"""Exercise the real egress policy in a disposable user+network namespace.

Refuses host-root execution and verifies namespace separation before nft runs.
It never changes the host firewall, accounts, interfaces or running services.
"""
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
        self.wfile.write(b'public-network-policy-fixture')


def request(port):
    with urllib.request.urlopen('http://127.0.0.1:' + str(port), timeout=2) as response:
        return response.status


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--nft', required=True)
    p.add_argument('--ip', required=True)
    p.add_argument('--rules-file', type=Path, required=True)
    p.add_argument('--honcho-enabled', action='store_true')
    p.add_argument('--inside', action='store_true')
    p.add_argument('--outer-network')
    args=p.parse_args()
    if not args.inside:
        if os.geteuid()==0:
            raise RuntimeError('Run as an unprivileged operator, not host root')
        network=os.readlink('/proc/self/ns/net')
        command=['/run/current-system/sw/bin/unshare','-Urn',sys.executable,__file__,*sys.argv[1:],'--inside','--outer-network',network]
        raise SystemExit(subprocess.call(command))
    if os.geteuid()!=0 or os.readlink('/proc/self/ns/net')==args.outer_network:
        raise RuntimeError('Not in the required private user/network namespace')
    uid_map=Path('/proc/self/uid_map').read_text().split()
    if len(uid_map)!=3 or uid_map[0]!='0' or uid_map[1]=='0' or uid_map[2]!='1':
        raise RuntimeError('Unexpected UID mapping; refusing firewall operations')
    subprocess.run([args.ip,'link','set','lo','up'],check=True)
    servers=[ThreadingHTTPServer(('127.0.0.1',port),Fixture) for port in [18090,18092,9119,8081,18093,18094,8000,5432]]
    for server in servers:threading.Thread(target=server.serve_forever,daemon=True).start()
    assert all(request(port)==200 for port in [18090,18092,9119,8081,18093,18094,8000,5432])
    rules=args.rules_file.read_text()
    if rules.count('meta skuid "hermes"')!=5:
        raise RuntimeError('Canonical rules do not match the test mapping contract')
    # Only the UID name is replaced: namespace UID 0 maps to the unprivileged operator.
    rules=rules.replace('meta skuid "hermes"','meta skuid 0')
    subprocess.run([args.nft,'--file','-'],input=rules,text=True,check=True)
    assert request(18090)==200
    assert request(18092)==200,'Fixed local owner RPC was not reachable'
    assert request(9119)==200,'Same-host dashboard WebSocket transport was not reachable'
    if args.honcho_enabled:
        assert request(8000)==200,'Local Honcho API was not reachable'
    for forbidden in [8081,18093,18094,5432] + ([] if args.honcho_enabled else [8000]):
        try:
            request(forbidden)
        except (urllib.error.URLError,TimeoutError,OSError):
            denied=True
        else:
            denied=False
        assert denied,f'Forbidden local port {forbidden} was reachable'
    assert request(18090)==200,'Allowed inference or reply traffic was broken'
    print(json.dumps({'private_namespace_verified':True,'baseline_all_ports_reachable':True,'inference_allowed':True,'fixed_owner_rpc_allowed':True,'same_host_dashboard_allowed':True,'honcho_api_allowed':args.honcho_enabled,'database_and_memory_inference_denied':True,'direct_upstream_denied':True,'arbitrary_loopback_denied':True,'reply_traffic_allowed':True,'host_firewall_changed':False}))
    for server in servers:server.shutdown();server.server_close()


if __name__=='__main__':main()
