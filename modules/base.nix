{ lib, ... }:
{
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Resizing the VM disk later only grows /dev/vda; growPartition extends the
  # root partition + filesystem to match on boot.
  boot.growPartition = lib.mkDefault true;

  # zram-backed swap covers RAM bursts (cargo, heavy nix substitutions)
  # without touching disk.
  zramSwap.enable = lib.mkDefault true;

  # Rebuild flows run unattended over SSH; password prompts would deadlock.
  security.sudo.wheelNeedsPassword = lib.mkDefault false;

  # Default 1024 fds isn't enough for cache.nixos.org substitution during
  # a full rebuild.
  systemd.services.nix-daemon.serviceConfig.LimitNOFILE = lib.mkDefault 65536;
  security.pam.loginLimits = [
    {
      domain = "*";
      type = "soft";
      item = "nofile";
      value = "65536";
    }
  ];

  documentation.enable = lib.mkDefault false;
  documentation.man.enable = lib.mkDefault false;
  documentation.doc.enable = lib.mkDefault false;
  documentation.info.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;

  services.openssh.enable = lib.mkDefault true;
}
