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

2. add `blocklist-updater.nixosModules.blocklist-updater` to your modules
3. set `services.blocklist-updater.enable = true;`
4. run `nixos-rebuild switch` and let NixOS do the rest :)

# Develop

This repo is using automated code formatting. Please run `nix fmt` before committing :)
