{ pkgs, config, ... }:
let
  cfg = config.services.blocklist-updater;
  inherit (cfg) ipV4SetName ipV6SetName;
  mkRules = bin: f: set: ''
    ${bin} ${f} INPUT -m set --match-set ${set} src -j DROP
    ${bin} ${f} INPUT -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "

    ${bin} ${f} FORWARD -m set --match-set ${set} src -j DROP
    ${bin} ${f} FORWARD -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "

    ${bin} -t raw ${f} PREROUTING -m set --match-set ${set} src -j DROP
    ${bin} -t raw ${f} PREROUTING -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "
  '';

  script = ''
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
    BLFILE_PROCESSED="/tmp/ipblocklist_processed.txt"

    rm -f "$BLFILE" "$BLFILE_PROCESSED" || :

    # Download the blocklist and add it to a file
    for url in "''${urls[@]}"; do
      echo "Downloading blocklist '$url'..."
      wget -q -O - "$url" >> "$BLFILE"
      echo >> "$BLFILE" # Add a newline separator
    done

    # blocklist manual ips
    echo "${cfg.blocklistedIPs}">> $BLFILE


    ipset flush "${ipV4SetName}"
    ipset flush "${ipV6SetName}"

    ipv4_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$"
    ipv6_regex="^([0-9a-fA-F:]+::?[0-9a-fA-F]*)+(\/[0-9]{1,3})?$"

    # Use a temporary buffer to improve performance
    {
        while IFS= read -r IP; do
            if [[ $IP =~ $ipv4_regex ]]; then
                echo -exist add "${ipV4SetName}" "$IP"
            elif [[ $IP =~ $ipv6_regex ]]; then
                echo -exist add "${ipV6SetName}" "$IP"
            elif [ -n "$IP" ]; then # only warn on non-empty line
                echo "Warning: Invalid line skipped -> '$IP'" >&2
            fi
        done < "$BLFILE"
    } > "$BLFILE_PROCESSED"
    ipset restore < "$BLFILE_PROCESSED"

    rm -f $BLFILE $BLFILE_PROCESSED
  '';

  postStop = ''
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

    startAt = cfg.updateAt;
    path = [
      pkgs.ipset
      pkgs.iptables
      pkgs.wget
    ];

    wantedBy = [ "multi-user.target" ]; # start at boot
    after = [ "network.target" ]; # Ensure networking is up
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
  };
}
