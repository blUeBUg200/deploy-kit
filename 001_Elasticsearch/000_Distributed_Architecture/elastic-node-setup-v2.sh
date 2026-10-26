#!/usr/bin/env bash
# =============================================================================
#  elastic-node-setup-v2.sh  —  tiered, air-gapped-ready Elastic Stack 9.x
#
#  Run ON EACH VM and choose that VM's role. Binary (tar.gz) installs only.
#
#    Order  VM                      Role          What it does
#    -----  ----------------------  ------------  ---------------------------------
#      0    staging PC (Internet)   bundle        downloads everything into one
#                                                 air-gap bundle (.tar)
#      1    repository server       repo          artifact registry (HTTP 9080 /
#                                                 HTTPS 9443) + Elastic Package
#                                                 Registry (HTTPS 8443), containers
#      2    master-1                es-first      cluster plan, cluster CA, one
#                                                 encrypted *node pack* per VM,
#                                                 installs master-1
#      3    master-2, master-3      es-node       dedicated masters (cluster forms)
#      4    hot-1..3                es-node       data_hot + data_content + ingest
#      5    warm-1..2               es-node       data_warm
#      6    frozen-1                es-node       data_frozen (searchable snapshots)
#      7    master-1                es-finalize   licence, snapshot repository,
#                                                 ILM hot→warm→frozen, SLM
#      8    Kibana VM               kibana        HTTPS Kibana + Fleet (air-gapped)
#      9    Fleet Server VM         fleet         Elastic Agent as Fleet Server
#     10    ES + Kibana VMs         monitor       optional Stack Monitoring agent
#           master-1                pack          re-issue a node pack
#
#  Usage:  sudo ./elastic-node-setup-v2.sh [--role ROLE] [--pack FILE]
#                 [--plan FILE] [--token-file FILE | --token VALUE]
#  Env overrides (mirrors / testing): ELASTIC_ARTIFACTS_URL,
#    ELASTIC_ENDPOINT_ARTIFACTS_URL, ELASTIC_ML_MODELS_URL, ELASTIC_EPR_IMAGE,
#    REPO_NGINX_IMAGE, ARTIFACT_DIR
# =============================================================================
set -Eeuo pipefail

SCRIPT_VERSION="v2.0.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
DEFAULT_STACK_VERSION="9.5.5"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$SCRIPT_DIR}"

# ---- Upstream sources (only the bundle / internet modes use these) -----------
UPSTREAM_ARTIFACTS="${ELASTIC_ARTIFACTS_URL:-https://artifacts.elastic.co}"
UPSTREAM_ENDPOINT="${ELASTIC_ENDPOINT_ARTIFACTS_URL:-https://artifacts.security.elastic.co}"
UPSTREAM_ML="${ELASTIC_ML_MODELS_URL:-https://ml-models.elastic.co}"
EPR_IMAGE="${ELASTIC_EPR_IMAGE:-docker.elastic.co/package-registry/distribution}"
NGINX_IMAGE="${REPO_NGINX_IMAGE:-docker.io/library/nginx:stable-alpine}"

# ---- Layout -------------------------------------------------------------------
INSTALL_BASE="/opt/elastic"
ES_HOME="${INSTALL_BASE}/elasticsearch"
KB_HOME="${INSTALL_BASE}/kibana"
ES_DATA_DIR="/var/lib/elasticsearch"
ES_LOG_DIR="/var/log/elasticsearch"
ES_TMP_DIR="${INSTALL_BASE}/tmp/elasticsearch"
KB_DATA_DIR="/var/lib/kibana"
KB_LOG_DIR="/var/log/kibana"
FLEET_CERT_DIR="${INSTALL_BASE}/fleet-server-certs"
STATE_DIR="/etc/elastic-node-setup"             # per-VM: node.env, ca.crt, repo-ca.crt
CLUSTER_DIR="/root/elastic-cluster"             # master-1 only: plan, CA, packs
REPO_BASE_DEFAULT="/srv/elastic-repo"
FLEET_PORT=8220
REPO_HTTP_PORT=9080                             # agents (Elastic: no TLS for agent downloads)
REPO_HTTPS_PORT=9443                            # installer downloads, verified TLS
EPR_PORT=8443                                   # Elastic Package Registry (TLS)
SM_ES_POLICY="stack-monitoring-elasticsearch"
SM_KB_POLICY="stack-monitoring-kibana"
FLEET_POLICY_ID="fleet-server-policy"
HEAP_CAP_MB=30720
HEAP_FALLBACK="26g"
PBKDF2_ITER=600000

# Node roles per tier (no generic "data" role – it would override the tiers)
declare -A TIER_ROLES=(
  [master]="master"
  [hot]="data_hot, data_content, ingest, ml, transform, remote_cluster_client"
  [warm]="data_warm"
  [frozen]="data_frozen" )
# How _cat/nodes shows them (node.role column)
declare -A TIER_LETTERS=( [master]="m" [hot]="hilrst" [warm]="w" [frozen]="f" )

# ---- Output helpers -----------------------------------------------------------
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
valid_addr()    { valid_ipv4 "$1" || valid_hostname "$1"; }
valid_version() { [[ $1 =~ ^9\.[0-9]+\.[0-9]+$ ]]; }
valid_name()    { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }
valid_file()    { [[ -r $1 ]] || { echo "    File not found/readable: $1" >&2; return 1; }; }
valid_int()     { [[ $1 =~ ^[0-9]+$ ]]; }
valid_uid()     { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1000 && $1 < 60000)); }
valid_abs()     { [[ $1 == /* && $1 != *[[:space:]]* ]]; }
valid_url()     { [[ $1 =~ ^https?://[^[:space:]]+$ ]]; }
valid_days()    { [[ $1 =~ ^[0-9]+d$ ]]; }
valid_size()    { [[ $1 =~ ^[0-9]+(gb|mb|tb)$ ]]; }
valid_cache()   { [[ $1 =~ ^([0-9]{1,2}%|[0-9]+(gb|tb|mb))$ ]]; }
valid_token()   { [[ $1 =~ ^[A-Za-z0-9+/=]{40,}$ ]]; }
norm_fp()       { local f=${1//[:[:space:]]/}; echo "${f,,}"; }
valid_fp()      { [[ $(norm_fp "$1") =~ ^[0-9a-f]{64}$ ]]; }
valid_secret12(){
  ((${#1} >= 12)) || { echo "    Must be at least 12 characters." >&2; return 1; }
  [[ $1 != *'"'* && $1 != *'\'* ]] || { echo "    Must not contain \" or \\." >&2; return 1; }
}
clean_token() {
  local t=$1
  t=${t//$'\e[200~'/}; t=${t//$'\e[201~'/}
  t=${t//[[:space:]]/}; t=${t//\"/}; t=${t//\'/}
  printf '%s' "$t"
}
token_complete() {   # Fleet enrollment token = base64("<id>:<key>")
  local t=$1 d
  valid_token "$t" || return 1
  d=$(printf '%s' "$t" | base64 -d 2>/dev/null) || return 1
  [[ $d =~ ^[A-Za-z0-9_-]{10,}:[A-Za-z0-9_-]{10,}$ ]]
}
ask_token() {   # ask_token VAR "label" [preset]
  local __v=$1 __label=$2 __pre=${3-} __line __acc
  if [[ -n $__pre ]]; then
    __acc=$(clean_token "$__pre")
    token_complete "$__acc" || die "The $__label supplied via --token/--token-file is not valid."
    printf -v "$__v" '%s' "$__acc"; ok "$__label taken from the command line/file"; return 0
  fi
  while true; do
    info "Paste the $__label and press Enter:"
    __acc=""
    while IFS= read -r -e -p "    > " __line || { [[ -n $__acc ]] && break; exit 1; }; do
      __line=$(clean_token "$__line")
      [[ -z $__line ]] && break
      __acc+=$__line
      token_complete "$__acc" && break
      info "(partial: ${#__acc} characters – keep pasting, or Enter on an empty line)"
    done
    token_complete "$__acc" && { printf -v "$__v" '%s' "$__acc"; ok "$__label accepted"; return 0; }
    warn "Not a valid/complete $__label. Copy it again – or use --token-file."
  done
}
ask() {   # ask VAR "prompt" [default] [validator]
  local __v=$1 __p=$2 __d=${3-} __f=${4-} __a
  while true; do
    if [[ -n $__d ]]; then read -r -p "    $__p [$__d]: " __a || exit 1; __a=${__a:-$__d}
    else read -r -p "    $__p: " __a || exit 1; fi
    [[ -z $__a ]] && { echo "    A value is required." >&2; continue; }
    if [[ -n $__f ]] && ! "$__f" "$__a"; then echo "    Invalid value: $__a" >&2; continue; fi
    printf -v "$__v" '%s' "$__a"; return 0
  done
}
ask_optional() {   # blank allowed
  local __v=$1 __p=$2 __f=${3-} __a
  while true; do
    read -r -p "    $__p: " __a || exit 1
    if [[ -n $__a && -n $__f ]] && ! "$__f" "$__a"; then echo "    Invalid value: $__a" >&2; continue; fi
    printf -v "$__v" '%s' "$__a"; return 0
  done
}
ask_secret() {   # ask_secret VAR "prompt" confirm(yes|no) [validator]
  local __v=$1 __p=$2 __c=$3 __f=${4-} __a __b
  while true; do
    read -r -s -p "    $__p: " __a || exit 1; echo
    [[ -z $__a ]] && { echo "    A value is required." >&2; continue; }
    if [[ -n $__f ]] && ! "$__f" "$__a"; then continue; fi
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
ask_choice() {   # ask_choice VAR "prompt" default opt1 opt2 ...   (number or name)
  local __v=$1 __p=$2 __d=$3 __a i; shift 3
  local -a o=("$@")
  for i in "${!o[@]}"; do info "  $((i + 1))) ${o[$i]}"; done
  while true; do
    read -r -p "    $__p [$__d]: " __a || exit 1; __a=${__a:-$__d}
    if [[ $__a =~ ^[0-9]+$ ]] && ((__a >= 1 && __a <= ${#o[@]})); then __a=${o[$((__a - 1))]}; fi
    for i in "${o[@]}"; do [[ $__a == "$i" ]] && { printf -v "$__v" '%s' "$__a"; return 0; }; done
    echo "    Choose one of: ${o[*]}" >&2
  done
}
confirm_or_abort() { local go; ask_yn go "Proceed?" n; [[ $go == yes ]] || die "Aborted by user."; }
start_logging() {
  mkdir -p /var/log
  LOG_FILE="/var/log/elastic-node-setup-${ROLE}-$(date +%Y%m%d-%H%M%S).log"
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# =============================================================================
#  Host detection
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
normalize_os() {
  case "${1,,}" in
    1|debian|ubuntu|deb) echo debian ;;
    2|rhel|redhat|centos|rocky|alma|almalinux|oracle|ol|fedora|amzn|rpm) echo rhel ;;
    3|suse|sles|opensuse) echo suse ;;
    *) return 1 ;;
  esac
}
valid_os() { normalize_os "$1" >/dev/null; }
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  ES_ARCH=x86_64;  AGENT_ARCH=x86_64 ;;
    aarch64|arm64) ES_ARCH=aarch64; AGENT_ARCH=arm64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}
ip_is_local() { ip -o addr 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$1"; }
prompt_os_family() {
  detect_os
  local os; ask os "OS family (debian|rhel|suse)" "$([[ $DETECTED_OS != unknown ]] && echo "$DETECTED_OS")" valid_os
  OS_FAMILY=$(normalize_os "$os")
  if [[ $DETECTED_OS != unknown && $DETECTED_OS != "$OS_FAMILY" ]]; then
    warn "This host reports '$DETECTED_OS' ($OS_PRETTY) but you chose '$OS_FAMILY'."
    local c; ask_yn c "Continue anyway?" n; [[ $c == yes ]] || die "Aborted."
  fi
}
prompt_host_basics() {   # prompt_host_basics <name> <ip>   (values known from the plan/pack)
  HOST_NAME=$1; HOST_SHORT=${1%%.*}; IP=$2
  step "This host: ${HOST_NAME} (${IP})"
  ip_is_local "$IP" || warn "$IP is not configured on any local interface of this VM – is this the right pack/VM?"
  prompt_os_family
  ask_yn SET_HOSTNAME "Set the OS hostname to '$HOST_NAME'?" y
  ask_yn CONFIG_FW    "Open the required ports in firewalld/ufw (if active)?" y
}
prompt_this_host() {   # free-form (roles without a plan/pack)
  step "This host"
  local def_ip; def_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ask HOST_NAME "Hostname for this VM" "$(hostname -f 2>/dev/null || hostname)" valid_hostname
  HOST_SHORT=${HOST_NAME%%.*}
  ask IP "IP address of this VM" "$def_ip" valid_ipv4
  ip_is_local "$IP" || warn "$IP is not configured on any local interface."
  prompt_os_family
  ask_yn SET_HOSTNAME "Set the OS hostname to '$HOST_NAME'?" y
  ask_yn CONFIG_FW    "Open the required ports in firewalld/ufw (if active)?" y
}
prompt_version() { ask STACK_VERSION "Elastic Stack version (same on every VM)" "$DEFAULT_STACK_VERSION" valid_version; }

# =============================================================================
#  Certificates / TLS helpers
# =============================================================================
cert_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'; }
fetch_ca_by_fp() {   # fetch_ca_by_fp <host> <port> <fingerprint> <dest>
  # Saves the certificate in the server's TLS chain whose SHA-256 fingerprint
  # matches the one the operator copied from the other VM (trust on verification).
  local host=$1 port=$2 fp=$3 dest=$4 chain c
  chain=$(timeout 15 openssl s_client -connect "${host}:${port}" -servername "$host" -showcerts </dev/null 2>/dev/null || true)
  [[ $chain == *"BEGIN CERTIFICATE"* ]] || return 1
  rm -f "$WORKDIR"/chain-*.pem
  awk -v d="$WORKDIR" '/-----BEGIN CERTIFICATE-----/{n++; f=1; out=sprintf("%s/chain-%02d.pem", d, n)}
                       f{print > out} /-----END CERTIFICATE-----/{f=0}' <<<"$chain"
  for c in "$WORKDIR"/chain-*.pem; do
    if [[ $(cert_fp "$c") == "$fp" ]]; then cp "$c" "$dest"; return 0; fi
  done
  return 1
}
ca_create() {   # ca_create <dir> <CN>
  local d=$1 cn=$2
  mkdir -p "$d"; chmod 700 "$d"
  [[ -f $d/ca.crt ]] && return 0
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "$d/ca.key" -out "$d/ca.crt" -subj "/CN=${cn}" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 600 "$d/ca.key"
}
cert_issue() {   # cert_issue <ca-dir> <out-dir> <name> <dns...> -- <ip...>
  # Server+client certificate (TLS transport uses mutual authentication).
  local cad=$1 out=$2 name=$3 san="" x; shift 3
  local mode=dns
  for x in "$@"; do
    [[ $x == -- ]] && { mode=ip; continue; }
    [[ -n $san ]] && san+=","
    if [[ $mode == dns ]]; then san+="DNS:${x}"; else san+="IP:${x}"; fi
  done
  mkdir -p "$out"
  cat > "$out/$name.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=${san}
EXT
  openssl req -newkey rsa:2048 -nodes -keyout "$out/$name.key" -out "$out/$name.csr" -subj "/CN=${name}" 2>/dev/null
  openssl x509 -req -in "$out/$name.csr" -CA "$cad/ca.crt" -CAkey "$cad/ca.key" -CAcreateserial \
    -days 1095 -sha256 -extfile "$out/$name.ext" -out "$out/$name.crt" 2>/dev/null
  chmod 600 "$out/$name.key"; rm -f "$out/$name.csr"
}

# =============================================================================
#  HTTP helpers (TLS verified; credentials via a temp curl config file)
# =============================================================================
API_CODE=""; API_BODY=""
jgrep() { grep -o "$@" || true; }   # grep -o that never trips errexit/pipefail
_http() {   # _http METHOD URL CA_FILE BODY [extra-header ...]
  local m=$1 url=$2 cafile=$3 b=$4 cfg out x; shift 4
  local -a dopt=() hopt=()
  [[ -n $b ]] && dopt=(--data-binary "$b")
  for x in "$@"; do hopt+=(-H "$x"); done
  cfg=$(mktemp); chmod 600 "$cfg"; printf 'user = "elastic:%s"\n' "$ELASTIC_PASSWORD" > "$cfg"
  out=$(curl -sS --max-time 180 --cacert "$cafile" -K "$cfg" -X "$m" -H 'Content-Type: application/json' \
        ${hopt[@]+"${hopt[@]}"} ${dopt[@]+"${dopt[@]}"} -w '\n%{http_code}' "$url" 2>/dev/null) || out=$'\n000'
  rm -f "$cfg"
  API_CODE=${out##*$'\n'}; API_BODY=${out%$'\n'*}
  [[ $API_CODE == 2* ]]
}
es_api()  { _http "$1" "https://localhost:9200$2" "$ES_HOME/config/certs/ca.crt" "${3-}"; }
es_remote_api() {   # tries the given ES IPs (default: hot nodes) in turn
  local ip; local -a targets=("${ES_TARGETS[@]}")
  for ip in "${targets[@]}"; do
    _http "$1" "https://${ip}:9200$2" "$CLUSTER_CA" "${3-}" && return 0
    [[ $API_CODE != 000 ]] && return 1
  done
  return 1
}
kbn_api() { _http "$1" "https://${IP}:5601$2" "$KB_CA" "${3-}" 'kbn-xsrf: true' 'Elastic-Api-Version: 2023-10-31'; }
json_str() {   # json_str <value>  -> JSON string literal (escapes \ and ")
  local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"
}

# =============================================================================
#  Artifact source: repo server (air-gapped) | internet | local files
# =============================================================================
repo_https_url() { echo "https://${REPO_ADDR}:${REPO_HTTPS_PORT}"; }
repo_http_url()  { echo "http://${REPO_ADDR}:${REPO_HTTP_PORT}"; }
epr_url()        { echo "https://${REPO_ADDR}:${EPR_PORT}"; }
REPO_CA=""      # path to the repository server CA (repo mode)

fetch_url() {   # fetch_url <url> <dest> [quiet]
  local -a caopt=()
  [[ $ART_MODE == repo && -n $REPO_CA ]] && caopt=(--cacert "$REPO_CA")
  if [[ ${3-} == quiet ]]; then curl -fsSL --retry 3 ${caopt[@]+"${caopt[@]}"} -o "$2" "$1"
  else curl -fL --retry 3 --progress-bar ${caopt[@]+"${caopt[@]}"} -o "$2" "$1"; fi
}
prompt_artifact_source() {   # sets ART_MODE, REPO_ADDR, REPO_CA
  step "Where do the Elastic packages come from?"
  ask_choice ART_MODE "Package source" "repo" repo internet local
  case $ART_MODE in
    repo)
      info "Air-gapped repository server (installed with --role repo)."
      ask REPO_ADDR "Repository server address (IP or DNS name every VM can reach)" "" valid_addr
      info "Repository CA fingerprint (printed at the end of the repo run):"
      local fp; ask fp "SHA-256 fingerprint" "" valid_fp; fp=$(norm_fp "$fp")
      REPO_CA="$WORKDIR/repo-ca.crt"
      fetch_ca_by_fp "$REPO_ADDR" "$REPO_HTTPS_PORT" "$fp" "$REPO_CA" \
        || die "The repository server at ${REPO_ADDR}:${REPO_HTTPS_PORT} did not present a certificate with that fingerprint."
      curl -fsS --max-time 15 --cacert "$REPO_CA" -o /dev/null "$(repo_https_url)/downloads/" \
        || die "Repository server reachable but /downloads/ is not served – check the repo run."
      ok "Repository server verified (CA ${fp:0:16}…)" ;;
    internet) REPO_ADDR=""; info "Packages are downloaded from ${UPSTREAM_ARTIFACTS}." ;;
    local)    REPO_ADDR=""; info "Place the .tar.gz (+ .sha512) files in ${ARTIFACT_DIR} on every VM." ;;
  esac
}
artifact_rel() {   # artifact_rel <es|kibana|agent|hdfs>  -> path below the site root
  case $1 in
    es)     echo "downloads/elasticsearch/elasticsearch-${STACK_VERSION}-linux-${ES_ARCH}.tar.gz" ;;
    kibana) echo "downloads/kibana/kibana-${STACK_VERSION}-linux-${ES_ARCH}.tar.gz" ;;
    agent)  echo "downloads/beats/elastic-agent/elastic-agent-${STACK_VERSION}-linux-${AGENT_ARCH}.tar.gz" ;;
    hdfs)   echo "downloads/elasticsearch-plugins/repository-hdfs/repository-hdfs-${STACK_VERSION}.zip" ;;
  esac
}
artifact_site() {
  case $ART_MODE in
    repo) repo_https_url ;;
    internet) echo "$UPSTREAM_ARTIFACTS" ;;
    *) echo "" ;;
  esac
}
verify_sha512() { ( cd "$(dirname "$1")" && sha512sum -c "$(basename "$1").sha512" >/dev/null 2>&1 ); }
verify_gpg() {   # best effort: verifies the .asc signature when gpg + key are available
  local f=$1 site gh
  command -v gpg >/dev/null || { info "gpg not installed – signature check skipped (SHA-512 verified)."; return 0; }
  site=$(artifact_site); [[ -n $site ]] || return 0
  fetch_url "${site}/$(dirname "$2")/$(basename "$f").asc" "$f.asc" quiet 2>/dev/null \
    || { info "No .asc signature published – SHA-512 verified only."; return 0; }
  gh="$WORKDIR/gnupg"; mkdir -p "$gh"; chmod 700 "$gh"
  if ! fetch_url "${site%/downloads}/GPG-KEY-elasticsearch" "$WORKDIR/gpg.key" quiet 2>/dev/null \
     && ! fetch_url "${site}/GPG-KEY-elasticsearch" "$WORKDIR/gpg.key" quiet 2>/dev/null; then
    warn "GPG key not available – signature check skipped."; return 0
  fi
  GNUPGHOME="$gh" gpg --batch --quiet --import "$WORKDIR/gpg.key" 2>/dev/null
  GNUPGHOME="$gh" gpg --batch --quiet --verify "$f.asc" "$f" 2>/dev/null \
    || die "GPG signature verification FAILED for $(basename "$f")"
  ok "GPG signature verified"
}
get_artifact() {   # get_artifact <comp>  -> ARTIFACT_PATH
  local comp=$1 rel f site
  rel=$(artifact_rel "$comp"); f=$(basename "$rel"); site=$(artifact_site)
  step "Obtaining $f"
  ARTIFACT_PATH="$ARTIFACT_DIR/$f"
  if [[ -f $ARTIFACT_PATH && -f $ARTIFACT_PATH.sha512 ]] && verify_sha512 "$ARTIFACT_PATH"; then
    ok "Using local copy (checksum OK)"; return 0
  fi
  if [[ $ART_MODE == local ]]; then
    [[ -f $ARTIFACT_PATH ]] || die "$f not found in $ARTIFACT_DIR (local mode)."
    [[ -f $ARTIFACT_PATH.sha512 ]] || { warn "No $f.sha512 – using the file unverified."; return 0; }
    verify_sha512 "$ARTIFACT_PATH" || die "SHA-512 verification FAILED for $f"
    ok "Local file verified"; return 0
  fi
  info "Downloading ${site}/${rel}"
  fetch_url "${site}/${rel}" "$ARTIFACT_PATH" || die "Download failed: ${site}/${rel}"
  fetch_url "${site}/${rel}.sha512" "$ARTIFACT_PATH.sha512" quiet || die "Checksum download failed."
  verify_sha512 "$ARTIFACT_PATH" || die "SHA-512 verification FAILED for $f"
  ok "Downloaded, SHA-512 verified"
  verify_gpg "$ARTIFACT_PATH" "$rel"
}
tar_top() { local t; t=$(set +o pipefail; tar -tzf "$1" | head -n1); t=${t#./}; echo "${t%%/*}"; }
nologin_shell() { command -v nologin 2>/dev/null || echo /sbin/nologin; }

# =============================================================================
#  OS preparation
# =============================================================================
pm_install() {   # returns non-zero instead of aborting (air-gapped OS mirrors vary)
  case $OS_FAMILY in
    debian) export DEBIAN_FRONTEND=noninteractive
            { apt-get update -qq && apt-get install -y -qq "$@"; } >/dev/null 2>&1 ;;
    rhel)   if command -v dnf >/dev/null; then dnf install -y -q "$@" >/dev/null 2>&1
            else yum install -y -q "$@" >/dev/null 2>&1; fi ;;
    suse)   zypper --non-interactive --quiet install --no-recommends "$@" >/dev/null 2>&1 ;;
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
hosts_block() {   # writes a managed /etc/hosts block for every planned VM
  local -a lines=("$@")
  ((${#lines[@]})) || return 0
  cp -a /etc/hosts "/etc/hosts.bak.elastic.$(date +%s)"
  sed -i '/^# BEGIN elastic-node-setup/,/^# END elastic-node-setup/d' /etc/hosts
  { echo "# BEGIN elastic-node-setup"; printf '%s\n' "${lines[@]}"; echo "# END elastic-node-setup"; } >> /etc/hosts
}
plan_hosts_lines() {   # prints "ip name" for all planned VMs
  local i
  for i in "${!MASTER_NAMES[@]}"; do echo "${MASTER_IPS[$i]}  ${MASTER_NAMES[$i]}"; done
  for i in "${!HOT_NAMES[@]}";    do echo "${HOT_IPS[$i]}  ${HOT_NAMES[$i]}"; done
  for i in "${!WARM_NAMES[@]}";   do echo "${WARM_IPS[$i]}  ${WARM_NAMES[$i]}"; done
  for i in "${!FROZEN_NAMES[@]}"; do echo "${FROZEN_IPS[$i]}  ${FROZEN_NAMES[$i]}"; done
  [[ -n ${KIBANA_IP-} ]] && echo "${KIBANA_IP}  ${KIBANA_NAME}"
  [[ -n ${FLEET_IP-} ]] && echo "${FLEET_IP}  ${FLEET_NAME}"
  if [[ -n ${REPO_ADDR-} ]] && valid_ipv4 "${REPO_ADDR}" && [[ -n ${REPO_NAME-} ]]; then echo "${REPO_ADDR}  ${REPO_NAME}"; fi
  return 0
}
es_all_ips() { echo "${MASTER_IPS[*]} ${HOT_IPS[*]} ${WARM_IPS[*]-} ${FROZEN_IPS[*]-}"; }
prepare_os() {   # prepare_os <es|kibana|fleet|repo|agent>
  local role=$1 c need=() p
  step "Preparing the operating system ($OS_FAMILY, ${OS_PRETTY:-unknown})"
  for c in curl tar gzip openssl; do command -v "$c" >/dev/null || need+=("$c"); done
  if ((${#need[@]})); then
    info "Installing: ${need[*]}"
    pm_install "${need[@]}" || die "Could not install ${need[*]} – make the OS package repository (internal mirror) available."
  fi
  if ! systemctl is-active --quiet chronyd && ! systemctl is-active --quiet chrony \
     && ! systemctl is-active --quiet systemd-timesyncd && ! systemctl is-active --quiet ntpd; then
    info "Enabling time synchronisation (chrony)"
    if pm_install chrony; then
      systemctl enable --now chronyd >/dev/null 2>&1 || systemctl enable --now chrony >/dev/null 2>&1 \
        || warn "chrony installed but not started – point it at your internal NTP server."
    else warn "Could not install chrony – make sure NTP is configured (clocks must be in sync)."; fi
  fi
  if [[ $SET_HOSTNAME == yes ]]; then
    hostnamectl set-hostname "$HOST_NAME" 2>/dev/null || { echo "$HOST_NAME" > /etc/hostname; hostname "$HOST_NAME"; }
  fi
  if [[ $role == repo ]]; then
    hosts_block "$IP  $HOST_NAME"
  else
    local -a hl=(); mapfile -t hl < <(plan_hosts_lines)
    if ((${#hl[@]})); then hosts_block "${hl[@]}"; else hosts_block "$IP  $HOST_NAME"; fi
  fi
  if [[ $CONFIG_FW == yes ]]; then
    fw_detect
    if [[ $FW == none ]]; then info "No active firewalld/ufw – skipping firewall rules"
    else
      case $role in
        es)     fw_open 9200; for p in $(es_all_ips); do fw_open 9300 "$p"; done ;;
        kibana) fw_open 5601 ;;
        fleet)  fw_open "$FLEET_PORT" ;;
        repo)   fw_open "$REPO_HTTP_PORT"; fw_open "$REPO_HTTPS_PORT"; fw_open "$EPR_PORT" ;;
      esac
      [[ $FW == firewalld ]] && firewall-cmd -q --reload
      ok "Firewall ($FW) updated"
    fi
  fi
  if [[ $role == es ]]; then
    mkdir -p /etc/sysctl.d /etc/security/limits.d
    cat > /etc/sysctl.d/90-elasticsearch.conf <<'SYS'
# Managed by elastic-node-setup-v2.sh
vm.max_map_count = 1048576
vm.swappiness = 1
net.ipv4.tcp_retries2 = 5
SYS
    sysctl -q -p /etc/sysctl.d/90-elasticsearch.conf || warn "sysctl could not apply every setting."
    cat > /etc/security/limits.d/90-elasticsearch.conf <<'LIM'
elasticsearch  -  nofile   65535
elasticsearch  -  nproc    4096
elasticsearch  -  memlock  unlimited
LIM
    if [[ ${DISABLE_SWAP:-no} == yes ]]; then
      swapoff -a 2>/dev/null || true
      if grep -Eq '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
        cp -a /etc/fstab "/etc/fstab.bak.elastic.$(date +%s)"
        sed -ri 's@^([^#].*[[:space:]]swap[[:space:]].*)$@# \1  # disabled for Elasticsearch@' /etc/fstab
      fi
    fi
  fi
  ok "OS prepared"
}

# =============================================================================
#  Node packs (encrypted bundle of certificates + settings for one VM)
# =============================================================================
CLUSTER_VARS=(STACK_VERSION CLUSTER_NAME ELASTIC_PASSWORD ES_UID ES_GID CA_FP
  MASTER_NAMES MASTER_IPS HOT_NAMES HOT_IPS WARM_NAMES WARM_IPS FROZEN_NAMES FROZEN_IPS
  KIBANA_NAME KIBANA_IP FLEET_NAME FLEET_IP ART_MODE REPO_ADDR REPO_NAME ML_MODEL_REPO
  SNAP_TYPE SNAP_REPO_NAME SNAP_FS_PATH SNAP_FS_MODE SNAP_NFS_EXPORT SNAP_NFS_OPTS
  S3_BUCKET S3_BASE_PATH S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_PATH_STYLE
  AZ_ACCOUNT AZ_KEY AZ_SAS AZ_CONTAINER AZ_BASE_PATH AZ_ENDPOINT_SUFFIX
  GCS_BUCKET GCS_BASE_PATH GCS_ENDPOINT HDFS_URI HDFS_PATH)
NODE_STATE_VARS=(STACK_VERSION CLUSTER_NAME NODE_TYPE NODE_NAME NODE_IP CA_FP ART_MODE REPO_ADDR REPO_NAME
  MASTER_NAMES MASTER_IPS HOT_NAMES HOT_IPS WARM_NAMES WARM_IPS FROZEN_NAMES FROZEN_IPS
  KIBANA_NAME KIBANA_IP FLEET_NAME FLEET_IP)
write_env() {   # write_env <file> VAR...   (globals, sourceable from functions)
  local f=$1; shift
  ( umask 077; declare -p "$@" 2>/dev/null \
      | sed -E 's/^declare -- /declare -g /; s/^declare -([a-zA-Z]+) /declare -g\1 /' > "$f" )
}
load_env() { # shellcheck disable=SC1090
  source "$1"; }
pack_write() {   # pack_write <dir> <outfile>
  tar -C "$1" -czf - . | openssl enc -aes-256-cbc -salt -pbkdf2 -iter "$PBKDF2_ITER" -pass fd:3 -out "$2" 3<<<"$PACK_PASS"
  chmod 600 "$2"
}
pack_read() {   # pack_read <file>  -> PACK_DIR
  PACK_DIR="$WORKDIR/pack"; rm -rf "$PACK_DIR"; mkdir -p "$PACK_DIR"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -pass fd:3 -in "$1" 3<<<"$PACK_PASS" 2>/dev/null \
    | tar -C "$PACK_DIR" -xzf - 2>/dev/null || return 1
  [[ -f $PACK_DIR/cluster.env ]]
}
prompt_pack() {   # prompt_pack <expected types regex>  -> loads cluster.env + node vars
  local types=$1 f
  step "Node pack"
  if [[ -z ${CLI_PACK-} ]]; then
    local def=""; for f in "$SCRIPT_DIR"/*.pack; do [[ -f $f ]] && { def=$f; break; }; done
    ask CLI_PACK "Path to this VM's node pack (from master-1: $CLUSTER_DIR/packs/)" "$def" valid_file
  fi
  valid_file "$CLI_PACK" || die "Pack not found: $CLI_PACK"
  local tries=0
  while true; do
    ask_secret PACK_PASS "Pack passphrase (set during es-first)" no
    pack_read "$CLI_PACK" && break
    tries=$((tries + 1)); ((tries < 3)) || die "Could not open the pack (wrong passphrase or corrupted file)."
    warn "Wrong passphrase or corrupted pack – try again."
  done
  load_env "$PACK_DIR/cluster.env"
  [[ $NODE_TYPE =~ ^(${types})$ ]] || die "This pack is for a '${NODE_TYPE}' VM (${NODE_NAME}), not for this role."
  CLUSTER_CA="$PACK_DIR/ca.crt"
  if [[ -f $PACK_DIR/repo-ca.crt ]]; then REPO_CA="$PACK_DIR/repo-ca.crt"; fi
  ES_TARGETS=("${HOT_IPS[@]}")
  ok "Pack opened: ${NODE_NAME} (${NODE_TYPE}) – cluster '${CLUSTER_NAME}', Elastic ${STACK_VERSION}, packages: ${ART_MODE}${REPO_ADDR:+ (${REPO_ADDR})}"
}
save_node_state() {   # keeps non-secret settings + CAs for later roles (monitor)
  mkdir -p "$STATE_DIR"; chmod 755 "$STATE_DIR"
  write_env "$STATE_DIR/node.env" "${NODE_STATE_VARS[@]}"
  chmod 644 "$STATE_DIR/node.env"
  install -m 0644 "$CLUSTER_CA" "$STATE_DIR/ca.crt"
  if [[ -n $REPO_CA && -f $REPO_CA ]]; then install -m 0644 "$REPO_CA" "$STATE_DIR/repo-ca.crt"; fi
}
check_not_installed() {
  [[ ! -e $ES_HOME && ! -e $KB_HOME && ! -e /opt/Elastic/Agent && ! -e /etc/systemd/system/elasticsearch.service ]] \
    || die "An Elastic component is already installed on this VM – this script performs fresh installs only."
}

# =============================================================================
#  Role: bundle  (Internet-connected staging machine – builds the air-gap bundle)
# =============================================================================
detect_runtime() {   # sets RT (podman|docker) or empty
  local have=()
  command -v podman >/dev/null && have+=(podman)
  command -v docker >/dev/null && have+=(docker)
  case ${#have[@]} in
    0) RT="" ;;
    1) RT=${have[0]} ;;
    *) ask_choice RT "Container runtime" "podman" "${have[@]}" ;;
  esac
}
bundle_dl() {   # bundle_dl <relative path under site/> [optional]
  local rel=$1 dst="$B_SITE/$1" url="${UPSTREAM_ARTIFACTS}/$1"
  mkdir -p "$(dirname "$dst")"
  local -a q=(-fsSL); [[ ${2-} == optional ]] && q=(-fsL)
  if ! curl "${q[@]}" --retry 3 -o "$dst" "$url"; then
    rm -f "$dst"
    [[ ${2-} == optional ]] && { warn "Not available upstream (skipped): $rel"; return 0; }
    die "Download failed: $url"
  fi
  curl -fsSL --retry 3 -o "$dst.sha512" "$url.sha512" || die "Checksum download failed: $url.sha512"
  curl -fsSL --retry 3 -o "$dst.asc" "$url.asc" 2>/dev/null || rm -f "$dst.asc"
  verify_sha512 "$dst" || die "SHA-512 verification FAILED: $rel"
  ok "$(basename "$rel")"
}
role_bundle() {
  step "Air-gap bundle – run this on a staging machine WITH Internet access"
  prompt_version
  ask_choice B_ARCH "CPU architecture of your servers" "x86_64" x86_64 aarch64 both
  ask_yn B_AGENT_EXTRA "Include Elastic Agent packages for Windows/macOS/DEB/RPM hosts (agent installs and upgrades)?" y
  ask_yn B_ENDPOINT "Include Elastic Defend (Endpoint) protection artifacts?" y
  ask_yn B_ELSER "Include the ELSER v2 model (semantic search / AI Assistant)?" n
  ask_yn B_HDFS "Include the repository-hdfs plugin (only for an HDFS snapshot repository)?" n
  detect_runtime
  [[ -n $RT ]] || die "podman or docker is required here to download the Elastic Package Registry image."
  ask B_OUT "Output directory" "$PWD/elastic-airgap-bundle-${STACK_VERSION}" valid_abs
  [[ ! -e $B_OUT ]] || die "$B_OUT already exists – choose another directory or remove it."
  confirm_or_abort; start_logging
  command -v unzip >/dev/null || [[ $B_ENDPOINT == no ]] || die "unzip is required for the Endpoint artifacts."

  B_SITE="$B_OUT/site"; mkdir -p "$B_SITE/downloads" "$B_OUT/images"
  local -a archs=() agent_archs=(); local a
  case $B_ARCH in x86_64) archs=(x86_64) ;; aarch64) archs=(aarch64) ;; both) archs=(x86_64 aarch64) ;; esac
  for a in "${archs[@]}"; do [[ $a == x86_64 ]] && agent_archs+=(x86_64) || agent_archs+=(arm64); done
  [[ $B_AGENT_EXTRA == yes ]] && agent_archs=(x86_64 arm64)

  step "Elasticsearch, Kibana and Elastic Agent ${STACK_VERSION}"
  for a in "${archs[@]}"; do
    bundle_dl "downloads/elasticsearch/elasticsearch-${STACK_VERSION}-linux-${a}.tar.gz"
    bundle_dl "downloads/kibana/kibana-${STACK_VERSION}-linux-${a}.tar.gz"
  done
  for a in "${agent_archs[@]}"; do
    bundle_dl "downloads/beats/elastic-agent/elastic-agent-${STACK_VERSION}-linux-${a}.tar.gz"
  done
  if [[ $B_AGENT_EXTRA == yes ]]; then
    step "Elastic Agent packages for other platforms"
    local f
    for f in windows-x86_64.zip darwin-x86_64.tar.gz darwin-aarch64.tar.gz amd64.deb arm64.deb x86_64.rpm aarch64.rpm; do
      bundle_dl "downloads/beats/elastic-agent/elastic-agent-${STACK_VERSION}-${f}" optional
    done
  fi
  if [[ $B_HDFS == yes ]]; then
    step "repository-hdfs plugin"
    bundle_dl "downloads/elasticsearch-plugins/repository-hdfs/repository-hdfs-${STACK_VERSION}.zip"
  fi
  step "Elastic GPG keys"
  curl -fsSL --retry 3 -o "$B_SITE/GPG-KEY-elasticsearch" "${UPSTREAM_ARTIFACTS}/GPG-KEY-elasticsearch" || die "GPG key download failed."
  curl -fsSL --retry 3 -o "$B_SITE/GPG-KEY-elastic-agent" "${UPSTREAM_ARTIFACTS}/GPG-KEY-elastic-agent" \
    || warn "GPG-KEY-elastic-agent not available (agents fall back to their bundled key)."
  ok "Keys saved"

  if [[ $B_ENDPOINT == yes ]]; then
    step "Elastic Defend (Endpoint) artifacts ${STACK_VERSION}"
    local mdir="$B_SITE/downloads/endpoint/manifest" zip list rel n=0
    mkdir -p "$mdir"; zip="$mdir/artifacts-${STACK_VERSION}.zip"
    curl -fsSL --retry 3 -o "$zip" "${UPSTREAM_ENDPOINT}/downloads/endpoint/manifest/artifacts-${STACK_VERSION}.zip" \
      || die "Endpoint manifest download failed."
    list=$(unzip -p "$zip" manifest.json | jgrep '"relative_url"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\(\/[^"]*\)"$/\1/')
    while IFS= read -r rel; do
      [[ -n $rel ]] || continue
      mkdir -p "$B_SITE$(dirname "$rel")"
      curl -fsSL --retry 3 -o "$B_SITE$rel" "${UPSTREAM_ENDPOINT}${rel}" || die "Endpoint artifact download failed: $rel"
      n=$((n + 1))
    done <<<"$list"
    ok "Manifest + ${n} artifacts"
  fi
  if [[ $B_ELSER == yes ]]; then
    step "ELSER v2 model"
    mkdir -p "$B_SITE/ml-models"
    for f in elser_model_2.metadata.json elser_model_2.pt elser_model_2.vocab.json \
             elser_model_2_linux-x86_64.metadata.json elser_model_2_linux-x86_64.pt elser_model_2_linux-x86_64.vocab.json; do
      curl -fsSL --retry 3 -o "$B_SITE/ml-models/$f" "${UPSTREAM_ML}/$f" || die "Model download failed: $f"
      ok "$f"
    done
  fi

  step "Container images ($RT)"
  local epr_ref="${EPR_IMAGE}:${STACK_VERSION}"
  "$RT" pull "$epr_ref" >/dev/null || die "Could not pull $epr_ref"
  "$RT" save -o "$B_OUT/images/package-registry-${STACK_VERSION}.tar" "$epr_ref" || die "Could not save $epr_ref"
  ok "Elastic Package Registry: $epr_ref"
  "$RT" pull "$NGINX_IMAGE" >/dev/null || die "Could not pull $NGINX_IMAGE"
  "$RT" save -o "$B_OUT/images/nginx.tar" "$NGINX_IMAGE" || die "Could not save $NGINX_IMAGE"
  ok "Web server: $NGINX_IMAGE"
  printf 'epr %s package-registry-%s.tar\nnginx %s nginx.tar\n' "$epr_ref" "$STACK_VERSION" "$NGINX_IMAGE" > "$B_OUT/images/IMAGES.txt"

  step "Checksums and archive"
  {
    echo "Elastic air-gap bundle – Elastic Stack ${STACK_VERSION} – created $(date -u +%FT%TZ) by ${SCRIPT_NAME} ${SCRIPT_VERSION}"
    echo "Architectures: ${archs[*]} | agent packages: ${agent_archs[*]}$([[ $B_AGENT_EXTRA == yes ]] && echo ' + windows/macOS/deb/rpm')"
    echo "Endpoint artifacts: ${B_ENDPOINT} | ELSER: ${B_ELSER} | repository-hdfs: ${B_HDFS}"
  } > "$B_OUT/MANIFEST.txt"
  ( cd "$B_OUT" && find site images MANIFEST.txt -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
  tar -C "$(dirname "$B_OUT")" -cf "${B_OUT}.tar" "$(basename "$B_OUT")"
  step "Done"
  info "Bundle directory: $B_OUT"
  info "Bundle archive  : ${B_OUT}.tar  ($(du -h "${B_OUT}.tar" | cut -f1))"
  info "Copy the .tar to the repository server (USB/approved transfer) and run there:"
  info "  sudo ./${SCRIPT_NAME} --role repo"
  info "Log: $LOG_FILE"
}

# =============================================================================
#  Role: repo  (air-gapped repository server: artifact registry + EPR)
# =============================================================================
valid_bundle() { [[ -f $1 || -d $1 ]] || { echo "    Not found: $1" >&2; return 1; }; }
repo_unit() {   # repo_unit <unit> <description> <exec-start...>
  local unit=$1 desc=$2; shift 2
  local rtbin; rtbin=$(command -v "$RT")
  local dep=""; [[ $RT == docker ]] && dep=$'Requires=docker.service\nAfter=docker.service'
  cat > "/etc/systemd/system/${unit}.service" <<UNIT
[Unit]
Description=${desc}
Wants=network-online.target
After=network-online.target
${dep}

[Service]
Restart=always
RestartSec=10
TimeoutStartSec=300
ExecStartPre=-${rtbin} rm -f ${unit}
ExecStart=${rtbin} $*
ExecStop=${rtbin} stop -t 10 ${unit}

[Install]
WantedBy=multi-user.target
UNIT
}
role_repo() {
  prompt_this_host
  step "Repository server settings"
  local def=""; local f
  for f in "$SCRIPT_DIR"/elastic-airgap-bundle-*.tar "$PWD"/elastic-airgap-bundle-*.tar; do [[ -f $f ]] && { def=$f; break; }; done
  ask B_SRC "Air-gap bundle (.tar file or extracted directory)" "$def" valid_bundle
  ask REPO_BASE "Install directory" "$REPO_BASE_DEFAULT" valid_abs
  detect_runtime
  [[ -n $RT ]] || die "podman (RHEL/SUSE) or docker is required on the repository server – install it from your internal OS mirror."
  ask_choice REPO_TLS "TLS certificate for the repository server" "local" local own
  if [[ $REPO_TLS == own ]]; then
    ask OWN_CERT "Certificate (PEM, SAN must include ${HOST_NAME} and ${IP})" "" valid_file
    ask OWN_KEY  "Private key (PEM, unencrypted)" "" valid_file
    ask OWN_CA   "CA certificate that signed it" "" valid_file
  fi
  confirm_or_abort; start_logging
  prepare_os repo

  step "Unpacking and verifying the bundle"
  local src="$B_SRC" inc="$REPO_BASE/incoming"
  mkdir -p "$REPO_BASE"; chmod 755 "$REPO_BASE"
  if [[ -f $src ]]; then
    rm -rf "$inc"; mkdir -p "$inc"
    tar -C "$inc" -xf "$src" || die "Cannot extract $src"
    src=$(dirname "$(find "$inc" -maxdepth 2 -name SHA256SUMS | head -n1)")
  fi
  [[ -f $src/SHA256SUMS ]] || die "SHA256SUMS not found in the bundle."
  ( cd "$src" && sha256sum -c --quiet SHA256SUMS ) || die "Bundle checksum verification FAILED."
  ok "Bundle verified: $(head -n1 "$src/MANIFEST.txt" 2>/dev/null)"
  mkdir -p "$REPO_BASE/www"
  cp -a "$src/site/." "$REPO_BASE/www/"
  chmod -R a+rX "$REPO_BASE/www"
  ok "Artifacts published under $REPO_BASE/www"

  step "TLS certificate"
  local cd="$REPO_BASE/certs" sd="$REPO_BASE/certs/serve"
  mkdir -p "$sd"; chmod 700 "$cd"
  if [[ $REPO_TLS == own ]]; then
    install -m 0644 "$OWN_CA" "$cd/ca.crt"
    { cat "$OWN_CERT"; echo; cat "$OWN_CA"; } | sed '/^$/d' > "$sd/repo-chain.crt"
    install -m 0644 "$OWN_KEY" "$sd/repo.key"
  else
    ca_create "$cd" "Elastic repository CA (${HOST_SHORT})"
    local -a dns=("$HOST_NAME" localhost); [[ $HOST_SHORT != "$HOST_NAME" ]] && dns=("$HOST_SHORT" "${dns[@]}")
    cert_issue "$cd" "$cd" repo "${dns[@]}" -- "$IP" 127.0.0.1
    { cat "$cd/repo.crt"; echo; cat "$cd/ca.crt"; } | sed '/^$/d' > "$sd/repo-chain.crt"
    install -m 0644 "$cd/repo.key" "$sd/repo.key"   # read by the (possibly non-root) container user
  fi
  chmod 711 "$cd"; chmod 755 "$sd"; chmod 644 "$sd/repo-chain.crt"
  ok "Certificate ready (served with its CA chain)"

  step "Loading container images ($RT)"
  [[ -f $src/images/IMAGES.txt ]] || die "images/IMAGES.txt missing from the bundle."
  local kind ref file epr_ref="" nginx_ref=""
  while read -r kind ref file; do
    [[ -n $kind ]] || continue
    "$RT" load -i "$src/images/$file" >/dev/null || die "Could not load $file"
    case $kind in epr) epr_ref=$ref ;; nginx) nginx_ref=$ref ;; esac
    ok "$ref"
  done < "$src/images/IMAGES.txt"
  [[ -n $epr_ref && -n $nginx_ref ]] || die "The bundle must contain both the package-registry and nginx images."

  step "Web server (artifact registry) and Elastic Package Registry"
  mkdir -p "$REPO_BASE/nginx"
  cat > "$REPO_BASE/nginx/default.conf" <<NGX
# Managed by ${SCRIPT_NAME} – Elastic artifact registry
# Plain HTTP for Elastic Agents (Elastic: agents cannot be given a custom CA
# for binary downloads), verified HTTPS for the installer script.
server {
    listen ${REPO_HTTP_PORT};
    server_name _;
    root /usr/share/nginx/html;
    autoindex on;
    location / { try_files \$uri \$uri/ =404; }
}
server {
    listen ${REPO_HTTPS_PORT} ssl;
    server_name _;
    ssl_certificate     /etc/nginx/certs/repo-chain.crt;
    ssl_certificate_key /etc/nginx/certs/repo.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /usr/share/nginx/html;
    autoindex on;
    location / { try_files \$uri \$uri/ =404; }
}
NGX
  repo_unit elastic-repo-nginx "Elastic artifact registry (nginx)" \
    run --rm --name elastic-repo-nginx --network host \
    -v "$REPO_BASE/www:/usr/share/nginx/html:ro,z" \
    -v "$REPO_BASE/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro,z" \
    -v "$sd:/etc/nginx/certs:ro,z" "$nginx_ref"
  repo_unit elastic-epr "Elastic Package Registry" \
    run --rm --name elastic-epr --network host \
    -e "EPR_ADDRESS=0.0.0.0:${EPR_PORT}" -e EPR_TLS_CERT=/etc/ssl/epr.crt -e EPR_TLS_KEY=/etc/ssl/epr.key \
    -v "$sd/repo-chain.crt:/etc/ssl/epr.crt:ro,z" -v "$sd/repo.key:/etc/ssl/epr.key:ro,z" "$epr_ref"
  systemctl daemon-reload
  systemctl enable --now elastic-repo-nginx.service >/dev/null 2>&1 || die "Could not start elastic-repo-nginx."
  systemctl enable --now elastic-epr.service >/dev/null 2>&1 || die "Could not start elastic-epr."

  step "Health checks"
  local t=0 ca="$cd/ca.crt"
  until curl -fsS --max-time 5 -o /dev/null "http://${IP}:${REPO_HTTP_PORT}/downloads/"; do
    t=$((t + 5)); ((t < 120)) || die "Artifact registry (HTTP ${REPO_HTTP_PORT}) did not come up – journalctl -u elastic-repo-nginx"; sleep 5
  done
  ok "Artifact registry  http://${IP}:${REPO_HTTP_PORT}/downloads/"
  curl -fsS --max-time 5 --cacert "$ca" -o /dev/null "https://${IP}:${REPO_HTTPS_PORT}/downloads/" \
    || die "HTTPS ${REPO_HTTPS_PORT} failed certificate verification."
  ok "Artifact registry  https://${IP}:${REPO_HTTPS_PORT}/downloads/ (TLS verified)"
  t=0
  until curl -fsS --max-time 5 --cacert "$ca" -o /dev/null "https://${IP}:${EPR_PORT}/health?ready=true"; do
    t=$((t + 5)); ((t < 300)) || die "Package registry did not become ready – journalctl -u elastic-epr"; sleep 5
  done
  ok "Package registry   https://${IP}:${EPR_PORT}"

  local fp vers
  fp=$(cert_fp "$ca")
  vers=$(find "$REPO_BASE/www/downloads/elasticsearch" -name 'elasticsearch-*.tar.gz' -printf '%f\n' 2>/dev/null | sed -E 's/elasticsearch-([0-9.]+)-linux-(.*)\.tar\.gz/\1 (\2)/' | sort -u | paste -sd, -)
  local S=/root/elastic-repo-summary.txt
  {
    echo "Elastic repository server ${HOST_NAME} (${IP}) – ${SCRIPT_NAME} ${SCRIPT_VERSION}"
    echo
    echo "Repository CA fingerprint (enter it in es-first):"
    echo "  ${fp}"
    echo
    echo "Artifact registry (agents)    : http://${IP}:${REPO_HTTP_PORT}/downloads/"
    echo "Artifact registry (installer) : https://${IP}:${REPO_HTTPS_PORT}/downloads/"
    echo "Elastic Package Registry      : https://${IP}:${EPR_PORT}"
    echo "Endpoint artifacts            : http://${IP}:${REPO_HTTP_PORT}  (Defend: *.advanced.artifacts.global.base_url)"
    [[ -d $REPO_BASE/www/ml-models ]] && echo "ML models (ELSER)             : http://${IP}:${REPO_HTTP_PORT}/ml-models"
    echo "Elasticsearch versions        : ${vers:-none}"
    echo "Services                      : systemctl status elastic-repo-nginx elastic-epr"
    echo
    echo "Next: on master-1 run  sudo ./${SCRIPT_NAME} --role es-first  and choose package source 'repo'."
  } > "$S"; chmod 600 "$S"
  step "Done"; sed 's/^/    /' "$S"; info ""; info "Saved to $S  |  log: $LOG_FILE"
}

# =============================================================================
#  Cluster plan (all VMs, decided once on master-1)
# =============================================================================
MASTER_NAMES=(); MASTER_IPS=(); HOT_NAMES=(); HOT_IPS=(); WARM_NAMES=(); WARM_IPS=()
FROZEN_NAMES=(); FROZEN_IPS=(); KIBANA_NAME=""; KIBANA_IP=""; FLEET_NAME=""; FLEET_IP=""
plan_add() {   # plan_add <type> <name> <ip>
  case $1 in
    master) MASTER_NAMES+=("$2"); MASTER_IPS+=("$3") ;;
    hot)    HOT_NAMES+=("$2");    HOT_IPS+=("$3") ;;
    warm)   WARM_NAMES+=("$2");   WARM_IPS+=("$3") ;;
    frozen) FROZEN_NAMES+=("$2"); FROZEN_IPS+=("$3") ;;
    kibana) KIBANA_NAME=$2; KIBANA_IP=$3 ;;
    fleet)  FLEET_NAME=$2;  FLEET_IP=$3 ;;
    *) die "Unknown node type in plan: $1" ;;
  esac
}
plan_nodes() {   # prints "type name ip" for every planned VM
  local i
  for i in "${!MASTER_NAMES[@]}"; do echo "master ${MASTER_NAMES[$i]} ${MASTER_IPS[$i]}"; done
  for i in "${!HOT_NAMES[@]}";    do echo "hot ${HOT_NAMES[$i]} ${HOT_IPS[$i]}"; done
  for i in "${!WARM_NAMES[@]}";   do echo "warm ${WARM_NAMES[$i]} ${WARM_IPS[$i]}"; done
  for i in "${!FROZEN_NAMES[@]}"; do echo "frozen ${FROZEN_NAMES[$i]} ${FROZEN_IPS[$i]}"; done
  [[ -n $KIBANA_NAME ]] && echo "kibana ${KIBANA_NAME} ${KIBANA_IP}"
  [[ -n $FLEET_NAME ]] && echo "fleet ${FLEET_NAME} ${FLEET_IP}"
  return 0
}
plan_load_file() {
  local t n i ln=0
  while read -r t n i _; do
    ln=$((ln + 1))
    [[ -z ${t-} || $t == \#* ]] && continue
    valid_hostname "$n" || die "Plan line $ln: invalid name '$n'"
    valid_ipv4 "$i" || die "Plan line $ln: invalid IP '$i'"
    plan_add "${t,,}" "$n" "$i"
  done < "$1"
}
valid_master_count() { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 3 && $1 % 2 == 1)) || { echo "    Use an odd number >= 3 (3 is recommended)." >&2; return 1; }; }
valid_pos() { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1)); }
plan_interactive() {
  local nm nh nw nf i n a def_ip
  def_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  info "Node counts (requirement: 3 masters, 3 hot, 2 warm, 1 frozen)."
  ask nm "Dedicated master nodes" 3 valid_master_count
  ask nh "Hot nodes"    3 valid_pos
  ask nw "Warm nodes"   2 valid_int
  ask nf "Frozen nodes" 1 valid_int
  info "Name and IP of every VM (master-1 = THIS VM):"
  for ((i = 1; i <= nm; i++)); do
    ask n "master-$i name" "$([[ $i == 1 ]] && (hostname -s 2>/dev/null || echo es-master-1) || echo "es-master-$i")" valid_hostname
    ask a "master-$i IP" "$([[ $i == 1 ]] && echo "$def_ip")" valid_ipv4; plan_add master "$n" "$a"
  done
  for ((i = 1; i <= nh; i++)); do ask n "hot-$i name" "es-hot-$i" valid_hostname; ask a "hot-$i IP" "" valid_ipv4; plan_add hot "$n" "$a"; done
  for ((i = 1; i <= nw; i++)); do ask n "warm-$i name" "es-warm-$i" valid_hostname; ask a "warm-$i IP" "" valid_ipv4; plan_add warm "$n" "$a"; done
  for ((i = 1; i <= nf; i++)); do ask n "frozen-$i name" "es-frozen-$i" valid_hostname; ask a "frozen-$i IP" "" valid_ipv4; plan_add frozen "$n" "$a"; done
  ask n "Kibana VM name" "kibana" valid_hostname;       ask a "Kibana VM IP" "" valid_ipv4; plan_add kibana "$n" "$a"
  ask n "Fleet Server VM name" "fleet-server" valid_hostname; ask a "Fleet Server VM IP" "" valid_ipv4; plan_add fleet "$n" "$a"
}
plan_validate() {
  ((${#MASTER_NAMES[@]} >= 3 && ${#MASTER_NAMES[@]} % 2 == 1)) || die "The plan needs an odd number (>= 3) of master nodes."
  ((${#HOT_NAMES[@]} >= 1)) || die "The plan needs at least one hot node (it also holds the content tier)."
  [[ -n $KIBANA_NAME && -n $FLEET_NAME ]] || die "The plan needs one kibana and one fleet VM."
  local dup
  dup=$(plan_nodes | awk '{print $2}' | sort | uniq -d | head -n1); [[ -z $dup ]] || die "Duplicate name in plan: $dup"
  dup=$(plan_nodes | awk '{print $3}' | sort | uniq -d | head -n1); [[ -z $dup ]] || die "Duplicate IP in plan: $dup"
}
plan_print() {
  printf '      %-7s %-24s %s\n' TYPE NAME IP
  plan_nodes | while read -r t n i; do printf '      %-7s %-24s %s\n' "$t" "$n" "$i"; done
}

# =============================================================================
#  Snapshot repository (needed by the frozen tier; also used for backups)
# =============================================================================
valid_nfs() { [[ $1 =~ ^[A-Za-z0-9._-]+:/[^[:space:]]*$ ]]; }
prompt_snapshot_repo() {
  SNAP_TYPE=""; SNAP_REPO_NAME=""; SNAP_FS_PATH=""; SNAP_FS_MODE=""; SNAP_NFS_EXPORT=""; SNAP_NFS_OPTS=""
  S3_BUCKET=""; S3_BASE_PATH=""; S3_ENDPOINT=""; S3_ACCESS_KEY=""; S3_SECRET_KEY=""; S3_PATH_STYLE=""; S3_CA_FILE=""
  AZ_ACCOUNT=""; AZ_KEY=""; AZ_SAS=""; AZ_CONTAINER=""; AZ_BASE_PATH=""; AZ_ENDPOINT_SUFFIX=""
  GCS_BUCKET=""; GCS_BASE_PATH=""; GCS_ENDPOINT=""; GCS_CRED_FILE=""; HDFS_URI=""; HDFS_PATH=""
  step "Snapshot repository (frozen tier / searchable snapshots and backups)"
  local want=yes
  if ((${#FROZEN_NAMES[@]} == 0)); then ask_yn want "Configure a snapshot repository for backups?" y; fi
  [[ $want == yes ]] || { info "No snapshot repository."; return 0; }
  info "Supported (writable) repository types for self-managed clusters:"
  info "  fs    shared file system mounted on every master+data node (NFS, SMB, …)"
  info "  s3    AWS S3 or S3-compatible storage (MinIO, Ceph RGW, NetApp StorageGRID, …)"
  info "  azure Azure Blob Storage (incl. Azure Stack / sovereign clouds)"
  info "  gcs   Google Cloud Storage"
  info "  hdfs  Hadoop HDFS (official repository-hdfs plugin, simple auth)"
  info "  (read-only URL and source-only repositories cannot hold searchable snapshots)"
  ask_choice SNAP_TYPE "Repository type" "fs" fs s3 azure gcs hdfs
  ask SNAP_REPO_NAME "Repository name in Elasticsearch" "elastic-snapshots" valid_name
  case $SNAP_TYPE in
    fs)
      ask SNAP_FS_PATH "Mount point on every Elasticsearch node (path.repo)" "/mnt/es-snapshots" valid_abs
      info "  nfs      = this script mounts the NFS export on every ES node (and adds it to /etc/fstab)"
      info "  existing = you mount the share yourself on every ES node before running es-node"
      ask_choice SNAP_FS_MODE "How is the share mounted?" "nfs" nfs existing
      if [[ $SNAP_FS_MODE == nfs ]]; then
        ask SNAP_NFS_EXPORT "NFS export (server:/path)" "" valid_nfs
        ask SNAP_NFS_OPTS "NFS mount options" "rw,hard,_netdev,nofail" ;
      fi ;;
    s3)
      ask S3_BUCKET "Bucket" "" valid_name
      ask_optional S3_BASE_PATH "Base path inside the bucket (blank = bucket root)"
      ask_optional S3_ENDPOINT "Endpoint for S3-compatible storage, e.g. https://minio.corp:9000 (blank = AWS)" valid_url
      [[ -n $S3_ENDPOINT ]] && ask_yn S3_PATH_STYLE "Use path-style access (MinIO/most on-prem storage)?" y
      ask S3_ACCESS_KEY "Access key" "" ; ask_secret S3_SECRET_KEY "Secret key" yes
      [[ $S3_ENDPOINT == https://* ]] && ask_optional S3_CA_FILE "CA certificate of the S3 endpoint (blank = publicly trusted)" valid_file ;;
    azure)
      ask AZ_ACCOUNT "Storage account name" "" valid_name
      local auth; ask_choice auth "Authentication" "key" key sas
      if [[ $auth == key ]]; then ask_secret AZ_KEY "Account key" no; else ask_secret AZ_SAS "SAS token" no; fi
      ask AZ_CONTAINER "Container" "" valid_name
      ask_optional AZ_BASE_PATH "Base path (blank = container root)"
      ask_optional AZ_ENDPOINT_SUFFIX "Endpoint suffix (blank = core.windows.net)" ;;
    gcs)
      ask GCS_BUCKET "Bucket" "" valid_name
      ask_optional GCS_BASE_PATH "Base path (blank = bucket root)"
      ask GCS_CRED_FILE "Service-account JSON key file" "" valid_file
      ask_optional GCS_ENDPOINT "Custom endpoint (blank = Google)" valid_url ;;
    hdfs)
      ask HDFS_URI "HDFS NameNode URI" "hdfs://namenode:8020" valid_url_hdfs
      ask HDFS_PATH "Path inside HDFS" "/elasticsearch/snapshots" valid_abs ;;
  esac
}
valid_url_hdfs() { [[ $1 =~ ^hdfs://[^[:space:]]+$ ]]; }
snapshot_repo_body() {   # JSON body for PUT _snapshot/<name>
  local s
  case $SNAP_TYPE in
    fs)    s="{\"location\":$(json_str "${SNAP_FS_PATH}/${CLUSTER_NAME}"),\"compress\":true}" ;;
    s3)    s="{\"bucket\":$(json_str "$S3_BUCKET"),\"client\":\"default\"${S3_BASE_PATH:+,\"base_path\":$(json_str "$S3_BASE_PATH")}}" ;;
    azure) s="{\"container\":$(json_str "$AZ_CONTAINER"),\"client\":\"default\"${AZ_BASE_PATH:+,\"base_path\":$(json_str "$AZ_BASE_PATH")}}" ;;
    gcs)   s="{\"bucket\":$(json_str "$GCS_BUCKET"),\"client\":\"default\"${GCS_BASE_PATH:+,\"base_path\":$(json_str "$GCS_BASE_PATH")}}" ;;
    hdfs)  s="{\"uri\":$(json_str "$HDFS_URI"),\"path\":$(json_str "$HDFS_PATH")}" ;;
  esac
  printf '{"type":"%s","settings":%s}' "$SNAP_TYPE" "$s"
}
setup_fs_mount() {   # on every ES node when SNAP_TYPE=fs
  [[ ${SNAP_TYPE-} == fs ]] || return 0
  step "Shared snapshot file system (${SNAP_FS_PATH})"
  mkdir -p "$SNAP_FS_PATH"
  if [[ $SNAP_FS_MODE == nfs ]]; then
    if ! mountpoint -q "$SNAP_FS_PATH"; then
      command -v mount.nfs >/dev/null || case $OS_FAMILY in
        debian) pm_install nfs-common ;; rhel) pm_install nfs-utils ;; suse) pm_install nfs-client ;; esac \
        || die "NFS client tools missing and could not be installed."
      if ! grep -qs "[[:space:]]${SNAP_FS_PATH}[[:space:]]" /etc/fstab; then
        cp -a /etc/fstab "/etc/fstab.bak.elastic.$(date +%s)"
        echo "${SNAP_NFS_EXPORT}  ${SNAP_FS_PATH}  nfs  ${SNAP_NFS_OPTS}  0 0" >> /etc/fstab
      fi
      mount "$SNAP_FS_PATH" || die "Mounting ${SNAP_NFS_EXPORT} on ${SNAP_FS_PATH} failed."
    fi
    ok "NFS ${SNAP_NFS_EXPORT} mounted (persistent in /etc/fstab)"
  else
    mountpoint -q "$SNAP_FS_PATH" || warn "${SNAP_FS_PATH} is not a mount point – it MUST be the same shared file system on every ES node."
  fi
  # Same numeric UID/GID on every node (NFS maps by number), so ownership lines up.
  if [[ $(stat -c %u "$SNAP_FS_PATH") != "$ES_UID" ]]; then
    chown "$ES_UID:$ES_GID" "$SNAP_FS_PATH" 2>/dev/null || warn "Could not chown ${SNAP_FS_PATH} (root squash?) – make it writable for UID ${ES_UID}."
  fi
  chmod 770 "$SNAP_FS_PATH" 2>/dev/null || true
  runuser -u elasticsearch -- sh -c "touch '$SNAP_FS_PATH/.write-test-$NODE_NAME' && rm -f '$SNAP_FS_PATH/.write-test-$NODE_NAME'" \
    || die "The elasticsearch user (UID ${ES_UID}) cannot write to ${SNAP_FS_PATH}."
  ok "${SNAP_FS_PATH} writable by elasticsearch (UID ${ES_UID})"
}

# =============================================================================
#  Elasticsearch node helpers
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
es_diag() {
  journalctl -u elasticsearch.service -n 60 --no-pager >&2 2>/dev/null || true
  tail -n 60 "$ES_LOG_DIR"/*.log >&2 2>/dev/null || true
}
valid_heap() { [[ $1 =~ ^[0-9]+[mMgG]$ ]]; }
compute_heap() {
  local heap_mb
  RAM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
  heap_mb=$((RAM_MB / 2))
  if ((heap_mb > HEAP_CAP_MB)); then heap_mb=$HEAP_CAP_MB; fi
  heap_mb=$((heap_mb / 512 * 512))   # whole 512 MB steps
  if ((heap_mb < 1024)); then heap_mb=1024; fi
  if ((heap_mb % 1024 == 0)); then HEAP_DEF="$((heap_mb / 1024))g"; else HEAP_DEF="${heap_mb}m"; fi
}
valid_data_dir() {
  local dd=$1
  [[ $dd == /* ]] || { echo "    Must be an absolute path." >&2; return 1; }
  [[ $dd != *[[:space:]]* ]] || { echo "    Spaces are not supported." >&2; return 1; }
  case "${dd%/}" in
    ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var)
      echo "    Choose a dedicated directory, not a system directory." >&2; return 1 ;;
  esac
  [[ ${dd%/}/ != "$INSTALL_BASE"/* ]] || { echo "    Keep data outside $INSTALL_BASE." >&2; return 1; }
}
prompt_es_local() {   # heap, data dir, swap (+ frozen cache)
  step "Local settings for this ${NODE_TYPE} node"
  compute_heap
  if ((RAM_MB < 4096)); then warn "Only ${RAM_MB} MB RAM – 8 GB+ is recommended for an Elasticsearch node."; fi
  info "This VM has ${RAM_MB} MB RAM. Recommended JVM heap: ${HEAP_DEF} (50% of RAM, capped for compressed oops)."
  ask ES_HEAP "JVM heap (Xms = Xmx), e.g. 4g or 2048m" "$HEAP_DEF" valid_heap; ES_HEAP=${ES_HEAP,,}
  info "Elasticsearch data directory (path.data) – use a dedicated disk/mount; created if missing (elasticsearch, 750)."
  ask ES_DATA_DIR "Data directory" "$ES_DATA_DIR" valid_data_dir; ES_DATA_DIR=${ES_DATA_DIR%/}
  if [[ -d $ES_DATA_DIR ]] && [[ -n $(find "$ES_DATA_DIR" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit 2>/dev/null) ]]; then
    die "$ES_DATA_DIR is not empty – use an empty directory for a fresh node."
  fi
  FROZEN_CACHE=""
  if [[ $NODE_TYPE == frozen ]]; then
    info "Searchable-snapshot shared cache: Elastic defaults to 90% of the data disk on a dedicated frozen node."
    ask FROZEN_CACHE "Shared cache size (e.g. 90%, 500gb)" "90%" valid_cache
    [[ $FROZEN_CACHE == 90% ]] && FROZEN_CACHE=""
  fi
  ask_yn DISABLE_SWAP "Disable swap (recommended)?" y
}
prepare_data_dir() {
  mkdir -p "$ES_DATA_DIR"; chown elasticsearch:elasticsearch "$ES_DATA_DIR"; chmod 750 "$ES_DATA_DIR"
  if command -v selinuxenabled >/dev/null && selinuxenabled 2>/dev/null && command -v restorecon >/dev/null; then
    if command -v semanage >/dev/null; then
      semanage fcontext -a -t var_lib_t "${ES_DATA_DIR}(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t var_lib_t "${ES_DATA_DIR}(/.*)?" 2>/dev/null || true
    fi
    restorecon -R "$ES_DATA_DIR" 2>/dev/null || true
  fi
  runuser -u elasticsearch -- test -w "$ES_DATA_DIR" -a -x "$ES_DATA_DIR" \
    || die "The elasticsearch user cannot write to $ES_DATA_DIR – check parent directory permissions (o+x) and mount options."
  ok "Data directory $ES_DATA_DIR ready"
}
write_heap() {
  printf '# Managed by %s – sized from %s MB RAM\n-Xms%s\n-Xmx%s\n' "$SCRIPT_NAME" "${RAM_MB:-?}" "$1" "$1" \
    > "$ES_HOME/config/jvm.options.d/heap.options"
  chown elasticsearch:elasticsearch "$ES_HOME/config/jvm.options.d/heap.options"
}
es_user_create() {   # fixed UID/GID on every ES node (NFS snapshot repos map by number)
  if getent group elasticsearch >/dev/null; then
    [[ $(getent group elasticsearch | cut -d: -f3) == "$ES_GID" ]] || warn "Group elasticsearch exists with a different GID than ${ES_GID}."
  else groupadd -r -g "$ES_GID" elasticsearch || die "Cannot create group elasticsearch (GID ${ES_GID} in use?)."; fi
  if id -u elasticsearch >/dev/null 2>&1; then
    if [[ $(id -u elasticsearch) != "$ES_UID" ]]; then
      [[ ${SNAP_TYPE-} == fs ]] && die "User elasticsearch exists with UID $(id -u elasticsearch), expected ${ES_UID} (required for the shared file system)."
      warn "User elasticsearch has UID $(id -u elasticsearch) (plan: ${ES_UID})."
    fi
  else
    useradd -r -u "$ES_UID" -g "$ES_GID" -M -d "$ES_HOME" -s "$(nologin_shell)" elasticsearch \
      || die "Cannot create user elasticsearch (UID ${ES_UID} in use?)."
  fi
}
yml_list() {   # yml_list a b c  -> [ "a", "b", "c" ]
  local out="[" x first=1
  for x in "$@"; do ((first)) || out+=", "; out+="\"$x\""; first=0; done
  echo "${out} ]"
}
es_write_yml() {
  local yml="$ES_HOME/config/elasticsearch.yml" m
  local -a seeds=(); for m in "${MASTER_IPS[@]}"; do seeds+=("${m}:9300"); done
  cp -a "$yml" "$yml.dist" 2>/dev/null || true
  {
    echo "# ===================== Managed by ${SCRIPT_NAME} ${SCRIPT_VERSION} ====================="
    echo "cluster.name: ${CLUSTER_NAME}"
    echo "node.name: ${NODE_NAME}"
    echo "node.roles: [ ${TIER_ROLES[$NODE_TYPE]} ]"
    echo "path.data: ${ES_DATA_DIR}"
    echo "path.logs: ${ES_LOG_DIR}"
    [[ ${SNAP_TYPE-} == fs ]] && echo "path.repo: [ \"${SNAP_FS_PATH}\" ]"
    echo "bootstrap.memory_lock: true"
    echo
    echo "network.host: 0.0.0.0"
    echo "network.publish_host: ${NODE_IP}"
    echo "http.port: 9200"
    echo "transport.port: 9300"
    echo "discovery.seed_hosts: $(yml_list "${seeds[@]}")"
    if [[ $NODE_TYPE == master ]]; then
      echo "# Bootstrap only – removed automatically once the cluster has formed:"
      echo "cluster.initial_master_nodes: $(yml_list "${MASTER_NAMES[@]}")"
    fi
    echo
    echo "# Security: TLS with the cluster CA created on master-1 (no auto-configuration)"
    echo "xpack.security.enabled: true"
    echo "xpack.security.enrollment.enabled: false"
    echo "xpack.security.transport.ssl.enabled: true"
    echo "xpack.security.transport.ssl.verification_mode: full"
    echo "xpack.security.transport.ssl.client_authentication: required"
    echo "xpack.security.transport.ssl.key: certs/node.key"
    echo "xpack.security.transport.ssl.certificate: certs/node.crt"
    echo "xpack.security.transport.ssl.certificate_authorities: [ \"certs/ca.crt\" ]"
    echo "xpack.security.http.ssl.enabled: true"
    echo "xpack.security.http.ssl.key: certs/node.key"
    echo "xpack.security.http.ssl.certificate: certs/node.crt"
    echo "xpack.security.http.ssl.certificate_authorities: [ \"certs/ca.crt\" ]"
    if [[ $NODE_TYPE == frozen && -n ${FROZEN_CACHE-} ]]; then
      echo; echo "xpack.searchable.snapshot.shared_cache.size: ${FROZEN_CACHE}"
    fi
    if [[ $ART_MODE == repo ]]; then
      echo
      echo "# Air-gapped: no Internet GeoIP downloads (host your own endpoint if needed)"
      echo "ingest.geoip.downloader.enabled: false"
    fi
    if [[ $NODE_TYPE == master && -n ${ML_MODEL_REPO-} ]]; then
      echo "xpack.ml.model_repository: ${ML_MODEL_REPO}"
    fi
    case ${SNAP_TYPE-} in
      s3)
        if [[ -n $S3_ENDPOINT ]]; then
          echo; echo "s3.client.default.endpoint: \"${S3_ENDPOINT}\""
          [[ ${S3_PATH_STYLE-} == yes ]] && echo "s3.client.default.path_style_access: true"
        fi ;;
      azure) [[ -n $AZ_ENDPOINT_SUFFIX ]] && { echo; echo "azure.client.default.endpoint_suffix: \"${AZ_ENDPOINT_SUFFIX}\""; } ;;
      gcs)   [[ -n $GCS_ENDPOINT ]] && { echo; echo "gcs.client.default.endpoint: \"${GCS_ENDPOINT}\""; } ;;
    esac
    return 0
  } > "$yml"
  chown elasticsearch:elasticsearch "$yml"; chmod 640 "$yml"
}
es_keystore() {
  local ks="$ES_HOME/config/elasticsearch.keystore"
  [[ -f $ks ]] || es_cli elasticsearch-keystore create >/dev/null
  printf '%s' "$ELASTIC_PASSWORD" | es_cli elasticsearch-keystore add --stdin --force bootstrap.password >/dev/null
  case ${SNAP_TYPE-} in
    s3)
      printf '%s' "$S3_ACCESS_KEY" | es_cli elasticsearch-keystore add --stdin --force s3.client.default.access_key >/dev/null
      printf '%s' "$S3_SECRET_KEY" | es_cli elasticsearch-keystore add --stdin --force s3.client.default.secret_key >/dev/null ;;
    azure)
      printf '%s' "$AZ_ACCOUNT" | es_cli elasticsearch-keystore add --stdin --force azure.client.default.account >/dev/null
      if [[ -n $AZ_KEY ]]; then printf '%s' "$AZ_KEY" | es_cli elasticsearch-keystore add --stdin --force azure.client.default.key >/dev/null
      else printf '%s' "$AZ_SAS" | es_cli elasticsearch-keystore add --stdin --force azure.client.default.sas_token >/dev/null; fi ;;
    gcs)
      local g="$ES_HOME/config/.gcs-credentials.json"
      install -m 0600 -o elasticsearch -g elasticsearch "$PACK_DIR/gcs-credentials.json" "$g"
      es_cli elasticsearch-keystore add-file --force gcs.client.default.credentials_file "$g" >/dev/null
      rm -f "$g" ;;
  esac
  chown elasticsearch:elasticsearch "$ks"; chmod 660 "$ks"
  case ${SNAP_TYPE-} in s3|azure|gcs) ok "Keystore: bootstrap.password + ${SNAP_TYPE} repository credentials" ;;
                        *) ok "Keystore: bootstrap.password" ;; esac
}
es_install_from_pack() {
  local top
  step "Installing Elasticsearch ${STACK_VERSION} – ${NODE_TYPE} node ${NODE_NAME}"
  es_user_create
  top=$(tar_top "$ARTIFACT_PATH"); [[ -n $top ]] || die "Cannot read $ARTIFACT_PATH"
  mkdir -p "$INSTALL_BASE"
  tar -xzf "$ARTIFACT_PATH" -C "$INSTALL_BASE"
  ln -sfn "$INSTALL_BASE/$top" "$ES_HOME"
  mkdir -p "$ES_LOG_DIR" "$ES_TMP_DIR" "$ES_HOME/config/certs" "$ES_HOME/config/jvm.options.d"
  install -m 0644 "$PACK_DIR/ca.crt"   "$ES_HOME/config/certs/ca.crt"
  install -m 0644 "$PACK_DIR/node.crt" "$ES_HOME/config/certs/node.crt"
  install -m 0600 "$PACK_DIR/node.key" "$ES_HOME/config/certs/node.key"
  chown -R elasticsearch:elasticsearch "$INSTALL_BASE/$top" "$ES_LOG_DIR" "$ES_TMP_DIR"
  chmod 750 "$ES_LOG_DIR"
  prepare_data_dir
  setup_fs_mount
  es_write_yml
  write_heap "$ES_HEAP"
  es_keystore
  if [[ ${SNAP_TYPE-} == s3 && -f $PACK_DIR/s3-ca.crt ]]; then
    "$ES_HOME/jdk/bin/keytool" -importcert -noprompt -cacerts -storepass changeit -alias es-snapshot-s3-ca \
      -file "$PACK_DIR/s3-ca.crt" >/dev/null 2>&1 || warn "Could not import the S3 endpoint CA into the bundled JDK."
    ok "S3 endpoint CA trusted by the bundled JDK"
  fi
  if [[ ${SNAP_TYPE-} == hdfs ]]; then
    local es_art=$ARTIFACT_PATH
    get_artifact hdfs
    install -m 0644 "$ARTIFACT_PATH" "$ES_TMP_DIR/repository-hdfs.zip"
    ( cd "$ES_HOME" && ES_PATH_CONF="$ES_HOME/config" "$ES_HOME/bin/elasticsearch-plugin" install --batch "file://$ES_TMP_DIR/repository-hdfs.zip" >/dev/null ) \
      || die "Installing repository-hdfs failed."
    chown -R elasticsearch:elasticsearch "$ES_HOME/plugins" "$ES_HOME/config"
    rm -f "$ES_TMP_DIR/repository-hdfs.zip"; ARTIFACT_PATH=$es_art
    ok "Plugin repository-hdfs installed"
  fi
  cat > /etc/systemd/system/elasticsearch.service <<UNIT
[Unit]
Description=Elasticsearch (${NODE_TYPE})
Documentation=https://www.elastic.co
Wants=network-online.target
After=network-online.target remote-fs.target

[Service]
Type=simple
User=elasticsearch
Group=elasticsearch
Environment=ES_HOME=${ES_HOME}
Environment=ES_PATH_CONF=${ES_HOME}/config
Environment=ES_TMPDIR=${ES_TMP_DIR}
WorkingDirectory=${ES_HOME}
ExecStart=${ES_HOME}/bin/elasticsearch --quiet
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
es_drop_initial_masters() {   # bootstrap setting must not stay in the config
  local yml="$ES_HOME/config/elasticsearch.yml"
  grep -q '^cluster.initial_master_nodes' "$yml" || return 0
  sed -i -e '/^# Bootstrap only – removed automatically/d' -e '/^cluster\.initial_master_nodes:/d' "$yml"
  ok "cluster.initial_master_nodes removed from elasticsearch.yml (takes effect on next restart)"
}
verify_roles() {
  local want got
  es_api GET '/_nodes/_local?filter_path=nodes.*.roles' || { warn "Could not read node roles ($API_CODE)."; return 0; }
  got=$(jgrep '"roles":[[:space:]]*\[[^]]*\]' <<<"$API_BODY" | head -n1 | sed 's/"roles":[[:space:]]*\[//; s/\]//; s/[" ]//g' | tr ',' '\n' | sort | paste -sd, -)
  want=$(tr ',' '\n' <<<"${TIER_ROLES[$NODE_TYPE]}" | tr -d ' ' | sort | paste -sd, -)
  if [[ $got == "$want" ]]; then ok "Node roles: ${got}"
  else warn "Node roles are '${got}', expected '${want}' – check node.roles in elasticsearch.yml."; fi
}
verify_heap() {
  es_api GET '/_nodes/_local/jvm?filter_path=nodes.*.jvm.using_compressed_ordinary_object_pointers' \
    || { warn "Could not read JVM info ($API_CODE)."; return 0; }
  if [[ $API_BODY == *'"using_compressed_ordinary_object_pointers":"true"'* || $API_BODY == *'"using_compressed_ordinary_object_pointers":true'* ]]; then
    ok "JVM heap ${ES_HEAP}, compressed oops enabled"
  else
    warn "Compressed oops are OFF with heap ${ES_HEAP} – lowering to ${HEAP_FALLBACK} and restarting."
    ES_HEAP=$HEAP_FALLBACK; write_heap "$ES_HEAP"
    systemctl restart elasticsearch.service
    es_wait_http 900 || { es_diag; die "Restart failed after heap change."; }
  fi
}
master_health() {   # GET _cluster/health on any master (CLUSTER_CA)  -> API_CODE/BODY
  local m
  for m in "${MASTER_IPS[@]}"; do
    _http GET "https://${m}:9200/_cluster/health" "$CLUSTER_CA" "" && return 0
  done
  return 1
}
es_start_and_join() {
  step "Starting Elasticsearch"
  systemctl start elasticsearch.service
  es_wait_http 900 || { es_diag; die "Elasticsearch did not start – see the log above."; }
  ok "HTTPS 9200 is answering"
  local t=0
  if [[ $NODE_TYPE == master ]]; then
    local wait_s=600; [[ $ROLE == es-first ]] && wait_s=20
    info "Waiting for the master quorum (cluster forms once 2 of ${#MASTER_NAMES[@]} masters are up)…"
    while ((t < wait_s)); do
      if es_api GET /_cluster/health; then break; fi
      sleep 5; t=$((t + 5))
    done
    if [[ $API_CODE == 200 ]]; then
      ok "Cluster '${CLUSTER_NAME}' formed: $(jgrep '"status":[[:space:]]*"[a-z]*"' <<<"$API_BODY" | head -n1 | sed 's/.*"\([a-z]*\)"$/\1/')"
      es_drop_initial_masters
    else
      [[ $ROLE == es-first ]] && info "Not formed yet (expected) – it forms when master-2 starts." \
        || warn "Cluster not formed yet (HTTP ${API_CODE}). Check that the other masters are running and port 9300 is open."
    fi
  else
    while ((t < 600)); do
      if es_api GET '/_cat/nodes?h=name' && awk -v n="$NODE_NAME" '$1 == n { f = 1 } END { exit !f }' <<<"$API_BODY"; then break; fi
      sleep 5; t=$((t + 5))
    done
    ((t < 600)) || { es_diag; die "Node did not join. Masters must reach ${NODE_IP}:9300 (firewall?)."; }
    ok "Joined cluster '${CLUSTER_NAME}'"
  fi
  verify_roles
  verify_heap
}
es_precheck_cluster() {   # data nodes: masters must be up; warm/frozen need a hot node
  step "Checking the cluster before joining"
  master_health || die "No master answered (HTTP ${API_CODE}). Install master-1..3 first (es-first, then es-node on master-2/3)."
  ok "Masters reachable, cluster formed"
  if [[ $NODE_TYPE != hot ]]; then
    local m ok_hot=no
    for m in "${MASTER_IPS[@]}"; do
      if _http GET "https://${m}:9200/_cat/nodes?h=node.role" "$CLUSTER_CA" ""; then
        grep -q 'h' <<<"$API_BODY" && ok_hot=yes; break
      fi
    done
    [[ $ok_hot == yes ]] || die "No hot node in the cluster yet – install the hot nodes first (they hold the content tier)."
    ok "Hot tier present"
  fi
}
persist_elastic_password() {   # writes the password to the security index (needs a content-tier node)
  if es_api POST /_security/user/elastic/_password "{\"password\":$(json_str "$ELASTIC_PASSWORD")}"; then
    ok "elastic password stored in the security index"
  else
    warn "Could not store the elastic password yet (HTTP ${API_CODE}) – es-finalize retries."
  fi
}

# =============================================================================
#  Cluster material: CA, certificates, packs  (master-1)
# =============================================================================
build_node_dir() {   # build_node_dir <type> <name> <ip> <dir>
  local t=$1 n=$2 i=$3 d=$4
  rm -rf "$d"; mkdir -p "$d"; chmod 700 "$d"
  (
    NODE_TYPE=$t; NODE_NAME=$n; NODE_IP=$i
    if [[ $t == kibana || $t == fleet ]]; then   # no storage credentials outside the ES nodes
      S3_ACCESS_KEY=""; S3_SECRET_KEY=""; AZ_KEY=""; AZ_SAS=""
    fi
    write_env "$d/cluster.env" "${CLUSTER_VARS[@]}" NODE_TYPE NODE_NAME NODE_IP
  )
  cp "$CLUSTER_DIR/ca/ca.crt" "$d/ca.crt"
  cp "$CLUSTER_DIR/certs/$n.crt" "$d/node.crt"
  cp "$CLUSTER_DIR/certs/$n.key" "$d/node.key"
  [[ -f $CLUSTER_DIR/repo-ca.crt ]] && cp "$CLUSTER_DIR/repo-ca.crt" "$d/repo-ca.crt"
  if [[ $t != kibana && $t != fleet ]]; then
    [[ -f $CLUSTER_DIR/secrets/s3-ca.crt ]] && cp "$CLUSTER_DIR/secrets/s3-ca.crt" "$d/s3-ca.crt"
    [[ -f $CLUSTER_DIR/secrets/gcs-credentials.json ]] && cp "$CLUSTER_DIR/secrets/gcs-credentials.json" "$d/gcs-credentials.json"
  fi
  return 0
}
build_node_pack() {   # build_node_pack <type> <name> <ip>
  local d="$WORKDIR/build-$2"
  build_node_dir "$1" "$2" "$3" "$d"
  pack_write "$d" "$CLUSTER_DIR/packs/$2.pack"
  rm -rf "$d"
}
generate_cluster_material() {
  step "Cluster CA, node certificates and encrypted node packs"
  mkdir -p "$CLUSTER_DIR"/{certs,packs,secrets}; chmod 700 "$CLUSTER_DIR" "$CLUSTER_DIR"/{certs,packs,secrets}
  ca_create "$CLUSTER_DIR/ca" "Elastic cluster CA (${CLUSTER_NAME})"
  CA_FP=$(cert_fp "$CLUSTER_DIR/ca/ca.crt")
  [[ $ART_MODE == repo ]] && install -m 0644 "$REPO_CA" "$CLUSTER_DIR/repo-ca.crt"
  [[ -n ${S3_CA_FILE-} ]] && install -m 0600 "$S3_CA_FILE" "$CLUSTER_DIR/secrets/s3-ca.crt"
  [[ -n ${GCS_CRED_FILE-} ]] && install -m 0600 "$GCS_CRED_FILE" "$CLUSTER_DIR/secrets/gcs-credentials.json"
  write_env "$CLUSTER_DIR/cluster.env" "${CLUSTER_VARS[@]}"
  plan_nodes > "$CLUSTER_DIR/plan.txt"
  ok "Cluster CA created (fingerprint ${CA_FP:0:16}…)"
  local t n i short
  while read -r t n i; do
    short=${n%%.*}
    if [[ $short != "$n" ]]; then cert_issue "$CLUSTER_DIR/ca" "$CLUSTER_DIR/certs" "$n" "$n" "$short" localhost -- "$i" 127.0.0.1
    else cert_issue "$CLUSTER_DIR/ca" "$CLUSTER_DIR/certs" "$n" "$n" localhost -- "$i" 127.0.0.1; fi
    if [[ $n == "${MASTER_NAMES[0]}" ]]; then
      build_node_dir "$t" "$n" "$i" "$WORKDIR/self"
    else
      build_node_pack "$t" "$n" "$i"
      ok "pack  ${t}  ${n}  (${i})"
    fi
  done < "$CLUSTER_DIR/plan.txt"
  PACK_DIR="$WORKDIR/self"; CLUSTER_CA="$PACK_DIR/ca.crt"
  [[ -f $PACK_DIR/repo-ca.crt ]] && REPO_CA="$PACK_DIR/repo-ca.crt"
  ES_TARGETS=("${HOT_IPS[@]}")
}

# =============================================================================
#  Role: es-first  (master-1)
# =============================================================================
role_es_first() {
  [[ ! -e $CLUSTER_DIR/ca ]] || die "$CLUSTER_DIR/ca already exists – es-first has already run on this VM (use --role pack to re-issue packs)."
  step "Cluster plan"
  if [[ -n ${CLI_PLAN-} ]]; then valid_file "$CLI_PLAN" || die "Plan not found"; plan_load_file "$CLI_PLAN"; ok "Plan loaded from $CLI_PLAN"
  else plan_interactive; fi
  plan_validate
  plan_print
  NODE_TYPE=master; NODE_NAME=${MASTER_NAMES[0]}; NODE_IP=${MASTER_IPS[0]}
  prompt_host_basics "$NODE_NAME" "$NODE_IP"
  step "Cluster settings"
  prompt_version
  ask CLUSTER_NAME "Cluster name" "elastic-prod" valid_name
  info "Password for the built-in 'elastic' superuser (min 12 characters):"
  ask_secret ELASTIC_PASSWORD "elastic password" yes valid_secret12
  info "The elasticsearch user gets the same numeric UID/GID on every ES node (required for NFS snapshots)."
  ask ES_UID "UID/GID for the elasticsearch user" 1550 valid_uid; ES_GID=$ES_UID
  prompt_artifact_source
  REPO_NAME=""; ML_MODEL_REPO=""
  if [[ $ART_MODE == repo ]] && curl -fsS --max-time 10 --cacert "$REPO_CA" -o /dev/null "$(repo_https_url)/ml-models/elser_model_2.metadata.json" 2>/dev/null; then
    ML_MODEL_REPO="$(repo_http_url)/ml-models"
    info "ELSER model found on the repository server – the masters will use ${ML_MODEL_REPO}."
  fi
  prompt_snapshot_repo
  step "Node packs"
  info "Every other VM gets an encrypted pack (its certificate + cluster settings)."
  info "Choose a passphrase (min 12 characters) – you will type it on each VM."
  ask_secret PACK_PASS "Pack passphrase" yes valid_secret12
  prompt_es_local
  confirm_or_abort; start_logging

  prepare_os es
  generate_cluster_material
  get_artifact es
  es_install_from_pack
  save_node_state
  es_start_and_join

  local S=/root/elastic-es-first-summary.txt t n i
  {
    echo "Cluster '${CLUSTER_NAME}' – Elastic ${STACK_VERSION} – ${SCRIPT_NAME} ${SCRIPT_VERSION}"
    echo "master-1: ${NODE_NAME} (${NODE_IP}) installed and started."
    echo
    echo "Cluster CA fingerprint : ${CA_FP}"
    echo "Packs                  : ${CLUSTER_DIR}/packs/  (passphrase: the one you just set)"
    echo
    echo "Copy each pack to its VM (next to the script) and run there, IN THIS ORDER:"
    while read -r t n i; do
      [[ $n == "${MASTER_NAMES[0]}" ]] && continue
      case $t in kibana|fleet) continue ;; esac
      printf '  %-7s %-22s scp %s/packs/%s.pack <user>@%s:  ->  sudo ./%s --role es-node --pack %s.pack\n' \
        "$t" "$n" "$CLUSTER_DIR" "$n" "$i" "$SCRIPT_NAME" "$n"
    done < "$CLUSTER_DIR/plan.txt"
    echo "  then on THIS VM:                sudo ./${SCRIPT_NAME} --role es-finalize"
    echo "  kibana  ${KIBANA_NAME}   ->  sudo ./${SCRIPT_NAME} --role kibana --pack ${KIBANA_NAME}.pack"
    echo "  fleet   ${FLEET_NAME}    ->  sudo ./${SCRIPT_NAME} --role fleet  --pack ${FLEET_NAME}.pack"
    echo
    echo "Keep ${CLUSTER_DIR} (CA key, packs, settings) safe – back it up offline."
  } > "$S"; chmod 600 "$S"
  step "Done"; sed 's/^/    /' "$S"; info ""; info "Saved to $S  |  log: $LOG_FILE"
}

# =============================================================================
#  Role: es-node  (master-2/3, hot, warm, frozen)
# =============================================================================
role_es_node() {
  prompt_pack 'master|hot|warm|frozen'
  [[ $NODE_TYPE == master && $NODE_NAME == "${MASTER_NAMES[0]}" ]] && die "master-1 is installed by es-first."
  prompt_host_basics "$NODE_NAME" "$NODE_IP"
  prompt_es_local
  confirm_or_abort; start_logging
  [[ $NODE_TYPE == master ]] || es_precheck_cluster
  prepare_os es
  get_artifact es
  es_install_from_pack
  save_node_state
  es_start_and_join
  [[ $NODE_TYPE == hot ]] && persist_elastic_password
  step "Done"
  es_api GET '/_cat/nodes?v&h=name,ip,node.role,master&s=name' && printf '%s' "$API_BODY" | sed 's/^/    /'
  info ""
  case $NODE_TYPE in
    master) info "Next: the remaining masters, then the hot nodes (es-node with their packs)." ;;
    hot)    info "Next: the remaining hot nodes, then warm and frozen nodes." ;;
    warm)   info "Next: the remaining warm nodes, then the frozen node(s)." ;;
    frozen) info "Next: on master-1 run  sudo ./${SCRIPT_NAME} --role es-finalize" ;;
  esac
  info "Log: $LOG_FILE"
}

# =============================================================================
#  Role: es-finalize  (master-1, after every ES node has joined)
# =============================================================================
days_of() { echo "${1%d}"; }
role_es_finalize() {
  [[ -f $CLUSTER_DIR/cluster.env ]] || die "Run es-finalize on master-1 (where es-first ran)."
  [[ -d $ES_HOME ]] || die "Elasticsearch is not installed on this VM."
  load_env "$CLUSTER_DIR/cluster.env"
  CLUSTER_CA="$CLUSTER_DIR/ca/ca.crt"; ES_TARGETS=("${HOT_IPS[@]}")
  NODE_TYPE=master; NODE_NAME=${MASTER_NAMES[0]}; NODE_IP=${MASTER_IPS[0]}
  detect_os; OS_FAMILY=$DETECTED_OS
  start_logging

  step "Cluster topology"
  es_api GET '/_cat/nodes?h=name,node.role,master' || die "Cannot query the cluster (HTTP ${API_CODE})."
  local nodes=$API_BODY t n i letters want missing=0 bad=0
  printf '      %-7s %-24s %-10s %s\n' TYPE NAME ROLES STATUS
  while read -r t n i; do
    case $t in kibana|fleet) continue ;; esac
    want=${TIER_LETTERS[$t]}; letters=$(awk -v n="$n" '$1 == n {print $2}' <<<"$nodes")
    if [[ -z $letters ]]; then printf '      %-7s %-24s %-10s %s\n' "$t" "$n" "-" "MISSING"; missing=$((missing + 1))
    elif [[ $letters != "$want" ]]; then printf '      %-7s %-24s %-10s %s\n' "$t" "$n" "$letters" "UNEXPECTED (want ${want})"; bad=$((bad + 1))
    else printf '      %-7s %-24s %-10s %s\n' "$t" "$n" "$letters" "ok"; fi
  done < <(plan_nodes)
  if ((missing + bad)); then
    local c; ask_yn c "${missing} missing / ${bad} unexpected node(s) – continue anyway?" n
    [[ $c == yes ]] || die "Install the missing nodes first (es-node with their packs)."
  else ok "All planned Elasticsearch nodes joined with the expected roles"; fi
  es_drop_initial_masters
  persist_elastic_password

  local frozen_ok=no lic=""
  if [[ -n ${SNAP_TYPE-} ]]; then
    step "Snapshot repository '${SNAP_REPO_NAME}' (${SNAP_TYPE})"
    es_api PUT "/_snapshot/${SNAP_REPO_NAME}" "$(snapshot_repo_body)" \
      || die "Registering the repository failed (HTTP ${API_CODE}): ${API_BODY:0:400}"
    es_api POST "/_snapshot/${SNAP_REPO_NAME}/_verify" \
      || die "Repository verification failed – every master and data node must reach it (HTTP ${API_CODE}): ${API_BODY:0:400}"
    ok "Registered and verified on $(jgrep '"name"' <<<"$API_BODY" | wc -l) node(s)"
  fi
  if ((${#FROZEN_NAMES[@]})) && [[ -n ${SNAP_TYPE-} ]]; then
    step "Licence (the frozen tier uses searchable snapshots = Enterprise feature)"
    es_api GET /_license || die "Cannot read the licence."
    lic=$(jgrep '"type"[[:space:]]*:[[:space:]]*"[a-z]*"' <<<"$API_BODY" | head -n1 | sed 's/.*"\([a-z]*\)"$/\1/')
    info "Current licence: ${lic:-unknown}"
    if [[ $lic != enterprise && $lic != trial ]]; then
      info "  file  = install your Enterprise licence (JSON file from Elastic)"
      info "  trial = start the 30-day trial (all features; evaluation only)"
      info "  skip  = no frozen phase in the ILM policy for now"
      local act; ask_choice act "Licence action" "file" file trial skip
      case $act in
        file) local lf; ask lf "Licence file (JSON)" "" valid_file
              es_api PUT "/_license?acknowledge=true" "$(cat "$lf")" || die "Licence upload failed (HTTP ${API_CODE}): ${API_BODY:0:300}"
              lic=enterprise; ok "Licence installed" ;;
        trial) es_api POST "/_license/start_trial?acknowledge=true" || die "Starting the trial failed (HTTP ${API_CODE}): ${API_BODY:0:300}"
               lic=trial; ok "30-day trial started" ;;
        skip) warn "Frozen phase skipped – the frozen node stays idle until a licence is installed." ;;
      esac
    else ok "Licence allows searchable snapshots"; fi
    [[ $lic == enterprise || $lic == trial ]] && frozen_ok=yes
  fi

  step "Index lifecycle (ILM) policy"
  local pname="hot-warm-frozen"; ((${#WARM_NAMES[@]})) || pname="hot-frozen"; [[ $frozen_ok == yes ]] || pname="${pname%-frozen}"
  [[ $pname == hot ]] && pname="hot-delete"
  ask ILM_NAME "Policy name" "$pname" valid_name
  ask ROLL_SIZE "Hot: roll over at primary shard size" "50gb" valid_size
  ask ROLL_AGE  "Hot: …or at index age" "30d" valid_days
  local warm_age="" frozen_age="" del="" del_age="" phases
  ((${#WARM_NAMES[@]})) && ask warm_age "Move to WARM after" "7d" valid_days
  [[ $frozen_ok == yes ]] && ask frozen_age "Move to FROZEN (searchable snapshot) after" "30d" valid_days
  ask_yn del "Delete data at the end of its retention?" y
  [[ $del == yes ]] && ask del_age "Delete after" "365d" valid_days
  if [[ -n $warm_age && -n $frozen_age ]] && (( $(days_of "$frozen_age") <= $(days_of "$warm_age") )); then die "FROZEN age must be greater than WARM age."; fi
  if [[ -n $del_age ]]; then
    local last=${frozen_age:-$warm_age}
    if [[ -n $last ]] && (( $(days_of "$del_age") <= $(days_of "$last") )); then die "Delete age must be greater than the previous phase."; fi
  fi
  phases="\"hot\":{\"min_age\":\"0ms\",\"actions\":{\"rollover\":{\"max_primary_shard_size\":\"${ROLL_SIZE}\",\"max_age\":\"${ROLL_AGE}\"},\"set_priority\":{\"priority\":100}}}"
  [[ -n $warm_age ]] && phases+=",\"warm\":{\"min_age\":\"${warm_age}\",\"actions\":{\"set_priority\":{\"priority\":50},\"forcemerge\":{\"max_num_segments\":1}}}"
  [[ -n $frozen_age ]] && phases+=",\"frozen\":{\"min_age\":\"${frozen_age}\",\"actions\":{\"searchable_snapshot\":{\"snapshot_repository\":\"${SNAP_REPO_NAME}\"}}}"
  [[ -n $del_age ]] && phases+=",\"delete\":{\"min_age\":\"${del_age}\",\"actions\":{\"delete\":{}}}"
  es_api PUT "/_ilm/policy/${ILM_NAME}" "{\"policy\":{\"_meta\":{\"managed_by\":\"${SCRIPT_NAME}\"},\"phases\":{${phases}}}}" \
    || die "Creating the ILM policy failed (HTTP ${API_CODE}): ${API_BODY:0:400}"
  ok "Policy '${ILM_NAME}': hot${warm_age:+ → warm@${warm_age}}${frozen_age:+ → frozen@${frozen_age}}${del_age:+ → delete@${del_age}}"

  local apply; ask_yn apply "Use '${ILM_NAME}' for all Fleet/Elastic Agent data (logs-*, metrics-*, via logs@custom / metrics@custom)?" y
  if [[ $apply == yes ]]; then
    local ct
    for ct in logs@custom metrics@custom; do
      if es_api GET "/_component_template/${ct}" && [[ $API_BODY != *"$SCRIPT_NAME"* ]]; then
        warn "${ct} already exists with your own settings – not overwritten. Add index.lifecycle.name: ${ILM_NAME} to it manually."
        continue
      fi
      es_api PUT "/_component_template/${ct}" "{\"template\":{\"settings\":{\"index\":{\"lifecycle\":{\"name\":\"${ILM_NAME}\"}}}},\"_meta\":{\"managed_by\":\"${SCRIPT_NAME}\"}}" \
        || die "Updating ${ct} failed (HTTP ${API_CODE}): ${API_BODY:0:300}"
      ok "${ct} → index.lifecycle.name: ${ILM_NAME} (applies at the next rollover)"
    done
  fi
  if [[ -n ${SNAP_TYPE-} ]]; then
    local slm; ask_yn slm "Nightly snapshot of the whole cluster (SLM 01:30, keep 30 days)?" y
    if [[ $slm == yes ]]; then
      es_api PUT /_slm/policy/nightly-snapshots "{\"schedule\":\"0 30 1 * * ?\",\"name\":\"<nightly-snap-{now/d}>\",\"repository\":\"${SNAP_REPO_NAME}\",\"config\":{\"include_global_state\":true},\"retention\":{\"expire_after\":\"30d\",\"min_count\":5,\"max_count\":50}}" \
        || die "Creating the SLM policy failed (HTTP ${API_CODE}): ${API_BODY:0:300}"
      ok "SLM policy 'nightly-snapshots' → ${SNAP_REPO_NAME}"
    fi
  fi

  step "Done"
  es_api GET '/_cat/nodes?v&h=name,ip,node.role,master,heap.max&s=name' && printf '%s' "$API_BODY" | sed 's/^/    /'
  es_api GET /_cluster/health && info "Health: $(jgrep '"status":[[:space:]]*"[a-z]*"' <<<"$API_BODY" | head -n1 | sed 's/.*"\([a-z]*\)"$/\1/')"
  info ""
  info "Next: Kibana VM  ->  sudo ./${SCRIPT_NAME} --role kibana --pack ${KIBANA_NAME}.pack"
  info "      Fleet VM   ->  sudo ./${SCRIPT_NAME} --role fleet  --pack ${FLEET_NAME}.pack"
  info "Log: $LOG_FILE"
}

# =============================================================================
#  Role: pack  (master-1: re-issue a node pack, e.g. lost file or new passphrase)
# =============================================================================
role_pack() {
  [[ -f $CLUSTER_DIR/cluster.env ]] || die "Run --role pack on master-1 (where es-first ran)."
  load_env "$CLUSTER_DIR/cluster.env"
  step "Re-issue a node pack"
  plan_print
  local n t i line
  ask n "Node name" "" valid_hostname
  line=$(plan_nodes | awk -v n="$n" '$2 == n'); [[ -n $line ]] || die "$n is not in the plan."
  read -r t n i <<<"$line"
  [[ -f $CLUSTER_DIR/certs/$n.crt ]] || die "No certificate for $n in $CLUSTER_DIR/certs."
  ask_secret PACK_PASS "Pack passphrase for this pack" yes valid_secret12
  build_node_pack "$t" "$n" "$i"
  ok "Written: $CLUSTER_DIR/packs/$n.pack"
}

# =============================================================================
#  Kibana / Fleet shared helpers
# =============================================================================
es_login_check() {
  es_remote_api GET / || die "Cannot log in to Elasticsearch on the hot nodes (${ES_TARGETS[*]}) with TLS verification (HTTP ${API_CODE}). Finish the ES nodes and es-finalize first."
  ok "Elasticsearch reachable (TLS verified with the cluster CA, elastic login OK)"
}
create_service_token() {   # create_service_token <kibana|fleet-server>  -> stdout
  local svc=$1 name
  name="${svc}-${HOST_SHORT//[^A-Za-z0-9_-]/-}-$(date +%s)"
  es_remote_api POST "/_security/service/elastic/${svc}/credential/token/${name}" \
    || die "Creating the ${svc} service token failed (HTTP ${API_CODE}): ${API_BODY}"
  sed -n 's/.*"value":"\([^"]*\)".*/\1/p' <<<"$API_BODY"
}
valid_mb() { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1024)); }
prompt_kibana_heap() {
  local ram def
  ram=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
  if ((ram >= 10240)); then def=8192; else def=$(( (ram * 3 / 4) / 512 * 512 )); ((def < 1024)) && def=1024; fi
  info "This VM has ${ram} MB RAM. Kibana's Node.js heap limit (MB); leave ~2 GB for the OS and native memory."
  ask KB_HEAP_MB "Kibana heap in MB (8 GB = 8192)" "$def" valid_mb
  if ((KB_HEAP_MB > ram - 1536)); then
    warn "${KB_HEAP_MB} MB leaves less than 1.5 GB for the OS on a ${ram} MB VM."
    local c; ask_yn c "Keep ${KB_HEAP_MB} MB anyway?" n; [[ $c == yes ]] || prompt_kibana_heap
  fi
}
hot_hosts_json() { local out="[" ip first=1; for ip in "${HOT_IPS[@]}"; do ((first)) || out+=","; out+="\"https://${ip}:9200\""; first=0; done; echo "${out}]"; }
hot_hosts_yml()  { local out="[" ip first=1; for ip in "${HOT_IPS[@]}"; do ((first)) || out+=", "; out+="\"https://${ip}:9200\""; first=0; done; echo "${out}]"; }

# ---- Stack Monitoring via Elastic Agent ---------------------------------------
fleet_ensure_policy() {
  local body
  kbn_api GET "/api/fleet/agent_policies/$1" && return 0
  body="{\"id\":\"$1\",\"name\":\"$2\",\"namespace\":\"default\",\"description\":\"Created by ${SCRIPT_NAME}\",\"monitoring_enabled\":[\"logs\",\"metrics\"]}"
  kbn_api POST "/api/fleet/agent_policies?sys_monitoring=true" "$body" && return 0
  kbn_api GET "/api/fleet/agent_policies/$1" && return 0
  kbn_api POST /api/fleet/agent_policies "$body"
}
fleet_pkg_version() {
  kbn_api POST "/api/fleet/epm/packages/$1" '{}' || true
  kbn_api GET "/api/fleet/epm/packages/$1" || return 1
  local v; v=$(jgrep '"version":[[:space:]]*"[0-9][^"]*"' <<<"$API_BODY" | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  echo "$v"
}
fleet_add_pkg_policy() {
  kbn_api POST /api/fleet/package_policies \
    "{\"name\":\"$1\",\"namespace\":\"default\",\"policy_ids\":[\"$2\"],\"package\":{\"name\":\"$3\",\"version\":\"$4\"},\"inputs\":$5}" \
    && return 0
  [[ $API_CODE == 409 ]] && return 0
  warn "Adding '$1' failed (${API_CODE}): ${API_BODY:0:300}"; return 1
}
fleet_enrollment_token() {
  kbn_api GET "/api/fleet/enrollment_api_keys?perPage=100" || return 1
  tr '{' '\n' <<<"$API_BODY" | { grep "\"policy_id\":\"$1\"" || true; } | jgrep '"api_key":"[^"]*"' | head -n1 | cut -d'"' -f4
}
setup_stack_monitoring() {
  step "Stack Monitoring (Elastic Agent + Elasticsearch/Kibana integrations)"
  local mon_pw es_v kb_v es_inputs kb_inputs
  mon_pw=$(openssl rand -hex 24)
  es_remote_api POST /_security/user/remote_monitoring_user/_password "{\"password\":\"${mon_pw}\"}" \
    || { warn "Could not set the remote_monitoring_user password (${API_CODE})."; return 1; }
  fleet_ensure_policy "$SM_ES_POLICY" "Stack Monitoring - Elasticsearch" || { warn "Creating policy $SM_ES_POLICY failed (${API_CODE})."; return 1; }
  fleet_ensure_policy "$SM_KB_POLICY" "Stack Monitoring - Kibana"        || { warn "Creating policy $SM_KB_POLICY failed (${API_CODE})."; return 1; }
  es_v=$(fleet_pkg_version elasticsearch) || { warn "Elasticsearch integration unavailable from the package registry."; return 1; }
  kb_v=$(fleet_pkg_version kibana)        || { warn "Kibana integration unavailable from the package registry."; return 1; }
  es_inputs="{\"elasticsearch-logfile\":{\"enabled\":true},\"elasticsearch-elasticsearch/metrics\":{\"enabled\":true,\"vars\":{\"hosts\":[\"https://localhost:9200\"],\"username\":\"remote_monitoring_user\",\"password\":\"${mon_pw}\",\"scope\":\"node\",\"ssl\":\"certificate_authorities: [${ES_HOME}/config/certs/ca.crt]\"}}}"
  kb_inputs="{\"kibana-logfile\":{\"enabled\":true},\"kibana-http/metrics\":{\"enabled\":false},\"kibana-kibana/metrics\":{\"enabled\":true,\"vars\":{\"hosts\":[\"https://${IP}:5601\"],\"username\":\"remote_monitoring_user\",\"password\":\"${mon_pw}\",\"ssl\":\"certificate_authorities: [${KB_CA}]\"}}}"
  fleet_add_pkg_policy "elasticsearch-stack-monitoring" "$SM_ES_POLICY" elasticsearch "$es_v" "$es_inputs" || return 1
  fleet_add_pkg_policy "kibana-stack-monitoring"        "$SM_KB_POLICY" kibana        "$kb_v" "$kb_inputs" || return 1
  ok "Policies '$SM_ES_POLICY' (elasticsearch $es_v) and '$SM_KB_POLICY' (kibana $kb_v) ready"
  SM_ES_TOKEN=$(fleet_enrollment_token "$SM_ES_POLICY" || true)
  SM_KB_TOKEN=$(fleet_enrollment_token "$SM_KB_POLICY" || true)
  [[ -n $SM_ES_TOKEN && -n $SM_KB_TOKEN ]] || { warn "Could not read the enrollment tokens – see Fleet > Enrollment tokens."; return 1; }
  ok "Enrollment tokens retrieved"
}

# =============================================================================
#  Role: kibana
# =============================================================================
role_kibana() {
  prompt_pack kibana
  prompt_host_basics "$NODE_NAME" "$NODE_IP"
  step "Kibana settings"
  ask_yn OWN_CERTS "Use your own CA-signed certificate for browser HTTPS (default: cluster-CA certificate)?" n
  if [[ $OWN_CERTS == yes ]]; then
    ask OWN_CERT "Certificate (PEM, SAN must include ${HOST_NAME} and/or ${IP})" "" valid_file
    ask OWN_KEY  "Private key (PEM, unencrypted)" "" valid_file
    ask OWN_CA   "CA certificate that signed it" "" valid_file
  fi
  ask_yn ENABLE_MONITORING "Create Stack Monitoring policies (Elastic Agent based)?" y
  prompt_kibana_heap
  confirm_or_abort; start_logging

  prepare_os kibana
  es_login_check
  local sa_token; sa_token=$(create_service_token kibana)
  [[ -n $sa_token ]] || die "Empty Kibana service token."
  ok "Kibana service-account token created"
  get_artifact kibana

  step "Installing Kibana ${STACK_VERSION}"
  id -u kibana >/dev/null 2>&1 || useradd --system --user-group --no-create-home --home-dir "$KB_HOME" --shell "$(nologin_shell)" kibana
  local top; top=$(tar_top "$ARTIFACT_PATH"); [[ -n $top ]] || die "Cannot read $ARTIFACT_PATH"
  mkdir -p "$INSTALL_BASE"; tar -xzf "$ARTIFACT_PATH" -C "$INSTALL_BASE"; ln -sfn "$INSTALL_BASE/$top" "$KB_HOME"
  local cd="$KB_HOME/config/certs"
  mkdir -p "$KB_DATA_DIR" "$KB_LOG_DIR" "$cd"
  install -m 0644 "$CLUSTER_CA" "$cd/es-ca.crt"
  if [[ $OWN_CERTS == yes ]]; then
    install -m 0644 "$OWN_CA" "$cd/ca.crt"; install -m 0644 "$OWN_CERT" "$cd/kibana.crt"; install -m 0600 "$OWN_KEY" "$cd/kibana.key"
  else
    install -m 0644 "$CLUSTER_CA" "$cd/ca.crt"; install -m 0644 "$PACK_DIR/node.crt" "$cd/kibana.crt"; install -m 0600 "$PACK_DIR/node.key" "$cd/kibana.key"
  fi
  # CA bundle for Node.js (package registry over HTTPS + cluster CA)
  { cat "$CLUSTER_CA"; [[ -n $REPO_CA ]] && { echo; cat "$REPO_CA"; }; } | sed '/^$/d' > "$cd/extra-ca.pem"
  chmod 644 "$cd/extra-ca.pem"
  chown -R kibana:kibana "$INSTALL_BASE/$top" "$KB_DATA_DIR" "$KB_LOG_DIR"
  chmod 750 "$KB_DATA_DIR" "$KB_LOG_DIR"

  {
    echo "# ===================== Managed by ${SCRIPT_NAME} ${SCRIPT_VERSION} ====================="
    echo "server.port: 5601"
    echo "server.host: \"${IP}\""
    echo "server.name: \"${HOST_NAME}\""
    echo "server.publicBaseUrl: \"https://${IP}:5601\""
    echo "server.ssl.enabled: true"
    echo "server.ssl.certificate: ${cd}/kibana.crt"
    echo "server.ssl.key: ${cd}/kibana.key"
    echo
    echo "# Kibana -> Elasticsearch: hot nodes (coordinating/ingest), full TLS verification,"
    echo "# service-account token in the Kibana keystore."
    echo "elasticsearch.hosts: $(hot_hosts_yml)"
    echo "elasticsearch.ssl.certificateAuthorities: [ \"${cd}/es-ca.crt\" ]"
    echo "elasticsearch.ssl.verificationMode: full"
    echo "path.data: ${KB_DATA_DIR}"
    if [[ $ART_MODE == repo ]]; then
      echo
      echo "# Air-gapped: Fleet uses the local Elastic Package Registry; no calls to the Internet"
      echo "xpack.fleet.isAirGapped: true"
      echo "xpack.fleet.registryUrl: \"$(epr_url)\""
      echo "telemetry.optIn: false"
      echo "telemetry.allowChangingOptInStatus: false"
      echo "newsfeed.enabled: false"
      echo "map.includeElasticMapsService: false"
    fi
    cat <<'LOG'

logging:
  appenders:
    file:
      type: rolling-file
      fileName: /var/log/kibana/kibana.log
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
LOG
  } > "$KB_HOME/config/kibana.yml"
  chown kibana:kibana "$KB_HOME/config/kibana.yml"; chmod 640 "$KB_HOME/config/kibana.yml"
  local f="$KB_HOME/config/node.options"; touch "$f"; sed -i '/--max-old-space-size/d' "$f"
  printf '\n# Kibana heap limit (set by %s)\n--max-old-space-size=%s\n' "$SCRIPT_NAME" "$KB_HEAP_MB" >> "$f"; chown kibana:kibana "$f"
  ok "Kibana heap limit ${KB_HEAP_MB} MB"

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
Environment=NODE_EXTRA_CA_CERTS=${cd}/extra-ca.pem
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
    sleep 5; t=$((t + 5))
  done
  case $ready in
    yes) ok "Kibana is available" ;;
    degraded) warn "Kibana is up but 'degraded' – review Stack Management > Status." ;;
    *) journalctl -u kibana.service -n 60 --no-pager >&2 || true; die "Kibana did not become available." ;;
  esac

  step "Configuring Fleet"
  local fleet_url="https://${FLEET_IP}:${FLEET_PORT}" body _ done_setup=no
  for _ in $(seq 1 12); do kbn_api POST /api/fleet/setup '{}' && { done_setup=yes; break; }; sleep 10; done
  [[ $done_setup == yes ]] || die "Fleet setup failed (${API_CODE}): ${API_BODY}"
  kbn_api PUT /api/fleet/outputs/fleet-default-output \
    "{\"name\":\"default\",\"type\":\"elasticsearch\",\"hosts\":$(hot_hosts_json),\"is_default\":true,\"is_default_monitoring\":true,\"ca_trusted_fingerprint\":\"${CA_FP}\"}" \
    || die "Updating the default output failed (${API_CODE}): ${API_BODY}"
  ok "Default output -> hot nodes ${HOT_IPS[*]} (cluster CA pinned by fingerprint)"
  kbn_api GET /api/fleet/fleet_server_hosts || die "Listing Fleet Server hosts failed (${API_CODE})."
  if [[ $API_BODY != *"\"${fleet_url}\""* ]]; then
    kbn_api POST /api/fleet/fleet_server_hosts "{\"name\":\"Fleet Server (${FLEET_NAME})\",\"host_urls\":[\"${fleet_url}\"],\"is_default\":true}" \
      || die "Adding the Fleet Server host failed (${API_CODE}): ${API_BODY}"
  fi
  ok "Fleet Server host ${fleet_url}"
  if [[ $ART_MODE == repo ]]; then
    local dl; dl="$(repo_http_url)/downloads/"
    kbn_api GET /api/fleet/agent_download_sources || die "Listing agent download sources failed (${API_CODE})."
    if [[ $API_BODY != *"\"${dl}\""* ]]; then
      kbn_api POST /api/fleet/agent_download_sources "{\"name\":\"Air-gapped artifact registry\",\"host\":\"${dl}\",\"is_default\":true}" \
        || die "Adding the agent binary download source failed (${API_CODE}): ${API_BODY}"
    fi
    ok "Agent binary download source -> ${dl} (default, used for agent upgrades)"
  fi
  if ! kbn_api GET "/api/fleet/agent_policies/${FLEET_POLICY_ID}"; then
    body="{\"id\":\"${FLEET_POLICY_ID}\",\"name\":\"Fleet Server Policy\",\"namespace\":\"default\",\"description\":\"Created by ${SCRIPT_NAME}\",\"has_fleet_server\":true,\"monitoring_enabled\":[\"logs\",\"metrics\"]}"
    if ! kbn_api POST "/api/fleet/agent_policies?sys_monitoring=true" "$body"; then
      warn "Policy with the System integration failed (${API_CODE}) – is the package registry reachable? Retrying without it."
      kbn_api GET "/api/fleet/agent_policies/${FLEET_POLICY_ID}" || kbn_api POST /api/fleet/agent_policies "$body" \
        || die "Creating the Fleet Server policy failed (${API_CODE}): ${API_BODY}"
    fi
  fi
  ok "Fleet Server policy '${FLEET_POLICY_ID}'"
  SM_ES_TOKEN=""; SM_KB_TOKEN=""
  if [[ $ENABLE_MONITORING == yes ]]; then
    setup_stack_monitoring || warn "Stack Monitoring was not fully configured – add it later in Fleet."
  fi
  save_node_state

  local S=/root/elastic-kibana-summary.txt
  {
    echo "Kibana ${HOST_NAME} (${IP}) – Elastic ${STACK_VERSION}"
    echo
    echo "URL            : https://${IP}:5601   (user: elastic)"
    echo "Browser CA     : ${cd}/ca.crt  (fingerprint $(cert_fp "$cd/ca.crt"))"
    echo "Fleet Server   : ${fleet_url}  policy '${FLEET_POLICY_ID}'"
    [[ $ART_MODE == repo ]] && echo "Air-gapped     : registry $(epr_url), agent downloads $(repo_http_url)/downloads/"
    echo
    echo "Next: Fleet VM -> sudo ./${SCRIPT_NAME} --role fleet --pack ${FLEET_NAME}.pack"
    if [[ -n $SM_ES_TOKEN || -n $SM_KB_TOKEN ]]; then
      echo
      echo "Stack Monitoring (after Fleet Server is up): sudo ./${SCRIPT_NAME} --role monitor"
      echo "  on every Elasticsearch VM with token: ${SM_ES_TOKEN:-<not created>}"
      echo "  on this Kibana VM with token        : ${SM_KB_TOKEN:-<not created>}"
    fi
  } > "$S"; chmod 600 "$S"
  step "Done"; sed 's/^/    /' "$S"; info ""; info "Saved to $S  |  log: $LOG_FILE"
}

# =============================================================================
#  Role: fleet  (Fleet Server)
# =============================================================================
role_fleet() {
  prompt_pack fleet
  prompt_host_basics "$NODE_NAME" "$NODE_IP"
  confirm_or_abort; start_logging
  prepare_os fleet
  es_login_check
  local fs_token; fs_token=$(create_service_token fleet-server)
  [[ -n $fs_token ]] || die "Empty Fleet Server service token."
  ok "fleet-server service-account token created"
  get_artifact agent

  step "Installing Fleet Server (Elastic Agent ${STACK_VERSION}, servers flavor)"
  mkdir -p "$FLEET_CERT_DIR"; chmod 700 "$FLEET_CERT_DIR"
  install -m 0644 "$CLUSTER_CA" "$FLEET_CERT_DIR/ca.crt"
  { cat "$PACK_DIR/node.crt"; echo; cat "$CLUSTER_CA"; } | sed '/^$/d' > "$FLEET_CERT_DIR/fleet-server.crt"
  chmod 0644 "$FLEET_CERT_DIR/fleet-server.crt"
  install -m 0600 "$PACK_DIR/node.key" "$FLEET_CERT_DIR/fleet-server.key"
  ( umask 077; printf '%s' "$fs_token" > "$FLEET_CERT_DIR/fleet-server.token" )
  local stg="$INSTALL_BASE/staging" top
  mkdir -p "$stg"; top=$(tar_top "$ARTIFACT_PATH"); [[ -n $top ]] || die "Cannot read $ARTIFACT_PATH"
  rm -rf "${stg:?}/$top"; tar -xzf "$ARTIFACT_PATH" -C "$stg"
  ( cd "$stg/$top" && ./elastic-agent install --non-interactive --install-servers \
      --url="https://${IP}:${FLEET_PORT}" \
      --certificate-authorities="$FLEET_CERT_DIR/ca.crt" \
      --fleet-server-es="https://${HOT_IPS[0]}:9200" \
      --fleet-server-es-ca="$FLEET_CERT_DIR/ca.crt" \
      --fleet-server-service-token-path="$FLEET_CERT_DIR/fleet-server.token" \
      --fleet-server-policy="$FLEET_POLICY_ID" \
      --fleet-server-cert="$FLEET_CERT_DIR/fleet-server.crt" \
      --fleet-server-cert-key="$FLEET_CERT_DIR/fleet-server.key" \
      --fleet-server-port="$FLEET_PORT" ) \
    || die "elastic-agent install failed – did the kibana run create policy '${FLEET_POLICY_ID}'?"
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
  save_node_state
  local S=/root/elastic-fleet-summary.txt
  {
    echo "Fleet Server ${HOST_NAME} (${IP}) – Elastic ${STACK_VERSION}"
    echo
    echo "URL            : https://${IP}:${FLEET_PORT}"
    echo "CA for agents  : $FLEET_CERT_DIR/ca.crt  (cluster CA, fingerprint ${CA_FP})"
    [[ $ART_MODE == repo ]] && echo "Agent binaries : $(repo_http_url)/downloads/  (Fleet default download source)"
    echo
    echo "Enroll agents (token from Kibana > Fleet > Enrollment tokens):"
    echo "  sudo ./elastic-agent install --url=https://${IP}:${FLEET_PORT} --enrollment-token=<TOKEN> \\"
    echo "       --certificate-authorities=/path/to/ca.crt"
    echo "Stack Monitoring: sudo ./${SCRIPT_NAME} --role monitor  on each ES VM and the Kibana VM."
  } > "$S"; chmod 600 "$S"
  step "Done"; sed 's/^/    /' "$S"; info ""; info "Saved to $S  |  log: $LOG_FILE"
}

# =============================================================================
#  Role: monitor  (Elastic Agent for Stack Monitoring on ES / Kibana VMs)
# =============================================================================
role_monitor() {
  [[ ! -e /opt/Elastic/Agent ]] || die "Elastic Agent is already installed on this VM."
  [[ -f $STATE_DIR/node.env ]] || die "Run --role monitor on an Elasticsearch or Kibana VM installed by this script."
  load_env "$STATE_DIR/node.env"
  CLUSTER_CA="$STATE_DIR/ca.crt"; [[ -f $STATE_DIR/repo-ca.crt ]] && REPO_CA="$STATE_DIR/repo-ca.crt"
  detect_os; OS_FAMILY=$DETECTED_OS
  step "Stack Monitoring agent for ${NODE_NAME} (${NODE_TYPE})"
  info "Fleet Server: https://${FLEET_IP}:${FLEET_PORT} (certificate from the cluster CA)"
  info "Use the $([[ $NODE_TYPE == kibana ]] && echo Kibana || echo Elasticsearch) monitoring token from /root/elastic-kibana-summary.txt on the Kibana VM."
  ask_token MON_TOKEN "Fleet enrollment token" "${CLI_TOKEN-}"
  confirm_or_abort; start_logging
  curl -fsS --max-time 10 --cacert "$CLUSTER_CA" -o /dev/null "https://${FLEET_IP}:${FLEET_PORT}/api/status" \
    || die "Fleet Server https://${FLEET_IP}:${FLEET_PORT} is not reachable / not trusted."
  ok "Fleet Server reachable (TLS verified)"
  get_artifact agent
  step "Installing Elastic Agent ${STACK_VERSION} (enrolled in Fleet)"
  local stg="$INSTALL_BASE/staging" top
  mkdir -p "$stg"; top=$(tar_top "$ARTIFACT_PATH"); [[ -n $top ]] || die "Cannot read $ARTIFACT_PATH"
  rm -rf "${stg:?}/$top"; tar -xzf "$ARTIFACT_PATH" -C "$stg"
  ( cd "$stg/$top" && ./elastic-agent install --non-interactive --url="https://${FLEET_IP}:${FLEET_PORT}" \
      --enrollment-token="$MON_TOKEN" --certificate-authorities="$CLUSTER_CA" ) || die "elastic-agent install failed."
  rm -rf "${stg:?}/$top"
  local _ healthy=no
  for _ in $(seq 1 36); do elastic-agent status 2>/dev/null | grep -q 'HEALTHY' && { healthy=yes; break; }; sleep 5; done
  if [[ $healthy == yes ]]; then ok "Agent is running and enrolled"
  else warn "Agent not HEALTHY yet – check 'elastic-agent status' and Kibana > Fleet > Agents."; fi
  step "Done"; info "Data appears in Kibana > Stack Monitoring within a few minutes."; info "Log: $LOG_FILE"
}

# =============================================================================
#  Main
# =============================================================================
usage() { sed -n '3,/^# =====/p' "$0" | sed '$d; s/^#//'; }
main() {
  ROLE=""; CLI_TOKEN=""; CLI_PACK=""; CLI_PLAN=""
  while (($#)); do
    case $1 in
      --role) ROLE=${2-}; shift 2 ;;
      --pack) CLI_PACK=${2-}; shift 2 ;;
      --plan) CLI_PLAN=${2-}; shift 2 ;;
      --token) CLI_TOKEN=${2-}; shift 2 ;;
      --token-file) [[ -r ${2-} ]] || die "Cannot read token file: ${2-}"; CLI_TOKEN=$(<"$2"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1 (see --help)" ;;
    esac
  done
  [[ $EUID -eq 0 ]] || die "Run as root:  sudo $0"
  ((BASH_VERSINFO[0] >= 4)) || die "bash 4+ is required."
  command -v curl >/dev/null || die "curl is required."
  command -v openssl >/dev/null || die "openssl is required."
  if [[ -z $ROLE ]]; then
    printf '%sElastic Stack setup %s (tiered, air-gapped ready)%s\n' "$B" "$SCRIPT_VERSION" "$N"
    info "Order: bundle (Internet PC) → repo → es-first → es-node (masters, hot, warm, frozen) → es-finalize → kibana → fleet → monitor"
    ask_choice ROLE "Role for THIS machine" "es-node" bundle repo es-first es-node es-finalize kibana fleet monitor pack
  fi
  [[ $ROLE == bundle ]] || [[ -d /run/systemd/system ]] || die "systemd is required."
  detect_arch
  case $ROLE in
    bundle)      role_bundle ;;
    repo)        role_repo ;;
    es-first)    check_not_installed; role_es_first ;;
    es-node)     check_not_installed; role_es_node ;;
    es-finalize) role_es_finalize ;;
    pack)        role_pack ;;
    kibana)      check_not_installed; role_kibana ;;
    fleet)       check_not_installed; role_fleet ;;
    monitor)     role_monitor ;;
    *) die "Unknown role: $ROLE" ;;
  esac
}

main "$@"
