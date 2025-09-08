export async function getKeyboardData(version) {
	try {
		const fileName = `ergopti_v${version}`;
		// Retrieve layout data from the static folder
		const response = await fetch(`/dispositions/data/${fileName}.json`);
		if (!response.ok) {
			throw new Error('Erreur lors du chargement du fichier JSON');
		}
		const data = await response.json(); // Parse JSON data
		console.log(`Données de la disposition ${fileName} chargées :`, data);
		return data;
	} catch (error) {
		console.error(`Erreur lors du chargement des données de la disposition ${fileName} :`, error);
	}
}
