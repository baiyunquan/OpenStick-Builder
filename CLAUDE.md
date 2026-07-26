# CLAUDE.md

Image builder for MSM8916-based 4G LTE dongles (Zhihe UFI103S / UFI-001C / UZ801 / UF896 …).
Forked from `kinsamanka/OpenStick-Builder`; this fork adds a postmarketOS build track.

## Two independent build tracks

The repo contains **two unrelated pipelines**. Know which one you're touching.

### 1. Debian rootfs (original upstream)

`build.sh` drives `scripts/*.sh` in order: `install_deps` → `build_hyp_aboot` →
`extract_fw` → `debootstrap` → `build_gt` → `build_images`. Everything runs as root
on the host and builds an arm64 chroot under `rootfs/` via `debootstrap` + `qemu-aarch64-static`.

- Workflows: `.github/workflows/build.yml`, `build-uz801-v21-trixie-fullimg.yml`
- Package customization lives in `scripts/setup.sh` (runs *inside* the chroot)
- Output goes to `files/` (gitignored)

### 2. postmarketOS (this fork's addition, branch `pmos-zhihe-ufi103s-v05`)

No `scripts/` involvement at all — the workflow clones `pmbootstrap` + `pmaports`,
writes `~/.config/pmbootstrap_v3.cfg` by hand, and runs `pmbootstrap install --split`.

- Workflows: `.github/workflows/build-pmos-zhihe.yml` (`ui = none`),
  `build-pmos-zhihe-modem.yml` (`ui = console` + ModemManager/qmi/qrtr)
- Device package is upstream `device-zhihe-generic`, kernel subpackage `ufi001c`
- `pmbootstrap/` in the repo root is a **gitignored local clone of upstream pmbootstrap**,
  kept only for reading source when debugging. Nothing builds from it.

Both tracks share the bootloader build (submodules) and are `workflow_dispatch` only.

## Bootloader chain (shared)

Submodules under `src/`: `lk2nd`, `qhypstub`, `qtestsign`, `gt`, `libusbgx`.

- `qhypstub` → signed by `qtestsign hyp` → `files/hyp.mbn`
- `lk2nd` target `lk1st-msm8916` → signed by `qtestsign aboot` → `files/aboot.mbn`
- `tz.mbn` is extracted from a DragonBoard 410c firmware zip
  (`firmware/dragonboard410c/`, sha256-verified in CI)
- `LK2ND_COMPATIBLE` differs per board: `thwc,ufi001c` (pmOS workflows) vs
  `yiming,uz801-v3` (`scripts/build_hyp_aboot.sh`)
- `USE_TARGET_HS200_CAPS=1` is appended to `project/lk1st-msm8916.mk` on purpose —
  it lowers mmc speed because some boards use recycled flash. Don't drop it.

## SIM slot DTB variants (pmOS modem track)

`scripts/make_zhihe_dtb_variants.sh <base.dtb> <outdir>` decompiles the exported
`msm8916-thwc-ufi001c.dtb` with `dtc`, rewrites the `sim-ctrl-default-state` pinctrl
node, and emits `-physical` / `-esim1` / `-esim2` variants.
`helpers/ufi103s-select-sim-slot.sh` swaps the active DTB on the device at runtime.

## Working with the postmarketOS track

**The single biggest source of breakage is upstream pmaports, not this repo.**
It tracks the `edge` channel, so an upstream commit can break CI on a day when
nothing here changed. See [SOLUTION.md](SOLUTION.md) for a worked example
(2026-07-19 removal of `device-zhihe-generic-nonfree-firmware` broke every run
for a week) and the full debugging recipe.

### Rules of thumb

- **Never hardcode upstream subpackage names in `extra_packages`.** pmbootstrap's
  `get_nonfree_packages()` (`pmb/install/_install.py:61`) already discovers
  `-nonfree-firmware` / `-nonfree-userland` from the APKBUILD. Put only genuinely
  extra packages there — things the upstream device package will never pull in.
- **Don't hardcode pmbootstrap internals.** `$PMB_WORK/version` is read from
  `pmb.config.work_version` at runtime; a bump would otherwise hit an interactive
  `confirm()` and hang CI.
- **pmbootstrap is pinned** (`--branch 3.11.1`). pmaports deliberately is not.
- Both workflows dump `tail -n 300 "$PMB_WORK/log.txt"` on failure. pmbootstrap's
  real apk error goes there, not to stdout — keep this.

### Verifying a package-set change without waiting for CI

Resolve the dependency closure offline against the live APKINDEXes (seconds, not
minutes). Full script in [SOLUTION.md](SOLUTION.md) §3. Repo URLs:

```
https://dl-cdn.alpinelinux.org/alpine/edge/{main,community,testing}/aarch64/APKINDEX.tar.gz
https://mirror.postmarketos.org/postmarketos/main/aarch64/APKINDEX.tar.gz
https://mirror.postmarketos.org/postmarketos/extra-repos/systemd/main/aarch64/APKINDEX.tar.gz
```

The postmarketOS mirrordir is `channels.cfg`'s `branch_pmaports`, **not** the channel
name. pmaports renamed its default branch `master` → `main`, so edge lives under
`/postmarketos/main/`, not `/postmarketos/edge/`. Same for the pmbootstrap repo —
its default branch is `main` too.

`extra-repos/systemd` only applies when systemd is selected (`ui = console` does;
`ui = none` doesn't). Check the `Channel:` line pmbootstrap prints.

## Running CI

All workflows are `workflow_dispatch` only:

```bash
gh workflow run build-pmos-zhihe-modem.yml --ref pmos-zhihe-ufi103s-v05
gh run watch <run-id> --exit-status
```

Healthy pmOS runs take ~2–5 min. A failure in 1–2 min almost always means apk
couldn't resolve the package set.

## Conventions

- Shell scripts are POSIX `sh` with `set -e` (`#!/bin/sh -e`), tab-indented.
- Commit subjects are short and imperative, often prefixed `CI:` for workflow changes.
- `files/`, `rootfs/`, `mnt/`, `build/`, `dist/`, `pmbootstrap/`, `*.mbn`, `*.img`
  are gitignored — never commit build output.
- Branches are per-device/per-target (`pmos-zhihe-ufi103s-v05`,
  `uz801-v21-trixie-fullimg`, `alpine`, …); `main` is the Debian/UZ801 baseline.
  Fixes validated on a device branch usually need cherry-picking to `main`.
