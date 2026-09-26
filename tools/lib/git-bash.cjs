// tools/lib/git-bash.cjs

/**
 * ==============================================================================
 * MODULE: The Bash A Tool Spawns
 * DESCRIPTION:
 * The single resolver for the bash that build and test scripts spawn.
 *
 * WHY A BARE "bash" IS WRONG ON WINDOWS:
 * PATH order decides which executable answers, and from PowerShell or cmd the
 * first one is WSL's launcher (System32\bash.exe or WindowsApps\bash.exe). The
 * script then runs inside a Linux distribution, with /mnt/<drive> paths, a
 * checkout whose .git file points at a Windows path, and none of the host's
 * tools. Measured on 2026-09-26: six JS suite checks were red from PowerShell
 * for that reason alone and green from Git Bash, where PATH lists Git's bash
 * first. Each script had grown its own resolver, and the fallbacks disagreed:
 * some fell back to a bare "bash", one to "/bin/bash", one to a fixed
 * C:\Program Files path.
 *
 * FEATURES & RATIONALE:
 * 1. Windows resolves Git for Windows' own bash from `git --exec-path`, the
 *    installation the repository is already driven with, whatever PATH says.
 * 2. Missing is loud: no git, or a Git with no bash, throws. A test that needs
 *    bash fails instead of skipping or reaching WSL.
 * 3. Elsewhere /bin/bash, the interpreter the replayed scripts' shebangs name
 *    (#!/bin/bash): on macOS that is bash 3.2, so a construct it rejects fails
 *    here as it would for users, even when Homebrew's bash comes first on
 *    PATH. A host with no /bin/bash (NixOS) has no bash the shebangs could
 *    name, and takes PATH's bash.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

/** The interpreter the repository's `#!/bin/bash` scripts name. */
const SYSTEM_BASH = '/bin/bash';

let cachedRoot = null;

/**
 * The Git for Windows installation root: the nearest ancestor of
 * `git --exec-path` that carries the MSYS userland (usr/bin/sh.exe).
 * @returns {string} Absolute directory.
 * @throws {Error} When git cannot run or has no MSYS userland above it.
 */
function gitForWindowsRoot() {
	if (cachedRoot) return cachedRoot;
	const git = spawnSync('git', ['--exec-path'], { encoding: 'utf8' });
	if (git.error || git.status !== 0 || !git.stdout.trim()) {
		throw new Error(
			`git --exec-path failed, so Git for Windows' bash cannot be located: ${git.error || git.stderr}`
		);
	}
	const execPath = path.resolve(git.stdout.trim());
	let root = execPath;
	while (!fs.existsSync(path.join(root, 'usr', 'bin', 'sh.exe'))) {
		const parent = path.dirname(root);
		if (parent === root) throw new Error(`no Git for Windows MSYS userland above ${execPath}`);
		root = parent;
	}
	cachedRoot = root;
	return root;
}

/**
 * The bash executable to spawn: Git for Windows' bin/bash.exe on Windows,
 * which puts the MSYS tools on the script's PATH, and /bin/bash elsewhere
 * (PATH's "bash" on a host that has none).
 * @returns {string}
 * @throws {Error} On Windows, when Git for Windows ships no bash.
 */
function bashExecutable() {
	if (process.platform !== 'win32') return fs.existsSync(SYSTEM_BASH) ? SYSTEM_BASH : 'bash';
	const bash = path.join(gitForWindowsRoot(), 'bin', 'bash.exe');
	if (!fs.existsSync(bash)) throw new Error(`Git for Windows has no ${bash}`);
	return bash;
}

module.exports = { SYSTEM_BASH, bashExecutable, gitForWindowsRoot };
