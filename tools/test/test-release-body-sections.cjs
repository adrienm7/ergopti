// tools/test/test-release-body-sections.cjs

/**
 * ==============================================================================
 * MODULE: Release Body Sections Regression Test
 * DESCRIPTION:
 * The in-app Versions pages must show a release's changelog before its
 * downloads, whatever order github.com needs. The shared splitter
 * (_shared/ui/changelog/release_body.js) is replayed against every body format
 * CI has published, against the body the current workflow actually writes, and
 * against a body rebuilt from the public Atom feed.
 *
 * ROOT CAUSE ENCODED:
 * de5ef9ebf moved the downloads above a folded changelog for github.com, and
 * every in-app viewer rendered the body verbatim, so the changelog ended up
 * last, behind literal <details> tags. Nothing in the body marked where a
 * section started, so no viewer could reorder it.
 *
 * FEATURES & RATIONALE:
 * 1. Real CI body: the release-body step of .github/workflows/ci.yml is
 *    interpreted (heredocs, echo lines inside the body group, the changelog
 *    sed) instead of being copied into a fixture, so a workflow edit that drops
 *    or garbles a section marker fails here. An unrecognised statement throws
 *    rather than being skipped.
 * 2. Shared vectors: _shared/tests/corpus/updater/release_body_vectors.json is
 *    the cross-driver contract; the Windows native notes view replays the same
 *    file through its port.
 * 3. Atom path: GitHub strips comments from rendered notes, so a feed body has
 *    no markers and must split on the fold and headings.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const CHANGELOG_UI = path.join(SHARED, 'ui', 'changelog');
const CORPUS = path.join(SHARED, 'tests', 'corpus', 'updater');
const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'ci.yml');
const BODY_STEP = 'Write release body with platform sections';
const MIN_VECTORS = 8;

const failures = [];

function expect(condition, message) {
	if (!condition) failures.push(message);
}

// ==========================================
// ==========================================
// ======= 1/ Page Modules =================
// ==========================================
// ==========================================

/** Loads the splitter and the feed reader exactly as the page ships them. */
function loadModules() {
	const sandbox = { console, URL };
	sandbox.window = sandbox;
	vm.createContext(sandbox);
	for (const file of ['release_body.js', 'atom_feed.js']) {
		vm.runInContext(fs.readFileSync(path.join(CHANGELOG_UI, file), 'utf8'), sandbox, { filename: file });
	}
	if (typeof sandbox.splitReleaseBody !== 'function') throw new Error('release_body.js exports no splitReleaseBody');
	return sandbox;
}

// ==========================================
// ==========================================
// ======= 2/ CI Release Body ==============
// ==========================================
// ==========================================

// Changelog shaped like tools/build/build_changelog.py output, including a
// commit body that mentions the structural tokens in prose.
const CHANGELOG_MD = [
	'## Changelog',
	'',
	'_Commits since [`v1.2.2`](https://github.com/adrienm7/ergopti/releases/tag/v1.2.2)._',
	'',
	'### Features',
	'',
	'- **Changelog: Show the changelog first**',
	'  The body explains why, and mentions <details> and ## Downloads in prose.',
	'### Fix',
	'',
	'- **Ci: Mark the release body sections**',
	'---',
	''
].join('\n');

/** Returns the `run: |` script of the release-body step, dedented. */
function releaseBodyScript() {
	const lines = fs.readFileSync(WORKFLOW, 'utf8').replace(/\r\n?/g, '\n').split('\n');
	const nameAt = lines.findIndex((line) => line.trim() === `- name: ${BODY_STEP}`);
	if (nameAt === -1) throw new Error(`ci.yml has no "${BODY_STEP}" step`);
	const stepIndent = lines[nameAt].indexOf('-');
	let runAt = -1;
	for (let i = nameAt + 1; i < lines.length; i++) {
		if (lines[i].trim() !== '' && lines[i].search(/\S/) <= stepIndent) break;
		if (/^\s*run: \|\s*$/.test(lines[i])) {
			runAt = i;
			break;
		}
	}
	if (runAt === -1) throw new Error(`the "${BODY_STEP}" step has no run: | block`);
	const keyIndent = lines[runAt].search(/\S/);
	const block = [];
	for (let i = runAt + 1; i < lines.length; i++) {
		if (lines[i].trim() !== '' && lines[i].search(/\S/) <= keyIndent) break;
		block.push(lines[i]);
	}
	const indent = Math.min(...block.filter((l) => l.trim() !== '').map((l) => l.search(/\S/)));
	return block.map((l) => l.slice(indent));
}

/** Expands $VAR / ${VAR} and the backslash escapes of one bash context. */
function expand(text, env, escapable) {
	let out = '';
	for (let i = 0; i < text.length; i++) {
		const ch = text[i];
		if (ch === '\\' && i + 1 < text.length && escapable.includes(text[i + 1])) {
			out += text[++i];
			continue;
		}
		if (ch === '$') {
			if (text[i + 1] === '(') throw new Error(`command substitution is not modelled: ${text}`);
			const m = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/.exec(text.slice(i));
			if (!m) throw new Error(`unsupported expansion in: ${text}`);
			const name = m[1] || m[2];
			if (!Object.prototype.hasOwnProperty.call(env, name)) throw new Error(`unknown variable $${name}`);
			out += env[name];
			i += m[0].length - 1;
			continue;
		}
		if (ch === '`') throw new Error(`unescaped backtick substitution in: ${text}`);
		out += ch;
	}
	return out;
}

/**
 * Interprets the release-body step for one set of inputs and returns the
 * body file it writes.
 */
function buildCiBody(env, changelog) {
	const script = releaseBodyScript();
	let body = '';
	let inGroup = false;
	let skipping = false;
	for (let i = 0; i < script.length; i++) {
		const line = script[i];
		const trimmed = line.trim();
		if (trimmed === '' || trimmed.startsWith('#')) continue;
		// `[ -s file ]` is true for a non-empty changelog file only.
		if (trimmed === 'if [ -s "$RUNNER_TEMP/changelog.md" ]; then') {
			if (skipping) throw new Error('nested changelog conditions are not modelled');
			skipping = changelog === '';
			continue;
		}
		if (trimmed === 'fi') {
			skipping = false;
			continue;
		}
		if (skipping) continue;
		if (/^cat >> "\$body_file" << EOF$/.test(trimmed)) {
			for (i++; i < script.length && script[i] !== 'EOF'; i++) {
				body += expand(script[i], env, '$`\\') + '\n';
			}
			if (i >= script.length) throw new Error('unterminated heredoc in the release-body step');
			continue;
		}
		if (trimmed === '{') {
			inGroup = true;
			continue;
		}
		if (trimmed === '} >> "$body_file"') {
			inGroup = false;
			continue;
		}
		const echo = /^echo "((?:[^"\\]|\\.)*)"$/.exec(trimmed);
		if (echo) {
			if (inGroup) body += expand(echo[1], env, '$`"\\') + '\n';
			continue;
		}
		const sed = /^sed '\/(.+)\/d' "\$RUNNER_TEMP\/changelog\.md"$/.exec(trimmed);
		if (sed) {
			if (!inGroup) throw new Error('the changelog sed writes outside the body group');
			const drop = new RegExp(sed[1].replace(/\[\[:space:\]\]/g, '[ \\t]'));
			body += changelog.split('\n').filter((l) => !drop.test(l)).join('\n');
			continue;
		}
		if (
			trimmed === 'set -euo pipefail' ||
			trimmed === 'body_file="$(mktemp)"' ||
			trimmed.startsWith('gh release edit ')
		) {
			continue;
		}
		throw new Error(`unmodelled statement in the release-body step: ${trimmed}`);
	}
	if (inGroup) throw new Error('the body group never closes');
	return body;
}

function checkCiBody(modules) {
	const defaults = JSON.parse(fs.readFileSync(path.join(SHARED, 'modules', 'updater', 'defaults.json'), 'utf8'));
	const env = {
		VERSION: '1.2.3',
		TAG: 'v1.2.3',
		GITHUB_REPOSITORY: 'adrienm7/ergopti',
		GITHUB_RUN_ID: '4242',
		LINUX_BUNDLE_ASSET: defaults.release_assets.linux_bundle,
		RUNNER_TEMP: '/tmp/runner'
	};
	const body = buildCiBody(env, CHANGELOG_MD);
	const parts = modules.splitReleaseBody(body);

	expect(parts.format === 'marked', `the CI body must carry valid section markers (format: ${parts.format})`);
	expect(parts.title === 'Ergopti 1.2.3', `the title must be the version heading (got "${parts.title}")`);
	expect(
		parts.changelog.startsWith('> Timestamps are in **Paris time**') &&
			parts.changelog.includes('### Features') &&
			parts.changelog.includes('- **Ci: Mark the release body sections**'),
		'the changelog section must hold the timestamp note and every changelog group'
	);
	for (const token of ['<details', '<summary', '</details>', 'ergopti:section', '## Downloads', 'Ergopti_windows.exe']) {
		expect(
			!parts.changelog.split('\n').some((line) => line.startsWith(token)),
			`the changelog section must not start a line with ${token}`
		);
	}
	expect(
		parts.downloads.includes('### Ergopti — keyboard layout only') &&
			parts.downloads.includes('releases/download/v1.2.3/ErgoptiPlus.exe') &&
			!/^## Downloads/m.test(parts.downloads),
		'the downloads section must hold every table, without its own heading'
	);
	expect(
		parts.intro.includes('**Ergopti — keyboard layout:**') && !parts.intro.includes('## Ergopti'),
		'the intro must keep its product lines and lose the version heading'
	);
	expect(
		parts.footer === '_Generated by [CI](https://github.com/adrienm7/ergopti/actions/runs/4242)_',
		`the footer must be the CI credit line alone (got "${parts.footer}")`
	);
	const markers = body.match(/^<!-- ergopti:section=[a-z]+ -->$/gm) || [];
	expect(
		JSON.stringify(markers.map((m) => /=([a-z]+)/.exec(m)[1])) === JSON.stringify(modules.RELEASE_BODY_SECTIONS),
		`CI must emit every section the splitter knows, in order (got ${markers.join(', ')})`
	);

	// Without a changelog file the step still writes a marked, valid body.
	const bare = modules.splitReleaseBody(buildCiBody(env, ''));
	expect(bare.format === 'marked' && bare.changelog === '', 'an empty changelog must still split as marked');
}

// ==========================================
// ==========================================
// ======= 3/ Shared Vectors ===============
// ==========================================
// ==========================================

function checkVectors(modules) {
	const data = JSON.parse(fs.readFileSync(path.join(CORPUS, 'release_body_vectors.json'), 'utf8'));
	const vectors = data.vectors || [];
	expect(vectors.length >= MIN_VECTORS, `expected at least ${MIN_VECTORS} vectors, found ${vectors.length}`);
	for (const vector of vectors) {
		const parts = modules.splitReleaseBody(vector.body.join('\n'));
		const expected = vector.changelog.join('\n');
		expect(parts.format === vector.format, `[${vector.id}] format ${parts.format}, expected ${vector.format}`);
		expect(
			parts.changelog === expected,
			`[${vector.id}] changelog mismatch:\n--- got\n${parts.changelog}\n--- expected\n${expected}`
		);
		const all = [parts.intro, parts.changelog, parts.downloads, parts.footer].join('\n');
		expect(!/Skip to downloads/.test(all), `[${vector.id}] the github.com jump link must be dropped`);
		expect(!/^<a id=/m.test(all), `[${vector.id}] empty anchors must be dropped`);
	}
	const legacy = vectors.find((v) => v.id === 'changelog-first-with-jump-link');
	if (legacy) {
		const parts = modules.splitReleaseBody(legacy.body.join('\n'));
		expect(
			parts.downloads.startsWith('### Ergopti — keyboard layout only') &&
				!parts.intro.includes('Timestamps') &&
				parts.footer.startsWith('_Generated by'),
			'a legacy body must split into downloads, an intro without the moved note, and the footer'
		);
	} else {
		expect(false, 'the legacy jump-link vector is missing');
	}
}

// ==========================================
// ==========================================
// ======= 4/ Atom Feed Bodies =============
// ==========================================
// ==========================================

function checkAtomBodies(modules) {
	const xml = fs.readFileSync(path.join(CORPUS, 'release_body_feed.atom'), 'utf8');
	const releases = modules.parseReleasesAtom(xml, 'adrienm7', 'ergopti');
	expect(releases.length === 2, `the feed fixture must yield 2 releases (got ${releases.length})`);
	const expectations = {
		'v0.0.0-dev.133': 'Linux: Keep the daemon',
		'v0.0.0-dev.132': 'Macos: Make Disable All switch features off like pause'
	};
	for (const release of releases) {
		const parts = modules.splitReleaseBody(release.body);
		const entry = expectations[release.tag_name];
		expect(parts.format === 'legacy', `[${release.tag_name}] a feed body must split heuristically`);
		expect(
			Boolean(entry) && parts.changelog.includes(entry) && parts.changelog.includes('### Fix'),
			`[${release.tag_name}] the feed changelog must hold its entries`
		);
		expect(
			/^> Timestamps are in/.test(parts.changelog),
			`[${release.tag_name}] the timestamp note must open the feed changelog`
		);
		expect(
			!/<details|<summary|<\/details>|Downloads|keyboard layout only/.test(parts.changelog),
			`[${release.tag_name}] the feed changelog must not carry the fold or the downloads`
		);
		expect(
			parts.downloads.includes('keyboard layout only'),
			`[${release.tag_name}] the feed downloads must be their own section`
		);
		expect(/Generated by/.test(parts.footer), `[${release.tag_name}] the feed footer must be split off`);
	}
}

for (const [name, check] of [
	['vectors', checkVectors],
	['CI body', checkCiBody],
	['Atom bodies', checkAtomBodies]
]) {
	try {
		check(loadModules());
	} catch (error) {
		expect(false, `the ${name} check raised: ${error.message}`);
	}
}

console.log(`1..${failures.length === 0 ? 1 : failures.length}`);
if (failures.length === 0) {
	console.log('ok 1 - release bodies split into changelog, downloads, intro and footer');
	process.exit(0);
}
failures.forEach((message, index) => console.log(`not ok ${index + 1} - ${message}`));
process.exit(1);
