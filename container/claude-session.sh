#!/bin/bash
# Wrapper: saves user preferences to persistent volume, then exec's claude.
# exec ensures claude becomes PID 1 (direct terminal access for paste, etc.)

CONFIG_DIR="/home/claude/.claude/user-config"

# Save preferences on exit (trap fires when claude exits since exec replaces this shell)
save_on_exit() {
    [ -d "$CONFIG_DIR" ] || return
    if [ -f /home/claude/.claude/.credentials.json ] && [ -s /home/claude/.claude/.credentials.json ]; then
        cp /home/claude/.claude/.credentials.json "$CONFIG_DIR/credentials.json" 2>/dev/null || true
    fi
    if [ -f /home/claude/.claude.json ]; then
        jq '{theme, editorMode, showTurnDuration, terminalProgressBarEnabled, autoConnectIde,
             hasCompletedOnboarding, bypassPermissionsModeAccepted, hasTrustDialogsShown,
             hasAvailableSubscription, lastOnboardingVersion, tipsHistory,
             oauthAccount, userID, firstStartTime, projects}
            | with_entries(select(.value != null))' \
            /home/claude/.claude.json > "$CONFIG_DIR/user-preferences.json" 2>/dev/null || true
    fi
    if [ -f /home/claude/.claude/settings.json ]; then
        jq '{model, effortLevel, language, viewMode, forceLoginMethod, forceLoginOrgUUID, autoUpdatesChannel, prefersReducedMotion}
            | with_entries(select(.value != null))' \
            /home/claude/.claude/settings.json > "$CONFIG_DIR/user-settings.json" 2>/dev/null || true
    fi
    if [ -d /home/claude/.claude/statsig ]; then
        mkdir -p "$CONFIG_DIR/statsig"
        cp -r /home/claude/.claude/statsig/* "$CONFIG_DIR/statsig/" 2>/dev/null || true
    fi
    echo "  [OK] Preferences sauvegardees"
}

# Save prefs BEFORE exec (captures state at session start + any login changes)
# Main save happens via entrypoint trap or docker stop
save_on_exit

clear
exec claude "$@"
