# Shell functions shared by the maintenance commands (config-update,
# system-update, app-manager): login to the git repositories and helpers for
# the PC-specific repository with the "base" input.
{ lib, cfg }:
let
  credFile = if cfg.gitCredentialsFile == null then "" else cfg.gitCredentialsFile;
in
rec {
  # Login to the git repositories (configuration and "base" input), in order:
  # login already configured for root -> gitCredentialsFile -> KDE Wallet of
  # the sudo user -> file in the KDE Vault -> terminal (offering to save it
  # in the wallet). The chosen login applies to git and to nix (which fetches
  # the inputs with git) through the GIT_CONFIG_* variables.
  gitLogin = ''
    CRED_FILE="${credFile}"
    VAULT_FILE="${cfg.vaultCredentialsFile}"
    LOGIN_HOST=""
    TMP_CRED="" CAP=""
    trap 'rm -f "$TMP_CRED" "$CAP"' EXIT
    # shellcheck disable=SC2016  # the variables are expanded by git's shell
    HELPER_ENV='!f() { if [ "$1" = get ]; then printf "username=%s\npassword=%s\n" "$GIT_U" "$GIT_P"; fi; }; f'
    # shellcheck disable=SC2016
    HELPER_CAPTURE='!f() { if [ "$1" = store ]; then cat > "$CAP"; fi; }; f'

    use_helper() {
      export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0="" \
             GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1="$1"
    }
    no_helper() {
      unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1
    }
    can_read() { GIT_TERMINAL_PROMPT=0 git ls-remote "$1" HEAD >/dev/null 2>&1; }
    url_host() { sed -E 's#^[a-z+]+://([^@/]*@)?([^/:]+).*#\2#' <<<"$1"; }

    # login file (git-credentials format) in the sudo user's open KDE Vaults:
    # it is a FUSE mount root cannot read, so it is read as that user
    vault_credentials() {
      local user=''${SUDO_USER:-} home d
      [ -n "$VAULT_FILE" ] && [ -n "$user" ] && [ "$user" != root ] || return 1
      home=$(getent passwd "$user" | cut -d: -f6)
      local dirs=()
      if [ -r "$home/.config/plasmavaultrc" ]; then
        while IFS= read -r d; do dirs+=("$d"); done \
          < <(sed -n 's/^mount[Pp]oint=//p' "$home/.config/plasmavaultrc")
      fi
      for d in "$home"/Vaults/*; do dirs+=("$d"); done
      for d in "''${dirs[@]}"; do
        if runuser -u "$user" -- test -r "$d/$VAULT_FILE" 2>/dev/null; then
          runuser -u "$user" -- grep -v '^[[:space:]]*\(#\|$\)' "$d/$VAULT_FILE"
          return 0
        fi
      done
      return 1
    }

    # the wallet lives in the sudo user's session: use it as that user
    WALLET_USER=''${SUDO_USER:-}
    wallet_ok() {
      [ -n "$WALLET_USER" ] && [ "$WALLET_USER" != root ] && [ -n "$LOGIN_HOST" ] &&
        [ -S "/run/user/$(id -u "$WALLET_USER")/bus" ]
    }
    as_wallet_user() {
      runuser -u "$WALLET_USER" -- env \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$WALLET_USER")/bus" "$@"
    }
    wallet_get() {
      wallet_ok && as_wallet_user secret-tool lookup service nixconfiguration-git host "$LOGIN_HOST" 2>/dev/null
    }
    wallet_set() {
      printf '%s\n%s' "$1" "$2" | as_wallet_user secret-tool store \
        --label="NixOS configuration: git $LOGIN_HOST" service nixconfiguration-git host "$LOGIN_HOST"
    }

    # git_login URL: prepares the login to read URL (0 = ready)
    git_login() {
      local url=$1 creds u p ans
      LOGIN_HOST=$(url_host "$url")
      can_read "$url" && return 0            # login already set up (same server)
      no_helper
      can_read "$url" && return 0            # public repository or root's login
      if [ -n "$CRED_FILE" ] && [ -r "$CRED_FILE" ]; then
        use_helper "store --file=$CRED_FILE"
        if can_read "$url"; then echo ">> Login for $LOGIN_HOST taken from $CRED_FILE."; return 0; fi
      fi
      if creds=$(wallet_get) && [ -n "$creds" ]; then
        GIT_U=$(head -n1 <<<"$creds") GIT_P=$(tail -n +2 <<<"$creds")
        export GIT_U GIT_P
        use_helper "$HELPER_ENV"
        if can_read "$url"; then echo ">> Login for $LOGIN_HOST taken from the KDE Wallet."; return 0; fi
        echo "!! Wallet login rejected (password changed?): enter it again."
      fi
      if creds=$(vault_credentials) && [ -n "$creds" ]; then
        TMP_CRED=$(mktemp)
        chmod 600 "$TMP_CRED"
        printf '%s\n' "$creds" > "$TMP_CRED"
        use_helper "store --file=$TMP_CRED"
        if can_read "$url"; then echo ">> Login for $LOGIN_HOST taken from the Vault ($VAULT_FILE)."; return 0; fi
      fi
      [ -t 0 ] || return 1
      CAP=$(mktemp)
      chmod 600 "$CAP"
      export CAP
      use_helper "$HELPER_CAPTURE"
      echo ">> Login for $LOGIN_HOST:"
      git ls-remote "$url" HEAD >/dev/null || return 1
      u=$(sed -n 's/^username=//p' "$CAP")
      p=$(sed -n 's/^password=//p' "$CAP")
      [ -n "$u" ] && [ -n "$p" ] || { no_helper; return 0; }
      GIT_U=$u GIT_P=$p
      export GIT_U GIT_P
      use_helper "$HELPER_ENV"
      if wallet_ok; then
        read -r -p ">> Save user and password for $LOGIN_HOST in the KDE Wallet? [Y/n] " ans
        case "$ans" in
          n|N|no|NO) echo "   Not saved." ;;
          *) if wallet_set "$u" "$p"; then
               echo "   Saved in the KDE Wallet: they will not be asked next time."
             else
               echo "   Could not save them (wallet closed or unavailable)."
             fi ;;
        esac
      fi
      return 0
    }
  '';

  # after an update: keeps the current system version and the previous
  # keepPrevious ones (at least 2), deletes the older ones and frees the space
  cleanFns = ''
    clean_generations() {
      local profile=/nix/var/nix/profiles/system keep=${toString (cfg.keepPrevious + 1)} before after
      echo ">> Keeping the current system version and the previous ${toString cfg.keepPrevious}, deleting the older ones..."
      nix-env --delete-generations "+$keep" --profile "$profile"
      before=$(df --output=avail -B1M /nix/store | tail -1)
      nix-store --gc >/dev/null
      after=$(df --output=avail -B1M /nix/store | tail -1)
      echo "   Space freed: $(( after - before )) MB"
      /run/current-system/bin/switch-to-configuration boot
      nix-env --list-generations --profile "$profile" | sed 's/^/   /'
    }
  '';

  # after nixos-rebuild switch: restarts the Plasma panel (plasmashell) of the
  # logged-in users. The switch restarts system services and the running
  # panel can get stuck at 100% CPU (Power and Battery widget looping on the
  # sleep inhibitors); the open windows are not touched.
  sessionFns = ''
    restart_plasma() {
      local bus uid
      for bus in /run/user/*/bus; do
        [ -S "$bus" ] || continue
        uid=$(basename "$(dirname "$bus")")
        [ "$uid" -ge 1000 ] || continue
        as_session() {
          setpriv --reuid="$uid" --regid="$(id -g "$uid")" --init-groups \
            env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" XDG_RUNTIME_DIR="/run/user/$uid" \
            /run/current-system/sw/bin/systemctl --user "$@"
        }
        if as_session is-active -q plasma-plasmashell 2>/dev/null; then
          echo ">> Restarting the Plasma panel of $(id -nu "$uid" 2>/dev/null || echo "$uid")..."
          as_session restart plasma-plasmashell 2>/dev/null || true
        fi
      done
    }
  '';

  # PC-specific repository: flake with the "base" input (= this repository)
  baseFns = ''
    G=(git -c user.name=locale -c user.email=locale@localhost)
    PUSH_CONFIG=${lib.boolToString cfg.pushConfig}

    has_base() {
      { [ -f flake.lock ] && jq -e '.nodes.root.inputs.base' flake.lock >/dev/null; } ||
        grep -Eq '^[[:space:]]*(inputs\.)?base(\.url)?[[:space:]]*[.=]' flake.nix
    }
    # git URL of "base" (empty if it is not a git repository, e.g. github:)
    base_url() {
      local u=""
      if [ -f flake.lock ]; then
        u=$(jq -r '.nodes.root.inputs.base as $b | if $b then (.nodes[$b].original.url // empty) else empty end' flake.lock)
      fi
      [ -n "$u" ] || u=$(sed -nE 's#.*base\.url[[:space:]]*=[[:space:]]*"(git\+)?([^"?]+).*#\2#p' flake.nix | head -n1)
      case "$u" in http*|ssh*|git@*) echo "$u" ;; esac
    }
    base_rev() {
      [ -f flake.lock ] || return 0
      jq -r '.nodes.root.inputs.base as $b | if $b then (.nodes[$b].locked.rev // "") else "" end' flake.lock
    }
    # prints what changed in "base" between two revisions
    base_changes() {
      local old=$1 new=$2 web
      [ "$old" = "$new" ] && { echo "   generic configuration: already at the latest version (''${new:0:7})"; return 0; }
      echo "   generic configuration: ''${old:0:7} → ''${new:0:7}"
      web=$(base_url)
      if [ -n "$web" ] && [ -n "$old" ]; then echo "   ''${web%.git}/compare/$old...$new"; fi
    }
    # lock_update [INPUT...]: nix flake update with a short summary instead of
    # Nix's 'warning: updating lock file' (one line per changed input)
    # shellcheck disable=SC2120  # system-update calls it without arguments
    lock_update() {
      local out rc=0 sum
      echo ">> Updating the locked versions (flake.lock)''${1:+: $*}..."
      out=$(nix --extra-experimental-features 'nix-command flakes' flake update "$@" 2>&1) || rc=$?
      if [ "$rc" -ne 0 ]; then
        grep -v '^warning: updating lock file' <<<"$out"
        echo "!! Update of flake.lock failed."
        return "$rc"
      fi
      if ! grep -q '^warning: updating lock file' <<<"$out"; then
        echo "   already at the latest versions: flake.lock unchanged"
        return 0
      fi
      # Nix prints:  • Updated input 'name':
      #                  'url…rev=OLD…' (date)
      #                → 'url…rev=NEW…' (date)
      # (q = single quote: it cannot be written inside this Nix string)
      sum=$(awk -v q="'" '
        function ver(s,  r, d) {
          r = ""; d = ""
          if (match(s, /rev=[0-9a-f]+/)) r = substr(s, RSTART + 4, 7)
          else if (match(s, /\/[0-9a-f]{40}/)) r = substr(s, RSTART + 1, 7)
          if (match(s, /\([0-9-]+\)/)) d = substr(s, RSTART + 1, RLENGTH - 2)
          return d (r != "" ? " (" r ")" : "")
        }
        /^• (Updated|Added|Removed) input/ {
          what = $2; split($0, p, q); name = p[2]
          state = (what == "Updated") ? 1 : 0
          if (what == "Removed") print "   " name ": removed"
          next
        }
        { url = (substr($0, 1, 5) == "    " q) }
        state == 1 && url { old = ver($0); next }
        state == 1 && /^  → / { print "   " name ": " old " → " ver($0); state = 0; next }
        url && what == "Added" && name != "" { print "   " name ": added, " ver($0); name = "" }
      ' <<<"$out")
      echo ">> New versions locked in flake.lock:"
      if [ -n "$sum" ]; then echo "$sum"
      else grep -E "^(•|    |  →)" <<<"$out"; fi
    }
    # commit of the updated flake.lock (stays in the PC repository)
    commit_lock() {
      "''${G[@]}" add flake.lock
      if ! "''${G[@]}" diff --cached --quiet; then
        "''${G[@]}" commit -q -m "$1"
      fi
    }
    # pushes the local commits to the PC repository, if any
    push_local() {
      [ "$PUSH_CONFIG" = true ] || return 0
      git rev-parse -q --verify '@{upstream}' >/dev/null || return 0
      [ "$(git rev-list --count '@{upstream}..HEAD')" -gt 0 ] || return 0
      local up remote
      up=$(git rev-parse --abbrev-ref '@{upstream}')     # e.g. origin/main
      remote=''${up%%/*}
      git_login "$(git remote get-url "$remote")" || true
      if GIT_TERMINAL_PROMPT=0 "''${G[@]}" push -q "$remote" "HEAD:''${up#*/}"; then
        echo ">> This PC's configuration pushed to $(git remote get-url "$remote")."
      else
        echo "!! Push failed (a login with write permission is required):"
        echo "   the commits stay on this PC and will be pushed at the next config-update."
      fi
    }
  '';
}
