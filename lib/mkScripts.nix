{
  pkgs,
  devbox-cli ? null,
  flakeRef ? ".",
  privateKeyHook ? "",
  parentPubKeyHook ? "",
  preRebuildHook ? "",
}:
let
  cli = if devbox-cli != null then devbox-cli else pkgs.callPackage ../pkgs/devbox-cli.nix { };
  cliBin = "${cli}/bin/devbox-cli";
  nixBin = "${pkgs.nix}/bin/nix";

  mk =
    name: body:
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      ${body}
    '';
in
{
  devbox-bootstrap = mk "devbox-bootstrap" ''
    if [[ $# -lt 1 ]]; then
      echo "usage: devbox-bootstrap <hostname>" >&2
      exit 2
    fi
    HOST="$1"
    ${privateKeyHook}
    ${parentPubKeyHook}
    exec ${cliBin} init "${flakeRef}#$HOST"
  '';

  devbox-rebuild = mk "devbox-rebuild" ''
    if [[ $# -lt 1 ]]; then
      echo "usage: devbox-rebuild <hostname>" >&2
      exit 2
    fi
    HOST="$1"
    ${preRebuildHook}
    exec ${cliBin} update "${flakeRef}#$HOST"
  '';

  devbox-start = mk "devbox-start" ''
    if [[ $# -lt 1 ]]; then
      echo "usage: devbox-start <hostname>" >&2
      exit 2
    fi
    HOST="$1"
    NESTED=$(${nixBin} eval --json "${flakeRef}#nixosConfigurations.$HOST.config.devbox.vm.nested" 2>/dev/null || echo "false")
    if [[ "$NESTED" == "true" ]]; then
      exec ${cliBin} vm start "$HOST" --nested
    else
      exec ${cliBin} vm start "$HOST"
    fi
  '';

  devbox-stop = mk "devbox-stop" ''
    if [[ $# -lt 1 ]]; then
      echo "usage: devbox-stop <hostname>" >&2
      exit 2
    fi
    exec ${cliBin} vm stop "$1"
  '';

  devbox-remove = mk "devbox-remove" ''
    if [[ $# -lt 1 ]]; then
      echo "usage: devbox-remove <hostname>" >&2
      exit 2
    fi
    exec ${cliBin} vm remove "$1"
  '';
}
