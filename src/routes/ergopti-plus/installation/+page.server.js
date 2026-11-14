// src/routes/ergopti-plus/installation/+page.server.js

/** Ergopti+ Installation: only the summaries its sections show (site-data.server.js). */
import { installationData } from '../site-data.server.js';

export function load() {
	return installationData();
}
