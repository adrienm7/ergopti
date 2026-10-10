// video/src/scenes/ThreeOs.tsx
//
// One system at a time, full frame, each showing a different hotstring
// family: autocorrection on Windows, a ★ abbreviation on macOS, ★ symbols on
// Linux. The closing card says it once: the same files drive all three.

import React, { useMemo } from 'react';
import { AbsoluteFill, interpolate, Sequence, useCurrentFrame, useVideoConfig } from 'remotion';
import { OsWindow, type Os } from '../components/OsWindow';
import { KeySounds, Sfx } from '../components/Sound';
import { compileTyping, TypedText, type Step } from '../components/Typewriter';
import { progress } from '../lib/motion';

const PHASE = 135;
const PHASES: Array<{ os: Os; name: string; feature: string; app: string; steps: Step[] }> = [
	{
		os: 'windows',
		name: 'Windows',
		feature: 'Autocorrection',
		app: 'Outlook',
		steps: [
			{ type: 'I asked ' },
			{ hotstring: 'chatgpt', end: ' about it on ' },
			{ hotstring: 'youtube', end: '.' }
		]
	},
	{
		os: 'macos',
		name: 'macOS',
		feature: '★ abbreviations',
		app: 'Messages',
		steps: [{ type: 'Salut, ' }, { hotstring: 'ecq★', end: ' tu viens ce soir ?' }]
	},
	{
		os: 'linux',
		name: 'Linux',
		feature: '★ symbols',
		app: 'Text Editor',
		steps: [
			{ type: 'Proof: ' },
			{ hotstring: '(for all)★', end: ' x, A ' },
			{ hotstring: '< = >★', end: ' B' }
		]
	}
];
const CLOSING_AT = PHASE * 3 - 6;

const Phase: React.FC<{ index: number }> = ({ index }) => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const phase = PHASES[index];
	const typing = useMemo(
		() => compileTyping(phase.steps, fps, 14, `os-${index}`),
		[fps, index, phase]
	);
	const enter = progress(frame, 0, 14);
	const leave = interpolate(frame, [PHASE - 10, PHASE], [0, 1], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp'
	});
	return (
		<AbsoluteFill>
			<div
				style={{
					position: 'absolute',
					left: 230,
					top: 300,
					opacity: enter * (1 - leave),
					transform: `translateX(${(1 - enter) * 160 - leave * 160}px) scale(${0.96 + 0.04 * enter})`
				}}
			>
				<OsWindow
					os={phase.os}
					title={phase.app}
					width={1460}
					height={460}
					bodyStyle={{ padding: '80px 80px' }}
				>
					<TypedText typing={typing} fontSize={60} />
				</OsWindow>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 230,
					top: 200,
					fontSize: 56,
					fontWeight: 800,
					letterSpacing: '0.04em',
					color: 'var(--accent-blue)',
					opacity: enter * (1 - leave)
				}}
			>
				{phase.name}
				<span
					style={{
						marginLeft: 24,
						fontSize: 34,
						fontWeight: 600,
						letterSpacing: 0,
						color: 'var(--ink-soft)'
					}}
				>
					{phase.feature}
				</span>
			</div>
			<KeySounds keys={typing.keys} />
			{typing.expansions.map((f) => (
				<Sfx key={f} name="pop" at={f} />
			))}
		</AbsoluteFill>
	);
};

export const ThreeOs: React.FC = () => {
	const frame = useCurrentFrame();
	const closing = progress(frame, CLOSING_AT, 18);
	return (
		<AbsoluteFill>
			{PHASES.map((_, i) => (
				<Sequence key={i} from={i * PHASE} durationInFrames={PHASE} layout="none">
					<Phase index={i} />
				</Sequence>
			))}
			<AbsoluteFill
				style={{
					alignItems: 'center',
					justifyContent: 'center',
					flexDirection: 'column',
					gap: 22,
					opacity: closing
				}}
			>
				<div style={{ fontSize: 92, fontWeight: 800, letterSpacing: '-0.02em' }}>
					Same config. Every system.
				</div>
				<div style={{ fontSize: 34, color: 'var(--ink-soft)' }}>
					One set of hotstring files, in every app.
				</div>
			</AbsoluteFill>
		</AbsoluteFill>
	);
};
