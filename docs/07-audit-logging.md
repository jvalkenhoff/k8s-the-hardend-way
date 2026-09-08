Install:
```
apt install aide aide-common auditd -y
```

## 7.1 Configure persistent local logging
Journald records kernel messages, systemd service output, and application messages sent to the journal. Persistent storage ensures these records remain available after a reboot.
### 7.1.1 Use only journald
Remove rsyslog when it is installed:
```bash
apt purge -y rsyslog
```

### 7.1.2 Configure retention and persistent storage
Create the drop-in directory:
```bash
install -d -o root -g root -m 0755 /etc/systemd/journald.conf.d
```

Create the node logging policy:
```bash
cat > /etc/systemd/journald.conf.d/10-node-logging.conf <<'EOF'
[Journal]
Storage=persistent
Compress=yes
Seal=yes
ForwardToSyslog=no

# Adjust these values to the size of the /var/log filesystem.
SystemMaxUse=1G
SystemKeepFree=500M
MaxRetentionSec=1month

# Limit temporary journal use before persistent storage is available.
RuntimeMaxUse=200M
RuntimeKeepFree=50M
EOF
```

Protect the configuration:
```bash
chown root:root /etc/systemd/journald.conf.d/10-node-logging.conf

chmod 0644 /etc/systemd/journald.conf.d/10-node-logging.conf
```

Create the persistent journal directory:
```bash
install -d -o root -g systemd-journal -m 2755 /var/log/journal
```

Restart journald and flush the runtime journal:
```bash
systemctl restart systemd-journald.service
journalctl --flush
```

Do not recursively change ownership and permissions across `/var/log`. Log files are created by different services with intentionally different owners and groups. The package and service defaults should remain in control unless a specific application requires correction.

Confirm that journald is active and using persistent storage:

```bash
systemctl is-active systemd-journald.service
journalctl --disk-usage
journalctl --verify
```

`systemd-journald.service` is normally a static system service. It does not need to report `enabled`; it must report `active`.

---
## 7.2 Configure kernel auditing
Auditd records selected security events independently from normal application logging. This baseline focuses on changes that affect administrative access, persistence, boot trust, networking, host security policy, and later, Kubernetes configuration.
### 7.2.1 Enable auditd
Create the audit log directory:
```bash
install -d -o root -g root -m 0750 /var/log/audit
```

Enable and start auditd:
```
systemctl unmask auditd.service
systemctl enable auditd.service
systemctl start auditd.service
```

### 7.2.2 Enable auditing during early boot
Processes can start before `auditd.service`. Add kernel parameters so auditing begins before the userspace daemon is running.

Read the existing GRUB kernel parameters and add the audit parameters in `/etc/default/grub`
Add these two parameters inside `GRUB_CMDLINE_LINUX`:
```
audit=1 audit_backlog_limit=8192
```

So it becomes:
```
GRUB_CMDLINE_LINUX="apparmor=1 security=apparmor audit=1 audit_backlog_limit=8192"
```

```bash
cat > /etc/default/grub.d/audit.cfg <<'EOF'
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX audit=1 audit_backlog_limit=8192"
EOF
```

Then update GRUB:
```
update-grub
```

The new kernel parameters become active after the final reboot.

### 7.2.3 Configure audit retention and failure behavior
Audit rules determine how quickly events are generated. The settings in `auditd.conf` determine how those events are stored and what happens when storage becomes constrained.

Create a full new `/etc/audit/auditd.conf` file:
```bash
cat > /etc/audit/auditd.conf <<'EOF'
local_events = yes
write_logs = yes

log_file = /var/log/audit/audit.log
log_group = root
log_format = ENRICHED
name_format = HOSTNAME

flush = INCREMENTAL_ASYNC
freq = 50

# Keep a bounded set of local audit logs.
max_log_file = 64
num_logs = 5
max_log_file_action = rotate

# Warn while there is still enough space to respond.
space_left = 25%
space_left_action = syslog

# Restrict the node before the audit filesystem becomes unusable.
admin_space_left = 10%
admin_space_left_action = single

# Do not continue normal operation when audit records cannot be written.
disk_full_action = halt
disk_error_action = halt
EOF
```

Set permissions correctly:
```
chown root:root /etc/audit/auditd.conf
chmod 0640 /etc/audit/auditd.conf
```


> [!WARNING]
> The `halt` actions deliberately prioritize evidence preservation over availability. Confirm that `/var/log/audit` has enough space and that storage usage is monitored before applying this policy to production nodes.

restart the service:
```
service auditd restart
```

### 7.2.4 Create a focused node audit policy
Move existing rule snippets out of the active directory:
```bash
find /etc/audit/rules.d -mindepth 1 -maxdepth 1 -type f -name '*.rules' -exec mv -t /root/sb/etc/audit/rules.d-disabled/ {} +
```

> [!NOTE] 
> This is appropriate for the fresh lab node. On an existing system, review application-specific and organization-specific rules before replacing them.


Create one rule file:
```bash
cat > /etc/audit/rules.d/10-hardening.rules <<EOF
# Start from one known rule set.
-D

# Match the kernel audit backlog configured in GRUB.
-b 8192

# Send an audit subsystem failure to the kernel log.
-f 1

# Privilege-boundary execution, such as a SUID program.
-a always,exit -F arch=b64 -S execve -C euid!=uid -F auid>=1000 -F auid!=unset -k privilege-use

# User-initiated changes to time, host identity, mounts, and kernel modules.
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -F auid>=1000 -F auid!=unset -k time-change
-a always,exit -F arch=b64 -S sethostname,setdomainname -F auid>=1000 -F auid!=unset -k host-identity
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=unset -k mounts
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -F auid>=1000 -F auid!=unset -k kernel-modules

# Privilege and local identity configuration.
-w /etc/sudoers -p wa -k privilege-config
-w /etc/sudoers.d -p wa -k privilege-config
-w /var/log/sudo.log -p wa -k privilege-config

-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/pam.d -p wa -k identity
-w /etc/security -p wa -k identity
-w /etc/nsswitch.conf -p wa -k identity

# Remote access.
-w /etc/ssh -p wa -k remote-access
-w /home/debian/.ssh -p wa -k remote-access

# Boot and mandatory access-control policy.
-w /etc/default/grub -p wa -k boot
-w /etc/grub.d -p wa -k boot
-w /boot/grub/grub.cfg -p wa -k boot
-w /etc/apparmor.d -p wa -k apparmor

# Scheduled and service-based persistence.
-w /etc/crontab -p wa -k persistence
-w /etc/cron.d -p wa -k persistence
-w /etc/cron.hourly -p wa -k persistence
-w /etc/cron.daily -p wa -k persistence
-w /etc/cron.weekly -p wa -k persistence
-w /etc/cron.monthly -p wa -k persistence
-w /var/spool/cron/crontabs -p wa -k persistence
-w /etc/systemd/system -p wa -k persistence
-w /usr/local/bin -p wa -k persistence
-w /usr/local/sbin -p wa -k persistence

# Host networking and the audit configuration itself.
-w /etc/hostname -p wa -k network-config
-w /etc/hosts -p wa -k network-config
-w /etc/systemd/network -p wa -k network-config
-w /etc/systemd/resolved.conf -p wa -k network-config
-w /etc/audit -p wa -k audit-config
EOF
```

Set permissions:
```bash
chown root:root /etc/audit/rules.d/10-hardening.rules
chmod 0640 /etc/audit/rules.d/10-hardening.rules
```

Apply the rules:
```
augenrules --load
```

Confirm that the rule set compiles and that the focused rule keys are loaded:
```bash
augenrules --check

auditctl -l | grep -E 'scope|identity|access|boot|persistence|network-config|audit-config|kubernetes-node|kernel-modules'
```

The output should show the rules for paths that exist on this node. 


> [!IMPORTANT]
> The following section is after the completion of full Kubernetes setup. After chapter 14, come back to finish the AIDE installation and setup

## 7.3 Configure AIDE
AIDE compares stable host content against a database. It should focus on configuration, boot files, administrative tooling, and host binaries.
### 7.3.1 Add node-specific AIDE rules
Add explicit stable-content groups and Kubernetes-aware exclusions:
```bash
cat >> /etc/aide/aide.conf <<'EOF'
# Stable configuration and security tools.
StableConfig = p+i+n+u+g+s+b+m+c+acl+xattrs+sha512
AuditTool = p+i+n+u+g+s+b+acl+xattrs+sha512

# Host security and persistence configuration.
/etc/audit StableConfig
/etc/ssh StableConfig
/etc/pam.d StableConfig
/etc/security StableConfig
/etc/systemd/system StableConfig
/etc/cron.d StableConfig
/etc/crontab StableConfig
/etc/default/grub StableConfig
/etc/grub.d StableConfig

# Kubernetes and container runtime configuration.
# These paths become part of the baseline when they exist.
/etc/containerd/config\.toml StableConfig
/etc/kubernetes StableConfig
/var/lib/kubelet/config\.yaml StableConfig

# Volatile evidence and runtime data are not stable integrity targets.
!/var/log/.*
!/run/.*
!/var/lib/containerd/.*
!/var/lib/kubelet/pods/.*
!/var/lib/kubelet/plugins/.*
!/var/lib/kubelet/plugins_registry/.*
!/var/log/pods/.*
!/var/log/containers/.*

# Interactive history changes constantly and is already covered by
# normal access controls and logging.
!/root/\.bash_history
!/root/\.lesshst
!/root/\.viminfo

/usr/sbin/auditctl AuditTool
/usr/sbin/auditd AuditTool
/usr/sbin/ausearch AuditTool
/usr/sbin/aureport AuditTool
/usr/sbin/autrace AuditTool
/usr/sbin/augenrules AuditTool

EOF
```

Protect the configuration:
```bash
chown root:root /etc/aide/aide.conf
chmod 0640 /etc/aide/aide.conf
```
### 7.3.2 Create the daily integrity check
Create the daily AIDE check service and timer: 
- `dailyaidecheck.service`
- `dailyaidecheck.timer`

```
cat > /etc/systemd/system/dailyaidecheck.service <<'EOF'
[Unit]
Description=Daily AIDE filesystem integrity check

[Service]
Type=oneshot
ExecStart=/usr/bin/aide --config /etc/aide/aide.conf --check
EOF
```

Let the daily check run at 05:00.
```
cat > /etc/systemd/system/dailyaidecheck.timer <<'EOF'
[Unit]
Description=Run AIDE filesystem integrity check daily

[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true
Unit=dailyaidecheck.service

[Install]
WantedBy=timers.target
EOF
```

Set permissions correctly:
```
chown root:root /etc/systemd/system/dailyaidecheck.service /etc/systemd/system/dailyaidecheck.timer
chmod 0644 /etc/systemd/system/dailyaidecheck.service /etc/systemd/system/dailyaidecheck.timer
```

Reload systemctl daemon, start the service and timer:
```
systemctl daemon-reload
```

Do not enable the timer until a valid baseline database exists.
### 7.3.3 Initialize the final baseline
Perform this step only after:
- The Debian host hardening is complete.
- The container runtime is installed and configured.
- Kubernetes node configuration is present.
- All intentional package and configuration changes are finished.
- The AIDE exclusions match the runtime paths used by the cluster.

Remove any existing databases, if there are any:
```bash
rm -f /var/lib/aide/aide.db.new*
```

Initialize the AIDE database:
```
aideinit
```

After initializing the database, replace the default database:
```
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

Set permissions on the db:
```
chown root:root /var/lib/aide/aide.db
chmod 0600 /var/lib/aide/aide.db
```

Run one initial comparison:
```bash
/usr/bin/aide --config /etc/aide/aide.conf --check
```

Immediately after initialization, there should be no unexpected stable configuration changes. Do not rebuild the database merely to hide an unexplained difference; first determine why the file changed.

Enable the daily timer:
```bash
systemctl unmask dailyaidecheck.service dailyaidecheck.timer

systemctl enable --now dailyaidecheck.timer
```

Confirm the next scheduled run:
```bash
systemctl list-timers dailyaidecheck.timer
```

AIDE check results are written to the system journal through the systemd service:
```bash
journalctl -u dailyaidecheck.service
```

---
## 7.4 Finalize the audit policy
Audit rules should remain changeable while the node is being built. Once the host, container runtime, and Kubernetes configuration are complete, lock the running audit policy.

Create the finalization rule:
```
cat > /etc/audit/rules.d/99-finalize.rules <<'EOF'
# Prevent changes to the active audit policy until the next reboot.
-e 2
EOF
```

Set permissions:
```
chown root:root /etc/audit/rules.d/99-finalize.rules
chmod 0640 /etc/audit/rules.d/99-finalize.rules
```

Load it:
```
augenrules --load
```

Verify:
```
auditctl -s | grep '^enabled'
```

Expected:
```
enabled 2
```

From this point, files in `/etc/audit/rules.d` can still be edited, but a changed policy cannot be loaded until the node has rebooted.

---
## 7.5 Reboot and validate the installed layer
Reboot once to activate the kernel audit parameters and confirm that every component returns successfully:
```bash
reboot
```

After reconnecting, validate the components configured by this layer:
```bash
echo "== Persistent journal =="
systemctl is-active systemd-journald.service
journalctl --disk-usage

echo
echo "== Audit subsystem =="
systemctl is-active auditd.service
auditctl -s | grep -E \
  '^(enabled|backlog_limit|lost)'
augenrules --check

echo
echo "== Kernel audit parameters =="
cat /proc/cmdline |
  tr ' ' '\n' |
  grep -E \
    '^(audit|audit_backlog_limit)='

echo
echo "== AIDE schedule =="
systemctl is-active dailyaidecheck.timer
systemctl list-timers dailyaidecheck.timer
```

The important results are:
- Journald is active and has persistent disk usage.
- Auditd is active.
- `enabled 2` confirms that the audit policy is immutable.
- The kernel command line contains `audit=1` and `audit_backlog_limit=8192`.
- `augenrules --check` reports no difference between the source rules and generated rules.
- The AIDE timer is active and has a next-run time.
### 7.2.5 Add Kubernetes-specific watches
Add this file after containerd and Kubernetes have been installed and the listed paths exist:
```bash
cat > /etc/audit/rules.d/20-kubernetes-node.rules <<'EOF'
# Container runtime and Kubernetes node configuration.
-w /etc/containerd -p wa -k kubernetes-node
-w /etc/kubernetes -p wa -k kubernetes-node
-w /var/lib/kubelet/config.yaml -p wa -k kubernetes-node
EOF
```

Protect and load the additional rules:
```bash
chown root:root /etc/audit/rules.d/20-kubernetes-node.rules
chmod 0640 /etc/audit/rules.d/20-kubernetes-node.rules

augenrules --load
```

Do this before the finalization step in section 8.6. Once the audit policy is immutable, new rules cannot be loaded until after a reboot.