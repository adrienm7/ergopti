import * as data_clavier from '$lib/stores_infos.js';
export class Clavier {
	constructor(id, version, data) {
		this.id = id;
		this.data_clavier = data_clavier;
		data_clavier[this.id].subscribe((value) => {
			this.infos_clavier = value;
		});
		this.version = version;
		this.data = data;
	}

	majClavier() {
		this.majTouches();
		this.activerModificateurs();

		document.getElementById(this.infos_clavier.emplacement).dataset['type'] =
			this.infos_clavier.type;
		document.getElementById(this.infos_clavier.emplacement).dataset['couche'] =
			this.infos_clavier.couche;
		document.getElementById(this.infos_clavier.emplacement).dataset['plus'] =
			this.infos_clavier.plus;
		document.getElementById(this.infos_clavier.emplacement).dataset['couleur'] =
			this.infos_clavier.couleur;

		if (this.infos_clavier.controles === 'oui') {
			this.ajouterBoutonsChangerCouche(this.id, this.infos_clavier);
		}
	}

	majTouches() {
		for (let ligne = 1; ligne <= 7; ligne++) {
			for (let j = 0; j <= 15; j++) {
				// Récupération de ce qui doit être affiché sur la touche, selon que la géométrie est iso ou ergodox (deux listes de propriétés différentes)
				const res = this.data[this.infos_clavier.type].find(
					(el) => el['ligne'] == ligne && el['colonne'] == j
				);

				let colonne = j;

				// Interversion de É et de ★ sur les claviers ISO
				// if (res !== undefined) {
				// 	if ((this.infos_clavier.type === 'iso') && (this.infos_clavier.plus === 'oui') && (res.touche === 'é')) {
				// 		colonne = j + 1;
				// 	} else if ((this.infos_clavier.type === 'iso') && (this.infos_clavier.plus === 'oui') && (res.touche === 'magique')) {
				// 		colonne = j - 1;
				// 	}
				// }

				// Suppression des event listeners sur la touche
				const toucheClavier0 = document
					.getElementById(this.infos_clavier.emplacement)
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
					const contenuTouche = this.data.touches.find((el) => el['touche'] === res['touche']);

					if (contenuTouche[this.infos_clavier.couche] === '') {
						toucheClavier.innerHTML = '<div><div>'; /* Touche vide */
					} else {
						if (this.infos_clavier.couche === 'Visuel') {
							if (contenuTouche['type'] === 'ponctuation') {
								if (res['touche'] === '"') {
									// Cas particulier de la touche « " »
									toucheClavier.innerHTML =
										'<div>' +
										contenuTouche['Shift'] +
										'<br/>' +
										contenuTouche['Primary'] +
										'</div>';
								} else {
									// Toutes les autres touches "doubles"
									toucheClavier.innerHTML =
										'<div>' +
										contenuTouche['AltGr'] +
										'<br/>' +
										contenuTouche['Primary'] +
										'</div>';
									if (contenuTouche['Primary' + '+'] !== undefined && ligne < 6) {
										// Si la couche + existe ET n’est pas en thumb cluster
										toucheClavier.dataset['plus'] = 'oui';
									}
								}
							} else {
								// Cas où la touche n’est pas double
								if (this.infos_clavier.plus === 'oui') {
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
							if (this.infos_clavier.plus === 'oui') {
								if (contenuTouche[this.infos_clavier.couche + '+'] !== undefined) {
									toucheClavier.innerHTML =
										'<div>' + contenuTouche[this.infos_clavier.couche + '+'] + '</div>';
									toucheClavier.dataset.plus = 'oui';
								} else {
									toucheClavier.innerHTML =
										'<div>' + contenuTouche[this.infos_clavier.couche] + '</div>';
								}
							} else {
								toucheClavier.innerHTML =
									'<div>' + contenuTouche[this.infos_clavier.couche] + '</div>';
							}
						}
					}

					// Corrections localisées
					if (this.infos_clavier.type === 'ergodox' && res.touche === 'Space') {
						toucheClavier.innerHTML = '<div>␣</div>';
					}
					if (
						this.infos_clavier.type === 'iso' &&
						res.touche === 'Space' &&
						this.infos_clavier.couche === 'Visuel'
						// this.infos_clavier.plus === 'non'
					) {
						toucheClavier.innerHTML = '<div>HyperTexte v.' + this.version + '</div>';
					}
					// if (
					// 	this.infos_clavier.type === 'iso' &&
					// 	res.touche === 'Space' &&
					// 	this.infos_clavier.couche === 'Visuel' &&
					// 	this.infos_clavier.plus === 'oui'
					// ) {
					// 	toucheClavier.innerHTML =
					// 		"<div>Layer de navigation<br><span class='tap'>HyperTexte v." +
					// 		this.version +
					// 		'</span></div>';
					// }

					// On ajoute des this.infos_clavier dans les data attributes de la touche
					toucheClavier.dataset['touche'] = res['touche'];
					toucheClavier.dataset['colonne'] = colonne;
					toucheClavier.dataset['doigt'] = res['doigt'];
					toucheClavier.dataset['main'] = res['main'];
					toucheClavier.dataset['type'] = contenuTouche['type'];
					toucheClavier.dataset['style'] = '';
					if (
						this.infos_clavier.couche === 'Visuel' &&
						contenuTouche['Primary' + '-style'] !== undefined &&
						contenuTouche['Primary' + '-style'] !== ''
					) {
						toucheClavier.dataset['style'] = contenuTouche['Primary' + '-style'];
					} else {
						if (
							contenuTouche[this.infos_clavier.couche + '-style'] !== undefined &&
							contenuTouche[this.infos_clavier.couche + '-style'] !== ''
						) {
							toucheClavier.dataset['style'] = contenuTouche[this.infos_clavier.couche + '-style'];
						}
					}
					toucheClavier.style.setProperty('--taille', res['taille']);
					let frequence = mayzner[contenuTouche[this.infos_clavier.couche]] / mayzner['max'];
					toucheClavier.style.setProperty('--frequence', frequence);
					toucheClavier.style.setProperty('--frequence-log', Math.log(frequence));
				}
			}
		}
	}

	activerModificateurs() {
		let lShift = document
			.getElementById(this.infos_clavier.emplacement)
			.querySelector("[data-touche='LShift']");
		let rShift = document
			.getElementById(this.infos_clavier.emplacement)
			.querySelector("[data-touche='RShift']");
		let lCtrl = document
			.getElementById(this.infos_clavier.emplacement)
			.querySelector("[data-touche='LCtrl']");
		let rCtrl = document
			.getElementById(this.infos_clavier.emplacement)
			.querySelector("[data-touche='RCtrl']");
		let altGr = document
			.getElementById(this.infos_clavier.emplacement)
			.querySelector("[data-touche='RAlt']");
		let aGrave = document
			.getElementById(this.infos_clavier.emplacement)
			.querySelector("[data-touche='à']");
		let virgule = document
			.getElementById(this.infos_clavier.emplacement)
			.querySelector("[data-touche=',']");
		let lalt = document
			.getElementById(this.infos_clavier.emplacement)
			.querySelector("[data-touche='LAlt']");
		let space = document
			.getElementById(this.infos_clavier.emplacement)
			.querySelector("[data-touche='Space']");

		if (this.infos_clavier.couche === 'Shift' && lShift !== null) {
			lShift.classList.add('touche-active');
		}
		if (this.infos_clavier.couche === 'Shift' && rShift !== null) {
			rShift.classList.add('touche-active');
		}
		if (
			this.infos_clavier.couche === 'Shift' &&
			rCtrl !== null &&
			this.infos_clavier.plus === 'oui'
		) {
			rCtrl.classList.add('touche-active');
		}
		if (this.infos_clavier.couche === 'Ctrl' && lCtrl !== null) {
			lCtrl.classList.add('touche-active');
		}
		if (this.infos_clavier.couche === 'Ctrl' && rCtrl !== null) {
			rCtrl.classList.add('touche-active');
		}
		if (this.infos_clavier.couche === 'AltGr' && altGr !== null) {
			altGr.classList.add('touche-active');
		}
		if (this.infos_clavier.couche === 'ShiftAltGr' && lShift !== null) {
			lShift.classList.add('touche-active');
		}
		if (this.infos_clavier.couche === 'ShiftAltGr' && rShift !== null) {
			rShift.classList.add('touche-active');
		}
		if (this.infos_clavier.couche === 'ShiftAltGr' && altGr !== null) {
			altGr.classList.add('touche-active');
		}
		if (this.infos_clavier.couche === 'À' && aGrave !== null) {
			aGrave.classList.add('touche-active');
		}
		if (this.infos_clavier.couche === ',' && virgule !== null) {
			virgule.classList.add('touche-active');
		}
		if (
			this.infos_clavier.couche === 'Layer' &&
			lalt !== null &&
			this.infos_clavier.type === 'iso'
		) {
			lalt.classList.add('touche-active');
		}
		if (
			this.infos_clavier.couche === 'Layer' &&
			space !== null &&
			this.infos_clavier.type === 'ergodox'
		) {
			space.classList.add('touche-active');
		}
	}

	changerCouche(toucheModificatrice) {
		let touchePressee = toucheModificatrice.dataset.touche;
		let coucheActuelle = document.getElementById(this.infos_clavier.emplacement).dataset.couche;
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

		// Touche pressée = LAlt (devient Layer)
		if (
			((touchePressee === 'LAlt') & (this.infos_clavier.type === 'iso')) |
				((touchePressee === 'Space') & (this.infos_clavier.type === 'ergodox')) &&
			this.infos_clavier.plus === 'oui' &&
			coucheActuelle === 'Layer'
		) {
			nouvelleCouche = 'Visuel';
		} else if (
			((touchePressee === 'LAlt') & (this.infos_clavier.type === 'iso')) |
				((touchePressee === 'Space') & (this.infos_clavier.type === 'ergodox')) &&
			this.infos_clavier.plus === 'oui'
		) {
			nouvelleCouche = 'Layer';
		}

		// Touche pressée = RCtrl (devient Shift)
		if (
			((touchePressee === 'RCtrl') & (this.infos_clavier.type === 'iso')) |
				((touchePressee === 'Space') & (this.infos_clavier.type === 'ergodox')) &&
			this.infos_clavier.plus === 'oui' &&
			coucheActuelle === 'Shift'
		) {
			nouvelleCouche = 'Visuel';
		} else if (
			(touchePressee === 'RCtrl') & (this.infos_clavier.type === 'iso') &&
			this.infos_clavier.plus === 'oui'
		) {
			nouvelleCouche = 'Shift';
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
		this.data_clavier[this.id].update((currentData) => {
			currentData['couche'] = nouvelleCouche;
			return currentData;
		});

		this.majClavier();
	}

	ajouterBoutonsChangerCouche() {
		let emplacementClavier = document.getElementById(this.infos_clavier.emplacement);
		let toucheRAlt = emplacementClavier.querySelector("bloc-touche[data-touche='RAlt']");
		let toucheLShift = emplacementClavier.querySelector("bloc-touche[data-touche='LShift']");
		let toucheRShift = emplacementClavier.querySelector("bloc-touche[data-touche='RShift']");
		let toucheLCtrl = emplacementClavier.querySelector("bloc-touche[data-touche='LCtrl']");
		let toucheRCtrl = emplacementClavier.querySelector("bloc-touche[data-touche='RCtrl']");
		let toucheLAlt = emplacementClavier.querySelector("bloc-touche[data-touche='LAlt']");
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
					() => {
						this.changerCouche(toucheModificatrice);
					},
					{ passive: true }
				);
			}
		}

		// Les boutons de touches modificatrices À et Space ne sont ajoutées que si + est activé
		if (this.infos_clavier.plus === 'oui') {
			for (let toucheModificatrice of [toucheLAlt, toucheA, toucheVirgule, toucheEspace]) {
				if (toucheModificatrice !== null) {
					toucheModificatrice.addEventListener('click', () => {
						this.changerCouche(toucheModificatrice);
					});
				}
			}
		}
	}
}

const mayzner = {
	max: 14.444,
	e: 13.001,
	t: 7.958,
	a: 7.584,
	n: 6.702,
	s: 6.671,
	o: 6.648,
	i: 6.615,
	r: 5.888,
	u: 4.316,
	l: 4.209,
	h: 4.056,
	d: 3.971,
	c: 2.622,
	m: 2.572,
	',': 1.997,
	p: 1.931,
	f: 1.61,
	g: 1.384,
	v: 1.342,
	w: 1.151,
	b: 1.098,
	y: 1.057,
	q: 0.816,
	"'": 0.756,
	é: 0.716,
	'.': 0.494,
	k: 0.355,
	j: 0.33,
	';': 0.302,
	x: 0.285,
	à: 0.236,
	'-': 0.175,
	'“': 0.152,
	'”': 0.15,
	è: 0.13,
	z: 0.115,
	ê: 0.092,
	':': 0.061,
	'?': 0.061,
	â: 0.054,
	'!': 0.047,
	î: 0.047,
	ô: 0.036,
	_: 0.03,
	û: 0.024,
	ç: 0.023,
	ñ: 0.023,
	ù: 0.022,
	'‘': 0.013,
	'—': 0.012,
	œ: 0.011,
	']': 0.009,
	'[': 0.009,
	'(': 0.008,
	')': 0.008,
	ï: 0.005,
	'«': 0.004,
	ë: 0.002,
	'»': 0.002,
	á: 0.001,
	æ: 0.001,
	í: 0.001
};
