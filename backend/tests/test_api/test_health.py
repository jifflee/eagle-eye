from fastapi.testclient import TestClient


def test_health_check(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_openapi_docs(client: TestClient) -> None:
    response = client.get("/docs")
    assert response.status_code == 200


def test_investigation_endpoints_exist(client: TestClient) -> None:
    response = client.post("/api/v1/investigation")
    assert response.status_code == 200

    response = client.get("/api/v1/saved-investigations")
    assert response.status_code == 200


def test_search_endpoint_exists(client: TestClient) -> None:
    response = client.post("/api/v1/search")
    assert response.status_code == 200


def test_sources_endpoint_exists(client: TestClient) -> None:
    response = client.get("/api/v1/sources")
    assert response.status_code == 200
