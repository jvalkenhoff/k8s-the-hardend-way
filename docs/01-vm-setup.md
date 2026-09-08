## 1. VMware
### 1.1 VMware Network Configuration

#### Create VMnet2
Open **Virtual Network Editor**.
Create `VMnet2`, rename it to:
`k8s-net`

Set it to:
```
Type: NAT
Connect a host virtual adapter: Enabled
Use local DHCP service: Disabled
Subnet IP:   172.31.88.0
Subnet mask: 255.255.255.240
```

#### NAT Settings
```
Gateway IP: 172.31.88.2
Port forwarding: leave empty
IPv6: disabled
```

### 1.2 Virtual Machine Creation

#### VM Shell
Start the Virtual Machine Wizard and choose **Custom**:
1. Latest Hardware compability
2. Install VM Later
3. Choose Linux, Version: Debian 12.x 64-bit
4. Virtual Machine name: controlplane / node01
5. Number of processors: 1, Number of cores per processor: 2
6. Choose 8192MB for controlplane, 10240MB for node01 memory
7. Choose network connection NAT
8. Choose Paravirtualized SCSI
9. Virtual Disk Type should be SCSI
10. Create new Virtual Disk
11. Make size 80GB for all VMs, store virtual disks in a single file
12. Finish the creation

### 1.3 Customize Hardware
Edit the virtual machine settings
1. Remove sound card and USB controllers
2. Set the Network Adapter to custom, select the k8s-net virtual network
3. Set the CD/DVD drive to ISO image file debian-12.12.0.iso

### 1.4 Switch to UEFI
Edit the Virtual machine settings
1. Open Options --> Advanced
2. Switch firmware type to UEFI

## 2. Debian Installation
Power on the VM, choose graphical install
Use the following steps to consistently setup the VM:
### 2.1 Localization
1. **Country:** Netherlands 
2. **Locales:** United States (en_US.UTF-8)
3. **Keymap** American English

*loading components...*

### 2.2 Network
1. IP: 172.31.88.10/28 / 172.31.88.11/28
2. Gateway: 172.31.88.2
3. **Hostname:** `controlplane` / `node01`
4. **Domain Name:** `k8s.local`

### 2.3 Users setup
1. **Root password:** `<password>`
2. **Verify password**
3. **Name for new user:** `debian`
4. **Username:** `debian`
5. **User password:** `<password>`
6. **Verify password**

### 2.4 Partition table
1. **Partitioning method**: Manual
2. **Select disk**: SCSI 1 (can only choose one)
3. **Create partition Table**: Yes

| Partition   | Use as | Mount Point                 | Size  |
| ----------- | ------ | --------------------------- | ----- |
| `/dev/sda1` | EFI    | `/boot/efi` (automatically) | 512MB |
| `/dev/sda2` | ext4   | `/boot`                     | 1G    |
| `/dev/sda3` | LVM    | -                           | rest  |

### 2.5 LVM Setup
1. Configure Logical Volume Manager
2. **Format**: Yes
3. **Create volume group**: vg0

**controlplane**

| Logical volume          | Use as | Mount point           | Size |
| ----------------------- | ------ | --------------------- | ---- |
| `lv_root`               | Ext4   | `/`                   | 18G  |
| `lv_home`               | Ext4   | `/home`               | 5G   |
| `lv_var`                | Ext4   | `/var`                | 20G  |
| `lv_var_tmp`            | Ext4   | `/var/tmp`            | 2G   |
| `lv_var_log`            | Ext4   | `/var/log`            | 5G   |
| `lv_var_log_audit`      | Ext4   | `/var/log/audit`      | 3G   |
| `lv_var_lib_etcd`       | Ext4   | `/var/lib/etcd`       | 8G   |
| `lv_var_lib_containerd` | ext4   | `/var/lib/containerd` | 20G  |

**Node**

| Logical volume          | Mount point           | Size |
| ----------------------- | --------------------- | ---: |
| `lv_root`               | `/`                   |  18G |
| `lv_home`               | `/home`               |   5G |
| `lv_var`                | `/var`                |  22G |
| `lv_var_tmp`            | `/var/tmp`            |   2G |
| `lv_var_log`            | `/var/log`            |   5G |
| `lv_var_log_audit`      | `/var/log/audit`      |   3G |
| `lv_var_lib_containerd` | `/var/lib/containerd` |  26G |

Do not worry about mount-options. That will be handled later.

*Installing base system...*

**Package Manager**
1. **Scan extra installation media**: no
2. **Mirror country**: Netherlands
3. **Archive mirror**: deb.debian.org
4. **HTTP Proxy**: leave empty

**Software Selection**
1. **DESELECT:** Debian desktop environment, GNOME (with spacebar)
2. **SELECT:** SSH server, standard system utilities

**Configure GRUB**
1. **Boot loader on primary drive**: yes
2. **Device for bootloader**: /dev/vda

Reboot the system.