// tools/lib/kbd-dll/build.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL Build
 * DESCRIPTION:
 * Compiles the emitted C and resource script into the four layout DLL images
 * with the LLVM toolchain, on any OS and without the WDK or MSKLC: clang for
 * i686, x86_64 and aarch64 Windows targets, llvm-rc for the resources and
 * lld-link for a DLL with no entry point, no CRT and KbdLayerDescriptor
 * exported at ordinal 1.
 *
 * FEATURES & RATIONALE:
 * 1. Reproducible: /Brepro fixes the timestamp, so the same model gives the
 *    same bytes; /release writes the image checksum the loader may check.
 * 2. Subsystem native, as Microsoft's layout DLLs are linked; tables stay in
 *    .rdata (no section is merged into a writable one).
 * 3. Fail fast: a missing tool or a refused compile throws with the tool's own
 *    message; nothing partial is returned.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const Emit = require('./emit-c.cjs');
const Model = require('./model.cjs');

// clang target and lld-link machine of each image.
const TARGETS = Object.freeze({
	x86: { triple: 'i686-pc-windows-msvc', machine: 'X86', defines: [] },
	wow64: { triple: 'i686-pc-windows-msvc', machine: 'X86', defines: ['-DKBD_WOW64'] },
	x64: { triple: 'x86_64-pc-windows-msvc', machine: 'X64', defines: [] },
	arm64: { triple: 'aarch64-pc-windows-msvc', machine: 'ARM64', defines: [] }
});
const TOOLS = Object.freeze({ clang: 'clang', rc: 'llvm-rc', link: 'lld-link' });

/** Runs one tool; throws with its output when it fails or is missing. */
function run(tool, args, cwd) {
	const result = spawnSync(tool, args, { cwd, encoding: 'utf8', timeout: 120000 });
	if (result.error) throw new Error(`kbd_dll_tool_missing: ${tool}: ${result.error.message}`);
	if (result.status !== 0)
		throw new Error(
			`kbd_dll_tool_failed: ${tool} ${args.join(' ')}\n${result.stdout}${result.stderr}`
		);
}

/** Whether the three LLVM tools answer; the tests and CLI refuse without them. */
function toolchainAvailable() {
	return Object.values(TOOLS).every((tool) => {
		const result = spawnSync(tool, ['--version'], { encoding: 'utf8' });
		return !result.error && (result.status === 0 || tool === TOOLS.rc);
	});
}

/**
 * Builds the four DLL images of a model.
 * @param {object} input - A kbd tables model.
 * @returns {{sources: {c: string, rc: string, def: string}, dlls: Object<string, Buffer>}}
 */
function buildDlls(input) {
	const model = Model.check(input);
	const name = model.dll_name;
	const sources = { c: Emit.emitC(model), rc: Emit.emitRc(model), def: Emit.emitDef(model) };
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kbd-dll-'));
	try {
		fs.writeFileSync(path.join(dir, `${name}.c`), sources.c);
		fs.writeFileSync(path.join(dir, `${name}.rc`), sources.rc);
		fs.writeFileSync(path.join(dir, `${name}.def`), sources.def);
		run(TOOLS.rc, ['/C', '65001', '/FO', `${name}.res`, `${name}.rc`], dir);
		const dlls = {};
		for (const [arch, target] of Object.entries(TARGETS)) {
			const obj = `${name}_${arch}.obj`;
			run(
				TOOLS.clang,
				[
					`--target=${target.triple}`,
					'-O2',
					'-ffreestanding',
					'-fno-builtin',
					'-fno-stack-protector',
					'-Werror',
					...target.defines,
					'-c',
					`${name}.c`,
					'-o',
					obj
				],
				dir
			);
			const out = `${name}_${arch}.dll`;
			run(
				TOOLS.link,
				[
					'/dll',
					'/noentry',
					'/nodefaultlib',
					`/machine:${target.machine}`,
					'/subsystem:native',
					`/def:${name}.def`,
					'/Brepro',
					'/release',
					`/out:${out}`,
					obj,
					`${name}.res`
				],
				dir
			);
			dlls[arch] = fs.readFileSync(path.join(dir, out));
		}
		return { sources, dlls };
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

module.exports = { TARGETS, TOOLS, buildDlls, toolchainAvailable };
