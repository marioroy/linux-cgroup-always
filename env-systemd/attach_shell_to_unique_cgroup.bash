# This file must be sourced in Bash:

function attach_shell_to_unique_cgroup {
    # Launch a new bash shell within a systemd-run scope,
    # with the CPU controller explicitly enabled.

    # If not running interactively or previously attached, do nothing.
    [[ $- != *i* || -n "$INVOCATION_ID" ]] && return 0

    # If the parent terminal command is not in the list, do nothing.
    # Ghostty provides support with the "linux-cgroup = always" option.
    # Refer to readme for GNOME Terminal. Other terminal applications
    # can be supported, by adding /proc/$PPID/comm result to the list.
    local cmd=""
    read -r cmd < "/proc/$PPID/comm"
    case "$cmd" in
        alacritty|kitty|konsole|qterminal|"tmux: server")
            # supported - proceed
            ;;
        *) return 0
    esac

    # Launch shell with the cgroup CPU controller enabled.
    exec systemd-run -q --user --scope --unit="shell-$$" \
         -p CPUAccounting=yes -p CPUQuota=$(nproc)00% -- "$BASH"
}

function cgterm_nice {
    # Get or set the cgroup nice level.
    local cgroup cpath
    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}
    if [ -z "$1" ]; then
        cat "/sys/fs/cgroup/$cpath/cpu.weight.nice"
    else
        if [[ "$1" =~ ^[0-9]+$ ]] && (($1 <= 19)); then
            echo "$1" > "/sys/fs/cgroup/$cpath/cpu.weight.nice"
        else
            echo "invalid argument"
            return 1
        fi
    fi
}

attach_shell_to_unique_cgroup

