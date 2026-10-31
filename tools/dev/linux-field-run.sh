#!/usr/bin/env bash
# tools/dev/linux-field-run.sh

# ==============================================================================
# MODULE: Linux field run request
# DESCRIPTION:
# Asks the running Linux daemon to run its Debug field checks with no window
# (static/ergopti_plus/linux/infra/field_run.lua, declared by
# static/ergopti_plus/linux/data/field_run.json): it writes the request into the
# daemon's field-run folder, waits for the done marker or a refusal, copies the
# results into the report and prints one mark per step, the macOS collector's
# marks (✅ pass, ❌ fail, ⏭️ skip, ⌨️ needs_typing, ⚠️ other), then a summary line.
#
# FEATURES & RATIONALE:
# 1. The folder, the file names and the default deadline come from the driver
#    itself through luajit: one source for the daemon and the collector.
# 2. No daemon ready (no ready.json, or its process is gone) is said and is not
#    a collector failure: the shell checks and the logs are still collected.
# 3. The request is staged then renamed, so the daemon never reads half of it.
#
# Sourced only; defines functions and runs nothing.
# ==============================================================================

# Prints the folder, the request, refused, results and done names and the
# default deadline, one per line, as the driver resolves them.
field_run_layout() {
	local driver_root="$1/static/ergopti_plus/linux" shared="$1/static/ergopti_plus/_shared/lua"
	# luajit -e takes no script arguments: the driver root travels in the environment.
	FIELD_RUN_DRIVER_ROOT="$driver_root" \
	LUA_PATH="$driver_root/?.lua;$driver_root/?/init.lua;$shared/?.lua;$shared/?/init.lua;;" luajit -e '
		local FieldRun = require("infra.field_run")
		local file = assert(io.open(os.getenv("FIELD_RUN_DRIVER_ROOT") .. "/data/field_run.json", "rb"))
		local spec = FieldRun.validate(require("json").decode(file:read("*a")))
		file:close()
		local folder = assert(FieldRun.folder(spec, os.getenv, require("app_dirs").folder_name))
		print(folder); print(spec.files.ready); print(spec.files.request); print(spec.files.refused)
		print(spec.files.results); print(spec.files.done); print(spec.deadline_seconds.default)'
}

# Runs the field checks of the daemon and copies their results.
# $1 the clone root, $2 the report folder. Prints the marks and the summary.
field_linux_run() {
	local root="$1" out="$2" layout folder ready request refused results done deadline pid id waited
	if ! layout="$(field_run_layout "${root}" 2>&1)"; then
		printf 'field_run=unresolved\n%s\n' "${layout}"
		return 1
	fi
	{ read -r folder; read -r ready; read -r request; read -r refused; read -r results; read -r done; read -r deadline; } <<< "${layout}"
	pid="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "${folder}/${ready}" 2>/dev/null)"
	if [ -z "${pid}" ] || ! kill -0 "${pid}" 2>/dev/null; then
		printf '  ⚠️ field run: no running daemon published its field run session\n'
		printf 'field_run=no_daemon\n'
		return 0
	fi
	id="fr-$(date +%Y%m%d%H%M%S)-$$"
	rm -f "${folder}/${refused}"
	printf '{"schema":1,"request_id":"%s","steps":["all"]}' "${id}" > "${folder}/${request}.tmp-$$"
	mv -f "${folder}/${request}.tmp-$$" "${folder}/${request}"
	# The daemon's own request deadline plus a grace for its last write.
	waited=0
	while [ "${waited}" -lt $((deadline + 30)) ]; do
		[ -f "${folder}/${results}/${id}/${done}" ] && break
		if [ -f "${folder}/${refused}" ] && grep -q "\"request_id\":\"${id}\"" "${folder}/${refused}"; then
			printf '  ⚠️ field run refused: %s\n' "$(sed -n 's/.*"reason":"\([a-z_]*\)".*/\1/p' "${folder}/${refused}")"
			printf 'field_run=refused\n'
			return 1
		fi
		sleep 1
		waited=$((waited + 1))
	done
	if [ ! -f "${folder}/${results}/${id}/${done}" ]; then
		printf '  ⚠️ field run: no done marker after %s s\n' "${waited}"
		printf 'field_run=timeout\n'
		return 1
	fi
	mkdir -p "${out}/field_run"
	cp "${folder}/${results}/${id}"/*.json "${out}/field_run/"
	python3 - "${out}/field_run" "${done}" <<'EOF'
import json, pathlib, sys
folder, done_name = pathlib.Path(sys.argv[1]), sys.argv[2]
marks = {"pass": "✅", "fail": "❌", "skip": "⏭️", "needs_typing": "⌨️"}
counts = {"pass": 0, "fail": 0, "skip": 0, "needs_typing": 0, "other": 0}
for path in sorted(folder.glob("[0-9][0-9]_*.json")):
    step = json.loads(path.read_text(encoding="utf-8"))
    verdict = step.get("verdict", "unreadable")
    counts[verdict if verdict in counts else "other"] += 1
    codes = ",".join(step.get("codes") or []) or "none"
    print("  %s field run %s: %s (%s)" % (marks.get(verdict, "⚠️"), step.get("step"), verdict, codes))
done = json.loads((folder / done_name).read_text(encoding="utf-8"))
print("Field run summary: ✅ %d pass, ❌ %d fail, ⏭️ %d skip, ⌨️ %d needs_typing, ⚠️ %d other%s." % (
    counts["pass"], counts["fail"], counts["skip"], counts["needs_typing"], counts["other"],
    " (interrupted)" if done.get("interrupted") else ""))
EOF
	printf 'field_run=%s\n' "${id}"
}
