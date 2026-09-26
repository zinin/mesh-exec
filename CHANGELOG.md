# Changelog

All notable changes to mesh-exec (claude-mesh up to 0.15.0) will be documented here.

## [Unreleased]

### Changed
- **Renamed from claude-mesh to mesh-exec** and cut down to one job: running prompts through
  other models' CLIs. `/mesh-review`, `/mesh-design-review`, `/auto-decide-disputed` and the
  review prompt generators (`/code-review-fresh-session`, `/design-review-fresh-session`) moved
  with their reviewers to the mesh-review plugin; `/do-plan`, `/pause-after-current-task`,
  `/transfer-session`, `/exec-plan-fresh-session`, `/continue-plan-fresh-session` and the
  context-size hook to session-relay; `claude-md-writer` to claude-md. Skill and agent names
  change accordingly: `/claude-mesh:codex-exec` is `/mesh-exec:codex-exec`.
- **The config lives at `~/.config/mesh/config.yaml`, runs under `~/.local/state/mesh/`**
  (XDG; `MESH_CONFIG` overrides the config path). No harness plugin-data directory is involved:
  an uninstall no longer deletes the config, and Codex finds it too. When the old
  `~/.claude/plugins/data/claude-mesh-*/config.yaml` is still there and the new one is not,
  the loader prints the command that copies it. New `config-loader.sh config-path`.
- **`preflight-env.sh` prints the loader's move command** when the old claude-mesh config is
  still in place and the new one is not: its `hint:` line is the loader's own
  `mkdir -p … && cp … && chmod 600 …` rather than `cp config.example.yaml`, which would start a
  blank config beside the one holding the provider tokens.
- **`runtime.do_plan_default_stop_tokens` is ignored with a warning** and `get-flag
  do_plan_default_stop_tokens` is gone: do-plan has its own config in session-relay.

### Removed
- `scripts/backup-config.sh`: the config no longer sits where an uninstall deletes it.

## [0.15.0] - 2026-09-05

### Changed
- **`/do-plan` on Grok inherits the session model when `runtime.dispatch_model` is not a host slug.** The Step 1 fence probes `grok models` (same `timeout` + `list-host-models.sh` as `/mesh-review`); a miss, an empty catalog, or a missing `timeout(1)` clears `DISPATCH_MODEL` so subagents omit `model:` rather than spawning `opus`. `spawn_subagent` has no effort field — omitting `model:` is what inherits session effort (`xhigh` on `grok-4.6`).
- **`/do-plan` binds the context hook with `GROK_SESSION_ID` when `CLAUDE_CODE_SESSION_ID` is empty.** Both empty still abort.
- **`check-context-size.sh` reads Grok `signals.json` (`contextTokensUsed`) and keys the session off `sessionId` / `$GROK_SESSION_ID`.** Data dir falls back to `$GROK_PLUGIN_DATA`. Subagent fires (`subagentType` or `agent_id`) stay silent. Wiring stays `PostToolUse` only — same as Claude Code.
- **`/do-plan` on Grok polls `signals.json` for STOP.** The hook is not the primary channel: Grok does not inject status-line / `/session-info` numbers into the model, and `PostToolUse` stdout is ignored. Step 1 echoes `CONTEXT_SIGNALS=`; after each task checkpoint the controller reads `contextTokensUsed` and pauses when it crosses the threshold.

## [0.14.1] - 2026-09-02

### Changed
- **`/transfer-session` always writes under `docs/`.** `docs/session-transfer-<date>-<time>.md`,
  creating the directory when needed, like every other prompt generator in the plugin. The
  `/tmp` fallback is gone: the fresh session has to find the file by a project-relative path.

## [0.14.0] - 2026-09-02

### Changed
- **Fresh-session prompt generators print the file path, not the prompt.** `/transfer-session`,
  `/exec-plan-fresh-session`, `/continue-plan-fresh-session`, `/design-review-fresh-session`
  and `/code-review-fresh-session` still write the prompt to the same file; the chat now gets
  a one-line summary plus the relative and absolute path. Echoing the prompt only spent tokens.

### Removed
- **Clipboard copy.** No generator calls xclip/xsel/pbcopy any more, and the generated review
  prompts no longer tell the sandbox session about clipboards. `preflight-env.sh` lost its
  `clipboard` row — its only reader was that advice.

## [0.13.0] - 2026-09-02

### Added
- **Host-aware mesh on Grok Build.** `/mesh-review` and `/mesh-design-review` detect Grok by the presence of `spawn_subagent` and dispatch native `general-purpose` reviewers with `model:` slugs from `grok models` (`builtin: native` / `native_models`). Wrappers still run when selected. On Grok, `claude` is the Claude Code CLI (`claude -p --model`, `runs/claude/<alias>/`).

### Fixed
- **Grok native reviewers had no shell.** `explore` on Grok 1.0.13 is `read_file`/`list_dir`/`grep` only, so `git diff` never ran. Native dispatch is `general-purpose` (do not edit files).
- **Unpublished Grok install lost to the Claude cache.** `resolve-plugin-root.sh` and every skill/command else-branch now search `~/.grok/installed-plugins` before `~/.claude/plugins`. Only inside a Grok session (`GROK_SESSION_ID` set in bash): a Claude Code session keeps the 0.12.0 order, so a stale Grok snapshot on a two-host machine cannot outrank the Claude cache.
- **HOST_CLAUDE `claude -p -m` is not a flag** on Claude Code 2.1.257. Pass `--model`.
- **Empty `.session_id` on Grok.** Stamp and match `GROK_SESSION_ID` when `CLAUDE_CODE_SESSION_ID` is unset.
- **Grok wrapper `.session_id` is the child session, not the parent.** Wrapper bash sees its own `GROK_SESSION_ID`; `watch-runs` / `verify-delegation` run as the orchestrator. A child-stamped run is still this dispatch when Grok's subagent `meta.json` names the parent. Without that meta the stamp stays foreign. The meta lives at `~/.grok/sessions/<cwd>/<parent id>/subagents/<child id>/meta.json`; the first cut globbed one level too shallow and matched nothing, and the match is now on the value, not on Grok's pretty-printing.
- **Grok wait rule contradicted by the exec skills.** The four `*-exec` skills told every wrapper to end its turn after the launch; on Grok Build the wrapper waits on the command id instead, as the agent definitions already said.
- `mesh-design-review` merge template gained the `native:<slug>` section; the Grok wait loop now binds `runtime.timeouts.global_sec` (`GLOBAL_SEC`) instead of naming a value nothing had read.
- `list-host-models.sh` stops at the first non-bullet line after `Available models:` — bulleted prose printed after the list no longer becomes slugs.
- Preflight: `native` detection reads the preset JSON, not the joined summary string; a `claude-cli MISSING` row now carries a note that `claude:*` is the CLI on Grok Build.
- HOST_CLAUDE without a config.yaml: `get-runtime` rc=2 now means the default timeouts (1800/600/3600, 2 retries) plus a WARN naming the data dir, matching the review skill's preflight; rc=1 (a config that does not validate) still STOPs.
- Grok native reviewers run as `general-purpose` with a shell, so both orchestrators now hash the working tree before dispatch and after the native wait; a difference is reported (a `tree | CHANGED` row in mesh-review, a note atop the design-review merged file), never reverted.
- The orchestrators' `grok models` probe honours `GROK_MODELS_TIMEOUT`, else `PREFLIGHT_CLI_TIMEOUT` (the knob preflight's NO-NETWORK row names), else 30; documented in README.
- `ext-claude-exec`: Step 1 records the validated `MODEL` / `HOST_CLAUDE` pair in `$WORK_DIR/.mode`; both launch fences re-check their own substitution against it and STOP before the CLI starts on a mismatch.
- **Review→exec Read on Grok opened the Claude cache.** The no-Skill-tool paragraph in the five `*-code-review` skills (and fresh-session preflight) now searches `~/.grok/installed-plugins` before `~/.claude/plugins`.
- Preflight no longer marks a zero-slug `grok models` listing as `OK` (and no longer leaks a temp file).
- **Grok wrapper fences died before the Claude-cache fallback** when `~/.grok/installed-plugins` was absent (marketplace install, no `grok plugin install`). `find` on a missing dir is rc=1; under `set -euo pipefail` that killed the last `||` arm, so Step 1/2 never reached `~/.claude/plugins`. Each loader-find assignment now ends with `|| true`.

### Changed
- **Grok-only break:** a 0.12.0 preset with `builtin: [claude, …]` and no `native` no longer means "review on the host model". It means `claude -p`. Claude Code behaviour for that preset is unchanged.

## [0.12.0] - 2026-08-30

### Added
- **grok is a third CLI reviewer engine**, alongside codex and gemini: `grok-exec` /
  `grok-code-review` skills, `grok-executor` / `grok-code-reviewer` agents, a gated `grok:`
  config section, a row in the environment probe, and a place in the selection UI of both
  `/mesh-review` and `/mesh-design-review`. Unlike codex and gemini, grok carries a model
  CATALOG — `grok.models`, with `defaults.<preset>.grok_models` choosing which entries a
  preset runs — so one review can cross-check itself across several grok models, exactly as
  `claude.models` already allows for the built-in reviewer. Cost scales the same way: each
  entry is one more full review of the same diff.
- The grok runs speak the Claude Code wire format (`--output-format streaming-messages-json`),
  so the report renderer serves them unchanged and `verify-delegation.sh` judges them on the
  same branch as `ext-claude` — which is why grok reaches the `DEGRADED` verdict, a state
  codex and gemini cannot express. Sharing that branch was not free: it now forks in two
  places, on the remedy for a refused tool call (`grok-exec` already passes
  `--permission-mode bypassPermissions`, so ext-claude's "add the flag" advice would be
  wrong) and on the sentence that explains the review-length floor, whose archived
  measurement is ext-claude's alone. Separately — because of the shared WIRE FORMAT rather
  than the shared branch — `shared/extract-result.py` learned grok's TOP-LEVEL
  `{"type":"error","message":…}` shape, the one a bad `-m` produces, which until now
  rendered as the literal `API Error: {}` with the message lost.
- **`grok.model_efforts` — per-model reasoning effort.** `grok.reasoning_effort` is one value
  for the whole section, but the grok CLI validates `--effort` PER MODEL at argument parsing and
  rejects a bad pair with rc=1 before any API call, and the accepted sets genuinely differ:
  measured 2026-08-30 on grok 1.0.5, `grok-4.6` takes `xhigh` but not `max`, `grok-4.5` takes
  neither, and most proxied entries take all five. A catalog of more than one model therefore
  could not be served by a single level — the pairing `config.example.yaml` shipped was itself
  unrunnable for half its own catalog, which is why that example had been cut to one model.
  `model_efforts` maps a model id to the level that model runs at and overrides the section
  default for it alone, so the example ships two models again. Keys must be catalog entries: a
  key outside `models:` is a hard error rather than a silent no-op, because the point of the
  key is being able to trust that a model ran at the level you wrote. `get-grok` takes an
  optional model argument for this; called with none — as a direct `grok-exec` invocation
  naming no model does — it answers the whole-section question exactly as before. Nothing in
  the orchestrators, the wrapper agents or `grok-code-review` changed: `grok-exec` resolves the
  level itself and already knew which model it was running.

### Changed
- **The reviewer-type question of both orchestrators is three options, not five.** `claude`,
  one option for the external CLIs, and one for the Anthropic-API models; picking the CLI
  option opens a second page listing the engines actually configured, skipped when there is
  only one. `AskUserQuestion` accepts four options at most, so a fourth engine had nowhere to
  go — and a fifth one still will not need this question to change. A catalog holding exactly
  one entry is still asked about rather than chosen for you: the second option is that page's
  own "run none of them".
- **A broken optional section fails its own row, not the environment.** A `grok:` section that
  does not validate — a malformed catalog, or a section that is not a mapping at all, such as
  `grok: false` — now degrades grok alone on the preset-read path: it is dropped from the
  preset, `get-defaults` reports `grok_degraded`, and the orchestrator says out loud that the
  reviewer you asked for is not running. Before, one typo made `preflight-env.sh` print
  `config INVALID` and skip EVERY row, codex and gemini included. `config-loader.sh validate`
  is unchanged and still rejects the file, and the flag is now reported to the preset that
  actually named grok rather than to both.
- **`report.md` shows the whole run again.** The shared renderer read only the first content
  block of each message, so a message beginning with a `thinking` block — the ordinary shape
  for a reasoning model — vanished from the report entirely, tool call included. Measured on a
  real grok review: 22 of 23 assistant messages began that way, and the 904 KB report held
  none of the run's 79 tool calls, only their outputs. It now renders every block, and has a
  regression suite of its own (`shared/tests/test-stream-json-report.sh`) — its first.
- `verify-delegation.sh` reads a refused tool call before it decides a run is `BROKEN`, so a
  reviewer that was denied its very first call is no longer told to swap a model that did
  nothing wrong. It also rejects a grok model that is not a catalog id: the `<provider>/<short>`
  spelling belongs to ext-claude, and it used to resolve a path nothing writes and come back
  as `FLIP` — "this reviewer never delegated" — about a reviewer that had just delivered.
- `skills/ext-claude-exec/generate-md.sh` moved to `skills/shared/stream-json-report.sh`. Two
  engines render reports from the same stream format; the renderer had been living inside one
  of them. Same signature, same output.
- The model-catalog validator is now one function serving `claude:` and `grok:`. Its error
  messages for `claude.models` are unchanged, byte for byte — pinned by a golden fixture.
- `preflight-env.sh` probes a CLI with a command when an HTTP request cannot answer for it:
  `grok models` reports network and login together, while a curl against `api.x.ai` would
  describe an endpoint a grok.com subscription never calls. Read the table accordingly — `OK`
  on the codex and gemini rows remains a heuristic that says nothing about auth, while `OK` on
  the grok row means the CLI answered, so the login is live.

### Requirements
- `grok` CLI (only when using the grok agents). It authenticates itself; claude-mesh never
  handles a grok token, and never checks or substitutes a model id — an id your CLI does not
  accept fails that one reviewer's run. Note that grok also reads `~/.claude/CLAUDE.md` and
  every installed claude-* plugin — the review prompt therefore forbids it from invoking any
  skill.

### Fixed
These four are engine-agnostic: they were found while building grok, but every one of them had
been costing codex, gemini and ext-claude runs the same way.

- **A review split across stream segments was delivered as its wake-up line.** `output.txt` took
  the LAST `result` event, and a run that dispatches a background subagent ends on a short
  acknowledgement rather than on its review — so the report, the merge and the delegation guard
  all saw the acknowledgement. Measured over the run archive on the development machine: of the
  56 streams carrying more than one result event with usable text, 33 had a last event shorter
  than the longest, up to 16817 of 17882 characters of review discarded — the same sweep counts
  59 and 36 if result events with no text of their own are included, which the extractor never
  had to choose between. This plugin's own review of 2026-08-29 is among them.
  The longest result now wins, ties going to the last so single-result runs stay
  byte-identical to what they produced before. A failed segment never wins over a successful
  one whatever its length; an error result is used only when the stream has no successful one,
  which keeps a quota or balance message from being replaced by silence.
- **A stream whose last line had no newline lost that line** — and the last line is the `result`
  event. Measured: a three-event log ending without a newline reached `raw.jsonl` as two events,
  the missing one being exactly what `verify-delegation.sh` requires to call a run finished. A
  completed review was therefore one truncated line away from being scored `STALLED` — "killed
  mid-flight" — and re-dispatched. Fixed in every stream consumer: `codex-exec`, `gemini-exec`,
  `grok-exec` and the shared report renderer.
- **A run that died before its first turn was called `STALLED`, which prescribes a retry.** It
  is now `BROKEN`, the verdict that says the next identical run dies identically. The rule is
  narrow on purpose: an archive sweep showed a non-empty `errors[]` is ordinary in healthy
  ext-claude runs — dozens of them, 2 to 62 turns — so only a zero-turn result event carries
  the new verdict. The turn count itself is now read from the last result EVENT rather than
  from the last integer seen anywhere in the stream.
- **A CLI that refused its own arguments produced an empty review and no reason.** When the
  terminal `result` event carries its cause in `errors[]` and the stream holds no `error`
  event — the shape an unsupported `--effort` value produces — `output.txt` was zero bytes, the
  reason survived only in `stderr.txt` where nothing downstream reads it, and the guard scored
  a deterministic 15-second death as a stall worth retrying. The reason now reaches
  `output.txt`, every entry of it.

- **An ext-claude reviewer dispatched with `BASE_BRANCH=` got the base in front of `MODEL=`.**
  `/mesh-review` prescribed a one-line `MODEL=<id> Review the changes…` prompt and then told
  the caller to prefix the whole thing with `BASE_BRANCH=<branch> ` — which puts the base at
  the head of the first line, where `agents/ext-claude-code-reviewer.md` requires MODEL to be.
  Nothing parses that prompt mechanically, so the agent either stops with its own
  `ERROR: MODEL parameter is required on first line` or forwards a guess: a reviewer that
  never runs, or one reviewing a range nobody asked for. Both the initial dispatch and the
  auto-redispatch retry are now the same three-line shape grok already used — `MODEL=` alone
  on the first line, `BASE_BRANCH=` directly under it, then the request — and the prefix rule
  says what it is really about: it belongs to codex and gemini, whose agents claim no first
  line, and a wrapper that does claim one takes the two-line shape instead.

## [0.11.0] - 2026-08-26

### Requirements
- `yq` may now be **either flavor**: Python-yq (`kislyuk/yq`) or Go-yq v4+ (`mikefarah/yq`).
  The loader no longer identifies the binary — it runs the transcode, keeps whichever
  invocation produced JSON, and verifies scalar resolution when the config contains something
  that could have been mis-resolved. `pipx install yq` stops being the only supported route.
  README's package-manager→flavor table is deleted rather than inverted: which flavor a package
  manager delivers depends on the repositories configured, not on the distribution name.

### Fixed
- claude-mesh could not start at all where `yq` is Go-yq. `config-loader.sh` refused it on
  sight, and since it died before opening `config.yaml`, `preflight-env.sh` reported
  `config UNKNOWN` and `SUMMARY available: —`: not one reviewer selectable, not even the
  built-in `claude`. The plugin uses `yq` for exactly one operation, a single YAML→JSON
  transcode, so the incompatibility was never the DSL the rejection cited — Go-yq simply needs
  `-o=json` to print JSON.
- Every transcode failure used to be reported as a broken `config.yaml`. A `yq` that cannot
  emit JSON now says so, and only a genuinely malformed file is sent back to the user as one.
  This also covers the flavors the old string matcher never recognised: it keyed on the
  `mikefarah` URL or the literal `version v`, and anything else passed the check and then died
  blaming the config.
- A `yq` that resolves scalars per YAML 1.1 used to surface as `codex.reasoning_level: must be
  a string (got boolean) — quote it…`, telling the user to fix a value that was already correct.
  It is now named as what it is.
- A `config.yaml` that could not be snapshotted because `mktemp` failed was reported as an
  invalid config. TMPDIR being unwritable or full is not a property of the file, and the file
  was never opened; `preflight-env.sh` now routes those deaths to `config UNKNOWN` with the
  same `tmpfile` cause it already used for its own temp files, and the hint points at TMPDIR
  instead of at a healthy config.

## [0.10.0] - 2026-08-23

### Added
- `/claude-mesh:auto-decide-disputed` and the `autodecide` argument for `/claude-mesh:mesh-review`
  and `/claude-mesh:mesh-design-review` — a fourth exit for a disputed review issue. Until now an
  issue with several reasonable variants could only end the turn and wait for a free-text answer,
  or — in `/claude-mesh:mesh-review`'s `default` mode — be deferred to a re-run. The new mode keeps
  the analysis exactly as it was — суть, анализ, варианты с плюсами и минусами, рекомендация —
  adds a mandatory `Проверка решения` section in which the agent argues against the variant it just
  chose and answers that objection, flags the decision `уверенно` or `под вопросом` by an explicit test
  (unanswered objection, or a deciding fact that is not in this repository), and then applies its
  own recommendation. Each decision is committed on its own, so `git revert <hash>` undoes exactly
  one; `git log --grep=auto-decide-disputed` lists the whole run, and the summary lists every
  `под вопросом` decision with what was missing. The decision protocol lives in one file — the
  command — and both review flows carry only the hand-off, their own Iron-Rule carve-outs and
  their own reporting, rather than a copy of it.

## [0.9.0] - 2026-08-09

### Added
- `claude-md-writer` skill — best practices for writing and refactoring `CLAUDE.md`: size
  budgets, the three-tier `CLAUDE.md` → `.claude/rules/` → co-located layout, `paths:`
  frontmatter for conditional loading, and a quality checklist. It had been living unversioned
  in `~/.claude/skills/`, i.e. on one machine and in no release; moving it here puts it under
  the same version and install path as everything else the plugin ships. Vendored from
  [serejaris/personal-corp-os](https://github.com/serejaris/personal-corp-os/tree/main/skills/claude-md-writer)
  (MIT). Attribution and the upstream-diff recipe are in README's new Credits section.

### Fixed
- `claude-md-writer` was checked against the sources it cites and corrected — the upstream
  copy is stamped "Updated: Jan 2026" and Claude Code has moved since. Six factual errors, in
  a skill whose whole job is to state these facts: import depth is **four** hops, not five;
  `/memory` lists and opens memory files while **`/context`** is what shows which ones
  actually loaded; `CLAUDE.local.md` is **not** auto-gitignored, you add it yourself; the
  memory hierarchy table was inverted at the bottom (`CLAUDE.local.md` is read *last*, not
  lowest-priority), carried only the macOS managed-policy path — no use on Linux, which is
  `/etc/claude-code/CLAUDE.md` — and omitted `~/.claude/rules/` entirely; the refactor
  workflow prescribed `@file` imports as a way to shrink a bloated CLAUDE.md, which is
  backwards, since imports load at launch too and only `.claude/rules/` with `paths:` cuts
  startup context; and the 3-Tier system plus the 500-line rules budget were both billed as
  official Anthropic recommendations when the first is the community Claude Code Development
  Kit's and the second appears in no Anthropic doc. One cited source, `anthropic.com/
  engineering/claude-code-best-practices`, now 308-redirects to `code.claude.com/docs/en/
  best-practices`.
- Same pass, additions from what the docs have gained since: auto memory
  (`~/.claude/projects/<project>/memory/`, a second memory system the skill did not mention),
  `AGENTS.md` interop, `claudeMdExcludes` for monorepos, `/doctor`'s trim proposals, the
  brace-expansion budget and bracket-escaping rules for globs, the fact that path-scoped rules
  are not re-injected after `/compact`, rules-directory symlinks, the `InstructionsLoaded`
  hook for debugging what loaded, and the framing that makes the rest cohere: CLAUDE.md
  arrives as a user message after the system prompt, so it is advisory context and anything
  that must hold every time belongs in a hook.
- One review finding was checked and **not** applied. An automated reviewer flagged the
  skill's comma-separated `paths:` example, `"{src,lib}/**/*.ts, tests/**/*.test.ts"`, as a
  single glob that would match nothing. Probed against CC 2.1.226 with `.claude/rules/`
  fixtures and a negative control: a comma-joined value whose *second* pattern matches does
  load the rule, one where neither side matches does not, and a lone non-matching pattern does
  not — so Claude Code splits on the comma and the example works. The documented form is a
  YAML list; the example stands as upstream wrote it.

### Removed
- `codex-review-native` skill and its `codex-native-reviewer` agent — the thin wrapper around
  `codex exec review`. It was a second, weaker codex path (branch or uncommitted changes only,
  no SHA range, output scraped out of the JSONL log) that `/mesh-review` never dispatched:
  codex reviewers have always gone through `codex-code-reviewer` → `codex-code-review`, which
  takes a custom prompt and writes its output with `-o`. Reachable only by invoking it by hand,
  which nobody did. `mesh-review.md`'s base-branch note no longer cites it among the skills that
  auto-detect the base; the historical entries below still name it, as they should.

## [0.8.0] - 2026-08-05

### Fixed
- Wrapper reviewers launched their external engine as a **foreground** Bash call, and the
  harness caps one at `BASH_MAX_TIMEOUT_MS` — ten minutes out of the box — then SIGTERMs it at
  the cap, taking the whole process group with it. `watchdog.sh`'s `trap 'cleanup 143' TERM`
  recorded `exit_code: 143` and the run died mid-flight while its stream was still growing. On
  2026-08-05 (CC 2.1.222) a `/mesh-review` lost five of eight reviewers that way — all five
  dying at 600-605s, each tool result reading `Exit code 143 / Command timed out after 10m 0s`
  — while every run that happened to be launched with `run_in_background: true` outlived the
  cap: 812s, 1397s, 2001s, 2028s. Nothing in the plugin had ever specified the launch mode of
  that Bash call — the string `run_in_background` appeared exactly once anywhere in the plugin,
  on `mesh-review.md`'s **Task** dispatch, and never on a Bash launch — so each wrapper model
  chose for itself, which is why the same model both died and survived in one session. Worse, the three agent files said
  the opposite of the orchestrator: "Wait for the Bash call to return" (there since the first
  commit, `46302fd`) against `mesh-review.md`'s "launches its external engine as a background
  Bash task", on which the whole `watch-runs.sh` + ping machinery is built. The budgets those
  agent files advertise — two watchdog restarts, a 60-minute wall clock — all sit above the cap
  and were unreachable by construction on the foreground path. `ext-claude-exec`, `codex-exec`
  and `gemini-exec` now require the supervised block to run as a background task, and the three
  reviewer agents were rewritten to match: launch, name the run dir, go idle, read the results
  when pinged. No work moved — extraction, report generation and bail diagnostics already ran
  inside that one block.
- Wrapper reviewers no longer relaunch a dead run on their own initiative. That behaviour was
  never specified; the models improvised it (`setsid nohup`, a hand-written driver script) once
  their runs started dying, and it left a second run dir the orchestrator was not tracking —
  `watch-runs.sh` follows the newest dir, so attribution moved to a run nobody had asked for
  and the work was duplicated. Retry belongs to `runtime.max_redispatch`.

### Added
- `shared/verify-delegation.sh` gained a sixth verdict, `KILLED` (exit 6), for a run stopped by
  a signal from outside it: the watchdog's last `cleanup` carries 143 (SIGTERM) or 130 (SIGINT)
  and no `watchdog.exit` sits beside it — the file the watchdog writes only when it stops on its
  own judgement — so nothing inside the run decided anything. Such a run used to score
  `STALLED`, which `/mesh-review` Step 6.0.4 re-dispatches as "retry helps"; on 2026-08-05 three
  of those re-dispatches died exactly as the runs they replaced. `KILLED` is excluded from
  `PROBLEMS` and reported for what it was — the review was alive when it was killed, so the
  fault is in the launch, not in the model. The check is engine-agnostic and deliberately does
  **not** key on a lifetime near the cap: the same session produced 143s from three different
  senders (the harness cap, an orchestrator `TaskStop` on the wrapper, and a wrapper killing its
  own run), and a corridor heuristic would have confused them. The verdict weighs what the signal
  **cost**, not that one arrived: every non-`REAL` outcome routes through one `fail` helper that
  promotes it to `KILLED` when the run was signalled, while a run that had already delivered a
  usable review reaches `REAL` and keeps its findings. That holds on every engine — the first cut
  emitted `KILLED` from the watchdog exit code before the codex/gemini branch had looked at the
  content, so a finished codex review with a signalled tail was excluded rather than kept, and
  the ext-claude branch never consulted the signal at all, so a killed run there was still
  re-dispatched (`STALLED`) or dropped as a broken engine (`BROKEN`) — the latter telling the
  user to swap a model that had done nothing wrong. `num_turns<=1` is the one `BROKEN` a signal
  moves: a run that dispatches a background subagent answers "started" with `num_turns` 1 and
  delivers the review in a later segment, and a kill between the two leaves exactly that shape.
  The reason line now also carries the run's lifetime (`after 601s`), computed from
  `watchdog.log` — both orchestrators are told to report it and to read a cluster of deaths at
  the same round number as the foreground-cap signature, and neither can compute it for itself.
  A `SIGINT` no longer blames the Bash cap, which raises `SIGTERM` and cannot produce a 130.

### Fixed (second pass — found by reviewing this release's own changes)
- `/mesh-review` Step 6.0.4b said "Wait for completion" after re-dispatching, which the same
  branch turned into a no-op: a wrapper now launches its engine in the background and ends its
  turn, so its Task returns within seconds and the guard in step c inspected a run dir that had
  barely been created — scoring every re-dispatch `STALLED` or `FLIP` and spending the whole
  `max_redispatch` budget without a single run finishing. It now runs the same disk-watch + ping
  loop as Step 5a against the re-dispatched roster.
- `watchdog.sh`'s `cleanup` tore down the process group *before* writing the `cleanup` heartbeat
  that the `KILLED` verdict is read from — up to 15 seconds later (10 grace seconds on TERM plus
  5 on KILL). A sender that follows its SIGTERM with a SIGKILL inside that window left a log
  ending at the last `alive` line, indistinguishable from a genuine stall. The record is now
  written first.
- An existing-but-unreadable `watchdog.log` failed open into `STALLED`: the read error was
  swallowed, so "the evidence says nothing happened" and "the evidence could not be read" gave
  the same answer, and the run was re-dispatched into whatever had killed it. The verdict now
  says which of the two it is.
- A dead `.watchdog_rc` check ran before the signal was weighed, so a 143 in that file masked
  `KILLED` behind "engine exit code != 0". Nothing under `skills/` writes it, but the test
  fixtures do, and any future writer would have inherited the mask.
- `config.example.yaml`'s `max_redispatch` comment still said a run killed mid-flight is
  re-dispatched, and listed `BROKEN` as the only verdict never retried. It now names all three
  (`BROKEN`, `DEGRADED`, `KILLED`).
- Both orchestrators now fall back to **reading the run's `output.txt` themselves** when a
  wrapper stays silent through two pings, instead of writing the reviewer off. A report is how
  findings travel, and travel is the part that breaks: the harness sends an idle subagent no
  notification when its background task exits, and a composed report can still be lost on top of
  that. On 2026-08-05 an `alibaba/qwen` run finished with `num_turns=22` and an 11428-byte review
  on disk while the same session recorded that model as having produced nothing across five runs
  and dropped it from the cross-validation — the review was never missing, only undelivered. The
  rule both files now state: a reviewer is never "silent" or "empty-handed" while
  `verify-delegation.sh` scores its run `REAL`, because that verdict is a statement about the
  file, made from the disk. `output.txt` specifically, never `report.md` — the latter is the
  whole run rendered by `generate-md.sh` and measures 137–250 KB in the archive, against 11 KB
  for a large review.
- `REAL` now requires a review, not merely a non-empty file. The only content test it ever
  applied was "output.txt is not blank", and a model that delegates the work and reports the
  delegation clears that: on 2026-08-05 `deepseek/v4-pro` delivered "Ревью запущено … Ожидаю
  результаты, уведомлю вас по завершении" twice — with `num_turns` 7 and 5 behind 24 and 17 tool
  calls, agentic by every signal the gate had — and `/mesh-review` counted both as cross-
  validating reviewers. A stub that passes is worse than a run that fails: it inflates "N models
  agreed" with a model that said nothing. The floor is a length because nothing more specific
  survives the archive — the stubs share no distinguishing tool and no distinguishing turn count
  (a genuine 460-byte review ran 15 turns; a stub ran 7), and keying on their wording is the
  mistake the `permission_denials` check already documents. Across every archived run with a
  non-empty output (336 ext-claude, 78 codex) everything under **400 non-space bytes** was a
  stub, a torn fragment, leaked tool grammar or an "approve this command" note, while the
  shortest genuine review measured 460 (ext-claude) and 1746 (codex). Replaying all 624 archived
  runs through both versions of the gate, the floor moves exactly the two stubs out of `REAL`
  — every one of the other 198 `REAL` verdicts is unchanged — plus five `DEGRADED` runs whose
  "review" was an approval request, DSML grammar, or a summary of findings that are not in the
  file. `STALLED` and not `BROKEN`: a stub is not proof the engine cannot review (the same
  session's 11428-byte review came from a comparable model on a later attempt), so one
  re-dispatch is a fair use of the budget — and on a signalled run the verdict stays `KILLED`.
  For codex and gemini the floor is checked **after** the tool-call test, so "finished a turn and
  ran nothing" keeps saying `BROKEN`.
- `shared/preflight-env.sh` gained a `bash-timeout` row: it compares the harness's foreground
  ceiling — the larger of `BASH_MAX_TIMEOUT_MS` and `BASH_DEFAULT_TIMEOUT_MS`, both defaulted as
  Claude Code defaults them — against `runtime.timeouts.global_sec × 1000`, and reports `LOW`
  with the exact value to set when the ceiling is below it. Not a blocker (background launches
  are not subject to the cap) and not `MISSING` (the stock values are valid Claude Code
  settings, just too small for these budgets); it is for the machine that never set them, where
  the alternative to a row is diagnosing a `KILLED` after a review dies at 600s.
- The three `*-executor` agents run the same supervised block as the reviewer agents —
  `/mesh-design-review` dispatches them with `SUPERVISED_MODE: shell` — but only the reviewers
  got the background-launch and no-self-relaunch rules. Both now sit on the executors too.

## [0.7.1] - 2026-08-04

### Fixed
- `ext-claude-exec` invoked `claude -p` with no permission flag at all, so every reviewer on
  an alt-provider model was silently confined to the directory the orchestration was launched
  from. Under `-p` there is nobody to answer a permission prompt, so each request is
  auto-denied rather than raised: on 2026-08-04 a `/mesh-design-review` had all five reviewers
  (zai/glm, alibaba/qwen, deepseek/v4-pro, ollama/kimi, ollama/minimax) unable to open a single
  file outside the project — one of them asked, in its own output, for permission to read a
  `pom.xml` — while codex in the same session read a neighbouring repository 37 times without
  one refusal. Nothing was lost in a refactor: `git grep` across all 201 commits finds no
  permission flag on the ext-claude path in any tree, ever. The asymmetry dates to the first
  commit, where codex already carried `--dangerously-bypass-approvals-and-sandbox` and gemini
  `--approval-mode yolo` — ext-claude was the one engine for which the question was never
  asked. Both invocations now pass `--permission-mode bypassPermissions`: the default
  `progress-monitor.sh` pipeline **and** the supervised `watchdog.sh` one, which is the branch
  every orchestrated review actually takes. `--add-dir` is deliberately not added alongside it
  — measured on CC 2.1.221, the bypass lifts the directory confinement by itself, so there is
  no list of trusted roots to keep in sync with each project.

### Added
- `shared/verify-delegation.sh` gained a fifth verdict, `DEGRADED` (exit 5, ext-claude only),
  for a run that delivered a real agentic review after the CLI had refused N of its tool calls.
  Every signal the gate already had reads healthy on such a run — finalized, `is_error:false`,
  `num_turns` far above 1, non-empty `output.txt` — so a review written without access to the
  sources it tried to open scored `REAL`, and the only way to notice was to read `raw.jsonl` by
  hand. That is exactly how the bug above surfaced. The verdict reads `permission_denials` off
  the result event — one entry per refusal, carrying the tool name and the input that was
  refused — so the reason line reports both a count and a breakdown (`Read×2, Bash×1`), which
  says whether the reviewer lost source files, searches or both. Denials are counted on
  **successful** result events only, matching how `num_turns` is taken: refusals belonging to a
  segment the run abandoned never constrained the review that was delivered. A result event
  that omits the field is REAL — absent is not denied. `DEGRADED` is checked last, so `STALLED`
  and `BROKEN` keep precedence. Both orchestrators keep such a reviewer's findings and never
  re-dispatch it (an identical invocation is refused identically), and `/mesh-review`'s
  delegation table must name the denial count rather than just the verdict.
  An earlier revision of this check grepped the refusal *text* out of `tool_result` bodies
  instead. It was replaced before release because it failed in both directions: the CLI has
  more refusal wordings than the two that had been sampled, and any **failed** tool call whose
  output quoted one of them scored `DEGRADED` — which reviewing this repository reliably
  produces, since the wordings are written down in it. The regression tests pin both directions.

## [0.7.0] - 2026-08-04

### Added
- `/claude-mesh:design-review-fresh-session` and `/claude-mesh:code-review-fresh-session`
  generate the prompt for a fresh session that reviews a design+plan, or a finished
  implementation, instead of executing it. Both are built for a review that runs somewhere
  else — typically a sandbox VM sharing the working copy — so neither generator reads
  `config.yaml` and neither prompt names a model: the reviewing session runs the new
  `skills/shared/preflight-env.sh` in its own environment and selects from what that reports.
  The probe emits one row per capability (plugin identity, config state, the built-in `claude`
  reviewer, the Claude catalog, codex/gemini gated on their config section first and their
  network second, one probe per provider through the existing `token-precheck.sh` /
  `ollama-precheck.sh`, git remote, gh/glab, clipboard) and a `SUMMARY` block naming the
  reviewers that can actually be selected there. Every verdict exits 0 — a non-zero exit means
  the probe is broken, could not start (bash 4+ is required) or was interrupted, never that the
  environment is poor. Provider tokens never reach the output and exported env files are removed
  through a trap. Its two budgets — `PREFLIGHT_HTTP_TIMEOUT` and `PREFLIGHT_GIT_TIMEOUT` — are
  validated as positive integers rather than pasted into `curl --max-time` and `timeout` as
  given: a bad value there did not degrade a verdict, it decided one (`--help` made `timeout`
  print its usage and exit 0 without running git, and the row then read `git-remote OK` about a
  remote nothing had contacted). The probe invokes `config-loader.sh` and both prechecks as
  `bash <script>` — the same reason the generated PREFLIGHT block runs the probe itself that
  way: a shared-folder mount, the environment this is built for, drops the exec bit.
  `skills/ext-claude-exec/ollama-precheck.sh` grew three env knobs so a caller on
  a fixed budget can shrink its retries — `OLLAMA_PRECHECK_TRIES`,
  `OLLAMA_PRECHECK_ATTEMPT_TIMEOUT` and `OLLAMA_PRECHECK_TAGS_TIMEOUT`; the defaults reproduce
  the previous fixed 3×2s budget exactly, and all three are validated now that the probe has
  made them a public interface (`TRIES=0` skipped the loop and still reported `UNREACHABLE`
  "after 0x2s").
  A new `skills/shared/tests/test-command-sync.sh` holds the two command files byte-identical
  where the prompt's experimentally measured wording lives — the `DO NOT` gate and the
  `PREFLIGHT` block — which until now was held by a comment alone. `mesh-design-review` Step 15
  now routes its next iteration into the new generator, and `/do-plan` Step 7 points at the
  code-review one and states that a sandbox cannot finish a branch that needs a push.
- `/claude-mesh:mesh-review` takes `BASE_BRANCH=<branch>` and carries it to every reviewer,
  re-dispatch included. Without it each review skill re-detects the base itself — `git
  symbolic-ref refs/remotes/origin/HEAD`, falling back to `master` — so in a repository whose
  default branch is `main`, or when reviewing against anything but the default branch,
  `merge-base` finds nothing and the codex / gemini skills fall back to `HEAD~1`: a single
  commit reviewed while the caller believes the whole branch was, with nothing on screen saying
  otherwise. `/claude-mesh:code-review-fresh-session` resolves the base locally and emits the
  argument in the invocation it writes.

### Fixed
- `ext-claude-code-review` resolves its base branch the way the codex and gemini skills already
  did — the bare name, then `origin/<name>` — and stops instead of reviewing nothing when neither
  resolves. The name it is given need not exist as a *local* branch: `origin/HEAD` yields a bare
  name, and `BASE_BRANCH=` now reaches this skill from `/claude-mesh:mesh-review` naming whatever
  the caller wants reviewed against. A single lookup left `BASE_SHA` empty, the prompt template
  rendered `git diff ..<head>` — which git reads as `HEAD..HEAD`, zero bytes and exit 0 — and the
  reviewer reported "no issues" about a diff it never saw. Deliberately not codex/gemini's third
  fallback `git rev-parse HEAD~1`: reviewing one commit while the caller believes the whole branch
  was covered is the same silent lie in another shape.
- `skills/shared/config-loader.sh` rejects a newline inside a model label, as it already
  rejected `|`. One entry otherwise became two, and the phantom reached `preflight-env.sh` as a
  row whose name held spaces — shifting an arbitrary word into the status column, where it can
  read `AUTH-FAILED` and satisfy every closed-set check with a verdict nothing measured.

## [0.6.0] - 2026-07-28

### Fixed
- The `/mesh-review` and `/mesh-design-review` watch loops could not tell a slow
  executor from a dead one — both leave the same disk, and every finalization predicate
  was about a result *appearing*. The only backstop was `runtime.timeouts.global_sec`,
  an hour of blindness by default, and when it fired it reported `WATCH_TIMEOUT` rather
  than naming the death. A new `skills/shared/watch-runs.sh` classifies each dispatched
  executor as `DONE` / `FAILED` / `RUN` / `SILENT` / `MISSING` and returns as soon as any
  of them stops running, naming the executor and the transition. It holds a roster of
  `engine[/provider/model]` rather than run directories, so an executor that dies and
  self-retries into a new directory is followed instead of being reported dead. Freshness
  is the newest mtime across `raw.jsonl`, `log.jsonl`, `watchdog.log` and
  `attempt-*/raw.jsonl`, so a supervised run between watchdog retries reads as `RUN` on
  its heartbeat. Finishing is deliberately not judged on `output.txt` alone, in either
  direction. `watchdog.sh` never writes that file — the `*-exec` skill extracts it from
  `raw.jsonl` after the watchdog returns, 0-33s later across 249 archived runs — so a run
  that exited 0 with nothing yet on disk stays `RUN` for a settle minute instead of being
  called `FAILED` over a file still being written. Without a watchdog a non-empty
  `output.txt` is not a finish either: `gemini-exec` appends to it inside its stream loop,
  so a live run would read `DONE` and hand back half a review. `report.md`, which all three
  `*-exec` skills write only after that loop ends, is the stop signal there. Recovery is
  deliberately not signalled: the baseline is virtual — every
  roster entry is assumed `RUN`, so an already-dead run is caught on the first tick after
  every restart, and an executor that recovers on its own produces no event. Both prompts
  now call the script instead of describing a poll loop in prose; the improvised
  implementation exited only when the finished count grew, which death never does. An
  executor's unprompted message is now spent on a `--once` liveness check rather than on
  an acknowledgement. A budget expiring on the same tick something moved names the
  transitions (`DEADLINE codex RUN→DONE`) instead of summarising a finished run as a bare
  `DEADLINE`, and the roster validator rejects `.` as a path component alongside `..`.
- `/mesh-design-review` never passed `SUPERVISED_MODE`, so its executors ran unsupervised
  by default: no `shared/watchdog.sh`, no stall detection, no restart on a torn provider
  stream, and no `watchdog.log`. Whether a run got a watchdog was luck — 42 of 223 archived
  runs did, against 242 of 255 on the `/mesh-review` path. Step 6 now dispatches every
  executor with `SUPERVISED_MODE: shell`, and `codex-executor` / `gemini-executor` /
  `ext-claude-executor` document the parameter so it is forwarded to the skill instead of
  leaking into the prompt.
- `shared/verify-delegation.sh` picked the newest run dir by mtime while `watch-runs.sh` picks
  it by name. On bail an abandoned dir gains a `final` symlink, which lifts its mtime above the
  retry dir that superseded it, so the two disagreed on which run was "the run" — the watcher
  reporting `DONE` on the retry while the gate reported `STALLED` on the corpse. Now that
  design review chains them on the same run, that disagreement discarded a finished review, so
  the gate orders candidates by name too. Its codex/gemini branch also stopped being a no-op:
  it checked `.watchdog_rc`, which nothing under `skills/` writes, and then only that
  `output.txt` was non-empty — the same question the caller had already answered. It now reads
  the watchdog's real exit code out of `watchdog.log` and requires the CLI's own terminal event
  (`turn.completed` / `result`) plus at least one tool call, which is the codex and gemini
  analogue of `num_turns<=1`. A narration-only draft is `BROKEN` for those engines instead of
  `REAL`. Three more holes in that gate closed after a second review round: candidates are
  shape-filtered to timestamp-named directories like the watcher's (in `LC_ALL=C` letters sort
  above digits, so a stray `tmp/` — or the provider directory a truncated model argument
  resolves to — outranked every real run and read `STALLED` where the truth was `REAL` or
  `FLIP`); a gemini result event carrying an explicit `status != "success"` is `STALLED`
  rather than `REAL` (the CLI can exit 0 on an API failure while `gemini-exec`'s extraction
  writes `API Error: …` into `output.txt`); and a finalized run with no stream file at all is
  `STALLED` — every layout the exec skills produce carries one, so its absence means the
  checks would otherwise be skipped on a layout nothing in the tooling wrote.
- `/mesh-design-review` accepted an executor's report without checking that the run had
  produced one. A run that stops and leaves a non-empty `output.txt` looks finished even
  when the file holds only the model's narration. It now runs `verify-delegation.sh` — the
  guard `/mesh-review` has used since Step 6.0 existed — before asking an executor to
  extract findings.
- A watcher or content gate could resolve a run directory belonging to a different
  orchestration. Both pick the newest run dir under `runs/<engine>[/provider/model]`, and the
  plugin's data dir is global, so two `/mesh-review` or `/mesh-design-review` sessions on the
  same engine/model — in two different repositories — saw each other's runs: the earlier
  session could report `DONE`/`SILENT` about a run it never dispatched, ping its wrapper
  early, and hand `verify-delegation.sh` the wrong directory, discarding a finished review.
  The four skills that create a run dir now stamp `$CLAUDE_CODE_SESSION_ID` into
  `<run dir>/.session_id`, and both consumers walk their existing newest-first order until
  they reach a run of their own. The identity is ambient rather than passed down the dispatch:
  the variable is inherited across the agent boundary, so an executor cannot fail to forward
  it and an improvised re-run inherits it automatically. A directory with no stamp stays
  eligible — legacy runs, direct `/claude-mesh:*-exec` invocations and a harness without the
  variable must keep working, and reporting `MISSING` for a live unstamped run would be worse
  than the collision. Two orchestrations inside one session remain indistinguishable. When the
  reader's own id is the one that moved — a resumed or forked session, where every live run is
  suddenly foreign — neither consumer can find a run, and both now say so instead of reporting
  it as a death: the watcher's `MISSING` row and the gate's `FLIP` reason both name how many
  in-window runs belong to another session. Both prompts route the watcher's annotated row
  away from their failure paths. The gate's annotated `FLIP` keeps `/mesh-review`'s
  re-dispatch — a fresh run carries this session's id and is the only way back to a checkable
  answer, and the guard cannot tell "my id moved" from "a real flip whose window overlaps
  another orchestration's runs" — but such a reviewer is never recorded as having failed to
  delegate; the summary names the session mismatch instead.
- `shared/verify-delegation.sh` and `shared/watch-runs.sh` disagreed about which runs are even
  *in* the dispatch window, which is the same class of defect as the mtime-vs-name winner above
  and survived that fix. Eligibility in the gate was `find -newermt` — MODIFICATION time — while
  the watcher compares the run-dir name against `--since` rendered the same way. A run created
  before the window but still being written stays mtime-eligible indefinitely, so `/mesh-review`
  Step 6.4a, which stamps a fresh epoch precisely "so the guard inspects the NEW run, not the
  old failed one", still handed the gate the old one: a wrapper that flipped on re-dispatch and
  produced no run dir at all was scored `REAL` off the previous round's corpse. The gate now
  filters candidates by name against the same rendering the watcher uses, so the two windows are
  identical by construction. Three smaller divergences closed with it: the gate picked
  `output.txt` with `-f` where the watcher uses `-s`, so an existing-but-empty root file beat a
  `final/output.txt` holding the actual review (`DONE` from the watcher, `STALLED` from the
  gate); name comparison and sorting now run under `LC_ALL=C` in both, since a UTF-8 collation
  ignores `-` and would order run dirs differently; and a non-numeric `since-epoch` — an
  unsubstituted `$DISPATCH_EPOCH`, which expands to nothing — is a usage error rather than a
  silent `FLIP` for every reviewer. `/mesh-review` Step 6.0 stopped passing that variable
  through a shell reference that cannot survive between Bash tool calls.
- `shared/verify-delegation.sh` had no GNU-`find` probe although it depends on `-printf`, so on
  a BSD `find` the candidate walk failed silently and every reviewer came back `FLIP` — which
  `/mesh-review` acts on by re-dispatching all of them. It now fails loudly, like the GNU-`stat`
  probes in `config-loader.sh` and `watch-runs.sh`.

### Requirements
- `shared/watch-runs.sh` and `shared/verify-delegation.sh` need **bash 4.2**, up from the 4.0
  the rest of the plugin asks for: both render a timestamp with the `printf '%(fmt)T'`
  builtin. `verify-delegation.sh` also states the **GNU `find`** dependency it always had
  (`-printf`) and probes for it at startup. README's macOS setup gains `findutils` and its
  gnubin path — `coreutils` does not provide GNU `find`.

### Configuration
- No new keys. `runtime.timeouts.stall_sec` gains a second consumer: the orchestrator's
  watcher reports a run `SILENT` past that threshold. The watcher floors it at 600, because
  `codex-exec` and `gemini-exec` hardcode `HARD_ZERO_TIMEOUT=600` and ignore the key — a
  lower value would let the watcher call a live run dead before its own watchdog acts.

## [0.5.0] - 2026-07-27

### Added
- Multi-model built-in Claude reviewers. A new optional `claude:` section holds a
  catalog of Claude model aliases (`claude.models: [opus, sonnet, fable]`), and a new
  per-preset key `defaults.<preset>.claude_models` picks the default subset. Both
  `/mesh-review` and `/mesh-design-review` now run **one independent reviewer per
  selected Claude model** — same input, same prompt, different model — so a session on
  `opus` can be cross-checked by `opus` and `fable` at once, with your session
  aggregating both. The interactive UI gains a Claude-model page (★ marks the preset's
  picks); `default` mode reads the preset. Reviewers are attributed as `claude:<model>`
  in the dedup table, the delegation roster (as `INLINE`, never passed to
  `verify-delegation.sh`) and the merged design-review file. Loader support:
  `get-flag has_claude_models`, `list-claude-models`, and a `claude_models` field in
  `get-defaults`.
  `runtime.dispatch_model` is unchanged and still governs the codex / gemini / ext-claude
  wrappers, `review-discussion` and `/do-plan`; claude reviewers with an explicit model
  ignore it. Configs without a `claude:` section — or with a catalog but no models
  selected — keep the old `/mesh-review` behaviour exactly: one claude reviewer on
  `dispatch_model`, or on the session model when that is unset.

### Fixed
- `claude` in `defaults.design_review.builtin` was silently dropped. The loader accepted
  the value, but `/mesh-design-review` expanded only `codex` and `gemini` in `default`
  mode and offered no `claude` option in its interactive reviewer-type question —
  so design review had never once run a built-in Claude reviewer. Both paths now expand
  it — so a `design_review` preset that already lists `claude` gains one reviewer, and
  its cost, on upgrade with no config change. The related fail-closed guard is new too:
  `claude_models` set without `claude` in the same preset's `builtin` is now a validation
  error rather than another silently ignored list.
- `/mesh-design-review` swallowed the validator's exit code when reading its preset. Its
  Step 5.0 fence ran `DEFAULTS_JSON=$("$LOADER" get-defaults design_review)` bare, so a
  config.yaml that failed validation left `DEFAULTS_JSON` empty and Step 5.1 then STOPped
  with the misleading "defaults.design_review not configured" instead of the real error.
  The read is now rc-aware and surfaces the validator's stderr verbatim, matching the
  `dispatch_model` read directly below it and `/mesh-review` Step 1.

## [0.4.3] - 2026-07-22

### Fixed
- Delegation guard no longer discards genuine external reviews whose stream
  carries more than one `type:result` event. `verify-delegation.sh` read
  `num_turns` from the LAST event (`tail -1`); when an external model
  dispatches a background subagent it answers "work started", the session
  resumes, and the final event describes only the short closing segment
  (`num_turns:1`) — so a full agentic review (44 assistant events, 19
  `tool_use`, 8933 bytes of findings whose cited line numbers checked out) was
  stamped `BROKEN`, the one verdict `/mesh-review` never retries: findings
  dropped, user told to swap the model in `config.yaml`. Classification now
  takes the MAXIMUM `num_turns` over result events — max and not sum, since
  summing two non-agentic segments (1+1) would fabricate a `REAL` out of a run
  that read no code. `ext-claude-exec/generate-md.sh` keeps its `tail -1`:
  there the last result legitimately carries the answer.
- Hardening of that guard after a 7-reviewer `/mesh-review` (codex, zai/glm,
  alibaba/qwen, deepseek/v4-pro, ollama/kimi, ollama/minimax, builtin claude —
  all seven verified `REAL` by the guard under test): errored result events no
  longer feed the maximum, because five historical runs carry
  `{"subtype":"success","is_error":true,"num_turns":95,"result":"Prompt is too
  long"}` — `subtype` lies, `is_error` is the signal — and both the old and the
  new selection had been admitting that 18-character failure string as a real
  cross-validation; a stream whose FINAL result event errored is `STALLED`,
  since `progress-monitor.sh` REWRITES `output.txt` per result event, so the
  delivered text is the last segment's and the lone `"\n"` it leaves sailed
  through `[ -s ]`; `num_turns` must be a non-negative integer to reach
  `[ "$NT" -le 1 ]` (`[` errors on anything else, the error was swallowed, the
  `if` read false and the run fell through to `REAL`); `REAL` now requires
  `output.txt` to hold non-whitespace, not merely bytes. Replaying the old and
  the new logic over 228 historical run dirs gives 12 verdict changes, all
  accounted for.
- Slash commands no longer run a stale copy of the shared loader. All four
  sites located `config-loader.sh` with `find … | head -1` — directory order,
  not version order — which returned 0.4.0 while 0.4.2 was installed, and was
  blind to `--plugin-dir` (command TEXT came from the working tree but SCRIPTS
  from the installed cache, so a dogfood run never exercised the copy under
  test). `CLAUDE_PLUGIN_ROOT` is empty as a shell variable in slash-command
  Bash calls, but the harness substitutes the placeholder into command and
  skill TEXT before the call, inside bash fences too (measured on CC 2.1.217);
  it names the active copy, so it is tried first and the glob stays a fallback,
  now `sort -V | tail -1`. The same substitution made the "config.yaml ещё не
  создан" hint print the wrong data dir under a `--plugin-dir` load; both twins
  now print `$("$LOADER" data-dir)`. New `shared/tests/test-loader-resolution.sh`
  extracts the live snippet out of the markdown and executes it, so the four
  duplicated copies cannot drift from the assertions.
- `/do-plan` Step 2 no longer claims that the command and the `PostToolUse`
  hook "converge on one absolute path". The hook takes the data dir from
  `$CLAUDE_PLUGIN_DATA` while the command asks the loader; on a marketplace
  install both land on `claude-mesh-zinin`, but under a `--plugin-dir` dev load
  they diverge, the per-session config is written where the hook never looks,
  and the STOP threshold silently never fires. Documented here; the hook itself
  is a separate task.

## [0.4.2] - 2026-07-17

### Fixed
- Disputed-issue discussion no longer loses the structured analysis behind an
  `AskUserQuestion` modal (`/mesh-review` Step 6.4, `mesh-design-review`
  Step 12). The model withholds prose emitted before a self-presenting tool
  call, so users saw a bare modal without the Суть → Анализ → Варианты →
  Рекомендация write-up. The analysis is now the turn-final message (no
  trailing tool call) and the user answers in free text; `AskUserQuestion`
  remains only at self-contained sites (reviewer/model selection,
  design-review "what next"). `/mesh-review default` defers multi-variant
  disputed issues instead of waiting for an absent user.
- Hardening from the pre-merge max-effort review of that fix (12 findings,
  5 confirmed): stop-token sets synced between the twin flows (`stop` is now
  recognized by `/mesh-review` too) and the stop check runs BEFORE
  apply/record, so a «стоп» reply can no longer produce a phantom answers
  entry or an unintended edit; the turn-final closing prompt is Russian like
  every other user-facing template; `default`-mode carve-outs added to Iron
  Rules 7–8 and 6.4.c (the unconditional "wait" wording could hang an
  unattended run); the Step 6.6 summary separates «стоп» deferrals from
  `default`-mode ones and lists every deferred issue with its recommended
  variant; `mesh-design-review` deferred issues now reach `answers`, the
  iteration log and Step 15 counts (previously they silently vanished from
  the committed iter file); a background watcher/task event resuming the
  turn-final wait is never treated as the user's answer; `review-discussion`
  agent description matched to reality (parses and returns results — never
  talks to the user or edits documents).

## [0.4.1] - 2026-07-16

### Fixed
- Review-prompt templating no longer corrupts CONTEXT on bash >= 5.2: the
  `${PROMPT//\{DESCRIPTION\}/$DESC}` snippet in `ext-claude-code-review` relied
  on a literal-replacement guarantee that bash 5.2 revoked — the
  `patsub_replacement` shopt (on by default) expands an unquoted `&` in the
  replacement to the matched pattern, so a CONTEXT carrying shell commands
  (`cd test-server && python3 -m unittest ...`) rendered as `cd test-server
  {DESCRIPTION}{DESCRIPTION} python3 ...` (2026-07-16 mesh-review incident;
  wrappers recovered only when the reviewer model noticed the corruption
  itself). All three review skills (`ext-claude-code-review`,
  `codex-code-review`, `gemini-code-review`) now render
  `shared/code-review-prompt.md` via the new `shared/render-template.py`:
  argv values are substituted str-literally on any bash version, in a single
  pass (placeholder-looking text inside a value is never re-substituted).
  Covered by `shared/tests/test-render-template.sh`, including a dry run of
  the real template with a hostile `&& & \&` CONTEXT.
- Hardening pass on the templating fix after a 7-reviewer `/mesh-review`
  (codex gpt-5.5, 5 ext-claude models, builtin claude): `codex-` /
  `gemini-code-review` Step 3 now passes DESCRIPTION / PLAN_REFERENCE through
  quoted heredocs into `"$VAR"` expansions instead of instructing the agent to
  inline prose into single quotes — an apostrophe in commit-derived text broke
  the command, and a crafted `x'; cmd; : '` value would have executed
  (found by 6 of 7 reviewers, escalated to Critical by codex); `python3` is
  now pre-flighted in all three review skills and its README Dependencies row
  covers the shared renderer; `ext-claude-code-review` Step 1 fails loudly
  when rendering fails or yields an empty prompt (previously an empty
  `$PROMPT_FILE` would silently produce an empty review); the renderer
  documents last-wins duplicate pairs and its byte-preserving surrogateescape
  I/O contract, derives both name regexes from one charset and truncates bad
  NAME=VALUE diagnostics to 64 chars; tests grew a metacharacter-zoo calling
  convention case, an `LC_ALL=C` round-trip, a byte-exact `cmp` check and a
  duplicate-pair contract case.

## [0.4.0] - 2026-07-10

### Fixed
- `config-loader.sh` no longer aborts on an unknown `codex.reasoning_level`
  (e.g. the new gpt-5.6 `ultra`): unknown levels WARN and pass through — the
  codex CLI/API is the final validator. Previously a single unknown level in
  the `codex:` section killed `export` for **every** ext-claude executor
  mid-review and pushed blocked review subagents into "fixing" the user's
  config (`ultra` → `xhigh` flips).
- codex agent definitions (`codex-executor`, `codex-code-reviewer`,
  `codex-native-reviewer`) no longer hardcode `gpt-5.5`/`xhigh` mandates that
  bypassed config-driven resolution on the `/mesh-review` and
  `/mesh-design-review` dispatch paths (final-review finding).
- `validate_codex` now type- and charset-checks `codex.model` /
  `codex.reasoning_level` (same forward-compatible charset as
  `runtime.dispatch_model`): a non-string value (e.g. an unquoted
  `reasoning_level: 3`) used to pass validation and then crash `get-codex`
  with a raw jq type error, and a `|` in a value silently corrupted the
  `model|level` protocol. Unknown-but-safe string levels still WARN and pass
  through; the known-levels contract is now locked by tests (0.4.0 pre-merge
  external review, fix wave 3).
- `/mesh-review` and `/mesh-design-review` orchestrators now disk-watch
  external runs and ping idle wrapper reviewers: a wrapper launches its engine
  as a background task and never wakes on its completion (the harness delivers
  no task-notification to idle subagents), so finished reviews sat unreported
  until a manual ping (0.4.0 pre-merge external review, fix wave 4).
- Wave-5 fixes from the 0.4.0 pre-merge `/mesh-review` smoke (7 reviewers):
  `codex.model` charset now allows provider-qualified ids
  (`openai/gpt-oss-20b`); `get-runtime` exposes the `timeouts` block the
  orchestrator disk-watch is told to read; a scalar `codex:`/`gemini:` section
  (`codex: false`) dies cleanly instead of crashing typed getters with a raw
  jq error; an empty config.yaml dies without bash arithmetic noise; watch
  loops run as a background Bash task, count only a non-empty root
  `output.txt` as finalization (gemini-exec pre-creates a zero-byte one) and
  ping each finished-but-silent wrapper once per poll cycle; loader test
  suite grown to 171 assertions (export-own-sections and known-level
  round-trip regression guards; duplicate test numbering fixed).
- `validate_runtime` type-gates `runtime:` and `runtime.timeouts` like the
  wave-5 `codex:`/`gemini:` gates: `runtime: false` used to pass validation
  silently, and a non-mapping `timeouts` passed it with raw jq noise — both
  then crashed `get-runtime` (raw jq rc=5), which the `/mesh-review` /
  `/mesh-design-review` watch loops call for `timeouts.global_sec` (Codex
  PR-review P2, fix wave 6; loader suite 171 → 180 assertions).

### Changed
- `cmd_export` validates only the sections it reads (providers/models/runtime).
  Errors in `codex:` / `gemini:` / `defaults:` can no longer block ext-claude
  runs. `validate` remains the full-config lint.
- `get-codex` / `get-gemini` likewise validate only their own section — a
  malformed `gemini:` section no longer blocks config-driven codex resolution
  (and vice versa); Codex PR-review finding.
- Known reasoning levels extended to `none|minimal|low|medium|high|xhigh|ultra`.
- Loader test suite: the unknown-level test asserts the new warn-and-pass
  contract; new scoped-export assertion (codex-section errors don't block
  `export`).

### Added
- codex executors (`codex-exec`, `codex-code-review`, `codex-review-native`)
  resolve MODEL / REASONING_LEVEL from `config.yaml` (`codex.model` /
  `codex.reasoning_level`) when the caller passes none — mirroring the existing
  gemini-exec idiom. `/mesh-review` and `/mesh-design-review` become
  config-driven for codex transitively. Precedence: explicit caller parameter >
  config.yaml > `gpt-5.5`/`xhigh` fallbacks.
- Guardrail wording in every pre-flight: on config failures agents STOP and
  report verbatim; `config.yaml` is user-owned and never edited by agents.

## [0.3.0] - 2026-06-15

### Changed
- Subagent dispatch model is no longer hardcoded. The static `model: fable` pin
  was removed from all mesh agents; by default subagents now **inherit your
  current session model** (your `/model`), so a model alias opening or closing no
  longer requires editing the plugin. The "never delegate to a cheaper model"
  policy is preserved relative to the resolved/session model rather than a literal.
- README/Dependencies: dropped the hard requirement for a Claude Code build whose
  Agent model enum includes the `fable` alias.

### Added
- Optional `runtime.dispatch_model` config knob: set it to **force** a specific
  tier on every `/do-plan`, `/mesh-review`, and `/mesh-design-review` dispatch;
  leave it unset (or omit `config.yaml`) to inherit the session model. Accepts any
  model alias or full id, including cloud-provider ids (Bedrock `…-v2:0`, Vertex
  `…@date`). Exposed via `config-loader.sh` (`get-flag` / `get-runtime`).

## [0.2.0] - 2026-06-10

### Changed
- Model policy switched from `opus` to `fable` (`claude-fable-5`): `/do-plan`
  now treats Opus as a forbidden "cheaper" model for subagent dispatch, and all
  mesh agents are pinned to `model: fable` via frontmatter.
- verify-delegation FLIP diagnostics reworded to be model-neutral.
- README: Dependencies now require a Claude Code build whose Agent tool model
  enum includes the `fable` alias.

## [0.1.0] - 2026-06-07

### Added
- Initial release: ext-claude-* family, codex/gemini wrappers, mesh-review,
  mesh-design-review, session/plan helpers, check-context-size hook.

### Fixed
- check-context-size hook is now scoped to the `/do-plan` session: it no longer
  injects `ctx:` milestone reminders into ordinary sessions (which made the agent
  economize context prematurely). `/do-plan` writes a per-session config file
  `do-plan-config-<cwd>-<session>.json`; the hook emits milestone/STOP only in the
  session that owns a file. Two concurrent `/do-plan` runs in one cwd no longer
  clobber each other. Old per-cwd `do-plan-config-<cwd>.json` files (pre-change)
  have a different name and are ignored — re-run `/claude-mesh:do-plan` to re-bind.
