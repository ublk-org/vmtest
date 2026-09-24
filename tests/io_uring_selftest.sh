#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: Run kernel tools/testing/selftests/io_uring runner
# vmtest-requires: root kernel-selftests
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_kernel_tree

cd "$KERNEL_DIR/tools/testing/selftests/io_uring" \
	|| vt_die "no io_uring selftest tree under $KERNEL_DIR"
[ -x ./runner ] || vt_die "io_uring selftest 'runner' not built"
exec ./runner
