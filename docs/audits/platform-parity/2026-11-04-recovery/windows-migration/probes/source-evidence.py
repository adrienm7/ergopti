from pathlib import Path
import hashlib, subprocess, json

root = Path("/workspace/ergopti")
sha = "3a680d9f530a9af686fccc16d3f7611ec7fb034c"
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip() == sha
base = root / "static/ergopti_plus/windows"
src = (base / "infra/legacy_folder_migration.ahk").read_text(encoding="utf-8-sig")
boot = (base / "infra/boot.ahk").read_text(encoding="utf-8-sig")
fs = (base / "adapters/file_system.ahk").read_text(encoding="utf-8-sig")
transition = (base / "infra/config_transition.ahk").read_text(encoding="utf-8-sig")
run = src.split("LegacyFolderMigrationRun(PathsFile) {", 1)[1].split(
    "; Logs a migration report", 1
)[0]
assert run.index("LegacyFolderMoveEntry(LegacyConfig, NewConfig") < run.index(
    "LegacyFolderRewritePathsFile(PathsFile, Rewrites)"
)
assert 'Report["kept"]' not in run and "throw" not in run and "return Report" in run
assert "if !FSCopyCreateVerified(Path, Backup) || !FSWrite(Path, Rewritten)" in src
assert (
    'for Old in Rule["old"]' in src
    and "LegacyFolderNormalize(Match[4]) != LegacyFolderNormalize(Old)" in src
)
assert '\'^(\\s*)(\\w+)(\\s*=\\s*)"([^"]*)"(.*)$\'' in src
assert 'CONFIG_TRANSITION_WAL_SUFFIX := ".config-transition.wal"' in transition
assert "config-transition" not in src
assert boot.index("LegacyFolderMigrationRun(_PathsFile)") < boot.index(
    "ConfigTransitionRecoverAtBootOrThrow(_PathsFile)"
)
assert 'OpenFn.Call(Path, "w", "UTF-8-RAW")' in fs and "if Opened && !Succeeded" in fs
entry = (base / "ErgoptiPlus.ahk").read_text(encoding="utf-8-sig")
assert entry.index('DRIVER_MUTEX_NAME := "Local\\ErgoptiPlusDriver"') < entry.index(
    "#Include infra/boot.ahk"
)
rows = []
for path in [
    "infra/legacy_folder_migration.ahk",
    "infra/boot.ahk",
    "adapters/file_system.ahk",
    "infra/config_transition.ahk",
    "infra/config_transition_runtime.ahk",
    "infra/toml/toml_helpers.ahk",
    "ErgoptiPlus.ahk",
]:
    raw = (base / path).read_bytes()
    rows.append({"path": str(base / path), "sha256": hashlib.sha256(raw).hexdigest()})
receipt = {
    "audited_sha": sha,
    "basis": "executed source assertions only; no AutoHotkey/native Windows execution",
    "owners": rows,
    "confirmed_mechanisms": [
        "unconditional rebase after independent move outcomes",
        "exact-only identity matching",
        "bare-key double-quoted-string regex",
        "old locator journal not transferred or recovered",
    ],
    "refuted": "ordinary concurrent drivers fenced by preboot unchanged named mutex",
}
print(json.dumps(receipt, indent=2))
