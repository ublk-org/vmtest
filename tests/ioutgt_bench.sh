#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: ioutgt NVMe/TCP t/io_uring throughput probe (target on host)
# vmtest-requires: root nvme-cli
#
# Launch from the ioutgt checkout's host runner, which starts the target
# and boots the VM. The runner owns VMTEST / VMTEST_CONF (and the probe
# path) — nothing local is baked into this test:
#
#   VMTEST=/path/to/vmtest/vmtest \
#   VMTEST_CONF=/path/to/vmtest.conf \
#   T_IO_URING=/path/to/fio/t/io_uring \
#   IOUTGT_BACKEND=null IOUTGT_IO_THREADS=16 \
#       testing/run_interop.sh ioutgt_bench
#
# env does not cross into the guest, so the host runner publishes the
# checkout dir, the listen port, and the t/io_uring path through the
# vmtest 9p marker dir; this test reads them back. Tunables:
#   IOUTGT_NR_IO_QUEUES  nvme connect --nr-io-queues  (default 16)
#   TIOU_ARGS            t/io_uring args              (default -p0 -b4096 -r15)
#   T_IO_URING           probe path, when run by hand inside the guest
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap

IOUTGT_DIR="${IOUTGT_DIR:-$(cat "$VMTEST_TMPDIR/ioutgt_top" 2>/dev/null || true)}"
[ -n "$IOUTGT_DIR" ] && [ -r "$IOUTGT_DIR/testing/vmtest/ioutgt_connect.sh" ] ||
	vt_die "ioutgt repo not found at '${IOUTGT_DIR:-<unset>}'"
. "$IOUTGT_DIR/testing/vmtest/ioutgt_connect.sh"

# Probe path: the host runner passes it via the 9p marker dir (same path
# mechanism as the checkout dir / port); T_IO_URING overrides it for a
# manual guest run. No local path is hardcoded here.
TIOU="${T_IO_URING:-$(cat "$VMTEST_TMPDIR/ioutgt_tiou" 2>/dev/null || true)}"
[ -n "$TIOU" ] || vt_die "t/io_uring path unset: pass T_IO_URING to the host runner (testing/run_interop.sh)"
[ -x "$TIOU" ] || vt_die "t/io_uring not executable at '$TIOU' (build it with: make -C <fio> t/io_uring)"

NRQ="${IOUTGT_NR_IO_QUEUES:-16}"
vt_log "nvme connect --nr-io-queues=$NRQ to $ADDR:$PORT"
nvme connect -t tcp -a "$ADDR" -s "$PORT" -n "$NQN" --nr-io-queues="$NRQ" ||
	vt_die "nvme connect failed"

dev=""
for _ in $(seq 40); do
	dev=$(nvme list 2>/dev/null | awk '$1 ~ /^\/dev\/nvme/ {print $1}' | tail -1)
	[ -n "$dev" ] && [ -b "$dev" ] && break
	sleep 0.25
done
[ -n "$dev" ] || { dmesg | tail -20; vt_die "no nvme namespace device appeared"; }
ctrl=$(basename "$dev"); ctrl=${ctrl%n*}
qc=$(cat "/sys/class/nvme/$ctrl/queue_count" 2>/dev/null || echo '?')
nr_tags=$(cat "/sys/block/$(basename "$dev")/mq/0/nr_tags" 2>/dev/null || echo '?')
vt_log "bench dev=$dev ctrl=$ctrl queue_count=$qc mq0/nr_tags=$nr_tags (the single-queue depth)"

# Default args mirror the reported repro: t/io_uring's own default is one
# submitter thread at depth 128, 4K, 15s. The single submitter rides one
# nvme queue, whose depth is what the target's --io-queue-size (MAXCMD)
# clamps.
ARGS="${TIOU_ARGS:--p0 -b4096 -r15}"
vt_log "RUN: $TIOU $ARGS $dev"
# shellcheck disable=SC2086
"$TIOU" $ARGS "$dev" 2>&1 | while IFS= read -r line; do vt_log "tiou| $line"; done

nvme disconnect -n "$NQN" >/dev/null 2>&1 || true
ioutgt_mark "PASS bench"
