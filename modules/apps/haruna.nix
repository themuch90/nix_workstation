{ config, lib, pkgs, ... }:
let
  cfg = config.my.apps.haruna;
  videoTypes = [
    "video/mp4" "video/x-matroska" "video/mpeg" "video/ogg" "video/quicktime"
    "video/vnd.avi" "video/x-msvideo" "video/mp2t" "video/webm" "video/x-ms-wmv"
  ];
in
{
  options.my.apps.haruna = {
    enable = lib.mkEnableOption "Haruna (KDE video player)";
    defaultVideo = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Opens videos with Haruna (system default; each user can change it).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.haruna ];
    xdg.mime.defaultApplications = lib.mkIf cfg.defaultVideo
      (lib.genAttrs videoTypes (_: "org.kde.haruna.desktop"));
  };
}
