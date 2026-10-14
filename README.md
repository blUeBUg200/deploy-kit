# Installation Scripts

Production-ready installation scripts for data pipeline, observability and security platforms on Linux.

Each script turns a fresh server into a working, hardened node in a single run: it checks prerequisites, installs from the vendor's official package, applies operating-system best practices and verifies the result. The goal is the same outcome every time, whether you are building a one-node lab or adding the fiftieth node to a production cluster.

---

## Why these scripts

| | |
|---|---|
| **One file per product** | Each installer is a single, self-contained Bash script. Copy it to a server and run it. |
| **Autonomous** | Sensible defaults, interactive prompts only where a decision is genuinely needed, and no options required for the common path. |
| **Offline-ready** | Place the vendor package next to the script and it is used automatically. Nothing is downloaded unless you confirm the host has internet access. |
| **Safe to rerun** | Previous or partial installs are detected, stopped and backed up (or cleanly removed) before a fresh install. |
| **Hardened by default** | Dedicated non-root service account, systemd service with auto-restart, kernel and resource tuning, host firewall rules. |
| **Fails early and clearly** | Every check runs before the host is changed. When something is missing, the script says exactly what and how to fix it. |

---

## Repository layout

```
.
├── README.md                  ← you are here
├── <product-a>/
│   ├── <product-a>-deploy.sh  ← the installer
│   ├── README.md              ← what it does, what it covers, how to run it
│   ├── <product-a>-guide.docx ← the same guide as a Word document
│   └── diagram.excalidraw     ← architecture and install flow
├── <product-b>/
│   └── ...
└── LICENSE
```

Each product folder is independent. Start with that folder's `README.md`.

---

## Supported platforms

| Family | Distributions | CPU |
|---|---|---|
| Debian | Ubuntu, Debian | x86_64, aarch64 |
| Red Hat | RHEL, Rocky Linux, AlmaLinux, Oracle Linux, CentOS | x86_64, aarch64 |

Requirements common to all scripts: `systemd`, `bash` 4+, root or `sudo` access, and local disk for the install directory. Product-specific sizing is listed in each product's README.

---

## Quick start

```bash
# 1. Copy the product folder to the target server
scp -r <product>/ user@server:/tmp/

# 2. Optional, for offline hosts: put the vendor package in the same folder
#    (keep the vendor's original file name)

# 3. Check the host without changing anything
cd /tmp/<product> && chmod +x <product>-deploy.sh
sudo ./<product>-deploy.sh --precheck

# 4. Install
sudo ./<product>-deploy.sh
```

Run with no options for interactive prompts, or `--help` to see every option.

---

## How every script works

All installers follow the same stages, so once you have used one, the rest behave the same way.

| # | Stage | What happens |
|---|---|---|
| 1 | **Detect** | OS family, package manager and CPU architecture. |
| 2 | **Inputs** | Role and settings, from options or prompts. Secrets are generated when not supplied. |
| 3 | **Prerequisites** | Looks for the vendor package next to the script and for missing OS packages. If anything must be downloaded, asks once whether the host has internet. `n` stops with a precise list of what is required. |
| 4 | **Pre-flight** | CPU, memory, disk, filesystem type, hostname resolution and network reachability. |
| 5 | **Previous installs** | Detects full or partial installs, stops them, then backs them up (default) or removes them. |
| 6 | **Harden** | Service account, resource limits, kernel tuning, time synchronisation, SELinux labels where enforcing. |
| 7 | **Install** | Validates and installs the package, applies the role configuration, registers the systemd service. |
| 8 | **Firewall** | Opens only the ports the role needs, in `ufw` or `firewalld` if active. |
| 9 | **Verify** | Confirms the service is running and reachable, then prints a summary with next steps. |

Each run is logged to `/var/log/<product>-deploy.log`.

---

## Conventions

These apply to every script in the repository.

**Behaviour**
- Nothing on the host changes until every prerequisite check has passed.
- Downloads happen only after the user confirms internet access.
- A local vendor package always takes priority over a download.
- Reinstalls back up the previous installation by default.
- Unrelated processes, files and services are never touched.

**Common options**

| Option | Purpose |
|---|---|
| `--precheck` | Report on the host; change nothing. |
| `--yes` | Unattended run; answers yes to every question. |
| `--reinstall-mode backup\|clean` | What to do with a previous installation. |
| `--skip-firewall` | Leave host firewall rules unchanged. |
| `--skip-os-tuning` | Leave kernel and limit settings unchanged. |
| `--uninstall` | Stop, disable and remove the product. |
| `--help` | Show every option for that script. |

**Exit behaviour**
- Exit code `0` on success, non-zero on any failure.
- Every failure names the cause and the fix.

---

## What is out of scope

These scripts install and harden the platform. They do not:

- Configure data sources, destinations, pipelines or content.
- Create licenses, user accounts beyond the service account, or TLS certificates.
- Change infrastructure outside the host (cloud security groups, load balancers, network firewalls).
- Perform in-place upgrades with configuration migration.

Each product README lists its own specific limits.

---

## Contributing

New installers should match the existing ones so users get the same experience everywhere.

1. Create a folder named after the product.
2. Follow the nine stages and the conventions above.
3. Include a product `README.md` with these sections: what it does, what is covered, what is not covered, prerequisites, how to run, options, files changed, troubleshooting.
4. Pass `bash -n` and `shellcheck -S warning` with no findings.
5. Test on at least one Debian-family and one Red Hat-family host before opening a pull request.

---

## Disclaimer

These scripts are provided as-is, without warranty. Test in a non-production environment first and review each script before running it with root privileges. Product names and trademarks belong to their respective owners; this repository is not affiliated with or endorsed by any vendor.

## License

See [LICENSE](LICENSE).
