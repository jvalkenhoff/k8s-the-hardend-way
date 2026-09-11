## 4.1 Login warnings and information disclosure
The default MOTD configuration may display unnecessary system information, including operating-system and kernel details. This baseline disables MOTD output and retains only explicit pre-authentication warning banners. The login information displayed is stored in different locations:
- `/etc/issue`
- `/etc/issue.net`
- `/etc/motd`
- `/etc/update-motd.d/10-uname`
- `/run/motd.dynamic`

The only ones we will keep are:
- `/etc/issue`
- `/etc/issue.net`

The only package we need here:
```
apt install libpam-pwquality -y
```

Remove the following:
``` 
rm -f /etc/motd
```

Apply this to the ones we keep:
```
cat > /etc/issue <<'EOF'
Authorized users only. All activity may be monitored and reported.
EOF
```


```
cat > /etc/issue.net <<'EOF'
Authorized users only. All activity may be monitored and reported.
EOF
```

Change ownership and permissions:
```
chown root:root /etc/issue /etc/issue.net && chmod 0644 /etc/issue /etc/issue.net
```

In `/etc/pam.d/login`, comment out the following lines:
```
...
# Print the message of the day upon successful login.
# This includes a dynamically generated part from /run/motd.dynamic
# and a static (admin-editable) part from /etc/motd.
# session    optional     pam_motd.so  motd=/run/motd.dynamic
# session    optional     pam_motd.so noupdate
....
```

Do the same for SSH logins.
In `/etc/pam.d/sshd`, comment out the following lines:
```
...
# Print the message of the day upon successful login.
# This includes a dynamically generated part from /run/motd.dynamic
# and a static (admin-editable) part from /etc/motd.
# session    optional     pam_motd.so  motd=/run/motd.dynamic
# session    optional     pam_motd.so noupdate
....
```
## 4.2 PAM setup

### 4.2.1 Installation
Run an initial PAM update:
```
pam-auth-update
```

A tty GUI will popup which asks to enable PAM profiles. Keep the default preselected PAM modules and just continue.
### 4.2.2 PAM profiles
Create PAM profiles
`faillock`:
```
cat > /usr/share/pam-configs/faillock <<'EOF'
Name: Enable pam_faillock to deny access
Default: yes
Priority: 0
Auth-Type: Primary
Auth:
 [default=die] pam_faillock.so authfail
EOF
```

`faillock`
```
cat > /usr/share/pam-configs/faillock_notify <<'EOF'
Name: Check account lockout before authentication
Default: yes
Priority: 1024
Auth-Type: Primary
Auth:
 required pam_faillock.so preauth
Account-Type: Primary
Account:
 required pam_faillock.so
EOF
```

`pwhistory`
```
cat > /usr/share/pam-configs/pwhistory <<'EOF'
Name: Pwhistory password history checking
Default: yes
Priority: 1024
Password-Type: Primary
Password:
 requisite pam_pwhistory.so remember=24 enforce_for_root use_authtok
EOF
```

`unix`
```
cat > /usr/share/pam-configs/unix <<'EOF'
Name: Unix authentication
Default: yes
Priority: 256
Auth-Type: Primary
Auth:
 [success=end default=ignore] pam_unix.so try_first_pass
Auth-Initial:
 [success=end default=ignore] pam_unix.so
Account-Type: Primary
Account:
 [success=end new_authtok_reqd=done default=ignore] pam_unix.so
Account-Initial:
 [success=end new_authtok_reqd=done default=ignore] pam_unix.so
Session-Type: Additional
Session:
 required pam_unix.so
Session-Initial:
 required pam_unix.so
Password-Type: Primary
Password:
 [success=end default=ignore] pam_unix.so obscure use_authtok try_first_pass yescrypt
Password-Initial:
 [success=end default=ignore] pam_unix.so obscure yescrypt
EOF
```

Make sure the permissions are set correctly:
```
chown root:root /usr/share/pam-configs/faillock /usr/share/pam-configs/faillock_notify /usr/share/pam-configs/pwhistory /usr/share/pam-configs/unix

chmod 644 /usr/share/pam-configs/faillock /usr/share/pam-configs/faillock_notify /usr/share/pam-configs/pwhistory /usr/share/pam-configs/unix
```

### 4.2.3 PAM policies
`faillock`
```
cat > /etc/security/faillock.conf <<'EOF'
deny = 5
fail_interval = 900
unlock_time = 900
silent
even_deny_root
root_unlock_time = 900
EOF
```

Make the main file passive, and put the active policy in one explicit file:
```
cat > /etc/security/pwquality.conf <<'EOF'  
# Active password quality policy is managed in: /etc/security/pwquality.conf.d/password-quality.conf  
EOF
```

Create the drop-in file
```
install -d -m 0755 -o root -g root /etc/security/pwquality.conf.d

cat > /etc/security/pwquality.conf.d/password-quality.conf <<'EOF'
# Require at least 2 characters changed from the old password.
difok = 2

# Minimum password length.
minlen = 14

# Require at least 3 character classes:
# lowercase, uppercase, digits, other.
minclass = 3

# Reject more than 3 same consecutive characters.
maxrepeat = 3

# Reject monotonic sequences longer than 3 characters.
maxsequence = 3

# Enable dictionary checking.
dictcheck = 1

# Enforce failed quality checks.
enforcing = 1

# Enforce quality checks for root as well.
enforce_for_root
EOF
```

Correct permissions:
```
chown root:root /etc/security/faillock.conf /etc/security/pwquality.conf /etc/security/pwquality.conf.d/password-quality.conf

chmod 0644 /etc/security/faillock.conf /etc/security/pwquality.conf /etc/security/pwquality.conf.d/password-quality.conf
```

### 4.2.4 PAM Update
Enable the profiles:
```
pam-auth-update --enable unix faillock faillock_notify pwquality pwhistory
```
## 4.3 Account Lifecycle
### 4.3.1 Account defaults and password aging
Replace the full file with this:
```
cat > /etc/login.defs <<'EOF'
# Mail
MAIL_DIR        /var/mail

# Logging
FAILLOG_ENAB           yes
LOG_UNKFAIL_ENAB       no
LOG_OK_LOGINS          no
SYSLOG_SU_ENAB         yes
SYSLOG_SG_ENAB         yes
FTMP_FILE              /var/log/btmp

# Login behavior
LOGIN_RETRIES          5
LOGIN_TIMEOUT          60
HUSHLOGIN_FILE         .hushlogin
DEFAULT_HOME           no

# Environment
ENV_SUPATH     PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV_PATH       PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games

# Terminal settings
TTYGROUP       tty
TTYPERM        0600
ERASECHAR      0177
KILLCHAR       025

# User/group ID ranges
UID_MIN                  1000
UID_MAX                 60000
SYS_UID_MIN               100
SYS_UID_MAX               999

GID_MIN                  1000
GID_MAX                 60000
SYS_GID_MIN               100
SYS_GID_MAX               999

# Subordinate ID ranges
SUB_UID_MIN             100000
SUB_UID_MAX          600100000
SUB_UID_COUNT            65536

SUB_GID_MIN             100000
SUB_GID_MAX          600100000
SUB_GID_COUNT            65536

# Password aging
PASS_MAX_DAYS             365
PASS_MIN_DAYS               1
PASS_WARN_AGE               7

# Password hashing
ENCRYPT_METHOD        SHA512

# Default permissions
UMASK                  027

# User/group behavior
USERGROUPS_ENAB       yes

# chfn restrictions
# r = room number, w = work phone, h = home phone
CHFN_RESTRICT         rwh
EOF
```

Set the permissions correctly:
```
chown root:root /etc/login.defs && chmod 0644 /etc/login.defs
```

Configure accounts to become inaccessible 45 days after password expiration if the password is not changed:
```
useradd -D -f 45
```

Apply the policy to existing users:
```bash
for user in root debian; do
  chage \
    --maxdays 365 \
    --mindays 1 \
    --warndays 7 \
    --inactive 45 \
    "$user"
done
```
This will also overwrite your current admin account, so be warned.

Then, check the root account password info:
```
passwd -S root
```

Should see something like:
```
root P 2026-05-13 1 365 7 45
```

The second field shows the root password state:
- `P`: root has a usable local password.
- `L`: the root password is locked.
- `NP`: root has no password.

Do not leave root with `NP`. Either reset the password of root:
```
passwd root
```

or explicitly lock password authentication:
```
passwd -l root
```
### 4.3.2 umask
Create an explicit file and source it:
```
cat > /root/.security-profile <<'EOF'
umask 027
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF

chmod 0600 /root/.security-profile
chown root:root /root/.security-profile
```

Add:
```
[ -f /root/.security-profile ] && . /root/.security-profile
```
to both `/root/.profile` and `/root/.bashrc`

Set correct permissions:
```
chmod 0600 /root/.security-profile && chown root:root /root/.security-profile
```

### 4.4.3 Shell configuration
`nologin` should not be listed in `/etc/shells`. if it is, remove it:
```bash
sed -i '\#nologin#d' /etc/shells
```

Set the correct ownership and permissions:
```bash
chown root:root /etc/shells && chmod 0644 /etc/shells
```

Create `/etc/profile.d/10-tmout.sh` to configure a 15-minute shell timeout:
```bash
cat > /etc/profile.d/10-tmout.sh <<'EOF'
TMOUT=900
readonly TMOUT
export TMOUT
EOF
```

Set the correct ownership and permissions:
```bash
chown root:root /etc/profile.d/10-tmout.sh && chmod 0644 /etc/profile.d/10-tmout.sh
```

Open a new SSH session and verify:
```bash
echo "$TMOUT"
```

Expected result:
```text
900
```

Bash closes an idle interactive shell after the configured number of seconds.
### 3.4.4 Configure the default user umask
Create a Debian PAM profile for `pam_umask`:
```bash
cat > /usr/share/pam-configs/umask <<'EOF'
Name: Apply default user umask
Default: yes
Priority: 1024
Session-Type: Additional
Session:
	optional pam_umask.so nousergroups
EOF
```

Enable the profile:
```bash
pam-auth-update --enable umask
```

Open a second SSH session before closing the current session and test:
```bash
umask
sudo -v
```

The `umask` command should return:
```text
0027
```

## 4.4 Configure controlled privilege escalation
Create a clean sudo policy in a temporary file:
```bash
cat > /root/sudoers.new <<'EOF'
Defaults env_reset
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Run elevated commands through a pseudo-terminal.
Defaults use_pty

# Record sudo activity in a dedicated log.
Defaults logfile="/var/log/sudo.log"

# Require re-authentication after no more than 15 minutes.
Defaults timestamp_timeout=15

root ALL=(ALL:ALL) ALL
%sudo ALL=(ALL:ALL) ALL

@includedir /etc/sudoers.d
EOF
```

This policy deliberately contains no `NOPASSWD` or `!authenticate` entries. Members of the `sudo` group must authenticate before receiving elevated privileges.

Validate the temporary file:
```bash
visudo -cf /root/sudoers.new
```

Install it only when validation succeeds:
```bash
install -o root -g root -m 0440 /root/sudoers.new /etc/sudoers

visudo -c
```

Create and protect the dedicated sudo log:
```bash
touch /var/log/sudo.log
chown root:root /var/log/sudo.log
chmod 0600 /var/log/sudo.log
```

From a second SSH session as `debian`, test it:
```bash
sudo -k
sudo whoami
```

The command should request the `debian` account password and return:
```text
root
```

Confirm that the event was logged:
```bash
sudo tail -n 5 /var/log/sudo.log
```

---
## 4.5 Restrict direct use of `su`

`sudo` provides command-level authorization and logging. `su` provides a less granular switch into another account, so normal users should not be allowed to use it.

Create an empty group:
```bash
groupadd -f sugroup
gpasswd -M "" sugroup
```

Add the PAM restriction if it is not already present:
```bash
grep -qxF \
  'auth required pam_wheel.so use_uid group=sugroup' \
  /etc/pam.d/su || \
  printf '%s\n' \
    'auth required pam_wheel.so use_uid group=sugroup' \
    >> /etc/pam.d/su
```

Confirm that the group has no members:
```bash
getent group sugroup
```

Expected pattern:
```text
sugroup:x:<gid>:
```

From a second session as `debian`, test the restriction:
```bash
su - root
```

The request should be denied. Administrative work should continue through `sudo`.

---
## 4.6 Protect account and password databases
The local account databases define users, password hashes, groups, valid shells, and password history. A normal user must not be able to modify them.

Apply root ownership to the public account files:
```bash
chown root:root \
  /etc/passwd \
  /etc/passwd- \
  /etc/group \
  /etc/group- \
  /etc/shells

chmod u-x,go-wx \
  /etc/passwd \
  /etc/passwd- \
  /etc/group \
  /etc/group- \
  /etc/shells
```

Keep Debian's normal `root:shadow` ownership model for the protected password databases:
```bash
chown root:shadow \
  /etc/shadow \
  /etc/shadow- \
  /etc/gshadow \
  /etc/gshadow-

chmod u-x,g-wx,o-rwx \
  /etc/shadow \
  /etc/shadow- \
  /etc/gshadow \
  /etc/gshadow-
```

Protect the PAM password-history files when they exist:
```bash
for file in /etc/security/opasswd /etc/security/opasswd.old; do
  if [ -e "$file" ]; then
    chown root:root "$file"
    chmod 0600 "$file"
  fi
done
```

## 4.7 Secure cron scheduling
Cron executes recurring tasks and may run scripts as root. The service remains available for approved maintenance and integrity checks, but its configuration must remain under root control.

### 4.7.1 enable cron
Enable the service:
```bash
systemctl unmask cron.service
systemctl enable --now cron.service
```

### 4.7.2 Protect the system cron locations
Apply root ownership:
```bash
chown root:root \
  /etc/crontab \
  /etc/cron.hourly \
  /etc/cron.daily \
  /etc/cron.weekly \
  /etc/cron.monthly \
  /etc/cron.d
```

Protect the system crontab:
```bash
chmod 0600 /etc/crontab
```

Protect the system scheduling directories:
```bash
chmod 0700 \
  /etc/cron.hourly \
  /etc/cron.daily \
  /etc/cron.weekly \
  /etc/cron.monthly \
  /etc/cron.d
```

These permissions do not stop cron from executing the approved jobs. The cron daemon runs as root and can still read the protected files and directories.

### 4.7.3 Restrict personal crontabs
Create an empty allow list:
```bash
install -o root -g crontab -m 0640 /dev/null /etc/cron.allow
```

Remove the redundant deny list:
```bash
rm -f /etc/cron.deny
```

With an empty `/etc/cron.allow`, normal users cannot create or modify personal crontabs. Root-managed jobs in `/etc/crontab`, `/etc/cron.d`, and the periodic cron directories continue to operate.

When an approved user genuinely requires a personal crontab, add that username as a separate line in `/etc/cron.allow`.
