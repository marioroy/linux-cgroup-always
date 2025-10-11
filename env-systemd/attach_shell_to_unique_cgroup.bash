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
        alacritty|kitty|konsole|qterminal|screen|"tmux: server")
            # supported - proceed
            ;;
        *) return 0
    esac

    # Launch shell with the cgroup CPU controller enabled.
    exec systemd-run -q --user --scope --unit="shell-$$" \
         -p CPUAccounting=yes -p IOAccounting=yes \
         -p CPUQuota=$(nproc)00% -- "$BASH"
}

function cgterm_attach {
    # Attach and display the shell cgroup.
    local cgroup=""
    read -r cgroup < "/proc/self/cgroup"

    if [ -n "$1" ]; then
        # attach to a base cgroup, error if not [0-9]
        if [[ "$1" = [0-9] ]]; then
            local cgroot="/sys/fs/cgroup/user.slice/user-$UID.slice"
            if [[ -z "$OLDCGROUP" ]]; then
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

function cgterm_nice {
    # Get or set the cgroup nice value [-20..19].
    local match="/user.slice/user-$UID.slice/term-"
    local cgroup cpath
    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}

    if [ -z "$1" ]; then
        cat "/sys/fs/cgroup/$cpath/cpu.weight.nice"
    else
        if [[ "$cgroup" = *"$match"* ]]; then
            echo "cannot apply nice value to base cgroup"
            return 1
        fi
        if [[ "$1" =~ ^-?[0-9]+$ ]] && (($1 >= -20 && $1 <= 19)); then
            echo "$1" > "/sys/fs/cgroup/$cpath/cpu.weight.nice"
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
    else
        if [[ "$cgroup" = *"$match"* ]]; then
            echo "cannot apply quota to base cgroup"
            return 1
        fi
        if [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 100)); then
            max=$((nproc * period * $1 / 100))
            echo "$max $period" > "/sys/fs/cgroup/$cpath/cpu.max"
        else
            echo "invalid argument"
            return 1
        fi
    fi
}

function cgterm_weight {
    # Get or set the cgroup weight [1..10000].
    local match="/user.slice/user-$UID.slice/term-"
    local cgroup cpath weight

    read -r cgroup < "/proc/self/cgroup"
    cpath=${cgroup#*::/}

    read -r weight < "/sys/fs/cgroup/$cpath/cpu.weight"

    if [ -z "$1" ]; then
        echo "$weight"
    else
        if [[ "$cgroup" = *"$match"* ]]; then
            echo "cannot apply weight to base cgroup"
            return 1
        fi
        if [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 10000)); then
            echo "$1" > "/sys/fs/cgroup/$cpath/cpu.weight"
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
        echo "cannot reset base cgroup"
        return 1
    fi

    echo "max $period" > "/sys/fs/cgroup/$cpath/cpu.max"
    echo "100" > "/sys/fs/cgroup/$cpath/cpu.weight"

    if [ -e "/sys/fs/cgroup/$cpath/io.weight" ]; then
        echo "100" > "/sys/fs/cgroup/$cpath/io.weight"
    fi
}

attach_shell_to_unique_cgroup

