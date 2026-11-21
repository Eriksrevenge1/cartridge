#!/usr/bin/env bash
# The checks follow-upstream.yml runs on a merge of upstream nxnative into Cartridge's fork, before it is pushed and published (and that Claude, fixing a merge,
# runs until they pass): the tool, settings, docs and chain tests, the Markdown merge driver, the host's build, and the CPU-only display-link and pacing tests
# (GitHub's Macs have no Metal 4: the GPU tests stay local). GAME: any profile (the tests are about code); 010015100B514000 by default
set -euo pipefail
cd "$(dirname "$0")/.."
GAME=${GAME:-010015100B514000}
for t in test_docs test_settings test_launcher_settings test_nsp_chain test_md_merge; do echo "== $t"; python3 dm/tools/tests/$t.py; done
echo "== host build"; make -C dm/host GAME="$GAME" -j3 > /dev/null
tests="t_link_ticks t_link_latch t_link_drain t_present_rescue t_pace t_fstep"   # the display link and pacing, where Cartridge's host changes are
make -C dm/gfx/tests GAME="$GAME" -j3 $tests > /dev/null
for t in $tests; do echo "== $t"; (cd dm/gfx/tests && ./$t | tail -1); done
echo "follow-upstream tests: all passed"
