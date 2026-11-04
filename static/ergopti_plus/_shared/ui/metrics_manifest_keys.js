/**
 * _shared/ui/metrics_manifest_keys.js
 * ==============================================================================
 * MODULE: Metrics Manifest Application Keys
 * DESCRIPTION:
 * Keeps application labels distinct from reserved system rows. Shared vectors
 * pin this port to the Lua and Windows implementations.
 * ==============================================================================
 */

/** Encodes application labels without colliding with reserved system rows. */
function metricsManifestKey(name) {
	return name === '_system' || name === '_sys' || name.startsWith('~') ? `~${name}` : name;
}

/** Decodes an application key after excluding reserved system rows. */
function metricsManifestLabel(key) {
	return key.startsWith('~') ? key.slice(1) : key;
}
