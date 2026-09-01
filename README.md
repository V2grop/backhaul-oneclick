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
| XHTTP CDN | Isolated official Xray core | Direct or reverse endpoint/peer over Cloudflare XHTTP, TCP/UDP/both mappings, private SOCKS, full IPv4 TUN, native XMUX, clean edge IPv4, automatic origin certificate, pairing code and dedicated Nginx snippet |
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
tunnel-manager --xhttp-reverse
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

### XHTTP direct and reverse, with simple names

There are two symmetric choices:

| Model | Endpoint (runs Nginx/Xray server) | Peer (runs Xray client and user listeners) |
|---|---|---|
| Direct | Usually `FOREIGN_SERVER_IP` | Usually `IRAN_SERVER_IP` |
| Reverse | Usually `IRAN_SERVER_IP` | Usually `FOREIGN_SERVER_IP` |

On the endpoint's easy screen enter only `CDN_HOSTNAME`. It generates the UUID,
secret `XHTTP_PATH`, private `ORIGIN_PORT`, certificate and native XHTTP XMUX.
Copy the one complete pairing command to the peer. The peer normally asks only
for `CLEAN_CLOUDFLARE_IP`; if the endpoint did not embed a mapping it asks for
`LOCAL_PORT=REMOTE_TARGET_PORT` (for example `2444=8444`).

The profile selector is intentionally short:

| `TRAFFIC_SCOPE` | What is carried through the two-server XHTTP link |
|---|---|
| `ports` | TCP/UDP/both port mappings (`tcp:2444=8444,udp:5353=53`) |
| `socks` | Private no-auth SOCKS listener (`SOCKS_BIND`/`SOCKS_PORT`) |
| `tun` | Full IPv4 packet tunnel on a named TUN (`TUN_NAME`, `TUN_GATEWAY`, `TUN_MTU`, `TUN_DNS`) |
| `all` | All three inbounds at once |

`EDGE_PORT` defaults to 443 and accepts Cloudflare's proxied ports
`2053,2083,2087,2096,8443` as well. Native XHTTP XMUX is used in
`xhttpSettings.extra`; the legacy top-level `mux` field is not used. Every
generated unit runs Xray's configuration preflight, and failed replacements
restore the previous config/Nginx/metadata state. A small per-instance
watchdog timer restarts a stopped service.

The XHTTP menu uses option `1` for easy direct endpoint, `9` for easy reverse
endpoint, `2` to rebuild the peer command, and `10` for advanced profiles. The
CLI aliases are `peer-command`, `reverse-server`, `easy-reverse-client` and
`watchdog`; `iran-command` remains a compatibility alias.

For simultaneous direct and reverse links, create two instances with different
`INSTANCE_NAME`, `CDN_HOSTNAME` and `XHTTP_PATH`; each instance has its own
service, metadata and watchdog files.

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

Choose `8) XHTTP CDN` for the profile menu or `9) XHTTP reverse endpoint` for
the one-question reverse shortcut. The universal launcher forwards the choice
to the isolated XHTTP manager without touching the other tunnel engines.

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
