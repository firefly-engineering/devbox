{
  writeShellApplication,
  jq,
  openssh,
  coreutils,
  findutils,
  git,
  rsync,
  nix,
}:
writeShellApplication {
  name = "devbox-cli";
  runtimeInputs = [
    jq
    openssh
    coreutils
    findutils
    git
    rsync
    nix
  ];
  text = ''
    usage() {
      cat <<'EOF'
    Usage: devbox-cli <subcommand> [args...]

    Lifecycle:
      init <flake>#<host> [--ssh-key=PATH] [--parent-pubkey=PATH]
                                  build installer ISO, create VM, auto-install NixOS
      update <flake>#<host>       rsync flake source and run nixos-rebuild over SSH
      up <name> [--nested]        start a VM headless
      down <name>                 stop a running VM
      rm <name>                   stop and delete a VM, plus its log

    Raw hypervisor operations:
      vm create <name> [--hypervisor=tart] [--disk=GB] [--memory=MB]
      vm start <name> [--nested]
      vm stop <name>
      vm remove <name>
      vm ip <name>
      vm wait-ssh <name> --user=USER [--timeout=SECS]
      vm boot-iso <name> <iso-path> [--nested]

    Set XDG_STATE_HOME to redirect VM logs (default: ~/.local/state/devbox/).
    EOF
    }

    require_tart() {
      if ! command -v tart >/dev/null 2>&1; then
        echo "error: tart not found on PATH. Install: brew install cirruslabs/cli/tart" >&2
        exit 127
      fi
    }

    vm_state() {
      tart list --format json 2>/dev/null \
        | jq -r ".[] | select(.Name == \"$1\") | .State"
    }

    cmd_vm_create() {
      local name="" hypervisor="tart" disk="" memory=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --hypervisor=*) hypervisor="''${1#*=}" ;;
          --disk=*)       disk="''${1#*=}" ;;
          --memory=*)     memory="''${1#*=}" ;;
          --)             shift; break ;;
          -*)             echo "unknown flag: $1" >&2; return 2 ;;
          *)              if [[ -z "$name" ]]; then name="$1"; else echo "unexpected: $1" >&2; return 2; fi ;;
        esac
        shift
      done
      if [[ -z "$name" ]]; then
        echo "usage: devbox-cli vm create <name> [--hypervisor=tart] [--disk=GB] [--memory=MB]" >&2
        return 2
      fi
      if [[ "$hypervisor" != "tart" ]]; then
        echo "error: only tart hypervisor is supported (got: $hypervisor)" >&2
        return 2
      fi

      require_tart
      tart delete "$name" 2>/dev/null || true
      if [[ -n "$disk" ]]; then
        tart create --linux "$name" --disk-size "$disk"
      else
        tart create --linux "$name"
      fi
      if [[ -n "$memory" ]]; then
        tart set "$name" --memory "$memory"
      fi
    }

    cmd_vm_start() {
      local name="" nested=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --nested) nested=1 ;;
          -*)       echo "unknown flag: $1" >&2; return 2 ;;
          *)        if [[ -z "$name" ]]; then name="$1"; else echo "unexpected: $1" >&2; return 2; fi ;;
        esac
        shift
      done
      if [[ -z "$name" ]]; then
        echo "usage: devbox-cli vm start <name> [--nested]" >&2
        return 2
      fi
      require_tart

      local state
      state=$(vm_state "$name")
      if [[ -z "$state" ]]; then
        echo "error: tart VM '$name' not found" >&2
        return 1
      fi
      if [[ "$state" == "running" ]]; then
        echo "$name is already running"
        return 0
      fi

      local nested_flag=""
      if [[ $nested -eq 1 ]]; then nested_flag="--nested"; fi

      local log_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/devbox"
      mkdir -p "$log_dir"
      local log="$log_dir/$name.log"

      echo "starting $name (log: $log)..."
      # shellcheck disable=SC2086
      nohup tart run $nested_flag --no-graphics "$name" >> "$log" 2>&1 < /dev/null &
      disown

      for _ in 1 2 3 4 5; do
        sleep 1
        state=$(vm_state "$name")
        if [[ "$state" == "running" ]]; then
          local ip
          ip=$(tart ip "$name" 2>/dev/null || true)
          echo "$name is running (ip: ''${ip:-pending})"
          return 0
        fi
      done
      echo "$name start initiated; check $log if it doesn't come up"
    }

    cmd_vm_stop() {
      local name="''${1:-}"
      if [[ -z "$name" ]]; then
        echo "usage: devbox-cli vm stop <name>" >&2
        return 2
      fi
      require_tart

      local state
      state=$(vm_state "$name")
      if [[ -z "$state" ]]; then
        echo "error: tart VM '$name' not found" >&2
        return 1
      fi
      if [[ "$state" != "running" ]]; then
        echo "$name is not running (state: $state)"
        return 0
      fi

      echo "stopping $name..."
      tart stop "$name"
      echo "$name stopped"
    }

    cmd_vm_remove() {
      local name="''${1:-}"
      if [[ -z "$name" ]]; then
        echo "usage: devbox-cli vm remove <name>" >&2
        return 2
      fi
      require_tart

      local state
      state=$(vm_state "$name")
      if [[ -z "$state" ]]; then
        echo "tart VM '$name' not found; nothing to do"
        return 0
      fi

      if [[ "$state" == "running" ]]; then
        echo "stopping $name..."
        tart stop "$name"
      fi

      echo "deleting tart VM '$name'..."
      tart delete "$name"

      local log="''${XDG_STATE_HOME:-$HOME/.local/state}/devbox/$name.log"
      if [[ -f "$log" ]]; then
        rm -f "$log"
        echo "removed $log"
      fi
    }

    cmd_vm_ip() {
      local name="''${1:-}"
      if [[ -z "$name" ]]; then
        echo "usage: devbox-cli vm ip <name>" >&2
        return 2
      fi
      require_tart
      tart ip "$name"
    }

    cmd_vm_wait_ssh() {
      local name="" user="" timeout=120
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --user=*)    user="''${1#*=}" ;;
          --timeout=*) timeout="''${1#*=}" ;;
          -*)          echo "unknown flag: $1" >&2; return 2 ;;
          *)           if [[ -z "$name" ]]; then name="$1"; else echo "unexpected: $1" >&2; return 2; fi ;;
        esac
        shift
      done
      if [[ -z "$name" ]]; then
        echo "usage: devbox-cli vm wait-ssh <name> --user=USER [--timeout=SECS]" >&2
        return 2
      fi
      if [[ -z "$user" ]]; then
        echo "error: --user=USER is required" >&2
        return 2
      fi
      require_tart

      local deadline
      deadline=$(( $(date +%s) + timeout ))
      while [[ $(date +%s) -lt $deadline ]]; do
        local ip
        ip=$(tart ip "$name" 2>/dev/null || true)
        if [[ -n "$ip" ]]; then
          if ssh -o "BatchMode=yes" -o "StrictHostKeyChecking=accept-new" \
                 -o "UserKnownHostsFile=/dev/null" -o "ConnectTimeout=2" \
                 -o "LogLevel=ERROR" "$user@$ip" true 2>/dev/null; then
            echo "$ip"
            return 0
          fi
        fi
        sleep 2
      done
      echo "error: timed out waiting for SSH on $name" >&2
      return 1
    }

    cmd_vm_boot_iso() {
      local name="" iso="" nested=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --nested) nested=1 ;;
          -*)       echo "unknown flag: $1" >&2; return 2 ;;
          *)        if [[ -z "$name" ]]; then
                      name="$1"
                    elif [[ -z "$iso" ]]; then
                      iso="$1"
                    else
                      echo "unexpected: $1" >&2; return 2
                    fi ;;
        esac
        shift
      done
      if [[ -z "$name" || -z "$iso" ]]; then
        echo "usage: devbox-cli vm boot-iso <name> <iso-path> [--nested]" >&2
        return 2
      fi
      require_tart
      local nested_flag=""
      if [[ $nested -eq 1 ]]; then nested_flag="--nested"; fi
      # shellcheck disable=SC2086
      tart run $nested_flag --disk "$iso:ro" "$name"
    }

    parse_ref() {
      # Splits "<flake>#<host>" into globals REF_FLAKE and REF_HOST. Returns
      # 2 if the form is wrong.
      local ref="$1"
      if [[ "$ref" != *"#"* ]]; then
        echo "error: ref must be in <flake>#<host> form (got: $ref)" >&2
        return 2
      fi
      REF_FLAKE="''${ref%#*}"
      REF_HOST="''${ref#*#}"
    }

    cmd_init() {
      local ref="" ssh_key="" parent_pubkey=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --ssh-key=*)       ssh_key="''${1#*=}" ;;
          --parent-pubkey=*) parent_pubkey="''${1#*=}" ;;
          -*)                echo "unknown flag: $1" >&2; return 2 ;;
          *)                 if [[ -z "$ref" ]]; then ref="$1"; else echo "unexpected: $1" >&2; return 2; fi ;;
        esac
        shift
      done
      if [[ -z "$ref" ]]; then
        echo "usage: devbox-cli init <flake>#<host> [--ssh-key=PATH] [--parent-pubkey=PATH]" >&2
        return 2
      fi
      parse_ref "$ref" || return $?
      require_tart

      if [[ -n "$ssh_key" ]]; then
        if [[ ! -f "$ssh_key" ]]; then
          echo "error: --ssh-key file not found: $ssh_key" >&2
          return 1
        fi
        export DEVBOX_SSH_KEY="$ssh_key"
      fi
      if [[ -n "$parent_pubkey" ]]; then
        if [[ ! -f "$parent_pubkey" ]]; then
          echo "error: --parent-pubkey file not found: $parent_pubkey" >&2
          return 1
        fi
        export DEVBOX_PARENT_PUBKEY="$parent_pubkey"
      fi

      local installer_attr="$REF_FLAKE#nixosConfigurations.$REF_HOST.config.system.build.devboxInstaller"
      local link_dir
      link_dir=$(mktemp -d)
      local link="$link_dir/installer"

      # Pass devbox.nix.{substituters,trustedPublicKeys} through as
      # --option flags. nix-daemon honors them only if the substituters
      # are already in the host's trusted-substituters list, so this is a
      # best-effort speedup, not a trust mechanism.
      local substs keys
      substs=$(nix eval --json "$REF_FLAKE#nixosConfigurations.$REF_HOST.config.devbox.nix.substituters" 2>/dev/null \
                 | jq -r 'join(" ")')
      keys=$(nix eval --json "$REF_FLAKE#nixosConfigurations.$REF_HOST.config.devbox.nix.trustedPublicKeys" 2>/dev/null \
               | jq -r 'join(" ")')
      local -a build_opts=()
      if [[ -n "$substs" ]]; then
        build_opts+=(--option extra-substituters "$substs")
      fi
      if [[ -n "$keys" ]]; then
        build_opts+=(--option extra-trusted-public-keys "$keys")
      fi

      echo "building installer ISO ($installer_attr)..."
      nix build --impure "''${build_opts[@]}" "$installer_attr" -o "$link"

      local iso
      iso=$(find -L "$link" -name '*.iso' | head -1)
      if [[ -z "$iso" ]]; then
        echo "error: no ISO found in $link" >&2
        rm -rf "$link_dir"
        return 1
      fi

      local disk memory nested
      disk=$(nix eval --json "$REF_FLAKE#nixosConfigurations.$REF_HOST.config.devbox.vm.diskGB")
      memory=$(nix eval --json "$REF_FLAKE#nixosConfigurations.$REF_HOST.config.devbox.vm.memoryMB")
      nested=$(nix eval --json "$REF_FLAKE#nixosConfigurations.$REF_HOST.config.devbox.vm.nested")

      echo "creating tart VM '$REF_HOST' (''${disk}GB)..."
      tart delete "$REF_HOST" 2>/dev/null || true
      tart create --linux "$REF_HOST" --disk-size "$disk"
      if [[ "$memory" != "null" ]]; then
        echo "setting memory to ''${memory}MB..."
        tart set "$REF_HOST" --memory "$memory"
      fi

      local nested_flag=""
      if [[ "$nested" == "true" ]]; then
        nested_flag="--nested"
        echo "nested virtualization enabled"
      fi

      echo "booting installer ISO (a VM window will open)..."
      echo "the VM will auto-partition, install NixOS, and shut down."
      # shellcheck disable=SC2086
      tart run $nested_flag --disk "$iso:ro" "$REF_HOST" || true

      rm -rf "$link_dir"

      echo "init complete."
      echo "next: devbox-cli up $REF_HOST''${nested_flag:+ --nested}"
      echo "      devbox-cli update $ref"
    }

    cmd_update() {
      local ref="''${1:-}"
      if [[ -z "$ref" ]]; then
        echo "usage: devbox-cli update <flake>#<host>" >&2
        return 2
      fi
      parse_ref "$ref" || return $?
      require_tart

      local flake_dir
      if [[ "$REF_FLAKE" == "." ]]; then
        flake_dir=$(git rev-parse --show-toplevel 2>/dev/null) || {
          echo "error: '.' flake ref but not in a git repo" >&2
          return 1
        }
      else
        flake_dir=$(nix flake metadata "$REF_FLAKE" --json 2>/dev/null | jq -r '.path // empty')
        if [[ -z "$flake_dir" || "$flake_dir" == "null" ]]; then
          echo "error: cannot resolve flake source for $REF_FLAKE (only local flakes are supported by 'update')" >&2
          return 1
        fi
      fi

      local user
      user=$(nix eval --raw "$REF_FLAKE#nixosConfigurations.$REF_HOST.config.devbox.user.login") || {
        echo "error: cannot read $REF_FLAKE#nixosConfigurations.$REF_HOST.config.devbox.user.login" >&2
        return 1
      }

      local ip
      ip=$(tart ip "$REF_HOST" 2>/dev/null || true)
      if [[ -z "$ip" ]]; then
        echo "error: tart ip returned no address for $REF_HOST. Is it running?" >&2
        echo "       devbox-cli up $REF_HOST" >&2
        return 1
      fi

      # Connect to the raw IP, not any ssh_config alias. The alias may carry
      # tailscale hostnames, custom ControlPath, RequestTTY=force, or a stale
      # known_hosts entry — all of which interfere with first-rebuild auth.
      local -a ssh_opts=(
        -o "StrictHostKeyChecking=accept-new"
        -o "UserKnownHostsFile=/dev/null"
        -o "LogLevel=ERROR"
      )
      local rsync_ssh="ssh -T ''${ssh_opts[*]}"

      echo "copying flake source to $REF_HOST ($ip)..."
      rsync -az --rsh "$rsync_ssh" --exclude='.git' --exclude='result' \
        "$flake_dir/" "$user@$ip:/tmp/nix-config/"

      echo "running nixos-rebuild switch on $REF_HOST..."
      # Heavy substitution from cache.nixos.org during a full rebuild can
      # blow past the default 1024 fd limit; bump it for this session.
      ssh "''${ssh_opts[@]}" -t "$user@$ip" \
        "ulimit -n 65536 && sudo nixos-rebuild switch --flake /tmp/nix-config#$REF_HOST"

      echo "done."
    }

    cmd_up() {
      cmd_vm_start "$@"
    }

    cmd_down() {
      cmd_vm_stop "$@"
    }

    cmd_rm() {
      cmd_vm_remove "$@"
    }

    if [[ $# -lt 1 ]]; then
      usage
      exit 2
    fi

    case "$1" in
      vm)
        if [[ $# -lt 2 ]]; then usage; exit 2; fi
        sub="$2"; shift 2
        case "$sub" in
          create)   cmd_vm_create "$@" ;;
          start)    cmd_vm_start "$@" ;;
          stop)     cmd_vm_stop "$@" ;;
          remove)   cmd_vm_remove "$@" ;;
          ip)       cmd_vm_ip "$@" ;;
          wait-ssh) cmd_vm_wait_ssh "$@" ;;
          boot-iso) cmd_vm_boot_iso "$@" ;;
          *) echo "unknown vm subcommand: $sub" >&2; usage; exit 2 ;;
        esac ;;
      init)   shift; cmd_init "$@" ;;
      update) shift; cmd_update "$@" ;;
      up)     shift; cmd_up "$@" ;;
      down)   shift; cmd_down "$@" ;;
      rm)     shift; cmd_rm "$@" ;;
      -h|--help|help)
        usage ;;
      *)
        echo "unknown subcommand: $1" >&2
        usage
        exit 2 ;;
    esac
  '';
}
