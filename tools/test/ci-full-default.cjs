'use strict';

/**
 * Read the mandatory full CI graph without rewriting any source predicate.
 * The temporary all-suite fast route is retired. Its reintroduction refuses;
 * the independent bounded qualification scopes remain owned by their policy.
 * Known scoped wrappers are admitted before inspecting their retained full commands.
 * All workflow predicates and unrelated scripts remain unchanged.
 */
const raw = require('./ci-pipeline.cjs');
const { projectScopedSteps } = require('./fixtures/ci-scoped-full-branches.cjs');
const ROOT = raw.ROOT;
const ENTRY_REL = raw.ENTRY_REL;
const JOBS = [
	['.github/workflows/ci.yml', 'validate', null],
	['.github/workflows/ci.yml', 'core', null],
	['.github/workflows/ci.yml', 'macos', "needs.validate.outputs.lane_macos == 'true'"],
	['.github/workflows/ci.yml', 'windows', "needs.validate.outputs.lane_windows == 'true'"],
	['.github/workflows/ci.yml', 'linux', "needs.validate.outputs.lane_linux == 'true'"],
	[
		'.github/workflows/ci.yml',
		'manual-verdict',
		"always() && github.event_name == 'workflow_dispatch'"
	],
	[
		'.github/workflows/ci.yml',
		'release',
		"github.event_name == 'push' && needs.validate.outputs.release == 'true'"
	],
	[
		'.github/workflows/ci-macos.yml',
		'item36-native',
		"${{ github.event_name == 'workflow_dispatch' && !inputs.release }}"
	],
	['.github/workflows/ci-macos.yml', 'managed-ollama-native', null],
	['.github/workflows/ci-macos.yml', 'test-hs', null],
	['.github/workflows/ci-macos.yml', 'e2e-hs', null],
	['.github/workflows/ci-macos.yml', 'tooltip-canvas', null],
	['.github/workflows/ci-macos.yml', 'package-macos', null],
	['.github/workflows/ci-macos.yml', 'launch', null],
	['.github/workflows/ci-macos.yml', 'cold-bootstrap-native', null],
	['.github/workflows/ci-macos.yml', 'macos-ok', 'always()'],
	['.github/workflows/ci-windows.yml', 'test-ahk', null],
	['.github/workflows/ci-windows.yml', 'e2e-ahk', null],
	['.github/workflows/ci-windows.yml', 'package-windows', null],
	['.github/workflows/ci-windows.yml', 'launch-windows', null],
	['.github/workflows/ci-windows.yml', 'windows-ok', 'always()'],
	['.github/workflows/ci-linux.yml', 'test-linux', null],
	['.github/workflows/ci-linux.yml', 'e2e-linux', null],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		"${{ !cancelled() && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')) }}"
	],
	['.github/workflows/ci-linux.yml', 'install-linux', null],
	['.github/workflows/ci-linux.yml', 'linux-ok', 'always()']
];
const FULL_STEPS = [
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Prepare genuine pinned Go toolchain',
		'${{ !cancelled() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Acquire and verify genuine pinned upstream inputs',
		'${{ !cancelled() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Build and admit the actual native source asset',
		'${{ !cancelled() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Receive selected-release shell corpus and native guardian cancellation',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Retain selected-release native ownership receiving',
		'always()'
	],
	[
		'.github/workflows/ci-macos.yml',
		'item36-native',
		'Observe the actual no-prompt SDK permission API independently',
		'${{ !cancelled() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Prepare locked native HTTP receiving clients',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Receive actual private-session and numeric TLS peer controls',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Retain actual private-session and numeric TLS peer diagnostics',
		'always()'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Qualify actual SDK accepted-owner and deadline XCTest controls',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Qualify actual native PAC source ownership XCTest controls',
		'${{ !cancelled() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Retain independent native SDK XCTest diagnostics',
		'always()'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Qualify actual native PAC and WPAD XCTest controls',
		'${{ !cancelled() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Retain independent native PAC XCTest diagnostics',
		'always()'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Receive actual independent managed HTTP native clients',
		'${{ !cancelled() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Qualify actual explicit curl stream ownership',
		'${{ !cancelled() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'managed-ollama-native',
		'Receive actual native model create, pull, inference and retirement',
		"${{ !cancelled() && steps.ollama-native-build.outcome == 'success' }}"
	],
	['.github/workflows/ci-macos.yml', 'package-macos', 'Run reporter lifecycle self-tests', null],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Run owned program XCTest notice constructed-policy controls',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Admit native nonreaping Python prerequisites',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Prepare locked managed HTTP native clients',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Prepare scoped native qualification profile',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Run portable Brew ownership and refusal controls',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Verify scoped Swift test target exclusion',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Receive actual managed HTTP native clients',
		null
	],
	['.github/workflows/ci-macos.yml', 'package-macos', 'Run Swift launcher tests', null],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain scoped native Brew qualification receipt',
		'${{ always() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Upload Swift launcher failure transcript',
		"${{ failure() && steps.swift-launcher-tests.outcome == 'failure' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain archive diagnostic session',
		"${{ always() && steps.swift-launcher-tests.outputs.archive_session_dir != '' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain closed TIS diagnostic session',
		"${{ always() && steps.swift-launcher-tests.outcome != 'skipped' && steps.swift-launcher-tests.outputs.tis_session_dir != '' }}"
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Run signed Hammerspoon program provider inventory',
		'${{ always() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain native Hammerspoon provider inventory',
		'${{ always() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Observe native notification constructors',
		'${{ always() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain native notification constructor observations',
		'${{ always() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Observe native global application switcher',
		'${{ always() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain native global application switcher observations',
		'${{ always() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Observe native Apple Shortcuts discovery',
		'${{ always() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain native Apple Shortcuts observation',
		'${{ always() }}'
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Remove the launcher log the Swift tests wrote',
		null
	],
	['.github/workflows/ci-macos.yml', 'package-macos', 'Self-test the launch verdict', null],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Receive actual cold native MLX bootstrap',
		null
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Smoke test built ErgoptiPlus.app (crash-on-launch guard)',
		'inputs.release'
	],
	[
		'.github/workflows/ci-macos.yml',
		'package-macos',
		'Retain packaged application startup evidence',
		'always() && inputs.release'
	],
	['.github/workflows/ci-macos.yml', 'macos-ok', 'Download launch evidence', null],
	['.github/workflows/ci-macos.yml', 'macos-ok', 'Download native cold bootstrap evidence', null],
	[
		'.github/workflows/ci-macos.yml',
		'macos-ok',
		'Verify mandatory jobs and launch scenarios',
		null
	],
	['.github/workflows/ci-windows.yml', 'windows-ok', 'Download launch evidence', null],
	[
		'.github/workflows/ci-windows.yml',
		'windows-ok',
		'Install locked evidence validation dependencies',
		null
	],
	[
		'.github/workflows/ci-windows.yml',
		'windows-ok',
		'Verify mandatory jobs and launch scenarios',
		null
	],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		'Install the Flatpak the way a user would',
		null
	],
	['.github/workflows/ci-linux.yml', 'package-linux', 'Launch the Flatpak', null],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		'The sandboxed shared data tree resolves and opens',
		null
	],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		'Unpack and install the tarball the way a user would',
		null
	],
	['.github/workflows/ci-linux.yml', 'package-linux', 'Launch what the tarball installed', null],
	[
		'.github/workflows/ci-linux.yml',
		'package-linux',
		'The installed shared data tree resolves and opens',
		null
	],
	['.github/workflows/ci-linux.yml', 'package-linux', 'Record mandatory package evidence', null],
	['.github/workflows/ci-linux.yml', 'package-linux', 'Upload mandatory package evidence', null],
	['.github/workflows/ci-linux.yml', 'linux-ok', 'Download assertion evidence', null],
	[
		'.github/workflows/ci-linux.yml',
		'linux-ok',
		'Assert all mandatory subjects ran and passed',
		null
	]
];

function refuse(message) {
	throw new Error(`[ci-full-default] ${message}`);
}
function requireEqual(actual, expected, label) {
	if (actual !== expected) refuse(label);
}
function validateRaw(files) {
	if (!Array.isArray(files)) refuse('workflow files must be an array');
	const entries = new Map();
	for (const entry of files) {
		if (
			!entry ||
			typeof entry.rel !== 'string' ||
			typeof entry.text !== 'string' ||
			entries.has(entry.rel)
		)
			refuse('invalid or duplicate workflow identity');
		entries.set(entry.rel, entry.text);
		const executable = entry.text
			.split('\n')
			.filter((line) => !line.trimStart().startsWith('#'))
			.join('\n');
		if (/fast_prerelease|ERGOPTI_FAST_PRERELEASE|--fast-action/.test(executable))
			refuse(`${entry.rel} retired fast route`);
	}
	const expectedFiles = [...new Set(JOBS.map((row) => row[0]))];
	if (entries.size !== expectedFiles.length || expectedFiles.some((rel) => !entries.has(rel)))
		refuse('exact four workflow call graph');
	const jobs = files.flatMap((entry) => raw.jobsOfText(entry.text, entry.rel));
	if (jobs.length !== JOBS.length) refuse('complete mandatory job inventory');
	for (const [rel, id, condition] of JOBS) {
		const found = jobs.filter((job) => job.file === rel && job.id === id);
		if (found.length !== 1) refuse(`ambiguous/missing job ${rel}/${id}`);
		requireEqual(raw.field(found[0].body, 'if'), condition, `${id} full job condition`);
		requireEqual(
			raw.field(found[0].body, 'continue-on-error'),
			null,
			`${id} job failure must remain fatal`
		);
	}
	for (const [rel, id, name, condition] of FULL_STEPS) {
		const job = jobs.find((entry) => entry.file === rel && entry.id === id);
		const body = raw.step(job.body, name);
		requireEqual(raw.stepField(body, 'if'), condition, `${id}/${name} full step condition`);
		if (name === 'Build and admit the actual native source asset') {
			requireEqual(
				raw.stepField(body, 'id'),
				'ollama-native-build',
				'native producer exact build id'
			);
			const members = raw.steps(job.body);
			requireEqual(
				members.filter((member) => raw.stepField(member.body, 'id') === 'ollama-native-build')
					.length,
				1,
				'native producer unique build id'
			);
			requireEqual(
				members.findIndex((member) => member.name === name) <
					members.findIndex(
						(member) =>
							member.name === 'Receive actual native model create, pull, inference and retirement'
					),
				true,
				'native producer precedes model receiving'
			);
		}
		if (name === 'Receive selected-release shell corpus and native guardian cancellation') {
			requireEqual(raw.stepField(body, 'shell'), 'bash', 'selected-release receiver exact shell');
			requireEqual(
				raw.runOf(body)?.join('\n'),
				[
					'set -euo pipefail',
					'node tools/diagnostics/macos_release_stage_native_receiving.cjs \\',
					'  --output "$RUNNER_TEMP/native-selected-release-$ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE"'
				].join('\n'),
				'selected-release receiver exact command'
			);
		}
		requireEqual(
			raw.stepField(body, 'continue-on-error'),
			null,
			`${id}/${name} failure must remain fatal`
		);
	}
	for (const lane of ['macos', 'windows', 'linux']) {
		const caller = jobs.find((job) => job.file === ENTRY_REL && job.id === lane);
		requireEqual(
			raw.field(caller.body, 'uses'),
			`./.github/workflows/ci-${lane}.yml`,
			`${lane} actual caller`
		);
		for (const key of ['release', 'prerelease', 'channel', 'tag', 'version']) {
			const value =
				key === 'release'
					? "needs.validate.outputs.release == 'true'"
					: `needs.validate.outputs.${key}`;
			const line = `      ${key}: \${{ ${value} }}\n`;
			if (caller.body.split(line).length !== 2) refuse(`${lane} exact ${key} source binding`);
		}
	}
}
function fromFiles(files) {
	validateRaw(files);
	const projected = files.map((entry) => ({
		...entry,
		text: projectScopedSteps(entry.text, entry.rel)
	}));
	const file = (rel) => {
		const found = projected.find((f) => f.rel === rel);
		if (!found) refuse(`unknown file ${rel}`);
		return found.text;
	};
	const jobs = (rel) => raw.jobsOfText(file(rel), rel);
	const locate = (id) => {
		const found = projected.flatMap((f) => jobs(f.rel)).filter((j) => j.id === id);
		if (found.length !== 1) refuse(`ambiguous/missing raw job ${id}`);
		return found[0];
	};
	const text = () => projected.map((f) => f.text).join('\n');
	const findStep = (name) => {
		const found = projected.flatMap((f) =>
			jobs(f.rel).flatMap((j) =>
				raw
					.steps(j.body)
					.filter((s) => s.name === name)
					.map((s) => ({ file: f.rel, job: j.id, body: s.body }))
			)
		);
		if (found.length !== 1) refuse(`ambiguous/missing projected step ${name}`);
		return found[0];
	};
	return {
		...raw,
		files: () => projected.map((f) => ({ ...f })),
		rawFiles: () => files.map((f) => ({ ...f })),
		file,
		text,
		jobs,
		locate,
		job: (id) => locate(id).body,
		findStep,
		textWithout: (id) => {
			const j = locate(id);
			return projected
				.map((f) => (f.rel === j.file ? f.text.replace(j.body, '') : f.text))
				.join('\n');
		},
		calls: (rel = ENTRY_REL) =>
			jobs(rel)
				.map((j) => ({ id: j.id, uses: raw.field(j.body, 'uses') }))
				.filter((j) => j.uses !== null)
	};
}
function open(root) {
	return fromFiles(raw.open(root).files());
}
module.exports = { ...open(ROOT), open, fromFiles, validateRaw };
