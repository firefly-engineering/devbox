# Auto-installer ISO for tart-backed devboxes.
#
# Reads two impure inputs from the environment so the ISO bake-in can pick up
# secrets without baking them into a flake input:
#   DEVBOX_SSH_KEY        path to the bootstrap user's SSH private key
#   DEVBOX_PARENT_PUBKEY  path to the calling host's SSH public key
# When set, the installer drops the private key at /home/<user>/.ssh/id_ed25519
# and authorizes the public key on both <user> and root so an outside SSH
# rebuild loop works on first boot.
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  inherit (config.devbox) user;
  nixCfg = config.devbox.nix;

  # Render a Nix list-of-strings as Nix source for embedding inside the
  # bootstrap configuration.nix heredoc. `[ "a" "b" ]` shape; `[ ]` for empty.
  renderNixList = items: "[ " + lib.concatMapStringsSep " " (s: ''"${s}"'') items + " ]";
  substList = renderNixList nixCfg.substituters;
  keysList = renderNixList nixCfg.trustedPublicKeys;

  sshKeyPath = builtins.getEnv "DEVBOX_SSH_KEY";
  hasSshKey = sshKeyPath != "";
  sshKeyFile =
    if hasSshKey then pkgs.writeText "devbox-id_ed25519" (builtins.readFile sshKeyPath) else null;

  parentPubKeyPath = builtins.getEnv "DEVBOX_PARENT_PUBKEY";
  hasParentPubKey = parentPubKeyPath != "";
  parentPubKey =
    if hasParentPubKey then lib.removeSuffix "\n" (builtins.readFile parentPubKeyPath) else "";

  authorizedKeysAttr = lib.optionalString hasParentPubKey ''
    users.users.${user.login}.openssh.authorizedKeys.keys = [ "${parentPubKey}" ];
    users.users.root.openssh.authorizedKeys.keys = [ "${parentPubKey}" ];
  '';

  autoInstallScript = pkgs.writeShellScript "devbox-auto-install" ''
    set -euo pipefail

    echo "=== Devbox auto-installer ==="

    while [ ! -b /dev/vda ]; do sleep 1; done

    echo "Partitioning /dev/vda..."
    ${pkgs.parted}/bin/parted -s /dev/vda -- \
      mklabel gpt \
      mkpart ESP fat32 1MiB 512MiB \
      set 1 esp on \
      mkpart nixos ext4 512MiB 100%

    echo "Formatting..."
    ${pkgs.dosfstools}/bin/mkfs.fat -F 32 -n boot /dev/vda1
    ${pkgs.e2fsprogs}/bin/mkfs.ext4 -L nixos /dev/vda2

    echo "Mounting..."
    mount /dev/vda2 /mnt
    mkdir -p /mnt/boot
    mount /dev/vda1 /mnt/boot

    echo "Generating hardware config..."
    nixos-generate-config --root /mnt

    echo "Writing bootstrap configuration..."
    cat > /mnt/etc/nixos/configuration.nix << 'NIXCFG'
    { config, pkgs, lib, ... }:
    {
      imports = [ ./hardware-configuration.nix ];

      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      networking.hostName = "${config.networking.hostName}";
      networking.networkmanager.enable = true;

      services.openssh = {
        enable = true;
        settings.PermitRootLogin = "yes";
      };

      users.users.${user.login} = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        initialPassword = "devbox";
      };

      users.users.root.initialPassword = "devbox";

      ${authorizedKeysAttr}

      security.sudo.wheelNeedsPassword = false;

      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      nix.settings.substituters = ${substList};
      nix.settings.trusted-public-keys = ${keysList};

      environment.systemPackages = with pkgs; [
        git
        vim
      ];

      system.stateVersion = "${config.system.stateVersion}";
    }
    NIXCFG

    echo "Running nixos-install..."
    nixos-install --no-root-passwd

    ${lib.optionalString hasSshKey ''
      echo "Installing devbox SSH user key..."
      USER_UID=$(${pkgs.gnugrep}/bin/grep "^${user.login}:" /mnt/etc/passwd | ${pkgs.coreutils}/bin/cut -d: -f3)
      USER_GID=$(${pkgs.gnugrep}/bin/grep "^${user.login}:" /mnt/etc/passwd | ${pkgs.coreutils}/bin/cut -d: -f4)
      ${pkgs.coreutils}/bin/install -m 0700 -o "$USER_UID" -g "$USER_GID" -d /mnt/home/${user.login}/.ssh
      KEY=/mnt/home/${user.login}/.ssh/id_ed25519
      ${pkgs.coreutils}/bin/install -m 0600 -o "$USER_UID" -g "$USER_GID" \
        ${sshKeyFile} "$KEY"
      # ssh-keygen refuses to read keys with permissive perms; derive the
      # public half from the post-install copy (mode 0600), not the store path.
      ${pkgs.openssh}/bin/ssh-keygen -y -f "$KEY" > "$KEY.pub"
      ${pkgs.coreutils}/bin/chown "$USER_UID:$USER_GID" "$KEY.pub"
      ${pkgs.coreutils}/bin/chmod 0644 "$KEY.pub"
    ''}

    echo "=== Installation complete, shutting down ==="
    poweroff
  '';
in
{
  config = lib.mkIf (config.devbox.hypervisor == "tart") {
    system.build.devboxInstaller =
      (import "${modulesPath}/../lib/eval-config.nix" {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
        {
          # Substituters for the ISO's own nix-daemon; nixos-install uses
          # these to copy the bootstrap closure into /mnt/nix/store.
          nix.settings.substituters = nixCfg.substituters;
          nix.settings.trusted-public-keys = nixCfg.trustedPublicKeys;

          # Apple Virtualization.framework uses virtio console (hvc0); enabling
          # serial-getty there lets `tart run --serial` show installer output.
          boot.kernelParams = [
            "console=hvc0"
            "console=tty0"
          ];
          systemd.services."serial-getty@hvc0".enable = true;

          systemd.services.devbox-auto-install = {
            description = "Devbox auto-installer";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            path = with pkgs; [
              util-linux
              coreutils
              nixos-install-tools
              nix
              systemd
            ];
            environment.NIX_PATH = "nixpkgs=${pkgs.path}";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = autoInstallScript;
              StandardOutput = "journal+console";
              StandardError = "journal+console";
            };
          };
        }
      ];
      }).config.system.build.isoImage;
  };
}
