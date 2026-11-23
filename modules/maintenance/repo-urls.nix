# repo-urls: shows and changes the git URLs this PC's configuration uses
#   - generic configuration: the "base" input in flake.nix
#   - this PC's repository: the "origin" remote of the configuration folder
#   sudo repo-urls                 menu (also in nix-tools)
#   sudo repo-urls show            current URLs
#   sudo repo-urls base URL        e.g. sudo repo-urls base https://git.example.com/it/nix_workstation.git
#   sudo repo-urls pc URL          e.g. sudo repo-urls pc https://git.example.com/it/nix_workstation_pc01.git
# Every new URL is checked (login as in config-update) before it is saved.
# A new "base" URL is written to flake.nix, locked in flake.lock, checked
# with nix eval, committed and pushed; it is applied by the next
# config-update. A new PC repository URL that is empty gets this PC's
# configuration pushed into it (after confirmation).
{ config, lib, pkgs, flakeHost, ... }:
let
  cfg = config.my.maintenance.repoUrls;
  ucfg = config.my.maintenance.updateCheck;
  inherit (import ./git-fns.nix { inherit lib; cfg = ucfg; }) gitLogin baseFns;

  repoUrls = pkgs.writeShellApplication {
    name = "repo-urls";
    runtimeInputs = [ pkgs.nix pkgs.newt ] ++ (with pkgs; [ git jq coreutils gnused gnugrep util-linux getent libsecret ]);
    text = ''
      if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo"; exit 1; fi
      # whiptail buttons in English
      unset LC_ALL LANGUAGE; export LC_MESSAGES=C.UTF-8
      FLAKE="${ucfg.flakePath}"
      HOST="${flakeHost}"
      TITLE="repo-urls · $(hostname)"
      cd "$FLAKE"
      ${gitLogin}
      ${baseFns}
      if ! git config --global --get-all safe.directory | grep -qx "$FLAKE"; then
        git config --global --add safe.directory "$FLAKE"
      fi

      BASE_RE='^([[:space:]]*(inputs\.)?base\.url[[:space:]]*=[[:space:]]*")[^"]*"'
      # URL written in flake.nix (empty: this flake has no "base" input)
      base_line_url() { grep -Em1 "$BASE_RE" flake.nix | sed -E 's#^[^"]*"([^"]*)".*#\1#' || true; }
      pc_url() { git remote get-url origin 2>/dev/null || true; }
      # URL for git (without git+ and ?ref=...); empty if not a git URL (github:...)
      plain_url() {
        local u=''${1#git+}
        u=''${u%%\?*}
        case "$u" in http://*|https://*|ssh://*|git@*) echo "$u" ;; esac
      }
      valid_url() { [[ "$1" =~ ^[A-Za-z0-9+.:/@_~%=?-]+$ ]]; }

      show() {
        local b
        b=$(base_line_url)
        echo "Generic configuration (base): ''${b:-(not used: this flake has no base input)}"
        echo "This PC's repository (origin): $(pc_url)"
      }

      ask_yes() {   # question -> 0 = yes (whiptail in the menu, text otherwise)
        local ans
        if [ "$INTERACTIVE" = 1 ]; then whiptail --title "$TITLE" --yesno "$1" 12 74; return; fi
        [ -t 0 ] || return 1
        read -r -p "$(printf '%b' "$1") [Y/n] " ans
        case "$ans" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
      }

      can_reach() {   # URL -> 0 if readable; prints the refs to $REFS
        git_login "$1" || return 1
        GIT_TERMINAL_PROMPT=0 git ls-remote "$1" >"$REFS" 2>/dev/null
      }

      set_base() {
        local new=$1 old plain
        old=$(base_line_url)
        [ -n "$old" ] || { echo "!! flake.nix has no base input: nothing to change."; exit 1; }
        valid_url "$new" || { echo "!! Invalid URL: $new"; exit 1; }
        # a plain http(s) URL becomes a git+ flake URL, like the existing one
        case "$new" in
          http://*|https://*|ssh://*) new="git+$new" ;;
          git@*:*) new="git+ssh://''${new%%:*}/''${new#*:}" ;;   # git@host:path (scp form)
        esac
        [ "$new" = "$old" ] && { echo "   Generic configuration: already $new"; return 0; }
        plain=$(plain_url "$new")
        if [ -n "$plain" ]; then
          echo ">> Checking $plain..."
          if ! can_reach "$plain" || ! [ -s "$REFS" ]; then
            echo "!! Cannot read $plain (wrong URL, no login or empty repository): nothing changed."; exit 1
          fi
        fi
        cp flake.nix "$BK_NIX"; [ -f flake.lock ] && cp flake.lock "$BK_LOCK"
        # any exit before the commit puts the files back
        trap 'cp "$BK_NIX" flake.nix; [ -s "$BK_LOCK" ] && cp "$BK_LOCK" flake.lock; cleanup' EXIT
        sed -i -E "0,/$BASE_RE/s##\1$new\"#" flake.nix
        [ "$(base_line_url)" = "$new" ] || { echo "!! Could not edit flake.nix: nothing changed."; exit 1; }
        echo ">> Locking the new generic configuration (flake.lock)..."
        if ! nix --extra-experimental-features 'nix-command flakes' flake lock; then
          echo "!! nix flake lock failed: files restored, nothing changed."; exit 1
        fi
        echo ">> Checking the configuration..."
        if ! nix --extra-experimental-features 'nix-command flakes' eval --raw \
             --option allow-import-from-derivation false \
             ".#nixosConfigurations.\"$HOST\".config.system.stateVersion" >/dev/null; then
          echo "!! The configuration does not evaluate with the new generic repository: files restored, nothing changed."; exit 1
        fi
        trap cleanup EXIT
        "''${G[@]}" add flake.nix flake.lock
        "''${G[@]}" commit -q -m "repos: generic configuration from $new" -- flake.nix flake.lock
        push_local
        echo ">> Generic configuration: $old → $new"
        echo "   It is applied to the system by: sudo config-update"
      }

      set_pc() {
        local new=$1 old branch
        old=$(pc_url)
        valid_url "$new" || { echo "!! Invalid URL: $new"; exit 1; }
        [ "$new" = "$old" ] && { echo "   This PC's repository: already $new"; return 0; }
        [ -n "$(plain_url "$new")" ] || { echo "!! Use a git URL (https://, ssh:// or git@): $new"; exit 1; }
        echo ">> Checking $new..."
        if ! can_reach "$new"; then
          echo "!! Cannot read $new (wrong URL or no login): nothing changed."; exit 1
        fi
        if [ -n "$old" ]; then git remote set-url origin "$new"; else git remote add origin "$new"; fi
        echo ">> This PC's repository: ''${old:-(none)} → $new"
        branch=$(git symbolic-ref --short HEAD)
        if ! [ -s "$REFS" ]; then
          if ask_yes "The repository $new is empty.\n\nPush this PC's configuration ($branch) into it?"; then
            if GIT_TERMINAL_PROMPT=0 "''${G[@]}" push -q -u origin "HEAD:$branch"; then
              echo ">> Configuration pushed to $new."
            else
              echo "!! Push failed (a login with write permission is required). Try again with: sudo repo-urls pc $new"
            fi
          else
            echo "   Not pushed: the repository stays empty."
          fi
          return 0
        fi
        GIT_TERMINAL_PROMPT=0 git fetch -q origin || { echo "!! Fetch from $new failed."; return 0; }
        if git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
          git branch -q -u "origin/$branch"
          local ahead behind
          ahead=$(git rev-list --count "origin/$branch..HEAD")
          behind=$(git rev-list --count "HEAD..origin/$branch")
          if [ "$ahead" = 0 ] && [ "$behind" = 0 ]; then
            echo "   Same commits as this PC: nothing else to do."
          else
            echo "   This PC: $ahead commits not in the repository, $behind new commits in the repository."
            echo "   They are aligned by: sudo config-update"
          fi
        else
          echo "!! The repository has no branch $branch: is it really this PC's repository?"
          echo "   Put the old URL back with: sudo repo-urls pc $old"
        fi
      }

      REFS=$(mktemp) BK_NIX=$(mktemp) BK_LOCK=$(mktemp)
      cleanup() { rm -f "$REFS" "$BK_NIX" "$BK_LOCK" "$TMP_CRED" "$CAP"; }
      trap cleanup EXIT
      INTERACTIVE=0

      case "''${1:-}" in
        show) show; exit 0 ;;
        base|pc)
          [ $# -eq 2 ] || { echo "Usage: sudo repo-urls $1 URL"; exit 1; }
          if [ "$1" = base ]; then set_base "$2"; else set_pc "$2"; fi
          exit 0 ;;
        "") ;;
        *) echo "Usage: sudo repo-urls [show | base URL | pc URL]"; exit 1 ;;
      esac

      # menu
      INTERACTIVE=1
      b=$(base_line_url) p=$(pc_url)
      items=()
      [ -n "$b" ] && items+=(base "Generic configuration: $b")
      items+=(pc "This PC's repository: ''${p:-(none)}")
      sel=$(whiptail --title "$TITLE" --menu "Git repositories of this PC's configuration. Choose the URL to change:" \
            14 100 2 "''${items[@]}" 3>&1 1>&2 2>&3) || { clear; exit 0; }
      if [ "$sel" = base ]; then cur=$b; what="generic configuration (base input in flake.nix)"
      else cur=$p; what="this PC's repository (origin)"; fi
      new=$(whiptail --title "$TITLE" --inputbox "New URL of the $what:" 10 100 "$cur" 3>&1 1>&2 2>&3) ||
        { clear; echo "Cancelled: nothing changed."; exit 0; }
      clear
      [ "$new" = "$cur" ] && { echo "Unchanged."; exit 0; }
      if [ "$sel" = base ]; then set_base "$new"; else set_pc "$new"; fi
    '';
  };
in
{
  options.my.maintenance.repoUrls.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "'sudo repo-urls' command to change the git URLs of the generic configuration and of this PC's repository.";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ repoUrls ];
  };
}
