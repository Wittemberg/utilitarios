# ============================================================
# KB5129237 - Windows Server 2022 x64
# Detecta o SO, baixa o MSU oficial e instala
# Uso: irm https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/install-kb5129237-server-2022.ps1 | iex
# ============================================================

$KB = "KB5129237"

$Url = "https://catalog.s.download.windowsupdate.com/c/msdownload/update/software/updt/2026/09/windows10.0-kb5129237-x64_e93c6b857e895024aeee1e023db638f8c7619096.msu"

$Arquivo = "C:\Windows\Temp\windows10.0-kb5129237-x64.msu"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " INSTALACAO $KB - WINDOWS SERVER 2022" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# Verificar se está executando como Administrador
# ------------------------------------------------------------

$Admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $Admin) {
    Write-Host "ERRO: Execute este script como Administrador." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# Identificar Windows
# ------------------------------------------------------------

$OS = Get-CimInstance Win32_OperatingSystem

Write-Host "Sistema detectado:" -ForegroundColor Yellow
Write-Host "  $($OS.Caption)"
Write-Host "  Versao: $($OS.Version)"
Write-Host "  Build:  $($OS.BuildNumber)"
Write-Host "  Arquitetura: $($OS.OSArchitecture)"
Write-Host ""

# ------------------------------------------------------------
# Validar Windows Server 2022
# Build principal do Server 2022 = 20348
# ------------------------------------------------------------

if ($OS.Caption -notmatch "Windows Server 2022" -or
    $OS.BuildNumber -ne "20348") {

    Write-Host "NAO APLICAVEL." -ForegroundColor Red
    Write-Host ""
    Write-Host "Este computador nao executa Windows Server 2022."
    Write-Host "Nenhuma alteracao foi realizada."
    exit 2
}

if ($OS.OSArchitecture -notmatch "64") {

    Write-Host "NAO APLICAVEL." -ForegroundColor Red
    Write-Host "Este pacote exige Windows Server 2022 x64."
    exit 3
}

Write-Host "OK - Windows Server 2022 x64 identificado." -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------
# Verificar se a KB já está instalada
# ------------------------------------------------------------

Write-Host "Verificando se $KB ja esta instalada..." -ForegroundColor Yellow

$Instalada = Get-HotFix -Id $KB -ErrorAction SilentlyContinue

if ($Instalada) {

    Write-Host ""
    Write-Host "$KB JA ESTA INSTALADA." -ForegroundColor Green
    Write-Host "Data: $($Instalada.InstalledOn)"
    Write-Host ""
    Write-Host "Nenhuma acao necessaria."
    exit 0
}

Write-Host "KB ainda nao instalada." -ForegroundColor Yellow
Write-Host ""

# ------------------------------------------------------------
# Criar diretório temporário
# ------------------------------------------------------------

$Pasta = Split-Path $Arquivo

if (!(Test-Path $Pasta)) {
    New-Item -ItemType Directory -Path $Pasta -Force | Out-Null
}

# ------------------------------------------------------------
# Baixar atualização
# ------------------------------------------------------------

Write-Host "Baixando $KB..." -ForegroundColor Cyan
Write-Host ""

try {

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $Arquivo `
        -UseBasicParsing `
        -ErrorAction Stop

}
catch {

    Write-Host ""
    Write-Host "ERRO AO BAIXAR A ATUALIZACAO." -ForegroundColor Red
    Write-Host $_.Exception.Message
    exit 4
}

# ------------------------------------------------------------
# Validar arquivo
# ------------------------------------------------------------

if (!(Test-Path $Arquivo)) {

    Write-Host "ERRO: Arquivo MSU nao encontrado." -ForegroundColor Red
    exit 5
}

$Tamanho = (Get-Item $Arquivo).Length

if ($Tamanho -lt 100MB) {

    Write-Host "ERRO: O arquivo baixado parece invalido." -ForegroundColor Red
    Write-Host "Tamanho: $([math]::Round($Tamanho / 1MB,2)) MB"
    exit 6
}

Write-Host "Download concluido." -ForegroundColor Green
Write-Host "Arquivo: $Arquivo"
Write-Host "Tamanho: $([math]::Round($Tamanho / 1MB,2)) MB"
Write-Host ""

# ------------------------------------------------------------
# Instalar MSU
# ------------------------------------------------------------

Write-Host "Instalando $KB..." -ForegroundColor Cyan
Write-Host "Aguarde. O processo pode levar alguns minutos..."
Write-Host ""

$Processo = Start-Process `
    -FilePath "wusa.exe" `
    -ArgumentList "`"$Arquivo`" /quiet /norestart" `
    -Wait `
    -PassThru

$Codigo = $Processo.ExitCode

Write-Host ""
Write-Host "Codigo retornado pelo WUSA: $Codigo"
Write-Host ""

# ------------------------------------------------------------
# Interpretar resultado
# ------------------------------------------------------------

switch ($Codigo) {

    0 {
        Write-Host "==============================================" -ForegroundColor Green
        Write-Host " $KB INSTALADA COM SUCESSO" -ForegroundColor Green
        Write-Host "==============================================" -ForegroundColor Green
    }

    3010 {
        Write-Host "==============================================" -ForegroundColor Yellow
        Write-Host " $KB INSTALADA COM SUCESSO" -ForegroundColor Green
        Write-Host " REINICIALIZACAO NECESSARIA" -ForegroundColor Yellow
        Write-Host "==============================================" -ForegroundColor Yellow
    }

    2359302 {
        Write-Host "$KB ja esta instalada." -ForegroundColor Green
    }

    # WUSA returns HRESULT 0x80240017 (WU_E_NOT_APPLICABLE) as a signed Int32.
    -2145124329 {
        Write-Host "ATUALIZACAO NAO APLICAVEL A ESTE SISTEMA." -ForegroundColor Red
    }

    default {
        Write-Host "A instalacao retornou codigo: $Codigo" -ForegroundColor Red
        Write-Host "Verifique o Windows Update / Event Viewer."
        exit $Codigo
    }
}

Write-Host ""
Write-Host "Build atual: $((Get-CimInstance Win32_OperatingSystem).BuildNumber)"
Write-Host ""

exit 0
