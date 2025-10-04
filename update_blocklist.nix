{ pkgs, config }:
let
  inherit (config.services.blocklist-updater)
    blocklists
    ipV4SetName
    ipV6SetName
    blocklistedIPs
    ;
in
''
  # Clear ipset from previous address.
  # Ignore if it fails, because we don't care 

  set -e
  urls=(
    ${blocklists}
  )

  # Output file
  BLFILE="/tmp/ipblocklist.txt"
  BLFILE_PROCESSED="/tmp/ipblocklist_processed.txt"

  # Empty the output file if it exists
  > "$BLFILE"

  # Download the blocklist and add it to a file
  for url in "''${urls[@]}"; do
    echo "Downloading blocklist '$url'..."
    wget -q -O - "$url" >> "$BLFILE"
    echo >> "$BLFILE" # Add a newline separator
  done

  # blocklist manual ips
  echo "${blocklistedIPs}">> $BLFILE

  ${import ./clear_blocklist.nix { inherit pkgs config; }}

  echo "Updating ip:s to ${ipV4SetName} ip-set"
  # Create an ip set and add each ip to it one by one

  # IPv4 and IPv6 regex patterns with CIDR notation support - WARNING: might not be correct for all IPs (e.g. ignore valid ones or accept wrong ones), but seems to work fine
  ipv4_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$"
  ipv6_regex="^([0-9a-fA-F:]+::?[0-9a-fA-F]*)+(\/[0-9]{1,3})?$"

  # Use a temporary buffer to improve performance
  {
      while IFS= read -r IP; do
          if [[ $IP =~ $ipv4_regex ]]; then
              echo -exist add "${ipV4SetName}" "$IP"
          elif [[ $IP =~ $ipv6_regex ]]; then
              echo -exist add "${ipV6SetName}" "$IP"
          else
              echo "Warning: Invalid line skipped -> $IP" >&2
          fi
      done < "$BLFILE"
  } > "$BLFILE_PROCESSED"
  ipset restore < "$BLFILE_PROCESSED"
''
