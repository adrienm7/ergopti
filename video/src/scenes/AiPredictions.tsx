// video/src/scenes/AiPredictions.tsx
//
// AI prediction as the driver shows it: after the configured pause, the caret
// tooltip streams corrected endings and continuations; Tab inserts the
// highlighted one. The pause and the number of lines come from the driver's
// LLM defaults.

import React, { useMemo } from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { Keycap, Pill } from '../components/Keycap';
import { OsWindow } from '../components/OsWindow';
import { KeySounds, Sfx } from '../components/Sound';
import { PredictionTooltip, type PredictionLine } from '../components/Tooltips';
import { compileTyping, TypedText, type Step } from '../components/Typewriter';
import { FACTS } from '../lib/data';
import { progress, rise } from '../lib/motion';

const CONTEXT = 'Our new project is ';
const TYPO = 'paralel to ';
const LINES: PredictionLine[] = [
	{ correction: 'parallel to ', continuation: 'last year’s roadmap, with a bigger budget.' },
	{ correction: 'parallel to ', continuation: 'the work we shipped in the spring.' },
	{ correction: 'parallel to ', continuation: 'what the design team is exploring.' },
	{ correction: 'parallel to ', continuation: 'the migration planned for Q3.' }
];
const AI_COLOR = 'var(--family-ia)';
/** Characters streamed per frame. */
const STREAM_RATE = 2.2;

export const AiPredictions: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const lines = LINES.slice(0, FACTS.llm.numPredictions);
	const typed: Step[] = [{ type: 'Hi team,\n\n' }, { type: CONTEXT + TYPO, cps: 12 }];
	const first = useMemo(() => compileTyping(typed, fps, 24, 'ai'), [fps]);
	// The driver waits for a pause in typing before asking the model.
	const showAt = first.end + Math.round((FACTS.llm.debounceMs / 1000) * fps);
	const downAt = showAt + 70;
	const upAt = showAt + 92;
	const acceptAt = showAt + 125;
	const accepted = `${lines[0].correction}${lines[0].continuation}`;
	const typing = useMemo(
		() =>
			compileTyping(
				[
					...typed,
					{ pause: acceptAt - first.end - 1 },
					{ erase: TYPO.length },
					{ insert: accepted, color: AI_COLOR }
				],
				fps,
				24,
				'ai'
			),
		[fps]
	);
	const active = frame >= downAt && frame < upAt ? 1 : 0;
	const visible = frame >= showAt && frame < acceptAt;
	const tipOpacity = visible ? Math.min(1, (frame - showAt) / 6) : 0;
	const press = Math.max(0, 1 - Math.abs(frame - acceptAt) / 5);
	const stat = progress(frame, acceptAt + 10, 20);
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 90, width: 1100 }}>
				<Caption
					chapter="AI"
					icon="✨"
					title="An AI that writes with you."
					sub="It fixes the end of your sentence and suggests what comes next. One Tab accepts both."
					size={66}
				/>
			</div>
			<div style={{ position: 'absolute', left: 120, top: 400 }}>
				<OsWindow
					os="windows"
					title="New message — Mail"
					width={1080}
					height={560}
					bodyStyle={{ padding: '36px 44px' }}
				>
					<TypedText
						typing={typing}
						fontSize={34}
						atCaret={
							visible ? (
								<PredictionTooltip
									context={CONTEXT}
									lines={lines}
									active={active}
									revealed={Math.floor((frame - showAt) * STREAM_RATE)}
									hint="Tab = accept the fix AND the rest   ·   ↑/↓ = choose"
									info="Cerebras API · or a local Ollama model · ⏱ 0.21 s"
									opacity={tipOpacity}
								/>
							) : null
						}
					/>
				</OsWindow>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 1560,
					top: 470,
					width: 280,
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					gap: 40
				}}
			>
				<Keycap
					label="Tab ⇥"
					press={press}
					lit={Math.max(
						press,
						interpolate(frame, [acceptAt - 20, acceptAt], [0, 0.6], {
							extrapolateLeft: 'clamp',
							extrapolateRight: 'clamp'
						})
					)}
					accent="#ec407a"
					width={240}
					height={130}
					fontSize={42}
				/>
				<div
					style={{
						...rise(stat, 30),
						display: 'flex',
						flexDirection: 'column',
						alignItems: 'center',
						gap: 8
					}}
				>
					<div style={{ fontSize: 96, fontWeight: 800, color: 'var(--ink)' }}>
						{accepted.length}
					</div>
					<div style={{ fontSize: 28, color: 'var(--ink-soft)' }}>characters for 1 keystroke</div>
				</div>
				<div style={{ ...rise(stat, 20), display: 'flex', gap: 12 }}>
					<Pill style={{ fontSize: 22, padding: '10px 18px' }}>Prediction</Pill>
					<Pill style={{ fontSize: 22, padding: '10px 18px' }}>Correction</Pill>
				</div>
			</div>
			<KeySounds keys={first.keys} />
			<Sfx name="chime" at={showAt} volume={0.18} />
			<Sfx name="key" at={downAt} />
			<Sfx name="key" at={upAt} />
			<Sfx name="thock" at={acceptAt} />
			<Sfx name="pop" at={acceptAt + 2} />
		</AbsoluteFill>
	);
};
