#Requires -Version 5.1
<#
    instalar-singbox-discord.ps1
    ------------------------------------------------------------
    1. Baixa a versao mais recente do sing-box (Windows amd64)
    2. Le o .\config.json que voce preparou (TUN + regra: so o Discord
       sai pela proxy) e pergunta IP / porta / senha do Shadowsocks
    3. Altera o config.json com esses dados (e habilita a Clash API
       em 127.0.0.1 so para os testes)
    4. Instala em C:\Program Files\sing-box e registra uma tarefa
       agendada para iniciar junto com o Windows (como SYSTEM)
    5. Valida ("importa") o config, inicia o sing-box
    6. Testa:
         a) conexao local da maquina (IP normal, saida direta)
         b) saida pela proxy: TCP no servidor + IP publico via socks local
         c) se o Discord esta saindo pela TUN criada pelo sing-box
    ------------------------------------------------------------
    Execute em um PowerShell como Administrador:
        Set-ExecutionPolicy Bypass -Scope Process -Force
        .\instalar-singbox-discord.ps1

    Modos de monitoramento (nao instalam nada, nao precisam de admin):
        .\instalar-singbox-discord.ps1 -Monitor   # trafego + status da rede ao vivo
        .\instalar-singbox-discord.ps1 -Logs      # log do sing-box continuo e legivel
    Ctrl+C ou fechar a janela encerra.
#>

[CmdletBinding()]
param(
    [string]$ConfigFile = "",                    # padrao: .\config.json ao lado do script
    [string]$InstallDir = "$env:ProgramFiles\sing-box",
    [string]$TaskName   = "sing-box",
    [int]$ClashApiPort  = 9090,
    [switch]$SkipDownload,
    [switch]$Monitor,       # so monitora: trafego + status da rede, ate fechar a janela (Ctrl+C)
    [switch]$Logs           # so monitora: log do sing-box em tempo real, formatado
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- utilitarios
function Write-Step  ($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok    ($msg) { Write-Host "    [OK]    $msg" -ForegroundColor Green }
function Write-Warn2 ($msg) { Write-Host "    [AVISO] $msg" -ForegroundColor Yellow }
function Write-Fail  ($msg) { Write-Host "    [FALHA] $msg" -ForegroundColor Red }

function Get-PublicIp {
    param([string]$SocksProxy)   # ex: 127.0.0.1:1080  (opcional)
    $urls = @("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com")
    foreach ($u in $urls) {
        try {
            if ($SocksProxy) {
                $r = & curl.exe -s --max-time 10 --proxy "socks5h://$SocksProxy" $u 2>$null
            } else {
                $r = & curl.exe -s --max-time 10 $u 2>$null
            }
            if ($r -and $r.Trim() -match '^\d{1,3}(\.\d{1,3}){3}$') { return $r.Trim() }
        } catch { }
    }
    return $null
}


function Format-Bytes ([double]$b) {
    if ($b -ge 1GB) { return "{0:N2} GB" -f ($b / 1GB) }
    if ($b -ge 1MB) { return "{0:N2} MB" -f ($b / 1MB) }
    if ($b -ge 1KB) { return "{0:N1} KB" -f ($b / 1KB) }
    return "{0:N0} B" -f $b
}
function Format-Rate ([double]$bps) { return (Format-Bytes $bps) + "/s" }

# Le config.json instalado para descobrir porta da Clash API, tag da proxy e nome da TUN
function Get-InstalledConfigInfo {
    $info = @{ ClashApiPort = $ClashApiPort; ProxyTag = "shadowsocks-out"; TunName = "singbox-tun"; LogPath = (Join-Path $InstallDir "sing-box.log") }
    $cfgPath = Join-Path $InstallDir "config.json"
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $ec = $cfg.experimental.clash_api.external_controller
            if ($ec) { $info.ClashApiPort = [int](($ec -split ":")[-1]) }
            $ss = @($cfg.outbounds | Where-Object { $_.type -eq "shadowsocks" }) | Select-Object -First 1
            if ($ss) { $info.ProxyTag = $ss.tag }
            $tun = @($cfg.inbounds | Where-Object { $_.type -eq "tun" }) | Select-Object -First 1
            if ($tun -and $tun.interface_name) { $info.TunName = $tun.interface_name }
            if ($cfg.log.output) {
                $info.LogPath = if ([IO.Path]::IsPathRooted($cfg.log.output)) { $cfg.log.output } else { Join-Path $InstallDir $cfg.log.output }
            }
        } catch { }
    }
    return $info
}

# ---------------------------------------------------------------- modo -Monitor
function Start-TrafficMonitor {
    $info = Get-InstalledConfigInfo
    $api  = "http://127.0.0.1:$($info.ClashApiPort)"
    $prevUp = $null; $prevDown = $null; $prevTime = $null
    $prevConn = @{}     # id -> @{u; d}
    $startedAt = Get-Date

    while ($true) {
        $now = Get-Date
        $sb = New-Object Text.StringBuilder
        [void]$sb.AppendLine("  sing-box MONITOR   $($now.ToString('dd/MM/yyyy HH:mm:ss'))   (Ctrl+C para sair)")
        [void]$sb.AppendLine("  " + ("=" * 90))

        # --- status do processo / tarefa
        $proc = Get-Process sing-box -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $up = $now - $proc.StartTime
            [void]$sb.AppendLine(("  sing-box   : RODANDO  PID {0}  ha {1:d\.hh\:mm\:ss}  RAM {2}" -f $proc.Id, $up, (Format-Bytes $proc.WorkingSet64)))
        } else {
            [void]$sb.AppendLine("  sing-box   : PARADO")
        }
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) { [void]$sb.AppendLine("  tarefa     : $($task.State)") }

        # --- rede
        $tun = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $info.TunName -or $_.InterfaceDescription -like "*Wintun*" } | Select-Object -First 1
        if ($tun) { [void]$sb.AppendLine("  TUN        : '$($tun.Name)' $($tun.Status)  ($($tun.InterfaceDescription))") }
        else      { [void]$sb.AppendLine("  TUN        : ausente") }

        $defRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Sort-Object RouteMetric
        foreach ($r in $defRoutes | Select-Object -First 3) {
            [void]$sb.AppendLine(("  rota 0/0   : via {0,-16} em '{1}' (metrica {2})" -f $r.NextHop, $r.InterfaceAlias, $r.RouteMetric))
        }
        $phys = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq "Up" | Select-Object -First 1
        if ($phys) {
            $ip4 = (Get-NetIPAddress -InterfaceIndex $phys.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
            [void]$sb.AppendLine("  fisica     : '$($phys.Name)' $ip4  $($phys.LinkSpeed)")
        }

        # --- clash api
        $apiOk = $false
        try {
            $data = Invoke-RestMethod "$api/connections" -TimeoutSec 2
            $apiOk = $true
        } catch { }

        if (-not $apiOk) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("  Clash API  : sem resposta em $api (sing-box parado ou clash_api desativada)")
        } else {
            $conns = @($data.connections)
            $rateUp = 0; $rateDown = 0
            if ($prevTime) {
                $dt = ($now - $prevTime).TotalSeconds
                if ($dt -gt 0) {
                    $rateUp   = [math]::Max(0, ($data.uploadTotal   - $prevUp)   / $dt)
                    $rateDown = [math]::Max(0, ($data.downloadTotal - $prevDown) / $dt)
                }
            }
            $prevUp = $data.uploadTotal; $prevDown = $data.downloadTotal; $prevTime = $now

            $nProxy  = @($conns | Where-Object { $_.chains -contains $info.ProxyTag }).Count
            $nDirect = $conns.Count - $nProxy
            $nDiscord = @($conns | Where-Object { $_.metadata.processPath -like "*discord*" }).Count

            [void]$sb.AppendLine("")
            [void]$sb.AppendLine(("  TRAFEGO    : up {0,-14} down {1,-14} total up {2}  down {3}" -f (Format-Rate $rateUp), (Format-Rate $rateDown), (Format-Bytes $data.uploadTotal), (Format-Bytes $data.downloadTotal)))
            [void]$sb.AppendLine(("  CONEXOES   : {0} ativas   via proxy '{1}': {2}   direto: {3}   Discord: {4}" -f $conns.Count, $info.ProxyTag, $nProxy, $nDirect, $nDiscord))
            [void]$sb.AppendLine("  " + ("-" * 90))
            [void]$sb.AppendLine(("  {0,-18} {1,-4} {2,-34} {3,-16} {4,10} {5,10}" -f "PROCESSO", "PROT", "DESTINO", "SAIDA", "UP/s", "DOWN/s"))

            $newConn = @{}
            $rows = foreach ($c in $conns) {
                $m = $c.metadata
                $pname = if ($m.processPath) { [IO.Path]::GetFileName($m.processPath) } elseif ($m.process) { $m.process } else { "?" }
                $dest = if ($m.host) { $m.host } else { $m.destinationIP }
                $dest = "$dest`:$($m.destinationPort)"
                $cu = 0; $cd = 0
                if ($prevConn.ContainsKey($c.id) -and $dt -gt 0) {
                    $cu = [math]::Max(0, ($c.upload   - $prevConn[$c.id].u) / $dt)
                    $cd = [math]::Max(0, ($c.download - $prevConn[$c.id].d) / $dt)
                }
                $newConn[$c.id] = @{ u = $c.upload; d = $c.download }
                [pscustomobject]@{
                    Proc = $pname; Net = $m.network; Dest = $dest
                    Chain = ($c.chains -join ">"); Up = $cu; Down = $cd
                    Total = $c.upload + $c.download
                    IsProxy = ($c.chains -contains $info.ProxyTag)
                }
            }
            $prevConn = $newConn

            $rows | Sort-Object -Property @{Expression = "IsProxy"; Descending = $true}, @{Expression = { $_.Up + $_.Down }; Descending = $true}, Total -Descending |
                Select-Object -First 25 | ForEach-Object {
                    $mark = if ($_.IsProxy) { "*" } else { " " }
                    $d = if ($_.Dest.Length -gt 34) { $_.Dest.Substring(0, 33) + "~" } else { $_.Dest }
                    $pn = if ($_.Proc.Length -gt 18) { $_.Proc.Substring(0, 17) + "~" } else { $_.Proc }
                    [void]$sb.AppendLine(("{0} {1,-18} {2,-4} {3,-34} {4,-16} {5,10} {6,10}" -f $mark, $pn, $_.Net, $d, $_.Chain, (Format-Rate $_.Up), (Format-Rate $_.Down)))
                }
            if ($conns.Count -gt 25) { [void]$sb.AppendLine("  ... e mais $($conns.Count - 25) conexoes") }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("  * = saindo pela proxy")
        }

        Clear-Host
        Write-Host $sb.ToString()
        Start-Sleep 2
    }
}

# ---------------------------------------------------------------- modo -Logs
function Start-LogMonitor {
    $info = Get-InstalledConfigInfo
    $log  = $info.LogPath
    if (-not (Test-Path $log)) {
        Write-Fail "Log nao encontrado: $log"
        Write-Host "      O sing-box grava log so se 'log.output' estiver no config (o instalador adiciona)."
        return
    }
    Write-Host "  Acompanhando $log   (Ctrl+C para sair)" -ForegroundColor Cyan
    Write-Host ""

    # formato do sing-box: [+0000] 2024-01-01 12:00:00 INFO [123456 0s] inbound/tun[tun-in]: mensagem
    $rx = '^(?:\+\d{4}\s+)?(?<date>\d{4}-\d{2}-\d{2})\s+(?<time>\d{2}:\d{2}:\d{2})\s+(?<lvl>[A-Z]+)\s+(?:\[(?<conn>\d+)\s+(?<dur>[^\]]+)\]\s+)?(?:(?<mod>[\w/\-]+(?:\[[^\]]*\])?):\s+)?(?<msg>.*)$'

    Get-Content $log -Tail 40 -Wait -Encoding UTF8 | ForEach-Object {
        $line = $_
        if ($line -notmatch $rx) { Write-Host "  $line" -ForegroundColor DarkGray; return }

        $lvl = $Matches.lvl; $mod = $Matches.mod; $msg = $Matches.msg; $time = $Matches.time
        $color = switch ($lvl) { "ERROR" { "Red" } "FATAL" { "Red" } "WARN" { "Yellow" } "INFO" { "Gray" } default { "DarkGray" } }

        # traducao dos eventos mais comuns
        $human = $msg
        $tag = ""
        if ($msg -match '^inbound (connection|packet connection) (from|to) (.+)$') {
            $what = if ($Matches[1] -like "packet*") { "UDP" } else { "TCP" }
            $human = "$what $($Matches[2] -replace 'from','de' -replace 'to','para') $($Matches[3])"
            $tag = "ENTRADA"
        }
        elseif ($msg -match '^outbound (connection|packet connection) to (.+)$') {
            $what = if ($Matches[1] -like "packet*") { "UDP" } else { "TCP" }
            $human = "$what para $($Matches[2])"
            $tag = "SAIDA"
        }
        elseif ($msg -match '^(?:sniffed|found) (?:protocol|process)') { $tag = "DETECT"; $color = "DarkCyan" }
        elseif ($msg -match 'match\[(\d+)\]\s*(.+)$') {
            $tag = "REGRA"
            $human = "regra #$($Matches[1]) casou: $($Matches[2])"
            $color = "Cyan"
        }
        elseif ($msg -match 'sing-box started') { $tag = "START"; $human = "sing-box iniciado ($msg)"; $color = "Green" }
        elseif ($msg -match 'started|listening') { $tag = "START"; $color = "Green" }
        elseif ($msg -match 'closed|stopped') { $tag = "STOP" }
        elseif ($msg -match 'dial|connect|refused|timeout|i/o timeout|EOF|reset by peer') { $tag = "ERRO-REDE"; if ($color -eq "Gray") { $color = "Yellow" } }

        # processo (quando o sniff/rota encontra) e outbound escolhido
        $extra = ""
        if ($mod -match '^outbound/(\w+)\[(.+)\]$') { $extra = " -> $($Matches[2])" }
        elseif ($mod -match '^inbound/(\w+)\[(.+)\]$') { $extra = " <- $($Matches[2])" }
        if ($msg -match 'process\s+(\S+\.exe)' ) { $extra += "  [$([IO.Path]::GetFileName($Matches[1]))]" }

        $prefix = "{0} {1,-5} {2,-9}" -f $time, $lvl, $tag
        Write-Host ("  $prefix " + $human + $extra) -ForegroundColor $color
    }
}

if ($Monitor) { Start-TrafficMonitor; exit 0 }
if ($Logs)    { Start-LogMonitor;     exit 0 }

# ---------------------------------------------------------------- 0. admin
Write-Step "Verificando privilegios"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn2 "Nao esta como administrador. Reabrindo com elevacao..."
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $args
    exit
}
Write-Ok "Rodando como administrador"

# Tudo abaixo roda dentro de try/finally: a janela so fecha depois de um ENTER,
# inclusive quando acontece um erro (senao a janela elevada some antes de dar para ler).
$exitCode = 0
try {

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "curl.exe nao encontrado (vem com o Windows 10 1803+). Necessario para os testes."
}

# ---------------------------------------------------------------- 1. download
# Pasta temporaria SEM nome curto 8.3 (ex.: C:\Users\JOS~1\...): Expand-Archive/ZipFile
# falham com esse formato, comum em usuarios cujo nome tem acento ou mais de 8 letras.
$tmp = Join-Path $env:ProgramData "sing-box-setup"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zipPath = Join-Path $tmp "sing-box.zip"

if (-not $SkipDownload) {
    Write-Step "Baixando a versao mais recente do sing-box"
    $arch = if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "windows-arm64" } else { "windows-amd64" }
    } else { "windows-386" }

    $release = Invoke-RestMethod "https://api.github.com/repos/SagerNet/sing-box/releases/latest" `
                -Headers @{ "User-Agent" = "singbox-installer" }
    $asset = $release.assets | Where-Object { $_.name -like "sing-box-*-$arch.zip" } | Select-Object -First 1
    if (-not $asset) { throw "Nao achei o asset $arch na release $($release.tag_name)" }

    Write-Host "    Versao: $($release.tag_name)  |  Arquivo: $($asset.name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
    Write-Ok "Download concluido"

    Write-Step "Extraindo"
    $extract = Join-Path $tmp "extract"
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extract)
    $exeSrc = Get-ChildItem $extract -Recurse -Filter "sing-box.exe" | Select-Object -First 1
    if (-not $exeSrc) { throw "sing-box.exe nao encontrado dentro do zip" }
    Write-Ok "sing-box.exe extraido"
}

# ---------------------------------------------------------------- 2. config preparado + dados da proxy
Write-Step "Carregando o config.json preparado"
$scriptDir = Split-Path -Parent $PSCommandPath
if (-not $ConfigFile) {
    foreach ($cand in @("config.json")) {
        $c = Join-Path $scriptDir $cand
        if (Test-Path $c) { $ConfigFile = $c; break }
    }
}
if (-not $ConfigFile -or -not (Test-Path $ConfigFile)) {
    throw "config.json nao encontrado. Coloque-o na mesma pasta do script (.\config.json) ou passe -ConfigFile <caminho>."
}
$ConfigFile = (Resolve-Path $ConfigFile).Path
Write-Ok "Usando $ConfigFile"

try {
    $config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "config.json invalido (JSON): $($_.Exception.Message)"
}

$ssOut = @($config.outbounds | Where-Object { $_.type -eq "shadowsocks" }) | Select-Object -First 1
if (-not $ssOut) { throw "Nenhum outbound do tipo 'shadowsocks' no config.json" }
$tunIn = @($config.inbounds | Where-Object { $_.type -eq "tun" }) | Select-Object -First 1
if (-not $tunIn) { throw "Nenhum inbound do tipo 'tun' no config.json" }
$proxyTag = $ssOut.tag
$tunName  = if ($tunIn.interface_name) { $tunIn.interface_name } else { "sing-box" }
$socksIn  = @($config.inbounds | Where-Object { $_.type -in @("mixed", "socks") }) | Select-Object -First 1
$SocksPort = if ($socksIn) { [int]$socksIn.listen_port } else { 0 }

Write-Host "    Outbound proxy : $proxyTag  (metodo: $($ssOut.method))"
Write-Host "    TUN            : $tunName"
if ($SocksPort) { Write-Host "    Socks local    : 127.0.0.1:$SocksPort  (inbound $($socksIn.tag))" }

Write-Step "Dados da proxy Shadowsocks"
# valores "__X__" no config sao placeholders: o cliente e obrigado a informar
$curIp   = [string]$ssOut.server
$curPass = [string]$ssOut.password
if ($curIp   -like "__*__") { $curIp   = "" }
if ($curPass -like "__*__") { $curPass = "" }

do {
    $ipIn = if ($curIp) { Read-Host "  IP/host do servidor [$curIp]" } else { Read-Host "  IP/host do servidor" }
    $proxyIp = if ($ipIn.Trim()) { $ipIn.Trim() } else { $curIp }
} while (-not $proxyIp)

$portIn = Read-Host "  Porta [$($ssOut.server_port)]"
$proxyPort = if ($portIn.Trim()) { [int]$portIn } else { [int]$ssOut.server_port }

do {
    $label = if ($curPass) { "  Senha [ENTER mantem a do arquivo]" } else { "  Senha" }
    $sec = Read-Host $label -AsSecureString
    $proxyPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if (-not $proxyPass) { $proxyPass = $curPass }
} while (-not $proxyPass)

# ---------------------------------------------------------------- 3. alterar config.json
Write-Step "Alterando config.json"
$ssOut.server      = $proxyIp
$ssOut.server_port = $proxyPort
$ssOut.password    = $proxyPass

# Clash API em localhost: usada pelo TESTE 3 para ver as conexoes do Discord.
# Se o seu config ja tiver experimental.clash_api, ele e respeitado.
if (-not $config.PSObject.Properties["experimental"]) {
    $config | Add-Member -NotePropertyName experimental -NotePropertyValue ([pscustomobject]@{})
}
if (-not $config.experimental.PSObject.Properties["clash_api"]) {
    $config.experimental | Add-Member -NotePropertyName clash_api `
        -NotePropertyValue ([pscustomobject]@{ external_controller = "127.0.0.1:$ClashApiPort" })
} else {
    $ClashApiPort = [int](($config.experimental.clash_api.external_controller -split ":")[-1])
}

# Log em arquivo (o sing-box roda escondido pela tarefa agendada; sem isso nao ha como ver erros)
if (-not $config.PSObject.Properties["log"]) {
    $config | Add-Member -NotePropertyName log -NotePropertyValue ([pscustomobject]@{ level = "info"; timestamp = $true; output = "sing-box.log" })
} elseif (-not $config.log.PSObject.Properties["output"]) {
    $config.log | Add-Member -NotePropertyName output -NotePropertyValue "sing-box.log"
}

$configJson = $config | ConvertTo-Json -Depth 20
$configTmp  = Join-Path $tmp "config.json"
[IO.File]::WriteAllText($configTmp, $configJson, (New-Object Text.UTF8Encoding($false)))
Write-Ok "config.json alterado: server=$proxyIp porta=$proxyPort (senha oculta)"

# ---------------------------------------------------------------- 4. instalar
Write-Step "Instalando em $InstallDir"

# para tarefa/processo anterior, se existir
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 1

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$exePath    = Join-Path $InstallDir "sing-box.exe"
$configPath = Join-Path $InstallDir "config.json"

if (-not $SkipDownload) { Copy-Item $exeSrc.FullName $exePath -Force }
if (-not (Test-Path $exePath)) { throw "sing-box.exe nao esta em $InstallDir (rode sem -SkipDownload)" }

# "importar" o config: valida antes de copiar para a pasta de instalacao
Write-Step "Validando e importando config.json"
$check = & $exePath check -c $configTmp 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "config.json invalido:"
    $check | ForEach-Object { Write-Host "      $_" }
    throw "Corrija o config e rode de novo."
}
Copy-Item $configTmp $configPath -Force
Write-Ok "config.json importado para $configPath"

# tarefa agendada: inicia no boot como SYSTEM (necessario para criar a TUN)
Write-Step "Registrando tarefa agendada '$TaskName' (inicia com o Windows)"
$action    = New-ScheduledTaskAction -Execute $exePath -Argument "run -c `"$configPath`"" -WorkingDirectory $InstallDir
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Force | Out-Null
Write-Ok "Tarefa registrada"

# ---------------------------------------------------------------- 5. iniciar
Write-Step "Iniciando o sing-box"
Start-ScheduledTask -TaskName $TaskName

$started = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Get-Process sing-box -ErrorAction SilentlyContinue) {
        try {
            Invoke-RestMethod "http://127.0.0.1:$ClashApiPort/version" -TimeoutSec 2 | Out-Null
            $started = $true; break
        } catch { }
    }
}
if (-not $started) {
    Write-Fail "sing-box nao subiu. Veja o log: $InstallDir\sing-box.log"
    Get-Content "$InstallDir\sing-box.log" -Tail 20 -ErrorAction SilentlyContinue
    throw "sing-box nao iniciou"
}
Write-Ok "sing-box em execucao (PID $((Get-Process sing-box).Id -join ','))"

# ---------------------------------------------------------------- 5b. reset do Discord
# Se o Discord ja estava aberto, ele tem conexoes antigas feitas antes da TUN existir.
# Reinicia para que todas as conexoes novas passem pelo sing-box.
Write-Step "Reset do Discord"
$discordRunning = Get-Process | Where-Object { $_.ProcessName -like "Discord*" }
if ($discordRunning) {
    $discordExe = $null
    try { $discordExe = ($discordRunning | Where-Object { $_.Path } | Select-Object -First 1).Path } catch { }
    if (-not $discordExe) {
        $upd = Join-Path $env:LOCALAPPDATA "Discord\Update.exe"
        if (Test-Path $upd) { $discordExe = $upd }
    }

    Write-Host "    Fechando Discord ($($discordRunning.Count) processo(s))..."
    $discordRunning | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 3

    if ($discordExe) {
        # explorer.exe lanca o processo SEM elevacao (o script roda como admin)
        if ($discordExe -like "*Update.exe") {
            Start-Process $discordExe -ArgumentList "--processStart Discord.exe"
        } else {
            Start-Process explorer.exe -ArgumentList "`"$discordExe`""
        }
        Start-Sleep 5
        if (Get-Process | Where-Object { $_.ProcessName -like "Discord*" }) {
            Write-Ok "Discord reiniciado"
        } else {
            Write-Warn2 "Discord foi fechado mas nao reabriu sozinho - abra manualmente"
        }
    } else {
        Write-Warn2 "Discord fechado, mas nao achei o executavel para reabrir - abra manualmente"
    }
} else {
    Write-Host "    Discord nao estava em execucao - nada a reiniciar"
}

# ---------------------------------------------------------------- 6. testes
Write-Step "TESTE 1 - Conexao local da maquina (saida direta, IP normal)"
$tunAdapter = Get-NetAdapter | Where-Object { $_.Name -eq $tunName -or $_.InterfaceDescription -like "*sing-box*" -or $_.InterfaceDescription -like "*Wintun*" } | Select-Object -First 1
if ($tunAdapter) { Write-Ok "Adaptador TUN encontrado: '$($tunAdapter.Name)' ($($tunAdapter.Status))" }
else             { Write-Warn2 "Adaptador TUN nao encontrado no Get-NetAdapter" }

$ping = Test-NetConnection -ComputerName 1.1.1.1 -InformationLevel Quiet -WarningAction SilentlyContinue
if ($ping) { Write-Ok "Ping para 1.1.1.1 respondeu" } else { Write-Warn2 "Ping para 1.1.1.1 falhou" }

$ipLocal = Get-PublicIp
if ($ipLocal) { Write-Ok "IP publico (saida direta): $ipLocal" }
else          { Write-Fail "Nao consegui obter o IP publico pela saida direta" }

Write-Step "TESTE 2 - Saida pela proxy Shadowsocks ($proxyIp`:$proxyPort)"
$ssReach = Test-NetConnection -ComputerName $proxyIp -Port $proxyPort -InformationLevel Quiet -WarningAction SilentlyContinue
if ($ssReach) { Write-Ok "Servidor aceita conexao TCP em $proxyIp`:$proxyPort" }
else          { Write-Fail "Nao consegui conectar em $proxyIp`:$proxyPort - confira IP/porta/firewall do servidor" }

$ipProxy = $null
if ($SocksPort) {
    # curl -> socks local do sing-box -> regra inbound proxy-in -> shadowsocks-out
    $ipProxy = Get-PublicIp -SocksProxy "127.0.0.1:$SocksPort"
    if ($ipProxy) {
        Write-Ok "IP publico pela proxy: $ipProxy"
        if ($ipLocal -and $ipProxy -eq $ipLocal) {
            Write-Warn2 "IP pela proxy e igual ao IP local - a regra 'inbound proxy-in -> $proxyTag' pode nao estar no config"
        } else {
            Write-Ok "IP diferente do local: senha, metodo e roteamento do Shadowsocks OK"
        }
    } else {
        Write-Fail "Sem resposta pela proxy (127.0.0.1:$SocksPort). Servidor responde TCP mas nao passa dados:"
        Write-Host "      quase sempre senha ou metodo errados. Veja $InstallDir\sing-box.log"
    }
} else {
    Write-Warn2 "Config sem inbound mixed/socks - nao da para testar o IP de saida pela proxy"
}

Write-Step "TESTE 3 - Discord saindo pela TUN do sing-box"
$discordProc = Get-Process | Where-Object { $_.ProcessName -like "Discord*" }
if (-not $discordProc) {
    Write-Warn2 "Discord nao esta aberto. Abra o Discord agora (e entre em um canal de voz, se possivel)."
    Read-Host "  Pressione ENTER quando o Discord estiver aberto" | Out-Null
}

$found = $null
for ($i = 0; $i -lt 45 -and -not $found; $i++) {
    Start-Sleep 1
    try {
        $conns = (Invoke-RestMethod "http://127.0.0.1:$ClashApiPort/connections" -TimeoutSec 3).connections
        $found = $conns | Where-Object {
            ($_.metadata.processPath -like "*discord*") -or ($_.metadata.process -like "*discord*")
        }
    } catch { }
    if (-not $found -and ($i % 5) -eq 4) { Write-Host "    aguardando conexoes do Discord... ($($i+1)s)" }
}

if (-not $found) {
    Write-Fail "Nenhuma conexao do Discord passou pelo sing-box em 45s."
    Write-Host "      Verifique se o Discord esta aberto e se a TUN esta ativa (Get-NetAdapter)."
} else {
    $viaProxy  = @($found | Where-Object { $_.chains -contains $proxyTag })
    $viaDirect = @($found | Where-Object { $_.chains -notcontains $proxyTag })

    Write-Host "    Conexoes do Discord vistas pela TUN ($($found.Count)):"
    $found | Select-Object -First 8 | ForEach-Object {
        $m = $_.metadata
        $dest = if ($m.host) { $m.host } else { $m.destinationIP }
        Write-Host ("      {0,-4} {1,-12} {2,-40} -> {3}" -f $m.network, $m.type, "$dest`:$($m.destinationPort)", ($_.chains -join " > "))
    }

    if ($viaProxy.Count -gt 0 -and $viaDirect.Count -eq 0) {
        Write-Ok "Discord esta saindo pela TUN '$tunName' (inbound $($tunIn.tag)) e pelo outbound '$proxyTag'"
    } elseif ($viaProxy.Count -gt 0) {
        Write-Warn2 "Discord esta na TUN, mas $($viaDirect.Count) conexao(oes) sairam direto (provavelmente DNS ou processo nao casado pela regra)"
    } else {
        Write-Fail "Discord passa pela TUN mas NAO esta saindo por '$proxyTag' - a regra de process_name nao casou. Nomes vistos:"
        $found | ForEach-Object { $_.metadata.processPath } | Sort-Object -Unique | ForEach-Object { Write-Host "      $_" }
    }
}

# ---------------------------------------------------------------- resumo
Write-Host ""
Write-Host "================ RESUMO ================" -ForegroundColor Cyan
Write-Host " Instalado em : $InstallDir"
Write-Host " Config       : $configPath"
Write-Host " Log          : $InstallDir\sing-box.log"
Write-Host " Tarefa       : $TaskName  (schtasks /run /tn $TaskName | schtasks /end /tn $TaskName)"
Write-Host " Clash API    : http://127.0.0.1:$ClashApiPort  (GET /connections mostra o trafego)"
Write-Host " Config origem: $ConfigFile"
Write-Host " Proxy        : $proxyIp`:$proxyPort  (outbound '$proxyTag')"
Write-Host " Socks local  : $(if ($SocksPort) { "127.0.0.1:$SocksPort  (aponte um app aqui para forcar pela proxy)" } else { "-" })"
Write-Host " IP direto    : $ipLocal"
Write-Host " IP via proxy : $(if ($ipProxy) { $ipProxy } else { "-" })"
Write-Host " Monitorar    : .\$(Split-Path -Leaf $PSCommandPath) -Monitor   (trafego/rede)"
Write-Host " Logs         : .\$(Split-Path -Leaf $PSCommandPath) -Logs      (log continuo)"
Write-Host "========================================" -ForegroundColor Cyan
} catch {
    Write-Host ""
    Write-Fail "ERRO: $($_.Exception.Message)"
    if ($_.InvocationInfo.ScriptLineNumber) { Write-Host "      (linha $($_.InvocationInfo.ScriptLineNumber))" }
    $exitCode = 1
} finally {
    Write-Host ""
    Read-Host "Pressione ENTER para sair" | Out-Null
}
exit $exitCode