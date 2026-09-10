# Discord via proxy isolado (Shadowsocks + tun2socks + network namespace)

Isso faz o Discord (texto, chamadas de voz, vídeo e compartilhamento de tela)
sair pela sua VPS, sem afetar o resto da internet do computador. Existem duas
versões: uma para **Linux** e outra para **Windows**.

---
# Disclaimer
*NÃO* me responsabilizo pela disponibilidade de proxies de terceiros e nem por eventuais problemas na sua rede
causados pelas configs (Extremamente difícil de acontecer, mas pode acontecer)
*APENAS USE SE VOCÊ SABE O QUE ESTÁ FAZENDO OU TEM ALGUÉM QUE SABE TE GUIANDO*

Todos os programas utilizados para a solução são _open source_, seus respectivos repositórios são:

Shadowsocks: "https://github.com/shadowsocks"
tun2socks (Linux): "https://github.com/xjasonlyu/tun2socks"
sing-box (Windows): "https://github.com/SagerNet/sing-box"


## Linux

### O que você precisa

- Os arquivos `setup.sh`, `teardown.sh` e `run-discord.sh` (nesta pasta).
- A senha do servidor Shadowsocks (peça pra quem configurou a VPS).

### Primeira vez usando

1. Abra o arquivo `setup.sh` num editor de texto.
2. Ache a linha `SERVER_PASSWORD="..."` perto do topo e troque pela senha real.
3. Salve o arquivo.
4. Abra um terminal nesta pasta e rode:
   ```bash
   sudo ./setup.sh
   ```
5. Vai pedir sua senha do computador (não a do proxy). Espere terminar —
   ele mesmo baixa tudo que precisa e testa a conexão no final.

### Todo dia, pra usar o Discord

Depois de fazer o passo acima uma vez, sempre que quiser abrir o Discord
pela proxy:
```bash
./run-discord.sh
```
**Não** coloque `sudo` na frente desse comando — ele mesmo pede a senha
só na hora certa.

### Se o computador reiniciar

O passo 4 (`sudo ./setup.sh`) precisa ser rodado de novo depois de cada
reinicialização do PC (mas é rápido — a segunda vez em diante ele pula as
partes que já estão prontas).

### Se algo der errado / quiser desfazer tudo

```bash
sudo ./teardown.sh
# ou, para também remover os binários sslocal/tun2socks:
sudo ./teardown.sh --purge
```
Isso desfaz tudo que o `setup.sh` criou e devolve a rede ao normal.

---

## Windows

### O que você precisa

- A pasta `windows` inteira (`install-bypass.bat`, `setup.ps1`, `revert.ps1`
  e `config.json`). Os arquivos precisam ficar juntos.
- O IP, a porta e a senha do servidor Shadowsocks (peça pra quem
  configurou a VPS).

### Primeira vez usando

1. Abra um terminal (Prompt de Comando ou PowerShell) na pasta `windows`.
2. Rode:
   ```bat
   install-bypass.bat
   ```
3. Se aparecer um aviso pedindo permissão de Administrador, aceite.
4. O script vai perguntar o **IP**, a **porta** e a **senha** do servidor.
   Digite e aperte ENTER (a senha não aparece na tela enquanto você digita).
5. Ele mesmo baixa o sing-box, instala em `C:\Program Files\sing-box`,
   registra pra iniciar junto com o Windows e testa a conexão no final.
6. Se o Discord já estiver aberto, o script fecha e reabre ele sozinho.
   Se não estiver, ele pede pra você abrir na hora do último teste.

### Todo dia, pra usar o Discord

Nada. Depois da primeira vez, o sing-box sobe sozinho junto com o Windows.
É só abrir o Discord normalmente. O resto da internet do PC continua saindo
direto, sem passar pela proxy.

### Ver se está funcionando

```bat
install-bypass.bat monitor
```
Mostra ao vivo o tráfego e quais conexões estão saindo pela proxy
(as marcadas com `*`). Pra ver o log do sing-box:
```bat
install-bypass.bat logs
```
`Ctrl+C` sai dos dois.

### Se precisar rodar de novo

Se rodar `install-bypass.bat` com tudo já instalado, ele avisa e pergunta
se quer reinstalar ou trocar os dados da proxy. Responda `N` pra não mexer
em nada.

### Se algo der errado / quiser desfazer tudo

Clique com o **botão direito** em `revert.ps1` e escolha **"Executar com o
PowerShell"**, ou num terminal na pasta `windows`:
```powershell
powershell -ExecutionPolicy Bypass -File .\revert.ps1
```
Isso para o sing-box, remove a tarefa de inicialização, o adaptador de rede
virtual e as rotas, e devolve a rede ao normal. Pra apagar também a pasta
`C:\Program Files\sing-box` (que guarda a senha no `config.json`), acrescente
`-RemoveFiles` ao final do comando.

---

## Resumindo

| | Linux | Windows |
|---|---|---|
| Primeira vez | `sudo ./setup.sh` | `install-bypass.bat` |
| Usar o Discord | `./run-discord.sh` | Abrir o Discord normalmente |
| Ver se funciona | — | `install-bypass.bat monitor` |
| Desfazer tudo | `sudo ./teardown.sh` | `revert.ps1` |

Dúvidas ou algo travou? Chama quem configurou o servidor.

---

## Detalhes técnicos (Linux)

### Arquivos

- `setup.sh` — cria tudo (namespace, veth, NAT, serviço Shadowsocks, tun2socks). Idempotente.
- `teardown.sh` — reverte **tudo** que o `setup.sh` criou. Use se algo parecer errado com a rede.
- `run-discord.sh` — abre o Discord dentro do namespace configurado.
- `.state` — gerado automaticamente pelo `setup.sh`, usado pelo `teardown.sh` para saber exatamente o que reverter (ex: se o `ip_forward` já estava ligado antes por causa do Docker). Não edite manualmente.

### O que é seguro e o que fica isolado

Tudo que o `setup.sh` cria é **aditivo e escopado**:
- Um network namespace novo (`discord-ns`) — não mexe nas interfaces reais do host.
- Uma regra de NAT restrita a um único IP interno (`10.200.200.2/32`) — não afeta nenhum outro tráfego.
- `net.ipv4.ip_forward=1` — geralmente já está ativo por causa do Docker; o `teardown.sh` só reverte se realmente foi este script que ativou.

Nada disso toca na rota default do host nem exige desligar a rede normal em
algum momento. Ainda assim, `teardown.sh` existe para desfazer tudo com um
comando só, caso algo saia diferente do esperado.

## Limitações conhecidas

- **Não sobrevive a reboot**: network namespaces são voláteis. Depois de
  reiniciar o PC, rode `sudo ./setup.sh` de novo (ele detecta o que já existe
  e pula essas partes; só recria o namespace/tun2socks, que somem no reboot).
- **Se trocar de distro**: os binários (`sslocal`, `tun2socks`) são estáticos
  e continuam funcionando; só confirme que `curl`, `tar`, `unzip` e
  `iptables`/`iproute2` estão instalados (praticamente universais).
- Se o caminho do executável do Discord for diferente do detectado por
  `which discord`, edite `DISCORD_BIN` em `run-discord.sh`.

---

## Detalhes técnicos (Windows)

### Arquivos

- `install-bypass.bat` — ponto de entrada. Sem argumentos roda a instalação; `monitor` e `logs` abrem os modos de acompanhamento.
- `setup.ps1` — baixa a versão mais recente do sing-box, pede IP/porta/senha, grava o `config.json` em `C:\Program Files\sing-box`, registra uma tarefa agendada (SYSTEM, inicia no boot) e roda três testes: saída direta, saída pela proxy e Discord passando pela TUN.
- `revert.ps1` — desfaz tudo. `-RemoveFiles` apaga também a pasta de instalação; `-ResetWinsock` reseta a pilha de rede (só se a rede continuar estranha, exige reboot).
- `config.json` — config do sing-box com placeholders `__SERVER_IP__` e `__SERVER_PASSWORD__`, preenchidos pelo `setup.ps1`. Uma interface TUN captura todo o tráfego, mas só os processos `Discord.exe`, `DiscordCanary.exe` e `DiscordDevelopment.exe` são roteados pelo outbound Shadowsocks; o resto sai direto. Há também um proxy SOCKS/HTTP local em `127.0.0.1:1080` que força qualquer app apontado pra ele a sair pela proxy.
