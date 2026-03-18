"""Authentication API endpoints."""

from __future__ import annotations

from fastapi import APIRouter

from app.auth.auth import (
    TokenResponse,
    UserLoginRequest,
    UserRegisterRequest,
    UserResponse,
    authenticate_user,
    create_access_token,
    create_user,
)

router = APIRouter(tags=["auth"])


@router.post("/auth/register", response_model=TokenResponse)
async def register(request: UserRegisterRequest) -> TokenResponse:
    """Register a new user account."""
    user = await create_user(request.email, request.password, request.name)
    token = create_access_token(user["id"], user["email"])
    return TokenResponse(
        access_token=token,
        user=UserResponse(
            id=user["id"],
            email=user["email"],
            name=user.get("name"),
            created_at=__import__("datetime").datetime.now(__import__("datetime").UTC),
        ),
    )


@router.post("/auth/login", response_model=TokenResponse)
async def login(request: UserLoginRequest) -> TokenResponse:
    """Login with email and password."""
    user = await authenticate_user(request.email, request.password)
    token = create_access_token(user["id"], user["email"])
    return TokenResponse(
        access_token=token,
        user=UserResponse(
            id=user["id"],
            email=user["email"],
            name=user.get("name"),
            created_at=user.get("created_at"),
        ),
    )
