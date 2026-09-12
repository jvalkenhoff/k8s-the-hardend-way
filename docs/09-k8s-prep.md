
> [!NOTE]
> This chapter is only on the `controlplane`


Install:
```
apt install socat conntrack ipset kmod -y
```
## 9.1 Verify basic kubeadm prerequisites
### Swap
```bash
swapon --show
```

Expected:
```text
No output
```

The default kubelet behavior is to fail when swap is enabled unless it is explicitly configured to tolerate swap. We are keeping swap disabled rather than weakening that behavior.

### IPv4 forwarding
```bash
sysctl net.ipv4.ip_forward
```

Expected:
```text
net.ipv4.ip_forward = 1
```

### Runtime
```bash
systemctl is-active containerd
```

Expected:
```text
active
```

---
## 9.2 Configure the Kubernetes signing key
Debian 12 already provides `/etc/apt/keyrings`, but create it normally if necessary:
```bash
install -d -o root -g root -m 0755 /etc/apt/keyrings
```

Install the Kubernetes repository signing key:
```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

Ensure the keyring is readable by APT:
```bash
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

The key URL and `signed-by` keyring model are the upstream Kubernetes v1.35 installation method.

---

## 9.3 Configure the k8s v1.35 repository
Create:
```bash
cat > /etc/apt/sources.list.d/kubernetes.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /
EOF
```

Protect it:
```bash
chown root:root /etc/apt/sources.list.d/kubernetes.list && chmod 0644 /etc/apt/sources.list.d/kubernetes.list
```

Update APT:
```bash
apt update
```

Confirm that the repository offers Kubernetes `1.35.8`:
```bash
apt-cache madison kubeadm kubelet kubectl
```

For this build, the expected Debian package version is:
```text
1.35.8-1.1
```

---
## 9.4 Install Kubernetes v1.35.8
Install `controlplane`
```bash
apt install -y cri-tools kubelet="1.35.8-1.1" kubeadm="1.35.8-1.1" kubectl="1.35.8-1.1"
```

Confirm the Kubernetes binaries:
```bash
kubeadm version
kubelet --version
kubectl version --client
```

The three Kubernetes binaries must report:
```text
v1.35.8
```

---
## 9.5 Runtime integration
Because we explicitly installed `cri-tools`, configure `crictl` on **both nodes**.

Create:
```bash
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
```

Protect it:
```bash
chown root:root /etc/crictl.yaml && chmod 0644 /etc/crictl.yaml
```

Then confirm the crictl binary:
```bash
crictl version
```

Must return:
```text
v2.3.5
```

---
## 9.6 firewall

### 9.6.1 Firewall rules
The nodes need inbound and outbound connections in order to allow kubelet, kube-apiserver and etcd.

For `controlplane`, add the following rules BEFORE any logging rule:
```
# ----------------------------------------------------------------------
# INPUT
# ----------------------------------------------------------------------

...

# Kubernetes API server
-A INPUT -s 172.31.88.0/28 -p tcp --dport 6443 -m conntrack --ctstate NEW -j ACCEPT

# Local etcd
-A INPUT -s 172.31.88.10/32 -p tcp -m multiport --dports 2379,2380 -m conntrack --ctstate NEW -j ACCEPT

# Kubelet API
-A INPUT -s 172.31.88.0/28 -p tcp --dport 10250 -m conntrack --ctstate NEW -j ACCEPT

# Typha INBOUND
-A INPUT -p tcp -s 172.31.88.11 -d 172.31.88.10 --dport 5473 -m conntrack --ctstate NEW -j ACCEPT

...

# ----------------------------------------------------------------------
# OUTPUT
# ----------------------------------------------------------------------

...

# Worker kubelets
-A OUTPUT -d 172.31.88.11/32 -p tcp --dport 10250 -m conntrack --ctstate NEW -j ACCEPT

# Local etcd
-A OUTPUT -d 172.31.88.10/32 -p tcp -m multiport --dports 2379,2380 -m conntrack --ctstate NEW -j ACCEPT

# Local API server
-A OUTPUT -d 172.31.88.10/32 -p tcp --dport 6443 -m conntrack --ctstate NEW -j ACCEPT

# Local kubelet
-A OUTPUT -d 172.31.88.10/32 -p tcp --dport 10250 -m conntrack --ctstate NEW -j ACCEPT

# Kubernetes host -> locally attached Calico workloads
#
# Required with OUTPUT DROP so kubelet can perform
# readiness/liveness/startup probes against local Pod IPs.
-A OUTPUT -o cali+ -d 10.244.0.0/16 -m conntrack --ctstate NEW -j ACCEPT

# Calico VXLAN - node01
-A OUTPUT -s 172.31.88.10/32 -d 172.31.88.11/32 -p udp --dport 4789 -m conntrack --ctstate NEW -j ACCEPT

# Calico WireGuard - node01
-A OUTPUT -s 172.31.88.10/32 -d 172.31.88.11/32 -p udp --dport 51820 -m conntrack --ctstate NEW -j ACCEPT

...
```

### 9.6.2 Save the firewall rules
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

### 9.6.3 Persist the firewall
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
