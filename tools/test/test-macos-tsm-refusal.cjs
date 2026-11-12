// tools/test/test-macos-tsm-refusal.cjs

/**
 * ==============================================================================
 * MODULE: macOS Text-Input Refusal Receipt
 * DESCRIPTION:
 * The native keyboard-source cohort failed on hosted Intel runners with a
 * selection deadline, an unresolved cleanup and "unavailable" for every later
 * case (runs 42014901978, 43013053161, 43172671159). Each refusal followed
 * TSMSendMessageToUIServer lines: TextInputMenuAgent, which serves
 * com.apple.tsm.uiserver, did not answer. Stopping that agent on a hosted
 * runner prints the same lines while the cohort still passes, so the state is
 * shared by the refusals but not proven to cause them.
 * tools/diagnostics/macos_tsm_refusal.py
 * names that state in a receipt and an error annotation. This test runs it on
 * the verbatim transcript lines of job 127206005395 and proves each state can
 * fail: the unanswered state needs the line before the refusal, a refusal
 * without it stays unclassified, and a passing cohort is not a refusal. The
 * refused case's TIS diagnostic record reaches the annotation as a selection
 * timeline, because the job log stays readable where the evidence upload is not.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const OWNER = path.join(ROOT, 'tools/diagnostics/macos_tsm_refusal.py');
const PYTHON = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const TEST = (name) => `Test Case '-[ErgoptiPlusTests.NumberRowSourceProbeTests ${name}]'`;
// The CI lines name the runner's checkout; the classifier reads only the message.
const SOURCE = path.join(
	ROOT,
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NumberRowSourceProbeTests.swift'
);
// Verbatim lines of job 127206005395 (run 42014901978, macos-15-intel).
const UNANSWERED =
	'2026-11-05 11:23:35.870 xctest[8730:26925] TSMSendMessageToUIServer: CFMessagePortSendRequest FAILED(-1) to send to port com.apple.tsm.uiserver';
const FRENCH = [
	TEST('testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor') + ' started.',
	UNANSWERED,
	TEST('testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor') +
		' passed (0.435 seconds).'
];
const REFUSED = [
	TEST('testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject') + ' started.',
	`${SOURCE}:62: error: -[ErgoptiPlusTests.NumberRowSourceProbeTests testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject] : failed - Native selection was not observed before the fixture deadline: deadline`,
	`${SOURCE}:113: error: -[ErgoptiPlusTests.NumberRowSourceProbeTests testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject] : failed - Temporary source cleanup remains unresolved: unavailable`,
	TEST('testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject') +
		' failed (11.591 seconds).',
	TEST('testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead') + ' started.',
	`${SOURCE}:82: error: -[ErgoptiPlusTests.NumberRowSourceProbeTests testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead] : failed: caught error: "unavailable"`
];
const AGENTS = [
	'phase=before now_epoch=1762341813 machine=x86_64',
	'',
	'## gui/501/com.apple.TextInputMenuAgent',
	'\tstate = running',
	'\tpid = 436',
	'\truns = 1',
	'launchctl_status=0',
	'phase=after now_epoch=1762341828 machine=x86_64',
	'',
	'## gui/501/com.apple.TextInputMenuAgent',
	'\tstate = running',
	'\tpid = 436',
	'\truns = 1',
	'launchctl_status=0',
	''
].join('\n');

const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-tsm-refusal-'));
let checks = 0;

// One bounded source state as KeyboardSourceTestDiagnostics encodes it.
const state = (id, enabled, selected) => ({
	id: { state: 'present', value: id },
	enabled: { state: 'present', value: enabled },
	selected: { state: 'present', value: selected },
	selectCapable: { state: 'present', value: true }
});

function classify(name, lines, records) {
	const log = path.join(folder, name + '.log');
	const agents = path.join(folder, name + '.agents.txt');
	const receipt = path.join(folder, name + '.json');
	fs.writeFileSync(log, lines.join('\r\n') + '\r\n');
	fs.writeFileSync(agents, AGENTS);
	const args = ['-I', OWNER, '--log', log, '--agents', agents, '--receipt', receipt];
	if (records) {
		const session = fs.mkdtempSync(path.join(folder, name + '.tis-'));
		fs.writeFileSync(path.join(session, 'start.json'), '{}');
		records.forEach((record, index) =>
			fs.writeFileSync(
				path.join(session, 'record-' + String(index + 1).padStart(6, '0') + '.dat'),
				'TIS_TEST_EVIDENCE ' + JSON.stringify(record) + '\n'
			)
		);
		args.push('--tis-session', session);
	}
	const result = spawnSync(PYTHON, args, { encoding: 'utf8' });
	assert.equal(result.status, 0, `${name}: the receipt owner failed: ${result.stderr}`);
	return { receipt: JSON.parse(fs.readFileSync(receipt, 'utf8')), stdout: result.stdout };
}

try {
	const original = classify('original', [...FRENCH, ...REFUSED]);
	assert.equal(original.receipt.state, 'tsm_uiserver_unanswered');
	assert.equal(original.receipt.unanswered_count, 1);
	assert.equal(original.receipt.first_unanswered.status, -1);
	assert.equal(
		original.receipt.first_unanswered.case,
		'testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor'
	);
	assert.equal(
		original.receipt.first_refusal.case,
		'testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject'
	);
	assert.equal(original.receipt.refusal_count, 3);
	assert.deepEqual(
		original.receipt.agent.map((phase) => [phase.phase, phase.pid, phase.runs]),
		[
			['before', '436', '1'],
			['after', '436', '1']
		]
	);
	assert.match(
		original.stdout,
		/^::error::Native keyboard-source refusal: tsm_uiserver_unanswered\. /m
	);
	assert.match(original.stdout, /names the runner state, not a proven cause\./);
	checks++;

	// The macOS 26 refusal of run 43108782369 carried no unanswered message.
	const unclassified = classify('unclassified', [FRENCH[0], FRENCH[2], ...REFUSED]);
	assert.equal(unclassified.receipt.state, 'fixture_refusal_unclassified');
	assert.match(
		unclassified.stdout,
		/^::error::Native keyboard-source refusal: fixture_refusal_unclassified\. /m
	);
	checks++;

	// A message after the first refusal did not cause it.
	const later = classify('later', [...REFUSED, UNANSWERED]);
	assert.equal(later.receipt.state, 'fixture_refusal_unclassified');
	checks++;

	// A passing cohort with an unanswered message is not a refusal.
	const passing = classify('passing', FRENCH);
	assert.equal(passing.receipt.state, 'no_fixture_refusal');
	assert.equal(passing.receipt.unanswered_count, 1);
	assert.doesNotMatch(passing.stdout, /::error::/);
	checks++;

	// The receipt is created once; an existing receipt is never overwritten.
	const again = spawnSync(
		PYTHON,
		[
			'-I',
			OWNER,
			'--log',
			path.join(folder, 'passing.log'),
			'--agents',
			path.join(folder, 'passing.agents.txt'),
			'--receipt',
			path.join(folder, 'passing.json')
		],
		{ encoding: 'utf8' }
	);
	assert.notEqual(again.status, 0, 'an existing receipt must be refused');
	checks++;

	// The macOS 26 full-suite refusal of job 131204789756 (shared selection
	// fixture, no unanswered server line) is named, not passed over.
	const fixture = '/Tests/ErgoptiPlusTests/KeyboardSourceSelectionFixture.swift';
	const mapping = (name) => `Test Case '-[ErgoptiPlusTests.KeyboardCharacterMappingTests ${name}]'`;
	const fullLines = [
		mapping('testFreshKeyboardEventsFollowLayoutAndShiftFlags') + ' started.',
		`${fixture}:63: error: -[ErgoptiPlusTests.KeyboardCharacterMappingTests testFreshKeyboardEventsFollowLayoutAndShiftFlags] : failed - Native selection was not observed before the fixture deadline: deadline`,
		`${fixture}:113: error: -[ErgoptiPlusTests.KeyboardCharacterMappingTests testFreshKeyboardEventsFollowLayoutAndShiftFlags] : failed - Temporary source cleanup remains unresolved: unavailable`
	];
	const full = classify('full-suite', fullLines);
	assert.equal(full.receipt.state, 'fixture_refusal_unclassified');
	assert.equal(full.receipt.first_refusal.case, 'testFreshKeyboardEventsFollowLayoutAndShiftFlags');
	assert.equal(full.receipt.tis_session, 'absent');
	assert.equal(full.receipt.selection_timeline, null);
	checks++;

	// The refused case's own diagnostic record reaches the receipt and the job
	// log: the job log stays readable where the uploaded evidence is not.
	const abc = state('com.apple.keylayout.ABC', true, true);
	const french = (enabled, selected) => state('com.apple.keylayout.French', enabled, selected);
	const timed = classify('timeline', fullLines, [
		{
			version: 1,
			test: { state: 'present', value: '-[ErgoptiPlusTests.KeyboardSourceProbeTests testOther]' },
			pid: 1,
			events: [{ phase: 'select.after', uptime: 1, status: -50, current: abc }],
			omittedEvents: 0
		},
		{
			version: 1,
			test: {
				state: 'present',
				value:
					'-[ErgoptiPlusTests.KeyboardCharacterMappingTests testFreshKeyboardEventsFollowLayoutAndShiftFlags]'
			},
			pid: 1,
			events: [
				{ phase: 'original.capture', uptime: 100, current: abc },
				{
					phase: 'enable.after',
					uptime: 100.004,
					status: 0,
					target: french(true, false),
					current: abc
				},
				{ phase: 'event.before', uptime: 100.005, target: french(true, false), current: abc },
				{
					phase: 'select.after',
					uptime: 105.012,
					status: 0,
					target: french(true, false),
					current: abc
				}
			],
			omittedEvents: 0
		}
	]);
	assert.equal(timed.receipt.tis_session, 'read');
	assert.deepEqual(
		timed.receipt.selection_timeline.map((event) => [event.phase, event.offset_ms, event.status]),
		[
			['original.capture', 0, null],
			['enable.after', 4, 0],
			['select.after', 5012, 0]
		]
	);
	assert.match(
		timed.stdout,
		/ Selection timeline: original\.capture \+0ms current=com\.apple\.keylayout\.ABC enabled=true selected=true \| enable\.after \+4ms status=0 target=com\.apple\.keylayout\.French enabled=true selected=false; current=com\.apple\.keylayout\.ABC/
	);
	checks++;

	// A session without the refused case's record says so instead of passing over it.
	const missing = classify('missing-record', fullLines, []);
	assert.equal(missing.receipt.selection_timeline, null);
	assert.match(
		missing.stdout,
		/The TIS session holds no receipt for testFreshKeyboardEventsFollowLayoutAndShiftFlags\./
	);
	checks++;

	// Both steps that select native input sources bracket their cohort with the
	// agent snapshot and write this receipt beside their transcript.
	const workflow = fs.readFileSync(path.join(ROOT, '.github/workflows/ci-macos.yml'), 'utf8');
	for (const [step, transcript, evidence] of [
		['Qualify actual selected number-row Carbon XCTest controls', '"$transcript"', '$evidence'],
		[
			'Run Swift launcher tests on macOS 26',
			'"$xctest_log"',
			'$RUNNER_TEMP/swift-launcher-evidence'
		]
	]) {
		const start = workflow.indexOf(`      - name: ${step}\n`);
		assert.ok(start >= 0, `missing step: ${step}`);
		const end = workflow.indexOf('\n      - name: ', start + 1);
		const body = workflow.slice(start, end < 0 ? undefined : end);
		const before = body.indexOf(
			`macos_text_input_agents.sh "${evidence}/text-input-agents.txt" before`
		);
		const suite = body.indexOf('swift test --package-path static/ergopti_plus/macos/launcher');
		const after = body.indexOf(
			`macos_text_input_agents.sh "${evidence}/text-input-agents.txt" after`
		);
		const receipt = body.indexOf(
			`macos_tsm_refusal.py --log ${transcript} --agents "${evidence}/text-input-agents.txt" --receipt "${evidence}/tsm-refusal.json" --tis-session "$ERGOPTI_TIS_EVIDENCE_DIR"`
		);
		assert.ok(
			before >= 0 && before < suite && suite < after && after < receipt,
			`${step} must bracket its cohort`
		);
		checks++;
	}
} finally {
	fs.rmSync(folder, { recursive: true, force: true });
}

console.log(`macOS text-input refusal receipt: ${checks} checks passed`);
