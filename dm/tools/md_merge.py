#!/usr/bin/env python3
"""Merge driver for Markdown in Cartridge's fork (.gitattributes; docs/launcher.md, Following upstream): where upstream's docs and the fork's change the same place,
keep upstream's text and add the fork's own new lines to it, instead of stopping on a conflict.

    git config merge.mdkeep.driver 'python3 dm/tools/md_merge.py %O %A %B'

A conflicting hunk becomes: the lines the fork added before the first line it kept from the merge base, then upstream's side, then the fork's other added lines.
Base lines the fork rewrote or deleted take upstream's version (the docs' paragraphs are one line each, so a line is a paragraph or a list item). Plain union
merging keeps both sides whole, which leaves a paragraph upstream rewrote twice, old and new. Exit status 0: %A holds the merge (git's driver contract).
"""
import subprocess, sys


def resolve(ours, base, theirs):
    kept = {l for l in base if l.strip()}
    first = next((i for i, l in enumerate(ours) if l in kept), None)
    added = [(i, l) for i, l in enumerate(ours) if l not in kept]
    if first is None:   # the fork's lines only: after upstream's
        pre, post = [], [l for _, l in added]
    else:
        pre, post = [l for i, l in added if i < first], [l for i, l in added if i > first]
    while post and not post[0].strip(): post.pop(0)
    while pre and not pre[-1].strip() and not theirs: pre.pop()
    paragraphs = any(not l.strip() for l in ours + theirs)
    out = []
    for part in (pre, theirs, post):
        if not part: continue
        if out and paragraphs and out[-1].strip() and part[0].strip(): out.append('')
        out += part
    return out


def main():
    o, a, b = sys.argv[1:4]
    r = subprocess.run(['git', 'merge-file', '-p', '--diff3', a, o, b], capture_output=True, text=True)
    if r.returncode < 0 or r.returncode > 127: return 1
    lines, out, i = r.stdout.split('\n'), [], 0
    while i < len(lines):
        if not lines[i].startswith('<<<<<<< '): out.append(lines[i]); i += 1; continue
        ours, base, theirs, cur = [], [], [], None
        i += 1; cur = ours
        while i < len(lines) and not lines[i].startswith('>>>>>>> '):
            if lines[i].startswith('||||||| '): cur = base
            elif lines[i] == '=======': cur = theirs
            else: cur.append(lines[i])
            i += 1
        i += 1
        out += resolve(ours, base, theirs)
    open(a, 'w').write('\n'.join(out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
