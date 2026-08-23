from __future__ import annotations

import base64
import json
import struct

RPACK_MAP_B64 = (
    "xA0eC70rP1X8RW71ZlNPGuC7MJSGumu/QVBvm+/etxBhFyDfMomonW2ryZAA"
    "DF2v0sFW5RZkkYJldJfKI9ZS0f+0oOgvilg4WmAZlknb18g7PkNLpWNHqmop"
    "kvQVz2I0eNMdPOIFjipXDhvNTC3yQCwleUgPsnq1p2w35px7VH7+h9yaAuQz"
    "ouuxLgPdmaaw59WIGIN89r7hXJ/DIUYfCE7QdhJf7v2PROqjXosoCTWeacwK"
    "x4UHrUrzd+ln1NqEgJO2TXP6JyZ/BMb78XI5UcI2qWis+O3FucvOdaQ9gdlC"
    "cByVEbzYjJj5WaET9xR9s+xxwOON8AGuWzEGJCI6uCz3hIvJZfu2n66zAy0B"
    "aXQf5KPs7lw0IZNKD2riYgKeIpz9PPxxx8atWWcFcG2KRBL6JIZfr9F6R87+"
    "UGPdUQZvGOBSqAmdVnNMuFNsw6AOGc8+DX4HMmhG6kj5mS6rpEkgXlU1OAy8"
    "07FYFnkoChrh8s3EOduiumBydn2V73/IwN43lL+1FIGSJUWs5/Vmpys2WsET"
    "40s66I2DG3wnsJpC64eq3FSOeCbSVynUt/gvj4l18EF3wh7/2BUR5QSXF/Mx"
    "0JsA18q0Tyo72bJr2l2hPzBhvZE9Tubfvk2CjB0jEJhk9IUze5BDu6mI8dal"
    "HPbMbrlbC5bt1enFywimgEA="
)


class RPackError(ValueError):
    pass


def _maps() -> tuple[bytes, bytes]:
    data = base64.b64decode(RPACK_MAP_B64)
    if len(data) != 512:
        raise RPackError("invalid RPack map")
    return data[:256], data[256:]


def encode(data: bytes) -> bytes:
    enc, _ = _maps()
    return bytes(enc[b] for b in data)


def decode(data: bytes) -> bytes:
    _, dec = _maps()
    return bytes(dec[b] for b in data)


def pack_module(module: dict) -> bytes:
    raw = json.dumps(
        {"module": module, "type": "risuModule"},
        ensure_ascii=False,
        indent=2,
    ).encode("utf-8")
    payload = encode(raw)
    return b"o\x00" + struct.pack("<I", len(payload)) + payload + b"\x00"


def unpack_module(data: bytes) -> dict:
    if len(data) < 7 or data[:2] != b"o\x00":
        raise RPackError("invalid module magic/version")
    length = struct.unpack_from("<I", data, 2)[0]
    end = 6 + length
    if end >= len(data) or data[end:] != b"\x00":
        raise RPackError("invalid module framing")
    obj = json.loads(decode(data[6:end]).decode("utf-8"))
    if obj.get("type") != "risuModule" or not isinstance(obj.get("module"), dict):
        raise RPackError("invalid module payload")
    return obj["module"]
