#!/bin/bash
# Hook UserPromptSubmit: inject git context once per session.
# Stdout content is appended to the user prompt by Claude Code.
#
# Triggers on the first prompt only (per session); subsequent prompts skip
# silently so we don't spam the context with redundant status. The injection
# saves a handful of reactive `Bash(git status)` / `Bash(git log)` calls when
# the model wants to know where it is.
#
# Verbosity controlled by env CLAUDE_GIT_CONTEXT_LEVEL:
#   off      → no injection at all
#   minimal  → branch only
#   default  → branch + status (capped 20 files) + 3 recent commits   [default]
#   verbose  → default + `git diff --stat` of uncommitted changes

set -e

LEVEL="${CLAUDE_GIT_CONTEXT_LEVEL:-default}"
[ "$LEVEL" = "off" ] && exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // "/project"')

# Skip if no git repo
[ -d "$CWD/.git" ] || { [ -d /project/.git ] && CWD=/project; } || exit 0
[ -d "$CWD/.git" ] || exit 0

# Per-session flag — only emit on first prompt
FLAG_DIR="/tmp/.claude-git-context"
mkdir -p "$FLAG_DIR" 2>/dev/null || true
FLAG="$FLAG_DIR/${SESSION_ID:-default}"
[ -f "$FLAG" ] && exit 0
touch "$FLAG"

cd "$CWD"

# Branch (cheap, no fork to git for the common case)
BRANCH=""
if [ -f .git/HEAD ]; then
    _head=$(cat .git/HEAD 2>/dev/null)
    case "$_head" in
        "ref: refs/heads/"*) BRANCH="${_head#ref: refs/heads/}" ;;
        *) BRANCH="${_head:0:12} (detached)" ;;
    esac
fi

# Build the injection. Wrap in tags so the model can recognise it as ambient
# context rather than a request.
{
    echo "<git-context>"
    [ -n "$BRANCH" ] && echo "branch: $BRANCH"

    if [ "$LEVEL" != "minimal" ]; then
        STATUS=$(git status --porcelain=v1 2>/dev/null | head -20)
        N_CHANGED=$(printf '%s\n' "$STATUS" | sed '/^$/d' | wc -l)
        if [ "$N_CHANGED" -gt 0 ]; then
            echo "changes: $N_CHANGED file(s)"
            printf '%s\n' "$STATUS"
        else
            echo "changes: working tree clean"
        fi

        LOG=$(git log -3 --oneline --no-decorate 2>/dev/null || true)
        if [ -n "$LOG" ]; then
            echo "recent commits:"
            printf '%s\n' "$LOG"
        fi
    fi

    if [ "$LEVEL" = "verbose" ]; then
        DIFFSTAT=$(git diff --stat HEAD 2>/dev/null | tail -20)
        if [ -n "$DIFFSTAT" ]; then
            echo "diff stat:"
            printf '%s\n' "$DIFFSTAT"
        fi
    fi

    echo "</git-context>"
}
