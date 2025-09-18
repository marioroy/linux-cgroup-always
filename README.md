# Linux Cgroup Always

Ghostty-like `linux-cgroup = always` feature via systemd-run or pre-defined
pool of cgroup names. The benefit is overall improved desktop interactivity
by preventing resource hogging, enhancing isolation, and ensuring fair
resource distribution.

This works with { `alacritty`, `kitty`, `konsole`, `qterminal`, `tmux: server` }
and interactive shells { `bash`, `fish`, `zsh` }. Refer to the end of the readme
for Ghostty and GNOME Terminal setup.

## Systemd-run or Pool

Choose between two approaches. Cgroup via transient systemd scope unit
or pre-defined pool of cgroup names. If former, source the `env-systemd`
file. No further steps needed.

Continue reading for the pool approach.

## Pool Requirements

The intended use-case is your personal Linux machine or workstation,
have `libcgroup` package installed, and `cgconfig.service` enabled.

Steps for Arch-based distributions:

```bash
source ~/.config/user-dirs.dirs
cd "$XDG_DOWNLOAD_DIR"
git clone --depth=1 https://aur.archlinux.org/libcgroup.git
cd libcgroup

gpg --keyserver keyserver.ubuntu.com --recv-keys E050B79D5B290D03
makepkg -si

sudo systemctl enable --now cgconfig.service
```

## Attach Shell to Unique Cgroup

**Installation**

The minimum and maximum pool capacity are 30 and 260, respectively.
This adds 50 cgroup entries (10 + 40) to `/etc/cgconfig.conf`. The pool
consists of ten basenames ending in `{0..9}` and four suffixes `{a..d}`
per basename.

Want to change capacity later? Run installer again with desired capacity.

```text
$ ./cgconfig.install [capacity] (default 40)

Adding pool of cgroup entries to /etc/cgconfig.conf
group user.slice/user-ID.slice/term-0 {
        perm {
                admin {
                        uid = [USER];
                        gid = [USER];
                }
                task {
                        tuid = [USER];
                        tgid = [USER];
                }
        }
}
...
Adding and enabling set-owner-cgroup-procs-ID.service
Created symlink '/etc/systemd/system/sysinit.target.wants/set-owner...
Please reboot the machine for the changes to take effect
```

**Shell Activation**

Preferably, source the environment file near the top of your shell
startup script for early activation.

```bash
# ~/.bashrc
source /path/to/env/attach_shell_to_unique_cgroup.bash

# ~/.config/fish/config.fish
source /path/to/env/attach_shell_to_unique_cgroup.fish

# ~/.zshrc
source /path/to/env/attach_shell_to_unique_cgroup.zsh
```

Or copy the `attach_shell_to_unique_cgroup` env file to your shell
function folder. Call the `attach_shell_to_unique_cgroup` function
near the top of your shell startup script.

**Verification**

Launch the terminal application and check the cgroup membership.
The base name `term-{0..9}` is derived from the last character
of the shell PID value. The next empty cgroup is selected, suffix
`{a..k}` unless exhausted (no suffix). 

```bash
$ cat /proc/self/cgroup 
------------------------------------
0::/user.slice/user-ID.slice/term-3e
```

The cgroup basename is term-{0..9} without a suffix {a..k} after reaching
pool capacity. Once resources have been freed, a helper function can be
called to move the shell process to a unique cgroup. (optional)

```bash
$ cat /proc/self/cgroup 
------------------------------------
0::/user.slice/user-ID.slice/term-4

$ cgterm_attach
------------------------------------
user.slice/user-ID.slice/term-8c
```

Helper functions can be used to display the usage.

```bash
$ cgterm_taken
------------------------------------
user.slice/user-ID.slice/term-3e
user.slice/user-ID.slice/term-6a
user.slice/user-ID.slice/term-8c

$ cgterm_free | wc -l
------------------------------------
47
```

The `systemd-cgtop` command can be used to monitor resource usage.

```bash
$ systemd-cgtop
----------------------------------------------------------------------
CGroup                            Tasks   %CPU Memory Input/s Output/s
/                                   986 1600.9     5G       -        -
user.slice                          470 1599.8     2G       -        -
user.slice/user-1000.slice          470 1599.8   1.9G       -        -
user.slice/user-1000.slice/term-3e   18  799.8 158.5M       -        -
user.slice/user-1000.slice/term-6a   10  798.5 140.3M       -        -
user.slice/user-1000.slice/term-8c    2    0.8   3.8M       -        -
user.slice/user-.../session-2.scope 306    0.2   1.1G       -        -
system.slice                         66    0.1 444.9M       -        -
```

**Uninstall**

Run the uninstall script to undo the system-level changes. Separately,
remove the entry from your shell's function folder or startup script.

```text
$ ./cgconfig.uninstall 

Removing pool of cgroup entries from /etc/cgconfig.conf
group user.slice/user-ID.slice/term-0 {
        perm {
                admin {
                        uid = [USER];
                        gid = [USER];
                }
                task {
                        tuid = [USER];
                        tgid = [USER];
                }
        }
}
...
Disabling and removing set-owner-cgroup-procs-ID.service
Removed '/etc/systemd/system/sysinit.target.wants/set-owner...
Please reboot the machine for the changes to take effect
```

## Ghostty

Ghostty can isolate each terminal surface directly with the
`linux-cgroup = always` option: `~/.config/ghostty/config`

Calling `attach_shell_to_unique_cgroup` is a NO-OP, does nothing.

## GNOME Terminal

Isolating GNOME Terminal windows is possible as well, simply adding
the `CPUQuota` entry to the service file.

Likewise, calling `attach_shell_to_unique_cgroup` is a NO-OP.

```bash
mkdir -p ~/.config/systemd/user
cd ~/.config/systemd/user
cp /usr/lib/systemd/user/gnome-terminal-server.service .
```

Edit the file and add line `CPUQuota=100%` to the Service section.

```text
[Unit]
Description=GNOME Terminal Server
PartOf=graphical-session.target
[Service]
Slice=app-org.gnome.Terminal.slice
CPUQuota=100%
Type=dbus
BusName=org.gnome.Terminal
ExecStart=/usr/lib/gnome-terminal-server
TimeoutStopSec=5s
KillMode=process
```

Restart the service. This will close any opened GNOME Terminal windows.
So, be mindful of any unsave work inside GNOME Terminal.

```bash
systemctl --user daemon-reload
systemctl --user restart gnome-terminal-server.service
```

## LICENSE 

```text
This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
at your option any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
```

