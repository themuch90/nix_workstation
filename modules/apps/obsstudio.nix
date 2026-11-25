{ config, lib, ... }:
{
  options.my.apps.obsstudio.enable = lib.mkEnableOption "OBS Studio (screen recording and streaming)";

  config = lib.mkIf config.my.apps.obsstudio.enable {
    programs.obs-studio.enable = true;
  };
}
