#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: Generic CephFS kernel-client test suite (vstart cluster inside the VM)
# vmtest-requires: root ceph-build
#
# A general-purpose functional suite for the CephFS kernel client. Brings up a
# vstart Ceph cluster INSIDE the guest (server and client in the same VM) and
# exercises the kclient against it. Intended for verifying any kernel change
# that touches fs/ceph or net/ceph -- not tied to one patch series.
#
# Cases run on a stock mainline kernel as well as a patched one: anything that
# depends on a not-yet-merged feature probes for it first and SKIPs when the
# kernel does not support it.
#
#   mount       mount/umount, v1 + v2 (msgr2) syntax, subdir and ro mounts
#   basic       buffered + O_DIRECT + mmap IO, truncate, sparse, fsync
#   meta        create/rename/link/symlink/xattr/permission semantics
#   readdir     large directory listing, warm and cold
#   coherency   two independent clients see each other's writes
#   stress      concurrent metadata + data storm from many tasks
#   snapshot    .snap create/list/read/delete
#   failover    MDS fail + reconnect, mount survives
#   evict       client blocklist/eviction and recovery
#   fsstress    generic fs stress (if fsstress/fsx available)
#   lazyio      'lazyio' mount option           [probed: needs the lazyio patch]
#
# Usage:
#   vmtest -c <conf> run cephfs_kclient                 # default case set
#   vmtest -c <conf> run cephfs_kclient basic meta      # selected cases
#   vmtest -c <conf> run cephfs_kclient all             # every case
#   vmtest -c <conf> run cephfs_kclient list            # list and exit
#
# Config (vmtest.conf):
#   CEPH_BUILD_DIR="/path/to/ceph/build"     required
#   VMTEST_QEMU_EXTRA="-drive file=$VMTEST_DATA_DIR/ceph.img,format=raw,if=none,id=ceph_drv -device nvme,drive=ceph_drv,serial=cephtest"
#
# Knobs -- set these in vmtest.conf. run_vm forwards only a fixed whitelist
# of variables into the guest, so setting CEPHTEST_* in the host environment
# has no effect:
#   CEPHTEST_BACKING    disk (default) | tmpfs      -- where cluster state lives
#   CEPHTEST_STORE      bluestore (default) | memstore
#   CEPHTEST_DEV        block device override
#   CEPHTEST_MON/OSD/MDS/MGR    daemon counts (default 1/1/1/1)
#   CEPHTEST_MULTIMDS   max_mds to configure
#   CEPHTEST_CASES      default case list
#   CEPHTEST_STRESS_PROCS / _OPS      concurrency of the stress case
#   CEPHTEST_READDIR_N                entries in the readdir case
#   CEPHTEST_ARTIFACTS                artifact subdir name (default cephfs_kclient)
set -eu

. "$(dirname "$0")/../lib/common.sh"

ALL_CASES="mount basic meta readdir coherency stress snapshot failover evict fsstress lazyio"
DEFAULT_CASES="mount basic meta readdir coherency stress failover lazyio"

if [ "${1:-}" = list ]; then
	echo "available cases: $ALL_CASES"
	echo "default cases:   $DEFAULT_CASES"
	exit 0
fi

vt_load_config
vt_require_root
vt_install_trap

CEPHTEST_STRESS_PROCS="${CEPHTEST_STRESS_PROCS:-16}"
CEPHTEST_STRESS_OPS="${CEPHTEST_STRESS_OPS:-200}"
CEPHTEST_READDIR_N="${CEPHTEST_READDIR_N:-20000}"
ARTIFACT_NAME="${CEPHTEST_ARTIFACTS:-cephfs_kclient}"

case "${1:-}" in
	all) CASES="$ALL_CASES" ;;
	"")  CASES="${CEPHTEST_CASES:-$DEFAULT_CASES}" ;;
	*)   CASES="$*" ;;
esac

# Validate the requested cases up front: a typo should cost a second, not a
# VM boot plus a full cluster bring-up.
for _c in $CASES; do
	case " $ALL_CASES " in
		*" $_c "*) ;;
		*) vt_die "unknown case '$_c' (valid: $ALL_CASES)" ;;
	esac
done
unset _c

# ======================================================================
# CephFS cluster / mount plumbing
#
# Brings up a vstart Ceph cluster inside the guest from a host-side ceph
# build (read-only over 9p, all mutable state redirected via VSTART_DEST)
# and mounts it with the kernel client under test. Everything allocated
# registers its own vt_atexit cleanup, so the single vt_install_trap above
# unwinds all of it.
# ======================================================================

CEPH_WORK="${CEPH_WORK:-/var/tmp/cephtest}"	# cluster state (conf, dev, out)
# Mountpoints MUST be on a writable fs. /mnt is part of the read-only 9p root
# in the guest, and with the new mount API a missing target is not caught
# early: the superblock is fully built (mon session, cephx, fsid) and only
# move_mount() returns ENOENT, which surfaces as the misleading message
# "mount point does not exist".
CEPH_MNT="${CEPH_MNT:-/var/tmp/ceph-mnt}"
# NOTE: no shared "second mountpoint" global on purpose -- use ceph_mnt_for
# <case> so a broken mount in one case cannot poison another.
CEPH_CONF=""
CEPH_FSNAME=""
CEPH_FSID=""

# ----------------------------------------------------------------------
# Build discovery
# ----------------------------------------------------------------------

ceph_require_build() {
	CEPH_BUILD_DIR="${CEPH_BUILD_DIR:-}"
	[ -n "$CEPH_BUILD_DIR" ] \
		|| vt_skip "CEPH_BUILD_DIR not set (add it to vmtest.conf)"
	[ -x "$CEPH_BUILD_DIR/bin/ceph-mon" ] \
		|| vt_skip "no ceph build at $CEPH_BUILD_DIR (missing bin/ceph-mon)"
	CEPH_SRC_DIR="${CEPH_SRC_DIR:-$(cd "$CEPH_BUILD_DIR/.." && pwd)/src}"
	[ -x "$CEPH_SRC_DIR/vstart.sh" ] \
		|| vt_skip "no vstart.sh at $CEPH_SRC_DIR"

	CEPH_BIN="$CEPH_BUILD_DIR/bin"
	CEPH_LIB="$CEPH_BUILD_DIR/lib"
	CEPH_CONF="$CEPH_WORK/ceph.conf"
	export LD_LIBRARY_PATH="$CEPH_LIB:${LD_LIBRARY_PATH:-}"

	# A stale ceph build (binaries older than libceph-common) does not crash,
	# it SPINS forever inside md_config_t::find_option(). Catch that here
	# rather than letting vstart hang for the whole test timeout. Note
	# --version short-circuits before global_init(), so it is useless as a
	# probe; --show-config actually goes through config init.
	if ! timeout 30 "$CEPH_BIN/ceph-conf" --show-config >/dev/null 2>&1; then
		vt_skip "ceph build at $CEPH_BUILD_DIR is broken (ceph-conf hangs or
       fails). Usually stale binaries vs a newer libceph-common; rebuild with:
         ninja bin/ceph-mon bin/ceph-osd bin/ceph-mds bin/ceph-mgr \\
               bin/ceph-authtool bin/ceph-conf bin/monmaptool bin/crushtool \\
               bin/rados bin/rbd cython_modules"
	fi
	vt_log "ceph build: $CEPH_BUILD_DIR (usable)"
}

# The ceph CLI blocks indefinitely on a wedged/unreachable mon rather than
# erroring out, which would make every "bounded" retry loop below unbounded.
ceph_cli() {
	timeout "${CEPHTEST_CLI_TIMEOUT:-60}" "$CEPH_BIN/ceph" -c "$CEPH_CONF" "$@"
}

# ----------------------------------------------------------------------
# Cluster state backing
# ----------------------------------------------------------------------

# Find the disk dedicated to ceph testing by its QEMU serial, never by device
# name: the shared d1/d2 scratch disks other tests reformat would otherwise be
# claimed at random depending on enumeration order.
ceph_find_disk() {
	local s dev
	for s in /sys/class/nvme/nvme*/serial; do
		[ -r "$s" ] || continue
		if [ "$(tr -d ' \n' < "$s")" = cephtest ]; then
			dev="/dev/$(basename "$(dirname "$s")")n1"
			[ -b "$dev" ] && { echo "$dev"; return 0; }
		fi
	done
	return 1
}

ceph_setup_backing() {
	local backing="${CEPHTEST_BACKING:-disk}"
	CEPHTEST_STORE="${CEPHTEST_STORE:-bluestore}"
	mkdir -p "$CEPH_WORK"

	case "$backing" in
	tmpfs)
		mount -t tmpfs -o size="${CEPHTEST_TMPFS_SIZE:-4G}" tmpfs "$CEPH_WORK" \
			|| vt_die "tmpfs mount on $CEPH_WORK failed"
		vt_atexit "umount '$CEPH_WORK' 2>/dev/null"
		# BlueStore opens its block file O_DIRECT, which tmpfs cannot do.
		if [ "$CEPHTEST_STORE" = bluestore ]; then
			vt_log "tmpfs backing: switching to memstore (bluestore needs O_DIRECT)"
			CEPHTEST_STORE=memstore
		fi
		;;
	disk)
		local dev="${CEPHTEST_DEV:-}"
		[ -n "$dev" ] || dev=$(ceph_find_disk) || true
		[ -n "$dev" ] || vt_skip "no dedicated ceph disk (serial 'cephtest').
       Add to vmtest.conf:
         VMTEST_QEMU_EXTRA=\"-drive file=\$VMTEST_DATA_DIR/ceph.img,format=raw,if=none,id=ceph_drv -device nvme,drive=ceph_drv,serial=cephtest\"
       and create it: truncate -s 20G \$VMTEST_DATA_DIR/ceph.img
       Or set CEPHTEST_DEV=/dev/... explicitly."
		local bytes; bytes=$(blockdev --getsize64 "$dev" 2>/dev/null) || bytes=0
		vt_log "cluster state on $dev ($((bytes / 1024/1024/1024))G)"
		wipefs -a "$dev" >/dev/null 2>&1 || true
		mkfs.ext4 -q -F "$dev" || vt_die "mkfs.ext4 on $dev failed"
		mount "$dev" "$CEPH_WORK" || vt_die "mount $dev on $CEPH_WORK failed"
		vt_atexit "umount '$CEPH_WORK' 2>/dev/null"
		;;
	*)
		vt_die "unknown CEPHTEST_BACKING='$backing' (disk|tmpfs)"
		;;
	esac
	mkdir -p "$CEPH_WORK/dev" "$CEPH_WORK/out" "$CEPH_WORK/asok"
}

# ----------------------------------------------------------------------
# Cluster lifecycle
# ----------------------------------------------------------------------

ceph_start_cluster() {
	local store_arg
	case "${CEPHTEST_STORE:-bluestore}" in
	bluestore) store_arg="-b" ;;
	memstore)  store_arg="--memstore" ;;
	*) vt_die "unknown CEPHTEST_STORE='$CEPHTEST_STORE'" ;;
	esac
	local port="${CEPHTEST_PORT:-40000}"
	local nmon="${CEPHTEST_MON:-1}" nosd="${CEPHTEST_OSD:-1}"
	local nmds="${CEPHTEST_MDS:-1}" nmgr="${CEPHTEST_MGR:-1}"

	vt_log "vstart: mon=$nmon osd=$nosd mds=$nmds mgr=$nmgr store=${CEPHTEST_STORE} port=$port"
	vt_atexit "ceph_stop_cluster"

	# cwd must be the build dir: vstart keys off CMakeCache.txt there.
	# VSTART_DEST redirects ceph.conf/dev/out/asok into CEPH_WORK so the 9p
	# build tree itself stays read-only.
	(
		cd "$CEPH_BUILD_DIR" || exit 1
		MON="$nmon" OSD="$nosd" MDS="$nmds" MGR="$nmgr" RGW=0 NFS=0 \
		VSTART_DEST="$CEPH_WORK" CEPH_PORT="$port" \
		CEPH_BIN="$CEPH_BIN" CEPH_LIB="$CEPH_LIB" \
		timeout "${CEPHTEST_VSTART_TIMEOUT:-900}" \
			"$CEPH_SRC_DIR/vstart.sh" -n -l --without-dashboard $store_arg
	) > "$CEPH_WORK/vstart.log" 2>&1 || {
		vt_log "vstart failed; tail of vstart.log:"
		tail -40 "$CEPH_WORK/vstart.log" >&2
		vt_die "cluster bring-up failed"
	}
	[ -r "$CEPH_CONF" ] || vt_die "vstart produced no $CEPH_CONF"

	ceph_wait_fs
	if [ -n "${CEPHTEST_MULTIMDS:-}" ]; then
		vt_log "setting max_mds=$CEPHTEST_MULTIMDS"
		ceph_cli fs set "$CEPH_FSNAME" max_mds "$CEPHTEST_MULTIMDS" >/dev/null 2>&1 \
			|| vt_warn "could not set max_mds"
	fi
	CEPH_FSID=$(ceph_cli fsid 2>/dev/null | tr -d ' \n')
	[ -n "$CEPH_FSID" ] || vt_warn "could not determine cluster fsid"
	vt_log "cluster up: fs='$CEPH_FSNAME' fsid=$CEPH_FSID"
}

ceph_stop_cluster() {
	vt_log "stopping cluster"
	# No ceph.conf means vstart died early -- skip stop.sh but still reap any
	# daemons it managed to spawn (the pkill sweep below).
	[ -r "$CEPH_CONF" ] && (
		cd "$CEPH_BUILD_DIR" 2>/dev/null || exit 0
		VSTART_DEST="$CEPH_WORK" CEPH_BIN="$CEPH_BIN" CEPH_LIB="$CEPH_LIB" \
			timeout 120 "$CEPH_SRC_DIR/stop.sh" >/dev/null 2>&1
	) || true
	local d
	for d in ceph-mon ceph-osd ceph-mds ceph-mgr; do
		pkill -9 -x "$d" 2>/dev/null || true
	done
}

# Wait for a filesystem with at least one ACTIVE MDS. Sets CEPH_FSNAME.
ceph_wait_fs() {
	local i name
	for i in $(seq 1 "${CEPHTEST_FS_TIMEOUT:-120}"); do
		name=$(ceph_cli fs ls 2>/dev/null | sed -n 's/^name: \([^,]*\),.*/\1/p' | head -1)
		if [ -n "$name" ] && ceph_cli fs status "$name" 2>/dev/null | grep -q active; then
			CEPH_FSNAME="$name"
			vt_log "filesystem '$name' active after ${i}s"
			return 0
		fi
		sleep 1
	done
	ceph_cli -s >&2 2>/dev/null || true
	vt_die "no active CephFS after ${CEPHTEST_FS_TIMEOUT:-120}s"
}

# Wait for the fs to be active again (after a failover). Does not vt_die.
ceph_wait_fs_active() {
	local i timeout="${1:-120}"
	for i in $(seq 1 "$timeout"); do
		ceph_cli fs status "$CEPH_FSNAME" 2>/dev/null | grep -q active && return 0
		sleep 1
	done
	return 1
}

# ----------------------------------------------------------------------
# Mounting
# ----------------------------------------------------------------------

# vstart writes:  mon host = [v2:127.0.0.1:40000/0,v1:127.0.0.1:40001/0]
ceph_mon_v1() {
	local a; a=$(grep -oE 'v1:[0-9.]+:[0-9]+' "$CEPH_CONF" | head -1 | sed 's/^v1://')
	[ -n "$a" ] || a="127.0.0.1:$(( ${CEPHTEST_PORT:-40000} + 1 ))"
	echo "$a"
}
ceph_mon_v2() {
	local a; a=$(grep -oE 'v2:[0-9.]+:[0-9]+' "$CEPH_CONF" | head -1 | sed 's/^v2://')
	[ -n "$a" ] || a="127.0.0.1:${CEPHTEST_PORT:-40000}"
	echo "$a"
}

ceph_key() { ceph_cli auth get-key "client.${1:-admin}" 2>/dev/null; }

# ceph_mount <mountpoint> [user] [extra-opts] [subdir]
#
# Uses `mount -i` deliberately: /sbin/mount.ceph insists on /etc/ceph/ceph.conf
# and falls back to DNS SRV discovery when it is missing, which fails against a
# vstart cluster -- and the helper is not what a kernel test is exercising.
ceph_mount() {
	local mnt="$1" user="${2:-admin}" extra="${3:-}" subdir="${4:-/}"
	local key opts
	key=$(ceph_key "$user") || return 1
	[ -n "$key" ] || { vt_warn "no cephx key for client.$user"; return 1; }
	opts="name=$user,secret=$key"
	[ -n "$extra" ] && opts="$opts,$extra"

	ceph_prepare_mnt "$mnt" \
		|| { vt_warn "cannot prepare mountpoint $mnt (stale mount? read-only parent?)"; return 1; }
	mount -i -t ceph "$(ceph_mon_v1):$subdir" "$mnt" -o "$opts" || return 1
	vt_atexit "umount -l '$mnt' 2>/dev/null"
	return 0
}

# Same, but via the new device syntax over msgr2 (name@fsid.fsname=/path).
ceph_mount_v2() {
	local mnt="$1" user="${2:-admin}" extra="${3:-}" subdir="${4:-/}"
	local key opts
	key=$(ceph_key "$user") || return 1
	[ -n "$key" ] || { vt_warn "no cephx key for client.$user"; return 1; }
	# Without these the device string degrades to "admin@.=/" and the mount
	# fails -- a cluster problem that would be misreported as a kernel one.
	[ -n "$CEPH_FSID" ]   || { vt_warn "no cluster fsid known"; return 1; }
	[ -n "$CEPH_FSNAME" ] || { vt_warn "no filesystem name known"; return 1; }
	opts="mon_addr=$(ceph_mon_v2),secret=$key,ms_mode=${CEPHTEST_MS_MODE:-crc}"
	[ -n "$extra" ] && opts="$opts,$extra"
	ceph_prepare_mnt "$mnt" || return 1
	mount -i -t ceph "$user@$CEPH_FSID.$CEPH_FSNAME=$subdir" "$mnt" -o "$opts" || return 1
	vt_atexit "umount -l '$mnt' 2>/dev/null"
	return 0
}

ceph_umount() {
	local mnt="$1"
	mountpoint -q "$mnt" || return 0
	umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
}

# A distinct mountpoint per caller. Sharing one path across cases lets a
# broken mount poison later cases: an evicted/blocklisted client cannot be
# unmounted normally, so ceph_umount falls back to `umount -l`, and every
# syscall on the leftover stale mount (mkdir/stat included) returns EACCES.
ceph_mnt_for() { echo "/var/tmp/ceph-mnt-$1"; }

# Make sure <dir> exists and is usable as a mountpoint, clearing any stale
# mount left behind by a previous case.
ceph_prepare_mnt() {
	local mnt="$1"
	# A blocklisted CephFS mount fails EVERY syscall with EACCES, stat(2)
	# included -- so `stat`/`[ -e ]`/`mountpoint` all fail and cannot be used
	# to detect it. Consult the mount table instead, which needs no stat.
	if grep -qF " $mnt " /proc/self/mounts 2>/dev/null; then
		if ! stat "$mnt" >/dev/null 2>&1; then
			umount -f "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
		else
			ceph_umount "$mnt"
		fi
	fi
	mkdir -p "$mnt" 2>/dev/null || return 1
	stat "$mnt" >/dev/null 2>&1 || return 1
	return 0
}

# Create an extra cephx identity. Two mounts with identical options share one
# struct ceph_client (there is no 'noshare' option any more), so a genuinely
# independent second client must authenticate as a different user.
ceph_add_client() {
	local user="$1"
	ceph_cli auth get-or-create "client.$user" \
		mon 'allow r' mds 'allow rw' osd 'allow rw' >/dev/null 2>&1
}

# ----------------------------------------------------------------------
# Feature probing -- so a suite runs green on kernels without a given patch
# ----------------------------------------------------------------------

# ceph_kmount_supports <mount-option>
# Mounts a scratch mountpoint with the option and reports whether it worked.
ceph_kmount_supports() {
	local opt="$1" probe=/var/tmp/.ceph-probe rc=1
	mkdir -p "$probe" 2>/dev/null || return 1
	if ceph_mount "$probe" admin "$opt" >/dev/null 2>&1; then
		rc=0
		ceph_umount "$probe"
	fi
	rmdir "$probe" 2>/dev/null || true
	return $rc
}

# ----------------------------------------------------------------------
# Kernel state
# ----------------------------------------------------------------------

CEPH_LOCKDEP_STATE=unknown

ceph_lockdep_start() {
	if [ -r /proc/lockdep_stats ]; then
		CEPH_LOCKDEP_STATE=yes
		vt_log "lockdep active: $(awk '/lock-classes|direct dependencies/{printf "%s ", $0}' /proc/lockdep_stats | tr -s ' ')"
		if grep -qi "debug_locks: *0" /proc/lockdep_stats 2>/dev/null; then
			vt_warn "lockdep was ALREADY disabled before the test started"
			CEPH_LOCKDEP_STATE=disabled
		fi
	else
		CEPH_LOCKDEP_STATE=no
		vt_warn "lockdep not compiled in -- a clean run does NOT validate locking"
	fi
}

# Patterns are deliberately specific: a bare "lockdep" would match the
# validator's own benign boot chatter and fail every run.
CEPH_DMESG_PATTERNS=(
	"BUG:"
	"Oops"
	"general protection fault"
	"kernel NULL pointer dereference"
	"Unable to handle kernel"
	"WARNING: CPU:"
	"possible circular locking dependency"
	"INFO: possible recursive locking"
	"possible irq lock inversion dependency"
	"INFO: trying to register non-static key"
	"DEBUG_LOCKS_WARN_ON"
	"suspicious RCU usage"
	"held lock freed"
	"INFO: task .* blocked for more than"
	"KASAN:"
	"KFENCE:"
	"UBSAN:"
	"refcount_t:"
	"list_add corruption"
	"list_del corruption"
)

# ceph_save_artifacts [name] -- copy logs somewhere that survives VM shutdown
ceph_save_artifacts() {
	local out="${VMTEST_DATA_DIR:-/tmp}/${1:-cephfs}"
	mkdir -p "$out"
	dmesg > "$out/dmesg.log" 2>/dev/null || true
	cp "$CEPH_WORK/vstart.log" "$out/vstart.log" 2>/dev/null || true
	tar -czf "$out/ceph-logs.tar.gz" -C "$CEPH_WORK" out 2>/dev/null || true
	echo "$out"
}

# ceph_check_dmesg <artifact-dir> -- 0 = clean, 1 = complaints found
ceph_check_dmesg() {
	local out="$1" re
	re="$(IFS='|'; echo "${CEPH_DMESG_PATTERNS[*]}")"
	if dmesg | grep -qE -- "$re"; then
		dmesg | grep -nE -- "$re" -A 40 > "$out/splats.log" 2>/dev/null || true
		vt_log "kernel complaints found -- full detail in $out/splats.log:"
		head -200 "$out/splats.log" >&2
		return 1
	fi
	# Lockdep is one-shot per boot: the first splat sets debug_locks=0 and the
	# validator goes quiet, so later cases would run unchecked. Catch that even
	# if no message matched our patterns.
	if [ "$CEPH_LOCKDEP_STATE" = yes ] \
	   && grep -qi "debug_locks: *0" /proc/lockdep_stats 2>/dev/null; then
		vt_warn "lockdep DISABLED ITSELF during the run -- see $out/dmesg.log"
		return 1
	fi
	vt_log "dmesg clean (lockdep=$CEPH_LOCKDEP_STATE)"
	return 0
}

# ----------------------------------------------------------------------
# Result bookkeeping
# ----------------------------------------------------------------------

PASSED=0; FAILED=0; SKIPPED=0
RESULTS=""

note_fail() { vt_warn "  FAIL: $*"; CASE_FAILED=1; }
note_skip() { vt_log  "  SKIP: $*"; CASE_SKIPPED="$*"; }

record() {
	local name="$1" state="$2" secs="$3" detail="${4:-}"
	RESULTS="${RESULTS}$(printf '%-11s %-5s %5ss %s' "$name" "$state" "$secs" "$detail")
"
}

run_case() {
	local name="$1" fn="case_$1" t0 secs
	if ! declare -F "$fn" >/dev/null; then
		vt_die "unknown case '$name' (valid: $ALL_CASES)"
	fi
	vt_log "== case: $name =="
	CASE_FAILED=0; CASE_SKIPPED=""
	t0=$SECONDS
	"$fn" || CASE_FAILED=1
	# Every case must leave the primary mount up. A case that returns early
	# after unmounting it would otherwise let all later cases run against a
	# plain directory on the guest overlay and report PASS against something
	# that is not CephFS at all.
	if ! mountpoint -q "$CEPH_MNT" 2>/dev/null; then
		vt_warn "  case '$name' left the primary mount down; restoring"
		CASE_FAILED=1
		ceph_mount "$CEPH_MNT" admin \
			|| vt_die "cannot restore primary mount after '$name'"
	fi
	secs=$((SECONDS - t0))
	# Order matters: a case that both failed and skipped is a FAILURE.
	# Checking skip first would hide a real data-mismatch behind "skipped".
	if [ "$CASE_FAILED" != 0 ]; then
		FAILED=$((FAILED + 1)); record "$name" FAIL "$secs"
	elif [ -n "$CASE_SKIPPED" ]; then
		SKIPPED=$((SKIPPED + 1)); record "$name" SKIP "$secs" "$CASE_SKIPPED"
	else
		PASSED=$((PASSED + 1)); record "$name" PASS "$secs"
	fi
}

# Scratch dir per case, always cleaned up so cases stay independent.
case_dir() {
	local d="$CEPH_MNT/$1"
	rm -rf "$d" 2>/dev/null || true
	mkdir -p "$d"
	echo "$d"
}

# ----------------------------------------------------------------------
# Cases
# ----------------------------------------------------------------------

case_mount() {
	# The primary mount is already up; exercise the other ways in.
	ceph_umount "$CEPH_MNT"

	# legacy v1 device syntax
	ceph_mount "$CEPH_MNT" admin \
		|| { note_fail "v1 legacy mount failed"; return 1; }
	vt_log "  v1 legacy mount OK"
	ceph_umount "$CEPH_MNT"

	# new device syntax over msgr2
	if ceph_mount_v2 "$CEPH_MNT" admin; then
		vt_log "  v2 (name@fsid.fs=/) mount OK"
		ceph_umount "$CEPH_MNT"
	else
		note_fail "msgr2 new-syntax mount failed"
	fi

	# read-only mount
	if ceph_mount "$CEPH_MNT" admin "ro"; then
		if touch "$CEPH_MNT/should_fail" 2>/dev/null; then
			note_fail "ro mount allowed a write"
			rm -f "$CEPH_MNT/should_fail" 2>/dev/null || true
		else
			vt_log "  ro mount correctly rejects writes"
		fi
		ceph_umount "$CEPH_MNT"
	else
		note_fail "ro mount failed"
	fi

	# subdirectory mount
	ceph_mount "$CEPH_MNT" admin || { note_fail "remount for subdir setup failed"; return 1; }
	mkdir -p "$CEPH_MNT/subdirtest"
	echo hello > "$CEPH_MNT/subdirtest/marker"
	ceph_umount "$CEPH_MNT"
	if ceph_mount "$CEPH_MNT" admin "" "/subdirtest"; then
		[ "$(cat "$CEPH_MNT/marker" 2>/dev/null)" = hello ] \
			|| note_fail "subdir mount does not show the expected content"
		vt_log "  subdir mount OK"
		ceph_umount "$CEPH_MNT"
	else
		note_fail "subdir mount failed"
	fi

	# restore the shared mount for the remaining cases
	ceph_mount "$CEPH_MNT" admin || vt_die "cannot restore primary mount"
	rm -rf "$CEPH_MNT/subdirtest"
}

case_basic() {
	local d; d=$(case_dir basic)

	# buffered write, verify after dropping the page cache.
	# drop_caches only frees CLEAN pages, so without the sync the re-read is
	# served from the very cache that produced s1 and the OSD round trip is
	# never exercised.
	dd if=/dev/urandom of="$d/f1" bs=1M count=32 status=none \
		|| { note_fail "buffered write failed"; return 1; }
	local s1 s2
	s1=$(md5sum < "$d/f1")
	[ -n "$s1" ] || { note_fail "could not checksum f1"; return 1; }
	sync
	echo 3 > /proc/sys/vm/drop_caches
	s2=$(md5sum < "$d/f1")
	[ "$s1" = "$s2" ] || note_fail "data mismatch after cache drop"

	# O_DIRECT round trip
	dd if=/dev/urandom of="$d/f2" bs=4M count=4 oflag=direct status=none \
		|| note_fail "O_DIRECT write failed"
	dd if="$d/f2" of=/dev/null bs=4M iflag=direct status=none \
		|| note_fail "O_DIRECT read failed"

	# mmap read/write
	python3 - "$d/f3" <<-'PY' || note_fail "mmap IO failed"
	import mmap, sys, os
	p = sys.argv[1]
	data = bytes(range(256)) * 4096          # 1 MiB
	with open(p, "wb") as f:
	    f.write(data); f.flush(); os.fsync(f.fileno())
	with open(p, "r+b") as f:
	    m = mmap.mmap(f.fileno(), len(data))
	    assert m[:256] == data[:256], "mmap read mismatch"
	    m[0:4] = b"ABCD"
	    m.flush(); m.close()
	with open(p, "rb") as f:
	    assert f.read(4) == b"ABCD", "mmap write not visible"
	PY

	# sparse file + truncate
	dd if=/dev/zero of="$d/f4" bs=1M count=1 conv=fsync status=none
	truncate -s 8M "$d/f4"
	[ "$(stat -c %s "$d/f4")" = $((8*1024*1024)) ] || note_fail "truncate size wrong"
	truncate -s 0 "$d/f4"
	[ "$(stat -c %s "$d/f4")" = 0 ] || note_fail "truncate to zero failed"

	# fallocate (optional: not all kernels/backends support it on cephfs)
	if fallocate -l 1M "$d/f5" 2>/dev/null; then
		[ "$(stat -c %s "$d/f5")" = $((1024*1024)) ] || note_fail "fallocate size wrong"
	else
		vt_log "  (fallocate unsupported here -- check skipped)"
	fi

	# append + fsync durability within the same mount
	for i in $(seq 1 20); do echo "line$i" >> "$d/f6"; done
	sync
	[ "$(wc -l < "$d/f6")" = 20 ] || note_fail "append lost data"

	rm -rf "$d"
}

case_meta() {
	local d; d=$(case_dir meta)

	mkdir -p "$d/sub/dir"
	: > "$d/file"
	ln "$d/file" "$d/hard"
	[ "$(stat -c %h "$d/file")" = 2 ] || note_fail "hardlink count wrong"
	ln -s ../file "$d/sub/sym"
	[ "$(readlink "$d/sub/sym")" = "../file" ] || note_fail "symlink target wrong"

	mv "$d/file" "$d/renamed"
	[ -f "$d/renamed" ] || note_fail "rename lost the file"
	# cross-directory rename
	mv "$d/renamed" "$d/sub/dir/moved"
	[ -f "$d/sub/dir/moved" ] || note_fail "cross-dir rename failed"

	# permissions and ownership
	chmod 0640 "$d/sub/dir/moved"
	[ "$(stat -c %a "$d/sub/dir/moved")" = 640 ] || note_fail "chmod not reflected"
	chown 1000:1000 "$d/sub/dir/moved" 2>/dev/null \
		&& { [ "$(stat -c %u:%g "$d/sub/dir/moved")" = "1000:1000" ] \
			|| note_fail "chown not reflected"; }

	# xattrs (user namespace + ceph's own virtual xattrs)
	# 2>/dev/null hides "command not found" exactly like "not supported", so
	# say which happened rather than letting the check vanish behind a PASS.
	if ! command -v setfattr >/dev/null 2>&1; then
		vt_log "  (setfattr not installed -- xattr check skipped)"
	elif setfattr -n user.test -v hello "$d/sub/dir/moved" 2>/dev/null; then
		[ "$(getfattr --only-values -n user.test "$d/sub/dir/moved" 2>/dev/null)" = hello ] \
			|| note_fail "user xattr round trip failed"
		setfattr -x user.test "$d/sub/dir/moved" 2>/dev/null || true
	else
		note_fail "setfattr present but the xattr set failed"
	fi
	getfattr -n ceph.dir.entries "$d" >/dev/null 2>&1 \
		|| vt_log "  (ceph.* virtual xattrs unavailable)"

	# unlink-while-open must keep the fd valid (POSIX)
	python3 - "$d" <<-'PY' || note_fail "unlink-while-open semantics broken"
	import os, sys
	p = os.path.join(sys.argv[1], "openunlink")
	fd = os.open(p, os.O_CREAT | os.O_RDWR, 0o644)
	os.write(fd, b"payload")
	os.unlink(p)
	os.lseek(fd, 0, os.SEEK_SET)
	assert os.read(fd, 7) == b"payload", "read after unlink failed"
	os.close(fd)
	PY

	# rmdir must refuse a non-empty directory
	rmdir "$d/sub" 2>/dev/null && note_fail "rmdir removed a non-empty dir"

	rm -rf "$d"
	[ -d "$d" ] && note_fail "rm -rf left the tree behind"
	return 0
}

case_readdir() {
	local d; d=$(case_dir readdir)
	vt_log "  populating $CEPHTEST_READDIR_N entries"
	python3 - "$d" "$CEPHTEST_READDIR_N" <<-'PY'
	import os, sys
	d, n = sys.argv[1], int(sys.argv[2])
	for i in range(n):
	    os.close(os.open(os.path.join(d, "entry_%06d" % i), os.O_CREAT | os.O_WRONLY, 0o644))
	PY

	# concurrent submitters, so a large reply decode has to compete with
	# ongoing request submission rather than running on an idle client
	local noise; noise=$(case_dir readdir_noise)
	(
		end=$((SECONDS + 30)); i=0
		while [ $SECONDS -lt $end ]; do
			i=$((i+1)); : > "$noise/n$i"; stat "$noise/n$i" >/dev/null; rm -f "$noise/n$i"
		done
	) &
	local noise_pid=$!

	local t0 n
	# ls -f: raw unsorted readdir is what is being timed; names are fixed entry_N.
	t0=$SECONDS
	# shellcheck disable=SC2010
	n=$(ls -f "$d" | grep -c '^entry_'); vt_log "  warm list: $n in $((SECONDS-t0))s"
	[ "$n" = "$CEPHTEST_READDIR_N" ] || note_fail "warm readdir returned $n entries"

	echo 3 > /proc/sys/vm/drop_caches
	t0=$SECONDS
	# shellcheck disable=SC2010
	n=$(ls -f "$d" | grep -c '^entry_'); vt_log "  cold list: $n in $((SECONDS-t0))s"
	[ "$n" = "$CEPHTEST_READDIR_N" ] || note_fail "cold readdir returned $n entries"

	# rewinddir/seekdir consistency
	python3 - "$d" "$CEPHTEST_READDIR_N" <<-'PY' || note_fail "readdir iteration inconsistent"
	import os, sys
	d, n = sys.argv[1], int(sys.argv[2])
	a = sorted(x for x in os.listdir(d) if x.startswith("entry_"))
	b = sorted(x for x in os.listdir(d) if x.startswith("entry_"))
	assert a == b, "two listdir passes disagree"
	assert len(a) == n, "listdir saw %d of %d" % (len(a), n)
	PY

	kill $noise_pid 2>/dev/null || true; wait $noise_pid 2>/dev/null || true
	rm -rf "$d" "$noise"
}

case_coherency() {
	local m2; m2=$(ceph_mnt_for coherency)
	ceph_add_client test || { note_skip "cannot create second cephx client"; return 0; }
	if ! ceph_mount "$m2" test; then
		note_fail "second client mount failed"
		return 1
	fi
	local a b
	a=$(case_dir coherency); b="$m2/coherency"

	# writes on client A must become visible on client B
	echo "from-A" > "$a/f"
	sync
	local seen=""
	for i in $(seq 1 30); do
		seen=$(cat "$b/f" 2>/dev/null || true)
		[ "$seen" = "from-A" ] && break
		sleep 1
	done
	[ "$seen" = "from-A" ] || note_fail "client B never saw client A's write (got '$seen')"

	# and the reverse direction
	echo "from-B" > "$b/g"
	sync
	seen=""
	for i in $(seq 1 30); do
		seen=$(cat "$a/g" 2>/dev/null || true)
		[ "$seen" = "from-B" ] && break
		sleep 1
	done
	[ "$seen" = "from-B" ] || note_fail "client A never saw client B's write (got '$seen')"

	# directory operations must be visible too
	mkdir "$a/dir-from-A"
	for i in $(seq 1 30); do [ -d "$b/dir-from-A" ] && break; sleep 1; done
	[ -d "$b/dir-from-A" ] || note_fail "mkdir not visible on the other client"

	rm -rf "$a"
	ceph_umount "$m2"
}

case_stress() {
	local d; d=$(case_dir stress)
	vt_log "  $CEPHTEST_STRESS_PROCS procs x $CEPHTEST_STRESS_OPS ops"
	# Concurrent metadata traffic from many tasks: every operation is a
	# separate MDS request, keeping submit and reply paths busy at once.
	local pids=() i
	for i in $(seq 1 "$CEPHTEST_STRESS_PROCS"); do
		(
			set -e
			w="$d/w$i"; mkdir -p "$w"
			for j in $(seq 1 "$CEPHTEST_STRESS_OPS"); do
				: > "$w/f$j"
				stat "$w/f$j" >/dev/null
				setfattr -n user.t -v "$j" "$w/f$j" 2>/dev/null || true
				mv "$w/f$j" "$w/g$j"
				ln "$w/g$j" "$w/h$j" 2>/dev/null || true
				rm -f "$w/h$j" "$w/g$j"
			done
			# a little data traffic alongside the metadata storm
			dd if=/dev/zero of="$w/data" bs=64k count=16 status=none
			rm -rf "$w"
		) &
		pids+=($!)
	done
	local rc=0
	for i in "${pids[@]}"; do wait "$i" || rc=1; done
	[ "$rc" = 0 ] || note_fail "a stress worker reported an error"

	local left; left=$(find "$d" -mindepth 1 2>/dev/null | wc -l)
	[ "$left" = 0 ] || note_fail "$left entries left behind"
	rm -rf "$d"
}

case_snapshot() {
	local d; d=$(case_dir snapshot)
	echo original > "$d/f"
	sync
	if ! mkdir "$d/.snap/snap1" 2>/dev/null; then
		note_skip "snapshots not enabled on this filesystem"
		rm -rf "$d"; return 0
	fi
	echo modified > "$d/f"
	sync
	[ "$(cat "$d/.snap/snap1/f" 2>/dev/null)" = original ] \
		|| note_fail "snapshot does not preserve the original content"
	[ "$(cat "$d/f")" = modified ] || note_fail "live file content wrong"
	# Checks the .snap readdir listing, not a lookup, so a plain [ -d ] would not do.
	# shellcheck disable=SC2010
	ls "$d/.snap" | grep -q snap1 || note_fail "snapshot not listed in .snap"
	rmdir "$d/.snap/snap1" || note_fail "cannot remove snapshot"
	rm -rf "$d"
}

case_failover() {
	local d; d=$(case_dir failover)
	# Keep requests in flight (some of them unsafe/uncommitted) across the
	# failover, so the client has real work to replay on reconnect.
	(
		i=0
		while :; do
			i=$((i+1))
			: > "$d/f$i" 2>/dev/null || true
			mv "$d/f$i" "$d/r$i" 2>/dev/null || true
			rm -f "$d/r$i" 2>/dev/null || true
		done
	) &
	local load_pid=$!
	# guarded: the pid is reaped below, and a bare kill from the trap could
	# signal an unrelated process if the pid has been recycled by then
	vt_atexit "kill -0 $load_pid 2>/dev/null && kill $load_pid 2>/dev/null"
	sleep 3

	vt_log "  failing the active MDS"
	ceph_cli mds fail 0 >/dev/null 2>&1 || vt_warn "  'mds fail 0' returned non-zero"

	if ceph_wait_fs_active 120; then
		vt_log "  MDS active again"
	else
		note_fail "MDS did not become active again within 120s"
	fi

	kill $load_pid 2>/dev/null || true; wait $load_pid 2>/dev/null || true

	if timeout 120 bash -c ": > '$d/after' && stat '$d/after' >/dev/null && rm -f '$d/after'"; then
		vt_log "  mount functional after reconnect"
	else
		note_fail "mount unusable after MDS reconnect"
	fi
	rm -rf "$d" 2>/dev/null || true
}

case_evict() {
	local m2; m2=$(ceph_mnt_for evict)
	ceph_add_client evictme || { note_skip "cannot create cephx client"; return 0; }
	if ! ceph_mount "$m2" evictme; then
		note_fail "victim client mount failed"
		return 1
	fi
	# An evicted client cannot be unmounted normally, so its mountpoint is
	# left stale; keep it private to this case and tear it down explicitly.
	echo data > "$m2/evict-marker" 2>/dev/null || true
	sync

	# Find the victim's session id and evict it. This drives the session
	# teardown path (cleanup_session_requests) rather than a clean umount.
	local id
	id=$(ceph_cli tell "mds.0" session ls 2>/dev/null \
		| python3 -c 'import json,sys
try:
    for s in json.load(sys.stdin):
        if s.get("client_metadata",{}).get("entity_id") == "evictme":
            print(s["id"]); break
except Exception:
    pass' 2>/dev/null)
	if [ -z "$id" ]; then
		note_skip "could not find the victim MDS session"
		ceph_umount "$m2"; return 0
	fi
	vt_log "  evicting session $id"
	ceph_cli tell "mds.0" session evict id="$id" >/dev/null 2>&1 \
		|| vt_warn "  session evict returned non-zero"
	sleep 5

	# The evicted mount is expected to be broken; what must survive is the
	# other client and the kernel itself.
	ls "$CEPH_MNT" >/dev/null 2>&1 || note_fail "surviving client broke after peer eviction"
	umount -f "$m2" 2>/dev/null || umount -l "$m2" 2>/dev/null || true
	rmdir "$m2" 2>/dev/null || true
	rm -f "$CEPH_MNT/evict-marker" 2>/dev/null || true
}

case_fsstress() {
	local bin=""
	for c in fsstress /usr/lib/xfstests/ltp/fsstress /usr/local/lib/xfstests/ltp/fsstress; do
		command -v "$c" >/dev/null 2>&1 && { bin="$c"; break; }
		[ -x "$c" ] && { bin="$c"; break; }
	done
	if [ -z "$bin" ]; then
		note_skip "fsstress not installed"
		return 0
	fi
	local d; d=$(case_dir fsstress)
	vt_log "  running fsstress ($bin)"
	"$bin" -d "$d" -n "${CEPHTEST_FSSTRESS_OPS:-2000}" -p 4 >/dev/null 2>&1 \
		|| note_fail "fsstress reported an error"
	rm -rf "$d"
}

case_lazyio() {
	# Probed, not assumed: mainline has no 'lazyio' mount option, so this case
	# must SKIP rather than fail when testing a kernel without that patch.
	if ! ceph_kmount_supports lazyio; then
		note_skip "kernel does not support the 'lazyio' mount option"
		return 0
	fi
	ceph_umount "$CEPH_MNT"
	ceph_mount "$CEPH_MNT" admin lazyio || { note_fail "mount -o lazyio failed"; \
		ceph_mount "$CEPH_MNT" admin; return 1; }

	grep -E " $CEPH_MNT " /proc/mounts | grep -q lazyio \
		|| note_fail "lazyio not reported in /proc/mounts"

	local d; d=$(case_dir lazyio)
	dd if=/dev/urandom of="$d/f1" bs=1M count=16 status=none \
		|| { note_fail "lazyio write failed"; return 1; }
	local s1 s2
	s1=$(md5sum < "$d/f1")
	[ -n "$s1" ] || { note_fail "could not checksum lazyio f1"; return 1; }
	sync
	echo 3 > /proc/sys/vm/drop_caches
	s2=$(md5sum < "$d/f1")
	[ "$s1" = "$s2" ] || note_fail "data mismatch under lazyio"

	# Two independent clients writing the same file: the case LazyIO exists
	# for, since without it the MDS revokes buffered caps from both.
	local m2; m2=$(ceph_mnt_for lazyio)
	if ! ceph_add_client lazy2; then
		note_skip "cannot create second cephx client for the shared-write check"
	elif ceph_mount "$m2" lazy2 lazyio; then
		local shared="$d/shared"
		dd if=/dev/zero of="$shared" bs=1M count=4 status=none; sync
		dd if=/dev/urandom of="$shared" bs=4k count=256 conv=notrunc status=none &
		local p1=$!
		dd if=/dev/urandom of="$m2/${d##*/}/shared" bs=4k count=256 seek=256 \
			conv=notrunc status=none &
		local p2=$!
		wait $p1 || note_fail "lazyio writer 1 failed"
		wait $p2 || note_fail "lazyio writer 2 failed"
		sync
		[ -s "$shared" ] || note_fail "shared file empty after two writers"
		vt_log "  two-client shared write OK"
		ceph_umount "$m2"
	else
		# Silently downgrading this to a log line once hid the loss of the
		# most valuable part of the case behind an overall PASS.
		note_fail "second lazyio client could not mount -- shared-write check did NOT run"
	fi

	# NOTE: 'mount -o remount' is NOT tested here. Every cephfs remount fails
	# on current kernels -- show_options() prints secret=<hidden>, util-linux
	# feeds that back on remount, and Opt_secret cannot parse it (-EINVAL).
	# That is a pre-existing kclient bug, unrelated to lazyio.

	rm -rf "$d"
	ceph_umount "$CEPH_MNT"
	ceph_mount "$CEPH_MNT" admin || vt_die "cannot restore primary mount"
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

vt_require_cmd python3 mkfs.ext4 mount umount
vt_require_module ceph

vt_dmesg_clear
vt_log "kernel: $(uname -r)"
vt_log "cases:  $CASES"
ceph_lockdep_start

ceph_require_build
ceph_setup_backing
ceph_start_cluster

# Save artifacts from the EXIT trap as well, so a mid-run vt_die (cluster
# bring-up failure, unrestorable mount, ...) still leaves dmesg and the ceph
# logs on the host -- those paths are exactly when they are most needed.
# Registered after ceph_start_cluster so LIFO runs it BEFORE the daemons stop
# and their logs are still complete.
vt_atexit "ceph_save_artifacts '$ARTIFACT_NAME' >/dev/null 2>&1 || true"

ceph_mount "$CEPH_MNT" admin || vt_die "initial CephFS mount failed"
vt_log "mounted $(ceph_mon_v1):/ on $CEPH_MNT"

for c in $CASES; do
	run_case "$c"
done

# Unmount while the cluster is still alive: tearing the MDS down under a live
# mount would mask teardown bugs behind an unavoidable lazy umount.
# Hold BEFORE tearing anything down: post-mortem inspection is precisely when
# the mount and the cluster need to still be there.
vt_hold

ceph_umount "$CEPH_MNT"

OUT=$(ceph_save_artifacts "$ARTIFACT_NAME")
vt_log "artifacts: $OUT/"
DMESG_OK=0
ceph_check_dmesg "$OUT" || DMESG_OK=1

echo "" >&2
echo "===== cephfs_kclient summary =====" >&2
printf '%s' "$RESULTS" >&2
printf 'passed=%d failed=%d skipped=%d  lockdep=%s  dmesg=%s\n' \
	"$PASSED" "$FAILED" "$SKIPPED" "$CEPH_LOCKDEP_STATE" \
	"$([ "$DMESG_OK" = 0 ] && echo clean || echo COMPLAINTS)" >&2
echo "==================================" >&2

[ "$DMESG_OK" = 0 ] || vt_die "kernel reported errors/warnings (see $OUT/splats.log)"
[ "$FAILED" = 0 ] || vt_die "$FAILED case(s) failed"
[ "$PASSED" -gt 0 ] || vt_skip "no case actually executed ($SKIPPED skipped)"
vt_pass "cephfs_kclient: $PASSED passed, $SKIPPED skipped"
