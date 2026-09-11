#!/usr/bin/env bash
#
# setup.sh — Cria um network namespace isolado ("discord-ns") com um tunel
# Shadowsocks + tun2socks, para que SOMENTE o processo do Discord (lancado
# via run-discord.sh) saia pela VPS, cobrindo TCP e UDP (texto, API, voz,
# video e compartilhamento de tela).
#
# Tudo que este script cria e' aditivo e escopado (namespace proprio, IP
# de NAT restrito a um /32, interface veth dedicada) — nao mexe na rota
# default nem nas interfaces reais do host. Mesmo assim, use teardown.sh
# a qualquer momento para desfazer tudo caso algo pareca errado.
#
# Uso:
#   1. Edite SERVER_IP e SERVER_PASSWORD abaixo.
#   2. sudo ./setup.sh
#
set -euo pipefail

# ============================ CONFIGURACAO ============================
SERVER_IP="${PROXY_IP:-SEU_IP_AQUI}"
SERVER_PORT="${PROXY_PORT:-8388}"
SERVER_PASSWORD="${PROXY_PASSWORD:-SUA_SENHA_AQUI}"
METHOD="chacha20-ietf-poly1305"

NETNS_NAME="discord-ns"
VETH_HOST="veth-host"
VETH_NS="veth-ns"
VETH_HOST_IP="10.200.200.1"
VETH_NS_IP="10.200.200.2"
VETH_PREFIX="24"
SOCKS_PORT="1080"
TUN_IF="tun0"
TUN_IP="198.18.0.1/15"
DNS_SERVER="1.1.1.1"

SS_VERSION="1.25.0"
TUN2SOCKS_VERSION="2.7.0"
# ========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.state"
DOWNLOAD_DIR="${SCRIPT_DIR}/.downloads"
BIN_DIR="/usr/local/bin"
SS_CONFIG_DIR="/etc/shadowsocks"
SS_SERVICE_NAME="shadowsocks-netns-client"
NETNS_DNS_DIR="/etc/netns/${NETNS_NAME}"

step() { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "    \033[1;33m[ATENCAO]\033[0m $*"; }
die()  { echo -e "    \033[1;31m[ERRO]\033[0m $*"; exit 1; }

# ------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Este script precisa de root (cria namespaces, interfaces e regras de firewall)."
    exec sudo -E "$0" "$@"
fi

if [[ "$SERVER_IP" == "SEU_IP_AQUI" ]]; then
    die "Edite a variavel SERVER_IP no topo do script antes de rodar."
fi

if [[ "$SERVER_PASSWORD" == "SUA_SENHA_AQUI" ]]; then
    die "Edite a variavel SERVER_PASSWORD no topo do script antes de rodar."
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"

mkdir -p "$DOWNLOAD_DIR"

# ------------------------------------------------------------------------
step "Verificando/baixando binarios (sslocal, tun2socks)"

CURL_OPTS=(--retry 5 --retry-delay 3 --retry-connrefused --retry-all-errors -fL)

# IMPORTANTE: checamos o ARQUIVO REAL no destino final (-x "${BIN_DIR}/...")
# em vez de 'command -v', que depende de PATH/hash do shell e pode dar falso
# positivo (foi a causa de um bug real: o script achava que 'sslocal' ja
# existia e pulava a instalacao, mesmo com o binario ausente).
if [[ ! -x "${BIN_DIR}/sslocal" ]]; then
    ARCHIVE="shadowsocks-v${SS_VERSION}.x86_64-unknown-linux-musl.tar.xz"
    curl "${CURL_OPTS[@]}" -o "${DOWNLOAD_DIR}/${ARCHIVE}" \
        "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${SS_VERSION}/${ARCHIVE}" \
        || die "Falha ao baixar sslocal apos varias tentativas. Confira sua conexao e rode o script de novo."

    [[ -s "${DOWNLOAD_DIR}/${ARCHIVE}" ]] || die "Download de sslocal terminou com arquivo vazio/ausente."

    tar xf "${DOWNLOAD_DIR}/${ARCHIVE}" -C "$DOWNLOAD_DIR" sslocal \
        || die "Falha ao extrair 'sslocal' do arquivo baixado (${ARCHIVE})."

    [[ -f "${DOWNLOAD_DIR}/sslocal" ]] || die "Extracao terminou sem erro, mas ${DOWNLOAD_DIR}/sslocal nao existe."

    install -m 755 "${DOWNLOAD_DIR}/sslocal" "${BIN_DIR}/sslocal" \
        || die "Falha ao copiar sslocal para ${BIN_DIR}."

    [[ -x "${BIN_DIR}/sslocal" ]] || die "install terminou sem erro, mas ${BIN_DIR}/sslocal nao existe/nao e executavel."

    ok "sslocal instalado em ${BIN_DIR}/sslocal"
else
    ok "sslocal ja instalado em ${BIN_DIR}/sslocal"
fi

if [[ ! -x "${BIN_DIR}/tun2socks" ]]; then
    ZIPFILE="tun2socks-linux-amd64.zip"
    curl "${CURL_OPTS[@]}" -o "${DOWNLOAD_DIR}/${ZIPFILE}" \
        "https://github.com/xjasonlyu/tun2socks/releases/download/v${TUN2SOCKS_VERSION}/${ZIPFILE}" \
        || die "Falha ao baixar tun2socks apos varias tentativas. Confira sua conexao e rode o script de novo."

    [[ -s "${DOWNLOAD_DIR}/${ZIPFILE}" ]] || die "Download de tun2socks terminou com arquivo vazio/ausente."

    (cd "$DOWNLOAD_DIR" && unzip -o "$ZIPFILE" >/dev/null) \
        || die "Falha ao extrair o pacote do tun2socks (${ZIPFILE})."

    [[ -f "${DOWNLOAD_DIR}/tun2socks-linux-amd64" ]] || die "Extracao terminou sem erro, mas ${DOWNLOAD_DIR}/tun2socks-linux-amd64 nao existe."

    install -m 755 "${DOWNLOAD_DIR}/tun2socks-linux-amd64" "${BIN_DIR}/tun2socks" \
        || die "Falha ao copiar tun2socks para ${BIN_DIR}."

    [[ -x "${BIN_DIR}/tun2socks" ]] || die "install terminou sem erro, mas ${BIN_DIR}/tun2socks nao existe/nao e executavel."

    ok "tun2socks instalado em ${BIN_DIR}/tun2socks"
else
    ok "tun2socks ja instalado em ${BIN_DIR}/tun2socks"
fi

# Checkpoint: nao adianta seguir (configurar servico, criar namespace, etc)
# se por qualquer motivo os binarios nao estiverem realmente utilizaveis.
[[ -x "${BIN_DIR}/sslocal" ]]   || die "sslocal ausente em ${BIN_DIR} mesmo apos a instalacao — aborte e investigue antes de continuar."
[[ -x "${BIN_DIR}/tun2socks" ]] || die "tun2socks ausente em ${BIN_DIR} mesmo apos a instalacao — aborte e investigue antes de continuar."
ok "Checkpoint: ambos os binarios confirmados em ${BIN_DIR}."

# ------------------------------------------------------------------------
step "Registrando estado atual do sistema (para o teardown reverter com precisao)"

IP_FORWARD_WAS_ENABLED="$(sysctl -n net.ipv4.ip_forward)"
IFACE_OUT="$(ip route show default | awk '{print $5; exit}')"
[[ -n "$IFACE_OUT" ]] || die "Nao consegui detectar a interface de saida default (ip route show default vazio)."

cat > "$STATE_FILE" <<EOF
IP_FORWARD_WAS_ENABLED=${IP_FORWARD_WAS_ENABLED}
IFACE_OUT=${IFACE_OUT}
VETH_HOST_IP=${VETH_HOST_IP}
VETH_NS_IP=${VETH_NS_IP}
NETNS_NAME=${NETNS_NAME}
VETH_HOST=${VETH_HOST}
SS_SERVICE_NAME=${SS_SERVICE_NAME}
SS_CONFIG_DIR=${SS_CONFIG_DIR}
NETNS_DNS_DIR=${NETNS_DNS_DIR}
SETUP_DATE=$(date -Iseconds)
EOF
ok "Estado salvo em ${STATE_FILE}"

# ------------------------------------------------------------------------
step "Criando o network namespace '${NETNS_NAME}' e a interface veth"

if ip netns list 2>/dev/null | grep -q "^${NETNS_NAME}"; then
    warn "Namespace ${NETNS_NAME} ja existe, pulando criacao (rode teardown.sh antes se quiser recriar do zero)."
else
    ip netns add "$NETNS_NAME"
    ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
    ip link set "$VETH_NS" netns "$NETNS_NAME"

    ip addr add "${VETH_HOST_IP}/${VETH_PREFIX}" dev "$VETH_HOST"
    ip link set "$VETH_HOST" up

    ip netns exec "$NETNS_NAME" ip addr add "${VETH_NS_IP}/${VETH_PREFIX}" dev "$VETH_NS"
    ip netns exec "$NETNS_NAME" ip link set "$VETH_NS" up
    ip netns exec "$NETNS_NAME" ip link set lo up
    ip netns exec "$NETNS_NAME" ip route add default via "$VETH_HOST_IP"
    ok "Namespace e veth criados (${VETH_HOST_IP} <-> ${VETH_NS_IP})"
fi

# ------------------------------------------------------------------------
step "Habilitando ip_forward e NAT (escopado ao IP do namespace, nao afeta o resto da rede)"

sysctl -w net.ipv4.ip_forward=1 >/dev/null

if ! iptables -t nat -C POSTROUTING -s "${VETH_NS_IP}/32" -o "$IFACE_OUT" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "${VETH_NS_IP}/32" -o "$IFACE_OUT" -j MASQUERADE
    ok "Regra de NAT adicionada (${VETH_NS_IP}/32 -> ${IFACE_OUT})"
else
    ok "Regra de NAT ja existia"
fi

# ------------------------------------------------------------------------
step "Configurando e subindo o cliente Shadowsocks (sslocal), escutando so para o namespace"

mkdir -p "$SS_CONFIG_DIR"
cat > "${SS_CONFIG_DIR}/client.json" <<EOF
{
  "server": "${SERVER_IP}",
  "server_port": ${SERVER_PORT},
  "password": "${SERVER_PASSWORD}",
  "method": "${METHOD}",
  "local_address": "${VETH_HOST_IP}",
  "local_port": ${SOCKS_PORT},
  "mode": "tcp_and_udp"
}
EOF

cat > "/etc/systemd/system/${SS_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Shadowsocks client (sslocal) para o namespace do Discord
After=network-online.target

[Service]
ExecStart=${BIN_DIR}/sslocal -c ${SS_CONFIG_DIR}/client.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl reset-failed "$SS_SERVICE_NAME" 2>/dev/null || true
systemctl enable --now "$SS_SERVICE_NAME"
sleep 2
systemctl is-active --quiet "$SS_SERVICE_NAME" && ok "Servico ${SS_SERVICE_NAME} ativo" || die "Servico ${SS_SERVICE_NAME} nao subiu, veja: journalctl -u ${SS_SERVICE_NAME}"

# ------------------------------------------------------------------------
step "Subindo tun2socks dentro do namespace"

# Mata uma instancia anterior de tun2socks nesse namespace, se houver
ip netns pids "$NETNS_NAME" 2>/dev/null | while read -r pid; do
    if readlink "/proc/${pid}/exe" 2>/dev/null | grep -q tun2socks; then
        kill "$pid" 2>/dev/null || true
    fi
done
sleep 1

ip netns exec "$NETNS_NAME" env -- \
    nohup "${BIN_DIR}/tun2socks" --device "$TUN_IF" --proxy "socks5://${VETH_HOST_IP}:${SOCKS_PORT}" \
    > /tmp/tun2socks-discord-ns.log 2>&1 &
disown

# Espera ativa pela interface aparecer dentro do namespace, em vez de um
# sleep fixo (o tun2socks pode demorar mais que 2s pra subir na primeira vez).
TUN_WAIT_TIMEOUT=15
tun_ready=0
for ((i = 0; i < TUN_WAIT_TIMEOUT; i++)); do
    if ip netns exec "$NETNS_NAME" ip link show "$TUN_IF" &>/dev/null; then
        tun_ready=1
        break
    fi
    sleep 1
done

if [[ $tun_ready -ne 1 ]]; then
    warn "Interface ${TUN_IF} nao apareceu apos ${TUN_WAIT_TIMEOUT}s. Log do tun2socks:"
    cat /tmp/tun2socks-discord-ns.log 2>/dev/null || true
    die "tun2socks nao criou a interface ${TUN_IF} a tempo."
fi
ok "Interface ${TUN_IF} detectada apos $((i + 1))s."

ip netns exec "$NETNS_NAME" ip addr add "$TUN_IP" dev "$TUN_IF"
ip netns exec "$NETNS_NAME" ip link set "$TUN_IF" up
ip netns exec "$NETNS_NAME" ip route replace default dev "$TUN_IF"
ok "tun2socks rodando (log em /tmp/tun2socks-discord-ns.log)"

# ------------------------------------------------------------------------
step "Configurando DNS do namespace"

mkdir -p "$NETNS_DNS_DIR"
echo "nameserver ${DNS_SERVER}" > "${NETNS_DNS_DIR}/resolv.conf"
ok "DNS do namespace: ${DNS_SERVER}"

# ------------------------------------------------------------------------
step "Testando conectividade de dentro do namespace"

RESULT="$(ip netns exec "$NETNS_NAME" curl -s --max-time 10 https://ifconfig.me || echo "FALHOU")"
if [[ "$RESULT" == "$SERVER_IP" ]]; then
    ok "Sucesso! Saida do namespace confirmada como ${RESULT} (IP da VPS)."
else
    warn "Resultado inesperado: '${RESULT}' (esperado ${SERVER_IP})."
    warn "Rode 'sudo ./teardown.sh' se quiser desfazer tudo, ou investigue com:"
    warn "  sudo ip netns exec ${NETNS_NAME} curl -v https://ifconfig.me"
fi

# ------------------------------------------------------------------------
step "Verificando que a rede normal do host nao foi afetada"

if curl -s --max-time 5 https://ifconfig.me >/dev/null; then
    ok "Rede do host (fora do namespace) segue normal."
else
    warn "Nao consegui confirmar a rede do host — verifique manualmente. Se algo quebrou, rode: sudo ./teardown.sh"
fi

echo -e "\nSetup concluido. Use ./run-discord.sh para abrir o Discord dentro do proxy."
echo "Usuario detectado para rodar o Discord: ${REAL_USER}"
