# Architecture

`firefly-engineering/devbox` builds NixOS VMs intended as remote development
environments. Today only the `tart` hypervisor (Apple Silicon) is supported;
the schema reserves room for `kvm` and others without an API break.

The split:

| Directory | Role |
|---|---|
| `modules/` | One NixOS module (`nixosModules.default`) — base settings + the selected hypervisor stack. |
| `lib/` | `mkDevbox` (a thin `nixosSystem` wrapper) and `mkScripts` (a factory for parametrized lifecycle scripts). |
| `pkgs/` | `devbox-cli`, a single-binary CLI with both raw VM ops (`vm create`/`start`/...) and high-level lifecycle (`init`/`update`/`up`/...). |
| `examples/` | A smoke-test workload validating the API end-to-end. |

## Lifecycle

A devbox traverses four phases, each running in a different evaluation
context.

```
host                     VM (booted from ISO)         VM (booted from disk)
─────────────────────    ─────────────────────────    ─────────────────────────
1. nix build             2. devbox-auto-install
   installer ISO            systemd unit:
                            - partition /dev/vda
                            - mkfs ESP + nixos
                            - nixos-generate-config
                            - write minimal
                              /etc/nixos/
                              configuration.nix
                            - nixos-install           3. running NixOS:
                            - poweroff                   - first nixos-rebuild
                                                         - workload modules apply

                                                      4. ongoing rebuilds
                                                         (consumer-driven)
```

**Phase 1 — host build.** The CLI's `init` subcommand evaluates
`<flake>#nixosConfigurations.<host>.config.system.build.devboxInstaller`
against the host's nixpkgs. Two impure inputs are read from the
environment: `DEVBOX_SSH_KEY` (path to the bootstrap user's private SSH
key) and `DEVBOX_PARENT_PUBKEY` (path to the calling host's public key).
Either may be unset; `init` accepts `--ssh-key=PATH` / `--parent-pubkey=PATH`
flags that set them. `--impure` is required so `builtins.getEnv` can read
them at eval time. `devbox.nix.substituters` and `devbox.nix.trustedPublicKeys`
are passed as `--option extra-substituters` / `--option extra-trusted-public-keys`
to speed up substitution if the host pre-trusts those caches.

**Phase 2 — VM, booted from ISO.** The auto-install unit partitions
`/dev/vda` (GPT: 512MiB ESP + remainder ext4), mounts /mnt, runs
`nixos-generate-config --root /mnt`, writes a minimal bootstrap
`configuration.nix`, runs `nixos-install --no-root-passwd`, and powers
off. The bootstrap `configuration.nix` carries: SSH enabled,
the bootstrap user from `config.devbox.user.login` with `initialPassword =
"devbox"`, the parent host's authorized SSH key (if `DEVBOX_PARENT_PUBKEY`
was set during phase 1), passwordless sudo for wheel, flakes enabled, and
the substituters declared in `config.devbox.nix.*`. That last bit is what
makes phase 3's first rebuild fast.

**Phase 3 — VM, booted from disk, first rebuild.** The CLI's `update`
subcommand resolves the VM's IP via `tart ip`, rsyncs the consumer's flake
source to `/tmp/nix-config` on the guest (excluding `.git` and `result`),
and runs `nixos-rebuild switch --flake /tmp/nix-config#<host>` over SSH.
Connection bypasses `~/.ssh/config` aliases (uses the raw IP) so that
tailscale hostnames and stale `known_hosts` entries don't interfere with
first-time auth. The full workload module set takes over here — the
bootstrap user defined by phase 2 is replaced by whatever `users.users.*`
the workload defines, and the workload's own `nix.settings.substituters`
governs subsequent substitution.

**Phase 4 — steady state.** `devbox-cli update <ref>#<host>` re-runs phase
3 on demand. The bootstrap configuration.nix from phase 2 is no longer in
play — only the workload modules.

## Module hierarchy

`nixosModules.default` is `./modules`. Inside:

- `default.nix` — imports the rest. No logic.
- `options.nix` — declares the `config.devbox.*` option surface.
- `base.nix` — hypervisor-agnostic VM defaults (boot loader, growPartition,
  zram, fd limits, doc disable). Every option uses `lib.mkDefault`, so
  consumers override at normal priority without `lib.mkForce`.
- `tart/guest.nix` — virtio kernel modules + qemu-guest-agent. Wrapped in
  `lib.mkIf (config.devbox.hypervisor == "tart")`.
- `tart/installer.nix` — produces `system.build.devboxInstaller` (the
  bootable ISO). Same `mkIf` gate.

Module imports are static; gating happens inside each leaf's `config = lib.mkIf
... { ... }`. Putting `config` references into `imports = lib.optionals (...)`
triggers infinite recursion, since the option declarations themselves are
part of the eval graph that produces `config`.

Adding a `kvm` backend means adding `modules/kvm/{guest,installer}.nix`
with the same gating pattern, extending the `hypervisor` enum in
`options.nix`, and importing the new files unconditionally from
`modules/default.nix`.

## Option surface

| Option | Type | Default | Description |
|---|---|---|---|
| `devbox.hypervisor` | enum | `"tart"` | Hypervisor backing the VM. Only `"tart"` is currently supported. |
| `devbox.user.login` | str | `"devbox"` | Login of the bootstrap user the auto-install ISO creates. Should match the workload's eventual user so SSH key paths stay stable across the bootstrap → rebuild handoff. |
| `devbox.vm.nested` | bool | `false` | Enables `tart run --nested`. |
| `devbox.vm.memoryMB` | int? | `null` | VM memory in MB; `null` leaves the hypervisor default. |
| `devbox.vm.diskGB` | int | `50` | VM disk size in GB. |
| `devbox.nix.substituters` | [str] | `[ ]` | Caches active during the bootstrap window — the ISO's nix-daemon, the bootstrap configuration.nix, and the host-side `nix build` of the installer. |
| `devbox.nix.trustedPublicKeys` | [str] | `[ ]` | Public keys for the substituters above. cache.nixos.org is trusted by default in NixOS. |

## CLI surface

Two layers in one binary.

**Raw `vm` ops** — no flake awareness, single-VM scope. Useful when you
already know what you want and don't need configuration lookup.

```
devbox-cli vm create <name> [--hypervisor=tart] [--disk=GB] [--memory=MB]
devbox-cli vm start <name> [--nested]
devbox-cli vm stop <name>
devbox-cli vm remove <name>
devbox-cli vm ip <name>
devbox-cli vm wait-ssh <name> --user=USER [--timeout=SECS]
devbox-cli vm boot-iso <name> <iso-path> [--nested]
```

**High-level lifecycle** — flake-aware. `init` and `update` take a
`<flake>#<host>` reference; `up`/`down`/`rm` operate on bare VM names.

```
devbox-cli init <flake>#<host> [--ssh-key=PATH] [--parent-pubkey=PATH]
devbox-cli update <flake>#<host>
devbox-cli up <name> [--nested]
devbox-cli down <name>
devbox-cli rm <name>
```

Each high-level subcommand is also exposed as a flake app, so a downstream
consumer with no Nix infrastructure can still drive the CLI:

```bash
nix run github:firefly-engineering/devbox#init -- ./my-flake#my-devbox
```

## lib.mkDevbox

A thin wrapper around `nixpkgs.lib.nixosSystem`. Prepends
`nixosModules.default` and translates the `hypervisor` and `vm` args into
`config.devbox.*` settings.

```nix
inputs.devbox.lib.mkDevbox {
  nixpkgs       = inputs.nixpkgs;
  system        = "aarch64-linux";
  hypervisor    = "tart";          # default
  vm            = { nested = true; memoryMB = 32768; diskGB = 150; };
  modules       = [ ./my-workload.nix ];
  specialArgs   = { inherit machine user; };  # forwarded verbatim
}
```

The flake makes no assumptions about home-manager, sops, or any
particular user model. Whatever the workload module defines is what the
guest gets, save the bootstrap-window minimal user from phase 2.

## lib.mkScripts

`mkScripts` produces parametrized lifecycle wrappers — useful when a
consumer needs custom hooks (e.g., sops decryption, parent-key extraction,
sops re-keying) woven into the bootstrap and rebuild flows. Each output
is a `pkgs.writeShellScriptBin` derivation.

```nix
inputs.devbox.lib.mkScripts {
  pkgs              = pkgs;
  flakeRef          = ".";              # default
  privateKeyHook    = ''...shell snippet that exports DEVBOX_SSH_KEY...'';
  parentPubKeyHook  = ''...shell snippet that exports DEVBOX_PARENT_PUBKEY...'';
  preRebuildHook    = ''...shell snippet run before rebuild...'';
}
# → { devbox-bootstrap, devbox-rebuild, devbox-start, devbox-stop, devbox-remove }
```

Each wrapper `cd`s to the git repo root before doing anything else, so
`flakeRef = "."` works from any subdirectory of the consumer's checkout.
Hooks run in the wrapper's process; `$HOST` is set to the first positional
argument before they execute, so hooks can reference it.

Hooks are arbitrary shell — `writeShellScriptBin` rather than
`writeShellApplication`, intentionally — because consumer-supplied snippets
won't reliably pass shellcheck.

## Inputs

The flake's only input is `firefly-engineering/nix-pins`, which re-exports
a curated set of nixpkgs versions. Consumers should set
`devbox.inputs.nix-pins.follows = "nix-pins"` so their nix-pins is shared
across the input graph.
