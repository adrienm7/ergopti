"""Build real PNG scanlines and run the pixel action's exact Python program."""

import binascii
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib


def chunk(kind, body):
    """Encode an independently framed PNG chunk, including its CRC."""
    return (
        struct.pack(">I", len(body)) + kind + body + struct.pack(">I", binascii.crc32(kind + body))
    )


def main():
    """Exercise filtering without replacing the production decoder."""
    source, mode, temporary = sys.argv[1:]
    fields = mode.split(":")
    channels, filter_kind = map(int, fields[:2])
    mutation = fields[2] if len(fields) == 3 else None
    # Deliberately distinct rows and channels expose missing Up, Sub and Paeth
    # reconstruction. The center pixel is #a1b2c3 in either RGB or RGBA.
    rows = [
        [(11, 27, 49, 81), (53, 91, 137, 171), (181, 211, 239, 251)],
        [(71, 103, 149, 193), (161, 178, 195, 213), (227, 233, 241, 247)],
        [(5, 31, 67, 97), (107, 139, 173, 197), (223, 229, 237, 253)],
    ]
    scanlines = bytearray()
    previous = bytes(3 * channels)
    for pixels in rows:
        row = bytes(channel for pixel in pixels for channel in pixel[:channels])
        scanlines.append(filter_kind)
        for index, value in enumerate(row):
            left = row[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            estimate = left + up - upper_left
            distances = [abs(estimate - item) for item in (left, up, upper_left)]
            paeth = (left, up, upper_left)[distances.index(min(distances))]
            predictor = (0, left, up, (left + up) // 2, paeth)[filter_kind]
            scanlines.append((value - predictor) % 256)
        previous = row
    if mutation == "invalid-filter":
        scanlines[0] = 5
    elif mutation == "short-row":
        scanlines.pop()
    depth = 16 if mutation == "unsupported-depth" else 8
    color = 3 if mutation == "palette" else 2 if channels == 3 else 6
    interlace = 1 if mutation == "interlaced" else 0
    header = struct.pack(">IIBBBBB", 3, 3, depth, color, 0, 0, interlace)
    compressed = zlib.compress(scanlines)
    middle = len(compressed) // 2
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
    # IDAT boundaries do not coincide with rows or zlib blocks.
    png += chunk(b"IDAT", compressed[:middle])
    png += chunk(b"IDAT", compressed[middle:])
    if mutation != "missing-end":
        png += chunk(b"IEND", b"")
    if mutation == "bad-crc":
        png = png[:29] + bytes([png[29] ^ 1]) + png[30:]
    elif mutation == "bad-signature":
        png = b"INVALID!" + png[8:]
    elif mutation == "truncated-chunk":
        png = png[:-7]
    with tempfile.TemporaryDirectory(prefix="pixel-png-", dir=temporary) as directory:
        path = pathlib.Path(directory) / "capture.png"
        path.write_bytes(png)
        result = subprocess.run(
            [sys.executable, "-c", source, str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        print(result.returncode)
        print(result.stdout, end="")


if __name__ == "__main__":
    main()
