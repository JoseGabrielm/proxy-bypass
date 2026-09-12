@echo off
setlocal

cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "INSTALL=.\setup.ps1"

set "CMD=%~1"
if "%CMD%"=="" set "CMD=instalar"

set "USECLI=0"
set "ARGS="
:loop
shift
if "%~1"=="" goto :run
if /i "%~1"=="--cli"      (set "USECLI=1" & goto :loop)
if /i "%~1"=="--terminal" (set "USECLI=1" & goto :loop)
set "ARGS=%ARGS% %1"
goto :loop

:run
if /i "%CMD%"=="instalar"  goto :instalar
if /i "%CMD%"=="install"   goto :instalar
if /i "%CMD%"=="monitor"   goto :monitor
if /i "%CMD%"=="monitorar" goto :monitor
if /i "%CMD%"=="logs"      goto :logs
if /i "%CMD%"=="log"       goto :logs
if /i "%CMD%"=="ajuda"     goto :ajuda
if /i "%CMD%"=="help"      goto :ajuda
if /i "%CMD%"=="/?"        goto :ajuda
echo  Comando desconhecido: %CMD%
goto :ajuda

:instalar
title Instalar sing-box (Discord via proxy)
schtasks /query /tn sing-box >nul 2>&1
if %errorlevel%==0 (
    echo.
    echo  O sing-box ja esta instalado e configurado para iniciar com o Windows.
    echo  Nao e necessario rodar o setup de novo.
    echo.
    choice /c SN /n /m "  Deseja REINSTALAR / trocar os dados da proxy? [S/N] "
    if errorlevel 2 (
        echo.
        echo  Nada foi alterado.
        echo.
        pause
        goto :eof
    )
)
if "%USECLI%"=="1" (
    %PS% "%INSTALL%" %ARGS%
) else (
    %PS% "%INSTALL%" -WebUI %ARGS%
)
goto :eof

:monitor
title sing-box - monitor de trafego e rede
%PS% "%INSTALL%" -Monitor %ARGS%
goto :eof

:logs
title sing-box - logs
%PS% "%INSTALL%" -Logs %ARGS%
goto :eof

:ajuda
echo.
echo  Uso: install-bypass.bat [comando] [opcoes]
echo.
echo    instalar   (padrao)  baixa, configura e inicia o sing-box (abre interface web)
echo    monitor              trafego e status da rede ao vivo (Ctrl+C para sair)
echo    logs                 log do sing-box continuo e legivel (Ctrl+C para sair)
echo    ajuda                esta tela
echo.
echo  Opcoes:
echo    --cli                usa o modo terminal em vez da interface web
echo.
echo  Exemplos:
echo    install-bypass.bat
echo    install-bypass.bat monitor
echo.
echo  Para desfazer a instalacao use: revert-bypass.bat
echo.
pause
goto :eof