
> [!NOTE]
> This chapter is only on the `controlplane`
## 11.1 Preflight checks
Run:
```bash
kubeadm init phase preflight --config /tmp/kubeadm-init.yaml
```

The preflight check may error on the fact that `/var/lib/etcd` is not empty. Contains most likely `lost+found`. Remove it:
```
if [ -d /var/lib/etcd/lost+found ]; then rmdir /var/lib/etcd/lost+found fi
```
## 11.2 Pre-pull the control-plane images
Before modifying the node, pull everything kubeadm requires:
```bash
kubeadm config images pull --config /tmp/kubeadm-init.yaml
```

Afterward:
```bash
crictl images
```

You should see images for components such as:
```text
kube-apiserver
kube-controller-manager
kube-scheduler
kube-proxy
etcd
coredns
pause
```

## 11.3 Bootstrap the control plane
If both previous steps succeed, run:
```bash
kubeadm init --config /tmp/kubeadm-init.yaml
```

Near the end you should get something similar to:
```text
Your Kubernetes control-plane has initialized successfully!
```

At this moment it is normal for the control-plane node to be:
```text
NotReady
```


After successful initialization, you can check the current containers:
```bash
crictl ps
```

We want to see the control-plane containers:
```text
etcd
kube-apiserver
kube-controller-manager
kube-scheduler
```

Some containers may restart a few times, but they should settle into `Running`.

---
## 11.4 Kubeconfig
### 11.4.1 Add to config
Configure the current user's kubeconfig normally:
```
mkdir -p "$HOME/.kube"
cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

Verify access:
```bash
kubectl version
```

Then:
```bash
kubectl get nodes -o wide
```

At this stage `controlplane` may still show:
```text
NotReady
```

because no CNI has been installed yet.

Check the Kubernetes system Pods:
```bash
kubectl get pods -n kube-system -o wide
```

The important control-plane Pods should be running:
```text
etcd-controlplane
kube-apiserver-controlplane
kube-controller-manager-controlplane
kube-scheduler-controlplane
```

CoreDNS may remain `Pending` until cluster networking exists.

### 11.4.2 Alias
Set `kubectl` alias in `~/.bashrc`
```
alias k='kubectl'
```

Reload bash:
```
source ~/.bashrc
```

check if it works:
```
k get nodes -o wide
```

### 11.4.3 vimrc
Make sure vimrc config is set to support yaml files. Create `~/.vimrc`:
```
" Enable syntax highlighting
syntax on

" Detect file types
filetype plugin indent on

" Kubernetes / YAML indentation
autocmd FileType yaml setlocal expandtab
autocmd FileType yaml setlocal shiftwidth=2
autocmd FileType yaml setlocal softtabstop=2
autocmd FileType yaml setlocal tabstop=2
autocmd FileType yaml setlocal autoindent
```



---
## 11.5 Validate and Trust the Kubelet Serving Certificate

We already configured:
```yaml
serverTLSBootstrap: true
```

The kubelet should therefore have requested a CA-signed **serving certificate**.

List CSRs:
```bash
kubectl get csr
```

Look specifically for a CSR with:
```text
SIGNERNAME
kubernetes.io/kubelet-serving
```

If there are multiple, grab the latest:
```
kubectl get csr --sort-by=.metadata.creationTimestamp
```

```
KUBELET_CSR=$(kubectl get csr --sort-by=.metadata.creationTimestamp --no-headers | tail -1 | awk '{print $1}')
```
### 11.5.1 Verify who requested it
Run:
```bash
kubectl get csr $KUBELET_CSR -o jsonpath='{.spec.request}' | base64 -d | openssl req -noout -text
```

You want to see:
```text
Subject:
    CN = system:node:controlplane
    O = system:nodes

Subject Alternative Name:
    DNS:controlplane
    IP Address:172.31.88.10
```

Run:
```bash
kubectl get csr $KUBELET_CSR -oyaml
```

The important properties are:
```text
identity      system:node:controlplane
group         system:nodes
signer        kubernetes.io/kubelet-serving
usage         server auth
```

### 11.5.2 Approve the CSR
Only after those checks succeed:
```bash
kubectl certificate approve $KUBELET_CSR
```

Then:
```bash
kubectl get csr $KUBELET_CSR
```

Expected:
```text
Approved,Issued
```

The kubelet should retrieve the certificate automatically.

### 11.5.3 Verify the kubelet received its serving certificate
Check:
```bash
ls -l /var/lib/kubelet/pki/kubelet-server-current.pem
```

You should see a current serving certificate/symlink appear.

Inspect it:
```bash
openssl x509 -in /var/lib/kubelet/pki/kubelet-server-current.pem -noout -subject -issuer -ext subjectAltName -ext extendedKeyUsage
```

We want to see the Kubernetes CA as issuer and identities belonging to this node (`controlplane` or `node01`).

---
## 11.6 Add kubelet CA verification to kubeadm configuration
### 11.6.1 Update kubeadm config
Now that a valid serving certificate exists, we can safely enable API-server verification.

Edit:
```bash
nano /etc/kubernetes/config/kubeadm-config.yaml
```

Inside the existing:
```yaml
apiServer:
  extraArgs:
```

add:
```yaml
    - name: kubelet-certificate-authority
      value: "/etc/kubernetes/pki/ca.crt"
```

Do not add another volume.

Kubeadm already mounts:
```text
/etc/kubernetes/pki
```

into the API-server Pod.
### 11.6.2 Validate before applying
Assemble again:
```bash
{
    cat /etc/kubernetes/config/kubeadm-config.yaml
    printf '\n---\n'
    cat /etc/kubernetes/config/kubelet-config.yaml
    printf '\n---\n'
    cat /etc/kubernetes/config/kube-proxy-config.yaml
} > /tmp/kubeadm-init.yaml
```

Permissions:
```bash
chown root:root /tmp/kubeadm-init.yaml && chmod 0600 /tmp/kubeadm-init.yaml
```

Validate it:
```bash
kubeadm config validate --config /tmp/kubeadm-init.yaml
```

### 11.6.3 Update kubeadm's stored ClusterConfiguration
The local YAML is our installation source, but kubeadm also stores its `ClusterConfiguration` inside:
```text
kube-system/kubeadm-config
```

That stored configuration is used by later operations such as upgrades.

Upload our updated configuration:
```bash
kubeadm init phase upload-config kubeadm --config /tmp/kubeadm-init.yaml --kubeconfig /etc/kubernetes/admin.conf
```

This is important: otherwise we could harden the live manifest while leaving kubeadm's persistent configuration unaware of the change.

### 11.6.4 Regenerate only the API-server manifest
Rather than manually editing the generated static Pod, let kubeadm regenerate it from our hardened configuration:
```bash
kubeadm init phase control-plane apiserver --config /tmp/kubeadm-init.yaml
```

Because:
```text
/etc/kubernetes/manifests/kube-apiserver.yaml
```

changes, the kubelet will automatically restart the API-server static Pod.
### 11.6.5 Wait for the API server
After several seconds:
```bash
crictl ps | grep kube-apiserver
```

Then:
```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw='/readyz'
```

Expected:
```text
ok
```
