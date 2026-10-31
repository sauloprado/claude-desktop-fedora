#!/usr/bin/env bash
# =============================================================================
#  instalar-claude-desktop.sh
#  Instala o Claude Desktop no Fedora pelo repositório DNF da comunidade
#  (claude-desktop-unofficial, que reempacota o .deb oficial da Anthropic)
#  Projeto: https://github.com/sauloprado/claude-desktop-fedora
#
#  Uso:  bash instalar-claude-desktop.sh                (NÃO rode com sudo)
#        bash instalar-claude-desktop.sh --sem-cowork   (pula ajustes de VM)
#
#  O script é idempotente: pode ser executado de novo sem problemas.
# =============================================================================
set -euo pipefail

# ---------- Configuração -----------------------------------------------------
REPO_URL="https://pkg.claude-desktop-debian.dev/rpm/claude-desktop-unofficial.repo"
REPO_FILE="/etc/yum.repos.d/claude-desktop-unofficial.repo"
PACOTE="claude-desktop-unofficial"
FEDORA_MIN=40

CONFIG_COWORK=1
[[ "${1:-}" == "--sem-cowork" ]] && CONFIG_COWORK=0

# ---------- Saída colorida ---------------------------------------------------
verde()   { printf '\e[32m✔ %s\e[0m\n' "$*"; }
amarelo() { printf '\e[33m⚠ %s\e[0m\n' "$*"; }
azul()    { printf '\n\e[1;34m▶ %s\e[0m\n' "$*"; }
erro()    { printf '\e[31m✖ %s\e[0m\n' "$*" >&2; exit 1; }

# Instala pacotes um a um, sem parar se algum não existir na versão do Fedora
instalar_opcional() {
  local p
  for p in "$@"; do
    if sudo dnf install -y "$p" >/dev/null 2>&1; then
      verde "$p"
    else
      amarelo "$p não disponível nesta versão (ignorado)"
    fi
  done
}

PRECISA_RELOGAR=0

# ---------- 1. Pré-checagens -------------------------------------------------
azul "Verificando o sistema"

[[ $EUID -eq 0 ]] && erro "Não rode como root/sudo. Execute como seu usuário: bash $0"
command -v dnf >/dev/null \
  || erro "Sistema sem dnf. No Ubuntu/Mint/Debian use: https://github.com/sauloprado/claude-desktop-ubuntu"
command -v sudo >/dev/null || erro "sudo não encontrado."
sudo -v || erro "Não foi possível obter permissão de sudo."

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" || "$ARCH" == "aarch64" ]] \
  || erro "Arquitetura '$ARCH' não suportada (apenas x86_64 ou aarch64)."
verde "Arquitetura: $ARCH"

# shellcheck disable=SC1091
. /etc/os-release
echo "  Distribuição: ${PRETTY_NAME:-?}"
if [[ "${ID:-}" == "fedora" ]]; then
  [[ "${VERSION_ID:-0}" =~ ^[0-9]+$ && "$VERSION_ID" -ge $FEDORA_MIN ]] \
    || erro "Fedora ${VERSION_ID:-?} é antigo demais. Use Fedora $FEDORA_MIN ou superior."
  verde "Fedora $VERSION_ID compatível"
elif [[ " ${ID_LIKE:-} " == *" fedora "* || " ${ID_LIKE:-} " == *" rhel "* ]]; then
  amarelo "Derivado do Fedora/RHEL (${ID:-?}): deve funcionar, mas não foi testado."
else
  erro "Este script é para Fedora. Distribuição detectada: ${ID:-desconhecida}."
fi

# ---------- 2. Dependências --------------------------------------------------
azul "Instalando dependências (curl)"
sudo dnf install -y curl ca-certificates >/dev/null
verde "curl pronto"

# ---------- 3. Repositório DNF da comunidade ---------------------------------
azul "Registrando o repositório DNF (claude-desktop-unofficial)"
amarelo "A Anthropic ainda não publica pacote para Fedora: este repositório é da comunidade"
amarelo "(github.com/aaddrick/claude-desktop-debian) e reempacota o app oficial."
sudo curl -fsSLo "$REPO_FILE" "$REPO_URL" \
  || erro "Falha ao baixar o .repo. Verifique se a rede alcança pkg.claude-desktop-debian.dev."
grep -q '^\[' "$REPO_FILE" || { sudo rm -f "$REPO_FILE"; erro "Arquivo .repo inválido. Removido."; }
verde "Repositório em $REPO_FILE"

# ---------- 4. Instalação ----------------------------------------------------
azul "Instalando o $PACOTE"
sudo dnf makecache -y >/dev/null
# Na primeira vez o dnf pede para aceitar a chave GPG do repositório (-y aceita)
sudo dnf install -y "$PACOTE"
verde "Claude Desktop instalado: $(rpm -q --qf '%{VERSION}-%{RELEASE}' "$PACOTE")"

# ---------- 5. Chaveiro (para o login ficar salvo) ---------------------------
azul "Verificando o chaveiro do sistema (login salvo)"
if [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]]; then
  verde "KDE detectado — o KDE Wallet será usado"
else
  sudo dnf install -y gnome-keyring >/dev/null
  verde "gnome-keyring presente"
fi

# ---------- 6. Requisitos do Cowork (VM com QEMU/KVM) ------------------------
if [[ $CONFIG_COWORK -eq 1 ]]; then
  azul "Preparando requisitos do Cowork (QEMU + KVM)"

  if grep -Eq '(vmx|svm)' /proc/cpuinfo || [[ "$ARCH" == "aarch64" ]]; then
    verde "CPU com suporte a virtualização"
  else
    amarelo "Virtualização (VT-x/AMD-V) não detectada: ative na BIOS/UEFI para usar o Cowork."
  fi

  if [[ "$ARCH" == "x86_64" ]]; then
    instalar_opcional qemu-system-x86-core edk2-ovmf virtiofsd
  else
    instalar_opcional qemu-system-aarch64-core edk2-aarch64 virtiofsd
  fi

  if id -nG "$USER" | grep -qw kvm; then
    verde "Usuário '$USER' já está no grupo kvm"
  else
    sudo usermod -aG kvm "$USER"
    PRECISA_RELOGAR=1
    verde "Usuário '$USER' adicionado ao grupo kvm"
  fi

  if sudo modprobe vhost_vsock 2>/dev/null; then
    verde "Módulo vhost_vsock carregado"
  else
    amarelo "Não foi possível carregar vhost_vsock (kernel sem suporte?)"
  fi
  echo vhost_vsock | sudo tee /etc/modules-load.d/vhost_vsock.conf >/dev/null
  verde "vhost_vsock configurado para carregar no boot"
fi

# ---------- 7. Resumo --------------------------------------------------------
azul "Concluído!"
echo "  • Abra pelo menu de aplicativos (Claude) ou rode: $PACOTE"
echo "  • Faça login com sua conta (claude.ai ou SSO da organização)"
echo "  • Diagnóstico (Cowork, Wayland, chaveiro): $PACOTE --doctor"
echo "  • Atualizações chegam pelo dnf: sudo dnf upgrade"
echo "  • Para remover: sudo dnf remove $PACOTE && sudo rm -f $REPO_FILE"
if [[ $PRECISA_RELOGAR -eq 1 ]]; then
  amarelo "Faça LOGOUT e LOGIN de novo (ou reinicie) para o grupo kvm valer e o Cowork funcionar."
fi
