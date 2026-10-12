#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { resolveSiteContext } from './site-context.cjs';

function main() {
	const context = resolveSiteContext(process.env, (args) =>
		execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
	);
	const text = JSON.stringify(context, null, 2) + '\n';
	const outDir = resolve(process.cwd(), 'static');
	mkdirSync(outDir, { recursive: true });
	const outFile = resolve(outDir, 'version.json');
	writeFileSync(outFile, text, 'utf8');
	console.log('Wrote', outFile, 'branch=', context.branch);

	// The development server reads the same metadata at the project root.
	const rootOut = resolve(process.cwd(), 'version.json');
	writeFileSync(rootOut, text, 'utf8');
	console.log('Wrote', rootOut, 'branch=', context.branch);
}

main();
