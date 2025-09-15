
## My favorite shell is missing

A pull request is welcomed if you like. The requirements are:

- Check if interactive shell
- Check the parent command, ensuring supported terminal application 
- Check the UID of the ancestor cgroup.procs file
- The base cgroup is derived from the last charactor of shell PID
- The file name is `attach_shell_to_unique_cgroup` with shell suffix
- Likewise, the function name is `attach_shell_to_unique_cgroup`
- Not forget the helper functions

Blessings and Grace.

