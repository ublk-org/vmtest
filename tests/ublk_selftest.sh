#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: Run a single ublk kernel selftest by filename pattern
# vmtest-requires: root kernel-selftests
# Usage: ./vmtest run ublk_selftest [pattern]   (default: test_null_01.sh)
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_kernel_tree

cd "$KERNEL_DIR/tools/testing/selftests/ublk" \
	|| vt_die "no ublk selftest tree under $KERNEL_DIR"

pattern="${1:-test_null_01.sh}"
vt_log "ublk selftest: $pattern"

ret=0
if [ -f "./$pattern" ]; then
	./"$pattern" || ret=$?
else
	for t in $pattern; do
		[ -f "./$t" ] && { ./"$t" || ret=$?; }
	done
fi
exit "$ret"
