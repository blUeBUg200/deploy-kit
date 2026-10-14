#!/usr/bin/env bash
# =============================================================================
#  cribl-deploy.sh — Cribl Stream distributed deployment (tarball / bundle based)
# =============================================================================
#  Installs Cribl Stream from the official .tgz bundle (no RPM/DEB) on
#  Ubuntu/Debian and RHEL-family hosts, configures the node as a Leader or a
#  Worker, applies OS-level best practices, and registers it as a systemd
#  service running as a dedicated non-root user.
#
#  Reference: https://docs.cribl.io/stream/setting-up-leader-and-worker-nodes/
#             https://docs.cribl.io/stream/cli-mode-master/
#             https://docs.cribl.io/stream/cli-mode-worker/
#             https://docs.cribl.io/stream/os-tuning/
#
#  QUICK START
#  -----------
#   1) Leader  (prints the auth token + ready-made worker command at the end):
#        sudo ./cribl-deploy.sh --role leader
#
#   2) Worker  (repeat on every worker host; group defaults to "default"):
#        sudo ./cribl-deploy.sh --role worker \
#             --leader-host 10.0.0.10 --token <AUTH_TOKEN> [--group <group>]
#
#   Offline: put cribl-<ver>-<build>-linux-<arch>.tgz next to this script —
#   it is used automatically (no flags). Otherwise the latest is downloaded.
#
#   Run with no arguments on a terminal for interactive prompts.
#   Run with --help for every option.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# Defaults (override via flags or environment)
# ----------------------------------------------------------------------------
SCRIPT_VERSION="1.5.0"
ROLE="${ROLE:-}"                                  # leader | worker
INSTALL_PARENT="${INSTALL_PARENT:-/opt}"          # bundle is extracted here
CRIBL_HOME="${CRIBL_HOME:-${INSTALL_PARENT}/cribl}"
CRIBL_USER="${CRIBL_USER:-cribl}"
CRIBL_GROUP="${CRIBL_GROUP:-cribl}"

LEADER_HOST="${LEADER_HOST:-}"                    # worker: leader FQDN/IP
LEADER_BIND="${LEADER_BIND:-0.0.0.0}"             # leader: bind address
LEADER_PORT="${LEADER_PORT:-4200}"                # distributed mgmt port
UI_PORT="${UI_PORT:-9000}"                        # UI / API port
AUTH_TOKEN="${AUTH_TOKEN:-}"                      # shared leader/worker token
WORKER_GROUP="${WORKER_GROUP:-default}"
WORKER_TAGS="${WORKER_TAGS:-}"

TLS="${TLS:-false}"                               # leader<->worker TLS
TLS_CERT="${TLS_CERT:-}"
TLS_KEY="${TLS_KEY:-}"

PACKAGE_FILE=""                                   # set automatically: bundle next to the script, else download
DATA_PORTS="${DATA_PORTS:-}"                      # worker inbound ports to open, e.g. "9514/tcp,9514/udp,10080/tcp"

TUNE_OS="${TUNE_OS:-true}"
DISABLE_THP="${DISABLE_THP:-true}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-true}"
ALLOW_LOW_PORTS="${ALLOW_LOW_PORTS:-true}"        # cribl may bind <1024 (syslog 514, etc.) — default ON
NOFILE_LIMIT="${NOFILE_LIMIT:-65536}"
REINSTALL_MODE="${REINSTALL_MODE:-}"              # backup | clean (prompted on a TTY, else backup)
BACKUP_ROOT="${BACKUP_ROOT:-}"                    # default: <install-parent>/cribl-backups
FORCE="${FORCE:-false}"
SKIP_LEADER_CHECK="${SKIP_LEADER_CHECK:-false}"      # worker: install even if Leader:4200 is unreachable now
ASSUME_YES="${ASSUME_YES:-false}"
ACTION="install"                                  # install | uninstall | precheck

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/cribl-deploy.log"
TMP_DIR=""
OS_FAMILY=""; OS_ID=""; OS_VERSION=""; PKG_MGR=""; ARCH_TAG=""

# ----------------------------------------------------------------------------
# Logging helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi
ts()    { date '+%Y-%m-%d %H:%M:%S'; }
info()  { printf '%s %s[INFO]%s  %s\n'  "$(ts)" "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s %s[ OK ]%s  %s\n'  "$(ts)" "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s %s[WARN]%s  %s\n'  "$(ts)" "$C_YEL" "$C_RST" "$*" >&2; }
die()   { printf '%s %s[FAIL]%s  %s\n'  "$(ts)" "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step()  { printf '\n%s==> %s%s\n' "$C_BLU" "$*" "$C_RST"; }

on_error() {
  local rc=$? line=${1:-?}
  printf '%s %s[FAIL]%s  Aborted at line %s (exit %s). See %s\n' \
    "$(ts)" "$C_RED" "$C_RST" "$line" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}
cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; return 0; }
trap 'on_error $LINENO' ERR
trap cleanup EXIT

is_true() { [[ "${1,,}" =~ ^(true|yes|y|1)$ ]]; }
have()    { command -v "$1" >/dev/null 2>&1; }
join_by() { local sep="$1"; shift; local out="" x; for x in "$@"; do out+="${out:+$sep}$x"; done; printf "%s" "${out:-none}"; }

# ----------------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------------
usage() {
  cat <<EOF
cribl-deploy.sh v${SCRIPT_VERSION} — tarball-based Cribl Stream Leader/Worker deployment

USAGE
  sudo $0 --role leader [options]
  sudo $0 --role worker --leader-host <host> --token <token> [--group <name>] [options]
  sudo $0 --precheck
  sudo $0 --uninstall [--yes]

ROLE / TOPOLOGY
  --role <leader|worker>     Node role (prompted if omitted on a terminal)
  --leader-host <host>       Worker: Leader FQDN or IP (required for worker)
  --leader-bind <addr>       Leader: address to bind port ${LEADER_PORT} (default ${LEADER_BIND})
  --leader-port <port>       Distributed management port (default ${LEADER_PORT})
  --ui-port <port>           UI/API port, used for firewall + health checks (default ${UI_PORT})
  --token <token>            Shared auth token. Leader: auto-generated if omitted.
  --group <name>             Worker Group to join (default: default)
  --tags <t1,t2>             Worker tags reported to the Leader
  --skip-leader-check        Worker: install even if Leader:4200 is not reachable yet

TLS (Leader <-> Worker)
  --tls                      Enable TLS on the distributed channel
  --tls-cert <path>          Leader: PEM certificate (required with --tls on leader)
  --tls-key <path>           Leader: PEM private key  (required with --tls on leader)

PREREQUISITES  (automatic — no options)
  Checked first, before anything on the host is changed:
  * Cribl bundle: cribl-<ver>-<build>-linux-<arch>.tgz in the same directory as
    this script is used as-is (newest version if several). Nothing is downloaded.
  * If the bundle is not there and/or OS packages are missing, the script lists
    what it needs and asks once: "Does this host have internet access to
    download them? [y/n]"
      y  missing OS packages are installed, the bundle is downloaded
      n  the script stops and states which packages / that the Cribl package
         is required to proceed

OTHER
  --force                    Continue even if a non-Cribl process holds port ${UI_PORT}/${LEADER_PORT}
  --yes                      Non-interactive; assume yes to confirmations
  --precheck                 Only run system checks, change nothing
  --uninstall                Stop, disable and remove Cribl from this host
  -h, --help                 Show this help

EXAMPLES
  sudo $0 --role leader
  sudo $0 --role worker --leader-host leader01.corp.local --token 'S3cr3t' --group syslog-dmz \\
       --data-ports "514/udp,514/tcp,9514/tcp"
  sudo $0 --role leader --reinstall-mode clean --yes      # wipe a broken/partial install, reinstall
EOF
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)            ROLE="${2:-}"; shift 2 ;;
      --leader-host)     LEADER_HOST="${2:-}"; shift 2 ;;
      --leader-bind)     LEADER_BIND="${2:-}"; shift 2 ;;
      --leader-port)     LEADER_PORT="${2:-}"; shift 2 ;;
      --ui-port)         UI_PORT="${2:-}"; shift 2 ;;
      --token)           AUTH_TOKEN="${2:-}"; shift 2 ;;
      --group)           WORKER_GROUP="${2:-}"; shift 2 ;;
      --tags)            WORKER_TAGS="${2:-}"; shift 2 ;;
      --tls)             TLS=true; shift ;;
      --tls-cert)        TLS_CERT="${2:-}"; shift 2 ;;
      --tls-key)         TLS_KEY="${2:-}"; shift 2 ;;
      --install-dir)     INSTALL_PARENT="${2%/}"; CRIBL_HOME="${INSTALL_PARENT}/cribl"; shift 2 ;;
      --user)            CRIBL_USER="${2:-}"; CRIBL_GROUP="${2:-}"; shift 2 ;;
      --data-ports)      DATA_PORTS="${2:-}"; shift 2 ;;
      --allow-low-ports) ALLOW_LOW_PORTS=true; shift ;;   # kept for compatibility (default)
      --no-low-ports)    ALLOW_LOW_PORTS=false; shift ;;
      --reinstall-mode)  REINSTALL_MODE="${2:-}"; shift 2 ;;
      --backup-dir)      BACKUP_ROOT="${2%/}"; shift 2 ;;
      --nofile)          NOFILE_LIMIT="${2:-}"; shift 2 ;;
      --skip-os-tuning)  TUNE_OS=false; shift ;;
      --keep-thp)        DISABLE_THP=false; shift ;;
      --skip-firewall)   CONFIGURE_FIREWALL=false; shift ;;
      --force)           FORCE=true; shift ;;
      --yes|-y)          ASSUME_YES=true; shift ;;
      --precheck)        ACTION="precheck"; shift ;;
      --skip-leader-check) SKIP_LEADER_CHECK=true; shift ;;
      --uninstall)       ACTION="uninstall"; shift ;;
      -h|--help)         usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# Interactive prompts (only when attached to a terminal and value missing)
# ----------------------------------------------------------------------------
ask() { # ask <var> <prompt> [default] [secret]
  local __var="$1" __prompt="$2" __def="${3:-}" __secret="${4:-false}" __val=""
  local __hint=""; [[ -n "$__def" ]] && __hint=" [${__def}]"
  if is_true "$__secret"; then
    read -r -s -p "${__prompt}${__hint}: " __val </dev/tty; echo
  else
    read -r -p "${__prompt}${__hint}: " __val </dev/tty
  fi
  printf -v "$__var" '%s' "${__val:-$__def}"
}

collect_inputs() {
  local interactive=false
  [[ -t 0 ]] && ! is_true "$ASSUME_YES" && interactive=true

  if [[ -z "$ROLE" ]]; then
    $interactive || die "--role is required (leader|worker)"
    echo "Select node role:"; echo "  1) Leader"; echo "  2) Worker"
    local choice; ask choice "Choice" "1"
    case "$choice" in 1|leader|Leader) ROLE=leader ;; 2|worker|Worker) ROLE=worker ;; *) die "Invalid choice" ;; esac
  fi
  ROLE="${ROLE,,}"
  [[ "$ROLE" == "leader" || "$ROLE" == "worker" ]] || die "--role must be 'leader' or 'worker'"

  if [[ "$ROLE" == "worker" ]]; then
    if [[ -z "$LEADER_HOST" ]]; then
      $interactive || die "--leader-host is required for a worker"
      ask LEADER_HOST "Leader hostname or IP"
    fi
    if [[ -z "$AUTH_TOKEN" ]]; then
      $interactive || die "--token is required for a worker"
      ask AUTH_TOKEN "Leader auth token" "" true
    fi
    if $interactive && [[ "$WORKER_GROUP" == "default" ]]; then
      ask WORKER_GROUP "Worker Group" "default"
    fi
    [[ -n "$LEADER_HOST" ]] || die "Leader host cannot be empty"
    [[ -n "$AUTH_TOKEN"  ]] || die "Auth token cannot be empty"
  fi

  if [[ "$ROLE" == "leader" && -z "$AUTH_TOKEN" ]]; then
    AUTH_TOKEN="$(generate_token)"
    info "Generated a random auth token for the Leader."
  fi

  if [[ "$AUTH_TOKEN" == "criblmaster" ]]; then
    die "Refusing to use the well-known default token 'criblmaster'. Supply a unique --token."
  fi
  [[ "$WORKER_GROUP" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid group name '$WORKER_GROUP' (letters, digits, _ and - only)"
  [[ "$LEADER_PORT" =~ ^[0-9]+$ && "$UI_PORT" =~ ^[0-9]+$ ]] || die "Ports must be numeric"

  if is_true "$TLS" && [[ "$ROLE" == "leader" ]]; then
    [[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] || die "--tls on the Leader needs --tls-cert and --tls-key (PEM files)"
  fi
}

generate_token() {
  if have openssl; then openssl rand -hex 24
  else { tr -dc 'A-Za-z0-9' </dev/urandom || true; } | head -c 48; fi
}

# ----------------------------------------------------------------------------
# Platform detection
# ----------------------------------------------------------------------------
require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

detect_os() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-}"
  local like="${ID_LIKE:-}"
  case "$OS_ID" in
    ubuntu|debian) OS_FAMILY=debian ;;
    rhel|centos|rocky|almalinux|ol|fedora|amzn) OS_FAMILY=rhel ;;
    *)
      if   [[ "$like" == *debian* ]]; then OS_FAMILY=debian
      elif [[ "$like" == *rhel* || "$like" == *fedora* ]]; then OS_FAMILY=rhel
      else die "Unsupported OS: $OS_ID (supported: Ubuntu/Debian, RHEL/Rocky/Alma/Oracle/CentOS)"; fi ;;
  esac
  if [[ "$OS_FAMILY" == "debian" ]]; then PKG_MGR=apt-get
  elif have dnf; then PKG_MGR=dnf
  else PKG_MGR=yum; fi
  ok "OS: ${PRETTY_NAME:-$OS_ID $OS_VERSION} (family: $OS_FAMILY, pkg: $PKG_MGR)"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   ARCH_TAG=x64 ;;
    aarch64|arm64)  ARCH_TAG=arm64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  ok "Architecture: $(uname -m) (bundle: linux-${ARCH_TAG})"
}

# ----------------------------------------------------------------------------
# Pre-flight checks (warn-only for sizing; fail for hard blockers)
# ----------------------------------------------------------------------------
precheck() {
  step "Pre-flight checks"
  local cpus mem_gb disk_gb
  cpus=$(nproc)
  mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  mkdir -p "$INSTALL_PARENT"
  disk_gb=$(df -Pk "$INSTALL_PARENT" | awk 'NR==2 {printf "%d", $4/1024/1024}')

  info "CPU cores: $cpus | RAM: ${mem_gb} GB | Free disk on ${INSTALL_PARENT}: ${disk_gb} GB"
  (( cpus   >= 4 ))  || warn "Fewer than 4 vCPUs — fine for a lab, undersized for production."
  (( mem_gb >= 8 ))  || warn "Less than 8 GB RAM — fine for a lab, undersized for production."
  (( disk_gb >= 5 )) || die  "Less than 5 GB free on ${INSTALL_PARENT}."

  # Install dir must be on local disk, not NFS/EFS (Cribl requirement)
  local fstype; fstype=$(df -PT "$INSTALL_PARENT" | awk 'NR==2 {print $2}')
  case "$fstype" in nfs*|cifs|smb*|fuse.*|efs) die "${INSTALL_PARENT} is on network storage ($fstype). Cribl requires fast local disk." ;; esac
  ok "Install filesystem: $fstype"

  have systemctl || die "systemd is required."

  # Hostname sanity: workers are identified by hostname on the Leader
  local hn; hn=$(hostname -f 2>/dev/null || hostname)
  getent hosts "$hn" >/dev/null 2>&1 || warn "Hostname '$hn' does not resolve locally — add it to DNS or /etc/hosts."

  # Previous / partial install (handled later by handle_existing_install)
  if detect_existing_install; then
    warn "Previous or partial Cribl install detected:"
    local a; for a in "${EXISTING_ITEMS[@]}"; do warn "   - $a"; done
  fi

  # Worker -> Leader reachability
  if [[ "$ROLE" == "worker" && -n "$LEADER_HOST" ]]; then
    check_leader_reachable
  fi
  ok "Pre-flight checks passed."
}

# Probe Leader:4200 from the worker and explain *why* it fails, not just that it did.
check_leader_reachable() {
  local err="" rc=0 reason=""
  err="$(timeout 5 bash -c "exec 3<>/dev/tcp/${LEADER_HOST}/${LEADER_PORT}" 2>&1)" || rc=$?
  if (( rc == 0 )); then ok "Leader ${LEADER_HOST}:${LEADER_PORT} is reachable."; return 0; fi

  if   (( rc == 124 ));                                then reason="TIMEOUT — no reply in 5s. A firewall is silently DROPPING traffic (Leader ufw/firewalld/iptables, hypervisor or cloud security group, network ACL)."
  elif [[ "$err" == *"refused"* ]];                    then reason="CONNECTION REFUSED — the Leader host answered, but nothing is listening on ${LEADER_PORT}. Most likely the Cribl Leader service is not running or not in leader mode (or a firewall REJECT rule)."
  elif [[ "$err" == *"No route to host"* ]];           then reason="NO ROUTE TO HOST — either a routing problem, or a firewall REJECTing with icmp-host-prohibited (firewalld's default behaviour)."
  elif [[ "$err" == *"Name or service not known"* || "$err" == *"resolve"* ]]; then reason="DNS — '${LEADER_HOST}' does not resolve from this worker. Use the IP or fix DNS / /etc/hosts."
  elif [[ "$err" == *"unreachable"* ]];                then reason="NETWORK UNREACHABLE — this worker has no route to the Leader's subnet."
  else reason="${err:-unknown error (exit $rc)}"; fi

  warn "Cannot connect to Leader ${LEADER_HOST}:${LEADER_PORT}"
  warn "Reason: ${reason}"
  [[ -n "$err" ]] && warn "Raw:    ${err##*: }"
  cat >&2 <<EOF

  Check on the LEADER (${LEADER_HOST}):
      sudo systemctl status cribl                 # service running?
      sudo ss -ltnp | grep ':${LEADER_PORT}'               # listening on 0.0.0.0:${LEADER_PORT}?
      sudo grep -A3 '^distributed' /opt/cribl/local/_system/instance.yml   # mode: master?
      sudo ufw status  ||  sudo firewall-cmd --list-ports
  Check from this WORKER:
      nc -vz ${LEADER_HOST} ${LEADER_PORT}
      ip route get ${LEADER_HOST}

EOF
  if is_true "$SKIP_LEADER_CHECK"; then
    warn "--skip-leader-check given: continuing. The worker will keep retrying the Leader after install."
    return 0
  fi
  if [[ -t 0 ]] && ! is_true "$ASSUME_YES"; then
    if ask_yes_no "  Continue installing anyway? (the worker keeps retrying until the Leader is reachable)"; then
      warn "Continuing without Leader connectivity."
      return 0
    fi
  fi
  die "Leader not reachable. Fix the cause above and re-run, or add --skip-leader-check to install now and connect later."
}

# ----------------------------------------------------------------------------
# Previous / partial install handling
# ----------------------------------------------------------------------------
EXISTING_ITEMS=()
UNIT_PATHS=(/etc/systemd/system/cribl.service /etc/systemd/system/cribl.service.d
            /lib/systemd/system/cribl.service /usr/lib/systemd/system/cribl.service
            /etc/systemd/system/multi-user.target.wants/cribl.service /etc/init.d/cribl)

# PIDs whose executable IS a Cribl binary (matched on /proc/<pid>/exe, never on the
# command line, so shells/editors that merely mention the path are never touched)
cribl_pids() {
  local d exe
  for d in /proc/[0-9]*; do
    exe="$(readlink "$d/exe" 2>/dev/null)" || continue
    case "$exe" in
      "${CRIBL_HOME}/bin/cribl"|"${CRIBL_HOME}/bin/cribl (deleted)"|*/cribl/bin/cribl|*"/cribl/bin/cribl (deleted)")
        echo "${d#/proc/}" ;;
    esac
  done
}

cribl_pkg_installed() { # prints the package manager that owns a 'cribl' package, if any
  if have dpkg && dpkg -s cribl >/dev/null 2>&1; then echo dpkg
  elif have rpm && rpm -q cribl >/dev/null 2>&1; then echo rpm; fi
}

detect_existing_install() {
  EXISTING_ITEMS=()
  [[ -e "$CRIBL_HOME" ]] && EXISTING_ITEMS+=("install directory: $CRIBL_HOME")
  local f; for f in "${UNIT_PATHS[@]}"; do
    [[ -e "$f" || -L "$f" ]] && EXISTING_ITEMS+=("service file: $f")
  done
  local pids; pids="$(cribl_pids)"
  [[ -n "$pids" ]] && EXISTING_ITEMS+=("running cribl processes: $(echo "$pids" | tr '\n' ' ')")
  local pkg; pkg="$(cribl_pkg_installed)"
  [[ -n "$pkg" ]] && EXISTING_ITEMS+=("OS package 'cribl' registered in $pkg")
  (( ${#EXISTING_ITEMS[@]} > 0 ))
}

stop_cribl_processes() {
  systemctl stop cribl >/dev/null 2>&1 || true
  if [[ -x "${CRIBL_HOME}/bin/cribl" ]]; then
    "${CRIBL_HOME}/bin/cribl" stop >/dev/null 2>&1 || true
  fi
  local pids _; pids="$(cribl_pids)"
  [[ -z "$pids" ]] && return 0
  info "Stopping leftover cribl processes: $(echo "$pids" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  for _ in $(seq 1 20); do [[ -z "$(cribl_pids)" ]] && return 0; sleep 1; done
  pids="$(cribl_pids)"
  if [[ -n "$pids" ]]; then
    warn "Force-killing: $(echo "$pids" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
    sleep 2
  fi
  [[ -z "$(cribl_pids)" ]] || die "Could not stop existing cribl processes."
}

handle_existing_install() {
  step "Checking for previous / partial installs"
  if ! detect_existing_install; then ok "None found — clean host."; return 0; fi

  local a; for a in "${EXISTING_ITEMS[@]}"; do info "Found $a"; done

  if [[ -z "$REINSTALL_MODE" ]]; then
    if [[ -t 0 ]] && ! is_true "$ASSUME_YES"; then
      echo "A previous or partial install exists. How should it be handled?"
      echo "  1) Back up, then install fresh (recommended)"
      echo "  2) Delete it, then install fresh"
      echo "  3) Abort"
      local c; ask c "Choice" "1"
      case "$c" in 1) REINSTALL_MODE=backup ;; 2) REINSTALL_MODE=clean ;; *) die "Aborted by user." ;; esac
    else
      REINSTALL_MODE=backup
    fi
  fi
  REINSTALL_MODE="${REINSTALL_MODE,,}"
  [[ "$REINSTALL_MODE" == "backup" || "$REINSTALL_MODE" == "clean" ]] \
    || die "--reinstall-mode must be 'backup' or 'clean'"
  info "Reinstall mode: $REINSTALL_MODE"

  # 1) Stop and unregister the old service, kill stragglers
  stop_cribl_processes
  if [[ -x "${CRIBL_HOME}/bin/cribl" ]]; then
    "${CRIBL_HOME}/bin/cribl" boot-start disable -m systemd >/dev/null 2>&1 || true
  fi
  systemctl disable cribl >/dev/null 2>&1 || true

  # 2) Back up or delete the old files
  local bdir=""
  if [[ "$REINSTALL_MODE" == "backup" ]]; then
    bdir="${BACKUP_ROOT:-${INSTALL_PARENT}/cribl-backups}/cribl-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${bdir}/systemd"; chmod 700 "$(dirname "$bdir")" "$bdir"
    [[ -e "$CRIBL_HOME" ]] && mv "$CRIBL_HOME" "${bdir}/cribl"
    local f; for f in "${UNIT_PATHS[@]}" /etc/sysctl.d/99-cribl.conf /etc/sysctl.d/99-cribl-conntrack.conf \
                     /etc/security/limits.d/99-cribl.conf; do
      [[ -e "$f" ]] && cp -a "$f" "${bdir}/systemd/" 2>/dev/null || true
    done
    ok "Backed up previous install to ${bdir}"
  else
    rm -rf "$CRIBL_HOME"
    ok "Deleted ${CRIBL_HOME}"
  fi

  # 3) Remove service definitions so boot-start writes a fresh unit
  rm -rf "${UNIT_PATHS[@]}"
  systemctl daemon-reload || warn "systemctl daemon-reload failed."
  systemctl reset-failed cribl >/dev/null 2>&1 || true

  # 4) Deregister any RPM/DEB 'cribl' package left from an earlier package-based attempt
  case "$(cribl_pkg_installed)" in
    dpkg) apt-get purge -y -qq cribl >/dev/null 2>&1 || dpkg --remove --force-all cribl >/dev/null 2>&1 || warn "Could not purge DEB package 'cribl'." ;;
    rpm)  $PKG_MGR remove -y -q cribl >/dev/null 2>&1 || rpm -e --noscripts cribl >/dev/null 2>&1 || warn "Could not remove RPM package 'cribl'." ;;
  esac

  # 5) Stale temp downloads from interrupted runs
  rm -rf /tmp/cribl-deploy.* 2>/dev/null || true

  detect_existing_install && die "Leftovers remain after cleanup: $(join_by "; " "${EXISTING_ITEMS[@]}")"
  ok "Host is clean — proceeding with a fresh install."
}

check_ports() {
  step "Port availability"
  local p owner ports=("$UI_PORT"); [[ "$ROLE" == "leader" ]] && ports+=("$LEADER_PORT")
  for p in "${ports[@]}"; do
    if ss -ltn "( sport = :$p )" 2>/dev/null | grep LISTEN >/dev/null; then
      owner="$(ss -ltnpH "( sport = :$p )" 2>/dev/null | grep -o 'users:(([^)]*' | head -1 | sed 's/users:((//' || true)"
      is_true "$FORCE" || die "Port $p is in use by a non-Cribl process (${owner:-unknown}). Free it or use --force."
      warn "Port $p in use by ${owner:-unknown} (continuing due to --force)."
    fi
  done
  ok "Ports free: $(join_by " " "${ports[@]}")"
}

# ----------------------------------------------------------------------------
# Packages
# ----------------------------------------------------------------------------
MISSING_PKGS=(); DEP_REQS=()

ask_yes_no() { # ask_yes_no <prompt>  -> returns 0 for yes, 1 for no
  local ans
  while true; do
    read -r -p "$1 [y/n]: " ans </dev/tty
    case "${ans,,}" in y|yes) return 0 ;; n|no) return 1 ;; *) echo "Please answer y or n." ;; esac
  done
}

selinux_active() { [[ "$OS_FAMILY" == "rhel" && "$(getenforce 2>/dev/null || echo Disabled)" != "Disabled" ]]; }

time_sync_present() {
  have chronyd && return 0
  local s; for s in systemd-timesyncd ntpd ntp; do systemctl is-active --quiet "$s" 2>/dev/null && return 0; done
  return 1
}

# Map a requirement to the package that provides it on this OS family
pkg_for() {
  local req="$1" major="${OS_VERSION%%.*}"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    case "$req" in
      ss) echo iproute2 ;; pgrep) echo procps ;; ca-certs) echo ca-certificates ;; chronyd) echo chrony ;;
      *) echo "$req" ;;
    esac
  else
    case "$req" in
      ss) echo iproute ;; pgrep) echo procps-ng ;; ca-certs) echo ca-certificates ;; chronyd) echo chrony ;;
      restorecon) echo policycoreutils ;;
      semanage) if [[ "$major" =~ ^[0-9]+$ ]] && (( major < 8 )); then echo policycoreutils-python
                else echo policycoreutils-python-utils; fi ;;
      *) echo "$req" ;;
    esac
  fi
}

req_present() {
  case "$1" in
    ca-certs) [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/pki/tls/certs/ca-bundle.crt ]] ;;
    chronyd)  time_sync_present ;;
    *)        have "$1" ;;
  esac
}

# Initial-stage prerequisite check, fully autonomous (no options):
#   * Cribl bundle in the script's directory  -> use it, no download.
#   * Bundle missing and/or OS packages missing -> list what is needed and ask ONE
#     question: "Does this host have internet access to download them? [y/n]"
#       y -> missing packages are installed now; the bundle is downloaded later.
#       n -> stop, stating exactly which packages / the Cribl package are required.
BUNDLE_SOURCE=""          # local | download

check_prerequisites() {
  step "Checking prerequisites (OS packages + Cribl bundle)"

  # Base tools every supported server ships with; cannot sensibly be auto-installed
  local c base_missing=()
  for c in awk sed grep df nproc getent useradd groupadd runuser timeout readlink sort systemctl; do
    have "$c" || base_missing+=("$c")
  done
  (( ${#base_missing[@]} == 0 )) \
    || die "Core system commands missing: $(join_by " " "${base_missing[@]}"). Not a standard ${OS_FAMILY} server install."

  # 1) Cribl bundle
  report_unusable_bundles
  PACKAGE_FILE="$(find_local_bundle)"
  if [[ -n "$PACKAGE_FILE" ]]; then
    BUNDLE_SOURCE=local
    ok "Cribl bundle: $(basename "$PACKAGE_FILE") found next to the script — will be used, nothing downloaded."
  else
    BUNDLE_SOURCE=download
    warn "Cribl bundle: no cribl-<ver>-<build>-linux-${ARCH_TAG}.tgz in ${SCRIPT_DIR}"
  fi

  # 2) OS packages this run needs
  local reqs=(tar gzip ss pgrep openssl ca-certs chronyd)
  [[ "$BUNDLE_SOURCE" == "download" ]] && reqs+=(curl)   # curl only needed to download
  [[ "$ROLE" == "leader" ]] && reqs+=(git)                # Leader needs git for commit/deploy
  selinux_active && reqs+=(restorecon semanage)           # label /opt/cribl/bin for systemd

  DEP_REQS=("${reqs[@]}")
  local r pkg present=()
  MISSING_PKGS=()
  for r in "${reqs[@]}"; do
    pkg="$(pkg_for "$r")"
    if req_present "$r"; then present+=("$pkg")
    else [[ " ${MISSING_PKGS[*]} " == *" $pkg "* ]] || MISSING_PKGS+=("$pkg"); fi
  done
  ok "OS packages present: $(join_by " " "${present[@]}")"
  (( ${#MISSING_PKGS[@]} > 0 )) && warn "OS packages missing: $(join_by " " "${MISSING_PKGS[@]}")"

  # 3) Nothing to download -> proceed
  if (( ${#MISSING_PKGS[@]} == 0 )) && [[ "$BUNDLE_SOURCE" == "local" ]]; then
    ok "All prerequisites available locally — no internet access needed."
    return 0
  fi
  [[ "$ACTION" == "precheck" ]] && { info "Precheck only — nothing downloaded or installed."; return 0; }

  # 4) Ask once whether we can download what is missing
  echo
  echo "  The following must be downloaded from the internet:"
  (( ${#MISSING_PKGS[@]} > 0 )) && echo "    - OS packages: $(join_by " " "${MISSING_PKGS[@]}")  (from the ${PKG_MGR} repositories)"
  [[ "$BUNDLE_SOURCE" == "download" ]] && echo "    - Cribl Stream package: latest linux-${ARCH_TAG} bundle from cdn.cribl.io"
  echo

  local internet=no
  if is_true "$ASSUME_YES"; then
    internet=yes; info "--yes given: assuming internet access."
  elif [[ -t 0 ]]; then
    ask_yes_no "  Does this host have internet access to download them?" && internet=yes
  else
    warn "No terminal to ask on — treating as 'no internet'."
  fi

  if [[ "$internet" != "yes" ]]; then
    stop_missing_prerequisites
  fi

  (( ${#MISSING_PKGS[@]} > 0 )) && install_missing_packages
  [[ "$BUNDLE_SOURCE" == "download" ]] && info "Cribl bundle will be downloaded from cdn.cribl.io."
  return 0
}

# User answered 'n' (or no terminal): explain exactly what is required, then stop.
stop_missing_prerequisites() {
  echo
  if (( ${#MISSING_PKGS[@]} > 0 )); then
    warn "These OS packages are required to proceed: $(join_by " " "${MISSING_PKGS[@]}")"
    manual_install_hint
  fi
  if [[ "$BUNDLE_SOURCE" == "download" ]]; then
    warn "The Cribl Stream package is required to proceed."
    echo "  Copy the bundle into the same directory as this script, keeping its original name:"
    echo "      ${SCRIPT_DIR}/cribl-<version>-<build>-linux-${ARCH_TAG}.tgz"
    echo "  (download it on a connected machine from https://cribl.io/download)"
    echo
  fi
  die "Required prerequisites are missing. Provide them as shown above and re-run the script."
}

manual_install_hint() {
  local list; list="$(join_by " " "${MISSING_PKGS[@]}")"
  echo
  echo "  Install these packages manually, then re-run the script:"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    echo "      sudo apt-get install -y ${list}"
    echo "  Fully offline? On a connected Ubuntu host of the same release:"
    echo "      apt-get download ${list}     # copy the .deb files over, then: sudo apt-get install ./*.deb"
  else
    echo "      sudo ${PKG_MGR} install -y ${list}"
    echo "  Fully offline? On a connected host of the same RHEL release:"
    echo "      ${PKG_MGR} download --resolve ${list}   # copy the .rpm files over, then: sudo ${PKG_MGR} install ./*.rpm"
  fi
  echo
}

install_missing_packages() {
  step "Installing missing packages from OS repositories"
  local list; list="$(join_by " " "${MISSING_PKGS[@]}")"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    info "Refreshing package index (apt-get update)..."
    timeout 180 apt-get update -qq >/dev/null 2>&1 \
      || { manual_install_hint; die "Cannot reach the apt repositories. These OS packages are required to proceed: ${list}"; }
    apt-get install -y -qq "${MISSING_PKGS[@]}" >/dev/null 2>&1 \
      || { manual_install_hint; die "apt-get could not install: ${list}"; }
  else
    info "Refreshing repository metadata (${PKG_MGR} makecache)..."
    timeout 300 "$PKG_MGR" -q makecache >/dev/null 2>&1 \
      || { manual_install_hint; die "Cannot reach the ${PKG_MGR} repositories (check subscription, proxy, DNS). These OS packages are required to proceed: ${list}"; }
    "$PKG_MGR" install -y -q "${MISSING_PKGS[@]}" >/dev/null 2>&1 \
      || { manual_install_hint; die "${PKG_MGR} could not install: ${list}"; }
  fi

  # Re-verify
  local r still=()
  for r in "${DEP_REQS[@]}"; do req_present "$r" || still+=("$(pkg_for "$r")"); done
  (( ${#still[@]} == 0 )) || die "Still missing after install: $(join_by " " "${still[@]}")"
  ok "Installed: ${list}"
}

configure_time_sync() {
  step "Time synchronisation"
  local s
  for s in systemd-timesyncd ntpd ntp; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then ok "Using existing time sync service: $s"; return 0; fi
  done
  if have chronyd; then
    s=chronyd; [[ "$OS_FAMILY" == "debian" ]] && s=chrony
    systemctl enable --now "$s" >/dev/null 2>&1 || warn "Could not enable $s."
    ok "Time sync service: $s ($(systemctl is-active "$s" 2>/dev/null || echo unknown))"
  else
    warn "No time sync service found — Leader and Worker clocks must agree. Configure NTP."
  fi
}

# ----------------------------------------------------------------------------
# Service account
# ----------------------------------------------------------------------------
create_user() {
  step "Service account"
  getent group "$CRIBL_GROUP" >/dev/null || groupadd --system "$CRIBL_GROUP"
  if ! id "$CRIBL_USER" >/dev/null 2>&1; then
    useradd --system --gid "$CRIBL_GROUP" --home-dir "$CRIBL_HOME" \
            --no-create-home --shell /sbin/nologin --comment "Cribl Stream" "$CRIBL_USER"
    ok "Created system user '$CRIBL_USER' (no login shell)"
  else
    ok "User '$CRIBL_USER' already exists"
  fi
}

# ----------------------------------------------------------------------------
# OS tuning (Cribl OS-tuning guidance + common Linux practice)
# ----------------------------------------------------------------------------
tune_os() {
  is_true "$TUNE_OS" || { warn "Skipping OS tuning (--skip-os-tuning)."; return 0; }
  step "OS tuning"

  # Process limits for the service account (systemd unit gets its own drop-in too)
  cat > /etc/security/limits.d/99-cribl.conf <<EOF
# Managed by cribl-deploy.sh
${CRIBL_USER}  soft  nofile  ${NOFILE_LIMIT}
${CRIBL_USER}  hard  nofile  ${NOFILE_LIMIT}
${CRIBL_USER}  soft  nproc   16384
${CRIBL_USER}  hard  nproc   16384
EOF

  # Kernel / network settings
  cat > /etc/sysctl.d/99-cribl.conf <<'EOF'
# Managed by cribl-deploy.sh — Cribl Stream host tuning
fs.file-max = 2097152
vm.swappiness = 10
vm.max_map_count = 262144
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF

  if [[ "$ROLE" == "worker" ]]; then
    # Larger socket buffers for UDP-heavy ingest (syslog, NetFlow) — Cribl suggests ~25 MB
    cat >> /etc/sysctl.d/99-cribl.conf <<'EOF'
# Worker: socket buffers for high-rate UDP/TCP ingest
net.core.rmem_max = 26214400
net.core.rmem_default = 26214400
net.core.wmem_max = 16777216
net.ipv4.udp_mem = 65536 131072 262144
EOF
    # Connection tracking table (only if netfilter conntrack is loaded)
    if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
      cat > /etc/sysctl.d/99-cribl-conntrack.conf <<'EOF'
# Worker: avoid "nf_conntrack: table full, dropping packet" under many connections
net.netfilter.nf_conntrack_max = 2097152
EOF
    fi
  fi
  sysctl --system >/dev/null 2>&1 || warn "Some sysctl keys were not accepted by this kernel."
  ok "Applied sysctl + limits (see /etc/sysctl.d/99-cribl*.conf)"

  # Transparent Huge Pages -> 'never' (general practice for latency-sensitive data services)
  if is_true "$DISABLE_THP" && [[ -e /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (cribl-deploy)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=cribl.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
    systemctl daemon-reload
    systemctl enable --now disable-thp.service >/dev/null 2>&1 || warn "Could not disable THP."
    ok "Transparent Huge Pages disabled (persistent)"
  fi
}

# ----------------------------------------------------------------------------
# Bundle download / extraction
# ----------------------------------------------------------------------------
# Newest Cribl Stream bundle for this CPU arch in the SAME DIRECTORY AS THE SCRIPT
# (cribl-<ver>-<build>-linux-<arch>.tgz). Cribl Edge bundles (cribl-edge-*) are ignored.
find_local_bundle() {
  local f candidates=""
  for f in "$SCRIPT_DIR"/cribl-*-linux-"${ARCH_TAG}".tgz; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == cribl-edge-* ]] && continue
    candidates+="$(basename "$f")"$'\t'"${f}"$'\n'
  done
  [[ -z "$candidates" ]] && return 0
  # Version-sort on the file name only (cribl-<ver>-...), newest last
  printf '%s' "$candidates" | sort -t$'\t' -k1,1V | tail -n 1 | cut -f2
}

# Bundles next to the script that cannot be used on this host (other CPU / Edge / renamed)
report_unusable_bundles() {
  local f n
  for f in "$SCRIPT_DIR"/*.tgz; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f")"
    case "$n" in
      cribl-edge-*)                    warn "Ignoring ${n}: Cribl Edge bundle, not Cribl Stream." ;;
      cribl-*-linux-"${ARCH_TAG}".tgz) ;;
      cribl-*-linux-x64.tgz|cribl-*-linux-arm64.tgz)
                                       warn "Ignoring ${n}: built for a different CPU (this host needs linux-${ARCH_TAG})." ;;
      cribl*)                          warn "Ignoring ${n}: name is not cribl-<ver>-<build>-linux-${ARCH_TAG}.tgz (keep the original file name)." ;;
    esac
  done
}

fetch_bundle() {
  step "Obtaining Cribl Stream bundle"
  TMP_DIR="$(mktemp -d /tmp/cribl-deploy.XXXXXX)"
  local tgz="${TMP_DIR}/cribl.tgz"

  # Source was decided in check_prerequisites (local file, or download after a 'y')
  if [[ "$BUNDLE_SOURCE" == "local" ]]; then
    info "Using local bundle (no download): $PACKAGE_FILE"
    cp "$PACKAGE_FILE" "$tgz"
  else
    local url
    url="$(curl -fsSL --retry 3 --connect-timeout 10 "https://cdn.cribl.io/dl/latest-${ARCH_TAG}")" \
      || die "Cannot reach cdn.cribl.io. The Cribl Stream package is required to proceed: copy cribl-<ver>-<build>-linux-${ARCH_TAG}.tgz into ${SCRIPT_DIR} and re-run."
    [[ "$url" =~ ^https://.*\.tgz$ ]] || die "Unexpected bundle URL from cdn.cribl.io: $url"
    info "Downloading: $url"
    curl -fSL --retry 3 --connect-timeout 10 --progress-bar -o "$tgz" "$url" \
      || die "Download failed. The Cribl Stream package is required to proceed: copy it into ${SCRIPT_DIR} and re-run."
  fi

  # Validate without pipes into head/grep -q (under pipefail, SIGPIPE on tar = false failure)
  local listing="${TMP_DIR}/listing.txt"
  tar -tzf "$tgz" > "$listing" 2>/dev/null || die "Bundle is corrupt or not a gzip tar archive."
  grep -E '^(\./)?cribl/bin/cribl$' "$listing" >/dev/null \
    || die "Bundle does not contain cribl/bin/cribl — is this a Cribl Stream Linux tarball?"
  ok "Bundle verified ($(du -h "$tgz" | cut -f1), $(wc -l < "$listing") entries)"
  BUNDLE="$tgz"
}

install_bundle() {
  step "Installing bundle to ${CRIBL_HOME}"
  [[ -e "$CRIBL_HOME" ]] && die "${CRIBL_HOME} still exists after cleanup — aborting to avoid mixing versions."
  [[ -e "${INSTALL_PARENT}/cribl" ]] && die "${INSTALL_PARENT}/cribl exists and would be overwritten by the bundle."
  tar -xzf "$BUNDLE" -C "$INSTALL_PARENT"
  [[ "$CRIBL_HOME" == "${INSTALL_PARENT}/cribl" ]] || mv "${INSTALL_PARENT}/cribl" "$CRIBL_HOME"
  chown -R "${CRIBL_USER}:${CRIBL_GROUP}" "$CRIBL_HOME"
  chmod 750 "$CRIBL_HOME"
  ok "Installed Cribl $("$CRIBL_HOME/bin/cribl" version 2>/dev/null | sed -n 1p || echo '(version unknown)')"
}

configure_selinux() {
  [[ "$OS_FAMILY" == "rhel" ]] || return 0
  local mode; mode="$(getenforce 2>/dev/null || echo Disabled)"
  [[ "$mode" == "Disabled" ]] && return 0
  step "SELinux ($mode)"
  if have semanage; then
    semanage fcontext -a -t bin_t "${CRIBL_HOME}/bin(/.*)?" 2>/dev/null \
      || semanage fcontext -m -t bin_t "${CRIBL_HOME}/bin(/.*)?"
    restorecon -R "$CRIBL_HOME" >/dev/null
    ok "Labelled ${CRIBL_HOME}/bin as bin_t so systemd can execute it"
  else
    warn "semanage not found; if the service fails to start, label ${CRIBL_HOME}/bin with bin_t."
  fi
}

# ----------------------------------------------------------------------------
# Role configuration (CLI: mode-master / mode-worker)
# ----------------------------------------------------------------------------
as_cribl() { runuser -u "$CRIBL_USER" -- "$@"; }

configure_leader() {
  step "Configuring LEADER (mode-master)"
  local args=(mode-master -H "$LEADER_BIND" -p "$LEADER_PORT" -u "$AUTH_TOKEN")
  if is_true "$TLS"; then
    install -o "$CRIBL_USER" -g "$CRIBL_GROUP" -m 600 "$TLS_KEY"  "${CRIBL_HOME}/local/leader.key" 2>/dev/null \
      || { mkdir -p "${CRIBL_HOME}/local"; install -o "$CRIBL_USER" -g "$CRIBL_GROUP" -m 600 "$TLS_KEY" "${CRIBL_HOME}/local/leader.key"; }
    install -o "$CRIBL_USER" -g "$CRIBL_GROUP" -m 644 "$TLS_CERT" "${CRIBL_HOME}/local/leader.crt"
    args+=(-S true -k "${CRIBL_HOME}/local/leader.key" -c "${CRIBL_HOME}/local/leader.crt")
  fi
  as_cribl "${CRIBL_HOME}/bin/cribl" "${args[@]}" >/dev/null
  ok "Leader bound to ${LEADER_BIND}:${LEADER_PORT} (TLS: $TLS)"
}

configure_worker() {
  step "Configuring WORKER (mode-worker)"
  local args=(mode-worker -H "$LEADER_HOST" -p "$LEADER_PORT" -u "$AUTH_TOKEN" -g "$WORKER_GROUP")
  [[ -n "$WORKER_TAGS" ]] && args+=(-t "$WORKER_TAGS")
  is_true "$TLS" && args+=(-S true)
  as_cribl "${CRIBL_HOME}/bin/cribl" "${args[@]}" >/dev/null
  ok "Worker -> ${LEADER_HOST}:${LEADER_PORT} | group: ${WORKER_GROUP}${WORKER_TAGS:+ | tags: $WORKER_TAGS} | TLS: $TLS"
}

# ----------------------------------------------------------------------------
# systemd
# ----------------------------------------------------------------------------
enable_service() {
  step "Registering systemd service"
  "${CRIBL_HOME}/bin/cribl" boot-start enable -m systemd -u "$CRIBL_USER" >/dev/null
  mkdir -p /etc/systemd/system/cribl.service.d
  {
    echo "# Managed by cribl-deploy.sh"
    echo "[Service]"
    echo "LimitNOFILE=${NOFILE_LIMIT}"
    echo "LimitNPROC=16384"
    echo "Restart=always"
    echo "RestartSec=5"
    if is_true "$ALLOW_LOW_PORTS"; then
      echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
      echo "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
    fi
  } > /etc/systemd/system/cribl.service.d/override.conf
  systemctl daemon-reload || warn "systemctl daemon-reload failed."
  systemctl enable cribl >/dev/null 2>&1
  chown -R "${CRIBL_USER}:${CRIBL_GROUP}" "$CRIBL_HOME"
  systemctl restart cribl
  ok "cribl.service enabled and started as '$CRIBL_USER'"
}

# ----------------------------------------------------------------------------
# Firewall
# ----------------------------------------------------------------------------
fw_open() { # fw_open <port/proto>
  local spec="$1"
  if have firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="$spec" >/dev/null
  elif have ufw && ufw status 2>/dev/null | grep "Status: active" >/dev/null; then
    ufw allow "$spec" >/dev/null
  else
    return 1
  fi
}

configure_firewall() {
  is_true "$CONFIGURE_FIREWALL" || { warn "Skipping firewall (--skip-firewall)."; return 0; }
  step "Host firewall"
  local specs=()
  if [[ "$ROLE" == "leader" ]]; then
    specs+=("${UI_PORT}/tcp" "${LEADER_PORT}/tcp")
  fi
  if [[ -n "$DATA_PORTS" ]]; then
    local IFS=','; local p
    for p in $DATA_PORTS; do specs+=("$(echo "$p" | tr -d ' ')"); done
  fi
  if [[ ${#specs[@]} -eq 0 ]]; then
    info "No inbound ports to open (worker initiates the connection to the Leader)."
    return 0
  fi
  local s opened=()
  for s in "${specs[@]}"; do
    [[ "$s" =~ ^[0-9]+/(tcp|udp)$ ]] || { warn "Skipping malformed port spec '$s' (use 1234/tcp)"; continue; }
    if fw_open "$s"; then opened+=("$s"); else
      warn "No active firewalld/ufw found — open these manually if a firewall is in use: $(join_by " " "${specs[@]}")"
      return 0
    fi
  done
  have firewall-cmd && systemctl is-active --quiet firewalld && firewall-cmd --reload >/dev/null
  ok "Opened: $(join_by " " "${opened[@]}")"
}

# ----------------------------------------------------------------------------
# Verification
# ----------------------------------------------------------------------------
verify() {
  step "Verifying"
  local _
  for _ in $(seq 1 30); do
    systemctl is-active --quiet cribl && break; sleep 2
  done
  systemctl is-active --quiet cribl || die "cribl.service is not running. Check: journalctl -u cribl -n 100"
  ok "cribl.service is active"

  if is_true "$ALLOW_LOW_PORTS"; then
    local pid capamb
    pid="$(systemctl show -p MainPID --value cribl 2>/dev/null || echo 0)"
    capamb="$(awk '/^CapAmb/ {print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
    if [[ -n "$capamb" && "$capamb" != "0000000000000000" ]]; then
      ok "Privileged ports enabled (CAP_NET_BIND_SERVICE granted to PID ${pid})"
    else
      warn "Could not confirm CAP_NET_BIND_SERVICE on the running process — check: grep Cap /proc/<pid>/status"
    fi
  fi

  if [[ "$ROLE" == "leader" ]]; then
    for _ in $(seq 1 30); do
      curl -fs "http://127.0.0.1:${UI_PORT}/api/v1/health" >/dev/null 2>&1 && break
      curl -fsk "https://127.0.0.1:${UI_PORT}/api/v1/health" >/dev/null 2>&1 && break
      sleep 2
    done
    ss -ltn "( sport = :${LEADER_PORT} )" | grep LISTEN >/dev/null \
      && ok "Leader listening on ${LEADER_PORT}/tcp" \
      || warn "Port ${LEADER_PORT} not listening yet — check ${CRIBL_HOME}/log/cribl.log"
  else
    for _ in $(seq 1 30); do
      ss -tn state established "( dport = :${LEADER_PORT} )" 2>/dev/null | grep . >/dev/null && break; sleep 2
    done
    if ss -tn state established "( dport = :${LEADER_PORT} )" 2>/dev/null | grep . >/dev/null; then
      ok "Worker has an established session to the Leader on ${LEADER_PORT}/tcp"
    else
      warn "No session to Leader yet. Check token/group and ${CRIBL_HOME}/log/cribl.log"
    fi
  fi
}

summary() {
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo
  echo "=============================================================================="
  if [[ "$ROLE" == "leader" ]]; then
    cat <<EOF
 LEADER READY
   UI:            http://${ip:-<leader-ip>}:${UI_PORT}   (first login: admin / admin -> change it)
   Mgmt port:     ${LEADER_PORT}/tcp
   CRIBL_HOME:    ${CRIBL_HOME}   (service user: ${CRIBL_USER})
   Auth token:    ${AUTH_TOKEN}

 Store the token securely. Run this on each Worker host:

   sudo ./cribl-deploy.sh --role worker --leader-host ${ip:-<leader-ip>} \\
        --token '${AUTH_TOKEN}' --group default$(is_true "$TLS" && echo " --tls")

 Non-default groups must exist on the Leader (Worker Groups page) before
 workers that report them will be mapped there.
EOF
  else
    cat <<EOF
 WORKER READY
   Leader:        ${LEADER_HOST}:${LEADER_PORT}
   Worker Group:  ${WORKER_GROUP}
   CRIBL_HOME:    ${CRIBL_HOME}   (service user: ${CRIBL_USER})

 Confirm on the Leader UI -> Workers. Then commit & deploy the '${WORKER_GROUP}'
 group so this worker receives its config bundle.
EOF
  fi
  if is_true "$ALLOW_LOW_PORTS"; then
    echo "   Low ports:     enabled — Sources may listen on <1024 (e.g. 514) as user '${CRIBL_USER}'"
  fi
  echo "   Service:       systemctl status cribl  |  logs: ${CRIBL_HOME}/log/cribl.log"
  echo "   Deploy log:    ${LOG_FILE}"
  echo "=============================================================================="
}

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
uninstall() {
  step "Uninstalling Cribl Stream from ${CRIBL_HOME}"
  detect_existing_install || die "No Cribl install, service or process found on this host."
  if ! is_true "$ASSUME_YES"; then
    local c; ask c "This stops the service and deletes ${CRIBL_HOME}. Type 'yes' to continue" "no"
    [[ "$c" == "yes" ]] || die "Aborted."
  fi
  stop_cribl_processes
  "${CRIBL_HOME}/bin/cribl" boot-start disable -m systemd >/dev/null 2>&1 || true
  systemctl disable cribl >/dev/null 2>&1 || true
  rm -rf "${UNIT_PATHS[@]}"
  rm -f /etc/sysctl.d/99-cribl.conf /etc/sysctl.d/99-cribl-conntrack.conf /etc/security/limits.d/99-cribl.conf
  systemctl disable --now disable-thp.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/disable-thp.service
  systemctl daemon-reload || warn "systemctl daemon-reload failed."
  rm -rf "$CRIBL_HOME"
  ok "Removed. Service account '$CRIBL_USER' kept (userdel $CRIBL_USER to remove)."
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_root
  mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "cribl-deploy.sh v${SCRIPT_VERSION} — action: ${ACTION}"

  detect_os
  detect_arch

  case "$ACTION" in
    uninstall) uninstall; exit 0 ;;
    precheck)  [[ -z "$ROLE" ]] && ROLE=leader; check_prerequisites; precheck; exit 0 ;;
  esac

  collect_inputs
  check_prerequisites
  info "Role: ${ROLE^^} | CRIBL_HOME: ${CRIBL_HOME} | user: ${CRIBL_USER}"

  precheck
  handle_existing_install
  check_ports
  configure_time_sync
  create_user
  tune_os
  fetch_bundle
  install_bundle
  configure_selinux
  if [[ "$ROLE" == "leader" ]]; then configure_leader; else configure_worker; fi
  enable_service
  configure_firewall
  verify
  summary
}

main "$@"
