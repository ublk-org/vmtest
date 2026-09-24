#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ublksrv UBLK_F_SHMEM_ZC against ublk.loop with hugetlb buffers
# vmtest-requires: root ublksrv hugetlb fio
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_module ublk_drv
vt_require_ublksrv
vt_require_cmd fio
vt_install_trap

UBLK_LOOP="$UBLKSRV_DIR/.libs/ublk.loop"
[ -x "$UBLK_LOOP" ] || vt_skip "ublk.loop not built"

vt_setup_hugetlb 10
HTLB_BUF="$VT_HUGETLB_MNT/ublk_shmem_buf"
BACKING="$VMTEST_TMPDIR/shmem_zc_backing.img"

vt_atexit "'$VT_UBLK' del -a 2>/dev/null || true"
vt_atexit "rm -f '$HTLB_BUF' '$BACKING'"

fallocate -l 4M "$HTLB_BUF"
truncate -s 256M "$BACKING"
dd if=/dev/zero of="$BACKING" bs=1M count=256 oflag=direct 2>/dev/null

run_dev() {
	"$UBLK_LOOP" add -t loop -q 1 -f "$BACKING" --shmem_zc --htlb "$HTLB_BUF" &
	local kpid=$!
	sleep 2
	local dev=""
	local i
	for i in $(seq 0 9); do
		[ -b "/dev/ublkb$i" ] && dev="/dev/ublkb$i" && break
	done
	[ -n "$dev" ] || { kill $kpid 2>/dev/null; vt_die "no /dev/ublkbN appeared"; }
	echo "$dev"
}

vt_log "test 1: shmem_zc hugetlb randrw"
DEV=$(run_dev)
fio --name=test --filename="$DEV" --ioengine=libaio --direct=1 \
    --bs=4k --iodepth=32 --numjobs=1 \
    --rw=randrw --runtime=10 --time_based \
    --mem=mmaphuge:"$HTLB_BUF" --group_reporting
"$VT_UBLK" del -n "${DEV##/dev/ublkb}" 2>/dev/null || true
wait 2>/dev/null || true
vt_pass "shmem_zc randrw"

vt_log "test 2: shmem_zc hugetlb verify"
DEV=$(run_dev)
fio --name=write --filename="$DEV" --ioengine=libaio --direct=1 \
    --bs=4k --iodepth=32 --numjobs=1 --rw=write --size=4M \
    --mem=mmaphuge:"$HTLB_BUF" --do_verify=0 --verify=crc32c
fio --name=verify --filename="$DEV" --ioengine=libaio --direct=1 \
    --bs=4k --iodepth=32 --numjobs=1 --rw=read --size=4M \
    --mem=mmaphuge:"$HTLB_BUF" --verify=crc32c --verify_only
"$VT_UBLK" del -n "${DEV##/dev/ublkb}" 2>/dev/null || true
wait 2>/dev/null || true
vt_pass "shmem_zc verify"
