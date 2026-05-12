#!/bin/bash
# Statusline rendered after each model response. Keep it cheap: every external
# command shows up as latency in the UI. Budget: < 50ms total.
# Force POSIX numeric locale so `printf '%.2f' 0.42` works under fr_BE.UTF-8
# (which expects "0,42" otherwise and errors out). LC_ALL overrides LC_NUMERIC, so
# unset LC_ALL — the statusline only formats numbers and ASCII labels.
unset LC_ALL
export LC_NUMERIC=C

# Single jq pass extracts everything we need as TSV. Each jq invocation costs
# ~5-10ms (Node.js-free, but still a fork+exec + JSON parse), so collapsing 8
# calls to 1 saves 35-70ms per model turn. Trailing "END" sentinel guarantees
# each field has a defined column.
{ IFS=$'\t' read -r MODEL COST CTX_RAW CWD FIVE_H FIVE_RESET WEEK _SENTINEL; } < <(
    jq -r '[
        .model.display_name // "?",
        (.cost.total_cost_usd // 0 | tostring),
        (.context_window.used_percentage // 0 | tostring),
        .workspace.current_dir // .cwd // "/project",
        (.rate_limits.five_hour.used_percentage // "" | tostring),
        (.rate_limits.five_hour.resets_at // 0 | tostring),
        (.rate_limits.seven_day.used_percentage // "" | tostring),
        "END"
    ] | @tsv'
)
CTX="${CTX_RAW%%.*}"

# Claude Code version: read the symlink target instead of spawning `claude --version`
# (which boots Node.js -> ~200ms). The versions/<x.y.z> naming makes this trivial.
CC_VERSION=""
if _link=$(readlink /home/claude/.local/bin/claude 2>/dev/null); then
    CC_VERSION="${_link##*/}"
fi

# Git branch: read .git/HEAD directly (no `git` fork). Detached HEAD -> short SHA.
GIT_BRANCH=""
_head=""
for _dir in "$CWD/.git" /project/.git; do
    if [ -f "$_dir/HEAD" ]; then
        _head=$(cat "$_dir/HEAD" 2>/dev/null)
        break
    fi
done
if [ -n "$_head" ]; then
    case "$_head" in
        "ref: refs/heads/"*) GIT_BRANCH="${_head#ref: refs/heads/}" ;;
        *) GIT_BRANCH="${_head:0:7}" ;;
    esac
fi

# Count active MCP servers (cheap, file is small)
MCP_COUNT=$(jq -r '.mcpServers | length // 0' /home/claude/.claude.json 2>/dev/null)

PARTS=""

if [ -n "$FIVE_H" ]; then
    MINS_LEFT=$(( (FIVE_RESET - $(date +%s)) / 60 ))
    if [ "$MINS_LEFT" -gt 60 ]; then
        RESET_STR="$((MINS_LEFT / 60))h$((MINS_LEFT % 60))m"
    else
        RESET_STR="${MINS_LEFT}m"
    fi
    PARTS="5h: $(printf '%.0f' "$FIVE_H")% (reset ${RESET_STR})"
fi

if [ -n "$WEEK" ]; then
    PARTS="${PARTS:+$PARTS | }7d: $(printf '%.0f' "$WEEK")%"
fi

PARTS="${PARTS:+$PARTS | }ctx: ${CTX}%"
PARTS="$PARTS | \$$(printf '%.2f' "$COST")"
PARTS="$PARTS | $MODEL"
[ -n "$CC_VERSION" ] && PARTS="$PARTS | cc $CC_VERSION"
[ -n "$GIT_BRANCH" ] && PARTS="$PARTS | git:$GIT_BRANCH"
[ -n "$MCP_COUNT" ] && [ "$MCP_COUNT" -gt 0 ] && PARTS="$PARTS | mcp:$MCP_COUNT"

echo "$PARTS"
