"""Exercise checkpoint visibility with real isolated Lua children, not acceptance."""

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import select
import subprocess
import tempfile
import unittest


SOURCE = None
LUA = None
TEMPORARY_ROOT = None
HELPERS = None
RECEIPTS = []
PRIVATE = "private-sentinel-prompt-token-config-error-path-https-secret"


def checkpoint_body():
    """Extract only the exact checkpoint function, never the hardware main."""
    source = SOURCE.read_text()
    match = re.search(
        r"^local function checkpoint\(phase\).*?(?=^local configured_origin =)",
        source,
        re.MULTILINE | re.DOTALL,
    )
    assert match is not None, "checkpoint body must exist"
    body = match.group(0)
    assert body.count('print("ACCEPTANCE_PHASE " .. phase)') == 1
    assert re.fullmatch(
        r'local function checkpoint\(phase\) print\("ACCEPTANCE_PHASE " \.\. phase\) end\n'
        r"|local function checkpoint\(phase\)\n"
        r'\tprint\("ACCEPTANCE_PHASE " \.\. phase\)\n'
        r'\tassert\(io.stdout:flush\(\), "acceptance phase stdout flush failed"\)\nend\n',
        body,
    ), "only the checkpoint is executable in this control"
    return body


def load_safe_helpers(path):
    """Compile only closed projection definitions; import no acceptance module."""
    constants = {"WORK_PHASES", "CLEANUP_PHASE", "FAILURE_REASONS", "EXCEPTION_TYPES"}
    functions = {"acceptance_phases", "safe_failure_metadata", "failure_annotation"}
    nodes = []
    seen = set()
    for node in ast.parse(path.read_text()).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if isinstance(target, ast.Name) and target.id in constants:
                nodes.append(node)
                seen.add(target.id)
        elif isinstance(node, ast.FunctionDef) and node.name in functions:
            nodes.append(node)
            seen.add(node.name)
    assert seen == constants | functions, "closed helper roster must be complete"
    namespace = {}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), namespace)
    return namespace


def terminal_boundary_body():
    """Read two exact control-flow cuts; never execute hardware cleanup or main."""
    source = SOURCE.read_text()
    invocations = re.findall(
        r'^checkpoint\("terminal-physical-shutdown"\)\n'
        r"|^local terminal_checkpoint_ok, terminal_checkpoint_error = "
        r'pcall\(checkpoint, "terminal-physical-shutdown"\)\n',
        source,
        re.MULTILINE,
    )
    assert len(invocations) == 1, "one actual terminal checkpoint invocation required"
    original = (
        "if not ok then error(diagnostic) end\nif not shutdown_ok then error(shutdown_error) end\n"
    )
    final_guards = re.findall(
        r"^if not ok then error\(diagnostic\) end\n"
        r"if not shutdown_ok then error\(shutdown_error\) end\n"
        r"(?:if not terminal_checkpoint_ok then error\(terminal_checkpoint_error\) end\n)?"
        r"(?=print\(Json.encode\(\{ passed = true,)",
        source,
        re.MULTILINE,
    )
    assert len(final_guards) == 1, "one actual final primary guard block required"
    assert final_guards[0] in (
        original,
        original + "if not terminal_checkpoint_ok then error(terminal_checkpoint_error) end\n",
    )
    return invocations[0], final_guards[0]


class CheckpointFlushTests(unittest.TestCase):
    def test_phase_is_visible_before_owned_child_exit(self):
        with tempfile.TemporaryDirectory(
            prefix="checkpoint-flush-", dir=TEMPORARY_ROOT
        ) as directory:
            root = Path(directory)
            script = root / "checkpoint.lua"
            script.write_text(
                checkpoint_body()
                + 'checkpoint("official-https-install")\n'
                + 'assert(io.stderr:write("READY\\n"))\n'
                + "assert(io.stderr:flush())\n"
                + 'assert(io.stdin:read("*l"))\n'
            )
            output = root / "phase.log"
            child = None
            observed = None
            before_exit = False
            try:
                with output.open("xb", buffering=0) as stream:
                    child = subprocess.Popen(
                        [LUA, str(script)],
                        stdin=subprocess.PIPE,
                        stdout=stream,
                        stderr=subprocess.PIPE,
                        close_fds=True,
                    )
                    readable, _, _ = select.select([child.stderr], [], [], 5)
                    self.assertEqual(len(readable), 1, "owned child readiness must arrive")
                    self.assertEqual(os.read(child.stderr.fileno(), 6), b"READY\n")
                    before_exit = child.poll() is None
                    observed = output.read_bytes()
                    self.assertTrue(before_exit, "phase must be inspected while child remains live")
                    self.assertEqual(observed, b"ACCEPTANCE_PHASE official-https-install\n")
            finally:
                if child is not None:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=5)
                    child.stdin.close()
                    child.stderr.close()
                    RECEIPTS.append(
                        {
                            "control": self._testMethodName,
                            "observed_before_exit": before_exit,
                            "marker_visible": observed
                            == b"ACCEPTANCE_PHASE official-https-install\n",
                            "owned_child_reaped": child.poll() is not None,
                            "child_status": child.returncode,
                            "private_stdout_handle_closed": stream.closed,
                            "no_native_acceptance": True,
                        }
                    )

    def test_flush_refusal_never_becomes_success_or_private_text(self):
        with tempfile.TemporaryDirectory(
            prefix="checkpoint-refusal-", dir=TEMPORARY_ROOT
        ) as directory:
            script = Path(directory) / "checkpoint.lua"
            script.write_text(
                checkpoint_body()
                + 'io.stdout = {flush = function() return nil, "'
                + PRIVATE
                + '" end}\n'
                + 'checkpoint("official-https-install")\n'
            )
            result = subprocess.run([LUA, str(script)], capture_output=True, timeout=5)
            RECEIPTS.append(
                {
                    "control": self._testMethodName,
                    "child_status": result.returncode,
                    "owned_child_reaped": True,
                    "no_native_acceptance": True,
                }
            )
            self.assertNotEqual(result.returncode, 0, "flush refusal must fail the checkpoint")
            self.assertIn(b"acceptance phase stdout flush failed", result.stderr)
            self.assertNotIn(PRIVATE.encode(), result.stdout + result.stderr)

    def test_closed_phase_parser_refuses_private_and_post_cleanup_markers(self):
        text = (
            "ACCEPTANCE_PHASE official-https-install\n"
            + "ACCEPTANCE_PHASE "
            + PRIVATE
            + "\n"
            + "ACCEPTANCE_PHASE real-model-chat \n"
            + "ACCEPTANCE_PHASE terminal-physical-shutdown\n"
            + "ACCEPTANCE_PHASE real-model-chat\n"
        )
        self.assertEqual(
            HELPERS["acceptance_phases"](text),
            {
                "phase": "terminal-physical-shutdown",
                "work_phase": "official-https-install",
                "cleanup_phase": "terminal-physical-shutdown",
            },
        )
        self.assertIsNone(HELPERS["acceptance_phases"]({"text": PRIVATE}))

    def test_private_workflow_injection_has_no_annotation_authority(self):
        document = {
            "passed": False,
            "status": "failed",
            "reason": "native_receipt_or_source_qualification_failed",
            "work_phase": "official-https-install",
            "cleanup_phase": None,
            "child_status": 1,
            "zero_descendants": True,
            "sources_unchanged": True,
            "private_log": PRIVATE,
        }
        annotation = HELPERS["failure_annotation"](document)
        self.assertEqual(
            annotation,
            "::error title=Ollama native acceptance::phase=official-https-install "
            "cleanup_phase=none status=failed reason=native_receipt_or_source_qualification_failed "
            "child_status=1 zero_descendants=true sources_unchanged=true exception_type=none",
        )
        self.assertNotIn(PRIVATE, annotation)
        document["work_phase"] = "official-https-install\n::error::" + PRIVATE
        self.assertIsNone(HELPERS["failure_annotation"](document))

    def receive_terminal_boundary(self, primary):
        invocation, guards = terminal_boundary_body()
        with tempfile.TemporaryDirectory(
            prefix="checkpoint-terminal-", dir=TEMPORARY_ROOT
        ) as directory:
            script = Path(directory) / "checkpoint.lua"
            work_ok = "false" if primary == "work" else "true"
            shutdown_ok = "false" if primary == "shutdown" else "true"
            script.write_text(
                checkpoint_body()
                + "local work_error, shutdown_error = {}, {}\n"
                + "local cleanup_count = 0\n"
                + 'io.stdout = {flush = function() return nil, "'
                + PRIVATE
                + '" end}\n'
                + "local succeeded, refusal = pcall(function()\n"
                + "local ok, diagnostic = "
                + work_ok
                + ", work_error\n"
                + "local shutdown_ok, shutdown_error = "
                + shutdown_ok
                + ", shutdown_error\n"
                + invocation
                + "cleanup_count = cleanup_count + 1\n"
                + 'assert(io.stderr:write("MODELED_CLEANUP_REACHED\\n"))\n'
                + "assert(io.stderr:flush())\n"
                + guards
                + "end)\n"
                + 'local category = "unknown"\n'
                + 'if succeeded then category = "success"\n'
                + 'elseif rawequal(refusal, work_error) then category = "work"\n'
                + 'elseif rawequal(refusal, shutdown_error) then category = "shutdown"\n'
                + 'elseif type(refusal) == "string" and refusal:find("acceptance phase stdout flush failed", 1, true) then category = "terminal" end\n'
                + 'assert(io.stderr:write("BOUNDARY success=" .. tostring(succeeded) .. " cleanup=" .. tostring(cleanup_count) .. " category=" .. category .. "\\n"))\n'
                + "assert(io.stderr:flush())\n"
            )
            result = subprocess.run([LUA, str(script)], capture_output=True, timeout=5)
            stderr = result.stderr.decode("utf-8")
            received = re.search(
                r"^BOUNDARY success=(true|false) cleanup=([0-9]+) category=(success|work|shutdown|terminal|unknown)$",
                stderr,
                re.MULTILINE,
            )
            RECEIPTS.append(
                {
                    "control": self._testMethodName,
                    "primary": primary,
                    "child_status": result.returncode,
                    "owned_child_reaped": True,
                    "stdout_hex": result.stdout.hex(),
                    "stderr": stderr,
                    "modeled_cleanup_only": True,
                    "no_native_acceptance": True,
                }
            )
            self.assertEqual(result.returncode, 0, "isolated boundary observation must complete")
            self.assertIsNotNone(received, "the closed boundary observation must arrive")
            self.assertEqual(
                received.group(2), "1", "modeled cleanup must execute despite terminal refusal"
            )
            self.assertEqual(stderr.count("MODELED_CLEANUP_REACHED\n"), 1)
            self.assertEqual(received.group(1), "false", "terminal refusal never becomes success")
            self.assertEqual(
                received.group(3), primary, "original primary error object retains precedence"
            )
            self.assertNotIn(PRIVATE.encode(), result.stdout + result.stderr)

    def test_terminal_flush_refusal_is_deferred_until_modeled_cleanup(self):
        self.receive_terminal_boundary("terminal")

    def test_original_work_error_precedes_terminal_flush_refusal(self):
        self.receive_terminal_boundary("work")

    def test_original_shutdown_error_precedes_terminal_flush_refusal(self):
        self.receive_terminal_boundary("shutdown")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--diagnostics-source", type=Path, required=True)
    parser.add_argument("--lua", required=True)
    parser.add_argument("--temporary-root", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    SOURCE, LUA, TEMPORARY_ROOT = args.source, args.lua, args.temporary_root
    HELPERS = load_safe_helpers(args.diagnostics_source)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(CheckpointFlushTests)
    )
    args.receipt.write_text(
        json.dumps(
            {
                "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                "helpers_sha256": hashlib.sha256(args.diagnostics_source.read_bytes()).hexdigest(),
                "lua": LUA,
                "tests": result.testsRun,
                "failures": len(result.failures),
                "errors": len(result.errors),
                "skipped": len(result.skipped),
                "receipts": RECEIPTS,
                "native_acceptance_executed": False,
            },
            indent=2,
        )
        + "\n"
    )
    raise SystemExit(0 if result.wasSuccessful() else 1)
