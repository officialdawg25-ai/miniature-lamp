"""Run once on the execution host. Prints a new host secret and its SHA-256 hash.

Keep the secret on this machine (environment variable HOST_TOKEN). Send only the hash to whoever registers the host.
The secret is shown once and is not stored by this script.
"""
import hashlib
import secrets

token = secrets.token_urlsafe(48)
print("HOST_TOKEN (keep on this machine only):")
print(token)
print()
print("TOKEN_HASH (safe to share, used to register this host):")
print(hashlib.sha256(token.encode()).hexdigest())
