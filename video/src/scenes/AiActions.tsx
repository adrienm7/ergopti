// video/src/scenes/AiActions.tsx
//
// AI actions on a selection: the picker's real action labels light up in
// turn while the selected sentence is rewritten.

import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame } from 'remotion';
import { Caption } from '../components/Caption';
import { OsWindow } from '../components/OsWindow';
import { Sfx } from '../components/Sound';
import { actionLabel } from '../lib/data';
import { progress } from '../lib/motion';

const ORIGINAL = 'hey, can u send me the report by friday?';
const STEPS = [
	{ action: 'llm_tone_more_formal', text: 'Could you please send me the report by Friday?' },
	{
		action: 'llm_translate_selection',
		text: 'Pourriez-vous m’envoyer le rapport d’ici vendredi ?'
	},
	{ action: 'llm_tone_more_familiar', text: 'Hey! Mind sending me the report by Friday?' }
];
const FIRST = 40;
const EVERY = 55;

export const AiActions: React.FC = () => {
	const frame = useCurrentFrame();
	const index = Math.floor((frame - FIRST) / EVERY);
	const current = index >= 0 ? STEPS[Math.min(index, STEPS.length - 1)] : null;
	const since = index >= 0 ? frame - FIRST - Math.min(index, STEPS.length - 1) * EVERY : 0;
	const morph = current
		? progress(frame, FIRST + Math.min(index, STEPS.length - 1) * EVERY, 14)
		: 0;
	const text = current ? current.text : ORIGINAL;
	const extras = ['llm_screen_region', 'llm_screen_error', 'llm_agent_command'];
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 110, width: 1300 }}>
				<Caption
					chapter="AI"
					icon="🤖"
					title="Rewrite, translate, ask."
					sub="Select text, press a key: a more formal tone, another language, an answer about your screen."
					size={66}
				/>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 120,
					top: 470,
					display: 'flex',
					flexDirection: 'column',
					gap: 16,
					width: 620
				}}
			>
				{[...STEPS.map((s) => s.action), ...extras].map((id) => {
					const on = current?.action === id && since < EVERY;
					return (
						<div
							key={id}
							style={{
								fontSize: 30,
								padding: '14px 22px',
								borderRadius: 14,
								border: `1px solid ${on ? 'var(--family-ia)' : 'var(--border)'}`,
								background: on
									? 'color-mix(in srgb, var(--family-ia) 22%, transparent)'
									: 'var(--surface)',
								color: on ? '#fff' : 'var(--ink-soft)',
								transform: `scale(${on ? 1.03 : 1})`
							}}
						>
							{actionLabel(id)}
						</div>
					);
				})}
			</div>
			<div style={{ position: 'absolute', left: 820, top: 470 }}>
				<OsWindow
					os="macos"
					title="Slack — #team"
					width={980}
					height={420}
					bodyStyle={{ padding: '60px 50px', display: 'flex', alignItems: 'center' }}
				>
					<span
						style={{
							fontSize: 46,
							lineHeight: 1.35,
							color: '#fff',
							background: 'rgba(49,190,255,0.32)',
							borderRadius: 8,
							padding: '2px 6px',
							filter: `blur(${(1 - morph) * (current ? 6 : 0)}px)`,
							opacity: current ? interpolate(morph, [0, 1], [0.3, 1]) : 1
						}}
					>
						{text}
					</span>
				</OsWindow>
			</div>
			{STEPS.map((_, i) => (
				<Sfx key={i} name="whoosh" at={FIRST + i * EVERY} volume={0.25} />
			))}
		</AbsoluteFill>
	);
};
