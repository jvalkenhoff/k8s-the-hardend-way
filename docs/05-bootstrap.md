## 5.1 Protect GRUB boot parameters
Without authentication, a user with console access may edit a GRUB entry and add kernel parameters that bypass normal startup controls.

The goal is:
- Normal boot entries remain available without a password.
- Editing a boot entry requires GRUB authentication.
- Access to the GRUB command line requires GRUB authentication.
### 5.1.1 Create the GRUB administrator
Generate a password hash:
```bash
grub-mkpasswd-pbkdf2 --iteration-count=600000 --salt=64
```

Store the GRUB password in the password manager used for the lab.

Copy the complete hash beginning with:
```text
grub.pbkdf2.sha512
```

Create the GRUB user script:
```bash
cat > /etc/grub.d/01_users <<'EOF'
#!/bin/sh
exec tail -n +3 "$0"
set superusers="grubadmin"
password_pbkdf2 grubadmin grub.pbkdf2.sha512.REPLACE_WITH_YOUR_HASH
EOF
```

Replace:
```text
grub.pbkdf2.sha512.REPLACE_WITH_YOUR_HASH
```

with the generated hash.

Protect the script:
```bash
chown root:root /etc/grub.d/01_users && chmod 0700 /etc/grub.d/01_users
```

### 5.1.2 Keep normal boots unrestricted
When a GRUB superuser is configured, menu entries may also become restricted. Add `--unrestricted` to the normal Linux entries so the node can reboot unattended while entry editing remains protected.

Edit:
```bash
vim /etc/grub.d/10_linux
```

Find the `CLASS=` line. It normally resembles:
```text
CLASS="--class gnu-linux --class gnu --class os"
```

Add `--unrestricted`:
```text
CLASS="--class gnu-linux --class gnu --class os --unrestricted"
```

> [!IMPORTANT]
>  `/etc/grub.d/10_linux` belongs to the GRUB package. A GRUB package update may replace this modification. After updating GRUB, confirm that `--unrestricted` is still present before rebooting the node.

Generate the active configuration:
```bash
update-grub
```

Protect the generated GRUB configuration:
```bash
chown root:root /boot/grub/grub.cfg && chmod 0600 /boot/grub/grub.cfg
```

Confirm that the generated configuration contains the user, password hash, and unrestricted normal entries:
```bash
grep -E 'set superusers=|password_pbkdf2|--unrestricted' /boot/grub/grub.cfg
```

The output should include:
- `set superusers="grubadmin"`
- The `password_pbkdf2` entry
- `--unrestricted` on normal Linux menu entries

During the next console-accessible reboot:
1. Confirm that the default operating-system entry starts without a password.
2. Press `e` on a GRUB menu entry.
3. Confirm that GRUB requests the `grubadmin` credentials.
4. Cancel the edit and continue the normal boot.

## 5.2 Modprobe blacklist
### 5.2.1 Blacklist Network Modules
Create `/etc/modprobe.d/net-blacklist.conf`
```
install dccp /bin/false
blacklist dccp

install tipc /bin/false
blacklist tipc

install rds /bin/false
blacklist rds

install sctp /bin/false
blacklist sctp
```

Set the ownership and permissions:
```bash
chown root:root /etc/modprobe.d/net-blacklist.conf && chmod 0644 /etc/modprobe.d/net-blacklist.conf
```

Unload them if any are active:
```
for module in dccp tipc rds sctp; do modprobe -r "$module" 2>/dev/null; done
```

Confirm that each module is not loadable:
```bash
for module in dccp tipc rds sctp; do
  echo "### $module"
  modprobe -n -v "$module"
done
```

Each module should resolve to an `install /bin/false` action.

Confirm that none of the modules are loaded:
```bash
lsmod | awk '{print $1}' | grep -E '^(dccp|tipc|rds|sctp)$'
```

No output is expected.

> [!NOTE]
> SCTP could be used by CNI if the CNI plugin supports this. In most cases you probably won't need it but it's good to know that Kubernetes might use it in some cases. 

### 5.2.2 Filesystem blacklist
Most of them are already disabled, but it is neat to disable filesystems on a blacklist.
Create the following blacklist `/etc/modprobe.d/fs-blacklist.conf`:
```
install cramfs /bin/false
blacklist cramfs

install freevxfs /bin/false
blacklist freevxfs

install hfs /bin/false
blacklist hfs

install hfsplus /bin/false
blacklist hfsplus

install jffs2 /bin/false
blacklist jffs2

install udf /bin/false
blacklist udf
```

### 5.2.3 Enable network modules
We also need to enable some network modules. This is required during the CNI section, which happens much later.
Create the following modprobe loading list `/etc/modules.load.d/net-load.conf`:
```
cat > /etc/modules-load.d/net-load.conf <<'EOF'
vxlan
wireguard
nf_conntrack
ip_set
xt_set
xt_conntrack
xt_comment
xt_addrtype
xt_mark
xt_multiport
ipt_rpfilter
EOF
```

Protect it:
```
chown root:root /etc/modules-load.d/net-load.conf && chmod 0644 /etc/modules-load.d/net-load.conf
```

We can reboot the system, or load them immediately:
```
for module in \
  vxlan \
  wireguard \
  nf_conntrack \
  ip_set \
  xt_set \
  xt_conntrack \
  xt_comment \
  xt_addrtype \
  xt_mark \
  xt_multiport \
  ipt_rpfilter
do
  modprobe "${module}" || exit 1
done
```
