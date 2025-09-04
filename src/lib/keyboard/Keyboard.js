import * as stores_infos from '$lib/stores_infos.js';
import { getKeyboardData } from '$lib/keyboard/getKeyboardData.js';

import characterFrequencies from '$lib/keyboard/characterFrequencies.json';
// Créer les clés "max" et "min" contenant la valeur maximale parmi les fréquences (souvent la fréquence en E) et valeur minimale
characterFrequencies.max = Math.max(...Object.values(characterFrequencies));
characterFrequencies.min = Math.min(...Object.values(characterFrequencies));
// Permet de mieux étaler les valeurs des fréquences
function logarithmicTransformation(x, k) {
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
			this.keyboardInformation = value;
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
		this.keysUpdate();
		this.currentLayerModifiersKeyPress();

		try {
			const keyboardLocation = this.getKeyboardLocation();
			keyboardLocation.dataset['type'] = this.keyboardInformation.type;
			keyboardLocation.dataset['layer'] = this.keyboardInformation.layer;
			keyboardLocation.dataset['plus'] = this.keyboardInformation.plus;
			keyboardLocation.dataset['couleur'] = this.keyboardInformation.couleur;
		} catch (error) {
			return;
		}
	}

	keysUpdate() {
		if (this.data_disposition === undefined) {
			return;
		}
		try {
			const keyboardLocation = this.getKeyboardLocation();
			for (let ligne = 1; ligne <= 7; ligne++) {
				for (let j = 0; j <= 15; j++) {
					// Récupération de ce qui doit être affiché sur la touche, selon que la géométrie est iso ou ergodox (deux listes de propriétés différentes)
					const res = this.data_disposition[this.keyboardInformation.type].find(
						(el) => el['ligne'] == ligne && el['colonne'] == j
					);

					let colonne = j;

					// Interversion de É et de ★ sur les claviers ISO
					// if (res !== undefined) {
					// 	if ((this.keyboardInformation.type === 'iso') && (this.keyboardInformation.plus === 'oui') && (res.touche === 'é')) {
					// 		colonne = j + 1;
					// 	} else if ((this.keyboardInformation.type === 'iso') && (this.keyboardInformation.plus === 'oui') && (res.touche === 'magique')) {
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
					toucheClavier.classList.remove('pressed-key'); // Suppression de la classe css pour les touches pressées

					if (res !== undefined) {
						const contenuTouche = this.data_disposition.touches.find(
							(el) => el['touche'] === res['touche']
						);

						if (
							this.keyboardInformation.layer !== 'Visuel' &&
							(contenuTouche[this.keyboardInformation.layer] === '' ||
								contenuTouche[this.keyboardInformation.layer] === undefined)
						) {
							toucheClavier.innerHTML = '<div><div>'; /* Touche vide ou undefined dans le json */
						} else {
							if (this.keyboardInformation.layer === 'Visuel') {
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
											// Si la layer + existe ET n’est pas en thumb cluster
											toucheClavier.dataset['plus'] = 'oui';
										}
									}
								} else {
									// Cas où la touche n’est pas double
									if (this.keyboardInformation.plus === 'oui') {
										// Cas où la touche n’est pas double et + est activé
										if (contenuTouche['Primary' + '+'] !== undefined && ligne < 6) {
											// Si la layer + existe ET n’est pas en thumb cluster
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
								if (this.keyboardInformation.plus === 'oui') {
									if (
										contenuTouche[this.keyboardInformation.layer + '+'] !== undefined &&
										(ligne < 6 || res.touche === 'Space')
									) {
										// Si la layer + existe et n’est pas en thumb cluster. Sur le thumb cluster, on affiche seulement le tap hold en space et pas en Alt ou Ctrl
										toucheClavier.innerHTML =
											'<div>' + contenuTouche[this.keyboardInformation.layer + '+'] + '</div>';
										toucheClavier.dataset.plus = 'oui';
									} else {
										toucheClavier.innerHTML =
											'<div>' + contenuTouche[this.keyboardInformation.layer] + '</div>';
									}
								} else {
									toucheClavier.innerHTML =
										'<div>' + contenuTouche[this.keyboardInformation.layer] + '</div>';
								}
							}
						}

						if (this.keyboardInformation.controles === 'oui') {
							// Functionality to switch layer by clicking on a key
							toucheClavier.addEventListener(
								'click',
								() => {
									this.layerSwitch(toucheClavier);
								},
								{ passive: true }
							);
						}

						// Corrections localisées sur la barre d’espace
						if (
							this.keyboardInformation.type === 'ergodox' &&
							res.touche === 'Space' &&
							['Visuel', 'Primary'].includes(this.keyboardInformation.layer)
						) {
							toucheClavier.innerHTML = '<div>␣</div>';
						}
						if (
							this.keyboardInformation.type === 'iso' &&
							res.touche === 'Space' &&
							this.keyboardInformation.layer === 'Visuel' &&
							this.keyboardInformation.plus === 'non'
						) {
							toucheClavier.innerHTML = '<div>' + this.data_disposition.nom + '</div>';
						}

						// On ajoute des this.keyboardInformation dans les data attributes de la touche
						toucheClavier.dataset['touche'] = res['touche'];
						toucheClavier.dataset['colonne'] = colonne;
						toucheClavier.dataset['doigt'] = res['doigt'];
						toucheClavier.dataset['main'] = res['main'];
						toucheClavier.dataset['type'] = contenuTouche['type'];
						toucheClavier.dataset['style'] = '';
						if (
							this.keyboardInformation.layer === 'Visuel' &&
							contenuTouche['Primary' + '-style'] !== undefined &&
							contenuTouche['Primary' + '-style'] !== ''
						) {
							toucheClavier.dataset['style'] = contenuTouche['Primary' + '-style'];
						} else {
							if (
								this.keyboardInformation.plus === 'oui' &&
								contenuTouche[this.keyboardInformation.layer + '+' + '-style'] !== undefined &&
								contenuTouche[this.keyboardInformation.layer + '+' + '-style'] !== ''
							) {
								toucheClavier.dataset['style'] =
									contenuTouche[this.keyboardInformation.layer + '+' + '-style'];
							} else if (
								contenuTouche[this.keyboardInformation.layer + '-style'] !== undefined &&
								contenuTouche[this.keyboardInformation.layer + '-style'] !== ''
							) {
								toucheClavier.dataset['style'] =
									contenuTouche[this.keyboardInformation.layer + '-style'];
							}
						}
						toucheClavier.style.setProperty('--taille', res['taille']);
						let frequence = characterFrequencies[contenuTouche[this.keyboardInformation.layer]];
						toucheClavier.style.setProperty('--frequence', frequence);
						let frequence_normalisee =
							(characterFrequencies[contenuTouche[this.keyboardInformation.layer]] -
								characterFrequencies['min']) /
							(characterFrequencies['max'] - characterFrequencies['min']); // Entre 0 et 1 avec 1 pour la lettre la plus fréquente
						toucheClavier.style.setProperty(
							'--frequence-normalisee',
							logarithmicTransformation(frequence_normalisee, 40)
						);
					}
				}
			}
		} catch (error) {
			return;
		}
	}

	layerSwitch(pressedKey) {
		let pressedKeyName = pressedKey.dataset.touche;
		const currentLayer = this.keyboardInformation.layer;
		const plus = this.keyboardInformation.plus === 'oui';
		const type = this.keyboardInformation.type;
		let newLayer = currentLayer;

		if (
			pressedKeyName === 'LShift' ||
			pressedKeyName === 'RShift' ||
			// RCtrl becomes Shift in Ergopti+
			(pressedKeyName === 'RCtrl' && plus)
		) {
			pressedKeyName = 'Shift';
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

		if (pressedKeyName in mappings) {
			const rules = mappings[pressedKeyName];
			if (rules) {
				newLayer = rules[currentLayer] || rules.default;
			}
		}

		// Dead Keys on direct access
		if (['Visuel', 'Primary'].includes(currentLayer)) {
			if (pressedKeyName === 'Circonflexe') {
				newLayer = 'Circonflexe';
			}

			if (pressedKeyName === 'Trema') {
				newLayer = 'Trema';
			}
		}

		// Dead Keys on Shift + AltGr
		if (currentLayer === 'ShiftAltGr') {
			if (pressedKeyName === 'e') {
				newLayer = 'Exposant';
			}

			if (pressedKeyName === 'u') {
				newLayer = 'Greek';
			}

			if (pressedKeyName === 't') {
				newLayer = 'Trema';
			}

			if (pressedKeyName === 'r') {
				newLayer = 'R';
			}

			if (pressedKeyName === 'ê') {
				newLayer = 'Circonflexe';
			}

			if (pressedKeyName === 'à') {
				newLayer = 'Indice';
			}
		}

		if (plus) {
			// Comma
			if (pressedKeyName === ',') {
				if (['Visuel', 'Primary', 'Shift'].includes(currentLayer)) {
					newLayer = ',';
				}
			}

			// À
			if (pressedKeyName === 'à') {
				if (['Visuel', 'Primary', 'Shift'].includes(currentLayer)) {
					newLayer = 'À';
				} else if (currentLayer === 'À') {
					newLayer = 'Visuel';
				}
			}

			// CapsLock
			if (pressedKeyName === 'CapsLock') {
				if (currentLayer !== 'Ctrl') {
					newLayer = 'Ctrl';
				} else {
					newLayer = 'Visuel';
				}
			}

			// Space
			if (pressedKeyName === 'Space' && type === 'ergodox') {
				if (['Visuel', 'Primary'].includes(currentLayer)) {
					newLayer = 'Layer';
				} else if (currentLayer === 'Layer') {
					newLayer = 'Visuel';
				}
			}

			// LAlt
			if (pressedKeyName === 'LAlt' && type === 'iso') {
				if (currentLayer === 'Layer') {
					newLayer = 'Visuel';
				} else {
					newLayer = 'Layer';
				}
			}
		}

		// At this point, the new layer has been determined
		// Most keys pressed won’t change the layer, as only some modifiers and deadkeys defined in this code do
		// Then, the layer variable is updated, and finally the keyboard
		if (newLayer !== currentLayer) {
			this.data_clavier.update((currentData) => {
				currentData['layer'] = newLayer;
				return currentData;
			});
			this.majClavier();
		}
	}

	currentLayerModifiersKeyPress() {
		try {
			const keyboardLocation = this.getKeyboardLocation();
			const layer = this.keyboardInformation.layer;
			const plus = this.keyboardInformation.plus === 'oui';
			const type = this.keyboardInformation.type;

			const keys = {
				LShift: keyboardLocation.querySelector("[data-touche='LShift']"),
				RShift: keyboardLocation.querySelector("[data-touche='RShift']"),
				LCtrl: keyboardLocation.querySelector("[data-touche='LCtrl']"),
				RCtrl: keyboardLocation.querySelector("[data-touche='RCtrl']"),
				LAlt: keyboardLocation.querySelector("[data-touche='LAlt']"),
				RAlt: keyboardLocation.querySelector("[data-touche='RAlt']"),
				CapsLock: keyboardLocation.querySelector("[data-touche='CapsLock']"),
				Space: keyboardLocation.querySelector("[data-touche='Space']")
			};

			// Utility function to activate a key if it exists
			function activate(key) {
				if (keys[key] !== null) {
					keys[key].classList.add('pressed-key');
				}
			}

			// Mapping of keys to activate for each layer
			const layerMap = {
				Shift: ['LShift', 'RShift'],
				Ctrl: ['LCtrl'], // RCtrl is a special case
				AltGr: ['RAlt'],
				ShiftAltGr: ['LShift', 'RShift', 'RAlt'],
				CirconflexeShift: ['LShift', 'RShift'],
				TremaShift: ['LShift', 'RShift'],
				GreekShift: ['LShift', 'RShift']
			};

			// Activate keys for the current layer
			const keysToActivate = layerMap[layer];
			if (keysToActivate !== undefined) {
				for (const key of keysToActivate) {
					activate(key);
				}
			}

			// Special cases
			if (
				plus &&
				type === 'iso' &&
				['Shift', 'ShiftAltGr', 'CirconflexeShift', 'TremaShift', 'GreekShift'].includes(layer)
			) {
				activate('RCtrl');
			}

			if (layer === 'Ctrl') {
				if (plus) {
					activate('CapsLock');
				} else {
					activate('RCtrl');
				}
			}

			if (layer === 'Layer') {
				if (type === 'iso') {
					activate('LAlt');
				}
				if (type === 'ergodox') {
					activate('Space');
				}
			}
		} catch (error) {
			return;
		}
	}

	typeText(text, speed, makePreviousKeysDisappear) {
		const keyboardLocation = this.getKeyboardLocation();

		// Clear previously pressed keys
		const pressedKeys = keyboardLocation.querySelectorAll('.pressed-key');
		pressedKeys.forEach(function (el) {
			el.classList.remove('pressed-key');
		});

		function writeNext(i) {
			if (i >= text.length) return; // stop condition

			const nextLetter = text.charAt(i);
			const nextKey = keyboardLocation.querySelector(
				"bloc-touche[data-touche='" + nextLetter + "']"
			);

			if (nextKey) {
				nextKey.classList.add('pressed-key');
			}

			if (makePreviousKeysDisappear && i > 0) {
				const previousLetter = text.charAt(i - 1);
				const previousKey = keyboardLocation.querySelector(
					"bloc-touche[data-touche='" + previousLetter + "']"
				);
				if (previousKey) {
					previousKey.classList.remove('pressed-key');
				}
			}

			setTimeout(function () {
				writeNext(i + 1);
			}, speed);
		}

		writeNext(0);
	}
}
