#!/usr/bin/env bash
# =============================================================================
#  elastic-node-setup.sh  —  run ON EACH VM, choose that VM's role
#
#  Binary (tar.gz) installation of a secured Elastic Stack, one host at a time:
#
#    Order  VM              Role          What it does
#    -----  --------------  ------------  ---------------------------------------
#      1    Elasticsearch 1 es-first      bootstraps the cluster, sets the elastic
#                                         password, prints CA fingerprint + token
#      2    Elasticsearch 2 es-join       joins with an enrollment token
#      3    Elasticsearch 3 es-join       joins with a NEW enrollment token
#                                         (create it on node 1: --role token)
#      4    Kibana          kibana        HTTPS Kibana + Fleet settings/policy
#      5    Fleet Server    fleet         Elastic Agent running Fleet Server
#      6    ES 1-3 + Kibana monitor       Elastic Agent for Stack Monitoring
#                                         (token printed by the kibana run)
#
#  Also: JVM heap sized from the VM's RAM (50%, compressed-oops safe).
#
#  Based on https://www.elastic.co/docs/deploy-manage/deploy/self-managed/tutorial-self-managed-install
#  adapted from RPM to archive installs, plus the "Important system
#  configuration" settings and CA-signed TLS for Kibana and Fleet Server.
#
#  Usage:  sudo ./elastic-node-setup.sh [--role es-first|es-join|token|kibana|fleet|monitor]
#                                        [--token-file FILE | --token VALUE]
#  Air-gapped: place the .tar.gz (+ .sha512) files next to this script.
# =============================================================================
set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
DEFAULT_STACK_VERSION="9.5.5"
ARTIFACT_BASE_URL="https://artifacts.elastic.co/downloads"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$SCRIPT_DIR}"

# ---- Layout ------------------------------------------------------------------
INSTALL_BASE="/opt/elastic"
ES_HOME="${INSTALL_BASE}/elasticsearch"          # symlink -> elasticsearch-<ver>
KB_HOME="${INSTALL_BASE}/kibana"                 # symlink -> kibana-<ver>
ES_DATA_DIR="/var/lib/elasticsearch"
ES_LOG_DIR="/var/log/elasticsearch"
ES_TMP_DIR="${INSTALL_BASE}/tmp/elasticsearch"   # JNA tmp dir (must allow exec)
KB_DATA_DIR="/var/lib/kibana"
KB_LOG_DIR="/var/log/kibana"
LOCAL_CA_DIR="${INSTALL_BASE}/local-ca"          # Kibana / Fleet hosts only
FLEET_CERT_DIR="${INSTALL_BASE}/fleet-server-certs"
FLEET_PORT=8220
BOOTSTRAP_ENV="/etc/elasticsearch-bootstrap.env"
FLEET_CA_DIR="${INSTALL_BASE}/fleet-ca"          # monitored hosts: CA that signed Fleet Server
SM_ES_POLICY="stack-monitoring-elasticsearch"    # Stack Monitoring agent policies
SM_KB_POLICY="stack-monitoring-kibana"
HEAP_CAP_MB=30720                                # 30 GB – verified for compressed oops at start
HEAP_FALLBACK="26g"                              # Elastic: "26GB is safe on most systems"

# ---- Output helpers ----------------------------------------------------------
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s==> [%02d] %s%s\n' "$B" "$STEP" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '    %s! %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '\n%sERROR:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'printf "%sFailed at line %s. Log: %s%s\n" "$R" "$LINENO" "${LOG_FILE:-n/a}" "$N" >&2' ERR
trap 'die "Interrupted."' INT
WORKDIR="$(mktemp -d)"; chmod 700 "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

# =============================================================================
#  Prompt helpers & validation
# =============================================================================
valid_ipv4() {
  local ip=$1 o x; [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a o <<<"$ip"; for x in "${o[@]}"; do ((10#$x <= 255)) || return 1; done
}
valid_hostname() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}
valid_version() { [[ $1 =~ ^9\.[0-9]+\.[0-9]+$ ]]; }
valid_cluster() { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }
valid_file()    { [[ -r $1 ]] || { echo "    File not found/readable: $1" >&2; return 1; }; }
valid_token()   { [[ $1 =~ ^[A-Za-z0-9+/=]{40,}$ ]]; }
clean_token() {   # strip whatever a terminal paste can drag along
  local t=$1
  t=${t//$'\e[200~'/}; t=${t//$'\e[201~'/}           # bracketed-paste markers
  t=${t//[[:space:]]/}                                # spaces, tabs, CR, LF (wrapped lines)
  t=${t//\"/}; t=${t//\'/}                            # stray quotes
  printf '%s' "$t"
}
token_complete() {   # token_complete <node|fleet> <token>  – decodes to check it is whole
  local kind=$1 t=$2 d
  valid_token "$t" || return 1
  d=$(printf '%s' "$t" | base64 -d 2>/dev/null) || return 1
  case $kind in
    node)  [[ $d == '{'*'"key"'*'}' ]] ;;              # {"ver":..,"adr":[..],"fgr":..,"key":..}
    fleet) [[ $d =~ ^[A-Za-z0-9_-]{10,}:[A-Za-z0-9_-]{10,}$ ]] ;;   # <api-key-id>:<api-key>
  esac
}
# ask_token VAR "label" <node|fleet> [preset-value]
#   Visible input with line editing; spaces/CR/line breaks from the paste are
#   removed. A token that arrives over several lines is joined automatically.
#   Alternatives: --token-file FILE or --token VALUE on the command line.
ask_token() {
  local __v=$1 __label=$2 __kind=$3 __pre=${4-} __line __acc
  if [[ -n $__pre ]]; then
    __acc=$(clean_token "$__pre")
    token_complete "$__kind" "$__acc" || die "The $__label supplied via --token/--token-file is not valid (${#__acc} characters)."
    printf -v "$__v" '%s' "$__acc"; ok "$__label taken from the command line/file"; return 0
  fi
  while true; do
    info "Paste the $__label and press Enter (press Enter on an empty line to retry):"
    __acc=""
    while IFS= read -r -e -p "    > " __line || { [[ -n $__acc ]] && break; exit 1; }; do
      __line=$(clean_token "$__line")
      [[ -z $__line ]] && break
      __acc+=$__line
      token_complete "$__kind" "$__acc" && break
      info "(partial: ${#__acc} characters so far – keep pasting, or Enter on an empty line)"
    done
    if token_complete "$__kind" "$__acc"; then
      ok "$__label accepted (${#__acc} characters)"
      printf -v "$__v" '%s' "$__acc"; return 0
    fi
    warn "Not a valid/complete $__label (${#__acc} characters). Copy it again – or use --token-file."
  done
}
norm_fp()       { local f=${1//[:[:space:]]/}; echo "${f,,}"; }
valid_fp()      { [[ $(norm_fp "$1") =~ ^[0-9a-f]{64}$ ]]; }
normalize_os() {
  case "${1,,}" in
    1|debian|ubuntu|deb) echo debian ;;
    2|rhel|redhat|centos|rocky|alma|almalinux|oracle|ol|fedora|amzn|rpm) echo rhel ;;
    3|suse|sles|opensuse) echo suse ;;
    *) return 1 ;;
  esac
}
valid_os() { normalize_os "$1" >/dev/null; }
valid_elastic_pw() {
  local p=$1
  ((${#p} >= 12)) || { echo "    Must be at least 12 characters." >&2; return 1; }
  [[ $p != *'"'* && $p != *'\'* ]] || { echo "    Must not contain \" or \\." >&2; return 1; }
}
ask() {   # ask VAR "prompt" [default] [validator]
  local __v=$1 __p=$2 __d=${3-} __f=${4-} __a
  while true; do
    if [[ -n $__d ]]; then read -r -p "    $__p [$__d]: " __a || exit 1; __a=${__a:-$__d}
    else read -r -p "    $__p: " __a || exit 1; fi
    [[ -z $__a ]] && { echo "    A value is required." >&2; continue; }
    if [[ -n $__f ]] && ! "$__f" "$__a"; then echo "    Invalid value." >&2; continue; fi
    printf -v "$__v" '%s' "$__a"; return 0
  done
}
ask_optional() {   # ask_optional VAR "prompt" [validator]  (blank allowed)
  local __v=$1 __p=$2 __f=${3-} __a
  while true; do
    read -r -p "    $__p: " __a || exit 1
    if [[ -n $__a && -n $__f ]] && ! "$__f" "$__a"; then continue; fi
    printf -v "$__v" '%s' "$__a"; return 0
  done
}
ask_secret() {   # ask_secret VAR "prompt" confirm(yes|no) [validator]
  local __v=$1 __p=$2 __c=$3 __f=${4-} __a __b
  while true; do
    read -r -s -p "    $__p: " __a || exit 1; echo
    [[ -z $__a ]] && { echo "    A value is required." >&2; continue; }
    if [[ -n $__f ]] && ! "$__f" "$__a"; then echo "    Invalid value." >&2; continue; fi
    if [[ $__c == yes ]]; then
      read -r -s -p "    Confirm: " __b || exit 1; echo
      [[ $__a == "$__b" ]] || { echo "    Values do not match." >&2; continue; }
    fi
    printf -v "$__v" '%s' "$__a"; return 0
  done
}
ask_yn() {   # ask_yn VAR "question" default(y|n)
  local __v=$1 __p=$2 __d=$3 __a
  while true; do
    read -r -p "    $__p [$([[ $__d == y ]] && echo Y/n || echo y/N)]: " __a || exit 1
    case "${__a:-$__d}" in [Yy]|[Yy][Ee][Ss]) printf -v "$__v" yes; return 0 ;;
                           [Nn]|[Nn][Oo])     printf -v "$__v" no;  return 0 ;; esac
  done
}

# =============================================================================
#  Host detection & common prompts
# =============================================================================
detect_os() {
  local ids
  DETECTED_OS=unknown; OS_PRETTY=unknown
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_PRETTY=${PRETTY_NAME:-unknown}
    ids=" ${ID:-} ${ID_LIKE:-} "
    case "$ids" in
      *" debian "*|*" ubuntu "*)                       DETECTED_OS=debian ;;
      *" rhel "*|*" fedora "*|*" centos "*|*" amzn "*) DETECTED_OS=rhel ;;
      *suse*|*" sles "*)                               DETECTED_OS=suse ;;
    esac
  fi
}
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  ES_ARCH=x86_64;  AGENT_ARCH=x86_64 ;;
    aarch64|arm64) ES_ARCH=aarch64; AGENT_ARCH=arm64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}
prompt_this_host() {
  step "This host"
  detect_os
  local def_ip; def_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ask HOST_NAME "Hostname for this VM" "$(hostname -f 2>/dev/null || hostname)" valid_hostname
  HOST_SHORT=${HOST_NAME%%.*}
  ask IP "IP address of this VM" "$def_ip" valid_ipv4
  ip -o addr 2>/dev/null | grep -qw "$IP" || warn "$IP is not configured on any local interface."
  local os; ask os "OS family (debian|rhel|suse)" "$([[ $DETECTED_OS != unknown ]] && echo "$DETECTED_OS")" valid_os
  OS_FAMILY=$(normalize_os "$os")
  if [[ $DETECTED_OS != unknown && $DETECTED_OS != "$OS_FAMILY" ]]; then
    warn "This host reports '$DETECTED_OS' ($OS_PRETTY) but you chose '$OS_FAMILY'."
    local c; ask_yn c "Continue anyway?" n; [[ $c == yes ]] || die "Aborted."
  fi
  ask_yn SET_HOSTNAME "Set the OS hostname to '$HOST_NAME'?" y
  ask_yn CONFIG_FW    "Open the required ports in firewalld/ufw (if active)?" y
}
prompt_es_ips() {   # prompt_es_ips [default-for-node1]
  info "IP addresses of the three Elasticsearch nodes:"
  ask ES1_IP "Elasticsearch node 1 IP (the es-first node)" "${1-}" valid_ipv4
  ask ES2_IP "Elasticsearch node 2 IP" "" valid_ipv4
  ask ES3_IP "Elasticsearch node 3 IP" "" valid_ipv4
  ES_IPS=("$ES1_IP" "$ES2_IP" "$ES3_IP")
  [[ $ES1_IP != "$ES2_IP" && $ES1_IP != "$ES3_IP" && $ES2_IP != "$ES3_IP" ]] || die "The three Elasticsearch IPs must differ."
}
prompt_version() { ask STACK_VERSION "Elastic Stack version (same on every VM)" "$DEFAULT_STACK_VERSION" valid_version; }
confirm_or_abort() { local go; ask_yn go "Proceed?" n; [[ $go == yes ]] || die "Aborted by user."; }
start_logging() {
  LOG_FILE="/var/log/elastic-node-setup-${ROLE}-$(date +%Y%m%d-%H%M%S).log"
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# =============================================================================
#  Artifacts
# =============================================================================
artifact_file() {
  case $1 in
    es)     echo "elasticsearch-${STACK_VERSION}-linux-${ES_ARCH}.tar.gz" ;;
    kibana) echo "kibana-${STACK_VERSION}-linux-${ES_ARCH}.tar.gz" ;;
    agent)  echo "elastic-agent-${STACK_VERSION}-linux-${AGENT_ARCH}.tar.gz" ;;
  esac
}
artifact_url() {
  case $1 in
    es)     echo "${ARTIFACT_BASE_URL}/elasticsearch/$2" ;;
    kibana) echo "${ARTIFACT_BASE_URL}/kibana/$2" ;;
    agent)  echo "${ARTIFACT_BASE_URL}/beats/elastic-agent/$2" ;;
  esac
}
verify_artifact() { ( cd "$ARTIFACT_DIR" && sha512sum -c "$1.sha512" >/dev/null 2>&1 ); }
get_artifact() {   # get_artifact <comp>  -> sets ARTIFACT_PATH
  local comp=$1 f url; f=$(artifact_file "$comp"); url=$(artifact_url "$comp" "$f")
  step "Obtaining $f"
  ARTIFACT_PATH="$ARTIFACT_DIR/$f"
  if [[ -f $ARTIFACT_PATH ]]; then
    if [[ -f $ARTIFACT_PATH.sha512 ]]; then
      verify_artifact "$f" && { ok "Using local copy (checksum OK)"; return 0; }
      warn "Local copy failed checksum – downloading again."
    else
      if curl -fsSL --retry 3 -o "$ARTIFACT_PATH.sha512" "$url.sha512" 2>/dev/null && verify_artifact "$f"; then
        ok "Using local copy (checksum OK)"; return 0
      fi
      [[ -f $ARTIFACT_PATH.sha512 ]] || { warn "No checksum available – using the local copy unverified."; return 0; }
    fi
  fi
  info "Downloading $url"
  curl -fL --retry 3 --progress-bar -o "$ARTIFACT_PATH" "$url" || die "Download failed (no Internet? place $f next to this script)."
  curl -fsSL --retry 3 -o "$ARTIFACT_PATH.sha512" "$url.sha512" || die "Checksum download failed."
  verify_artifact "$f" || die "SHA-512 verification FAILED for $f"
  ok "Downloaded and verified"
}
tar_top() { local t; t=$(set +o pipefail; tar -tzf "$1" | head -n1); t=${t#./}; echo "${t%%/*}"; }
nologin_shell() { command -v nologin 2>/dev/null || echo /sbin/nologin; }

# =============================================================================
#  OS preparation
# =============================================================================
pm_install() {
  case $OS_FAMILY in
    debian) export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null && apt-get install -y -qq "$@" >/dev/null ;;
    rhel)   if command -v dnf >/dev/null; then dnf install -y -q "$@" >/dev/null
            else yum install -y -q "$@" >/dev/null; fi ;;
    suse)   zypper --non-interactive --quiet install --no-recommends "$@" >/dev/null ;;
  esac
}
FW=none
fw_detect() {
  local fwd=no ufw=no
  command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld && fwd=yes
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active' && ufw=yes
  if [[ $OS_FAMILY == debian ]]; then
    if [[ $ufw == yes ]]; then FW=ufw; elif [[ $fwd == yes ]]; then FW=firewalld; fi
  else
    if [[ $fwd == yes ]]; then FW=firewalld; elif [[ $ufw == yes ]]; then FW=ufw; fi
  fi
}
fw_open() {   # fw_open <port> [source-ip ...]
  local port=$1 s; shift
  case $FW in
    firewalld)
      if (($#)); then for s in "$@"; do
          firewall-cmd -q --permanent --add-rich-rule="rule family=ipv4 source address=$s/32 port port=$port protocol=tcp accept"; done
      else firewall-cmd -q --permanent --add-port="$port/tcp"; fi ;;
    ufw)
      if (($#)); then for s in "$@"; do ufw allow proto tcp from "$s" to any port "$port" >/dev/null; done
      else ufw allow "$port/tcp" >/dev/null; fi ;;
  esac
}
prepare_os() {   # prepare_os <es|kibana|fleet>
  local role=$1 c need=()
  step "Preparing the operating system ($OS_FAMILY, $OS_PRETTY)"
  for c in curl tar gzip openssl; do command -v "$c" >/dev/null || need+=("$c"); done
  if ((${#need[@]})); then info "Installing: ${need[*]}"; pm_install "${need[@]}"; fi

  if ! systemctl is-active --quiet chronyd && ! systemctl is-active --quiet chrony \
     && ! systemctl is-active --quiet systemd-timesyncd && ! systemctl is-active --quiet ntpd; then
    info "Enabling time synchronisation (chrony)"
    if pm_install chrony; then
      systemctl enable --now chronyd >/dev/null 2>&1 || systemctl enable --now chrony >/dev/null 2>&1 || true
    else warn "Could not install chrony – make sure NTP is configured."; fi
  fi

  if [[ $SET_HOSTNAME == yes ]]; then
    hostnamectl set-hostname "$HOST_NAME" 2>/dev/null || { echo "$HOST_NAME" > /etc/hostname; hostname "$HOST_NAME"; }
  fi
  if ! grep -Eq "^[[:space:]]*${IP//./\\.}[[:space:]].*\\b${HOST_SHORT}\\b" /etc/hosts; then
    cp -a /etc/hosts "/etc/hosts.bak.elastic.$(date +%s)"
    if [[ $HOST_SHORT != "$HOST_NAME" ]]; then echo "$IP  $HOST_NAME  $HOST_SHORT" >> /etc/hosts
    else echo "$IP  $HOST_NAME" >> /etc/hosts; fi
  fi

  if [[ $CONFIG_FW == yes ]]; then
    fw_detect
    if [[ $FW == none ]]; then info "No active firewalld/ufw – skipping firewall rules"
    else
      case $role in
        es)     fw_open 9200; fw_open 9300 "${ES_IPS[@]}" ;;   # transport only between ES nodes
        kibana) fw_open 5601 ;;
        fleet)  fw_open "$FLEET_PORT" ;;
      esac
      [[ $FW == firewalld ]] && firewall-cmd -q --reload
      ok "Firewall ($FW) updated"
    fi
  fi

  if [[ $role == es ]]; then
    cat > /etc/sysctl.d/90-elasticsearch.conf <<'SYS'
# Managed by elastic-node-setup.sh
vm.max_map_count = 1048576
vm.swappiness = 1
net.ipv4.tcp_retries2 = 5
SYS
    sysctl -q -p /etc/sysctl.d/90-elasticsearch.conf
    cat > /etc/security/limits.d/90-elasticsearch.conf <<'LIM'
elasticsearch  -  nofile   65535
elasticsearch  -  nproc    4096
elasticsearch  -  memlock  unlimited
LIM
    if [[ $DISABLE_SWAP == yes ]]; then
      swapoff -a || true
      if grep -Eq '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
        cp -a /etc/fstab "/etc/fstab.bak.elastic.$(date +%s)"
        sed -ri 's@^([^#].*[[:space:]]swap[[:space:]].*)$@# \1  # disabled for Elasticsearch@' /etc/fstab
      fi
    fi
  fi
  ok "OS prepared"
}

# =============================================================================
#  HTTP helpers (verify TLS, credentials passed via a temp curl config file)
# =============================================================================
API_CODE=""; API_BODY=""
_http() {   # _http METHOD URL CA_FILE BODY [extra-header ...]
  local m=$1 url=$2 ca=$3 b=$4 cfg out x; shift 4
  local -a d=() h=()
  [[ -n $b ]] && d=(--data-binary "$b")
  for x in "$@"; do h+=(-H "$x"); done
  cfg=$(mktemp); printf 'user = "elastic:%s"\n' "$ELASTIC_PASSWORD" > "$cfg"
  out=$(curl -sS --max-time 180 --cacert "$ca" -K "$cfg" -X "$m" -H 'Content-Type: application/json' \
        ${h[@]+"${h[@]}"} ${d[@]+"${d[@]}"} -w '\n%{http_code}' "$url" 2>/dev/null) || out=$'\n000'
  rm -f "$cfg"
  API_CODE=${out##*$'\n'}; API_BODY=${out%$'\n'*}
  [[ $API_CODE == 2* ]]
}
es_api() { _http "$1" "https://localhost:9200$2" "$ES_HOME/config/certs/http_ca.crt" "${3-}"; }
es_remote_api() {   # tries each ES node in turn (for Kibana / Fleet hosts)
  local ip
  for ip in "${ES_IPS[@]}"; do
    _http "$1" "https://${ip}:9200$2" "$ES_CA_FILE" "${3-}" && return 0
    [[ $API_CODE != 000 ]] && return 1
  done
  return 1
}
kbn_api() { _http "$1" "https://${IP}:5601$2" "$KB_CA" "${3-}" 'kbn-xsrf: true' 'Elastic-Api-Version: 2023-10-31'; }

# =============================================================================
#  Elasticsearch helpers
# =============================================================================
es_cli() { local t=$1; shift; ( cd "$ES_HOME" && runuser -u elasticsearch -- env ES_PATH_CONF="$ES_HOME/config" "$ES_HOME/bin/$t" "$@" ); }
es_wait_http() {
  local max=${1:-900} t=0 c
  while ((t < max)); do
    c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://localhost:9200/ 2>/dev/null || true)
    [[ $c == 200 || $c == 401 ]] && return 0
    sleep 5; t=$((t + 5))
  done
  return 1
}
es_wait_health() {   # es_wait_health <status> [max_seconds]
  local s=$1 max=${2:-600} t=0
  while ((t < max)); do
    if es_api GET "/_cluster/health?wait_for_status=$s&timeout=20s" && [[ $API_BODY == *'"timed_out":false'* ]]; then return 0; fi
    sleep 5; t=$((t + 25))
  done
  return 1
}
es_diag() {
  journalctl -u elasticsearch.service -n 60 --no-pager >&2 2>/dev/null || true
  tail -n 60 "$ES_LOG_DIR"/*.log >&2 2>/dev/null || true
}
cert_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'; }

# ---- JVM heap sized from this VM's RAM --------------------------------------
# Elastic guidance: Xms = Xmx, <= 50% of RAM (rest is filesystem cache), and
# below the compressed-oops threshold (26 GB safe, up to ~30 GB on some JVMs).
valid_heap() { [[ $1 =~ ^[0-9]+[mMgG]$ ]]; }
compute_heap() {   # sets RAM_MB and HEAP_DEF
  local heap_mb
  RAM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
  heap_mb=$((RAM_MB / 2))
  if ((heap_mb > HEAP_CAP_MB)); then heap_mb=$HEAP_CAP_MB; fi
  if ((heap_mb < 1024)); then heap_mb=1024; fi
  if ((heap_mb % 1024 == 0)); then HEAP_DEF="$((heap_mb / 1024))g"; else HEAP_DEF="${heap_mb}m"; fi
}
prompt_es_extras() {
  local def; compute_heap; def=$HEAP_DEF
  if ((RAM_MB < 4096)); then warn "Only ${RAM_MB} MB RAM – 8 GB+ is recommended for an Elasticsearch node."; fi
  info "This VM has ${RAM_MB} MB RAM. Recommended JVM heap: ${def} (50% of RAM, capped for compressed oops)."
  ask ES_HEAP "JVM heap (Xms = Xmx), e.g. 4g or 2048m" "$def" valid_heap
  ES_HEAP=${ES_HEAP,,}
  prompt_data_dir
  ask_yn DISABLE_SWAP "Disable swap (recommended)?" y
}

# ---- Elasticsearch data directory (custom location) -------------------------
valid_data_dir() {
  local dd=$1
  [[ $dd == /* ]] || { echo "    Must be an absolute path." >&2; return 1; }
  [[ $dd != *[[:space:]]* ]] || { echo "    Spaces are not supported." >&2; return 1; }
  case "${dd%/}" in
    ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var)
      echo "    Choose a dedicated directory, not a system directory." >&2; return 1 ;;
  esac
  [[ ${dd%/}/ != "$INSTALL_BASE"/* ]] || { echo "    Keep data outside $INSTALL_BASE (upgrades replace that tree)." >&2; return 1; }
}
prompt_data_dir() {
  info "Elasticsearch data directory (path.data). Use a dedicated disk/mount for production;"
  info "it will be created if missing and owned by the 'elasticsearch' user (mode 750)."
  ask ES_DATA_DIR "Data directory" "$ES_DATA_DIR" valid_data_dir
  ES_DATA_DIR=${ES_DATA_DIR%/}
  if [[ -d $ES_DATA_DIR ]] && [[ -n $(find "$ES_DATA_DIR" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit 2>/dev/null) ]]; then
    die "$ES_DATA_DIR is not empty – use an empty directory for a fresh node."
  fi
  if [[ -d $ES_DATA_DIR ]]; then
    local fs avail
    fs=$(df -PT "$ES_DATA_DIR" | awk 'NR==2{print $2" on "$7}')
    avail=$(df -P -BG "$ES_DATA_DIR" | awk 'NR==2{print $4}')
    info "Found: ${fs}, ${avail} free."
    if [[ $(findmnt -no TARGET --target "$ES_DATA_DIR" 2>/dev/null) == / ]]; then
      warn "$ES_DATA_DIR is on the root filesystem – a dedicated mount is recommended."
    fi
  fi
}
prepare_data_dir() {   # after the elasticsearch user exists
  mkdir -p "$ES_DATA_DIR"
  chown elasticsearch:elasticsearch "$ES_DATA_DIR"
  chmod 750 "$ES_DATA_DIR"
  # SELinux: give a custom path the same label as the default data location
  if command -v selinuxenabled >/dev/null && selinuxenabled 2>/dev/null && command -v restorecon >/dev/null; then
    if command -v semanage >/dev/null; then
      semanage fcontext -a -t var_lib_t "${ES_DATA_DIR}(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t var_lib_t "${ES_DATA_DIR}(/.*)?" 2>/dev/null || true
    fi
    restorecon -R "$ES_DATA_DIR" 2>/dev/null || true
  fi
  # every parent directory must be traversable by the service user
  runuser -u elasticsearch -- test -w "$ES_DATA_DIR" -a -x "$ES_DATA_DIR" \
    || die "The elasticsearch user cannot write to $ES_DATA_DIR – check the permissions of its parent directories (they need o+x) and the mount options."
  ok "Data directory $ES_DATA_DIR ready (elasticsearch:elasticsearch, 750)"
}
write_heap() {   # write_heap <size>
  printf '# Managed by elastic-node-setup.sh – sized from %s MB RAM\n-Xms%s\n-Xmx%s\n' \
    "${RAM_MB:-?}" "$1" "$1" > "$ES_HOME/config/jvm.options.d/heap.options"
  chown elasticsearch:elasticsearch "$ES_HOME/config/jvm.options.d/heap.options"
}
verify_heap() {   # confirms compressed oops; drops to 26g and restarts if needed
  es_api GET '/_nodes/_local/jvm?filter_path=nodes.*.jvm.using_compressed_ordinary_object_pointers,nodes.*.jvm.mem.heap_max_in_bytes' \
    || { warn "Could not read JVM info ($API_CODE)."; return 0; }
  if [[ $API_BODY == *'"using_compressed_ordinary_object_pointers":"true"'* || $API_BODY == *'"using_compressed_ordinary_object_pointers":true'* ]]; then
    ok "JVM heap ${ES_HEAP} active, compressed oops enabled"
  else
    warn "Compressed oops are OFF with heap ${ES_HEAP} – lowering to ${HEAP_FALLBACK} and restarting."
    ES_HEAP=$HEAP_FALLBACK; write_heap "$ES_HEAP"
    systemctl restart elasticsearch.service
    es_wait_http 900 || { es_diag; die "Restart failed after heap change."; }
    es_wait_health yellow 600 || true
  fi
}

es_install() {   # es_install <is-first yes|no>
  local is_first=$1 top yml
  step "Installing Elasticsearch ${STACK_VERSION}"
  id -u elasticsearch >/dev/null 2>&1 || useradd --system --user-group --no-create-home \
      --home-dir "$ES_HOME" --shell "$(nologin_shell)" elasticsearch
  top=$(tar_top "$ARTIFACT_PATH"); [[ -n $top ]] || die "Cannot read $ARTIFACT_PATH"
  mkdir -p "$INSTALL_BASE"
  tar -xzf "$ARTIFACT_PATH" -C "$INSTALL_BASE"
  ln -sfn "$INSTALL_BASE/$top" "$ES_HOME"
  mkdir -p "$ES_LOG_DIR" "$ES_TMP_DIR"
  chown -R elasticsearch:elasticsearch "$INSTALL_BASE/$top" "$ES_LOG_DIR" "$ES_TMP_DIR"
  chmod 750 "$ES_LOG_DIR"
  prepare_data_dir

  # Node 1: no network settings before the first start, so security
  # auto-configuration bootstraps a new cluster (as in the tutorial).
  # Joining nodes: enrollment writes transport/http/discovery settings.
  yml="$ES_HOME/config/elasticsearch.yml"
  cp -a "$yml" "$yml.dist"
  {
    echo "# ======================== Managed by elastic-node-setup.sh ========================"
    echo "cluster.name: ${CLUSTER_NAME}"
    echo "node.name: ${HOST_NAME}"
    echo "path.data: ${ES_DATA_DIR}"
    echo "path.logs: ${ES_LOG_DIR}"
    echo "bootstrap.memory_lock: true"
    echo "http.port: 9200"
    echo "transport.port: 9300"
    [[ $is_first == no ]] && echo "network.publish_host: ${IP}"
  } > "$yml"
  chown elasticsearch:elasticsearch "$yml"
  write_heap "$ES_HEAP"

  cat > /etc/systemd/system/elasticsearch.service <<UNIT
[Unit]
Description=Elasticsearch
Documentation=https://www.elastic.co
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=elasticsearch
Group=elasticsearch
Environment=ES_HOME=${ES_HOME}
Environment=ES_PATH_CONF=${ES_HOME}/config
Environment=ES_TMPDIR=${ES_TMP_DIR}
# Present only during the one-time enrollment of a joining node:
EnvironmentFile=-${BOOTSTRAP_ENV}
WorkingDirectory=${ES_HOME}
ExecStart=${ES_HOME}/bin/elasticsearch --quiet \$ES_BOOTSTRAP_ARGS
StandardOutput=journal
StandardError=inherit
LimitNOFILE=65535
LimitNPROC=4096
LimitAS=infinity
LimitFSIZE=infinity
LimitMEMLOCK=infinity
TimeoutStartSec=900
TimeoutStopSec=0
KillSignal=SIGTERM
KillMode=process
SendSIGKILL=no
SuccessExitStatus=143
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable elasticsearch.service >/dev/null 2>&1
  ok "Installed at $ES_HOME -> $INSTALL_BASE/$top (service: elasticsearch)"
}

es_set_seed_hosts() {   # final discovery config (tutorial step 6)
  local yml="$ES_HOME/config/elasticsearch.yml"
  cp -a "$yml" "$yml.bak.$(date +%s)"
  awk '
    /^(cluster\.initial_master_nodes|discovery\.seed_hosts):/ { skip=1; next }
    skip && /^[[:space:]]+-/ { next }
    { skip=0; print }
  ' "$yml" > "$yml.new"
  printf '\n# Consolidated by elastic-node-setup.sh\ndiscovery.seed_hosts: ["%s:9300","%s:9300","%s:9300"]\n' \
    "$ES1_IP" "$ES2_IP" "$ES3_IP" >> "$yml.new"
  cat "$yml.new" > "$yml"; rm -f "$yml.new"
}

check_not_installed() {
  [[ ! -e $ES_HOME && ! -e $KB_HOME && ! -e /opt/Elastic/Agent && ! -e /etc/systemd/system/elasticsearch.service ]] \
    || die "An Elastic component is already installed on this VM – this script performs fresh installs only."
}

# =============================================================================
#  Role: es-first  (Elasticsearch node 1 — bootstraps the cluster)
# =============================================================================
role_es_first() {
  prompt_this_host
  step "Cluster settings"
  prompt_version
  ask CLUSTER_NAME "Cluster name (same on all ES nodes)" "elastic-prod" valid_cluster
  info "Password for the built-in 'elastic' superuser (min 12 chars):"
  ask_secret ELASTIC_PASSWORD "elastic password" yes valid_elastic_pw
  prompt_es_ips "$IP"
  [[ $ES1_IP == "$IP" ]] || die "This is node 1, so 'node 1 IP' must be this VM's IP ($IP)."
  prompt_es_extras
  confirm_or_abort; start_logging

  prepare_os es
  get_artifact es
  es_install yes

  step "First start + security auto-configuration"
  systemctl start elasticsearch.service
  es_wait_http 900 || { es_diag; die "Elasticsearch did not start."; }
  [[ -f $ES_HOME/config/certs/http_ca.crt ]] || { es_diag; die "Security auto-configuration did not run."; }

  local tmp_pw="" new_pw=$ELASTIC_PASSWORD _
  for _ in $(seq 1 20); do
    tmp_pw=$(es_cli elasticsearch-reset-password -u elastic -b -s 2>/dev/null | tail -n1 || true)
    [[ -n $tmp_pw ]] && break; sleep 10
  done
  [[ -n $tmp_pw ]] || die "Could not reset the elastic password."
  ELASTIC_PASSWORD=$tmp_pw
  es_api POST /_security/user/elastic/_password "{\"password\":\"${new_pw}\"}" \
    || die "Setting the elastic password failed ($API_CODE): $API_BODY"
  ELASTIC_PASSWORD=$new_pw
  es_api GET / || die "Login with the new elastic password failed ($API_CODE)."
  es_wait_health yellow 600 || { es_diag; die "Cluster did not form."; }
  ok "Cluster formed; elastic password set"

  step "Opening the transport layer and consolidating discovery (tutorial steps 2 and 6)"
  local yml="$ES_HOME/config/elasticsearch.yml"
  if grep -Eq '^#[[:space:]]*transport\.host:' "$yml"; then
    sed -ri 's/^#[[:space:]]*transport\.host:.*/transport.host: 0.0.0.0/' "$yml"
  elif ! grep -Eq '^transport\.host:' "$yml"; then
    echo "transport.host: 0.0.0.0" >> "$yml"
  fi
  grep -Eq '^network\.publish_host:' "$yml" || echo "network.publish_host: ${IP}" >> "$yml"
  es_set_seed_hosts    # also removes cluster.initial_master_nodes (cluster has formed)
  systemctl restart elasticsearch.service
  es_wait_http 900 || { es_diag; die "Restart failed – check bootstrap checks in the log."; }
  es_wait_health yellow 600 || { es_diag; die "Cluster not healthy after restart."; }
  ok "Node 1 ready (bootstrap checks enforced)"
  verify_heap

  local fp token
  fp=$(cert_fp "$ES_HOME/config/certs/http_ca.crt")
  token=$(es_cli elasticsearch-create-enrollment-token -s node 2>/dev/null | tail -n1 || true)
  local S=/root/elastic-es-first-summary.txt
  {
    echo "Elasticsearch node 1 ($HOST_NAME / $IP) – cluster '$CLUSTER_NAME', version $STACK_VERSION"
    echo
    echo "HTTP CA fingerprint (enter on the Kibana and Fleet VMs):"
    echo "  $fp"
    echo "HTTP CA file: $ES_HOME/config/certs/http_ca.crt"
    echo
    echo "Next: on Elasticsearch node 2 run   sudo ./elastic-node-setup.sh --role es-join"
    echo "      and paste this node enrollment token (valid 30 minutes, use once):"
    echo "  ${token:-<could not create – run: sudo ./elastic-node-setup.sh --role token>}"
    echo
    echo "For node 3, create a NEW token here:  sudo ./elastic-node-setup.sh --role token"
  } > "$S"; chmod 600 "$S"
  step "Done"; sed 's/^/    /' "$S"; info ""; info "Saved to $S  |  log: $LOG_FILE"
}

# =============================================================================
#  Role: token  (run on node 1 – prints a fresh node enrollment token)
# =============================================================================
role_token() {
  [[ -x $ES_HOME/bin/elasticsearch-create-enrollment-token ]] || die "Elasticsearch is not installed here."
  systemctl is-active --quiet elasticsearch.service || die "Elasticsearch is not running here."
  local t; t=$(es_cli elasticsearch-create-enrollment-token -s node 2>/dev/null | tail -n1 || true)
  valid_token "$t" || die "Could not create an enrollment token (is the cluster healthy?)."
  echo; echo "Node enrollment token (valid 30 minutes, use once):"; echo; echo "$t"; echo
}

# =============================================================================
#  Role: es-join  (Elasticsearch nodes 2 and 3)
# =============================================================================
role_es_join() {
  prompt_this_host
  step "Cluster settings (must match node 1)"
  prompt_version
  ask CLUSTER_NAME "Cluster name" "elastic-prod" valid_cluster
  ask_secret ELASTIC_PASSWORD "elastic password (set on node 1)" no
  prompt_es_ips
  [[ $IP == "$ES2_IP" || $IP == "$ES3_IP" ]] || die "This VM's IP ($IP) must be node 2 or node 3."
  info "Node enrollment token from node 1 (sudo ./elastic-node-setup.sh --role token):"
  ask_token TOKEN "node enrollment token" node "$CLI_TOKEN"
  prompt_es_extras
  confirm_or_abort; start_logging

  step "Checking connectivity to node 1"
  local p
  for p in 9200 9300; do
    timeout 5 bash -c "</dev/tcp/${ES1_IP}/$p" 2>/dev/null || die "Cannot reach ${ES1_IP}:$p (firewall/routing?)."
  done
  ok "Node 1 reachable on 9200 and 9300"

  prepare_os es
  get_artifact es
  es_install no

  step "Enrolling into the cluster"
  ( umask 077; printf 'ES_BOOTSTRAP_ARGS=--enrollment-token %s\n' "$TOKEN" > "$BOOTSTRAP_ENV" )
  systemctl start elasticsearch.service
  es_wait_http 900 || { es_diag; die "Elasticsearch did not start (expired token? create a new one on node 1)."; }
  [[ -f $ES_HOME/config/certs/http_ca.crt ]] || { es_diag; die "Enrollment did not complete (expired or invalid token? create a new one on node 1)."; }
  rm -f "$BOOTSTRAP_ENV"          # enrollment is done – the token must never be reused on a restart

  # The master connects BACK to this node on its publish address (port 9300).
  # Make sure the transport layer is bound to the network, not only to localhost.
  local yml="$ES_HOME/config/elasticsearch.yml"
  if ! grep -Eq '^[[:space:]]*(transport|network)\.host:' "$yml"; then
    info "Binding the transport layer to all interfaces (transport.host: 0.0.0.0) and restarting"
    printf '\n# Allow the master to connect back on 9300 (added by elastic-node-setup.sh)\ntransport.host: 0.0.0.0\n' >> "$yml"
    systemctl restart elasticsearch.service
    es_wait_http 900 || { es_diag; die "Elasticsearch did not restart."; }
  fi
  if ss -ltnH 'sport = :9300' 2>/dev/null | awk '{print $4}' | grep -qvE '^(127\.|\[::1\]|::1)'; then
    ok "Transport port 9300 is listening on the network"
  else
    warn "Port 9300 appears to listen on localhost only: $(ss -ltnH 'sport = :9300' 2>/dev/null | awk '{print $4}' | xargs)"
  fi

  local joined=no _
  for _ in $(seq 1 60); do
    if es_api GET '/_cat/nodes?h=name' && awk -v n="$HOST_NAME" '$1 == n { f = 1 } END { exit !f }' <<<"$API_BODY"; then
      joined=yes; break
    fi
    sleep 10
  done
  if [[ $joined != yes ]]; then
    es_diag
    die "Node did not join. Node 1 must reach ${IP}:9300 – test on node 1:  timeout 3 bash -c '</dev/tcp/${IP}/9300' && echo open
       Also check the firewall on this VM allows 9300 from ${ES1_IP} and that the elastic password is correct."
  fi
  ok "Joined the cluster"

  step "Consolidating discovery configuration (tutorial step 6)"
  es_set_seed_hosts
  systemctl restart elasticsearch.service
  es_wait_http 900 || { es_diag; die "Restart failed."; }
  es_wait_health yellow 600 || { es_diag; die "Cluster not healthy after restart."; }
  verify_heap
  es_api GET '/_cat/nodes?v&h=ip,name,node.role,master&s=name' || true
  step "Done"
  printf '%s\n' "$API_BODY" | sed 's/^/    /'
  info ""
  if [[ $IP == "$ES2_IP" ]]; then info "Next: create a NEW token on node 1 (--role token) and run --role es-join on node 3."
  else info "Next: run --role kibana on the Kibana VM."; fi
  info "Log: $LOG_FILE"
}

# =============================================================================
#  Kibana / Fleet shared: trust the Elasticsearch CA, certificates
# =============================================================================
prompt_es_trust() {
  info "Elasticsearch HTTP CA fingerprint (printed at the end of the node 1 run):"
  ask ES_CA_FP "SHA-256 fingerprint" "" valid_fp
  ES_CA_FP=$(norm_fp "$ES_CA_FP")
  ask_optional ES_CA_PATH "Path to a copy of http_ca.crt (blank = fetch from the cluster and verify)" valid_file
}
fetch_ca_by_fp() {   # fetch_ca_by_fp <host> <port> <fingerprint> <dest>
  # Saves the certificate in the server's TLS chain whose SHA-256 fingerprint
  # matches the one the operator copied from the other VM (trust on verification).
  local host=$1 port=$2 fp=$3 dest=$4 chain c
  chain=$(timeout 15 openssl s_client -connect "${host}:${port}" -showcerts </dev/null 2>/dev/null || true)
  [[ $chain == *"BEGIN CERTIFICATE"* ]] || return 1
  rm -f "$WORKDIR"/chain-*.pem
  awk -v d="$WORKDIR" '/-----BEGIN CERTIFICATE-----/{n++; f=1; out=sprintf("%s/chain-%02d.pem", d, n)}
                       f{print > out} /-----END CERTIFICATE-----/{f=0}' <<<"$chain"
  for c in "$WORKDIR"/chain-*.pem; do
    if [[ $(cert_fp "$c") == "$fp" ]]; then cp "$c" "$dest"; return 0; fi
  done
  return 1
}
obtain_es_ca() {
  step "Establishing trust in the Elasticsearch CA"
  ES_CA_FILE="$WORKDIR/http_ca.crt"
  if [[ -n $ES_CA_PATH ]]; then
    cp "$ES_CA_PATH" "$ES_CA_FILE"
    [[ $(cert_fp "$ES_CA_FILE") == "$ES_CA_FP" ]] || die "The fingerprint of $ES_CA_PATH does not match the one entered."
  else
    local ip found=no
    for ip in "${ES_IPS[@]}"; do
      if fetch_ca_by_fp "$ip" 9200 "$ES_CA_FP" "$ES_CA_FILE"; then found=yes; break; fi
    done
    [[ $found == yes ]] || die "No certificate with that fingerprint was presented by the Elasticsearch nodes. Copy http_ca.crt from node 1 and give its path instead."
  fi
  es_remote_api GET / || die "Cannot log in to Elasticsearch with TLS verification ($API_CODE). Check the elastic password and port 9200."
  ok "Elasticsearch CA verified (fingerprint ${ES_CA_FP:0:16}…), login OK"
}
create_service_token() {   # create_service_token <kibana|fleet-server>  -> stdout
  local svc=$1 name
  name="${svc}-${HOST_SHORT//[^A-Za-z0-9_-]/-}-$(date +%s)"
  es_remote_api POST "/_security/service/elastic/${svc}/credential/token/${name}" \
    || die "Creating the ${svc} service token failed ($API_CODE): $API_BODY"
  sed -n 's/.*"value":"\([^"]*\)".*/\1/p' <<<"$API_BODY"
}
prompt_certs() {   # prompt_certs <component label>
  ask_yn OWN_CERTS "Use your own CA-signed certificate for $1 (recommended for production)?" n
  if [[ $OWN_CERTS == yes ]]; then
    ask OWN_CERT "Certificate file (PEM, SAN must include $HOST_NAME and/or $IP)" "" valid_file
    ask OWN_KEY  "Private key file (PEM, unencrypted)" "" valid_file
    ask OWN_CA   "CA certificate (chain) that signed it" "" valid_file
  else
    info "A local CA will be created in $LOCAL_CA_DIR to sign the $1 certificate."
  fi
}
make_certs() {   # make_certs <name>  -> CERT_FILE KEY_FILE CA_FILE
  local name=$1 san
  if [[ $OWN_CERTS == yes ]]; then CERT_FILE=$OWN_CERT; KEY_FILE=$OWN_KEY; CA_FILE=$OWN_CA; return 0; fi
  step "Creating a local CA and a certificate for $name"
  mkdir -p "$LOCAL_CA_DIR"; chmod 700 "$LOCAL_CA_DIR"
  if [[ ! -f $LOCAL_CA_DIR/ca.crt ]]; then
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "$LOCAL_CA_DIR/ca.key" -out "$LOCAL_CA_DIR/ca.crt" \
      -subj "/CN=Elastic Stack local CA (${HOST_SHORT})" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  fi
  san="DNS:${HOST_NAME},DNS:localhost,IP:${IP},IP:127.0.0.1"
  [[ $HOST_SHORT != "$HOST_NAME" ]] && san="DNS:${HOST_SHORT},${san}"
  cat > "$LOCAL_CA_DIR/$name.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san}
EXT
  openssl req -newkey rsa:2048 -nodes -keyout "$LOCAL_CA_DIR/$name.key" -out "$LOCAL_CA_DIR/$name.csr" \
    -subj "/CN=${HOST_NAME}" 2>/dev/null
  openssl x509 -req -in "$LOCAL_CA_DIR/$name.csr" -CA "$LOCAL_CA_DIR/ca.crt" -CAkey "$LOCAL_CA_DIR/ca.key" \
    -CAcreateserial -days 825 -sha256 -extfile "$LOCAL_CA_DIR/$name.ext" -out "$LOCAL_CA_DIR/$name.crt" 2>/dev/null
  chmod 600 "$LOCAL_CA_DIR"/*.key
  CERT_FILE="$LOCAL_CA_DIR/$name.crt"; KEY_FILE="$LOCAL_CA_DIR/$name.key"; CA_FILE="$LOCAL_CA_DIR/ca.crt"
  ok "Certificate issued (SAN: $san)"
}

# ---- Kibana (Node.js) heap ---------------------------------------------------
valid_mb() { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1024)); }
prompt_kibana_heap() {
  local ram def
  ram=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
  if ((ram >= 10240)); then def=8192; else def=$(( (ram * 3 / 4) / 512 * 512 )); ((def < 1024)) && def=1024; fi
  info "This VM has ${ram} MB RAM. Kibana's Node.js heap limit (MB); leave ~2 GB for the OS and Kibana's native memory."
  ask KB_HEAP_MB "Kibana heap in MB (8 GB = 8192)" "$def" valid_mb
  if ((KB_HEAP_MB > ram - 1536)); then
    warn "${KB_HEAP_MB} MB leaves less than 1.5 GB for the OS on a ${ram} MB VM – give this VM more RAM or lower the heap."
    local c; ask_yn c "Keep ${KB_HEAP_MB} MB anyway?" n; [[ $c == yes ]] || prompt_kibana_heap
  fi
}
write_kibana_heap() {   # config/node.options is read by bin/kibana (KBN_PATH_CONF)
  local f="$KB_HOME/config/node.options"
  touch "$f"
  sed -i '/--max-old-space-size/d' "$f"
  printf '\n# Kibana heap limit (set by elastic-node-setup.sh)\n--max-old-space-size=%s\n' "$KB_HEAP_MB" >> "$f"
  chown kibana:kibana "$f"
  ok "Kibana heap limit set to ${KB_HEAP_MB} MB ($f)"
}

# =============================================================================
#  Role: kibana
# =============================================================================
# ---- Stack Monitoring via Elastic Agent (Elastic's recommended collection) ----
fleet_ensure_policy() {   # fleet_ensure_policy <id> <name>
  local body
  kbn_api GET "/api/fleet/agent_policies/$1" && return 0
  body="{\"id\":\"$1\",\"name\":\"$2\",\"namespace\":\"default\",\"description\":\"Created by elastic-node-setup.sh\",\"monitoring_enabled\":[\"logs\",\"metrics\"]}"
  kbn_api POST "/api/fleet/agent_policies?sys_monitoring=true" "$body" && return 0
  kbn_api GET "/api/fleet/agent_policies/$1" && return 0
  kbn_api POST /api/fleet/agent_policies "$body"
}
fleet_pkg_version() {   # installs the latest compatible package, prints its version
  kbn_api POST "/api/fleet/epm/packages/$1" '{}' || true
  kbn_api GET "/api/fleet/epm/packages/$1" || return 1
  local v; v=$(grep -o '"version":"[0-9][^"]*"' <<<"$API_BODY" | head -n1 | cut -d'"' -f4)
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  echo "$v"
}
fleet_add_pkg_policy() {   # <name> <agent-policy-id> <package> <version> <inputs-json>
  kbn_api POST /api/fleet/package_policies \
    "{\"name\":\"$1\",\"namespace\":\"default\",\"policy_ids\":[\"$2\"],\"package\":{\"name\":\"$3\",\"version\":\"$4\"},\"inputs\":$5}" \
    && return 0
  [[ $API_CODE == 409 ]] && return 0      # already exists
  warn "Adding '$1' failed ($API_CODE): ${API_BODY:0:300}"; return 1
}
fleet_enrollment_token() {   # prints the enrollment token of an agent policy
  kbn_api GET "/api/fleet/enrollment_api_keys?perPage=100" || return 1
  tr '{' '\n' <<<"$API_BODY" | grep "\"policy_id\":\"$1\"" | grep -o '"api_key":"[^"]*"' | head -n1 | cut -d'"' -f4
}
setup_stack_monitoring() {
  step "Setting up Stack Monitoring (Elastic Agent + Elasticsearch/Kibana integrations)"
  local mon_pw es_v kb_v es_inputs kb_inputs
  # Built-in collector user (roles remote_monitoring_collector + remote_monitoring_agent)
  mon_pw=$(openssl rand -hex 24)
  es_remote_api POST /_security/user/remote_monitoring_user/_password "{\"password\":\"${mon_pw}\"}" \
    || { warn "Could not set the remote_monitoring_user password ($API_CODE)."; return 1; }
  fleet_ensure_policy "$SM_ES_POLICY" "Stack Monitoring - Elasticsearch" || { warn "Creating policy $SM_ES_POLICY failed ($API_CODE)."; return 1; }
  fleet_ensure_policy "$SM_KB_POLICY" "Stack Monitoring - Kibana"        || { warn "Creating policy $SM_KB_POLICY failed ($API_CODE)."; return 1; }
  es_v=$(fleet_pkg_version elasticsearch) || { warn "Elasticsearch integration unavailable (is epr.elastic.co reachable from this VM?)."; return 1; }
  kb_v=$(fleet_pkg_version kibana)        || { warn "Kibana integration unavailable (is epr.elastic.co reachable from this VM?)."; return 1; }

  # One agent per ES node, scope=node, local HTTPS endpoint verified with the ES CA.
  # The logfile input picks up the server, slow and GC logs.
  es_inputs="{\"elasticsearch-logfile\":{\"enabled\":true},\"elasticsearch-elasticsearch/metrics\":{\"enabled\":true,\"vars\":{\"hosts\":[\"https://localhost:9200\"],\"username\":\"remote_monitoring_user\",\"password\":\"${mon_pw}\",\"scope\":\"node\",\"ssl\":\"certificate_authorities: [${ES_HOME}/config/certs/http_ca.crt]\"}}}"
  kb_inputs="{\"kibana-logfile\":{\"enabled\":true},\"kibana-http/metrics\":{\"enabled\":false},\"kibana-kibana/metrics\":{\"enabled\":true,\"vars\":{\"hosts\":[\"https://${IP}:5601\"],\"username\":\"remote_monitoring_user\",\"password\":\"${mon_pw}\",\"ssl\":\"certificate_authorities: [${KB_HOME}/config/certs/ca.crt]\"}}}"
  fleet_add_pkg_policy "elasticsearch-stack-monitoring" "$SM_ES_POLICY" elasticsearch "$es_v" "$es_inputs" || return 1
  fleet_add_pkg_policy "kibana-stack-monitoring"        "$SM_KB_POLICY" kibana        "$kb_v" "$kb_inputs" || return 1
  ok "Policies '$SM_ES_POLICY' (elasticsearch $es_v) and '$SM_KB_POLICY' (kibana $kb_v) ready"

  SM_ES_TOKEN=$(fleet_enrollment_token "$SM_ES_POLICY" || true)
  SM_KB_TOKEN=$(fleet_enrollment_token "$SM_KB_POLICY" || true)
  [[ -n $SM_ES_TOKEN && -n $SM_KB_TOKEN ]] || { warn "Could not read the enrollment tokens – get them in Fleet > Enrollment tokens."; return 1; }
  ok "Enrollment tokens retrieved"
}

role_kibana() {
  prompt_this_host
  step "Stack settings"
  prompt_version
  prompt_es_ips
  ask_secret ELASTIC_PASSWORD "elastic password (set on node 1)" no
  prompt_es_trust
  ask FS_IP "Fleet Server VM IP (Kibana registers it in Fleet)" "" valid_ipv4
  ask FLEET_POLICY_ID "Fleet Server policy id" "fleet-server-policy" valid_cluster
  prompt_certs "Kibana (browser HTTPS)"
  ask_yn ENABLE_MONITORING "Create Stack Monitoring policies (Elasticsearch + Kibana integrations; needs epr.elastic.co)?" y
  prompt_kibana_heap
  confirm_or_abort; start_logging

  prepare_os kibana
  obtain_es_ca
  local sa_token; sa_token=$(create_service_token kibana)
  [[ -n $sa_token ]] || die "Empty Kibana service token."
  ok "Kibana service-account token created"
  make_certs kibana
  get_artifact kibana

  step "Installing Kibana ${STACK_VERSION}"
  id -u kibana >/dev/null 2>&1 || useradd --system --user-group --no-create-home \
      --home-dir "$KB_HOME" --shell "$(nologin_shell)" kibana
  local top; top=$(tar_top "$ARTIFACT_PATH"); [[ -n $top ]] || die "Cannot read $ARTIFACT_PATH"
  mkdir -p "$INSTALL_BASE"
  tar -xzf "$ARTIFACT_PATH" -C "$INSTALL_BASE"
  ln -sfn "$INSTALL_BASE/$top" "$KB_HOME"
  local cd="$KB_HOME/config/certs"
  mkdir -p "$KB_DATA_DIR" "$KB_LOG_DIR" "$cd"
  install -m 0644 "$ES_CA_FILE" "$cd/http_ca.crt"
  install -m 0644 "$CA_FILE"    "$cd/ca.crt"
  install -m 0644 "$CERT_FILE"  "$cd/kibana.crt"
  install -m 0600 "$KEY_FILE"   "$cd/kibana.key"
  chown -R kibana:kibana "$INSTALL_BASE/$top" "$KB_DATA_DIR" "$KB_LOG_DIR"
  chmod 750 "$KB_DATA_DIR" "$KB_LOG_DIR"

  cat > "$KB_HOME/config/kibana.yml" <<YML
# ======================== Managed by elastic-node-setup.sh ========================
server.port: 5601
server.host: "${IP}"
server.name: "${HOST_NAME}"
server.publicBaseUrl: "https://${IP}:5601"

# Browser -> Kibana TLS
server.ssl.enabled: true
server.ssl.certificate: ${cd}/kibana.crt
server.ssl.key: ${cd}/kibana.key

# Kibana -> Elasticsearch: all nodes, full TLS verification,
# service-account token held in the Kibana keystore.
elasticsearch.hosts: ["https://${ES1_IP}:9200","https://${ES2_IP}:9200","https://${ES3_IP}:9200"]
elasticsearch.ssl.certificateAuthorities: [ "${cd}/http_ca.crt" ]
elasticsearch.ssl.verificationMode: full

path.data: ${KB_DATA_DIR}

logging:
  appenders:
    file:
      type: rolling-file
      fileName: ${KB_LOG_DIR}/kibana.log
      policy:
        type: size-limit
        size: 256mb
      strategy:
        type: numeric
        pattern: '-%i'
        max: 10
      layout:
        type: json
  root:
    appenders: [default, file]
YML
  chown kibana:kibana "$KB_HOME/config/kibana.yml"; chmod 640 "$KB_HOME/config/kibana.yml"
  write_kibana_heap

  # run from KB_HOME: Kibana tools look for package.json in the current directory,
  # and the kibana user cannot read the operator's home directory
  kb_ks() { ( cd "$KB_HOME" && runuser -u kibana -- env KBN_PATH_CONF="$KB_HOME/config" "$KB_HOME/bin/kibana-keystore" "$@" ); }
  kb_ks create >/dev/null </dev/null
  printf '%s' "$sa_token" | kb_ks add elasticsearch.serviceAccountToken --stdin >/dev/null
  local k
  for k in xpack.encryptedSavedObjects.encryptionKey xpack.security.encryptionKey xpack.reporting.encryptionKey; do
    openssl rand -hex 32 | tr -d '\n' | kb_ks add "$k" --stdin >/dev/null
  done
  ok "Secrets stored in the Kibana keystore"

  cat > /etc/systemd/system/kibana.service <<UNIT
[Unit]
Description=Kibana
Documentation=https://www.elastic.co
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=kibana
Group=kibana
Environment=KBN_PATH_CONF=${KB_HOME}/config
WorkingDirectory=${KB_HOME}
ExecStart=${KB_HOME}/bin/kibana
StandardOutput=journal
StandardError=inherit
LimitNOFILE=65535
TimeoutStopSec=60
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now kibana.service >/dev/null 2>&1

  step "Waiting for Kibana (first start runs migrations, several minutes)"
  KB_CA="$cd/ca.crt"
  local t=0 ready=no
  while ((t < 900)); do
    if kbn_api GET /api/status; then
      [[ $API_BODY == *'"level":"available"'* ]] && { ready=yes; break; }
      ((t > 240)) && [[ $API_BODY == *'"level":"degraded"'* ]] && { ready=degraded; break; }
    fi
    sleep 10; t=$((t + 10))
  done
  case $ready in
    yes) ok "Kibana is available" ;;
    degraded) warn "Kibana is up but 'degraded' – review Stack Management > Status." ;;
    *) journalctl -u kibana.service -n 60 --no-pager >&2 || true; die "Kibana did not become available." ;;
  esac

  step "Configuring Fleet (output, Fleet Server host, Fleet Server policy)"
  local fleet_url="https://${FS_IP}:${FLEET_PORT}" es_hosts body _ done_setup=no
  es_hosts="[\"https://${ES1_IP}:9200\",\"https://${ES2_IP}:9200\",\"https://${ES3_IP}:9200\"]"
  for _ in $(seq 1 12); do kbn_api POST /api/fleet/setup '{}' && { done_setup=yes; break; }; sleep 15; done
  [[ $done_setup == yes ]] || die "Fleet setup failed ($API_CODE): $API_BODY"

  kbn_api PUT /api/fleet/outputs/fleet-default-output \
    "{\"name\":\"default\",\"type\":\"elasticsearch\",\"hosts\":${es_hosts},\"is_default\":true,\"is_default_monitoring\":true,\"ca_trusted_fingerprint\":\"${ES_CA_FP}\"}" \
    || die "Updating the default output failed ($API_CODE): $API_BODY"
  ok "Default output -> all 3 Elasticsearch nodes (CA pinned by fingerprint)"

  kbn_api GET /api/fleet/fleet_server_hosts || die "Listing Fleet Server hosts failed ($API_CODE)."
  if [[ $API_BODY != *"\"${fleet_url}\""* ]]; then
    kbn_api POST /api/fleet/fleet_server_hosts \
      "{\"name\":\"Fleet Server (${FS_IP})\",\"host_urls\":[\"${fleet_url}\"],\"is_default\":true}" \
      || die "Adding the Fleet Server host failed ($API_CODE): $API_BODY"
  fi
  ok "Fleet Server host ${fleet_url} registered as default"

  if ! kbn_api GET "/api/fleet/agent_policies/${FLEET_POLICY_ID}"; then
    body="{\"id\":\"${FLEET_POLICY_ID}\",\"name\":\"Fleet Server Policy\",\"namespace\":\"default\",\"description\":\"Created by elastic-node-setup.sh\",\"has_fleet_server\":true,\"monitoring_enabled\":[\"logs\",\"metrics\"]}"
    if ! kbn_api POST "/api/fleet/agent_policies?sys_monitoring=true" "$body"; then
      warn "Policy with the System integration failed ($API_CODE) – is epr.elastic.co reachable? Retrying without it."
      kbn_api GET "/api/fleet/agent_policies/${FLEET_POLICY_ID}" \
        || kbn_api POST /api/fleet/agent_policies "$body" \
        || die "Creating the Fleet Server policy failed ($API_CODE): $API_BODY"
    fi
  fi
  ok "Fleet Server policy '${FLEET_POLICY_ID}' ready"

  SM_ES_TOKEN=""; SM_KB_TOKEN=""
  if [[ $ENABLE_MONITORING == yes ]]; then
    setup_stack_monitoring || warn "Stack Monitoring was not fully configured – see the messages above; you can add it later in Fleet."
  fi

  local S=/root/elastic-kibana-summary.txt
  {
    echo "Kibana ($HOST_NAME / $IP) – version $STACK_VERSION"
    echo
    echo "URL           : https://${IP}:5601   (user: elastic)"
    echo "Kibana CA     : ${cd}/ca.crt   (import in browsers to trust the Kibana certificate)"
    echo "Fleet Server  : ${fleet_url}  policy '${FLEET_POLICY_ID}'"
    echo
    echo "Next: on the Fleet Server VM run   sudo ./elastic-node-setup.sh --role fleet"
    if [[ -n $SM_ES_TOKEN || -n $SM_KB_TOKEN ]]; then
      echo
      echo "Stack Monitoring – after the Fleet Server is up, run   sudo ./elastic-node-setup.sh --role monitor"
      echo "  on each Elasticsearch VM, with this enrollment token:"
      echo "    ${SM_ES_TOKEN:-<not created>}"
      echo "  on this Kibana VM, with this enrollment token:"
      echo "    ${SM_KB_TOKEN:-<not created>}"
      echo "  View it in Kibana > Stack Monitoring."
    fi
  } > "$S"; chmod 600 "$S"
  step "Done"; sed 's/^/    /' "$S"; info ""; info "Saved to $S  |  log: $LOG_FILE"
}

# =============================================================================
#  Role: fleet  (Fleet Server)
# =============================================================================
role_fleet() {
  prompt_this_host
  step "Stack settings"
  prompt_version
  prompt_es_ips
  ask_secret ELASTIC_PASSWORD "elastic password (set on node 1)" no
  prompt_es_trust
  ask FLEET_POLICY_ID "Fleet Server policy id (created by the Kibana run)" "fleet-server-policy" valid_cluster
  prompt_certs "Fleet Server"
  confirm_or_abort; start_logging

  prepare_os fleet
  obtain_es_ca
  local fs_token; fs_token=$(create_service_token fleet-server)
  [[ -n $fs_token ]] || die "Empty Fleet Server service token."
  ok "fleet-server service-account token created"
  make_certs fleet-server
  get_artifact agent

  step "Installing Fleet Server (Elastic Agent ${STACK_VERSION}, servers flavor)"
  mkdir -p "$FLEET_CERT_DIR"; chmod 700 "$FLEET_CERT_DIR"
  install -m 0644 "$ES_CA_FILE" "$FLEET_CERT_DIR/http_ca.crt"
  install -m 0644 "$CA_FILE"    "$FLEET_CERT_DIR/ca.crt"
  # Serve the full chain (leaf + CA) so other VMs can fetch and verify the CA
  # by fingerprint (used by --role monitor).
  { cat "$CERT_FILE"; echo; cat "$CA_FILE"; } | sed '/^$/d' > "$FLEET_CERT_DIR/fleet-server.crt"
  chmod 0644 "$FLEET_CERT_DIR/fleet-server.crt"
  install -m 0600 "$KEY_FILE"   "$FLEET_CERT_DIR/fleet-server.key"
  ( umask 077; printf '%s' "$fs_token" > "$FLEET_CERT_DIR/fleet-server.token" )

  local stg="$INSTALL_BASE/staging" top
  mkdir -p "$stg"
  top=$(tar_top "$ARTIFACT_PATH"); [[ -n $top ]] || die "Cannot read $ARTIFACT_PATH"
  rm -rf "${stg:?}/$top"; tar -xzf "$ARTIFACT_PATH" -C "$stg"
  ( cd "$stg/$top" && ./elastic-agent install --non-interactive --install-servers \
      --url="https://${IP}:${FLEET_PORT}" \
      --certificate-authorities="$FLEET_CERT_DIR/ca.crt" \
      --fleet-server-es="https://${ES1_IP}:9200" \
      --fleet-server-es-ca="$FLEET_CERT_DIR/http_ca.crt" \
      --fleet-server-service-token-path="$FLEET_CERT_DIR/fleet-server.token" \
      --fleet-server-policy="$FLEET_POLICY_ID" \
      --fleet-server-cert="$FLEET_CERT_DIR/fleet-server.crt" \
      --fleet-server-cert-key="$FLEET_CERT_DIR/fleet-server.key" \
      --fleet-server-port="$FLEET_PORT" ) \
    || die "elastic-agent install failed – did the Kibana run create policy '${FLEET_POLICY_ID}'?"
  rm -rf "${stg:?}/$top"

  step "Waiting for Fleet Server to report HEALTHY"
  local s _ healthy=no
  for _ in $(seq 1 60); do
    s=$(curl -s --max-time 5 --cacert "$FLEET_CERT_DIR/ca.crt" "https://${IP}:${FLEET_PORT}/api/status" || true)
    [[ $s == *'"HEALTHY"'* ]] && { healthy=yes; break; }
    sleep 5
  done
  [[ $healthy == yes ]] || { elastic-agent status >&2 || true; die "Fleet Server did not become healthy."; }
  ok "Fleet Server is HEALTHY"

  local S=/root/elastic-fleet-summary.txt
  {
    echo "Fleet Server ($HOST_NAME / $IP) – version $STACK_VERSION"
    echo
    echo "URL                : https://${IP}:${FLEET_PORT}"
    echo "CA for agents      : $FLEET_CERT_DIR/ca.crt"
    echo "CA fingerprint     : $(cert_fp "$FLEET_CERT_DIR/ca.crt")"
    echo "                     (enter this in --role monitor on the ES and Kibana VMs)"
    echo "Service            : systemctl status elastic-agent"
    echo
    echo "Next: Stack Monitoring – run  sudo ./elastic-node-setup.sh --role monitor  on each"
    echo "      Elasticsearch VM and the Kibana VM (tokens are in /root/elastic-kibana-summary.txt on Kibana)."
    echo
    echo "Enroll an Elastic Agent (token from Kibana > Fleet > Enrollment tokens):"
    echo "  sudo ./elastic-agent install --url=https://${IP}:${FLEET_PORT} \\"
    echo "       --enrollment-token=<TOKEN> --certificate-authorities=/path/to/ca.crt"
  } > "$S"; chmod 600 "$S"
  step "Done"; sed 's/^/    /' "$S"; info ""; info "Saved to $S  |  log: $LOG_FILE"
}

# =============================================================================
#  Main
# =============================================================================
# =============================================================================
#  Role: monitor  (Elastic Agent for Stack Monitoring on ES and Kibana VMs)
# =============================================================================
role_monitor() {
  [[ ! -e /opt/Elastic/Agent ]] || die "Elastic Agent is already installed on this VM."
  local target ver_default=""
  if [[ -d $ES_HOME ]]; then target="Elasticsearch"
  elif [[ -d $KB_HOME ]]; then target="Kibana"
  else die "Run --role monitor on an Elasticsearch or Kibana VM installed by this script (the Fleet Server monitors itself)."; fi
  ver_default=$(basename "$(readlink -f "$([[ $target == Elasticsearch ]] && echo "$ES_HOME" || echo "$KB_HOME")")" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  detect_os; OS_FAMILY=$DETECTED_OS

  step "Stack Monitoring agent for this ${target} VM"
  STACK_VERSION=""
  ask STACK_VERSION "Elastic Agent version (match the stack)" "${ver_default:-$DEFAULT_STACK_VERSION}" valid_version
  ask FS_IP "Fleet Server IP" "" valid_ipv4
  info "Fleet Server CA fingerprint (printed at the end of the fleet run):"
  ask FLEET_CA_FP "SHA-256 fingerprint" "" valid_fp
  FLEET_CA_FP=$(norm_fp "$FLEET_CA_FP")
  info "Enrollment token for the '${target}' Stack Monitoring policy (in /root/elastic-kibana-summary.txt on the Kibana VM):"
  ask_token MON_TOKEN "Fleet enrollment token" fleet "$CLI_TOKEN"
  confirm_or_abort; start_logging

  step "Establishing trust in the Fleet Server CA"
  mkdir -p "$FLEET_CA_DIR"; chmod 755 "$FLEET_CA_DIR"
  fetch_ca_by_fp "$FS_IP" "$FLEET_PORT" "$FLEET_CA_FP" "$FLEET_CA_DIR/ca.crt" \
    || die "Fleet Server at ${FS_IP}:${FLEET_PORT} did not present a certificate with that fingerprint."
  chmod 644 "$FLEET_CA_DIR/ca.crt"
  ok "Fleet Server CA verified"

  get_artifact agent
  step "Installing Elastic Agent ${STACK_VERSION} (enrolled in Fleet)"
  local stg="$INSTALL_BASE/staging" top
  mkdir -p "$stg"
  top=$(tar_top "$ARTIFACT_PATH"); [[ -n $top ]] || die "Cannot read $ARTIFACT_PATH"
  rm -rf "${stg:?}/$top"; tar -xzf "$ARTIFACT_PATH" -C "$stg"
  ( cd "$stg/$top" && ./elastic-agent install --non-interactive \
      --url="https://${FS_IP}:${FLEET_PORT}" \
      --enrollment-token="$MON_TOKEN" \
      --certificate-authorities="$FLEET_CA_DIR/ca.crt" ) \
    || die "elastic-agent install failed."
  rm -rf "${stg:?}/$top"

  local _ healthy=no
  for _ in $(seq 1 36); do
    elastic-agent status 2>/dev/null | grep -q 'HEALTHY' && { healthy=yes; break; }
    sleep 5
  done
  if [[ $healthy == yes ]]; then ok "Agent is running and enrolled"
  else warn "Agent not HEALTHY yet – check 'elastic-agent status' and Kibana > Fleet > Agents."; fi
  step "Done"
  info "Data appears in Kibana > Stack Monitoring within a few minutes."
  info "Log: $LOG_FILE"
}

usage() {
  sed -n '3,/Air-gapped/p' "$0" | sed 's/^#//'
}
main() {
  ROLE=""; CLI_TOKEN=""
  while (($#)); do
    case $1 in
      --role) ROLE=${2-}; shift 2 ;;
      --token) CLI_TOKEN=${2-}; shift 2 ;;
      --token-file) [[ -r ${2-} ]] || die "Cannot read token file: ${2-}"
                    CLI_TOKEN=$(<"$2"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1 (see --help)" ;;
    esac
  done
  [[ $EUID -eq 0 ]] || die "Run as root:  sudo $0"
  ((BASH_VERSINFO[0] >= 4)) || die "bash 4+ is required."
  [[ -d /run/systemd/system ]] || die "systemd is required."
  command -v curl >/dev/null || die "curl is required (install it first)."

  if [[ -z $ROLE ]]; then
    printf '%sElastic Stack node setup v%s%s\n' "$B" "$SCRIPT_VERSION" "$N"
    info "Run order: es-first -> es-join (node 2) -> es-join (node 3) -> kibana -> fleet -> monitor (ES VMs + Kibana VM)"
    info "  1) es-first  Elasticsearch node 1 (bootstraps the cluster)"
    info "  2) es-join   Elasticsearch node 2 or 3"
    info "  3) kibana    Kibana"
    info "  4) fleet     Fleet Server"
    info "  5) token     Print a node enrollment token (run on node 1)"
    info "  6) monitor   Stack Monitoring agent (run on each ES VM and the Kibana VM)"
    local r; ask r "Role for THIS VM" ""
    case $r in 1|es-first) ROLE=es-first ;; 2|es-join) ROLE=es-join ;; 3|kibana) ROLE=kibana ;;
                4|fleet) ROLE=fleet ;; 5|token) ROLE=token ;; 6|monitor) ROLE=monitor ;; *) die "Unknown role: $r" ;; esac
  fi
  [[ $ROLE == token ]] && { role_token; exit 0; }
  if [[ $ROLE == monitor ]]; then detect_arch; role_monitor; exit 0; fi
  check_not_installed
  detect_arch
  case $ROLE in
    es-first) role_es_first ;;
    es-join)  role_es_join ;;
    kibana)   role_kibana ;;
    fleet)    role_fleet ;;
    *) die "Unknown role: $ROLE" ;;
  esac
}

main "$@"
