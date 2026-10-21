import pytest
import re
from app.tokens import (
    generate_session_tokens,
    is_valid_token_format,
    normalize_token,
    UNAMBIGUOUS_ALPHABET,
    TOKEN_PATTERN,
    VIEW_TOKEN_PATTERN
)

def test_alphabet_unambiguity():
    # Verify no ambiguous characters: 0, O, 1, I, L
    forbidden = {"0", "O", "1", "I", "L"}
    for char in forbidden:
        assert char not in UNAMBIGUOUS_ALPHABET, f"Found forbidden char {char} in alphabet"
    assert len(UNAMBIGUOUS_ALPHABET) in [31, 32]

def test_generate_session_tokens():
    write_token, view_token = generate_session_tokens()

    # Write token check
    assert re.match(r"^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}$", write_token)
    assert len(write_token) == 19 # 16 chars + 3 dashes
    assert is_valid_token_format(write_token) is True

    # View token check
    assert view_token.startswith("V-")
    assert re.match(r"^V-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}$", view_token)
    assert len(view_token) == 21 # 'V-' + 19
    assert is_valid_token_format(view_token) is True

def test_token_normalization():
    raw = "  k7m2-q9xd-4tpa-r8wc \n"
    norm = normalize_token(raw)
    assert norm == "K7M2-Q9XD-4TPA-R8WC"
    assert is_valid_token_format(norm) is True

    view_raw = " v-k7m2-q9xd-4tpa-r8wc "
    view_norm = normalize_token(view_raw)
    assert view_norm == "V-K7M2-Q9XD-4TPA-R8WC"
    assert is_valid_token_format(view_norm) is True

def test_invalid_tokens():
    assert is_valid_token_format("INVALID-TOKEN") is False
    assert is_valid_token_format("0123-4567-89AB-CDEF") is False # contains 0, 1
    assert is_valid_token_format("K7M2-Q9XD-4TPA-R8WO") is False # contains O
    assert is_valid_token_format("K7M2-Q9XD-4TPA-R8WI") is False # contains I
    assert is_valid_token_format("K7M2-Q9XD-4TPA-R8WL") is False # contains L
    assert is_valid_token_format("K7M2Q9XD4TPAR8WC") is False    # missing dashes
    assert is_valid_token_format("") is False
