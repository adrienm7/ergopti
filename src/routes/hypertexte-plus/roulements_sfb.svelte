<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<p>L’un des avantages majeurs de <NomPlus /> est qu’il réduit presque à 0 les <SFB />s.</p>
<p>
	Les <SFB />s les plus fréquents de la disposition sont : <kbd>SC</kbd>,
	<kbd>PT</kbd>, <kbd>EO</kbd>, <kbd>OE</kbd>,
	<kbd>UB</kbd>, <kbd>BU</kbd> et <kbd>GT</kbd>. <kbd>SC</kbd> étant de loin celui apparaissant le
	plus. En outre, <kbd>EO</kbd> et
	<kbd>OE</kbd> sont relativement fréquents en anglais (pour écrire <kbd-sortie>DOES</kbd-sortie>,
	<kbd-sortie>PEOPLE</kbd-sortie>, etc.) Tous ces <SFB />s seront supprimés, plus de nombreux autres
	encore moins fréquents.
</p>
<petit-espace />
<div class="accordion">
	<section>
		<input type="checkbox" name="acc" id="acc41" />
		<label for="acc41">
			<span class="numero-faq" />
			<h3 data-aos="zoom-out" data-aos-mirror="true">
				Ajout d’excellents roulements et suppression des <SFB />s majeurs
			</h3>
		</label>
		<div class="content">
			<p>
				<kbd-sortie>SC</kbd-sortie> est remplacé par le racccourci <kbd>,C</kbd> et d’autres <SFB
				/>s parmi les plus fréquents se font par roulements :
			</p>
			<ul class="margin-top-2">
				<li><kbd>P’</kbd> ➜ <kbd-sortie>PT</kbd-sortie></li>
				<li><kbd>GX</kbd> ➜ <kbd-sortie>GT</kbd-sortie></li>
			</ul>

			<mini-espace />

			<p>En outre, des roulements pour plus de confort sont ajoutés :</p>
			<ul class="margin-top-2">
				<li><kbd>HC</kbd> ➜ <kbd-sortie>WH</kbd-sortie></li>
				<li><kbd>’P</kbd> ➜ <kbd-sortie>XP</kbd-sortie></li>
			</ul>

			<mini-espace />
			<p>
				Le roulement <kbd>CH</kbd> était déjà l’un des atouts majeur de la disposition <Nom />, car
				cette combinaison est très fréquente et ce roulement la rend extrêmement confortable.
				L’ajout de ce roulement <kbd>WH</kbd> est
			</p>
			<p>
				Encore une fois, ces roulements améliorent beaucoup l’expérience de frappe dans la majorité
				du temps. Cependant, parfois vous voudrez écrire <kbd>GX</kbd> (par exemple pour écrire
				Yu-Gi-Oh GX) et vous ne pourrez pas car <kbd>GX</kbd> se transformera en
				<kbd-non>GT</kbd-non>. À vous de voir si vous voulez supprimer certains raccourcis, les
				modifier ou créer d’autres raccourcis pour écrire <kbd>GX</kbd> d’une autre manière.
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc42" />
		<label for="acc42">
			<span class="numero-faq" />
			<h3 data-aos="zoom-out" data-aos-mirror="true">
				Utilisation de la touche <kbd>À</kbd> + <kbd>Consonne</kbd>
			</h3>
		</label>
		<div class="content">
			<p>
				La touche <kbd>À</kbd> est l’une des plus importantes dans <NomPlus />. C’est grâce à elle
				que tous les autres <SFB />s, en dehors de ceux supprimés grâce à des roulements, sont
				supprimés. De plus, certaines des combinaisons sont aussi pour plus de confort, en évitant
				de dovoir sauter 3 lignes entre chaque lettre comme pour <kbd>PH</kbd>.
			</p>
			<ul class="margin-top-2">
				<li><kbd>ÀB</kbd> ➜ <kbd-sortie>BÉ</kbd-sortie></li>
				<li><kbd>ÀC</kbd> ➜ <kbd-sortie>CD</kbd-sortie></li>
				<li><kbd>ÀD</kbd> ➜ <kbd-sortie>DS</kbd-sortie></li>
				<li><kbd>ÀF</kbd> ➜ <kbd-sortie>SF</kbd-sortie></li>
				<li><kbd>ÀG</kbd> ➜ <kbd-sortie>GL</kbd-sortie></li>
				<li><kbd>ÀH</kbd> ➜ <kbd-sortie>NH</kbd-sortie></li>
				<li><kbd>ÀL</kbd> ➜ <kbd-sortie>CL</kbd-sortie></li>
				<li><kbd>ÀM</kbd> ➜ <kbd-sortie>SM</kbd-sortie></li>
				<li><kbd>ÀN</kbd> ➜ <kbd-sortie>NL</kbd-sortie></li>
				<li><kbd>ÀP</kbd> ➜ <kbd-sortie>PH</kbd-sortie></li>
				<li><kbd>ÀQ</kbd> ➜ <kbd-sortie>RQ</kbd-sortie></li>
				<li><kbd>ÀR</kbd> ➜ <kbd-sortie>CF.</kbd-sortie></li>
				<li><kbd>ÀS</kbd> ➜ <kbd-sortie>CS</kbd-sortie></li>
				<li><kbd>ÀT</kbd> ➜ <kbd-sortie>TP</kbd-sortie></li>
				<li><kbd>ÀV</kbd> ➜ <kbd-sortie>ADV</kbd-sortie></li>
				<li><kbd>ÀW</kbd> ➜ <kbd-sortie>JA</kbd-sortie></li>
				<li><kbd>ÀX</kbd> ➜ <kbd-sortie>ADM</kbd-sortie></li>
				<li><kbd>À,</kbd> ➜ <kbd-sortie>U,</kbd-sortie></li>
				<li><kbd>À.</kbd> ➜ <kbd-sortie>U.</kbd-sortie></li>
			</ul>
			<p>
				Comme vous pouvez le constater, la touche <kbd>À</kbd> est vraiment pour supprimer les
				derniers petits <SFB />s restants. Sans utiliser cette touche, vous aurez déjà éliminé la
				majorité d’entre eux.
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc43" />
		<label for="acc43">
			<span class="numero-faq" />
			<h3 data-aos="zoom-out" data-aos-mirror="true">
				Utilisation de la touche <kbd>È</kbd> + <kbd>Voyelle</kbd>
			</h3>
		</label>
		<div class="content">
			<p>
				La touche <kbd>È</kbd> est souvent suivie et précédée d’autres lettres en français, il n’y a
				donc pas beaucoup de combinaisons disponibles. Toutefois, les combinaisons <kbd>È</kbd> +
				<kbd>Voyelle</kbd> n’existent pas et peuvent donc être utilisées :
			</p>
			<ul class="margin-top-2">
				<li>
					<kbd>ÈE</kbd> ➜ <kbd-sortie>EO</kbd-sortie> et <kbd>EÈ</kbd> ➜ <kbd-sortie>OE</kbd-sortie>
				</li>
				<li>
					<kbd>ÈÉ</kbd> ➜ <kbd-sortie>BU</kbd-sortie> et <kbd>ÉÈ</kbd> ➜ <kbd-sortie>UB</kbd-sortie>
				</li>
				<li><kbd>ÈÊ</kbd> ➜ <kbd-sortie>YI</kbd-sortie></li>
				<li><kbd>UÈ</kbd> ➜ <kbd-sortie>UÉ</kbd-sortie></li>
				<li><kbd>ÈU</kbd> ➜ <kbd-sortie>ÉU</kbd-sortie></li>
			</ul>
		</div>
	</section>
</div>
