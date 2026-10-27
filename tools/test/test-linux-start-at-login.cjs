// tools/test/test-linux-start-at-login.cjs

/**
 * ==============================================================================
 * MODULE: Linux Login Startup Regression
 * DESCRIPTION:
 * Exercises real startup helper files in a temporary installation with an inert
 * systemctl. No desktop setting or service outside the sandbox is changed.
 * ==============================================================================
 */

'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { createHash } = require('node:crypto');
const { bashExecutable } = require('../lib/git-bash.cjs');

const root = path.resolve(__dirname, '../..');
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-login-startup-'));
let stagingRoot;
const posix = (value) =>
	process.platform === 'win32'
		? value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`)
		: value;
try {
	const installed = path.join(sandbox, "a space d'été Ω", 'lib/ergopti/linux/install');
	const stubs = path.join(sandbox, 'stubs');
	const config = path.join(sandbox, 'config');
	const calls = path.join(sandbox, 'calls');
	fs.mkdirSync(installed, { recursive: true });
	fs.mkdirSync(stubs);
	const script = path.join(installed, 'start_at_login.sh');
	fs.copyFileSync(path.join(root, 'static/ergopti_plus/linux/install/start_at_login.sh'), script);
	for (const helper of ['desktop_entry.sh', 'config_home.sh']) {
		fs.copyFileSync(
			path.join(root, 'static/ergopti_plus/linux/install', helper),
			path.join(installed, helper)
		);
	}
	// Git Bash cannot reliably chmod NTFS directories; permission semantics are
	// exercised by the unchanged helper on Linux CI.
	if (process.platform === 'win32') {
		fs.writeFileSync(
			path.join(stubs, 'install'),
			'#!/bin/bash\n[ "$1" = -d ] && [ "$2" = -m ] || exit 1\nshift 3\nmkdir -p -- "$@"\n',
			{ mode: 0o755 }
		);
	}
	fs.writeFileSync(
		path.join(stubs, 'systemctl'),
		[
			'#!/bin/bash',
			'printf "%s\\n" "$*" >> "$CALL_LOG"',
			'if [ "$2" = is-enabled ]; then exit 1; fi',
			'if [ "$4" = list-unit-files ]; then',
			'  [ "${QUERY_REFUSE:-0}" != 1 ] || exit 23',
			'  if [ "${NO_UNIT:-0}" = 1 ]; then',
			'    [ "$#" -eq 4 ] || exit 1',
			'    printf "%s\\n" "fooergopti-hotstrings.service disabled enabled" "ergopti-hotstrings.service.other disabled enabled"',
			'  else echo "ergopti-hotstrings.service disabled enabled"; fi',
			'  exit 0',
			'fi',
			'[ "${NO_UNIT:-0}" != 1 ] && [ "${REFUSE:-0}" != 1 ]',
			''
		].join('\n'),
		{ mode: 0o755 }
	);
	const env = {
		...process.env,
		HOME: posix(sandbox),
		XDG_CONFIG_HOME: posix(config),
		CALL_LOG: posix(calls),
		TEST_STUBS: posix(stubs)
	};
	const run = (action, extra = {}, cwd = sandbox) =>
		spawnSync(
			bashExecutable(),
			[
				'-c',
				'export PATH="$TEST_STUBS:/usr/bin:/bin"; exec bash "$1" "$2"',
				'startup-test',
				posix(script),
				action
			],
			{ encoding: 'utf8', timeout: 10000, cwd, env: { ...env, ...extra } }
		);
	let result = run('status');
	assert.equal(result.status, 0, result.stderr);
	assert.equal(result.stdout.trim(), 'disabled');
	assert.ok(!fs.existsSync(config), 'reading state creates no startup files');
	result = run('enable');
	assert.equal(result.status, 0, result.stderr);
	const desktop = path.join(config, 'autostart/ergopti-hotstrings.desktop');
	assert.match(
		fs.readFileSync(desktop, 'utf8'),
		/^Exec=\/bin\/bash ".*a space.*" --session-start --tray$/m
	);
	assert.equal(run('status').stdout.trim(), 'enabled');
	assert.equal(run('disable').status, 0);
	assert.equal(run('status').stdout.trim(), 'disabled');
	assert.match(fs.readFileSync(desktop, 'utf8'), /^Hidden=true$/m);
	assert.doesNotMatch(
		fs.readFileSync(calls, 'utf8'),
		/--now|restart|stop|start\b/,
		'future sessions only'
	);
	const disabled = fs.readFileSync(desktop, 'utf8');
	assert.notEqual(run('enable', { REFUSE: '1' }).status, 0);
	assert.equal(
		fs.readFileSync(desktop, 'utf8'),
		disabled,
		'failed service mutation cannot publish a false enabled state'
	);
	assert.notEqual(run('enable', { QUERY_REFUSE: '1' }).status, 0);
	assert.equal(
		fs.readFileSync(desktop, 'utf8'),
		disabled,
		'a failed metadata query cannot publish a false enabled state'
	);
	const beforeMissing = fs.readFileSync(calls, 'utf8').length;
	assert.equal(
		run('enable', { NO_UNIT: '1' }).status,
		0,
		'an installation without a service can use XDG startup'
	);
	assert.equal(run('status').stdout.trim(), 'enabled');
	assert.doesNotMatch(
		fs.readFileSync(calls, 'utf8').slice(beforeMissing),
		/--no-reload disable/,
		'nearby unit names cannot grant authority to disable the exact service'
	);
	assert.equal(run('disable', { NO_UNIT: '1' }).status, 0);
	assert.equal(run('status').stdout.trim(), 'disabled');
	assert.match(fs.readFileSync(desktop, 'utf8'), /^Hidden=true$/m);
	fs.writeFileSync(desktop, '[Desktop Entry]\nExec=/other/program\n');
	assert.equal(
		run('status').stdout.trim(),
		'other',
		'the actual foreign command is read-only conflict evidence'
	);
	assert.notEqual(run('disable').status, 0, 'foreign startup commands are never replaced');
	assert.equal(fs.readFileSync(desktop, 'utf8'), '[Desktop Entry]\nExec=/other/program\n');
	if (process.platform === 'linux') {
		const manifest = path.resolve(installed, '../../.ergopti-owned-files');
		const manifestArgument = path.dirname(installed) + '/../.ergopti-owned-files';
		const receiptTarget = path.join(sandbox, 'unrelated-receipt');
		const receiptBytes = 'Unrelated receipt must remain unchanged.\n';
		fs.writeFileSync(receiptTarget, receiptBytes);
		const quotedEvidencePath = (value) => {
			const result = spawnSync(
				bashExecutable(),
				['-c', 'printf %q "$1"', 'startup-evidence', value],
				{
					encoding: 'utf8'
				}
			);
			assert.equal(result.status, 0, result.stderr);
			return result.stdout;
		};
		const receiptRefusals = [];
		for (const [state, sourceKind] of ['absent', 'disabled'].flatMap((state) =>
			['file-link', 'dangling-link', 'fifo', 'directory'].map((kind) => [state, kind])
		)) {
			fs.rmSync(desktop, { force: true });
			if (state === 'disabled') fs.writeFileSync(desktop, disabled);
			if (sourceKind === 'directory') fs.mkdirSync(manifest);
			else if (sourceKind === 'fifo') {
				const fifo = spawnSync('mkfifo', [manifest], { encoding: 'utf8', timeout: 1000 });
				assert.equal(fifo.status, 0, fifo.stderr);
			} else
				fs.symlinkSync(
					sourceKind === 'file-link' ? receiptTarget : receiptTarget + '.absent',
					manifest
				);
			const receiptNodeBefore = fs.lstatSync(manifest);
			const receiptLinkBefore = receiptNodeBefore.isSymbolicLink()
				? fs.readlinkSync(manifest)
				: null;
			const callsBefore = fs.readFileSync(calls, 'utf8');
			const refused = run('enable');
			const receiptNodeAfter = fs.lstatSync(manifest);
			const receiptLinkAfter = receiptNodeAfter.isSymbolicLink() ? fs.readlinkSync(manifest) : null;
			const nodeUnchanged =
				receiptNodeAfter.dev === receiptNodeBefore.dev &&
				receiptNodeAfter.ino === receiptNodeBefore.ino &&
				(receiptNodeAfter.mode & fs.constants.S_IFMT) ===
					(receiptNodeBefore.mode & fs.constants.S_IFMT) &&
				receiptLinkAfter === receiptLinkBefore;
			const unchanged =
				state === 'absent'
					? !fs.existsSync(desktop)
					: fs.readFileSync(desktop, 'utf8') === disabled;
			if (
				refused.status !== 78 ||
				!unchanged ||
				!nodeUnchanged ||
				!refused.stderr.includes(
					`[startup] code=invalid-source role=receipt path=${quotedEvidencePath(manifestArgument)}\n`
				) ||
				fs.readFileSync(calls, 'utf8') !== callsBefore ||
				fs.readFileSync(receiptTarget, 'utf8') !== receiptBytes
			) {
				receiptRefusals.push({
					state,
					sourceKind,
					status: refused.status,
					unchanged,
					nodeUnchanged,
					stderr: refused.stderr
				});
			}
			if (sourceKind === 'directory') fs.rmdirSync(manifest);
			else fs.unlinkSync(manifest);
		}
		for (const sourceKind of ['fifo', 'directory']) {
			fs.rmSync(desktop, { force: true });
			if (sourceKind === 'directory') fs.mkdirSync(desktop);
			else {
				const fifo = spawnSync('mkfifo', [desktop], { encoding: 'utf8', timeout: 1000 });
				assert.equal(fifo.status, 0, fifo.stderr);
			}
			const callsBefore = fs.readFileSync(calls, 'utf8');
			const refused = run('enable');
			const kept = fs.lstatSync(desktop);
			if (
				refused.status !== 78 ||
				!refused.stderr.includes(
					`[startup] code=invalid-source role=desktop path=${quotedEvidencePath(desktop)}\n`
				) ||
				fs.readFileSync(calls, 'utf8') !== callsBefore ||
				(sourceKind === 'fifo'
					? !kept.isFIFO()
					: !kept.isDirectory() || fs.readdirSync(desktop).length !== 0)
			) {
				receiptRefusals.push({ sourceKind, role: 'desktop', status: refused.status });
			}
			fs.rmSync(desktop, { recursive: true, force: true });
		}
		fs.writeFileSync(desktop, disabled);
		const previousReceipt =
			`${'a'.repeat(64)}\tlinux/retained-file\n` +
			`${createHash('sha256').update(disabled).digest('hex')}\t@autostart\n`;
		fs.writeFileSync(manifest, previousReceipt);
		fs.chmodSync(desktop, 0o640);
		fs.chmodSync(manifest, 0o640);
		fs.writeFileSync(
			path.join(stubs, 'mv'),
			[
				'#!/bin/bash',
				'if [ "${REFUSE_RECEIPT_MV:-0}" = 1 ] && [ "${!#}" = "$STARTUP_RECEIPT" ]; then exit 73; fi',
				'if [ "${REFUSE_DESKTOP_MV:-0}" = 1 ] && [ "${!#}" = "$STARTUP_DESKTOP" ]; then exit 74; fi',
				'if [ "${REFUSE_RECEIPT_ROLLBACK:-0}" = 1 ] && [ "${!#}" = "$STARTUP_RECEIPT" ]; then',
				'  case "${3:-}" in *.previous.*) exit 75;; esac',
				'fi',
				'exec /bin/mv "$@"',
				''
			].join('\n'),
			{ mode: 0o755 }
		);
		for (const fault of ['REFUSE_RECEIPT_MV', 'REFUSE_DESKTOP_MV']) {
			const callsBefore = fs.readFileSync(calls, 'utf8');
			const refused = run('enable', {
				[fault]: '1',
				STARTUP_RECEIPT: manifestArgument,
				STARTUP_DESKTOP: desktop
			});
			const unchanged = fs.readFileSync(desktop, 'utf8') === disabled;
			const receiptUnchanged = fs.readFileSync(manifest, 'utf8') === previousReceipt;
			const serviceMutated = /--no-reload disable/.test(
				fs.readFileSync(calls, 'utf8').slice(callsBefore.length)
			);
			if (refused.status === 0 || !unchanged || !receiptUnchanged || serviceMutated) {
				receiptRefusals.push({
					fault,
					status: refused.status,
					unchanged,
					receiptUnchanged,
					serviceMutated
				});
			}
			if (
				(fs.statSync(desktop).mode & 0o777) !== 0o640 ||
				(fs.statSync(manifest).mode & 0o777) !== 0o640
			) {
				receiptRefusals.push({ fault, modePreserved: false });
			}
			fs.writeFileSync(desktop, disabled);
			fs.writeFileSync(manifest, previousReceipt);
			fs.chmodSync(desktop, 0o640);
			fs.chmodSync(manifest, 0o640);
		}
		const refusedService = run('enable', { REFUSE: '1' });
		assert.notEqual(refusedService.status, 0);
		assert.equal(
			fs.readFileSync(desktop, 'utf8'),
			disabled,
			'startup-receipt-service: service refusal restores the previous setting'
		);
		assert.equal(
			fs.readFileSync(manifest, 'utf8'),
			previousReceipt,
			'startup-receipt-service: service refusal restores the previous receipt'
		);
		const refusedRollback = run('enable', {
			REFUSE: '1',
			REFUSE_RECEIPT_ROLLBACK: '1',
			STARTUP_RECEIPT: manifestArgument
		});
		const recovery = fs
			.readdirSync(path.dirname(manifest))
			.filter((name) => name.startsWith(path.basename(manifest) + '.previous.'))
			.map((name) => path.join(path.dirname(manifest), name));
		const recoveryRecordPresent =
			recovery.length === 1 &&
			refusedRollback.stderr.includes(
				`[startup] code=rollback-failed role=recovery path=${quotedEvidencePath(manifestArgument + recovery[0].slice(manifest.length))}\n`
			);
		if (
			refusedRollback.status === 0 ||
			!recoveryRecordPresent ||
			recovery.length !== 1 ||
			fs.readFileSync(recovery[0], 'utf8') !== previousReceipt
		) {
			receiptRefusals.push({
				fault: 'REFUSE_RECEIPT_ROLLBACK',
				status: refusedRollback.status,
				recovery,
				stderr: refusedRollback.stderr
			});
		}
		for (const file of recovery) fs.unlinkSync(file);
		fs.writeFileSync(desktop, disabled);
		fs.writeFileSync(manifest, previousReceipt);
		fs.chmodSync(desktop, 0o640);
		fs.chmodSync(manifest, 0o640);
		const healthy = run('enable');
		assert.equal(healthy.status, 0, healthy.stderr);
		assert.match(fs.readFileSync(desktop, 'utf8'), /^Hidden=false$/m);
		if (
			(fs.statSync(desktop).mode & 0o777) !== 0o640 ||
			(fs.statSync(manifest).mode & 0o777) !== 0o640
		) {
			receiptRefusals.push({ healthyPublication: true, modePreserved: false });
		}
		const currentDigest = createHash('sha256').update(fs.readFileSync(desktop)).digest('hex');
		assert.equal(
			fs.readFileSync(manifest, 'utf8'),
			`${'a'.repeat(64)}\tlinux/retained-file\n${currentDigest}\t@autostart\n`,
			'startup-receipt-healthy: the published receipt owns the exact enabled bytes once'
		);
		fs.unlinkSync(manifest);
		fs.unlinkSync(path.join(stubs, 'mv'));
		fs.writeFileSync(desktop, '[Desktop Entry]\nExec=/other/program\n');
		assert.deepEqual(
			receiptRefusals,
			[],
			'startup-receipt-transaction: refusal preserves startup settings, ownership and service state'
		);
		const disagreements = [];
		for (const [index, value] of [
			'',
			'relative settings',
			'.',
			'../elsewhere',
			'~/settings',
			path.join(sandbox, 'absolute\\settings\n')
		].entries()) {
			const home = path.join(sandbox, `xdg-home-${index}`);
			const cwd = path.join(home, 'cwd');
			fs.mkdirSync(cwd, { recursive: true });
			const variables = { HOME: home, XDG_CONFIG_HOME: value };
			const resolved = spawnSync(
				'lua',
				[
					'-e',
					'package.path="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;"..package.path; io.write(require("infra.config_paths").config_home())'
				],
				{
					cwd: path.join(root, 'static/ergopti_plus/linux'),
					env: { ...process.env, ...variables },
					encoding: 'utf8',
					timeout: 10000
				}
			);
			assert.equal(resolved.status, 0, resolved.stderr || resolved.error?.message);
			assert.equal(
				resolved.stdout,
				path.isAbsolute(value) ? value : path.join(home, '.config'),
				'the observed daemon root must obey the independently stated XDG absolute-base rule'
			);
			const changed = run('enable', variables, cwd);
			assert.equal(changed.status, 0, changed.stderr || changed.error?.message);
			const expectedDesktop = path.join(resolved.stdout, 'autostart/ergopti-hotstrings.desktop');
			if (!fs.existsSync(expectedDesktop))
				disagreements.push(
					`value ${JSON.stringify(value)} was written outside the actual Lua configuration root`
				);
			if (
				value &&
				!path.isAbsolute(value) &&
				fs.existsSync(path.resolve(cwd, value, 'autostart/ergopti-hotstrings.desktop'))
			) {
				disagreements.push(
					`relative value ${JSON.stringify(value)} acquired a cwd-dependent startup entry`
				);
			}
		}
		assert.deepEqual(
			disagreements,
			[],
			'xdg-shell-lua-root: native startup and the daemon use the same XDG rule'
		);

		// Exercise the bundle's tracked copier and real required-file scan.
		// These are presence controls, not native binary qualification.
		stagingRoot = fs.mkdtempSync(path.join(root, '.ergopti-xdg-stage-'));
		const staged = path.join(stagingRoot, 'install');
		const copied = spawnSync(
			process.execPath,
			[
				path.join(root, 'tools/build/copy-tracked-tree.cjs'),
				root,
				path.join(root, 'static/ergopti_plus/linux/install'),
				staged
			],
			{ encoding: 'utf8', timeout: 10000 }
		);
		assert.equal(copied.status, 0, copied.stderr || copied.error?.message);
		assert.deepEqual(
			fs.readFileSync(path.join(staged, 'config_home.sh')),
			fs.readFileSync(path.join(root, 'static/ergopti_plus/linux/install/config_home.sh')),
			'the canonical shell resolver reaches actual tracked staging unchanged'
		);
		const builder = fs.readFileSync(path.join(root, 'tools/build/build-linux-driver.sh'), 'utf8');
		const requiredStart = builder.indexOf('REQUIRED_FILES=(');
		const declarationEnd = builder.indexOf('\nMISSING=0', requiredStart);
		const scanEnd = builder.indexOf('\n# The WebView asset set', declarationEnd);
		assert.ok(
			requiredStart >= 0 && declarationEnd > requiredStart && scanEnd > declarationEnd,
			'the real required-file admission block must be present'
		);
		const declaration = builder.slice(requiredStart, declarationEnd);
		const inventory = spawnSync(bashExecutable(), ['-s'], {
			input: declaration + '\nprintf "%s\\0" "${REQUIRED_FILES[@]}"\n',
			encoding: 'utf8',
			timeout: 10000
		});
		assert.equal(inventory.status, 0, inventory.stderr);
		const required = inventory.stdout.split('\0').filter(Boolean);
		assert.ok(
			required.includes('linux/install/config_home.sh'),
			'the resolver is a required driver runtime input'
		);
		const build = path.join(sandbox, 'required-stage');
		for (const relative of required) {
			const file = path.resolve(build, relative);
			assert.ok(
				file.startsWith(build + path.sep),
				'all presence fixtures stay in the private build tree'
			);
			fs.mkdirSync(path.dirname(file), { recursive: true });
			fs.writeFileSync(file, 'presence fixture');
		}
		const missing = path.join(build, 'linux/install/config_home.sh');
		const admission = () =>
			spawnSync(bashExecutable(), ['-s'], {
				input: builder.slice(requiredStart, scanEnd) + '\ntest "$MISSING" -eq 0\n',
				env: { ...process.env, BUILD_DIR: build },
				encoding: 'utf8',
				timeout: 10000
			});
		fs.unlinkSync(missing);
		const refused = admission();
		assert.notEqual(refused.status, 0, 'missing canonical resolver blocks bundle admission');
		assert.match(refused.stdout, /MISSING: linux\/install\/config_home\.sh/);
		fs.copyFileSync(path.join(staged, 'config_home.sh'), missing);
		const complete = admission();
		assert.equal(complete.status, 0, complete.stdout || complete.stderr);
	}
	console.log(
		'PASS Linux login startup: explicit changes, read-only status, ownership and failure handling'
	);
} finally {
	assert.ok(path.resolve(sandbox).startsWith(path.resolve(os.tmpdir()) + path.sep));
	fs.rmSync(sandbox, { recursive: true, force: true });
	if (stagingRoot) {
		assert.equal(path.dirname(stagingRoot), root);
		fs.rmSync(stagingRoot, { recursive: true, force: true });
	}
}
