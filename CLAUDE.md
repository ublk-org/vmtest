# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A standalone harness for running Linux kernel block-layer / ublk / io_uring
tests under [virtme-ng](https://github.com/arighi/virtme-ng). It is *not* a
kernel source tree; it sits next to one and boots it. See `README.md` for
user-facing docs.

## Common commands

There is **no build step** — everything is bash, run in place.

```sh
./vmtest config                 # verify config resolves (vng, vmlinux, dirs)
./vmtest list                   # list tests + their requirements
./vmtest run NAME [args]        # boot the kernel under vng, run a test inside
./vmtest run ./path/to.sh       # run an ad-hoc script (not a registered test)
./vmtest run shell              # interactive root shell in the VM (also bare `run`)
./vmtest run-host NAME [args]   # run on the host (only if marked host-safe)
KERNEL_DIR=~/git/linux-next ./vmtest run NAME   # per-invocation override
shellcheck vmtest run_vm lib/common.sh tests/*.sh   # lint (no CI; run manually)
```

`shellcheck` is the only linter; the three top-level scripts carry inline
`# shellcheck disable=` directives, so keep new code clean under it.

## Layout (load-bearing)

```
vmtest               CLI: list / run / run-host / config (bash)
run_vm               Low-level: invokes `vng` with our QEMU + kcmdline
lib/common.sh        All helpers — sourced by every test
tests/*.sh           One file per test, fronted by `# vmtest-desc:` /
                     `# vmtest-requires:` metadata comments
vmtest.conf.example  Sample config; users copy to vmtest.conf (gitignored)
data/                Runtime scratch (disk images, hugetlb buffers). Gitignored.
```

When adding code, prefer growing `lib/common.sh` over copy-pasting into a
new test. The `vmtest list` CLI parses the metadata comments at the top
of each `tests/*.sh` — preserve the exact prefix (`# vmtest-desc:` /
`# vmtest-requires:`).

## Execution model

1. The user runs `./vmtest run NAME [args]` on the host.
2. `vmtest` resolves config (`vmtest.conf` + env), then execs `run_vm` with
   the resolved script path plus any extra args. `NAME` is either a
   registered test (resolves to `tests/NAME.sh`) or a literal path to any
   script — `cmd_run` prefers an existing file at the given path before
   falling back to `tests/NAME.sh` (see `vmtest:108`).
3. `run_vm` checks `$KERNEL_DIR/vmlinux`, ensures `data/d1.img` and
   `data/d2.img` exist (creating them with `truncate` if not), then boots
   `vng` with:
   - `--rwdir $VMTEST_DATA_DIR` — host dir visible read-write in guest.
   - `intel-iommu` enabled in QEMU and on the kernel cmdline.
   - Extra SCSI + NVMe devices behind the IOMMU.
   - `--exec "env VAR=val... tests/NAME.sh args..."` — env forwarding,
     because `vng` does **not** preserve the host environment otherwise.
4. Inside the VM, the test sources `lib/common.sh`, calls `vt_load_config`
   to repopulate `$KERNEL_DIR` / `$UBLKSRV_DIR` / etc., declares its
   requirements via `vt_require_*`, installs the cleanup trap, and runs.

## Config resolution

`vt_load_config` (in `lib/common.sh`) sources `${VMTEST_CONF:-./vmtest.conf}`
if present, then fills defaults. **The environment always wins** because
the `: "${VAR:=default}"` syntax only sets when unset. This means
`KERNEL_DIR=… ./vmtest run …` is the canonical per-invocation override and
should be treated as a supported public interface — don't break it.

## Conventions for new tests

- Source `lib/common.sh` with `. "$(dirname "$0")/../lib/common.sh"`. Relative
  paths inside tests are fragile because `vng` invokes them with an arbitrary
  cwd; the `dirname "$0"` form is what works.
- One `vt_install_trap` per test, with cleanup commands pushed via
  `vt_atexit "cmd"`. Cleanups run LIFO. Do not register your own EXIT trap
  — it will clobber the cleanup stack.
- Missing optional deps → `vt_skip` (exit 4); real failures → `vt_die` (exit
  1) or non-zero exit. Don't conflate the two — `vmtest list` shows
  requirements precisely so testers know what to install.
- Out-of-tree binaries (`ublksrv`, `fio/t/io_uring`) belong behind
  `vt_require_ublksrv` / `vt_require_fio`. Don't hard-code paths under
  `/home/ming/...` — those are gone for a reason.
- `set -eu` at the top; `set -x` only when actively debugging.

## Interactive shell

`./vmtest run shell` (aliases: `run bash`, or bare `./vmtest run`) boots the
same VM but drops into an interactive root shell instead of a test. Mechanics
worth knowing (`run_vm` `--shell`):

- Shell mode must **not** use virtme-ng's `--exec`/`--script-sh` path: in
  script mode the kernel console is a write-only chardev and the script's
  stdin is a non-tty virtio-serial port, so an interactive shell there gets
  no input and no job control. Instead shell mode boots vng *without*
  `--exec`, so virtme-ng wires a bidirectional getty on the serial console
  (`/dev/ttyS0`) — a real tty with input and job control (`$-` has `i`+`m`).
- Env forwarding (which `--exec` normally carries) is reintroduced via a
  generated wrapper passed to vng's `--shell`. `run_vm` writes
  `$VMTEST_TMPDIR/vmtest-shell.sh` — it `export`s the same `PATH` (incl.
  cargo bins), `UBLKSRV_DIR`, `VMTEST_DATA_DIR`, `TERM`, etc. that tests
  get, `cd`s into the repo, then `exec bash -i`. The tmpdir is mounted into
  the guest at the same absolute path, so vng can exec it as the login
  shell. You can `source lib/common.sh` and reproduce a test by hand.
- Precedence: a real test or file named `shell`/`bash` wins over the keyword,
  so the keyword can never shadow an actual test (`cmd_run` in `vmtest`).
- Exit the shell (or Ctrl-D) to power the VM off.

## run-host and post-mortem debugging

- `run-host` bypasses the VM entirely and runs `tests/NAME.sh` on the real
  host. It refuses unless the test declares `# vmtest-host: yes` (only
  `rublk.sh` does today). This gate exists because most tests `modprobe`
  modules and touch real devices — running those on the host is dangerous.
- To inspect a running VM, set `VMTEST_SSH=1` (adds user-mode net + in-VM
  sshd; attach from another terminal with `vng --ssh-client --ssh-tcp`).
  Pair with `VMTEST_HOLD=1`, which makes tests that call `vt_hold` block on
  `sleep infinity` after the body finishes instead of powering off. atexit
  cleanups still run on Ctrl-C / `kill -TERM $$`.

## Exit-code convention (kselftest)

Tests follow kselftest semantics, enforced by the `lib/common.sh` helpers:
`0` pass (`vt_pass`), `1` fail (`vt_die`), `4` skip (`vt_skip`, for missing
optional deps / hardware). Keep skip and fail distinct — `vmtest list`
advertises requirements so testers can tell which is which.

## Things that look like bugs but aren't

- `KERNEL_DIR` defaults to `<repo>/..` not `<repo>/../..` — the convention
  is that the repo sits inside the kernel tree as `vmtest/`, not two levels
  deep. (Earlier `run_vm` versions took the kernel path as a positional arg,
  which is why that pattern was easy to get wrong.)
- The two extra disk images are lazily created by `run_vm` on first boot,
  so a freshly-cloned repo will show `data/d{1,2}.img` appearing after the
  first `./vmtest run`.

## Verification

`./vmtest run loop_autoclear` is the dependency-free smoke test — it
only needs a built kernel and `vng`. Use it to validate harness changes
before touching the heavier ublksrv/VFIO paths.
