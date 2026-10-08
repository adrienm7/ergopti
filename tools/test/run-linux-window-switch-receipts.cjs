// tools/test/run-linux-window-switch-receipts.cjs

/**
 * ==============================================================================
 * MODULE: Native Linux Cursor Display Window Receipt Gate
 * DESCRIPTION:
 * Requires exact-family kernel retirement receipts across deadlines and signals.
 * Owned Xvfb/Openbox qualifies virtual displays, focus and actual scoped routing.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const qualification = require('../ci/dev-release-qualification.cjs');

const ROOT = path.resolve(__dirname, '../..');
const DRIVER = path.join(ROOT, 'static/ergopti_plus/linux');
const LUA_PATH = './?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;';
const UNRESOLVED = new Map();
const FIXTURES = [
	{ args: ['tests/hardware/run_native_fixture_family_receipts.py'], timeout: 30 },
	{ args: ['tests/hardware/run_window_switch_receipts.py', '--require-routing'], timeout: 160 }
];

/** Runs native receipts, retaining the owner until EOF and process close. */
async function run({
	platform = process.platform,
	spawnChild = spawn,
	signals = process,
	fixtures = FIXTURES,
	debts = UNRESOLVED,
	log = console.log,
	error = console.error,
	qualificationContext = qualification.environmentContext(),
	qualificationNow = new Date(),
	recordQualification = (receipt) => {
		const fs = require('node:fs');
		if (!process.env.RUNNER_TEMP) throw new Error('Qualification receipt owner unavailable.');
		fs.writeFileSync(
			path.join(process.env.RUNNER_TEMP, 'linux-window-qualification.json'),
			JSON.stringify(receipt, null, 2) + '\n'
		);
	}
} = {}) {
	if (platform !== 'linux') {
		log(
			'[DEFERRED] Native cursor-display window receipts require Linux; mandatory CI runs the owned Xvfb/Openbox fixture.'
		);
		return 0;
	}
	if (debts.size) {
		error(
			'[BLOCKED] Earlier native supervisor loss has unresolved descendant debt; external ownership proof is required.'
		);
		return 1;
	}
	const profile = qualification.resolveQualificationProfile(qualificationContext, qualificationNow);
	if (profile) {
		const scope = profile.scopes['linux-window-receipts'];
		if (
			fixtures.filter(
				(fixture) => JSON.stringify(fixture.args) === JSON.stringify([scope.path, ...scope.args])
			).length !== 1
		)
			throw new Error('Qualification fixture must match the complete registry exactly once.');
	}
	const env = { ...process.env, LUA_PATH };
	if (env.ERGOPTI_NATIVE_LUA_CPATH) env.LUA_CPATH = env.ERGOPTI_NATIVE_LUA_CPATH;
	let cancellation = null;
	let active = null;
	function forward(entry) {
		if (
			!entry.ready ||
			entry.nativeClosed ||
			entry.signalAccepted ||
			entry.settled ||
			!cancellation
		)
			return;
		try {
			const accepted = entry.child.kill(cancellation) === true;
			entry.signalDebt = accepted ? null : 'native-signal-refused';
			if (accepted) entry.signalAccepted = true;
		} catch {
			entry.signalDebt = 'native-signal-refused';
		}
	}
	function cancel(kind) {
		cancellation ||= kind;
		if (active) forward(active);
	}
	const handlers = new Map(['SIGINT', 'SIGTERM'].map((kind) => [kind, () => cancel(kind)]));
	for (const [kind, handler] of handlers) signals.on(kind, handler);
	try {
		for (const fixture of fixtures) {
			if (cancellation) return cancellation === 'SIGINT' ? 130 : 143;
			if (profile) {
				const scope = profile.scopes['linux-window-receipts'];
				if (JSON.stringify(fixture.args) === JSON.stringify([scope.path, ...scope.args])) {
					const receipt = qualification.qualificationReceipt(profile, 'linux-window-receipts', {
						source_sha: process.env.GITHUB_SHA
					});
					recordQualification(receipt);
					log(
						'[DEFERRED] linux-window-receipts: ' + scope.reason + ' Native/feature qualified=false.'
					);
					continue;
				}
			}
			const result = await new Promise((resolve) => {
				const token = crypto.randomBytes(16).toString('hex');
				let child;
				try {
					child = spawnChild(
						'python3',
						[
							'tests/hardware/native_fixture_family.py',
							'--timeout',
							String(fixture.timeout),
							'--receipt-fd',
							'3',
							'--token',
							token,
							'--',
							'python3',
							...fixture.args
						],
						{ cwd: DRIVER, stdio: ['ignore', 'inherit', 'inherit', 'pipe'], env }
					);
				} catch (failure) {
					error(`[FAIL] Native fixture launch refused: ${failure.message}`);
					resolve(1);
					return;
				}
				const entry = {
					child,
					ready: false,
					nativeClosed: false,
					signalDebt: null,
					signalAccepted: false,
					settled: false
				};
				active = entry;
				let refused = false;
				let buffer = '',
					bytes = 0,
					terminal = null,
					eof = false,
					fault = false;
				const deadline = setTimeout(() => cancel('SIGTERM'), (fixture.timeout + 15) * 1000);
				const retry = setInterval(() => {
					if (active === entry) forward(entry);
				}, 25);
				const receipt = child.stdio?.[3];
				if (!receipt) fault = true;
				receipt?.on('data', (data) => {
					bytes += data.length;
					if (bytes > 4096) {
						fault = true;
						cancel('SIGTERM');
						return;
					}
					buffer += data.toString('utf8');
					while (buffer.includes('\n')) {
						const end = buffer.indexOf('\n');
						const line = buffer.slice(0, end);
						buffer = buffer.slice(end + 1);
						try {
							const frame = JSON.parse(line);
							if (frame.version !== 1 || frame.token !== token || frame.supervisor !== child.pid)
								throw new Error('foreign receipt');
							if (
								frame.stage === 'refused' &&
								!entry.ready &&
								!terminal &&
								frame.status === 1 &&
								frame.acquired === 0 &&
								frame.reaped === 0 &&
								frame.closed === 0 &&
								frame.namespace_absent === true
							) {
								refused = true;
								terminal = frame;
							} else if (frame.stage === 'ready' && !entry.ready && !terminal) {
								entry.ready = true;
								if (cancellation) forward(entry);
							} else if (frame.stage === 'settled' && entry.ready && !terminal) {
								for (const key of ['status', 'acquired', 'reaped', 'closed'])
									if (!Number.isInteger(frame[key]) || frame[key] < 0)
										throw new Error('invalid numeric receipt');
								if (
									frame.namespace_absent !== true ||
									frame.acquired !== frame.reaped ||
									frame.acquired !== frame.closed
								)
									throw new Error('physical debt');
								terminal = frame;
								entry.settled = true;
							} else throw new Error('invalid receipt order');
						} catch {
							fault = true;
							cancel('SIGTERM');
						}
					}
				});
				receipt?.on('end', () => {
					eof = true;
				});
				receipt?.on('error', () => {
					fault = true;
					cancel('SIGTERM');
				});
				child.on('error', (failure) => {
					fault = true;
					error(`[FAIL] Native fixture could not run: ${failure.message}`);
				});
				child.on('close', (status, signal) => {
					clearTimeout(deadline);
					clearInterval(retry);
					entry.nativeClosed = true;
					if (fault || !eof || buffer || !terminal || signal || terminal.status !== status) {
						// A dead supervisor is no longer usable process authority. Retain
						// its unresolved external boundary; do not describe it as settled
						// or admit another native run in this owner scope.
						debts.set(token, {
							supervisor: child.pid,
							positiveAdmission: entry.ready,
							reason: 'native-supervisor-authority-lost'
						});
						error(
							'[BLOCKED] Native supervisor authority lost before physical settlement; exact descendant recovery requires an external owner.'
						);
						resolve(1);
					} else {
						if (active === entry) active = null;
						if (refused)
							error(
								'[BLOCKED] Native supervisor prerequisite refused before child or namespace allocation.'
							);
						resolve(status);
					}
				});
			});
			if (result !== 0) return result;
		}
		if (profile)
			log(
				'[DEFERRED] X11 routing and input focus remain unqualified; native family and external recovery entries completed.'
			);
		else log('[OK] Actual virtual X11 routing, input focus and owned settlement passed.');
		return 0;
	} finally {
		for (const [kind, handler] of handlers) signals.removeListener(kind, handler);
	}
}

if (require.main === module)
	run().then(
		(status) => {
			process.exitCode = status;
		},
		() => {
			process.exitCode = 1;
		}
	);
module.exports = {
	run,
	unresolvedDebt: () => [...UNRESOLVED.values()].map((entry) => ({ ...entry }))
};
