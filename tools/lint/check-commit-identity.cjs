// tools/lint/check-commit-identity.cjs

/**
 * ==============================================================================
 * MODULE: Commit Identity Gate
 * DESCRIPTION:
 * Refuses commits whose author or committer is an AI assistant identity, and
 * commit messages that carry AI attribution trailers.
 *
 * WHY:
 * Every commit in this repository is made in the maintainer's name. Agent
 * containers start with a default Git identity and attribution habits; on
 * 2026-11-14 the maintainer found 1297 dev commits signed « Claude ». A Git
 * hook alone is not enough (a checkout without installed hooks skips it), so
 * the same check runs in the commit-msg hook and in CI over the pushed range.
 *
 * USAGE:
 *   node tools/lint/check-commit-identity.cjs --pending [message-file]
 *   node tools/lint/check-commit-identity.cjs --range <base>..<head>
 * ==============================================================================
 */

'use strict';

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');

const FORBIDDEN_NAME = /\bclaude\b/i;
const FORBIDDEN_EMAIL = /@anthropic\.com$/i;
const FORBIDDEN_TRAILER = /^\s*(co-authored-by:.*(claude|anthropic)|claude-session:)/im;

/**
 * Describes why one identity is refused.
 * @param {string} role Either "author" or "committer".
 * @param {string} name Identity name.
 * @param {string} email Identity e-mail.
 * @returns {string | null} The refusal, or null when the identity is allowed.
 */
function refuseIdentity(role, name, email) {
	if (FORBIDDEN_NAME.test(name) || FORBIDDEN_EMAIL.test(email)) {
		return `${role} « ${name} <${email}> » is an AI assistant identity`;
	}
	return null;
}

/**
 * Describes why one commit message is refused.
 * @param {string} message Full commit message.
 * @returns {string | null} The refusal, or null when the message is allowed.
 */
function refuseMessage(message) {
	const match = message.match(FORBIDDEN_TRAILER);
	return match ? `message carries an AI attribution trailer: « ${match[0].trim()} »` : null;
}

/**
 * Parses `git var GIT_*_IDENT` output into a name and an e-mail.
 * @param {string} ident Raw identity line.
 * @returns {{ name: string, email: string }} Parsed identity.
 */
function parseIdent(ident) {
	const match = ident.match(/^(.*) <([^>]*)>/);
	if (!match) throw new Error(`check-commit-identity: unparsable identity « ${ident} »`);
	return { name: match[1], email: match[2] };
}

/**
 * Checks the identity and message of the commit being created.
 * @param {string | undefined} messageFile Path of the commit message file, if any.
 * @returns {string[]} Refusals.
 */
function checkPending(messageFile) {
	const refusals = [];
	for (const [role, variable] of [
		['author', 'GIT_AUTHOR_IDENT'],
		['committer', 'GIT_COMMITTER_IDENT']
	]) {
		const { name, email } = parseIdent(
			execFileSync('git', ['var', variable], { encoding: 'utf8' }).trim()
		);
		const refusal = refuseIdentity(role, name, email);
		if (refusal) refusals.push(refusal);
	}
	if (messageFile) {
		const message = fs
			.readFileSync(messageFile, 'utf8')
			.split('\n')
			.filter((line) => !line.startsWith('#'))
			.join('\n');
		const refusal = refuseMessage(message);
		if (refusal) refusals.push(refusal);
	}
	return refusals;
}

/**
 * Checks every commit of a revision range.
 * @param {string} range Revision range such as `base..head`.
 * @returns {string[]} Refusals, each prefixed with the short commit id.
 */
function checkRange(range) {
	const separator = '\x1e';
	const raw = execFileSync(
		'git',
		['log', '--format=%h%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%B' + separator, range],
		{
			encoding: 'utf8',
			maxBuffer: 256 * 1024 * 1024
		}
	);
	const refusals = [];
	for (const record of raw.split(separator)) {
		const fields = record.replace(/^\n/, '').split('\x1f');
		if (fields.length < 6) continue;
		const [sha, authorName, authorEmail, committerName, committerEmail, message] = fields;
		for (const refusal of [
			refuseIdentity('author', authorName, authorEmail),
			refuseIdentity('committer', committerName, committerEmail),
			refuseMessage(message)
		]) {
			if (refusal) refusals.push(`${sha}: ${refusal}`);
		}
	}
	return refusals;
}

/**
 * Runs the gate from the command line.
 * @returns {void}
 */
function main() {
	const [mode, argument] = process.argv.slice(2);
	let refusals;
	if (mode === '--pending') refusals = checkPending(argument);
	else if (mode === '--range' && argument) refusals = checkRange(argument);
	else
		throw new Error(
			'usage: check-commit-identity.cjs --pending [message-file] | --range <base>..<head>'
		);
	if (refusals.length) {
		console.error('check-commit-identity: refused.');
		for (const refusal of refusals) console.error(`  ${refusal}`);
		console.error(
			"Commit in the maintainer's name (git config user.name / user.email) without AI trailers."
		);
		process.exit(1);
	}
	console.log(`check-commit-identity: OK (${mode}).`);
}

if (require.main === module) main();

module.exports = { refuseIdentity, refuseMessage, checkRange };
