// tools/test/test-release-notes-assets-are-uploaded.cjs

/**
 * ==============================================================================
 * MODULE: Release-Note Asset Link Guard
 * DESCRIPTION:
 * Every file the release notes advertise as a release asset must be a file some
 * build job actually uploads. The download tables and the upload lists live in
 * different workflows of the CI pipeline — the notes in the release job of
 * `.github/workflows/ci.yml`, the uploads in each OS box it calls — and nothing
 * compared them.
 *
 * ROOT CAUSE ENCODED:
 * The Linux table advertised `kanata.kbd`, linking to
 * `releases/download/<tag>/kanata.kbd`. The Linux release build's upload list
 * only ever held `Ergopti_xkb.zip` and `ergopti-plus-linux.tar.gz` — the kanata
 * config was packed *inside* the tarball and never attached on its own. Every
 * published release therefore shipped a table row pointing at a file the release
 * does not contain, and no job, test or lint pass could notice: the notes are a
 * heredoc, the uploads are a YAML list, and neither is derived from the other.
 *
 * It is worse than a dead link in the notes. The website resolves its download
 * buttons through a STRICT asset-name lookup (`release.assets[name] ?? null` in
 * `src/lib/js/getGitHubRelease.js`), and three components ask for that exact
 * name — `src/routes/ergopti-plus/Platforms.svelte`, `Hero.svelte` and
 * `StickyCta.svelte`. A missing asset does not degrade: the Linux download
 * button renders as `href="#"`.
 *
 * FEATURES & RATIONALE:
 * 1. Both sides are derived from the pipeline (tools/test/ci-pipeline.cjs) after
 *    expanding the Linux bundle name from the shared updater contract. A
 *    hardcoded list of expected assets would rot exactly the way the thing it
 *    guards rotted — it would be one more copy nobody updates. The links come
 *    from the release job's heredoc, the uploads from the `path:` list of every
 *    `actions/upload-artifact` step whose artifact is named `assets-*`: the
 *    release downloads only that pattern, so an evidence upload cannot stand in.
 * 2. Floored parses. A regex that stopped matching would find zero links, and a
 *    guard over an empty set passes forever; both extractions assert a minimum.
 * 3. The premise is asserted too — the release job attaching exactly what the
 *    boxes uploaded as `assets-*` is what makes those upload lists an
 *    authoritative asset inventory, so a rewrite of that step fails here rather
 *    than silently invalidating the whole check.
 * 4. An upload list only proves a file CAN be uploaded. The release preflight
 *    refuses to publish when one is missing, so every linked asset, derived
 *    from the same links, must be in its list, with the Sparkle signature, the
 *    channel appcast and the Linux bundle checksum.
 * 5. Section markers: the body's invisible <!-- ergopti:section=NAME -->
 *    markers must match the names the in-app splitter
 *    (_shared/ui/changelog/release_body.js) exports, in order, each closed.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const pipeline = require('./ci-pipeline.cjs');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');

// A link to an asset of THIS release. Anchoring on the literal `${TAG}` is what
// scopes the scan to our own release: the workflows also download third-party
// tarballs from `releases/download/v2.0.26/…` (AutoHotkey) and
// `releases/download/${SPARKLE_VERSION}/…`, which are nobody's job to attach.
const RELEASE_LINK = /releases\/download\/\$\{TAG\}\/([A-Za-z0-9._+-]+)/g;

// The step that publishes build outputs, and the key holding its file list.
const UPLOAD_STEP = /^\s*(?:-\s+)?uses:\s*actions\/upload-artifact/;
const ARTIFACT_NAME = /^\s*name:\s*(\S+)/;
const PATH_KEY = /^(\s*)path:\s*(.*)$/;
// Only these artifacts reach the release (its download pattern is assets-*).
const RELEASE_ARTIFACT = /^assets-/;

// A `path:` entry can be a glob. Basename equality cannot decide those, so they
// are compiled to a matcher instead of being compared literally.
const IS_GLOB = /[*?[\]]/;

// The release job attaches whatever the boxes uploaded as assets-*. If that
// stops being true, the upload lists stop being the asset inventory and this
// guard is measuring the wrong thing.
const ATTACHES_DOWNLOADED_ARTIFACTS = /find\s+release-assets\s+-type\s+f/;
const DOWNLOADS_RELEASE_ARTIFACTS =
	/uses:\s*actions\/download-artifact[\s\S]*?pattern:\s*assets-\*/;

// Floors — today: 10 linked assets across 3 assets-* upload steps naming 13
// files (macOS 4, Windows 2, Linux 7).
const MIN_LINKED_ASSETS = 5;
const MIN_UPLOAD_STEPS = 3;
const MIN_UPLOAD_PATHS = 13;

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

const updaterDefaults = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'updater', 'defaults.json'),
		'utf8'
	)
);
const linuxBundleAsset = updaterDefaults.release_assets?.linux_bundle;
if (!/^[A-Za-z0-9._+-]+\.tar\.gz$/.test(linuxBundleAsset || '')) {
	console.error('[ERROR] release_assets.linux_bundle is absent or unsafe in updater defaults.');
	process.exit(1);
}

/** Expands every spelling of the Linux bundle name the workflows use. */
function expand(text) {
	return text
		.replaceAll('${{ env.LINUX_BUNDLE_ASSET }}', linuxBundleAsset)
		.replaceAll('${LINUX_BUNDLE_ASSET}', linuxBundleAsset)
		.replaceAll('$LINUX_BUNDLE_ASSET', linuxBundleAsset);
}

// locate() throws when the release job is missing, so the link scan below can
// never run over an empty body.
const release = pipeline.locate('release');
const releaseLines = expand(release.body).split('\n');
const releaseText = releaseLines.join('\n');

if (
	!DOWNLOADS_RELEASE_ARTIFACTS.test(releaseText) ||
	!ATTACHES_DOWNLOADED_ARTIFACTS.test(releaseText)
) {
	errors.push(
		'the release job no longer downloads the assets-* artifacts and attaches every file it finds ' +
			'(`actions/download-artifact` with `pattern: assets-*` + `find release-assets -type f`). That ' +
			'pairing is what makes the assets-* upload `path:` lists the authoritative inventory of release ' +
			'assets, which is the premise of this whole check — re-derive the upload side before trusting it again.'
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

releaseLines.forEach((line, i) => {
	for (const m of line.matchAll(RELEASE_LINK)) {
		if (!linked.has(m[1])) linked.set(m[1], `${release.file}:${release.line + i + 1}`);
	}
});

if (linked.size < MIN_LINKED_ASSETS) {
	errors.push(
		`parsed only ${linked.size} release-asset link(s) out of the release job (floor ${MIN_LINKED_ASSETS}). ` +
			'The release-body heredoc changed shape and the extraction stopped matching — this guard would ' +
			'then approve download tables it never read.'
	);
}

// =====================================================
// =====================================================
// ======= 3/ Collect What The Build Jobs Upload =======
// =====================================================
// =====================================================

/** @type {Array<{artifact: string, where: string, files: string[]}>} */
const uploads = [];

for (const { rel, text } of pipeline.files()) {
	const lines = expand(text).split('\n');
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
			if (
				inline !== '' &&
				inline !== '|' &&
				inline !== '>' &&
				!inline.startsWith('|-') &&
				!inline.startsWith('>-')
			) {
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

		// An evidence upload (launch-gate-*, linux-ci-evidence-*, ...) never
		// reaches the release, so it cannot vouch for an advertised asset.
		if (!RELEASE_ARTIFACT.test(artifact)) continue;
		uploads.push({ artifact, where: `${rel}:${pathLine || i + 1}`, files });
	}
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
			const pattern = base
				.replace(/[.+^${}()|\\]/g, '\\$&')
				.replace(/\*/g, '.*')
				.replace(/\?/g, '.');
			uploadedGlobs.push(new RegExp(`^${pattern}$`));
		} else {
			uploadedNames.add(base);
		}
	}
}

if (uploads.length < MIN_UPLOAD_STEPS) {
	errors.push(
		`found only ${uploads.length} assets-* upload-artifact step(s) (floor ${MIN_UPLOAD_STEPS}) — the step ` +
			'scan broke, and an empty upload set makes every linked asset look missing (or, once someone ' +
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
	.map((u) => `${u.artifact} (${u.where}): ${u.files.join(', ') || '(none)'}`)
	.join('\n        ');

for (const [name, where] of linked) {
	if (uploadedNames.has(name)) continue;
	if (uploadedGlobs.some((re) => re.test(name))) continue;

	errors.push(
		`"${name}" is advertised as a release asset but no job uploads it.\n` +
			`      Reconcile these two places:\n` +
			`        1. the download table in the release body — ${where}\n` +
			`        2. the \`path:\` list of the assets-* \`actions/upload-artifact\` step in the box that builds it:\n` +
			`        ${inventory}\n` +
			`      Either attach the file or drop the row. Left as is, every published release carries a ` +
			`dead link, and the site is worse off still: src/lib/js/getGitHubRelease.js looks assets up by ` +
			`exact name, so Platforms.svelte, Hero.svelte and StickyCta.svelte fall back to href="#".`
	);
}

// ======================================================
// ======================================================
// ======= 5/ The Preflight Requires Every Asset ========
// ======================================================
// ======================================================

// An upload list proves a box CAN upload a file, not that this run did:
// upload-artifact's if-no-files-found only fires when every path of a step is
// missing, and a skipped release step drops its file silently. The release
// preflight is what refuses to publish without one, so every linked asset, the
// Sparkle signature and appcast the feed step publishes, and the checksum the
// Linux updater verifies the bundle against must be in its list.
const PREFLIGHT = 'Refuse to publish an incomplete or already-taken release';
const UNLINKED_REQUIRED = [
	'_ErgoptiPlus.app.zip.sig',
	'appcast-${CHANNEL}.xml',
	`${linuxBundleAsset}.sha256`
];
const preflight = expand(pipeline.step(release.body, PREFLIGHT));
const assetLoop = /^\s*for asset in ([^\n;]*(?:\\\n[^\n;]*)*); do\n([\s\S]*?)\n\s*done$/m.exec(
	preflight
);
const required = assetLoop
	? assetLoop[1]
			.split(/\s+/)
			.filter((token) => token !== '' && token !== '\\')
			.map((token) => token.replace(/^"(.*)"$/, '$1'))
	: [];
if (!assetLoop || !/if \[ ! -s "release-assets\/\$asset" \]; then/.test(assetLoop[2])) {
	errors.push(
		`"${PREFLIGHT}" no longer loops over the required assets with [ ! -s "release-assets/$asset" ]`
	);
} else if (!/if \[ "\$missing" -gt 0 \]; then\n[^\n]*\n\s*exit 1/.test(preflight)) {
	errors.push(`"${PREFLIGHT}" must exit 1 when any required asset is missing`);
}
if (required.length < linked.size + UNLINKED_REQUIRED.length) {
	errors.push(
		`"${PREFLIGHT}" requires ${required.length} asset(s), fewer than the ${linked.size} linked plus ` +
			`${UNLINKED_REQUIRED.length} feed and checksum files; the list parse drifted or entries were dropped`
	);
}
for (const name of [...linked.keys(), ...UNLINKED_REQUIRED]) {
	if (!required.includes(name)) {
		errors.push(
			`"${name}" is not in the asset list of "${PREFLIGHT}" (${release.file}): a run whose box ` +
				'skipped it would publish anyway. Add it to the loop.'
		);
	}
}
for (const name of required) {
	if (!uploadedNames.has(name) && !uploadedGlobs.some((re) => re.test(name))) {
		errors.push(
			`"${PREFLIGHT}" requires "${name}", which no assets-* upload step names: every release would stop there`
		);
	}
}

const releaseBody = releaseText;
// The downloads must be in view without a jump. A "skip to downloads" link
// failed twice: the releases list page truncates long notes, which cut the
// anchor placed after the changelog, and from the list GitHub opens a release
// page client-side without scrolling to the fragment, so the first click landed
// at the top. The downloads now come before the changelog, which is folded.
const downloadsAt = releaseBody.indexOf('## Downloads');
const foldAt = releaseBody.indexOf('<details>');
const changelogAt = releaseBody.search(/sed [^\n]*\$RUNNER_TEMP\/changelog\.md/);
if (
	downloadsAt < 0 ||
	foldAt < 0 ||
	changelogAt < 0 ||
	!(downloadsAt < foldAt && foldAt < changelogAt)
) {
	errors.push(
		'the release downloads must come before the changelog, and the changelog must be folded in <details>'
	);
}
if (/Skip to downloads|DOWNLOADS_ANCHOR/.test(pipeline.text())) {
	errors.push(
		'release notes must not rely on a jump link to the downloads (it cannot scroll on the first click)'
	);
}
// The in-app Versions pages show the changelog first; they find it through the
// invisible section markers, which the page splitter reads before the Markdown
// renderer strips every comment. The names come from the splitter itself.
const splitterSandbox = { window: {} };
vm.createContext(splitterSandbox);
vm.runInContext(
	fs.readFileSync(
		path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui', 'changelog', 'release_body.js'),
		'utf8'
	),
	splitterSandbox,
	{ filename: 'release_body.js' }
);
const sectionNames = splitterSandbox.window.RELEASE_BODY_SECTIONS || [];
if (sectionNames.length < 4) {
	errors.push(
		`release_body.js exports ${sectionNames.length} section name(s); the marker pin would check nothing`
	);
}
const openMarkers = [...releaseBody.matchAll(/<!-- ergopti:section=([a-z]+) -->/g)].map(
	(m) => m[1]
);
const closeMarkers = releaseBody.match(/<!-- \/ergopti:section -->/g) || [];
if (
	JSON.stringify(openMarkers) !== JSON.stringify(sectionNames) ||
	closeMarkers.length !== sectionNames.length
) {
	errors.push(
		`the release body must open each section once, in the splitter's order (${sectionNames.join(', ')}), and ` +
			`close each one: found ${openMarkers.join(', ') || 'none'} with ${closeMarkers.length} close marker(s)`
	);
}
const changelogOpen = releaseBody.indexOf('<!-- ergopti:section=changelog -->');
if (!(changelogOpen >= 0 && changelogOpen < foldAt && foldAt < changelogAt)) {
	errors.push(
		'the changelog marker must open before its <details> fold and the changelog it wraps'
	);
}
// The repository sidebar truncates long release titles, which hid the version.
// The title is computed in shell once, in validate's plan; later steps only forward it via ${{ }}.
const titles = pipeline.text().match(/^\s*title="(?!\$\{\{)[^"\n]*"/gm) || [];
if (titles.length === 0 || titles.some((line) => line.trim() !== 'title="Ergopti ${tag}"')) {
	errors.push(
		`every release title must be exactly "Ergopti \${tag}", got: ${titles.map((t) => t.trim()).join(' | ')}`
	);
}
const layoutSection = releaseBody.indexOf('### Ergopti — keyboard layout only');
const applicationSection = releaseBody.indexOf(
	'### Ergopti Plus — application with advanced typing tools'
);
if (layoutSection < 0 || applicationSection <= layoutSection) {
	errors.push('release notes must explain keyboard layouts before the companion application');
}

// Fresh public macOS artifacts are admitted by their actual canonical owner,
// in addition to the retained historical/common release requirements above.
const publication = require('../build/macos-release-publication.cjs');
const freshMacosFiles = publication
	.bindings()
	.flatMap((archive) => [archive.name, `_${archive.name}.sig`]);
freshMacosFiles.push(publication.RECEIPT);
for (const name of freshMacosFiles) {
	if (!uploadedNames.has(name) && !uploadedGlobs.some((pattern) => pattern.test(name)))
		errors.push(`the fresh macOS publication file ${name} has no assets-* upload owner`);
}
if (
	!preflight.includes('if [ "$create_release" = true ]; then') ||
	!preflight.includes('node tools/build/macos-release-publication.cjs validate release-assets')
)
	errors.push(
		'fresh macOS publication must validate its whole canonical signing receipt before publication'
	);

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] the release notes link to files the release does not contain:\x1b[0m'
	);
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

/** Names the assets-* artifacts whose upload list holds `name`. */
function providersOf(name) {
	return uploads
		.filter((u) =>
			u.files.some((file) => {
				const base = file.split('/').pop();
				if (!IS_GLOB.test(base)) return base === name;
				const pattern = base
					.replace(/[.+^${}()|\\]/g, '\\$&')
					.replace(/\*/g, '.*')
					.replace(/\?/g, '.');
				return new RegExp(`^${pattern}$`).test(name);
			})
		)
		.map((u) => u.artifact);
}

console.log(
	`\x1b[32m[OK] all ${linked.size} asset(s) linked by the release notes are uploaded by one of the ` +
		`${uploads.length} assets-* upload step(s) (${uploadedPathCount} path(s) inventoried), and the ` +
		`release preflight requires all ${required.length} release file(s):\x1b[0m`
);
for (const name of required) console.log(`    ${name} <- ${providersOf(name).join(', ')}`);
