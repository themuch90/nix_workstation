# Microsoft 365 with Microsoft Edge.
# - Outlook and Teams: web apps (PWA) installed via policy on Edge's first run
#   (their sites provide a manifest: icon, notifications).
# - Word, Excel, PowerPoint, OneDrive, OneNote: Microsoft offers no installable
#   PWA (Edge would create a placeholder without an icon), so they get menu
#   entries with Edge in app mode and the official icon.
{ config, lib, pkgs, ... }:
let
  cfg = config.my.apps.office365;

  apps = {
    word = { name = "Word"; url = "https://www.microsoft365.com/launch/word"; pwa = false;
             icon = "0ydg82nmgyhdg3qsvn9226gxc3n47y6ns36mwrams32g27ydgygy"; };
    excel = { name = "Excel"; url = "https://www.microsoft365.com/launch/excel"; pwa = false;
              icon = "0wcdvfrjmg4axppg6ggmm3jh6dn9bc9h12hqckk5bcws818ab4fs"; };
    powerpoint = { name = "PowerPoint"; url = "https://www.microsoft365.com/launch/powerpoint"; pwa = false;
                   icon = "110z8jsxl4fvc63zi6bkj8g5wd57r0wnmgd4hinph9dgxfgsg3vh"; };
    onedrive = { name = "OneDrive"; url = "https://www.microsoft365.com/launch/onedrive"; pwa = false;
                 icon = "0sigjqlcqj1rn5l0vgn1988xhhgalphyqypvvkj55pikki8f6grr"; };
    onenote = { name = "OneNote"; url = "https://www.microsoft365.com/launch/onenote"; pwa = false;
                icon = "1v53js7vilhqy1a4drw013516mv2rfvbh3v44g6lgzs7nmari9xj"; };
    outlook = { name = "Outlook"; url = "https://outlook.cloud.microsoft/mail/"; pwa = true; };
    teams = { name = "Teams"; url = "https://teams.microsoft.com/v2/"; pwa = true; };
  };

  selected = lib.genAttrs cfg.apps (a: apps.${a});
  pwas = lib.filterAttrs (_: a: a.pwa) selected;
  shortcuts = lib.filterAttrs (_: a: !a.pwa) selected;

  launchers = pkgs.runCommand "m365-launchers" { } (lib.concatStrings (lib.mapAttrsToList (id: a:
    let
      icon = pkgs.fetchurl {
        name = "m365-${id}.svg";
        url = "https://res-1.cdn.office.net/files/fabric-cdn-prod_20230815.002/assets/brand-icons/product/svg/${id}_48x1.svg";
        sha256 = a.icon;
      };
      desktop = pkgs.makeDesktopItem {
        name = "m365-${id}";
        desktopName = a.name;
        genericName = "Microsoft 365";
        # --class: the panel groups the window under this entry
        exec = "${pkgs.microsoft-edge}/bin/microsoft-edge --class=m365-${id} --app=${a.url}";
        icon = "m365-${id}";
        startupWMClass = "m365-${id}";
        categories = [ "Office" ];
      };
    in ''
      install -Dm644 ${icon} $out/share/icons/hicolor/scalable/apps/m365-${id}.svg
      install -Dm644 ${desktop}/share/applications/m365-${id}.desktop $out/share/applications/m365-${id}.desktop
    '') shortcuts));

  policy = builtins.toJSON ({
    WebAppInstallForceList = lib.mapAttrsToList (_: a: {
      url = a.url;
      default_launch_container = "window";
      fallback_app_name = a.name;
      create_desktop_shortcut = false;
    }) pwas;

    BrowserSignin = 1;
    HideFirstRunExperience = true;
    ShowRecommendationsEnabled = false;
    PersonalizationReportingEnabled = false;
    DiagnosticData = 0;
  } // lib.optionalAttrs (!cfg.defaultBrowser) {
    DefaultBrowserSettingEnabled = false;
  });
in
{
  options.my.apps.office365 = {
    enable = lib.mkEnableOption "Microsoft 365 (via Microsoft Edge)";

    apps = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames apps));
      default = [ "word" "excel" "powerpoint" "outlook" "teams" "onedrive" ];
      description = "Microsoft 365 apps in every user's menu.";
    };

    defaultBrowser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "true = Edge may offer itself as the default browser; false = Firefox stays the default.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.microsoft-edge launchers ];

    # the nixpkgs package reads /etc/opt/edge/policies (check: edge://policy);
    # the copy in the Microsoft path guards against a future package change
    environment.etc."opt/edge/policies/managed/office365.json".text = policy;
    environment.etc."opt/microsoft/msedge/policies/managed/office365.json".text = policy;
  };
}
