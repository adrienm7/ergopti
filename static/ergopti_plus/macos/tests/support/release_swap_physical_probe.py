# static/ergopti_plus/macos/tests/support/release_swap_physical_probe.py

"""Execute the actual literal release-swap program at owned filesystem ports."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile


def literal(text, offset):
    """Decode only the quoted Lua literals used by the production shell table."""
    if offset >= len(text) or text[offset] not in "\"'":
        raise ValueError("The release swap source requires a quoted Lua literal")
    quote = text[offset]
    offset += 1
    output = []
    escapes = {
        "a": "\a",
        "b": "\b",
        "f": "\f",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "v": "\v",
        "\\": "\\",
        '"': '"',
        "'": "'",
    }
    while offset < len(text):
        value = text[offset]
        offset += 1
        if value == quote:
            return "".join(output), offset
        if value in "\r\n":
            raise ValueError("A release swap literal contains an unescaped newline")
        if value == "\\":
            if offset >= len(text) or text[offset] not in escapes:
                raise ValueError("The release swap source contains an unsupported Lua escape")
            value = escapes[text[offset]]
            offset += 1
        output.append(value)
    raise ValueError("A release swap literal is unterminated")


def standalone_boundary(source, offset):
    """Reject Lua continuations before the next supported local declaration."""
    tail = source[offset:].split("\n", 1)[0].strip()
    if tail and not tail.startswith("--"):
        raise ValueError("The release literal must be a complete standalone assignment")
    following = source[offset:].lstrip()
    while following.startswith("--"):
        if following.startswith("--["):
            raise ValueError("Long comments after release literals are unsupported")
        _, newline, following = following.partition("\n")
        if not newline:
            following = ""
            break
        following = following.lstrip()
    if following and re.match(r"local[ \t]+[A-Za-z_]", following) is None:
        raise ValueError("The release literal must be a standalone assignment")


def extract_program(source):
    """Extract one complete, fail-closed literal table; Common compares Lua bytes."""
    constants = list(re.finditer(r"(?m)^local ARMING_RECEIPT\s*=\s*", source))
    bindings = list(re.finditer(r"(?m)^M\.SWAP_SCRIPT\s*=\s*table\.concat\s*\(\s*\{", source))
    receipt_assignments = list(re.finditer(r"(?m)^(?:local[ \t]+)?ARMING_RECEIPT\s*=", source))
    assignments = list(re.finditer(r"(?m)^M\.SWAP_SCRIPT\s*=", source))
    if (
        len(constants) != 1
        or len(bindings) != 1
        or len(assignments) != 1
        or len(receipt_assignments) != 1
    ):
        raise ValueError("The release swap source needs one receipt and one script binding")
    receipt, end = literal(source, constants[0].end())
    standalone_boundary(source, end)
    offset = bindings[0].end()

    def whitespace():
        nonlocal offset
        while offset < len(source) and source[offset].isspace():
            offset += 1

    def term():
        nonlocal offset
        whitespace()
        if source.startswith("ARMING_RECEIPT", offset):
            offset += len("ARMING_RECEIPT")
            return receipt
        value, offset = literal(source, offset)
        return value

    rows = []
    while True:
        whitespace()
        if offset < len(source) and source[offset] == "}":
            offset += 1
            break
        value = term()
        while True:
            whitespace()
            if not source.startswith("..", offset):
                break
            offset += 2
            value += term()
        whitespace()
        if offset >= len(source) or source[offset] != ",":
            raise ValueError("Every release swap table entry must be complete")
        offset += 1
        rows.append(value)
    whitespace()
    if offset >= len(source) or source[offset] != ",":
        raise ValueError("The release swap table has no declared separator")
    offset += 1
    whitespace()
    separator, offset = literal(source, offset)
    whitespace()
    if offset >= len(source) or source[offset] != ")" or not rows:
        raise ValueError("The release swap expression is incomplete")
    standalone_boundary(source, offset + 1)
    return separator.join(rows)


def copy_mutant(program):
    """Remove only the new admissions, preserving the historical unsafe worker."""
    first = "# Stage/destination filesystem admission begins\n"
    last = "# Stage/destination filesystem admission ends\n"
    if program.count(first) != 1 or program.count(last) != 1:
        raise ValueError("The filesystem admission mutation needs its exact source")
    start, end = program.index(first), program.index(last) + len(last)
    program = program[:start] + program[end:]
    first = "# Occupied destinations are retained rather than overwritten or nested into\n"
    last = "# Occupied destination admission ends\n"
    if program.count(first) != 1 or program.count(last) != 1:
        raise ValueError("The occupied-path mutation needs its exact source")
    start, end = program.index(first), program.index(last) + len(last)
    program = program[:start] + program[end:]
    statement = "replacement_path_clear || exit 8\n"
    if program.count(statement) != 2:
        raise ValueError("Both occupied-path admissions must remain present")
    return program.replace(statement, "")


def native_stat_port(arguments):
    """Model Darwin stat argv using actual host inode metadata, never fake IDs."""
    follow = False
    if arguments[:1] == ["-L"]:
        follow = True
        arguments = arguments[1:]
    if len(arguments) != 3 or arguments[:2] != ["-f", "%d"]:
        raise ValueError("The native device observation argv is invalid")
    print(os.stat(arguments[2], follow_symlinks=follow).st_dev)


def execute_case(
    program,
    name,
    root,
    stage_base,
    native,
    limit=None,
    move_fault=None,
    temporary_root=None,
    stat_fault=None,
    candidate_fault=None,
):
    """Keep all app trees owned and execute real moves except the named refusal."""
    import resource

    base = root / name
    base.mkdir()
    app = base / "ErgoptiPlus.app"
    previous = base / "ErgoptiPlus.app.previous"
    app.mkdir()
    (app / "marker").write_text("installed", encoding="utf-8")
    original_identity = (app.stat().st_dev, app.stat().st_ino)
    stage = Path(tempfile.mkdtemp(prefix="ergopti-release-probe-", dir=stage_base))
    staged = stage / "app" / "ErgoptiPlus.app"
    staged.mkdir(parents=True)
    (staged / "marker").write_text("chosen", encoding="utf-8")
    (staged / "large").write_bytes(b"x" * 8192)
    if candidate_fault == "missing":
        import shutil

        shutil.rmtree(staged)
    elif candidate_fault == "symlink":
        real = stage / "real-app"
        staged.rename(real)
        staged.symlink_to(real, target_is_directory=True)
    opened = base / "opened"
    opener = base / "open"
    opener.write_text(
        "#!/bin/sh\nprintf '%s\\n' \"$2\" >> " + shlex.quote(str(opened)) + "\nexit 0\n",
        encoding="utf-8",
    )
    opener.chmod(0o700)
    actual = program.replace("/usr/bin/open", shlex.quote(str(opener)))
    if not native:
        observer = base / "stat"
        observer.write_text(
            "#!/bin/sh\nexec "
            + shlex.quote(sys.executable)
            + " "
            + shlex.quote(__file__)
            + ' stat "$@"\n',
            encoding="utf-8",
        )
        observer.chmod(0o700)
        actual = actual.replace("/usr/bin/stat", shlex.quote(str(observer)))
    if stat_fault:
        observer = base / "refused-stat"
        observer.write_text(
            "#!/bin/sh\n"
            + ("exit 42\n" if stat_fault == "refused" else "printf 'unknown-device\\n'\n"),
            encoding="utf-8",
        )
        observer.chmod(0o700)
        actual = re.sub(
            r"(?:/usr/bin/stat|" + re.escape(shlex.quote(str(base / "stat"))) + r")",
            lambda _: shlex.quote(str(observer)),
            actual,
        )
    if move_fault:
        mover = base / "move"
        lines = ["#!/bin/sh"]
        if move_fault == "occupied":
            lines += [
                'if [ "$2" = ' + shlex.quote(str(app)) + " ]; then",
                ' /bin/mv "$@" || exit $?',
                " /bin/mkdir " + shlex.quote(str(app)) + " || exit $?",
                " printf 'foreign' > " + shlex.quote(str(app / "marker")),
                " exit 0",
                "fi",
            ]
        elif move_fault == "partial-publication":
            lines += [
                'if [ "$2" = ' + shlex.quote(str(staged)) + " ]; then",
                " /bin/mkdir " + shlex.quote(str(app)) + " || exit $?",
                " printf 'partial' > " + shlex.quote(str(app / "marker")),
                " exit 45",
                "fi",
            ]
        elif move_fault == "publication":
            lines += ['[ "$2" = ' + shlex.quote(str(staged)) + " ] && exit 45"]
        else:
            raise ValueError("Unknown owned move refusal")
        lines += ['exec /bin/mv "$@"']
        mover.write_text("\n".join(lines) + "\n", encoding="utf-8")
        mover.chmod(0o700)
        actual = actual.replace("/bin/mv", shlex.quote(str(mover)))

    def policy():
        if limit is not None:
            resource.setrlimit(
                resource.RLIMIT_FSIZE,
                (limit, resource.getrlimit(resource.RLIMIT_FSIZE)[1]),
            )

    env = os.environ.copy()
    env["TMPDIR"] = str(temporary_root or stage_base)
    settled = False
    try:
        result = subprocess.run(
            [
                "/bin/sh",
                "-c",
                "exec 3>&1\n" + actual,
                "swap",
                "999999999",
                str(app),
                str(staged),
                str(previous),
            ],
            env=env,
            capture_output=True,
            text=True,
            preexec_fn=policy,
            timeout=15,
        )

        settled = True

        def read(path):
            return path.read_text(encoding="utf-8") if path.is_file() else None

        return {
            "name": name,
            "original_identity": original_identity,
            "app_identity": (app.stat().st_dev, app.stat().st_ino) if app.exists() else None,
            "previous_identity": (previous.stat().st_dev, previous.stat().st_ino)
            if previous.exists()
            else None,
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "app_marker": read(app / "marker"),
            "previous_marker": read(previous / "marker"),
            "nested_previous_marker": read(app / previous.name / "marker"),
            "opened": read(opened) or "",
            "app_path": str(app),
            "staged_exists": staged.exists(),
            "stage_device": stage.stat().st_dev,
            "parent_device": base.stat().st_dev,
            "temporary_device": Path(temporary_root or stage_base).stat().st_dev,
            "stage_mode": stat.S_IMODE(stage.stat().st_mode),
            "large_size": (app / "large").stat().st_size if (app / "large").is_file() else None,
            "arming_observed": result.stdout.startswith("ARMED\n"),
        }
    finally:
        # The test alone created this exact stage outside the production tree.
        import shutil

        if settled:
            shutil.rmtree(stage)


def probe(root, source, external, native):
    """Exercise same-parent publication and a historical real cross-volume fault."""
    root.mkdir(parents=True, exist_ok=True)
    if root.stat().st_dev == external.stat().st_dev:
        raise ValueError("The physical worker probe requires a distinct external volume")
    program = extract_program(source.read_text(encoding="utf-8"))
    cases = [
        execute_case(
            copy_mutant(program),
            "old-cross-device-copy-failure",
            root,
            external,
            native,
            256,
        ),
        execute_case(
            program,
            "parent-stage-external-tmp",
            root,
            root,
            native,
            256,
            temporary_root=external,
        ),
        execute_case(program, "foreign-device-before-arming", root, external, native),
        execute_case(
            program,
            "occupied-publication-target",
            root,
            root,
            native,
            move_fault="occupied",
        ),
        execute_case(
            program,
            "publication-refusal-restores-original",
            root,
            root,
            native,
            move_fault="publication",
        ),
        execute_case(
            program,
            "partial-publication-target",
            root,
            root,
            native,
            move_fault="partial-publication",
        ),
        execute_case(
            program,
            "device-observation-refused",
            root,
            root,
            native,
            stat_fault="refused",
        ),
        execute_case(
            program,
            "device-observation-invalid",
            root,
            root,
            native,
            stat_fault="invalid",
        ),
        execute_case(program, "missing-candidate", root, root, native, candidate_fault="missing"),
        execute_case(program, "symlink-candidate", root, root, native, candidate_fault="symlink"),
    ]
    qualify(cases)
    return {
        "platform": sys.platform,
        "native_stat": native,
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "program_sha256": hashlib.sha256(program.encode()).hexdigest(),
        "cases": cases,
    }


def parser_controls(source):
    """Prove unknown syntax and duplicate authorities cannot select stale bytes."""
    variants = {
        "receipt-suffix": source.replace(
            'local ARMING_RECEIPT = "ARMED"', 'local ARMING_RECEIPT = "ARMED" .. "X"', 1
        ),
        "receipt-continued-suffix": source.replace(
            'local ARMING_RECEIPT = "ARMED"',
            'local ARMING_RECEIPT = "ARMED"\n .. "X"',
            1,
        ),
        "reassigned-receipt": source.replace(
            "M.SWAP_SCRIPT = ", 'ARMING_RECEIPT = "FOREIGN"\nM.SWAP_SCRIPT = ', 1
        ),
        "long-comment-suffix": source.replace(
            '}, "\\n")', '}, "\\n")\n--[[\nlocal ignored\n]]\n .. "X"', 1
        ),
        "long-equals-comment-suffix": source.replace(
            '}, "\\n")', '}, "\\n")\n--[=[\nlocal ignored\n]=]\n .. "X"', 1
        ),
        "duplicate-script": source + "\nM.SWAP_SCRIPT = table.concat({\n",
        "duplicate-literal-script": source + '\nM.SWAP_SCRIPT = "FOREIGN"\n',
        "duplicate-receipt": source + '\nlocal ARMING_RECEIPT = "FOREIGN"\n',
        "dynamic-entry": source.replace('"set -u"', 'os.getenv("SHELL")', 1),
        "unsupported-escape": source.replace('"set -u"', r'"set\q"', 1),
        "missing-entry-comma": source.replace('"set -u",', '"set -u"', 1),
        "dynamic-suffix": source.replace('}, "\\n")', '}, "\\n") .. "FOREIGN"', 1),
        "continued-suffix": source.replace('}, "\\n")', '}, "\\n")\n .. "FOREIGN"', 1),
        "missing-separator": source.replace('}, "\\n")', "})", 1),
    }
    for name, changed in variants.items():
        assert changed != source, name
        try:
            extract_program(changed)
        except ValueError:
            continue
        raise AssertionError("The literal extractor accepted " + name)
    return list(variants)


def controls(root, source):
    """Run shared same-filesystem fault controls without a mounted volume."""
    root.mkdir(parents=True, exist_ok=True)
    program = extract_program(source.read_text(encoding="utf-8"))
    cases = [
        execute_case(program, "healthy", root, root, sys.platform == "darwin"),
        execute_case(
            program,
            "occupied",
            root,
            root,
            sys.platform == "darwin",
            move_fault="occupied",
        ),
        execute_case(
            program,
            "partial",
            root,
            root,
            sys.platform == "darwin",
            move_fault="partial-publication",
        ),
        execute_case(
            program,
            "publication",
            root,
            root,
            sys.platform == "darwin",
            move_fault="publication",
        ),
        execute_case(
            program,
            "stat-refused",
            root,
            root,
            sys.platform == "darwin",
            stat_fault="refused",
        ),
        execute_case(
            program,
            "stat-invalid",
            root,
            root,
            sys.platform == "darwin",
            stat_fault="invalid",
        ),
        execute_case(
            program,
            "missing",
            root,
            root,
            sys.platform == "darwin",
            candidate_fault="missing",
        ),
        execute_case(
            program,
            "symlink",
            root,
            root,
            sys.platform == "darwin",
            candidate_fault="symlink",
        ),
    ]
    healthy, occupied, partial, publication, *refused = cases
    assert healthy["exit_code"] == 0 and healthy["app_marker"] == "chosen"
    assert healthy["previous_marker"] == "installed" and healthy["large_size"] == 8192
    assert healthy["opened"] == healthy["app_path"] + "\n"
    for case, marker in [(occupied, "foreign"), (partial, "partial")]:
        assert case["exit_code"] == 8 and case["app_marker"] == marker, case
        assert case["previous_marker"] == "installed" and case["nested_previous_marker"] is None, (
            case
        )
        assert case["opened"] == "" and "the previous one is back" not in case["stdout"], case
    assert publication["exit_code"] == 6 and publication["app_marker"] == "installed"
    assert (
        publication["previous_marker"] is None
        and publication["opened"] == publication["app_path"] + "\n"
    )
    for case in refused:
        assert case["exit_code"] != 0 and not case["arming_observed"], case
        assert case["app_marker"] == "installed" and case["previous_marker"] is None, case
        assert case["opened"] == "" and case["nested_previous_marker"] is None, case
    assert healthy["previous_identity"] == healthy["original_identity"]
    assert publication["app_identity"] == publication["original_identity"]
    assert all(case["app_identity"] == case["original_identity"] for case in refused)
    assert all(
        case["previous_identity"] == case["original_identity"] for case in [occupied, partial]
    )
    parser_cases = parser_controls(source.read_text(encoding="utf-8"))
    return {"platform": sys.platform, "cases": cases, "parser_refusals": parser_cases}


def qualify(cases):
    """Require the historical failure and every independent candidate contract."""
    by_name = {case["name"]: case for case in cases}
    assert len(by_name) == len(cases) == 10, "The complete physical case census must execute"
    old = by_name["old-cross-device-copy-failure"]
    assert old["stage_device"] != old["parent_device"]
    assert old["exit_code"] == 6 and old["arming_observed"]
    # Directory traversal order differs across filesystems: the sibling marker
    # need not copy before the large file fails. The original is still nested.
    assert old["app_marker"] != "installed" and old["large_size"] == 256
    assert old["app_identity"] != old["original_identity"]
    assert old["previous_marker"] is None and old["nested_previous_marker"] == "installed"
    assert "the previous one is back" in old["stdout"]
    healthy = by_name["parent-stage-external-tmp"]
    assert healthy["temporary_device"] != healthy["parent_device"], "TMPDIR must really be external"
    assert healthy["stage_device"] == healthy["parent_device"]
    assert healthy["previous_identity"] == healthy["original_identity"]
    assert healthy["exit_code"] == 0 and healthy["app_marker"] == "chosen"
    assert healthy["previous_marker"] == "installed" and healthy["large_size"] == 8192
    assert healthy["opened"] == healthy["app_path"] + "\n" and not healthy["staged_exists"]
    for name in [
        "foreign-device-before-arming",
        "device-observation-refused",
        "device-observation-invalid",
        "missing-candidate",
        "symlink-candidate",
    ]:
        case = by_name[name]
        assert case["exit_code"] != 0 and not case["arming_observed"], name
        assert case["app_marker"] == "installed" and case["previous_marker"] is None, name
        assert case["opened"] == "" and case["nested_previous_marker"] is None, name
    for name, marker in [
        ("occupied-publication-target", "foreign"),
        ("partial-publication-target", "partial"),
    ]:
        case = by_name[name]
        assert case["exit_code"] == 8 and case["arming_observed"], name
        assert case["app_marker"] == marker and case["previous_marker"] == "installed", name
        assert case["nested_previous_marker"] is None and case["opened"] == "", name
        assert "the previous one is back" not in case["stdout"], name
    restored = by_name["publication-refusal-restores-original"]
    assert restored["app_identity"] == restored["original_identity"]
    assert restored["exit_code"] == 6 and restored["app_marker"] == "installed"
    assert restored["previous_marker"] is None and restored["nested_previous_marker"] is None
    assert restored["opened"] == restored["app_path"] + "\n"
    assert all(case["stage_mode"] == 0o700 for case in cases)


def main():
    if not __debug__:
        raise RuntimeError("Release swap regressions require Python assertions to be enabled")
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["emit", "stat", "physical", "native", "controls"])
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.mode == "stat":
        native_stat_port(args.arguments)
    elif args.mode == "emit":
        sys.stdout.write(extract_program(Path(args.arguments[0]).read_text(encoding="utf-8")))
    elif args.mode == "controls":
        source, root = map(Path, args.arguments)
        print(json.dumps(controls(root, source)))
    else:
        source, root, external = map(Path, args.arguments)
        if args.mode == "native" and sys.platform != "darwin":
            raise ValueError("Native release swap receiving requires Darwin")
        print(json.dumps(probe(root, source, external, args.mode == "native")))


if __name__ == "__main__":
    main()
