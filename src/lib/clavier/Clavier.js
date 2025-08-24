import * as stores_infos from '$lib/stores_infos.js';
import { getData } from '$lib/clavier/getData.js';

import characterFrequencies from '$lib/clavier/characterFrequencies.json';
// Créer la clé "max" contenant la valeur maximale parmi les fréquences (souvent la fréquence en E)
characterFrequencies.max = Math.max(...Object.values(characterFrequencies));
characterFrequencies.min = Math.min(...Object.values(characterFrequencies));
// Permet de mieux étaler les valeurs des fréquences
function transformLogarithmique(x, k) {
	return Math.log(1 + k * x) / Math.log(1 + k);
}

export class Clavier {
	constructor(id) {
		this.id = id;

		// S'abonner au store pour la version
		stores_infos['version'].subscribe((value) => {
			this.version = value;
		});
		stores_infos['data_disposition'].subscribe((value) => {
			this.data_disposition = value;
			this.majClavier();
		});

		// Liaison avec le store spécifique au clavier (data_clavier)
		this.data_clavier = stores_infos[this.id]; // Permet de modifier les données du clavier

		// S'abonner au store pour récupérer les données du clavier mises à jour en temps réel
		this.data_clavier.subscribe((value) => {
			this.infos_clavier = value;
		});
	}

	getEmplacementClavier() {
		// Vérifie si le document est défini
		if (typeof document !== 'undefined') {
			let emplacementClavier = document.getElementById(`clavier_${this.id}`);
			if (emplacementClavier === null) {
				// Lève une exception si l'emplacement n'est pas défini
				throw new Error('Emplacement clavier introuvable');
			}
			return emplacementClavier;
		}
		// Lève une exception si le document n'est pas défini
		throw new Error('Document non défini');
	}

	majClavier() {
		// On n’en a pas besoin, et si c’est activé cela multiplie les requêtes inutiles (1 par clavier)
		// if (this.data_disposition === undefined) {
		// 	this.data_disposition = getData(this.version);
		// }
		this.majTouches();
		this.activerModificateurs();

		try {
			const emplacementClavier = this.getEmplacementClavier();
			emplacementClavier.dataset['type'] = this.infos_clavier.type;
			emplacementClavier.dataset['couche'] = this.infos_clavier.couche;
			emplacementClavier.dataset['plus'] = this.infos_clavier.plus;
			emplacementClavier.dataset['couleur'] = this.infos_clavier.couleur;
		} catch (error) {
			return;
		}

		if (this.infos_clavier.controles === 'oui') {
			this.ajouterBoutonsChangerCouche(this.id, this.infos_clavier);
		}
	}

	majTouches() {
		if (this.data_disposition === undefined) {
			return;
		}
		try {
			const emplacementClavier = this.getEmplacementClavier();
			for (let ligne = 1; ligne <= 7; ligne++) {
				for (let j = 0; j <= 15; j++) {
					// Récupération de ce qui doit être affiché sur la touche, selon que la géométrie est iso ou ergodox (deux listes de propriétés différentes)
					const res = this.data_disposition[this.infos_clavier.type].find(
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
					const toucheClavier0 = emplacementClavier.querySelector(
						"bloc-touche[data-ligne='" + ligne + "'][data-colonne='" + colonne + "']"
					);
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
					// Suppression du contenu de la touche
					toucheClavier.dataset['touche'] = '';
					toucheClavier.dataset['plus'] = 'non';
					toucheClavier.classList.remove('touche-active'); // Suppression de la classe css pour les touches pressées

					if (res !== undefined) {
						const contenuTouche = this.data_disposition.touches.find(
							(el) => el['touche'] === res['touche']
						);

						if (
							this.infos_clavier.couche !== 'Visuel' &&
							(contenuTouche[this.infos_clavier.couche] === '' ||
								contenuTouche[this.infos_clavier.couche] === undefined)
						) {
							toucheClavier.innerHTML = '<div><div>'; /* Touche vide ou undefined dans le json */
						} else {
							if (this.infos_clavier.couche === 'Visuel') {
								if (contenuTouche['type'] === 'ponctuation') {
									if (res['touche'] === '"') {
										// Cas particulier de la touche « " »
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
									if (
										contenuTouche[this.infos_clavier.couche + '+'] !== undefined &&
										(ligne < 6 || res.touche === 'Space')
									) {
										// Si la couche + existe et n’est pas en thumb cluster. Sur le thumb cluster, on affiche seulement le tap hold en space et pas en Alt ou Ctrl
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

						// Corrections localisées sur la barre d’espace
						if (
							this.infos_clavier.type === 'ergodox' &&
							res.touche === 'Space' &&
							['Visuel', 'Primary'].includes(this.infos_clavier.couche)
						) {
							toucheClavier.innerHTML = '<div>␣</div>';
						}
						if (
							this.infos_clavier.type === 'iso' &&
							res.touche === 'Space' &&
							this.infos_clavier.couche === 'Visuel' &&
							this.infos_clavier.plus === 'non'
						) {
							toucheClavier.innerHTML = '<div>' + this.data_disposition.nom + '</div>';
						}
						if (
							this.infos_clavier.type === 'iso' &&
							res.touche === 'Space' &&
							this.infos_clavier.couche === 'Visuel' &&
							this.infos_clavier.plus === 'oui'
						) {
							toucheClavier.innerHTML =
								"<div>Layer de navigation<br><span class='tap'>Ergopti v." +
								this.version +
								'</span></div>';
						}

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
								this.infos_clavier.plus === 'oui' &&
								contenuTouche[this.infos_clavier.couche + '+' + '-style'] !== undefined &&
								contenuTouche[this.infos_clavier.couche + '+' + '-style'] !== ''
							) {
								toucheClavier.dataset['style'] =
									contenuTouche[this.infos_clavier.couche + '+' + '-style'];
							} else if (
								contenuTouche[this.infos_clavier.couche + '-style'] !== undefined &&
								contenuTouche[this.infos_clavier.couche + '-style'] !== ''
							) {
								toucheClavier.dataset['style'] =
									contenuTouche[this.infos_clavier.couche + '-style'];
							}
						}
						toucheClavier.style.setProperty('--taille', res['taille']);
						let frequence = characterFrequencies[contenuTouche[this.infos_clavier.couche]];
						toucheClavier.style.setProperty('--frequence', frequence);
						let frequence_normalisee =
							(characterFrequencies[contenuTouche[this.infos_clavier.couche]] -
								characterFrequencies['min']) /
							(characterFrequencies['max'] - characterFrequencies['min']); // Entre 0 et 1 avec 1 pour la lettre la plus fréquente
						toucheClavier.style.setProperty(
							'--frequence-normalisee',
							transformLogarithmique(frequence_normalisee, 40)
						);
					}
				}
			}
		} catch (error) {
			return;
		}
	}

	activerModificateurs() {
		try {
			const emplacementClavier = this.getEmplacementClavier();
			let lShift = emplacementClavier.querySelector("[data-touche='LShift']");
			let rShift = emplacementClavier.querySelector("[data-touche='RShift']");
			let lCtrl = emplacementClavier.querySelector("[data-touche='LCtrl']");
			let rCtrl = emplacementClavier.querySelector("[data-touche='RCtrl']");
			let altGr = emplacementClavier.querySelector("[data-touche='RAlt']");
			let CapsLock = emplacementClavier.querySelector("[data-touche='CapsLock']");
			let aGrave = emplacementClavier.querySelector("[data-touche='à']");
			let virgule = emplacementClavier.querySelector("[data-touche=',']");
			let circonflexe = emplacementClavier.querySelector("[data-touche='Circonflexe']");
			let Trema = emplacementClavier.querySelector("[data-touche='Trema']");
			let lalt = emplacementClavier.querySelector("[data-touche='LAlt']");
			let space = emplacementClavier.querySelector("[data-touche='Space']");

			if (this.infos_clavier.couche === 'Shift' && lShift !== null) {
				lShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'Shift' && rShift !== null) {
				rShift.classList.add('touche-active');
			}
			if (
				this.infos_clavier.couche === 'Shift' &&
				this.infos_clavier.plus === 'oui' &&
				this.infos_clavier.type === 'iso'
			) {
				lalt.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'Ctrl' && lCtrl !== null) {
				lCtrl.classList.add('touche-active');
			}
			if (
				this.infos_clavier.couche === 'Ctrl' &&
				CapsLock !== null &&
				this.infos_clavier.plus === 'oui'
			) {
				CapsLock.classList.add('touche-active');
			}
			if (
				this.infos_clavier.couche === 'Ctrl' &&
				rCtrl !== null &&
				this.infos_clavier.plus === 'non'
			) {
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
			// if (this.infos_clavier.couche === 'À' && aGrave !== null) {
			// 	aGrave.classList.add('touche-active');
			// }
			// if (this.infos_clavier.couche === ',' && virgule !== null) {
			// 	virgule.classList.add('touche-active');
			// }
			if (
				this.infos_clavier.couche === 'Layer' &&
				space !== null &&
				this.infos_clavier.type === 'iso'
			) {
				space.classList.add('touche-active');
			}
			if (
				this.infos_clavier.couche === 'Layer' &&
				space !== null &&
				this.infos_clavier.type === 'ergodox'
			) {
				space.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'CirconflexeShift' && lShift !== null) {
				lShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'CirconflexeShift' && rShift !== null) {
				rShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'TremaShift' && lShift !== null) {
				lShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'TremaShift' && rShift !== null) {
				rShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'GreekShift' && lShift !== null) {
				lShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'GreekShift' && rShift !== null) {
				rShift.classList.add('touche-active');
			}
		} catch (error) {
			return;
		}
	}

	changerCouche(toucheModificatrice) {
		let touchePressee = toucheModificatrice.dataset.touche;
		let coucheActuelle = this.infos_clavier.couche;
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
		if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'Shift'
		) {
			nouvelleCouche = 'Visuel';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'AltGr'
		) {
			nouvelleCouche = 'ShiftAltGr';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'ShiftAltGr'
		) {
			nouvelleCouche = 'AltGr';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			(coucheActuelle === 'À' || coucheActuelle === ',')
		) {
			nouvelleCouche = 'Shift';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'CirconflexeShift'
		) {
			nouvelleCouche = 'Circonflexe';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'Circonflexe'
		) {
			nouvelleCouche = 'CirconflexeShift';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'TremaShift'
		) {
			nouvelleCouche = 'Trema';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'Trema'
		) {
			nouvelleCouche = 'TremaShift';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'Exposant'
		) {
			nouvelleCouche = 'Shift';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'Indice'
		) {
			nouvelleCouche = 'Shift';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'GreekShift'
		) {
			nouvelleCouche = 'Greek';
		} else if (
			(touchePressee === 'LShift' ||
				touchePressee === 'RShift' ||
				(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')) &&
			coucheActuelle === 'Greek'
		) {
			nouvelleCouche = 'GreekShift';
		} else if (
			touchePressee === 'LShift' ||
			touchePressee === 'RShift' ||
			(touchePressee === 'LAlt' && this.infos_clavier.plus === 'oui')
		) {
			nouvelleCouche = 'Shift';
		}

		// Touche pressée = Ctrl
		if (touchePressee === 'LCtrl' && coucheActuelle !== 'Ctrl') {
			nouvelleCouche = 'Ctrl';
		} else if (touchePressee === 'LCtrl') {
			nouvelleCouche = 'Visuel';
		}

		// Touche pressée = RCtrl
		if (
			touchePressee === 'RCtrl' &&
			this.infos_clavier.plus === 'non' &&
			coucheActuelle !== 'Ctrl'
		) {
			nouvelleCouche = 'Ctrl';
		} else if (touchePressee === 'RCtrl' && this.infos_clavier.plus === 'non') {
			nouvelleCouche = 'Visuel';
		}

		// Touche pressée = CapsLock
		if (
			touchePressee === 'CapsLock' &&
			this.infos_clavier.plus === 'oui' &&
			coucheActuelle !== 'Ctrl'
		) {
			nouvelleCouche = 'Ctrl';
		} else if (touchePressee === 'CapsLock' && this.infos_clavier.plus === 'oui') {
			nouvelleCouche = 'Visuel';
		}

		// Touche pressée = Space
		if (
			touchePressee === 'Space' &&
			this.infos_clavier.plus === 'oui' &&
			['Visuel', 'Primary'].includes(coucheActuelle)
		) {
			nouvelleCouche = 'Layer';
		} else if (touchePressee === 'Space' && this.infos_clavier.plus === 'oui') {
			nouvelleCouche = 'Visuel';
		}

		// Touche pressée = À
		if (
			touchePressee === 'à' &&
			['Visuel', 'Primary', 'Shift'].includes(coucheActuelle) &&
			this.infos_clavier.plus === 'oui'
		) {
			nouvelleCouche = 'À';
		}
		if (touchePressee === 'à' && coucheActuelle === 'ShiftAltGr') {
			nouvelleCouche = 'Indice';
		}

		// Touche pressée = E
		if (touchePressee === 'e' && coucheActuelle === 'ShiftAltGr') {
			nouvelleCouche = 'Exposant';
		}

		// Touche pressée = U
		if (touchePressee === 'u' && coucheActuelle === 'ShiftAltGr') {
			nouvelleCouche = 'Greek';
		}

		// Touche pressée = R
		if (touchePressee === 'r' && coucheActuelle === 'ShiftAltGr') {
			nouvelleCouche = 'R';
		}

		// Touche pressée = ,
		if (
			touchePressee === ',' &&
			['Visuel', 'Primary', 'Shift'].includes(coucheActuelle) &&
			this.infos_clavier.plus === 'oui'
		) {
			nouvelleCouche = ',';
		}

		// Touche pressée = Circonflexe
		if (
			(touchePressee === 'Circonflexe' && ['Visuel', 'Primary'].includes(coucheActuelle)) ||
			(touchePressee === 'ê' && coucheActuelle === 'ShiftAltGr')
		) {
			nouvelleCouche = 'Circonflexe';
		}

		// Touche pressée = Trema
		if (
			(touchePressee === 'Trema' && ['Visuel', 'Primary'].includes(coucheActuelle)) ||
			(touchePressee === 't' && coucheActuelle === 'ShiftAltGr')
		) {
			nouvelleCouche = 'Trema';
		}

		// Une fois que la nouvelle couche est déterminée, on actualise la valeur de la couche, puis le clavier
		this.data_clavier.update((currentData) => {
			currentData['couche'] = nouvelleCouche;
			return currentData;
		});
		this.majClavier();
	}

	ajouterBoutonsChangerCouche() {
		try {
			const emplacementClavier = this.getEmplacementClavier();
			let toucheLAlt = emplacementClavier.querySelector("bloc-touche[data-touche='LAlt']");
			let toucheRAlt = emplacementClavier.querySelector("bloc-touche[data-touche='RAlt']");
			let toucheLShift = emplacementClavier.querySelector("bloc-touche[data-touche='LShift']");
			let toucheRShift = emplacementClavier.querySelector("bloc-touche[data-touche='RShift']");
			let toucheLCtrl = emplacementClavier.querySelector("bloc-touche[data-touche='LCtrl']");
			let toucheRCtrl = emplacementClavier.querySelector("bloc-touche[data-touche='RCtrl']");
			let toucheCapsLock = emplacementClavier.querySelector("bloc-touche[data-touche='CapsLock']");
			let toucheA = emplacementClavier.querySelector("bloc-touche[data-touche='à']");
			let toucheE = emplacementClavier.querySelector("bloc-touche[data-touche='e']");
			let toucheECirc = emplacementClavier.querySelector("bloc-touche[data-touche='ê']");
			let toucheR = emplacementClavier.querySelector("bloc-touche[data-touche='r']");
			let toucheT = emplacementClavier.querySelector("bloc-touche[data-touche='t']");
			let toucheU = emplacementClavier.querySelector("bloc-touche[data-touche='u']");
			let toucheEspace = emplacementClavier.querySelector("bloc-touche[data-touche='Space']");
			let toucheVirgule = emplacementClavier.querySelector("bloc-touche[data-touche=',']");
			let toucheCirconflexe = emplacementClavier.querySelector(
				"bloc-touche[data-touche='Circonflexe']"
			);
			let toucheTrema = emplacementClavier.querySelector("bloc-touche[data-touche='Trema']");

			// On ajoute une action au clic sur chacune des touches modificatrices
			for (let toucheModificatrice of [
				toucheLAlt,
				toucheRAlt,
				toucheLShift,
				toucheRShift,
				toucheLCtrl,
				toucheRCtrl,
				toucheCapsLock,
				toucheA,
				toucheE,
				toucheECirc,
				toucheR,
				toucheT,
				toucheU,
				toucheVirgule,
				toucheEspace,
				toucheCirconflexe,
				toucheTrema
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
		} catch (error) {
			return;
		}
	}

	taperTexte(texte, vitesse, disparition_anciennes_touches) {
		try {
			const emplacementClavier = this.getEmplacementClavier();

			// Nettoyage des touches actives
			const touchesActives = emplacementClavier.querySelectorAll('.touche-active');
			[].forEach.call(touchesActives, function (el) {
				el.classList.remove('touche-active');
			});

			// let texte = 'test';
			function writeNext(texte, i) {
				let nouvelleLettre = texte.charAt(i);
				emplacementClavier
					.querySelector("bloc-touche[data-touche='" + nouvelleLettre + "']")
					.classList.add('touche-active');

				if (disparition_anciennes_touches) {
					if (i === texte.length) {
						emplacementClavier
							.querySelector("bloc-touche[data-touche='" + texte.charAt(i - 1) + "']")
							.classList.remove('touche-active');
						return;
					}

					if (i !== 0) {
						let ancienneLettre = texte.charAt(i - 1);
						emplacementClavier
							.querySelector("bloc-touche[data-touche='" + ancienneLettre + "']")
							.classList.remove('touche-active');
					}
				}

				setTimeout(function () {
					writeNext(texte, i + 1);
				}, vitesse);
			}

			writeNext(texte, 0);
		} catch (error) {
			return;
		}
	}
}
