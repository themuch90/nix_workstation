{ config, lib, pkgs, ... }:
{
  options.my.apps.onlyoffice.enable = lib.mkEnableOption "ONLYOFFICE Desktop Editors";

  config = lib.mkIf config.my.apps.onlyoffice.enable {
    environment.systemPackages = [ pkgs.onlyoffice-desktopeditors ];
    # Microsoft-compatible fonts for Office documents
    fonts.packages = with pkgs; [ corefonts vista-fonts ];
  };
}
