# This file must be sourced in Fish:
#
# Fish function to move the shell PID to a unique cgroup
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

function attach_shell_to_unique_cgroup
    # Fish function to move the shell PID to a unique cgroup

    # If not running interactively, don't do anything.
    if not status --is-interactive
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

    # If previously attached uniquely, do nothing.
    set --local UID (id -u)
    set --local match "/user.slice/user-$UID.slice/term-"
    read -l cgroup < "/proc/self/cgroup"
    if string match --quiet --regex "$match\d[a-z]\Z" "$cgroup"
        return 0
    end

    # If the term-0c/cgroup.procs file is missing, do nothing.
    # Possibly /etc/cgconfig.conf pre-defined entries missing or
    # running cgroup v1.
    set --local cgroot "/sys/fs/cgroup/user.slice/user-$UID.slice"
    if not test -e "$cgroot/term-0c/cgroup.procs"
        return 0
    end

    # If the cgroup.procs file cannot be opened for writing, do nothing.
    # To move a process from cgroup A to cgroup B, the user attempting
    # the move must have write permissions to the common ancestor of
    # both A and B.
    bash -c '
        cd "/sys/fs/cgroup/user.slice/user-$UID.slice"
        exec {lock_fd}>>cgroup.procs || exit 0
        trap "exec {lock_fd}>&-" EXIT # close lock handle

        # get the last letter suffix {a..z} of the pool capacity
        last_suffix=$(\ls -1d term-0*)
        last_suffix="${last_suffix: -1}" # last char of string

        # select base cgroup from the last char of the PPID value
        cgname="term-${PPID: -1}"
        shell_pid="$PPID"

        # obtain an exclusive lock
        flock -x $lock_fd

        # select another base cgroup if the last suffix is taken
        read -r line < "${cgname}${last_suffix}/cgroup.procs"
        if [[ -n "$line" ]]; then
            # quick scan
            cgname2=""
            for i in {0..9}; do
                read -r line < "term-${i}${last_suffix}/cgroup.procs"
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

        # all taken, move the shell PID into base cgroup
        echo $shell_pid > "${cgname}/cgroup.procs"
    ' 2> /dev/null
end

attach_shell_to_unique_cgroup

function cgterm_attach
    # Display the shell cgroup.
    # If base cgroup, try attaching the shell to unique cgroup.
    set --local UID (id -u)
    set --local match "/user.slice/user-$UID.slice/term-"
    read -l cgroup < "/proc/self/cgroup"
    if string match --quiet --regex "$match\d[a-z]\Z" "$cgroup"
        echo "$cgroup"
    else
        attach_shell_to_unique_cgroup
        cat "/proc/self/cgroup"
    end
end

function cgterm_free
    # Display the list of available cgroups.
    set --local UID (id -u)
    set --local conf "/etc/cgconfig.conf"
    set --local match "group user.slice/user-$UID.slice/term-"
    for g in (grep -s "^$match" $conf | sed -e 's/^group //' -e 's/ {$//')
        if test -d "/sys/fs/cgroup/$g"
            read -l line < "/sys/fs/cgroup/$g/cgroup.procs"
            if test -z "$line"
                echo "$g"
            end
        end
    end
end

function cgterm_taken
    # Display the list of taken cgroups.
    set --local UID (id -u)
    set --local conf "/etc/cgconfig.conf"
    set --local match "group user.slice/user-$UID.slice/term-"
    for g in (grep -s "^$match" $conf | sed -e 's/^group //' -e 's/ {$//')
        if test -d "/sys/fs/cgroup/$g"
            read -l line < "/sys/fs/cgroup/$g/cgroup.procs"
            if test -n "$line"
                echo "$g"
            end
        end
    end
end

