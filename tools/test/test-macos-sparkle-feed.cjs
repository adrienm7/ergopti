// tools/test/test-macos-sparkle-feed.cjs

/**
 * Regression guard for the channel-specific Sparkle release contract.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..');
const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'ci.yml'), 'utf8');
const buildScript = fs.readFileSync(path.join(root, 'tools', 'build', 'build_macos_app.sh'), 'utf8');
const errors = [];

const macosJob = workflow.match(/\n  build-macos:\n([\s\S]*?)(?=\n  build-windows:)/)?.[1] ?? '';
const channelExpression =
	"${{ needs.resolve-release-meta.outputs.prerelease == 'true' && 'dev' || 'main' }}";
const channelAssignments = [...macosJob.matchAll(/ERGOPTI_CHANNEL:\s*(.+)/g)].map(
	(match) => match[1].trim()
);

if (channelAssignments.length !== 2) {
	errors.push(`the macOS release job must stamp exactly two channel consumers, found ${channelAssignments.length}`);
}
if (channelAssignments.some((value) => value !== channelExpression)) {
	errors.push('both the macOS bundle and appcast must derive their channel from prerelease metadata');
}

if (!buildScript.includes('/releases/download/sparkle-feed/appcast-$ERGOPTI_CHANNEL.xml')) {
	errors.push('SUFeedURL must target the permanent channel-specific Sparkle feed release');
}
if (/Rename appcast|_appcast-(?:main|dev)|build\/macos\/_appcast/.test(workflow)) {
	errors.push('the published appcast basename must not be renamed behind SUFeedURL');
}
if (!macosJob.includes('OUTPUT_PATH: build/macos/appcast-${{ needs.resolve-release-meta.outputs.prerelease')) {
	errors.push('appcast output must use the same resolved channel as the bundle');
}
if (!macosJob.includes('build/macos/appcast-*.xml')) {
	errors.push('the macOS artifact must preserve the exact appcast-{channel}.xml basename');
}
const feedPublishStep = workflow.match(
	/- name: Publish channel feed for Sparkle([\s\S]*?)(?=\n\s{6}- name:|\n  [a-z])/
);
if (!feedPublishStep || !/gh release upload sparkle-feed[\s\S]*--clobber/.test(feedPublishStep[1])) {
	errors.push('finalization must atomically refresh the permanent Sparkle channel feed');
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}

console.log('[OK] macOS Sparkle release metadata is channel-specific.');
