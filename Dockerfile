# ---------- Estágio 1: instalar as dependências ----------
FROM python:3.12-alpine AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---------- Estágio 2: imagem final ----------
FROM python:3.12-alpine

RUN adduser -D -u 10001 ufla-shop \
 && mkdir -p /opt/ufla-shop \
 && chown ufla-shop /opt/ufla-shop

WORKDIR /opt/ufla-shop

COPY --from=builder /install /usr/local
COPY app/ app/
COPY static/ static/

USER ufla-shop

EXPOSE 8000

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]

CMD ["uvicorn", "app:api", "--host", "0.0.0.0", "--port", "8000"]