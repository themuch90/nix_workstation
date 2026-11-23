{ config, lib, ... }:
{
  options.my.apps.firefox.enable = lib.mkEnableOption "Firefox";

  config = lib.mkIf config.my.apps.firefox.enable {
    programs.firefox = {
      enable = true;
      languagePacks = [ "it" ];
      policies = {
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        # Kerberos SSO to the domain's intranet sites (like IE/Edge on Windows)
        Authentication = lib.mkIf config.my.activeDirectory.enable {
          SPNEGO = [ ".${config.my.activeDirectory.domain}" ];
          Delegated = [ ".${config.my.activeDirectory.domain}" ];
        };
      };
    };
  };
}
