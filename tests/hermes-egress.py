"""Exercise the real egress policy in a disposable user+network namespace.

Refuses host-root execution and verifies namespace separation before nft runs.
It never changes the host firewall, accounts, interfaces or running services.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import urllib.error
import urllib.request

PRIVATE_PEERS = ('10.77.0.2', '100.64.0.2', '169.254.42.2', '192.168.42.2')


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'public-network-policy-fixture')


def request(port, host='127.0.0.1'):
    # Never inherit a proxy from the operator's shell.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f'http://{host}:{port}', timeout=2) as response:
        return response.status


def serve(host, port):
    server = ThreadingHTTPServer((host, port), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def udp_server(host):
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind((host, 53))
    def echo():
        while True:
            try:
                data, address = server.recvfrom(128)
                server.sendto(data, address)
            except OSError:
                return
    threading.Thread(target=echo, daemon=True).start()
    return server


def udp_request(host):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(2)
        client.sendto(b'synthetic-dns-transport', (host, 53))
        return client.recv(128) == b'synthetic-dns-transport'


def peer(args):
    assert os.readlink('/proc/self/ns/net') != args.parent_network
    with socket.socket(fileno=args.peer_fd) as channel_socket:
        channel = channel_socket.makefile('rw')
        channel.write('ready\n'); channel.flush()
        assert channel.readline() == 'configure\n'
        for command in [
            ['link', 'set', 'lo', 'up'],
            ['address', 'add', '198.18.0.2/30', 'dev', 'fixture-peer'],
            ['link', 'set', 'fixture-peer', 'up'],
            ['address', 'add', '93.184.216.34/32', 'dev', 'lo'],
        ]:
            subprocess.run([args.ip, *command], check=True)
        for address in PRIVATE_PEERS:
            subprocess.run([args.ip, 'address', 'add', address + '/32', 'dev', 'lo'], check=True)
        servers = [serve('0.0.0.0', port) for port in (53, 80, 443, 8443)]
        udp = udp_server('0.0.0.0')
        channel.write('configured\n'); channel.flush()
        try:
            channel.readline()
        finally:
            udp.close()
            for server in servers:
                server.shutdown(); server.server_close()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--nft', required=True)
    p.add_argument('--ip', required=True)
    p.add_argument('--rules-file', type=Path, required=True)
    p.add_argument('--honcho-enabled', action='store_true')
    p.add_argument('--inside', action='store_true')
    p.add_argument('--outer-network')
    p.add_argument('--peer-fd', type=int)
    p.add_argument('--parent-network')
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
    if args.peer_fd is not None:
        return peer(args)
    subprocess.run([args.ip,'link','set','lo','up'],check=True)
    servers=[serve('127.0.0.1',port) for port in [18090,18092,9119,8081,18093,18094,8000,5432,443]]
    servers.append(serve('127.0.0.53', 53))
    subprocess.run([args.ip, 'address', 'add', '93.184.216.35/32', 'dev', 'lo'], check=True)
    servers.append(serve('93.184.216.35', 443))
    udp = udp_server('127.0.0.53')
    assert all(request(port)==200 for port in [18090,18092,9119,8081,18093,18094,8000,5432])
    rules=args.rules_file.read_text()
    if rules.count('meta skuid "hermes"')!=10:
        raise RuntimeError('Canonical rules do not match the test mapping contract')
    # A second private network supplies public/private destination controls.
    # The public address exists only here; neither namespace has a host uplink.
    a, b = socket.socketpair()
    a.settimeout(10)
    child = subprocess.Popen([
        '/run/current-system/sw/bin/unshare', '-n', sys.executable, __file__,
        *sys.argv[1:], '--peer-fd', str(b.fileno()),
        '--parent-network', os.readlink('/proc/self/ns/net'),
    ], pass_fds=(b.fileno(),))
    b.close()
    channel = a.makefile('rw')
    try:
        assert channel.readline() == 'ready\n'
        assert os.readlink(f'/proc/{child.pid}/ns/net') != os.readlink('/proc/self/ns/net')
        assert os.readlink(f'/proc/{child.pid}/ns/user') == os.readlink('/proc/self/ns/user')
        for command in [
            ['link', 'add', 'fixture-out', 'type', 'veth', 'peer', 'name', 'fixture-peer'],
            ['link', 'set', 'fixture-peer', 'netns', str(child.pid)],
            ['address', 'add', '198.18.0.1/30', 'dev', 'fixture-out'],
            ['link', 'set', 'fixture-out', 'up'],
            ['route', 'add', '93.184.216.34/32', 'via', '198.18.0.2'],
        ]:
            subprocess.run([args.ip, *command], check=True)
        for address in PRIVATE_PEERS:
            subprocess.run([args.ip, 'route', 'add', address + '/32', 'via', '198.18.0.2'], check=True)
        channel.write('configure\n'); channel.flush()
        assert channel.readline() == 'configured\n'
        assert all(request(port, '93.184.216.34') == 200 for port in (53,80,443,8443))
        assert request(443, '198.18.0.2') == 200
        assert all(request(443, host) == 200 for host in (*PRIVATE_PEERS, '93.184.216.35'))
        assert request(53, '127.0.0.53') == 200 and udp_request('127.0.0.53')
        assert udp_request('93.184.216.34')
        check_policy(args, rules)
    finally:
        channel.close(); a.close()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.terminate(); child.wait(timeout=5)
        udp.close()
        for server in servers:
            server.shutdown(); server.server_close()


def check_policy(args, rules):
    # Only the UID name is replaced: namespace UID 0 maps to the unprivileged operator.
    rules=rules.replace('meta skuid "hermes"','meta skuid 0')
    subprocess.run([args.nft,'--file','-'],input=rules,text=True,check=True)
    assert request(18090)==200
    assert request(18092)==200,'Fixed local owner RPC was not reachable'
    assert request(9119)==200,'Same-host dashboard WebSocket transport was not reachable'
    if args.honcho_enabled:
        assert request(8000)==200,'Local Honcho API was not reachable'
    for forbidden in [443,8081,18093,18094,5432] + ([] if args.honcho_enabled else [8000]):
        try:
            request(forbidden)
        except (urllib.error.URLError,TimeoutError,OSError):
            denied=True
        else:
            denied=False
        assert denied,f'Forbidden local port {forbidden} was reachable'
    assert request(18090)==200,'Allowed inference or reply traffic was broken'
    assert request(443, '93.184.216.34') == 200, 'Public HTTPS transport denied'
    assert request(53, '127.0.0.53') == 200 and udp_request('127.0.0.53'), 'Stub DNS denied'
    forbidden_targets = [('93.184.216.34', p) for p in (53,80,8443)]
    forbidden_targets += [(host,443) for host in (*PRIVATE_PEERS, '198.18.0.2', '93.184.216.35')]
    for host, port in forbidden_targets:
        try:
            request(port, host)
        except (urllib.error.URLError,TimeoutError,OSError):
            pass
        else:
            raise AssertionError(f'Forbidden destination {host}:{port} was reachable')
    try:
        udp_request('93.184.216.34')
    except OSError:
        pass
    else:
        raise AssertionError('External UDP DNS was reachable')
    print(json.dumps({'private_namespace_verified':True,'baseline_all_ports_reachable':True,'inference_allowed':True,'fixed_owner_rpc_allowed':True,'same_host_dashboard_allowed':True,'honcho_api_allowed':args.honcho_enabled,'database_and_memory_inference_denied':True,'direct_upstream_denied':True,'arbitrary_loopback_denied':True,'reply_traffic_allowed':True,'public_https_allowed':True,'stub_dns_allowed':True,'private_https_and_external_dns_denied':True,'host_firewall_changed':False}))


if __name__=='__main__':main()
