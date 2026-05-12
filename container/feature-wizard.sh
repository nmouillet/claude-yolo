#!/bin/bash
# Wizard interactif (gum) pour configurer Claude YOLO par-projet.
#
# Routage (en fonction des flags et de l'état) :
#   --no-prompt + config existe         → applique direct, exit 0
#   --no-prompt + pas de config         → preset auto-détecté, applique, NE SAUVEGARDE PAS, exit 0
#   --reconfigure                       → wizard édition complet
#   interactif + config existe          → écran récap : [Enter] valide / [e] édite / [r] reset
#   interactif + pas de config          → wizard premier run (preset auto pré-coché)
#
# Lecture/écriture : /home/claude/claude-yolo-config/projects.settings.json (clé = HOST_PROJECT_PATH)
# Énumération via : container/enumerate-features.sh
# Application via : container/apply-project-config.sh

set -e

PROJECTS_FILE="/home/claude/claude-yolo-config/projects.settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENUMERATE="$SCRIPT_DIR/enumerate-features.sh"
APPLY="$SCRIPT_DIR/apply-project-config.sh"
KEY="${HOST_PROJECT_PATH:-}"

NO_PROMPT=false
RECONFIGURE=false
for arg in "$@"; do
    case "$arg" in
        --no-prompt)   NO_PROMPT=true ;;
        --reconfigure) RECONFIGURE=true ;;
    esac
done

# Pas de TTY → mode no-prompt forcé
if [ ! -t 0 ] || [ ! -t 1 ]; then
    NO_PROMPT=true
    RECONFIGURE=false
fi

# Pas de clé → wizard inutile
if [ -z "$KEY" ]; then
    echo "  [WIZARD] HOST_PROJECT_PATH non défini, configuration ignorée." >&2
    exit 0
fi

mkdir -p "$(dirname "$PROJECTS_FILE")"
[ ! -f "$PROJECTS_FILE" ] && echo '{"version":1,"projects":{}}' > "$PROJECTS_FILE"

# Vérifier gum (si absent en mode interactif, fallback no-prompt)
if ! command -v gum &>/dev/null; then
    if ! $NO_PROMPT; then
        echo "  [WIZARD] gum absent, basculage en mode no-prompt." >&2
    fi
    NO_PROMPT=true
    RECONFIGURE=false
fi

# Récupérer l'inventaire et la config existante
FEATURES=$("$ENUMERATE" /project 2>/dev/null || echo '{}')
EXISTING=$(jq --arg k "$KEY" '.projects[$k] // empty' "$PROJECTS_FILE")

# ── Helpers : defaults par preset ──────────────────────────────────────

preset_plugins() {
    # Aucun plugin pré-coché par défaut (préserve la sobriété)
    case "$1" in
        *) echo "" ;;
    esac
}

preset_mcp() {
    case "$1" in
        lean)                                       echo "" ;;
        dotnet-vue|dotnet|vue|react|node|python)    echo "fetch,context7" ;;
        ansible)                                    echo "fetch" ;;
        docs|generic|*)                             echo "fetch" ;;
    esac
}

# Skills par défaut, alignés sur l'outillage typique du preset.
# Renvoie une liste CSV. Vide = aucun skill pré-coché.
preset_skills() {
    case "$1" in
        lean)        echo "" ;;
        dotnet-vue)  echo "dead-code-dotnet,dead-code-js,dead-code-css,overengineering-dotnet,fontawesome,bootstrap,accessibilite,helmo-charte,build,check-updates,simplify" ;;
        dotnet)      echo "dead-code-dotnet,overengineering-dotnet,build,check-updates,simplify" ;;
        vue|react|node)
                     echo "dead-code-js,dead-code-css,fontawesome,bootstrap,accessibilite,helmo-charte,check-updates,simplify" ;;
        ansible)     echo "audit-ansible,audit-securite-ansible,overengineering-ansible,check-updates,simplify" ;;
        python)      echo "check-updates,simplify" ;;
        docs)        echo "accessibilite,simplify" ;;
        generic|*)   echo "simplify" ;;
    esac
}

# Output style par défaut selon le preset. Vide = défaut Claude Code.
preset_output_style() {
    case "$1" in
        lean) echo "concise" ;;
        *)    echo "" ;;
    esac
}

# ── Mode no-prompt ──────────────────────────────────────────
if $NO_PROMPT; then
    if [ -n "$EXISTING" ]; then
        # Config existe → applique tel quel
        echo "  [WIZARD] Config existante restaurée pour $KEY"
    else
        # Pas de config → preset auto, créée silencieusement avec flag autoCreated:true.
        # Skills laissé à `null` = "pas de préférence", apply-project-config laisse tout activé.
        DETECTED=$(echo "$FEATURES" | jq -r '.detected_preset // "generic"')
        MCP_DEFAULT=$(preset_mcp "$DETECTED")
        STYLE_DEFAULT=$(preset_output_style "$DETECTED")
        AVAILABLE_MCP=$(echo "$FEATURES" | jq -r '.mcp[].id')
        SELECTED_MCP_JSON=$(
            for m in $(echo "$MCP_DEFAULT" | tr ',' ' '); do
                echo "$AVAILABLE_MCP" | grep -qx "$m" && echo "$m"
            done | jq -R . | jq -s .
        )
        TMP=$(mktemp)
        jq --arg k "$KEY" \
           --arg preset "$DETECTED" \
           --arg style "$STYLE_DEFAULT" \
           --argjson plugins '[]' \
           --argjson mcp "$SELECTED_MCP_JSON" \
           '.projects[$k] = ({
               preset: $preset,
               plugins: $plugins,
               mcp: $mcp,
               skills: null,
               hooks: {rtk: true},
               model: null,
               effortLevel: null,
               outputStyle: (if $style == "" then null else $style end),
               createdAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
               lastUsed: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
               autoCreated: true
           })' "$PROJECTS_FILE" > "$TMP" && mv "$TMP" "$PROJECTS_FILE"
        echo "  [WIZARD] Aucune config, preset auto: $DETECTED (lancez avec --reconfigure pour personnaliser)"
    fi
    exec "$APPLY"
fi

# ── Mode interactif (gum) ──────────────────────────────────

# Couleurs gum
G_PRIM="212"   # rose
G_SEC="240"    # gris
G_OK="42"      # vert

# Affichage du récap d'une config (string formaté)
render_summary() {
    local cfg="$1"
    local preset=$(echo "$cfg" | jq -r '.preset // "—"')
    local plugins=$(echo "$cfg" | jq -r '.plugins | if length == 0 then "(aucun)" else join(", ") end')
    local mcp=$(echo "$cfg" | jq -r '.mcp | if length == 0 then "(aucun)" else join(", ") end')
    local skills=$(echo "$cfg" | jq -r '.skills | if . == null then "(tous)" elif length == 0 then "(aucun)" else join(", ") end')
    local rtk=$(echo "$cfg" | jq -r '.hooks.rtk // true')
    local model=$(echo "$cfg" | jq -r '.model // "(défaut)"')
    local effort=$(echo "$cfg" | jq -r '.effortLevel // "(défaut)"')
    local style=$(echo "$cfg" | jq -r '.outputStyle // "(défaut)"')

    gum style --border normal --margin "0" --padding "1 2" --border-foreground "$G_PRIM" \
        "$(gum style --bold "Configuration de $KEY")" \
        "" \
        "$(printf "%-12s %s" "Preset"   "$preset")" \
        "$(printf "%-12s %s" "Plugins"  "$plugins")" \
        "$(printf "%-12s %s" "MCP"      "$mcp")" \
        "$(printf "%-12s %s" "Skills"   "$skills")" \
        "$(printf "%-12s %s" "RTK"      "$rtk")" \
        "$(printf "%-12s %s" "Model"    "$model")" \
        "$(printf "%-12s %s" "Effort"   "$effort")" \
        "$(printf "%-12s %s" "Style"    "$style")"
}

# Étape : choisir un preset (renvoie l'id sur stdout)
choose_preset() {
    local detected="$1"
    local prompt_msg="$2"
    local options
    options=$(echo "$FEATURES" | jq -r '.presets[] | "\(.id)\t\(.label)"')

    # Construit la liste avec marqueur sur le détecté
    local choices=""
    while IFS=$'\t' read -r id label; do
        if [ "$id" = "$detected" ]; then
            choices+="$label (auto-détecté)"$'\n'
        else
            choices+="$label"$'\n'
        fi
    done <<< "$options"

    # On affiche, l'utilisateur choisit, on remappe vers l'id
    local picked
    picked=$(echo -n "$choices" | gum choose --header "$prompt_msg" --selected "$(echo "$FEATURES" | jq -r --arg d "$detected" '.presets[] | select(.id == $d) | .label + " (auto-détecté)"')")
    # Retire suffixe " (auto-détecté)" pour le matching
    picked="${picked% (auto-détecté)}"
    echo "$FEATURES" | jq -r --arg lbl "$picked" '.presets[] | select(.label == $lbl) | .id'
}

# Étape : multi-select générique sur une liste (id\tlabel[\tdesc]) avec présélection.
# La description est affichée à côté du label, alignée. Les entrées sans desc
# restent affichées avec leur label uniquement.
multi_select() {
    local header="$1"
    local list="$2"       # lines: id\tlabel[\tdesc]
    local preselected="$3"  # CSV des ids

    [ -z "$list" ] && return

    # Calcule la largeur max des labels pour aligner les descriptions
    local maxw=0
    while IFS=$'\t' read -r id label desc; do
        [ -z "$id" ] && continue
        local lw=${#label}
        [ "$lw" -gt "$maxw" ] && maxw=$lw
    done <<< "$list"
    [ "$maxw" -gt 32 ] && maxw=32  # cap pour éviter de pousser la desc trop loin

    # Construire les options affichées et le mapping display→id
    declare -A LABEL_TO_ID=()
    local options="" selected_labels=""
    while IFS=$'\t' read -r id label desc; do
        [ -z "$id" ] && continue
        local display
        if [ -n "$desc" ]; then
            display=$(printf "%-${maxw}s  %s" "$label" "$desc")
        else
            display="$label"
        fi
        LABEL_TO_ID["$display"]="$id"
        options+="$display"$'\n'
        if [[ ",$preselected," == *",$id,"* ]]; then
            selected_labels+="$display"$'\n'
        fi
    done <<< "$list"

    [ -z "$options" ] && return

    local picked
    if [ -n "$selected_labels" ]; then
        picked=$(echo -n "$options" | gum choose --no-limit --header "$header" --selected "$(echo -n "$selected_labels" | tr '\n' ',' | sed 's/,$//')") || return
    else
        picked=$(echo -n "$options" | gum choose --no-limit --header "$header") || return
    fi

    # Remappe display strings → ids
    while IFS= read -r lbl; do
        [ -n "$lbl" ] && echo "${LABEL_TO_ID[$lbl]}"
    done <<< "$picked"
}

# Liste les output styles disponibles dans /home/claude/.claude/output-styles/ + defaults seeded
list_output_styles() {
    local styles_dir="/home/claude/.claude/output-styles"
    [ -d "$styles_dir" ] || return
    find "$styles_dir" -maxdepth 1 -name '*.md' 2>/dev/null | while read -r f; do
        basename "$f" .md
    done | sort -u
}

# Wizard "édition" : retourne un JSON complet de config sur stdout
edit_wizard() {
    local initial="$1"
    local default_preset=$(echo "$initial" | jq -r '.preset // empty')
    [ -z "$default_preset" ] && default_preset=$(echo "$FEATURES" | jq -r '.detected_preset // "generic"')

    # Étape 1 — preset
    local preset
    preset=$(choose_preset "$default_preset" "Choisir un preset (point de départ) :")
    [ -z "$preset" ] && preset="$default_preset"

    # Defaults selon preset (si initial vide)
    local def_plugins=$(preset_plugins "$preset")
    local def_mcp=$(preset_mcp "$preset")
    local def_skills=$(preset_skills "$preset")
    local def_style=$(preset_output_style "$preset")
    local init_plugins=$(echo "$initial" | jq -r '.plugins // [] | join(",")')
    local init_mcp=$(echo "$initial" | jq -r '.mcp // [] | join(",")')
    local init_skills=$(echo "$initial" | jq -r 'if .skills == null then "" else (.skills | join(",")) end')
    local init_style=$(echo "$initial" | jq -r '.outputStyle // ""')
    [ -z "$init_plugins" ] && init_plugins="$def_plugins"
    [ -z "$init_mcp" ] && init_mcp="$def_mcp"
    [ -z "$init_skills" ] && init_skills="$def_skills"
    [ -z "$init_style" ] && init_style="$def_style"

    # Étape 2 — plugins
    local plugins_list=$(echo "$FEATURES" | jq -r '.plugins[] | "\(.id)\t\(.label)\t\(.desc // "")"')
    local sel_plugins
    sel_plugins=$(multi_select "Plugins (espace pour cocher, entrée pour valider) :" "$plugins_list" "$init_plugins" | paste -sd ',' -)

    # Étape 3 — MCP
    local mcp_list=$(echo "$FEATURES" | jq -r '.mcp[] | "\(.id)\t\(.label)\t\(.desc // "")"')
    local sel_mcp
    sel_mcp=$(multi_select "MCP servers (espace pour cocher) :" "$mcp_list" "$init_mcp" | paste -sd ',' -)

    # Étape 4 — skills (chaque skill non coché = symlink retiré du conteneur)
    local skills_list=$(echo "$FEATURES" | jq -r '.skills[]? | "\(.id)\t\(.label)\t\(.desc // "")"')
    local sel_skills=""
    if [ -n "$skills_list" ]; then
        sel_skills=$(multi_select "Skills (cocher uniquement ceux à exposer à Claude) :" "$skills_list" "$init_skills" | paste -sd ',' -)
    fi

    # Étape 5 — hooks
    local rtk_default=$(echo "$initial" | jq -r '.hooks.rtk // true')
    local rtk_choice
    if gum confirm "Activer RTK (compression des sorties Bash) ?" --default="$([ "$rtk_default" = "true" ] && echo true || echo false)"; then
        rtk_choice=true
    else
        rtk_choice=false
    fi

    # Étape 6 — model + effort (optionnel)
    local cur_model=$(echo "$initial" | jq -r '.model // ""')
    local cur_effort=$(echo "$initial" | jq -r '.effortLevel // ""')
    local model_pick effort_pick
    model_pick=$(printf "(défaut)\nsonnet\nopus\nhaiku" | gum choose --header "Modèle par défaut :" --selected "${cur_model:-(défaut)}")
    [ "$model_pick" = "(défaut)" ] && model_pick=""
    effort_pick=$(printf "(défaut)\nlow\nmedium\nhigh" | gum choose --header "Niveau d'effort :" --selected "${cur_effort:-(défaut)}")
    [ "$effort_pick" = "(défaut)" ] && effort_pick=""

    # Étape 7 — output style
    local style_options=$(list_output_styles)
    local style_pick=""
    if [ -n "$style_options" ]; then
        local style_choices="(défaut)"$'\n'"$style_options"
        style_pick=$(echo -n "$style_choices" | gum choose --header "Output style (verbosité des réponses) :" --selected "${init_style:-(défaut)}")
        [ "$style_pick" = "(défaut)" ] && style_pick=""
    fi

    # Assemble JSON
    local created_at
    created_at=$(echo "$initial" | jq -r '.createdAt // empty')
    [ -z "$created_at" ] && created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jq -n \
        --arg preset "$preset" \
        --arg plugins "$sel_plugins" \
        --arg mcp "$sel_mcp" \
        --arg skills "$sel_skills" \
        --argjson rtk "$rtk_choice" \
        --arg model "$model_pick" \
        --arg effort "$effort_pick" \
        --arg style "$style_pick" \
        --arg created "$created_at" \
        --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            preset: $preset,
            plugins: ($plugins | if . == "" then [] else split(",") end),
            mcp:     ($mcp     | if . == "" then [] else split(",") end),
            skills:  ($skills  | if . == "" then [] else split(",") end),
            hooks:   {rtk: $rtk},
            model:   (if $model == "" then null else $model end),
            effortLevel: (if $effort == "" then null else $effort end),
            outputStyle: (if $style == "" then null else $style end),
            createdAt: $created,
            lastUsed:  $now
        }'
}

save_config() {
    local cfg="$1"
    local tmp
    tmp=$(mktemp)
    jq --arg k "$KEY" --argjson cfg "$cfg" \
        '.projects[$k] = $cfg' "$PROJECTS_FILE" > "$tmp" && mv "$tmp" "$PROJECTS_FILE"
}

# ── Routage final ──────────────────────────────────────────
clear

if $RECONFIGURE || [ -z "$EXISTING" ]; then
    # Premier run OU --reconfigure → directement le wizard d'édition
    if [ -z "$EXISTING" ]; then
        gum style --foreground "$G_PRIM" --bold "Première ouverture de ce projet — configuration initiale"
        # Pour le 1er run, initialiser depuis le preset auto-détecté
        DETECTED=$(echo "$FEATURES" | jq -r '.detected_preset // "generic"')
        EXISTING=$(jq -n --arg p "$DETECTED" --arg mcp "$(preset_mcp "$DETECTED")" --arg style "$(preset_output_style "$DETECTED")" \
            '{preset:$p, plugins:[], mcp:($mcp | split(",")), skills:null, hooks:{rtk:true}, model:null, effortLevel:null, outputStyle: (if $style == "" then null else $style end)}')
        echo ""
        echo "  Projet détecté comme : $(gum style --bold "$DETECTED")"
        echo ""
    fi
    NEW_CFG=$(edit_wizard "$EXISTING")
    echo ""
    render_summary "$NEW_CFG"
    echo ""
    if gum confirm "Sauvegarder cette configuration ?" --default=true; then
        save_config "$NEW_CFG"
        echo "  $(gum style --foreground "$G_OK" "[OK] Sauvegardé dans projects.settings.json")"
    fi
else
    # Config existe → écran de validation rapide
    render_summary "$EXISTING"
    echo ""
    CHOICE=$(printf "Valider et lancer Claude\nModifier la configuration\nRepartir d'un preset\nQuitter" \
        | gum choose --header "Action :")

    case "$CHOICE" in
        "Valider et lancer Claude"|"")
            : # On garde l'EXISTING tel quel
            ;;
        "Modifier la configuration")
            NEW_CFG=$(edit_wizard "$EXISTING")
            echo ""
            render_summary "$NEW_CFG"
            echo ""
            if gum confirm "Sauvegarder ?" --default=true; then
                save_config "$NEW_CFG"
                echo "  $(gum style --foreground "$G_OK" "[OK] Sauvegardé")"
            fi
            ;;
        "Repartir d'un preset")
            DETECTED=$(echo "$FEATURES" | jq -r '.detected_preset // "generic"')
            FRESH=$(jq -n --arg p "$DETECTED" --arg mcp "$(preset_mcp "$DETECTED")" --arg style "$(preset_output_style "$DETECTED")" \
                '{preset:$p, plugins:[], mcp:($mcp | split(",")), skills:null, hooks:{rtk:true}, model:null, effortLevel:null, outputStyle: (if $style == "" then null else $style end)}')
            NEW_CFG=$(edit_wizard "$FRESH")
            echo ""
            render_summary "$NEW_CFG"
            echo ""
            if gum confirm "Sauvegarder ?" --default=true; then
                save_config "$NEW_CFG"
                echo "  $(gum style --foreground "$G_OK" "[OK] Sauvegardé")"
            fi
            ;;
        "Quitter")
            echo "  Annulé."
            exit 130
            ;;
    esac
fi

# Mettre à jour lastUsed
tmp=$(mktemp)
jq --arg k "$KEY" --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    'if .projects[$k] then .projects[$k].lastUsed = $now else . end' \
    "$PROJECTS_FILE" > "$tmp" && mv "$tmp" "$PROJECTS_FILE"

# Appliquer
"$APPLY"
