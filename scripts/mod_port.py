#!/usr/bin/env python3
"""Port a game mod made for a Switch game to its Switch 2 Edition (or any game whose add-on content carries newer copies of the program's files).

A Switch 2 Edition such as Xenoblade Chronicles: Definitive Edition's keeps the Switch game's RomFS and adds an upgrade add-on whose own copies of the same paths
(bdat/, menu/image/, monolib/shader/) the game reads instead. A Switch mod's romfs/ files lie over the program's copies only (dm/mac/launcher.c DM_ROMFS_OVERLAY), so a
mod that replaces such a file does nothing there (Remove PRESS ANY BUTTON), or puts old data beside the edition's new data. This script writes, for each file of the mod
that the add-on carries in a newer version, the mod's change carried onto the add-on's copy, into the mod's aoc/<index>/ folder, which the host lays over that add-on
(DM_AOC_OVERLAY_<index>):
  - .bdat tables: scripts/bdat_port.py's three-way merge (the program's copy as the original the mod was made from, the add-on's as the target);
  - key=value text (.ini, .txt): the keys whose value the mod changed, set in the add-on's copy;
  - anything else (images, layouts, models) cannot be ported: listed, and left to lie over the program's copy as before.
Files it wrote are listed in <mod>/.ported.json, so a run again replaces its own and never a file the mod brought itself. The result is written to <mod>/PORT.txt and
printed as JSON (one line: ported, skipped, unportable).

Usage: mod_port.py <the game's .app> <mod folder>     (exit 1 on an error; a mod with nothing to port exits 0)
"""
import json, os, re, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'dm' / 'tools'))
import romfs as rfs


def images(app):
    res = app / 'Contents/Resources'
    base = [p for p in [res / 'romfs.img', *sorted((res / 'romfs_programs').glob('*.img'))] if p.is_file() and rfs.is_image(p)]
    aoc = {}
    for p in sorted((res / 'aoc').glob('*.img')) if (res / 'aoc').is_dir() else []:
        if p.stem.isdigit() and rfs.is_image(p): aoc[int(p.stem)] = p
    return base, aoc


def read(img, rel):
    g = f'{img}/{rel}'
    if not rfs.isfile(g): return None
    with rfs.open(g, 'rb') as h: return h.read()


KV = re.compile(rb'^\s*([^=#;\[\s][^=]*?)\s*=\s*(.*?)\s*$')


def kv(data):
    out = {}
    for line in data.splitlines():
        m = KV.match(line)
        if m: out[m.group(1)] = m.group(2)
    return out


def port_text(orig, mod, target):
    """The add-on's text with the keys the mod changed set to the mod's values; None when the mod changed something other than values (lines added or removed)"""
    o, m = kv(orig), kv(mod)
    if set(o) != set(m): return None, 0
    changed = {k: v for k, v in m.items() if o.get(k) != v}
    lines, n = [], 0
    for line in target.splitlines(keepends=True):
        mm = KV.match(line.rstrip(b'\r\n'))
        if mm and mm.group(1) in changed:
            eol = line[len(line.rstrip(b'\r\n')):]
            line = line[:mm.start(2)] + changed[mm.group(1)] + line.rstrip(b'\r\n')[mm.end(2):] + eol; n += 1
        lines.append(line)
    return b''.join(lines), n


def main():
    if len(sys.argv) != 3: sys.exit(__doc__.split('\n\n')[-1].strip())
    app, mod = Path(sys.argv[1]), Path(sys.argv[2])
    if not app.is_dir() or not mod.is_dir(): sys.exit(f'mod_port: no such app or mod folder: {app}, {mod}')
    base, aoc = images(app)
    record = mod / '.ported.json'
    ours = set(json.loads(record.read_text())) if record.is_file() else set()
    for rel in ours:   # this script's earlier output goes first: a run again starts from the mod as it came
        p = mod / rel
        if p.is_file(): p.unlink()
    romfs = mod / 'romfs' if (mod / 'romfs').is_dir() else None
    ported, skipped, unportable, written = [], [], [], []
    if romfs and base and aoc:
        for f in sorted(romfs.rglob('*')):
            if not f.is_file(): continue
            rel = f.relative_to(romfs).as_posix()
            orig = next((d for d in (read(b, rel) for b in base) if d is not None), None)
            if orig is None: continue
            mine = f.read_bytes()
            for i, img in aoc.items():
                target = read(img, rel)
                if target is None or target == orig: continue   # the add-on does not carry this file, or carries the same one: the program's copy is the one read
                out = mod / 'aoc' / str(i) / rel
                if out.exists(): skipped.append(f'{rel}: the mod has its own aoc/{i} copy'); continue
                if f.suffix.lower() == '.bdat':
                    out.parent.mkdir(parents=True, exist_ok=True)
                    with tempfile.TemporaryDirectory() as t:
                        for name, data in (('orig', orig), ('target', target)): Path(t, name).write_bytes(data)
                        r = subprocess.run([sys.executable, str(HERE / 'bdat_port.py'), '--original', f'{t}/orig', '--mod', str(f), '--target', f'{t}/target', '-o', str(out)],
                                           capture_output=True, text=True)
                    if r.returncode or not out.is_file(): unportable.append(f'{rel}: {(r.stderr or r.stdout).strip().splitlines()[-1:] or "port failed"}'); continue
                    m = re.search(r'written: (\d+)', r.stdout)
                    ported.append(f'{rel} → aoc/{i}: {m.group(1) if m else "?"} fields')
                elif f.suffix.lower() in ('.ini', '.txt', '.cfg'):
                    data, n = port_text(orig, mine, target)
                    if data is None: unportable.append(f'{rel}: the mod adds or removes lines'); continue
                    out.parent.mkdir(parents=True, exist_ok=True); out.write_bytes(data); ported.append(f'{rel} → aoc/{i}: {n} values')
                else:
                    unportable.append(rel); continue
                written.append(out.relative_to(mod).as_posix())
    if written: record.write_text(json.dumps(sorted(written)))
    elif record.exists(): record.unlink()
    report = ['Ported to this game\'s add-on content by scripts/mod_port.py (the mod was made for files the add-on replaces):'] + [f'  {p}' for p in ported]
    if unportable: report += [f'Not portable ({len(unportable)}; made for the Switch version, the add-on carries newer ones):'] + [f'  {u}' for u in unportable[:40]]
    if skipped: report += ['Skipped:'] + [f'  {s}' for s in skipped]
    if ported or unportable or skipped: (mod / 'PORT.txt').write_text('\n'.join(report) + '\n')
    elif (mod / 'PORT.txt').exists(): (mod / 'PORT.txt').unlink()
    print(json.dumps({'ported': len(ported), 'unportable': len(unportable), 'skipped': len(skipped)}))


if __name__ == '__main__':
    main()
