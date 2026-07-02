#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: Run a group of ublk kernel selftests (make run_all / run_<group>)
# vmtest-requires: root kernel-selftests
# Usage: ./vmtest run ublk_test_grp <group-name>   (e.g. run_all, run_batch)
set -euo pipefail

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root

GRP="${1:-}"
[ -n "$GRP" ] || vt_die "usage: vmtest run ublk_test_grp <group>"

TEST_DIR="$KERNEL_DIR/tools/testing/selftests/ublk"
[ -d "$TEST_DIR" ] || vt_die "no ublk selftest tree under $KERNEL_DIR"

# The group targets depend on `all`, which builds kublk. Build on the host
# beforehand: an in-guest build without staged uapi headers dies in a wall
# of -Werror noise instead of anything actionable.
[ -x "$TEST_DIR/kublk" ] || vt_die "kublk not built in $TEST_DIR — on the host run:
       make headers_install && make -C tools/testing/selftests/ublk"

vt_log "ublk selftest group: $GRP (KERNEL_DIR=$KERNEL_DIR)"

# The Makefile's parallel mode (JOBS>1) runs tests via `xargs ... || true`,
# so make's exit status never reflects test failures. Capture the output
# and derive the verdict from the kselftest [FAIL] markers as well.
OUT="$(mktemp)"
ret=0
make -C "$TEST_DIR" JOBS=2 "$GRP" 2>&1 | tee "$OUT" || ret=$?

fails=$(grep -c '\[FAIL\]' "$OUT" || true)
if [ "${fails:-0}" -gt 0 ]; then
	vt_log "$fails test(s) FAILED:"
	grep '\[FAIL\]' "$OUT" || true
	ret=1
fi
rm -f "$OUT"

# Always show the kernel log tail (set -e must not skip this on failure),
# and call out splats loudly — tests can PASS while the kernel WARNs.
dmesg | tail -n 80
if dmesg | grep -qE 'WARNING:|BUG:|UBSAN:|Oops:'; then
	vt_log "NOTE: kernel splat(s) in dmesg:"
	dmesg | grep -E 'WARNING:|BUG:|UBSAN:|Oops:' || true
fi
exit "$ret"
