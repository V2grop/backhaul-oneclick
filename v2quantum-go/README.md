# V2Quantum-Go

هسته‌ای مستقل و بدون لایسنس برای Reverse Tunnel است که با Go و فقط با کتابخانه استاندارد نوشته شده است. این پروژه از کد یا باینری Pengu، Dagger یا Backhaul استفاده نمی‌کند و با پروتکل آن‌ها نیز wire-compatible نیست. پوشه و سرویس‌های Backhaul/WSMUX را تغییر نمی‌دهد.

## قابلیت‌ها

- Reverse TCP forwarding با چند mapping نام‌دار و محدودشده؛ سرور نمی‌تواند مقصد دلخواه روی کلاینت باز کند.
- سه carrier مستقل: `tcp`، `quantum_udp` و `raw_icmp` آزمایشی.
- Multiplex چند صد stream روی pool اتصال‌ها با انتخاب کم‌بارترین session.
- احراز هویت دوطرفه PSK با nonce تصادفی و HMAC-SHA256.
- رمزنگاری تمام frameها با AES-256-GCM، کلید جدا برای هر جهت و counter ضد replay/order.
- Quantum UDP با cookie بدون state، پنجره ۱۲۸ بسته، ACK تجمعی، reorder، retransmit و timeout.
- reconnect با exponential backoff و jitter، keepalive داخلی و راه‌اندازی مجدد توسط systemd.
- health endpoint روی `127.0.0.1:9090/healthz` و metrics سازگار با Prometheus روی `/metrics`.
- Raw ICMP با packet IPv4 واقعی، checksum، `IP_HDRINCL`، تنظیم interface، MTU و source/destination override کنترل‌شده.
- تولید خودکار توکن در سمت ایران و منوی ساده با پذیرش `y` یا `Y`.

## انتخاب carrier

| حالت | کاربرد | نیاز شبکه | وضعیت |
|---|---|---|---|
| `tcp` | بیشترین سازگاری و پایداری | یک پورت TCP | Production |
| `quantum_udp` | مسیرهایی که UDP بهتر از TCP جواب می‌دهد | یک پورت UDP | Production |
| `raw_icmp` | شبکه آزمایشی، BIP یا مسیر ICMP مجاز | root/CAP_NET_RAW و ICMP دوطرفه | Experimental |

برای شروع `quantum_udp` را امتحان کنید و اگر packet loss داشتید `tcp` را انتخاب کنید. Raw ICMP الزاماً ping را پایین نمی‌آورد و نتیجه به route، فیلترینگ ICMP و سیاست دیتاسنتر بستگی دارد.

## Build و تست

Go 1.24 یا جدیدتر پیشنهاد می‌شود:

```bash
make check
make race
make build
./bin/v2quantum version
```

ساخت release برای Linux amd64 و arm64:

```bash
make release VERSION=0.1.0
```

## نصب ساده

از داخل همین پوشه:

```bash
sudo ./scripts/install.sh
sudo v2quantum-manager
```

بعد از انتشار Release، نصب مستقیم روی سرور بدون نیاز به Go:

```bash
bash <(curl -fsSL --ipv4 https://raw.githubusercontent.com/V2grop/backhaul-oneclick/main/v2quantum-go/scripts/install-remote.sh)
```

ترتیب پیشنهادی:

1. روی سرور ایران گزینه `1` را بزنید، carrier و پورت را انتخاب کنید. توکن ۶۴کاراکتری خودکار ساخته و در پایان چاپ می‌شود.
2. همان توکن را روی سرور خارج در گزینه `2` paste کنید.
3. برای نمونه، mapping ایران را `0.0.0.0:2444` و target خارج را `127.0.0.1:2444` بگذارید.
4. در firewall فقط carrier را باز کنید: `8880/tcp` برای TCP یا `8880/udp` برای Quantum. پورت `2444/tcp` نیز باید برای کاربران روی ایران باز باشد.

مدیر سرویس از `v2quantum@iran.service` و `v2quantum@outside.service` استفاده می‌کند. systemd با `Restart=always` جای cron را می‌گیرد و در صورت crash یا قطع carrier، کلاینت نیز خودش reconnect می‌کند.

## اجرای دستی

تولید کلید:

```bash
export V2QUANTUM_PSK="$(./bin/v2quantum keygen)"
```

سمت ایران:

```bash
./bin/v2quantum check -config examples/server-quantum-udp.json
./bin/v2quantum run -config examples/server-quantum-udp.json
```

سمت خارج، ابتدا `IRAN_IP` را در فایل client عوض کنید و همان PSK را export کنید:

```bash
./bin/v2quantum run -config examples/client-quantum-udp.json
```

نمونه‌های TCP، Quantum و Raw در پوشه `examples/` هستند. هر دو سمت باید نام mapping یکسان، PSK یکسان و carrier سازگار داشته باشند.

## Raw ICMP، spoofing و BIP

Raw mode آگاهانه پشت دو قفل است: `experimental_enabled=true` و برای source غیرمحلی `allow_unrouted_spoof=true`. دستور پیش‌بررسی:

```bash
sudo v2quantum spoof-check -config /etc/v2quantum/iran.json
sudo v2quantum spoof-check -config /etc/v2quantum/iran.json -send
```

معنی فیلدها:

- `local_ip`: IP واقعی همین سرور؛ باید روی host موجود باشد.
- `peer_ip`: IP واقعی سمت مقابل.
- `spoof_source_ip`: IP مبدأ جایگزین؛ فقط IP مجاز و route‌شده به همین سرور.
- `spoof_destination_ip`: IP/BIP جایگزین سمت مقابل.
- `icmp_identifier`: عدد یکسان در هر دو سمت.
- `payload_mtu`: اندازه datagram خام؛ Quantum به‌صورت خودکار chunk را با آن هماهنگ می‌کند.

اگر سمت ایران با source برابر `A2` و destination برابر `B2` تنظیم شود، سمت خارج باید source برابر `B2` و destination برابر `A2` داشته باشد. فعال‌کردن `allow_unrouted_spoof` فقط guard محلی برنامه را کنار می‌زند؛ BCP38 یا anti-spoof دیتاسنتر را دور نمی‌زند. موفقیت واقعی spoof فقط با تأیید provider و packet capture روی peer مشخص می‌شود.

## امنیت و محدودیت‌ها

- PSK را داخل JSON یا Git قرار ندهید؛ installer آن را با mode `0600` در `/etc/v2quantum/*.env` نگه می‌دارد.
- handshake فعلی PSK-based است و forward secrecy ندارد؛ برای تغییر دوره‌ای، یک token جدید روی هر دو سمت قرار دهید و سرویس‌ها را restart کنید.
- فقط TCP mapping پیاده‌سازی شده است. UDP سرویس کاربر هنوز mapping مستقل ندارد؛ `quantum_udp` نام carrier است، نه UDP port-forward.
- health endpoint به‌صورت پیش‌فرض public نیست.
- Raw ICMP روی Linux اجرا می‌شود و به `CAP_NET_RAW` نیاز دارد.

## آنچه تست شده است

- unit test پروتکل، config، checksum و رمزنگاری.
- ردشدن PSK اشتباه و حفاظت sequence رکوردها.
- انتقال سرتاسری هم‌زمان روی TCP و Quantum UDP.
- Raw packet loopback، Quantum روی Raw ICMP و reverse tunnel رمز‌شده روی Raw ICMP.
- race detector، vet و build باینری در فرایند release بررسی می‌شوند.

برای مشاهده وضعیت:

```bash
systemctl status v2quantum@iran --no-pager
journalctl -u v2quantum@iran -f
curl -fsS http://127.0.0.1:9090/healthz
```
