#!/bin/bash
# Wrapper: saves user preferences to persistent volume, runs the per-project
# feature wizard, then exec's claude. exec ensures claude becomes PID 1
# (direct terminal access for paste, etc.)

CONFIG_DIR="/home/claude/.claude/user-config"

# Sync session state. Misnamed `save_on_exit` for historical reasons — actually
# runs at session START (the `exec claude` at the end replaces this shell, so
# trap-based exit hooks would never fire). Captures any state from the previous
# session that survived in mounted volumes.
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
        # Drop `model: "default"` — it's not a valid model id and bricks the next session.
        jq '{model, effortLevel, language, viewMode, forceLoginMethod, forceLoginOrgUUID, autoUpdatesChannel, prefersReducedMotion, outputStyle}
            | with_entries(select(.value != null))
            | if .model == "default" then del(.model) else . end' \
            /home/claude/.claude/settings.json > "$CONFIG_DIR/user-settings.json" 2>/dev/null || true
    fi
    if [ -d /home/claude/.claude/statsig ]; then
        mkdir -p "$CONFIG_DIR/statsig"
        cp -r /home/claude/.claude/statsig/* "$CONFIG_DIR/statsig/" 2>/dev/null || true
    fi
    if [ -f /home/claude/.claude/CLAUDE.md ] && [ -s /home/claude/.claude/CLAUDE.md ]; then
        cp /home/claude/.claude/CLAUDE.md "$CONFIG_DIR/CLAUDE.md" 2>/dev/null || true
    fi

    # Migrate user-added skills (real dirs added via `/skill add` in a prior session)
    # from the per-project skills overlay to the shared host-skills/. After migration,
    # replace the real dir with a symlink so subsequent rebuilds work uniformly.
    SKILLS_DIR="/home/claude/.claude/skills"
    HOST_SKILLS_DIR="/home/claude/.claude/host-skills"
    if [ -d "$SKILLS_DIR" ] && [ -d "$HOST_SKILLS_DIR" ]; then
        for _entry in "$SKILLS_DIR"/*; do
            [ -e "$_entry" ] || continue
            [ -L "$_entry" ] && continue   # already a symlink, nothing to migrate
            [ -d "$_entry" ] || continue
            _name=$(basename "$_entry")
            if [ ! -e "$HOST_SKILLS_DIR/$_name" ]; then
                if cp -r "$_entry" "$HOST_SKILLS_DIR/$_name" 2>/dev/null; then
                    rm -rf "$_entry"
                    ln -s "$HOST_SKILLS_DIR/$_name" "$_entry"
                    echo "  [OK] Skill '$_name' migre vers host-skills/"
                fi
            fi
        done
    fi

    echo "  [OK] Preferences sauvegardees"
}

# Save prefs BEFORE exec (captures state at session start + any login changes)
save_on_exit

# ── Per-project feature wizard ─────────────────────────────────────────
# Routage des flags : --no-prompt / --reconfigure peuvent venir via env var
# CLAUDE_SESSION_FLAGS (positionné par l'entrypoint, qui les lit dans CLAUDE_ARGS).
# Mode -p (prompt one-shot) ⇒ forcer --no-prompt pour ne pas bloquer.
WIZARD_FLAGS=""
case "$*" in
    *"-p "*|*"-p="*|*"--print"*) WIZARD_FLAGS="--no-prompt" ;;
esac
[[ "${CLAUDE_SESSION_FLAGS:-}" == *"--no-prompt"*   ]] && WIZARD_FLAGS="--no-prompt"
[[ "${CLAUDE_SESSION_FLAGS:-}" == *"--reconfigure"* ]] && WIZARD_FLAGS="--reconfigure"

if [ -x /home/claude/.claude/container-hooks/feature-wizard.sh ]; then
    /home/claude/.claude/container-hooks/feature-wizard.sh $WIZARD_FLAGS || {
        rc=$?
        [ "$rc" = "130" ] && exit 0  # user a quitté le wizard → on stoppe proprement
        echo "  [WARN] Wizard a échoué (exit $rc), démarrage avec config par défaut" >&2
    }
fi

clear
exec claude "$@"
