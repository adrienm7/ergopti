// src/routes/ergopti-plus/hotstrings/+page.server.js

/** Ergopti+ Hotstrings: only the summaries its sections show (site-data.server.js). */
import { hotstringsData } from '../site-data.server.js';

export function load() {
	return hotstringsData();
}
