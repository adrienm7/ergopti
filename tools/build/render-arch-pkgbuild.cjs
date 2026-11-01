// tools/build/render-arch-pkgbuild.cjs

/**
 * MODULE: Arch Recipe Renderer
 * Fills the tools/build/PKGBUILD template from the release tarball it repacks:
 * the tarball's SHA-256, the version its build stamp names (the source
 * package's own version on a non-release validation run, as
 * linux-package-version.cjs does) and that version's release tag. Writes the
 * rendered PKGBUILD and its pacman hook ergopti.install into one directory,
 * which is what the release attaches and what `makepkg -si` reads.
 *
 * Usage: node tools/build/render-arch-pkgbuild.cjs <release tarball> <output directory>
 */
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { loadChannels } = require('./release-channel.cjs');

const ROOT = path.resolve(__dirname, '../..');
const TEMPLATE = path.join(__dirname, 'PKGBUILD');
const HOOK = path.join(__dirname, 'ergopti.install');
const SOURCE_PACKAGE = path.join(ROOT, 'package.json');
// The stamp member of the tarball and its version key (write_build_stamp.sh).
const STAMP_MEMBER = '_shared/build_stamp.txt';
const VERSION_KEY = 'version';
const PLACEHOLDERS = ['__PKGVER__', '__TAG__', '__SHA256__'];

/**
 * Projects a release version onto pacman's grammar: no hyphen is allowed, and
 * a prerelease must sort before its stable core, which pacman's vercmp does for
 * letters glued to the last number (1.2.3dev.4 < 1.2.3).
 * @param {string} version An admitted release version (x.y.z or x.y.z-pre).
 * @returns {string}
 */
function pacmanVersion(version) {
	return version.replace('-', '');
}

/**
 * Renders the recipe for one tarball.
 * @param {string} template The PKGBUILD template text.
 * @param {{version: string, sha256: string}} release The tarball's identity.
 * @returns {string}
 */
function render(template, release) {
	if (loadChannels().channelForTag(release.version) === null)
		throw new Error(`not an admitted release version: ${JSON.stringify(release.version)}`);
	if (!/^[a-f0-9]{64}$/.test(release.sha256)) throw new Error('the tarball SHA-256 is malformed');
	const values = {
		__PKGVER__: pacmanVersion(release.version),
		__TAG__: 'v' + release.version,
		__SHA256__: release.sha256
	};
	let text = template;
	for (const placeholder of PLACEHOLDERS) {
		if (text.split(placeholder).length !== 2)
			throw new Error(`the template must hold ${placeholder} exactly once`);
		text = text.replace(placeholder, () => values[placeholder]);
	}
	if (/__[A-Z0-9]+__/.test(text)) throw new Error('the rendered recipe kept a placeholder');
	return text;
}

/**
 * Reads the version a tarball's build stamp names, or the source package's
 * version when the stamp has none (a non-release validation build).
 * @param {string} tarball
 * @returns {string}
 */
function tarballVersion(tarball) {
	const stamp = spawnSync('tar', ['-xzOf', tarball, STAMP_MEMBER], { encoding: 'utf8' });
	if (stamp.error || stamp.status !== 0)
		throw new Error(
			`the tarball carries no ${STAMP_MEMBER}: ${stamp.error?.message || stamp.stderr.trim()}`
		);
	const line = stamp.stdout.split('\n').find((entry) => entry.startsWith(VERSION_KEY + '='));
	if (line) return line.slice(VERSION_KEY.length + 1);
	return JSON.parse(fs.readFileSync(SOURCE_PACKAGE, 'utf8')).version;
}

function main(args) {
	if (args.length !== 2)
		throw new Error('usage: render-arch-pkgbuild.cjs <release tarball> <output directory>');
	const [tarball, output] = args;
	const sha256 = crypto.createHash('sha256').update(fs.readFileSync(tarball)).digest('hex');
	const version = tarballVersion(tarball);
	const recipe = render(fs.readFileSync(TEMPLATE, 'utf8'), { version, sha256 });
	fs.mkdirSync(output, { recursive: true });
	fs.writeFileSync(path.join(output, 'PKGBUILD'), recipe);
	fs.copyFileSync(HOOK, path.join(output, 'ergopti.install'));
	console.log(`[arch-pkgbuild] ${version} (${sha256.slice(0, 12)}…) -> ${output}/PKGBUILD`);
}

if (require.main === module) {
	try {
		main(process.argv.slice(2));
	} catch (error) {
		console.error(`[arch-pkgbuild] ERROR: ${error.message}`);
		process.exitCode = 1;
	}
}

module.exports = { render, pacmanVersion, PLACEHOLDERS };
