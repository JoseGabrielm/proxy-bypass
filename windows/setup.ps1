#Requires -Version 5.1
<#
    instalar-singbox-discord.ps1
    ------------------------------------------------------------
    1. Baixa o sing-box (versao travada no script, so baixa se ainda
       nao existir sing-box.exe instalado em C:\Program Files\sing-box)
    2. Le o .\config.json que voce preparou (TUN + regra: so o Discord
       sai pela proxy) e abre uma pagina no navegador padrao para
       informar IP / porta / senha do Shadowsocks (a pagina testa a
       conexao real com o servidor antes de aceitar os dados, sem
       tocar em nenhuma configuracao de rede do Windows)
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
    [string]$SingBoxVersion = "1.14.0",     # versao travada: so muda revisando este valor
    [switch]$ForceReinstall,                # baixa e sobrescreve mesmo se ja houver sing-box.exe instalado
    [switch]$SkipDownload,                  # nao baixa nada; usa o exe ja instalado (falha se nao existir)
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
    param([string]$SocksProxy, [int]$TimeoutSec = 10)   # ex: 127.0.0.1:1080  (opcional)
    $urls = @("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com")
    foreach ($u in $urls) {
        try {
            if ($SocksProxy) {
                $r = & curl.exe -s --max-time $TimeoutSec --proxy "socks5h://$SocksProxy" $u 2>$null
            } else {
                $r = & curl.exe -s --max-time $TimeoutSec $u 2>$null
            }
            if ($r -and $r.Trim() -match '^\d{1,3}(\.\d{1,3}){3}$') { return $r.Trim() }
        } catch { }
    }
    return $null
}

# Sobe uma instancia isolada do sing-box (sem TUN, sem tocar rede do Windows)
# so para validar se IP/porta/senha do Shadowsocks realmente conectam,
# ANTES de instalar/iniciar a tarefa com TUN em strict_route.
function Test-ShadowsocksConnection {
    param(
        [string]$ExePath,
        [string]$Method,
        [string]$Server,
        [int]$Port,
        [string]$Password,
        [string]$WorkDir
    )

    $testPort = 0
    foreach ($p in 18080..18090) {
        $probe = $null
        try {
            $probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p)
            $probe.Start()
            $testPort = $p
        } catch { }
        finally { if ($probe) { $probe.Stop() } }
        if ($testPort) { break }
    }
    if (-not $testPort) { return $false }

    $testConfig = [pscustomobject]@{
        outbounds = @([pscustomobject]@{
            type        = "shadowsocks"
            tag         = "ss-test"
            server      = $Server
            server_port = $Port
            method      = $Method
            password    = $Password
        })
        inbounds = @([pscustomobject]@{
            type        = "mixed"
            tag         = "test-in"
            listen      = "127.0.0.1"
            listen_port = $testPort
        })
        route = [pscustomobject]@{ final = "ss-test" }
    } | ConvertTo-Json -Depth 10

    $testConfigPath = Join-Path $WorkDir "test-config.json"
    [IO.File]::WriteAllText($testConfigPath, $testConfig, (New-Object Text.UTF8Encoding($false)))

    $proc = $null
    try {
        $proc = Start-Process -FilePath $ExePath -ArgumentList "run -c `"$testConfigPath`"" `
                    -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 800
        if ($proc.HasExited) { return $false }

        $ip = Get-PublicIp -SocksProxy "127.0.0.1:$testPort" -TimeoutSec 6
        return [bool]$ip
    } finally {
        if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item $testConfigPath -Force -ErrorAction SilentlyContinue
    }
}


function Format-Bytes ([double]$b) {
    if ($b -ge 1GB) { return "{0:N2} GB" -f ($b / 1GB) }
    if ($b -ge 1MB) { return "{0:N2} MB" -f ($b / 1MB) }
    if ($b -ge 1KB) { return "{0:N1} KB" -f ($b / 1KB) }
    return "{0:N0} B" -f $b
}
function Format-Rate ([double]$bps) { return (Format-Bytes $bps) + "/s" }

# Sobe um servidor HTTP local, abre uma pagina no navegador padrao pedindo
# IP/porta/senha do Shadowsocks (com validacao no navegador e no servidor,
# incluindo um teste real de conexao antes de aceitar os dados).
# e bloqueia ate receber os dados. Devolve @{ Ip; Port; Pass }.
function Get-ProxyCredentialsViaBrowser {
    param(
        [string]$CurrentIp,
        [int]$CurrentPort,
        [string]$CurrentPassword,   # usada so para testar a conexao quando o campo senha fica em branco
        [string]$ExePath,           # sing-box.exe usado para o teste isolado (sem TUN)
        [string]$Method,            # metodo Shadowsocks (ssOut.method)
        [string]$WorkDir            # pasta temporaria para o config de teste
    )

    $HasCurrentPassword = [bool]$CurrentPassword
    Add-Type -AssemblyName System.Web

    $listener = $null
    $usedPort = $null
    foreach ($p in 8765..8774) {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://127.0.0.1:$p/")
        try {
            $l.Start()
            $listener = $l
            $usedPort = $p
            break
        } catch { }
    }
    if (-not $listener) { throw "Nao consegui abrir um servidor local (portas 8765-8774 ocupadas)" }

    $passNote = if ($HasCurrentPassword) { " (deixe em branco para manter a atual)" } else { "" }
    $hasPassJs = if ($HasCurrentPassword) { "true" } else { "false" }

    $html = @"
<!DOCTYPE html>
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
    <input id="ip" name="ip" value="$CurrentIp" autocomplete="off">
  </label>
  <div class="err" id="errIp"></div>

  <label>Porta
    <input id="port" name="port" value="$CurrentPort" autocomplete="off">
  </label>
  <div class="err" id="errPort"></div>

  <label>Senha$passNote
    <input id="pass" name="pass" type="text" autocomplete="off">
  </label>
  <div class="err" id="errPass"></div>

  <div class="err" id="errGeneral" style="margin-top:12px"></div>
  <button type="submit" id="btn">Salvar e continuar</button>
</form>
<script>
var hasCurrentPass = $hasPassJs;
var form = document.getElementById('f');
var btn = document.getElementById('btn');

form.addEventListener('submit', function (e) {
  e.preventDefault();
  var ip = document.getElementById('ip').value.trim();
  var port = document.getElementById('port').value.trim();
  var pass = document.getElementById('pass').value.replace(/\s+/g, '');
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
      document.body.innerHTML = '<h2>Conectado! Pode fechar esta aba e voltar ao PowerShell.</h2>';
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
"@
    $htmlBytes = [Text.Encoding]::UTF8.GetBytes($html)

    $url = "http://127.0.0.1:$usedPort/"
    Write-Host "    Pagina: $url  (abrindo no navegador padrao...)"
    try { Start-Process $url | Out-Null } catch { Write-Warn2 "Nao consegui abrir o navegador automaticamente. Acesse: $url" }

    $result = $null
    try {
        while (-not $result) {
            $context  = $listener.GetContext()
            $request  = $context.Request
            $response = $context.Response

            if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/") {
                $response.ContentType = "text/html; charset=utf-8"
                $response.ContentLength64 = $htmlBytes.Length
                $response.OutputStream.Write($htmlBytes, 0, $htmlBytes.Length)
                $response.OutputStream.Close()
            }
            elseif ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/submit") {
                $reader = New-Object IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd()
                $reader.Close()

                $parsed  = [Web.HttpUtility]::ParseQueryString($body)
                $ip      = $parsed["ip"]
                $portStr = $parsed["port"]
                $pass    = [string]$parsed["pass"] -replace '\s+', ''

                $portVal = 0
                $formatValid = $ip -and [int]::TryParse($portStr, [ref]$portVal) -and $portVal -ge 1 -and $portVal -le 65535 `
                               -and ($pass -or $HasCurrentPassword)

                $status = "INVALID"
                if ($formatValid) {
                    $testPass = if ($pass) { $pass } else { $CurrentPassword }
                    Write-Host "    Testando conexao com $ip`:$portVal (sem alterar a rede do Windows)..."
                    $connOk = Test-ShadowsocksConnection -ExePath $ExePath -Method $Method `
                                -Server $ip -Port $portVal -Password $testPass -WorkDir $WorkDir
                    if ($connOk) {
                        $status = "OK"
                        Write-Ok "Conexao com $ip`:$portVal confirmada"
                    } else {
                        $status = "AUTH_FAILED"
                        Write-Warn2 "Nao consegui conectar em $ip`:$portVal com os dados informados - pedindo de novo na pagina"
                    }
                }

                $respBytes = [Text.Encoding]::UTF8.GetBytes($status)
                $response.StatusCode = if ($status -eq "OK") { 200 } else { 400 }
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $response.OutputStream.Close()

                if ($status -eq "OK") {
                    $result = [pscustomobject]@{ Ip = $ip; Port = $portVal; Pass = $pass }
                }
            }
            else {
                $response.StatusCode = 404
                $response.OutputStream.Close()
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }

    return $result
}

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

$installedExePath = Join-Path $InstallDir "sing-box.exe"
$alreadyInstalled = Test-Path $installedExePath

Write-Step "Verificando sing-box (versao travada: $SingBoxVersion)"
if ($SkipDownload) {
    if (-not $alreadyInstalled) { throw "sing-box.exe nao encontrado em $installedExePath e -SkipDownload foi usado" }
    Write-Ok "Pulando download (-SkipDownload) - usando $installedExePath"
}
elseif ($alreadyInstalled -and -not $ForceReinstall) {
    $installedVersion = $null
    try {
        $verOut = & $installedExePath version 2>$null
        if ($verOut -match 'version\s+([\d.]+)') { $installedVersion = $Matches[1] }
    } catch { }
    Write-Ok "sing-box ja instalado em $installedExePath$(if ($installedVersion) { " (versao $installedVersion)" })"
    if ($installedVersion -and $installedVersion -ne $SingBoxVersion) {
        Write-Warn2 "Versao instalada ($installedVersion) difere da travada no script ($SingBoxVersion). Mantendo a instalada - use -ForceReinstall para trocar."
    }
}
else {
    if ($ForceReinstall) { Write-Host "    -ForceReinstall: baixando de novo mesmo ja instalado" }
    Write-Host "    Baixando sing-box v$SingBoxVersion"
    $arch = if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "windows-arm64" } else { "windows-amd64" }
    } else { "windows-386" }

    $assetName   = "sing-box-$SingBoxVersion-$arch.zip"
    $downloadUrl = "https://github.com/SagerNet/sing-box/releases/download/v$SingBoxVersion/$assetName"

    Write-Host "    Arquivo: $assetName"
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    } catch {
        throw "Falha ao baixar $downloadUrl (a versao $SingBoxVersion existe para $arch ?): $($_.Exception.Message)"
    }
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

$testExePath = if ($exeSrc) { $exeSrc.FullName } else { Join-Path $InstallDir "sing-box.exe" }
if (-not (Test-Path $testExePath)) {
    throw "sing-box.exe nao encontrado para testar a conexao"
}

$cred = Get-ProxyCredentialsViaBrowser -CurrentIp $curIp -CurrentPort ([int]$ssOut.server_port) `
            -CurrentPassword $curPass -ExePath $testExePath -Method $ssOut.method -WorkDir $tmp
$proxyIp   = $cred.Ip
$proxyPort = $cred.Port
$proxyPass = if ($cred.Pass) { $cred.Pass } else { $curPass }
Write-Ok "Dados recebidos e conexao com o servidor confirmada"

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

if ($exeSrc) { Copy-Item $exeSrc.FullName $exePath -Force }
if (-not (Test-Path $exePath)) { throw "sing-box.exe nao esta em $InstallDir" }

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