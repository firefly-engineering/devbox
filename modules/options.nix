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

    nix = {
      substituters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "https://cache.nixos.org/"
          "https://nix-community.cachix.org"
        ];
        description = ''
          Substituter URLs that should be active during the bootstrap window:
          on the auto-install ISO's nix-daemon (so `nixos-install` is fast),
          baked into the bootstrap `/etc/nixos/configuration.nix` (so the
          first `nixos-rebuild` on the guest is fast), and passed to the
          host-side `nix build` of the installer ISO via
          `--option extra-substituters` (best-effort, honored only if the
          host already lists them in `trusted-substituters`).

          Once the workload's full config takes over after the first rebuild,
          the workload's own `nix.settings.substituters` governs.
        '';
      };

      trustedPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Public keys matching the substituters above. cache.nixos.org is
          trusted by default in NixOS; only third-party caches need entries.
        '';
      };
    };
  };
}
