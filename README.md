# devbox

Build NixOS development VMs ("devboxes") from a single workload module.

The flake exposes one NixOS module (`nixosModules.default`) that contains
hypervisor-aware base settings (boot loader, virtio drivers, auto-install ISO),
a `lib.mkDevbox` builder that wraps `nixpkgs.lib.nixosSystem` with that module
pre-imported, and a `devbox-cli` package for managing VM lifecycle (create,
start, stop, remove, bootstrap, rebuild).

Only the `tart` hypervisor is supported today. The schema reserves room for
others (`kvm`, etc.) without an API break.

## Quick start

```nix
# flake.nix
{
  inputs = {
    nix-pins.url = "github:firefly-engineering/nix-pins";
    nixpkgs.follows = "nix-pins/nixpkgs-stable";
    devbox.url = "github:firefly-engineering/devbox";
    devbox.inputs.nix-pins.follows = "nix-pins";
  };

  outputs = { self, nixpkgs, devbox, ... }: {
    nixosConfigurations.my-devbox = devbox.lib.mkDevbox {
      inherit nixpkgs;
      system = "aarch64-linux";
      hypervisor = "tart";
      vm = { nested = false; memoryMB = 8192; diskGB = 60; };
      modules = [
        ./my-workload.nix
        # Optional: caches active during bootstrap so the auto-installer
        # and the first rebuild on the guest don't crawl cache.nixos.org alone.
        {
          devbox.nix.substituters = [
            "https://cache.nixos.org/"
            "https://nix-community.cachix.org"
          ];
          devbox.nix.trustedPublicKeys = [
            "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
            "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          ];
        }
      ];
    };
  };
}
```

```bash
# Bootstrap the VM (build installer ISO, create Tart VM, auto-install)
nix run github:firefly-engineering/devbox#init -- .#my-devbox

# Push a config update over SSH
nix run github:firefly-engineering/devbox#update -- .#my-devbox

# Lifecycle
nix run github:firefly-engineering/devbox#up   -- my-devbox
nix run github:firefly-engineering/devbox#down -- my-devbox
nix run github:firefly-engineering/devbox#rm   -- my-devbox
```

## What's exposed

| Output | Description |
|---|---|
| `nixosModules.default` | Devbox base + selected hypervisor stack. Reads `config.devbox.{hypervisor,vm.*}`. |
| `lib.mkDevbox` | `{ nixpkgs, system, hypervisor, vm, modules, specialArgs }` → nixosConfiguration. |
| `lib.mkScripts` | Generates parametrized `devbox-bootstrap`/`devbox-rebuild`/... derivations for consumers that need to weave in custom hooks (sops, parent-key extraction, pre-rebuild steps). |
| `packages.<system>.devbox-cli` | The CLI binary. |
| `apps.<system>.{default,init,update,up,down,rm}` | `nix run` entrypoints. |

## Requirements

- macOS Apple Silicon for the `tart` hypervisor (Tart is macOS-only).
- [Tart](https://tart.run/) installed (`brew install cirruslabs/cli/tart`).

## Further reading

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — the four-phase bootstrap
  lifecycle, full option surface, and how to extend with a new hypervisor.
- [`AGENTS.md`](./AGENTS.md) — conventions and pitfalls when contributing.
