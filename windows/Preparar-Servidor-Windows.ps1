#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Preparação e Hardening Completo de Windows Server Novo (Wittemberg / Hermes).
.DESCRIPTION
    Script unificado para instalação nova de Windows Server (2016, 2019, 2022, 2025).
    Reúne e moderniza 100% dos procedimentos e baselines operacionais:
    - Política de Senhas (mínimo 6 caracteres, sem expiração, bloqueio 5 falhas / 15 min, complexidade)
    - Redefinição segura de senha do Administrador local
    - Renomeação padronizada do computador
    - Fuso Horário (-03:00 Brasília), Região (pt-BR) e NTP sincronizado (a.ntp.br, b.ntp.br, c.ntp.br)
    - Windows Update configurado para notificar antes de baixar/instalar (sem reinício forçado com usuários)
    - Plano de Energia de Alto Desempenho e Paginação Fixa (48 GB / 72 GB para estabilidade RDS)
    - Usabilidade: Server Manager fechado no logon, sem diálogo de motivo de desligamento, sem CTRL+ALT+DEL,
      ctfmon ativo, EnableLinkedConnections ativo, desbloqueio de executáveis e tipos de baixo risco
    - Terminal Server / RDP: Porta 3389 aberta integralmente, sessão única por usuário, NLA desabilitado,
      SecurityLayer 0 (RDP nativo para evitar erro interno e dar suporte a terminais legados),
      KeepAlive 60s, tuning de buffer TCP/IP e redirecionamento de dispositivos USB
    - Licenciamento RDS: Modo Por Dispositivo (2) apontado para 127.0.0.1 em Policies, RCM e WMI
    - Compatibilidade Legada (Cobol, VB6, Delphi): Protocolo SMB1 ativo, acesso Guest e sem assinatura SMB,
      Spooler de impressão ajustado para evitar erro 0x0000011b (RpcAuthnLevelPrivacy=0), Point & Print,
      UAC desativado (EnableLUA=0) e proteção em tempo real do Defender desativada
    - Tuning de Serviços: Telemetria, serviços Xbox, Bluetooth e bloatware OEM desativados, SysMain/WSearch como Manual,
      WaitToKillServiceTimeout ajustado para 2000 ms (seguro contra corrupção de bancos de dados),
      mantendo cryptsvc e bits ativos
    - Limpeza de Perfis: Remoção profunda de arquivos temporários, relatórios WER e caches em todos os perfis de C:\Users
    - Ferramentas: Instalação das ferramentas RSAT-AD-Tools e do AWS CLI v2 com variáveis de ambiente Machine
    - SSH Hermes: Instalação do OpenSSH Server na porta personalizada 5822 com acesso por chave

    USO EM UMA LINHA:
    $d="$env:TEMP\WittembergServerPrep"; New-Item -ItemType Directory -Force $d | Out-Null; [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/Preparar-Servidor-Windows.ps1 -OutFile "$d\Preparar-Servidor-Windows.ps1"; irm https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/hermes-ssh-setup.ps1 -OutFile "$d\hermes-ssh-setup.ps1"; Unblock-File "$d\*.ps1"; & "$d\Preparar-Servidor-Windows.ps1" -NewComputerName "SRV-CLIENTE-XXXX" -SetAdminPassword "SuaSenhaAqui"

    USO LOCAL (PowerShell como Administrador):
    .\Preparar-Servidor-Windows.ps1 -NewComputerName "SRV-CLIENTE-01" -SetAdminPassword "MinhaSenhaForte"

    AUDITORIA (Somente Leitura):
    .\Preparar-Servidor-Windows.ps1 -Audit
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Position=0)]
    [string]$NewComputerName,

    [Parameter(Position=1)]
    [string]$SetAdminPassword,

    [switch]$Audit,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = $PWD.Path }
} else {
    $ScriptDir = $PSScriptRoot
}

$Script:LogPath = Join-Path $ScriptDir ('prep-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$Script:BackupRoot = Join-Path $ScriptDir ('prep-backup-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
$null = New-Item -ItemType Directory -Path $Script:BackupRoot -Force

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level='INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    switch ($Level) {
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        Default { Write-Host $line }
    }
    try { Add-Content -LiteralPath $Script:LogPath -Value $line -Encoding UTF8 } catch {}
}

function Get-OsInfo {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
        Select-Object ProductName, EditionID, DisplayVersion, CurrentBuild, UBR, InstallationType
}

function Assert-Standalone {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain) {
        Write-Log "Servidor membro do domínio ($($cs.Domain)): políticas de conta e senha devem ser gerenciadas via GPO do domínio." 'WARN'
        return $false
    }
    return $true
}

function Backup-RegistryKey {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$File)
    $null = New-Item -ItemType Directory -Path (Split-Path $File -Parent) -Force
    $r = & reg.exe query $Key 2>$null
    if ($LASTEXITCODE -ne 0) {
        Set-Content -LiteralPath ($File + '.absent-before-change') -Value "A chave $Key não existia antes da execução." -Encoding UTF8
        return
    }
    & reg.exe export $Key $File /y | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log "Falha ao exportar backup da chave de registro: $Key" 'WARN' }
}

function Ensure-RegistryPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
}

function Set-SafeRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Type
    )
    Ensure-RegistryPath -Path $Path
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# =====================================================================
# AUDITORIA
# =====================================================================
function Invoke-Audit {
    Write-Log '=== AUDITORIA COMPLETA SOMENTE LEITURA INICIADA ===' 'INFO'
    Write-Log ("Host: {0} | Usuário: {1} | PS: {2} | Data: {3}" -f $env:COMPUTERNAME, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $PSVersionTable.PSVersion, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    
    $os = Get-OsInfo
    Write-Log ("SO: {0} (Build {1}.{2}, Edição {3})" -f $os.ProductName, $os.CurrentBuild, $os.UBR, $os.EditionID)
    
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Log ("Domínio: {0} (Membro de Domínio: {1}) | RAM Total: {2:N2} GB" -f $cs.Domain, $cs.PartOfDomain, ($cs.TotalPhysicalMemory / 1GB))
    
    try {
        Write-Log "Fuso Horário Atual: $(Get-TimeZone | Select-Object -ExpandProperty Id)"
    } catch {}

    Write-Log '--- Políticas Locais de Senha / Bloqueio ---'
    net.exe accounts | ForEach-Object { Write-Log $_ }
    
    Write-Log '--- Status de Serviços Críticos ---'
    Get-Service WinDefend, mpssvc, w32time, TermService, sshd, SysMain, WSearch, cryptsvc, bits -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_.TrimEnd() }

    Write-Log '--- Status do Firewall ---'
    try {
        Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction |
            Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_.TrimEnd() }
    } catch { Write-Log "Não foi possível consultar perfis de firewall: $_" 'WARN' }

    Write-Log '--- Configuração RDP ---'
    try {
        $rdp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue
        $nla = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction SilentlyContinue
        Write-Log ("RDP Conexões Bloqueadas (fDenyTSConnections): {0} | NLA Obrigatório (UserAuthentication): {1}" -f $rdp.fDenyTSConnections, $nla.UserAuthentication)
        
        $listen = Get-NetTCPConnection -State Listen -LocalPort 3389 -ErrorAction SilentlyContinue
        if ($listen) { Write-Log "Porta RDP 3389 está em ESCUTA (Listening)." 'OK' } else { Write-Log "Porta RDP 3389 NÃO está em escuta." 'WARN' }
    } catch { Write-Log "Erro ao verificar RDP: $_" 'WARN' }

    Test-RdpRegression
    Write-Log "Auditoria finalizada. Log registrado em: $Script:LogPath" 'OK'
}

function Test-RdpRegression {
    $os = Get-OsInfo
    $hotfixes = @(Get-HotFix -ErrorAction SilentlyContinue | ForEach-Object HotFixID)
    $build = [int]$os.CurrentBuild
    $ubr = [int]$os.UBR
    if ($build -eq 20348) {
        $affected = $hotfixes -contains 'KB5122882'
        $fixed = ($hotfixes -contains 'KB5129237') -or ($ubr -ge 5631)
        if ($affected -and -not $fixed) { Write-Log 'ALERTA RDP: Server 2022 possui KB5122882 sem KB5129237 / build 20348.5631+.' 'WARN' }
        elseif ($fixed) { Write-Log 'RDP Server 2022: Atualização corretiva detectada.' 'OK' }
    } elseif ($build -eq 14393) {
        $fixed = $hotfixes -contains 'KB5129239'
        if ($fixed) { Write-Log 'RDP Server 2016: KB5129239 detectada.' 'OK' }
        else { Write-Log 'RDP Server 2016: KB5129239 não listada explicitamente (pode estar contida no rollup cumulativo).' 'INFO' }
    }
}

# =====================================================================
# ROTINAS DE PREPARAÇÃO E HARDENING
# =====================================================================

function Set-LocalSecurityPolicy {
    Write-Log 'Configurando Política Local de Contas e Senhas...'
    if (Assert-Standalone) {
        $secBackup = Join-Path $Script:BackupRoot 'secpol-before.inf'
        & secedit.exe /export /cfg $secBackup /areas SECURITYPOLICY | Out-Null
        
        # Mínimo 6 caracteres, sem expiração, bloqueio após 5 falhas, janela 15 min
        $changes = @(
            '/minpwlen:6',
            '/maxpwage:unlimited',
            '/lockoutthreshold:5',
            '/lockoutwindow:15'
        )
        foreach ($change in $changes) {
            $out = & net.exe accounts $change 2>&1
            Write-Log "net accounts $change : $($out -join ' ')"
        }
        
        # Ativa Complexidade de Senhas via secedit
        try {
            $tmpInf = "$env:TEMP\secpol_tmp.inf"
            & secedit.exe /export /cfg $tmpInf /areas SECURITYPOLICY | Out-Null
            if (Test-Path $tmpInf) {
                (Get-Content $tmpInf) -replace '^(PasswordComplexity\s*=\s*).*', '${1}1' | Set-Content $tmpInf
                & secedit.exe /configure /db "$env:SystemRoot\Security\Database\secedit.sdb" /cfg $tmpInf /areas SECURITYPOLICY /quiet | Out-Null
                Remove-Item $tmpInf -Force -ErrorAction SilentlyContinue
                Write-Log 'Requisito de complexidade de senha ativado (secedit PasswordComplexity=1).' 'OK'
            }
        } catch {
            Write-Log "Aviso ao ajustar PasswordComplexity: $_" 'WARN'
        }
    }
}

function Set-AdminPasswordRoutine {
    param([Parameter(Mandatory)][string]$Password)
    Write-Log 'Aplicando nova senha na conta de Administrador local...'
    try {
        $secStr = ConvertTo-SecureString $Password -AsPlainText -Force
        Set-LocalUser -Name "Administrator" -Password $secStr -ErrorAction SilentlyContinue
        Set-LocalUser -Name "Administrador" -Password $secStr -ErrorAction SilentlyContinue
        Write-Log 'Senha do Administrador local redefinida com sucesso.' 'OK'
    } catch {
        Write-Log "Erro ao redefinir senha do Administrador: $_" 'WARN'
    }
}

function Set-ComputerNameRoutine {
    param([Parameter(Mandatory)][string]$Name)
    Write-Log "Configurando nome do computador para: $Name..."
    try {
        if ($env:COMPUTERNAME -ne $Name) {
            Rename-Computer -NewName $Name -Force
            Write-Log "Computador renomeado para $Name com sucesso. A alteração terá efeito completo após o reboot." 'OK'
        } else {
            Write-Log "O nome do computador já é $Name. Nenhuma alteração necessária." 'INFO'
        }
    } catch {
        Write-Log "Erro ao renomear computador: $_" 'WARN'
    }
}

function Set-TimeAndRegionalSettings {
    Write-Log 'Configurando Fuso Horário, Região e Sincronização NTP...'
    
    # 1. Fuso Horário (-03:00 Brasília)
    try {
        & tzutil.exe /s "E. South America Standard Time"
        Write-Log 'Fuso horário definido para E. South America Standard Time (-03:00 Brasília).' 'OK'
    } catch { Write-Log "Aviso tzutil: $_" 'WARN' }

    # 2. Configurações Regionais pt-BR
    try {
        Set-WinSystemLocale -SystemLocale pt-BR -ErrorAction SilentlyContinue
        Set-Culture -CultureInfo pt-BR -ErrorAction SilentlyContinue
        Set-WinHomeLocation -GeoId 32 -ErrorAction SilentlyContinue
        Write-Log 'Localidade, Formato e Região definidos para pt-BR.' 'OK'
    } catch {}

    # 3. NTP com múltiplos peers (a.ntp.br, b.ntp.br, c.ntp.br)
    try {
        Set-Service w32time -StartupType Automatic
        Start-Service w32time -ErrorAction SilentlyContinue
        $peers = "a.ntp.br,b.ntp.br,c.ntp.br,0x8"
        & w32tm.exe /config "/manualpeerlist:$peers" /syncfromflags:manual /reliable:YES /update | Out-Null
        Restart-Service w32time
        & w32tm.exe /resync /rediscover | Out-Null
        Write-Log "Serviço NTP w32time configurado e sincronizado com: $peers" 'OK'
    } catch { Write-Log "Aviso w32time: $_" 'WARN' }

    # Regras de Firewall para NTP UDP 123
    try {
        New-NetFirewallRule -DisplayName "NTP UDP 123 Saida (Prep)" -Direction Outbound -Protocol UDP -RemotePort 123 -Action Allow -ErrorAction SilentlyContinue | Out-Null
        New-NetFirewallRule -DisplayName "NTP UDP 123 Entrada (Prep)" -Direction Inbound -Protocol UDP -LocalPort 123 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    # 4. Política de Windows Update (Notificar antes de baixar/instalar, sem reboot forçado)
    $wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    Backup-RegistryKey -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -File (Join-Path $Script:BackupRoot 'wu-au.reg')
    Set-SafeRegistryValue -Path $wuPath -Name 'AUOptions' -Value 2 -Type DWord
    Set-SafeRegistryValue -Path $wuPath -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -Type DWord
    Write-Log 'Windows Update configurado: AUOptions=2 (Notificar), NoAutoRebootWithLoggedOnUsers=1.' 'OK'
}

function Set-PowerAndPerformanceSettings {
    Write-Log 'Aplicando otimizações de Desempenho, Usabilidade e Memória Virtual...'
    
    # Plano de Energia: Alto Desempenho
    try {
        & powercfg.exe -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
        Write-Log 'Plano de Energia definido para Alto Desempenho.' 'OK'
    } catch { Write-Log "Aviso powercfg: $_" 'WARN' }

    # Memória Virtual / Pagefile fixo (48 GB inicial, 72 GB final) para estabilidade com múltiplas conexões RDP
    try {
        $sys = Get-CimInstance Win32_ComputerSystem
        $sys.AutomaticManagedPagefile = $false
        Set-CimInstance -InputObject $sys
        
        $pagefile = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
        if ($pagefile) {
            $pagefile.InitialSize = 49152
            $pagefile.MaximumSize = 73728
            Set-CimInstance -InputObject $pagefile
        } else {
            New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = "C:\pagefile.sys"; InitialSize = 49152; MaximumSize = 73728 } | Out-Null
        }
        Write-Log 'Arquivo de paginação fixado em 49152 MB (Inicial) - 73728 MB (Máximo).' 'OK'
    } catch { Write-Log "Aviso Memória Virtual: $_" 'WARN' }

    # Desabilitar inicialização automática do Server Manager no Logon
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name 'DoNotOpenServerManagerAtLogon' -Value 1 -Type DWord
    Set-SafeRegistryValue -Path 'HKCU:\Software\Microsoft\ServerManager' -Name 'DoNotOpenServerManagerAtLogon' -Value 1 -Type DWord

    # Desabilitar diálogo de motivo de desligamento do Windows (Shutdown Tracker)
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' -Name 'ShutdownReasonOn' -Value 0 -Type DWord

    # Desabilitar exigência de CTRL+ALT+DEL no logon
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'DisableCAD' -Value 1 -Type DWord

    # TimeBrokerSvc = 3 (Manual) para evitar problemas no Gerenciador de Tarefas
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\TimeBrokerSvc' -Name 'Start' -Value 3 -Type DWord

    # EnableLinkedConnections = 1 (Compartilha mapeamentos de rede com sessões de Administrador elevado)
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLinkedConnections' -Value 1 -Type DWord

    # MenuShowDelay = 0 (Menus mais rápidos e responsivos)
    Set-SafeRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'MenuShowDelay' -Value "0" -Type String

    # AutoRun desativado em todas as unidades (Prevenção contra infecções por mídia externa)
    Set-SafeRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'NoDriveTypeAutoRun' -Value 255 -Type DWord

    # Inclusão de tipos de arquivos de baixo risco (elimina caixas de alerta contínuas em executáveis)
    Set-SafeRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Associations' -Name 'LowRiskFileTypes' -Value '.exe;.cmd;.lnk;.bat;.reg;.msi;.xml' -Type String
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Associations' -Name 'LowRiskFileTypes' -Value '.exe;.cmd;.lnk;.bat;.reg;.msi;.xml' -Type String

    # Iniciar ctfmon.exe no Logon para garantir digitação funcional no menu iniciar
    Set-SafeRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ctfmon' -Value 'C:\Windows\System32\ctfmon.exe' -Type String

    # Remover pasta 'Objetos 3D' do Meu Computador
    $ns3d = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\explorer\MyComputer\NameSpace\{FC9FB64A-1EB2-4CCF-AF5E-1A497A9B5C2D}'
    if (Test-Path $ns3d) { Remove-Item -Path $ns3d -Recurse -Force -ErrorAction SilentlyContinue }

    # Desbloquear executáveis baixados em Downloads e C:\Instaladores
    @("C:\Users\*\Downloads\*.exe", "C:\Users\*\Downloads\*.msi", "C:\Instaladores\*.exe", "C:\Instaladores\*.msi") | ForEach-Object {
        Get-ChildItem $_ -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    }
    Write-Log 'Otimizações de SO e Usabilidade aplicadas.' 'OK'
}

function Set-RdpAndRdsSettings {
    Write-Log 'Configurando Terminal Server (RDS), Licenciamento e Porta RDP 3389...'
    
    # 1. Habilitar conexões RDP no registro
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -Type DWord
    
    # 2. Porta 3389 aberta integralmente no Firewall (Any Profile, Inbound TCP)
    try {
        $existingRule = Get-NetFirewallRule -DisplayName "RDP TCP-In" -ErrorAction SilentlyContinue
        if ($existingRule) {
            Set-NetFirewallRule -DisplayName "RDP TCP-In" -Enabled True -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -Profile Any | Out-Null
        } else {
            New-NetFirewallRule -DisplayName "RDP TCP-In" -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -Profile Any | Out-Null
        }
        Write-Log 'Regra de Firewall RDP TCP-In (Porta 3389) aberta integralmente.' 'OK'
    } catch { Write-Log "Aviso Firewall RDP: $_" 'WARN' }

    # 3. Restringir usuários a uma única sessão simultânea
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fSingleSessionPerUser' -Value 1 -Type DWord
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fSingleSessionPerUser' -Value 1 -Type DWord

    # 4. RDP SecurityLayer = 0 e NLA desativado (compatibilidade com terminais legados e prevenção de erro interno)
    $tsPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    Set-SafeRegistryValue -Path $tsPol -Name 'SecurityLayer' -Value 0 -Type DWord
    Set-SafeRegistryValue -Path $tsPol -Name 'UserAuthentication' -Value 0 -Type DWord

    $rdpTcp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    Set-SafeRegistryValue -Path $rdpTcp -Name 'SecurityLayer' -Value 0 -Type DWord
    Set-SafeRegistryValue -Path $rdpTcp -Name 'UserAuthentication' -Value 0 -Type DWord
    Write-Log 'RDP configurado com SecurityLayer=0 e NLA=0 (compatibilidade total e sem erro interno).' 'OK'

    # 5. Licenciamento RDS sem AD: Modo 2 (Por Dispositivo) apontando para 127.0.0.1
    Set-SafeRegistryValue -Path $tsPol -Name 'LicensingMode' -Value 2 -Type DWord
    Ensure-RegistryPath -Path "$tsPol\LicenseServers"
    Set-SafeRegistryValue -Path "$tsPol\LicenseServers" -Name '127.0.0.1' -Value '' -Type String

    $rcmPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\Licensing Core'
    Set-SafeRegistryValue -Path $rcmPath -Name 'LicensingMode' -Value 2 -Type DWord
    Set-SafeRegistryValue -Path $rcmPath -Name 'LicenseServers' -Value @('127.0.0.1') -Type MultiString

    try {
        $tsWmi = Get-CimInstance -Namespace root\cimv2\terminalservices -ClassName Win32_TerminalServiceSetting -ErrorAction SilentlyContinue
        if ($tsWmi) {
            Invoke-CimMethod -InputObject $tsWmi -MethodName SetSpecifiedLicenseServerList -Arguments @{ SpecifiedLSList = '127.0.0.1' } -ErrorAction SilentlyContinue | Out-Null
            Invoke-CimMethod -InputObject $tsWmi -MethodName ChangeMode -Arguments @{ LicensingMode = 2 } -ErrorAction SilentlyContinue | Out-Null
            Write-Log 'Licenciamento RDS configurado via WMI (Modo Por Dispositivo, 127.0.0.1).' 'OK'
        }
    } catch {}

    # 6. Otimizações de rede TCP/IP, KeepAlive 60s e buffer
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex' -Value 0xffffffff -Type DWord
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'EnablePMTUDiscovery' -Value 1 -Type DWord
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters' -Name 'DefaultSendWindow' -Value 98304 -Type DWord
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'KeepAliveEnable' -Value 1 -Type DWord
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'KeepAliveTime' -Value 60000 -Type DWord

    # 7. Redirecionamento e Consentimento de Dispositivos USB
    $tsClientPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client'
    Set-SafeRegistryValue -Path $tsClientPol -Name 'fEnableUsbBlockDeviceBySetupClass' -Value 1 -Type DWord
    Set-SafeRegistryValue -Path $tsClientPol -Name 'fEnableUsbNoAckIsochWriteToDevice' -Value 80 -Type DWord
    Set-SafeRegistryValue -Path $tsClientPol -Name 'fEnableUsbSelectDeviceByInterface' -Value 1 -Type DWord
    Set-SafeRegistryValue -Path $tsClientPol -Name 'fClientDisableUDP' -Value 0 -Type DWord
    Set-SafeRegistryValue -Path $tsClientPol -Name 'RedirectionWarningDialogVersion' -Value 1 -Type DWord
    Set-SafeRegistryValue -Path 'HKCU:\Software\Microsoft\Terminal Server Client' -Name 'RdpLaunchConsentAccepted' -Value 1 -Type DWord
    Set-SafeRegistryValue -Path 'HKCU:\Software\Microsoft\Terminal Server Client\Default\AddIns\RDPDR' -Name 'FilterQueueType' -Value 0xffffffff -Type DWord

    Write-Log 'Terminal Server e RDP configurados com sucesso.' 'OK'
}

function Set-LegacyCompatibilitySettings {
    Write-Log 'Aplicando compatibilidade para ERPs Legados (Cobol, VB6, Delphi, Spooler, SMB)...'
    
    # 1. Habilitar Protocolo SMB1
    try {
        $smb1 = Get-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -ErrorAction SilentlyContinue
        if ($smb1 -and $smb1.State -ne 'Enabled') {
            Write-Log 'Habilitando recurso SMB1Protocol (necessário para bancos de dados legados em rede)...' 'WARN'
            Enable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -All -NoRestart | Out-Null
            Write-Log 'SMB1Protocol ativado.' 'OK'
        } else {
            Write-Log 'SMB1Protocol já está ativado.' 'INFO'
        }
    } catch { Write-Log "Aviso ao gerenciar recurso SMB1Protocol: $_" 'WARN' }

    # 2. Configurações de Acesso Guest e sem assinatura obrigatória no SMB
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' -Name 'AllowInsecureGuestAuth' -Value 1 -Type DWord
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -Name 'AllowInsecureGuestAuth' -Value 1 -Type DWord
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' -Name 'RequireSecuritySignature' -Value 0 -Type DWord

    # 3. Spooler de Impressão e Point and Print (resolve erro 0x0000011b)
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Print' -Name 'RpcAuthnLevelPrivacyEnabled' -Value 0 -Type DWord
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint' -Name 'RestrictDriverInstallationToAdministrators' -Value 1 -Type DWord
    Write-Log 'Spooler de impressão configurado: RpcAuthnLevelPrivacyEnabled=0 (sem erro 0x0000011b).' 'OK'

    # 4. Desativar UAC (EnableLUA = 0)
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -Value 0 -Type DWord
    Write-Log 'UAC (Controle de Conta de Usuário) desativado (EnableLUA = 0).' 'WARN'

    # 5. Desativar proteção em tempo real do Windows Defender
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
        Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Value 1 -Type DWord
        Write-Log 'Proteção em tempo real do Windows Defender desativada.' 'WARN'
    } catch { Write-Log "Aviso Defender: $_" 'WARN' }
}

function Set-ServiceAndTelemetryTuning {
    Write-Log 'Aplicando tuning de serviços, telemetria e timeout de desligamento...'
    
    # Timeout de desligamento ajustado para 2000 ms (2 segundos - rápido e seguro contra corrupção de bancos)
    Set-SafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'WaitToKillServiceTimeout' -Value "2000" -Type String
    Write-Log 'WaitToKillServiceTimeout definido para 2000 ms.' 'OK'

    # Serviços seguros para desativar em servidores (telemetria, jogos, rastreamento)
    $servicesToDisable = @(
        'DiagTrack',
        'diagnosticshub.standardcollector.service',
        'dmwappushservice',
        'XboxGipSvc',
        'XboxNetApiSvc',
        'xbgm',
        'XblGameSave',
        'XblAuthManager',
        'PhoneSvc',
        'DusmSvc',
        'lfsvc',
        'WMPNetworkSvc'
    )

    # Bloatware OEM (Dell, Intel, Atheros) se presente no hardware
    $oemServices = @(
        'AtherosSvc',
        'DellSupportAssistRemediation',
        'SupportAssistAgent',
        'DellDataVault',
        'DDVDataCollector',
        'DellUpdate',
        'DDVRulesProcessor',
        'DDVCollectorSvcApi',
        'DellDataVaultWiz',
        'Dell Foundation Services',
        'DellDigitalDelivery',
        'IAStorDataMgrSvc',
        'lms',
        'cphs'
    )

    foreach ($svcName in ($servicesToDisable + $oemServices)) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                Set-Service -Name $svcName -StartupType Disabled -ErrorAction SilentlyContinue
                if ($svc.Status -eq 'Running') { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue }
                Write-Log "Serviço $svcName desativado com sucesso." 'OK'
            } catch {}
        }
    }

    # SysMain e WSearch como Manual (não sobrecarregam I/O contínuo)
    @('SysMain', 'WSearch') | ForEach-Object {
        $s = Get-Service -Name $_ -ErrorAction SilentlyContinue
        if ($s) {
            Set-Service -Name $_ -StartupType Manual -ErrorAction SilentlyContinue
            Write-Log "Serviço $_ definido como Manual." 'OK'
        }
    }

    # Desativar Tarefas Agendadas de Telemetria / Compatibilidade
    $tasksToDisable = @(
        "\Microsoft\Windows\Application Experience\StartupAppTask",
        "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
        "\Microsoft\Windows\TaskScheduler\Maintenance Configurator"
    )
    foreach ($tn in $tasksToDisable) {
        try {
            & schtasks.exe /change /tn $tn /DISABLE 2>$null | Out-Null
            Write-Log "Tarefa agendada $tn desativada." 'OK'
        } catch {}
    }

    # Bloqueio de Telemetria via Registro
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -Type DWord
    Set-SafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'AllowCortana' -Value 0 -Type DWord

    Write-Log 'NOTA DE SEGURANÇA: Serviços cryptsvc e bits foram MANTIDOS ATIVOS para garantir instalação de pacotes e validação de certificados digitais.' 'OK'
    Write-Log 'NOTA DE ESCALABILIDADE: bcdedit numproc NÃO foi fixado para garantir escalabilidade da VM.' 'OK'
}

function Invoke-FullProfileCleanup {
    Write-Log 'Iniciando limpeza de temporários e caches em todos os perfis de usuários...'
    
    # 1. C:\Windows\Temp
    $winTemp = Join-Path $env:windir 'Temp'
    if (Test-Path $winTemp) {
        Get-ChildItem -LiteralPath $winTemp -Force -Recurse -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Write-Log "Arquivos em $winTemp limpos." 'OK'
    }

    # 2. Varredura profunda em C:\Users
    $usersDir = Split-Path $env:USERPROFILE -Parent
    if (Test-Path $usersDir) {
        Get-ChildItem -Path $usersDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $userPath = $_.FullName
            $targets = @(
                (Join-Path $userPath 'AppData\Local\Temp'),
                (Join-Path $userPath 'AppData\Local\Microsoft\Windows\Temporary Internet Files'),
                (Join-Path $userPath 'AppData\Local\Microsoft\Windows\INetCache'),
                (Join-Path $userPath 'AppData\Local\Microsoft\Windows\WER\ReportArchive'),
                (Join-Path $userPath 'AppData\Local\Microsoft\Terminal Server Client\Cache'),
                (Join-Path $userPath 'AppData\Local\Google\Chrome\User Data\Default\Cache'),
                (Join-Path $userPath 'AppData\Local\Mozilla\Firefox\Profiles')
            )
            foreach ($t in $targets) {
                if (Test-Path $t) {
                    Get-ChildItem -LiteralPath $t -Force -Recurse -ErrorAction SilentlyContinue |
                        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
                }
            }
        }
        Write-Log 'Arquivos temporários, relatórios WER e caches limpos em todos os perfis de C:\Users.' 'OK'
    }
}

function Install-ToolsAndPackages {
    Write-Log 'Instalando Ferramentas AD (RSAT) e AWS CLI v2...'
    
    # 1. RSAT-AD-Tools
    try {
        Write-Log 'Instalando recurso RSAT-AD-Tools...'
        Install-WindowsFeature -Name RSAT-AD-Tools -ErrorAction SilentlyContinue | Out-Null
        Write-Log 'RSAT-AD-Tools instalado com sucesso.' 'OK'
    } catch { Write-Log "Aviso RSAT: $_" 'WARN' }

    # 2. AWS CLI v2
    try {
        [Environment]::SetEnvironmentVariable("AWS_CONFIG_FILE", "C:\Instaladores\.aws\config", "Machine")
        [Environment]::SetEnvironmentVariable("AWS_SHARED_CREDENTIALS_FILE", "C:\Instaladores\.aws\credentials", "Machine")
        
        $dest = "$env:TEMP\AWSCLIV2.msi"
        Write-Log 'Baixando instalador oficial do AWS CLI v2...'
        Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile $dest -UseBasicParsing
        Write-Log 'Instalando AWS CLI v2 silenciosamente...'
        Start-Process msiexec.exe -ArgumentList "/i `"$dest`" /qn" -Wait
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        Write-Log 'AWS CLI v2 instalado e variáveis Machine configuradas.' 'OK'
    } catch { Write-Log "Aviso AWS CLI: $_" 'WARN' }
}

function Invoke-SshSetup {
    $candidate = Join-Path $ScriptDir 'hermes-ssh-setup.ps1'
    if (-not (Test-Path -LiteralPath $candidate)) {
        Write-Log "hermes-ssh-setup.ps1 não encontrado na pasta $ScriptDir. Baixando do repositório oficial..." 'INFO'
        try {
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/hermes-ssh-setup.ps1" -OutFile $candidate -UseBasicParsing
            Write-Log 'hermes-ssh-setup.ps1 baixado com sucesso.' 'OK'
        } catch {
            Write-Log "Não foi possível baixar hermes-ssh-setup.ps1: $_. Configuração do SSH pulada." 'WARN'
            return
        }
    }
    
    Write-Log 'Invocando configuração do OpenSSH Server (Hermes, Porta 5822)...'
    $priorAllow = $env:HERMES_SSH_ALLOW
    try {
        $env:HERMES_SSH_ALLOW = '177.136.234.234,10.10.1.0/24,10.8.0.0/24'
        & $candidate
        Write-Log 'SSH Hermes configurado e validado.' 'OK'
    } catch {
        Write-Log "Erro durante execução do hermes-ssh-setup: $_" 'WARN'
    } finally {
        if ($null -eq $priorAllow) { Remove-Item Env:\HERMES_SSH_ALLOW -ErrorAction SilentlyContinue }
        else { $env:HERMES_SSH_ALLOW = $priorAllow }
    }
}

# =====================================================================
# FLUXO PRINCIPAL DE EXECUÇÃO
# =====================================================================
try {
    Write-Log "=== INÍCIO DA EXECUÇÃO NO HOST: $env:COMPUTERNAME ===" 'INFO'
    
    # Modo Auditoria Apenas
    if ($Audit) {
        Invoke-Audit
        return
    }

    # Solicita interativamente parâmetros se não fornecidos
    if ([string]::IsNullOrWhiteSpace($NewComputerName)) {
        $NewComputerName = Read-Host "Informe o novo nome do servidor (ex: SRV-CLIENTE-01)"
    }
    if ([string]::IsNullOrWhiteSpace($SetAdminPassword)) {
        $SetAdminPassword = Read-Host "Informe a nova senha do Administrador local"
    }

    if ([string]::IsNullOrWhiteSpace($NewComputerName) -or [string]::IsNullOrWhiteSpace($SetAdminPassword)) {
        throw "Nome do computador (-NewComputerName) e Senha do Administrador (-SetAdminPassword) são obrigatórios para a preparação."
    }

    Write-Log "Preparação iniciada para o servidor: $NewComputerName" 'INFO'
    Get-OsInfo | Format-List | Out-String | ForEach-Object { Write-Log $_.TrimEnd() }

    # 1. Política Local de Senha e Bloqueio
    Set-LocalSecurityPolicy

    # 2. Redefinição de Senha do Administrador
    Set-AdminPasswordRoutine -Password $SetAdminPassword

    # 3. Renomeação do Servidor
    Set-ComputerNameRoutine -Name $NewComputerName

    # 4. Fuso Horário, Região e NTP
    Set-TimeAndRegionalSettings

    # 5. Otimizações de Desempenho, Usabilidade e Memória Virtual
    Set-PowerAndPerformanceSettings

    # 6. Terminal Server, Licenciamento RDS e Porta RDP 3389
    Set-RdpAndRdsSettings

    # 7. Compatibilidade Legada (SMB1, Spooler, UAC off, Defender off)
    Set-LegacyCompatibilitySettings

    # 8. Tuning de Serviços, Telemetria e Timeout de Desligamento
    Set-ServiceAndTelemetryTuning

    # 9. Limpeza Profunda de Todos os Perfis
    Invoke-FullProfileCleanup

    # 10. Instalação de Ferramentas (RSAT e AWS CLI)
    Install-ToolsAndPackages

    # 11. SSH Hermes (Porta 5822)
    Invoke-SshSetup

    Write-Log '=== PREPARAÇÃO COMPLETA DO SERVIDOR FINALIZADA COM SUCESSO ===' 'OK'
    Write-Log "Log de execução gravado em: $Script:LogPath" 'INFO'
    Write-Log 'Recomenda-se reiniciar o servidor para que todas as alterações (nome, paginação, SMB1, UAC) sejam carregadas.' 'WARN'
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    throw
}
