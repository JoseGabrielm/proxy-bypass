#!/usr/bin/env bash
#
# run-discord.sh — Lanca o Discord dentro do namespace "discord-ns" criado
# pelo setup.sh. Todo o trafego do Discord (texto, API, voz, video, screen
# share) sai pela VPS; o resto do sistema fica de fora.
#
# Se o Discord ja estiver aberto fora do namespace, o Electron detecta a
# instancia existente, repassa o controle pra ela e sai ("Quitting secondary
# instance") - nesse caso nada passa pela proxy. Por isso este script mata
# qualquer instancia ja rodando antes de abrir a isolada.
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

# Mata qualquer instancia do Discord ja rodando fora do namespace (ver nota
# no topo do arquivo sobre o lock de instancia unica do Electron).
EXISTING_PIDS="$(pgrep -u "$REAL_USER" -i discord || true)"
if [[ -n "$EXISTING_PIDS" ]]; then
    echo "Encontrei o Discord ja rodando fora do namespace - encerrando antes de abrir a versao isolada..."
    # shellcheck disable=SC2086
    kill $EXISTING_PIDS 2>/dev/null || true
    for _ in $(seq 1 10); do
        pgrep -u "$REAL_USER" -i discord >/dev/null 2>&1 || break
        sleep 1
    done
    if pgrep -u "$REAL_USER" -i discord >/dev/null 2>&1; then
        echo "Ainda tinha processo(s) de pe, forcando encerramento..."
        # shellcheck disable=SC2086
        kill -9 $(pgrep -u "$REAL_USER" -i discord) 2>/dev/null || true
        sleep 1
    fi
fi

echo "Abrindo Discord dentro do namespace ${NETNS_NAME} (${DISCORD_BIN}) como usuario '${REAL_USER}'..."
echo "Vai pedir sua senha de sudo (necessaria para 'ip netns exec')."

exec sudo ip netns exec "$NETNS_NAME" runuser -u "$REAL_USER" -- \
    env DISPLAY="${DISPLAY:-}" \
        XAUTHORITY="${XAUTHORITY:-$REAL_HOME/.Xauthority}" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
    "$DISCORD_BIN"
