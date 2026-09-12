> [!NOTE]
> This chapter is only on the `controlplane`
## 12.1 Calico
### 12.1.1 Install Calico
On `controlplane`:
```bash
install -d -o root -g root -m 0700 /root/calico
```

Download the CRD bundle:
```bash
curl -fL \
  "https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/v1_crd_projectcalico_org.yaml" \
  -o /root/calico/v1_crd_projectcalico_org.yaml
```

Download tigera operator:
```bash
curl -fL \
  "https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/tigera-operator.yaml" \
  -o /root/calico/tigera-operator.yaml
```
### 12.1.2 Install the Calico CRDs
Install the Calico CRDs:
```bash
kubectl create -f /root/calico/v1_crd_projectcalico_org.yaml
```
### 12.1.3 Install the Tigera Operator
Now:
```bash
kubectl create -f /root/calico/tigera-operator.yaml
```

Check:
```bash
kubectl get pods -n tigera-operator -o wide
```

Then wait for the Deployment:
```bash
kubectl wait --namespace tigera-operator --for=condition=Available deployment/tigera-operator --timeout=120s
```

Expected:
```text
deployment.apps/tigera-operator condition met
```

### 12.1.4 Create Installation resource
Create:
```bash
cat > /root/calico/installation.yaml <<'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:

  cni:
    type: Calico

  calicoNetwork:
    linuxDataplane: Iptables

    bgp: Disabled

    mtu: 1440

    nodeAddressAutodetectionV4:
      kubernetes: NodeInternalIP

    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: 10.244.0.0/16
        encapsulation: VXLAN
        natOutgoing: Enabled
        nodeSelector: all()
EOF
```

Protect it:
```bash
chown root:root /root/calico/installation.yaml && chmod 0600 /root/calico/installation.yaml
```
### 12.1.5 Create the Calico installation
Before creating it, let the API server validate the object without persisting it:
```bash
kubectl create --dry-run=server -f /root/calico/installation.yaml
```

If that succeeds:
```bash
kubectl create -f /root/calico/installation.yaml
```

Expected:
```text
installation.operator.tigera.io/default created
```

Run:
```bash
watch kubectl get tigerastatus
```

The important status is:
```text
calico
```

We want:
```text
AVAILABLE      True
PROGRESSING    False
DEGRADED       False
```

Calico uses `TigeraStatus` specifically for operator deployment health.

Exit `watch` with:
```text
Ctrl+C
```

### 12.1.6 Inspect the actual Calico Pods
Run:
```bash
kubectl get pods -n calico-system -o wide
```

The important components should settle into:
```text
Running
```

You should have a `calico-node` Pod on `controlplane`, together with operator-managed supporting components such as the kube controllers.

Then:
```bash
kubectl get nodes -o wide
```

The `controlplane` should change from `NotReady` to `Ready`

### 12.1.7 Verify CoreDNS
Now:
```bash
kubectl get pods -n kube-system -o wide
```

CoreDNS should no longer remain permanently `Pending`.

Eventually we want:

```text
coredns-...       Running
coredns-...       Running
```

This is our first indication that the Pod network is functioning.

### Confirm the generated CNI configuration exists
On the host:
```bash
ls -l /etc/cni/net.d
```

You should now see Calico's generated CNI configuration, normally:
```text
10-calico.conflist
```

## 12.2 Enable WireGuard
### 12.2.1 Inspect IP Pools
Run:
```bash
kubectl get ippools.crd.projectcalico.org -o wide
```

You should have one pool corresponding to:
```text
default-ipv4-ippool
10.244.0.0/16
```

To inspect the important properties:

```bash
kubectl get ippools.crd.projectcalico.org/default-ipv4-ippool -o yaml
```

Verify:
```text
CIDR          10.244.0.0/16
VXLAN         enabled
IP-in-IP      disabled
NAT outgoing  enabled
```

### 12.2.2 Enable WireGuard
Now that the core Calico installation is healthy, enable IPv4 WireGuard:
```bash
kubectl patch felixconfiguration default --type='merge' -p '{"spec":{"wireguardEnabled":true,"wireguardEnabledV6":false}}'
```

Calico officially enables IPv4 WireGuard through:
```text
FelixConfiguration.spec.wireguardEnabled
```

and its default is otherwise `false`.

We explicitly keep:
```text
wireguardEnabledV6: false
```

because this is an IPv4-only cluster.
### 12.2.3 Verify the WireGuard setting
Run:
```bash
kubectl get felixconfiguration default -o jsonpath='{.spec.wireguardEnabled}{"\n"}'
```

Expected:
```text
true
```

Also:
```bash
ip link show wireguard.cali
```

Once Felix has reconciled the setting, you should normally see an interface named:
```text
wireguard.cali
```

The default interface name and default IPv4 listening port are:
```text
wireguard.cali
UDP 51820
```

Since only `controlplane` belongs to the Kubernetes cluster right now, there is not yet another Calico node with which to establish useful encrypted Pod traffic.

The real peer relationship will appear after `node01` joins.
