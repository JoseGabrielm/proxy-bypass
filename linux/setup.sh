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
#   sudo ./setup.sh                # pede IP/porta/senha numa pagina local no
#                                   # navegador (testa a conexao de verdade
#                                   # antes de aceitar, sem tocar na rede) e
#                                   # habilita reinicio automatico no boot
#   sudo ./setup.sh --reconfigure  # forca pedir os dados de novo, mesmo se
#                                   # ja houver credenciais confirmadas
#   sudo ./setup.sh --no-persist   # nao instala/habilita a unit de boot
#                                   # (voce roda ./setup.sh manualmente a
#                                   # cada reinicializacao, como antes)
#
# Se preferir, ainda da pra pre-preencher SERVER_IP/SERVER_PORT/SERVER_PASSWORD
# abaixo (a pagina abre com esses valores prontos, so falta confirmar).
#
set -euo pipefail

RECONFIGURE=0
NO_PERSIST=0
for _arg in "$@"; do
    case "$_arg" in
        --reconfigure) RECONFIGURE=1 ;;
        --no-persist)  NO_PERSIST=1 ;;
    esac
done

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
BOOT_SERVICE_NAME="discord-proxy-setup"
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
step "Configurando credenciais do Shadowsocks"

command -v python3 >/dev/null 2>&1 \
    || die "python3 nao encontrado - necessario para configurar as credenciais do Shadowsocks. Instale com o gerenciador de pacotes da sua distro (ex: apt install python3 / dnf install python3 / pacman -S python)."

CLIENT_JSON="${SS_CONFIG_DIR}/client.json"
EXISTING_IP=""
EXISTING_PORT=""
EXISTING_PASSWORD=""

if [[ -f "$CLIENT_JSON" ]]; then
    # Le via json.load (em vez de sed) para nao truncar senhas com aspas
    # escapadas, e escreve com shlex.quote para o 'source' ser seguro mesmo
    # com $()/crases/aspas na senha.
    EXISTING_SH="$(mktemp)"
    python3 -c '
import json, shlex, sys
cfg_path, out_path = sys.argv[1], sys.argv[2]
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
    ip, port, pw = str(cfg.get("server", "")), str(cfg.get("server_port", "")), str(cfg.get("password", ""))
except Exception:
    ip = port = pw = ""
with open(out_path, "w") as f:
    f.write("EXISTING_IP=%s\n" % shlex.quote(ip))
    f.write("EXISTING_PORT=%s\n" % shlex.quote(port))
    f.write("EXISTING_PASSWORD=%s\n" % shlex.quote(pw))
' "$CLIENT_JSON" "$EXISTING_SH" || true
    # shellcheck disable=SC1090
    source "$EXISTING_SH"
    rm -f "$EXISTING_SH"
fi

if [[ -n "$EXISTING_IP" && -n "$EXISTING_PASSWORD" && "$RECONFIGURE" -eq 0 ]]; then
    SERVER_IP="$EXISTING_IP"
    SERVER_PORT="${EXISTING_PORT:-$SERVER_PORT}"
    SERVER_PASSWORD="$EXISTING_PASSWORD"
    ok "Reaproveitando credenciais ja confirmadas em ${CLIENT_JSON} (use --reconfigure para trocar)"
else
    CURRENT_IP_FOR_FORM="$EXISTING_IP"
    [[ -z "$CURRENT_IP_FOR_FORM" && "$SERVER_IP" != "SEU_IP_AQUI" ]] && CURRENT_IP_FOR_FORM="$SERVER_IP"

    CURRENT_PORT_FOR_FORM="${EXISTING_PORT:-$SERVER_PORT}"

    CURRENT_PASSWORD_FOR_FORM="$EXISTING_PASSWORD"
    [[ -z "$CURRENT_PASSWORD_FOR_FORM" && "$SERVER_PASSWORD" != "SUA_SENHA_AQUI" ]] && CURRENT_PASSWORD_FOR_FORM="$SERVER_PASSWORD"

    CRED_PY="$(mktemp)"
    CRED_OUT="$(mktemp)"
    trap 'rm -f "$CRED_PY" "$CRED_OUT"' EXIT

    cat > "$CRED_PY" <<'PYEOF'
#!/usr/bin/env python3
import argparse, json, os, re, shlex, socket, subprocess, sys, tempfile, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

ap = argparse.ArgumentParser()
ap.add_argument("--current-ip", default="")
ap.add_argument("--current-port", default="")
ap.add_argument("--method", required=True)
ap.add_argument("--sslocal-bin", required=True)
ap.add_argument("--out-file", required=True)
args = ap.parse_args()

CURRENT_PASSWORD = os.environ.get("SS_CRED_CURRENT_PASSWORD", "")
HAS_CURRENT_PASSWORD = bool(CURRENT_PASSWORD)


def find_free_port(start, end, host="127.0.0.1"):
    for p in range(start, end + 1):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind((host, p))
            s.close()
            return p
        except OSError:
            continue
    return None


def test_connection(server, port, method, password):
    test_port = find_free_port(18080, 18090)
    if not test_port:
        return False

    cfg = {
        "server": server,
        "server_port": port,
        "password": password,
        "method": method,
        "local_address": "127.0.0.1",
        "local_port": test_port,
        "mode": "tcp_and_udp",
    }
    cfg_path = tempfile.mktemp(prefix="sslocal-test-")
    with open(cfg_path, "w") as f:
        json.dump(cfg, f)

    proc = None
    try:
        proc = subprocess.Popen(
            [args.sslocal_bin, "-c", cfg_path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        time.sleep(1.0)
        if proc.poll() is not None:
            return False

        try:
            r = subprocess.run(
                ["curl", "-s", "--max-time", "6", "--proxy",
                 "socks5h://127.0.0.1:%d" % test_port, "https://api.ipify.org"],
                capture_output=True, text=True, timeout=8,
            )
        except Exception:
            return False

        ip = (r.stdout or "").strip()
        return bool(re.match(r"^\d{1,3}(\.\d{1,3}){3}$", ip))
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
        if os.path.exists(cfg_path):
            os.remove(cfg_path)


PASS_NOTE = " (deixe em branco para manter a atual)" if HAS_CURRENT_PASSWORD else ""
HAS_PASS_JS = "true" if HAS_CURRENT_PASSWORD else "false"

PAGE = """<!DOCTYPE html>
<html lang="pt-br">
<head>
<meta charset="utf-8">
<title>Dados da proxy Shadowsocks</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 420px; margin: 60px auto; padding: 0 16px; background:#111; color:#eee; }
  label { display:block; margin-top: 16px; font-size: 14px; }
  input { width: 100%; padding: 8px; margin-top: 4px; box-sizing: border-box; background:#222; color:#eee; border:1px solid #444; border-radius:4px; font-size:14px; }
  button { margin-top: 24px; padding: 10px 20px; width: 100%; background:#4c8bf5; color:#fff; border:none; border-radius:4px; cursor:pointer; font-size:15px; }
  button:hover { background:#3a76e0; }
  .err { color:#ff6b6b; font-size: 13px; margin-top: 4px; min-height: 16px; }
  h2 { text-align:center; }
</style>
</head>
<body>
<h2>Dados da proxy Shadowsocks</h2>
<form id="f" novalidate>
  <label>IP/host do servidor
    <input id="ip" name="ip" value="__CURRENT_IP__" autocomplete="off">
  </label>
  <div class="err" id="errIp"></div>

  <label>Porta
    <input id="port" name="port" value="__CURRENT_PORT__" autocomplete="off">
  </label>
  <div class="err" id="errPort"></div>

  <label>Senha__PASS_NOTE__
    <input id="pass" name="pass" type="text" autocomplete="off">
  </label>
  <div class="err" id="errPass"></div>

  <div class="err" id="errGeneral" style="margin-top:12px"></div>
  <button type="submit" id="btn">Salvar e continuar</button>
</form>
<script>
var hasCurrentPass = __HAS_PASS_JS__;
var form = document.getElementById('f');
var btn = document.getElementById('btn');

form.addEventListener('submit', function (e) {
  e.preventDefault();
  var ip = document.getElementById('ip').value.trim();
  var port = document.getElementById('port').value.trim();
  var pass = document.getElementById('pass').value.replace(/\\s+/g, '');
  var ok = true;
  document.getElementById('errIp').textContent = '';
  document.getElementById('errPort').textContent = '';
  document.getElementById('errPass').textContent = '';
  document.getElementById('errGeneral').textContent = '';

  if (!ip) { document.getElementById('errIp').textContent = 'Informe o IP ou host.'; ok = false; }

  var portNum = Number(port);
  if (!port || !Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
    document.getElementById('errPort').textContent = 'Porta invalida (1-65535).';
    ok = false;
  }

  if (!pass && !hasCurrentPass) {
    document.getElementById('errPass').textContent = 'Informe a senha.';
    ok = false;
  }

  if (!ok) return;

  btn.disabled = true;
  btn.textContent = 'Testando conexao com o servidor...';

  fetch('/submit', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'ip=' + encodeURIComponent(ip) + '&port=' + encodeURIComponent(port) + '&pass=' + encodeURIComponent(pass)
  }).then(function (r) {
    return r.text().then(function (text) { return { ok: r.ok, text: text }; });
  }).then(function (res) {
    if (res.ok) {
      document.body.innerHTML = '<h2>Conectado! Pode fechar esta aba e voltar ao terminal.</h2>';
      return;
    }
    btn.disabled = false;
    btn.textContent = 'Salvar e continuar';
    if (res.text === 'AUTH_FAILED') {
      document.getElementById('errGeneral').textContent = 'Nao consegui conectar nesse servidor com esses dados. Confira IP, porta e senha, e tente de novo.';
    } else {
      document.getElementById('errGeneral').textContent = 'Dados invalidos, confira os campos.';
    }
  }).catch(function () {
    btn.disabled = false;
    btn.textContent = 'Salvar e continuar';
    document.getElementById('errGeneral').textContent = 'Erro ao enviar. Tente novamente.';
  });
});
</script>
</body>
</html>
"""

PAGE = (PAGE
        .replace("__CURRENT_IP__", args.current_ip)
        .replace("__CURRENT_PORT__", str(args.current_port))
        .replace("__PASS_NOTE__", PASS_NOTE)
        .replace("__HAS_PASS_JS__", HAS_PASS_JS))
PAGE_BYTES = PAGE.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        pass

    def do_GET(self):
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(PAGE_BYTES)))
            self.end_headers()
            self.wfile.write(PAGE_BYTES)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/submit":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8")
        data = parse_qs(raw)
        ip = data.get("ip", [""])[0].strip()
        port_str = data.get("port", [""])[0].strip()
        pw = re.sub(r"\s+", "", data.get("pass", [""])[0])

        port = None
        try:
            port = int(port_str)
        except ValueError:
            pass

        format_valid = bool(ip) and port is not None and 1 <= port <= 65535 and (pw or HAS_CURRENT_PASSWORD)

        status = "INVALID"
        if format_valid:
            test_pw = pw if pw else CURRENT_PASSWORD
            print("    Testando conexao com %s:%d (isolado, sem tocar na rede)..." % (ip, port))
            if test_connection(ip, port, args.method, test_pw):
                status = "OK"
                print("    [OK] Conexao com %s:%d confirmada" % (ip, port))
            else:
                status = "AUTH_FAILED"
                print("    [AVISO] Nao consegui conectar em %s:%d com os dados informados - pedindo de novo na pagina" % (ip, port))

        body = status.encode("utf-8")
        self.send_response(200 if status == "OK" else 400)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

        if status == "OK":
            with open(args.out_file, "w") as f:
                f.write("NEW_SERVER_IP=%s\n" % shlex.quote(ip))
                f.write("NEW_SERVER_PORT=%d\n" % port)
                f.write("NEW_SERVER_PASSWORD=%s\n" % shlex.quote(pw if pw else CURRENT_PASSWORD))
            threading.Thread(target=self.server.shutdown, daemon=True).start()


listen_port = find_free_port(8765, 8774)
if listen_port is None:
    print("Nao consegui abrir um servidor local (portas 8765-8774 ocupadas)", file=sys.stderr)
    sys.exit(1)

httpd = HTTPServer(("127.0.0.1", listen_port), Handler)
url = "http://127.0.0.1:%d/" % listen_port
print("    Pagina: %s  (abrindo no navegador padrao...)" % url)
try:
    webbrowser.open(url)
except Exception:
    print("    Nao consegui abrir o navegador automaticamente. Acesse: %s" % url)

httpd.serve_forever()
PYEOF

    SS_CRED_CURRENT_PASSWORD="$CURRENT_PASSWORD_FOR_FORM" python3 "$CRED_PY" \
        --current-ip "$CURRENT_IP_FOR_FORM" \
        --current-port "$CURRENT_PORT_FOR_FORM" \
        --method "$METHOD" \
        --sslocal-bin "${BIN_DIR}/sslocal" \
        --out-file "$CRED_OUT" \
        || die "Falha ao rodar a pagina de credenciais (python3 ${CRED_PY})"

    # shellcheck disable=SC1090
    source "$CRED_OUT"
    rm -f "$CRED_PY" "$CRED_OUT"

    [[ -n "${NEW_SERVER_IP:-}" ]] || die "Nao recebi os dados da pagina de credenciais."
    SERVER_IP="$NEW_SERVER_IP"
    SERVER_PORT="$NEW_SERVER_PORT"
    SERVER_PASSWORD="$NEW_SERVER_PASSWORD"
    ok "Dados recebidos e conexao com o servidor confirmada"
fi

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
BOOT_SERVICE_NAME=${BOOT_SERVICE_NAME}
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
# Gerado via python (json.dump) em vez de heredoc bash: a senha vem de um
# formulario web agora (texto livre), e um heredoc <<EOF sem aspas faz
# expansao de $(...) / crases no conteudo - risco de injecao de comando
# como root, alem de poder gerar JSON invalido se a senha tiver aspas.
SS_JSON_SERVER="$SERVER_IP" SS_JSON_PORT="$SERVER_PORT" SS_JSON_PASSWORD="$SERVER_PASSWORD" \
SS_JSON_METHOD="$METHOD" SS_JSON_LOCAL_ADDR="$VETH_HOST_IP" SS_JSON_LOCAL_PORT="$SOCKS_PORT" \
SS_JSON_OUT="${SS_CONFIG_DIR}/client.json" python3 -c '
import json, os
cfg = {
    "server": os.environ["SS_JSON_SERVER"],
    "server_port": int(os.environ["SS_JSON_PORT"]),
    "password": os.environ["SS_JSON_PASSWORD"],
    "method": os.environ["SS_JSON_METHOD"],
    "local_address": os.environ["SS_JSON_LOCAL_ADDR"],
    "local_port": int(os.environ["SS_JSON_LOCAL_PORT"]),
    "mode": "tcp_and_udp",
}
with open(os.environ["SS_JSON_OUT"], "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
' || die "Falha ao gerar ${SS_CONFIG_DIR}/client.json"

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

# ------------------------------------------------------------------------
if [[ $NO_PERSIST -eq 0 ]]; then
    step "Habilitando execucao automatica no boot"

    # ExecStart aponta pro caminho real deste script (SCRIPT_DIR), entao
    # funciona onde quer que o repositorio esteja clonado. Como o script e'
    # idempotente e ja tem as credenciais confirmadas em client.json a essa
    # altura, rodar de novo no boot NAO abre navegador nem pede nada -
    # so recria namespace/veth/NAT/tun2socks, que somem no reboot.
    cat > "/etc/systemd/system/${BOOT_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Recria o namespace/tunel do Discord (proxy-bypass) no boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT_DIR}/setup.sh
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$BOOT_SERVICE_NAME" >/dev/null
    ok "Unit '${BOOT_SERVICE_NAME}' habilitada - o setup roda sozinho a cada boot, sem pedir nada de novo"
    ok "Pra desativar: sudo systemctl disable ${BOOT_SERVICE_NAME}  (ou rode ./setup.sh --no-persist da proxima vez)"
else
    if systemctl list-unit-files 2>/dev/null | grep -q "^${BOOT_SERVICE_NAME}.service"; then
        systemctl disable "$BOOT_SERVICE_NAME" 2>/dev/null || true
        rm -f "/etc/systemd/system/${BOOT_SERVICE_NAME}.service"
        systemctl daemon-reload
        ok "Execucao automatica no boot desativada (--no-persist). Rode 'sudo ./setup.sh' manualmente apos cada reinicializacao."
    else
        ok "Execucao automatica no boot NAO habilitada (--no-persist). Rode 'sudo ./setup.sh' manualmente apos cada reinicializacao."
    fi
fi

echo -e "\nSetup concluido. Use ./run-discord.sh para abrir o Discord dentro do proxy."
echo "Usuario detectado para rodar o Discord: ${REAL_USER}"
