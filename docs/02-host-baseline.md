## 2.1 Base Install

### 2.1.1 Add Packages
On each VM, install base packages:
```
apt update && 
apt install -y bash-completion ca-certificates chrony cron curl debian-archive-keyring dnsutils gpg kmod sudo vim wget
```

### 2.1 Remove packages
A Kubernetes node should not also operate as a DNS server, DHCP server, mail server, file server, print server, proxy, web server, or network-discovery service.

remove the packages:
```bash
apt purge -y \
  autofs \
  avahi-daemon \
  isc-dhcp-server \
  bind9 \
  dnsmasq \
  vsftpd \
  slapd \
  dovecot-imapd \
  dovecot-pop3d \
  nfs-kernel-server \
  ypserv \
  cups \
  samba \
  snmpd \
  tftpd-hpa \
  squid \
  apache2 \
  nginx \
  xinetd \
  postfix \
  exim4 \
  exim4-base \
  exim4-config \
  exim4-daemon-light \
  exim4-daemon-heavy \
  sendmail-bin \
  nis \
  rsh-client \
  talk \
  telnet \
  inetutils-telnet \
  ftp \
  tnftp
```

Start open-vm-tools:
```
systemctl enable --now open-vm-tools
```

---
## 2.3 Admin 
Add `debian` to the `sudo` group:
```
usermod -aG sudo debian
```

---
## 2.4 SSH Remote access
### 2.4.1 Admin user
Create ssh group, Add `debian` to the `ssh-login` group:
```
groupadd -f ssh-login
usermod -aG ssh-login debian
```

### 2.4.2 SSH Keys
Create `.ssh` directory:
```
install -d -m 700 -o debian -g debian /home/debian/.ssh
```

If `/home/debian/.ssh/authorized_keys` already exists:
```
chown debian:debian /home/debian/.ssh/authorized_keys && chmod 0600 /home/debian/.ssh/authorized_keys
```

if not:
```
install -m 0600 -o debian -g debian /dev/null /home/debian/.ssh/authorized_keys
```

### 2.4.3 sshd_config
Create the sshd_config drop-in file:
```
cat > /etc/ssh/sshd_config.d/10-sshd_dropin.conf <<'EOF'
# Connection and logging
LoginGraceTime 60
LogLevel VERBOSE
MaxAuthTries 4
MaxStartups 10:30:60

# Access
PermitRootLogin no
AllowGroups ssh-login

# Authentication
AuthenticationMethods publickey
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
HostbasedAuthentication no
GSSAPIAuthentication no
PermitEmptyPasswords no
UsePAM yes

# Cryptographic policy
Ciphers -3des-cbc,aes128-cbc,aes192-cbc,aes256-cbc
KexAlgorithms -diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1
MACs -hmac-md5*,hmac-sha1*,umac-64*

# Forwarding and environment
DisableForwarding yes
PermitUserEnvironment no
PermitTunnel no

# Dead connection detection
ClientAliveInterval 15
ClientAliveCountMax 3

# Information disclosure
DebianBanner no
Banner /etc/issue.net
PrintMotd no
EOF
```

Set permissions:
```bash
chown root:root /etc/ssh/sshd_config.d/10-sshd_dropin.conf && chmod 0600 /etc/ssh/sshd_config.d/10-sshd_dropin.conf
```

Validate and reload:
```
sshd -t && systemctl reload ssh.service
```

---
## 2.5 Repository configuration
Disable the older `sources.list` when it exists:
```bash
mv /etc/apt/sources.list /etc/apt/sources.list.disabled
```

Create `/etc/apt/sources.list.d/debian.sources`:
```bash
cat > /etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: bookworm-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
```

Protect the file and refresh the metadata:
```bash
chown root:root /etc/apt/sources.list.d/debian.sources && chmod 0644 /etc/apt/sources.list.d/debian.sources
```

Perform an update check:
```
apt update
```

A Kubernetes repository may be added later when it is intentional and uses its own scoped `Signed-By` keyring.

---
## 2.6 Configure time synchronization
Accurate time supports log correlation, certificate validity, authentication records, sudo evidence, and cluster troubleshooting.
This baseline uses Chrony as the only time-synchronization daemon.

Disable `systemd-timesyncd` when it is available:
```bash
systemctl disable --now systemd-timesyncd.service

systemctl mask systemd-timesyncd.service
```

Replace `/etc/chrony/chrony.conf`:
```bash
cat > /etc/chrony/chrony.conf <<'EOF'
# Public source for the lab.
# Replace this with approved internal NTP servers in production.
pool nl.pool.ntp.org iburst maxsources 4

driftfile /var/lib/chrony/chrony.drift

# Correct a large offset during the first three updates.
makestep 1.0 3

# Periodically synchronize the hardware clock.
rtcsync

# This node is an NTP client, not an NTP server.
port 0

# Disable the network command port.
# Local chronyc access continues through the Unix socket.
cmdport 0

logdir /var/log/chrony
EOF
```

Protect the configuration:
```bash
chown root:root /etc/chrony/chrony.con && chmod 0644 /etc/chrony/chrony.conf
```

Enable Chrony:
```bash
systemctl unmask chrony.service
systemctl enable --now chrony.service
```

Confirm that a source is selected:
```bash
chronyc tracking
chronyc sources -v
```

The selected source is marked with `^*`. The offset should settle after Chrony has completed several updates.

---
## 2.7 fstab replacement
Replace the `/etc/fstab`:
```c
# Root filesystem
/dev/mapper/vg0-lv_root              /                ext4    errors=remount-ro                                      0       1

# Boot filesystems
UUID=f553e622-968d-430c-8c0e-a4d23c5b3631  /boot      ext4    defaults                                               0       2
UUID=6FBE-0064                       /boot/efi        vfat    umask=0077                                             0       1

# Kubernetes-aware separate filesystems
/dev/mapper/vg0-lv_home              /home            ext4    defaults,rw,nosuid,nodev,relatime                     0       2
/dev/mapper/vg0-lv_var               /var             ext4    defaults,rw,nosuid,nodev,relatime                     0       2
/dev/mapper/vg0-lv_var_lib_etcd      /var/lib/etcd    ext4    defaults,rw,nosuid,nodev,relatime                     0       2
/dev/mapper/vg0-lv_var_tmp           /var/tmp         ext4    defaults,rw,nosuid,nodev,noexec,relatime              0       2
/dev/mapper/vg0-lv_var_log           /var/log         ext4    defaults,rw,nosuid,nodev,noexec,relatime              0       2
/dev/mapper/vg0-lv_var_log_audit     /var/log/audit   ext4    defaults,rw,nosuid,nodev,noexec,relatime              0       2

# Only add this on the Control Plane
/dev/mapper/vg0-lv_var_lib_containerd  /var/lib/containerd  ext4  defaults,rw,nosuid,nodev,relatime  0  2

# Temporary filesystems
tmpfs                                /tmp             tmpfs   defaults,rw,nosuid,nodev,noexec,relatime,size=2G,mode=1777  0  0
tmpfs                                /dev/shm         tmpfs   defaults,rw,nosuid,nodev,noexec,relatime,size=2G,mode=1777  0  0
```

Replace the `/boot` and `/boot/efi` UUIDs with the values from the target system, and confirm that every LVM device path matches an existing logical volume. Omit the `/var/lib/etcd` entry on worker nodes that do not host local etcd.

The `size=2G` value is a fixed example. Confirm that it is appropriate for the node's available memory and workload before applying it.

Validate the configuration:
```bash
systemctl daemon-reload
findmnt --verify --verbose
```

Do not reboot until `findmnt --verify --verbose` completes without errors.