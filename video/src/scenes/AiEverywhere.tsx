// video/src/scenes/AiEverywhere.tsx
//
// The killer feature, everywhere: the same prediction tooltip at the caret in
// a terminal, an IDE, a browser, Teams and WhatsApp, across Windows, macOS
// and Linux. Each vignette types a little, shows a prediction and accepts it.

import React, { useMemo } from 'react';
import { AbsoluteFill, interpolate, Sequence, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { OsWindow, type Os } from '../components/OsWindow';
import { KeySounds, Sfx } from '../components/Sound';
import { PredictionTooltip } from '../components/Tooltips';
import { compileTyping, TypedText, type Step } from '../components/Typewriter';
import { progress } from '../lib/motion';
import { MONO, SANS } from '../styles';

const VIGNETTE = 88;
/** Typing speed, fast enough to leave room for the prediction. */
const CPS = 34;
/** Frames between the last key and the tooltip, then until it is accepted. */
const SHOW_DELAY = 6;
const SHOW_FRAMES = 26;
const AI_COLOR = 'var(--family-ia)';

type Vignette = {
	app: string;
	os: Os;
	osName: string;
	prefix?: string;
	typed: string;
	prediction: string;
	alternatives: string[];
	mono?: boolean;
	background: string;
};

const VIGNETTES: Vignette[] = [
	{
		app: 'Terminal',
		os: 'linux',
		osName: 'Linux',
		prefix: '~/ergopti $ ',
		typed: 'git commit -m "fix tooltip pos',
		prediction: 'ition on multi-monitor setups"',
		alternatives: ['ition when the caret is hidden"', 'ition in terminals"'],
		mono: true,
		background: '#0c0c0c'
	},
	{
		app: 'Visual Studio Code',
		os: 'windows',
		osName: 'Windows',
		prefix: '12  ',
		typed: "// Debounce the search box so we don't ",
		prediction: 'call the API on every keystroke',
		alternatives: ['flood the server while typing', 're-render the list each time'],
		mono: true,
		background: '#1e1e1e'
	},
	{
		app: 'New message — Browser',
		os: 'macos',
		osName: 'macOS',
		typed: 'Could you send me the updated slides before ',
		prediction: 'Thursday’s review?',
		alternatives: ['the client call tomorrow?', 'the end of the day?'],
		background: '#1b1d22'
	},
	{
		app: 'Microsoft Teams',
		os: 'windows',
		osName: 'Windows',
		typed: 'Running five minutes late, start without ',
		prediction: 'me and I’ll catch up.',
		alternatives: ['me, I’ll join shortly.', 'me if needed.'],
		background: '#1f1f2e'
	},
	{
		app: 'WhatsApp',
		os: 'macos',
		osName: 'macOS',
		typed: 'Happy birthday! Hope you have ',
		prediction: 'an amazing day, see you tonight!',
		alternatives: ['a wonderful year ahead!', 'a great celebration!'],
		background: '#0b141a'
	}
];

const Clip: React.FC<{ v: Vignette; index: number }> = ({ v, index }) => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const { typing, showAt, acceptAt } = useMemo(() => {
		const typed: Step[] = [{ type: v.typed, cps: CPS }];
		const seed = `ai-${index}`;
		const first = compileTyping(typed, fps, 4, seed);
		const show = first.end + SHOW_DELAY;
		const accept = show + SHOW_FRAMES;
		const full = compileTyping(
			[...typed, { pause: accept - first.end - 1 }, { insert: v.prediction, color: AI_COLOR }],
			fps,
			4,
			seed
		);
		return { typing: full, showAt: show, acceptAt: accept };
	}, [fps, index, v]);
	const visible = frame >= showAt && frame < acceptAt;
	const enter = progress(frame, 0, 12);
	const leave = interpolate(frame, [VIGNETTE - 8, VIGNETTE], [0, 1], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp'
	});
	const context = v.typed.split(' ').slice(-4).join(' ');
	return (
		<AbsoluteFill>
			<div
				style={{
					position: 'absolute',
					left: 250,
					top: 300,
					opacity: enter * (1 - leave),
					transform: `translateY(${(1 - enter) * 40}px) scale(${0.97 + 0.03 * enter - leave * 0.03})`
				}}
			>
				<OsWindow
					os={v.os}
					title={v.app}
					width={1420}
					height={420}
					bodyStyle={{ padding: '48px 56px', background: v.background }}
				>
					{v.prefix ? (
						<span style={{ fontFamily: MONO, fontSize: 38, color: '#5ad16a' }}>{v.prefix}</span>
					) : null}
					<TypedText
						typing={typing}
						fontSize={38}
						font={v.mono ? MONO : SANS}
						atCaret={
							visible ? (
								<PredictionTooltip
									context={`${context} `}
									lines={[
										{ continuation: v.prediction },
										...v.alternatives.map((a) => ({ continuation: a }))
									]}
									active={0}
									revealed={Math.floor((frame - showAt) * 3)}
									hint="Tab = accept"
									info={`${v.osName} · ${v.app}`}
									opacity={Math.min(1, (frame - showAt) / 5)}
								/>
							) : null
						}
					/>
				</OsWindow>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 250,
					top: 230,
					display: 'flex',
					gap: 14,
					fontSize: 28,
					fontWeight: 700,
					opacity: enter * (1 - leave)
				}}
			>
				<span
					style={{
						color: 'var(--accent-blue)',
						textTransform: 'uppercase',
						letterSpacing: '0.1em'
					}}
				>
					{v.osName}
				</span>
				<span style={{ color: 'var(--ink-soft)' }}>· {v.app}</span>
			</div>
			<KeySounds keys={typing.keys} />
			<Sfx name="chime" at={showAt} volume={0.12} />
			<Sfx name="thock" at={acceptAt} volume={0.4} />
		</AbsoluteFill>
	);
};

export const AiEverywhere: React.FC = () => (
	<AbsoluteFill>
		<div style={{ position: 'absolute', left: 120, top: 70 }}>
			<Caption chapter="AI" icon="✨" title="Every app. Every system." size={70} />
		</div>
		{VIGNETTES.map((v, i) => (
			<Sequence key={v.app} from={20 + i * VIGNETTE} durationInFrames={VIGNETTE} layout="none">
				<Clip v={v} index={i} />
			</Sequence>
		))}
	</AbsoluteFill>
);
