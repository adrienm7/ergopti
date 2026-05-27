#!/usr/bin/env node
import { execSync } from 'child_process';
import { writeFileSync, mkdirSync } from 'fs';
import { resolve } from 'path';

function getBranch() {
	try {
		const branch = execSync('git rev-parse --abbrev-ref HEAD', { encoding: 'utf8' }).trim();
		return branch;
	} catch (e) {
		return null;
	}
}

function main() {
	const branch = getBranch() || 'main';
	const outDir = resolve(process.cwd(), 'static');
	try {
		mkdirSync(outDir, { recursive: true });
	} catch (e) {}
	const outFile = resolve(outDir, 'version.json');
	writeFileSync(outFile, JSON.stringify({ branch }, null, 2), 'utf8');
	console.log('Wrote', outFile, 'branch=', branch);

	// Also write to project root so Vite serves it at /version.json
	try {
		const rootOut = resolve(process.cwd(), 'version.json');
		writeFileSync(rootOut, JSON.stringify({ branch }, null, 2), 'utf8');
		console.log('Wrote', rootOut, 'branch=', branch);
	} catch (e) {}
}

main();
