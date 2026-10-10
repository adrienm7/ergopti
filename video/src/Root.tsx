// video/src/Root.tsx
//
// Registers the full film and one composition per feature scene. A feature
// composition renders the same component as the film, so a README GIF can
// never drift from the matching part of the video.

import React from 'react';
import { Composition, Folder } from 'remotion';
import { FPS, TIMELINE } from './lib/data';
import { Promo, promoDuration } from './Promo';
import { SceneFrame } from './SceneFrame';
import { SCENES } from './scenes';
import { REAL_LEAD_FRAMES, realClipFrames } from './scenes/Real';

const WIDTH = 1920;
const HEIGHT = 1080;

for (const scene of TIMELINE.scenes) {
	if (!SCENES[scene.id]) throw new Error(`timeline.json lists "${scene.id}" but no scene draws it`);
}
const realScene = TIMELINE.scenes.find((scene) => scene.id === 'real');
if (realScene && realScene.seconds * FPS < REAL_LEAD_FRAMES + realClipFrames(FPS)) {
	throw new Error(
		`timeline.json gives the real scene ${realScene.seconds} s, shorter than its recorded clips`
	);
}

export const Root: React.FC = () => (
	<>
		<Composition
			id="Promo"
			component={Promo}
			durationInFrames={promoDuration()}
			fps={FPS}
			width={WIDTH}
			height={HEIGHT}
		/>
		<Folder name="Scenes">
			{TIMELINE.scenes.map((scene) => (
				<Composition
					key={scene.id}
					id={`Scene-${scene.id}`}
					component={SceneFrame}
					defaultProps={{ id: scene.id, audio: true }}
					durationInFrames={Math.round(scene.seconds * FPS)}
					fps={FPS}
					width={WIDTH}
					height={HEIGHT}
				/>
			))}
		</Folder>
	</>
);
