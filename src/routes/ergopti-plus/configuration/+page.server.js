// src/routes/ergopti-plus/configuration/+page.server.js

/** Ergopti+ Configuration: only the summaries its sections show (site-data.server.js). */
import { configurationData } from '../site-data.server.js';

export function load() {
	return configurationData();
}
