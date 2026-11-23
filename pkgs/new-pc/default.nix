# Wizard for a new PC: nix run <generic repository>#new-pc (wiki: Nuovo-PC).
# src = source of this repository (hosts/workstation template).
{ writeShellApplication, git, coreutils, gnused, gnugrep, jq, mkpasswd, newt, nix, pciutils, python3, src }:
writeShellApplication {
  name = "new-pc";
  runtimeInputs = [ git coreutils gnused gnugrep jq mkpasswd newt nix pciutils python3 ];
  text = ''
    NEW_PC_SRC="${src}"
  ''
  # graphics card detection (gpu_detect, drivers_block), same as driver-check
  + builtins.readFile ../../modules/hardware/gpu-detect.sh
  + builtins.readFile ./new-pc.sh;
}
