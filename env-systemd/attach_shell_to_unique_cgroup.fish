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

function cgterm_attach
    # Attach and display the shell cgroup.
    set --local arg $argv[1]
    read -l cgroup < "/proc/self/cgroup"

    if test -n "$arg"
        # attach to a base cgroup, error if not [0-9]
        if string match --quiet --regex "\A\d\Z" "$arg"
            set --local UID (id -u)
            set --local cgroot "/sys/fs/cgroup/user.slice/user-$UID.slice"
            if test -z "$OLDCGROUP"
                set -gx OLDCGROUP "$cgroup"
                set -g  OLDCGROUP_PID (bash -c '
                    # prevent the old cgroup from being removed
                    nohup sleep infinity &>/dev/null &
                    echo $!
                ')
                trap '
                    if test -n "$OLDCGROUP_PID"
                        kill $OLDCGROUP_PID
                    end
                ' EXIT
            end
            echo "$fish_pid" > "$cgroot/term-$arg/cgroup.procs"
            cat "/proc/self/cgroup"
        else
            echo "invalid argument"
            return 1
        end
    else
        # do nothing
        echo "$cgroup"
    end
end

function cgterm_detach
    # Detach and display the shell cgroup.
    if test -n "$OLDCGROUP_PID"
        # revert back to the originating cgroup
        set --local cpath (string replace -r '^.*::/' '' $OLDCGROUP)

        echo "$fish_pid" > "/sys/fs/cgroup/$cpath/cgroup.procs"
        kill $OLDCGROUP_PID 2>/dev/null
        set -e OLDCGROUP_PID OLDCGROUP

        trap - EXIT
    end

    cat "/proc/self/cgroup"
end

function cgterm_nice
    # Get or set the cgroup nice value [0-19].
    set --local UID (id -u)
    set --local match "/user.slice/user-$UID.slice/term-"

    read -l cgroup < "/proc/self/cgroup"
    set --local cpath (string replace -r '^.*::/' '' $cgroup)
    set --local arg $argv[1]

    if test -z "$arg"
        cat "/sys/fs/cgroup/$cpath/cpu.weight.nice"
    else
        if string match --quiet --regex "$match" "$cgroup"
            echo "cannot apply nice value to base cgroup"
            return 1
        end
        if string match --quiet --regex "\A[0-9]+\Z" "$arg"
                and test "$arg" -le 19
            echo "$arg" > "/sys/fs/cgroup/$cpath/cpu.weight.nice"
        else
            echo "invalid argument"
            return 1
        end
    end
end

function cgterm_quota
    # Get or set the cgroup quota percent [10-100].
    set --local UID (id -u)
    set --local match "/user.slice/user-$UID.slice/term-"

    read -l cgroup < "/proc/self/cgroup"
    set --local cpath (string replace -r '^.*::/' '' $cgroup)
    set --local arg $argv[1]

    read -l cpuline < "/sys/fs/cgroup/$cpath/cpu.max"
    set cpuline (string split ' ' -- $cpuline)
    set --local max $cpuline[1]
    set --local period $cpuline[2]
    set --local nproc (nproc)

    if test "$max" = "max"
        set max (math "$nproc * $period")
    end

    if test -z "$arg"
        echo (math "$max * 100 / $nproc / $period")
    else
        if string match --quiet --regex "$match" "$cgroup"
            echo "cannot apply quota to base cgroup"
            return 1
        end
        if string match --quiet --regex "\A[0-9]+\Z" "$arg"
                and test "$arg" -ge 10
                and test "$arg" -le 100
            set max (math "$nproc * $period * $arg / 100")
            echo "$max $period" > "/sys/fs/cgroup/$cpath/cpu.max"
        else
            echo "invalid argument"
            return 1
        end
    end
end

attach_shell_to_unique_cgroup

