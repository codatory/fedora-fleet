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

New directories need no registration: comtrya walks `manifests/` recursively and applies
everything it finds, skipping a manifest whose `where` is false or whose labels do not
match. A manifest that fails stops the manifests that `depends` on it, not the others, so
problems in one area do not hide another.

Note that `where` is evaluated by comtrya's condition engine, not rendered like the rest of
the manifest, so Tera functions such as `read_file_contents` are not available in it. Test
what is available with `comtrya contexts`.

Each run is idempotent, so the manifests describe the desired state and never a sequence
of commands to replay.

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
`--dry-run` work as they do with comtrya.

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

## Conventions

- **Pinned, not floating.** The comtrya version is explicit, and checksums are handled by
  comtrya's own installer, so no download is unverified.
- **Idempotent by construction.** Prefer actions that check for drift (`package.install`,
  `file.copy`, `file.link`, `directory.create`) over `command.run`, and guard the ones that
  have no check of their own with a test, as the install step does.
- **Claims are tested.** The manifests are validated against the comtrya version they pin,
  not against the documentation, which describes unreleased behavior: `os.arch`, for one,
  is documented but absent from v0.11.0.
- **Legible first.** A reader should be able to tell what a machine gets, and why, without
  running anything.

## Requirements

Fedora 45 or a close relative. Nothing here is specific to a minor release, but the
repository assumes `dnf`, `systemd` and a `/usr/local` prefix.
