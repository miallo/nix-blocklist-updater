{ pkgs, config, ... }:
let
  cfg = config.services.blocklist-updater;
  inherit (cfg) ipV4SetName ipV6SetName;
  mkRules = bin: f: set: ''
    ${bin} ${f} INPUT -m set --match-set ${set} src -j DROP
    ${bin} ${f} INPUT -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "

    ${bin} ${f} FORWARD -m set --match-set ${set} src -j DROP
    ${bin} ${f} FORWARD -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "

    ${bin} -t raw ${f} PREROUTING -m set --match-set ${set} src -j DROP
    ${bin} -t raw ${f} PREROUTING -m set --match-set ${set} src -j LOG --log-prefix "FW_DROPPED: "
  '';
  postStop = ''
    echo "Deleting all tables from firewall"
    ${mkRules "iptables" "-D" ipV4SetName}
    ipset destroy "${ipV4SetName}"

    ${mkRules "ip6tables" "-D" ipV6SetName}
    ipset destroy "${ipV6SetName}"
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
    inherit postStop;

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
