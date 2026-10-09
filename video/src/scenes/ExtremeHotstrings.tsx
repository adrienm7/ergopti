// video/src/scenes/ExtremeHotstrings.tsx
//
// The site's best-of abbreviations (src/routes/utilisation/magic_sample.toml),
// longest output per key first, then a sentence typed with them while a
// counter compares keys struck with characters written.

import React, { useMemo } from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { OsWindow } from '../components/OsWindow';
import { KeySounds, Sfx } from '../components/Sound';
import { PredictionTooltip } from '../components/Tooltips';
import { compileTyping, TypedText, typingStats, type Step } from '../components/Typewriter';
import { BEST_OF } from '../lib/data';
import { pop } from '../lib/motion';
import { MONO } from '../styles';

const CARDS = 5;
/** Shortest output worth a card: one-word expansions say less. */
const MIN_OUTPUT = 9;
const TYPED: Step[] = [{ hotstring: 'pex★', typed: 'Pex★', end: ' tu peux écrire ' }];
/** The prediction the AI offers once typing pauses, and its alternatives. */
const PREDICTION = 'à la vitesse de l’éclair.';
const ALTERNATIVES = ['en quelques touches.', 'sans effort.'];
const AI_COLOR = 'var(--family-ia)';
const TYPE_AT = 120;

export const ExtremeHotstrings: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const cards = BEST_OF.filter((b) => [...b.output].length >= MIN_OUTPUT).slice(0, CARDS);
	// Hotstring first, then the AI completes the sentence, accepted with Tab.
	const { typing, showAt, acceptAt } = useMemo(() => {
		const first = compileTyping(TYPED, fps, TYPE_AT, 'extreme');
		const show = first.end + 12;
		const accept = show + 50;
		return {
			typing: compileTyping(
				[...TYPED, { pause: accept - first.end - 1 }, { insert: PREDICTION, color: AI_COLOR }],
				fps,
				TYPE_AT,
				'extreme'
			),
			showAt: show,
			acceptAt: accept
		};
	}, [fps]);
	const predicting = frame >= showAt && frame < acceptAt;
	const stats = typingStats(typing, frame);
	const typed = frame >= TYPE_AT;
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 90, width: 900 }}>
				<Caption
					chapter="Hotstrings"
					icon="⚡"
					title="A few keys. A whole phrase."
					sub="From the best-of list, as the driver ships it. The AI finishes the sentence."
					size={68}
				/>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 120,
					top: 400,
					display: 'flex',
					flexDirection: 'column',
					gap: 16
				}}
			>
				{cards.map((card, i) => {
					const p = Math.min(1, pop(frame, fps, 14 + i * 9));
					return (
						<div
							key={card.trigger}
							style={{
								display: 'flex',
								alignItems: 'center',
								gap: 24,
								padding: '14px 26px',
								borderRadius: 18,
								background: 'var(--surface-strong)',
								border: '1px solid var(--border)',
								opacity: p,
								transform: `translateX(${(1 - p) * -60}px)`
							}}
						>
							<span style={{ fontFamily: MONO, fontSize: 38, color: card.color, minWidth: 150 }}>
								{card.trigger}
							</span>
							<span style={{ fontSize: 30, color: 'var(--ink-faint)' }}>→</span>
							<span style={{ fontSize: 40, fontWeight: 700, flex: 1 }}>{card.output}</span>
							<span
								style={{
									fontSize: 22,
									fontWeight: 700,
									color: 'var(--accent-cyan)',
									minWidth: 70,
									textAlign: 'right'
								}}
							>
								×{card.ratio.toFixed(1)}
							</span>
						</div>
					);
				})}
			</div>
			<div style={{ position: 'absolute', left: 1020, top: 400 }}>
				<OsWindow
					os="windows"
					title="WhatsApp"
					width={720}
					height={360}
					bodyStyle={{ padding: '36px 40px' }}
				>
					<TypedText typing={typing} fontSize={34} caret={typed} />
				</OsWindow>
				{/* Under the line rather than at the caret: at the end of the line the
				    tooltip would run off the frame. */}
				{predicting ? (
					<div style={{ position: 'absolute', left: 30, top: 140 }}>
						<PredictionTooltip
							context="tu peux écrire "
							lines={[
								{ continuation: PREDICTION },
								...ALTERNATIVES.map((a) => ({ continuation: a }))
							]}
							active={0}
							revealed={Math.floor((frame - showAt) * 2.5)}
							hint="Tab = accept"
							info="AI prediction"
							opacity={Math.min(1, (frame - showAt) / 5)}
						/>
					</div>
				) : null}
			</div>
			<div
				style={{
					position: 'absolute',
					left: 1020,
					top: 800,
					display: 'flex',
					gap: 40,
					opacity: typed ? 1 : 0
				}}
			>
				{[
					// Accepting the prediction is one more key: Tab.
					{ value: stats.keys + (frame >= acceptAt ? 1 : 0), label: 'keys typed' },
					{ value: stats.chars, label: 'characters written' }
				].map((s) => (
					<div key={s.label} style={{ display: 'flex', flexDirection: 'column' }}>
						<span style={{ fontSize: 76, fontWeight: 800, fontVariantNumeric: 'tabular-nums' }}>
							{s.value}
						</span>
						<span style={{ fontSize: 24, color: 'var(--ink-soft)' }}>{s.label}</span>
					</div>
				))}
			</div>
			<KeySounds keys={typing.keys} />
			<Sfx name="chime" at={showAt} volume={0.12} />
			<Sfx name="thock" at={acceptAt} volume={0.4} />
			{typing.expansions.map((f) => (
				<Sfx key={f} name="pop" at={f} />
			))}
		</AbsoluteFill>
	);
};
