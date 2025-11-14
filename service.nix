{
  pkgs,
  config,
  lib,
  ...
}:
let
  cfg = config.services.blocklist-updater;
  inherit (cfg) ipV4SetName ipV6SetName;
  allowSomeOutboundTraffic = cfg.generateOutboundAllowedScript != null;
  mkRules =
    bin: f: set: allowOutbound:
    lib.optionalString allowOutbound /* bash */ ''
      ${bin} ${if f == "-I" then "-A" else f} INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ''
    + /* bash */ ''
      ${bin} ${f} INPUT -m set --match-set ${set} src -j DROP
      ${bin} ${f} INPUT -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "
    ''
    + lib.optionalString (!allowOutbound) /* bash */ ''
      ${bin} ${f} FORWARD -m set --match-set ${set} src -j DROP
      ${bin} ${f} FORWARD -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "

      # TODO: check if this should be OUTPUT instead of PREROUTING
      ${bin} -t raw ${f} PREROUTING -m set --match-set ${set} src -j DROP
      ${bin} -t raw ${f} PREROUTING -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "
    '';

  sed_domain_regex = "^(0\.0\.0\.0|127\.0\.0\.1)?[[:space:]]*([a-zA-Z0-9.-]*\.[a-zA-Z][a-zA-Z0-9.-]*)$";

  applyFile =
    file: blockOutbound:
    let
      suffix = lib.optionalString blockOutbound "out";
    in
    /* bash */ ''
      {
        sed -nE '/${sed_domain_regex}/!p' "${file}"
        # get all domains and query the IPs and ignore CNAMEs returned (e.g. from `dig +short mail.yahoo.com A`)
        dig -f <(sed -nE 's/${sed_domain_regex}/\2 A \2 AAAA +short/p' "${file}") | grep -v '\.$'
      } | ${lib.optionalString cfg.compressIPRanges "${lib.getExe pkgs.python3Minimal} ${./compressIPs.py} |"} {
          while IFS= read -r IP; do
            if [[ "$IP" =~ $ipv4_regex ]]; then
              echo -exist add "${ipV4SetName + suffix}" "$IP"
            elif [[ "$IP" =~ $ipv6_regex ]]; then
              echo -exist add "${ipV6SetName + suffix}" "$IP"
            elif ! [[ "$IP" =~ ^$|^\# ]]; then
              # ignore empty line / comments
              echo "Warning: Invalid line skipped -> '$IP'" >&2
            fi
          done
      } | ipset restore
    '';

  script = /* bash */ ''
    echo "Checking if ip-set ${ipV4SetName} already exists"
    if ! ipset -L ${ipV4SetName} >/dev/null 2>&1; then
        echo "${ipV4SetName} doesn't exist. Creating."
        ipset create "${ipV4SetName}" hash:net hashsize 262144 family inet
        ${mkRules "iptables" "-I" ipV4SetName false}
    fi
    if ! ipset -L ${ipV6SetName} >/dev/null 2>&1; then
        echo "${ipV6SetName} doesn't exist. Creating."
        ipset create "${ipV6SetName}" hash:net hashsize 262144 family inet6
        ${mkRules "ip6tables" "-I" ipV6SetName false}
    fi

    ${lib.optionalString allowSomeOutboundTraffic /* bash */ ''
      if ! ipset -L ${ipV4SetName}out >/dev/null 2>&1; then
          echo "${ipV4SetName}out doesn't exist. Creating."
          ipset create "${ipV4SetName}out" hash:net hashsize 262144 family inet
          ${mkRules "iptables" "-I" "${ipV4SetName}out" allowSomeOutboundTraffic}
      fi
      if ! ipset -L ${ipV6SetName}out >/dev/null 2>&1; then
          echo "${ipV6SetName}out doesn't exist. Creating."
          ipset create "${ipV6SetName}out" hash:net hashsize 262144 family inet6
          ${mkRules "ip6tables" "-I" "${ipV6SetName}out" allowSomeOutboundTraffic}
      fi
    ''}

    set -e
    urls=(
      ${cfg.blocklists}
    )

    # Output file
    BLFILE="/tmp/ipblocklist.txt"
    ${lib.optionalString cfg.debug ''
      BLDEBUG_DIR="/tmp/blocklist_debug"
      rm -rf "$BLDEBUG_DIR"
      mkdir "$BLDEBUG_DIR"
    ''}

    rm -f "$BLFILE" || :

    # Download the blocklist and add it to a file
    for url in "''${urls[@]}"; do
      echo "Downloading blocklist '$url'..."
      wget -q -O - "$url" >> "$BLFILE"
      echo >> "$BLFILE" # Add a newline separator
    done

    # blocklist manual ips
    echo "${cfg.blocklistedIPs}">> $BLFILE

    ${lib.optionalString (cfg.generateIPScript != null) /* bash */ ''
      (
        # begin custom code
        ${cfg.generateIPScript}
        # end custom code
      ) >> "$BLFILE"
    ''}

    # Countries
    ${builtins.concatStringsSep "\n" (
      map (country: ''
        wget -O - 'https://stat.ripe.net/data/country-resource-list/data.json?resource=${country}&v4_format=prefix' | ${lib.optionalString cfg.debug ''${pkgs.coreutils}/bin/tee "$BLDEBUG_DIR/${country}.json" |''} ${lib.getExe pkgs.jq} -r '.data.resources | .ipv4 + .ipv6 | .[]' >> "$BLFILE"
      '') cfg.blocklistedCountries
    )}

    # ASNs
    ${builtins.concatStringsSep "\n" (
      map (asn: ''
        wget -O - 'https://stat.ripe.net/data/announced-prefixes/data.json?resource=${builtins.toString asn}&preferred_version=1' | ${lib.optionalString cfg.debug ''${pkgs.coreutils}/bin/tee "$BLDEBUG_DIR/${builtins.toString asn}.json" |''} ${lib.getExe pkgs.jq} -r '.data.prefixes[].prefix' >> "$BLFILE"
      '') cfg.blocklistedASNs
    )}

    ipset flush "${ipV4SetName}"
    ipset flush "${ipV6SetName}"

    ipv4_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$"
    ipv6_regex="^([0-9a-fA-F:]+::?[0-9a-fA-F]*)+(\/[0-9]{1,3})?$"

    ${applyFile "$BLFILE" true}

    ${lib.optionalString (!cfg.debug) ''rm -f "$BLFILE"''}

    ${lib.optionalString allowSomeOutboundTraffic /* bash */ ''
      ipset flush "${ipV4SetName}out"
      ipset flush "${ipV6SetName}out"
      BLFILE_OUT="/tmp/ipblocklist.txt"
      (
        # begin custom code
        ${cfg.generateOutboundAllowedScript}
        # end custom code
      ) >> "$BLFILE_OUT"
      ${applyFile "$BLFILE_OUT" false}
      ${lib.optionalString (!cfg.debug) ''rm -f "$BLFILE_OUT"''}
    ''}
  '';

  postStop = /* bash */ ''
    echo "Deleting all tables from firewall"
    ${mkRules "iptables" "-D" ipV4SetName false}
    ipset destroy "${ipV4SetName}"

    ${mkRules "ip6tables" "-D" ipV6SetName false}
    ipset destroy "${ipV6SetName}"

    ${lib.optionalString allowSomeOutboundTraffic /* bash */ ''
      ${mkRules "iptables" "-D" "${ipV4SetName}out" allowSomeOutboundTraffic}
      ipset destroy "${ipV4SetName}out"
      ${mkRules "ip6tables" "-D" "${ipV6SetName}out" allowSomeOutboundTraffic}
      ipset destroy "${ipV6SetName}out"
    ''}
  '';
in
{
  systemd.services."blocklist" = {
    enable = cfg.enable;
    description = "Set firewall according to blocklist";
    inherit script postStop;
    path = [
      pkgs.ipset
      pkgs.iptables
      pkgs.wget
      pkgs.dig
    ];

    wantedBy = [ "multi-user.target" ]; # start at boot
    after = [ "network.target" ]; # Ensure networking is up
    serviceConfig.Type = "oneshot";
    # needed to avoid triggering `onStop`, BUT
    # This also prevents the timer from restarting (see: https://unix.stackexchange.com/a/546946)
    # => create separate service that manually restarts this on a timer
    serviceConfig.RemainAfterExit = true;
  };

  systemd.services."blocklist-restart" = {
    enable = cfg.enable;
    description = "Trigger update of blocklist";
    startAt = cfg.updateAt;
    path = [ pkgs.systemd ];
    script = "systemctl restart blocklist";
    serviceConfig.Type = "oneshot";
  };

  systemd.timers = lib.mkIf cfg.enable { "blocklist-restart" = { inherit (cfg) timerConfig; }; };
}
