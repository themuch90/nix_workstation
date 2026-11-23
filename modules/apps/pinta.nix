{ config, lib, pkgs, ... }:
{
  options.my.apps.pinta.enable = lib.mkEnableOption "Pinta (drawing and photo editing)";

  config = lib.mkIf config.my.apps.pinta.enable {
    environment.systemPackages = [ pkgs.pinta ];
  };
}
