#!/usr/bin/env bash
# Contract for the mesh-exec wrapper agents and exec skills.
#
# claude-executor dispatches official `claude -p` via ext-claude-exec HOST_CLAUDE=1:
# catalog aliases (opus, fable), run dirs under runs/claude/. The reviewer half of
# this file moved to the mesh-review plugin together with the reviewers.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS_DIR/../../.." && pwd)"

FAIL=0
PASS=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"
    fi
}

assert_ge() {
    local desc="$1" min="$2" actual="$3"
    case "$actual" in
        ''|*[!0-9]*)
            FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected a count >= $min, got '$actual' — did the file move?)"
            return ;;
    esac
    if [ "$actual" -ge "$min" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc ($actual >= $min)"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected >= $min, got $actual)"
    fi
}

echo "=== Test: claude CLI executor ==="
assert_eq "executor agent exists" "1" "$([ -f "$REPO/agents/claude-executor.md" ] && echo 1 || echo 0)"
assert_eq "executor does not STOP when MODEL is omitted" "0" \
    "$(grep -c 'ERROR: MODEL parameter is required on first line' "$REPO/agents/claude-executor.md")"
assert_ge "executor still invokes skill when MODEL omitted" "1" \
    "$(grep -c 'If the first line is not `MODEL=`, still invoke the skill' "$REPO/agents/claude-executor.md")"

echo ""
echo "=== Test: wrapper dual-path invoke + Grok wait ==="
AGENTS="$REPO/agents"
# The five executor wrappers; the reviewer wrappers are checked in mesh-review.
WRAPPERS="codex-executor.md gemini-executor.md grok-executor.md ext-claude-executor.md claude-executor.md"
forbid=0
for f in $WRAPPERS; do
    grep -q 'Do NOT read SKILL.md' "$AGENTS/$f" && forbid=$((forbid+1))
done
assert_eq "no wrapper still forbids reading SKILL.md" "0" "$forbid"
missing=0
for f in $WRAPPERS; do
    grep -q 'If this host has no Skill tool' "$AGENTS/$f" || missing=$((missing+1))
    grep -q 'do not end the turn while the CLI is alive' "$AGENTS/$f" || missing=$((missing+1))
done
assert_eq "every wrapper has dual invoke + Grok wait" "0" "$missing"

echo ""
echo "=== Test: empty-SKILL_BASE else-branch is in the fence ==="
# Prose telling the LLM to rewrite is not enough: the executable fence must
# contain the find fallback. Every resolve-plugin-root.sh call via $SKILL_BASE
# must sit in `if [ -n "$SKILL_BASE" ]`.
SKILLS_WITH_RESOLVER="ext-claude-exec codex-exec gemini-exec grok-exec"
mismatch=0
for s in $SKILLS_WITH_RESOLVER; do
    f="$REPO/skills/$s/SKILL.md"
    n_resolve="$(grep -c 'bash "$SKILL_BASE/../shared/resolve-plugin-root.sh"' "$f" || true)"
    n_if="$(grep -c 'if \[ -n "\$SKILL_BASE" \]; then' "$f" || true)"
    n_find="$(grep -c 'mesh-exec\*/skills/shared/config-loader.sh' "$f" || true)"
    n_installed="$(grep -c 'installed-plugins' "$f" || true)"
    if [ "$n_resolve" != "$n_if" ] || [ "$n_find" -ne $((3 * n_if)) ]; then
        mismatch=$((mismatch+1))
        echo "    mismatch $s: resolve=$n_resolve if=$n_if find=$n_find"
    fi
    if [ "$n_installed" -lt "$n_if" ]; then
        mismatch=$((mismatch+1))
        echo "    mismatch $s: installed-plugins=$n_installed if=$n_if"
    fi
done
assert_eq "every resolver fence has empty-SKILL_BASE else-branch" "0" "$mismatch"

echo ""
echo "=== Test: HOST_CLAUDE claude -p uses --model, not -m ==="
# Measured 2026-09-01 on Claude Code 2.1.257: `claude -p -m fable` →
# `error: unknown option '-m'`. The long option is `--model`.
n_old="$(grep -c 'claude -p -m' "$REPO/skills/ext-claude-exec/SKILL.md" || true)"
n_new="$(grep -c 'claude -p --model' "$REPO/skills/ext-claude-exec/SKILL.md" || true)"
assert_eq "no HOST_CLAUDE invocation still passes -m" "0" "$n_old"
assert_ge "HOST_CLAUDE invocations pass --model" "2" "$n_new"

echo ""
echo "=== Test: HOST_CLAUDE MODEL charset matches watch-runs / verify-delegation ==="
# claude.models admits :/@ via IDENT_RE; the watcher and guard do not. A HOST_CLAUDE
# alias with those characters created a run dir the guard then refused as usage error.
assert_ge "HOST_CLAUDE path rejects :/@ before mkdir" "1" \
    "$(grep -cE 'A-Za-z0-9\]\[A-Za-z0-9\._-\]\*' "$REPO/skills/ext-claude-exec/SKILL.md")"
assert_ge "session stamp falls back to GROK_SESSION_ID" "1" \
    "$(grep -c 'GROK_SESSION_ID' "$REPO/skills/ext-claude-exec/SKILL.md")"


echo ""
echo "=== Test: ext-claude-exec launch fences re-check MODEL / HOST_CLAUDE against Step 1 ==="
# MODEL and HOST_CLAUDE are substituted into every fence separately. Step 1 writes the pair it
# validated to $WORK_DIR/.mode; both Step 2 launch fences must read it back and STOP on a
# mismatch before the CLI starts (decided 2026-09-02). One write, two checks.
EXEC_SKILL="$REPO/skills/ext-claude-exec/SKILL.md"
assert_eq "Step 1 writes .mode once" "1" "$(grep -c '> "\$WORK_DIR/.mode"' "$EXEC_SKILL")"
assert_eq "both launch fences read .mode" "2" "$(grep -c 'if \[ -f "\$WORK_DIR/.mode" \]; then' "$EXEC_SKILL")"

echo ""
echo "=== Test: resolver fences keep the ROOT ORDER, and the prose agrees ==="
# 0c851d0 moved installed-plugins to the front of every fence and left the prose in all ten
# skills saying `.claude` first; the counts above never looked at ORDER or at prose, so the
# drift was invisible until an external review read both. Every fence holds exactly one find
# per root, so pairing the i-th line of each root by position checks every fence: the
# installed-plugins line must precede the .claude line, which must precede the .grok line.
order_bad=0
for s in $SKILLS_WITH_RESOLVER; do
    f="$REPO/skills/$s/SKILL.md"
    # Byte offsets, not line numbers: the review→exec Read paragraph carries all three finds
    # on ONE line, and a line-number comparison reads that correct order as a tie.
    inst="$(grep -boF 'find "$HOME"/.grok/installed-plugins -path' "$f" | cut -d: -f1)"
    cc="$(grep -boF 'find "$HOME"/.claude/plugins -path' "$f" | cut -d: -f1)"
    gp="$(grep -boF 'find "$HOME"/.grok/plugins -path' "$f" | cut -d: -f1)"
    n_i="$(printf '%s\n' "$inst" | grep -c .)"; n_c="$(printf '%s\n' "$cc" | grep -c .)"; n_g="$(printf '%s\n' "$gp" | grep -c .)"
    if [ "$n_i" -eq 0 ] || [ "$n_i" != "$n_c" ] || [ "$n_c" != "$n_g" ]; then
        order_bad=$((order_bad+1)); echo "    $s: find counts installed=$n_i claude=$n_c grok=$n_g"; continue
    fi
    if ! paste <(printf '%s\n' "$inst") <(printf '%s\n' "$cc") <(printf '%s\n' "$gp") | while IFS=$'\t' read -r a b c; do
            [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] || { echo "    $s: fence order wrong at byte offsets $a/$b/$c"; exit 1; }
        done; then
        order_bad=$((order_bad+1))
    fi
    [ "$(grep -cF 'searches `$HOME/.grok/installed-plugins` first' "$f")" = 1 ] \
        || { order_bad=$((order_bad+1)); echo "    $s: prose does not say installed-plugins first (exactly once)"; }
    [ "$(grep -cF 'searches `$HOME/.claude/plugins` first' "$f")" = 0 ] \
        || { order_bad=$((order_bad+1)); echo "    $s: stale prose says .claude first"; }
done
assert_eq "every skill fence searches installed-plugins, .claude, .grok in that order, and the prose says so" "0" "$order_bad"

echo ""
echo "=== Test: missing installed-plugins does not abort a set -euo pipefail skill fence ==="
# ext-claude-exec Step 1/2 fences are `set -euo pipefail`. The last `||` arm is the
# installed-plugins find; GNU find returns 1 on a missing dir, pipefail promotes that
# to the assignment, and `set -e` then exits before the .claude fallback — silent
# death of every wrapper on marketplace Grok (no grok plugin install). Extract the
# live three-line chain so this assertion cannot drift from the fence.
ELSE_CHAIN="$(awk '/find "\$HOME"\/\.grok\/installed-plugins/ {print; getline; print; getline; print; exit}' \
    "$REPO/skills/ext-claude-exec/SKILL.md")"
assert_eq "extracted a 3-line else-chain from ext-claude-exec" "3" \
    "$(printf '%s\n' "$ELSE_CHAIN" | grep -c .)"
TDIR=$(mktemp -d)
mkdir -p "$TDIR/home/.claude/plugins/cache/zinin/mesh-exec/0.12.0/skills/shared"
: > "$TDIR/home/.claude/plugins/cache/zinin/mesh-exec/0.12.0/skills/shared/config-loader.sh"
GOT=$(HOME="$TDIR/home" GROK_SESSION_ID="grok-session-1" bash -c 'set -euo pipefail
_LOADER=""
'"$ELSE_CHAIN"'
printf %s "$_LOADER"'); RC=$?
assert_eq "skill else-chain ran cleanly under set -e" "0" "$RC"
assert_eq "skill else-chain falls through to the Claude cache" \
    "$TDIR/home/.claude/plugins/cache/zinin/mesh-exec/0.12.0/skills/shared/config-loader.sh" "$GOT"
rm -rf "$TDIR"
# Review Focus 2 on the Grok path: claude-mesh copies carry the same marker in all three roots.
OHOME=$(mktemp -d)
for p in .grok/installed-plugins/claude-mesh-aabbccdd .claude/plugins/cache/zinin/claude-mesh/9.9.9 .grok/plugins/cache/zinin/claude-mesh/9.9.9; do
    mkdir -p "$OHOME/$p/skills/shared"; : > "$OHOME/$p/skills/shared/config-loader.sh"
done
GOT=$(HOME="$OHOME" GROK_SESSION_ID="grok-session-1" bash -c 'set -euo pipefail
_LOADER=""
'"$ELSE_CHAIN"'
printf %s "$_LOADER"')
assert_eq "skill else-chain never takes a claude-mesh copy" "" "$GOT"
rm -rf "$OHOME"

echo ""
echo "=== Test: every loader-find assignment is guarded against find rc=1 ==="
# The three roots are each a `find | sort | tail` assignment. Any one of them on a
# missing directory is the same set -e hole. `|| true` after the assignment is the
# contract; a new fence without it must fail this count.
unprotected=0
while IFS= read -r line; do
    printf '%s\n' "$line" | grep -q '|| true[[:space:]]*$' && continue
    unprotected=$((unprotected+1))
    echo "    unguarded: $line"
done < <(grep -h 'find "$HOME"/.*/config-loader.sh' \
    "$REPO"/skills/*/SKILL.md \
    "$REPO"/skills/shared/resolve-plugin-root.sh || true)
assert_eq "every loader find assignment ends with || true" "0" "$unprotected"

echo ""
echo "=== Test: codex-/gemini-/grok-exec soft gates when config.yaml is missing ==="
# Loader rc=2 is "no config.yaml at all". The gate names the file through config-path, passes
# the loader's own lines on — with the old claude-mesh config still in place they carry the
# command that moves it — and the run continues on defaults (rc 0). A config without the
# engine's block, a configured block and any other loader failure keep their old outcome and
# text. Each gate is extracted from its SKILL.md and executed: against the real loader in a
# scratch HOME for rc=2, against a stub loader for the rest.
GHOME=$(mktemp -d)
OLDCFG="$GHOME/.claude/plugins/data/claude-mesh-zinin/config.yaml"
NEWCFG="$GHOME/.config/mesh/config.yaml"
mkdir -p "${OLDCFG%/*}"; printf 'providers: {}\n' > "$OLDCFG"
STUB="$GHOME/stub-loader.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
case "${1:-}" in
    config-path) echo "/stub/config.yaml" ;;
    get-flag)
        [ "${STUB_RC:-0}" = 0 ] || { echo "config-loader: stub failure" >&2; exit "$STUB_RC"; }
        echo "${STUB_FLAG:-1}" ;;
esac
STUBEOF
chmod +x "$STUB"
for e in codex gemini grok; do
    GATE="$(awk '/^# Soft gate:/ {s=1} s && /^if \[ -x "\$LOADER" \]; then$/ {g=1} g {print} g && /^fi$/ {exit}' \
        "$REPO/skills/$e-exec/SKILL.md")"
    OUT=$(env -u MESH_CONFIG -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$GHOME" \
        LOADER="$REPO/skills/shared/config-loader.sh" bash -c "$GATE" 2>&1); RC=$?
    assert_eq "$e-exec: no config.yaml -> a WARN naming its path, and the run goes on" \
        "0|WARN: no config.yaml at $NEWCFG — continuing on defaults. It is user-owned; agents never create or edit it. The loader says:" \
        "$RC|$(printf '%s\n' "$OUT" | head -1)"
    assert_eq "$e-exec: …followed by the loader's move command" "1" \
        "$(printf '%s\n' "$OUT" | grep -cxF "  mkdir -p \"${NEWCFG%/*}\" && cp \"$OLDCFG\" \"$NEWCFG\" && chmod 600 \"$NEWCFG\"")"
    OUT=$(STUB_FLAG=0 LOADER="$STUB" bash -c "$GATE" 2>&1); RC=$?
    assert_eq "$e-exec: a config without the $e: block keeps the old WARN" \
        "0|WARN: $e: block not configured in config.yaml ($e uses its own auth — continuing)" "$RC|$OUT"
    OUT=$(STUB_FLAG=1 LOADER="$STUB" bash -c "$GATE" 2>&1); RC=$?
    if [ "$e" = grok ]; then WANT="0|"; else WANT="0|OK: has_$e configured"; fi
    assert_eq "$e-exec: a configured block passes as before" "$WANT" "$RC|$OUT"
    OUT=$(STUB_RC=1 LOADER="$STUB" bash -c "$GATE" 2>&1); RC=$?
    if [ "$e" = grok ]; then
        assert_eq "grok-exec: a grok: section that does not validate still STOPs" \
            "1|STOP: the grok: section in config.yaml does not validate — config.yaml is user-owned; agents never edit it. The loader says:" \
            "$RC|$(printf '%s\n' "$OUT" | head -1)"
    else
        assert_eq "$e-exec: any other loader failure keeps the old WARN" \
            "0|WARN: $e: block not configured in config.yaml ($e uses its own auth — continuing)" "$RC|$OUT"
    fi
done
rm -rf "$GHOME"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
