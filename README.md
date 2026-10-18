# vload-sstp

SSTP VPN server for a VPS that already shares port 443 through an **SNI router**
(HAProxy `mode tcp` + `req_ssl_sni`). Each SSTP client gets its **own SNI and its
own local port** on `127.0.0.1`; your SNI router sends that SNI to that port.

- Server: [accel-ppp](https://github.com/accel-ppp/accel-ppp) 1.14.0, built from the
  source bundled in `vendor/` (nothing is downloaded at install time except the
  Ubuntu build packages `cmake libssl-dev libpcre2-dev`).
- Egress: client traffic is handed to a local SOCKS5 proxy (default
  `127.0.0.1:2063`, e.g. an xray inbound) through the bundled
  [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) 2.19.0,
  or leaves the VPS directly (`sstp egress nat`).
- Safe on a shared VPS: binds only to `127.0.0.1`, never edits HAProxy/xray/the
  firewall, never touches the default route. The only routing it adds is one
  `ip rule` for the client pool (`10.88.0.0/16`).

## Install

```bash
git clone https://github.com/alaaabd90/vload-sstp.git
cd vload-sstp && sudo bash install.sh
sstp
```

## The `sstp` menu

```
1) Enable   2) Disable   3) Add new client   4) Remove client   5) Adjust client
6) Show MikroTik commands for a client   7) Egress settings   8) Uninstall   0) Exit
```

Scriptable equivalents:

```bash
sstp add  <name> <sni> <port> [user] [password]
sstp set  <name> sni=www.example.com port=450 user=u pass=p
sstp remove <name>
sstp show <name>            # prints the MikroTik commands
sstp list | enable | disable
sstp egress socks 127.0.0.1 2063 | sstp egress nat
sstp uninstall
```

## SNI router line (HAProxy example)

```
use_backend bk443_sstp1 if { req_ssl_sni -i www.360.fb.com }
backend bk443_sstp1
    mode tcp
    server srv 127.0.0.1:449
```

## MikroTik

`sstp show <name>` prints ready-to-paste RouterOS 7 commands. RouterOS sends the
`connect-to` host name as the SNI only when `add-sni=yes`. If the SNI is a name that
does not resolve to your VPS, add a static DNS entry on the router (pick a name
nobody on your LAN uses, because the static entry applies to every LAN client).

## Files

| Path | What |
|---|---|
| `/opt/vload-sstp/` | accel-ppp build, hev-socks5-tunnel, the `sstp` script |
| `/etc/vload-sstp/` | global settings and one folder per client (config, certificate, secrets) |
| `/var/log/vload-sstp/` | logs (rotated weekly) |
| `vload-sstp@<client>.service`, `vload-sstp-egress.service` | systemd units |
