// video/src/Promo.tsx
//
// The full film: every scene of timeline.json not marked "film": false, in order, joined by short
// transitions, over the generated soundtrack.

import { fade } from '@remotion/transitions/fade';
import { slide } from '@remotion/transitions/slide';
import { linearTiming, TransitionSeries } from '@remotion/transitions';
import React from 'react';
import { FILM_SCENES, FPS, TIMELINE } from './lib/data';
import { SceneFrame } from './SceneFrame';
import { Soundtrack } from './components/Sound';

/** Total film length: scene lengths minus the transition overlaps. */
export function promoDuration(): number {
	const scenes = FILM_SCENES.reduce((s, sc) => s + Math.round(sc.seconds * FPS), 0);
	return scenes - (FILM_SCENES.length - 1) * TIMELINE.transitionFrames;
}

export const Promo: React.FC = () => (
	<>
		<TransitionSeries>
			{FILM_SCENES.flatMap((scene, i) => {
				const items = [
					<TransitionSeries.Sequence
						key={scene.id}
						durationInFrames={Math.round(scene.seconds * FPS)}
					>
						<SceneFrame id={scene.id} />
					</TransitionSeries.Sequence>
				];
				if (i < FILM_SCENES.length - 1) {
					items.push(
						<TransitionSeries.Transition
							key={`${scene.id}-out`}
							presentation={i % 3 === 2 ? slide({ direction: 'from-right' }) : fade()}
							timing={linearTiming({ durationInFrames: TIMELINE.transitionFrames })}
						/>
					);
				}
				return items;
			})}
		</TransitionSeries>
		<Soundtrack />
	</>
);
