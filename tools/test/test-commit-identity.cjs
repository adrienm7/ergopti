// tools/test/test-commit-identity.cjs

/**
 * ==============================================================================
 * MODULE: Commit Identity Gate Regression
 * DESCRIPTION:
 * Builds a throwaway repository and proves the gate refuses an AI assistant
 * author or committer and an AI attribution trailer, in both the pending
 * (hook) and range (CI) modes, while the maintainer's identity passes.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { spawnSync, execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const GATE = path.resolve(__dirname, '..', 'lint', 'check-commit-identity.cjs');
const MAINTAINER = { name: 'Maintainer Example', email: 'maintainer@example.org' };
const ASSISTANT = { name: 'Claude', email: 'noreply@anthropic.com' };

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'commit-identity-'));

/**
 * Builds the environment for one identity, isolated from the host's Git config.
 * @param {{ name: string, email: string }} author Author identity.
 * @param {{ name: string, email: string }} committer Committer identity.
 * @returns {NodeJS.ProcessEnv} Environment.
 */
function identityEnv(author, committer) {
	return {
		...process.env,
		GIT_CONFIG_GLOBAL: path.join(root, 'empty-gitconfig'),
		GIT_CONFIG_NOSYSTEM: '1',
		GIT_AUTHOR_NAME: author.name,
		GIT_AUTHOR_EMAIL: author.email,
		GIT_COMMITTER_NAME: committer.name,
		GIT_COMMITTER_EMAIL: committer.email
	};
}

/**
 * Makes one empty commit and returns its id.
 * @param {string} message Commit message.
 * @param {{ name: string, email: string }} author Author identity.
 * @param {{ name: string, email: string }} committer Committer identity.
 * @returns {string} Commit id.
 */
function commit(message, author, committer) {
	const env = identityEnv(author, committer);
	execFileSync('git', ['commit', '--allow-empty', '--no-verify', '-q', '-m', message], {
		cwd: root,
		env
	});
	return execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, env, encoding: 'utf8' }).trim();
}

/**
 * Runs the gate and returns its exit status.
 * @param {string[]} args Gate arguments.
 * @param {NodeJS.ProcessEnv} env Environment.
 * @returns {number} Exit status.
 */
function gate(args, env) {
	return spawnSync(process.execPath, [GATE, ...args], { cwd: root, env, encoding: 'utf8' }).status;
}

try {
	fs.writeFileSync(path.join(root, 'empty-gitconfig'), '');
	const clean = identityEnv(MAINTAINER, MAINTAINER);
	execFileSync('git', ['init', '-q'], { cwd: root, env: clean });
	const base = commit('chore: base', MAINTAINER, MAINTAINER);
	const good = commit('feat: maintainer work', MAINTAINER, MAINTAINER);
	assert.equal(
		gate(['--range', `${base}..${good}`], clean),
		0,
		'the maintainer identity must pass'
	);

	const badAuthor = commit('feat: assistant author', ASSISTANT, MAINTAINER);
	assert.equal(
		gate(['--range', `${good}..${badAuthor}`], clean),
		1,
		'an assistant author must be refused'
	);
	const badCommitter = commit('feat: assistant committer', MAINTAINER, ASSISTANT);
	assert.equal(
		gate(['--range', `${badAuthor}..${badCommitter}`], clean),
		1,
		'an assistant committer must be refused'
	);
	const trailer = commit(
		'feat: trailer\n\nCo-Authored-By: Claude <noreply@anthropic.com>',
		MAINTAINER,
		MAINTAINER
	);
	assert.equal(
		gate(['--range', `${badCommitter}..${trailer}`], clean),
		1,
		'an attribution trailer must be refused'
	);
	const session = commit(
		'feat: session\n\nClaude-Session: https://claude.ai/code/x',
		MAINTAINER,
		MAINTAINER
	);
	assert.equal(
		gate(['--range', `${trailer}..${session}`], clean),
		1,
		'a session trailer must be refused'
	);

	const messageFile = path.join(root, 'MSG');
	fs.writeFileSync(messageFile, 'feat: pending\n');
	assert.equal(gate(['--pending', messageFile], clean), 0, 'a pending maintainer commit must pass');
	assert.equal(
		gate(['--pending', messageFile], identityEnv(ASSISTANT, MAINTAINER)),
		1,
		'a pending assistant author must be refused'
	);
	assert.equal(
		gate(['--pending', messageFile], identityEnv(MAINTAINER, ASSISTANT)),
		1,
		'a pending assistant committer must be refused'
	);
	fs.writeFileSync(
		messageFile,
		'feat: pending\n\nCo-Authored-By: Claude Opus <noreply@anthropic.com>\n'
	);
	assert.equal(
		gate(['--pending', messageFile], clean),
		1,
		'a pending attribution trailer must be refused'
	);
	console.log('PASS commit identity gate refuses assistant identities and attribution trailers');
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}
