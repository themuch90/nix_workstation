{
  description = "NixOS workstation - AD, applications, Proxmox VE + VM Station";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Proxmox VE on NixOS. Do NOT add "follows" on nixpkgs-stable:
    # the project only supports its own pinned version.
    proxmox-nixos.url = "github:SaumonNet/proxmox-nixos";

    # SolidCraft (parametric CAD). No "follows": the flake requires a minimum
    # Rust version that stable nixpkgs may not have yet.
    # Pinned to a stable release tag: release candidates and nightly builds are
    # never installed. update-check reports a newer stable release and
    # system-update moves the PC repository to it (wiki: Aggiornamenti).
    solidcraft.url = "github:tangency-labs/solidcraft/v0.44.1";
  };

  outputs = { self, nixpkgs, proxmox-nixos, ... }@inputs:
    let
      system = "x86_64-linux";

      # Builds the system of a PC.
      #   name    flake profile (--flake .#<name>), passed to the modules as flakeHost;
      #           the machine name is set in my.core.hostName
      #   path    host folder (default: ./hosts/<name> in this repository)
      #   modules additional NixOS modules
      # Also used by the PC-specific repositories, which import this one
      # as the "base" input (wiki: Repository-del-PC):
      #   nixosConfigurations.pc01 = base.lib.mkHost { name = "pc01"; path = ./hosts/pc01; };
      mkHost = { name, path ? ./hosts/${name}, modules ? [ ] }: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs self; flakeHost = name; };
        modules = [ self.nixosModules.default path ] ++ modules;
      };
    in
    {
      lib = { inherit mkHost; };

      # all the my.* modules (each one switched on or off by its own options)
      nixosModules.default = {
        imports = [
          proxmox-nixos.nixosModules.proxmox-ve
          ./modules
        ];
      };

      packages.${system} = {
        vmstation = nixpkgs.legacyPackages.${system}.callPackage ./pkgs/vmstation { };
        # wizard for a new PC (wiki: Nuovo-PC):
        #   sudo nix-shell -p git --run "nix --extra-experimental-features 'nix-command flakes' run --no-write-lock-file git+https://…/nix_workstation.git#new-pc"
        new-pc = nixpkgs.legacyPackages.${system}.callPackage ./pkgs/new-pc { src = self; };
      };

      apps.${system}.new-pc = {
        type = "app";
        program = "${self.packages.${system}.new-pc}/bin/new-pc";
      };

      nixosConfigurations = {
        workstation = mkHost { name = "workstation"; };
        # other-pc = mkHost { name = "other-pc"; };   # copy hosts/workstation to hosts/other-pc
      };
    };
}
