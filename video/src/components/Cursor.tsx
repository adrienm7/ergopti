// video/src/components/Cursor.tsx
//
// A mouse pointer that travels between waypoints and shows a ripple when it
// clicks. Positions are in the coordinates of its positioned parent.

import React from 'react';
import { interpolate } from 'remotion';
import { EASE_OUT } from '../lib/motion';

export type Waypoint = { frame: number; x: number; y: number; click?: boolean };

/** Frames a ripple stays visible after a click. */
const RIPPLE_FRAMES = 14;

/**
 * Where the pointer is at a frame: it eases from one waypoint to the next and
 * rests on each until the next one starts.
 * @param waypoints - Sorted by frame.
 * @param frame - Current frame.
 * @param travel - Frames a move takes.
 */
export function cursorAt(
	waypoints: Waypoint[],
	frame: number,
	travel = 14
): { x: number; y: number } {
	if (waypoints.length === 0) throw new Error('A cursor needs at least one waypoint');
	let previous = waypoints[0];
	for (const point of waypoints.slice(1)) {
		if (frame < point.frame - travel) break;
		if (frame < point.frame) {
			const p = interpolate(frame, [point.frame - travel, point.frame], [0, 1], {
				easing: EASE_OUT
			});
			return {
				x: previous.x + (point.x - previous.x) * p,
				y: previous.y + (point.y - previous.y) * p
			};
		}
		previous = point;
	}
	return { x: previous.x, y: previous.y };
}

type Props = { waypoints: Waypoint[]; frame: number; scale?: number; opacity?: number };

export const Cursor: React.FC<Props> = ({ waypoints, frame, scale = 1, opacity = 1 }) => {
	const { x, y } = cursorAt(waypoints, frame);
	const click = waypoints.find(
		(w) => w.click && frame >= w.frame && frame < w.frame + RIPPLE_FRAMES
	);
	const age = click ? frame - click.frame : 0;
	const pressed = click && age < 4 ? 0.85 : 1;
	return (
		<div
			style={{ position: 'absolute', left: x, top: y, pointerEvents: 'none', opacity, zIndex: 50 }}
		>
			{click ? (
				<div
					style={{
						position: 'absolute',
						left: -28 * scale,
						top: -28 * scale,
						width: 56 * scale,
						height: 56 * scale,
						borderRadius: '50%',
						border: `${3 * scale}px solid rgba(49,190,255,${1 - age / RIPPLE_FRAMES})`,
						transform: `scale(${0.3 + (age / RIPPLE_FRAMES) * 1.1})`
					}}
				/>
			) : null}
			<svg
				width={28 * scale}
				height={40 * scale}
				viewBox="0 0 28 40"
				style={{
					transform: `scale(${pressed})`,
					transformOrigin: 'top left',
					filter: 'drop-shadow(0 3px 6px rgba(0,0,0,0.5))'
				}}
			>
				<path
					d="M2 2 L2 32 L10 25 L15 37 L20 35 L15 23 L26 23 Z"
					fill="#fff"
					stroke="#111"
					strokeWidth="2"
				/>
			</svg>
		</div>
	);
};
