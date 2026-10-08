# tools/test/fixtures/linux-explicit-crypto-staging.py

# controls/test_explicit_crypto_staging.py
"""Independent actual stager-function controls; controlled metadata is not ELF proof."""

import importlib.util
from pathlib import Path
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("owned_crypto_stager", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
checks = 0


def check(name, body):
    global checks
    body()
    checks += 1
    print("PASS " + name)


with tempfile.TemporaryDirectory(prefix="crypto-staging-model-") as directory:
    root = Path(directory)
    real = root / "libcrypto.so.3"
    real.write_bytes(b"controlled ordinary source; not a native ELF fixture")
    calls = []
    state = {
        "directory": str(root),
        "elf": " 0x000000000000000e (SONAME) Library soname: [libcrypto.so.3]\n",
    }

    def run(command, **options):
        calls.append(command)
        if command == ["pkg-config", "--variable=libdir", "libcrypto"]:
            return state["directory"]
        assert command == ["readelf", "--dynamic", "--", str(real)]
        assert options["env"]["LC_ALL"] == "C"
        return state["elf"]

    module.run = run
    # GNU readelf uses the literal Library soname label for SONAME in this
    # independently authored production parser control, not derived output.
    state["elf"] = " 0x000000000000000e (SONAME) Library soname: [libcrypto.so.3]\n"
    catalogue = {
        "archive_digest_runtime": {
            "soname": "libcrypto.so.3",
            "portable_dlopen_roots": ["libcrypto.so.3"],
        }
    }

    def refused(value):
        try:
            module.explicit_digest_sources(value)
        except module.RuntimeRefused:
            return
        raise AssertionError("Expected exact refusal")

    check("missing descriptor refuses", lambda: refused({}))
    check(
        "invalid descriptor refuses",
        lambda: refused(
            {
                "archive_digest_runtime": {
                    "soname": "libcrypto.so.1.1",
                    "portable_dlopen_roots": ["libcrypto.so.1.1"],
                }
            }
        ),
    )
    check(
        "implicit transitive crypto is insufficient",
        lambda: refused(
            {"archive_digest_runtime": {"soname": "libcrypto.so.3", "portable_dlopen_roots": []}}
        ),
    )
    state["directory"] = "relative/lib"
    check("relative metadata library path refuses", lambda: refused(catalogue))
    state["directory"] = str(root)
    state["elf"] = " 0x000000000000000e (SONAME) Library soname: [libcrypto.so.1.1]\n"
    check("wrong native SONAME refuses", lambda: refused(catalogue))
    state["elf"] = ""
    check("absent SONAME refuses", lambda: refused(catalogue))
    state["elf"] = " 0x000000000000000e (SONAME) Library soname: [libcrypto.so.3]\n" * 2
    check("ambiguous SONAME refuses", lambda: refused(catalogue))
    state["elf"] = " 0x000000000000000e (SONAME) Library soname: [libcrypto.so.3]\n"

    def admitted():
        assert module.explicit_digest_sources(catalogue) == [real]
        assert calls[-2:] == [
            ["pkg-config", "--variable=libdir", "libcrypto"],
            ["readelf", "--dynamic", "--", str(real)],
        ]

    check("explicit actual-metadata root is retained independently of curl", admitted)
assert checks == 8
print("8 PASS, 0 FAIL, 0 SKIP; controlled metadata only")
