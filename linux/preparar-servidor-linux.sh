#!/usr/bin/env bash
# Preparação base de servidor Ubuntu/Debian.
# Execute como root; alterações de SSH têm backup e são validadas antes de reiniciar.
# O script nunca reinicia o servidor automaticamente.
set -Eeuo pipefail

readonly SSH_PORT=5822
readonly NTP_SERVERS=(a.ntp.br b.ntp.br)
readonly PUBLIC_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDeEaZtxz6NNXm7N//QdvTHgRiSDBbQi9jqjqxNRnNz2lrvZ2u2s1k2CgL9dszTylGPrnN0W8XTGplXOpk625NEQDjyAd0EGWhfoJBv6HOmlyNLNgmSbmQwjMdomBpMNGzWBx7kzbmt+3Qm7AieuxYl50U8eCJtmzTkBZzUmqqAKVd63zOLX2OzGnvZml/yov8tKhVGn+tHOQEOkayCsRrZFsuINuStBR//D/0Wu+HxWSR5WipCQL1ay92LTAZsRzYambafBG/aZ9J2s6PLqYwoXWtAvEO2ZrwG3hi1t4lhFSZ5w4G5Av2USqocuMKH8yWKQt82oQoKboAoyHqNzYbhG5yJEn91MqX0rfC6t9nqu9FtIPJb0uz8E8hbemgPA5MzLQFDHuRZhld0vX7xt517m0SG915wEGGN/zAKTYrYhGtUa4/YJTW463jps1ukvbkquFW8B/wNpZaAFkgz1+XHmtAOGzpKlvJCbOE+yNHCQKVPqPPj/1n8SVqVFe4Ks5GMWam3gUNmm4OsEW5T1tJqdsSdERK+p7Y17PT4zEfVSW/wPb4O+oXYFWqucA85X+3xNkpi8EQV1M/rUjUUhr9YifMXk29s84Rnn7eLSEiEGg35bbOteslhcOjlTKdrZjwsHg19H305RjBPNFOSA6gEPW9pxKOi502bmkVUPjewrw== computador@NITRO5'

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
ask_yes_no() {
    local prompt=$1 answer
    while true; do
        read -r -p "$prompt [s/N]: " answer </dev/tty
        case "$answer" in
            s|S|sim|SIM|Sim) return 0 ;;
            n|N|nao|não|NAO|NÃO|"") return 1 ;;
            *) printf 'Responda s ou n.\n' ;;
        esac
    done
}

[[ $EUID -eq 0 ]] || die 'Execute como root (sudo -i ou sudo bash).'
[[ -r /etc/os-release ]] || die 'Não foi possível identificar a distribuição.'
. /etc/os-release
[[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || die "Distribuição não suportada: ${PRETTY_NAME:-desconhecida}. Somente Ubuntu/Debian."
[[ -r /dev/tty ]] || die 'Este script requer um terminal interativo para as decisões de swap, Proxmox e SSH.'

log 'Atualizando pacotes do sistema'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y

log 'Configurando alias ls'
alias_line="alias ls='ls -l --color=auto'"
grep -qxF "$alias_line" /etc/bash.bashrc || printf '\n%s\n' "$alias_line" >> /etc/bash.bashrc

log 'Instalando pacotes necessários'
apt-get install -y chrony fail2ban iptables-persistent mc s3fs nfs-common git binutils build-essential sshpass htop unzip cloud-guest-utils net-tools jq apparmor-utils curl wget btop

log 'Configurando fuso horário e locale'
timedatectl set-timezone America/Sao_Paulo
if ! locale -a | grep -qi '^pt_BR\.utf8$'; then
    if grep -q '^# *pt_BR.UTF-8 UTF-8' /etc/locale.gen; then
        sed -i 's/^# *pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen
    elif ! grep -q '^pt_BR.UTF-8 UTF-8' /etc/locale.gen; then
        printf '\npt_BR.UTF-8 UTF-8\n' >> /etc/locale.gen
    fi
    locale-gen pt_BR.UTF-8
fi

log 'Configurando Chrony'
chrony_conf=/etc/chrony/chrony.conf
[[ -f $chrony_conf ]] || die "Arquivo ausente: $chrony_conf"
cp -a "$chrony_conf" "${chrony_conf}.bak.$(date +%F_%H-%M-%S)"
sed -i -E '/^[[:space:]]*pool[[:space:]]+/s/^/# /' "$chrony_conf"
for server in "${NTP_SERVERS[@]}"; do
    grep -qE "^[[:space:]]*server[[:space:]]+$server([[:space:]]|$)" "$chrony_conf" || printf 'server %s iburst\n' "$server" >> "$chrony_conf"
done
systemctl enable --now chrony
systemctl restart chrony
chronyc sources || true
chronyc makestep || true
date

log 'Configurando Fail2ban'
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 177.136.234.234/32
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 24h
banaction = iptables-allports
usedns = no

[sshd]
enabled = true
port = 5822
filter = sshd[mode=aggressive]
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
maxretry = 3
findtime = 10m
bantime = 2h

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = iptables-allports
findtime = 1d
bantime = 7d
maxretry = 3
EOF
fail2ban-client -t
systemctl enable --now fail2ban
systemctl restart fail2ban

log 'Swap e parâmetros de memória'
if ask_yes_no 'Deseja criar/ativar um arquivo de swap?'; then
    if swapon --show=NAME --noheadings | grep -Fxq /swapfile; then
        printf 'O arquivo /swapfile já está ativo; não será recriado.\n'
    elif [[ -e /swapfile ]]; then
        die '/swapfile já existe, mas não está ativo. Verifique-o manualmente; não será sobrescrito.'
    else
        while true; do
            read -r -p 'Tamanho da swap em GiB (ex.: 2, 8, 32): ' swap_gib </dev/tty
            [[ $swap_gib =~ ^[1-9][0-9]*$ ]] && (( swap_gib <= 1024 )) && break
            printf 'Informe um número inteiro entre 1 e 1024.\n'
        done
        if ! fallocate -l "${swap_gib}G" /swapfile; then
            rm -f /swapfile
            log 'fallocate falhou; usando dd para criar a swap'
            dd if=/dev/zero of=/swapfile bs=1M count=$((swap_gib * 1024)) status=progress
        fi
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        cp -a /etc/fstab "/etc/fstab.bak.$(date +%F_%H-%M-%S)"
        grep -qE '^/swapfile[[:space:]]' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    fi
else
    printf 'Criação de swap ignorada.\n'
fi

if ask_yes_no 'Este servidor é um host Proxmox e deseja aplicar os ajustes vm.swappiness/KSM?'; then
    sysctl_file=/etc/sysctl.d/99-proxmox.conf
    cp -a "$sysctl_file" "${sysctl_file}.bak.$(date +%F_%H-%M-%S)" 2>/dev/null || true
    printf 'vm.swappiness=10\n' > "$sysctl_file"
    sysctl -p "$sysctl_file"
    if [[ -d /sys/kernel/mm/ksm ]]; then
        printf '1\n' > /sys/kernel/mm/ksm/run
        printf '1000\n' > /sys/kernel/mm/ksm/sleep_millisecs
        printf '100\n' > /sys/kernel/mm/ksm/pages_to_scan
    else
        printf 'KSM não está disponível; ajustes KSM ignorados.\n'
    fi
else
    printf 'Ajuste de swappiness/Proxmox ignorado.\n'
fi

log 'Instalando chave pública'
install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
grep -qxF "$PUBLIC_KEY" /root/.ssh/authorized_keys || printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys

log 'Preparando hardening do SSH'
sshd_config=/etc/ssh/sshd_config
[[ -f $sshd_config ]] || die "Arquivo ausente: $sshd_config"
ssh_backup="${sshd_config}.bak_$(date +%F_%H-%M-%S)"
cp -a "$sshd_config" "$ssh_backup"
set_sshd_option() {
    local key=$1 value=$2
    if grep -qiE "^[[:space:]#]*${key}[[:space:]]" "$sshd_config"; then
        sed -i -E "0,/^[[:space:]#]*${key}[[:space:]]+.*/s//${key} ${value}/I" "$sshd_config"
    else
        printf '\n%s %s\n' "$key" "$value" >> "$sshd_config"
    fi
}
set_sshd_option Port "$SSH_PORT"
set_sshd_option PubkeyAuthentication yes
set_sshd_option AuthorizedKeysFile .ssh/authorized_keys
set_sshd_option PasswordAuthentication no
set_sshd_option ChallengeResponseAuthentication no
set_sshd_option KbdInteractiveAuthentication no
set_sshd_option MaxAuthTries 3
set_sshd_option LoginGraceTime 30
if ! sshd -t; then
    cp -a "$ssh_backup" "$sshd_config"
    die "Configuração SSH inválida; backup restaurado de $ssh_backup. SSH não foi reiniciado."
fi
printf 'Backup SSH: %s\n' "$ssh_backup"
printf 'A alteração de SSH exige porta TCP %s liberada no firewall/console.\n' "$SSH_PORT"
if ask_yes_no 'Aplicar agora a configuração SSH reiniciando o serviço? Confirme acesso alternativo/console.'; then
    systemctl restart ssh
    systemctl is-active --quiet ssh || die 'O serviço SSH não ficou ativo. Consulte o backup informado acima.'
    printf 'SSH ativo após a alteração.\n'
else
    cp -a "$ssh_backup" "$sshd_config"
    printf 'Alteração SSH cancelada; configuração anterior restaurada.\n'
fi

log 'Resumo'
swapon --show
free -h
printf '\nConcluído. Nenhuma reinicialização do servidor foi executada.\n'
