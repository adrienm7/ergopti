// tools/test/test-package-builds-stamp-commit.cjs

/**
 * ==============================================================================
 * MODULE: Package Build Commit Stamp Guard
 * DESCRIPTION:
 * Every package the CI pipeline builds (`.github/workflows/ci.yml` and the OS
 * workflows it calls) must carry the commit it was built from, because an
 * installed package has no .git to ask.
 *
 * ROOT CAUSE ENCODED:
 * The packaged ErgoptiPlus.app showed "Last git commit: unknown" in its
 * System diagnostics: the healthcheck ran `git rev-parse` inside
 * Contents/Resources, and the boot snapshot only read .git. Windows had solved
 * this long before with the BUNDLE_COMMIT stamp; the macOS and Linux packages
 * (.deb, .rpm, AppImage, Flatpak, tarball) had nothing. They now share one
 * mechanism — tools/build/write_build_stamp.sh writes `build_stamp.txt` at the
 * root of the shared tree they ship, and _shared/lua/diagnostics/snapshot.lua
 * reads it — and this guard fails as soon as a build path stops stamping.
 *
 * FEATURES & RATIONALE:
 * 1. Every pipeline workflow is parsed into jobs and steps, so the check follows
 *    the steps that really run a build entry point instead of trusting a text
 *    search. tools/test/ci-pipeline.cjs lists the files CI actually calls.
 * 2. Each build entry point must be handed the workflow's own commit, each
 *    Linux packager must verify the stamp in the tree it packages, and each
 *    tarball must be verified before it is packed.
 * 3. The stamp's file name and key are declared by the writer and by the Lua
 *    reader; they are compared here so they cannot drift apart.
 * 4. The guard proves it can fail: it is re-run on a copy of each workflow with
 *    one stamp removed and must report it.
 * 5. The Linux build also stamps the release version: the Linux driver has no
 *    other version source (linux/infra/version.lua reads the stamp), and a fixed
 *    literal there once made every install report a release that never existed.
 *    One assembly serves CI and release, so every build-linux-driver.sh step
 *    must hand ERGOPTI_BUILD_VERSION the version its box receives (empty outside
 *    a release, which writes a commit-only stamp), and the macOS build its
 *    ERGOPTI_VERSION the same way.
 * 6. The version reaches the lanes only through ci.yml: each OS caller must
 *    pass the version output of validate's plan, or a lane would stamp an empty
 *    version on a release.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const pipeline = require('./ci-pipeline.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS_WORKFLOW_REL = '.github/workflows/ci-windows.yml';
const WRITER_REL = 'tools/build/write_build_stamp.sh';
const READER_REL = 'static/ergopti_plus/_shared/lua/diagnostics/snapshot.lua';
const WINDOWS_BUNDLE_REL = 'static/ergopti_plus/windows/infra/bundle.ahk';

// The scripts that assemble a shipped tree and therefore write the stamp.
const STAMPING_BUILDS = {
	'tools/build/build_macos_app.sh':
		/bash\s+tools\/build\/build_macos_app\.sh(?!\s+--native-helper-only)/,
	'tools/build/build-linux-driver.sh': /bash\s+tools\/build\/build-linux-driver\.sh/
};

// The Linux packagers, which package build/linux/_shared and must verify it.
const PACKAGERS = ['deb', 'rpm', 'appimage', 'flatpak'].map(
	(kind) => `tools/build/build-linux-${kind}.sh`
);
const PKGBUILD_REL = 'tools/build/PKGBUILD';

const COMMIT_ENV = /^ERGOPTI_BUILD_COMMIT:\s*\$\{\{\s*github\.sha\s*\}\}\s*$/;
const VERSION_ENV = /^ERGOPTI_BUILD_VERSION:\s*\$\{\{\s*inputs\.version\s*\}\}\s*$/;
const MACOS_VERSION_ENV = /^ERGOPTI_VERSION:\s*\$\{\{\s*inputs\.version\s*\}\}\s*$/;
const CALLER_VERSION = /^ {6}version:\s*\$\{\{\s*needs\.validate\.outputs\.version\s*\}\}\s*$/m;
const VERSIONED_BOXES = ['macos', 'windows', 'linux'];

// Floors — today: 1 macOS build and 1 Linux assembly, 4 packager runs,
// 1 tarball. A parse that found fewer stopped reading the workflow.
const MIN_STAMPING_STEPS = 2;
const MIN_PACKAGER_STEPS = 4;
const MIN_TARBALL_STEPS = 1;
// Today: one job assembles the Linux tree, for CI and release alike.
const MIN_RELEASE_LINUX_STEPS = 1;

/** Returns the column of the first non-space character, or -1 for a blank line. */
function indentOf(line) {
	if (line.trim() === '') return -1;
	return line.length - line.trimStart().length;
}

/** Reads a repository file as text. */
function read(rel) {
	return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

// ================================
// ================================
// ======= 1/ Parse Workflow ======
// ================================
// ================================

/**
 * Collects the `key: value` entries of the mapping that starts below `start`.
 * @param {string[]} lines
 * @param {number} start Index of the line holding the mapping's key.
 * @returns {string[]} Trimmed child lines.
 */
function childLines(lines, start) {
	const own = indentOf(lines[start]);
	const out = [];
	for (let i = start + 1; i < lines.length; i++) {
		const ind = indentOf(lines[i]);
		if (ind === -1) continue;
		if (ind <= own) break;
		out.push(lines[i].trim());
	}
	return out;
}

/**
 * Splits a workflow into jobs and their steps.
 * @param {string} text Workflow YAML.
 * @returns {Array<{name: string, env: string[], steps: Array<{line: number, name: string, run: string, env: string[]}>}>}
 */
function parseJobs(text) {
	const lines = text.split(/\r?\n/);
	const jobsAt = lines.findIndex((line) => /^jobs:\s*$/.test(line));
	if (jobsAt < 0) return [];
	const jobs = [];
	let job = null;
	for (let i = jobsAt + 1; i < lines.length; i++) {
		const line = lines[i];
		const ind = indentOf(line);
		if (ind === 0) break;
		const jobMatch = line.match(/^ {2}([A-Za-z0-9_-]+):\s*$/);
		if (jobMatch) {
			job = { name: jobMatch[1], env: [], steps: [] };
			jobs.push(job);
			continue;
		}
		if (!job) continue;
		if (/^ {4}env:\s*$/.test(line)) job.env = childLines(lines, i);
		const stepMatch = line.match(/^( {6})- /);
		if (!stepMatch) continue;
		const stepIndent = 6;
		const body = [line.slice(stepIndent + 2)];
		let j = i + 1;
		for (; j < lines.length; j++) {
			const inner = indentOf(lines[j]);
			if (inner === -1) {
				body.push('');
				continue;
			}
			if (inner <= stepIndent) break;
			body.push(lines[j].slice(stepIndent + 2));
		}
		const step = { line: i + 1, name: '', run: '', env: [] };
		for (let k = 0; k < body.length; k++) {
			const nameMatch = body[k].match(/^name:\s*(.*)$/);
			if (nameMatch) step.name = nameMatch[1].replace(/^['"]|['"]$/g, '');
			const runMatch = body[k].match(/^run:\s*(.*)$/);
			if (runMatch) {
				const inline = runMatch[1].trim();
				if (inline && inline !== '|' && inline !== '>') {
					step.run = inline;
				} else {
					const block = [];
					for (let m = k + 1; m < body.length && (body[m] === '' || /^\s/.test(body[m])); m++) {
						block.push(body[m].trim());
					}
					step.run = block.join('\n');
				}
			}
			if (/^env:\s*$/.test(body[k])) {
				for (let m = k + 1; m < body.length && /^\s/.test(body[m]); m++)
					step.env.push(body[m].trim());
			}
		}
		job.steps.push(step);
		i = j - 1;
	}
	return jobs;
}

// =================================
// =================================
// ======= 2/ Check Workflow =======
// =================================
// =================================

/**
 * Checks that every package build in a workflow stamps the commit.
 * @param {string} text Workflow YAML.
 * @param {string} rel The workflow's repository-relative path, for messages.
 * @returns {{errors: string[], stamping: number, packagers: number, tarballs: number, releaseLinux: number}}
 */
function checkWorkflow(text, rel) {
	const errors = [];
	let stamping = 0;
	let packagers = 0;
	let tarballs = 0;
	let releaseLinux = 0;
	for (const job of parseJobs(text)) {
		let assembledLinux = false;
		for (const step of job.steps) {
			const where = `${rel}:${step.line} (job ${job.name}, step "${step.name}")`;
			const env = step.env.concat(job.env);
			for (const [script, invocation] of Object.entries(STAMPING_BUILDS)) {
				if (!invocation.test(step.run)) continue;
				stamping++;
				const hasCommit = env.some((entry) => COMMIT_ENV.test(entry));
				if (!hasCommit) {
					errors.push(
						`${where} runs ${script} without ERGOPTI_BUILD_COMMIT: \${{ github.sha }} — ` +
							'the package it builds could not name the commit it was built from'
					);
				}
				if (
					script.endsWith('build_macos_app.sh') &&
					!env.some((entry) => MACOS_VERSION_ENV.test(entry))
				) {
					errors.push(
						`${where} builds the macOS app without ERGOPTI_VERSION: \${{ inputs.version }} — ` +
							'a release app would report the 0.0.0-dev placeholder'
					);
				}
				if (script.endsWith('build-linux-driver.sh')) {
					assembledLinux = true;
					// The one assembly serves CI and release alike.
					releaseLinux++;
					if (!env.some((entry) => VERSION_ENV.test(entry))) {
						errors.push(
							`${where} assembles the Linux tree without ERGOPTI_BUILD_VERSION: ` +
								'${{ inputs.version }} — a release driver would report no release version'
						);
					}
				}
			}
			for (const packager of PACKAGERS) {
				if (!step.run.includes(`bash ${packager}`)) continue;
				packagers++;
				if (!assembledLinux) {
					errors.push(
						`${where} runs ${packager} before any build-linux-driver.sh in its job — ` +
							'it would package a tree nobody stamped'
					);
				}
			}
			// A tar command may continue over backslash-ended lines.
			if (/\btar\s+-czf\b[^\n]*(?:\\\n[^\n]*)*\b_shared\b/.test(step.run)) {
				tarballs++;
				const verify = step.run.indexOf('write_build_stamp.sh verify build/linux/_shared');
				const tar = step.run.search(/\btar\s+-czf\b/);
				if (verify < 0 || verify > tar) {
					errors.push(
						`${where} packs a tarball without first running ` +
							'`bash tools/build/write_build_stamp.sh verify build/linux/_shared`'
					);
				}
			}
		}
	}
	return { errors, stamping, packagers, tarballs, releaseLinux };
}

/**
 * Checks that ci.yml hands the plan's version to every OS lane.
 * @param {string} text ci.yml YAML.
 * @returns {string[]} Errors.
 */
function checkVersionChain(text) {
	const errors = [];
	const jobs = pipeline.jobsOfText(text, pipeline.ENTRY_REL);
	for (const box of VERSIONED_BOXES) {
		const caller = jobs.find((job) => job.id === box);
		if (!caller || pipeline.field(caller.body, 'uses') === null) {
			errors.push(`${pipeline.ENTRY_REL} no longer calls the ${box} box as job \`${box}\``);
		} else if (!CALLER_VERSION.test(caller.body)) {
			errors.push(
				`${pipeline.ENTRY_REL}:${caller.line} (job ${box}) must pass ` +
					'version: ${{ needs.validate.outputs.version }} — the lane would stamp no release version'
			);
		}
	}
	return errors;
}

// =================================
// =================================
// ======= 3/ Run The Guard ========
// =================================
// =================================

const errors = [];
const workflows = pipeline.files();
const result = { errors: [], stamping: 0, packagers: 0, tarballs: 0, releaseLinux: 0 };
for (const { rel, text } of workflows) {
	const found = checkWorkflow(text, rel);
	result.errors.push(...found.errors);
	for (const key of ['stamping', 'packagers', 'tarballs', 'releaseLinux'])
		result[key] += found[key];
}
errors.push(...result.errors);
errors.push(...checkVersionChain(pipeline.file(pipeline.ENTRY_REL)));

// validate's plan is where the version comes from; the callers only forward it.
const planMeta = pipeline.step(pipeline.job('validate'), 'Compute tag and version');
if (
	!/^\s+version:\s*\$\{\{\s*steps\.meta\.outputs\.version\s*\}\}\s*$/m.test(
		pipeline.job('validate')
	) ||
	!planMeta.includes('emit version "$version"')
) {
	errors.push(
		`${pipeline.ENTRY_REL}: validate's plan no longer emits the release version its callers forward`
	);
}

if (result.stamping < MIN_STAMPING_STEPS) {
	errors.push(
		`found only ${result.stamping} build step(s) (floor ${MIN_STAMPING_STEPS}) — the step parse drifted`
	);
}
if (result.packagers < MIN_PACKAGER_STEPS) {
	errors.push(
		`found only ${result.packagers} packager run(s) (floor ${MIN_PACKAGER_STEPS}) — the step parse drifted`
	);
}
if (result.releaseLinux < MIN_RELEASE_LINUX_STEPS) {
	errors.push(
		`found only ${result.releaseLinux} release Linux assembly step(s) ` +
			`(floor ${MIN_RELEASE_LINUX_STEPS}) — the job parse drifted`
	);
}
if (result.tarballs < MIN_TARBALL_STEPS) {
	errors.push(
		`found only ${result.tarballs} tarball step(s) (floor ${MIN_TARBALL_STEPS}) — the step parse drifted`
	);
}

/** Removes one env field belonging to an actual parsed stamping build. */
function stampingOwnerMutation(text, rel, key) {
	const parsed = parseJobs(text);
	const jobs = pipeline.jobsOfText(text, rel);
	for (const job of parsed) {
		for (const step of job.steps) {
			const stamps = Object.entries(STAMPING_BUILDS).some(
				([script, invocation]) =>
					invocation.test(step.run) &&
					(key === 'ERGOPTI_BUILD_COMMIT' ||
						(key === 'ERGOPTI_BUILD_VERSION' && script.endsWith('build-linux-driver.sh')) ||
						(key === 'ERGOPTI_VERSION' && script.endsWith('build_macos_app.sh')))
			);
			if (!stamps) continue;
			const field = new RegExp(`^${key}:`);
			const stepFields = step.env.filter((entry) => field.test(entry));
			const jobFields = job.env.filter((entry) => field.test(entry));
			if (stepFields.length + jobFields.length === 0) continue;
			if (stepFields.length + jobFields.length !== 1)
				throw new Error(`${rel}: stamping owner ${key} must have one env field`);
			const matchingJobs = jobs.filter((candidate) => candidate.id === job.name);
			if (matchingJobs.length !== 1) throw new Error(`${rel}: stamping owner job must be unique`);
			const jobBody = matchingJobs[0].body;
			const body = stepFields.length ? pipeline.step(jobBody, step.name) : jobBody;
			const envIndent = stepFields.length ? 8 : 4;
			const lines = body.split('\n');
			const envAt = lines.flatMap((line, index) =>
				line === ' '.repeat(envIndent) + 'env:' ? [index] : []
			);
			if (envAt.length !== 1) throw new Error(`${rel}: stamping owner env mapping must be unique`);
			const entries = [];
			for (let at = envAt[0] + 1; at < lines.length; at++) {
				const ind = indentOf(lines[at]);
				if (ind === -1) continue;
				if (ind <= envIndent) break;
				if (ind === envIndent + 2 && field.test(lines[at].trim())) entries.push(at);
			}
			if (entries.length !== 1 || text.split(body).length !== 2)
				throw new Error(`${rel}: stamping owner field boundary must be unique`);
			lines.splice(entries[0], 1);
			const mutated = text.replace(body, () => lines.join('\n'));
			if (mutated === text) throw new Error(`${rel}: stamping owner mutation must change text`);
			return mutated;
		}
	}
	throw new Error(`${rel}: no parsed stamping owner supplies ${key}`);
}

// The guard must be able to fail: dropping one stamp or one version, in every
// workflow that carries one, has to be reported.
for (const [key, owners] of [
	['ERGOPTI_BUILD_COMMIT', 2],
	['ERGOPTI_BUILD_VERSION', 1],
	['ERGOPTI_VERSION', 1]
]) {
	const entry = new RegExp(`^\\s*${key}:.*\\r?\\n`, 'm');
	const carriers = workflows.filter(({ text }) => entry.test(text));
	if (carriers.length < owners) {
		errors.push(
			`only ${carriers.length} pipeline workflow(s) set ${key} (floor ${owners}) — the build steps moved`
		);
	}
	for (const { rel, text } of carriers) {
		const mutated = stampingOwnerMutation(text, rel, key);
		if (checkWorkflow(mutated, rel).errors.length === 0) {
			errors.push(
				`self-check: removing the first ${key} entry of ${rel} went unnoticed — this guard cannot fail`
			);
		}
	}
}
const ciText = pipeline.file(pipeline.ENTRY_REL);
const chainMutated = ciText.replace(CALLER_VERSION, "      version: ''");
if (chainMutated === ciText) {
	errors.push(`${pipeline.ENTRY_REL} passes the plan's version to no lane at all`);
} else if (checkVersionChain(chainMutated).length === 0) {
	errors.push(
		"self-check: dropping the plan's version from an OS caller went unnoticed — this guard cannot fail"
	);
}

// Each build entry point writes the stamp; each packager verifies its copy.
for (const script of Object.keys(STAMPING_BUILDS)) {
	if (!/write_build_stamp\.sh"?\s+write\s/.test(read(script))) {
		errors.push(
			`${script} no longer calls write_build_stamp.sh write — its packages would ship no commit`
		);
	}
}
for (const packager of PACKAGERS) {
	if (!/write_build_stamp\.sh"?\s+verify\s/.test(read(packager))) {
		errors.push(`${packager} no longer verifies the build stamp in the tree it packages`);
	}
}

// The Arch package is built by makepkg, outside the workflow, so the workflow
// parse above never sees it: it must assemble through the stamping driver
// builder and verify the tree it installs.
const pkgbuild = read(PKGBUILD_REL);
if (!STAMPING_BUILDS['tools/build/build-linux-driver.sh'].test(pkgbuild)) {
	errors.push(
		`${PKGBUILD_REL} no longer assembles through build-linux-driver.sh, which writes the stamp`
	);
}
if (!/write_build_stamp\.sh\s+verify\s+"\$pkgdir\/usr\/lib\/ergopti\/_shared"/.test(pkgbuild)) {
	errors.push(`${PKGBUILD_REL} no longer verifies the build stamp in the tree it installs`);
}

// One stamp format: what the writer writes is what the Lua drivers read.
const writer = read(WRITER_REL);
const reader = read(READER_REL);
for (const [shellName, luaName] of [
	['BUILD_STAMP_FILE', 'BUILD_STAMP_FILE'],
	['BUILD_STAMP_COMMIT_KEY', 'BUILD_STAMP_COMMIT_KEY'],
	['BUILD_STAMP_VERSION_KEY', 'BUILD_STAMP_VERSION_KEY']
]) {
	const shell = writer.match(new RegExp(`^${shellName}="([^"]+)"$`, 'm'));
	const lua = reader.match(new RegExp(`^M\\.${luaName} = "([^"]+)"$`, 'm'));
	if (!shell || !lua) {
		errors.push(`${shellName} is no longer declared in ${WRITER_REL} and ${READER_REL}`);
	} else if (shell[1] !== lua[1]) {
		errors.push(
			`${shellName} differs: ${WRITER_REL} writes "${shell[1]}", ${READER_REL} reads "${lua[1]}"`
		);
	}
}

// Windows keeps its own stamp; the release build must still fill it.
if (!/BUNDLE_COMMIT := "__BUNDLE_COMMIT__"/.test(read(WINDOWS_BUNDLE_REL))) {
	errors.push(`${WINDOWS_BUNDLE_REL} no longer declares the __BUNDLE_COMMIT__ placeholder`);
}
if (
	!/Replace\("__BUNDLE_COMMIT__",\s*"\$\{\{ github\.sha \}\}"\)/.test(
		pipeline.step(
			pipeline.job('package-windows'),
			'Stamp BUNDLE_VERSION, BUNDLE_RELEASE_URL, BUNDLE_CHANNEL'
		)
	)
) {
	errors.push(
		`${WINDOWS_WORKFLOW_REL} no longer stamps BUNDLE_COMMIT with github.sha in the Windows build`
	);
}
if (pipeline.locate('package-windows').file !== WINDOWS_WORKFLOW_REL) {
	errors.push(`the Windows release build must live in ${WINDOWS_WORKFLOW_REL}`);
}

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] a package build does not stamp the commit it was built from:\x1b[0m'
	);
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${result.stamping} build step(s), ${result.packagers} packager run(s) and ` +
		`${result.tarballs} tarball(s) all ship the commit stamp.\x1b[0m`
);
