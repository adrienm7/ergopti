// tools/test/test-rtk-project-integration.cjs

/**
 * Offline contract tests for the project-owned RTK launchers. The bootstrap is
 * a developer convenience: CI must remain able to run the underlying command
 * without RTK, network access, a global hook, or a persistent PATH change.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const TOOL_ROOT = path.join(ROOT, 'tools', 'rtk');
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-rtk-'));
const RTK_INVOCATION =
	/(?:^|[\s`"'$(&])(?:rtk|(?:\.{0,2}[\\/])?tools[\\/]rtk[\\/]rtk\.(?:ps1|sh))(?=\s)/i;
const EXACT_OUTPUT_MODE =
	/--(?:explain-)?json\b|--csv\b|--stdout\b|\b(?:sha256sum|shasum|Get-FileHash)\b|\bgit\s+(?:rev-parse|hash-object)\b/i;
const OUTPUT_SINK =
	/(?<!\|)\|(?!\|)|(?:^|\s)(?:[012]?>>?|[012]?>&[012])(?:\s|$)|\b(?:Out-File|Tee-Object)\b/i;

const expectedRows = [
	[
		'v0.43.0',
		'windows',
		'x86_64',
		'rtk-x86_64-pc-windows-msvc.zip',
		'7c5e4a2ef816a4d4ed947ddd74ca3df851fc39ea87d49a3ca2bf3abc515a016b'
	],
	[
		'v0.43.0',
		'darwin',
		'x86_64',
		'rtk-x86_64-apple-darwin.tar.gz',
		'a85f60e2637811be68366208b8d8b9c5ba1b748cb5df4477ab20cd73d3c5d9f8'
	],
	[
		'v0.43.0',
		'darwin',
		'aarch64',
		'rtk-aarch64-apple-darwin.tar.gz',
		'8a17e49acbd378997eb21d0eb6f7f861111f35b4fc9b1c74edf4c7448e576c65'
	],
	[
		'v0.43.0',
		'linux',
		'x86_64',
		'rtk-x86_64-unknown-linux-musl.tar.gz',
		'ff8a1e7766496e175291a85aeca1dc97c9ff6df33e51e5893d1fbc78fea2a609'
	],
	[
		'v0.43.0',
		'linux',
		'aarch64',
		'rtk-aarch64-unknown-linux-gnu.tar.gz',
		'5519f7ca12e5c143a609f0d28a0a77b97413a8dce31c2681f1a41c24519a8731'
	]
];

function read(relativePath) {
	const content = fs.readFileSync(path.join(ROOT, relativePath), 'utf8');
	assert.equal(content.includes('\r'), false, `${relativePath} must use LF`);
	return content;
}

function agentInstructionPaths() {
	const skillsRoot = path.join(ROOT, '.agents', 'skills');
	const skills = fs
		.readdirSync(skillsRoot, { withFileTypes: true })
		.filter((entry) => entry.isDirectory())
		.map((entry) => path.join('.agents', 'skills', entry.name, 'SKILL.md'))
		.filter((relativePath) => fs.existsSync(path.join(ROOT, relativePath)));
	return [
		'AGENTS.md',
		'docs/tooling/rtk.md',
		'docs/memory/workflow-and-verification.md',
		...skills
	];
}

function unsafeRtkDataExamples(relativePath, content) {
	const violations = [];
	const lines = content.split('\n');
	for (const [index, line] of lines.entries()) {
		const invocation = RTK_INVOCATION.exec(line);
		if (invocation === null) continue;
		const prefix = line.slice(0, invocation.index);
		let command = line.slice(invocation.index);
		let cursor = index;
		while (cursor + 1 < lines.length) {
			const current = lines[cursor].trimEnd();
			const next = lines[cursor + 1].trimStart();
			const backticks = (current.match(/`/g) || []).length;
			const continues =
				current.endsWith('\\') ||
				(current.endsWith('`') && backticks % 2 === 1) ||
				/^(?:\||(?:[012]?>>?|[012]?>&[012])(?:\s|$)|Out-File\b|Tee-Object\b)/i.test(next);
			if (!continues) break;
			cursor += 1;
			command += `\n${lines[cursor]}`;
		}
		const captured =
			/\$\(\s*$/.test(prefix) || /(?:^|[\s`])\$[A-Za-z_][\w:.-]*\s*=\s*(?:&\s*)?$/.test(prefix);
		if (captured || OUTPUT_SINK.test(command) || EXACT_OUTPUT_MODE.test(command)) {
			violations.push(`${relativePath}:${index + 1}`);
		}
	}
	return violations;
}

function copyTooling() {
	const destination = path.join(temporaryRoot, 'tools', 'rtk');
	fs.mkdirSync(destination, { recursive: true });
	for (const name of ['release.tsv', 'bootstrap.ps1', 'bootstrap.sh', 'rtk.ps1', 'rtk.sh']) {
		fs.copyFileSync(path.join(TOOL_ROOT, name), path.join(destination, name));
	}
	return destination;
}

function findPosixShell() {
	const direct = spawnSync('sh', ['-c', ':'], { encoding: 'utf8' });
	if (!direct.error) return 'sh';

	const git = spawnSync('git', ['--exec-path'], { encoding: 'utf8' });
	if (git.status !== 0 || !git.stdout.trim()) return null;
	let ancestor = path.resolve(git.stdout.trim());
	while (true) {
		for (const relative of [path.join('bin', 'sh.exe'), path.join('usr', 'bin', 'sh.exe')]) {
			const candidate = path.join(ancestor, relative);
			if (fs.existsSync(candidate)) return candidate;
		}
		const parent = path.dirname(ancestor);
		if (parent === ancestor) return null;
		ancestor = parent;
	}
}

try {
	const manifest = read('tools/rtk/release.tsv')
		.trimEnd()
		.split('\n')
		.map((line) => line.split('\t'));
	assert.deepEqual(manifest[0], ['version', 'os', 'arch', 'asset', 'sha256']);
	assert.deepEqual(
		manifest.slice(1),
		expectedRows,
		'the reviewed release matrix and checksums must stay pinned'
	);

	const scripts = ['bootstrap.ps1', 'bootstrap.sh', 'rtk.ps1', 'rtk.sh']
		.map((name) => read(`tools/rtk/${name}`))
		.join('\n');
	assert.match(
		scripts,
		/releases\/download\/\$?(?:Version|version)/,
		'download URL must include the pinned version'
	);
	assert.doesNotMatch(scripts, /rtk\s+init[^\n]*(?:--global|-g\b)/i);
	assert.doesNotMatch(scripts, /curl[^\n|]*\|\s*(?:ba)?sh\b/i);
	assert.doesNotMatch(
		scripts,
		/(?:setx|\.bashrc|\.zshrc|\$PROFILE)/i,
		'bootstrap must not persist PATH changes'
	);
	const powershellBootstrap = read('tools/rtk/bootstrap.ps1');
	assert.match(powershellBootstrap, /Test-RtkBinary -Path \$Cached -RequirePinnedVersion/);
	assert.match(powershellBootstrap, /Test-RtkBinary -Path \$Command\.Source -RequirePinnedVersion/);
	const posixBootstrap = read('tools/rtk/bootstrap.sh');
	assert.match(posixBootstrap, /is_rtk "\$cached" "\$version"/);
	assert.match(posixBootstrap, /is_rtk "\$candidate" "\$version"/);

	const instructionPaths = agentInstructionPaths();
	assert.ok(instructionPaths.length >= 10, 'instruction scan must keep a useful floor');
	const unsafeExamples = instructionPaths.flatMap((relativePath) =>
		unsafeRtkDataExamples(relativePath, read(relativePath))
	);
	assert.deepEqual(unsafeExamples, [], 'RTK examples must not feed exact machine-data consumers');
	for (const example of [
		'./tools/rtk/rtk.sh report --json | jq .',
		'.\\tools\\rtk\\rtk.ps1 report > receipt.json',
		'commit=$(./tools/rtk/rtk.sh git rev-parse HEAD)',
		'./tools/rtk/rtk.sh tests --explain-json',
		'./tools/rtk/rtk.sh report \\\n  | jq .',
		'.\\tools\\rtk\\rtk.ps1 report `\n  | ConvertFrom-Json'
	]) {
		assert.equal(
			unsafeRtkDataExamples('mutation.md', example).length,
			1,
			`unsafe mutation survived: ${example}`
		);
	}
	assert.deepEqual(
		unsafeRtkDataExamples(
			'safe.md',
			'./tools/rtk/rtk.sh git status\ngit diff --raw > candidate.diff\n'
		),
		[]
	);

	const isolatedTooling = copyTooling();
	const exitProbe = path.join(temporaryRoot, 'exit-probe.cjs');
	fs.writeFileSync(exitProbe, 'process.exit(23);\n', 'utf8');
	const environment = {
		...process.env,
		CI: '1',
		LOCALAPPDATA: path.join(temporaryRoot, 'local-data'),
		XDG_DATA_HOME: path.join(temporaryRoot, 'xdg-data')
	};

	let result;
	if (process.platform === 'win32') {
		const powershell = path.join(
			process.env.SystemRoot || 'C:\\Windows',
			'System32',
			'WindowsPowerShell',
			'v1.0',
			'powershell.exe'
		);
		environment.PATH = path.dirname(powershell);
		result = spawnSync(
			powershell,
			['-NoProfile', '-File', path.join(isolatedTooling, 'bootstrap.ps1'), 'verify'],
			{ encoding: 'utf8', env: environment }
		);
		assert.equal(result.status, 3, result.stderr);

		result = spawnSync(
			powershell,
			['-NoProfile', '-File', path.join(isolatedTooling, 'rtk.ps1'), process.execPath, exitProbe],
			{ encoding: 'utf8', env: environment }
		);
		assert.equal(result.status, 23, result.stderr || result.stdout);

		const gitSh = findPosixShell();
		if (gitSh !== null) {
			const posixResult = spawnSync(
				gitSh,
				[path.join(isolatedTooling, 'rtk.sh'), process.execPath, exitProbe],
				{ encoding: 'utf8', env: environment }
			);
			assert.equal(posixResult.status, 23, posixResult.stderr || posixResult.stdout);
		}
	} else {
		const privateBin = path.join(temporaryRoot, 'bin');
		fs.mkdirSync(privateBin);
		fs.symlinkSync('/usr/bin/dirname', path.join(privateBin, 'dirname'));
		environment.PATH = privateBin;
		result = spawnSync('/bin/sh', [path.join(isolatedTooling, 'bootstrap.sh'), 'verify'], {
			encoding: 'utf8',
			env: environment
		});
		assert.equal(result.status, 3, result.stderr);

		result = spawnSync(
			'/bin/sh',
			[path.join(isolatedTooling, 'rtk.sh'), process.execPath, exitProbe],
			{ encoding: 'utf8', env: environment }
		);
	}
	assert.equal(result.status, 23, result.stderr || result.stdout);

	console.log('project RTK integration: ok');
} finally {
	fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
