"""Evaluate the actual worker expression and exercise its real POSIX signals."""

import json
import os
from pathlib import Path
import re
import resource
import signal
import shutil
import subprocess
import sys
import tempfile
import time


BINDINGS = {"cmd", "resultPath", "statusPath", "donePath"}
BLOCK = re.compile(r"^\tset bgCmd to (.*?)^\tdo shell script bgCmd$", re.M | re.S)
LITERAL = re.compile(r'"(?:[^"\\\r\n¬]|\\["\\])*"')
OPERAND = re.compile(r"(quoted form of )?(cmd|resultPath|statusPath|donePath)\b")


def quoted_form(value):
    return "'" + value.replace("'", "'\\''") + "'"


def worker_expression(source, values):
    if set(values) != BINDINGS or any(not isinstance(x, str) for x in values.values()):
        raise ValueError("Missing or unknown worker binding")
    blocks = list(BLOCK.finditer(source))
    if len(blocks) != 1:
        raise ValueError("Expected exactly one complete actual worker expression")
    text = blocks[0].group(1).rstrip(" \t\r\n")
    offset = 0
    result = []
    seen = set()
    expecting_operand = True
    while offset < len(text):
        if text[offset] in " \t":
            offset += 1
            continue
        if text[offset] == "¬":
            continuation = re.match(r"¬[ \t]*\r?\n", text[offset:])
            if continuation is None:
                raise ValueError("Invalid AppleScript line continuation")
            offset += continuation.end()
            continue
        if not expecting_operand:
            if text[offset] != "&":
                raise ValueError("Expected AppleScript concatenation")
            offset += 1
            expecting_operand = True
            continue
        literal = LITERAL.match(text, offset)
        if literal:
            result.append(json.loads(literal.group()))
            offset = literal.end()
        else:
            operand = OPERAND.match(text, offset)
            if operand is None:
                raise ValueError("Unknown or missing worker operand")
            name = operand.group(2)
            if name in seen or bool(operand.group(1)) != (name != "cmd"):
                raise ValueError("Ambiguous or unquoted worker operand")
            seen.add(name)
            value = values[name]
            result.append(quoted_form(value) if operand.group(1) else value)
            offset = operand.end()
        expecting_operand = False
    if expecting_operand or seen != BINDINGS:
        raise ValueError("Missing or trailing worker operand")
    return "".join(result)


CHILD_DEADLINE = 5
RETIREMENT_DEADLINE = 5


def group_exists(identity):
    try:
        os.killpg(identity, 0)
    except ProcessLookupError:
        return False
    return True


def group_retired(identity, deadline):
    while group_exists(identity):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)
    return True


def run_case(source, shell, name, limited, kind):
    root = Path(tempfile.mkdtemp(prefix="ergopti-worker ' signal-"))
    ownership_closed = True
    retain = False
    try:
        survived = root / "survived"
        body = {
            "success": "exit 0",
            "failure": "exit 7",
            "signal": "kill -XFSZ $$; touch " + quoted_form(str(survived)) + "; exit 0",
        }[kind]
        values = {label + "Path": str(root / label) for label in ("result", "status", "done")}
        values["cmd"] = "/bin/sh -c " + quoted_form(body)
        program = worker_expression(source, values) + '\nwait "$!"\n'

        def child_policy():
            signal.signal(signal.SIGXFSZ, signal.SIG_DFL)
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            if limited:
                resource.setrlimit(
                    resource.RLIMIT_FSIZE, (0, resource.getrlimit(resource.RLIMIT_FSIZE)[1])
                )

        ownership_closed = False
        process = subprocess.Popen(
            [shell, "-c", program],
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            preexec_fn=child_policy,
            start_new_session=True,
        )
        timed_out = False
        try:
            output, errors = process.communicate(timeout=CHILD_DEADLINE)
            retirement_end = time.monotonic() + RETIREMENT_DEADLINE
        except subprocess.TimeoutExpired:
            timed_out = retain = True
            retirement_end = time.monotonic() + RETIREMENT_DEADLINE
            # Only a still-owned, unreaped session leader authorizes signalling
            # this exact new group. A reaped/reused PID is never selected.
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            try:
                output, errors = process.communicate(
                    timeout=max(0, retirement_end - time.monotonic())
                )
            except subprocess.TimeoutExpired:
                for stream in (process.stdout, process.stderr):
                    if stream is not None:
                        stream.close()
                raise RuntimeError(
                    f"Owned worker group retirement is unknown; fixture retained: {root}"
                )
        try:
            ownership_closed = group_retired(process.pid, retirement_end)
        except OSError as error:
            retain = True
            raise RuntimeError(
                f"Owned worker group identity is unknown; fixture retained: {root}"
            ) from error
        if not ownership_closed:
            retain = True
            raise RuntimeError(
                f"Owned worker descendants remain unqualified; fixture retained: {root}"
            )
        if timed_out:
            raise RuntimeError(
                f"Worker deadline expired; exact group retired, fixture retained: {root}"
            )
        status = root / "status"
        return {
            "name": name,
            "shell": shell,
            "limited": limited,
            "kind": kind,
            "wait_status": process.returncode,
            "done": (root / "done").is_file(),
            "status_present": status.is_file(),
            "status_text": status.read_text() if status.is_file() else None,
            "result_present": (root / "result").is_file(),
            "survived": survived.exists(),
            "stdout": output,
            "stderr": errors,
            "ownership_closed": ownership_closed,
        }
    finally:
        if ownership_closed and not retain:
            shutil.rmtree(root)


def parser_negatives(source):
    values = {name: name for name in BINDINGS}
    worker_expression(source, values)
    block = BLOCK.search(source).group()
    variants = {
        "missing-block": (source.replace("set bgCmd to", "set removed to"), values),
        "ambiguous-block": (source + "\n" + block, values),
        "unknown-operand": (source.replace("& cmd ¬", "& surprise ¬"), values),
        "missing-operand": (source.replace("& cmd ¬", "& ¬"), values),
        "duplicate-operand": (source.replace("& cmd ¬", "& cmd & cmd ¬"), values),
        "unquoted-path": (source.replace("quoted form of statusPath", "statusPath"), values),
        "missing-binding": (
            source,
            {name: value for name, value in values.items() if name != "donePath"},
        ),
        "trailing-operand": (
            source.replace("\n\tdo shell script bgCmd", " & surprise\n\tdo shell script bgCmd"),
            values,
        ),
        "trailing-concatenation": (
            source.replace("\n\tdo shell script bgCmd", " &\n\tdo shell script bgCmd"),
            values,
        ),
        "unsupported-escape": (source.replace('" > "', '"\\q > "', 1), values),
    }
    result = []
    for name, (candidate, bindings) in variants.items():
        try:
            worker_expression(candidate, bindings)
        except ValueError as error:
            result.append({"name": name, "rejected": True, "error": str(error)})
        else:
            result.append({"name": name, "rejected": False, "error": ""})
    return result


def main():
    source = Path(sys.argv[1]).read_text(encoding="utf-8")
    shells = ["/bin/sh", sys.argv[2]]
    controls = [
        ("success", False, "success"),
        ("failure", False, "failure"),
        ("limited-success", True, "success"),
        ("limited-failure", True, "failure"),
        ("child-signal", False, "signal"),
        ("limited-child-signal", True, "signal"),
    ]
    cases = [run_case(source, shell, *control) for shell in shells for control in controls]
    block = list(BLOCK.finditer(source))
    if len(block) != 1:
        raise ValueError("The actual child boundary must exist exactly once")
    literal = LITERAL.match(block[0].group(1))
    if literal is None or not json.loads(literal.group()).startswith("("):
        raise ValueError("The actual supervisor must own one initial group literal")
    begin = block[0].start(1)
    end = begin + literal.end()
    mutant = source[:begin] + json.dumps("(trap '' XFSZ; ") + source[end:]
    uncaught = source[:begin] + json.dumps("(") + source[end:]
    uncaught_cases = [
        run_case(uncaught, shell, "uncaught-supervisor-mutant", True, "success") for shell in shells
    ]
    moved = [
        run_case(mutant, shell, "before-child-mutant", limited, "signal")
        for shell in shells
        for limited in (False, True)
    ]
    print(
        json.dumps(
            {
                "cases": cases,
                "parser_negatives": parser_negatives(source),
                "before_child_mutant": moved,
                "uncaught_supervisor_mutant": uncaught_cases,
                "signal_number": signal.SIGXFSZ,
                "scope": "Actual POSIX kernel RLIMIT_FSIZE and signals; no arbitrary disk error or native GUI qualification",
            }
        )
    )


if __name__ == "__main__":
    main()
