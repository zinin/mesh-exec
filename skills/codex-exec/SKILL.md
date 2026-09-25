---
name: codex-exec
description: Execute any prompt via OpenAI Codex CLI with full logging and progress display
user_invocable: true
---

# Codex Exec

Execute arbitrary prompts via OpenAI Codex CLI with streaming progress and full logging.

**Announce at start:** "Using codex-exec skill to run prompt via Codex."

> **Codex manages its own auth/config.** Unlike the ext-claude skills, codex is NOT
> an anthropic-api provider — the `codex` CLI handles login itself. This skill does
> NOT call `config-loader.sh export` and does NOT source `ANTHROPIC_*`. The loader is
> used ONLY to (a) discover the plugin data dir for run logs, (b) gate on the
> `has_codex` config flag, and (c) resolve the default model/level via `get-codex`.

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
  SKILL_BASE="$PLUGIN_ROOT/skills/codex-exec"
fi

Do not rewrite the fence. The else-branch searches `$HOME/.grok/installed-plugins` first (only inside a Grok session: bash has `GROK_SESSION_ID` there and not on Claude Code, so a two-host machine's stale snapshot never reaches a Claude Code run) — an unpublished `grok plugin install <tree>` copy, the one `grok inspect` loads, which a stale Claude cache must not outrank (measured 2026-09-01: `sort -V` on the cache picked 0.12.0 and the wrappers ran the old loader) — then `$HOME/.claude/plugins`, then `$HOME/.grok/plugins`, each version-sorted, `| sort -V | tail -1`, and each tried only when the previous root finds nothing. The roots are tried in PRIORITY order, never in one find over all three: `sort -V` compares whole paths, and `.claude` < `.grok`, so a single find picked the `.grok` copy whatever its version. `.claude` is where a published copy lives on both hosts — Grok loads a marketplace mesh-exec from the Claude cache; only an unpublished tree sits under `installed-plugins`. It then sets `PLUGIN_ROOT` two directories up, and sets `SKILL_BASE=$PLUGIN_ROOT/skills/<this-skill>`. The else-branch repeats `resolve-plugin-root.sh`'s remaining order IDENTICALLY — `$CLAUDE_PLUGIN_ROOT`, `$GROK_PLUGIN_ROOT`, then the three plugin trees — because it cannot call the helper (that is the file it is locating). Keep the two in step: they are one contract in two copies. If nothing resolves it STOPs, rather than resolving a `PLUGIN_ROOT` from the current directory.

From `SKILL_BASE` / `PLUGIN_ROOT`:
- loader = `$SKILL_BASE/../shared/config-loader.sh`
- this skill's own scripts = `$SKILL_BASE/<x>` (e.g. `$SKILL_BASE/generate-md.sh`); sibling shared scripts = `$SKILL_BASE/../shared/<x>` (e.g. `watchdog.sh`)
- data dir = `"$LOADER" data-dir` (`~/.local/state/mesh`, or `$XDG_STATE_HOME/mesh` when that is set); build run paths under `$PLUGIN_DATA/runs/codex/...`

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

- Running any task through Codex (code review, generation, analysis, etc.)
- Getting "second opinion" from OpenAI model
- Delegating complex tasks to external agent

## Input

The caller must provide:
- **PROMPT** — the full prompt text to send to Codex

Optional:
- **TASK_NAME** — short name for log files (default: "task")
- **MODEL** — Codex model to use. If the caller does NOT specify a model, the skill resolves the default from config (`"$LOADER" get-codex` reads `codex.model` from `config.yaml`), falling back to `gpt-5.5` when config is absent (fresh install) or the `codex:` section is missing. Do NOT hardcode a model yourself — let the config/loader provide the default, and only override when the caller EXPLICITLY supplies a different model.
- **REASONING_LEVEL** — reasoning effort level. If the caller does NOT specify a level, the skill resolves the default from config (`get-codex` also returns `codex.reasoning_level`), falling back to `xhigh` when unset. Unknown levels are passed through to codex as-is (the codex CLI/API validates them). Do NOT choose a level yourself.
- **SUPERVISED_MODE** — `none` (default) or `shell`. When `shell`, the codex invocation is wrapped by `shared/watchdog.sh` (located at `$SKILL_BASE/../shared/watchdog.sh`), which auto-restarts the CLI on stall (no stream events for `HARD_ZERO_TIMEOUT` seconds, default 600) up to `MAX_RETRIES=2` times. A wall-clock `GLOBAL_TIMEOUT` (default 3600s) caps total duration across all attempts. Output artifacts are produced under `$WORK_DIR/attempt-N/` (where `$WORK_DIR` is under `~/.local/state/mesh/runs/codex/...`); the successful (or last) attempt is exposed via `$WORK_DIR/final/` symlink, and `raw.jsonl` / `output.txt` / `report.md` are additionally copied to `$WORK_DIR/` root for backward compatibility with legacy callers (note: `log.jsonl` is no longer generated — review skills consume `raw.jsonl` directly; see Task 10b for `generate-md.sh` updates). `SUPERVISED_MODE=none` preserves today's behavior.

### Reasoning Levels

| Level | Flag value | Description |
|-------|------------|-------------|
| none | `"none"` | No extended reasoning |
| minimal | `"minimal"` | Minimal reasoning depth |
| low | `"low"` | Fast responses with lighter reasoning |
| medium | `"medium"` | Balances speed and reasoning depth for everyday tasks |
| high | `"high"` | Greater reasoning depth for complex problems |
| xhigh | `"xhigh"` | Extra high reasoning depth (final fallback default; may consume rate limits quickly) |
| ultra | `"ultra"` | Deepest reasoning (gpt-5.6+ models) |

Levels not in this table are passed through unchanged — OpenAI adds levels with
new models, and the codex CLI/API rejects truly invalid values with a clear
HTTP 400 (`Invalid value: ...`).

## Pre-flight Checks

Run in ONE Bash call. The `codex` CLI is mandatory; the `has_codex` config gate is a
soft check (warn-only) because codex manages its own auth and may work even if the
optional `codex:` block is absent from `config.yaml`.
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
  SKILL_BASE="$PLUGIN_ROOT/skills/codex-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"

command -v codex >/dev/null 2>&1 || { echo "STOP: codex CLI not found - npm install -g @openai/codex"; exit 1; }
echo "OK: codex found"

# Soft gate: warn (don't STOP) if the optional codex: block is unconfigured. codex
# CLI handles its own auth, so an absent block is non-fatal. NEVER test get-codex's
# string for truthiness — it prints a lone '|' when unset; use the get-flag helper.
if [ -x "$LOADER" ]; then
    if [ "$("$LOADER" get-flag has_codex 2>/dev/null)" = "1" ]; then
        echo "OK: has_codex configured"
    else
        echo "WARN: codex: block not configured in config.yaml (codex uses its own auth — continuing)"
    fi
fi
```

If the codex CLI check fails, STOP and report the error to the user verbatim. Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.

## Process

### Step 1: Save Prompt to File

**IMPORTANT:** The Write tool requires reading a file first. For NEW files, use Bash with heredoc instead.

Create prompt file using Bash:
```bash
set -euo pipefail
# PID suffix prevents collision when same TASK_NAME within the same second.
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)-$$
# Heredoc + sanitize TASK_NAME against path traversal / command injection.
# Quoted '__TASK_NAME_BOUNDARY_6556dff9_49b0_469e_b084_ec37755a55fe_TASK_NAME_END__' prevents shell expansion at substitution time AND
# tolerates literal single quotes in TASK_NAME. tr -cd allow-lists alnum + . _ -
# so the result is always a safe path component.
RAW_TASK_NAME=$(cat <<'__TASK_NAME_BOUNDARY_6556dff9_49b0_469e_b084_ec37755a55fe_TASK_NAME_END__'
{TASK_NAME}
__TASK_NAME_BOUNDARY_6556dff9_49b0_469e_b084_ec37755a55fe_TASK_NAME_END__
)
TASK_NAME=$(printf '%s' "$RAW_TASK_NAME" | tr -cd '[:alnum:]._-' | head -c 64)
[ -z "$TASK_NAME" ] && TASK_NAME="task"
# Task 2.5: data dir self-discovered by the loader ($CLAUDE_PLUGIN_DATA empty in skill
# Bash). SKILL_BASE = absolute base dir Claude Code prints at skill load.
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
  SKILL_BASE="$PLUGIN_ROOT/skills/codex-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"
PLUGIN_DATA="$("$LOADER" data-dir)"
WORK_DIR="$PLUGIN_DATA/runs/codex/${TIMESTAMP}-${TASK_NAME}"
mkdir -p "$WORK_DIR"
# Persist sanitized TASK_NAME for step 2 callers — avoids fragile path-parsing
# in generate-md.sh when WORK_DIR contains the -$$ PID suffix.
echo "$TASK_NAME" > "$WORK_DIR/.task_name"
# Stamp the dispatching session. CLAUDE_CODE_SESSION_ID is inherited across the agent
# boundary, so shared/watch-runs.sh and shared/verify-delegation.sh can tell this run from one
# a concurrent orchestration started under the same engine/model in the same data dir.
# Unconditional: an empty value writes an empty line, which both readers treat as unstamped.
printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}" > "$WORK_DIR/.session_id"
cat > "$WORK_DIR/prompt.md" << '__PROMPT_BOUNDARY_a8f7e2c4_3b91_47d8_b6a9_PROMPT_END__'
{PROMPT_TEXT_HERE}
__PROMPT_BOUNDARY_a8f7e2c4_3b91_47d8_b6a9_PROMPT_END__
echo "WORK_DIR=$WORK_DIR"
```

**Important:** Keep this as a SINGLE Bash call, but do not continue the heredoc with `&&`. The heredoc must terminate before the next shell command is parsed.

**Note:** The quoted UUID-style delimiter prevents shell expansion AND minimises collision risk with prompt content. If the prompt happens to contain the literal delimiter on its own line, regenerate the delimiter to a fresh UUID (and update both opening and closing lines).

**Save the WORK_DIR path** for use in Step 2.

### Step 2: Execute Codex (SINGLE Bash call)

**IMPORTANT:** Execute the ENTIRE command in ONE Bash call. Substitute actual values for parameters.

Replace before execution:
- `{WORK_DIR}` → path from Step 1
- `{MODEL}` → leave EMPTY if the caller did not supply a model (the block resolves the default from config via `get-codex`, falling back to `gpt-5.5`). Substitute a model name ONLY when the caller explicitly provided one.
- `{REASONING_LEVEL}` → leave EMPTY if the caller did not supply a level (the block resolves it from config via `get-codex`, falling back to `xhigh`). Substitute a level ONLY when the caller explicitly provided one.

**Branch on `SUPERVISED_MODE`:**
- If `SUPERVISED_MODE` is unset or `none` → use **Default execution** below (unchanged).
- If `SUPERVISED_MODE=shell` → use **Supervised execution**.

#### Default execution (SUPERVISED_MODE=none)

```bash
# === EXECUTE THIS ENTIRE BLOCK AS ONE BASH CALL ===
set -euo pipefail
WORK_DIR="{WORK_DIR}"
MODEL=$(cat <<'__MODEL_BOUNDARY_28a49527_fa56_4a11_b3ed_cce16f0b257c_MODEL_END__'
{MODEL}
__MODEL_BOUNDARY_28a49527_fa56_4a11_b3ed_cce16f0b257c_MODEL_END__
)
REASONING_LEVEL=$(cat <<'__REASONING_LEVEL_BOUNDARY_60678825_9225_47fd_8703_bbca0e7b7d85_REASONING_LEVEL_END__'
{REASONING_LEVEL}
__REASONING_LEVEL_BOUNDARY_60678825_9225_47fd_8703_bbca0e7b7d85_REASONING_LEVEL_END__
)
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR")
PROMPT_FILE="$WORK_DIR/prompt.md"
LOG_FILE="$WORK_DIR/log.jsonl"
OUTPUT_FILE="$WORK_DIR/output.txt"
MD_FILE="$WORK_DIR/report.md"
# Task 2.5: SKILL_BASE = absolute base dir Claude Code prints at skill load.
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
  SKILL_BASE="$PLUGIN_ROOT/skills/codex-exec"
fi
SKILL_DIR="$SKILL_BASE"
# Resolve model/level from config.yaml when the caller left them empty (mirrors
# gemini-exec). Gated on has_codex; get-codex rc!=0 = broken codex: section —
# STOP and surface it. config.yaml is user-owned: do NOT edit it.
LOADER="$SKILL_BASE/../shared/config-loader.sh"
if [ -z "$MODEL" ] || [ -z "$REASONING_LEVEL" ]; then
    CG="|"
    if [ -x "$LOADER" ] && [ "$("$LOADER" get-flag has_codex 2>/dev/null)" = "1" ]; then
        CG=$("$LOADER" get-codex) || { echo "STOP: config-loader get-codex failed — fix config.yaml (user-owned, agents never edit it)"; exit 1; }
    fi
    [ -n "$MODEL" ] || MODEL="${CG%%|*}"
    [ -n "$REASONING_LEVEL" ] || REASONING_LEVEL="${CG##*|}"
fi
MODEL="${MODEL:-gpt-5.5}"
REASONING_LEVEL="${REASONING_LEVEL:-xhigh}"
echo "=== Codex Exec ==="
echo "Work dir: $WORK_DIR"
echo "Model: $MODEL | Reasoning: $REASONING_LEVEL"
echo ""

# iter-3 fix (etalon ollama-exec commit 2ed67bc): capture pipeline RC instead
# of failing fast. Post-extraction check + report-gen run UNCONDITIONALLY so
# that 'output.txt missing + log.jsonl non-empty' (codex error event path:
# type=error / type=turn.failed) surfaces stderr+log tail to caller's stderr
# even when codex crashes or the pipeline returns non-zero. Note: codex CLI
# does not create output.txt at all on failure (verified: invalid-model run).
PIPELINE_RC=0
{ cat "$PROMPT_FILE" | timeout 1800 codex exec \
    --json \
    --skip-git-repo-check \
    --dangerously-bypass-approvals-and-sandbox \
    -m "$MODEL" \
    -c "model_reasoning_effort=\"$REASONING_LEVEL\"" \
    -o "$OUTPUT_FILE" \
    - 2>"$WORK_DIR/stderr.txt" | while IFS= read -r line || [ -n "$line" ]; do
    TS=$(date +%H:%M:%S)
    echo "[$TS] $line" >> "$LOG_FILE"
    TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    case "$TYPE" in
        "thread.started") echo ":: Session started" ;;
        "item.completed")
            ITEM_TYPE=$(echo "$line" | jq -r '.item.type')
            [ "$ITEM_TYPE" = "reasoning" ] && echo ":: Reasoning..."
            [ "$ITEM_TYPE" = "command_execution" ] && echo ":: Running command..."
            [ "$ITEM_TYPE" = "agent_message" ] && echo ":: Agent response received"
            ;;
        "turn.completed") echo ":: Completed" ;;
    esac
done ; } || PIPELINE_RC=$?

echo ""
echo "=== Generating report ==="
{ [ -s "$LOG_FILE" ] && "$SKILL_DIR/generate-md.sh" "$LOG_FILE" "$MD_FILE" "$TASK_NAME" \
    || echo "WARN: generate-md.sh skipped or failed — report.md may be missing" >&2 ; } || true

# Post-extraction check (iter-3 default-mode parity): fail loudly if codex
# emitted events (log.jsonl non-empty) but never produced output.txt — the
# typical 401/403/invalid-model failure path. Always runs, even on
# PIPELINE_RC != 0, so caller sees stderr/log context.
if [ ! -s "$OUTPUT_FILE" ] && [ -s "$LOG_FILE" ]; then
  echo "ERROR: output.txt empty/missing but log.jsonl has data" >&2
  [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
  echo "--- log.jsonl tail ---" >&2; tail -5 "$LOG_FILE" >&2
  exit 4
fi

# Surface non-zero pipeline rc with stderr context (iter-3 fix). Triggered
# when codex crashed/timed-out and post-check above didn't fire (e.g. log.jsonl
# also empty). Without this branch the script would silently exit 0 after the
# unconditional report-gen block, masking the real failure.
if [ "$PIPELINE_RC" -ne 0 ]; then
  echo "WARN: codex pipeline exited rc=$PIPELINE_RC" >&2
  [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
  exit "$PIPELINE_RC"
fi

echo ""
echo "=== FILES ==="
echo "Directory: $WORK_DIR"
ls -la "$WORK_DIR"
echo ""
echo "=== OUTPUT ==="
cat "$OUTPUT_FILE"
```

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
(812s, 1397s, 2001s, 2028s) — the one codex run of that session was launched in the background
and reached 34 minutes untouched.

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
- `command -v jq` precondition fails fast with a clear message if `jq` is missing (QUESTION-8).
- `timeout 1800 stdbuf -oL -eL codex …` — `timeout` is the immediate child of watchdog so it can SIGKILL `codex` if the watchdog itself is wedged; `stdbuf` then disables full-buffering of `codex`'s stdout when redirected to a file (DESIGN-12 fix: previously `stdbuf` was placed *before* `timeout`, which relied on `LD_PRELOAD` inheritance — works in practice but is undocumented).
- `watchdog.sh` exit code is captured with `|| WATCHDOG_RC=$?` so the post-run diagnostic branch always runs even when watchdog returns 2 or 3.
- `timeout 1800` remains as Layer 0 per-attempt backstop; `GLOBAL_TIMEOUT=3600` in watchdog caps total wall-clock across retries.
- On success, `$WORK_DIR/final/` artifacts are copied to `$WORK_DIR/` root so legacy callers that read `$WORK_DIR/output.txt` continue to work.
- `output.txt` is extracted post-hoc by inline `python3` from `raw.jsonl` (DESIGN-20: differs from default mode which uses `codex -o`; if a kill mid-stream truncates the last JSON line, `try/except Exception` simply skips it — last `agent_message` may be a few bytes shorter, acceptable).

```bash
set -euo pipefail && \
command -v jq >/dev/null 2>&1 || { echo "supervised mode requires jq" >&2; exit 64; } && \
WORK_DIR="{WORK_DIR}" && \
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
  SKILL_BASE="$PLUGIN_ROOT/skills/codex-exec"
fi && \
WATCHDOG="$SKILL_BASE/../shared/watchdog.sh" && \
MODEL=$(cat <<'__MODEL_BOUNDARY_28a49527_fa56_4a11_b3ed_cce16f0b257c_MODEL_END__'
{MODEL}
__MODEL_BOUNDARY_28a49527_fa56_4a11_b3ed_cce16f0b257c_MODEL_END__
) && \
REASONING_LEVEL=$(cat <<'__REASONING_LEVEL_BOUNDARY_60678825_9225_47fd_8703_bbca0e7b7d85_REASONING_LEVEL_END__'
{REASONING_LEVEL}
__REASONING_LEVEL_BOUNDARY_60678825_9225_47fd_8703_bbca0e7b7d85_REASONING_LEVEL_END__
) && \
LOADER="$SKILL_BASE/../shared/config-loader.sh" && \
{ [ -n "$MODEL" ] && [ -n "$REASONING_LEVEL" ]; } || { \
  CG="|"; \
  if [ -x "$LOADER" ] && [ "$("$LOADER" get-flag has_codex 2>/dev/null)" = "1" ]; then \
    CG=$("$LOADER" get-codex) || { echo "STOP: config-loader get-codex failed — fix config.yaml (user-owned, agents never edit it)"; exit 1; }; \
  fi; \
  [ -n "$MODEL" ] || MODEL="${CG%%|*}"; \
  [ -n "$REASONING_LEVEL" ] || REASONING_LEVEL="${CG##*|}"; \
} && \
MODEL="${MODEL:-gpt-5.5}" && \
REASONING_LEVEL="${REASONING_LEVEL:-xhigh}" && \
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR") && \
PROMPT_FILE="$WORK_DIR/prompt.md" && \
echo "=== Codex Exec (supervised: shell watchdog) ===" && \
echo "Work dir: $WORK_DIR" && \
echo "Model: $MODEL | Reasoning: $REASONING_LEVEL" && \
echo "" && \
WATCHDOG_RC=0 && { \
    WORK_DIR="$WORK_DIR" \
      STDIN_FILE="$PROMPT_FILE" \
      MAX_RETRIES=2 \
      HARD_ZERO_TIMEOUT=600 \
      GLOBAL_TIMEOUT=3600 \
      STREAM_FILE_NAME=raw.jsonl \
      "$WATCHDOG" -- \
        timeout 1800 stdbuf -oL -eL codex exec \
          --json \
          --skip-git-repo-check \
          --dangerously-bypass-approvals-and-sandbox \
          -m "$MODEL" \
          -c "model_reasoning_effort=\"$REASONING_LEVEL\"" \
          - \
    || WATCHDOG_RC=$?; \
} && \
echo "" && \
echo "=== WATCHDOG RESULT (rc=$WATCHDOG_RC) ===" && \
if [ "$WATCHDOG_RC" = "0" ]; then \
  FINAL="$WORK_DIR/final" && \
  SKILL_DIR="$SKILL_BASE" && \
  python3 -c '
import json
import os
import sys
# Note: the last line of raw.jsonl may be truncated if the CLI was killed mid-write
# (rare, only on stall+KILL). try/except silently skips malformed lines (QUESTION-10).
# iter-3 parity (etalon ollama-exec ISSUE-1): if no agent_message events, fall back
# to type=error / type=turn.failed so output.txt carries the API error message
# instead of being silently empty (401/403/invalid-model paths).
final = sys.argv[1]
agent_text = []
error_msg = None
with open(os.path.join(final, "raw.jsonl")) as f:
    for line in f:
        try: d = json.loads(line)
        except Exception: continue
        item = d.get("item") or {}
        if d.get("type") == "item.completed" and item.get("type") == "agent_message":
            agent_text.append(item.get("text", ""))
        elif error_msg is None and d.get("type") == "error":
            error_msg = d.get("message", "Unknown error")
        elif error_msg is None and d.get("type") == "turn.failed":
            error_msg = d.get("error", {}).get("message", "Unknown error")
with open(os.path.join(final, "output.txt"), "w") as out:
    if agent_text:
        out.write("".join(agent_text))
    elif error_msg:
        out.write(f"API Error: {error_msg}")
    # else: leave empty — post-check downstream catches this
' "$FINAL" && \
  cp -f "$FINAL/raw.jsonl" "$WORK_DIR/raw.jsonl" && \
  cp -f "$FINAL/output.txt" "$WORK_DIR/output.txt" && \
  { [ ! -x "$SKILL_DIR/generate-md.sh" ] || "$SKILL_DIR/generate-md.sh" "$FINAL/raw.jsonl" "$FINAL/report.md" "$TASK_NAME" || true; } && \
  { [ ! -f "$FINAL/report.md" ] || cp -f "$FINAL/report.md" "$WORK_DIR/report.md" || true; } && \
  echo "=== FILES ===" && ls -la "$WORK_DIR" && \
  echo "=== OUTPUT ===" && cat "$WORK_DIR/output.txt"; \
elif [ "$WATCHDOG_RC" = "2" ]; then \
  echo "## Review Diagnostics" && \
  jq -r '"- Attempts: \(.attempts)\n- Reason: \(.reason)\n- Elapsed: \(.elapsed_sec)s\n- Last attempt: \(.last_attempt_dir)"' "$WORK_DIR/watchdog.exit" 2>/dev/null || cat "$WORK_DIR/watchdog.exit" && \
  echo "" && echo "=== PER-ATTEMPT TAILS ===" && \
  for a in "$WORK_DIR"/attempt-*; do \
    [ -d "$a" ] || continue; \
    echo "-- $a --"; tail -20 "$a/raw.jsonl" 2>/dev/null || true; \
    [ -s "$a/stderr.txt" ] && { echo "-- $a/stderr --"; tail -20 "$a/stderr.txt" || true; }; \
    echo ""; \
  done; \
  exit 2; \
else \
  echo "Watchdog internal error (exit $WATCHDOG_RC)" && exit "$WATCHDOG_RC"; \
fi
```

### Step 3: Handle Errors

If Codex times out or fails, check partial results:
```bash
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
  SKILL_BASE="$PLUGIN_ROOT/skills/codex-exec"
fi && \
LOADER="$SKILL_BASE/../shared/config-loader.sh" && \
LOG_DIR="$("$LOADER" data-dir)/runs/codex" && \
LATEST_DIR=$(ls -td "$LOG_DIR"/*/ 2>/dev/null | head -1) && \
[ -n "$LATEST_DIR" ] && echo "Latest: $LATEST_DIR" && ls -la "$LATEST_DIR" && \
{ [ ! -f "$LATEST_DIR/log.jsonl" ] || { echo "=== Last 30 lines (log.jsonl, default mode) ==="; tail -30 "$LATEST_DIR/log.jsonl"; }; } && \
{ [ ! -f "$LATEST_DIR/raw.jsonl" ] || { echo "=== Last 30 lines (raw.jsonl, supervised mode) ==="; tail -30 "$LATEST_DIR/raw.jsonl"; }; } && \
{ [ ! -f "$LATEST_DIR/stderr.txt" ] || { echo "=== STDERR ==="; cat "$LATEST_DIR/stderr.txt"; }; }
```

**Return to caller:** The work directory path and the final output content.

## Options Explained

| Flag | Purpose |
|------|---------|
| `--json` | Output JSONL events for parsing and logging |
| `--skip-git-repo-check` | Work outside git repositories |
| `--dangerously-bypass-approvals-and-sandbox` | Skip approvals AND disable bwrap sandbox. Required in Docker — bwrap cannot create user namespaces there. Do NOT combine with `--full-auto` or `-s`: `--full-auto` is an alias for `--sandbox workspace-write` and will override `-s danger-full-access` depending on flag order, re-activating bwrap. |
| `-m $MODEL` | Model to use (caller value, else `codex.model` from config.yaml, else `gpt-5.5`) |
| `-c model_reasoning_effort="$REASONING_LEVEL"` | Reasoning effort (caller value, else `codex.reasoning_level` from config.yaml, else `xhigh`; unknown levels pass through) |
| `-o <file>` | Save final response to file |
| `timeout 1800` | 30 minute limit |

## Error Recovery

| Error | Solution |
|-------|----------|
| `codex: command not found` | `npm install -g @openai/codex` |
| `not authenticated` | `codex login` |
| Timeout (30 min) | Partial results in log file |
| Empty response | Check `$WORK_DIR/stderr.txt` and codex's own logs (`~/.codex/logs/`), retry |
| Variables empty | Ensure ALL commands in SINGLE Bash call |
| Write tool "File has not been read" | Use Bash heredoc for new files instead |

## Log File Format

Log files have timestamp prefix on each line:
```
[HH:MM:SS] {"type":"...", ...}
```

**When parsing logs with jq, ALWAYS strip the timestamp first:**
```bash
grep 'pattern' "$LOG_FILE" | sed 's/^\[[0-9:]*\] //' | jq '...'
```

Without `sed`, jq will fail to parse and may cause "command not found" errors.

## Checklist

- [ ] Pre-flight checks passed
- [ ] Prompt saved to file (via Bash heredoc)
- [ ] SUPERVISED_MODE handled (default `none` preserves legacy behavior; `shell` routes through watchdog.sh)
- [ ] Codex executed with progress displayed
- [ ] Report generated
- [ ] All file paths returned to caller
