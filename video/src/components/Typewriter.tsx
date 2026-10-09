// video/src/components/Typewriter.tsx
//
// Deterministic typing engine. A scene lists steps (text, hotstring trigger,
// pause, instant insertion); compileTyping() turns them into keyframes once,
// and <TypedText> renders the state of any frame. Hotstring outputs and
// colours come from the driver data, so a scene only names the trigger.

import React from 'react';
import { random, useCurrentFrame } from 'remotion';
import { hotstring } from '../lib/data';
import { MONO } from '../styles';
import { DriverTooltip } from './Tooltips';

export type Step =
	| { type: string; cps?: number }
	| {
			hotstring: string;
			end?: string;
			demo?: { output: string; color: string };
			/** Keys actually struck, when they differ in case from the trigger. */
			typed?: string;
	  }
	| { pause: number }
	| { insert: string; color?: string }
	| { erase: number }
	| { mark: string };

type Run = { text: string; color?: string; at: number };
type Tip = { text: string; color: string; since: number; until: number };
type Keyframe = { frame: number; runs: Run[] };

export type Typing = {
	keyframes: Keyframe[];
	tips: Tip[];
	/** Frames at which a key is struck, for sound. */
	keys: number[];
	/** Frames at which a hotstring fires. */
	expansions: number[];
	marks: Record<string, number>;
	end: number;
};

/** Default typing speed in characters per second. */
const DEFAULT_CPS = 14;
/** Frames the preview tooltip shows before the trigger completes. */
const PREVIEW_LEAD = 10;
/** Frames the tooltip lingers after the expansion. */
const TIP_LINGER = 28;

/**
 * Compile typing steps into frame keyframes.
 * @param steps - What to type, in order.
 * @param fps - Composition frame rate.
 * @param start - Frame the first key is struck at.
 * @param seed - Seed for the human-like rhythm.
 */
export function compileTyping(steps: Step[], fps: number, start = 0, seed = 'type'): Typing {
	let frame = start;
	let runs: Run[] = [];
	const keyframes: Keyframe[] = [{ frame, runs }];
	const tips: Tip[] = [];
	const keys: number[] = [];
	const expansions: number[] = [];
	const marks: Record<string, number> = {};
	let n = 0;

	const push = (next: Run[]) => {
		runs = next;
		keyframes.push({ frame, runs });
	};
	const typeChar = (ch: string, cps: number) => {
		const gap = (fps / cps) * (0.6 + random(`${seed}-${n++}`) * 0.8);
		frame += Math.max(1, Math.round(gap));
		keys.push(frame);
		const last = runs[runs.length - 1];
		if (last && last.color === undefined)
			push([...runs.slice(0, -1), { ...last, text: last.text + ch }]);
		else push([...runs, { text: ch, at: frame }]);
	};
	const erase = (count: number) => {
		let left = count;
		const next = runs.map((r) => ({ ...r }));
		while (left > 0 && next.length > 0) {
			const last = next[next.length - 1];
			const chars = [...last.text];
			const cut = Math.min(left, chars.length);
			last.text = chars.slice(0, chars.length - cut).join('');
			left -= cut;
			if (last.text === '') next.pop();
		}
		push(next);
	};

	for (const step of steps) {
		if ('type' in step) {
			for (const ch of step.type) typeChar(ch, step.cps ?? DEFAULT_CPS);
		} else if ('pause' in step) {
			frame += step.pause;
		} else if ('mark' in step) {
			marks[step.mark] = frame;
		} else if ('erase' in step) {
			erase(step.erase);
		} else if ('insert' in step) {
			frame += 1;
			push([...runs, { text: step.insert, color: step.color, at: frame }]);
		} else {
			// A personal hotstring brings its output; a built-in one is looked up.
			const found = step.demo ?? hotstring(step.hotstring);
			const chars = [...(step.typed ?? step.hotstring)];
			if (chars.join('').toLowerCase() !== step.hotstring.toLowerCase())
				throw new Error(`Typed ${step.typed} is not the trigger ${step.hotstring}`);
			// A capitalised trigger capitalises the output, as the driver does.
			const capital = chars[0] !== step.hotstring[0] && chars[0] === chars[0].toUpperCase();
			const demo = capital
				? { ...found, output: found.output[0].toUpperCase() + found.output.slice(1) }
				: found;
			const starred = chars[chars.length - 1] === '★';
			const body = starred ? chars.slice(0, -1) : chars;
			for (const ch of body) typeChar(ch, DEFAULT_CPS);
			const tipStart = frame;
			frame += PREVIEW_LEAD;
			// The ★ key, or the first character after the word, fires the
			// expansion; the rest of `end` is typed after it, as on a keyboard.
			const after = [...(step.end ?? (starred ? '' : ' '))];
			const fire = starred ? '★' : after.shift();
			if (fire === undefined) throw new Error(`Hotstring ${step.hotstring} needs an end character`);
			typeChar(fire, DEFAULT_CPS);
			erase(chars.length + (starred ? 0 : 1));
			frame += 1;
			expansions.push(frame);
			push([...runs, { text: demo.output, color: demo.color, at: frame }]);
			if (!starred) push([...runs, { text: fire, at: frame }]);
			for (const ch of after) typeChar(ch, DEFAULT_CPS);
			tips.push({
				text: demo.output,
				color: demo.color,
				since: tipStart,
				until: frame + TIP_LINGER
			});
		}
	}
	return { keyframes, tips, keys, expansions, marks, end: frame };
}

/**
 * The runs on screen at a frame.
 * @param typing - Compiled typing.
 * @param frame - Current frame.
 */
function runsAt(typing: Typing, frame: number): Run[] {
	let lo = 0;
	let hi = typing.keyframes.length - 1;
	while (lo < hi) {
		const mid = (lo + hi + 1) >> 1;
		if (typing.keyframes[mid].frame <= frame) lo = mid;
		else hi = mid - 1;
	}
	return typing.keyframes[lo].frame <= frame ? typing.keyframes[lo].runs : [];
}

/**
 * Keys struck and characters on screen at a frame, for keystroke counters.
 * @param typing - Compiled typing.
 * @param frame - Current frame.
 */
export function typingStats(typing: Typing, frame: number): { keys: number; chars: number } {
	return {
		keys: typing.keys.filter((k) => k <= frame).length,
		chars: runsAt(typing, frame).reduce((n, r) => n + [...r.text].length, 0)
	};
}

type Props = {
	typing: Typing;
	fontSize?: number;
	color?: string;
	font?: string;
	/** Hide the caret, e.g. once a scene moves on. */
	caret?: boolean;
	/** Extra element anchored at the caret (prediction tooltip). */
	atCaret?: React.ReactNode;
};

export const TypedText: React.FC<Props> = ({
	typing,
	fontSize = 34,
	color = '#e8e8ea',
	font = MONO,
	caret = true,
	atCaret
}) => {
	const frame = useCurrentFrame();
	const runs = runsAt(typing, frame);
	const tip = typing.tips.find((t) => frame >= t.since && frame < t.until);
	const blink =
		Math.floor(frame / 16) % 2 === 0 || typing.keys.some((k) => frame - k >= 0 && frame - k < 10);
	return (
		<span style={{ fontFamily: font, fontSize, color, whiteSpace: 'pre-wrap', lineHeight: 1.5 }}>
			{runs.map((r, i) => {
				const age = frame - r.at;
				const glow = r.color ? Math.max(0, 1 - age / 40) : 0;
				return (
					<span
						key={i}
						style={
							r.color
								? {
										color,
										background: `color-mix(in srgb, ${r.color} ${Math.round(glow * 45)}%, transparent)`,
										borderRadius: 6,
										boxShadow:
											glow > 0
												? `0 0 ${24 * glow}px color-mix(in srgb, ${r.color} ${Math.round(glow * 70)}%, transparent)`
												: 'none'
									}
								: undefined
						}
					>
						{r.text}
					</span>
				);
			})}
			<span style={{ position: 'relative', display: 'inline-block', width: 0 }}>
				<span
					style={{
						// The zero-width anchor sits on the baseline.
						position: 'absolute',
						left: 1,
						bottom: '-0.28em',
						width: 3,
						height: '1.15em',
						borderRadius: 2,
						background: 'var(--accent-blue)',
						opacity: caret && blink ? 1 : 0
					}}
				/>
				{tip ? (
					<DriverTooltip
						text={tip.text}
						color={tip.color}
						age={frame - tip.since}
						remaining={tip.until - frame}
					/>
				) : null}
				{atCaret}
			</span>
		</span>
	);
};
