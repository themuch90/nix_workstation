# SolidCraft: 3D parametric CAD (https://github.com/tangency-labs/solidcraft).
# Built from source (no binary cache): the first rebuild and the ones after
# a SolidCraft update take a while.
{ config, lib, pkgs, inputs, ... }:
{
  options.my.apps.solidcraft.enable = lib.mkEnableOption "SolidCraft (3D parametric CAD)";

  config = lib.mkIf config.my.apps.solidcraft.enable {
    environment.systemPackages = [
      inputs.solidcraft.packages.${pkgs.stdenv.hostPlatform.system}.solidcraft
    ];
    # renders on the GPU through the system drivers (/run/opengl-driver)
    hardware.graphics.enable = true;
  };
}
