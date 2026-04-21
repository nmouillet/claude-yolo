# Claude Code Container

Environnement Docker isole pour executer [Claude Code](https://docs.anthropic.com/en/docs/claude-code) en mode YOLO (`--dangerously-skip-permissions`) sur des projets de developpement. Le conteneur embarque les SDK .NET 6-9, Node.js 22, Python 3, des serveurs MCP preconfigures et des outils CLI courants.

L'interet principal : Claude Code s'execute dans un bac a sable Docker avec des permissions dangereuses activees, sans risque pour le systeme hote. Les credentials Anthropic de l'hote sont reutilises automatiquement.

## Prerequis

- **Docker Desktop** installe et demarre
- **Claude Code** authentifie sur l'hote (`claude login` prealable)
- ~5 Go d'espace disque (~6 Go avec Chromium)

## Demarrage rapide

```bash
# 1. Cloner le depot
git clone <url-du-depot> _claude-container
cd _claude-container

# 2. Configurer l'environnement
cp .env.example .env
# Editer .env : renseigner CLAUDE_HOME (ex: C:\Users\VotreNom)

# 3. Ajuster config.json si necessaire
# sourcesRoot : racine de vos projets (pour le navigateur interactif)

# 4. Construire l'image
docker compose build

# 5. Lancer
.\run-claude.ps1        # Windows (PowerShell)
./run-claude.sh         # Linux / macOS / Git Bash
```

## Configuration

### config.json

| Champ | Description | Defaut |
|-------|-------------|--------|
| `sourcesRoot` | Racine des projets sources (chemin Windows) | `C:\Users\<user>\Documents\Sources` |
| `memory` | Limite memoire du conteneur | `8G` |
| `cpus` | Limite CPU du conteneur | `4.0` |

### Variables d'environnement (.env)

| Variable | Requis | Description |
|----------|--------|-------------|
| `PROJECT_PATH` | Auto | Chemin du projet (rempli par les lanceurs) |
| `CLAUDE_HOME` | Oui | Repertoire profil utilisateur contenant `.claude/` |
| `GITHUB_TOKEN` | Non | Active le serveur MCP GitHub et `gh` CLI |
| `BRAVE_API_KEY` | Non | Active le serveur MCP Brave Search |
| `DATABASE_URL` | Non | Chaine de connexion base de donnees |
| `INSTALL_CHROMIUM` | Non | `true` (defaut) ou `false` pour economiser ~500 Mo |
| `MEMORY_LIMIT` | Non | Limite memoire conteneur (defaut `8G`) |
| `CPU_LIMIT` | Non | Limite CPU conteneur (defaut `4.0`) |

### Argument de build

```bash
# Desactiver Chromium (economise ~500 Mo)
docker compose build --build-arg INSTALL_CHROMIUM=false
```

## Utilisation

### Lanceur PowerShell (Windows)

```powershell
.\run-claude.ps1                              # Navigateur interactif
.\run-claude.ps1 -ProjectPath "C:\Sources\x"  # Chemin direct
.\run-claude.ps1 -Build                       # Reconstruire avant de lancer
.\run-claude.ps1 -Prompt "Lance check-updates" # Mode non-interactif
```

Navigation dans le navigateur interactif :
- Fleches haut/bas : naviguer
- Entree : ouvrir un sous-dossier
- Espace : selectionner le dossier courant (si projet detecte)
- Retour arriere : remonter
- P : saisir un chemin manuellement
- Echap : quitter

### Lanceur Bash (Linux / macOS / Git Bash)

```bash
./run-claude.sh                    # Navigateur interactif
./run-claude.sh /chemin/projet     # Chemin direct
./run-claude.sh --build            # Reconstruire avant de lancer
./run-claude.sh --prompt "texte"   # Mode non-interactif
```

Navigation : saisir le numero du dossier, 0 pour remonter, Entree pour selectionner, q pour quitter.

### Detection de projets

Les lanceurs detectent les projets par la presence de : `.sln`, `.csproj`, `package.json`, `vite.config.*`, `.git`. Les dossiers contenant ces indicateurs sont mis en surbrillance.

### Reutilisation de conteneurs

Les lanceurs reutilisent automatiquement un conteneur existant nomme `claude-<nom-projet>`. Pour forcer une recreation :

```bash
docker compose down
# puis relancer normalement
```

## Serveurs MCP

### Toujours actifs

| Serveur | Fonction |
|---------|----------|
| `fetch` | Recuperation de contenu web (uvx mcp-server-fetch) |
| `memory` | Memoire persistante entre sessions (volume Docker `claude-mcp-memory`) |
| `sequential-thinking` | Raisonnement structure etape par etape |
| `filesystem` | Acces au systeme de fichiers du projet (`/project`) |

### Conditionnels

| Serveur | Condition d'activation |
|---------|----------------------|
| `brave-search` | Variable `BRAVE_API_KEY` definie dans `.env` |
| `github` | Variable `GITHUB_TOKEN` definie dans `.env` |
| `puppeteer` | Chromium installe (`INSTALL_CHROMIUM=true`) |

Les configurations MCP de l'hote (`~/.claude.json`) sont automatiquement fusionnees au demarrage. Les configs de l'hote ont priorite sur celles du conteneur.

## Securite

- **Isolation Docker** : option `no-new-privileges:true`, utilisateur non-root `claude`
- **Volumes en ecriture** : `/project`, skills, projects, hooks, plans, sessions (persistent sur l'hote)
- **Volumes en lecture seule** : credentials, settings, statsig montes en `:ro`
- **Hook protect-config.sh** : intercepte les outils Read, Grep, Glob, Bash avant tout acces aux fichiers sensibles (`appsettings*.json`, `.env*`, certificats, etc.) et aux fichiers listes dans `.gitignore`
- **Credentials partagees** : volume nomme `claude-credentials` partage entre tous les containers (un login/refresh beneficie a tous)
- **Volume nomme** : `claude-mcp-memory` persiste entre recreations de conteneur
- **Repertoires persistants** : skills, projects, hooks, plans, sessions montes en lecture-ecriture depuis l'hote

Le mode `--dangerously-skip-permissions` signifie que Claude execute toutes les commandes sans confirmation -- d'ou l'importance de l'isolation Docker.

## Personnalisation

### Ajouter des outils

Modifier le `Dockerfile` dans la section appropriee :
- Section 1 (apt-get) : paquets systeme
- Section 5c (npm install -g) : serveurs MCP Node.js
- Section 5d (npm install -g) : outils de dev
- Section 5a : outils .NET globaux

Reconstruire avec `docker compose build` ou `--build`.

### Modifier les permissions

Editer les settings Claude de l'hote (`~/.claude/settings.json`), qui sont fusionnes au demarrage du conteneur via `entrypoint.sh`.

### Ajouter un serveur MCP

1. Si le serveur est un package npm, l'ajouter dans le Dockerfile section 5c
2. Ajouter sa configuration dans `entrypoint.sh` (variable `MCP_SERVERS` pour toujours actif, ou bloc conditionnel `if [ -n "${MA_VARIABLE:-}" ]` pour conditionnel)
3. Ajouter la variable d'environnement dans `docker-compose.yml` et `.env.example`

## Depannage

| Probleme | Solution |
|----------|----------|
| Token expire | Le refresh est automatique et partage entre containers. Si echec : relancer `claude login` sur l'hote ou dans un container (le volume partage propage le nouveau token) |
| Conteneur ne demarre pas | Verifier que Docker Desktop est actif et que les chemins dans `.env` sont corrects |
| Serveur MCP non detecte | Verifier que la variable d'environnement correspondante est definie dans `.env` |
| Image trop volumineuse | Desactiver Chromium : `INSTALL_CHROMIUM=false` |
| Forcer recreation conteneur | `docker compose -p claude-monprojet down` puis relancer |
| Erreur Git safe.directory | Normalement automatique ; verifier que `/project` contient bien un `.git` |

## Outils installes

| Categorie | Outils |
|-----------|--------|
| Langages | Node.js 22, .NET 6/7/8/9, Python 3 |
| Gestionnaires de paquets | npm, yarn, pnpm, pip, uv, dotnet-ef |
| CLI | git, gh, lazygit, jq, ripgrep, fd, bat, fzf, tree, httpie, shellcheck |
| Dev frontend | TypeScript, ESLint, Prettier, vue-tsc |
| Navigateur | Chromium (optionnel, pour Puppeteer) |
