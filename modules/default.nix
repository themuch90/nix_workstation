{
  imports = [
    ./core
    ./users/local-admin.nix
    ./identity/active-directory.nix
    ./desktop/plasma.nix
    ./apps
    ./virtualization
    ./vmstation
    ./hardware/drivers.nix
    ./maintenance/update-check.nix
    ./maintenance/nix-tools.nix
    ./maintenance/app-manager.nix
    ./maintenance/repo-urls.nix
    ./maintenance/config-sync.nix
  ];
}
