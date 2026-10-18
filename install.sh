#!/usr/bin/env bash
# vload-sstp installer: builds accel-ppp from the source bundled in this repo
# (vendor/), installs it under /opt/vload-sstp and adds the `sstp` command.
#
# It never touches existing services: no HAProxy/xray/firewall edits, no
# default-route changes, nothing listens on a public address. Every SSTP
# instance binds to 127.0.0.1 and is meant to sit behind an SNI router.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=/opt/vload-sstp
CONF_DIR=/etc/vload-sstp
ACCEL_VER=1.14.0
HEV_VER=2.19.0

log()  { printf '\033[1;32m[vload-sstp]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[vload-sstp] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ "$(uname -m)" = "x86_64" ] || die "only x86_64 is supported (bundled binaries)"
command -v apt-get >/dev/null || die "Debian/Ubuntu (apt) is required"
[ -c /dev/ppp ] || die "/dev/ppp missing: kernel PPP support is required"
[ -c /dev/net/tun ] || die "/dev/net/tun missing: kernel TUN support is required"

log "verifying bundled files"
(cd "$REPO_DIR/vendor" && sha256sum -c SHA256SUMS) || die "bundled files are corrupt"

log "installing build dependencies (new packages only, nothing is upgraded)"
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends --no-upgrade \
    gcc make cmake pkg-config libssl-dev libpcre2-dev openssl iproute2 >/dev/null

log "building accel-ppp $ACCEL_VER from vendor/ (this takes a few minutes)"
BUILD=$(mktemp -d /tmp/vload-sstp-build.XXXXXX)
trap 'rm -rf "$BUILD"' EXIT
tar -xzf "$REPO_DIR/vendor/accel-ppp-$ACCEL_VER.tar.gz" -C "$BUILD"
mkdir -p "$BUILD/out"
(
    cd "$BUILD/out"
    cmake "$BUILD/accel-ppp-$ACCEL_VER" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX/accel" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLIB_SUFFIX= \
        -DRADIUS=FALSE -DSHAPER=FALSE -DLUA=FALSE -DNETSNMP=FALSE -DLOG_PGSQL=FALSE \
        -DBUILD_IPOE_DRIVER=FALSE -DBUILD_VLAN_MON_DRIVER=FALSE -DBUILD_PPTP_DRIVER=FALSE >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
)
# accel-ppp's install also creates an empty /var/log/accel-ppp; keep the system tidy
rmdir /var/log/accel-ppp 2>/dev/null || true
[ -x "$PREFIX/accel/sbin/accel-pppd" ] || die "accel-ppp build failed"

log "installing hev-socks5-tunnel $HEV_VER (bundled)"
install -d "$PREFIX/bin"
install -m 0755 "$REPO_DIR/vendor/hev-socks5-tunnel-$HEV_VER-linux-x86_64" "$PREFIX/bin/hev-socks5-tunnel"

log "installing the sstp command and systemd units"
install -m 0755 "$REPO_DIR/sstp" "$PREFIX/sstp"
ln -sf "$PREFIX/sstp" /usr/local/bin/sstp
install -m 0644 "$REPO_DIR/systemd/vload-sstp@.service" /etc/systemd/system/vload-sstp@.service
install -m 0644 "$REPO_DIR/systemd/vload-sstp-egress.service" /etc/systemd/system/vload-sstp-egress.service
systemctl daemon-reload

log "loading kernel PPP line disciplines"
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
# vload-sstp global settings (edit with: sstp -> Egress settings)
# EGRESS_MODE=socks : client traffic is handed to a local SOCKS5 proxy
#                     (e.g. an xray inbound) through hev-socks5-tunnel
# EGRESS_MODE=nat   : client traffic leaves the VPS directly (masquerade)
EGRESS_MODE=socks
SOCKS_HOST=127.0.0.1
SOCKS_PORT=2063
POOL_PREFIX=10.88
EGRESS_TABLE=188
EGRESS_RULE_PRIO=1888
EOF
fi

log "installed. Run:  sstp"
