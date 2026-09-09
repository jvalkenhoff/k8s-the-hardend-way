## 13.1 Final check on `node01`

On `node01`:
```bash
systemctl is-active containerd
```

Expected:
```text
active
```

Then:
```bash
crictl info >/dev/null &&
  echo "CRI OK"
```

Expected:
```text
CRI OK
```

And:
```bash
swapon --show
```

Expected:
```text
No output
```

Also confirm the intended node IP:
```bash
ip -4 addr
```

We want:
```text
172.31.88.11
```


Check whether the API server is reachable from `node01`:
```bash
curl --max-time 3 -k https://172.31.88.10:6443/livez
```

An HTTP response proves the path is reachable.

The `-k` is acceptable for this **connectivity-only test**.

Kubeadm itself will not skip verification; it will use our CA hash in the actual join.

---
## 13.2 Update the Authentication Config
On `controlplane`, update `/etc/kubernetes/auth/authentication-config.yaml`:
```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AuthenticationConfiguration

anonymous:
  enabled: true
  conditions:
    - path: /livez
    - path: /readyz
    - path: /healthz
    - path: /api/v1/namespaces/kube-public/configmaps/cluster-info
```

Reboot the API server container. I'd simply stop its container:
```
APISERVER_ID="$(crictl ps --name kube-apiserver -q | head -n1)"
```

Confirm:
```
crictl inspect "${APISERVER_ID}" | grep -m1 kube-apiserver
```

Then:
```
crictl stop "${APISERVER_ID}"
```

---
## 13.3 Prepare JoingConfiguration
### 13.3.1 Create a short-lived bootstrap token
Create a token valid for two hours:
```bash
JOIN_TOKEN="$(kubeadm token create --ttl 2h --description "THEW node01 join")"
```

Confirm one exists without printing the secret itself:
```bash
kubeadm token list
```

Kubeadm bootstrap tokens normally support authentication and signing and have a default TTL of 24 hours, so we deliberately reduce ours to two hours.
### 13.3.2 Calculate the Kubernetes CA pin
Still on `controlplane`:
```bash
CA_HASH="$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | awk '{print $2}')"
```

Check only the length:
```bash
printf 'CA hash length: %s\n' "${#CA_HASH}"
```

Expected:
```text
CA hash length: 64
```

Kubeadm pins the SHA-256 hash of the CA certificate's Subject Public Key Info during discovery.

### 13.3.3 Transfer only the two bootstrap values
You now need these two values on `node01`:
```text
JOIN_TOKEN
CA_HASH
```

You can display them on `controlplane`:
```bash
printf 'JOIN_TOKEN=%s\n' "${JOIN_TOKEN}"
printf 'CA_HASH=%s\n' "${CA_HASH}"
```

On `node01`, set:
```bash
JOIN_TOKEN='<token>'
CA_HASH='<hash>'
```

### 13.3.4 Create the JoinConfiguration
On `node01`:
```bash
install -d -o root -g root -m 0700 /root/kubeadm
```

Create:
```bash
cat > /root/kubeadm/join-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration

discovery:
  bootstrapToken:
    apiServerEndpoint: 172.31.88.10:6443
    token: ${JOIN_TOKEN}
    caCertHashes:
      - sha256:${CA_HASH}

nodeRegistration:
  name: node01
  criSocket: unix:///run/containerd/containerd.sock

  kubeletExtraArgs:
    - name: node-ip
      value: 172.31.88.11
EOF
```

Protect it:
```bash
chown root:root /root/kubeadm/join-config.yaml && chmod 0600 /root/kubeadm/join-config.yaml
```

### 13.3.5 Validate
On `node01`:
```bash
kubeadm config validate --config /root/kubeadm/join-config.yaml
```

If validation succeeds, continue.

---

## 13.4 Join the cluster
### 13.4.1 Join The cluster
```bash
kubeadm join phase preflight --config /root/kubeadm/join-config.yaml
```

If there is a real preflight error, fix it.

Run:
```bash
kubeadm join --config /root/kubeadm/join-config.yaml
```

### 13.4.2 Check the node
Back on `controlplane`:
```bash
kubectl get nodes -o wide
```

Initially you may briefly see:
```text
node01     NotReady
```

while Calico initializes on the new node.

Then it should transition to:
```text
node01     Ready
```

Also:
```bash
kubectl get pods -A -o wide
```

You should eventually see a new:
```text
calico-node
kube-proxy
```

Pod scheduled on `node01`.

---
## 13.5 CSR approval
### 13.5.1 Check the CSR
On `controlplane`:
```bash
kubectl get csr
```

Find the pending CSR whose signer is:
```text
kubernetes.io/kubelet-serving
```

and which belongs to `node01`.

Set:

```bash
CSR='<CSR_NAME>'
```

Inspect its identity:

```bash
kubectl get csr "${CSR}" \
  -o jsonpath='Username: {.spec.username}{"\n"}Signer: {.spec.signerName}{"\n"}Usages: {.spec.usages}{"\n"}'
```

We want:
```text
Username: system:node:node01

Signer:
kubernetes.io/kubelet-serving

Usages:
digital signature
key encipherment
server auth
```

Check Kubernetes' view of the node:
```bash
kubectl get node node01 -o jsonpath='{range .status.addresses[*]}{.type}={.address}{"\n"}{end}'
```

Expected:
```text
InternalIP=172.31.88.11
Hostname=node01
```

Now decode the CSR:
```bash
kubectl get csr "${CSR}" -o jsonpath='{.spec.request}' | base64 -d | openssl req -noout -text
```

The requested SANs should correspond to:
```text
DNS:node01
IP Address:172.31.88.11
```

### 13.5.2 Approve the serving certificate
If the identity, signer, usage and SANs all match:
```bash
kubectl certificate approve "${CSR}"
```

Then:
```bash
kubectl get csr "${CSR}"
```

Expected:
```text
Approved,Issued
```

On `node01`, confirm that the kubelet installed it:
```bash
ls -l /var/lib/kubelet/pki/kubelet-server-current.pem
```

Then:
```bash
openssl x509 -in /var/lib/kubelet/pki/kubelet-server-current.pem -noout -subject -issuer -ext subjectAltName
```

We want the certificate to identify:
```text
node01
172.31.88.11
```

and be issued by our Kubernetes CA.
### 13.5.3 Prove API server → worker kubelet TLS
From `controlplane`, get the Calico Pod running on `node01`:
```bash
CALICO_NODE_POD="$(kubectl get pods -n calico-system -l k8s-app=calico-node --field-selector spec.nodeName=node01 -o jsonpath='{.items[0].metadata.name}')"

echo "${CALICO_NODE_POD}"
```

Then:
```bash
kubectl logs -n calico-system "${CALICO_NODE_POD}" -c calico-node --tail=5
```

If logs are returned: 
- the path from kubectl to container logs work.
- connection between api server and worker kubelet is secure

---

## 13.6 Final node state

Run:
```bash
kubectl get nodes -o wide
```

We want:
```text
controlplane    Ready    172.31.88.10
node01          Ready    172.31.88.11
```

And:
```bash
kubectl get pods -A -o wide
```

should show Calico and kube-proxy running on both nodes.

At this point, the cluster is basically ready. But we will, we will do some test cases before we wrap up
