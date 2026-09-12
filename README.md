# Backhaul One-Command Installer

## Universal Tunnel Manager

`oneclick-universal.sh` is the single public entry point for all supported
tunnel managers. It does not replace a working tunnel and it does not download
an engine until that engine is selected from the menu.

Public command after this branch is merged into `main`:

```bash
bash <(curl -fsSL --ipv4 https://raw.githubusercontent.com/V2grop/backhaul-oneclick/main/oneclick-universal.sh)
```

The unified menu contains one tunnel-family submenu. Standard Backhaul,
XWSMUX Max and the independent V2TUN entry are grouped instead of appearing as
duplicate top-level engines:

| Menu | Engine | Modes |
|---|---|---|
| Backhaul | Existing `backhaul_premium` core | TCP, TCPMUX, XTCPMUX, WS, WSS, WSMUX, WSSMUX, XWSMUX and AnyTLS |
| XWSMUX Max | Existing optimized Backhaul profile | Cloudflare XWSMUX, automatic Iran token, 15-second transport watchdog, staged recovery and rollback |
| V2Quantum | Independent MIT-licensed Go core | TCP, adaptive Quantum v2 UDP with SACK/multi-parity FEC, experimental Raw ICMP spoof/BIP and separate encrypted L3 TUN |
| XHTTP CDN | Isolated official Xray core | Direct Iran-to-Foreign tunnel over Cloudflare XHTTP, TCP/UDP/both mappings, private SOCKS, full IPv4 TUN, native XMUX, clean edge IPv4, automatic origin certificate, pairing code and dedicated Nginx snippet |
| Realm | External open-source Realm manager | TCP and UDP layer-4 port forwarding |

The launcher itself, V2Quantum and Realm do not use Pengu or Dagger licensed
binaries. Backhaul remains the existing core selected by the server owner and
is deliberately not rewritten by the launcher. V2Quantum user mappings are TCP;
`quantum_udp` describes its carrier. Use Realm when a separate UDP port forward
is required.

After choosing the shortcut-install item, the same manager can be opened later with:

```bash
tunnel-manager
```

Useful direct actions:

```bash
tunnel-manager --backhaul
tunnel-manager --xwsmux-max
tunnel-manager --v2quantum
tunnel-manager --tun
tunnel-manager --xhttp-cdn
tunnel-manager --realm
tunnel-manager --status
```

The XHTTP CDN option is additive and isolated. It installs its own binary at
`/opt/xhttp-cdn/bin/xray`, configurations and metadata under `/etc/xhttp-cdn`,
services named `xhttp-cdn-*`, watchdog timers, and a dedicated Nginx server
block for an unused Cloudflare hostname. It does not edit `/etc/xray`, X-UI,
Backhaul, V2Quantum, Realm, or an existing Nginx server block. The peer dials
the selected `CLEAN_CLOUDFLARE_IP`, while TLS SNI and HTTP Host remain the
proxied `CDN_HOSTNAME`.

### XHTTP Direct: Foreign first, Iran second

The XHTTP manager is English-only. Direct means the **Iran server initiates**
the connection through Cloudflare to the **Foreign server**. The setup order is
Foreign first, then Iran. Reverse setup and launcher shortcuts have been removed.
Existing Reverse services are not stopped automatically: remove them explicitly
using option 7, then create a Direct installation on the correct servers.

| Label | Where it belongs | Example |
|---|---|---|
| `FOREIGN_SERVER_IP` | Cloudflare DNS A record for the tunnel hostname | Your Foreign public IPv4 |
| `IRAN_SERVER_IP` | Address users connect to | Your Iran public IPv4 |
| `CLEAN_CLOUDFLARE_IP` | Dial address entered on Iran; not either server's IP | A Cloudflare edge reachable from Iran |
| **Port IR** | User-facing listener on Iran | `2444` |
| **Port Foreign** | Existing destination application on Foreign | `8444` |
| **Port Foreign Tunnel** | Foreign Nginx TLS listener | `443` |
| **Port Foreign Internal** | Foreign Xray loopback listener; keep private | `18080` |

1. On **Foreign**, open XHTTP and choose **1**. Enter a dedicated Cloudflare
   hostname, then `CLOUDFLARE_TUNNEL_PORT` (default `443`). Non-443 TLS ports
   automatically select packet-up. UUID, path and the origin certificate are automatic.
2. Point that hostname's proxied DNS record to `FOREIGN_SERVER_IP`. Use
   Cloudflare SSL/TLS **Full** for the automatic self-signed origin certificate;
   enable **Network > gRPC**. Allow inbound TCP/443 to Foreign Nginx.
3. On **Iran**, run the same updated script and choose **2**. Paste the setup code
   or complete command printed on Foreign. Pasted commands are parsed as data.
4. Enter the reachable Cloudflare IPv4, **Port IR**, **Port Foreign**, and protocol
   (`tcp`, `udp`, or `both`). Each question names the server. Add more mappings
   when prompted. Allow the selected Port IR/protocol on the Iran firewall.
5. Your destination application must already listen on `127.0.0.1:Port Foreign`
   or another target selected through Advanced Iran setup. Users connect to
   `IRAN_SERVER_IP:Port IR`.

For example, `Port IR = 2444` and `Port Foreign = 8444` deliver connections to
`127.0.0.1:8444` **on Foreign**. Port 443 is already used by Nginx; do not use
that same port for the destination application. The manager rejects loopback
mappings that feed back into its Nginx or Xray listener.

| XHTTP menu | Action |
|---|---|
| 1 | **Foreign**: create Direct endpoint |
| 2 | **Iran**: connect with Foreign setup code |
| 3 | **Foreign**: recover Iran setup code |
| 4 | List XHTTP services |
| 5 | Diagnose connection and show recent logs |
| 6 | Restart one XHTTP service |
| 7 | Remove one XHTTP installation |
| 8 | Advanced **Foreign** profiles, certificates and extra instances |
| 9 | Update isolated Xray core |
| 10 | Update XHTTP manager |
| 11 | Setup guide |
| 0 | Exit |

Advanced profiles remain available: `ports` for TCP/UDP mappings, `socks` for a
private Iran SOCKS proxy, `tun` for Iran IPv4 routing, and `all` for all three.
Advanced mappings use `tcp:2444=8444,udp:5353=53` (**Port IR=Port Foreign**).
For TUN, the physical outbound interface is detected to prevent routing the
control connection into its own tunnel. Override it only when necessary with
`XHTTP_CDN_TUN_OUTBOUND_INTERFACE`.

`auto` lets the pinned core select its XHTTP mode over TLS/H2. Explicit
`stream-up` is also supported. This manager uses port 443 for both, to support
the gRPC path. Stream-up connections
require port 443 on Cloudflare, per its gRPC requirements. `packet-up` uses an
HTTP upstream in Nginx and permits Cloudflare's other supported TLS ports.
Native XMUX is used; no additional legacy mux layer is enabled.

The bundled default is **Xray v26.9.9**, an upstream **pre-release**, pinned for
reproducibility and tested with this manager. Set `XHTTP_CDN_XRAY_VERSION` to an
explicit compatible version if needed; both servers should use the same version.
Downloads are checked against the official SHA-256 digest. Changing versions
should be tested before updating a working installation.

The original server configuration used an unrestricted-looking `freedom`
outbound without explicit rules. Recent Xray versions still block private
VLESS destinations by default, including the default `127.0.0.1` target.
This causes a connected tunnel to stall with `blocked target` in the logs.
The corrected server explicitly allows authenticated forwarding to **127.0.0.1**,
while blocking its own Nginx and Xray listener ports to prevent loops. Other
private IP ranges retain Xray's default policy; a LAN target needs its own
explicit, narrowly scoped Foreign `finalRules` allow rule. Keep pairing codes
private because they authorize access to local services.

Diagnosis distinguishes TLS/network failures, HTTP/2 negotiation, wrong origin
responses, Cloudflare 403, upstream 502/504, unreachable origins 521-523, and
certificate errors 525/526. A secret-path, non-cacheable marker verifies that
the requested Foreign Nginx origin was reached. It does **not** authenticate a
complete VLESS session or prove the destination application is reachable.
Old endpoints without the marker must be updated on Foreign before that check
can pass. Existing Direct XHC1/XHC2 pairing codes remain readable.

The watchdog restarts stopped services; it is not an end-to-end network monitor.
Use option 5 on both servers when investigating a failed connection. Remote
firewalls, Cloudflare policy and Iranian network reachability require live tests
on the actual servers.

For a downloaded copy, run `sudo bash oneclick-xhttp-cdn.sh` on **both** servers
and transfer the **setup code** using menu option 2. Download commands printed
by the manager require the updated files to have been published to the selected
repository/ref first. Until then, use the downloaded script on both sides.
The selected branch is saved for subsequent updates and pairing commands.

References:
- [Xray v26.9.9 release](https://github.com/XTLS/Xray-core/releases/tag/v26.9.9)
- [Freedom private-target policy](https://xtls.github.io/en/config/outbounds/freedom.html)
- [XHTTP transport discussion](https://github.com/XTLS/Xray-core/discussions/4113)
- [Cloudflare gRPC requirements](https://developers.cloudflare.com/network/grpc-connections/)

Tests:

```bash
bash tests/test-xhttp-cdn.sh
bash tests/test-xhttp-direct.sh
bash v2quantum-go/tests/test-universal.sh
XRAY_TEST_BIN=/path/to/xray NGINX_TEST_BIN=/path/to/nginx python3 tests/test-xhttp-integration.py
```

The integration test uses loopback-only listeners and a test certificate to
exercise real Xray and Nginx, concurrent TCP streams and UDP. It does not
install services, edit system configuration, or require a Cloudflare account.

Every new V2Quantum/V2TUN tunnel receives a distinct name, JSON configuration,
token file, systemd instance, health port and watchdog state. Creating a second
tunnel therefore does not replace the first one. Setup codes use `V2Q3_` for
reverse TCP mappings and `V2T2_` for the independent point-to-point TUN. The
manager accepts the older prefixes for migration, but both peers must run the
new core before using the Quantum v2 wire protocol.

An Iran-side V2TUN can now own an isolated TCP DNAT/SNAT forward such as
`443=443`. Existing TUNs can add, change or remove it from TUN menu option `6`
without recreation or a new setup code. Its per-instance systemd service
removes only its own firewall rules when the TUN stops or is deleted.

Use the same Universal Tunnel Manager on both V2TUN peers. On this branch the
single entry command is:

```bash
TUNNEL_MANAGER_REF=codex/v2quantum-go-v1 bash <(curl -fsSL --ipv4 "https://raw.githubusercontent.com/V2grop/backhaul-oneclick/codex/v2quantum-go-v1/oneclick-universal.sh?cb=$(date +%s)")
```

Choose `1) Backhaul family`, then `3) V2TUN`. The older
`install-v2tun.sh` URL remains only as a backward-compatible helper and is no
longer the recommended entry point.

The XHTTP branch can be opened directly on either server with:

```bash
TUNNEL_MANAGER_REF=codex/v2quantum-go-v1 bash <(curl -fsSL --ipv4 "https://raw.githubusercontent.com/V2grop/backhaul-oneclick/codex/v2quantum-go-v1/oneclick-universal.sh?cb=$(date +%s)")
```

Choose `8) XHTTP Direct - Foreign setup / Iran setup`.

The legacy TUN fields exposed by some opaque Backhaul builds are not advertised
as working. The menu's supported L3 option is the source-built V2TUN core; it
uses `/dev/net/tun`, `CAP_NET_ADMIN`, a non-persistent per-instance interface,
encrypted frames and TCP or Quantum UDP as its outer carrier.

Raw setup offers an assigned-IP ICMP scanner, authorized manual entry, or a
real-IP-only mode. The automatic scanner ranks only addresses assigned to the
server; it never scans or selects third-party websites. Raw spoof/BIP cannot
bypass BCP38 or a provider anti-spoofing policy and works only with addresses
and routes authorized on both servers.

فایل‌های زیر را در ریشه ریپو قرار دهید:

```text
install.sh
backhaul_easy_installer.sh
backhaul_premium
README.md
```

داخل `install.sh` این خط را با نام کاربری و نام ریپو عوض کنید:

```bash
GITHUB_REPO="YOUR_GITHUB_USERNAME/YOUR_REPOSITORY"
```

سپس نصب تعاملی:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPOSITORY/main/install.sh)
```

نصب مستقیم سمت ایران:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPOSITORY/main/install.sh) \
  install server --tunnel-port 2095 --ports '2444=443' --pool 8
```

نصب مستقیم سمت خارج:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPOSITORY/main/install.sh) \
  install client --tunnel-port 2095 --remote vip.example.com:2095 --pool 8
```

> اگر `backhaul_premium` یا `backhaul_easy_installer.sh` را تغییر دادید، SHA256های داخل `install.sh` را نیز به‌روزرسانی کنید:
>
> ```bash
> sha256sum backhaul_premium backhaul_easy_installer.sh
> ```

### Explicit port labels (v3.0.1)

| Prompt | Enter on | Meaning | Example |
|---|---|---|---|
| `CLOUDFLARE_TUNNEL_PORT` | Foreign only | Cloudflare edge and Foreign Nginx TLS port; carried to Iran in the code | 443 |
| `CLOUDFLARE_EDGE_IP` | Iran | Reachable Cloudflare IPv4 address, not a port | Your tested Cloudflare IP |
| `CLIENT_PORT_IR` | Iran | Port users connect to on Iran | 2444 |
| `SERVICE_PORT_FOREIGN` | Iran | Existing application port on Foreign | 8444 |

`CLIENT_PORT_IR` can equal `CLOUDFLARE_TUNNEL_PORT` because they run on
different servers. The Foreign application port cannot equal the Foreign
Nginx or internal Xray port. Simple setup forwards only the selected client
ports; it does not change the server's default route.
