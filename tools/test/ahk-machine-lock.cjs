// tools/test/ahk-machine-lock.cjs
'use strict';

/**
 * Keeps two AHK suite runners off one machine. The clipboard, the focus and
 * injected input are not separated by a checkout, so an exclusive phase is only
 * exclusive when no other runner is alive, whichever worktree it started from.
 *
 * The lock is a Windows named pipe rather than a file. The pipe namespace is
 * machine-wide and owns no file in a checkout or a user's TEMP, a second listener
 * is refused atomically, and the kernel frees the name when the holder dies: a
 * killed runner leaves no stale lock to judge, so no PID-reuse or reclaim race
 * exists. A client that connects reads who holds it.
 *
 * Only the runner is the holder: if it is killed outright its AutoHotkey workers
 * can outlive it for a moment, and those are not covered.
 */

const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const DEFAULT_LOCK_NAME = 'ergopti-ahk-parallel';
const HOLDER_READ_TIMEOUT_MS = 2000;
const WAIT_POLL_MS = 5000;

/**
 * Resolves a lock name to its listening address.
 * @param {string} name Lock name.
 * @returns {string} A pipe path on Windows, a socket path elsewhere (self-tests only).
 */
function lockAddress(name) {
	return process.platform === 'win32'
		? `\\\\.\\pipe\\${name}`
		: path.join(os.tmpdir(), `${name}.sock`);
}

/**
 * Takes the lock if it is free.
 * @param {string} name Lock name.
 * @param {object} holder JSON description served to whoever is refused.
 * @returns {Promise<net.Server|null>} The holding server, or null when already held.
 */
function tryAcquire(name, holder) {
	return new Promise((resolve, reject) => {
		const payload = JSON.stringify(holder);
		const server = net.createServer((socket) => {
			socket.on('error', () => socket.destroy());
			socket.end(payload);
		});
		server.once('error', (error) => {
			if (error.code === 'EADDRINUSE') resolve(null);
			else reject(error);
		});
		server.listen(lockAddress(name), () => resolve(server));
	});
}

/**
 * Asks the current holder who it is.
 * @param {string} name Lock name.
 * @returns {Promise<object|null>} Its description; null when it left or would not answer.
 */
function readHolder(name) {
	return new Promise((resolve) => {
		let text = '';
		const socket = net.connect(lockAddress(name));
		const settle = (value) => {
			socket.destroy();
			resolve(value);
		};
		socket.setTimeout(HOLDER_READ_TIMEOUT_MS, () => settle(null));
		socket.on('data', (chunk) => {
			text += chunk;
		});
		socket.on('error', () => settle(null));
		socket.on('end', () => {
			try {
				settle(JSON.parse(text));
			} catch {
				settle(null);
			}
		});
	});
}

function describeHolder(holder) {
	if (!holder) return 'another runner (it did not say which)';
	return `PID ${holder.pid} in ${holder.checkout} at ${holder.commit}, since ${holder.started}${holder.only ? `, --only="${holder.only}"` : ''}`;
}

/**
 * Takes the lock, or refuses with who holds it.
 * @param {object} holder JSON description of this runner.
 * @param {{name?: string, waitMinutes?: number, pollMs?: number, log?: function}} [options]
 *   waitMinutes 0 refuses at once; a positive value waits that long, then refuses.
 * @returns {Promise<net.Server>} The holding server; closing it, or dying, releases the lock.
 */
async function acquireMachineLock(holder, options = {}) {
	const {
		name = DEFAULT_LOCK_NAME,
		waitMinutes = 0,
		pollMs = WAIT_POLL_MS,
		log = console.log
	} = options;
	const deadline = Date.now() + waitMinutes * 60000;
	let announced = false;
	for (;;) {
		const server = await tryAcquire(name, holder);
		if (server) return server;
		const description = describeHolder(await readHolder(name));
		if (Date.now() >= deadline)
			throw new Error(
				`Another AHK runner holds this machine: ${description}. Two runners would share the clipboard, the focus and injected input. ` +
					(waitMinutes > 0
						? `Gave up after ${waitMinutes} minute(s).`
						: 'Wait for it to end, or pass --wait to queue behind it.')
			);
		if (!announced) log(`Waiting for the machine lock, held by ${description}.`);
		announced = true;
		await new Promise((resolve) => setTimeout(resolve, pollMs));
	}
}

module.exports = { DEFAULT_LOCK_NAME, acquireMachineLock, readHolder };
