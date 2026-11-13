// tools/build/homebrew-cask.cjs

/**
 * ==============================================================================
 * MODULE: Homebrew Cask Generator
 * DESCRIPTION:
 * Writes the Homebrew cask of one released macOS build into a tap checkout:
 * Casks/ergoptiplus.rb for the most stable channel of the shared registry
 * (_shared/updater/data/channels.json), Casks/ergoptiplus@<id>.rb for every
 * other channel. The release workflow runs it after publishing a release and
 * pushes the result to the tap repository.
 *
 * WHY THIS EXISTS:
 * Homebrew no longer evaluates download URLs at install time and GitHub has no
 * stable URL for the newest prerelease, so a dev cask must name one exact
 * release and its checksum. The workflow knows both only after publishing, so
 * the cask is rendered there, from the same registry that decides the tag's
 * channel, instead of being maintained by hand.
 *
 * FEATURES & RATIONALE:
 * 1. One cask per channel, each conflicting with the others: the cask a user
 *    installs is the build, hence the channel, the app follows until they pick
 *    another channel in its About menu.
 * 2. Two update paths, one bundle: the app updates itself (Sparkle, the
 *    About menu, automatic checks), and brew upgrade updates it with the rest
 *    of the user's casks, so the cask does not declare auto_updates. brew
 *    quits the app before replacing the bundle (its Lua files load from it)
 *    and, from Homebrew 7, reopens the apps it quit once the upgrade succeeds.
 *    The launcher is quit first: it stops its embedded Hammerspoon, so only
 *    the launcher is reopened. After a Sparkle update, the next
 *    brew upgrade reinstalls the same version once, since brew only knows the
 *    version it installed.
 * 3. livecheck reads the channel's Sparkle appcast, the feed the app itself
 *    follows, so brew livecheck and the app agree on the newest version.
 * 4. The postflight steps clear the quarantine flag: the app is not
 *    notarised, and Gatekeeper would otherwise refuse to open it. Homebrew 7
 *    deprecates Ruby flight blocks for declarative steps run in its sandbox,
 *    which denies launching apps, hence reopening is left to brew itself.
 *
 * USAGE:  node tools/build/homebrew-cask.cjs <tag> <sha256> <tap-dir> [declared-asset]
 *         Prints the path of the cask it wrote, relative to <tap-dir>.
 *         node tools/build/homebrew-cask.cjs --token <channel>
 *         Prints the cask token of a channel (the release notes name it).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const identifiers = require('../lib/identifiers.cjs');
const { bindings } = require('./macos-release-publication.cjs');
const { loadChannels, REGISTRY_PATH } = require('./release-channel.cjs');

// Repository publishing the releases and the Sparkle appcasts
const SOURCE_REPOSITORY = 'adrienm7/ergopti';

// Branch serving the appcasts (ci.yml "Publish channel feed for Sparkle")
const APPCAST_BRANCH = 'sparkle-appcasts';

// Release asset and bundle name (tools/build/build_macos_app.sh)
const ASSET_NAME = bindings().find((archive) => archive.format === 'zip')?.name;
if (!ASSET_NAME) throw new Error('The historical macOS cask binding is absent.');
const APP_NAME = identifiers.app.bundle;

// Launcher bundle identifier (tools/build/build_macos_app.sh BUNDLE_ID)
const BUNDLE_ID = identifiers.bundle_ids.launcher;

// Base cask token; channels other than the most stable one add @<id>
const TOKEN_BASE = 'ergoptiplus';

// The launcher's folder constants, generated from app_dirs.toml. The release
// job runs this script without node_modules, so it reads the generated file
// instead of parsing the TOML.
const APP_DIRS_SWIFT = path.join(
	__dirname,
	'..',
	'..',
	'static',
	'ergopti_plus',
	'macos',
	'launcher',
	'Sources',
	'ErgoptiPlus',
	'AppDirs.generated.swift'
);

/**
 * Returns one string constant of the generated launcher folder file.
 * @param {string} name Swift constant name, e.g. "kMacOSSupportHomeRelativePath".
 * @return {string}
 */
function appDirsConstant(name) {
	const source = fs.readFileSync(APP_DIRS_SWIFT, 'utf8');
	const match = source.match(new RegExp(`^let ${name} = "([^"\\\\]+)"$`, 'm'));
	if (!match) throw new Error(`homebrew-cask: ${name} is absent from ${APP_DIRS_SWIFT}.`);
	return match[1];
}

// The Ergopti folders --zap removes: the support root, which holds the
// configuration, paths.toml and the managed runtimes, then the logs and the cache
const ZAP_FOLDERS = [
	'kMacOSSupportHomeRelativePath',
	'kMacOSLogsHomeRelativePath',
	'kMacOSCacheHomeRelativePath'
].map((name) => `~/${appDirsConstant(name)}`);

// Oldest macOS the bundle declares (LSMinimumSystemVersion 11.0)
const MINIMUM_MACOS = ':big_sur';

/**
 * Returns the cask token of every registry channel, in stability order.
 * @return {Array<{id: string, token: string, feed: string}>}
 */
function caskChannels() {
	const registry = JSON.parse(fs.readFileSync(REGISTRY_PATH, 'utf8'));
	return registry.channels.map((channel, index) => ({
		id: channel.id,
		token: index === 0 ? TOKEN_BASE : `${TOKEN_BASE}@${channel.id}`,
		feed: channel.sparkle_feed
	}));
}

/**
 * Returns the cask token of one registry channel.
 * @param {string} id Channel id, e.g. "dev".
 * @return {string} e.g. "ergoptiplus@dev".
 */
function tokenForChannel(id) {
	const entry = caskChannels().find((channel) => channel.id === id);
	if (entry === undefined) {
		throw new Error(`homebrew-cask: ${JSON.stringify(id)} is not a registry channel.`);
	}
	return entry.token;
}

/**
 * Renders the cask of one release.
 * @param {string} tag Release tag, e.g. "v1.0.10-dev.170".
 * @param {string} sha256 Lowercase hex checksum of the selected release archive.
 * @return {{token: string, file: string, text: string}}
 */
function renderCask(tag, sha256, assetName = ASSET_NAME) {
	if (!bindings().some((archive) => archive.name === assetName))
		throw new Error('homebrew-cask: undeclared macOS archive.');
	if (typeof tag !== 'string' || !tag.startsWith('v')) {
		throw new Error(`homebrew-cask: a release tag starts with "v", got ${JSON.stringify(tag)}.`);
	}
	if (typeof sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(sha256)) {
		throw new Error(`homebrew-cask: expected a lowercase SHA-256, got ${JSON.stringify(sha256)}.`);
	}
	const version = tag.slice(1);
	const channelId = loadChannels().channelForTag(tag);
	if (channelId === null) {
		throw new Error(`homebrew-cask: no update channel owns the tag ${JSON.stringify(tag)}.`);
	}
	const channels = caskChannels();
	const channel = channels.find((entry) => entry.id === channelId);
	const others = channels.filter((entry) => entry.id !== channelId);
	const suffix = channel.token === TOKEN_BASE ? '' : ` (${channel.id} channel)`;
	const lines = [
		`# Generated by ${SOURCE_REPOSITORY} tools/build/homebrew-cask.cjs on release ${tag}; do not edit.`,
		`cask "${channel.token}" do`,
		`  version "${version}"`,
		`  sha256 "${sha256}"`,
		'',
		`  url "https://${identifiers.hosts.github}/${SOURCE_REPOSITORY}/releases/download/v#{version}/${assetName}"`,
		`  name "Ergopti+${suffix}"`,
		'  desc "Ergopti keyboard layout companion: hotstrings, tap-holds, gestures and AI"',
		'  homepage "https://ergopti.fr/"',
		'',
		'  livecheck do',
		`    url "https://raw.githubusercontent.com/${SOURCE_REPOSITORY}/${APPCAST_BRANCH}/${channel.feed}"`,
		'    strategy :sparkle, &:short_version',
		'  end',
		'',
		...others.map((other) => `  conflicts_with cask: "${other.token}"`),
		`  depends_on macos: ${MINIMUM_MACOS}`,
		'',
		`  app "${APP_NAME}"`,
		'',
		'  # A running app loads its Lua files from the bundle: brew quits it before the',
		'  # bundle is replaced and reopens it after an upgrade. Quitting the launcher',
		'  # stops its embedded Hammerspoon, so only the launcher is reopened; the',
		'  # second identifier stops a Hammerspoon left without its launcher.',
		`  uninstall quit: ["${BUNDLE_ID}", "${BUNDLE_ID}.hammerspoon"]`,
		'',
		'  # The app is not notarised: without this, Gatekeeper refuses to open it.',
		'  postflight_steps do',
		'    run "/usr/bin/xattr",',
		`        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/${APP_NAME}"],`,
		'        must_succeed:   false,',
		`        writable_paths: ["{{appdir}}/${APP_NAME}"]`,
		'  end',
		'',
		'  zap trash: [',
		...ZAP_FOLDERS.map((folder) => `    "${folder}",`),
		`    "~/Library/Caches/${BUNDLE_ID}",`,
		`    "~/Library/HTTPStorages/${BUNDLE_ID}",`,
		`    "~/Library/Preferences/${BUNDLE_ID}.plist",`,
		'  ]',
		'end',
		''
	];
	return {
		token: channel.token,
		file: path.join('Casks', `${channel.token}.rb`),
		text: lines.join('\n')
	};
}

function main(args) {
	if (args.length === 2 && args[0] === '--token') {
		process.stdout.write(`${tokenForChannel(args[1])}\n`);
		return 0;
	}
	if (![3, 4].includes(args.length) || args.some((arg) => arg === '')) {
		console.error(
			'usage: node tools/build/homebrew-cask.cjs <tag> <sha256> <tap-dir> [declared-asset] | --token <channel>'
		);
		return 1;
	}
	const [tag, sha256, tapDir, assetName = ASSET_NAME] = args;
	const cask = renderCask(tag, sha256, assetName);
	const target = path.join(tapDir, cask.file);
	fs.mkdirSync(path.dirname(target), { recursive: true });
	fs.writeFileSync(target, cask.text);
	process.stdout.write(`${cask.file}\n`);
	return 0;
}

if (require.main === module) {
	process.exitCode = main(process.argv.slice(2));
}

module.exports = {
	renderCask,
	caskChannels,
	tokenForChannel,
	TOKEN_BASE,
	SOURCE_REPOSITORY,
	APPCAST_BRANCH,
	ASSET_NAME,
	APP_NAME,
	BUNDLE_ID,
	MINIMUM_MACOS,
	ZAP_FOLDERS
};
