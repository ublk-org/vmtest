#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: run the libublk-rs loop example (sync and async) against a file and verify IO
# vmtest-requires: root rublk
# vmtest-host: yes
# Note: like libublk.sh, RUBLK_DIR points at the crate checkout and the
#       rust toolchain lives under the invoking user's home.
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_cmd cargo

[ -d "$RUBLK_DIR" ] || vt_skip "RUBLK_DIR not set or missing: $RUBLK_DIR"

cargo_bin=$(command -v cargo)
case "$cargo_bin" in
/home/*/.cargo/bin/cargo)
	user_home=${cargo_bin%/.cargo/bin/cargo}
	export CARGO_HOME="$user_home/.cargo" RUSTUP_HOME="$user_home/.rustup"
	;;
esac

cd "$RUBLK_DIR"
cargo build --example loop

loop_bin=./target/debug/examples/loop
back=$(mktemp /tmp/lo_back.XXXXXX)
data=$(mktemp /tmp/lo_data.XXXXXX)
lo_pid=

cleanup() {
	"$loop_bin" del -n 0 >/dev/null 2>&1 || true
	[ -n "$lo_pid" ] && kill "$lo_pid" 2>/dev/null || true
	rm -f "$back" "$data"
}
trap cleanup EXIT

dd if=/dev/urandom of="$back" bs=1M count=64 status=none
dd if=/dev/urandom of="$data" bs=1M count=64 status=none

for mode in "" "-a"; do
	# shellcheck disable=SC2086  # $mode is deliberately word-split
	"$loop_bin" add -n 0 -f "$back" --foreground $mode &
	lo_pid=$!
	for _ in $(seq 50); do
		[ -b /dev/ublkb0 ] && break
		sleep 0.2
	done
	[ -b /dev/ublkb0 ] || {
		echo "loop device did not appear (mode: ${mode:-sync})"
		exit 1
	}

	# read path: the device must expose the backing file's content
	exp=$(md5sum <"$back" | cut -d' ' -f1)
	got=$(dd if=/dev/ublkb0 bs=1M count=64 iflag=direct status=none | md5sum | cut -d' ' -f1)
	[ "$exp" = "$got" ] || {
		echo "read mismatch (mode: ${mode:-sync})"
		exit 1
	}

	# write path (+ conv=fsync driving the FLUSH op): the new content
	# must land in the backing file
	dd if="$data" of=/dev/ublkb0 bs=1M count=64 oflag=direct conv=fsync status=none
	exp=$(md5sum <"$data" | cut -d' ' -f1)
	got=$(md5sum <"$back" | cut -d' ' -f1)
	[ "$exp" = "$got" ] || {
		echo "write mismatch (mode: ${mode:-sync})"
		exit 1
	}

	"$loop_bin" del -n 0
	wait "$lo_pid" 2>/dev/null || true
	lo_pid=
done

echo "libublk loop example: sync and async modes OK"
