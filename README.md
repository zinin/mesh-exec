# mesh-exec

Run a prompt through another model's CLI and keep a record of the run: Codex, Gemini, Grok,
the Claude Code CLI itself, and Anthropic-compatible alt providers (z.ai, Alibaba DashScope,
DeepSeek, LiteLLM, an Ollama daemon) through `claude -p`. Each run gets a directory with the
prompt, the raw stream, the answer and a readable report; a watchdog restarts a stalled CLI.

An [Agent Skills](https://agentskills.io) plugin for Claude Code, Grok and Codex. Split out of
claude-mesh 0.15.0: multi-model review moved to [mesh-review](https://github.com/zinin/mesh-review),
plan execution and session hand-off to [session-relay](https://github.com/zinin/session-relay),
the CLAUDE.md skill to [claude-md](https://github.com/zinin/claude-md).

## Skills and agents

- **`/mesh-exec:codex-exec`, `/mesh-exec:gemini-exec`, `/mesh-exec:grok-exec`** — run a prompt
  through that CLI with full logging and progress display.
- **`/mesh-exec:ext-claude-exec`** — run a prompt through `claude -p` against an alt provider
  from `config.yaml`, or, with `HOST_CLAUDE=1`, through the Claude Code CLI under your own
  `claude login`.
- **Agents `mesh-exec:codex-executor`, `gemini-executor`, `grok-executor`, `ext-claude-executor`,
  `claude-executor`** — the same runs as subagents, for Claude Code and Grok. mesh-review
  dispatches them.
- **`skills/shared/`** — the config loader, environment preflight, run watcher, delegation
  guard and watchdog that the skills and mesh-review share.

## Install

### Claude Code

```
/plugin marketplace add zinin/agent-plugins
/plugin install mesh-exec@zinin
```

### Grok

Nothing to do when Claude Code has it: Grok loads the plugins Claude Code installed. Without
Claude Code: `grok plugin marketplace add zinin/agent-plugins`, then
`grok plugin install mesh-exec --trust`.

### Codex

```
codex plugin marketplace add zinin/agent-plugins
codex plugin add mesh-exec@zinin
```

Codex has no plugin agents, so the `*-executor` agents do not exist there; the skills do. A
run writes under `~/.local/state/mesh/`, outside the workspace: approve the write Codex asks
about, or start it with `--add-dir ~/.local/state/mesh`.

Smoke-tested in `codex exec` 0.157, in a trusted folder or with `-s workspace-write` (an
untrusted folder gets a read-only sandbox): codex-exec and grok-exec answered with
`--add-dir ~/.local/state/mesh -c sandbox_workspace_write.network_access=true` plus their CLI's
home (`--add-dir ~/.codex`, `--add-dir ~/.grok`), which makes that CLI's config and auth
writable inside the sandbox. ext-claude-exec did not start, because Codex refuses the `rm -f` in
its preflight. gemini-exec was not verified: the test machine has no Gemini credentials.

## Configure

The config is `~/.config/mesh/config.yaml` (`$XDG_CONFIG_HOME/mesh/config.yaml` when that is
set; `MESH_CONFIG` overrides the path). Runs live under `~/.local/state/mesh/runs/`
(`$XDG_STATE_HOME/mesh`). Both paths are the same under every harness, and neither is deleted
when you uninstall the plugin.

```bash
mkdir -p ~/.config/mesh
cp <plugin dir>/config.example.yaml ~/.config/mesh/config.yaml
chmod 600 ~/.config/mesh/config.yaml
```

The plugin dir is the checkout, or `~/.claude/plugins/cache/zinin/mesh-exec/<version>/` after
a marketplace install. Then edit the file:
- providers (URL + token) under `providers:`, models under `models:` with id `<provider>/<short>`;
- the optional `claude:` / `codex:` / `gemini:` / `grok:` sections (`grok:` needs a non-empty
  `models:` catalog — see the schema table below);
- `defaults:` — review presets for the mesh-review plugin, which reads this same file.

Check it: `bash <plugin dir>/skills/shared/config-loader.sh validate`.

### Moving from claude-mesh

claude-mesh kept the config in Claude Code's plugin-data directory. Copy it once:

```bash
mkdir -p ~/.config/mesh
cp ~/.claude/plugins/data/claude-mesh-zinin/config.yaml ~/.config/mesh/config.yaml
chmod 600 ~/.config/mesh/config.yaml
```

Until you do, the loader stops with `config.yaml not found at …` and prints that command.
mesh-review's orchestrators and its grok-code-review stop there, and so does `ext-claude-exec`
on a provider model. `codex-exec`, `gemini-exec` and `grok-exec` warn with the config path, pass
that command on and continue on their defaults; so do mesh-review's codex- and
gemini-code-review, which run them. `HOST_CLAUDE=1` runs, mesh-review's claude-code-review among
them, warn and continue on their defaults and never print that command. Copy the config before
the first run.
`runtime.do_plan_default_stop_tokens` is ignored now (`validate` says so): do-plan moved to
session-relay, which has `stop_tokens` in `~/.config/session-relay/config.yaml`. Old runs stay
in the old directory; nothing reads them.

### Grok Build

- `builtin: native` in a mesh-review preset runs `spawn_subagent` with slugs from `grok models`;
  `builtin: claude` runs `claude -p` (Claude Code CLI) under `HOST_CLAUDE=1`: the CLI's own
  `claude login` credentials, no provider `export` from `config.yaml`. That run unsets
  `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL` and the Bedrock / Vertex routing variables, so log
  the CLI in first. Run dirs: `runs/claude/<alias>/`.
- The `grok models` probe that builds the native page waits `GROK_MODELS_TIMEOUT` seconds, else
  `PREFLIGHT_CLI_TIMEOUT`, else 30; a non-numeric value falls back to 30 with a warning.

## Claude Code settings (not plugin config)

Two Claude Code environment variables bound how long a **single Bash tool call** may run. They
belong in `~/.claude/settings.json` (or a project `.claude/settings.json` / `.local.json`) —
**not** in the plugin's `config.yaml` — and they cap the harness, not the shell: nothing outside
Claude Code sees them.

| Variable | What it does | Claude Code default |
|---|---|---|
| `BASH_DEFAULT_TIMEOUT_MS` | timeout applied when the model passes none | `120000` (2 min) |
| `BASH_MAX_TIMEOUT_MS` | ceiling on what the model may request; the effective ceiling is the **larger** of the two | `600000` (10 min) |

A foreground Bash call that reaches its timeout is SIGTERMed, and the signal takes the whole
process group with it — every child dies, mid-write, with no chance to finalize.

Recommended:

```json
{
  "env": {
    "BASH_DEFAULT_TIMEOUT_MS": "300000",
    "BASH_MAX_TIMEOUT_MS": "3600000"
  }
}
```

**`BASH_MAX_TIMEOUT_MS` — set it to at least `runtime.timeouts.global_sec × 1000`** (default
`3600` → `3600000`). The rule is an invariant, not a preference: below it the plugin's own
budgets are decorative. `global_sec` 3600 and `single_run_sec` 1800 both sit above the stock
10-minute ceiling, so on the stock value a synchronous wait on a run is cut long before the
watchdog's restarts or its wall clock can act. Measured 2026-08-05 on CC 2.1.222: five external
reviewers launched as foreground calls died at 600–605 s while their streams were still growing,
each tool result reading `Exit code 143 / Command timed out after 10m 0s`. Values are JSON
**strings**; `settings.json` changes apply on save, a shell `export` from the next `claude`.

Since the release that made the exec skills launch their engine as a background task, this
ceiling is no longer load-bearing for reviews — a background task is not subject to it at all.
Keep it raised anyway as a safety net for a wrapper that ignores the instruction, and read
`KILLED` in a delegation table as the sign that one did (see Troubleshooting). The environment
probe checks the rule for you: a ceiling below `global_sec × 1000` shows up as a `bash-timeout
LOW` row carrying the exact value to set.

**`BASH_DEFAULT_TIMEOUT_MS` — 300000 (5 min) is a sane middle.** This one governs ordinary
commands that pass no timeout of their own: builds, test runs, `git log -S` sweeps over full
history, `find` over large trees. The 2-minute stock value is tight enough that this plugin's
own test suite does not fit: `skills/shared/tests/` runs 207 s end to end (2026-08-30, thirteen
suites, 1178 assertions — `test-preflight-env.sh` 123 s, `test-config-loader.sh` 53 s,
`test-watch-runs.sh` 21 s), so a foreground run of it dies partway through the longest
suite. 5 minutes clears that with room to spare. Do not push it near the max:
it applies to *every* untimed command, so a genuinely wedged one holds the turn for the whole
value before the harness intervenes — which is exactly the runaway the default exists to catch.

## Dependencies

The plugin requires:
- A harness that loads Agent Skills: Claude Code, Grok or Codex. The `claude` CLI is needed only
  for `ext-claude-exec` (alt providers and `HOST_CLAUDE=1`).
  - `runtime.dispatch_model` governs the plumbing: the codex / gemini / grok / ext-claude wrapper
    agents and mesh-review's `review-discussion` agent. Empty = the subagent inherits the session
    model. do-plan's subagents take `dispatch_model` from session-relay's own config instead.
  - `claude.models` is the catalog mesh-review offers for the built-in `claude` reviewer; each
    selected entry is one more full review, so cost scales with it.
- `yq` — **either flavor**: Python-yq (`kislyuk/yq`) or Go-yq v4+ (`mikefarah/yq`). `config-loader.sh` does not identify the binary: it runs the transcode, keeps whichever invocation produced JSON, and — when the config contains a value that could have been mis-resolved — checks that `off`/`on`/`yes`/`no` came through as strings before trusting it. A `yq` that fails either check is refused by name, and your `config.yaml` is not blamed for it.
- `jq` — for JSON parsing in stream-json mode
- `bc`, `curl` — for `ext-claude-exec` skill
- `python3` — for `ext-claude-exec`; also for `shared/extract-result.py`, which `ext-claude-exec` and `grok-exec` both use to pull the final answer out of the stream
- `codex` CLI (only if using codex agents)
- `gemini` CLI (only if using gemini agents)
- `grok` CLI (only if using grok agents). It authenticates itself (`grok login`); mesh-exec never handles a grok token. Unlike codex and gemini, grok also reads your `~/.claude/CLAUDE.md` and every installed plugin — a grok reviewer starts with your project rules in context, and its review prompt forbids it from invoking any of those skills

Install missing tools:
- Ubuntu/Debian: `apt install jq bc curl python3`
- macOS: `brew install jq bash coreutils util-linux findutils`

Plus a `yq`, installed however your platform provides one. If your package manager has none, or ships a Go-yq older than v4, `pipx install yq` works everywhere (that is Python-yq, and it needs `pipx`).

### macOS additional setup

mesh-exec's scripts use **GNU coreutils** (`timeout`, `stdbuf`, `stat -c`, `setsid` from util-linux) and **GNU findutils** (`find -printf`, used by the delegation guard). macOS ships only BSD variants by default. After `brew install bash coreutils util-linux findutils`, prepend the gnubin paths to your `PATH` so `timeout`/`stat`/`setsid`/`find` resolve to the GNU versions:

```sh
# Add to ~/.zshrc or ~/.bashrc
export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$(brew --prefix)/opt/findutils/libexec/gnubin:$(brew --prefix)/opt/util-linux/sbin:$(brew --prefix)/opt/util-linux/bin:$PATH"
```

A bash 4.2+ shell is also required (macOS system bash is 3.2). `brew install bash` provides this; ensure `/opt/homebrew/bin/bash` (Apple Silicon) or `/usr/local/bin/bash` (Intel) appears in `$SHELL` or your terminal config. `config-loader.sh` and `ext-claude-exec` preflights detect Darwin and fail fast with these instructions if the setup is missing; `shared/watch-runs.sh` and `shared/verify-delegation.sh` are the two that need 4.2 rather than 4.0, for the `printf '%(fmt)T'` builtin, and `verify-delegation.sh` probes for GNU `find` at startup.

## Config schema reference

See `config.example.yaml` for the canonical example. Sections:

| Section | Required | Purpose |
|---|---|---|
| `providers:` | yes | API endpoint + auth + kind (anthropic-api / ollama-daemon) |
| `models:` | yes | id = `<provider>/<short>`, model name, optional alias overrides |
| `claude:` | no | `models:` — catalog of Claude model aliases offered for the built-in `claude` reviewer; each selected entry becomes one independent reviewer. Omit it (together with any `defaults.*.claude_models`) for the previous single-reviewer behaviour |
| `codex:` | no | model + reasoning_level for codex CLI — the default for `/codex-*` skills and reviews unless the caller overrides; unknown levels pass through with a WARN (known set as of 2026-07 is listed in `config.example.yaml`) |
| `gemini:` | no | model for gemini CLI — the default for `/gemini-*` skills and reviews unless the caller overrides |
| `grok:` | no | `models:` — catalog of grok model ids for the built-in `grok` reviewer, **required and non-empty** while the section exists. `reasoning_effort:` — optional section-wide default; `model_efforts:` — optional per-model overrides of it, because the CLI validates the level per model. One reviewer per selected entry, so cost scales as for `claude.models`. All three keys have rules worth reading before you edit them — see below |
| `defaults:` | no | named presets for `/mesh-review:mesh-review default` etc. (read by the mesh-review plugin) |
| `defaults.*.native` | no | host-reviewer type in a preset's `builtin`. On Grok: `spawn_subagent` with slugs from `grok models`. On Claude Code: synonym of `claude` (not a second set). No `native:` YAML section |
| `defaults.*.native_models` | no | Grok default native slugs for that preset. Ignored on Claude Code. A slug missing from live `grok models` is skipped, not a loader error. Requires `native` in the same preset's `builtin` |
| `runtime:` | no | UI defaults + timeouts |


### The `grok:` section: a mandatory catalog, and an effort key the CLI checks per model

**`models:` is required and non-empty whenever the section exists** — a missing `models:` and an
empty `models: []` are both hard errors, because the grok reviewer agent refuses to start without
a model. (`claude:`'s catalog is optional; this one is not.) Its charset is narrower than
`claude.models`, since a grok model id becomes a directory name and a run-watcher roster entry —
`config.example.yaml` states the exact set. Entries are never checked against your CLI's own list
and never substituted: an id your `grok` does not accept fails that reviewer's run, and the other
reviewers carry on.

**`reasoning_effort:` is one value per section — the CLI validates it per model.** This loader
passes five values without a WARN — `low`, `medium`, `high`, `xhigh`, `max` — and anything else
with one, so a level xAI ships tomorrow needs no plugin release. Run `grok --help` for the
current set; `config.example.yaml`'s `grok.reasoning_effort` comment is the canonical copy of
the list, and this note and `config-loader.sh` follow it.

**Those five are no single model's set.** The CLI validates the flag PER MODEL at argument
parsing, before any API call, and rejects with rc=1. Measured 2026-08-30 on grok 1.0.5:
`grok-4.6` accepts `xhigh|high|medium|low`, `grok-4.5` only `high|medium|low`, and that CLI's own
default model all five — three sets behind one binary. Reading a model's own set is free, since
the probe fails on the flag and never reaches the API:

```sh
grok -m <id> --effort __bogus__ -p x
```

Rank each printed set by `low < medium < high < xhigh < max`: the CLI prints them in different
orders per model, so position is not rank.

**`model_efforts:` is how one catalog holds models with different sets.** It maps a model id to
the level that model runs at, overriding `reasoning_effort` for it alone; the section-wide value
still serves every entry the table does not name. Without it, the section default has to be valid
for EVERY catalog entry, and the entries that reject it lose their whole run with no diagnostic
from this plugin. Keys must be catalog entries — a key outside `models:` is a hard error rather
than a silent no-op, since the whole point is that you can trust a model ran at the level you
wrote. Write only the exceptions: most models accept the top level.

The resolution order a run follows is: the level a caller passed explicitly, then
`grok.model_efforts[<model>]`, then `grok.reasoning_effort`, then — with none of them set — no
`--effort` at all, which hands the choice to `~/.grok/config.toml`.

## Troubleshooting

| Problem | Solution |
|---|---|
| `claude: command not found` | Install Claude Code CLI first |
| `yq: command not found` | Install either flavor — `pipx install yq` (Python-yq) or `apt install yq` / `brew install yq` (Go-yq v4+) |
| `yq cannot produce JSON` | The `yq` on PATH answers neither `yq .` nor `yq -o=json .` with JSON — it is too old, or not a `yq` at all. Install one of the two flavors above |
| `yq mis-resolves YAML scalars` | The `yq` on PATH resolves YAML 1.1, turning `off`/`yes` into booleans. Upgrade it, or install one of the two flavors above |
| config.yaml not found at … | See "Configure" and "Moving from claude-mesh" — the message prints the cp command when the old config is still there |
| `models[X] references missing provider "Y"` | Add a `providers[]` entry with `id: Y` |
| `Token expired or invalid for ...` | Update `token:` in the corresponding `providers[]` entry |
| `grok: command not found` | Install Grok Build — `curl -fsSL https://x.ai/cli/install.sh \| bash`, the installer xAI documents in the CLI's own README — then `grok login` |
| `grok` row reads `NO-NETWORK` in the probe | `grok models` failed: no network, or the CLI is signed out — run `grok login` |
| A grok reviewer's `output.txt` reads `API Error: Couldn't set model to <id>` | The id in `grok.models` is not one this machine's CLI accepts — mesh-exec does not check ids and never substitutes one. Run `grok models`: it prints `Default model:` and then `Available models:`, one `  - <id>` per line with `*` marking the default — copy an id from there verbatim |
| `Ollama daemon not running` | `ollama serve` or `systemctl start ollama` |
| `Daemon up but /api/tags returns error` | `ollama signin` |
| `HTTP 404 / 501 from LiteLLM provider` | LiteLLM is in OpenAI-compat mode — enable Anthropic mode in your LiteLLM config, or pass `SKIP_TOKEN_PRECHECK=1` to `ext-claude-exec` |
| External review dies at ~600 s; `watchdog.log` ends with `"event":"cleanup" … "exit_code":143` and there is no `watchdog.exit` | The wrapper launched its engine as a **foreground** Bash call and the harness SIGTERMed it at `BASH_MAX_TIMEOUT_MS`. `verify-delegation.sh` reports this as `KILLED` (exit 6) and `/mesh-review:mesh-review` does **not** re-dispatch it — an identical launch dies identically. The exec skills require a background launch; raise the ceiling as a safety net (see "Claude Code settings"). A cluster of deaths at the same round number is the signature |
| `runs/` directory grows large over time | No automatic cleanup (intentional — personal-use plugin, hot-path I/O minimised). Add a cron one-liner: `0 3 * * 0 find ~/.local/state/mesh/runs -mindepth 4 -maxdepth 4 -type d -mtime +30 -exec rm -rf {} +` (Sunday 03:00 weekly, deletes per-run dirs older than 30 days). Adjust `+30` to your retention preference. |

## License

MIT — see [LICENSE](LICENSE).
