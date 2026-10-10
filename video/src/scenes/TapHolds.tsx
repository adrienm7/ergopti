// video/src/scenes/TapHolds.tsx
//
// Tap-holds as a principle, not as a preset. First one key, Space: a tap
// types a space, a hold turns it into something else (here, the navigation
// layer moving the caret). Then any key that every system has can do the
// same, with choices cycling under each one: nothing is imposed, everything
// is picked per key.

import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { Keycap } from '../components/Keycap';
import { OsWindow } from '../components/OsWindow';
import { Sfx } from '../components/Sound';
import { TAP_HOLD_KEYS, TAP_HOLD_OPTIONS } from '../lib/data';
import { pop, progress, rise } from '../lib/motion';
import { MONO } from '../styles';

const TAP_AT = 40;
const HOLD_AT = 92;
const HOLD_ACTIVE = 104;
/** Presses of the "left" key while Space is held. */
const LEFT_PRESSES = [116, 128, 140];
const RELEASE_AT = 158;
const PART_B = 186;
const TEXT = 'Meeting moved to Friday';

// Keys every system has, without the platform modifiers (Ctrl, Cmd).
const KEYS = TAP_HOLD_KEYS.filter((k) => !/ctrl|cmd|command|option|alt|win/i.test(k.id));

const Role: React.FC<{ kind: string; text: string; lit: number; color: string }> = ({
	kind,
	text,
	lit,
	color
}) => (
	<div
		style={{
			padding: '12px 22px',
			borderRadius: 14,
			textAlign: 'center',
			minWidth: 260,
			background: `color-mix(in srgb, ${color} ${Math.round(lit * 30)}%, var(--surface))`,
			border: `1px solid color-mix(in srgb, ${color} ${Math.round(25 + lit * 75)}%, transparent)`,
			transform: `scale(${1 + lit * 0.04})`
		}}
	>
		<div style={{ fontSize: 18, letterSpacing: '0.14em', fontWeight: 800, color }}>{kind}</div>
		<div
			style={{
				fontSize: 30,
				fontWeight: 600,
				marginTop: 4,
				color: lit > 0.5 ? '#fff' : 'var(--ink-soft)'
			}}
		>
			{text}
		</div>
	</div>
);

/** Part A: the principle on Space. */
const Principle: React.FC<{ frame: number }> = ({ frame }) => {
	const tapPress = frame >= TAP_AT && frame < TAP_AT + 5 ? 1 : 0;
	const holding = frame >= HOLD_AT && frame < RELEASE_AT;
	const tapLit = interpolate(frame, [TAP_AT, TAP_AT + 3, TAP_AT + 30], [0, 1, 0.2], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp'
	});
	const holdLit = frame >= HOLD_ACTIVE && frame < RELEASE_AT + 10 ? 1 : 0.15;
	const ring = interpolate(frame, [HOLD_AT, HOLD_ACTIVE], [0, 1], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp'
	});
	// The text: a space after the tap, then the caret steps left while held.
	const typed = frame >= TAP_AT ? `${TEXT} ` : TEXT;
	const caretBack = LEFT_PRESSES.filter((f) => frame >= f).length;
	const caretAt = [...typed].length - caretBack;
	const leftPress = LEFT_PRESSES.some((f) => frame >= f && frame < f + 5) ? 1 : 0;
	return (
		<>
			<div
				style={{
					position: 'absolute',
					left: 160,
					top: 420,
					display: 'flex',
					gap: 30,
					alignItems: 'center'
				}}
			>
				<div style={{ position: 'relative' }}>
					<Keycap
						label="Space"
						width={560}
						height={130}
						fontSize={40}
						press={Math.max(tapPress, holding ? 1 : 0)}
						lit={Math.max(tapLit, holding ? 0.9 : 0)}
					/>
					{holding ? (
						<div
							style={{
								position: 'absolute',
								left: 0,
								bottom: -16,
								height: 6,
								width: `${ring * 100}%`,
								borderRadius: 3,
								background: 'var(--accent-blue)'
							}}
						/>
					) : null}
				</div>
				{/* Blank on purpose: the key under Space's layer can be any key. */}
				<Keycap
					label=""
					width={130}
					height={130}
					fontSize={40}
					press={leftPress}
					lit={holding && frame >= HOLD_ACTIVE ? 0.8 : 0}
				/>
			</div>
			<div style={{ position: 'absolute', left: 160, top: 610, display: 'flex', gap: 24 }}>
				<Role kind="TAP" text="Space" lit={tapLit} color="var(--accent-cyan)" />
				<Role
					kind="HOLD"
					text={`${TAP_HOLD_OPTIONS.holds[1]} (example)`}
					lit={holdLit}
					color="var(--accent-blue)"
				/>
			</div>
			<div style={{ position: 'absolute', left: 1100, top: 400 }}>
				<OsWindow
					os="macos"
					title="Notes"
					width={700}
					height={300}
					bodyStyle={{ padding: '60px 50px' }}
				>
					<span style={{ fontFamily: MONO, fontSize: 40, color: '#eee', whiteSpace: 'pre' }}>
						{[...typed].slice(0, caretAt).join('')}
						<span style={{ display: 'inline-block', width: 0, position: 'relative' }}>
							<span
								style={{
									position: 'absolute',
									left: -1,
									bottom: '-0.25em',
									width: 3,
									height: '1.15em',
									background: 'var(--accent-blue)'
								}}
							/>
						</span>
						{[...typed].slice(caretAt).join('')}
					</span>
				</OsWindow>
			</div>
		</>
	);
};

/** Part B: any key, choices cycling under each. */
const AnyKey: React.FC<{ frame: number; fps: number }> = ({ frame, fps }) => (
	<div
		style={{
			position: 'absolute',
			left: 0,
			right: 0,
			top: 420,
			display: 'flex',
			justifyContent: 'center',
			gap: 26
		}}
	>
		{KEYS.map((key, i) => {
			const p = Math.min(1, pop(frame, fps, PART_B + 4 + i * 4));
			const cycle = Math.floor((frame - PART_B + i * 7) / 22);
			const tap = TAP_HOLD_OPTIONS.taps[(cycle + i) % TAP_HOLD_OPTIONS.taps.length];
			const hold = TAP_HOLD_OPTIONS.holds[(cycle + i * 2) % TAP_HOLD_OPTIONS.holds.length];
			return (
				<div
					key={key.id}
					style={{
						display: 'flex',
						flexDirection: 'column',
						alignItems: 'center',
						gap: 14,
						opacity: p,
						transform: `translateY(${(1 - p) * 40}px)`
					}}
				>
					<Keycap
						label={key.name}
						width={key.id === 'space' ? 260 : 170}
						height={110}
						fontSize={26}
						lit={0.25}
					/>
					<div style={{ fontSize: 20, color: 'var(--accent-cyan)', fontWeight: 700 }}>TAP</div>
					<div style={{ fontSize: 22, color: '#fff', minHeight: 30 }}>{tap}</div>
					<div style={{ fontSize: 20, color: 'var(--accent-blue)', fontWeight: 700 }}>HOLD</div>
					<div style={{ fontSize: 22, color: '#fff', minHeight: 30 }}>{hold}</div>
				</div>
			);
		})}
	</div>
);

export const TapHolds: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const toB = progress(frame, PART_B - 14, 14);
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 100, width: 1500, opacity: 1 - toB }}>
				<Caption
					chapter="Tap-holds"
					icon="⌨"
					title="One key, two jobs."
					sub="Tap it: it does its usual thing. Hold it: it becomes something else. Space shown here."
					size={70}
				/>
			</div>
			{frame < PART_B ? (
				<div style={{ opacity: 1 - toB }}>
					<Principle frame={frame} />
				</div>
			) : null}
			{frame >= PART_B - 14 ? (
				<>
					<div style={{ position: 'absolute', left: 120, top: 100, width: 1600, opacity: toB }}>
						<Caption
							chapter="Tap-holds"
							icon="⌨"
							title="Any key. Any action. Your choice."
							sub="Pick the tap and the hold of each key you want; change or turn off any of them from the menu."
							size={64}
							delay={PART_B - 14}
						/>
					</div>
					<div style={{ opacity: toB }}>
						<AnyKey frame={frame} fps={fps} />
					</div>
					<div
						style={{
							position: 'absolute',
							left: 0,
							right: 0,
							top: 900,
							textAlign: 'center',
							fontSize: 28,
							color: 'var(--ink-soft)',
							...rise(progress(frame, PART_B + 50, 20), 16)
						}}
					>
						Same keys on Windows, macOS and Linux.
					</div>
				</>
			) : null}
			<Sfx name="key" at={TAP_AT} />
			<Sfx name="thock" at={HOLD_AT} volume={0.35} />
			{LEFT_PRESSES.map((f) => (
				<Sfx key={f} name="key" at={f} />
			))}
		</AbsoluteFill>
	);
};
