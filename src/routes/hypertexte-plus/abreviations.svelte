<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<div class="accordion">
	<section>
		<input type="checkbox" name="acc" id="acc1" />
		<label for="acc1">
			<span class="numero-faq" />
			<h3 data-aos="zoom-out" data-aos-mirror="true">Remplacement de texte avec <kbd>★</kbd></h3>
		</label>
		<div class="content">
			<p>
				La touche <kbd>★</kbd> va normalement répéter la dernière touche frappée. Toutefois, dans le
				cas où l’abréviation existe dans votre liste, alors elle sera envoyée à la place. Ainsi,
				<kbd>★R</kbd>
				envoie le raccourci « Rien », tandis que <kbd>AR★IVER</kbd> enverra <kbd>ARRIVER</kbd>.
			</p>
			<p>Liste de quelques-unes :</p>

			<ul>
				<li><kbd>A★</kbd> ➜ <kbd-sortie>AINSI</kbd-sortie></li>
				<li><kbd>AVV★</kbd> ➜ <kbd-sortie>AVEZ-VOUS</kbd-sortie></li>
				<li><kbd>C★</kbd> ➜ <kbd-sortie>C’EST</kbd-sortie></li>
				<li><kbd>CT★</kbd> ➜ <kbd-sortie>C’ÉTAIT</kbd-sortie></li>
				<li><kbd>D★</kbd> ➜ <kbd-sortie>DONC</kbd-sortie></li>
				<li><kbd>DÉ★</kbd> ➜ <kbd-sortie>DÉJÀ</kbd-sortie></li>
				<li><kbd>Ê★</kbd> ➜ <kbd-sortie>ÊTRE</kbd-sortie></li>
				<li><kbd>EEF★</kbd> ➜ <kbd-sortie>EN EFFET</kbd-sortie></li>
				<li><kbd>F★</kbd> ➜ <kbd-sortie>FAIRE</kbd-sortie></li>
				<li><kbd>G★</kbd> ➜ <kbd-sortie>J’AI</kbd-sortie></li>
				<li><kbd>GT★</kbd> ➜ <kbd-sortie>J’ÉTAIS</kbd-sortie></li>
				<li><kbd>M★</kbd> ➜ <kbd-sortie>MAIS</kbd-sortie></li>
				<li><kbd>PCQ★</kbd> ➜ <kbd-sortie>PARCE QUE</kbd-sortie></li>
				<li><kbd>PÊ★</kbd> ➜ <kbd-sortie>PEUT-ÊTRE</kbd-sortie></li>
				<li><kbd>PEX★</kbd> ➜ <kbd-sortie>PAR EXEMPLE</kbd-sortie></li>
				<li><kbd>R★</kbd> ➜ <kbd-sortie>RIEN</kbd-sortie></li>
			</ul>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc2" />
		<label for="acc2">
			<span class="numero-faq" />
			<h3 data-aos="zoom-out" data-aos-mirror="true">
				Ajout des suffixes les plus communs en <kbd>,</kbd>
			</h3>
		</label>
		<div class="content">
			<p>
				Il y a toujours un espace après la virgule (sauf si l’on écrit des nombres). Par conséquent,
				toute combinaison de type <kbd-non>,S</kbd-non> ou <kbd-non>,C</kbd-non> n’est jamais tapée.
				Cela donne une opportunité extraordinaire de raccourcis pour augmenter sa vitesse et son
				confort de frappe. Par exemple, au lieu de taper 5 lettres pour écrire le suffixe
				<kbd-sortie>EMENT</kbd-sortie>, très souvent utilisé en français, deux frappes suffisent :
				<kbd>,S</kbd>. Ces raccourcis vont diviser par deux le nombre de touches nécessaires pour
				écrire les suffixes les plus communs, entrainant une petite augmentation de vitesse.
			</p>
			<p>
				Le confort est aussi visé, par exemple pour la combinaison <em>GHT</em> qui est un peu
				inconfortable à faire en <Nom />, car il faut frapper de l’annulaire droit, du majeur droit,
				puis encore de l’annulaire droit. Ce n’est pas un beau roulement, alors qu’au contraire
				<kbd>,I</kbd>
				écrira <kbd-sortie>IGHT</kbd-sortie> et <kbd>,O</kbd> écrira <kbd-sortie>OUGH</kbd-sortie>.
			</p>
			<p>
				Enfin, notons que <kbd-sortie>SC</kbd-sortie> est présent en <kbd>,C</kbd>. En effet, cette
				position est parfaite pour ensuite enchaîner avec le <kbd>H</kbd> ou le <kbd>R</kbd>.
			</p>

			<ul>
				<li><kbd>,A</kbd> ➜ <kbd-sortie>ABLE</kbd-sortie></li>
				<li><kbd>,B</kbd> ➜ Rien, pour éviter un <SFB /></li>
				<li><kbd>,C</kbd> ➜ <kbd-sortie>SC</kbd-sortie></li>
				<li><kbd>,D</kbd> ➜ <kbd-sortie>WOULD</kbd-sortie></li>
				<li><kbd>,E</kbd> ➜ <kbd-sortie>THE</kbd-sortie></li>
				<li><kbd>,É</kbd> ➜ Rien, pour éviter un <SFB /></li>
				<li><kbd>,È</kbd> ➜ <kbd-sortie>ÈRE</kbd-sortie></li>
				<li><kbd>,Ê</kbd> ➜ <kbd-sortie>ÊTRE</kbd-sortie></li>
				<li><kbd>,F</kbd> ➜ <kbd-sortie>ENCE</kbd-sortie></li>
				<li><kbd>,G</kbd> ➜ <kbd-sortie>RING</kbd-sortie></li>
				<li><kbd>,H</kbd> ➜ <kbd-sortie>TECHN</kbd-sortie></li>
				<li><kbd>,I</kbd> ➜ <kbd-sortie>IGHT</kbd-sortie></li>
				<li><kbd>,J</kbd> ➜ <kbd-sortie>TOUJOURS</kbd-sortie></li>
				<li><kbd>,K</kbd> ➜ Rien, pour éviter un <SFB /></li>
				<li><kbd>,L</kbd> ➜ <kbd-sortie>ELLE</kbd-sortie></li>
				<li><kbd>,M</kbd> ➜ <kbd-sortie>EMENTS</kbd-sortie></li>
				<li><kbd>,N</kbd> ➜ <kbd-sortie>ATION</kbd-sortie></li>
				<li><kbd>,O</kbd> ➜ <kbd-sortie>OUGH</kbd-sortie></li>
				<li><kbd>,P</kbd> ➜ <kbd-sortie>MPL</kbd-sortie></li>
				<li><kbd>,Q</kbd> ➜ <kbd-sortie>IQUE</kbd-sortie></li>
				<li><kbd>,R</kbd> ➜ <kbd-sortie>ERRE</kbd-sortie></li>
				<li><kbd>,S</kbd> ➜ <kbd-sortie>EMENT</kbd-sortie></li>
				<li><kbd>,T</kbd> ➜ <kbd-sortie>CTION</kbd-sortie></li>
				<li><kbd>,U</kbd> ➜ Rien, pour éviter un <SFB /></li>
				<li><kbd>,V</kbd> ➜ <kbd-sortie>ANCE</kbd-sortie></li>
				<li><kbd>,W</kbd> ➜ Rien, pour éviter un <SFB /></li>
				<li><kbd>,X</kbd> ➜ <kbd-sortie>IEUX</kbd-sortie></li>
				<li><kbd>,Y</kbd> ➜ <kbd-sortie>YING</kbd-sortie></li>
				<li><kbd>,Z</kbd> ➜ <kbd-sortie>EZ-VOUS</kbd-sortie></li>
				<li><kbd>,’</kbd> ➜ <kbd-sortie>QU’</kbd-sortie></li>
			</ul>
		</div>
	</section>
</div>
