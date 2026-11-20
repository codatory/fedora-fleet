# Adding a manifest

Read `comtrya-behaviour.md` first if you haven't. It lists the ways comtrya fails quietly,
which are the ways a mistake here survives unnoticed.

## Where it goes

```
manifests/
  base/       every machine, unconditionally
  role/       machines with a role, gated by a `where` or a label
  host/       a single machine, gated by `os.hostname`
```

`base/` is for things the fleet agrees on. Anything that would be wrong on some machine
belongs elsewhere, with a condition. Add a new directory freely — comtrya walks
`manifests/` recursively and needs no registration.

A machine gets a manifest when its `where` is true and, if the manifest has `labels`, when
the run passes the matching `--label`. Prefer a `where` for a property of the machine, and
`labels` for a choice the person running it makes.

```yaml
# manifests/role/gpu.yaml
version: 1
where: env.FLEET_ROLE == "gpu"
```

## Shape of a manifest

```yaml
# yaml-language-server: $schema=https://comtrya.dev/schema.json
version: 1

# One sentence on what this manifest is for, and any condition that is not obvious.
where: os.name == "linux"

actions:
  - action: package.install
    list:
      - ripgrep
      - fd-find
```

Every manifest starts with the schema comment so editors validate it, and `version: 1`.

## Choosing an action

Prefer the action that knows how to check itself, in roughly this order:

| Need | Action | Idempotent |
|---|---|---|
| Packages | `package.install` | yes |
| A config file | `file.copy` | yes, including `chmod` |
| A directory | `directory.create` | yes |
| A symlink to a file in `files/` | `file.link` | yes |
| A pinned release from a URL | `file.download` with `sha256` | yes, with `sha256` |
| Anything else | `command.run` | no, unless guarded |

`command.run` is the escape hatch, not the default. When you reach for it, make it check:

```yaml
- action: command.run
  command: sh
  args:
    - -c
    - |
      set -eu
      command -v some-tool >/dev/null 2>&1 && exit 0
      do_the_work
```

`set -eu` is not optional. Without `-e` a failure inside the script is swallowed and the
step reports success.

Do not use `binary.github` for anything you want pinned: it keeps whatever version is
already on disk. See the behaviour notes.

## Files next to the manifest

`file.copy` and `file.link` resolve a relative `from`/`source` against a `files/` directory
**beside the manifest**:

```
manifests/role/gpu.yaml
manifests/role/files/nvidia.conf     # `from: nvidia.conf` in gpu.yaml
```

`files/` is never parsed as manifests, so it is the place for anything that looks like YAML
but isn't one.

Set `template: true` to render the file with the comtrya contexts:

```yaml
- action: file.copy
  from: gitconfig.tmpl
  to: "{{ user.home_dir }}/.gitconfig"
  template: true
```

## Test it

```sh
comtrya -d manifests apply --dry-run     # plans; exit 1 means it cannot run
comtrya -d manifests apply -v            # `-v` before `apply`, not after
comtrya -d manifests apply               # must be a no-op
```

Read the output rather than the exit status. A skipped manifest, a typo'd `-m` and a
`where` on a misspelled key all exit 0 without doing anything.

When a manifest is gated, confirm both branches work:

```sh
comtrya -d manifests apply --label laptop --dry-run
FLEET_ROLE=gpu comtrya -d manifests apply --dry-run
```

## Checklist

- [ ] Starts with the schema comment and `version: 1`
- [ ] Named and placed by what it applies to, gated if not for every machine
- [ ] Uses the most specific action that fits
- [ ] Every `command.run` checks before it acts, and uses `set -eu`
- [ ] A second `apply` is a no-op
- [ ] Any `where` key was confirmed with `comtrya contexts --show-values`
- [ ] Comments say *why*, not *what*
