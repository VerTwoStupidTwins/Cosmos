"""Exercise generated OpenConcho UID policy only in a private user/net namespace."""
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
        self.wfile.write(b'public disposable network fixture')


def request(host, port):
    # Ignore operator proxy settings: these addresses exist only in the fixture.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f'http://{host}:{port}', timeout=2) as r:
        return r.status


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
        raise SystemExit(subprocess.call(['/run/current-system/sw/bin/unshare', '-Urn', sys.executable, __file__, *sys.argv[1:], '--inside', '--outer-network', os.readlink('/proc/self/ns/net')]))
    assert os.geteuid() == 0 and os.readlink('/proc/self/ns/net') != args.outer_network
    mapping = Path('/proc/self/uid_map').read_text().split()
    assert len(mapping) == 3 and mapping[0] == '0' and mapping[1] != '0' and mapping[2] == '1'
    subprocess.run([args.ip, 'link', 'set', 'lo', 'up'], check=True)
    subprocess.run([args.ip, 'address', 'add', '198.18.0.1/32', 'dev', 'lo'], check=True)
    allowed = [('127.0.0.1', p) for p in [8000, 9120]]
    denied = [('127.0.0.1', p) for p in [5432, 8081, 9119, 18090, 18092, 18093, 18094]] + [('127.0.0.2', 8000), ('198.18.0.1', 8000)]
    servers = [ThreadingHTTPServer(a, Fixture) for a in allowed + denied]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        assert all(request(*a) == 200 for a in allowed + denied)
        rules = args.rules_file.read_text()
        assert rules.count('meta skuid "openconcho"') == 4
        rules = rules.replace('meta skuid "openconcho"', 'meta skuid 0')
        for _ in range(2):
            subprocess.run([args.nft, '--file', '-'], input=rules, text=True, check=True)
            assert all(request(*a) == 200 for a in allowed)
            for a in denied:
                try:
                    request(*a)
                except (urllib.error.URLError, OSError, TimeoutError):
                    pass
                else:
                    raise AssertionError('Forbidden destination reachable')
        print(json.dumps({'private_namespace': True, 'api_and_readiness_allowed': True, 'models_database_other_destinations_denied': True, 'atomic_policy_reload': True, 'host_firewall_changed': False}))
    finally:
        for s in servers:
            s.shutdown()
            s.server_close()


if __name__ == '__main__':
    main()
