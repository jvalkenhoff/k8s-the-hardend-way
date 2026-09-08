## 6.1 AppArmor
Install:
```
apt install -y apparmor apparmor-utils
```

Create a GRUB drop-in that enables AppArmor for all generated Linux boot entries:
```bash
mkdir -p /etc/default/grub.d

cat > /etc/default/grub.d/apparmor.cfg <<'EOF'
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX apparmor=1 security=apparmor"
EOF

update-grub
```

Loaded profiles should be in enforce mode rather than complain mode.

Inspect the current state, then place the installed profiles in enforce mode:
```bash
aa-status
aa-enforce /etc/apparmor.d/*
```

Enforcing profiles can expose missing policy rules and may prevent an application from starting or accessing required resources. Resolve profile violations in the lab before using the node template in another environment.

Reboot the system:
```bash
reboot
```

Verify that AppArmor is enabled and review the loaded profiles:
```bash
cat /sys/module/apparmor/parameters/enabled
aa-enabled
aa-status
```

The kernel parameter should return `Y`. The status output should show the intended profiles loaded in enforce mode, with no profiled processes unexpectedly unconfined.

For Kubernetes workloads, enabling AppArmor on the node is only the host prerequisite. Workload profiles still need to be available on the relevant nodes and selected through the Pod or container security context. We will work with AppArmor profiles in the last chapter.

---
## 6.2 Process Hardening
- **ASLR** randomizes process memory layout and makes memory-corruption exploits less predictable.
- **Restricted `ptrace`** limits one normal process from attaching to unrelated processes owned by the same user and reading or modifying their memory.
- **Core-dump restrictions** prevent crash data from retaining secrets such as tokens, passwords, SSH material, API keys, and process memory.

Create `/etc/sysctl.d/process-hardening.conf`:
```conf
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
```

Create `/etc/security/limits.d/core-dumps.conf`:
```conf
* hard core 0
```

Apply the sysctl settings:
```bash
sysctl --system
```

Configure systemd core-dump handling when `systemd-coredump` is installed:
```bash
cat > /etc/systemd/coredump.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
```

Verify the active kernel settings and the hard core-dump limit:
```bash
sysctl kernel.randomize_va_space
sysctl kernel.yama.ptrace_scope
sysctl fs.suid_dumpable
```

Expected sysctl values:
```text
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
```

Disabling core dumps reduces post-crash diagnostic information. Treat this as an intentional security-versus-troubleshooting decision for the hardened node baseline.

## 6.3 Network kernel parameters
Create `/etc/sysctl.d/net-hardening.conf`
```
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# Enable ipv4 forwarding for Kubernetes
net.ipv4.ip_forward = 1

# IPv6 forwarding remains disabled because this lab is IPv4-only.
net.ipv6.conf.all.forwarding = 0

# Disable packet redirect sending
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Ignore bogus ICMP error responses
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Ignore broadcast ICMP requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Do not accept ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Do not accept secure ICMP redirects
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Do not accept source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Enable TCP SYN cookies
net.ipv4.tcp_syncookies = 1

# Do not accept IPv6 router advertisements
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
```

Apply:
```
sysctl --system
```

Set the ownership and permissions:
```bash
chown root:root /etc/sysctl.d/net-hardening.conf && chmod 0644 /etc/sysctl.d/net-hardening.conf
```

Check the key decisions from this batch:
```bash
sysctl net.ipv4.ip_forward net.ipv4.conf.all.send_redirects net.ipv4.conf.all.rp_filter net.ipv4.tcp_syncookies net.ipv6.conf.all.disable_ipv6

ip -6 addr show scope global
```

The expected values are:
```text
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.disable_ipv6 = 1
```

There should be no meaningful global IPv6 address.