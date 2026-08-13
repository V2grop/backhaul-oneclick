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
hostname. The normal foreign installer asks only for that hostname and creates
the UUID, secret path, internal port, XHTTP mode, and a self-signed origin
certificate automatically for Cloudflare `Full`. Optional Let's Encrypt and
existing-certificate choices remain available through `advanced-server`.
Only TCP port mappings are advertised by this first version.

The simple menu uses option `1` for the one-question foreign installation,
option `2` to show the Iran command again, and option `3` for numbered deletion
with one confirmation. It does not ask users to type a role, instance name,
UUID, path, internal port, or XHC1 code during the normal workflow.

For the normal Iran installation, manual setup-code entry is no longer needed.
After the foreign endpoint starts, it prints one complete cache-busted command.
Paste that whole command on the Iran server; the automatic workflow transfers
the private XHTTP settings internally and asks only for
`CLEAN_CLOUDFLARE_IP` and `IRAN_PORT=FOREIGN_SERVICE_PORT`. The command is also
saved root-only and can always be rebuilt from the installed configuration by
choosing menu option `2` or running `xhttp-cdn-manager iran-command`.

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
