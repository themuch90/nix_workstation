# nix-tools: text menu with all the system management commands
# (updates, rollback and version choice, cleanup, diagnostics,
# AD domain, services, network). Usage: sudo nix-tools
{ config, lib, pkgs, flakeHost, ... }:
let
  cfg = config.my.maintenance.nixTools;
  flakePath = config.my.maintenance.updateCheck.flakePath;
  domain = if config.my.activeDirectory.enable then config.my.activeDirectory.domain else "";

  nixTools = pkgs.writeShellApplication {
    name = "nix-tools";
    runtimeInputs = with pkgs; [ newt coreutils gnugrep gnused gawk git systemd nano less ];
    text = ''
      # interactive menu: a failed command or a "No" must not close the menu
      set +o errexit
      # Ctrl+C interrupts the running command, not the menu
      trap ':' INT

      FLAKE="${flakePath}"
      HOST="${flakeHost}"
      DOMAIN="${domain}"
      PROFILE=/nix/var/nix/profiles/system
      TITLE="nix-tools · $(hostname)"

      if [ "$(id -u)" -ne 0 ]; then
        echo "Run with: sudo nix-tools"; exit 1
      fi
      # menus in English also when the system language is another one: the
      # whiptail buttons and the programs started from here (nmtui...)
      unset LC_ALL LANGUAGE; export LC_MESSAGES=C.UTF-8

      pause() { echo; read -r -p "Press Enter to return to the menu... " _; }

      have() { command -v "$1" >/dev/null 2>&1; }

      run() {
        # runs a command showing it, then waits for Enter
        local rc=0
        clear
        echo "\$ $*"; echo
        "$@" || rc=$?
        echo; echo "(done, exit code $rc)"
        pause
      }

      tool() {
        # repository command: if missing, its module is disabled
        if have "$1"; then run "$@"
        else whiptail --title "$TITLE" --msgbox "The command '$1' is not installed (module disabled in the configuration)." 9 70
        fi
      }

      confirm() { whiptail --title "$TITLE" --yesno "$1" 12 74; }

      current_gen() { readlink "$PROFILE" | sed -E 's/.*system-([0-9]+)-link/\1/'; }

      switch_gen() {
        local n="$1"
        clear
        echo "\$ activating version $n"; echo
        if nix-env -p "$PROFILE" --switch-generation "$n" \
           && "$PROFILE/bin/switch-to-configuration" switch; then
          echo; echo "Version $n active, also on the next boots."
        else
          echo; echo "Activation failed."
        fi
        pause
      }

      rollback() {
        local cur prev
        cur=$(current_gen)
        prev=$(nix-env -p "$PROFILE" --list-generations | awk -v c="$cur" '$1 < c {p=$1} END {print p}')
        if [ -z "$prev" ]; then
          whiptail --title "$TITLE" --msgbox "There is no version older than $cur." 8 60; return
        fi
        confirm "Go back from version $cur to the previous version $prev?\n\nThe configuration in $FLAKE does not change: it will be applied again at the next update." \
          && switch_gen "$prev"
      }

      choose_gen() {
        local cur items=() n d t
        cur=$(current_gen)
        while read -r n d t _; do
          if [ "$n" = "$cur" ]; then items+=("$n" "$d $t  ◀ current")
          else items+=("$n" "$d $t"); fi
        done < <(nix-env -p "$PROFILE" --list-generations | sort -rn)
        n=$(whiptail --title "$TITLE" --menu "System versions (newest first). Choose the one to activate:" 22 70 14 \
              "''${items[@]}" 3>&1 1>&2 2>&3) || return
        [ "$n" = "$cur" ] && { whiptail --title "$TITLE" --msgbox "Version $n is already the active one." 8 50; return; }
        confirm "Activate version $n (current: $cur)?" && switch_gen "$n"
      }

      diagnosis() {
        clear
        echo "== Failed services =="; systemctl --failed --no-pager; echo
        echo "== Errors of this boot (last 40) =="
        journalctl -b -p err --no-pager -o short | tail -40
        echo; echo "== Active version: $(current_gen)  ·  booted: $(uptime -s)"
        pause
      }

      sssd_restart() {
        run bash -c 'systemctl reset-failed nscd sssd; systemctl restart nscd sssd; sleep 2; systemctl is-active nscd sssd'
      }

      sssd_cache() {
        confirm "Clear the SSSD cache?\n\nAD users and groups will be read again from the domain (the company network is required). Passwords for offline login are kept." \
          && run bash -c 'sss_cache -E; systemctl restart sssd; echo "Cache invalidated."'
      }

      ad_join() {
        local u
        u=$(whiptail --title "$TITLE" --inputbox "AD user with join rights:" 9 60 "administrator" 3>&1 1>&2 2>&3) || return
        tool ad-join "$u"
      }

      ad_user() {
        local u
        u=$(whiptail --title "$TITLE" --inputbox "AD user to check (groups and sudo):" 9 60 3>&1 1>&2 2>&3) || return
        # shellcheck disable=SC2016  # $1 is expanded by the inner bash
        [ -n "$u" ] && run bash -c 'id "$1" && echo && sudo -l -U "$1"' _ "$u"
      }

      dm_restart() {
        confirm "Restart the login screen?\n\nALL open graphical sessions will be closed (unsaved work is lost). Useful if the screen stays black." \
          && systemctl restart display-manager
      }

      edit_host() {
        nano "$FLAKE/hosts/$HOST/default.nix"
        if confirm "Apply the changes now (nixos-rebuild switch)?"; then
          git -C "$FLAKE" add -A
          run nixos-rebuild switch --flake "$FLAKE#$HOST"
        fi
      }

      git_status() {
        clear
        echo "== $FLAKE =="; git -C "$FLAKE" status -sb; echo
        echo "== Latest commits =="; git -C "$FLAKE" log --oneline -15
        pause
      }

      while true; do
        choice=$(whiptail --title "$TITLE" --menu "Active version: $(current_gen)   ·   Esc = exit" 32 78 24 \
          "─1" "──────── UPDATES ────────" \
          "u1" "Update the configuration from git (config-update)" \
          "u2" "Check for package updates (update-check)" \
          "u3" "Update the packages (system-update)" \
          "u4" "Apply the local configuration (rebuild)" \
          "u5" "Try the configuration without making it permanent" \
          "─2" "──────── VERSIONS ────────" \
          "v1" "Rollback: go back to the previous version" \
          "v2" "Choose a version to activate" \
          "v3" "Delete old versions (system-clean)" \
          "─3" "──────── DIAGNOSTICS ────────" \
          "d1" "Failed services and log of this boot" \
          "d2" "Driver and firmware check (driver-check)" \
          "d3" "Live log (Ctrl+C to exit)" \
          "─4" "──────── AD DOMAIN ────────" \
          "a1" "Domain status (ad-status)" \
          "a2" "Check an AD user (groups and sudo)" \
          "a3" "Restart SSSD and nscd" \
          "a4" "Clear the SSSD cache" \
          "a5" "Join the PC to the domain (ad-join)" \
          "─5" "──────── SYSTEM ────────" \
          "s1" "Network and Wi-Fi (nmtui)" \
          "s2" "Enable or disable applications (app-manager)" \
          "s3" "Edit this PC's configuration" \
          "s4" "Configuration repository status" \
          "s5" "Repository URLs: generic and this PC's (repo-urls)" \
          "s6" "Restart the login screen (black screen)" \
          "s7" "Reboot the PC" \
          "s8" "Shut down the PC" \
          3>&1 1>&2 2>&3) || { clear; exit 0; }

        case "$choice" in
          u1) tool config-update ;;
          u2) tool update-check ;;
          u3) tool system-update ;;
          u4) git -C "$FLAKE" add -A; run nixos-rebuild switch --flake "$FLAKE#$HOST" ;;
          u5) git -C "$FLAKE" add -A; run nixos-rebuild test --flake "$FLAKE#$HOST" ;;
          v1) rollback ;;
          v2) choose_gen ;;
          v3) tool system-clean ;;
          d1) diagnosis ;;
          d2) tool driver-check ;;
          d3) clear; echo "Ctrl+C to return to the menu"; journalctl -f -n 30 ;;
          a1) if [ -n "$DOMAIN" ]; then tool ad-status; else whiptail --title "$TITLE" --msgbox "Active Directory is not enabled." 8 50; fi ;;
          a2) ad_user ;;
          a3) sssd_restart ;;
          a4) sssd_cache ;;
          a5) ad_join ;;
          s1) nmtui || true ;;
          s2) if have app-manager; then clear; app-manager; pause
              else tool app-manager; fi ;;
          s3) edit_host ;;
          s4) git_status ;;
          s5) if have repo-urls; then clear; repo-urls; pause
              else tool repo-urls; fi ;;
          s6) dm_restart ;;
          s7) confirm "Reboot the PC now?" && systemctl reboot ;;
          s8) confirm "Shut down the PC now?" && systemctl poweroff ;;
          *) ;;   # header rows
        esac
      done
    '';
  };
in
{
  options.my.maintenance.nixTools.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "'sudo nix-tools' menu with the system management commands.";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ nixTools ];
  };
}
