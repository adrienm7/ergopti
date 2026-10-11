"""Private proposed dedicated one-omission source preparer; never executes Swift."""

from pathlib import Path, PurePosixPath
import hashlib, json, subprocess, sys

# This opt-in source composition is not an invocation/native acceptance path.
# External approval/composition digests must come from independent receiving.
if len(sys.argv) > 1 and sys.argv[1] in ("--composition", "--composition-controls"):
    controls_projection = sys.argv[-1] if sys.argv[1] == "--composition-controls" else None
    if len(sys.argv) != (13 if controls_projection is not None else 12):
        raise SystemExit(
            "composition requires head recipe projection evidence receiver receiverSHA composition compositionSHA approval approvalSHA [historicalControlsProjection for --composition-controls]"
        )
    (
        head,
        recipe_path,
        projection_path,
        evidence_path,
        receiver_path,
        receiver_sha,
        composition_path,
        composition_sha,
        approval_path,
        approval_sha,
    ) = sys.argv[2:12]
    if (
        receiver_path != "tools/diagnostics/number_row_native_causal.py"
        or receiver_sha != "d913505e2d3522d5023227b947f3c7896ba3ef4aeadfbd0c1a7042fa9686c148"
    ):
        raise SystemExit("exact reviewed composition receiver required")
    if (
        recipe_path
        != "tools/diagnostics/fixtures/number-row-native-causal/projection-manifest.original-c15.json.raw"
    ):
        raise SystemExit("original historical recipe path required")
    control_pins = {
        receiver_path: receiver_sha,
        recipe_path: "77118a5238f504b1475988957843427f61aaaa798ab9f972e812205a2fb5b7ba",
        "tools/diagnostics/keyboard_geometry_xctest_receipt.py": "9cef4f9256f3604ac07d710d77c95424718012f23c6a8b472f9e5936253ac094",
        "tools/diagnostics/tis_evidence_transport.cjs": "f62344840267ab207370df974cc344fce83cbe3b758f2a25c986837a41d04269",
        "tools/diagnostics/test_number_row_native_causal.py": "f058b0937e278229f2b348d07c65c8e73c575dbb12cbbde53713ab91d3df9ca2",
        "tools/diagnostics/fixtures/number-row-native-causal/fixture-manifest.json.raw": "50fbec17bdd2f624bf65c6e16613deb2c0ddd2b9d6eff10a640520780770b8d1",
    }
    if subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != head:
        raise SystemExit("actual source commit refused")
    admitted_images = {}
    for path, expected in control_pins.items():
        item = Path(path)
        data = item.read_bytes()
        if (
            item.is_symlink()
            or not item.is_file()
            or hashlib.sha256(data).hexdigest() != expected
            or data != subprocess.check_output(["git", "show", head + ":" + path])
        ):
            raise SystemExit("reviewed composition control source drift refused")
        admitted_images[path] = data
    from types import ModuleType

    positive_path = "tools/diagnostics/keyboard_geometry_xctest_receipt.py"
    positive_name = "keyboard_geometry_xctest_receipt"
    missing = object()
    previous = sys.modules.get(positive_name, missing)
    positive = ModuleType(positive_name)
    positive.__file__ = str(Path(positive_path).resolve())
    module = ModuleType("reviewed_number_row_composition")
    module.__file__ = str(Path(receiver_path).resolve())
    try:
        sys.modules[positive_name] = positive
        exec(compile(admitted_images[positive_path], positive.__file__, "exec"), positive.__dict__)
        exec(compile(admitted_images[receiver_path], module.__file__, "exec"), module.__dict__)
    finally:
        if previous is missing:
            sys.modules.pop(positive_name, None)
        else:
            sys.modules[positive_name] = previous
    module.materialize_composed_projection(
        Path.cwd(),
        head,
        Path(recipe_path),
        Path(approval_path),
        approval_sha,
        Path(composition_path),
        composition_sha,
        Path(projection_path),
        Path(evidence_path),
    )
    if controls_projection is not None:
        module.materialize_historical_controls(
            Path.cwd(),
            head,
            Path(recipe_path),
            Path(approval_path),
            approval_sha,
            Path(composition_path),
            composition_sha,
            Path(controls_projection),
            Path(evidence_path),
            Path(projection_path),
        )
    raise SystemExit(0)

# Five explicit paths/identity; unknown arity refuses before allocation.
if len(sys.argv) != 6:
    raise SystemExit("head recipe projection evidence receiver required")
head, recipe_path, projection_path, evidence_path, receiver_path = sys.argv[1:]
projection, evidence = Path(projection_path), Path(evidence_path)
if subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != head:
    raise SystemExit("actual CI source commit refused")
for path, expected in [
    (recipe_path, "77118a5238f504b1475988957843427f61aaaa798ab9f972e812205a2fb5b7ba"),
    (receiver_path, "d913505e2d3522d5023227b947f3c7896ba3ef4aeadfbd0c1a7042fa9686c148"),
    (
        "tools/diagnostics/keyboard_geometry_xctest_receipt.py",
        "9cef4f9256f3604ac07d710d77c95424718012f23c6a8b472f9e5936253ac094",
    ),
    (
        "tools/diagnostics/tis_evidence_transport.cjs",
        "f62344840267ab207370df974cc344fce83cbe3b758f2a25c986837a41d04269",
    ),
    (
        "tools/diagnostics/test_number_row_native_causal.py",
        "f058b0937e278229f2b348d07c65c8e73c575dbb12cbbde53713ab91d3df9ca2",
    ),
    (
        "tools/diagnostics/fixtures/number-row-native-causal/fixture-manifest.json.raw",
        "50fbec17bdd2f624bf65c6e16613deb2c0ddd2b9d6eff10a640520780770b8d1",
    ),
]:
    data = Path(path).read_bytes()
    if hashlib.sha256(data).hexdigest() != expected or data != subprocess.check_output(
        ["git", "show", head + ":" + path]
    ):
        raise SystemExit("reviewed receiver/input image drift refused")

recipe_bytes = Path(recipe_path).read_bytes()
if (
    hashlib.sha256(recipe_bytes).hexdigest()
    != "77118a5238f504b1475988957843427f61aaaa798ab9f972e812205a2fb5b7ba"
):
    raise SystemExit("reviewed source-image recipe refused")
recipe = json.loads(recipe_bytes)
repo = Path.cwd().resolve()
if projection.resolve().is_relative_to(repo) or repo.is_relative_to(projection.resolve()):
    raise SystemExit("outside projection required")
if projection.is_symlink() or not projection.is_dir() or any(projection.iterdir()):
    raise SystemExit("fresh owned projection refused")
if len(recipe["paths"]) != 99 or len({row["path"] for row in recipe["paths"]}) != 99:
    raise SystemExit("exact reviewed package input census refused")
rows, original = [], None
needle = b"Data(bytes: currentBytes, count: CFDataGetLength(currentData)) == originalBytes"
producer = recipe["permitted_omission"]["path"]
for row in recipe["paths"]:
    rel = PurePosixPath(row["path"])
    if rel.is_absolute() or ".." in rel.parts:
        raise SystemExit("unsafe package input path refused")
    spec = head + ":" + row["path"]
    data = subprocess.check_output(["git", "show", spec])
    blob = subprocess.check_output(["git", "rev-parse", spec], text=True).strip()
    if blob != row["git_blob"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
        raise SystemExit("reviewed source input drift refused: " + row["path"])
    if row["path"] == producer:
        original = data
        if data.count(needle) != 1:
            raise SystemExit("unique final-byte omission refused")
        data = data.replace(needle, b"true", 1)
    target = projection / row["path"]
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("xb") as stream:
        stream.write(data)
    rows.append(
        {
            **row,
            "actual_commit": head,
            "projected_sha256": hashlib.sha256(data).hexdigest(),
            "projected_git_blob": None if row["path"] == producer else blob,
        }
    )
if original is None:
    raise SystemExit("original producer absent")
with (evidence / "NumberRowSourceProbe.original.swift").open("xb") as stream:
    stream.write(original)
with (evidence / "actual-git-projection.json").open("x") as stream:
    json.dump(
        {
            "actual_commit": head,
            "recipe_historical_head": recipe["original_head"],
            "image_role": "private-counterfactual-not-canonical-product",
            "paths": rows,
        },
        stream,
    )
