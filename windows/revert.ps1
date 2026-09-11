#Requires -Version 5.1
<#
    reverter-singbox-discord.ps1
    ------------------------------------------------------------
    Desfaz tudo que o instalar-singbox-discord.ps1 configurou e
    devolve a rede da maquina ao normal:

      1. Para o sing-box e remove a tarefa agendada
      2. Remove o adaptador TUN (Wintun) se ele ficou para tras
      3. Remove rotas orfas que apontavam para a TUN
      4. Limpa cache de DNS
      5. Reinicia o Discord (se estiver aberto) para ele reconectar
         pela rede normal

    Parametros:
      -RemoveFiles   apaga tambem C:\Program Files\sing-box
                     (config.json com a senha, log e o executavel)
      -ResetWinsock  faz "netsh winsock reset" + "netsh int ip reset"
                     (so use se a rede continuar estranha; exige reboot)
    ------------------------------------------------------------
    Execute em um PowerShell como Administrador:
        Set-ExecutionPolicy Bypass -Scope Process -Force
        .\reverter-singbox-discord.ps1
        .\reverter-singbox-discord.ps1 -RemoveFiles
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramFiles\sing-box",
    [string]$TaskName   = "sing-box",
    [switch]$RemoveFiles,
    [switch]$ResetWinsock
)

$ErrorActionPreference = "Continue"

function Write-Step  ($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok    ($msg) { Write-Host "    [OK]    $msg" -ForegroundColor Green }
function Write-Warn2 ($msg) { Write-Host "    [AVISO] $msg" -ForegroundColor Yellow }
function Write-Fail  ($msg) { Write-Host "    [FALHA] $msg" -ForegroundColor Red }

function Get-PublicIp {
    foreach ($u in @("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com")) {
        try {
            $r = & curl.exe -s --max-time 10 $u 2>$null
            if ($r -and $r.Trim() -match '^\d{1,3}(\.\d{1,3}){3}$') { return $r.Trim() }
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------- 0. admin
Write-Step "Verificando privilegios"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn2 "Nao esta como administrador. Reabrindo com elevacao..."
    $extra = @()
    if ($RemoveFiles)  { $extra += "-RemoveFiles" }
    if ($ResetWinsock) { $extra += "-ResetWinsock" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " + ($extra -join " "))
    exit
}
Write-Ok "Rodando como administrador"

# Tudo abaixo roda dentro de try/finally: a janela so fecha depois de um ENTER,
# inclusive quando acontece um erro (senao a janela elevada some antes de dar para ler).
$exitCode = 0
try {

# ---------------------------------------------------------------- 1. parar sing-box
Write-Step "Parando o sing-box"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Ok "Tarefa agendada '$TaskName' parada e removida"
} else {
    Write-Host "    Tarefa '$TaskName' nao existe"
}

$procs = Get-Process sing-box -ErrorAction SilentlyContinue
if ($procs) {
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    Write-Ok "Processo sing-box encerrado"
} else {
    Write-Host "    Nenhum processo sing-box em execucao"
}

# ---------------------------------------------------------------- 2. adaptador TUN
Write-Step "Removendo adaptador TUN"
# o sing-box normalmente remove a TUN ao sair; isso cobre o caso de ela ficar orfa
Start-Sleep 1
$tun = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -eq "sing-box" -or $_.Name -eq "singbox-tun" -or $_.InterfaceDescription -like "*sing*box*" -or $_.InterfaceDescription -like "*Wintun*"
}
if ($tun) {
    foreach ($a in $tun) {
        try {
            Remove-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop
            Write-Ok "Adaptador '$($a.Name)' removido"
        } catch {
            # Wintun nem sempre aceita Remove-NetAdapter; tenta via pnputil
            $pnp = Get-PnpDevice -FriendlyName $a.InterfaceDescription -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pnp) {
                & pnputil.exe /remove-device $pnp.InstanceId | Out-Null
                Write-Ok "Adaptador '$($a.Name)' removido via pnputil"
            } else {
                Write-Warn2 "Nao consegui remover '$($a.Name)': $($_.Exception.Message)"
            }
        }
    }
} else {
    Write-Ok "Nenhum adaptador TUN restante"
}

# ---------------------------------------------------------------- 3. rotas orfas
Write-Step "Limpando rotas que apontavam para a TUN"
$removed = 0
# rotas na faixa que o config usou (172.19.0.0/30) ou em interface que ja nao existe
$ifIndexes = (Get-NetAdapter -ErrorAction SilentlyContinue).ifIndex
$routes = Get-NetRoute -ErrorAction SilentlyContinue | Where-Object {
    ($_.DestinationPrefix -like "172.19.0.*") -or
    ($_.NextHop -like "172.19.0.*") -or
    ($_.InterfaceAlias -eq "sing-box") -or ($_.InterfaceAlias -eq "singbox-tun") -or
    ($ifIndexes -and ($ifIndexes -notcontains $_.ifIndex))
}
foreach ($r in $routes) {
    try {
        Remove-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $r.ifIndex -Confirm:$false -ErrorAction Stop
        $removed++
    } catch { }
}
if ($removed -gt 0) { Write-Ok "$removed rota(s) removida(s)" } else { Write-Ok "Nenhuma rota orfa encontrada" }

# garante que existe rota padrao na interface fisica
$default = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
if ($default) {
    Write-Ok "Rota padrao ativa: via $($default.NextHop) em '$($default.InterfaceAlias)'"
} else {
    Write-Warn2 "Nenhuma rota padrao encontrada - renovando DHCP..."
    & ipconfig.exe /renew | Out-Null
}

# ---------------------------------------------------------------- 4. DNS
Write-Step "Limpando cache DNS"
& ipconfig.exe /flushdns | Out-Null
Clear-DnsClientCache -ErrorAction SilentlyContinue
Write-Ok "Cache DNS limpo"

if ($ResetWinsock) {
    Write-Step "Reset do Winsock / pilha IP (exige reboot)"
    & netsh.exe winsock reset | Out-Null
    & netsh.exe int ip reset | Out-Null
    Write-Ok "Reset feito - reinicie o Windows ao final"
}

# ---------------------------------------------------------------- 5. arquivos
if ($RemoveFiles) {
    Write-Step "Removendo $InstallDir"
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $InstallDir) { Write-Warn2 "Nao consegui apagar tudo em $InstallDir" }
        else                       { Write-Ok "Pasta removida (config.json, log e executavel)" }
    } else {
        Write-Host "    Pasta nao existe"
    }
    foreach ($tmp in @((Join-Path $env:ProgramData "sing-box-setup"), (Join-Path $env:TEMP "sing-box-setup"))) {
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host "`n    (arquivos em $InstallDir mantidos - use -RemoveFiles para apagar)"
}

# ---------------------------------------------------------------- 6. reset do Discord
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
        if ($discordExe -like "*Update.exe") {
            Start-Process $discordExe -ArgumentList "--processStart Discord.exe"
        } else {
            Start-Process explorer.exe -ArgumentList "`"$discordExe`""
        }
        Start-Sleep 5
        if (Get-Process | Where-Object { $_.ProcessName -like "Discord*" }) { Write-Ok "Discord reiniciado pela rede normal" }
        else { Write-Warn2 "Discord fechado mas nao reabriu - abra manualmente" }
    } else {
        Write-Warn2 "Discord fechado, mas nao achei o executavel para reabrir - abra manualmente"
    }
} else {
    Write-Host "    Discord nao estava em execucao"
}


Write-Host "================ CONCLUIDO ================" -ForegroundColor Cyan
Write-Host " Rede da maquina de volta ao normal."
if ($ResetWinsock) { Write-Host " Reinicie o Windows para concluir o reset do Winsock." -ForegroundColor Yellow }
Write-Host "===========================================" -ForegroundColor Cyan
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