#!/usr/bin/env python3
import os
import json
import socket
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

PORT = 19800
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
UI_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "ui")
SETUP_SH = os.path.join(SCRIPT_DIR, "setup.sh")
TEARDOWN_SH = os.path.join(SCRIPT_DIR, "teardown.sh")

class ProxyUIHandler(BaseHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/":
            path = "/index.html"
            
        file_path = os.path.join(UI_DIR, path.lstrip('/'))
        if os.path.exists(file_path) and os.path.isfile(file_path):
            self.send_response(200)
            if path.endswith('.html'):
                self.send_header('Content-Type', 'text/html; charset=utf-8')
            elif path.endswith('.css'):
                self.send_header('Content-Type', 'text/css; charset=utf-8')
            elif path.endswith('.js'):
                self.send_header('Content-Type', 'application/javascript; charset=utf-8')
            self.end_headers()
            with open(file_path, 'rb') as f:
                self.wfile.write(f.read())
        elif path == "/api/status":
            self.handle_status()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/install":
            self.handle_install()
        elif path == "/api/test":
            self.handle_test()
        elif path == "/api/monitor":
            self.handle_monitor()
        elif path == "/api/cancel":
            self.handle_cancel()
        else:
            self.send_response(404)
            self.end_headers()

    def handle_status(self):
        installed = os.path.exists(os.path.join(SCRIPT_DIR, ".state"))
        
        # Check if service is running
        running = False
        if installed:
            res = subprocess.run(["systemctl", "is-active", "--quiet", "shadowsocks-netns-client"])
            running = (res.returncode == 0)

        proxy_info = None
        # Try to read client.json to get proxy info
        cfg_path = "/etc/shadowsocks/client.json"
        if os.path.exists(cfg_path):
            try:
                with open(cfg_path, 'r') as f:
                    cfg = json.load(f)
                    proxy_info = {"ip": cfg.get("server"), "port": cfg.get("server_port")}
            except:
                pass

        self.send_json({"installed": installed, "running": running, "proxyInfo": proxy_info})

    def handle_install(self):
        content_len = int(self.headers.get('Content-Length', 0))
        data = json.loads(self.rfile.read(content_len))
        
        ip = data.get("ip")
        port = data.get("port")
        password = data.get("password")

        # Set env vars for setup.sh
        env = os.environ.copy()
        env["PROXY_IP"] = ip
        env["PROXY_PORT"] = str(port)
        env["PROXY_PASSWORD"] = password

        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()

        def send_sse(event, data_obj):
            msg = f"event: {event}\ndata: {json.dumps(data_obj)}\n\n"
            self.wfile.write(msg.encode('utf-8'))
            self.wfile.flush()

        try:
            send_sse("step", {"id": "download", "status": "running", "message": "Iniciando setup.sh..."})
            
            # Start setup.sh
            process = subprocess.Popen([SETUP_SH], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, text=True)
            
            send_sse("step", {"id": "download", "status": "done", "message": "Ambiente iniciado."})
            send_sse("step", {"id": "config", "status": "running", "message": "Configurando proxy e interface..."})
            
            for line in process.stdout:
                # Basic parsing to show activity
                pass
            
            process.wait()
            
            if process.returncode == 0:
                send_sse("step", {"id": "config", "status": "done", "message": "Configurado com sucesso."})
                send_sse("step", {"id": "install", "status": "done", "message": "Instalado no sistema."})
                send_sse("step", {"id": "start", "status": "done", "message": "Serviços iniciados."})
                send_sse("complete", {"installDir": "/etc/shadowsocks"})
            else:
                send_sse("error", {"message": f"Erro durante a instalação. Código: {process.returncode}"})

        except Exception as e:
            send_sse("error", {"message": str(e)})

    def handle_cancel(self):
        try:
            res = subprocess.run([TEARDOWN_SH], capture_output=True, text=True)
            if res.returncode == 0:
                self.send_json({"success": True, "message": "Proxy desinstalada com sucesso"})
            else:
                self.send_json({"success": False, "message": f"Erro na desinstalação: {res.stderr}"}, 500)
        except Exception as e:
            self.send_json({"success": False, "message": str(e)}, 500)

    def handle_monitor(self):
        self.send_json({"success": True})

    def handle_test(self):
        content_len = int(self.headers.get('Content-Length', 0))
        data = json.loads(self.rfile.read(content_len))
        
        ip = data.get("ip")
        port = data.get("port")

        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(3.0)
            s.connect((ip, int(port)))
            s.close()
            self.send_json({"success": True, "message": "Conectado com sucesso!"})
        except Exception as e:
            self.send_json({"success": False, "message": f"Falha ao conectar: {str(e)}"})

    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

if __name__ == '__main__':
    # Ensure root
    if os.geteuid() != 0:
        print("Este servidor precisa ser executado como root (sudo).")
        exit(1)
        
    server = HTTPServer(('127.0.0.1', PORT), ProxyUIHandler)
    print(f"Interface web rodando em http://localhost:{PORT}/")
    print("O navegador abrirá automaticamente.")
    print("Feche esta janela ou pressione Ctrl+C para encerrar.")
    
    # Try to open browser
    try:
        # Run as original user to avoid running browser as root
        user = os.environ.get("SUDO_USER")
        if user:
            subprocess.Popen(["sudo", "-u", user, "xdg-open", f"http://localhost:{PORT}/"], 
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.Popen(["xdg-open", f"http://localhost:{PORT}/"], 
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except:
        pass
        
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
