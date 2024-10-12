<texte-sfb class="nowrap">
	<div class="tooltip">
		SFB
		<div class="tooltiptext">
			« Same Finger Bigram », c’est-à-dire nécessiter le même doigt pour taper deux lettres qui se
			suivent. Par exemple, cela peut être utiliser l’index droit pour taper <span class="nowrap"
				><kbd>SC</kbd>,</span
			>
			car
			<kbd>S</kbd> et <kbd>C</kbd> sont tous deux sur la colonne de ce doigt dans la disposition
			HyperTexte. Un autre exemple en AZERTY de SFB sur ce même doigt est <kbd>UN</kbd> (qui est pourtant
			tellement fréquent en français…)
		</div>
	</div>
</texte-sfb>

<style>
	.tooltip {
		display: inline-block;
		border-bottom: 2px dotted black;
		white-space: normal;
	}

	.tooltip .tooltiptext {
		visibility: hidden;
		width: 90%;
		background-color: black;
		border: 1px solid rgba(255, 255, 255, 0.2);
		color: white;
		border-radius: 8px;
		padding: 20px;
		font-size: 1rem;
		font-weight: normal;
		line-height: 1.35;
		box-shadow: rgba(0, 0, 0, 0.35) 0px 5px 15px;

		/* Enlève les dégradés de texte */
		background-clip: unset;
		-webkit-text-fill-color: white;

		/* Position the tooltip */
		position: absolute;
		right: 50%;
		transform: translate(50%, 0);
	}

	.tooltip:hover .tooltiptext {
		visibility: visible;
	}
</style>
