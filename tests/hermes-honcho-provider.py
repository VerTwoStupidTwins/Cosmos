"""Real packaged Hermes provider against a disposable OCI fixture only.

The caller supplies a private synthetic HERMES_HOME. Never run this against
production: it writes public test preferences through the normal provider hooks.
"""
import argparse
import os
from pathlib import Path
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['learn', 'recall', 'correct', 'corrected-recall'])
    args = parser.parse_args()
    home = Path(os.environ['HERMES_HOME'])
    if not (home / 'PUBLIC_DISPOSABLE_FIXTURE').is_file():
        raise RuntimeError('Refusing to use a home without the disposable-fixture marker')
    from plugins.memory import load_memory_provider
    provider = load_memory_provider('honcho', register_skills=False)
    assert provider is not None and provider.name == 'honcho', 'Packaged provider did not load'
    provider.initialize('public-fixture-' + args.phase, cwd=str(home), platform='cli')
    try:
        deadline = time.monotonic() + 90
        while not provider._session_initialized and time.monotonic() < deadline:
            time.sleep(0.2)
        assert provider._session_initialized, 'Packaged provider did not initialize'
        if args.phase in ['learn', 'correct']:
            message = ('This is a synthetic public acceptance test. My favourite test colour is cobalt blue.'
                       if args.phase == 'learn' else
                       'Correction for this public test: my current favourite test colour is amber orange, not cobalt blue. Replace the previous preference.')
            provider.sync_turn(message, 'I will remember your current test colour.')
            provider.on_session_end([])
        else:
            response = provider.handle_tool_call('honcho_reasoning', {
                'query': 'What is my CURRENT favourite test colour? Use the most recent correction if there is one. Reply only with the colour.',
                'reasoning_level': 'minimal',
                'peer': 'user',
            })
            (home / ('public-response-' + args.phase + '.json')).write_text(response)
            expected = 'cobalt' if args.phase == 'recall' else 'amber'
            assert expected in response.lower(), 'Provider failed to recall the current public test preference'
        print('packaged-provider-' + args.phase + ': passed', flush=True)
    finally:
        provider.shutdown()


if __name__ == '__main__':
    main()
