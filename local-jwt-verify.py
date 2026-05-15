"""Local validation of the multi-audience JWT verification logic.

This script reproduces what auth.py does, OUTSIDE the brain container, to
prove whether the patched logic correctly accepts JWTs from the CLI client.

Run it with: py local-jwt-verify.py
You'll be prompted for password (visible - it's a local test only).
"""

from __future__ import annotations

import getpass
import json
import sys
import urllib.request

# --- Constants (locked from earlier diagnostic) ---
COGNITO_REGION = "ca-central-1"
COGNITO_USER_POOL_ID = "ca-central-1_3TjLuZRim"
COGNITO_WEB_CLIENT_ID = "132om57mrn5k7433dcmt53mfof"
COGNITO_CLI_CLIENT_ID = "1ugh2hn13j004m59p2kh530hbc"
USERNAME = "meek@acme-meddev.test"

COGNITO_ISSUER = (
    f"https://cognito-idp.{COGNITO_REGION}.amazonaws.com/{COGNITO_USER_POOL_ID}"
)
COGNITO_JWKS_URL = f"{COGNITO_ISSUER}/.well-known/jwks.json"


def fail(msg: str) -> None:
    print(f"\nFAIL: {msg}")
    sys.exit(1)


def main() -> None:
    # Check pyjwt is available
    try:
        import jwt
    except ImportError:
        fail("pyjwt not installed. Run: pip install pyjwt cryptography")

    print("This is a LOCAL test - your password stays on this machine.")
    password = getpass.getpass("Cognito password: ")

    # --- Get a JWT via boto3 (same as the PowerShell script) ---
    try:
        import boto3
    except ImportError:
        fail("boto3 not installed. Run: pip install boto3")

    client = boto3.client("cognito-idp", region_name=COGNITO_REGION)
    print("\n==> Calling initiate_auth on CLI client...")
    resp = client.initiate_auth(
        AuthFlow="USER_PASSWORD_AUTH",
        ClientId=COGNITO_CLI_CLIENT_ID,
        AuthParameters={"USERNAME": USERNAME, "PASSWORD": password},
    )

    if "ChallengeName" in resp:
        if resp["ChallengeName"] != "SOFTWARE_TOKEN_MFA":
            fail(f"Unexpected challenge: {resp['ChallengeName']}")
        code = input("Enter 6-digit TOTP code: ").strip()
        resp = client.respond_to_auth_challenge(
            ClientId=COGNITO_CLI_CLIENT_ID,
            ChallengeName="SOFTWARE_TOKEN_MFA",
            Session=resp["Session"],
            ChallengeResponses={
                "USERNAME": USERNAME,
                "SOFTWARE_TOKEN_MFA_CODE": code,
            },
        )

    id_token = resp["AuthenticationResult"]["IdToken"]
    print(f"    Got ID token, length {len(id_token)}")

    # --- Decode header to see kid + aud ---
    header = jwt.get_unverified_header(id_token)
    unverified_claims = jwt.decode(id_token, options={"verify_signature": False})
    print(f"\n==> Token header: alg={header.get('alg')}, kid={header.get('kid')}")
    print(f"==> Token aud claim:  {unverified_claims.get('aud')}")
    print(f"==> Token iss claim:  {unverified_claims.get('iss')}")
    print(f"==> Token use:        {unverified_claims.get('token_use')}")

    # --- Fetch JWKS and find signing key ---
    print(f"\n==> Fetching JWKS from {COGNITO_JWKS_URL}")
    with urllib.request.urlopen(COGNITO_JWKS_URL, timeout=10) as r:
        jwks = json.load(r)

    signing_key = None
    for key in jwks.get("keys", []):
        if key.get("kid") == header["kid"]:
            signing_key = jwt.algorithms.RSAAlgorithm.from_jwk(key)
            break
    if signing_key is None:
        fail(f"Could not find signing key for kid {header['kid']} in JWKS")

    # --- THE ACTUAL TEST: decode with audience as a list ---
    print("\n==> Test 1: decode with audience=[WEB_CLIENT_ID, CLI_CLIENT_ID] (the patched logic)")
    try:
        claims = jwt.decode(
            id_token,
            key=signing_key,
            algorithms=["RS256"],
            audience=[COGNITO_WEB_CLIENT_ID, COGNITO_CLI_CLIENT_ID],
            issuer=COGNITO_ISSUER,
            options={"require": ["exp", "iss", "aud", "sub", "token_use"]},
        )
        print(f"    PASS - decoded OK. sub={claims.get('sub')[:8]}..., tenant_id={claims.get('custom:tenant_id')}")
    except jwt.PyJWTError as e:
        print(f"    FAIL - {type(e).__name__}: {e}")
        print("    => Patched audience-list logic is broken. We need to investigate.")
        sys.exit(1)

    # --- Test 2: with web-only audience, to prove it would have failed before the patch ---
    print("\n==> Test 2: decode with audience=WEB_CLIENT_ID only (the pre-patch logic)")
    try:
        jwt.decode(
            id_token,
            key=signing_key,
            algorithms=["RS256"],
            audience=COGNITO_WEB_CLIENT_ID,
            issuer=COGNITO_ISSUER,
            options={"require": ["exp", "iss", "aud", "sub", "token_use"]},
        )
        print("    PASS - decoded OK. (Unexpected - means our token's aud already matched web client somehow.)")
    except jwt.InvalidAudienceError as e:
        print(f"    Rejected as expected: {e}")
        print("    => This is what the brain is doing right now if the env var isn't loaded.")
    except jwt.PyJWTError as e:
        print(f"    Other error: {type(e).__name__}: {e}")

    # --- Test 3: parse the actual env var the brain would see ---
    print("\n==> Test 3: simulate brain's env var parsing")
    # Reproduce auth.py's list-comprehension logic exactly
    raw_env = f"{COGNITO_WEB_CLIENT_ID},{COGNITO_CLI_CLIENT_ID}"
    parsed = [s.strip() for s in raw_env.split(",") if s.strip()]
    print(f"    Raw env value:    '{raw_env}'")
    print(f"    Parsed to list:   {parsed}")
    print(f"    Length:           {len(parsed)}")
    if len(parsed) == 2 and parsed[1] == COGNITO_CLI_CLIENT_ID:
        print("    PASS - parsing logic produces correct list")
    else:
        print("    FAIL - parsing logic is wrong")

    print("\n==> All local tests done.")
    print("If Test 1 PASSED, the patched logic is correct. The brain's 401 must")
    print("be because the env var isn't actually being read by the running container.")


if __name__ == "__main__":
    main()
