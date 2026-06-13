#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt NVMe/TCP target interop (target on host 10.0.2.2:4420)
# vmtest-requires: root nvme-cli
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap

# The ioutgt repo is 9p-visible at its host path; the host runner
# (testing/run_interop.sh) publishes its checkout via the marker dir.
IOUTGT_DIR="${IOUTGT_DIR:-$(cat "$VMTEST_TMPDIR/ioutgt_top" 2>/dev/null || true)}"
[ -n "$IOUTGT_DIR" ] && [ -r "$IOUTGT_DIR/testing/vmtest/ioutgt_connect.sh" ] ||
	vt_die "ioutgt repo not found at '${IOUTGT_DIR:-<unset>}' (run via testing/run_interop.sh or set IOUTGT_DIR)"

. "$IOUTGT_DIR/testing/vmtest/ioutgt_connect.sh"

ioutgt_run_${IOUTGT_MILESTONE:-all}
