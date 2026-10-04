// tools/test/support/windows-startup-log-runtime.cjs

/** Executes the actual startup log collector against owned native log files. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('../ci-pipeline.cjs');

/** Uses the exact standard-library catalogue reader owned by the native workflow. */
function readStartupLogCatalog(recipe, root = pipeline.ROOT, execute = spawnSync) {
	assert.ok(
		Array.isArray(recipe) && recipe.every((line) => typeof line === 'string'),
		'the native log catalogue reader requires the actual workflow recipe'
	);
	const commands = [
		...recipe
			.join('\n')
			.matchAll(
				/^\s*\$catalogJson = & (python) -c '([^'\r\n]+)' "\$env:GITHUB_WORKSPACE\\([^"\r\n]+)"\s*$/gm
			)
	];
	assert.ok(commands.length === 1, 'the native log catalogue reader must have one actual owner');
	const [, program, script, relative] = commands[0];
	const segments = relative.split('\\');
	assert.ok(
		segments.every(
			(segment) => segment !== '' && segment !== '.' && segment !== '..' && !/[/:]/.test(segment)
		),
		'the native log catalogue reader must stay inside its repository'
	);
	const result = execute(program, ['-c', script, path.join(root, ...segments)], {
		encoding: 'utf8',
		timeout: 5000,
		maxBuffer: 65536,
		windowsHide: true
	});
	assert.ok(
		result && !result.error && result.status === 0,
		'the actual native log catalogue reader refused'
	);
	assert.ok(
		result.stderr === '' && typeof result.stdout === 'string',
		'the actual native log catalogue reader returned an invalid stream'
	);
	let catalog;
	try {
		catalog = JSON.parse(result.stdout);
	} catch {
		throw new Error('the actual native log catalogue reader returned invalid JSON');
	}
	assert.ok(
		catalog &&
			typeof catalog === 'object' &&
			!Array.isArray(catalog) &&
			Object.keys(catalog).sort().join('|') === 'base|extension|prefix|segments',
		'the actual native log catalogue reader returned an invalid schema'
	);
	assert.ok(
		['base', 'prefix', 'extension'].every(
			(key) => typeof catalog[key] === 'string' && catalog[key] !== ''
		) &&
			Array.isArray(catalog.segments) &&
			catalog.segments.length > 0 &&
			catalog.segments.every(
				(segment) =>
					typeof segment === 'string' &&
					segment !== '' &&
					segment !== '.' &&
					segment !== '..' &&
					!/[\\/:]/.test(segment)
			),
		'the actual native log catalogue reader returned invalid fields'
	);
	return catalog;
}

module.exports = function checkWindowsStartupLogRuntime() {
	if (process.platform !== 'win32') {
		console.log('[SKIP] Native startup log-root observations require Windows.');
		return;
	}
	const recipe = pipeline.runOf(
		pipeline.step(
			pipeline.job('launch-windows'),
			'Smoke test compiled ErgoptiPlus.exe (crash-on-launch guard)'
		)
	);
	const functions = [
		'function Format-StartupEvidenceText',
		'function Write-StartupOwnershipEvidence'
	]
		.map((name) => pipeline.scriptBlock(recipe, name).join('\n'))
		.join('\n');
	const initialization = pipeline.scriptBlock(recipe, '$startupEvidence = [ordered]@{').join('\n');
	const catalog = readStartupLogCatalog(recipe);
	const relative = catalog.segments;
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-startup-log-roots-'));
	const quote = (value) => "'" + value.replaceAll("'", "''") + "'";
	const logs = (root) => path.join(root, ...relative);
	try {
		for (const smoke of [true, false]) {
			for (const present of [true, false]) {
				const scenario = path.join(
					temporary,
					`${smoke ? 'smoke' : 'normal'}-${present ? 'present' : 'absent'}`
				);
				const smokeRoot = path.join(scenario, 'private-smoke');
				const defaultRoot = path.join(scenario, 'private-local-app-data');
				const selected = smoke ? smokeRoot : defaultRoot;
				const foreign = smoke ? defaultRoot : smokeRoot;
				fs.mkdirSync(logs(selected), { recursive: true });
				fs.mkdirSync(logs(foreign), { recursive: true });
				const marker = 'owned Unicode log: café / 中文 / 😀\n';
				const bytes = Buffer.from('q'.repeat(5000) + marker, 'utf8');
				fs.writeFileSync(
					path.join(logs(foreign), 'bootstrap.log'),
					'FOREIGN ROOT MUST NOT BE READ\n'
				);
				if (present) fs.writeFileSync(path.join(logs(selected), 'bootstrap.log'), bytes);
				const observer = path.join(scenario, 'observe.ps1');
				// The observer's JSON pipe must carry UTF-8 independently from the desktop code page.
				fs.writeFileSync(
					observer,
					"$ErrorActionPreference = 'Stop'\n[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)\n" +
						functions +
						'\n' +
						'$proc = [Diagnostics.Process]::GetCurrentProcess()\n' +
						'$exe = $proc.MainModule.FileName\n' +
						initialization +
						'\n' +
						'$launchOwner = [ordered]@{ pid = $proc.Id; expected_executable = $proc.MainModule.FileName; observed_executable = $proc.MainModule.FileName; start_utc = $proc.StartTime.ToUniversalTime(); identity_qualified = $true; identity_error = $null }\n' +
						'$name = ' +
						quote(catalog.prefix) +
						" + (Get-Date -Format 'yyyy-MM-dd') + " +
						quote(catalog.extension) +
						'\n' +
						'$foreign = Join-Path ' +
						quote(logs(foreign)) +
						' $name\n' +
						"[IO.File]::WriteAllText($foreign, 'FOREIGN ROOT MUST NOT BE READ', [Text.UTF8Encoding]::new($false))\n" +
						(present
							? '[IO.File]::WriteAllBytes((Join-Path ' +
								quote(logs(selected)) +
								' $name), [Convert]::FromBase64String(' +
								quote(bytes.toString('base64')) +
								'))\n'
							: '') +
						'Write-StartupOwnershipEvidence $proc\n'
				);
				const result = spawnSync('pwsh.exe', ['-NoProfile', '-NonInteractive', '-File', observer], {
					cwd: pipeline.ROOT,
					encoding: 'utf8',
					windowsHide: true,
					timeout: 30000,
					env: {
						...process.env,
						GITHUB_WORKSPACE: pipeline.ROOT,
						[catalog.base]: defaultRoot,
						ERGOPTI_STARTUP_SMOKE_DIR: smoke ? smokeRoot : ''
					}
				});
				assert.ifError(result.error);
				assert.equal(result.status, 0, result.stdout + result.stderr);
				const observations = result.stdout
					.split(/\r?\n/)
					.filter((line) => line.startsWith('{'))
					.map((line) => JSON.parse(line))
					.filter((row) => Object.hasOwn(row, 'log'));
				assert.equal(
					observations.length,
					2,
					"the actual collector must observe bootstrap and today's catalogue log"
				);
				assert.equal(observations.filter((row) => row.log === 'bootstrap.log').length, 1);
				assert.equal(
					observations.filter(
						(row) => row.log.startsWith(catalog.prefix) && row.log.endsWith(catalog.extension)
					).length,
					1
				);
				for (const row of observations) {
					assert.equal(
						row.status,
						present ? 'observed' : 'unavailable',
						'the collector must select the actual ' +
							(smoke ? 'smoke' : 'normal') +
							' root: ' +
							JSON.stringify(row)
					);
					if (present) {
						assert.equal(
							row.size_bytes,
							bytes.length,
							'the selected ' + (smoke ? 'smoke' : 'normal') + ' root holds the owned fixture bytes'
						);
						assert.equal(row.read_bytes, 4096);
						assert.equal(row.truncated, true);
						assert.equal(row.tail, bytes.subarray(bytes.length - 4096).toString('utf8'));
						assert.ok(row.tail.endsWith(marker), 'actual UTF-8 log bytes must remain observable');
					} else {
						assert.equal(typeof row.cause, 'string');
						assert.ok(row.cause.length > 0);
						assert.equal(
							Object.hasOwn(row, 'tail'),
							false,
							'an absent log must not acquire invented bytes'
						);
					}
				}
				console.log(
					'[OK] Native startup logs select ' +
						(smoke ? 'smoke' : 'normal') +
						' root with ' +
						(present ? 'real bounded UTF-8 files.' : 'explicit absence.')
				);
			}
		}
	} finally {
		assert.equal(path.dirname(path.resolve(temporary)), path.resolve(os.tmpdir()));
		assert.ok(path.basename(temporary).startsWith('ergopti-startup-log-roots-'));
		fs.rmSync(temporary, {
			recursive: true,
			force: true,
			maxRetries: 10,
			retryDelay: 100
		});
	}
};

module.exports.readStartupLogCatalog = readStartupLogCatalog;
