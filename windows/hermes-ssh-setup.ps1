# =====================================================================
#  hermes-ssh-setup.ps1  (v2 - hardening por padrao)
#  Prepara Windows Server 2016+ (PowerShell 5.1) para receber SSH do Hermes
#  - Instala Win32-OpenSSH (MSI oficial, SHA-256 verificado)
#  - Porta personalizada + firewall restrito a origens autorizadas
#  - Chave publica em administrators_authorized_keys e ~\.ssh\authorized_keys
#  - PowerShell como shell padrao
#  - PasswordAuthentication no  (somente chave)
#  - Valida (sshd -t), reinicia sshd, mostra resumo
#
#  Uso (PowerShell como Administrador, logado com a conta que o Hermes usara):
#    [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/hermes-ssh-setup.ps1 | iex
#
#  Variaveis de ambiente opcionais (definir ANTES do irm):
#    $env:HERMES_SSH_PORT      = '5822'                       # porta TCP (padrao 5822)
#    $env:HERMES_SSH_ALLOW     = '177.136.234.234,10.8.0.0/24' # origens permitidas no firewall (padrao: IP do Hermes)
#    $env:HERMES_SSH_ALLOW     = 'Any'                        # abre para qualquer origem (nao recomendado)
#    $env:HERMES_SSH_PASSWORD  = 'yes'                        # mantem login por senha (padrao: no)
#
#  Regra de seguranca: o script NUNCA fecha a porta antiga nem remove regras existentes.
#  Ele so adiciona/ajusta a regra propria "OpenSSH Server - TCP <porta> (Hermes)".
# =====================================================================

$ErrorActionPreference = 'Stop'

# ----------------------------- Parametros -----------------------------
$Port = 5822
if ($env:HERMES_SSH_PORT -match '^\d+$') { $Port = [int]$env:HERMES_SSH_PORT }

$HermesIP = '177.136.234.234'
$AllowRaw = if ($env:HERMES_SSH_ALLOW) { $env:HERMES_SSH_ALLOW } else { $HermesIP }
$AllowAny = ($AllowRaw.Trim() -ieq 'Any')
$Allow    = @($AllowRaw -split '[,; ]+' | Where-Object { $_ -and $_ -ine 'Any' })

$PasswordAuth = if ($env:HERMES_SSH_PASSWORD -match '^(yes|true|1)$') { 'yes' } else { 'no' }

$PublicKey = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDeEaZtxz6NNXm7N//QdvTHgRiSDBbQi9jqjqxNRnNz2lrvZ2u2s1k2CgL9dszTylGPrnN0W8XTGplXOpk625NEQDjyAd0EGWhfoJBv6HOmlyNLNgmSbmQwjMdomBpMNGzWBx7kzbmt+3Qm7AieuxYl50U8eCJtmzTkBZzUmqqAKVd63zOLX2OzGnvZml/yov8tKhVGn+tHOQEOkayCsRrZFsuINuStBR//D/0Wu+HxWSR5WipCQL1ay92LTAZsRzYambafBG/aZ9J2s6PLqYwoXWtAvEO2ZrwG3hi1t4lhFSZ5w4G5Av2USqocuMKH8yWKQt82oQoKboAoyHqNzYbhG5yJEn91MqX0rfC6t9nqu9FtIPJb0uz8E8hbemgPA5MzLQFDHuRZhld0vX7xt517m0SG915wEGGN/zAKTYrYhGtUa4/YJTW463jps1ukvbkquFW8B/wNpZaAFkgz1+XHmtAOGzpKlvJCbOE+yNHCQKVPqPPj/1n8SVqVFe4Ks5GMWam3gUNmm4OsEW5T1tJqdsSdERK+p7Y17PT4zEfVSW/wPb4O+oXYFWqucA85X+3xNkpi8EQV1M/rUjUUhr9YifMXk29s84Rnn7eLSEiEGg35bbOteslhcOjlTKdrZjwsHg19H305RjBPNFOSA6gEPW9pxKOi502bmkVUPjewrw== computador@NITRO5'

$MsiUrl    = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.3.0p2-Preview/OpenSSH-Win64-v9.8.3.0.msi'
$MsiSha256 = 'C8A8C7E21136A099665C2FAD9ACCB41152D129466B719EA71678BAB665E03389'
$MsiPath   = Join-Path $env:TEMP 'OpenSSH-Win64-v9.8.3.0.msi'

$ProgramDataSsh = Join-Path $env:ProgramData 'ssh'
$SshdConfig     = Join-Path $ProgramDataSsh 'sshd_config'
$AdminKeys      = Join-Path $ProgramDataSsh 'administrators_authorized_keys'
$UserSshDir     = Join-Path $env:USERPROFILE '.ssh'
$UserKeys       = Join-Path $UserSshDir 'authorized_keys'
$PowerShellExe  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$RuleName       = "OpenSSH Server - TCP $Port (Hermes)"

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [!!] $msg" -ForegroundColor Yellow }

# Substitui (descomentando) ou insere no topo uma diretiva do sshd_config.
# Diretivas globais precisam ficar ANTES de qualquer bloco Match.
function Set-SshdDirective([string[]]$Lines, [string]$Name, [string]$Value) {
    $Idx = -1
    for ($n = 0; $n -lt $Lines.Count; $n++) {
        if ($Lines[$n] -match '^\s*Match\s') { break }              # nao mexer dentro de Match
        if ($Lines[$n] -match "^\s*#?\s*$Name\s+") { $Idx = $n; break }
    }
    if ($Idx -ge 0) { $Lines[$Idx] = "$Name $Value"; return ,$Lines }
    return ,(@("$Name $Value") + $Lines)
}

# ----------------------------- Pre-checks -----------------------------
Step "Pre-checks"
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) { throw "Execute o PowerShell como Administrador." }
Ok "Sessao elevada"

$OS = Get-CimInstance Win32_OperatingSystem
Write-Host "    $($OS.Caption) $($OS.Version) $($OS.OSArchitecture) | PowerShell $($PSVersionTable.PSVersion)"
if ($OS.OSArchitecture -notmatch '64') { throw "Este script usa o MSI Win64. SO nao e 64 bits." }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Ok "TLS 1.2 habilitado"

Write-Host "    Porta: $Port | Origem permitida: $(if ($AllowAny) {'Any'} else {$Allow -join ', '}) | PasswordAuthentication: $PasswordAuth"
if ($AllowAny) { Warn "Firewall aberto para qualquer origem (HERMES_SSH_ALLOW=Any)." }
if ($PasswordAuth -eq 'no') { Warn "Login por senha sera DESABILITADO. Garanta que a chave privada correspondente esta no Hermes." }

# ------------------------- Instalar OpenSSH -------------------------
Step "OpenSSH Server"
$Svc = Get-Service sshd -ErrorAction SilentlyContinue
if ($Svc) {
    $SvcPath = (Get-CimInstance Win32_Service -Filter "Name='sshd'").PathName
    Ok "Servico sshd ja existe ($($Svc.Status)) - $SvcPath"
} else {
    Write-Host "    Baixando $MsiUrl"
    Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath -UseBasicParsing
    $Hash = (Get-FileHash $MsiPath -Algorithm SHA256).Hash
    if ($Hash -ne $MsiSha256) {
        Remove-Item $MsiPath -Force -ErrorAction SilentlyContinue
        throw "SHA-256 do MSI nao confere. Esperado $MsiSha256, obtido $Hash. Abortando."
    }
    Ok "SHA-256 do MSI verificado"

    $P = Start-Process msiexec.exe -ArgumentList "/i `"$MsiPath`" ADDLOCAL=Server /qn /norestart" -Wait -PassThru
    if ($P.ExitCode -ne 0) { throw "msiexec retornou $($P.ExitCode). Verifique %TEMP% / Event Viewer." }
    Ok "MSI instalado (ExitCode 0)"
    $Svc = Get-Service sshd
}

$SshdExe = @("$env:ProgramFiles\OpenSSH\sshd.exe", "$env:SystemRoot\System32\OpenSSH\sshd.exe") |
           Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $SshdExe) { throw "sshd.exe nao localizado." }
Ok "sshd.exe: $SshdExe"

Set-Service sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
$i = 0
while (-not (Test-Path $SshdConfig) -and $i -lt 15) { Start-Sleep 1; $i++ }
if (-not (Test-Path $SshdConfig)) { throw "sshd_config nao foi criado em $SshdConfig." }
Ok "sshd Running/Automatic, config em $SshdConfig"

# --------------------------- Firewall (antes de tocar na porta) ---------------------------
Step "Firewall TCP $Port"
$Rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
if (-not $Rule) {
    $Params = @{
        DisplayName = $RuleName; Direction = 'Inbound'; Protocol = 'TCP'
        LocalPort = $Port; Action = 'Allow'; Profile = 'Any'
        Description = 'Acesso SSH do Hermes Agent. Gerenciado por hermes-ssh-setup.ps1'
    }
    if (-not $AllowAny) { $Params.RemoteAddress = $Allow }
    New-NetFirewallRule @Params | Out-Null
    Ok "Regra criada: $RuleName"
} else {
    if ($AllowAny) { Set-NetFirewallRule -DisplayName $RuleName -RemoteAddress Any }
    else           { Set-NetFirewallRule -DisplayName $RuleName -RemoteAddress $Allow }
    Ok "Regra atualizada: $RuleName"
}
$Eff = Get-NetFirewallRule -DisplayName $RuleName | Get-NetFirewallAddressFilter
Ok "RemoteAddress efetivo: $($Eff.RemoteAddress -join ', ')"

# Regra legada (v1 do script, sem restricao de origem): avisar, nao remover automaticamente
$Legacy = Get-NetFirewallRule -DisplayName "OpenSSH Server - TCP $Port" -ErrorAction SilentlyContinue
if ($Legacy -and -not $AllowAny) {
    Warn "Regra legada aberta encontrada: 'OpenSSH Server - TCP $Port'. Ela anula a restricao de origem."
    Warn "Remova apos validar o acesso:  Remove-NetFirewallRule -DisplayName 'OpenSSH Server - TCP $Port'"
}
$MsiRule = Get-NetFirewallRule -DisplayName 'OpenSSH SSH Server Preview (sshd)' -ErrorAction SilentlyContinue
if ($MsiRule -and $MsiRule.Enabled -eq 'True') {
    Warn "Regra do instalador MSI ('OpenSSH SSH Server Preview (sshd)', TCP 22) esta habilitada."
    Warn "Desabilite apos validar:  Disable-NetFirewallRule -DisplayName 'OpenSSH SSH Server Preview (sshd)'"
}

# --------------------------- sshd_config ---------------------------
Step "sshd_config"
$Backup = "$SshdConfig.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item $SshdConfig $Backup -Force
Ok "Backup: $Backup"

$Lines = @(Get-Content $SshdConfig)
$Lines = Set-SshdDirective $Lines 'Port'                   "$Port"
$Lines = Set-SshdDirective $Lines 'PubkeyAuthentication'   'yes'
$Lines = Set-SshdDirective $Lines 'PasswordAuthentication' $PasswordAuth
$Lines = Set-SshdDirective $Lines 'PermitEmptyPasswords'   'no'

if (-not ($Lines -match '^\s*Match\s+Group\s+administrators')) {
    $Lines += ''
    $Lines += 'Match Group administrators'
    $Lines += '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
    Ok "Bloco 'Match Group administrators' adicionado"
} else { Ok "Bloco 'Match Group administrators' presente" }

Set-Content -Path $SshdConfig -Value $Lines -Encoding ascii
Ok "Port $Port / PubkeyAuthentication yes / PasswordAuthentication $PasswordAuth gravados"

& $SshdExe -t
if ($LASTEXITCODE -ne 0) {
    Copy-Item $Backup $SshdConfig -Force
    throw "sshd -t falhou (exit $LASTEXITCODE). Backup restaurado; sshd NAO reiniciado."
}
Ok "sshd -t: sintaxe valida"

# --------------------------- Chave publica ---------------------------
Step "Chave publica"
function Add-KeyLine($File, $Key) {
    $Dir = Split-Path $File -Parent
    if (-not (Test-Path $Dir))  { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    if (-not (Test-Path $File)) { New-Item -ItemType File -Path $File -Force | Out-Null }
    $Existing = @(Get-Content $File -ErrorAction SilentlyContinue)
    $KeyBody  = ($Key -split '\s+')[1]
    if ($Existing -match [regex]::Escape($KeyBody)) { Warn "Chave ja presente em $File" }
    else { Add-Content -Path $File -Value $Key -Encoding ascii; Ok "Chave adicionada em $File" }
}

Add-KeyLine $AdminKeys $PublicKey
icacls $AdminKeys /inheritance:r | Out-Null
icacls $AdminKeys /grant 'SYSTEM:F' | Out-Null
icacls $AdminKeys /grant '*S-1-5-32-544:F' | Out-Null
Ok "ACL de administrators_authorized_keys ajustada (SYSTEM + Administrators)"

Add-KeyLine $UserKeys $PublicKey
$UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls $UserKeys /inheritance:r | Out-Null
icacls $UserKeys /grant 'SYSTEM:F' | Out-Null
icacls $UserKeys /grant '*S-1-5-32-544:F' | Out-Null
icacls $UserKeys /grant "*${UserSid}:F" | Out-Null
Ok "ACL de $UserKeys ajustada"

# --------------------------- Shell padrao ---------------------------
Step "PowerShell como DefaultShell"
if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $PowerShellExe -PropertyType String -Force | Out-Null
Ok (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell).DefaultShell

# --------------------------- Aplicar ---------------------------
Step "Reiniciando sshd"
Restart-Service sshd
Start-Sleep -Seconds 2
$Listen = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if (-not $Listen) { throw "sshd nao esta escutando em $Port. Veja: Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 20" }
$Listen | Format-Table LocalAddress, LocalPort, State, OwningProcess -AutoSize | Out-String | Write-Host
Ok "sshd escutando em TCP $Port"

# --------------------------- Resumo ---------------------------
Step "Resumo para o Hermes"
$Who  = whoami
$IPs  = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        Select-Object -ExpandProperty IPAddress
Write-Host "    Host         : $env:COMPUTERNAME"
Write-Host "    Usuario      : $Who"
Write-Host "    Porta        : $Port"
Write-Host "    Origens      : $(if ($AllowAny) {'Any'} else {$Eff.RemoteAddress -join ', '})"
Write-Host "    Senha via SSH: $PasswordAuth"
Write-Host "    IPs locais   : $($IPs -join ', ')"
Write-Host "    Firewall     : $RuleName"
Write-Host "    Config       : $SshdConfig  (backup: $Backup)"
Write-Host ""
Write-Host "    Teste do lado Hermes/Linux:" -ForegroundColor Cyan
Write-Host "    ssh -i ~/.ssh/KW_Kronic.key -p $Port '$Who@<IP_PUBLICO_OU_VPN>' 'hostname; whoami'"
Write-Host ""
Write-Host "    Rollback rapido (nesta sessao ou console/RDP):" -ForegroundColor Cyan
Write-Host "    Copy-Item '$Backup' '$SshdConfig' -Force; Restart-Service sshd"
Write-Host ""
if (-not $AllowAny) { Warn "Se o servidor estiver atras de NAT, publique TCP $Port para $($Allow -join ', ') no roteador/firewall de borda." }
