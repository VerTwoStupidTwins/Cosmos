"""Real OpenConcho + Honcho OCI acceptance against a private, disposable database."""
import base64
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

os.umask(0o077)
assert os.geteuid() != 0, 'Run only as the unprivileged Odin operator'
ROOT = Path('/home/twins/.cache/cosmos-specialist-tests/honcho-local')
RUN = ROOT / 'openconcho' / ('fixture-' + secrets.token_hex(5))
RUN.mkdir(mode=0o700, parents=True)
(RUN / 'PUBLIC_DISPOSABLE_FIXTURE').touch()
PG = Path('/nix/store/nwqpn9hcpz6ri2bplh089fm64lcd9qkv-postgresql-and-plugins-17.11/bin')
POD = ['podman', '--storage-driver=overlay', '--root', str(ROOT / 'podman-overlay-storage'), '--runroot', str(ROOT / 'podman-overlay-run')]
DATA, SOCK = RUN / 'postgres', RUN / 'socket'
SOCK.mkdir(mode=0o700)
containers = []
started = False
result = {'scratch': str(RUN)}


def execute(command, stdin=None, env=None, timeout=180):
    p = subprocess.run(command, input=stdin, env=env, text=True, capture_output=True, timeout=timeout)
    if p.returncode:
        (RUN / 'command-error.log').write_text(p.stdout + p.stderr)
        raise RuntimeError('Fixture command failed; diagnostic retained privately')
    return p.stdout.strip()


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def request(port, method, path, body=None, auth=None, extra=None):
    headers = {'Content-Type': 'application/json', **(extra or {})}
    if auth:
        headers['Authorization'] = auth
    req = urllib.request.Request(f'http://127.0.0.1:{port}' + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def ready(port, path):
    for _ in range(120):
        try:
            if request(port, 'GET', path)[0] == 200:
                return
        except (urllib.error.URLError, TimeoutError):
            pass
        time.sleep(1)
    raise RuntimeError('Disposable service readiness timed out')


try:
    execute([str(PG / 'initdb'), '-D', str(DATA), '--locale=C', '--encoding=UTF8', '--auth-local=peer', '--auth-host=reject'])
    (DATA / 'pg_hba.conf').write_text('local all honcho peer map=fixture\nlocal all twins peer\n')
    (DATA / 'pg_ident.conf').write_text('fixture twins honcho\n')
    with (DATA / 'postgresql.conf').open('a') as f:
        f.write("\nlisten_addresses = ''\nunix_socket_directories = '" + str(SOCK) + "'\n")
    execute([str(PG / 'pg_ctl'), '-D', str(DATA), '-l', str(RUN / 'postgres.log'), '-w', 'start'])
    started = True
    execute([str(PG / 'psql'), '-h', str(SOCK), '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], stdin='CREATE ROLE honcho LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION; CREATE DATABASE honcho OWNER honcho;')
    execute([str(PG / 'psql'), '-h', str(SOCK), '-d', 'honcho', '-v', 'ON_ERROR_STOP=1'], stdin='CREATE EXTENSION vector; CREATE EXTENSION pg_trgm; CREATE EXTENSION btree_gin;')
    creds, viewer = RUN / 'honcho', RUN / 'viewer'
    creds.mkdir(mode=0o700)
    viewer.mkdir(mode=0o700)
    execute([sys.executable, '/Cosmos/packages/honcho-credentials.py', '--state-dir', str(creds)])
    htpasswd = '/nix/store/2aynq10g4n1s0bmya4qgm74mfnsm087q-apache-httpd-2.4.69/bin/htpasswd'
    execute([sys.executable, '/Cosmos/packages/openconcho-credentials.py', '--state-dir', str(viewer), '--signing-key', str(creds / 'signing.key'), '--core', '/Cosmos/packages/honcho-credentials.py', '--htpasswd', htpasswd])
    api_port, ui_port = free_port(), free_port()
    assert api_port != 8000 and ui_port != 9120 and api_port != ui_port
    api_env = json.loads(execute(['nix', 'eval', '--no-write-lock-file', '--json', 'path:/Cosmos#nixosConfigurations.odin.config.virtualisation.oci-containers.containers.honcho-api.environment']))
    api_env['HONCHO_API_PORT'] = str(api_port)
    envfile = RUN / 'api.env'
    envfile.write_text('\n'.join(k + '=' + v for k, v in api_env.items()) + '\n')
    child_env = dict(os.environ, AUTH_JWT_SECRET=(creds / 'signing.key').read_text().strip())
    api = RUN.name + '-api'
    containers.append(api)
    cache = (ROOT / 'tokenizer-cache-path').read_text().strip()
    execute(POD + ['run', '-d', '--name', api, '--network=host', '--pull=never', '--read-only', '--userns=keep-id:uid=100,gid=101', '--user=100:101', '--cap-drop=ALL', '--security-opt=no-new-privileges', '--log-driver=k8s-file', '--log-opt=path=' + str(RUN / 'api.log'), '--tmpfs=/tmp:rw,nosuid,nodev,mode=1777', '-v', str(SOCK) + ':/run/postgresql:ro', '-v', cache + ':/opt/tiktoken:ro', '-v', '/Cosmos/packages/honcho-entrypoint.py:/opt/entry.py:ro', '--env-file', str(envfile), '--env=AUTH_JWT_SECRET', '--entrypoint=/app/.venv/bin/python', 'ghcr.io/plastic-labs/honcho:3.4.0', '/opt/entry.py', 'api'], env=child_env)
    ready(api_port, '/health')
    result['disposable_honcho_ready'] = True
    image = execute(['nix', 'build', '--no-write-lock-file', '--no-link', '--print-out-paths', 'path:/Cosmos#packages.x86_64-linux.openconcho-image'])
    execute(POD + ['load', '-i', image])
    expr = 'let f=builtins.getFlake "path:/Cosmos"; p=f.inputs.nixpkgs.legacyPackages.x86_64-linux; in p.callPackage /Cosmos/packages/openconcho-nginx.nix { listenAddress="127.0.0.1"; port=' + str(ui_port) + '; upstream="http://127.0.0.1:' + str(api_port) + '"; }'
    nginx = execute(['nix', 'build', '--no-write-lock-file', '--impure', '--no-link', '--print-out-paths', '--expr', expr])
    cfg = RUN / 'config.js'
    cfg.write_text('window.__OPENCONCHO_DEFAULT_HONCHO_URL__ = "http://127.0.0.1:8000";\n')
    child_env = dict(os.environ, **dict(line.split('=', 1) for line in (viewer / 'container.env').read_text().splitlines()))
    web = RUN.name + '-web'
    containers.append(web)
    execute(POD + ['run', '-d', '--name', web, '--network=host', '--pull=never', '--read-only', '--userns=keep-id:uid=101,gid=101', '--user=101:101', '--cap-drop=ALL', '--security-opt=no-new-privileges', '--pids-limit=128', '--memory=512m', '--http-proxy=false', '--log-driver=k8s-file', '--log-opt=path=' + str(RUN / 'web.log'), '--tmpfs=/tmp:rw,nosuid,nodev,mode=1777', '-v', '/Cosmos/packages/openconcho-start.sh:/opt/cosmos-start.sh:ro', '-v', nginx + ':/opt/cosmos-nginx.conf:ro', '-v', str(cfg) + ':/opt/cosmos-config.js:ro', '--env=OPENCONCHO_API_TOKEN', '--env=OPENCONCHO_HTPASSWD', '--entrypoint=/bin/sh', 'ghcr.io/offendingcommit/openconcho-web:0.17.1', '/opt/cosmos-start.sh'], env=child_env)
    ready(ui_port, '/healthz')
    login = json.loads((viewer / 'login.json').read_text())
    basic = 'Basic ' + base64.b64encode((login['username'] + ':' + login['password']).encode()).decode()
    for path in ['/', '/config.js', '/api/v3/workspaces/list']:
        assert request(ui_port, 'GET' if path != '/api/v3/workspaces/list' else 'POST', path, {} if path.endswith('/list') else None)[0] == 401, path
    assert request(ui_port, 'GET', '/', auth='Basic ' + base64.b64encode(b'viewer:wrong-public-fixture-password').decode())[0] == 401
    result['unauthenticated_and_wrong_password_rejected'] = True
    status, html, headers = request(ui_port, 'GET', '/', auth=basic)
    assert status == 200 and b'openconcho' in html.lower()
    asset = re.search(rb'src="([^"]+\.js)"', html).group(1).decode()
    assert request(ui_port, 'GET', asset, auth=basic)[0] == 200
    for path in ['/', '/config.js', asset]:
        body = request(ui_port, 'GET', path, auth=basic)[1]
        assert child_env['OPENCONCHO_API_TOKEN'].encode() not in body and login['password'].encode() not in body
    assert "connect-src 'self'" in headers['Content-Security-Policy']
    result['upstream_spa_assets_and_no_browser_backend_token'] = True
    def proxy(method, path, body=None, extra=None):
        status, raw, _ = request(ui_port, method, '/api' + path, body, basic, extra)
        if status not in (200, 201, 204):
            (RUN / 'http-error.json').write_bytes(raw)
            raise RuntimeError('Disposable Honcho proxy operation failed: ' + str(status))
        return json.loads(raw) if raw else None
    proxy('POST', '/v3/workspaces', {'id': 'personal'})
    listed = proxy('POST', '/v3/workspaces/list', {})
    assert any(x.get('id', x.get('name')) == 'personal' for x in listed['items'])
    proxy('POST', '/v3/workspaces/personal/peers', {'id': 'public-viewer-person'})
    proxy('POST', '/v3/workspaces/personal/sessions', {'id': 'public-viewer-session', 'peers': {'public-viewer-person': {'observe_me': False, 'observe_others': False}}})
    proxy('POST', '/v3/workspaces/personal/sessions/public-viewer-session/messages', {'messages': [{'peer_id': 'public-viewer-person', 'content': 'PUBLIC DISPOSABLE FIXTURE: stored message visible through OpenConcho.'}]})
    for path in ['/peers/list', '/sessions/list', '/sessions/public-viewer-session/messages/list']:
        data = proxy('POST', '/v3/workspaces/personal' + path, {})
        assert data['items']
    proxy('POST', '/v3/workspaces/personal/conclusions', {'conclusions': [{'content': 'PUBLIC DISPOSABLE FIXTURE: the example colour is cobalt.', 'observer_id': 'public-viewer-person', 'observed_id': 'public-viewer-person'}]})
    conclusions = proxy('POST', '/v3/workspaces/personal/conclusions/list', {})
    assert conclusions['items']
    result['real_workspace_peer_session_message_conclusion_browsing'] = True
    spoofed = proxy('POST', '/v3/workspaces/list', {}, {'X-Honcho-Upstream': 'http://127.0.0.1:1'})
    assert spoofed['items']
    result['fixed_local_upstream_not_header_selected'] = True
    execute(POD + ['restart', web])
    ready(ui_port, '/healthz')
    assert proxy('POST', '/v3/workspaces/personal/sessions/public-viewer-session/messages/list', {})['items']
    result['container_restart_and_login_recovery'] = True
    result['passed'] = True
finally:
    for name in reversed(containers):
        subprocess.run(POD + ['rm', '-f', '--ignore', name], capture_output=True, text=True)
    if started:
        subprocess.run([str(PG / 'pg_ctl'), '-D', str(DATA), '-m', 'fast', '-w', 'stop'], capture_output=True, text=True)
    (RUN / 'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
