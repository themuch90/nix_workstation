# app-manager: enables or disables the applications of this PC (my.apps.*
# and VM Station) after the installation, without editing the file by hand.
#   sudo app-manager                      check list (also in nix-tools)
#   sudo app-manager list                 state of every application
#   sudo app-manager enable KEY...        e.g. sudo app-manager enable pinta
#   sudo app-manager disable KEY...
# It changes the "enable" lines in hosts/<pc>/default.nix, checks the result
# with nix eval, applies with nixos-rebuild switch and, only if that works,
# commits and pushes the PC repository (like config-update).
{ config, lib, pkgs, options, flakeHost, ... }:
let
  cfg = config.my.maintenance.appManager;
  ucfg = config.my.maintenance.updateCheck;
  inherit (import ./git-fns.nix { inherit lib; cfg = ucfg; }) gitLogin baseFns sessionFns;

  # "key|description": every my.apps.* module, plus VM Station
  describe = o: lib.removeSuffix "." (lib.removePrefix "Whether to enable " (o.description or ""));
  appList = pkgs.writeText "app-manager-apps" (lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: o: "${n}|${describe o.enable}") options.my.apps
    ++ lib.optional (options.my ? vmstation) "my.vmstation|${describe options.my.vmstation.enable}"));

  appManager = pkgs.writeShellApplication {
    name = "app-manager";
    runtimeInputs = [ pkgs.nix pkgs.python3 pkgs.newt ] ++ (with pkgs; [ git jq coreutils gnused gnugrep util-linux getent libsecret ]);
    text = ''
      if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo"; exit 1; fi
      # whiptail buttons in English
      unset LC_ALL LANGUAGE; export LC_MESSAGES=C.UTF-8
      FLAKE="${ucfg.flakePath}"
      HOST="${flakeHost}"
      HOSTFILE="hosts/$HOST/default.nix"
      TITLE="app-manager · $(hostname)"
      cd "$FLAKE"
      ${gitLogin}
      ${baseFns}
      ${sessionFns}
      [ -f "$HOSTFILE" ] || { echo "$FLAKE/$HOSTFILE not found"; exit 1; }
      if ! git config --global --get-all safe.directory | grep -qx "$FLAKE"; then
        git config --global --add safe.directory "$FLAKE"
      fi

      APPS=$(cat ${appList})
      label() {   # key -> name shown to the user (my.vmstation -> vmstation)
        echo "''${1#my.}"
      }
      key_of() {   # name typed by the user -> key
        local k
        while IFS='|' read -r k _; do
          if [ "$1" = "$k" ] || [ "$1" = "$(label "$k")" ]; then echo "$k"; return 0; fi
        done <<<"$APPS"
        return 1
      }

      # state in the configuration files (also changes not applied yet)
      read_state() {
        nix --extra-experimental-features 'nix-command flakes' eval --json \
          --option allow-import-from-derivation false \
          ".#nixosConfigurations.\"$HOST\".config" --apply '
            c: builtins.mapAttrs (n: v: v.enable or false) c.my.apps
               // (if c.my ? vmstation then { "my.vmstation" = c.my.vmstation.enable; } else { })'
      }
      is_on() { jq -e --arg k "$1" '.[$k] == true' <<<"$STATE" >/dev/null; }

      list() {
        local k d
        printf '%-14s %-4s %s\n' APPLICATION ON DESCRIPTION
        while IFS='|' read -r k d; do
          printf '%-14s %-4s %s\n' "$(label "$k")" "$(is_on "$k" && echo yes || echo no)" "$d"
        done <<<"$APPS"
      }

      # apply KEY=true|false ...: edit, check, rebuild, commit, push
      apply() {
        local want msg msg_on="" msg_off="" a k v
        BACKUP=$(mktemp) ERRS=$(mktemp)
        cp "$HOSTFILE" "$BACKUP"
        # any exit before the end (error, Ctrl+C) puts the file back
        trap 'cp "$BACKUP" "$HOSTFILE"; rm -f "$BACKUP" "$ERRS" "$TMP_CRED" "$CAP"' EXIT
        python3 ${./app-set.py} "$HOSTFILE" "$@"
        echo ">> Checking the configuration..."
        if ! STATE=$(read_state 2>"$ERRS"); then
          cat "$ERRS"
          echo "!! The configuration does not evaluate: $HOSTFILE restored, nothing changed."; exit 1
        fi
        for a in "$@"; do
          k=''${a%%=*} v=''${a#*=}
          want=$(jq -r --arg k "$k" '.[$k]' <<<"$STATE")
          if [ "$want" != "$v" ]; then
            echo "!! $(label "$k") is $want instead of $v (set elsewhere in $HOSTFILE?):"
            echo "   file restored, nothing changed. Edit it with: sudo nix-tools -> Edit this PC's configuration"
            exit 1
          fi
          if [ "$v" = true ]; then msg_on="$msg_on $(label "$k")"; else msg_off="$msg_off $(label "$k")"; fi
        done
        git --no-pager diff -- "$HOSTFILE" | sed 's/^/   /'
        echo ">> Applying (nixos-rebuild switch)..."
        if ! nixos-rebuild switch --flake ".#$HOST"; then
          echo "!! nixos-rebuild failed: $HOSTFILE restored, the system is unchanged."; exit 1
        fi
        # applied: from here on the change stays
        trap 'rm -f "$BACKUP" "$ERRS" "$TMP_CRED" "$CAP"' EXIT
        restart_plasma
        "''${G[@]}" add "$HOSTFILE"
        msg="''${msg_on:+enabled$msg_on}"
        if [ -n "$msg_off" ]; then msg="''${msg:+$msg; }disabled$msg_off"; fi
        "''${G[@]}" commit -q -m "apps: $msg" -- "$HOSTFILE"
        if has_base; then push_local; fi
        echo ">> Done.''${msg_on:+ Enabled:$msg_on.}''${msg_off:+ Disabled:$msg_off.}"
      }

      echo ">> Reading the configuration of $HOST..."
      ERRS0=$(mktemp)
      if ! STATE=$(read_state 2>"$ERRS0"); then
        cat "$ERRS0"; rm -f "$ERRS0"
        echo "!! Cannot evaluate the configuration in $FLAKE."; exit 1
      fi
      rm -f "$ERRS0"

      case "''${1:-}" in
        list) list; exit 0 ;;
        enable|disable)
          v=$([ "$1" = enable ] && echo true || echo false); shift
          [ $# -gt 0 ] || { echo "Usage: sudo app-manager $([ "$v" = true ] && echo enable || echo disable) KEY..."; exit 1; }
          args=()
          for n in "$@"; do
            k=$(key_of "$n") || { echo "Unknown application: $n (see: sudo app-manager list)"; exit 1; }
            if { [ "$v" = true ] && ! is_on "$k"; } || { [ "$v" = false ] && is_on "$k"; }; then
              args+=("$k=$v")
            else
              echo "   $(label "$k"): already $([ "$v" = true ] && echo enabled || echo disabled)"
            fi
          done
          [ ''${#args[@]} -gt 0 ] || { echo "Nothing to change."; exit 0; }
          apply "''${args[@]}"; exit 0 ;;
        "") ;;
        *) echo "Usage: sudo app-manager [list | enable KEY... | disable KEY...]"; exit 1 ;;
      esac

      # interactive check list
      items=()
      while IFS='|' read -r k d; do
        items+=("$(label "$k")" "$d" "$(is_on "$k" && echo ON || echo OFF)")
      done <<<"$APPS"
      sel=$(whiptail --title "$TITLE" --separate-output --checklist \
            "Applications of this PC (Space = check, Enter = confirm, Esc = cancel)" \
            24 90 16 "''${items[@]}" 3>&1 1>&2 2>&3) || { clear; echo "Cancelled: nothing changed."; exit 0; }
      clear
      args=() summary=""
      while IFS='|' read -r k _; do
        if grep -qx "$(label "$k")" <<<"$sel"; then
          is_on "$k" || { args+=("$k=true"); summary="$summary\n  + $(label "$k")"; }
        else
          ! is_on "$k" || { args+=("$k=false"); summary="$summary\n  - $(label "$k")"; }
        fi
      done <<<"$APPS"
      [ ''${#args[@]} -gt 0 ] || { echo "Nothing to change."; exit 0; }
      note=""
      case " ''${args[*]} " in *" solidcraft=true "*|*" bambustudio=true "*)
        note="\n\nSolidCraft and Bambu Studio are compiled on this PC: the first build takes a long time." ;; esac
      whiptail --title "$TITLE" --yesno "Changes (+ enable, - disable):$summary$note\n\nApply now?" 20 70 ||
        { clear; echo "Cancelled: nothing changed."; exit 0; }
      clear
      apply "''${args[@]}"
    '';
  };
in
{
  options.my.maintenance.appManager.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "'sudo app-manager' command to enable or disable the applications of this PC.";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ appManager ];
  };
}
