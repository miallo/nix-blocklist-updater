{
  description = "A service for updating blocklists of IPs";

  inputs = {
    nixpkgs.url = "flake:nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
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

      # Evaluate the NixOS module so `nix flake check` notices module-level
      # breakage (e.g. units that ignore services.blocklist-updater.enable).
      evalNixosModule =
        system: enabled:
        (import "${nixpkgs}/nixos/lib/eval-config.nix" {
          inherit system;
          modules = [
            {
              networking.hostName = "module-eval-test";
              services.blocklist-updater.enable = enabled;
            }
            blocklistModule
            (
              { config, ... }:
              {
                assertions = [
                  {
                    assertion = (config.systemd.units ? "blocklist.service") == enabled;
                    message = "unit blocklist.service should ${
                      if enabled then "" else "not "
                    }exist when enable = ${builtins.toString enabled}";
                  }
                  {
                    assertion = (config.systemd.units ? "blocklist-restart.timer") == enabled;
                    message = "timer blocklist-restart.timer should ${
                      if enabled then "" else "not "
                    }exist when enable = ${builtins.toString enabled}";
                  }
                ];
              }
            )
          ];
        }).config;
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

        # the manual recipe formerly noted here, automated
        compressIPs =
          pkgs.runCommand "compressIPs-fixture-check" { nativeBuildInputs = [ pkgs.python3Minimal ]; }
            ''
              python3 ${./compressIPs.py} < ${./test/ips.txt} > out
              diff out ${./test/expected_ips.txt}
              mv out $out
            '';

        moduleEval =
          let
            on = evalNixosModule pkgs.stdenv.hostPlatform.system true;
            off = evalNixosModule pkgs.stdenv.hostPlatform.system false;
          in
          pkgs.runCommand "nixos-module-eval-check" { } ''
            echo "on=${on.networking.hostName} off=${off.networking.hostName}" > $out
          '';
      });
    };
}
