# -*- coding: utf-8 -*-
"""Public Stronghold calendar. No account, clan, cookies or access tokens."""
import json
import math
import os
import re
import time

ENDPOINT = 'https://strongholds.tanki.su/game_api/schedule'
COOLDOWN = 86400.0
TTL = 172800.0
TIMEOUT = 10.0
MAX_BODY = 1048576
ICON = '../maps/icons/nidin/server_mode_icons/stronghold.png'
LABEL = u'Укрепрайон: сражения'


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, long, float)):
        raise ValueError('invalid calendar number')
    value = float(value)
    if math.isnan(value) or math.isinf(value):
        raise ValueError('nonfinite calendar number')
    return value


def parse(body, now):
    """Native web calendar: UTC date in milliseconds and UTC hour pairs."""
    if not isinstance(body, basestring) or len(body) > MAX_BODY:
        raise ValueError('invalid calendar body')
    days = json.loads(body)
    if not isinstance(days, list) or len(days) > 32:
        raise ValueError('invalid calendar days')
    result = {}
    for day in days:
        if not isinstance(day, dict):
            raise ValueError('invalid calendar day')
        date = _number(day['date']) / 1000.0
        if date % 86400 or abs(date - now) > 40 * 86400:
            raise ValueError('invalid calendar date')
        items = day['schedule_items']
        if not isinstance(items, list) or len(items) > 64:
            raise ValueError('invalid calendar items')
        for item in items:
            kind = item['type']
            if kind not in ('SORTIE', 'FORT_BATTLE'):
                continue
            raw_level = _number(item['vehicle_level'])
            level = int(raw_level)
            if level != raw_level or not 1 <= level <= 20:
                raise ValueError('invalid vehicle level')
            schedules = item['schedules']
            if not isinstance(schedules, list) or len(schedules) > 64:
                raise ValueError('invalid server schedules')
            for schedule in schedules:
                if not isinstance(schedule, dict):
                    raise ValueError('invalid server schedule')
                if schedule.get('enabled') is not True:
                    continue
                name = schedule.get('periphery')
                match = re.match(r'^RU([1-9][0-9]?)$', name) if isinstance(name, basestring) else None
                if not match:
                    continue
                # RU periphery IDs use 100 + the public server number.
                pid = 100 + int(match.group(1))
                periods = schedule['periods']
                if not isinstance(periods, list) or len(periods) > 48:
                    raise ValueError('invalid calendar periods')
                for pair in periods:
                    if not isinstance(pair, (list, tuple)) or len(pair) != 2:
                        raise ValueError('invalid calendar period')
                    start, end = map(_number, pair)
                    if not (0 <= start < 24 and 0 <= end <= 24):
                        raise ValueError('invalid UTC hours')
                    if start == end:
                        continue
                    lower, upper = date + start * 3600, date + end * 3600
                    if upper < lower:
                        upper += 86400
                    if upper > now:
                        result.setdefault(pid, set()).add((lower, upper, kind, level))
    return dict((pid, sorted(periods)) for pid, periods in result.items())


def tooltip(periods, now):
    """Two upcoming intervals per division, preserving calendar exceptions."""
    groups = {}
    for start, end, kind, level in periods:
        if end > now:
            groups.setdefault((kind, level), []).append((start, end))
    grouped = {}
    for (kind, level), intervals in groups.items():
        merged = []
        for start, end in sorted(intervals):
            if merged and start <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], end)
            else:
                merged.append([start, end])
        key = (kind, tuple(tuple(interval) for interval in merged[:2]))
        grouped.setdefault(key, []).append(level)
    blocks = []
    for (kind, intervals), levels in sorted(grouped.items(), reverse=True):
        title = u'Вылазки' if kind == 'SORTIE' else u'Наступления'
        levels_text = u', '.join(unicode(level) for level in sorted(levels))
        lines = [u'%s, %s ур.:' % (title, levels_text)]
        for start, end in intervals:
            first = time.strftime('%d.%m %H:%M', time.gmtime(start + 10800))
            same_day = int((start + 10800) // 86400) == int((end + 10800) // 86400)
            last = time.strftime('%H:%M' if same_day else '%d.%m %H:%M', time.gmtime(end + 10800))
            lines.append(u'%s — %s (МСК)' % (first, last))
        blocks.append(u'\n'.join(lines))
    return u'\n\n'.join(blocks)


class ScheduleService(object):
    def __init__(self, request, clock, changed, cache_path=None):
        self.request, self.clock, self.changed = request, clock, changed
        self.cache_path = cache_path
        self.running = False
        self.generation = 0
        self.pending = False
        self.deadline = 0
        self.attempt = None
        self.updated = None
        self.periods = {}

    def start(self):
        self.stop()
        self.running = True
        self._read_cache()
        self.refresh()

    def stop(self):
        self.running = False
        self.generation += 1
        self.pending = False
        self.attempt = self.updated = None
        self.periods = {}

    def _read_cache(self):
        if not self.cache_path:
            return
        try:
            with open(self.cache_path, 'rb') as source:
                raw = source.read(MAX_BODY * 2 + 1)
            if len(raw) > MAX_BODY * 2:
                return
            saved = json.loads(raw)
            if saved.get('schema') != 1:
                return
            updated = _number(saved['updated'])
            now = self.clock()
            if not 0 <= now - updated < TTL:
                return
            body = json.dumps(saved['calendar'], separators=(',', ':'))
            periods = parse(body, now)
            self.periods, self.updated = periods, updated
        except (IOError, OSError, AttributeError, KeyError, TypeError, ValueError, OverflowError):
            pass

    def _save_cache(self, body):
        if not self.cache_path:
            return
        temporary = self.cache_path + '.tmp'
        try:
            directory = os.path.dirname(self.cache_path)
            if directory and not os.path.isdir(directory):
                os.makedirs(directory)
            saved = {'schema': 1, 'updated': self.updated, 'calendar': json.loads(body)}
            with open(temporary, 'wb') as target:
                target.write(json.dumps(saved, separators=(',', ':')))
            if os.path.isfile(self.cache_path):
                os.remove(self.cache_path)
            os.rename(temporary, self.cache_path)
        except (IOError, OSError, TypeError, ValueError):
            # Disk errors must not discard a calendar already received in memory.
            pass

    def markers(self, now):
        if not self.running or self.updated is None or not 0 <= now - self.updated < TTL:
            return {}
        result = {}
        for pid, periods in self.periods.items():
            current = [p for p in periods if p[1] > now]
            if not current:
                continue
            active = any(start <= now < end for start, end, kind, level in current)
            result[pid] = {'icon': ICON, 'label': LABEL, 'active': active,
                           'tooltipTitle': LABEL + (u'' if active else u' (недоступен)'),
                           'tooltipBody': tooltip(current, now)}
        return result

    def refresh(self):
        now = self.clock()
        if not self.running:
            return False
        if self.updated is not None and 0 <= now - self.updated < COOLDOWN:
            return False
        if self.pending and now >= self.deadline:
            self.generation += 1
            self.pending = False
        if self.pending or (self.attempt is not None and 0 <= now - self.attempt < COOLDOWN):
            return False
        self.attempt = now
        self.generation += 1
        generation = self.generation
        self.pending = True
        self.deadline = now + TIMEOUT

        def received(status, body):
            if not self.running or generation != self.generation or not self.pending:
                return
            self.pending = False
            current = self.clock()
            if current < now or current >= self.deadline or status != 200:
                return
            try:
                periods = parse(body, current)
            except (KeyError, TypeError, ValueError, OverflowError):
                return
            self.periods, self.updated = periods, current
            self._save_cache(body)
            try:
                self.changed()
            except Exception:
                pass

        try:
            self.request(ENDPOINT, received)
        except Exception:
            self.pending = False
        return True
