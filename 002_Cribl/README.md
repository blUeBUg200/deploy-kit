# Cribl Stream Deployment Script — `cribl-deploy.sh`

One Bash script that installs **Cribl Stream** from the official tarball (no RPM/DEB) and configures the host as a **Leader** or a **Worker** in a distributed deployment.

| | |
|---|---|
| **Script version** | 1.5.0 |
| **Supported OS** | Ubuntu / Debian · RHEL / Rocky / Alma / Oracle / CentOS |
| **CPU** | x86_64 (`linux-x64`) · aarch64 (`linux-arm64`) |
| **Install path** | `/opt/cribl` |
| **Service** | `cribl.service` (systemd), runs as non-root user `cribl` |
| **Reference** | [Set Up Leader and Worker Nodes](https://docs.cribl.io/stream/setting-up-leader-and-worker-nodes/) |

---

## 1. What it does

The script runs the same stages on every host. Only the role step differs.

| # | Stage | What happens |
|---|---|---|
| 1 | **Detect platform** | Identifies OS family, package manager and CPU architecture. |
| 2 | **Collect inputs** | Role, Leader host, auth token, Worker Group — from flags or interactive prompts. Leader token is auto-generated if not given. |
| 3 | **Check prerequisites** | Looks for the Cribl bundle next to the script and for missing OS packages. If anything must be downloaded, asks once whether the host has internet; `n` stops with what is required. |
| 4 | **Pre-flight checks** | CPU, RAM, free disk, local (non-network) filesystem, systemd, hostname resolution. Worker: tests TCP to Leader on 4200 and explains any failure. |
| 5 | **Handle previous installs** | Detects a full or partial install (directory, service files, running processes, leftover RPM/DEB). Stops it, then **backs it up** (default) or **deletes** it. |
| 6 | **Check ports** | Fails if a non-Cribl process holds 9000 (and 4200 on the Leader). |
| 7 | **Time sync** | Uses existing `systemd-timesyncd` / `ntpd`, otherwise enables `chrony`. |
| 8 | **Service account** | Creates system user `cribl` with no login shell. |
| 9 | **OS tuning** | File / process limits, kernel network settings, Transparent Huge Pages off. Worker adds larger socket buffers and connection-tracking headroom. |
| 10 | **Obtain bundle** | Uses the bundle from the script's directory, or downloads the latest from `cdn.cribl.io` (only after a `y`). Validates the tarball. |
| 11 | **Install** | Extracts to `/opt/cribl`, sets ownership. On RHEL with SELinux, labels the binaries so systemd can run them. |
| 12 | **Set role** | Leader: `cribl mode-master`. Worker: `cribl mode-worker` with Leader host, token and group. |
| 13 | **Register service** | `cribl boot-start` + systemd override (limits, auto-restart, privileged-port permission). Starts the service. |
| 14 | **Firewall** | Opens ports in `ufw` / `firewalld` if active. Leader: 9000, 4200. Worker: only ports passed in `--data-ports`. |
| 15 | **Verify & summarise** | Leader: service up, 4200 listening. Worker: live session to the Leader. Prints next steps. |

All output is also written to `/var/log/cribl-deploy.log`.

---

## 2. What is covered

**Installation**
- Tarball-based install on Ubuntu and RHEL families, x64 and arm64.
- Offline install with no extra options: place the bundle next to the script (newest version wins).
- Automatic cleanup of previous or partial installs, with backup or delete.

**Distributed setup**
- Leader configuration with a randomly generated auth token.
- Worker configuration with Leader host, token, Worker Group (default `default`) and optional tags.
- Optional TLS between Leader and Worker (certificate and key supplied by you).
- Any number of Workers — rerun the Worker command on each new host.

**OS best practices**
- Dedicated non-root service account; service runs under systemd with auto-restart.
- Privileged ports (< 1024, e.g. syslog 514) allowed by default, without running as root.
- Open-file limit 65536, kernel network tuning, Transparent Huge Pages disabled.
- Worker: 25 MB socket receive buffers, larger connection-tracking table.
- Time synchronisation, SELinux labelling on RHEL, host firewall rules.

**Safety**
- Prerequisite check before any change; asks before downloading anything, and stops cleanly on `n`.
- Refuses the well-known default token `criblmaster`.
- Refuses network storage (NFS/CIFS/EFS) for the install directory.
- Process detection by executable, so unrelated processes are never stopped.

---

## 3. What is not covered

| Area | Notes |
|---|---|
| Leader high availability / failover | Single Leader only. |
| Creating Worker Groups | Create non-default groups in the Leader UI **before** installing Workers that use them. |
| Admin password | First login is `admin` / `admin`; change it manually. |
| TLS certificates | Not generated. Supply PEM certificate and key with `--tls-cert` / `--tls-key`. |
| Licensing | Apply your license in the Leader UI. |
| Data configuration | Sources, Destinations, Routes, Pipelines, Packs. |
| Commit & deploy | Run from the Leader UI after Workers join. |
| Git remote / version control | Local git only (installed on the Leader). |
| Network outside the host | Hypervisor, cloud security groups, network firewalls, load balancers. |
| Upgrades | A rerun installs fresh and backs up the old copy; it does not migrate configuration. |
| Other platforms | Cribl Edge, Docker, Kubernetes, Windows. |
| Proxy for Cribl itself | The script's downloads honour `https_proxy`; Cribl's runtime proxy is configured separately. |

---

## 4. Prerequisites check: OS packages and Cribl bundle (automatic)

Runs first, before anything on the host is changed. There are no options for it.

| Situation | What the script does |
|---|---|
| Bundle in the script's directory, all OS packages present | Proceeds. **Nothing is downloaded**, no question asked. |
| Bundle in the script's directory, OS packages missing | Asks: *Does this host have internet access to download them? [y/n]* |
| No bundle in the script's directory | Asks the same question (the bundle would come from `cdn.cribl.io`). |
| Both missing | Lists both and asks the question **once**. |

| Answer | Result |
|---|---|
| `y` | Installs the missing OS packages now; downloads the bundle at the install step. |
| `n` | Stops and states what is required: *"These OS packages are required to proceed: …"* with the install command, and/or *"The Cribl Stream package is required to proceed"* with where to put the file. |

**Bundle rules:** file must be `cribl-<ver>-<build>-linux-<arch>.tgz` in the **same directory as the script**, under its original name. If several versions are there, the newest is used. Bundles for the other CPU type, Cribl Edge bundles (`cribl-edge-*`) and renamed files are ignored with a warning.

**No terminal** (for example, run from automation): the question cannot be asked, so it is treated as `n` and the script stops with the same message. The general `--yes` flag answers `y`.

---

## 5. Prerequisites

| Item | Leader | Worker |
|---|---|---|
| Access | `root` or `sudo` | `root` or `sudo` |
| Sizing (production) | 4+ vCPU, 8+ GB RAM | 4+ vCPU, 8+ GB RAM |
| Free disk on `/opt` | 5 GB minimum, local disk | 5 GB minimum, local disk |
| Inbound ports | 9000/tcp (UI), 4200/tcp (Workers) | Your data ports only |
| Outbound | — | Leader on 4200/tcp |
| Bundle | Internet to `cdn.cribl.io`, **or** the `.tgz` next to the script | Same |

Lower sizing only warns, so labs work.

---

## 6. How to run — 1 Leader + 1 Worker

Example hosts:

| Role | Hostname | IP |
|---|---|---|
| Leader | `cribl-leader01` | `192.168.55.55` |
| Worker | `cribl-worker01` | `192.168.55.56` |

### Step 1 — Copy files to both hosts
```bash
scp cribl-deploy.sh cribl-4.20.2-7199aa90-linux-x64.tgz user@192.168.55.55:/tmp/
scp cribl-deploy.sh cribl-4.20.2-7199aa90-linux-x64.tgz user@192.168.55.56:/tmp/
```
**Offline:** keep the `.tgz` in the same directory as the script, under its original name — it is used automatically. **Online:** copy only the script; the latest bundle is downloaded.

On each host:
```bash
cd /tmp && chmod +x cribl-deploy.sh
```

### Step 2 — Optional dry run
```bash
sudo ./cribl-deploy.sh --precheck
```
Reports dependencies, sizing and any previous install. Changes nothing.

### Step 3 — Install the Leader (`192.168.55.55`)
```bash
sudo ./cribl-deploy.sh --role leader
```
At the end, the summary shows the **UI URL**, the **auth token** and the exact Worker command. Store the token securely.

### Step 4 — Prepare the Leader UI
1. Open `http://192.168.55.55:9000` and log in as `admin` / `admin`.
2. Change the admin password.
3. Only if not using `default`: **Worker Groups → Add** the group.

### Step 5 — Install the Worker (`192.168.55.56`)
Paste the command from the Leader summary:
```bash
sudo ./cribl-deploy.sh --role worker \
     --leader-host 192.168.55.55 \
     --token '<AUTH_TOKEN>' \
     --group default
```
Optional: `--data-ports "514/udp,514/tcp"` to open inbound data ports, `--tags "dc1,linux"` to tag the Worker.

### Step 6 — Verify and deploy
1. Leader UI → **Workers**: `cribl-worker01` appears in its group.
2. Open the group → **Commit** → **Deploy**.

To scale out, repeat Step 5 on each new Worker host.

---

## 7. Common options

| Need | Flag |
|---|---|
| Interactive mode | run with no flags |
| Worker: install before the Leader is reachable | `--skip-leader-check` |
| Reinstall, delete old copy | `--reinstall-mode clean` |
| Backup location | `--backup-dir /data/cribl-backups` |
| Unattended (answers `y` to every question, including downloads) | `--yes` |
| TLS (Leader) | `--tls --tls-cert leader.crt --tls-key leader.key` |
| TLS (Worker) | `--tls` |
| Do not allow ports < 1024 | `--no-low-ports` |
| Skip firewall / OS tuning | `--skip-firewall` / `--skip-os-tuning` |
| Remove Cribl | `--uninstall` |
| All options | `--help` |

---

## 8. Files and changes on the host

| Path | Purpose |
|---|---|
| `/opt/cribl` | Cribl installation |
| `/opt/cribl-backups/cribl-<timestamp>/` | Previous install (backup mode) |
| `/etc/systemd/system/cribl.service` | Service unit (from `cribl boot-start`) |
| `/etc/systemd/system/cribl.service.d/override.conf` | Limits, restart policy, privileged-port permission |
| `/etc/systemd/system/disable-thp.service` | Disables Transparent Huge Pages at boot |
| `/etc/sysctl.d/99-cribl.conf`, `99-cribl-conntrack.conf` | Kernel tuning |
| `/etc/security/limits.d/99-cribl.conf` | User limits for `cribl` |
| `/var/log/cribl-deploy.log` | Script log |

---

## 9. Troubleshooting

| Symptom | Check |
|---|---|
| Worker: `Cannot connect to Leader <ip>:4200` | The script prints the cause (refused, timeout, no route, DNS). On the Leader: `systemctl status cribl`, `ss -ltnp \| grep 4200` (expect `0.0.0.0:4200`), `ufw status` / `firewall-cmd --list-ports`. From the Worker: `nc -vz <leader-ip> 4200`. On a terminal you can choose to continue; unattended, add `--skip-leader-check`. |
| Bundle was downloaded instead of the local file | File must be in the **script's** directory, keep its original name, and match the CPU (`linux-x64` / `linux-arm64`). The log shows `Ignoring <file>: <reason>`. |
| "The Cribl Stream package is required to proceed" | Copy `cribl-<ver>-<build>-linux-<arch>.tgz` next to the script and re-run. |
| "These OS packages are required to proceed" | Run the printed `apt-get install` / `dnf install` command, or copy the packages from a connected host. |
| Answered `y` but repositories or `cdn.cribl.io` unreachable | Script stops with the same "required" message; check proxy, DNS and firewall, or provide the files locally. |
| Service does not start | `journalctl -u cribl -n 100`, `/opt/cribl/log/cribl.log` |
| Worker not in expected group | Group must exist on the Leader; then Commit & Deploy. |
| Port 9000 / 4200 in use | Stop the other process, or `--force`. |

Logs: `/var/log/cribl-deploy.log` (script) · `/opt/cribl/log/cribl.log` (Cribl).
