# Generate the blocklist shell script the module would install, for a pinned
# set of options, so the e2e harness can run it verbatim in a netns.
#
# repo MUST be the absolute path of the checkout: `builtins.getFlake "git+file://..."`
# uses HEAD of that repo. NEVER pass a `toString ./..`-style path here — that
# copies the tree into a store path and pins nothing.
{
  repo,
  maxElem ? null,
  blocklistedIPs ? [ "9.9.9.9" ],
  blockDirection ? "all",
}:
let
  flake = builtins.getFlake "git+file://${repo}";
  pkgs = import flake.inputs.nixpkgs.outPath { };
  evalConfig = import (flake.inputs.nixpkgs.outPath + "/nixos/lib/eval-config.nix");
  sys = evalConfig {
    system = "x86_64-linux";
    modules = [
      {
        networking.hostName = "test";
        services.blocklist-updater = {
          enable = true;
          blocklists = [ "http://127.0.0.1:8765/all.txt" ];
          inherit blocklistedIPs;
          blocklistedCountries = [ ];
          blocklistedASNs = [ ];
          inherit blockDirection;
        }
        // (if maxElem == null then { } else { inherit maxElem; });
      }
      flake.nixosModules.blocklist-updater
    ];
  };
in
sys.config.systemd.services."blocklist".script
