"""Bounded Honcho readiness gate; no response bodies or credentials are logged."""
import json
import time
import urllib.error
import urllib.request


def wait_ready(*, timeout=240, interval=1, opener=urllib.request.urlopen, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    while clock() < deadline:
        try:
            with opener('http://127.0.0.1:8000/health', timeout=2) as response:
                if response.status == 200 and json.loads(response.read(4096)) == {'status': 'ok'}:
                    return
        except (OSError, ValueError, urllib.error.URLError):
            pass
        sleep(interval)
    raise TimeoutError('Honcho API did not become ready within the startup deadline')


if __name__ == '__main__':
    try:
        wait_ready()
    except TimeoutError:
        raise SystemExit('Honcho API readiness failed')
