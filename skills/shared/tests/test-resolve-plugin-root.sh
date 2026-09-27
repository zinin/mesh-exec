#!/usr/bin/env bash
# Regression tests for skills/shared/resolve-plugin-root.sh.
#
# Every skill bash fence in the plugin now routes through this script, so its coverage
# floor has to be higher than the two happy-path branches it started with. The five
# branches, in the order the script tries them:
#
#   1. SKILL_BASE is itself a plugin root            (resolve-plugin-root.sh:4-5)
#   2. SKILL_BASE is a skill dir → walk up two       (:6-8)
#   3. CLAUDE_PLUGIN_ROOT                            (:10-12)
#   4. GROK_PLUGIN_ROOT — new in the host-aware work (:13-15)
#   5. find fallback (installed-plugins, .claude, .grok), then the not-found exit 1 (:22-30)
#
# Branch 4 is the whole reason the script exists on Grok Build, and branch 5's exit 1 is
# what stops a caller from resolving a PLUGIN_ROOT out of its current directory.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../resolve-plugin-root.sh"
REPO="$(cd "$TESTS_DIR/../../.." && pwd)"
FAIL=0; PASS=0
assert_eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS: $1"; else FAIL=$((FAIL+1)); echo "  FAIL: $1 (expected '$2', got '$3')"; fi; }

# 1. SKILL_BASE already IS the plugin root — returned as-is, no walking up.
GOT=$(SKILL_BASE="$REPO" "$SCRIPT")
assert_eq "SKILL_BASE=plugin root → returned unchanged" "$REPO" "$GOT"

# 2. SKILL_BASE is a skill dir — walk up two.
GOT=$(SKILL_BASE="$REPO/skills/ext-claude-exec" "$SCRIPT")
assert_eq "SKILL_BASE=skill dir → plugin root" "$REPO" "$GOT"

# 3. CLAUDE_PLUGIN_ROOT, consulted once SKILL_BASE yields nothing.
GOT=$(CLAUDE_PLUGIN_ROOT="$REPO" SKILL_BASE= "$SCRIPT")
assert_eq "CLAUDE_PLUGIN_ROOT wins when SKILL_BASE empty" "$REPO" "$GOT"

# 4. GROK_PLUGIN_ROOT — the Grok Build path, where SKILL_BASE is never printed.
GOT=$(GROK_PLUGIN_ROOT="$REPO" CLAUDE_PLUGIN_ROOT= SKILL_BASE= "$SCRIPT")
assert_eq "GROK_PLUGIN_ROOT used when SKILL_BASE and CLAUDE_PLUGIN_ROOT empty" "$REPO" "$GOT"

# 4b. A set-but-wrong env root does NOT win: loader_at must actually find the loader there.
EMPTY_DIR="$(mktemp -d)"
GOT=$(GROK_PLUGIN_ROOT="$EMPTY_DIR" CLAUDE_PLUGIN_ROOT="$EMPTY_DIR" SKILL_BASE="$REPO" "$SCRIPT")
assert_eq "env roots without a loader are skipped, SKILL_BASE still wins" "$REPO" "$GOT"

# 5. Nothing resolves → exit 1 with a message on stderr, NOT a path from the cwd.
#    HOME is pointed at an empty dir so the find fallback comes back empty too.
ERR="$(HOME="$EMPTY_DIR" GROK_PLUGIN_ROOT= CLAUDE_PLUGIN_ROOT= SKILL_BASE= "$SCRIPT" 2>&1 >/dev/null)"; RC=$?
assert_eq "nothing resolves → exit 1" "1" "$RC"
case "$ERR" in
    *"plugin root not found"*) PASS=$((PASS+1)); echo "  PASS: not-found message on stderr" ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: not-found message on stderr (got '$ERR')" ;;
esac
OUT="$(HOME="$EMPTY_DIR" GROK_PLUGIN_ROOT= CLAUDE_PLUGIN_ROOT= SKILL_BASE= "$SCRIPT" 2>/dev/null)"
assert_eq "nothing resolves → no path printed on stdout" "" "$OUT"

# 5b. The find fallback itself: a fake plugin tree under a scratch HOME is found.
FAKE_HOME="$(mktemp -d)"
FAKE_ROOT="$FAKE_HOME/.grok/plugins/cache/z/mesh-exec/9.9.9"
mkdir -p "$FAKE_ROOT/skills/shared"
touch "$FAKE_ROOT/skills/shared/config-loader.sh"
GOT=$(HOME="$FAKE_HOME" GROK_PLUGIN_ROOT= CLAUDE_PLUGIN_ROOT= SKILL_BASE= "$SCRIPT")
assert_eq "find fallback resolves a plugin tree under HOME" "$FAKE_ROOT" "$GOT"

# 5c. Root PRIORITY, not a cross-root version sort. With a copy in both trees, `.claude` wins
#     even when the `.grok` one has a higher version — a single `find` over both roots would
#     pick .grok whatever the versions, because sort -V compares whole paths and .claude <
#     .grok. That is the same silent mis-resolution the loader's original `head -1` caused.
BOTH_HOME="$(mktemp -d)"
mkdir -p "$BOTH_HOME/.claude/plugins/cache/z/mesh-exec/0.12.0/skills/shared" \
         "$BOTH_HOME/.grok/plugins/cache/z/mesh-exec/9.9.9/skills/shared"
touch "$BOTH_HOME/.claude/plugins/cache/z/mesh-exec/0.12.0/skills/shared/config-loader.sh" \
      "$BOTH_HOME/.grok/plugins/cache/z/mesh-exec/9.9.9/skills/shared/config-loader.sh"
GOT=$(HOME="$BOTH_HOME" GROK_PLUGIN_ROOT= CLAUDE_PLUGIN_ROOT= SKILL_BASE= "$SCRIPT")
assert_eq ".claude wins over a HIGHER-versioned .grok copy" \
    "$BOTH_HOME/.claude/plugins/cache/z/mesh-exec/0.12.0" "$GOT"
rm -rf "$BOTH_HOME/.claude"
GOT=$(HOME="$BOTH_HOME" GROK_PLUGIN_ROOT= CLAUDE_PLUGIN_ROOT= SKILL_BASE= "$SCRIPT")
assert_eq "…and .grok is used once .claude has nothing" \
    "$BOTH_HOME/.grok/plugins/cache/z/mesh-exec/9.9.9" "$GOT"
rm -rf "$BOTH_HOME"

# 5d. Unpublished Grok install (`~/.grok/installed-plugins/mesh-exec-<hash>`)
# wins over a stale Claude-compat cache. Measured 2026-09-01: both trees exist,
# find ~/.claude/plugins | sort -V | tail -1 picked 0.12.0, and HOST_CLAUDE
# wrappers ran the old loader. The snapshot is the copy grok inspect loaded.
INST_HOME="$(mktemp -d)"
mkdir -p "$INST_HOME/.claude/plugins/cache/z/mesh-exec/0.12.0/skills/shared" \
         "$INST_HOME/.grok/installed-plugins/mesh-exec-aabbccdd/skills/shared"
touch "$INST_HOME/.claude/plugins/cache/z/mesh-exec/0.12.0/skills/shared/config-loader.sh" \
      "$INST_HOME/.grok/installed-plugins/mesh-exec-aabbccdd/skills/shared/config-loader.sh"
GOT=$(HOME="$INST_HOME" GROK_PLUGIN_ROOT= CLAUDE_PLUGIN_ROOT= SKILL_BASE= GROK_SESSION_ID=grok-1 "$SCRIPT")
assert_eq "installed-plugins wins over a stale .claude cache (Grok session)" \
    "$INST_HOME/.grok/installed-plugins/mesh-exec-aabbccdd" "$GOT"
# 5e. …but only inside a Grok session. Without GROK_SESSION_ID — bash under Claude Code — the
#     same snapshot must NOT outrank the Claude cache: on a machine that runs both hosts it is
#     stale the moment a commit lands (decided 2026-09-02), and Claude Code keeps the 0.12.0 order.
GOT=$(HOME="$INST_HOME" GROK_PLUGIN_ROOT= CLAUDE_PLUGIN_ROOT= SKILL_BASE= GROK_SESSION_ID= "$SCRIPT")
assert_eq "no Grok session: .claude cache wins over installed-plugins" \
    "$INST_HOME/.claude/plugins/cache/z/mesh-exec/0.12.0" "$GOT"
rm -rf "$INST_HOME"

rm -rf "$EMPTY_DIR" "$FAKE_HOME"
# 6. A claude-mesh cache left from before the rename is not this plugin. It carries the same
#    config-loader.sh marker, so only the *mesh-exec* pattern keeps it out — and its path is
#    made to sort LAST, so a loosened pattern would pick it and fail here.
OLD_HOME="$(mktemp -d)"
mkdir -p "$OLD_HOME/.claude/plugins/cache/zz-old/claude-mesh/9.9.9/skills/shared" \
         "$OLD_HOME/.claude/plugins/cache/zinin/mesh-exec/0.16.0/skills/shared"
touch "$OLD_HOME/.claude/plugins/cache/zz-old/claude-mesh/9.9.9/skills/shared/config-loader.sh" \
      "$OLD_HOME/.claude/plugins/cache/zinin/mesh-exec/0.16.0/skills/shared/config-loader.sh"
GOT=$(HOME="$OLD_HOME" GROK_PLUGIN_ROOT= CLAUDE_PLUGIN_ROOT= SKILL_BASE= "$SCRIPT")
assert_eq "claude-mesh in the cache is ignored, even sorting last" "$OLD_HOME/.claude/plugins/cache/zinin/mesh-exec/0.16.0" "$GOT"
rm -rf "$OLD_HOME"
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
