# Blocklist Updater For NixOS

This NixOS expression will block all malicous IPs and update them daily.

The source for the malicious IPs is lists.blocklist.de

# Systemd

A systemd unit called "blocklist" will be created and will run every day at 01:00:00.

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

   # optionally set the time when to update
   updateAt = [
     "Wed 14:00:00"
     "Sun 14:00:00"
    ]
};
```

3. run `nixos-rebuild switch` and let NixOS do the rest :)

# Develop

This repo is using automated code formatting. Please run `nix fmt` before committing :)
