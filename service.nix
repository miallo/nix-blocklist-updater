{
  pkgs,
  config,
  lib,
  ...
}:
let
  cfg = config.services.blocklist-updater;
  bldebugDir = "/var/lib/blocklist-updater/debug";
  inherit (cfg) ipV4SetName ipV6SetName;
  createArgs =
    family:
    "hash:net ${
      lib.optionalString (cfg.hashSize != null) "hashsize ${toString cfg.hashSize} "
    }maxelem ${toString cfg.maxElem} family ${family}";
  logLimit = "-m limit --limit 10/min --limit-burst 20";
  logTarget = "${logLimit} -j LOG --log-prefix \"FW_DROPPED: \"";
  # Up to and including main, the LOG rule shipped WITHOUT rate limiting.
  # `iptables -D/-C` match the full rule spec, so teardown carries the old
  # spec explicitly as a "legacy" target: stopping this release must delete
  # what the previous release installed, or the leftover rules pin the ipset
  # and silently replace the working firewall on upgrade (e2e run 8).
  legacyLogTarget = "-j LOG --log-prefix \"FW_DROPPED: \"";
  # One rule spec = exactly one iptables rule. `match` carries the conntrack
  # variant; the conntrack match is only valid in filter chains — the raw
  # table runs before conntrack exists, and omitting the raw pair is what
  # lets blockDirection = "inbound" keep outbound traffic alive.
  mkRuleSpecs =
    ctNew: includeRaw: legacyCompat: set:
    let
      m = "${ctNew}-m set --match-set ${set} src";
      pair = table: chain: [
        {
          inherit table chain;
          match = m;
          target = logTarget;
          legacyTargets = lib.optionals legacyCompat [ legacyLogTarget ];
          pos = 1;
        }
        {
          inherit table chain;
          match = m;
          target = "-j DROP";
          legacyTargets = [ ];
          pos = 2;
        }
      ];
    in
    pair "filter" "INPUT"
    ++ pair "filter" "FORWARD"
    ++ lib.optionals includeRaw (pair "raw" "PREROUTING");
  ruleSpecs = {
    # Paranoid default: drop every packet whose source is blocklisted.
    all = mkRuleSpecs "" true true;
    # Block new inbound connections only: packets of established connections
    # (incl. replies to our own outbound traffic) pass because they no longer
    # match conntrack state NEW, so outbound contact with blocklisted hosts
    # keeps working. Stray packets that match no connection (INVALID) pass;
    # they cannot establish anything without a responding handshake.
    inbound = mkRuleSpecs "-m conntrack --ctstate NEW " false false;
  };
  tblArg = t: lib.optionalString (t == "raw") "-t raw ";
  # Install each spec unless already present. A live ipset is NOT proof the
  # rules are (manual `iptables -F`, or teardown interrupted by an older
  # release's spec mismatch), so installation is idempotent per rule instead
  # of gated on set creation — a missing DROP rule is self-healed by the next
  # timer run rather than silently absent.
  installRules =
    bin: rules:
    lib.concatStringsSep "\n" (
      map (r: ''
        if ! ${bin} ${tblArg r.table}-C ${r.chain} ${r.match} ${r.target} 2>/dev/null; then
          ${bin} ${tblArg r.table}-I ${r.chain} ${toString r.pos} ${r.match} ${r.target}
        fi
      '') rules
    );
  # -D matches the full rule spec: delete the current spec plus every legacy
  # spec that was ever installed into this rule slot.
  teardownRules =
    bin: rules:
    lib.concatStringsSep "\n" (
      map (
        r:
        lib.concatStringsSep "\n" (
          [
            ''${bin} ${tblArg r.table}-D ${r.chain} ${r.match} ${r.target} 2>/dev/null || :''
          ]
          ++ map (
            t: ''${bin} ${tblArg r.table}-D ${r.chain} ${r.match} ${t} 2>/dev/null || :''
          ) r.legacyTargets
        )
      ) rules
    );

  sed_domain_regex = "^(0\.0\.0\.0|127\.0\.0\.1)?[[:space:]]*([a-zA-Z0-9.-]*\.[a-zA-Z][a-zA-Z0-9.-]*)$";
  script = /* bash */ ''
    set -eo pipefail
    urls=(
      ${lib.escapeShellArgs cfg.blocklists}
    )

    # Output file
    BLFILE="/tmp/ipblocklist.txt"
    ${lib.optionalString cfg.debug ''
      rm -rf ${lib.escapeShellArg bldebugDir}
      mkdir -p ${lib.escapeShellArg bldebugDir}
    ''}

    rm -f "$BLFILE" || :

    # Download the blocklist and add it to a file
    for url in "''${urls[@]}"; do
      echo "Downloading blocklist '$url'..."
      wget -q -O - "$url" >> "$BLFILE"
      echo >> "$BLFILE" # Add a newline separator
    done

    # blocklist manual ips
    printf '%s\n' ${lib.escapeShellArgs (lib.toList cfg.blocklistedIPs)} >> "$BLFILE"

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
        wget -O - ${lib.escapeShellArg "https://stat.ripe.net/data/country-resource-list/data.json?resource=${country}&v4_format=prefix"} | ${lib.optionalString cfg.debug ''${pkgs.coreutils}/bin/tee ${lib.escapeShellArg "${bldebugDir}/${country}.json"} |''} ${lib.getExe pkgs.jq} -r '.data.resources | .ipv4 + .ipv6 | .[]' >> "$BLFILE"
      '') cfg.blocklistedCountries
    )}

    # ASNs
    ${builtins.concatStringsSep "\n" (
      map (asn: ''
        wget -O - ${lib.escapeShellArg "https://stat.ripe.net/data/announced-prefixes/data.json?resource=${builtins.toString asn}&preferred_version=1"} | ${lib.optionalString cfg.debug ''${pkgs.coreutils}/bin/tee ${lib.escapeShellArg "${bldebugDir}/${builtins.toString asn}.json"} |''} ${lib.getExe pkgs.jq} -r '.data.prefixes[].prefix' >> "$BLFILE"
      '') cfg.blocklistedASNs
    )}

    if ! grep -q . "$BLFILE"; then
      echo "blocklist-updater: no entries collected from any source, refusing to replace live sets" >&2
      exit 1
    fi

    # Build fresh sets next to the live ones; they are committed atomically below,
    # so a failed or partial update can never leave the live sets empty.
    ipset destroy "${ipV4SetName}_new" 2>/dev/null || true
    ipset create "${ipV4SetName}_new" ${createArgs "inet"}
    ipset destroy "${ipV6SetName}_new" 2>/dev/null || true
    ipset create "${ipV6SetName}_new" ${createArgs "inet6"}

    ipv4_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$"
    ipv6_regex="^([0-9a-fA-F:]+::?[0-9a-fA-F]*)+(\/[0-9]{1,3})?$"

    {
      sed -nE '/${sed_domain_regex}/!p' "$BLFILE"
      # get all domains and query the IPs and ignore CNAMEs returned (e.g. from `dig +short mail.yahoo.com A`)
      # a domain failing to resolve is normal (NXDOMAIN -> dig exit 2), so tolerate it; dedup queries with sort -u
      dig -f <(sed -nE 's/${sed_domain_regex}/\2 A \2 AAAA +short/p' "$BLFILE" | sort -u) | grep -v '\.$' || true
    } | ${lib.optionalString cfg.compressIPRanges "${lib.getExe pkgs.python3Minimal} ${./compressIPs.py} |"} {
        while IFS= read -r IP; do
          if [[ "$IP" =~ $ipv4_regex ]]; then
            echo -exist add "${ipV4SetName}_new" "$IP"
          elif [[ "$IP" =~ $ipv6_regex ]]; then
            echo -exist add "${ipV6SetName}_new" "$IP"
          elif ! [[ "$IP" =~ ^$|^\# ]]; then
            # ignore empty line / comments
            echo "Warning: Invalid line skipped -> '$IP'" >&2
          fi
        done
    } | ipset restore

    commit_staged() {
      local active="$1" staged="$2"
      if ipset -L "$active" >/dev/null 2>&1; then
        # swap exchanges contents *and* create options (hashsize/maxelem)
        # atomically; afterwards the staged name holds the previous set.
        if ipset swap "$active" "$staged"; then
          ipset destroy "$staged"
        else
          echo "ipset swap failed for $active; recreating it from the staged set" >&2
          ipset destroy "$active" 2>/dev/null || true
          ipset rename "$staged" "$active"
        fi
      else
        ipset rename "$staged" "$active"
      fi
    }
    commit_staged "${ipV4SetName}" "${ipV4SetName}_new"
    ${installRules "iptables" (ruleSpecs.${cfg.blockDirection} ipV4SetName)}
    commit_staged "${ipV6SetName}" "${ipV6SetName}_new"
    ${installRules "ip6tables" (ruleSpecs.${cfg.blockDirection} ipV6SetName)}

    ${
      if cfg.debug then
        ''mv "$BLFILE" ${lib.escapeShellArg "${bldebugDir}/ipblocklist.txt"}''
      else
        ''rm -f "$BLFILE"''
    }
  '';

  postStop = /* bash */ ''
    echo "Deleting all tables from firewall"
    # Tear down *both* directions best-effort: if services.blocklist-updater.blockDirection
    # was changed during a rebuild, the unit restarts and the rules installed in the
    # kernel come from the old setting — deleting only the current variant would orphan
    # them. Failing to delete a variant that was never installed must not fail teardown.
    # The "all" variant additionally deletes the pre-rate-limit LOG spec so an
    # upgrade from <= main unpins the ipsets instead of leaving orphan rules that
    # survive teardown and silently replace the firewall (e2e run 8).
    (
      set +e
      ${teardownRules "iptables" (ruleSpecs.all ipV4SetName)}
      ${teardownRules "ip6tables" (ruleSpecs.all ipV6SetName)}
      ${teardownRules "iptables" (ruleSpecs.inbound ipV4SetName)}
      ${teardownRules "ip6tables" (ruleSpecs.inbound ipV6SetName)}
      true
    )
    ipset destroy "${ipV4SetName}"
    ipset destroy "${ipV4SetName}_new" 2>/dev/null || true
    ipset destroy "${ipV6SetName}"
    ipset destroy "${ipV6SetName}_new" 2>/dev/null || true
  '';
in
lib.mkIf cfg.enable {
  systemd.services."blocklist" = {
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
    # /tmp/ipblocklist.txt is written as root: keep it in a private /tmp so
    # local users cannot pre-seed or symlink it, and keep debug artifacts in
    # a dedicated state directory instead.
    serviceConfig.PrivateTmp = true;
    serviceConfig.StateDirectory = "blocklist-updater";
  };

  systemd.services."blocklist-restart" = {
    description = "Trigger update of blocklist";
    startAt = cfg.updateAt;
    path = [ pkgs.systemd ];
    script = "systemctl restart blocklist";
    serviceConfig.Type = "oneshot";
  };

  systemd.timers."blocklist-restart" = { inherit (cfg) timerConfig; };
}
