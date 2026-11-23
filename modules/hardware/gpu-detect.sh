# Graphics card detection, shared by driver-check and the new-pc wizard.
# Needs lspci (pciutils). gpu_detect sets:
#   want_intel want_amd want_nvidia want_prime  true|false
#   want_drv (NVIDIA branch) want_open (NVIDIA open modules)
#   intel_bus amd_bus nvidia_bus  (PCI:b:d:f, NixOS format)
# and calls gpu_found SLOT NAME VENDOR for every card, if that function exists.
# drivers_block prints the my.hardware.drivers block for the detected cards.

# 0000:01:00.0 -> PCI:1:0:0 (NixOS format, decimal)
busid() {
  local a=$1 bus dev fn
  bus=${a#*:}; bus=${bus%%:*}
  dev=${a##*:}; fn=${dev#*.}; dev=${dev%.*}
  printf 'PCI:%d:%d:%d' "$((16#$bus))" "$((16#$dev))" "$((16#$fn))"
}

gpu_detect() {
  local slot rest ids vendor device name
  want_intel=false; want_amd=false; want_nvidia=false; want_open=true; want_drv=stable
  intel_bus=""; amd_bus=""; nvidia_bus=""
  while read -r slot rest; do
    ids=$(grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' <<<"$rest" | tail -1 | tr -d '[]')
    vendor=${ids%:*}; device=${ids#*:}
    name=$(sed -E 's/^[^:]*: //; s/ \[[0-9a-f]{4}:[0-9a-f]{4}\].*//' <<<"$rest")
    case "$vendor" in
      8086) want_intel=true; intel_bus=$(busid "$slot") ;;
      1002) want_amd=true; amd_bus=$(busid "$slot") ;;
      10de)
        want_nvidia=true; nvidia_bus=$(busid "$slot")
        # driver branch by generation (device ID):
        #   Turing (GTX 16xx / RTX 20xx) and later -> stable, open modules
        #   Maxwell / Pascal / Volta               -> legacy_580 (595+ does not support them)
        #   Kepler -> legacy_470, Fermi -> legacy_390 (may not build with recent kernels)
        if (( 16#$device >= 16#1e00 )); then want_drv=stable
        else
          want_open=false
          if (( 16#$device >= 16#1340 )); then want_drv=legacy_580
          elif (( 16#$device >= 16#0fc0 )); then want_drv=legacy_470
          else want_drv=legacy_390
          fi
        fi
        ;;
    esac
    if declare -F gpu_found >/dev/null; then gpu_found "$slot" "$name" "$vendor"; fi
  done < <(lspci -Dnn | grep -E '\[(0300|0302|0380)\]')
  want_prime=false
  if $want_nvidia && { $want_intel || $want_amd; }; then want_prime=true; fi
}

drivers_block() {
  echo "  my.hardware.drivers = {"
  echo "    enable = true;"
  if $want_intel; then echo "    intel.enable = true;"; fi
  if $want_amd; then echo "    amd.enable = true;"; fi
  if $want_nvidia; then
    echo "    nvidia = {"
    echo "      enable = true;"
    echo "      driver = \"$want_drv\";"
    echo "      open = $want_open;"
    if $want_prime; then
      echo "      prime = {"
      echo "        enable = true;"
      if [ -n "$intel_bus" ]; then echo "        intelBusId = \"$intel_bus\";"; fi
      if [ -n "$amd_bus" ]; then echo "        amdgpuBusId = \"$amd_bus\";"; fi
      echo "        nvidiaBusId = \"$nvidia_bus\";"
      echo "      };"
    fi
    echo "    };"
  fi
  echo "  };"
}
