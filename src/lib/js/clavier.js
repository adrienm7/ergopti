export function majClavier({ emplacement, data, config }) {
	const typeClavier = config.type;
	const coucheClavier = config.couche;
	const couleurClavier = config.couleur;
	const plusClavier = config.plus;
	const controlesClavier = config.controles;

	document.getElementById(emplacement).dataset.type = typeClavier;
	document.getElementById(emplacement).dataset.couche = coucheClavier;
	document.getElementById(emplacement).dataset.couleur = couleurClavier;
	document.getElementById(emplacement).dataset.plus = plusClavier;
	// document.getElementById(emplacement).style.setProperty('--frequence-max', mayzner['max']);
	for (let i = 1; i <= 5; i++) {
		for (let j = 0; j <= 15; j++) {
			const toucheClavier = document
				.getElementById(emplacement)
				.querySelector("[data-ligne='" + i + "'][data-colonne='" + j + "']");
			toucheClavier.dataset.touche = ''; // On nettoie le contenu de la touche
			const res = data[typeClavier].find((el) => (el.ligne == i) & (el.colonne == j));
			// console.log(res);
			if (res !== undefined) {
				const touche = data.touches.find((el) => el.touche == res.touche);
				if (touche[coucheClavier] === '') {
					toucheClavier.getElementsByTagName('div')[0].innerHTML = ' ';
				} else {
					if (coucheClavier == 'Visuel') {
						if (touche.type == 'double') {
							if (res.touche == '"') {
								toucheClavier.getElementsByTagName('div')[0].innerHTML =
									touche['Shift'] + '<br/>' + touche['Primary'];
							} else {
								toucheClavier.getElementsByTagName('div')[0].innerHTML =
									touche['AltGr'] + '<br/>' + touche['Primary'];
							}
						} else {
							if (plusClavier) {
								if (touche['Primary' + '+'] !== undefined) {
									toucheClavier.getElementsByTagName('div')[0].innerHTML = touche['Primary' + '+'];
								} else {
									toucheClavier.getElementsByTagName('div')[0].innerHTML = touche['Primary'];
								}
							} else {
								toucheClavier.getElementsByTagName('div')[0].innerHTML = touche['Primary'];
							}
						}
					} else {
						if (plusClavier) {
							if (touche[coucheClavier + '+'] !== undefined) {
								toucheClavier.getElementsByTagName('div')[0].innerHTML =
									touche[coucheClavier + '+'];
							} else {
								toucheClavier.getElementsByTagName('div')[0].innerHTML = touche[coucheClavier];
							}
						} else {
							toucheClavier.getElementsByTagName('div')[0].innerHTML = touche[coucheClavier];
						}
					}
				}
				toucheClavier.dataset.touche = res.touche;
				toucheClavier.dataset.colonne = j;
				toucheClavier.dataset.doigt = res.doigt;
				toucheClavier.dataset.main = res.main;
				toucheClavier.dataset.type = touche.type;
				toucheClavier.style.setProperty('--taille', res.taille);
				toucheClavier.style.setProperty('--frequence', mayzner[res.touche] / mayzner['max']);
				toucheClavier.style.setProperty(
					'--frequence-log',
					Math.log(mayzner[res.touche] / mayzner['max'])
				);
			}
		}
	}

	/* La couche active a ses modificateurs pressés */
	toggle_couche(emplacement, coucheClavier);

	if (controlesClavier) {
		/* Il n’y a les touches pour changer de couche que quand il y a les contrôles pour changer de couche */
		boutons_changer_couche(emplacement, data, config);
	}

	document.getElementById(emplacement).querySelector('select').value = coucheClavier;
}

function boutons_changer_couche(emplacement, data, config) {
	let emplacementClavier = document.getElementById(emplacement);
	let toucheRAlt = emplacementClavier.querySelector("bloc-touche[data-touche='RAlt']");
	let toucheLShift = emplacementClavier.querySelector("bloc-touche[data-touche='LShift']");
	let toucheRShift = emplacementClavier.querySelector("bloc-touche[data-touche='RShift']");
	let toucheSpace = emplacementClavier.querySelector("bloc-touche[data-touche='Space']");
	let toucheA = emplacementClavier.querySelector("bloc-touche[data-touche='à']");

	for (let toucheClavier of [toucheRAlt, toucheLShift, toucheRShift, toucheSpace, toucheA]) {
		toucheClavier.addEventListener('click', function () {
			let couche = config.couche;

			if ((toucheClavier.dataset.touche == 'RAlt') & (couche == 'Shift')) {
				couche = 'ShiftAltGr';
			} else if ((toucheClavier.dataset.touche == 'RAlt') & (couche == 'AltGr')) {
				couche = 'Visuel';
			} else if ((toucheClavier.dataset.touche == 'RAlt') & (couche == 'ShiftAltGr')) {
				couche = 'Shift';
			} else if (toucheClavier.dataset.touche == 'RAlt') {
				couche = 'AltGr';
			}

			if (
				((toucheClavier.dataset.touche == 'LShift') | (toucheClavier.dataset.touche == 'RShift')) &
				(couche == 'AltGr')
			) {
				couche = 'ShiftAltGr';
			} else if (
				((toucheClavier.dataset.touche == 'LShift') | (toucheClavier.dataset.touche == 'RShift')) &
				(couche == 'Shift')
			) {
				couche = 'Visuel';
			} else if (
				((toucheClavier.dataset.touche == 'LShift') | (toucheClavier.dataset.touche == 'RShift')) &
				(couche == 'ShiftAltGr')
			) {
				couche = 'AltGr';
			} else if (
				(toucheClavier.dataset.touche == 'LShift') |
				(toucheClavier.dataset.touche == 'RShift')
			) {
				couche = 'Shift';
			}

			if ((toucheClavier.dataset.touche == 'Space') & (couche == 'layer')) {
				couche = 'Visuel';
			} else if (toucheClavier.dataset.touche == 'Space') {
				console.log(couche);
				couche = 'layer';
			}

			if ((toucheClavier.dataset.touche == 'à') & (couche == 'à')) {
				couche = 'Visuel';
			} else if (toucheClavier.dataset.touche == 'à') {
				couche = 'à';
			}

			majClavier({
				emplacement: emplacement,
				data: data,
				config: {
					type: config.type,
					couche: couche,
					couleur: config.couleur,
					plus: config.plus,
					controles: config.controles
				}
			});
		});
	}
}

function toggle_couche(emplacement, couche) {
	let shift1 = document.getElementById(emplacement).querySelector("[data-touche='LShift']");
	let shift2 = document.getElementById(emplacement).querySelector("[data-touche='RShift']");
	let altgr = document.getElementById(emplacement).querySelector("[data-touche='RAlt']");
	let a_grave = document.getElementById(emplacement).querySelector("[data-touche='à']");
	let space = document.getElementById(emplacement).querySelector("[data-touche='Space']");

	/* On enlève tout, puis on remet le bon */
	shift1.classList.remove('touche-active');
	shift2.classList.remove('touche-active');
	altgr.classList.remove('touche-active');
	a_grave.classList.remove('touche-active');
	space.classList.remove('touche-active');

	if (couche == 'Shift') {
		shift1.classList.add('touche-active');
		shift2.classList.add('touche-active');
	} else if (couche == 'AltGr') {
		altgr.classList.add('touche-active');
	} else if (couche == 'ShiftAltGr') {
		shift1.classList.add('touche-active');
		shift2.classList.add('touche-active');
		altgr.classList.add('touche-active');
	} else if (couche == 'à') {
		a_grave.classList.add('touche-active');
	} else if (couche == 'layer') {
		space.classList.add('touche-active');
	}
}
var mayzner = {
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
