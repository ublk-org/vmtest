#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt --pin CPU affinity on a multi-NUMA guest (group_cpus_evenly)
# vmtest-requires: root
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap

# The ioutgt repo is 9p-visible at its host path; the host runner
# (testing/run_affinity.sh) publishes its checkout via the marker dir.
IOUTGT_DIR="${IOUTGT_DIR:-$(cat "$VMTEST_TMPDIR/ioutgt_top" 2>/dev/null ||
	echo /home/ming/git/ioustgt)}"
[ -r "$IOUTGT_DIR/testing/vmtest/ioutgt_affinity.sh" ] ||
	vt_die "ioutgt affinity test not found at $IOUTGT_DIR"

. "$IOUTGT_DIR/testing/vmtest/ioutgt_affinity.sh"

ioutgt_run_affinity
