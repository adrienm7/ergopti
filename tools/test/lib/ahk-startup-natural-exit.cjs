// tools/test/lib/ahk-startup-natural-exit.cjs

/** Retains an exact launched source process through cooperative natural shutdown. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

/**
 * Waits for actual native close; an expired budget publishes cancellation only.
 * No live child is killed, detached, or treated as retired by a timer.
 */
async function launchNaturalExit(spawnPort, binary, args, options, budgetMs) {
	if (typeof spawnPort !== 'function' || !Number.isSafeInteger(budgetMs) || budgetMs <= 0)
		throw new TypeError('Natural startup launch requires a callable port and positive budget.');
	const directory = options.env.ERGOPTI_STARTUP_SMOKE_DIR;
	const nonce = options.env.ERGOPTI_STARTUP_SMOKE_NONCE;
	if (!directory || !/^[0-9a-f]{32}$/.test(nonce))
		throw new TypeError('Natural startup launch requires an exclusive directory and nonce.');
	const child = spawnPort(binary, args, { ...options, windowsHide: true });
	let stdout = '',
		stderr = '',
		launchError = null,
		stopError = null,
		budgetExpired = false;
	child.stdout.setEncoding('utf8');
	child.stderr.setEncoding('utf8');
	child.stdout.on('data', (data) => {
		stdout += data;
	});
	child.stderr.on('data', (data) => {
		stderr += data;
	});
	const timer = setTimeout(() => {
		budgetExpired = true;
		try {
			fs.writeFileSync(path.join(directory, 'stop.request'), nonce, { flag: 'wx' });
		} catch (error) {
			stopError = error;
		}
		console.error('Natural startup shutdown budget expired; exact child retained: ' + child.pid);
	}, budgetMs);
	try {
		return await new Promise((resolve, reject) => {
			child.once('error', (error) => {
				launchError = error;
			});
			child.once('close', (status, signal) => {
				try {
					fs.writeFileSync(path.join(directory, 'natural.stdout.log'), stdout, { flag: 'wx' });
					fs.writeFileSync(path.join(directory, 'natural.stderr.log'), stderr, { flag: 'wx' });
					resolve({
						pid: child.pid,
						status,
						signal,
						stdout,
						stderr,
						error: launchError || stopError,
						budgetExpired
					});
				} catch (error) {
					reject(error);
				}
			});
		});
	} finally {
		clearTimeout(timer);
	}
}

/** Requires acknowledgment from this exact ready process and its natural status. */
function naturalExitReceiptProblem(configRoot, result, nonce) {
	if (result.error || result.budgetExpired || result.status !== 0 || result.signal || result.stderr)
		return 'natural shutdown did not retire normally within its cooperative budget';
	const receiptFile = path.join(configRoot, 'natural-exit.json');
	if (!fs.existsSync(receiptFile))
		return 'the driver published no accepted natural shutdown acknowledgment';
	let receipt;
	try {
		receipt = JSON.parse(fs.readFileSync(receiptFile, 'utf8').replace(/^\uFEFF/, ''));
	} catch (error) {
		return 'the natural shutdown acknowledgment cannot be read: ' + error.message;
	}
	if (
		!receipt ||
		typeof receipt !== 'object' ||
		Array.isArray(receipt) ||
		Object.keys(receipt).sort().join('|') !==
			[
				'schema_version',
				'nonce',
				'pid',
				'reason',
				'code',
				'accepted',
				'logs_flushed',
				'veto_exhausted'
			]
				.sort()
				.join('|') ||
		receipt.schema_version !== 1 ||
		!/^[0-9a-f]{32}$/.test(nonce) ||
		receipt.nonce !== nonce ||
		!Number.isSafeInteger(result.pid) ||
		result.pid <= 0 ||
		receipt.pid !== result.pid ||
		receipt.reason !== 'Exit' ||
		receipt.code !== 0 ||
		receipt.accepted !== true ||
		receipt.logs_flushed !== true ||
		receipt.veto_exhausted !== false
	)
		return 'the natural shutdown acknowledgment is foreign or incomplete';
	return null;
}

module.exports = { launchNaturalExit, naturalExitReceiptProblem };
