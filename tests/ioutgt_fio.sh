#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt NVMe/TCP fio data-integrity verify (target on host)
# vmtest-requires: root nvme-cli fio
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap

# The host runner (testing/run_interop.sh) publishes its checkout via
# the marker dir.
IOUTGT_DIR="${IOUTGT_DIR:-$(cat "$VMTEST_TMPDIR/ioutgt_top" 2>/dev/null || true)}"
[ -n "$IOUTGT_DIR" ] && [ -r "$IOUTGT_DIR/testing/vmtest/ioutgt_connect.sh" ] ||
	vt_die "ioutgt repo not found at '${IOUTGT_DIR:-<unset>}' (run via testing/run_interop.sh or set IOUTGT_DIR)"

. "$IOUTGT_DIR/testing/vmtest/ioutgt_connect.sh"

ioutgt_run_m5
ioutgt_mark "PASS fio-verify"
