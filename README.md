# utilitarios

Repositório padrão de ferramentas pessoais (Wittemberg / Hermes). Scripts pensados para
execução em uma linha, idempotentes e com rollback descrito no cabeçalho.

### install-kb5129237-server-2022.ps1

Detecta e valida Windows Server 2022 x64 (build 20348), verifica se a KB5129237 já está instalada, baixa o MSU oficial do Microsoft Update Catalog e inicia a instalação silenciosa com `/norestart`. Exige PowerShell elevado. Se o WUSA retornar 3010, a atualização foi instalada e o Windows indicou que será necessário reiniciar; o script não reinicia o servidor automaticamente. O pacote tem aproximadamente 560 MB.

PowerShell como Administrador:

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/install-kb5129237-server-2022.ps1 | iex
```

O script é específico para Windows Server 2022 x64 e KB5129237. Em outro sistema, não instala a atualização.

## linux/

### preparar-servidor-linux.sh

Prepara Ubuntu/Debian: atualiza o sistema, instala ferramentas, configura timezone/locale, Chrony, Fail2ban, chave SSH e hardening opcional do SSH. Antes de perguntar sobre swap, exibe memória e swap já ativas; qualquer swap solicitada é adicional à existente, exige confirmação explícita de necessidade e passa por verificação de espaço livre na raiz com reserva mínima de 2 GiB. Em caso de falha ou interrupção, remove o arquivo parcial criado nesta execução. Pergunta se o servidor é um host Proxmox para aplicar `vm.swappiness=10` e ajustes KSM. Se `/root/.ssh/authorized_keys` for o link padrão do Proxmox para `/etc/pve/priv/authorized_keys`, a chave é gravada em `/root/.ssh/authorized_keys.hermes` para evitar escrita no pmxcfs; o SSH é configurado para aceitar os dois arquivos. O arquivo compartilhado e o link são preservados.

Requer root, terminal interativo e conectividade com os repositórios. Antes de aceitar aplicar o hardening SSH, confirme que TCP/5822 está liberada no firewall e que há console/acesso alternativo; a autenticação por senha será desabilitada. Revise `ignoreip` do Fail2ban para incluir os IPs administrativos necessários. A escolha Proxmox aplica os ajustes ao host; não execute em LXC/VM convidada esperando que controle KSM do host.

Ubuntu/Debian, como root:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/Wittemberg/utilitarios/main/linux/preparar-servidor-linux.sh?v=$(date +%s)")
```

A execução é interativa. O script não cria snapshot e não reinicia o servidor. Os backups ficam ao lado dos arquivos alterados; rollback de SSH: copie o backup informado pelo script de volta para `/etc/ssh/sshd_config` e valide com `sshd -t` antes de reiniciar `ssh`.

## windows/

### Preparar-Servidor-Windows.ps1

Prepara e aplica hardening completo em instalação nova de Windows Server (2016, 2019, 2022, 2025 recém-instalado, sem updates ou alterações prévias).
Unifica 100% dos procedimentos operacionais e de compatibilidade legada:
- **Política de Senhas**: Mínimo de 6 caracteres, sem expiração, bloqueio após 5 falhas, janela de 15 min e complexidade ativada.
- **Administrador Local**: Redefinição imediata da senha da conta de Administrador.
- **Identificação**: Renomeação padronizada do computador.
- **Relógio e Região**: Fuso Horário (-03:00 Brasília), formatação pt-BR e múltiplos peers NTP (`a.ntp.br`, `b.ntp.br`, `c.ntp.br`).
- **Windows Update**: Configurado para notificar antes de baixar e instalar (`AUOptions=2`, sem reinício forçado com usuários logados).
- **Desempenho**: Plano de Energia de Alto Desempenho e Paginação Fixa (48 GB / 72 GB para estabilidade RDS).
- **Usabilidade**: Server Manager fechado no logon, sem diálogo de motivo de desligamento, sem exigência de CTRL+ALT+DEL, auto-start do `ctfmon.exe`, `EnableLinkedConnections=1` e desbloqueio de executáveis baixados.
- **Terminal Server / RDP**: Porta 3389 aberta integralmente, sessão única por usuário, NLA desabilitado, `SecurityLayer=0` (RDP nativo para evitar erro interno e dar suporte a terminais legados), KeepAlive de 60s, tuning de buffer TCP/IP e redirecionamento de dispositivos USB.
- **Licenciamento RDS**: Modo Por Dispositivo (2) apontado para `127.0.0.1` em Policies, RCM e WMI.
- **Compatibilidade com ERPs Legados (Cobol, VB6, Delphi)**: Protocolo SMB1 ativo, acesso Guest e sem assinatura SMB, Spooler com `RpcAuthnLevelPrivacyEnabled=0` (sem erro 0x0000011b), Point & Print, UAC desativado (`EnableLUA=0`) e proteção em tempo real do Defender desativada.
- **Tuning de Serviços**: Desativação de telemetria, serviços Xbox, Bluetooth e bloatware OEM, `SysMain` e `WSearch` como Manual, `WaitToKillServiceTimeout=2000` (rápido e seguro contra corrupção de bancos), mantendo `cryptsvc` e `bits` ativos e preservando núcleos para escalabilidade da VM.
- **Limpeza Profunda**: Limpeza em todos os perfis de `C:\Users` (temporários, caches de navegadores, relatórios WER e cache RDP).
- **Ferramentas**: Instalação das ferramentas administrativas do Active Directory (`RSAT-AD-Tools`) e download/instalação silenciosa do AWS CLI v2 com variáveis de ambiente Machine.
- **SSH Hermes**: Instalação automática do OpenSSH Server na porta 5822 com login restrito por chave.

Comando unificado em uma linha (com parâmetros):

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $d="$env:TEMP\WittembergServerPrep"; New-Item -ItemType Directory -Force $d | Out-Null; iwr https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/Preparar-Servidor-Windows.ps1 -OutFile "$d\Preparar-Servidor-Windows.ps1" -UseBasicParsing; iwr https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/hermes-ssh-setup.ps1 -OutFile "$d\hermes-ssh-setup.ps1" -UseBasicParsing; Unblock-File "$d\*.ps1"; & "$d\Preparar-Servidor-Windows.ps1" -NewComputerName "SRV-CLIENTE-XXXX" -SetAdminPassword "SuaSenhaAqui"
```

Comando em uma linha interativo (pergunta o nome e senha na tela):

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $d="$env:TEMP\WittembergServerPrep"; New-Item -ItemType Directory -Force $d | Out-Null; iwr https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/Preparar-Servidor-Windows.ps1 -OutFile "$d\Preparar-Servidor-Windows.ps1" -UseBasicParsing; iwr https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/hermes-ssh-setup.ps1 -OutFile "$d\hermes-ssh-setup.ps1" -UseBasicParsing; Unblock-File "$d\*.ps1"; & "$d\Preparar-Servidor-Windows.ps1"
```

Execução local (PowerShell como Administrador):

```powershell
.\Preparar-Servidor-Windows.ps1 -NewComputerName "SRV-CLIENTE-XXXX" -SetAdminPassword "SuaSenhaAqui"
```

Se executado sem parâmetros, o script solicita o nome e a senha interativamente.
Para executar apenas auditoria somente leitura (sem aplicar alterações):

```powershell
.\Preparar-Servidor-Windows.ps1 -Audit
```


### hermes-ssh-setup.ps1

Prepara Windows Server 2016+ para receber SSH do Hermes com Win32-OpenSSH, chave pública,
PowerShell como shell padrão, firewall restrito à origem do Hermes e senha desabilitada.

PowerShell como Administrador (conta que o Hermes vai usar):

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/hermes-ssh-setup.ps1 | iex
```

Opções (definir antes do `irm`):

| Variável              | Padrão            | Efeito                                                  |
|-----------------------|-------------------|---------------------------------------------------------|
| `HERMES_SSH_PORT`     | `5822`            | Porta TCP do sshd                                       |
| `HERMES_SSH_ALLOW`    | `177.136.234.234` | Origens permitidas no firewall (lista por vírgula, CIDR ok) ou `Any` |
| `HERMES_SSH_PASSWORD` | `no`              | `yes` mantém autenticação por senha                     |

Exemplo permitindo também a VPN:

```powershell
$env:HERMES_SSH_ALLOW='177.136.234.234,10.8.0.0/24'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/Wittemberg/utilitarios/main/windows/hermes-ssh-setup.ps1 | iex
```

Rollback: o script imprime ao final o comando `Copy-Item <backup> sshd_config; Restart-Service sshd`.
