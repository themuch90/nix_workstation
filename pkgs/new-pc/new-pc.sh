# new-pc: wizard (nix-tools style) that creates the PC-specific repository of
# a new PC, always starting from the generic hosts/workstation template.
# It first collects all the answers, then shows the summary and only after
# confirmation runs the commands, showing them on screen.
#   sudo new-pc                              normal use (in /etc/nixos)
#   new-pc --target /tmp/test --no-switch    test without touching the system
# Without a terminal (answers from a pipe) it uses plain text questions.
# NEW_PC_SRC (set by the package) = source of the generic repository.
# NEW_PC_BASE (set by install.sh) = address it was cloned from.

TARGET=/etc/nixos
SWITCH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET=${2%/}; shift 2 ;;
    --no-switch) SWITCH=0; shift ;;
    -h|--help)
      echo "Usage: sudo new-pc"
      echo "       new-pc --target /tmp/test --no-switch   (test, does not apply)"
      exit 0 ;;
    *) echo "Unknown option: $1 (see new-pc --help)"; exit 1 ;;
  esac
done
if [ "$TARGET" = /etc/nixos ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo"; exit 1
fi

# whiptail buttons in English
unset LC_ALL LANGUAGE; export LC_MESSAGES=C.UTF-8
G=(git -c user.name=locale -c user.email=locale@localhost -c init.defaultBranch=main)
TITLE="new-pc · new NixOS PC"
TUI=0
if [ -t 0 ] && [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != dumb ]; then TUI=1; fi

# ---------------------------------------------------------------------------
# Interface: whiptail dialogs (like nix-tools) or plain text
# ---------------------------------------------------------------------------
eof() { echo; echo "End of input: cancelled, nothing changed."; exit 1; }
confirm_exit() {
  if [ "$TUI" -eq 0 ]; then echo "Cancelled: nothing changed."; exit 0; fi
  if whiptail --title "$TITLE" --yesno "Exit the wizard?\n\nNothing has been changed." 10 60; then
    clear; echo "Cancelled: nothing changed."; exit 0
  fi
}
ask() {   # ask VARIABLE "question" [default]
  local _ans
  while true; do
    if [ "$TUI" -eq 1 ]; then
      if _ans=$(whiptail --title "$TITLE" --inputbox "$2" 16 78 "${3:-}" 3>&1 1>&2 2>&3); then break; fi
      confirm_exit
    else
      printf '%b' "$2"; [ -n "${3:-}" ] && printf ' [%s]' "$3"; printf ': '
      read -r _ans || eof
      [ -n "$_ans" ] || _ans=${3:-}
      break
    fi
  done
  printf -v "$1" '%s' "$_ans"
}
ask_secret() {   # ask_secret VARIABLE "question"
  local _ans
  while true; do
    if [ "$TUI" -eq 1 ]; then
      if _ans=$(whiptail --title "$TITLE" --passwordbox "$2" 10 78 3>&1 1>&2 2>&3); then break; fi
      confirm_exit
    else
      printf '%b: ' "$2"; read -r -s _ans || eof; echo
      break
    fi
  done
  printf -v "$1" '%s' "$_ans"
}
yes_no() {   # yes_no "question" [height]  (0 = yes; with a height the text scrolls)
  if [ "$TUI" -eq 1 ]; then
    if [ -n "${2:-}" ]; then whiptail --title "$TITLE" --scrolltext --yesno "$1" "$2" 78
    else whiptail --title "$TITLE" --yesno "$1" 14 78; fi
  else
    local _ans
    printf '%b [y/N] ' "$1"; read -r _ans || eof
    case "$_ans" in y|Y|yes|YES|s|S|si|SI) return 0 ;; *) return 1 ;; esac
  fi
}
say() {   # message confirmed with Enter
  if [ "$TUI" -eq 1 ]; then whiptail --title "$TITLE" --msgbox "$1" 16 78; else printf '%b\n' "$1"; fi
}
step() { echo; echo ">> $*"; }
run() { echo "\$ $*"; "$@"; }   # shows the command and runs it

url_host() { sed -E 's#^[a-z+]+://([^@/]*@)?([^/:]+).*#\2#' <<<"$1"; }
re_esc() { sed 's/[][\/.^$*|]/\\&/g' <<<"$1"; }
rep_esc() { sed 's/[\/&|]/\\&/g' <<<"$1"; }

# --- git login: asked once, used by git and by nix ---------------------------
# shellcheck disable=SC2016  # the variables are expanded by git's shell
HELPER_ENV='!f() { if [ "$1" = get ]; then printf "username=%s\npassword=%s\n" "$GIT_U" "$GIT_P"; fi; }; f'
GIT_U="" GIT_P="" LOGIN_SET=0
can_read() { GIT_TERMINAL_PROMPT=0 git ls-remote "$1" >/dev/null 2>&1; }
login_for() {   # 0 = repository readable (after the login, if needed)
  local url=$1
  can_read "$url" && return 0
  ask GIT_U "Login for $(url_host "$url")\n\nUser:" "$GIT_U"
  ask_secret GIT_P "Password or token of $GIT_U on $(url_host "$url"):"
  export GIT_U GIT_P
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0="" \
         GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1="$HELPER_ENV"
  if ! can_read "$url"; then
    say "Access failed to:\n$url\n\nWrong URL, repository does not exist or login rejected. Try again."
    return 1
  fi
  LOGIN_SET=1
}

# --- parts shared by "new PC" and "restore" ----------------------------------
hw_source() {   # hardware-configuration.nix of this installation
  local f
  for f in "$TARGET/hardware-configuration.nix" "$TARGET"/hosts/*/hardware-configuration.nix; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}
ask_save_cred() {
  save_cred=0
  if [ "$LOGIN_SET" -eq 1 ] && [ "$(id -u)" -eq 0 ]; then
    if yes_no "Save the git login in /root/.git-credentials (readable only by root)?\n\nupdate-check (daily check), config-update and system-update use it without asking again."; then
      save_cred=1
    fi
  fi
}
confirm_summary() {   # shows the summary and asks for confirmation
  if [ "$TUI" -eq 1 ]; then
    whiptail --title "$TITLE" --yesno "Summary:\n\n$1\n\nRun now?" 24 90 || confirm_exit
    clear
  else
    echo "------------------------------------------------------------------"
    echo "$1"
    echo "------------------------------------------------------------------"
    yes_no "Run now?" || { echo "Cancelled: nothing changed."; exit 0; }
  fi
}
save_credentials() {
  local u line
  step "Saving the login in /root/.git-credentials"
  enc() { jq -rn --arg s "$1" '$s | @uri'; }
  touch /root/.git-credentials
  chmod 600 /root/.git-credentials
  for u in "$repo" "$base"; do
    line="https://$(enc "$GIT_U"):$(enc "$GIT_P")@$(url_host "$u")"
    grep -qxF "$line" /root/.git-credentials || echo "$line" >> /root/.git-credentials
  done
}
install_target() {   # puts $NEW in place of $TARGET (installer or old configuration)
  local backup
  if [ -e "$TARGET" ]; then
    backup="$TARGET.orig"
    [ -e "$backup" ] && backup="$TARGET.orig-$(date +%Y%m%d-%H%M)"
    step "Moving the current configuration to $backup"
    run mv "$TARGET" "$backup"
  fi
  run mv "$NEW" "$TARGET"
  trap - EXIT
  cd "$TARGET"
}
apply_config() {   # nixos-rebuild switch; $1 = commit to make if it fails (empty = none)
  [ "$SWITCH" -eq 1 ] || return 0
  # on the first run flakes and the Proxmox cache are not active yet
  export NIX_CONFIG='experimental-features = nix-command flakes
extra-substituters = https://cache.saumon.network/proxmox-nixos
extra-trusted-public-keys = proxmox-nixos:D9RYSWpQQC/msZUWphOY2I5RLH5Dd6yQcaHIuug7dWM='
  local log=/root/rebuild.log
  [ -w /root ] || log=$(mktemp)
  step "Applying the configuration (log in $log): the first time takes a long time"
  if ! run nixos-rebuild switch --flake "$TARGET#$name" 2>&1 | tee "$log"; then
    if [ -n "$1" ]; then "${G[@]}" commit -q -m "$1"; fi
    echo
    echo "!! nixos-rebuild failed: do NOT reboot. Error in $log"
    echo "   Fix $TARGET/hosts/$name/default.nix, then:"
    echo "   sudo nixos-rebuild switch --flake $TARGET#$name"
    echo "   cd $TARGET && sudo git push -u origin HEAD:main"
    exit 1
  fi
}
push_config() {
  step "Pushing to the server"
  if GIT_TERMINAL_PROMPT=0 "${G[@]}" push -q -u origin HEAD:main; then
    echo "   Configuration pushed to $repo"
  else
    echo "!! Push failed: try again with  cd $TARGET && sudo git push -u origin HEAD:main"
  fi
}
finish() {   # $1 = AD domain (empty = none), $2 = "new" or "restore"
  local next
  if [ "$SWITCH" -eq 1 ]; then
    next=" • sudo reboot"
  else
    next=" • sudo nixos-rebuild switch --flake $TARGET#$name   and then  sudo reboot"
  fi
  if [ -n "$1" ]; then
    next="$next
 • sudo ad-join administrator      (join the domain $1)"
  fi
  if [ "$2" = new ]; then
    next="$next
 • sudo driver-check               paste the block into $TARGET/hosts/$name/default.nix
 • sudo config-update              apply and push the change to the server"
  else
    next="$next
 • sudo driver-check               check drivers and firmware of this PC
 • sudo config-update              bring the generic configuration to the latest version"
  fi
  echo
  echo "Done. Next steps:"
  echo "$next"
  if [ "$TUI" -eq 1 ]; then
    echo
    read -r -p "Press Enter to close... " _
  fi
}

# ===========================================================================
# 1. Questions (nothing changes until the final confirmation)
# ===========================================================================
if [ "$TUI" -eq 1 ]; then
  whiptail --title "$TITLE" --yesno "This wizard prepares the configuration of a new PC:\n\n • starts from the generic template hosts/workstation\n • creates the PC repository with the \"base\" input\n • puts it in $TARGET, applies it and pushes it to the server\n\nFirst create a PRIVATE and EMPTY repository on the git server (not a fork), e.g. nix_workstation_<pc-name>.\n\nNothing is changed until the final summary. Continue?" 20 78 ||
    { clear; exit 0; }
else
  echo "== new-pc: new PC (template hosts/workstation, folder $TARGET) =="
fi

name="" current=""
current=$(cat /proc/sys/kernel/hostname 2>/dev/null || true)
[ "$current" = nixos ] && current=""
while true; do
  ask name "PC name\n\nMax 15 characters: letters, digits, hyphen. It is also the name in the AD domain and the flake profile ($TARGET#name)." "$current"
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,14}$ ]] && break
  say "Invalid name: \"$name\""
done

repo="" base="" base_def=""
while true; do
  ask repo "URL of this PC's repository\n\nEmpty for a new PC; with a configuration already saved the wizard offers to restore it.\nExample: https://git.example.com/user/nix_workstation_$name.git" "$repo"
  [ -n "$repo" ] && login_for "$repo" && break
done

# --- repository not empty: restore a saved configuration ---------------------
if [ -n "$(git ls-remote --heads "$repo")" ]; then
  NEW="$TARGET.new-$$"
  trap 'rm -rf "$NEW"' EXIT
  "${G[@]}" clone -q "$repo" "$NEW" 2>/dev/null || true
  if [ -d "$NEW/.git" ] && [ ! -f "$NEW/flake.nix" ]; then   # server HEAD on an empty branch
    "${G[@]}" -C "$NEW" checkout -q -B main origin/main 2>/dev/null || true
  fi
  rname="" rbase=""
  if [ -f "$NEW/flake.nix" ]; then
    rname=$(sed -nE 's/.*nixosConfigurations\.([A-Za-z0-9-]+)[[:space:]]*=[[:space:]]*base\.lib\.mkHost.*/\1/p' "$NEW/flake.nix" | head -n1)
    rbase=$(sed -nE 's/.*base\.url[[:space:]]*=[[:space:]]*"git\+([^"?]+).*/\1/p' "$NEW/flake.nix" | head -n1)
  fi
  if [ -z "$rname" ] || [ -z "$rbase" ] || [ ! -f "$NEW/hosts/$rname/default.nix" ]; then
    say "$repo is not empty but does not contain a recognizable PC configuration\n(flake.nix with base.lib.mkHost and hosts/<name>/default.nix).\n\nA new PC needs an empty repository. Nothing has been changed."
    exit 1
  fi
  last=$(git -C "$NEW" log -1 --date=short --format='%cd: %s')
  if ! yes_no "The repository already contains the configuration of PC \"$rname\"\n(last commit $last).\n\nRestore it on this PC?\n\nNo = exit without changes (a new PC needs an empty repository)."; then
    if [ "$TUI" -eq 1 ]; then clear; fi
    echo "Cancelled: nothing changed."; exit 0
  fi

  name=$rname base=$rbase
  until login_for "$base"; do :; done
  hw=$(hw_source || true) use_hw=0
  if [ -n "$hw" ] && yes_no "Use the hardware-configuration.nix of this installation?\n($hw)\n\nYes if the disk was formatted or this is another PC: the disk identifiers change and the saved one would not boot the system.\nNo only if it is the same installation."; then
    use_hw=1
  fi
  # graphics drivers: the saved ones belong to the old PC (another GPU, other
  # PCI addresses = black screen); compare them with the ones detected here
  drv_new="" use_drv=0
  if [ "$use_hw" -eq 1 ] && command -v lspci >/dev/null; then
    gpu_detect
    drv_new=$(drivers_block)
    drv_rc=0
    python3 "$NEW_PC_SRC/modules/hardware/drivers-set.py" "$NEW/hosts/$name/default.nix" --check <<<"$drv_new" || drv_rc=$?
    if [ "$drv_rc" -eq 3 ]; then
      drv_old=$(sed -n '/^[[:space:]]*my\.hardware\.drivers = {/,/^  };/p' "$NEW/hosts/$name/default.nix")
      if yes_no "The graphics drivers saved for $name do not match the graphics card of this PC.\n\nSaved in the repository:\n$drv_old\n\nDetected on this PC:\n$drv_new\n\nReplace them with the detected ones? (Recommended: wrong drivers can leave a black screen. Bluetooth, printers and scanners settings are kept.)" 30; then
        use_drv=1
      fi
    fi
  fi
  ask_save_cred
  confirm_summary "Restore of PC:       $name
Profile:             $TARGET#$name
PC repository:       $repo
Base configuration:  $base
Last commit:         $last
Hardware:            $([ "$use_hw" -eq 1 ] && echo "from this installation ($hw)" || echo "the one saved in the repository")
Graphics drivers:    $([ "$use_drv" -eq 1 ] && echo "detected on this PC" || echo "as saved in the repository")
Login saved:         $([ "$save_cred" -eq 1 ] && echo /root/.git-credentials || echo no)
Apply:               $([ "$SWITCH" -eq 1 ] && echo "nixos-rebuild switch (may take a long time)" || echo "no (--no-switch)")"

  echo "=================================================================="
  echo " new-pc: restore of $name"
  echo "=================================================================="
  "${G[@]}" -C "$NEW" checkout -q -B main
  if [ "$use_hw" -eq 1 ]; then
    step "Using the hardware-configuration.nix of this installation"
    install -m 644 "$hw" "$NEW/hosts/$name/hardware-configuration.nix"
    "${G[@]}" -C "$NEW" add -A
    if ! "${G[@]}" -C "$NEW" diff --cached --quiet; then
      "${G[@]}" -C "$NEW" commit -q -m "$name: hardware-configuration.nix of the new installation"
    fi
  fi
  if [ "$use_drv" -eq 1 ]; then
    step "Using the graphics drivers detected on this PC"
    python3 "$NEW_PC_SRC/modules/hardware/drivers-set.py" "$NEW/hosts/$name/default.nix" <<<"$drv_new"
    "${G[@]}" -C "$NEW" add -A
    if ! "${G[@]}" -C "$NEW" diff --cached --quiet; then
      "${G[@]}" -C "$NEW" commit -q -m "$name: graphics drivers of the new PC"
    fi
  fi
  if [ "$save_cred" -eq 1 ]; then save_credentials; fi
  install_target
  apply_config ""
  if [ "$(git rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 1)" -gt 0 ]; then push_config; fi
  rdomain=""
  if grep -A1 'my.activeDirectory = {' "hosts/$name/default.nix" | grep -q 'enable = true;'; then
    rdomain=$(sed -nE 's/^[[:space:]]*domain = "([^"]+)".*/\1/p' "hosts/$name/default.nix" | head -n1)
  fi
  finish "$rdomain" restore
  exit 0
fi

base_def=${repo%.git}
for suffix in "_$name" "-$name"; do
  if [ "${base_def%"$suffix"}" != "$base_def" ]; then base_def="${base_def%"$suffix"}.git"; break; fi
done
[ "$base_def" = "${repo%.git}" ] && base_def=""
# started with install.sh: the address the generic repository was cloned from
base_def=${NEW_PC_BASE:-$base_def}
while true; do
  ask base "URL of the generic repository (shared configuration, \"base\" input)" "${base:-$base_def}"
  [ -n "$base" ] && login_for "$base" && break
done

admin="" domain="" sudo_users="" hash="" root_hash="" p1="" p2=""
ask admin "Name of the local administrator (always available, even without a domain)" "localadmin"
while true; do
  ask_secret p1 "Password of $admin"
  ask_secret p2 "Repeat the password of $admin"
  [ -n "$p1" ] && [ "$p1" = "$p2" ] && break
  say "The passwords are empty or do not match: try again."
done
hash=$(printf '%s' "$p1" | mkpasswd -m sha-512 --stdin)
p1="" p2=""
if yes_no "Use the same password for root too?\n\nNeeded to log in to the Proxmox Web UI as root@pam (real USB/PCI devices, backup restore). Over SSH, root password login stays blocked."; then
  root_hash=$hash
fi

ask domain "Active Directory domain (DNS, e.g. example.local)\n\nLeave empty for a PC without a domain." ""
domain=$(tr '[:upper:]' '[:lower:]' <<<"$domain")
if [ -n "$domain" ]; then
  ask sudo_users "AD users as administrators (sudo), separated by spaces\n\nEmpty = only the 'domain admins' group." ""
fi

# --- applications and virtualization: check list -----------------------------
# key|description|default (as in the hosts/workstation template)
FEATURES=(
  "firefox|Firefox|on"
  "office365|Microsoft 365 (web apps with Edge)|on"
  "onlyoffice|ONLYOFFICE (documents, also offline)|off"
  "localsend|LocalSend (files between devices)|on"
  "vscode|Visual Studio Code|on"
  "whatsapp|WhatsApp (ZapZap)|on"
  "freerdp|xfreerdp (remote desktop)|on"
  "pinta|Pinta (drawing and photo editing)|on"
  "naps2|NAPS2 (scan to PDF)|on"
  "haruna|Haruna (video player)|on"
  "solidcraft|SolidCraft (3D CAD, compiled: first build ~30 min)|on"
  "prusaslicer|PrusaSlicer (3D printing)|on"
  "bambustudio|Bambu Studio (Bambu Lab slicer, compiled: slow first build)|off"
  "proxmox|Proxmox VE + VM network 172.30.20.0/24|on"
  "vmstation|VM Station (RDP/SSH console for the VMs)|on"
)
feature_keys=() feature_defaults=""
for f in "${FEATURES[@]}"; do
  IFS='|' read -r k _ d <<<"$f"
  feature_keys+=("$k")
  [ "$d" = on ] && feature_defaults="$feature_defaults $k"
done
selected=""
while true; do
  if [ "$TUI" -eq 1 ]; then
    items=()
    for f in "${FEATURES[@]}"; do
      IFS='|' read -r k desc d <<<"$f"
      items+=("$k" "$desc" "$([ "$d" = on ] && echo ON || echo OFF)")
    done
    if selected=$(whiptail --title "$TITLE" --separate-output --checklist \
          "What to install on this PC (Space = check, Enter = confirm)\n\nIt can be changed later in hosts/$name/default.nix." \
          24 78 14 "${items[@]}" 3>&1 1>&2 2>&3); then
      selected=$(tr '\n' ' ' <<<"$selected")
      break
    fi
    confirm_exit
  else
    ask selected "What to install (keys separated by spaces; empty = defaults)\nAvailable: ${feature_keys[*]}" "${feature_defaults# }"
    bad=""
    for k in $selected; do
      [[ " ${feature_keys[*]} " == *" $k "* ]] || bad="$bad $k"
    done
    [ -z "$bad" ] && break
    say "Unknown keys:$bad"
  fi
done
is_selected() { [[ " $selected " == *" $1 "* ]]; }

ask_save_cred

summary="PC:                  $name
Profile:             $TARGET#$name
PC repository:       $repo
Base configuration:  $base
Administrator:       $admin$([ -n "$root_hash" ] && echo "  (+ root password)")
AD domain:           ${domain:-none}${sudo_users:+
AD sudo users:       $sudo_users}
To install:          $(fold -s -w 60 <<<"${selected% }" | sed '2,$s/^/                     /')
Login saved:         $([ "$save_cred" -eq 1 ] && echo /root/.git-credentials || echo no)
Apply:               $([ "$SWITCH" -eq 1 ] && echo "nixos-rebuild switch (may take a long time)" || echo "no (--no-switch)")"
confirm_summary "$summary"

# ===========================================================================
# 2. Execution
# ===========================================================================
echo "=================================================================="
echo " new-pc: creating $name"
echo "=================================================================="

step "Checking that the PC repository is empty"
if [ -n "$(git ls-remote --heads "$repo")" ]; then
  say "$repo is not empty: it already contains a configuration.\n\nTo use it on this PC:\nsudo git clone $repo $TARGET\n\nNothing has been changed."
  exit 1
fi

NEW="$TARGET.new-$$"
trap 'rm -rf "$NEW"' EXIT
step "Cloning the PC repository"
run "${G[@]}" clone -q "$repo" "$NEW" 2>/dev/null
"${G[@]}" -C "$NEW" checkout -q -B main

step "Copying the hosts/workstation template to hosts/$name"
H="$NEW/hosts/$name/default.nix"
mkdir -p "$NEW/hosts/$name"
install -m 644 "$NEW_PC_SRC/hosts/workstation/default.nix" "$H"
install -m 644 "$NEW_PC_SRC/.gitignore" "$NEW/.gitignore"

# hardware: the one generated by the installer, otherwise detected now
hw=$(hw_source || true)
if [ -n "$hw" ]; then
  install -m 644 "$hw" "$NEW/hosts/$name/hardware-configuration.nix"
  echo "   hardware-configuration.nix taken from $hw"
elif command -v nixos-generate-config >/dev/null; then
  nixos-generate-config --show-hardware-config > "$NEW/hosts/$name/hardware-configuration.nix"
  echo "   hardware-configuration.nix generated now (nixos-generate-config)"
else
  say "hardware-configuration.nix not found and nixos-generate-config is missing.\n\nNothing has been changed."
  exit 1
fi

# stateVersion of the installation (must not be changed afterwards)
state=""
if [ -f "$TARGET/configuration.nix" ]; then
  state=$(grep -v '^[[:space:]]*#' "$TARGET/configuration.nix" |
    sed -nE 's/.*system\.stateVersion[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
fi

step "Writing the values into hosts/$name/default.nix"
subst() {   # replaces an exact text of the template; stops if the template has changed
  if ! grep -qF -- "$1" "$H"; then
    say "The hosts/workstation/default.nix template has changed: cannot find\n$1\n\nUpdate pkgs/new-pc/new-pc.sh in the generic repository. Nothing has been changed."
    exit 1
  fi
  sed -i "s|$(re_esc "$1")|$(rep_esc "$2")|" "$H"
}
subst '#  HOST: workstation' "#  HOST: $name"
subst 'hostName = "workstation";' "hostName = \"$name\";"
subst 'name = "localadmin";' "name = \"$admin\";"
subst '    password = "CHANGEME";' '    # password = "CHANGEME";   # replaced by hashedPassword'
# shellcheck disable=SC2016  # "$6$..." is template text
subst '# hashedPassword = "$6$...";' "hashedPassword = \"$hash\";"
if [ -n "$root_hash" ]; then
  # shellcheck disable=SC2016
  subst '# rootHashedPassword = "$6$...";' "rootHashedPassword = \"$root_hash\";"
fi
if [ -n "$domain" ]; then
  subst 'domain = "example.local";' "domain = \"$domain\";"
  if [ -n "$sudo_users" ]; then
    list=""
    for u in $sudo_users; do list="$list \"$u\""; done
    subst '# sudoUsers = [ "john.doe" ];' "sudoUsers = [$list ];"
  fi
else
  sed -i '/my\.activeDirectory = {/,/};/ s/enable = true;/enable = false;/' "$H"
  grep -A1 'my.activeDirectory = {' "$H" | grep -q 'enable = false;' ||
    { say "Cannot disable Active Directory in the template. Nothing has been changed."; exit 1; }
fi
if [ "$save_cred" -eq 1 ]; then
  grep -q 'vaultCredentialsFile = ' "$H" ||
    { say "vaultCredentialsFile not found in the template. Nothing has been changed."; exit 1; }
  sed -i '/vaultCredentialsFile = /a\    gitCredentialsFile = "/root/.git-credentials";  # git login for update-check and config-update' "$H"
fi
if [ -n "$state" ]; then
  sed -i -E "s|system\.stateVersion = \"[^\"]*\";|system.stateVersion = \"$state\";|" "$H"
fi

# applications and virtualization chosen in the list
block_off() {   # block_off "block start": enable = false in the block { ... };
  grep -qF -- "$1" "$H" ||
    { say "The template has changed: cannot find\n$1\n\nUpdate pkgs/new-pc/new-pc.sh. Nothing has been changed."; exit 1; }
  sed -i "/$(re_esc "$1")/,/};/ s/enable = true;/enable = false;/" "$H"
}
# (same editor as app-manager: handles enabled, disabled, commented and missing lines)
app_args=()
for k in "${feature_keys[@]}"; do
  v=$(is_selected "$k" && echo true || echo false)
  case "$k" in
    proxmox)   [ "$v" = true ] || { block_off 'proxmox = {'; block_off 'vmNetwork = {'; } ;;
    vmstation) app_args+=("my.vmstation=$v") ;;
    *)         app_args+=("$k=$v") ;;
  esac
done
python3 "$NEW_PC_SRC/modules/maintenance/app-set.py" "$H" "${app_args[@]}" ||
  { say "Cannot write the applications into $H. Nothing has been changed."; exit 1; }

# package versions: same URLs as the generic repository, but locked in the PC
# repository (config-update updates only "base", system-update the packages)
gen_url() {
  sed -nE "s#^[[:space:]]*$1\.url[[:space:]]*=[[:space:]]*\"([^\"]+)\".*#\1#p" "$NEW_PC_SRC/flake.nix" | head -n1
}
U_NIXPKGS=$(gen_url nixpkgs)
U_PROXMOX=$(gen_url proxmox-nixos)
U_SOLID=$(gen_url solidcraft)

step "Writing flake.nix (base input = $base)"
cat > "$NEW/flake.nix" <<EOF
{
  description = "Configuration of PC $name (based on nix_workstation)";

  inputs = {
    # generic configuration: main branch of the shared repository (config-update)
    base.url = "git+$base";

    # packages: updated only by system-update; solidcraft follows stable
    # releases only (tag), never prereleases
    nixpkgs.url = "$U_NIXPKGS";
    proxmox-nixos.url = "$U_PROXMOX";
    solidcraft.url = "$U_SOLID";
    base.inputs.nixpkgs.follows = "nixpkgs";
    base.inputs.proxmox-nixos.follows = "proxmox-nixos";
    base.inputs.solidcraft.follows = "solidcraft";
  };

  outputs = { base, ... }: {
    # nixos-rebuild switch --flake $TARGET#$name
    nixosConfigurations.$name = base.lib.mkHost { name = "$name"; path = ./hosts/$name; };
  };
}
EOF

if [ "$save_cred" -eq 1 ]; then save_credentials; fi
install_target
"${G[@]}" add -A

step "Fetching the generic configuration and creating flake.lock"
run nix --extra-experimental-features 'nix-command flakes' flake lock
"${G[@]}" add -A

apply_config "$name: initial configuration (not applied)"
"${G[@]}" commit -q -m "$name: initial configuration"
push_config
finish "$domain" new
