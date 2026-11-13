#!/usr/bin/env bash
# tools/dev/linux-field-run.sh

# ==============================================================================
# MODULE: Linux field run request
# DESCRIPTION:
# Asks the running Linux daemon to run its Debug field checks with no window
# (static/ergopti_plus/linux/diagnostics/engine/field_run/field_run.lua, on the shared protocol
# static/ergopti_plus/_shared/diagnostics/data/field_run_protocol.json and the Linux steps
# file it names): it writes the request into the folder of the daemon that is
# ready, waits for the done marker or a refusal, copies the
# results into the report and prints one mark per step, the macOS collector's
# marks (✅ pass, ❌ fail, ⏭️ skip, ⌨️ needs_typing, ⚠️ other), then a summary line.
#
# FEATURES & RATIONALE:
# 1. The folders, the file names, the every-step word and the default deadline
#    come from the driver itself through luajit: one source for the daemon and
#    the collector. The developer folder (the clone's) is tried first, then the
#    installed one, as the shared declaration says.
# 2. No daemon ready (no ready.json, or its process is gone) is said and is not
#    a collector failure: the shell checks and the logs are still collected.
# 3. The request is staged then renamed, so the daemon never reads half of it.
#
# Sourced only; defines functions and runs nothing.
# ==============================================================================

# Prints the developer folder, the installed folder (empty without
# XDG_RUNTIME_DIR), the ready, request, refused, results and done names, the
# every-step word, the schema and the default deadline, one per line, as the driver resolves them.
field_run_layout() {
	local driver_root="$1/static/ergopti_plus/linux" shared="$1/static/ergopti_plus/_shared"
	# luajit -e takes no script arguments: the roots travel in the environment.
	FIELD_RUN_CLONE_ROOT="$1" FIELD_RUN_DRIVER_ROOT="$driver_root" FIELD_RUN_SHARED_ROOT="$shared" \
	LUA_PATH="$driver_root/?.lua;$driver_root/?/init.lua;$shared/lua/?.lua;$shared/lua/?/init.lua;;" luajit -e '
		local FieldRun = require("diagnostics.engine.field_run.field_run")
		local spec = FieldRun.load(os.getenv("FIELD_RUN_SHARED_ROOT"), os.getenv("FIELD_RUN_DRIVER_ROOT"))
		print(FieldRun.folder(spec, os.getenv, os.getenv("FIELD_RUN_CLONE_ROOT")))
		print(FieldRun.folder(spec, os.getenv, nil) or "")
		print(spec.files.ready); print(spec.files.request); print(spec.files.refused)
		print(spec.files.results); print(spec.files.done); print(spec.all_steps); print(spec.schema)
		print(spec.deadline_seconds.default)'
}

# Prints the pid a ready file names when that process is alive.
field_run_ready_pid() {
	local pid
	pid="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null)"
	[ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && printf '%s\n' "${pid}"
}

# Installs Ergopti's Python before the field run, so the composer check runs
# without a click: the maintainer who runs the collector gave the consent, said
# in one line before the download. A failure is printed and the composer check
# then reports SKIP python_not_installed with its reason.
# $1 the clone root. Prints field_python=installed or field_python=<code>.
field_linux_ensure_python() {
	local driver_root="$1/static/ergopti_plus/linux" shared="$1/static/ergopti_plus/_shared"
	LUA_PATH="$driver_root/?.lua;$driver_root/?/init.lua;$shared/lua/?.lua;$shared/lua/?/init.lua;;" luajit -e '
		local uv = require("luv")
		local Pins = require("_generated.native_runtime").managed_python
		local outcome
		require("modules.keymap.layout_registry").install_python(function(bytes)
			io.write(string.format("  ⬇️ Installing Ergopti'"'"'s Python %s (%d MB) for the composer check: "
				.. "running this collector is the consent.\n", Pins.version, math.ceil(bytes / 1048576)))
			io.flush()
			return true
		end, function(ok, value) outcome = { ok, value } end)
		while not outcome and uv.loop_alive() do uv.run("once") end
		print("field_python=" .. (outcome and outcome[1] and "installed" or tostring(outcome and outcome[2] or "unsettled")))'
}

# Runs the field checks of the daemon and copies their results.
# $1 the clone root, $2 the report folder. Prints the marks and the summary.
field_linux_run() {
	local root="$1" out="$2" layout clone installed folder ready request refused results done all schema deadline id waited
	if ! layout="$(field_run_layout "${root}" 2>&1)"; then
		printf 'field_run=unresolved\n%s\n' "${layout}"
		return 1
	fi
	{ read -r clone; read -r installed; read -r ready; read -r request; read -r refused; read -r results; read -r done; read -r all; read -r schema; read -r deadline; } <<< "${layout}"
	folder=""
	if field_run_ready_pid "${clone}/${ready}" > /dev/null; then
		folder="${clone}"
	elif [ -n "${installed}" ] && field_run_ready_pid "${installed}/${ready}" > /dev/null; then
		folder="${installed}"
	fi
	if [ -z "${folder}" ]; then
		printf '  ⚠️ field run: no running daemon published its field run session\n'
		printf 'field_run=no_daemon\n'
		return 0
	fi
	id="fr-$(date +%Y%m%d%H%M%S)-$$"
	rm -f "${folder}/${refused}"
	printf '{"schema":%s,"request_id":"%s","steps":["%s"]}' "${schema}" "${id}" "${all}" > "${folder}/${request}.tmp-$$"
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
