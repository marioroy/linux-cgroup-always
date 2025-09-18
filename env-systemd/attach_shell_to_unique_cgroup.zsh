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

attach_shell_to_unique_cgroup

