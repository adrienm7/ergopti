// src/routes/ergopti-plus/ia/+page.server.js

/** Ergopti+ IA: only the summaries its sections show (site-data.server.js). */
import { aiData } from '../site-data.server.js';

export function load() {
	return aiData();
}
