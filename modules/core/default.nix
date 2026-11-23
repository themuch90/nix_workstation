{ config, lib, pkgs, ... }:
let
  cfg = config.my.core;
in
{
  options.my.core = {
    hostName = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9-]{0,14}";
      example = "office-pc01";
      description = ''
        Machine name (letters, digits, hyphen; max 15 characters for
        NetBIOS/Active Directory compatibility). It is also the name of
        the computer account in the domain.
      '';
    };
    timeZone = lib.mkOption { type = lib.types.str; default = "Europe/Rome"; };
    locale = lib.mkOption { type = lib.types.str; default = "it_IT.UTF-8"; };
    keyboardLayout = lib.mkOption { type = lib.types.str; default = "it"; };
    vpnPlugins = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        NetworkManager VPN plugins: OpenVPN, OpenConnect (Cisco AnyConnect,
        GlobalProtect, Fortinet, Pulse), L2TP. vpnc, FortiSSL and SSTP are
        excluded: nixpkgs marks them as insecure (known CVEs).
        WireGuard is built in and needs no plugin.
      '';
    };
  };

  config = {
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    networking.hostName = cfg.hostName;
    networking.networkmanager.enable = true;
    networking.networkmanager.plugins = lib.mkIf cfg.vpnPlugins (with pkgs; [
      networkmanager-openvpn networkmanager-openconnect networkmanager-l2tp
    ]);
    networking.firewall.enable = true;

    time.timeZone = cfg.timeZone;
    i18n.defaultLocale = cfg.locale;
    console.keyMap = cfg.keyboardLayout;
    services.xserver.xkb.layout = cfg.keyboardLayout;

    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      # no "Git tree '/etc/nixos' is dirty" warning: uncommitted local
      # changes are expected (see config-update)
      warn-dirty = false;
    };
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
      git vim wget curl htop pciutils usbutils dnsutils
    ];

    services.openssh.enable = true;
    services.fwupd.enable = true;
  };
}
