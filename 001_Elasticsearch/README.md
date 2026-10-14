# Elastic Stack 9.x – Minimal Self-Managed Cluster Setup

`elastic-node-setup.sh` installs a secured, production-style Elastic Stack from the official **tar.gz (binary) archives** — no RPM/DEB packages. You copy the one script to every VM and run it there, choosing that VM's **role**.

The result is a minimal cluster of five VMs:

- 3 × Elasticsearch nodes
- 1 × Kibana
- 1 × Fleet Server

It follows Elastic's tutorial [*Install a self-managed Elastic Stack*](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/tutorial-self-managed-install), adapted to archive installs and hardened with Elastic's *Important system configuration* guidance.

---

## Architecture

![Minimal Elastic Stack architecture](elastic-stack-architecture.png)

> An editable version of this diagram is in `elastic-stack-architecture.excalidraw` (open it at <https://excalidraw.com> → *Open*).

| Component | Port | Who connects |
|---|---|---|
| Elasticsearch HTTPS | 9200/tcp | Kibana, Fleet Server, Elastic Agents, admins |
| Elasticsearch transport (TLS) | 9300/tcp | The three Elasticsearch nodes only |
| Kibana HTTPS | 5601/tcp | Users' browsers |
| Fleet Server HTTPS | 8220/tcp | Elastic Agents |

---

## What the script does

**Security**
- TLS everywhere: Elasticsearch HTTP and transport (automatic security setup), Kibana HTTPS, and Fleet Server HTTPS.
- Kibana and Fleet Server certificates are signed by a local CA or by your own CA. Agents never need `--insecure`.
- Kibana connects to Elasticsearch with a service-account token, not a password.
- Kibana secrets and encryption keys are kept in the Kibana keystore.

**Cluster formation**
- Three master-eligible data nodes.
- Each extra node joins with an **enrollment token**.
- `discovery.seed_hosts` is consolidated on every node.

**Operating system tuning**
- `vm.max_map_count`, `vm.swappiness=1` and `tcp_retries2=5` are set.
- Swap is disabled and memory is locked.
- File and thread limits are raised.
- Time sync (chrony) is enabled.
- systemd service units are created.

**Memory**
- **Elasticsearch JVM heap** is sized from the VM's RAM: 50%, capped at 30 GB. After startup the script checks that compressed oops are still on.
- **Kibana heap** is configurable (for example 8 GB).

**Storage**
- **Custom Elasticsearch data directory**, created with `elasticsearch:elasticsearch` ownership and mode `750`. SELinux labels are set where applicable.

**Firewall**
- Only the required ports are opened in firewalld or ufw.
- Port 9300 is restricted to the Elasticsearch node IPs.

**Fleet**
- Fleet is configured automatically: the output points to all 3 nodes, the Fleet Server host is registered, and the Fleet Server policy is created.

**Stack Monitoring (optional)**
- Elastic Agent collects with the Elasticsearch and Kibana integrations.

**Downloads**
- Artifacts are verified with SHA-512.
- Air-gapped use is supported: place the archives next to the script.

---

## Requirements

**VMs (minimal sizing)**

| VM | Role | Suggested sizing |
|---|---|---|
| VM 1 | `es-first` | 4+ vCPU, 16 GB RAM, dedicated data disk |
| VM 2 | `es-join` | 4+ vCPU, 16 GB RAM, dedicated data disk |
| VM 3 | `es-join` | 4+ vCPU, 16 GB RAM, dedicated data disk |
| VM 4 | `kibana` | 2–4 vCPU, ≥ 10 GB RAM (for an 8 GB Kibana heap) |
| VM 5 | `fleet` | 2–4 vCPU, 8 GB RAM |

**Software and access**
- **Linux distribution:** one of these OS families:
  - `debian` (Debian/Ubuntu)
  - `rhel` (RHEL/Rocky/Alma/Oracle)
  - `suse` (SLES/openSUSE)
- **Base tools:** systemd, bash 4+, `curl`.
- **Privileges:** root via `sudo` on each VM.
- **Internet access to `artifacts.elastic.co`**, or the archives (`.tar.gz` + `.sha512`) placed next to the script.
- The Kibana VM needs access to `epr.elastic.co` for the integration packages.
- **Network:** the ports in the architecture table must be reachable between the VMs.
- **Same values on every VM:** stack version (default **9.5.5**), cluster name and `elastic` password.

---

## Roles

| Role | Run on | Purpose |
|---|---|---|
| `es-first` | Elasticsearch VM 1 | Bootstraps the cluster and sets the `elastic` password. Prints the **CA fingerprint** and a node **enrollment token**. |
| `token` | Elasticsearch VM 1 | Prints a fresh node enrollment token (valid 30 min, single use). |
| `es-join` | Elasticsearch VMs 2 and 3 | Joins the cluster with an enrollment token. |
| `kibana` | Kibana VM | Installs Kibana over HTTPS and configures Fleet. Optionally creates the Stack Monitoring policies. |
| `fleet` | Fleet Server VM | Installs Elastic Agent as Fleet Server. Prints the **Fleet CA fingerprint**. |
| `monitor` | ES VMs and Kibana VM | *Optional:* installs Elastic Agent for Stack Monitoring. |

Run `sudo ./elastic-node-setup.sh` with no options to choose the role from a menu.

---

## Installation steps

Example IPs used below: Elasticsearch `192.168.55.50–52`, Kibana `192.168.55.60`, Fleet `192.168.55.70`.

### Step 0 – Copy the script to every VM

```bash
for h in 192.168.55.50 192.168.55.51 192.168.55.52 192.168.55.60 192.168.55.70; do
  scp elastic-node-setup.sh <user>@$h:~/elastic-scripts/
done
# on each VM
chmod +x ~/elastic-scripts/elastic-node-setup.sh
```

If you're using a dedicated data disk on the Elasticsearch VMs, mount it first and add it to `/etc/fstab`.

### Step 1 – Elasticsearch node 1 (bootstrap)

```bash
cd ~/elastic-scripts
sudo ./elastic-node-setup.sh --role es-first
```

You will be asked for:
- hostname, IP and OS family
- stack version, cluster name and the `elastic` password
- the three Elasticsearch IPs
- the JVM heap
- the data directory
- whether to disable swap

**Record from the output** (also saved in `/root/elastic-es-first-summary.txt`):
- the **HTTP CA fingerprint**
- the **node enrollment token** for node 2

### Step 2 – Elasticsearch node 2 (join)

```bash
sudo ./elastic-node-setup.sh --role es-join
```

Paste the token from Step 1. Tokens expire after **30 minutes**.

> **Tip – avoid copy/paste issues:** save the token to a file on node 1 and pass the file instead:
> ```bash
> # node 1
> sudo ./elastic-node-setup.sh --role token | tail -2 | head -1 > node.token
> # node 2 (after copying node.token over)
> sudo ./elastic-node-setup.sh --role es-join --token-file node.token
> ```

### Step 3 – Elasticsearch node 3 (join with a new token)

```bash
# on node 1 – create a fresh token
sudo ./elastic-node-setup.sh --role token
# on node 3
sudo ./elastic-node-setup.sh --role es-join
```

### Step 4 – Kibana

```bash
sudo ./elastic-node-setup.sh --role kibana
```

You will be asked for:
- the Elasticsearch IPs
- the `elastic` password
- the **CA fingerprint** from Step 1
- the Fleet Server IP
- certificate choice: your own CA-signed certificate, or a local CA
- whether to create the Stack Monitoring policies
- the **Kibana heap** (e.g. `8192` for 8 GB)

**Record from the output** (also in `/root/elastic-kibana-summary.txt`):
- the Kibana URL
- the two Stack Monitoring enrollment tokens, if you enabled monitoring

### Step 5 – Fleet Server

```bash
sudo ./elastic-node-setup.sh --role fleet
```

Enter the Elasticsearch IPs, the `elastic` password and the **CA fingerprint** from Step 1.

**Record from the output** (also in `/root/elastic-fleet-summary.txt`):
- the **Fleet CA fingerprint**
- the CA file path (`/opt/elastic/fleet-server-certs/ca.crt`), which you'll distribute to agent hosts

### Step 6 – Stack Monitoring (optional)

Choose **one** method.

**A. Elastic Agent (recommended, future-proof).** Run on each Elasticsearch VM and on the Kibana VM:

```bash
sudo ./elastic-node-setup.sh --role monitor
```

Enter the Fleet Server IP, the Fleet CA fingerprint (Step 5) and the matching token from Step 4:
- the *Elasticsearch* token on the ES VMs
- the *Kibana* token on the Kibana VM

This method also collects host metrics and logs.

**B. Built-in collection (one command, no agents).** It is deprecated and will be removed in Elasticsearch 10.0. Run on any Elasticsearch node:

```bash
sudo curl --cacert /opt/elastic/elasticsearch/config/certs/http_ca.crt -u elastic \
  -X PUT "https://localhost:9200/_cluster/settings" -H 'Content-Type: application/json' \
  -d '{"persistent":{"xpack.monitoring.collection.enabled":true}}'
```

---

## Verify the installation

```bash
# Cluster nodes and health (on any ES node)
sudo curl --cacert /opt/elastic/elasticsearch/config/certs/http_ca.crt -u elastic \
  "https://localhost:9200/_cat/nodes?v"
sudo curl --cacert /opt/elastic/elasticsearch/config/certs/http_ca.crt -u elastic \
  "https://localhost:9200/_cluster/health?pretty"
```

Then:
1. Open `https://<kibana-ip>:5601` and log in as `elastic`.
2. In **Fleet → Agents**, the Fleet Server (and any monitoring agents) should be **Healthy**.
3. In **Stack Monitoring**, the cluster, nodes and Kibana should appear.

**Enrolling more agents:**
1. Get a token from **Fleet → Enrollment tokens**.
2. Copy the Fleet CA file `/opt/elastic/fleet-server-certs/ca.crt` to the agent host.
3. On the agent host run:

```bash
sudo ./elastic-agent install --url=https://<fleet-ip>:8220 \
     --enrollment-token=<TOKEN> --certificate-authorities=/path/to/ca.crt
```

---

## Command-line options

| Option | Description |
|---|---|
| `--role <role>` | `es-first`, `es-join`, `token`, `kibana`, `fleet` or `monitor`. If omitted, a menu is shown. |
| `--token-file <file>` | Read the enrollment token from a file (`es-join`, `monitor`). |
| `--token <value>` | Pass the enrollment token directly. |
| `ARTIFACT_DIR=<dir>` | Environment variable: where archives are looked up and downloaded to (default: the script's folder). |
| `-h`, `--help` | Show usage. |

---

## Files and directories

| Path | Content |
|---|---|
| `/opt/elastic/elasticsearch` → `elasticsearch-<ver>` | Elasticsearch binaries and config (`config/elasticsearch.yml`, `config/jvm.options.d/heap.options`) |
| Data directory (prompted, default `/var/lib/elasticsearch`) | Elasticsearch data |
| `/var/log/elasticsearch` | Elasticsearch logs (`<cluster>.log`) |
| `/opt/elastic/kibana` → `kibana-<ver>` | Kibana binaries and config (`kibana.yml`, `node.options`, keystore, `certs/`) |
| `/var/lib/kibana`, `/var/log/kibana` | Kibana data and logs |
| `/opt/elastic/local-ca` | Local CA (Kibana / Fleet VMs, when not using your own certificates) |
| `/opt/elastic/fleet-server-certs` | Fleet Server certificates and service token |
| `/opt/Elastic/Agent` | Elastic Agent (Fleet Server and monitoring agents) |
| `/root/elastic-<role>-summary.txt` | Values to carry to the next step |
| `/var/log/elastic-node-setup-<role>-<time>.log` | Full log of each run |

Services: `systemctl status elasticsearch | kibana | elastic-agent`

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Token "not valid / complete" | The token was cut off or wrapped when copied. Paste it again, or use `--token-file`. Tokens expire after 30 min, so create a new one with `--role token` on node 1. |
| Node does not join; node 1 log shows `Connection refused … :9300` | Node 1 cannot reach the joining node on 9300. The script binds the transport port to all interfaces automatically. Also check the joining VM's firewall allows 9300 from node 1. To test from node 1: `timeout 3 bash -c '</dev/tcp/<node-ip>/9300' && echo open` |
| Script stops with "already installed" | It performs fresh installs only. Remove the partial install (for Kibana: `/opt/elastic/kibana*`, `/var/lib/kibana`, `/var/log/kibana`, `kibana.service`) and run again. Downloaded archives next to the script are reused. |
| Kibana Stack Monitoring policies not created | The Kibana VM cannot reach `epr.elastic.co`. Allow it, or use monitoring method B. |
| Elasticsearch fails at start-up | Check `journalctl -u elasticsearch` and `/var/log/elasticsearch/<cluster>.log`. Common causes are bootstrap checks (memory lock, `vm.max_map_count`) or data directory permissions. |

---

## Notes and limitations

- **Fresh installs only.** The script doesn't upgrade or reconfigure existing installs.
- **Monitoring data location.** Stack Monitoring stores its data in the same cluster. For production, Elastic recommends a separate monitoring cluster.
- **Single instances.** Kibana and Fleet Server are single instances; add more behind a load balancer for high availability.
- **CA private keys.** Move the local CA private keys (`/opt/elastic/local-ca/ca.key`) offline, or use your corporate CA certificates.
- **Back up the Kibana keystore** (`/opt/elastic/kibana/config/kibana.keystore`). Losing its encryption keys makes Fleet and alerting objects unreadable.
