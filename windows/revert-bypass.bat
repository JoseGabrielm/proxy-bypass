@echo off
setlocal

cd /d "%~dp0"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "REVERT=.\revert.ps1"

set "CMD=%~1"
if "%CMD%"=="" set "CMD=reverter"

set "ARGS="
:loop
shift
if "%~1"=="" goto :run
set "ARGS=%ARGS% %1"
goto :loop

:run
if /i "%CMD%"=="reverter"  goto :reverter
if /i "%CMD%"=="revert"    goto :reverter
if /i "%CMD%"=="desfazer"  goto :reverter
if /i "%CMD%"=="completo"  goto :completo
if /i "%CMD%"=="full"      goto :completo
if /i "%CMD%"=="winsock"   goto :winsock
if /i "%CMD%"=="ajuda"     goto :ajuda
if /i "%CMD%"=="help"      goto :ajuda
if /i "%CMD%"=="/?"        goto :ajuda
echo  Comando desconhecido: %CMD%
goto :ajuda

:reverter
title Reverter sing-box (Discord via proxy)
call :confirmar "  Isso para o sing-box, remove a tarefa de inicializacao, o adaptador TUN e as rotas." || goto :eof
%PS% "%REVERT%" %ARGS%
goto :eof

:completo
title Reverter sing-box + apagar arquivos
call :confirmar "  Isso desfaz tudo E APAGA a pasta C:\Program Files\sing-box (config com a senha, log e executavel)." || goto :eof
%PS% "%REVERT%" -RemoveFiles %ARGS%
goto :eof

:winsock
title Reverter sing-box + reset do Winsock
call :confirmar "  Isso desfaz tudo e reseta a pilha de rede do Windows (netsh winsock reset). Exige REINICIAR o PC." || goto :eof
%PS% "%REVERT%" -ResetWinsock %ARGS%
goto :eof

:confirmar
schtasks /query /tn sing-box >nul 2>&1
if not %errorlevel%==0 (
    echo.
    echo  A tarefa agendada 'sing-box' nao existe. Parece que nao ha nada instalado.
    echo  Ainda assim, o revert pode limpar adaptador TUN e rotas que ficaram para tras.
)
echo.
echo %~1
echo.
choice /c SN /n /m "  Deseja continuar? [S/N] "
if errorlevel 2 (
    echo.
    echo  Nada foi alterado.
    echo.
    pause
    exit /b 1
)
exit /b 0

:ajuda
echo.
echo  Uso: revert-bypass.bat [comando] [opcoes]
echo.
echo    reverter   (padrao)  para o sing-box, remove tarefa, TUN e rotas; mantem os arquivos
echo    completo             o mesmo, mas apaga tambem C:\Program Files\sing-box (senha, log, exe)
echo    winsock              o mesmo, mais "netsh winsock reset" (so se a rede continuar estranha; exige reboot)
echo    ajuda                esta tela
echo.
echo  Exemplos:
echo    revert-bypass.bat
echo    revert-bypass.bat completo
echo.
echo  Qualquer opcao extra e repassada ao revert.ps1 (ex: revert-bypass.bat reverter -ResetWinsock).
echo  Para instalar de novo use: install-bypass.bat
echo.
pause
goto :eof
