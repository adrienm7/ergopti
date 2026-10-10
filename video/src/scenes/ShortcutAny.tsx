// video/src/scenes/ShortcutAny.tsx
//
// Right after the teleport example: it is one action among the catalogue's,
// and any key combination can run any of them. A wall of the driver's real
// action labels drifts behind a binding whose keys and action keep changing.

import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { Sfx } from '../components/Sound';
import { FACTS, WINDOWS_ACTIONS } from '../lib/data';
import { pop } from '../lib/motion';
import { MONO } from '../styles';

/** Combinations the binding cycles through: any modifiers, any key. */
const COMBOS = [
	'Win + T',
	'Ctrl + Alt + M',
	'Alt + Space',
	'Shift + F3',
	'Win + Shift + K',
	'Ctrl + ;'
];
/** "More than" a round figure: the catalogue keeps growing. */
const ACTIONS_FLOOR = Math.floor(FACTS.actions.windows / 10) * 10;
const FIRST_SWAP = 40;
const SWAP_EVERY = 22;
const ROWS = 4;
const ROW_SPEED = [0.9, -0.7, 1.1, -0.8];

/** Actions spread over the whole catalogue rather than its first entries. */
const PICKED = WINDOWS_ACTIONS.filter((_, i) => i % 9 === 4);
if (PICKED.length < COMBOS.length) throw new Error('Too few Windows actions for the binding demo');

const Wall: React.FC<{ frame: number }> = ({ frame }) => (
	<div style={{ position: 'absolute', left: 0, right: 0, top: 560, opacity: 0.32 }}>
		{Array.from({ length: ROWS }, (_, row) => {
			const labels = WINDOWS_ACTIONS.filter((_, i) => i % ROWS === row);
			const shift = ((frame * ROW_SPEED[row] * 3) % 2400) - 1200;
			return (
				<div
					key={row}
					style={{
						display: 'flex',
						gap: 16,
						marginTop: 16,
						whiteSpace: 'nowrap',
						transform: `translateX(${shift}px)`
					}}
				>
					{[...labels, ...labels].map((a, i) => (
						<span
							key={i}
							style={{
								fontSize: 24,
								padding: '10px 18px',
								borderRadius: 12,
								background: 'var(--surface-strong)',
								border: '1px solid var(--border)'
							}}
						>
							{a.label}
						</span>
					))}
				</div>
			);
		})}
	</div>
);

export const ShortcutAny: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps, durationInFrames } = useVideoConfig();
	const step = Math.max(0, Math.floor((frame - FIRST_SWAP) / SWAP_EVERY) + 1);
	const since = frame - (FIRST_SWAP + (step - 1) * SWAP_EVERY);
	const combo = COMBOS[step % COMBOS.length];
	const action = PICKED[(step * 5) % PICKED.length].label;
	const roll = step === 0 ? 1 : Math.min(1, since / 8);
	const enter = Math.min(1, pop(frame, fps, 18));
	const swaps = Array.from(
		{ length: Math.ceil((durationInFrames - FIRST_SWAP) / SWAP_EVERY) },
		(_, i) => FIRST_SWAP + i * SWAP_EVERY
	);
	return (
		<AbsoluteFill>
			<Wall frame={frame} />
			<div style={{ position: 'absolute', left: 120, top: 110, width: 1650 }}>
				<Caption
					chapter="Shortcuts"
					icon="🎯"
					title={`Teleport is just one of more than ${ACTIONS_FLOOR} actions.`}
					sub="Assign any key combination to any action. Your keys, your rules."
					size={70}
				/>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 0,
					right: 0,
					top: 400,
					display: 'flex',
					justifyContent: 'center',
					alignItems: 'center',
					gap: 34,
					opacity: enter,
					transform: `scale(${0.92 + 0.08 * enter})`
				}}
			>
				<span
					style={{
						fontFamily: MONO,
						fontSize: 44,
						padding: '16px 30px',
						borderRadius: 18,
						background: 'var(--surface-strong)',
						border: '2px solid var(--accent-blue)',
						opacity: roll,
						transform: `translateY(${(1 - roll) * -24}px)`
					}}
				>
					{combo}
				</span>
				<span style={{ fontSize: 50, color: 'var(--accent-cyan)' }}>→</span>
				<span
					style={{
						fontSize: 40,
						fontWeight: 700,
						padding: '16px 30px',
						borderRadius: 18,
						background: 'color-mix(in srgb, #00bfa5 22%, var(--surface))',
						border: '2px solid #00bfa5',
						opacity: interpolate(since, [2, 10], [0, 1], {
							extrapolateLeft: 'clamp',
							extrapolateRight: 'clamp'
						}),
						transform: `translateY(${(1 - roll) * 24}px)`
					}}
				>
					{action}
				</span>
			</div>
			{swaps.map((f) => (
				<Sfx key={f} name="pop" at={f} volume={0.15} />
			))}
		</AbsoluteFill>
	);
};
