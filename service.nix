{
  pkgs,
  config,
  lib,
  ...
}:
let
  cfg = config.services.blocklist-updater;
  inherit (cfg) ipV4SetName ipV6SetName;
  mkRules = bin: f: set: /* bash */ ''
    ${bin} ${f} INPUT -m set --match-set ${set} src -j DROP
    ${bin} ${f} INPUT -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "

    ${bin} ${f} FORWARD -m set --match-set ${set} src -j DROP
    ${bin} ${f} FORWARD -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "

    ${bin} -t raw ${f} PREROUTING -m set --match-set ${set} src -j DROP
    ${bin} -t raw ${f} PREROUTING -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "
  '';

  sed_domain_regex = "^(0\.0\.0\.0|127\.0\.0\.1)?[[:space:]]*([a-zA-Z0-9.-]*\.[a-zA-Z][a-zA-Z0-9.-]*)$";
  script = /* bash */ ''
    echo "Checking if ip-set ${ipV4SetName} already exists"
    if ! ipset -L ${ipV4SetName} >/dev/null 2>&1; then
        echo "${ipV4SetName} doesn't exist. Creating."
        ipset create "${ipV4SetName}" hash:net hashsize 262144 family inet
        ${mkRules "iptables" "-I" ipV4SetName}
    fi
    if ! ipset -L ${ipV6SetName} >/dev/null 2>&1; then
        echo "${ipV6SetName} doesn't exist. Creating."
        ipset create "${ipV6SetName}" hash:net hashsize 262144 family inet6
        ${mkRules "ip6tables" "-I" ipV6SetName}
    fi

    set -e
    urls=(
      ${cfg.blocklists}
    )

    # Output file
    BLFILE="/tmp/ipblocklist.txt"

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

    # ASNs
    ${builtins.concatStringsSep "\n" (
      map (asn: ''
        wget -O - 'https://stat.ripe.net/data/announced-prefixes/data.json?resource=${builtins.toString asn}&preferred_version=1' | ${lib.getExe pkgs.jq} -r '.data.prefixes[].prefix' >> "$BLFILE"
      '') cfg.blocklistedASNs
    )}

    ipset flush "${ipV4SetName}"
    ipset flush "${ipV6SetName}"

    ipv4_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$"
    ipv6_regex="^([0-9a-fA-F:]+::?[0-9a-fA-F]*)+(\/[0-9]{1,3})?$"

    {
      sed -nE '/${sed_domain_regex}/!p' "$BLFILE"
      # get all domains and query the IPs and ignore CNAMEs returned (e.g. from `dig +short mail.yahoo.com A`)
      dig -f <(sed -nE 's/${sed_domain_regex}/\2 A \2 AAAA +short/p' "$BLFILE") | grep -v '\.$'
    } | ${lib.optionalString cfg.compressIPRanges "${lib.getExe pkgs.python3Minimal} ${./compressIPs.py} |"} {
        while IFS= read -r IP; do
          if [[ "$IP" =~ $ipv4_regex ]]; then
            echo -exist add "${ipV4SetName}" "$IP"
          elif [[ "$IP" =~ $ipv6_regex ]]; then
            echo -exist add "${ipV6SetName}" "$IP"
          elif ! [[ "$IP" =~ ^$|^\# ]]; then
            # ignore empty line / comments
            echo "Warning: Invalid line skipped -> '$IP'" >&2
          fi
        done
    } | ipset restore

    rm -f "$BLFILE"
  '';

  postStop = /* bash */ ''
    echo "Deleting all tables from firewall"
    ${mkRules "iptables" "-D" ipV4SetName}
    ipset destroy "${ipV4SetName}"

    ${mkRules "ip6tables" "-D" ipV6SetName}
    ipset destroy "${ipV6SetName}"
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
}
