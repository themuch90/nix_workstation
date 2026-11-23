{ config, lib, pkgs, ... }:
{
  options.my.apps.freerdp.enable = lib.mkEnableOption "FreeRDP (xfreerdp)";

  config = lib.mkIf config.my.apps.freerdp.enable {
    environment.systemPackages = [ pkgs.freerdp ];
  };
}
