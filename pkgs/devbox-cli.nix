{
  writeShellApplication,
  jq,
  openssh,
  coreutils,
}:
writeShellApplication {
  name = "devbox-cli";
  runtimeInputs = [
    jq
    openssh
    coreutils
  ];
  text = ''
    usage() {
      cat <<'EOF'
    Usage: devbox-cli <subcommand> [args...]

    VM lifecycle (raw hypervisor operations):
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
      -h|--help|help)
        usage ;;
      *)
        echo "unknown subcommand: $1" >&2
        usage
        exit 2 ;;
    esac
  '';
}
