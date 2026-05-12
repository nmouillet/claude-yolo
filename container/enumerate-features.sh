#!/bin/bash
# Scan dynamique : ce qui est installé/disponible dans le conteneur courant.
# Sortie : JSON unique sur stdout
#   {
#     "plugins": [{"id":"postman","label":"postman","desc":"..."}, ...],
#     "mcp":     [{"id":"fetch","label":"fetch","desc":"..."}, ...],
#     "skills":  [{"id":"init","label":"init","desc":"..."}, ...],
#     "hooks":   [{"id":"rtk","label":"RTK","desc":"...","available":true}, ...],
#     "presets": [{"id":"dotnet-vue","label":".NET + Vue.js"}, ...],
#     "detected_preset": "dotnet-vue"
#   }
#
# Les descriptions sont sanitisées (pas de virgules ni tab/newline) car
# feature-wizard.sh les passe à gum dont --selected utilise la virgule
# comme séparateur. Toutes tronquées à 60 caractères.
#
# Appelé par feature-wizard.sh. Aucun side-effect, JSON only.

set -e

PROJECT_DIR="${1:-/project}"
CLAUDE_JSON="/home/claude/.claude.json"
MARKETPLACES_DIR="/home/claude/.claude/plugins/marketplaces"
# Source of truth for skills enumeration is host-skills/ (overlay source).
# Fall back to skills/ for backwards compat with older container layouts.
SKILLS_DIR="/home/claude/.claude/host-skills"
[ ! -d "$SKILLS_DIR" ] && SKILLS_DIR="/home/claude/.claude/skills"

# Sanitise une description pour affichage tabulé : retire newline/tab/CR,
# remplace virgules par `;` (gum --selected utilise la virgule comme séparateur),
# tronque à 60 caractères.
sanitize_desc() {
    tr -d '\n\r\t' | tr ',' ';' | cut -c1-60
}

# Description connue pour un MCP server (par id). Vide si inconnu.
mcp_desc() {
    case "$1" in
        fetch)               echo "Récupération de pages web (HTTP)" ;;
        sequential-thinking) echo "Raisonnement étape par étape" ;;
        context7)            echo "Documentation à jour des bibliothèques" ;;
        filesystem)          echo "Accès au système de fichiers (/project)" ;;
        memory)              echo "Mémoire persistante JSON entre sessions" ;;
        brave-search)        echo "Recherche web via Brave Search API" ;;
        playwright)          echo "Automatisation navigateur (headless)" ;;
        chrome-devtools)     echo "Inspection via Chrome DevTools Protocol" ;;
        github)              echo "API GitHub — issues / PRs / branches" ;;
        dbhub)               echo "Connexion SQL (lecture/écriture)" ;;
        docker)              echo "Gestion des conteneurs Docker" ;;
        *)                   echo "" ;;
    esac
}

# ── Plugins disponibles (scan des marketplaces) ──
plugins_json='[]'
if [ -d "$MARKETPLACES_DIR" ]; then
    plugins_json=$(
        find "$MARKETPLACES_DIR" -mindepth 3 -maxdepth 3 -type d -path '*/plugins/*' 2>/dev/null \
        | while read -r pdir; do
            pname=$(basename "$pdir")
            mp=$(basename "$(dirname "$(dirname "$pdir")")")
            pdesc=""
            if [ -f "$pdir/.claude-plugin/plugin.json" ]; then
                pdesc=$(jq -r '.description // ""' "$pdir/.claude-plugin/plugin.json" 2>/dev/null | sanitize_desc)
            fi
            # ID au format "plugin@marketplace" (Claude Code convention)
            jq -n --arg id "${pname}@${mp}" --arg label "$pname" --arg desc "$pdesc" \
                '{id: $id, label: $label, desc: $desc}'
        done | jq -s 'sort_by(.label)'
    )
    [ -z "$plugins_json" ] && plugins_json='[]'
fi

# ── MCP servers actuellement configurés dans .claude.json ──
mcp_json='[]'
if [ -f "$CLAUDE_JSON" ]; then
    mcp_json=$(
        jq -r '.mcpServers // {} | keys[]' "$CLAUDE_JSON" 2>/dev/null \
        | while IFS= read -r k; do
            d=$(mcp_desc "$k" | sanitize_desc)
            jq -n --arg id "$k" --arg label "$k" --arg desc "$d" \
                '{id: $id, label: $label, desc: $desc}'
        done | jq -s 'sort_by(.label)'
    )
    [ -z "$mcp_json" ] && mcp_json='[]'
fi

# ── Skills custom (hors plugins) ──
skills_json='[]'
if [ -d "$SKILLS_DIR" ]; then
    skills_json=$(
        find "$SKILLS_DIR" -maxdepth 2 -name 'SKILL.md' 2>/dev/null \
        | while read -r sf; do
            sid=$(basename "$(dirname "$sf")")
            # description: extract `description:` from frontmatter
            sdesc=$(awk '/^---$/{f=!f;next} f && /^description:/{sub(/^description:[[:space:]]*/,""); print; exit}' "$sf" 2>/dev/null \
                    | tr -d '"' | sanitize_desc)
            jq -n --arg id "$sid" --arg label "$sid" --arg desc "$sdesc" \
                '{id: $id, label: $label, desc: $desc}'
        done | jq -s 'sort_by(.label)'
    )
    [ -z "$skills_json" ] && skills_json='[]'
fi

# ── Hooks toggle-ables (protect-config et git-context sont obligatoires) ──
hooks_json=$(jq -n --argjson rtk_available "$(command -v rtk &>/dev/null && echo true || echo false)" '
    [{
        id: "rtk",
        label: "RTK",
        desc: "Rust Token Killer — compresse les sorties Bash longues",
        available: $rtk_available
    }]
')

# ── Presets statiques ──
# `lean` : économie maximale — aucun MCP, aucun skill, output style concise.
# À utiliser pour les sessions one-shot type "renomme cette variable".
presets_json='[
    {"id":"dotnet-vue","label":".NET + Vue.js"},
    {"id":"dotnet","label":".NET"},
    {"id":"vue","label":"Vue.js"},
    {"id":"react","label":"React"},
    {"id":"node","label":"Node.js / TypeScript"},
    {"id":"ansible","label":"Ansible"},
    {"id":"python","label":"Python"},
    {"id":"docs","label":"Documentation / Markdown"},
    {"id":"lean","label":"Lean (token-economy max)"},
    {"id":"generic","label":"Generique"}
]'

# ── Détection auto du preset selon le contenu du projet ──
detect_preset() {
    local p="$1"
    local has_csproj=false has_sln=false has_pkg=false has_vue=false has_react=false
    local has_ansible=false has_python=false has_md_only=true

    shopt -s nullglob
    local csproj=( "$p"/*.csproj "$p"/**/*.csproj )
    local sln=( "$p"/*.sln )
    shopt -u nullglob

    [ ${#csproj[@]} -gt 0 ] && has_csproj=true
    [ ${#sln[@]} -gt 0 ] && has_sln=true
    [ -f "$p/package.json" ] && has_pkg=true
    # Wrap in if/then: `[ a ] || [ b ] && var=true` would only set var when b is true
    # (the && binds tighter than the chained ||).
    if [ -f "$p/pyproject.toml" ] || [ -f "$p/requirements.txt" ] || [ -f "$p/setup.py" ]; then
        has_python=true
    fi
    if [ -f "$p/ansible.cfg" ] || [ -d "$p/playbooks" ] || [ -d "$p/roles" ] || [ -f "$p/site.yml" ]; then
        has_ansible=true
    fi

    if $has_pkg; then
        grep -q '"vue"' "$p/package.json" 2>/dev/null && has_vue=true
        grep -q '"react"' "$p/package.json" 2>/dev/null && has_react=true
    fi

    if $has_csproj || $has_sln; then
        $has_vue && { echo "dotnet-vue"; return; }
        echo "dotnet"; return
    fi
    $has_ansible && { echo "ansible"; return; }
    $has_python && { echo "python"; return; }
    $has_vue && { echo "vue"; return; }
    $has_react && { echo "react"; return; }
    $has_pkg && { echo "node"; return; }

    # Docs only : présence de README.md + .md mais pas de fichier build
    if compgen -G "$p/*.md" >/dev/null 2>&1 && ! compgen -G "$p/Makefile" >/dev/null 2>&1; then
        echo "docs"; return
    fi
    echo "generic"
}

detected=$(detect_preset "$PROJECT_DIR" 2>/dev/null || echo "generic")

# ── Composition finale ──
jq -n \
    --argjson plugins "$plugins_json" \
    --argjson mcp "$mcp_json" \
    --argjson skills "$skills_json" \
    --argjson hooks "$hooks_json" \
    --argjson presets "$presets_json" \
    --arg detected "$detected" \
    '{plugins: $plugins, mcp: $mcp, skills: $skills, hooks: $hooks, presets: $presets, detected_preset: $detected}'
