# This file must be sourced in Zsh:

function attach_shell_to_unique_cgroup {
    # Launch a new zsh shell within a systemd-run scope,
    # with the CPU controller explicitly enabled.

    # If not running interactively or previously attached, do nothing.
    [[ ! -o interactive || -n "$INVOCATION_ID" ]] && return 0

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
         -p CPUAccounting=yes -p CPUQuota=$(nproc)00% -- "$ZSH_NAME"
}

function cgterm_nice {
    # Get or set the cgroup nice value [0-19].
    local cgroup cpath
    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}

    if [ -z "$1" ]; then
        cat "/sys/fs/cgroup/$cpath/cpu.weight.nice"
    elif [[ "$1" =~ ^[0-9]+$ ]] && (($1 <= 19)); then
        echo "$1" > "/sys/fs/cgroup/$cpath/cpu.weight.nice"
    else
        echo "invalid argument"
        return 1
    fi
}

function cgterm_quota {
    # Get or set the cgroup quota percent [10-100].
    local cgroup cpath cpuline max period
    local nproc=$(nproc)

    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}

    read -r cpuline < "/sys/fs/cgroup/$cpath/cpu.max"
    max=${cpuline% *}
    period=${cpuline#* }

    if [ "$max" = "max" ]; then
        max=$((nproc * period))
    fi

    if [ -z "$1" ]; then
        echo $((max * 100 / nproc / period))
    elif [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 10 && $1 <= 100)); then
        max=$((nproc * period * $1 / 100))
        echo "$max $period" > "/sys/fs/cgroup/$cpath/cpu.max"
    else
        echo "invalid argument"
        return 1
    fi
}

attach_shell_to_unique_cgroup

