from fastapi.testclient import TestClient


def test_health_check(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] in ("ok", "degraded")
    assert "services" in data


def test_openapi_docs(client: TestClient) -> None:
    response = client.get("/docs")
    assert response.status_code == 200


def test_sources_endpoint(client: TestClient) -> None:
    response = client.get("/api/v1/sources")
    assert response.status_code == 200
    data = response.json()
    assert "sources" in data
    assert len(data["sources"]) >= 10  # API-based connectors (scrapers removed)
    # Verify source structure
    source = data["sources"][0]
    assert "name" in source
    assert "tier" in source
    assert "requires_auth" in source
    assert "description" in source
    assert "status" in source


def test_saved_investigations_empty(client: TestClient) -> None:
    response = client.get("/api/v1/saved-investigations")
    assert response.status_code == 200


def test_search_endpoint(client: TestClient) -> None:
    response = client.post(
        "/api/v1/search",
        json={"query": "test", "limit": 10},
    )
    assert response.status_code == 200
    data = response.json()
    assert "results" in data
    assert "total" in data


def test_create_investigation(client: TestClient) -> None:
    response = client.post(
        "/api/v1/investigation",
        json={
            "address": {
                "street": "123 Main St",
                "city": "Lawrenceville",
                "state": "GA",
                "zip": "30043",
            }
        },
    )
    assert response.status_code == 200
    data = response.json()
    assert "id" in data
    assert data["status"] == "initializing"
    assert "Lawrenceville" in data["address"]
