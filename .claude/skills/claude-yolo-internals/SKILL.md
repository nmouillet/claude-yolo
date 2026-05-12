---
name: claude-yolo-internals
description: Référence détaillée des mécanismes internes de Claude YOLO (persistance des préférences, volumes Docker partagés, NuGet feeds privés/DPAPI, RTK token-killer, flux de démarrage entrypoint.sh). Charge ce skill quand l'utilisateur mentionne 'RTK', 'NuGet', 'feed privé', 'DPAPI', 'Credential Provider', 'persistance', 'claude-user-config', 'claude-bin', 'volume partagé', 'entrypoint.sh', 'flux démarrage', 'auto-update Claude Code', 'CLAUDE_FORCE_RESEED', 'reset preferences', 'mcp-memory', 'host-claude.json', 'cache npm partagé', 'symlink claude', 'install-dotnet'.
---

# Claude YOLO — Internals

Ce skill documente les mécanismes internes du conteneur Claude YOLO. Le CLAUDE.md principal reste léger ; les détails fins vivent ici, chargés à la demande.

## Persistance des préférences utilisateur

Les préférences Claude Code (credentials, theme, effort level, etc.) sont stockées dans un **volume Docker partagé** `claude-user-config`, commun à tous les projets. Cela permet de configurer une seule fois (`claude login`, `/config`) et que les paramètres persistent entre les sessions et les projets.

### Volume partagé `claude-user-config`

| Fichier dans le volume | Contenu | Écrit par |
|------------------------|---------|-----------|
| `credentials.json` | Token OAuth complet (avec refreshToken) | `entrypoint.sh` (copie depuis fichier hôte ou `claude login` via `claude-session`) |
| `user-preferences.json` | Theme, editorMode, flags d'onboarding (`hasCompletedOnboarding`, `bypassPermissionsModeAccepted`, `hasTrustDialogsShown`, `tipsHistory`, `oauthAccount`, `userID`, `firstStartTime`, `projects`, etc.) | `claude-session` (sauvegarde à la sortie) |
| `user-settings.json` | effortLevel, language, viewMode, forceLoginMethod, etc. | `claude-session` (sauvegarde à la sortie) |
| `statsig/` | Cache feature flags (évite le prompt de login) | `entrypoint.sh` |
| `CLAUDE.md` | Instructions user-level globales (appliquées à TOUS les projets, en complément du `/project/CLAUDE.md`) | `claude-session` (copie depuis `~/.claude/CLAUDE.md` à la sortie) |
| `.last-update-check` | Marqueur de dernière mise à jour réussie (throttle 24h) | Mis à jour après `claude update` réussi |
| `.update-in-progress` | Lock empêchant deux containers de relancer `claude update` simultanément (auto-purge si > 10min) | Créé au début de l'update, supprimé à la fin |

### Pas de faux premier lancement

`entrypoint.sh` écrit des defaults dans `.claude.json` qui pré-approuvent l'onboarding complet : `hasCompletedOnboarding`, `bypassPermissionsModeAccepted`, `hasTrustDialogsShown`, `hasAvailableSubscription`, et `projects["/project"].hasTrustDialogAccepted` / `hasClaudeMdExternalIncludesApproved`. Le dossier `/project` est connu d'avance (montage fixe via docker-compose), donc on peut le pré-approuver sans interaction. Cela évite que Claude Code réaffiche le wizard de configuration (theme, confirmation du mode YOLO, trust dialog) à chaque recréation de conteneur ou reset du volume.

Un log `[SETUP] onboarding=X bypass=Y trust=Z` est affiché au démarrage pour diagnostiquer rapidement si un `.claude.json` hôte écrase un de ces flags à `false`.

### Priorité de merge

**settings.json** : prefs persistées < host settings.json < hooks conteneur (conteneur gagne toujours pour les hooks)

**.claude.json** : MCP servers < prefs persistées (avec defaults d'onboarding) < host .claude.json **filtré** (filtre dans `entrypoint.sh` : drop des champs volumineux non pertinents — `cachedGrowthBookFeatures` 17 KB, projets non-/project, caches marketing 10+ entrées)

**credentials** : fichier hôte complet (avec refreshToken, monté ro) > env var `CLAUDE_CODE_OAUTH_TOKEN` > volume partagé > `claude login`

### Volume partagé `claude-bin` (binaires Claude Code)

Le store de binaires `/home/claude/.local/share/claude/versions/` est monté sur le volume Docker partagé `claude-bin`. Sans ce volume, chaque nouveau conteneur repartait de la version baked dans l'image (ex: 2.1.114) même si `claude update` avait déjà installé une version plus récente lors d'un run précédent — résultat : tourne sur une vieille version pendant 24h à cause du throttle.

Le symlink `/home/claude/.local/bin/claude` vit dans la couche image (pas dans le volume). L'entrypoint le re-pointe automatiquement vers la dernière version trouvée dans `versions/` au démarrage (avant le `claude --version`) et après un update réussi.

### Reinitialiser les préférences

Pour forcer la reconstruction des configs depuis l'hôte (ignore le volume) :

```bash
CLAUDE_FORCE_RESEED=true ./tools/launch_shortcuts/run-claude.sh
```

## Flux de démarrage (entrypoint.sh)

1. (phase root) Fix ownership volumes (`user-config`, `mcp-memory`, `rtk-config`, `claude-bin`, `npm-cache`), seed credentials (fichier hôte complet > env var > volume partagé), symlink claude, installation SDKs .NET, traitement NuGet.Config hôte (copie + remplacement credentials DPAPI par PAT)
2. Création des répertoires `.claude/{skills,projects,sessions,plans,hooks,commands,agents,output-styles,mcp-memory,user-config}`
3. Merge settings : prefs persistées < `host-settings.json` < config hooks conteneur (trois niveaux via `jq -s '.[0] * .[1] * .[2]'`). Les hooks conteneur enregistrent `PreToolUse` (protect-config + RTK conditionnel) et `UserPromptSubmit` (git-context)
4. Build MCP : variable `MCP_SERVERS` (JSON) avec binaires directs (`mcp-server-sequential-thinking`, `context7-mcp`, etc. — pas `npx -y`) + ajouts conditionnels (filesystem/memory derrière flag, brave-search si `BRAVE_API_KEY`, playwright si chromium, github si `GITHUB_TOKEN`, dbhub si `DATABASE_URL`, docker si socket accessible), puis merge avec prefs persistées et **host-claude.json filtré**
5. Seed `CLAUDE.md` global si présent sur le volume `claude-user-config`
6. Version check : par défaut `claude update` est lancé en **arrière-plan** (la session démarre immédiatement, le swap se fait au prochain démarrage via re-pointage du symlink). Lock `.update-in-progress` évite les concurrences entre containers parallèles. Throttle 24h via `.last-update-check`. Variables : `CLAUDE_SKIP_UPDATE=true` (bypass), `CLAUDE_UPDATE_SYNC=true` (UX legacy avec barre de progression), `CLAUDE_UPDATE_INTERVAL=<sec>`, `CLAUDE_UPDATE_TIMEOUT=<sec>` (sync uniquement)
7. Statsig : volume partagé > hôte > rien
8. Git safe.directory pour `/project`
9. Trap SIGTERM pour sauvegarder les prefs avant arrêt conteneur
10. `sleep infinity` -- le conteneur reste en vie, le lanceur connecte via `docker exec -it <name> claude-session --dangerously-skip-permissions`

À l'attach (`claude-session`), avant `exec claude` : sauvegarde des prefs, puis appel au **wizard de configuration par-projet** (cf. CLAUDE.md, section "Configuration par projet"), puis `apply-project-config.sh` filtre `.claude.json` et `settings.json` selon les choix utilisateur.

## NuGet : feeds privés et cache de packages

| Élément | Emplacement | Description |
|---------|-------------|-------------|
| NuGet.Config hôte | `%APPDATA%\NuGet\NuGet.Config` -> `/home/claude/.nuget-host/NuGet.Config:ro` | Monté en ro, traité par entrypoint |
| NuGet.Config conteneur | `/home/claude/.nuget/NuGet/NuGet.Config` | Copie nettoyée (sans DPAPI) + PAT si fourni |
| Cache packages | volume `claude-nuget-cache` -> `/home/claude/.nuget/packages` | Partagé entre tous les projets |
| PAT credentials | `NUGET_PRIVATE_FEED_PAT` dans `.env` | Remplace les credentials DPAPI Windows |

Les lanceurs (`run-claude.ps1` / `run-claude.sh`) auto-détectent le NuGet.Config de l'hôte. La détection de "feed privé" couvre deux cas : (1) présence d'un bloc `<packageSourceCredentials>` (auth DPAPI historique), (2) présence d'une source `<add value="https://...">` dont l'URL n'est pas `api.nuget.org` (cas Visual Studio, où l'auth est fournie par un Credential Provider MSAL / Azure Artifact et n'est donc pas écrite dans NuGet.Config). Dans les deux cas, si aucun PAT n'est configuré, un prompt interactif demande le token (sauvegardé dans `.env`). Les credentials DPAPI et les Credential Providers VS ne fonctionnant pas sur Linux, l'entrypoint injecte le PAT en clair dans tous les feeds non-nuget.org via `dotnet nuget update source`.

## RTK (Rust Token Killer) : compression des sorties Bash

Le binaire `rtk` (téléchargé depuis [rtk-ai/rtk](https://github.com/rtk-ai/rtk)) est installé dans l'image (`/usr/local/bin/rtk`). Un hook PreToolUse appelle `rtk hook claude` (sous-commande native du binaire, pas un script séparé) qui réécrit chaque commande Bash en `rtk <commande>` — sortie filtrée/compressée, 60-90% de tokens économisés sur les opérations de dev courantes (git, npm, cargo, ls, etc.).

| Élément | Emplacement | Description |
|---------|-------------|-------------|
| Binaire rtk | `/usr/local/bin/rtk` | Téléchargé depuis releases GitHub au build (tarball musl) |
| Hook de réécriture | sous-commande `rtk hook claude` | Native, pas de script dans `container-hooks/` |
| Analytics + config + filtres | volume `claude-rtk-config` -> `/home/claude/.config/rtk` | Partagé entre tous les projets (cumul des économies via `rtk gain`, template `filters.toml`) |

Le hook RTK s'exécute APRÈS `protect-config.sh` (qui peut bloquer via exit 2). Si protect-config laisse passer, RTK réécrit `tool_input.command` pour préfixer `rtk`. L'opt-out se fait via le wizard par-projet (`hooks.rtk: false`) ou globalement via `CLAUDE_DISABLE_RTK=true` dans `.env`.

Les gains observés en pratique sur des sessions de dev courantes sont **plus modestes que les 60-90% annoncés** : 5-15% est typique (`rtk gain` permet de mesurer). Le chiffre haut est atteint surtout sur les `ls`/`du` récursifs ; la plupart des sorties `git`, `npm`, etc. sont déjà compactes et offrent peu de gain.

Commandes utiles dans le conteneur : `rtk gain` (économies cumulées), `rtk gain --history` (historique détaillé), `rtk --version`. Note : `rtk gain` prend ~4s (parsing analytics) — ne pas l'intégrer à la statusline.

## Auto-update Claude Code

Claude Code utilise l'installeur natif. Les binaires (`~/.local/share/claude/versions/`) sont persistés sur le volume partagé `claude-bin` ; le symlink `~/.local/bin/claude` vit dans la couche image et est re-pointé au démarrage vers la version la plus récente du volume (`sort -V`).

Par défaut, `entrypoint.sh` lance `claude update` **en arrière-plan détaché** : la session démarre immédiatement sur la version actuelle, et la nouvelle version (si l'update réussit) est utilisée au prochain démarrage de container. Un lock `$CONFIG_DIR/.update-in-progress` empêche deux containers parallèles de déclencher l'update en concurrence (le second skip et héritera du résultat au démarrage suivant). Throttle 24h via `$CONFIG_DIR/.last-update-check`. Log dans `/tmp/.claude-update.log`.

Variables :
- `CLAUDE_SKIP_UPDATE=true` : bypass total, utile hors ligne
- `CLAUDE_UPDATE_SYNC=true` : ancien comportement synchrone avec barre de progression — pour réseaux très lents ou debug
- `CLAUDE_UPDATE_INTERVAL=<sec>` : défaut 86400
- `CLAUDE_UPDATE_TIMEOUT=<sec>` : défaut 120, mode sync uniquement

Pour forcer un check immédiat :

```bash
docker run --rm -v claude-user-config:/data alpine rm /data/.last-update-check
```

## SDKs .NET dynamiques

Seul le SDK LTS est dans l'image. Les autres SDKs sont installés au premier démarrage selon les `.csproj` et `global.json` du projet. Sans projet .NET, .NET 10 est installé par défaut. Installation à la volée possible via `sudo install-dotnet-sdk.sh X.0`.

## MCP servers — binaires directs

Les MCP node sont lancés via leurs **binaires globaux directs** (`mcp-server-sequential-thinking`, `context7-mcp`, `brave-search-mcp-server`, `playwright-mcp`, `mcp-server-github`, `dbhub`, `mcp-server-docker`) installés dans `/home/claude/.npm-global/bin/`. Plus rapide que `npx -y <pkg>` (pas de revalidation registre, pas de spawn intermédiaire) : économie de 1-3s par MCP au démarrage de session.

Le MCP `fetch` reste en `uvx mcp-server-fetch` (Python, cache uvx). Les MCP `filesystem` et `memory` sont **désactivés par défaut** — les outils natifs Read/Edit/Write/Grep/Glob couvrent le scope filesystem, et le système auto-memory file-based remplace le MCP memory. Réactivation via `MCP_ENABLE_FILESYSTEM=true` / `MCP_ENABLE_MEMORY=true`.

## Cache npm partagé

Volume Docker `claude-npm-cache` partagé entre containers — évite de re-télécharger les packages quand on lance `npm install` / `npx` dans `/project`. Pour vider :

```bash
docker volume rm claude-npm-cache
```
