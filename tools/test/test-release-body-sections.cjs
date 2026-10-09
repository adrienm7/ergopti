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
 * 4. Versions page: every fixture goes through the real page (recording DOM):
 *    the changelog section comes first and expanded, the downloads follow
 *    collapsed, and no fold, summary, anchor or marker line survives as text.
 * 5. Update prompt pane: _shared/ui/release_notes/ (the Windows prompt's notes)
 *    shows the changelog only, posts link clicks with its seeded session, and
 *    refuses to start without a seeded body.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { byTag, runPage, textNodes } = require('./support/changelog-page-dom.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const CHANGELOG_UI = path.join(SHARED, 'ui', 'changelog');
const CORPUS = path.join(SHARED, 'tests', 'corpus', 'updater');
const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'ci.yml');
const BODY_STEP = 'Write release body with platform sections';
const qualification = require('../ci/dev-release-qualification.cjs');
const signing = require('../ci/windows-stable-signing.cjs');
const crypto = require('node:crypto');
const MIN_VECTORS = 8;
const EN = JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'));
const CI_ENV = {
	VERSION: '1.2.3',
	TAG: 'v1.2.3',
	CHANNEL: 'main',
	GITHUB_REPOSITORY: 'adrienm7/ergopti',
	GITHUB_REPOSITORY_OWNER: 'adrienm7',
	GITHUB_RUN_ID: '4242',
	LINUX_BUNDLE_ASSET: JSON.parse(
		fs.readFileSync(path.join(SHARED, 'modules', 'updater', 'defaults.json'), 'utf8')
	).release_assets.linux_bundle,
	RUNNER_TEMP: '/tmp/runner'
};

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
		vm.runInContext(fs.readFileSync(path.join(CHANGELOG_UI, file), 'utf8'), sandbox, {
			filename: file
		});
	}
	if (typeof sandbox.splitReleaseBody !== 'function')
		throw new Error('release_body.js exports no splitReleaseBody');
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
			if (!Object.prototype.hasOwnProperty.call(env, name))
				throw new Error(`unknown variable $${name}`);
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
function buildCiBody(
	inputs,
	changelog,
	script = releaseBodyScript(),
	qualificationNow = new Date(),
	signingFixture = null
) {
	const env = { ...inputs };
	let body = '';
	let inGroup = false;
	let skipping = false;
	for (let i = 0; i < script.length; i++) {
		const line = script[i];
		const trimmed = line.trim();
		if (trimmed === '' || trimmed.startsWith('#')) continue;
		if (trimmed === 'if [ -n "${ERGOPTI_NATIVE_QUALIFICATION_NOTE:-}" ]; then') {
			if (skipping) throw new Error('nested qualification conditions are not modelled');
			skipping = !env.ERGOPTI_NATIVE_QUALIFICATION_NOTE;
			continue;
		}
		if (
			trimmed ===
			'printf \'\\n## Native qualification limits\\n\\n%s\\n\' "$ERGOPTI_NATIVE_QUALIFICATION_NOTE" >> "$body_file"'
		) {
			if (skipping) continue;
			body += '\n## Native qualification limits\n\n' + env.ERGOPTI_NATIVE_QUALIFICATION_NOTE + '\n';
			continue;
		}
		if (trimmed === 'node tools/ci/dev-release-qualification.cjs --publication-admit >/dev/null') {
			const notice = qualification.stablePublicationNotice(
				env.ERGOPTI_NATIVE_QUALIFICATION_PROFILE || '',
				qualification.environmentContext(env),
				env.GITHUB_SHA,
				qualificationNow
			);
			assert.equal(
				env.ERGOPTI_NATIVE_QUALIFICATION_NOTE || '',
				notice,
				'the public notice must be the admitted source-bound text'
			);
			continue;
		}

		if (trimmed === 'node tools/ci/windows-stable-signing.cjs --publication-admit >/dev/null') {
			let notice = '';
			if (signingFixture) {
				signing.requireFreshUnsigned(env.ERGOPTI_WINDOWS_CREATE_RELEASE);
				signing.validateReceipt(
					signingFixture.receipt,
					qualification.environmentContext(env),
					env.GITHUB_SHA,
					signingFixture.checkout,
					crypto.createHash('sha256').update(signingFixture.image).digest('hex'),
					qualificationNow
				);
				notice = signing.notice(env.GITHUB_SHA);
			} else if (
				env.ERGOPTI_DEV_RELEASE_TAG === signing.POLICY.tag &&
				env.ERGOPTI_DEV_RELEASE_CHANNEL === signing.POLICY.channel
			) {
				assert.equal(
					env.ERGOPTI_WINDOWS_SIGNING_CONFIGURED,
					'true',
					'a stable body without an unsigned receipt requires the full signing configuration'
				);
			}
			assert.equal(
				env.ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE || '',
				notice,
				'the public Windows notice must be the actual admitted artifact-bound text'
			);
			continue;
		}
		if (trimmed === 'if [ -n "${ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE:-}" ]; then') {
			if (skipping) throw new Error('nested signing conditions are not modelled');
			skipping = !env.ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE;
			continue;
		}
		if (
			trimmed ===
			'printf \'\\n## Windows signature qualification\\n\\n%s\\n\' "$ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE" >> "$body_file"'
		) {
			if (skipping) continue;
			body +=
				'\n## Windows signature qualification\n\n' +
				env.ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE +
				'\n';
			continue;
		}

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
		// A quoted Node heredoc is literal stdin; only TAG is an argv value.
		// Execute the workflow's actual code instead of copying its note text.
		if (trimmed === 'node - "$TAG" >> "$body_file" <<\'NODE\'') {
			const source = [];
			for (i++; i < script.length && script[i] !== 'NODE'; i++) source.push(script[i]);
			if (i >= script.length) throw new Error('unterminated Node heredoc in the release-body step');
			const result = spawnSync(process.execPath, ['-', env.TAG], {
				input: source.join('\n') + '\n',
				cwd: ROOT,
				encoding: 'utf8',
				env: { ...process.env, ...env },
				windowsHide: true,
				timeout: 5000,
				maxBuffer: 65536
			});
			if (result.error) throw result.error;
			if (result.signal !== null || result.status !== 0 || result.stderr !== '')
				throw new Error(
					`Node release-body heredoc failed: status=${result.status}, signal=${result.signal}, stderr=${result.stderr}`
				);
			body += result.stdout;
			continue;
		}
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
			body += changelog
				.split('\n')
				.filter((l) => !drop.test(l))
				.join('\n');
			continue;
		}
		// The cask token comes from the real generator the step runs.
		if (trimmed === 'cask="$(node tools/build/homebrew-cask.cjs --token "$CHANNEL")"') {
			env.cask = require(path.join(ROOT, 'tools', 'build', 'homebrew-cask.cjs')).tokenForChannel(
				env.CHANNEL
			);
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
	const env = CI_ENV;
	const body = buildCiBody(env, CHANGELOG_MD);
	const parts = modules.splitReleaseBody(body);

	expect(
		parts.format === 'marked',
		`the CI body must carry valid section markers (format: ${parts.format})`
	);
	expect(
		parts.title === 'Ergopti 1.2.3',
		`the title must be the version heading (got "${parts.title}")`
	);
	expect(
		parts.changelog.startsWith('> Timestamps are in **Paris time**') &&
			parts.changelog.includes('### Features') &&
			parts.changelog.includes('- **Ci: Mark the release body sections**'),
		'the changelog section must hold the timestamp note and every changelog group'
	);
	for (const token of [
		'<details',
		'<summary',
		'</details>',
		'ergopti:section',
		'## Downloads',
		'Ergopti_windows.exe'
	]) {
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
		JSON.stringify(markers.map((m) => /=([a-z]+)/.exec(m)[1])) ===
			JSON.stringify(modules.RELEASE_BODY_SECTIONS),
		`CI must emit every section the splitter knows, in order (got ${markers.join(', ')})`
	);

	// Replay the actual policy publisher, retaining explicit unqualified labels.
	const qualification = require('../../.github/ci/dev_release_qualification_exceptions.json');
	const qualifiedBody = buildCiBody(
		{ ...env, TAG: qualification.tag, VERSION: qualification.version },
		CHANGELOG_MD
	);
	const qualifiedParts = modules.splitReleaseBody(qualifiedBody);
	expect(qualifiedParts.format === 'marked', 'the exception body must retain every section marker');
	expect(
		qualifiedParts.footer.includes('Deferred checks are not passes'),
		'the real publisher must disclose unqualified native checks'
	);
	for (const [scope, record] of Object.entries(qualification.scopes)) {
		expect(
			qualifiedParts.footer.includes(scope + ':** ' + record.reason),
			'the actual body must retain each deferred scope and reason'
		);
	}
	expect(
		!body.includes('Native validation limitations'),
		'ordinary release tags must not inherit a foreign qualification exception'
	);

	// Without a changelog file the step still writes a marked, valid body.
	const bare = modules.splitReleaseBody(buildCiBody(env, ''));
	expect(
		bare.format === 'marked' && bare.changelog === '',
		'an empty changelog must still split as marked'
	);
}

/** Actual workflow Node notes must stay scoped without weakening the shell model. */
function checkNodeBodyInterpreter(modules) {
	const policy = JSON.parse(
		fs.readFileSync(path.join(ROOT, '.github/ci/dev_release_qualification_exceptions.json'), 'utf8')
	);
	const active = { ...CI_ENV, TAG: policy.tag, VERSION: policy.version, CHANNEL: policy.channel };
	const body = buildCiBody(active, CHANGELOG_MD);
	assert.ok(
		body.includes('### Native validation limitations'),
		'The actual dev.156 notes block must be executed.'
	);
	assert.ok(
		body.includes('Deferred checks are not passes'),
		'The actual notes must deny native qualification.'
	);
	for (const [scope, record] of Object.entries(policy.scopes)) {
		const line = '- **DEFERRED — ' + scope + ':** ' + record.reason;
		assert.equal(
			body.split(line).length - 1,
			1,
			'Every actual declared limitation must occur once.'
		);
	}
	assert.ok(body.includes(policy.expires_at));
	for (const tag of ['v0.0.0-dev.155', 'v0.0.0-dev.158', 'v1.2.3']) {
		const other = buildCiBody({ ...CI_ENV, TAG: tag }, CHANGELOG_MD);
		assert.ok(
			!other.includes('Native validation limitations'),
			'Other tags must not borrow these notes.'
		);
		assert.ok(!other.includes('**DEFERRED —'));
	}
	const parts = modules.splitReleaseBody(body);
	const baseline = modules.splitReleaseBody(buildCiBody(CI_ENV, CHANGELOG_MD));
	assert.equal(parts.format, 'marked');
	assert.equal(parts.title, 'Ergopti ' + policy.version);
	assert.equal(
		parts.changelog,
		baseline.changelog,
		'Qualification notes cannot contaminate changelog.'
	);
	assert.ok(parts.footer.includes('### Native validation limitations'));
	assert.ok(
		parts.footer.endsWith(baseline.footer),
		'The CI credit must remain the final footer text.'
	);
	assert.ok(parts.downloads.includes('releases/download/' + policy.tag + '/ErgoptiPlus.exe'));
	checkPageOrder('CI qualification notes', body, 'Ci: Mark the release body sections');
	assert.equal(
		renderPane(body).notes.textContent,
		renderPane(buildCiBody(CI_ENV, CHANGELOG_MD)).notes.textContent
	);
	const command = 'node - "$TAG" >> "$body_file" <<\'NODE\'';
	assert.equal(
		buildCiBody(CI_ENV, '', [
			command,
			'console.log(JSON.stringify(["$TAG", process.argv[2]]))',
			'NODE'
		]),
		JSON.stringify(['$TAG', CI_ENV.TAG]) + '\n',
		'A quoted heredoc remains literal while the exact tag is passed through argv.'
	);
	assert.throws(
		() =>
			buildCiBody(CI_ENV, '', [
				command,
				'console.log("partial"); throw Error("controlled-node-refusal")',
				'NODE'
			]),
		/Node release-body heredoc failed/
	);
	assert.throws(
		() => buildCiBody(CI_ENV, '', [command, 'console.error("controlled-node-stderr")', 'NODE']),
		/Node release-body heredoc failed/
	);
	assert.throws(
		() => buildCiBody(CI_ENV, '', [command, 'console.log("missing terminator")']),
		/unterminated Node heredoc/
	);
	for (const unknown of [
		'node - "$VERSION" >> "$body_file" <<\'NODE\'',
		'curl https://example.invalid',
		'node arbitrary-script.cjs'
	]) {
		assert.throws(() => buildCiBody(CI_ENV, '', [unknown]), /unmodelled statement/);
	}
}

// ==========================================
// ==========================================
// ======= 3/ Shared Vectors ===============
// ==========================================
// ==========================================

function checkVectors(modules) {
	const data = JSON.parse(fs.readFileSync(path.join(CORPUS, 'release_body_vectors.json'), 'utf8'));
	const vectors = data.vectors || [];
	expect(
		vectors.length >= MIN_VECTORS,
		`expected at least ${MIN_VECTORS} vectors, found ${vectors.length}`
	);
	for (const vector of vectors) {
		const parts = modules.splitReleaseBody(vector.body.join('\n'));
		const expected = vector.changelog.join('\n');
		expect(
			parts.format === vector.format,
			`[${vector.id}] format ${parts.format}, expected ${vector.format}`
		);
		expect(
			parts.changelog === expected,
			`[${vector.id}] changelog mismatch:\n--- got\n${parts.changelog}\n--- expected\n${expected}`
		);
		const all = [parts.intro, parts.changelog, parts.downloads, parts.footer].join('\n');
		expect(
			!/Skip to downloads/.test(all),
			`[${vector.id}] the github.com jump link must be dropped`
		);
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

	// A note after a legacy changelog fold that is not the CI credit line is
	// shown in the footer, never dropped with the fold's surroundings.
	const note = 'Full Changelog: https://github.com/adrienm7/ergopti/compare/v1.2.2...v1.2.3';
	const trailing = modules.splitReleaseBody(
		[
			'## Downloads',
			'',
			'Files.',
			'',
			'<details>',
			'<summary>Changelog</summary>',
			'',
			'- **Ci: Fold**',
			'',
			'</details>',
			'',
			note
		].join('\n')
	);
	expect(
		trailing.format === 'legacy' &&
			trailing.changelog === '- **Ci: Fold**' &&
			trailing.footer === note,
		`a note after the changelog fold must move to the footer (changelog "${trailing.changelog}", footer "${trailing.footer}")`
	);
}

// ==========================================
// ==========================================
// ======= 4/ Atom Feed Bodies =============
// ==========================================
// ==========================================

function checkAtomBodies(modules) {
	const xml = fs.readFileSync(path.join(CORPUS, 'release_body_feed.atom'), 'utf8');
	const releases = modules.parseReleasesAtom(xml, 'adrienm7', 'ergopti');
	expect(releases.length === 3, `the feed fixture must yield 3 releases (got ${releases.length})`);
	const expectations = {
		'v0.0.0-dev.133': 'Linux: Keep the daemon',
		'v0.0.0-dev.132': 'Macos: Make Disable All switch features off like pause',
		'v0.0.0-dev.128': 'Llm: Insert the chosen prediction on its validation chord'
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
		expect(
			/Generated by/.test(parts.footer),
			`[${release.tag_name}] the feed footer must be split off`
		);
		// The jump link only works on github.com. The feed renders older bodies'
		// in-page "#user-content-downloads" href, which must be dropped like the
		// API body's, not left behind as a dead bold label.
		const sections = [parts.intro, parts.changelog, parts.downloads, parts.footer].join('\n');
		expect(
			!/Skip to downloads/.test(sections),
			`[${release.tag_name}] the feed jump link must not survive the split`
		);
	}
}

// ==========================================
// ==========================================
// ======= 5/ Versions Page ================
// ==========================================
// ==========================================

// A text node that IS a structural line means the fold or anchor leaked as text.
const STRUCTURAL_TEXT =
	/^(?:<details( open)?>|<\/details>|<summary>.*|<a (?:id|name)=.*|<!-- \/?ergopti:section.*)$/;

/** Renders one release through the real page and returns its body element. */
function renderInPage(body) {
	const { sandbox, document } = runPage({ _i18n_strings: EN });
	sandbox.injectReleases(
		[
			{
				tag_name: 'v1.2.3',
				body,
				html_url: 'https://github.com/adrienm7/ergopti/releases/tag/v1.2.3',
				published_at: '2026-09-23T00:00:00Z',
				prerelease: true
			}
		],
		'dev'
	);
	return document.getElementById('release-body');
}

/** Section element of the rendered page carrying a class, or undefined. */
function section(root, className) {
	return root.children.find((child) => (child.className || '').split(/\s+/).includes(className));
}

function checkPageOrder(label, body, entry) {
	const root = renderInPage(body);
	const changelog = section(root, 'release-section-changelog');
	const downloads = section(root, 'release-section-downloads');
	expect(
		Boolean(changelog) && changelog.tagName === 'details',
		`[${label}] the changelog must be a page section`
	);
	expect(
		Boolean(downloads) && downloads.tagName === 'details',
		`[${label}] the downloads must be a page section`
	);
	if (!changelog || !downloads) return;
	expect(
		root.children.indexOf(changelog) === 0 && root.children.indexOf(downloads) > 0,
		`[${label}] the changelog must come first and the downloads after it`
	);
	expect(
		changelog.getAttribute('open') === '' && downloads.getAttribute('open') === null,
		`[${label}] the changelog must be expanded and the downloads collapsed`
	);
	expect(
		changelog.children[0].tagName === 'summary' &&
			changelog.children[0].textContent === EN['changelog_window.section_changelog'] &&
			downloads.children[0].textContent === EN['changelog_window.section_downloads'],
		`[${label}] each section must be titled from its locale key`
	);
	expect(
		changelog.textContent.includes(entry) &&
			!changelog.textContent.includes('keyboard layout only'),
		`[${label}] the changelog section must hold the entries and nothing of the downloads`
	);
	expect(
		downloads.textContent.includes('keyboard layout only') &&
			!downloads.textContent.includes(entry),
		`[${label}] the downloads section must hold the download tables`
	);
	const leaked = textNodes(root)
		.map((node) => node.textContent.trim())
		.filter((text) => STRUCTURAL_TEXT.test(text));
	expect(leaked.length === 0, `[${label}] structural lines leaked as text: ${leaked.join(' | ')}`);
}

function checkVersionsPage(modules) {
	const ciBody = buildCiBody(CI_ENV, CHANGELOG_MD);
	checkPageOrder('CI body', ciBody, 'Ci: Mark the release body sections');
	const vectors = JSON.parse(
		fs.readFileSync(path.join(CORPUS, 'release_body_vectors.json'), 'utf8')
	).vectors;
	const byId = (id) => vectors.find((v) => v.id === id).body.join('\n');
	checkPageOrder(
		'legacy body',
		byId('changelog-first-with-jump-link'),
		'Make Disable All switch features off'
	);
	checkPageOrder('folded body', byId('folded-after-downloads'), 'Keep the daemon');
	const feed = modules.parseReleasesAtom(
		fs.readFileSync(path.join(CORPUS, 'release_body_feed.atom'), 'utf8'),
		'adrienm7',
		'ergopti'
	);
	checkPageOrder('Atom folded body', feed[0].body, 'Keep the daemon');
	checkPageOrder('Atom legacy body', feed[1].body, 'Make Disable All switch features off');
	checkPageOrder('Atom in-page jump link body', feed[2].body, 'Insert the chosen prediction');
	expect(
		!renderInPage(feed[2].body).textContent.includes('Skip to downloads'),
		'the Versions page must not show a feed jump link that cannot jump'
	);

	// Without a changelog the section still leads, saying so.
	const bare = renderInPage(buildCiBody(CI_ENV, ''));
	const bareChangelog = section(bare, 'release-section-changelog');
	expect(
		Boolean(bareChangelog) && bareChangelog.textContent.includes(EN['changelog_window.no_notes']),
		'a release without a changelog must say so in the leading changelog section'
	);

	// A body with no recognisable section renders verbatim, without section chrome.
	const unknown = renderInPage(byId('unknown-body-is-its-own-changelog'));
	expect(
		!section(unknown, 'release-section-changelog') &&
			unknown.textContent.includes('Hand-written notes'),
		'an unrecognised body must render as written'
	);
}

// ==========================================
// ==========================================
// ======= 6/ Update Prompt Notes Pane =====
// ==========================================
// ==========================================

/** Runs the pane page with a seeded body. */
function renderPane(body) {
	const seed = { body, owner: 'adrienm7', repo: 'ergopti', session: 's1' };
	const page = runPage({ _i18n_strings: EN, __release_notes: seed }, 'release_notes');
	return {
		notes: page.document.getElementById('release-notes'),
		empty: page.document.getElementById('empty-notes'),
		posted: page.posted
	};
}

function checkNotesPane() {
	const { notes, empty, posted } = renderPane(buildCiBody(CI_ENV, CHANGELOG_MD));
	expect(
		notes.textContent.includes('Ci: Mark the release body sections') && empty.hidden === true,
		'the prompt pane must render the changelog entries'
	);
	expect(
		!notes.textContent.includes('keyboard layout only') &&
			!notes.textContent.includes('Generated by'),
		'the prompt pane must show the changelog only, not the downloads or the footer'
	);
	const leaked = textNodes(notes)
		.map((node) => node.textContent.trim())
		.filter((text) => STRUCTURAL_TEXT.test(text));
	expect(leaked.length === 0, `the prompt pane leaked structural lines: ${leaked.join(' | ')}`);
	const link = byTag(notes, 'a').find(
		(a) => a.getAttribute('data-url') === 'https://github.com/adrienm7/ergopti/releases/tag/v1.2.2'
	);
	expect(Boolean(link), 'a repository link in the changelog must be clickable in the pane');
	if (link) {
		link.dispatch('click', { preventDefault() {} });
		const message = posted[posted.length - 1];
		expect(
			message &&
				message.name === 'release_notes_bridge' &&
				message.payload.action === 'open_url' &&
				message.payload.url === 'https://github.com/adrienm7/ergopti/releases/tag/v1.2.2' &&
				message.payload.session === 's1',
			'a link click must post open_url with the seeded session on the pane bridge'
		);
	}

	const blank = renderPane('');
	expect(
		blank.empty.hidden === false && blank.notes.children.length === 0,
		'an empty body must show the empty-notes line'
	);

	let refused = false;
	try {
		runPage({ _i18n_strings: EN }, 'release_notes');
	} catch (error) {
		refused = /__release_notes/.test(error.message);
	}
	expect(refused, 'the pane must fail loudly when the host seeded no release body');
}

function checkNativeQualificationBody(modules) {
	const before = new Date('2026-10-09T21:00:00Z');
	const selected = {
		...CI_ENV,
		TAG: 'v1.0.0',
		VERSION: '1.0.0',
		GITHUB_ACTIONS: 'true',
		GITHUB_EVENT_NAME: 'push',
		GITHUB_REF: 'refs/heads/main',
		GITHUB_SHA: 'a'.repeat(40),
		ERGOPTI_DEV_RELEASE_RELEASE: 'true',
		ERGOPTI_DEV_RELEASE_PRERELEASE: 'false',
		ERGOPTI_DEV_RELEASE_CHANNEL: 'main',
		ERGOPTI_DEV_RELEASE_TAG: 'v1.0.0',
		ERGOPTI_DEV_RELEASE_VERSION: '1.0.0',
		ERGOPTI_NATIVE_QUALIFICATION_PROFILE: 'stable-v1-20261009-macos-native-deferred',
		ERGOPTI_WINDOWS_SIGNING_CONFIGURED: 'true'
	};
	selected.ERGOPTI_NATIVE_QUALIFICATION_NOTE = qualification.stablePublicationNotice(
		selected.ERGOPTI_NATIVE_QUALIFICATION_PROFILE,
		qualification.environmentContext(selected),
		selected.GITHUB_SHA,
		before
	);
	const body = buildCiBody(selected, CHANGELOG_MD, releaseBodyScript(), before);
	assert.ok(body.includes(selected.ERGOPTI_NATIVE_QUALIFICATION_NOTE));
	assert.ok(body.includes('qualified:false'));
	const sections = modules.splitReleaseBody(body);
	assert.ok(sections.changelog && sections.downloads && sections.intro && sections.footer);
	assert.throws(
		() =>
			buildCiBody(selected, CHANGELOG_MD, releaseBodyScript(), new Date('2026-10-09T22:00:00Z')),
		/not authorized/
	);
	assert.throws(
		() =>
			buildCiBody(
				{ ...selected, GITHUB_SHA: 'b'.repeat(40) },
				CHANGELOG_MD,
				releaseBodyScript(),
				before
			),
		/source-bound text/
	);
	assert.throws(
		() =>
			buildCiBody(
				{ ...selected, ERGOPTI_DEV_RELEASE_TAG: 'v1.0.1' },
				CHANGELOG_MD,
				releaseBodyScript(),
				before
			),
		/not authorized/
	);
	const ordinary = buildCiBody(CI_ENV, CHANGELOG_MD);
	assert.ok(!ordinary.includes('Native qualification limits'));
}

function checkUnsignedQualificationBody(modules) {
	const now = new Date('2026-10-09T21:00:00Z');
	const env = {
		...CI_ENV,
		TAG: 'v1.0.0',
		VERSION: '1.0.0',
		GITHUB_ACTIONS: 'true',
		GITHUB_EVENT_NAME: 'push',
		GITHUB_REF: 'refs/heads/main',
		GITHUB_SHA: 'a'.repeat(40),
		ERGOPTI_DEV_RELEASE_RELEASE: 'true',
		ERGOPTI_DEV_RELEASE_PRERELEASE: 'false',
		ERGOPTI_DEV_RELEASE_CHANNEL: 'main',
		ERGOPTI_DEV_RELEASE_TAG: 'v1.0.0',
		ERGOPTI_DEV_RELEASE_VERSION: '1.0.0',
		ERGOPTI_WINDOWS_CREATE_RELEASE: 'true'
	};
	const image = Buffer.from('independent unsigned fixture bytes, not an executable');
	const hash = crypto.createHash('sha256').update(image).digest('hex');
	const fixture = {
		image,
		checkout: env.GITHUB_SHA,
		receipt: signing.receipt(
			qualification.environmentContext(env),
			env.GITHUB_SHA,
			env.GITHUB_SHA,
			hash,
			now
		)
	};
	env.ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE = signing.notice(env.GITHUB_SHA);
	const body = buildCiBody(env, CHANGELOG_MD, releaseBodyScript(), now, fixture);
	assert.ok(body.includes(env.ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE));
	assert.ok(
		body.includes('qualified:false') && body.includes('windows-signing-qualification.json')
	);
	const sections = modules.splitReleaseBody(body);
	assert.ok(sections.changelog && sections.downloads && sections.intro && sections.footer);
	checkPageOrder('CI unsigned signature notes', body, 'Ci: Mark the release body sections');
	for (const bad of [
		{ ...fixture, image: Buffer.from('tampered bytes') },
		{ ...fixture, checkout: 'b'.repeat(40) },
		{ ...fixture, receipt: { ...fixture.receipt, qualified: true } }
	])
		assert.throws(
			() => buildCiBody(env, CHANGELOG_MD, releaseBodyScript(), now, bad),
			/not admitted/
		);
	assert.throws(
		() =>
			buildCiBody(
				{ ...env, ERGOPTI_WINDOWS_CREATE_RELEASE: 'false' },
				CHANGELOG_MD,
				releaseBodyScript(),
				now,
				fixture
			),
		/not admitted/
	);
	assert.throws(
		() =>
			buildCiBody(
				env,
				CHANGELOG_MD,
				releaseBodyScript(),
				new Date('2026-10-09T22:00:00Z'),
				fixture
			),
		/not admitted/
	);
	assert.throws(
		() =>
			buildCiBody(
				{ ...env, ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE: 'invented' },
				CHANGELOG_MD,
				releaseBodyScript(),
				now,
				fixture
			),
		/artifact-bound text/
	);
	assert.throws(
		() => buildCiBody(env, CHANGELOG_MD, releaseBodyScript(), now),
		/full signing configuration/
	);
}

for (const [name, check] of [
	['vectors', checkVectors],
	['CI body', checkCiBody],
	['source-bound native qualification body', checkNativeQualificationBody],
	['artifact-bound unsigned qualification body', checkUnsignedQualificationBody],
	['Node body interpreter', checkNodeBodyInterpreter],
	['Atom bodies', checkAtomBodies],
	['Versions page', checkVersionsPage],
	['prompt notes pane', checkNotesPane]
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
