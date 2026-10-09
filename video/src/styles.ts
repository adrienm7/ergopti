// video/src/styles.ts
//
// Visual identity imported from the website instead of restated: the brand
// variables and navy gradient (global.css), the name gradient
// (ergopti_name.css) and the Ergopti+ page tokens on .ep-root
// (ergopti-plus.css). Scenes read them through var(--…) and these classes.

import { loadFont as loadMono } from '@remotion/google-fonts/FiraCode';
import { loadFont as loadSans } from '@remotion/google-fonts/NotoSans';

import '../../src/lib/css/global.css';
import '../../src/lib/css/ergopti_name.css';
import '../../src/routes/ergopti-plus/ergopti-plus.css';

export const SANS = loadSans('normal', {
	weights: ['400', '500', '600', '700', '800'],
	subsets: ['latin', 'latin-ext']
}).fontFamily;
export const MONO = loadMono('normal', {
	weights: ['400', '500'],
	subsets: ['latin', 'latin-ext']
}).fontFamily;

/** Class carrying the site's navy gradient. */
export const BG_CLASS = 'bg-blue';
/** Class scoping the Ergopti+ page tokens. */
export const TOKENS_CLASS = 'ep-root';
/** Class painting text with the Ergopti name gradient. */
export const NAME_GRADIENT_CLASS = 'namecolor';
