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
| XHTTP CDN | Isolated official Xray core | Iran-side TCP mappings over Cloudflare XHTTP, clean edge IPv4, automatic origin certificate, TLS SNI/Host, setup code and dedicated Nginx snippet |
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
`/opt/xhttp-cdn/bin/xray`, configurations under `/etc/xhttp-cdn`, services named
`xhttp-cdn-*`, and a dedicated Nginx server block for an unused Cloudflare
hostname. It does not edit `/etc/xray`, X-UI, Backhaul, V2Quantum, Realm, or an
existing Nginx server block. On the Iran node the dial address is the selected
clean Cloudflare IPv4, while TLS SNI and the XHTTP Host remain the proxied
hostname. The foreign installer offers automatic Let's Encrypt issuance and
renewal through a locally entered, zone-restricted Cloudflare `Zone:DNS:Edit`
token; a no-token self-signed option for Cloudflare `Full`; or an existing
certificate. The token is kept in a root-only file and is not written to Xray
or Nginx configuration. Only TCP port mappings are advertised by this first
version.

The XHTTP manager now presents the setup as two explicit guided steps: option
`1` runs on the foreign server and option `2` runs on the Iran server. Its
prompts consistently distinguish `FOREIGN_SERVER_IP`, `IRAN_SERVER_IP`, and
`CLEAN_CLOUDFLARE_IP`, explain mappings as
`IRAN_PORT=FOREIGN_SERVICE_PORT`, and print the complete connection route after
installation. Run `xhttp-cdn-manager guide` to display the same quick guide
without changing any service.

Every new V2Quantum/V2TUN tunnel receives a distinct name, JSON configuration,
token file, systemd instance, health port and watchdog state. Creating a second
tunnel therefore does not replace the first one. Setup codes use `V2Q3_` for
reverse TCP mappings and `V2T2_` for the independent point-to-point TUN. The
manager accepts the older prefixes for migration, but both peers must run the
new core before using the Quantum v2 wire protocol.

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
