# Atividade 4 — Containerizar a aplicação

Imagem Docker do `ufla-devops-shop`, construída em três versões até chegar à final (`ufla-shop:1.0`).

## Como construir e rodar

```bash
docker build -t ufla-shop:1.0 .
docker run -d --name loja -p 8000:8000 ufla-shop:1.0
curl -sS localhost:8000/health
```

Nesta atividade a aplicação roda sem variáveis de ambiente (SQLite + cache em memória).

---

## 1. Tamanho antes e depois

Saída de `docker images ufla-shop`:

```
IMAGE           ID             DISK USAGE   CONTENT SIZE   EXTRA
ufla-shop:1.0   ab828f686860        139MB         32.6MB
ufla-shop:v1    e47132eaa733        455MB         74.8MB
ufla-shop:v2    e4672b68fd0e        260MB         62.3MB
```

**Como ler esses números.** Nesta versão do Docker (29), `CONTENT SIZE` é o tamanho **compactado** (o que trafega num pull) e `DISK USAGE` soma o compactado com o descompactado guardados em disco. O tamanho **descompactado** da imagem, que é o usado no `docs/aplicacao.md`, foi obtido somando as camadas do `docker history`:

| Versão | Descompactada (soma do `docker history`) | Compactada (`CONTENT SIZE`) |
|---|---|---|
| v1 — primeira que funcionou | **~380 MB** | 74.8 MB |
| v2 — COPY e chown corrigidos | ~198 MB | 62.3 MB |
| **1.0 — final** | **~106 MB** | **32.6 MB** |

A conta confere: descompactada + compactada ≈ `DISK USAGE` (380 + 75 ≈ 455; 198 + 62 ≈ 260; 106 + 33 ≈ 139).

---

## 2. O que mudou e quanto cada mudança economizou

### v1 → v2: −182 MB

Camadas da v1 (`docker history ufla-shop:v1`):

```
RUN /bin/sh -c useradd --create-home ufla-sh…   91.2MB
COPY . . # buildkit                             91.2MB
RUN /bin/sh -c pip install --no-cache-dir -r…   55.4MB
```

| Mudança | Economia | Por quê |
|---|---|---|
| `COPY . .` → `COPY app/ app/` + `COPY static/ static/` | ~91 MB | O `COPY . .` levava a pasta `dados/` (87 MB de logs) e outros arquivos que a aplicação não usa (`docs/`, `scripts/`, `.github/`, `README.md`...). Copiar por lista branca garante que só entra o que a aplicação precisa. O código copiado passou de 91.2 MB para 86 KB. |
| `chown -R` em tudo → `chown` só da pasta | ~91 MB | Camadas são imutáveis: mudar o dono de um arquivo numa camada posterior **regrava o arquivo inteiro** numa camada nova. Por isso a camada do `chown -R` tinha exatamente o mesmo tamanho do `COPY . .`. A aplicação só precisa escrever o `loja.db` na pasta de trabalho, então basta ser dona da **pasta**; o código continua com dono root e fica somente leitura para ela. A camada caiu de 91.2 MB para 12.3 kB. |

Na v2 também: o usuário passou a ser criado no topo do Dockerfile (camada estável, aproveitada pelo cache) e com UID fixo `10001`, para não coincidir com o UID 1000 do usuário do host.

### v2 → 1.0: −92 MB

Camadas da 1.0 (`docker history ufla-shop:1.0`):

```
COPY static/ static/ # buildkit                 28.7kB
COPY app/ app/ # buildkit                       57.3kB
COPY /install /usr/local # buildkit             43.9MB
WORKDIR /opt/ufla-shop                          4.1kB
RUN /bin/sh -c adduser -D -u 10001 ufla-shop…   49.2kB
```

| Mudança | Economia | Por quê |
|---|---|---|
| Base `python:3.12-slim` → `python:3.12-alpine` | ~80 MB | A base slim (Debian) soma ~142 MB de camadas; a Alpine soma ~62 MB. O alerta do slide sobre o Alpine (musl em vez de glibc) não se aplica aqui: todas as dependências do projeto têm wheels prontos para musl, então nada precisa ser compilado. |
| Dependências instaladas num estágio `builder` e copiadas com `COPY --from` | ~11 MB | As dependências caíram de 55.4 MB para 43.9 MB. A maior parte dessa diferença vem dos pacotes compilados para Alpine serem menores, **não do multi-stage em si**: como nenhuma dependência é compilada, o builder deixa pouco lixo para trás. O multi-stage está lá porque deixa a imagem preparada — se entrar uma dependência que precise de compilador, ele fica no builder e a imagem final não cresce. |

Detalhes de implementação da 1.0:

- `pip install --prefix=/install` junta todas as dependências numa pasta só, com a mesma estrutura de `/usr/local`; o `COPY --from=builder /install /usr/local` as coloca onde o Python procura, sem precisar alterar o `PATH`.
- Os dois estágios usam Alpine: pacotes instalados sobre glibc (Debian) não funcionariam numa base musl.
- No Alpine não existe `useradd`; o equivalente é `adduser -D`.

---

## 3. Verificação

```
$ docker run --rm ufla-shop:1.0 id -u
10001

$ docker inspect --format '{{.State.Health.Status}}' loja
healthy

$ curl -sS localhost:8000/health
{"status":"ok","versao":"1.0.0"}

$ curl -sS localhost:8000/api/produtos | python3 -c "import sys, json; print(len(json.load(sys.stdin)))"
12

$ docker run --rm ufla-shop:1.0 ls -a
.
..
app
static

$ time docker stop loja
loja

real    0m0.305s
user    0m0.005s
sys     0m0.002s
```

O `docker stop` termina em 0,3 s porque o `CMD` está na forma exec: o `uvicorn` é o PID 1 e recebe o `SIGTERM` diretamente, sem um `/bin/sh` no meio engolindo o sinal.

O `HEALTHCHECK` usa o próprio Python (`urllib.request`), porque a imagem Alpine não tem `curl`, e consulta `127.0.0.1:8000`, já que roda dentro do container. O intervalo é de 5 s para que o container já esteja `healthy` aos 10 s da verificação.

---

## 4. Por que o HEALTHCHECK consulta `/health` e não `/ready`?

O `/health` responde se **o próprio processo** está vivo e atendendo, enquanto o `/ready` também verifica as dependências externas (banco e cache). Se o HEALTHCHECK usasse o `/ready`, uma queda do PostgreSQL marcaria como `unhealthy` um container que está perfeitamente saudável — e um orquestrador que reinicia containers doentes ficaria reiniciando a API sem resolver nada, já que o problema está no banco.