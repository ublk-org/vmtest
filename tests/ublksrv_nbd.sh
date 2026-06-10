#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ublksrv target full test group (make test T=$1)
# vmtest-requires: root ublksrv nbdkit fio nbd-client
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_module nbd
vt_require_ublksrv
vt_require_cmd nbdkit fio nbd-client
vt_install_trap

vt_log "running: make -C $UBLKSRV_DIR test T=$1"
make -C "$UBLKSRV_DIR" test T=$1
ret=$?

if [ $ret -ne 0 ]; then
	vt_log "T=$1 failed (rc=$ret); recent dmesg:"
	dmesg | tail -n 80
fi

exit "$ret"
