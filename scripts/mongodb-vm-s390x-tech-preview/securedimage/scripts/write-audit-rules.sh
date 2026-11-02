#!/bin/bash
# write-audit-rules.sh — writes all DISA STIG RHEL9 audit rules.d drop-ins
# Called from Containerfile §8e-A via COPY + RUN.
# Using printf avoids heredoc mis-parsing by podman's Dockerfile parser.
# set -e ensures any write failure aborts the build.
# Write to /usr/share/audit/rules.d/ (the vendor rules directory).
# augenrules merges rules from /usr/share/audit/rules.d/ AND /etc/audit/rules.d/
# in lexicographic order.  /usr/share/ has usr_t SELinux context which is
# accessible to root at build time and survives bootc/ostree label restoration —
# unlike /etc/audit/rules.d/ which has auditd_conf_t:0700 and is inaccessible
# to unconfined_t processes even as root.
set -e

D=/usr/share/audit/rules.d
mkdir -p "$D"

printf '## DAC modification syscalls (DISA STIG RHEL9)\n\
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k perm_mod\n\
-a always,exit -F arch=b64 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=unset -k perm_mod\n\
-a always,exit -F arch=b64 -S setxattr,fsetxattr,lsetxattr,removexattr,fremovexattr,lremovexattr -F auid>=1000 -F auid!=unset -k perm_mod\n\
-a always,exit -F arch=b64 -S umount,umount2 -F auid>=1000 -F auid!=unset -k perm_mod\n' \
  > "$D/20-syscall-dac.rules"

printf '## File deletion events (DISA STIG RHEL9)\n\
-a always,exit -F arch=b64 -S rename,renameat,rmdir,unlink,unlinkat -F auid>=1000 -F auid!=unset -k delete\n' \
  > "$D/21-syscall-delete.rules"

printf '## Unsuccessful file access attempts (DISA STIG RHEL9)\n\
-a always,exit -F arch=b64 -S creat,open,openat,open_by_handle_at,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k access\n\
-a always,exit -F arch=b64 -S creat,open,openat,open_by_handle_at,truncate,ftruncate -F exit=-EPERM  -F auid>=1000 -F auid!=unset -k access\n' \
  > "$D/22-syscall-open.rules"

printf '## Kernel module loading/unloading (DISA STIG RHEL9)\n\
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules\n' \
  > "$D/23-syscall-kmod.rules"

printf '## User/group modification (DISA STIG RHEL9)\n\
-w /etc/group   -p wa -k identity\n\
-w /etc/passwd  -p wa -k identity\n\
-w /etc/shadow  -p wa -k identity\n\
-w /etc/gshadow -p wa -k identity\n\
-w /etc/security/opasswd -p wa -k identity\n' \
  > "$D/24-usergroup.rules"

printf '## Logon/logout events (DISA STIG RHEL9)\n\
-w /var/log/faillock -p wa -k logins\n\
-w /var/log/lastlog  -p wa -k logins\n' \
  > "$D/25-login.rules"

printf '## Sudoers modification (DISA STIG RHEL9)\n\
-w /etc/sudoers   -p wa -k actions\n\
-w /etc/sudoers.d -p wa -k actions\n' \
  > "$D/26-sudoers.rules"

printf '## SELinux MAC modification (DISA STIG RHEL9)\n\
-a always,exit -F path=/usr/bin/chcon     -F perm=x -F auid>=1000 -F auid!=unset -k MAC-policy\n\
-a always,exit -F path=/usr/sbin/semanage -F perm=x -F auid>=1000 -F auid!=unset -k MAC-policy\n\
-a always,exit -F path=/usr/sbin/setfiles -F perm=x -F auid>=1000 -F auid!=unset -k MAC-policy\n\
-a always,exit -F path=/usr/sbin/setsebool -F perm=x -F auid>=1000 -F auid!=unset -k MAC-policy\n\
-a always,exit -F path=/usr/bin/chacl     -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng\n\
-a always,exit -F path=/usr/bin/setfacl   -F perm=x -F auid>=1000 -F auid!=unset -k perm_chng\n' \
  > "$D/27-selinux.rules"

printf '## Privileged command execution (DISA STIG RHEL9)\n\
-a always,exit -F path=/usr/sbin/init      -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/sbin/poweroff  -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/sbin/reboot    -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/sbin/shutdown  -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/chage      -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/chsh       -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/crontab    -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/gpasswd    -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/kmod       -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/mount      -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/newgrp     -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/sbin/pam_timestamp_check -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/passwd     -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/sbin/postdrop  -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/sbin/postqueue -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/ssh-agent  -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/libexec/openssh/ssh-keysign -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/su         -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/sudo       -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/sudoedit   -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/bin/umount     -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/sbin/unix_chkpwd -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/sbin/unix_update -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/sbin/userhelper -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n\
-a always,exit -F path=/usr/sbin/usermod   -F perm=x -F auid>=1000 -F auid!=unset -k privileged\n' \
  > "$D/28-privileged.rules"

printf '## SUID/SGID execution (DISA STIG RHEL9)\n\
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid\n\
-a always,exit -F arch=b64 -S execve -C gid!=egid -F egid=0 -k setgid\n' \
  > "$D/29-suid.rules"

printf '## Kernel panic on audit failure (DISA STIG RHEL9)\n\
-f 2\n' \
  > "$D/30-shutdown.rules"

printf '## Cron execution monitoring (DISA STIG RHEL9)\n\
-w /etc/cron.allow -p wa -k cron\n\
-w /etc/cron.deny  -p wa -k cron\n\
-w /etc/cron.d     -p wa -k cron\n\
-w /etc/cron.daily -p wa -k cron\n\
-w /etc/cron.hourly -p wa -k cron\n\
-w /etc/cron.monthly -p wa -k cron\n\
-w /etc/cron.weekly  -p wa -k cron\n\
-w /etc/crontab -p wa -k cron\n\
-w /var/spool/cron/crontabs -p wa -k cron\n' \
  > "$D/31-cron.rules"

printf '## Immutable flag -- audit_rules_immutable (DISA STIG RHEL9)\n## oscap checks for -e 2 in the rules FILE (not live kernel state).\n-e 2\n' \
  > "$D/99-finalize.rules"

# Verify — abort build if fewer than 10 files were written
NFILES=$(ls "$D"/*.rules 2>/dev/null | wc -l)
echo "[write-audit-rules] wrote ${NFILES} rules files to ${D}"
[ "${NFILES}" -ge 10 ] || { echo "ERROR: expected >=10 rules files, got ${NFILES}"; exit 1; }

# Lock down permissions (0640 is correct for /usr/share vendor files)
find "$D" -type f -exec chmod 0640 {} \;
chmod 0755 "$D"

echo "[write-audit-rules] permissions set. Done."
