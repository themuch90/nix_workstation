#!/usr/bin/env bash
# Starts the new-pc wizard from a clone of this repository.
#   sudo ./install.sh [new-pc options]
# The address this repository was cloned from (remote "origin") is read from
# .git/config and proposed as the URL of the generic repository, so no
# address is written in the files. git is not needed here: on a fresh NixOS
# it is not installed, and root would refuse a clone owned by another user.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

origin_url() {
  [ -f "$DIR/.git/config" ] || return 0      # e.g. downloaded as a zip
  sed -n '/^\[remote "origin"\]/,/^\[/s/^[[:space:]]*url[[:space:]]*=[[:space:]]*//p' "$DIR/.git/config" | head -n1
}

# address usable by root on the new PC: https, without a saved login
public_url() {
  sed -E -e 's#^ssh://([^@/]*@)?([^/:]+)(:[0-9]+)?/#https://\2/#' \
         -e 's#^[A-Za-z0-9._-]+@([^:/]+):#https://\1/#' \
         -e 's#^(https?://)[^@/]*@#\1#' <<<"$1"
}

url=$(public_url "$(origin_url)")
case "$url" in
  http://*|https://*)
    echo ">> Generic repository: $url"
    export NEW_PC_BASE="$url" ;;
  *) echo ">> Address of the generic repository not found: the wizard will ask for it." ;;
esac

# only the configuration, without .git: nix copies the folder to its store,
# readable by everyone, and .git/config could hold a token
SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT
cp -r "$DIR"/{flake.nix,hosts,modules,pkgs,.gitignore} "$SRC"/

nix --extra-experimental-features 'nix-command flakes' \
  run --no-write-lock-file "path:$SRC#new-pc" -- "$@"
