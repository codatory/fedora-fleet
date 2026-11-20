---
name: comtrya-fleet
description: Add or edit comtrya manifests in this repository for Fedora workstations. Use when adding packages, files, binaries or system settings to the fleet, changing the pinned comtrya version, or debugging a manifest that does not apply, applies on the wrong machines, or is not idempotent.
---

# comtrya fleet

This repository is a comtrya manifest tree for a fleet of Fedora workstations. Your job is
to make a manifest change that is correct on every machine it applies to, and that a second
run leaves alone.

Read these two, at the repository root, before your first change.
`docs/comtrya-behaviour.md` records what the pinned comtrya version actually does, which
differs from its published documentation in ways that fail silently.
`docs/adding-a-manifest.md` is the human-facing version of the workflow below.

## Ground rules

1. **Verify against the pinned version, never the website.** The site documents `main`.
   `os.arch`, for example, is documented and does not exist in v0.11.0, so a `where` using
   it silently skips the manifest forever. Check a context key with
   `comtrya contexts --show-values`.
2. **Exit status 0 does not mean it worked.** A typo'd `-m`, a `where` on a missing key and
   a `where` with a syntax error all exit 0 while doing nothing. Read the output.
3. **Global options go before the subcommand.** `comtrya -v -d manifests apply`. `-v` after
   `apply` is an error, despite the documentation.
4. **A second apply must be a no-op.** That is the definition of done here.

## Workflow

1. Decide where the manifest belongs: `manifests/base/` for every machine, or a role/host
   directory with a `where`. Never gate something in `base/`.
2. Write the manifest. Start with the schema comment and `version: 1`. Prefer
   `package.install`, `file.copy`, `directory.create`, `file.link`; reach for `command.run`
   only when nothing else fits, and then guard it with a check and `set -eu`.
3. Verify:

   ```sh
   comtrya -d manifests apply --dry-run     # plans; exit 1 = cannot run
   comtrya -d manifests apply
   comtrya -d manifests apply               # must report nothing to do
   ```

4. If the manifest is gated, exercise the gate both ways with `--label` or an env var.
   `--label x` runs *only* labelled manifests, skipping unlabelled ones like `base.*`, so a
   label gate is not additive and cannot be combined with a second `--label`.
5. Update `docs/comtrya-behaviour.md` if you discovered behaviour it doesn't record.

## Things that will bite you

- `file.link` fails at plan time if `source` doesn't exist yet, absolute or not. To link to
  something produced during the run, use `command.run` with `ln -sfn`.
- `file.copy` and `file.link` resolve relative paths against a `files/` directory beside the
  manifest.
- `directory.copy` reports drift on every run; it is safe but never a no-op.
- `binary.github` keeps any existing file, so it cannot pin a version.
- `file.download` without `sha256` keeps any existing file, right or wrong.
- A variant *replaces* the action rather than merging: repeat every field it needs.
- `depends` uses dotted names (`base.comtrya`); `./name` means the manifest's own directory.
- Installing or replacing the running comtrya binary fails with `Text file busy`; that is why
  it is installed to a versioned directory and symlinked.

## Changing the pinned comtrya version

`manifests/base/comtrya.yaml` holds the version once, in `{% set comtrya_version %}`.
`bootstrap.sh` reads it from there. Change it in one place, then confirm the new release
supports anything the manifests rely on by checking
`https://github.com/comtrya/comtrya/releases` — do not assume `main`'s behaviour.

## Scope

Repository-specific work only. Do not commit, push, or change the git remote unless asked.
Do not edit files under `.commandcode/`.
