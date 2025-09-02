import * as stores_infos from '$lib/stores_infos.js';
import { getKeyboardData } from '$lib/keyboard/getKeyboardData.js';

import characterFrequencies from '$lib/keyboard/characterFrequencies.json';
// Créer la clé "max" contenant la valeur maximale parmi les fréquences (souvent la fréquence en E)
characterFrequencies.max = Math.max(...Object.values(characterFrequencies));
characterFrequencies.min = Math.min(...Object.values(characterFrequencies));
// Permet de mieux étaler les valeurs des fréquences
function transformLogarithmique(x, k) {
	return Math.log(1 + k * x) / Math.log(1 + k);
}

export class Keyboard {
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

	getKeyboardLocation() {
		// Vérifie si le document est défini
		if (typeof document !== 'undefined') {
			let keyboardLocation = document.getElementById(`clavier_${this.id}`);
			if (keyboardLocation === null) {
				// Lève une exception si l'emplacement n'est pas défini
				throw new Error('Emplacement clavier introuvable');
			}
			return keyboardLocation;
		}
		// Lève une exception si le document n'est pas défini
		throw new Error('Document non défini');
	}

	majClavier() {
		// On n’en a pas besoin, et si c’est activé cela multiplie les requêtes inutiles (1 par clavier)
		// if (this.data_disposition === undefined) {
		// 	this.data_disposition = getKeyboardData(this.version);
		// }
		this.majTouches();
		this.modifiersActivationOfCurrentLayer();

		try {
			const keyboardLocation = this.getKeyboardLocation();
			keyboardLocation.dataset['type'] = this.infos_clavier.type;
			keyboardLocation.dataset['couche'] = this.infos_clavier.couche;
			keyboardLocation.dataset['plus'] = this.infos_clavier.plus;
			keyboardLocation.dataset['couleur'] = this.infos_clavier.couleur;
		} catch (error) {
			return;
		}

		if (this.infos_clavier.controles === 'oui') {
			this.layerSwitchAddButtons(this.id, this.infos_clavier);
		}
	}

	majTouches() {
		if (this.data_disposition === undefined) {
			return;
		}
		try {
			const keyboardLocation = this.getKeyboardLocation();
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
					const toucheClavier0 = keyboardLocation.querySelector(
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

	modifiersActivationOfCurrentLayer() {
		try {
			const keyboardLocation = this.getKeyboardLocation();
			let keyLeftShift = keyboardLocation.querySelector("[data-touche='LShift']");
			let keyRightShift = keyboardLocation.querySelector("[data-touche='RShift']");
			let keyLeftControl = keyboardLocation.querySelector("[data-touche='LCtrl']");
			let keyRightControl = keyboardLocation.querySelector("[data-touche='RCtrl']");
			let keyRightAlt = keyboardLocation.querySelector("[data-touche='RAlt']");
			let keyLeftAlt = keyboardLocation.querySelector("[data-touche='LAlt']");
			let keyCapsLock = keyboardLocation.querySelector("[data-touche='CapsLock']");
			let keySpace = keyboardLocation.querySelector("[data-touche='Space']");
			let keyAGrave = keyboardLocation.querySelector("[data-touche='à']");
			let keyComma = keyboardLocation.querySelector("[data-touche=',']");

			if (this.infos_clavier.couche === 'Shift' && keyLeftShift !== null) {
				keyLeftShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'Shift' && keyRightShift !== null) {
				keyRightShift.classList.add('touche-active');
			}
			if (
				this.infos_clavier.couche === 'Shift' &&
				this.infos_clavier.plus === 'oui' &&
				this.infos_clavier.type === 'iso'
			) {
				keyRightControl.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'Ctrl' && keyLeftControl !== null) {
				keyLeftControl.classList.add('touche-active');
			}
			if (
				this.infos_clavier.couche === 'Ctrl' &&
				keyCapsLock !== null &&
				this.infos_clavier.plus === 'oui'
			) {
				keyCapsLock.classList.add('touche-active');
			}
			if (
				this.infos_clavier.couche === 'Ctrl' &&
				keyRightControl !== null &&
				this.infos_clavier.plus === 'non'
			) {
				keyRightControl.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'AltGr' && keyRightAlt !== null) {
				keyRightAlt.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'ShiftAltGr' && keyLeftShift !== null) {
				keyLeftShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'ShiftAltGr' && keyRightShift !== null) {
				keyRightShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'ShiftAltGr' && keyRightAlt !== null) {
				keyRightAlt.classList.add('touche-active');
			}
			if (
				this.infos_clavier.couche === 'Layer' &&
				keyLeftAlt !== null &&
				this.infos_clavier.type === 'iso'
			) {
				keySpace.classList.add('touche-active');
			}
			if (
				this.infos_clavier.couche === 'Layer' &&
				keySpace !== null &&
				this.infos_clavier.type === 'ergodox'
			) {
				keySpace.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'CirconflexeShift' && keyLeftShift !== null) {
				keyLeftShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'CirconflexeShift' && keyRightShift !== null) {
				keyRightShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'TremaShift' && keyLeftShift !== null) {
				keyLeftShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'TremaShift' && keyRightShift !== null) {
				keyRightShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'GreekShift' && keyLeftShift !== null) {
				keyLeftShift.classList.add('touche-active');
			}
			if (this.infos_clavier.couche === 'GreekShift' && keyRightShift !== null) {
				keyRightShift.classList.add('touche-active');
			}
			// if (this.infos_clavier.couche === 'À' && keyAGrave !== null) {
			// 	keyAGrave.classList.add('touche-active');
			// }
			// if (this.infos_clavier.couche === ',' && keyComma !== null) {
			// 	keyComma.classList.add('touche-active');
			// }
		} catch (error) {
			return;
		}
	}

	layerSwitch(modifierKey) {
		let pressedKey = modifierKey.dataset.touche;
		let currentLayer = this.infos_clavier.couche;
		let newLayer = currentLayer;

		let shiftPressed =
			pressedKey === 'LShift' ||
			pressedKey === 'RShift' ||
			(pressedKey === 'RCtrl' && this.infos_clavier.plus === 'oui');

		if (shiftPressed) {
			pressedKey = 'Shift';
		}

		// Ctrl becomes Shift in Ergopti+
		if (pressedKey === 'RCtrl' && this.infos_clavier.plus === 'oui') {
			pressedKey = 'Shift';
		}

		const mappings = {
			Shift: {
				Shift: 'Visuel',
				AltGr: 'ShiftAltGr',
				ShiftAltGr: 'AltGr',
				CirconflexeShift: 'Circonflexe',
				Circonflexe: 'CirconflexeShift',
				TremaShift: 'Trema',
				Trema: 'TremaShift',
				GreekShift: 'Greek',
				Greek: 'GreekShift',
				À: 'Shift',
				',': 'Shift',
				Exposant: 'Shift',
				Indice: 'Shift',
				default: 'Shift'
			},
			RAlt: {
				AltGr: 'Visuel',
				Shift: 'ShiftAltGr',
				ShiftAltGr: 'Shift',
				default: 'AltGr'
			},
			LCtrl: {
				Ctrl: 'Visuel',
				default: 'Ctrl'
			},
			RCtrl: {
				Ctrl: 'Visuel',
				default: 'Ctrl'
			}
		};

		if (pressedKey in mappings) {
			const rules = mappings[pressedKey];
			if (rules) {
				newLayer = rules[currentLayer] || rules.default;
			}
		}

		// Touche pressée = CapsLock
		if (pressedKey === 'CapsLock' && this.infos_clavier.plus === 'oui' && currentLayer !== 'Ctrl') {
			newLayer = 'Ctrl';
		} else if (pressedKey === 'CapsLock' && this.infos_clavier.plus === 'oui') {
			newLayer = 'Visuel';
		}

		// Touche pressée = Space
		if (
			pressedKey === 'Space' &&
			this.infos_clavier.type === 'ergodox' &&
			this.infos_clavier.plus === 'oui' &&
			['Visuel', 'Primary'].includes(currentLayer)
		) {
			newLayer = 'Layer';
		} else if (
			pressedKey === 'Space' &&
			this.infos_clavier.type === 'ergodox' &&
			this.infos_clavier.plus === 'oui'
		) {
			newLayer = 'Visuel';
		}

		// LAlt
		if (
			pressedKey === 'LAlt' &&
			this.infos_clavier.type === 'iso' &&
			this.infos_clavier.plus === 'oui' &&
			['Visuel', 'Primary'].includes(currentLayer)
		) {
			newLayer = 'Layer';
		} else if (
			pressedKey === 'LAlt' &&
			this.infos_clavier.type === 'iso' &&
			this.infos_clavier.plus === 'oui'
		) {
			newLayer = 'Visuel';
		}

		// Touche pressée = À
		if (
			pressedKey === 'à' &&
			['Visuel', 'Primary', 'Shift'].includes(currentLayer) &&
			this.infos_clavier.plus === 'oui'
		) {
			newLayer = 'À';
		}
		if (pressedKey === 'à' && currentLayer === 'ShiftAltGr') {
			newLayer = 'Indice';
		}

		// Touche pressée = E
		if (pressedKey === 'e' && currentLayer === 'ShiftAltGr') {
			newLayer = 'Exposant';
		}

		// Touche pressée = U
		if (pressedKey === 'u' && currentLayer === 'ShiftAltGr') {
			newLayer = 'Greek';
		}

		// Touche pressée = R
		if (pressedKey === 'r' && currentLayer === 'ShiftAltGr') {
			newLayer = 'R';
		}

		// Touche pressée = ,
		if (
			pressedKey === ',' &&
			['Visuel', 'Primary', 'Shift'].includes(currentLayer) &&
			this.infos_clavier.plus === 'oui'
		) {
			newLayer = ',';
		}

		// Touche pressée = Circonflexe
		if (
			(pressedKey === 'Circonflexe' && ['Visuel', 'Primary'].includes(currentLayer)) ||
			(pressedKey === 'ê' && currentLayer === 'ShiftAltGr')
		) {
			newLayer = 'Circonflexe';
		}

		// Touche pressée = Trema
		if (
			(pressedKey === 'Trema' && ['Visuel', 'Primary'].includes(currentLayer)) ||
			(pressedKey === 't' && currentLayer === 'ShiftAltGr')
		) {
			newLayer = 'Trema';
		}

		// Une fois que la nouvelle couche est déterminée, on actualise la valeur de la couche, puis le clavier
		this.data_clavier.update((currentData) => {
			currentData['couche'] = newLayer;
			return currentData;
		});
		this.majClavier();
	}

	layerSwitchAddButtons() {
		try {
			const keyboardLocation = this.getKeyboardLocation();
			let toucheLAlt = keyboardLocation.querySelector("bloc-touche[data-touche='LAlt']");
			let toucheRAlt = keyboardLocation.querySelector("bloc-touche[data-touche='RAlt']");
			let toucheLShift = keyboardLocation.querySelector("bloc-touche[data-touche='LShift']");
			let toucheRShift = keyboardLocation.querySelector("bloc-touche[data-touche='RShift']");
			let toucheLCtrl = keyboardLocation.querySelector("bloc-touche[data-touche='LCtrl']");
			let toucheRCtrl = keyboardLocation.querySelector("bloc-touche[data-touche='RCtrl']");
			let toucheCapsLock = keyboardLocation.querySelector("bloc-touche[data-touche='CapsLock']");
			let toucheA = keyboardLocation.querySelector("bloc-touche[data-touche='à']");
			let toucheE = keyboardLocation.querySelector("bloc-touche[data-touche='e']");
			let toucheECirc = keyboardLocation.querySelector("bloc-touche[data-touche='ê']");
			let toucheR = keyboardLocation.querySelector("bloc-touche[data-touche='r']");
			let toucheT = keyboardLocation.querySelector("bloc-touche[data-touche='t']");
			let toucheU = keyboardLocation.querySelector("bloc-touche[data-touche='u']");
			let toucheEspace = keyboardLocation.querySelector("bloc-touche[data-touche='Space']");
			let toucheVirgule = keyboardLocation.querySelector("bloc-touche[data-touche=',']");
			let toucheCirconflexe = keyboardLocation.querySelector(
				"bloc-touche[data-touche='Circonflexe']"
			);
			let toucheTrema = keyboardLocation.querySelector("bloc-touche[data-touche='Trema']");

			// On ajoute une action au clic sur chacune des touches modificatrices
			for (let modifierKey of [
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
				if (modifierKey !== null) {
					modifierKey.addEventListener(
						'click',
						() => {
							this.layerSwitch(modifierKey);
						},
						{ passive: true }
					);
				}
			}
		} catch (error) {
			return;
		}
	}

	typeText(texte, vitesse, disparition_anciennes_touches) {
		try {
			const keyboardLocation = this.getKeyboardLocation();

			// Nettoyage des touches actives
			const touchesActives = keyboardLocation.querySelectorAll('.touche-active');
			[].forEach.call(touchesActives, function (el) {
				el.classList.remove('touche-active');
			});

			// let texte = 'test';
			function writeNext(texte, i) {
				let nouvelleLettre = texte.charAt(i);
				keyboardLocation
					.querySelector("bloc-touche[data-touche='" + nouvelleLettre + "']")
					.classList.add('touche-active');

				if (disparition_anciennes_touches) {
					if (i === texte.length) {
						keyboardLocation
							.querySelector("bloc-touche[data-touche='" + texte.charAt(i - 1) + "']")
							.classList.remove('touche-active');
						return;
					}

					if (i !== 0) {
						let ancienneLettre = texte.charAt(i - 1);
						keyboardLocation
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
