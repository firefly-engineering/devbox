{ lib, ... }:
{
  options.devbox = {
    hypervisor = lib.mkOption {
      type = lib.types.enum [ "tart" ];
      default = "tart";
      description = ''
        Hypervisor backing the devbox VM. Only "tart" is currently supported;
        the enum will grow as new backends land.
      '';
    };

    user.login = lib.mkOption {
      type = lib.types.str;
      default = "devbox";
      description = ''
        Login of the bootstrap user the auto-install ISO creates. The first
        rebuild over SSH replaces this minimal user with the one defined in
        your workload module — keep the names in sync so SSH key locations
        on disk stay stable across the bootstrap → rebuild handoff.
      '';
    };

    vm = {
      nested = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable nested virtualization (passes --nested to `tart run`).";
      };

      memoryMB = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "VM memory in MB. null leaves the hypervisor's default.";
      };

      diskGB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 50;
        description = "VM disk size in GB. Used by `devbox-cli init`.";
      };
    };
  };
}
