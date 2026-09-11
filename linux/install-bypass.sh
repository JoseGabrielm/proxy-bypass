#!/usr/bin/env bash
cd "$(dirname "$0")"

if ! command -v python3 &> /dev/null; then
    echo "Python 3 é necessário para iniciar a interface. Por favor, instale-o."
    exit 1
fi

echo "Iniciando painel de controle (requer permissão de root para configurar a rede)..."
sudo python3 ui-server.py
