#!/bin/bash
# Hook PreToolUse: blocks reading sensitive files without explicit user authorization
# Exit code 2 = BLOCK the action.
#
# Performance: tous les champs d'entrée extraits en un seul appel jq (au lieu de
# 6 séparés). Sur 200 tool calls par session, économie ~5-8s cumulés.

INPUT=$(cat)

# Single jq extracts all the fields we may need, tab-separated.
# A trailing sentinel guarantees every field has a defined position.
{ IFS=$'\t' read -r TOOL_NAME FILE_PATH SEARCH_PATH COMMAND PATTERN GLOB_FILTER _SENTINEL; } < <(
    jq -r '[
        .tool_name // "",
        .tool_input.file_path // "",
        .tool_input.path // "",
        .tool_input.command // "",
        .tool_input.pattern // "",
        .tool_input.glob // "",
        "END"
    ] | @tsv' <<< "$INPUT"
)

# Sensitive file basename patterns (glob-style, matched against basename of file_path)
SENSITIVE_PATTERNS=(
    # .NET configuration
    "appsettings*.json"
    "secrets.json"
    "usersecrets.json"
    "web.config"
    "app.config"
    # Environment files
    ".env"
    ".env.*"
    # Certificates and private keys
    "*.pfx"
    "*.p12"
    "*.pem"
    "*.key"
    "*.keystore"
    "*.jks"
    # SSH keys
    "id_rsa*"
    "id_ed25519*"
    "id_ecdsa*"
    "id_dsa*"
    # Package manager auth
    ".npmrc"
    ".pypirc"
    "NuGet.Config"
    # Cloud / service accounts
    "serviceAccountKey*.json"
    # Generic credential/secret files
    "*credential*.json"
    "*secret*.json"
    "*credentials.json"
    "*token*.json"
)

# Regex for keyword detection in Grep/Glob patterns and Bash commands
SENSITIVE_KEYWORDS='appsettings.*\.json|secrets\.json|usersecrets|web\.config|app\.config|\.env\b|\.pfx|\.p12|\.pem\b|\.key\b|\.keystore|\.jks|id_rsa|id_ed25519|id_ecdsa|id_dsa|\.npmrc|\.pypirc|NuGet\.Config|serviceAccountKey|credential.*\.json|secret.*\.json|token.*\.json'

BLOCK_MSG="BLOCKED: This file may contain secrets (keys, tokens, connection strings). Ask the user before accessing it."
GITIGNORE_MSG="BLOCKED: This file is listed in .gitignore (likely contains environment-specific or sensitive data). Ask the user before accessing it."

# Suffixes that mark a file as a public template/example (versioned, no real secrets).
TEMPLATE_SUFFIXES='(\.example|\.sample|\.template|\.dist|\.tpl|\.tmpl|-example|-sample|-template)'

# Whitelist : fichiers/dossiers gitignored qui ne sont PAS sensibles (rebuilds,
# caches, config locale, etc.). La whitelist agit UNIQUEMENT sur la check gitignore,
# JAMAIS sur la check des patterns sensibles ci-dessus : .env reste bloqué même
# s'il matche un préfixe de cette liste.
GITIGNORE_WHITELIST_REGEX='(^|/)(\.claude/[^/]+\.(json|md)|[^/]+\.local\.[^/]+|node_modules|dist|build|out|coverage|\.next|\.nuxt|\.vite|\.svelte-kit|\.cache|\.parcel-cache|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|target/(debug|release)|bin/(Debug|Release)|obj/(Debug|Release)|\.idea|\.vscode/[^/]+\.json)(/|$)'

# Returns 0 if the basename ends with a template suffix
is_template_file() {
    local bn="$1"
    [[ "$bn" =~ ${TEMPLATE_SUFFIXES}$ ]] && return 0
    [[ "$bn" =~ ${TEMPLATE_SUFFIXES}\.[A-Za-z0-9]+$ ]] && return 0
    return 1
}

# Returns 0 if the path matches the gitignore whitelist (= safe to access despite gitignore)
is_whitelisted_gitignore() {
    [[ "$1" =~ $GITIGNORE_WHITELIST_REGEX ]]
}

# --- Helper: check if a file is gitignored ---
is_gitignored() {
    local filepath="$1"
    if [ -f /project/.gitignore ] && [ -d /project/.git ]; then
        git -C /project check-ignore -q "$filepath" 2>/dev/null
        return $?
    fi
    return 1
}

# --- Helper: check a path against sensitive basename patterns + gitignore ---
check_path() {
    local filepath="$1"
    [ -z "$filepath" ] && return 0
    local basename
    basename=$(basename "$filepath")
    # Whitelist template/example files (.env.example, secrets.template.json, etc.)
    if is_template_file "$basename"; then
        return 0
    fi
    for pat in "${SENSITIVE_PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$basename" == $pat ]]; then
            echo "$BLOCK_MSG" >&2
            exit 2
        fi
    done
    # Gitignore check : skippée si le chemin est dans la whitelist
    if is_whitelisted_gitignore "$filepath"; then
        return 0
    fi
    if is_gitignored "$filepath"; then
        echo "$GITIGNORE_MSG" >&2
        exit 2
    fi
}

# --- Read/Edit/Write: check the target file path ---
if [[ "$TOOL_NAME" =~ ^(Read|Edit|Write)$ ]]; then
    check_path "$FILE_PATH"
fi

# Strip occurrences that are explicitly template/example references so the keyword
# scan below doesn't block `cat .env.example` or `grep -r '.env.sample' .`
strip_templates() {
    sed -E 's/(\.env|appsettings[^[:space:]]*|secrets[^[:space:]]*|usersecrets|web\.config|app\.config|NuGet\.Config|\.npmrc|\.pypirc|credential[^[:space:]]*|secret[^[:space:]]*|token[^[:space:]]*|serviceAccountKey[^[:space:]]*)(\.example|\.sample|\.template|\.dist|\.tpl|\.tmpl|-example|-sample|-template)(\.[A-Za-z0-9]+)?//gi'
}

# --- Grep/Glob: check search pattern, the path param, and the glob filter ---
if [[ "$TOOL_NAME" =~ ^(Grep|Glob)$ ]]; then
    if [ -n "$PATTERN" ] && echo "$PATTERN" | strip_templates | grep -qEi "$SENSITIVE_KEYWORDS"; then
        echo "$BLOCK_MSG" >&2
        exit 2
    fi
    if [ -n "$GLOB_FILTER" ] && echo "$GLOB_FILTER" | strip_templates | grep -qEi "$SENSITIVE_KEYWORDS"; then
        echo "$BLOCK_MSG" >&2
        exit 2
    fi
    check_path "$SEARCH_PATH"
fi

# --- Bash: scan command string for sensitive keywords ---
if [[ "$TOOL_NAME" == "Bash" && -n "$COMMAND" ]]; then
    if echo "$COMMAND" | strip_templates | grep -qEi "$SENSITIVE_KEYWORDS"; then
        echo "$BLOCK_MSG" >&2
        exit 2
    fi
fi

exit 0
