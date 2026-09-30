"""Bearer-token validation for home-mcp (ADR-0021).

Authentik is the authorization server. Its access tokens are signed JWTs
carrying the same claims as the ID token (iss, sub, aud=client_id, exp,
preferred_username, scope) -- see authentik/providers/oauth2/id_token.py's
to_access_token -- so every token is verified locally against the
provider's JWKS, no per-request call to Authentik.

This server never trusts Traefik (IP allowlist) or Authentik's own
application policy alone: it re-checks issuer, audience, expiry and the
username on every request itself.
"""

import logging
import time

import jwt
from mcp.server.auth.provider import AccessToken

log = logging.getLogger("home-mcp.auth")


class AuthentikTokenVerifier:
    def __init__(self, *, issuer: str, jwks_url: str, client_id: str, allowed_usernames: set[str]):
        self.issuer = issuer
        self.client_id = client_id
        self.allowed_usernames = allowed_usernames
        # PyJWKClient caches keys and refetches on an unknown kid, so a key
        # rotation in Authentik is picked up without a restart.
        self._jwks = jwt.PyJWKClient(jwks_url, cache_keys=True, lifespan=3600)

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            signing_key = self._jwks.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256", "ES256"],
                audience=self.client_id,
                issuer=self.issuer,
                options={"require": ["exp", "iss", "aud", "sub"]},
            )
        except jwt.PyJWTError as exc:
            log.warning("rejected token: %s", exc)
            return None

        username = claims.get("preferred_username")
        if username not in self.allowed_usernames:
            log.warning("rejected token for user %r (not allowed)", username)
            return None

        scopes = claims.get("scope", "")
        return AccessToken(
            token=token,
            client_id=claims.get("azp", self.client_id),
            scopes=scopes.split() if isinstance(scopes, str) else list(scopes),
            expires_at=int(claims["exp"]),
            subject=claims["sub"],
            claims={"iss": claims["iss"], "preferred_username": username, "verified_at": int(time.time())},
        )
