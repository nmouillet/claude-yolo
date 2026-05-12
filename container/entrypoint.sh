#!/bin/bash
set -e

# Persistent user config directory (shared Docker volume across all projects)
CONFIG_DIR="/home/claude/.claude/user-config"

# ── Root init: fix volume ownership, install .NET SDKs, then drop to claude user ──
if [ "$(id -u)" = "0" ]; then
    # Fix ownership on shared config volume (may be created as root)
    if [ -d "$CONFIG_DIR" ] && [ "$(stat -c '%U' "$CONFIG_DIR" 2>/dev/null)" != "claude" ]; then
        chown -R claude:claude "$CONFIG_DIR"
    fi
    if [ "$(stat -c '%U' /home/claude/.claude/mcp-memory 2>/dev/null)" != "claude" ]; then
        chown -R claude:claude /home/claude/.claude/mcp-memory
    fi
    # Skills overlay volume (per-project) may be created as root on first mount
    if [ -d /home/claude/.claude/skills ] \
       && [ "$(stat -c '%U' /home/claude/.claude/skills 2>/dev/null)" != "claude" ]; then
        chown -R claude:claude /home/claude/.claude/skills
    fi
    # RTK analytics volume (~/.config/rtk shared across all projects)
    if [ -d /home/claude/.config/rtk ] \
       && [ "$(stat -c '%U' /home/claude/.config/rtk 2>/dev/null)" != "claude" ]; then
        chown -R claude:claude /home/claude/.config/rtk
    fi
    # Claude Code binary store volume (empty named volume -> seeded from image,
    # ownership may be root on first mount)
    if [ -d /home/claude/.local/share/claude ] \
       && [ "$(stat -c '%U' /home/claude/.local/share/claude 2>/dev/null)" != "claude" ]; then
        chown -R claude:claude /home/claude/.local/share/claude
    fi
    # npm cache volume (same first-mount ownership issue)
    if [ -d /home/claude/.npm ] \
       && [ "$(stat -c '%U' /home/claude/.npm 2>/dev/null)" != "claude" ]; then
        chown -R claude:claude /home/claude/.npm
    fi
    # Bind-mounted host dirs: Claude Code rewrites files in-place (projects/*.jsonl
    # during /compact, sessions, etc). Files left over from older runs with a different
    # UID (e.g. pre-gosu root runs) break rewrites with EACCES. Scan and fix mismatches.
    # Note: skills/ is now per-container (overlay), host-skills/ is the bind mount.
    for _d in projects host-skills plans sessions hooks; do
        _path="/home/claude/.claude/$_d"
        [ -d "$_path" ] && find "$_path" \( ! -user claude -o ! -group claude \) \
            -exec chown claude:claude {} + 2>/dev/null || true
    done

    # Authentication priority: base64 credentials > host file > env var token > persistent volume > manual login
    CRED_FILE="/home/claude/.claude/.credentials.json"
    CRED_ALT="/home/claude/.claude/credentials/.credentials.json"
    AUTH_STATUS="none"

    if [ -n "${CLAUDE_CREDENTIALS_B64:-}" ]; then
        # Full credentials JSON (base64 encoded, includes scopes + refreshToken)
        TMP_CRED=$(mktemp)
        if echo "$CLAUDE_CREDENTIALS_B64" | base64 -d > "$TMP_CRED" 2>/dev/null \
           && jq -e '.claudeAiOauth.accessToken' "$TMP_CRED" > /dev/null 2>&1; then
            mv "$TMP_CRED" "$CRED_FILE"
            AUTH_STATUS="base64"
        else
            rm -f "$TMP_CRED"
            echo "  [WARN] CLAUDE_CREDENTIALS_B64 invalide (base64 ou JSON malforme) - ignore"
        fi
    fi
    if [ "$AUTH_STATUS" = "none" ] && [ -f /home/claude/.claude/host-credentials.json ] \
       && [ -s /home/claude/.claude/host-credentials.json ] \
       && jq -e '.claudeAiOauth.accessToken' /home/claude/.claude/host-credentials.json > /dev/null 2>&1; then
        # Full host credentials file (mounted from host)
        cp /home/claude/.claude/host-credentials.json "$CRED_FILE"
        AUTH_STATUS="host-mount"
    fi
    if [ "$AUTH_STATUS" = "none" ] && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        # Bare token fallback (CI) - no refreshToken: token won't auto-renew
        EXPIRY=$(date -d "+365 days" +%s)000
        jq -n --arg token "$CLAUDE_CODE_OAUTH_TOKEN" --arg exp "$EXPIRY" \
            '{claudeAiOauth: {
                accessToken: $token,
                expiresAt: ($exp | tonumber),
                scopes: ["org:create_api_key","user:profile","user:inference","user:sessions:claude_code","user:mcp_servers","user:file_upload"]
            }}' \
            > "$CRED_FILE"
        AUTH_STATUS="env-token"
        echo "  [WARN] Token seul (CLAUDE_CODE_OAUTH_TOKEN) - pas de refreshToken, pas d'auto-refresh"
    fi
    if [ "$AUTH_STATUS" = "none" ] && [ -f "$CONFIG_DIR/credentials.json" ] \
       && [ -s "$CONFIG_DIR/credentials.json" ] \
       && jq -e '.claudeAiOauth.accessToken' "$CONFIG_DIR/credentials.json" > /dev/null 2>&1; then
        cp "$CONFIG_DIR/credentials.json" "$CRED_FILE"
        AUTH_STATUS="volume"
    fi

    # Write credentials to BOTH known paths (Claude Code may use either)
    if [ "$AUTH_STATUS" != "none" ] && [ -f "$CRED_FILE" ] && [ -s "$CRED_FILE" ]; then
        mkdir -p "$(dirname "$CRED_ALT")"
        cp "$CRED_FILE" "$CRED_ALT"
        chown claude:claude "$CRED_FILE" "$CRED_ALT"
        chmod 600 "$CRED_FILE" "$CRED_ALT"
        cp "$CRED_FILE" "$CONFIG_DIR/credentials.json" 2>/dev/null || true
        echo "  [OK] Credentials ($AUTH_STATUS) -> .credentials.json + credentials/.credentials.json"
    else
        # Explain which sources were checked so the user knows where to fix the issue
        echo "  [WARN] Pas de credentials - login requis. Sources verifiees :"
        [ -n "${CLAUDE_CREDENTIALS_B64:-}" ] \
            && echo "           - CLAUDE_CREDENTIALS_B64 (defini mais invalide ou JSON malforme)" \
            || echo "           - CLAUDE_CREDENTIALS_B64 (non defini)"
        if [ -f /home/claude/.claude/host-credentials.json ] && [ -s /home/claude/.claude/host-credentials.json ]; then
            echo "           - /home/claude/.claude/host-credentials.json (present mais accessToken absent)"
        else
            echo "           - /home/claude/.claude/host-credentials.json (non monte - HOST_CREDENTIALS_PATH manquant)"
        fi
        [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
            && echo "           - CLAUDE_CODE_OAUTH_TOKEN (defini mais rejete)" \
            || echo "           - CLAUDE_CODE_OAUTH_TOKEN (non defini)"
        if [ -f "$CONFIG_DIR/credentials.json" ] && [ -s "$CONFIG_DIR/credentials.json" ]; then
            echo "           - $CONFIG_DIR/credentials.json (present mais invalide)"
        else
            echo "           - $CONFIG_DIR/credentials.json (volume vide - premier lancement ?)"
        fi
    fi

    # Save auth status for diagnostic after attach
    echo "$AUTH_STATUS" > /tmp/.claude-auth-status

    # Symlink claude into standard PATH (docker exec always finds it)
    ln -sf /home/claude/.local/bin/claude /usr/local/bin/claude 2>/dev/null || true
    # Dynamic .NET SDK installation based on mounted project
    /usr/local/bin/install-dotnet.sh

    # NuGet: process host config and set up credentials for private feeds
    NUGET_DIR="/home/claude/.nuget/NuGet"
    mkdir -p "$NUGET_DIR"

    if [ -f /home/claude/.nuget-host/NuGet.Config ] && [ -s /home/claude/.nuget-host/NuGet.Config ]; then
        # Copy and strip DPAPI-encrypted credentials (Windows-only, useless on Linux)
        sed '/<packageSourceCredentials>/,/<\/packageSourceCredentials>/d' \
            /home/claude/.nuget-host/NuGet.Config > "$NUGET_DIR/NuGet.Config"

        if [ -n "${NUGET_PRIVATE_FEED_PAT:-}" ]; then
            # Add cleartext PAT credentials for each non-nuget.org source
            while IFS= read -r line; do
                name=$(echo "$line" | sed -n 's/^[[:space:]]*[0-9]*\.[[:space:]]*\(.*\) \[Enabled\].*/\1/p')
                if [ -n "$name" ] && [ "$name" != "nuget.org" ]; then
                    dotnet nuget update source "$name" \
                        --username "pat" --password "$NUGET_PRIVATE_FEED_PAT" \
                        --store-password-in-clear-text \
                        --configfile "$NUGET_DIR/NuGet.Config" 2>/dev/null || true
                fi
            done < <(dotnet nuget list source --configfile "$NUGET_DIR/NuGet.Config" 2>/dev/null)
            echo "  [OK] NuGet config + credentials PAT pour les feeds prives"
        else
            echo "  [OK] NuGet config copiee (feeds publics uniquement)"
            echo "         Pour les feeds prives : NUGET_PRIVATE_FEED_PAT dans .env"
        fi
        chown claude:claude "$NUGET_DIR/NuGet.Config"
        chmod 600 "$NUGET_DIR/NuGet.Config"
    else
        echo "  [INFO] Pas de NuGet.Config hote"
    fi

    # Fix ownership on NuGet cache volume
    if [ -d /home/claude/.nuget ]; then
        chown -R claude:claude /home/claude/.nuget
    fi

    exec gosu claude "$0" "$@"
fi

# Ensure .claude subdirectories exist
mkdir -p /home/claude/.claude/skills \
         /home/claude/.claude/host-skills \
         /home/claude/.claude/projects \
         /home/claude/.claude/sessions \
         /home/claude/.claude/plans \
         /home/claude/.claude/hooks \
         /home/claude/.claude/commands \
         /home/claude/.claude/agents \
         /home/claude/.claude/output-styles \
         /home/claude/.claude/container-hooks \
         /home/claude/.claude/mcp-memory \
         /home/claude/.claude/credentials \
         "$CONFIG_DIR"

# ── Skills overlay : populate per-container skills/ with symlinks to host-skills ──
# Real directories (added mid-session via /skill add) are preserved; only stale
# symlinks are pruned. apply-project-config.sh later prunes symlinks NOT in the
# per-project selection. Default (no project config) keeps all skills enabled.
SKILLS_DIR="/home/claude/.claude/skills"
HOST_SKILLS_DIR="/home/claude/.claude/host-skills"
if [ -d "$HOST_SKILLS_DIR" ]; then
    # Drop stale symlinks (might point at removed host skills); keep real dirs.
    find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type l -delete 2>/dev/null || true
    _n_linked=0
    for _skill in "$HOST_SKILLS_DIR"/*/; do
        [ -d "$_skill" ] || continue
        _name=$(basename "$_skill")
        # Don't shadow a real dir already in skills/ (user-added skill not yet captured)
        [ -e "$SKILLS_DIR/$_name" ] && continue
        ln -s "$_skill" "$SKILLS_DIR/$_name" 2>/dev/null && _n_linked=$((_n_linked + 1))
    done
    echo "  [OK] Skills overlay : $_n_linked symlinks vers host-skills"
fi

# ── Auth diagnostic (visible after docker attach connects) ──
_AUTH_STATUS=$(cat /tmp/.claude-auth-status 2>/dev/null || echo "unknown")
CRED_FILE="/home/claude/.claude/.credentials.json"
if [ -f "$CRED_FILE" ] && [ -s "$CRED_FILE" ]; then
    _TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED_FILE" 2>/dev/null)
    _SCOPES=$(jq -r '.claudeAiOauth.scopes // [] | length' "$CRED_FILE" 2>/dev/null)
    _HAS_REFRESH=$(jq -r 'if .claudeAiOauth.refreshToken then "oui" else "non" end' "$CRED_FILE" 2>/dev/null)
    echo -e "  \033[32m[AUTH] Credentials OK (source: $_AUTH_STATUS, scopes: $_SCOPES, refresh: $_HAS_REFRESH)\033[0m"
    # Only export CLAUDE_CODE_OAUTH_TOKEN for bare-token CI fallback.
    # When full credentials file exists, leave the env var unset so Claude Code
    # reads the file directly with full scopes (required for Remote Control).
    if [ -n "$_TOKEN" ] && [ "$_AUTH_STATUS" = "env-token" ]; then
        export CLAUDE_CODE_OAUTH_TOKEN="$_TOKEN"
    fi
else
    echo -e "  \033[31m[AUTH] PAS DE CREDENTIALS - Claude demandera un login\033[0m"
fi

# ── Settings : merge persistent prefs + host settings + container config (hooks + statusline) ──
CONTAINER_CONFIG='{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Edit|Write|Grep|Glob|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/home/claude/.claude/container-hooks/protect-config.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/claude/.claude/container-hooks/git-context.sh"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "/home/claude/.claude/statusline.sh"
  },
  "forceLoginMethod": "claudeai"
}'

# RTK (Rust Token Killer): append a second PreToolUse hook on Bash that rewrites
# commands to their `rtk <cmd>` equivalent. The hook is `rtk hook claude` (native
# subcommand of the rtk binary, not a separate script). Order matters: protect-config
# runs first (can block via exit 2); rtk hook then transforms tool_input if allowed.
if [ "${CLAUDE_DISABLE_RTK:-false}" != "true" ] && command -v rtk &> /dev/null; then
    CONTAINER_CONFIG=$(echo "$CONTAINER_CONFIG" | jq '.hooks.PreToolUse += [{
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "rtk hook claude"}]
    }]')
    echo "  [SETUP] RTK actif (token-killer hook enregistre sur Bash)"
else
    echo "  [SETUP] RTK desactive (CLAUDE_DISABLE_RTK=${CLAUDE_DISABLE_RTK:-false})"
fi

# Build settings.json: defaults < persistent user prefs < host settings < container hooks
# Container hooks always win (immutable). Defaults fill the gap when neither user prefs nor host set a value.
# Do NOT default `model` here: the literal string "default" is not a valid model identifier
# (valid values are aliases like sonnet/opus/haiku or full IDs). Leave it unset so Claude Code
# uses its built-in default selection.
DEFAULT_SETTINGS='{}'
SETTINGS_BASE="$DEFAULT_SETTINGS"
if [ -f "$CONFIG_DIR/user-settings.json" ] && [ -s "$CONFIG_DIR/user-settings.json" ] && [ "${CLAUDE_FORCE_RESEED:-}" != "true" ]; then
    # Strip any legacy `model: "default"` written by older entrypoint versions
    SETTINGS_BASE=$(jq -s '.[0] * (.[1] | if .model == "default" then del(.model) else . end)' \
        <(echo "$DEFAULT_SETTINGS") "$CONFIG_DIR/user-settings.json")
    echo "  [OK] Preferences settings restaurees depuis le volume"
fi

if [ -f /home/claude/.claude/host-settings.json ]; then
    # Strip host hooks that can't run in Linux (Windows paths C:\, .exe binaries, powershell)
    HOST_SETTINGS_FILTERED=$(jq '
      if .hooks then
        .hooks |= (
          with_entries(
            .value |= (
              map(.hooks |= map(select((.command // "") | test("\\b[A-Za-z]:[/\\\\]|\\.exe\\b|\\bpowershell\\b"; "i") | not)))
              | map(select(.hooks | length > 0))
            )
          )
          | with_entries(select(.value | length > 0))
        )
      else . end
    ' /home/claude/.claude/host-settings.json)
    _N_BEFORE=$(jq '[.hooks // {} | .[] | .[] | .hooks[]] | length' /home/claude/.claude/host-settings.json 2>/dev/null || echo 0)
    _N_AFTER=$(echo "$HOST_SETTINGS_FILTERED" | jq '[.hooks // {} | .[] | .[] | .hooks[]] | length' 2>/dev/null || echo 0)
    if [ "${_N_BEFORE:-0}" -gt "${_N_AFTER:-0}" ]; then
        echo "  [OK] $((_N_BEFORE - _N_AFTER)) hook(s) Windows hote filtre(s) (chemins C:\\, .exe, powershell)"
    fi

    jq -s '.[0] * .[1] * .[2]' \
        <(echo "$SETTINGS_BASE") \
        <(echo "$HOST_SETTINGS_FILTERED") \
        <(echo "$CONTAINER_CONFIG") \
        > /home/claude/.claude/settings.json
else
    jq -s '.[0] * .[1]' \
        <(echo "$SETTINGS_BASE") \
        <(echo "$CONTAINER_CONFIG") \
        > /home/claude/.claude/settings.json
fi

# ── MCP Servers : build .claude.json with MCP configurations ──
# Use direct binaries (installed globally in the image, see Dockerfile section 5d)
# instead of `npx -y <pkg>`: saves ~1-3s per server at session startup (no registry
# revalidation, no extra Node spawn).
#
# `filesystem` and `memory` MCPs are intentionally NOT registered:
#  - filesystem: Read/Edit/Write/Grep/Glob native tools cover this scope already
#  - memory: superseded by the file-based auto-memory system at
#    /home/claude/.claude/projects/-project/memory/
# Set MCP_ENABLE_FILESYSTEM=true / MCP_ENABLE_MEMORY=true to re-enable.
MCP_SERVERS='{
  "mcpServers": {
    "fetch": {
      "command": "uvx",
      "args": ["mcp-server-fetch"]
    },
    "sequential-thinking": {
      "command": "mcp-server-sequential-thinking"
    },
    "context7": {
      "command": "context7-mcp"
    }
  }
}'

if [ "${MCP_ENABLE_FILESYSTEM:-false}" = "true" ]; then
    FS_SERVER='{
      "mcpServers": {
        "filesystem": {
          "command": "mcp-server-filesystem",
          "args": ["/project"]
        }
      }
    }'
    MCP_SERVERS=$(echo "$MCP_SERVERS" "$FS_SERVER" | jq -s '.[0] * .[1]')
fi

if [ "${MCP_ENABLE_MEMORY:-false}" = "true" ]; then
    MEM_SERVER='{
      "mcpServers": {
        "memory": {
          "command": "mcp-server-memory",
          "env": {
            "MEMORY_FILE_PATH": "/home/claude/.claude/mcp-memory/memory.json"
          }
        }
      }
    }'
    MCP_SERVERS=$(echo "$MCP_SERVERS" "$MEM_SERVER" | jq -s '.[0] * .[1]')
fi

# Conditionally add Brave Search MCP (only if BRAVE_API_KEY is set)
if [ -n "${BRAVE_API_KEY:-}" ]; then
    BRAVE_SERVER=$(jq -n --arg key "$BRAVE_API_KEY" '{
      "mcpServers": {
        "brave-search": {
          "command": "brave-search-mcp-server",
          "env": {
            "BRAVE_API_KEY": $key
          }
        }
      }
    }')
    MCP_SERVERS=$(echo "$MCP_SERVERS" "$BRAVE_SERVER" | jq -s '.[0] * .[1]')
fi

# Conditionally add Playwright MCP (only if chromium is installed)
if command -v chromium &> /dev/null; then
    PLAYWRIGHT_SERVER='{
      "mcpServers": {
        "playwright": {
          "command": "playwright-mcp",
          "args": ["--headless"]
        }
      }
    }'
    MCP_SERVERS=$(echo "$MCP_SERVERS" "$PLAYWRIGHT_SERVER" | jq -s '.[0] * .[1]')
fi

# Conditionally add GitHub MCP (only if GITHUB_TOKEN is set)
if [ -n "${GITHUB_TOKEN:-}" ]; then
    # Try Go binary first, fall back to global npm binary
    if [ -f /usr/local/bin/github-mcp-server ] && [ -x /usr/local/bin/github-mcp-server ]; then
        GITHUB_SERVER=$(jq -n --arg token "$GITHUB_TOKEN" '{
          "mcpServers": {
            "github": {
              "command": "/usr/local/bin/github-mcp-server",
              "env": {
                "GITHUB_PERSONAL_ACCESS_TOKEN": $token
              }
            }
          }
        }')
    else
        GITHUB_SERVER=$(jq -n --arg token "$GITHUB_TOKEN" '{
          "mcpServers": {
            "github": {
              "command": "mcp-server-github",
              "env": {
                "GITHUB_PERSONAL_ACCESS_TOKEN": $token
              }
            }
          }
        }')
    fi
    MCP_SERVERS=$(echo "$MCP_SERVERS" "$GITHUB_SERVER" | jq -s '.[0] * .[1]')
fi

# Conditionally add DBHub MCP (only if DATABASE_URL is set)
if [ -n "${DATABASE_URL:-}" ]; then
    DBHUB_SERVER=$(jq -n --arg dsn "$DATABASE_URL" '{
      "mcpServers": {
        "dbhub": {
          "command": "dbhub",
          "args": ["--dsn", $dsn]
        }
      }
    }')
    MCP_SERVERS=$(echo "$MCP_SERVERS" "$DBHUB_SERVER" | jq -s '.[0] * .[1]')
fi

# Conditionally add Docker MCP (only if Docker socket is accessible)
if [ -S /var/run/docker.sock ]; then
    DOCKER_SERVER='{
      "mcpServers": {
        "docker": {
          "command": "mcp-server-docker"
        }
      }
    }'
    MCP_SERVERS=$(echo "$MCP_SERVERS" "$DOCKER_SERVER" | jq -s '.[0] * .[1]')
fi

# Build .claude.json: MCP servers < persistent user prefs < host .claude.json
# Host always wins. Persistent prefs (theme, etc.) fill the gap when host has none.
# Default prefs skip the first-run wizard (onboarding, bypass-mode confirmation,
# trust dialog on /project, tips, etc.) so a fresh container never replays the setup.
DEFAULT_PREFS='{
  "theme": "dark",
  "numStartups": 100,
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true,
  "hasTrustDialogsShown": true,
  "hasAvailableSubscription": true,
  "tipsHistory": {},
  "projects": {
    "/project": {
      "hasTrustDialogAccepted": true,
      "hasClaudeMdExternalIncludesApproved": true,
      "hasClaudeMdExternalIncludesWarningShown": true,
      "allowedTools": [],
      "history": []
    }
  }
}'

PREFS_BASE="$DEFAULT_PREFS"
if [ -f "$CONFIG_DIR/user-preferences.json" ] && [ -s "$CONFIG_DIR/user-preferences.json" ] && [ "${CLAUDE_FORCE_RESEED:-}" != "true" ]; then
    # Merge: defaults < saved prefs (saved prefs override defaults)
    PREFS_BASE=$(echo "$DEFAULT_PREFS" "$(cat "$CONFIG_DIR/user-preferences.json")" | jq -s '.[0] * .[1]')
    echo "  [OK] Preferences utilisateur restaurees depuis le volume"
fi

if [ -f /home/claude/.claude/host-claude.json ]; then
    # Filtrer host-claude.json : drop les caches volumineux et les projets non-/project.
    # Le fichier hôte fait 37 KB dont 17 KB de cachedGrowthBookFeatures (flags Anthropic
    # internes, pas utiles dans le conteneur) et 8 KB de projets hors /project (chemins
    # Windows qui ne fonctionnent pas ici). Garde uniquement les champs réellement
    # nécessaires à l'identité utilisateur et aux flags d'onboarding.
    HOST_FILTERED=$(jq '{
        theme,
        oauthAccount,
        userID,
        firstStartTime,
        numStartups,
        tipsHistory,
        hasCompletedOnboarding,
        hasAvailableSubscription,
        bypassPermissionsModeAccepted,
        hasTrustDialogsShown,
        installMethod,
        autoUpdatesChannel,
        toolUsage,
        skillUsage,
        enabledPlugins,
        seenNotifications,
        projects: (.projects // {} | with_entries(select(.key == "/project")))
    } | with_entries(select(.value != null))' /home/claude/.claude/host-claude.json)
    _BEFORE=$(stat -c '%s' /home/claude/.claude/host-claude.json 2>/dev/null || echo 0)
    _AFTER=$(echo "$HOST_FILTERED" | wc -c)
    echo "  [OK] host-claude.json filtre : ${_BEFORE}o -> ${_AFTER}o"
    jq -s '.[0] * .[1] * .[2]' \
        <(echo "$MCP_SERVERS") \
        <(echo "$PREFS_BASE") \
        <(echo "$HOST_FILTERED") \
        > /home/claude/.claude.json
else
    jq -s '.[0] * .[1]' \
        <(echo "$MCP_SERVERS") \
        <(echo "$PREFS_BASE") \
        > /home/claude/.claude.json
fi

echo "  [OK] MCP servers configures ($(jq '.mcpServers | length' /home/claude/.claude.json) serveurs)"

# ── Onboarding flags diagnostic (detects when host-claude.json overrides a critical flag to false) ──
_HAS_ONBOARD=$(jq -r '.hasCompletedOnboarding // false' /home/claude/.claude.json)
_HAS_BYPASS=$(jq -r '.bypassPermissionsModeAccepted // false' /home/claude/.claude.json)
_HAS_TRUST=$(jq -r '.projects["/project"].hasTrustDialogAccepted // false' /home/claude/.claude.json)
echo "  [SETUP] onboarding=$_HAS_ONBOARD bypass=$_HAS_BYPASS trust=$_HAS_TRUST"

# ── Claude Code version check (async background update by default) ──
# The session starts immediately on the currently-installed version. `claude update`
# runs in the background and installs newer versions into the binary store volume;
# the symlink re-pointing at the next container start picks them up. The persistent
# volume `claude-bin` means downloaded versions survive container recreation.
#
# Variables:
#   CLAUDE_SKIP_UPDATE=true     bypass entirely (offline)
#   CLAUDE_UPDATE_SYNC=true     wait for update at startup (legacy progress-bar UX)
#   CLAUDE_UPDATE_INTERVAL=N    throttle window in seconds (default 86400 = 24h)
#   CLAUDE_UPDATE_TIMEOUT=N     hard timeout in seconds (default 120, sync mode only)
_CC_VERSIONS_DIR="/home/claude/.local/share/claude/versions"
if [ -d "$_CC_VERSIONS_DIR" ]; then
    _CC_LATEST=$(ls -1 "$_CC_VERSIONS_DIR" 2>/dev/null | sort -V | tail -n 1)
    if [ -n "$_CC_LATEST" ] && [ -x "$_CC_VERSIONS_DIR/$_CC_LATEST" ]; then
        ln -sf "$_CC_VERSIONS_DIR/$_CC_LATEST" /home/claude/.local/bin/claude
    fi
fi

_CC_CURR=$(claude --version 2>/dev/null | awk '{print $1}')
_CC_STAMP="$CONFIG_DIR/.last-update-check"
_CC_LOCK="$CONFIG_DIR/.update-in-progress"
_CC_LOG="/tmp/.claude-update.log"
_CC_INTERVAL="${CLAUDE_UPDATE_INTERVAL:-86400}"

# Determine if we should run an update now
_CC_SKIP=false
_CC_REASON=""
if [ "${CLAUDE_SKIP_UPDATE:-}" = "true" ]; then
    _CC_SKIP=true; _CC_REASON="CLAUDE_SKIP_UPDATE=true"
elif [ -f "$_CC_LOCK" ]; then
    # Another container is currently updating. Skip; we'll pick up the new version
    # at the next start when the symlink re-pointing scans the versions dir.
    _CC_AGE=$(( $(date +%s) - $(stat -c '%Y' "$_CC_LOCK" 2>/dev/null || echo 0) ))
    if [ "$_CC_AGE" -lt 600 ]; then
        _CC_SKIP=true; _CC_REASON="update en cours dans un autre container (${_CC_AGE}s)"
    else
        # Stale lock (>10min): assume previous run crashed, remove and proceed
        rm -f "$_CC_LOCK"
    fi
elif [ -f "$_CC_STAMP" ]; then
    _CC_LAST=$(stat -c '%Y' "$_CC_STAMP" 2>/dev/null || echo 0)
    _CC_AGE=$(( $(date +%s) - _CC_LAST ))
    if [ "$_CC_AGE" -lt "$_CC_INTERVAL" ]; then
        _CC_SKIP=true; _CC_REASON="dernier check il y a $((_CC_AGE / 60)) min (< ${_CC_INTERVAL}s)"
    fi
fi

# Background updater: respects lock, touches stamp on success, re-points symlink
_cc_run_update_bg() {
    (
        : > "$_CC_LOG"
        touch "$_CC_LOCK"
        trap 'rm -f "$_CC_LOCK"' EXIT
        if claude update < /dev/null > "$_CC_LOG" 2>&1; then
            touch "$_CC_STAMP" 2>/dev/null || true
            if [ -d "$_CC_VERSIONS_DIR" ]; then
                _new=$(ls -1 "$_CC_VERSIONS_DIR" 2>/dev/null | sort -V | tail -n 1)
                if [ -n "$_new" ] && [ -x "$_CC_VERSIONS_DIR/$_new" ]; then
                    ln -sf "$_CC_VERSIONS_DIR/$_new" /home/claude/.local/bin/claude 2>/dev/null || true
                fi
            fi
        fi
    ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

if $_CC_SKIP; then
    echo "  [OK] Claude Code ${_CC_CURR:-?} ($_CC_REASON)"
elif [ "${CLAUDE_UPDATE_SYNC:-false}" != "true" ]; then
    # Async mode (default): launch update detached, don't block the session
    _cc_run_update_bg
    echo "  [OK] Claude Code ${_CC_CURR:-?} (update en arriere-plan, swap au prochain demarrage)"
else
    # Sync mode (legacy): keep the progress bar for users on slow networks
    _CC_TIMEOUT="${CLAUDE_UPDATE_TIMEOUT:-120}"
    _CC_BAR_WIDTH=30
    : > "$_CC_LOG"
    touch "$_CC_LOCK"
    trap 'rm -f "$_CC_LOCK"' EXIT

    _CC_WATCH_DIR="/home/claude/.local/share/claude"
    _CC_SIZE_INITIAL=$(du -sb "$_CC_WATCH_DIR" 2>/dev/null | awk '{print $1+0}')
    [ -z "$_CC_SIZE_INITIAL" ] && _CC_SIZE_INITIAL=0
    _CC_EXPECTED=0
    if [ -n "$_CC_CURR" ] && [ -f "$_CC_VERSIONS_DIR/$_CC_CURR" ]; then
        _CC_EXPECTED=$(stat -c '%s' "$_CC_VERSIONS_DIR/$_CC_CURR" 2>/dev/null || echo 0)
    fi

    ( claude update < /dev/null > "$_CC_LOG" 2>&1 ) &
    _CC_PID=$!
    _CC_START=$(date +%s)
    _CC_TIMED_OUT=false
    _CC_WIN_TIME=$_CC_START
    _CC_WIN_SIZE=$_CC_SIZE_INITIAL

    while kill -0 "$_CC_PID" 2>/dev/null; do
        _CC_NOW_T=$(date +%s)
        _CC_ELAPSED=$(( _CC_NOW_T - _CC_START ))
        if [ "$_CC_ELAPSED" -ge "$_CC_TIMEOUT" ]; then
            kill -TERM "$_CC_PID" 2>/dev/null || true
            sleep 1
            kill -KILL "$_CC_PID" 2>/dev/null || true
            _CC_TIMED_OUT=true
            break
        fi
        _CC_FILLED=$(( _CC_ELAPSED * _CC_BAR_WIDTH / _CC_TIMEOUT ))
        [ "$_CC_FILLED" -gt "$_CC_BAR_WIDTH" ] && _CC_FILLED=$_CC_BAR_WIDTH
        _CC_BAR=$(printf '%*s' "$_CC_FILLED" '' | tr ' ' '#')
        _CC_EMPTY=$(printf '%*s' $(( _CC_BAR_WIDTH - _CC_FILLED )) '')
        _CC_RAW_STATUS=$(tr -d '\r' < "$_CC_LOG" 2>/dev/null | grep -v '^Warning\|^Fix:\|^$' | tail -n 1)
        case "$_CC_RAW_STATUS" in
            "") _CC_STATUS="demarrage..." ;;
            "Current version:"*|"Checking for updates"*) _CC_STATUS="verification..." ;;
            "Updating configuration"*|"Installation method"*) _CC_STATUS="telechargement..." ;;
            "Successfully updated"*|"Claude Code is up to date"*) _CC_STATUS="finalisation..." ;;
            *) _CC_STATUS=$(echo "$_CC_RAW_STATUS" | cut -c1-30) ;;
        esac

        _CC_NOW_SIZE=$(du -sb "$_CC_WATCH_DIR" 2>/dev/null | awk '{print $1+0}')
        [ -z "$_CC_NOW_SIZE" ] && _CC_NOW_SIZE=$_CC_SIZE_INITIAL
        _CC_DOWNLOADED=$(( _CC_NOW_SIZE - _CC_SIZE_INITIAL ))
        [ "$_CC_DOWNLOADED" -lt 0 ] && _CC_DOWNLOADED=0
        _CC_WIN_ELAPSED=$(( _CC_NOW_T - _CC_WIN_TIME ))
        _CC_WIN_GROWTH=$(( _CC_NOW_SIZE - _CC_WIN_SIZE ))
        [ "$_CC_WIN_GROWTH" -lt 0 ] && _CC_WIN_GROWTH=0
        _CC_SPEED=0
        if [ "$_CC_WIN_ELAPSED" -gt 0 ] && [ "$_CC_WIN_GROWTH" -gt 0 ]; then
            _CC_SPEED=$(( _CC_WIN_GROWTH / _CC_WIN_ELAPSED ))
        fi
        if [ "$_CC_WIN_ELAPSED" -ge 5 ]; then
            _CC_WIN_TIME=$_CC_NOW_T
            _CC_WIN_SIZE=$_CC_NOW_SIZE
        fi

        _CC_DL_SUFFIX=""
        if [ "$_CC_SPEED" -gt 0 ]; then
            if [ "$_CC_SPEED" -ge 1048576 ]; then
                _CC_SPEED_STR=$(awk -v b="$_CC_SPEED" 'BEGIN{printf "%.1f MB/s", b/1048576}')
            elif [ "$_CC_SPEED" -ge 1024 ]; then
                _CC_SPEED_STR=$(awk -v b="$_CC_SPEED" 'BEGIN{printf "%.0f KB/s", b/1024}')
            else
                _CC_SPEED_STR="${_CC_SPEED} B/s"
            fi
            _CC_DL_SUFFIX="  $_CC_SPEED_STR"
            if [ "$_CC_EXPECTED" -gt 0 ] && [ "$_CC_DOWNLOADED" -lt "$_CC_EXPECTED" ]; then
                _CC_ETA_SEC=$(( (_CC_EXPECTED - _CC_DOWNLOADED) / _CC_SPEED ))
                _CC_DL_SUFFIX="${_CC_DL_SUFFIX} ETA ${_CC_ETA_SEC}s"
            fi
        fi

        printf "\r\033[2K  \033[90m[..] Claude %s [%s%s] %02d/%02ds  %s%s\033[0m" \
            "${_CC_CURR:-?}" "$_CC_BAR" "$_CC_EMPTY" "$_CC_ELAPSED" "$_CC_TIMEOUT" "$_CC_STATUS" "$_CC_DL_SUFFIX"
        sleep 1
    done
    wait "$_CC_PID" 2>/dev/null
    _CC_RC=$?
    printf "\r\033[2K"
    rm -f "$_CC_LOCK"
    trap - EXIT

    if [ "$_CC_TIMED_OUT" = "true" ]; then
        echo -e "  \033[33m[WARN] Claude Code ${_CC_CURR:-?} - timeout ${_CC_TIMEOUT}s (reseau lent ?) - voir $_CC_LOG\033[0m"
    elif [ "$_CC_RC" -eq 0 ]; then
        if [ -d "$_CC_VERSIONS_DIR" ]; then
            _CC_LATEST=$(ls -1 "$_CC_VERSIONS_DIR" 2>/dev/null | sort -V | tail -n 1)
            if [ -n "$_CC_LATEST" ] && [ -x "$_CC_VERSIONS_DIR/$_CC_LATEST" ]; then
                ln -sf "$_CC_VERSIONS_DIR/$_CC_LATEST" /home/claude/.local/bin/claude
            fi
        fi
        _CC_NEW=$(claude --version 2>/dev/null | awk '{print $1}')
        touch "$_CC_STAMP" 2>/dev/null || true
        if [ -n "$_CC_CURR" ] && [ -n "$_CC_NEW" ] && [ "$_CC_CURR" != "$_CC_NEW" ]; then
            echo -e "  \033[32m[OK] Claude Code $_CC_CURR -> $_CC_NEW (mis a jour)\033[0m"
        else
            echo "  [OK] Claude Code ${_CC_NEW:-?} (a jour, prochain check dans ${_CC_INTERVAL}s)"
        fi
    else
        echo -e "  \033[33m[WARN] Claude Code ${_CC_CURR:-?} - update echoue (exit $_CC_RC) - voir $_CC_LOG\033[0m"
    fi
fi

# ── User-level CLAUDE.md (global instructions, applied to every project) ──
# Persisted on the shared `claude-user-config` volume. Edited in-container with
# /memory, or directly on the host volume. Skipped if CLAUDE_FORCE_RESEED=true.
if [ -f "$CONFIG_DIR/CLAUDE.md" ] && [ -s "$CONFIG_DIR/CLAUDE.md" ] && [ "${CLAUDE_FORCE_RESEED:-}" != "true" ]; then
    cp "$CONFIG_DIR/CLAUDE.md" /home/claude/.claude/CLAUDE.md
    echo "  [OK] CLAUDE.md global restaure depuis le volume ($(wc -l < /home/claude/.claude/CLAUDE.md) lignes)"
fi

# ── Statsig cache : persistent volume > host ──
if [ -d "$CONFIG_DIR/statsig" ] && [ "$(ls -A "$CONFIG_DIR/statsig" 2>/dev/null)" ] && [ "${CLAUDE_FORCE_RESEED:-}" != "true" ]; then
    mkdir -p /home/claude/.claude/statsig
    cp -r "$CONFIG_DIR/statsig/"* /home/claude/.claude/statsig/ 2>/dev/null || true
    echo "  [OK] Cache statsig restaure depuis le volume"
elif [ -d /home/claude/.claude/host-statsig ]; then
    mkdir -p /home/claude/.claude/statsig "$CONFIG_DIR/statsig"
    cp -r /home/claude/.claude/host-statsig/* /home/claude/.claude/statsig/ 2>/dev/null || true
    cp -r /home/claude/.claude/host-statsig/* "$CONFIG_DIR/statsig/" 2>/dev/null || true
    echo "  [OK] Cache statsig copie depuis l'hote (+ sauvegarde)"
fi

# ── Seed default output styles into the mounted output-styles/ dir ──
# Only seed missing files — never overwrite a user-edited style.
if [ -d /opt/claude-yolo-defaults/output-styles ]; then
    for _src in /opt/claude-yolo-defaults/output-styles/*.md; do
        [ -f "$_src" ] || continue
        _dst="/home/claude/.claude/output-styles/$(basename "$_src")"
        if [ ! -f "$_dst" ]; then
            cp "$_src" "$_dst" 2>/dev/null && \
                echo "  [OK] Output style seeded: $(basename "$_src")"
        fi
    done
fi

# ── Git safe directory ──
if [ -d /project/.git ]; then
    git config --global --add safe.directory /project
fi

echo ""

# Readiness marker: entrypoint reached launch (picked up by docker HEALTHCHECK)
touch /tmp/.claude-ready

# Wizard flags propagation: les lanceurs passent --reconfigure / --no-prompt via
# CLAUDE_WIZARD_FLAGS (env var). On les passe au wrapper claude-session via une
# autre env var, en filtrant CLAUDE_ARGS pour ne pas les transmettre à `claude`
# lui-même qui ne les connait pas.
if [ -n "${CLAUDE_WIZARD_FLAGS:-}" ]; then
    export CLAUDE_SESSION_FLAGS="$CLAUDE_WIZARD_FLAGS"
fi

# Launch Claude (exec replaces bash so claude becomes PID 1 = direct terminal access)
if [ -n "$CLAUDE_ARGS" ]; then
    # shellcheck disable=SC2086
    exec claude-session $CLAUDE_ARGS
else
    exec claude-session --dangerously-skip-permissions
fi
