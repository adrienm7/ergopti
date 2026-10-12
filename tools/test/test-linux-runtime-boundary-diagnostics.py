"""Pure boundary controls: no hardware main, native owner or model is imported."""

import argparse
import ast
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import unittest


NAMESPACE = None
PREFIX = "ACCEPTANCE_BOUNDARY "
PRIVATE = "private-sentinel-prompt-token-path-error-url"


def helpers(path):
    """Compile only boundary definitions or the exact original guardian expression."""
    tree = ast.parse(path.read_text())
    functions = {"_boundary_marker", "_boundary_observation", "_guardian_call"}
    constants = {"BOUNDARY_STEPS", "BOUNDARY_REFUSAL"}
    selected = []
    seen = set()
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in functions:
            selected.append(node)
            seen.add(node.name)
        elif isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if isinstance(target, ast.Name) and target.id in constants:
                selected.append(node)
                seen.add(target.id)
    namespace = {"print": print}
    if selected:
        assert seen == functions | constants
        exec(compile(ast.Module(body=selected, type_ignores=[]), str(path), "exec"), namespace)
        return namespace, "candidate-boundary-AST-only"
    # Old collector has no boundary publication or interpretation. Validate that
    # omission, then preserve its actual guardian call via a test-only adapter.
    assert not any(
        isinstance(n, ast.Constant)
        and isinstance(n.value, str)
        and "ACCEPTANCE_BOUNDARY" in n.value
        for n in ast.walk(tree)
    )
    calls = [
        n
        for n in ast.walk(tree)
        if isinstance(n, ast.Call)
        and isinstance(n.func, ast.Attribute)
        and n.func.attr == "main"
        and isinstance(n.func.value, ast.Name)
        and n.func.value.id == "owner"
    ]
    assert len(calls) == 1
    call = copy.deepcopy(calls[0])
    assert len(call.args) == 1 and isinstance(call.args[0], ast.Attribute)
    assert call.args[0].attr == "child_command"
    assert len(call.keywords) == 1 and call.keywords[0].arg == "deadline_seconds"
    assert isinstance(call.keywords[0].value, ast.Constant) and call.keywords[0].value.value == 930
    adapter = ast.FunctionDef(
        name="_guardian_call",
        args=ast.arguments(
            posonlyargs=[],
            args=[ast.arg(arg="owner"), ast.arg(arg="args")],
            kwonlyargs=[],
            kw_defaults=[],
            defaults=[],
        ),
        body=[ast.Return(value=call)],
        decorator_list=[],
    )
    exec(
        compile(
            ast.fix_missing_locations(ast.Module(body=[adapter], type_ignores=[])),
            "original-guardian-expression-only",
            "exec",
        ),
        namespace,
    )
    namespace["_boundary_marker"] = lambda kind: None
    namespace["_boundary_observation"] = lambda text: {}
    return namespace, "original-guardian-expression-and-boundary-omission"


class RuntimeBoundaryTests(unittest.TestCase):
    def test_ordered_fixed_milestones_and_refusal_are_observations_only(self):
        text = (
            "ACCEPTANCE_BOUNDARY guardian-enter\n"
            "ACCEPTANCE_BOUNDARY build-admission\n"
            "ACCEPTANCE_BOUNDARY build-command\n"
            "ACCEPTANCE_BOUNDARY guardian-deadline-exception\n"
        )
        actual = NAMESPACE["_boundary_observation"](text)
        self.assertEqual(
            actual,
            {
                "boundary_stage_observed": "build-command",
                "boundary_reason_observed": "guardian-deadline-exception",
            },
        )
        self.assertNotIn("passed", actual)
        self.assertNotIn("zero_descendants", actual)
        self.assertNotIn("sources_unchanged", actual)
        self.assertNotIn("child_status", actual)

    def test_full_order_does_not_claim_lua_status_or_physical_closure(self):
        text = (
            "ACCEPTANCE_BOUNDARY guardian-enter\nACCEPTANCE_BOUNDARY build-admission\n"
            "ACCEPTANCE_BOUNDARY build-command\nACCEPTANCE_BOUNDARY build-complete\n"
            "ACCEPTANCE_BOUNDARY lua-launch\nACCEPTANCE_BOUNDARY lua-complete\n"
        )
        self.assertEqual(
            NAMESPACE["_boundary_observation"](text),
            {
                "boundary_stage_observed": "lua-complete",
                "boundary_reason_observed": None,
            },
        )

    def test_unknown_duplicate_out_of_order_and_private_injection_are_refused(self):
        for text in [
            "ACCEPTANCE_BOUNDARY " + PRIVATE + "\n",
            "ACCEPTANCE_BOUNDARY guardian-enter\nACCEPTANCE_BOUNDARY guardian-enter\n",
            "ACCEPTANCE_BOUNDARY build-command\n",
            "ACCEPTANCE_BOUNDARY guardian-enter\nACCEPTANCE_BOUNDARY lua-launch\n",
            "ACCEPTANCE_BOUNDARY guardian-enter \n",
            "ACCEPTANCE_BOUNDARY guardian-deadline-exception\n",
            "ACCEPTANCE_BOUNDARY guardian-enter\nACCEPTANCE_BOUNDARY guardian-deadline-exception\nACCEPTANCE_BOUNDARY build-admission\n",
            "ACCEPTANCE_BOUNDARY guardian-enter\nACCEPTANCE_BOUNDARY guardian-deadline-exception\nACCEPTANCE_BOUNDARY guardian-deadline-exception\n",
            "ACCEPTANCE_BOUNDARY guardian-enter\nACCEPTANCE_BOUNDARY " + PRIVATE + "\n",
        ]:
            self.assertEqual(NAMESPACE["_boundary_observation"](text), {})

        class PrivateValue:
            def __str__(self):
                raise AssertionError("private value must not be coerced")

        for value in [None, {}, [], PrivateValue()]:
            self.assertEqual(NAMESPACE["_boundary_observation"](value), {})

    def test_no_marker_or_elapsed_duration_has_no_reason_authority(self):
        self.assertEqual(NAMESPACE["_boundary_observation"]("elapsed=930.449\n"), {})
        self.assertEqual(
            NAMESPACE["_boundary_observation"]("ACCEPTANCE_PHASE official-https-install\n"), {}
        )

    def test_marker_is_closed_and_flushed_without_private_values(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            NAMESPACE["_boundary_marker"]("build-command")
        self.assertEqual(output.getvalue(), "ACCEPTANCE_BOUNDARY build-command\n")

        class PrivateValue:
            def __str__(self):
                raise AssertionError("must not stringify private value")

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            for token in [PRIVATE, {}, [], PrivateValue()]:
                NAMESPACE["_boundary_marker"](token)
        self.assertEqual(output.getvalue(), "")
        calls = []
        original = NAMESPACE["print"]
        try:
            NAMESPACE["print"] = lambda *args, **kwargs: calls.append((args, kwargs))
            NAMESPACE["_boundary_marker"]("lua-launch")
        finally:
            NAMESPACE["print"] = original
        self.assertEqual(calls, [(("ACCEPTANCE_BOUNDARY lua-launch",), {"flush": True})])

    def test_guardian_success_retains_command_identity_single_call_and_930(self):
        command = ["pure-unexecuted-command"]
        calls = []

        class Owner:
            def main(self, received, **options):
                calls.append((received, options))
                return 37

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            value = NAMESPACE["_guardian_call"](Owner(), argparse.Namespace(child_command=command))
        self.assertEqual(value, 37)
        self.assertEqual(len(calls), 1)
        self.assertIs(calls[0][0], command)
        self.assertEqual(calls[0][1], {"deadline_seconds": 930})
        self.assertEqual(output.getvalue(), "ACCEPTANCE_BOUNDARY guardian-enter\n")

    def test_exact_original_refusal_and_modeled_cleanup_identity_preserved(self):
        error = RuntimeError("native owned-process probe exceeded its deadline")
        calls = []

        class Owner:
            def main(self, received, **options):
                calls.append("entered")
                try:
                    raise error
                finally:
                    calls.append("modeled-cleanup")

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            with self.assertRaises(RuntimeError) as caught:
                NAMESPACE["_guardian_call"](Owner(), argparse.Namespace(child_command=[]))
        self.assertIs(caught.exception, error)
        self.assertEqual(calls, ["entered", "modeled-cleanup"])
        self.assertEqual(
            output.getvalue(),
            "ACCEPTANCE_BOUNDARY guardian-enter\nACCEPTANCE_BOUNDARY guardian-deadline-exception\n",
        )

    def test_unknown_private_runtime_and_assertion_arguments_are_not_compared(self):
        attempts = []

        class PrivateArgument:
            def __eq__(self, other):
                attempts.append("equality")
                raise AssertionError("private comparison forbidden")

            def __str__(self):
                attempts.append("stringification")
                raise AssertionError("private stringification forbidden")

        for error in [
            RuntimeError(PrivateArgument()),
            AssertionError(PrivateArgument()),
            RuntimeError(PRIVATE),
        ]:

            class Owner:
                def main(self, received, **options):
                    raise error

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                with self.assertRaises(type(error)) as caught:
                    NAMESPACE["_guardian_call"](Owner(), argparse.Namespace(child_command=[]))
            self.assertIs(caught.exception, error)
            self.assertNotIn("guardian-deadline-exception", output.getvalue())
            self.assertNotIn(PRIVATE, output.getvalue())
        self.assertEqual(attempts, [])

    def test_technical_publication_refusal_never_replaces_original_error(self):
        original = NAMESPACE["print"]
        error = RuntimeError("native owned-process probe exceeded its deadline")
        calls = []

        class Owner:
            def main(self, received, **options):
                calls.append(1)
                raise error

        try:
            for failure in [OSError(PRIVATE), RuntimeError(PRIVATE), AssertionError(PRIVATE)]:

                def refuse(*args, **kwargs):
                    raise failure

                NAMESPACE["print"] = refuse
                with self.assertRaises(RuntimeError) as caught:
                    NAMESPACE["_guardian_call"](Owner(), argparse.Namespace(child_command=[]))
                self.assertIs(caught.exception, error)
        finally:
            NAMESPACE["print"] = original
        self.assertEqual(calls, [1, 1, 1])

    def test_fresh_control_exception_after_original_owner_cleanup_propagates(self):
        class Stop(BaseException):
            pass

        original = NAMESPACE["print"]
        try:
            for interruption in [KeyboardInterrupt(), SystemExit(143), Stop()]:
                callbacks = []
                error = RuntimeError("native owned-process probe exceeded its deadline")

                class Owner:
                    def main(self, received, **options):
                        try:
                            raise error
                        finally:
                            callbacks.append("modeled-cleanup")

                def emit(*args, **kwargs):
                    if args[0] == "ACCEPTANCE_BOUNDARY guardian-deadline-exception":
                        raise interruption

                NAMESPACE["print"] = emit
                try:
                    NAMESPACE["_guardian_call"](Owner(), argparse.Namespace(child_command=[]))
                except BaseException as caught:
                    self.assertIs(caught, interruption)
                else:
                    self.fail("fresh control exception must propagate")
                self.assertEqual(callbacks, ["modeled-cleanup"])
        finally:
            NAMESPACE["print"] = original


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    NAMESPACE, mode = helpers(args.source)
    actual = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(RuntimeBoundaryTests)
    )
    args.receipt.write_text(
        json.dumps(
            {
                "source_sha256": hashlib.sha256(args.source.read_bytes()).hexdigest(),
                "mode": mode,
                "tests": actual.testsRun,
                "failures": len(actual.failures),
                "errors": len(actual.errors),
                "skipped": len(actual.skipped),
                "hardware_main_native_model_subreaper_import_or_execution": False,
            },
            indent=2,
        )
        + "\n"
    )
    raise SystemExit(0 if actual.wasSuccessful() else 1)
