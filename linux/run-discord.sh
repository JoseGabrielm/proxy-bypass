#!/usr/bin/env bash
#
# run-discord.sh — Lanca o Discord dentro do namespace "discord-ns" criado
# pelo setup.sh. Todo o trafego do Discord (texto, API, voz, video, screen
# share) sai pela VPS; o resto do sistema fica de fora.
#
# Uso: ./run-discord.sh   (nao precisa rodar como root, ele mesmo pede sudo
#                          so para o comando 'ip netns exec')
#
set -euo pipefail

NETNS_NAME="discord-ns"

if ! ip netns list 2>/dev/null | grep -q "^${NETNS_NAME}"; then
    echo "O namespace '${NETNS_NAME}' nao existe."
    echo "Rode primeiro: sudo ./setup.sh"
    exit 1
fi

DISCORD_BIN="$(command -v discord || true)"
if [[ -z "$DISCORD_BIN" ]]; then
    echo "Nao encontrei o binario 'discord' no PATH."
    echo "Edite este script e defina DISCORD_BIN manualmente com o caminho correto."
    exit 1
fi

# Descobre o usuario "de verdade" (dono da sessao grafica), mesmo que este
# script tenha sido chamado com sudo por engano. O Electron RECUSA rodar
# como root (sem --no-sandbox), entao e' essencial nao deixar o Discord
# ser lancado como root aqui dentro.
if [[ $EUID -eq 0 ]]; then
    if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
        echo "Este script foi chamado como root e nao consigo identificar seu usuario normal."
        echo "Rode SEM sudo: ./run-discord.sh (ele mesmo pede a senha so quando precisar)."
        exit 1
    fi
    REAL_USER="$SUDO_USER"
    REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
else
    REAL_USER="$(id -un)"
    REAL_HOME="$HOME"
fi

echo "Abrindo Discord dentro do namespace ${NETNS_NAME} (${DISCORD_BIN}) como usuario '${REAL_USER}'..."
echo "Vai pedir sua senha de sudo (necessaria para 'ip netns exec')."

exec sudo ip netns exec "$NETNS_NAME" runuser -u "$REAL_USER" -- \
    env DISPLAY="${DISPLAY:-}" \
        XAUTHORITY="${XAUTHORITY:-$REAL_HOME/.Xauthority}" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
    "$DISCORD_BIN"
