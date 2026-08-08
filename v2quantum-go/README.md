# V2Quantum-Go

هسته‌ای مستقل و بدون لایسنس برای Reverse Tunnel است که با Go و فقط با کتابخانه استاندارد نوشته شده است. این پروژه از کد یا باینری Pengu، Dagger یا Backhaul استفاده نمی‌کند و با پروتکل آن‌ها نیز wire-compatible نیست. پوشه و سرویس‌های Backhaul/WSMUX را تغییر نمی‌دهد.

## قابلیت‌ها

- Reverse TCP forwarding با چند mapping نام‌دار و محدودشده؛ سرور نمی‌تواند مقصد دلخواه روی کلاینت باز کند.
- سه carrier مستقل: `tcp`، `quantum_udp` و `raw_icmp` آزمایشی.
- TUN مستقل لایهٔ ۳ روی carrierهای TCP یا Quantum UDP با interface مجزا برای هر نمونه.
- Multiplex چند صد stream روی pool اتصال‌ها با انتخاب کم‌بارترین session.
- احراز هویت دوطرفه PSK با nonce تصادفی و HMAC-SHA256.
- رمزنگاری تمام frameها با AES-256-GCM، کلید جدا برای هر جهت و counter ضد replay/order.
- Quantum v2 UDP با cookie بدون state، SACK شصت‌وچهاربیتی، reorder، fast retransmit، RTO تطبیقی، pacing، کنترل ازدحام AIMD و Cauchy Reed-Solomon FEC چندپاریتی.
- reconnect با exponential backoff و jitter، keepalive داخلی و راه‌اندازی مجدد توسط systemd.
- health endpoint جدا برای هر instance روی loopback (مدیر معمولاً از پورت `19090` به بعد انتخاب می‌کند) و metrics سازگار با Prometheus روی `/metrics`.
- Raw ICMP با packet IPv4 واقعی، checksum، `IP_HDRINCL`، تنظیم interface، MTU و source/destination override کنترل‌شده.
- تولید خودکار setup code در ایران؛ `V2Q3_` برای reverse port و `V2T2_` برای TUN لایهٔ ۳؛ کدهای قدیمی نیز برای مهاجرت خوانده می‌شوند.
- نصب/آپدیت/حذف تک‌خطی، backup خودکار تنظیمات، بررسی تداخل پورت و پشتیبانی از چند mapping.
- پشتیبانی واقعی از چند tunnel هم‌زمان؛ هر نمونه نام، config، health port، سرویس و watchdog مستقل دارد و نمونهٔ قبلی overwrite نمی‌شود.
- watchdog سه‌مرحله‌ای سمت خارج؛ سه healthcheck ناموفق متوالی باعث restart سرویس می‌شود.
- بازکردن خودکار پورت‌ها در UFW/firewalld فعال، بدون نصب یا تغییر فایروال موجود.

## انتخاب carrier

| حالت | کاربرد | نیاز شبکه | وضعیت |
|---|---|---|---|
| `tcp` | بیشترین سازگاری و پایداری | یک پورت TCP | Production |
| `quantum_udp` | مسیرهایی که UDP بهتر از TCP جواب می‌دهد | یک پورت UDP | Production |
| `raw_icmp` | شبکه آزمایشی، BIP یا مسیر ICMP مجاز | root/CAP_NET_RAW و ICMP دوطرفه | Experimental |

برای شروع `quantum_udp` را امتحان کنید و اگر UDP در مسیر مسدود یا شدیداً rate-limit بود `tcp` را انتخاب کنید. Quantum v2 برای loss و reorder طراحی شده، اما هیچ نرم‌افزاری نمی‌تواند RTT فیزیکی route را کمتر کند. Raw ICMP الزاماً ping را پایین نمی‌آورد و نتیجه به route، فیلترینگ ICMP و سیاست دیتاسنتر بستگی دارد.

## معماری Quantum v2

Quantum v2 یک پیاده‌سازی مستقل Go است و از باینری Dagger یا کد KCP آن استفاده نمی‌کند. ساختارش همان اجزای قابل‌اندازه‌گیری یک carrier دیتاگرامی حرفه‌ای را دارد:

- handshake مبتنی بر cookie پیش از تخصیص session، سپس احراز هویت و رمزنگاری AES-256-GCM در لایهٔ بالاتر؛
- reliable ordered byte stream روی UDP با ACK تجمعی و selective ACK برای packetهای خارج از ترتیب؛
- fast retransmit برای gap، RTO تطبیقی بر اساس SRTT/RTTVAR و backoff محدود برای timeout؛
- congestion window از نوع slow-start/AIMD و pacing مبتنی بر RTT برای جلوگیری از burst؛
- Cauchy Reed-Solomon FEC مستقل که تا تعداد `parity_shards` packet گم‌شده در هر block را بدون انتظار برای RTO بازسازی می‌کند؛
- window، datagram size، FEC و socket buffer مستقل در پروفایل‌های `stable`، `balanced` و `max`؛
- reconnect داخلی، keepalive، watchdog و metrics شامل RTT، RTO، window، retransmit و FEC recovery.

پروفایل Balanced پیش‌فرض و پیشنهادشده است: Stable از FEC `6+2`، Balanced از `8+2` و Max از `10+1` استفاده می‌کند. Stable تحمل loss بیشتری دارد و Max سربار کمتر همراه پنجره و buffer بزرگ‌تر برای پهنای باند بالا می‌دهد. هر دو سمت باید هستهٔ `0.3.x` یا جدیدتر داشته باشند؛ Quantum v2 عمداً با پروتکل بستهٔ Dagger یا Leech wire-compatible نیست و هیچ باینری یا لایسنس آن‌ها را نیاز ندارد.

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
make release VERSION=0.3.0
```

## نصب تک‌خطی

روی هر دو سرور ایران و خارج، به‌عنوان root اجرا کنید:

```bash
bash <(curl -fsSL --ipv4 https://raw.githubusercontent.com/V2grop/backhaul-oneclick/main/v2quantum-oneclick.sh)
```

نصب‌کنندهٔ عمومی فقط release استاتیک را با `SHA256SUMS` بررسی و نصب می‌کند؛ بنابراین روی سرور عمومی Go دانلود یا نصب نمی‌شود. build از source فقط برای توسعه‌دهنده و به‌صورت صریح با `--source` فعال می‌شود. در این حالت موقت، سه آدرس رسمی دانلود Go به‌ترتیب امتحان می‌شوند، checksum ثابت بررسی می‌شود و toolchain پس از پایان حذف می‌گردد.

برای دسترسی به تمام موتورهای پروژه از منوی واحد استفاده کنید:

```bash
bash <(curl -fsSL --ipv4 https://raw.githubusercontent.com/V2grop/backhaul-oneclick/main/oneclick-universal.sh)
```

راه‌اندازی پیشنهادی بدون تداخل با Backhaul قبلی:

1. ایران: گزینه `1`، حالت Quantum، پروفایل Balanced، ورودی عمومی `2445` و carrier برابر `8890`.
2. setup code با پیشوند `V2Q3_` را کپی کنید؛ این کد حاوی PSK است و نباید عمومی شود. کدهای قدیمی `V2Q2_` و `V2Q1_` نیز برای مهاجرت خوانده می‌شوند، ولی برای Quantum باید هستهٔ هر دو سمت به‌روز باشد.
3. خارج: گزینه `2` و Paste همان setup code؛ مقصد پیش‌فرض `127.0.0.1:2444` است.
4. در firewall ایران، `8890/udp` و `2445/tcp` باید باز باشند. خارج فقط اتصال خروجی به `8890/udp` نیاز دارد.
5. در لینک VLESS فقط پورت ورودی ایران را به `2445` تغییر دهید؛ Xray خارج همچنان روی `2444` می‌ماند.

برای چند پورت، در ایران پورت‌ها را با کاما وارد کنید؛ برای مثال `2445,2446,2447`. خارج باید همان تعداد target را به همان ترتیب بدهد. مدیر برای هر تونل نامی مانند `iran-main` و `outside-main` می‌سازد؛ سرویس‌ها نیز به‌شکل `v2quantum@iran-main.service` و `v2quantum-watchdog@outside-main.timer` هستند. systemd با `Restart=always` جای cron را می‌گیرد و خود هسته نیز reconnect با backoff و jitter دارد.

## TUN مستقل لایهٔ ۳

از منوی عمومی گزینهٔ `V2TUN` یا دستور زیر استفاده کنید:

```bash
tunnel-manager --tun
```

در ایران گزینهٔ ساخت server را بزنید و کد `V2T2_` را به خارج منتقل کنید. خارج همان کد را Paste می‌کند؛ `V2T1_` قدیمی نیز خوانده می‌شود. آدرس‌های پیش‌فرض `10.77.0.1/30` و `10.77.0.2/30` هستند و MTU پیش‌فرض `1280` است. پس از اتصال:

```bash
# ایران
ping -c 3 10.77.0.2

# خارج
ping -c 3 10.77.0.1
```

هر TUN یک interface غیرماندگار با نام یکتا می‌سازد؛ با توقف یا حذف همان سرویس interface نیز حذف می‌شود. route پیش‌فرض `0.0.0.0/0` عمداً توسط manager پذیرفته نمی‌شود تا outer carrier داخل خود TUN loop نشود. برای route کردن subnetهای پشت دو سرور، subnetهای مشخص را وارد کنید و IP forwarding/firewall را متناسب با شبکهٔ خود تنظیم کنید. TUN به `iproute2`، `/dev/net/tun` و `CAP_NET_ADMIN` نیاز دارد. این مسیر از Raw/Spoof جداست و carrier خام ICMP را استفاده نمی‌کند.

مدیریت بعد از نصب:

```bash
v2quantum-manager
v2quantum-installer --update
v2quantum-installer --uninstall
```

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

نمونه‌های TCP، Quantum، Raw و TUN در پوشه `examples/` هستند. هر دو سمت باید PSK و carrier سازگار داشته باشند؛ در reverse-port نام mappingها نیز باید یکسان باشد.

## Raw ICMP، spoofing و BIP

Raw mode آگاهانه پشت دو قفل است: `experimental_enabled=true` و برای source غیرمحلی `allow_unrouted_spoof=true`. دستور پیش‌بررسی:

```bash
sudo v2quantum spoof-check -config /etc/v2quantum/iran.json
sudo v2quantum spoof-check -config /etc/v2quantum/iran.json -send
```

مدیر هنگام ساخت Raw سه روش انتخاب source ارائه می‌دهد:

1. `Automatic safe scan`: فقط IPv4های واقعاً assign‌شده به interfaceهای فعال را تا peer با ICMP آزمایش می‌کند؛ IP با loss کمتر و RTT بهتر، پس از حداقل دو پاسخ از سه probe، انتخاب می‌شود.
2. `Manual advanced entry`: برای secondary IP/BIP یا prefixای که دیتاسنتر صریحاً به همین سرور route و مجاز کرده است.
3. `Real IP only`: بدون هیچ source/destination override.

اسکن مستقل همان قابلیت:

```bash
sudo v2quantum spoof-scan -peer PEER_REAL_IPV4
sudo v2quantum spoof-scan -peer PEER_REAL_IPV4 -json
```

اسکنر خودکار هیچ دامنه، رنج اینترنتی یا IP شخص ثالثی را تولید و اسکن نمی‌کند. پاسخ ICMP یک وب‌سایت عمومی نیز مجوز استفاده از IP آن به‌عنوان source نیست.

معنی فیلدها:

- `local_ip`: IP واقعی همین سرور؛ باید روی host موجود باشد.
- `peer_ip`: IP واقعی سمت مقابل.
- `spoof_source_ip`: IP مبدأ جایگزین؛ فقط IP مجاز و route‌شده به همین سرور.
- `spoof_destination_ip`: IP/BIP جایگزین سمت مقابل.
- `expected_peer_source_ip`: sourceای که باید در بسته‌های ورودی peer دیده شود؛ از مقصد ارسال مستقل است.
- `icmp_identifier`: عدد یکسان در هر دو سمت.
- `payload_mtu`: اندازه datagram خام؛ Quantum به‌صورت خودکار chunk را با آن هماهنگ می‌کند.

برای حالت معمول، `peer_ip` مقصد واقعی ارسال باقی می‌ماند و فقط `expected_peer_source_ip` نتیجهٔ انتخاب‌شدهٔ سمت مقابل است. `spoof_destination_ip` صرفاً برای BIP واقعاً route‌شده استفاده می‌شود. فعال‌کردن `allow_unrouted_spoof` فقط guard محلی برنامه را کنار می‌زند؛ BCP38 یا anti-spoof دیتاسنتر را دور نمی‌زند. موفقیت source غیرمحلی فقط با تأیید provider و packet capture روی peer مشخص می‌شود.

## امنیت و محدودیت‌ها

- PSK را داخل JSON یا Git قرار ندهید؛ installer آن را با mode `0600` در `/etc/v2quantum/*.env` نگه می‌دارد.
- handshake فعلی PSK-based است و forward secrecy ندارد؛ برای تغییر دوره‌ای، یک token جدید روی هر دو سمت قرار دهید و سرویس‌ها را restart کنید.
- فقط TCP mapping پیاده‌سازی شده است. UDP سرویس کاربر هنوز mapping مستقل ندارد؛ `quantum_udp` نام carrier است، نه UDP port-forward. TUN بستهٔ کامل IP را مستقل از mapping حمل می‌کند.
- health endpoint به‌صورت پیش‌فرض public نیست.
- Raw ICMP روی Linux اجرا می‌شود و به `CAP_NET_RAW` نیاز دارد.
- TUN روی Linux اجرا می‌شود و به `CAP_NET_ADMIN` و ابزار `ip` نیاز دارد.

## آنچه تست شده است

- unit test پروتکل، config، checksum، FEC، SACK و رمزنگاری.
- ردشدن PSK اشتباه و حفاظت sequence رکوردها.
- انتقال سرتاسری هم‌زمان روی TCP و Quantum v2 UDP، شامل loss، reorder، fast recovery و انتقال دوطرفه.
- انتقال دوطرفهٔ بستهٔ IP در TUN روی carrier رمز‌شده با interface آزمایشی in-memory.
- Raw packet loopback، Quantum روی Raw ICMP و reverse tunnel رمز‌شده روی Raw ICMP.
- نصب ایزوله، نگهداری فایل‌های Backhaul، rollback تنظیمات در خطای start و حذف با `y` کوچک.
- race detector، vet و build باینری در فرایند release بررسی می‌شوند.

برای مشاهده وضعیت:

```bash
v2quantum-manager --list
systemctl status v2quantum@iran-main --no-pager
journalctl -u v2quantum@iran-main -f
set -a; source /etc/v2quantum/iran-main.env; set +a
v2quantum healthcheck -config /etc/v2quantum/iran-main.json
```
