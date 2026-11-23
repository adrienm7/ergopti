// tools/ci/github-api-read.cjs

/**
 * One authenticated GitHub API read for the CI scripts, repeated only after a
 * server error. The dev run of 2026-11-23 (45271461283) passed every test lane
 * and lost its verdict, and so its prerelease, to one HTTP 502 on a job listing
 * page: a 5xx is transient, any other refusal is final.
 */
'use strict';

const { execFileSync } = require('node:child_process');

const SERVER_RETRY_DELAYS_MS = [5000, 15000, 30000];

/**
 * Runs one GitHub read, repeating it only after a server error.
 * @param {() => string} read The read; it throws with gh's stderr on failure.
 * @param {number[]} delays Pauses before each repeat, in milliseconds.
 * @returns {string} The read's output.
 */
function readWithServerRetry(read, delays = SERVER_RETRY_DELAYS_MS) {
	for (let attempt = 0; ; attempt += 1) {
		try {
			return read();
		} catch (error) {
			const detail = String(error.stderr || error.message);
			if (!/HTTP 5\d\d/.test(detail) || attempt >= delays.length) throw error;
			console.error(
				`GitHub server error, read repeated in ${delays[attempt] / 1000} s: ${detail.trim()}`
			);
			Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, delays[attempt]);
		}
	}
}

/**
 * Reads one GitHub API endpoint through the authenticated `gh`.
 * @param {string} endpoint API path.
 * @param {number} maxBuffer Largest accepted answer, in bytes.
 * @returns {object} The parsed answer.
 */
function readGitHubApi(endpoint, maxBuffer = 4 * 1024 * 1024) {
	return JSON.parse(
		readWithServerRetry(() =>
			execFileSync('gh', ['api', endpoint], {
				encoding: 'utf8',
				maxBuffer,
				stdio: ['ignore', 'pipe', 'pipe']
			})
		)
	);
}

module.exports = { readWithServerRetry, readGitHubApi };
