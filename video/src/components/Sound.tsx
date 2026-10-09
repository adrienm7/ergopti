// video/src/components/Sound.tsx
//
// Audio placed in the film: the soundtrack and short interface sounds, all
// synthesised by scripts/make-audio.mjs into public/audio/ so the film needs
// no licensed asset.

import React from 'react';
import { Audio, Sequence, staticFile } from 'remotion';

export type SfxName = 'key' | 'pop' | 'whoosh' | 'thock' | 'chime';

const VOLUME: Record<SfxName, number> = {
	key: 0.22,
	pop: 0.5,
	whoosh: 0.35,
	thock: 0.6,
	chime: 0.45
};

/** One interface sound at a frame. */
export const Sfx: React.FC<{ name: SfxName; at: number; volume?: number }> = ({
	name,
	at,
	volume
}) => (
	<Sequence from={Math.round(at)} durationInFrames={45} layout="none">
		<Audio src={staticFile(`audio/${name}.wav`)} volume={volume ?? VOLUME[name]} />
	</Sequence>
);

/**
 * Key clicks for a typing burst, thinned so a fast burst does not stack
 * dozens of audio tracks.
 */
export const KeySounds: React.FC<{ keys: number[] }> = ({ keys }) => (
	<>
		{keys
			.filter((k, i) => i === 0 || k - keys[i - 1] >= 2)
			.map((k, i) => (
				<Sfx key={i} name="key" at={k} volume={VOLUME.key * (0.75 + ((i * 37) % 10) / 40)} />
			))}
	</>
);

export const Soundtrack: React.FC = () => (
	<Audio src={staticFile('audio/soundtrack.wav')} volume={0.55} />
);
