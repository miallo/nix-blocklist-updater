{ pkgs, config, ... }:
let
  cfg = config.services.blocklist-updater;
  mkRules = bin: f: set: ''
    ${bin} ${f} INPUT -m set --match-set ${set} src -j DROP
    ${bin} ${f} INPUT -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "

    ${bin} ${f} FORWARD -m set --match-set ${set} src -j DROP
    ${bin} ${f} FORWARD -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "

    ${bin} -t raw ${f} PREROUTING -m set --match-set ${set} src -j DROP
    ${bin} -t raw ${f} PREROUTING -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "
  '';
in
{
  systemd.services."blocklist" = {
    enable = cfg.enable;
    preStart = toString (
      pkgs.writeScript "init_blocklist.sh" (import ./init_blocklist.nix { inherit pkgs config mkRules; })
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
