// tools/test/support/issue-form-yaml.cjs

/**
 * ==============================================================================
 * MODULE: Issue Form YAML Reader (test support)
 * DESCRIPTION:
 * Parses the YAML subset the GitHub issue forms of .github/ISSUE_TEMPLATE/ are
 * written in, so tests can read their field ids without a YAML dependency:
 * block mappings and sequences by indentation, `|` literal blocks, flow
 * sequences of scalars, quoted and plain scalars, booleans and comments.
 * Anything outside that subset throws with its line number instead of being
 * guessed, so a form that grows a construct this reader does not know fails
 * the test rather than silently losing fields.
 * ==============================================================================
 */

'use strict';

/**
 * Splits the text into significant lines with their indentation.
 * @param {string} text
 * @returns {{indent: number, text: string, line: number}[]}
 */
function tokenize(text) {
	const out = [];
	text
		.replace(/\r\n?/g, '\n')
		.split('\n')
		.forEach((raw, index) => {
			if (/^\s*(#.*)?$/.test(raw)) {
				out.push({ indent: -1, text: '', line: index + 1, raw });
				return;
			}
			if (/^\t/.test(raw)) throw new Error(`line ${index + 1}: tab indentation is not YAML`);
			const indent = raw.match(/^ */)[0].length;
			out.push({ indent, text: raw.slice(indent), line: index + 1, raw });
		});
	return out;
}

/**
 * Parses one scalar or flow sequence.
 * @param {string} value
 * @param {number} line
 * @returns {*}
 */
function scalar(value, line) {
	const text = value.replace(/\s+#.*$/, '').trim();
	if (/^".*"$/.test(text)) return JSON.parse(text);
	if (/^'.*'$/.test(text)) return text.slice(1, -1).replace(/''/g, "'");
	if (/^\[.*\]$/.test(text)) {
		const inner = text.slice(1, -1).trim();
		return inner === '' ? [] : inner.split(',').map((part) => scalar(part, line));
	}
	if (text === 'true') return true;
	if (text === 'false') return false;
	if (/^[&*!{|>]/.test(text)) throw new Error(`line ${line}: unsupported YAML construct "${text}"`);
	return text;
}

/**
 * Parses the block starting at `start` whose lines are indented `indent`.
 * @returns {{value: *, next: number}}
 */
function parseBlock(lines, start, indent) {
	let i = start;
	while (i < lines.length && lines[i].indent === -1) i++;
	if (i >= lines.length) return { value: null, next: i };
	const isSequence = lines[i].text.startsWith('- ') || lines[i].text === '-';
	const container = isSequence ? [] : {};
	while (i < lines.length) {
		const current = lines[i];
		if (current.indent === -1) {
			i++;
			continue;
		}
		if (current.indent < indent) break;
		if (current.indent > indent) throw new Error(`line ${current.line}: unexpected indentation`);
		if (isSequence) {
			if (!current.text.startsWith('-')) throw new Error(`line ${current.line}: expected "- "`);
			const rest = current.text.slice(1).trimStart();
			if (rest === '') {
				const child = parseBlock(lines, i + 1, indent + 2);
				container.push(child.value);
				i = child.next;
			} else if (/^[^"'[\s][^:]*:(\s|$)/.test(rest)) {
				// "- key: value" opens a mapping whose other keys sit under the key
				const itemIndent = indent + (current.text.length - rest.length);
				const synthetic = lines.slice();
				synthetic[i] = { indent: itemIndent, text: rest, line: current.line };
				const child = parseBlock(synthetic, i, itemIndent);
				container.push(child.value);
				i = child.next;
			} else {
				container.push(scalar(rest, current.line));
				i++;
			}
			continue;
		}
		const match = current.text.match(/^([A-Za-z0-9_-]+):(?:\s+(.*))?$/);
		if (!match)
			throw new Error(`line ${current.line}: expected "key: value", got "${current.text}"`);
		const key = match[1];
		const rest = match[2] === undefined ? '' : match[2];
		if (rest === '|' || rest === '|-') {
			const body = [];
			let j = i + 1;
			let blockIndent = null;
			while (j < lines.length) {
				const candidate = lines[j];
				if (candidate.indent === -1) {
					body.push('');
					j++;
					continue;
				}
				if (candidate.indent <= indent) break;
				if (blockIndent === null) blockIndent = candidate.indent;
				body.push(candidate.raw.slice(blockIndent));
				j++;
			}
			while (body.length && body[body.length - 1] === '') body.pop();
			container[key] = body.join('\n') + (rest === '|' ? '\n' : '');
			i = j;
		} else if (rest === '') {
			const child = parseBlock(lines, i + 1, nextIndent(lines, i + 1));
			container[key] = child.value;
			i = child.next;
		} else {
			container[key] = scalar(rest, current.line);
			i++;
		}
	}
	return { value: container, next: i };
}

/**
 * The indentation of the next significant line.
 */
function nextIndent(lines, from) {
	for (let i = from; i < lines.length; i++) if (lines[i].indent !== -1) return lines[i].indent;
	return 0;
}

/**
 * Parses an issue form or config.yml.
 * @param {string} text
 * @returns {object}
 */
function parseIssueFormYaml(text) {
	const lines = tokenize(text);
	const result = parseBlock(lines, 0, 0);
	for (let i = result.next; i < lines.length; i++) {
		if (lines[i].indent !== -1)
			throw new Error(`line ${lines[i].line}: content after the document`);
	}
	return result.value;
}

module.exports = { parseIssueFormYaml };
