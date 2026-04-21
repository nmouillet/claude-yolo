#!/bin/bash
# On-the-fly .NET SDK installer - use during work to add a missing SDK
# Usage: sudo install-dotnet-sdk.sh <channel>
# Examples:
#   sudo install-dotnet-sdk.sh 6.0
#   sudo install-dotnet-sdk.sh 10.0

INSTALL_SCRIPT="/usr/local/bin/dotnet-install.sh"
DOTNET_DIR="/usr/share/dotnet"
DOTNET="$DOTNET_DIR/dotnet"

# -- Validate argument --
if [ $# -ne 1 ]; then
    echo "Usage: sudo install-dotnet-sdk.sh <channel>"
    echo "Exemple: sudo install-dotnet-sdk.sh 9.0"
    exit 1
fi

CHANNEL="$1"

if ! echo "$CHANNEL" | grep -qP '^\d+\.\d+$'; then
    echo "Erreur: format invalide '$CHANNEL' (attendu: X.Y, ex: 9.0, 10.0)"
    exit 1
fi

# -- Check if already installed --
if "$DOTNET" --list-sdks 2>/dev/null | grep -q "^${CHANNEL}\."; then
    INSTALLED_VERSION=$("$DOTNET" --list-sdks 2>/dev/null | grep "^${CHANNEL}\." | tail -1 | awk '{print $1}')
    echo "SDK .NET ${CHANNEL} deja installe (${INSTALLED_VERSION})"
    exit 0
fi

# -- Install --
echo "Installation du SDK .NET ${CHANNEL}..."
if "$INSTALL_SCRIPT" --channel "$CHANNEL" --install-dir "$DOTNET_DIR" --no-path; then
    INSTALLED_VERSION=$("$DOTNET" --list-sdks 2>/dev/null | grep "^${CHANNEL}\." | tail -1 | awk '{print $1}')
    echo "SDK .NET ${CHANNEL} installe (${INSTALLED_VERSION})"
else
    echo "Erreur: echec de l'installation du SDK .NET ${CHANNEL}"
    exit 1
fi
