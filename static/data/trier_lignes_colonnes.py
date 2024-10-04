import json

data = {
		"iso": [
		{
			"touche": "=",
			"code": "Backquote",
			"main": "gauche",
			"doigt": "auriculaire",
			"ligne": "1",
			"colonne": "1",
			"taille": "1"
		},
		{
			"touche": "1",
			"code": "Digit1",
			"main": "gauche",
			"doigt": "auriculaire",
			"ligne": "1",
			"colonne": "2",
			"taille": "1"
		},
		{
			"touche": "2",
			"code": "Digit2",
			"main": "gauche",
			"doigt": "annulaire",
			"ligne": "1",
			"colonne": "3",
			"taille": "1"
		},
		{
			"touche": "3",
			"code": "Digit3",
			"main": "gauche",
			"doigt": "majeur",
			"ligne": "1",
			"colonne": "4",
			"taille": "1"
		},
		{
			"touche": "4",
			"code": "Digit4",
			"main": "gauche",
			"doigt": "index",
			"ligne": "1",
			"colonne": "5",
			"taille": "1"
		},
		{
			"touche": "5",
			"code": "Digit5",
			"main": "gauche",
			"doigt": "index",
			"ligne": "1",
			"colonne": "6",
			"taille": "1"
		},
		{
			"touche": "6",
			"code": "Digit6",
			"main": "droite",
			"doigt": "index",
			"ligne": "1",
			"colonne": "8",
			"taille": "1"
		},
		{
			"touche": "7",
			"code": "Digit7",
			"main": "droite",
			"doigt": "index",
			"ligne": "1",
			"colonne": "9",
			"taille": "1"
		},
		{
			"touche": "8",
			"code": "Digit8",
			"main": "droite",
			"doigt": "majeur",
			"ligne": "1",
			"colonne": "10",
			"taille": "1"
		},
		{
			"touche": "9",
			"code": "Digit9",
			"main": "droite",
			"doigt": "annulaire",
			"ligne": "1",
			"colonne": "11",
			"taille": "1"
		},
		{
			"touche": "0",
			"code": "Digit0",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "1",
			"colonne": "12",
			"taille": "1"
		},
		{
			"touche": "%",
			"code": "Minus",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "1",
			"colonne": "13",
			"taille": "1"
		},
		{
			"touche": "\u20ac",
			"code": "Equal",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "1",
			"colonne": "14",
			"taille": "1"
		},
		{
			"touche": "BackSpace",
			"code": "Backspace",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "1",
			"colonne": "15",
			"taille": "1.75"
		},
		{
			"touche": "Tab",
			"code": "Tab",
			"main": "gauche",
			"doigt": "auriculaire",
			"ligne": "2",
			"colonne": "0",
			"taille": "1.5"
		},
		{
			"touche": "\u00e0",
			"code": "KeyQ",
			"main": "gauche",
			"doigt": "auriculaire",
			"ligne": "2",
			"colonne": "2",
			"taille": "1"
		},
		{
			"touche": "y",
			"code": "KeyW",
			"main": "gauche",
			"doigt": "annulaire",
			"ligne": "2",
			"colonne": "3",
			"taille": "1"
		},
		{
			"touche": "o",
			"code": "KeyE",
			"main": "gauche",
			"doigt": "majeur",
			"ligne": "2",
			"colonne": "4",
			"taille": "1"
		},
		{
			"touche": "w",
			"code": "KeyR",
			"main": "gauche",
			"doigt": "index",
			"ligne": "2",
			"colonne": "5",
			"taille": "1"
		},
		{
			"touche": "b",
			"code": "KeyT",
			"main": "gauche",
			"doigt": "index",
			"ligne": "2",
			"colonne": "6",
			"taille": "1"
		},
		{
			"touche": "f",
			"code": "KeyY",
			"main": "droite",
			"doigt": "index",
			"ligne": "2",
			"colonne": "8",
			"taille": "1"
		},
		{
			"touche": "d",
			"code": "KeyU",
			"main": "droite",
			"doigt": "index",
			"ligne": "2",
			"colonne": "9",
			"taille": "1"
		},
		{
			"touche": "l",
			"code": "KeyI",
			"main": "droite",
			"doigt": "majeur",
			"ligne": "2",
			"colonne": "10",
			"taille": "1"
		},
		{
			"touche": "p",
			"code": "KeyO",
			"main": "droite",
			"doigt": "annulaire",
			"ligne": "2",
			"colonne": "11",
			"taille": "1"
		},
		{
			"touche": "’",
			"code": "KeyP",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "2",
			"colonne": "12",
			"taille": "1"
		},
		{
			"touche": "z",
			"code": "BracketLeft",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "2",
			"colonne": "13",
			"taille": "1"
		},
		{
			"touche": "!",
			"code": "BracketRight",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "2",
			"colonne": "14",
			"taille": "1"
		},
		{
			"touche": "Enter",
			"code": "Enter",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "2",
			"colonne": "15",
			"taille": "1.25"
		},
		{
			"touche": "CapsLock",
			"code": "CapsLock",
			"main": "gauche",
			"doigt": "auriculaire",
			"ligne": "3",
			"colonne": "0",
			"taille": "1.75"
		},
		{
			"touche": "a",
			"code": "KeyA",
			"main": "gauche",
			"doigt": "auriculaire",
			"ligne": "3",
			"colonne": "2",
			"taille": "1"
		},
		{
			"touche": "i",
			"code": "KeyS",
			"main": "gauche",
			"doigt": "annulaire",
			"ligne": "3",
			"colonne": "3",
			"taille": "1"
		},
		{
			"touche": "e",
			"code": "KeyD",
			"main": "gauche",
			"doigt": "majeur",
			"ligne": "3",
			"colonne": "4",
			"taille": "1"
		},
		{
			"touche": "u",
			"code": "KeyF",
			"main": "gauche",
			"doigt": "index",
			"ligne": "3",
			"colonne": "5",
			"taille": "1"
		},
		{
			"touche": ",",
			"code": "KeyG",
			"main": "gauche",
			"doigt": "index",
			"ligne": "3",
			"colonne": "6",
			"taille": "1"
		},
		{
			"touche": "m",
			"code": "KeyH",
			"main": "droite",
			"doigt": "index",
			"ligne": "3",
			"colonne": "8",
			"taille": "1"
		},
		{
			"touche": "s",
			"code": "KeyJ",
			"main": "droite",
			"doigt": "index",
			"ligne": "3",
			"colonne": "9",
			"taille": "1"
		},
		{
			"touche": "n",
			"code": "KeyK",
			"main": "droite",
			"doigt": "majeur",
			"ligne": "3",
			"colonne": "10",
			"taille": "1"
		},
		{
			"touche": "t",
			"code": "KeyL",
			"main": "droite",
			"doigt": "annulaire",
			"ligne": "3",
			"colonne": "11",
			"taille": "1"
		},
		{
			"touche": "r",
			"code": "Semicolon",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "3",
			"colonne": "12",
			"taille": "1"
		},
		{
			"touche": "q",
			"code": "Quote",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "3",
			"colonne": "13",
			"taille": "1"
		},
		{
			"touche": "j",
			"code": "Backslash",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "3",
			"colonne": "14",
			"taille": "1"
		},
		{
			"touche": "LShift",
			"main": "gauche",
			"doigt": "auriculaire",
			"ligne": "4",
			"colonne": "0",
			"taille": "1.25"
		},
		{
			"touche": "è",
			"code": "KeyX",
			"main": "gauche",
			"doigt": "majeur",
			"ligne": "4",
			"colonne": "4",
			"taille": "1"
		},
		{
			"touche": ".",
			"code": "KeyV",
			"main": "gauche",
			"doigt": "index",
			"ligne": "4",
			"colonne": "6",
			"taille": "1"
		},
		{
			"touche": "ê",
			"code": "IntlBackslash",
			"main": "gauche",
			"doigt": "auriculaire",
			"ligne": "4",
			"colonne": "2",
			"taille": "1"
		},
		{
			"touche": "magique",
			"code": "KeyC",
			"main": "gauche",
			"doigt": "index",
			"ligne": "4",
			"colonne": "5",
			"taille": "1"
		},
		{
			"touche": "é",
			"code": "KeyZ",
			"main": "gauche",
			"doigt": "annulaire",
			"ligne": "4",
			"colonne": "3",
			"taille": "1"
		},
		{
			"touche": "k",
			"code": "KeyB",
			"main": "gauche",
			"doigt": "index",
			"ligne": "4",
			"colonne": "7",
			"taille": "1"
		},
		{
			"touche": "v",
			"code": "KeyN",
			"main": "droite",
			"doigt": "index",
			"ligne": "4",
			"colonne": "8",
			"taille": "1"
		},
		{
			"touche": "c",
			"code": "KeyM",
			"main": "droite",
			"doigt": "index",
			"ligne": "4",
			"colonne": "9",
			"taille": "1"
		},
		{
			"touche": "h",
			"code": "Comma",
			"main": "droite",
			"doigt": "majeur",
			"ligne": "4",
			"colonne": "10",
			"taille": "1"
		},
		{
			"touche": "g",
			"code": "Period",
			"main": "droite",
			"doigt": "annulaire",
			"ligne": "4",
			"colonne": "11",
			"taille": "1"
		},
		{
			"touche": "x",
			"code": "Slash",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "4",
			"colonne": "12",
			"taille": "1"
		},
		{
			"touche": "RShift",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "4",
			"colonne": "13",
			"taille": "2.5"
		},
		{
			"touche": "LCtrl",
			"main": "gauche",
			"doigt": "auriculaire",
			"ligne": "5",
			"colonne": "0",
			"taille": "1.25"
		},
		{
			"touche": "Win",
			"main": "gauche",
			"doigt": "auriculaire",
			"ligne": "5",
			"colonne": "1",
			"taille": "1.25"
		},
		{
			"touche": "LAlt",
			"main": "gauche",
			"doigt": "pouce",
			"ligne": "5",
			"colonne": "2",
			"taille": "1.25"
		},
		{
			"touche": "Space",
			"code": "Space",
			"main": "gauche",
			"doigt": "pouce",
			"ligne": "5",
			"colonne": "4",
			"taille": "7"
		},
		{
			"touche": "RAlt",
			"code": "AltRight",
			"main": "droite",
			"doigt": "pouce",
			"ligne": "5",
			"colonne": "10",
			"taille": "1.25"
		},
		{
			"touche": "RCtrl",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "5",
			"colonne": "11",
			"taille": "1.25"
		},
		{
			"touche": "Option",
			"main": "droite",
			"doigt": "auriculaire",
			"ligne": "5",
			"colonne": "12",
			"taille": "1.5"
		}
	],
}

# Fonction de tri pour trier d'abord par ligne, puis par colonne
def custom_sort(item):
    return (int(item['ligne']), int(item['colonne']))

# Trier les données en utilisant la fonction de tri personnalisée
data_trie = sorted(data["iso"], key=custom_sort)

# Ouverture du fichier en mode écriture avec l'encodage UTF-8
with open("donnees_triees.json", "w", encoding="utf-8") as fichier:
    # Écriture des données triées au format JSON dans le fichier
    json.dump(data_trie, fichier, ensure_ascii=False, indent=4)

print("Données triées écrites dans le fichier 'donnees_triees.json' au format JSON avec l'encodage UTF-8.")