Create a temporary /tmp/binaries folder:
```
install -d -m 0700 /tmp/binaries

cd /tmp/binaries
```

## 8.1 runc install
Download runc and its checksum:
```
curl -fL -O "https://github.com/opencontainers/runc/releases/download/v1.5.1/runc.amd64" --output-dir /tmp/binaries

curl -fL -O "https://github.com/opencontainers/runc/releases/download/v1.5.1/runc.sha256sum" --output-dir /tmp/binaries
```

Verify the checksum:
```
grep -E '[[:space:]]runc\.amd64$' runc.sha256sum | sha256sum -c -
```

Install `runc`:
```
install -d -o root -g root -m 0755 /usr/local/sbin 

install -o root -g root -m 0755 /tmp/binaries/runc.amd64 /usr/local/sbin/runc
```

## 8.2 Containerd install
Download containerd and its checksum:
```
curl -fL -O "https://github.com/containerd/containerd/releases/download/v2.3.5/containerd-2.3.5-linux-amd64.tar.gz" --output-dir /tmp/binaries/

curl -fL -O "https://github.com/containerd/containerd/releases/download/v2.3.5/containerd-2.3.5-linux-amd64.tar.gz.sha256sum" --output-dir /tmp/binaries
```

Verify the checksum:
```
sha256sum -c containerd-2.3.5-linux-amd64.tar.gz.sha256sum
```

Unzip containerd tar:
```
tar -xzf /tmp/binaries/containerd-2.3.5-linux-amd64.tar.gz -C /tmp/binaries --strip-components 1
```

Setup folder explicitly:
```
install -d -o root -g root -m 0755 /usr/local/bin
```

Install containerd binaries:
```
for c in containerd containerd-shim-runc-v2 ctr; do install -m 0755 "/tmp/binaries/${c}" "/usr/local/bin/${c}"; done
```

## 8.3 Config containerd
### 8.3.1 toml
setup the folder:
```bash
install -d -o root -g root -m 0755 /etc/containerd
```

Create the configuration. `/etc/containerd/config.toml`:
```toml
version = 4

root = "/var/lib/containerd"
state = "/run/containerd"

[plugins.'io.containerd.server.v1.grpc']
  address = "/run/containerd/containerd.sock"
  uid = 0
  gid = 0

[plugins.'io.containerd.server.v1.debug']
  address = ""

[plugins.'io.containerd.server.v1.metrics']
  address = ""

[plugins.'io.containerd.cri.v1.images']
  snapshotter = "overlayfs"

  [plugins.'io.containerd.cri.v1.images'.registry]
    config_path = "/etc/containerd/certs.d"

[plugins.'io.containerd.cri.v1.runtime']
  disable_cgroup = false
  disable_apparmor = false
  unset_seccomp_profile = ""
  enable_unprivileged_ports = false
  enable_unprivileged_icmp = false
  enable_cdi = false

  [plugins.'io.containerd.cri.v1.runtime'.containerd]
    default_runtime_name = "runc"

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
      runtime_type = "io.containerd.runc.v2"
      privileged_without_host_devices = false
      privileged_without_host_devices_all_devices_allowed = false
      cgroup_writable = false
      base_runtime_spec = ""

      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
        BinaryName = "/usr/local/sbin/runc"
        SystemdCgroup = true

[plugins.'io.containerd.grpc.v1.cri']
  disable_tcp_service = true
  stream_server_address = "127.0.0.1"
  stream_server_port = "0"
  enable_tls_streaming = false

[plugins.'io.containerd.nri.v1.nri']
  disable = true
```

Protect it:
```
chown root:root /etc/containerd/config.toml
chmod 0640 /etc/containerd/config.toml
```
### 8.3.2 Systemd
create `/etc/systemd/system/containerd.service`
```ini
[Unit]
Description=containerd
After=network-online.target
Wants=network-online.target
RequiresMountsFor=/var/lib/containerd

[Service]
Type=notify
ExecStartPre=/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
```

Protect it:
```
chown root:root /etc/systemd/system/containerd.service && chmod 0644 /etc/systemd/system/containerd.service
```

### 8.3.3 certs folder
Create the certs folder:
```
install -d -o root -g root -m 0755 /etc/containerd/certs.d
```

### 8.3.4 Start containerd
Enable containerd:
```
systemctl daemon-reload
systemctl enable --now containerd
```

See if it runs properly:
```
systemctl status containerd
```

## 8.4 Verification
Run these small verification steps. 

Check containerd version:
```
containerd --version
```

Check runc version:
```
runc --version
```

CRI plugins should show `ok`:
```
ctr plugins ls | grep cri
```

If you want, you can check your current containerd config. The settings from `/etc/containerd/config.toml` should be present:
```
containerd config dump
```

Remove the binaries:
```
rm -rf /tmp/binaries
```