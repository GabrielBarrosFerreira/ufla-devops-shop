# Atividade 5 — A stack completa

Stack do `ufla-devops-shop` em modo completo com Docker Compose: **api** (FastAPI/Uvicorn), **banco** (PostgreSQL 16), **cache** (Redis 7) e **nginx** (proxy reverso, única porta publicada).

## (a) Stack saudável

```
$ docker compose ps
NAME                       IMAGE                                           COMMAND                  SERVICE   CREATED         STATUS                   PORTS
ufla-devops-shop-api-1     ghcr.io/gabrielbarrosferreira/ufla-shop:1.0.0   "uvicorn app:api --h…"   api       2 minutes ago   Up 2 minutes (healthy)   8000/tcp
ufla-devops-shop-banco-1   postgres:16-alpine                              "docker-entrypoint.s…"   banco     2 minutes ago   Up 2 minutes (healthy)   5432/tcp
ufla-devops-shop-cache-1   redis:7-alpine                                  "docker-entrypoint.s…"   cache     2 minutes ago   Up 2 minutes (healthy)   6379/tcp
ufla-devops-shop-nginx-1   nginx:1.27-alpine                               "/docker-entrypoint.…"   nginx     7 seconds ago   Up 5 seconds (healthy)   0.0.0.0:80->80/tcp, [::]:80->80/tcp
```

Os quatro serviços estão `healthy`. Apenas o Nginx publica porta (`0.0.0.0:80->80/tcp`); API, banco e cache ficam acessíveis só pela rede interna do Compose.

Verificação via Nginx:

```
$ curl -I http://localhost
HTTP/1.1 200 OK
Server: nginx/1.27.5
Content-Type: text/html

$ curl -s http://localhost/api/info
{"aplicacao":"ufla-devops-shop","versao":"1.0.0","banco":"postgresql","cache":"redis","instancia":"9a7121d1e61d"}
```

## (b) Roteiro de persistência

POST do produto:

```
$ curl -s -X POST http://localhost/api/produtos -H 'Content-Type: application/json' \
    -d '{"nome":"Prova de persistencia","preco":9.9,"estoque":1}'
{"id":13,"nome":"Prova de persistencia","descricao":"","preco":9.9,"estoque":1,"criado_em":"2026-10-07T01:17:46.116250+00:00"}
```

Down (sem `-v`) e up:

```
$ docker compose down
 ✔ Container ufla-devops-shop-nginx-1 Removed
 ✔ Container ufla-devops-shop-api-1   Removed
 ✔ Container ufla-devops-shop-banco-1 Removed
 ✔ Container ufla-devops-shop-cache-1 Removed
 ✔ Network ufla-devops-shop_default   Removed

$ docker compose up -d --wait
 ✔ Network ufla-devops-shop_default   Created
 ✔ Container ufla-devops-shop-cache-1 Healthy
 ✔ Container ufla-devops-shop-banco-1 Healthy
 ✔ Container ufla-devops-shop-api-1   Healthy
 ✔ Container ufla-devops-shop-nginx-1 Healthy
```

O `down` removeu containers e rede, mas não o volume `ufla-devops-shop_dados-pg`.

Busca após o up:

```
$ curl -s 'http://localhost/api/busca?q=persistencia'
{"termo":"persistencia","total":1,"resultados":[{"id":13,"nome":"Prova de persistencia","descricao":"","preco":9.9,"estoque":1,"criado_em":"2026-10-07T01:17:46.116250+00:00"}]}
```

O produto (mesmo `id` e mesmo `criado_em`) sobreviveu à recriação dos containers, pois o PostgreSQL grava em um volume nomeado.

## (c) Imagem publicada

- Imagem: `ghcr.io/gabrielbarrosferreira/ufla-shop:1.0.0`
- Página do pacote: https://github.com/users/GabrielBarrosFerreira/packages/container/package/ufla-shop
- Digest: `sha256:23a057cacda644d580f2364d5f85e02ea8279c915fd4d28f33955f21b105b497`

Pacote público: o pull funciona sem credencial.

```
$ docker logout ghcr.io
$ docker pull ghcr.io/gabrielbarrosferreira/ufla-shop:1.0.0
Digest: sha256:23a057cacda644d580f2364d5f85e02ea8279c915fd4d28f33955f21b105b497
Status: Image is up to date for ghcr.io/gabrielbarrosferreira/ufla-shop:1.0.0
```

## (d) Por que `depends_on` sozinho não basta?

O `depends_on` sozinho só garante a ordem de início dos containers: o container do PostgreSQL é considerado iniciado em cerca de um segundo, mas o servidor ainda leva alguns segundos para aceitar conexões, e a API subiria nesse intervalo falhando com `connection refused`. O `condition: service_healthy` faz o Compose esperar o healthcheck do serviço passar (`pg_isready` no banco, `redis-cli ping` no cache) antes de iniciar a API, distinguindo "container iniciado" de "serviço pronto". Ainda assim, isso resolve apenas a inicialização: se o banco cair depois, a aplicação precisa saber reconectar.