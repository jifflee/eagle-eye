"""JWT authentication — user registration, login, and token validation."""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID, uuid4

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from passlib.context import CryptContext
from pydantic import BaseModel, EmailStr

from app.config import settings
from app.database import postgres_client

logger = logging.getLogger(__name__)

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
security = HTTPBearer(auto_error=False)

# JWT settings
JWT_SECRET = settings.jwt_secret
JWT_ALGORITHM = "HS256"
JWT_EXPIRATION_HOURS = 24


# === Models ===


class UserRegisterRequest(BaseModel):
    email: str
    password: str
    name: str | None = None


class UserLoginRequest(BaseModel):
    email: str
    password: str


class UserResponse(BaseModel):
    id: UUID
    email: str
    name: str | None
    created_at: datetime


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int = JWT_EXPIRATION_HOURS * 3600
    user: UserResponse


# === Password Hashing ===


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


# === JWT Tokens ===


def create_access_token(user_id: UUID, email: str) -> str:
    """Create a JWT access token."""
    payload = {
        "sub": str(user_id),
        "email": email,
        "iat": datetime.now(UTC),
        "exp": datetime.now(UTC) + timedelta(hours=JWT_EXPIRATION_HOURS),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def decode_token(token: str) -> dict[str, Any]:
    """Decode and validate a JWT token."""
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token expired",
        )
    except jwt.InvalidTokenError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token",
        )


# === Dependencies ===


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
) -> dict[str, Any] | None:
    """FastAPI dependency — returns current user or None if not authenticated.

    Routes that require auth should check if user is None and raise 401.
    Routes that are optionally authenticated can use the user if present.
    """
    if credentials is None:
        return None

    payload = decode_token(credentials.credentials)
    return {
        "id": payload["sub"],
        "email": payload["email"],
    }


async def require_auth(
    user: dict[str, Any] | None = Depends(get_current_user),
) -> dict[str, Any]:
    """FastAPI dependency — requires authentication. Raises 401 if not authenticated."""
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user


# === User Operations (PostgreSQL) ===


async def create_user(email: str, password: str, name: str | None = None) -> dict[str, Any]:
    """Create a new user."""
    user_id = uuid4()
    hashed = hash_password(password)
    pool = await postgres_client.get_pool()
    async with pool.acquire() as conn:
        # Check if email already exists
        existing = await conn.fetchrow(
            "SELECT id FROM users WHERE email = $1", email
        )
        if existing:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Email already registered",
            )

        await conn.execute(
            """
            INSERT INTO users (id, email, password_hash, name)
            VALUES ($1, $2, $3, $4)
            """,
            user_id, email, hashed, name,
        )

    return {"id": user_id, "email": email, "name": name}


async def authenticate_user(email: str, password: str) -> dict[str, Any]:
    """Authenticate a user by email and password."""
    pool = await postgres_client.get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, email, password_hash, name, created_at FROM users WHERE email = $1",
            email,
        )

    if not row:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password",
        )

    if not verify_password(password, row["password_hash"]):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password",
        )

    return dict(row)
