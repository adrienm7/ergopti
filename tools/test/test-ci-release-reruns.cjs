// tools/test/test-ci-release-reruns.cjs

/**
 * ==============================================================================
 * MODULE: Release Re-run Guard
 * DESCRIPTION:
 * Executes the real scripts of ci.yml's release plan (the last steps of its
 * validate job) and of its release job with bash, against temporary git
 * repositories: the plan's `Compute tag and version`, the
 * release preflight, `Create release` and the Sparkle feed publication. It
 * proves which tag a push plans, and what each re-run of a release does.
 *
 * ROOT CAUSE ENCODED:
 * plan numbered the next tag from the tag list alone and never looked at HEAD.
 * "Re-run all jobs" on an older run, or any run of a commit an earlier run had
 * already tagged, therefore published that older code under the next number,
 * and the Windows updater, which orders tags by version, offered it as the
 * newest release. The first guard compared HEAD with the newest tag only, so
 * after a force push it still republished an already-tagged commit. The
 * release preflight made it worse: for a tag on another commit it advised
 * exactly that re-run, and for a tag on this commit it assumed no release
 * existed and advised deleting a tag that an immutable release had locked, so
 * a release whose feed or notes step had failed could never be finished. A
 * resumed release then pushed its older appcast over a newer release's feed,
 * from an artifact that no longer had to match the published zip.
 * Three defects predate the split and were found by mutation: `git log
 * --pretty=format:` left the oldest subject unterminated, so `read` dropped it
 * and a feat there was bumped as a patch; nothing noticed a dropped
 * `--prerelease`, which would make every dev build GitHub's latest release,
 * the one the Windows and Linux stable updaters install; and a tag such as
 * v0.0.0-dev.4-hotfix, which the dev glob matches, reached shell arithmetic
 * as the last number and failed plan under set -u.
 *
 * FEATURES & RATIONALE:
 * 1. Nothing is re-implemented: the scripts are sliced out of the workflow
 *    through tools/test/ci-pipeline.cjs and run byte for byte, with the env
 *    GitHub provides. A script that starts reading a workflow expression fails
 *    here, since the harness cannot substitute one; the expressions feeding
 *    each script's env are pinned structurally instead.
 * 2. bash and git are required. A missing one fails this test, never skips it,
 *    on Windows (Git Bash) and on the ubuntu Validate runner alike.
 * 3. gh and curl are stubs on PATH that answer only the exact calls the
 *    scripts make, so a changed call fails here instead of being answered
 *    wrongly. The feed is pushed to a real local origin.
 * 4. Structural pins keep the resume wiring: the preflight's id and token, the
 *    three conditional steps, and every other release step running.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('./ci-pipeline.cjs');
// Throws without bash: this test must fail, never skip, without it.
const { bashExecutable } = require('../lib/git-bash.cjs');
const { pythonExecutable } = require('../lib/python.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const PREFLIGHT = 'Refuse to publish an incomplete or already-taken release';
const CREATE_TAG = 'Create git tag';
const CREATE_RELEASE = 'Create draft release, verify assets and publish';
const PUBLISH_FEED = 'Publish channel feed for Sparkle';
const REPOSITORY = 'owner/ergopti';
const LINUX_BUNDLE = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'updater', 'defaults.json'),
		'utf8'
	)
).release_assets.linux_bundle;

const MANAGED_PUBLICATION_ASSETS = [
	'ollama-ergopti-native-http-darwin-arm64.tgz',
	'ollama-ergopti-native-http-darwin-amd64.tgz',
	'managed_ollama_release.json'
];
// Source dependencies are real copied files. The fixture creator never imports
// production admission or generation code to choose its expected metadata.
const MANAGED_PUBLICATION_SOURCES = [
	'tools/build/verify-macos-managed-ollama-publication.py',
	'tools/build/stage-macos-managed-ollama-catalogue.py',
	'tools/build/build-macos-managed-ollama.py',
	'static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json',
	'static/ergopti_plus/_shared/modules/llm/ollama_release.json',
	'static/ergopti_plus/_shared/python/managed_ollama_runtime.py',
	'static/ergopti_plus/_shared/go/native_http/transport.go',
	'static/ergopti_plus/_shared/go/native_http/worker_darwin.go',
	'static/ergopti_plus/_shared/go/native_http/worker_other.go',
	'static/ergopti_plus/_shared/go/native_http/admission.go',
	'static/ergopti_plus/_shared/go/native_http/network_bootstrap.go',
	'static/ergopti_plus/_shared/go/native_http/network_bootstrap_posix.go',
	'static/ergopti_plus/_shared/go/native_http/network_bootstrap_unsupported.go',
	'static/ergopti_plus/_shared/go/native_http/transport_test.go',
	'static/ergopti_plus/_shared/go/native_http/admission_test.go',
	'static/ergopti_plus/_shared/go/native_http/network_bootstrap_test.go',
	'static/ergopti_plus/_shared/go/native_http/network_bootstrap_darwin_test.go',
	'static/ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json',
	'static/ergopti_plus/_shared/modules/network/proxy_policy.json',
	'tools/diagnostics/macos_owned_process.py'
];
function copyManagedPublicationSources(work) {
	for (const relative of MANAGED_PUBLICATION_SOURCES) {
		const target = path.join(work, relative);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.copyFileSync(path.join(ROOT, relative), target);
	}
}

const failures = [];
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-release-reruns-'));
// Also on a thrown setup error, which ends the process before the report.
process.on('exit', () => fs.rmSync(scratch, { recursive: true, force: true }));
let runCount = 0;

/** Records one named case; a failure never hides the cases after it. */
function check(label, run) {
	try {
		run();
	} catch (error) {
		failures.push(`${label}: ${error.message}`);
	}
}

/** Returns the column of the first non-space character, or -1 for a blank line. */
function indentOf(line) {
	if (line.trim() === '') return -1;
	return line.length - line.trimStart().length;
}

/** Turns a native path into one bash accepts on every platform. */
function bashPath(value) {
	const normalized = value.replaceAll('\\', '/');
	if (process.platform !== 'win32') return normalized;
	return normalized.replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`);
}

// ======================================
// ======================================
// ======= 1/ Harness ===================
// ======================================
// ======================================

/**
 * Returns the literal `run: |` script of a step, dedented as YAML does.
 * @param {string} stepBody Step body from the loader.
 * @param {string} what Step name, for the messages.
 * @returns {string}
 */
function scriptOf(stepBody, what) {
	const lines = stepBody.split('\n');
	const at = lines.findIndex((line) => /^ {8}run: \|\s*$/.test(line));
	if (at < 0) throw new Error(`"${what}" has no literal run: | script`);
	const block = [];
	for (let index = at + 1; index < lines.length; index++) {
		if (indentOf(lines[index]) !== -1 && indentOf(lines[index]) <= 8) break;
		block.push(lines[index]);
	}
	const first = block.find((line) => line.trim() !== '');
	if (!first) throw new Error(`"${what}" has an empty script`);
	const indent = indentOf(first);
	const script = `${block
		.map((line) => line.slice(indent))
		.join('\n')
		.trimEnd()}\n`;
	if (script.includes('${{')) {
		throw new Error(
			`"${what}" reads a workflow expression in its script; pass it through env: so it can be tested`
		);
	}
	return script;
}

const BASH = bashExecutable();
const gitVersion = spawnSync('git', ['--version'], { encoding: 'utf8' });
if (gitVersion.status !== 0)
	throw new Error(
		`git is required to run the release scripts: ${gitVersion.error ?? gitVersion.stderr}`
	);

// Every git call, the harness's and the scripts', ignores the user's and the
// system's configuration.
const emptyConfig = path.join(scratch, 'empty.gitconfig');
fs.writeFileSync(emptyConfig, '');
const GIT_ENV = {
	...process.env,
	GIT_CONFIG_NOSYSTEM: '1',
	GIT_CONFIG_GLOBAL: emptyConfig,
	GIT_AUTHOR_NAME: 'CI Test',
	GIT_AUTHOR_EMAIL: 'ci@example.invalid',
	GIT_COMMITTER_NAME: 'CI Test',
	GIT_COMMITTER_EMAIL: 'ci@example.invalid',
	GIT_TERMINAL_PROMPT: '0'
};

/** Runs git in `cwd` and returns its trimmed stdout, or throws. */
function git(cwd, ...args) {
	const result = spawnSync('git', args, { cwd, env: GIT_ENV, encoding: 'utf8' });
	if (result.status !== 0)
		throw new Error(`git ${args.join(' ')} failed: ${result.stderr || result.error}`);
	return result.stdout.trim();
}

/** Makes an empty commit on the checked-out branch and returns its SHA. */
function commit(repo, subject) {
	git(repo, 'commit', '--quiet', '--allow-empty', '-m', subject);
	return git(repo, 'rev-parse', 'HEAD');
}

/** Creates a bare origin and a clone of it on `branch`; returns the clone. */
function repository(name, branch) {
	const origin = path.join(scratch, `${name}-origin.git`);
	const work = path.join(scratch, `${name}-work`);
	git(scratch, 'init', '--quiet', '--bare', origin);
	git(scratch, 'init', '--quiet', `--initial-branch=${branch}`, work);
	git(work, 'remote', 'add', 'origin', origin);
	// The extracted workflow calls the real channel resolver and its registry.
	for (const relative of [
		'tools/build/release-channel.cjs',
		'tools/ci/dev-release-qualification.cjs',
		'tools/ci/windows-stable-signing.cjs',
		'.github/ci/stable_windows_signing_exception.json',
		'.github/ci/dev_release_qualification_exceptions.json',
		'.github/ci/stable_release_qualification_exception.json',
		'tools/build/publish-verified-release.cjs',
		'tools/build/macos-release-publication.cjs',
		'tools/build/macos-release-archives.cjs',
		'tools/lib/paths.cjs',
		'static/ergopti_plus/_shared/modules/updater/defaults.json',
		'static/ergopti_plus/_shared/modules/updater/channels.json',
		'static/ergopti_plus/_shared/ui/update_channels.js'
	]) {
		const target = path.join(work, relative);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.copyFileSync(path.join(ROOT, relative), target);
	}
	copyManagedPublicationSources(work);
	return work;
}

/** Reads a GITHUB_OUTPUT file into an object. */
function outputsOf(file) {
	const outputs = {};
	for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
		if (line === '') continue;
		const at = line.indexOf('=');
		outputs[line.slice(0, at)] = line.slice(at + 1);
	}
	return outputs;
}

/**
 * Runs one extracted script the way a `shell: bash` step does.
 * @returns {{status: number, stdout: string, stderr: string, outputs: object}}
 */
function runScript(script, cwd, env, prologue = '') {
	runCount++;
	const file = path.join(scratch, `script-${runCount}.sh`);
	const output = path.join(scratch, `output-${runCount}.txt`);
	fs.writeFileSync(file, prologue + script);
	fs.writeFileSync(output, '');
	const result = spawnSync(BASH, ['--noprofile', '--norc', '-eo', 'pipefail', bashPath(file)], {
		cwd,
		env: { ...GIT_ENV, ...env, GITHUB_OUTPUT: bashPath(output) },
		encoding: 'utf8',
		timeout: 60000
	});
	if (result.error) throw result.error;
	return {
		status: result.status,
		stdout: result.stdout,
		stderr: result.stderr,
		outputs: outputsOf(output)
	};
}

// gh and curl answer only the exact calls the release scripts make; anything
// else exits 99, so a changed call fails a case instead of being answered.
const stubs = path.join(scratch, 'stubs');
fs.mkdirSync(stubs);
fs.writeFileSync(
	path.join(stubs, 'gh'),
	[
		'#!/usr/bin/env bash',
		'printf \'%s\\n\' "$*" >> "$GH_STUB_LOG"',
		'if [ -z "${GH_TOKEN:-}" ]; then echo "gh stub: GH_TOKEN is not set" >&2; exit 98; fi',
		'case "$1 $2" in',
		'    "release view")',
		'        if [ "$*" = "release view ${GH_STUB_TAG:-} --repo ${GH_STUB_REPO:-} --json isDraft,assets" ]; then',
		'            node "$GH_STUB_PUBLISH_RESPONDER" "$@"; exit $?;',
		'        fi',
		'        if [ "$*" != "release view $GH_STUB_TAG --repo $GH_STUB_REPO --json isDraft --jq .isDraft" ]; then',
		'            echo "gh stub: unexpected call: $*" >&2; exit 99',
		'        fi',
		'        case "$GH_STUB_MODE" in',
		'            missing) echo "release not found" >&2; exit 1 ;;',
		'            published) echo false ;;',
		'            draft) echo true ;;',
		'            empty) echo "" ;;',
		'            error) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;',
		'            not-found) echo "HTTP 404: Not Found (https://api.github.com/repos/$GH_STUB_REPO/releases)" >&2; exit 1 ;;',
		'            *) echo "gh stub: no mode" >&2; exit 97 ;;',
		'        esac ;;',
		'    "release create")',
		'        printf \'%s\\n\' "${@:3}" > "$GH_STUB_ARGS"',
		'        if [ -n "${GH_STUB_PUBLISH_STATE:-}" ]; then node "$GH_STUB_PUBLISH_RESPONDER" "$@"; fi ;;',
		'    "release upload"|"release edit")',
		'        node "$GH_STUB_PUBLISH_RESPONDER" "$@" ;;',
		'    "release download")',
		'        feed="appcast-$GH_STUB_CHANNEL.xml"',
		'        if [ "$*" != "release download $GH_STUB_TAG --repo $GH_STUB_REPO --pattern $feed --output release-assets/$feed --clobber" ]; then',
		'            echo "gh stub: unexpected call: $*" >&2; exit 99',
		'        fi',
		'        printf \'%s\\n\' "$GH_STUB_PUBLISHED_FEED" > "release-assets/$feed" ;;',
		'    *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;',
		'esac',
		''
	].join('\n')
);
fs.writeFileSync(
	path.join(stubs, 'curl'),
	[
		'#!/usr/bin/env bash',
		'url="${*: -1}"',
		'printf \'%s\\n\' "$url" >> "$CURL_STUB_LOG"',
		'if [ "$url" != "$CURL_STUB_URL" ]; then echo "curl stub: unexpected URL $url" >&2; exit 99; fi',
		'case "$CURL_STUB_MODE" in',
		'    origin) git --git-dir "$CURL_STUB_ORIGIN" show "sparkle-appcasts:appcast-$CURL_STUB_CHANNEL.xml" ;;',
		'    stale) echo "<appcast>a stale edge copy</appcast>" ;;',
		'    *) echo "curl stub: no mode" >&2; exit 97 ;;',
		'esac',
		''
	].join('\n')
);
fs.chmodSync(path.join(stubs, 'gh'), 0o755);
fs.chmodSync(path.join(stubs, 'curl'), 0o755);
// Git Bash must execute the same observed CPython as fixture generation; a
// Windows Store python3 alias is not the workflow's real Python prerequisite.
// Forward argv unchanged to the real interpreter, never simulate verification.
if (process.platform === 'win32') {
	const nativePython = bashPath(pythonExecutable());
	const quotedPython = "'" + nativePython.replaceAll("'", "'\\''") + "'";
	fs.writeFileSync(
		path.join(stubs, 'python3'),
		'#!/usr/bin/env bash\nexec ' + quotedPython + ' "$@"\n'
	);
	fs.chmodSync(path.join(stubs, 'python3'), 0o755);
}

const STUB_PATH = `export PATH="${bashPath(stubs)}:$PATH"\n`;

// A Node child must cross the same fake gh boundary on Windows: Node cannot
// execute a POSIX shebang there. Preloading this exact boundary leaves the
// extracted workflow and the production publication helper byte-identical.
const ghPreload = path.join(stubs, 'gh-preload.cjs');
fs.writeFileSync(
	ghPreload,
	`
const cp = require('node:child_process');
const original = cp.spawnSync;
cp.spawnSync = function(file, args, options) {
    if (file === 'gh') return original(${JSON.stringify(BASH)},
        ['--noprofile', '--norc', ${JSON.stringify(bashPath(path.join(stubs, 'gh')))}, ...args], options);
    return original(file, args, options);
};
`
);
const publishResponder = path.join(stubs, 'publish-responder.cjs');
fs.writeFileSync(
	publishResponder,
	String.raw`
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const args = process.argv.slice(2);
const file = process.env.GH_STUB_PUBLISH_STATE;
const state = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(args[0], 'release');
assert.equal(args[2], process.env.GH_STUB_TAG);
if (args[1] === 'create') {
    state.isDraft = args.includes('--draft');
} else if (args[1] === 'view') {
    assert.deepEqual(args.slice(3), ['--repo', process.env.GH_STUB_REPO, '--json', 'isDraft,assets']);
    if (state.mode === 'lookup-refusal') throw new Error('native inventory lookup refused');
    if (state.mode === 'malformed') { process.stdout.write('{invalid'); process.exit(0); }
    if (state.mode === 'unexpected-published') state.isDraft = false;
    process.stdout.write(JSON.stringify({ isDraft: state.isDraft, assets: state.assets }));
} else if (args[1] === 'upload') {
    assert.equal(state.isDraft, true, 'an immutable publication cannot be repaired');
    const repo = args.indexOf('--repo');
    assert.deepEqual(args.slice(repo), ['--repo', process.env.GH_STUB_REPO, '--clobber']);
    if (state.mode === 'upload-refusal') throw new Error('native upload refused');
    for (const local of args.slice(3, repo)) {
        const name = path.basename(local);
        if (state.mode === 'permanent-loss') continue;
        state.assets = state.assets.filter(asset => asset.name !== name);
        state.assets.push({ name, size: fs.statSync(local).size, state: 'uploaded' });
    }
} else if (args[1] === 'edit') {
    assert.deepEqual(args.slice(3), ['--repo', process.env.GH_STUB_REPO, '--draft=false']);
    if (state.mode === 'publish-refusal') throw new Error('native publication refused');
    if (state.mode !== 'unacknowledged-publication') state.isDraft = false;
} else {
    throw new Error('unexpected native release operation');
}
fs.writeFileSync(file, JSON.stringify(state));
`
);

/** Returns a fresh, empty log file for a stub. */
function stubLog(name) {
	const file = path.join(scratch, `${name}-${runCount + 1}.log`);
	fs.writeFileSync(file, '');
	return file;
}

/** Reads a stub log as its non-empty lines. */
function linesOf(file) {
	return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
}

// ======================================
// ======================================
// ======= 2/ Plan Never Republishes ====
// ======================================
// ======================================

const planScript = scriptOf(
	pipeline.step(pipeline.job('validate'), 'Compute tag and version'),
	'Compute tag and version'
);

/** Runs plan's script for a push of `ref`, with HEAD at `sha`. */
function plan(repo, sha, ref, event = 'push') {
	git(repo, 'checkout', '--quiet', '--detach', sha);
	return runScript(planScript, repo, {
		GITHUB_EVENT_NAME: event,
		GITHUB_REF: ref,
		GITHUB_REF_NAME: ref.replace(/^refs\/heads\//, '')
	});
}

/** Asserts a plan run that publishes nothing. */
function noRelease(result, notice) {
	assert.equal(result.status, 0, result.stderr);
	assert.deepEqual(result.outputs, { release: 'false', channel: 'dev' });
	if (notice) assert.match(result.stdout, notice);
}

/** Asserts a plan run that publishes `tag`. */
function releases(result, tag) {
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.equal(result.outputs.release, 'true', result.stdout);
	assert.equal(result.outputs.tag, tag, result.stdout);
}

const dev = repository('dev', 'dev');
const d1 = commit(dev, 'chore: one');
const d2 = commit(dev, 'chore: two');
const d3 = commit(dev, 'chore: three');
git(dev, 'tag', 'v0.0.0-dev.1', d1);
git(dev, 'tag', '-a', '-m', 'dev 2', 'v0.0.0-dev.2', d3);
git(dev, 'push', '--quiet', 'origin', 'dev', '--tags');

check('dev: an ancestor of the last dev tag is not published again', () => {
	noRelease(
		plan(dev, d2, 'refs/heads/dev'),
		/::notice::This commit is already part of v0\.0\.0-dev\.2, which an earlier run published/
	);
});

check("dev: the last dev tag's own commit is not published again", () => {
	noRelease(
		plan(dev, d3, 'refs/heads/dev'),
		/::notice::This commit is already part of v0\.0\.0-dev\.2, /
	);
});

check('dev: the notice says how to finish a half-published release without a dead end', () => {
	const result = plan(dev, d1, 'refs/heads/dev');
	noRelease(
		result,
		/::notice::This commit is already part of v0\.0\.0-dev\.1 and 1 later tag\(s\)/
	);
	assert.match(
		result.stdout,
		/'Re-run failed jobs' on the run that created that tag, before any 'Re-run all jobs' there/
	);
	assert.match(
		result.stdout,
		/delete an orphan tag, or write a published release's notes with gh release edit/
	);
});

check('dev: a new commit publishes under the next dev tag', () => {
	git(dev, 'checkout', '--quiet', '--detach', d3);
	const d4 = commit(dev, 'chore: four');
	const result = plan(dev, d4, 'refs/heads/dev');
	assert.equal(result.status, 0, result.stderr);
	assert.deepEqual(result.outputs, {
		release: 'true',
		tag: 'v0.0.0-dev.3',
		version: '0.0.0-dev.3',
		title: 'Ergopti v0.0.0-dev.3',
		prerelease: 'true',
		channel: 'dev'
	});
});

check('dev: a pull request never publishes', () => {
	noRelease(plan(dev, d3, 'refs/pull/7/merge', 'pull_request'), /Not a push to main or dev/);
});

check('dev: after a force push, a commit that an older tag contains is not published again', () => {
	const forced = repository('forced', 'dev');
	const a1 = commit(forced, 'chore: a1');
	const a2 = commit(forced, 'chore: a2');
	git(forced, 'tag', 'v0.0.0-dev.1', a1);
	git(forced, 'tag', 'v0.0.0-dev.2', a2);
	// dev rewritten from scratch: the newest tag no longer descends from a1 or a2.
	git(forced, 'checkout', '--quiet', '--orphan', 'rewritten');
	const b1 = commit(forced, 'chore: b1 after the force push');
	git(forced, 'tag', 'v0.0.0-dev.3', b1);
	git(forced, 'push', '--quiet', 'origin', '--tags');
	noRelease(
		plan(forced, a1, 'refs/heads/dev'),
		/::notice::This commit is already part of v0\.0\.0-dev\.1 and 1 later tag\(s\)/
	);
	noRelease(
		plan(forced, a2, 'refs/heads/dev'),
		/::notice::This commit is already part of v0\.0\.0-dev\.2, /
	);
	git(forced, 'checkout', '--quiet', '--detach', b1);
	releases(plan(forced, commit(forced, 'chore: b2'), 'refs/heads/dev'), 'v0.0.0-dev.4');
});

check('dev: a failing git tag fails plan instead of reading as "never released"', () => {
	const broken = repository('broken', 'dev');
	const b1 = commit(broken, 'chore: one');
	git(broken, 'tag', 'v0.0.0-dev.1', b1);
	git(broken, 'pack-refs', '--all');
	git(broken, 'checkout', '--quiet', '--detach', b1);
	fs.appendFileSync(path.join(broken, '.git', 'packed-refs'), 'not a ref line\n');
	const result = runScript(planScript, broken, {
		GITHUB_EVENT_NAME: 'push',
		GITHUB_REF: 'refs/heads/dev',
		GITHUB_REF_NAME: 'dev'
	});
	assert.notEqual(
		result.status,
		0,
		'plan must fail when git cannot list the tags that contain HEAD'
	);
	assert.match(result.stderr, /packed-refs/);
	assert.equal(result.outputs.release, undefined, 'a failed plan must not emit release');
});

check('dev: the first dev release is planned without any tag', () => {
	const fresh = repository('fresh', 'dev');
	releases(plan(fresh, commit(fresh, 'chore: first'), 'refs/heads/dev'), 'v0.0.0-dev.1');
});

const main = repository('main', 'main');
const m1 = commit(main, 'chore: init');
const m2 = commit(main, 'fix: a bug');
git(main, 'tag', 'v1.2.3', m2);
git(main, 'push', '--quiet', 'origin', 'main', '--tags');

check("main: the last stable tag's own commit is not published again", () => {
	noRelease(
		plan(main, m2, 'refs/heads/main'),
		/::notice::This commit is already part of v1\.2\.3, /
	);
});

check('main: an ancestor of the last stable tag is not published again', () => {
	noRelease(
		plan(main, m1, 'refs/heads/main'),
		/::notice::This commit is already part of v1\.2\.3, /
	);
});

check('main: a new commit publishes the next stable version', () => {
	git(main, 'checkout', '--quiet', '--detach', m2);
	const m3 = commit(main, 'fix: another bug');
	const result = plan(main, m3, 'refs/heads/main');
	assert.equal(result.status, 0, result.stderr);
	assert.deepEqual(result.outputs, {
		release: 'true',
		tag: 'v1.2.4',
		version: '1.2.4',
		title: 'Ergopti v1.2.4',
		prerelease: 'false',
		channel: 'main'
	});
});

check('main: with no stable tag yet, the first release is planned', () => {
	const first = repository('first', 'main');
	releases(plan(first, commit(first, 'chore: first'), 'refs/heads/main'), 'v0.0.1');
});

/** Plans a push to main of `subjects`, oldest first, committed after v1.2.3. */
function mainBump(name, subjects) {
	const repo = repository(name, 'main');
	git(repo, 'tag', 'v1.2.3', commit(repo, 'chore: base'));
	let last = null;
	for (const subject of subjects) last = commit(repo, subject);
	return plan(repo, last, 'refs/heads/main');
}

// The range is read newest first, so its oldest subject is the last line.
check('main: a feat as the only commit bumps the minor version', () => {
	releases(mainBump('feat-only', ['feat: a new feature']), 'v1.3.0');
});

check('main: a feat as the oldest commit, before a fix, bumps the minor version', () => {
	releases(mainBump('feat-oldest', ['feat: a new feature', 'fix: a later fix']), 'v1.3.0');
});

check('main: a `!:` breaking change as the oldest commit bumps the major version', () => {
	releases(
		mainBump('bang-oldest', ['refactor(api)!: drop the old API', 'fix: a later fix']),
		'v2.0.0'
	);
});

check('main: a BREAKING: subject bumps the major version', () => {
	releases(
		mainBump('breaking', ['fix: a bug', 'BREAKING: drop the old config', 'feat: a feature']),
		'v2.0.0'
	);
});

check('main: fixes and chores only bump the patch version', () => {
	releases(mainBump('patch-only', ['fix: a bug', 'chore: tidy']), 'v1.2.4');
});

// The glob also matches tags no run publishes; only the series counts, both
// for "already published" and for the next number.
check('a tag outside the series, even one the glob matches, does not count as published', () => {
	const stable = repository('rc', 'main');
	git(stable, 'tag', 'v1.2.3', commit(stable, 'chore: base'));
	const fixed = commit(stable, 'fix: a bug');
	git(stable, 'tag', 'v1.2.4-rc.1', fixed);
	releases(plan(stable, fixed, 'refs/heads/main'), 'v1.2.4');
	const hotfix = repository('hotfix', 'dev');
	const h1 = commit(hotfix, 'chore: one');
	git(hotfix, 'tag', 'v0.0.0-dev.1', h1);
	const h2 = commit(hotfix, 'chore: two');
	git(hotfix, 'tag', 'v0.0.0-dev.1-hotfix', h2);
	releases(plan(hotfix, h2, 'refs/heads/dev'), 'v0.0.0-dev.2');
});

// ===============================================
// ===============================================
// ======= 3/ The Preflight Resumes Or Stops =====
// ===============================================
// ===============================================

const releaseJob = pipeline.job('release');
const preflightScript = scriptOf(pipeline.step(releaseJob, PREFLIGHT), PREFLIGHT);

// Every file the preflight requires, read from its own loop.
const assetLoop = /^for asset in ([^\n;]*(?:\\\n[^\n;]*)*); do$/m.exec(preflightScript);
if (!assetLoop) throw new Error(`"${PREFLIGHT}" no longer loops over its required assets`);
/** Lists the files the preflight requires for `channel`. */
function requiredAssets(channel) {
	return assetLoop[1]
		.split(/\s+/)
		.filter((token) => token !== '' && token !== '\\')
		.map((token) =>
			token
				.replace(/^"(.*)"$/, '$1')
				.replace('${CHANNEL}', channel)
				.replace('$LINUX_BUNDLE_ASSET', LINUX_BUNDLE)
		);
}
if (requiredAssets('dev').length < 10)
	throw new Error(`parsed only ${requiredAssets('dev').length} required asset(s)`);

const runner = repository('runner', 'dev');
const other = commit(runner, 'chore: an older commit');
const head = commit(runner, 'chore: the commit being released');
const newer = commit(runner, 'chore: a newer commit');
git(runner, 'push', '--quiet', 'origin', 'dev');

const FLATTEN = 'Bring every downloaded asset to the top of release-assets';
const flattenScript = scriptOf(pipeline.step(releaseJob, FLATTEN), FLATTEN);

/** The `path:` list of one upload-artifact step, one entry per line. */
function uploadPaths(stepBody) {
	const lines = stepBody.split('\n');
	const at = lines.findIndex((line) => /^ {10}path:/.test(line));
	if (at < 0) throw new Error('an assets-* upload step lists no path');
	const inline = lines[at].replace(/^ {10}path:\s*/, '').trim();
	if (inline !== '|') return [inline];
	const listed = [];
	for (let index = at + 1; index < lines.length; index++) {
		if (indentOf(lines[index]) !== -1 && indentOf(lines[index]) <= 10) break;
		if (lines[index].trim() !== '') listed.push(lines[index].trim());
	}
	return listed;
}

/**
 * Where each required asset lands in release-assets, as the real upload steps
 * lay it out: upload-artifact keeps a file's path below the deepest directory
 * common to every path its step lists, and merge-multiple pours every assets-*
 * artifact into one directory. A listed name may be a glob or an expression.
 * @returns {Map<string, string>} Asset name to its path inside release-assets.
 */
function uploadedLayout(channel) {
	const layout = new Map();
	for (const entry of pipeline.files()) {
		for (const job of pipeline.jobs(entry.rel)) {
			for (const candidate of pipeline.steps(job.body)) {
				if (!/uses:\s*actions\/upload-artifact/.test(candidate.body)) continue;
				if (!/^ {10}name:\s*assets-/m.test(candidate.body)) continue;
				const listed = uploadPaths(candidate.body).flatMap((listedPath) => {
					if (listedPath !== '${{ env.ERGOPTI_OLLAMA_ASSET }}') return [listedPath];
					assert.equal(
						job.id,
						'managed-ollama-native',
						'the runtime asset has one native producer owner'
					);
					assert.equal(candidate.name, 'Upload the actual managed native release asset');
					// The real matrix uploads each archive alone: both artifact roots are
					// its filename. Independent filenames model these two actual legs.
					return MANAGED_PUBLICATION_ASSETS.slice(0, 2);
				});
				const dirs = listed.map((listedPath) => listedPath.split('/').slice(0, -1));
				const common = [];
				for (
					let depth = 0;
					dirs.every((dir) => depth < dir.length && dir[depth] === dirs[0][depth]);
					depth++
				) {
					common.push(dirs[0][depth]);
				}
				for (const listedPath of listed) {
					const below = listedPath.split('/').slice(common.length);
					const leaf = below[below.length - 1].replace(
						/\$\{\{\s*([^}]*?)\s*\}\}/g,
						(whole, expression) => {
							if (expression === 'inputs.linux_bundle' || expression === 'env.LINUX_BUNDLE_ASSET')
								return LINUX_BUNDLE;
							if (expression === 'inputs.channel') return channel;
							throw new Error(
								`an assets-* upload path uses ${whole}, which this test cannot resolve`
							);
						}
					);
					const pattern = new RegExp(
						`^${leaf.replace(/[.+?^$(){}|[\]\\]/g, '\\$&').replace(/\*/g, '[^/]*')}$`
					);
					for (const name of [...requiredAssets(channel), ...MANAGED_PUBLICATION_ASSETS]) {
						if (!pattern.test(name)) continue;
						if (layout.has(name)) throw new Error(`two assets-* upload paths match ${name}`);
						layout.set(name, [...below.slice(0, -1), name].join('/'));
					}
				}
			}
		}
	}
	return layout;
}

/**
 * Runs the preflight in `cwd` for `tag`, with every asset but `missingAsset`
 * present and gh answering `ghMode`. With `uploaded`, the assets are laid out
 * the way the real upload steps store them and the release job's flattening
 * step runs first.
 */
function preflight(
	tag,
	{
		ghMode = 'none',
		missingAsset = null,
		cwd = runner,
		channel = 'dev',
		sha = head,
		uploaded = false,
		managedMutation = null
	} = {}
) {
	const assets = path.join(cwd, 'release-assets');
	fs.rmSync(assets, { recursive: true, force: true });
	fs.mkdirSync(assets);
	const layout = uploaded ? uploadedLayout(channel) : new Map();
	for (const name of requiredAssets(channel)) {
		if (name === missingAsset) continue;
		const target = path.join(assets, ...(layout.get(name) || name).split('/'));
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.writeFileSync(target, `${name}\n`);
	}
	// Execute the real new preflight owner against independent, physically
	// bound synthetic publication assets and actual valid ZIP/TAR files.
	// These bytes deliberately cannot qualify native production or signing.
	copyManagedPublicationSources(cwd);
	for (const relative of [
		'tools/build/release-channel.cjs',
		'tools/ci/dev-release-qualification.cjs',
		'tools/ci/windows-stable-signing.cjs',
		'.github/ci/stable_windows_signing_exception.json',
		'.github/ci/dev_release_qualification_exceptions.json',
		'.github/ci/stable_release_qualification_exception.json',
		'static/ergopti_plus/_shared/ui/update_channels.js',
		'static/ergopti_plus/_shared/modules/updater/defaults.json',
		'static/ergopti_plus/_shared/modules/updater/channels.json'
	]) {
		const target = path.join(cwd, relative);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.copyFileSync(path.join(ROOT, relative), target);
	}
	const managed = spawnSync(
		pythonExecutable(),
		[
			path.join(ROOT, 'tools/test/fixtures/managed_native_publication.py'),
			'--repository',
			cwd,
			'--assets',
			assets,
			'--tag',
			tag,
			'--channel',
			channel
		],
		{ cwd, env: GIT_ENV, encoding: 'utf8', timeout: 60000 }
	);
	assert.equal(managed.error, undefined, 'independent publication fixture must start');
	assert.equal(managed.signal, null, 'independent publication fixture must close');
	assert.equal(managed.status, 0, managed.stderr || managed.stdout);
	if (uploaded) {
		const flattened = runScript(flattenScript, cwd, {});
		if (flattened.status !== 0) return { ...flattened, ghCalls: [] };
	}
	// The new fresh-publication owner is exercised with actual private files.
	// It signs only through controlled native ports; no native crypto claim.
	const publication = require('../build/macos-release-publication.cjs');
	for (const archive of publication.bindings()) {
		const target = path.join(assets, archive.name);
		if (!fs.existsSync(target)) fs.writeFileSync(target, `${archive.name}\n`);
		const signature = path.join(assets, `_${archive.name}.sig`);
		if (fs.existsSync(signature)) fs.unlinkSync(signature);
	}
	publication.signArchives(assets, 'private-fixture-signer', 'private-fixture-key', {
		execute: (tool, args) => ({
			status: 0,
			stdout: args.includes('--verify')
				? ''
				: `sparkle:edSignature="${'A'.repeat(86)}==" length="${fs.statSync(args[2]).size}"\n`,
			stderr: ''
		})
	});
	if (managedMutation) managedMutation(assets);
	if (missingAsset && fs.existsSync(path.join(assets, missingAsset)))
		fs.unlinkSync(path.join(assets, missingAsset));
	const ghLog = stubLog('gh');
	const result = runScript(
		preflightScript,
		cwd,
		{
			TAG: tag,
			CHANNEL: channel,
			LINUX_BUNDLE_ASSET: LINUX_BUNDLE,
			GITHUB_SHA: sha,
			GITHUB_REPOSITORY: REPOSITORY,
			RUNNER_TEMP: bashPath(scratch),
			GH_TOKEN: 'stub-token',
			GH_STUB_LOG: bashPath(ghLog),
			GH_STUB_TAG: tag,
			GH_STUB_REPO: REPOSITORY,
			GH_STUB_MODE: ghMode
		},
		STUB_PATH
	);
	return { ...result, ghCalls: linesOf(ghLog) };
}

/** Pushes `tag` to the origin of `repo`, lightweight or annotated. */
function pushTag(tag, sha, { annotated = false, repo = runner } = {}) {
	if (annotated) git(repo, 'tag', '-a', '-m', tag, tag, sha);
	else git(repo, 'tag', tag, sha);
	git(repo, 'push', '--quiet', 'origin', `refs/tags/${tag}`);
}

check('a free tag publishes from the start', () => {
	const result = preflight('v0.0.0-dev.10');
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.deepEqual(result.outputs, {
		create_tag: 'true',
		create_release: 'true',
		skip_feed: 'false'
	});
	assert.deepEqual(result.ghCalls, [], 'a free tag needs no release lookup');
});

check(
	'assets stored below a common directory by upload-artifact still publish (release-assets-layout-2026-09-27)',
	() => {
		const layout = uploadedLayout('dev');
		for (const name of requiredAssets('dev')) {
			assert.ok(layout.has(name), `no assets-* upload step lists ${name}`);
		}
		// The layout that failed the first release of the grouped pipeline: the
		// Windows exes and the XKB zip arrived in subdirectories.
		assert.ok(
			[...layout.values()].some((placed) => placed.includes('/')),
			'no asset lands in a subdirectory, so this case no longer exercises the flattening'
		);
		const result = preflight('v0.0.0-dev.10', { uploaded: true });
		assert.equal(result.status, 0, result.stdout + result.stderr);
		assert.deepEqual(result.outputs, {
			create_tag: 'true',
			create_release: 'true',
			skip_feed: 'false'
		});
		const top = fs.readdirSync(path.join(runner, 'release-assets'), { withFileTypes: true });
		assert.deepEqual(
			top.filter((dirent) => !dirent.isFile()).map((dirent) => dirent.name),
			[],
			'release-assets must hold files only once flattened'
		);
	}
);

check('two downloaded assets with one name stop the release', () => {
	const assets = path.join(runner, 'release-assets');
	fs.rmSync(assets, { recursive: true, force: true });
	fs.mkdirSync(path.join(assets, 'windows'), { recursive: true });
	fs.writeFileSync(path.join(assets, 'ErgoptiPlus.exe'), 'one\n');
	fs.writeFileSync(path.join(assets, 'windows', 'ErgoptiPlus.exe'), 'two\n');
	const result = runScript(flattenScript, runner, {});
	assert.equal(result.status, 1, result.stdout + result.stderr);
	assert.match(result.stdout, /::error::two downloaded assets are named ErgoptiPlus\.exe/);
});

check('a missing asset stops the release before anything is created', () => {
	const result = preflight('v0.0.0-dev.10', { missingAsset: 'Ergopti_macOS.zip' });
	assert.equal(result.status, 1);
	assert.match(result.stdout, /::error::release-assets\/Ergopti_macOS\.zip is missing or empty/);
	assert.deepEqual(result.outputs, {});
});

check(
	'a tag on a newer commit means this run was superseded: nothing to publish, no re-run',
	() => {
		pushTag('v0.0.0-dev.11', newer);
		const result = preflight('v0.0.0-dev.11');
		assert.equal(result.status, 1);
		assert.match(
			result.stdout,
			new RegExp(
				`::error::v0\\.0\\.0-dev\\.11 already exists on ${newer}, not on ${head}: ` +
					'a newer run superseded this one'
			)
		);
		assert.match(result.stdout, /There is nothing to publish; do not re-run this run\./);
		assert.doesNotMatch(result.stdout, /Re-run all jobs/);
		assert.deepEqual(result.ghCalls, []);
		assert.deepEqual(result.outputs, {});
	}
);

check(
	'a tag on an older commit means another run took the number: "Re-run all jobs" publishes this one',
	() => {
		pushTag('v0.0.0-dev.12', other);
		const result = preflight('v0.0.0-dev.12');
		assert.equal(result.status, 1);
		assert.match(
			result.stdout,
			new RegExp(
				`::error::v0\\.0\\.0-dev\\.12 already exists on ${other}, an older commit ` +
					`than this run's ${head}: another run took the number this run planned\\.`
			)
		);
		assert.match(result.stdout, /'Re-run all jobs' publishes this commit under the next number/);
		assert.doesNotMatch(result.stdout, /newer run superseded/);
		assert.deepEqual(result.outputs, {});
	}
);

check("this commit's tag without a release resumes at the release", () => {
	pushTag('v0.0.0-dev.13', head);
	const result = preflight('v0.0.0-dev.13', { ghMode: 'missing' });
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.deepEqual(result.outputs, {
		create_tag: 'false',
		create_release: 'true',
		skip_feed: 'false'
	});
	assert.equal(result.ghCalls.length, 1);
	assert.match(
		result.stdout,
		/::notice::v0\.0\.0-dev\.13 already points at this commit and has no release/
	);
});

check("this commit's published release resumes at the feed and the notes", () => {
	// Annotated: the tag object differs from the commit, so the peeled line decides.
	pushTag('v0.0.0-dev.14', head, { annotated: true });
	const result = preflight('v0.0.0-dev.14', { ghMode: 'published' });
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.deepEqual(result.outputs, {
		create_tag: 'false',
		create_release: 'false',
		skip_feed: 'false'
	});
	assert.match(result.stdout, /::notice::v0\.0\.0-dev\.14 is already released from this commit/);
});

check("this commit's draft release stops the run with the manual fix", () => {
	pushTag('v0.0.0-dev.15', head);
	const result = preflight('v0.0.0-dev.15', { ghMode: 'draft' });
	assert.equal(result.status, 1);
	assert.match(
		result.stdout,
		/::error::v0\.0\.0-dev\.15 has a draft release[^\n]*Delete that draft \(keep the tag\), then use 'Re-run failed jobs'/
	);
	assert.deepEqual(result.outputs, {});
});

check('an empty draft flag is refused, never read as "published"', () => {
	pushTag('v0.0.0-dev.16', head);
	const result = preflight('v0.0.0-dev.16', { ghMode: 'empty' });
	assert.equal(result.status, 1);
	assert.match(
		result.stdout,
		/::error::gh reported isDraft='' for v0\.0\.0-dev\.16; expected true or false\./
	);
	assert.deepEqual(result.outputs, {});
});

check('a failed release lookup fails the preflight instead of being read as "no release"', () => {
	pushTag('v0.0.0-dev.17', head);
	for (const [mode, message] of [
		['error', /HTTP 502: Bad Gateway/],
		['not-found', /HTTP 404: Not Found/]
	]) {
		const result = preflight('v0.0.0-dev.17', { ghMode: mode });
		assert.equal(result.status, 1, `gh mode ${mode}`);
		assert.match(result.stderr, message);
		assert.match(
			result.stdout,
			/::error::could not read the release of v0\.0\.0-dev\.17 \(gh exit 1\)/
		);
		assert.deepEqual(result.outputs, {});
	}
});

check('an unreachable origin fails the preflight instead of reading as "tag free"', () => {
	const offline = path.join(scratch, 'offline-work');
	git(scratch, 'clone', '--quiet', path.join(scratch, 'runner-origin.git'), offline);
	// A real candidate checkout is required before its source-bound catalogue.
	git(offline, 'checkout', '--quiet', '--detach', head);
	git(offline, 'remote', 'set-url', 'origin', path.join(scratch, 'no-such-origin.git'));
	const result = preflight('v0.0.0-dev.10', { cwd: offline });
	assert.notEqual(result.status, 0);
	assert.deepEqual(result.outputs, {});
});

// A later run published a newer tag of the channel while this one waited for
// a re-run. Tags that are not of the channel's series never count.
const series = repository('series', 'dev');
const seriesHead = commit(series, 'chore: the commit being released');
const seriesNewer = commit(series, 'chore: a newer commit');
pushTag('v0.0.0-dev.20', seriesHead, { repo: series });
pushTag('v0.0.0-dev.21', seriesNewer, { repo: series });
pushTag('v0.0.0-dev.99-hotfix', seriesNewer, { repo: series });
pushTag('v1.2.3', seriesHead, { repo: series });
pushTag('v1.3.0', seriesNewer, { repo: series });
pushTag('v9.9.9-rc.1', seriesNewer, { repo: series });
const inSeries = { cwd: series, sha: seriesHead };

check(
	'a newer release of the channel: a published older release finishes its notes but skips its feed',
	() => {
		const result = preflight('v0.0.0-dev.20', { ...inSeries, ghMode: 'published' });
		assert.equal(result.status, 0, result.stdout + result.stderr);
		assert.deepEqual(result.outputs, {
			create_tag: 'false',
			create_release: 'false',
			skip_feed: 'true'
		});
		assert.match(
			result.stdout,
			/::notice::v0\.0\.0-dev\.21 was published after this run planned v0\.0\.0-dev\.20\. Finishing the changelog and the notes/
		);
	}
);

check('a newer release of the channel: an orphan older tag is not released', () => {
	const result = preflight('v0.0.0-dev.20', { ...inSeries, ghMode: 'missing' });
	assert.equal(result.status, 1);
	assert.match(
		result.stdout,
		/::error::v0\.0\.0-dev\.21 was published after this run planned v0\.0\.0-dev\.20: publishing v0\.0\.0-dev\.20 now would put older code after it/
	);
	assert.deepEqual(result.outputs, {});
});

check('a newer release of the channel: a free older tag is not created', () => {
	const result = preflight('v0.0.0-dev.19', inSeries);
	assert.equal(result.status, 1);
	assert.match(
		result.stdout,
		/::error::v0\.0\.0-dev\.21 was published after this run planned v0\.0\.0-dev\.19/
	);
	assert.deepEqual(result.ghCalls, []);
	assert.deepEqual(result.outputs, {});
});

check('the stable channel compares stable tags only', () => {
	const older = preflight('v1.2.4', { ...inSeries, channel: 'main' });
	assert.equal(older.status, 1);
	assert.match(older.stdout, /::error::v1\.3\.0 was published after this run planned v1\.2\.4/);
	// v9.9.9-rc.1 and the dev tags sort higher but are not stable releases.
	const next = preflight('v1.4.0', { ...inSeries, channel: 'main' });
	assert.equal(next.status, 0, next.stdout + next.stderr);
	assert.deepEqual(next.outputs, {
		create_tag: 'true',
		create_release: 'true',
		skip_feed: 'false'
	});
});

// ==========================================
// ==========================================
// ======= 4/ The Release And Its Feed ======
// ==========================================
// ==========================================

const createScript = scriptOf(pipeline.step(releaseJob, CREATE_RELEASE), CREATE_RELEASE);

/** Runs the release creation with `prerelease`; returns the result and gh's arguments. */
function createRelease(
	prerelease,
	{ mode = '', missing = '', incomplete = '', fastPrerelease = 'false' } = {}
) {
	const assets = path.join(runner, 'release-assets');
	fs.rmSync(assets, { recursive: true, force: true });
	fs.mkdirSync(assets);
	for (const name of requiredAssets('dev')) fs.writeFileSync(path.join(assets, name), `${name}\n`);
	const ghArgs = stubLog('gh-args');
	const ghLog = stubLog('gh');
	const stateFile = stubLog('publish-state');
	const receipts = requiredAssets('dev')
		.filter((name) => name !== missing)
		.map((name) => ({
			name,
			size: fs.statSync(path.join(assets, name)).size,
			state: name === incomplete ? 'starter' : 'uploaded'
		}));
	if (mode === 'duplicate') receipts.push({ ...receipts[0] });
	if (mode === 'wrong-size') receipts[0].size += 1;
	if (mode === 'invalid-size') receipts[0].size = '1';
	if (mode === 'missing-size') delete receipts[0].size;
	if (mode === 'missing-state') delete receipts[0].state;
	fs.writeFileSync(stateFile, JSON.stringify({ isDraft: true, mode, assets: receipts }));
	const result = runScript(
		createScript,
		runner,
		{
			TAG: 'v0.0.0-dev.30',
			PRERELEASE: prerelease,
			ERGOPTI_FAST_PRERELEASE: fastPrerelease,
			TITLE: 'Ergopti v0.0.0-dev.30',
			GITHUB_SHA: head,
			GITHUB_REPOSITORY: REPOSITORY,
			GH_TOKEN: 'stub-token',
			GH_STUB_LOG: bashPath(ghLog),
			GH_STUB_ARGS: bashPath(ghArgs),
			GH_STUB_TAG: 'v0.0.0-dev.30',
			GH_STUB_REPO: REPOSITORY,
			GH_STUB_PUBLISH_STATE: stateFile,
			GH_STUB_PUBLISH_RESPONDER: bashPath(publishResponder),
			NODE_OPTIONS: [process.env.NODE_OPTIONS, `--require="${ghPreload.replaceAll('\\', '/')}"`]
				.filter(Boolean)
				.join(' ')
		},
		STUB_PATH
	);
	return {
		...result,
		args: linesOf(ghArgs),
		calls: linesOf(ghLog),
		state: JSON.parse(fs.readFileSync(stateFile, 'utf8'))
	};
}

check(
	'full release fixtures admit the real policy with explicit false (release-full-default-policy)',
	() => {
		const result = createRelease('true');
		assert.equal(result.status, 0, result.stdout + result.stderr);
		assert.ok(
			!result.args.includes('--notes'),
			'Full execution cannot borrow fast prerelease notes.'
		);
	}
);

// The temporary fast route is retired. Legacy flags are inert data, not an
// alternative admission capability; mandatory asset verification still gates
// every publication, including hostile or malformed former fast requests.
check(
	'retired fast request cannot change full release admission (release-fast-retired-full)',
	() => {
		const result = createRelease('true', { fastPrerelease: 'true' });
		assert.equal(result.status, 0, result.stdout + result.stderr);
		assert.ok(
			!result.args.includes('--notes'),
			'Retired fast flags cannot add unqualified bypass notes.'
		);
		assert.equal(
			result.state.isDraft,
			false,
			'Only the fully verified ordinary release publishes.'
		);
	}
);
check(
	'retired missing or malformed fast flags cannot bypass assets (release-fast-retired-input)',
	() => {
		for (const fastPrerelease of ['', 'TRUE', '1', 'true']) {
			const valid = createRelease('true', { fastPrerelease });
			assert.equal(valid.status, 0, valid.stdout + valid.stderr);
			assert.ok(
				!valid.args.includes('--notes'),
				'Every legacy flag retains full release semantics.'
			);
			const refused = createRelease('true', {
				fastPrerelease,
				mode: 'permanent-loss',
				missing: 'ErgoptiPlus.exe'
			});
			assert.notEqual(
				refused.status,
				0,
				'Missing mandatory assets must refuse even with a retired fast flag.'
			);
			assert.equal(
				refused.state.isDraft,
				true,
				'Refusal retains the draft instead of publishing incomplete assets.'
			);
			assert.ok(
				!refused.calls.some((call) => call.includes('--draft=false')),
				'No retired flag can reach the public publication port after failed asset verification.'
			);
		}
	}
);

/** Splits `gh release create` arguments into the tag, its options and its files. */
function parseCreate(args) {
	const options = {};
	const files = [];
	for (let index = 1; index < args.length; index++) {
		if (args[index] === '--prerelease') options.prerelease = true;
		else if (args[index] === '--draft') options.draft = true;
		else if (args[index].startsWith('--')) options[args[index].slice(2)] = args[++index];
		else files.push(args[index]);
	}
	return { tag: args[0], options, files: files.sort() };
}

check('release assets are verified while draft before publication can make them immutable', () => {
	const result = createRelease('true');
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.equal(
		parseCreate(result.args).options.draft,
		true,
		'a successful upload command cannot prove GitHub retained every asset'
	);
	const read = result.calls.findIndex((call) => call.includes('--json isDraft,assets'));
	const publish = result.calls.findIndex((call) => call.includes('--draft=false'));
	assert.ok(read > 0, 'the actual GitHub draft inventory must be read after creation');
	assert.ok(publish > read, 'publication must follow the successful draft inventory gate');
});

check('a silently lost RPM is reuploaded by name before publication', () => {
	const result = createRelease('true', { missing: 'ErgoptiPlus-linux-noarch.rpm' });
	assert.equal(result.status, 0, result.stdout + result.stderr);
	const uploads = result.calls.filter((call) => call.startsWith('release upload '));
	assert.deepEqual(uploads, [
		`release upload v0.0.0-dev.30 release-assets/ErgoptiPlus-linux-noarch.rpm --repo ${REPOSITORY} --clobber`
	]);
	assert.equal(result.state.isDraft, false);
	assert.equal(result.state.assets.length, requiredAssets('dev').length);
	const last = result.calls.at(-1);
	assert.match(
		last,
		/release view .* --json isDraft,assets$/,
		'the published state and inventory must be read back too'
	);
});

check('an incomplete upload receipt is repaired without reuploading healthy siblings', () => {
	const result = createRelease('true', { incomplete: 'ErgoptiPlus.app.zip' });
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.deepEqual(
		result.calls.filter((call) => call.startsWith('release upload ')),
		[
			`release upload v0.0.0-dev.30 release-assets/ErgoptiPlus.app.zip --repo ${REPOSITORY} --clobber`
		]
	);
	assert.equal(result.state.isDraft, false);
});

check('a wrong-size uploaded file must be replaced and read back before publication', () => {
	const result = createRelease('true', { mode: 'wrong-size' });
	assert.equal(result.status, 0, result.stdout + result.stderr);
	const name = requiredAssets('dev')[0];
	assert.deepEqual(
		result.calls.filter((call) => call.startsWith('release upload ')),
		[`release upload v0.0.0-dev.30 release-assets/${name} --repo ${REPOSITORY} --clobber`]
	);
	assert.equal(
		result.state.assets.find((asset) => asset.name === name).size,
		fs.statSync(path.join(runner, 'release-assets', name)).size
	);
	assert.equal(result.state.isDraft, false);
});

check('a permanently lost RPM stays a draft after the bounded repair attempts', () => {
	const result = createRelease('true', {
		mode: 'permanent-loss',
		missing: 'ErgoptiPlus-linux-noarch.rpm'
	});
	assert.equal(result.status, 1);
	assert.equal(result.state.isDraft, true);
	assert.equal(result.calls.filter((call) => call.startsWith('release upload ')).length, 2);
	assert.equal(result.calls.filter((call) => call.startsWith('release edit ')).length, 0);
	assert.match(result.stderr, /Release remains a draft.*ErgoptiPlus-linux-noarch\.rpm/);
});

for (const mode of [
	'malformed',
	'lookup-refusal',
	'duplicate',
	'invalid-size',
	'missing-size',
	'missing-state'
]) {
	check(`an invalid asset inventory (${mode}) never grants publication`, () => {
		const result = createRelease('true', { mode });
		assert.equal(result.status, 1);
		assert.equal(result.state.isDraft, true);
		assert.equal(result.calls.filter((call) => call.startsWith('release edit ')).length, 0);
		assert.equal(result.calls.filter((call) => call.startsWith('release upload ')).length, 0);
	});
}

check('an already published release is not granted draft repair or a second publication', () => {
	const result = createRelease('true', { mode: 'unexpected-published' });
	assert.equal(result.status, 1);
	assert.equal(result.calls.filter((call) => call.startsWith('release edit ')).length, 0);
	assert.equal(result.calls.filter((call) => call.startsWith('release upload ')).length, 0);
});

check('a refused repair stops before publication', () => {
	const result = createRelease('true', {
		mode: 'upload-refusal',
		missing: 'ErgoptiPlus-linux-noarch.rpm'
	});
	assert.equal(result.status, 1);
	assert.equal(result.state.isDraft, true);
	assert.equal(result.calls.filter((call) => call.startsWith('release upload ')).length, 1);
	assert.equal(result.calls.filter((call) => call.startsWith('release edit ')).length, 0);
});

for (const mode of ['publish-refusal', 'unacknowledged-publication']) {
	check(`a ${mode} cannot complete the release step or publish its feed`, () => {
		const result = createRelease('true', { mode });
		assert.equal(result.status, 1);
		assert.equal(result.state.isDraft, true);
		assert.equal(result.calls.filter((call) => call.startsWith('release edit ')).length, 1);
	});
}

check(
	'a dev release is created as a prerelease, on this commit, with every downloaded file',
	() => {
		const result = createRelease('true');
		assert.equal(result.status, 0, result.stdout + result.stderr);
		const created = parseCreate(result.args);
		assert.equal(created.tag, 'v0.0.0-dev.30');
		assert.deepEqual(created.options, {
			repo: REPOSITORY,
			draft: true,
			target: head,
			title: 'Ergopti v0.0.0-dev.30',
			prerelease: true
		});
		assert.deepEqual(
			created.files,
			requiredAssets('dev')
				.map((name) => `release-assets/${name}`)
				.sort()
		);
	}
);

check('a stable release is not a prerelease', () => {
	const result = createRelease('false');
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.deepEqual(parseCreate(result.args).options, {
		repo: REPOSITORY,
		draft: true,
		target: head,
		title: 'Ergopti v0.0.0-dev.30'
	});
});

check('an unreadable prerelease flag creates nothing', () => {
	const result = createRelease('');
	assert.equal(result.status, 1);
	assert.match(result.stdout, /::error::plan's prerelease output is '', expected true or false\./);
	assert.deepEqual(result.args, []);
});

const feedScript = scriptOf(pipeline.step(releaseJob, PUBLISH_FEED), PUBLISH_FEED);
const feedOrigin = path.join(scratch, 'runner-origin.git');

/**
 * Publishes the dev feed from `artifact`, the appcast this attempt downloaded,
 * with curl reading back `served`; returns the result and what origin holds.
 */
function publishFeed(artifact, { resumed = false, served = 'origin', published = '' } = {}) {
	const assets = path.join(runner, 'release-assets');
	fs.rmSync(assets, { recursive: true, force: true });
	fs.mkdirSync(assets);
	fs.writeFileSync(path.join(assets, 'appcast-dev.xml'), `${artifact}\n`);
	const temp = path.join(scratch, `feed-temp-${runCount + 1}`);
	fs.mkdirSync(temp);
	const curlLog = stubLog('curl');
	const ghLog = stubLog('gh');
	const url = `https://raw.githubusercontent.com/${REPOSITORY}/sparkle-appcasts/appcast-dev.xml?release=${head}`;
	const result = runScript(
		feedScript,
		runner,
		{
			ERGOPTI_CHANNEL: 'dev',
			TAG: 'v0.0.0-dev.14',
			RESUMED: resumed ? 'true' : 'false',
			GITHUB_SHA: head,
			GITHUB_REPOSITORY: REPOSITORY,
			RUNNER_TEMP: bashPath(temp),
			GH_TOKEN: 'stub-token',
			GH_STUB_LOG: bashPath(ghLog),
			GH_STUB_TAG: 'v0.0.0-dev.14',
			GH_STUB_REPO: REPOSITORY,
			GH_STUB_CHANNEL: 'dev',
			GH_STUB_PUBLISHED_FEED: published,
			CURL_STUB_LOG: bashPath(curlLog),
			CURL_STUB_URL: url,
			CURL_STUB_MODE: served,
			CURL_STUB_ORIGIN: bashPath(feedOrigin),
			CURL_STUB_CHANNEL: 'dev'
		},
		STUB_PATH
	);
	const onOrigin = spawnSync(
		'git',
		['--git-dir', feedOrigin, 'show', 'sparkle-appcasts:appcast-dev.xml'],
		{ env: GIT_ENV, encoding: 'utf8' }
	);
	return {
		...result,
		onOrigin: onOrigin.status === 0 ? onOrigin.stdout.trim() : null,
		curlCalls: linesOf(curlLog),
		ghCalls: linesOf(ghLog)
	};
}

check('a first release pushes its appcast to the feed branch and reads it back', () => {
	const result = publishFeed('<appcast>dev.14</appcast>');
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.equal(result.onOrigin, '<appcast>dev.14</appcast>');
	assert.equal(result.curlCalls.length, 1);
	assert.deepEqual(result.ghCalls, [], 'a first attempt publishes its own artifact');
});

check('a feed that does not read back as pushed fails the step', () => {
	const result = publishFeed('<appcast>dev.14 again</appcast>', { served: 'stale' });
	assert.notEqual(result.status, 0, 'a published copy that differs must fail the verification');
});

check(
	"a resumed release publishes the appcast attached to the release, not this attempt's artifact",
	() => {
		const result = publishFeed('<appcast>a rebuilt package</appcast>', {
			resumed: true,
			published: '<appcast>the published zip</appcast>'
		});
		assert.equal(result.status, 0, result.stdout + result.stderr);
		assert.equal(result.onOrigin, '<appcast>the published zip</appcast>');
		assert.equal(result.ghCalls.length, 1);
	}
);

// The existing actual preflight must distinguish missing new output from an
// already published historical inventory, without guessing release existence.
check('fresh publication refuses missing preferred archive', () => {
	const publication = require('../build/macos-release-publication.cjs');
	const result = preflight('v0.0.0-dev.20', { missingAsset: publication.bindings()[0].name });
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /Public macOS archive operation refused/);
	assert.deepEqual(result.outputs, {});
});
check('fresh publication refuses missing preferred signature', () => {
	const publication = require('../build/macos-release-publication.cjs');
	const result = preflight('v0.0.0-dev.20', {
		missingAsset: `_${publication.bindings()[0].name}.sig`
	});
	assert.notEqual(result.status, 0);
	assert.deepEqual(result.outputs, {});
});
check('published historical resume does not require rebuilt preferred archive', () => {
	const publication = require('../build/macos-release-publication.cjs');
	const result = preflight('v0.0.0-dev.13', {
		ghMode: 'published',
		missingAsset: publication.bindings()[0].name
	});
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.equal(result.outputs.create_release, 'false');
});

// Actual preflight source remains unchanged: these corrupt only private bytes.
for (const name of MANAGED_PUBLICATION_ASSETS) {
	check('fresh publication refuses missing managed asset ' + name, () => {
		const result = preflight('v0.0.0-dev.51', { missingAsset: name });
		assert.notEqual(result.status, 0);
		assert.deepEqual(result.outputs, {});
		assert.deepEqual(result.ghCalls, [], 'refused bytes cause no publication lookup');
	});
}
check('both actual native matrix uploads resolve to their exact archive filenames', () => {
	const layout = uploadedLayout('dev');
	for (const name of MANAGED_PUBLICATION_ASSETS) {
		assert.equal(layout.get(name), name, 'single-file native/catalogue artifacts are flat');
	}
});
check('fresh publication refuses changed managed asset bytes', () => {
	const result = preflight('v0.0.0-dev.52', {
		managedMutation: (assets) =>
			fs.appendFileSync(path.join(assets, MANAGED_PUBLICATION_ASSETS[0]), 'foreign')
	});
	assert.notEqual(result.status, 0);
	assert.deepEqual(result.outputs, {});
	assert.deepEqual(result.ghCalls, []);
});
check('fresh publication refuses stale managed catalogue source', () => {
	const result = preflight('v0.0.0-dev.53', {
		managedMutation: (assets) => {
			const file = path.join(assets, MANAGED_PUBLICATION_ASSETS[2]);
			const catalogue = JSON.parse(fs.readFileSync(file, 'utf8'));
			catalogue.repository_commit = '0'.repeat(40);
			fs.writeFileSync(file, JSON.stringify(catalogue) + '\n');
		}
	});
	assert.notEqual(result.status, 0);
	assert.deepEqual(result.outputs, {});
	assert.deepEqual(result.ghCalls, []);
});

// ==========================================
// ==========================================
// ======= 5/ The Resume Wiring =============
// ==========================================
// ==========================================

check('the release job skips only the three steps the preflight decides on', () => {
	const releaseSteps = pipeline.steps(releaseJob);
	const indexOf = (name) => releaseSteps.findIndex((candidate) => candidate.name === name);
	const preflightStep = pipeline.step(releaseJob, PREFLIGHT);
	assert.equal(pipeline.stepField(preflightStep, 'id'), 'preflight');
	assert.match(
		preflightStep,
		/^ {10}GH_TOKEN: \$\{\{ github\.token \}\}$/m,
		'the preflight reads the release with the job token'
	);
	const conditional = {
		[CREATE_TAG]: "steps.preflight.outputs.create_tag == 'true'",
		[CREATE_RELEASE]: "steps.preflight.outputs.create_release == 'true'",
		[PUBLISH_FEED]: "steps.preflight.outputs.skip_feed != 'true'"
	};
	for (const candidate of releaseSteps) {
		assert.equal(
			pipeline.stepField(candidate.body, 'if'),
			conditional[candidate.name] ?? null,
			`release step "${candidate.name}" must ${conditional[candidate.name] ? `run if ${conditional[candidate.name]}` : 'always run'}`
		);
	}
	assert.ok(
		indexOf(PREFLIGHT) < indexOf(CREATE_TAG) &&
			indexOf(CREATE_TAG) < indexOf(CREATE_RELEASE) &&
			indexOf(CREATE_RELEASE) < indexOf(PUBLISH_FEED),
		'the preflight, the tag, the release and the feed run in that order'
	);
	// A resumed attempt must still finish the feed, the changelog and the notes.
	assert.ok(
		releaseSteps.length - indexOf(CREATE_RELEASE) - 1 >= 3,
		`only ${releaseSteps.length - indexOf(CREATE_RELEASE) - 1} step(s) follow the release creation`
	);
});

check("each script's env carries the plan output or preflight decision it reads", () => {
	const envOf = (name) => pipeline.step(releaseJob, name).split('\n');
	for (const [name, lines] of [
		[
			CREATE_RELEASE,
			[
				'          TAG: ${{ needs.validate.outputs.tag }}',
				'          PRERELEASE: ${{ needs.validate.outputs.prerelease }}',
				'          TITLE: ${{ needs.validate.outputs.title }}',
				'          GH_TOKEN: ${{ github.token }}'
			]
		],
		[
			PUBLISH_FEED,
			[
				'          ERGOPTI_CHANNEL: ${{ needs.validate.outputs.channel }}',
				'          TAG: ${{ needs.validate.outputs.tag }}',
				"          RESUMED: ${{ steps.preflight.outputs.create_release == 'false' }}",
				'          GH_TOKEN: ${{ github.token }}'
			]
		],
		[
			PREFLIGHT,
			[
				'          TAG: ${{ needs.validate.outputs.tag }}',
				'          CHANNEL: ${{ needs.validate.outputs.channel }}'
			]
		]
	]) {
		for (const line of lines)
			assert.ok(envOf(name).includes(line), `"${name}" must set ${line.trim()}`);
	}
	assert.match(
		pipeline.job('release'),
		/^ {6}LINUX_BUNDLE_ASSET: \$\{\{ needs\.validate\.outputs\.linux_bundle \}\}$/m,
		'the release job must give the preflight and the notes the bundle name plan resolved'
	);
});

check(
	'real qualification helper closes publication on foreign context and preserves full defaults',
	() => {
		const work = repository('qualification-publication', 'main');
		const marker = path.join(work, 'publication-marker');
		const script =
			'set -euo pipefail\nnode tools/ci/dev-release-qualification.cjs --publication-admit >/dev/null\nprintf published > publication-marker';
		const foreign = {
			ERGOPTI_NATIVE_QUALIFICATION_PROFILE: 'stable-v1-20261009-macos-native-deferred',
			GITHUB_ACTIONS: 'true',
			GITHUB_REPOSITORY: 'adrienm7/ergopti',
			GITHUB_EVENT_NAME: 'push',
			GITHUB_REF: 'refs/heads/main',
			GITHUB_SHA: 'a'.repeat(40),
			ERGOPTI_DEV_RELEASE_RELEASE: 'true',
			ERGOPTI_DEV_RELEASE_PRERELEASE: 'false',
			ERGOPTI_DEV_RELEASE_CHANNEL: 'main',
			ERGOPTI_DEV_RELEASE_TAG: 'v1.0.1',
			ERGOPTI_DEV_RELEASE_VERSION: '1.0.1'
		};
		const refused = runScript(script, work, foreign);
		assert.notEqual(refused.status, 0);
		assert.match(refused.stderr, /not authorized/);
		assert.equal(
			fs.existsSync(marker),
			false,
			'refused admission cannot reach the publication port'
		);
		const ordinary = runScript(script, work, {
			...foreign,
			ERGOPTI_NATIVE_QUALIFICATION_PROFILE: ''
		});
		assert.equal(ordinary.status, 0, ordinary.stdout + ordinary.stderr);
		assert.equal(
			fs.readFileSync(marker, 'utf8'),
			'published',
			'full default must execute the real copied helper'
		);
	}
);

check(
	'real unsigned publication helper refuses a missing receipt before its publication port',
	() => {
		const work = repository('unsigned-publication', 'main');
		const sha = commit(work, 'independent unsigned boundary fixture');
		const marker = path.join(work, 'unsigned-marker');
		const script =
			'set -euo pipefail\nnode tools/ci/windows-stable-signing.cjs --publication-admit >/dev/null\nprintf published > unsigned-marker';
		const env = {
			GITHUB_ACTIONS: 'true',
			GITHUB_REPOSITORY: REPOSITORY,
			GITHUB_EVENT_NAME: 'push',
			GITHUB_REF: 'refs/heads/main',
			GITHUB_SHA: sha,
			ERGOPTI_DEV_RELEASE_RELEASE: 'true',
			ERGOPTI_DEV_RELEASE_PRERELEASE: 'false',
			ERGOPTI_DEV_RELEASE_CHANNEL: 'main',
			ERGOPTI_DEV_RELEASE_TAG: 'v1.0.1',
			ERGOPTI_DEV_RELEASE_VERSION: '1.0.1',
			ERGOPTI_WINDOWS_SIGNING_CONFIGURED: 'false'
		};
		const refused = runScript(script, work, env);
		assert.notEqual(refused.status, 0);
		assert.match(refused.stderr, /not admitted/);
		assert.equal(
			fs.existsSync(marker),
			false,
			'missing evidence must not reach the publication port'
		);
		const full = runScript(script, work, { ...env, ERGOPTI_WINDOWS_SIGNING_CONFIGURED: 'true' });
		assert.equal(full.status, 0, full.stdout + full.stderr);
		assert.equal(
			fs.readFileSync(marker, 'utf8'),
			'published',
			'complete signed configuration retains full defaults'
		);
	}
);

if (failures.length > 0) {
	console.error('[FAIL] a release re-run can republish old code or cannot finish a release:');
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}

console.log(
	'[OK] plan never republishes a tagged commit and bumps from every subject; the release preflight ' +
		'resumes or stops on every tag state, and the release and its feed publish what was gated.'
);
