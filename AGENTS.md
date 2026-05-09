# Contributor Guide

Notes for anyone — human or agent — extending this repo.

## What this is

A flake that builds NixOS VMs ("devboxes") on Apple Silicon via Tart.
Consumers hand it a workload NixOS module and get back a bootable
`nixosConfiguration` plus lifecycle tooling.

## What this is not

- A general-purpose NixOS deployment framework — use deploy-rs, colmena,
  or nixos-anywhere.
- A workload provisioner — consumers supply modules; this flake supplies
  infrastructure (boot loader, virtio drivers, installer ISO, lifecycle CLI).
- An opinionated dev environment — no sops, no home-manager, no specific
  user model. Consumers layer those on themselves.

Read [`ARCHITECTURE.md`](./ARCHITECTURE.md) before making non-trivial
changes; the four-phase lifecycle is what most decisions turn on.

## Layout

```
modules/      one nixosModules.default — base + selected hypervisor stack
lib/          mkDevbox (nixosSystem wrapper), mkScripts (lifecycle wrappers)
pkgs/         devbox-cli (single-binary CLI)
examples/     in-tree smoke-test workload
```

## Where things go

| Change | Files |
|---|---|
| New hypervisor (e.g., kvm) | `modules/kvm/{guest,installer}.nix`; extend the `hypervisor` enum in `modules/options.nix`; import unconditionally from `modules/default.nix` and gate each leaf with `lib.mkIf (config.devbox.hypervisor == "kvm")`. |
| New module option | `modules/options.nix`. Keep options hypervisor-agnostic where possible. |
| New CLI subcommand | `pkgs/devbox-cli.nix`: add a `cmd_<name>` function and a dispatch case. If it's a high-level lifecycle op, also add `apps.<system>.<name>` in `flake.nix`. |
| New `mkScripts` hook | `lib/mkScripts.nix`: add an arg to the function signature (default `""`), splice into the relevant wrapper(s). |

## Conventions

**Modules.**

- Use `lib.mkIf` for hypervisor gating, never `imports = lib.optionals (...)`. The latter creates infinite recursion when the gate references `config`. See `modules/default.nix` for the static-imports + leaf-mkIf pattern.
- Defaults use `lib.mkDefault` so consumers override at normal priority without `lib.mkForce`.
- Don't assume `specialArgs` (no `machine`, no `user`). Read everything from `config.devbox.*` instead. The flake doesn't know about consumer-side concepts.

**CLI (`pkgs/devbox-cli.nix`).**

- `pkgs.writeShellApplication` runs shellcheck strictly. Common fixes: prefix unused vars with `_`, replace `for i in ...` with `for _ in ...`. Use `# shellcheck disable=SCxxxx` only as a last resort.
- The CLI's runtime tools must be in `runtimeInputs`. `tart` is checked at runtime via `require_tart` (it's not in nixpkgs).
- Argument parsing is bash-flavoured: `case` on `$1` for subcommand, then a `while [[ $# -gt 0 ]]` loop with positional + `--flag=value` patterns inside each `cmd_*`.

**`mkScripts` wrappers.**

- `pkgs.writeShellScriptBin`, not `writeShellApplication`. Hooks are consumer-supplied shell snippets and won't reliably pass shellcheck.
- Each wrapper `cd`s to `$(git rev-parse --show-toplevel)` before running, so `flakeRef = "."` resolves correctly from any subdirectory.

**Bash inside Nix `''...''` strings.**

- `${VAR}` is Nix interpolation. To emit a literal `${VAR}` (bash variable
  with braces), write `''${VAR}`.
- `$VAR` (no braces) needs no escaping — Nix doesn't interpret it.
- Heredocs with quoted delimiters (`<<'EOF'`) skip bash interpolation;
  Nix interpolation still happens at script-build time.

**VCS.**

- Repo is jj-tracked with a colocated git backend. Push with `jj git push`; if no bookmark moves, `jj bookmark move main --to @` first.
- Granular commits — one logical change per commit.
- Conventional Commits: `feat(scope): ...`, `fix(scope): ...`, `refactor(scope): ...`, `docs: ...`, `chore: ...`. See `git log` for examples.
- No emojis in code, commits, or docs.

## Testing

```bash
nix flake check --no-build           # typecheck all per-system outputs
nix eval .#nixosConfigurations.example.config.networking.hostName
                                     # smoke-test the API end-to-end
nix eval --json .#nixosConfigurations.example.config.devbox.vm
                                     # sanity-check option flow
nix build .#devbox-cli --no-link     # build the CLI (runs shellcheck)
nix run .#devbox-cli -- help         # exercise dispatch
```

There is no Tart in CI. `init`/`update`/`up`/`down`/`rm` call `tart` at
runtime and exit with a clear error if it isn't on PATH.

When a consumer is iterating against an unpushed change, they can use
`nix --override-input devbox path:/path/to/devbox <cmd>` to bypass the
locked input without touching `flake.lock`.

## Pitfalls

- **`builtins.getEnv` in `installer.nix`.** Required for the impure bootstrap (DEVBOX_SSH_KEY, DEVBOX_PARENT_PUBKEY). The `init` subcommand passes `--impure` to `nix build`. Don't try to make this pure — the design accepts impurity at the bootstrap boundary.
- **`config.<...>` in `imports = ...`.** Infinite recursion. Always use static imports and gate inside the leaf module's `config = lib.mkIf ... { ... }` block.
- **`devbox-cli` name.** The binary is `devbox-cli` to avoid colliding with [jetpack-io/devbox](https://www.jetpack.io/devbox/). Don't rename it.
- **Substituters need host trust.** `--option extra-substituters` is honored only if the host's `/etc/nix/nix.conf` already lists the cache in `trusted-substituters`. The CLI passes the option unconditionally; if it's not pre-trusted, you get a warning and the build proceeds with defaults.
- **The bootstrap user is throwaway.** Phase 2 creates a minimal user with `initialPassword = "devbox"`. The first `nixos-rebuild` (phase 3) replaces it with whatever `users.users.*` the workload defines. Keep `config.devbox.user.login` matching the workload's eventual login so SSH key paths in `/home/<user>/.ssh/` stay valid across the handoff.

## Related

- `firefly-engineering/nix-pins` — the canonical pin source. The flake's only input. Consumers should set `devbox.inputs.nix-pins.follows = "nix-pins"`.
- Any consumer flake — passes a workload module to `lib.mkDevbox`. The consumer owns home-manager, sops, the user catalog, and any organization-specific policy; the flake stays generic.
