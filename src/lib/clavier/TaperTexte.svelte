<script>
	function taperTexte(texte, vitesse, disparition_anciennes_touches) {
		let emplacementClavier = document.getElementById(emplacementValue);

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
	}

	let texte;
	let roulements_voyelles = ['ai', 'ie', 'eu', 'io', 'ou', 'oi', 'au', 'aie', 'ieu', 'you'];
	let roulements_consonnes = ['ch', 'pl', 'ld'];
</script>
