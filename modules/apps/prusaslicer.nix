{ config, lib, pkgs, ... }:
{
  options.my.apps.prusaslicer.enable = lib.mkEnableOption "PrusaSlicer (slicer for 3D printing)";

  config = lib.mkIf config.my.apps.prusaslicer.enable {
    environment.systemPackages = [ pkgs.prusa-slicer ];
  };
}
