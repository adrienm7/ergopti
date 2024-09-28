<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<section>
	<h3 data-aos="fade-right" data-aos-mirror="true">Touche <kbd>★</kbd> de répétition</h3>
	<div class="content">
		<p>
			De nombreux <SFB />s se produisent non pas à cause de deux touches devant être tapées par le
			même doigt, mais aussi lors de la répétition de la même touche. C’est par exemple le cas avec
			<kbd>LL</kbd>
			(elle, pelle, telle, etc.) ou encore <kbd>RR</kbd> (terre, erreur, etc.).
		</p>
		<p>
			En Excel, la touche <kbd>F4</kbd> permet de répéter la dernière action. De la même manière, la
			touche <kbd>★</kbd> va répéter la dernière touche tapée. Ainsi, <kbd>L★</kbd> va envoyer
			<kbd>LL</kbd>, tandis que <kbd>R★</kbd> va envoyer <kbd>RR</kbd>. L’utilisation de cette
			touche va instantanément fluidifier la fra<kbd>p★</kbd>e et réduire le nombre de <SFB />s.
		</p>
	</div>
	<h3 data-aos="fade-right" data-aos-mirror="true">Remplacement de texte avec <kbd>★</kbd></h3>
	<div class="content">
		<p>
			La touche <kbd>★</kbd> va normalement répéter dernière touche tapée. Cependant, dans le cas où
			l’abréviation existe dans votre liste, alors elle sera envoyée à la place. Ainsi,
			<kbd>r★</kbd>
			envoie le raccourci <kbd-sortie>rien</kbd-sortie>, tandis que <kbd>AR★IVER</kbd> enverra
			<kbd-sortie>ARRIVER</kbd-sortie>.
		</p>
		<p>Liste de quelques-unes de ces abréviations :</p>
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

	<h3 data-aos="fade-right" data-aos-mirror="true">
		Ajout des suffixes les plus communs en <kbd>À</kbd>
	</h3>
	<div class="content">
		<p>
			Il y a toujours un espace après un À, car les deux seuls mots l’utilisant sont <kbd-sortie
				>à</kbd-sortie
			>
			et <kbd-sortie>déjà</kbd-sortie>. Par conséquent, toute combinaison de type <kbd>ÀS</kbd> ou
			<kbd>ÀC</kbd> n’est jamais tapée. Cela donne une opportunité extraordinaire de raccourcis pour
			augmenter sa vitesse et son confort de frappe. Par exemple, au lieu de taper 5 lettres pour
			écrire le suffixe
			<kbd-sortie>EMENT</kbd-sortie>, très souvent utilisé en français, deux frappes suffisent :
			<kbd>ÀS</kbd>. Ces raccourcis vont diviser par deux le nombre de touches nécessaires pour
			écrire les suffixes les plus communs, entraînant une petite augmentation de vitesse.
		</p>
		<p>
			Le confort est aussi visé, par exemple pour la combinaison <em>GHT</em> qui est un peu
			inconfortable à faire en <Nom />, car il faut frapper de l’annulaire droit, du majeur droit,
			puis encore de l’annulaire droit. Ce n’est pas un beau roulement, alors qu’au contraire
			<kbd>ÀI</kbd>
			écrira <kbd-sortie>IGHT</kbd-sortie> et <kbd>ÀO</kbd> écrira <kbd-sortie>OUGH</kbd-sortie>.
		</p>
		<p>
			Enfin, notons que <kbd-sortie>SC</kbd-sortie> est présent en <kbd>ÀC</kbd>. En effet, cette
			position est parfaite pour ensuite enchaîner avec le <kbd>H</kbd> ou le <kbd>R</kbd>.
		</p>

		<ul>
			<li><kbd>ÀA</kbd> ➜ <kbd-sortie>ABLE</kbd-sortie></li>
			<li><kbd>ÀB</kbd> ➜ Rien, pour éviter un <SFB /></li>
			<li><kbd>ÀC</kbd> ➜ <kbd-sortie>SC</kbd-sortie></li>
			<li><kbd>ÀD</kbd> ➜ <kbd-sortie>WOULD</kbd-sortie></li>
			<li><kbd>ÀE</kbd> ➜ <kbd-sortie>THE</kbd-sortie></li>
			<li><kbd>ÀÉ</kbd> ➜ Rien, pour éviter un <SFB /></li>
			<li><kbd>ÀÈ</kbd> ➜ <kbd-sortie>ÈRE</kbd-sortie></li>
			<li><kbd>ÀÊ</kbd> ➜ <kbd-sortie>ÊTRE</kbd-sortie></li>
			<li><kbd>ÀF</kbd> ➜ <kbd-sortie>ENCE</kbd-sortie></li>
			<li><kbd>ÀG</kbd> ➜ <kbd-sortie>RING</kbd-sortie></li>
			<li><kbd>ÀH</kbd> ➜ <kbd-sortie>TECHN</kbd-sortie></li>
			<li><kbd>ÀI</kbd> ➜ <kbd-sortie>IGHT</kbd-sortie></li>
			<li><kbd>ÀJ</kbd> ➜ <kbd-sortie>TOUJOURS</kbd-sortie></li>
			<li><kbd>ÀK</kbd> ➜ Rien, pour éviter un <SFB /></li>
			<li><kbd>ÀL</kbd> ➜ <kbd-sortie>ELLE</kbd-sortie></li>
			<li><kbd>ÀM</kbd> ➜ <kbd-sortie>EMENTS</kbd-sortie></li>
			<li><kbd>ÀN</kbd> ➜ <kbd-sortie>ATION</kbd-sortie></li>
			<li><kbd>ÀO</kbd> ➜ <kbd-sortie>OUGH</kbd-sortie></li>
			<li><kbd>ÀP</kbd> ➜ <kbd-sortie>MPL</kbd-sortie></li>
			<li><kbd>ÀQ</kbd> ➜ <kbd-sortie>IQUE</kbd-sortie></li>
			<li><kbd>ÀR</kbd> ➜ <kbd-sortie>ERRE</kbd-sortie></li>
			<li><kbd>ÀS</kbd> ➜ <kbd-sortie>EMENT</kbd-sortie></li>
			<li><kbd>ÀT</kbd> ➜ <kbd-sortie>CTION</kbd-sortie></li>
			<li><kbd>ÀU</kbd> ➜ <kbd-sortie>OUGH</kbd-sortie></li>
			<li><kbd>ÀV</kbd> ➜ <kbd-sortie>ANCE</kbd-sortie></li>
			<li><kbd>ÀW</kbd> ➜ Rien, pour éviter un <SFB /></li>
			<li><kbd>ÀX</kbd> ➜ <kbd-sortie>IEUX</kbd-sortie></li>
			<li><kbd>ÀY</kbd> ➜ <kbd-sortie>YING</kbd-sortie></li>
			<li><kbd>ÀZ</kbd> ➜ <kbd-sortie>EZ-VOUS</kbd-sortie></li>
			<li><kbd>À’</kbd> ➜ <kbd-sortie>QU’</kbd-sortie></li>
		</ul>
	</div>
</section>
