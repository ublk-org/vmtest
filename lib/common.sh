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
	# Snapshot environment overrides before the config file can clobber them.
	# The design rule is: environment > vmtest.conf > defaults.
	# We test ${VAR+set} on the ORIGINAL variable (before sourcing), which is
	# true when it was set in the environment at all — including to an empty
	# string (e.g. UBLKSRV_DIR="" to disable ublksrv is meaningful).
	local _had_KERNEL_DIR=0 _val_KERNEL_DIR=
	[ "${KERNEL_DIR+set}" = set ] && { _had_KERNEL_DIR=1; _val_KERNEL_DIR="$KERNEL_DIR"; }
	local _had_VMTEST_DATA_DIR=0 _val_VMTEST_DATA_DIR=
	[ "${VMTEST_DATA_DIR+set}" = set ] && { _had_VMTEST_DATA_DIR=1; _val_VMTEST_DATA_DIR="$VMTEST_DATA_DIR"; }
	local _had_VMTEST_TMPDIR=0 _val_VMTEST_TMPDIR=
	[ "${VMTEST_TMPDIR+set}" = set ] && { _had_VMTEST_TMPDIR=1; _val_VMTEST_TMPDIR="$VMTEST_TMPDIR"; }
	local _had_UBLKSRV_DIR=0 _val_UBLKSRV_DIR=
	[ "${UBLKSRV_DIR+set}" = set ] && { _had_UBLKSRV_DIR=1; _val_UBLKSRV_DIR="$UBLKSRV_DIR"; }
	local _had_FIO_DIR=0 _val_FIO_DIR=
	[ "${FIO_DIR+set}" = set ] && { _had_FIO_DIR=1; _val_FIO_DIR="$FIO_DIR"; }
	local _had_LIBURING_DIR=0 _val_LIBURING_DIR=
	[ "${LIBURING_DIR+set}" = set ] && { _had_LIBURING_DIR=1; _val_LIBURING_DIR="$LIBURING_DIR"; }
	local _had_RUBLK_DIR=0 _val_RUBLK_DIR=
	[ "${RUBLK_DIR+set}" = set ] && { _had_RUBLK_DIR=1; _val_RUBLK_DIR="$RUBLK_DIR"; }
	# VM tuning knobs (consumed by run_vm, config file sourced here).
	local _had_VMTEST_CPUS=0 _val_VMTEST_CPUS=
	[ "${VMTEST_CPUS+set}" = set ] && { _had_VMTEST_CPUS=1; _val_VMTEST_CPUS="$VMTEST_CPUS"; }
	local _had_VMTEST_MEM=0 _val_VMTEST_MEM=
	[ "${VMTEST_MEM+set}" = set ] && { _had_VMTEST_MEM=1; _val_VMTEST_MEM="$VMTEST_MEM"; }
	local _had_VMTEST_NUMA_NODES=0 _val_VMTEST_NUMA_NODES=
	[ "${VMTEST_NUMA_NODES+set}" = set ] && { _had_VMTEST_NUMA_NODES=1; _val_VMTEST_NUMA_NODES="$VMTEST_NUMA_NODES"; }
	local _had_VMTEST_NET=0 _val_VMTEST_NET=
	[ "${VMTEST_NET+set}" = set ] && { _had_VMTEST_NET=1; _val_VMTEST_NET="$VMTEST_NET"; }
	local _had_VMTEST_SSH=0 _val_VMTEST_SSH=
	[ "${VMTEST_SSH+set}" = set ] && { _had_VMTEST_SSH=1; _val_VMTEST_SSH="$VMTEST_SSH"; }
	local _had_VMTEST_HOLD=0 _val_VMTEST_HOLD=
	[ "${VMTEST_HOLD+set}" = set ] && { _had_VMTEST_HOLD=1; _val_VMTEST_HOLD="$VMTEST_HOLD"; }
	local _had_VMTEST_KCMDLINE_EXTRA=0 _val_VMTEST_KCMDLINE_EXTRA=
	[ "${VMTEST_KCMDLINE_EXTRA+set}" = set ] && { _had_VMTEST_KCMDLINE_EXTRA=1; _val_VMTEST_KCMDLINE_EXTRA="$VMTEST_KCMDLINE_EXTRA"; }
	local _had_VMTEST_QEMU_EXTRA=0 _val_VMTEST_QEMU_EXTRA=
	[ "${VMTEST_QEMU_EXTRA+set}" = set ] && { _had_VMTEST_QEMU_EXTRA=1; _val_VMTEST_QEMU_EXTRA="$VMTEST_QEMU_EXTRA"; }
	local _had_VMTEST_VNG=0 _val_VMTEST_VNG=
	[ "${VMTEST_VNG+set}" = set ] && { _had_VMTEST_VNG=1; _val_VMTEST_VNG="$VMTEST_VNG"; }
	local _had_VMTEST_SDISK_SIZE=0 _val_VMTEST_SDISK_SIZE=
	[ "${VMTEST_SDISK_SIZE+set}" = set ] && { _had_VMTEST_SDISK_SIZE=1; _val_VMTEST_SDISK_SIZE="$VMTEST_SDISK_SIZE"; }
	local _had_VMTEST_NDISK_SIZE=0 _val_VMTEST_NDISK_SIZE=
	[ "${VMTEST_NDISK_SIZE+set}" = set ] && { _had_VMTEST_NDISK_SIZE=1; _val_VMTEST_NDISK_SIZE="$VMTEST_NDISK_SIZE"; }

	local cfg="${VMTEST_CONF:-${VT_TOP}/vmtest.conf}"
	if [ -r "$cfg" ]; then
		# shellcheck disable=SC1090
		. "$cfg"
	fi

	# Restore environment overrides — env beats config file.
	[ "$_had_KERNEL_DIR" = 1 ] && KERNEL_DIR="$_val_KERNEL_DIR"
	[ "$_had_VMTEST_DATA_DIR" = 1 ] && VMTEST_DATA_DIR="$_val_VMTEST_DATA_DIR"
	[ "$_had_VMTEST_TMPDIR" = 1 ] && VMTEST_TMPDIR="$_val_VMTEST_TMPDIR"
	[ "$_had_UBLKSRV_DIR" = 1 ] && UBLKSRV_DIR="$_val_UBLKSRV_DIR"
	[ "$_had_FIO_DIR" = 1 ] && FIO_DIR="$_val_FIO_DIR"
	[ "$_had_LIBURING_DIR" = 1 ] && LIBURING_DIR="$_val_LIBURING_DIR"
	[ "$_had_RUBLK_DIR" = 1 ] && RUBLK_DIR="$_val_RUBLK_DIR"

	# VM tuning knobs — same: env beats config file.
	[ "$_had_VMTEST_CPUS" = 1 ] && VMTEST_CPUS="$_val_VMTEST_CPUS"
	[ "$_had_VMTEST_MEM" = 1 ] && VMTEST_MEM="$_val_VMTEST_MEM"
	[ "$_had_VMTEST_NUMA_NODES" = 1 ] && VMTEST_NUMA_NODES="$_val_VMTEST_NUMA_NODES"
	[ "$_had_VMTEST_NET" = 1 ] && VMTEST_NET="$_val_VMTEST_NET"
	[ "$_had_VMTEST_SSH" = 1 ] && VMTEST_SSH="$_val_VMTEST_SSH"
	[ "$_had_VMTEST_HOLD" = 1 ] && VMTEST_HOLD="$_val_VMTEST_HOLD"
	[ "$_had_VMTEST_KCMDLINE_EXTRA" = 1 ] && VMTEST_KCMDLINE_EXTRA="$_val_VMTEST_KCMDLINE_EXTRA"
	[ "$_had_VMTEST_QEMU_EXTRA" = 1 ] && VMTEST_QEMU_EXTRA="$_val_VMTEST_QEMU_EXTRA"
	[ "$_had_VMTEST_VNG" = 1 ] && VMTEST_VNG="$_val_VMTEST_VNG"
	[ "$_had_VMTEST_SDISK_SIZE" = 1 ] && VMTEST_SDISK_SIZE="$_val_VMTEST_SDISK_SIZE"
	[ "$_had_VMTEST_NDISK_SIZE" = 1 ] && VMTEST_NDISK_SIZE="$_val_VMTEST_NDISK_SIZE"

	# Apply defaults for anything still unset.
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
