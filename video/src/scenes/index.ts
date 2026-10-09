// video/src/scenes/index.ts
//
// Scene id → component. Order, length and GIF eligibility live in
// src/data/timeline.json; this map only says which component draws a scene.

import type React from 'react';
import { AiActions } from './AiActions';
import { AiEverywhere } from './AiEverywhere';
import { AiLocal } from './AiLocal';
import { AiPredictions } from './AiPredictions';
import { ExtremeHotstrings } from './ExtremeHotstrings';
import { Gestures } from './Gestures';
import { Hook } from './Hook';
import { Menu } from './Menu';
import { Metrics } from './Metrics';
import { NavLayer } from './NavLayer';
import { Outro } from './Outro';
import { PersonalHotstrings } from './PersonalHotstrings';
import { Private } from './Private';
import { Real } from './Real';
import { ScreenTime } from './ScreenTime';
import {
	ShortcutCase,
	ShortcutColor,
	ShortcutSearch,
	ShortcutSelectLine,
	ShortcutTeleport,
	ShortcutWrap
} from './ShortcutActions';
import { ShortcutAny } from './ShortcutAny';
import { Shortcuts } from './Shortcuts';
import { TapHolds } from './TapHolds';
import { ThreeOs } from './ThreeOs';

export const SCENES: Record<string, React.FC> = {
	hook: Hook,
	menu: Menu,
	'three-os': ThreeOs,
	'extreme-hotstrings': ExtremeHotstrings,
	'personal-hotstrings': PersonalHotstrings,
	'ai-predictions': AiPredictions,
	'ai-everywhere': AiEverywhere,
	'ai-local': AiLocal,
	'ai-actions': AiActions,
	'tap-holds': TapHolds,
	'nav-layer': NavLayer,
	shortcuts: Shortcuts,
	'shortcut-teleport': ShortcutTeleport,
	'shortcut-any': ShortcutAny,
	'shortcut-select-line': ShortcutSelectLine,
	'shortcut-case': ShortcutCase,
	'shortcut-color': ShortcutColor,
	'shortcut-search': ShortcutSearch,
	'shortcut-wrap': ShortcutWrap,
	gestures: Gestures,
	metrics: Metrics,
	'screen-time': ScreenTime,
	private: Private,
	real: Real,
	outro: Outro
};
