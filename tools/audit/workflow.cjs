// tools/audit/workflow.cjs

/**
 * Deterministic audit queue and worktree preflight. The tool reads repository,
 * report, and Git state; it never creates, moves, cleans, stashes, commits,
 * merges, or pushes a worktree.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const DEFAULT_ROOT = path.resolve(__dirname, '..', '..');
const SCOPES = {
	ahk: { prefix: 'AHK', worktreeSuffix: 'fix-ahk', driver: 'windows' },
	hammerspoon: { prefix: 'HS', worktreeSuffix: 'fix-hs', driver: 'macos' }
};
const SCOPE_ALIASES = new Map([
	['ahk', 'ahk'],
	['autohotkey', 'ahk'],
	['hs', 'hammerspoon'],
	['hammerspoon', 'hammerspoon'],
	['macos', 'hammerspoon']
]);
const SEVERITIES = new Set(['critical', 'high', 'medium', 'low']);
const CONFIDENCES = new Set(['high', 'medium', 'low']);
const GUARANTEES = new Set(['G1', 'G2', 'G3', 'G4', 'G5']);

function fail(message) {
	throw new Error(message);
}

function git(cwd, args, options = {}) {
	const result = spawnSync('git', args, {
		cwd,
		encoding: options.encoding === null ? null : 'utf8',
		input: options.input
	});
	if (result.error || result.status === null)
		fail(`git ${args[0]} could not run: ${result.error ? result.error.message : 'no exit status'}`);
	if (result.status !== 0 && !options.allowFailure) {
		const diagnostic = `${result.stderr || result.stdout || ''}`.trim();
		fail(`git ${args.join(' ')} failed${diagnostic ? `: ${diagnostic}` : ''}`);
	}
	return result;
}

function normalizeScope(value) {
	const scope = SCOPE_ALIASES.get(String(value || '').toLowerCase());
	if (!scope) fail('scope must be ahk/autohotkey or hammerspoon/hs/macos');
	return scope;
}

function parseArgs(argv) {
	const command = argv[0];
	if (!['preflight', 'validate-report', 'extract', 'status', 'verify-commit'].includes(command)) {
		fail('usage: workflow.cjs <preflight|validate-report|extract|status|verify-commit> [options]');
	}
	const options = { command, root: DEFAULT_ROOT };
	for (let index = 1; index < argv.length; index += 1) {
		const argument = argv[index];
		if (!argument.startsWith('--') || !argv[index + 1])
			fail(`unknown or incomplete argument: ${argument}`);
		const key = argument.slice(2).replace(/-([a-z])/g, (_match, letter) => letter.toUpperCase());
		if (!['root', 'scope', 'report', 'id', 'commit'].includes(key))
			fail(`unknown option: ${argument}`);
		options[key] = argv[index + 1];
		index += 1;
	}
	options.root = path.resolve(options.root);
	if (options.scope) options.scope = normalizeScope(options.scope);
	return options;
}

function samePath(left, right) {
	const normalize = (value) => {
		const resolved = path.resolve(value);
		return process.platform === 'win32' ? resolved.toLowerCase() : resolved;
	};
	return normalize(left) === normalize(right);
}

function repositoryRoot(candidate) {
	const root = git(candidate, ['rev-parse', '--show-toplevel']).stdout.trim();
	if (!samePath(root, candidate)) fail(`--root must name the main repository checkout: ${root}`);
	return path.resolve(root);
}

function canonicalWorktree(root, scope) {
	const config = SCOPES[normalizeScope(scope)];
	return path.resolve(path.dirname(root), `${path.basename(root)}-${config.worktreeSuffix}`);
}

function parseWorktrees(raw) {
	const records = [];
	let current = null;
	for (const token of raw.split('\0')) {
		if (token.startsWith('worktree ')) {
			current = { path: token.slice('worktree '.length) };
			records.push(current);
		} else if (!current || !token) {
			continue;
		} else if (token.startsWith('HEAD ')) {
			current.head = token.slice('HEAD '.length);
		} else if (token.startsWith('branch ')) {
			current.branch = token.slice('branch '.length).replace(/^refs\/heads\//, '');
		} else if (token === 'detached') {
			current.detached = true;
		} else if (token.startsWith('locked')) {
			current.locked = token.slice('locked'.length).trim() || true;
		} else if (token.startsWith('prunable')) {
			current.prunable = token.slice('prunable'.length).trim() || true;
		}
	}
	return records;
}

function branchMatchesScope(branch, scope) {
	if (!branch) return false;
	return scope === 'ahk'
		? /(^|[\/_-])(ahk|autohotkey)([\/_-]|$)/i.test(branch)
		: /(^|[\/_-])(hs|hammerspoon|macos)([\/_-]|$)/i.test(branch);
}

function pathMatchesScope(candidate, scope) {
	const base = path.basename(candidate);
	return scope === 'ahk'
		? /(?:-|_)fix(?:-|_)(?:ahk|autohotkey)$/i.test(base)
		: /(?:-|_)fix(?:-|_)(?:hs|hammerspoon|macos)$/i.test(base);
}

function dirtyPaths(worktree) {
	const output = git(worktree, ['status', '--porcelain=v1', '--untracked-files=all']).stdout;
	return output
		.split(/\r?\n/)
		.filter(Boolean)
		.map((line) => line.slice(3).replace(/^.* -> /, ''));
}

function preflight(rootCandidate, requestedScope) {
	const root = repositoryRoot(rootCandidate);
	const scope = normalizeScope(requestedScope);
	const expectedPath = canonicalWorktree(root, scope);
	const records = parseWorktrees(git(root, ['worktree', 'list', '--porcelain', '-z']).stdout);
	const expected = records.find((record) => samePath(record.path, expectedPath));
	const competing = records.filter(
		(record) =>
			!samePath(record.path, root) &&
			!samePath(record.path, expectedPath) &&
			(branchMatchesScope(record.branch, scope) || pathMatchesScope(record.path, scope))
	);

	if (expected) {
		if (!fs.existsSync(expectedPath))
			fail(`registered canonical worktree is missing on disk: ${expectedPath}`);
		if (!branchMatchesScope(expected.branch, scope)) {
			return {
				scope,
				root,
				expected_path: expectedPath,
				state: 'blocked',
				reason: 'canonical_path_has_wrong_branch',
				branch: expected.branch || null
			};
		}
		if (expected.locked || expected.prunable) {
			return {
				scope,
				root,
				expected_path: expectedPath,
				state: 'blocked',
				reason: expected.locked ? 'worktree_locked' : 'worktree_prunable',
				branch: expected.branch || null
			};
		}
		const dirty = dirtyPaths(expectedPath);
		return {
			scope,
			root,
			expected_path: expectedPath,
			state: 'ready',
			action: 'resume',
			branch: expected.branch,
			head: expected.head,
			dirty: dirty.length > 0,
			dirty_count: dirty.length,
			dirty_paths: dirty.slice(0, 20),
			preserve_existing_changes: true
		};
	}

	if (fs.existsSync(expectedPath)) {
		return {
			scope,
			root,
			expected_path: expectedPath,
			state: 'blocked',
			reason: 'canonical_path_exists_but_is_not_registered'
		};
	}
	if (competing.length > 0) {
		return {
			scope,
			root,
			expected_path: expectedPath,
			state: 'blocked',
			reason: 'another_scope_worktree_is_active',
			competing: competing.map((record) => ({
				path: path.resolve(record.path),
				branch: record.branch || null,
				head: record.head || null
			}))
		};
	}
	return {
		scope,
		root,
		expected_path: expectedPath,
		state: 'missing',
		action: 'create_explicitly',
		can_create: true
	};
}

function isWithin(root, candidate) {
	const relative = path.relative(root, candidate);
	return relative && !relative.startsWith('..') && !path.isAbsolute(relative);
}

function latestReport(root, scope) {
	const base = path.join(root, 'docs', 'audits', scope);
	if (!fs.existsSync(base)) fail(`no audit directory for scope ${scope}`);
	const dated = fs
		.readdirSync(base, { withFileTypes: true })
		.filter((entry) => entry.isDirectory() && /^\d{4}_\d{2}_\d{2}$/.test(entry.name))
		.map((entry) => entry.name)
		.sort((left, right) => right.localeCompare(left));
	const selected = dated.find((date) => fs.existsSync(path.join(base, date, 'findings.json')));
	if (!selected) fail(`no findings.json under ${path.relative(root, base)}`);
	return path.join(base, selected, 'findings.json');
}

function requireText(object, field, context) {
	if (typeof object[field] !== 'string' || object[field].trim() === '')
		fail(`${context}.${field} must be a non-empty string`);
}

function loadReport(rootCandidate, reportOption, scopeOption) {
	const root = repositoryRoot(rootCandidate);
	const reportFile = reportOption
		? path.resolve(root, reportOption)
		: latestReport(root, normalizeScope(scopeOption));
	if (!isWithin(root, reportFile)) fail('report must be inside the repository');
	const relativeFile = path.relative(root, reportFile).replace(/\\/g, '/');
	const match = relativeFile.match(
		/^docs\/audits\/(ahk|hammerspoon)\/(\d{4}_\d{2}_\d{2})\/findings\.json$/
	);
	if (!match)
		fail('findings.json must live at docs/audits/<ahk|hammerspoon>/<YYYY_MM_DD>/findings.json');
	let manifest;
	try {
		manifest = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
	} catch (error) {
		fail(`cannot parse ${relativeFile}: ${error.message}`);
	}
	if (!manifest || Array.isArray(manifest) || typeof manifest !== 'object')
		fail('report manifest must be a JSON object');
	if (manifest.schema_version !== 1) fail('schema_version must be 1');
	const scope = normalizeScope(manifest.scope);
	if (scope !== match[1]) fail('manifest scope must match its directory');
	if (scopeOption && scope !== normalizeScope(scopeOption))
		fail('manifest scope does not match --scope');
	if (!/^[0-9a-f]{40}$/.test(manifest.audited_sha || ''))
		fail('audited_sha must be a full 40-character lowercase Git SHA');
	if (!/^\d{4}-\d{2}-\d{2}$/.test(manifest.created_at || ''))
		fail('created_at must use YYYY-MM-DD');
	if (manifest.created_at.replace(/-/g, '_') !== match[2])
		fail('created_at must match the dated directory');
	requireText(manifest, 'report_path', 'manifest');
	const expectedReportPath = relativeFile.replace(/findings\.json$/, 'report.md');
	if (manifest.report_path.replace(/\\/g, '/') !== expectedReportPath)
		fail(`report_path must be ${expectedReportPath}`);
	if (!fs.existsSync(path.join(root, expectedReportPath)))
		fail(`human report is missing: ${expectedReportPath}`);
	if (!Array.isArray(manifest.findings)) fail('findings must be an array');
	const ids = new Set();
	const prefix = SCOPES[scope].prefix;
	for (let index = 0; index < manifest.findings.length; index += 1) {
		const finding = manifest.findings[index];
		const context = `findings[${index}]`;
		if (!finding || Array.isArray(finding) || typeof finding !== 'object')
			fail(`${context} must be an object`);
		for (const field of [
			'id',
			'title',
			'severity',
			'confidence',
			'reproduction',
			'root_cause',
			'silent_failure',
			'regression_test'
		]) {
			requireText(finding, field, context);
		}
		if (!new RegExp(`^${prefix}-\\d{3}$`).test(finding.id))
			fail(`${context}.id must match ${prefix}-NNN`);
		if (ids.has(finding.id)) fail(`duplicate finding id: ${finding.id}`);
		ids.add(finding.id);
		if (!SEVERITIES.has(finding.severity)) fail(`${context}.severity is invalid`);
		if (!CONFIDENCES.has(finding.confidence)) fail(`${context}.confidence is invalid`);
		if (
			!Array.isArray(finding.guarantees) ||
			finding.guarantees.length === 0 ||
			finding.guarantees.some((guarantee) => !GUARANTEES.has(guarantee))
		) {
			fail(`${context}.guarantees must contain only G1..G5`);
		}
	}
	return { root, reportFile, relativeFile, manifest, scope };
}

function commitRecords(worktree, auditedSha) {
	const relation = git(worktree, ['merge-base', '--is-ancestor', auditedSha, 'HEAD'], {
		allowFailure: true
	});
	if (relation.status !== 0)
		fail(`audited SHA ${auditedSha} is not an ancestor of the worktree HEAD`);
	const output = git(worktree, ['log', '--format=%H%x1f%B%x1e', `${auditedSha}..HEAD`]).stdout;
	return output
		.split('\x1e')
		.map((record) => record.trim())
		.filter(Boolean)
		.map((record) => {
			const separator = record.indexOf('\x1f');
			return { sha: record.slice(0, separator), message: record.slice(separator + 1) };
		});
}

function findingTrailers(message) {
	return [...message.matchAll(/^Audit-Finding:\s*((?:AHK|HS)-\d{3})\s*$/gim)].map((match) =>
		match[1].toUpperCase()
	);
}

function statusFor(rootCandidate, reportOption, scopeOption) {
	const report = loadReport(rootCandidate, reportOption, scopeOption);
	const worktreeState = preflight(report.root, report.scope);
	if (worktreeState.state !== 'ready')
		fail(`canonical worktree is not ready: ${worktreeState.reason || worktreeState.state}`);
	const commits = commitRecords(worktreeState.expected_path, report.manifest.audited_sha);
	const known = new Set(report.manifest.findings.map((finding) => finding.id));
	const completed = new Map();
	const unknownTrailers = [];
	for (const commit of commits) {
		for (const id of findingTrailers(commit.message)) {
			if (!known.has(id)) unknownTrailers.push({ id, commit: commit.sha });
			else if (completed.has(id))
				fail(
					`finding ${id} has multiple completion commits: ${completed.get(id)} and ${commit.sha}`
				);
			else {
				try {
					verifyCommit(report.root, report.relativeFile, report.scope, id, commit.sha);
				} catch (error) {
					fail(`finding ${id} completion commit ${commit.sha} is invalid: ${error.message}`);
				}
				completed.set(id, commit.sha);
			}
		}
	}
	if (unknownTrailers.length > 0)
		fail(`unknown Audit-Finding trailer(s): ${unknownTrailers.map((item) => item.id).join(', ')}`);
	const open = report.manifest.findings
		.map((finding) => finding.id)
		.filter((id) => !completed.has(id));
	return {
		scope: report.scope,
		report: report.relativeFile,
		audited_sha: report.manifest.audited_sha,
		worktree: worktreeState.expected_path,
		branch: worktreeState.branch,
		head: git(worktreeState.expected_path, ['rev-parse', 'HEAD']).stdout.trim(),
		dirty: worktreeState.dirty,
		dirty_count: worktreeState.dirty_count,
		completed: Object.fromEntries(completed),
		open,
		next_open: open[0] || null
	};
}

function verifyCommit(rootCandidate, reportOption, scopeOption, id, commitOption) {
	if (!id) fail('verify-commit requires --id');
	const report = loadReport(rootCandidate, reportOption, scopeOption);
	const normalizedId = String(id).toUpperCase();
	const finding = report.manifest.findings.find((candidate) => candidate.id === normalizedId);
	if (!finding)
		fail(`finding is not in the manifest: ${normalizedId}`);
	const worktreeState = preflight(report.root, report.scope);
	if (worktreeState.state !== 'ready')
		fail(`canonical worktree is not ready: ${worktreeState.reason || worktreeState.state}`);
	const worktree = worktreeState.expected_path;
	const commit = git(worktree, ['rev-parse', `${commitOption || 'HEAD'}^{commit}`]).stdout.trim();
	if (
		git(worktree, ['merge-base', '--is-ancestor', report.manifest.audited_sha, commit], {
			allowFailure: true
		}).status !== 0
	) {
		fail('commit does not descend from the audited SHA');
	}
	const parents = git(worktree, ['rev-list', '--parents', '-n', '1', commit])
		.stdout.trim()
		.split(/\s+/);
	if (parents.length !== 2) fail('audit fix commit must be a non-merge commit with one parent');
	const message = git(worktree, ['show', '-s', '--format=%B', commit]).stdout;
	const trailers = findingTrailers(message);
	if (trailers.length !== 1 || trailers[0] !== normalizedId)
		fail(`commit must contain exactly one Audit-Finding: ${normalizedId} trailer`);
	const files = git(worktree, ['diff-tree', '--no-commit-id', '--name-only', '-r', commit])
		.stdout.split(/\r?\n/)
		.filter(Boolean)
		.map((file) => file.replace(/\\/g, '/'));
	if (files.some((file) => file.startsWith('docs/audits/')))
		fail('audit fix commits must not mutate immutable audit artifacts');
	const driver = SCOPES[report.scope].driver;
	const driverPrefix = `static/ergopti_plus/${driver}/`;
	const production = files.filter(
		(file) =>
			(file.startsWith(driverPrefix) && !/\/tests\//i.test(file)) ||
			(file.startsWith('static/ergopti_plus/_shared/') && !/\/tests\//i.test(file))
	);
	// A finding can target the canonical test runner itself. In that narrow case,
	// demanding an unrelated driver edit would reward a fake production change.
	// The audit record must explicitly name test/CI infrastructure as its root
	// cause, and the commit must contain a real runner/tooling implementation file;
	// generic tools changes still cannot claim an ordinary driver finding.
	const testInfrastructureFinding = /(?:^|[\s(])(?:tests\/|tools\/test\/|\.github\/workflows\/)/i
		.test(finding.root_cause);
	if (production.length === 0 && testInfrastructureFinding) {
		production.push(...files.filter((file) =>
			file === 'package.json' ||
			file.startsWith('.github/workflows/') ||
			file === `${driverPrefix}tests/run_all.ahk` ||
			file === `${driverPrefix}tests/test_framework.ahk` ||
			(/^tools\/test\/(?!test-).+\.c?js$/.test(file))
		));
	}
	const tests = files.filter(
		(file) =>
			(file.startsWith(`${driverPrefix}tests/`) &&
				(file.endsWith('.ahk') || file.endsWith('.lua'))) ||
			(file.startsWith(`${driverPrefix}launcher/Tests/`) && file.endsWith('.swift')) ||
			/^tools\/test\/test-.*\.c?js$/.test(file)
	);
	if (production.length === 0)
		fail('audit fix commit has no production change for the selected scope');
	if (tests.length === 0) fail('audit fix commit has no regression test for the selected scope');
	return { scope: report.scope, id: normalizedId, commit, files, production, tests };
}

function run(argv) {
	const options = parseArgs(argv);
	if (options.command === 'preflight') {
		if (!options.scope) fail('preflight requires --scope');
		return preflight(options.root, options.scope);
	}
	if (options.command === 'validate-report') {
		const report = loadReport(options.root, options.report, options.scope);
		return {
			valid: true,
			scope: report.scope,
			report: report.relativeFile,
			findings: report.manifest.findings.length,
			audited_sha: report.manifest.audited_sha
		};
	}
	if (options.command === 'extract') {
		if (!options.id) fail('extract requires --id');
		const report = loadReport(options.root, options.report, options.scope);
		const id = options.id.toUpperCase();
		const finding = report.manifest.findings.find((candidate) => candidate.id === id);
		if (!finding) fail(`finding is not in the manifest: ${id}`);
		return {
			scope: report.scope,
			audited_sha: report.manifest.audited_sha,
			report: report.relativeFile,
			finding
		};
	}
	if (options.command === 'status') return statusFor(options.root, options.report, options.scope);
	return verifyCommit(options.root, options.report, options.scope, options.id, options.commit);
}

if (require.main === module) {
	try {
		console.log(JSON.stringify(run(process.argv.slice(2))));
	} catch (error) {
		console.error(`audit-workflow: ${error.message}`);
		process.exit(1);
	}
}

module.exports = {
	branchMatchesScope,
	canonicalWorktree,
	findingTrailers,
	loadReport,
	normalizeScope,
	parseWorktrees,
	preflight,
	run,
	verifyCommit
};
