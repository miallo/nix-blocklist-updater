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

      # `nix develop`: ipset/iptables/wget/dig/python3 etc. — the tools
      # test/e2e/netns.sh runs its netns tests with, handy for manual debugging.
      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            ipset
            iptables
            wget
            bind
            python3
            coreutils
            gnused
            gnugrep
            git
          ];
        };
      });
      # for `nix flake check`
      checks = eachSystem (pkgs: {
        formatting = treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.check self;

        # the manual recipe formerly noted here, automated
        compressIPs =
          pkgs.runCommand "compressIPs-fixture-check" { nativeBuildInputs = [ pkgs.python3Minimal ]; }
            ''
              python3 ${./compressIPs.py} < ${./test/ips.txt} > out
              diff out ${./test/expected_ips.txt}
              # regression: 4096 consecutive /24 must collapse to exactly one /12
              # (the old fixed-10-pass merge hit its cap and emitted chains raw)
              for k in $(seq 0 4095); do echo "172.$((16 + k / 256)).$((k % 256)).0/24"; done \
                | python3 ${./compressIPs.py} > wide 2>/dev/null
              [ "$(cat wide)" = "172.16.0.0/12" ] || { echo "FAIL 4096-chain: $(cat wide)"; exit 1; }
              # regression: duplicate v4-mapped address must appear exactly once (in v6)
              printf '::ffff:1.2.3.4\n::ffff:1.2.3.4\n' \
                | python3 ${./compressIPs.py} > mapped 2>/dev/null
              [ "$(cat mapped)" = "::ffff:1.2.3.4/128" ] || { echo "FAIL v4-mapped: $(cat mapped)"; exit 1; }
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
