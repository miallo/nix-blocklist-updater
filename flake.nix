{
  description = "A service for updating blocklists of IPs";

  inputs = {
    nixpkgs.url = "flake:nixpkgs/nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
      treefmt-nix,
      ...
    }:
    let
      eachSystem = f: nixpkgs.lib.genAttrs (import systems) (system: f nixpkgs.legacyPackages.${system});

      treefmtEval = eachSystem (
        pkgs:
        treefmt-nix.lib.evalModule pkgs {
          programs.nixfmt.enable = true;
          programs.prettier.enable = true;
        }
      );
      blocklistModule = import ./.;
    in
    {
      nixosModules = rec {
        blocklist-updater = blocklistModule;
        default = blocklist-updater;
        blacklist-updater = blocklistModule; # backwards compatibility
      };

      # for `nix fmt`
      formatter = eachSystem (pkgs: treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.wrapper);
      # for `nix flake check`
      checks = eachSystem (pkgs: {
        formatting = treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.check self;

        # TODO: add automated check of compressIPs script. for now: manually run it with:
        # git diff --no-index -- <(cat test/ips.txt | python3 ./compressIPs.py) test/expected_ips.txt
      });
    };
}
