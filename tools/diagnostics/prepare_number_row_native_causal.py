"""Private proposed dedicated one-omission source preparer; never executes Swift."""

from pathlib import Path, PurePosixPath
import hashlib, json, subprocess, sys

# Five explicit paths/identity; unknown arity refuses before allocation.
if len(sys.argv) != 6:
    raise SystemExit("head recipe projection evidence receiver required")
head, recipe_path, projection_path, evidence_path, receiver_path = sys.argv[1:]
projection, evidence = Path(projection_path), Path(evidence_path)
if subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != head:
    raise SystemExit("actual CI source commit refused")
for path, expected in [
    (recipe_path, "77118a5238f504b1475988957843427f61aaaa798ab9f972e812205a2fb5b7ba"),
    (receiver_path, "5aaadaed103f6458ef01cec87474b8de8f9eb1584008338332baa199157632fd"),
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
