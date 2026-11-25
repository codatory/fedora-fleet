# fedora-fleet

Base configuration for a fleet of Fedora workstations, applied with
[comtrya](https://comtrya.dev). One repository, one command, and every machine converges
on the same state.

This is not a dotfiles repository. It is the layer underneath one: the packages, binaries
and system settings that should be the same everywhere, so that replacing a laptop is a
clone and an apply rather than an afternoon of remembering what was installed.

## Why comtrya

[comtrya](https://github.com/comtrya/comtrya) reads manifests and makes the changes they
describe. Most actions check the machine first and do nothing when it already matches what
the manifest asks for, so a second `apply` is a no-op and an interrupted run is finished by
running it again. That property — idempotence — is the reason this repository is worth
having: a manifest is a statement about how a machine should look, not a list of steps that
must be performed exactly once.

## Layout

```
bootstrap.sh              Prepares a new machine: gets comtrya, then applies the manifests
Comtrya.yaml              Configuration for running comtrya in a local checkout
manifests/
  base/
    comtrya.yaml          Keeps one pinned comtrya installed
    mise.yaml             Installs mise from its COPR, and activates it system-wide
    dev-tools.yaml        A developer's packages: toolchain, shells, containers
    browsers.yaml         Chrome and Brave Origin, from their vendors' repositories
    codecs.yaml           RPM Fusion, and the full media codecs
    desktop.yaml          GNOME packages, Flatpaks, extensions, and the window buttons
    fonts.yaml            Noto, Liberation, DejaVu, Roboto, the Microsoft core fonts, Selawik
    vm-tuning.yaml        Kernel VM tuning for zram swap, via /etc/sysctl.d
    zram.yaml             zram swap compressed with lz4
    files/
      mise.sh             The /etc/profile.d hook mise.yaml installs
      selawik-segoe.conf  The fontconfig rules fonts.yaml installs for Segoe UI
      vm-tuning.conf      The sysctl.d file vm-tuning.yaml installs
      zram-compression.conf  The zram-generator drop-in zram.yaml installs
scripts/
  check.sh                Lints the manifests, and plans them with --apply
docs/
  comtrya-behaviour.md    What the pinned comtrya actually does, checked by running it
  adding-a-manifest.md    How to add one, and what to check before committing
.agents/skills/           An agent skill for working in this repository
```

Manifests are named by their path below `manifests/`, with dots instead of slashes:
`manifests/base/comtrya.yaml` is `base.comtrya`. That name is what `-m` selects and what
`depends` refers to.

`manifests/base/` is everything every machine gets, unconditionally. Manifests that apply
to some machines but not others go in a directory of their own and say so. Two conditions
cover most of it, since `where` is evaluated per machine:

```yaml
# manifests/role/gpu.yaml: only where something set FLEET_ROLE=gpu in the environment
where: env.FLEET_ROLE == "gpu"
```

```yaml
# manifests/host/office.yaml: only on one machine
where: os.hostname == "office-catchyos"
```

Or prefer to leave the choice to the run, with `labels` and `--label`:

```yaml
# manifests/role/laptop.yaml, applied with `comtrya ... apply --label laptop`
labels:
  - laptop
```

`--label` is a filter over the whole run, not an addition to it: naming a label runs the
manifests that carry it **and nothing else**. Unlabelled manifests are skipped too, so
`apply --label laptop` on a fresh machine installs comtrya not at all. Label the manifests
that a label-selected run must include, or select with a `where` instead. Without
`--label`, every manifest runs and labels are ignored.

New directories need no registration: comtrya walks `manifests/` recursively and applies
everything it finds, skipping a manifest whose `where` is false. A manifest that fails stops
the manifests that `depends` on it, not the others, so problems in one area do not hide
another.

Each run is idempotent, so the manifests describe the desired state and never a sequence
of commands to replay.

## Making a change

Read [`docs/adding-a-manifest.md`](docs/adding-a-manifest.md) before adding a manifest.
Then:

```sh
./scripts/check.sh --apply
```

That lints the manifests and asks comtrya to plan every one. It catches a manifest that
can't be parsed or planned, but not one that quietly does nothing, so also read the run:

```sh
comtrya -d manifests apply      # then run it again: the second run must be a no-op
```

Note that global options go before the subcommand (`comtrya -v -d manifests apply`), and
that neither a skipped manifest nor a typo'd `-m` sets a failing exit status. Both are in
[`docs/comtrya-behaviour.md`](docs/comtrya-behaviour.md), which records where the pinned
version disagrees with its published documentation — heeding it saves an afternoon.

## Initializing a new machine

Fedora ships `git` and `curl`, which is all this needs:

```sh
git clone https://github.com/<you>/fedora-fleet.git ~/Code/fedora-fleet
~/Code/fedora-fleet/bootstrap.sh
```

Comtrya asks for your password once, when the first step that needs root runs. To see
what a run would change without changing anything:

```sh
~/Code/fedora-fleet/bootstrap.sh --dry-run
```

`bootstrap.sh` passes its arguments through to `comtrya apply`, so `-m`, `--label` and
`--dry-run` work as they do with comtrya — including `--label` narrowing the run to the
labelled manifests (see above), which on a fresh machine installs neither comtrya nor
anything else in `base/`.

### On an already-provisioned machine

```sh
comtrya -d https://github.com/<you>/fedora-fleet#main:manifests apply
```

Comtrya clones the repository itself, updates the clone on every run, and runs the
manifests in `manifests/` on that branch. No checkout is needed, and no `git`.

Two things are worth knowing about running from a URL:

- `Comtrya.yaml` is read from the working directory, never from the clone, so only what is
  inside `manifests/` travels with the URL. Nothing here depends on the config, but a
  manifest added later must not read a variable from it.
- `--dry-run` and `comtrya status` are the cheap way to check a change before applying it.
  A `command.run` step is not executed in a dry run, though, so it cannot report what it
  would do — the pinned comtrya install is one such step.

## How comtrya is installed

`manifests/base/comtrya.yaml` pins the version, downloads it once into
`/usr/local/lib/comtrya/<version>/`, and points `/usr/local/bin/comtrya` at it with a
symlink.

The indirection is not incidental. Comtrya's `file.copy` and `file.download` write a file
in place, and Linux refuses to write to a program that is running (`Text file busy`). So a
manifest that downloaded a new release over the binary applying it would fail precisely
when an upgrade is due — the one run where it matters. Writing each version to its own
directory and moving a symlink never touches the running file, and it leaves the previous
version on disk to go back to.

The download is comtrya's own `install.sh`, which picks the asset for the machine's CPU and
verifies it against the SHA-256 GitHub records for the release. The version is written
once, at the top of the manifest, and both the download and the symlink read it from there.

To upgrade, change `comtrya_version` in that manifest, then let a run install it. Once
nothing points at an old version, remove it:

```sh
rm -rf /usr/local/lib/comtrya/v0.10.0
```

## Browsers

`manifests/base/browsers.yaml` installs Google Chrome and Brave Origin, both from their
vendors' repositories.

Chrome's repository is defined but disabled. Its definition ships in
`fedora-workstation-repositories`, which the manifest installs rather than assumes — a
Workstation image has it already, and one that does not would otherwise have no such
repository to enable. The manifest then enables it with `dnf config-manager enable` and
installs `google-chrome-stable`.

Brave's is added from `https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo`.
That repository carries both `brave-browser` and `brave-origin`; the manifest installs
Origin, the standalone build. Brave makes Origin free on Linux, though it is a one-time
purchase elsewhere.

Both repositories are fetched over https and both keep `gpgcheck=1`, so the packages are
verified against the vendor's key. Adding Brave's repository is guarded, and enabling
Chrome's does not need to be: `dnf config-manager addrepo` exits 1 when the repo file is
already there, while `enable` is happy to repeat. See
[`docs/comtrya-behaviour.md`](docs/comtrya-behaviour.md).

## Media codecs

Fedora ships only the free-software codecs: `ffmpeg-free` and the `gstreamer1-plugins-*-free`
builds, which cannot handle H.264, H.265, AAC or MP3. `manifests/base/codecs.yaml` installs
RPM Fusion's unrestricted builds instead, so video and audio play out of the box.

The manifest enables both of RPM Fusion's repositories from their release packages, installs
the appstream data that lists those packages in a desktop software centre, and then swaps in
`ffmpeg`, `libavcodec-freeworld`, `gstreamer1-plugins-bad-freeworld` and
`gstreamer1-plugins-ugly`.

The swap needs `extra_args: [--allowerasing]`. The RPM Fusion packages conflict with Fedora's
instead of obsoleting them, so dnf refuses the transaction until it may remove what is
installed. It removes the eight `-free` packages — `ffmpeg-free`, and the `-free` variants of
libavcodec, libavdevice, libavfilter, libavformat, libavutil, libswresample and libswscale —
and nothing else. Afterwards a second run is a no-op.

The release packages are fetched by URL, with the Fedora version read from `os.version`
rather than written down: `$releasever` is not expanded in an argument, since comtrya runs
dnf without a shell. Installing one is already a no-op once present. See
[`docs/comtrya-behaviour.md`](docs/comtrya-behaviour.md).

## Desktop

`manifests/base/desktop.yaml` installs the desktop's own tools and turns on the GNOME
extensions a workstation is expected to have.

Tweaks, the Extensions app and GNOME Firmware are distribution packages, as are Piper and
`libratbag-ratbagd` — the GUI and the daemon that let a mouse or keyboard be configured.
GNOME Firmware is the fwupd front end for listing devices and the firmware updates they have.
Gearlever, Zed and Pika Backup come from Flathub instead, since each is published there by
its own project: Gearlever keeps AppImages updated, Zed is the editor, and Pika Backup is the
restic front end. Fedora ships Flathub as a filtered remote and all three are in that
allowlist, so the remote is left as it is; on a Fedora without one, the manifest adds the
full remote.

Three of the four extensions are Fedora packages, built against the GNOME Shell the release
ships: Dash to Panel, Blur my Shell and Caffeine. Tiling Shell has no Fedora package, so it is
fetched from extensions.gnome.org, pinned to version 77 with a `sha256` and unpacked
system-wide into `/usr/share/gnome-shell/extensions`. Installing a Fedora extension package
does not enable it, so the manifest enables all four itself.

The bundle stores its files with modes meant for an author's machine — `metadata.json` as
`0600`, the rest as `0777` — and `unzip` restores them, so the unpack step normalises them.
Without that, the user's shell could not read `metadata.json`, and every local account could
rewrite code the shell loads. Installing an extension while a session is running does not
make it appear either: the shell scans those directories at startup and cannot be restarted
in place on Wayland, so the first apply needs a logout and login.

`enabled-extensions` is a per-user key, so that step applies to the account running the
manifest, not to the machine. It reads the current list and adds only the UUIDs that are
missing, leaving anything the user had already enabled alone, and a second run finds all four
and writes nothing. The shell picks the change up, but extension code is read as the shell
loads it, so a newly installed extension starts working at the next login. The same section
sets `button-layout` to `appmenu:minimize,maximize,close`: Fedora's `appmenu:close` has no
minimize or maximize button.

Both `gsettings` steps are `command.run`, because comtrya has no action for them. They are
guarded on the value they would write, which is what keeps the second apply a no-op. See
[`docs/comtrya-behaviour.md`](docs/comtrya-behaviour.md) for the Flatpak and `gsettings`
behaviour they depend on.

## Fonts

`manifests/base/fonts.yaml` installs the font families a workstation actually renders, in
several groups.

Noto, but not all of it: `google-noto-fonts-common`, `google-noto-sans-fonts`,
`google-noto-serif-fonts` and `google-noto-color-emoji-fonts`. The `google-noto-fonts-all`
metapackage is 263 packages and 395 MiB of script coverage — CJK, historic scripts, musical
notation — that nothing here asks for.

Liberation and DejaVu. Liberation is the metric-compatible set: it has the same advance
widths as Arial, Times New Roman and Courier New, so a document laid out for those does not
reflow. `liberation-fonts` resolves to the `liberation-fonts-all` metapackage. DejaVu is the
broad Unicode fallback that fills in the glyphs the metric fonts leave out.

Roboto, from `google-roboto-fonts`. It is a named fallback in the font stack most
cross-platform interfaces list — the family after the system UI font and before the
generics, as in `"Segoe UI", Roboto, "Noto Sans", sans-serif`. Installed, such a stack
resolves to it; without it, the same stack skips the entry the author intended and renders
in Noto Sans. That is a different job from the metric substitutes above, which catch a name
nothing else provides.

It needs no alias, because the requested name is the family name; nothing in fontconfig
references Roboto, and installing the package is enough. The siblings are left out:
`google-roboto-condensed-fonts`, `google-roboto-slab-fonts` and `google-roboto-mono-fonts`
declare families of their own (`Roboto Condensed`, `Roboto Slab`, `Roboto Mono`), which no
stack falls back to from `Roboto`.

Microsoft's core fonts for the web — Arial, Times New Roman, Verdana, Georgia, Trebuchet,
Courier New, Comic Sans, Impact, Andale Mono and Webdings — are the ones a web page or a
Word document actually specifies, so the manifest installs them for real rather than relying
on a substitute.

Those last ones are where the manifest does something unusual. They normally come from
`msttcore-fonts-installer`, which comtrya cannot install: the RPM carries neither a digest
nor a signature, and the `--nodigest` flag that skips that check is an `rpm` option that
dnf5 rejects. The only dnf5 route is `--setopt=tsflags=nocrypto`, which disables digest
verification for the entire transaction, not just that archive. See
[`docs/comtrya-behaviour.md`](docs/comtrya-behaviour.md).

The RPM is a thin wrapper in any case. Its payload "fonts" are 7-byte files containing the
word `filler`; the postinstall downloads the real ones over plain HTTP and then exits 0 even
when that fails. So the manifest does the work itself: `file.download` fetches the eight
archives over https with a pinned `sha256` each, and a guarded `command.run` unpacks them
with `cabextract` into `/usr/share/fonts/msttcore`.

The guard checks for all thirty expected faces and rejects a placeholder, so a machine where
the RPM's postinstall failed — filenames present, real files absent — is repaired rather than
mistaken for done. An archive that does not match its checksum fails the download, and a
missing one fails the extraction, rather than leaving a partially populated font directory.
fontconfig scans `/usr/share/fonts` recursively, so no font path or index has to be
registered.

The manifest also installs **Selawik**, Microsoft's own open replacement for Segoe UI, under
the SIL Open Font License. Segoe UI is the family Windows-authored documents and UI mockups
name, so it is the substitute most likely to be asked for by a file that makes no sense on
Linux otherwise.

Fedora ships neither the font nor a COPR for it, so the binaries come from upstream's only
release — a 530 KB web-format zip whose `.ttf` files sit among `.eot`, `.svg` and `.woff2`
siblings. `file.download` pins it by `sha256` and a guarded `command.run` extracts just the
five faces with `unzip`. Upstream's README notes two open issues, missing kerning against
Segoe UI and imperfect hinting, so it is a close substitute rather than an exact one.

Installing the family is not enough on its own. Fedora's `45-latin.conf` routes Segoe UI to
`system-ui`, which resolves to the desktop's own UI font, so a document asking for Segoe UI
would keep getting Adwaita Sans. `files/selawik-segoe.conf` is copied to
`/etc/fonts/conf.d/62-selawik-segoe.conf` to substitute Selawik for it, and also for
`Segoe UI Webfont`, the family name Microsoft's own webfont kit declares.

The rule uses `match`/`edit` with `mode="assign"` rather than an `<alias>` with `<prefer>`:
an alias carries a single family name, and `prefer` can only reorder candidates already in
the request — there is nothing for it to reorder onto a font the application did not name.
`assign` with `binding="same"` swaps the family in place, leaving the rest of the caller's
family list intact so glyphs Selawik lacks fall through to it. Neither the rules nor the
font files need an `fc-cache` run: fontconfig re-reads `conf.d` per program and scans font
directories on demand, so the manifest has no step that would report drift on every apply.

## How mise is installed

`manifests/base/mise.yaml` installs mise from the `jdxcode/mise` COPR, since Fedora does not
carry it, and then activates it for every user.

Enabling a COPR is a `command.run`, not `package.repository`: comtrya's dnf provider calls a
`config-manager` option that dnf5 removed, so the action fails. The step is guarded on the
repository already being configured, because `dnf copr enable` contacts the Copr server and
rewrites the `.repo` file every time it runs. See
[`docs/comtrya-behaviour.md`](docs/comtrya-behaviour.md).

Activation is a file in `/etc/profile.d/` rather than a line appended to each user's dotfile,
because the package is system-wide. The file runs `mise activate` at shell startup instead of
containing its output: that output names the calling user's own shims directory, so a
generated file would point every user at whoever ran the manifest. Bash and zsh are handled;
other shells are left alone.

It gives the two kinds of shell different things, as mise recommends:

- **A login shell gets shims on `PATH`** (`mise activate --shims`). Anything started from it
  — an editor, an IDE, a script that never reads a shell startup file — then finds mise's
  tools through `~/.local/share/mise/shims`. One `PATH` entry, no per-prompt work.
- **An interactive shell gets full activation**, which follows the directory on `cd` and
  exports the project's `[env]` variables into the shell itself.

The difference is visible: in a project with `[env] FOO` set, an interactive shell sees
`$FOO`, a login shell does not — but a shimmed command run from that login shell does, since
a shim resolves the environment each time it runs. Shims resolve the version from the current
directory too, so a non-interactive login shell still gets the right `node` inside a project.

Fedora sources `profile.d` exactly once per shell — from `/etc/profile` for a login shell,
and from `/etc/bashrc` or `/etc/zshrc` for an interactive one that is not — so a single file
cannot go in a "login" one and an "interactive" one without being skipped somewhere. It tells
the modes apart instead, with `shopt -q login_shell` and `[[ -o login ]]`.

The zsh branch needs `emulate -L zsh` before the full activation only: Fedora sources
`profile.d` inside `emulate -L ksh`, and mise's zsh code uses `(( $+functions[...] ))`, which
is not arithmetic test syntax in ksh. Without the `emulate`, every zsh startup prints `bad
output format specification` once for each of those tests — five lines in mise 2026.11.11.
Activation still works, which is what makes it easy to miss. `--shims` is a plain `export`
and needs no such care.

Verify with `mise doctor`: an interactive shell reports `activated: yes` and a login shell
reports `activated: no`, which is expected — it has the shims on `PATH` rather than PATH
activation. The `path:` section of the same output lists `~/.local/share/mise/shims` in a
login shell. A shell needs a fresh login to pick the file up.

## zram swap

`manifests/base/zram.yaml` switches zram's compressor from the kernel default, `lzo-rle`, to
`lz4`. Fedora Workstation's `zram-generator-defaults` creates `/dev/zram0` at
`min(ram, 8192)` and leaves the compressor alone, so the manifest installs that package and
adds a drop-in that changes only the algorithm.

lz4 is a deliberate trade: it compresses and decompresses faster than lzo-rle at a slightly
worse ratio. For swap that is usually the right side of the trade, because decompression
sits on the page-fault path while the ratio mostly buys swap capacity that never gets used.

The drop-in is in `/etc/systemd/zram-generator.conf.d/` rather than a
`/etc/systemd/zram-generator.conf`, because the main config file **replaces** the vendor one
instead of merging with it; writing it would silently drop the size setting.

The kernel will not change the compressor of an initialized device, so the last step
releases the swap and lets systemd set the device up again when the algorithm differs.
That is what makes the change take effect without a reboot.

Once the fleet goes back to zswap, delete this manifest along with the package it installs.
The drop-in is not harmless on its own: the generator creates a device for any `[zramN]`
section it finds, so leaving it behind would create zram swap at the generator's default
size on a machine that is supposed to use zswap.

## VM tuning

`manifests/base/vm-tuning.yaml` installs `/etc/sysctl.d/99-vm-tuning.conf` and loads it into
the running kernel, so a machine converges without a reboot. systemd-sysctl reads the same
file at boot; the `99-` prefix sorts it after the vendor files in `/usr/lib/sysctl.d` and
after Fedora's `99-sysctl.conf` symlink.

The values assume swap is zram, which it is on Fedora Workstation. Swapping is cheap there,
so `vm.swappiness = 100` treats swap and page cache as equal rather than penalising swap.
`dirty_bytes` and `dirty_background_bytes` bound writeback in absolute terms instead of as a
percentage of RAM, which matters because Fedora's defaults scale with memory size.
`watermark_scale_factor`, `watermark_boost_factor`, `compaction_proactiveness` and
`defrag_mode` give kswapd more room and keep higher-order blocks available.

Dirty limits are written as bytes only. `dirty_bytes` and `dirty_ratio` are mutually
exclusive — writing either zeroes the other — so writing the ratio after the byte limit
would clear it and leave both at zero, throttling at the first dirty page. The ratios read
back as 0 on their own.

The load step is a guarded `command.run`, because the kernel offers no way to tell whether a
write changed a value. It reads each key back from `/proc/sys` and only runs `sysctl -p` when
something differs, which is what makes the second apply a no-op.

## Conventions

- **Pinned, not floating.** The comtrya version is explicit, and checksums are handled by
  comtrya's own installer, so no download is unverified.
- **Idempotent by construction.** Prefer actions that check for drift (`package.install`,
  `file.copy`, `file.link`, `directory.create`) over `command.run`, and guard the ones that
  have no check of their own with a test, as the install step does.
- **Claims are tested.** Everything in [`docs/comtrya-behaviour.md`](docs/comtrya-behaviour.md)
  was confirmed by running the pinned version. The published documentation describes `main`,
  so where the two disagree the file in this repository wins.
- **Legible first.** A reader should be able to tell what a machine gets, and why, without
  running anything.

## Requirements

Fedora 45 or a close relative. Nothing here is specific to a minor release, but the
repository assumes `dnf`, `systemd` and a `/usr/local` prefix.

Checking a change needs `curl`, plus `git` for the URL form. `scripts/check.sh --apply`
needs comtrya itself, and takes its path from `COMTRYA` when it is not on `PATH`.
