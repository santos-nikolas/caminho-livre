"""Testes de integracao: exigem Postgres em DATABASE_URL (servico no CI / docker compose)."""
import os

os.environ.setdefault("ADMIN_TOKEN", "token-admin-teste")
os.environ.setdefault("METRICS_TOKEN", "token-metricas-teste")

from fastapi.testclient import TestClient  # noqa: E402

from main import app, sanitizar  # noqa: E402

ADMIN = {"Authorization": f"Bearer {os.environ['ADMIN_TOKEN']}"}
DENTRO = {"latitude": -23.56421, "longitude": -46.65271, "categoria": "rampa_bloqueada"}


def test_fluxo_cidadao_e_gestor():
    with TestClient(app) as c:
        assert c.get("/health").json()["status"] == "ok"
        r = c.post("/api/reports", json={**DENTRO, "descricao": "Rampa bloqueada, ligar 11 98765-4321"})
        assert r.status_code == 201 and r.json()["status"] == "pendente"
        rid = r.json()["id"]
        item = next(i for i in c.get("/api/reports").json()["itens"] if i["id"] == rid)
        assert item["latitude"] == -23.5642  # coordenada aproximada (LGPD)
        assert "98765" not in item["descricao_sanitizada"]
        assert c.patch(f"/api/admin/reports/{rid}", json={"status": "resolvido"}, headers=ADMIN).status_code == 200
        assert c.get("/api/reports", params={"status": "resolvido"}).json()["itens"][0]["id"] == rid


def test_validacoes_e_autorizacao():
    with TestClient(app) as c:
        fora = c.post("/api/reports", json={**DENTRO, "latitude": -22.9})
        assert fora.status_code == 422
        assert c.post("/api/reports", json={**DENTRO, "categoria": "buraco"}).status_code == 422
        rid = c.post("/api/reports", json=DENTRO).json()["id"]
        assert c.patch(f"/api/admin/reports/{rid}", json={"status": "resolvido"}).status_code == 401
        assert c.patch(f"/api/admin/reports/{rid}", json={"status": "resolvido"},
                       headers={"Authorization": "Bearer errado"}).status_code == 401


def test_metricas_protegidas_e_sinais_de_ouro():
    with TestClient(app) as c:
        assert c.get("/metrics").status_code == 401
        c.get("/api/reports")
        corpo = c.get("/metrics", headers={"Authorization": f"Bearer {os.environ['METRICS_TOKEN']}"}).text
        for m in ("http_requests_total", "http_request_duration_seconds_bucket", "http_requests_in_progress"):
            assert m in corpo
        assert 'route="/api/reports"' in corpo


def test_cabecalhos_de_seguranca():
    with TestClient(app) as c:
        h = c.get("/").headers
        assert "default-src 'self'" in h["content-security-policy"]
        assert h["x-content-type-options"] == "nosniff"


def test_sanitizar():
    assert sanitizar("mail a@b.com cpf 123.456.789-00") == "mail [removido] cpf [removido]"
    assert sanitizar("   ") is None
