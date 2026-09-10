#!/usr/bin/env bash
#
# teardown.sh — Desfaz TUDO que o setup.sh criou: namespace, veth, regra de
# NAT, servico systemd e arquivos de config. Seguro de rodar mesmo que o
# setup tenha falhado no meio ou ja tenha sido revertido antes (nao quebra
# se algo ja nao existir).
#
# Uso:
#   sudo ./teardown.sh            # reverte tudo, mantem os binarios sslocal/tun2socks
#   sudo ./teardown.sh --purge    # alem disso, remove os binarios tambem
#
set -uo pipefail   # sem -e: queremos best-effort, continuar mesmo se um passo falhar

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.state"
BIN_DIR="/usr/local/bin"

PURGE_BINARIES=0
[[ "${1:-}" == "--purge" ]] && PURGE_BINARIES=1

step() { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "    \033[1;33m[ATENCAO]\033[0m $*"; }

if [[ $EUID -ne 0 ]]; then
    echo "Precisa de root para desfazer namespaces/iptables/systemd."
    exec sudo -E "$0" "$@"
fi

# Valores default, sobrescritos pelo .state se ele existir
NETNS_NAME="discord-ns"
VETH_HOST="veth-host"
VETH_NS_IP="10.200.200.2"
SS_SERVICE_NAME="shadowsocks-netns-client"
SS_CONFIG_DIR="/etc/shadowsocks"
NETNS_DNS_DIR="/etc/netns/discord-ns"
IFACE_OUT=""
IP_FORWARD_WAS_ENABLED="1"

if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    ok "Estado carregado de ${STATE_FILE}"
else
    warn "Arquivo de estado (.state) nao encontrado — usando valores padrao. Alguns passos (interface de saida do NAT) podem precisar de conferencia manual."
fi

# ------------------------------------------------------------------------
step "Encerrando processos dentro do namespace (tun2socks, discord, etc)"

if ip netns list 2>/dev/null | grep -q "^${NETNS_NAME}"; then
    PIDS="$(ip netns pids "$NETNS_NAME" 2>/dev/null || true)"
    if [[ -n "$PIDS" ]]; then
        echo "$PIDS" | xargs -r kill 2>/dev/null
        sleep 1
        echo "$PIDS" | xargs -r kill -9 2>/dev/null
        ok "Processos do namespace encerrados."
    else
        ok "Nenhum processo rodando no namespace."
    fi
else
    ok "Namespace ${NETNS_NAME} nao existe, nada a encerrar."
fi

# ------------------------------------------------------------------------
step "Removendo o network namespace (isso remove veth-ns e tun0 junto)"

if ip netns list 2>/dev/null | grep -q "^${NETNS_NAME}"; then
    ip netns del "$NETNS_NAME" && ok "Namespace ${NETNS_NAME} removido." || warn "Falha ao remover o namespace."
else
    ok "Namespace ${NETNS_NAME} ja nao existia."
fi

# ------------------------------------------------------------------------
step "Removendo a interface veth do lado do host (se ainda existir)"

if ip link show "$VETH_HOST" &>/dev/null; then
    ip link del "$VETH_HOST" && ok "Interface ${VETH_HOST} removida." || warn "Falha ao remover ${VETH_HOST}."
else
    ok "Interface ${VETH_HOST} ja nao existia."
fi

# ------------------------------------------------------------------------
step "Removendo a regra de NAT"

if [[ -n "$IFACE_OUT" ]]; then
    if iptables -t nat -C POSTROUTING -s "${VETH_NS_IP}/32" -o "$IFACE_OUT" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -D POSTROUTING -s "${VETH_NS_IP}/32" -o "$IFACE_OUT" -j MASQUERADE
        ok "Regra de NAT removida (${VETH_NS_IP}/32 -> ${IFACE_OUT})."
    else
        ok "Regra de NAT ja nao existia."
    fi
else
    warn "Interface de saida desconhecida (sem .state). Verifique manualmente:"
    warn "  sudo iptables -t nat -L POSTROUTING -n --line-numbers"
    warn "  procure uma regra MASQUERADE com origem ${VETH_NS_IP}/32 e remova com:"
    warn "  sudo iptables -t nat -D POSTROUTING <numero-da-linha>"
fi

# ------------------------------------------------------------------------
step "Revertendo net.ipv4.ip_forward, se este script foi quem ativou"

if [[ "$IP_FORWARD_WAS_ENABLED" == "0" ]]; then
    sysctl -w net.ipv4.ip_forward=0 >/dev/null
    ok "net.ipv4.ip_forward revertido para 0 (estava desativado antes do setup.sh)."
else
    ok "net.ipv4.ip_forward mantido em 1 (ja estava ativo antes do setup — provavelmente por causa do Docker; desativa-lo agora quebraria containers)."
fi

# ------------------------------------------------------------------------
step "Parando e removendo o servico systemd do Shadowsocks"

if systemctl list-unit-files 2>/dev/null | grep -q "^${SS_SERVICE_NAME}.service"; then
    systemctl stop "$SS_SERVICE_NAME" 2>/dev/null
    systemctl disable "$SS_SERVICE_NAME" 2>/dev/null
    rm -f "/etc/systemd/system/${SS_SERVICE_NAME}.service"
    systemctl daemon-reload
    ok "Servico ${SS_SERVICE_NAME} removido."
else
    ok "Servico ${SS_SERVICE_NAME} ja nao existia."
fi

# ------------------------------------------------------------------------
step "Removendo arquivos de configuracao"

rm -rf "$SS_CONFIG_DIR" "$NETNS_DNS_DIR"
ok "Removidos: ${SS_CONFIG_DIR}, ${NETNS_DNS_DIR}"

if [[ $PURGE_BINARIES -eq 1 ]]; then
    step "Removendo binarios (--purge)"
    rm -f "${BIN_DIR}/sslocal" "${BIN_DIR}/tun2socks"
    ok "Binarios removidos de ${BIN_DIR}"
fi

rm -f "$STATE_FILE"

# ------------------------------------------------------------------------
step "Estado final da rede (confira se esta tudo normal)"

echo "--- Namespaces de rede ---"
ip netns list 2>/dev/null || echo "(nenhum)"
echo "--- Interfaces ---"
ip -brief link show
echo "--- Rota default ---"
ip route show default
echo "--- Teste de internet do host ---"
if curl -s --max-time 5 https://ifconfig.me; then
    echo ""
    ok "Internet do host respondendo normalmente."
else
    warn "Sem resposta. Tente: sudo systemctl restart NetworkManager (ou reinicie a maquina)."
fi

echo -e "\nReversao concluida."
