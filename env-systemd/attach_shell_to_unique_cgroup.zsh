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
        alacritty|kitty|konsole|qterminal|screen|"tmux: server")
            # supported - proceed
            ;;
        sshd-session)
            ;;
        *) return 0
    esac

    # Launch shell with the cgroup CPU controller enabled.
    # Using lscpu as nproc may differ depending on CPU affinity.
    local cpus=("${(@f)$(lscpu --parse=cpu)}")
    local ncpus=$((${cpus[-1]} + 1))

    exec systemd-run -q --user --scope --unit="shell-$$" \
         -p CPUQuota=${ncpus}00% -p IOAccounting=yes \
         -p AllowedCPUs="0-${cpus[-1]}" -- "$ZSH_NAME"
}

function cgterm_attach {
    # Attach and display the shell cgroup.
    local cgroup=""
    read -r cgroup < "/proc/self/cgroup"

    if [ -n "$1" ]; then
        # attach to a base cgroup, error if not [0-9]
        if [[ "$1" = [0-9] ]]; then
            local cgroot="/sys/fs/cgroup/user.slice/user-$UID.slice"
            if [ ! -d "$cgroot/term-$1" ]; then
                echo "cannot access the base cgroup 'term-$1': not enabled"
                return 1
            fi
            if [ -z "$OLDCGROUP" ]; then
                export OLDCGROUP="$cgroup"
                OLDCGROUP_PID=$(bash -c '
                    # prevent the old cgroup from being removed
                    nohup sleep infinity &>/dev/null &
                    echo $!
                ')
                trap '[ -n "$OLDCGROUP_PID" ] && kill $OLDCGROUP_PID' EXIT
            fi
            echo "$$" > "$cgroot/term-$1/cgroup.procs"
            cat /proc/self/cgroup
        else
            echo "invalid argument"
            return 1
        fi
    else
        # do nothing
        echo "$cgroup"
    fi
}

function cgterm_detach {
    # Detach and display the shell cgroup.
    if [ -n "$OLDCGROUP_PID" ]; then
        # revert back to the originating cgroup
        local cpath=${OLDCGROUP#*::/}

        echo "$$" > "/sys/fs/cgroup/$cpath/cgroup.procs"
        kill $OLDCGROUP_PID 2>/dev/null
        unset OLDCGROUP_PID OLDCGROUP

        trap - EXIT
    fi

    cat /proc/self/cgroup
}

function cgterm_cpus {
    # Get or set the cgroup list of CPU indices or ranges.
    local match="/user.slice/user-$UID.slice/term-"
    local cgroup cpath

    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}

    if [ ! -e "/sys/fs/cgroup/$cpath/cpuset.cpus" ]; then
        echo "cannot access cpuset.cpus: not available"
        return 1
    fi

    if [ -z "$1" ]; then
        local cpus; read -r cpus < "/sys/fs/cgroup/$cpath/cpuset.cpus"
        if [ -z "$cpus" ]; then
            read -r cpus < "/sys/fs/cgroup/$cpath/cpuset.cpus.effective"
        fi
        echo "$cpus"
    else
        if [[ "$cgroup" = *"$match"* ]]; then
            echo "cannot apply change: attached to a base cgroup"
            return 1
        fi
        if [ "$1" = "all" ]; then
            local cpus=("${(@f)$(lscpu --parse=cpu)}")
            local last="${cpus[-1]}"
            echo "0-$last" > "/sys/fs/cgroup/$cpath/cpuset.cpus" || return 1
            if [ -z "$2" ]; then
                # prevent recursion
                cgterm_memnodes "all" "_internal_use_"
            fi
        elif [ "$1" = "performance" ]; then
            if [ -z "$CGTERM_PERFORMANCE_CPUS" ]; then
                echo "cannot apply change: CGTERM_PERFORMANCE_CPUS undefined"
            else
                echo "$CGTERM_PERFORMANCE_CPUS" \
                    > "/sys/fs/cgroup/$cpath/cpuset.cpus" || return 1
                cgterm_memnodes "all" "_internal_use_"
            fi
        elif [ "$1" = "powersave" ]; then
            if [ -z "$CGTERM_POWERSAVE_CPUS" ]; then
                echo "cannot apply change: CGTERM_POWERSAVE_CPUS undefined"
            else
                echo "$CGTERM_POWERSAVE_CPUS" \
                    > "/sys/fs/cgroup/$cpath/cpuset.cpus" || return 1
                cgterm_memnodes "all" "_internal_use_"
            fi
        else
            echo "$1" > "/sys/fs/cgroup/$cpath/cpuset.cpus" || return 1
        fi
    fi
}

function cgterm_memnodes {
    # Get or set the cgroup list of memory nodes indices or ranges.
    # Call cgterm_cpus with a list of CPUs for given memory nodes.
    local match="/user.slice/user-$UID.slice/term-"
    local cgroup cpath

    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}

    if [ ! -e "/sys/fs/cgroup/$cpath/cpuset.mems" ]; then
        echo "cannot access cpuset.mems: not available"
        return 1
    fi

    if [ -z "$1" ]; then
        local nodes; read -r nodes < "/sys/fs/cgroup/$cpath/cpuset.mems"
        if [ -z "$nodes" ]; then
            read -r nodes < "/sys/fs/cgroup/$cpath/cpuset.mems.effective"
        fi
        echo "$nodes"
    else
        if [[ "$cgroup" = *"$match"* ]]; then
            echo "cannot apply change: attached to a base cgroup"
            return 1
        fi
        if [ "$1" = "all" ]; then
            local nodes=("${(@f)$(lscpu --parse=node)}")
            local last="${nodes[-1]}"
            echo "0-$last" > "/sys/fs/cgroup/$cpath/cpuset.mems" || return 1
            if [ -z "$2" ]; then
                # prevent recursion
                cgterm_cpus "all" "_internal_use_"
            fi
        else
            echo "$1" > "/sys/fs/cgroup/$cpath/cpuset.mems" || return 1
            local nodes; read -r nodes < "/sys/fs/cgroup/$cpath/cpuset.mems"
            nodes=("${(@s:,:)nodes}")

            # Expand a mixed range string like "0-1,3" into a list of integers
            local integers="" part begin end
            for part in "${nodes[@]}"; do
                if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
                    begin="${part%-*}"; end="${part#*-}"
                    integers+="$(seq "$begin" "$end" | tr '\n' '|')"
                else
                    integers+="$part|"
                fi
            done

            # Build a list of CPUs connected to the memory nodes
            local regex=",(${integers%|*})$"
            local lscpu=("${(@f)$(lscpu --parse=cpu,node)}")
            local cpus="" line
            for line in "${lscpu[@]}"; do
                if [[ "$line" =~ $regex ]]; then
                    cpus+="${line%,*} "
                fi
            done

            # Set CPU affinity
            cgterm_cpus "$cpus"
        fi
    fi
}

function cgterm_nice {
    # Get or set the cgroup nice value [-20..19, idle].
    local match="/user.slice/user-$UID.slice/term-"
    local cgroup cpath idle nice

    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}

    read -r idle < "/sys/fs/cgroup/$cpath/cpu.idle"
    read -r nice < "/sys/fs/cgroup/$cpath/cpu.weight.nice"

    if [ -z "$1" ]; then
        if [ "$idle" = "1" ]; then
            echo "idle"
        else
            echo "$nice"
        fi
    else
        if [[ "$cgroup" = *"$match"* ]]; then
            echo "cannot apply change: attached to a base cgroup"
            return 1
        fi
        if [[ "$1" = "idle" ]]; then
            echo "1" > "/sys/fs/cgroup/$cpath/cpu.idle" || return 1
            if [ -e "/sys/fs/cgroup/$cpath/io.weight" ]; then
                echo "1" > "/sys/fs/cgroup/$cpath/io.weight"
            fi
        elif [[ "$1" =~ ^-?[0-9]+$ ]] && (($1 >= -20 && $1 <= 19)); then
            echo "0" > "/sys/fs/cgroup/$cpath/cpu.idle" || return 1
            echo "$1" > "/sys/fs/cgroup/$cpath/cpu.weight.nice" || return 1
            if [ -e "/sys/fs/cgroup/$cpath/io.weight" ]; then
                local weight
                read -r weight < "/sys/fs/cgroup/$cpath/cpu.weight"
                echo "$weight" > "/sys/fs/cgroup/$cpath/io.weight"
            fi
        else
            echo "invalid argument"
            return 1
        fi
    fi
}

function cgterm_quota {
    # Get or set the cgroup quota percent [1..100].
    local match="/user.slice/user-$UID.slice/term-"
    local cgroup cpath cpuline max period
    local cpus=("${(@f)$(lscpu --parse=cpu)}")
    local ncpus=$((${cpus[-1]} + 1))

    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}

    read -r cpuline < "/sys/fs/cgroup/$cpath/cpu.max"
    max=${cpuline% *}
    period=${cpuline#* }

    if [ "$max" = "max" ]; then
        max=$((ncpus * period))
    fi

    if [ -z "$1" ]; then
        echo $((max * 100 / ncpus / period))
    else
        if [[ "$cgroup" = *"$match"* ]]; then
            echo "cannot apply change: attached to a base cgroup"
            return 1
        fi
        if [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 100)); then
            max=$((ncpus * period * $1 / 100))
            echo "$max $period" > "/sys/fs/cgroup/$cpath/cpu.max" || return 1
        else
            echo "invalid argument"
            return 1
        fi
    fi
}

function cgterm_weight {
    # Get or set the cgroup weight [1..10000, idle].
    local match="/user.slice/user-$UID.slice/term-"
    local cgroup cpath idle weight

    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}

    read -r idle < "/sys/fs/cgroup/$cpath/cpu.idle"
    read -r weight < "/sys/fs/cgroup/$cpath/cpu.weight"

    if [ -z "$1" ]; then
        if [ "$idle" = "1" ]; then
            echo "idle"
        else
            echo "$weight"
        fi
    else
        if [[ "$cgroup" = *"$match"* ]]; then
            echo "cannot apply change: attached to a base cgroup"
            return 1
        fi
        if [[ "$1" = "idle" ]]; then
            echo "1" > "/sys/fs/cgroup/$cpath/cpu.idle" || return 1
            if [ -e "/sys/fs/cgroup/$cpath/io.weight" ]; then
                echo "1" > "/sys/fs/cgroup/$cpath/io.weight"
            fi
        elif [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 10000)); then
            echo "0" > "/sys/fs/cgroup/$cpath/cpu.idle" || return 1
            echo "$1" > "/sys/fs/cgroup/$cpath/cpu.weight" || return 1
            if [ -e "/sys/fs/cgroup/$cpath/io.weight" ]; then
                echo "$1" > "/sys/fs/cgroup/$cpath/io.weight"
            fi
        else
            echo "invalid argument"
            return 1
        fi
    fi
}

function cgterm_reset {
    # Reset the cgroup nice, quota, and weight values.
    local match="/user.slice/user-$UID.slice/term-"
    local cgroup cpath cpuline period

    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}

    read -r cpuline < "/sys/fs/cgroup/$cpath/cpu.max"
    period=${cpuline#* }

    if [[ "$cgroup" = *"$match"* ]]; then
        echo "cannot reset values: attached to a base cgroup"
        return 1
    fi

    echo "max $period" > "/sys/fs/cgroup/$cpath/cpu.max" || return 1
    echo "0" > "/sys/fs/cgroup/$cpath/cpu.idle" || return 1
    echo "100" > "/sys/fs/cgroup/$cpath/cpu.weight" || return 1

    if [ -e "/sys/fs/cgroup/$cpath/io.weight" ]; then
        echo "100" > "/sys/fs/cgroup/$cpath/io.weight"
    fi

    # Reset the cpuset cpus and mems values.
    if [ -e "/sys/fs/cgroup/$cpath/cpuset.cpus" ]; then
        local lscpu=("${(@f)$(lscpu --parse=cpu,node)}")
        local last="${lscpu[-1]}"
        echo "0-${last%,*}" > "/sys/fs/cgroup/$cpath/cpuset.cpus"
        echo "0-${last#*,}" > "/sys/fs/cgroup/$cpath/cpuset.mems"
    fi
}

attach_shell_to_unique_cgroup

