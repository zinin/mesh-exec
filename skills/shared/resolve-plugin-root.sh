#!/usr/bin/env bash
set -u
loader_at() { [ -f "$1/skills/shared/config-loader.sh" ]; }
if [ -n "${SKILL_BASE:-}" ]; then
    if loader_at "$SKILL_BASE"; then printf '%s\n' "$SKILL_BASE"; exit 0; fi
    # SKILL_BASE is the skill dir (…/skills/ext-claude-exec)
    parent="$(cd "$SKILL_BASE/../.." && pwd)"
    if loader_at "$parent"; then printf '%s\n' "$parent"; exit 0; fi
fi
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && loader_at "$CLAUDE_PLUGIN_ROOT"; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; exit 0
fi
if [ -n "${GROK_PLUGIN_ROOT:-}" ] && loader_at "$GROK_PLUGIN_ROOT"; then
    printf '%s\n' "$GROK_PLUGIN_ROOT"; exit 0
fi
# Unpublished Grok install (`grok plugin install <tree>`) copies the plugin to
# ~/.grok/installed-plugins/mesh-exec-<hash>. That path is what `grok inspect`
# loads. A stale Claude-compat cache under ~/.claude/plugins must not win: measured
# 2026-09-01, sort -V | tail -1 on the cache picked 0.12.0 and HOST_CLAUDE wrappers
# ran the old loader. Search installed-plugins first, then the two cache trees.
# Priority, not a cross-root sort: `sort -V` compares whole paths.
# installed-plugins is a GROK-SESSION root: bash inside Grok Build has GROK_SESSION_ID and
# Claude Code does not (measured 2026-09-01). A Claude Code session on a machine that also
# runs Grok smokes must not execute that snapshot — it falls behind the tree the moment a
# commit lands (decided 2026-09-02) — so without the variable the order is 0.12.0's.
found=""
[ -z "${GROK_SESSION_ID:-}" ] || found="$(find "$HOME"/.grok/installed-plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -n "$found" ] || found="$(find "$HOME"/.claude/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
[ -n "$found" ] || found="$(find "$HOME"/.grok/plugins -path '*mesh-exec*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
if [ -n "$found" ]; then
    printf '%s\n' "$(cd "$(dirname "$found")/../.." && pwd)"
    exit 0
fi
echo "resolve-plugin-root: mesh-exec plugin root not found" >&2
exit 1
