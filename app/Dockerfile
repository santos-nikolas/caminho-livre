# Estagio 1: instala dependencias (ferramentas de build nao vao para a imagem final)
FROM python:3.12-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Estagio 2: runtime enxuto, sem segredos, usuario nao root
FROM python:3.12-slim
ARG GIT_SHA=dev
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 APP_VERSION=${GIT_SHA}
# Aplica patches de seguranca do SO que a imagem base ainda nao trouxe (barrado pelo Trivy: zlib1g CVE HIGH)
RUN apt-get update && apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app \
 && mkdir /data && chown 10001 /data
COPY --from=build /install /usr/local
WORKDIR /app
COPY main.py ./
COPY static ./static
USER 10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"]
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
