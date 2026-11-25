// tools/dev/measure-issue-url-limits.cjs

/**
 * ==============================================================================
 * MODULE: GitHub Issue URL Limit Probe
 * DESCRIPTION:
 * Measures, anonymously, how long a prefilled "new issue" URL github.com still
 * serves, and how long one survives the login redirect a signed-out click goes
 * through (/login?return_to=<the URL encoded again>). The bug link's budget,
 * max_url_bytes of _shared/diagnostics/data/issue_templates.json, is set by
 * that redirect: this probe is the measurement the TODO item « The URL budget
 * stays 4,000 bytes » asks for before the budget is counted on the re-encoded
 * length in the three issue_link ports.
 *
 * FEATURES & RATIONALE:
 * 1. Two value shapes bound the cost of a report: letters, which the redirect
 *    copies as they are, and spaces, which cost 3 bytes (%20) and 5 once
 *    encoded again (%2520).
 * 2. Synthetic values only and no cookie: nothing of the machine, its account
 *    or a report leaves it, and the answers are those of a signed-out click.
 * 3. A host whose HTTPS goes through an authenticating proxy (a cloud agent
 *    container) cannot measure a signed-out click; run it on a direct
 *    connection.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { hosts } = require('../lib/identifiers.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
// The repository the bug link opens, from its single source
const DEFAULTS = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'updater', 'data', 'defaults.json'),
		'utf8'
	)
);
const DEFAULT_REPOSITORY = `${DEFAULTS.github.owner}/${DEFAULTS.github.repo}`;
const DEFAULT_LENGTHS = [3000, 4000, 5000, 6000, 6500, 7000, 7500, 8200];
const SHAPES = { letters: 'a', spaces: ' ' };
const TIMEOUT_MS = 20000;

/**
 * Parses --repo=owner/name and --lengths=3000,4000 from the command line.
 * @param {string[]} argv
 * @returns {{ repository: string, lengths: number[] }}
 * @throws {Error} On an unknown argument or a malformed value.
 */
function parseArguments(argv) {
	const options = { repository: DEFAULT_REPOSITORY, lengths: DEFAULT_LENGTHS };
	for (const argument of argv) {
		if (argument.startsWith('--repo=')) {
			options.repository = argument.slice('--repo='.length);
			if (!/^[\w.-]+\/[\w.-]+$/.test(options.repository))
				throw new Error(`--repo must be owner/name, got ${options.repository}`);
		} else if (argument.startsWith('--lengths=')) {
			options.lengths = argument
				.slice('--lengths='.length)
				.split(',')
				.map((value) => Number(value));
			if (!options.lengths.every((value) => Number.isInteger(value) && value > 0))
				throw new Error('--lengths must list positive integers');
		} else throw new Error(`unknown argument ${argument}`);
	}
	return options;
}

/**
 * Builds a bug-form URL of about `length` bytes with one shape of value.
 * @param {string} repository
 * @param {string} unit One character, repeated.
 * @param {number} length Target URL length in bytes.
 * @returns {string}
 */
function issueUrl(repository, unit, length) {
	const base = `https://${hosts.github}/${repository}/issues/new?template=bug_report.yml&diagnostics=`;
	const encoded = encodeURIComponent(unit);
	return base + encoded.repeat(Math.max(1, Math.ceil((length - base.length) / encoded.length)));
}

/**
 * Requests a URL without following redirects and without a cookie.
 * @param {string} url
 * @returns {Promise<{ status: number, location: string }>}
 */
async function probe(url) {
	const response = await fetch(url, {
		redirect: 'manual',
		signal: AbortSignal.timeout(TIMEOUT_MS)
	});
	await response.arrayBuffer();
	return { status: response.status, location: response.headers.get('location') || '' };
}

async function main() {
	const options = parseArguments(process.argv.slice(2));
	console.log('shape    url_bytes  status  login_bytes  return_to_kept  login_status');
	for (const [shape, unit] of Object.entries(SHAPES)) {
		for (const length of options.lengths) {
			const url = issueUrl(options.repository, unit, length);
			const first = await probe(url);
			let loginStatus = '-';
			let kept = '-';
			if (first.location) {
				const login = new URL(first.location, url);
				kept = login.searchParams.get('return_to') ? 'yes' : 'no';
				loginStatus = String((await probe(login.href)).status);
			}
			console.log(
				[
					shape.padEnd(8),
					String(url.length).padStart(9),
					String(first.status).padStart(7),
					String(first.location.length).padStart(12),
					kept.padStart(15),
					loginStatus.padStart(13)
				].join('  ')
			);
		}
	}
}

main().catch((error) => {
	console.error(`[FAIL] issue URL probe: ${error.message}`);
	process.exit(1);
});
