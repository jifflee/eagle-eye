from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # Backend
    backend_host: str = "0.0.0.0"
    backend_port: int = 8000
    backend_cors_origins: str = "http://localhost:5173"
    log_level: str = "INFO"

    # Neo4j
    neo4j_uri: str = "bolt://localhost:7687"
    neo4j_user: str = "neo4j"
    neo4j_password: str = "password"

    # PostgreSQL
    database_url: str = "postgresql://eagle_eye:password@localhost:5432/eagle_eye"

    # Redis
    redis_url: str = "redis://localhost:6379/0"

    # JWT Authentication
    jwt_secret: str = "eagle-eye-dev-secret-change-in-production"

    # Optional API keys
    google_places_api_key: str = ""
    hunter_io_api_key: str = ""
    numverify_api_key: str = ""
    census_api_key: str = ""

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8", "extra": "ignore"}


settings = Settings()
