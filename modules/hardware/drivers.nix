# Firmware, microcode, Intel/AMD/NVIDIA video drivers (PRIME included), Bluetooth,
# printers and scanners. driver-check suggests the my.hardware.drivers block for the PC.
{ config, lib, pkgs, flakeHost, ... }:
let
  cfg = config.my.hardware.drivers;
  flakePath = config.my.maintenance.updateCheck.flakePath;
  b = lib.boolToString;

  driverCheck = pkgs.writeShellApplication {
    name = "driver-check";
    runtimeInputs = with pkgs; [
      pciutils usbutils coreutils gnugrep gnused gawk systemd
      config.services.fwupd.package
    ];
    text = ''
      SKIP_FW=0
      [ "''${1:-}" = "--no-firmware" ] && SKIP_FW=1

      CUR_ENABLE=${b cfg.enable}
      CUR_INTEL=${b cfg.intel.enable}
      CUR_AMD=${b cfg.amd.enable}
      CUR_NVIDIA=${b cfg.nvidia.enable}
      CUR_OPEN=${b cfg.nvidia.open}
      CUR_DRV=${cfg.nvidia.driver}
      CUR_PRIME=${b cfg.nvidia.prime.enable}
      CUR_BT=${b cfg.bluetooth}

      hr() { printf '\n== %s ==\n' "$1"; }
      indent() { while IFS= read -r l; do printf '%s%s\n' "$1" "$l"; done; }
      ${builtins.readFile ./gpu-detect.sh}
      driver_of() {
        local d
        d=$(lspci -s "$1" -k | sed -n 's/.*Kernel driver in use: //p')
        echo "''${d:-NONE}"
      }

      [ "$(id -u)" -ne 0 ] && echo "Note: with sudo the analysis is complete (kernel log, firmware)."

      hr "Processor"
      cpu=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')
      mc=$(grep -m1 microcode /proc/cpuinfo | awk '{print $3}' || true)
      echo "• $cpu"
      echo "    microcode: ''${mc:-unknown} (updated at boot by the module)"
      echo "    kernel: $(uname -r)"

      hr "Graphics card"
      # called by gpu_detect for every card
      gpu_found() {
        echo "• $2"
        echo "    location $(busid "$1"), driver in use: $(driver_of "$1")"
        if [ "$3" = 10de ]; then
          echo "    suitable NVIDIA driver: $want_drv$($want_open && echo ', open modules')"
          case "$want_drv" in legacy_470|legacy_390)
            echo "    !! very old GPU: the legacy driver may not work with recent kernels;"
            echo "       in that case better keep nouveau (nvidia.enable = false)." ;;
          esac
        fi
      }
      gpu_detect

      if $want_prime; then
        echo "  → hybrid system: integrated graphics + NVIDIA (PRIME offload)."
        echo "    Apps use the integrated GPU; to use the NVIDIA one, e.g.: nvidia-offload blender"
      fi

      hr "Devices without a driver"
      # host bridges, ISA bridges, RAM controllers excluded: they need none
      nodrv=$(lspci -Dnnk | gawk '
        /^[0-9a-f]{4}:/ { if (dev != "" && !drv) print dev; dev=$0; drv=0; next }
        /Kernel driver in use:/ { drv=1 }
        END { if (dev != "" && !drv) print dev }' \
        | grep -vE '\[(0600|0601|0500|0580)\]' || true)
      if [ -n "$nodrv" ]; then
        indent '• ' <<<"$nodrv"
        echo "  (some system controllers work without a dedicated driver)"
      else
        echo "✓ all PCI devices have a driver"
      fi

      want_bt=false
      for f in /sys/class/bluetooth/hci*; do [ -e "$f" ] && want_bt=true; done
      lsusb 2>/dev/null | grep -qi bluetooth && want_bt=true
      $want_bt && echo "• Bluetooth present"

      hr "Firmware errors in the log"
      errs=$(journalctl -k -b --no-pager 2>/dev/null \
        | grep -iE 'firmware.*(fail|error)|failed to load.*firmware|direct firmware load' || true)
      if [ -n "$errs" ]; then
        tail -15 <<<"$errs" | indent '  '
      elif [ "$(id -u)" -ne 0 ]; then
        echo "(kernel log not readable without sudo)"
      else
        echo "✓ no firmware loading errors"
      fi

      hr "Firmware updates (BIOS, SSD, dock... via fwupd/LVFS)"
      if [ "$SKIP_FW" -eq 1 ]; then
        echo "(skipped)"
      else
        fwupdmgr refresh --force >/dev/null 2>&1 </dev/null || true
        rc=0
        out=$(fwupdmgr get-updates --no-unreported-check 2>&1 </dev/null) || rc=$?
        if [ "$rc" -eq 0 ]; then
          indent '  ' <<<"$out"
          echo "  → to install them: sudo fwupdmgr update"
        elif [ "$rc" -eq 2 ]; then
          echo "✓ no firmware updates available"
        else
          echo "  unable to check (offline or unsupported device)"
        fi
      fi

      hr "Recommended configuration"
      diff=0
      chk() {
        if [ "$2" != "$3" ]; then
          echo "• $1: current $2 → recommended $3"; diff=1
        fi
      }
      chk "enable" "$CUR_ENABLE" true
      chk "intel.enable" "$CUR_INTEL" "$want_intel"
      chk "amd.enable" "$CUR_AMD" "$want_amd"
      chk "nvidia.enable" "$CUR_NVIDIA" "$want_nvidia"
      if $want_nvidia; then
        chk "nvidia.driver" "$CUR_DRV" "$want_drv"
        chk "nvidia.open" "$CUR_OPEN" "$want_open"
        chk "nvidia.prime.enable" "$CUR_PRIME" "$want_prime"
      fi
      # bluetooth is never advised against: it is also needed for future peripherals
      $want_bt && chk "bluetooth" "$CUR_BT" true

      if [ "$diff" -eq 0 ]; then
        echo "✓ the current configuration is already the recommended one for this hardware"
        exit 0
      fi

      echo
      echo "Copy this block into ${flakePath}/hosts/${flakeHost}/default.nix"
      echo "(replacing the existing one), then apply with:"
      echo "  sudo nixos-rebuild switch --flake ${flakePath}#${flakeHost}"
      echo
      drivers_block
    '';
  };
in
{
  options.my.hardware.drivers = {
    enable = lib.mkEnableOption "firmware, video drivers, Bluetooth, printers and scanners";

    allFirmware = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "All available firmware, non-free included (Wi-Fi, GPU, Bluetooth...).";
    };

    intel.enable = lib.mkEnableOption "video acceleration for Intel graphics (VA-API)";
    amd.enable = lib.mkEnableOption "amdgpu driver loaded at boot (AMD graphics)";

    nvidia = {
      enable = lib.mkEnableOption "NVIDIA proprietary driver";
      driver = lib.mkOption {
        type = lib.types.enum [ "stable" "legacy_580" "legacy_470" "legacy_390" ];
        default = "stable";
        description = ''
          Driver branch: stable for GTX 16xx/RTX 20xx and later,
          legacy_580 for Maxwell/Pascal/Volta (GTX 7xx-10xx, Quadro M/P),
          legacy_470 for Kepler, legacy_390 for Fermi. driver-check tells which.
        '';
      };
      open = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "NVIDIA open kernel modules (recommended from GTX 16xx/RTX 20xx on; false for older GPUs).";
      };
      prime = {
        enable = lib.mkEnableOption "PRIME offload (hybrid laptops: integrated + NVIDIA)";
        intelBusId = lib.mkOption { type = lib.types.str; default = ""; example = "PCI:0:2:0"; };
        amdgpuBusId = lib.mkOption { type = lib.types.str; default = ""; example = "PCI:5:0:0"; };
        nvidiaBusId = lib.mkOption { type = lib.types.str; default = ""; example = "PCI:1:0:0"; };
      };
    };

    bluetooth = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Bluetooth support (Plasma shows the icon in the panel).";
    };

    printers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Common printer drivers (HP, Epson/Canon via Gutenprint, Brother laser) and network printer discovery.";
    };

    scanners = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Driverless network and USB scanners (eSCL/WSD, IPP-over-USB) and SANE backends.";
    };
  };

  config = lib.mkMerge [
    # the analysis command is always there, even with the module off
    { environment.systemPackages = [ driverCheck ]; }

    (lib.mkIf cfg.enable {
      assertions = [{
        assertion = !cfg.nvidia.prime.enable
          || (cfg.nvidia.prime.nvidiaBusId != ""
              && (cfg.nvidia.prime.intelBusId != "" || cfg.nvidia.prime.amdgpuBusId != ""));
        message = "my.hardware.drivers.nvidia.prime: nvidiaBusId and intelBusId (or amdgpuBusId) are required. Run driver-check for the values.";
      }];

      hardware.enableAllFirmware = cfg.allFirmware;
      hardware.enableRedistributableFirmware = true;
      hardware.cpu.intel.updateMicrocode = true;   # loaded only on the matching CPU
      hardware.cpu.amd.updateMicrocode = true;

      hardware.graphics.enable = true;
      hardware.graphics.extraPackages = lib.optionals cfg.intel.enable (with pkgs; [
        intel-media-driver    # Broadwell (2014) and later
        intel-vaapi-driver    # older generations
      ]);
      hardware.amdgpu.initrd.enable = cfg.amd.enable;

      services.xserver.videoDrivers = lib.mkIf cfg.nvidia.enable [ "nvidia" ];
      hardware.nvidia = lib.mkIf cfg.nvidia.enable {
        package = config.boot.kernelPackages.nvidiaPackages.${cfg.nvidia.driver};
        open = cfg.nvidia.open;
        modesetting.enable = true;          # required for Wayland
        nvidiaSettings = true;
        powerManagement.enable = true;      # proper suspend/resume
        powerManagement.finegrained = cfg.nvidia.prime.enable && cfg.nvidia.open;
        prime = lib.mkIf cfg.nvidia.prime.enable {
          offload.enable = true;
          offload.enableOffloadCmd = true;
          inherit (cfg.nvidia.prime) intelBusId amdgpuBusId nvidiaBusId;
        };
      };

      hardware.bluetooth = lib.mkIf cfg.bluetooth {
        enable = true;
        powerOnBoot = true;
      };

      services.printing = lib.mkIf cfg.printers {
        enable = true;
        drivers = with pkgs; [ gutenprint hplip brlaser ];
      };
      services.avahi = lib.mkIf (cfg.printers || cfg.scanners) {
        enable = true;          # finds printers and scanners on the network
        nssmdns4 = true;
        openFirewall = true;
      };

      hardware.sane = lib.mkIf cfg.scanners {
        enable = true;
        extraBackends = [ pkgs.sane-airscan ];
      };
      services.ipp-usb.enable = cfg.scanners || cfg.printers;
    })
  ];
}
