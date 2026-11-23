{ config, lib, ... }:
{
  options.my.apps.localsend.enable = lib.mkEnableOption "LocalSend";

  config = lib.mkIf config.my.apps.localsend.enable {
    programs.localsend = {
      enable = true;
      openFirewall = true;
    };
  };
}
