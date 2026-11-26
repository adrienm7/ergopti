// tools/build/release-channel.cjs

/**
 * ==============================================================================
 * MODULE: Release Channel Resolver
 * DESCRIPTION:
 * Prints the update channel that owns a release tag, as the shared registry
 * (_shared/updater/data/channels.json) decides it through the canonical
 * matcher (_shared/ui/update_channels.js). The release workflow stamps this id
 * into the Windows bundle, the macOS bundle and its Sparkle appcast. It also
 * prints the Sparkle feeds a published release replaces.
 *
 * WHY THIS EXISTS:
 * The workflow used to turn GitHub's prerelease flag into "dev" or "main" in
 * five places. A second prerelease channel would have been stamped as dev, and
 * its builds would have followed the wrong feed. The tag is what every driver
 * reads to decide a release's channel, so the workflow reads it the same way.
 * Each feed carries one release, its channel's latest: a stable release is in
 * the dev view too and outranks every prerelease of its version, so it must
 * replace the dev feed as well, or Sparkle on dev keeps offering the older
 * prerelease (v1.0.10-dev.179 after v1.0.10, 2026-11-26). The feeds are chosen
 * by the same pick rule the in-app updaters apply to the release list.
 *
 * USAGE:  node tools/build/release-channel.cjs <tag>
 *         Exits 1, printing nothing on stdout, when no channel owns the tag.
 *         node tools/build/release-channel.cjs feeds <tag> [<listed tag>...]
 *         Prints, one per line in registry order, the sparkle_feed of every
 *         channel whose latest release among <tag> and the listed tags is
 *         <tag>, so an older release never replaces a newer one's feed.
 *         Exits 1 when no channel owns <tag>.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { pathToFileURL } = require('url');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const REGISTRY_PATH = path.join(SHARED, 'updater', 'data', 'channels.json');
const MATCHER_PATH = path.join(SHARED, 'ui', 'update_channels.js');
const VERSION_PATH = path.join(SHARED, 'updater', 'data', 'version.js');

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

/**
 * Lists the Sparkle feeds a release replaces: those of every channel whose
 * latest release, by the shared pick rule, is this tag. The tag is put first,
 * so a listed copy of it keeps it on the tie.
 * @param {string} tag - The release being published.
 * @param {string[]} listed - Every other published release tag.
 * @param {Function} compare - Shared semver comparison (version.js).
 * @return {string[]|null} Feed file names in registry order, or null when no
 *   channel owns the tag.
 */
function feedsFor(tag, listed, compare) {
	const channels = loadChannels();
	if (channels.channelForTag(tag) === null) return null;
	const tags = [tag, ...listed];
	return channels.ids
		.filter((id) => channels.pickLatest(tags, id, compare) === 0)
		.map((id) => channels.channel(id).sparkleFeed);
}

/** Loads the shared semver comparison (an ES module). */
async function loadCompare() {
	return (await import(pathToFileURL(VERSION_PATH).href)).compareVersions;
}

async function main(args) {
	if (args[0] === 'feeds') {
		if (args.length < 2 || args[1] === '') {
			console.error('usage: node tools/build/release-channel.cjs feeds <tag> [<listed tag>...]');
			return 1;
		}
		const feeds = feedsFor(args[1], args.slice(2), await loadCompare());
		if (feeds === null) {
			console.error(`release-channel: no update channel owns the tag ${JSON.stringify(args[1])}.`);
			return 1;
		}
		process.stdout.write(feeds.map((feed) => `${feed}\n`).join(''));
		return 0;
	}
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

if (require.main === module) {
	main(process.argv.slice(2)).then(
		(code) => {
			process.exitCode = code;
		},
		(error) => {
			console.error(`release-channel: ${error.message}`);
			process.exitCode = 1;
		}
	);
}

module.exports = { loadChannels, feedsFor, loadCompare, REGISTRY_PATH };
