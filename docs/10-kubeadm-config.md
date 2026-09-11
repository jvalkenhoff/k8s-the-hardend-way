## 10.1 Base Cluster
For documentation/organization, I actually like splitting these.
```
/etc/kubernetes/config/
├── kubeadm-config.yaml
├── kubelet-config.yaml
└── kube-proxy-config.yaml
```

Create the following directory on `controlplane`:
```bash
install -d -o root -g root -m 0700 /etc/kubernetes/config
```

### 10.1.1 Base Cluster
Start with the initial `/etc/kubernetes/config/kubeadm-config.yaml`

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration

localAPIEndpoint:
  advertiseAddress: 172.31.88.10
  bindPort: 6443

nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: 172.31.88.10

---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration

kubernetesVersion: v1.35.8
controlPlaneEndpoint: "172.31.88.10:6443"

networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
  dnsDomain: cluster.local
```

Permissions:
```
chown root:root /etc/kubernetes/config/kubeadm-config.yaml && chmod 0600 /etc/kubernetes/config/kubeadm-config.yaml
```
### 10.1.2 Kubelet config
Build the kubelet config `/etc/kubernetes/config/kubelet-config.yaml`
```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: true
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
readOnlyPort: 0
rotateCertificates: true
serverTLSBootstrap: true
seccompDefault: true
podPidsLimit: 4096
clusterDNS:
  - 10.96.0.10
clusterDomain: cluster.local
resolvConf: /run/systemd/resolve/resolv.conf
makeIPTablesUtilChains: true
healthzBindAddress: 127.0.0.1
healthzPort: 10248
staticPodPath: /etc/kubernetes/manifests
shutdownGracePeriod: 30s
shutdownGracePeriodCriticalPods: 10s
tlsMinVersion: VersionTLS12
tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
```

Permissions:
```
chown root:root /etc/kubernetes/config/kubelet-config.yaml && chmod 0600 /etc/kubernetes/config/kubelet-config.yaml
```
### 10.1.3 Kube-proxy config
Build the kube-proxy config `/etc/kubernetes/config/kube-proxy-config.yaml`
```yaml
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration

metricsBindAddress: "127.0.0.1:10249"
```

Permissions:
```
chown root:root /etc/kubernetes/config/kube-proxy-config.yaml && chmod 0600 /etc/kubernetes/config/kube-proxy-config.yaml
```
## 10.2 API Server
### 10.2.1 Update ClusterConfiguration
Edit `/etc/kubernetes/config/kubeadm-config.yaml`.

Inside the existing `ClusterConfiguration`, add the following `apiServer:` block:
```yaml
apiServer:
  certSANs:
    - "172.31.88.10"
    - "controlplane"
  extraArgs:
    - name: authentication-config
      value: "/etc/kubernetes/auth/authentication-config.yaml"
    - name: authorization-mode
      value: "Node,RBAC"
    - name: enable-admission-plugins
      value: "NodeRestriction,DenyServiceExternalIPs,AlwaysPullImages,EventRateLimit"
    - name: admission-control-config-file
      value: "/etc/kubernetes/admission/admission-config.yaml"
    - name: profiling
      value: "false"
    - name: audit-policy-file
      value: "/etc/kubernetes/audit/audit-policy.yaml"
    - name: audit-log-path
      value: "/var/log/kubernetes/audit/audit.log"
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: encryption-provider-config
      value: "/etc/kubernetes/encryption/encryption-config.yaml"
    - name: service-account-lookup
      value: "true"
    - name: service-account-extend-token-expiration
      value: "false"
    - name: tls-min-version
      value: "VersionTLS12"
    - name: tls-cipher-suites
      value: "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
  extraVolumes:
    - name: admission-config
      hostPath: /etc/kubernetes/admission
      mountPath: /etc/kubernetes/admission
      readOnly: true
      pathType: Directory
    - name: audit-policy
      hostPath: /etc/kubernetes/audit
      mountPath: /etc/kubernetes/audit
      readOnly: true
      pathType: Directory
    - name: audit-log
      hostPath: /var/log/kubernetes/audit
      mountPath: /var/log/kubernetes/audit
      readOnly: false
      pathType: Directory
    - name: encryption-config
      hostPath: /etc/kubernetes/encryption
      mountPath: /etc/kubernetes/encryption
      readOnly: true
      pathType: Directory
    - name: authentication-config
      hostPath: /etc/kubernetes/auth
      mountPath: /etc/kubernetes/auth
      readOnly: true
      pathType: Directory
```

> [!NOTE]
> With this setup, the API server expects extra config files. We will configure them now.

### 10.2.2 Configure Endpoint Authentication
Allow anonymous auth for health endpoints. Create:
```bash
install -d -o root -g root -m 0700 /etc/kubernetes/auth
```

Create  `/etc/kubernetes/auth/authentication-config.yaml:
```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AuthenticationConfiguration
anonymous:
  enabled: true
  conditions:
  - path: /livez
  - path: /readyz
  - path: /healthz
```

Permissions:
```
chown root:root /etc/kubernetes/auth/authentication-config.yaml && chmod 0600 /etc/kubernetes/auth/authentication-config.yaml
```
### 10.2.3 Configure rate limit
Setup rate limits on the cluster. Create:
```bash
install -d -o root -g root -m 0700 /etc/kubernetes/admission
```

Create `/etc/kubernetes/admission/eventratelimit.yaml`:
```yaml
apiVersion: eventratelimit.admission.k8s.io/v1alpha1
kind: Configuration
limits:
  - type: Server
    qps: 50
    burst: 100
  - type: Namespace
    qps: 50
    burst: 100
    cacheSize: 2000
  - type: User
    qps: 10
    burst: 50
```

Create `/etc/kubernetes/admission/admission-config.yaml`:
```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: EventRateLimit
    path: /etc/kubernetes/admission/eventratelimit.yaml
```

Permissions:
```
chown root:root /etc/kubernetes/admission/eventratelimit.yaml && chmod 0600 /etc/kubernetes/admission/eventratelimit.yaml

chown root:root /etc/kubernetes/admission/admission-config.yaml && chmod 0600 /etc/kubernetes/admission/admission-config.yaml
```

### 10.2.4 Configure audit
Create:
```bash
install -d -o root -g root -m 0700 /etc/kubernetes/audit

install -d -o root -g root -m 0700 /var/log/kubernetes/audit
```

Create `/etc/kubernetes/audit/audit-policy.yaml`
```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Sensitive resources: log metadata only.
  # Never record Secret, ConfigMap, TokenReview or token bodies.
  - level: Metadata
    resources:
      - group: ""
        resources:
          - secrets
          - configmaps
          - serviceaccounts/token
      - group: authentication.k8s.io
        resources:
          - tokenreviews

  # Record modifications to workloads.
  - level: Request
    verbs:
      - create
      - update
      - patch
      - delete
      - deletecollection
    resources:
      - group: ""
        resources:
          - pods
      - group: apps
        resources:
          - deployments

  # Security-sensitive pod/service subresources.
  - level: Metadata
    resources:
      - group: ""
        resources:
          - pods/exec
          - pods/portforward
          - pods/proxy
          - services/proxy

  # Certificate creation and approval.
  - level: Metadata
    resources:
      - group: certificates.k8s.io
        resources:
          - certificatesigningrequests
          - certificatesigningrequests/approval

  # Baseline visibility for all remaining API requests.
  - level: Metadata
```

Permissions:
```
chown root:root /etc/kubernetes/audit/audit-policy.yaml && chmod 0600 /etc/kubernetes/audit/audit-policy.yaml
```
### 10.2.5 Configure Encryption
Create:
```bash
install -d -o root -g root -m 0700 /etc/kubernetes/encryption
```

Generate a random 32-byte encryption key:
```bash
ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"
```

Create:
```bash
umask 077

cat > /etc/kubernetes/encryption/encryption-config.yaml <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration

resources:
  - resources:
      - secrets

    providers:
      - secretbox:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
EOF

unset ENCRYPTION_KEY
```

Permissions:
```bash
chown root:root /etc/kubernetes/encryption/encryption-config.yaml && chmod 0600 /etc/kubernetes/encryption/encryption-config.yaml
```
## 10.3 Controller Manager
Edit `/etc/kubernetes/config/kubeadm-config.yaml`.

Inside the existing `ClusterConfiguration`, add the following `controllerManager:` block:
```yaml
controllerManager:
  extraArgs:
    - name: profiling
      value: "false"
    - name: use-service-account-credentials
      value: "true"
    - name: bind-address
      value: "127.0.0.1"
    - name: terminated-pod-gc-threshold
      value: "1000"
```

## 10.4 Scheduler
Edit `/etc/kubernetes/config/kubeadm-config.yaml`.

Inside the existing `ClusterConfiguration`, add the following `scheduler:` block:
```yaml
scheduler:
  extraArgs:
    - name: profiling
      value: "false"
    - name: bind-address
      value: "127.0.0.1"
```
## 10.5 etcd
Edit `/etc/kubernetes/config/kubeadm-config.yaml`.

Inside the existing `ClusterConfiguration`, add the following `scheduler:` block:
```yaml
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      - name: client-cert-auth
        value: "true"
      - name: peer-client-cert-auth
        value: "true"
      - name: auto-tls
        value: "false"
      - name: peer-auto-tls
        value: "false"
```

## 10.6 Build the config
Assemble the configs:
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

Check the complete images list:
```bash
kubeadm config images list --config /tmp/kubeadm-init.yaml
```
