# Backhaul One-Command Installer

## XWSMUX Max (safe preview)

`oneclick-xwsmux-max.sh` is the low-jitter Cloudflare profile for the existing
`backhaul_premium` v1.4.0 core. It keeps the deployed XWSMUX wire format, adds
aggressive pool refill, bounded low-latency defaults, safe kernel tuning,
systemd recovery, a session watchdog, preflight validation, and automatic
rollback when a replacement service cannot start.

The Max manager does not overwrite a running configuration until the candidate
configuration has passed the core's parser. Every replacement keeps timestamped
configuration and unit backups.

Interactive installation:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/V2grop/backhaul-oneclick/main/oneclick-xwsmux-max.sh?cb=$(date +%s)")
```

Generate one token and use the exact same value on both servers:

```bash
openssl rand -hex 24
```

Iran/server example:

```bash
bash /root/backhaul_xwsmux_max.sh install server \
  --tunnel-port 8880 \
  --ports '2444=443' \
  --token 'REPLACE_WITH_THE_SHARED_TOKEN'
```

Kharej/client example:

```bash
bash /root/backhaul_xwsmux_max.sh install client \
  --remote 'pak.example.com:8880' \
  --edge '172.67.0.1' \
  --token 'REPLACE_WITH_THE_SHARED_TOKEN'
```

For a no-downtime preview, first use a second Cloudflare-supported HTTP port
such as `2095` and a spare local port such as `2445`. After the preview works,
install the final profile on Iran first and Kharej second.

Default Max profile:

| Setting | Value |
|---|---:|
| Connection pool / mux concurrency | 16 |
| Keepalive | 20 seconds |
| Heartbeat | 5 seconds |
| Retry interval | 1 second |
| Channel size | 8192 |
| Mux frame size | 32768 bytes |
| Mux receive buffer | 8 MiB |
| Aggressive pool refill | enabled |
| Session watchdog | 3 failed checks, 20 seconds apart |

The watchdog is a systemd timer rather than cron, so it can check more often
than once per minute and remains tied to the exact tunnel service.

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
