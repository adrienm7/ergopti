# tools/diagnostics/ollama_native_tiny_gguf.py
"""Independent tiny real Llama GGUF for native parser and inference receiving.

The deterministic random weights are a test model, not a trained assistant.
The file uses real F32 tensors, SentencePiece byte fallback and native inference;
no model/parser/HTTP implementation or expected corpus is substituted.
"""

import math
from pathlib import Path
import struct


def text(value):
    encoded = value.encode("utf-8")
    return struct.pack("<Q", len(encoded)) + encoded


def metadata(name, kind, value):
    return text(name) + struct.pack("<I", kind) + value


def tensor(name, dimensions, offset):
    return (
        text(name)
        + struct.pack("<I", len(dimensions))
        + b"".join(struct.pack("<Q", n) for n in dimensions)
        + struct.pack("<IQ", 0, offset)
    )


def model_bytes():
    tokens = ["<unk>", "<s>", "</s>", "▁"] + [f"<0x{value:02X}>" for value in range(256)]
    integers = {
        "general.alignment": 32,
        "general.file_type": 0,
        "llama.context_length": 64,
        "llama.embedding_length": 16,
        "llama.block_count": 1,
        "llama.feed_forward_length": 32,
        "llama.attention.head_count": 2,
        "llama.attention.head_count_kv": 2,
        "llama.rope.dimension_count": 8,
        "tokenizer.ggml.bos_token_id": 1,
        "tokenizer.ggml.eos_token_id": 2,
        "tokenizer.ggml.unknown_token_id": 0,
    }
    entries = [metadata(name, 4, struct.pack("<I", value)) for name, value in integers.items()]
    for name, value in (
        ("general.architecture", "llama"),
        ("general.name", "Ergopti native transport fixture"),
        ("tokenizer.ggml.model", "llama"),
    ):
        entries.append(metadata(name, 8, text(value)))
    entries.append(metadata("llama.attention.layer_norm_rms_epsilon", 6, struct.pack("<f", 1e-5)))
    entries.append(
        metadata(
            "tokenizer.ggml.tokens",
            9,
            struct.pack("<IQ", 8, len(tokens)) + b"".join(map(text, tokens)),
        )
    )
    entries.append(
        metadata(
            "tokenizer.ggml.scores",
            9,
            struct.pack("<IQ", 6, len(tokens))
            + struct.pack("<" + "f" * len(tokens), *([0.0] * len(tokens))),
        )
    )
    entries.append(
        metadata(
            "tokenizer.ggml.token_type",
            9,
            struct.pack("<IQ", 5, len(tokens))
            + struct.pack("<" + "i" * len(tokens), *([2, 3, 3, 1] + [6] * 256)),
        )
    )
    entries.append(metadata("tokenizer.ggml.add_bos_token", 7, b"\x01"))
    entries.append(metadata("tokenizer.ggml.add_eos_token", 7, b"\x00"))
    shapes = [
        ("token_embd.weight", [16, len(tokens)]),
        ("output_norm.weight", [16]),
        ("output.weight", [16, len(tokens)]),
        ("blk.0.attn_norm.weight", [16]),
        ("blk.0.attn_q.weight", [16, 16]),
        ("blk.0.attn_k.weight", [16, 16]),
        ("blk.0.attn_v.weight", [16, 16]),
        ("blk.0.attn_output.weight", [16, 16]),
        ("blk.0.ffn_norm.weight", [16]),
        ("blk.0.ffn_gate.weight", [16, 32]),
        ("blk.0.ffn_down.weight", [32, 16]),
        ("blk.0.ffn_up.weight", [16, 32]),
    ]
    descriptors, payload = [], bytearray()
    for index, (name, dimensions) in enumerate(shapes):
        descriptors.append(tensor(name, dimensions, len(payload)))
        count = math.prod(dimensions)
        values = (
            [1.0] * count
            if "norm.weight" in name
            else [((position * 17 + index * 31) % 127 - 63) / 1024.0 for position in range(count)]
        )
        payload.extend(struct.pack("<" + "f" * count, *values))
    header = (
        b"GGUF"
        + struct.pack("<IQQ", 3, len(shapes), len(entries))
        + b"".join(entries)
        + b"".join(descriptors)
    )
    return header + b"\0" * (-len(header) % 32) + payload


def write(path):
    with Path(path).open("xb") as stream:
        stream.write(model_bytes())


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    write(parser.parse_args().output)
