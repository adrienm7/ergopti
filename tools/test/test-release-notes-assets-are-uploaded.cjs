// tools/test/test-release-notes-assets-are-uploaded.cjs

/**
 * ==============================================================================
 * MODULE: Release-Note Asset Link Guard
 * DESCRIPTION:
 * Every file the release notes advertise as a release asset must be a file some
 * build job actually uploads. The download tables and the upload lists live in
 * two different jobs of `.github/workflows/ci.yml`, two hundred lines apart, and
 * nothing compared them.
 *
 * ROOT CAUSE ENCODED:
 * The Linux table advertised `kanata.kbd`, linking to
 * `releases/download/<tag>/kanata.kbd`. The `build-linux` job's upload list only
 * ever held `Ergopti_xkb.zip` and `ergopti-plus-linux.tar.gz` — the kanata config
 * was packed *inside* the tarball and never attached on its own. Every published
 * release therefore shipped a table row pointing at a file the release does not
 * contain, and no job, test or lint pass could notice: the notes are a heredoc,
 * the uploads are a YAML list, and neither is derived from the other.
 *
 * It is worse than a dead link in the notes. The website resolves its download
 * buttons through a STRICT asset-name lookup (`release.assets[name] ?? null` in
 * `src/lib/js/getGitHubRelease.js`), and three components ask for that exact
 * name — `src/routes/ergopti-plus/Platforms.svelte`, `Hero.svelte` and
 * `StickyCta.svelte`. A missing asset does not degrade: the Linux download
 * button renders as `href="#"`.
 *
 * FEATURES & RATIONALE:
 * 1. Both sides are derived from `ci.yml`. A hardcoded list of expected assets
 *    would rot exactly the way the thing it guards rotted — it would be one more
 *    copy nobody updates. The links come from the release-body heredoc, the
 *    uploads from every `actions/upload-artifact` step's `path:` list.
 * 2. Floored parses. A regex that stopped matching would find zero links, and a
 *    guard over an empty set passes forever; both extractions assert a minimum.
 * 3. The premise is asserted too — the finalize job attaching exactly what the
 *    build jobs uploaded is what makes the upload lists an authoritative asset
 *    inventory, so a rewrite of that step fails here rather than silently
 *    invalidating the whole check.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WORKFLOW_REL = '.github/workflows/ci.yml';
const WORKFLOW = path.join(ROOT, WORKFLOW_REL);

// A link to an asset of THIS release. Anchoring on the literal `${TAG}` is what
// scopes the scan to our own release: ci.yml also downloads third-party
// tarballs from `releases/download/v2.0.19/…` (AutoHotkey) and
// `releases/download/${SPARKLE_VERSION}/…`, which are nobody's job to attach.
const RELEASE_LINK = /releases\/download\/\$\{TAG\}\/([A-Za-z0-9._+-]+)/g;

// The step that publishes build outputs, and the key holding its file list.
const UPLOAD_STEP = /^\s*(?:-\s+)?uses:\s*actions\/upload-artifact/;
const ARTIFACT_NAME = /^\s*name:\s*(\S+)/;
const PATH_KEY = /^(\s*)path:\s*(.*)$/;

// A `path:` entry can be a glob. Basename equality cannot decide those, so they
// are compiled to a matcher instead of being compared literally.
const IS_GLOB = /[*?[\]]/;

// The finalize job attaches whatever the build jobs uploaded. If that stops
// being true, the upload lists stop being the asset inventory and this guard is
// measuring the wrong thing.
const ATTACHES_DOWNLOADED_ARTIFACTS = /find\s+release-assets\s+-type\s+f/;
const DOWNLOADS_ARTIFACTS = /uses:\s*actions\/download-artifact/;

// Floors — today: 6 linked assets across 3 upload steps naming 8 files.
const MIN_LINKED_ASSETS = 5;
const MIN_UPLOAD_STEPS = 3;
const MIN_UPLOAD_PATHS = 6;

const errors = [];

/** Returns the column of the first non-space character, or -1 for a blank line. */
function indentOf(line) {
	if (line.trim() === '') return -1;
	return line.length - line.trimStart().length;
}




// ====================================
// ====================================
// ======= 1/ Read The Workflow =======
// ====================================
// ====================================

if (!fs.existsSync(WORKFLOW)) {
	console.error(`\x1b[31m[FAIL] ${WORKFLOW_REL} does not exist — the release pipeline cannot be checked.\x1b[0m`);
	process.exit(1);
}

const lines = fs.readFileSync(WORKFLOW, 'utf8').split(/\r?\n/);

if (!DOWNLOADS_ARTIFACTS.test(lines.join('\n')) || !ATTACHES_DOWNLOADED_ARTIFACTS.test(lines.join('\n'))) {
	errors.push(
		'the finalize job no longer downloads the build artifacts and attaches every file it finds ' +
			'(`actions/download-artifact` + `find release-assets -type f`). That pairing is what makes the ' +
			'upload-artifact `path:` lists the authoritative inventory of release assets, which is the ' +
			'premise of this whole check — re-derive the upload side before trusting it again.'
	);
}




// ====================================================
// ====================================================
// ======= 2/ Collect The Linked Release Assets =======
// ====================================================
// ====================================================

// Filename → first line that links to it. Duplicates would report the same
// reconciliation twice, and the first occurrence is the one to fix.
const linked = new Map();

lines.forEach((line, i) => {
	for (const m of line.matchAll(RELEASE_LINK)) {
		if (!linked.has(m[1])) linked.set(m[1], i + 1);
	}
});

if (linked.size < MIN_LINKED_ASSETS) {
	errors.push(
		`parsed only ${linked.size} release-asset link(s) out of ${WORKFLOW_REL} (floor ${MIN_LINKED_ASSETS}). ` +
			'The release-body heredoc changed shape and the extraction stopped matching — this guard would ' +
			'then approve download tables it never read.'
	);
}




// =====================================================
// =====================================================
// ======= 3/ Collect What The Build Jobs Upload =======
// =====================================================
// =====================================================

/** @type {Array<{artifact: string, line: number, files: string[]}>} */
const uploads = [];

for (let i = 0; i < lines.length; i++) {
	if (!UPLOAD_STEP.test(lines[i])) continue;

	const stepIndent = indentOf(lines[i]);
	let artifact = '(unnamed)';
	let pathLine = 0;
	const files = [];

	// A step ends at the first non-blank line indented less than its own keys —
	// the dash of the next list item, or the comment banner of the next job.
	for (let j = i + 1; j < lines.length; j++) {
		const ind = indentOf(lines[j]);
		if (ind === -1) continue;
		if (ind < stepIndent) break;

		const nameMatch = lines[j].match(ARTIFACT_NAME);
		if (nameMatch && ind > stepIndent) artifact = nameMatch[1];

		const pathMatch = lines[j].match(PATH_KEY);
		if (!pathMatch) continue;
		pathLine = j + 1;

		// `path: build/foo.zip` — a single inline value rather than a block.
		const inline = pathMatch[2].trim();
		if (inline !== '' && inline !== '|' && inline !== '>' && !inline.startsWith('|-') && !inline.startsWith('>-')) {
			files.push(inline);
			continue;
		}

		const listIndent = pathMatch[1].length;
		for (let k = j + 1; k < lines.length; k++) {
			const entryIndent = indentOf(lines[k]);
			if (entryIndent === -1) continue;
			if (entryIndent <= listIndent) break;
			const entry = lines[k].trim();
			if (entry.startsWith('#')) continue;
			files.push(entry.replace(/^-\s*/, ''));
		}
	}

	uploads.push({ artifact, line: pathLine || i + 1, files });
}

const uploadedNames = new Set();
const uploadedGlobs = [];
let uploadedPathCount = 0;

for (const step of uploads) {
	for (const file of step.files) {
		uploadedPathCount++;
		const base = file.split('/').pop();
		if (IS_GLOB.test(base)) {
			// `build/linux/*.kbd` cannot be compared by equality, so it becomes a
			// matcher — otherwise a legitimate wildcard upload would read as a
			// missing asset and this guard would cry wolf until someone deleted it.
			const pattern = base.replace(/[.+^${}()|\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
			uploadedGlobs.push(new RegExp(`^${pattern}$`));
		} else {
			uploadedNames.add(base);
		}
	}
}

if (uploads.length < MIN_UPLOAD_STEPS) {
	errors.push(
		`found only ${uploads.length} upload-artifact step(s) (floor ${MIN_UPLOAD_STEPS}) — the step scan ` +
			'broke, and an empty upload set makes every linked asset look missing (or, once someone ' +
			'"fixes" that, makes nothing look missing at all).'
	);
}

if (uploadedPathCount < MIN_UPLOAD_PATHS) {
	errors.push(
		`extracted only ${uploadedPathCount} upload path(s) (floor ${MIN_UPLOAD_PATHS}) — the \`path:\` ` +
			'block parse drifted and the inventory is incomplete.'
	);
}




// ==============================================
// ==============================================
// ======= 4/ Join On Basename And Report =======
// ==============================================
// ==============================================

// The join key is the BASENAME, deliberately. The two sides speak different
// vocabularies: an upload `path:` entry is a path in the build tree
// (`build/linux/xkb/Ergopti_xkb.zip`), while a note link is a release-asset name
// (`Ergopti_xkb.zip`). `gh release create` is handed the downloaded files and
// names each asset after the file — so the basename is both the only token the
// two lists share and exactly the key the published release is addressed by.
const inventory = uploads
	.map((u) => `${u.artifact} (${WORKFLOW_REL}:${u.line}): ${u.files.join(', ') || '(none)'}`)
	.join('\n        ');

for (const [name, line] of linked) {
	if (uploadedNames.has(name)) continue;
	if (uploadedGlobs.some((re) => re.test(name))) continue;

	errors.push(
		`"${name}" is advertised as a release asset but no job uploads it.\n` +
			`      Reconcile these two places:\n` +
			`        1. the download table in the release body — ${WORKFLOW_REL}:${line}\n` +
			`        2. the \`path:\` list of the \`actions/upload-artifact\` step in the job that builds it:\n` +
			`        ${inventory}\n` +
			`      Either attach the file or drop the row. Left as is, every published release carries a ` +
			`dead link, and the site is worse off still: src/lib/js/getGitHubRelease.js looks assets up by ` +
			`exact name, so Platforms.svelte, Hero.svelte and StickyCta.svelte fall back to href="#".`
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the release notes link to files the release does not contain:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${linked.size} asset(s) linked by the release notes are uploaded by one of the ` +
		`${uploads.length} build job(s) (${uploadedPathCount} path(s) inventoried).\x1b[0m`
);
