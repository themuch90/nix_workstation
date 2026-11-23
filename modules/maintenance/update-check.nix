# Daily update check with notification (installs nothing).
# Commands: update-check, system-update, config-update, system-clean.
# /etc/nixos is the PC repository, which imports this one as the flake's "base"
# input (wiki: Repository-del-PC): config-update also updates "base" and pushes
# the local commits to the server.
{ config, lib, pkgs, flakeHost, ... }:
let
  cfg = config.my.maintenance.updateCheck;
  credFile = if cfg.gitCredentialsFile == null then "" else cfg.gitCredentialsFile;

  inherit (import ./git-fns.nix { inherit lib cfg; }) gitLogin baseFns cleanFns sessionFns;

  # Inputs pinned to a release tag (github:owner/repo/v1.2.3) follow only the
  # stable releases: GitHub's "latest release" never is a prerelease (rc,
  # beta, nightly) or a draft, and tags with a suffix are rejected anyway.
  releaseFns = ''
    is_release() { [[ "$1" =~ ^v?[0-9]+(\.[0-9]+)+$ ]]; }
    latest_release() {
      local tag
      tag=$(curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' \
              "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name // empty') || return 1
      is_release "$tag" || return 1
      echo "$tag"
    }
  '';

  loginInputs = with pkgs; [ git jq curl coreutils gnused gnugrep gawk util-linux getent libsecret ];

  # list of pending updates, read again at every login until system-update
  reportFile = "/var/lib/update-check/report.txt";

  # notify-send options: "critical" stays on screen until it is closed
  notifyArgs = "-a NixOS -i system-software-update -u ${if cfg.persistentNotification then "critical" else "normal"}";

  # reminder at login (user service): pending updates are not lost if the
  # notification was missed or nobody was logged in during the check
  updateReminder = pkgs.writeShellApplication {
    name = "update-reminder";
    runtimeInputs = with pkgs; [ coreutils gnugrep libnotify ];
    text = ''
      NOTIFY_USERS="${lib.concatStringsSep " " cfg.notifyUsers}"
      if [ -n "$NOTIFY_USERS" ]; then
        case " $NOTIFY_USERS " in *" $(id -nu) "*) ;; *) exit 0 ;; esac
      fi
      [ -r "${reportFile}" ] || exit 0
      found=$(grep -c '^•' "${reportFile}" || true)
      [ "$found" -gt 0 ] || exit 0
      # wait for the notification service of the session
      sleep 20
      notify-send ${notifyArgs} "Updates available ($found)" \
        "$(grep '^•' "${reportFile}")
      To install: sudo system-update" || true
    '';
  };

  updateCheck = pkgs.writeShellApplication {
    name = "update-check";
    runtimeInputs = with pkgs; [ nix git jq curl coreutils util-linux libnotify gnugrep systemd ];
    text = ''
      ${releaseFns}
      FLAKE="${cfg.flakePath}"
      LOCK="$FLAKE/flake.lock"
      STATE=/var/lib/update-check
      mkdir -p "$STATE" 2>/dev/null || STATE="$(mktemp -d)"
      REPORT="$STATE/report.txt"

      if [ ! -f "$LOCK" ]; then
        echo "flake.lock not found in $FLAKE"; exit 1
      fi

      # private git repositories (e.g. the "base" input): login from the system file, if any
      CRED_FILE="${credFile}"
      if [ -n "$CRED_FILE" ] && [ -r "$CRED_FILE" ]; then
        export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0="" \
               GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1="store --file=$CRED_FILE"
      fi
      export GIT_TERMINAL_PROMPT=0

      : > "$REPORT.new"
      found=0
      # direct inputs of the flake and, in PC-specific repositories, those of
      # the generic "base" configuration (nixpkgs, proxmox-nixos, ...)
      while read -r name node; do
        type=$(jq -r --arg n "$node" '.nodes[$n].original.type' "$LOCK")
        old=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // empty' "$LOCK")
        ref=$(jq -r --arg n "$node" '.nodes[$n].original.ref // empty' "$LOCK")
        case "$type" in
          github)
            owner=$(jq -r --arg n "$node" '.nodes[$n].original.owner' "$LOCK")
            repo=$(jq -r --arg n "$node" '.nodes[$n].original.repo' "$LOCK")
            if is_release "$ref"; then
              if ! latest=$(latest_release "$owner/$repo") || [ -z "$latest" ]; then
                echo "[$name] cannot read the releases of $owner/$repo (offline?)"
                continue
              fi
              if [ "$latest" = "$ref" ]; then
                echo "[$name] up to date ($ref, latest stable release)"
              else
                found=$((found + 1))
                note=""
                case "$name" in base/*) note=" (pinned by the generic configuration)" ;; esac
                echo "• $name: $ref → $latest (stable release)$note" | tee -a "$REPORT.new"
                echo "   https://github.com/$owner/$repo/releases/tag/$latest" >> "$REPORT.new"
              fi
              continue
            fi
            url="github:$owner/$repo''${ref:+/$ref}"
            if ! meta=$(nix --extra-experimental-features 'nix-command flakes' \
                        flake metadata --json --refresh "$url" 2>/dev/null); then
              echo "[$name] cannot reach $url (offline?)"
              continue
            fi
            new=$(echo "$meta" | jq -r '.locked.rev // .revision')
            date=" ($(echo "$meta" | jq -r '.lastModified' | xargs -I{} date -d @{} '+%Y-%m-%d'))"
            web="https://github.com/$owner/$repo"
            ;;
          git)
            url=$(jq -r --arg n "$node" '.nodes[$n].original.url' "$LOCK")
            if ! new=$(git ls-remote "$url" "''${ref:-HEAD}" | head -n1 | cut -f1) || [ -z "$new" ]; then
              echo "[$name] cannot read $url (offline or login required:"
              echo "        my.maintenance.updateCheck.gitCredentialsFile, or sudo config-update)"
              continue
            fi
            date=""
            web="''${url%.git}"
            ;;
          *) continue ;;
        esac

        if [ "$new" != "$old" ]; then
          found=$((found + 1))
          line="• $name: ''${old:0:7} → ''${new:0:7}$date"
          echo "$line" | tee -a "$REPORT.new"
          echo "   $web/compare/$old...$new" >> "$REPORT.new"
        else
          echo "[$name] up to date$date"
        fi
      done < <(jq -r '
        def direct(p; n): n.inputs // {} | to_entries[]
          | select(.value | type == "string") | "\(p)\(.key) \(.value)";
        .nodes as $all
        | direct(""; $all.root),
          (if ($all.root.inputs.base | type) == "string"
           then direct("base/"; $all[$all.root.inputs.base]) else empty end)
      ' "$LOCK")

      mv "$REPORT.new" "$REPORT"
      [ "$found" -eq 0 ] && { echo "No updates."; exit 0; }

      title="Updates available ($found)"
      body="$(grep '^•' "$REPORT")
      To install: sudo system-update"

      # notify every graphical session (empty NOTIFY_USERS = all)
      NOTIFY_USERS="${lib.concatStringsSep " " cfg.notifyUsers}"
      for bus in /run/user/*/bus; do
        [ -S "$bus" ] || continue
        uid=$(basename "$(dirname "$bus")")
        user=$(id -nu "$uid" 2>/dev/null) || continue
        if [ -n "$NOTIFY_USERS" ]; then
          case " $NOTIFY_USERS " in *" $user "*) ;; *) continue ;; esac
        fi
        echo "Notifying $user"
        if [ "$(id -u)" -eq 0 ]; then
          setpriv --reuid="$uid" --regid="$(id -g "$uid")" --init-groups \
            env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            notify-send ${notifyArgs} "$title" "$body" || true
        elif [ "$uid" = "$(id -u)" ]; then
          notify-send ${notifyArgs} "$title" "$body" || true
        fi
      done
      cat "$REPORT"
    '';
  };

  systemUpdate = pkgs.writeShellApplication {
    name = "system-update";
    # nixos-rebuild comes from the system (/run/current-system/sw/bin)
    runtimeInputs = [ pkgs.nix ] ++ loginInputs;
    text = ''
      if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo"; exit 1; fi
      cd "${cfg.flakePath}"
      ${gitLogin}
      ${baseFns}
      ${releaseFns}
      ${cleanFns}
      ${sessionFns}

      # inputs of this flake pinned to a release tag: move to the latest
      # stable release (prereleases are never installed)
      bump_releases() {
        local name node ref owner repo latest
        [ -f flake.lock ] || return 0
        while read -r name node; do
          [ "$(jq -r --arg n "$node" '.nodes[$n].original.type' flake.lock)" = github ] || continue
          ref=$(jq -r --arg n "$node" '.nodes[$n].original.ref // empty' flake.lock)
          is_release "$ref" || continue
          owner=$(jq -r --arg n "$node" '.nodes[$n].original.owner' flake.lock)
          repo=$(jq -r --arg n "$node" '.nodes[$n].original.repo' flake.lock)
          if ! latest=$(latest_release "$owner/$repo") || [ -z "$latest" ]; then
            echo "!! $name: cannot read the releases of $owner/$repo, stays at $ref"
            continue
          fi
          [ "$latest" = "$ref" ] && { echo "   $name: $ref (latest stable release)"; continue; }
          if grep -q "github:$owner/$repo/$ref\"" flake.nix; then
            sed -i "s#github:$owner/$repo/''${ref//./\\.}\"#github:$owner/$repo/$latest\"#" flake.nix
            echo "   $name: $ref → $latest (stable release)"
          fi
        done < <(jq -r '.nodes.root.inputs | to_entries[] | select(.value | type == "string") | "\(.key) \(.value)"' flake.lock)
      }

      cp flake.lock "flake.lock.bak-$(date +%Y%m%d-%H%M)" 2>/dev/null || true
      echo ">> Release-pinned inputs:"
      bump_releases
      old=""
      if has_base; then
        old=$(base_rev)
        url=$(base_url)
        if [ -n "$url" ] && ! git_login "$url"; then
          echo "!! Cannot access $url (no network or login rejected)."; exit 1
        fi
      fi
      # shellcheck disable=SC2119  # all the inputs
      lock_update
      if has_base; then
        echo ">> What's new:"
        base_changes "$old" "$(base_rev)"
      fi
      nixos-rebuild switch --flake ".#${flakeHost}"
      restart_plasma
      # updates installed: no more reminders at login until the next check
      if [ -f "${reportFile}" ]; then : > "${reportFile}"; fi
      if has_base; then
        "''${G[@]}" add flake.nix
        commit_lock "flake.lock: packages updated $(date '+%Y-%m-%d %H:%M')"
        push_local
      fi
      clean_generations
      echo "Update complete. If something goes wrong: reboot and choose the previous generation."
    '';
  };

  # Updates the configuration from git, keeping the local changes.
  configUpdate = pkgs.writeShellApplication {
    name = "config-update";
    runtimeInputs = [ pkgs.nix ] ++ loginInputs;
    text = ''
      if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo"; exit 1; fi
      cd "${cfg.flakePath}"
      ${gitLogin}
      ${baseFns}
      ${sessionFns}

      # repo created by another user: avoids "dubious ownership"
      if ! git config --global --get-all safe.directory | grep -qx "${cfg.flakePath}"; then
        git config --global --add safe.directory "${cfg.flakePath}"
      fi

      if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
        echo "A previous update has unresolved conflicts."
        echo "Resolve it (see below) or cancel it with: git rebase --abort"
        exit 1
      fi

      # 1. save the local changes in a commit
      "''${G[@]}" add -A
      if ! "''${G[@]}" diff --cached --quiet; then
        "''${G[@]}" commit -q -m "local configuration $(date '+%Y-%m-%d %H:%M')"
        echo ">> Local changes saved in a local commit."
      fi

      # 2. fetch and replay the local changes on top
      echo ">> Fetching configuration updates..."
      if ! git_login "$(git remote get-url origin)" || ! "''${G[@]}" fetch -q; then
        echo
        echo "!! Download failed (no network or login rejected)."
        exit 1
      fi
      if ! "''${G[@]}" rebase -q '@{upstream}'; then
        echo
        echo "!! CONFLICT: you and the repository changed the same lines."
        echo "   Conflicting files:"
        git diff --name-only --diff-filter=U | sed 's/^/     /'
        echo
        echo "   1. open the files and look for the blocks  <<<<<<<  =======  >>>>>>>"
        echo "      keep the right version and delete the marker lines"
        echo "   2. cd ${cfg.flakePath} && git add $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
        echo "   3. GIT_EDITOR=true git -c user.name=locale -c user.email=locale@localhost rebase --continue"
        echo "   4. sudo config-update   (to apply)"
        echo "   To cancel everything:  git rebase --abort"
        exit 1
      fi

      echo ">> What's new:"
      git log --oneline ORIG_HEAD..HEAD 2>/dev/null | grep -vE "local configuration|configurazione locale" | sed 's/^/   /' || true

      # 3. PC repository: bring the generic configuration ("base") to the latest version
      if has_base; then
        old=$(base_rev)
        url=$(base_url)
        if [ -n "$url" ] && ! git_login "$url"; then
          echo "!! Cannot access the generic configuration $url"; exit 1
        fi
        lock_update base
        new=$(base_rev)
        base_changes "$old" "$new"
        commit_lock "flake.lock: generic configuration ''${new:0:7}"
      fi

      if [ "''${1:-}" = "--no-switch" ]; then
        echo ">> Configuration updated (not applied)."
        exit 0
      fi
      nixos-rebuild switch --flake ".#${flakeHost}"
      restart_plasma
      echo ">> Configuration updated and applied."
      if has_base; then push_local; fi
    '';
  };
  systemClean = pkgs.writeShellApplication {
    name = "system-clean";
    runtimeInputs = with pkgs; [ nix coreutils gnugrep ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo"; exit 1; fi
      PROFILE=/nix/var/nix/profiles/system

      echo ">> System versions present:"
      nix-env --list-generations --profile "$PROFILE" | sed 's/^/   /'
      total=$(nix-env --list-generations --profile "$PROFILE" | grep -c .)
      echo "   Total: $total (the one marked (current) is in use and is never deleted)"
      echo

      keep="''${1:-}"
      if [ -z "$keep" ]; then
        read -r -p "How many versions do you want to keep (including the current one)? [${toString cfg.keepGenerations}] " keep </dev/tty
        keep="''${keep:-${toString cfg.keepGenerations}}"
      fi
      if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -lt 1 ]; then
        echo "Invalid value: a number greater than or equal to 1 is required"; exit 1
      fi
      if [ "$keep" -ge "$total" ]; then
        echo "There are $total versions and you want to keep $keep: nothing to delete."
      else
        echo "$((total - keep)) versions will be deleted, the latest $keep remain."
        if [ "''${2:-}" != "-y" ]; then
          read -r -p "Confirm? [y/N] " ok </dev/tty
          case "$ok" in y|Y|yes|YES|s|S|si|SI) ;; *) echo "Cancelled."; exit 0 ;; esac
        fi
        nix-env --delete-generations "+$keep" --profile "$PROFILE"
      fi

      echo ">> Freeing disk space (may take a few minutes)..."
      before=$(df --output=avail -B1M /nix/store | tail -1)
      nix-store --gc
      after=$(df --output=avail -B1M /nix/store | tail -1)
      echo "   Space freed: $(( after - before )) MB"

      echo ">> Updating the boot menu..."
      /run/current-system/bin/switch-to-configuration boot

      echo ">> Done. Remaining versions:"
      nix-env --list-generations --profile "$PROFILE" | sed 's/^/   /'
    '';
  };
in
{
  options.my.maintenance.updateCheck = {
    vaultCredentialsFile = lib.mkOption {
      type = lib.types.str;
      default = "git-credentials";
      description = ''
        Name of the file, inside an open KDE Vault (Plasma Vault), holding the
        login for the configuration repository, one line per server:
        https://user:TOKEN@git.example.com
        config-update uses it only for the download, without saving it elsewhere.
        Empty string = do not look for it.
      '';
    };

    gitCredentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/root/.git-credentials";
      description = ''
        File readable only by root, outside the repository, in git-credentials
        format (https://user:TOKEN@git.example.com). Needed for private
        repositories: download of the configuration and of the "base" input,
        and update-check's daily check (which runs without the KDE Wallet).
        null = do not use it (config-update and system-update ask for the login).
      '';
    };

    pushConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        After a successful apply, config-update and system-update push the
        local commits of the PC repository to the server.
      '';
    };

    keepPrevious = lib.mkOption {
      type = lib.types.ints.between 2 100;
      default = 2;
      description = ''
        After system-update and the automatic alignment (config-sync): system
        versions kept besides the current one (at least 2); the older ones are
        deleted and the disk space freed.
      '';
    };

    keepGenerations = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Number of versions proposed by system-clean (when pressing Enter).";
    };

    enable = lib.mkEnableOption "daily update check";

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = "Folder containing flake.nix and flake.lock.";
    };

    time = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 10:00:00";
      description = "When to run the check (systemd OnCalendar format).";
    };

    notifyUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users to notify. Empty = all logged-in users.";
    };

    persistentNotification = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        true = the notification stays on screen until it is closed (critical
        urgency). It is also shown again at every login while updates are
        pending, until "sudo system-update" installs them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ updateCheck systemUpdate configUpdate systemClean ];

    systemd.services.update-check = {
      description = "Flake update check (nixpkgs, proxmox-nixos, ...)";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe updateCheck;
        StateDirectory = "update-check";
      };
    };

    systemd.user.services.update-reminder = {
      description = "Reminder of pending system updates";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe updateReminder;
      };
    };

    systemd.timers.update-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.time;
        Persistent = true;          # if the PC was off, check at power-on
        RandomizedDelaySec = "15m";
        OnBootSec = "10m";
      };
    };
  };
}
