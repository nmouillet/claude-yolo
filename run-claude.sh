#!/usr/bin/env bash
set -Eeuo pipefail

# -E propagates the ERR trap into functions and subshells. Report the
# failing line + command when set -e trips, otherwise a bare
# `exit 127` bubbles up to the PS1 wrapper with no diagnostic at all.
_on_error() {
    local _ec=$? _line=$1 _cmd=$2
    tput cnorm 2>/dev/null || true
    printf '\e[?1l' 2>/dev/null || true
    echo "" >&2
    echo -e "  \033[31m[ERREUR] run-claude.sh ligne ${_line} : exit ${_ec}\033[0m" >&2
    echo -e "  \033[90m  Commande : ${_cmd}\033[0m" >&2
    [ "$_ec" = "127" ] && echo -e "  \033[90m  (exit 127 = commande/binaire introuvable)\033[0m" >&2
}
trap '_on_error "$LINENO" "$BASH_COMMAND"' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# ── Parse args ───────────────────────────────────────────────
BUILD=false
PROJECT_PATH=""
PROMPT=""
REMOTE=false
SOURCES_ROOT_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)        BUILD=true; shift ;;
        --prompt)       PROMPT="$2"; shift 2 ;;
        --remote)       REMOTE=true; shift ;;
        --sources-root) SOURCES_ROOT_ARG="$2"; shift 2 ;;
        -*)             echo "Unknown option: $1"; exit 1 ;;
        *)              PROJECT_PATH="$1"; shift ;;
    esac
done

# ── Pre-checks ─────────────────────────────────────────────
# Docker
if ! docker info > /dev/null 2>&1; then
    echo "Erreur : Docker n'est pas accessible." >&2
    echo "Lancez Docker Desktop ou verifiez l'integration WSL." >&2
    exit 1
fi

# Volume partage (external: true dans docker-compose.yml)
if ! docker volume inspect claude-user-config > /dev/null 2>&1; then
    docker volume create claude-user-config > /dev/null
fi

# ── OAuth credentials ──────────────────────────────────────
# Auto-detect host credentials file from Windows (PS1 passes WIN_USERPROFILE)
# or native Linux. Two channels to pass credentials to container:
#   1. HOST_CREDENTIALS_PATH → Docker volume mount (file mount, most reliable)
#   2. CLAUDE_CREDENTIALS_B64 → env var (base64-encoded full JSON, fallback)

# Helper: convert a Windows path (C:\foo\bar or C:/foo/bar) to a WSL path (/mnt/c/foo/bar)
# Returns nothing if the input is already a Unix path or conversion fails.
_win_to_wsl_path() {
    local in="$1"
    [ -z "$in" ] && return
    # Already a Unix path
    [[ "$in" == /* ]] && { echo "$in"; return; }
    # Prefer wslpath if available (handles edge cases like UNC paths)
    if command -v wslpath &>/dev/null; then
        local out
        out=$(wslpath -u "$in" 2>/dev/null)
        if [ -n "$out" ]; then
            echo "$out"
            return
        fi
    fi
    # Manual fallback: C:\foo\bar -> /mnt/c/foo/bar
    if [[ "$in" =~ ^[A-Za-z]: ]]; then
        local drive="${in:0:1}"
        drive=$(echo "$drive" | tr '[:upper:]' '[:lower:]')
        local rest="${in:2}"
        rest="${rest//\\//}"
        echo "/mnt/$drive$rest"
    fi
}

# Helper: detect Windows user home from WSL
_detect_win_home() {
    # WIN_USERPROFILE passed by PS1 (already a WSL path)
    if [ -n "${WIN_USERPROFILE:-}" ] && [ -d "$WIN_USERPROFILE" ]; then
        echo "$WIN_USERPROFILE"
        return
    fi
    # Auto-detect via cmd.exe
    if command -v cmd.exe &>/dev/null; then
        local _win_prof _wsl
        _win_prof=$(cmd.exe /C "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n')
        _wsl=$(_win_to_wsl_path "$_win_prof")
        [ -n "$_wsl" ] && [ -d "$_wsl" ] && echo "$_wsl"
    fi
}

# Helper: find credentials file across known paths.
# Claude Code has used both locations over time; pick the most recently modified
# so a stale legacy file never wins over a freshly-refreshed one.
_find_credentials() {
    local home_dir="$1"
    local newest="" newest_mtime=0
    for _cred in "$home_dir/.claude/.credentials.json" "$home_dir/.claude/credentials/.credentials.json"; do
        if [ -f "$_cred" ] && [ -s "$_cred" ]; then
            local mtime
            mtime=$(stat -c '%Y' "$_cred" 2>/dev/null || echo 0)
            if [ "$mtime" -gt "$newest_mtime" ]; then
                newest="$_cred"
                newest_mtime=$mtime
            fi
        fi
    done
    [ -n "$newest" ] && echo "$newest"
}

# Helper: extracts .claudeAiOauth.expiresAt from a credentials file (empty if absent).
# Uses grep+PCRE because jq is not guaranteed to be on the WSL/Linux host (it's in the image only).
_cred_expires_at() {
    local cred_file="$1"
    { [ ! -f "$cred_file" ] || [ ! -s "$cred_file" ]; } && return
    grep -oP '"expiresAt"\s*:\s*\K[0-9]+' "$cred_file" 2>/dev/null | head -1
}

# Helper: returns 0 (true) if the credentials file's accessToken is expired or malformed
_creds_expired() {
    local exp
    exp=$(_cred_expires_at "$1")
    [ -z "$exp" ] && return 0
    local now_ms=$(($(date +%s) * 1000))
    [ "$exp" -lt "$now_ms" ]
}

# 1. Auto-detect host credentials file (PS1 ran auth login, credentials should exist)
if [ -z "${HOST_CREDENTIALS_PATH:-}" ] || [ ! -f "${HOST_CREDENTIALS_PATH:-}" ] || [ ! -s "${HOST_CREDENTIALS_PATH:-}" ]; then
    # Try Windows home first (WSL/PS1 context)
    _WIN_HOME=$(_detect_win_home)
    if [ -n "$_WIN_HOME" ]; then
        _cred_file=$(_find_credentials "$_WIN_HOME")
        if [ -n "$_cred_file" ]; then
            export HOST_CREDENTIALS_PATH="$_cred_file"
            export CLAUDE_CREDENTIALS_B64=$(base64 -w0 "$_cred_file")
            echo -e "  \033[32m[OK] Credentials detectees : $_cred_file\033[0m"
        fi
    fi
    # Try native Linux home
    if [ -z "${HOST_CREDENTIALS_PATH:-}" ] || [ ! -f "${HOST_CREDENTIALS_PATH:-}" ]; then
        _cred_file=$(_find_credentials "${CLAUDE_HOME:-$HOME}")
        if [ -n "${_cred_file:-}" ]; then
            export HOST_CREDENTIALS_PATH="$_cred_file"
            export CLAUDE_CREDENTIALS_B64=$(base64 -w0 "$_cred_file")
            echo -e "  \033[32m[OK] Credentials detectees : $_cred_file\033[0m"
        fi
    fi
fi

# 1b. Precheck expiresAt: if expired, drop the file so we fall through to re-auth.
# A stale refreshToken may also be revoked server-side, so a freshly logged-in session
# is safer than letting the container 401 on the first message.
if [ -n "${HOST_CREDENTIALS_PATH:-}" ] && _creds_expired "$HOST_CREDENTIALS_PATH"; then
    _EXP_AT=$(_cred_expires_at "$HOST_CREDENTIALS_PATH")
    if [ -n "$_EXP_AT" ]; then
        _EXP_AGO=$(( ($(date +%s) * 1000 - _EXP_AT) / 60000 ))
        echo -e "  \033[33m[WARN] Token OAuth expire depuis ${_EXP_AGO} min - reauthentification requise\033[0m"
    else
        echo -e "  \033[33m[WARN] Fichier de credentials invalide - reauthentification requise\033[0m"
    fi
    unset HOST_CREDENTIALS_PATH CLAUDE_CREDENTIALS_B64
fi

# 2. Fallback: bare token from env var or .env file
if [ -z "${CLAUDE_CREDENTIALS_B64:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    if [ -f "$SCRIPT_DIR/.env" ]; then
        ENV_TOKEN=$(grep -oP '^CLAUDE_CODE_OAUTH_TOKEN=\K.+' "$SCRIPT_DIR/.env" 2>/dev/null || true)
        if [ -n "$ENV_TOKEN" ]; then
            export CLAUDE_CODE_OAUTH_TOKEN="$ENV_TOKEN"
            echo -e "  \033[32m[OK] Token OAuth depuis .env\033[0m"
        fi
    fi
fi

# 3. Fallback: browser auth via PowerShell (WSL-only, when PS1 didn't run)
if [ -z "${CLAUDE_CREDENTIALS_B64:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    if command -v powershell.exe &>/dev/null \
       && powershell.exe -NoProfile -Command "Get-Command claude -ErrorAction Stop" > /dev/null 2>&1; then
        echo ""
        echo -e "  \033[33mAuthentification via navigateur...\033[0m"
        echo ""

        _saved_tty=$(stty -g 2>/dev/null || true)
        powershell.exe -NoProfile -Command "& claude auth login"
        [ -n "$_saved_tty" ] && stty "$_saved_tty" 2>/dev/null

        # Re-detect credentials after auth login
        _WIN_HOME=$(_detect_win_home)
        if [ -n "$_WIN_HOME" ]; then
            _cred_file=$(_find_credentials "$_WIN_HOME")
            if [ -n "$_cred_file" ]; then
                export HOST_CREDENTIALS_PATH="$_cred_file"
                export CLAUDE_CREDENTIALS_B64=$(base64 -w0 "$_cred_file")
                echo -e "  \033[32m[OK] Credentials obtenues (navigateur : $_cred_file)\033[0m"
            fi
        fi
    fi
fi

# 4. Manual prompt (last resort)
if [ -z "${CLAUDE_CREDENTIALS_B64:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo ""
    echo -e "  \033[33mToken OAuth manquant.\033[0m"
    echo -e "  \033[90mLancez : claude auth login (sur l'hote)\033[0m"
    echo -e "  \033[90mOu collez un token ci-dessous :\033[0m"
    echo ""
    read -rp "  Token: " _TOKEN
    if [ -z "$_TOKEN" ]; then
        echo "Pas de token fourni." >&2
        exit 1
    fi
    export CLAUDE_CODE_OAUTH_TOKEN="$_TOKEN"
fi

# Host credentials mount path (empty file fallback for Docker mount)
if [ -z "${HOST_CREDENTIALS_PATH:-}" ] || [ ! -f "${HOST_CREDENTIALS_PATH:-}" ]; then
    HOST_CREDENTIALS_PATH="${CLAUDE_HOME:-$HOME}/.claude/.host-credentials-empty"
    mkdir -p "$(dirname "$HOST_CREDENTIALS_PATH")"
    touch "$HOST_CREDENTIALS_PATH"
fi
export HOST_CREDENTIALS_PATH

# NuGet.Config auto-detection (Windows via WSL, or Linux)
if [ -z "${NUGET_CONFIG_PATH:-}" ]; then
    _APPDATA="${APPDATA:-}"
    if [ -z "$_APPDATA" ] && command -v cmd.exe &>/dev/null; then
        _APPDATA=$(cmd.exe /c "echo %APPDATA%" 2>/dev/null | tr -d '\r\n')
    fi
    if [ -n "$_APPDATA" ]; then
        _APPDATA_WSL=$(_win_to_wsl_path "$_APPDATA")
        _CFG="$_APPDATA_WSL/NuGet/NuGet.Config"
        [ -f "$_CFG" ] && NUGET_CONFIG_PATH="$_CFG"
    fi
    # Fallback: standard Linux location
    if [ -z "${NUGET_CONFIG_PATH:-}" ] && [ -f "$HOME/.nuget/NuGet/NuGet.Config" ]; then
        NUGET_CONFIG_PATH="$HOME/.nuget/NuGet/NuGet.Config"
    fi
fi

# If NuGet.Config found with private feeds, check/prompt for PAT
if [ -n "${NUGET_CONFIG_PATH:-}" ] && [ -f "$NUGET_CONFIG_PATH" ]; then
    if grep -q '<packageSourceCredentials>' "$NUGET_CONFIG_PATH" 2>/dev/null; then
        # Load PAT from .env if not already set
        NUGET_PAT="${NUGET_PRIVATE_FEED_PAT:-}"
        if [ -z "$NUGET_PAT" ] && [ -f "$SCRIPT_DIR/.env" ]; then
            NUGET_PAT=$(grep -oP '^NUGET_PRIVATE_FEED_PAT=\K.+' "$SCRIPT_DIR/.env" 2>/dev/null || true)
        fi

        if [ -z "$NUGET_PAT" ]; then
            echo ""
            echo -e "  \033[33mFeeds NuGet prives detectes dans la config hote.\033[0m"
            echo -e "  \033[90mLes credentials Windows (DPAPI) ne fonctionnent pas dans Docker.\033[0m"
            echo -e "  \033[90mUn Personal Access Token (PAT) est necessaire pour les feeds prives.\033[0m"
            echo ""
            echo -e "  \033[90mComment obtenir un PAT :\033[0m"
            echo -e "  \033[90m  GitLab : Preferences > Access Tokens > scope 'read_api'\033[0m"
            echo -e "  \033[90m  Azure DevOps : User Settings > PAT > scope 'Packaging (Read)'\033[0m"
            echo -e "  \033[90m  GitHub : Settings > Developer > PAT > scope 'read:packages'\033[0m"
            echo ""
            read -rp "  PAT NuGet (ou Entree pour ignorer) : " NUGET_PAT

            if [ -n "$NUGET_PAT" ]; then
                # Sauvegarder dans .env (meme pattern que le token OAuth)
                if [ -f "$SCRIPT_DIR/.env" ]; then
                    if grep -q '^NUGET_PRIVATE_FEED_PAT=' "$SCRIPT_DIR/.env"; then
                        sed -i "s|^NUGET_PRIVATE_FEED_PAT=.*|NUGET_PRIVATE_FEED_PAT=$NUGET_PAT|" "$SCRIPT_DIR/.env"
                    else
                        echo "NUGET_PRIVATE_FEED_PAT=$NUGET_PAT" >> "$SCRIPT_DIR/.env"
                    fi
                else
                    echo "NUGET_PRIVATE_FEED_PAT=$NUGET_PAT" >> "$SCRIPT_DIR/.env"
                fi
                echo -e "  \033[32m[OK] PAT NuGet sauvegarde dans .env\033[0m"
            else
                echo -e "  \033[90m  Ignore. Les feeds prives ne seront pas accessibles.\033[0m"
            fi
            echo ""
        fi
        export NUGET_PRIVATE_FEED_PAT="${NUGET_PAT:-}"
    fi
fi

# Fallback: empty file (docker-compose needs a valid mount path)
if [ -z "${NUGET_CONFIG_PATH:-}" ]; then
    NUGET_CONFIG_PATH="${CLAUDE_HOME:-$HOME}/.claude/.nuget-config-empty"
    mkdir -p "$(dirname "$NUGET_CONFIG_PATH")"
    touch "$NUGET_CONFIG_PATH"
fi
export NUGET_CONFIG_PATH

# ── Load config ──────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config.json not found in $SCRIPT_DIR" >&2
    exit 1
fi
# Priority: --sources-root (from PS1) > config.json > parent of script dir
if [ -n "$SOURCES_ROOT_ARG" ] && [ -d "$SOURCES_ROOT_ARG" ]; then
    SOURCES_ROOT="$SOURCES_ROOT_ARG"
else
    SOURCES_ROOT=$(grep -o '"sourcesRoot"\s*:\s*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*:.*"\(.*\)"/\1/' || true)
    if [ -n "$SOURCES_ROOT" ]; then
        _CONVERTED=$(_win_to_wsl_path "$SOURCES_ROOT")
        [ -n "$_CONVERTED" ] && SOURCES_ROOT="$_CONVERTED"
    else
        SOURCES_ROOT="$(dirname "$SCRIPT_DIR")"
    fi
fi

# ── Directory browser (arrow-key navigation) ──────────────
# Pure-bash tag detection (nullglob, no forks — critical on /mnt/c where
# find/head/echo pipelines are very slow).
get_project_tags() {
    local dir="$1" tags=""
    local _saved_ng
    _saved_ng=$(shopt -p nullglob)
    shopt -s nullglob
    local _sln=( "$dir"/*.sln ) _cs=( "$dir"/*.csproj ) _vite=( "$dir"/vite.config.* )
    eval "$_saved_ng"
    ((${#_sln[@]})) && tags+="sln, "
    ((${#_cs[@]})) && tags+="csproj, "
    [ -f "$dir/package.json" ] && tags+="npm, "
    ((${#_vite[@]})) && tags+="vite, "
    [ -d "$dir/.git" ] && tags+="git, "
    printf '%s' "${tags%, }"
}

# Parallel arrays (globals): path, display name, tag string.
# Rebuilt only when entering/leaving a directory — not on every arrow press.
_ITEM_PATH=()
_ITEM_NAME=()
_ITEM_TAG=()

build_items() {
    local current="$1"
    _ITEM_PATH=()
    _ITEM_NAME=()
    _ITEM_TAG=()

    local parent
    parent=$(dirname "$current")
    if [ -n "$parent" ] && [ "$parent" != "$current" ]; then
        _ITEM_PATH+=("$parent")
        _ITEM_NAME+=("..")
        _ITEM_TAG+=("")
    fi

    local _saved_ng _saved_dg
    _saved_ng=$(shopt -p nullglob)
    _saved_dg=$(shopt -p dotglob)
    shopt -s nullglob
    shopt -u dotglob

    # Bash pathname expansion is locale-sorted → no need for `sort`.
    local d name
    for d in "$current"/*/; do
        d="${d%/}"
        name="${d##*/}"
        _ITEM_PATH+=("$d")
        _ITEM_NAME+=("$name")
        _ITEM_TAG+=("$(get_project_tags "$d")")
    done

    eval "$_saved_ng"
    eval "$_saved_dg"
}

draw_browser() {
    local current="$1" sel="$2" scroll="$3" max_visible="$4"
    local count=${#_ITEM_PATH[@]}

    local tags
    tags=$(get_project_tags "$current")
    local is_project=false
    [ -n "$tags" ] && is_project=true

    # Cursor-home + clear-to-end-of-screen instead of `clear` — no flash.
    local out=$'\e[H\e[J\n'
    out+=$'  \e[36mCLAUDE CODE - Navigateur de projets\e[0m\n\n'
    out+="  "$'\e[90m'"$current"$'\e[0m\n'
    if $is_project; then
        out+="  "$'\e[32m['"$tags"$']\e[0m\n'
    fi
    out+=$'\n  \e[90m[^][v] naviguer  [Entree] ouvrir  [Retour] remonter\e[0m\n'
    if $is_project; then
        out+=$'  \e[90m[Espace] CHOISIR ce projet  [p] saisir chemin  [q] quitter\e[0m\n'
    else
        out+=$'  \e[90m[p] saisir chemin  [q] quitter\e[0m\n'
    fi
    out+=$'\n'

    if [ "$scroll" -gt 0 ]; then
        out+="  "$'\e[90m'"  ... ($scroll de plus au-dessus)"$'\e[0m\n'
    fi

    local end=$((scroll + max_visible))
    [ "$end" -gt "$count" ] && end=$count

    local i name tag suffix color prefix
    for (( i=scroll; i<end; i++ )); do
        name="${_ITEM_NAME[i]}"
        tag="${_ITEM_TAG[i]}"
        suffix=""
        [ -n "$tag" ] && suffix="  [$tag]"

        if [ "$i" -eq "$sel" ]; then
            prefix="> "
            [ -n "$tag" ] && color=$'\e[32m' || color=$'\e[37m'
        else
            prefix="  "
            [ -n "$tag" ] && color=$'\e[32m' || color=$'\e[90m'
        fi
        out+="  ${color}${prefix}${name}${suffix}"$'\e[0m\n'
    done

    local remaining=$((count - end))
    if [ "$remaining" -gt 0 ]; then
        out+="  "$'\e[90m'"  ... ($remaining de plus en-dessous)"$'\e[0m\n'
    fi

    # Single write — avoids partial-frame tearing between many echo calls.
    printf '%s' "$out"
}

browse_projects() {
    local current="$1"
    local sel=0
    local scroll=0
    local need_rebuild=true

    tput civis 2>/dev/null

    while true; do
        if $need_rebuild; then
            build_items "$current"
            need_rebuild=false
        fi

        local count=${#_ITEM_PATH[@]}
        [ "$sel" -ge "$count" ] && sel=$((count - 1))
        [ "$sel" -lt 0 ] && sel=0

        local parent
        parent=$(dirname "$current")

        local tags
        tags=$(get_project_tags "$current")
        local is_project=false
        [ -n "$tags" ] && is_project=true

        local term_h
        term_h=$(tput lines 2>/dev/null || echo 24)
        local header_size=9
        $is_project && header_size=10
        local max_visible=$((term_h - header_size - 2))
        [ "$max_visible" -lt 5 ] && max_visible=5

        [ "$sel" -lt "$scroll" ] && scroll=$sel
        [ "$sel" -ge $((scroll + max_visible)) ] && scroll=$((sel - max_visible + 1))

        draw_browser "$current" "$sel" "$scroll" "$max_visible"

        while true; do
            local redraw=false navigate=false
            IFS= read -rsn1 key
            case "$key" in
                $'\x1b')
                    read -rsn2 -t 0.1 seq
                    case "$seq" in
                        '[A'|'OA') # Up
                            sel=$(( (sel - 1 + count) % count ))
                            redraw=true
                            ;;
                        '[B'|'OB') # Down
                            sel=$(( (sel + 1) % count ))
                            redraw=true
                            ;;
                        '[D'|'OD') # Left — go to parent
                            if [ -n "$parent" ] && [ "$parent" != "$current" ]; then
                                current="$parent"
                                sel=0; scroll=0
                                need_rebuild=true; navigate=true
                            fi
                            ;;
                        '[C'|'OC') # Right — enter selected
                            local target="${_ITEM_PATH[$sel]}"
                            if [ -d "$target" ]; then
                                current="$target"
                                sel=0; scroll=0
                                need_rebuild=true; navigate=true
                            fi
                            ;;
                        '[H'|'OH') # Home
                            sel=0; redraw=true ;;
                        '[F'|'OF') # End
                            sel=$((count - 1)); redraw=true ;;
                        '[5') # PageUp (ESC [ 5 ~)
                            read -rsn1 -t 0.05 _tail
                            sel=$((sel - max_visible)); [ "$sel" -lt 0 ] && sel=0
                            redraw=true
                            ;;
                        '[6') # PageDown
                            read -rsn1 -t 0.05 _tail
                            sel=$((sel + max_visible)); [ "$sel" -ge "$count" ] && sel=$((count - 1))
                            redraw=true
                            ;;
                    esac
                    ;;
                "") # Enter — navigate into selected
                    local target="${_ITEM_PATH[$sel]}"
                    if [ -d "$target" ]; then
                        current="$target"
                        sel=0; scroll=0
                        need_rebuild=true; navigate=true
                    fi
                    ;;
                " ") # Space — select current as project
                    if $is_project; then
                        tput cnorm 2>/dev/null
                        SELECTED_PATH="$current"
                        return 0
                    fi
                    ;;
                $'\x7f'|$'\x08') # Backspace — parent
                    if [ -n "$parent" ] && [ "$parent" != "$current" ]; then
                        current="$parent"
                        sel=0; scroll=0
                        need_rebuild=true; navigate=true
                    fi
                    ;;
                q)
                    tput cnorm 2>/dev/null
                    return 1
                    ;;
                p) # Manual path entry
                    tput cnorm 2>/dev/null
                    printf '\e[H\e[J'
                    echo ""
                    echo -e "  \033[33mEntrez le chemin du projet :\033[0m"
                    read -rp "  " manual_path
                    if [ -n "$manual_path" ] && [ -d "$manual_path" ]; then
                        current=$(cd "$manual_path" && pwd)
                        sel=0; scroll=0
                        need_rebuild=true
                    elif [ -n "$manual_path" ]; then
                        echo -e "  \033[31mChemin invalide : $manual_path\033[0m"
                        sleep 1
                    fi
                    tput civis 2>/dev/null
                    navigate=true
                    ;;
            esac

            if $navigate; then
                break
            fi

            if $redraw; then
                [ "$sel" -lt "$scroll" ] && scroll=$sel
                [ "$sel" -ge $((scroll + max_visible)) ] && scroll=$((sel - max_visible + 1))
                draw_browser "$current" "$sel" "$scroll" "$max_visible"
            fi
        done
    done
}

# ── Resolve project path ────────────────────────────────────
EXPLICIT_PROJECT_PATH=""
if [ -z "$PROJECT_PATH" ]; then
    if [ ! -d "$SOURCES_ROOT" ]; then
        echo "Error: Sources root does not exist: $SOURCES_ROOT (check config.json)" >&2
        exit 1
    fi

    # Restaurer le terminal apres les appels cmd.exe :
    # stty sane remet les attributs, \e[?1l desactive le mode "application cursor keys"
    # (Ink/setup-token peut laisser le terminal en mode ou les fleches envoient \eOA au lieu de \e[A)
    stty sane 2>/dev/null
    printf '\e[?1l' 2>/dev/null

    SELECTED_PATH=""
    if browse_projects "$SOURCES_ROOT"; then
        PROJECT_PATH="$SELECTED_PATH"
    else
        echo "Cancelled."
        exit 0
    fi
else
    EXPLICIT_PROJECT_PATH="$PROJECT_PATH"
fi

PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"

# ── Compose wrapper (project-scoped to allow parallel containers) ──
dc() {
    docker compose -p "claude-${PROJECT_NAME}" "$@"
}

# ── Container functions ─────────────────────────────────────
new_container() {
    echo -e "  \033[36mMise a jour de l'image...\033[0m"
    dc build
    dc up -d --force-recreate claude-worker
    docker attach "claude-${PROJECT_NAME}"
}

# Wait for container removal to complete (docker rm -f returns before async cleanup finishes)
remove_container() {
    local name="$1"
    docker rm -f "$name" > /dev/null 2>&1 || true
    local retries=0
    while docker container inspect "$name" > /dev/null 2>&1; do
        retries=$((retries + 1))
        if [ "$retries" -ge 20 ]; then
            echo -e "  \033[31mErreur : le container $name n'a pas ete supprime apres 10s.\033[0m" >&2
            exit 1
        fi
        sleep 0.5
    done
}

start_existing() {
    local name="$1"
    local status
    status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)
    case "$status" in
        running)
            echo -e "  \033[32mRattachement au container en cours...\033[0m"
            echo ""
            docker attach "$name"
            ;;
        *)
            docker start -ai "$name"
            ;;
    esac
}

# ── Export for docker compose ────────────────────────────────
export PROJECT_PATH
export CLAUDE_HOME="${CLAUDE_HOME:-$HOME}"

# Ensure host .claude subdirectories exist (avoids Docker creating them as root)
for d in skills projects hooks plans sessions; do
    mkdir -p "${CLAUDE_HOME}/.claude/$d"
done
BASE_NAME=$(basename "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
export PROJECT_NAME="$BASE_NAME"

cd "$SCRIPT_DIR"

if [ -n "$PROMPT" ]; then
    export CLAUDE_ARGS="--dangerously-skip-permissions -p \"$PROMPT\""
elif [ "$REMOTE" = true ]; then
    export CLAUDE_ARGS="--dangerously-skip-permissions --remote-control $PROJECT_NAME"
else
    export CLAUDE_ARGS=""
fi

# Launch
clear
echo ""
echo -e "  \033[36mCLAUDE CODE CONTAINER\033[0m"
echo -e "  \033[32mProjet : $PROJECT_PATH\033[0m"
if [ -n "$PROMPT" ]; then
    _MODE_LABEL="non-interactif"
elif [ "$REMOTE" = true ]; then
    _MODE_LABEL="remote-control"
else
    _MODE_LABEL="interactif YOLO"
fi
echo -e "  \033[33mMode :   $_MODE_LABEL\033[0m"
echo ""

if [ "$BUILD" = true ]; then
    echo -e "  \033[36mConstruction de l'image Docker...\033[0m"
    dc build
fi

CONTAINER_NAME="claude-${BASE_NAME}"

# Check if container already exists
if ! docker container inspect "$CONTAINER_NAME" > /dev/null 2>&1; then
    # No existing container: build image and create
    new_container
elif [ -n "$PROMPT" ]; then
    # Non-interactive mode: reuse silently
    start_existing "$CONTAINER_NAME"
elif [ "$REMOTE" = true ]; then
    # Remote-control mode: recreate to apply new CLAUDE_ARGS
    echo -e "  \033[36mRecreation du container en mode remote-control...\033[0m"
    remove_container "$CONTAINER_NAME"
    new_container
else
    # Interactive mode: arrow-key menu
    STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
    EXIT_CODE=$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null)

    STATE_LABEL="$STATUS"
    [ "$STATUS" = "exited" ] && STATE_LABEL="arrete, code $EXIT_CODE"

    if [ "$STATUS" = "running" ]; then
        MENU_ITEMS=("Se rattacher au container en cours" "Ecraser (supprimer et recreer)" "Nouveau container (claude-$BASE_NAME-xxxx)" "Revenir en arriere")
    else
        MENU_ITEMS=("Reutiliser le container" "Ecraser (supprimer et recreer)" "Nouveau container (claude-$BASE_NAME-xxxx)" "Revenir en arriere")
    fi
    MENU_COLORS=($'\e[32m' $'\e[33m' $'\e[33m' $'\e[90m')
    SEL=0

    # Hide cursor
    tput civis 2>/dev/null

    # Buffered single-write redraw (cursor-home, no clear flash).
    draw_container_menu() {
        local out=$'\e[H\e[J\n'
        out+=$'  \e[36mCLAUDE CODE CONTAINER\e[0m\n'
        out+="  "$'\e[32m'"Projet : $PROJECT_PATH"$'\e[0m\n'
        out+=$'  \e[33mMode :   interactif YOLO\e[0m\n\n'
        out+="  "$'\e[33m'"Container existant : $CONTAINER_NAME ($STATE_LABEL)"$'\e[0m\n\n'
        out+=$'  \e[90m[^][v] naviguer  [Entree] valider  [q] quitter\e[0m\n\n'
        local i
        for i in "${!MENU_ITEMS[@]}"; do
            if [ "$i" -eq "$SEL" ]; then
                out+="  ${MENU_COLORS[$i]}> ${MENU_ITEMS[$i]}"$'\e[0m\n'
            else
                out+="  "$'\e[90m'"  ${MENU_ITEMS[$i]}"$'\e[0m\n'
            fi
        done
        printf '%s' "$out"
    }

    draw_container_menu

    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq
                case "$seq" in
                    '[A'|'OA') SEL=$(( (SEL - 1 + ${#MENU_ITEMS[@]}) % ${#MENU_ITEMS[@]} )); draw_container_menu ;;
                    '[B'|'OB') SEL=$(( (SEL + 1) % ${#MENU_ITEMS[@]} )); draw_container_menu ;;
                    '[H'|'OH') SEL=0; draw_container_menu ;;
                    '[F'|'OF') SEL=$(( ${#MENU_ITEMS[@]} - 1 )); draw_container_menu ;;
                esac
                ;;
            q) tput cnorm 2>/dev/null; echo ""; echo "  Annule."; exit 0 ;;
            "") break ;;  # Enter
        esac
    done

    # Show cursor
    tput cnorm 2>/dev/null
    echo ""

    case "$SEL" in
        0)
            # Reuse / attach
            if [ "$STATUS" = "exited" ] && [ "$EXIT_CODE" != "0" ]; then
                echo -e "  \033[31mContainer en erreur (exit code $EXIT_CODE) : recreation...\033[0m"
                remove_container "$CONTAINER_NAME"
                new_container
            elif [ "$STATUS" = "dead" ] || [ "$STATUS" = "created" ] || [ "$STATUS" = "paused" ]; then
                echo -e "  \033[31mContainer en etat '$STATUS' : recreation...\033[0m"
                remove_container "$CONTAINER_NAME"
                new_container
            else
                start_existing "$CONTAINER_NAME"
            fi
            ;;
        1)
            # Replace
            echo -e "  \033[31mSuppression de $CONTAINER_NAME...\033[0m"
            remove_container "$CONTAINER_NAME"
            new_container
            ;;
        2)
            # New with salt
            SALT=$(printf '%04x' $RANDOM)
            export PROJECT_NAME="${BASE_NAME}-${SALT}"
            NEW_NAME="claude-${PROJECT_NAME}"
            echo -e "  \033[36mCreation de $NEW_NAME...\033[0m"
            new_container
            ;;
        3)
            # Go back
            if [ -n "${EXPLICIT_PROJECT_PATH:-}" ]; then
                echo "  Annule."
                exit 0
            fi
            SELECTED_PATH=""
            if browse_projects "$SOURCES_ROOT"; then
                PROJECT_PATH="$SELECTED_PATH"
                PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"
                export PROJECT_PATH
                BASE_NAME=$(basename "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
                export PROJECT_NAME="$BASE_NAME"
                exec "$0" "$PROJECT_PATH" $([ -n "$PROMPT" ] && echo "--prompt" && echo "$PROMPT")
            else
                echo "  Annule."
                exit 0
            fi
            ;;
    esac
fi
