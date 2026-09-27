---
name: grok-exec
description: Execute any prompt via the xAI Grok CLI with full logging and progress display
user_invocable: true
---

# Grok Exec

Execute arbitrary prompts via the Grok Build CLI with streaming progress and full logging.

**Announce at start:** "Using grok-exec skill to run prompt via Grok."

> **Grok manages its own auth.** Like codex and gemini — and unlike the ext-claude skills —
> grok is NOT an anthropic-api provider: the `grok` CLI logs in by itself (`grok login`).
> This skill does NOT call `config-loader.sh export` and does NOT source `ANTHROPIC_*`. The
> loader is used ONLY to (a) find the plugin data dir for run logs, (b) gate on the `has_grok`
> config flag, and (c) resolve the reasoning effort for the model at hand via `get-grok <model>`.

> **Grok reads the Claude Code world.** `grok inspect` shows it loading `~/.claude/CLAUDE.md`
> and every installed claude-* plugin with its skills, and the `system`/`init` event repeats
> them: measured 2026-08-29 on grok 1.0.5, a one-line prompt billed 33,091 input tokens with
> `cache_read_input_tokens: 0`, and the event listed 69 skills — `claude-mesh:mesh-review`
> among them. The bill scales with the installed plugin set, so treat that number as this
> machine's, not a constant. What does not vary is the consequence: grok can SEE those skills.
> Callers that care — the review skill does — put an explicit "do not invoke skills" line in
> the prompt. There is no CLI flag to suppress this.

## Locating plugin files (Task 2.5)

Set `SKILL_BASE` from the `Base directory for this skill: <ABS>` line Claude Code prints at load **if present**. Do not rely on Grok printing that line. **`${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_DATA}` are NOT available inside Bash-tool calls** (verified empty on Claude Code 2.1.156).

At the top of EACH bash fence:
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the three plugin trees, installed-plugins first inside a Grok session. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || _LOADER="$(find "$HOME"/.grok/installed-plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || { echo "STOP: mesh-exec plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.grok/installed-plugins, $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/grok-exec"
fi

Do not rewrite the fence. The else-branch searches `$HOME/.grok/installed-plugins` first (only inside a Grok session: bash has `GROK_SESSION_ID` there and not on Claude Code, so a two-host machine's stale snapshot never reaches a Claude Code run) — an unpublished `grok plugin install <tree>` copy, the one `grok inspect` loads, which a stale Claude cache must not outrank (measured 2026-09-01: `sort -V` on the cache picked 0.12.0 and the wrappers ran the old loader) — then `$HOME/.claude/plugins`, then `$HOME/.grok/plugins`, each version-sorted, `| sort -V | tail -1`, and each tried only when the previous root finds nothing. The roots are tried in PRIORITY order, never in one find over all three: `sort -V` compares whole paths, and `.claude` < `.grok`, so a single find picked the `.grok` copy whatever its version. `.claude` is where a published copy lives on both hosts — Grok loads a marketplace mesh-exec from the Claude cache; only an unpublished tree sits under `installed-plugins`. It then sets `PLUGIN_ROOT` two directories up, and sets `SKILL_BASE=$PLUGIN_ROOT/skills/<this-skill>`. The else-branch repeats `resolve-plugin-root.sh`'s remaining order IDENTICALLY — `$CLAUDE_PLUGIN_ROOT`, `$GROK_PLUGIN_ROOT`, then the three plugin trees — because it cannot call the helper (that is the file it is locating). Keep the two in step: they are one contract in two copies. If nothing resolves it STOPs, rather than resolving a `PLUGIN_ROOT` from the current directory.

From `SKILL_BASE` / `PLUGIN_ROOT`:
- loader = `$SKILL_BASE/../shared/config-loader.sh`
- this skill's own scripts = `$SKILL_BASE/<x>`; sibling shared scripts = `$SKILL_BASE/../shared/<x>` (e.g. `watchdog.sh`, `extract-result.py`, `stream-json-report.sh`)
- data dir = `"$LOADER" data-dir` (`~/.local/state/mesh`, or `$XDG_STATE_HOME/mesh` when that is set); build run paths under `$PLUGIN_DATA/runs/grok/...`

## CRITICAL: Tool Execution Rules

### Bash Variables

**The Bash tool runs each call in an ISOLATED shell. Variables DO NOT persist between calls.**

BAD (will fail):
```bash
# Call 1
LOG_FILE="/path/to/file.log"
# Call 2
cat "$LOG_FILE"  # ERROR: $LOG_FILE is empty!
```

GOOD (use single call with &&):
```bash
LOG_FILE="/path/to/file.log" && cat "$LOG_FILE"
```

**Rule: Put ALL related commands in ONE Bash call using `&&` to chain them.**

### Write Tool Limitation

**Write tool requires reading a file first.** For NEW files this fails:
```
Write(/path/new-file.txt)
Error: File has not been read yet. Read it first before writing to it.
```

**Solution:** Use Bash heredoc for new files:
```bash
cat > "/path/new-file.txt" << 'EOF'
content here
EOF
```

## When to Use

- Running any task through Grok (code review, generation, analysis, etc.)
- Getting a "second opinion" from an xAI model
- Delegating complex tasks to an external agent

## Input

The caller must provide:
- **PROMPT** — the full prompt text to send to Grok

Optional:
- **TASK_NAME** — short name for log files (default: "task")
- **MODEL** — a grok model id (e.g. `grok-4.6`). **Do NOT choose one yourself.** When the
  caller names none, `-m` is omitted entirely and the CLI's own default applies
  (`~/.grok/config.toml`, `[models] default`). This skill hardcodes no model, unlike
  codex-exec and gemini-exec: grok ships a user-level default and overriding it silently
  would be wrong. The review path always passes a model, chosen from the `grok.models`
  catalog.
- **REASONING_EFFORT** — `low` | `medium` | `high` | `xhigh` | `max` (the set known today).
  When the caller passes none, the skill asks the loader for the level THIS MODEL should run at
  (`get-grok "$MODEL"`): `grok.model_efforts[<model>]` first, then the section-wide
  `grok.reasoning_effort`. When both are unset, `--effort` is omitted and the CLI's
  `default_reasoning_effort` applies. Unknown values are passed through — the CLI validates, and
  it validates PER MODEL, which is why the table exists: measured 2026-08-30 against grok 1.0.5,
  grok-4.6 accepts `xhigh` but not `max`, and grok-4.5 accepts neither.
- **SUPERVISED_MODE** — `none` (default) or `shell`. Under `shell` the run is wrapped by
  `shared/watchdog.sh` (`$SKILL_BASE/../shared/watchdog.sh`), which restarts the CLI when the
  stream stops growing for `HARD_ZERO_TIMEOUT` seconds (600) up to `MAX_RETRIES=2` times,
  under a `GLOBAL_TIMEOUT=3600` wall clock. Artifacts land in `$WORK_DIR/attempt-N/`, the
  winning attempt is exposed as `$WORK_DIR/final/`, and `raw.jsonl` / `raw.json` /
  `output.txt` / `report.md` / `stderr.txt` are produced at `$WORK_DIR/` root for callers that
  read the root paths.

### Reasoning Efforts

| Level | Description |
|-------|-------------|
| low | Fast responses with lighter reasoning |
| medium | Balances speed and reasoning depth |
| high | Greater reasoning depth for complex problems |
| xhigh | Extra high reasoning depth |
| max | Deepest reasoning |

Known as of 2026-08 against grok 1.0.5. This is **NOT an enum**: xAI ships levels with new
models, so a value outside this table is passed to `--effort` unchanged and the grok CLI is
the final validator. `config-loader.sh` warns on an unknown `grok.reasoning_effort` and passes
it through for the same reason — never turn either into a closed set.

## Pre-flight Checks

Run in ONE Bash call. The `grok` CLI is mandatory; the `has_grok` config gate is a soft check
(warn-only) because grok manages its own auth and works even when the optional `grok:` block is
absent from `config.yaml`.

```bash
# Task 2.5 (CC 2.1.156): ${CLAUDE_PLUGIN_ROOT}/${CLAUDE_PLUGIN_DATA} are EMPTY in
# Bash-tool calls from skills. Locate files via the absolute base dir Claude Code
# prints at skill load ("Base directory for this skill: <ABS>"). See "## Locating
# plugin files (Task 2.5)" above.
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the three plugin trees, installed-plugins first inside a Grok session. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || _LOADER="$(find "$HOME"/.grok/installed-plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || { echo "STOP: mesh-exec plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.grok/installed-plugins, $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/grok-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"

command -v grok >/dev/null 2>&1 || { echo "STOP: grok CLI not found — install Grok Build with 'curl -fsSL https://x.ai/cli/install.sh | bash', then run 'grok login'"; exit 1; }
echo "OK: grok found"
command -v jq >/dev/null 2>&1 || { echo "STOP: jq not found — required to parse the stream"; exit 1; }
echo "OK: jq found"
command -v python3 >/dev/null 2>&1 || { echo "STOP: python3 not found — required by shared/extract-result.py"; exit 1; }
echo "OK: python3 found"
# WARN, not STOP: shared/stream-json-report.sh computes the report's duration with `bc` and
# falls back to 0 without it. That costs one header field, never the review — so a missing bc
# must not stop a run the way a missing jq or python3 does.
command -v bc >/dev/null 2>&1 || echo "WARN: bc not found — the report's duration will read 0; the review itself is unaffected"

# Soft gate: warn (don't STOP) if the optional grok: block is unconfigured. grok handles its
# own auth, so an absent block is non-fatal for a direct call — it only means no catalog and
# no configured effort. But BRANCH ON THE rc, never on stdout alone: has_grok VALIDATES the
# section (unlike the bare has_codex / has_gemini probes), so a MALFORMED catalog exits 1 with
# an empty stdout, and a bare `!= "1"` then reports "not configured" for a section that is
# right there — the user hunts for something that is not missing while this run silently falls
# back to whatever ~/.grok/config.toml names as default, which need not even be a grok model.
# rc=2 is the separate "no config.yaml at all", which IS unconfigured, so it warns and continues:
# the WARN names the file the loader looked for and passes the loader's lines on — with the old
# claude-mesh config still in place they carry the command that moves it.
# The review path states the same rule at mesh-review/skills/grok-code-review/SKILL.md:102-108; it STOPs on
# every non-zero rc because a review cannot start without a model, while a direct call can.
if [ -x "$LOADER" ]; then
    GROK_ERR=$(mktemp) || { echo "STOP: mktemp failed"; exit 1; }
    FLAG_RC=0
    HAS_GROK=$("$LOADER" get-flag has_grok 2>"$GROK_ERR") || FLAG_RC=$?
    if [ "$FLAG_RC" -eq 1 ]; then
        echo "STOP: the grok: section in config.yaml does not validate — config.yaml is user-owned; agents never edit it. The loader says:"
        cat "$GROK_ERR"; rm -f "$GROK_ERR"; exit 1
    fi
    if [ "$FLAG_RC" -eq 2 ]; then
        echo "WARN: no config.yaml at $("$LOADER" config-path) — continuing on defaults. It is user-owned; agents never create or edit it. The loader says:"
        cat "$GROK_ERR"
    else
        [ "$HAS_GROK" = "1" ] || echo "WARN: grok: block not configured in config.yaml (grok uses its own auth — continuing)"
    fi
    rm -f "$GROK_ERR"
fi
```

If the grok CLI check fails, STOP and report the error to the user verbatim. Do NOT edit
config.yaml (or any plugin config) yourself — only the user changes it.

## Process

### Step 1: Save Prompt to File

**IMPORTANT:** The Write tool requires reading a file first. For NEW files, use Bash with heredoc instead.

Replace before execution:
- `{TASK_NAME}` → the caller's task name, or `task`
- `{MODEL}` → the caller's grok model id, or leave EMPTY. Note this differs from codex-exec and
  gemini-exec, which substitute the model in Step 2: here Step 1 validates it, builds the run
  path from it and persists it to `.model`, and Step 2 reads that file. Leaving the placeholder
  literal is safe — it fails the charset check and STOPs — but it is not a substitute for
  reading this line.
- `{PROMPT_TEXT_HERE}` → the full prompt text

Create the run directory and prompt file using Bash:
```bash
set -euo pipefail
# PID suffix prevents collision when the same TASK_NAME lands within the same second.
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)-$$
RAW_TASK_NAME=$(cat <<'__TASK_NAME_BOUNDARY_9f21c6b4_TASK_NAME_END__'
{TASK_NAME}
__TASK_NAME_BOUNDARY_9f21c6b4_TASK_NAME_END__
)
TASK_NAME=$(printf '%s' "$RAW_TASK_NAME" | tr -cd '[:alnum:]._-' | head -c 64)
[ -z "$TASK_NAME" ] && TASK_NAME="task"
RAW_MODEL=$(cat <<'__MODEL_BOUNDARY_9f21c6b4_MODEL_END__'
{MODEL}
__MODEL_BOUNDARY_9f21c6b4_MODEL_END__
)
# REJECT, never rewrite. `tr -cd` is NOT "the same allow-list the config validator enforces":
# GROK_IDENT_RE anchors the first character, tr does not. `..` survives the filter intact and
# sends WORK_DIR to runs/grok/../<ts>-task — outside the tree verify-delegation.sh searches,
# so a run that genuinely happened scores FLIP; `-p` survives too. And a 70-char id that the
# config accepts is silently truncated to 64, after which the directory carries one string
# while `-m` below is handed another, leaving guard and watcher hunting a path that does not
# exist. Silent rewriting is the wrong tool for a value that is simultaneously a path
# component and a CLI argument: one string, or a hard stop.
[[ "$RAW_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [ -z "$RAW_MODEL" ] || {
    echo "STOP: MODEL must match [A-Za-z0-9][A-Za-z0-9._-]* (got '$RAW_MODEL')" >&2; exit 1; }
MODEL="$RAW_MODEL"
# Persist it so Step 2 reads the SAME string instead of re-expanding {MODEL} from the template
# unfiltered — that second, unchecked read is what let the path and the -m argument diverge.
# Mirrors the existing .task_name file.
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the three plugin trees, installed-plugins first inside a Grok session. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || _LOADER="$(find "$HOME"/.grok/installed-plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || { echo "STOP: mesh-exec plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.grok/installed-plugins, $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/grok-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"
PLUGIN_DATA="$("$LOADER" data-dir)"
# ONE shape, always: runs/grok/<model>/<ts>-<task>, with a model-less call landing under the
# fixed namespace _default rather than one level up. Two shapes would need the invariant "a
# model dir is never read as a run" — true, since run names match ^[0-9]{4}(-[0-9]{2}){5}-,
# but it leans on nobody naming a model 2026-08-28-20-45-02, which GROK_IDENT_RE would accept.
# _default is unreachable as a model name: the charset is anchored at [A-Za-z0-9] and the
# Global Constraints forbid widening it. Keep them in step — if the charset ever changes, this
# namespace must move too.
WORK_DIR="$PLUGIN_DATA/runs/grok/${MODEL:-_default}/${TIMESTAMP}-${TASK_NAME}"
mkdir -p "$WORK_DIR"
echo "$TASK_NAME" > "$WORK_DIR/.task_name"
# The validated model, so Step 2 uses the SAME string the path was built from.
printf '%s\n' "$MODEL" > "$WORK_DIR/.model"
# Stamp the dispatching session so watch-runs.sh and verify-delegation.sh can tell this run
# from one a concurrent orchestration started under the same engine/model in the same data dir.
printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}" > "$WORK_DIR/.session_id"
cat > "$WORK_DIR/prompt.md" << '__PROMPT_BOUNDARY_9f21c6b4_PROMPT_END__'
{PROMPT_TEXT_HERE}
__PROMPT_BOUNDARY_9f21c6b4_PROMPT_END__
echo "WORK_DIR=$WORK_DIR"
```

**Important:** Keep this as a SINGLE Bash call, but do not continue the heredoc with `&&`. The heredoc must terminate before the next shell command is parsed.

**Note:** The quoted delimiters prevent shell expansion AND minimise collision risk with prompt content. If the prompt happens to contain a literal delimiter on its own line, regenerate it (and update both the opening and closing lines).

**Save the WORK_DIR path** for use in Step 2.

### Step 2: Execute Grok (SINGLE Bash call)

**IMPORTANT:** Execute the ENTIRE block in ONE Bash call. Substitute actual values for parameters.

Replace before execution:
- `{WORK_DIR}` → path from Step 1
- `{REASONING_EFFORT}` → leave EMPTY unless the caller explicitly supplied a level. The block
  then resolves the level for its OWN model from config — `grok.model_efforts[<model>]`, then
  `grok.reasoning_effort` — and omits `--effort` when both are unset.

`{MODEL}` is **not** substituted again here: Step 1 validated it and wrote it to
`$WORK_DIR/.model`, and this block reads that file.

**Branch on `SUPERVISED_MODE`:**
- If `SUPERVISED_MODE` is unset or `none` → use **Default execution** below.
- If `SUPERVISED_MODE=shell` → use **Supervised execution**.

#### Default execution (SUPERVISED_MODE=none)

```bash
# === EXECUTE THIS ENTIRE BLOCK AS ONE BASH CALL ===
set -euo pipefail
WORK_DIR="{WORK_DIR}"
# Read the model Step 1 validated and persisted. Do NOT re-expand {MODEL} here: that second,
# unchecked read is exactly how the directory name and the -m argument came apart.
MODEL=$(cat "$WORK_DIR/.model" 2>/dev/null || true)
EFFORT=$(cat <<'__EFFORT_BOUNDARY_9f21c6b4_EFFORT_END__'
{REASONING_EFFORT}
__EFFORT_BOUNDARY_9f21c6b4_EFFORT_END__
)
# Same reason {MODEL} is checked and not rewritten: catch a bad value BEFORE it becomes an
# argument. NOT an enum — the design forbids one, so that a new xAI level passes without a
# plugin release — only the charset a level name can have. The case this actually catches is an
# UNSUBSTITUTED `{REASONING_EFFORT}`, which would otherwise reach the CLI and lose the run to a
# 4.7-second argument refusal. The heredoc already makes injection impossible; this is about a
# wasted run, not about safety.
if [ -n "$EFFORT" ] && ! printf '%s' "$EFFORT" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    echo "STOP: REASONING_EFFORT '$EFFORT' is not a level name (expected [A-Za-z0-9][A-Za-z0-9._-]*, e.g. xhigh) — an unsubstituted {REASONING_EFFORT} looks exactly like this"; exit 1
fi
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the three plugin trees, installed-plugins first inside a Grok session. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || _LOADER="$(find "$HOME"/.grok/installed-plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || { echo "STOP: mesh-exec plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.grok/installed-plugins, $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/grok-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR")
PROMPT_FILE="$WORK_DIR/prompt.md"
RAW_FILE="$WORK_DIR/raw.jsonl"
# Resolve the effort from config when the caller left it empty — for THIS model, not for the
# section: the CLI validates --effort per model and the accepted sets differ, so "$MODEL" has to
# reach the loader. It is legitimately empty on a call that names no model, and that is the
# whole-section question get-grok has always answered. Gated on has_grok; a get-grok rc!=0 means
# a broken grok: section — STOP and surface it. config.yaml is user-owned: never edit it.
if [ -z "$EFFORT" ] && [ -x "$LOADER" ]; then
    # The flag is read rc-AWARE, not inside the `if` condition under 2>/dev/null. Read that
    # way, a grok: section that does not validate made the whole condition false and the run
    # continued with NO --effort — the CLI's own default, which on this machine belongs to a
    # model this plugin never chose. The soft pre-flight above STOPs on exactly that rc, and
    # these are separate Bash calls, so the config can break between them. rc=2 ("no
    # config.yaml at all") stays unconfigured and quiet, exactly as it does up there.
    FLAG_ERR=$(mktemp) || { echo "STOP: mktemp failed"; exit 1; }
    FLAG_RC=0
    HAS_GROK_FLAG=$("$LOADER" get-flag has_grok 2>"$FLAG_ERR") || FLAG_RC=$?
    if [ "$FLAG_RC" -eq 1 ]; then
        echo "STOP: the grok: section in config.yaml does not validate — config.yaml is user-owned; agents never edit it. The loader says:"
        cat "$FLAG_ERR"; rm -f "$FLAG_ERR"; exit 1
    fi
    rm -f "$FLAG_ERR"
    if [ "$HAS_GROK_FLAG" = "1" ]; then
        EFFORT=$("$LOADER" get-grok "$MODEL") || { echo "STOP: config-loader get-grok failed — fix config.yaml (user-owned, agents never edit it)"; exit 1; }
    fi
fi
# NO fallback model and NO fallback effort: an unset value means "let ~/.grok/config.toml
# decide", which is the whole reason this skill differs from codex-exec and gemini-exec.
# if/then, not `test && cmd`: the second form is the SC2015 shape this codebase avoids, and
# under `set -e` its failing test is only saved by an exception in the manual.
GROK_ARGS=()
if [ -n "$MODEL" ];  then GROK_ARGS+=(-m "$MODEL"); fi
if [ -n "$EFFORT" ]; then GROK_ARGS+=(--effort "$EFFORT"); fi
echo "=== Grok Exec ==="
echo "Work dir: $WORK_DIR"
echo "Model: ${MODEL:-<CLI default>} | Effort: ${EFFORT:-<CLI default>}"
echo ""

# raw.jsonl is written UNPREFIXED — extract-result.py parses it line by line as JSON, so a
# timestamp prefix (which codex-exec and gemini-exec add to their log.jsonl) would break it.
# No stdbuf, unlike the three sibling skills: the grok binary is statically linked
# (`file -L "$(command -v grok)"` reports "static-pie linked"), and stdbuf works by preloading
# libstdbuf through a dynamic loader that is not there — it would be a silent no-op. It is not
# needed either, and that holds for BOTH shapes this skill uses — which is worth spelling out,
# because the block right below sends stdout into a PIPE while supervised mode redirects it to a
# file, and a claim measured on only one of them would not cover the other. Measured on grok
# 1.0.5: to a redirected file, the stream grows while the run is live; through a pipe into
# `while read`, a five-event agentic run delivered its events at 3.44s, 5.89s, 7.35s, 7.70s and
# 7.71s against a process that exited at 8.13s — spread across the run, not delivered in one
# burst at exit, which is what block buffering would look like. Reproduce with:
#   grok --prompt-file <(echo 'List the files here, then reply DONE.') \
#        --output-format streaming-messages-json --permission-mode bypassPermissions --no-plan \
#        -m <model> | while IFS= read -r l; do date +%s.%N; done
# Keep this comment; without it the next reader "restores parity" with codex/gemini and
# reintroduces stdbuf, or "fixes" a pipe-buffering problem this binary does not have.
# ${GROK_ARGS[@]+"${GROK_ARGS[@]}"}, not "${GROK_ARGS[@]}": under `set -u` bash 4.2 treats the
# plain form on an EMPTY array as an unbound variable and aborts, and this project supports
# bash 4.2. Do not "simplify" it back.
# `timeout 1800` here is the same per-attempt backstop the supervised branch uses, and in THIS
# branch it is mostly aspirational: run this fence in a FOREGROUND Bash call and the harness
# SIGTERMs it at `BASH_MAX_TIMEOUT_MS` (ten minutes out of the box) long before 1800 s — the
# KILLED shape the supervised section below documents with measurements. Nothing is wrong with
# the number; what is wrong is expecting it to bind. For a direct call you expect to run past
# ten minutes, launch this fence in the BACKGROUND, or use SUPERVISED_MODE, which is built for
# exactly that. The shape is inherited from codex-exec and gemini-exec, which carry it too.
PIPELINE_RC=0
{ timeout 1800 grok \
    --prompt-file "$PROMPT_FILE" \
    --output-format streaming-messages-json \
    --permission-mode bypassPermissions \
    --no-plan \
    ${GROK_ARGS[@]+"${GROK_ARGS[@]}"} 2>"$WORK_DIR/stderr.txt" | while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$RAW_FILE"
    TYPE=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)
    case "$TYPE" in
        system) echo ":: Session started" ;;
        assistant)
            # `[ -n "$X" ] && echo` is the SC2015 shape this project avoids: as the LAST
            # command of a loop body it makes the whole loop exit 1 whenever the string is
            # empty — i.e. on a perfectly healthy run whose final message called no tool.
            TOOLS=$(printf '%s' "$line" | jq -r '[.message.content[]? | select(.type=="tool_use") | .name] | join(", ")' 2>/dev/null)
            if [ -n "$TOOLS" ]; then echo ":: Tools: $TOOLS"; fi
            ;;
        result) echo ":: Completed" ;;
    esac
done ; } || PIPELINE_RC=$?

# Extraction and report generation run UNCONDITIONALLY, so a crash still leaves whatever the
# stream carried — including a {"type":"error"} event, which extract-result.py surfaces as
# "API Error: <msg>" in output.txt. grok emits that message TOP-LEVEL while the three older
# engines nest it under .error.message; the extractor reads both (nested first), which is what
# stops an unknown-model run — the CLI prints the error on stdout AND stderr and exits 1 —
# from rendering as the literal "API Error: {}".
# Tolerant call, never a link in an && chain: rc=3 means "raw.jsonl exists but nothing parses",
# which is exactly the shape "xAI changed the wire format" takes, and aborting there destroys
# the evidence for it.
python3 "$SKILL_BASE/../shared/extract-result.py" "$WORK_DIR" || { echo "WARN: extract-result.py rc=$?" >&2; }

# The report's Profile column: the caller's model, else the model the stream itself announced,
# else the engine name. Never empty.
PROFILE="$MODEL"
if [ -z "$PROFILE" ] && [ -s "$RAW_FILE" ]; then
    PROFILE=$(jq -Rr 'fromjson? | objects | select(.type=="system") | .model // empty' "$RAW_FILE" 2>/dev/null | head -1)
fi
if [ -z "$PROFILE" ]; then PROFILE="grok"; fi
echo ""
echo "=== Generating report ==="
# if/then, not `[ -s … ] && cmd || echo`: that is the SC2015 shape this file argues against
# twice elsewhere, and here it also merged two different outcomes into one WARN — "there was
# no stream" and "the renderer failed" want different sentences. Neither branch can exit
# non-zero, so the `|| true` the old form needed is gone with it.
if [ -s "$RAW_FILE" ]; then
  "$SKILL_BASE/../shared/stream-json-report.sh" "$RAW_FILE" "$WORK_DIR/report.md" "$PROFILE" "Grok Execution Report" "$TASK_NAME" \
    || echo "WARN: report generation failed — report.md may be missing" >&2
else
  echo "WARN: raw.jsonl is empty — no report generated" >&2
fi

# The stream is the evidence. A run with events but no terminal result event is a torn stream;
# a run with no output at all is a failed launch. Both must be loud rather than empty.
# jq, not grep: the substring "type":"result" also occurs inside tool_result payloads and any
# assistant text quoting it, so grep answers "there was a terminal event" for a stream that has
# none. This is the check design §2 offers against a wire-format change — it must not be
# satisfiable by prose.
# `| "1"` is load-bearing: it projects the match to a CONSTANT. Emitting the whole result event
# instead makes jq write the entire final answer while `grep -q` exits on the first line; past
# the pipe buffer jq then dies of SIGPIPE, `pipefail` makes 141 the pipeline's status, the
# leading `!` inverts it and this WARN fires on a perfectly healthy run. Measured on this file
# 2026-08-29: unprojected, rc=141 for every answer >=16 KB (10/10 runs at 16 KB, 20 KB and
# 200 KB) and rc=0 at 5 KB; projected, rc=0 at all four sizes. Review answers routinely clear
# 16 KB, so the unprojected form would cry wolf on most real runs and train the reader to
# ignore the one signal that catches a wire-format change. verify-delegation.sh:430 shares the
# `fromjson? | objects | select(...)` prefix but is NOT exposed to this: it pipes into `tail -1`,
# which drains jq's output, and projects `.is_error` — a few bytes either way.
if [ -s "$RAW_FILE" ] && ! jq -Rr 'fromjson? | objects | select(.type=="result") | "1"' "$RAW_FILE" \
     2>/dev/null | grep -q .; then
  echo "WARN: no terminal result event in raw.jsonl — the run was cut off, or the CLI changed its wire format" >&2
fi
# if/then inside, not `test && { ... }`: the guard must reach `exit 4`, and an AND-list whose
# test fails is a poor way to get there.
if [ ! -s "$WORK_DIR/output.txt" ]; then
  echo "ERROR: output.txt is empty (grok pipeline rc=$PIPELINE_RC)" >&2
  if [ -s "$WORK_DIR/stderr.txt" ]; then echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; fi
  if [ -s "$RAW_FILE" ]; then echo "--- raw.jsonl tail ---" >&2; tail -5 "$RAW_FILE" >&2; fi
  exit 4
fi
if [ "$PIPELINE_RC" -ne 0 ]; then
  echo "WARN: grok pipeline exited rc=$PIPELINE_RC" >&2
  if [ -s "$WORK_DIR/stderr.txt" ]; then echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; fi
  # Print the output before leaving. It is non-empty (the check above already returned on empty),
  # and on the run this branch exists for — a top-level `error` event, the shape a typo in `-m`
  # produces — output.txt holds the extracted `API Error: Couldn't set model to <id>`, the one
  # line that says WHY. Exiting before `=== OUTPUT ===` handed the caller a bare rc and left the
  # reason in the run dir. The supervised branch has no such gap: it always reaches its own
  # OUTPUT section.
  echo "=== OUTPUT ==="
  cat "$WORK_DIR/output.txt"
  exit "$PIPELINE_RC"
fi

echo ""
echo "=== FILES ==="
ls -la "$WORK_DIR"
echo ""
echo "=== OUTPUT ==="
cat "$WORK_DIR/output.txt"
```

>
> **`report.md` is the whole run rendered — decide from `output.txt`.** Not because the
> rendering is lossy: `shared/stream-json-report.sh` used to read `.message.content[0]` and
> nothing else, so a message mixing blocks lost everything after the first and a message
> STARTING with `thinking` — the ordinary shape for a reasoning model, which grok is — matched
> no branch and was dropped whole, tool call included. Measured on this skill's own acceptance
> run: 22 of 23 assistant messages began with `thinking`, and the 904 KB report contained none
> of the run's 79 tool calls, only their outputs — consequences with no causes. The renderer now
> iterates every block and is pinned by `shared/tests/test-stream-json-report.sh`. What remains
> true is the SIZE: `report.md` is ~930 KB against `output.txt`'s 10 KB on that same run. Nothing
> in this plugin decides anything from it either way: every verdict is made from `output.txt`,
> which `shared/extract-result.py` builds independently from `raw.jsonl`, and `raw.jsonl` itself
> is kept whole.

#### Supervised execution (SUPERVISED_MODE=shell)

Execute as ONE **background** Bash call — `run_in_background: true`, never a foreground one.

**Why it must be background.** The harness caps a foreground call at `BASH_MAX_TIMEOUT_MS` (ten
minutes out of the box; the effective ceiling is the larger of that and
`BASH_DEFAULT_TIMEOUT_MS`) and SIGTERMs it at the cap, taking the whole process group with it.
`watchdog.sh`'s `trap 'cleanup 143' TERM` then records `exit_code: 143` and the run is lost with
no `watchdog.exit` to explain it — the shape `verify-delegation.sh` reports as `KILLED`. Every
budget below sits ABOVE that cap (`timeout 1800` per attempt, `GLOBAL_TIMEOUT=3600` across
retries), so on a foreground launch neither the restarts nor the wall-clock deadline is
reachable. Measured 2026-08-05 on CC 2.1.222 across the sibling ext-claude path: 5 of 5
foreground runs died at 600-605s with their streams still growing, each tool result reading
`Exit code 143 / Command timed out after 10m 0s`; every background launch outlived the cap
(812s, 1397s, 2001s, 2028s).

Backgrounding costs nothing, because everything the caller needs happens INSIDE this block:
watchdog, copy-up, extraction, report generation and the bail diagnostics. Report the work dir,
end the turn, and read `$WORK_DIR/output.txt` / `report.md` — and the launch's stdout file for
an `rc=2` bail — once you are woken. Do NOT wrap the launch in a foreground wait or poll loop:
such a call carries the same cap. If the run dies, report the death rather than relaunching it.

**That is the Claude Code shape.** On Grok Build — no Skill tool, no SendMessage, nothing that
wakes an idle wrapper — do NOT end the turn while the CLI is alive: keep the launch in the
background and wait on its command id with `get_command_or_subagent_output` (loop; each call's
ceiling is 600 s) until it exits, then read `$WORK_DIR/output.txt` and report, exactly as the
agent definition says. Ending the turn there leaves the review on disk with nobody to collect it.

Key points:
- `command -v jq` precondition fails fast with a clear message if `jq` is missing.
- There is **no `STDIN_FILE`**: the prompt reaches grok through `--prompt-file`, and
  `watchdog.sh` treats `STDIN_FILE` as optional (`watchdog.sh:58`), feeding `/dev/null` when
  it is unset.
- `timeout 1800` stays the immediate child of the watchdog so it can SIGKILL `grok` even if the
  watchdog itself is wedged. No `stdbuf` — see the comment in the block.
- The watchdog exit code is captured with `|| WATCHDOG_RC=$?` so the diagnostics branch runs
  when it returns 2 or 3.
- On success the winning attempt's `raw.jsonl` and `stderr.txt` are copied to `$WORK_DIR/`
  root, and extraction then writes `raw.json` + `output.txt` there directly — the same set of
  root paths the default branch produces.
- The `report.md` limitation noted under the default branch applies here unchanged.

```bash
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "supervised mode requires jq" >&2; exit 64; }
WORK_DIR="{WORK_DIR}"
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the three plugin trees, installed-plugins first inside a Grok session. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || _LOADER="$(find "$HOME"/.grok/installed-plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || { echo "STOP: mesh-exec plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.grok/installed-plugins, $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/grok-exec"
fi
WATCHDOG="$SKILL_BASE/../shared/watchdog.sh"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
# The model Step 1 validated and persisted — never a fresh {MODEL} expansion.
MODEL=$(cat "$WORK_DIR/.model" 2>/dev/null || true)
EFFORT=$(cat <<'__EFFORT_BOUNDARY_9f21c6b4_EFFORT_END__'
{REASONING_EFFORT}
__EFFORT_BOUNDARY_9f21c6b4_EFFORT_END__
)
# Same reason {MODEL} is checked and not rewritten: catch a bad value BEFORE it becomes an
# argument. NOT an enum — the design forbids one, so that a new xAI level passes without a
# plugin release — only the charset a level name can have. The case this actually catches is an
# UNSUBSTITUTED `{REASONING_EFFORT}`, which would otherwise reach the CLI and lose the run to a
# 4.7-second argument refusal. The heredoc already makes injection impossible; this is about a
# wasted run, not about safety.
if [ -n "$EFFORT" ] && ! printf '%s' "$EFFORT" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    echo "STOP: REASONING_EFFORT '$EFFORT' is not a level name (expected [A-Za-z0-9][A-Za-z0-9._-]*, e.g. xhigh) — an unsubstituted {REASONING_EFFORT} looks exactly like this"; exit 1
fi
if [ -z "$EFFORT" ] && [ -x "$LOADER" ]; then
    # The flag is read rc-AWARE, not inside the `if` condition under 2>/dev/null. Read that
    # way, a grok: section that does not validate made the whole condition false and the run
    # continued with NO --effort — the CLI's own default, which on this machine belongs to a
    # model this plugin never chose. The soft pre-flight above STOPs on exactly that rc, and
    # these are separate Bash calls, so the config can break between them. rc=2 ("no
    # config.yaml at all") stays unconfigured and quiet, exactly as it does up there.
    FLAG_ERR=$(mktemp) || { echo "STOP: mktemp failed"; exit 1; }
    FLAG_RC=0
    HAS_GROK_FLAG=$("$LOADER" get-flag has_grok 2>"$FLAG_ERR") || FLAG_RC=$?
    if [ "$FLAG_RC" -eq 1 ]; then
        echo "STOP: the grok: section in config.yaml does not validate — config.yaml is user-owned; agents never edit it. The loader says:"
        cat "$FLAG_ERR"; rm -f "$FLAG_ERR"; exit 1
    fi
    rm -f "$FLAG_ERR"
    if [ "$HAS_GROK_FLAG" = "1" ]; then
        EFFORT=$("$LOADER" get-grok "$MODEL") || { echo "STOP: config-loader get-grok failed — fix config.yaml (user-owned, agents never edit it)"; exit 1; }
    fi
fi
# NO fallback model and NO fallback effort — an unset value means "let ~/.grok/config.toml
# decide". Same contract as the default branch above.
GROK_ARGS=()
if [ -n "$MODEL" ];  then GROK_ARGS+=(-m "$MODEL"); fi
if [ -n "$EFFORT" ]; then GROK_ARGS+=(--effort "$EFFORT"); fi
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR")
PROMPT_FILE="$WORK_DIR/prompt.md"
echo "=== Grok Exec (supervised: shell watchdog) ==="
echo "Work dir: $WORK_DIR"
echo "Model: ${MODEL:-<CLI default>} | Effort: ${EFFORT:-<CLI default>}"
echo ""

# No stdbuf: the grok binary is statically linked (`file -L "$(command -v grok)"` reports
# "static-pie linked"), and stdbuf works by preloading libstdbuf through a dynamic loader that
# is not there — it would be a silent no-op. It is not needed either: the stream was measured
# reaching a redirected file unbuffered. Keep this comment; without it the next reader
# "restores parity" with codex/gemini and reintroduces it. The comment lives HERE, above the
# statement, and not inside the invocation: a `#` comment on a backslash-continued line ends
# the continuation, which would hand the watchdog a `--` with no command after it.
# ${GROK_ARGS[@]+"${GROK_ARGS[@]}"}: see the default branch — the plain form aborts under
# `set -u` on bash 4.2 when the array is empty.
WATCHDOG_RC=0
{ WORK_DIR="$WORK_DIR" \
    MAX_RETRIES=2 \
    HARD_ZERO_TIMEOUT=600 \
    GLOBAL_TIMEOUT=3600 \
    STREAM_FILE_NAME=raw.jsonl \
    "$WATCHDOG" -- \
      timeout 1800 grok \
        --prompt-file "$PROMPT_FILE" \
        --output-format streaming-messages-json \
        --permission-mode bypassPermissions \
        --no-plan \
        ${GROK_ARGS[@]+"${GROK_ARGS[@]}"} \
  || WATCHDOG_RC=$?; }

# Watchdog writes each attempt's artefacts under $WORK_DIR/attempt-N/ and makes $WORK_DIR/final
# a SYMLINK to the winning attempt. Branch on WATCHDOG_RC:
#   rc=0 → copy the winning attempt up, extract, report, stream + empty-output checks
#   rc=2 → watchdog bailed (retries exhausted / global timeout): surface watchdog.exit plus the
#          per-attempt tails, then exit 2. The exit-4 path must NOT run here — on a bail `final`
#          points at a partial attempt with an empty output.txt, so exit 4 would fire first and
#          mask the bail, losing the diagnostics.
#   else → watchdog internal error: propagate rc.
echo ""
echo "=== WATCHDOG RESULT (rc=$WATCHDOG_RC) ==="
if [ "$WATCHDOG_RC" = "0" ]; then
  # Copy the winning attempt's files up so the rest of the pipeline behaves like the default
  # branch. if/then inside the loop, not `[ -f x ] && cp`: as the last command of a loop body a
  # failing test makes the whole loop return 1.
  if [ -d "$WORK_DIR/final" ]; then
    for f in raw.jsonl stderr.txt; do
      if [ -f "$WORK_DIR/final/$f" ]; then cp -f "$WORK_DIR/final/$f" "$WORK_DIR/$f"; fi
    done
  fi

  # Extract into $WORK_DIR, not $FINAL: this writes raw.json AND output.txt at the run root
  # directly, which is where design §2 and this skill's Input section say they live. Tolerant
  # call — rc=3 ("raw.jsonl exists but nothing parses") is the shape a wire-format change
  # takes, and aborting the block there would destroy the report and diagnostics that prove it.
  python3 "$SKILL_BASE/../shared/extract-result.py" "$WORK_DIR" \
    || { echo "WARN: extract-result.py rc=$?" >&2; }

  PROFILE="$MODEL"
  if [ -z "$PROFILE" ] && [ -s "$WORK_DIR/raw.jsonl" ]; then
      PROFILE=$(jq -Rr 'fromjson? | objects | select(.type=="system") | .model // empty' "$WORK_DIR/raw.jsonl" 2>/dev/null | head -1)
  fi
  if [ -z "$PROFILE" ]; then PROFILE="grok"; fi
  echo ""
  echo "=== Generating report ==="
  { "$SKILL_BASE/../shared/stream-json-report.sh" "$WORK_DIR/raw.jsonl" "$WORK_DIR/report.md" "$PROFILE" "Grok Execution Report" "$TASK_NAME" \
      || echo "WARN: report generation skipped or failed — report.md may be missing" >&2 ; } || true

  # The SAME terminal-event check the default branch runs, on the path every review takes —
  # review always uses SUPERVISED_MODE=shell, so a check that lived only in the default branch
  # would never execute in production. jq, not grep: the substring "type":"result" also occurs
  # inside tool_result payloads and in assistant text quoting it. (The rc=2 branch below shows
  # the same evidence a different way, through the per-attempt tails.)
  # `| "1"` projects the match to a constant — see the default branch for why omitting it makes
  # this WARN fire on every healthy answer over ~16 KB. This is the branch every review takes,
  # so it is the branch where that false alarm would actually be seen.
  if [ -s "$WORK_DIR/raw.jsonl" ] && ! jq -Rr 'fromjson? | objects | select(.type=="result") | "1"' "$WORK_DIR/raw.jsonl" \
       2>/dev/null | grep -q .; then
    echo "WARN: no terminal result event in raw.jsonl — the run was cut off, or the CLI changed its wire format" >&2
  fi

  # Empty output is a recoverable signal — fail loudly rather than leaving a silent zero-byte
  # file for the caller to treat as an answer. Safe to run unconditionally HERE because this
  # is already inside the rc=0 branch: on an rc=2 bail `final` points at a partial attempt with
  # an empty output.txt, and an exit 4 there would mask the bail and lose its diagnostics.
  if [ ! -s "$WORK_DIR/output.txt" ]; then
    if [ -s "$WORK_DIR/raw.jsonl" ]; then
      echo "ERROR: output.txt empty but raw.jsonl has data" >&2
      if [ -s "$WORK_DIR/stderr.txt" ]; then echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; fi
      echo "--- raw.jsonl tail ---" >&2; tail -5 "$WORK_DIR/raw.jsonl" >&2
    else
      # Watchdog called it a success with nothing on the stream at all. It should be
      # unreachable — watchdog truncates the stream file at attempt start and only reports rc=0
      # when the command exited 0 — but silence is the one outcome a review orchestrator must
      # never receive, so this exits 4 like the default branch instead of printing an empty
      # OUTPUT section under a green exit code.
      echo "ERROR: output.txt AND raw.jsonl are both empty despite watchdog rc=0" >&2
      if [ -s "$WORK_DIR/stderr.txt" ]; then echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; fi
    fi
    exit 4
  fi

  echo "=== FILES ==="
  ls -la "$WORK_DIR"
  echo "=== OUTPUT ==="
  cat "$WORK_DIR/output.txt"
elif [ "$WATCHDOG_RC" = "2" ]; then
  echo "## Review Diagnostics"
  if [ -f "$WORK_DIR/watchdog.exit" ]; then
    jq -r '"- Attempts: \(.attempts)\n- Reason: \(.reason)\n- Elapsed: \(.elapsed_sec)s\n- Last attempt: \(.last_attempt_dir)"' \
      "$WORK_DIR/watchdog.exit" 2>/dev/null || cat "$WORK_DIR/watchdog.exit"
  fi
  echo ""
  echo "=== PER-ATTEMPT TAILS ==="
  for a in "$WORK_DIR"/attempt-*; do
    if [ ! -d "$a" ]; then continue; fi
    echo "-- $a --"; tail -20 "$a/raw.jsonl" 2>/dev/null || true
    if [ -s "$a/stderr.txt" ]; then echo "-- $a/stderr --"; tail -20 "$a/stderr.txt" || true; fi
    echo ""
  done
  exit 2
else
  echo "Watchdog internal error (exit $WATCHDOG_RC)" >&2
  exit "$WATCHDOG_RC"
fi
```

### Step 3: Handle Errors

If Grok times out or fails, check partial results:
```bash
set -uo pipefail
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the three plugin trees, installed-plugins first inside a Grok session. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || _LOADER="$(find "$HOME"/.grok/installed-plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || { echo "STOP: mesh-exec plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.grok/installed-plugins, $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/grok-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"
RUNS_DIR="$("$LOADER" data-dir)/runs/grok"
# The work dir this skill returned, when the caller still has it — an exact answer beats any
# search. Leave it empty only when it is genuinely lost; the search below is the fallback.
# Bound through a quoted heredoc, the shape grok-code-review uses for MODEL and BASE_BRANCH
# and for the reason measured there: a double-quoted assignment is a substitution point into an
# EXECUTED context. The value here is generated from sanitized components, so this is defence in
# depth rather than a repair — but this is the fence a reader runs when something has already
# gone wrong, which is the worst moment to be the one place that kept the weaker shape.
WORK_DIR_HINT=$(cat <<'__HINT_BOUNDARY_3d5a91e7_HINT_END__'
<the WORK_DIR this skill returned, or leave empty to search>
__HINT_BOUNDARY_3d5a91e7_HINT_END__
)
# And when it IS lost, the search must not cross into another session's run. `ls -t | head -1`
# did: it answered "the newest directory under runs/grok" across every model and every session,
# which is a different question from "the run I am looking for". Two runs of one model a minute
# apart is the ordinary shape of a review that retried, and on 2026-08-30 reading the older of
# two produced the report "this reviewer is dead" about a reviewer that was writing its review
# at that moment. verify-delegation.sh already answers the same question by `.session_id`;
# these blocks are the last thing anyone reads when a run went wrong, so they had better agree.
#
# Same semantics as the guard, including the exception: a run carrying NO stamp stays eligible.
# Those come from plugin versions that predate the stamp, and calling a live one somebody
# else's would be worse than the collision the filter removes. An empty SELF likewise accepts
# everything rather than nothing.
#
# TWO glob segments: runs/grok/<model>/<ts>-<task>/. `"$RUNS_DIR"/*/` alone would list the
# MODEL directories (or `_default`), not the runs inside them.
SELF_SID="${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}"
LATEST_DIR=""
if [ -n "$WORK_DIR_HINT" ] && [ -d "$WORK_DIR_HINT" ]; then
    LATEST_DIR="$WORK_DIR_HINT"
else
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        run_sid=""
        [ -r "$d/.session_id" ] && IFS= read -r run_sid < "$d/.session_id"
        if [ -z "$SELF_SID" ] || [ -z "$run_sid" ] || [ "$run_sid" = "$SELF_SID" ]; then
            LATEST_DIR="$d"; break
        fi
    done < <(ls -td "$RUNS_DIR"/*/*/ 2>/dev/null)
fi
if [ -z "$LATEST_DIR" ]; then echo "No grok runs under $RUNS_DIR for this session"; exit 0; fi
echo "Latest: $LATEST_DIR"
ls -la "$LATEST_DIR"
if [ -f "$LATEST_DIR/raw.jsonl" ]; then echo "=== Last 30 events (raw.jsonl) ==="; tail -30 "$LATEST_DIR/raw.jsonl"; fi
if [ -f "$LATEST_DIR/stderr.txt" ]; then echo "=== STDERR ==="; cat "$LATEST_DIR/stderr.txt"; fi
if [ -f "$LATEST_DIR/watchdog.exit" ]; then echo "=== WATCHDOG EXIT ==="; cat "$LATEST_DIR/watchdog.exit"; fi
```

**Return to caller:** The work directory path and the final output content.

## Options Explained

| Flag | Purpose |
|------|---------|
| `--prompt-file <path>` | Single-turn prompt read from disk — no stdin plumbing, so the watchdog runs without `STDIN_FILE` |
| `--output-format streaming-messages-json` | NDJSON in the Anthropic Messages wire format — the same shape `claude -p --output-format stream-json` emits, which is why `shared/extract-result.py` and `shared/stream-json-report.sh` consume it unchanged |
| `--permission-mode bypassPermissions` | Approves tool use AND lets the run read outside its working directory. `--always-approve` covers only the first half; a reviewer confined to its cwd reviews on incomplete context and still finalizes cleanly, which is the failure `verify-delegation.sh` scores DEGRADED |
| `--no-plan` | Prevents grok from entering plan mode and answering with a plan instead of doing the work |
| `-m <model>` | Only when the caller named one — otherwise `~/.grok/config.toml` decides |
| `--effort <level>` | Caller value, else `grok.model_efforts[<model>]`, else the section-wide `grok.reasoning_effort`, else the CLI default — the CLI validates this flag PER MODEL, which is why the per-model table exists. Documented alias of `--reasoning-effort` |
| `timeout 1800` | 30-minute cap per attempt |

## Stream File Format

`raw.jsonl` is written **UNPREFIXED** — one bare JSON event per line, no `[HH:MM:SS]` prefix.
This differs deliberately from codex-exec and gemini-exec, whose `log.jsonl` carries a
timestamp prefix that must be stripped with `sed` before `jq` will parse it:
`shared/extract-result.py` reads `raw.jsonl` line by line as JSON, and a prefix would break it
outright. `shared/stream-json-report.sh` accepts both — it inspects the first non-blank line and
synthesizes `[??:??:??]` when it finds none, which is why a grok report's Timing section reads
`Timing: unknown (raw stream — no timestamps)`.

Parse it directly:
```bash
jq -Rr 'fromjson? | objects | select(.type=="result")' "$WORK_DIR/raw.jsonl"
```
`fromjson?` skips a truncated final line — the shape a mid-write kill leaves — instead of
failing the whole read.

## Stream Event Types

`--output-format streaming-messages-json` is the Anthropic Messages wire format:

| Event | Description |
|-------|-------------|
| `system` | Session start; carries `session_id`, `model`, `cwd` and the loaded tool/skill inventory |
| `assistant` | One assistant message; `.message.content[]` holds `text`, `thinking` and `tool_use` blocks |
| `user` | Tool results fed back to the model (`.message.content[]` `tool_result` blocks) |
| `result` | Terminal event: `is_error`, `num_turns`, `duration_ms`, `usage`, `result` (the final text) |
| `error` | Failure event. grok puts the text TOP-LEVEL in `.message`, where claude/codex/gemini nest it under `.error.message`; `extract-result.py` reads both |

**grok has TWO failure shapes, not one, and the second is the common one.** Besides the `error`
event above, a run can fail through the TERMINAL `result` event alone: `is_error:true`,
`num_turns:0` and the reason in `errors[]`, with no `error` event anywhere in the stream. That is
what an argument the CLI refuses produces — measured, `--effort max` against `grok-4.6`, which
accepts only `xhigh|high|medium|low`: rc=1 in 4.7 s, before any API call. `extract-result.py`
covers it (arm F4); before it did, that stream yielded a ZERO-BYTE `output.txt` and the reason
survived only in `stderr.txt`. A reader who knows only the `error` row will look for an event
that is not there.

`--include-partial-messages` would add `stream_event` delta lines. This skill does NOT pass it:
whole messages keep the progress log short by construction, and the extractor wants complete
messages.

## Error Recovery

| Error | Solution |
|-------|----------|
| `grok: command not found` | Install Grok Build — `curl -fsSL https://x.ai/cli/install.sh \| bash`, the installer xAI documents in the CLI's own README — then `grok login` |
| `not authenticated` | `grok login` |
| `output.txt` reads `API Error: Couldn't set model to <x>` | The model id is not one this CLI accepts — `grok models` lists the real set. Fix `grok.models` in config.yaml (the user does this, not you) |
| `STOP: MODEL must match …` | The caller passed a model id outside `[A-Za-z0-9][A-Za-z0-9._-]*`. It is rejected, never rewritten, because the same string is both a path component and a CLI argument |
| Timeout (30 min) | Partial results in `$WORK_DIR/raw.jsonl` |
| Empty response | Check `$WORK_DIR/stderr.txt`, then `$WORK_DIR/raw.jsonl` for an `error` event |
| `WARN: no terminal result event` | The run was cut off — or xAI changed the wire format. Keep `raw.jsonl`; it is the evidence |
| Watchdog `rc=2` | Retries exhausted or global timeout: read `$WORK_DIR/watchdog.exit` and the per-attempt tails the block printed |
| Variables empty | Ensure ALL commands are in a SINGLE Bash call |
| Write tool "File has not been read" | Use a Bash heredoc for new files instead |

## Checklist

- [ ] Pre-flight checks passed
- [ ] Prompt saved to file (via Bash heredoc); `.model` written with the VALIDATED model
- [ ] No model invented: `-m` omitted when the caller named none
- [ ] No effort invented: `--effort` omitted when neither caller nor config set one
- [ ] SUPERVISED_MODE handled (`none` = default pipeline; `shell` = watchdog, BACKGROUND launch)
- [ ] Grok executed with progress displayed, or watchdog heartbeats under supervision
- [ ] Report generated; verdicts taken from `output.txt`, not `report.md`
- [ ] All file paths returned to caller
