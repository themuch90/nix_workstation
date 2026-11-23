# Plasma 6 + SDDM. "Windows-style" login: user list hidden, so the user field
# is prefilled with the last login (domain users too).
{ config, lib, pkgs, ... }:
let
  cfg = config.my.desktop.plasma;
  localAdmin = config.my.users.localAdmin;
in
{
  options.my.desktop.plasma = {
    enable = lib.mkEnableOption "KDE Plasma 6 desktop";

    showUserList = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        false = Windows-style screen (user field with the last user).
        true  = show the list of local users with avatars.
      '';
    };

    dolphinDetailsView = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Dolphin uses the Details view for all folders (default for every user).";
    };

    wifiForAllUsers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        New Wi-Fi networks created by Plasma are "system" connections: available
        to all users and with the password stored outside the wallet, so they
        already connect at the login screen (SDDM has no Wi-Fi selector).
      '';
    };

    numlock = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Num Lock on at boot (login, KDE session and console).";
    };

    raiseNewWindows = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        A program opened by another one (browser from a link, player from a
        video, viewer from a photo) comes to the foreground instead of flashing
        in the taskbar: KWin focus stealing prevention set to "None".
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.xserver.enable = true;            # XWayland/X11: needed by xfreerdp
    services.desktopManager.plasma6.enable = true;

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
      settings = {
        Users = {
          RememberLastUser = true;
          RememberLastSession = true;
          HideUsers = lib.optionalString (!cfg.showUserList && localAdmin.enable) localAdmin.name;
          MaximumUid = if cfg.showUserList then 60513 else 999;
        };
      };
      autoNumlock = cfg.numlock;
    };

    # Num Lock for KWin (SDDM greeter and sessions): 0 = on, 1 = off, 2 = unchanged
    environment.etc."xdg/kcminputrc" = lib.mkIf cfg.numlock {
      text = ''
        [Keyboard]
        NumLock=0
      '';
    };

    # system default for KWin; each user can change it in
    # Settings > Window Management > Window Behavior > Focus
    environment.etc."xdg/kwinrc" = lib.mkIf cfg.raiseNewWindows {
      text = ''
        [Windows]
        FocusStealingPreventionLevel=0
      '';
    };

    # Wi-Fi: new connections are system-wide (plasma-nm default for every user)
    environment.etc."xdg/plasma-nm" = lib.mkIf cfg.wifiForAllUsers {
      text = ''
        [General]
        SystemConnectionsByDefault=true
      '';
    };
    # saving a system connection requires an administrator: allow it for
    # whoever is physically at the PC (active local session), so that
    # non-admin AD users can add networks too
    security.polkit.extraConfig = lib.mkIf cfg.wifiForAllUsers ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.NetworkManager.settings.modify.system"
            && subject.local && subject.active) {
          return polkit.Result.YES;
        }
      });
    '';

    # Dolphin: same view for all folders
    environment.etc."xdg/dolphinrc" = lib.mkIf cfg.dolphinDetailsView {
      text = ''
        [General]
        GlobalViewProps=true
      '';
    };
    # the global view lives in the user profile: at login create it in Details
    # if it does not exist (the user's choices are kept)
    systemd.user.services.dolphin-details-view = lib.mkIf cfg.dolphinDetailsView {
      description = "Default Details view for Dolphin";
      wantedBy = [ "default.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        d="$HOME/.local/share/dolphin/view_properties/global"
        if [ ! -f "$d/.directory" ]; then
          mkdir -p "$d"
          cat > "$d/.directory" <<'EOF'
        [Dolphin]
        Version=4
        ViewMode=1
        VisibleRoles=Details_text,Details_size,Details_modificationtime,Details_type,CustomizedDetails
        EOF
        fi
      '';
    };

    # Num Lock on the text consoles (Ctrl+Alt+F1...F6)
    systemd.services.numlock-console = lib.mkIf cfg.numlock {
      description = "Num Lock on for the consoles";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-vconsole-setup.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        for tty in /dev/tty[1-6]; do
          ${pkgs.kbd}/bin/setleds -D +num < "$tty" || true
        done
      '';
    };

    environment.plasma6.excludePackages = with pkgs.kdePackages; [
      elisa
      kmahjongg
    ];

    environment.systemPackages = with pkgs.kdePackages; [
      kate
      ark
      spectacle
      filelight
      kcalc
      partitionmanager
      sddm-kcm
    ];

    programs.kdeconnect.enable = true;

    services.printing.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };
    security.rtkit.enable = true;

    fonts.packages = with pkgs; [ noto-fonts noto-fonts-color-emoji liberation_ttf ];
  };
}
