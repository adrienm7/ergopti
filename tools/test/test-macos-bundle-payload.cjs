// tools/test/test-macos-bundle-payload.cjs

/**
 * ==============================================================================
 * MODULE: macOS Bundle Payload Guard
 * DESCRIPTION:
 * Stages the packaged app's Contents/Resources/static payload exactly as
 * build_macos_app.sh does (tools/build/macos-bundle-payload.cjs) and proves
 * that every path the macOS runtime reads is inside it, and that no group the
 * runtime never reads has come back.
 *
 * ROOT CAUSE ENCODED:
 * The app builder copied whole trees, so v0.0.0-dev.146 shipped 99 MB: an
 * unused 49 MB Karabiner-Elements installer (onboarding downloads its own
 * pinned DMG), a second copy of every locale, website screenshots, tests,
 * documentation and debug symbols. Trimming that by hand is only safe when a
 * guard knows what the runtime reads; without one, the next exclusion that
 * catches a real runtime file ships an app that fails in the field.
 *
 * FEATURES & RATIONALE:
 * 1. The staged set is the real stager's output, compared with the resolver,
 *    so the guard judges the bytes the build ships, with their modes.
 * 2. Runtime references are read from the staged sources themselves: every
 *    require(), every path-like literal of the Lua, shell and JavaScript files
 *    (relative to the file, the driver root and the shared root), and every
 *    src/href of the WebView pages. A reference that resolves in the complete
 *    repository trees must resolve in the staged set too, so an exclusion can
 *    never remove a file the runtime opens.
 * 3. Reads that no literal shows (a file name joined at run time, the
 *    launcher's init.lua) are listed in CURATED_READS; each entry is pinned to
 *    the source text that makes it, so a moved reader invalidates the entry
 *    instead of leaving it stale. Every staged image must be one of them.
 * 4. Excluded groups are judged independently of the manifest (tests,
 *    documentation, debug symbols, developer tooling, launcher sources,
 *    duplicate top-level copies, a checkout's own state, the Karabiner
 *    installer, the Ollama binary), so deleting a manifest exclusion cannot
 *    quietly bring its files back.
 * 5. A self-check removes one runtime file per reference kind and injects one
 *    forbidden file per group: the guard must report each, or it could not
 *    fail for the regression it exists to catch.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

const payload = require('../build/macos-bundle-payload.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BUILD_REL = 'tools/build/build_macos_app.sh';
const BUILD = fs.readFileSync(path.join(ROOT, BUILD_REL), 'utf8');

// Static-root-relative roots the runtime resolves literals against
const DRIVER_ROOT = 'ergopti_plus/macos';
const SHARED_ROOT = 'ergopti_plus/_shared';

// Static-root entries the packaged app may contain: the staged trees plus the
// directories the keyboard-layout and registry functions own
const ALLOWED_TOP_LEVEL = new Set(['ergopti_plus', 'img', 'ergopti', 'layouts']);

// Reads that no path literal of the reader shows. `reader` is a staged target
// or, for the launcher, a repository path; every `needle` must still be in it.
const CURATED_READS = [
	{
		reader: 'repo:static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/main.swift',
		needles: ['/Contents/Resources/static/ergopti_plus/macos"', 'bundledConfigDir() + "/init.lua"'],
		targets: ['ergopti_plus/macos/init.lua'],
		why: 'the launcher points MJConfigFile at the bundled init.lua'
	},
	{
		reader: 'ergopti_plus/macos/ui/menu/init.lua',
		needles: [
			'base_dir .. "../../img/logo/"',
			'"logo_simple.png"',
			'"logo_simple_disabled.png"',
			'"logo_black.png"',
			'"logo_white.png"'
		],
		targets: [
			'img/logo/logo_simple.png',
			'img/logo/logo_simple_disabled.png',
			'img/logo/logo_black.png',
			'img/logo/logo_white.png'
		],
		why: 'the menu bar icon joins one of four logo names to the logo folder'
	},
	{
		reader: 'ergopti_plus/macos/infra/notifications.lua',
		needles: ['_base .. "../../../img/logo/logo_simple.png"'],
		targets: ['img/logo/logo_simple.png'],
		why: 'notifications carry the logo'
	},
	{
		reader: 'ergopti_plus/macos/modules/llm/ensure-mlx-deps.sh',
		needles: [
			'HS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"',
			'"$HS_ROOT/pyproject.toml"',
			'"$HS_ROOT/uv.lock"'
		],
		targets: ['ergopti_plus/macos/pyproject.toml', 'ergopti_plus/macos/uv.lock'],
		why: 'the MLX bootstrap fingerprints and syncs the committed Python project'
	},
	{
		reader: 'ergopti_plus/macos/modules/llm/network-retry.sh',
		needles: ['"$SCRIPT_DIR/managed_bootstrap_http.py"'],
		targets: ['ergopti_plus/macos/modules/llm/managed_bootstrap_http.py'],
		why: 'native bootstrap downloads use the bundled offline-input producer'
	},
	{
		reader: 'ergopti_plus/macos/modules/llm/managed_bootstrap_http.py',
		needles: [
			'SHARED_ROOT / "data/http/redirect_policy.json"',
			'SHARED_ROOT / "python/network_proxy_policy.py"',
			'SHARED_ROOT / "modules/llm/managed_python_release.json"',
			'DRIVER_ROOT / "platform/network/native_http.py"'
		],
		targets: [
			'ergopti_plus/_shared/data/http/redirect_policy.json',
			'ergopti_plus/_shared/python/network_proxy_policy.py',
			'ergopti_plus/_shared/modules/llm/managed_python_release.json',
			'ergopti_plus/macos/platform/network/native_http.py'
		],
		why: 'offline inputs retain the canonical routing policy, pinned Python and native request owner'
	},
	{
		reader: 'ergopti_plus/macos/ui/menu/menu_llm/models_manager_mlx_download.lua',
		needles: ['from managed_http import install_huggingface_transport'],
		targets: ['ergopti_plus/macos/platform/network/managed_http.py'],
		why: 'the emitted Hugging Face downloader activates the bundled native HTTPX transport'
	},
	{
		reader: 'ergopti_plus/macos/platform/network/managed_http.py',
		needles: [
			'with_name("native_http.py")',
			'_ROOT.parent / "_shared/python/network_proxy_policy.py"'
		],
		targets: [
			'ergopti_plus/macos/platform/network/native_http.py',
			'ergopti_plus/_shared/python/network_proxy_policy.py'
		],
		why: 'the HTTPX transport loads the exact native protocol owner and shared policy'
	},
	{
		reader: 'ergopti_plus/macos/modules/llm/managed_ollama_runtime.py',
		needles: [
			'SHARED / "python/managed_ollama_runtime.py"',
			'DRIVER / "modules/llm/managed_bootstrap_http.py"',
			'SHARED / "python/network_proxy_policy.py"',
			'SHARED / "python/managed_source_alias.py"',
			'SHARED / "modules/llm/managed_ollama_runtime.json"',
			'SHARED / "modules/llm/managed_ollama_release.json"'
		],
		targets: [
			'ergopti_plus/_shared/python/managed_ollama_runtime.py',
			'ergopti_plus/macos/modules/llm/managed_bootstrap_http.py',
			'ergopti_plus/_shared/python/network_proxy_policy.py',
			'ergopti_plus/_shared/python/managed_source_alias.py',
			'ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json',
			'ergopti_plus/_shared/modules/llm/managed_ollama_release.json'
		],
		why: 'native runtime admission retains its canonical source, alias and network policy'
	},
	{
		reader: 'ergopti_plus/macos/modules/llm/managed_ollama_pull.py',
		needles: [
			'DRIVER / "platform/network/native_ollama_api.py"',
			'with_name("managed_ollama_runtime.py")',
			'SHARED / "python/managed_ollama_pull.py"',
			'SHARED / "python/managed_ollama_sessions.py"',
			'SHARED / "python/managed_operation_receipt.py"',
			'SHARED / "python/managed_ollama_operation_authority.py"',
			'with_name("managed_ollama_cleanup.py")',
			'DRIVER / "platform/ollama_daemon_authority.py"',
			'DRIVER / "platform/ollama_bootstrap_owner.py"',
			'SHARED / "python/network_proxy_policy.py"',
			'SHARED / "modules/llm/managed_ollama_bootstrap.json"'
		],
		targets: [
			'ergopti_plus/macos/platform/network/native_ollama_api.py',
			'ergopti_plus/macos/modules/llm/managed_ollama_runtime.py',
			'ergopti_plus/_shared/python/managed_ollama_pull.py',
			'ergopti_plus/_shared/python/managed_ollama_sessions.py',
			'ergopti_plus/_shared/python/managed_operation_receipt.py',
			'ergopti_plus/_shared/python/managed_ollama_operation_authority.py',
			'ergopti_plus/macos/modules/llm/managed_ollama_cleanup.py',
			'ergopti_plus/macos/platform/ollama_daemon_authority.py',
			'ergopti_plus/macos/platform/ollama_bootstrap_owner.py',
			'ergopti_plus/_shared/python/network_proxy_policy.py',
			'ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json'
		],
		why: 'the request owner loads its original session, receipt and cleanup authorities'
	},
	{
		reader: 'ergopti_plus/macos/modules/llm/managed_ollama_cleanup.py',
		needles: [
			'DRIVER / "platform/network/native_ollama_api.py"',
			'SHARED / "python/managed_ollama_operation_authority.py"',
			'with_name("managed_ollama_runtime.py")',
			'SHARED / "python/managed_operation_receipt.py"'
		],
		targets: [
			'ergopti_plus/macos/platform/network/native_ollama_api.py',
			'ergopti_plus/_shared/python/managed_ollama_operation_authority.py',
			'ergopti_plus/macos/modules/llm/managed_ollama_runtime.py',
			'ergopti_plus/_shared/python/managed_operation_receipt.py'
		],
		why: 'explicit retirement resumes only the original request authority'
	},
	{
		reader: 'ergopti_plus/macos/adapters/managed_ollama_hint.lua',
		needles: ['driver .. "/modules/llm/managed_ollama_hint.py"'],
		targets: ['ergopti_plus/macos/modules/llm/managed_ollama_hint.py'],
		why: 'asynchronous metadata dispatch reads the fixed bundled native hint entry'
	},
	{
		reader: 'ergopti_plus/macos/modules/llm/managed_ollama_hint.py',
		needles: [
			'SHARED / "python/managed_ollama_runtime.py"',
			'SHARED / "python/managed_ollama_hint.py"',
			'DRIVER / "platform/ollama_hint_metadata.py"',
			'driver / "modules/llm/network-retry.sh"',
			'driver.parent / "_shared/modules/llm"',
			'shared / "managed_ollama_bootstrap.json"',
			'shared / "managed_ollama_runtime.json"',
			'shared / "managed_ollama_release.json"',
			'driver.parent / "_shared/modules/network/bootstrap_retry.json"'
		],
		targets: [
			'ergopti_plus/_shared/python/managed_ollama_runtime.py',
			'ergopti_plus/_shared/python/managed_ollama_hint.py',
			'ergopti_plus/macos/platform/ollama_hint_metadata.py',
			'ergopti_plus/macos/modules/llm/network-retry.sh',
			'ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json',
			'ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json',
			'ergopti_plus/_shared/modules/llm/managed_ollama_release.json',
			'ergopti_plus/_shared/modules/network/bootstrap_retry.json'
		],
		why: 'bounded metadata reads retain actual shared policy, native FD owner and catalogue inputs'
	},
	{
		reader: 'ergopti_plus/_shared/python/managed_ollama_pull.py',
		needles: ['Path(__file__).with_name("managed_ollama_runtime.py")'],
		targets: ['ergopti_plus/_shared/python/managed_ollama_runtime.py'],
		why: 'the shared operation caller retains the exact runtime admission policy'
	},
	{
		reader: 'ergopti_plus/macos/adapters/managed_ollama_pull.lua',
		needles: [
			'context.arguments[2]:gsub("/managed_ollama_pull%.py$", "/managed_ollama_cleanup.py")'
		],
		targets: ['ergopti_plus/macos/modules/llm/managed_ollama_cleanup.py'],
		why: 'explicit retirement derives its worker from the original caller script'
	},
	{
		reader: 'ergopti_plus/_shared/python/managed_ollama_sessions.py',
		needles: ['Path(__file__).with_name("managed_ollama_runtime.py")'],
		targets: ['ergopti_plus/_shared/python/managed_ollama_runtime.py'],
		why: 'session authentication reuses the shared runtime admission policy'
	},
	{
		reader: 'ergopti_plus/macos/modules/llm/managed_ollama_serve.py',
		needles: [
			'with_name("managed_ollama_runtime.py")',
			'DRIVER / "platform/suspended_image_owner.py"',
			'DRIVER / "platform/source_alias_owner.py"',
			'DRIVER / "platform/ollama_bootstrap_owner.py"',
			'DRIVER / "platform/ollama_daemon_authority.py"',
			'SHARED / "python/network_proxy_policy.py"',
			'DRIVER / "platform/network/native_http.py"',
			'SHARED / "modules/llm/managed_ollama_bootstrap.json"',
			'SHARED / "modules/network/proxy_policy.json"'
		],
		targets: [
			'ergopti_plus/macos/modules/llm/managed_ollama_runtime.py',
			'ergopti_plus/macos/platform/suspended_image_owner.py',
			'ergopti_plus/macos/platform/source_alias_owner.py',
			'ergopti_plus/macos/platform/ollama_bootstrap_owner.py',
			'ergopti_plus/macos/platform/ollama_daemon_authority.py',
			'ergopti_plus/_shared/python/network_proxy_policy.py',
			'ergopti_plus/macos/platform/network/native_http.py',
			'ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json',
			'ergopti_plus/_shared/modules/network/proxy_policy.json'
		],
		why: 'the serve owner binds original source, empty bootstrap and sealed daemon authority'
	},
	{
		reader: 'ergopti_plus/macos/platform/suspended_image_owner.py',
		needles: ['Path(__file__).with_name("trusted_native_guardian.py")'],
		targets: ['ergopti_plus/macos/platform/trusted_native_guardian.py'],
		why: 'the suspended original image uses only the admitted bundle guardian'
	},
	{
		reader: 'ergopti_plus/macos/platform/trusted_native_guardian.py',
		needles: ['Path(__file__).parent / "network/native_http.py"'],
		targets: ['ergopti_plus/macos/platform/network/native_http.py'],
		why: 'guardian admission retains the existing native helper trust boundary'
	},
	{
		reader: 'ergopti_plus/macos/platform/ollama_bootstrap_owner.py',
		needles: [
			'Path(__file__).with_name("suspended_image_owner.py")',
			'Path(__file__).absolute().parents[2] / "_shared/python/managed_ollama_bootstrap.py"'
		],
		targets: [
			'ergopti_plus/macos/platform/suspended_image_owner.py',
			'ergopti_plus/_shared/python/managed_ollama_bootstrap.py'
		],
		why: 'native descriptor ownership delegates bootstrap data and policy to shared code'
	},
	{
		reader: 'ergopti_plus/macos/platform/ollama_daemon_authority.py',
		needles: [
			'Path(__file__).with_name("suspended_image_owner.py")',
			'Path(__file__).absolute().parents[2] / "_shared/python/managed_ollama_daemon_authority.py"'
		],
		targets: [
			'ergopti_plus/macos/platform/suspended_image_owner.py',
			'ergopti_plus/_shared/python/managed_ollama_daemon_authority.py'
		],
		why: 'the same-session source receipt retains its shared lexical authority'
	},
	{
		reader: 'ergopti_plus/_shared/python/managed_ollama_daemon_authority.py',
		needles: [
			'Path(__file__).with_name("managed_ollama_runtime.py")',
			'Path(__file__).with_name("managed_source_alias.py")'
		],
		targets: [
			'ergopti_plus/_shared/python/managed_ollama_runtime.py',
			'ergopti_plus/_shared/python/managed_source_alias.py'
		],
		why: 'sealed source admission preserves the original session and strict alias policy'
	},
	{
		reader: 'ergopti_plus/macos/platform/source_alias_owner.py',
		needles: ['Path(__file__).resolve().parents[2] / "_shared/python/managed_source_alias.py"'],
		targets: ['ergopti_plus/_shared/python/managed_source_alias.py'],
		why: 'the native alias owner retains the canonical private namespace admission'
	},
	{
		reader: 'ergopti_plus/macos/platform/network/native_ollama_api.py',
		needles: [
			'Path(__file__).with_name("native_http.py")',
			'Path(__file__).resolve().parents[3] / "_shared/python/managed_source_alias.py"'
		],
		targets: [
			'ergopti_plus/macos/platform/network/native_http.py',
			'ergopti_plus/_shared/python/managed_source_alias.py'
		],
		why: 'authenticated loopback calls keep the actual native wire and alias contract'
	},
	{
		reader: 'ergopti_plus/macos/modules/llm/managed_native_python.lua',
		needles: [
			'require("core.llm.managed_python_locator")',
			'require("adapters.native_python_probe")',
			'require("adapters.timer_scheduler")',
			'require("modules.llm.bootstrap_retry_generated")'
		],
		targets: [
			'ergopti_plus/_shared/lua/core/llm/managed_python_locator.lua',
			'ergopti_plus/macos/adapters/native_python_probe.lua',
			'ergopti_plus/macos/adapters/timer_scheduler.lua',
			'ergopti_plus/macos/modules/llm/bootstrap_retry_generated.lua'
		],
		why: 'private Python selection consumes the generated pinned locator and retained native header probe'
	},
	{
		reader: 'ergopti_plus/macos/adapters/native_python_probe.lua',
		needles: ['require("modules.llm.bootstrap_retry_generated")'],
		targets: ['ergopti_plus/macos/modules/llm/bootstrap_retry_generated.lua'],
		why: 'the exact native header probe preserves canonical original admission and retirement budgets'
	},
	{
		reader: 'ergopti_plus/_shared/python/network_proxy_policy.py',
		needles: ['Path(__file__).parent.parent / "modules/network/proxy_policy.json"'],
		targets: ['ergopti_plus/_shared/modules/network/proxy_policy.json'],
		why: 'Python routing consumes the same canonical proxy policy as the other clients'
	}
];

// Paths that must never be staged, whatever the manifest says
const FORBIDDEN = [
	{ group: 'tests', test: (target) => /(^|\/)tests\//.test(target) },
	{ group: 'tests', test: (target) => target.startsWith(`${SHARED_ROOT}/lua/test/`) },
	{ group: 'tests', test: (target) => /(^|\/)test_[^/]*\.py$/.test(target) },
	{
		group: 'documentation',
		test: (target) => target.endsWith('.md') && !/(^|\/)LICENSES?\.md$/.test(target)
	},
	{ group: 'documentation', test: (target) => target.includes('/config_schema/examples/') },
	{ group: 'debug-symbols', test: (target) => target.includes('.dSYM/') },
	{ group: 'launcher-sources', test: (target) => target.startsWith(`${DRIVER_ROOT}/launcher/`) },
	{
		group: 'developer-tooling',
		test: (target) =>
			/(^|\/)(generate_models|validate_[^/]*)\.py$/.test(target) ||
			target.startsWith(`${SHARED_ROOT}/modules/llm/install/`) ||
			target.startsWith(`${SHARED_ROOT}/native/`) ||
			target.startsWith(`${SHARED_ROOT}/go/`)
	},
	{
		group: 'duplicate-copies',
		test: (target) => !ALLOWED_TOP_LEVEL.has(target.split('/')[0])
	},
	{
		// The former rsync excluded these by name; a checkout's own state must
		// never ship (paths.toml is a user file, prefetch caches hold metrics)
		group: 'developer-state',
		test: (target) =>
			/(^|\/)(paths\.toml|prefetch\.json)$/.test(target) ||
			/(^|\/)(\.venv|\.pytest_cache|__pycache__|\.build)\//.test(target)
	}
];

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};

// ===========================================
// ===========================================
// ======= 1/ Path sets ======================
// ===========================================
// ===========================================

/**
 * Indexes a file set with every directory prefix, so a literal naming a
 * folder resolves when the set holds a file below it.
 * @param {Iterable<string>} files Static-root-relative file paths.
 * @return {{files: Set<string>, directories: Set<string>}}
 */
function indexPaths(files) {
	const index = { files: new Set(), directories: new Set() };
	for (const file of files) {
		index.files.add(file);
		const parts = file.split('/');
		for (let length = 1; length < parts.length; length += 1) {
			index.directories.add(parts.slice(0, length).join('/'));
		}
	}
	return index;
}

/**
 * Tells whether a path is present in an index or owned by an external entry.
 * @param {{files: Set<string>, directories: Set<string>}} index Indexed set.
 * @param {string[]} externals External target paths.
 * @param {string} target Static-root-relative path.
 * @param {boolean} directory True when the literal names a folder.
 * @return {boolean}
 */
function present(index, externals, target, directory) {
	for (const external of externals) {
		if (target === external || target.startsWith(`${external}/`)) return true;
		if (directory && external.startsWith(`${target}/`)) return true;
	}
	return directory ? index.directories.has(target) : index.files.has(target);
}

/**
 * Joins a literal to a static-root-relative base; null when it leaves the root.
 * @param {string} base Folder relative to the static root ('' for the root).
 * @param {string} literal Path literal from a source file.
 * @return {string|null}
 */
function joinWithin(base, literal) {
	const trimmed = literal.replace(/^\/+/, '');
	const joined = path.posix.normalize(base ? `${base}/${trimmed}` : trimmed).replace(/\/+$/, '');
	if (joined === '.' || joined === '' || joined === '..' || joined.startsWith('../')) return null;
	return joined;
}

// ===========================================
// ===========================================
// ======= 2/ Runtime reference scanners =====
// ===========================================
// ===========================================

/**
 * Removes Lua comments while keeping string contents, one line at a time.
 * @param {string} line One source line.
 * @return {string}
 */
function stripLuaComment(line) {
	let quote = null;
	for (let index = 0; index < line.length; index += 1) {
		const character = line[index];
		if (quote) {
			if (character === '\\') index += 1;
			else if (character === quote) quote = null;
		} else if (character === '"' || character === "'") {
			quote = character;
		} else if (character === '-' && line[index + 1] === '-') {
			return line.slice(0, index);
		}
	}
	return line;
}

// A literal is a path candidate when it holds a slash and none of the
// characters of a pattern, a URL, a shell expansion or a user path
const NOT_A_PATH = /[%*^$\\<>(){}|?~:\s]|^\/tmp\//;

/**
 * Lists the ways one path literal can resolve for its reader.
 * @param {string} reader Static-root-relative path of the reading file.
 * @param {string} literal The literal.
 * @param {string} kind 'lua', 'shell', 'js' or 'html'.
 * @return {string[]}
 */
function interpretations(reader, literal, kind) {
	const readerDir = path.posix.dirname(reader);
	const bases = [readerDir];
	if (kind === 'lua' || kind === 'shell') bases.push(DRIVER_ROOT, SHARED_ROOT);
	const out = [];
	for (const base of bases) {
		const joined = joinWithin(base, literal);
		if (joined) out.push(joined);
	}
	if (literal.startsWith('/static/')) {
		const joined = joinWithin('', literal.slice('/static/'.length));
		if (joined) out.push(joined);
	}
	return out;
}

/**
 * Extracts every runtime reference of one staged source file.
 * @param {string} reader Static-root-relative path.
 * @param {string} text File contents.
 * @return {{reader: string, line: number, literal: string, candidates: string[], directory: boolean, require?: boolean}[]}
 */
function referencesOf(reader, text) {
	const references = [];
	const lines = text.split('\n');
	if (reader.endsWith('.lua')) {
		lines.forEach((raw, index) => {
			const line = stripLuaComment(raw);
			const requirePattern =
				/\brequire\s*\(?\s*["']([A-Za-z0-9_.]+)["']|pcall\s*\(\s*require\s*,\s*["']([A-Za-z0-9_.]+)["']/g;
			let match;
			while ((match = requirePattern.exec(line))) {
				const name = match[1] || match[2];
				const touchdevice = /^hs\._asm\.undocumented\.touchdevice(?:\.(\w+))?$/.exec(name);
				const candidates = touchdevice
					? [
							`${DRIVER_ROOT}/vendor/hs_asm/undocumented/touchdevice/${
								touchdevice[1] ? `${touchdevice[1]}.so` : 'init.lua'
							}`
						]
					: [SHARED_ROOT + '/lua', DRIVER_ROOT].flatMap((root) => {
							const stem = `${root}/${name.replace(/\./g, '/')}`;
							return [`${stem}.lua`, `${stem}/init.lua`];
						});
				references.push({
					reader,
					line: index + 1,
					literal: `require("${name}")`,
					candidates,
					directory: false,
					require: true
				});
			}
			const literalPattern = /"([^"\n]*)"|'([^'\n]*)'/g;
			while ((match = literalPattern.exec(line))) {
				const literal = match[1] ?? match[2];
				if (!literal.includes('/') || NOT_A_PATH.test(literal)) continue;
				references.push({
					reader,
					line: index + 1,
					literal,
					candidates: interpretations(reader, literal, 'lua'),
					directory: literal.endsWith('/')
				});
			}
		});
	} else if (reader.endsWith('.sh')) {
		lines.forEach((line, index) => {
			if (/^\s*#/.test(line)) return;
			const pattern = /\$\{?(?:SCRIPT_DIR|HS_ROOT)\}?\/([A-Za-z0-9_./-]+)/g;
			let match;
			while ((match = pattern.exec(line))) {
				const root = match[0].includes('HS_ROOT') ? DRIVER_ROOT : path.posix.dirname(reader);
				const joined = joinWithin(root, match[1]);
				if (!joined) continue;
				references.push({
					reader,
					line: index + 1,
					literal: match[0],
					candidates: [joined],
					directory: match[1].endsWith('/')
				});
			}
		});
	} else if (reader.endsWith('.html')) {
		lines.forEach((line, index) => {
			const pattern = /\b(?:src|href)\s*=\s*["']([^"'#?]+)/g;
			let match;
			while ((match = pattern.exec(line))) {
				const literal = match[1];
				if (/^(?:[a-z]+:|\/)/i.test(literal) || literal.includes('{')) continue;
				const joined = joinWithin(path.posix.dirname(reader), literal);
				if (!joined) continue;
				references.push({
					reader,
					line: index + 1,
					literal,
					candidates: [joined],
					directory: false
				});
			}
		});
	} else if (reader.endsWith('.js')) {
		lines.forEach((line, index) => {
			if (/^\s*(\/\/|\*)/.test(line)) return;
			const pattern = /["'`](\.\.?\/[^"'`\n]*)["'`]/g;
			let match;
			while ((match = pattern.exec(line))) {
				const literal = match[1];
				if (NOT_A_PATH.test(literal)) continue;
				references.push({
					reader,
					line: index + 1,
					literal,
					candidates: interpretations(reader, literal, 'js'),
					directory: literal.endsWith('/')
				});
			}
		});
	}
	return references;
}

// ===========================================
// ===========================================
// ======= 3/ Audit ==========================
// ===========================================
// ===========================================

/**
 * Judges one staged payload. Pure: the self-check reruns it on mutated sets.
 * @param {object} input
 * @param {Set<string>} input.staged Staged static-root-relative files.
 * @param {Set<string>} input.unfiltered Every file the trees would ship unfiltered.
 * @param {string[]} input.externals External target paths.
 * @param {function(string): string} input.read Reads a staged target or a repo: path.
 * @return {{problems: string[], checked: number}} Problems found, and how many
 *   runtime references resolved in the repository and were therefore judged.
 */
function audit({ staged, unfiltered, externals, read }) {
	const problems = [];
	let checked = 0;
	const stagedIndex = indexPaths(staged);
	const knownIndex = indexPaths([...unfiltered, ...staged]);

	// Every reference the complete trees can satisfy must survive the exclusions
	for (const reader of [...staged].sort()) {
		if (!/\.(lua|sh|html|js)$/.test(reader)) continue;
		for (const reference of referencesOf(reader, read(reader))) {
			const known = reference.candidates.filter((candidate) =>
				present(knownIndex, externals, candidate, reference.directory)
			);
			if (known.length === 0) continue;
			checked += 1;
			const satisfied = known.some((candidate) =>
				present(stagedIndex, externals, candidate, reference.directory)
			);
			if (!satisfied) {
				problems.push(
					`${reader}:${reference.line} reads ${reference.literal}, which resolves to ${known.join(
						' or '
					)} in the repository but is missing from the staged payload`
				);
			}
		}
	}

	// Curated reads: the source still makes them, and their targets are staged
	for (const entry of CURATED_READS) {
		const readerStaged = entry.reader.startsWith('repo:') || staged.has(entry.reader);
		if (!readerStaged) {
			problems.push(`curated reader ${entry.reader} is not staged (${entry.why})`);
			continue;
		}
		const text = read(entry.reader);
		for (const needle of entry.needles) {
			if (!text.includes(needle)) {
				problems.push(`${entry.reader} no longer contains ${needle}: re-inventory "${entry.why}"`);
			}
		}
		for (const target of entry.targets) {
			if (!present(stagedIndex, externals, target, false)) {
				problems.push(
					`${target} is missing from the staged payload (${entry.why}, ${entry.reader})`
				);
			}
		}
	}

	// Images have no literal-shaped reader: each one must be curated
	const curatedTargets = new Set(CURATED_READS.flatMap((entry) => entry.targets));
	for (const target of staged) {
		if (target.startsWith('img/') && !curatedTargets.has(target)) {
			problems.push(
				`${target} is staged but no runtime read of it is inventoried in CURATED_READS`
			);
		}
	}

	// License notices ship with the third-party code they cover
	for (const target of unfiltered) {
		if (/(^|\/)LICEN[CS]ES?(\.[^/]*)?$/i.test(target) && !staged.has(target)) {
			problems.push(
				`${target} is a license notice of bundled code but is missing from the staged payload`
			);
		}
	}

	// Groups the runtime never reads stay out, whatever the manifest says
	for (const target of staged) {
		for (const rule of FORBIDDEN) {
			if (rule.test(target)) problems.push(`${target} belongs to the excluded group ${rule.group}`);
		}
	}
	return { problems, checked };
}

// ===========================================
// ===========================================
// ======= 4/ Build script contract ==========
// ===========================================
// ===========================================

/**
 * Extracts one shell function body from a build script.
 * @param {string} source Build script text.
 * @param {string} name Function name.
 * @return {string} Body, or '' when absent.
 */
function shellFunction(source, name) {
	const match = new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?\\n\\}\\n`, 'm').exec(source);
	return match ? match[0] : '';
}

// The only functions allowed to copy repository static files themselves
const OWNED_COPIES = new Set(['bundle_keyboard_layout', 'bundle_layout_registry']);

// This one absent repository file is generated only by its exact qualified
// owner. An external entry inventories an output; it never supplies its bytes.
const MANAGED_CATALOGUE_TARGET = 'ergopti_plus/_shared/modules/llm/managed_ollama_release.json';
const MANAGED_CATALOGUE_OWNER = 'tools/build/stage-macos-managed-ollama-inputs.py';
const MANAGED_CATALOGUE_RECIPE = [
	'python3 "$REPO_ROOT/tools/build/stage-macos-managed-ollama-inputs.py" \\',
	'--repository "$REPO_ROOT" --inputs "$ERGOPTI_MANAGED_OLLAMA_INPUTS" \\',
	'--source "${ERGOPTI_OLLAMA_SOURCE:?native source inputs are required}" \\',
	'--official-archive "${ERGOPTI_OLLAMA_OFFICIAL_ARCHIVE:?official archive is required}" \\',
	'--go "${ERGOPTI_MANAGED_OLLAMA_GO:?absolute pinned Go is required}" \\',
	'--release "${ERGOPTI_RELEASE:-false}" --release-tag "${ERGOPTI_RELEASE_TAG:-}" \\',
	'--release-version "${ERGOPTI_RELEASE_VERSION:-}" --release-channel "$ERGOPTI_CHANNEL" \\',
	'--output "$static_root/ergopti_plus/_shared/modules/llm/managed_ollama_release.json"'
];

/** Bind the precise generated external to one actual source-qualified owner. */
function managedCatalogueProblems(source, externals) {
	const problems = [];
	const entries = externals.filter(
		(entry) => entry.target === MANAGED_CATALOGUE_TARGET || entry.owner === MANAGED_CATALOGUE_OWNER
	);
	if (
		entries.length !== 1 ||
		entries[0].target !== MANAGED_CATALOGUE_TARGET ||
		entries[0].owner !== MANAGED_CATALOGUE_OWNER
	) {
		problems.push('the generated managed catalogue requires exactly one exact target/owner pair');
	}
	const body = shellFunction(source, 'assemble_app');
	const lines = body.split(/\r?\n/).map((line) => line.trim());
	const starts = lines.flatMap((line, index) =>
		line === MANAGED_CATALOGUE_RECIPE[0] ? [index] : []
	);
	const sourceCalls = source
		.split(/\r?\n/)
		.filter((line) => line.trim() === MANAGED_CATALOGUE_RECIPE[0]);
	const start = starts[0];
	if (
		starts.length !== 1 ||
		sourceCalls.length !== 1 ||
		JSON.stringify(lines.slice(start, start + MANAGED_CATALOGUE_RECIPE.length)) !==
			JSON.stringify(MANAGED_CATALOGUE_RECIPE) ||
		lines[start - 1] !== 'if [ -n "${ERGOPTI_MANAGED_OLLAMA_INPUTS:-}" ]; then' ||
		lines[start + MANAGED_CATALOGUE_RECIPE.length] !== 'fi'
	) {
		problems.push(
			'assemble_app must conditionally invoke the exact source-qualified managed catalogue owner and output'
		);
	}
	return problems;
}

/**
 * Judges how a build script fills Contents/Resources. Pure: the self-check
 * reruns it on mutated scripts.
 * @param {string} source Build script text.
 * @param {{target: string, owner: string}[]} externals Manifest external entries.
 * @return {string[]} Problems found.
 */
function buildScriptProblems(source, externals) {
	const problems = [];
	problems.push(...managedCatalogueProblems(source, externals));
	const assembleApp = shellFunction(source, 'assemble_app');
	if (assembleApp === '') problems.push(`${BUILD_REL}: assemble_app() not found`);
	if (
		!/^\tnode "\$REPO_ROOT\/tools\/build\/macos-bundle-payload\.cjs" stage "\$REPO_ROOT" "\$static_root"$/m.test(
			assembleApp
		)
	) {
		problems.push(
			`${BUILD_REL}: assemble_app() must stage the payload with macos-bundle-payload.cjs into "$static_root"`
		);
	}
	if (/\brsync\b/.test(source)) problems.push(`${BUILD_REL}: rsync bypasses the payload manifest`);
	for (const match of source.matchAll(/^([a-z_]+)\(\) \{\n[\s\S]*?\n\}\n/gm)) {
		if (OWNED_COPIES.has(match[1])) continue;
		for (const line of match[0].split('\n')) {
			if (/^\s*#/.test(line) || !/\bcp\b[^\n]*\$REPO_ROOT\/static\//.test(line)) continue;
			problems.push(
				`${BUILD_REL}: ${match[1]}() copies repository static files outside the payload manifest: ${line.trim()}`
			);
		}
	}
	if (/Tools\/Karabiner|download_karabiner|Karabiner-Elements\.(?:app|pkg)/.test(source)) {
		problems.push(
			`${BUILD_REL}: the Karabiner-Elements installer is back in the bundle; onboarding downloads its own pinned DMG (platform/remap/onboarding.lua)`
		);
	}
	// The 79.6 MB Ollama binary is downloaded on the first Ollama selection
	if (
		/Tools\/Ollama|download_ollama|ollama-darwin\.tgz|OLLAMA_RELEASE_FILE|ERGOPTI_OLLAMA_BIN/.test(
			source
		)
	) {
		problems.push(
			`${BUILD_REL}: the Ollama binary is back in the bundle; the first Ollama selection downloads it (modules/llm/ensure-ollama-deps.sh)`
		);
	}
	// Maximum deflate is still the plain zip ditto, Sparkle and Homebrew read
	if (!/^\t\(cd "\$BUILD_DIR" && zip -qry -9 /m.test(shellFunction(source, 'zip_app'))) {
		problems.push(`${BUILD_REL}: zip_app() must compress the release archive with zip -9`);
	}
	for (const entry of externals) {
		if (!source.includes(entry.owner)) {
			problems.push(
				`${BUILD_REL}: external payload ${entry.target} names owner ${entry.owner}, which the build never runs`
			);
		}
	}
	return problems;
}

const manifest = payload.loadManifest(ROOT);
errors.push(...buildScriptProblems(BUILD, manifest.external));

// The build validated the Karabiner pin on every package run; with the
// installer gone, the macOS package job must still run that validation, or a
// bad pin first fails on a new user's onboarding
const packageJob =
	(fs
		.readFileSync(path.join(ROOT, '.github/workflows/ci-macos.yml'), 'utf8')
		.match(/^ {2}package-macos:\n[\s\S]*?(?=^ {2}[a-z][a-z-]*:\n|(?![\s\S]))/m) || [])[0] || '';
check(
	/^ {8}run: python3 -m unittest discover -s tools\/build -p 'karabiner_manifest_test\.py'$/m.test(
		packageJob
	),
	'ci-macos.yml: the package-macos job no longer validates the Karabiner-Elements pin (tools/build/karabiner_manifest_test.py)'
);

// Self-check: each way of bypassing the manifest must be reported
const stageLine =
	'\tnode "$REPO_ROOT/tools/build/macos-bundle-payload.cjs" stage "$REPO_ROOT" "$static_root"\n';
const bypasses = [
	['the staging call removed', BUILD.replace(stageLine, '')],
	[
		'a tree copied with rsync',
		BUILD.replace(
			stageLine,
			`${stageLine}\trsync -a "$REPO_ROOT/static/img/" "$static_root/img/"\n`
		)
	],
	[
		'a duplicate copy at the static root',
		BUILD.replace(
			stageLine,
			`${stageLine}\tcp -R "$REPO_ROOT/static/ergopti_plus/_shared/data/locales" "$static_root/"\n`
		)
	],
	[
		'the Karabiner installer vendored again',
		BUILD.replace(
			stageLine,
			`${stageLine}\tmkdir -p "$APP_PATH/Contents/Resources/Tools/Karabiner"\n`
		)
	],
	[
		'the Ollama binary bundled again',
		BUILD.replace(
			stageLine,
			`${stageLine}\tcp "$ollama_bin_path" "$APP_PATH/Contents/Resources/Tools/Ollama/ollama"\n`
		)
	],
	['the archive back at default compression', BUILD.replace('zip -qry -9 ', 'zip -qry ')]
];
for (const [label, mutated] of bypasses) {
	check(mutated !== BUILD, `self-check: the staging call drifted; re-derive "${label}"`);
	check(
		buildScriptProblems(mutated, manifest.external).length > 0,
		`self-check: a build script with ${label} went unreported`
	);
}

// Independently retain the literal generated-output boundary, including a
// comment that still contains the owner text but cannot generate any bytes.
const managedRecipe =
	'\t\t' +
	MANAGED_CATALOGUE_RECIPE[0] +
	'\n\t\t\t' +
	MANAGED_CATALOGUE_RECIPE.slice(1).join('\n\t\t\t');
check(BUILD.includes(managedRecipe), 'self-check: the exact managed catalogue recipe drifted');
const managedOwnerMutants = [
	['missing owner call', BUILD.replace(MANAGED_CATALOGUE_RECIPE[0], '')],
	[
		'comment-only owner',
		BUILD.replace(MANAGED_CATALOGUE_RECIPE[0], '# ' + MANAGED_CATALOGUE_RECIPE[0])
	],
	[
		'foreign output',
		BUILD.replace(
			'--output "$static_root/ergopti_plus/_shared/modules/llm/managed_ollama_release.json"',
			'--output "$static_root/foreign_catalogue.json"'
		)
	],
	[
		'foreign inputs',
		BUILD.replace('--inputs "$ERGOPTI_MANAGED_OLLAMA_INPUTS"', '--inputs "$FOREIGN_INPUTS"')
	],
	['duplicate owner call', BUILD.replace(managedRecipe, managedRecipe + '\n' + managedRecipe)],
	['owner outside assemble_app', BUILD.replace(managedRecipe, '') + '\n' + managedRecipe + '\n'],
	[
		'inverted optional input guard',
		BUILD.replace(
			'if [ -n "${ERGOPTI_MANAGED_OLLAMA_INPUTS:-}" ]; then',
			'if [ -z "${ERGOPTI_MANAGED_OLLAMA_INPUTS:-}" ]; then'
		)
	]
];
for (const [label, mutated] of managedOwnerMutants) {
	check(mutated !== BUILD, `self-check: the catalogue mutation did not hit ${label}`);
	check(
		buildScriptProblems(mutated, manifest.external).length > 0,
		`self-check: ${label} was admitted`
	);
}
const managedExternal = manifest.external.find(
	(entry) => entry.target === MANAGED_CATALOGUE_TARGET
);
for (const [label, externals] of [
	['missing catalogue owner', manifest.external.filter((entry) => entry !== managedExternal)],
	['duplicate catalogue owner', [...manifest.external, managedExternal]],
	[
		'foreign catalogue owner',
		manifest.external.map((entry) =>
			entry === managedExternal ? { ...entry, owner: 'write_build_stamp.sh' } : entry
		)
	],
	[
		'foreign catalogue target',
		manifest.external.map((entry) =>
			entry === managedExternal
				? { ...entry, target: 'ergopti_plus/_shared/modules/llm/foreign_catalogue.json' }
				: entry
		)
	]
]) {
	check(buildScriptProblems(BUILD, externals).length > 0, `self-check: ${label} was admitted`);
}

// ===========================================
// ===========================================
// ======= 5/ Real staging and audit =========
// ===========================================
// ===========================================

/**
 * Lists every regular file below a folder, relative to it.
 * @param {string} directory Absolute folder.
 * @return {string[]}
 */
function walk(directory) {
	const out = [];
	const visit = (absolute, relative) => {
		for (const entry of fs.readdirSync(absolute, { withFileTypes: true })) {
			const childAbsolute = path.join(absolute, entry.name);
			const childRelative = relative ? `${relative}/${entry.name}` : entry.name;
			if (entry.isDirectory()) visit(childAbsolute, childRelative);
			else out.push(childRelative);
		}
	};
	visit(directory, '');
	return out;
}

const resolved = payload.resolvePayload(manifest, payload.trackedFiles(ROOT, manifest));
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-macos-payload-'));
let staged;
let checkedReferences = 0;
// A junction needs no privilege on Windows and reads as a link like a symlink
const linkType = process.platform === 'win32' ? 'junction' : 'dir';
try {
	// Stage through a symbolic-link ancestor, as every macOS temporary folder
	// and a checkout under /tmp are (/var and /tmp point into /private): the
	// stager must accept links above the root it is given
	const realParent = path.join(scratch, 'real');
	const linkedParent = path.join(scratch, 'linked');
	fs.mkdirSync(realParent);
	fs.symlinkSync(realParent, linkedParent, linkType);
	const staticRoot = path.join(linkedParent, 'static');
	const copied = payload.stage(ROOT, staticRoot);
	staged = new Set(walk(staticRoot));
	check(
		copied === resolved.files.length,
		`stage() copied ${copied} files, the resolver lists ${resolved.files.length}`
	);
	const expected = new Set(resolved.files.map((file) => file.target));
	for (const target of expected) check(staged.has(target), `stage() did not write ${target}`);
	for (const target of staged) check(expected.has(target), `stage() wrote unexpected ${target}`);
	if (process.platform !== 'win32') {
		for (const file of resolved.files) {
			const sourceMode = fs.statSync(path.join(ROOT, file.source)).mode & 0o111;
			const stagedMode = fs.statSync(path.join(staticRoot, file.target)).mode & 0o111;
			check(sourceMode === stagedMode, `stage() changed the executable bits of ${file.target}`);
		}
	}
	// ...but never a link below that root, which would write the payload
	// outside the bundle
	const hijacked = path.join(scratch, 'hijacked');
	const outside = path.join(scratch, 'outside');
	fs.mkdirSync(hijacked);
	fs.mkdirSync(outside);
	fs.symlinkSync(outside, path.join(hijacked, 'ergopti_plus'), linkType);
	let refusal = '';
	try {
		payload.stage(ROOT, hijacked);
	} catch (error) {
		refusal = error.message;
	}
	check(
		refusal.startsWith('Unsafe payload directory'),
		`stage() did not refuse a link below its root: ${refusal || 'no error'}`
	);
	check(fs.readdirSync(outside).length === 0, 'stage() wrote through a link below its root');

	// The build's stage command copies tracked files only, so it must refuse an
	// untracked runtime file (a module never added would be missing at boot)
	// while leaving ignored state and untracked files of excluded groups alone
	const checkout = path.join(scratch, 'checkout');
	const writeFile = (relative, text) => {
		fs.mkdirSync(path.dirname(path.join(checkout, relative)), { recursive: true });
		fs.writeFileSync(path.join(checkout, relative), text);
	};
	writeFile(
		payload.MANIFEST_REL,
		JSON.stringify({
			trees: [{ source: 'driver', target: 'app', reason: 'fixture' }],
			external: [{ target: 'stamp.txt', owner: 'fixture', reason: 'fixture' }],
			exclude: [{ group: 'tests', reason: 'fixture', patterns: ['app/tests/**'] }]
		})
	);
	writeFile('.gitignore', '*.log\n');
	writeFile('driver/init.lua', 'require("modules.fresh")\n');
	writeFile('driver/tests/run.lua', '');
	writeFile('driver/modules/fresh.lua', 'return {}\n');
	writeFile('driver/tests/fresh_test.lua', '');
	writeFile('driver/cache.log', '');
	// A hook's GIT_DIR or GIT_INDEX_FILE would point the fixture at the real index
	const env = Object.fromEntries(
		Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_'))
	);
	const git = (...args) => execFileSync('git', ['-C', checkout, ...args], { stdio: 'pipe', env });
	git('init', '-q');
	git('add', '--', 'driver/init.lua', 'driver/tests/run.lua');
	const stageCommand = (destination) =>
		spawnSync(
			process.execPath,
			[path.join(ROOT, 'tools/build/macos-bundle-payload.cjs'), 'stage', checkout, destination],
			{ encoding: 'utf8', env }
		);
	const untrackedRun = stageCommand(path.join(scratch, 'untracked-static'));
	check(
		untrackedRun.status !== 0 && untrackedRun.stderr.includes('driver/modules/fresh.lua'),
		`the stage command shipped a bundle without an untracked runtime file (exit ${untrackedRun.status})`
	);
	check(
		!untrackedRun.stderr.includes('fresh_test.lua') && !untrackedRun.stderr.includes('cache.log'),
		'the stage command refused an untracked test or an ignored file it never ships'
	);
	git('add', '--', 'driver/modules/fresh.lua');
	const trackedStatic = path.join(scratch, 'tracked-static');
	const trackedRun = stageCommand(trackedStatic);
	check(
		trackedRun.status === 0 && fs.existsSync(path.join(trackedStatic, 'app/modules/fresh.lua')),
		`the stage command failed once every runtime file was tracked: ${trackedRun.stderr}`
	);
	check(
		!fs.existsSync(path.join(trackedStatic, 'app/cache.log')),
		'the stage command shipped an ignored file'
	);

	const read = (target) =>
		target.startsWith('repo:')
			? fs.readFileSync(path.join(ROOT, target.slice('repo:'.length)), 'utf8')
			: fs.readFileSync(path.join(staticRoot, target), 'utf8');
	const externals = manifest.external.map((entry) => entry.target);
	const verdict = audit({ staged, unfiltered: resolved.unfiltered, externals, read });
	errors.push(...verdict.problems);
	checkedReferences = verdict.checked;
	check(
		checkedReferences > 1000,
		`only ${checkedReferences} runtime references were judged: a scanner went blind`
	);

	// ===========================================
	// ===========================================
	// ======= 6/ Self-check =====================
	// ===========================================
	// ===========================================

	// One removal per reference kind: the audit must name the missing file
	const removals = [
		['ergopti_plus/_shared/lua/json.lua', 'a required shared Lua module'],
		['ergopti_plus/macos/modules/llm/network-retry.sh', 'a file a bootstrap script sources'],
		['ergopti_plus/_shared/ui/host_bridge.js', 'a script a WebView page loads'],
		['ergopti_plus/_shared/modules/hotstrings/defaults.toml', 'a shared data file'],
		['img/logo/logo_white.png', 'a curated image read'],
		['ergopti_plus/macos/uv.lock', 'the committed MLX lock file'],
		['ergopti_plus/_shared/ui/vendor/LICENSES.md', 'the vendored code license notice']
	];
	for (const [removed, kind] of removals) {
		check(staged.has(removed), `self-check: ${removed} (${kind}) is not staged to begin with`);
		const mutated = new Set([...staged].filter((target) => target !== removed));
		const found = audit({
			staged: mutated,
			unfiltered: resolved.unfiltered,
			externals,
			read
		}).problems;
		check(
			found.some((problem) => problem.includes(removed)),
			`self-check: removing ${kind} (${removed}) went unreported`
		);
	}

	// One injection per forbidden group: the audit must refuse it
	const injections = [
		`${DRIVER_ROOT}/tests/run.lua`,
		`${SHARED_ROOT}/tests/corpus/x.json`,
		`${SHARED_ROOT}/lua/test/format.lua`,
		`${DRIVER_ROOT}/README.md`,
		`${DRIVER_ROOT}/vendor/hs_asm/undocumented/touchdevice/watcher.so.dSYM/Contents/Info.plist`,
		`${DRIVER_ROOT}/launcher/Package.swift`,
		`${SHARED_ROOT}/modules/llm/validate_api_providers.py`,
		'locales/fr.json',
		'img/og_image.jpg',
		`${DRIVER_ROOT}/paths.toml`
	];
	for (const injected of injections) {
		const mutated = new Set([...staged, injected]);
		const found = audit({
			staged: mutated,
			unfiltered: resolved.unfiltered,
			externals,
			read: (target) => (target === injected ? '' : read(target))
		}).problems;
		check(
			found.some((problem) => problem.startsWith(injected)),
			`self-check: staging ${injected} went unreported`
		);
	}

	// Dropping a manifest exclusion must bring its files into the audit's view
	const withoutTests = payload.parseManifest(
		JSON.stringify({
			...JSON.parse(fs.readFileSync(path.join(ROOT, payload.MANIFEST_REL), 'utf8')),
			exclude: manifest.exclude
				.filter((group) => group.group !== 'tests')
				.map(({ group, reason, patterns }) => ({ group, reason, patterns }))
		})
	);
	const leaked = payload.resolvePayload(withoutTests, payload.trackedFiles(ROOT, withoutTests));
	const leakedSet = new Set(leaked.files.map((file) => file.target));
	const leakedFound = audit({
		staged: leakedSet,
		unfiltered: leaked.unfiltered,
		externals,
		read: (target) =>
			target.startsWith('repo:')
				? read(target)
				: fs.readFileSync(
						path.join(ROOT, leaked.files.find((file) => file.target === target).source),
						'utf8'
					)
	}).problems;
	check(
		leakedFound.some((problem) => problem.includes('excluded group tests')),
		'self-check: a manifest without its tests exclusion went unreported'
	);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] macOS bundle payload guard:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] macOS bundle payload: ${staged.size} staged files, ${checkedReferences} runtime references resolve, no excluded group is shipped, and the self-check caught every seeded regression.\x1b[0m`
);
