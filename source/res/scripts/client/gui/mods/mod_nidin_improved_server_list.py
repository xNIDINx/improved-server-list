# -*- coding: utf-8 -*-
"""Improved server list with cached native schedules and public online counts."""
import json
import hashlib
import errno
import os
import time
import BigWorld
from constants import AUTH_REALM
from frameworks.wulf import WindowLayer
from gui.Scaleform.framework import ScopeTemplates, ViewSettings, g_entitiesFactories
from gui.Scaleform.framework.entities.View import View
from gui.Scaleform.framework.managers.loaders import SFViewLoadParams
from gui.mods.nidin_server_list import modes as policy
from gui.mods.nidin_server_list import online
from gui.mods.nidin_server_list import settings as preferences
from gui.impl import backport
from helpers import dependency, getClientVersion, isPlayerAccount, time_utils
from predefined_hosts import g_preDefinedHosts
from skeletons.gui.app_loader import GuiGlobalSpaceID, IAppLoader
from skeletons.gui.lobby_context import ILobbyContext

MOD_ID = 'nidin.improved_server_list'
VIEW_ALIAS = MOD_ID + '.hook'
VERSION = policy.client_version(getClientVersion(False))
BUILD_REVISION = None
CACHE_PATH = os.path.join('mods', 'temp', MOD_ID, 'cache.json')
LEGACY_CACHE_PATHS = (
    os.path.join('mods', 'temp', 'nidin.server_mode_icons', 'cache.json'),
    os.path.join('mods', 'configs', 'nidin.server_mode_icons', 'cache.json'))
_views = {}
_requests = {}
_settings = None
_callback = None
_cache = None
_appLoader = None
_lobbyContext = None
_installed = False
_onlineService = None
_onlineCallback = None
_preferences = None


def _log(message):
    print '[%s] %s' % (MOD_ID, message)


def _readClientRevision(path='version.xml'):
    # Include the build number and client/overrides/localization revisions:
    # micro-updates can keep the same four-part public client version.
    try:
        with open(path, 'rb') as source:
            data = source.read(65537)
        if data and len(data) <= 65536:
            return hashlib.sha256(data).hexdigest()
    except (IOError, OSError):
        pass
    return None


def _readCache():
    global _cache
    _cache = None
    # Only absence permits migration from an older location. A damaged or
    # incompatible newer cache must not revive an older schedule.
    if not BUILD_REVISION:
        return
    for path in (CACHE_PATH,) + LEGACY_CACHE_PATHS:
        try:
            with open(path, 'rb') as source:
                candidate = json.loads(source.read(65536))
            if (isinstance(candidate, dict) and candidate.get('buildRevision') == BUILD_REVISION and
                    (candidate.get('schema'), candidate.get('realm'), candidate.get('version')) ==
                    (policy.SCHEMA, AUTH_REALM, VERSION)):
                _cache = candidate
            return
        except (IOError, OSError) as error:
            if error.errno != errno.ENOENT:
                return
        except ValueError:
            return


def _saveCache():
    directory = os.path.dirname(CACHE_PATH)
    temporary = CACHE_PATH + '.tmp'
    try:
        if not os.path.isdir(directory):
            os.makedirs(directory)
        with open(temporary, 'wb') as target:
            target.write(json.dumps(_cache, sort_keys=True, separators=(',', ':')))
        if os.path.isfile(CACHE_PATH):
            os.remove(CACHE_PATH)
        os.rename(temporary, CACHE_PATH)
    except (IOError, OSError) as error:
        _log('cache write failed: %s' % type(error).__name__)


def _payload():
    native_hosts = g_preDefinedHosts.hostsWithRoaming()
    hosts = [(host.peripheryID, (host.url, host.urlToken)) for host in native_hosts]
    values = _preferences.values if _preferences is not None else preferences.DEFAULTS
    payload = policy.make_payload(hosts, time_utils.getCurrentLocalServerTimestamp(), AUTH_REALM, VERSION, _cache,
                                  selected_modes=preferences.selected_modes(values))
    counts = (_onlineService.get_by_periphery() if _onlineService is not None and AUTH_REALM == 'RU'
              and values['enabled'] and values['showOnline'] else {})
    payload['online'] = {}
    for host in native_hosts:
        if host.peripheryID in counts:
            value = backport.getIntegralFormat(counts[host.peripheryID])
            for url in (host.url, host.urlToken):
                if url:
                    payload['online'][url] = value
    return payload


def _refresh():
    payload = _payload()
    for view in list(_views.values()):
        try:
            if view._isDAAPIInited() and getattr(view, '_lastPayload', None) != payload:
                view.flashObject.as_setModes(payload)
                view._lastPayload = payload
        except Exception as error:
            _log('refresh failed: %s' % type(error).__name__)


def _captureSettings(*unused):
    global _cache
    if not isPlayerAccount():
        return
    raw = _lobbyContext.getServerSettings().getSettings()
    now = time_utils.getCurrentLocalServerTimestamp()
    modes = {}
    for mode, key in policy.CONFIG_KEYS.items():
        if key in raw:
            try:
                modes[mode] = policy.snapshot(raw[key], now, mode)
            except (KeyError, TypeError, ValueError) as error:
                _log('%s config unavailable: %s' % (mode, type(error).__name__))
    if modes:
        _cache = {'schema': policy.SCHEMA, 'realm': AUTH_REALM, 'version': VERSION,
                  'buildRevision': BUILD_REVISION, 'modes': modes}
        _saveCache()
    _refresh()


def _onSettingsDiff(diff):
    if any(key in diff for key in policy.CONFIG_KEYS.values()):
        _captureSettings()


def _setSettings(settings):
    global _settings
    if _settings is not settings:
        if _settings is not None:
            _settings.onServerSettingsChange -= _onSettingsDiff
        _settings = settings
        if _settings is not None:
            _settings.onServerSettingsChange += _onSettingsDiff
    _captureSettings()


class _Request(object):
    def __init__(self, key, loader):
        self.key, self.loader = key, loader
        loader.onViewLoadError += self.onError
        loader.onViewLoadCanceled += self.onCanceled

    def close(self):
        if _requests.get(self.key) is self:
            del _requests[self.key]
        if self.loader is not None:
            self.loader.onViewLoadError -= self.onError
            self.loader.onViewLoadCanceled -= self.onCanceled
            self.loader = None

    def onError(self, viewKey, message, item):
        if viewKey.alias == VIEW_ALIAS:
            self.close()
            _log('view load failed: %s' % message)

    def onCanceled(self, viewKey, item):
        if viewKey.alias == VIEW_ALIAS:
            self.close()


class NidinServerModeIconsHook(View):
    def _populate(self):
        super(NidinServerModeIconsHook, self)._populate()
        # Closing listeners does not cancel an already pending native load.
        # Never resurrect a late bridge after uninstall().
        if not _installed:
            self.destroy()
            return
        self._appKey = id(self.app.loaderManager)
        request = _requests.get(self._appKey)
        if request is not None:
            request.close()
        _views[self._appKey] = self
        _refresh()
        _log('1.0.0 loaded; client schedule cache ready')

    def onServerListOpening(self):
        # Called synchronously by the native dropdown's SHOW_DROP_DOWN event,
        # before its new rows render. Re-evaluate prime time on every opening.
        self._listOpeningCount = getattr(self, '_listOpeningCount', 0) + 1
        self._lastListOpeningTime = time_utils.getCurrentLocalServerTimestamp()
        if _onlineService is not None:
            _onlineService.refresh()
        _refresh()

    def onBridgeReady(self):
        window = self.getParentWindow()
        if window is not None:
            if not window.isHidden():
                window.hide()
            if window.layer != WindowLayer.HIDDEN_SERVICE_LAYOUT:
                window.setLayer(WindowLayer.HIDDEN_SERVICE_LAYOUT)

    def _dispose(self):
        key = getattr(self, '_appKey', None)
        if _views.get(key) is self:
            del _views[key]
        super(NidinServerModeIconsHook, self)._dispose()


def _ensureView():
    app = _appLoader.getDefLobbyApp()
    if app is None or app.loaderManager is None:
        return
    key = id(app.loaderManager)
    if key in _views or key in _requests:
        return
    request = _Request(key, app.loaderManager)
    _requests[key] = request
    try:
        app.loadView(SFViewLoadParams(VIEW_ALIAS))
    except Exception as error:
        request.close()
        _log('view request failed: %s' % type(error).__name__)


def _cancelCallback():
    global _callback
    if _callback is not None:
        BigWorld.cancelCallback(_callback)
        _callback = None


def _tick():
    global _callback
    _callback = None
    if _installed and _appLoader.getSpaceID() in (GuiGlobalSpaceID.LOGIN, GuiGlobalSpaceID.LOBBY):
        _setSettings(_lobbyContext.getServerSettings())
        _ensureView()
        _refresh()
        _callback = BigWorld.callback(60.0, _tick)


def _onGUIInitialized():
    if _appLoader.getSpaceID() in (GuiGlobalSpaceID.LOGIN, GuiGlobalSpaceID.LOBBY):
        _ensureView()


def _onSpaceEntered(spaceID):
    global _callback
    _cancelCallback()
    if spaceID in (GuiGlobalSpaceID.LOGIN, GuiGlobalSpaceID.LOBBY):
        if _onlineService is not None:
            _onlineService.refresh()
        _ensureView()
        # Account/controllers finish their synchronous initialization first.
        _callback = BigWorld.callback(0.1, _tick)
    else:
        _setSettings(None)
        for request in list(_requests.values()):
            request.close()


def _onlineTick():
    global _onlineCallback
    _onlineCallback = None
    if not _installed:
        return
    # Expire displayed counts even when a list stays open and the proxy fails.
    # This reads local state only; opening the list triggers network refresh.
    if _appLoader.getSpaceID() in (GuiGlobalSpaceID.LOGIN, GuiGlobalSpaceID.LOBBY):
        _refresh()
    _onlineCallback = BigWorld.callback(5.0, _onlineTick)


def _syncOnlineService():
    global _onlineService
    values = _preferences.values
    wanted = AUTH_REALM == 'RU' and values['enabled'] and values['showOnline']
    if not wanted:
        service, _onlineService = _onlineService, None
        if service is not None:
            service.stop()
    elif _onlineService is None:
        _onlineService = online.OnlineService(online.fetch_url, time.time, _refresh)
        _onlineService.start(online.read_config())


def _onPreferencesChanged():
    if _installed:
        _syncOnlineService()
        _refresh()


def install():
    global _installed, _appLoader, _lobbyContext, _onlineCallback, _preferences, BUILD_REVISION
    if _installed:
        return
    _appLoader = dependency.instance(IAppLoader)
    _lobbyContext = dependency.instance(ILobbyContext)
    if g_entitiesFactories.getSettings(VIEW_ALIAS) is None:
        g_entitiesFactories.addSettings(ViewSettings(
            VIEW_ALIAS, NidinServerModeIconsHook, 'nidinServerModeIcons.swf',
            WindowLayer.OVERLAY, None, ScopeTemplates.GLOBAL_SCOPE, False,
            canDrag=False, canClose=False, isModal=False, isCentered=False))
    BUILD_REVISION = _readClientRevision()
    _readCache()
    _preferences = preferences.Preferences(_onPreferencesChanged)
    try:
        _preferences.install()
    except Exception as error:
        _log('mod settings unavailable: %s' % type(error).__name__)
    _appLoader.onGUIInitialized += _onGUIInitialized
    _appLoader.onGUISpaceEntered += _onSpaceEntered
    _lobbyContext.onServerSettingsChanged += _setSettings
    _installed = True
    _syncOnlineService()
    if AUTH_REALM == 'RU':
        _onlineCallback = BigWorld.callback(5.0, _onlineTick)
    _onSpaceEntered(_appLoader.getSpaceID())
    _log('registered')


def uninstall():
    global _installed, _settings, _onlineService, _onlineCallback
    if not _installed:
        return
    _installed = False
    if _preferences is not None:
        try:
            _preferences.uninstall()
        except Exception as error:
            _log('settings cleanup failed: %s' % type(error).__name__)
    if _onlineCallback is not None:
        BigWorld.cancelCallback(_onlineCallback)
        _onlineCallback = None
    if _onlineService is not None:
        _onlineService.stop()
        _onlineService = None
    _cancelCallback()
    _appLoader.onGUIInitialized -= _onGUIInitialized
    _appLoader.onGUISpaceEntered -= _onSpaceEntered
    _lobbyContext.onServerSettingsChanged -= _setSettings
    if _settings is not None:
        _settings.onServerSettingsChange -= _onSettingsDiff
        _settings = None
    for request in list(_requests.values()):
        request.close()
    for view in list(_views.values()):
        try:
            view.destroy()
        except Exception as error:
            _log('dispose failed: %s' % type(error).__name__)
    _views.clear()


install()
