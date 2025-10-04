{ pkgs, config, ... }:
let
  cfg = config.services.blocklist-updater;
in
{
  systemd.services."blocklist" = {
    enable = cfg.enable;
    preStart = toString (
      pkgs.writeScript "init_blocklist.sh" (import ./init_blocklist.nix { inherit pkgs config; })
    );
    script = toString (
      pkgs.writeScript "blocklist_update.sh" (import ./update_blocklist.nix { inherit pkgs config; })
    );
    postStop = toString (
      pkgs.writeScript "clear_blocklist.sh" (import ./clear_blocklist.nix { inherit pkgs config; })
    );
    startAt = cfg.updateAt;
    path = [
      pkgs.ipset
      pkgs.iptables
      pkgs.wget
    ];

    wantedBy = [ "multi-user.target" ]; # start at boot
    after = [ "network.target" ]; # Ensure networking is up
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
  };
}
