#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: Run the io500 benchmark against CephFS mounted with lazyio, report the score
# vmtest-requires: root ceph-build io500 mpi
#
# Brings up a vstart Ceph cluster INSIDE the guest (server and client in the
# same VM), mounts CephFS with the kernel client using -o lazyio, runs the
# io500 benchmark on it, and prints the resulting score.
#
# The default profile is the MINIMUM-TIME one: stonewall-time=1s, so each
# phase stops after roughly a second. io500 marks such a run [INVALID] because
# a submittable result needs stonewall-time=300 -- that is expected and
# correct here. The number is for exercising the client and for relative
# comparison between kernels, NOT for submission to the io500 list.
#
# Config (vmtest.conf -- host environment is NOT forwarded into the guest):
#   CEPH_BUILD_DIR="/home/ming/git/ceph/ceph/build"   required
#   IO500_DIR="/home/ming/git/ceph/io500"             default shown
#   VMTEST_QEMU_EXTRA="-drive file=$VMTEST_DATA_DIR/ceph.img,format=raw,if=none,id=ceph_drv -device nvme,drive=ceph_drv,serial=cephtest"
#
# Knobs (vmtest.conf):
#   CEPHTEST_IO500_STONEWALL   seconds per phase (default 1; 300 = submittable)
#   CEPHTEST_IO500_NP          MPI ranks (default 2)
#   CEPHTEST_IO500_LAZYIO      1 = require lazyio (default), 0 = plain mount
#   CEPHTEST_IO500_DROPCACHES  TRUE/FALSE (default FALSE; TRUE is slower but
#                              makes the read phases hit the OSDs)
#   CEPHTEST_IO500_EXTRA_INI   extra lines appended to the generated [global]
#   plus the cluster knobs shared with cephfs_kclient.sh (CEPHTEST_OSD, ...)
#
# io500 must be built first, on the HOST (it needs network + MPI):
#   sudo dnf install -y mpich-devel          # or openmpi-devel
#   export PATH=/usr/lib64/mpich/bin:$PATH
#   cd ~/git/ceph/io500 && ./prepare.sh
#
# Usage:
#   vmtest -c <conf> run cephfs_io500
set -eu

. "$(dirname "$0")/../lib/common.sh"

vt_load_config
vt_require_root
vt_install_trap

IO500_DIR="${IO500_DIR:-/home/ming/git/ceph/io500}"
IO500_STONEWALL="${CEPHTEST_IO500_STONEWALL:-1}"
IO500_NP="${CEPHTEST_IO500_NP:-2}"
IO500_LAZYIO="${CEPHTEST_IO500_LAZYIO:-1}"
IO500_DROPCACHES="${CEPHTEST_IO500_DROPCACHES:-FALSE}"
ARTIFACT_NAME="${CEPHTEST_ARTIFACTS:-cephfs_io500}"

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
# io500 / MPI discovery
# ----------------------------------------------------------------------

MPIEXEC=""
MPI_EXTRA=()

# Fedora keeps the MPI launchers out of the default PATH (one directory per
# implementation), so look there as well as in $PATH.
find_mpiexec() {
	local c
	for c in "${MPIEXEC_BIN:-}" \
		 /usr/lib64/mpich/bin/mpiexec \
		 /usr/lib64/openmpi/bin/mpiexec \
		 "$(command -v mpiexec 2>/dev/null || true)" \
		 "$(command -v mpirun 2>/dev/null || true)"; do
		[ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
	done
	return 1
}

io500_require() {
	[ -d "$IO500_DIR" ] \
		|| vt_skip "IO500_DIR=$IO500_DIR does not exist (set it in vmtest.conf)"
	[ -x "$IO500_DIR/io500" ] || vt_skip "io500 is not built at $IO500_DIR.
       Build it on the HOST (needs network + MPI):
         sudo dnf install -y mpich-devel
         export PATH=/usr/lib64/mpich/bin:\$PATH
         cd $IO500_DIR && ./prepare.sh"

	MPIEXEC=$(find_mpiexec) \
		|| vt_skip "no mpiexec found (install mpich-devel or openmpi-devel,
       or point MPIEXEC_BIN at the launcher in vmtest.conf)"

	# OpenMPI refuses to run as root unless told otherwise, and everything in
	# this guest is root. MPICH has no such restriction.
	if "$MPIEXEC" --version 2>&1 | grep -qi "open\(-\| \)mpi\|openrte"; then
		MPI_EXTRA=(--allow-run-as-root --oversubscribe)
		vt_log "MPI: OpenMPI detected, adding ${MPI_EXTRA[*]}"
	fi
	vt_log "MPI: $MPIEXEC (np=$IO500_NP)"
	# Fedora's MPI packages live outside the default loader path (they expect
	# `module load`). The io500 binary carries a RUNPATH, but the launcher and
	# anything it spawns may not, so make it explicit.
	local mpilib; mpilib="$(dirname "$(dirname "$MPIEXEC")")/lib"
	[ -d "$mpilib" ] && export LD_LIBRARY_PATH="$mpilib:${LD_LIBRARY_PATH:-}"

	# The io500 binary is dynamically linked against its MPI; if the runtime
	# libs are not resolvable the failure is an unhelpful loader error much
	# later, so surface it now.
	if ldd "$IO500_DIR/io500" 2>/dev/null | grep -q "not found"; then
		vt_log "io500 has unresolved libraries:"
		ldd "$IO500_DIR/io500" 2>/dev/null | grep "not found" | sed 's/^/  /' >&2
		vt_skip "io500 binary has unresolved shared libraries (MPI runtime missing?)"
	fi
}

# ----------------------------------------------------------------------
# Config generation
# ----------------------------------------------------------------------

# io500 reads an ini file; generate one pointing datadir at the CephFS mount
# and resultdir at the local scratch fs (keeping benchmark output off the
# filesystem being measured).
write_io500_ini() {
	local ini="$1" datadir="$2" resultdir="$3"
	cat > "$ini" <<-INI
	[global]
	datadir = $datadir
	resultdir = $resultdir
	timestamp-datadir = FALSE
	timestamp-resultdir = FALSE
	api = POSIX
	drop-caches = $IO500_DROPCACHES
	drop-caches-cmd = bash -c "echo 3 > /proc/sys/vm/drop_caches"
	verbosity = 1
	${CEPHTEST_IO500_EXTRA_INI:-}

	[debug]
	stonewall-time = $IO500_STONEWALL
	INI
	vt_log "io500 config ($ini):"
	sed 's/^/  /' "$ini" >&2
}

# ----------------------------------------------------------------------
# Score reporting
# ----------------------------------------------------------------------

# io500 prints (src/main.c):
#   [SCORE ] Bandwidth %f GiB/s : IOPS %f kiops : TOTAL %f[INVALID]
# The [INVALID] suffix is expected whenever stonewall-time < 300.
report_score() {
	local log="$1" resultdir="$2" score_line

	echo "" >&2
	echo "================ io500 per-phase results ================" >&2
	# io500 prints per-phase lines as "[RESULT] <name> <value> <unit> : time ..."
	# (and "[      ]" for phases that carry no score, e.g. ior-rnd4K).
	grep -aE "^\[(RESULT| +)\]" "$log" 2>/dev/null | sed 's/^/  /' >&2 || true

	echo "" >&2
	echo "======================= io500 SCORE ======================" >&2
	score_line=$(grep -aE "^\[SCORE" "$log" 2>/dev/null | head -2 || true)
	if [ -n "$score_line" ]; then
		printf '%s\n' "$score_line" | sed 's/^/  /' >&2
	else
		echo "  (no [SCORE] line found -- see $log)" >&2
	fi
	echo "=========================================================" >&2
	echo "" >&2

	[ -n "$score_line" ] || return 1

	# Fail on a zero/NaN total: io500 can print a score line even when every
	# phase errored out, and a silent 0.000 would read as a successful run.
	local total
	total=$(printf '%s\n' "$score_line" | sed -n 's/.*TOTAL \([0-9.eE+-]*\).*/\1/p' | head -1)
	case "$total" in
		''|0|0.0|0.00|0.000|0.000000|*[Nn]a[Nn]*)
			vt_warn "io500 TOTAL is '$total' -- no phase produced a usable result"
			return 1 ;;
	esac
	vt_log "io500 TOTAL score: $total"
	[ -r "$resultdir/result_summary.txt" ] \
		&& vt_log "full summary: $resultdir/result_summary.txt"
	return 0
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

vt_require_cmd python3 mkfs.ext4 mount umount
vt_require_module ceph

vt_dmesg_clear
vt_log "kernel: $(uname -r)"
ceph_lockdep_start

ceph_require_build
io500_require
ceph_setup_backing
ceph_start_cluster

vt_atexit "ceph_save_artifacts '$ARTIFACT_NAME' >/dev/null 2>&1 || true"

# Mount with lazyio. It is the point of this test, so an unsupported kernel
# is a SKIP rather than a silent fallback to a different configuration.
MOUNT_OPTS=""
if [ "$IO500_LAZYIO" = 1 ]; then
	if ceph_kmount_supports lazyio; then
		MOUNT_OPTS="lazyio"
		vt_log "mounting with -o lazyio"
	else
		vt_skip "kernel does not support the 'lazyio' mount option
       (set CEPHTEST_IO500_LAZYIO=0 in vmtest.conf to benchmark without it)"
	fi
else
	vt_log "lazyio disabled by config; plain mount"
fi

ceph_mount "$CEPH_MNT" admin "$MOUNT_OPTS" || vt_die "CephFS mount failed"
if [ -n "$MOUNT_OPTS" ]; then
	grep -E " $CEPH_MNT " /proc/mounts | grep -q lazyio \
		|| vt_die "lazyio requested but not present in /proc/mounts"
	vt_log "confirmed lazyio in /proc/mounts"
fi

DATADIR="$CEPH_MNT/io500-data"
RESULTDIR="$CEPH_WORK/io500-results"
INI="$CEPH_WORK/io500-vmtest.ini"
RUNLOG="$CEPH_WORK/io500-run.log"
mkdir -p "$DATADIR" "$RESULTDIR"

write_io500_ini "$INI" "$DATADIR" "$RESULTDIR"

vt_log "running io500 (stonewall=${IO500_STONEWALL}s, np=$IO500_NP) -- this takes a few minutes"
RC=0
# cwd must be writable: io500 drops a few files next to itself. The binary is
# referenced by absolute path so the io500 tree itself stays read-only on 9p.
( cd "$CEPH_WORK" && timeout "${CEPHTEST_IO500_TIMEOUT:-2400}" \
	"$MPIEXEC" "${MPI_EXTRA[@]}" -np "$IO500_NP" \
	"$IO500_DIR/io500" "$INI" --timestamp io500 ) > "$RUNLOG" 2>&1 || RC=$?

if [ "$RC" != 0 ]; then
	vt_log "io500 exited $RC; tail of $RUNLOG:"
	tail -40 "$RUNLOG" >&2
fi

# Copy the raw log and results somewhere that survives VM shutdown.
OUT="${VMTEST_DATA_DIR:-/tmp}/$ARTIFACT_NAME"
mkdir -p "$OUT"
cp "$RUNLOG" "$OUT/io500-run.log" 2>/dev/null || true
cp "$INI" "$OUT/io500.ini" 2>/dev/null || true
# -T: replace the directory, do not nest a copy inside a previous run's
# results (plain `cp -r src dst` with dst existing creates dst/src/).
rm -rf "$OUT/results" 2>/dev/null || true
cp -rT "$RESULTDIR" "$OUT/results" 2>/dev/null || true

SCORE_OK=0
report_score "$RUNLOG" "$RESULTDIR" || SCORE_OK=1

vt_hold

ceph_umount "$CEPH_MNT"

OUT=$(ceph_save_artifacts "$ARTIFACT_NAME")
vt_log "artifacts: $OUT/"
DMESG_OK=0
ceph_check_dmesg "$OUT" || DMESG_OK=1

echo "" >&2
echo "===== cephfs_io500 summary =====" >&2
printf '  kernel        %s\n' "$(uname -r)" >&2
printf '  lazyio        %s\n' "$([ -n "$MOUNT_OPTS" ] && echo yes || echo no)" >&2
printf '  stonewall     %ss (%s)\n' "$IO500_STONEWALL" \
	"$([ "$IO500_STONEWALL" -ge 300 ] 2>/dev/null && echo submittable || echo "minimum-time, score is [INVALID] by io500 rules")" >&2
printf '  mpi ranks     %s\n' "$IO500_NP" >&2
printf '  io500 exit    %s\n' "$RC" >&2
printf '  lockdep       %s\n' "$CEPH_LOCKDEP_STATE" >&2
printf '  dmesg         %s\n' "$([ "$DMESG_OK" = 0 ] && echo clean || echo COMPLAINTS)" >&2
grep -aE "^\[SCORE" "$RUNLOG" 2>/dev/null | sed 's/^/  /' >&2 || true
echo "================================" >&2

[ "$DMESG_OK" = 0 ] || vt_die "kernel reported errors/warnings (see $OUT/splats.log)"
[ "$RC" = 0 ] || vt_die "io500 failed (exit $RC, log at $OUT/io500-run.log)"
[ "$SCORE_OK" = 0 ] || vt_die "io500 produced no usable score (log at $OUT/io500-run.log)"
vt_pass "io500 completed on CephFS$([ -n "$MOUNT_OPTS" ] && echo ' (lazyio)')"
