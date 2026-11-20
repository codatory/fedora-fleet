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
