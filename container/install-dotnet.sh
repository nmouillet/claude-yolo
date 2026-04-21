#!/bin/bash
# Dynamic .NET SDK installer - detects project requirements and installs missing SDKs
# Called from entrypoint.sh root phase (runs as root) before dropping to claude user

INSTALL_SCRIPT="/usr/local/bin/dotnet-install.sh"
DOTNET_DIR="/usr/share/dotnet"
PROJECT_DIR="/project"
DOTNET="$DOTNET_DIR/dotnet"

# -- Collect required channels from project files --
CHANNELS=()

# Scan .csproj files for TargetFramework(s)
CSPROJ_FILES=$(find "$PROJECT_DIR" -name '*.csproj' \
    -not -path '*/bin/*' \
    -not -path '*/obj/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/.git/*' \
    2>/dev/null)

if [ -n "$CSPROJ_FILES" ]; then
    # Extract TargetFramework and TargetFrameworks values
    TFMS=$(echo "$CSPROJ_FILES" | xargs grep -ohP '<TargetFrameworks?>\K[^<]+' 2>/dev/null)

    # Split semicolons and extract channel numbers
    for tfm in $(echo "$TFMS" | tr ';' '\n'); do
        # net8.0 -> 8.0, net8.0-windows -> 8.0, net10.0-android -> 10.0
        channel=$(echo "$tfm" | sed -n 's/^net\([0-9]*\.[0-9]*\).*/\1/p')
        [ -n "$channel" ] && CHANNELS+=("$channel")
    done
fi

# Check global.json for SDK version pinning
if [ -f "$PROJECT_DIR/global.json" ]; then
    SDK_VERSION=$(jq -r '.sdk.version // empty' "$PROJECT_DIR/global.json" 2>/dev/null)
    if [ -n "$SDK_VERSION" ]; then
        # 8.0.100 -> 8.0, 9.0.200-preview.1 -> 9.0
        channel=$(echo "$SDK_VERSION" | sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p')
        [ -n "$channel" ] && CHANNELS+=("$channel")
    fi
fi

# -- Log file for installer output (full trace kept for diagnostics) --
LOG_FILE="/tmp/dotnet-install.log"

run_install() {
    local label="$1"
    shift
    if "$INSTALL_SCRIPT" "$@" --install-dir "$DOTNET_DIR" --no-path > "$LOG_FILE" 2>&1; then
        return 0
    else
        local rc=$?
        echo "  [WARN] Echec de l'installation ${label} (code $rc) - extrait du log :"
        tail -10 "$LOG_FILE" | sed 's/^/        /'
        echo "        (log complet : $LOG_FILE)"
        return $rc
    fi
}

# -- No .NET project detected: install .NET 10 as default --
if [ ${#CHANNELS[@]} -eq 0 ]; then
    if "$DOTNET" --list-sdks 2>/dev/null | grep -q "^10\.0\."; then
        echo "  [OK] Aucun projet .NET detecte - SDK .NET 10 deja installe"
    else
        echo "  [..] Aucun projet .NET detecte - installation de .NET 10..."
        if run_install "SDK .NET 10" --channel 10.0; then
            echo "  [OK] SDK .NET 10 installe par defaut"
        fi
    fi
    exit 0
fi

# -- Deduplicate and sort channels --
mapfile -t UNIQUE_CHANNELS < <(printf '%s\n' "${CHANNELS[@]}" | sort -V | uniq)

echo "  [INFO] Frameworks .NET detectes : ${UNIQUE_CHANNELS[*]}"

# -- Install missing SDKs --
INSTALLED=0
for channel in "${UNIQUE_CHANNELS[@]}"; do
    if "$DOTNET" --list-sdks 2>/dev/null | grep -q "^${channel}\."; then
        echo "  [OK] SDK .NET ${channel} deja installe"
    else
        echo "  [..] Installation du SDK .NET ${channel}..."
        if run_install "SDK .NET ${channel}" --channel "$channel"; then
            echo "  [OK] SDK .NET ${channel} installe"
            INSTALLED=$((INSTALLED + 1))
        fi
    fi
done

# -- Handle global.json pinned version --
if [ -f "$PROJECT_DIR/global.json" ]; then
    SDK_VERSION=$(jq -r '.sdk.version // empty' "$PROJECT_DIR/global.json" 2>/dev/null)
    if [ -n "$SDK_VERSION" ]; then
        if ! "$DOTNET" --list-sdks 2>/dev/null | grep -q "^${SDK_VERSION} "; then
            echo "  [..] Installation de la version exacte ${SDK_VERSION} (global.json)..."
            if run_install "SDK .NET ${SDK_VERSION}" --version "$SDK_VERSION"; then
                echo "  [OK] SDK .NET ${SDK_VERSION} installe"
                INSTALLED=$((INSTALLED + 1))
            fi
        fi
    fi
fi

if [ "$INSTALLED" -gt 0 ]; then
    echo "  [OK] ${INSTALLED} SDK(s) .NET installe(s) dynamiquement"
fi
