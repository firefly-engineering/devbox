{ config, lib, ... }:
{
  config = lib.mkIf (config.devbox.hypervisor == "tart") {
    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_net"
      "virtio_scsi"
    ];

    services.qemuGuest.enable = true;
  };
}
