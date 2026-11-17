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

## Notes

- Enrollment is **24 touches** by design (more stored touches cover more of the
  fingertip, which lowers false rejects).
- The reader's threshold is device-specific, so this change does not alter
  behaviour for `04f3:0c4f`, `0c63`, `0c6e`.
- Upstreaming: this could go to the `elanpress` driver
  (github.com/filip-rs/libfprint, branch `elanpress`) and/or the Omarchy package
  PR (`omacom/omarchy-pkgs#2329`) so it stops being a local patch.

## License

The patches apply to libfprint and the `elanpress` driver, both licensed
LGPL-2.1-or-later; the contents of this repository are offered under the same
terms.
