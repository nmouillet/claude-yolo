<#
.SYNOPSIS
    Ajoute/supprime l'entree "Ouvrir dans Claude-Yolo" dans le menu contextuel Windows.
.DESCRIPTION
    Enregistre run-claude.ps1 dans HKCU\Software\Classes\Directory pour qu'il soit
    accessible via clic droit sur un dossier, ou dans l'arriere-plan d'un dossier.
    Aucun droit admin requis (ecriture dans HKCU uniquement).

    Sur Windows 11, l'entree apparait sous "Afficher plus d'options" (Shift+F10).
.EXAMPLE
    .\install-context-menu.ps1                          # Installe
    .\install-context-menu.ps1 -Uninstall               # Desinstalle
    .\install-context-menu.ps1 -Label "Claude YOLO"     # Etiquette personnalisee
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$Label = "Ouvrir dans Claude-Yolo"
)

$ErrorActionPreference = "Stop"

$KeyName = "ClaudeYolo"
$Roots = @(
    "HKCU:\Software\Classes\Directory\shell\$KeyName",
    "HKCU:\Software\Classes\Directory\Background\shell\$KeyName"
)

if ($Uninstall) {
    foreach ($root in $Roots) {
        if (Test-Path $root) {
            Remove-Item -Path $root -Recurse -Force
            Write-Host "  Supprime : $root" -ForegroundColor Green
        } else {
            Write-Host "  Absent   : $root" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host "Menu contextuel desinstalle." -ForegroundColor Green
    exit 0
}

# -- Resoudre le chemin du lanceur --
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Launcher = Join-Path $ScriptDir "run-claude.ps1"

if (-not (Test-Path $Launcher)) {
    Write-Error "Lanceur introuvable : $Launcher"
    exit 1
}

# -- Executable PowerShell : preferer pwsh 7+ si disponible, sinon Windows PowerShell --
$PwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($PwshCmd) {
    $PwshExe = $PwshCmd.Source
} else {
    $PwshExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
}

# %V = chemin du dossier clique (Directory\shell) ou du dossier courant (Background\shell)
$Command = '"{0}" -ExecutionPolicy Bypass -NoProfile -File "{1}" -ProjectPath "%V"' -f $PwshExe, $Launcher

foreach ($root in $Roots) {
    New-Item -Path $root -Force | Out-Null
    Set-ItemProperty -Path $root -Name "(Default)" -Value $Label
    Set-ItemProperty -Path $root -Name "Icon" -Value $PwshExe

    $cmdKey = Join-Path $root "command"
    New-Item -Path $cmdKey -Force | Out-Null
    Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value $Command

    Write-Host "  Installe : $root" -ForegroundColor Green
}

Write-Host ""
Write-Host "Menu contextuel installe." -ForegroundColor Green
Write-Host "  Lanceur  : $Launcher" -ForegroundColor DarkGray
Write-Host "  Shell    : $PwshExe" -ForegroundColor DarkGray
Write-Host "  Clic droit sur un dossier -> `"$Label`"" -ForegroundColor DarkGray
Write-Host "  (Windows 11 : passer par `"Afficher plus d'options`" ou Shift+F10)" -ForegroundColor DarkGray
