# This file must be sourced in Fish:

function attach_shell_to_unique_cgroup
    # Launch a new fish shell within a systemd-run scope,
    # with the CPU controller explicitly enabled.

    # If not running interactively or previously attached, do nothing.
    if not status --is-interactive
        or test -n "$INVOCATION_ID"
        return 0
    end

    # If the parent terminal command is not in the list, do nothing.
    # Ghostty provides support with the "linux-cgroup = always" option.
    # Refer to readme for GNOME Terminal. Other terminal applications
    # can be supported, by adding /proc/$PPID/comm result to the list.
    set --local PPID (ps -o ppid= -p $fish_pid)
    set PPID (string trim --left -- $PPID)
    read -l cmd < "/proc/$PPID/comm"
    switch "$cmd"
        case alacritty kitty konsole qterminal "tmux: server"
            # supported - proceed
        case '*'
            return 0
    end

    # Launch shell with the cgroup CPU controller enabled.
    set --local FISH (status fish-path)
    exec systemd-run -q --user --scope --unit="shell-$fish_pid" \
         -p CPUAccounting=yes -p CPUQuota=(nproc)00% -- "$FISH"
end

function cgterm_nice
    # Get or set the cgroup nice level.
    read -l cgroup < "/proc/self/cgroup"
    set --local cpath (string replace -r '^.*::/' '' $cgroup)
    set --local arg $argv[1]
    if test -z "$arg"
        cat "/sys/fs/cgroup/$cpath/cpu.weight.nice"
    else
        if string match --quiet --regex "\A[0-9]+\Z" "$arg"
                and test "$arg" -le 19
            echo "$arg" > "/sys/fs/cgroup/$cpath/cpu.weight.nice"
        else
            echo "invalid argument"
            return 1
        end
    end
end

attach_shell_to_unique_cgroup

