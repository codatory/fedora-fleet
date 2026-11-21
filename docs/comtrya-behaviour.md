# comtrya behaviour notes

Everything here was checked against the comtrya version pinned in
`manifests/base/comtrya.yaml` (v0.11.0), by running it. The published documentation at
<https://comtrya.dev> is generated from `main` and describes some behaviour that has not
been released, so where the two disagree this file wins. Update it when the pin moves.

The entries most likely to cost an afternoon are the silent failures and the actions that
never become a no-op, so they come first.

## Silent failures

These fail quietly, with exit status 0. They are the reason to prefer checking a run's
output over trusting its exit code.

| Situation | What happens |
|---|---|
| `where` names a context key that doesn't exist | The condition is false. The manifest is skipped with one INFO line. |
| `where` has a syntax error | Logs a WARN, treats it as false, skips the manifest. Exit 0. |
| `-m` names a manifest that doesn't exist | Nothing runs, nothing is said. Exit 0. |
| `depends` names a manifest that doesn't exist | ERROR, and the dependent is skipped. Exit 1. |

The first two are the dangerous ones, because a `where` on a key that was renamed or never
existed silently disables a manifest forever. `os.arch` is exactly that: documented on the
site, absent from v0.11.0. Confirm a key exists before depending on it:

```sh
comtrya contexts --show-values
```

## Command line

Global options must come **before** the subcommand. The documentation says either order
works; it does not:

```sh
comtrya -v -d manifests apply      # works
comtrya -d manifests apply -v      # error: unexpected argument '-v' found
comtrya apply -d manifests         # error: unexpected argument '-d' found
```

`apply` has its own options, which do come after it: `-m/--manifests`, `--dry-run`,
`-l/--label`, `-j/--jobs`. `-j` defaults to 1; more than that runs manifests whose
dependencies are satisfied at the same time, while steps that touch the same file or package
database still take turns. Leave it alone unless a run is slow for no other reason — the log
of a parallel run is interleaved and harder to read.

### `--label` selects, it does not add

`--label laptop` runs the manifests whose `labels` include `laptop` **and skips every other
manifest**, including those with no `labels` at all:

```
INFO base.comtrya: Skipping manifest, label not found label="laptop"
```

So a label-selected run on a fresh machine installs nothing under `base/`, comtrya
included, and a dependency is no help: `depends` is followed inside the selected set, and an
unlabelled dependency is skipped just like any other. Without `--label`, labels are ignored
and every manifest runs.

Two consequences for this repository:

- Nothing in `base/` should rely on a labelled manifest having run, and a manifest that
  gates with `labels` must not carry anything `base/` needs.
- `where` is the safer gate. Only one `--label` may be given (`cannot be used multiple
  times`, exit 2), and a comma-separated list is matched literally rather than as a set, so
  selecting a combination of labels is not possible.

`status` takes `--label` too, and ignores it — it lists every manifest either way, so it is
not a way to preview what a labelled run would do.

`-d` replaces `manifest_paths` from `Comtrya.yaml` entirely, and is resolved against the
current directory.

### `Comtrya.yaml` is only read from the current directory and `~/.config`

It is never read from a manifest directory, including a git clone. So:

- Running from a checkout at the repository root picks up `Comtrya.yaml`.
- Running from elsewhere with `-d /path/to/manifests` does **not**.
- Running from a git URL (`-d https://...#main:manifests`) does **not**.

Only what is inside `manifests/` travels with a URL, which is why this repository keeps
values in the manifests and not in `Comtrya.yaml`.

`manifest_paths` in `Comtrya.yaml` is relative to that file, not the current directory.

## Manifest naming

A manifest's name is its path below the manifest directory, dots for slashes, without the
extension: `manifests/base/comtrya.yaml` is `base.comtrya`. That name is what `-m` takes and
what `depends` refers to.

In `depends`, `./` means the manifest's own directory. Both of these work:

```yaml
# in manifests/base/comtrya.yaml, or any top-level manifest
depends: [base.other]
# in manifests/base/other.yaml
depends: [./comtrya]        # resolves to base.comtrya
```

`depends: [comtrya]` from inside `base/` does **not** resolve — a name without `./` is
absolute from the manifest root. Slashes never work.

A label-selected run filters the graph as it walks it, so a dependency that doesn't carry the
label is skipped rather than pulled in. See `--label` above.

### What counts as a manifest

Files ending in `.yaml`, `.yml` or `.toml`, below the manifest directory, at any depth. In
particular:

- A `.yml` file is loaded exactly like `.yaml`; both are manifests.
- A directory named `files` is skipped entirely, at any depth. That is why `files/` beside a
  manifest can hold YAML that isn't a manifest — including nested directories under it.
- The `Comtrya.yaml`/`.yml`/`.toml` beside the manifests is the config, not a manifest.

`scripts/check.sh` follows the same rules for YAML, so its lint matches what comtrya will
load. `.toml` manifests are not linted: this repository does not use them.

Dependencies run first. If one fails, its dependents are skipped, the rest of the run
continues, and the exit status is 1.

## Idempotency by action

Checked by running the same manifest twice and reading the second run's output.

| Action | Second run |
|---|---|
| `directory.create` | no-op |
| `file.copy` | no-op (content and `chmod`) |
| `file.link` | no-op, replaces a stale or broken symlink |
| `file.download` | no-op only with `sha256`; **without it any existing file is kept**, even a wrong one |
| `package.install` | no-op for installed packages |
| `git.clone` | no-op if the directory exists; never fetches updates |
| `binary.github` | no-op if `directory/name` exists; **cannot pin**: an existing file of any version is kept |
| `command.run` | **always runs** — idempotency is your problem |
| `directory.copy` | **always copies** — `check` always reports drift |

`command.run` is the workhorse and also the thing that breaks idempotency. Guard it with a
test in the command itself, the way `manifests/base/comtrya.yaml` does:

```yaml
- action: command.run
  command: sh
  args:
    - -c
    - |
      set -eu
      if [ -x /some/thing ]; then exit 0; fi
      do_the_actual_work
```

`set -eu` matters: without `-e` a failing command inside the script is ignored and the step
reports success.

`directory.copy` re-copies every run. It is safe (the result is the same) but it is not a
no-op, and it will overwrite files under `to`. Prefer `file.copy` for individual files.

## Actions that surprise

**`binary.github`** can't pin a version. It skips the download when `directory/name` exists,
whatever version is there, so bumping `version` does nothing on a machine that has the file.
It also does not create `directory`. Use it only for "any version is fine".

**`file.download`** without `sha256` keeps whatever file is already there. With `sha256`,
a mismatched file is re-downloaded and a good one is left alone, which is what makes version
pinning work. Checksums come from the release page; comtrya requires 64 hex characters.

**`file.copy`** and **`file.download`** write in place. Linux returns `Text file busy` when
you write to a running executable, so a manifest cannot replace the comtrya binary that is
running it. This is why comtrya is installed to a versioned directory with a symlink.

**`file.copy` creates the parent directory** of `to` when it is missing, so a nested target
such as `/etc/systemd/zram-generator.conf.d/99-compression.conf` needs no separate
`directory.create`. Checked by copying into a path whose directories did not exist, then
looking for the file.

**`file.copy`** accepts an absolute `from`, which bypasses the `files/` directory. Relative
`from` paths are resolved under the manifest's sibling `files/` directory, and the file must
be there at plan time, or the action fails — including under `--dry-run`.

**`file.link`** fails at plan time if its `source` doesn't exist yet, absolute or not, so it
cannot link to something a later step creates. Link only to files that are already in the
repository's `files/` directory, or use `command.run` with `ln -sfn` for a target that is
produced during the run (which is what the install manifest does).

**`package.install`** with an explicit `provider` different from the host's provider warns
`dnf not available` and does nothing. Omit `provider` and let comtrya choose; it reports its
choice in `comtrya contexts` under `packages.provider`.

**`package.repository`** does not work for dnf on Fedora 45. Its dnf provider runs
`dnf config-manager --add-repo <name>`, and dnf5 dropped `--add-repo`, so the step fails:

```
CommandExec with: dnf config-manager --assumeyes --add-repo <name> (as root) failed:
Unknown argument "--add-repo" for command "config-manager".
```

Run it by hand and dnf5 exits 0 on that same error, so it fails silently outside comtrya.
Add a repository with `command.run` instead, and guard it, because the command that enables
one is not always a no-op. For a COPR:

```yaml
- action: command.run
  command: sh
  privileged: true
  args:
    - -c
    - |
      set -eu
      if grep -rqs 'copr.fedorainfracloud.org/results/<owner>/<project>' /etc/yum.repos.d/; then
          exit 0
      fi
      dnf copr enable -y <owner>/<project>
```

`dnf copr enable` rewrites the `.repo` file and contacts the Copr server every time it runs,
so without the guard it is not idempotent even though the result is the same. The `copr`
command comes from `dnf5-plugins`, which is present on the Fedora workstation image this was
checked against.

**`dnf config-manager addrepo`** is not idempotent either. Against a repo file that already
configures the same IDs it exits **1**:

```
File "/etc/yum.repos.d/<name>.repo" already exists and configures repositories with IDs
"<id>". Add "--overwrite" to overwrite.
```

Under `set -eu` that fails the step, so a manifest that adds a repository this way fails on
its second run. `--overwrite` is not the fix: it exits 0 but refetches and rewrites the file
every time, so the step never becomes a no-op. Guard on the repo file instead, the way the
COPR example above does.

`dnf config-manager enable <repo-id>` is fine unguarded: re-enabling an enabled repository
exits 0 and leaves its override file alone.

One way to misread this: piping the command through `tail` or `grep` reports the exit status
of the last command in the pipe, not dnf's. `dnf ... | tail -3; echo $?` shows 0 for a failure.

### `$releasever` in a package URL

comtrya runs `dnf` directly, without a shell, so a URL given as a package name is passed
through literally: `.../rpmfusion-free-release-$releasever.noarch.rpm` stays
`$releasever` and 404s. There is no shell to expand it, and dnf only substitutes
`$releasever` in its own repo configuration, not in arguments.

Read the version from the machine instead. `os.version` is the full version (`45.0.0` on
Fedora 45), so take the first component:

```yaml
- action: package.install
  list:
    - "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-{{ os.version | split(pat='.') | first }}.noarch.rpm"
```

Use single quotes inside the Tera expression. A YAML string is already double-quoted, and
`pat=\"\.\"` inside it is a Tera parse error rather than an escaped quote.

### Replacing a package that conflicts rather than obsoletes

`ffmpeg` from RPM Fusion conflicts with Fedora's `ffmpeg-free` instead of obsoleting it, so
dnf refuses the transaction (`installed package ffmpeg-free conflicts with ffmpeg-free
provided by ffmpeg`) until it may remove what is installed. `extra_args` is passed to `dnf
install` before the package names, so:

```yaml
- action: package.install
  extra_args: [--allowerasing]
  list:
    - ffmpeg
    - libavcodec-freeworld
```

`--allowerasing` is broad, and here it removed exactly the `-free` counterparts and nothing
else. Check the transaction the first time rather than assuming: `dnf install --assumeno
--allowerasing ...` lists what it will remove. A second run afterwards is a no-op.

## zram, zswap and reinitialising a device

Verified on Fedora 45 with zram-generator 1.2.1 and zram-generator-defaults. `zram.yaml`
depends on this.

**zram and zswap are different things, and Fedora Workstation uses zram.** zswap is a
compressed write-back cache in front of a disk swap device; zram is a compressed block device
used *as* swap. On this image zswap is present but disabled (`/sys/module/zswap/parameters/
enabled` is `N`, compressor `lzo`) and `/dev/zram0` is the only swap. So "change the zswap
compressor" means editing zram-generator, not `zswap.compressor`.

**The algorithm comes from `zram-generator-defaults`, not the kernel.** The kernel default is
lzo-rle (`CONFIG_ZRAM_DEF_COMP="lzo-rle"`), and
`/usr/lib/systemd/zram-generator.conf` from `zram-generator-defaults` sets only
`zram-size = min(ram, 8192)`, leaving `compression-algorithm` unset. Unset means the kernel
default is kept.

**A drop-in merges with the main config; the main config replaces it.** The generator reads
the first of `/run`, `/etc`, `/usr/local/lib`, `/usr/lib` `systemd/zram-generator.conf` — so
writing `/etc/systemd/zram-generator.conf` **hides** the vendor file rather than merging with
it, and drops `zram-size`. A file in `/etc/systemd/zram-generator.conf.d/` merges per key
with the vendor section:

```sh
# vendor: zram-size = min(ram, 8192)
# drop-in: compression-algorithm = lz4
# result: 8192MB, lz4
```

**A drop-in alone creates a device.** The generator creates one `/dev/zramN` per `[zramN]`
section it finds anywhere, so the same drop-in on a machine without
`zram-generator-defaults` creates a zram device at the generator default,
`min(ram / 2, 4096)` — a different size than the fleet means. This is why `zram.yaml`
installs the package explicitly, and why reverting to zswap means deleting the drop-in, not
just disabling it. Check without root using the generator's `ZRAM_GENERATOR_ROOT`:

```sh
ZRAM_GENERATOR_ROOT=/tmp/fake /usr/lib/systemd/system-generators/zram-generator /tmp/fake/out
```

**The compressor cannot be changed on an initialized device.** `comp_algorithm` returns
`EBUSY` once `disksize` has been written (`init_done`), and `reset` returns `EBUSY` while
anything has the device open. So a manifest has to release the swap first:

```sh
systemctl daemon-reload
systemctl stop dev-zram0.swap     # swapoff
systemctl start dev-zram0.swap    # re-runs the setup service
```

Stopping the swap unit runs `swapoff`, and the setup service's `ExecStop` (the device reset)
does not run before it because the swap unit is ordered `After=` the setup service. The
subsequent `start` re-runs `systemd-zram-setup@zram0.service`, which writes
`comp_algorithm` before `disksize` and then re-runs `systemd-makefs`. A failed `swapoff`
leaves the swap in place, so the risk is a failed step rather than a machine without swap.

`/etc/fstab` has no entry for `/dev/zram0`; the swap unit is generated from the config, so
editing the drop-in is the only thing to change.

**Secondary (recompression) algorithms are allowed on this kernel, but nothing drives
them.** `CONFIG_ZRAM_MULTI_COMP=y` on the installed 7.3.4 kernel, so
`/sys/block/zram0/recomp_algorithm` exists and `comp_algorithm` accepts up to four
priorities (`ZRAM_PRIMARY_COMP` 0 and secondaries 1–3). zram-generator reads the same
`compression-algorithm` list as priorities: `compression-algorithm = lz4 zstd` sets lz4
primary and zstd as secondary 1, and writes `recomp_algorithm` for everything after the
first. `recomp_algorithm` is empty here because no secondary is configured.

Two things make it useless as configured, and both have to change before adding one:

- **Nothing triggers recompression.** The kernel only recompresses when `recompress` is
  written, and nothing on a stock Fedora 45 does that — there is no workqueue, timer or
  unit behind it, and zramctl has no recompression option, only `--reset`. So a secondary
  algorithm would sit configured and unused.
- **Idle recompression needs page-age tracking, which is off.** `type=idle` and
  `type=huge_idle` only select pages already flagged `ZRAM_IDLE`, and
  `echo <age> > idle` returns `EINVAL` without `CONFIG_ZRAM_TRACK_ENTRY_ACTIME`
  (`not set` here). Only `echo all > idle` works, which is a manual marking, not an age
  policy.

`type=huge` does not need idle tracking, so a `recompress` step could target incompressible
pages right after boot. It is not worth adding until there is a measurement showing those
pages are the exception rather than the rule: at 4K of data in the device, there is nothing
to recompress yet.

**`vm.page-cluster = 0` is a real no-readahead setting**, not a special case to memorise:
`mm/swap_state.c` computes `max_pages = 1 << page_cluster` and returns 1 when that is `<= 1`.
The default of 3 reads eight pages per swap-in fault. That batching pays for seek cost,
which zram swap does not have, so the batch mostly decompresses neighbours the fault may not
need. It only helps a swap-heavy workload if those neighbours turn out to be needed; the
knob is a latency trade either way, not a free win.

## sysctl files and `command.run`

Verified with procps-ng 4.0.6 on Fedora 45 (kernel 7.3.4). `vm-tuning.yaml` depends on all
of this.

**`sysctl -p file` only accepts `key = value`.** A `key: value` line — the form used in
blog posts and in some examples — is rejected with `invalid syntax, continuing...` and the
line is skipped, yet the command still exits **0**. A whole file written with colons loads
nothing and reports success. `sysctl --dry-run -p file` prints the `key = value` lines it
parsed, which is the quickest way to see that a line was dropped.

**An unknown key exits 1 and the rest of the file still applies**, so a manifest file whose
keys are missing on an older kernel fails the step rather than silently doing part of the
job. `-e` suppresses that and makes an unknown key a no-op, which is the wrong choice for a
manifest: it would hide a typo forever.

**`sysctl -p` has no way to report whether it changed anything.** It prints the values it
wrote, which it also does when the value was already correct, so its output cannot gate a
second run. There is no `--check`. The guard has to read the keys back from `/proc/sys`
first, as `vm-tuning.yaml` does:

```sh
differs=0
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}; value=${line#*=}
    current=$(sysctl -n "$(printf '%s' "$key" | tr -d '[:blank:]')")
    [ "$current" = "$(printf '%s' "$value" | tr -d '[:blank:]')" ] || differs=1
done <"$conf"
if [ "$differs" -eq 0 ]; then
    exit 0
fi
sysctl -q -p "$conf"
```

Use that `if`, not a trailing `[ "$differs" -eq 0 ] && exit 0`. As the last line, that
and-list returns 1 when nothing differs, so the converged machine exits 1 and comtrya records
a failed step. `set -e` does not rescue it: the failing command is the last line of the
script, and its status becomes the script's.

**Dirty-memory `bytes` and `ratio` knobs are mutually exclusive.** Writing either zeroes the
other, and the handlers differ:

- `dirty_background_ratio_handler` zeroes `dirty_background_bytes` on **every** write, even
  one that does not change the value.
- `dirty_bytes_handler` zeroes `dirty_ratio` only when `dirty_bytes` actually changed.
  `dirty_ratio_handler` likewise zeroes `dirty_bytes` only on a change.

So a file that sets `dirty_background_bytes` and then `dirty_background_ratio = 0` — the
obvious way to write "bytes, not a ratio" — ends up with **both** zero, and the kernel
throttles writers at the first dirty page. Set the byte knobs alone; each ratio then reads
back as 0 because the kernel set it that way.

**`/etc/sysctl.conf` is a symlink to `/etc/sysctl.d/99-sysctl.conf`** on Fedora 45, so a file
named later than `99-` sorts after it. An earlier name cannot override Fedora's.

## Variants replace, they do not merge

A variant that applies is used *instead of* the action, not merged into it:

```yaml
- action: command.run
  command: echo
  args: [BASE]
  env: {MARKER: base}
  variants:
    - where: os.name == "linux"
      command: echo
      args: [VARIANT]        # `env` is gone: the whole action is the variant
```

Repeat every field a variant needs. A variant with no `where` never applies. An action's own
`where` being false does not stop a variant from applying.

A `where` on a single action skips just that action; the rest of the manifest still runs.

## Dry runs

`--dry-run` plans every action and reports what would change. It does **not** run
`command.run`, so a step implemented as a command reports nothing useful. `file.copy` shows
a diff. All actions are still planned, so a manifest that can't be planned fails the dry run
and the exit status is 1.

## Verification recipe

For a change that adds or edits a manifest:

```sh
comtrya -d manifests apply --dry-run     # plans, exits 1 on anything unplannable
comtrya -d manifests apply               # for real
comtrya -d manifests apply               # again: this run should be a no-op
```

If the second real run is not a no-op, the manifest isn't idempotent yet. Read its output
rather than its exit status: only a failed manifest, not a skipped or typo'd one, exits 1.
