## 1. Scope

### 1.1 Purpose
This document describes the initial installation base for a Kubernetes The Hard Way lab environment on Debian 12.

The goal of this part is to create a clean, repeatable, minimal server foundation for the Kubernetes control plane and worker nodes before any Kubernetes components are installed.
### 1.2 Version choice for Kubernetes
Use **Kubernetes v1.35**

## 2. Lab Topology
### 2.1 VM layout

| VM             | Role          | vCPU | RAM   | Disk       | OS                |
| -------------- | ------------- | ---- | ----- | ---------- | ----------------- |
| `controlplane` | control plane | 2    | 8 GB  | 80 GB thin | Debian 12 minimal |
| `node01`       | worker        | 2    | 10 GB | 80 GB thin | Debian 12 minimal |

### 2.2 Network layout
```
VMnet2: NAT
Subnet: 172.31.88.0/28
Mask:   255.255.255.240

Gateway/NAT: 172.31.88.2

DHCP range:  
	Start: 172.31.88.3  
	End:   172.31.88.6

Static Kubernetes nodes:  
	controlplane: 172.31.88.10  
	node01:       172.31.88.11  
```

A `/28` gives you 14 usable addresses, which is enough for this lab:
```
172.31.88.1   VMware host adapter
172.31.88.2   VMware NAT gateway
172.31.88.3   DHCP spare
172.31.88.4   DHCP spare
172.31.88.5   DHCP spare
172.31.88.6   DHCP spare
172.31.88.10  controlplane
172.31.88.11  node01
172.31.88.12  node02 (if possible)
```

### 2.3 Kubernetes CIDRs
Use non-overlapping networks:
```
Node network:    172.31.88.0/28
Pod network:     10.244.0.0/16
Service network: 10.96.0.0/12
Service network: 10.96.0.0/12
```
## 3. Cluster

### 3.1 Components
- **Kubernetes**: v1.35.x
- **containerd**: v2.3.x
- **Calico (CNI)**: v3.32.x
- **etcd:** v3.6.x
- **runc:** v1.4.x

All VMs are built with **Debian 12.12.x**. It is available in the [Debian Archive](https://cdimage.debian.org/cdimage/archive/12.12.0/amd64/iso-cd/).
Kubernetes is intentionally left at version 1.35 in order to leave room for upgrade tasks (and upgrade to 1.36)
