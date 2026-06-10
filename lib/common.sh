# SPDX-License-Identifier: GPL-2.0
#
# Common helpers for vmtest scripts.
#
# Test scripts should `source` this file and rely on the helpers below
# instead of re-implementing trap/cleanup/hugetlb/wait-for-device logic.
#
# Convention: every helper that allocates a resource registers its own
# cleanup with vt_atexit, so a single `trap vt_run_atexit EXIT` at the
# top of a test is enough to undo everything that ran.

# Resolve our own directory regardless of caller's cwd.
VT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VT_TOP="$(cd "${VT_LIB_DIR}/.." && pwd)"

# ----------------------------------------------------------------------
# Logging / failure
# ----------------------------------------------------------------------

vt_log()  { printf '[vmtest] %s\n' "$*" >&2; }
vt_warn() { printf '[vmtest] WARN: %s\n' "$*" >&2; }
vt_die()  { printf '[vmtest] FAIL: %s\n' "$*" >&2; exit 1; }
vt_skip() { printf '[vmtest] SKIP: %s\n' "$*" >&2; exit 4; }
vt_pass() { printf '[vmtest] PASS: %s\n' "$*" >&2; }

# If VMTEST_HOLD=1 was passed in, block here so the VM stays up for
# post-mortem inspection (run_vm forwards the env var into the guest).
# Pair with `VMTEST_SSH=1` on the host invocation; attach with
#   vng --ssh-client --ssh-tcp
# from another terminal. Cleanup atexit hooks still run on Ctrl-C.
vt_hold() {
	[ -n "${VMTEST_HOLD:-}" ] || return 0
	vt_log "VMTEST_HOLD=1: pausing. attach with: vng --ssh-client --ssh-tcp"
	vt_log "  release with: kill -TERM \$\$ (in-guest) or reboot -f"
	sleep infinity
}

# ----------------------------------------------------------------------
# Cleanup stack
# ----------------------------------------------------------------------

VT_ATEXIT_CMDS=()

vt_atexit() {
	VT_ATEXIT_CMDS+=("$*")
}

vt_run_atexit() {
	local rc=$?
	# LIFO so resources are torn down in reverse order of allocation.
	local i
	for (( i = ${#VT_ATEXIT_CMDS[@]} - 1; i >= 0; i-- )); do
		eval "${VT_ATEXIT_CMDS[$i]}" || true
	done
	exit "$rc"
}

vt_install_trap() {
	trap vt_run_atexit EXIT
}

# ----------------------------------------------------------------------
# Config: load vmtest.conf if present, then let env overrides win.
# ----------------------------------------------------------------------

vt_load_config() {
	local cfg="${VMTEST_CONF:-${VT_TOP}/vmtest.conf}"
	if [ -r "$cfg" ]; then
		# shellcheck disable=SC1090
		. "$cfg"
	fi

	: "${KERNEL_DIR:=${VT_TOP}/..}"
	# Canonicalize only if it actually resolves — let the caller diagnose.
	local resolved
	if resolved="$(cd "$KERNEL_DIR" 2>/dev/null && pwd)"; then
		KERNEL_DIR="$resolved"
	fi
	: "${VMTEST_DATA_DIR:=${VT_TOP}/data}"
	: "${VMTEST_TMPDIR:=${VMTEST_DATA_DIR}/tmp}"

	# Optional — only checked by tests that explicitly require them.
	: "${UBLKSRV_DIR:=}"
	: "${FIO_DIR:=}"
	: "${LIBURING_DIR:=}"
	: "${RUBLK_DIR:=${VMTEST_DATA_DIR}/rublk}"

	mkdir -p "$VMTEST_DATA_DIR" "$VMTEST_TMPDIR"
	export KERNEL_DIR VMTEST_DATA_DIR VMTEST_TMPDIR
	export UBLKSRV_DIR FIO_DIR RUBLK_DIR LIBURING_DIR
}

# ----------------------------------------------------------------------
# Requirements — tests call these at the top to declare what they need.
# Missing optional pieces → SKIP (exit 4), missing hard requirements → FAIL.
# ----------------------------------------------------------------------

vt_require_root() {
	[ "$(id -u)" -eq 0 ] || vt_die "must run as root (inside the VM)"
}

vt_require_cmd() {
	local c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || vt_skip "missing command: $c"
	done
}

vt_require_module() {
	local m
	for m in "$@"; do
		modprobe "$m" 2>/dev/null || vt_skip "cannot modprobe $m"
	done
}

vt_require_ublksrv() {
	[ -n "$UBLKSRV_DIR" ] || vt_skip "UBLKSRV_DIR not set in vmtest.conf"
	[ -x "$UBLKSRV_DIR/.libs/ublk" ] \
		|| vt_skip "ublksrv not built at $UBLKSRV_DIR"
	export LD_LIBRARY_PATH="$UBLKSRV_DIR/lib/.libs:${LD_LIBRARY_PATH:-}"
	VT_UBLK="$UBLKSRV_DIR/.libs/ublk"
	export VT_UBLK
}

vt_require_fio() {
	command -v fio >/dev/null 2>&1 || vt_skip "fio not installed"
	if [ -n "$FIO_DIR" ] && [ -x "$FIO_DIR/t/io_uring" ]; then
		VT_T_IO_URING="$FIO_DIR/t/io_uring"
		export VT_T_IO_URING
	fi
}

# ----------------------------------------------------------------------
# Hugetlb helper — mounts hugetlbfs at /tmp/hugetlb and allocates pages.
# Auto-registers umount + page reset on EXIT.
# ----------------------------------------------------------------------

vt_setup_hugetlb() {
	local nr_pages="${1:-256}"
	local mnt="${VT_HUGETLB_MNT:-/tmp/hugetlb}"
	local prev_nr
	prev_nr=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)

	echo "$nr_pages" > /proc/sys/vm/nr_hugepages
	local got
	got=$(cat /proc/sys/vm/nr_hugepages)
	[ "$got" -ge "$nr_pages" ] \
		|| vt_skip "cannot allocate $nr_pages hugepages (got $got)"

	mkdir -p "$mnt"
	if ! mountpoint -q "$mnt"; then
		mount -t hugetlbfs none "$mnt" || vt_die "hugetlbfs mount failed"
		vt_atexit "umount '$mnt' 2>/dev/null"
	fi
	vt_atexit "echo $prev_nr > /proc/sys/vm/nr_hugepages 2>/dev/null"

	VT_HUGETLB_MNT="$mnt"
	export VT_HUGETLB_MNT
}

# ----------------------------------------------------------------------
# Block-device helpers
# ----------------------------------------------------------------------

vt_wait_for_block() {
	local dev="$1"
	local timeout="${2:-10}"
	local i
	for (( i = 0; i < timeout * 10; i++ )); do
		[ -b "$dev" ] && return 0
		sleep 0.1
	done
	return 1
}

vt_find_nvme_pci() {
	lspci -D 2>/dev/null | awk '/Non-Volatile memory|NVMe/ { print $1; exit }'
}

# ----------------------------------------------------------------------
# Kernel state probes
# ----------------------------------------------------------------------

vt_dmesg_clear() { dmesg -c >/dev/null 2>&1 || true; }

# Returns 0 if any of the given patterns appears in dmesg.
vt_dmesg_has() {
	local p
	for p in "$@"; do
		if dmesg | grep -qE -- "$p"; then return 0; fi
	done
	return 1
}
