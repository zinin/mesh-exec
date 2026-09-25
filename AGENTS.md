# mesh-exec (plugin source)

This file is for work **inside this repository**. It is not a plugin component.

Consumer projects that install `mesh-exec` get `skills/` and `agents/` — not
this file. Grok and Claude Code load `AGENTS.md` / `CLAUDE.md`
from the **current project's** tree (`projectRoot` → cwd), listed under
`grok inspect` → `projectInstructions`. Installed plugins are a separate list.
A copy of this file may sit on disk under `~/.grok/installed-plugins/mesh-exec-*`
after `grok plugin update`; that does not inject it into other projects unless
the session's cwd is that snapshot.

## Load an unpublished tree

Smoke unreleased changes without a marketplace release. `plugin.json` may still
read the last published version — identify the load by **path** and by a byte
match against this working tree, not by the version number.

Do not edit the user's `~/.config/mesh/config.yaml` or
`~/.grok/config.toml`. Ask the user to change presets.

### Claude Code — live working tree, this session only

Interactive Claude has no durable "install this folder". Session flag, from the
repo root (or pass the absolute path):

```bash
claude plugin disable mesh-exec@zinin
claude --plugin-dir "$PWD"
```

`--plugin-dir` is a live mount: the session runs the tree as it is. Disable the
marketplace copy first so the session does not mix the published cache with the
branch.

After smoke: `claude plugin enable mesh-exec@zinin`.

### Grok Build — copy into `installed-plugins`

Interactive `grok` has no `--plugin-dir`. That flag exists on `grok agent … stdio`
and is **ignored in leader mode**. Install the tree:

```bash
grok plugin install /absolute/path/to/mesh-exec --trust
grok plugin enable mesh-exec
```

Then start a **new** session (or reload plugins). This is a **copy**, not a
symlink, at `~/.grok/installed-plugins/mesh-exec-<hash>`. After you change
the working tree, edits do not apply until you **reinstall**:

```bash
grok plugin uninstall mesh-exec --confirm
grok plugin install /absolute/path/to/mesh-exec --trust
grok plugin enable mesh-exec
```

and start a new session. `grok plugin update mesh-exec` does **not** recopy a
local install — measured 2026-09-01: it answered `local symlink, already live`
while the directory stayed the old copy. The Claude marketplace cache under
`~/.claude/plugins/cache/zinin/mesh-exec/` is left alone — Claude Code smoke
still uses `--plugin-dir`.

**Keep exactly one snapshot.** The resolver picks the `mesh-exec-<hash>` that
sorts last, and the hash is not a version: with two snapshots (installed from two
paths, e.g. a worktree) the pick is arbitrary. `ls -d ~/.grok/installed-plugins/mesh-exec-*`
must list one entry; uninstall before installing from another path. The
snapshot is searched only inside a Grok session (`GROK_SESSION_ID` set), so a
stale one cannot reach a Claude Code run — but it will reach the next Grok one.

Remove the native copy: `grok plugin uninstall mesh-exec --confirm`.

### Confirm this session loaded the branch

Grok:

```bash
SNAP=$(grok inspect --json | python3 -c 'import json,sys; d=json.load(sys.stdin)
print([p["path"] for p in d["plugins"] if p["name"]=="mesh-exec"][0])')
echo "$SNAP"
cmp -s "$SNAP/skills/shared/config-loader.sh" skills/shared/config-loader.sh \
  && echo "SNAP == working tree" || echo "STOP: snapshot is not this tree"
```

Expect a path under `~/.grok/installed-plugins/mesh-exec-*` and `SNAP == working tree`.
`cmp` one file alone proves little: `skills/shared/config-loader.sh` matched a snapshot that was
three commits stale because those commits never touched it. Compare a file your change
touched, or the whole tree — `diff -rq "$SNAP" . -x .git -x docs -x runs` prints nothing
when the snapshot is current.
If the path is `~/.claude/plugins/cache/zinin/mesh-exec/…`, STOP — that is the
published cache, not this tree.

Claude Code: the session was started with `--plugin-dir <this-repo>` and
`mesh-exec@zinin` is disabled. Commands and skills resolve from the working
tree, not `~/.claude/plugins/cache/`.

## While working in this repo

- Agents never edit the user's plugin `config.yaml`.
- Do not bump `.claude-plugin/plugin.json` on a feature branch; version releases
  are a separate `chore(release)` commit on master.
- Before a PR: `git rm -r docs/superpowers/` and commit — plan/design docs must
  not appear in the PR diff (they stay in branch history).
- mesh-review calls these scripts across the plugin boundary: `config-loader.sh` (subcommands
  `data-dir`, `config-path`, `get-flag`, `get-defaults`, `get-runtime`, `list-models`,
  `list-claude-models`, `list-grok-models`, `get-codex`, `get-gemini`), `preflight-env.sh`,
  `watch-runs.sh`, `verify-delegation.sh`, `watchdog.sh`, `list-host-models.sh`. A change to
  their interface ships in the same release as the matching mesh-review change.
- Tests: `for f in skills/shared/tests/test-*.sh; do bash "$f"; done`.
