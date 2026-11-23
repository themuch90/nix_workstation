{ config, lib, pkgs, ... }:
{
  options.my.apps.naps2.enable = lib.mkEnableOption "NAPS2 (document scanning)";

  config = lib.mkIf config.my.apps.naps2.enable {
    environment.systemPackages = [ pkgs.naps2 ];
  };
}
