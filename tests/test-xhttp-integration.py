#!/usr/bin/env python3
"""Loopback data-path test. Requires XRAY_TEST_BIN and NGINX_TEST_BIN.
Runs actual Xray -> TLS/H2 Nginx -> Xray -> TCP/UDP echo services.
No root, systemd, external network or production configuration changes.
"""
import json
import os
from pathlib import Path
import socket
import pwd
import grp
import socketserver
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
XRAY = os.environ['XRAY_TEST_BIN']
NGINX = os.environ['NGINX_TEST_BIN']

class TCP(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(65536):
            self.request.sendall(data)

class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(data, self.client_address)

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def ready(port, processes):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        assert all(p.poll() is None for p in processes), 'A tunnel process exited'
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                return
        except OSError:
            time.sleep(.05)
    raise AssertionError(f'Port {port} did not become ready')

with tempfile.TemporaryDirectory(prefix='xhttp-integration-') as tmp:
    work = Path(tmp)
    (work/'logs').mkdir()
    cert, key = work/'cert.pem', work/'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', str(key), '-out', str(cert), '-days', '1',
                    '-subj', '/CN=cdn.example.com', '-addext', 'subjectAltName=DNS:cdn.example.com'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tcp = socketserver.ThreadingTCPServer(('127.0.0.1', 0), TCP)
    udp = socketserver.ThreadingUDPServer(('127.0.0.1', 0), UDP)
    tcp.daemon_threads = udp.daemon_threads = True
    for server in (tcp, udp):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for mode in os.environ.get('XHTTP_TEST_MODES', 'auto,stream-up,packet-up').split(','):
            origin, edge, port_ir, port_udp = [free_port() for _ in range(4)]
            assert len({origin, edge, port_ir, port_udp}) == 4
            env = os.environ | dict(TEST_WORK=tmp, TEST_MODE=mode,
                TEST_ORIGIN=str(origin), TEST_EDGE=str(edge), TEST_IR=str(port_ir),
                TEST_UDP=str(port_udp), TEST_TARGET=str(tcp.server_address[1]),
                TEST_UDP_TARGET=str(udp.server_address[1]))
            script = r'''
source "$1/oneclick-xhttp-cdn.sh"
INSTANCE=test DOMAIN=cdn.example.com UUID=123e4567-e89b-12d3-a456-426614174000
XHTTP_PATH=/xhttp-integration-test XHTTP_MODE="$TEST_MODE"
ORIGIN_PORT="$TEST_ORIGIN" EDGE_PORT="$TEST_EDGE"
CLEAN_IP=127.0.0.1 BIND_ADDRESS=127.0.0.1 TARGET_HOST=127.0.0.1 TRAFFIC_SCOPE=ports
TLS_CERT="$TEST_WORK/cert.pem" TLS_KEY="$TEST_WORK/key.pem"
parse_mappings "tcp:$TEST_IR=$TEST_TARGET,udp:$TEST_UDP=$TEST_UDP_TARGET"
write_server_config "$TEST_WORK/server.json"
write_client_config "$TEST_WORK/client.json"
write_nginx_config "$TEST_WORK/snippet.conf"
'''
            subprocess.run(['bash', '-c', script, 'test', str(ROOT)], env=env, check=True)
            if os.environ.get('XHTTP_TEST_DEBUG'):
                for config in ('server.json', 'client.json'):
                    value = json.loads((work/config).read_text())
                    value['log']['loglevel'] = 'debug'
                    (work/config).write_text(json.dumps(value))
            client = json.loads((work/'client.json').read_text())
            # Test-only CA trust. Production retains the system CA store.
            client['outbounds'][0]['streamSettings']['tlsSettings']['certificates'] = [
                {'certificateFile': str(cert), 'usage': 'verify'}]
            (work/'client.json').write_text(json.dumps(client))
            snippet = (work/'snippet.conf').read_text().replace(
                f'listen {edge} ssl http2;', f'listen 127.0.0.1:{edge} ssl http2;').replace(
                f'    listen [::]:{edge} ssl http2;\n', '')
            (work/'nginx.conf').write_text(
                f'user {pwd.getpwuid(os.getuid()).pw_name} {grp.getgrgid(os.getgid()).gr_name};\n'
                f'daemon off;\nmaster_process off;\npid {work}/nginx.pid;\n'
                f'error_log {work}/nginx.log info;\nevents {{}}\nhttp {{\n'
                f'client_body_temp_path {work}/body;\nproxy_temp_path {work}/proxy;\n'
                f'fastcgi_temp_path {work}/fastcgi;\nuwsgi_temp_path {work}/uwsgi;\n'
                f'scgi_temp_path {work}/scgi;\naccess_log off;\n{snippet}\n}}\n')
            processes, logs = [], []
            try:
                for command in ([XRAY, 'run', '-config', str(work/'server.json')],
                                [NGINX, '-p', tmp+'/', '-c', str(work/'nginx.conf')],
                                [XRAY, 'run', '-config', str(work/'client.json')]):
                    log = open(work/f'process-{len(logs)}.log', 'w+')
                    logs.append(log)
                    processes.append(subprocess.Popen(command, stdout=log, stderr=log))
                for port in (origin, edge, port_ir):
                    ready(port, processes)
                # Multiple concurrent connections exercise native XMUX reuse.
                def transfer(index):
                    payload = os.urandom(256*1024 + index)
                    with socket.create_connection(('127.0.0.1', port_ir), timeout=15) as conn:
                        conn.settimeout(15)
                        # Send/receive chunks to avoid echo-side socket backpressure.
                        for start in range(0, len(payload), 16384):
                            block = payload[start:start+16384]
                            conn.sendall(block)
                            received = b''
                            while len(received) < len(block):
                                try:
                                    part = conn.recv(len(block)-len(received))
                                except TimeoutError as exc:
                                    raise AssertionError(f'{mode} stream {index}: offset {start}, got {len(received)}/{len(block)} bytes') from exc
                                assert part, 'Unexpected EOF'
                                received += part
                            assert received == block, 'TCP data corruption'
                from concurrent.futures import ThreadPoolExecutor
                with ThreadPoolExecutor(max_workers=4) as pool:
                    list(pool.map(transfer, range(4)))
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                    sock.settimeout(15)
                    payload = os.urandom(1024)
                    sock.sendto(payload, ('127.0.0.1', port_udp))
                    assert sock.recv(4096) == payload, 'UDP data corruption'
                print(f'[PASS] {mode}: 4 concurrent TCP streams + UDP via TLS/H2 Nginx', flush=True)
            except BaseException:
                for log in logs:
                    log.flush()
                    log.seek(0)
                    print(log.read())
                if (work/'nginx.log').exists():
                    print((work/'nginx.log').read_text()[-12000:])
                raise
            finally:
                for proc in processes:
                    proc.terminate()
                for proc in processes:
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                for log in logs:
                    log.close()
    finally:
        for server in (tcp, udp):
            server.shutdown()
            server.server_close()
