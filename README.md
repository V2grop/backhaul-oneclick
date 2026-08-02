# Backhaul One-Command Installer

## Universal Tunnel Manager

`oneclick-universal.sh` is the single public entry point for all supported
tunnel managers. It does not replace a working tunnel and it does not download
an engine until that engine is selected from the menu.

Public command after this branch is merged into `main`:

```bash
bash <(curl -fsSL --ipv4 https://raw.githubusercontent.com/V2grop/backhaul-oneclick/main/oneclick-universal.sh)
```

The unified menu contains one Backhaul submenu (Standard and XWSMUX Max are
grouped together instead of appearing as duplicate top-level engines):

| Menu | Engine | Modes |
|---|---|---|
| Backhaul | Existing `backhaul_premium` core | TCP, TCPMUX, XTCPMUX, WS, WSS, WSMUX, WSSMUX, XWSMUX, AnyTLS, TUN |
| XWSMUX Max | Existing optimized Backhaul profile | Cloudflare XWSMUX, automatic Iran token, watchdog and rollback |
| V2Quantum | Independent MIT-licensed Go core | TCP, Quantum UDP carrier, experimental Raw ICMP spoof/BIP |
| Realm | External open-source Realm manager | TCP and UDP layer-4 port forwarding |

The launcher itself, V2Quantum and Realm do not use Pengu or Dagger licensed
binaries. Backhaul remains the existing core selected by the server owner and
is deliberately not rewritten by the launcher. V2Quantum user mappings are TCP;
`quantum_udp` describes its carrier. Use Realm when a separate UDP port forward
is required.

After choosing menu item 6, the same manager can be opened later with:

```bash
tunnel-manager
```

Useful direct actions:

```bash
tunnel-manager --backhaul
tunnel-manager --xwsmux-max
tunnel-manager --v2quantum
tunnel-manager --realm
tunnel-manager --status
```

Raw spoof/BIP cannot bypass BCP38 or a provider anti-spoofing policy. It works
only with addresses and routes authorized on both servers; the V2Quantum
preflight reports the local prerequisites before the service is used.

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
