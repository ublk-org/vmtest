#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: Run ublk BPF selftests bpf_01..05 with the module preloaded (=m safe)
# vmtest-requires: root kernel-selftests
# Usage: ./vmtest run ublk_bpf_all
set -u

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_kernel_tree

cd "$KERNEL_DIR/tools/testing/selftests/ublk" || vt_die "no ublk selftest tree"

# =m: preload the module so _have_feature "BPF" (which runs kublk BEFORE the
# test's own modprobe in _prep_test) sees /dev/ublk-control and does not SKIP.
modprobe ublk_drv 2>/dev/null || \
	insmod "$KERNEL_DIR/drivers/block/ublk/ublk_drv.ko" 2>/dev/null || true
if [ -c /dev/ublk-control ]; then
	vt_log "ublk_drv loaded, /dev/ublk-control present"
else
	vt_log "WARN: /dev/ublk-control missing after preload"
fi

summary=""
ret=0
for t in test_bpf_01.sh test_bpf_02.sh test_bpf_03.sh test_bpf_04.sh \
	 test_bpf_05.sh test_loop_01.sh test_loop_03.sh; do
	if [ ! -f "./$t" ]; then
		summary="${summary}
  ${t}: MISSING"
		ret=1
		continue
	fi
	out="$(./"$t" 2>&1)"
	rc=$?
	verdict="$(printf '%s\n' "$out" | grep -oE '\b(PASS|FAIL|SKIP)\b' | tail -1)"
	summary="${summary}
  ${t}: rc=${rc} ${verdict:-?}"
	printf '%s\n' "$out" | tail -4
	[ "$rc" -ne 0 ] && ret=1
done

vt_log "==================== BPF SELFTEST SUMMARY ===================="
printf '%s\n' "$summary"
vt_log "============================================================="

if dmesg | grep -qE 'WARNING:|BUG:|Oops:|UBSAN:'; then
	vt_log "NOTE: kernel splat(s):"
	dmesg | grep -E 'WARNING:|BUG:|Oops:|UBSAN:' || true
	ret=1
fi
exit "$ret"
