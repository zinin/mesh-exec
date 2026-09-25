---
name: gemini-exec
description: Execute any prompt via Gemini CLI with full logging and progress display
user_invocable: true
---

# Gemini Exec

Execute arbitrary prompts via Gemini CLI with streaming progress and full logging.

**Announce at start:** "Using gemini-exec skill to run prompt via Gemini."

> **Gemini manages its own auth/config.** Unlike the ext-claude skills, gemini is NOT
> an anthropic-api provider — the `gemini` CLI handles login itself. This skill does
> NOT call `config-loader.sh export` and does NOT source `ANTHROPIC_*`. The loader is
> used ONLY to (a) discover the plugin data dir for run logs, (b) resolve the default
> model via `get-gemini`, and (c) gate on the `has_gemini` config flag.

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
  SKILL_BASE="$PLUGIN_ROOT/skills/gemini-exec"
fi

Do not rewrite the fence. The else-branch searches `$HOME/.grok/installed-plugins` first (only inside a Grok session: bash has `GROK_SESSION_ID` there and not on Claude Code, so a two-host machine's stale snapshot never reaches a Claude Code run) — an unpublished `grok plugin install <tree>` copy, the one `grok inspect` loads, which a stale Claude cache must not outrank (measured 2026-09-01: `sort -V` on the cache picked 0.12.0 and the wrappers ran the old loader) — then `$HOME/.claude/plugins`, then `$HOME/.grok/plugins`, each version-sorted, `| sort -V | tail -1`, and each tried only when the previous root finds nothing. The roots are tried in PRIORITY order, never in one find over all three: `sort -V` compares whole paths, and `.claude` < `.grok`, so a single find picked the `.grok` copy whatever its version. `.claude` is where a published copy lives on both hosts — Grok loads a marketplace mesh-exec from the Claude cache; only an unpublished tree sits under `installed-plugins`. It then sets `PLUGIN_ROOT` two directories up, and sets `SKILL_BASE=$PLUGIN_ROOT/skills/<this-skill>`. The else-branch repeats `resolve-plugin-root.sh`'s remaining order IDENTICALLY — `$CLAUDE_PLUGIN_ROOT`, `$GROK_PLUGIN_ROOT`, then the three plugin trees — because it cannot call the helper (that is the file it is locating). Keep the two in step: they are one contract in two copies. If nothing resolves it STOPs, rather than resolving a `PLUGIN_ROOT` from the current directory.

From `SKILL_BASE` / `PLUGIN_ROOT`:
- loader = `$SKILL_BASE/../shared/config-loader.sh`
- this skill's own scripts = `$SKILL_BASE/<x>` (e.g. `$SKILL_BASE/generate-md.sh`); sibling shared scripts = `$SKILL_BASE/../shared/<x>` (e.g. `watchdog.sh`)
- data dir = `"$LOADER" data-dir` (`~/.local/state/mesh`, or `$XDG_STATE_HOME/mesh` when that is set); build run paths under `$PLUGIN_DATA/runs/gemini/...`

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

- Running any task through Gemini (code review, generation, analysis, etc.)
- Getting "second opinion" from Google model
- Delegating complex tasks to external agent

## Input

The caller must provide:
- **PROMPT** — the full prompt text to send to Gemini

Optional:
- **TASK_NAME** — short name for log files (default: "task")
- **MODEL** — Gemini model to use. If the caller does NOT specify a model, the skill resolves the default from config (`"$LOADER" get-gemini` reads `gemini.model` from `config.yaml`), falling back to `gemini-3.1-pro-preview` when config is absent (fresh install) or unset. Do NOT hardcode a model yourself — let the config/loader provide the default, and only override when the caller EXPLICITLY supplies a different model.
- **APPROVAL_MODE** — controls tool approval and safety. **MUST be `yolo` unless the caller EXPLICITLY specifies a different mode.** Do NOT choose a mode yourself — if not specified, use `yolo`.
- **SUPERVISED_MODE** — `none` (default) or `shell`. Wraps the gemini invocation in the plugin's `shared/watchdog.sh` (located at `$SKILL_BASE/../shared/watchdog.sh`) with auto-restart on stall. See `codex-exec/SKILL.md` for full semantics. Note: supervised mode uses watchdog stderr heartbeats instead of the default live pipeline progress.

### Approval Modes

| Mode | Description |
|------|-------------|
| yolo | Auto-approve ALL tool calls, full access (default — needed for headless mode) |
| plan | Read-only, no tool calls — only for simple text-only prompts |
| default | Prompt for approval on each tool call (NOT usable in headless mode) |
| auto_edit | Auto-approve edit tools, prompt for others (NOT usable in headless mode) |

## Pre-flight Checks

Run in ONE Bash call. The `gemini` CLI is mandatory; the `has_gemini` config gate is a
soft check (warn-only) because gemini manages its own auth and may work even if the
optional `gemini:` block is absent from `config.yaml`.
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
  SKILL_BASE="$PLUGIN_ROOT/skills/gemini-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"

command -v gemini >/dev/null 2>&1 || { echo "STOP: gemini CLI not found - npm install -g @google/gemini-cli"; exit 1; }
echo "OK: gemini found"

# Soft gate: warn (don't STOP) if the optional gemini: block is unconfigured. gemini
# CLI handles its own auth, so an absent block is non-fatal. get-flag emits 1/0 (never
# true/false) — compare to "1".
if [ -x "$LOADER" ]; then
    if [ "$("$LOADER" get-flag has_gemini 2>/dev/null)" = "1" ]; then
        echo "OK: has_gemini configured"
    else
        echo "WARN: gemini: block not configured in config.yaml (gemini uses its own auth — continuing)"
    fi
fi
```

If the gemini CLI check fails, STOP and report the error to the user verbatim. Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.

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
  SKILL_BASE="$PLUGIN_ROOT/skills/gemini-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"
PLUGIN_DATA="$("$LOADER" data-dir)"
WORK_DIR="$PLUGIN_DATA/runs/gemini/${TIMESTAMP}-${TASK_NAME}"
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

### Step 2: Execute Gemini (SINGLE Bash call)

**IMPORTANT:** Execute the ENTIRE command in ONE Bash call. Substitute actual values for parameters.

Replace before execution:
- `{WORK_DIR}` → path from Step 1
- `{MODEL}` → leave EMPTY if the caller did not supply a model (the block resolves the default from config via `get-gemini`, falling back to `gemini-3.1-pro-preview`). Substitute a model name ONLY when the caller explicitly provided one.
- `{APPROVAL_MODE}` → **MUST be `yolo`** unless caller explicitly provided a different mode.

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
APPROVAL_MODE=$(cat <<'__APPROVAL_MODE_BOUNDARY_82abab34_d691_4dc2_bb9b_706220a58ef5_APPROVAL_MODE_END__'
{APPROVAL_MODE}
__APPROVAL_MODE_BOUNDARY_82abab34_d691_4dc2_bb9b_706220a58ef5_APPROVAL_MODE_END__
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
  SKILL_BASE="$PLUGIN_ROOT/skills/gemini-exec"
fi
SKILL_DIR="$SKILL_BASE"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
# Model resolution: caller-supplied wins; else config (get-gemini); else documented
# default. get-gemini exits 2 with empty stdout on fresh install (no config.yaml) —
# the `|| true` + empty-string check below falls back cleanly.
if [ -z "$MODEL" ]; then
    MODEL=$("$LOADER" get-gemini 2>/dev/null || true)
    [ -z "$MODEL" ] && MODEL="gemini-3.1-pro-preview"
fi
echo "=== Gemini Exec ==="
echo "Work dir: $WORK_DIR"
echo "Model: $MODEL | Mode: $APPROVAL_MODE"
echo ""
touch "$OUTPUT_FILE"

# iter-3 fix (etalon ollama-exec commit 2ed67bc): capture pipeline RC instead
# of failing fast. Post-extraction check + report-gen run UNCONDITIONALLY so
# that 'output.txt empty + log.jsonl non-empty' (gemini error event path:
# type=result with status!="success") surfaces stderr+log tail to caller's
# stderr even when gemini crashes or the pipeline returns non-zero. Note:
# output.txt is touch'd above; the while-loop only writes content for
# type=message+role=assistant, so on error it stays zero-byte.
PIPELINE_RC=0
{ cat "$PROMPT_FILE" | timeout 1800 gemini -p "" \
    -m "$MODEL" \
    -o stream-json \
    --approval-mode "$APPROVAL_MODE" \
    --skip-trust \
    2>"$WORK_DIR/stderr.txt" | while IFS= read -r line || [ -n "$line" ]; do
    echo "$line" | jq -e '.' >/dev/null 2>&1 || continue
    TS=$(date +%H:%M:%S)
    echo "[$TS] $line" >> "$LOG_FILE"
    TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    case "$TYPE" in
        "init") echo ":: Session started (model: $(echo "$line" | jq -r '.model'))" ;;
        "tool_use") echo ":: Tool: $(echo "$line" | jq -r '.tool_name')" ;;
        "tool_result") echo ":: Tool result: $(echo "$line" | jq -r '.status')" ;;
        "message")
            ROLE=$(echo "$line" | jq -r '.role')
            if [ "$ROLE" = "assistant" ]; then
                echo "$line" | jq -j '.content' >> "$OUTPUT_FILE"
            fi
            ;;
        "result") echo ":: Completed ($(echo "$line" | jq -r '.stats.duration_ms // 0')ms)" ;;
    esac
done ; } || PIPELINE_RC=$?

echo ""
echo "=== Generating report ==="
{ [ -s "$LOG_FILE" ] && "$SKILL_DIR/generate-md.sh" "$LOG_FILE" "$MD_FILE" "$TASK_NAME" \
    || echo "WARN: generate-md.sh skipped or failed — report.md may be missing" >&2 ; } || true

# Post-extraction check (iter-3 default-mode parity): fail loudly if gemini
# emitted events (log.jsonl non-empty) but never produced assistant text — the
# typical 401/403/invalid-model failure path where type=result has
# status!="success". Always runs, even on PIPELINE_RC != 0.
if [ ! -s "$OUTPUT_FILE" ] && [ -s "$LOG_FILE" ]; then
  echo "ERROR: output.txt empty but log.jsonl has data" >&2
  [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
  echo "--- log.jsonl tail ---" >&2; tail -5 "$LOG_FILE" >&2
  exit 4
fi

# Surface non-zero pipeline rc with stderr context (iter-3 fix). Triggered
# when gemini crashed/timed-out and post-check above didn't fire (e.g.
# log.jsonl also empty). Without this branch the script would silently exit 0
# after the unconditional report-gen block, masking the real failure.
if [ "$PIPELINE_RC" -ne 0 ]; then
  echo "WARN: gemini pipeline exited rc=$PIPELINE_RC" >&2
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
- `timeout 1800 stdbuf -oL -eL gemini ...` keeps `timeout` as the immediate child under watchdog and disables full buffering for the CLI stream.
- `watchdog.sh` exit code is captured with `|| WATCHDOG_RC=$?` so diagnostics run when watchdog returns 2 or 3.
- On success, `$WORK_DIR/final/` artifacts are copied to `$WORK_DIR/` root so legacy callers that read `$WORK_DIR/raw.jsonl` or `$WORK_DIR/output.txt` continue to work.
- `output.txt` is extracted post-hoc from stream-json message events where `type == "message"` and `role == "assistant"`; malformed or truncated JSONL lines are skipped.

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
  SKILL_BASE="$PLUGIN_ROOT/skills/gemini-exec"
fi && \
SKILL_DIR="$SKILL_BASE" && \
LOADER="$SKILL_BASE/../shared/config-loader.sh" && \
WATCHDOG="$SKILL_BASE/../shared/watchdog.sh" && \
MODEL=$(cat <<'__MODEL_BOUNDARY_28a49527_fa56_4a11_b3ed_cce16f0b257c_MODEL_END__'
{MODEL}
__MODEL_BOUNDARY_28a49527_fa56_4a11_b3ed_cce16f0b257c_MODEL_END__
) && \
if [ -z "$MODEL" ]; then MODEL=$("$LOADER" get-gemini 2>/dev/null || true); if [ -z "$MODEL" ]; then MODEL="gemini-3.1-pro-preview"; fi; fi && \
APPROVAL_MODE=$(cat <<'__APPROVAL_MODE_BOUNDARY_82abab34_d691_4dc2_bb9b_706220a58ef5_APPROVAL_MODE_END__'
{APPROVAL_MODE}
__APPROVAL_MODE_BOUNDARY_82abab34_d691_4dc2_bb9b_706220a58ef5_APPROVAL_MODE_END__
) && \
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR") && \
PROMPT_FILE="$WORK_DIR/prompt.md" && \
echo "=== Gemini Exec (supervised: shell watchdog) ===" && \
echo "Work dir: $WORK_DIR" && \
echo "Model: $MODEL | Mode: $APPROVAL_MODE" && \
echo "" && \
WATCHDOG_RC=0 && { \
    WORK_DIR="$WORK_DIR" \
      STDIN_FILE="$PROMPT_FILE" \
      MAX_RETRIES=2 \
      HARD_ZERO_TIMEOUT=600 \
      GLOBAL_TIMEOUT=3600 \
      STREAM_FILE_NAME=raw.jsonl \
      "$WATCHDOG" -- \
        timeout 1800 stdbuf -oL -eL gemini -p "" \
          -m "$MODEL" \
          -o stream-json \
          --approval-mode "$APPROVAL_MODE" \
          --skip-trust \
    || WATCHDOG_RC=$?; \
} && \
echo "" && \
echo "=== WATCHDOG RESULT (rc=$WATCHDOG_RC) ===" && \
if [ "$WATCHDOG_RC" = "0" ]; then \
  FINAL="$WORK_DIR/final" && \
  python3 -c '
import json
import os
import sys

# iter-3 parity (etalon ollama-exec ISSUE-1): if no assistant message events,
# fall back to type=result with status!="success" so output.txt carries the
# API error message instead of being silently empty (401/403/invalid-model).
final = sys.argv[1]
raw_jsonl = os.path.join(final, "raw.jsonl")
output_txt = os.path.join(final, "output.txt")

content = []
error_msg = None
with open(raw_jsonl) as f:
    for line in f:
        try:
            event = json.loads(line)
        except Exception:
            continue
        if event.get("type") == "message" and event.get("role") == "assistant":
            content.append(event.get("content", ""))
        elif error_msg is None and event.get("type") == "result" and event.get("status") != "success":
            error_msg = event.get("error", {}).get("message", "Unknown error")

with open(output_txt, "w") as out:
    if content:
        out.write("".join(content))
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

If Gemini times out or fails, check partial results:
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
  SKILL_BASE="$PLUGIN_ROOT/skills/gemini-exec"
fi && \
LOADER="$SKILL_BASE/../shared/config-loader.sh" && \
LOG_DIR="$("$LOADER" data-dir)/runs/gemini" && \
LATEST_DIR=$(ls -td "$LOG_DIR"/*/ 2>/dev/null | head -1) && \
[ -n "$LATEST_DIR" ] && echo "Latest: $LATEST_DIR" && ls -la "$LATEST_DIR" && \
[ -f "$LATEST_DIR/log.jsonl" ] && echo "=== Last 30 lines ===" && tail -30 "$LATEST_DIR/log.jsonl" && \
[ -f "$LATEST_DIR/stderr.txt" ] && echo "=== STDERR ===" && cat "$LATEST_DIR/stderr.txt"
```

**Return to caller:** The work directory path and the final output content.

## Options Explained

| Flag | Purpose |
|------|---------|
| `-p ""` | Headless mode, read prompt from stdin |
| `-m $MODEL` | Model to use (default resolved from config via `get-gemini`, falling back to `gemini-3.1-pro-preview`; overridable by the caller) |
| `-o stream-json` | Output JSONL events for parsing and logging |
| `--approval-mode $MODE` | Tool approval policy (**MUST be `yolo`** unless explicitly overridden) |
| `--skip-trust` | Session-only trust for headless automation in the current workspace |
| `timeout 1800` | 30 minute limit |

## Error Recovery

| Error | Solution |
|-------|----------|
| `gemini: command not found` | `npm install -g @google/gemini-cli` |
| `not authenticated` | `gemini` (interactive mode to login) |
| Timeout (30 min) | Partial results in log file |
| Empty response | Check `$WORK_DIR/stderr.txt`, retry |
| Variables empty | Ensure ALL commands in SINGLE Bash call |
| Write tool "File has not been read" | Use Bash heredoc for new files instead |
| Non-JSON lines in output | Filtered automatically by `jq -e` check |

## Log File Format

Log files have timestamp prefix on each line:
```
[HH:MM:SS] {"type":"...", ...}
```

**When parsing logs with jq, ALWAYS strip the timestamp first:**
```bash
grep 'pattern' "$LOG_FILE" | sed 's/^\[[0-9:]*\] //' | jq '...'
```

Without `sed`, jq will fail to parse.

## Stream-JSON Event Types

| Event | Description |
|-------|-------------|
| `init` | Session started, contains `session_id` and `model` |
| `message` (role: user) | User prompt echoed back |
| `message` (role: assistant, delta: true) | Model response chunk |
| `tool_use` | Tool call with `tool_name` and `parameters` |
| `tool_result` | Tool result with `status` and `output` |
| `result` | Completion stats: `total_tokens`, `input_tokens`, `output_tokens`, `duration_ms`, `tool_calls`, `cached` |

## Checklist

- [ ] Pre-flight checks passed
- [ ] Prompt saved to file (via Bash heredoc)
- [ ] SUPERVISED_MODE handled (default `none` preserves legacy behavior; `shell` routes through watchdog.sh)
- [ ] Gemini executed with progress displayed in default mode or watchdog stderr heartbeats in supervised mode
- [ ] Report generated
- [ ] All file paths returned to caller
