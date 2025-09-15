export function getLatestVersion(name, versionPrefix = null) {
	const extractedVersions = getFilteredFileVersions(name, versionPrefix);
	// Trier les versions
	const sortedVersions = sortVersions(extractedVersions);
	// Retourner la dernière version (la plus élevée)
	return sortedVersions[sortedVersions.length - 1];
}

export function getFilteredFileVersions(name, versionPrefix = null) {
	let files;
	// On ne peut pas utiliser de variable path dans import.meta.glob, donc on doit utiliser des conditions

	switch (name) {
		case 'kbdedit_exe':
			files = import.meta.glob('/static/pilotes/kbdedit/*.exe');
			break;
		case 'kbdedit_kbe':
			files = import.meta.glob('/static/pilotes/kbdedit/*.kbe');
			break;
		case 'kbdedit_mac':
			files = import.meta.glob('/static/pilotes/kbdedit/*.keylayout');
			break;
		case 'ahk':
			files = import.meta.glob('/static/pilotes/ahk/*.exe');
			break;
		case 'plus':
			files = import.meta.glob('/static/pilotes/plus/*.ahk');
			break;
		case 'kla_iso':
			files = import.meta.glob('/static/layouts/iso/*.json');
			break;
		case 'kla_iso_plus':
			files = import.meta.glob('/static/layouts/iso/*+.json');
			break;
		case 'kla_ergodox':
			files = import.meta.glob('/static/layouts/ergodox/*.json');
			break;
		case 'kalamine_1dk':
			files = import.meta.glob('/static/pilotes/kalamine/1dk/*.toml');
			break;
		case 'kalamine_analyse':
			files = import.meta.glob('/static/pilotes/kalamine/standard/*_analyse.toml');
			break;
		case 'kalamine_standard':
			files = import.meta.glob('/static/pilotes/kalamine/standard/*.toml');
			files = Object.fromEntries(
				Object.entries(files).filter(([key]) => !key.endsWith('_analyse.toml'))
			);
			break;
		default:
			files = import.meta.glob('/static/layouts/ergodox/*.json'); // Valeur par défaut
			break;
	}

	// Récupérer les noms des fichiers
	const fileNames = Object.keys(files).map((filePath) => filePath.split('/').pop());

	// Extraire les versions des noms de fichiers
	const extractedVersions = extractVersions(fileNames);

	// Filtrer les versions par préfixe si spécifié
	return filterVersions(extractedVersions, versionPrefix);
}

function extractVersions(fileNames) {
	const versionPattern = /v(\d+\.\d+\.\d+)/; // Capture la version sans le 'v'
	return fileNames
		.map((file) => {
			const match = file.match(versionPattern);
			return match ? match[1] : null; // Utilise match[1] pour extraire uniquement la version sans 'v'
		})
		.filter(Boolean); // Supprime les valeurs nulles
}

function filterVersions(versions, versionPrefix) {
	if (!versionPrefix) {
		return versions; // Si le préfixe est nul, retourner toutes les versions
	}
	return versions.filter((version) => version.startsWith(versionPrefix));
}

function sortVersions(versions) {
	// Convertir les versions en tableaux de nombres pour un tri numérique
	return versions.sort((a, b) => {
		const aParts = a.split('.').map(Number);
		const bParts = b.split('.').map(Number);

		// Comparer version par version (major, minor, patch)
		for (let i = 0; i < Math.max(aParts.length, bParts.length); i++) {
			if ((aParts[i] || 0) !== (bParts[i] || 0)) {
				return (aParts[i] || 0) - (bParts[i] || 0);
			}
		}

		return 0; // Les versions sont égales
	});
}
