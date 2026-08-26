import io, json, glob, sys, collections, os
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

BS = chr(92)

GLYPHS = {
 'privacy': chr(0xE72E), 'ads': chr(0xE789), 'ai': chr(0xE99A), 'apps': chr(0xE71D),
 'explorer': chr(0xE8B7), 'services': chr(0xE713), 'tasks': chr(0xE917),
 'update': chr(0xE72C), 'perf': chr(0xE7FC), 'security': chr(0xEA18),
 'network': chr(0xE774), 'features': chr(0xEA86), 'onedrive': chr(0xE753),
 'advanced': chr(0xE90F), 'edge': chr(0xE774),
}
PGLYPH = {
 'builtin.privacy-essentials': chr(0xE72E), 'builtin.recommended': chr(0xE73E),
 'builtin.win10feel': chr(0xE7F4), 'builtin.quiet': chr(0xE74F),
 'builtin.gaming': chr(0xE7FC), 'builtin.laptop': chr(0xE83F),
 'builtin.security': chr(0xEA18), 'builtin.developer': chr(0xE943),
 'builtin.shared': chr(0xE716), 'builtin.maximum': chr(0xE7BA),
 'builtin.revert-all': chr(0xE777),
 # Technician: builds for machines that are not yours.
 'builtin.corporate': chr(0xE821), 'builtin.kiosk': chr(0xE977),
 'builtin.handoff': chr(0xE8AB),
}

errors, warns = [], []
ids, catkeys = {}, {}
regmap = collections.defaultdict(list)
total = 0

for f in sorted(glob.glob('data/catalog/*.json')):
    doc = json.load(io.open(f, encoding='utf-8'))
    cat = doc['category']
    key = cat['key']
    if key in catkeys:
        errors.append('%s: duplicate category key %s' % (f, key))
    catkeys[key] = f
    if key in GLYPHS:
        cat['glyph'] = GLYPHS[key]
    else:
        warns.append('%s: no glyph mapping for category %s' % (f, key))

    for t in doc['tweaks']:
        total += 1
        tid = t['id']
        if tid in ids:
            errors.append('%s: duplicate tweak id %s (also in %s)' % (f, tid, ids[tid]))
        ids[tid] = f
        for fld in ('name', 'impact', 'explain', 'enableMeans', 'disableMeans', 'risk', 'actions'):
            if not t.get(fld):
                errors.append('%s: missing %s' % (tid, fld))
        if t.get('risk') not in ('safe', 'moderate', 'aggressive'):
            errors.append('%s: bad risk %s' % (tid, t.get('risk')))
        for i, a in enumerate(t.get('actions', [])):
            k = a.get('kind')
            tag = '%s[%d]' % (tid, i)
            if k not in ('reg', 'service', 'appx', 'task', 'feature', 'capability', 'command'):
                errors.append('%s: bad kind %s' % (tag, k))
                continue
            if k == 'reg':
                for fld in ('hive', 'path', 'name', 'type'):
                    if fld not in a:
                        errors.append('%s: reg missing %s' % (tag, fld))
                if a.get('hive') not in ('HKLM', 'HKCU', 'HKCR', 'HKU'):
                    errors.append('%s: bad hive %s' % (tag, a.get('hive')))
                if a.get('type') not in ('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary'):
                    errors.append('%s: bad type %s' % (tag, a.get('type')))
                if 'enable' not in a or 'disable' not in a:
                    errors.append('%s: reg needs both enable and disable' % tag)
                elif str(a['enable']) == str(a['disable']):
                    errors.append('%s: enable == disable (%s), state can never read Enabled'
                                  % (tag, a['enable']))
                regmap[(a.get('hive'), str(a.get('path')).lower(), str(a.get('name')).lower())].append(tid)
            elif k == 'service':
                if not a.get('name'):
                    errors.append('%s: service needs name' % tag)
                if a.get('enable') == a.get('disable'):
                    errors.append('%s: service enable == disable' % tag)
            elif k == 'appx':
                if not a.get('packages'):
                    errors.append('%s: appx needs packages' % tag)
            elif k == 'task':
                if not a.get('tasks'):
                    errors.append('%s: task needs tasks' % tag)
                for p in a.get('tasks', []):
                    if not p.startswith(BS):
                        errors.append('%s: task path must start with a backslash: %s' % (tag, p))
            elif k in ('feature', 'capability'):
                if not a.get('name'):
                    errors.append('%s: %s needs name' % (tag, k))
            elif k == 'command':
                if not a.get('probe'):
                    warns.append('%s: command has no probe, state reads Unknown' % tag)
                if not a.get('enable') and not a.get('disable'):
                    errors.append('%s: command needs enable or disable' % tag)

    io.open(f, 'w', encoding='utf-8', newline='\n').write(
        json.dumps(doc, ensure_ascii=False, indent=2) + '\n')

for k, v in regmap.items():
    if len(set(v)) > 1:
        warns.append('shared registry value %s%s%s -> %s used by: %s'
                     % (k[0], BS, k[1], k[2], ', '.join(sorted(set(v)))))

pdoc = json.load(io.open('data/presets.json', encoding='utf-8'))
for p in pdoc['presets']:
    if p['id'] in PGLYPH:
        p['glyph'] = PGLYPH[p['id']]
    else:
        warns.append('preset %s: no glyph mapping' % p['id'])
    for fld in ('name', 'summary', 'detail', 'risk'):
        if not p.get(fld):
            errors.append('preset %s: missing %s' % (p['id'], fld))
    for r in p.get('rules', []):
        if r.get('action') not in ('Enable', 'Disable', 'Revert'):
            errors.append('preset %s: bad action %s' % (p['id'], r.get('action')))
        for lst in ('ids', 'excludeIds'):
            for i in r.get(lst, []):
                if i not in ids:
                    errors.append('preset %s: unknown id in %s: %s' % (p['id'], lst, i))
        for c in r.get('categories', []) + r.get('excludeCategories', []):
            if c not in catkeys:
                errors.append('preset %s: unknown category %s' % (p['id'], c))

io.open('data/presets.json', 'w', encoding='utf-8', newline='\n').write(
    json.dumps(pdoc, ensure_ascii=False, indent=2) + '\n')

print('%d tweaks in %d categories, %d presets' % (total, len(catkeys), len(pdoc['presets'])))
print('--- %d errors' % len(errors))
for e in errors:
    print('  ERROR', e)
print('--- %d warnings' % len(warns))
for w in warns:
    print('  warn ', w)
sys.exit(1 if errors else 0)
