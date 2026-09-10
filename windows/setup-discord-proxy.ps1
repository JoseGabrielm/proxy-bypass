<#
    setup-discord-proxy.ps1

    Configura o Discord para passar por um proxy SOCKS5 (Shadowsocks) rodando
    numa VPS, cobrindo texto/API (Shadowsocks-Windows) e voz/video/screen share
    (SocksCap64 forcando o processo Discord.exe pelo mesmo proxy).

    COMO USAR:
      1. Edite as variaveis na secao CONFIGURACAO abaixo.
      2. Clique com o botao direito neste arquivo -> "Executar com o PowerShell"
         (ou abra um PowerShell como Administrador e rode:
          powershell -ExecutionPolicy Bypass -File setup-discord-proxy.ps1)

    O QUE ESTE SCRIPT FAZ AUTOMATICAMENTE:
      - Baixa e configura o Shadowsocks-Windows (cliente SOCKS5 local).
      - Baixa o instalador do SocksCap64 e abre para voce concluir (poucos cliques).
      - Testa a conexao no final.

    O QUE VOCE AINDA PRECISA FAZER NA MAO (a UI de terceiros nao da pra automatizar
    com seguranca sem testar numa maquina real):
      - Terminar o instalador do SocksCap64 (Next/Next/Finish).
      - Dentro do SocksCap64: adicionar o proxy 127.0.0.1:1080 (SOCKS5) e criar
        uma regra para o Discord.exe usar esse proxy. O script mostra o passo
        a passo exato na tela quando chegar nessa etapa.
#>

# ============================ CONFIGURACAO ============================
$ServerIP       = "2.25.217.51"
$ServerPort     = 8388
$ServerPassword = "SENHA_UNICA_AQUI"
$Method         = "chacha20-ietf-poly1305"
$LocalSocksPort = 1080
# ========================================================================

$ErrorActionPreference = "Stop"

$ShadowsocksZipUrl   = "https://github.com/shadowsocks/shadowsocks-windows/releases/download/4.4.1.0/Shadowsocks-4.4.1.0.zip"
$SocksCap64InstallUrl = "https://github.com/bobo2334/sockscap64/releases/download/4.7/SocksCap64-setup-4.7.exe"

$WorkDir         = "C:\ProgramData\DiscordProxySetup"
$ShadowsocksDir  = "C:\ProgramData\ShadowsocksClient"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}
function Write-Ok($msg) {
    Write-Host "    [OK] $msg" -ForegroundColor Green
}
function Write-Warn($msg) {
    Write-Host "    [ATENCAO] $msg" -ForegroundColor Yellow
}
function Write-Fail($msg) {
    Write-Host "    [ERRO] $msg" -ForegroundColor Red
}

# ------------------------------------------------------------------------
# 1. Checar / forcar execucao como Administrador
# ------------------------------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Este script precisa ser executado como Administrador. Reabrindo elevado..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

if ($ServerPassword -eq "SENHA_UNICA_AQUI") {
    Write-Fail "Edite a variavel `$ServerPassword` no topo do script antes de rodar."
    Read-Host "Pressione Enter para sair"
    exit 1
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

# ------------------------------------------------------------------------
# 2. Baixar e configurar o Shadowsocks-Windows
# ------------------------------------------------------------------------
Write-Step "Baixando o Shadowsocks-Windows..."
$ssZipPath = Join-Path $WorkDir "shadowsocks-windows.zip"
try {
    Invoke-WebRequest -Uri $ShadowsocksZipUrl -OutFile $ssZipPath -UseBasicParsing
    Write-Ok "Download concluido."
} catch {
    Write-Fail "Nao consegui baixar o Shadowsocks-Windows: $_"
    Read-Host "Pressione Enter para sair"
    exit 1
}

Write-Step "Extraindo para $ShadowsocksDir ..."
New-Item -ItemType Directory -Force -Path $ShadowsocksDir | Out-Null
Expand-Archive -Path $ssZipPath -DestinationPath $ShadowsocksDir -Force
Write-Ok "Extraido."

# O Shadowsocks-Windows le o "gui-config.json" na mesma pasta do executavel
# quando esta rodando em modo portable (sem instalador). Escrevemos a config
# ja preenchida para nao precisar digitar nada na interface.
Write-Step "Gravando configuracao do servidor..."
$guiConfig = @{
    configs = @(
        @{
            server      = $ServerIP
            server_port = $ServerPort
            password    = $ServerPassword
            method      = $Method
            remarks     = "MeuProxy"
            timeout     = 300
        }
    )
    strategy               = $null
    index                  = 0
    global                 = $false
    enabled                = $true
    shareOverLan           = $false
    isDefault              = $false
    localPort              = $LocalSocksPort
    portableMode           = $true
    pacUrl                 = $null
    useOnlinePac           = $false
    availabilityStatistics = $false
    autoCheckUpdate        = $false
    isVerboseLogging       = $false
} | ConvertTo-Json -Depth 5

$guiConfigPath = Join-Path $ShadowsocksDir "gui-config.json"
Set-Content -Path $guiConfigPath -Value $guiConfig -Encoding UTF8
Write-Ok "Config gravada em $guiConfigPath"
Write-Warn "Se o Shadowsocks abrir sem o servidor configurado, adicione manualmente: Servers > Edit Servers, usando os dados do topo deste script."

# Atalho na pasta de Inicializacao (inicia junto com o Windows)
Write-Step "Criando atalho de inicializacao automatica..."
$startupFolder = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupFolder "Shadowsocks.lnk"
$wshShell = New-Object -ComObject WScript.Shell
$shortcut = $wshShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $ShadowsocksDir "Shadowsocks.exe"
$shortcut.WorkingDirectory = $ShadowsocksDir
$shortcut.Save()
Write-Ok "Atalho criado em: $shortcutPath"

Write-Step "Iniciando o Shadowsocks..."
Start-Process -FilePath (Join-Path $ShadowsocksDir "Shadowsocks.exe") -WorkingDirectory $ShadowsocksDir
Write-Ok "Shadowsocks iniciado (procure o icone na bandeja do sistema, perto do relogio)."
Start-Sleep -Seconds 5

# ------------------------------------------------------------------------
# 3. Baixar e abrir o instalador do SocksCap64
# ------------------------------------------------------------------------
Write-Step "Baixando o instalador do SocksCap64..."
$sockscapInstaller = Join-Path $WorkDir "SocksCap64-setup.exe"
try {
    Invoke-WebRequest -Uri $SocksCap64InstallUrl -OutFile $sockscapInstaller -UseBasicParsing
    Write-Ok "Download concluido."
} catch {
    Write-Fail "Nao consegui baixar o SocksCap64: $_"
    Read-Host "Pressione Enter para sair"
    exit 1
}

Write-Step "Abrindo o instalador do SocksCap64..."
Write-Warn "Uma janela de instalacao vai abrir. Clique em Next / Next / Install / Finish com as opcoes padrao."
Start-Process -FilePath $sockscapInstaller -Wait

Write-Host ""
Write-Host "=====================================================================" -ForegroundColor Magenta
Write-Host " CONFIGURACAO MANUAL NECESSARIA (leva menos de 1 minuto)" -ForegroundColor Magenta
Write-Host "=====================================================================" -ForegroundColor Magenta
Write-Host " 1. Abra o SocksCap64 (deve ter aberto sozinho, ou procure no Menu Iniciar)."
Write-Host " 2. Va em 'Proxy' (ou 'Settings') e adicione um proxy:"
Write-Host "      Tipo:  SOCKS5"
Write-Host "      Host:  127.0.0.1"
Write-Host "      Porta: $LocalSocksPort"
Write-Host " 3. Va na lista de aplicativos/regras e adicione o 'Discord.exe'"
Write-Host "    (geralmente em C:\Users\<voce>\AppData\Local\Discord\app-*\Discord.exe)"
Write-Host "    apontando para o proxy que voce acabou de criar."
Write-Host " 4. Salve/ative a regra."
Write-Host " 5. Fecheee o Discord COMPLETAMENTE pela bandeja do sistema (botao direito"
Write-Host "    no icone > Quit Discord) e abra de novo."
Write-Host "=====================================================================" -ForegroundColor Magenta
Read-Host "Depois de concluir os passos acima, pressione Enter para testar a conexao"

# ------------------------------------------------------------------------
# 4. Teste de conectividade
# ------------------------------------------------------------------------
Write-Step "Testando a conexao via proxy local..."
$curlExe = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curlExe) {
    Write-Warn "curl.exe nao encontrado (raro em Windows 10/11 atualizados). Pulei o teste automatico."
    Write-Warn "Teste manualmente abrindo https://ifconfig.me com o Discord/navegador usando o proxy."
} else {
    try {
        $result = & curl.exe -s --max-time 10 -x "socks5h://127.0.0.1:$LocalSocksPort" https://ifconfig.me
        if ($result -eq $ServerIP) {
            Write-Ok "Sucesso! Saida confirmada pelo IP da VPS: $result"
        } else {
            Write-Fail "A saida foi '$result', esperado '$ServerIP'."
            Write-Warn "Verifique se o Shadowsocks esta rodando (icone na bandeja) e se a senha/porta estao corretas."
        }
    } catch {
        Write-Fail "Nao consegui testar a conexao: $_"
    }
}

Write-Host ""
Write-Host "Setup finalizado. A partir de agora, o Discord (texto, API, voz, video e" -ForegroundColor Cyan
Write-Host "compartilhamento de tela) deve sair pela VPS, contanto que o Shadowsocks" -ForegroundColor Cyan
Write-Host "e a regra do SocksCap64 estejam ativos." -ForegroundColor Cyan
Read-Host "Pressione Enter para fechar"
