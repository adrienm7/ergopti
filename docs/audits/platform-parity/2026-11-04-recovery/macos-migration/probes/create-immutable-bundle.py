from pathlib import Path
import subprocess, json, hashlib

sha = "3a680d9f530a9af686fccc16d3f7611ec7fb034c"
base = Path(__file__).resolve().parent.parent
bundle = base / "probes/immutable-bundle"
files = {
    "adapters/legacy_folder_migration.lua": "macos/adapters/legacy_folder_migration.lua",
    "legacy_folder_migration.lua": "_shared/lua/legacy_folder_migration.lua",
    "app_dirs.lua": "_shared/lua/app_dirs.lua",
    "native_path.lua": "_shared/lua/native_path.lua",
}
rows = []
for dest, source in files.items():
    path = "static/ergopti_plus/" + source
    data = subprocess.check_output(["git", "show", sha + ":" + path], cwd="/workspace/ergopti")
    target = bundle / dest
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    rows.append(
        dict(
            bundle_path=str(target),
            source_path=path,
            git_blob=subprocess.check_output(
                ["git", "rev-parse", sha + ":" + path], cwd="/workspace/ergopti", text=True
            ).strip(),
            sha256=hashlib.sha256(data).hexdigest(),
        )
    )
(base / "logs/immutable-bundle-provenance.json").write_text(
    json.dumps(
        dict(
            audited_sha=sha, command="git show <sha>:<source_path> (captured as bytes)", files=rows
        ),
        indent=2,
    )
    + "\n"
)
joins = []
for source in [
    "macos/init.lua",
    "macos/infra/config_paths.lua",
    "macos/launcher/Sources/ErgoptiPlus/main.swift",
    "_shared/modules/paths/app_dirs.toml",
]:
    path = "static/ergopti_plus/" + source
    data = subprocess.check_output(["git", "show", sha + ":" + path], cwd="/workspace/ergopti")
    target = base / "logs/immutable-source-joins" / source
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    joins.append(
        dict(source_path=path, scratch_path=str(target), sha256=hashlib.sha256(data).hexdigest())
    )
(base / "logs/immutable-source-joins.json").write_text(
    json.dumps(dict(audited_sha=sha, files=joins), indent=2) + "\n"
)
print("4 immutable Git-blob modules extracted; no live production module loaded")
