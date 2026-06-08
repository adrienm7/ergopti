<span class="nowrap texte-sfb">
	<span class="tooltip">
		SFB
		<span class="tooltiptext">
			« Same Finger Bigram », c’est-à-dire nécessiter le même doigt pour taper deux lettres qui se
			suivent. Par exemple, en AZERTY un SFB serait <kbd>UN</kbd> qui implique d’utiliser l’index droit
			pour appuyer successivement sur ces deux touches. Et pourtant, cette combinaison est si fréquente
			en français…
		</span>
	</span>
</span>

<style>
	.texte-sfb {
		display: inline;
		width: fit-content;
	}

	.tooltip {
		border-bottom: 2px dotted white;
		display: inline-block;
		white-space: normal;
	}

	.tooltip .tooltiptext {
		/* Enlève les dégradés de texte */
		background-clip: unset;
		background-color: rgba(0, 13, 27, 0.95);
		border: 1px solid rgba(255, 255, 255, 0.2);
		border-radius: 8px;
		box-shadow: rgba(0, 0, 0, 0.35) 0px 5px 15px;
		color: white;
		display: inline-block;
		font-size: 1rem;
		font-weight: normal;
		line-height: 1.35;
		max-width: 600px;
		padding: 20px;
		position: relative;
		visibility: hidden;
		width: 90%;
		z-index: 2;
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
