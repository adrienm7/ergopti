// tools/test/test-text-crypto-envelope-parity.cjs

/**
 * ==============================================================================
 * MODULE: At-Rest Encryption Envelope Parity Gate
 * DESCRIPTION:
 * The three drivers encrypt the keylogger's typed-text columns. A row written on
 * one machine is only decryptable on that machine (the key derives from the
 * machine id), but the ENVELOPE FORMAT and the crypto parameters must be
 * identical across drivers — otherwise the shared codec and the "same bytes
 * everywhere" property silently rot, and a future cross-device import would read
 * back garbage instead of failing cleanly.
 *
 * ROOT CAUSE ENCODED:
 * The Lua codec (_shared/lua/keylogger/text_crypto.lua) is the single source of
 * truth. The Windows driver re-implements the same constants in AutoHotkey
 * (keylogger_text_cipher.ahk) because it uses CNG instead of openssl. Two copies
 * of a wire format is two places for it to drift; this gate pins the AHK copy to
 * the Lua original: marker, separator, cipher, PBKDF2 iterations, salt, and the
 * key/IV sizes must all match.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

const errors = [];

function read(rel) {
	const full = path.join(SP, rel);
	if (!fs.existsSync(full)) {
		errors.push(`${rel}: expected file is missing — update this gate or restore the file.`);
		return null;
	}
	return fs.readFileSync(full, 'utf8');
}

// ── The canonical values, parsed from the shared Lua codec ───────────────────

const lua = read('_shared/lua/keylogger/text_crypto.lua');

/** Pulls `M.NAME = "value"` or `M.NAME = number` out of the Lua source. */
function luaConst(src, name) {
	const m = src && src.match(new RegExp(`M\\.${name}\\s*=\\s*("([^"]*)"|[\\d]+)`));
	if (!m) return undefined;
	return m[2] !== undefined ? m[2] : m[1];
}

const canonical = lua
	? {
			marker: luaConst(lua, 'MARKER'),
			separator: luaConst(lua, 'SEPARATOR'),
			cipher: luaConst(lua, 'CIPHER'),
			iterations: luaConst(lua, 'KDF_ITERATIONS'),
			saltHex: luaConst(lua, 'KDF_SALT_HEX'),
			keyHex: luaConst(lua, 'KEY_HEX_LENGTH'),
			ivHex: luaConst(lua, 'IV_HEX_LENGTH')
	  }
	: {};

if (lua) {
	for (const [k, v] of Object.entries(canonical)) {
		if (v === undefined) errors.push(`text_crypto.lua: could not parse constant for "${k}".`);
	}
	// The credential gate is meaningless if the iteration count is weak. Pin the
	// floor so a well-meaning "make it faster" cannot quietly gut the KDF.
	if (canonical.iterations && Number(canonical.iterations) < 600000) {
		errors.push(`text_crypto.lua: KDF_ITERATIONS is ${canonical.iterations}; must be at least 600000.`);
	}
}

// ── The AutoHotkey copy must mirror every one of them ────────────────────────

const ahk = read('windows/modules/keylogger/keylogger_text_cipher.ahk');
if (ahk && lua) {
	/** Pulls `global KL_ENC_NAME := "value"` / `:= number` out of the AHK source. */
	function ahkConst(name) {
		const m = ahk.match(new RegExp(`KL_ENC_${name}\\s*:=\\s*("([^"]*)"|[\\d]+)`));
		if (!m) return undefined;
		return m[2] !== undefined ? m[2] : m[1];
	}

	const checks = [
		['MARKER', canonical.marker],
		['SEPARATOR', canonical.separator],
		['KDF_ITERATIONS', canonical.iterations],
		['KDF_SALT_HEX', canonical.saltHex]
	];
	for (const [name, expected] of checks) {
		const got = ahkConst(name);
		if (got === undefined) {
			errors.push(`keylogger_text_cipher.ahk: KL_ENC_${name} not found.`);
		} else if (String(got) !== String(expected)) {
			errors.push(
				`keylogger_text_cipher.ahk: KL_ENC_${name} = "${got}" but the shared codec says "${expected}". ` +
					'The stored envelope would no longer be portable in form across drivers.'
			);
		}
	}

	// Key/IV are expressed in bytes on the AHK side, hex chars on the Lua side.
	const keyBytes = ahkConst('KEY_BYTES');
	const ivBytes = ahkConst('IV_BYTES');
	if (keyBytes !== undefined && Number(keyBytes) * 2 !== Number(canonical.keyHex)) {
		errors.push(
			`keylogger_text_cipher.ahk: KL_ENC_KEY_BYTES=${keyBytes} (=${keyBytes * 2} hex) ` +
				`disagrees with text_crypto KEY_HEX_LENGTH=${canonical.keyHex}.`
		);
	}
	if (ivBytes !== undefined && Number(ivBytes) * 2 !== Number(canonical.ivHex)) {
		errors.push(
			`keylogger_text_cipher.ahk: KL_ENC_IV_BYTES=${ivBytes} (=${ivBytes * 2} hex) ` +
				`disagrees with text_crypto IV_HEX_LENGTH=${canonical.ivHex}.`
		);
	}

	// The AHK driver uses CNG, not openssl, but must speak the same cipher.
	if (canonical.cipher && !ahk.toLowerCase().includes(canonical.cipher.toLowerCase())) {
		errors.push(
			`keylogger_text_cipher.ahk: does not mention the shared cipher "${canonical.cipher}" — ` +
				'AES-256-CBC with PKCS7 is what openssl writes and CNG must match it.'
		);
	}
}

// ── Both Lua ciphers must consume the shared codec, not re-type the format ────

for (const rel of [
	'linux/modules/keylogger/text_cipher.lua',
	'macos/modules/keylogger/text_cipher.lua'
]) {
	const src = read(rel);
	if (src && !src.includes('keylogger.text_crypto')) {
		errors.push(`${rel}: must build on the shared codec require("keylogger.text_crypto"), not re-type the format.`);
	}
}

// ── Report ───────────────────────────────────────────────────────────────────

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] At-rest encryption envelope is not single-sourced across drivers:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] At-rest envelope parity: marker "${canonical.marker}", ${canonical.cipher}, ` +
		`${canonical.iterations} PBKDF2 iterations — identical across the three drivers.\x1b[0m`
);
