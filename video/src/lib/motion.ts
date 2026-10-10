// video/src/lib/motion.ts
//
// The few motion primitives every scene shares, so timing feels like one
// film. The easing matches the sales page's --ease-out token.

import { Easing, interpolate, spring } from 'remotion';

export const EASE_OUT = Easing.bezier(0.16, 1, 0.3, 1);

/**
 * 0 → 1 progress between two frames with the shared easing.
 * @param frame - Current frame.
 * @param start - First frame of the move.
 * @param duration - Length of the move in frames.
 */
export function progress(frame: number, start: number, duration: number): number {
	return interpolate(frame, [start, start + duration], [0, 1], {
		easing: EASE_OUT,
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp'
	});
}

/**
 * A soft spring entrance starting at a frame.
 * @param frame - Current frame.
 * @param fps - Composition frame rate.
 * @param delay - Frame the spring starts at.
 */
export function pop(frame: number, fps: number, delay = 0): number {
	return spring({ frame: frame - delay, fps, config: { damping: 14, stiffness: 120, mass: 0.7 } });
}

/**
 * Style for an element rising and fading in.
 * @param p - Progress from 0 to 1.
 * @param distance - Travel in pixels.
 */
export function rise(p: number, distance = 40): React.CSSProperties {
	return { opacity: p, transform: `translateY(${(1 - p) * distance}px)` };
}

/**
 * Fade-out progress over the last frames of a scene (1 → 0).
 * @param frame - Current frame.
 * @param total - Scene length in frames.
 * @param duration - Fade length in frames.
 */
export function outro(frame: number, total: number, duration = 12): number {
	return interpolate(frame, [total - duration, total], [1, 0], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp'
	});
}
