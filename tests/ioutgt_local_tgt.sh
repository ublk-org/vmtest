#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt + nvmet two-target loopback driver (testing/local_tgt.sh)
# vmtest-requires: root nvme-cli
#
# Self-contained: runs BOTH the ioutgt and kernel nvmet-tcp targets and the
# initiator on 127.0.0.1 inside the guest, exercising testing/local_tgt.sh
# end to end (start -> connect -> fio -> disconnect -> stop).
#
#   ~/git/utils/vmtest/vmtest -c ~/git/linux-knext/vmtest.conf \
#       run ioutgt_local_tgt /home/ming/git/io-target/worktree/ioutgt-nbd
set -eu

# Capture the repo path arg before any helper touches $@.
REPO_ARG="${1:-}"

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap
vt_require_cmd nvme
vt_require_module nvme_tcp
vt_require_module nvmet_tcp

# The ioutgt checkout is virtiofs-visible at its host path; pass it as arg1
# (or IOUTGT_DIR). The release binary must already be built on the host.
IOUTGT_DIR="${IOUTGT_DIR:-$REPO_ARG}"
[ -n "$IOUTGT_DIR" ] && [ -x "$IOUTGT_DIR/testing/local_tgt.sh" ] ||
	vt_die "pass the ioutgt checkout dir: vmtest run ioutgt_local_tgt <repo>"
cd "$IOUTGT_DIR"
[ -x target/release/ioutgt ] ||
	vt_die "build it on the host first: cargo build --release -p ioutgt"

S=./testing/local_tgt.sh

# Both backends are file/bdev (local_tgt.sh is file-backend only). ioutgt
# takes a plain file: it uses a fixed block_shift, so vng's /tmp overlayfs
# (whose inode reports i_blkbits 0) is fine, and O_DIRECT falls back to
# buffered there. nvmet derives its LBA size from the inode, so a file on
# that overlay would advertise LBA 0 ("invalid LBA data size 0, skipping
# namespace") — back it with a loop device instead (also exercises the bdev
# path). IOUTGT_BACKEND is auto-created by local_tgt.sh's ensure_backing.
export IOUTGT_BACKEND=/tmp/lt-ioutgt.img
modprobe loop 2>/dev/null || true
NVIMG=/tmp/lt-nvmet.img
truncate -s 256M "$NVIMG"
LOOP=$(losetup -f --show "$NVIMG") || vt_die "losetup failed"
export NVMET_BACKEND="$LOOP"
export BACKEND_GB=1
export NR_QUEUES=2 QUEUE_SIZE=64
export FIO_SECS=3 FIO_JOBS=2 FIO_QD=8

cleanup() {
	"$S" disconnect >/dev/null 2>&1 || true
	"$S" stop       >/dev/null 2>&1 || true
	[ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
	rm -f "$NVIMG" "$IOUTGT_BACKEND"
}
vt_atexit cleanup

# Run the full lifecycle with digests off, then on. HDGST/DDGST are read
# fresh on each local_tgt.sh invocation, so this proves nvmet and ioutgt
# negotiate identically in both modes (the digest-on leg exercises the
# CRC32C header+data digest framing on the IO path for both targets).
for dg in "0 0" "1 1"; do
	read -r HDGST DDGST <<<"$dg"
	export HDGST DDGST
	vt_log "=== digests HDGST=$HDGST DDGST=$DDGST ==="
	"$S" start
	"$S" connect
	"$S" status | tee /tmp/lt-status
	grep -Eq 'ioutgt.*: /dev/nvme' /tmp/lt-status || vt_die "ioutgt namespace missing (HDGST=$HDGST)"
	grep -Eq 'nvmet.*: /dev/nvme'  /tmp/lt-status || vt_die "nvmet namespace missing (HDGST=$HDGST)"
	if command -v fio >/dev/null 2>&1; then
		"$S" fio
	else
		for kind in ioutgt nvmet; do
			dev=$(awk -v k="$kind" '$0 ~ k && /\/dev\/nvme/ {print $NF}' /tmp/lt-status)
			[ -b "$dev" ] || vt_die "no block device for $kind (HDGST=$HDGST)"
			dd if="$dev" of=/dev/null bs=4k count=16 iflag=direct status=none ||
				vt_die "dd read from $kind ($dev) failed (HDGST=$HDGST)"
		done
	fi
	"$S" disconnect
	"$S" stop
done

vt_pass "local_tgt.sh: ioutgt + nvmet two-target loopback verified (digests off and on)"
