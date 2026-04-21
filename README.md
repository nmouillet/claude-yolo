# Claude Code Container

A Docker sandbox for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in YOLO mode (`--dangerously-skip-permissions`) against real development projects — without putting the host at risk.

The container ships with a curated toolchain (Node.js 22, .NET LTS SDK with on-demand install of other majors, Python 3, common CLI utilities) and a set of preconfigured MCP servers. Anthropic credentials from the host are reused automatically, and user preferences (theme, effort level, OAuth tokens) persist across projects through a shared Docker volume.

## Why

Running Claude Code with `--dangerously-skip-permissions` inside an isolated container means the agent can execute arbitrary commands without confirmation prompts — but all blast radius is confined to `/project` and a handful of named volumes. The host filesystem, shell, and system configuration remain untouched.

## Requirements

- Docker Desktop (running)
- Claude Code authenticated on the host (`claude login` at least once)
- ~5 GB free disk (~6 GB with Chromium)
- Windows: PowerShell + WSL 2; Linux/macOS: Bash

## Quick start

```bash
# 1. Clone
git clone <repo-url> claude-yolo
cd claude-yolo

# 2. Configure environment
cp .env.example .env
# Edit .env — at minimum, set CLAUDE_HOME (e.g. C:\Users\YourName on Windows)

# 3. Build the image
docker compose build

# 4. Launch against a project
./run-claude.sh                 # Linux / macOS / WSL
.\run-claude.ps1                # Windows (auto-starts Docker Desktop, delegates to WSL)
```

The launcher opens an interactive browser rooted at `sourcesRoot` (from `config.json`, defaults to the parent of the script). Pick a project, and a container named `claude-<project>` is spun up for it.

## Launchers

### Bash (`run-claude.sh`)

```bash
./run-claude.sh                       # Interactive project browser
./run-claude.sh /path/to/project      # Direct path
./run-claude.sh --build               # Rebuild image first
./run-claude.sh --prompt "run tests"  # Non-interactive (one-shot prompt)
./run-claude.sh --remote              # Remote-control mode (QR code for mobile)
./run-claude.sh --sources-root <dir>  # Override sourcesRoot for this run
```

Browser navigation: type the folder number, `0` to go up, `Enter` to select, `q` to quit.

### PowerShell (`run-claude.ps1`)

```powershell
.\run-claude.ps1                                   # Interactive
.\run-claude.ps1 -ProjectPath "C:\Sources\myapp"   # Direct path
.\run-claude.ps1 -Build                            # Rebuild first
.\run-claude.ps1 -Prompt "summarize changes"       # Non-interactive
.\run-claude.ps1 -Remote                           # Mobile remote control
```

The PowerShell script ensures Docker Desktop is running, then delegates execution to `run-claude.sh` inside WSL.

### Windows Explorer context menu

Register "Ouvrir dans Claude-Yolo" as a right-click action on any folder (no admin required — entries live in `HKCU`):

```powershell
.\install-context-menu.ps1               # Install
.\install-context-menu.ps1 -Uninstall    # Remove
.\install-context-menu.ps1 -Label "..."  # Custom label
```

Two entries are registered: right-click on a folder, and right-click in a folder's empty space. On Windows 11 the entry appears under **Show more options** (or Shift+F10).

### Project detection

Projects are highlighted in the browser when they contain any of: `.sln`, `.csproj`, `package.json`, `vite.config.*`, `.git`.

### Container reuse

Each project gets a dedicated compose project (`-p claude-<name>`), so multiple containers can run in parallel without interference. An existing container is reused when it already exists; to force recreation:

```bash
docker compose -p claude-<name> down
```

## Configuration

### `config.json`

| Field | Description | Default |
|-------|-------------|---------|
| `sourcesRoot` | Root directory of your projects (accepts Windows paths) | Parent of the script |

### Environment variables (`.env`)

| Variable | Required | Description |
|----------|----------|-------------|
| `CLAUDE_HOME` | Yes | Host user profile containing `.claude/` (e.g. `C:\Users\You`) |
| `PROJECT_PATH` | Auto | Injected by the launcher |
| `GITHUB_TOKEN` | No | Enables the GitHub MCP server and `gh` CLI |
| `BRAVE_API_KEY` | No | Enables the Brave Search MCP server |
| `DATABASE_URL` | No | Enables the dbhub MCP server |
| `NUGET_PRIVATE_FEED_PAT` | No | PAT for private NuGet feeds (replaces Windows DPAPI credentials) |
| `INSTALL_CHROMIUM` | No | `true` (default) or `false` to skip Chromium and save ~500 MB |
| `MEMORY_LIMIT` | No | Container memory cap (default `8G`) |
| `CPU_LIMIT` | No | Container CPU cap (default `4.0`) |
| `CLAUDE_FORCE_RESEED` | No | `true` to rebuild configs from host and ignore the shared volume |
| `CLAUDE_SKIP_UPDATE` | No | `true` to skip the startup `claude update` check |

### Build arguments

```bash
docker compose build --build-arg INSTALL_CHROMIUM=false   # Skip Chromium (~500 MB)
docker compose build --no-cache                           # Full rebuild after Dockerfile edits
```

## Credentials and preferences

User preferences and OAuth credentials are stored in the shared Docker volume `claude-user-config`, attached to every container. A single `claude login` (or `/config` tweak) persists across projects and container recreations.

| File in volume | Purpose |
|----------------|---------|
| `credentials.json` | Full OAuth payload with `refreshToken` |
| `user-preferences.json` | Theme, editor mode, onboarding flags, OAuth account |
| `user-settings.json` | Effort level, language, view mode, forced login method |
| `statsig/` | Feature-flag cache (skips first-run login prompt) |

Resolution order for credentials: host `~/.claude/.credentials.json` (mounted read-only) → `CLAUDE_CODE_OAUTH_TOKEN` env var → shared volume → interactive `claude login` inside the container.

The launchers check token expiry before starting and trigger `claude setup-token` on the host if the token is stale.

## MCP servers

Always active:

| Server | Purpose |
|--------|---------|
| `filesystem` | Access to `/project` |
| `memory` | Persistent knowledge graph (per-project volume `claude-mcp-memory-<name>`) |
| `sequential-thinking` | Structured step-by-step reasoning |
| `fetch` | Web content retrieval |
| `context7` | Up-to-date library/framework documentation |

Conditional (auto-enabled when their prerequisite is present):

| Server | Condition |
|--------|-----------|
| `brave-search` | `BRAVE_API_KEY` set |
| `github` | `GITHUB_TOKEN` set |
| `playwright` | Chromium installed in the image |
| `dbhub` | `DATABASE_URL` set |
| `docker` | Docker socket mounted (see `docker-compose.yml`) |

MCP configurations from the host `~/.claude.json` are merged at startup — host entries win over container defaults.

## NuGet (.NET)

The host's `NuGet.Config` is auto-detected and mounted read-only. The entrypoint copies it, strips DPAPI-encrypted credentials (they can't be decrypted on Linux), and injects `NUGET_PRIVATE_FEED_PAT` when private feeds are detected. If no PAT is configured, the launcher prompts for one on first run.

Packages are cached in the shared `claude-nuget-cache` volume — not the Windows host cache, to avoid cross-platform conflicts with native dependencies.

## .NET SDKs

Only the LTS SDK is baked into the image. Additional majors are installed at startup based on `global.json` and `.csproj` files in the project. Manual install from inside the container:

```bash
sudo install-dotnet-sdk.sh 9.0
sudo install-dotnet-sdk.sh 10.0
```

## Security model

- **No new privileges** (`security_opt: no-new-privileges:true`), non-root `claude` user
- **Writable**: `/project` and a handful of `.claude/` subdirectories that persist to the host
- **Read-only mounts**: host credentials, host settings, statsig cache, host `NuGet.Config`
- **Hook `protect-config.sh`**: intercepts `Read`, `Edit`, `Write`, `Grep`, `Glob`, and `Bash` calls, blocking access to `appsettings*.json`, `.env*`, certificates, and any file covered by the project's `.gitignore`
- **Shared credentials volume**: a refresh in one container benefits all others

`--dangerously-skip-permissions` means Claude runs every command without asking — the Docker boundary is what makes that safe.

## Startup flow

1. **Root phase**: fix volume ownership, seed credentials (host file → env var → shared volume), symlink `claude`, install required .NET SDKs, stage `NuGet.Config`
2. **Claude phase** (via `gosu`): create `.claude/` subdirs, merge settings (`persisted < host < container hooks`), build MCP config (static entries + conditionals), run `claude update` (timeout 20 s, once per 24 h)
3. `sleep infinity` — the container stays alive; the launcher attaches with `docker exec -it <name> claude-session --dangerously-skip-permissions`
4. On `SIGTERM`, user preferences are flushed back to the shared volume before exit

A `[SETUP]` log line summarizes onboarding flags so you can quickly spot a host `.claude.json` that overrides them.

## Common tasks

| Task | Command / file |
|------|----------------|
| Add a system package | `Dockerfile` section 1 / 1a + rebuild |
| Add an npm-based MCP server | `Dockerfile` section 5c + `container/entrypoint.sh` (MCP_SERVERS or conditional block) |
| Add an environment variable | `.env.example` + `docker-compose.yml` + `entrypoint.sh` (if read at startup) |
| Modify the protection hook | `container/protect-config.sh` + rebuild |
| Change resource limits | `.env` (`MEMORY_LIMIT`, `CPU_LIMIT`) |
| Reset user preferences | `CLAUDE_FORCE_RESEED=true` in `.env` or environment |
| Inspect the shared volume | `docker run --rm -v claude-user-config:/data alpine ls -la /data` |
| Force an update check | `docker run --rm -v claude-user-config:/data alpine rm /data/.last-update-check` |
| Clear the NuGet cache | `docker volume rm claude-nuget-cache` |
| Mobile access | `./run-claude.sh --remote` → scan the QR code with the Claude mobile app |
| Windows Explorer integration | `.\install-context-menu.ps1` (right-click a folder → "Ouvrir dans Claude-Yolo") |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Token expired (401) | The launcher handles refresh automatically; if it fails, run `claude setup-token` on the host |
| Container won't start | Verify Docker Desktop is running and paths in `.env` are correct |
| MCP server not detected | Check that its activation variable is set in `.env` |
| Image too large | Rebuild with `INSTALL_CHROMIUM=false` |
| Force container recreation | `docker compose -p claude-<name> down` |
| `safe.directory` git error | Ensure `/project` contains a `.git` directory |

## Included tooling

| Category | Tools |
|----------|-------|
| Languages | Node.js 22, .NET LTS (others on demand), Python 3 |
| Package managers | npm, yarn, pnpm, pip, uv, `dotnet-ef` |
| CLIs | `git`, `gh`, `lazygit`, `jq`, `yq`, `ripgrep`, `fd`, `bat`, `fzf`, `tree`, `httpie`, `shellcheck`, `delta` |
| Frontend | TypeScript, ESLint, Prettier, vue-tsc, npm-check-updates |
| Browser | Chromium (optional, for Playwright MCP) |

## License

See [LICENSE](LICENSE).
