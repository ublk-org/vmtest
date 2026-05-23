# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A personal test harness for Linux kernel block-layer / ublk / io_uring work. It is **not** a kernel source tree — it lives at `vmtest/` inside a kernel checkout (e.g. `~/git/linux/vmtest/`). The top-level `.gitignore` is the upstream kernel `.gitignore` and is not authoritative for this directory.

All scripts are bash; there is no build step here. The work happens by booting the surrounding kernel tree inside a VM and running shell scripts against it.

## VM execution model

Tests are run via `virtme-ng` (the `vng` binary). The dispatcher is `./run_vm`:

```
./run_vm <kernel-src-dir> <test-script-path> [test-args...]
```

`run_vm` boots `vng` with:
- `--rwdir` pointing at `./data/` (host directory exposed read-write to the guest via 9p)
- two extra block devices attached to the VM: SCSI (`data/d1.img`) and NVMe (`data/d2.img`)
- `intel-iommu` with `caching-mode=on` and `device-iotlb=on` — required for the `vfio_pci` tests
- 16 CPUs / 8G RAM, `intel_iommu=on` on the kernel command line, zram services masked
- `--exec` runs the provided test script as root inside the VM

Test scripts are designed to run **inside the VM**, not on the host. They reference host paths (e.g. `/home/ming/git/ublksrv/.libs/...`) because the host filesystem is visible through 9p.

## Test-script families

| Script | What it tests |
|---|---|
| `ublk_test_grp.sh` | Runs a group of kernel `tools/testing/selftests/ublk` selftests (`make $GRP`). Wired up by commit "ublk: test via group". |
| `ublk_selftest.sh` | Runs a single ublk selftest by filename pattern. |
| `io_uring_selftest.sh` | Runs the kernel `tools/testing/selftests/io_uring/runner`. |
| `loop_autoclear_test.sh` | Stress test for the `losetup -d` race fixed by `sync_blockdev()` in `__loop_clr_fd()` — looks for GPF in `lo_rw_aio` in `dmesg`. |
| `t_io_uring_htlb_test.sh` | Runs fio's `t/io_uring` with a hugetlbfs-backed buffer (`-H`). |
| `ublksrv_shmem_zc_test.sh` | Tests `UBLK_F_SHMEM_ZC` against the `ublk.loop` target with hugetlb-registered buffers. |
| `nvme_vfio_shmem_zc_test.sh` | Same `SHMEM_ZC` path, against the `ublk.nvme_vfio` target (binds the guest's NVMe to `vfio_pci`). |
| `nvme_vfio_legacy_test.sh` | Same target, but forces the legacy VFIO container path (`--force-legacy`). |
| `nvme_bpf` | BPF-arena SQ-submission variant of the `nvme_vfio` test. |
| `rublk_test` | `cd data/rublk && cargo test` — Rust-based ublk tests. |

Files ending in `~` are Emacs backups; ignore them.

## External dependencies the scripts assume

These paths are hard-coded; if they're missing the test fails immediately.

- `~/git/ublksrv` — built ublksrv tree. The VFIO/SHMEM tests load `ublk`, `ublk.loop`, `ublk.nvme_vfio` from `${UBLKSRVD}/.libs/` and shared libs from `${UBLKSRVD}/lib/.libs/`.
- `~/git/others/fio` and/or `~/git/fio` — `fio` and `fio/t/io_uring` binaries.
- `~/git/linux/temp/{data,vng}` — used as `TMPDIR` and as the `--rwdir` target. Disk images and stray binaries (e.g. `temp/data/ublksrv/`) are expected to already exist; the test scripts do not provision them.
- A working `hugetlbfs` — the SHMEM_ZC and VFIO scripts allocate hugepages on the fly (`echo N > /proc/sys/vm/nr_hugepages`) and mount on `/tmp/hugetlb`.

## Common operations

- Run a ublk selftest group inside the VM:
  `./run_vm ~/git/linux ./ublk_test_grp.sh <group-name>`
- Run a single bash test:
  `./run_vm ~/git/linux ./loop_autoclear_test.sh 50`
- Reproduce a VFIO NVMe regression:
  `./run_vm ~/git/linux ./nvme_vfio_legacy_test.sh`

The kernel-source argument is whichever tree you want booted; `run_vm` itself does not care that it lives inside that tree.

## Conventions worth preserving

- Scripts use `set -ex` (or `set -e`) and a `die()` helper followed by an explicit `cleanup` `trap EXIT` — every test that creates a ublk device / mounts hugetlbfs / allocates a backing file is expected to tear it down even on failure. Keep that pattern when adding new scripts.
- `dmesg | tail` at the end of a failure path is the standard way of surfacing kernel state from inside the VM; the host never sees the guest's dmesg otherwise.
- Tests are deliberately tolerant of missing devices (`modprobe ... 2>/dev/null || true`, `[ -b /dev/ublkb0 ]` probes) because the same script is reused across kernels with different config.
- New tests should be invokable as `./run_vm <kernel> ./new_test.sh [args]` — i.e. accept their own args via `$@`, do their own module loading, and exit non-zero on the first real failure.
