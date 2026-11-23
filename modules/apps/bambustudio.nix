# Bambu Studio: slicer for Bambu Lab 3D printers (https://github.com/bambulab/BambuStudio).
# AGPL with a proprietary network plugin: nixpkgs marks it unfree, so it is not
# in cache.nixos.org and is compiled on the PC (slow first rebuild).
{ config, lib, pkgs, ... }:
{
  options.my.apps.bambustudio.enable = lib.mkEnableOption "Bambu Studio (slicer for Bambu Lab 3D printers)";

  config = lib.mkIf config.my.apps.bambustudio.enable {
    environment.systemPackages = [ pkgs.bambu-studio ];
  };
}
