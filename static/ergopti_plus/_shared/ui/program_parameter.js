// _shared/ui/program_parameter.js

/** Literal program parameters are data; they never undergo shell expansion. */
var ProgramParameter = (() => {
	function cleanString(value) {
		if (typeof value !== 'string' || value.includes('\0')) return false;
		for (let index = 0; index < value.length; index += 1) {
			const code = value.charCodeAt(index);
			if (code >= 0xd800 && code <= 0xdbff) {
				const next = value.charCodeAt(++index);
				if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
			} else if (code >= 0xdc00 && code <= 0xdfff) return false;
		}
		return true;
	}

	// JSON.parse discards duplicate object keys. Inspect the actual top-level
	// string tokens first; escaped keys have the same identity as plain keys.
	function uniqueFields(raw) {
		const fields = new Set();
		let depth = 0;
		for (let index = 0; index < raw.length; index += 1) {
			const character = raw[index];
			if (character === '"') {
				const start = index;
				for (index += 1; index < raw.length; index += 1) {
					if (raw[index] === '\\') index += 1;
					else if (raw[index] === '"') break;
				}
				if (index >= raw.length) return false;
				let next = index + 1;
				while (/\s/.test(raw[next] || '') && next < raw.length) next += 1;
				if (depth === 1 && raw[next] === ':') {
					const key = JSON.parse(raw.slice(start, index + 1));
					if (fields.has(key)) return false;
					fields.add(key);
				}
			} else if (character === '{' || character === '[') depth += 1;
			else if (character === '}' || character === ']') depth -= 1;
		}
		return true;
	}

	function parse(raw, platform) {
		if (typeof raw !== 'string') return null;
		try {
			if (!uniqueFields(raw)) return null;
			const data = JSON.parse(raw);
			if (!data || Array.isArray(data) || typeof data !== 'object') return null;
			if (
				Object.keys(data).length !== 3 ||
				!Object.hasOwn(data, 'version') ||
				!Object.hasOwn(data, 'executable') ||
				!Object.hasOwn(data, 'arguments')
			)
				return null;
			if (typeof data.version !== 'number' || data.version !== 1) return null;
			if (!cleanString(data.executable) || data.executable === '') return null;
			if (platform === 'ahk') {
				if (
					!/^[A-Za-z]:[/\\]/.test(data.executable) &&
					!/^\\\\[^\\/]+\\[^\\/]+\\./.test(data.executable)
				)
					return null;
				if (/^\\\\[?.]\\/.test(data.executable)) return null;
			} else if (platform === 'hs' || platform === 'linux') {
				if (!data.executable.startsWith('/')) return null;
			} else return null;
			if (!Array.isArray(data.arguments) || !data.arguments.every(cleanString)) return null;
			return { executable: data.executable, arguments: data.arguments.slice() };
		} catch {
			return null;
		}
	}

	function encode(executable, argumentsValue, platform) {
		try {
			const raw = JSON.stringify({ version: 1, executable, arguments: argumentsValue });
			return parse(raw, platform) === null ? null : raw;
		} catch {
			return null;
		}
	}
	return { parse, encode };
})();
