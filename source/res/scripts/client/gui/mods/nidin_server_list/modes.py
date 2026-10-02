# -*- coding: utf-8 -*-
"""Engine-independent server mode markers from cached native settings."""
import calendar
import math
import re
import time

SCHEMA = 2
MODE_ORDER = ('white_tiger', 'comp7')
AVAILABLE_MODES = MODE_ORDER + ('frontline', 'battle_royale', 'rift', 'arcade')
# Stable UI/cache IDs; native Frontline settings are named epic_config.
CONFIG_KEYS = {'white_tiger': 'white_tiger_config', 'comp7': 'comp7_config',
               'frontline': 'epic_config', 'battle_royale': 'battle_royale_config',
               'rift': 'portal_config', 'arcade': 'fun_random_config'}
MODE_INFO = {
    'white_tiger': {'label': u'Ваффентрагер', 'icon': '../maps/icons/nidin/server_mode_icons/whiteTiger.png'},
    'comp7': {'label': u'Натиск', 'icon': '../maps/icons/nidin/server_mode_icons/comp7.png'},
    'frontline': {'label': u'Линия фронта', 'icon': '../maps/icons/nidin/server_mode_icons/frontline.png'},
    'battle_royale': {'label': u'Стальной охотник', 'icon': '../maps/icons/nidin/server_mode_icons/battle_royale.png'},
    'rift': {'label': u'Разлом', 'icon': '../maps/icons/nidin/server_mode_icons/rift.png'},
    'arcade': {'label': u'Аркада', 'icon': '../maps/icons/nidin/server_mode_icons/arcade.png'}
}


def moscow_time(year, month, day, hour=0, minute=0):
    return calendar.timegm((year, month, day, hour, minute, 0)) - 3 * 3600


ALL_DAYS = (1, 2, 3, 4, 5, 6, 7)


def client_version(value):
    match = re.search(r'\b(\d+\.\d+\.\d+\.\d+)\b', value or '')
    return match.group(1) if match else ''


def _ids(values):
    result = set()
    for value in values:
        try:
            number = int(value)
            if number > 0:
                result.add(number)
        except (ValueError, TypeError):
            pass
    return result


def _clock_minute(clock, extended_end=False):
    hour, minute = clock
    hour, minute = int(hour), int(minute)
    maximum = 47 if extended_end else 24
    if (not 0 <= hour <= maximum or not 0 <= minute < 60 or
            (not extended_end and hour == 24 and minute)):
        raise ValueError('invalid UTC clock')
    return hour * 60 + minute


def _period_ids(periods, now):
    """An overnight period belongs to the weekday on which it starts."""
    weekday = time.gmtime(now).tm_wday + 1
    previous_weekday = (weekday - 2) % 7 + 1
    minute = (now % 86400) / 60.0
    result = set()
    for start, end, weekdays, ids in periods:
        if start < end:
            active = weekday in weekdays and start <= minute < end
        elif start > end:
            active = ((weekday in weekdays and minute >= start) or
                      (previous_weekday in weekdays and minute < end))
        else:
            active = False
        if active:
            result.update(ids)
    return result


def snapshot(config, now, mode=None):
    """Persist only playable windows and UTC schedules, without account data."""
    if not isinstance(config, dict):
        raise ValueError('mode config must be a dict')
    if mode == 'arcade':
        return _snapshot_arcade(config, now)
    if mode == 'rift':
        realm = config.get('realmConfig', {})
        if not isinstance(realm, dict):
            raise ValueError('Portal realm config must be a dict')
        config = dict(config, peripheryIDs=realm.get('peripheryIDs', ()),
                      primeTimes=realm.get('primeTimes', {}))
    if not config.get('isEnabled', False):
        return {'captured': now, 'windows': [], 'periods': []}
    allowed = _ids(config.get('peripheryIDs', ()))
    scheduled = set()
    periods = []
    for period in config.get('primeTimes', {}).values():
        start, end = _clock_minute(period['start']), _clock_minute(period['end'], True)
        weekdays = sorted(day for day in _ids(period.get('weekdays', ())) if day <= 7)
        ids = sorted(allowed.intersection(_ids(period.get('peripheryIDs', ()))))
        bounds = [(start, end, weekdays)]
        if end > 1440:
            # Native PrimeTime computes an extended end literally from the
            # UTC day start. Split it into ordinary cached day intervals,
            # preserving the weekday to which its midnight continuation belongs.
            next_days = sorted(day % 7 + 1 for day in weekdays)
            bounds = [(start, 1440, weekdays), (0, end - 1440, next_days)]
        for lower, upper, days in bounds:
            if days and lower != upper and ids:
                scheduled.update(ids)
                periods.append({'startMinute': lower, 'endMinute': upper,
                                'weekdays': days, 'peripheryIDs': ids})
    allowed.intersection_update(scheduled)
    windows = []
    for season in config.get('seasons', {}).values():
        start, end = int(season['startSeason']), int(season['endSeason'])
        # Cycles delimit playable portions of a season; off-season gaps get no icon.
        cycles = season.get('cycles', {})
        bounds = [(int(c['start']), int(c['end'])) for c in cycles.values()]
        if not bounds:
            bounds = [(start, end)]
        for cycle_start, cycle_end in bounds:
            lower, upper = max(start, cycle_start), min(end, cycle_end)
            if lower < upper and upper > now and allowed:
                windows.append([lower, upper, sorted(allowed)])
    record = {'captured': now, 'windows': windows, 'periods': periods}
    if mode == 'rift':
        # Portal keeps an available season while battles are temporarily off.
        record['battleEnabled'] = config.get('isBattleEnabled', False) is True
    return record


def _snapshot_arcade(config, now):
    """Keep each enabled native submode's season and clocks correlated."""
    # FEPType 1 is Field Trials, not Arcade; the native default for Arcade is 0.
    if not config.get('isEnabled', False) or config.get('FEPType', 0) != 0:
        return {'captured': now, 'windows': [], 'periods': []}
    events = config.get('events', {})
    if not isinstance(events, dict):
        raise ValueError('Arcade events must be a dict')
    components = []
    for event in events.values():
        if not isinstance(event, dict):
            raise ValueError('Arcade event must be a dict')
        if event.get('isEnabled', False) and event.get('eventID', 0):
            # The raw event is flat. Native FunSubModeConfig constructs its
            # seasonality namedtuple from these same top-level fields.
            components.append(snapshot(event, now))
    return {'captured': now, 'components': components}


def _cached_state(record, now):
    """Return (seasonal servers, playable servers), or None for invalid data."""
    try:
        captured = float(record['captured'])
        if math.isnan(captured) or math.isinf(captured) or not 0 <= now - captured:
            return None
        if 'components' in record:
            components = record['components']
            if not isinstance(components, (list, tuple)):
                return None
            configured, playable = set(), set()
            for component in components:
                # Only the adapter's single aggregation level is supported.
                if not isinstance(component, dict) or 'components' in component:
                    return None
                state = _cached_state(component, now)
                if state is None:
                    return None
                configured.update(state[0])
                playable.update(state[1])
            return configured, playable
        windows = record['windows']
        if not isinstance(windows, (list, tuple)):
            return None
        # A disabled mode is authoritative, including a record without periods.
        if not windows:
            return set(), set()
        periods = []
        scheduled = set()
        for period in record['periods']:
            start, end = int(period['startMinute']), int(period['endMinute'])
            weekdays = _ids(period['weekdays'])
            ids = _ids(period['peripheryIDs'])
            if (not 0 <= start <= 1440 or not 0 <= end <= 1440 or start == end or
                    not weekdays or not weekdays.issubset(set(ALL_DAYS)) or not ids):
                return None
            periods.append((start, end, weekdays, ids))
            scheduled.update(ids)
        if not periods:
            return None
        configured = set()
        for start, end, ids in windows:
            start, end = float(start), float(end)
            if (math.isnan(start) or math.isinf(start) or math.isnan(end) or math.isinf(end) or start >= end):
                return None
            # Tooltip dates must also be representable by the runtime clock.
            time.gmtime(start + 10800)
            time.gmtime(end + 10800)
            if start <= now < end:
                configured.update(_ids(ids))
        configured.intersection_update(scheduled)
        battle_enabled = record.get('battleEnabled', True)
        if not isinstance(battle_enabled, bool):
            return None
        playable = configured.intersection(_period_ids(periods, now)) if battle_enabled else set()
        return configured, playable
    except (KeyError, ValueError, TypeError, OverflowError):
        return None


def _cached_ids(record, now):
    """None means invalid; an empty set is an authoritative closed mode."""
    state = _cached_state(record, now)
    return state[1] if state is not None else None


def _mode_records(now, realm, version, cache=None):
    """Use valid native cache records; absent or invalid records stay absent."""
    result = {}
    cache_modes = {}
    if isinstance(cache, dict) and (cache.get('schema'), cache.get('realm'), cache.get('version')) == (SCHEMA, realm, version):
        cache_modes = cache.get('modes', {})
        if not isinstance(cache_modes, dict):
            cache_modes = {}
    for mode in AVAILABLE_MODES:
        record = cache_modes.get(mode, {})
        if _cached_state(record, now) is not None:
            result[mode] = record
    return result


def _mode_states(now, realm, version, cache=None):
    records = _mode_records(now, realm, version, cache)
    return dict((mode, _cached_state(records.get(mode, {}), now) or (set(), set()))
                for mode in AVAILABLE_MODES)


def mode_servers(now, realm, version, cache=None):
    """Servers where the mode is playable at the specified instant."""
    return dict((mode, state[1]) for mode, state in _mode_states(now, realm, version, cache).items())


def mode_season_servers(now, realm, version, cache=None):
    """Servers hosting the current season/cycle, including closed prime time."""
    return dict((mode, state[0]) for mode, state in _mode_states(now, realm, version, cache).items())


def normalize_selected_modes(values=None):
    """Distinct supported IDs, preserving the requested order without a limit."""
    if values is None:
        return MODE_ORDER
    if not isinstance(values, (list, tuple)):
        return ()
    selected = []
    for mode in values:
        if isinstance(mode, basestring) and mode in MODE_INFO and mode not in selected:
            selected.append(mode)
    return tuple(selected)


_WEEKDAYS = (u'Пн', u'Вт', u'Ср', u'Чт', u'Пт', u'Сб', u'Вс')


def _clock_text(minute):
    return u'%02d:%02d' % (minute // 60, minute % 60)


def _periods_text(periods):
    """Merge this window's display intervals on a cyclic Moscow-time week."""
    week = 7 * 1440
    intervals = []
    for period in periods:
        start, end = int(period['startMinute']), int(period['endMinute'])
        duration = end - start + (1440 if end < start else 0)
        if duration <= 0:
            continue
        for day in _ids(period['weekdays']):
            lower = ((day - 1) * 1440 + start + 180) % week
            upper = lower + duration
            intervals.append((lower, min(upper, week)))
            if upper > week:
                intervals.append((0, upper - week))
    merged = []
    for lower, upper in sorted(intervals):
        if merged and lower <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], upper)
        else:
            merged.append([lower, upper])
    if merged == [[0, week]]:
        return [u'Расписание: круглосуточно']
    if len(merged) > 1 and merged[0][0] == 0 and merged[-1][1] == week:
        # Sunday night and Monday morning are the same continuous interval.
        merged[-1][1] += merged.pop(0)[1]
    groups, long_intervals, full_days = {}, [], set()
    for lower, upper in merged:
        if upper - lower >= 1440:
            if lower % 1440 == 0 and upper % 1440 == 0:
                full_days.update(day % 7 for day in range(lower // 1440, upper // 1440))
                continue
            text = u'%s %s — %s %s' % (_WEEKDAYS[lower // 1440], _clock_text(lower % 1440),
                                       _WEEKDAYS[(upper // 1440) % 7], _clock_text(upper % 1440))
            if upper // 1440 - lower // 1440 == 7:
                text += u' (следующая неделя)'
            long_intervals.append(text + u' (МСК)')
        else:
            key = (lower % 1440, upper % 1440, upper // 1440 - lower // 1440)
            groups.setdefault(key, set()).add(lower // 1440)
    result = []
    for (start, end, overnight), days in sorted(groups.items()):
        text = u'%s — %s (МСК)' % (_clock_text(start), _clock_text(end))
        if len(days) < 7:
            text = u'%s — %s' % (u', '.join(_WEEKDAYS[day] for day in sorted(days)), text)
        result.append(text)
    if full_days:
        result.append(u'%s — круглосуточно' % u', '.join(_WEEKDAYS[day] for day in sorted(full_days)))
    result.extend(long_intervals)
    if result:
        result[0] = u'Расписание: ' + result[0]
    return result


def _current_schedules(record, periphery_id, now):
    """Return only this server's current cycle windows and matching clocks."""
    result = []
    if 'components' in record:
        for component in record['components']:
            result.extend(_current_schedules(component, periphery_id, now))
        return result
    if not record.get('windows'):
        return result
    periods = [period for period in record['periods'] if periphery_id in _ids(period['peripheryIDs'])]
    for start, end, ids in record['windows']:
        if float(start) <= now < float(end) and periphery_id in _ids(ids):
            result.append((start, end, periods))
    return result


def _remaining_text(end, now):
    seconds = max(0, float(end) - now)
    if seconds >= 86400:
        count, forms = int(seconds // 86400), (u'день', u'дня', u'дней')
    elif seconds >= 3600:
        count, forms = int(seconds // 3600), (u'час', u'часа', u'часов')
    else:
        return u'Осталось: менее часа'
    ending = 2 if 11 <= count % 100 <= 14 else 0 if count % 10 == 1 else 1 if 2 <= count % 10 <= 4 else 2
    return u'Осталось: %d %s' % (count, forms[ending])


def _tooltip_body(record, periphery_id, now):
    blocks = []
    schedules = _current_schedules(record, periphery_id, now)
    for index, (start, end, periods) in enumerate(schedules):
        date_start = time.strftime('%d.%m.%Y %H:%M', time.gmtime(float(start) + 10800))
        date_end = time.strftime('%d.%m.%Y %H:%M', time.gmtime(float(end) + 10800))
        lines = []
        if len(schedules) > 1:
            lines.append(u'Расписание %d' % (index + 1))
        lines.append(u'Начало:\t%s (МСК)' % date_start)
        lines.append(u'Конец:\t%s (МСК)' % date_end)
        lines.append(_remaining_text(end, now))
        lines.extend(_periods_text(periods))
        blocks.append(u'\n'.join(lines))
    return u'\n\n'.join(blocks)


def make_payload(hosts, now, realm, version, cache=None, selected_modes=None):
    records = _mode_records(now, realm, version, cache)
    by_mode = dict((mode, _cached_state(record, now)) for mode, record in records.items())
    selected = normalize_selected_modes(selected_modes)
    servers = {}
    column_count = 0
    for periphery_id, urls in hosts:
        markers = []
        for mode in selected:
            configured, playable = by_mode.get(mode, (set(), set()))
            if periphery_id in configured:
                marker = dict(MODE_INFO[mode])
                marker['active'] = periphery_id in playable
                marker['tooltipTitle'] = marker['label'] + (u'' if marker['active'] else u' (недоступен)')
                marker['tooltipBody'] = _tooltip_body(records[mode], periphery_id, now)
                markers.append(marker)
        if markers:
            for url in urls:
                if url:
                    servers[url] = markers
                    column_count = max(column_count, len(markers))
    return {'servers': servers, 'columnCount': column_count}
