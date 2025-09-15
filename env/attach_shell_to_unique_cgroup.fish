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

    # If the parent command is not in the list, do nothing.
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

    # If the UID of the cgroup.procs file is not $UID, do nothing.
    # To move a process from cgroup A to cgroup B, the user attempting
    # the move must have write permissions to the common ancestor of
    # both A and B.
    set --local UID (id -u)
    set --local cgroot "/sys/fs/cgroup/user.slice/user-$UID.slice"
    set --local uid (stat -c '%u' "$cgroot/cgroup.procs")
    if test "$uid" != "$UID"
        return 0
    end

    # If the term-0/cgroup.procs file is missing, do nothing.
    if not test -e "$cgroot/term-0/cgroup.procs"
        # /etc/cgconfig.conf lacking pre-defined entries
        # or possibly not running cgroup v2
        return 0
    end

    # If the last_suffix is blank e.g. no term-* cgroups, do nothing.
    set --export last_suffix (ls -1d "$cgroot/term-0"* 2>/dev/null | tail -1)
    set last_suffix (string sub --start -1 $last_suffix)
    if test -z "$last_suffix"
        return 0
    end

    # Select base cgroup from the last char of the shell PID value.
    set --local last_char (string sub --start -1 $fish_pid)
    set --export cgname "term-$last_char"
    set --local lockfile "$cgroot/cgroup.procs"
    set --export shell_pid "$fish_pid"

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
            [[ ! -d "$cgname${letter}" ]] && break
            read -r line < "$cgname${letter}/cgroup.procs"
            if [[ -z "$line" ]]; then
                # move the shell PID into empty cgroup
                echo $shell_pid > "${cgname}${letter}/cgroup.procs"
                exit 0
            fi
        done

        # move the shell PID into base cgroup
        echo $shell_pid > "$cgname/cgroup.procs"
    '

    set -e cgname last_suffix shell_pid
end

attach_shell_to_unique_cgroup

function cgterm_attach
    # Display the shell cgroup.
    # If base cgroup, try attaching the shell to unique cgroup.
    set --local UID (id -u)
    set --local match "/user-$UID.slice/term-"
    set --local cgroup (cat "/proc/self/cgroup")
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

