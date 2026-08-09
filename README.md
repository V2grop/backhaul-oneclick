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
| V2Quantum | Independent MIT-licensed Go core | FusionMux failover, TCP, adaptive Quantum v2 UDP with SACK/multi-parity FEC, experimental Raw ICMP spoof/BIP and separate encrypted L3 TUN |
| Dagger External/Local | Independent third-party local bundle | Verifies operator-supplied `setup.sh` and binary by SHA256, then runs the original setup copy unchanged |
| Realm | External open-source Realm manager | TCP and UDP layer-4 port forwarding |

Backhaul and V2Quantum do not use the Dagger engine. The Dagger menu item is an
explicit, separate local adapter: neither third-party file is stored or
downloaded by this repository. Backhaul remains the existing core selected by
the server owner and is deliberately not rewritten by the launcher. V2Quantum
user mappings are TCP; `quantum_udp` describes its carrier. Use Realm when a
separate UDP port forward is required.

After choosing the shortcut-install item, the same manager can be opened later with:

```bash
tunnel-manager
```

Useful direct actions:

```bash
tunnel-manager --backhaul
tunnel-manager --xwsmux-max
tunnel-manager --v2quantum
tunnel-manager --fusion
tunnel-manager --tun
tunnel-manager --dagger-local
tunnel-manager --realm
tunnel-manager --status
```

### Independent Dagger local adapter

The universal menu's option `3` opens `oneclick-dagger-local.sh`. The adapter
does not contain, modify or download Dagger. Copy the two files you are
authorized to use onto the server, then select option `3` and enter their local
paths. The currently recognized bundle fingerprints are:

```text
setup.sh:                    1f8893c74381bc84b73bdc1f68dadc2f8f39c1ce5b66402d71f77f5394535ad3
DaggerConnect3.2.patched:    ac19385f703c9db5bf3bb50c66fe874f53478d307f31f3fc6defc74c49ffddbc
```

Direct non-interactive path selection is also available:

```bash
DAGGER_SETUP_PATH=/root/setup.sh \
DAGGER_BINARY_PATH=/root/DaggerConnect3.2.patched \
tunnel-manager --dagger-local
```

The adapter verifies the source files, re-verifies private temporary copies and
automatically supplies the verified temporary binary path when the original
setup asks for it. The original setup remains responsible for Dagger services
and configs. Do not select its `System Optimizer` when strict isolation is
required: that third-party action changes host-wide sysctl and qdisc settings
and can affect every network service on the server.

Compatibility bootstrap for the complete manager (all previous engines remain
available):

```bash
bash <(curl -fsSL --ipv4 https://raw.githubusercontent.com/V2grop/backhaul-oneclick/main/fusionmux-oneclick.sh)
```

Add `--fusion` after the command only when the dedicated FusionMux submenu is
desired. In the normal V2Quantum manager, Iran option `1` now lists TCP,
Quantum UDP, Raw ICMP and FusionMux as four separate transports; outside option
`2` accepts both `V2Q...` and `V2F1_...` setup codes. No existing tunnel family
is removed or merged.

Every new V2Quantum/FusionMux/V2TUN tunnel receives a distinct name, JSON configuration,
token file, systemd instance, health port and watchdog state. Creating a second
tunnel therefore does not replace the first one. Setup codes use `V2Q3_` for
single-carrier reverse TCP mappings, `V2F1_` for Quantum/WebSocket/TCP FusionMux,
and `V2T2_` for the independent point-to-point TUN. The
manager accepts the older prefixes for migration, but both peers must run the
new core before using the Quantum v2 wire protocol.

FusionMux keeps all three authenticated paths hot. Quantum UDP is primary,
WebSocket/WSS is the first standby and direct TCP is the final fallback. Logical
streams carry byte offsets and cumulative acknowledgements, so unacknowledged
data can be replayed and deduplicated on another path while the user's existing
TCP connection remains open. This is failover, not bandwidth aggregation.

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
