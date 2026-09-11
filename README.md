# Discord via proxy isolado (Shadowsocks + tun2socks / sing-box)

Isso faz o Discord (texto, chamadas de voz, vídeo e compartilhamento de tela)
sair pela sua VPS, sem afetar o resto da internet do computador. Existem duas
versões: uma para **Linux** e outra para **Windows**.

---

> [!WARNING]
> ## Disclaimer
>
> **NÃO** me responsabilizo pela disponibilidade de proxies de terceiros, nem
> por eventuais problemas na sua rede causados pelas configs (extremamente
> difícil de acontecer, mas pode acontecer).
>
> **APENAS USE SE VOCÊ SABE O QUE ESTÁ FAZENDO OU TEM ALGUÉM QUE SABE TE
> GUIANDO.**

Todos os programas utilizados na solução são _open source_. Os respectivos
repositórios são:

| Programa | Usado em | Repositório |
|---|---|---|
| Shadowsocks (`sslocal`) | Linux | <https://github.com/shadowsocks/shadowsocks-rust> |
| tun2socks | Linux | <https://github.com/xjasonlyu/tun2socks> |
| sing-box | Windows | <https://github.com/SagerNet/sing-box> |

---

## Linux

### O que você precisa

- Os arquivos `setup.sh`, `teardown.sh` e `run-discord.sh` (pasta `linux`).
- `python3` instalado (usado só para abrir a página local que pede os dados
  da proxy — praticamente toda distro desktop já vem com ele).
- O IP, a porta e a senha do servidor Shadowsocks (peça pra quem configurou
  a VPS).

### Primeira vez usando

1. Abra um terminal na pasta `linux` e rode:
   ```bash
   sudo ./setup.sh
   ```
2. Vai pedir sua senha do computador (não a do proxy). Uma página abre no
   seu navegador padrão pedindo IP, porta e senha do servidor — ela testa a
   conexão de verdade antes de aceitar (sem mexer na rede do PC ainda); se
   errar a senha, é só tentar de novo na mesma aba.
3. Espere terminar — ele baixa o que precisa, sobe o túnel, testa a conexão
   e no final habilita uma unit do systemd (`discord-proxy-setup`) que
   recria tudo sozinho a cada boot, sem pedir nada de novo.

### Todo dia, pra usar o Discord

Depois de fazer o passo acima uma vez, sempre que quiser abrir o Discord
pela proxy:
```bash
./run-discord.sh
```
**Não** coloque `sudo` na frente desse comando — ele mesmo pede a senha
só na hora certa.

Se o Discord já estiver aberto "normal" (fora da proxy), o script fecha
ele antes e abre a versão isolada. Isso é necessário: o Discord só aceita
uma instância por vez, e se a antiga continuasse viva o Discord novo só
repassaria o controle pra ela e nada passaria pela proxy.

### Se o computador reiniciar

Nada a fazer — o setup roda sozinho no boot (unit `discord-proxy-setup`
habilitada na primeira vez) e reaproveita a senha já confirmada antes; só
recria o namespace/túnel, que somem no reboot. Se preferir controlar
manualmente em vez de automático:
```bash
sudo ./setup.sh --no-persist
```
Isso desativa a unit de boot (ou evita habilitá-la, se ainda não existir) —
aí é rodar `sudo ./setup.sh` você mesmo depois de cada reinicialização.

### Se precisar trocar IP/porta/senha da proxy

```bash
sudo ./setup.sh --reconfigure
```
Força abrir a página de novo mesmo já tendo credenciais confirmadas. A
página vem com o IP e a porta atuais preenchidos; deixe a senha em branco
pra manter a que já está salva.

### Se algo der errado / quiser desfazer tudo

```bash
sudo ./teardown.sh
# ou, para também remover os binários sslocal/tun2socks:
sudo ./teardown.sh --purge
```
Isso desfaz tudo que o `setup.sh` criou (incluindo a unit de boot) e
devolve a rede ao normal.

---

## Windows

### O que você precisa

- A pasta `windows` inteira (`install-bypass.bat`, `revert-bypass.bat`,
  `setup.ps1`, `revert.ps1` e `config.json`). Os arquivos precisam ficar
  juntos.
- Windows 10 1803 ou mais novo (o script usa o `curl.exe` que já vem com o
  sistema).
- O IP, a porta e a senha do servidor Shadowsocks (peça pra quem
  configurou a VPS).

### Primeira vez usando

1. Abra um terminal (Prompt de Comando ou PowerShell) na pasta `windows`.
2. Rode:
   ```bat
   install-bypass.bat
   ```
3. Se aparecer um aviso pedindo permissão de Administrador, aceite.
4. Uma página abre no seu navegador padrão pedindo o **IP**, a **porta** e
   a **senha** do servidor. Ao clicar em "Salvar e continuar", ela testa a
   conexão de verdade com o servidor **antes** de mexer em qualquer coisa
   na rede do Windows. Se errar algum dado, ela avisa e você tenta de novo
   na mesma aba. Quando aparecer "Conectado!", pode fechar a aba e voltar
   pro terminal.
5. Ele mesmo baixa o sing-box (numa versão fixa, testada com este setup),
   instala em `C:\Program Files\sing-box`, registra pra iniciar junto com o
   Windows e roda três testes no final: saída direta, saída pela proxy e
   Discord passando pelo túnel.
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
`Ctrl+C` sai dos dois. Nenhum dos dois precisa de Administrador.

### Se precisar trocar IP/porta/senha da proxy

Rode `install-bypass.bat` de novo. Como já está tudo instalado, ele avisa e
pergunta se quer reinstalar / trocar os dados da proxy:

- `S` — abre a página de novo, com o IP e a porta atuais já preenchidos.
  Deixe a senha em branco pra manter a que já está salva. O sing-box já
  instalado é reaproveitado (não baixa de novo).
- `N` — não mexe em nada.

### Se precisar trocar a versão do sing-box

O script só baixa o sing-box quando ele ainda não está instalado. Pra forçar
o download da versão travada no script mesmo já tendo um instalado:
```bat
install-bypass.bat instalar -ForceReinstall
```
Se a versão instalada for diferente da travada no script, ele avisa no
começo, mas mantém a instalada até você rodar com `-ForceReinstall`.

### Se algo der errado / quiser desfazer tudo

Num terminal na pasta `windows` (ou dando dois cliques no arquivo):
```bat
revert-bypass.bat
```
Ele pede confirmação e depois para o sing-box, remove a tarefa de
inicialização, o adaptador de rede virtual e as rotas, reinicia o Discord
pela rede normal e testa se a internet voltou. Pra apagar também a pasta
`C:\Program Files\sing-box` (que guarda a senha no `config.json`):
```bat
revert-bypass.bat completo
```
O `.bat` já roda o PowerShell com `-ExecutionPolicy Bypass`, então não
precisa mexer na política de execução do Windows. Se preferir chamar o
`revert.ps1` direto, use `powershell -ExecutionPolicy Bypass -File .\revert.ps1`.

---

## Resumindo

| | Linux | Windows |
|---|---|---|
| Primeira vez | `sudo ./setup.sh` | `install-bypass.bat` |
| Usar o Discord | `./run-discord.sh` | Abrir o Discord normalmente |
| Depois de reiniciar o PC | Nada (automático) | Nada (automático) |
| Trocar dados da proxy | `sudo ./setup.sh --reconfigure` | `install-bypass.bat` e responder `S` |
| Ver se funciona | — | `install-bypass.bat monitor` |
| Desfazer tudo | `sudo ./teardown.sh` | `revert-bypass.bat` |

Dúvidas ou algo travou? Chama quem configurou o servidor.

---

## Detalhes técnicos (Linux)

### Arquivos

- `setup.sh` — cria tudo (namespace, veth, NAT, serviço Shadowsocks, tun2socks). Idempotente. Na primeira vez (ou com `--reconfigure`), abre uma página local no navegador (servida via `python3`, só em `127.0.0.1`) pra pedir IP/porta/senha da proxy; ela testa a conexão de verdade contra o servidor (uma instância isolada do `sslocal`, sem tocar em namespace/rede) antes de aceitar os dados, e permite tentar de novo na mesma aba se a senha estiver errada — evita configurar o túnel real com uma credencial que não funciona.
- `teardown.sh` — reverte **tudo** que o `setup.sh` criou. Use se algo parecer errado com a rede.
- `run-discord.sh` — abre o Discord dentro do namespace configurado. Antes disso, encerra qualquer instância do Discord já rodando no usuário (o lock de instância única do Electron faria a nova instância só repassar o controle pra antiga e sair, deixando tudo fora da proxy). Também garante que o Discord não seja lançado como root, mesmo se o script for chamado com `sudo` por engano.
- `.state` — gerado automaticamente pelo `setup.sh`, usado pelo `teardown.sh` para saber exatamente o que reverter (ex: se o `ip_forward` já estava ligado antes por causa do Docker, nomes das units). Não edite manualmente.
- `/etc/shadowsocks/client.json` — guarda IP/porta/senha confirmados; é onde o `setup.sh` verifica se já tem credenciais válidas antes de abrir a página de novo. Gerado via `json.dump` (não heredoc) pra senha com aspas/`$()` não quebrar o JSON nem virar comando.
- `/etc/systemd/system/shadowsocks-netns-client.service` — serviço do `sslocal`, escutando em `10.200.200.1:1080` (só alcançável de dentro do namespace).
- `/etc/systemd/system/discord-proxy-setup.service` — unit oneshot criada pelo `setup.sh` (a menos que rodado com `--no-persist`) que reexecuta o próprio `setup.sh` a cada boot, depois que a rede sobe (`network-online.target`). Como as credenciais já estão em `client.json`, essa execução automática nunca abre navegador nem pede nada — só recria namespace/veth/NAT/tun2socks. `teardown.sh` remove essa unit junto com o resto (antes de apagar o `client.json`, senão o próximo boot travaria tentando abrir a página sem ninguém pra responder).

### O que é seguro e o que fica isolado

Tudo que o `setup.sh` cria é **aditivo e escopado**:
- Um network namespace novo (`discord-ns`) — não mexe nas interfaces reais do host.
- Uma regra de NAT restrita a um único IP interno (`10.200.200.2/32`) — não afeta nenhum outro tráfego.
- `net.ipv4.ip_forward=1` — geralmente já está ativo por causa do Docker; o `teardown.sh` só reverte se realmente foi este script que ativou.

Nada disso toca na rota default do host nem exige desligar a rede normal em
algum momento. Ainda assim, `teardown.sh` existe para desfazer tudo com um
comando só, caso algo saia diferente do esperado.

### Limitações conhecidas

- **O namespace em si não sobrevive a reboot** (são voláteis por natureza),
  mas por padrão isso é transparente: a unit `discord-proxy-setup` recria
  tudo sozinha logo depois que a rede sobe no boot. Com `--no-persist`, essa
  unit não é instalada e você volta a precisar rodar `sudo ./setup.sh`
  manualmente depois de cada reinicialização.
- **Se trocar de distro**: os binários (`sslocal`, `tun2socks`) são estáticos
  e continuam funcionando; só confirme que `curl`, `tar`, `unzip`,
  `iptables`/`iproute2` e `python3` estão instalados (praticamente
  universais em distros desktop; `python3` só é usado pela página local de
  credenciais).
- **systemd é obrigatório** (o serviço do `sslocal` e a unit de boot são
  registrados via `systemctl`) — distros sem systemd (Alpine, Void, Devuan,
  Gentoo com OpenRC) não funcionam sem adaptar essa parte.
- **Só x86_64 por enquanto**: os downloads de `sslocal`/`tun2socks` são
  fixos pra `amd64`; ARM64 (Raspberry Pi, Asahi Linux) precisa editar as
  URLs de download no topo do `setup.sh`.
- Se o caminho do executável do Discord for diferente do detectado por
  `which discord`, edite `DISCORD_BIN` em `run-discord.sh`.

---

## Detalhes técnicos (Windows)

### Arquivos

- `install-bypass.bat` — ponto de entrada. Sem argumentos roda a instalação; `monitor` e `logs` abrem os modos de acompanhamento; `ajuda` lista os comandos. Qualquer argumento extra é repassado ao `setup.ps1` (ex: `install-bypass.bat instalar -ForceReinstall`). Se a tarefa agendada `sing-box` já existir, pergunta antes de reinstalar.
- `setup.ps1` — faz tudo, nesta ordem:
  1. Verifica se já existe `sing-box.exe` em `C:\Program Files\sing-box`. Se não, baixa a versão **travada** no script (`-SingBoxVersion`, hoje `1.14.0`), detectando `amd64`/`arm64`/`386`. Se já existe, reaproveita (e avisa se a versão instalada difere da travada). `-ForceReinstall` força o download; `-SkipDownload` proíbe qualquer download.
  2. Abre uma página local (`http://127.0.0.1:8765`, ou a próxima porta livre até `8774`) no navegador padrão pedindo IP/porta/senha. O handler local sobe uma instância isolada do sing-box (só um inbound `mixed` em `127.0.0.1`, sem TUN) e tenta buscar o IP público por ela; só aceita os dados se a autenticação funcionar. Isso evita ativar a TUN com `strict_route` usando uma senha errada, o que derrubaria a rede do Discord inteira.
  3. Grava IP/porta/senha no `config.json`, adiciona a Clash API em `127.0.0.1:9090` (usada pelos testes e pelo `monitor`) e log em arquivo (`sing-box.log`).
  4. Copia pra `C:\Program Files\sing-box`, valida com `sing-box check`, registra uma tarefa agendada (`sing-box`, roda como SYSTEM no boot, reinicia sozinha se cair) e inicia.
  5. Reinicia o Discord se estiver aberto (conexões antigas foram feitas antes da TUN existir) e roda três testes: saída direta, saída pela proxy (via socks local) e Discord passando pela TUN.
- `revert-bypass.bat` — ponto de entrada pra desfazer. Sem argumentos roda o `revert.ps1`; `completo` acrescenta `-RemoveFiles`; `winsock` acrescenta `-ResetWinsock`; `ajuda` lista os comandos. Pede confirmação antes de rodar e avisa se a tarefa agendada `sing-box` não existir. Qualquer argumento extra é repassado ao `revert.ps1`. Existe pelo mesmo motivo do `install-bypass.bat`: chamar o PowerShell com `-ExecutionPolicy Bypass` pra não esbarrar na política de execução da máquina.
- `revert.ps1` — desfaz tudo: para e remove a tarefa, mata o processo, remove o adaptador TUN (Wintun) e rotas órfãs, limpa DNS, reinicia o Discord pela rede normal e testa a saída direta. `-RemoveFiles` apaga também a pasta de instalação e as temporárias; `-ResetWinsock` reseta a pilha de rede (só se a rede continuar estranha, exige reboot).
- `config.json` — config do sing-box com placeholders `__SERVER_IP__` e `__SERVER_PASSWORD__`, preenchidos pelo `setup.ps1`. Uma interface TUN (`singbox-tun`, `172.19.0.1/30`, `auto_route` + `strict_route`) captura todo o tráfego, mas só os processos `Discord.exe`, `DiscordCanary.exe` e `DiscordDevelopment.exe` são roteados pelo outbound Shadowsocks; o resto sai direto. Há também um proxy SOCKS/HTTP local em `127.0.0.1:1080` que força qualquer app apontado pra ele a sair pela proxy.

### Onde ficam as coisas

| O quê | Onde |
|---|---|
| Executável e config (com a senha) | `C:\Program Files\sing-box\` |
| Log | `C:\Program Files\sing-box\sing-box.log` |
| Tarefa agendada | `sing-box` (`schtasks /run /tn sing-box`, `schtasks /end /tn sing-box`) |
| Clash API | `http://127.0.0.1:9090` (`GET /connections` mostra o tráfego) |
| Temporários do download | `C:\ProgramData\sing-box-setup\` |

### Limitações conhecidas

- **Precisa de Administrador** pra instalar e pra reverter (criar a TUN e a
  tarefa agendada). `monitor` e `logs` não precisam.
- **A senha fica em texto puro** em `C:\Program Files\sing-box\config.json`
  (só Administrador lê). Use `revert-bypass.bat completo` se quiser apagar.
- **Só os executáveis listados no `config.json`** saem pela proxy. Se o
  Discord mudar o nome do processo, edite a lista em `process_name` e rode
  `install-bypass.bat` de novo.
