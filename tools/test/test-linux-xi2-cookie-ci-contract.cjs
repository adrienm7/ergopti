// tools/test/test-linux-xi2-cookie-ci-contract.cjs
// Source controls for the isolated non-input native receiving cut; no native runs.
'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const pipeline = require('./ci-pipeline.cjs');
const ROOT = path.resolve(__dirname, '..', '..');
const HARDWARE = 'static/ergopti_plus/linux/tests/hardware/';
const sha = (value) => crypto.createHash('sha256').update(value).digest('hex');
const BLOCK =
	'      # Non-input C qualification uses the original exact full-family owner.\n      # This separate native receipt does not qualify the deferred E2E suite.\n      - name: Qualify three actual XI2 property cookies\n        id: native_xi2_cookies\n        if: ${{ !cancelled() }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py" -y --no-install-recommends gcc libx11-dev libxi-dev xvfb\n          set +e\n          python3 static/ergopti_plus/linux/tests/hardware/run_xi2_property_cookies.py "$RUNNER_TEMP/linux-xi2-property-cookies" 2>&1 | tee "$RUNNER_TEMP/linux-xi2-property-cookies.log"\n          xi2_pipeline_status=("${PIPESTATUS[@]}")\n          set -e\n          if [ "${#xi2_pipeline_status[@]}" -ne 2 ]; then exit 1; fi\n          if [ "${xi2_pipeline_status[0]}" -ne 0 ]; then exit "${xi2_pipeline_status[0]}"; fi\n          exit "${xi2_pipeline_status[1]}"\n        timeout-minutes: 5\n\n      - name: Retain actual XI2 property-cookie evidence\n        if: always()\n        uses: actions/upload-artifact@v4\n        with:\n          name: linux-xi2-property-cookies-${{ github.sha }}-${{ github.run_attempt }}\n          retention-days: 7\n          path: |\n            ${{ runner.temp }}/linux-xi2-property-cookies\n            ${{ runner.temp }}/linux-xi2-property-cookies.log\n          if-no-files-found: error\n\n';
const PINS = {
	c_source_sha256: '7e4f9d4c2615248787a05efa96dd8f464a8eebdd3e2267b9083e351a78c33e32',
	header_sha256: '96b02b21619deb2148b279e2b8dc183b311f1ab66aa57c7dbcef669d285691be',
	family_sha256: '7545c2d6aa8d48e5d48557b2b218e6d8a864eeb42ae761e055d4f917cdf06334'
};
const RUNNER_NEED = [
	'CASES = ["property-created", "property-modified", "property-deleted"]',
	'digest(FAMILY) == FAMILY_SHA',
	'"--receipt-fd",\n                    str(writer),\n                    "--token",\n                    token,\n                    "--",\n                    *command',
	'code = supervisor.wait()',
	'[row["stage"] for row in frames] == ["ready", "settled"]',
	'row["token"] == token',
	'row["supervisor"] == supervisor.pid',
	'terminal["namespace_absent"] is True',
	'terminal["acquired"] == terminal["reaped"] == terminal["closed"] >= 1',
	'terminal["status"] == code == 0',
	'["git", "show", source_sha + ":" + relative]',
	'"source must equal exact Git image"',
	'compiler_terminal = family_run(directory, "compile", command, 60, environment)',
	'native_terminal = family_run(\n            directory,\n            "native",\n            [',
	'            ],\n            25,\n            environment,\n        )',
	'display["rescue"] == 0',
	'display["termination_requested"] is True',
	'display["server_pidfd_closed"] is True',
	'facts["fetched"] == facts["freed"] == facts["published"] == len(CASES) == 3',
	'not (directory / "native.stderr").read_bytes()',
	'digest(executable) == executable_sha',
	'digest(ROOT / name) == sha',
	'qualified=False',
	'result.update(\n            qualified=True',
	'record(directory / "receiving.json", result)'
];
const DISPLAY_NEED = [
	'signal.pidfd_send_signal(server_pidfd, signal.SIGTERM)',
	'termination_requested = True',
	'assert leader.poll() is None, "owned Xvfb exited before native connection"',
	'assert leader.poll() is None, "owned Xvfb exited before native completion"',
	'facts["server_peer_pid"] == leader.pid',
	'facts["server_peer_uid"] == os.getuid()',
	'receipt["premature_xvfb_exit"] = True',
	'not termination_requested or receipt["xvfb_exit"] not in (0, -signal.SIGTERM)',
	'receipt["server_pidfd_closed"] = True',
	'if rescue:\n            result = 1'
];
function verify(subject) {
	assert.strictEqual(
		subject.workflow.split(BLOCK).length,
		2,
		'exact fatal step and always artifact'
	);
	// Use the real independent CI parser and its existing graph/field contracts.
	// Exact whole-file preimages belong to private receiving receipts only.
	const jobs = pipeline.jobsOfText(subject.workflow, '.github/workflows/ci-linux.yml');
	const required = ['test-linux', 'e2e-linux', 'package-linux', 'install-linux', 'linux-ok'];
	for (const id of required)
		assert.strictEqual(
			jobs.filter((job) => job.id === id).length,
			1,
			'original mandatory job ' + id
		);
	const owner = jobs.find((job) => job.id === 'e2e-linux');
	const gate = jobs.find((job) => job.id === 'linux-ok');
	assert.strictEqual(pipeline.field(owner.body, 'runs-on'), 'ubuntu-latest');
	assert.strictEqual(pipeline.field(owner.body, 'if'), null, 'ordinary mandatory owner admission');
	assert.strictEqual(pipeline.field(owner.body, 'continue-on-error'), null);
	assert(pipeline.needsOf(owner.body).includes('test-linux'), 'original unit prerequisite');
	assert.strictEqual(pipeline.field(gate.body, 'if'), 'always()');
	for (const id of required.filter((id) => id !== 'linux-ok'))
		assert(pipeline.needsOf(gate.body).includes(id), 'original Linux verdict waits for ' + id);
	assert(owner.body.includes(BLOCK), 'owned block must remain inside the E2E job');
	const steps = pipeline.steps(owner.body);
	const uniqueIndex = (name) => {
		assert.strictEqual(
			steps.filter((step) => step.name === name).length,
			1,
			'unique anchor ' + name
		);
		return steps.findIndex((step) => step.name === name);
	};
	const source = uniqueIndex('Qualify actual X11 physical shortcut sources');
	const native = uniqueIndex('Qualify three actual XI2 property cookies');
	const upload = uniqueIndex('Retain actual XI2 property-cookie evidence');
	const cursor = uniqueIndex('Qualify actual cursor-display window switching');
	assert(
		source < native && native < upload && upload < cursor,
		'native receipt remains between original anchors'
	);
	for (const index of [source, cursor]) {
		assert.strictEqual(pipeline.stepField(steps[index].body, 'if'), '${{ !cancelled() }}');
		assert.strictEqual(pipeline.stepField(steps[index].body, 'continue-on-error'), null);
	}
	assert.strictEqual(pipeline.stepField(steps[source].body, 'timeout-minutes'), '3');
	assert.strictEqual(pipeline.stepField(steps[cursor].body, 'timeout-minutes'), '4');
	assert.strictEqual(
		sha(subject.c),
		PINS.c_source_sha256,
		'original peer/scalar/fetch/free predicates'
	);
	assert.strictEqual(
		sha(subject.header),
		PINS.header_sha256,
		'original three exact ABI declarations'
	);
	assert.strictEqual(
		sha(subject.family),
		PINS.family_sha256,
		'original full-family custody unchanged'
	);
	for (const literal of RUNNER_NEED)
		assert(subject.runner.includes(literal), 'receiving fence: ' + literal);
	for (const literal of DISPLAY_NEED)
		assert(subject.display.includes(literal), 'original server fence: ' + literal);
	assert(
		subject.suite.includes("args: ['tools/test/test-linux-xi2-cookie-ci-contract.cjs']"),
		'registered guard'
	);
}
const subject = {
	workflow: fs.readFileSync(path.join(ROOT, '.github/workflows/ci-linux.yml'), 'utf8'),
	c: fs.readFileSync(path.join(ROOT, HARDWARE + 'xi2_property_cookie.c'), 'utf8'),
	header: fs.readFileSync(path.join(ROOT, HARDWARE + 'xi2_property_types.h'), 'utf8'),
	family: fs.readFileSync(path.join(ROOT, HARDWARE + 'native_fixture_family.py'), 'utf8'),
	runner: fs.readFileSync(path.join(ROOT, HARDWARE + 'run_xi2_property_cookies.py'), 'utf8'),
	display: fs.readFileSync(path.join(ROOT, HARDWARE + 'xi2_property_display.py'), 'utf8'),
	suite: fs.readFileSync(path.join(ROOT, 'tools/test/run-js-suite.cjs'), 'utf8')
};
verify(subject);
const mutations = [
	[
		'mandatory step omission',
		'workflow',
		'      - name: Qualify three actual XI2 property cookies',
		'      - name: omitted'
	],
	[
		'cancellation fence weakened',
		'workflow',
		'        id: native_xi2_cookies\n        if: ${{ !cancelled() }}',
		'        id: native_xi2_cookies\n        if: always()'
	],
	[
		'new native deadline inflated',
		'workflow',
		'          exit "${xi2_pipeline_status[1]}"\n        timeout-minutes: 5',
		'          exit "${xi2_pipeline_status[1]}"\n        timeout-minutes: 6'
	],
	[
		'raw runner status omitted',
		'workflow',
		'xi2_pipeline_status=("${PIPESTATUS[@]}")',
		'xi2_pipeline_status=(0 0)'
	],
	[
		'artifact omitted',
		'workflow',
		'      - name: Retain actual XI2 property-cookie evidence',
		'      - name: omitted'
	],
	['cookie free omitted', 'c', 'XFreeEventData(d,&e.xcookie);freed++;', 'freed++;'],
	['kernel peer binding omitted', 'c', 'if(!bind_peer(d,(pid_t)expected_pid,&peer))', 'if(0)'],
	['full family census omitted', 'family', '        self.children()', '        pass'],
	['terminal status bypassed', 'runner', 'terminal["status"] == code == 0', 'True'],
	['terminal physical namespace omitted', 'runner', 'terminal["namespace_absent"] is True', 'True'],
	['zero scenario accepted', 'runner', '>= 1', '>= 0'],
	[
		'source Git join omitted',
		'runner',
		'["git", "show", source_sha + ":" + relative]',
		'["git", "rev-parse", "HEAD"]'
	],
	[
		'native budget inflated',
		'runner',
		'],\n            25,\n            environment,\n        )',
		'],\n            26,\n            environment,\n        )'
	],
	[
		'server terminal currentness omitted',
		'display',
		'assert leader.poll() is None, "owned Xvfb exited before native completion"',
		'pass'
	],
	[
		'server close acknowledgement omitted',
		'display',
		'termination_requested = True',
		'termination_requested = False'
	],
	[
		'guard enrollment omitted',
		'suite',
		"args: ['tools/test/test-linux-xi2-cookie-ci-contract.cjs']",
		'args: []'
	]
];
for (const [name, role, before, after] of mutations) {
	const altered = { ...subject };
	assert(altered[role].includes(before), 'control must change actual source: ' + name);
	altered[role] = altered[role].replace(before, after);
	assert.throws(() => verify(altered), undefined, name);
}
console.log(
	'PASS native XI2 CI source contract: positive baseline and 16 causal refusals; native UNRUN'
);

// Separately counted scope controls preserve the original positive+16 above.
const fixtureMarker = '      - name: XI2 guard owned harmless fixture';
assert(!subject.workflow.includes(fixtureMarker), 'own fixture must be absent initially');
const fixture = subject.workflow.replace(BLOCK, BLOCK + fixtureMarker + '\n        run: true\n\n');
verify({ ...subject, workflow: fixture });
verify({ ...subject, workflow: fixture.replace(fixtureMarker, fixtureMarker + ' renamed') });
const removed = subject.workflow.replace(BLOCK, '');
const fixtureJobs = pipeline.jobsOfText(removed, '.github/workflows/ci-linux.yml');
const unitBody = fixtureJobs.find((job) => job.id === 'test-linux').body;
const ownerBody = fixtureJobs.find((job) => job.id === 'e2e-linux').body;
const cursorBody = pipeline.step(ownerBody, 'Qualify actual cursor-display window switching');
const unitMarker = '    steps:\n';
assert.strictEqual(unitBody.split(unitMarker).length, 2, 'existing unit steps mapping');
assert.strictEqual(removed.split(unitBody).length, 2, 'unique original unit body');
assert.strictEqual(removed.split(cursorBody).length, 2, 'unique original cursor body');
const placements = [
	[
		'moved to unit job',
		removed.replace(unitBody, unitBody.replace(unitMarker, unitMarker + BLOCK))
	],
	[
		'moved before source anchor',
		removed.replace(
			'      - name: Qualify actual X11 physical shortcut sources',
			BLOCK + '      - name: Qualify actual X11 physical shortcut sources'
		)
	],
	['moved after cursor anchor', removed.replace(cursorBody, cursorBody + '\n\n' + BLOCK)]
];
for (const [name, workflow] of placements) {
	assert.notStrictEqual(workflow, removed, 'placement must change actual source: ' + name);
	assert.throws(() => verify({ ...subject, workflow }), undefined, name);
}
console.log(
	'PASS native XI2 bounded workflow scope: unrelated-edit1/placement-refusals3; native UNRUN'
);

// Additive LuaJIT enrollment leaves every original C3 assertion and mutation intact.
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');
const LUAJIT_BLOCK =
	'      # Real LuaJIT cdata is qualified separately from the unchanged C3 baseline.\n      # The child-local libXi projection grants no installed runtime or input epoch.\n      - name: Qualify actual LuaJIT XI2 ABI and property cookies\n        id: native_xi2_luajit\n        if: ${{ !cancelled() }}\n        shell: bash\n        run: |\n          set -euo pipefail\n          python3 -B static/ergopti_plus/linux/tests/hardware/test_xi2_luajit_diagnostic_portable.py\n          sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py" -y --no-install-recommends gcc luajit libx11-dev libxi-dev libx11-xcb1 libxkbcommon-dev libxkbcommon-x11-dev xkb-data xvfb\n          python3 static/ergopti_plus/linux/tests/hardware/run_xi2_luajit_diagnostic.py "$RUNNER_TEMP/linux-xi2-luajit" "$GITHUB_WORKSPACE" "$GITHUB_WORKSPACE/static/ergopti_plus/linux/adapters/xkb_source_probe.lua"\n        timeout-minutes: 7\n\n      - name: Retain actual LuaJIT XI2 diagnostic evidence\n        if: always()\n        uses: actions/upload-artifact@v4\n        with:\n          name: linux-xi2-luajit-${{ github.sha }}-${{ github.run_attempt }}\n          retention-days: 7\n          path: |\n            ${{ runner.temp }}/linux-xi2-luajit/receiving.json\n            ${{ runner.temp }}/linux-xi2-luajit/original-c3/receiving.json\n            ${{ runner.temp }}/linux-xi2-luajit/lua-native/display.json\n            ${{ runner.temp }}/linux-xi2-luajit/abi-compile.family.json\n            ${{ runner.temp }}/linux-xi2-luajit/lua-native.family.json\n            ${{ runner.temp }}/linux-xi2-luajit/lua-native/luajit.stdout\n            ${{ runner.temp }}/linux-xi2-luajit/lua-native/luajit.stderr\n          if-no-files-found: error\n\n';
function verifyLuaJitEnrollment(value) {
	assert.strictEqual(
		value.workflow.split(LUAJIT_BLOCK).length,
		2,
		'exact fatal LuaJIT native and always evidence steps'
	);
	const jobs = pipeline.jobsOfText(value.workflow, '.github/workflows/ci-linux.yml');
	const owner = jobs.find((job) => job.id === 'test-linux');
	assert(
		owner && owner.body.endsWith(LUAJIT_BLOCK.trimEnd()),
		'real independent unit-job native owner'
	);
	const steps = pipeline.steps(owner.body);
	const index = (name) => {
		assert.strictEqual(steps.filter((step) => step.name === name).length, 1, 'unique ' + name);
		return steps.findIndex((step) => step.name === name);
	};
	const oldEvidence = index('Retain the source-bound linux-unit-suite qualification');
	const native = index('Qualify actual LuaJIT XI2 ABI and property cookies');
	const evidence = index('Retain actual LuaJIT XI2 diagnostic evidence');
	assert(
		oldEvidence < native && native < evidence && evidence === steps.length - 1,
		'additive unit-retention/LuaJIT/retention END order'
	);
	assert.strictEqual(native, oldEvidence + 1, 'native observation follows all original unit steps');
	assert.strictEqual(evidence, native + 1, 'native failure evidence is immediately retained');
	assert.strictEqual(pipeline.field(owner.body, 'if'), null, 'unit owner admission is unchanged');
	assert.strictEqual(
		pipeline.field(owner.body, 'continue-on-error'),
		null,
		'unit failures remain fatal'
	);
	for (const at of [native, evidence])
		assert.strictEqual(pipeline.stepField(steps[at].body, 'continue-on-error'), null);
	assert.strictEqual(pipeline.stepField(steps[native].body, 'if'), '${{ !cancelled() }}');
	assert.strictEqual(pipeline.stepField(steps[evidence].body, 'if'), 'always()');
	for (const literal of [
		'assert original.main() == 0, "original three C cases remain mandatory"',
		'["git", "show", source_sha + ":" + relative]',
		'candidate.is_file() and original.digest(candidate) == CANDIDATE_SHA',
		'original.family_run(\n        directory,\n        "abi-compile",',
		'original.family_run(\n        directory,\n        "lua-native",',
		'static/ergopti_plus/_shared/lua/logger/init.lua',
		'result["display_pidfd_closed"] is True and result["rescue"] == 0'
	])
		assert(value.luaRunner.includes(literal), 'real diagnostic custody: ' + literal);
	assert(value.receiver.includes('local ffi = require("ffi")'), 'real FFI module');
	assert(value.receiver.includes('runtime.xi = xi_path'), 'explicit controlled child projection');
	assert(value.receiver.includes('comparisons == 29 and cases == 3'), 'nonzero ABI/cookie census');
	assert(
		value.receiver.includes('final_view.reason == "native-property-connection-retired"'),
		'candidate retirement readback'
	);
	assert(
		value.receiver.includes('cleanup_ok = W.ep_xvfb_peers(server_pid, uid) == 0 and cleanup_ok'),
		'native peer FD retirement'
	);
	assert(
		value.witness.includes('#include <X11/extensions/XInput2.h>'),
		'independent official header'
	);
	assert(value.witness.includes('TYPE(0, XGenericEventCookie)'), 'independent type layout witness');
}
const luaJitSubject = {
	workflow: subject.workflow,
	luaRunner: fs.readFileSync(path.join(ROOT, HARDWARE + 'run_xi2_luajit_diagnostic.py'), 'utf8'),
	receiver: fs.readFileSync(path.join(ROOT, HARDWARE + 'xi2_luajit_receiver.lua'), 'utf8'),
	witness: fs.readFileSync(path.join(ROOT, HARDWARE + 'xi2_luajit_abi.c'), 'utf8')
};
verifyLuaJitEnrollment(luaJitSubject);
const luaJitMutations = [
	[
		'native omission',
		'workflow',
		'      - name: Qualify actual LuaJIT XI2 ABI and property cookies',
		'      - name: omitted'
	],
	[
		'failure evidence omission',
		'workflow',
		'      - name: Retain actual LuaJIT XI2 diagnostic evidence',
		'      - name: omitted'
	],
	[
		'cancel fence weakened',
		'workflow',
		'        id: native_xi2_luajit\n        if: ${{ !cancelled() }}',
		'        id: native_xi2_luajit\n        if: success()'
	],
	[
		'masked native status',
		'workflow',
		'python3 static/ergopti_plus/linux/tests/hardware/run_xi2_luajit_diagnostic.py ',
		'true # '
	],
	[
		'unowned APT fallback',
		'workflow',
		'sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py" -y --no-install-recommends gcc luajit',
		'sudo apt-get install -y gcc luajit'
	],
	[
		'portable controls omitted',
		'workflow',
		'python3 -B static/ergopti_plus/linux/tests/hardware/test_xi2_luajit_diagnostic_portable.py',
		'true'
	],
	[
		'whole-directory upload',
		'workflow',
		'${{ runner.temp }}/linux-xi2-luajit/receiving.json',
		'${{ runner.temp }}/linux-xi2-luajit/'
	],
	[
		'failure receipt omitted',
		'workflow',
		'            ${{ runner.temp }}/linux-xi2-luajit/lua-native/display.json\n',
		''
	],
	[
		'missing evidence allowed',
		'workflow',
		'            ${{ runner.temp }}/linux-xi2-luajit/lua-native/luajit.stderr\n          if-no-files-found: error',
		'            ${{ runner.temp }}/linux-xi2-luajit/lua-native/luajit.stderr\n          if-no-files-found: ignore'
	],
	[
		'original C3 bypass',
		'luaRunner',
		'assert original.main() == 0, "original three C cases remain mandatory"',
		'assert True'
	],
	[
		'Git source custody bypass',
		'luaRunner',
		'["git", "show", source_sha + ":" + relative]',
		'["git", "rev-parse", "HEAD"]'
	],
	[
		'ABI compiler family custody bypass',
		'luaRunner',
		'original.family_run(\n        directory,\n        "abi-compile",',
		'unowned_run(\n        directory,\n        "abi-compile",'
	],
	[
		'LuaJIT family custody bypass',
		'luaRunner',
		'original.family_run(\n        directory,\n        "lua-native",',
		'unowned_run(\n        directory,\n        "lua-native",'
	],
	['modeled FFI substituted', 'receiver', 'local ffi = require("ffi")', 'local ffi = {}'],
	[
		'zero cookie census',
		'receiver',
		'comparisons == 29 and cases == 3',
		'comparisons == 29 and cases == 0'
	],
	[
		'pending candidate cleanup promoted',
		'receiver',
		'final_view.reason == "native-property-connection-retired"',
		'true'
	],
	[
		'peer FD readback omitted',
		'receiver',
		'cleanup_ok = W.ep_xvfb_peers(server_pid, uid) == 0 and cleanup_ok',
		'cleanup_ok = true'
	],
	[
		'header oracle substituted',
		'witness',
		'#include <X11/extensions/XInput2.h>',
		'#include "candidate.h"'
	]
];
for (const dependency of ['libx11-xcb1', 'libxkbcommon-dev', 'libxkbcommon-x11-dev', 'xkb-data']) {
	luaJitMutations.push([
		'missing native dependency ' + dependency,
		'workflow',
		' ' + dependency + ' ',
		' '
	]);
}
for (const [name, role, before, after] of luaJitMutations) {
	assert(luaJitSubject[role].includes(before), 'nonvacuous actual mutation ' + name);
	if (role === 'workflow')
		assert(LUAJIT_BLOCK.includes(before), 'mutation stays in its owned region');
	const changed =
		role === 'workflow'
			? luaJitSubject.workflow.replace(LUAJIT_BLOCK, LUAJIT_BLOCK.replace(before, after))
			: luaJitSubject[role].replace(before, after);
	const altered = { ...luaJitSubject, [role]: changed };
	assert.throws(() => verifyLuaJitEnrollment(altered), undefined, name);
}
const unitTail = '      - name: Retain the source-bound linux-unit-suite qualification';
const harmlessUnitStep = '      - name: LuaJIT guard harmless adjacent step\n        run: true\n\n';
assert.strictEqual(luaJitSubject.workflow.split(unitTail).length, 2, 'unique original unit tail');
verifyLuaJitEnrollment({
	...luaJitSubject,
	workflow: luaJitSubject.workflow.replace(unitTail, harmlessUnitStep + unitTail)
});
const omittedLuaJitBlock = luaJitSubject.workflow.replace(LUAJIT_BLOCK, '');
assert.notStrictEqual(
	omittedLuaJitBlock,
	luaJitSubject.workflow,
	'nonvacuous native block removal'
);
for (const [name, workflow] of [
	['native block omitted', omittedLuaJitBlock],
	[
		'behind skipped E2E prerequisite',
		omittedLuaJitBlock.replace(
			'      # A real X server and WM qualify logical RandR placement and input focus.',
			LUAJIT_BLOCK +
				'      # A real X server and WM qualify logical RandR placement and input focus.'
		)
	],
	[
		'before original unit qualification',
		omittedLuaJitBlock.replace(unitTail, LUAJIT_BLOCK + unitTail)
	],
	[
		'foreign step after terminal evidence',
		luaJitSubject.workflow.replace(LUAJIT_BLOCK, LUAJIT_BLOCK + harmlessUnitStep)
	]
]) {
	assert.notStrictEqual(workflow, luaJitSubject.workflow, 'nonvacuous placement mutation ' + name);
	assert.throws(() => verifyLuaJitEnrollment({ ...luaJitSubject, workflow }), undefined, name);
}
const portable = spawnSync(
	pythonExecutable(),
	['-B', path.join(ROOT, HARDWARE + 'test_xi2_luajit_diagnostic_portable.py')],
	{
		cwd: ROOT,
		encoding: 'utf8',
		timeout: 30000,
		maxBuffer: 65536,
		shell: false
	}
);
assert.ifError(portable.error);
assert.strictEqual(portable.signal, null, 'portable controls completed');
assert.strictEqual(portable.status, 0, 'actual portable controls: ' + portable.stderr);
assert.match(
	portable.stderr,
	/Ran 15 tests[\s\S]*\nOK(?:\r?\n|$)/,
	'all 15 actual portable cases executed'
);
console.log(
	'PASS additive LuaJIT XI2 enrollment: portable15/source refusals22/placement refusals4; ABI29/cookies3 native UNRUN'
);
