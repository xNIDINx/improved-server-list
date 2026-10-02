# -*- coding: utf-8 -*-
"""Persistent ModsSettingsAPI choices; no game imports until installation."""
LINKAGE = 'nidin.improved_server_list'
LEGACY_LINKAGE = 'nidin.server_mode_icons'
MODE_CHOICES = (None, 'white_tiger', 'comp7', 'frontline', 'battle_royale', 'rift', 'arcade')
MODES = MODE_CHOICES[1:]
DEFAULTS = dict((mode, mode in ('white_tiger', 'comp7')) for mode in MODES)
DEFAULTS.update(enabled=True, showOnline=True)


def normalized(values):
    values = values if isinstance(values, dict) else {}
    result = dict(DEFAULTS)
    for key in ('enabled', 'showOnline'):
        if isinstance(values.get(key), bool):
            result[key] = values[key]
    if not any(mode in values for mode in MODES) and any(key in values for key in ('firstMode', 'secondMode')):
        # Convert the pre-v5 dropdowns before ModsSettingsAPI replaces them
        # with checkbox defaults. Empty and duplicate selections stay empty/unique.
        selected = set()
        for key, default in (('firstMode', 1), ('secondMode', 2)):
            value = values.get(key, default)
            if not isinstance(value, (int, long)) or isinstance(value, bool) or not 0 <= value < len(MODE_CHOICES):
                value = default
            if value:
                selected.add(MODE_CHOICES[value])
        result.update((mode, mode in selected) for mode in MODES)
    else:
        for mode in MODES:
            if isinstance(values.get(mode), bool):
                result[mode] = values[mode]
    return result


def selected_modes(values):
    values = normalized(values)
    if not values['enabled']:
        return ()
    return tuple(mode for mode in MODES if values[mode])


def make_template(templates):
    modes = (
        ('white_tiger', 'whiteTiger', u'Ваффентрагер'),
        ('comp7', 'comp7', u'Натиск'),
        ('frontline', 'frontline', u'Линия фронта'),
        ('battle_royale', 'battle_royale', u'Стальной охотник'),
        ('rift', 'rift', u'Разлом'),
        ('arcade', 'arcade', u'Аркада'))
    explanation = (u'Показывать значок режима в раскрытом списке серверов. Вне игровых часов он затемнён, вне сезона скрыт.\n\n'
                   u'При первом входе после установки мода значок не отображается.\n\n'
                   u'Данные о режиме на сервере появляются после первого входа в ангар и используются на экране входа '
                   u'до обновления игры, включая микропатчи. После обновления нужно снова войти в ангар.')
    controls = []
    for mode, icon, name in modes:
        tip = u'{BODY}%s{/BODY}' % explanation
        label = (u'<img src="img://gui/maps/icons/nidin/server_mode_icons/%s_settings.png" '
                 u'width="16" height="16" vspace="-16" hspace="0"/> %s') % (icon, name)
        controls.append(templates.createCheckbox(label, mode, DEFAULTS[mode], tooltip=tip))
    online_tip = u'{BODY}Обновляется раз в 30 секунд{/BODY}'
    return {
        'modDisplayName': u'Улучшенный список серверов',
        'settingsVersion': 9, 'enabled': True,
        'column1': controls[:3] + [templates.createCheckbox(u'Показывать онлайн серверов', 'showOnline', True,
                                                           tooltip=online_tip)],
        'column2': controls[3:]
    }


class Preferences(object):
    def __init__(self, on_change):
        self.values = dict(DEFAULTS)
        self.on_change = on_change
        self.api = None
        self.active = False

    def install(self, api=None, templates=None):
        if self.active:
            return
        if api is None:
            from gui.modsSettingsApi import g_modsSettingsApi as api, templates
        template = make_template(templates)
        stored = api.state.get('settings', {})
        # Keep the user's choices before the API replaces an outdated template.
        # Only import the previous mod ID when the new ID has no saved entry.
        previous = stored.get(LINKAGE) if LINKAGE in stored else stored.get(LEGACY_LINKAGE)
        previous = dict(previous) if isinstance(previous, dict) else None
        self.api = api
        saved = api.getModSettings(LINKAGE, template)
        if saved is None:
            saved = api.setModTemplate(LINKAGE, template, self.changed)
        else:
            api.registerCallback(LINKAGE, self.changed)
        if saved is None:
            raise RuntimeError('ModsSettingsAPI rejected server settings')
        self.values = normalized(previous if previous is not None else saved)
        self.active = True
        self._save_normalized(saved)

    def _save_normalized(self, original):
        if self.api is not None and original != self.values:
            self.api.updateModSettings(LINKAGE, dict(self.values))
            self.api.saveState()

    def changed(self, linkage, values):
        if not self.active or linkage != LINKAGE:
            return
        updated = normalized(values)
        changed = updated != self.values
        self.values = updated
        # Set our values before the synchronous API callback to avoid recursion.
        self._save_normalized(values)
        if changed:
            self.on_change()

    def uninstall(self):
        self.active = False
        if self.api is not None:
            try:
                self.api.onSettingsChanged -= self.changed
            finally:
                self.api.activeMods.discard(LINKAGE)
                self.api = None
