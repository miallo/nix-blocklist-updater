{ pkgs, config, mkRules }:
let
  inherit (config.services.blocklist-updater) ipV4SetName ipV6SetName;
in
''
  echo "Running blocklist initializer"

  # Stop if the set already exists
  echo "Checking if ip-set ${ipV4SetName} already exists"

  if ! ipset -L ${ipV4SetName} >/dev/null 2>&1; then
      echo "${ipV4SetName} doesn't exist. Creating."

      ipset create "${ipV4SetName}" hash:ip hashsize 262144

      # Blacklist all addresses from this ip set
      ${mkRules "iptables" "-I" ipV4SetName}
  fi

  if ! ipset -L ${ipV6SetName} >/dev/null 2>&1; then
      echo "${ipV6SetName} doesn't exist. Creating."

      ipset create "${ipV6SetName}" hash:ip hashsize 262144 family inet6

      # Blacklist all addresses from this ip set
      ${mkRules "ip6tables" "-I" ipV6SetName}
  fi
''
