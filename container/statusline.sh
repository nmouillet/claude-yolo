#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
CTX=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

# Rate limits (only present for Pro/Max subscribers)
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVE_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // 0')
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

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

echo "${PARTS:+$PARTS | }ctx: ${CTX}% | \$$(printf '%.2f' "$COST") | $MODEL"
