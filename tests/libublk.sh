#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: cargo test the libublk-rs crate (RUBLK_DIR points at the checkout)
# vmtest-requires: root rublk ublk_drv
# vmtest-host: yes
# Note: reuses RUBLK_DIR (propagated into the guest by run_vm) as the crate
#       directory. Inside the VM the test runs as root while the rust
#       toolchain lives under the invoking user's home, so point
#       rustup/cargo there explicitly.
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_cmd cargo
vt_require_module ublk_drv

[ -d "$RUBLK_DIR" ] || vt_skip "RUBLK_DIR not set or missing: $RUBLK_DIR"

cargo_bin=$(command -v cargo)
case "$cargo_bin" in
/home/*/.cargo/bin/cargo)
	user_home=${cargo_bin%/.cargo/bin/cargo}
	export CARGO_HOME="$user_home/.cargo" RUSTUP_HOME="$user_home/.rustup"
	;;
esac

cd "$RUBLK_DIR"
exec cargo test "$@"
