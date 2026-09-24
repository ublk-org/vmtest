#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: UBLK_F_SHMEM_ZC against ublk.nvme_vfio (modern IOMMUFD path)
# vmtest-requires: root ublksrv hugetlb fio nvme-pci vfio
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_module ublk_drv vfio_pci
vt_require_ublksrv
vt_require_cmd fio
vt_install_trap

UBLK_VFIO="$UBLKSRV_DIR/.libs/ublk.nvme_vfio"
[ -x "$UBLK_VFIO" ] || vt_skip "ublk.nvme_vfio not built"

PCI=$(vt_find_nvme_pci) || true
[ -n "$PCI" ] || vt_skip "no NVMe PCI device in this VM"
vt_log "found NVMe at $PCI"

vt_setup_hugetlb 2248
HTLB_BUF="$VT_HUGETLB_MNT/ublk_shmem_buf"
vt_atexit "'$VT_UBLK' del -a 2>/dev/null || true"
vt_atexit "rm -f '$HTLB_BUF'"
fallocate -l 4G "$HTLB_BUF"

run_dev() {
	"$UBLK_VFIO" add --pci "$PCI" -q 2 -d 128 --shmem_zc --htlb "$HTLB_BUF" &
	local kpid=$!
	sleep 3
	vt_wait_for_block /dev/ublkb0 5 || { kill $kpid 2>/dev/null; vt_die "/dev/ublkb0 not created"; }
}

vt_log "test 1: nvme_vfio shmem_zc randrw"
run_dev
fio --name=test --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
    --bs=4k --iodepth=32 --numjobs=1 \
    --rw=randrw --runtime=10 --time_based \
    --mem=mmaphuge:"$HTLB_BUF" --group_reporting
"$VT_UBLK" del -n 0 2>/dev/null || true
wait 2>/dev/null || true
vt_pass "shmem_zc randrw"

vt_log "test 2: nvme_vfio shmem_zc verify"
run_dev
fio --name=write --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
    --bs=4k --iodepth=32 --numjobs=1 --rw=write --size=4M \
    --mem=mmaphuge:"$HTLB_BUF" --do_verify=0 --verify=crc32c
fio --name=verify --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
    --bs=4k --iodepth=32 --numjobs=1 --rw=read --size=4M \
    --mem=mmaphuge:"$HTLB_BUF" --verify=crc32c --verify_only
"$VT_UBLK" del -n 0 2>/dev/null || true
wait 2>/dev/null || true
vt_pass "shmem_zc verify"
