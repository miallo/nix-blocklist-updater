{ lib, ... }:
{
  options.services.blocklist-updater = {
    enable = lib.mkEnableOption "blocklist-updater";
    blocklists = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "example.com" ];
      default = [ "https://lists.blocklist.de/lists/all.txt" ];
      description = "URL lists containing new line separated IPs to be blocked";
      apply = lib.strings.concatMapStrings (x: "\n'${x}'");
    };
    blocklistedIPs = lib.mkOption {
      type = with lib.types; either str (listOf str);
      example = [
        "1.2.3.4"
        "10.168.10.0/24"
        "2a06:4883:1000::2"
      ];
      default = [ ];
      description = "List of manually banned IPs";
      apply = v: if builtins.isList v then lib.strings.concatMapStrings (x: "\n" + x) v else v;
    };

    blocklistedASNs = lib.mkOption {
      type = with lib.types; listOf (either ints.u32 str);
      example = lib.literalExpression ''
        [
           14061 # DigitalOcean LLC
           "AS396982" # GOOGLE-CLOUD-PLATFORM
        ]'';
      default = [ ];
      description = "List of manually banned ASNs (autonomous systems). Uses https://stat.ripe.net . For terms and conditions, see https://www.ripe.net/about-us/legal/ripestat-service-terms-and-conditions/";
      apply = lib.unique;
    };

    compressIPRanges = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "If too many ip blocks are found you can compress the data. While updating this is more memory intensive and adds python as a dependency.";
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Leave intermediate files in /tmp for later review";
    };

    generateIPScript = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      example = ''
        ''${lib.getExe pkgs.curl} -L https://www.spamhaus.org/drop/drop_v4.json | ''${lib.getExe pkgs.jq} -r ' .cidr | select( . != null )'
        ''${lib.getExe pkgs.curl} -L https://www.spamhaus.org/drop/drop_v6.json | ''${lib.getExe pkgs.jq} -r ' .cidr | select( . != null )'
      '';
      default = null;
      description = "bash script to generate IPs/CIDR notatings/domains. The output (STDOUT) is taken and expects newline separated entries.";
    };
    updateAt = lib.mkOption {
      type = with lib.types; either str (listOf str);
      default = "*-*-* 01:00:00";
      example = [
        "Wed 14:00:00"
        "Sun 14:00:00"
      ];
      description = ''
        Automatically start this unit at the given date/time, which
        must be in the format described in
        {manpage}`systemd.time(7)`.  This is equivalent
        to adding a corresponding timer unit with
        {option}`OnCalendar` set to the value given here.
      '';
    };
    ipV4SetName = lib.mkOption {
      type = lib.types.str;
      default = "blocklist-as4";
      description = "Name of ipset for IPv4 addresses";
    };
    ipV6SetName = lib.mkOption {
      type = lib.types.str;
      default = "blocklist-as6";
      description = "Name of ipset for IPv6 addresses";
    };
  };

  imports = [
    ./service.nix
    (lib.mkRemovedOptionModule [ "services" "blocklist-updater" "runInitially" ] ''
      The service is now performant and can be run on every boot. This avoids
      leaving the blocklist in place if the module is removed.
    '')
    (lib.mkRenamedOptionModule
      [ "services" "blacklist-updater" "enable" ]
      [ "services" "blocklist-updater" "enable" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "blacklist-updater" "blacklists" ]
      [ "services" "blocklist-updater" "blocklists" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "blacklist-updater" "blacklistedIPs" ]
      [ "services" "blocklist-updater" "blocklistedIPs" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "blacklist-updater" "updateAt" ]
      [ "services" "blocklist-updater" "updateAt" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "blocklist-updater" "ipSetName" ]
      [ "services" "blocklist-updater" "ipV4SetName" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "blacklist-updater" "ipSetName" ]
      [ "services" "blocklist-updater" "ipV4SetName" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "blacklist-updater" "ipV6SetName" ]
      [ "services" "blocklist-updater" "ipV6SetName" ]
    )
  ];
}
