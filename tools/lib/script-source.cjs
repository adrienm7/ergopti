// tools/lib/script-source.cjs

/** Small lexical boundary for static Lua/AHK guards; this is not a flow analyzer. */
'use strict';

/** Returns tokens with literal boundaries intact, including comments for masking. */
function scan(source, extension) {
	const ahk = extension === '.ahk';
	const tokens = [];
	let at = 0;
	while (at < source.length) {
		if (/\s/.test(source[at])) { at += 1; continue; }
		const start = at;
		const tail = source.slice(at);
		if ((ahk && source[at] === ';' && (at === 0 || /\s/.test(source[at - 1])))
			|| (!ahk && tail.startsWith('--'))) {
			const long = !ahk && tail.match(/^--\[(=*)\[/);
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
		if (ahk && tail.startsWith('/*')) {
			const end = source.indexOf('*/', at + 2);
			at = end < 0 ? source.length : end + 2;
			tokens.push({ kind: 'comment', start, end: at });
			continue;
		}
		const long = !ahk && tail.match(/^\[(=*)\[/);
		if (long) {
			const end = source.indexOf(']' + long[1] + ']', at + long[0].length);
			at = end < 0 ? source.length : end + long[1].length + 2;
			tokens.push({ kind: 'string', value: source.slice(start + long[0].length, end), start, end: at });
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
		const identifier = tail.match(/^[A-Za-z_][A-Za-z_0-9]*/);
		const value = identifier ? identifier[0] : tail.startsWith(':=') ? ':=' : source[at];
		at += value.length;
		tokens.push({ kind: identifier ? 'identifier' : 'symbol', value, start, end: at });
	}
	return tokens;
}

/** Removes comments without interpreting markers inside strings or other comments. */
function stripComments(source, extension) {
	let result = '', previous = 0;
	for (const token of scan(source, extension)) {
		if (token.kind !== 'comment') continue;
		result += source.slice(previous, token.start) + source.slice(token.start, token.end).replace(/[^\n]/g, ' ');
		previous = token.end;
	}
	return result + source.slice(previous);
}

/** Returns code/literal tokens, excluding comments and whitespace. */
function scriptTokens(source, extension) {
	return scan(source, extension).filter((token) => token.kind !== 'comment');
}

module.exports = { stripComments, scriptTokens };
