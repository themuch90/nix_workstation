{ config, lib, pkgs, ... }:
let
  cfg = config.my.apps.vscode;

  # nixpkgs bug (VS Code >= 1.144): the recipe runs "rm .../@vscode/ripgrep/bin/rg"
  # but the file no longer exists; the command is made tolerant (harmless once fixed).
  rgPath = "resources/app/node_modules/@vscode/ripgrep/bin";
  fixRg = s: builtins.replaceStrings
    [ "rm ${rgPath}/rg" ]
    [ "mkdir -p ${rgPath}; rm -f ${rgPath}/rg" ]
    s;

  vscodeFixed = pkgs.vscode.overrideAttrs (old:
    lib.optionalAttrs (old ? patchPhase && old.patchPhase != null) { patchPhase = fixRg old.patchPhase; }
    // lib.optionalAttrs (old ? postPatch && old.postPatch != null) { postPatch = fixRg old.postPatch; }
  );
in
{
  options.my.apps.vscode = {
    enable = lib.mkEnableOption "Visual Studio Code";

    nixLd = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enables nix-ld: allows running the "generic" Linux binaries
        downloaded by extensions (Claude Code, C/C++, Python, Copilot...),
        which on NixOS otherwise fail with "Could not start dynamically linked executable".
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # not vscode-fhs: the FHS variant would ignore the fix above
    environment.systemPackages = [ vscodeFixed ];

    programs.nix-ld = lib.mkIf cfg.nixLd {
      enable = true;
      libraries = with pkgs; [
        stdenv.cc.cc.lib
        zlib
        openssl
        curl
        icu
        libsecret
        krb5
        glib
        nss
        nspr
        libxkbfile
        util-linux
        libx11
        libxcb
      ];
    };
  };
}
