// tools/test/fetch-real-ollama.cjs

/**
 * ==============================================================================
 * MODULE: Fetch The Real Ollama Release
 * DESCRIPTION:
 * Downloads the official Windows Ollama release the repository pins into a test
 * folder, refuses any other SHA-256, and unpacks the part the relay end-to-end
 * test runs: ollama.exe and its CPU libraries.
 *
 * FEATURES & RATIONALE:
 * 1. The GPU libraries are most of the 1.4 GB and no test inference needs them, so
 *    only they are left out; every test run republishes this folder through the
 *    real archive admission, which then stays quick and small.
 * 2. It touches no PATH, no user Ollama and no Ergopti data: the folder is
 *    %LOCALAPPDATA%\Programs\ergopti-ollama-e2e-<version>.
 *
 * USAGE:
 *   node tools/test/fetch-real-ollama.cjs [--keep-archive]
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { releaseHome, STAMP_NAME } = require('./lib/windows-real-ollama.cjs');
const runtime = require('./lib/windows-owned-runtime.cjs');

const ASSET = 'windows-amd64';
const RELEASE_URL = 'https://github.com/ollama/ollama/releases/download';
// What the zip holds that a CPU inference never loads.
const GPU_LIBRARY = /^lib\/ollama\/(cuda|rocm|vulkan)/i;

/** SHA-256 of a file, streamed: it is larger than a Buffer should hold. */
async function fileDigest(file) {
	const hash = crypto.createHash('sha256');
	for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
	return hash.digest('hex');
}

/** Extracts the archive's entries a CPU run needs, through the .NET reader. */
function extract(archive, target) {
	const script = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($env:ERGOPTI_ARCHIVE)
try {
	foreach ($entry in $zip.Entries) {
		if ($entry.Name -ceq '' -or $entry.FullName -match $env:ERGOPTI_SKIP) { continue }
		$output = [IO.Path]::GetFullPath([IO.Path]::Combine($env:ERGOPTI_TARGET, $entry.FullName))
		if (-not $output.StartsWith($env:ERGOPTI_TARGET + '\\')) { throw 'An entry leaves the folder.' }
		[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
		[IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $output)
	}
} finally { $zip.Dispose() }`;
	const done = spawnSync(
		runtime.POWERSHELL,
		['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
		{
			encoding: 'utf8',
			windowsHide: true,
			env: {
				...process.env,
				ERGOPTI_ARCHIVE: archive,
				ERGOPTI_TARGET: target,
				ERGOPTI_SKIP: GPU_LIBRARY.source
			}
		}
	);
	if (done.status !== 0) throw new Error(`The release did not unpack: ${done.stderr}`);
}

async function main() {
	if (process.platform !== 'win32') throw new Error('The Windows release is for Windows.');
	const pinned = JSON.parse(
		fs.readFileSync(path.join(runtime.SHARED, 'ai/data/ollama_release.json'), 'utf8')
	);
	const asset = pinned.assets[ASSET];
	const home = releaseHome();
	const archive = path.join(home, asset.filename);
	fs.mkdirSync(home, { recursive: true });
	if (!fs.existsSync(archive) || fs.statSync(archive).size !== asset.bytes) {
		const url = `${RELEASE_URL}/v${pinned.version}/${asset.filename}`;
		console.log(`Downloading ${url} (${asset.bytes} bytes).`);
		const done = spawnSync('curl.exe', ['-L', '-sS', '--fail', '-C', '-', '-o', archive, url], {
			stdio: 'inherit',
			windowsHide: true
		});
		if (done.status !== 0) throw new Error(`The download failed with exit ${done.status}.`);
	}
	const digest = await fileDigest(archive);
	if (digest !== asset.sha256) {
		fs.rmSync(archive, { force: true });
		throw new Error(`Refused and removed: the archive is ${digest}, the pin ${asset.sha256}.`);
	}
	const target = path.join(home, 'release');
	fs.rmSync(target, { recursive: true, force: true });
	fs.mkdirSync(target);
	extract(archive, target);
	fs.writeFileSync(
		path.join(home, STAMP_NAME),
		`${JSON.stringify({
			version: pinned.version,
			archive_sha256: digest,
			ollama_sha256: runtime.sha256File(path.join(target, 'ollama.exe'))
		})}\n`
	);
	if (!process.argv.includes('--keep-archive')) fs.rmSync(archive);
	console.log(`The real Ollama ${pinned.version} is ready in ${target}.`);
}

main().catch((error) => {
	console.error(error.message);
	process.exit(1);
});
