'use strict';

/**
 * Explicit source view for mandatory/default CI contract tests only.
 * The raw loader and runtime workflows remain unchanged. This view grants no
 * execution credit: it substitutes the independently pinned full-route predicates
 * only after checking the precise temporary diagnostic route's raw wiring.
 * Unknown identities, conditions, duplicate keys and changed topology refuse.
 */
const raw = require('./ci-pipeline.cjs');
const ROOT = raw.ROOT;
const ENTRY_REL = raw.ENTRY_REL;
const MAC = '.github/workflows/ci-macos.yml';
const WIN = '.github/workflows/ci-windows.yml';
const LIN = '.github/workflows/ci-linux.yml';
const CONDITIONS = [
	"needs.validate.outputs.fast_prerelease != 'true'",
	null,
	"${{ !cancelled() && github.event_name == 'push' && needs.validate.result == 'success' && needs.validate.outputs.release == 'true' && needs.macos.result == 'success' && needs.windows.result == 'success' && needs.linux.result == 'success' && ((needs.validate.outputs.fast_prerelease == 'true' && needs.core.result == 'skipped') || (needs.validate.outputs.fast_prerelease != 'true' && needs.core.result == 'success')) }}",
	"github.event_name == 'push' && needs.validate.outputs.release == 'true'",
	'${{ !inputs.fast_prerelease }}',
	'${{ !inputs.fast_prerelease && (always()) }}',
	'always()',
	'${{ !inputs.fast_prerelease && (!cancelled()) }}',
	'${{ !cancelled() }}',
	"${{ !cancelled() && needs.managed-ollama-native.result == 'success' && ((inputs.fast_prerelease && needs.e2e-hs.result == 'skipped') || (!inputs.fast_prerelease && needs.e2e-hs.result == 'success')) }}",
	'${{ always() }}',
	"${{ !inputs.fast_prerelease && (failure() && steps.swift-launcher-tests.outcome == 'failure') }}",
	"${{ failure() && steps.swift-launcher-tests.outcome == 'failure' }}",
	"${{ !inputs.fast_prerelease && (always() && steps.swift-launcher-tests.outputs.archive_session_dir != '') }}",
	"${{ always() && steps.swift-launcher-tests.outputs.archive_session_dir != '' }}",
	"${{ !inputs.fast_prerelease && (always() && steps.swift-launcher-tests.outcome != 'skipped' && steps.swift-launcher-tests.outputs.tis_session_dir != '') }}",
	"${{ always() && steps.swift-launcher-tests.outcome != 'skipped' && steps.swift-launcher-tests.outputs.tis_session_dir != '' }}",
	'${{ !inputs.fast_prerelease && (inputs.release) }}',
	'inputs.release',
	'${{ !inputs.fast_prerelease && (always() && inputs.release) }}',
	'always() && inputs.release',
	'${{ inputs.fast_prerelease }}',
	"${{ !cancelled() && ((inputs.fast_prerelease && needs.e2e-ahk.result == 'skipped') || (!inputs.fast_prerelease && needs.e2e-ahk.result == 'success')) }}",
	"${{ !cancelled() && ((inputs.fast_prerelease && needs.e2e-linux.result == 'skipped') || (!inputs.fast_prerelease && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')))) }}",
	"${{ !cancelled() && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')) }}"
];
// [file, job, exact step name (null means job), raw condition, full condition].
const WRAPPERS = [
	[ENTRY_REL, 'core', null, 0, 1],
	[ENTRY_REL, 'release', null, 2, 3],
	[MAC, 'managed-ollama-native', 'Prepare locked native HTTP receiving clients', 4, 1],
	[
		MAC,
		'managed-ollama-native',
		'Receive actual private-session and numeric TLS peer controls',
		4,
		1
	],
	[
		MAC,
		'managed-ollama-native',
		'Retain actual private-session and numeric TLS peer diagnostics',
		5,
		6
	],
	[
		MAC,
		'managed-ollama-native',
		'Qualify actual SDK accepted-owner and deadline XCTest controls',
		4,
		1
	],
	[MAC, 'managed-ollama-native', 'Retain independent native SDK XCTest diagnostics', 5, 6],
	[
		MAC,
		'managed-ollama-native',
		'Qualify actual native PAC source ownership XCTest controls',
		7,
		8
	],
	[MAC, 'managed-ollama-native', 'Qualify actual native PAC and WPAD XCTest controls', 7, 8],
	[MAC, 'managed-ollama-native', 'Retain independent native PAC XCTest diagnostics', 5, 6],
	[MAC, 'managed-ollama-native', 'Receive actual independent managed HTTP native clients', 7, 8],
	[MAC, 'managed-ollama-native', 'Qualify actual explicit curl stream ownership', 7, 8],
	[
		MAC,
		'managed-ollama-native',
		'Receive actual native model create, pull, inference and retirement',
		4,
		1
	],
	[MAC, 'test-hs', null, 4, 1],
	[MAC, 'e2e-hs', null, 4, 1],
	[MAC, 'tooltip-canvas', null, 4, 1],
	[MAC, 'package-macos', null, 9, 1],
	[MAC, 'package-macos', 'Run reporter lifecycle self-tests', 4, 1],
	[MAC, 'package-macos', 'Run owned program XCTest notice constructed-policy controls', 4, 1],
	[MAC, 'package-macos', 'Admit native nonreaping Python prerequisites', 4, 1],
	[MAC, 'package-macos', 'Prepare locked managed HTTP native clients', 4, 1],
	[MAC, 'package-macos', 'Prepare scoped native qualification profile', 4, 1],
	[MAC, 'package-macos', 'Run portable Brew ownership and refusal controls', 4, 1],
	[MAC, 'package-macos', 'Verify scoped Swift test target exclusion', 4, 1],
	[MAC, 'package-macos', 'Receive actual managed HTTP native clients', 4, 1],
	[MAC, 'package-macos', 'Run Swift launcher tests', 4, 1],
	[MAC, 'package-macos', 'Retain scoped native Brew qualification receipt', 5, 10],
	[MAC, 'package-macos', 'Upload Swift launcher failure transcript', 11, 12],
	[MAC, 'package-macos', 'Retain archive diagnostic session', 13, 14],
	[MAC, 'package-macos', 'Retain closed TIS diagnostic session', 15, 16],
	[MAC, 'package-macos', 'Run signed Hammerspoon program provider inventory', 5, 10],
	[MAC, 'package-macos', 'Retain native Hammerspoon provider inventory', 5, 10],
	[MAC, 'package-macos', 'Observe native notification constructors', 5, 10],
	[MAC, 'package-macos', 'Retain native notification constructor observations', 5, 10],
	[MAC, 'package-macos', 'Observe native global application switcher', 5, 10],
	[MAC, 'package-macos', 'Retain native global application switcher observations', 5, 10],
	[MAC, 'package-macos', 'Observe native Apple Shortcuts discovery', 5, 10],
	[MAC, 'package-macos', 'Retain native Apple Shortcuts observation', 5, 10],
	[MAC, 'package-macos', 'Remove the launcher log the Swift tests wrote', 4, 1],
	[MAC, 'package-macos', 'Self-test the launch verdict', 4, 1],
	[MAC, 'package-macos', 'Receive actual cold native MLX bootstrap', 4, 1],
	[MAC, 'package-macos', 'Smoke test built ErgoptiPlus.app (crash-on-launch guard)', 17, 18],
	[MAC, 'package-macos', 'Retain packaged application startup evidence', 19, 20],
	[MAC, 'launch', null, 4, 1],
	[MAC, 'cold-bootstrap-native', null, 4, 1],
	[MAC, 'macos-ok', 'Download launch evidence', 4, 1],
	[MAC, 'macos-ok', 'Download native cold bootstrap evidence', 4, 1],
	[MAC, 'macos-ok', 'Verify mandatory jobs and launch scenarios', 4, 1],
	[MAC, 'macos-ok', 'Record UNQUALIFIED temporary test deferral', 21, 1],
	[MAC, 'macos-ok', 'Retain the explicit unqualified test receipt', 21, 1],
	[WIN, 'test-ahk', null, 4, 1],
	[WIN, 'e2e-ahk', null, 4, 1],
	[WIN, 'package-windows', null, 22, 1],
	[WIN, 'launch-windows', null, 4, 1],
	[WIN, 'windows-ok', 'Download launch evidence', 4, 1],
	[WIN, 'windows-ok', 'Install locked evidence validation dependencies', 4, 1],
	[WIN, 'windows-ok', 'Verify mandatory jobs and launch scenarios', 4, 1],
	[WIN, 'windows-ok', 'Record UNQUALIFIED temporary test deferral', 21, 1],
	[WIN, 'windows-ok', 'Retain the explicit unqualified test receipt', 21, 1],
	[LIN, 'test-linux', null, 4, 1],
	[LIN, 'e2e-linux', null, 4, 1],
	[LIN, 'package-linux', null, 23, 24],
	[LIN, 'package-linux', 'Install the Flatpak the way a user would', 4, 1],
	[LIN, 'package-linux', 'Launch the Flatpak', 4, 1],
	[LIN, 'package-linux', 'The sandboxed shared data tree resolves and opens', 4, 1],
	[LIN, 'package-linux', 'Unpack and install the tarball the way a user would', 4, 1],
	[LIN, 'package-linux', 'Launch what the tarball installed', 4, 1],
	[LIN, 'package-linux', 'The installed shared data tree resolves and opens', 4, 1],
	[LIN, 'package-linux', 'Record mandatory package evidence', 4, 1],
	[LIN, 'package-linux', 'Upload mandatory package evidence', 4, 1],
	[LIN, 'install-linux', null, 4, 1],
	[LIN, 'linux-ok', 'Download assertion evidence', 4, 1],
	[LIN, 'linux-ok', 'Assert all mandatory subjects ran and passed', 4, 1],
	[LIN, 'linux-ok', 'Record UNQUALIFIED temporary test deferral', 21, 1],
	[LIN, 'linux-ok', 'Retain the explicit unqualified test receipt', 21, 1]
];

function refuse(message) {
	throw new Error(`[ci-full-default] ${message}`);
}
function requireEqual(actual, expected, label) {
	if (actual !== expected) refuse(label);
}
function oneJob(files, id) {
	const found = files.flatMap((f) => raw.jobsOfText(f.text, f.rel)).filter((j) => j.id === id);
	if (found.length !== 1) refuse(`ambiguous/missing job ${id}`);
	return found[0];
}
function exactStep(job, name) {
	return raw.step(job.body, name);
}
function admitStep(files, jobId, name) {
	const job = oneJob(files, jobId);
	const body = exactStep(job, name);
	requireEqual(raw.stepField(body, 'if'), null, `${jobId} admission must be unconditional`);
	requireEqual(
		raw.stepField(body, 'continue-on-error'),
		null,
		`${jobId} admission may not ignore failure`
	);
	requireEqual(
		raw.stepField(body, 'run'),
		'node tools/ci/dev-release-qualification.cjs --fast-action admit',
		`${jobId} actual admission command`
	);
	const expectedEnvironment =
		jobId === 'release'
			? ['RELEASE', 'PRERELEASE', 'CHANNEL', 'TAG', 'VERSION']
					.map(
						(key) =>
							`ERGOPTI_DEV_RELEASE_${key}: \${{ needs.validate.outputs.${key.toLowerCase()} }}`
					)
					.concat('ERGOPTI_FAST_PRERELEASE: ${{ needs.validate.outputs.fast_prerelease }}')
					.join(' ')
			: null;
	requireEqual(
		raw.stepField(body, 'env'),
		expectedEnvironment,
		`${jobId} closed admission context`
	);
	return body;
}
function validateRaw(files) {
	const entries = new Map(files.map((f) => [f.rel, f.text]));
	if (entries.size !== 4 || ![ENTRY_REL, MAC, WIN, LIN].every((f) => entries.has(f)))
		refuse('exact four workflow call graph');
	const root = entries.get(ENTRY_REL);
	const validate = oneJob(files, 'validate');
	requireEqual(raw.field(validate.body, 'if'), null, 'unconditional root validation');
	requireEqual(raw.field(validate.body, 'continue-on-error'), null, 'root validation failure');
	if (
		validate.body.split('      fast_prerelease: ${{ steps.fast.outputs.fast_prerelease }}\n')
			.length !== 2
	)
		refuse('root fast output');
	const select = exactStep(validate, 'Resolve authorized temporary fast prerelease');
	requireEqual(raw.stepField(select, 'id'), 'fast', 'selector output identity');
	requireEqual(
		raw.stepField(select, 'run'),
		'node tools/ci/dev-release-qualification.cjs --fast-action select',
		'actual central selector'
	);
	requireEqual(raw.stepField(select, 'if'), null, 'unconditional selector');
	requireEqual(raw.stepField(select, 'continue-on-error'), null, 'selector failure');
	requireEqual(
		raw.stepField(select, 'env'),
		['RELEASE', 'PRERELEASE', 'CHANNEL', 'TAG', 'VERSION']
			.map((key) => `ERGOPTI_DEV_RELEASE_${key}: \${{ steps.meta.outputs.${key.toLowerCase()} }}`)
			.join(' '),
		'closed selector actual context'
	);
	for (const key of ['RELEASE', 'PRERELEASE', 'CHANNEL', 'TAG', 'VERSION']) {
		if (
			!select.includes(
				`          ERGOPTI_DEV_RELEASE_${key}: \${{ steps.meta.outputs.${key.toLowerCase()} }}\n`
			)
		)
			refuse(`selector actual ${key}`);
	}
	if (/^      fast_prerelease:/m.test(root.slice(0, root.indexOf('jobs:'))))
		refuse('manual/public fast input');
	for (const [lane, rel] of [
		['macos', MAC],
		['windows', WIN],
		['linux', LIN]
	]) {
		const source = entries.get(rel);
		const input =
			'      fast_prerelease:\n        description: Temporary unqualified dev157 test deferral; defaults remain full\n        required: false\n        default: false\n        type: boolean\n';
		if (
			source.split(input).length !== 2 ||
			[...source.matchAll(/^      fast_prerelease:/gm)].length !== 1
		)
			refuse(`${lane} typed default-false input`);
		const environment =
			'env:\n' +
			['RELEASE', 'PRERELEASE', 'CHANNEL', 'TAG', 'VERSION']
				.map((key) => `  ERGOPTI_DEV_RELEASE_${key}: \${{ inputs.${key.toLowerCase()} }}\n`)
				.join('') +
			'  ERGOPTI_FAST_PRERELEASE: ${{ inputs.fast_prerelease }}\n';
		if (
			source.match(/^env:\n[\s\S]*?(?=^\S)/m)?.[0].trimEnd() !== environment.trimEnd() ||
			[...source.matchAll(/^env:/gm)].length !== 1
		)
			refuse(`${lane} closed actual context environment`);
		const caller = oneJob(files, lane);
		requireEqual(raw.field(caller.body, 'uses'), `./${rel}`, `${lane} actual caller`);
		if (
			!caller.body.includes(
				"      fast_prerelease: ${{ needs.validate.outputs.fast_prerelease == 'true' }}\n"
			)
		)
			refuse(`${lane} central output binding`);
		for (const key of ['release', 'prerelease', 'channel', 'tag', 'version']) {
			const expression =
				key === 'release'
					? "needs.validate.outputs.release == 'true'"
					: `needs.validate.outputs.${key}`;
			if (!caller.body.includes(`      ${key}: \${{ ${expression} }}\n`))
				refuse(`${lane} caller ${key}`);
			if (!source.includes(`  ERGOPTI_DEV_RELEASE_${key.toUpperCase()}: \${{ inputs.${key} }}\n`))
				refuse(`${lane} admission context ${key}`);
		}
		const verdict = oneJob(files, `${lane}-ok`);
		const receipt = exactStep(verdict, 'Record UNQUALIFIED temporary test deferral');
		requireEqual(
			raw.stepField(receipt, 'if'),
			'${{ inputs.fast_prerelease }}',
			`${lane} fast receipt condition`
		);
		requireEqual(
			raw.stepField(receipt, 'run'),
			`node tools/ci/dev-release-qualification.cjs --fast-action receipt --lane ${lane}`,
			`${lane} real unqualified receipt`
		);
		requireEqual(raw.stepField(receipt, 'continue-on-error'), null, `${lane} receipt failure`);
		if (!receipt.includes('          NEEDS: ${{ toJSON(needs) }}\n'))
			refuse(`${lane} actual needs receipt`);
		const retain = exactStep(verdict, 'Retain the explicit unqualified test receipt');
		requireEqual(
			raw.stepField(retain, 'continue-on-error'),
			null,
			`${lane} retained receipt failure must remain fatal`
		);
		requireEqual(
			raw.stepField(retain, 'if'),
			'${{ inputs.fast_prerelease }}',
			`${lane} retained fast condition`
		);
		requireEqual(
			raw.stepField(retain, 'uses'),
			'actions/upload-artifact@v4',
			`${lane} retain receipt`
		);
		if (
			!retain.includes(`          name: fast-prerelease-unqualified-${lane}\n`) ||
			!retain.includes(`          path: fast-prerelease-${lane}.json\n`) ||
			!retain.includes('          if-no-files-found: error')
		)
			refuse(`${lane} fixed retained receipt`);
		admitStep(files, `package-${lane}`, 'Recheck temporary fast prerelease authorization');
	}
	for (const [jobId, first] of [
		['package-macos', 'Prepare Node for native policy fixtures and XCTest evidence'],
		['package-windows', 'Build and test native navigation event owner'],
		['package-linux', 'Install LuaJIT'],
		['release', 'Download all build artifacts']
	]) {
		const j = oneJob(files, jobId);
		const admission = exactStep(
			j,
			jobId === 'release'
				? 'Recheck temporary publication authorization'
				: 'Recheck temporary fast prerelease authorization'
		);
		if (j.body.indexOf(admission) >= j.body.indexOf(exactStep(j, first)))
			refuse(`${jobId} admission before product/publication work`);
	}
	admitStep(files, 'managed-ollama-native', 'Recheck temporary fast prerelease authorization');
	admitStep(files, 'release', 'Recheck temporary publication authorization');
	const publication = oneJob(files, 'release').body;
	for (const key of ['RELEASE', 'PRERELEASE', 'CHANNEL', 'TAG', 'VERSION']) {
		if (
			!publication.includes(
				`      ERGOPTI_DEV_RELEASE_${key}: \${{ needs.validate.outputs.${key.toLowerCase()} }}\n`
			)
		)
			refuse(`publication ${key}`);
	}
	if (
		!publication.includes(
			'      ERGOPTI_FAST_PRERELEASE: ${{ needs.validate.outputs.fast_prerelease }}\n'
		)
	)
		refuse('publication fast binding');
	const seen = new Set();
	for (const f of files)
		for (const j of raw.jobsOfText(f.text, f.rel)) {
			if (/ERGOPTI_(?:FAST_PRERELEASE|DEV_RELEASE_)/.test(raw.field(j.body, 'env') ?? '')) {
				const keys = new Set();
				for (const match of j.body.matchAll(
					/^      (ERGOPTI_(?:FAST_PRERELEASE|DEV_RELEASE_[A-Z]+)): (.*)$/gm
				)) {
					if (keys.has(match[1])) refuse(`${j.id} duplicate admission context`);
					keys.add(match[1]);
					const variable =
						match[1] === 'ERGOPTI_FAST_PRERELEASE'
							? 'fast_prerelease'
							: match[1].slice('ERGOPTI_DEV_RELEASE_'.length).toLowerCase();
					if (
						!['fast_prerelease', 'release', 'prerelease', 'channel', 'tag', 'version'].includes(
							variable
						)
					)
						refuse(`${j.id} unknown admission context`);
					const origin = j.id === 'release' ? 'needs.validate.outputs.' : 'inputs.';
					requireEqual(
						match[2],
						`\${{ ${origin}${variable} }}`,
						`${j.id} fixed admission context ${variable}`
					);
				}
				if (keys.size === 0) refuse(`${j.id} unreadable admission context`);
			}
			const subjects = [
				[null, j.body, raw.field],
				...raw.steps(j.body).map((s) => [s.name, s.body, raw.stepField])
			];
			for (const [name, body, field] of subjects) {
				const condition = field(body, 'if');
				const row = WRAPPERS.find((r) => r[0] === f.rel && r[1] === j.id && r[2] === name);
				if (row) {
					requireEqual(
						condition,
						CONDITIONS[row[3]],
						`${f.rel}/${j.id}/${name ?? 'job'} exact temporary condition`
					);
					const identity = JSON.stringify(row.slice(0, 3));
					if (seen.has(identity)) refuse(`duplicate wrapper ${identity}`);
					seen.add(identity);
				} else if (condition?.includes('fast_prerelease'))
					refuse(`unknown temporary condition ${f.rel}/${j.id}/${name}`);
			}
		}
	if (seen.size !== WRAPPERS.length) refuse('missing fixed wrapper identity');
	return true;
}

function projectMetadata(entry) {
	let source = entry.text;
	if (entry.rel === ENTRY_REL) {
		const validation = raw.jobsOfText(source, entry.rel).find((j) => j.id === 'validate');
		const selector = raw.step(validation.body, 'Resolve authorized temporary fast prerelease');
		source = source.replace(selector, '');
		source = source.replace(
			'      ERGOPTI_FAST_PRERELEASE: ${{ needs.validate.outputs.fast_prerelease }}\n',
			''
		);
		source = source.replace(
			'      fast_prerelease: ${{ steps.fast.outputs.fast_prerelease }}\n',
			''
		);
		source = source.replaceAll(
			"      fast_prerelease: ${{ needs.validate.outputs.fast_prerelease == 'true' }}\n",
			''
		);
	} else {
		source = source.replace(
			'      fast_prerelease:\n        description: Temporary unqualified dev157 test deferral; defaults remain full\n        required: false\n        default: false\n        type: boolean\n',
			''
		);
	}
	for (const job of raw.jobsOfText(source, entry.rel)) {
		const name =
			job.id === 'release'
				? 'Recheck temporary publication authorization'
				: 'Recheck temporary fast prerelease authorization';
		const steps = raw.steps(job.body);
		const at = steps.findIndex((s) => s.name === name);
		if (at < 0) continue;
		let body = job.body;
		if (job.id !== 'release') {
			const setup = steps[at - 1]?.body;
			requireEqual(
				setup,
				"      - uses: actions/setup-node@v4\n        with:\n          node-version-file: '.node-version'",
				`${job.id} adjacent duplicate setup`
			);
			body = body.replace(setup + '\n\n', '');
		}
		body = body.replace(steps[at].body + '\n', '');
		source = source.replace(job.body, () => body);
	}
	return { ...entry, text: source };
}

function projectFile(entry) {
	let source = entry.text;
	for (const job of raw.jobsOfText(entry.text, entry.rel)) {
		let body = job.body;
		for (const row of WRAPPERS.filter(
			(r) => r[0] === entry.rel && r[1] === job.id && r[2] !== null
		)) {
			const step = raw.step(body, row[2]);
			if (CONDITIONS[row[3]] === '${{ inputs.fast_prerelease }}') {
				// These two independently checked receipt steps never run on the full route.
				body = body.replace(step, '');
			} else {
				const before = `        if: ${CONDITIONS[row[3]]}\n`;
				const after = CONDITIONS[row[4]] === null ? '' : `        if: ${CONDITIONS[row[4]]}\n`;
				body = body.replace(step, () => step.replace(before, () => after));
			}
		}
		const row = WRAPPERS.find((r) => r[0] === entry.rel && r[1] === job.id && r[2] === null);
		if (row)
			body = body.replace(`    if: ${CONDITIONS[row[3]]}\n`, () =>
				CONDITIONS[row[4]] === null ? '' : `    if: ${CONDITIONS[row[4]]}\n`
			);
		source = source.replace(job.body, () => body);
	}
	return { ...entry, text: source };
}
function fromFiles(files) {
	validateRaw(files);
	const projected = files.map(projectFile).map(projectMetadata);
	const file = (rel) => {
		const found = projected.find((f) => f.rel === rel);
		if (!found) refuse(`unknown file ${rel}`);
		return found.text;
	};
	const jobs = (rel) => raw.jobsOfText(file(rel), rel);
	const locate = (id) => {
		const found = projected.flatMap((f) => jobs(f.rel)).filter((j) => j.id === id);
		if (found.length !== 1) refuse(`ambiguous/missing projected job ${id}`);
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
