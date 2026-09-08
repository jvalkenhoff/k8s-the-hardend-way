## 3.1 Network Cutover
Install:
Install:
```
DEBIAN_FRONTEND=noninteractive apt install -y iptables iptables-persistent netfilter-persistent systemd-resolved dnsutils -y
```
### 3.1.1 Configure `systemd-networkd`
make sure the following folder exists:
```
mkdir -p /etc/systemd/network
```

Create a `.network` file for each of the node's primary interface. you can check this with:
```
ip addr show
```

Look for the NIC with the correct IP:
```
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host noprefixroute
       valid_lft forever preferred_lft forever
2: ens32: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 00:0c:29:53:03:59 brd ff:ff:ff:ff:ff:ff
    altname enp2s0
    inet 172.31.88.10/28 brd 172.31.88.15 scope global ens32
       valid_lft forever preferred_lft forever
    inet6 fe80::20c:29ff:fe53:359/64 scope link
       valid_lft forever preferred_lft forever
```

In this case, it is `ens32`. So you would create `/etc/systemd/network/ens32.network`

**controlplane**
```ini
[Match]
Name=ens32

[Network]
DHCP=no
Address=172.31.88.10/28
Gateway=172.31.88.2
DNS=172.31.88.2
```

**node01**
```ini
[Match]
Name=ens32

[Network]
DHCP=no
Address=172.31.88.11/28  
Gateway=172.31.88.2  
DNS=172.31.88.2
```

Enable `systemd-networkd`:
```
systemctl enable --now systemd-networkd
```

---
### 3.1.2 Configure  `systemd-resolved`
```
mkdir -p /etc/systemd/resolved.conf.d
```

Create a `.conf` file for all the nodes. This file will be the same across all nodes. Create `/etc/systemd/resolved.conf.d/dns_servers.conf`
```ini
[Resolve]
DNS=172.31.88.2
Domains=k8s.local
DNSSEC=no
DNSStubListener=yes
LLMNR=no
MulticastDNS=no
```

Enable `systemd-resolved`:
```
systemctl enable --now systemd-resolved
```

> [!NOTE]
> Disabling LLMNR is important because it opens a port on all interfaces. For personal use this is fine, for a hardened server it should be turned off. You can check with `ss -plntu`. At this stage, you should see no other ports open other than 53 and 22.

### 3.1.3 Neutralize ifupdown
Don't turn it off yet. This comments out the current config for `ifupdown`. This prevents loading the config on reboot.
```
sed -i 's/^/#/' /etc/network/interfaces 
```

Do **not** run `ifdown`.

Perform a reboot
```
reboot
```

Why reboot?
- `ifupdown` never comes up
- `networkd` takes over

After the reboot, SSH back into the Node. Stop and disable the traditional Debian networking and NetworkManager:
```
systemctl disable networking || true
systemctl disable NetworkManager || true
```
### 3.1.4 Verify
Inside the VM:
```
networkctl status ens32
```

Look for these lines:
```
Network File: /etc/systemd/network/10-ens32.network
State: routable (configured)
Online state: online
Address: 172.31.88.10
Gateway: 172.31.88.2
DNS: 172.31.88.2
```

```
resolvectl status
```

Should output:
```
Link 2 (enp1s0)
    Current Scopes: DNS LLMNR/IPv4 LLMNR/IPv6
         Protocols: +DefaultRoute -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 172.31.88.2
       DNS Servers: 172.31.88.2
```

From your the host system, check ping:
```
ping <node-ip>
```

From each node itself, verify:
```
ping -c 3 172.31.88.1
ping -c 3 172.31.88.2
ping -c 3 deb.debian.org
curl -I https://deb.debian.org
resolvectl query deb.debian.org
```

Check that DNS resolution works:
```
dig google.com @127.0.0.53
```

If this fails, double-check `/etc/resolv.conf` and `systemd-resolved` status:
```
systemctl status systemd-resolved
```

---
## 3.4 Host Firewall
### 3.4.1 firewall rules
#### controlplane
Create `/root/iptables.v4`
```
*filter

:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]

# ----------------------------------------------------------------------
# INPUT
# ----------------------------------------------------------------------

# Loopback
-A INPUT -i lo -j ACCEPT
-A INPUT -s 127.0.0.0/8 ! -i lo -j DROP

# Connection tracking
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# ICMP
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/sec --limit-burst 10 -j ACCEPT

# SSH from admin host
-A INPUT -s 172.31.88.1/32 -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

# Log anything that reaches the default DROP policy
-A INPUT -m limit --limit 10/min --limit-burst 20 -j LOG --log-prefix "DROP_CP_IN: "


# ----------------------------------------------------------------------
# FORWARD
# ----------------------------------------------------------------------

-A FORWARD -m conntrack --ctstate INVALID -j DROP
-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

-A FORWARD -m limit --limit 10/min --limit-burst 20 -j LOG --log-prefix "DROP_CP_FWD: "


# ----------------------------------------------------------------------
# OUTPUT
# ----------------------------------------------------------------------

# Loopback
-A OUTPUT -o lo -j ACCEPT

# Connection tracking
-A OUTPUT -m conntrack --ctstate INVALID -j DROP
-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# ICMP
-A OUTPUT -p icmp -j ACCEPT

# DNS
-A OUTPUT -p udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
-A OUTPUT -p tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT

# NTP
-A OUTPUT -p udp --dport 123 -m conntrack --ctstate NEW -j ACCEPT

# HTTPS
-A OUTPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT

# Log anything that reaches the default DROP policy
-A OUTPUT -m limit --limit 10/min --limit-burst 20 -j LOG --log-prefix "DROP_CP_OUT: "

COMMIT
```

#### node01
Create `/root/iptables.v4`
```
*filter

:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]

# ----------------------------------------------------------------------
# INPUT
# ----------------------------------------------------------------------

# Loopback
-A INPUT -i lo -j ACCEPT
-A INPUT -s 127.0.0.0/8 ! -i lo -j DROP

# Connection tracking
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# ICMP
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/sec --limit-burst 10 -j ACCEPT

# SSH from admin host
-A INPUT -s 172.31.88.1/32 -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

# Log anything that reaches the default DROP policy
-A INPUT -m limit --limit 10/min --limit-burst 20 -j LOG --log-prefix "DROP_WK_IN: "


# ----------------------------------------------------------------------
# FORWARD
# ----------------------------------------------------------------------

-A FORWARD -m conntrack --ctstate INVALID -j DROP
-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

-A FORWARD -m limit --limit 10/min --limit-burst 20 -j LOG --log-prefix "DROP_WK_FWD: "


# ----------------------------------------------------------------------
# OUTPUT
# ----------------------------------------------------------------------

# Loopback
-A OUTPUT -o lo -j ACCEPT

# Connection tracking
-A OUTPUT -m conntrack --ctstate INVALID -j DROP
-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# ICMP
-A OUTPUT -p icmp -j ACCEPT

# DNS
-A OUTPUT -p udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
-A OUTPUT -p tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT

# NTP
-A OUTPUT -p udp --dport 123 -m conntrack --ctstate NEW -j ACCEPT

# HTTPS
-A OUTPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT

# Log anything that reaches the default DROP policy
-A OUTPUT -m limit --limit 10/min --limit-burst 20 -j LOG --log-prefix "DROP_WK_OUT: "

COMMIT
```

Set ownership and permissions:
```bash
chown root:root /root/iptables.v4 && chmod 0600 /root/iptables.v4
```

### 3.4.2 Save the firewall rules
Perform a dry run test:
```
iptables-restore --test < /root/iptables.v4
```

if it gives no errors, you can apply the rules:
```
iptables-restore < /root/iptables.v4
```

Review the active policies and rules:
```bash
iptables -S
iptables -L -n -v
```

The default policies for `INPUT`, `FORWARD`, and `OUTPUT` should be `DROP`.

### 3.4.3 Persist the firewall
After applying, run this:
```
iptables-save > /etc/iptables/rules.v4
netfilter-persistent save
```

You can then reload the system:
```
systemctl restart netfilter-persistent
```

Check the firewall again after the reload:
```bash
iptables -S
```
### 3.4.4 Connectivity and open-port check
Check the applied rules with:
```
iptables -S  
iptables -L -n -v
```

Test if there is still connection:
```
apt update  
chronyc tracking  
resolvectl query debian.org  
curl -I https://deb.debian.org
```

The eventual worker baseline should account for:
- SSH on port `22` from `172.31.88.1` only.
- DNS, NTP, and approved HTTPS destinations.