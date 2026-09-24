#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: focused -z randwrite comparison: ublksrv vs rublk (single-cpu and multi-cpu affinity)
# vmtest-requires: root rublk
# vmtest-host: yes
set -eu
. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_cmd fio
vt_require_cmd nbdkit
[ -d "${RUBLK_DIR:-}" ] || vt_skip "RUBLK_DIR not set"
UBLKSRV_DIR=${UBLKSRV_DIR:-$RUBLK_DIR/../../ublksrv}
rublk_bin=$RUBLK_DIR/target/release/rublk
[ -x "$rublk_bin" ] || vt_skip "release rublk not built"
[ -x "$UBLKSRV_DIR/ublk" ] || vt_skip "ublksrv not built"
modprobe ublk_drv 2>/dev/null || true
[ -e /dev/ublk-control ] || vt_skip "no ublk"

nbdkit -p 10809 memory 2G --pidfile /tmp/nbdkit.pid
cleanup() { "$rublk_bin" del -n 90 >/dev/null 2>&1 || true; (cd "$UBLKSRV_DIR" && ./ublk del -n 91 >/dev/null 2>&1) || true; kill "$(cat /tmp/nbdkit.pid)" 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.5

wr() { fio --name=rw --filename="$1" --rw=randwrite --bs=4k --iodepth=32 --runtime=8 --time_based --ioengine=libaio --direct=1 --group_reporting 2>/dev/null | grep -oP "write: IOPS=\K[0-9.k]+"; }
wait_b() { for _ in $(seq 50); do [ -e "$1" ] && break; sleep 0.2; done; sleep 0.5; }

rub() { D=$1; shift; "$rublk_bin" add nbd -n 90 -q 1 -d 128 -z "$@" >/dev/null 2>&1; wait_b /dev/ublkb90; R=$(wr /dev/ublkb90); "$rublk_bin" del -n 90 >/dev/null 2>&1; sleep 0.3; echo "RESULT $D rw=$R"; }
usr() { (cd "$UBLKSRV_DIR" && ./ublk add -t nbd -n 91 -q 1 -d 128 -z --host=127.0.0.1 >/dev/null 2>&1); wait_b /dev/ublkb91; R=$(wr /dev/ublkb91); (cd "$UBLKSRV_DIR" && ./ublk del -n 91 >/dev/null 2>&1); sleep 0.3; echo "RESULT ublksrv-zc rw=$R"; }

# Prewarm: fault in nbdkit's memory pages so no config pays allocation
"$rublk_bin" add nbd -n 90 -q 1 -d 128 >/dev/null 2>&1; wait_b /dev/ublkb90
fio --name=warm --filename=/dev/ublkb90 --rw=write --bs=1M --size=2G --ioengine=libaio --direct=1 --iodepth=8 >/dev/null 2>&1
wr /dev/ublkb90 >/dev/null
"$rublk_bin" del -n 90 >/dev/null 2>&1; sleep 0.3

for i in 1 2 3; do
  rub rublk-zc
  usr
done
for i in 4 5 6; do
  usr
  rub rublk-zc
done
echo "done"
