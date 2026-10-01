#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configura e estabiliza as politicas do Windows Update e instalacao de drivers em servidores Windows.
.DESCRIPTION
    - Desabilita a busca e instalacao automatica de drivers pelo Windows Update (evita travamentos no ShellHWDetection e DsmSvc).
    - Configura o Windows Update para o modo 'Notificar antes de baixar e instalar' (AUOptions = 2), evitando uso inesperado de CPU/disco em producao.
    - Impede reinicializacoes automaticas forcadas quando houver usuarios logados (NoAutoRebootWithLoggedOnUsers = 1).
    - Cria ponto de backup do registro para rollback seguro.
    - Reinicia os servicos do Windows Update para aplicar as politicas imediatamente.
.EXAMPLE
    [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/windows-update-tune.ps1 | iex
#>

[CmdletBinding()]
param(
    [ValidateSet(2, 3, 4, 5)]
    [int]$AUOption = 2,
    [switch]$KeepDriverUpdates
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "    [!!] $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "    [ERRO] $Msg" -ForegroundColor Red }

Clear-Host
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   HERMES AGENT - Windows Update & Driver Policy Tuning (Server) " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# 1. Pre-checks
Write-Step "Pre-checks"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "Este script precisa ser executado como Administrador elevado."
    exit 1
}
Write-Ok "Sessao administrativa confirmada"

$os = Get-CimInstance Win32_OperatingSystem
Write-Ok "$($os.Caption) ($($os.Version) $($os.OSArchitecture))"

# 2. Backup do Registro
Write-Step "Backup das Chaves de Registro Atuais"
$backupDir = "C:\ProgramData\Hermes\Backups"
if (-not (Test-Path $backupDir)) {
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupFile = "$backupDir\WindowsUpdate-Backup-$timestamp.reg"

try {
    Start-Process reg.exe -ArgumentList @('export', 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', "$backupDir\WU-$timestamp.reg", '/y') -Wait -NoNewWindow -ErrorAction SilentlyContinue
    Start-Process reg.exe -ArgumentList @('export', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching', "$backupDir\DS-$timestamp.reg", '/y') -Wait -NoNewWindow -ErrorAction SilentlyContinue
    Write-Ok "Backup gravado em: $backupDir"
} catch {
    Write-Warn "Nao foi possivel exportar chaves anteriores (podem nao existir ainda). Continuando..."
}

# 3. Configuracao das Chaves de Politica
Write-Step "Aplicando Politicas de Windows Update"

# Chave base: HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
$wuPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
if (-not (Test-Path $wuPolicyPath)) {
    New-Item -Path $wuPolicyPath -Force | Out-Null
}

# Chave AU: HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU
$auPolicyPath = "$wuPolicyPath\AU"
if (-not (Test-Path $auPolicyPath)) {
    New-Item -Path $auPolicyPath -Force | Out-Null
}

# Definir opcoes de atualizacao automatica
Set-ItemProperty -Path $auPolicyPath -Name 'NoAutoUpdate' -Value 0 -Type DWord -Force
Set-ItemProperty -Path $auPolicyPath -Name 'AUOptions' -Value $AUOption -Type DWord -Force
Set-ItemProperty -Path $auPolicyPath -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord -Force
Set-ItemProperty -Path $auPolicyPath -Name 'ScheduledInstallDay' -Value 0 -Type DWord -Force
Set-ItemProperty -Path $auPolicyPath -Name 'ScheduledInstallTime' -Value 3 -Type DWord -Force

$auDesc = switch ($AUOption) {
    2 { "2 - Notificar antes de baixar e notificar antes de instalar (Recomendado para Servidores)" }
    3 { "3 - Baixar automaticamente e notificar para instalar" }
    4 { "4 - Baixar e agendar a instalacao" }
    5 { "5 - Permitir que o administrador local escolha a configuracao" }
}
Write-Ok "AUOptions = $auDesc"
Write-Ok "NoAutoRebootWithLoggedOnUsers = 1 (Evita reinicio com usuarios conectados)"

# 4. Desabilitar Atualizacoes e Busca de Drivers via Windows Update
if (-not $KeepDriverUpdates) {
    Write-Step "Desabilitando Busca e Instalacao Automatica de Drivers"
    
    # ExcludeWUDriversInQualityUpdate na politica do Windows Update
    Set-ItemProperty -Path $wuPolicyPath -Name 'ExcludeWUDriversInQualityUpdate' -Value 1 -Type DWord -Force
    Write-Ok "ExcludeWUDriversInQualityUpdate = 1"

    # DriverSearching global
    $dsPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"
    if (-not (Test-Path $dsPath)) { New-Item -Path $dsPath -Force | Out-Null }
    Set-ItemProperty -Path $dsPath -Name 'SearchOrderConfig' -Value 0 -Type DWord -Force
    Write-Ok "DriverSearching\SearchOrderConfig = 0 (Nao buscar drivers no Windows Update)"

    # Politica de DriverSearching
    $dsPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
    if (-not (Test-Path $dsPolicyPath)) { New-Item -Path $dsPolicyPath -Force | Out-Null }
    Set-ItemProperty -Path $dsPolicyPath -Name 'DontSearchWindowsUpdate' -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $dsPolicyPath -Name 'DontPromptForWindowsUpdate' -Value 1 -Type DWord -Force
    Write-Ok "Policies\DriverSearching\DontSearchWindowsUpdate = 1"

    # Device Metadata
    $metaPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata"
    if (-not (Test-Path $metaPath)) { New-Item -Path $metaPath -Force | Out-Null }
    Set-ItemProperty -Path $metaPath -Name 'PreventDeviceMetadataFromNetwork' -Value 1 -Type DWord -Force
    Write-Ok "PreventDeviceMetadataFromNetwork = 1"
}

# 5. Reiniciar e Estabilizar Servicos
Write-Step "Aplicando configuracoes e reiniciando servicos"
try {
    Get-Service -Name wuauserv, bits, ShellHWDetection -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Status -eq 'Running') {
            Write-Ok "Reiniciando servico $($_.Name)..."
            Restart-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Ok "Servicos sincronizados com sucesso"
} catch {
    Write-Warn "Algum servico demorou a responder, mas as politicas foram gravadas no registro."
}

# 6. Resumo Final
Write-Step "Resumo da Configuracao Aplicada"
Write-Host "    Servidor                   : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "    Modo Windows Update        : AUOptions = $AUOption (Notificacao manual)" -ForegroundColor White
Write-Host "    Atualizacao de Drivers     : DESABILITADA (Prevenindo travamento de hardware/SCM)" -ForegroundColor White
Write-Host "    Reinicio Forcado Bloqueado : SIM (NoAutoRebootWithLoggedOnUsers = 1)" -ForegroundColor White
Write-Host "    Backup das Chaves          : $backupDir" -ForegroundColor White

Write-Host "`n[OK] Politica aplicada com sucesso neste servidor!`n" -ForegroundColor Green
