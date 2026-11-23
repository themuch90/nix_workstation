{ config, lib, pkgs, ... }:
{
  options.my.apps.whatsapp.enable = lib.mkEnableOption "WhatsApp client";

  config = lib.mkIf config.my.apps.whatsapp.enable {
    # no official client: ZapZap is WhatsApp Web in a Qt app
    environment.systemPackages = [ pkgs.zapzap ];
  };
}
