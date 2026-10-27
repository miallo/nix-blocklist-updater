# Blocklist Updater For NixOS

This NixOS expression will block all malicious IPs and update them daily.

The source for the malicious IPs is lists.blocklist.de

# Systemd

A systemd service called "blocklist" will be created; it runs at boot and installs the firewall rules. A timer "blocklist-restart" triggers an update every day at 01:00:00 plus a randomized delay of up to 15 minutes (both configurable via `updateAt` and `timerConfig`).

# Usage

1. Add this to your flake inputs:

```
blocklist-updater = {
  url = "github:miallo/nix-blocklist-updater";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

2. add

```nix
imports = [
  inputs.blocklist-updater.nixosModules.blocklist-updater
];

config.services.blocklist-updater = {
  enable = true;

  # optionally manually block certain IPs/domains
  blocklistedIPs = [
    "145.249.104.0/22"
    "google.com"
  ];

  # optionally use your own blocklist
  blocklists = [
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-only/hosts"
  ];

  # optionally tune ipset capacity; the default maxElem is large enough for
  # country-wide blocking (ipset's own default of 65536 is not). Memory is
  # allocated per entry, not for the limit. hashSize is grown automatically.
  maxElem = 1048576;
  # hashSize = 65536;

  # optionally add a script to generate lists of IPs/domains (e.g. allows you to transform lists in incompatible formats)
  generateIPScript = ''
    ${lib.getExe pkgs.curl} -L https://www.spamhaus.org/drop/drop_v4.json | ${lib.getExe pkgs.jq} -r ' .cidr | select( . != null )'
    ${lib.getExe pkgs.curl} -L https://www.spamhaus.org/drop/drop_v6.json | ${lib.getExe pkgs.jq} -r ' .cidr | select( . != null )'
  '';

  # optionally block countries
  blocklistedCountries = [
    "ru"
    "cn"
  ];

  # optionally block whole ASNs
  blocklistedASNs = [
    14061 # DigitalOcean LLC
    "AS396982" # GOOGLE-CLOUD-PLATFORM
  ];

  # optionally set the time when to update
  updateAt = [
    "Wed 14:00:00"
    "Sun 14:00:00"
  ];
};
```

3. run `nixos-rebuild switch` and let NixOS do the rest :)

# Develop

This repo is using automated code formatting. Please run `nix fmt` before committing :)

End-to-end tests (ipset/iptables in an unprivileged netns): `./test/e2e/netns.sh`.
The tools it needs (`ipset`, `iptables`, `wget`, `dig`, …) come from the flake's
devShell — `nix develop` gives you the same set for manual debugging.
It must run in a user shell (or CI step) — the nix build sandbox blocks `unshare`,
so it is deliberately not part of `nix flake check`.
