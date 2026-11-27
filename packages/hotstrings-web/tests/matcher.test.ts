// packages/hotstrings-web/tests/matcher.test.ts

import { describe, expect, it } from 'vitest';
import {
	DEFAULT_TERMINATORS,
	HotstringMatcher,
	foldCase,
	isWordChar,
	lowerCase,
	type Hotstring
} from '../src/index.js';

function hs(trigger: string, output: string, extra: Partial<Hotstring> = {}): Hotstring {
	return {
		trigger,
		output,
		expand: 'terminator',
		terminator: 'echo',
		caseSensitive: false,
		wordStart: false,
		...extra
	};
}

describe('case helpers', () => {
	it('lower-cases per code point and keeps a code point whose lower form is longer', () => {
		expect(lowerCase('ÀBC')).toBe('àbc');
		expect(lowerCase('İ')).toBe('İ');
	});

	it('folds the final sigma to sigma', () => {
		expect(foldCase('ΣΑΣ')).toBe('σασ');
		expect(foldCase('ας')).toBe('ασ');
	});

	it('reads ASCII letters, digits, _, @ and every non-ASCII character as word characters', () => {
		for (const ch of ['a', 'Z', '5', '_', '@', 'é', '★']) expect(isWordChar(ch)).toBe(true);
		for (const ch of [' ', '.', '-', "'", '\n']) expect(isWordChar(ch)).toBe(false);
	});

	it('ships the default terminators of Ergopti', () => {
		expect(DEFAULT_TERMINATORS).toBe(' \t\n\r★,;.!?:');
	});
});

describe('HotstringMatcher construction', () => {
	it('refuses an empty trigger, a non-string output and a key mode without key', () => {
		expect(() => new HotstringMatcher([hs('', 'x')])).toThrow(/trigger/);
		expect(() => new HotstringMatcher([hs('a', 1 as unknown as string)])).toThrow(/output/);
		expect(() => new HotstringMatcher([hs('a', 'b', { expand: 'key' })])).toThrow(/key/);
	});

	it('accepts an empty list', () => {
		expect(new HotstringMatcher([]).match('btw', ' ')).toBeNull();
	});
});

describe('terminator expansion', () => {
	const matcher = new HotstringMatcher([hs('btw', 'by the way')]);

	it('fires on a terminator and echoes it', () => {
		expect(matcher.match('I said btw', ',')).toEqual({
			hotstring: expect.objectContaining({ trigger: 'btw' }),
			deleteCount: 3,
			insert: 'by the way,',
			consumedKey: true,
			restore: 'btw,'
		});
	});

	it('does not fire on a letter, an empty key or a key that is no terminator', () => {
		expect(matcher.match('bt', 'w')).toBeNull();
		expect(matcher.match('btw', '')).toBeNull();
		expect(matcher.match('btw', '-')).toBeNull();
		expect(matcher.match('btw', 'F2')).toBeNull();
	});

	it('maps Enter and Tab to their terminators', () => {
		expect(matcher.match('btw', 'Enter')?.insert).toBe('by the way\n');
		expect(matcher.match('btw', 'Tab')?.insert).toBe('by the way\t');
	});

	it('takes custom terminators', () => {
		const custom = new HotstringMatcher([hs('btw', 'by the way')], { terminators: '-' });
		expect(custom.match('btw', '-')?.insert).toBe('by the way-');
		expect(custom.match('btw', ' ')).toBeNull();
	});

	it('consumes the terminator for a consume hotstring and for the magic key', () => {
		const consume = new HotstringMatcher([hs('btw', 'by the way', { terminator: 'consume' })]);
		expect(consume.match('btw', ' ')).toMatchObject({ insert: 'by the way', consumedKey: true, restore: 'btw' });
		expect(matcher.match('btw', '★')).toMatchObject({ insert: 'by the way', consumedKey: true, restore: 'btw' });
		const other = new HotstringMatcher([hs('btw', 'x')], { consumed: '!' });
		expect(other.match('btw', '!')?.insert).toBe('x');
		expect(other.match('btw', '★')?.insert).toBe('x★');
	});

	it('tolerates a no-break space before a colon or semicolon', () => {
		expect(matcher.match('btw ', ':')).toMatchObject({ deleteCount: 4, insert: 'by the way :' });
		expect(matcher.match('btw ', ';')).toMatchObject({ deleteCount: 4, insert: 'by the way ;' });
		expect(matcher.match('btw ', ',')).toBeNull();
		expect(matcher.match('btw', ':')?.deleteCount).toBe(3);
	});
});

describe('end-key modes', () => {
	const matcher = new HotstringMatcher([
		hs('sig', 'Signature', { expand: 'enter' }),
		hs('tb', 'table', { expand: 'tab' }),
		hs('dd', 'date', { expand: 'key', key: 'F2' }),
		hs('nl', 'newline', { expand: 'key', key: '\n' }),
		hs('kk', 'kay', { expand: 'key', key: 'Enter', terminator: 'consume' })
	]);

	it('fires only on its key', () => {
		expect(matcher.match('sig', 'Enter')?.insert).toBe('Signature\n');
		expect(matcher.match('sig', ' ')).toBeNull();
		expect(matcher.match('tb', 'Tab')?.insert).toBe('table\t');
		expect(matcher.match('tb', 'Enter')).toBeNull();
	});

	it('lets a named key do its own work when echoed, and swallows it when consumed', () => {
		expect(matcher.match('dd', 'F2')).toMatchObject({ insert: 'date', consumedKey: false, restore: 'dd' });
		expect(matcher.match('dd', 'F3')).toBeNull();
		expect(matcher.match('nl', 'Enter')?.insert).toBe('newline\n');
		expect(matcher.match('kk', '\n')).toMatchObject({ insert: 'kay', consumedKey: true });
		const named = new HotstringMatcher([hs('dd', 'date', { expand: 'key', key: 'F2', terminator: 'consume' })]);
		expect(named.match('dd', 'F2')).toMatchObject({ insert: 'date', consumedKey: true });
	});
});

describe('immediate expansion', () => {
	it('fires on the last trigger character and drops a final magic key from the restore', () => {
		const matcher = new HotstringMatcher([hs('td★', 'today', { expand: 'immediate' })]);
		expect(matcher.match('td', '★')).toEqual({
			hotstring: expect.anything(),
			deleteCount: 2,
			insert: 'today',
			consumedKey: true,
			restore: 'td'
		});
		expect(matcher.match('td', 'Enter')).toBeNull();
	});

	it('keeps the restore whole without a magic key', () => {
		const matcher = new HotstringMatcher([hs('td★', 'today', { expand: 'immediate' })], { magicKey: '' });
		expect(matcher.match('td', '★')?.restore).toBe('td★');
	});

	it('loses to a strictly longer end-key trigger and wins a tie', () => {
		const matcher = new HotstringMatcher([
			hs('a.', 'IMMEDIATE', { expand: 'immediate' }),
			hs('xba', 'ENDING')
		]);
		expect(matcher.match('xba', '.')?.insert).toBe('ENDING.');
		const tie = new HotstringMatcher([hs('b.', 'IMMEDIATE', { expand: 'immediate' }), hs('xb', 'ENDING')]);
		expect(tie.match('xb', '.')?.insert).toBe('IMMEDIATE');
	});
});

describe('collisions', () => {
	it('prefers the longest trigger, then the priority, then the first listed', () => {
		const matcher = new HotstringMatcher([
			hs('w', 'short', { expand: 'immediate' }),
			hs('ow', 'low', { expand: 'immediate', priority: 1 }),
			hs('ow', 'high', { expand: 'immediate', priority: 5 }),
			hs('ow', 'high-late', { expand: 'immediate', priority: 5 })
		]);
		expect(matcher.match('o', 'w')?.insert).toBe('high');
		expect(matcher.match('x', 'w')?.insert).toBe('short');
	});

	it('falls back to a shorter trigger when the longer one is blocked', () => {
		const matcher = new HotstringMatcher([
			hs('ab', 'AB', { wordStart: true, caseSensitive: true }),
			hs('b', 'B', { caseSensitive: true })
		]);
		expect(matcher.match('xab', ' ')?.insert).toBe('B ');
		expect(matcher.match('ab', ' ')?.insert).toBe('AB ');
	});
});

describe('case rules', () => {
	it('conforms the output to a lower, Title or UPPER trigger and refuses another casing', () => {
		const matcher = new HotstringMatcher([hs('ppt', 'PowerPoint {cursor}')]);
		expect(matcher.match('ppt', ' ')?.insert).toBe('PowerPoint {cursor} ');
		expect(matcher.match('Ppt', ' ')?.insert).toBe('PowerPoint {cursor} ');
		expect(matcher.match('PPT', ' ')?.insert).toBe('POWERPOINT {cursor} ');
		expect(matcher.match('pPt', ' ')).toBeNull();
	});

	it('keeps a leading placeholder and an empty output under Title case', () => {
		const matcher = new HotstringMatcher([hs('sel', '{selection} done'), hs('del', '')]);
		expect(matcher.match('Sel', ' ')?.insert).toBe('{selection} done ');
		expect(matcher.match('SEL', ' ')?.insert).toBe('{selection} DONE ');
		expect(matcher.match('Del', ' ')?.insert).toBe(' ');
	});

	it('folds and keeps the output verbatim in the literal mode', () => {
		const matcher = new HotstringMatcher([hs('adn', 'ADN', { conformCase: false })]);
		expect(matcher.match('aDn', ' ')?.insert).toBe('ADN ');
		expect(matcher.match('adx', ' ')).toBeNull();
	});

	it('tells final sigma from sigma when conforming, as trig_lower does', () => {
		const matcher = new HotstringMatcher([hs('ας', 'word')]);
		expect(matcher.match('ας', ' ')?.insert).toBe('word ');
		expect(matcher.match('ασ', ' ')).toBeNull();
	});

	it('compares exactly in the strict mode', () => {
		const matcher = new HotstringMatcher([hs('BTW', 'by the way', { caseSensitive: true })]);
		expect(matcher.match('BTW', ' ')?.insert).toBe('by the way ');
		expect(matcher.match('btw', ' ')).toBeNull();
	});
});

describe('word start and no-op', () => {
	const matcher = new HotstringMatcher([hs('the', 'THE', { wordStart: true, caseSensitive: true })]);

	it('fires at the line start and after a separator, not inside a word', () => {
		expect(matcher.match('the', ' ')).not.toBeNull();
		expect(matcher.match('a the', ' ')).not.toBeNull();
		expect(matcher.match('bathe', ' ')).toBeNull();
		expect(matcher.match('éthe', ' ')).toBeNull();
	});

	it('fires nothing when the output equals the typed trigger', () => {
		expect(new HotstringMatcher([hs('ok', 'ok')]).match('ok', ' ')).toBeNull();
	});
});

describe('surrogate pairs', () => {
	it('walks code points, not UTF-16 units', () => {
		const matcher = new HotstringMatcher([hs('🎉x', 'party', { wordStart: true }), hs('y', 'Y')]);
		expect(matcher.match(' 🎉x', ' ')).toMatchObject({ deleteCount: 3, insert: 'party ' });
		expect(matcher.match('a🎉x', ' ')).toBeNull();
		expect(matcher.match('\udc00y', ' ')?.insert).toBe('Y ');
		expect(matcher.match('a\udc00y', ' ')?.insert).toBe('Y ');
		const lone = new HotstringMatcher([hs('\udc00', 'L')]);
		expect(lone.match('\udc00', ' ')?.insert).toBe('L ');
	});
});

describe('performance', () => {
	it('stays under 1 ms per keystroke on average with 1 000 hotstrings', () => {
		const list: Hotstring[] = [];
		for (let i = 0; i < 1000; i += 1) {
			const trigger = `w${i.toString(36)}${'abcdefghij'[i % 10]}`;
			list.push(hs(trigger, `output ${i}`, { expand: i % 3 === 0 ? 'immediate' : 'terminator' }));
		}
		const matcher = new HotstringMatcher(list);
		const text = 'the quick brown fox jumps over w1a the lazy dog, w2b. '.repeat(40);
		let before = '';
		const started = performance.now();
		for (const ch of text) {
			const e = matcher.match(before, ch);
			before = e ? before.slice(0, before.length - e.deleteCount) + e.insert : before + ch;
			if (ch === '\n') before = '';
		}
		const perKey = (performance.now() - started) / text.length;
		console.info(`hotstring match: ${(perKey * 1000).toFixed(2)} µs per keystroke over ${text.length} keys`);
		expect(perKey).toBeLessThan(1);
	});
});
