"""Offline checks of the installed gateway and full-package integration SDKs."""
import json
import os
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

import anthropic
import discord
import openai
import telegram
from gateway.authz_mixin import GatewayAuthorizationMixin
from gateway.config import Platform, load_gateway_config
from gateway.session import SessionSource


class Gate(GatewayAuthorizationMixin):
    """Exercise upstream's sender gate without adapters, pairing or role grants."""
    def _adapter_profile_for_source(self, source):
        return None

    def _chat_scoped_grant(self, *args):
        return False

    def _pairing_store_for(self, source):
        return None

    def _adapter_flag(self, *args):
        return False

    def _adapter_extra_allowlist_authorizes(self, *args):
        return False

    def _adapter_resolved_allowlist_ids(self, source):
        return set()


settings = json.loads(Path(sys.argv[1]).read_text())
environment = json.loads(Path(sys.argv[2]).read_text())
assert settings['model']['provider'] == 'custom'
assert settings['model']['base_url'] == 'http://127.0.0.1:18090/v1'
assert settings['fallback_providers'] == []
assert not settings['stt']['enabled']
with tempfile.TemporaryDirectory() as home:
    config_path = Path(home) / 'config.yaml'
    config_path.write_text(json.dumps(settings))
    config_path.chmod(0o444)
    environment.update(HOME=home, HERMES_HOME=home)
    with patch.dict(os.environ, environment, clear=True), \
            patch('socket.socket.connect', side_effect=AssertionError('Unexpected network connection')), \
            patch('socket.getaddrinfo', side_effect=AssertionError('Unexpected DNS lookup')):
        config = load_gateway_config()
        assert Platform.TELEGRAM not in config.get_connected_platforms()
        assert Platform.DISCORD not in config.get_connected_platforms()
        # Public synthetic values: config loading must never contact a provider.
        os.environ.update(
            TELEGRAM_BOT_TOKEN='123456789:AbCdEfGhIjKlMnOpQrStUvWxYz012345678',
            DISCORD_BOT_TOKEN='AbCdEfGhIjKlMnOpQrStUvWxYz.012345.AbCdEfGhIjKlMnOpQrStUvWxYz012345678',
        )
        config = load_gateway_config()
        assert {Platform.TELEGRAM, Platform.DISCORD} <= set(config.get_connected_platforms())
        gate = Gate()
        gate.config = config
        for platform in (Platform.TELEGRAM, Platform.DISCORD):
            allowed = SessionSource(platform=platform, chat_id='101', user_id='101')
            stranger = SessionSource(platform=platform, chat_id='202', user_id='202')
            assert not gate._is_user_authorized(allowed), 'Missing allowlist must deny access'
            os.environ[platform.value.upper() + '_ALLOWED_USERS'] = '101'
            assert gate._is_user_authorized(allowed), 'Explicit user ID was denied'
            assert not gate._is_user_authorized(stranger), 'Unlisted user was admitted'
        assert json.loads(config_path.read_text()) == settings
print('Full SDKs, credential-driven messaging, sender allowlists and local default verified')
