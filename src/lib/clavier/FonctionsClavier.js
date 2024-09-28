import { version } from '$lib/stores_infos.js';
let versionValue;
version.subscribe((value) => {
	versionValue = value;
});

import data from '$lib/clavier/data/hypertexte_v1.0.19.json';
import * as data_clavier from '$lib/clavier/stores.js';

let claviersStores = {};
for (const clavier in Object.keys(data_clavier)) {
	claviersStores[clavier] = data_clavier[clavier];
}

let infos_clavier;

export function majClavier(clavier) {
	data_clavier[clavier].subscribe((value) => {
		infos_clavier = value;
	});
	majTouches();
	activerModificateurs();

	document.getElementById(infos_clavier.emplacement).dataset['type'] = infos_clavier.type;
	document.getElementById(infos_clavier.emplacement).dataset['couche'] = infos_clavier.couche;
	document.getElementById(infos_clavier.emplacement).dataset['plus'] = infos_clavier.plus;
	document.getElementById(infos_clavier.emplacement).dataset['couleur'] = infos_clavier.couleur;

	if (infos_clavier.controles === 'oui') {
		ajouterBoutonsChangerCouche(clavier, infos_clavier);
	}
}

function majTouches() {
	for (let ligne = 1; ligne <= 7; ligne++) {
		for (let j = 0; j <= 15; j++) {
			// Récupération de ce qui doit être affiché sur la touche
			const res = data[infos_clavier.type].find((el) => el['ligne'] == ligne && el['colonne'] == j);

			let colonne = j;

			// Interversion de É et de ★ sur les claviers ISO
			// if (res !== undefined) {
			// 	if ((infos_clavier.type === 'iso') && (infos_clavier.plus === 'oui') && (res.touche === 'é')) {
			// 		colonne = j + 1;
			// 	} else if ((infos_clavier.type === 'iso') && (infos_clavier.plus === 'oui') && (res.touche === 'magique')) {
			// 		colonne = j - 1;
			// 	}
			// }

			// Suppression des event listeners sur la touche
			const toucheClavier0 = document
				.getElementById(infos_clavier.emplacement)
				.querySelector("bloc-touche[data-ligne='" + ligne + "'][data-colonne='" + colonne + "']");
			const toucheClavier = toucheClavier0.cloneNode(true);
			toucheClavier0.parentNode.replaceChild(toucheClavier, toucheClavier0);

			// Nettoyage des attributs de la touche
			const attributes = toucheClavier.getAttributeNames();
			const attributesToKeep = ['data-ligne', 'data-colonne'];
			attributes.forEach((attribute) => {
				if (attribute.startsWith('data-') && !attributesToKeep.includes(attribute)) {
					toucheClavier.removeAttribute(attribute);
				}
			});
			toucheClavier.dataset['touche'] = ''; // Suppression du contenu de la touche
			toucheClavier.classList.remove('touche-active'); // Suppression de la classe css pour les touches pressées
			toucheClavier.dataset['plus'] = 'non';

			if (res !== undefined) {
				const contenuTouche = data.touches.find((el) => el['touche'] === res['touche']);

				if (contenuTouche[infos_clavier.couche] === '') {
					toucheClavier.innerHTML = '<div> <div>';
				} else {
					if (infos_clavier.couche === 'Visuel') {
						if (contenuTouche['type'] === 'double') {
							if (res['touche'] === '"') {
								// Cas particulier de la touche « " »
								toucheClavier.innerHTML =
									'<div>' + contenuTouche['Shift'] + '<br/>' + contenuTouche['Primary'] + '</div>';
							} else {
								// Toutes les autres touches "doubles"
								toucheClavier.innerHTML =
									'<div>' + contenuTouche['AltGr'] + '<br/>' + contenuTouche['Primary'] + '</div>';
								if (contenuTouche['Primary' + '+'] !== undefined && ligne < 6) {
									// Si la couche + existe ET n’est pas en thumb cluster
									toucheClavier.dataset['plus'] = 'oui';
								}
							}
						} else {
							// Cas où la touche n’est pas double
							if (infos_clavier.plus === 'oui') {
								// Cas où la touche n’est pas double et + est activé
								if (contenuTouche['Primary' + '+'] !== undefined && ligne < 6) {
									// Si la couche + existe ET n’est pas en thumb cluster
									toucheClavier.innerHTML = '<div>' + contenuTouche['Primary' + '+'] + '</div>';
									toucheClavier.dataset['plus'] = 'oui';
								} else {
									toucheClavier.innerHTML = '<div>' + contenuTouche['Primary'] + '</div>';
								}
							} else {
								toucheClavier.innerHTML = '<div>' + contenuTouche['Primary'] + '</div>';
							}
						}
					} else {
						// Toutes les couches autres que "Visuel"
						if (infos_clavier.plus === 'oui') {
							if (contenuTouche[infos_clavier.couche + '+'] !== undefined) {
								toucheClavier.innerHTML =
									'<div>' + contenuTouche[infos_clavier.couche + '+'] + '</div>';
								toucheClavier.dataset.plus = 'oui';
							} else {
								toucheClavier.innerHTML = '<div>' + contenuTouche[infos_clavier.couche] + '</div>';
							}
						} else {
							toucheClavier.innerHTML = '<div>' + contenuTouche[infos_clavier.couche] + '</div>';
						}
					}
				}

				// Corrections localisées
				if (infos_clavier.type === 'ergodox' && res.touche === 'Space') {
					toucheClavier.innerHTML = '<div>␣</div>';
				}
				if (
					infos_clavier.type === 'iso' &&
					res.touche === 'Space' &&
					infos_clavier.couche === 'Visuel'
					// infos_clavier.plus === 'non'
				) {
					toucheClavier.innerHTML = '<div>HyperTexte v.' + versionValue + '</div>';
				}
				// if (
				// 	infos_clavier.type === 'iso' &&
				// 	res.touche === 'Space' &&
				// 	infos_clavier.couche === 'Visuel' &&
				// 	infos_clavier.plus === 'oui'
				// ) {
				// 	toucheClavier.innerHTML =
				// 		"<div>Layer de navigation<br><span class='tap'>HyperTexte v." +
				// 		versionValue +
				// 		'</span></div>';
				// }

				// On ajoute des infos_clavier dans les data attributes de la touche
				toucheClavier.dataset['touche'] = res['touche'];
				toucheClavier.dataset['colonne'] = colonne;
				toucheClavier.dataset['doigt'] = res['doigt'];
				toucheClavier.dataset['main'] = res['main'];
				toucheClavier.dataset['type'] = contenuTouche['type'];
				toucheClavier.style.setProperty('--taille', res['taille']);
				toucheClavier.style.setProperty('--frequence', mayzner[res['touche']] / mayzner['max']);
				toucheClavier.style.setProperty(
					'--frequence-log',
					Math.log(mayzner[res.touche] / mayzner['max'])
				);
			}
		}
	}
}

function activerModificateurs() {
	let lShift = document
		.getElementById(infos_clavier.emplacement)
		.querySelector("[data-touche='LShift']");
	let rShift = document
		.getElementById(infos_clavier.emplacement)
		.querySelector("[data-touche='RShift']");
	let lCtrl = document
		.getElementById(infos_clavier.emplacement)
		.querySelector("[data-touche='LCtrl']");
	let rCtrl = document
		.getElementById(infos_clavier.emplacement)
		.querySelector("[data-touche='RCtrl']");
	let altGr = document
		.getElementById(infos_clavier.emplacement)
		.querySelector("[data-touche='RAlt']");
	let aGrave = document
		.getElementById(infos_clavier.emplacement)
		.querySelector("[data-touche='à']");
	let virgule = document
		.getElementById(infos_clavier.emplacement)
		.querySelector("[data-touche=',']");
	let lalt = document
		.getElementById(infos_clavier.emplacement)
		.querySelector("[data-touche='LAlt']");
	let space = document
		.getElementById(infos_clavier.emplacement)
		.querySelector("[data-touche='Space']");

	if (infos_clavier.couche === 'Shift' && lShift !== null) {
		lShift.classList.add('touche-active');
	}
	if (infos_clavier.couche === 'Shift' && rShift !== null) {
		rShift.classList.add('touche-active');
	}
	if (infos_clavier.couche === 'Ctrl' && lCtrl !== null) {
		lCtrl.classList.add('touche-active');
	}
	if (infos_clavier.couche === 'Ctrl' && rCtrl !== null) {
		rCtrl.classList.add('touche-active');
	}
	if (infos_clavier.couche === 'AltGr' && altGr !== null) {
		altGr.classList.add('touche-active');
	}
	if (infos_clavier.couche === 'ShiftAltGr' && lShift !== null) {
		lShift.classList.add('touche-active');
	}
	if (infos_clavier.couche === 'ShiftAltGr' && rShift !== null) {
		rShift.classList.add('touche-active');
	}
	if (infos_clavier.couche === 'ShiftAltGr' && altGr !== null) {
		altGr.classList.add('touche-active');
	}
	if (infos_clavier.couche === 'À' && aGrave !== null) {
		aGrave.classList.add('touche-active');
	}
	if (infos_clavier.couche === ',' && virgule !== null) {
		virgule.classList.add('touche-active');
	}
	if (infos_clavier.couche === 'Layer' && rCtrl !== null && infos_clavier.type === 'iso') {
		rCtrl.classList.add('touche-active');
	}
	if (infos_clavier.couche === 'Layer' && space !== null && infos_clavier.type === 'ergodox') {
		space.classList.add('touche-active');
	}
}

function ajouterBoutonsChangerCouche(clavier, infos_clavier) {
	let emplacementClavier = document.getElementById(infos_clavier.emplacement);
	let toucheRAlt = emplacementClavier.querySelector("bloc-touche[data-touche='RAlt']");
	let toucheLShift = emplacementClavier.querySelector("bloc-touche[data-touche='LShift']");
	let toucheRShift = emplacementClavier.querySelector("bloc-touche[data-touche='RShift']");
	let toucheLCtrl = emplacementClavier.querySelector("bloc-touche[data-touche='LCtrl']");
	let toucheRCtrl = emplacementClavier.querySelector("bloc-touche[data-touche='RCtrl']");
	let toucheLalt = emplacementClavier.querySelector("bloc-touche[data-touche='LAlt']");
	let toucheA = emplacementClavier.querySelector("bloc-touche[data-touche='à']");
	let toucheVirgule = emplacementClavier.querySelector("bloc-touche[data-touche=',']");
	let toucheEspace = emplacementClavier.querySelector("bloc-touche[data-touche='Space']");

	// On ajoute une action au clic sur chacune des touches modificatrices
	for (let toucheModificatrice of [
		toucheRAlt,
		toucheLShift,
		toucheRShift,
		toucheLCtrl,
		toucheRCtrl
	]) {
		if (toucheModificatrice !== null) {
			toucheModificatrice.addEventListener(
				'click',
				function () {
					changerCouche(toucheModificatrice, clavier, infos_clavier);
				},
				{ passive: true }
			);
		}
	}

	// Les boutons de touches modificatrices À et Space ne sont ajoutées que si + est activé
	if (infos_clavier.plus === 'oui') {
		for (let toucheModificatrice of [toucheLalt, toucheA, toucheVirgule, toucheEspace]) {
			if (toucheModificatrice !== null) {
				toucheModificatrice.addEventListener('click', function () {
					changerCouche(toucheModificatrice, clavier, infos_clavier);
				});
			}
		}
	}
}

function changerCouche(toucheModificatrice, clavier, infos_clavier) {
	let touchePressee = toucheModificatrice.dataset.touche;
	let coucheActuelle = document.getElementById(infos_clavier.emplacement).dataset.couche;
	let nouvelleCouche = coucheActuelle;

	// Touche pressée = AltGr
	if (touchePressee === 'RAlt' && coucheActuelle === 'AltGr') {
		nouvelleCouche = 'Visuel';
	} else if (touchePressee === 'RAlt' && coucheActuelle === 'Shift') {
		nouvelleCouche = 'ShiftAltGr';
	} else if (touchePressee === 'RAlt' && coucheActuelle === 'ShiftAltGr') {
		nouvelleCouche = 'Shift';
	} else if (touchePressee === 'RAlt') {
		nouvelleCouche = 'AltGr';
	}

	// Touche pressée = Shift
	if ((touchePressee === 'LShift' || touchePressee === 'RShift') & (coucheActuelle === 'AltGr')) {
		nouvelleCouche = 'ShiftAltGr';
	} else if (
		(touchePressee === 'LShift' || touchePressee === 'RShift') &
		(coucheActuelle === 'Shift')
	) {
		nouvelleCouche = 'Visuel';
	} else if (
		(touchePressee === 'LShift' || touchePressee === 'RShift') &
		(coucheActuelle === 'ShiftAltGr')
	) {
		nouvelleCouche = 'AltGr';
	} else if (
		(touchePressee === 'LShift' || touchePressee === 'RShift') &
		((coucheActuelle === 'À') | (coucheActuelle === ','))
	) {
		nouvelleCouche = 'Shift';
	} else if (touchePressee === 'LShift' || touchePressee === 'RShift') {
		nouvelleCouche = 'Shift';
	}

	// Touche pressée = Ctrl
	if ((touchePressee === 'LCtrl' || touchePressee === 'RCtrl') && coucheActuelle !== 'Ctrl') {
		nouvelleCouche = 'Ctrl';
	} else if (touchePressee === 'LCtrl' || touchePressee === 'RCtrl') {
		nouvelleCouche = 'Visuel';
	}

	// Touche pressée = RCtrl (pour accéder au Layer)
	if (
		((touchePressee === 'RCtrl') & (infos_clavier.type === 'iso')) |
			((touchePressee === 'Space') & (infos_clavier.type === 'ergodox')) &&
		infos_clavier.plus === 'oui' &&
		coucheActuelle === 'Layer'
	) {
		nouvelleCouche = 'Visuel';
	} else if (
		((touchePressee === 'RCtrl') & (infos_clavier.type === 'iso')) |
			((touchePressee === 'Space') & (infos_clavier.type === 'ergodox')) &&
		infos_clavier.plus === 'oui'
	) {
		nouvelleCouche = 'Layer';
	}

	// Touche pressée = À
	if (touchePressee === 'à' && coucheActuelle === 'À') {
		nouvelleCouche = 'Visuel';
	} else if (touchePressee === 'à') {
		nouvelleCouche = 'À';
	}

	// Touche pressée = ,
	if (touchePressee === ',' && coucheActuelle === ',') {
		nouvelleCouche = 'Visuel';
	} else if (touchePressee === ',') {
		nouvelleCouche = ',';
	}

	// Une fois que la nouvelle couche est déterminée, on actualise la valeur de la couche, puis le clavier
	data_clavier[clavier].update((currentData) => {
		currentData['couche'] = nouvelleCouche;
		return currentData;
	});

	majClavier(clavier);
}

const mayzner = {
	max: 12.49,
	a: 8.04,
	b: 1.48,
	c: 3.34,
	d: 3.82,
	e: 12.49,
	f: 2.4,
	g: 1.87,
	h: 5.05,
	i: 7.57,
	j: 0.16,
	k: 0.54,
	l: 4.07,
	m: 2.51,
	n: 7.23,
	o: 7.64,
	p: 2.14,
	q: 0.12,
	r: 6.28,
	s: 6.51,
	t: 9.28,
	u: 2.73,
	v: 1.05,
	w: 1.68,
	x: 0.23,
	y: 1.66,
	z: 0.09
};
