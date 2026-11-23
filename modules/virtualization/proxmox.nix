# Proxmox VE (proxmox-nixos). Web UI: https://<vmNetwork.address>:8006
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.my.virtualization.proxmox;
  net = config.my.virtualization.vmNetwork;

  # Web UI widget toolkit without the "No valid subscription" popup.
  # Same name/version as the original: required by replaceDependencies.
  widgetToolkitNoNag = pkgs.proxmox-widget-toolkit.overrideAttrs (old: {
    # checked_command(cmd) shows the popup and then runs cmd: make it run cmd
    # right away, both in proxmoxlib.js and in .min.js (where the parameter has
    # a short name, e.g. "a", so it is read from the code).
    postInstall = (old.postInstall or "") + ''
      ID='[A-Za-z_$][A-Za-z0-9_$]*'
      failed=0; count=0
      for f in $out/share/javascript/proxmox-widget-toolkit/proxmoxlib*.js; do
        [ -f "$f" ] || continue
        count=$((count + 1))
        sed -Ei "s/(checked_command: *function *\( *($ID) *\) *\{)/\1 \2(); return;/" "$f"
        if grep -Eq "checked_command: *function *\( *$ID *\) *\{ $ID\(\); return;" "$f"; then
          echo "nag removed in $f"
        else
          echo "ERROR: nag NOT removed in $f"
          grep -Eo 'checked_command.{0,80}' "$f" | head -3 || true
          failed=1
        fi
      done
      # The first line of proxmoxlib.js becomes the script's "?ver=": with Nix
      # it never changes and the browser would keep the old file with the popup cached.
      sed -Ei '1s|^// (.*)$|// \1-${old.version}-nonag2|' \
        $out/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
      head -1 $out/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
      if [ "$count" -eq 0 ] || [ "$failed" -ne 0 ]; then
        echo "ERROR: subscription popup NOT removed: the proxmoxlib code has changed."
        echo "Set my.virtualization.proxmox.removeSubscriptionNag = false; and report the problem."
        exit 1
      fi
    '';
  });
in
{
  options.my.virtualization.proxmox = {
    enable = lib.mkEnableOption "Proxmox VE";

    adminUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "${config.my.users.localAdmin.name}@pam" ];
      defaultText = "[ \"<local admin user>@pam\" ]";
      description = "Users (realm @pam) made Proxmox Administrators at boot.";
    };

    nfsClient = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "NFS storage support (showmount, mount.nfs, rpcbind) for Proxmox.";
    };

    removeSubscriptionNag = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Removes the 'No valid subscription' popup from the Web UI.";
    };
  };

  config = lib.mkIf cfg.enable {

    services.proxmox-ve = {
      enable = true;
      # VM bridge IP: does not change when the PC changes network
      ipAddress = net.address;
      bridges = lib.optional net.enable net.bridge;
    };

    nixpkgs.overlays = [ inputs.proxmox-nixos.overlays.x86_64-linux ];

    # Replaces the widget toolkit system-wide without rebuilding Proxmox
    # (pve-manager uses proxmox-nixos's internal copy, so a normal overlay
    # would not be enough).
    system.replaceDependencies.replacements = lib.mkIf cfg.removeSubscriptionNag [{
      original = pkgs.proxmox-widget-toolkit;
      replacement = widgetToolkitNoNag;
    }];

    # Proxmox uses showmount and mount -t nfs: the daemons need nfs-utils and rpcbind in their PATH
    boot.supportedFilesystems = lib.mkIf cfg.nfsClient [ "nfs" ];
    services.rpcbind.enable = lib.mkIf cfg.nfsClient true;
    environment.systemPackages = lib.mkIf cfg.nfsClient [ pkgs.nfs-utils ];
    systemd.services.pvedaemon.path = lib.mkIf cfg.nfsClient [ pkgs.nfs-utils pkgs.util-linux ];
    systemd.services.pvestatd.path = lib.mkIf cfg.nfsClient [ pkgs.nfs-utils pkgs.util-linux ];
    systemd.services.pveproxy.path = lib.mkIf cfg.nfsClient [ pkgs.nfs-utils pkgs.util-linux ];

    # The project's binary cache (avoids building Proxmox)
    nix.settings = {
      substituters = [ "https://cache.saumon.network/proxmox-nixos" ];
      trusted-public-keys = [ "proxmox-nixos:D9RYSWpQQC/msZUWphOY2I5RLH5Dd6yQcaHIuug7dWM=" ];
    };

    boot.extraModprobeConfig = ''
      options kvm_intel nested=1
      options kvm_amd nested=1
    '';

    # Makes the listed users Proxmox administrators (root on NixOS has no password)
    systemd.services.pve-admin-users = {
      description = "Configure the Proxmox administrators";
      wantedBy = [ "multi-user.target" ];
      after = [ "pve-cluster.service" "pvedaemon.service" ];
      wants = [ "pve-cluster.service" ];
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.concatMapStrings (u: ''
        if ! pveum user list --output-format json 2>/dev/null | grep -q '"userid":"${u}"'; then
          pveum user add '${u}' --comment 'created by NixOS' || true
        fi
        pveum acl modify / --users '${u}' --roles Administrator || true
      '') cfg.adminUsers;
    };
  };
}
