"""将原始图标 PNG 打包为 ICNS，不进行重采样。"""

import pathlib, struct, sys

source, output = map(pathlib.Path, sys.argv[1:])
entries = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 256),
    ("ic14", 512),
]
body = bytearray()
for tag, size in entries:
    data = (source / f"icon-{size}.png").read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    assert struct.unpack(">II", data[16:24]) == (size, size)
    body.extend(tag.encode() + struct.pack(">I", len(data) + 8) + data)
output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
