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

Prepara Ubuntu/Debian: atualiza o sistema, instala ferramentas, configura timezone/locale, Chrony, Fail2ban, chave SSH e hardening opcional do SSH. Pergunta se deve criar swap e seu tamanho (GiB), e se o servidor é um host Proxmox para aplicar `vm.swappiness=10` e ajustes KSM. Antes de criar swap, verifica espaço disponível na raiz e preserva ao menos 2 GiB livres; em caso de falha ou interrupção, remove o arquivo parcial criado nesta execução. Faz backup dos arquivos alterados, valida o SSH antes de reiniciar o serviço e não reinicia o servidor.

Requer root, terminal interativo e conectividade com os repositórios. Antes de aceitar aplicar o hardening SSH, confirme que TCP/5822 está liberada no firewall e que há console/acesso alternativo; a autenticação por senha será desabilitada. Revise `ignoreip` do Fail2ban para incluir os IPs administrativos necessários. A escolha Proxmox aplica os ajustes ao host; não execute em LXC/VM convidada esperando que controle KSM do host.

Ubuntu/Debian, como root:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/Wittemberg/utilitarios/main/linux/preparar-servidor-linux.sh?v=$(date +%s)")
```

A execução é interativa. O script não cria snapshot e não reinicia o servidor. Os backups ficam ao lado dos arquivos alterados; rollback de SSH: copie o backup informado pelo script de volta para `/etc/ssh/sshd_config` e valide com `sshd -t` antes de reiniciar `ssh`.

## windows/

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
