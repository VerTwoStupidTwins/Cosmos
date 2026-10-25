"""Exercise Honcho UID rules only in a verified disposable user/network namespace."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import urllib.error
import urllib.request


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'public honcho policy fixture')


def request(port):
    with urllib.request.urlopen('http://127.0.0.1:' + str(port), timeout=2) as response:
        return response.status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rules-file', type=Path, required=True)
    parser.add_argument('--nft', required=True)
    parser.add_argument('--ip', required=True)
    parser.add_argument('--inside', action='store_true')
    parser.add_argument('--outer-network')
    args = parser.parse_args()
    if not args.inside:
        if os.geteuid() == 0:
            raise RuntimeError('Refusing host-root firewall test')
        command = ['/run/current-system/sw/bin/unshare', '-Urn', sys.executable, __file__, *sys.argv[1:], '--inside', '--outer-network', os.readlink('/proc/self/ns/net')]
        raise SystemExit(subprocess.call(command))
    if os.geteuid() != 0 or os.readlink('/proc/self/ns/net') == args.outer_network:
        raise RuntimeError('Not in a private user/network namespace')
    mapping = Path('/proc/self/uid_map').read_text().split()
    if len(mapping) != 3 or mapping[0] != '0' or mapping[1] == '0' or mapping[2] != '1':
        raise RuntimeError('Unsafe UID mapping')
    subprocess.run([args.ip, 'link', 'set', 'lo', 'up'], check=True)
    allowed, denied = [8000, 18093, 18094], [8081, 18090, 18092, 9119]
    servers = [ThreadingHTTPServer(('127.0.0.1', port), Fixture) for port in allowed + denied]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        assert all(request(port) == 200 for port in allowed + denied)
        rules = args.rules_file.read_text()
        if rules.count('meta skuid "honcho"') != 3:
            raise RuntimeError('Canonical Honcho policy changed; inspect the test mapping')
        rules = rules.replace('meta skuid "honcho"', 'meta skuid 0')
        for _ in range(2):
            subprocess.run([args.nft, '--file', '-'], input=rules, text=True, check=True)
            assert all(request(port) == 200 for port in allowed)
            for port in denied:
                try:
                    request(port)
                except (urllib.error.URLError, OSError, TimeoutError):
                    pass
                else:
                    raise AssertionError('Forbidden port reachable: ' + str(port))
        print(json.dumps({'private_namespace': True, 'local_models_and_api_allowed': True, 'direct_upstream_and_other_loopback_denied': True, 'atomic_policy_reload': True, 'host_firewall_changed': False}))
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
