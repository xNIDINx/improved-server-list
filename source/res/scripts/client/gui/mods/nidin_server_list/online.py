# -*- coding: utf-8 -*-
"""Memory-only online counts from the configured shared cache service.

The service publishes {updated_at: UNIX UTC, servers: {"101": integer, ...}}.
No application ID, account token or online counts are persisted by this module.
The caller starts/stops this object with its GUI lifecycle and calls refresh()
on entering LOGIN and opening the native server list.
"""
import json
import errno
import math
import os
import urlparse

CONFIG_PATH = os.path.join('mods', 'configs', 'nidin.improved_server_list', 'online.json')
LEGACY_CONFIG_PATH = os.path.join('mods', 'configs', 'nidin.server_mode_icons', 'online.json')
DEFAULT_ENDPOINT = 'https://nidin.ru/api/server-online'
COOLDOWN = 15.0
TTL = 180.0
REQUEST_TIMEOUT = 10.0
MAX_BODY = 65536
MAX_CCU = 10000000
MAX_FUTURE_SKEW = 30.0
RU_PERIPHERIES = frozenset(range(101, 110))
RU_KEYS = frozenset(str(pid) for pid in RU_PERIPHERIES)


def _endpoint(value):
    if not isinstance(value, basestring) or not value or len(value) > 2048:
        return ''
    try:
        value = value.encode('ascii') if isinstance(value, unicode) else value
        if any(ord(char) <= 32 or ord(char) >= 127 for char in value):
            return ''
        parts = urlparse.urlsplit(value)
        host = parts.hostname
        port = parts.port
        if not host or parts.username or parts.password or parts.query or parts.fragment:
            return ''
        # Python 2 urlparse.port silently returns None for an out-of-range
        # port, so validate the literal authority suffix as well.
        suffix = parts.netloc.rsplit(']', 1)[-1] if parts.netloc.startswith('[') else parts.netloc[len(host):]
        if suffix and (not suffix.startswith(':') or not suffix[1:].isdigit() or
                       not 1 <= int(suffix[1:]) <= 65535):
            return ''
        if port is not None and not 1 <= port <= 65535:
            return ''
        if parts.scheme != 'https' and not (
                parts.scheme == 'http' and host.lower() in ('127.0.0.1', 'localhost')):
            return ''
    except (UnicodeError, ValueError):
        return ''
    return value


def read_config(path=CONFIG_PATH, legacy_path=None):
    """Honor legacy overrides only when the new config is absent."""
    if legacy_path is None and path == CONFIG_PATH:
        legacy_path = LEGACY_CONFIG_PATH
    paths = (path, legacy_path) if legacy_path is not None else (path,)
    for config_path in paths:
        try:
            with open(config_path, 'rb') as source:
                raw = source.read(16385)
            if len(raw) > 16384:
                return {}
            data = json.loads(raw)
            endpoint = _endpoint(data.get('endpoint')) if isinstance(data, dict) else ''
            return {'endpoint': endpoint} if endpoint else {}
        except (IOError, OSError) as error:
            if error.errno != errno.ENOENT:
                return {}
        except (TypeError, ValueError):
            return {}
    return {'endpoint': DEFAULT_ENDPOINT}


def fetch_url(url, callback):
    """Native asynchronous transport; callback receives (HTTP status, body).

    Signature and response fields were checked in installed 1.45 scripts.pkg:
    gui.clientgw.factory._webUrlFetcher / gui.platform.base.request._urlFetcher.
    """
    import BigWorld

    def received(response):
        callback(getattr(response, 'responseCode', 0), getattr(response, 'body', ''))

    return BigWorld.fetchURL(url, received, {'Accept': 'application/json'},
                             REQUEST_TIMEOUT, 'GET', '')


def _snapshot(body, now, ttl):
    if not isinstance(body, basestring) or len(body) > MAX_BODY:
        return None
    try:
        data = json.loads(body)
    except (TypeError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get('servers'), dict):
        return None
    updated = data.get('updated_at')
    if isinstance(updated, bool) or not isinstance(updated, (int, long, float)):
        return None
    try:
        updated = float(updated)
    except (OverflowError, ValueError):
        return None
    if math.isnan(updated) or math.isinf(updated) or updated < 0:
        return None
    if updated > now + MAX_FUTURE_SKEW or now - updated >= ttl:
        return None
    counts = {}
    for key, count in data['servers'].iteritems():
        if not isinstance(key, basestring) or key not in RU_KEYS:
            continue
        if isinstance(count, bool) or not isinstance(count, (int, long)) or not 0 <= count <= MAX_CCU:
            continue
        counts[int(key)] = count
    # Small clock skew must not extend the maximum cache age after reception.
    return min(updated, now), counts


class OnlineService(object):
    """One pending request, bounded retry rate, and invalidation of late replies."""
    def __init__(self, request_func, now_func, on_change, cooldown=COOLDOWN, ttl=TTL):
        self._request = request_func
        self._now = now_func
        self._on_change = on_change
        self._cooldown = float(cooldown)
        self._ttl = float(ttl)
        self._running = False
        self._endpoint = ''
        self._generation = 0
        self._pending = False
        self._deadline = None
        self._last_attempt = None
        self._updated_at = None
        self._counts = {}
        self._published = {}

    def start(self, config):
        self.stop()
        self._endpoint = _endpoint(config.get('endpoint')) if isinstance(config, dict) else ''
        self._running = True
        self._last_attempt = None
        return self.refresh()

    def stop(self):
        self._running = False
        self._generation += 1
        self._pending = False
        self._deadline = None
        self._endpoint = ''
        self._updated_at = None
        self._counts = {}
        self._publish()

    def get_by_periphery(self):
        if not self._running or self._updated_at is None:
            return {}
        age = self._now() - self._updated_at
        if not 0 <= age < self._ttl:
            return {}
        return dict(self._counts)

    def _publish(self):
        visible = self.get_by_periphery()
        if visible == self._published:
            return
        self._published = visible
        try:
            self._on_change()
        except Exception:
            # A UI teardown must not escape into the native HTTP callback.
            pass

    def refresh(self):
        self._publish()
        if not self._running or not self._endpoint:
            return False
        now = self._now()
        if self._pending and now >= self._deadline:
            self._generation += 1
            self._pending = False
            self._deadline = None
        if self._pending or (self._last_attempt is not None and
                             now - self._last_attempt < self._cooldown):
            return False
        self._last_attempt = now
        self._generation += 1
        generation = self._generation
        self._pending = True
        self._deadline = now + REQUEST_TIMEOUT

        def received(status, body):
            if not self._running or generation != self._generation or not self._pending:
                return
            self._pending = False
            deadline, self._deadline = self._deadline, None
            current = self._now()
            # fetchURL normally reports its own timeout; never accept a late
            # success if the engine callback itself was delayed past it.
            if current >= deadline or status != 200:
                self._publish()
                return
            result = _snapshot(body, current, self._ttl)
            if result is not None:
                self._updated_at, self._counts = result
            self._publish()

        try:
            self._request(self._endpoint, received)
        except Exception:
            self._pending = False
            self._deadline = None
            self._publish()
            return False
        return True
