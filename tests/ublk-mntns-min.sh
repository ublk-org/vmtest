#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ublk mnt_ns self-deadlock repro + --fix verification (libublk-rs #50)
# vmtest-requires: root rublk ublk_drv
#
# Default mode (no args): reproduce the bug. Pass --fix to verify the
# §9.1 userspace mitigation (daemon in its own mnt_ns).
#
#   ./vmtest run ublk-mntns-min            # show the bug / kernel mitigation
#   ./vmtest run ublk-mntns-min --fix      # verify the userspace fix
set -u

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_cmd rublk
vt_require_cmd mkfs.ext4
vt_require_cmd unshare
vt_require_module ublk_drv

DEV=ublkb0 ID=0 IMG=/tmp/u-min.img MNT=/tmp/u-min-mnt
truncate -s 1G "$IMG"; mkdir -p "$MNT"

vt_install_trap
vt_atexit "rublk del -n $ID 2>/dev/null || true"
vt_atexit "rm -f $IMG"

if [ "${1:-}" = --fix ]; then
    unshare --mount rublk add loop -n $ID -f $IMG -q 1 --quiet
    DAEMON_IN_SHELL=
else
    DAEMON_IN_SHELL="rublk add loop -n $ID -f $IMG -q 1 --quiet; sleep 1"
fi

unshare --mount --fork bash -c "
    set -e
    $DAEMON_IN_SHELL
    mkfs.ext4 -F /dev/$DEV >/dev/null
    mount /dev/$DEV $MNT
    dd if=/dev/zero of=$MNT/dirty bs=1M count=64 conv=fsync status=none
"

PID=$(pgrep -of rublk)
kill -KILL "$PID"
sleep 3

if [ -d "/proc/$PID" ]; then
    cat "/proc/$PID/stack" >&2
    vt_die "DEADLOCK: daemon $PID stuck in cleanup_mnt"
fi
if dmesg | tail -50 | grep -q 'I/O error.*ublkb'; then
    vt_pass "OK-but-EIO: kernel masked the hang with -EIO; data lost (no --fix)"
else
    vt_pass "OK-clean: ext4 flush landed; daemon served it"
fi
