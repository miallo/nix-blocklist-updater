{ pkgs, config }:
let
  inherit (pkgs) ipset;
  inherit (config.services.blocklist-updater) ipV4SetName ipV6SetName;
in
''
  echo "Clearing ${ipV4SetName} ip-set..."
  ${ipset}/bin/ipset flush "${ipV4SetName}"
  ${ipset}/bin/ipset flush "${ipV6SetName}"
''
