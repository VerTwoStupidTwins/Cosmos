"""RED/GREEN proof using real nft in disposable user/network namespaces.

Only reads the public store artifact named by the loaded egress unit. Candidate
rules remain a private fixture, never host source or a deployed policy.
"""
import argparse
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import threading
import time

NFT = '/nix/store/731gh86rhap0py5q65xz8mdhc6qfq8j0-nftables-1.1.7/bin/nft'
IP = '/nix/store/y9qysn0swmsr7mcknww5f40vch93i4cv-iproute2-7.1.0/bin/ip'
UNSHARE = '/run/current-system/sw/bin/unshare'
RESULT = Path('/home/twins/.hermes/profiles/cosmos/cache/scratch/hermes-dashboard-egress-result.json')
RULE = '    meta skuid "hermes" meta nfproto ipv4 fib daddr type local tcp dport 9119 accept\n'
ANCHOR = '    meta skuid "hermes" counter reject\n'
EXPECTED_OLD = (
    'destroy table inet cosmos_hermes\n'
    'table inet cosmos_hermes {\n'
    '  chain output {\n'
    '    type filter hook output priority -5; policy accept;\n'
    '    meta skuid "hermes" ct direction reply ct state established,related accept\n'
    '    meta skuid "hermes" ip daddr 127.0.0.1 tcp dport { 18090, 18092 } accept\n'
    '    meta skuid "hermes" counter reject\n'
    '  }\n'
    '}\n'
)
TARGETS = {
    'self_dashboard': ('192.0.2.10', 9119),
    'loopback_dashboard': ('127.0.0.1', 9119),
    'remote_sameport': ('198.51.100.2', 9119),
    'inference': ('127.0.0.1', 18090),
    'owner_rpc': ('127.0.0.1', 18092),
    'management': ('127.0.0.1', 8081),
    'self_management': ('192.0.2.10', 8081),
    'arbitrary_loopback': ('127.0.0.1', 18093),
}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, capture_output=True,
                          timeout=10, **kwargs).stdout


def namespace(kind):
    return os.readlink('/proc/self/ns/' + kind)


def verify_private(args):
    mapping = Path('/proc/self/uid_map').read_text().split()
    require(os.geteuid() == 0, 'Inside UID is not namespace root')
    require(mapping == ['0', str(args.outer_uid), '1'] and args.outer_uid != 0,
            'Unsafe UID mapping')
    require(namespace('net') != args.outer_net, 'Host network namespace detected')
    require(namespace('user') != args.outer_user, 'Host user namespace detected')
    return {'uid_map': [int(x) for x in mapping], 'outer_net': args.outer_net,
            'private_net': namespace('net'), 'outer_user': args.outer_user,
            'private_user': namespace('user'), 'inside_euid': os.geteuid()}


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        body = self.server.fixture_body
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def server(address, port, marker):
    srv = ThreadingHTTPServer((address, port), Fixture)
    srv.fixture_body = marker
    srv.daemon_threads = True
    return srv


def read_message(fd, timeout=10):
    with selectors.DefaultSelector() as selector:
        selector.register(fd, selectors.EVENT_READ)
        require(selector.select(timeout), 'Peer synchronization timed out')
        data = os.read(fd, 65536)
    require(data, 'Peer exited before synchronization')
    return json.loads(data)


def peer(args):
    verify_private(args)
    require(namespace('net') != args.parent_net, 'Peer network is not isolated')
    require(namespace('user') == args.parent_user, 'Peer user namespace mismatch')
    os.write(args.ready_fd, (json.dumps({'net': namespace('net'),
                                       'user': namespace('user')}) + '\n').encode())
    require(os.read(args.go_fd, 1) == b'G', 'Parent did not authorize setup')
    run([IP, 'link', 'set', 'lo', 'up'])
    run([IP, 'addr', 'add', '198.51.100.2/30', 'dev', 'hdpeer'])
    run([IP, 'link', 'set', 'hdpeer', 'up'])
    srv = server('198.51.100.2', 9119, b'isolated-peer')
    os.write(args.ready_fd, b'{"listening":true}\n')
    os.close(args.ready_fd)
    os.close(args.go_fd)
    try:
        srv.serve_forever(poll_interval=0.05)
    finally:
        srv.server_close()


def probe(name):
    address, port = TARGETS[name]
    connection = http.client.HTTPConnection(address, port, timeout=1.5)
    start = time.monotonic()
    record = {'address': address, 'port': port}
    try:
        connection.request('GET', '/')
        response = connection.getresponse()
        body = response.read()
        record.update(reachable=response.status == 200,
                      status=response.status, fixture_body=body.decode('ascii'))
        require(body == (b'isolated-peer' if name == 'remote_sameport' else b'isolated-self'),
                'Unexpected responder')
    except (OSError, http.client.HTTPException) as exc:
        record.update(reachable=False, error_type=type(exc).__name__,
                      errno=getattr(exc, 'errno', None))
    finally:
        connection.close()
    record['elapsed_seconds'] = round(time.monotonic() - start, 6)
    return record


def phase(report, name, allowed):
    probes = {target: probe(target) for target in TARGETS}
    report[name] = {'probes': probes, 'expected_allowed': sorted(allowed)}
    for target, observed in probes.items():
        require(observed['reachable'] == (target in allowed),
                name + ': unexpected reachability of ' + target)
    report[name]['passed'] = True


def apply_policy(text):
    require(text.count('meta skuid "hermes"') in (3, 4), 'Unexpected UID substitution count')
    mapped = text.replace('meta skuid "hermes"', 'meta skuid 0')
    run([NFT, '--file', '-'], input=mapped)
    readback = json.loads(run([NFT, '--json', 'list', 'ruleset']))
    tables = [x['table'] for x in readback['nftables'] if 'table' in x]
    require(len(tables) == 1 and tables[0]['name'] == 'cosmos_hermes',
            'Private nft readback table mismatch')
    return {'uid_name_replacement_only': True,
            'mapped_rules_sha256': hashlib.sha256(mapped.encode()).hexdigest(),
            'private_nft_readback': readback}


def exercise(args, report):
    report['isolation'] = verify_private(args)
    initial = json.loads(run([NFT, '--json', 'list', 'ruleset']))
    require(not any('table' in row for row in initial['nftables']),
            'New namespace unexpectedly has nft tables')
    report['initial_private_ruleset_empty'] = True
    require(args.rules_file.startswith('/nix/store/') and args.rules_file.endswith('.nft'),
            'Rules must be a public store artifact')
    actual = Path(args.rules_file).read_text()
    require(actual == EXPECTED_OLD, 'Unit no longer names the exact expected OLD artifact')
    candidate = actual.replace(ANCHOR, RULE + ANCHOR)
    require(actual.count(ANCHOR) == 1 and candidate.replace(RULE, '') == actual,
            'Candidate must be exactly one literal insertion')
    if args.candidate_rules_file:
        path = args.candidate_rules_file
        require(path.startswith('/nix/store/') and path.endswith('.nft'),
                'Canonical candidate must be a public store artifact')
        canonical = Path(path).read_text()
        def meaningful(text):
            return [line.strip() for line in text.splitlines()
                    if line.strip() and not line.lstrip().startswith('#')]
        require(meaningful(canonical) == meaningful(candidate),
                'Canonical policy differs from the reviewed one-rule insertion')
        candidate = canonical
    report['policy'] = {'actual_old_artifact': args.rules_file,
                        'actual_old_exact_match': True,
                        'actual_old_sha256': hashlib.sha256(actual.encode()).hexdigest(),
                        'actual_old_rules': actual,
                        'candidate_source': args.candidate_rules_file or 'private fixture, NOT host source or deployed firewall',
                        'candidate_one_rule_only': True, 'inserted_literal': RULE.strip(),
                        'candidate_rules': candidate,
                        'candidate_sha256': hashlib.sha256(candidate.encode()).hexdigest()}
    servers, threads, fds = [], [], []
    child = None
    try:
        run([IP, 'link', 'set', 'lo', 'up'])
        run([IP, 'addr', 'add', '192.0.2.10/32', 'dev', 'lo'])
        ready_r, ready_w = os.pipe()
        go_r, go_w = os.pipe()
        fds.extend([ready_r, ready_w, go_r, go_w])
        command = [UNSHARE, '-n', sys.executable, __file__, '--peer',
                   '--outer-net', args.outer_net, '--outer-user', args.outer_user,
                   '--outer-uid', str(args.outer_uid), '--parent-net', namespace('net'),
                   '--parent-user', namespace('user'), '--ready-fd', str(ready_w),
                   '--go-fd', str(go_r)]
        child = subprocess.Popen(command, pass_fds=(ready_w, go_r),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        os.close(ready_w); fds.remove(ready_w)
        os.close(go_r); fds.remove(go_r)
        peer_info = read_message(ready_r)
        require(peer_info['net'] != namespace('net') and peer_info['user'] == namespace('user'),
                'Peer namespace identity mismatch')
        report['peer_isolation'] = peer_info | {'pid': child.pid}
        run([IP, 'link', 'add', 'hdself', 'type', 'veth', 'peer', 'name', 'hdpeer'])
        run([IP, 'link', 'set', 'hdpeer', 'netns', str(child.pid)])
        run([IP, 'addr', 'add', '198.51.100.1/30', 'dev', 'hdself'])
        run([IP, 'link', 'set', 'hdself', 'up'])
        os.write(go_w, b'G')
        require(read_message(ready_r).get('listening'), 'Peer did not listen')
        for port in (9119, 18090, 18092, 8081, 18093):
            srv = server('0.0.0.0', port, b'isolated-self')
            servers.append(srv)
            thread = threading.Thread(target=srv.serve_forever,
                                      kwargs={'poll_interval': 0.05}, daemon=True)
            thread.start()
            threads.append(thread)
        report['routes'] = {kind: json.loads(run([IP, '-j', 'route', 'get', address]))
                            for kind, address in [('self', '192.0.2.10'),
                                                  ('remote_peer', '198.51.100.2')]}
        require(report['routes']['self'][0].get('type') == 'local', 'Self FIB is not local')
        require(report['routes']['remote_peer'][0].get('dev') == 'hdself' and
                report['routes']['remote_peer'][0].get('type') != 'local',
                'Remote peer incorrectly has a local FIB route')
        phase(report, 'baseline_no_filter', set(TARGETS))
        report['red_old_policy'] = apply_policy(actual)
        phase(report, 'red_old_filter', {'inference', 'owner_rpc'})
        try:
            require(report['red_old_filter']['probes']['self_dashboard']['reachable'],
                    'Self dashboard TCP9119 must be reachable')
        except AssertionError as expected:
            report['red_old_filter']['desired_assertion'] = 'EXPECTED_FAIL'
            report['red_old_filter']['failure'] = str(expected)
        else:
            raise AssertionError('RED unexpectedly passed the desired dashboard assertion')
        report['green_candidate_policy'] = apply_policy(candidate)
        phase(report, 'green_candidate_filter',
              {'self_dashboard', 'loopback_dashboard', 'inference', 'owner_rpc'})
        report['green_candidate_filter']['desired_assertion'] = 'PASS'
        # Only the private table is deleted; prove the very same peer stays healthy.
        run([NFT, 'delete', 'table', 'inet', 'cosmos_hermes'])
        phase(report, 'postfilter_no_filter', set(TARGETS))
    finally:
        cleanup = report.setdefault('cleanup', {})
        if child is not None:
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
            cleanup['exact_peer_pid_reaped'] = child.pid
            cleanup['peer_returncode'] = child.returncode
            child.stderr.close()
        for srv in servers:
            srv.shutdown()
            srv.server_close()
        for thread in threads:
            thread.join(timeout=3)
        cleanup['all_self_servers_closed'] = len(servers)
        cleanup['all_server_threads_stopped'] = all(not t.is_alive() for t in threads)
        for fd in fds:
            os.close(fd)
        require(cleanup['all_server_threads_stopped'], 'Fixture thread survived cleanup')


def main():
    global RESULT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate-rules-file')
    parser.add_argument('--result', default=str(RESULT))
    parser.add_argument('--inside', action='store_true')
    parser.add_argument('--peer', action='store_true')
    parser.add_argument('--outer-net')
    parser.add_argument('--outer-user')
    parser.add_argument('--outer-uid', type=int)
    parser.add_argument('--parent-net')
    parser.add_argument('--parent-user')
    parser.add_argument('--ready-fd', type=int)
    parser.add_argument('--go-fd', type=int)
    parser.add_argument('--rules-file')
    args = parser.parse_args()
    RESULT = Path(args.result)
    if args.peer:
        peer(args)
        return
    if not args.inside:
        require(os.geteuid() != 0, 'Refusing host-root execution')
        unit = run(['systemctl', 'show', 'cosmos-hermes-egress.service',
                    '--property=ExecStart', '--value'])
        match = re.search(r'--file (/nix/store/[^ ;]+\.nft)', unit)
        require(match is not None, 'Could not discover public egress artifact')
        command = [UNSHARE, '-Urn', sys.executable, __file__, '--inside',
                   '--outer-net', namespace('net'), '--outer-user', namespace('user'),
                   '--outer-uid', str(os.geteuid()), '--rules-file', args.rules_file or match[1],
                   '--result', str(RESULT)]
        if args.candidate_rules_file:
            command += ['--candidate-rules-file', args.candidate_rules_file]
        raise SystemExit(subprocess.call(command, timeout=60))
    report = {'test': 'hermes-dashboard-egress', 'success': False,
              'host_firewall_changed': False, 'live_services_changed': False,
              'result_path': str(RESULT)}
    try:
        exercise(args, report)
        report['success'] = True
    except Exception as exc:
        report['error'] = {'type': type(exc).__name__, 'message': str(exc)}
    finally:
        RESULT.parent.mkdir(parents=True, exist_ok=True)
        RESULT.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'success': report['success'], 'result_path': str(RESULT),
                      'red': report.get('red_old_filter', {}).get('desired_assertion'),
                      'green': report.get('green_candidate_filter', {}).get('desired_assertion'),
                      'error': report.get('error'), 'cleanup': report.get('cleanup')}))
    raise SystemExit(0 if report['success'] else 1)


if __name__ == '__main__':
    main()
