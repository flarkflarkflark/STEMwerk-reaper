#!/usr/bin/env python3
"""Apply a deterministic alpha-only rounded mask to the sips logo resize."""

from __future__ import annotations

import argparse
import binascii
from pathlib import Path
import struct
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SIZE = 128
RADIUS = 18
SAMPLES_PER_AXIS = 16
SAMPLE_COUNT = SAMPLES_PER_AXIS * SAMPLES_PER_AXIS
BYTES_PER_PIXEL = 4


def _chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = binascii.crc32(kind)
    checksum = binascii.crc32(payload, checksum) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def _parse_chunks(data: bytes) -> list[tuple[bytes, bytes]]:
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("input is not a PNG")

    chunks: list[tuple[bytes, bytes]] = []
    offset = len(PNG_SIGNATURE)
    saw_iend = False
    while offset < len(data):
        if len(data) - offset < 12:
            raise ValueError("truncated PNG chunk")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("truncated PNG chunk payload")
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        stored_crc = struct.unpack(">I", data[offset + 8 + length : end])[0]
        actual_crc = binascii.crc32(kind)
        actual_crc = binascii.crc32(payload, actual_crc) & 0xFFFFFFFF
        if stored_crc != actual_crc:
            raise ValueError(f"invalid {kind.decode('ascii', 'replace')} CRC")
        chunks.append((kind, payload))
        offset = end
        if kind == b"IEND":
            saw_iend = True
            break

    if not saw_iend or offset != len(data):
        raise ValueError("invalid PNG end")
    if not chunks or chunks[0][0] != b"IHDR":
        raise ValueError("PNG must start with IHDR")
    if chunks[-1][0] != b"IEND" or chunks[-1][1]:
        raise ValueError("invalid IEND chunk")
    if sum(kind == b"IHDR" for kind, _ in chunks) != 1:
        raise ValueError("PNG must contain exactly one IHDR")

    known_critical = {b"IHDR", b"PLTE", b"IDAT", b"IEND"}
    for kind, _ in chunks:
        if not (kind[0] & 0x20) and kind not in known_critical:
            raise ValueError(f"unsupported critical PNG chunk {kind!r}")
    return chunks


def _paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def _decode_rgba(chunks: list[tuple[bytes, bytes]]) -> tuple[bytearray, bytes]:
    ihdr = chunks[0][1]
    if len(ihdr) != 13:
        raise ValueError("invalid IHDR length")
    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", ihdr
    )
    expected = (SIZE, SIZE, 8, 6, 0, 0, 0)
    actual = (width, height, bit_depth, color_type, compression, filtering, interlace)
    if actual != expected:
        raise ValueError(f"unsupported sips PNG format: expected {expected}, got {actual}")
    if any(kind == b"PLTE" for kind, _ in chunks):
        raise ValueError("unexpected palette in RGBA sips PNG")

    idat_positions = [index for index, (kind, _) in enumerate(chunks) if kind == b"IDAT"]
    if not idat_positions:
        raise ValueError("PNG has no IDAT data")
    if idat_positions != list(range(idat_positions[0], idat_positions[-1] + 1)):
        raise ValueError("PNG IDAT chunks must be consecutive")

    compressed = b"".join(chunks[index][1] for index in idat_positions)
    decompressor = zlib.decompressobj()
    filtered = decompressor.decompress(compressed) + decompressor.flush()
    if not decompressor.eof or decompressor.unused_data or decompressor.unconsumed_tail:
        raise ValueError("invalid PNG zlib stream")

    stride = SIZE * BYTES_PER_PIXEL
    expected_length = SIZE * (stride + 1)
    if len(filtered) != expected_length:
        raise ValueError(
            f"unexpected decompressed PNG length: expected {expected_length}, got {len(filtered)}"
        )

    decoded = bytearray(SIZE * stride)
    previous = bytearray(stride)
    source_offset = 0
    for row_index in range(SIZE):
        filter_type = filtered[source_offset]
        source_offset += 1
        source = filtered[source_offset : source_offset + stride]
        source_offset += stride
        row = decoded[row_index * stride : (row_index + 1) * stride]
        for index, value in enumerate(source):
            left = row[index - BYTES_PER_PIXEL] if index >= BYTES_PER_PIXEL else 0
            above = previous[index]
            upper_left = previous[index - BYTES_PER_PIXEL] if index >= BYTES_PER_PIXEL else 0
            if filter_type == 0:
                decoded_value = value
            elif filter_type == 1:
                decoded_value = value + left
            elif filter_type == 2:
                decoded_value = value + above
            elif filter_type == 3:
                decoded_value = value + ((left + above) // 2)
            elif filter_type == 4:
                decoded_value = value + _paeth(left, above, upper_left)
            else:
                raise ValueError(f"unsupported PNG filter type {filter_type}")
            row[index] = decoded_value & 0xFF
        decoded[row_index * stride : (row_index + 1) * stride] = row
        previous = row
    return decoded, ihdr


def _inside_quadratic_corner(horizontal: int, vertical: int, radius: int) -> bool:
    """Test a scaled sample against the exact quadratic Bezier corner.

    Eliminating t from the radius-r curve with control point at the outer
    corner gives sqrt(horizontal / r) + sqrt(vertical / r) = 1. Squaring
    that relation yields this integer-only inside test, with no platform
    renderer or floating-point boundary decisions.
    """
    total = horizontal + vertical
    if total >= radius:
        return True
    return 4 * horizontal * vertical >= (radius - total) ** 2


def _coverage(x: int, y: int) -> int:
    scale = 2 * SAMPLES_PER_AXIS
    size = SIZE * scale
    radius = RADIUS * scale
    left = x < RADIUS
    right = x >= SIZE - RADIUS
    top = y < RADIUS
    bottom = y >= SIZE - RADIUS
    if not ((left or right) and (top or bottom)):
        return SAMPLE_COUNT

    covered = 0
    for sample_y in range(SAMPLES_PER_AXIS):
        vertical = y * scale + 2 * sample_y + 1
        if bottom:
            vertical = size - vertical
        for sample_x in range(SAMPLES_PER_AXIS):
            horizontal = x * scale + 2 * sample_x + 1
            if right:
                horizontal = size - horizontal
            if _inside_quadratic_corner(horizontal, vertical, radius):
                covered += 1
    return covered


def _apply_alpha_mask(pixels: bytearray) -> bytearray:
    masked = bytearray(pixels)
    for y in range(SIZE):
        for x in range(SIZE):
            coverage = _coverage(x, y)
            alpha_index = ((y * SIZE + x) * BYTES_PER_PIXEL) + 3
            source_alpha = pixels[alpha_index]
            # Fixed 16x16 coverage and half-up integer rounding make edge
            # antialiasing deterministic while leaving every RGB byte alone.
            masked[alpha_index] = (
                source_alpha * coverage + (SAMPLE_COUNT // 2)
            ) // SAMPLE_COUNT
    return masked


def _encode_png(chunks: list[tuple[bytes, bytes]], pixels: bytearray) -> bytes:
    stride = SIZE * BYTES_PER_PIXEL
    scanlines = bytearray()
    for row_index in range(SIZE):
        scanlines.append(0)
        start = row_index * stride
        scanlines.extend(pixels[start : start + stride])
    replacement_idat = zlib.compress(bytes(scanlines), level=9)

    output = bytearray(PNG_SIGNATURE)
    wrote_idat = False
    for kind, payload in chunks:
        if kind == b"IDAT":
            if wrote_idat:
                continue
            payload = replacement_idat
            wrote_idat = True
        output.extend(_chunk(kind, payload))
    if not wrote_idat:
        raise ValueError("PNG has no IDAT data")
    return bytes(output)


def render(input_path: Path, output_path: Path) -> None:
    if input_path.resolve() == output_path.resolve():
        raise ValueError("input and output paths must differ")
    chunks = _parse_chunks(input_path.read_bytes())
    pixels, _ = _decode_rgba(chunks)
    masked = _apply_alpha_mask(pixels)
    output_path.write_bytes(_encode_png(chunks, masked))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Apply the STEMwerk Installer alpha mask without changing RGB bytes."
    )
    parser.add_argument("input", type=Path, help="128x128 RGBA PNG produced by sips -Z 128")
    parser.add_argument("output", type=Path, help="masked Installer resource PNG")
    args = parser.parse_args()
    render(args.input, args.output)


if __name__ == "__main__":
    main()
