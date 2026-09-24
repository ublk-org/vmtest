#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: compare rublk/nbd with ublksrv/nbd (copy and zero-copy modes) over nbdkit with fio
# vmtest-requires: root rublk
# vmtest-host: yes
# RUBLK_DIR points at the rublk checkout; UBLKSRV_DIR at a built ublksrv tree.
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_cmd fio
vt_require_cmd nbdkit

[ -d "${RUBLK_DIR:-}" ] || vt_skip "RUBLK_DIR not set or missing"
UBLKSRV_DIR=${UBLKSRV_DIR:-$RUBLK_DIR/../../ublksrv}
[ -x "$UBLKSRV_DIR/ublk" ] || vt_skip "ublksrv not built at $UBLKSRV_DIR"

rublk_bin=$RUBLK_DIR/target/release/rublk
if [ ! -x "$rublk_bin" ]; then
	cargo_bin=$(command -v cargo) || vt_skip "no cargo for release build"
	case "$cargo_bin" in
	/home/*/.cargo/bin/cargo)
		user_home=${cargo_bin%/.cargo/bin/cargo}
		export CARGO_HOME="$user_home/.cargo" RUSTUP_HOME="$user_home/.rustup"
		;;
	esac
	(cd "$RUBLK_DIR" && cargo build --release --no-default-features)
fi

modprobe ublk_drv 2>/dev/null || true
[ -e /dev/ublk-control ] || vt_skip "no ublk support in kernel"

nbdkit -p 10809 memory 2G --pidfile /tmp/nbdkit.pid
cleanup() {
	"$rublk_bin" del -n 90 >/dev/null 2>&1 || true
	(cd "$UBLKSRV_DIR" && ./ublk del -n 91 >/dev/null 2>&1) || true
	[ -f /tmp/nbdkit.pid ] && kill "$(cat /tmp/nbdkit.pid)" 2>/dev/null || true
}
trap cleanup EXIT
sleep 0.5

FIOC=(--ioengine=libaio --direct=1 --group_reporting)
run_fio() {
	local dev=$1
	local rr rw bw
	rr=$(fio --name=rr --filename="$dev" --rw=randread --bs=4k --iodepth=32 \
		--runtime=8 --time_based "${FIOC[@]}" 2>/dev/null | grep -oP "read: IOPS=\K[0-9.k]+")
	rw=$(fio --name=rw --filename="$dev" --rw=randwrite --bs=4k --iodepth=32 \
		--runtime=8 --time_based "${FIOC[@]}" 2>/dev/null | grep -oP "write: IOPS=\K[0-9.k]+")
	bw=$(fio --name=sr --filename="$dev" --rw=read --bs=64k --iodepth=8 \
		--runtime=8 --time_based "${FIOC[@]}" 2>/dev/null | grep -oP "READ: bw=\K[0-9.]+[MG]iB/s")
	echo "rr=$rr rw=$rw seqbw=$bw"
}

wait_bdev() {
	for _ in $(seq 50); do [ -e "$1" ] && break; sleep 0.2; done
	[ -e "$1" ] || vt_fail "device $1 did not appear"
	sleep 0.5
}

rublk_case() {
	local desc=$1; shift
	"$rublk_bin" add nbd -n 90 -q 1 -d 128 "$@" >/dev/null 2>&1
	wait_bdev /dev/ublkb90
	echo "RESULT rublk-$desc $(run_fio /dev/ublkb90)"
	"$rublk_bin" del -n 90 >/dev/null 2>&1
	sleep 0.5
}

usrv_case() {
	local desc=$1; shift
	(cd "$UBLKSRV_DIR" && ./ublk add -t nbd -n 91 -q 1 -d 128 --host=127.0.0.1 "$@" >/dev/null 2>&1)
	wait_bdev /dev/ublkb91
	echo "RESULT ublksrv-$desc $(run_fio /dev/ublkb91)"
	(cd "$UBLKSRV_DIR" && ./ublk del -n 91 >/dev/null 2>&1)
	sleep 0.5
}

for round in 1 2; do
	echo "ROUND$round"
	usrv_case default
	rublk_case default
	usrv_case zc -z
	rublk_case zc -z
	usrv_case zc+send_zc -z --send_zc
	rublk_case zc+send_zc -z --send-zc
done
echo "nbd zc perf comparison done"
