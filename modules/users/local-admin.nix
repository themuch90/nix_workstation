{ config, lib, ... }:
let
  cfg = config.my.users.localAdmin;
in
{
  options.my.users.localAdmin = {
    enable = lib.mkEnableOption "local administrator user";
    name = lib.mkOption { type = lib.types.str; default = "localadmin"; };
    description = lib.mkOption { type = lib.types.str; default = "Local administrator"; };
    password = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "CHANGEME";
      description = ''
        Plain-text password (ends up in the Nix store, readable by everyone).
        Only fine for the first boot: use hashedPassword afterwards.
      '';
    };
    hashedPassword = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Password hash (mkpasswd -m sha-512). When set, it takes precedence over password.";
    };
    rootHashedPassword = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "$6$...";
      description = ''
        Root password hash (mkpasswd -m sha-512). Needed to log into the
        Proxmox Web UI as root@pam: Proxmox allows some operations (USB/PCI
        passthrough of real devices, restoring backups that contain them)
        only to root. null = root without a password (sudo only).
        Root password login over SSH stays blocked (PermitRootLogin prohibit-password).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Passwords are managed ONLY by Nix: passwd has no permanent effect
    users.mutableUsers = false;

    users.users.${cfg.name} = {
      isNormalUser = true;
      description = cfg.description;
      hashedPassword = cfg.hashedPassword;
      password = if cfg.hashedPassword == null then cfg.password else null;
      extraGroups = [ "wheel" "networkmanager" "kvm" ];
      uid = 1000;
    };

    users.users.root.hashedPassword = lib.mkIf (cfg.rootHashedPassword != null) cfg.rootHashedPassword;

    assertions = [{
      assertion = cfg.hashedPassword != null || cfg.password != null;
      message = "my.users.localAdmin: set password or hashedPassword.";
    }];

    warnings = lib.optional (cfg.hashedPassword == null && cfg.password == "CHANGEME")
      "my.users.localAdmin uses the default password CHANGEME: change it with hashedPassword.";

    security.sudo.wheelNeedsPassword = true;
  };
}
