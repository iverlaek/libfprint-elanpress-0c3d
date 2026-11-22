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

## Install — build from this repo

**Use this repo's `PKGBUILD`.** The Omarchy / omarchy-pkgs `libfprint-git`
package does **not** contain `elanpress-0c3d.patch`. Installing that one leaves
`04f3:0c3d` on the swipe driver, and enrollment/verification will keep failing.

The patch is already wired up here:

- `elanpress.patch` adds Filip Spanne's press driver (for `0c4f`, `0c63`, `0c6e`).
- `elanpress-0c3d.patch` adds `04f3:0c3d` to that driver, removes it from `elan`,
  and gives it the lower `600` pixel-delta threshold.
- `PKGBUILD` lists `elanpress-0c3d.patch` in `source` and applies it in
  `prepare()`; `pkgrel=7` supersedes earlier builds.

```bash
git clone https://github.com/iverlaek/libfprint-elanpress-0c3d.git
cd libfprint-elanpress-0c3d
makepkg --nocheck --syncdeps --cleanbuild --force
sudo pacman -U --noconfirm libfprint-git-*.pkg.tar.zst
sudo systemctl restart fprintd
```

If pacman says the installed version is newer, bump `pkgrel` in `PKGBUILD`
(for example to `8`) and rebuild. Then confirm the patched driver is active:

```bash
pacman -Qi libfprint-git | grep Version
fprintd-list "$USER"    # expect: ElanTech press-type fingerprint sensor
```

Do **not** configure PAM with `omarchy setup security fingerprint` afterwards:
it can replace this package with the unpatched one, and it deletes any existing
print. Use `pam-fingerprint.sh` from this repo for PAM instead.

## Files

- `PKGBUILD` — Omarchy's `libfprint-git` package with `elanpress-0c3d.patch`
  added to `source`/`prepare()` and `pkgrel` bumped to 7. This is the file to
  build with `makepkg`; see **Install** above.
- `elanpress.patch` — Omarchy's press-driver patch (unchanged).
- `elanpress-0c3d.patch` — the local change described above.
- `focaltech_moc-add-pid-0xA97A.patch` — carried by the Omarchy PKGBUILD.
- `pam-fingerprint.sh` — wires `pam_fprintd` into sudo/polkit/lock screen,
  replicating `omarchy-setup-security-fingerprint`'s `setup_pam_config()`
  without its reinstall/re-enroll.
- `sddm-fingerprint-show-prompt.patch` — patch for Omarchy's
  `omarchy-fingerprint` SDDM theme: displays the PAM "place your finger"
  message and highlights the glyph while waiting; see **Fingerprint on the
  SDDM login screen**.

## Rebuilding after an upstream package upgrade

If a future `libfprint-git` from Omarchy (or stock `libfprint`) replaces this one
and the reader breaks again, rebuild from this repo using the same steps as in
**Install** above:

```bash
cd /path/to/libfprint-elanpress-0c3d    # wherever you cloned this repo
makepkg --nocheck --syncdeps --cleanbuild --force
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

## Fingerprint on the SDDM login screen

A working print and PAM config are not enough by themselves — two SDDM defaults
hide the option on Omarchy.

**1. Autologin bypasses authentication entirely.** With
`/etc/sddm.conf.d/autologin.conf` present, SDDM starts the session through
`pam_unix(sddm-autologin:session)` and never asks for credentials, so
`pam_fprintd` is never reached. Disable it (reversibly):

```bash
sudo mv /etc/sddm.conf.d/autologin.conf /etc/sddm.conf.d/autologin.conf.disabled
```

**2. Install the theme where the greeter can see it.** Omarchy ships the theme
in `~/.local/share/sddm/themes/omarchy-fingerprint`, but the SDDM greeter runs
as the `sddm` user and cannot read it. SDDM then logs

```text
The configured theme "omarchy-fingerprint" doesn't exist, using the embedded theme instead
```

and you get the stock Breeze greeter, with its user/session dropdown (handy for
picking e.g. `Hyprland (uwsm-managed)`), but no fingerprint glyph. Copy it to
the system theme directory:

```bash
cd ~/.local/share/sddm/themes/omarchy-fingerprint
patch -p1 < /path/to/libfprint-elanpress-0c3d/sddm-fingerprint-show-prompt.patch
sudo cp -a ~/.local/share/sddm/themes/omarchy-fingerprint /usr/share/sddm/themes/
```

The patch matters: the stock theme only draws the glyph and never displays the
PAM conversation, so clicking it with an empty password looks like nothing
happened. It now shows the `Place your right index finger...` message and lights
the glyph amber while the sensor is waiting. It also fixes a deprecated
`Keys.onPressed` handler.

**3. The stock theme config overrides the fingerprint theme.** If
`99-omarchy-login.conf` (`Current=omarchy`) loads after
`99-omarchy-fingerprint.conf` (`Current=omarchy-fingerprint`), the plain theme
wins. SDDM reads `/etc/sddm.conf.d/*.conf` in filename order, so rename the
fingerprint file to sort last:

```bash
sudo mv /etc/sddm.conf.d/99-omarchy-fingerprint.conf \
        /etc/sddm.conf.d/99-omarchy-zfingerprint.conf
grep -H 'Current=' /etc/sddm.conf.d/*.conf   # fingerprint entry must be last
```

After logging out or rebooting, the login screen shows a `󰈷` glyph next to the
password field. **Click the glyph** to start authentication with an empty
password; `pam_fprintd` then prompts for the print. Touching the sensor alone
does not initiate login from SDDM — the QML only wires the glyph's click to
`sddm.login(...)`. If verification fails or times out, PAM falls back to the
password field. Even the embedded greeter can authenticate by fingerprint:
submitting an empty password reaches `pam_fprintd.so`, which prompts
`Place your right index finger on the fingerprint reader`. The lock screen is
different again — there, Omarchy's `FingerprintModel.js` reacts to the sensor
directly.

Use the **same firm, ~1 s centred press** for verification as for enrollment.
Quick taps are ignored by the driver and short presses never reach the coverage
gate; with `auth sufficient pam_fprintd.so`, a failed verification simply falls
through to `pam_unix`, which is why you end up needing the password as well.
Don't click the glyph repeatedly or press Enter again while a login is in flight:
SDDM logs `Existing authentication ongoing, aborting` and discards those
attempts. Wait for the prompt, press once properly, and wait for the result.

A healthy fingerprint-only login looks like this in the journal:

```text
Authentication information: SDDM::Auth::INFO_UNKNOWN "Place your right index finger on the fingerprint reader"
Authentication for user "verlaek" successful
```

To confirm the greeter found the theme, check the journal after a logout:

```bash
journalctl -u sddm --since '-10 min' | grep -i theme
```

There should be no `using the embedded theme instead` line.

Both renames are reversible — swap the filenames back to restore autologin or
the stock theme.

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
