#!/usr/bin/env python3
"""Проверка локализации (CI): каждый ключ L("…") из Swift и C# есть в en.lproj, без дублей, %@ совпадает.
Ключи — русские строки (язык разработки). Запуск: python3 -I scripts/check-l10n.py [корень репозитория]."""
import os, re, sys, collections

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..'))
EN = os.path.join(ROOT, 'resources/localization/en.lproj/Localizable.strings')
SOURCES = [('apps/swift/Sources', '.swift'), ('apps/dotnet', '.cs')]
# L("…") и Strings.L("…"); в Swift и C# одинаковые обычные строки с \-экранированием.
CALL = re.compile(r'(?<![\w.])(?:Strings\.)?L\(\s*"((?:[^"\\\n]|\\.)*)"')
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')


def unescape(s):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)


def code_keys():
    keys = collections.defaultdict(list)
    for sub, ext in SOURCES:
        for base, dirs, files in os.walk(os.path.join(ROOT, sub)):
            dirs[:] = [d for d in dirs if d not in ('bin', 'obj', '.build', 'RelayaRust', 'Core')]
            for f in files:
                if not f.endswith(ext):
                    continue
                path = os.path.join(base, f)
                text = open(path, encoding='utf-8').read()
                for m in CALL.finditer(text):
                    raw = m.group(1)
                    if '\\(' in raw or '{' in raw and ext == '.cs' and '$"' in text[max(0, m.start() - 3):m.start() + 3]:
                        continue  # интерполяция — не ключ
                    line = text.count('\n', 0, m.start()) + 1
                    keys[unescape(raw)].append(f'{os.path.relpath(path, ROOT)}:{line}')
    return keys


def en_entries():
    entries, problems = collections.defaultdict(list), []
    for n, line in enumerate(open(EN, encoding='utf-8'), 1):
        line = line.rstrip('\n')
        if not line.strip() or line.lstrip().startswith(('/*', '//', '*')):
            continue
        m = ENTRY.match(line)
        if not m:
            problems.append(f'en.lproj:{n}: строка не разобрана')
            continue
        entries[unescape(m.group(1))].append((n, unescape(m.group(2))))
    return entries, problems


def main():
    keys = code_keys()
    entries, problems = en_entries()
    for k, places in sorted(keys.items()):
        if not re.search('[а-яА-ЯёЁ]', k):
            continue  # латиница (имена, команды) переводить не нужно
        if k not in entries:
            problems.append(f'нет перевода: «{k}» ({places[0]})')
    for k, rows in entries.items():
        if len(rows) > 1:
            problems.append(f'дубль в en.lproj: «{k}» (строки {", ".join(str(r[0]) for r in rows)})')
        for n, v in rows:
            if k.count('%@') != v.count('%@'):
                problems.append(f'en.lproj:{n}: число %@ не совпадает в «{k}»')
    for p in problems:
        print(p)
    print(f'ключей в коде: {len(keys)}, записей en.lproj: {len(entries)}, проблем: {len(problems)}')
    sys.exit(1 if problems else 0)


main()
