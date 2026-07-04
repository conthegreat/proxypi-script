#!/usr/bin/env python3
import asyncio
import logging
from logging.handlers import RotatingFileHandler
import socket
import csv
import threading
import time
import sys
import select
from datetime import datetime

if sys.platform == 'win32' and not hasattr(select, 'poll'):
    POLLIN = 1

    class _WindowsPoll:
        def __init__(self):
            self._read_fds = {}

        def register(self, fd, mask):
            if mask & POLLIN:
                self._read_fds[fd] = mask

        def unregister(self, fd):
            self._read_fds.pop(fd, None)

        def poll(self, timeout=None):
            if not self._read_fds:
                return []
            fds = list(self._read_fds)
            wait = None if timeout is None else max(0, timeout) / 1000.0
            readable, _, _ = select.select(fds, [], [], wait)
            return [(fd, POLLIN) for fd in readable]

    select.POLLIN = POLLIN
    select.poll = _WindowsPoll

import pyrad.packet
from pyrad.client import Client
from pyrad.dictionary import Dictionary
import base64
from urllib.parse import urlparse
import os
import uuid

BUFFER_SIZE = 8192
SOCKS_VERSION = 5
HOP_BY_HOP_HEADERS = {
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailers', 'transfer-encoding', 'upgrade', 'proxy-connection',
}
CLIENT_DISCONNECT_ERRORS = (
    asyncio.CancelledError,
    ConnectionResetError,
    BrokenPipeError,
    EOFError,
    ConnectionAbortedError,
)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FORMAT = '%(asctime)s - %(levelname)s - %(message)s'


def setup_logger():
    log = logging.getLogger("ImprovedProxy")
    if log.handlers:
        return log

    log.setLevel(logging.INFO)
    formatter = logging.Formatter(LOG_FORMAT)

    console = logging.StreamHandler()
    console.setFormatter(formatter)
    log.addHandler(console)

    log_dir = os.environ.get('PROXY_LOG_DIR', os.path.join(SCRIPT_DIR, 'logs'))
    os.makedirs(log_dir, exist_ok=True)
    log_file = os.path.join(log_dir, 'proxy.log')
    file_handler = RotatingFileHandler(
        log_file, maxBytes=5 * 1024 * 1024, backupCount=3, encoding='utf-8'
    )
    file_handler.setFormatter(formatter)
    log.addHandler(file_handler)
    log.propagate = False
    log.debug_log_file = log_file
    return log


logger = setup_logger()

_MINIMAL_RADIUS_DICTIONARY = """\
ATTRIBUTE\tUser-Name\t\t1\tstring
ATTRIBUTE\tUser-Password\t\t2\tstring
ATTRIBUTE\tNAS-IP-Address\t\t4\tipaddr
ATTRIBUTE\tNAS-Port-Type\t\t61\tinteger
ATTRIBUTE\tNAS-Identifier\t\t32\tstring
ATTRIBUTE\tCalling-Station-Id\t31\tstring
ATTRIBUTE\tCalled-Station-Id\t30\tstring
ATTRIBUTE\tAcct-Status-Type\t40\tinteger
ATTRIBUTE\tAcct-Delay-Time\t\t41\tinteger
ATTRIBUTE\tAcct-Session-Id\t\t44\tstring
ATTRIBUTE\tAcct-Multi-Session-Id\t50\tstring
ATTRIBUTE\tAcct-Input-Octets\t42\tinteger
ATTRIBUTE\tAcct-Output-Octets\t43\tinteger
ATTRIBUTE\tAcct-Session-Time\t46\tinteger
VALUE\t\tAcct-Status-Type\tStart\t\t\t1
VALUE\t\tAcct-Status-Type\tStop\t\t\t2
VALUE\t\tNAS-Port-Type\t\tVirtual\t\t\t5
"""

_REQUIRED_RADIUS_ATTRS = (
    'User-Name',
    'NAS-IP-Address',
    'Acct-Status-Type',
    'Acct-Session-Id',
    'Acct-Multi-Session-Id',
    'Acct-Input-Octets',
    'Acct-Output-Octets',
    'Acct-Session-Time',
    'NAS-Identifier',
    'NAS-Port-Type',
    'Calling-Station-Id',
    'Called-Station-Id',
)


class ImprovedProxy:
    def __init__(self, socks_host='0.0.0.0', socks_port=18100, http_host='0.0.0.0', http_port=58100,
                 radius_server='10.147.17.33', radius_secret='',
                 nas_ip_address=None):
        self.socks_host = socks_host
        self.socks_port = socks_port
        self.http_host = http_host
        self.http_port = http_port
        self.radius_server = radius_server
        self.radius_secret = radius_secret.encode('utf-8')
        self.nas_ip_address = nas_ip_address or os.environ.get('PROXY_NAS_IP') or self._detect_nas_ip()
        self._radius_auth_lock = threading.Lock()
        self._radius_acct_lock = threading.Lock()
        self.radius_dict = self._load_radius_dictionary()
        self.radius_client = Client(
            server=self.radius_server,
            authport=1812,
            secret=self.radius_secret,
            dict=self.radius_dict,
        )
        self.radius_acct_client = Client(
            server=self.radius_server,
            acctport=1813,
            secret=self.radius_secret,
            dict=self.radius_dict,
        )
        self.radius_client.timeout = 3
        self.radius_client.retries = 2
        self.radius_acct_client.timeout = 5
        self.radius_acct_client.retries = 2
        hostname = socket.gethostname()
        log_dir = os.environ.get('PROXY_LOG_DIR', os.path.join(SCRIPT_DIR, 'logs'))
        os.makedirs(log_dir, exist_ok=True)
        logger.info(f"[*] NAS-IP-Address set to {self.nas_ip_address}")
        logger.info(f"[*] Logs directory: {log_dir}")
        logger.info(f"[*] Debug log file: {os.path.join(log_dir, 'proxy.log')}")
        self.usage_log = os.path.join(log_dir, f"user_usage_{hostname}.csv")
        self.connection_log = os.path.join(log_dir, f"connection_log_{hostname}.csv")
        self.user_usage = {}
        self.load_existing_usage()

    def _detect_nas_ip(self):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.connect((self.radius_server, 1812))
                return sock.getsockname()[0]
        except OSError:
            return "127.0.0.1"

    def _ensure_bundled_dictionary(self):
        path = os.path.join(SCRIPT_DIR, "dictionary")
        if os.path.exists(path):
            return path
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(_MINIMAL_RADIUS_DICTIONARY)
        logger.info(f"[*] Created bundled RADIUS dictionary at {path}")
        return path

    def _validate_radius_dictionary(self, radius_dict):
        return [
            attr for attr in _REQUIRED_RADIUS_ATTRS
            if attr not in radius_dict.attributes
        ]

    def _load_radius_dictionary(self):
        env_dict = os.environ.get("RADIUS_DICTIONARY")
        candidates = [
            path for path in (
                self._ensure_bundled_dictionary(),
                env_dict,
                os.path.join(SCRIPT_DIR, "dictionary"),
                "/home/con-root/custom_dictionary",
                "/home/conroot/custom_dictionary",
            )
            if path
        ]
        seen = set()
        for path in candidates:
            if path in seen:
                continue
            seen.add(path)
            if not os.path.exists(path):
                continue
            try:
                radius_dict = Dictionary(path)
                missing = self._validate_radius_dictionary(radius_dict)
                if missing:
                    logger.warning(
                        f"[-] RADIUS dictionary {path} missing attributes: "
                        f"{', '.join(missing)}"
                    )
                    continue
                logger.info(f"[*] Loading RADIUS dictionary from {path}")
                return radius_dict
            except Exception as e:
                logger.warning(f"[-] Failed to load RADIUS dictionary {path}: {e}")
        raise FileNotFoundError("No usable RADIUS dictionary found")

    def _new_session_id(self):
        return uuid.uuid4().hex

    def _send_accounting_packet(self, req, username, protocol, label):
        try:
            with self._radius_acct_lock:
                reply = self.radius_acct_client.SendPacket(req)
            if reply.code == pyrad.packet.AccountingResponse:
                logger.info(f"[+] Accounting {label} sent for {username} ({protocol})")
            else:
                logger.warning(
                    f"[-] Accounting {label} unexpected reply for {username} ({protocol}): "
                    f"RADIUS code {reply.code}"
                )
        except Exception as e:
            logger.warning(
                f"[-] Accounting {label} no reply for {username} ({protocol}): "
                f"{type(e).__name__}: {e}"
            )

    def load_existing_usage(self):
        try:
            with open(self.usage_log, 'r') as csvfile:
                reader = csv.DictReader(csvfile)
                for row in reader:
                    username = row['Username']
                    inbound = int(row['Inbound (bytes)'])
                    outbound = int(row['Outbound (bytes)'])
                    self.user_usage[username] = {"inbound": inbound, "outbound": outbound}
        except FileNotFoundError:
            logger.info("[*] No existing usage log found. Starting fresh.")

    def _start_accounting_async(self, username, session_id, protocol, source_ip):
        threading.Thread(
            target=self._send_accounting_start,
            args=(username, session_id, protocol, source_ip),
            daemon=True,
        ).start()

    def _stop_accounting_async(self, username, session_id, input_octets, output_octets, session_time, protocol, source_ip):
        threading.Thread(
            target=self._send_accounting_stop,
            args=(username, session_id, input_octets, output_octets, session_time, protocol, source_ip),
            daemon=True,
        ).start()

    def _build_accounting_request(self, username, session_id, source_ip, protocol):
        req = self.radius_acct_client.CreateAcctPacket(
            code=pyrad.packet.AccountingRequest, User_Name=username
        )
        req["Acct-Session-Id"] = session_id
        req["Acct-Multi-Session-Id"] = session_id
        req["NAS-Identifier"] = "ImprovedProxy"
        req["NAS-IP-Address"] = self.nas_ip_address
        req["NAS-Port-Type"] = 5
        req["Calling-Station-Id"] = source_ip
        req["Called-Station-Id"] = protocol
        return req

    def _send_accounting_start(self, username, session_id, protocol, source_ip):
        try:
            req = self._build_accounting_request(username, session_id, source_ip, protocol)
            req["Acct-Status-Type"] = 1
            req["Acct-Session-Time"] = 0
            self._send_accounting_packet(req, username, protocol, "Start")
        except Exception as e:
            logger.warning(
                f"[-] Accounting Start failed for {username} ({protocol}): "
                f"{type(e).__name__}: {e}"
            )

    def _send_accounting_stop(self, username, session_id, input_octets, output_octets, session_time, protocol, source_ip):
        try:
            req = self._build_accounting_request(username, session_id, source_ip, protocol)
            req["Acct-Status-Type"] = 2
            req["Acct-Input-Octets"] = input_octets
            req["Acct-Output-Octets"] = output_octets
            req["Acct-Session-Time"] = session_time
            self._send_accounting_packet(req, username, protocol, "Stop")
        except Exception as e:
            logger.warning(
                f"[-] Accounting Stop failed for {username} ({protocol}): "
                f"{type(e).__name__}: {e}"
            )

    def _complete_session(self, username, protocol, inbound_data, outbound_data, start_time, session_id, source_ip):
        session_time = max(1, int((datetime.now() - start_time).total_seconds()))
        self.user_usage[username]["inbound"] += inbound_data
        self.user_usage[username]["outbound"] += outbound_data
        logger.info(
            f"[+] Session complete for '{username}' ({protocol}): "
            f"in={inbound_data}B out={outbound_data}B duration={session_time}s"
        )
        self._stop_accounting_async(
            username, session_id, outbound_data, inbound_data, session_time, protocol, source_ip
        )
        self.update_usage_log()

    async def start(self):
        try:
            with open(self.usage_log, 'x', newline='') as csvfile:
                writer = csv.writer(csvfile)
                writer.writerow(['Username', 'Inbound (bytes)', 'Outbound (bytes)'])
        except FileExistsError:
            pass
        try:
            with open(self.connection_log, 'x', newline='') as csvfile:
                writer = csv.writer(csvfile)
                writer.writerow(['Timestamp', 'Username', 'Source IP', 'Destination IP', 'Destination Port', 'Protocol'])
        except FileExistsError:
            pass

        try:
            socks_server = await asyncio.start_server(
                self.handle_socks_client, self.socks_host, self.socks_port
            )
            logger.info(f"[*] SOCKS Proxy started on {self.socks_host}:{self.socks_port}")
            http_server = await asyncio.start_server(
                self.handle_http_client, self.http_host, self.http_port
            )
            logger.info(f"[*] HTTP Proxy started on {self.http_host}:{self.http_port}")
        except OSError as e:
            if getattr(e, 'winerror', None) == 10048 or e.errno == 10048:
                logger.error(
                    f"[-] Port already in use (SOCKS {self.socks_port} / HTTP {self.http_port}). "
                    "Another proxy instance is still running — stop it in VS Code (Shift+F5) "
                    "or run: Get-Process python | Where-Object {...} | Stop-Process"
                )
            raise
        async with socks_server, http_server:
            await asyncio.gather(socks_server.serve_forever(), http_server.serve_forever())

    async def handle_socks_client(self, reader, writer):
        source_ip = writer.get_extra_info('peername')[0]
        try:
            data = await reader.read(2)
            if len(data) < 2 or data[0] != SOCKS_VERSION:
                logger.warning(f"[-] SOCKS invalid handshake from {source_ip}")
                writer.close()
                return
            n_methods = data[1]
            methods = await reader.read(n_methods)
            if 2 not in methods:
                logger.warning(
                    f"[-] SOCKS auth required but client {source_ip} offered methods "
                    f"{list(methods)} (Firefox needs network.proxy.socks_username/password)"
                )
                writer.write(bytes([SOCKS_VERSION, 0xFF]))
                await writer.drain()
                writer.close()
                return
            writer.write(bytes([SOCKS_VERSION, 2]))
            await writer.drain()
            logger.info(f"[+] SOCKS handshake from {source_ip}, requiring authentication")

            try:
                version = await self._read_exact(reader, 1, "auth version")
                if version[0] != 1:
                    raise ValueError(f"unsupported auth version {version[0]}")
                ulen = (await self._read_exact(reader, 1, "username length"))[0]
                username = (await self._read_exact(reader, ulen, "username")).decode('utf-8', errors='strict')
                plen = (await self._read_exact(reader, 1, "password length"))[0]
                password = (await self._read_exact(reader, plen, "password")).decode('utf-8', errors='strict')
            except (EOFError, UnicodeDecodeError, ValueError) as e:
                logger.warning(f"[-] SOCKS malformed auth from {source_ip}: {e}")
                writer.close()
                return
            if not await self.authenticate_client(username, password):
                logger.warning(f"[-] RADIUS Authentication failed for user {username}")
                writer.write(bytes([1, 1]))
                await writer.drain()
                writer.close()
                return
            writer.write(bytes([1, 0]))
            await writer.drain()
            logger.info(f"[+] Authentication successful for user '{username}'")

            try:
                request = await self._read_exact(reader, 4, "connect request")
                if request[0] != SOCKS_VERSION:
                    raise ValueError(f"unsupported SOCKS version {request[0]}")
                address_type = request[3]
                if address_type == 1:
                    address = socket.inet_ntoa(await self._read_exact(reader, 4, "ipv4 address"))
                elif address_type == 3:
                    domain_length = (await self._read_exact(reader, 1, "domain length"))[0]
                    domain = (await self._read_exact(reader, domain_length, "domain")).decode('utf-8', errors='strict')
                    address = await self._resolve_host(domain)
                elif address_type == 4:
                    address = socket.inet_ntop(socket.AF_INET6, await self._read_exact(reader, 16, "ipv6 address"))
                else:
                    logger.warning(f"[-] SOCKS unsupported address type {address_type} from {source_ip}")
                    writer.write(self._socks_failure_reply(8))
                    await writer.drain()
                    return
                port = int.from_bytes(await self._read_exact(reader, 2, "port"), 'big')
            except (EOFError, UnicodeDecodeError, ValueError, socket.gaierror) as e:
                logger.warning(f"[-] SOCKS malformed connect from {source_ip}: {e}")
                writer.close()
                return
            logger.info(f"[+] User '{username}' (SOCKS) connecting from {source_ip} to {address}:{port}")
            self.log_connection(username, source_ip, address, port, "SOCKS")

            if username not in self.user_usage:
                self.user_usage[username] = {"inbound": 0, "outbound": 0}

            try:
                remote_reader, remote_writer = await asyncio.wait_for(
                    asyncio.open_connection(address, port), timeout=15
                )
                writer.write(self._socks_success_reply(address, port))
                await writer.drain()

                session_id = self._new_session_id()
                start_time = datetime.now()
                self._start_accounting_async(username, session_id, "SOCKS", source_ip)
                inbound_data, outbound_data = await asyncio.gather(
                    self.relay_traffic(reader, remote_writer, "Client -> Server", is_inbound=False),
                    self.relay_traffic(remote_reader, writer, "Server -> Client", is_inbound=True)
                )
                self._complete_session(username, "SOCKS", inbound_data, outbound_data, start_time, session_id, source_ip)
            except (asyncio.TimeoutError, OSError, ConnectionError) as e:
                logger.warning(f"[-] SOCKS upstream unreachable {address}:{port} from {source_ip}: {e}")
                try:
                    writer.write(self._socks_failure_reply(5))
                    await writer.drain()
                except Exception:
                    pass
            except Exception as e:
                logger.error(f"[-] Failed to connect/relay to {address}:{port}: {e}")
                try:
                    writer.write(self._socks_failure_reply(1))
                    await writer.drain()
                except Exception:
                    pass
        except Exception as e:
            logger.error(f"[-] Error handling SOCKS client from {source_ip}: {type(e).__name__}: {e}")
        finally:
            writer.close()

    def _parse_connect_target(self, url):
        if url.startswith('['):
            end = url.index(']')
            address = url[1:end]
            port = int(url[end + 2:]) if len(url) > end + 2 and url[end + 1] == ':' else 443
            return address, port
        if ':' in url:
            address, port_str = url.rsplit(':', 1)
            return address, int(port_str)
        return url, 443

    def _format_header_name(self, name):
        return '-'.join(part.capitalize() for part in name.split('-'))

    async def _resolve_host(self, hostname):
        infos = await asyncio.get_running_loop().getaddrinfo(
            hostname, None, family=socket.AF_UNSPEC, type=socket.SOCK_STREAM
        )
        return infos[0][4][0]

    async def _read_exact(self, reader, nbytes, label):
        data = await reader.read(nbytes)
        if len(data) != nbytes:
            raise EOFError(f"incomplete {label}: expected {nbytes} bytes, got {len(data)}")
        return data

    def _socks_success_reply(self, address, port):
        response = bytearray([SOCKS_VERSION, 0, 0])
        if ':' in address:
            response.append(4)
            response.extend(socket.inet_pton(socket.AF_INET6, address))
        else:
            response.append(1)
            response.extend(socket.inet_aton(address))
        response.extend(port.to_bytes(2, 'big'))
        return response

    def _socks_failure_reply(self, reply_code=5):
        response = bytearray([SOCKS_VERSION, reply_code, 0, 1])
        response.extend(socket.inet_aton('0.0.0.0'))
        response.extend((0).to_bytes(2, 'big'))
        return response

    def _is_client_disconnect(self, exc):
        if isinstance(exc, CLIENT_DISCONNECT_ERRORS):
            return True
        return isinstance(exc, OSError) and getattr(exc, 'winerror', None) in (10053, 10054)

    async def _close_writer(self, writer):
        try:
            if writer is not None and not writer.is_closing():
                writer.close()
                await writer.wait_closed()
        except CLIENT_DISCONNECT_ERRORS:
            pass
        except OSError as e:
            if not self._is_client_disconnect(e):
                raise

    async def handle_http_client(self, reader, writer):
        source_ip = writer.get_extra_info('peername')[0]
        try:
            await self._handle_http_client_session(reader, writer, source_ip)
        except CLIENT_DISCONNECT_ERRORS:
            pass
        except OSError as e:
            if not self._is_client_disconnect(e):
                logger.error(f"[-] HTTP client error from {source_ip}: {e}")
        except Exception as e:
            logger.error(f"[-] HTTP client error from {source_ip}: {type(e).__name__}: {e}")
        finally:
            await self._close_writer(writer)

    def _parse_proxy_authorization(self, auth_header):
        if not auth_header or not auth_header.startswith('Basic '):
            return None
        try:
            creds = base64.b64decode(auth_header.split(' ', 1)[1]).decode('utf-8')
            username, password = creds.split(':', 1)
            return username, password
        except Exception:
            return None

    async def _resolve_http_credentials(self, headers, cached_username, cached_password, source_ip):
        parsed = self._parse_proxy_authorization(headers.get('proxy-authorization'))
        if parsed:
            return parsed[0], parsed[1], False
        if cached_username and cached_password:
            return cached_username, cached_password, False
        return None, None, True

    async def _handle_http_client_session(self, reader, writer, source_ip):
        cached_username = None
        cached_password = None
        auth_challenged_at = None
        while True:
            request_started = time.monotonic()
            request_line = await reader.readline()
            if not request_line:
                break
            request_line = request_line.decode('utf-8', errors='ignore').strip()
            if not request_line:
                continue
            parts = request_line.split()
            if len(parts) != 3:
                await self.send_http_response(writer, 400, "Bad Request")
                break
            method, url, http_version = parts
            headers = {}
            while True:
                line = await reader.readline()
                line = line.decode('utf-8', errors='ignore').strip()
                if not line:
                    break
                if ':' not in line:
                    continue
                key, value = line.split(':', 1)
                headers[key.strip().lower()] = value.strip()
            username, password, needs_challenge = await self._resolve_http_credentials(
                headers, cached_username, cached_password, source_ip
            )
            if needs_challenge:
                auth_challenged_at = time.monotonic()
                logger.info(f"[*] HTTP auth challenge sent to {source_ip}, awaiting credentials")
                await self.send_http_response(
                    writer, 407, "Proxy Authentication Required",
                    {
                        'Proxy-Authenticate': 'Basic realm="Proxy"',
                        'Connection': 'keep-alive',
                        'Proxy-Connection': 'keep-alive',
                    },
                    include_content_length=False,
                )
                continue
            if cached_username != username or cached_password != password:
                auth_started = time.monotonic()
                if not await self.authenticate_client(username, password):
                    await self.send_http_response(writer, 407, "Authentication Failed")
                    continue
                cached_username = username
                cached_password = password
                auth_ms = int((time.monotonic() - auth_started) * 1000)
                if auth_challenged_at is not None:
                    retry_ms = int((time.monotonic() - auth_challenged_at) * 1000)
                    logger.info(
                        f"[+] Authentication successful for user '{username}' "
                        f"(RADIUS {auth_ms}ms, client retried {retry_ms}ms after 407 challenge)"
                    )
                elif headers.get('proxy-authorization'):
                    logger.info(
                        f"[+] Authentication successful for user '{username}' "
                        f"(RADIUS {auth_ms}ms, credentials sent on first request)"
                    )
                else:
                    logger.info(
                        f"[+] Authentication successful for user '{username}' "
                        f"(RADIUS {auth_ms}ms, reusing connection-level credentials)"
                    )

            is_connect = method.upper() == 'CONNECT'
            if is_connect:
                address, port = self._parse_connect_target(url)
                path = None
            else:
                parsed_url = urlparse(url if '://' in url else f'http://{url}')
                address = parsed_url.hostname or headers.get('host', '').split(':')[0]
                if not address:
                    await self.send_http_response(writer, 400, "Bad Request")
                    break
                port = parsed_url.port or 80
                path = parsed_url.path or '/'
                if parsed_url.query:
                    path += f'?{parsed_url.query}'

            protocol = "HTTP-CONNECT" if is_connect else "HTTP"
            logger.info(f"[+] User '{username}' ({protocol}) connecting from {source_ip} to {address}:{port}")
            self.log_connection(username, source_ip, address, port, protocol)
            if username not in self.user_usage:
                self.user_usage[username] = {"inbound": 0, "outbound": 0}
            try:
                remote_reader, remote_writer = await asyncio.wait_for(
                    asyncio.open_connection(address, port), timeout=15
                )
                if is_connect:
                    await self.send_connect_established(writer, http_version)
                    connect_ms = int((time.monotonic() - request_started) * 1000)
                    logger.info(f"[+] CONNECT established for '{username}' in {connect_ms}ms")
                    session_id = self._new_session_id()
                    start_time = datetime.now()
                    self._start_accounting_async(username, session_id, protocol, source_ip)
                    inbound_data, outbound_data = await self.relay_connect_tunnel(
                        reader, writer, remote_reader, remote_writer
                    )
                    self._complete_session(
                        username, protocol, inbound_data, outbound_data, start_time, session_id, source_ip
                    )
                    if headers.get('proxy-connection', headers.get('connection', 'keep-alive')).lower() == 'close':
                        break
                    continue
                else:
                    session_id = self._new_session_id()
                    start_time = datetime.now()
                    self._start_accounting_async(username, session_id, protocol, source_ip)
                    forward_request = f"{method} {path} {http_version}\r\n"
                    forwarded_host = headers.get('host') or f"{address}:{port}"
                    forward_request += f"Host: {forwarded_host}\r\n"
                    for k, v in headers.items():
                        if k in HOP_BY_HOP_HEADERS or k == 'host':
                            continue
                        forward_request += f"{self._format_header_name(k)}: {v}\r\n"
                    forward_request += "\r\n"
                    outbound_data = len(forward_request.encode('utf-8'))
                    remote_writer.write(forward_request.encode('utf-8'))
                    await remote_writer.drain()
                    content_length = int(headers.get('content-length', 0))
                    if content_length > 0:
                        body = await reader.read(content_length)
                        outbound_data += len(body)
                        remote_writer.write(body)
                        await remote_writer.drain()
                    inbound_data = 0
                    response_data = await remote_reader.read(BUFFER_SIZE)
                    while response_data:
                        inbound_data += len(response_data)
                        writer.write(response_data)
                        await writer.drain()
                        response_data = await remote_reader.read(BUFFER_SIZE)
                    self._complete_session(
                        username, protocol, inbound_data, outbound_data, start_time, session_id, source_ip
                    )
                if not remote_writer.is_closing():
                    remote_writer.close()
                    await remote_writer.wait_closed()
            except Exception as e:
                if not self._is_client_disconnect(e):
                    logger.error(f"[-] HTTP relay error to {address}:{port}: {e}")
                    await self.send_http_response(writer, 502, "Bad Gateway")
                break
            if is_connect or headers.get('connection', 'keep-alive').lower() != 'keep-alive':
                break

    async def send_connect_established(self, writer, http_version='HTTP/1.1'):
        response = (
            f"{http_version} 200 Connection established\r\n"
            "Proxy-Agent: ImprovedProxy\r\n"
            "Connection: keep-alive\r\n"
            "\r\n"
        ).encode('ascii')
        writer.write(response)
        await writer.drain()

    async def relay_connect_tunnel(self, client_reader, client_writer, remote_reader, remote_writer):
        """Tunnel HTTPS without closing the client-facing proxy connection (HTTP keep-alive)."""
        inbound_data, outbound_data = await asyncio.gather(
            self.relay_traffic(
                remote_reader, client_writer, "Server -> Client", is_inbound=True, close_writer=False
            ),
            self.relay_traffic(
                client_reader, remote_writer, "Client -> Server", is_inbound=False, close_writer=True
            ),
        )
        return inbound_data, outbound_data

    async def send_http_response(self, writer, status, message, extra_headers=None, include_content_length=True):
        response = f"HTTP/1.1 {status} {message}\r\n"
        if extra_headers:
            for k, v in extra_headers.items():
                response += f"{k}: {v}\r\n"
        if include_content_length:
            response += "Content-Length: 0\r\n"
        response += "\r\n"
        writer.write(response.encode('utf-8'))
        await writer.drain()

    async def authenticate_client(self, username, password):
        logger.info(f"[*] Authenticating client with username '{username}'")
        try:
            with self._radius_auth_lock:
                req = self.radius_client.CreateAuthPacket(code=pyrad.packet.AccessRequest, User_Name=username)
                req["NAS-Identifier"] = "ImprovedProxy"
                req["User-Password"] = req.PwCrypt(password)
                reply = self.radius_client.SendPacket(req)
            return reply.code == pyrad.packet.AccessAccept
        except Exception as e:
            logger.error(f"[-] RADIUS Authentication error: {type(e).__name__}: {e}")
            return False

    async def relay_bidirectional(self, client_reader, client_writer, remote_reader, remote_writer):
        async def forward(reader, writer, direction):
            transferred = 0
            try:
                while True:
                    data = await reader.read(BUFFER_SIZE)
                    if not data:
                        break
                    transferred += len(data)
                    writer.write(data)
                    await writer.drain()
            except CLIENT_DISCONNECT_ERRORS:
                pass
            except OSError as e:
                if not self._is_client_disconnect(e):
                    logger.warning(f"[-] Relay error in {direction}: {e}")
            except Exception as e:
                logger.warning(f"[-] Relay error in {direction}: {type(e).__name__}: {e}")
            return transferred

        client_to_remote = asyncio.create_task(
            forward(client_reader, remote_writer, "Client -> Server")
        )
        remote_to_client = asyncio.create_task(
            forward(remote_reader, client_writer, "Server -> Client")
        )
        try:
            outbound_data, inbound_data = await asyncio.gather(
                client_to_remote, remote_to_client, return_exceptions=True
            )
        finally:
            for task in (client_to_remote, remote_to_client):
                if not task.done():
                    task.cancel()
            await asyncio.gather(client_to_remote, remote_to_client, return_exceptions=True)

        if isinstance(inbound_data, Exception):
            inbound_data = 0
        if isinstance(outbound_data, Exception):
            outbound_data = 0
        await self._close_writer(remote_writer)
        return inbound_data, outbound_data

    async def relay_traffic(self, reader, writer, direction, is_inbound, close_writer=True):
        data_transferred = 0
        try:
            while True:
                data = await reader.read(BUFFER_SIZE)
                if not data:
                    break
                data_transferred += len(data)
                writer.write(data)
                await writer.drain()
        except CLIENT_DISCONNECT_ERRORS:
            pass
        except OSError as e:
            if not self._is_client_disconnect(e):
                logger.warning(f"[-] Relay error in {direction}: {e}")
        except Exception as e:
            logger.warning(f"[-] Relay error in {direction}: {type(e).__name__}: {e}")
        finally:
            if close_writer:
                await self._close_writer(writer)
        return data_transferred

    def update_usage_log(self):
        with open(self.usage_log, 'w', newline='') as csvfile:
            writer = csv.writer(csvfile)
            writer.writerow(['Username', 'Inbound (bytes)', 'Outbound (bytes)'])
            for username, usage in self.user_usage.items():
                writer.writerow([username, usage["inbound"], usage["outbound"]])

    def log_connection(self, username, source_ip, dst_ip, dst_port, protocol):
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(self.connection_log, 'a', newline='') as csvfile:
            writer = csv.writer(csvfile)
            writer.writerow([timestamp, username, source_ip, dst_ip, dst_port, protocol])

if __name__ == "__main__":
    if sys.platform == 'win32':
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

    radius_secret = os.environ.get('RADIUS_SECRET', '')
    if not radius_secret:
        logger.error("[-] RADIUS_SECRET environment variable is required")
        sys.exit(1)

    proxy = ImprovedProxy(
        socks_port=int(os.environ.get('SOCKS_PORT', 18100)),
        http_port=int(os.environ.get('HTTP_PORT', 58100)),
        radius_server=os.environ.get('RADIUS_SERVER', '10.147.17.33'),
        radius_secret=radius_secret,
    )
    logger.info(f"[*] SOCKS proxy on {proxy.socks_host}:{proxy.socks_port}")
    logger.info(f"[*] HTTP proxy on {proxy.http_host}:{proxy.http_port}")
    logger.info(f"[*] RADIUS server {proxy.radius_server}")
    asyncio.run(proxy.start())
