// src/routes/ergopti-plus/fonctionnalites/+page.server.js

/** Ergopti+ Fonctionnalités: only the summaries its sections show (site-data.server.js). */
import { featuresData } from '../site-data.server.js';

export function load() {
	return featuresData();
}
