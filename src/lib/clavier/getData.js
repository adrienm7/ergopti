export async function loadData(version) {
	try {
		// Utilisation de fetch pour récupérer le fichier JSON depuis le dossier static
		const response = await fetch(`/dispositions/data/hypertexte_v${version}.json`);
		if (!response.ok) {
			throw new Error('Erreur lors du chargement du fichier JSON');
		}
		const data = await response.json(); // Parse les données JSON
		console.log('Données chargées :', data);
		return data;
	} catch (error) {
		console.error('Erreur lors du chargement des données :', error);
	}
}

export function getData(versionValue) {
	loadData(versionValue)
		.then((data) => {
			return data;
		})
		.catch((error) => {
			console.error('Erreur lors du chargement des données :', error);
		});
}
