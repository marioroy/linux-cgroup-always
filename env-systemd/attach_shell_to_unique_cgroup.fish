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
        case alacritty kitty konsole qterminal screen "tmux: server"
            # supported - proceed
        case sshd-session
            # supported
        case '*'
            return 0
    end

    # Launch shell with the cgroup CPU controller enabled.
    # Using lscpu as nproc may differ depending on CPU affinity.
    set --local cpus (lscpu --parse=cpu)
    set --local ncpus (math "$cpus[-1] + 1")
    set --local FISH (status fish-path)

    exec systemd-run -q --user --scope --unit="shell-$fish_pid" \
         -p CPUQuota="$ncpus"00% -p IOAccounting=yes \
         -p AllowedCPUs="0-$cpus[-1]" -- "$FISH"
end

function cgterm_attach
    # Attach and display the shell cgroup.
    set --local arg $argv[1]
    read -l cgroup < "/proc/self/cgroup"

    if test -n "$arg"
        # attach to a base cgroup, error if not [0-9]
        if string match --quiet --regex -- "\A\d\Z" "$arg"
            set --local UID (id -u)
            set --local cgroot "/sys/fs/cgroup/user.slice/user-$UID.slice"
            if not test -d "$cgroot/term-$arg"
                echo "cannot access the base cgroup 'term-$arg': not enabled"
                return 1
            end
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

function cgterm_cpus
    # Get or set the cgroup list of CPU indices or ranges.
    set --local UID (id -u)
    set --local match "/user.slice/user-$UID.slice/term-"

    read -l cgroup < "/proc/self/cgroup"
    set --local cpath (string replace -r '^.*::/' '' $cgroup)
    set --local arg $argv[1]

    if not test -e "/sys/fs/cgroup/$cpath/cpuset.cpus"
        echo "cannot access cpuset.cpus: not available"
        return 1
    end

    if test -z "$arg"
        read -l cpus < "/sys/fs/cgroup/$cpath/cpuset.cpus"
        if test -z "$cpus"
            read cpus < "/sys/fs/cgroup/$cpath/cpuset.cpus.effective"
        end
        echo "$cpus"
    else
        if string match --quiet --regex -- "$match" "$cgroup"
            echo "cannot apply change: attached to a base cgroup"
            return 1
        end
        if test "$arg" = "all"
            set --local cpus (lscpu --parse=cpu)
            set --local last $cpus[-1]
            echo "0-$last" > "/sys/fs/cgroup/$cpath/cpuset.cpus" || return 1
            if test -z $argv[2]
                # prevent recursion
                cgterm_memnodes "all" "_internal_use_"
            end
        else if test "$arg" = "performance"
            if test -z "$CGTERM_PERFORMANCE_CPUS"
                echo "cannot apply change: CGTERM_PERFORMANCE_CPUS undefined"
            else
                echo "$CGTERM_PERFORMANCE_CPUS" \
                    > "/sys/fs/cgroup/$cpath/cpuset.cpus" || return 1
                cgterm_memnodes "all" "_internal_use_"
            end
        else if test "$arg" = "powersave"
            if test -z "$CGTERM_POWERSAVE_CPUS"
                echo "cannot apply change: CGTERM_POWERSAVE_CPUS undefined"
            else
                echo "$CGTERM_POWERSAVE_CPUS" \
                    > "/sys/fs/cgroup/$cpath/cpuset.cpus" || return 1
                cgterm_memnodes "all" "_internal_use_"
            end
        else
            echo "$arg" > "/sys/fs/cgroup/$cpath/cpuset.cpus" || return 1
        end
    end
end

function cgterm_memnodes
    # Get or set the cgroup list of memory nodes indices or ranges.
    # Call cgterm_cpus with a list of CPUs for given memory nodes.
    set --local UID (id -u)
    set --local match "/user.slice/user-$UID.slice/term-"

    read -l cgroup < "/proc/self/cgroup"
    set --local cpath (string replace -r '^.*::/' '' $cgroup)
    set --local arg $argv[1]

    if not test -e "/sys/fs/cgroup/$cpath/cpuset.mems"
        echo "cannot access cpuset.mems: not available"
        return 1
    end

    if test -z "$arg"
        read -l nodes < "/sys/fs/cgroup/$cpath/cpuset.mems"
        if test -z "$nodes"
            read nodes < "/sys/fs/cgroup/$cpath/cpuset.mems.effective"
        end
        echo "$nodes"
    else
        if string match --quiet --regex -- "$match" "$cgroup"
            echo "cannot apply change: attached to a base cgroup"
            return 1
        end
        if test "$arg" = "all"
            set --local nodes (lscpu --parse=node)
            set --local last $nodes[-1]
            echo "0-$last" > "/sys/fs/cgroup/$cpath/cpuset.mems" || return 1
            if test -z $argv[2]
                # prevent recursion
                cgterm_cpus "all" "_internal_use_"
            end
        else
            echo "$arg" > "/sys/fs/cgroup/$cpath/cpuset.mems" || return 1
            read -l nodes < "/sys/fs/cgroup/$cpath/cpuset.mems"
            set nodes (string split ',' -- $nodes)

            # Expand a mixed range string like "0-1,3" into a list of integers
            set --local integers ""
            for part in $nodes
                if string match --quiet --regex -- "\A[0-9]+-[0-9]+\Z" "$part"
                    set part (string split '-' -- $part)
                    set --local begin $part[1]
                    set --local end $part[2]
                    set integers "$integers"(seq "$begin" "$end" | tr '\n' '|')
                else
                    set integers "$integers""$part|"
                end
            end

            # Build a list of CPUs connected to the memory nodes
            set integers (string trim -r -c '|' $integers)
            set --local lscpu (lscpu --parse=cpu,node)
            set --local cpus ""
            for line in $lscpu
                if string match --quiet --regex -- ",($integers)\Z" "$line"
                    set line (string split ',' -- $line)
                    set cpus "$cpus""$line[1] "
                end
            end

            # Set CPU affinity
            cgterm_cpus "$cpus"
        end
    end
end

function cgterm_nice
    # Get or set the cgroup nice value [-20..19, idle].
    set --local UID (id -u)
    set --local match "/user.slice/user-$UID.slice/term-"

    read -l cgroup < "/proc/self/cgroup"
    set --local cpath (string replace -r '^.*::/' '' $cgroup)
    set --local arg $argv[1]

    read -l idle < "/sys/fs/cgroup/$cpath/cpu.idle"
    read -l nice < "/sys/fs/cgroup/$cpath/cpu.weight.nice"

    if test -z "$arg"
        if test "$idle" = "1"
            echo "idle"
        else
            echo "$nice"
        end
    else
        if string match --quiet --regex -- "$match" "$cgroup"
            echo "cannot apply change: attached to a base cgroup"
            return 1
        end
        if test "$arg" = "idle"
            echo "1" > "/sys/fs/cgroup/$cpath/cpu.idle" || return 1
            if test -e "/sys/fs/cgroup/$cpath/io.weight"
                echo "1" > "/sys/fs/cgroup/$cpath/io.weight"
            end
        else if string match --quiet --regex -- "\A-?[0-9]+\Z" "$arg"
                and test "$arg" -ge -20
                and test "$arg" -le  19
            echo "0" > "/sys/fs/cgroup/$cpath/cpu.idle" || return 1
            echo "$arg" > "/sys/fs/cgroup/$cpath/cpu.weight.nice" || return 1
            if test -e "/sys/fs/cgroup/$cpath/io.weight"
                read -l weight < "/sys/fs/cgroup/$cpath/cpu.weight"
                echo "$weight" > "/sys/fs/cgroup/$cpath/io.weight"
            end
        else
            echo "invalid argument"
            return 1
        end
    end
end

function cgterm_quota
    # Get or set the cgroup quota percent [1..100].
    set --local UID (id -u)
    set --local match "/user.slice/user-$UID.slice/term-"

    read -l cgroup < "/proc/self/cgroup"
    set --local cpath (string replace -r '^.*::/' '' $cgroup)
    set --local arg $argv[1]

    read -l cpuline < "/sys/fs/cgroup/$cpath/cpu.max"
    set cpuline (string split ' ' -- $cpuline)
    set --local max $cpuline[1]
    set --local period $cpuline[2]
    set --local cpus (lscpu --parse=cpu)
    set --local ncpus (math "$cpus[-1] + 1")

    if test "$max" = "max"
        set max (math "$ncpus * $period")
    end

    if test -z "$arg"
        echo (math "$max * 100 / $ncpus / $period")
    else
        if string match --quiet --regex -- "$match" "$cgroup"
            echo "cannot apply change: attached to a base cgroup"
            return 1
        end
        if string match --quiet --regex -- "\A[0-9]+\Z" "$arg"
                and test "$arg" -ge 1
                and test "$arg" -le 100
            set max (math "$ncpus * $period * $arg / 100")
            echo "$max $period" > "/sys/fs/cgroup/$cpath/cpu.max" || return 1
        else
            echo "invalid argument"
            return 1
        end
    end
end

function cgterm_weight
    # Get or set the cgroup weight [1..10000, idle].
    set --local UID (id -u)
    set --local match "/user.slice/user-$UID.slice/term-"

    read -l cgroup < "/proc/self/cgroup"
    set --local cpath (string replace -r '^.*::/' '' $cgroup)
    set --local arg $argv[1]

    read -l idle < "/sys/fs/cgroup/$cpath/cpu.idle"
    read -l weight < "/sys/fs/cgroup/$cpath/cpu.weight"

    if test -z "$arg"
        if test "$idle" = "1"
            echo "idle"
        else
            echo "$weight"
        end
    else
        if string match --quiet --regex -- "$match" "$cgroup"
            echo "cannot apply change: attached to a base cgroup"
            return 1
        end
        if test "$arg" = "idle"
            echo "1" > "/sys/fs/cgroup/$cpath/cpu.idle" || return 1
            if test -e "/sys/fs/cgroup/$cpath/io.weight"
                echo "1" > "/sys/fs/cgroup/$cpath/io.weight"
            end
        else if string match --quiet --regex -- "\A[0-9]+\Z" "$arg"
                and test "$arg" -ge 1
                and test "$arg" -le 10000
            echo "0" > "/sys/fs/cgroup/$cpath/cpu.idle" || return 1
            echo "$arg" > "/sys/fs/cgroup/$cpath/cpu.weight" || return 1
            if test -e "/sys/fs/cgroup/$cpath/io.weight"
                echo "$arg" > "/sys/fs/cgroup/$cpath/io.weight"
            end
        else
            echo "invalid argument"
            return 1
        end
    end
end

function cgterm_reset
    # Reset the cgroup nice, quota, and weight values.
    set --local UID (id -u)
    set --local match "/user.slice/user-$UID.slice/term-"

    read -l cgroup < "/proc/self/cgroup"
    set --local cpath (string replace -r '^.*::/' '' $cgroup)

    read -l cpuline < "/sys/fs/cgroup/$cpath/cpu.max"
    set cpuline (string split ' ' -- $cpuline)
    set --local period $cpuline[2]

    if string match --quiet --regex -- "$match" "$cgroup"
        echo "cannot reset values: attached to a base cgroup"
        return 1
    end

    echo "max $period" > "/sys/fs/cgroup/$cpath/cpu.max" || return 1
    echo "0" > "/sys/fs/cgroup/$cpath/cpu.idle" || return 1
    echo "100" > "/sys/fs/cgroup/$cpath/cpu.weight" || return 1

    if test -e "/sys/fs/cgroup/$cpath/io.weight"
        echo "100" > "/sys/fs/cgroup/$cpath/io.weight"
    end

    # Reset the cpuset cpus and mems values.
    if test -e "/sys/fs/cgroup/$cpath/cpuset.cpus"
        set --local lscpu (lscpu --parse=cpu,node)
        set --local last (string split ',' -- $lscpu[-1])
        echo "0-$last[1]" > "/sys/fs/cgroup/$cpath/cpuset.cpus"
        echo "0-$last[2]" > "/sys/fs/cgroup/$cpath/cpuset.mems"
    end
end

attach_shell_to_unique_cgroup

