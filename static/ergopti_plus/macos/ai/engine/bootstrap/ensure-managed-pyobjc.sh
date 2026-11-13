#!/bin/bash
# ai/engine/bootstrap/ensure-managed-pyobjc.sh
# Installs the pinned PyObjC wheels of ../managed-pyobjc.json into Ergopti's
# managed Python, for the App Cloner helpers and the launchers it writes. Each
# wheel is downloaded with its pinned size and SHA-256 before uv installs it
# offline, without dependencies; the import check then proves the closed set.
# Prints `PYOBJC_READY<TAB><stable link>` on success (app-cloner/python3, a
# versionless link to the managed interpreter); any refusal exits non-zero
# with the stage named on stderr. Never touches /usr/bin/python3.

set -eu
set -o pipefail
if [ -n "${ERGOPTI_BOOTSTRAP_SNAPSHOT:-}" ] && [ "$0" = "$ERGOPTI_BOOTSTRAP_SNAPSHOT" ] \
	&& [ -n "${ERGOPTI_BOOTSTRAP_SCRIPT_DIR:-}" ]; then
	SCRIPT_DIR="$ERGOPTI_BOOTSTRAP_SCRIPT_DIR"
else
	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
source "$SCRIPT_DIR/network-retry.sh"
source "$SCRIPT_DIR/native_python_bootstrap.sh"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

BOOTSTRAP_STAGE="start"
PYOBJC_WORK=""

bootstrap_stage() {
	BOOTSTRAP_STAGE="$1"
	printf '[PYOBJC] stage: %s\n' "$1" >&2
}

# Names the stage a failed run stopped in, and removes the download folder.
finish() {
	local status=$?
	if [ -n "$PYOBJC_WORK" ] && [ -d "$PYOBJC_WORK" ] && [ ! -L "$PYOBJC_WORK" ] && [ -O "$PYOBJC_WORK" ]; then
		rm -rf "$PYOBJC_WORK"
	fi
	[ "$status" -eq 0 ] || printf '[PYOBJC] ERROR: stage %s ended with exit %s.\n' "$BOOTSTRAP_STAGE" "$status" >&2
}
trap finish EXIT

ROOT="$HOME/Library/Application Support/Ergopti/native-bootstrap"
MANIFEST="$SCRIPT_DIR/managed-pyobjc.json"
[ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || exit 78

# Only the canonical pinned bootstrap may supply the interpreter.
unset ERGOPTI_BOOTSTRAP_PYTHON
bootstrap_stage python_bootstrap
native_bootstrap_python "$ROOT"
interpreter="$ERGOPTI_BOOTSTRAP_PYTHON"

bootstrap_stage manifest
# One wheel per line: file name, URL, SHA-256 and size, each refused unless it
# has the shape the manifest declares; then the import check's module names.
manifest_lines="$("$interpreter" -I -c '
import json, re, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == 1 and data["python_tag"] == "cp%d%d" % sys.version_info[:2]
for wheel in data["wheels"]:
    name, url, digest, size = wheel["file_name"], wheel["url"], wheel["sha256"], wheel["size"]
    assert re.fullmatch(r"[A-Za-z0-9_.]+-[0-9.]+-" + data["python_tag"] + r"-[A-Za-z0-9_.-]+\.whl", name)
    assert url.startswith("https://files.pythonhosted.org/") and url.endswith("/" + name)
    assert re.fullmatch(r"[0-9a-f]{64}", digest) and type(size) is int and size > 0
    print("wheel\t%s\t%s\t%s\t%d" % (name, url, digest, size))
for module in data["import_check"]:
    assert re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", module)
    print("import\t" + module)
' "$MANIFEST")" || exit 78

PYOBJC_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-pyobjc.XXXXXX")"
wheels=()
modules=()
while IFS=$'\t' read -r kind first url digest size; do
	case "$kind" in
		wheel)
			bootstrap_stage "download_$first"
			managed_bootstrap_download "$url" "$PYOBJC_WORK/$first" "$digest" "$size" resilient
			wheels+=("$PYOBJC_WORK/$first")
			;;
		import) modules+=("$first") ;;
		*) exit 78 ;;
	esac
done <<< "$manifest_lines"
[ "${#wheels[@]}" -gt 0 ] && [ "${#modules[@]}" -gt 0 ] || exit 78

bootstrap_stage install
# uv marks its managed Pythons externally managed; this private prefix is Ergopti's own.
"$ROOT/bin/uv" pip install --python "$interpreter" --break-system-packages --no-deps --no-index \
	--offline --no-config --reinstall "${wheels[@]}" >&2

bootstrap_stage import_check
"$interpreter" -I -c 'import importlib, sys
for module in sys.argv[1:]:
    importlib.import_module(module)' "${modules[@]}"

bootstrap_stage stable_link
# The launchers App Cloner writes exec this versionless link, so a clone keeps
# working when a later managed Python replaces the versioned interpreter: the
# next run of this installer points the link at the new one. It is replaced
# atomically and only ever names an interpreter under the private prefix.
case "$interpreter" in "$ROOT/python/"*) ;; *) exit 78 ;; esac
link_dir="$ROOT/app-cloner"
mkdir -p "$link_dir"
[ ! -L "$link_dir" ] && [ -d "$link_dir" ] || exit 78
ln -s "$interpreter" "$link_dir/.python3.$$"
mv -f "$link_dir/.python3.$$" "$link_dir/python3"
[ "$(readlink "$link_dir/python3")" = "$interpreter" ] || exit 78

printf 'PYOBJC_READY\t%s\n' "$link_dir/python3"
