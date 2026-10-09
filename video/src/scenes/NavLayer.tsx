// video/src/scenes/NavLayer.tsx
//
// The navigation layer on a keyboard with no legends (the layer works on
// physical positions, whatever the layout): the recommended bindings from
// _shared/keymap/layers.recommended.toml light up group by group while Space
// is held, as one example of where the layer can live.

import React from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { Keycap } from '../components/Keycap';
import { Sfx } from '../components/Sound';
import { NAV_LAYER } from '../lib/data';
import { pop, progress } from '../lib/motion';

/** Physical rows of an ISO-like board, by KeyboardEvent.code. */
const ROWS: Array<{ indent: number; codes: string[] }> = [
	{
		indent: 0,
		codes: [
			'KeyQ',
			'KeyW',
			'KeyE',
			'KeyR',
			'KeyT',
			'KeyY',
			'KeyU',
			'KeyI',
			'KeyO',
			'KeyP',
			'BracketLeft'
		]
	},
	{
		indent: 0.5,
		codes: [
			'CapsLock',
			'KeyA',
			'KeyS',
			'KeyD',
			'KeyF',
			'KeyG',
			'KeyH',
			'KeyJ',
			'KeyK',
			'KeyL',
			'Semicolon',
			'Quote'
		]
	},
	{
		indent: 0.25,
		codes: [
			'IntlBackslash',
			'KeyZ',
			'KeyX',
			'KeyC',
			'KeyV',
			'KeyB',
			'KeyN',
			'KeyM',
			'Comma',
			'Period',
			'Slash'
		]
	}
];
const KEY = 104;
const GAP = 12;
/** Groups lit in turn, by the actions they hold. */
const GROUPS: Array<{ name: string; actions: string[]; at: number }> = [
	{ name: 'Arrows', actions: ['arrow_up', 'arrow_down', 'arrow_left', 'arrow_right'], at: 40 },
	{
		name: 'Words and lines',
		actions: ['word_prev', 'word_next', 'line_start', 'line_end'],
		at: 85
	},
	{
		name: 'Selection',
		actions: [
			'sel_line_start',
			'sel_word_prev',
			'sel_left',
			'sel_right',
			'sel_word_next',
			'sel_line_end'
		],
		at: 130
	},
	{
		name: 'Line editing',
		actions: ['move_line_up', 'move_line_down', 'duplicate_line_down', 'new_line_below'],
		at: 175
	}
];

/**
 * The symbols a label starts with, to fit on a keycap: the leading tokens
 * that are not words ("W ← Previous word" → "W←"), three characters at most.
 */
const glyph = (label: string): string => {
	const tokens: string[] = [];
	for (const token of label.split(/\s+/)) {
		if (/\p{L}{3,}/u.test(token)) break;
		tokens.push(token);
	}
	return [...(tokens.join('') || label)].slice(0, 3).join('');
};

export const NavLayer: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const byCode = new Map(NAV_LAYER.map((b) => [b.code, b]));
	const active = GROUPS.reduce((g, group, i) => (frame >= group.at ? i : g), -1);
	const boardIn = Math.min(1, pop(frame, fps, 6));
	const boardLeft = (1920 - 12 * (KEY + GAP)) / 2;
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 80, width: 1600 }}>
				<Caption
					chapter="Navigation layer"
					icon="☷"
					title="Move, select and edit without leaving the home row."
					sub="Example: hold Space. The layer, its key and every binding are yours to change."
					size={58}
				/>
			</div>
			<div
				style={{
					position: 'absolute',
					left: boardLeft,
					top: 400,
					opacity: boardIn,
					transform: `translateY(${(1 - boardIn) * 40}px)`
				}}
			>
				{ROWS.map((row, r) => (
					<div
						key={r}
						style={{
							display: 'flex',
							gap: GAP,
							marginBottom: GAP,
							marginLeft: row.indent * (KEY + GAP)
						}}
					>
						{row.codes.map((code) => {
							const binding = byCode.get(code);
							const group = binding
								? GROUPS.findIndex((g) => g.actions.includes(binding.action))
								: -1;
							const lit =
								group >= 0 && group === active ? progress(frame, GROUPS[group].at, 10) : 0;
							return (
								<Keycap
									key={code}
									label={
										<span style={{ fontSize: binding ? 30 : 18, opacity: binding ? 1 : 0.3 }}>
											{binding ? glyph(binding.label) : ''}
										</span>
									}
									width={KEY}
									height={KEY}
									lit={lit}
									press={lit > 0 && lit < 1 ? 0.4 : 0}
								/>
							);
						})}
					</div>
				))}
				<div style={{ marginLeft: 3 * (KEY + GAP), marginTop: 6 }}>
					<Keycap
						label="Space · held"
						width={6 * (KEY + GAP) - GAP}
						height={KEY}
						fontSize={28}
						press={1}
						lit={0.9}
					/>
				</div>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 0,
					right: 0,
					top: 930,
					display: 'flex',
					justifyContent: 'center',
					gap: 40
				}}
			>
				{GROUPS.map((group, i) => (
					<div
						key={group.name}
						style={{
							fontSize: 28,
							fontWeight: i === active ? 800 : 500,
							color: i === active ? '#fff' : 'var(--ink-faint)'
						}}
					>
						{group.name}
					</div>
				))}
			</div>
			{GROUPS.map((group) => (
				<Sfx key={group.name} name="pop" at={group.at} volume={0.25} />
			))}
		</AbsoluteFill>
	);
};
