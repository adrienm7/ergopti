"""Pure AST-only controls; never import or execute hardware fixture main."""

import argparse
import ast
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import unittest


SOURCE = None
NAMESPACE = None
PRIVATE = "private-sentinel-error-path-prompt-token"
TITLE = "owned111_active"
ARGS = ("xdotool", "search", "--onlyvisible", "--name", TITLE)
PREFIX = "# native_window_visible_search_failure "


def load_helpers(path):
    """Load only the two helpers or adapt the exact original wait expression."""
    tree = ast.parse(path.read_text())
    helpers = {"_visible_search_failure", "_discover_owned_xmessage"}
    selected = [
        node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in helpers
    ]
    namespace = {"subprocess": subprocess, "json": json, "print": print}
    if selected:
        assert {node.name for node in selected} == helpers
        exec(compile(ast.Module(body=selected, type_ignores=[]), str(path), "exec"), namespace)
        return namespace, "candidate-helpers-only"
    main = next(
        node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "main"
    )
    discovery = [
        node
        for node in ast.walk(main)
        if isinstance(node, ast.Assign)
        and isinstance(node.targets[0], ast.Subscript)
        and isinstance(node.targets[0].value, ast.Name)
        and node.targets[0].value.id == "ids"
    ]
    assert len(discovery) == 1
    value = discovery[0].value
    assert (
        isinstance(value, ast.Call) and isinstance(value.func, ast.Name) and value.func.id == "int"
    )
    wait = copy.deepcopy(value.args[0])
    assert isinstance(wait, ast.Call) and isinstance(wait.func, ast.Name) and wait.func.id == "wait"
    predicate = wait.args[0]
    assert isinstance(predicate, ast.Lambda)
    strip = predicate.body
    assert (
        isinstance(strip, ast.Call)
        and isinstance(strip.func, ast.Attribute)
        and strip.func.attr == "strip"
    )
    stdout = strip.func.value
    assert isinstance(stdout, ast.Attribute) and stdout.attr == "stdout"
    command = stdout.value
    assert (
        isinstance(command, ast.Call)
        and isinstance(command.func, ast.Name)
        and command.func.id == "command"
    )
    assert [x.value for x in command.args[:4]] == list(ARGS[:4])
    assert isinstance(command.args[4], ast.Name) and command.args[4].id == "title"
    assert len(command.keywords) == 1 and command.keywords[0].arg == "check"
    assert (
        isinstance(command.keywords[0].value, ast.Constant)
        and command.keywords[0].value.value is False
    )
    # This test-only adapter replaces the original command boundary with an already
    # completed result supplier; stdout.strip and original wait expression are exact.
    stdout.value = ast.Call(func=ast.Name(id="query", ctx=ast.Load()), args=[], keywords=[])
    adapter = ast.FunctionDef(
        name="_discover_owned_xmessage",
        args=ast.arguments(
            posonlyargs=[],
            args=[ast.arg(arg=x) for x in ["title", "wait", "query"]],
            kwonlyargs=[],
            kw_defaults=[],
            defaults=[],
        ),
        body=[ast.Return(value=wait)],
        decorator_list=[],
    )
    adapted = ast.fix_missing_locations(ast.Module(body=[adapter], type_ignores=[]))
    exec(compile(adapted, "original-discovery-expression-only", "exec"), namespace)
    return namespace, "original-expression-adapter-only"


def result(status=1, stdout="\n\t", stderr="é🙂", args=ARGS):
    return subprocess.CompletedProcess(args, status, stdout, stderr)


class VisibleSearchDiagnosticTests(unittest.TestCase):
    def discover(self, wait, query, title=TITLE):
        return NAMESPACE["_discover_owned_xmessage"](title, wait, query)

    def failed(self, rows, original=None, title=TITLE):
        error = (
            original if original is not None else AssertionError("owned native receipt deadline")
        )
        calls = []
        output = io.StringIO()
        queue = iter(rows)

        def query():
            value = next(queue)
            calls.append(value)
            return value

        def wait(predicate):
            for _ in rows:
                self.assertFalse(predicate())
            raise error

        with contextlib.redirect_stdout(output):
            with self.assertRaises(type(error)) as caught:
                self.discover(wait, query, title)
        self.assertIs(caught.exception, error, "original error identity must remain authoritative")
        self.assertEqual(len(calls), len(rows), "observer must acquire no new command/query")
        return output.getvalue()

    def test_only_last_failed_result_produces_closed_utf8_counts(self):
        text = self.failed([result(status=2, stderr=PRIVATE), result()])
        self.assertEqual(len(text.splitlines()), 1)
        self.assertTrue(text.startswith(PREFIX))
        self.assertEqual(
            json.loads(text[len(PREFIX) :]),
            {
                "version": 1,
                "phase": "owned-xmessage-visible-search",
                "title": "active",
                "status": 1,
                "stdout_bytes": 2,
                "stderr_bytes": 6,
            },
        )
        self.assertNotIn(PRIVATE, text)
        self.assertNotIn("é🙂", text)
        self.assertNotIn(TITLE, text)

    def test_success_preserves_original_window_id_without_diagnostic(self):
        calls = []
        output = io.StringIO()

        def query():
            calls.append(1)
            return result(0, "12345\n", "")

        with contextlib.redirect_stdout(output):
            observed = self.discover(lambda predicate: predicate(), query)
        self.assertEqual(observed, "12345")
        self.assertEqual(int(observed), 12345)
        self.assertEqual(calls, [1])
        self.assertEqual(output.getvalue(), "")

    def test_initial_failed_search_followed_by_success_emits_nothing(self):
        queue = iter([result(), result(0, "67890\n", "")])
        calls = []

        def query():
            calls.append(1)
            return next(queue)

        def wait(predicate):
            self.assertFalse(predicate())
            return predicate()

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(self.discover(wait, query), "67890")
        self.assertEqual(len(calls), 2)
        self.assertEqual(output.getvalue(), "")

    def test_later_worker_failure_cannot_publish_stale_search(self):
        output = io.StringIO()
        later = AssertionError("owned native receipt deadline")
        with contextlib.redirect_stdout(output):
            self.assertEqual(
                self.discover(lambda predicate: predicate(), lambda: result(0, "42\n", "")), "42"
            )
            with self.assertRaises(AssertionError) as caught:
                raise later
        self.assertIs(caught.exception, later)
        self.assertEqual(output.getvalue(), "")

    def test_search_timeout_preserves_same_original_exception(self):
        error = subprocess.TimeoutExpired(ARGS, 3, output=PRIVATE, stderr=PRIVATE)

        def query():
            raise error

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                self.discover(lambda predicate: predicate(), query)
        self.assertIs(caught.exception, error)
        self.assertEqual(output.getvalue(), "")

    def test_non_deadline_assertion_and_subclass_have_no_observation(self):
        class OtherAssertion(AssertionError):
            pass

        for error in [AssertionError(PRIVATE), OtherAssertion("owned native receipt deadline")]:
            with self.subTest(kind=type(error).__name__):
                self.assertEqual(self.failed([result()], error), "")

    def test_original_control_exceptions_are_not_swallowed(self):
        class ControlStop(BaseException):
            pass

        for error in [KeyboardInterrupt(), SystemExit(143), ControlStop()]:

            def query():
                raise error

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                with self.assertRaises(type(error)) as caught:
                    self.discover(lambda predicate: predicate(), query)
            self.assertIs(caught.exception, error)
            self.assertEqual(output.getvalue(), "")

    def test_technical_observer_refusal_preserves_original_deadline(self):
        original_print = NAMESPACE["print"]
        try:
            for error in [OSError(PRIVATE), RuntimeError(PRIVATE), AssertionError(PRIVATE)]:

                def refuse(*args, **kwargs):
                    raise error

                NAMESPACE["print"] = refuse
                self.assertEqual(self.failed([result()]), "")
        finally:
            NAMESPACE["print"] = original_print

    def test_observer_control_exceptions_preserve_cancellation(self):
        class ControlStop(BaseException):
            pass

        original_print = NAMESPACE["print"]
        try:
            for interruption in [KeyboardInterrupt(), SystemExit(143), ControlStop()]:
                original = AssertionError("owned native receipt deadline")

                def wait(predicate):
                    self.assertFalse(predicate())
                    raise original

                def refuse(*args, **kwargs):
                    raise interruption

                NAMESPACE["print"] = refuse
                try:
                    self.discover(wait, lambda: result())
                except BaseException as received:
                    self.assertIs(
                        received,
                        interruption,
                        "fresh cancellation must not become a deadline or success",
                    )
                else:
                    self.fail("control exception must propagate")
        finally:
            NAMESPACE["print"] = original_print

    def test_malformed_foreign_or_oversized_result_cannot_publish(self):
        class PrivateValue:
            def __str__(self):
                raise AssertionError("must never coerce private data")

        class Status(int):
            pass

        class Result(subprocess.CompletedProcess):
            pass

        rows = [
            result(status=True),
            result(status=1.0),
            result(status=Status(1)),
            result(status=-65),
            result(status=256),
            result(status=None),
            result(stderr=PrivateValue()),
            result(stderr=b"private"),
            result(stderr="x" * 65537),
            result(stdout="\n" * 65537),
            result(args=list(ARGS)),
            result(args=ARGS[:-1]),
            result(args=ARGS[:-1] + (PRIVATE,)),
            result(args=ARGS[:-1] + (PrivateValue(),)),
            Result(ARGS, 1, "", PRIVATE),
        ]
        for row in rows:
            with self.subTest(
                status_type=type(row.returncode).__name__, result_type=type(row).__name__
            ):
                self.assertEqual(self.failed([row]), "")
        self.assertEqual(self.failed([result()], title=PRIVATE), "")

    def test_projection_encoding_refusal_preserves_original_deadline(self):
        self.assertEqual(self.failed([result(stderr="\ud800")]), "")

    def test_fixed_title_enum_never_borrows_another_client(self):
        for title, enum in [
            ("owned111_active", "active"),
            ("owned111_right", "right"),
            ("owned111_left", "left"),
        ]:
            args = ARGS[:-1] + (title,)
            text = self.failed([result(args=args)], title=title)
            self.assertTrue(text.startswith(PREFIX))
            self.assertEqual(json.loads(text[len(PREFIX) :])["title"], enum)
            self.assertEqual(self.failed([result()], title=title), "" if title != TITLE else text)

    def test_private_primary_argument_never_enters_observer_comparison(self):
        attempts = []

        class PrivateArgument:
            def __eq__(self, other):
                attempts.append("comparison")
                raise AssertionError("private comparison must not execute")

            def __str__(self):
                attempts.append("stringification")
                raise AssertionError("private stringification must not execute")

        private = PrivateArgument()
        original = AssertionError(private)
        self.assertIs(original.args[0], private)
        self.assertEqual(self.failed([result()], original), "")
        self.assertEqual(attempts, [], "private primary argument must have no observer authority")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    SOURCE = args.source
    NAMESPACE, mode = load_helpers(SOURCE)
    actual = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(VisibleSearchDiagnosticTests)
    )
    args.receipt.write_text(
        json.dumps(
            {
                "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                "mode": mode,
                "tests": actual.testsRun,
                "failures": len(actual.failures),
                "errors": len(actual.errors),
                "skipped": len(actual.skipped),
                "hardware_main_imported_or_executed": False,
                "native_GUI_HTTP_model_subreaper_spawned": False,
            },
            indent=2,
        )
        + "\n"
    )
    raise SystemExit(0 if actual.wasSuccessful() else 1)
