// video/src/scenes/AiLocal.tsx
//
// Where the model runs: local engines first, the real model browser fed with
// the driver's catalogue, remote providers as an option.

import React from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { Caption } from '../components/Caption';
import { DriverWindow } from '../components/DriverWindow';
import { Pill } from '../components/Keycap';
import { FACTS } from '../lib/data';
import { pop } from '../lib/motion';

export const AiLocal: React.FC = () => {
	const frame = useCurrentFrame();
	const { fps } = useVideoConfig();
	const win = pop(frame, fps, 4);
	const chips = [
		{ text: '🦙 Ollama · Windows, macOS, Linux', at: 30 },
		{ text: '⚡ MLX · Apple Silicon', at: 40 },
		{ text: `☁ Or ${FACTS.apiProviders} APIs: Cerebras, OpenAI…`, at: 50 },
		{ text: '✈ Local models work offline', at: 60 }
	];
	return (
		<AbsoluteFill>
			<div style={{ position: 'absolute', left: 120, top: 120, width: 720 }}>
				<Caption
					chapter="AI"
					icon="✨"
					title="Local models, or the API you choose."
					sub={`${FACTS.aiModels} open models from ${FACTS.aiModelProviders} labs to run on your machine, with the RAM each needs shown before download.`}
					size={64}
				/>
				<div
					style={{
						display: 'flex',
						flexDirection: 'column',
						gap: 16,
						marginTop: 50,
						alignItems: 'flex-start'
					}}
				>
					{chips.map((c) => {
						const p = pop(frame, fps, c.at);
						return (
							<Pill
								key={c.text}
								style={{
									opacity: Math.min(1, p),
									transform: `translateX(${(1 - Math.min(1, p)) * -40}px)`,
									fontSize: 26
								}}
							>
								{c.text}
							</Pill>
						);
					})}
				</div>
			</div>
			<div
				style={{
					position: 'absolute',
					left: 900,
					top: 150,
					opacity: Math.min(1, win),
					transform: `perspective(1800px) rotateY(${(1 - Math.min(1, win)) * -20 - 4}deg)`
				}}
			>
				<DriverWindow id="model_browser" title="Model catalogue" scale={0.98} />
			</div>
		</AbsoluteFill>
	);
};
