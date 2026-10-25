"""Root-managed Honcho startup inside the official image; no runtime downloads."""
import argparse
import os
import subprocess
import urllib.parse

PYTHON = '/app/.venv/bin/python'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['api', 'worker'])
    args = parser.parse_args(argv)
    socket = os.environ['HONCHO_DB_SOCKET']
    if not socket.startswith('/'):
        raise ValueError('Database socket directory must be absolute')
    # Construct the passwordless peer-auth URI at runtime, not in Nix or argv.
    os.environ['DB_CONNECTION_URI'] = urllib.parse.urlunsplit((
        'postgresql+psycopg',
        urllib.parse.quote(os.environ['HONCHO_DB_USER'], safe='') + '@',
        '/' + urllib.parse.quote(os.environ['HONCHO_DB_NAME'], safe=''),
        urllib.parse.urlencode({'host': socket}),
        '',
    ))
    if args.mode == 'api':
        subprocess.run([PYTHON, 'scripts/provision_db.py'], check=True)
        # Upstream refuses dimensional changes if any embeddings are populated.
        subprocess.run([PYTHON, 'scripts/configure_embeddings.py', '--yes'], check=True)
        os.execv(PYTHON, [PYTHON, '-m', 'uvicorn', 'src.main:app', '--host', '127.0.0.1', '--port', os.environ['HONCHO_API_PORT'], '--no-access-log', '--log-level', 'warning'])
    else:
        # systemd orders the worker after the API's authenticated-schema bootstrap.
        os.execv(PYTHON, [PYTHON, '-m', 'src.deriver'])


if __name__ == '__main__':
    main()
