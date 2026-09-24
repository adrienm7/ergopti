// tools/build/release-channel.cjs

/**
 * ==============================================================================
 * MODULE: Release Channel Resolver
 * DESCRIPTION:
 * Prints the update channel that owns a release tag, as the shared registry
 * (_shared/modules/updater/channels.json) decides it through the canonical
 * matcher (_shared/ui/update_channels.js). The release workflow stamps this id
 * into the Windows bundle, the macOS bundle and its Sparkle appcast.
 *
 * WHY THIS EXISTS:
 * The workflow used to turn GitHub's prerelease flag into "dev" or "main" in
 * five places. A second prerelease channel would have been stamped as dev, and
 * its builds would have followed the wrong feed. The tag is what every driver
 * reads to decide a release's channel, so the workflow reads it the same way.
 *
 * USAGE:  node tools/build/release-channel.cjs <tag>
 *         Exits 1, printing nothing on stdout, when no channel owns the tag.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const REGISTRY_PATH = path.join(SHARED, 'modules', 'updater', 'channels.json');
const MATCHER_PATH = path.join(SHARED, 'ui', 'update_channels.js');

/**
 * Builds the registry interpreter exactly as the pages load it: a plain script.
 * @return {Object} The frozen channel API of update_channels.js.
 */
function loadChannels() {
	const sandbox = {};
	sandbox.window = sandbox;
	vm.createContext(sandbox);
	vm.runInContext(fs.readFileSync(MATCHER_PATH, 'utf8'), sandbox, { filename: MATCHER_PATH });
	return sandbox.createUpdateChannels(JSON.parse(fs.readFileSync(REGISTRY_PATH, 'utf8')));
}

function main(args) {
	if (args.length !== 1 || args[0] === '') {
		console.error('usage: node tools/build/release-channel.cjs <tag>');
		return 1;
	}
	const tag = args[0];
	const channel = loadChannels().channelForTag(tag);
	if (channel === null) {
		console.error(`release-channel: no update channel owns the tag ${JSON.stringify(tag)}.`);
		return 1;
	}
	process.stdout.write(`${channel}\n`);
	return 0;
}

process.exitCode = main(process.argv.slice(2));
