{ config, lib, pkgs, ... }:
let
  cfg = config.my.vmstation;
  vmstation = pkgs.callPackage ../../pkgs/vmstation { };
  net = config.my.virtualization.vmNetwork;
  ipPrefix = lib.concatMapStrings (o: o + ".")
    (lib.take (if net.prefixLength >= 24 then 3 else if net.prefixLength >= 16 then 2 else 1)
      (lib.splitString "." net.address));
in
{
  options.my.vmstation.enable = lib.mkEnableOption "VM Station (VM consoles via RDP and SSH)";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ vmstation ];

    # defaults for all users; ~/.config/vmstation/config.json stores only the differences
    environment.etc."vmstation/config.json".text = builtins.toJSON {
      proxmox = {
        url = "https://${config.my.virtualization.vmNetwork.address}:8006";
        user = "${config.my.users.localAdmin.name}@pam";
        token_id = "";
        token_secret = "";
        verify_ssl = false;
      };
      rdp = {
        prefer_ip_prefix = ipPrefix;
        default_user = "";
        default_domain = "";
      };
      # keyboard layout passed to the RDP consoles (/kbd:layout:)
      keyboard = config.my.core.keyboardLayout;
    };
  };
}
