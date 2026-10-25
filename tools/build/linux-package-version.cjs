// tools/build/linux-package-version.cjs

/**
 * MODULE: Linux Package Version Projection
 * Derives metadata from the verified copied runtime stamp. Nonrelease source
 * validation has no stamped version and explicitly uses the source package's
 * admitted version instead. Native package managers need tilde prereleases so
 * development builds sort before their corresponding stable core version.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const { loadChannels } = require('./release-channel.cjs');

function main(args) {
	if (args.length !== 3 || !['deb', 'rpm', 'appimage', 'flatpak'].includes(args[0]))
		throw new Error(
			'usage: linux-package-version.cjs deb|rpm|appimage|flatpak <copied shared tree> <source package.json>'
		);
	const [format, shared, sourcePackage] = args;
	const stamp = spawnSync(
		bashExecutable(),
		[path.join(__dirname, 'write_build_stamp.sh'), 'read-version', shared],
		{ encoding: 'utf8' }
	);
	if (stamp.error || stamp.status !== 0)
		throw new Error(`copied build stamp refused: ${stamp.error?.message || stamp.stderr.trim()}`);
	let version = stamp.stdout.trim();
	let origin = 'copied release stamp';
	if (!version) {
		version = JSON.parse(fs.readFileSync(sourcePackage, 'utf8')).version;
		origin = `source-validation package ${sourcePackage}`;
	}
	if (typeof version !== 'string' || loadChannels().channelForTag(version) === null)
		throw new Error(`${origin} has no admitted release version: ${JSON.stringify(version)}`);
	const projected = format === 'deb' || format === 'rpm' ? version.replace('-', '~') : version;
	console.error(`[package-version] ${format}: ${version} from ${origin} -> ${projected}`);
	process.stdout.write(`${projected}\n`);
}

try {
	main(process.argv.slice(2));
} catch (error) {
	console.error(`[package-version] ERROR: ${error.message}`);
	process.exitCode = 1;
}
