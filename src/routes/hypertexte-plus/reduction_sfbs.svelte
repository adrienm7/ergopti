<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<section>
	<p>L’un des avantages majeurs de <NomPlus /> est qu’il réduit presque totalement les <SFB />s.</p>
	<p>
		Les <SFB />s les plus fréquents de la disposition sont : <kbd>SC</kbd>,
		<kbd>PT</kbd>, <kbd>EO</kbd>, <kbd>OE</kbd>,
		<kbd>UB</kbd>, <kbd>BU</kbd> et <kbd>GT</kbd>. <kbd>SC</kbd> est de loin le plus fréquent. En
		outre, <kbd>EO</kbd> et
		<kbd>OE</kbd> sont également relativement fréquents en anglais (pour écrire
		<kbd-sortie>DOES</kbd-sortie>,
		<kbd-sortie>PEOPLE</kbd-sortie>, etc.) Tous ces <SFB />s sont supprimés avec <NomPlus />, plus
		de nombreux autres encore moins fréquents.
	</p>

	<h3 data-aos="fade-right" data-aos-mirror="true">
		Utilisation de la touche <kbd>,</kbd> + <kbd>Consonne</kbd>
	</h3>
	<div class="content">
		<p>
			La touche <kbd>,</kbd> est l’une des plus importantes dans <NomPlus />. C’est grâce à elle la
			plupart des <SFB />s restants sont supprimés. De plus, certaines combinaisons ont aussi été
			ajoutées pour plus de confort, afin d’éviter de devoir sauter de 2 rangées avec des doigts
			consécutifs pour écrire un bigramme. C’est le cas de <kbd>CL</kbd> ou encore de <kbd>PH</kbd>.
		</p>
		<ul class="margin-top-2">
			<li><kbd>,C</kbd> ➜ <kbd-sortie>CD</kbd-sortie></li>
			<li><kbd>,D</kbd> ➜ <kbd-sortie>DS</kbd-sortie></li>
			<li><kbd>,F</kbd> ➜ <kbd-sortie>FS</kbd-sortie></li>
			<li><kbd>,G</kbd> ➜ <kbd-sortie>GL</kbd-sortie></li>
			<li><kbd>,H</kbd> ➜ <kbd-sortie>PH</kbd-sortie></li>
			<li><kbd>,L</kbd> ➜ <kbd-sortie>CL</kbd-sortie></li>
			<li><kbd>,M</kbd> ➜ <kbd-sortie>MPL</kbd-sortie></li>
			<li><kbd>,N</kbd> ➜ <kbd-sortie>NL</kbd-sortie></li>
			<li><kbd>,P</kbd> ➜ <kbd-sortie>XP</kbd-sortie></li>
			<li><kbd>,Q</kbd> ➜ <kbd-sortie>QU’</kbd-sortie></li>
			<li><kbd>,R</kbd> ➜ <kbd-sortie>RQ</kbd-sortie></li>
			<li><kbd>,S</kbd> ➜ <kbd-sortie>SC</kbd-sortie></li>
			<li><kbd>,T</kbd> ➜ <kbd-sortie>PT</kbd-sortie></li>
			<li><kbd>,V</kbd> ➜ <kbd-sortie>DV</kbd-sortie></li>
			<li><kbd>,X</kbd> ➜ <kbd-sortie>'RE</kbd-sortie></li>
			<li>
				<kbd>,Y</kbd> ➜ <kbd-sortie>YI</kbd-sortie> pour tous les
				<span class="hyper text-bold">YI</span>NG en anglais
			</li>
		</ul>
		<p>
			Comme vous pouvez le constater, la touche <kbd>,</kbd> est vraiment pour supprimer les
			derniers petits <SFB />s restants. La disposition <Nom /> éliminait déjà la majorité d’entre eux.
		</p>
	</div>
	<h3 data-aos="fade-right" data-aos-mirror="true">Utilisation de la touche <kbd>È</kbd></h3>
	<div class="content">
		<p>
			La touche <kbd>È</kbd> permet de se débarrasser des quelques <SFB />s en <kbd>E</kbd> et en
			<kbd>U</kbd> :
		</p>
		<ul class="margin-top-2">
			<li><kbd>ÈO</kbd> ➜ <kbd-sortie>EO</kbd-sortie></li>
			<li><kbd>ÈE</kbd> ➜ <kbd-sortie>OE</kbd-sortie></li>
			<li><kbd>UÈ</kbd> ➜ <kbd-sortie>UB</kbd-sortie></li>
			<li><kbd>È,</kbd> ➜ <kbd-sortie>U,</kbd-sortie></li>
			<li><kbd>È.</kbd> ➜ <kbd-sortie>U.</kbd-sortie></li>
		</ul>
	</div>
	<h3 data-aos="fade-right" data-aos-mirror="true">Utilisation de roulements</h3>
	<div class="content">
		<ul class="margin-top-2">
			<li><kbd>ÊÉ</kbd> ➜ <kbd-sortie>IÉ</kbd-sortie></li>
			<li><kbd>ÉÊ</kbd> ➜ <kbd-sortie>ÉI</kbd-sortie></li>
			<li><kbd>GX</kbd> ➜ <kbd-sortie>GT</kbd-sortie></li>
		</ul>
		<p>
			Le bigramme <kbd>GT</kbd> est remplacé par le roulement <kbd>GX</kbd>. Ce roulement est très
			confortable et plus judicieux que l’utilisation d’une combinaison avec la touche <kbd>,</kbd>,
			car réaliser <kbd>NGT</kbd> devient alors très rapide. Cependant, ce roulement empêche dans le
			même temps d’écrire normalement <kbd-sortie>GX</kbd-sortie> (par exemple pour écrire "Yu-Gi-Oh
			GX"). Les autres remplacements sont quant à eux sur des combinaisons qui ne sont a priori jamais
			réalisées.
		</p>
	</div>
</section>
