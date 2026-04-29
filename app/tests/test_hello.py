from fastapi.testclient import TestClient
from hello.main import app

client = TestClient(app)

def test_hello():
    r = client.get("/")
    assert r.status_code == 200
    assert r.json()["message"] == "hello world"

def test_healthz():
    assert client.get("/healthz").json() == {"ok": True}