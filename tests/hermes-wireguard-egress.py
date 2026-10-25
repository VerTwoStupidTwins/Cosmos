#!/usr/bin/env python3
"""Real kernel WireGuard regression; run unprivileged on Odin, never host root.

Set HERMES_TEST_NFT, HERMES_TEST_WG, HERMES_TEST_RULES and
HERMES_TEST_OUTPUT_DIR to pinned tools, generated rules and private scratch.
Green tests the actual generated policy; red removes only its marked transport
exception. Peer-origin control checks both conntrack directions. No production
network or service mutations; ephemeral private keys are removed on exit.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

PY = sys.executable
IP = '/run/current-system/sw/bin/ip'
NFT = os.environ['HERMES_TEST_NFT']
WG = os.environ['HERMES_TEST_WG']
UNSHARE = '/run/current-system/sw/bin/unshare'
RULES = Path(os.environ['HERMES_TEST_RULES'])
ROOT = Path(os.environ['HERMES_TEST_OUTPUT_DIR'])
CANDIDATE = ('meta skuid "hermes" meta nfproto ipv4 meta mark 0x1bd00 '
             'oifname "enp4s0" fib daddr type != local udp sport 58120 counter accept')
FIXTURE_CANDIDATE = CANDIDATE.replace('meta skuid "hermes"', 'meta skuid 0').replace('"enp4s0"', '"fixture-out"')


def run(*argv, text=None):
    p = subprocess.run(argv, input=text, text=True, capture_output=True)
    if p.returncode:
        raise RuntimeError(f'{Path(argv[0]).name} failed: {p.stderr.strip()}')
    return p.stdout.strip()


def ns(kind):
    return os.readlink('/proc/self/ns/' + kind)


def verified(args, peer=False):
    mapping = Path('/proc/self/uid_map').read_text().split()
    assert os.geteuid() == 0, 'Not private namespace root'
    assert mapping == ['0', str(args.host_uid), '1', '1', '100000', '65536'] and args.host_uid != 0, 'Unsafe UID map'
    assert ns('user') != args.host_user and ns('net') != args.host_net, 'Host namespace refused'
    if peer:
        assert ns('user') == args.parent_user and ns('net') != args.parent_net, 'Peer separation failed'
    return {'uid_map': mapping, 'user_namespace_private': True, 'network_namespace_private': True}


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(2)
            if self.request.recv(128):
                self.request.sendall(b'synthetic-dashboard-reply')
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def serve(address):
    server = Server(address, Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def tcp_probe(address):
    try:
        with socket.create_connection(address, timeout=1.5) as s:
            s.sendall(b'synthetic-request')
            return {'ok': s.recv(128) == b'synthetic-dashboard-reply'}
    except OSError as e:
        return {'ok': False, 'errno': e.errno, 'error': type(e).__name__}


def peer(args):
    checks = verified(args, peer=True)
    channel = socket.socket(fileno=args.fd).makefile('rw')
    servers = []
    try:
        channel.write(json.dumps({'ready': checks, 'pid': os.getpid()}) + '\n'); channel.flush()
        for line in channel:
            msg = json.loads(line)
            if msg['op'] == 'configure':
                run(IP, 'link', 'set', 'lo', 'up')
                run(IP, 'address', 'add', '192.0.2.2/30', 'dev', 'fixture-peer')
                run(IP, 'link', 'set', 'fixture-peer', 'up')
                run(IP, 'link', 'add', 'wg-peer', 'type', 'wireguard')
                run(WG, 'set', 'wg-peer', 'private-key', msg['key_file'], 'listen-port', '58120',
                    'fwmark', '0x1bd00', 'peer', msg['public_key'], 'allowed-ips', '10.77.0.1/32',
                    'endpoint', '192.0.2.1:58120')
                run(IP, 'address', 'add', '10.77.0.2/24', 'dev', 'wg-peer')
                run(IP, 'link', 'set', 'wg-peer', 'up')
                servers = [serve(('192.0.2.2', p)) for p in (18090, 9119)] + [serve(('10.77.0.2', 9119))]
                response = {'configured': True}
            elif msg['op'] == 'request':
                response = tcp_probe(('10.77.0.1', msg.get('port', 9119)))
            elif msg['op'] == 'stop':
                channel.write(json.dumps({'stopped': True}) + '\n'); channel.flush()
                break
            else:
                raise RuntimeError('Unknown fixture command')
            channel.write(json.dumps(response) + '\n'); channel.flush()
    finally:
        for s in servers:
            s.shutdown(); s.server_close()
        channel.close()


def udp_probe(source_port, mark=0, destination='192.0.2.2', family=socket.AF_INET):
    stage = 'socket'
    try:
        with socket.socket(family, socket.SOCK_DGRAM) as s:
            stage = 'set_mark'
            s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, mark)
            stage = 'bind'
            s.bind(('::' if family == socket.AF_INET6 else '0.0.0.0', source_port))
            stage = 'sendto'
            s.sendto(b'synthetic-egress-probe', (destination, 59999))
        return {'blocked': False}
    except OSError as e:
        return {'blocked': True, 'errno': e.errno, 'error': type(e).__name__, 'stage': stage}


def counters():
    data = json.loads(run(NFT, '-j', 'list', 'table', 'inet', 'fixture_observe'))
    return {e['counter']['name']: e['counter']['packets'] for e in data['nftables'] if 'counter' in e}


def controller(args):
    checks = verified(args)
    original = RULES.read_text()
    assert original.count('meta skuid "hermes"') == 5, 'Canonical UID mapping contract changed'
    assert original.count(CANDIDATE) == 1, 'Expected exact protected transport exception'
    tested = original.replace(CANDIDATE, '') if args.mode == 'red' else original
    rules = tested.replace(CANDIDATE, FIXTURE_CANDIDATE).replace('meta skuid "hermes"', 'meta skuid 0')
    child = None
    server = None
    local_servers = []
    channel = None
    result = {'canonical_rules': str(RULES), 'canonical_sha256': hashlib.sha256(original.encode()).hexdigest(),
              'canonical_uid_matches_mapped': 5, 'namespace': checks, 'mode': args.mode,
              'kernel_wireguard': True, 'host_firewall_changed': False}
    with tempfile.TemporaryDirectory(prefix='keys-', dir=ROOT) as keys:
        os.chmod(keys, 0o700)
        key_paths = []
        public_keys = []
        for n in range(2):
            path = Path(keys) / f'peer{n}.key'
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as out:
                subprocess.run([WG, 'genkey'], stdout=out, check=True)
            with path.open('rb') as inp:
                pub = subprocess.run([WG, 'pubkey'], stdin=inp, capture_output=True, check=True).stdout.decode().strip()
            key_paths.append(str(path)); public_keys.append(pub)
        try:
            a, b = socket.socketpair()
            a.settimeout(12)
            child = subprocess.Popen([UNSHARE, '--net', PY, __file__, '--peer', '--fd', str(b.fileno()),
                '--host-uid', str(args.host_uid), '--host-user', args.host_user, '--host-net', args.host_net,
                '--parent-user', ns('user'), '--parent-net', ns('net')], pass_fds=(b.fileno(),),
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            b.close()
            channel = a.makefile('rw')
            ready_line = channel.readline()
            if not ready_line:
                raise RuntimeError('Peer startup failed: ' + child.stderr.read())
            ready = json.loads(ready_line)
            assert ready['pid'] == child.pid
            result['peer_namespace'] = ready['ready']
            assert os.readlink(f'/proc/{child.pid}/ns/user') == ns('user')
            assert os.readlink(f'/proc/{child.pid}/ns/net') != ns('net')
            def rpc(msg):
                channel.write(json.dumps(msg) + '\n'); channel.flush()
                return json.loads(channel.readline())
            # No ip/nft operation occurs until both namespaces have been verified.
            run(IP, 'link', 'set', 'lo', 'up')
            run(IP, 'link', 'add', 'fixture-out', 'type', 'veth', 'peer', 'name', 'fixture-peer')
            run(IP, 'link', 'set', 'fixture-peer', 'netns', str(child.pid))
            run(IP, 'address', 'add', '192.0.2.1/30', 'dev', 'fixture-out')
            run(IP, 'link', 'set', 'fixture-out', 'up')
            run(IP, 'link', 'add', 'wg-server', 'type', 'wireguard')
            run(WG, 'set', 'wg-server', 'private-key', key_paths[0], 'listen-port', '58120',
                'fwmark', '0x1bd00', 'peer', public_keys[1], 'allowed-ips', '10.77.0.2/32',
                'endpoint', '192.0.2.2:58120')
            run(IP, 'address', 'add', '10.77.0.1/24', 'dev', 'wg-server')
            run(IP, 'link', 'set', 'wg-server', 'up')
            rpc({'op': 'configure', 'key_file': key_paths[1], 'public_key': public_keys[0]})
            server = serve(('10.77.0.1', 9119))
            local_servers = [serve(('127.0.0.1', port)) for port in (18090, 18092, 8000, 9119, 8081)]
            # A genuinely different socket UID is an unfiltered control, while
            # both applications use the SAME root-created WireGuard interface.
            libc = ctypes.CDLL(None)
            assert libc.setfsuid(1) == 0
            try:
                control_server = serve(('10.77.0.1', 8081))
                local_servers.append(control_server)
            finally:
                assert libc.setfsuid(0) == 1
            inode = os.fstat(control_server.socket.fileno()).st_ino
            control_rows = [line.split() for line in Path('/proc/net/tcp').read_text().splitlines()[1:]
                if line.split()[9] == str(inode)]
            assert len(control_rows) == 1 and control_rows[0][7] == '1', 'Control socket UID was not distinct'
            result['socket_uids'] = {'protected_dashboard': 0, 'unfiltered_control': 1}
            # Register conntrack hooks BEFORE creating the UDP transport flow.
            run(NFT, '-f', '-', text='''table inet fixture_observe {
 counter inner_reply {}
 counter marked_outer_uid {}
 counter marked_outer_uid_ct_original {}
 counter marked_outer_uid_ct_reply {}
 counter marked_outer_unfiltered_uid1 {}
 chain output {
  type filter hook output priority -6; policy accept;
  meta skuid 0 tcp sport 9119 ct direction reply ct state established,related counter name inner_reply
  meta skuid 0 oifname "fixture-out" meta mark 0x1bd00 udp sport 58120 counter name marked_outer_uid
  meta skuid 0 oifname "fixture-out" meta mark 0x1bd00 udp sport 58120 ct direction original counter name marked_outer_uid_ct_original
  meta skuid 0 oifname "fixture-out" meta mark 0x1bd00 udp sport 58120 ct direction reply counter name marked_outer_uid_ct_reply
  meta skuid 1 oifname "fixture-out" meta mark 0x1bd00 udp sport 58120 counter name marked_outer_unfiltered_uid1
 }
}''')
            if args.transport_origin == 'server':
                assert tcp_probe(('10.77.0.2', 9119))['ok'], 'Server-originated warm tunnel failed'
            baseline = rpc({'op': 'request'})
            assert baseline['ok'], 'Baseline tunnel TCP failed'
            assert tcp_probe(('192.0.2.2', 18090))['ok'], 'Baseline external TCP failed'
            result['baseline_dashboard_reply'] = baseline
            result['baseline_external_tcp'] = True
            assert not udp_probe(58121)['blocked'], 'Baseline ordinary UDP failed'
            assert not udp_probe(58121, 0x1bd00)['blocked'], 'Fixture SO_MARK capability unavailable'
            assert not udp_probe(58121, 0x1bd00, '::1', socket.AF_INET6)['blocked']
            assert all(tcp_probe(('127.0.0.1', p))['ok'] for p in (18090, 18092, 8000, 9119, 8081))
            result['baseline_udp_and_loopback'] = True
            result['transport_origin'] = args.transport_origin
            before = counters()
            if args.mode == 'green':
                result['candidate_rule'] = CANDIDATE
                result['fixture_candidate_rule'] = FIXTURE_CANDIDATE
            run(NFT, '-f', '-', text=rules)
            result['dashboard_reply'] = rpc({'op': 'request'})
            after = counters()
            result['observations'] = {k: after[k] - before[k] for k in after}
            result['unfiltered_uid1_tunnel_control'] = rpc({'op': 'request', 'port': 8081})
            control_after = counters()
            result['control_outer_uid1_packets'] = control_after['marked_outer_unfiltered_uid1'] - after['marked_outer_unfiltered_uid1']
            assert result['unfiltered_uid1_tunnel_control']['ok'] and result['control_outer_uid1_packets'] > 0
            filter_rules = json.loads(run(NFT, '-j', 'list', 'table', 'inet', 'cosmos_hermes'))['nftables']
            result['canonical_reject_packets'] = sum(e.get('counter', {}).get('packets', 0)
                for obj in filter_rules if any('reject' in e for e in obj.get('rule', {}).get('expr', []))
                for e in obj.get('rule', {}).get('expr', []))
            result['candidate_accept_packets'] = sum(e.get('counter', {}).get('packets', 0)
                for obj in filter_rules if any('accept' in e for e in obj.get('rule', {}).get('expr', []))
                for e in obj.get('rule', {}).get('expr', []))
            result['ordinary_external_tcp_blocked'] = not tcp_probe(('192.0.2.2', 18090))['ok']
            result['remote_dashboard_tcp_blocked'] = not tcp_probe(('192.0.2.2', 9119))['ok']
            assert result['observations']['inner_reply'] > 0, 'No real inner TCP reply observed'
            assert result['observations']['marked_outer_uid'] > 0, 'No inherited-UID WireGuard UDP observed'
            assert result['ordinary_external_tcp_blocked'] and result['remote_dashboard_tcp_blocked']
            result['allowed_loopback_ports_preserved'] = all(tcp_probe(('127.0.0.1', p))['ok']
                for p in (18090, 18092, 8000, 9119))
            result['arbitrary_loopback_blocked'] = not tcp_probe(('127.0.0.1', 8081))['ok']
            result['same_host_nonloopback_callback_allowed'] = tcp_probe(('10.77.0.1', 9119))['ok']
            assert result['allowed_loopback_ports_preserved'] and result['arbitrary_loopback_blocked']
            assert result['same_host_nonloopback_callback_allowed']
            if args.transport_origin == 'server':
                assert result['observations']['marked_outer_uid_ct_original'] > 0
                assert result['observations']['marked_outer_uid_ct_reply'] == 0
                if args.mode == 'red':
                    assert result['canonical_reject_packets'] > 0
                else:
                    assert result['candidate_accept_packets'] > 0
            # Free the fixture-only UDP port AFTER the real kernel-WG test, then
            # prove that using the same source port without the exact mark fails.
            run(WG, 'set', 'wg-server', 'listen-port', '58122')
            run(IP, 'link', 'add', 'fixture-wrong', 'type', 'dummy')
            run(IP, 'link', 'set', 'fixture-wrong', 'up')
            run(IP, 'route', 'add', '198.51.100.2/32', 'dev', 'fixture-wrong', 'src', '192.0.2.1')
            negatives = {
                'unmarked_source_58120': udp_probe(58120),
                'ordinary_unmarked_udp': udp_probe(58121),
                'exact_mark_wrong_source_port': udp_probe(58121, 0x1bd00),
                'dataplane_mark_1bd10_source_58120': udp_probe(58120, 0x1bd10),
                'exact_mark_wrong_interface': udp_probe(58120, 0x1bd00, '198.51.100.2'),
                'exact_mark_local_destination': udp_probe(58120, 0x1bd00, '127.0.0.1'),
                'exact_mark_ipv6_loopback': udp_probe(58120, 0x1bd00, '::1', socket.AF_INET6),
            }
            assert all(v['blocked'] and v['errno'] == 1 and v['stage'] == 'sendto'
                for v in negatives.values()), negatives
            result['negative_udp_probes'] = negatives
            result['test_dashboard_reply_passed'] = result['dashboard_reply']['ok']
        finally:
            for local_server in local_servers:
                local_server.shutdown(); local_server.server_close()
            if server:
                server.shutdown(); server.server_close()
            if child:
                try:
                    if channel:
                        channel.write(json.dumps({'op': 'stop'}) + '\n'); channel.flush()
                        channel.readline()
                    child.wait(timeout=4)
                except (OSError, ValueError, subprocess.TimeoutExpired):
                    child.terminate()
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        child.kill(); child.wait()
                result['peer_process_reaped'] = child.poll() is not None
                if channel:
                    channel.close()
                child.stderr.close()
    result['ephemeral_private_keys_removed'] = not Path(keys).exists()
    outfile = ROOT / ('peer-origin-control.json' if args.transport_origin == 'peer' else args.mode + '.json')
    outfile.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True))
    return 0 if result['test_dashboard_reply_passed'] else 1


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--inside', action='store_true')
    p.add_argument('--peer', action='store_true')
    p.add_argument('--fd', type=int)
    p.add_argument('--host-uid', type=int)
    p.add_argument('--host-user')
    p.add_argument('--host-net')
    p.add_argument('--parent-user')
    p.add_argument('--parent-net')
    p.add_argument('--mode', choices=['red', 'green'], default='red')
    p.add_argument('--transport-origin', choices=['server', 'peer'], default='server')
    args = p.parse_args()
    if args.peer:
        peer(args); return 0
    if args.inside:
        return controller(args)
    if os.geteuid() == 0:
        raise RuntimeError('Host-root execution refused')
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    return subprocess.call([UNSHARE, '--user', '--map-root-user', '--map-auto', '--net', PY, __file__, '--inside',
        '--mode', args.mode, '--transport-origin', args.transport_origin,
        '--host-uid', str(os.geteuid()), '--host-user', ns('user'), '--host-net', ns('net')])


if __name__ == '__main__':
    raise SystemExit(main())
