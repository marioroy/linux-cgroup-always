# This file must be sourced in Zsh:
#
# Zsh function to move the shell PID to a unique cgroup
# Copyright (C) 2025 Mario Roy
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# See the included GNU General Public License for more details.

function attach_shell_to_unique_cgroup {
    # Zsh function to move the shell PID to a unique cgroup

    # If not running interactively, don't do anything.
    [[ ! -o interactive ]] && return 0

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

    # If previously attached uniquely, do nothing.
    local match="/user.slice/user-$UID.slice/term-"
    local cgroup=""
    read -r cgroup < "/proc/self/cgroup"
    if [[ "$cgroup" = *"$match"[0-9][a-z] ]]; then
        return 0
    fi

    # If the term-0c/cgroup.procs file is missing, do nothing.
    # Possibly /etc/cgconfig.conf pre-defined entries missing or
    # running cgroup v1.
    local cgroot="/sys/fs/cgroup/user.slice/user-$UID.slice"
    if [[ ! -e "$cgroot/term-0c/cgroup.procs" ]]; then
        return 0
    fi

    # If the UID of the cgroup.procs file is not $UID, do nothing.
    # To move a process from cgroup A to cgroup B, the user attempting
    # the move must have write permissions to the common ancestor of
    # both A and B.
    if [[ $(stat -c '%u' "$cgroot/cgroup.procs") != "$UID" ]]; then
        return 0
    fi

    # Get the last letter suffix {a..z} of the pool capacity.
    export last_suffix=$(ls -1d "$cgroot/term-0"* 2>/dev/null | tail -1)
    last_suffix="${last_suffix: -1}"

    # Select base cgroup from the last char of the shell PID value.
    export cgname="term-${$: -1}"
    local lockfile="$cgroot/cgroup.procs"
    export shell_pid="$$"

    flock -e -w 2 --fcntl "$lockfile" bash -c '
        cd "/sys/fs/cgroup/user.slice/user-$UID.slice"
        read -r line < "${cgname}${last_suffix}/cgroup.procs"
        cgname2=""

        # select another base cgroup if the last suffix is taken
        if [[ -n "$line" ]]; then
            # quick scan
            for i in {0..9}; do
                # assume the path exists
                { read -r line < "term-${i}${last_suffix}/cgroup.procs"
                } 2>/dev/null
                if [[ -z "$line" ]]; then
                    # found base cgroup
                    cgname2="term-$i"
                    break
                fi
            done
            if [[ -n "$cgname2" ]]; then
                # set to found base cgroup
                cgname="$cgname2"
            else
                # full scan
                for i in {0..9}; do
                    for letter in {a..z}; do
                        [[ ! -d "term-${i}${letter}" ]] && break
                        read -r line < "term-${i}${letter}/cgroup.procs"
                        if [[ -z "$line" ]]; then
                            # found empty cgroup
                            echo $shell_pid > "term-${i}${letter}/cgroup.procs"
                            exit 0
                        fi
                    done
                done
            fi
        fi

        # search for untaken cgroup
        for letter in {a..z}; do
            [[ ! -d "${cgname}${letter}" ]] && break
            read -r line < "${cgname}${letter}/cgroup.procs"
            if [[ -z "$line" ]]; then
                # move the shell PID into empty cgroup
                echo $shell_pid > "${cgname}${letter}/cgroup.procs"
                exit 0
            fi
        done

        # move the shell PID into base cgroup
        echo $shell_pid > "${cgname}/cgroup.procs"
    '

    unset cgname last_suffix shell_pid
}

attach_shell_to_unique_cgroup

function cgterm_attach {
    # Display the shell cgroup.
    # If base cgroup, try attaching the shell to unique cgroup.
    local match="/user.slice/user-$UID.slice/term-"
    local cgroup=""
    read -r cgroup < "/proc/self/cgroup"
    if [[ "$cgroup" = *"$match"[0-9][a-z] ]]; then
        echo "$cgroup"
    else
        attach_shell_to_unique_cgroup
        cat /proc/self/cgroup
    fi
}

function cgterm_free {
    # Display the list of available cgroups.
    local conf="/etc/cgconfig.conf"
    local match="group user.slice/user-$UID.slice/term-"
    local line=""
    local g=""
    for g in $(grep -s "^$match" $conf | sed -e 's/^group //' -e 's/ {$//'); do
        if [[ -d "/sys/fs/cgroup/$g" ]]; then
            read -r line < "/sys/fs/cgroup/$g/cgroup.procs"
            [[ -z "$line" ]] && echo "$g"
        fi
    done
}

function cgterm_taken {
    # Display the list of taken cgroups.
    local conf="/etc/cgconfig.conf"
    local match="group user.slice/user-$UID.slice/term-"
    local line=""
    local g=""
    for g in $(grep -s "^$match" $conf | sed -e 's/^group //' -e 's/ {$//'); do
        if [[ -d "/sys/fs/cgroup/$g" ]]; then
            read -r line < "/sys/fs/cgroup/$g/cgroup.procs"
            [[ -n "$line" ]] && echo "$g"
        fi
    done
}

