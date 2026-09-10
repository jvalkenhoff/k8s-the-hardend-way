## 14.1 Verify Encryption at Rest

### 14.1.1 Create a synthetic Secret
Use a deliberately recognizable test value:
```bash
kubectl create secret generic thew-encryption-test --namespace default --from-literal=marker='THEW_ENCRYPTION_TEST_VALUE'
```

Expected:
```text
secret/thew-encryption-test created
```

Check that the Kubernetes API can read it:
```bash
kubectl get secret thew-encryption-test --namespace default -o jsonpath='{.data.marker}' | base64 -d
```

Expected:
```text
THEW_ENCRYPTION_TEST_VALUE
```

This proves the API server can transparently decrypt the Secret.

### 14.1.2 Read the Secret directly from etcd
We now bypass the Kubernetes API server and query etcd itself.

Run:
```bash
kubectl exec \
  -n kube-system \
  etcd-controlplane \
  -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
    get /registry/secrets/default/thew-encryption-test \
  > /tmp/thew-encryption-test.raw
```

This path:
```text
/registry/secrets/default/thew-encryption-test
```

is the actual etcd key used for that Kubernetes Secret.

Kubernetes' own encryption-at-rest verification procedure recommends creating a Secret and then retrieving its raw value directly with `etcdctl`.
### 14.1.3 Prove the encryption prefix exists
Search the raw data:
```bash
grep -aF 'k8s:enc:secretbox:v1:' /tmp/thew-encryption-test.raw
```

You should see the encryption marker embedded in the binary data.

The important part is:
```text
k8s:enc:secretbox:v1:
```

Conceptually:
```text
etcd value

k8s:enc:secretbox:v1:key1:<ciphertext>
                 │
                 └── encrypted by our configured provider
```

Kubernetes uses an encryption marker in stored values so the API server knows which provider/key is required to decrypt the object. The Kubernetes documentation demonstrates the same verification method for its encryption providers.

### 14.1.4 Remove test data
The test is complete:
```bash
kubectl delete secret \
  thew-encryption-test \
  --namespace default
```

Remove our raw temporary copy:
```bash
rm -f /tmp/thew-encryption-test.raw
```

## 14.2 kubeconfigs
### 14.2.1 Inspection
We can inspect the embedded certificates without exposing their private keys.

For `admin.conf`:
```bash
kubectl config view \
  --kubeconfig=/etc/kubernetes/admin.conf \
  --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d \
  | openssl x509 -noout -subject
```

Expected identity:
```text
CN = kubernetes-admin
O = kubeadm:cluster-admins
```

Now inspect `super-admin.conf`:
```bash
kubectl config view \
  --kubeconfig=/etc/kubernetes/super-admin.conf \
  --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d \
  | openssl x509 -noout -subject
```

Expected:
```text
CN = kubernetes-super-admin
O = system:masters
```

### 14.2.2 Understand the difference
`admin.conf` is highly privileged:
```text
kubernetes-admin
        ↓
kubeadm:cluster-admins
        ↓
RBAC ClusterRoleBinding
        ↓
cluster-admin
```

But authorization still passes through Kubernetes RBAC.

`super-admin.conf` is different:
```text
kubernetes-super-admin
        ↓
system:masters
        ↓
authorization layer bypass
```

`system:masters` is a special break-glass group that bypasses normal authorization checks. Kubernetes explicitly warns against sharing this credential.

Therefore our operating rule is:
```text
admin.conf: root-only cluster administration

super-admin.conf: emergency / RBAC recovery only
```

---
## 14.3 PKI Lifecycle
### 14.3.1 kubeadm-managed certificates

Run:
```bash
kubeadm certs check-expiration
```

Kubeadm checks the certificates in its local PKI and the client certificates embedded in its generated kubeconfigs.

You should see certificates such as:

```text
admin.conf
super-admin.conf
apiserver
apiserver-etcd-client
apiserver-kubelet-client
controller-manager.conf
etcd-healthcheck-client
etcd-peer
etcd-server
front-proxy-client
scheduler.conf
```

and certificate authorities:

```text
ca
etcd-ca
front-proxy-ca
```

For a freshly initialized cluster, expect approximately:

```text
leaf certificates      ~1 year remaining
CA certificates         ~10 years remaining
```

Kubeadm v1beta4 defaults to:

```text
certificateValidityPeriod     8760h    = 1 year
caCertificateValidityPeriod   87600h   = 10 years
```

unless explicitly overridden.
### 14.3.2 Inspect the control-plane certificate relationships

Check a few representative certificates:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject -issuer -dates
```

Then:
```bash
openssl x509 -in /etc/kubernetes/pki/apiserver-etcd-client.crt -noout -subject -issuer -dates
```

And:
```bash
openssl x509 -in /etc/kubernetes/pki/front-proxy-client.crt -noout -subject -issuer -dates
```

The important relationships are:
```text
apiserver.crt
      ↓
Kubernetes CA


apiserver-etcd-client.crt
      ↓
etcd CA


front-proxy-client.crt
      ↓
front-proxy CA
```

### 14.3.3 Verify kubelet client certificate rotation
The kubelet is different from the control-plane certificates.

Check the current client certificate:
```bash
ls -l /var/lib/kubelet/pki/kubelet-client-current.pem
```

Then:
```bash
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -issuer -dates
```

The subject should identify the node:
```text
system:node:controlplane
```

Check how `kubelet.conf` references it:
```bash
grep -E 'client-certificate:|client-key:' /etc/kubernetes/kubelet.conf
```

Expected references include:
```text
/var/lib/kubelet/pki/kubelet-client-current.pem
```

Kubeadm intentionally excludes the kubelet client certificate from normal `kubeadm certs check-expiration` management because the kubelet rotates it automatically.

We already configured:
```yaml
rotateCertificates: true
```

so the lifecycle is:
```text
current certificate approaches expiration
                ↓
kubelet creates CSR
                ↓
controller approves valid client CSR
                ↓
new certificate issued
                ↓
kubelet switches certificate
```

Kubernetes normally starts this renewal while roughly 10–30% of the certificate lifetime remains.

No manual renewal is required during normal operation.

---

## 14.4 Verify kubelet serving-certificate lifecycle
Now inspect the certificate we manually approved earlier:
```bash
ls -l /var/lib/kubelet/pki/kubelet-server-current.pem
```

Then:
```bash
openssl x509 -in /var/lib/kubelet/pki/kubelet-server-current.pem -noout -subject -issuer -dates -ext subjectAltName
```

This certificate is also rotatable because we configured:
```yaml
serverTLSBootstrap: true
```

But there is one critical difference:

```text
CLIENT certificate CSR
        ↓
built-in approval possible


SERVING certificate CSR
        ↓
NO built-in automatic approval
```

Kubernetes deliberately does not automatically approve kubelet serving certificates because the requested IP/DNS SANs must be verified against the node.

Therefore future rotation looks like:

```text
kubelet serving certificate nears expiry
                ↓
new kubelet-serving CSR
                ↓
Pending
                ↓
operator verifies identity + SANs
                ↓
manual approval
                ↓
new certificate
```

---
## 14.5 Exposure and Live Endpoints
### 14.5.1 Inspect all listening TCP sockets
Run on `controlplane`:
```bash
ss -lntp
```

For a more focused view:
```bash
ss -lntp | grep -E ':(2379|2380|6443|10249|10250|10256|10257|10259)\b'
```

Do not remediate anything yet.

We first identify which endpoints are:
```text
loopback-only
node-network accessible
unexpected
```

### 14.5.2 Verify etcd rejects unauthenticated access
We can demonstrate that merely reaching etcd is insufficient.2
Try:
```bash
curl --cacert /etc/kubernetes/pki/etcd/ca.crt https://127.0.0.1:2379/health
```

Because we configured:
```text
--client-cert-auth=true
```

a request without a valid client certificate should fail rather than return normal etcd health data.

Now perform the authenticated request:
```bash
curl \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key /etc/kubernetes/pki/etcd/healthcheck-client.key \
  https://127.0.0.1:2379/health
```

Expected response contains:
```json
{"health":"true"}
```

The exact formatting may vary slightly.

This proves:
```text
network reachability
        ≠
etcd authorization
```

A valid etcd client certificate is required.

---

## NetworkPolicy
### Create a disposable test namespace

Because `controlplane` is still the only node and has the normal control-plane taint, our test Pods need a toleration.

Create:
```bash
cat > /root/calico/netpol-test.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: thew-netpol-test

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: server
  namespace: thew-netpol-test
spec:
  replicas: 1
  selector:
    matchLabels:
      role: server
  template:
    metadata:
      labels:
        role: server
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nginx
          image: nginx:1.29.1-alpine
          ports:
            - containerPort: 80

---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: thew-netpol-test
  labels:
    role: client
spec:
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  containers:
    - name: client
      image: busybox:1.37.0
      command:
        - sleep
        - "3600"
EOF
```

Apply:
```bash
kubectl apply -f /root/calico/netpol-test.yaml
```

Wait:
```bash
kubectl wait -n thew-netpol-test --for=condition=Ready pod --all --timeout=120s
```

### Prove the default is allow

Get the server IP:

```bash
SERVER_IP="$(kubectl get pod -n thew-netpol-test -l role=server -o jsonpath='{.items[0].status.podIP}')"

echo "${SERVER_IP}"
```

From the client:

```bash
kubectl exec -n thew-netpol-test client -- wget -T 3 -qO- "http://${SERVER_IP}"
```

You should receive the nginx page.

This demonstrates Kubernetes' default behavior:

```text
no NetworkPolicy selects Pod
        ↓
ingress allowed
egress allowed
```

CIS specifically warns that namespaces without NetworkPolicies effectively allow unrestricted Pod traffic.

### Apply default-deny

Create:
```bash
cat > /root/calico/default-deny.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: thew-netpol-test
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
EOF
```

Apply:
```bash
kubectl apply -f /root/calico/default-deny.yaml
```

This is the standard Kubernetes default-deny model for both ingress and egress.

Test again:

```bash
kubectl exec -n thew-netpol-test client -- wget -T 3 -qO- "http://${SERVER_IP}"
```

This time it should **time out / fail**.

That proves Calico is actually enforcing the policy rather than merely accepting the API object.

### Explicitly allow client → server
Now restore only the intended application path.

#### Server ingress
```bash
cat > /root/calico/allow-client-server.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-to-server
  namespace: thew-netpol-test
spec:
  podSelector:
    matchLabels:
      role: server
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: client
      ports:
        - protocol: TCP
          port: 80

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-egress-to-server
  namespace: thew-netpol-test
spec:
  podSelector:
    matchLabels:
      role: client
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              role: server
      ports:
        - protocol: TCP
          port: 80
EOF
```

Apply:

```bash
kubectl apply -f /root/calico/allow-client-server.yaml
```

Test:

```bash
kubectl exec -n thew-netpol-test client -- wget -T 3 -qO- "http://${SERVER_IP}"
```

The nginx page should work again.

The effective model is now:

```text
client
   │
   │ TCP/80
   ▼
server          ALLOWED


anything else
   │
   X
server          DENIED
```

### Explicitly allow DNS

Our default-deny also blocks DNS.

Create:
```bash
cat > /root/calico/allow-dns.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: thew-netpol-test
spec:
  podSelector:
    matchLabels:
      role: client
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF
```

Apply:

```bash
kubectl apply -f /root/calico/allow-dns.yaml
```

Test:

```bash
kubectl exec -n thew-netpol-test client -- nslookup kubernetes.default.svc.cluster.local
```

That should now succeed.

This illustrates an important default-deny lesson:

> DNS is egress too.

If you isolate workload egress without explicitly considering DNS, applications often appear to "randomly" break.

### Clean up the test

Once all three tests behaved correctly:

```bash
kubectl delete namespace thew-netpol-test
```

## Cross-node pod connectivity

On `controlplane`:
```bash
cat > /root/calico/cross-node-test.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: thew-network-test

---
apiVersion: v1
kind: Pod
metadata:
  name: pod-controlplane
  namespace: thew-network-test
spec:
  nodeSelector:
    kubernetes.io/hostname: controlplane
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  containers:
    - name: test
      image: busybox:1.37.0
      command: ["sleep", "3600"]

---
apiVersion: v1
kind: Pod
metadata:
  name: pod-node01
  namespace: thew-network-test
spec:
  nodeSelector:
    kubernetes.io/hostname: node01
  containers:
    - name: test
      image: busybox:1.37.0
      command: ["sleep", "3600"]
EOF
```

Apply:
```bash
kubectl apply -f /root/calico/cross-node-test.yaml
```

Wait:
```bash
kubectl wait -n thew-network-test --for=condition=Ready pod --all --timeout=120s
```

Check placement:
```bash
kubectl get pods -n thew-network-test -o wide
```

We specifically want:
```text
pod-controlplane    → controlplane
pod-node01          → node01
```

---

### Test

Get both addresses:
```bash
CP_POD_IP="$(kubectl get pod -n thew-network-test pod-controlplane -o jsonpath='{.status.podIP}')"

NODE01_POD_IP="$(kubectl get pod -n thew-network-test pod-node01 -o jsonpath='{.status.podIP}')"
```

Test control plane → worker:
```bash
kubectl exec -n thew-network-test pod-controlplane -- ping -c 4 "${NODE01_POD_IP}"
```

Then worker → control plane:
```bash
kubectl exec -n thew-network-test pod-node01 -- ping -c 4 "${CP_POD_IP}"
```

Both should succeed.

That proves:

```text
Calico IPAM              working
cross-node routing       working
FORWARD DROP integration working
```

### Inspect the WireGuard route

On `controlplane`:
```bash
ip route get "${NODE01_POD_IP}"
```

With WireGuard active between both nodes, the remote workload path should use:
```text
wireguard.cali
```

Check the reverse path on `node01` using the control-plane Pod IP:
```bash
ip route get "${CP_POD_IP}"
```

Again, we expect:
```text
wireguard.cali
```

Calico's default IPv4 WireGuard interface is `wireguard.cali`, and its default listening port is UDP `51820`.
### Clean up

Once verified:
```bash
kubectl delete namespace thew-network-test
```

Keep:
```text
/root/calico/cross-node-test.yaml
```

as a repeatable network validation test.
