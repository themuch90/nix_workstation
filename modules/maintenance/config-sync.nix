# config-sync: keeps this PC aligned with its repository on the git server.
# Change hosts/<pc>/default.nix on the server (e.g. onlyoffice.enable = true)
# and the PC applies it by itself, or right away with remote-update.
#   sudo config-sync           only if the PC repository has new commits (timer)
#   sudo config-sync --force   always (used by remote-update)
#   remote-update pc01 pc02    from the admin's PC: ssh + sudo config-sync --force
# It runs config-update; when that works it keeps the current version and the
# previous ones (updateCheck.keepPrevious, at least 2), deletes the older ones, frees the
# disk space and notifies the logged-in users. If it fails the system stays
# as it was and the same commit is not tried again (no loop): the next
# commit, or --force, tries again.
# Unattended runs need the login in my.maintenance.updateCheck.gitCredentialsFile
# (a token with access to this PC's repository and to the generic one).
{ config, lib, pkgs, ... }:
let
  cfg = config.my.maintenance.configSync;
  ucfg = config.my.maintenance.updateCheck;
  inherit (import ./git-fns.nix { inherit lib; cfg = ucfg; }) gitLogin cleanFns;
  notifyArgs = "-a NixOS -i system-software-update";

  configSync = pkgs.writeShellApplication {
    name = "config-sync";
    # config-update and nixos-rebuild come from the system
    runtimeInputs = with pkgs; [ nix git coreutils gnugrep gnused util-linux getent libsecret libnotify ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo"; exit 1; fi
      export PATH="$PATH:/run/current-system/sw/bin"
      FORCE=0
      [ "''${1:-}" = "--force" ] && FORCE=1
      FLAKE="${ucfg.flakePath}"
      STATE=/var/lib/config-sync
      mkdir -p "$STATE"
      cd "$FLAKE"
      ${gitLogin}
      ${cleanFns}
      if ! git config --global --get-all safe.directory | grep -qx "$FLAKE"; then
        git config --global --add safe.directory "$FLAKE"
      fi

      notify() {   # notify TITLE BODY: every graphical session
        local bus uid
        for bus in /run/user/*/bus; do
          [ -S "$bus" ] || continue
          uid=$(basename "$(dirname "$bus")")
          setpriv --reuid="$uid" --regid="$(id -g "$uid")" --init-groups \
            env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            notify-send ${notifyArgs} "$1" "$2" 2>/dev/null || true
        done
      }

      # 1. anything new on the server?
      url=$(git remote get-url origin)
      branch=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || {
        echo "!! The configuration folder has no upstream branch: nothing to sync."; exit 1; }
      branch=''${branch#*/}
      if ! git_login "$url" || ! git fetch -q origin; then
        echo "!! Cannot read $url (no network or no login: set gitCredentialsFile)."; exit 1
      fi
      remote=$(git rev-parse "origin/$branch")
      if [ "$FORCE" -eq 0 ]; then
        if git merge-base --is-ancestor "$remote" HEAD; then
          echo ">> Already aligned with $url ($(git rev-parse --short HEAD))."; exit 0
        fi
        if [ "$(cat "$STATE/failed" 2>/dev/null)" = "$remote" ]; then
          echo ">> Commit ''${remote:0:7} already failed: waiting for a new commit (or config-sync --force)."; exit 0
        fi
      fi
      news=$(git log --format='• %s' "HEAD..$remote" | grep -v 'flake.lock' || true)

      # 2. apply (config-update: rebase, generic configuration, rebuild, push)
      echo ">> Aligning with $url..."
      if ! config-update </dev/null; then
        if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
          git rebase --abort || true
          echo "!! Conflict with local changes in $FLAKE: rebase cancelled, nothing applied."
        fi
        echo "$remote" > "$STATE/failed"
        echo "!! Configuration update failed: the system stays as it was."
        notify "Configuration update failed" "This PC keeps working with the previous configuration."
        exit 1
      fi
      rm -f "$STATE/failed"

      # 3. keep the current version and the previous ones, delete the rest
      clean_generations

      notify "Configuration updated" "''${news:-The configuration of this PC has been updated.}"
      echo ">> Done."
    '';
  };

  remoteUpdate = pkgs.writeShellApplication {
    name = "remote-update";
    runtimeInputs = with pkgs; [ openssh coreutils ];
    text = ''
      user=''${REMOTE_USER:-$(id -un)}
      if [ "''${1:-}" = "-u" ]; then user=$2; shift 2; fi
      if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        echo "Usage: remote-update [-u USER] PC..."
        echo "  Aligns each PC with its repository now (ssh USER@PC sudo config-sync --force)."
        echo "  USER must be an administrator of the PC (default: $user)."
        exit 0
      fi
      ok=() failed=()
      for pc in "$@"; do
        echo "================ $pc ================"
        if ssh -t -o ConnectTimeout=10 "$user@$pc" sudo config-sync --force; then
          ok+=("$pc")
        else
          failed+=("$pc")
        fi
      done
      echo
      echo "Aligned: ''${ok[*]:-none}"
      if [ ''${#failed[@]} -gt 0 ]; then echo "FAILED:  ''${failed[*]}"; exit 1; fi
    '';
  };
in
{
  options.my.maintenance.configSync = {
    enable = lib.mkEnableOption "automatic alignment with this PC's repository on the git server";

    interval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "How often the PC repository is checked for new commits (systemd time span).";
    };
  };

  config = lib.mkIf ucfg.enable (lib.mkMerge [
    {
      # the commands are always there: remote-update works also with the timer off
      environment.systemPackages = [ configSync remoteUpdate ];
    }
    (lib.mkIf cfg.enable {
      assertions = [{
        assertion = ucfg.gitCredentialsFile != null;
        message = "my.maintenance.configSync needs my.maintenance.updateCheck.gitCredentialsFile (git login for unattended runs).";
      }];

      systemd.services.config-sync = {
        description = "Alignment with this PC's configuration repository";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe configSync;
          Nice = 10;
          IOSchedulingClass = "idle";
        };
      };

      systemd.timers.config-sync = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = cfg.interval;
          RandomizedDelaySec = "2min";
        };
      };
    })
  ]);
}
