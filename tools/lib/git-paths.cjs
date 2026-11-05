// tools/lib/git-paths.cjs

/**
 * ==============================================================================
 * MODULE: Git Path Inventory Reader
 * DESCRIPTION:
 * Reads complete NUL-delimited Git inventories without child_process's stdout
 * capture ceiling. Git streams into a private file; bounded reads decode every
 * path after the process has succeeded. Stderr remains bounded and any process
 * or framing failure refuses the inventory instead of accepting a prefix.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { StringDecoder } = require('node:string_decoder');

const CHUNK_BYTES = 65536;
const STDERR_BYTES = 65536;

/**
 * Returns exact Git path records, preserving whitespace and native Git ordering.
 * @param {string} root Repository or private candidate working directory.
 * @param {string[]} args Git arguments requesting NUL-delimited path output.
 * @param {{env?: NodeJS.ProcessEnv, temporaryRoot?: string}} options Native Git
 * environment and optional parent directory for the owned temporary capture.
 * @returns {string[]} Complete paths; no inventory is returned after refusal.
 */
function gitPaths(root, args, options = {}) {
	if (!Array.isArray(args) || !args.includes('-z'))
		throw new TypeError('Git path inventories require explicit NUL-delimited output.');
	const directory = fs.mkdtempSync(
		path.join(options.temporaryRoot || os.tmpdir(), 'ergopti-git-paths-')
	);
	let descriptor;
	try {
		descriptor = fs.openSync(path.join(directory, 'stdout'), 'wx+', 0o600);
		const result = spawnSync('git', args, {
			cwd: root,
			env: options.env,
			stdio: ['ignore', descriptor, 'pipe'],
			encoding: 'utf8',
			maxBuffer: STDERR_BYTES,
			windowsHide: true
		});
		if (result.error)
			throw new Error(`Git path inventory could not run: ${result.error.message}`, {
				cause: result.error
			});
		if (result.signal || result.status !== 0)
			throw new Error(
				`Git path inventory refused (status=${result.status}, signal=${result.signal}): ` +
					(result.stderr || '').trim()
			);
		const paths = [];
		const decoder = new StringDecoder('utf8');
		const buffer = Buffer.alloc(CHUNK_BYTES);
		let position = 0;
		let pending = '';
		let count;
		while ((count = fs.readSync(descriptor, buffer, 0, buffer.length, position)) !== 0) {
			position += count;
			const records = (pending + decoder.write(buffer.subarray(0, count))).split('\0');
			pending = records.pop();
			for (const record of records) if (record !== '') paths.push(record);
		}
		if (pending + decoder.end() !== '')
			throw new Error('Git path inventory ended without its final NUL delimiter.');
		return paths;
	} finally {
		try {
			if (descriptor !== undefined) fs.closeSync(descriptor);
		} finally {
			fs.rmSync(directory, { recursive: true, force: true });
		}
	}
}

module.exports = { gitPaths };
