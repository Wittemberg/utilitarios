#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
  Auditoria ou preparação padrão de Windows Server novo.
.DESCRIPTION
  Uso simples: sem parâmetros = auditoria; -Apply = executa o baseline aprovado.
  O apply configura política local de senha/bloqueio, NTP a.ntp.br, política de
  Windows Update e SSH Hermes (porta 5822, somente chave, origens restritas).
  Requer hermes-ssh-setup.ps1 ao lado do script. Comando em uma linha (baixa ambos para uma pasta local e executa Apply):
  $d="$env:TEMP\WittembergServerPrep"; New-Item -ItemType Directory -Force $d | Out-Null; [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/Preparar-Servidor-Windows.ps1 -OutFile "$d\Preparar-Servidor-Windows.ps1"; irm https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/hermes-ssh-setup.ps1 -OutFile "$d\hermes-ssh-setup.ps1"; Unblock-File "$d\*.ps1"; & "$d\Preparar-Servidor-Windows.ps1" -Apply
  Não reinicia o Windows, não desativa Defender/UAC/firewall e não abre RDP.
  Execute manualmente no servidor novo, como Administrador, com acesso ao console.
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    throw 'Execute este arquivo .ps1 diretamente para definir a pasta do script e salvar o log ao lado dele.'
}
$Script:LogPath = Join-Path $PSScriptRoot ('prep-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$Script:BackupRoot = Join-Path $PSScriptRoot ('prep-backup-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
$null = New-Item -ItemType Directory -Path $Script:BackupRoot -Force
function Write-Log {
    param([string]$Message,[ValidateSet('INFO','WARN','ERROR','OK')][string]$Level='INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date),$Level,$Message
    Write-Host $line
    try { Add-Content -LiteralPath $Script:LogPath -Value $line -Encoding UTF8 } catch { Write-Warning "Não foi possível gravar log em $Script:LogPath" }
}
function Get-OsInfo {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
        Select-Object ProductName,EditionID,DisplayVersion,CurrentBuild,UBR,InstallationType
}
function Assert-Standalone {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain) { throw "Servidor membro de domínio ($($cs.Domain)): política efetiva deve ser tratada por GPO. Alteração local de senha/bloqueio cancelada." }
}
function Backup-RegistryKey {
    param([Parameter(Mandatory)][string]$Key,[Parameter(Mandatory)][string]$File)
    $null = New-Item -ItemType Directory -Path (Split-Path $File -Parent) -Force
    $r = & reg.exe query $Key 2>$null
    if ($LASTEXITCODE -ne 0) {
        Set-Content -LiteralPath ($File + '.absent-before-change') -Value "A chave $Key não existia antes da execução; rollback requer remover somente os valores criados por este script." -Encoding UTF8
        return
    }
    & reg.exe export $Key $File /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Falha ao exportar backup do registro: $Key" }
}
function Restore-RegistryKey {
    param([Parameter(Mandatory)][string]$Key,[Parameter(Mandatory)][string]$BackupFile)
    if (Test-Path -LiteralPath ($BackupFile + '.absent-before-change')) {
        $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        Remove-ItemProperty -Path $path -Name AUOptions,NoAutoRebootWithLoggedOnUsers -ErrorAction SilentlyContinue
        return
    }
    if (Test-Path -LiteralPath $BackupFile) {
        & reg.exe import $BackupFile | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Falha ao restaurar backup do registro: $BackupFile" }
    }
}
function Invoke-Audit {
    Write-Log 'Auditoria somente leitura iniciada.'
    Write-Log ("Host={0}; Usuário={1}; PS={2}; Hora={3}; Fuso={4}" -f $env:COMPUTERNAME,[Security.Principal.WindowsIdentity]::GetCurrent().Name,$PSVersionTable.PSVersion,(Get-Date -Format o),(Get-TimeZone).Id)
    Get-OsInfo | Format-List | Out-String | ForEach-Object { Write-Log $_.TrimEnd() }
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Log ("Domínio={0}; MembroDeDominio={1}" -f $cs.Domain,$cs.PartOfDomain)
    net.exe accounts | ForEach-Object { Write-Log $_ }
    Get-Service WinDefend, mpssvc, w32time, TermService, sshd -ErrorAction SilentlyContinue |
        Select-Object Name,Status,StartType | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_.TrimEnd() }
    try {
        Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction |
            Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_.TrimEnd() }
    } catch { Write-Log "Não foi possível consultar perfis do firewall: $_" 'WARN' }
    try {
        $rdp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction Stop
        $nla = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction SilentlyContinue
        Write-Log ("RDP fDenyTSConnections={0}; NLA(UserAuthentication)={1}" -f $rdp.fDenyTSConnections,$nla.UserAuthentication)
        Get-NetTCPConnection -State Listen -LocalPort 3389 -ErrorAction SilentlyContinue | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_.TrimEnd() }
        Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Select-Object DisplayName,Enabled,Profile,Direction,Action | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_.TrimEnd() }
    } catch { Write-Log "Consulta RDP parcial: $_" 'WARN' }
    try { Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 12 HotFixID,InstalledOn | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_.TrimEnd() } } catch {}
    if ($CheckRdpRegression) { Test-RdpRegression }
    Write-Log "Auditoria concluída. Log: $Script:LogPath" 'OK'
}
function Test-RdpRegression {
    $os = Get-OsInfo
    $hotfixes = @(Get-HotFix -ErrorAction SilentlyContinue | ForEach-Object HotFixID)
    $build = [int]$os.CurrentBuild
    $ubr = [int]$os.UBR
    if ($build -eq 20348) {
        $affected = $hotfixes -contains 'KB5122882'
        $fixed = ($hotfixes -contains 'KB5129237') -or ($ubr -ge 5631)
        if ($affected -and -not $fixed) { Write-Log 'ALERTA RDP: Server 2022 mostra KB5122882 sem KB5129237/build 20348.5631+. Apenas reportado; nenhuma instalação/reinicialização foi feita.' 'WARN' }
        elseif ($fixed) { Write-Log 'RDP Server 2022: KB5129237 ou build corrigida detectada.' 'OK' }
        else { Write-Log 'RDP Server 2022: KB afetada não identificada; valide atualizações e build contra Microsoft Update Catalog.' 'INFO' }
    } elseif ($build -eq 14393) {
        $fixed = $hotfixes -contains 'KB5129239'
        if ($fixed) {
            Write-Log 'RDP Server 2016: KB5129239 aparece no Get-HotFix; confirme build/UBR e estado cumulativo.' 'OK'
        } else {
            Write-Log 'RDP Server 2016: KB5129239 não aparece no Get-HotFix. Isso NÃO confirma exposição: uma atualização cumulativa posterior pode substituí-la. Correlacione build/UBR, histórico de updates e orientação Microsoft; estado inconclusivo.' 'WARN'
        }
    } else {
        Write-Log "Verificação específica da regressão pós-update não configurada para build $build. Nenhuma conclusão de exposição." 'INFO'
    }
}
function Set-LocalSecurityPolicy {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
    param()
    Assert-Standalone
    $secBackup = Join-Path $Script:BackupRoot 'secpol-before.inf'
    & secedit.exe /export /cfg $secBackup /areas SECURITYPOLICY | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $secBackup)) { throw 'Não foi possível exportar política para rollback; nenhuma alteração feita.' }
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Aplicar senha mínima 12 e bloqueio 5/15 min')) {
        $changes = @('/minpwlen:12','/maxpwage:unlimited','/lockoutthreshold:5','/lockoutwindow:15')
        foreach ($change in $changes) {
            $output = & net.exe accounts $change 2>&1
            $nativeExit = $LASTEXITCODE
            foreach ($line in $output) { Write-Log $line }
            if ($nativeExit -ne 0 -and $change -eq '/lockoutduration:15') {
                Write-Log 'NET.EXE neste Windows Server 2016 rejeita /lockoutduration:15 (erro 87). A duração efetiva é definida pelo Windows junto com a política de bloqueio; prosseguindo para validar o limite e a janela.' 'WARN'
                continue
            }
            if ($nativeExit -ne 0) {
                $rollbackDb = Join-Path $Script:BackupRoot 'secpol-rollback.sdb'
                & secedit.exe /configure /db $rollbackDb /cfg $secBackup /areas SECURITYPOLICY /quiet | Out-Null
                $rollbackExit = $LASTEXITCODE
                if ($rollbackExit -ne 0) { throw "net accounts falhou em ${change}: $($output -join ' '); rollback secedit falhou ($rollbackExit). Backup: $secBackup" }
                throw "net accounts falhou em ${change}: $($output -join ' '); política restaurada do backup secedit. Backup: $secBackup"
            }
        }
        $after = Join-Path $Script:BackupRoot 'secpol-after.inf'
        & secedit.exe /export /cfg $after /areas SECURITYPOLICY | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $after)) { throw "Falha ao validar política aplicada. Backup: $secBackup" }
        $state = Get-Content $after -Raw
        if ($state -notmatch '(?m)^MinimumPasswordLength\s*=\s*12\s*$' -or $state -notmatch '(?m)^MaximumPasswordAge\s*=\s*-1\s*$' -or $state -notmatch '(?m)^LockoutBadCount\s*=\s*5\s*$' -or $state -notmatch '(?m)^ResetLockoutCount\s*=\s*15\s*$') { throw "Validação da política falhou. Backup: $secBackup" }
        Write-Log 'Política validada: senha mínima 12, expiração ilimitada, bloqueio após 5 falhas e janela de 15 minutos.' 'OK'
    }
}
function Set-TimePolicy {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
    param()
    $peer = 'a.ntp.br,0x8'
    Backup-RegistryKey -Key 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -File (Join-Path $Script:BackupRoot 'w32time-parameters.reg')
    if ($PSCmdlet.ShouldProcess('Windows Time',"Configurar peer NTP $peer e reiniciar w32time")) {
        Set-Service w32time -StartupType Automatic
        & w32tm.exe /config "/manualpeerlist:$peer" /syncfromflags:manual /update | ForEach-Object { Write-Log $_ }
        if ($LASTEXITCODE -ne 0) { throw 'w32tm /config falhou.' }
        Restart-Service w32time
        & w32tm.exe /resync /rediscover | ForEach-Object { Write-Log $_ }
        if ($LASTEXITCODE -ne 0) { Write-Log 'Resync não confirmou sincronismo; verificar DNS, UDP/123 e origem NTP.' 'WARN' }
        & w32tm.exe /query /status | ForEach-Object { Write-Log $_ }
    }
}
function Set-UpdatePolicy {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
    param()
    $key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $updateBackup = Join-Path $Script:BackupRoot 'windows-update-au-before.reg'
    Backup-RegistryKey -Key $key -File $updateBackup
    if ($PSCmdlet.ShouldProcess('Windows Update','Definir política AUOptions=2')) {
        $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        try {
            New-Item -Path $path -Force | Out-Null
            New-ItemProperty -Path $path -Name AUOptions -PropertyType DWord -Value 2 -Force | Out-Null
            New-ItemProperty -Path $path -Name NoAutoRebootWithLoggedOnUsers -PropertyType DWord -Value 1 -Force | Out-Null
            $state = Get-ItemProperty -Path $path
            if ($state.AUOptions -ne 2 -or $state.NoAutoRebootWithLoggedOnUsers -ne 1) { throw 'Validação do Windows Update falhou.' }
            Write-Log 'Windows Update configurado e validado; serviços não foram reiniciados.' 'OK'
        } catch {
            Restore-RegistryKey -Key $key -BackupFile $updateBackup
            throw
        }
    }
}
function Invoke-SshSetup {
    $candidate = Join-Path $PSScriptRoot 'hermes-ssh-setup.ps1'
    if (-not (Test-Path -LiteralPath $candidate)) { throw "Script SSH não encontrado ao lado deste arquivo: $candidate. Coloque ao lado a versão revisada do repositório Wittemberg/utilitarios." }
    Write-Log "Invocando script SSH local: $candidate" 'INFO'
    $priorAllow = $env:HERMES_SSH_ALLOW
    try {
        $env:HERMES_SSH_ALLOW = '177.136.234.234,10.10.1.0/24,10.8.0.0/24'
        & $candidate
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Script SSH retornou código $LASTEXITCODE" }
    } finally {
        if ($null -eq $priorAllow) { Remove-Item Env:\HERMES_SSH_ALLOW -ErrorAction SilentlyContinue }
        else { $env:HERMES_SSH_ALLOW = $priorAllow }
    }
}

try {
    $null = New-Item -ItemType Directory -Path $Script:BackupRoot -Force
    Write-Log "Preparação iniciada: Apply=$Apply; Host=$env:COMPUTERNAME"
    if ($Apply) {
        Write-Log 'Apply solicitado; alterações serão feitas sem reboot do Windows.' 'WARN'
        Get-OsInfo | Format-List | Out-String | ForEach-Object { Write-Log $_.TrimEnd() }
        Set-LocalSecurityPolicy
        Set-TimePolicy
        Set-UpdatePolicy
        Test-RdpRegression
        Invoke-SshSetup
        Write-Log 'Preparação concluída. Nenhum reboot do Windows foi executado; valide acesso SSH/RDP.' 'OK'
    } else {
        Invoke-Audit
        Write-Log 'Auditoria concluída; sem alterações de política.' 'OK'
    }
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    throw
}
