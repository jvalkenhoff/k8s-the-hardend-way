# 14 Post-install checks

This chapter validates the completed two-node cluster:

```text
controlplane    control-plane node
node01          worker node
```

Unless stated otherwise, run `kubectl` commands from `controlplane`. Run node-local commands on the node specified in each section.

## 14.1 Verify encryption at rest

Create a Secret with a recognizable value:

```bash
kubectl create secret generic thew-encryption-test \
  --namespace default \
  --from-literal=marker='THEW_ENCRYPTION_TEST_VALUE'
```

Confirm that the API server can read and transparently decrypt it:

```bash
kubectl get secret thew-encryption-test \
  --namespace default \
  -o jsonpath='{.data.marker}' \
  | base64 -d
```

Expected:

```text
THEW_ENCRYPTION_TEST_VALUE
```

Now bypass the API server and read the raw value from etcd:

```bash
kubectl exec -n kube-system etcd-controlplane -- \
  etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
    get /registry/secrets/default/thew-encryption-test \
  > /tmp/thew-encryption-test.raw

grep -aF 'k8s:enc:secretbox:v1:' /tmp/thew-encryption-test.raw
```

The raw value should contain:

```text
k8s:enc:secretbox:v1:
```

This confirms that etcd stores the Secret with the configured `secretbox` encryption provider rather than as plaintext.

Clean up:

```bash
kubectl delete secret thew-encryption-test --namespace default
rm -f /tmp/thew-encryption-test.raw
```

## 14.2 Verify kubeconfig identities

Inspect the client identities embedded in the administrative kubeconfigs:

```bash
for kubeconfig in admin.conf super-admin.conf; do
  echo "${kubeconfig}:"
  kubectl config view \
    --kubeconfig="/etc/kubernetes/${kubeconfig}" \
    --raw \
    -o jsonpath='{.users[0].user.client-certificate-data}' \
    | base64 -d \
    | openssl x509 -noout -subject
done
```

Expected identities:

```text
admin.conf:       CN = kubernetes-admin, O = kubeadm:cluster-admins
super-admin.conf: CN = kubernetes-super-admin, O = system:masters
```

`admin.conf` receives `cluster-admin` privileges through RBAC. `super-admin.conf` belongs to the special `system:masters` group, which bypasses normal authorization checks.

```text
admin.conf         root-only cluster administration
super-admin.conf   emergency RBAC recovery only
```

## 14.3 Verify the PKI lifecycle

### 14.3.1 Kubeadm-managed certificates

Run on `controlplane`:

```bash
kubeadm certs check-expiration
```

For a newly initialized cluster, expect approximately:

```text
leaf certificates    1 year
CA certificates      10 years
```

These are the kubeadm v1beta4 defaults unless `certificateValidityPeriod` or `caCertificateValidityPeriod` was overridden.

Inspect representative certificate chains:

```bash
for certificate in \
  apiserver.crt \
  apiserver-etcd-client.crt \
  front-proxy-client.crt
do
  echo "${certificate}:"
  openssl x509 \
    -in "/etc/kubernetes/pki/${certificate}" \
    -noout -subject -issuer -dates
done
```

Verify these relationships:

| Certificate | Issuer |
|---|---|
| `apiserver.crt` | Kubernetes CA |
| `apiserver-etcd-client.crt` | etcd CA |
| `front-proxy-client.crt` | front-proxy CA |

### 14.3.2 Kubelet client certificate rotation

Run on both `controlplane` and `node01`:

```bash
ls -l /var/lib/kubelet/pki/kubelet-client-current.pem

openssl x509 \
  -in /var/lib/kubelet/pki/kubelet-client-current.pem \
  -noout -subject -issuer -dates

grep -E 'client-certificate:|client-key:' /etc/kubernetes/kubelet.conf
```

The certificate subject must match the node:

```text
controlplane    system:node:controlplane
node01          system:node:node01
```

`kubelet.conf` should reference `/var/lib/kubelet/pki/kubelet-client-current.pem`. With `rotateCertificates: true`, the kubelet requests and activates a new client certificate automatically as the current one approaches expiry. Kubeadm therefore excludes it from `kubeadm certs check-expiration` management.

### 14.3.3 Kubelet serving certificate rotation

Run on both nodes:

```bash
ls -l /var/lib/kubelet/pki/kubelet-server-current.pem

openssl x509 \
  -in /var/lib/kubelet/pki/kubelet-server-current.pem \
  -noout -subject -issuer -dates -ext subjectAltName
```

With `serverTLSBootstrap: true`, each kubelet requests a signed serving certificate. Unlike kubelet client CSRs, Kubernetes has no built-in automatic approver for serving CSRs because the requested node identity and SANs must be verified.

Future rotations follow this process:

```
serving certificate nears expiry
        ↓
kubelet submits a new CSR
        ↓
operator verifies node identity and SANs
        ↓
operator approves the CSR
```

## 14.4 Verify exposure and authentication

### 14.4.1 Inspect listening ports

Run on both `controlplane` and `node01`:

```bash
ss -lntp
```

On `controlplane`, focus on the control-plane and kubelet ports:

```bash
ss -lntp | grep -E ':(2379|2380|6443|10249|10250|10256|10257|10259)\b'
```

On `node01`, focus on the kubelet and Kubernetes networking ports:

```bash
ss -lntp | grep -E ':(10249|10250|10256)\b'
```

Confirm that each listener is expected and bound to loopback or the node network as intended.

### 14.4.2 Verify etcd client-certificate authentication

Run on `controlplane`. First attempt an unauthenticated request:

```bash
curl \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  https://127.0.0.1:2379/health
```

Because etcd uses `--client-cert-auth=true`, this request should fail.

Repeat it with a valid client certificate:

```bash
curl \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key /etc/kubernetes/pki/etcd/healthcheck-client.key \
  https://127.0.0.1:2379/health
```

Expected response:

```json
{"health":"true"}
```

This confirms that reaching the etcd endpoint is insufficient without a trusted client certificate.

## 14.5 Verify NetworkPolicy enforcement

Create a disposable namespace with a server and client. The scheduler can place the workloads on `node01`; no control-plane tolerations are needed.

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
  containers:
    - name: client
      image: busybox:1.37.0
      command: ["sleep", "3600"]
EOF

kubectl apply -f /root/calico/netpol-test.yaml
kubectl wait -n thew-netpol-test \
  --for=condition=Ready pod --all --timeout=120s

SERVER_IP="$(kubectl get pod -n thew-netpol-test \
  -l role=server -o jsonpath='{.items[0].status.podIP}')"
```

### 14.5.1 Confirm default-allow behavior

```bash
kubectl exec -n thew-netpol-test client -- \
  wget -T 3 -qO- "http://${SERVER_IP}"
```

The nginx page should be returned. Without a selecting NetworkPolicy, Kubernetes allows ingress and egress by default.

### 14.5.2 Apply default-deny

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

kubectl apply -f /root/calico/default-deny.yaml

kubectl exec -n thew-netpol-test client -- \
  wget -T 3 -qO- "http://${SERVER_IP}"
```

The request should time out or fail, proving that Calico enforces the policy.

### 14.5.3 Allow client-to-server traffic and DNS

Because the client is egress-isolated and the server is ingress-isolated, allow both sides of the application path. Also permit DNS egress explicitly.

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
  name: allow-client-egress
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

kubectl apply -f /root/calico/allow-client-server.yaml
```

Verify both permitted paths:

```bash
kubectl exec -n thew-netpol-test client -- \
  wget -T 3 -qO- "http://${SERVER_IP}"

kubectl exec -n thew-netpol-test client -- \
  nslookup kubernetes.default.svc.cluster.local
```

Both should succeed. This also demonstrates that DNS must be permitted explicitly with default-deny egress.

Clean up:

```bash
kubectl delete namespace thew-netpol-test
```

## 14.6 Verify cross-node connectivity and WireGuard

Create one Pod on each node:

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

kubectl apply -f /root/calico/cross-node-test.yaml
kubectl wait -n thew-network-test \
  --for=condition=Ready pod --all --timeout=120s
kubectl get pods -n thew-network-test -o wide
```

Confirm that `pod-controlplane` runs on `controlplane` and `pod-node01` on `node01`.

Store both Pod IPs on `controlplane`:

```bash
CP_POD_IP="$(kubectl get pod -n thew-network-test pod-controlplane \
  -o jsonpath='{.status.podIP}')"

NODE01_POD_IP="$(kubectl get pod -n thew-network-test pod-node01 \
  -o jsonpath='{.status.podIP}')"
```

Test traffic in both directions:

```bash
kubectl exec -n thew-network-test pod-controlplane -- \
  ping -c 4 "${NODE01_POD_IP}"

kubectl exec -n thew-network-test pod-node01 -- \
  ping -c 4 "${CP_POD_IP}"
```

Both tests should succeed, validating Calico IPAM, cross-node routing and host firewall forwarding.

Finally, verify the encrypted route on each node.

On `controlplane`:

```bash
ip route get "${NODE01_POD_IP}"
```

On `node01`, copy the control-plane Pod IP obtained above:

```bash
CP_POD_IP='<control-plane-pod-IP>'
ip route get "${CP_POD_IP}"
```

Both remote workload routes should use Calico's `wireguard.cali` interface.

Clean up the namespace, but retain the manifest for future validation:

```bash
kubectl delete namespace thew-network-test
```
