# vmtest

A small harness for running Linux kernel block / ublk / io_uring tests
inside a throwaway VM. Wraps [virtme-ng](https://github.com/arighi/virtme-ng)
(`vng`) with sane defaults for IOMMU passthrough, hugetlb, extra disks,
and an out-of-tree ublksrv build.

It's designed to be cloned next to any kernel checkout — point it at
your built kernel and it will boot it, mount the host filesystem into
the guest over 9p, and run the requested test as root inside.

> **Note:** unrelated to [`danobi/vmtest`](https://github.com/danobi/vmtest),
> a separate (Rust) BPF-focused VM test runner. This project is a small
> bash harness around `virtme-ng`, oriented toward block / ublk / io_uring
> work — if you're looking for a general BPF kernel test runner, you
> probably want that one instead.

## Layout

```
vmtest/
  vmtest                CLI: list / run / run-host / config
  run_vm                Low-level: boots vng + runs one script
  lib/common.sh         Helpers all tests source
  tests/*.sh            One file per test
  vmtest.conf.example   Sample config — copy to vmtest.conf
```

## Quickstart

```sh
git clone https://github.com/<you>/vmtest.git
cd vmtest
cp vmtest.conf.example vmtest.conf
$EDITOR vmtest.conf                   # set KERNEL_DIR at minimum

./vmtest config                       # check everything resolves
./vmtest list                         # see available tests
./vmtest run loop_autoclear           # run one inside the VM
./vmtest run ublk_test_grp generic    # pass args to the test
./vmtest run shell                    # interactive root shell in the VM
```

`./vmtest run NAME` boots the kernel at `$KERNEL_DIR` under `vng`, mounts
the repo's `data/` directory read-write into the guest, and execs
`tests/NAME.sh` as root inside.

## Interactive shell

`./vmtest run shell` (aliases: `run bash`, or a bare `./vmtest run`) boots
the same VM but drops you at an interactive root shell instead of running a
test — handy for poking at the kernel by hand or reproducing a test
step-by-step.

It's a real terminal: keyboard input, job control (`Ctrl-Z`, `fg`, `bg`),
and line editing all work. The shell inherits the same environment the tests
get — `PATH` (including any host `~/.cargo/bin`), `UBLKSRV_DIR`,
`VMTEST_DATA_DIR`, `TERM`, etc. — and starts in the repo directory, so you
can `source lib/common.sh` and call the `vt_*` helpers directly. Exit the
shell (or press `Ctrl-D`) to power the VM off.

A registered test or file literally named `shell`/`bash` still takes
precedence over the keyword, so it can never shadow a real test.

## Prerequisites

On the host:

- `vng` / `virtme-ng` — boots the kernel.
- A kernel tree built with `vmlinux` present (any kernel that supports
  the subsystems your test exercises). Modules are needed for tests
  that use `modprobe`.
- `qemu-system-x86_64` with `intel-iommu` (used by the NVMe-VFIO tests).
- Optional: a built `ublksrv` checkout (for `ublksrv_*` and `nvme_vfio_*`
  tests), an `fio` source tree (for tests that use `fio/t/io_uring`), or
  a `rublk` Rust crate.

All of the optional pieces are pointed at via `vmtest.conf` — missing
deps cause tests to **skip** (exit 4), not fail.

## Configuration

`vmtest.conf` is sourced by bash. Set any of:

| Variable | Default | Purpose |
|---|---|---|
| `KERNEL_DIR` | `<repo>/..` | Kernel tree to boot (must have `vmlinux`). |
| `VMTEST_DATA_DIR` | `<repo>/data` | Scratch dir exposed to the guest via 9p. |
| `UBLKSRV_DIR` | unset | Path to a built ublksrv. |
| `FIO_DIR` | unset | Path to an fio source tree (uses `fio/t/io_uring`). |
| `RUBLK_DIR` | `$VMTEST_DATA_DIR/rublk` | Rust crate for `rublk` tests. |
| `VMTEST_CPUS` | `16` | vCPUs passed to vng. |
| `VMTEST_MEM` | `8G` | Memory passed to vng. |
| `VMTEST_KCMDLINE_EXTRA` | — | Extra kernel command line. |
| `VMTEST_VNG` | `vng` | Path to the `vng` binary. |
| `VMTEST_QEMU_EXTRA` | — | Extra QEMU args appended to the defaults. |
| `VMTEST_SDISK_SIZE` / `VMTEST_NDISK_SIZE` | `2G` | Size of the auto-created scratch disks. |
| `VMTEST_NET` | `1` | User-mode networking, **on by default**: the guest gets a DHCP address and can reach host services at the gateway `10.0.2.2` (a host server on `127.0.0.1:PORT` is `10.0.2.2:PORT` from the guest). No host setup or root needed. Set `0` to disable for a hermetic boot. |
| `VMTEST_SSH` | — | If `1`, boot with an in-VM sshd (forces networking on even if `VMTEST_NET=0`). Attach with `vng --ssh-client --ssh-tcp` from another terminal. |
| `VMTEST_HOLD` | — | If `1`, tests that call `vt_hold` will `sleep infinity` after the test body completes, keeping the VM up for post-mortem inspection. Pair with `VMTEST_SSH=1`. |

Anything in the environment beats `vmtest.conf`, so per-invocation
overrides work:

```sh
KERNEL_DIR=~/git/linux-next ./vmtest run ublk_selftest
```

## Writing a new test

Tests live in `tests/NAME.sh` and look like this:

```sh
#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: One-line description (shows in `vmtest list`)
# vmtest-requires: root ublksrv hugetlb fio nvme-pci

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_module ublk_drv
vt_require_ublksrv         # SKIPs if UBLKSRV_DIR missing
vt_require_cmd fio         # SKIPs if no fio in $PATH
vt_install_trap            # one trap, runs registered cleanups LIFO

vt_setup_hugetlb 256       # auto-mounts /tmp/hugetlb, auto-cleans
backing="$VMTEST_TMPDIR/mytest.img"
vt_atexit "rm -f '$backing'"
truncate -s 1G "$backing"

# ... test logic ...

vt_pass "mytest"
```

Helpers exported by `lib/common.sh`:

- `vt_log` / `vt_warn` / `vt_die` / `vt_skip` / `vt_pass` — labelled output.
- `vt_atexit "cmd"` — register cleanup; runs in LIFO order on EXIT.
- `vt_install_trap` — install the single EXIT trap that drains the list.
- `vt_require_root` / `vt_require_cmd C…` / `vt_require_module M…` —
  skip cleanly if prerequisites are missing.
- `vt_require_ublksrv` / `vt_require_fio` — set `VT_UBLK`, `VT_T_IO_URING`
  and `LD_LIBRARY_PATH` for out-of-tree binaries.
- `vt_setup_hugetlb N` — mount hugetlbfs and reserve N pages.
- `vt_wait_for_block /dev/X [timeout]` — poll for a block device.
- `vt_find_nvme_pci` — discover the guest's NVMe PCI address.
- `vt_dmesg_clear` / `vt_dmesg_has PAT…` — capture kernel events.

The metadata comments (`vmtest-desc:`, `vmtest-requires:`) are read by
`./vmtest list` — they're optional but make discovery much nicer.

Add `# vmtest-host: yes` if your test is safe to run on the host
(i.e. it doesn't touch real devices, modprobe modules, etc.). Without
that line, `./vmtest run-host NAME` refuses to run as a safeguard.

## Exit codes

Test scripts use the standard kselftest convention:

- `0` — pass
- `1` — fail
- `4` — skip (missing optional dep, no relevant hardware)

## License

GPL-2.0
