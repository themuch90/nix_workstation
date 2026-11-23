{ lib
, stdenv
, python3
, qt6
, makeWrapper
, makeDesktopItem
, copyDesktopItems
, freerdp
, xdotool
, xdg-utils
, xterm
, openssh
, sshpass
, xwininfo
}:
let
  # keyring/secretstorage/dbus: passwords in the KDE Wallet
  python = python3.withPackages (ps: [ ps.pyside6 ps.requests ps.keyring ps.secretstorage ps.dbus-python ]);
in
stdenv.mkDerivation {
  pname = "vmstation";
  version = "1.3.0";
  src = ./.;

  nativeBuildInputs = [ makeWrapper qt6.wrapQtAppsHook copyDesktopItems ];
  buildInputs = [ qt6.qtbase qt6.qtwayland ];
  dontWrapQtApps = true;
  dontBuild = true;

  desktopItems = [
    (makeDesktopItem {
      name = "vmstation";
      desktopName = "VM Station";
      genericName = "Virtual machine console";
      comment = "Management and RDP/SSH consoles for Proxmox VMs";
      exec = "vmstation";
      icon = "computer";
      categories = [ "System" "Emulator" "Network" ];
      startupWMClass = "vmstation";
    })
  ];

  installPhase = ''
    runHook preInstall
    install -Dm644 vmstation.py $out/share/vmstation/vmstation.py
    install -Dm644 vmstation_i18n.py $out/share/vmstation/vmstation_i18n.py
    makeWrapper ${python}/bin/python3 $out/bin/vmstation \
      "''${qtWrapperArgs[@]}" \
      --add-flags $out/share/vmstation/vmstation.py \
      --prefix PATH : ${lib.makeBinPath [ freerdp xdotool xdg-utils xterm openssh sshpass xwininfo ]} \
      --set-default QT_QPA_PLATFORM xcb
    runHook postInstall
  '';

  meta = {
    description = "VMware Workstation-style interface for Proxmox VMs (RDP with xfreerdp, SSH with xterm)";
    mainProgram = "vmstation";
    platforms = lib.platforms.linux;
  };
}
