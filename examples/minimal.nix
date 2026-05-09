# Smallest viable workload module — what you'd hand to `lib.mkDevbox`.
#
# Used by the in-tree `nixosConfigurations.example` smoke test:
#   nix eval .#nixosConfigurations.example.config.networking.hostName
{ ... }:
{
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
  };

  networking.hostName = "example";
  networking.networkmanager.enable = true;

  users.users.devbox = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "devbox";
  };

  system.stateVersion = "25.11";
}
