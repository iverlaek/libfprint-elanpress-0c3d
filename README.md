# Elan 04f3:0c3d (FeinTech FPS00201) fingerprint reader on Omarchy

## What was wrong

The reader is a **press** sensor, but upstream `libfprint`'s `elan` driver claimed
`04f3:0c3d` as a **swipe** sensor. Every capture was stitched/corrupted, so
enrollment appeared to work but verification always failed with
`verify-swipe-too-short` and `Failed to detect minutiae: No minutiae found`.

## The fix

Move `04f3:0c3d` to the `elanpress` press driver (Filip Spanne's driver, which
Omarchy already carries for `04f3:0c4f`, `0c63`, `0c6e`) and give it a pixel-delta
threshold suited to its pad.

The `elanpress` patch from Omarchy (`elanpress.patch`) does **not** include
`0c3d`. `elanpress-0c3d.patch` adds it, in two parts:

1. **ID tables** — remove `0x0c3d` from `elan.h` (swipe) and add it to
   `elanpress.h` (press).
2. **Touch threshold** — `elanpress` decides a finger is present by counting
   pixels at least `ELANPRESS_TOUCH_PIXEL_DELTA` above the background. That was
   tuned to `1200` on larger Elan pads. On this pad a settled press only lifts
   pixels by ~300-900, so coverage topped out at ~61% against the driver's 85%
   enrollment gate and no stage ever passed. The patch gives `0c3d` a
   per-device threshold of `600` via the id table's `driver_data`
   (`ELANPRESS_0C3D`), leaving every other Elan pad on the original `1200`.

Measured on this machine (FeinTech FPS00201, `04f3:0c3d`, 144x64):

| press            | pairs vs threshold 8 |
| ---------------- | -------------------- |
| genuine finger   | 25 (and 15 on retry) |
| different finger | 4                    |

## Files

- `PKGBUILD` — Omarchy's `libfprint-git` package with `elanpress-0c3d.patch`
  added and `pkgrel` bumped to 7.
- `elanpress.patch` — Omarchy's press-driver patch (unchanged).
- `elanpress-0c3d.patch` — the local change described above.
- `focaltech_moc-add-pid-0xA97A.patch` — carried by the Omarchy PKGBUILD.
- `pam-fingerprint.sh` — wires `pam_fprintd` into sudo/polkit/lock screen,
  replicating `omarchy-setup-security-fingerprint`'s `setup_pam_config()`
  without its reinstall/re-enroll.

## Rebuilding after an upstream package upgrade

If a future `libfprint-git` from Omarchy (or stock `libfprint`) replaces this one
and the reader breaks again, rebuild from this directory:

```bash
cd ~/Work/libfprint-elanpress-0c3d
makepkg --nocheck --cleanbuild --force
sudo pacman -U --noconfirm libfprint-git-*.pkg.tar.zst
sudo systemctl restart fprintd
```

Bump `pkgrel` first if pacman considers the existing version newer. Then check
the reader still reports as a press device:

```bash
fprintd-list "$USER"          # expect: ElanTech press-type fingerprint sensor
```

Existing enrollments survive a driver swap only if the driver id stays
`elanpress`; if `fprintd-list` shows no fingers, re-enroll:

```bash
fprintd-enroll -f right-index-finger "$USER"   # 24 touches, ~1s each
```

## Enrolling successfully (and not losing the print)

The driver needs a **firm, centred press**, not a light touch and not a swipe.
With `G_MESSAGES_DEBUG=all`, accepted frames on this pad sit at ~90–98% coverage:

```text
poll: touch (coverage 97,8%, mean delta 1112)
enroll_stage_cb: result enroll-stage-passed
```

A light touch only reaches ~76–86%, below the driver's 85% gate, and is rejected
(`touch covers ... waiting for a full press`). Use this rhythm for every stage:

1. Put the right index finger in the middle of the pad.
2. Press firmly and hold for about 1 second.
3. Lift the finger **fully off** the pad.
4. Wait about 1 second before the next press.

Stage progress is **not saved** until enrollment finishes. All 24
`enroll-stage-passed` results must happen in one uninterrupted run; stopping
early (`Ctrl-C`) discards them and leaves `/var/lib/fprint` empty.

`fprintd` repeats the same `Enroll result: enroll-stage-passed` line for every
stage, which is easy to misread as a hung terminal in a small window. A one-line
counter makes progress visible:

```bash
gdbus monitor --system --dest net.reactivated.Fprint |
  grep --line-buffered -E 'enroll-stage-passed|enroll-completed' |
  awk '/stage-passed/{printf "\rStage %d/24", ++n} /completed/{print "\nCompleted!"}'
```

**Do not rerun `omarchy setup security fingerprint` once a print exists.** It
starts a new enrollment, which deletes the current print immediately (`/var/lib/fprint`
was observed being emptied at that moment). PAM is already configured by
`pam-fingerprint.sh`; to re-enroll, run `fprintd-enroll` directly instead.

Verified on 2026-11-22 with `libfprint-git 1:1.94.100.r10.g6f9479c-7` and
`fprintd 1.94.5-2`:

```text
$ fprintd-list "$USER"
Fingerprints for user verlaek on ElanTech press-type fingerprint sensor (press):
 - #0: right-index-finger

$ fprintd-verify "$USER"
Verify result: verify-match (done)
```

## Notes

- Enrollment is **24 touches** by design (more stored touches cover more of the
  fingertip, which lowers false rejects).
- The reader's threshold is device-specific, so this change does not alter
  behaviour for `04f3:0c4f`, `0c63`, `0c6e`.
- Upstream: the same change is proposed to the `elanpress` driver as
  [filip-rs/libfprint#14](https://github.com/filip-rs/libfprint/pull/14). Until
  that lands, build this package to get it now.

## License

The patches apply to libfprint and the `elanpress` driver, both licensed
LGPL-2.1-or-later; the contents of this repository are offered under the same
terms.
