// src/routes/ergopti-plus/+page.server.js

/** Ergopti+ overview: only the key figures of its KPI strip (site-data.server.js). */
import { overviewData } from './site-data.server.js';

export function load() {
	return overviewData();
}
