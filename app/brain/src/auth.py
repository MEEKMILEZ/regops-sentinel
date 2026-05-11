"""Cognito JWT verification.

The Brain is a private-ish service: the Window BFF (the only intended
caller) forwards the user's Cognito ID token as a Bearer credential.
We verify it here against Cognito's public JWKS and pull tenant_id from
the verified claims. We never trust tenant_id from a query parameter -
that would let any caller read any tenant's data.

Flow:
  1. Client (Window BFF) sends: Authorization: Bearer <id_token>
  2. Decode the JWT header to find the signing key id (kid)
  3. Look that kid up in Cognito's JWKS (cached for 1 hour)
  4. Verify signature, expiration, issuer, audience, token_use
  5. Return the verified claims as a small CurrentUser object
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Any, Dict

import httpx
import jwt
from cachetools import TTLCache
from fastapi import Depends, HTTPException, Request, status

logger = logging.getLogger(__name__)

# --- Configuration -------------------------------------------------------

# These can be overridden via env vars on the ECS task. Defaults match the
# pool the Window app is currently configured against.
COGNITO_REGION = os.environ.get("COGNITO_REGION", "ca-central-1")
COGNITO_USER_POOL_ID = os.environ.get(
    "COGNITO_USER_POOL_ID", "ca-central-1_3TjLuZRim"
)
COGNITO_APP_CLIENT_ID = os.environ.get(
    "COGNITO_APP_CLIENT_ID", "132om57mrn5k7433dcmt53mfof"
)

COGNITO_ISSUER = (
    f"https://cognito-idp.{COGNITO_REGION}.amazonaws.com/{COGNITO_USER_POOL_ID}"
)
COGNITO_JWKS_URL = f"{COGNITO_ISSUER}/.well-known/jwks.json"

# Cache the JWKS for an hour. Cognito rotates keys very rarely and signals
# rotation by changing the 'kid' in token headers; on a kid miss we refresh.
_jwks_cache: TTLCache[str, Dict[str, Any]] = TTLCache(maxsize=1, ttl=3600)


# --- JWKS retrieval ------------------------------------------------------

def _fetch_jwks() -> Dict[str, Any]:
    """Fetch the current JWKS document from Cognito."""
    logger.info("Fetching JWKS from %s", COGNITO_JWKS_URL)
    with httpx.Client(timeout=5.0) as client:
        resp = client.get(COGNITO_JWKS_URL)
        resp.raise_for_status()
        return resp.json()


def _get_jwks() -> Dict[str, Any]:
    """Get the JWKS, using cache when possible."""
    cached = _jwks_cache.get("jwks")
    if cached is not None:
        return cached
    fresh = _fetch_jwks()
    _jwks_cache["jwks"] = fresh
    return fresh


def _get_signing_key(kid: str) -> Any:
    """Look up the public key for a given key id, refreshing JWKS on miss."""
    jwks = _get_jwks()
    for key in jwks.get("keys", []):
        if key.get("kid") == kid:
            return jwt.algorithms.RSAAlgorithm.from_jwk(key)
    # Cache miss - the kid might be from a rotated key set. Refresh once.
    logger.info("kid %s not in cached JWKS, refreshing", kid)
    _jwks_cache.pop("jwks", None)
    jwks = _get_jwks()
    for key in jwks.get("keys", []):
        if key.get("kid") == kid:
            return jwt.algorithms.RSAAlgorithm.from_jwk(key)
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="unknown_signing_key",
    )


# --- Token verification -------------------------------------------------

def verify_token(token: str) -> Dict[str, Any]:
    """Validate a Cognito ID token and return its claims."""
    try:
        header = jwt.get_unverified_header(token)
    except jwt.InvalidTokenError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"malformed_token: {e}",
        )

    kid = header.get("kid")
    if not kid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="missing_kid",
        )

    key = _get_signing_key(kid)

    try:
        claims = jwt.decode(
            token,
            key=key,
            algorithms=["RS256"],
            audience=COGNITO_APP_CLIENT_ID,
            issuer=COGNITO_ISSUER,
            options={"require": ["exp", "iss", "aud", "sub", "token_use"]},
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="token_expired",
        )
    except jwt.InvalidAudienceError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid_audience",
        )
    except jwt.InvalidIssuerError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid_issuer",
        )
    except jwt.InvalidTokenError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"invalid_token: {e}",
        )

    # Cognito issues both access tokens and id tokens. For our purposes
    # (reading custom:tenant_id, which only lives on id tokens) we require
    # token_use == "id". Access tokens are rejected.
    if claims.get("token_use") != "id":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="wrong_token_use",
        )

    return claims


# --- FastAPI dependency -------------------------------------------------

@dataclass(frozen=True)
class CurrentUser:
    sub: str
    email: str
    tenant_id: str
    tenant_role: str


def current_user(request: Request) -> CurrentUser:
    """Extract and verify the user's ID token from the Authorization header."""
    auth_header = request.headers.get("authorization")
    if not auth_header:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="missing_authorization",
            headers={"WWW-Authenticate": "Bearer"},
        )

    scheme, _, token = auth_header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid_authorization_scheme",
            headers={"WWW-Authenticate": "Bearer"},
        )

    claims = verify_token(token)

    tenant_id = claims.get("custom:tenant_id")
    if not tenant_id:
        # A valid token without a tenant_id claim is unusable for tenant-
        # scoped queries. Reject rather than fall back to a default tenant.
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="missing_tenant_id_claim",
        )

    return CurrentUser(
        sub=claims["sub"],
        email=claims.get("email", ""),
        tenant_id=tenant_id,
        tenant_role=claims.get("custom:tenant_role", ""),
    )
