"""Author tiny independent archives; these payloads must never be executed."""

import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parent
PAYLOADS = {
    "ollama.exe": b"Independent inert CLI fixture.\n",
    "lib/ollama/ggml-cpu-x64.dll": b"Independent inert CPU library fixture.\n",
    "lib/ollama/cuda_v12/ggml-cuda.dll": b"Independent inert CUDA library fixture.\n",
    "vc_redist.x64.exe": b"Independent inert prerequisite fixture. NEVER EXECUTE.\n",
}
CASES = {
    "portable": list(PAYLOADS.items()),
    "traversal": [("ollama.exe", PAYLOADS["ollama.exe"]), ("../outside", b"foreign")],
    "ads": [("ollama.exe", PAYLOADS["ollama.exe"]), ("lib/a:stream", b"foreign")],
    "rooted": [("ollama.exe", PAYLOADS["ollama.exe"]), ("/outside", b"foreign")],
    "device": [("ollama.exe", PAYLOADS["ollama.exe"]), ("lib/NUL.dll", b"foreign")],
    "collision": [("ollama.exe", b"one"), ("OLLAMA.EXE", b"two")],
    "trailing-dot": [("ollama.exe", PAYLOADS["ollama.exe"]), ("lib/file.", b"foreign")],
    "receipt-collision": [("ollama.exe", b"one"), ("prepared.json", b"foreign")],
    "directory-cli": [("ollama.exe/", b"")],
    "symlink": [("ollama.exe", PAYLOADS["ollama.exe"]), ("lib/link", b"outside")],
    "file-ancestor-cli": [("ollama.exe", b"cli"), ("ollama.exe/child", b"child")],
    "file-ancestor-library": [("ollama.exe", b"cli"), ("lib", b"file"), ("lib/cpu.dll", b"lib")],
    "file-ancestor-reverse": [("ollama.exe", b"cli"), ("lib/cpu.dll", b"lib"), ("lib", b"file")],
    "file-ancestor-case": [("ollama.exe", b"cli"), ("LIB", b"file"), ("lib/cpu.dll", b"lib")],
    "prepared-receipt-descendant": [("ollama.exe", b"cli"), ("PREPARED.JSON/child", b"child")],
    "owner-receipt-descendant": [("ollama.exe", b"cli"), ("stage-owner.json/child", b"child")],
}
NAMESPACE_CASES = {
    "file-ancestor-cli",
    "file-ancestor-library",
    "file-ancestor-reverse",
    "file-ancestor-case",
    "prepared-receipt-descendant",
    "owner-receipt-descendant",
}
receipts = {}
for name, entries in CASES.items():
    path = ROOT / (name + ".zip")
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for entry, payload in entries:
            info = zipfile.ZipInfo(entry, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 0
            info.external_attr = 0x10 if entry.endswith("/") else 0x20
            if name == "symlink" and entry == "lib/link":
                info.create_system = 3
                info.external_attr = 0o120777 << 16
            if name in NAMESPACE_CASES:
                # Preserve the six original independent native fixture images.
                info.date_time = (2026, 10, 10, 0, 0, 0)
                info.compress_type = zipfile.ZIP_STORED
                info.create_system = 3
                info.external_attr = 0o100644 << 16
            archive.writestr(info, payload)
    data = path.read_bytes()
    if name in NAMESPACE_CASES:
        receipts[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    else:
        receipts[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}

(ROOT / "receipts.json").write_text(
    json.dumps(receipts, indent="\t") + "\n", encoding="utf-8", newline="\n"
)
(ROOT / "payloads.json").write_text(
    json.dumps(
        {name: {"hex": payload.hex(), "bytes": len(payload)} for name, payload in PAYLOADS.items()},
        indent="\t",
    )
    + "\n",
    encoding="utf-8",
    newline="\n",
)
