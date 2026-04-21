#!/bin/bash
# Hook PreToolUse: blocks reading sensitive files without explicit user authorization
# Exit code 2 = BLOCK the action

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
SEARCH_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty')
GLOB_FILTER=$(echo "$INPUT" | jq -r '.tool_input.glob // empty')

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

# --- Helper: check if a file is gitignored ---
is_gitignored() {
    local filepath="$1"
    # Only check if we're in a git repo with a .gitignore
    if [ -f /project/.gitignore ] && [ -d /project/.git ]; then
        # git check-ignore returns 0 if the file IS ignored
        git -C /project check-ignore -q "$filepath" 2>/dev/null
        return $?
    fi
    return 1
}

# --- Helper: check a path against sensitive basename patterns + gitignore ---
# Echoes block message and exits 2 if the path is sensitive.
check_path() {
    local filepath="$1"
    [ -z "$filepath" ] && return 0
    local basename
    basename=$(basename "$filepath")
    for pat in "${SENSITIVE_PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$basename" == $pat ]]; then
            echo "$BLOCK_MSG" >&2
            exit 2
        fi
    done
    if is_gitignored "$filepath"; then
        echo "$GITIGNORE_MSG" >&2
        exit 2
    fi
}

# --- Read/Edit/Write: check the target file path ---
if [[ "$TOOL_NAME" =~ ^(Read|Edit|Write)$ ]]; then
    check_path "$FILE_PATH"
fi

# --- Grep/Glob: check search pattern, the path param, and the glob filter ---
if [[ "$TOOL_NAME" =~ ^(Grep|Glob)$ ]]; then
    if [ -n "$PATTERN" ] && echo "$PATTERN" | grep -qEi "$SENSITIVE_KEYWORDS"; then
        echo "$BLOCK_MSG" >&2
        exit 2
    fi
    if [ -n "$GLOB_FILTER" ] && echo "$GLOB_FILTER" | grep -qEi "$SENSITIVE_KEYWORDS"; then
        echo "$BLOCK_MSG" >&2
        exit 2
    fi
    # Glob/Grep path is a directory most of the time, but can point at a file
    # Only call check_path if it's an actual file (basename match remains valid for dirs too)
    check_path "$SEARCH_PATH"
fi

# --- Bash: scan command string for sensitive keywords ---
if [[ "$TOOL_NAME" == "Bash" && -n "$COMMAND" ]]; then
    if echo "$COMMAND" | grep -qEi "$SENSITIVE_KEYWORDS"; then
        echo "$BLOCK_MSG" >&2
        exit 2
    fi
fi

exit 0
