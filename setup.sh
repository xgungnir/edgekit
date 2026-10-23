#!/usr/bin/env bash
# edgekit: one installed entry point for provisioning, management and renewal.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EDGEKIT_VERSION=0.3.3
ROOT=/etc/edgekit
ENTRY=/usr/bin/ek
DEFAULT_ENV=/root/.ek.env
BOOTSTRAP=/root/setup.sh
STATE=$ROOT/state
TLS_ROOT=$ROOT/tls
TLS_PACKAGES=$TLS_ROOT/conda-forge
TLS_CURRENT=$TLS_ROOT/conda-current
TLS_DROPIN=/etc/systemd/system/nginx.service.d/edgekit-tls.conf
TLS_ENV=(OPENSSL_CONF=/etc/ssl/openssl.cnf SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt SSL_CERT_DIR=/etc/ssl/certs)
NETWORK_CONF=/etc/sysctl.d/99-proxy-tuning.conf
NETWORK_SYSCTL_DIRS=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d)
NETWORK_SYSCTL_LEGACY=/etc/sysctl.conf
NETWORK_SYS=/sys
NETWORK_PROC=/proc
SSH_JAIL=edgekit-sshd-password
F2B_DIR=/etc/fail2ban
SSH_JAIL_FILE=$F2B_DIR/jail.d/$SSH_JAIL.local
SSH_FILTER_FILE=$F2B_DIR/filter.d/$SSH_JAIL.conf
XR_HOME=$ROOT/xray
XR_BIN=$XR_HOME/xray
XR=$XR_HOME/conf
SB_BIN=/usr/bin/sing-box
SB_CONFIG=/etc/sing-box/config.json
SB_STATE=/var/lib/sing-box
SB_LOG=$ROOT/sing-box/error.log
SELF=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
STAGE=Entry
LOG=/dev/null

# ---------- Common checks and restricted operation logs ----------
say() { printf '%s\n' "$*"; }
report_error() {
    say "$*" >&3
    if [[ $LOG != /dev/null ]]; then say "$*" >>"$LOG" || true; fi
}
fail() { report_error "Failed [$STAGE]: $*"; exit 1; }
root_required() { [[ $EUID == 0 ]] || fail 'Run this command with sudo or as root.'; }
installed() { [[ -f $STATE/owner && -f $STATE/installed ]]; }
require_install() { installed || fail 'No complete installation found. Check the installation log; configuration will not be initialized automatically.'; }
stage() { STAGE=$1; say "[$STAGE] $2"; }
error_report() {
    local rc=$?
    trap - ERR
    report_error "Failed [$STAGE]: operation incomplete (exit code ${rc}). Log: $LOG"
    local s
    for s in xray nginx sing-box; do say "$s: $(systemctl is-active "$s" 2>/dev/null || true)" >&3; done
    exit "$rc"
}
start_log() {
    root_required
    install -d -m 700 "$STATE"
    LOG=$STATE/$1.log
    touch "$LOG"; chmod 600 "$LOG"
    trap error_report ERR
}
fetch() { curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 300 "$@"; }
confirm() {
    local answer
    read -r -p 'Continue? [y/N] ' answer || return 1
    [[ $answer == y || $answer == Y ]]
}
check_os() {
    [[ -r /etc/os-release && -d /run/systemd/system ]] || fail 'Only Debian 12/13 with systemd is supported.'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ $ID == debian && ( $VERSION_ID == 12 || $VERSION_ID == 13 ) ]] || fail 'Only Debian 12/13 is supported.'
    CODENAME=$VERSION_CODENAME
    DEBIAN=$VERSION_ID
    case $(uname -m) in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; *) fail 'Unsupported CPU architecture.';; esac
}
# Bootstrap input is a data file; no external template or shell sourcing is needed.
env_template() {
    cat <<'EOF'
# Required: Cloudflare DNS only domain with an A record pointing to this server's public IPv4.
DOMAIN=
# Required: token with DNS edit and Zone read permissions for this zone.
CF_ZONE_TOKEN=

# Optional: leave blank to generate credentials; saved credentials are reused.
VLESS_UUID=
REALITY_PRIVATE_KEY=
REALITY_SHORT_ID=
TUIC_UUID=
TUIC_PASSWORD=
# Wrap values containing special characters in single quotes; commands and variables are not expanded.
EOF
}
create_default_env() (
    local tmp=''
    trap '[[ -z $tmp ]] || rm -f "$tmp"' EXIT
    umask 077
    tmp=$(mktemp "${DEFAULT_ENV}.XXXXXX")
    env_template > "$tmp"
    chown 0:0 "$tmp"; chmod 600 "$tmp"
    # A hard link publishes a complete file and refuses to replace any existing path.
    ln -T "$tmp" "$DEFAULT_ENV" || fail "${DEFAULT_ENV} already exists or cannot be created; nothing was overwritten."
)
install_entry() (
    local tmp=''
    trap '[[ -z $tmp ]] || rm -f "$tmp"' EXIT
    [[ ! -L $ENTRY && ( ! -e $ENTRY || -f $ENTRY ) ]] || fail "${ENTRY} is not a regular file; refusing to overwrite."
    if [[ $SELF == "$ENTRY" ]]; then
        chown 0:0 "$ENTRY"; chmod 755 "$ENTRY"
        return
    fi
    tmp=$(mktemp "${ENTRY}.XXXXXX")
    install -m 755 -o root -g root "$SELF" "$tmp"
    /bin/bash -n "$tmp"
    mv -Tf "$tmp" "$ENTRY"
)
cleanup_bootstrap() {
    # Delete only the agreed download path, and only if it is still the copied script.
    if [[ -f $BOOTSTRAP && ! -L $BOOTSTRAP ]]; then
        if cmp -s "$BOOTSTRAP" "$ENTRY"; then
            rm -f "$BOOTSTRAP" || say "Installation complete, but ${BOOTSTRAP} could not be removed. Remove it manually."
        else say "${BOOTSTRAP} has changed; keeping the file."; fi
    fi
}
prepare_entry() {
    check_os
    if [[ $SELF != "$ENTRY" && ( -e $ENTRY || -L $ENTRY ) ]]; then
        [[ -f $ENTRY && ! -L $ENTRY ]] || fail "Unknown entry ${ENTRY} already exists; refusing to overwrite."
        [[ -f $STATE/owner ]] || cmp -s "$SELF" "$ENTRY" || fail "Unknown entry ${ENTRY} already exists; refusing to overwrite."
        exec /bin/bash "$ENTRY" "$@"
    fi
    install_entry
}
start() {
    root_required
    if [[ $SELF != "$ENTRY" ]]; then
        prepare_entry start
        exec /bin/bash "$ENTRY" install
    fi
    if installed; then
        [[ -f $ENTRY && ! -L $ENTRY ]] || fail "Installed entry ${ENTRY} is missing or invalid; it will not be reinstalled automatically."
        menu
    elif [[ -e $STATE/installed && ! -f $STATE/owner ]]; then
        fail 'Installation state has no ownership record; refusing to initialize automatically.'
    else init_menu; fi
}
init_menu() {
    local choice
    while true; do
        say $'edgekit installation is incomplete\n1. Install / Retry installation\n2. Clean up incomplete installation'
        say "8. $(ssh_guard_label)"
        say '0. Exit'
        read -r -p 'Select an option: ' choice || return 0
        case $choice in
            0) return 0;;
            1)
                if confirm; then
                    /bin/bash "$ENTRY" install || say "Installation failed (exit code $?). Check ${DEFAULT_ENV} or the installation log and retry."
                    if installed; then menu; return; fi
                else say 'Cancelled.'; fi;;
            2) /bin/bash "$ENTRY" uninstall || say "Cleanup failed (exit code $?)"; [[ -f $ENTRY ]] || return 0;;
            8) /bin/bash "$ENTRY" ssh-guard || say "Operation failed (exit code $?)";;
            '') say 'No option selected.';;
            *) say 'Invalid input. Try again.';;
        esac
    done
}

# Treat env files as data, never execute shell content or command substitutions.
read_env() {
    local file=$1 line key value
    [[ -f $file && -r $file && ! -L $file ]] || fail "Input is not a readable regular file: ${file}. Use install --env <FILE>."
    local mode
    mode=$(stat -c '%a' -- "$file")
    (( (8#$mode & 077) == 0 )) || fail "Input file $file has unsafe permissions. Run chmod 600 first."
    DOMAIN='' CF_ZONE_TOKEN='' VLESS_UUID='' REALITY_PRIVATE_KEY='' REALITY_SHORT_ID='' TUIC_UUID='' TUIC_PASSWORD=''
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line =~ ^([A-Z_]+)=(.*)$ ]] || fail "Input file ${file}: use KEY=value format."
        key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
        case $key in DOMAIN|CF_ZONE_TOKEN|VLESS_UUID|REALITY_PRIVATE_KEY|REALITY_SHORT_ID|TUIC_UUID|TUIC_PASSWORD) ;; *) fail "Input file ${file}: unknown variable ${key}.";; esac
        if [[ $value == \"*\" || $value == \'*\' ]]; then
            value=${value:1:${#value}-2}
        elif [[ $value =~ [[:space:]\;\`\$\(\)\\\"\'] ]]; then
            fail "Input file ${file}: invalid $key format; wrap special characters in single quotes."
        fi
        [[ $value != *$'\n'* && $value != *$'\r'* ]] || fail "${file}: $key contains control characters."
        printf -v "$key" '%s' "$value"
    done < "$file"
    [[ ${#DOMAIN} -le 253 && $DOMAIN =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]] || fail "${file}: invalid DOMAIN; enter a fully qualified domain name."
    DOMAIN=${DOMAIN,,}
    [[ $CF_ZONE_TOKEN =~ ^[a-zA-Z0-9_-]{20,256}$ ]] || fail "${file}: missing or invalid CF_ZONE_TOKEN; enter a zone token."
    for key in VLESS_UUID TUIC_UUID; do
        value=${!key}
        [[ -z $value || $value =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || fail "${file}: $key is not a UUID."
    done
    [[ -z $REALITY_PRIVATE_KEY || $REALITY_PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ ]] || fail "${file}: invalid REALITY_PRIVATE_KEY format."
    [[ -z $REALITY_SHORT_ID || ( $REALITY_SHORT_ID =~ ^[a-fA-F0-9]{2,16}$ && $((${#REALITY_SHORT_ID}%2)) == 0 ) ]] || fail "${file}: REALITY_SHORT_ID must be an even-length hexadecimal string."
    [[ -z $TUIC_PASSWORD || ${#TUIC_PASSWORD} -ge 16 ]] || fail "${file}: TUIC_PASSWORD must contain at least 16 characters."
}
preflight() {
    check_os
    if [[ -f $STATE/owner ]]; then
        [[ $(cat "$STATE/domain") == "$DOMAIN" ]] || fail 'The installed domain differs; refusing to overwrite.'
        return
    fi
    local p
    if [[ -d $ROOT ]] && [[ -n $(find "$ROOT" -mindepth 1 -maxdepth 1 ! -name tls -print -quit) ]]; then
        fail "$ROOT contains files without an ownership record; refusing to overwrite."
    fi
    if [[ -d $TLS_ROOT ]] && ! tls_current >/dev/null; then fail 'Existing TLS directory has no valid prebuilt runtime; refusing to take over.'; fi
    for p in nginx sing-box; do
        ! dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -qx installed || fail "Package $p is not managed by edgekit; refusing to take over."
    done
    for p in "$XR_BIN" /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray /var/log/xray "$SB_BIN" /etc/sing-box "$SB_STATE" /etc/systemd/system/sing-box.service /lib/systemd/system/sing-box.service /etc/nginx /etc/cron.d/edgekit-acme /usr/local/bin/ek /etc/systemd/system/xray.service; do
        [[ ! -e $p && ! -L $p ]] || fail "Resource ${p} already exists; refusing to overwrite."
    done
    if [[ ( -e $ENTRY || -L $ENTRY ) && $SELF != "$ENTRY" ]]; then
        fail "Unknown entry ${ENTRY} already exists; refusing to overwrite."
    fi
    if command -v ss >/dev/null; then check_ports; fi
}
check_ports() {
    ! ss -H -lnt 'sport = :443 or sport = :9443' | grep -q . || fail 'TCP 443/9443 is already in use.'
    ! ss -H -lnu 'sport = :8443' | grep -q . || fail 'UDP 8443 is already in use.'
}
base_tools() {
    local pair cmd pkg missing=()
    for pair in ss:iproute2 curl:curl gpg:gnupg jq:jq openssl:openssl unzip:unzip tar:tar gzip:gzip crontab:cron flock:util-linux; do
        cmd=${pair%:*}; pkg=${pair#*:}
        command -v "$cmd" >/dev/null || missing+=("$pkg")
    done
    [[ -e /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
    if ((${#missing[@]})); then
        stage Tools "Install missing tools only: ${missing[*]}"
        apt-get update >>"$LOG" 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >>"$LOG" 2>&1
        printf '%s\n' "${missing[@]}" >> "$STATE/base-packages"
    fi
}
check_dns() {
    local ip records v6
    ip=$(fetch -4 https://api.ipify.org 2>>"$LOG") || fail 'Cannot detect public IPv4: public address request failed. Check outbound HTTPS connectivity.'
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Cannot detect public IPv4.'
    records=$(getent ahostsv4 "$DOMAIN" 2>>"$LOG" | awk '{print $1}' | sort -u) ||
        fail "Cannot resolve an IPv4 address for ${DOMAIN}. Check the DOMAIN value, DNS A record and server DNS resolver, then retry installation."
    [[ -n $records ]] || fail "No IPv4 address found for ${DOMAIN}. Create a DNS-only A record pointing to ${ip}, then retry installation."
    [[ $records == "$ip" ]] || fail "DOMAIN A record does not match this server's public IPv4 or is proxied. Check DNS."
    v6=$(fetch "https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=AAAA" -H 'accept: application/dns-json' 2>>"$LOG" | jq -r '.Answer[]? | select(.type==28) | .data' 2>>"$LOG") ||
        fail 'Cannot query or parse AAAA records. Check outbound HTTPS connectivity and the DNS response.'
    if [[ -n $v6 ]]; then
        local public6
        public6=$(fetch -6 https://api64.ipify.org) || fail 'AAAA record exists, but IPv6 is unavailable on this server.'
        [[ $public6 == *:* ]] || fail 'Cannot verify public IPv6 connectivity.'
        local assigned addr local6 canonical found
        assigned=$(ip -6 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}')
        while read -r addr; do
            canonical=$(getent ahostsv6 "$addr" | awk 'NR==1{print $1}') || fail 'Invalid AAAA record format.'
            [[ -n $canonical ]] || fail 'Cannot resolve AAAA record to IPv6.'
            found=0
            while read -r local6; do
                [[ -n $local6 ]] || continue
                if [[ $(getent ahostsv6 "$local6" | awk 'NR==1{print $1}') == "$canonical" ]]; then found=1; break; fi
            done <<< "$assigned"
            ((found)) || fail 'AAAA record does not point to a public IPv6 assigned to this server.'
        done <<< "$v6"
        printf '%s\n' "$v6" > "$STATE/ipv6"
    else rm -f "$STATE/ipv6"; fi
    printf '%s\n' "$ip" > "$STATE/ipv4"
}

# ---------- Official repositories and isolated Debian 12 TLS ----------
repositories() {
    install -d -m 755 /etc/apt/keyrings
    fetch https://nginx.org/keys/nginx_signing.key -o "$STATE/nginx-key"
    install -d -m 700 "$STATE/gnupg"
    gpg --homedir "$STATE/gnupg" --show-keys --with-colons "$STATE/nginx-key" | grep -q '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62' || fail 'Nginx signing key fingerprint mismatch.'
    gpg --homedir "$STATE/gnupg" --batch --yes --dearmor -o /etc/apt/keyrings/edgekit-nginx.gpg "$STATE/nginx-key"
    rm "$STATE/nginx-key"
    printf 'deb [signed-by=/etc/apt/keyrings/edgekit-nginx.gpg] https://nginx.org/packages/mainline/debian %s nginx\n' "$CODENAME" > /etc/apt/sources.list.d/edgekit-nginx.list
    printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 900\n' > /etc/apt/preferences.d/edgekit-nginx
    chmod 644 /etc/apt/keyrings/edgekit-nginx.gpg
    apt-get update >>"$LOG" 2>&1
}
# Environment is scoped to Nginx/diagnostics, never exported to system commands.
tls_debian12() (
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ $ID == debian && $VERSION_ID == 12 ]]
)
tls_env() {
    local dir=$1; shift
    env LD_LIBRARY_PATH="$dir/lib" "${TLS_ENV[@]}" "$@"
}
tls_verified() {
    local dir=$1
    [[ -f $dir/verified && -f $dir/files.sha256 && -f $dir/package.json ]] || return 1
    [[ $(cat "$dir/verified") == edgekit-conda-v1 ]] || return 1
    (cd "$dir"; sha256sum --check --status files.sha256)
}
tls_current() {
    local dir
    [[ -L $TLS_CURRENT ]] || return 1
    dir=$(readlink -f "$TLS_CURRENT") || return 1
    [[ $dir == "$TLS_PACKAGES/"* && ${dir#"$TLS_PACKAGES/"} != */* ]] || return 1
    tls_verified "$dir" || return 1
    printf '%s\n' "$dir"
}
nginx_cmd() {
    local dir
    if tls_debian12; then
        dir=$(tls_current) || fail "Isolated TLS runtime is missing or invalid: ${TLS_CURRENT}."
        tls_env "$dir" /usr/sbin/nginx "$@"
    else /usr/sbin/nginx "$@"; fi
}

tls_tools() {
    local pair missing=()
    for pair in unzip:unzip zstd:zstd readelf:binutils; do
        command -v "${pair%:*}" >/dev/null || missing+=("${pair#*:}")
    done
    if ((${#missing[@]})); then
        stage TLS-tools "Install missing extraction/ELF tools only: ${missing[*]}; uninstall keeps them."
        apt-get update >>"$LOG" 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >>"$LOG" 2>&1
        printf '%s\n' "${missing[@]}" >> "$STATE/base-packages"
    fi
}
tls_select() {
    local subdir=$1
    # Select main-label, full OpenSSL packages only; never follow latest_version to 3.6/4.x.
    jq -e --arg subdir "$subdir" '[.files[] |
        select(.version|test("^3\\.5\\.[0-9]+$")) |
        select(.attrs.subdir==$subdir and (.labels|index("main"))!=null and (.labels|index("broken"))==null) |
        select(.basename==($subdir+"/openssl-"+.version+"-"+.attrs.build+".conda")) |
        select(.attrs.build|test("^h[0-9a-f]+_[0-9]+$")) |
        select(.sha256|test("^[0-9a-f]{64}$"))] |
        sort_by([(.version|split(".")|map(tonumber)), .attrs.build_number, .upload_time]) |
        last | select(.!=null)'
}
# Recheck the actual selected artifacts, not just Conda's package-wide declarations.
tls_check() {
    local dir=$1 lib output declared floor installed_gcc
    [[ $(tls_env "$dir" "$dir/bin/openssl" version) == "OpenSSL $(jq -r .version "$dir/package.json") "* ]] || fail 'Candidate CLI version mismatch.'
    : > "$dir/elf.txt"
    for lib in libssl.so.3 libcrypto.so.3; do
        readelf -dW "$dir/lib/$lib" | grep -Fq "Library soname: [$lib]" || fail "Incompatible candidate SONAME: ${lib}."
    done
    for lib in "$dir/lib/libssl.so.3" "$dir/lib/libcrypto.so.3" "$dir/bin/openssl"; do
        readelf -h -d -V -W "$lib" >> "$dir/elf.txt"
        # Origin-relative RPATH is relocatable. Reject every unexpected search path.
        output=$(readelf -dW "$lib" | sed -n '/(RPATH)\|(RUNPATH)/s/.*\[\(.*\)\].*/\1/p')
        [[ -z $output || $output == '$ORIGIN/.' || $output == '$ORIGIN/../lib' ]] || fail 'Incompatible candidate RPATH/RUNPATH; ELF files will not be modified.'
    done
    tls_env "$dir" ldd "$dir/lib/libssl.so.3" "$dir/lib/libcrypto.so.3" "$dir/bin/openssl" /usr/sbin/nginx > "$dir/ldd.txt"
    ! grep -Eq 'not found|version .* not found' "$dir/ldd.txt" || fail 'Candidate dependencies cannot be met by this system; system libraries will not be upgraded.'
    grep -Fq "$dir/lib/libssl.so.3" "$dir/ldd.txt" && grep -Fq "$dir/lib/libcrypto.so.3" "$dir/ldd.txt" || fail 'Nginx did not load the candidate libraries.'
    jq -e '.attrs.depends | all(.[]; test("^(__glibc |ca-certificates$|libgcc )"))' "$dir/package.json" >/dev/null || fail 'Candidate has unchecked package dependencies; refusing to ignore them or upgrade automatically.'
    declared=$(jq -r '.attrs.depends[] | select(startswith("libgcc "))' "$dir/package.json")
    if grep -q 'libgcc_s' "$dir/ldd.txt"; then
        [[ $declared =~ ^libgcc\ \>\=([0-9]+)$ ]] || fail 'libgcc is loaded, but its declared constraint cannot be verified automatically.'
        floor=${BASH_REMATCH[1]}
        installed_gcc=$(dpkg-query -W -f='${Version}' libgcc-s1)
        dpkg --compare-versions "$installed_gcc" ge "$floor" || fail "Candidate requires ${declared}, which system libgcc-s1 does not satisfy; no automatic upgrade."
        printf 'libgcc declaration: %s; loaded system package: %s\n' "$declared" "$installed_gcc" > "$dir/dependencies.txt"
    else
        printf 'libgcc declaration: %s; not loaded by this exact CLI/library/Nginx dependency chain.\n' "${declared:-none}" > "$dir/dependencies.txt"
    fi
    tls_env "$dir" "$dir/bin/openssl" list -providers >> "$dir/dependencies.txt"
    tls_env "$dir" "$dir/bin/openssl" list -kem-algorithms | grep -q 'ML-KEM-768' || fail 'Candidate lacks default ML-KEM-768; this check does not replace external handshake verification.'
    tls_env "$dir" /usr/sbin/nginx -V >> "$dir/dependencies.txt" 2>&1
    tls_env "$dir" /usr/sbin/nginx -t >> "$dir/dependencies.txt" 2>&1
}
tls_prepare() (
    # Remove only transient files created by this preparation attempt.
    root_required; check_os
    [[ $DEBIAN == 12 ]] || fail 'Prebuilt TLS is only supported on Debian 12.'
    # shellcheck disable=SC2034 # Read by the EXIT cleanup trap.
    local work='' final='' created=0 dir subdir version build digest archive member selected=${1:-}
    trap 'exit 130' INT TERM
    trap 'rc=$?; trap - EXIT; [[ -z $work ]] || rm -rf "$work"; if ((rc!=0 && created)); then rm -rf "$final"; fi; exit "$rc"' EXIT
    if [[ -z $selected && ( -e $TLS_CURRENT || -L $TLS_CURRENT ) ]]; then
        dir=$(tls_current) || fail 'Existing candidate TLS is not fully verified. Diagnose it; no automatic overwrite or upgrade.'
        [[ $(jq -r .attrs.subdir "$dir/package.json") == "$(case $ARCH in amd64) echo linux-64;; arm64) echo linux-aarch64;; esac)" ]] || fail 'Saved TLS architecture mismatch.'
        tls_check "$dir" >> "$LOG" 2>&1
        printf '%s\n' "$dir"; exit 0
    fi
    case $ARCH in amd64) subdir=linux-64;; arm64) subdir=linux-aarch64;; esac
    install -d -m 755 "$TLS_ROOT" "$TLS_PACKAGES"
    work=$(mktemp -d "$TLS_ROOT/.conda-download.XXXXXX")
    if [[ -n $selected ]]; then
        jq -e '{files:[.]}' "$selected" | tls_select "$subdir" > "$work/package.json"
    else fetch https://api.anaconda.org/package/conda-forge/openssl | tls_select "$subdir" > "$work/package.json"; fi
    version=$(jq -r .version "$work/package.json"); build=$(jq -r .attrs.build "$work/package.json")
    digest=$(jq -r .sha256 "$work/package.json")
    archive=openssl-$version-$build.conda
    final=$TLS_PACKAGES/$subdir-openssl-$version-$build-${digest:0:12}
    if [[ -e $final ]]; then
        tls_verified "$final" || fail "Candidate directory ${final} is incomplete or damaged; keeping it and refusing to overwrite."
        cmp <(jq -S '{version,basename,sha256,attrs}' "$work/package.json") <(jq -S '{version,basename,sha256,attrs}' "$final/package.json") >/dev/null || fail 'Candidate metadata changed; refusing to overwrite.'
        tls_check "$final" >> "$LOG" 2>&1
        printf '%s\n' "$final"; exit 0
    fi
    # Community binaries; this HTTPS metadata SHA256 is integrity checking, not a signature.
    fetch "https://api.anaconda.org/download/conda-forge/openssl/$version/$subdir/$archive" -o "$work/package.conda"
    (cd "$work"; printf '%s  package.conda\n' "$digest" | sha256sum -c -) >> "$LOG" 2>&1
    for member in pkg info; do
        local entry
        entry=$(unzip -Z1 "$work/package.conda" | sed -n "/^$member-[a-zA-Z0-9_.-]*\.tar\.zst$/p")
        [[ -n $entry && $entry != *$'\n'* ]] || fail "Conda $member archive is missing or not unique."
        unzip -p "$work/package.conda" "$entry" > "$work/$member.tar.zst"
    done
    install -d -m 755 "$work/runtime/lib" "$work/runtime/bin"
    for member in lib/libssl.so.3 lib/libcrypto.so.3 bin/openssl; do
        tar --zstd -xOf "$work/pkg.tar.zst" "$member" > "$work/runtime/$member"
        [[ -s $work/runtime/$member ]] || fail "Candidate is missing ${member}."
        chmod 755 "$work/runtime/$member"
    done
    tar --zstd -xOf "$work/info.tar.zst" info/licenses/LICENSE.txt > "$work/runtime/LICENSE.txt"
    tar --zstd -xOf "$work/info.tar.zst" info/index.json > "$work/runtime/index.json"
    jq -e --arg version "$version" --arg build "$build" --arg subdir "$subdir" '.name=="openssl" and .version==$version and .build==$build and .subdir==$subdir' "$work/runtime/index.json" >/dev/null
    jq -e --slurpfile selected "$work/package.json" '(.depends|sort)==($selected[0].attrs.depends|sort) and .build_number==$selected[0].attrs.build_number' "$work/runtime/index.json" >/dev/null
    jq --arg url "https://api.anaconda.org/download/conda-forge/openssl/$version/$subdir/$archive" '. + {edgekit_source:$url,edgekit_integrity:"HTTPS channel metadata SHA256; no publisher signature verification"}' "$work/package.json" > "$work/runtime/package.json"
    # shellcheck disable=SC2034 # The trap removes an unverified final directory.
    mv "$work/runtime" "$final"
    # shellcheck disable=SC2034 # Read by the EXIT trap.
    created=1
    tls_check "$final" >> "$LOG" 2>&1
    (cd "$final"; sha256sum lib/libssl.so.3 lib/libcrypto.so.3 bin/openssl LICENSE.txt index.json package.json > files.sha256)
    printf 'edgekit-conda-v1\n' > "$final/verified"
    chmod 644 "$final"/*.txt "$final"/*.json "$final/files.sha256" "$final/verified"
    printf '%s\n' "$final"
)
install_tls() {
    [[ $DEBIAN == 12 ]] || return 0
    stage Isolated-TLS 'Install or reuse verified conda-forge OpenSSL 3.5 LTS.'
    tls_tools
    local dir
    dir=$(/bin/bash "$ENTRY" _tls-prepare) || fail "Prebuilt TLS preparation failed. Log: $STATE/tls-prepare.log."
    tls_configure "$dir"
}
tls_configure() (
    local dir=$1
    trap 'exit 130' INT TERM
    trap 'rm -f "$TLS_ROOT/.current.$$" "$TLS_DROPIN.new"' EXIT
    tls_verified "$dir" || fail 'Prebuilt TLS is not verified; cannot configure Nginx.'
    install -d -m 755 "${TLS_DROPIN%/*}"
    {
        printf '[Service]\nEnvironment="LD_LIBRARY_PATH=%s/lib"\n' "$dir"
        printf 'Environment="%s"\n' "${TLS_ENV[@]}"
    } > "$TLS_DROPIN.new"
    chmod 644 "$TLS_DROPIN.new"
    ln -s "$dir" "$TLS_ROOT/.current.$$"
    mv -Tf "$TLS_ROOT/.current.$$" "$TLS_CURRENT"
    mv -f "$TLS_DROPIN.new" "$TLS_DROPIN"

)

# ---------- Xray versions, credentials and configuration ----------
xray_target() {
    local selection=$1
    case $selection in latest|release) ;; *) fail 'Xray selection must be latest or release.';; esac
    fetch 'https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100' |
        jq -ec --arg selection "$selection" '[.[] | select(.draft==false) |
            select($selection=="latest" or .prerelease==false)] | sort_by(.published_at) | last |
            select((.tag_name | type=="string" and test("^v[0-9]+([.][0-9]+)+$")) and (.prerelease | type=="boolean")) |
            {tag_name,prerelease}' ||
        fail "No Xray $selection version available. Check the network or GitHub API rate limit."
}
singbox_target() {
    fetch https://api.github.com/repos/SagerNet/sing-box/releases/latest |
        jq -er 'select(.draft==false and .prerelease==false) | .tag_name | select(test("^v[0-9]+[.][0-9]+[.][0-9]+$"))' ||
        fail 'Cannot fetch the latest stable sing-box release; no pre-release fallback.'
}
xray_version() { "$XR_BIN" version 2>/dev/null | awk 'NR==1{print $2}'; }
singbox_version() { "$SB_BIN" version 2>/dev/null | awk 'NR==1{print $3}'; }
xray_release_type() {
    jq -er --arg tag "v$1" 'select(.tag==$tag) |
        if .prerelease==true then "pre-release" elif .prerelease==false then "release" else empty end' \
        "$STATE/xray-release.json" 2>/dev/null
}
xray_refresh_type() (
    local target=$1 prerelease=$2 tmp=''
    [[ -f $STATE/xray-release.json ]] || return 0
    jq -e --arg target "$target" '.tag==$target' "$STATE/xray-release.json" >/dev/null || fail 'Installed Xray release record does not match the running version.'
    jq -e --argjson flag "$prerelease" '.prerelease==$flag' "$STATE/xray-release.json" >/dev/null && return 0
    trap '[[ -z $tmp ]] || rm -f "$tmp"' EXIT
    tmp=$(mktemp "$STATE/xray-release.XXXXXX")
    jq --argjson flag "$prerelease" '.prerelease=$flag' "$STATE/xray-release.json" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE/xray-release.json"
)
# Both proxies use official GitHub assets; no vendor installer or proxy APT source.
proxy_install() (
    root_required; check_os
    local component=$1 target=$2 repo asset member bin work='' atomic='' digest actual
    trap 'rc=$?; trap - EXIT; [[ -z $work ]] || rm -rf "$work"; [[ -z $atomic ]] || rm -f "$atomic"; exit "$rc"' EXIT
    trap 'exit 130' INT TERM
    [[ $target =~ ^v[0-9]+(\.[0-9]+)+$ ]] || fail 'Invalid release tag format.'
    case $component in
        xray)
            repo=XTLS/Xray-core; bin=$XR_BIN; member=xray
            case $ARCH in amd64) asset=Xray-linux-64.zip;; arm64) asset=Xray-linux-arm64-v8a.zip;; esac;;
        sing-box)
            repo=SagerNet/sing-box; bin=$SB_BIN
            asset=sing-box-${target#v}-linux-$ARCH.tar.gz
            member=sing-box-${target#v}-linux-$ARCH/sing-box;;
        *) fail 'Unknown proxy component.';;
    esac
    work=$(mktemp -d "$STATE/$component-download.XXXXXX")
    fetch "https://api.github.com/repos/$repo/releases/tags/$target" > "$work/release.json"
    jq -e --arg target "$target" --arg component "$component" '.tag_name==$target and .draft==false and (.prerelease | type=="boolean") and ($component=="xray" or .prerelease==false)' "$work/release.json" >/dev/null || fail 'Release metadata does not match the selected version or type.'
    # Require one exact official asset and its GitHub SHA256; never accept unchecked files.
    jq -e --arg name "$asset" --arg repo "$repo" --arg target "$target" '
        [.assets[] | select(.name==$name and .state=="uploaded") |
        select(.browser_download_url==("https://github.com/"+$repo+"/releases/download/"+$target+"/"+$name))] |
        select(length==1) | .[0] | select(.digest | test("^sha256:[0-9a-f]{64}$"))' "$work/release.json" > "$work/asset.json" ||
        fail "${component} architecture asset or SHA256 is missing; installation stopped."
    digest=$(jq -r '.digest | sub("^sha256:";"")' "$work/asset.json")
    fetch "https://github.com/$repo/releases/download/$target/$asset" -o "$work/archive"
    (cd "$work"; printf '%s  archive\n' "$digest" | sha256sum --check --status) || fail "${component} download SHA256 mismatch."
    if [[ $component == xray ]]; then
        unzip -p "$work/archive" "$member" > "$work/binary"
    else tar -xzOf "$work/archive" "$member" > "$work/binary"; fi
    chmod 755 "$work/binary"
    if [[ $component == xray ]]; then actual=$("$work/binary" version | awk 'NR==1{print $2}')
    else actual=$("$work/binary" version | awk 'NR==1{print $3}'); fi
    [[ $actual == "${target#v}" ]] || fail "${component} candidate binary version mismatch."
    jq --arg component "$component" --arg repo "$repo" --arg tag "$target" --slurpfile release "$work/release.json" \
        '{component:$component,repository:$repo,tag:$tag,prerelease:$release[0].prerelease,name,url:.browser_download_url,sha256:(.digest|sub("^sha256:";"")),integrity:"GitHub HTTPS asset SHA256; no publisher signature verification"}' "$work/asset.json" > "$work/record.json"
    # Same-directory rename replaces even a running binary without truncating it.
    atomic=$(mktemp "${bin}.XXXXXX")
    install -m 755 -o root -g root "$work/binary" "$atomic"
    mv -f "$atomic" "$bin"; atomic=''
    mv -f "$work/record.json" "$STATE/$component-release.json"
)
proxy_services() {
    # Dedicated unprivileged accounts; executable/config directories remain root-owned.
    systemd-sysusers - <<'EOF'
u xray - "edgekit Xray" /var/empty
u sing-box - "edgekit sing-box" /var/empty
EOF
    local user
    for user in xray sing-box; do
        [[ $(id -u "$user") != 0 && $(id -g "$user") != 0 ]] || fail "Service account ${user} must not use root UID/GID."
    done
    install -d -m 750 -o root -g xray "$XR_HOME"
    install -d -m 750 -o root -g sing-box "${SB_CONFIG%/*}"
    install -d -m 750 -o sing-box -g sing-box "$SB_STATE"
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=edgekit Xray
After=network.target nss-lookup.target
[Service]
User=xray
Group=xray
ExecStart=$XR_BIN run -confdir $XR
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
UMask=0077
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=edgekit sing-box
After=network.target nss-lookup.target
[Service]
User=sing-box
Group=sing-box
ExecStart=$SB_BIN -D $SB_STATE -C ${SB_CONFIG%/*} run
NoNewPrivileges=yes
UMask=0077
Restart=on-failure
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/xray.service /etc/systemd/system/sing-box.service
}
credentials() {
    [[ ! -f $STATE/client.json ]] || return 0
    local pair private public
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    TUIC_UUID=${TUIC_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    REALITY_SHORT_ID=${REALITY_SHORT_ID:-$(openssl rand -hex 8)}
    TUIC_PASSWORD=${TUIC_PASSWORD:-$(openssl rand -hex 24)}
    if [[ -n $REALITY_PRIVATE_KEY ]]; then pair=$("$XR_BIN" x25519 -i "$REALITY_PRIVATE_KEY"); else pair=$("$XR_BIN" x25519); fi
    private=$(printf '%s\n' "$pair" | awk '/PrivateKey:|Private key:/{print $NF}')
    public=$(printf '%s\n' "$pair" | awk '/Password|PublicKey:|Public key:/{print $NF}')
    [[ -n $private && -n $public ]] || fail 'Cannot generate or derive REALITY keys.'
    jq -n --arg domain "$DOMAIN" --arg vless "$VLESS_UUID" --arg private "$private" --arg public "$public" --arg sid "$REALITY_SHORT_ID" --arg tuic "$TUIC_UUID" --arg password "$TUIC_PASSWORD" '{domain:$domain,vless_uuid:$vless,reality_private:$private,reality_public:$public,short_id:$sid,tuic_uuid:$tuic,tuic_password:$password}' > "$STATE/client.json"
    chmod 600 "$STATE/client.json"
    jq -r '"vless://\(.vless_uuid)@\(.domain):443?encryption=none&security=reality&sni=\(.domain)&fp=chrome&pbk=\(.reality_public)&sid=\(.short_id)&type=tcp&flow=xtls-rprx-vision#edgekit", "tuic://\(.tuic_uuid):\(.tuic_password|@uri)@\(.domain):8443?congestion_control=bbr&alpn=h3&sni=\(.domain)#edgekit"' "$STATE/client.json" > "$STATE/client-links.txt"
    chmod 600 "$STATE/client-links.txt"
}
xray_config() {
    local listen=0.0.0.0
    [[ ! -s $STATE/ipv6 ]] || listen=::
    # The service can read its binary/config and write the log, not replace the binary.
    install -d -m 750 -o root -g xray "$XR_HOME" "$XR"
    # Replace only the JSON files in our managed configuration directory.
    rm -f "$XR"/*.json
    [[ -e $XR_HOME/error.log ]] || touch "$XR_HOME/error.log"
    chown xray:xray "$XR_HOME/error.log"; chmod 640 "$XR_HOME/error.log"
    jq -n --arg error "$XR_HOME/error.log" '{log:{error:$error,loglevel:"warning",dnsLog:false}}' > "$XR/00_log.json"
    cat > "$XR/11_dns.json" <<'EOF'
{
  "dns": {
    "servers": [
      "localhost"
    ]
  }
}
EOF
    jq --arg listen "$listen" '{inbounds:[{tag:"vless-reality",listen:$listen,port:443,protocol:"vless",settings:{clients:[{id:.vless_uuid,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"raw",security:"reality",realitySettings:{show:false,target:"127.0.0.1:9443",xver:1,serverNames:[.domain],privateKey:.reality_private,shortIds:[.short_id]}}}]}' "$STATE/client.json" > "$XR/02_vless_reality_inbound.json"
    cat > "$XR/z_direct_outbound.json" <<'EOF'
{
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "z_direct_outbound",
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIP"
        }
      }
    }
  ]
}
EOF
    chown root:xray "$XR"/*.json; chmod 640 "$XR"/*.json
}
static_site() (
    local work member
    work=$(mktemp -d "$STATE/site.XXXXXX") || fail 'Cannot create the static site download directory.'
    trap 'rm -rf -- "$work"' EXIT
    fetch https://raw.githubusercontent.com/xgungnir/edgekit/master/misc/html.zip -o "$work/html.zip" || fail 'Static site download failed.'
    unzip -Z1 "$work/html.zip" > "$work/members" || fail 'Invalid static site ZIP archive.'
    install -d -m 755 "$work/site"
    while IFS= read -r member || [[ -n $member ]]; do
        # Stream each member into a regular file; never follow ZIP symlinks.
        [[ -n $member && $member != /* && $member != *[!a-zA-Z0-9_./-]* ]] || fail 'Invalid static site archive path.'
        case "/${member%/}/" in */../*|*/./*|*//*) fail 'Unsafe static site archive path.';; esac
        if [[ $member == */ ]]; then
            install -d -m 755 "$work/site/${member%/}"
        else
            install -d -m 755 "$(dirname -- "$work/site/$member")"
            unzip -p "$work/html.zip" "$member" > "$work/site/$member" || fail 'Static site ZIP extraction failed.'
            chmod 644 "$work/site/$member"
        fi
    done < "$work/members"
    [[ -s $work/site/index.html ]] || fail 'Static site archive must contain a nonempty index.html at its root.'
    install -d -m 755 "$ROOT/www"
    cp -Rp "$work/site/." "$ROOT/www/"
)
nginx_config() {
    static_site
    install -d -m 755 /etc/nginx/edgekit.d
    [[ ! -f /etc/nginx/conf.d/default.conf ]] || mv /etc/nginx/conf.d/default.conf "$STATE/nginx-default.conf"
    cat > /etc/nginx/conf.d/edgekit.conf <<EOF
log_format edgekit '\$remote_addr \$server_name \$request \$status \$ssl_protocol \$ssl_curve';
server {
    listen 127.0.0.1:9443 ssl proxy_protocol;
    http2 on;
    server_name $DOMAIN;
    ssl_certificate $ROOT/certs/$DOMAIN/fullchain.pem;
    ssl_certificate_key $ROOT/certs/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve X25519MLKEM768:X25519:prime256v1;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    access_log /var/log/nginx/edgekit-access.log edgekit;
    root $ROOT/www;
    location / { try_files \$uri \$uri/ =404; }
    include /etc/nginx/edgekit.d/*.conf;
}
EOF
}
singbox_config() {
    local listen=0.0.0.0
    [[ ! -s $STATE/ipv6 ]] || listen=::
    install -d -m 750 "${SB_CONFIG%/*}"
    install -d -m 750 -o root -g sing-box "${SB_LOG%/*}"
    [[ -e $SB_LOG ]] || touch "$SB_LOG"
    chown sing-box:sing-box "$SB_LOG"; chmod 640 "$SB_LOG"
    jq --arg output "$SB_LOG" --arg listen "$listen" --arg cert "$ROOT/certs/$DOMAIN/fullchain.pem" --arg key "$ROOT/certs/$DOMAIN/privkey.pem" '{log:{level:"warn",output:$output},inbounds:[{type:"tuic",tag:"tuic",listen:$listen,listen_port:8443,users:[{uuid:.tuic_uuid,password:.tuic_password}],congestion_control:"bbr",zero_rtt_handshake:false,auth_timeout:"3s",heartbeat:"10s",tls:{enabled:true,server_name:.domain,alpn:["h3"],certificate_path:$cert,key_path:$key}}],dns:{servers:[{type:"local",tag:"local"}]},outbounds:[{type:"direct",tag:"direct",domain_resolver:{server:"local",strategy:"prefer_ipv4"}}]}' "$STATE/client.json" > "$SB_CONFIG"
    chown root:sing-box "${SB_CONFIG%/*}" "$SB_CONFIG"
    chmod 640 "$SB_CONFIG"
}
check_configs() {
    nginx_cmd -t >>"$LOG" 2>&1
    "$XR_BIN" run -test -confdir "$XR" >>"$LOG" 2>&1
    "$SB_BIN" check -c "$SB_CONFIG" >>"$LOG" 2>&1
    systemctl cat xray | grep -q -- "-confdir $XR" || fail 'Xray is not using the configuration directory.'
}
verify_services() {
    local s
    for s in nginx xray sing-box; do
        systemctl is-active --quiet "$s"
        systemctl is-enabled --quiet "$s"
    done
}

# ---------- ACME: one deploy hook and one daily non-forced check ----------
acme() { "$ROOT/acme.sh/acme.sh" --home "$ROOT/acme.sh" --config-home "$ROOT/acme.sh" --cert-home "$ROOT/acme.sh" "$@"; }
certificate() {
    local ca=$1 tmp
    if [[ -f $STATE/acme-ca && $(cat "$STATE/acme-ca") != "$ca" ]]; then fail 'Existing ACME state uses a different CA. Retry with the same mode, or uninstall before reinstalling.'; fi
    printf '%s\n' "$ca" > "$STATE/acme-ca"
    if [[ ! -x $ROOT/acme.sh/acme.sh ]]; then
        tmp=$(mktemp -d "$STATE/acme.XXXXXX")
        fetch https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz -o "$tmp/acme.tar.gz"
        tar xzf "$tmp/acme.tar.gz" -C "$tmp"
        (cd "$tmp/acme.sh-master"; ./acme.sh --install --home "$ROOT/acme.sh" --config-home "$ROOT/acme.sh" --cert-home "$ROOT/acme.sh" --nocron --noprofile) >>"$LOG" 2>&1
        rm -rf "$tmp"
    fi
    chmod 700 "$ROOT/acme.sh"
    export CF_Token=$CF_ZONE_TOKEN
    acme --set-default-ca --server "$ca" >>"$LOG" 2>&1
    acme --register-account --server "$ca" >>"$LOG" 2>&1
    if [[ ! -f $ROOT/acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer ]]; then
        acme --issue --server "$ca" --dns dns_cf -d "$DOMAIN" --keylength ec-256 >>"$LOG" 2>&1
    fi
    install -d -m 700 "$ROOT/certs" "$ROOT/certs/$DOMAIN"
    # During first install only permissions are changed; services start after config validation.
    acme --install-cert -d "$DOMAIN" --ecc --fullchain-file "$ROOT/certs/$DOMAIN/fullchain.pem" --key-file "$ROOT/certs/$DOMAIN/privkey.pem" --reloadcmd "/bin/bash $ENTRY deploy-cert" >>"$LOG" 2>&1
    unset CF_Token CF_ZONE_TOKEN
    find "$ROOT/acme.sh" -type f -exec chmod 600 {} +
    chmod 700 "$ROOT/acme.sh/acme.sh"
}
deploy_cert() {
    root_required
    local domain
    domain=$(cat "$STATE/domain")
    chown root:sing-box "$ROOT/certs" "$ROOT/certs/$domain" "$ROOT/certs/$domain/privkey.pem"
    chmod 750 "$ROOT/certs" "$ROOT/certs/$domain"
    chmod 640 "$ROOT/certs/$domain/privkey.pem"
    chmod 644 "$ROOT/certs/$domain/fullchain.pem"
    if installed; then
        start_log deploy-cert
        stage Certificate-deployment 'Check configuration and load the certificate.'
        if /bin/bash "$ENTRY" _load-cert-services >>"$LOG" 2>&1; then
            rm -rf "$STATE/cert-good"
            cp -a "$ROOT/certs/$domain" "$STATE/cert-good"
            date -Ins > "$STATE/cert-deployed"
        else
            if [[ -d $STATE/cert-good ]]; then
                cp -a "$STATE/cert-good/." "$ROOT/certs/$domain/"
                /bin/bash "$ENTRY" _load-cert-services >>"$LOG" 2>&1 || fail "Certificate deployment and recovery failed. Check ${LOG}."
                fail "Certificate deployment failed; restored the previous certificate and services. Log: ${LOG}."
            fi
            fail "Certificate deployment failed; no certificate available for recovery. Log: ${LOG}."
        fi
    else
        validate_certificate "$domain"
    fi
}
validate_certificate() {
    local domain=$1
    openssl x509 -in "$ROOT/certs/$domain/fullchain.pem" -noout -checkend 0 -checkhost "$domain" >/dev/null
    [[ $(openssl x509 -in "$ROOT/certs/$domain/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum) == "$(openssl pkey -in "$ROOT/certs/$domain/privkey.pem" -pubout -outform DER | sha256sum)" ]]
}
renew() {
    root_required; require_install; start_log renew
    exec 9>"$STATE/renew.lock"; flock -n 9 || fail 'Another renewal check is running.'
    local before after deployed_before deployed_after
    before=$(sha256sum "$ROOT/certs/$(cat "$STATE/domain")/fullchain.pem")
    deployed_before=$(cat "$STATE/cert-deployed" 2>/dev/null || true)
    stage Renewal 'Run the same acme.sh --cron check as the daily 01:30 task (no forced issuance).'
    acme --cron >>"$LOG" 2>&1
    after=$(sha256sum "$ROOT/certs/$(cat "$STATE/domain")/fullchain.pem")
    deployed_after=$(cat "$STATE/cert-deployed" 2>/dev/null || true)
    if [[ $before != "$after" ]]; then
        say 'Success: certificate updated and deployment hook executed.'
    elif [[ $deployed_before != "$deployed_after" ]]; then
        say 'Success: retried certificate deployment and loaded services; no new issuance needed.'
    else say 'No renewal needed: certificate unchanged; services were not reloaded.'; fi
    date -Is > "$STATE/renew-checked"
}

# ---------- Install, transactional component updates and uninstall ----------
firewall() {
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        local rule family source present
        for family in ipv4 ipv6; do
            [[ $family != ipv6 || -s $STATE/ipv6 ]] || continue
            source=0.0.0.0/0; [[ $family != ipv6 ]] || source=::/0
            for rule in 443/tcp 8443/udp; do
                present=0
                if [[ $family == ipv4 ]]; then
                    ufw status | grep -Eq "^${rule}[[:space:]]+ALLOW[[:space:]]+Anywhere" && present=1
                else
                    ufw status | grep -Eq "^${rule} \(v6\)[[:space:]]+ALLOW[[:space:]]+Anywhere \(v6\)" && present=1
                fi
                if ((present == 0)); then
                    ufw allow proto "${rule#*/}" from "$source" to any port "${rule%/*}" comment edgekit >>"$LOG" 2>&1
                    printf '%s %s %s\n' "$family" "${rule%/*}" "${rule#*/}" >> "$STATE/ufw-added"
                fi
            done
        done
    fi
}
firewall_remove() {
    local family port proto source
    [[ -f $STATE/ufw-added ]] || return 0
    while read -r family port proto; do
        [[ $family == ipv4 || $family == ipv6 ]] || fail 'Invalid application firewall record format.'
        source=0.0.0.0/0; [[ $family != ipv6 ]] || source=::/0
        ufw --force delete allow proto "$proto" from "$source" to any port "$port" >>"$LOG" 2>&1
    done < "$STATE/ufw-added"
    rm -f "$STATE/ufw-added"
}
# Keep reusable ACME state private after a failed install; stop incomplete services.
# Retrying the same env resumes the owned installation; uninstall can also clean it.
install_failed() {
    local rc=$? s load_state
    if ((rc != 0)) && ! installed; then
        for s in nginx xray sing-box; do
            load_state=$(systemctl show "$s" -p LoadState --value 2>/dev/null) || load_state=''
            [[ -n $load_state && $load_state != not-found ]] || continue
            systemctl stop "$s" >>"$LOG" 2>&1 || true
        done
        rm -f /etc/cron.d/edgekit-acme
        if [[ -f $STATE/ufw-added ]]; then
            firewall_remove || say "Application firewall recovery failed. Check ${LOG}." >&3
        fi
        say "Installation incomplete: cleanup attempted for existing application services and added firewall rules. Private logs/ACME state remain in ${ROOT}; fix the issue and retry or run uninstall." >&3
    fi
    return "$rc"
}
install_all() {
    root_required
    STAGE=Input
    local envfile='' ca=letsencrypt fresh=0
    local args=("$@")
    [[ -f $STATE/owner ]] || fresh=1
    while (($#)); do
        case $1 in --env) [[ $# -ge 2 ]] || fail '--env requires a path.'; envfile=$2; shift 2;; --staging) ca=letsencrypt_test; shift;; *) fail 'Usage: install [--env <FILE>] [--staging]';; esac
    done
    if installed; then say 'Already installed: reuse existing configuration and credentials; no automatic upgrade.'; status; return; fi
    prepare_entry install "${args[@]}"
    envfile=${envfile:-$DEFAULT_ENV}
    if [[ $envfile == "$DEFAULT_ENV" && ! -e $envfile && ! -L $envfile ]]; then
        create_default_env
        fail "Created ${DEFAULT_ENV} (0600). Fill in DOMAIN and CF_ZONE_TOKEN, then run ek."
    fi
    read_env "$envfile"
    preflight
    [[ $ca != letsencrypt_test ]] || say 'Test mode: staging certificates are not publicly trusted and do not count as production verification.'
    say "Architecture: ${ARCH}; domain: ${DOMAIN}; Xray TCP 443, Nginx loopback 9443, TUIC UDP 8443; credentials hidden."
    install -d -m 755 "$ROOT"
    start_log install
    exec 8>"$STATE/operation.lock"; flock -n 8 || fail 'Another management operation is running.'
    if [[ ! -f $STATE/owner ]]; then
        touch "$STATE/owner"
        printf '%s\n' "$DOMAIN" > "$STATE/domain"
        if dpkg-query -W -f='${db:Status-Status}' cron 2>/dev/null | grep -qx installed; then
            systemctl is-enabled cron > "$STATE/cron-enabled-before" 2>/dev/null || true
            systemctl is-active cron > "$STATE/cron-active-before" 2>/dev/null || true
        fi
        dpkg-query -W -f='${binary:Package} ${Version}\n' > "$STATE/packages-before" 2>/dev/null
        for s in nginx xray sing-box cron; do systemctl is-enabled "$s" >>"$STATE/services-before" 2>/dev/null || true; done
        for s in nginx xray sing-box; do id "$s" >/dev/null 2>&1 || printf '%s\n' "$s" >> "$STATE/users-new"; done
    fi
    trap install_failed EXIT
    trap 'exit 130' INT TERM
    stage Preflight 'Install missing tools and check DNS and public addresses.'
    base_tools
    if ((fresh)); then check_ports; fi
    check_dns
    stage Repositories 'Verify the Nginx signing key and configure the mainline APT repository.'
    repositories
    stage Components 'Install official Nginx mainline.'
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nginx >>"$LOG" 2>&1
    systemctl stop nginx >>"$LOG" 2>&1
    install_tls
    stage Proxies 'Download the latest Xray release and stable sing-box release from GitHub; verify SHA256.'
    proxy_services
    local target
    if [[ ! -x $XR_BIN || ! -f $STATE/xray-release.json ]]; then
        target=$(xray_target latest | jq -er .tag_name)
        proxy_install xray "$target"
    else [[ v$(xray_version) == "$(jq -r .tag "$STATE/xray-release.json")" ]] || fail 'Existing Xray binary does not match its installation record.'; fi
    if [[ ! -x $SB_BIN || ! -f $STATE/sing-box-release.json ]]; then
        target=$(singbox_target)
        proxy_install sing-box "$target"
    else [[ v$(singbox_version) == "$(jq -r .tag "$STATE/sing-box-release.json")" ]] || fail 'Existing sing-box binary does not match its installation record.'; fi
    credentials
    stage ACME "Wait for Let's Encrypt Cloudflare DNS-01; no email registration, automatic zone lookup."
    certificate "$ca"
    stage Configuration 'Write Xray configuration files, loopback Nginx and TUIC configuration.'
    xray_config; nginx_config; singbox_config
    systemctl daemon-reload
    check_configs
    stage Startup 'Enable services and application firewall rules.'
    firewall
    systemctl enable --now cron >>"$LOG" 2>&1
    systemctl enable nginx xray sing-box >>"$LOG" 2>&1
    systemctl restart nginx xray sing-box >>"$LOG" 2>&1
    verify_services
    cat > /etc/cron.d/edgekit-acme <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 1 * * * root $ENTRY renew >> $STATE/acme-renew.log 2>&1
EOF
    chmod 644 /etc/cron.d/edgekit-acme
    rm -rf "$STATE/cert-good"
    cp -a "$ROOT/certs/$DOMAIN" "$STATE/cert-good"
    touch "$STATE/installed"
    apt-cache policy nginx > "$STATE/package-origins"
    say 'Success: configuration, running services and startup are verified; public clients and PQ handshakes still need external verification.'
    say "Client settings: $STATE/client.json and client-links.txt (root only). Allow TCP 443 and UDP 8443 in the cloud firewall."
    status
    cleanup_bootstrap
    say "Run ek to manage this installation. You may delete ${DEFAULT_ENV}; management and renewal do not need the original input."
}
proxy_check() {
    if [[ $1 == xray ]]; then "$XR_BIN" run -test -confdir "$XR"
    else "$SB_BIN" check -c "$SB_CONFIG"; fi
}
update_proxy() {
    local component=$1 selection=$2 yes=${3:-} bin current target backup metadata prerelease current_type target_type
    root_required; require_install; check_os; start_log "update-$component"
    exec 8>"$STATE/operation.lock"; flock -n 8 || fail 'Another management operation is running.'
    systemctl is-active --quiet "$component" || fail "${component} service is unhealthy. Diagnose it first."
    if [[ $component == xray ]]; then
        if [[ $selection == latest ]]; then stage Versions 'Checking the latest published Xray version.'
        else stage Versions 'Checking the latest release Xray version (excluding pre-release).'; fi
        bin=$XR_BIN; current=$(xray_version); metadata=$(xray_target "$selection")
        target=$(jq -er .tag_name <<< "$metadata")
        prerelease=$(jq -r .prerelease <<< "$metadata")
        current_type=$(xray_release_type "$current" || true)
        target_type=release; [[ $prerelease != true ]] || target_type=pre-release
        say "Current: ${current}${current_type:+ ($current_type)}"
        say "Target:  ${target#v} (${target_type})"
    else
        stage Versions 'Query the latest stable sing-box release from GitHub.'
        bin=$SB_BIN; current=$(singbox_version); target=$(singbox_target)
        say "${component} current: ${current}; target: ${target}."
    fi
    [[ -x $bin ]] || fail "${component} binary is missing; no automatic initialization."
    if [[ $current == "${target#v}" ]]; then
        [[ $component != xray ]] || xray_refresh_type "$target" "$prerelease"
        say 'Already up to date.'; return
    fi
    if [[ $component == xray ]] && jq -en --arg current "$current" --arg target "${target#v}" \
        '($target | split(".") | map(tonumber)) < ($current | split(".") | map(tonumber))' >/dev/null; then
        say 'The target Xray version is older; this operation will downgrade Xray.'
    fi
    [[ $yes == --yes ]] || { confirm || { say 'Cancelled.'; return; }; }
    backup=$(mktemp -d "$STATE/$component-update.XXXXXX")
    cp -p "$bin" "$backup/binary"
    cp -p "$STATE/$component-release.json" "$backup/release.json"
    stage Proxy-update "Install the selected ${component} release; keep configuration, service definitions and credentials."
    if /bin/bash "$ENTRY" _proxy-install "$component" "$target" >>"$LOG" 2>&1 &&
        proxy_check "$component" >>"$LOG" 2>&1 && systemctl restart "$component" && systemctl is-active --quiet "$component"; then
        rm -rf "$backup"
        say "Success: ${component} switched to ${target}; configuration and credentials kept."
    else
        # Rename a new inode; the failed candidate may still be running.
        install -m 755 -o root -g root "$backup/binary" "${bin}.restore"
        mv -f "${bin}.restore" "$bin"
        cp -p "$backup/release.json" "$STATE/$component-release.json"
        if ! systemctl restart "$component" || ! systemctl is-active --quiet "$component"; then
            fail "Recovery failed; backup kept at ${backup}. Log: ${LOG}."
        fi
        rm -rf "$backup"
        fail "${component} update failed; restored previous version ${current}, service is running. Log: ${LOG}."
    fi
}
update_xray() {
    local selection=latest yes=''
    case ${1:-} in latest|release) selection=$1; shift;; esac
    if [[ ${1:-} == --yes ]]; then yes=--yes; shift; fi
    [[ $# == 0 ]] || fail 'Usage: update-xray [latest|release] [--yes].'
    update_proxy xray "$selection" "$yes"
}
update_singbox() { update_proxy sing-box stable "${1:-}"; }

# Read version metadata without executing the installed or downloaded script.
edgekit_file_version() {
    awk '
        /^[[:space:]]*(export[[:space:]]+)?EDGEKIT_VERSION[[:space:]]*=/ {
            count++
            if ($0 !~ /^EDGEKIT_VERSION=(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) invalid=1
            sub(/^EDGEKIT_VERSION=/, ""); version=$0
        }
        END { if (count!=1 || invalid) exit 1; print version }
    ' "$1"
}
edgekit_version_newer() {
    local i a b LC_ALL=C
    local target_parts current_parts
    IFS=. read -r -a target_parts <<< "$1"
    IFS=. read -r -a current_parts <<< "$2"
    for i in 0 1 2; do
        a=${target_parts[i]}; b=${current_parts[i]}
        ((${#a} == ${#b})) || { ((${#a} > ${#b})); return; }
        [[ $a == "$b" ]] || { [[ $a > $b ]]; return; }
    done
    return 1
}
edgekit_update_tools() {
    local pair cmd pkg missing=() packages=()
    for pair in curl:curl jq:jq flock:util-linux awk:mawk cmp:diffutils mktemp:coreutils install:coreutils mv:coreutils cp:coreutils rm:coreutils stat:coreutils timeout:coreutils; do
        cmd=${pair%:*}; pkg=${pair#*:}
        if ! command -v "$cmd" >/dev/null; then
            missing+=("$cmd")
            case " ${packages[*]} " in *" $pkg "*) ;; *) packages+=("$pkg");; esac
        fi
    done
    ((${#missing[@]} == 0)) || fail "Missing update tools: ${missing[*]}. Install the required Debian packages and retry: apt-get install ${packages[*]}"
}
edgekit_script_check() {
    local reported
    /bin/bash -n "$1" >>"$LOG" 2>&1 || return 1
    reported=$(timeout 10 /bin/bash "$1" --version 2>>"$LOG") || return 1
    [[ $reported == "edgekit $2" ]] || return 1
    timeout 10 /bin/bash "$1" --help >>"$LOG" 2>&1
}
update_edgekit() (
    local yes=${1:-} current target version release work='' atomic='' replaced=0 keep=0
    [[ $# -le 1 && ( -z $yes || $yes == --yes ) ]] || fail 'Usage: update-edgekit [--yes].'
    root_required; require_install; check_os
    edgekit_update_tools
    [[ -f $ENTRY && -x $ENTRY && ! -L $ENTRY && $(stat -c '%u:%g:%a' "$ENTRY") == 0:0:755 ]] ||
        fail "Installed entry ${ENTRY} must be a root-owned regular file with mode 0755."
    start_log update-edgekit
    exec 8>"$STATE/operation.lock"; flock -n 8 || fail 'Another management operation is running.'
    exec 9>"$STATE/renew.lock"; flock -n 9 || fail 'A renewal check is running; retry the update later.'
    current=$(edgekit_file_version "$ENTRY") || fail 'Cannot read the installed edgekit version.'
    stage Versions 'Query the latest stable edgekit release from GitHub.'
    release=$(fetch https://api.github.com/repos/xgungnir/edgekit/releases/latest) || fail 'Cannot query the latest edgekit release.'
    target=$(jq -er 'select(.draft==false and .prerelease==false) | .tag_name |
        select(type=="string" and test("^v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$"))' <<< "$release") ||
        fail 'Invalid stable edgekit release metadata.'
    version=${target#v}
    say "edgekit current: ${current}; target: ${target}."
    [[ $current != "$version" ]] || { say 'Already up to date.'; return 0; }
    edgekit_version_newer "$version" "$current" || { say 'Installed edgekit is newer than the latest release; no downgrade performed.'; return 0; }
    say 'Replace the ek script only; keep component binaries, configuration, certificates and website. No service restart.'
    [[ $yes == --yes ]] || { confirm || { say 'Cancelled.'; return 0; }; }
    # Keep one backup for this operation; restore atomically after any failed replacement.
    edgekit_update_cleanup() {
        local rc=$? restore=''
        trap - EXIT
        if ((replaced)); then
            if restore=$(mktemp "${ENTRY}.XXXXXX") &&
                install -m 755 -o root -g root "$work/previous.sh" "$restore" && mv -f "$restore" "$ENTRY"; then
                restore=""
                say "Previous edgekit entry restored." >&3
            else
                keep=1; rc=1
                say "Recovery failed; previous entry kept at ${work}/previous.sh." >&3
            fi
        fi
        [[ -z $restore ]] || rm -f "$restore"
        [[ -z $atomic ]] || rm -f "$atomic"
        if [[ -n $work ]] && ((keep==0)); then rm -rf "$work"; fi
        exit "$rc"
    }
    trap edgekit_update_cleanup EXIT
    trap 'exit 130' INT TERM
    work=$(mktemp -d "$STATE/edgekit-update.XXXXXX")
    stage Download "Download setup.sh from release ${target}; verify version and Bash entry points."
    fetch "https://raw.githubusercontent.com/xgungnir/edgekit/$target/setup.sh" -o "$work/setup.sh" || fail 'Edgekit script download failed.'
    [[ -s $work/setup.sh && $(edgekit_file_version "$work/setup.sh") == "$version" ]] || fail 'Downloaded edgekit version does not match the release.'
    edgekit_script_check "$work/setup.sh" "$version" || fail 'Downloaded edgekit failed syntax or entry point checks.'
    cp -p "$ENTRY" "$work/previous.sh"
    atomic=$(mktemp "${ENTRY}.XXXXXX")
    install -m 755 -o root -g root "$work/setup.sh" "$atomic"
    replaced=1
    mv -f "$atomic" "$ENTRY"; atomic=''
    edgekit_script_check "$ENTRY" "$version" || fail 'Updated edgekit entry failed verification.'
    replaced=0
    cleanup_bootstrap
    say "Success: edgekit updated to ${version}; configuration and running services kept."
)
# Verify running master/workers map the current library files, including after a restart.
tls_loaded() {
    local dir=${1:-} master pid lib file inode workers
    master=$(systemctl show nginx -p MainPID --value) || return 1
    [[ $master =~ ^[0-9]+$ && $master -gt 1 ]] || return 1
    workers=$(pgrep -P "$master" -x nginx) || return 1
    for lib in libssl.so.3 libcrypto.so.3; do
        if [[ -n $dir ]]; then file=$dir/lib/$lib
        else file=$(ldd /usr/sbin/nginx | awk -v lib="$lib" '$1==lib{print $3}'); fi
        file=$(readlink -f "$file") || return 1
        inode=$(stat -c '%i' "$file") || return 1
        for pid in $master $workers; do
            awk -v file="$file" -v inode="$inode" '$5==inode && $6==file{found=1} END{exit !found}' /proc/"$pid"/maps || return 1
        done
    done
}
tls_switch() (
    local dir=$1 old backup
    old=$(tls_current) || fail 'Current isolated TLS runtime is invalid.'
    tls_verified "$dir" || fail 'New TLS runtime is not verified.'
    backup=$(mktemp -d "$STATE/tls-update.XXXXXX")
    cp -a "$TLS_DROPIN" "$backup/drop-in"
    printf '%s\n' "$old" > "$backup/previous-runtime"
    trap 'exit 130' INT TERM
    trap 'rc=$?; trap - EXIT ERR; if ((rc!=0)); then
        rm -f "$TLS_ROOT/.current.$$";
        ln -s "$old" "$TLS_ROOT/.current.$$";
        mv -Tf "$TLS_ROOT/.current.$$" "$TLS_CURRENT";
        cp -a "$backup/drop-in" "$TLS_DROPIN";
        if systemctl daemon-reload && nginx_cmd -t >>"$LOG" 2>&1 && systemctl restart nginx && tls_loaded "$old"; then
            say "TLS update failed; restored previous isolated libraries and Nginx, service is running. Log: ${LOG}." >&3;
            rm -rf "$backup";
        else say "TLS recovery failed. Check $LOG and backup ${backup}." >&3; fi;
    fi; exit "$rc"' EXIT
    tls_configure "$dir"
    nginx_cmd -t >>"$LOG" 2>&1
    systemctl daemon-reload
    systemctl restart nginx
    systemctl is-active --quiet nginx
    tls_loaded "$dir"
    rm -rf "$backup"
    trap - EXIT
)
update_tls_conda() (
    local yes=$1 old work subdir current target dir
    old=$(tls_current) || fail 'Current isolated TLS runtime is invalid; no automatic initialization.'
    work=$(mktemp -d "$STATE/tls-query.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    trap 'exit 130' INT TERM
    case $ARCH in amd64) subdir=linux-64;; arm64) subdir=linux-aarch64;; esac
    stage Versions 'Query the latest stable OpenSSL 3.5.x build from conda-forge main.'
    fetch https://api.anaconda.org/package/conda-forge/openssl | tls_select "$subdir" > "$work/package.json"
    current=$(jq -r '.version+"-"+.attrs.build' "$old/package.json")
    target=$(jq -r '.version+"-"+.attrs.build' "$work/package.json")
    say "TLS current: ${current}; target: ${target}; source: conda-forge (isolated libraries)."
    if [[ $(jq -r .sha256 "$old/package.json") == "$(jq -r .sha256 "$work/package.json")" ]]; then
        say 'Already up to date.'; return
    fi
    local old_version new_version old_build new_build
    old_version=$(jq -r .version "$old/package.json"); new_version=$(jq -r .version "$work/package.json")
    old_build=$(jq -r .attrs.build_number "$old/package.json"); new_build=$(jq -r .attrs.build_number "$work/package.json")
    if dpkg --compare-versions "$new_version" lt "$old_version" || { [[ $new_version == "$old_version" ]] && ((new_build < old_build)); }; then
        fail 'Channel target is below the current version/build; no automatic downgrade.'
    fi
    [[ $yes == --yes ]] || { confirm || { say 'Cancelled.'; return; }; }
    stage TLS-update 'Download and verify the confirmed build; keep previous libraries, then restart Nginx only.'
    dir=$(/bin/bash "$ENTRY" _tls-prepare "$work/package.json") || fail "New TLS preparation failed; previous runtime unchanged. Log: $STATE/tls-prepare.log."
    if /bin/bash "$ENTRY" _tls-switch "$dir" >>"$LOG"; then
        say "Success: TLS updated to ${target}; Nginx configuration and loaded libraries verified."
    else fail "TLS update failed. See ${LOG} for the cause and recovery result."; fi
)
update_tls_native() (
    local yes=$1 pkg current target changed=0 work planned
    local packages=(openssl libssl3t64 openssl-provider-legacy) targets=()
    work=$(mktemp -d "$STATE/tls-apt.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    trap 'exit 130' INT TERM
    if dpkg-query -W -f='${db:Status-Status}' libssl-dev 2>/dev/null | grep -qx installed; then packages+=(libssl-dev); fi
    stage Versions 'Refresh APT indexes and check Debian system OpenSSL packages.'
    apt-get -o APT::Update::Error-Mode=any update >>"$LOG" 2>&1
    for pkg in "${packages[@]}"; do
        dpkg-query -W -f='${db:Status-Status}' "$pkg" | grep -qx installed || fail "$pkg is not installed; no automatic system repair."
        current=$(dpkg-query -W -f='${Version}' "$pkg")
        target=$(LC_ALL=C apt-cache policy "$pkg" | awk '/Candidate:/{print $2}')
        [[ $target =~ ^([0-9]+:)?3\.5\.[0-9]+[-+~] ]] || fail "$pkg has no available OpenSSL 3.5.x APT target."
        ! dpkg --compare-versions "$target" lt "$current" || fail "$pkg APT target is below the current version; no automatic downgrade."
        targets+=("$pkg=$target")
        say "TLS $pkg current: ${current}; target: ${target}; source: Debian system APT."
        [[ $current == "$target" ]] || changed=1
    done
    if ((changed == 0)); then
        if tls_loaded; then say 'Already up to date. Nginx has loaded the current system OpenSSL libraries.'; return; fi
        say 'System OpenSSL packages are up to date, but Nginx has not loaded the current libraries; only a Nginx restart is needed.'
        [[ $yes == --yes ]] || { confirm || { say 'Cancelled.'; return; }; }
        if nginx_cmd -t >>"$LOG" 2>&1 && systemctl restart nginx && tls_loaded; then
            say 'Success: Nginx restarted and loaded the current system TLS libraries.'
        else fail "Nginx failed to load current TLS libraries. Log: ${LOG}."; fi
        return
    fi
    LC_ALL=C apt-get -s --only-upgrade --no-remove --no-install-recommends install "${targets[@]}" > "$work/plan" 2>>"$LOG"
    cat "$work/plan" >> "$LOG"
    ! grep -q '^Remv ' "$work/plan" || fail 'APT plan would remove packages; nothing executed.'
    while read -r planned; do
        case ${planned%%:*} in openssl|libssl3t64|openssl-provider-legacy|libssl-dev) ;; *) fail "APT plan would also change ${planned}, outside the TLS update scope; nothing executed.";; esac
    done < <(awk '/^Inst /{print $2}' "$work/plan")
    say 'Update shared system OpenSSL packages and restart Nginx. Other services using system libraries may need a separate restart. No automatic downgrade after package failure.'
    [[ $yes == --yes ]] || { confirm || { say 'Cancelled.'; return; }; }
    stage TLS-update 'Update selected OpenSSL packages and check Nginx; no full system upgrade.'
    # Keep needrestart in list-only mode; do not deliberately restart unrelated services.
    if DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get --only-upgrade --no-remove --no-install-recommends -y install "${targets[@]}" >>"$LOG" 2>&1; then
        local matched=1
        for pkg in "${targets[@]}"; do
            [[ $(dpkg-query -W -f='${Version}' "${pkg%%=*}") == "${pkg#*=}" ]] || matched=0
        done
        if ((matched)) && nginx_cmd -t >>"$LOG" 2>&1 && systemctl restart nginx && systemctl is-active --quiet nginx && tls_loaded; then
            say 'Success: system TLS packages updated; Nginx configuration and loaded libraries verified.'
            return
        fi
    fi
    dpkg-query -W -f='${binary:Package} ${Version}\n' "${packages[@]}" >&3 || true
    fail "System TLS update or verification failed; no automatic downgrade of shared libraries. Nginx: $(systemctl is-active nginx 2>/dev/null || true). Log: ${LOG}."
)
update_tls() {
    local yes=${1:-}
    [[ $# -le 1 && ( -z $yes || $yes == --yes ) ]] || fail 'Usage: update-tls [--yes].'
    root_required; require_install; check_os; start_log update-tls
    exec 8>"$STATE/operation.lock"; flock -n 8 || fail 'Another management operation is running.'
    systemctl is-active --quiet nginx || fail 'Nginx service is unhealthy. Diagnose it first; no automatic initialization.'
    nginx_cmd -t >>"$LOG" 2>&1
    if [[ $DEBIAN == 12 ]]; then update_tls_conda "$yes"
    else update_tls_native "$yes"; fi
}

# ---------- Optional host network tuning; never called by installation ----------
network_config() {
    # Authoritative user profile: keep comments, spacing and values unchanged.
    cat <<'SYSCTL'
# /etc/sysctl.d/99-proxy-tuning.conf
# Workload: TCP proxy + TUIC v5 (UDP/QUIC)
# Profile: Performance-oriented, aggressive

# Queuing & Congestion Control
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# Socket Buffer Limits (TCP + UDP)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864

# TCP Autotuning
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432

# Connection Handling
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 2
net.ipv4.tcp_fin_timeout = 10

# Aggressive TCP Failure Detection
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_syn_retries = 4
net.ipv4.tcp_synack_retries = 4

# System Recovery & Memory
kernel.panic = -1
vm.swappiness = 50
SYSCTL
}
network_values() {
    awk -F= '/^[[:space:]]*[^#;[:space:]][^=]*=/ {
        key=$1; value=substr($0,index($0,"=")+1);
        sub(/[;#].*$/, "", value);
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key);
        sub(/^-/, "", key); gsub(/\//, ".", key);
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value);
        gsub(/[[:space:]]+/, " ", value); print key "=" value
    }' "$1"
}
network_tools() {
    local check=$1 pair cmd pkg missing=()
    for pair in ip:iproute2 tc:iproute2 modprobe:kmod sysctl:procps jq:jq; do
        cmd=${pair%:*}; pkg=${pair#*:}
        if ! command -v "$cmd" >/dev/null; then
            [[ $check != --check ]] || fail "Missing ${cmd}; read-only checks do not install tools."
            [[ " ${missing[*]} " == *" $pkg "* ]] || missing+=("$pkg")
        fi
    done
    if ((${#missing[@]})); then
        stage Tools "Install missing network tuning tools only: ${missing[*]}"
        apt-get update >>"$LOG" 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >>"$LOG" 2>&1
        printf '%s\n' "${missing[@]}" >> "$STATE/base-packages"
    fi
}
network_environment() {
    local container cap name value
    if container=$(systemd-detect-virt --container 2>/dev/null); then fail "Unsupported container environment: ${container}."; fi
    cap=''
    while read -r name value; do [[ $name != CapEff: ]] || cap=$value; done < "$NETWORK_PROC/self/status"
    [[ $cap =~ ^[0-9a-fA-F]+$ ]] && (( (16#$cap & 4096) != 0 )) || fail 'Missing CAP_NET_ADMIN; cannot change the interface qdisc.'
}
network_boot() {
    [[ $(systemctl show systemd-sysctl.service -p LoadState --value) == loaded ]] || fail 'systemd-sysctl.service is not loaded or is masked; boot loading cannot be guaranteed.'
    [[ $(systemctl show systemd-sysctl.service -p UnitFileState --value) != masked ]] || fail 'systemd-sysctl.service is masked.'
    systemctl list-dependencies --plain --all --no-pager sysinit.target | grep -qw systemd-sysctl.service || fail 'Boot dependencies do not include systemd-sysctl.service; boot configuration will not be changed automatically.'
}
network_conflicts() {
    local desired=$1 dir file base key value wanted blocked=0 earlier=0 LC_ALL=C
    local -a files=()
    local -A seen=() values=()
    while IFS='=' read -r key value; do values[$key]=$value; done < <(network_values "$desired")
    # Directory priority masks identical filenames; full filenames determine loading order.
    for dir in "${NETWORK_SYSCTL_DIRS[@]}"; do
        for file in "$dir"/*.conf; do
            [[ -e $file || -L $file ]] || continue
            base=${file##*/}
            [[ ! ${seen[$base]+yes} ]] || continue
            seen[$base]=1
            [[ $base == "${NETWORK_CONF##*/}" ]] || files+=("$file")
        done
    done
    [[ ! -f $NETWORK_SYSCTL_LEGACY ]] || files+=("$NETWORK_SYSCTL_LEGACY")
    for file in "${files[@]}"; do
        [[ -r $file ]] || fail "Cannot read sysctl file: ${file}."
        base=${file##*/}
        while IFS='=' read -r key value; do
            for wanted in "${!values[@]}"; do
                # shellcheck disable=SC2053 # sysctl permits glob patterns.
                [[ $wanted == $key && $value != "${values[$wanted]}" ]] || continue
                if [[ $file != "$NETWORK_SYSCTL_LEGACY" && $base < ${NETWORK_CONF##*/} ]]; then
                    say "Overridable difference (loaded earlier): ${file} ${key} = ${value}; target ${values[$wanted]}" >&3
                    earlier=1
                else
                    say "Blocking conflict (loaded later/legacy): ${file} ${key} = ${value}; target ${values[$wanted]}" >&3
                    blocked=1
                fi
            done
        done < <(network_values "$file")
    done
    ((blocked==0)) || fail 'Later sysctl files conflict. Resolve the listed files first; other configuration will not be changed.'
    if ((earlier)); then say "[INFO] ${NETWORK_CONF##*/} loads later and overrides these values; original files are kept."; fi
}
network_interface() {
    local family rules routes selected='' dev='' link path target
    for family in 4 6; do
        rules=$(ip -j -"$family" rule show)
        jq -e 'all(.[];
            ((keys - ["priority","src","dst","table","protocol"])|length)==0 and
            (.src // "all")=="all" and (.dst // "all")=="all" and
            ((.priority==0 and (.table=="local" or .table==255)) or
             (.priority==32766 and (.table=="main" or .table==254)) or
             (.priority==32767 and (.table=="default" or .table==253)))) and
            (group_by(.priority)|all(.[];length==1))' <<< "$rules" >/dev/null || fail "IPv${family} has policy routing; refusing to guess the public interface."
        routes=$(ip -j -"$family" route show table main default)
        jq -e '([.[].dev]|unique|length)<=1 and all(.[]; (.dev|type)=="string" and
            (has("nexthops") or has("nhid")|not) and (.type // "unicast")=="unicast" and
            ((.flags // [])|all(.[]; .!="linkdown" and .!="dead")))' <<< "$routes" >/dev/null || fail "IPv${family} default route is ambiguous, unavailable or multipath; refusing to change the interface."
        dev=$(jq -r '.[0].dev // empty' <<< "$routes")
        if [[ -n $dev ]]; then
            [[ -z $selected || $selected == "$dev" ]] || fail 'IPv4/IPv6 default routes use different interfaces. Check manually; no automatic selection.'
            selected=$dev
            target=1.1.1.1
            [[ $family == 4 ]] || target=2606:4700:4700::1111
            routes=$(ip -j -"$family" route get "$target")
            jq -e --arg dev "$selected" 'length==1 and .[0].dev==$dev' <<< "$routes" >/dev/null ||
                fail "Route lookup for IPv${family} does not match the default interface."
        fi
    done
    [[ $selected =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || fail 'Cannot reliably identify the default outbound interface.'
    case $selected in lo|docker*|br-*|virbr*|veth*|tun*|tap*|wg*) fail "Refusing to change virtual interface: ${selected}.";; esac
    path=$(readlink -f "$NETWORK_SYS/class/net/$selected") || fail 'Cannot resolve the network interface.'
    [[ -d $path && $path != */virtual/* ]] || fail "Refusing to change virtual or missing interface: ${selected}."
    link=$(ip -d -j link show dev "$selected")
    jq -e 'length==1 and .[0].link_type=="ether" and
        (.[0].linkinfo.info_kind // "")=="" and (.[0].flags|index("UP"))!=null' <<< "$link" >/dev/null || fail "${selected} is not an active Ethernet interface that can be safely managed."
    printf '%s\n' "$selected"
}
network_qdisc() {
    local dev=$1 qdisc extra kind
    qdisc=$(tc -j qdisc show dev "$dev")
    jq -e 'length==1 and .[0].root==true and
        (.[0].kind=="fq_pie" or
         (.[0].handle=="0:" and (["fq","fq_codel","pfifo_fast"]|index($kind))!=null))' \
        --arg kind "$(jq -r '.[0].kind' <<< "$qdisc")" <<< "$qdisc" >/dev/null || {
        say "$qdisc" >&3; fail "${dev} has a complex or unknown qdisc (mq, shaping tree or ingress); skipped for safety, nothing overwritten."
    }
    extra=$(tc -j class show dev "$dev")
    jq -e 'length==0' <<< "$extra" >/dev/null || fail "${dev} has traffic control classes; skipped for safety."
    extra=$(tc -j filter show dev "$dev" root)
    jq -e 'length==0' <<< "$extra" >/dev/null || fail "${dev} has root filters; skipped for safety."
    kind=$(jq -r '.[0].kind' <<< "$qdisc")
    printf '%s\n' "$kind"
}
network_modules() {
    local output
    if [[ ! -d $NETWORK_SYS/module/sch_fq_pie ]]; then
        if output=$(modprobe sch_fq_pie 2>&1); then printf '%s\n' "$output" >> "$LOG"
        else printf '%s\n' "$output" | tee -a "$LOG" >&3; fail 'Kernel cannot load sch_fq_pie; no fallback qdisc.'; fi
    fi
    if [[ " $(sysctl -n net.ipv4.tcp_available_congestion_control) " != *' bbr '* ]]; then
        if output=$(modprobe tcp_bbr 2>&1); then printf '%s\n' "$output" >> "$LOG"
        else printf '%s\n' "$output" | tee -a "$LOG" >&3; fail 'Kernel cannot load tcp_bbr.'; fi
    fi
    [[ " $(sysctl -n net.ipv4.tcp_available_congestion_control) " == *' bbr '* ]] || fail 'Current kernel does not provide bbr.'
}
network_verify() {
    local key expected actual bad=0
    while IFS='=' read -r key expected; do
        if ! actual=$(sysctl -n "$key" 2>&1); then
            say "Cannot read parameter: ${key}: ${actual}" >&3; bad=1; continue
        fi
        actual=$(printf '%s' "$actual" | awk '{$1=$1;print}')
        if [[ $actual != "$expected" ]]; then
            say "Parameter mismatch: ${key} = ${actual}; target ${expected}" >&3; bad=1
        fi
    done < <(network_values "$1")
    ((bad == 0))
}
tune_network() (
    local option=${1:-} dev kind atomic='' changed=0
    [[ $# -le 1 && ( -z $option || $option == --yes || $option == --check ) ]] || fail 'Usage: tune-network [--yes|--check].'
    root_required; require_install; check_os
    if [[ $option != --check ]]; then
        say 'Apply network tuning and switch the default public interface root qdisc to fq_pie; no network or VPS restart.'
        network_conflicts <(network_config)
        [[ $option == --yes ]] || { confirm || { say 'Cancelled.'; return; }; }
        start_log network-tune
        exec 8>"$STATE/operation.lock"; flock -n 8 || fail 'Another management operation is running.'
    fi
    stage Network-preflight 'Check permissions, boot loading, default interface and actual qdisc.'
    network_environment; network_boot; network_tools "$option"
    [[ ! -L $NETWORK_CONF && ( ! -e $NETWORK_CONF || -f $NETWORK_CONF ) ]] || fail "${NETWORK_CONF} is not a regular file; refusing to overwrite."
    dev=$(network_interface); kind=$(network_qdisc "$dev")
    if [[ $option == --check ]]; then
        cmp -s <(network_config) "$NETWORK_CONF" || fail 'Tuning configuration is missing or differs from the embedded profile.'
        [[ $(stat -c '%u:%g:%a' "$NETWORK_CONF") == 0:0:644 ]] || fail 'Tuning file must be root:root 0644.'
        network_conflicts "$NETWORK_CONF"
        network_verify "$NETWORK_CONF" || fail 'Runtime parameters are not fully applied.'
        [[ $kind == fq_pie ]] || fail "${dev} actual root qdisc is ${kind}; expected fq_pie."
    else
        # Only a same-directory temporary file is needed; no snapshots or rollback state.
        trap '[[ -z $atomic ]] || rm -f "$atomic"' EXIT
        trap 'exit 130' INT TERM
        network_modules
        if ! cmp -s <(network_config) "$NETWORK_CONF"; then
            install -d -m 755 "${NETWORK_CONF%/*}"
            atomic=$(mktemp "${NETWORK_CONF}.XXXXXX")
            network_config > "$atomic"
            chown 0:0 "$atomic"; chmod 644 "$atomic"
            mv -f "$atomic" "$NETWORK_CONF"; atomic=''
            changed=1
            say "[OK] Configuration written: ${NETWORK_CONF}"
        else
            [[ $(stat -c '%u:%g:%a' "$NETWORK_CONF") == 0:0:644 ]] || { chown 0:0 "$NETWORK_CONF"; chmod 644 "$NETWORK_CONF"; }
            say '[OK] Configuration unchanged.'
        fi
        if ((changed)) || ! network_verify "$NETWORK_CONF" 3>/dev/null; then
            if ! sysctl -p "$NETWORK_CONF" 2>&1 | tee -a "$LOG"; then
                fail 'sysctl loading failed; some values may be applied. Fix the errors above and retry; no automatic rollback.'
            fi
        fi
        network_verify "$NETWORK_CONF" || fail 'sysctl verification failed; no automatic rollback. Fix the issue and retry.'
        # Inspect again immediately before touching the queue; never replace a shaping tree.
        kind=$(network_qdisc "$dev")
        if [[ $kind != fq_pie ]]; then
            if ! tc qdisc replace dev "$dev" root fq_pie 2>&1 | tee -a "$LOG"; then
                fail "sysctl applied, but ${dev} qdisc switch failed. Fix the issue and retry."
            fi
            kind=$(network_qdisc "$dev")
            [[ $kind == fq_pie ]] || fail "sysctl applied, but ${dev} actual qdisc verification failed."
        else say "[OK] ${dev} already uses fq_pie; no replacement needed."; fi
    fi
    say '[OK] sysctl parameters verified; TCP congestion control bbr, default qdisc fq_pie.'
    say "[OK] Public interface ${dev}, actual root qdisc ${kind}."
    tc qdisc show dev "$dev"
    say '[INFO] systemd-sysctl loads the profile at boot. No immediate restart needed; run ek tune-network --check after a maintenance reboot.'
)

# ---------- Explicit SSH password protection; independent of proxy lifecycle ----------
ssh_guard_running() { command -v fail2ban-client >/dev/null && timeout 3 fail2ban-client status "$SSH_JAIL" >/dev/null 2>&1; }
ssh_guard_files() {
    local f
    for f in "$F2B_DIR/jail.conf" "$F2B_DIR/jail.local" "$F2B_DIR"/jail.d/*.conf "$F2B_DIR"/jail.d/*.local; do
        [[ -f $f && $f != "$SSH_JAIL_FILE" ]] || continue
        if grep -Eq "^[[:space:]]*\[${SSH_JAIL}\][[:space:]]*([#;].*)?$" "$f"; then say "$f"; fi
    done
}
ssh_guard_present() {
    [[ -e $SSH_JAIL_FILE || -L $SSH_JAIL_FILE || -e $SSH_FILTER_FILE || -L $SSH_FILTER_FILE ]] ||
        [[ -n $(ssh_guard_files) ]] || ssh_guard_running
}
ssh_guard_label() {
    if ssh_guard_present; then
        if [[ -f $SSH_JAIL_FILE && -f $SSH_FILTER_FILE && ! -L $SSH_JAIL_FILE && ! -L $SSH_FILTER_FILE ]] && ssh_guard_running; then
            say 'Remove SSH password protection'
        else say 'Remove SSH password protection (not running/invalid configuration)'; fi
    else say 'Enable SSH password protection'; fi
}
ssh_guard_owned() {
    local f
    [[ -z $(ssh_guard_files) ]] || fail "Same jail name found in other configuration; refusing to take over: $(ssh_guard_files)"
    for f in "$SSH_JAIL_FILE" "$SSH_FILTER_FILE"; do
        if [[ -e $f || -L $f ]]; then
            [[ -f $f && ! -L $f ]] && grep -qx '# Managed by edgekit: edgekit-sshd-password' "$f" || fail "Unknown configuration; refusing to overwrite or delete: $f"
        fi
    done
    if ssh_guard_running && [[ ! -f $SSH_JAIL_FILE ]]; then fail 'Running jail with the same name has no edgekit configuration; refusing to take over.'; fi
}
ssh_guard_filter() {
    cat <<'EOF'
# Managed by edgekit: edgekit-sshd-password
[INCLUDES]
before = common.conf

[Definition]
_daemon = sshd(?:-session)?
failregex = ^%(__prefix_line)sFailed password for (?:invalid user )?\S+ from <HOST> port \d+(?: ssh\d+)?(?: \[preauth\])?\s*$
ignoreregex =
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
EOF
}
ssh_guard_config() {
    cat <<'EOF'
# Managed by edgekit: edgekit-sshd-password
[edgekit-sshd-password]
enabled = true
filter = edgekit-sshd-password
backend = systemd
usedns = no
findtime = 3600
maxretry = 2
bantime = -1
bantime.increment = false
# An address-only rule blocks every inbound protocol, on Debian 12 and 13.
action = nftables[type=allports, name=edgekit-sshd-password, table=edgekit-f2b, rule_stat="<addr_family> saddr @<addr_set> <blocktype>"]
EOF
}
ssh_guard_check() {
    local db
    [[ -f $SSH_JAIL_FILE && -f $SSH_FILTER_FILE ]] || fail 'SSH protection configuration is incomplete. Remove it and enable it again.'
    ssh_guard_running || fail 'SSH protection jail is not running.'
    [[ $(fail2ban-client get "$SSH_JAIL" findtime) == 3600 && $(fail2ban-client get "$SSH_JAIL" maxretry) == 2 && $(fail2ban-client get "$SSH_JAIL" bantime) == -1 ]] || fail 'SSH protection runtime parameters do not match expected values.'
    # The client formats dbfile as an ASCII tree; accept its absolute path line.
    db=$(fail2ban-client get dbfile | sed -n 's/^[[:space:]`|-]*\(\/.*\)$/\1/p')
    [[ $db == /* && -f $db && -s $db ]] || fail 'Fail2ban has no usable persistent database; permanent ban recovery cannot be guaranteed. Global database settings will not be changed.'
}
ssh_guard_unban() {
    local ip bans
    fail2ban-client set "$SSH_JAIL" idle on >/dev/null || return 1
    bans=$(fail2ban-client get "$SSH_JAIL" banip) || return 1
    for ip in $bans; do fail2ban-client set "$SSH_JAIL" unbanip "$ip" >/dev/null || return 1; done
}
# Repair a stock file-backed sshd jail only when SSH journal records are available.
# Keep this backend setting when removing our separate password jail.
ssh_guard_journal_backend() (
    local file="$F2B_DIR/jail.d/edgekit-debian-sshd.local" f tmp='' config_error
    if config_error=$(fail2ban-client -t 2>&1); then return 0; fi
    [[ ${config_error//\'/} == *'Have not found any log file for sshd jail'* ]] ||
        fail 'Fail2ban configuration has an unrelated error; no log backend changed.'
    [[ -n $(journalctl --quiet --no-pager -n 1 -o json _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session 2>/dev/null) ]] ||
        fail 'No readable SSH journal records found; no log backend changed.'
    cmp -s <(printf '[sshd]\nenabled = true\n') "$F2B_DIR/jail.d/defaults-debian.conf" ||
        fail 'Default sshd jail differs from the packaged configuration; configure its log backend manually.'
    for f in "$F2B_DIR/paths-overrides.local" "$F2B_DIR/paths-debian.local"; do
        [[ ! -f $f ]] || ! grep -Eq '^[[:space:]]*sshd_(log|backend)[[:space:]]*=' "$f" ||
            fail 'Custom sshd log source found; configure its log backend manually.'
    done
    for f in "$F2B_DIR/jail.local" "$F2B_DIR"/jail.d/*.conf "$F2B_DIR"/jail.d/*.local; do
        [[ -f $f && $f != "$file" && $f != "$F2B_DIR/jail.d/defaults-debian.conf" ]] || continue
        ! grep -Eq '^[[:space:]]*\[sshd\][[:space:]]*([#;].*)?$' "$f" ||
            fail 'Custom sshd jail settings found; configure its journal backend before enabling SSH protection.'
    done
    local content='# Managed by edgekit: Debian sshd journal backend
[sshd]
backend = systemd'
    if [[ -e $file || -L $file ]]; then
        [[ -f $file && ! -L $file ]] && cmp -s <(printf '%s\n' "$content") "$file" ||
            fail "Unknown compatibility configuration; refusing to overwrite: ${file}"
        return 0
    fi
    trap '[[ -z $tmp ]] || rm -f "$tmp"' EXIT
    tmp=$(mktemp "$F2B_DIR/jail.d/.edgekit-sshd.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    chown 0:0 "$tmp"; chmod 644 "$tmp"
    mv -T "$tmp" "$file"
    say '[OK] Default sshd jail uses the available SSH journal; existing ban policy is unchanged.'
)
ssh_guard_cleanup() {
    local rc=$?
    if ((published && !complete)); then
        if ssh_guard_running; then
            if ! ssh_guard_unban || ! fail2ban-client stop "$SSH_JAIL"; then
                say 'Failed: SSH protection recovery incomplete; configuration kept. Check Fail2ban status and retry removal.' >&3
                rm -rf "$work"
                exit 1
            fi
        fi
        rm -f "$SSH_JAIL_FILE" "$SSH_FILTER_FILE"
        say 'Failed: new SSH protection configuration removed; dependency packages kept. Check the errors above.' >&3
    fi
    rm -rf "$work"
    exit "$rc"
}
ssh_guard() (
    root_required; check_os
    STAGE='SSH protection'
    local op=${1:-} yes=${2:-} work='' published=0 complete=0 existing=0 config_error
    local missing=()
    [[ $# -le 2 && ( -z $yes || $yes == --yes ) ]] || fail 'Usage: ek ssh-guard [install|remove] [--yes]'
    if [[ -z $op ]]; then if ssh_guard_present; then op=remove; else op=install; fi; fi
    [[ $op == install || $op == remove ]] || fail 'Usage: ek ssh-guard [install|remove] [--yes]'
    ssh_guard_owned
    if [[ $op == install ]] && ssh_guard_present; then
        fail2ban-client -t || fail 'Existing Fail2ban configuration is invalid; nothing changed or reloaded.'
        ssh_guard_check
        say '[OK] SSH password protection is already running; no reinstall needed.'; return
    fi
    if [[ $op == remove ]] && ! ssh_guard_present; then say 'Nothing to remove: no SSH password protection rules.'; return; fi
    say 'Rule: 2 password failures from the same IP within 1 hour permanently block all inbound ports/protocols (IPv4/IPv6).'
    if [[ $op == install ]]; then
        say 'Install missing Fail2ban/nftables dependencies and enable Fail2ban. Keep and report other jails, including Debian default sshd. Uninstalling edgekit keeps this protection.'
    else say 'Unban all IPs in this jail and remove its configuration; keep Fail2ban packages, other jails and the shared database.'; fi
    [[ $yes == --yes ]] || { confirm || { say 'Cancelled.'; return; }; }
    # A separate lock works even before proxy installation or after its removal.
    exec 8>/run/lock/edgekit-ssh-guard.lock; flock -n 8 || fail 'Another SSH protection operation is running.'
    ssh_guard_owned
    if [[ $op == remove ]]; then
        command -v fail2ban-client >/dev/null && fail2ban-client ping >/dev/null || fail 'Fail2ban is not running; cannot safely clear persistent bans. Restore the service and retry.'
        if ! ssh_guard_running; then fail2ban-client reload --restart --if-exists "$SSH_JAIL" || fail 'Cannot load this jail to clear saved bans. Check configuration.'; fi
        ssh_guard_unban
        fail2ban-client stop "$SSH_JAIL"
        nft list tables >/dev/null || fail 'Cannot inspect nftables; configuration kept. Restore permissions and retry.'
        if nft list table inet edgekit-f2b >/dev/null 2>&1; then fail 'SSH protection nftables table still exists; configuration kept. Check Fail2ban logs and retry.'; fi
        rm -f "$SSH_JAIL_FILE" "$SSH_FILTER_FILE"
        ! ssh_guard_running || fail 'Jail is still running; removal failed.'
        say '[OK] SSH password protection removed and bans from this jail cleared; other jails and packages kept.'; return
    fi
    if command -v fail2ban-client >/dev/null; then
        existing=1
        if ! fail2ban-client ping >/dev/null; then
            # Recover a confirmed log-source failure, never an intentionally stopped service.
            if systemctl is-failed --quiet fail2ban &&
                ! config_error=$(fail2ban-client -t 2>&1) && [[ ${config_error//\'/} == *'Have not found any log file for sshd jail'* ]]; then
                ssh_guard_journal_backend
                fail2ban-client -t || fail 'Fail2ban still has invalid configuration; no service started.'
                existing=0
            else fail 'Existing Fail2ban is not running; restore it first to avoid starting other jails unexpectedly.'; fi
        fi
    fi
    command -v fail2ban-client >/dev/null || missing+=(fail2ban)
    command -v nft >/dev/null || missing+=(nftables)
    /usr/bin/python3 -c 'import systemd.journal' 2>/dev/null || missing+=(python3-systemd)
    if ((${#missing[@]})); then
        stage 'SSH dependencies' "Install missing dependencies only: ${missing[*]}."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    fi
    nft list tables >/dev/null || fail 'Usable nftables or network administration permissions are missing.'
    if ((existing==0)); then ssh_guard_journal_backend; fi
    # Transient files share the destination filesystem; failure removes only our new files.
    work=$(mktemp -d "$F2B_DIR/.edgekit-ssh.XXXXXX")
    trap ssh_guard_cleanup EXIT
    ssh_guard_filter > "$work/filter"
    ssh_guard_config > "$work/jail"
    chown 0:0 "$work/filter" "$work/jail"; chmod 644 "$work/filter" "$work/jail"
    ssh_guard_owned
    [[ ! -e $SSH_JAIL_FILE && ! -e $SSH_FILTER_FILE ]] || fail 'Configuration state changed. Run the command again.'
    published=1
    mv -T "$work/filter" "$SSH_FILTER_FILE"
    mv -T "$work/jail" "$SSH_JAIL_FILE"
    fail2ban-client -t || fail 'Fail2ban configuration check failed.'
    systemctl enable fail2ban
    if ((existing)); then fail2ban-client reload --restart --if-exists "$SSH_JAIL"
    else
        systemctl start fail2ban
        local attempt
        for ((attempt=0; attempt<10; attempt++)); do fail2ban-client ping >/dev/null 2>&1 && break; sleep 1; done
        fail2ban-client reload --restart --if-exists "$SSH_JAIL"
    fi
    ssh_guard_check
    complete=1
    say '[OK] 2 SSH password failures per hour permanently block all inbound protocols and ports; startup and persistent database enabled.'
    say 'All current jails (other policies unchanged):'
    fail2ban-client status
)

uninstall() {
    root_required
    if [[ ! -f $STATE/owner ]]; then
        [[ $SELF == "$ENTRY" && -f $ENTRY && ! -L $ENTRY && ! -e $STATE/installed ]] || fail 'No deployment record for this script; refusing to delete unknown resources.'
        say "Remove the ek entry, ${DEFAULT_ENV} and matching download copy; keep other system files and SSH password protection."
        [[ ${1:-} == --yes ]] || { confirm || { say 'Cancelled.'; return; }; }
        cleanup_bootstrap
        rm -f "$DEFAULT_ENV"
        rm -f "$ENTRY"
        say 'Success: no application services deployed; entry and default input file removed.'
        return
    fi
    say "Remove Xray, Nginx, sing-box, acme.sh, certificates/credentials/website, daily task, ek, ${DEFAULT_ENV} and added firewall rules."
    say 'Keep installed base tools, isolated OpenSSL/PQC and dependencies, official Nginx mainline repository, enabled host network tuning and SSH password protection. Certificates are not revoked.'
    [[ ${1:-} == --yes ]] || { confirm || { say 'Cancelled.'; return; }; }
    start_log uninstall
    exec 8>"$STATE/operation.lock"; flock -n 8 || fail 'Another management operation is running.'
    stage 'Uninstall edgekit' 'Stop application services and remove deployed resources.'
    local s
    rm -f /etc/cron.d/edgekit-acme
    for s in nginx xray sing-box; do systemctl disable --now "$s" >>"$LOG" 2>&1 || true; done
    if [[ -f $STATE/ufw-added ]]; then
        firewall_remove
    fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx >>"$LOG" 2>&1
    rm -rf "$SB_BIN" "${SB_CONFIG%/*}" "$SB_STATE" /etc/nginx /var/log/nginx
    rm -rf /etc/systemd/system/xray.service /etc/systemd/system/sing-box.service "$TLS_DROPIN"
    rmdir "${TLS_DROPIN%/*}" 2>/dev/null || true
    if [[ -f $STATE/users-new ]]; then
        while read -r s; do if id "$s" >/dev/null 2>&1; then userdel "$s" >>"$LOG" 2>&1; fi; done < "$STATE/users-new"
    fi
    systemctl daemon-reload
    if [[ -f $STATE/cron-enabled-before ]]; then
        if [[ $(cat "$STATE/cron-enabled-before") == disabled ]]; then systemctl disable cron >>"$LOG" 2>&1; fi
        if [[ $(cat "$STATE/cron-active-before") == inactive ]]; then systemctl stop cron >>"$LOG" 2>&1; fi
    fi
    ! ss -H -lnt 'sport = :443 or sport = :9443' | grep -q . || fail 'Application TCP ports are still in use.'
    ! ss -H -lnu 'sport = :8443' | grep -q . || fail 'Application UDP port is still in use.'
    # Retained TLS has no service or cron entry. Never remove its parent blindly.
    find "$ROOT" -mindepth 1 -maxdepth 1 ! -name tls -exec rm -rf {} +
    rmdir "$ROOT" 2>/dev/null || true
    cleanup_bootstrap
    rm -f "$DEFAULT_ENV"
    rm -f "$ENTRY"
    say 'Success: deployment removed; base tools, isolated TLS runtime and official repository kept.'
}

# ---------- Read-only status, fixed menu and command dispatch ----------
display_version() {
    local raw
    raw=$("$@" 2>&1) || { say 'read failed'; return; }
    awk '!found && match($0,/[0-9]+([.][0-9]+)+/) {print substr($0,RSTART,RLENGTH); found=1} END{exit !found}' <<< "$raw" || say 'read failed'
}
tls_status() {
    local dir version
    if tls_debian12; then
        if dir=$(tls_current); then
            version=$(display_version jq -r .version "$dir/package.json")
            say "TLS  ${version}  conda-forge"
        else say 'TLS  missing or invalid'; fi
    else
        version=$(display_version dpkg-query -W -f='${Version}' libssl3t64)
        say "TLS  ${version}"
    fi
}
status() {
    local s v release_type domain expiry endepoch days certificate=unconfigured renewal=unconfigured
    say "edgekit $EDGEKIT_VERSION"
    for s in xray sing-box nginx; do
        v=absent
        case $s in
            xray)
                if [[ -x $XR_BIN ]]; then
                    v=$(display_version xray_version)
                    release_type=$(xray_release_type "$v" || true)
                    [[ -z $release_type ]] || v+=" ($release_type)"
                fi;;
            sing-box) [[ ! -x $SB_BIN ]] || v=$(display_version singbox_version);;
            nginx) [[ ! -x /usr/sbin/nginx ]] || v=$(display_version nginx_cmd -v);;
        esac
        say "$s  $v  $(systemctl is-active "$s" 2>/dev/null || true)"
    done
    tls_status
    if [[ -f $STATE/domain ]]; then
        domain=$(cat "$STATE/domain")
        if expiry=$(openssl x509 -in "$ROOT/certs/$domain/fullchain.pem" -noout -enddate 2>/dev/null) && endepoch=$(date -d "${expiry#notAfter=}" +%s 2>/dev/null); then
            days=$(( (endepoch - $(date +%s)) / 86400 ))
            certificate="$domain ${days} days remaining"
        else certificate="$domain missing or unreadable"; fi
    fi
    if [[ -f /etc/cron.d/edgekit-acme ]]; then renewal="01:30 $(systemctl is-active cron 2>/dev/null || true)"; fi
    say "Certificate ${certificate}; renewal ${renewal}"
}
menu() {
    local choice sub version
    [[ $EUID == 0 ]] || say 'Management requires root privileges. Run sudo ek.'
    while true; do
        status
        say $'\n1. Update Xray\n2. Update sing-box\n3. Check certificate renewal\n4. Uninstall edgekit\n5. Update edgekit\n6. Update TLS / OpenSSL\n7. Network tuning'
        say "8. $(ssh_guard_label)"
        say '0. Exit'
        read -r -p 'Select an option: ' choice || return 0
        case $choice in
            0) return 0;;
            1)
                while true; do
                    say $'1. Latest published version\n2. Latest release version\n0. Back'
                    read -r -p 'Select a version source: ' sub || return 0
                    case $sub in 0) break;; 1) /bin/bash "$ENTRY" update-xray latest || say "Operation failed (exit code $?)"; break;; 2) /bin/bash "$ENTRY" update-xray release || say "Operation failed (exit code $?)"; break;; *) say 'Invalid input. Try again.';; esac
                done;;
            2) /bin/bash "$ENTRY" update-sing-box || say "Operation failed (exit code $?)";;
            3) /bin/bash "$ENTRY" renew || say "Operation failed (exit code $?)";;
            4) /bin/bash "$ENTRY" uninstall || say "Operation failed (exit code $?)"; [[ -f $STATE/owner ]] || return 0;;
            5)
                if /bin/bash "$ENTRY" update-edgekit; then
                    if version=$(edgekit_file_version "$ENTRY") && [[ $version != "$EDGEKIT_VERSION" ]]; then
                        exec /bin/bash "$ENTRY"
                    fi
                else say "Operation failed (exit code $?)"; fi;;
            6) /bin/bash "$ENTRY" update-tls || say "Operation failed (exit code $?)";;
            7) /bin/bash "$ENTRY" tune-network || say "Operation failed (exit code $?)";;
            8) /bin/bash "$ENTRY" ssh-guard || say "Operation failed (exit code $?)";;
            '') say 'No option selected.'; continue;;
            *) say 'Invalid input. Try again.'; continue;;
        esac
        read -r -p 'Press Enter to return to the menu.' choice || return 0
    done
}
main() {
    # Preserve the caller terminal for failures even inside redirected tool functions.
    exec 3>&2
    local op=${1:-start}; (($# == 0)) || shift
    case $op in
        start) start;;
        install) install_all "$@";;
        status) status;;
        _tls-prepare) root_required; start_log tls-prepare; tls_prepare "$@";;
        _tls-switch) root_required; start_log update-tls; tls_switch "$@";;
        menu) start;;
        renew) renew;;
        deploy-cert) deploy_cert;;
        update-xray) update_xray "$@";;
        update-sing-box) update_singbox "$@";;
        update-edgekit) update_edgekit "$@";;
        update-tls) update_tls "$@";;
        tune-network) tune_network "$@";;
        ssh-guard) ssh_guard "$@";;
        uninstall) uninstall "$@";;
        _load-cert-services) root_required; start_log deploy-cert; validate_certificate "$(cat "$STATE/domain")"; check_configs; systemctl reload nginx; systemctl restart sing-box; verify_services;;
        _proxy-install) root_required; require_install; start_log "update-${1:-proxy}"; proxy_install "$@";;
        --version) say "edgekit $EDGEKIT_VERSION";;
        --help|-h) say 'Usage: ek [install [--env <FILE>] [--staging]] | status | menu | renew | update-xray [latest|release] [--yes] | update-sing-box [--yes] | update-edgekit [--yes] | update-tls [--yes] | tune-network [--yes|--check] | ssh-guard [install|remove] [--yes] | uninstall [--yes] | --version';;
        *) fail 'Unknown command. Use --help for usage.';;
    esac
}
main "$@"
