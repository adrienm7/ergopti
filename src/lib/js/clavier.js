export function majClavier({ emplacement, data, typeClavier, couche, couleur }) {
	document.getElementById(emplacement).dataset.type = typeClavier;
	document.getElementById(emplacement).dataset.couleur = couleur;
	// document.getElementById(emplacement).style.setProperty('--frequence-max', mayzner['max']);
	for (let i = 1; i <= 5; i++) {
		for (let j = 0; j <= 15; j++) {
			const toucheClavier = document
				.getElementById(emplacement)
				.querySelector("[data-ligne='" + i + "'][data-colonne='" + j + "']");
			toucheClavier.dataset.touche = ''; // On nettoie le contenu de la touche
			const res = data[typeClavier].find((el) => (el.ligne == i) & (el.colonne == j));
			console.log(res);
			if (res !== undefined) {
				const touche = data.touches.find((el) => el.touche == res.touche);
				if (touche[couche] === '') {
					toucheClavier.innerHTML = '<div> </div>';
				} else {
					if (couche == 'Visuel') {
						if (touche.type == 'double') {
							toucheClavier.innerHTML =
								'<div>' +
								touche['Shift'].toUpperCase() +
								'<br/>' +
								touche['Primary'].toUpperCase() +
								'</div>';
						} else {
							toucheClavier.innerHTML = '<div>' + touche['Primary'].toUpperCase() + '</div>';
						}
					} else {
						toucheClavier.innerHTML = touche[couche];
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
