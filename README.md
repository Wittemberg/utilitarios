# utilitarios

Repositório padrão de ferramentas pessoais (Wittemberg / Hermes). Scripts pensados para
execução em uma linha, idempotentes e com rollback descrito no cabeçalho.

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
