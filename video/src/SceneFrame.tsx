// video/src/SceneFrame.tsx
//
// One scene on its own stage, used by the film and by the per-feature
// compositions the README GIFs are rendered from.

import React from 'react';
import { Stage } from './components/Stage';
import { SCENES } from './scenes';

export const SceneFrame: React.FC<{ id: string; audio?: boolean }> = ({ id }) => {
	const Scene = SCENES[id];
	if (!Scene) throw new Error(`Unknown scene "${id}"`);
	return (
		<Stage>
			<Scene />
		</Stage>
	);
};
