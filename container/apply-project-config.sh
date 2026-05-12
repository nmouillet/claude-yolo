#!/bin/bash
# Applique une config par-projet aux fichiers Claude Code actifs.
#
# Lit la config depuis /home/claude/claude-yolo-config/projects.settings.json
# pour la clé HOST_PROJECT_PATH (passée en env var par le launcher).
#
# Patche en place :
#   - /home/claude/.claude.json    : filtre .mcpServers et .enabledPlugins
#   - /home/claude/.claude/settings.json : filtre .enabledPlugins, .hooks.PreToolUse (rtk),
#                                          met à jour .model, .effortLevel et .outputStyle
#   - /home/claude/.claude/skills/ : filtre les symlinks (overlay vers host-skills)
#
# Si aucune config trouvée, sort silencieusement (rien à appliquer).

set -e

PROJECTS_FILE="/home/claude/claude-yolo-config/projects.settings.json"
CLAUDE_JSON="/home/claude/.claude.json"
SETTINGS_JSON="/home/claude/.claude/settings.json"
SKILLS_DIR="/home/claude/.claude/skills"
KEY="${HOST_PROJECT_PATH:-}"

[ -z "$KEY" ] && exit 0
[ ! -f "$PROJECTS_FILE" ] && exit 0

# Lire l'entrée pour ce projet
project_cfg=$(jq --arg k "$KEY" '.projects[$k] // empty' "$PROJECTS_FILE" 2>/dev/null)
[ -z "$project_cfg" ] && exit 0

# Extraire les listes (arrays JSON) et scalaires
selected_plugins=$(echo "$project_cfg" | jq -c '.plugins // []')
selected_mcp=$(echo "$project_cfg" | jq -c '.mcp // []')
rtk_enabled=$(echo "$project_cfg" | jq -r '.hooks.rtk // true')
sel_model=$(echo "$project_cfg" | jq -r '.model // empty')
sel_effort=$(echo "$project_cfg" | jq -r '.effortLevel // empty')
sel_output_style=$(echo "$project_cfg" | jq -r '.outputStyle // empty')
# Skills filter: distinguer null (no preference = leave all on) vs explicit array.
skills_raw=$(echo "$project_cfg" | jq '.skills')

# ── 1. Filtrer .claude.json ──
if [ -f "$CLAUDE_JSON" ]; then
    tmp=$(mktemp)
    jq \
        --argjson plugins "$selected_plugins" \
        --argjson mcp "$selected_mcp" '
        # Plugins: keep enabledPlugins entries dont la clé est dans $plugins
        # (clé au format "name@marketplace")
        (.enabledPlugins // {}) as $ep
        | .enabledPlugins = (
            $ep | with_entries(select(.key as $k | $plugins | index($k)))
        )
        # MCP: keep mcpServers dont la clé est dans $mcp
        | (.mcpServers // {}) as $ms
        | .mcpServers = (
            $ms | with_entries(select(.key as $k | $mcp | index($k)))
        )
    ' "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"
fi

# ── 2. Filtrer settings.json (hooks + plugins + model + effort + outputStyle) ──
if [ -f "$SETTINGS_JSON" ]; then
    tmp=$(mktemp)
    jq \
        --argjson plugins "$selected_plugins" \
        --arg rtk "$rtk_enabled" \
        --arg model "$sel_model" \
        --arg effort "$sel_effort" \
        --arg outputStyle "$sel_output_style" '
        # 2a. Filter enabledPlugins
        (if .enabledPlugins then
            .enabledPlugins |= with_entries(select(.key as $k | $plugins | index($k)))
         else . end)
        # 2b. Filter hooks.PreToolUse: drop rtk hook if rtk_enabled != "true"
        | (if $rtk == "true" then . else
            (if .hooks.PreToolUse then
                .hooks.PreToolUse |= map(
                    # retire les entrées dont le seul hook est rtk
                    (.hooks |= map(select(.command != "rtk hook claude")))
                ) | .hooks.PreToolUse |= map(select(.hooks | length > 0))
             else . end)
          end)
        # 2c. Set model, effortLevel et outputStyle si définis
        | (if $model != "" then .model = $model else . end)
        | (if $effort != "" then .effortLevel = $effort else . end)
        | (if $outputStyle != "" then .outputStyle = $outputStyle else . end)
    ' "$SETTINGS_JSON" > "$tmp" && mv "$tmp" "$SETTINGS_JSON"
fi

# ── 3. Filtrer skills/ : retirer les symlinks non sélectionnés ──
# Sémantique :
#   .skills absent ou null  → pas de préférence, on garde tous les symlinks (default)
#   .skills == []           → l'utilisateur a explicitement décoché tout
#   .skills == [a,b,c]      → garder uniquement ces skills + le meta-skill interne
n_skills_kept="all"
if [ "$skills_raw" != "null" ] && [ -d "$SKILLS_DIR" ]; then
    sel_skills=$(echo "$skills_raw" | jq -r '.[]?' 2>/dev/null || true)
    n_skills_kept=0
    for link in "$SKILLS_DIR"/*; do
        [ -e "$link" ] || continue
        # Ne touche jamais aux vrais dossiers (skills ajoutés via /skill add)
        [ -L "$link" ] || continue
        name=$(basename "$link")
        # Toujours préserver le meta-skill interne au conteneur
        if [ "$name" = "claude-yolo-internals" ]; then
            n_skills_kept=$((n_skills_kept + 1))
            continue
        fi
        if printf '%s\n' "$sel_skills" | grep -qxF "$name"; then
            n_skills_kept=$((n_skills_kept + 1))
        else
            rm "$link" 2>/dev/null || true
        fi
    done
fi

# Log compact
n_plugins=$(echo "$selected_plugins" | jq 'length')
n_mcp=$(echo "$selected_mcp" | jq 'length')
echo "  [CONFIG] plugins=${n_plugins} mcp=${n_mcp} skills=${n_skills_kept} rtk=${rtk_enabled} model=${sel_model:-default} effort=${sel_effort:-default} style=${sel_output_style:-default}"
