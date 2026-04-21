<#
.SYNOPSIS
    Wrapper Windows pour run-claude.sh via WSL.
.DESCRIPTION
    Demarre Docker Desktop si necessaire, lance l'authentification navigateur,
    puis delegue a run-claude.sh dans WSL pour toute la logique.
.EXAMPLE
    .\run-claude.ps1
    .\run-claude.ps1 -ProjectPath "C:\Sources\mon-projet"
    .\run-claude.ps1 -Prompt "Lance check-updates"
    .\run-claude.ps1 -Build
    .\run-claude.ps1 -Remote
    .\run-claude.ps1 -Remote -ProjectPath "C:\Sources\mon-projet"
#>

[CmdletBinding()]
param(
    [string]$ProjectPath,
    [string]$Prompt,
    [switch]$Build,
    [switch]$Remote
)

$ErrorActionPreference = "Stop"

# -- Ensure Docker Desktop is running --
$ErrorActionPreference = "Continue"
docker info > $null 2>&1
$dockerRunning = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = "Stop"

if (-not $dockerRunning) {
    $dockerPath = "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path $dockerPath)) {
        Write-Error "Docker Desktop introuvable dans $dockerPath"
        exit 1
    }
    Write-Host "  Demarrage de Docker Desktop..." -ForegroundColor Yellow
    Start-Process $dockerPath

    $timeout = 60
    $elapsed = 0
    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds 2
        $elapsed += 2
        $ErrorActionPreference = "Continue"
        docker info > $null 2>&1
        $ready = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = "Stop"
        if ($ready) { break }
        Write-Host "  Attente du daemon Docker... ($elapsed s)" -ForegroundColor DarkGray
    }

    if (-not $ready) {
        Write-Error "Docker Desktop n'a pas demarre apres ${timeout}s"
        exit 1
    }
    Write-Host "  Docker Desktop pret." -ForegroundColor Green
    Write-Host ""
}

# -- Path conversion helper (Windows -> WSL /mnt/c/...) --
# wslpath is unreliable (returns Docker Desktop internal paths)
function ConvertTo-WslPath {
    param([string]$WinPath)
    $drive = $WinPath.Substring(0, 1).ToLower()
    $rest = $WinPath.Substring(2).Replace("\", "/")
    return "/mnt/$drive$rest"
}

# -- Convert script dir to WSL path --
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WslScriptDir = ConvertTo-WslPath $ScriptDir

# -- Build args for run-claude.sh --
$shArgs = @()

if ($Build) {
    $shArgs += "--build"
}

if ($Remote) {
    $shArgs += "--remote"
}

if ($Prompt) {
    $shArgs += "--prompt"
    $shArgs += "`"$Prompt`""
}

if ($ProjectPath) {
    $resolvedPath = (Resolve-Path $ProjectPath).Path
    $wslProjectPath = ConvertTo-WslPath $resolvedPath
    $shArgs += "`"$wslProjectPath`""
}

# -- OAuth: run auth login, then pass credentials to WSL --
$SourcesRootWin = Split-Path -Parent $ScriptDir
$WslSourcesRoot = ConvertTo-WslPath $SourcesRootWin
$WslUserProfile = ConvertTo-WslPath $env:USERPROFILE

$envPrefix = ""

# Claude Code has used both locations over time; pick the most recently modified
# so a stale legacy file never wins over a freshly-refreshed one.
$CredCandidates = @(
    (Join-Path $env:USERPROFILE ".claude\.credentials.json"),
    (Join-Path $env:USERPROFILE ".claude\credentials\.credentials.json")
) | Where-Object { Test-Path $_ } | Sort-Object { (Get-Item $_).LastWriteTime } -Descending

# Check for existing valid credentials (with refresh token = auto-renewable).
# Also precheck expiresAt: a stale refreshToken may be revoked server-side, so
# re-auth here is safer than letting the container 401 on the first message.
$hasValidCreds = $false
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
foreach ($path in $CredCandidates) {
    try {
        $json = Get-Content $path -Raw | ConvertFrom-Json
        $exp = [int64]($json.claudeAiOauth.expiresAt)
        if ($json.claudeAiOauth.accessToken -and $json.claudeAiOauth.refreshToken) {
            if ($exp -lt $nowMs) {
                $ageMin = [math]::Round(($nowMs - $exp) / 60000)
                Write-Host "  Token OAuth expire depuis ${ageMin} min - reauthentification requise." -ForegroundColor Yellow
            } else {
                $hasValidCreds = $true
                Write-Host "  Credentials existantes reutilisees." -ForegroundColor Green
            }
            break
        }
    } catch {}
}

if (-not $hasValidCreds) {
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeCmd) {
        Write-Host "  Authentification via navigateur..." -ForegroundColor Yellow

        $ErrorActionPreference = "Continue"
        & claude auth login
        $ErrorActionPreference = "Stop"

        Write-Host "  Auth login terminee." -ForegroundColor Green
    } else {
        Write-Host "  CLI Claude absente sur Windows - auth dans WSL." -ForegroundColor DarkGray
    }
}

# Always pass credentials to WSL if available (after auth login or from existing file).
# Re-list candidates in case `claude auth login` just created a new file.
$CredB64 = ""
$FreshCandidates = @(
    (Join-Path $env:USERPROFILE ".claude\.credentials.json"),
    (Join-Path $env:USERPROFILE ".claude\credentials\.credentials.json")
) | Where-Object { Test-Path $_ } | Sort-Object { (Get-Item $_).LastWriteTime } -Descending

foreach ($path in $FreshCandidates) {
    try {
        $json = Get-Content $path -Raw | ConvertFrom-Json
        if ($json.claudeAiOauth.accessToken) {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $CredB64 = [Convert]::ToBase64String($bytes)
            break
        }
    } catch {}
}

# CLAUDE_HOME must point to Windows home so docker-compose mounts the real host files
$envPrefix = "WIN_USERPROFILE='$WslUserProfile' CLAUDE_HOME='$WslUserProfile' "
if ($CredB64) {
    $envPrefix += "CLAUDE_CREDENTIALS_B64='$CredB64' "
}

# -- NuGet.Config auto-detection --
$NuGetConfigWin = Join-Path $env:APPDATA "NuGet\NuGet.Config"
if (Test-Path $NuGetConfigWin) {
    $NuGetConfigWsl = ConvertTo-WslPath $NuGetConfigWin
    $envPrefix += "NUGET_CONFIG_PATH='$NuGetConfigWsl' "
}

# -- Fix CRLF line endings for WSL (Windows git may checkout with CRLF) --
wsl -e bash -c "cd '$WslScriptDir' && sed -i 's/\r$//' run-claude.sh 2>/dev/null"

# -- Delegate to WSL --
$argString = $shArgs -join " "
if ($WslSourcesRoot) {
    $argString = "--sources-root '$WslSourcesRoot' $argString".Trim()
}
wsl -e bash -c "cd '$WslScriptDir' && ${envPrefix}./run-claude.sh $argString"
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "  Echec du lanceur (exit code $exitCode). Appuie sur Entree pour fermer..." -ForegroundColor Red
    $null = Read-Host
}

exit $exitCode
