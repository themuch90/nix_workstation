# Active Directory: SSSD + Kerberos, join with adcli (sudo ad-join <AD-admin>),
# cached credentials for logging in off the network, home created at first login.
{ config, lib, pkgs, ... }:
let
  cfg = config.my.activeDirectory;
  realm = if cfg.realm != null then cfg.realm else lib.toUpper cfg.domain;
  hasDCs = cfg.domainControllers != [ ];
  useSimpleAccess = cfg.allowedGroups != [ ];

  # "domain admins" -> "%domain\ admins" (sudoers syntax)
  sudoGroupLine = g: "%${lib.replaceStrings [ " " ] [ "\\ " ] g} ALL=(ALL:ALL) ALL";

  adJoin = pkgs.writeShellApplication {
    name = "ad-join";
    runtimeInputs = with pkgs; [ adcli krb5 coreutils inetutils systemd ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo"; exit 1; fi
      ADMIN="''${1:-}"
      if [ -z "$ADMIN" ]; then
        echo "Usage: sudo ad-join <AD-user-with-join-rights> [OU]"
        echo "  e.g.: sudo ad-join administrator \"OU=Computers,OU=Site,DC=example,DC=local\""
        exit 1
      fi
      OU="''${2:-}"
      HOST="$(hostname -s)"
      echo ">> Joining $HOST to domain ${cfg.domain} (realm ${realm}) as $ADMIN"
      ARGS=(--domain=${cfg.domain} --domain-realm=${realm}
            --host-fqdn="$HOST.${cfg.domain}" --login-user="$ADMIN"
            --os-name=NixOS --verbose)
      if [ -n "$OU" ]; then ARGS+=(--domain-ou="$OU"); fi
      ${lib.optionalString hasDCs ''ARGS+=(--domain-controller=${lib.head cfg.domainControllers})''}
      adcli join "''${ARGS[@]}"
      chmod 600 /etc/krb5.keytab
      systemctl restart sssd
      echo ">> Done. Check with: ad-status"
    '';
  };

  adStatus = pkgs.writeShellApplication {
    name = "ad-status";
    runtimeInputs = with pkgs; [ adcli sssd ];
    text = ''
      echo "== Join test (adcli testjoin) =="
      sudo adcli testjoin --domain=${cfg.domain} || true
      echo; echo "== SSSD domain status =="
      sudo sssctl domain-status ${cfg.domain} || true
      echo; echo "Tip: 'id <user>' checks that an AD user resolves"
    '';
  };

  adLeave = pkgs.writeShellApplication {
    name = "ad-leave";
    runtimeInputs = with pkgs; [ adcli systemd ];
    text = ''
      ADMIN="''${1:?Usage: sudo ad-leave <AD-admin-user>}"
      adcli delete-computer --domain=${cfg.domain} --login-user="$ADMIN"
      rm -f /etc/krb5.keytab
      systemctl restart sssd
    '';
  };
in
{
  options.my.activeDirectory = {
    enable = lib.mkEnableOption "Active Directory integration (SSSD)";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "example.local";
      description = "DNS name of the AD domain (lowercase).";
    };

    realm = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kerberos realm. Default: domain in uppercase.";
    };

    domainControllers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Explicit DCs. Empty = automatic discovery via DNS (SRV records).";
    };

    sudoGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "domain admins" ];
      description = "AD groups with sudo rights.";
    };

    sudoUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "john.doe" ];
      description = "Individual AD users with sudo rights (lowercase name, as shown by 'id').";
    };

    allowedGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "If not empty, only these AD groups can log in. Empty = AD/GPO rules.";
    };

    offlineDays = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Days cached credentials stay valid off the network (0 = unlimited, like Windows).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ adJoin adStatus adLeave pkgs.adcli pkgs.sssd pkgs.krb5 ];

    security.krb5 = {
      enable = true;
      settings = {
        libdefaults = {
          default_realm = realm;
          dns_lookup_realm = true;
          dns_lookup_kdc = true;
          rdns = false;
          forwardable = true;
          ticket_lifetime = "24h";
          renew_lifetime = "7d";
          udp_preference_limit = 0;
        };
        realms = lib.mkIf hasDCs {
          ${realm} = {
            kdc = cfg.domainControllers;
            admin_server = lib.head cfg.domainControllers;
          };
        };
        domain_realm = {
          ${cfg.domain} = realm;
          ".${cfg.domain}" = realm;
        };
      };
    };

    services.sssd = {
      enable = true;
      config = ''
        [sssd]
        config_file_version = 2
        services = nss, pam
        domains = ${cfg.domain}

        [nss]
        # cached user data stays valid off the network
        entry_negative_timeout = 15

        [pam]
        # days the offline login stays valid (0 = forever)
        offline_credentials_expiration = ${toString cfg.offlineDays}
        offline_failed_login_attempts = 5
        offline_failed_login_delay = 5

        [domain/${cfg.domain}]
        id_provider = ad
        auth_provider = ad
        chpass_provider = ad
        access_provider = ${if useSimpleAccess then "simple" else "ad"}
        ${lib.optionalString useSimpleAccess "simple_allow_groups = ${lib.concatStringsSep ", " cfg.allowedGroups}"}
        ad_domain = ${cfg.domain}
        krb5_realm = ${realm}
        ${lib.optionalString hasDCs "ad_server = ${lib.concatStringsSep ", " cfg.domainControllers}"}

        cache_credentials = true
        krb5_store_password_if_offline = true
        account_cache_expiration = 0
        entry_cache_timeout = 5400

        use_fully_qualified_names = false
        # plain name only ("jdoe"): with "DOMAIN\user" SSSD would accept the
        # password but systemd-logind rejects a name containing "\" and the
        # session stays black; this way the login fails right away and clearly
        re_expression = (?P<name>[^\\@]+)
        fallback_homedir = /home/%u
        default_shell = /run/current-system/sw/bin/bash
        ldap_id_mapping = true
        enumerate = false

        # Windows logon GPOs do not block the Linux login
        ad_gpo_access_control = permissive

        dyndns_update = true
        dyndns_refresh_interval = 43200
      '';
    };

    security.pam.services = lib.genAttrs [ "login" "sddm" "sshd" "su" "sudo" ] (_: {
      makeHomeDir = true;
    });

    # security.krb5.enable automatically enables pam_krb5 + pam_ccreds in all
    # PAM services. With SSSD they are useless (SSSD handles Kerberos and the
    # offline cache) and harmful: in the KDE screen locker pam_ccreds has
    # [default=die] and its helper is missing, so the password is rejected after suspend.
    security.pam.krb5.enable = false;

    # At boot nscd is restarted several times in a row (resolv.conf updates):
    # without this systemd blocks it (start-limit-hit) and SSSD, which
    # requires it, does not start -> "id user: no such user".
    # (SSSD already has its own limits/restarts in the NixOS module)
    systemd.services.nscd.startLimitIntervalSec = 0;

    security.sudo.extraConfig =
      lib.concatMapStrings (g: sudoGroupLine g + "\n") cfg.sudoGroups
      + lib.concatMapStrings (u: "${lib.replaceStrings [ " " ] [ "\\ " ] u} ALL=(ALL:ALL) ALL\n") cfg.sudoUsers;

    # Kerberos tolerates at most 5 minutes of clock skew with the DC
    networking.timeServers = cfg.domainControllers ++ [ "0.nixos.pool.ntp.org" "1.nixos.pool.ntp.org" ];

  };
}
