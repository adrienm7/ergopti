// Liste des balises à exclure de la transformation typographique
const excludedTags = [
	'html',
	'head',
	'style',
	'title',
	'link',
	'meta',
	'script',
	'object',
	'iframe',
	'pre',
	'code',
	'textarea',
	'noscript',
	'bloc-clavier',
	'kbd',
	'kbd-sortie',
	'kbd-non'
];

// Liste des balises en ligne à traiter de manière spécifique pour créer des spans nowrap pour la ponctuation
const inlineTags = ['kbd', 'kbd-sortie', 'kbd-non', 'nom-hypertexte', 'nom-hypertexte-plus'];

// Expressions régulières pour traiter les espaces, les apostrophes et la ponctuation
const spaceRegex = /(\u00AB)(?:\s+)?|(?:\s+)?([\?!;\u00BB])/g;
const apostropheRegex = /'/g;
const punctuationRegex = /^[\.,;:!?)]/; // Expression régulière pour la ponctuation

// Élément HTML pour représenter un espace insécable
const espaceInsecable = '<span class="insecable" style="font-size: 0.67em">&nbsp;</span>';

// Fonction principale pour appliquer la typographie
export function typography(searchNode = document.body) {
	const nodes = searchNode instanceof NodeList ? searchNode : searchNode.childNodes; // Vérification du type de nœud
	nodes.forEach((node) => {
		if (node.nodeType === 3 && node.nodeValue.trim() !== '') {
			// Vérification si le nœud est un nœud de texte non vide
			enhanceTypography(node); // Traitement du nœud de texte
		} else if (node.nodeType === 1) {
			// Vérification si le nœud est un élément

			// Vérification si le nœud, ou ses enfants, ne contiennent pas les classes 'nowrap' ou 'insecable', pour éviter des [espace][espace]? infinis
			if (!containsNoWrapOrInsecable(node)) {
				if (inlineTags.includes(node.tagName.toLowerCase())) {
					// Traitement spécifique pour les balises en ligne
					handleInlineBlockPunctuation(node);
				}
				if (!excludedTags.includes(node.tagName.toLowerCase())) {
					// Vérification si la balise n'est pas exclue
					typography(node); // Appel récursif pour traiter les enfants de ce nœud
				}
			}
		}
	});
}

// Fonction pour vérifier si un nœud ou ses enfants contiennent les classes 'nowrap' ou 'insecable'
const containsNoWrapOrInsecable = (node) => {
	if (
		node.classList &&
		(node.classList.contains('nowrap') || node.classList.contains('insecable'))
	) {
		return true;
	}
	// Parcourt les enfants de manière récursive pour vérifier si l'un des enfants contient les classes
	return Array.from(node.childNodes).some((child) => containsNoWrapOrInsecable(child));
};

// Fonction pour traiter les nœuds de texte
const enhanceTypography = (node) => {
	const newText = node.nodeValue
		.replace(apostropheRegex, '’')
		.replace(spaceRegex, `$1${espaceInsecable}$2`);
	const newElement = document.createElement('span'); // Création d'un nouvel élément span pour le texte modifié
	newElement.innerHTML = newText; // Ajout du texte modifié
	node.parentNode.replaceChild(newElement, node); // Remplacement du nœud de texte par le nouvel élément
};

// Fonction pour gérer la ponctuation associée aux balises en ligne
const handleInlineBlockPunctuation = (node) => {
	let nextSibling = node.nextSibling; // Récupération du nœud suivant

	// Ignore les nœuds de commentaire
	while (nextSibling && nextSibling.nodeType === 8) {
		// 8 correspond à un nœud de commentaire
		nextSibling = nextSibling.nextSibling; // Passer au nœud suivant
	}

	if (nextSibling) {
		let fullText;
		if (nextSibling.nodeType === 3) {
			// Vérification si le nœud suivant est un nœud de texte
			fullText = nextSibling.nodeValue; // Obtenez le texte du nœud de texte
		} else if (nextSibling.nodeType === 1) {
			// Si le nœud suivant est un élément, obtenir le texte complet
			fullText = Array.from(nextSibling.childNodes)
				.map((child) => (child.nodeType === 3 ? child.nodeValue : child.textContent))
				.join('');
		}

		const match = fullText.match(punctuationRegex); // Recherche de la ponctuation dans le texte complet
		if (match) {
			const newElement = document.createElement('span'); // Création d'un nouvel élément span pour contenir le nœud actuel et la ponctuation
			newElement.classList.add('nowrap'); // Ajout de la classe 'nowrap' pour éviter les sauts de ligne
			newElement.appendChild(node.cloneNode(true)); // Ajout du nœud actuel
			newElement.innerHTML += match[0]; // Ajout de la ponctuation

			// Mise à jour du texte du nœud suivant pour enlever la ponctuation
			if (nextSibling.nodeType === 3) {
				nextSibling.nodeValue = fullText.slice(match[0].length); // Mise à jour pour un nœud de texte
			} else {
				nextSibling.childNodes.forEach((child) => {
					if (child.nodeType === 3) {
						child.nodeValue = child.nodeValue.replace(fullText, ''); // Supprime le texte du nœud de texte
					} else {
						child.remove(); // Retire les nœuds d'éléments
					}
				});
			}
			node.parentNode.replaceChild(newElement, node); // Remplacement du nœud actuel par le nouvel élément
		}
	}
};
