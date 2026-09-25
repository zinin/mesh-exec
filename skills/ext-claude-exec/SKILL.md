---
name: ext-claude-exec
description: Execute prompts via claude -p against alt-provider Anthropic-compatible endpoints (z.ai, Alibaba, DeepSeek, LiteLLM, Ollama daemon) with logging
user_invocable: true
---

# Ext-Claude Exec

Execute arbitrary prompts via `claude -p` with provider/model env taken from
`~/.config/mesh/config.yaml`. Wraps both Anthropic-API-style providers
(GLM, Alibaba, DeepSeek, LiteLLM) and Ollama daemon.

When `HOST_CLAUDE=1`, the same `claude -p` pipeline talks to official Claude Code
(`claude login`): skip provider `export`, unset leaked `ANTHROPIC_*`, write
`runs/claude/<alias>/`, pass `--model` when MODEL is set.

**Announce at start:** "Using ext-claude-exec skill to run prompt via configured provider."

## CRITICAL: Tool Execution Rules

### Bash Variables

**The Bash tool runs each call in an ISOLATED shell. Variables DO NOT persist between calls.**

GOOD (single call with `&&`):
```bash
WORK_DIR="/path/to/dir" && cat "$WORK_DIR/file"
```

**Rule: Put ALL related commands in ONE Bash call using `&&` to chain them.**

### Write Tool Limitation

For NEW files, use Bash heredoc:
```bash
cat > "/path/new-file.txt" << 'EOF'
content here
EOF
```

## Input

The caller must provide:
- **PROMPT** — the full prompt text
- **MODEL** — required on the provider path: id from `models[]` in config, e.g.
  `zai/glm`, `ollama/kimi`, `alibaba/qwen`. When `HOST_CLAUDE=1`, this is a
  `claude.models` alias with no slash (`opus`, `fable`). Orchestrators that
  selected a catalog entry always pass MODEL. Omit it only for the CLI default
  (empty catalog → one run without `--model`).

Optional:
- **TASK_NAME** — short name for log dirs (default: "task")
- **SUPERVISED_MODE** — `none` (default) or `shell` (wraps in `shared/watchdog.sh`)
- **SKIP_TOKEN_PRECHECK** — set to `1` to skip token-precheck for anthropic-api providers
- **HOST_CLAUDE** — `1` = official `claude login`. MODEL is a `claude.models` alias
  with no slash. Skip `config-loader.sh export` and token/ollama prechecks; source
  `host-claude-env.sh`; run dir `runs/claude/<alias>/` (or `runs/claude/_default/`
  when MODEL is omitted). Pass `--model "$MODEL"` only when MODEL is non-empty.

## Template substitution convention

This SKILL.md contains `{NAME}` placeholders (e.g. `{MODEL}`, `{PROMPT}`, `{TASK_NAME}`, `{WORK_DIR}`). When the calling LLM composes the Bash tool call, **it replaces each `{NAME}` literally with the caller-supplied value** before the shell sees the script. Two embedding patterns are used, chosen by the shape of the value:

1. **Short, constrained scalars** (`MODEL`, `WORK_DIR`, `HOST_CLAUDE`): plain double-quoted assignment, e.g. `MODEL="{MODEL}"`. Safe because these values are constrained to `[a-z0-9._/-]` (model id grammar, see Design §5), the flag `1`/empty, or are paths derived inside the script. If a value could ever contain `"` or `$`, use the heredoc form below — this is exactly why `TASK_NAME` (free-form caller text) is embedded via heredoc in Step 1, not as a plain assignment.

2. **Multi-line or free-form values** (`PROMPT`, `TASK_NAME`): bash heredoc with a unique 16-hex delimiter, e.g. `__PROMPT_BOUND_a8f7e2c4__`. The hex suffix makes accidental collision with prompt content astronomically unlikely; if a collision is ever observed, regenerate the delimiter with a fresh suffix and retry. The single-quoted form `<<'__BOUND__'` is mandatory — it disables `$VAR`/backtick expansion inside the heredoc so prompt content cannot leak shell metachars into the surrounding script.

Why this matters (CONCERN-2): wrapping every value in a heredoc with a fixed delimiter (`__MODEL_BOUND__`) created a small but non-zero collision risk and added noise around values that don't need it. The two-tier convention removes the collision class for short ids while keeping the heredoc protection where it actually matters.

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
  SKILL_BASE="$PLUGIN_ROOT/skills/ext-claude-exec"
fi

Do not rewrite the fence. The else-branch searches `$HOME/.grok/installed-plugins` first (only inside a Grok session: bash has `GROK_SESSION_ID` there and not on Claude Code, so a two-host machine's stale snapshot never reaches a Claude Code run) — an unpublished `grok plugin install <tree>` copy, the one `grok inspect` loads, which a stale Claude cache must not outrank (measured 2026-09-01: `sort -V` on the cache picked 0.12.0 and the wrappers ran the old loader) — then `$HOME/.claude/plugins`, then `$HOME/.grok/plugins`, each version-sorted, `| sort -V | tail -1`, and each tried only when the previous root finds nothing. The roots are tried in PRIORITY order, never in one find over all three: `sort -V` compares whole paths, and `.claude` < `.grok`, so a single find picked the `.grok` copy whatever its version. `.claude` is where a published copy lives on both hosts — Grok loads a marketplace mesh-exec from the Claude cache; only an unpublished tree sits under `installed-plugins`. It then sets `PLUGIN_ROOT` two directories up, and sets `SKILL_BASE=$PLUGIN_ROOT/skills/<this-skill>`. The else-branch repeats `resolve-plugin-root.sh`'s remaining order IDENTICALLY — `$CLAUDE_PLUGIN_ROOT`, `$GROK_PLUGIN_ROOT`, then the three plugin trees — because it cannot call the helper (that is the file it is locating). Keep the two in step: they are one contract in two copies. If nothing resolves it STOPs, rather than resolving a `PLUGIN_ROOT` from the current directory.

From `SKILL_BASE` / `PLUGIN_ROOT`:
- loader = `$SKILL_BASE/../shared/config-loader.sh`
- sibling scripts = `$SKILL_BASE/../shared/<x>`; this skill's own scripts = `$SKILL_BASE/<x>`
- data dir = `"$LOADER" data-dir` (`~/.local/state/mesh`, or `$XDG_STATE_HOME/mesh` when that is set)

## Pre-flight Checks

Run in ONE Bash call. Provider path resolves kind via `config-loader.sh export`.
`HOST_CLAUDE=1` skips `export` / token-precheck / ollama-precheck: auth is
`claude login`. `command -v claude` stays. Timeouts come from `get-runtime` JSON,
not from export.

```bash
set -u
MODEL="{MODEL}"
HOST_CLAUDE="{HOST_CLAUDE}"
# Task 2.5 (CC 2.1.156): ${CLAUDE_PLUGIN_ROOT}/${CLAUDE_PLUGIN_DATA} are EMPTY in
# Bash-tool calls from skills. Locate files via the absolute base dir Claude Code
# prints at skill load ("Base directory for this skill: <ABS>"). See "## Locating
# plugin files (Task 2.5)" below.
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
  SKILL_BASE="$PLUGIN_ROOT/skills/ext-claude-exec"
fi
SKILL_DIR="$SKILL_BASE"
LOADER="$SKILL_BASE/../shared/config-loader.sh"

command -v claude >/dev/null 2>&1 || { echo "STOP: claude CLI not found"; exit 1; }
command -v jq     >/dev/null 2>&1 || { echo "STOP: jq not found"; exit 1; }
command -v bc     >/dev/null 2>&1 || { echo "STOP: bc not found (used by progress-monitor.sh)"; exit 1; }
# curl serves the token precheck and the ollama precheck — provider path only. HOST_CLAUDE=1
# skips both, so a machine without curl still runs the official CLI.
[ "${HOST_CLAUDE:-}" = "1" ] || command -v curl >/dev/null 2>&1 || { echo "STOP: curl not found (provider precheck needs it)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "STOP: python3 not found"; exit 1; }

if [ "${HOST_CLAUDE:-}" = "1" ]; then
    # Official Claude Code CLI. Do NOT call config-loader.sh export — a leftover
    # ANTHROPIC_BASE_URL from a previous ext-claude run would send opus to z.ai.
    # shellcheck source=/dev/null
    . "$SKILL_DIR/host-claude-env.sh"
    # rc=2 is "no config.yaml at all": the official CLI needs no provider section, so a
    # standalone claude-executor / claude-code-reviewer run gets the documented defaults and a
    # WARN naming the file the loader looked for. rc=1 (a file that exists and does not validate)
    # still STOPs — that is a user-owned config to fix, never to guess around.
    RT_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
    RT_RC=0; RUNTIME=$("$LOADER" get-runtime 2>"$RT_ERR") || RT_RC=$?
    if [ "$RT_RC" -eq 2 ]; then
        echo "WARN: no config.yaml at $("$LOADER" config-path) — HOST_CLAUDE uses default timeouts single=1800s stall=600s global=3600s retries=2" >&2
        RUNTIME='{"timeouts":{"single_run_sec":1800,"stall_sec":600,"global_sec":3600,"max_retries":2}}'
    elif [ "$RT_RC" -ne 0 ]; then
        echo "STOP: config-loader get-runtime failed — surface the error verbatim; do NOT edit config.yaml (user-owned):" >&2; cat "$RT_ERR" >&2; rm -f "$RT_ERR"; exit 1
    fi
    rm -f "$RT_ERR"
    SINGLE_RUN=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.single_run_sec')
    STALL=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.stall_sec')
    GLOBAL=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.global_sec')
    MAX_RETRIES=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.max_retries')
    echo "OK: HOST_CLAUDE=1 (claude login, no provider export); timeouts single=${SINGLE_RUN}s stall=${STALL}s global=${GLOBAL}s retries=$MAX_RETRIES"
else
    # Validate + resolve env via loader. cmd_export writes a mode-600 tmpfile and
    # prints its path on stdout — see CONCERN-1. We source it and unlink immediately
    # so the token never lands in the Bash-tool transcript.
    ENV_FILE=$("$LOADER" export "$MODEL") || { echo "STOP: config-loader failed — surface the error verbatim; do NOT edit config.yaml (user-owned)"; exit 1; }
    [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ] || { echo "STOP: config-loader produced no env file"; exit 1; }
    trap 'rm -f "$ENV_FILE"' EXIT
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    rm -f "$ENV_FILE"
    trap - EXIT

    case "$CLAUDE_MESH_PROVIDER_KIND" in
        anthropic-api)
            if [ "${SKIP_TOKEN_PRECHECK:-0}" != "1" ]; then
                PRECHECK_RC=0
                "$SKILL_DIR/token-precheck.sh" "$ANTHROPIC_BASE_URL" "$ANTHROPIC_AUTH_TOKEN" || PRECHECK_RC=$?
                case "$PRECHECK_RC" in
                    0) echo "OK: anthropic-api precheck passed" ;;
                    5) echo "STOP: Token expired or invalid for $MODEL" >&2; exit 5 ;;
                    6) echo "STOP: Endpoint unreachable for $MODEL ($ANTHROPIC_BASE_URL)" >&2; exit 6 ;;
                    *) echo "WARN: anthropic-api precheck rc=$PRECHECK_RC, continuing" >&2 ;;
                esac
            fi
            ;;
        ollama-daemon)
            # Capture rc BEFORE echo — otherwise $? becomes rc of `echo` (always 0)
            # and the real precheck failure code (5=auth / 6=unreachable) is masked.
            "$SKILL_DIR/ollama-precheck.sh" "$ANTHROPIC_BASE_URL" \
                || { rc=$?; echo "STOP: ollama-precheck failed (rc=$rc)" >&2; exit "$rc"; }
            ;;
        *)
            echo "STOP: unknown provider kind $CLAUDE_MESH_PROVIDER_KIND" >&2
            exit 1
            ;;
    esac
fi
```

## Process

### Step 1: Save Prompt to File

```bash
set -euo pipefail
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)-$$
# TASK_NAME is free-form caller text, so it MUST be embedded via a single-quoted
# heredoc (not a plain "{TASK_NAME}" assignment): that disables $VAR/backtick/quote
# expansion at LLM-substitution time, BEFORE tr sanitizes the value. See the
# "Template substitution convention" section above. tr -cd then allow-lists a safe component.
RAW_TASK_NAME=$(cat <<'__TASK_NAME_BOUND_b3d9f1a7__'
{TASK_NAME}
__TASK_NAME_BOUND_b3d9f1a7__
)
TASK_NAME=$(printf '%s' "$RAW_TASK_NAME" | tr -cd '[:alnum:]._-' | head -c 64)
[ -z "$TASK_NAME" ] && TASK_NAME="task"

MODEL="{MODEL}"
HOST_CLAUDE="{HOST_CLAUDE}"

# Task 2.5: data dir is self-discovered by the loader (CLAUDE_PLUGIN_DATA is empty
# in skill Bash calls). SKILL_BASE = absolute base dir Claude Code prints at load.
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
  SKILL_BASE="$PLUGIN_ROOT/skills/ext-claude-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"
PLUGIN_DATA="$("$LOADER" data-dir)"
if [ "${HOST_CLAUDE:-}" = "1" ]; then
    # MODEL is unvalidated on this path — the provider branch below gets its check from
    # `"$LOADER" export`, which HOST_CLAUDE skips. It becomes a path component two lines
    # down and a `claude -p --model` argument, so reject the two spellings that are wrong by
    # construction rather than by catalog: a slash (that is ext-claude's <provider>/<short>,
    # which would silently create a depth-3 run dir) and any `..`, `-` or `.` lead (path
    # traversal out of the data dir, or a value the CLI reads as a flag). grok-exec runs the
    # same guard at skills/grok-exec/SKILL.md. claude.models is validated with the wider
    # IDENT_RE, which admits `:`/`@`; this guard rejects those for HOST_CLAUDE on purpose —
    # watch-runs.sh and verify-delegation.sh accept [A-Za-z0-9][A-Za-z0-9._-]* only, so a
    # `:`/`@` alias would mkdir a run dir the delegation guard then refuses to score.
    if [ -n "${MODEL:-}" ] && ! printf '%s' "$MODEL" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        echo "STOP: MODEL '$MODEL' must match [A-Za-z0-9][A-Za-z0-9._-]* (HOST_CLAUDE alias, e.g. opus)" >&2
        exit 1
    fi
    # Do not split PROVIDER/SHORT. MODEL is a claude.models alias (no slash).
    # Empty MODEL (CLI default / empty catalog): `runs/claude/default/` is forbidden —
    # "default" looks like a catalog alias. Use `_default` so the watcher roster for a
    # fallback reviewer is `claude/_default`. Spec: empty catalog → one run without `--model`.
    # Orchestrators that selected a catalog entry always pass MODEL.
    WORK_DIR="$PLUGIN_DATA/runs/claude/${MODEL:-_default}/${TIMESTAMP}-${TASK_NAME}"
else
    PROVIDER="${MODEL%%/*}"
    SHORT="${MODEL#*/}"
    WORK_DIR="$PLUGIN_DATA/runs/ext-claude/$PROVIDER/$SHORT/${TIMESTAMP}-${TASK_NAME}"
fi
mkdir -p "$WORK_DIR"
echo "$TASK_NAME" > "$WORK_DIR/.task_name"
# Stamp the dispatching session. CLAUDE_CODE_SESSION_ID is inherited across the agent
# boundary, so shared/watch-runs.sh and shared/verify-delegation.sh can tell this run from one
# a concurrent orchestration started under the same engine/model in the same data dir.
# Unconditional: an empty value writes an empty line, which both readers treat as unstamped.
printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}" > "$WORK_DIR/.session_id"
# The mode this run was decided in, read back by both Step 2 launch fences: they receive
# MODEL / HOST_CLAUDE by a second substitution and must not launch on a value that differs
# from the one this fence validated — HOST_CLAUDE=1 here and empty there would send the alias
# down the provider path with a leftover ANTHROPIC_BASE_URL.
printf 'MODEL=%s\nHOST_CLAUDE=%s\n' "${MODEL:-}" "${HOST_CLAUDE:-}" > "$WORK_DIR/.mode"

cat > "$WORK_DIR/prompt.md" << '__PROMPT_BOUND_a8f7e2c4__'
{PROMPT}
__PROMPT_BOUND_a8f7e2c4__

echo "WORK_DIR=$WORK_DIR"
```

### Step 2: Execute Claude (SINGLE Bash call)

Branch on `SUPERVISED_MODE`:
- `none` (default) → `progress-monitor.sh` pipeline
- `shell` → `shared/watchdog.sh` wrapper

#### Default mode

```bash
set -euo pipefail
WORK_DIR="{WORK_DIR}"
MODEL="{MODEL}"
HOST_CLAUDE="{HOST_CLAUDE}"
# Cross-fence consistency: Step 1 recorded the MODEL / HOST_CLAUDE it validated in
# $WORK_DIR/.mode. A value substituted differently here would launch under the wrong path —
# HOST_CLAUDE=1 there and empty here sends the alias to a provider endpoint — so stop BEFORE
# the CLI starts, not after. A run dir without .mode predates this stamp and is not checked.
if [ -f "$WORK_DIR/.mode" ]; then
    _M_MODEL=$(sed -n 's/^MODEL=//p' "$WORK_DIR/.mode"); _M_HOST=$(sed -n 's/^HOST_CLAUDE=//p' "$WORK_DIR/.mode")
    [ "$_M_MODEL" = "${MODEL:-}" ] && [ "$_M_HOST" = "${HOST_CLAUDE:-}" ] \
        || { echo "STOP: this fence's MODEL='${MODEL:-}' HOST_CLAUDE='${HOST_CLAUDE:-}' differ from Step 1's MODEL='$_M_MODEL' HOST_CLAUDE='$_M_HOST' (\$WORK_DIR/.mode) — substitute the same values as Step 1; do not launch" >&2; exit 1; }
fi
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
  SKILL_BASE="$PLUGIN_ROOT/skills/ext-claude-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"
SKILL_DIR="$SKILL_BASE"
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR")

if [ "${HOST_CLAUDE:-}" = "1" ]; then
    # Skip export. Source host-claude-env.sh so a leftover parent-shell env cannot
    # send HOST_CLAUDE opus to z.ai. Timeouts from get-runtime JSON, not from export.
    # shellcheck source=/dev/null
    . "$SKILL_DIR/host-claude-env.sh"
    # rc=2 is "no config.yaml at all": the official CLI needs no provider section, so a
    # standalone claude-executor / claude-code-reviewer run gets the documented defaults and a
    # WARN naming the file the loader looked for. rc=1 (a file that exists and does not validate)
    # still STOPs — that is a user-owned config to fix, never to guess around.
    RT_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
    RT_RC=0; RUNTIME=$("$LOADER" get-runtime 2>"$RT_ERR") || RT_RC=$?
    if [ "$RT_RC" -eq 2 ]; then
        echo "WARN: no config.yaml at $("$LOADER" config-path) — HOST_CLAUDE uses default timeouts single=1800s stall=600s global=3600s retries=2" >&2
        RUNTIME='{"timeouts":{"single_run_sec":1800,"stall_sec":600,"global_sec":3600,"max_retries":2}}'
    elif [ "$RT_RC" -ne 0 ]; then
        echo "STOP: config-loader get-runtime failed — surface the error verbatim; do NOT edit config.yaml (user-owned):" >&2; cat "$RT_ERR" >&2; rm -f "$RT_ERR"; exit 1
    fi
    rm -f "$RT_ERR"
    SINGLE_RUN=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.single_run_sec')
    echo "=== Ext-Claude Exec (HOST_CLAUDE stream mode) ==="
    echo "Work dir: $WORK_DIR"
    echo "Model:    ${MODEL:-<CLI default>}"
    echo "Auth:     claude login (no provider export)"
else
    # Resolve env via loader tmpfile (CONCERN-1)
    ENV_FILE=$("$LOADER" export "$MODEL") || { echo "STOP: config-loader failed — surface the error verbatim; do NOT edit config.yaml (user-owned)" >&2; exit 1; }
    trap 'rm -f "$ENV_FILE"' EXIT
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    rm -f "$ENV_FILE"
    trap - EXIT
    SINGLE_RUN="${CLAUDE_MESH_TIMEOUT_SINGLE_RUN_SEC:-1800}"
    echo "=== Ext-Claude Exec (stream mode) ==="
    echo "Work dir: $WORK_DIR"
    echo "Model:    $MODEL ($ANTHROPIC_MODEL)"
    echo "Provider kind: $CLAUDE_MESH_PROVIDER_KIND"
fi

echo ""
echo "=== Executing claude (live progress below) ==="
unset CLAUDECODE

PIPELINE_RC=0
# Timeout from config (get-runtime when HOST_CLAUDE=1, else CLAUDE_MESH_TIMEOUT_SINGLE_RUN_SEC
# exported by config-loader).
#
# --permission-mode bypassPermissions is NOT optional here. Under -p there is nobody to
# answer a permission prompt, so every request is auto-denied and the reviewer is confined
# to the directory it was launched in — SILENTLY. It cannot read a sibling repository to
# check an API signature against the real source, and the review degrades to guesswork
# rather than failing loudly (see verify-delegation.sh's DEGRADED verdict, which exists to
# catch exactly that). Measured on CC 2.1.221, 2026-08-04: without the flag a Read outside
# the cwd returns "Claude requested permissions to read from <path>, but you haven't granted
# it yet" and a Bash `cat` returns "was blocked ... may only concatenate files from the
# allowed working directories"; with it, both reads and Bash searches work anywhere.
# --add-dir is NOT needed alongside it — the bypass lifts the directory confinement too
# (also measured), so there is no list of trusted roots to keep up to date.
# This restores parity with the other two engines, which have carried an equivalent since
# the first commit: codex `--dangerously-bypass-approvals-and-sandbox`, gemini
# `--approval-mode yolo`. ext-claude was the only path that never had one.
# HOST_CLAUDE=1: do not pass --model when MODEL is empty.
if [ "${HOST_CLAUDE:-}" = "1" ] && [ -n "$MODEL" ]; then
  { timeout "$SINGLE_RUN" claude -p --model "$MODEL" --permission-mode bypassPermissions --output-format stream-json < "$WORK_DIR/prompt.md" 2>"$WORK_DIR/stderr.txt" | \
    "$SKILL_DIR/progress-monitor.sh" "$WORK_DIR" "$MODEL" ; } || PIPELINE_RC=$?
else
  { timeout "$SINGLE_RUN" claude -p --permission-mode bypassPermissions --output-format stream-json < "$WORK_DIR/prompt.md" 2>"$WORK_DIR/stderr.txt" | \
    "$SKILL_DIR/progress-monitor.sh" "$WORK_DIR" "$MODEL" ; } || PIPELINE_RC=$?
fi

echo ""
echo "=== Generating report ==="
{ "$SKILL_DIR/../shared/stream-json-report.sh" "$WORK_DIR/log.jsonl" "$WORK_DIR/report.md" "$MODEL" "" "$TASK_NAME" \
    || echo "WARN: shared/stream-json-report.sh failed" >&2 ; } || true

if [ ! -s "$WORK_DIR/output.txt" ] && [ -s "$WORK_DIR/raw.jsonl" ]; then
  echo "ERROR: output.txt empty but raw.jsonl has data" >&2
  [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
  echo "--- raw.jsonl tail ---" >&2; tail -5 "$WORK_DIR/raw.jsonl" >&2
  exit 4
fi

if [ "$PIPELINE_RC" -ne 0 ]; then
  echo "WARN: claude pipeline exited rc=$PIPELINE_RC" >&2
  [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
  exit "$PIPELINE_RC"
fi
```

#### Supervised mode (SUPERVISED_MODE=shell)

**Run this block as a BACKGROUND Bash task — `run_in_background: true`, not a foreground call.**
The harness caps a foreground call at `BASH_MAX_TIMEOUT_MS` (ten minutes out of the box; the
effective ceiling is the larger of that and `BASH_DEFAULT_TIMEOUT_MS`) and SIGTERMs it at the
cap, taking the whole process group with it. `watchdog.sh`'s `trap 'cleanup 143' TERM` then
records `exit_code: 143` and the run is lost with no `watchdog.exit` to explain it — the shape
`verify-delegation.sh` reports as `KILLED`. Every budget this block passes down sits ABOVE that
cap (`single_run_sec` 1800, `global_sec` 3600), so on a foreground launch the watchdog's
restarts and its wall-clock deadline are unreachable by construction. Measured 2026-08-05 on
CC 2.1.222: 5 of 5 foreground runs died at 600-605s with their streams still growing
(`age_sec` 0-6), each tool result reading `Exit code 143 / Command timed out after 10m 0s`;
every run launched with `run_in_background: true` outlived the cap — 812s, 1397s, 2001s, 2028s.

Backgrounding costs nothing here, because everything the caller needs happens INSIDE this
block: watchdog, copy-up, `extract-result.py`, `shared/stream-json-report.sh` and the bail diagnostics. The
launch returns a task id and the path of the file this block's stdout is written to. Report the
work dir, end the turn, and read `$WORK_DIR/output.txt` / `report.md` — and that stdout file for
an `rc=2` bail — once you are woken. Do NOT wrap the launch in a foreground wait or a poll loop:
such a call is capped exactly like the one you just avoided. If the run dies, report the death
rather than relaunching it — a second, untracked run dir is worse than a reported failure.

**That is the Claude Code shape.** On Grok Build — no Skill tool, no SendMessage, nothing that
wakes an idle wrapper — do NOT end the turn while the CLI is alive: keep the launch in the
background and wait on its command id with `get_command_or_subagent_output` (loop; each call's
ceiling is 600 s) until it exits, then read `$WORK_DIR/output.txt` and report, exactly as the
agent definition says. Ending the turn there leaves the review on disk with nobody to collect it.

```bash
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "supervised mode requires jq" >&2; exit 64; }
WORK_DIR="{WORK_DIR}"
MODEL="{MODEL}"
HOST_CLAUDE="{HOST_CLAUDE}"
# Cross-fence consistency: Step 1 recorded the MODEL / HOST_CLAUDE it validated in
# $WORK_DIR/.mode. A value substituted differently here would launch under the wrong path —
# HOST_CLAUDE=1 there and empty here sends the alias to a provider endpoint — so stop BEFORE
# the CLI starts, not after. A run dir without .mode predates this stamp and is not checked.
if [ -f "$WORK_DIR/.mode" ]; then
    _M_MODEL=$(sed -n 's/^MODEL=//p' "$WORK_DIR/.mode"); _M_HOST=$(sed -n 's/^HOST_CLAUDE=//p' "$WORK_DIR/.mode")
    [ "$_M_MODEL" = "${MODEL:-}" ] && [ "$_M_HOST" = "${HOST_CLAUDE:-}" ] \
        || { echo "STOP: this fence's MODEL='${MODEL:-}' HOST_CLAUDE='${HOST_CLAUDE:-}' differ from Step 1's MODEL='$_M_MODEL' HOST_CLAUDE='$_M_HOST' (\$WORK_DIR/.mode) — substitute the same values as Step 1; do not launch" >&2; exit 1; }
fi
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
  SKILL_BASE="$PLUGIN_ROOT/skills/ext-claude-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"
SKILL_DIR="$SKILL_BASE"
WATCHDOG="$SKILL_BASE/../shared/watchdog.sh"
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR")

if [ "${HOST_CLAUDE:-}" = "1" ]; then
    # Skip export / source ENV_FILE. Source host-claude-env.sh instead. Timeouts
    # from get-runtime JSON, not from CLAUDE_MESH_TIMEOUT_* (those come from export).
    # shellcheck source=/dev/null
    . "$SKILL_DIR/host-claude-env.sh"
    # rc=2 is "no config.yaml at all": the official CLI needs no provider section, so a
    # standalone claude-executor / claude-code-reviewer run gets the documented defaults and a
    # WARN naming the file the loader looked for. rc=1 (a file that exists and does not validate)
    # still STOPs — that is a user-owned config to fix, never to guess around.
    RT_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
    RT_RC=0; RUNTIME=$("$LOADER" get-runtime 2>"$RT_ERR") || RT_RC=$?
    if [ "$RT_RC" -eq 2 ]; then
        echo "WARN: no config.yaml at $("$LOADER" config-path) — HOST_CLAUDE uses default timeouts single=1800s stall=600s global=3600s retries=2" >&2
        RUNTIME='{"timeouts":{"single_run_sec":1800,"stall_sec":600,"global_sec":3600,"max_retries":2}}'
    elif [ "$RT_RC" -ne 0 ]; then
        echo "STOP: config-loader get-runtime failed — surface the error verbatim; do NOT edit config.yaml (user-owned):" >&2; cat "$RT_ERR" >&2; rm -f "$RT_ERR"; exit 1
    fi
    rm -f "$RT_ERR"
    SINGLE_RUN=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.single_run_sec')
    STALL=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.stall_sec')
    GLOBAL=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.global_sec')
    MAX_RETRIES=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.max_retries')
    echo "=== Ext-Claude Exec (HOST_CLAUDE supervised) ==="
    echo "Work dir: $WORK_DIR"
    echo "Model:    ${MODEL:-<CLI default>}"
    echo "Timeouts: single=${SINGLE_RUN}s stall=${STALL}s global=${GLOBAL}s retries=$MAX_RETRIES"
else
    # Resolve env via loader tmpfile (CONCERN-1)
    ENV_FILE=$("$LOADER" export "$MODEL") || { echo "STOP: config-loader failed — surface the error verbatim; do NOT edit config.yaml (user-owned)" >&2; exit 1; }
    trap 'rm -f "$ENV_FILE"' EXIT
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    rm -f "$ENV_FILE"
    trap - EXIT

    # Timeouts already in env from cmd_export (CLAUDE_MESH_TIMEOUT_*); use those directly
    # instead of re-reading yaml here — avoids a second config-load and stays consistent with
    # default mode.
    SINGLE_RUN="${CLAUDE_MESH_TIMEOUT_SINGLE_RUN_SEC:-1800}"
    STALL="${CLAUDE_MESH_TIMEOUT_STALL_SEC:-600}"
    GLOBAL="${CLAUDE_MESH_TIMEOUT_GLOBAL_SEC:-3600}"
    MAX_RETRIES="${CLAUDE_MESH_TIMEOUT_MAX_RETRIES:-2}"

    echo "=== Ext-Claude Exec (supervised) ==="
    echo "Work dir: $WORK_DIR"
    echo "Model:    $MODEL ($ANTHROPIC_MODEL)"
    echo "Timeouts: single=${SINGLE_RUN}s stall=${STALL}s global=${GLOBAL}s retries=$MAX_RETRIES"
fi
echo ""
unset CLAUDECODE

# `--permission-mode bypassPermissions` carries the same reasoning as in default mode above
# (no one can answer a permission prompt under -p, so the reviewer is silently confined to its
# cwd) — and it must be on BOTH paths. Orchestrated runs (`/mesh-design-review`) always take
# this supervised branch, so a flag added only to the default pipeline above would fix the
# one-off interactive run and leave every actual review confined. The flag cannot be moved
# into a comment inside the `env` block below: the block is one continued line.
# HOST_CLAUDE=1: do not pass --model when MODEL is empty. Same watchdog wrapper as the provider path.
WATCHDOG_RC=0
if [ "${HOST_CLAUDE:-}" = "1" ] && [ -n "$MODEL" ]; then
{ env \
    WORK_DIR="$WORK_DIR" \
    STDIN_FILE="$WORK_DIR/prompt.md" \
    MAX_RETRIES="$MAX_RETRIES" \
    HARD_ZERO_TIMEOUT="$STALL" \
    GLOBAL_TIMEOUT="$GLOBAL" \
    STREAM_FILE_NAME=raw.jsonl \
    "$WATCHDOG" -- \
      timeout "$SINGLE_RUN" stdbuf -oL -eL claude -p --model "$MODEL" --permission-mode bypassPermissions --output-format stream-json \
  || WATCHDOG_RC=$?; }
else
{ env \
    WORK_DIR="$WORK_DIR" \
    STDIN_FILE="$WORK_DIR/prompt.md" \
    MAX_RETRIES="$MAX_RETRIES" \
    HARD_ZERO_TIMEOUT="$STALL" \
    GLOBAL_TIMEOUT="$GLOBAL" \
    STREAM_FILE_NAME=raw.jsonl \
    "$WATCHDOG" -- \
      timeout "$SINGLE_RUN" stdbuf -oL -eL claude -p --permission-mode bypassPermissions --output-format stream-json \
  || WATCHDOG_RC=$?; }
fi

# Watchdog writes each attempt's artefacts under $WORK_DIR/attempt-N/ and makes
# $WORK_DIR/final a SYMLINK to the winning attempt (watchdog.sh: `ln -sfn attempt-N final`).
# Branch on WATCHDOG_RC exactly like the legacy ccs-exec/ollama-exec supervised blocks:
#   rc=0 → copy the winning attempt's artefacts up, extract, report, empty-output post-check
#   rc=2 → watchdog bailed (retries exhausted / global timeout): surface watchdog.exit
#          diagnostics + per-attempt tails, then exit 2. Do NOT run the exit-4 path here —
#          on a bail `final` points at a partial attempt with an empty output.txt, so the
#          exit-4 check would fire first and mask the bail (exit 4 instead of 2, diagnostics lost).
#   else → watchdog internal error: propagate rc.
echo ""
echo "=== Watchdog result (rc=$WATCHDOG_RC) ==="
if [ "$WATCHDOG_RC" -eq 0 ]; then
  # Copy the winning attempt's files up to $WORK_DIR root so the rest of the pipeline
  # behaves like default mode. NOTE: no log.jsonl — that file is produced by
  # progress-monitor.sh (default mode only); supervised mode has raw.jsonl + stderr.txt.
  if [ -d "$WORK_DIR/final" ]; then
    for f in raw.jsonl stderr.txt; do
      [ -f "$WORK_DIR/final/$f" ] && cp "$WORK_DIR/final/$f" "$WORK_DIR/$f"
    done
  fi

  # Extract output.txt + raw.json from raw.jsonl via shared script (same script used by
  # default mode → DRY, eliminates the 80-line duplicate that legacy ollama-exec and
  # ccs-exec carried).
  python3 "$SKILL_BASE/../shared/extract-result.py" "$WORK_DIR" \
    || { echo "WARN: extract-result.py rc=$?" >&2; }

  echo ""
  echo "=== Generating report ==="
  # Supervised mode has no log.jsonl; feed raw.jsonl. shared/stream-json-report.sh detects the missing
  # timestamp prefix and synthesizes one — same call the legacy supervised blocks used.
  { "$SKILL_DIR/../shared/stream-json-report.sh" "$WORK_DIR/raw.jsonl" "$WORK_DIR/report.md" "$MODEL" "" "$TASK_NAME" \
      || echo "WARN: shared/stream-json-report.sh failed" >&2 ; } || true

  # Diagnostics: empty output despite a non-empty stream is a recoverable signal — fail loudly.
  if [ ! -s "$WORK_DIR/output.txt" ] && [ -s "$WORK_DIR/raw.jsonl" ]; then
    echo "ERROR: output.txt empty but raw.jsonl has data" >&2
    [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
    echo "--- raw.jsonl tail ---" >&2; tail -5 "$WORK_DIR/raw.jsonl" >&2
    exit 4
  fi
elif [ "$WATCHDOG_RC" -eq 2 ]; then
  # Watchdog bailed: retries exhausted or global timeout. Surface the structured
  # diagnostics watchdog.sh wrote to watchdog.exit (reason/attempts/elapsed/last_attempt_dir)
  # plus per-attempt tails, so the caller sees WHY it failed instead of a bare empty output.
  echo "## Watchdog Diagnostics"
  if [ -f "$WORK_DIR/watchdog.exit" ]; then
    jq -r '"- Attempts: \(.attempts)\n- Reason: \(.reason)\n- Elapsed: \(.elapsed_sec)s\n- Last attempt: \(.last_attempt_dir)"' \
      "$WORK_DIR/watchdog.exit" 2>/dev/null || cat "$WORK_DIR/watchdog.exit"
  fi
  echo ""
  echo "=== PER-ATTEMPT TAILS ==="
  for a in "$WORK_DIR"/attempt-*; do
    [ -d "$a" ] || continue
    echo "-- $a --"; tail -20 "$a/raw.jsonl" 2>/dev/null || true
    [ -s "$a/stderr.txt" ] && { echo "-- $a/stderr --"; tail -20 "$a/stderr.txt" || true; }
    echo ""
  done
  exit 2
else
  echo "WARN: watchdog internal error (rc=$WATCHDOG_RC)" >&2
  exit "$WATCHDOG_RC"
fi
```

The supervised block mirrors default mode (Step 3 above) but uses `watchdog.sh` instead of a single `claude | progress-monitor.sh` pipeline. Result extraction is asymmetric (iter-2 CRITICAL-3): **default mode** keeps `progress-monitor.sh` (battle-tested, streams progress lines live to stdout while extracting from `type=result` events). **Supervised mode** uses `shared/extract-result.py` because watchdog produces per-attempt dirs (`attempt-N/raw.jsonl`, with `final` a symlink to the winning attempt) — that layout doesn't fit progress-monitor.sh's stdin-pipe assumption. The Python extractor reads `type=result` first (matching progress-monitor.sh), then assistant-message text, and finally — if neither exists — surfaces an `error` event as `API Error: <msg>` (parity with the legacy ccs/ollama extractor). The supervised tail branches on the watchdog exit code: `rc=0` copies the winning attempt up and runs extraction + `shared/stream-json-report.sh` from `raw.jsonl`; `rc=2` (watchdog bail) prints the `watchdog.exit` diagnostics + per-attempt tails and exits 2 (no exit-4 masking); any other code is propagated.

### Step 3: Handle Errors

```bash
# Task 2.5: data dir self-discovered by loader (CLAUDE_PLUGIN_DATA empty in skill Bash).
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
  SKILL_BASE="$PLUGIN_ROOT/skills/ext-claude-exec"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"
PLUGIN_DATA="$("$LOADER" data-dir)"
HOST_CLAUDE="{HOST_CLAUDE}"
if [ "${HOST_CLAUDE:-}" = "1" ]; then
    # HOST_CLAUDE run dirs are depth 2: runs/claude/<alias-or-_default>/<ts>-<task>
    LATEST=$(find "$PLUGIN_DATA/runs/claude" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | xargs -I{} stat -c '%Y {}' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
else
    # iter-3 CONCERN-3: provider run dirs are depth 3 (provider/short/run)
    LATEST=$(find "$PLUGIN_DATA/runs/ext-claude" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | xargs -I{} stat -c '%Y {}' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
fi
[ -n "$LATEST" ] && { echo "Latest run: $LATEST"; ls -la "$LATEST"; }
```

**Return to caller:** WORK_DIR path and the contents of `output.txt`.

## Options Explained

| Flag | Purpose |
|------|---------|
| `-p` | Headless (print) mode — no interactive session, prompt arrives on stdin |
| `--model <alias>` | HOST_CLAUDE=1 only, and only when MODEL is non-empty. Empty catalog → omit `--model` (CLI default). Provider path never passes `--model`; it sets `ANTHROPIC_MODEL` via export instead. |
| `--permission-mode bypassPermissions` | Skip every permission check, **including the confinement to the launch directory**. Not optional: under `-p` nobody can answer a permission prompt, so without it every access outside the cwd is auto-denied and the reviewer silently loses the sibling repositories it needs to check an API signature against real source — the review degrades to guesswork instead of failing. `--add-dir` is NOT needed alongside it (the bypass lifts the directory confinement too). Parity with codex `--dangerously-bypass-approvals-and-sandbox` and gemini `--approval-mode yolo`; `--dangerously-skip-permissions` was measured equivalent and is spelled this way to match the mode vocabulary the other engines use. |
| `--output-format stream-json` | Emit JSONL events, consumed by `progress-monitor.sh` (default mode), `extract-result.py` (supervised) and `shared/stream-json-report.sh` (BOTH modes — default renders from `log.jsonl`, supervised from `raw.jsonl`) |
| `timeout $SINGLE_RUN` | Per-run limit from the `runtime` timeouts in config.yaml (default 1800s). HOST_CLAUDE=1 reads them via `get-runtime` JSON, not from export. |

> If `--add-dir` is ever added here, note it takes a **variadic** value (`--add-dir <directories...>`)
> and must not sit directly before a positional prompt — it swallows the prompt and the CLI exits
> with `Input must be provided either through stdin or as a prompt argument`. Both invocations above
> feed the prompt on **stdin**, which is immune to that.

## Error Recovery

| Error | Solution |
|-------|----------|
| `claude: command not found` | Install Claude CLI |
| HOST_CLAUDE=1 unauthenticated / STALLED | `claude login` — do not paste a token into yaml |
| `config.yaml not found` | Copy from plugin's `config.example.yaml` |
| `yq not found` | Install either flavor: `pipx install yq` (Python-yq) or `apt install yq` / `brew install yq` (Go-yq v4+) |
| `models[X] references missing provider` | Add missing provider to `providers:` in config |
| Token precheck failed (HTTP 401/403) | Update `token:` in `providers[X]` |
| Ollama daemon unreachable | `ollama serve` / `systemctl start ollama` |
| Ollama auth failed | `ollama signin` |
| The run's `raw.jsonl` result event carries a non-empty `permission_denials` | The CLI refused that many tool calls, so the model worked without the files it tried to open — the invocation that ran lacked `--permission-mode bypassPermissions` (an installed plugin picks it up only through a release). Report it; do not edit plugin files to work around it. `shared/verify-delegation.sh` turns the same field into a `DEGRADED` verdict for the orchestrator. |

## Checklist

- [ ] Pre-flight checks passed
- [ ] Provider path: config-loader.sh exported env successfully; token/daemon precheck OK (by kind)
- [ ] HOST_CLAUDE=1: skipped export, sourced `host-claude-env.sh`, timeouts from `get-runtime`
- [ ] Prompt saved to `prompt.md`; HOST_CLAUDE=1 work dir is `runs/claude/<alias>/` (or `_default`)
- [ ] `claude -p` executed (default or supervised); HOST_CLAUDE=1 passed `--model` only when MODEL is set
- [ ] `output.txt` extracted
- [ ] `report.md` generated
