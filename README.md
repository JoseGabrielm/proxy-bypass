# Discord via proxy isolado (Shadowsocks + tun2socks + network namespace)

Isso faz o Discord (texto, chamadas de voz, vídeo e compartilhamento de tela)
sair pela sua VPS, sem afetar o resto da internet do computador. Existem duas
versões: uma para **Linux** e outra para **Windows**.

---

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

- O arquivo `setup-discord-proxy.ps1`.
- A senha do servidor Shadowsocks.

### Como usar

1. Clique com o **botão direito** no arquivo `setup-discord-proxy.ps1`.
2. Escolha **"Executar com o PowerShell"** (ou abra o PowerShell como
   Administrador e rode o arquivo).
3. Se aparecer um aviso pedindo permissão de Administrador, aceite.
4. O script vai:
   - Instalar e configurar o programa que conecta na VPS.
   - Baixar e abrir outro programa (SocksCap64) — aqui você vai precisar
     clicar em "Next" algumas vezes até o instalador terminar.
   - Mostrar na tela um passo a passo simples (3 cliques) pra terminar a
     configuração dentro do SocksCap64.
5. No final, ele testa a conexão sozinho e avisa se deu certo.
6. Feche o Discord completamente (clique direito no ícone perto do
   relógio → Sair) e abra de novo.

### Se precisar rodar de novo

Pode rodar o script quantas vezes quiser — ele não quebra nada, só pula
as partes que já estão prontas.

---

## Resumindo

| | Linux | Windows |
|---|---|---|
| Primeira vez | `sudo ./setup.sh` | Executar `.ps1` como Administrador |
| Usar o Discord | `./run-discord.sh` | Abrir o Discord normalmente |
| Desfazer tudo | `sudo ./teardown.sh` | Desinstalar os dois programas pelo Painel de Controle |

Dúvidas ou algo travou? Chama quem configurou o servidor.

---

## Detalhes técnicos (Linux)

### Arquivos

- `setup.sh` — cria tudo (namespace, veth, NAT, serviço Shadowsocks, tun2socks). Idempotente.
- `teardown.sh` — reverte **tudo** que o `setup.sh` criou. Use se algo parecer errado com a rede.
- `run-discord.sh` — abre o Discord dentro do namespace configurado.
- `setup-discord-proxy.ps1` — versão Windows (Shadowsocks-Windows + SocksCap64).
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
