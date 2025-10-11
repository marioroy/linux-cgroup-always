# Linux Cgroup Always

Ghostty-like `linux-cgroup = always` feature via systemd-run. The benefit
is overall improved desktop interactivity by preventing resource hogging,
enhancing isolation, and ensuring fair resource distribution.

This works with { `alacritty`, `kitty`, `konsole`, `qterminal`, `screen`,
`tmux: server` } and interactive shells { `bash`, `fish`, `zsh` }.
Refer to the end of the readme for Ghostty and GNOME Terminal setup.

## Pool Requirements for Niceness Support

Niceness support refers to calling the nice command across multiple terminal
windows or panes, made possible by attaching to the same cgroup. This requires
the `libcgroup` package and have the `cgconfig.service` enabled.

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

The installer adds 10 entries to `/etc/cgconfig.conf`, ending in `{0..9}`.

```text
$ ./cgconfig.install

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

## Shell Activation

Preferably, source the environment file near the top of your shell
startup script for early activation.

```bash
# ~/.bashrc
source /path/to/env-systemd/attach_shell_to_unique_cgroup.bash

# ~/.config/fish/config.fish
source /path/to/env-systemd/attach_shell_to_unique_cgroup.fish

# ~/.zshrc
source /path/to/env-systemd/attach_shell_to_unique_cgroup.zsh
```

Or copy the env file to your shell function folder. Comment out the
line calling `attach_shell_to_unique_cgroup`. Instead, call it near
the top of your shell startup script.

## Verification

Launch the terminal application and check the cgroup membership.

```bash
$ cat /proc/self/cgroup 
---------------------------------------------------------------
0::/user.slice/.../user@1000.service/app.slice/shell-3608.scope
```

The `systemd-cgtop` command can be used to monitor resource usage.
Being deeply nested, `cgtop` shows one service entry where the
`app.slice` task groups reside.

```bash
$ systemd-cgtop
----------------------------------------------------------------------
CGroup                            Tasks   %CPU Memory Input/s Output/s
/                                   986 1600.9     5G       -        -
user.slice                          470 1599.8     2G       -        -
user.slice/user-1000.slice          470 1599.8   1.9G       -        -
user.slice/.../user@1000.service    155 1598.1 580.7M       -        -
user.slice/.../session-2.scope      306    0.2   1.1G       -        -
system.slice                         66    0.1 444.9M       -        -
```

## Starting tmux or Terminal Emulator interactively

The `INVOCATION_ID` environment variable is set by `systemd` for all
processes started as part of a service unit, including those launched
via `systemd-run`. If starting `screen`, `tmux`, or another terminal
emulator from inside the shell, clear the `INVOCATION_ID` variable.

```bash
$ env INVOCATION_ID= konsole -e zsh
$ env INVOCATION_ID= qterminal -e zsh
$ env INVOCATION_ID= screen -S my_project
$ env INVOCATION_ID= tmux
```

## Helper Functions 

**cgterm_attach**

A process/thread's nice value has an effect for scheduling decisions only
relative to other process/threads in the same task group. For nice support
across multiple terminal windows or panes, call helper function with `[0-9]`
to attach multiple emulators to the same base cgroup.

```bash
# terminal one
$ cgterm_attach 1
0::/user.slice/user-1000.slice/term-1
$ nice -n 0 primesieve 1e12
Seconds: 6.144

# terminal two
$ cgterm_attach 1
0::/user.slice/user-1000.slice/term-1
$ nice -n 9 primesieve 1e12
Seconds: 10.478
```

**cgterm_detach**

Detach reverts back to the originating cgroup. The result is the Linux kernel
scheduler equalizes the distribution of CPU cycles across the task groups.

```bash
# terminal one
$ cgterm_detach
0::/user.slice/.../user@1000.service/app.slice/shell-3608.scope
$ nice -n 0 primesieve 1e12
Seconds: 10.434

# terminal two
$ cgterm_detach
0::/user.slice/.../user@1000.service/app.slice/shell-2715.scope
$ nice -n 9 primesieve 1e12
Seconds: 10.510
```

**cgterm_quota**

The `cgterm_quota [1..100]` function can be used to get/set the max CPU
quota percentage. The default percent is 100 with a range of 1 to 100.

Applying a change to a base cgroup emits an error. Likewise, for the
other helper functions.

```bash
$ cat /proc/self/cgroup
0::/user.slice/.../user@1000.service/app.slice/shell-3608.scope

$ cgterm_quota
100

$ primesieve 1e12
Seconds: 5.224

$ cgterm_quota 50
$ primesieve 1e12
Seconds: 10.543

$ cgterm_attach 2
0::/user.slice/user-1000.slice/term-1

$ cgterm_quota 70
cannot apply quota to base cgroup
```

**cgterm_weight**

The `cgterm_weight [1..10000]` function can be used to get/set the
relative priority for CPU and I/O resources, when there is contention.
A cgroup with a higher weight will receive a proportionally larger
share. The default weight is 100 with a range of 1 to 10,000.

The weight is applied to both `cpu.weight` and `io.weight`.

```bash
# terminal one
$ cat /proc/self/cgroup
0::/user.slice/.../user@1000.service/app.slice/shell-3608.scope
$ cgterm_weight 100 (default)
$ primesieve 1e12
Seconds: 10.699

# terminal two
$ cat /proc/self/cgroup
0::/user.slice/.../user@1000.service/app.slice/shell-2715.scope
$ cgterm_weight 500
$ primesieve 1e12
Seconds: 7.041
```

**cgterm_nice**

Alternatively, the `cgterm_nice [-20..19]` function can be used to
get/set the value using the same values as the `nice` command, ranging
from -20 to 19. A cgroup with a lower value will receive a relative
larger CPU share.

```bash
# terminal one
$ cat /proc/self/cgroup
0::/user.slice/.../user@1000.service/app.slice/shell-3608.scope
$ cgterm_nice 0 (default)
$ primesieve 1e12
Seconds: 6.039

# terminal two
$ cat /proc/self/cgroup
0::/user.slice/.../user@1000.service/app.slice/shell-2715.scope
$ cgterm_nice 9
$ primesieve 1e12
Seconds: 10.437
```

**cgterm_reset**

The `cgterm_reset` function can be used to reset the cgroup2 files
`cpu.max`, `cpu.weight`, `cpu.weight.nice`, and `io.weight` to default.

```bash
$ cgterm_reset

# cpu.max          max 100000
# cpu.weight       100
# cpu.weight.nice  0
# io.weight        100
```

## Uninstall

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

## Acknowledgement

Thank you, to the CachyOS community with sounding board and testing.

- ms178
- nutcase
- phusho

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

