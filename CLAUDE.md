# Claude Code Container

Environnement Docker (Ubuntu 24.04) pour executer Claude Code CLI en mode YOLO sur des projets de dev. Pas de framework applicatif : uniquement du scripting Docker, Bash et PowerShell.

## Architecture des fichiers

```
claude-yolo/
├── run-claude.sh              # Lanceur principal (Bash/WSL)
├── run-claude.ps1             # Wrapper Windows : demarre Docker Desktop puis delegue a WSL
├── config.json                # Config lanceur : sourcesRoot (optionnel, defaut = parent du script)
├── Dockerfile                 # Image conteneur (9 sections numerotees)
├── docker-compose.yml         # Service claude-worker, volumes, limites ressources
├── .dockerignore              # Exclut lanceurs, docs, config du contexte de build
├── .env.example               # Template des variables d'environnement pour docker-compose
├── .gitignore
├── CLAUDE.md
├── README.md
├── container/                 # Scripts copies dans l'image Docker (COPY)
│   ├── entrypoint.sh          # Orchestration demarrage (root puis claude via gosu)
│   ├── claude-session.sh      # Wrapper claude : sauvegarde prefs a la sortie
│   ├── protect-config.sh      # Hook PreToolUse : bloque acces fichiers sensibles
│   ├── statusline.sh          # Affichage modele, cout, contexte dans le terminal
│   ├── install-dotnet.sh      # Detection et installation SDKs .NET au demarrage
│   └── install-dotnet-sdk.sh  # Installation SDK .NET a la volee (sudo install-dotnet-sdk.sh X.0)
└── .claude/
    └── settings.local.json    # Whitelist commandes pour le mode dev local
```

## Persistance des preferences utilisateur

Les preferences Claude Code (credentials, theme, effort level, etc.) sont stockees dans un **volume Docker partage** `claude-user-config`, commun a tous les projets. Cela permet de configurer une seule fois (`claude login`, `/config`) et que les parametres persistent entre les sessions et les projets.

### Volume partage `claude-user-config`

| Fichier dans le volume | Contenu | Ecrit par |
|------------------------|---------|-----------|
| `credentials.json` | Token OAuth complet (avec refreshToken) | `entrypoint.sh` (copie depuis fichier hote ou `claude login` via `claude-session`) |
| `user-preferences.json` | Theme, editorMode, flags d'onboarding (`hasCompletedOnboarding`, `bypassPermissionsModeAccepted`, `hasTrustDialogsShown`, `tipsHistory`, `oauthAccount`, `userID`, `firstStartTime`, `projects`, etc.) | `claude-session` (sauvegarde a la sortie) |
| `user-settings.json` | effortLevel, language, viewMode, forceLoginMethod, etc. | `claude-session` (sauvegarde a la sortie) |
| `statsig/` | Cache feature flags (evite le prompt de login) | `entrypoint.sh` |

### Pas de faux premier lancement

`entrypoint.sh` ecrit des defaults dans `.claude.json` qui pre-approuvent l'onboarding complet : `hasCompletedOnboarding`, `bypassPermissionsModeAccepted`, `hasTrustDialogsShown`, `hasAvailableSubscription`, et `projects["/project"].hasTrustDialogAccepted` / `hasClaudeMdExternalIncludesApproved`. Le dossier `/project` est connu d'avance (montage fixe via docker-compose), donc on peut le pre-approuver sans interaction. Cela evite que Claude Code reaffiche le wizard de configuration (theme, confirmation du mode YOLO, trust dialog) a chaque recreation de conteneur ou reset du volume.

Un log `[SETUP] onboarding=X bypass=Y trust=Z` est affiche au demarrage pour diagnostiquer rapidement si un `.claude.json` hote ecrase un de ces flags a `false`.

### Priorite de merge

**settings.json** : prefs persistees < host settings.json < hooks conteneur (conteneur gagne toujours pour les hooks)

**.claude.json** : MCP servers < prefs persistees (avec defaults d'onboarding) < host .claude.json (hote gagne toujours)

**credentials** : fichier hote complet (avec refreshToken, monte ro) > env var `CLAUDE_CODE_OAUTH_TOKEN` > volume partage > `claude login`

### NuGet : feeds prives et cache de packages

| Element | Emplacement | Description |
|---------|-------------|-------------|
| NuGet.Config hote | `%APPDATA%\NuGet\NuGet.Config` -> `/home/claude/.nuget-host/NuGet.Config:ro` | Monte en ro, traite par entrypoint |
| NuGet.Config conteneur | `/home/claude/.nuget/NuGet/NuGet.Config` | Copie nettoyee (sans DPAPI) + PAT si fourni |
| Cache packages | volume `claude-nuget-cache` -> `/home/claude/.nuget/packages` | Partage entre tous les projets |
| PAT credentials | `NUGET_PRIVATE_FEED_PAT` dans `.env` | Remplace les credentials DPAPI Windows |

Les lanceurs (`run-claude.ps1` / `run-claude.sh`) auto-detectent le NuGet.Config de l'hote. Si des feeds prives sont detectes et qu'aucun PAT n'est configure, un prompt interactif demande le token (sauvegarde dans `.env`). Les credentials DPAPI de Windows ne fonctionnant pas sur Linux, l'entrypoint les remplace par le PAT en clair via `dotnet nuget update source`.

### Reinitialiser les preferences

Pour forcer la reconstruction des configs depuis l'hote (ignore le volume) :
```bash
CLAUDE_FORCE_RESEED=true ./run-claude.sh
```

## Flux de demarrage (entrypoint.sh)

1. (phase root) Fix ownership volumes, seed credentials (fichier hote complet > env var > volume partage), symlink claude, installation SDKs .NET, traitement NuGet.Config hote (copie + remplacement credentials DPAPI par PAT)
2. Creation des repertoires `.claude/{skills,projects,sessions,plans,hooks,mcp-memory,user-config}`
3. Merge settings : prefs persistees < `host-settings.json` < config hooks conteneur (trois niveaux via `jq -s '.[0] * .[1] * .[2]'`)
4. Build MCP : variable `MCP_SERVERS` (JSON) + ajouts conditionnels (brave-search si `BRAVE_API_KEY`, playwright si chromium, github si `GITHUB_TOKEN`, dbhub si `DATABASE_URL`, docker si socket accessible), puis merge avec prefs persistees et host-claude.json
5. Version check : `claude update` synchrone avec timeout 20s (affiche l'ancienne et la nouvelle version si maj). Contournable via `CLAUDE_SKIP_UPDATE=true`
6. Statsig : volume partage > hote > rien
7. Git safe.directory pour `/project`
8. Trap SIGTERM pour sauvegarder les prefs avant arret conteneur
9. `sleep infinity` -- le conteneur reste en vie, le lanceur connecte via `docker exec -it <name> claude-session --dangerously-skip-permissions`

## Conventions et patterns

- **Fusion JSON** : toujours `jq -s '.[0] * .[1]'` (ou `.[0] * .[1] * .[2]` pour trois niveaux) -- le dernier argument ecrase les precedents
- **MCP conditionnels** : pattern `if [ -n "${VAR:-}" ]; then ... fi` pour les variables d'env, `if [ -S /path ]; then ... fi` pour les sockets, `if command -v X &> /dev/null; then ... fi` pour les binaires
- **Volumes** : convention stricte ro/rw. Host credentials (via `HOST_CREDENTIALS_PATH`, fichier complet avec refreshToken), settings, statsig, NuGet.Config en ro (seeds). Skills, projects, hooks, plans, sessions en rw (persistent sur l'hote). `claude-user-config` volume Docker partage (prefs utilisateur). `claude-nuget-cache` volume partage (cache packages NuGet). MCP memory sur volume nomme par projet. Socket Docker optionnel (commente par defaut dans docker-compose.yml). Pattern fallback fichier vide pour les mounts conditionnels (`HOST_CREDENTIALS_PATH`, `NUGET_CONFIG_PATH`)
- **Nommage conteneurs** : `claude-<nom-projet-normalise>` (lowercase, caracteres non-alphanumeriques remplaces par `-`)
- **Isolation compose** : chaque projet lance un projet compose distinct (`-p claude-<nom>`) via la fonction `dc()` dans les lanceurs, permettant plusieurs containers en parallele
- **Hooks** : stdin = JSON avec `tool_name` et `tool_input`, exit code 0 = OK, exit code 2 = blocage. Le hook `protect-config.sh` intercepte Read, Edit, Write, Grep, Glob et Bash. Il bloque aussi les fichiers matches par `.gitignore` du projet (via `git check-ignore`)
- **Messages** : messages utilisateur en francais dans les scripts, commentaires de code en anglais
- **Sections Dockerfile** : numerotees avec `# ---------- N. Description ----------`

## Commandes utiles

```bash
# Construire l'image
docker compose build

# Construire sans cache (apres modification Dockerfile)
docker compose build --no-cache

# Construire sans Chromium
docker compose build --build-arg INSTALL_CHROMIUM=false

# Supprimer un conteneur specifique et son volume MCP memory
docker compose -p claude-monprojet down --volumes

# Voir les logs d'un conteneur specifique
docker compose -p claude-monprojet logs claude-worker

# Lancer un shell dans l'image (debug)
PROJECT_PATH="." CLAUDE_HOME="$HOME" PROJECT_NAME="debug" \
  docker compose run --rm --entrypoint bash claude-worker

# Lancer via les scripts
./run-claude.sh --build                       # WSL/Linux + rebuild
.\run-claude.ps1 -Build                       # Windows (delegue a WSL)
./run-claude.sh --prompt "fais un resume"     # Mode non-interactif
./run-claude.sh --remote                      # Mode remote-control (QR code pour smartphone)
.\run-claude.ps1 -Remote                      # Idem depuis Windows

# Installer un SDK .NET a la volee (dans le conteneur)
sudo install-dotnet-sdk.sh 9.0
sudo install-dotnet-sdk.sh 10.0

# Reinitialiser les configs depuis l'hote
CLAUDE_FORCE_RESEED=true docker compose -p claude-monprojet up -d

# Voir le contenu du volume partage
docker run --rm -v claude-user-config:/data alpine ls -la /data
```

## Contraintes importantes

- **Pas de tests automatises** : validation manuelle uniquement
- **Pas de CI/CD** : image construite et utilisee localement
- **Chemins Windows** : `run-claude.ps1` convertit via `wslpath`, `run-claude.sh` convertit `sourcesRoot` de `config.json` (`C:\` -> `/c/`)
- **Credentials** : le fichier hote (`~/.claude/.credentials.json` ou l'ancien `~/.claude/credentials/.credentials.json`, on prend le plus recent par mtime) est monte en ro via `HOST_CREDENTIALS_PATH`. Il contient le `refreshToken` permettant au CLI de rafraichir automatiquement l'accessToken. Les deux lanceurs (`run-claude.ps1` et `run-claude.sh`) verifient `expiresAt` avant le lancement ; si le token est expire ils relancent `claude auth login` sur l'hote. Fallback : env var `CLAUDE_CODE_OAUTH_TOKEN` (CI) > volume partage > `claude login` dans le conteneur
- **Playwright remplace Puppeteer** : l'automatisation navigateur utilise `@playwright/mcp` (plus moderne, mieux maintenu). Active conditionnellement si `chromium` est present dans l'image
- **protect-config.sh est dans l'image** (`container/protect-config.sh` -> `/home/claude/.claude/container-hooks/`, hors du montage `hooks` rw) : toute modification necessite un rebuild
- **jq est une dependance critique** de `entrypoint.sh` (merge JSON, lecture credentials, build MCP)
- **Le .dockerignore exclut `*.md`** : les fichiers README.md et CLAUDE.md ne sont pas dans l'image Docker (c'est voulu)
- **Auto-update** : Claude Code utilise l'installeur natif (`~/.local/bin/claude`). `entrypoint.sh` execute `claude update` synchrone (timeout 45s) au plus une fois toutes les 24h, grace a un marqueur `$CONFIG_DIR/.last-update-check` partage entre containers. Log dans `/tmp/.claude-update.log`. Variables : `CLAUDE_SKIP_UPDATE=true` (bypass total, utile hors ligne), `CLAUDE_UPDATE_INTERVAL=<sec>` (defaut 86400). Pour forcer un check immediat : `docker run --rm -v claude-user-config:/data alpine rm /data/.last-update-check`
- **SDKs .NET dynamiques** : seul le SDK LTS est dans l'image. Les autres SDKs sont installes au premier demarrage selon les `.csproj` et `global.json` du projet. Sans projet .NET, .NET 10 est installe par defaut. Installation a la volee possible via `sudo install-dotnet-sdk.sh X.0`
- **Volume `claude-user-config`** : partage entre tous les conteneurs (external: true). Cree automatiquement par `run-claude.sh`. Ne pas lancer deux conteneurs en parallele avec le meme volume (conflit d'ecriture)
- **NuGet.Config DPAPI** : les credentials chiffrees DPAPI du NuGet.Config Windows ne fonctionnent pas sur Linux. Utiliser `NUGET_PRIVATE_FEED_PAT` pour les feeds prives (prompt interactif au premier lancement si feeds prives detectes)
- **Cache NuGet** : volume Docker `claude-nuget-cache` partage entre projets (pas le cache hote Windows, pour eviter les conflits cross-platform avec les packages natifs)

## Scenarios de modification courants

| Scenario | Fichiers a modifier |
|----------|-------------------|
| Ajouter un outil systeme | `Dockerfile` section 1 ou 1a |
| Ajouter un serveur MCP npm | `Dockerfile` section 5c + `container/entrypoint.sh` (MCP_SERVERS ou bloc conditionnel) |
| Ajouter une variable d'environnement | `.env.example` + `docker-compose.yml` (environment) + `container/entrypoint.sh` si utilisee au demarrage |
| Modifier le hook de protection | `container/protect-config.sh` (+ rebuild necessaire) |
| Changer les limites ressources | `.env` (MEMORY_LIMIT, CPU_LIMIT) |
| Ajouter un SDK .NET | Automatique au demarrage si le projet le requiert. A la volee : `sudo install-dotnet-sdk.sh X.0`. SDK de base : `Dockerfile` section 3 |
| Changer le theme par defaut | Dans le conteneur : `/config` puis quitter. Les prefs sont sauvegardees automatiquement |
| Token OAuth expire (401) | Automatique : `run-claude.sh` detecte l'expiration et lance `claude setup-token`. Manuel : `claude setup-token` sur l'hote puis relancer |
| Acceder depuis smartphone | `./run-claude.sh --remote` → QR code → scanner depuis l'app Claude mobile |
| Forcer le type de login | `.env` (`CLAUDE_FORCE_RESEED=true`) puis dans le conteneur : `claude login` |
| Reinitialiser les preferences | `CLAUDE_FORCE_RESEED=true` dans `.env` ou en variable d'environnement |
| Configurer un feed NuGet prive | `.env` (`NUGET_PRIVATE_FEED_PAT`), le NuGet.Config hote fournit les URLs |
| Vider le cache NuGet | `docker volume rm claude-nuget-cache` |
