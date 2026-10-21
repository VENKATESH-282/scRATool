import re
import secrets
from typing import Tuple

# 32-character unambiguous alphabet (no 0/O, no 1/I/L)
UNAMBIGUOUS_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
TOKEN_PATTERN = re.compile(r"^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}$")
VIEW_TOKEN_PATTERN = re.compile(r"^V-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}$")

def generate_raw_token_chars(length: int = 16) -> str:
    return "".join(secrets.choice(UNAMBIGUOUS_ALPHABET) for _ in range(length))

def generate_session_tokens() -> Tuple[str, str]:
    """
    Generates a pair of (write_token, read_only_view_token).
    Write token: 16 chars from 32-char alphabet, grouped 4-4-4-4 (80 bits entropy).
    View token: distinct 16 chars prefixed with 'V-'.
    """
    raw_write = generate_raw_token_chars(16)
    write_token = f"{raw_write[0:4]}-{raw_write[4:8]}-{raw_write[8:12]}-{raw_write[12:16]}"

    raw_view = generate_raw_token_chars(16)
    view_token = f"V-{raw_view[0:4]}-{raw_view[4:8]}-{raw_view[8:12]}-{raw_view[12:16]}"

    return write_token, view_token

def is_valid_token_format(token: str) -> bool:
    if not token or not isinstance(token, str):
        return False
    clean = token.strip().upper()
    return bool(TOKEN_PATTERN.match(clean) or VIEW_TOKEN_PATTERN.match(clean))

def normalize_token(token: str) -> str:
    return token.strip().upper()
