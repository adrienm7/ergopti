// tools/test/test-audit-workflow.cjs

/**
 * End-to-end coverage for the portable audit manifest and worktree workflow.
 * The real CLI runs against disposable Git worktrees; no repository worktree
 * owned by the developer is inspected or modified by this test.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SCRIPT = path.join(ROOT, 'tools', 'audit', 'workflow.cjs');
const temporaryParent = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-audit-workflow-'));
const repository = path.join(temporaryParent, 'ergopti');
const auditWorktree = path.join(temporaryParent, 'ergopti-fix-ahk');

function command(program, args, cwd, allowFailure = false) {
	const result = spawnSync(program, args, { cwd, encoding: 'utf8' });
	if (!allowFailure && result.status !== 0) {
		throw new Error(`${program} ${args.join(' ')} failed: ${result.stderr || result.stdout}`);
	}
	return result;
}

function git(cwd, ...args) {
	return command('git', args, cwd);
}

function write(root, relative, content) {
	const absolute = path.join(root, relative);
	fs.mkdirSync(path.dirname(absolute), { recursive: true });
	fs.writeFileSync(absolute, content, 'utf8');
}

function workflowAt(root, ...args) {
	return command(process.execPath, [SCRIPT, ...args, '--root', root], root, true);
}

function workflow(...args) {
	return workflowAt(repository, ...args);
}

function json(result) {
	assert.equal(result.status, 0, result.stderr);
	return JSON.parse(result.stdout);
}

try {
	fs.mkdirSync(repository);
	git(repository, 'init');
	git(repository, 'config', 'user.email', 'audit-test@example.invalid');
	git(repository, 'config', 'user.name', 'Audit Test');
	write(repository, 'README.md', 'fixture\n');
	git(repository, 'add', 'README.md');
	git(repository, 'commit', '-m', 'chore: initialize fixture');
	const auditedSha = git(repository, 'rev-parse', 'HEAD').stdout.trim();

	const dateDirectory = 'docs/audits/ahk/2026_08_22';
	write(repository, `${dateDirectory}/report.md`, '# AHK audit\n');
	write(
		repository,
		`${dateDirectory}/findings.json`,
		`${JSON.stringify(
			{
				schema_version: 1,
				scope: 'ahk',
				audited_sha: auditedSha,
				created_at: '2026-08-22',
				report_path: `${dateDirectory}/report.md`,
				findings: [
					{
						id: 'AHK-001',
						title: 'Fixture failure',
						severity: 'high',
						confidence: 'high',
						guarantees: ['G2'],
						reproduction: 'Run the fixture action.',
						root_cause: 'The fixture production file lacks a guard.',
						silent_failure: 'No fixture test existed.',
						regression_test: 'The fixture test observes the guard.'
					},
					{
						id: 'AHK-002',
						title: 'Second fixture failure',
						severity: 'medium',
						confidence: 'high',
						guarantees: ['G3'],
						reproduction: 'Run the second fixture action.',
						root_cause: 'The second fixture production path lacks a guard.',
						silent_failure: 'An unrelated tooling commit could claim completion.',
						regression_test: 'Reject commits that do not change scoped production.'
					},
					{
						id: 'AHK-003',
						title: 'Canonical test runner exits before its tail',
						severity: 'medium',
						confidence: 'high',
						guarantees: ['G5'],
						reproduction: 'Run the complete fixture suite.',
						root_cause: 'tests/run_all.ahk uses a stale fixed watchdog.',
						silent_failure: 'A partial green transcript resembles completion.',
						regression_test: 'Reject a manifest missing its slow tail.'
					}
				]
			},
			null,
			2
		)}\n`
	);

	let state = json(workflow('preflight', '--scope', 'ahk'));
	assert.equal(state.state, 'missing');
	assert.equal(path.resolve(state.expected_path), path.resolve(auditWorktree));

	let result = workflow('validate-report', '--report', `${dateDirectory}/findings.json`);
	assert.equal(json(result).findings, 3);
	assert.equal(
		json(workflow('extract', '--report', `${dateDirectory}/findings.json`, '--id', 'AHK-001'))
			.finding.title,
		'Fixture failure'
	);

	git(repository, 'worktree', 'add', '-b', 'fix/ahk-audit-2026-08-22', auditWorktree, auditedSha);
	state = json(workflow('preflight', '--scope', 'autohotkey'));
	assert.equal(state.state, 'ready');
	assert.equal(state.dirty, false);

	write(auditWorktree, 'static/ergopti_plus/windows/modules/example.ahk', '; fixed\n');
	write(auditWorktree, 'static/ergopti_plus/windows/tests/unit/test_example.ahk', '; regression\n');
	git(
		auditWorktree,
		'add',
		'static/ergopti_plus/windows/modules/example.ahk',
		'static/ergopti_plus/windows/tests/unit/test_example.ahk'
	);
	git(auditWorktree, 'commit', '-m', 'fix(ahk): guard fixture failure\n\nAudit-Finding: AHK-001');

	const verified = json(
		workflow(
			'verify-commit',
			'--report',
			`${dateDirectory}/findings.json`,
			'--id',
			'AHK-001',
			'--commit',
			'HEAD'
		)
	);
	assert.equal(verified.id, 'AHK-001');
	assert.equal(verified.production.length, 1);
	assert.equal(verified.tests.length, 1);

	const status = json(workflow('status', '--report', `${dateDirectory}/findings.json`));
	assert.deepEqual(status.open, ['AHK-002', 'AHK-003']);
	assert.equal(typeof status.completed['AHK-001'], 'string');

	write(auditWorktree, 'tools/audit/unrelated.cjs', '// unrelated tooling\n');
	write(auditWorktree, 'tools/test/test-unrelated.cjs', '// unrelated test\n');
	git(auditWorktree, 'add', 'tools/audit/unrelated.cjs', 'tools/test/test-unrelated.cjs');
	git(
		auditWorktree,
		'commit',
		'-m',
		'fix(tooling): unrelated audit helper\n\nAudit-Finding: AHK-002'
	);
	result = workflow(
		'verify-commit',
		'--report',
		`${dateDirectory}/findings.json`,
		'--id',
		'AHK-002',
		'--commit',
		'HEAD'
	);
	assert.notEqual(
		result.status,
		0,
		'an unrelated tools change and generic JS test must not satisfy an AHK finding'
	);

	write(auditWorktree, 'static/ergopti_plus/windows/tests/run_all.ahk', '; adaptive runner\n');
	write(auditWorktree, 'tools/test/validate-ahk-suite-manifest.cjs', '// exact manifest validator\n');
	write(auditWorktree, 'tools/test/test-ahk-suite-manifest.cjs', '// slow-tail regression\n');
	git(
		auditWorktree,
		'add',
		'static/ergopti_plus/windows/tests/run_all.ahk',
		'tools/test/validate-ahk-suite-manifest.cjs',
		'tools/test/test-ahk-suite-manifest.cjs'
	);
	git(auditWorktree, 'commit', '-m', 'test(ahk): verify complete suite\n\nAudit-Finding: AHK-003');
	const infrastructureVerified = json(
		workflow(
			'verify-commit',
			'--report',
			`${dateDirectory}/findings.json`,
			'--id',
			'AHK-003',
			'--commit',
			'HEAD'
		)
	);
	assert.equal(infrastructureVerified.id, 'AHK-003');
	assert.ok(infrastructureVerified.production.includes('static/ergopti_plus/windows/tests/run_all.ahk'));
	assert.equal(infrastructureVerified.tests.length, 2);

	result = workflow('status', '--report', `${dateDirectory}/findings.json`);
	assert.notEqual(
		result.status,
		0,
		'status must validate a completion commit instead of trusting its trailer alone'
	);

	write(auditWorktree, 'local-note.txt', 'preserve me\n');
	state = json(workflow('preflight', '--scope', 'ahk'));
	assert.equal(state.state, 'ready');
	assert.equal(state.dirty, true);
	assert.equal(state.preserve_existing_changes, true);

	const competingWorktree = path.join(temporaryParent, 'ergopti_fix_hs');
	git(
		repository,
		'worktree',
		'add',
		'-b',
		'fix/hammerspoon-audit-2026-08-22',
		competingWorktree,
		auditedSha
	);
	state = json(workflow('preflight', '--scope', 'hammerspoon'));
	assert.equal(state.state, 'blocked');
	assert.equal(state.reason, 'another_scope_worktree_is_active');

	const swiftRepository = path.join(temporaryParent, 'ergopti-swift');
	const swiftAuditWorktree = `${swiftRepository}-fix-hs`;
	fs.mkdirSync(swiftRepository);
	git(swiftRepository, 'init');
	git(swiftRepository, 'config', 'user.email', 'audit-test@example.invalid');
	git(swiftRepository, 'config', 'user.name', 'Audit Test');
	write(swiftRepository, 'README.md', 'swift fixture\n');
	git(swiftRepository, 'add', 'README.md');
	git(swiftRepository, 'commit', '-m', 'chore: initialize Swift fixture');
	const swiftAuditedSha = git(swiftRepository, 'rev-parse', 'HEAD').stdout.trim();
	const swiftDateDirectory = 'docs/audits/hammerspoon/2026_08_23';
	write(swiftRepository, `${swiftDateDirectory}/report.md`, '# Hammerspoon audit\n');
	write(
		swiftRepository,
		`${swiftDateDirectory}/findings.json`,
		`${JSON.stringify(
			{
				schema_version: 1,
				scope: 'hammerspoon',
				audited_sha: swiftAuditedSha,
				created_at: '2026-08-23',
				report_path: `${swiftDateDirectory}/report.md`,
				findings: [
					{
						id: 'HS-177',
						title: 'Swift launcher fixture failure',
						severity: 'low',
						confidence: 'high',
						guarantees: ['G1'],
						reproduction: 'Run the native launcher fixture.',
						root_cause: 'The launcher worker lacks a receive bound.',
						silent_failure: 'The serial queue stops serving work.',
						regression_test: 'The XCTest observes the receive bound.'
					}
				]
			},
			null,
			2
		)}\n`
	);
	git(
		swiftRepository,
		'worktree',
		'add',
		'-b',
		'fix/hammerspoon-audit-2026-08-23',
		swiftAuditWorktree,
		swiftAuditedSha
	);
	write(
		swiftAuditWorktree,
		'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/Worker.swift',
		'// fixed\n'
	);
	write(
		swiftAuditWorktree,
		'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/WorkerTests.swift',
		'// regression\n'
	);
	git(swiftAuditWorktree, 'add', 'static/ergopti_plus/macos/launcher');
	git(
		swiftAuditWorktree,
		'commit',
		'-m',
		'fix(logger): bound receive loop\n\nAudit-Finding: HS-177'
	);
	const swiftVerified = json(workflowAt(
		swiftRepository,
		'verify-commit',
		'--report',
		`${swiftDateDirectory}/findings.json`,
		'--id',
		'HS-177',
		'--commit',
		'HEAD'
	));
	assert.deepEqual(swiftVerified.production, [
		'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/Worker.swift'
	]);
	assert.deepEqual(swiftVerified.tests, [
		'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/WorkerTests.swift'
	]);

	const malformed = JSON.parse(
		fs.readFileSync(path.join(repository, dateDirectory, 'findings.json'), 'utf8')
	);
	malformed.findings[0].root_cause = '';
	write(repository, `${dateDirectory}/findings.json`, `${JSON.stringify(malformed, null, 2)}\n`);
	result = workflow('validate-report', '--report', `${dateDirectory}/findings.json`);
	assert.notEqual(result.status, 0, 'an empty root cause must invalidate the manifest');

	console.log('audit workflow: ok');
} finally {
	fs.rmSync(temporaryParent, { recursive: true, force: true });
}
