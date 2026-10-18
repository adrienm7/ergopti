// tools/lib/script-source.cjs

/** Small lexical boundary for static Lua/AHK guards; this is not a flow analyzer. */
'use strict';

// Sticky patterns match at an offset without slicing the remaining source.
const LONG_COMMENT = /--\[(=*)\[/y;
const LONG_STRING = /\[(=*)\[/y;
const IDENTIFIER = /[A-Za-z_][A-Za-z_0-9]*/y;

/** Matches a sticky pattern exactly at one offset. */
function matchAt(pattern, source, at) {
	pattern.lastIndex = at;
	return pattern.exec(source);
}

/** Returns tokens with literal boundaries intact, including comments for masking. */
function scan(source, extension) {
	const ahk = extension === '.ahk';
	const tokens = [];
	let at = 0;
	while (at < source.length) {
		if (/\s/.test(source[at])) {
			at += 1;
			continue;
		}
		const start = at;
		if (
			(ahk && source[at] === ';' && (at === 0 || /\s/.test(source[at - 1]))) ||
			(!ahk && source.startsWith('--', at))
		) {
			const long = !ahk && matchAt(LONG_COMMENT, source, at);
			if (long) {
				const end = source.indexOf(']' + long[1] + ']', at + long[0].length);
				at = end < 0 ? source.length : end + long[1].length + 2;
			} else {
				const end = source.indexOf('\n', at);
				at = end < 0 ? source.length : end;
			}
			tokens.push({ kind: 'comment', start, end: at });
			continue;
		}
		if (ahk && source.startsWith('/*', at)) {
			const end = source.indexOf('*/', at + 2);
			at = end < 0 ? source.length : end + 2;
			tokens.push({ kind: 'comment', start, end: at });
			continue;
		}
		const long = !ahk && matchAt(LONG_STRING, source, at);
		if (long) {
			const end = source.indexOf(']' + long[1] + ']', at + long[0].length);
			at = end < 0 ? source.length : end + long[1].length + 2;
			tokens.push({
				kind: 'string',
				value: source.slice(start + long[0].length, end),
				start,
				end: at
			});
			continue;
		}
		if (source[at] === '"' || source[at] === "'") {
			const quote = source[at++];
			let value = '';
			while (at < source.length && source[at] !== quote) {
				if (source[at] === (ahk ? '`' : '\\') && at + 1 < source.length) at += 1;
				value += source[at++];
			}
			if (at < source.length) at += 1;
			tokens.push({ kind: 'string', value, start, end: at });
			continue;
		}
		const identifier = matchAt(IDENTIFIER, source, at);
		const value = identifier ? identifier[0] : source.startsWith(':=', at) ? ':=' : source[at];
		at += value.length;
		tokens.push({ kind: identifier ? 'identifier' : 'symbol', value, start, end: at });
	}
	return tokens;
}

// The menu guards tokenize the same driver files thousands of times in one
// process. A bounded cache keeps each scan private: callers edit the tokens
// they receive (menu-native-startup-binding.cjs adds lineBefore), so every
// call returns fresh token objects and an edit never reaches another caller.
const SCAN_CACHE_SOURCE_BYTES = 8 * 1024 * 1024;
const scanCache = new Map();
let scanCacheBytes = 0;

/** Returns the shared scan of one source, computing it at most once while cached. */
function cachedScan(source, extension) {
	const mode = extension === '.ahk' ? 'ahk' : 'lua';
	const entries = scanCache.get(source);
	if (entries) {
		// Refresh the entry so the least recently used source is evicted first.
		scanCache.delete(source);
		scanCache.set(source, entries);
		if (entries[mode]) return entries[mode];
	}
	const all = scan(source, extension);
	const scanned = { all, code: all.filter((token) => token.kind !== 'comment') };
	if (entries) entries[mode] = scanned;
	else {
		scanCache.set(source, { [mode]: scanned });
		scanCacheBytes += source.length;
		for (const [oldest] of scanCache) {
			if (scanCacheBytes <= SCAN_CACHE_SOURCE_BYTES || oldest === source) break;
			scanCache.delete(oldest);
			scanCacheBytes -= oldest.length;
		}
	}
	return scanned;
}

/** Removes comments without interpreting markers inside strings or other comments. */
function stripComments(source, extension) {
	let result = '',
		previous = 0;
	for (const token of cachedScan(source, extension).all) {
		if (token.kind !== 'comment') continue;
		result +=
			source.slice(previous, token.start) +
			source.slice(token.start, token.end).replace(/[^\n]/g, ' ');
		previous = token.end;
	}
	return result + source.slice(previous);
}

/** Returns code/literal tokens, excluding comments and whitespace. */
function scriptTokens(source, extension) {
	// Every code token has exactly these fields, in this order.
	return cachedScan(source, extension).code.map(({ kind, value, start, end }) => ({
		kind,
		value,
		start,
		end
	}));
}

module.exports = { stripComments, scriptTokens };
