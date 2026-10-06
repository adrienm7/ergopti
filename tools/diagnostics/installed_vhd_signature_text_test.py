# tools/diagnostics/installed_vhd_signature_text_test.py
"""Exercise the frozen genuine corpus and handwritten before-code refusals."""

import base64
from collections import Counter
import hashlib
import itertools
import json
import os
from pathlib import Path
import sys
import unittest

import installed_vhd_signature_text as subject

EXPECTATIONS_SHA256 = "983de5385e734fdf42af2b69e8e8283ea14b0c9023d99fadcdbe4ca9b6f210b4"
STDOUT_SHA256 = {
    "8.4.0": "54413968e85cc41b18a556f8883585e8fc78a3fb882b15efdc85130e5c835c9a",
    "8.5.0": "9db169e93c6f70ff39cc7d1c3ab7c0e32bc639ed5cf2a6f5dba053a8f843b044",
    "8.6.0": "036ccdfa0a4dc644ed0c4a4c9a00dd6656a82cc2864c4b16a0ddc4b692806cdd",
}
EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
HELP_STDERR_SHA256 = "87d053567dfaf75496f6a1d31915037543138309b3df1ffe3e67c7172964e756"


def line_edit(lines, index, replacement):
    """Build a test input edit from captured rows, never a parser expectation."""
    changed = list(lines)
    changed[index] = replacement
    return b"".join(changed)


def refusal_inputs(original, captured_inputs, help_stderr):
    """Yield concrete controls for every independently frozen refusal family."""
    body = original["stdout"]
    version = original["expected_version"]
    lines = body.splitlines(keepends=True)

    def edit(family, **changes):
        result = dict(original)
        result.update(changes)
        return family, result, ValueError

    def output(family, changed):
        return edit(family, stdout=changed)

    for value in ("8.7.0", "arbitrary", ""):
        yield edit("unsupported-version", expected_version=value)
    for other in captured_inputs:
        if other["expected_version"] != version:
            yield edit("wrong-version-pair", expected_version=other["expected_version"])
    for value in (None, b"8.4.0", 840, False, True):
        yield edit("missing-version", expected_version=value)
    absent = dict(original)
    del absent["expected_version"]
    yield "missing-version", absent, TypeError
    for value in (False, True):
        yield edit("boolean-exit-status", exit_status=value)
    for value in (-1, 1, 2, 255):
        yield edit("nonzero-exit-status", exit_status=value)
    for value in (0.0, "0", None, []):
        yield edit("noninteger-exit-status", exit_status=value)
    absent = dict(original)
    del absent["exit_status"]
    yield "noninteger-exit-status", absent, TypeError
    for key, family, genuine in (
        ("stdout", "stdout-type", body),
        ("stderr", "stderr-type", b""),
    ):
        for value in (genuine.decode("ascii"), bytearray(genuine), memoryview(genuine), [], None):
            yield edit(family, **{key: value})
        absent = dict(original)
        del absent[key]
        yield family, absent, TypeError
    for value in (b"\n", b" ", b"diagnostic\n", body):
        yield edit("stderr-nonempty", stderr=value)
    yield output("empty-stdout", b"")
    for value in (body + b" ", b"x" * 131073, body + b"  "):
        yield output("oversized-stdout", value)
    for length in range(1128):
        yield output("every-proper-prefix", body[:length])
    for index in range(1128):
        yield output("every-byte-deletion", body[:index] + body[index + 1 :])
    for value in (body[:-1], body[:-2], body + b"\n"):
        yield output("terminal-newline", value)
    yield output("crlf", body.replace(b"\n", b"\r\n"))
    for index, byte in enumerate(body):
        if byte == 10:
            yield output("crlf", body[:index] + b"\r\n" + body[index + 1 :])
    yield output("bare-cr", body.replace(b"\n", b"\r"))
    for prefix in (
        b"\n",
        b"warning\n",
        b"pkgutil --check-signature package.pkg\n",
        b"2026-10-06T10:37:48.5039130Z ",
        b"\x1b[31m",
        b"::warning::untrusted prefix\n",
    ):
        yield output("leading-prefix", prefix + body)
    for suffix in (b"warning\n", lines[0], body, b"extra\n"):
        yield output("trailing-suffix", body + suffix)
    yield output("bom", b"\xef\xbb\xbf" + body)
    for index in range(len(body) + 1):
        yield output("nul", body[:index] + b"\0" + body[index:])
    for invalid in (b"\xff", b"\xc0\xaf", b"\xed\xa0\x80"):
        yield output("nonascii", body[:8] + invalid + body[8:])
    yield output("nonascii", body.replace(b"Apple", "\u0410pple".encode("utf-8"), 1))
    filename = b"Karabiner-DriverKit-VirtualHIDDevice-" + version.encode("ascii") + b".pkg"
    for value in (b"/tmp/" + filename, b"./" + filename, b"alias.pkg", b"other.pkg"):
        yield output("package-path", body.replace(filename, value, 1))
    for value in (b"8.7.0", b"08.4.0"):
        yield output("package-version", body.replace(version.encode("ascii"), value, 1))
    for family, replacements in (
        ("unsigned-status", (b"   Status: unsigned\n",)),
        ("adhoc-status", (b"   Status: signed with an ad-hoc certificate\n",)),
        (
            "unknown-status",
            (
                b"   Status: Unknown\n",
                lines[1].replace(b"signed", b"Signed", 1),
                lines[1][:-1] + b".\n",
                lines[1].replace(b"Status:", b"State:", 1),
            ),
        ),
    ):
        for replacement in replacements:
            yield output(family, line_edit(lines, 1, replacement))
    yield output("missing-status", line_edit(lines, 1, b""))
    for replacement in (lines[1] * 2, lines[1] + b"   Status: unsigned\n"):
        yield output("duplicate-status", line_edit(lines, 1, replacement))
    for value in (b"untrusted", b"rejected"):
        yield output(
            "untrusted-notarization", line_edit(lines, 2, b"   Notarization: " + value + b"\n")
        )
    for replacement in (b"   Notarization: Unknown\n", b"   Notary: trusted\n"):
        yield output("unknown-notarization", line_edit(lines, 2, replacement))
    yield output("missing-notarization", line_edit(lines, 2, b""))
    for replacement in (lines[2] * 2, lines[2] + b"   Notarization: rejected\n"):
        yield output("duplicate-notarization", line_edit(lines, 2, replacement))
    for other in captured_inputs:
        if other["expected_version"] != version:
            yield output(
                "timestamp-crosspair",
                line_edit(lines, 3, other["stdout"].splitlines(keepends=True)[3]),
            )
    for literal in (
        b"2026-09-01 00:00:00 +0000",
        b"2026-99-99 99:99:99 +0000",
        b"2026-09-04 13:32:50 +0100",
    ):
        yield output(
            "timestamp-unobserved",
            line_edit(lines, 3, b"   Signed with a trusted timestamp on: " + literal + b"\n"),
        )
    yield output("timestamp-unobserved", line_edit(lines, 3, lines[3].replace(b"trusted ", b"", 1)))
    for index in (6, 12, 18):
        yield output(
            "timestamp-expiry-mutation",
            line_edit(lines, index, lines[index].replace(b"Expires: 20", b"Expires: 21", 1)),
        )
    for replacement in (b"", b"   Certificates:\n"):
        yield output("chain-heading", line_edit(lines, 4, replacement))
    for old, new in (
        (b"Fumihiko", b"Otherxxx"),
        (b"G43BCU2T37", b"H43BCU2T37"),
        (b"Installer", b"Application"),
    ):
        yield output("unknown-leaf", line_edit(lines, 5, lines[5].replace(old, new, 1)))
    for index, family in ((11, "unknown-intermediate"), (17, "unknown-root")):
        yield output(
            family,
            line_edit(
                lines,
                index,
                lines[index].replace(b"ID", b"ZZ", 1)
                if index == 11
                else lines[index].replace(b"Apple", b"Other", 1),
            ),
        )
        fingerprint_index = index + 3
        replacement = lines[fingerprint_index].replace(b"7A" if index == 11 else b"B0", b"00", 1)
        yield output(family, line_edit(lines, fingerprint_index, replacement))
    for index in (8, 9, 14, 15, 20, 21):
        tokens = lines[index].split()
        ending = b" \n" if index in (8, 14, 20) else b"\n"
        for ordinal, token in enumerate(tokens):
            changed = list(tokens)
            changed[ordinal] = b"00" if token != b"00" else b"FF"
            yield output(
                "fingerprint-one-byte",
                line_edit(lines, index, b"           " + b" ".join(changed) + ending),
            )
        for replacement in (
            lines[index].lower(),
            b"           " + b":".join(tokens) + ending,
            b"           " + b" ".join(tokens[:-1]) + ending,
            b"           " + b" ".join(tokens + [b"00"]) + ending,
            b"           GG " + b" ".join(tokens[1:]) + ending,
        ):
            yield output("fingerprint-shape", line_edit(lines, index, replacement))
    for index in (8, 14, 20):
        tokens = lines[index].split() + lines[index + 1].split()
        rewrapped = list(lines)
        rewrapped[index] = b"           " + b" ".join(tokens[:16]) + b" \n"
        rewrapped[index + 1] = b"           " + b" ".join(tokens[16:]) + b"\n"
        yield output("fingerprint-shape", b"".join(rewrapped))
        yield output(
            "fingerprint-trailing-spaces", line_edit(lines, index, lines[index][:-2] + b"\n")
        )
    for index in set(range(23)) - {8, 14, 20}:
        yield output(
            "fingerprint-trailing-spaces", line_edit(lines, index, lines[index][:-1] + b" \n")
        )
    blocks = [lines[5:11], lines[11:17], lines[17:22]]
    for index in range(3):
        yield output(
            "missing-certificate",
            b"".join(
                lines[:5]
                + sum((block for ordinal, block in enumerate(blocks) if ordinal != index), [])
                + lines[22:]
            ),
        )
        yield output("extra-certificate", b"".join(lines[:22] + blocks[index] + lines[22:]))
    yield output(
        "extra-certificate",
        b"".join(lines[:22]) + b"    4. Unknown Certificate\n" + b"".join(lines[22:]),
    )
    for first, second in itertools.combinations(range(3), 2):
        changed = list(blocks)
        changed[first], changed[second] = changed[second], changed[first]
        yield output("reordered-chain", b"".join(lines[:5] + sum(changed, []) + lines[22:]))
        changed_lines = list(lines)
        a, b = (5, 11, 17)[first], (5, 11, 17)[second]
        changed_lines[a] = changed_lines[a].replace(
            str(first + 1).encode(), str(second + 1).encode(), 1
        )
        changed_lines[b] = changed_lines[b].replace(
            str(second + 1).encode(), str(first + 1).encode(), 1
        )
        yield output("reordered-chain", b"".join(changed_lines))
    field_rows = (6, 7, 8, 9, 12, 13, 14, 15, 18, 19, 20, 21)
    for index in field_rows:
        yield output("duplicate-field", line_edit(lines, index, lines[index] * 2))
    for first, second in itertools.combinations((1, 2, 3, 4), 2):
        changed = list(lines)
        changed[first], changed[second] = changed[second], changed[first]
        yield output("reordered-field", b"".join(changed))
    for block_rows in ((6, 7, 8, 9), (12, 13, 14, 15), (18, 19, 20, 21)):
        for first, second in itertools.combinations(block_rows, 2):
            changed = list(lines)
            changed[first], changed[second] = changed[second], changed[first]
            yield output("reordered-field", b"".join(changed))
    for index in (10, 16):
        for replacement in (b"", lines[index][:-2] + b"\n", lines[index] * 2):
            yield output("separator", line_edit(lines, index, replacement))
    for index, line in enumerate(lines):
        indentation = len(line) - len(line.lstrip(b" "))
        for position in range(indentation):
            yield output(
                "indentation",
                line_edit(lines, index, line[:position] + b"\t" + line[position + 1 :]),
            )
        if indentation:
            yield output("indentation", line_edit(lines, index, line[1:]))
            yield output("indentation", line_edit(lines, index, b" " + line))
    for index in range(1, 22):
        yield output(
            "interior-blank-line", b"".join(lines[:index]) + b"\n" + b"".join(lines[index:])
        )
    yield output("other-channel", help_stderr)
    yield edit("other-channel", stdout=b"", stderr=body)
    yield output("partial-chain-prefix", b"".join(lines[:5]))
    yield output("partial-chain-prefix", b"".join(lines[:4]))
    for suffix in (lines[0], b"   Status: unsigned\n"):
        yield output("ambiguous-second-package", body + suffix)


class SignatureTextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture_path = Path(__file__).with_name("installed_vhd_signature_text_corpus.json")
        cls.fixture = json.loads(fixture_path.read_bytes())
        cls.expectation_bytes = base64.b64decode(
            cls.fixture["handwritten_expectations_base64"], validate=True
        )
        cls.expectations = json.loads(cls.expectation_bytes)
        cls.inputs = [
            {
                "expected_version": row["version"],
                "stdout": base64.b64decode(row["stdout_base64"], validate=True),
                "stderr": base64.b64decode(row["stderr_base64"], validate=True),
                "exit_status": row["exit_status"],
            }
            for row in cls.fixture["raw_signature_inputs"]
        ]
        cls.help_stderr = base64.b64decode(cls.fixture["help_stderr_base64"], validate=True)

    def test_original_corpus_and_handwritten_expectations_remain_byteexact(self):
        self.assertEqual(hashlib.sha256(self.expectation_bytes).hexdigest(), EXPECTATIONS_SHA256)
        self.assertEqual(self.fixture["handwritten_expectations_sha256"], EXPECTATIONS_SHA256)
        self.assertEqual(len(self.inputs), 3)
        self.assertEqual({row["expected_version"] for row in self.inputs}, set(STDOUT_SHA256))
        self.assertEqual(len(self.expectations["positive_cases"]), 3)
        self.assertEqual(len(self.expectations["refusal_cases"]), 53)
        for row in self.inputs:
            self.assertEqual(len(row["stdout"]), 1128)
            self.assertEqual(len(row["stdout"].splitlines(keepends=True)), 23)
            self.assertEqual(
                hashlib.sha256(row["stdout"]).hexdigest(), STDOUT_SHA256[row["expected_version"]]
            )
            self.assertEqual(row["stderr"], b"")
            self.assertEqual(hashlib.sha256(row["stderr"]).hexdigest(), EMPTY_SHA256)
            self.assertIs(type(row["exit_status"]), int)
            self.assertEqual(row["exit_status"], 0)
        self.assertEqual(len(self.help_stderr), 2130)
        self.assertEqual(hashlib.sha256(self.help_stderr).hexdigest(), HELP_STDERR_SHA256)

    def test_genuine_positive_outputs_equal_frozen_handwritten_fields(self):
        for row, case in zip(self.inputs, self.expectations["positive_cases"], strict=True):
            with self.subTest(version=row["expected_version"]):
                self.assertEqual(row["expected_version"], case["input"]["expected_version"])
                self.assertEqual(subject.observe_signature_text(**row), case["expected"])

    def test_every_frozen_refusal_family_has_actual_mutations(self):
        families = {case["case"] for case in self.expectations["refusal_cases"]}
        counts = Counter()
        per_version = {}
        for row in self.inputs:
            version_counts = Counter()
            for family, changed, error_type in refusal_inputs(row, self.inputs, self.help_stderr):
                counts[family] += 1
                version_counts[family] += 1
                with self.subTest(
                    version=row["expected_version"], family=family, number=version_counts[family]
                ):
                    self.assertIn(family, families)
                    self.assertTrue(
                        set(changed) != set(row)
                        or any(
                            type(changed[key]) is not type(row[key]) or changed[key] != row[key]
                            for key in row
                        ),
                        "Refusal mutation must actually change a value or exact input type",
                    )
                    with self.assertRaises(error_type):
                        subject.observe_signature_text(**changed)
            self.assertEqual(set(version_counts), families)
            self.assertEqual(version_counts["every-proper-prefix"], 1128)
            self.assertEqual(version_counts["every-byte-deletion"], 1128)
            self.assertEqual(version_counts["nul"], 1129)
            self.assertEqual(version_counts["fingerprint-one-byte"], 96)
            per_version[row["expected_version"]] = dict(sorted(version_counts.items()))
        self.assertEqual(set(counts), families)
        self.assertEqual(len(counts), 53)
        self.assertTrue(all(value > 0 for value in counts.values()))
        print(
            "REFUSAL_CENSUS "
            + json.dumps(
                {
                    "families": 53,
                    "total_actual_mutations": sum(counts.values()),
                    "counts": dict(sorted(counts.items())),
                    "per_version": per_version,
                },
                sort_keys=True,
            )
        )

    def test_copied_text_never_grants_authority_and_returned_state_is_fresh(self):
        for row, case in zip(self.inputs, self.expectations["positive_cases"], strict=True):
            copied = dict(row)
            copied["stdout"] = bytes(bytearray(row["stdout"]))
            first = subject.observe_signature_text(**copied)
            self.assertEqual(first, case["expected"])
            self.assertEqual(set(first), set(case["expected"]))
            self.assertEqual(first["trust"], "unknown")
            self.assertIs(first["authority"], False)
            self.assertIs(first["reference_qualified"], False)
            first["trust"] = "changed by caller"
            first["observed_certificate_chain_text"][0]["subject_text"] = "changed by caller"
            self.assertEqual(subject.observe_signature_text(**row), case["expected"])
            with self.assertRaises(TypeError):
                subject.observe_signature_text(**row, package_sha256="unverified external metadata")

    def test_exact_input_types_refuse_subclasses(self):
        class BytesSubclass(bytes):
            pass

        class IntegerSubclass(int):
            pass

        class StringSubclass(str):
            pass

        for row in self.inputs:
            for key, value in (
                ("stdout", BytesSubclass(row["stdout"])),
                ("stderr", BytesSubclass(b"")),
                ("exit_status", IntegerSubclass(0)),
                ("expected_version", StringSubclass(row["expected_version"])),
            ):
                with self.subTest(key=key, version=row["expected_version"]):
                    changed = dict(row)
                    changed[key] = value
                    with self.assertRaises(ValueError):
                        subject.observe_signature_text(**changed)

    def test_interpreter_uses_the_actual_inherited_optimization_setting(self):
        optimization = os.environ.get("PYTHONOPTIMIZE", "0")
        self.assertIn(optimization, ("0", "1"))
        self.assertEqual(sys.flags.optimize, int(optimization))
        print(
            "INTERPRETER_MODE "
            + json.dumps(
                {"PYTHONOPTIMIZE": optimization, "sys_flags_optimize": sys.flags.optimize},
                sort_keys=True,
            )
        )


if __name__ == "__main__":
    unittest.main()
