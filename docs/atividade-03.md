# Atividade 3 — Automatizar de verdade

Esta atividade coloca o `ufla-devops-shop` para rodar como um serviço Linux de verdade: instalado por um script idempotente, gerenciado pelo systemd, com backup diário agendado e o Nginx à frente fazendo TLS.

Ambiente usado nos testes: Ubuntu 26.04, PostgreSQL 18, Redis 8, Nginx 1.28.

## Visão geral dos artefatos

| Artefato | O que faz |
|---|---|
| `scripts/deploy.sh` | Prepara a máquina e coloca a aplicação no ar. Idempotente: pode ser executado quantas vezes for preciso. Termina com healthcheck em `/ready`. |
| `scripts/backup.sh` | Gera um `pg_dump` compactado e datado, mantém os 7 mais recentes e registra o resultado no journal. |
| `systemd/ufla-shop.service` | Unit da API: usuário não-root, `EnvironmentFile`, `Restart=on-failure`, sobe depois do PostgreSQL. |
| `systemd/ufla-shop-backup.service` | Unit `oneshot` que executa o `backup.sh`. |
| `systemd/ufla-shop-backup.timer` | Dispara o backup todo dia às 3h, com `Persistent=true`. |
| `nginx/loja.conf` | Proxy reverso: redireciona HTTP para HTTPS, termina o TLS e repassa o IP real do cliente. |
| `ufla-shop.env.example` | Modelo das variáveis de ambiente, sem segredos. |

## (a) Como rodar o `deploy.sh` numa máquina limpa

Requisitos: Linux com systemd (Ubuntu/Debian), acesso `sudo` e o repositório clonado.

```bash
git clone <url-do-fork> ufla-devops-shop
cd ufla-devops-shop
git switch atividade-03
sudo ./scripts/deploy.sh
```

O script exige root e se recusa a rodar sem `sudo`. Em ordem, ele:

1. instala os pacotes do sistema (`python3-venv`, `postgresql`, `redis-server`, `rsync`, `nginx`, `curl`, `openssl`);
2. cria o usuário de sistema `ufla-shop` (sem shell de login), se ainda não existir;
3. sincroniza o código para `/opt/ufla-shop` com `rsync --delete`, cria o venv e instala o `requirements.txt`;
4. copia o `ufla-shop.env.example` para `/etc` e cria o `/etc/ufla-shop.env` a partir dele **somente se ainda não existir**, com `chmod 600`;
5. garante o usuário e a base `loja` no PostgreSQL, aplicando a senha que estiver no `/etc/ufla-shop.env`;
6. instala as três units em `/etc/systemd/system/`, roda `daemon-reload`, habilita e reinicia a API e habilita o timer do backup;
7. gera o certificado autoassinado (somente se ainda não existir), instala o site do Nginx, valida com `nginx -t` e recarrega;
8. consulta `http://localhost:8000/ready` até 10 vezes, com 1 s de intervalo, e sai com `exit 1` se o `/ready` não responder com sucesso (o `curl -f` trata qualquer status a partir de 400 como falha, incluindo o 503 que a API devolve quando o banco ou o cache não estão prontos).

**Senha do banco.** O `/etc/ufla-shop.env` é a única fonte da verdade da senha: o deploy faz o PostgreSQL usar a mesma senha que a aplicação. Numa máquina limpa, o arquivo é criado com a senha de exemplo e tudo funciona; o script apenas emite um aviso. Para usar outra senha, basta editar o arquivo e rodar o deploy de novo:

```bash
sudo vi /etc/ufla-shop.env
sudo ./scripts/deploy.sh
```

A senha real nunca é versionada: no repositório existe apenas o `ufla-shop.env.example`.

## (b) Prova do `Restart=on-failure`

Serviço rodando antes do teste, com o usuário não-root:

```text
$ systemctl status ufla-shop
● ufla-shop.service - API do ufla-devops-shop
     Loaded: loaded (/etc/systemd/system/ufla-shop.service; enabled; preset: enabled)
     Active: active (running) since Sun 2026-10-04 19:45:35 -03; 14s ago
   Main PID: 99556 (uvicorn)
     Memory: 50.1M (max: 512M, available: 461.8M, peak: 51.3M)
     CGroup: /system.slice/ufla-shop.service
             └─99556 /opt/ufla-shop/.venv/bin/python3 /opt/ufla-shop/.venv/bin/uvicorn app:api --port 8000

$ ps -o user= -p "$(systemctl show -p MainPID --value ufla-shop)"
ufla-shop
```

Processo morto com `kill -9`. Cinco segundos depois, o systemd já havia detectado a morte por sinal e agendado a religação:

```text
$ sudo kill -9 "$(systemctl show -p MainPID --value ufla-shop)"
$ sleep 5
$ systemctl status ufla-shop
● ufla-shop.service - API do ufla-devops-shop
     Loaded: loaded (/etc/systemd/system/ufla-shop.service; enabled; preset: enabled)
     Active: activating (auto-restart) (Result: signal) since Sun 2026-10-04 19:51:24 -03; 5s ago
    Process: 99556 ExecStart=/opt/ufla-shop/.venv/bin/uvicorn app:api --port 8000 (code=killed, signal=KILL)
   Main PID: 99556 (code=killed, signal=KILL)

Oct 04 19:51:29 GBUbuntu systemd[1]: ufla-shop.service: Scheduled restart job, restart counter is at 1.
Oct 04 19:51:29 GBUbuntu systemd[1]: Started ufla-shop.service - API do ufla-devops-shop.
```

O cabeçalho ainda mostra `activating (auto-restart)`, mas as linhas do journal da mesma saída já mostram o `Started`. Não é erro: o `sleep 5` terminou junto com o `RestartSec=5s`, e o `status` foi capturado no instante exato da religação (19:51:24 + 5 s = 19:51:29).

Logo depois, o serviço de pé de novo, com outro PID (99556 → 102060):

```text
$ systemctl status ufla-shop
● ufla-shop.service - API do ufla-devops-shop
     Loaded: loaded (/etc/systemd/system/ufla-shop.service; enabled; preset: enabled)
     Active: active (running) since Sun 2026-10-04 19:51:29 -03; 1min 5s ago
   Main PID: 102060 (uvicorn)
     Memory: 48.5M (max: 512M, available: 463.4M, peak: 49.3M)
     CGroup: /system.slice/ufla-shop.service
             └─102060 /opt/ufla-shop/.venv/bin/python3 /opt/ufla-shop/.venv/bin/uvicorn app:api --port 8000

Oct 04 19:51:29 GBUbuntu systemd[1]: ufla-shop.service: Scheduled restart job, restart counter is at 1.
Oct 04 19:51:29 GBUbuntu systemd[1]: Started ufla-shop.service - API do ufla-devops-shop.
Oct 04 19:51:29 GBUbuntu uvicorn[102060]: INFO:     Application startup complete.
Oct 04 19:51:29 GBUbuntu uvicorn[102060]: INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)
```

**Por que `systemctl show` e não `pidof uvicorn`:** o `uvicorn` é um script com shebang, então o programa executado é o `python3`, que recebe o script como argumento (veja a linha do `CGroup`). O kernel dá ao processo o nome `uvicorn`, e por isso o `status` mostra `Main PID: 99556 (uvicorn)`. Mas o `pidof` compara pelo primeiro argumento da linha de comando, que é o `python3`, e não encontra o processo. O `pidof -x uvicorn`, que também considera scripts, funcionaria. Perguntar o PID ao próprio systemd é a forma mais direta e confiável.

## (c) Nginx: TLS e redirecionamento

```text
$ curl -I http://localhost
HTTP/1.1 301 Moved Permanently
Server: nginx/1.28.3 (Ubuntu)
Content-Type: text/html
Content-Length: 178
Location: https://localhost/

$ curl -kI https://localhost
HTTP/1.1 200 OK
Server: nginx/1.28.3 (Ubuntu)
Content-Type: text/html
Content-Length: 1262
Last-Modified: Tue, 29 Sep 2026 21:42:03 GMT
Accept-Ranges: bytes
```

A API continua ouvindo apenas em `127.0.0.1:8000`; de fora, só o Nginx (portas 80 e 443).

**Por que a página inicial é servida pelo Nginx:** o `curl -I` envia uma requisição HEAD, e a rota `GET /` da API só aceita GET. Com o proxy direto, o resultado era `405 Method Not Allowed` (com `allow: GET`, vindo da própria API). Como o front é estático, o `loja.conf` passou a servir a página inicial direto do disco com um `location = /`, como já fazia com `/static/`. O Nginx responde HEAD normalmente, e a API fica livre para as rotas dinâmicas (`/ready`, `/health`, `/docs` e o restante seguem pelo `proxy_pass`).

## (d) Backup

Três execuções do backup, com um minuto ou mais de intervalo (o nome do arquivo vai até o minuto):

```text
$ sudo systemctl start ufla-shop-backup.service
$ sudo ls -la /var/backups/ufla-shop
total 20
drwx------ 2 root root 4096 Oct  4 21:56 .
drwxr-xr-x 3 root root 4096 Oct  4 21:45 ..
-rw------- 1 root root 1624 Oct  4 21:45 loja-2026-10-04-2145.sql.gz
-rw------- 1 root root 1623 Oct  4 21:54 loja-2026-10-04-2154.sql.gz
-rw------- 1 root root 1626 Oct  4 21:56 loja-2026-10-04-2156.sql.gz

$ journalctl -t backup -n 3
Oct 04 21:45:43 GBUbuntu backup[154047]: Backup gerado: /var/backups/ufla-shop/loja-2026-10-04-2145.sql.gz (4.0K)
Oct 04 21:54:59 GBUbuntu backup[159991]: Backup gerado: /var/backups/ufla-shop/loja-2026-10-04-2154.sql.gz (4.0K)
Oct 04 21:56:00 GBUbuntu backup[160473]: Backup gerado: /var/backups/ufla-shop/loja-2026-10-04-2156.sql.gz (4.0K)
```

Timer agendado:

```text
$ systemctl list-timers | grep ufla
Mon 2026-10-05 03:02:16 -03       7h -                                      - ufla-shop-backup.timer         ufla-shop-backup.service
```

O horário é 03:02, e não 03:00, por causa do `RandomizedDelaySec=5m`.

Comportamento do script:

- **Código de saída correto:** `set -euo pipefail`. Sem o `pipefail`, uma falha do `pg_dump` seria escondida pelo `gzip`, que termina bem.
- **Sem arquivo quebrado:** o dump é gravado em `.tmp` e só renomeado depois de completo; um `trap` remove o temporário se o script abortar. Um dump incompleto nunca entra na rotação.
- **Rotação:** lista os dumps do mais antigo ao mais novo e apaga todos menos os 7 últimos. A rotação acontece depois do dump, então um backup que falhou não apaga os antigos.
- **Permissões:** `umask 077`, e por isso os dumps (que contêm todos os dados do banco) só podem ser lidos pelo root.
- **Senha:** o script não contém senha. A `DATABASE_URL` chega pelo `EnvironmentFile` da unit.

## (e) Idempotência: duas execuções seguidas

Os avisos `W:` do `apt-get update` (um repositório de terceiros configurado nesta máquina) foram omitidos, porque não têm relação com o projeto.

Primeira execução (a saída do `openssl` gerando a chave do certificado foi omitida):

```text
$ sudo ./scripts/deploy.sh
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
Synchronizing state of nginx.service with SysV service script with /usr/lib/systemd/systemd-sysv-install.
Executing: /usr/lib/systemd/systemd-sysv-install enable nginx
Deploy concluido: /ready respondeu
```

Segunda execução, logo em seguida:

```text
$ sudo ./scripts/deploy.sh
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
Synchronizing state of nginx.service with SysV service script with /usr/lib/systemd/systemd-sysv-install.
Executing: /usr/lib/systemd/systemd-sysv-install enable nginx
Deploy concluido: /ready respondeu
```

Na segunda execução nada é recriado: o certificado não é gerado de novo, o `.env` não é sobrescrito e o usuário e a base do banco não são recriados.

Como cada passo se mantém idempotente:

| Passo | Técnica |
|---|---|
| usuário de sistema | `id ufla-shop \|\| useradd ...` (verificar antes de agir) |
| pastas | `mkdir -p` |
| código | `rsync --delete`: o destino vira um espelho da origem |
| venv | `python3 -m venv` já é seguro na repetição |
| `.env` | `[ -f ... ] \|\| cp ...`: nunca sobrescreve a configuração real |
| usuário e base no PostgreSQL | consulta em `pg_roles` e `pg_database` antes de criar; `ALTER USER` reaplica a mesma senha |
| certificado | gerado só se a chave não existir |
| site do Nginx | `ln -sfn` (o `ln -s` falharia na segunda execução) |
| serviços | `enable` e `restart` funcionam em qualquer estado |

## Decisões e observações

- **Uma única fonte da verdade para a senha.** A senha existe só no `/etc/ufla-shop.env`, e o deploy faz o PostgreSQL usá-la (`ALTER USER` a cada execução). O banco e a aplicação leem a senha do mesmo arquivo, então não têm como ficar diferentes. Trocar a senha é editar o arquivo e rodar o deploy.
- **Segredos fora do código.** A senha fica só em `/etc/ufla-shop.env` (`chmod 600`), lido pelo systemd como root antes de trocar para o usuário `ufla-shop`. A API recebe as variáveis sem ter acesso ao arquivo.
- **Aviso, e não erro, para a senha de exemplo.** Uma trava com `exit 1` impediria qualquer execução não assistida, inclusive a correção automática. O deploy avisa e segue.
- **Código separado da configuração.** O código fica em `/opt/ufla-shop` e a configuração em `/etc`. Como o `rsync --delete` espelha o repositório, um `.env` dentro de `/opt` seria apagado a cada deploy.
- **Healthcheck com `--retry-connrefused`.** Logo após o `restart`, a porta 8000 ainda não está aberta. Sem essa opção, o `curl` não repete quando a conexão é recusada. `--retry 9` significa 9 repetições além da primeira tentativa, ou seja, 10 tentativas.
- **Comentários das units em linhas próprias.** O systemd só reconhece `#` no início da linha; um comentário no fim viraria parte do valor.
- **API ouvindo só em `127.0.0.1`.** O uvicorn escuta apenas localmente; o único ponto de entrada externo é o Nginx.
- **ShellCheck sem apontamentos.** Os dois scripts passam no ShellCheck. Duas diretivas foram adicionadas, cada uma com comentário justificando: `source=/dev/null` no `deploy.sh`, porque o `/etc/ufla-shop.env` só existe no servidor e não pode ser analisado; e `disable=SC2012` no `backup.sh`, porque o `ls` da rotação só lista nomes gerados pelo próprio script, sem espaços nem caracteres especiais.