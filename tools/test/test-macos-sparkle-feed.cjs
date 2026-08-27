// tools/test/test-macos-sparkle-feed.cjs

/**
 * Regression guard for the channel-specific Sparkle release contract.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..');
const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'ci.yml'), 'utf8');
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

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}

console.log('[OK] macOS Sparkle release metadata is channel-specific.');
