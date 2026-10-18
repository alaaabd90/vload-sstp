#!/usr/bin/env bash
# vload-sstp installer / updater.
#
# One command, for a fresh VPS or one that already has vload-sstp:
#   bash <(curl -fsSL https://raw.githubusercontent.com/alaaabd90/vload-sstp/main/install.sh)
#
# Everything it installs comes from this repository: accel-ppp is built from the
# source bundled in vendor/, hev-socks5-tunnel is the bundled static binary.
# Existing clients and settings in /etc/vload-sstp are always kept.
#
# It never touches existing services: no HAProxy/xray/firewall edits, no
# default-route changes, nothing listens on a public address. Every SSTP
# instance binds to 127.0.0.1 and is meant to sit behind an SNI router.
set -euo pipefail

REPO_TARBALL=https://codeload.github.com/alaaabd90/vload-sstp/tar.gz/refs/heads/main
PREFIX=/opt/vload-sstp
CONF_DIR=/etc/vload-sstp
ACCEL_VER=1.14.0
HEV_VER=2.19.0
FORCE_BUILD=0
[ "${1:-}" = "--force-build" ] && FORCE_BUILD=1

log()  { printf '\033[1;32m[vload-sstp]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[vload-sstp] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"

# --- bootstrap: when run without the repo next to it (e.g. via curl), fetch the repo ---
SELF="${BASH_SOURCE[0]:-}"
REPO_DIR=""
if [ -n "$SELF" ] && [ -f "$SELF" ]; then REPO_DIR="$(cd "$(dirname "$SELF")" && pwd)"; fi
if [ -z "$REPO_DIR" ] || [ ! -f "$REPO_DIR/vendor/SHA256SUMS" ]; then
    command -v curl >/dev/null || { apt-get -o DPkg::Lock::Timeout=600 install -y curl >/dev/null; }
    log "downloading the vload-sstp repository"
    TMP=$(mktemp -d /tmp/vload-sstp-src.XXXXXX)
    curl -fsSL "$REPO_TARBALL" | tar -xz -C "$TMP" --strip-components=1 || die "download failed"
    exec bash "$TMP/install.sh" "$@"
fi

[ "$(uname -m)" = "x86_64" ] || die "only x86_64 is supported (bundled binaries)"
command -v apt-get >/dev/null || die "Debian/Ubuntu (apt) is required"
[ -c /dev/ppp ] || die "/dev/ppp missing: kernel PPP support is required"
[ -c /dev/net/tun ] || die "/dev/net/tun missing: kernel TUN support is required"

log "verifying bundled files"
(cd "$REPO_DIR/vendor" && sha256sum -c --quiet SHA256SUMS) || die "bundled files are corrupt"

UPDATE=0; [ -x "$PREFIX/accel/sbin/accel-pppd" ] && UPDATE=1
[ "$UPDATE" -eq 1 ] && log "existing installation found: updating (clients and settings are kept)"

# keep a copy of the repo for reinstall/update
install -d "$PREFIX"
if [ "$REPO_DIR" != "$PREFIX/repo" ]; then
    rm -rf "$PREFIX/repo.new"; cp -a "$REPO_DIR" "$PREFIX/repo.new"
    rm -rf "$PREFIX/repo"; mv "$PREFIX/repo.new" "$PREFIX/repo"
fi

# --- accel-ppp (built from vendor/ only when missing or a different version) ---
if [ "$FORCE_BUILD" -eq 1 ] || [ "$(cat "$PREFIX/accel/.version" 2>/dev/null)" != "$ACCEL_VER" ]; then
    log "installing build dependencies (new packages only, nothing is upgraded)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends --no-upgrade \
        gcc make cmake pkg-config libssl-dev libpcre2-dev openssl iproute2 iptables >/dev/null
    log "building accel-ppp $ACCEL_VER from vendor/ (takes a few minutes)"
    BUILD=$(mktemp -d /tmp/vload-sstp-build.XXXXXX)
    trap 'rm -rf "$BUILD"' EXIT
    tar -xzf "$REPO_DIR/vendor/accel-ppp-$ACCEL_VER.tar.gz" -C "$BUILD"
    mkdir -p "$BUILD/out"
    (
        cd "$BUILD/out"
        cmake "$BUILD/accel-ppp-$ACCEL_VER" \
            -DCMAKE_INSTALL_PREFIX="$PREFIX/accel" \
            -DCMAKE_BUILD_TYPE=Release -DLIB_SUFFIX= \
            -DRADIUS=FALSE -DSHAPER=FALSE -DLUA=FALSE -DNETSNMP=FALSE -DLOG_PGSQL=FALSE \
            -DBUILD_IPOE_DRIVER=FALSE -DBUILD_VLAN_MON_DRIVER=FALSE -DBUILD_PPTP_DRIVER=FALSE >/dev/null 2>&1
        make -j"$(nproc)" >/dev/null 2>&1 || { echo "build failed, re-running for the error:" >&2; make 2>&1 | tail -20 >&2; exit 1; }
        # running instances keep the old files open until they are restarted below
        rm -rf "$PREFIX/accel"
        make install >/dev/null 2>&1
    )
    rmdir /var/log/accel-ppp 2>/dev/null || true   # accel-ppp's install creates an empty one
    [ -x "$PREFIX/accel/sbin/accel-pppd" ] || die "accel-ppp build failed"
    echo "$ACCEL_VER" > "$PREFIX/accel/.version"
else
    log "accel-ppp $ACCEL_VER already installed"
fi

# --- SOCKS tunnel (hev-socks5-tunnel), installed from vendor/ when missing or outdated ---
if [ "$(cat "$PREFIX/bin/.hev-version" 2>/dev/null)" != "$HEV_VER" ] || [ ! -x "$PREFIX/bin/hev-socks5-tunnel" ]; then
    log "installing hev-socks5-tunnel $HEV_VER from vendor/"
    install -d "$PREFIX/bin"
    install -m 0755 "$REPO_DIR/vendor/hev-socks5-tunnel-$HEV_VER-linux-x86_64" "$PREFIX/bin/hev-socks5-tunnel.new"
    mv -f "$PREFIX/bin/hev-socks5-tunnel.new" "$PREFIX/bin/hev-socks5-tunnel"
    echo "$HEV_VER" > "$PREFIX/bin/.hev-version"
else
    log "hev-socks5-tunnel $HEV_VER already installed"
fi

log "installing the sstp command and systemd units"
install -m 0755 "$REPO_DIR/sstp" "$PREFIX/sstp"
ln -sf "$PREFIX/sstp" /usr/local/bin/sstp
install -m 0644 "$REPO_DIR/systemd/vload-sstp@.service" /etc/systemd/system/vload-sstp@.service
install -m 0644 "$REPO_DIR/systemd/vload-sstp-egress.service" /etc/systemd/system/vload-sstp-egress.service
systemctl daemon-reload

printf 'ppp_synctty\nppp_async\nn_hdlc\n' > /etc/modules-load.d/vload-sstp.conf
for m in ppp_synctty ppp_async n_hdlc; do modprobe "$m" 2>/dev/null || true; done

install -d -m 0700 "$CONF_DIR" "$CONF_DIR/clients"
install -d /var/log/vload-sstp
cat > /etc/logrotate.d/vload-sstp <<'EOF'
/var/log/vload-sstp/*.log {
    weekly
    rotate 4
    size 5M
    compress
    missingok
    notifempty
    copytruncate
}
EOF
if [ ! -f "$CONF_DIR/vload-sstp.conf" ]; then
    cat > "$CONF_DIR/vload-sstp.conf" <<'EOF'
# vload-sstp global settings (change with: sstp -> Change SOCKS proxy / Egress mode)
# EGRESS_MODE=socks : client traffic goes to a local SOCKS5 proxy (default: the
#                     3x-ui/xray inbound on 127.0.0.1:2063 that routes to reverse-9)
# EGRESS_MODE=nat   : client traffic leaves the VPS directly (masquerade)
EGRESS_MODE=socks
SOCKS_HOST=127.0.0.1
SOCKS_PORT=2063
POOL_PREFIX=10.88
EGRESS_TABLE=188
EGRESS_RULE_PRIO=1888
EOF
fi

if [ "$UPDATE" -eq 1 ]; then
    log "re-applying client configs and restarting running services"
    /usr/local/bin/sstp _reapply || true
fi

log "done. Run:  sstp"
