"""Caminho Livre - API do MVP (relatos de barreiras de acessibilidade)."""
import hmac
import os
import re
import sqlite3
import time
from contextlib import asynccontextmanager, contextmanager
from enum import Enum
from uuid import UUID, uuid4

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.staticfiles import StaticFiles
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from pydantic import BaseModel, Field

# shortcut: SQLite num unico arquivo (a assinatura Azure Starter nao oferece Postgres); trocar por banco gerenciado se houver mais de 1 instancia
DATABASE_PATH = os.getenv("DATABASE_PATH", "/data/caminholivre.db")
ADMIN_TOKEN = os.environ["ADMIN_TOKEN"]
METRICS_TOKEN = os.environ["METRICS_TOKEN"]
APP_VERSION = os.getenv("APP_VERSION", "dev")
SEED_DEMO = os.getenv("SEED_DEMO", "true").lower() == "true"
# Territorio do piloto: entorno do campus FIAP Paulista (min_lat,min_lon,max_lat,max_lon)
BBOX = [float(v) for v in os.getenv("PILOT_BBOX", "-23.5700,-46.6600,-23.5590,-46.6450").split(",")]


class Categoria(str, Enum):
    calcada_obstruida = "calcada_obstruida"
    rampa_bloqueada = "rampa_bloqueada"
    travessia_barreira = "travessia_barreira"


class Status(str, Enum):
    pendente = "pendente"
    em_analise = "em_analise"
    resolvido = "resolvido"
    descartado = "descartado"


class NovoRelato(BaseModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    categoria: Categoria
    descricao: str | None = Field(default=None, max_length=280)


class Revisao(BaseModel):
    status: Status


SCHEMA = """
CREATE TABLE IF NOT EXISTS relatos (
  id TEXT PRIMARY KEY,
  criado_em TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  atualizado_em TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  categoria TEXT NOT NULL,
  descricao_sanitizada TEXT,
  status TEXT NOT NULL DEFAULT 'pendente',
  fonte TEXT NOT NULL DEFAULT 'cidadao'
);
CREATE TABLE IF NOT EXISTS historico_status (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  relato_id TEXT NOT NULL REFERENCES relatos(id),
  de TEXT NOT NULL,
  para TEXT NOT NULL,
  em TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  papel TEXT NOT NULL
);
"""

DEMO = [  # dados SINTETICOS de demonstracao, marcados com fonte='sintetico'
    (-23.5646, -46.6522, "rampa_bloqueada", "Rampa com entulho (dado de demonstracao)"),
    (-23.5628, -46.6551, "calcada_obstruida", "Mesas ocupando a calcada (dado de demonstracao)"),
    (-23.5661, -46.6497, "travessia_barreira", "Canteiro sem rebaixamento (dado de demonstracao)"),
]

EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")
PHONE = re.compile(r"\+?\d[\d\s().-]{7,}\d")
CPF = re.compile(r"\d{3}\.?\d{3}\.?\d{3}-?\d{2}")


def sanitizar(texto: str | None) -> str | None:
    """LGPD: remove contatos/documentos do texto livre e caracteres de controle."""
    if not texto:
        return None
    texto = "".join(c for c in texto if c.isprintable())
    for padrao in (EMAIL, CPF, PHONE):
        texto = padrao.sub("[removido]", texto)
    return texto.strip() or None


@contextmanager
def conectar():
    # autocommit; transacoes explicitas onde ha leitura + escrita (revisar)
    conn = sqlite3.connect(DATABASE_PATH, timeout=15, isolation_level=None)
    conn.row_factory = lambda cur, row: {col[0]: v for col, v in zip(cur.description, row)}
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
    finally:
        conn.close()


@asynccontextmanager
async def lifespan(_app):
    os.makedirs(os.path.dirname(DATABASE_PATH) or ".", exist_ok=True)
    with conectar() as conn:
        conn.executescript(SCHEMA)
        vazio = conn.execute("SELECT count(*) AS n FROM relatos").fetchone()["n"] == 0
        if SEED_DEMO and vazio:
            for lat, lon, cat, desc in DEMO:
                conn.execute(
                    "INSERT INTO relatos (id, latitude, longitude, categoria, descricao_sanitizada, fonte)"
                    " VALUES (?, ?, ?, ?, ?, 'sintetico')", (str(uuid4()), lat, lon, cat, desc))
    yield


app = FastAPI(title="Caminho Livre API", version=APP_VERSION, lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)

# --- 4 sinais de ouro: latencia, trafego, erros (label status) e saturacao (em andamento + process_*) ---
REQS = Counter("http_requests_total", "Requisicoes HTTP", ["method", "route", "status"])
LAT = Histogram("http_request_duration_seconds", "Latencia HTTP", ["method", "route"],
                buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5))
INPROG = Gauge("http_requests_in_progress", "Requisicoes em andamento")

CSP = ("default-src 'self'; script-src 'self' https://unpkg.com; style-src 'self' https://unpkg.com; "
       "img-src 'self' data: https://unpkg.com https://*.tile.openstreetmap.fr; connect-src 'self'; frame-ancestors 'none'")


@app.middleware("http")
async def observar(request: Request, call_next):
    INPROG.inc()
    inicio = time.perf_counter()
    status = 500
    try:
        resposta = await call_next(request)
        status = resposta.status_code
    finally:
        INPROG.dec()
        rota = getattr(request.scope.get("route"), "path", "nao_mapeada")
        LAT.labels(request.method, rota).observe(time.perf_counter() - inicio)
        REQS.labels(request.method, rota, str(status)).inc()
    resposta.headers.update({
        "Content-Security-Policy": CSP,
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "strict-origin-when-cross-origin",
        "Permissions-Policy": "geolocation=(self), camera=()",
    })
    return resposta


def exigir_token(esperado: str):
    def verificar(authorization: str = Header(default="")):
        if not hmac.compare_digest(authorization.encode(), f"Bearer {esperado}".encode()):
            raise HTTPException(status_code=401, detail="nao autorizado")
    return verificar


@app.get("/health")
def health():
    try:
        with conectar() as conn:
            conn.execute("SELECT 1")
    except sqlite3.Error:
        raise HTTPException(status_code=503, detail="banco indisponivel")
    return {"status": "ok", "version": APP_VERSION}


@app.get("/metrics", dependencies=[Depends(exigir_token(METRICS_TOKEN))])
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/config")
def config():
    return {"bbox": BBOX, "version": APP_VERSION}


@app.get("/api/reports")
def listar(categoria: Categoria | None = None, status: Status | None = None):
    with conectar() as conn:
        linhas = conn.execute(
            "SELECT id, criado_em, atualizado_em, latitude, longitude, categoria, descricao_sanitizada,"
            " status, fonte FROM relatos WHERE (:c IS NULL OR categoria = :c)"
            " AND (:s IS NULL OR status = :s) ORDER BY criado_em DESC LIMIT 500",
            {"c": categoria and categoria.value, "s": status and status.value}).fetchall()
    return {"atualizado_em": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "itens": linhas}


@app.post("/api/reports", status_code=201)
def criar(relato: NovoRelato):
    min_lat, min_lon, max_lat, max_lon = BBOX
    if not (min_lat <= relato.latitude <= max_lat and min_lon <= relato.longitude <= max_lon):
        raise HTTPException(status_code=422, detail="localizacao fora do territorio do piloto")
    rid = str(uuid4())
    with conectar() as conn:
        # LGPD: coordenada arredondada (~11 m) - localizacao aproximada, nao exata
        conn.execute(
            "INSERT INTO relatos (id, latitude, longitude, categoria, descricao_sanitizada) VALUES (?, ?, ?, ?, ?)",
            (rid, round(relato.latitude, 4), round(relato.longitude, 4), relato.categoria.value,
             sanitizar(relato.descricao)))
    return {"id": rid, "status": Status.pendente}


@app.patch("/api/admin/reports/{relato_id}", dependencies=[Depends(exigir_token(ADMIN_TOKEN))])
def revisar(relato_id: UUID, revisao: Revisao):
    rid = str(relato_id)
    with conectar() as conn:
        conn.execute("BEGIN IMMEDIATE")  # trava de escrita: leitura + update + historico atomicos
        try:
            atual = conn.execute("SELECT status FROM relatos WHERE id = ?", (rid,)).fetchone()
            if not atual:
                raise HTTPException(status_code=404, detail="relato nao encontrado")
            conn.execute("UPDATE relatos SET status = ?, atualizado_em = (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')) WHERE id = ?",
                         (revisao.status.value, rid))
            conn.execute("INSERT INTO historico_status (relato_id, de, para, papel) VALUES (?, ?, ?, 'gestor')",
                         (rid, atual["status"], revisao.status.value))
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
    return {"id": relato_id, "status": revisao.status}


app.mount("/", StaticFiles(directory=os.path.join(os.path.dirname(__file__), "static"), html=True), name="static")
