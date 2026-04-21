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
    # Claude Code binary store volume (empty named volume -> seeded from image,
    # ownership may be root on first mount)
    if [ -d /home/claude/.local/share/claude ] \
       && [ "$(stat -c '%U' /home/claude/.local/share/claude 2>/dev/null)" != "claude" ]; then
        chown -R claude:claude /home/claude/.local/share/claude
    fi

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
         /home/claude/.claude/projects \
         /home/claude/.claude/sessions \
         /home/claude/.claude/plans \
         /home/claude/.claude/hooks \
         /home/claude/.claude/container-hooks \
         /home/claude/.claude/mcp-memory \
         /home/claude/.claude/credentials \
         "$CONFIG_DIR"

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
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "/home/claude/.claude/statusline.sh"
  },
  "forceLoginMethod": "claudeai"
}'

# Build settings.json: defaults < persistent user prefs < host settings < container hooks
# Container hooks always win (immutable). Defaults fill the gap when neither user prefs nor host set a value.
DEFAULT_SETTINGS='{
  "model": "default"
}'
SETTINGS_BASE="$DEFAULT_SETTINGS"
if [ -f "$CONFIG_DIR/user-settings.json" ] && [ -s "$CONFIG_DIR/user-settings.json" ] && [ "${CLAUDE_FORCE_RESEED:-}" != "true" ]; then
    SETTINGS_BASE=$(echo "$DEFAULT_SETTINGS" "$(cat "$CONFIG_DIR/user-settings.json")" | jq -s '.[0] * .[1]')
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
MCP_SERVERS='{
  "mcpServers": {
    "fetch": {
      "command": "uvx",
      "args": ["mcp-server-fetch"]
    },
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"],
      "env": {
        "MEMORY_FILE_PATH": "/home/claude/.claude/mcp-memory/memory.json"
      }
    },
    "sequential-thinking": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"]
    },
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/project"]
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}'

# Conditionally add Brave Search MCP (only if BRAVE_API_KEY is set)
if [ -n "${BRAVE_API_KEY:-}" ]; then
    BRAVE_SERVER=$(jq -n --arg key "$BRAVE_API_KEY" '{
      "mcpServers": {
        "brave-search": {
          "command": "npx",
          "args": ["-y", "@brave/brave-search-mcp-server"],
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
          "command": "npx",
          "args": ["-y", "@playwright/mcp", "--headless"]
        }
      }
    }'
    MCP_SERVERS=$(echo "$MCP_SERVERS" "$PLAYWRIGHT_SERVER" | jq -s '.[0] * .[1]')
fi

# Conditionally add GitHub MCP (only if GITHUB_TOKEN is set)
if [ -n "${GITHUB_TOKEN:-}" ]; then
    # Try Go binary first, fall back to npm package
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
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-github"],
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
          "command": "npx",
          "args": ["-y", "@bytebase/dbhub", "--dsn", $dsn]
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
          "command": "npx",
          "args": ["-y", "mcp-server-docker"]
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
    jq -s '.[0] * .[1] * .[2]' \
        <(echo "$MCP_SERVERS") \
        <(echo "$PREFS_BASE") \
        /home/claude/.claude/host-claude.json \
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

# ── Claude Code version check (synchronous update at startup) ──
# The background auto-updater is lazy; check explicitly so the session starts on the
# latest version. Set CLAUDE_SKIP_UPDATE=true to bypass (useful offline).
#
# The binary store /home/claude/.local/share/claude is a persistent volume; the
# symlink /home/claude/.local/bin/claude lives in the container layer (image-baked),
# so re-point it to the newest version found in the volume before reading version.
_CC_VERSIONS_DIR="/home/claude/.local/share/claude/versions"
if [ -d "$_CC_VERSIONS_DIR" ]; then
    _CC_LATEST=$(ls -1 "$_CC_VERSIONS_DIR" 2>/dev/null | sort -V | tail -n 1)
    if [ -n "$_CC_LATEST" ] && [ -x "$_CC_VERSIONS_DIR/$_CC_LATEST" ]; then
        ln -sf "$_CC_VERSIONS_DIR/$_CC_LATEST" /home/claude/.local/bin/claude
    fi
fi

_CC_CURR=$(claude --version 2>/dev/null | awk '{print $1}')
# Throttle: only run `claude update` if the last successful check is older than
# CLAUDE_UPDATE_INTERVAL seconds (default 86400 = 24h). Stamp lives on the shared
# volume so it's shared across all project containers.
_CC_STAMP="$CONFIG_DIR/.last-update-check"
_CC_INTERVAL="${CLAUDE_UPDATE_INTERVAL:-86400}"
_CC_SKIP=false
if [ "${CLAUDE_SKIP_UPDATE:-}" = "true" ]; then
    _CC_SKIP=true
    _CC_REASON="CLAUDE_SKIP_UPDATE=true"
elif [ -f "$_CC_STAMP" ]; then
    _CC_LAST=$(stat -c '%Y' "$_CC_STAMP" 2>/dev/null || echo 0)
    _CC_AGE=$(( $(date +%s) - _CC_LAST ))
    if [ "$_CC_AGE" -lt "$_CC_INTERVAL" ]; then
        _CC_SKIP=true
        _CC_REASON="dernier check il y a $((_CC_AGE / 60)) min (< ${_CC_INTERVAL}s)"
    fi
fi

if $_CC_SKIP; then
    echo "  [OK] Claude Code ${_CC_CURR:-?} ($_CC_REASON)"
else
    _CC_TIMEOUT="${CLAUDE_UPDATE_TIMEOUT:-120}"
    _CC_BAR_WIDTH=30
    _CC_LOG="/tmp/.claude-update.log"
    : > "$_CC_LOG"

    # Watch binary store to measure download progress (bytes growth over time).
    # Target size is approximated from the currently installed binary (new version
    # is typically within ~20% of the old one).
    _CC_WATCH_DIR="/home/claude/.local/share/claude"
    _CC_SIZE_INITIAL=$(du -sb "$_CC_WATCH_DIR" 2>/dev/null | awk '{print $1+0}')
    [ -z "$_CC_SIZE_INITIAL" ] && _CC_SIZE_INITIAL=0
    _CC_EXPECTED=0
    if [ -n "$_CC_CURR" ] && [ -f "$_CC_VERSIONS_DIR/$_CC_CURR" ]; then
        _CC_EXPECTED=$(stat -c '%s' "$_CC_VERSIONS_DIR/$_CC_CURR" 2>/dev/null || echo 0)
    fi

    # Run update in background so we can draw a progress bar + latest log line.
    ( claude update < /dev/null > "$_CC_LOG" 2>&1 ) &
    _CC_PID=$!
    _CC_START=$(date +%s)
    _CC_TIMED_OUT=false
    # Sliding window anchor for speed calculation (rolls every 5s).
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
        # `claude update` prints milestones but stays silent during the download
        # (~15s of a fresh install). Map known milestones to readable phases and
        # fall back to "telechargement..." once the last noisy line is behind us.
        _CC_RAW_STATUS=$(tr -d '\r' < "$_CC_LOG" 2>/dev/null | grep -v '^Warning\|^Fix:\|^$' | tail -n 1)
        case "$_CC_RAW_STATUS" in
            "") _CC_STATUS="demarrage..." ;;
            "Current version:"*|"Checking for updates"*) _CC_STATUS="verification..." ;;
            "Updating configuration"*|"Installation method"*) _CC_STATUS="telechargement..." ;;
            "Successfully updated"*|"Claude Code is up to date"*) _CC_STATUS="finalisation..." ;;
            *) _CC_STATUS=$(echo "$_CC_RAW_STATUS" | cut -c1-30) ;;
        esac

        # Sample bytes growth since start and over the ~5s sliding window.
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

        # Build speed + ETA suffix (empty when nothing is downloading yet).
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

    if [ "$_CC_TIMED_OUT" = "true" ]; then
        echo -e "  \033[33m[WARN] Claude Code ${_CC_CURR:-?} - timeout ${_CC_TIMEOUT}s (reseau lent ?) - voir $_CC_LOG\033[0m"
    elif [ "$_CC_RC" -eq 0 ]; then
        # Re-point symlink in case update installed a newer version
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

# ── Git safe directory ──
if [ -d /project/.git ]; then
    git config --global --add safe.directory /project
fi

echo ""

# Readiness marker: entrypoint reached launch (picked up by docker HEALTHCHECK)
touch /tmp/.claude-ready

# Launch Claude (exec replaces bash so claude becomes PID 1 = direct terminal access)
if [ -n "$CLAUDE_ARGS" ]; then
    # shellcheck disable=SC2086
    exec claude-session $CLAUDE_ARGS
else
    exec claude-session --dangerously-skip-permissions
fi
