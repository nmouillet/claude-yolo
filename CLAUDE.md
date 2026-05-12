# Claude Code Container

Environnement Docker (Ubuntu 24.04) pour exécuter Claude Code CLI en mode YOLO sur des projets de dev. Pas de framework applicatif : scripting Docker + Bash + PowerShell.

> **Détails fins** (persistance prefs, volumes partagés, RTK, NuGet, auto-update, flux `entrypoint.sh`) : skill `claude-yolo-internals`, chargé à la demande.
> **Commandes utiles + architecture détaillée** : voir `README.md`.

## Configuration par projet (wizard)

À la première ouverture d'un dossier, un **wizard** (TUI `gum`) propose un preset auto-détecté (`dotnet-vue` / `dotnet` / `ansible` / `python` / `vue` / `react` / `node` / `docs` / `lean` / `generic`) puis configure plugins, MCP, **skills exposés à Claude**, hooks (RTK), modèle, effort et **output style**.

Sauvegarde dans `config/projects.settings.json` (gitignored, clé = `HOST_PROJECT_PATH`).

| Comportement | Quand |
|--------------|-------|
| Wizard édition complet | Premier run sur ce projet |
| Écran récap `[Enter]` | Lancements suivants (config existante affichée) |
| Mode silencieux | `--prompt`, `--no-prompt`, ou pas de TTY |
| Reset forcé | `--reconfigure` |

**Preset `lean`** : aucun MCP, aucun skill, output style `concise` — économie max pour les one-shots.

**Filtrage skills** : les ~12 skills user-level (`~/.claude/skills/`) sont mountés en `host-skills/` et exposés à Claude via des **symlinks dans `skills/`** (par-conteneur, sur volume `claude-skills-overlay-<projet>`). Le wizard pilote quels symlinks survivent, ce qui retire les skills non pertinents du system prompt (gros gain de tokens sur les projets hors stack du skill).

## Conventions et patterns

- **Fusion JSON** : `jq -s '.[0] * .[1]'` (last-wins).
- **MCP conditionnels** : `if [ -n "${VAR:-}" ]` (env), `if [ -S /path ]` (socket), `if command -v X` (binaire).
- **Volumes** : ro pour les seeds (host credentials/settings/statsig/NuGet.Config), rw pour persistant (skills/projects/hooks/plans/sessions/commands/agents/output-styles/config). Volumes partagés : `claude-user-config`, `claude-bin`, `claude-nuget-cache`, `claude-npm-cache`, `claude-rtk-config`. Volumes par-projet : `claude-mcp-memory-<proj>`, `claude-skills-overlay-<proj>`.
- **Nommage conteneurs** : `claude-<nom-projet-normalisé>`. Isolation compose : `-p claude-<nom>` (containers parallèles possibles).
- **Hooks** : stdin = JSON, exit 0 = OK, exit 2 = blocage.
  - `protect-config.sh` (PreToolUse Read/Edit/Write/Grep/Glob/Bash) : bloque fichiers sensibles + gitignored (whitelists templates `.example`/`.sample` + dossiers techniques).
  - `git-context.sh` (UserPromptSubmit) : injecte branche+statut au 1er prompt. Verbosité via `CLAUDE_GIT_CONTEXT_LEVEL` (`off`/`minimal`/`default`/`verbose`).
  - RTK (PreToolUse Bash) : `rtk hook claude`, désactivable par-projet via wizard.
- **Output styles** : `concise.md` seeded au démarrage si absent du volume. Sélectionnable via wizard (`outputStyle` dans `projects.settings.json`) ou `/output-style`.
- **Auto-memory** : Claude Code persiste mémoire structurée dans `~/.claude/projects/-project/memory/` (continuité inter-sessions). Pas géré par le wizard, géré nativement.
- **Messages** : français dans les scripts utilisateur, anglais dans les commentaires de code.
- **Sections Dockerfile** : numérotées `# ---------- N. Description ----------`.

## Contraintes importantes

- **Pas de tests automatisés / pas de CI** : validation manuelle, image locale.
- **Chemins Windows** : conversion via `wslpath` (ps1) ou `C:\` → `/c/` (sh).
- **Credentials** : fichier hôte monté ro (`HOST_CREDENTIALS_PATH`) → contient `refreshToken` pour auto-refresh. Lanceurs vérifient `expiresAt` avant launch. Fallback : `CLAUDE_CODE_OAUTH_TOKEN` (CI) > volume partagé > `claude login`.
- **Skills overlay** : `~/.claude/skills/` est **un dossier conteneur** rempli de symlinks vers `host-skills/`. `/skill add` crée un vrai dossier dans le volume `claude-skills-overlay`, migré vers `host-skills/` au démarrage suivant (par `claude-session.sh save_on_exit`).
- **Scripts dans l'image** : `protect-config.sh`, `git-context.sh`, `feature-wizard.sh`, `enumerate-features.sh`, `apply-project-config.sh`, `statusline.sh` vivent dans `/home/claude/.claude/container-hooks/` (hors mount rw) — toute modification nécessite un rebuild.
- **Dépendances critiques** : `jq` (merge JSON, lecture credentials, MCP), `gum` (wizard interactif — sans TTY ou sans gum, fallback `--no-prompt`).
- **`.dockerignore` exclut `*.md`** : README.md et CLAUDE.md ne sont PAS dans l'image (voulu).
- **`host-claude.json` filtré** par `entrypoint.sh` : drop `cachedGrowthBookFeatures` (17 KB) et projets non-/project.
- **NuGet DPAPI / Credential Provider** : KO sur Linux. Utiliser `NUGET_PRIVATE_FEED_PAT`.
