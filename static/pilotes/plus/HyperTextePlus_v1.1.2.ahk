#Requires Autohotkey v2.0+
#SingleInstance Force
InstallKeybdHook
SetWorkingDir(A_ScriptDir) ; Ensures a consistent starting directory.
#Hotstring EndChars -()[]{}:;'"/\,.?!`n`s`t  

global clavier_iso := 1		; 0 = clavier ZMK 		 | 	1 = clavier ISO. Le clavier ZMK désactive les tap-holds pour éviter les conflits.
global pilote_azerty := 0	; 0 = pilote HYPERTEXTE	 | 	1 = pilote AZERTY. En mettant cette variable à 1, plus besoin de changer le pilote, le script va modifier chaque touche pour la faire correspondre à sa valeur en HyperTexte.
global autocorrection := 1

; Initialisation des variables, ne pas toucher
global script_actif := TRUE
global capsword_actif := FALSE ; État du capsword
global layer_actif := FALSE ; État du layer de navigation
global nb_repetitions := 1 ; Comme avec Vim, 3w pour aller de trois mots en avant, on peut faire pareil

global deadkey_grec_min := { a: "α", b: "β", c: "ε", d: "δ", e: "η", f: "ξ", g: "γ", h: "φ", i: "ι", j: "", k: "κ", l: "λ",
    m: "μ", n: "ν", o: "θ", p: "π", q: "", r: "ρ", s: "σ", t: "τ", u: "υ", v: "ν", w: "ω", x: "χ", y: "ψ", z: "ψ"
}
global deadkey_grec_maj := { A: "", B: "", C: "", D: "Δ", E: "", F: "Ξ", G: "Γ", H: "Φ", I: "", J: "", K: "", L: "Λ", M: "",
    N: "", O: "Θ", P: "Π", Q: "", R: "", S: "Σ", T: "", U: "", V: "", W: "Ω", X: "", Y: "Ψ", Z: "Ψ"
}
global deadkey_exposant_min := { a: "ᵃ", b: "ᵇ", c: "ᶜ", d: "ᵈ", e: "ᵉ", f: "ᶠ", g: "ᶢ", h: "ᵸ", i: "ᶤ", j: "ᶨ", k: "ᵏ",
    l: "ᶪ", m: "ᵐ", n: "ⁿ", o: "ᵒ", p: "ᵖ", q: "", r: "", s: "ᶳ", t: "ᵗ", u: "ᵘ", v: "ᵛ", w: "", x: "ᵡ", y: "", z: "ᶻ"
}
global deadkey_exposant_maj := { a: "ᴬ", b: "ᴮ", c: "", d: "ᴰ", e: "ᴱ", f: "", g: "", h: "ᴴ", i: "ᴵ", j: "ᴶ", k: "ᴷ", l: "ᴸ",
    m: "ᴹ", n: "ᴺ", o: "ᴼ", p: "ᴾ", q: "", r: "ᴿ", s: "", t: "ᵀ", u: "ᵁ", v: "", w: "ᵂ", x: "", y: "", z: ""
}
global deadkey_exposant_nb := { touche1: "¹", touche2: "²", touche3: "³", touche4: "⁴", touche5: "⁵", touche6: "⁶",
    touche7: "⁷", touche8: "⁸", touche9: "⁹", touche0: "⁰"
}
global deadkey_indice_min := { a: "ₐ", b: "ᵦ", c: "", d: "", e: "ₑ", f: "", g: "ᵧ", h: "", i: "ᵢ", j: "", k: "", l: "",
    m: "", n: "", o: "ₒ", p: "ᵨ", q: "", r: "ᵣ", s: "", t: "", u: "ᵤ", v: "ᵥ", w: "", x: "ₓ", y: "", z: ""
}
global deadkey_indice_nb := { touche1: "₁", touche2: "₂", touche3: "₃", touche4: "₄", touche5: "₅", touche6: "₆",
    touche7: "₇", touche8: "₈", touche9: "₉", touche0: "₀"
}

; ======= Raccourcis de gestion du script en AltGr =======

#SuspendExempt
^!Enter:: ; Désactivation/Réactivation du script avec AltGr + Enter
{
    global script_actif := !script_actif
    if !script_actif {
        Pause 1 ; Met en pause ce qui est en train d’être exécuté
        Suspend 1
    } else {
        Reload ; De cette façon, ce qui était en train d’être exécuté ne continue pas
    }
}

^!SC00E:: ; Sauvegarde et recharge le script avec AltGr + BackSpace
{

    Send("^s") ; Sauvegarde du script grâce au raccourci Ctrl + S
    Reload
}

^!Delete:: Edit ; Modification du script avec AltGr + Suppr
#SuspendExempt False

; =========================================================
; =========================================================
; =========================================================
; ================ 1/ AZERTY ➜ HYPERTEXTE ================
; ======== Convertit un pilote AZERTY en HYPERTEXTE =======
; =========================================================
; =========================================================
; =========================================================

#HotIf pilote_azerty
#InputLevel 50 ; Très important, il faut être en InputLevel le plus haut pour le remappage AZERTY vers HyperTexte
; Car ensuite on va remapper les touches déjà remappées, donc il faut que l’InputLevel des autres raccourcis soit plus bas

/* ======= Carte des scancodes des touches du clavier =======
        Un scancode est sous la forme SC000.
        Donc pour sélectionner la touche à l'emplacement F du clavier AZERTY, le scancode est SC021,
        SC039 pour la barre d'espace, SC028 pour la touche ù, SC003 pour la touche &/1, etc.
        Les scancodes sont beaucoup plus fiables que d'utiliser le nom des touches.
        Pour que les tap holds fonctionnent, il faut nécessairement faire tout le reste des raccourcis avec les scancodes.

	---     ---------------   ---------------   ---------------   -----------
	| 01|   | 3B| 3C| 3D| 3E| | 3F| 40| 41| 42| | 43| 44| 57| 58| |+37|+46|+45|
	---     ---------------   ---------------   ---------------   -----------
	-----------------------------------------------------------   -----------   ---------------
	| 29| 02| 03| 04| 05| 06| 07| 08| 09| 0A| 0B| 0C| 0D|     0E| |*52|*47|*49| |+45|+35|+37| 4A|
	|-----------------------------------------------------------| |-----------| |---------------|
	|   0F| 10| 11| 12| 13| 14| 15| 16| 17| 18| 19| 1A| 1B|     | |*53|*4F|*51| | 47| 48| 49|   |
	|------------------------------------------------------|  1C|  -----------  |-----------| 4E|
	|    3A| 1E| 1F| 20| 21| 22| 23| 24| 25| 26| 27| 28| 2B|    |               | 4B| 4C| 4D|   |
	|-----------------------------------------------------------|      ---      |---------------|
	|  2A| 56| 2C| 2D| 2E| 2F| 30| 31| 32| 33| 34| 35|       136|     |*4C|     | 4F| 50| 51|   |
	|-----------------------------------------------------------|  -----------  |-----------|-1C|
	|   1D|15B|   38|                       39|138|15C|15D|  11D| |*4B|*50|*4D| |     52| 53|   |
	-----------------------------------------------------------   -----------   ---------------
*/

; =========================
; ======= 1.1) Base =======
; =========================

; Pas de Send ici, sinon les raccourcis et shift ne fonctionnent plus !!!

; === Rangée des chiffres ===

SC029::=
SC002:: Send("{U+0031}") ; 1
SC003:: Send("{U+0032}") ; 2
SC004:: Send("{U+0033}") ; 3
SC005:: Send("{U+0034}") ; 4
SC006:: Send("{U+0035}") ; 5
SC007:: Send("{U+0036}") ; 6
SC008:: Send("{U+0037}") ; 7
SC009:: Send("{U+0038}") ; 8
SC00A:: Send("{U+0039}") ; 9
SC00B:: Send("{U+0030}") ; 0
SC00C:: Send("{U+0025}") ; %
SC00D:: Send("{U+20AC}") ; €

; === Rangée du haut ===

SC010::è
SC011::y
SC012::o
SC013::w
SC014::b
SC015::f
SC016::d
SC017::l
SC018::p
SC019::'
SC01A::z
SC01B::+SC01A ; La touche morte tréma
^SC01B::^SC035 ; Raccourci Ctrl + ! pour mettre sous format nombre dans Excel

; === Rangée du milieu ===

SC01E::a
SC01F::i
SC020::e
SC021::u
SC022::.
SC023::v
SC024::s
SC025::n
SC026::t
SC027::r
#SC027::#r
SC028::q
SC02B::SC01A ; SC01A est la touche morte ^ en AZERTY

; === Rangée du bas ===

SC056::ê
SC02C::é
SC02D::à
SC02E::j
SC02F::,
SC030::k
SC031::m
SC032::c
SC033::h
SC034::g
SC035::x

; ==========================
; ======= 1.2) Shift =======
; ==========================

+SC039:: Send("{U+002D}") ; - sur la barre d’espace

; === Rangée des chiffres ===

+SC029:: Send("=")
+SC002:: Send("{U+0031}") ; 1
+SC003:: Send("{U+0032}") ; 2
+SC004:: Send("{U+0033}") ; 3
+SC005:: Send("{U+0034}") ; 4
+SC006:: Send("{U+0035}") ; 5
+SC007:: Send("{U+0036}") ; 6
+SC008:: Send("{U+0037}") ; 7
+SC009:: Send("{U+0038}") ; 8
+SC00A:: Send("{U+0039}") ; 9
+SC00B:: Send("º")
+SC00C:: {
    Send(" ")
    Sleep(50)
    Send("%")
}
+SC00D:: {
    Send(" ")
    Sleep(50)
    Send("{U+20AC}") ; €
}

; === Rangée du haut ===

+SC010:: Send("È")
+SC011:: Send("Y")
+SC012:: Send("O")
+SC013:: Send("W")
+SC014:: Send("B")
+SC015:: Send("F")
+SC016:: Send("D")
+SC017:: Send("L")
+SC018:: Send("P")
+SC019:: {
    Send(" ")
    Sleep(50)
    Send("?")
}
+SC01A:: Send("Z")
+SC01B:: Send(" ") ; Espace fine insécable

; === Rangée du milieu ===

+SC01E:: Send("A")
+SC01F:: Send("I")
+SC020:: Send("E")
+SC021:: Send("U")
+SC022:: {
    Send(" ")
    Sleep(50)
    Send("{U+003A}") ; :
}
+SC023:: Send("V")
+SC024:: Send("S")
+SC025:: Send("N")
+SC026:: Send("T")
+SC027:: Send("R")
+SC028:: Send("Q")
+SC02B:: {
    Send(" ")
    Sleep(50)
    Send("{!}")
}

; === Rangée du bas ===

+SC056:: Send("Ê")
+SC02C:: Send("É")
+SC02D:: Send("À")
+SC02E:: Send("J")
+SC02F:: {
    Send(" ")
    Sleep(50)
    Send("{U+003B}") ; ;
}
+SC030:: Send("K")
+SC031:: Send("M")
+SC032:: Send("C")
+SC033:: Send("H")
+SC034:: Send("G")
+SC035:: Send("X")
#HotIf

; Met en Shift les caractères exotiques lors du Capslock
#HotIf pilote_azerty and GetKeyState("CapsLock", "T") and !layer_actif
SC002:: Send(1)
SC003:: Send(2)
SC004:: Send(3)
SC005:: Send(4)
SC006:: Send(5)
SC007:: Send(6)
SC008:: Send(7)
SC009:: Send(8)
SC00A:: Send(9)
SC00B:: Send(0)
SC010:: Send("È")
SC019:: Send("'")
SC022:: Send("{U+002E}") ; .
SC02C:: Send("É")
SC02D:: Send("À")
SC056:: Send("Ê")
SC02E:: Send("★")
SC02F:: Send(",")
SC034:: Send("G")
#HotIf

; ==========================
; ======= 1.3) AltGr =======
; ==========================

; On est forcé d’utiliser des Send ici, sinon la touche Ctrl reste activée dans certains cas
; Mais le problème est que les remplacements de texte ne fonctionnent alors plus
; Ce problème est résolu en utilisant l’envoi Unicode ! (j’ai l’impression, à vérifier)

<^>!SC039:: Send("_") ; Sur la barre d’espace

; === Rangée des chiffres ===

; ^!SC029::
<^>!SC002:: Send("1") ; AltGr + 1
<^>!SC003:: Send("2") ; AltGr + 2
<^>!SC004:: Send("3") ; AltGr + 3
<^>!SC005:: Send("4") ; AltGr + 4
<^>!SC006:: Send("5") ; AltGr + 5
<^>!SC007:: Send("6") ; AltGr + 6
<^>!SC008:: Send("7") ; AltGr + 7
<^>!SC009:: Send("8") ; AltGr + 8
<^>!SC00A:: Send("9") ; AltGr + 9
<^>!SC00B:: Send("°") ; AltGr + 0
<^>!SC00C:: Send("‰")
<^>!SC00D:: Send("£")

; === Rangée du haut ===

<^>!SC010:: Send("{U+0060}") ; `
<^>!SC011:: Send("{U+0040}") ; @
<^>!SC012:: Send("œ")
<^>!SC013:: Send("où") ; Sur W
<^>!SC014:: Send("« ")
<^>!SC015:: Send(" »")
<^>!SC016:: Send("{U+0024}") ; $
<^>!SC017:: Send("{U+003D}") ; =
<^>!SC018:: Send("{U+002B}") ; + Défini à un autre endroit du code à cause d’un bug sur Excel
<^>!SC019:: Send("{U+003F}") ; ?
<^>!SC01A:: Send("{!}")
<^>!SC01B:: Send(" ") ; Espace insécable

; === Rangée du milieu ===
<^>!SC01E:: Send("{U+003C}") ; <
<^>!SC01F:: Send("{U+003E}") ; >
<^>!SC020:: Send("{U+007B}") ; {
<^>!SC021:: Send("{U+007D}") ; }
<^>!SC022:: Send("{U+003A}") ; :
<^>!SC023:: Send("{U+007C}") ; |
<^>!SC024:: Send("{U+0028}") ; (
<^>!SC025:: Send("{U+0029}") ; )
<^>!SC026:: Send("{U+005B}") ; [
<^>!SC027:: Send("{U+005D}") ; ]
<^>!SC028:: Send("{U+0025}") ; %
<^>!SC02B:: Send("{U+0021}") ; !

; === Rangée du bas ===

<^>!SC056:: Send("{U+005E}") ; ^
<^>!SC02C:: Send("{U+002F}") ; /
<^>!SC02D:: Send("{U+005C}") ; \
<^>!SC02E:: Send("{U+0022}") ; "
<^>!SC02F:: Send("{U+003B}") ; ;
<^>!SC030:: Send("…")
<^>!SC031:: Send("{U+0026}") ; &
<^>!SC032:: Send("{U+00E7}") ; ç
<^>!SC033:: Send("{U+0023}") ; #
<^>!SC034:: Send("{U+007E}") ; ~
<^>!SC035:: Send("{U+002A}") ; *

; ==================================
; ======= 1.4) Shift + AltGr =======
; ==================================

; === Rangée des chiffres ===

+^!SC029:: Send("⁰")
+^!SC002:: Send("¹")
+^!SC003:: Send("²")
+^!SC004:: Send("³")
+^!SC005:: Send("⁴")
+^!SC006:: Send("⁵")
+^!SC007:: Send("⁶")
+^!SC008:: Send("⁷")
+^!SC009:: Send("⁸")
+^!SC00A:: Send("⁹")
+^!SC00B:: Send("ª")
+^!SC00C:: Send("‱")
+^!SC00D:: return

; === Rangée du haut ===

+^!SC010:: Send("„")
+^!SC011:: Send("„")
+^!SC012:: Send("Œ")
+^!SC013:: Send("Où")
+^!SC014:: Send("“")
+^!SC015:: Send("”")
+^!SC016:: Send("§")
+^!SC017:: Send("≠")
+^!SC018:: Send("±")
+^!SC019:: Send("¿")
+^!SC01A:: Send("¡")
+^!SC01B:: Send("¡")

; === Rangée du milieu ===

+^!SC01E:: Send("≤")
+^!SC01F:: Send("≥")
+^!SC020:: ; Touche morte Exposant en E
{
    ihkey := InputHook("L1",
        "{F1}{F2}{F3}{F4}{F5}{F6}{F7}{F8}{F9}{F10}{F11}{F12}{Left}{Right}{Up}{Down}{Home}{End}{PgUp}{PgDn}{Del}{Ins}{BS}{Capslock}{Numlock}{PrintScreen}{Pause}"
    ), ihkey.Start(), ihkey.Wait(), key := ihkey.Input
    if (RegExMatch(key, "[A-Z]")) { ; Si c’est une touche majuscule
        Send(deadkey_exposant_maj.%key%)
    } else if (RegExMatch(key, "[a-z]")) {
        Send(deadkey_exposant_min.%key%)
    } else if (RegExMatch(key, "[0-9]")) {
        element := "touche" . key
        Send(deadkey_exposant_nb.%element%)
    } else if (key = "+") {
        Send("⁺")
    } else if (key = "-") {
        Send("⁻")
    } else if (key = "=") {
        Send("⁼")
    } else if (key = "(") {
        Send("⁽")
    } else if (key = ")") {
        Send("⁾")
    }
}
+^!SC021:: ; Touche morte grec (μ) sur U
{
    ihkey := InputHook("L1",
        "{LControl}{RControl}{LAlt}{LCtrl}{LWin}{RWin}{AppsKey}{F1}{F2}{F3}{F4}{F5}{F6}{F7}{F8}{F9}{F10}{F11}{F12}{Left}{Right}{Up}{Down}{Home}{End}{PgUp}{PgDn}{Del}{Ins}{BS}{Capslock}{Numlock}{PrintScreen}{Pause}"
    ), ihkey.Start(), ihkey.Wait(), key := ihkey.Input
    if (RegExMatch(key, "[A-Z]")) { ; Si c’est une touche majuscule
        Send(deadkey_grec_maj.%key%)
    } else {
        Send(deadkey_grec_min.%key%)
    }
}
+^!SC022:: Send("·")
+^!SC023:: Send("¦")
+^!SC024:: Send("—")
+^!SC025:: Send("–")
+^!SC026:: Send("+{SC01A}") ; La touche morte ¨ sur T(réma)
+^!SC027:: return
+^!SC028:: Send("‰")
+^!SC02B:: return

; === Rangée du bas ===

+^!SC056:: return
+^!SC02C:: Send("÷")
+^!SC02D:: ; Touche morte Indice
{
    ihkey := InputHook("L1",
        "{F1}{F2}{F3}{F4}{F5}{F6}{F7}{F8}{F9}{F10}{F11}{F12}{Left}{Right}{Up}{Down}{Home}{End}{PgUp}{PgDn}{Del}{Ins}{BS}{Capslock}{Numlock}{PrintScreen}{Pause}"
    ), ihkey.Start(), ihkey.Wait(), key := ihkey.Input
    if (RegExMatch(key, "[a-z]")) { ; Si c’est une touche majuscule
        Send(deadkey_indice_min.%key%)
    } else if (RegExMatch(key, "[0-9]")) {
        element := "touche" . key
        Send(deadkey_indice_nb.%element%)
    } else if (key = "+") {
        Send("₊")
    } else if (key = "-") {
        Send("₋")
    } else if (key = "=") {
        Send("₌")
    } else if (key = "(") {
        Send("₍")
    } else if (key = ")") {
        Send("₎")
    }
}
+^!SC02E:: return
+^!SC02F:: return
+^!SC030:: return
+^!SC031:: Send("−")
+^!SC032:: Send("Ç")
+^!SC033:: return
+^!SC034:: Send("≈")
+^!SC035:: Send("×")

; ============================
; ======= 1.5) Control =======
; ============================

^SC02F:: Send("^v") ; Corrige le problème avec Win+V qui ne fonctionne pas
^SC010:: Send("^z") ; Ctrl + È donne Ctrl + Z
^SC056:: Send("^x") ; Ctrl + Ê donne Ctrl + X
^SC02C:: Send("^c") ; Ctrl + É donne Ctrl + C
^SC02D:: Send("^v") ; Ctrl + À donne Ctrl + V
^SC02E:: Send("^j") ; Ctrl + ★ donne Ctrl + J
#HotIf

; ====================================================================
; ====================================================================
; ====================================================================
; ================ 2/ TAP-HOLD ET LAYER DE NAVIGATION ================
; ====================================================================
; ====================================================================
; ====================================================================

; =============================
; ======= 2.1) Tap-hold =======
; =============================

#HotIf clavier_iso and !layer_actif ; Pour éviter des problèmes avec les raccourcis ZMK

; Tap-hold vur "Tab" : Alt en hold, Alt + Tab en tap
SC00F::LAlt
SC00F::
{
    Send("{LAlt Down}")
    ErrorLevel := KeyWait("SC00F", "T.2") ; Attente de la touche pour un temps de 200ms
    if ErrorLevel {  ; Si la touche est relâchée avant le temps d’attente
        Send("{LAlt Down}{Tab}{LAlt Up}")
    }
}
SC00F Up:: Send("{LAlt Up}")

; Tap-hold sur LShift : Shift en hold, Ctrl + C en tap
~$SC02A::
{
    if (KeyWait("LShift", "T0.25") and (A_PriorKey == "LShift")) { ;  If released before
        Send("{LShift Up}")
        Send("{LCtrl Down}c{LCtrl Up}")
        Send("{LControl Up}{RAlt Up}")
    }
}
SC02A Up:: Send("{LShift Up}")

; Tap-hold sur LControl : Ctrl en hold, Ctrl + V en tap
$SC01D:: ; Pas de ~ ici, ce qui force le Ctrl + V même si hold très long, car sinon #V ne fonctionne pas
{
    Send("{LControl Down}")
    if (KeyWait("LControl", "T0.25") and (A_PriorKey == "LControl")) { ;  If released before
        Send("{LControl Up}")
        Send("{LCtrl Down}v{LCtrl Up}")
    } else {
        KeyWait("LControl") ; Wait until released
        Send("{LControl Up}")
    }
    Send("{LControl Up}")
    Send("{LControl Up}{RAlt Up}")
}
SC01D Up:: Send("{LControl Up}")

; Tap-hold sur "Alt" : Layer en hold, Enter en tap
$SC038::
{
    Send("{LAlt Up}")
    global layer_actif := TRUE
    SetCapsLockState("AlwaysOn")
    global nb_repetitions := 1
    ErrorLevel := KeyWait("SC038", "T.2") ; Attente de la touche pour un temps de 200ms
    if ErrorLevel and A_PriorKey == "LAlt" { ; Si la touche est relâchée avant le temps d’attente
        layer_actif := FALSE
        SetCapsLockState("AlwaysOff")
        Send("{Enter}")
    } else {
        KeyWait("SC038")
        layer_actif := FALSE
        SetCapsLockState("AlwaysOff")
    }
    layer_actif := FALSE
    SetCapsLockState("AlwaysOff")
}
$SC038 Up:: {
    layer_actif := FALSE
    SetCapsLockState("AlwaysOff")
}

; SC01C::Return ; Désactivation de Enter le temps de s’habituer au nouvel emplacement

; En Ctrl + Shift, c’est un Ctrl + Shift + Enter
^+SC038::
{
    Send("^+{Enter}")
}

; En Shift, c’est un Shift + Enter
+SC038::
{
    Send("+{Enter}")
}

; En Control, c’est un Ctrl + Enter
<^>SC038::
{
    ; Send("b")
    Send("^{Enter}")
}

; En "Enter" (Alt), c’est un Alt + Enter
~SC00F & SC038::
{
    ; Send("{LAlt Up}c")
    Send("{Enter}")
}

; Tap-hold sur AltGr pour avoir Tab en tap. LControl & RAlt est le seul moyen que cela fire au tap directement
SC01D & ~SC138::
{
    if (KeyWait("SC138", "T.2") and A_PriorKey == "RAlt") { ; Si la touche est relâchée avant le temps d’attente
        desactiver_capsword()
        if (GetKeyState("LControl") and GetKeyState("Shift")) {
            Send("^+{Tab}")
        } else if GetKeyState("LControl") {
            Send("^{Tab}")
        } else if GetKeyState("Shift") {
            Send("+{Tab}")
        } else {
            Send("{Tab}")
        }
    } else {
        Send("{LControl Up}{RAlt Up}")
    }
}
SC01D & ~SC138 Up::
RAlt Up::
{
    Send("{LControl Up}{RAlt Up}")
}

#HotIf

; =============================
; ======= 2.2) Capsword =======
; =============================

toggle_capsword() {
    global capsword_actif := !capsword_actif
    if capsword_actif {
        SetCapsLockState("AlwaysOn")
    } else {
        SetCapsLockState("AlwaysOff")
    }
}

desactiver_capsword() {
    global capsword_actif := FALSE
    SetCapsLockState("Off")
}

#HotIf !capsword_actif
; Capsword en RAlt puis "LAlt" (cf. https://github.com/qmk/qmk_firmware/blob/master/users/drashna/keyrecords/capwords.md)
SC138 & SC038::
{
    global layer_actif := FALSE
    SetCapsLockState("AlwaysOff")
    ErrorLevel := KeyWait("SC038", "T.2") ; Attente de la touche pour un temps de 200ms
    if ErrorLevel {  ; Si la touche est relâchée avant le temps d’attente
        toggle_capsword()
    }
}
#HotIf

; Définit ce qui met fin au capslock de capsword
#HotIf capsword_actif

SC039::
Space::
{
    Send("{Space}")
    desactiver_capsword()
}

Enter::
{
    Send("{Enter}")
    desactiver_capsword()
}

SC00F:: ; Sur "LAlt"
{
    desactiver_capsword()
}

LButton::
RButton:: ; Le click désactive capsword
{
    desactiver_capsword()
}

Tab::
RAlt::
SC01D & ~SC138:: ; AltGr + Tab
SC138::
{
    Send("{Tab}")
    desactiver_capsword()
}

SC022::
{
    Send(",")
    desactiver_capsword()
}

`;::
{
    Send("`;")
    desactiver_capsword()
}

.::
{
    Send(".")
    desactiver_capsword()
}

:::
{
    Send(":")
    desactiver_capsword()
}

?::
{
    Send("?")
    desactiver_capsword()
}
!::
{
    Send("!")
    desactiver_capsword()
}
#HotIf

; Tap-hold sur RControl
$SC11D:: {
    Send("{LControl Up}{LShift Down}")
    OneShotShift()
    ErrorLevel := KeyWait("SC11D", "T.2") ; Attente de la touche pour un temps de 200ms
    if ErrorLevel and A_PriorKey == "RControl" { ; Si la touche est relâchée avant le temps d’attente
        ; OneShotShift()
        Send("{LControl Up}{LShift Up}")
    } else {
        KeyWait("SC11D")
        Send("{LControl Up}{LShift Up}")
    }
}

OneShotShift() {
    ihvText := InputHook("L1 T1 E", "{Space}.,'%€!àèéê★", ""), ihvText.Start(), ihvText.Wait(), vText :=
    ihvText.Input
    if (ihvText = "Timeout") {
        return
    } else if (ihvText.EndKey = "Space") {
        ; Cas particulier car sur Space ça ne fonctionnait pas
        Send("{U+002D}") ; -
    } else if (ihvText.EndKey = ".") {
        Send(" ")
        Sleep(50)
        Send("`:")
    } else if (ihvText.EndKey = ",") {
        Send(" ")
        Sleep(50)
        Send("`;")
    } else if (ihvText.EndKey = "%") {
        Send(" ")
        Sleep(50)
        Send("%")
    } else if (ihvText.EndKey = "€") {
        Send(" ")
        Sleep(50)
        Send("{U+20AC}") ; €
    } else if (ihvText.EndKey = "!") {
        Send(" ")
        Sleep(50)
        Send("{!}")
    } else if (ihvText.EndKey = "'") {
        Send(" ")
        Sleep(50)
        Send("?")
    } else if (ihvText.EndKey = "à") {
        Send("À")
    } else if (ihvText.EndKey = "è") {
        Send("È")
    } else if (ihvText.EndKey = "é") {
        Send("É")
    } else if (ihvText.EndKey = "ê") {
        Send("Ê")
    } else if (ihvText.EndKey = "★") {
        Send("J")
    } else {
        Send("{Raw}" Format("{:T}", vText)) ; Passe en titelcase
    }
}

; ========================================
; ======= 2.3) Layer de navigation =======
; ========================================

#HotIf layer_actif ; Sticky layer de navigation tant que la variable est activée

SC038:: Send("{LAlt Up}") ; Hécessaire pour éviter que le layer soit encore en Alt

SC039:: { ; Sur Space
    Send("{Escape " . nb_repetitions . "}")
    global nb_repetitions := 1
    global layer_actif := FALSE
    SetCapsLockState("AlwaysOff")
}
SC01D & ~SC138:: Send("{LCtrl Down}{Delete}{LCtrl Up}")
SC11D:: { ; Sur RControl
    global layer_actif := FALSE
    SetCapsLockState("AlwaysOff")
}

WheelUp:: { ; Monter le volume avec Scroll vers le haut
    Send("{Volume_Up " . nb_repetitions . "}")
    global nb_repetitions := 1
}
WheelDown:: { ; Baisser le volume avec Scroll vers le bas
    Send("{Volume_Down " . nb_repetitions . "}")
    global nb_repetitions := 1
}

SC002:: { ; 1
    global nb_repetitions := 1
}
SC003:: { ; 2
    global nb_repetitions := 2
}
SC004:: { ; 3
    global nb_repetitions := 3
}
SC005:: { ; 4
    global nb_repetitions := 4
}
SC006:: { ; 5
    global nb_repetitions := 5
}
SC007:: { ; 6
    global nb_repetitions := 6
}
SC008:: { ; 7
    global nb_repetitions := 7
}
SC009:: { ; 8
    global nb_repetitions := 8
}
SC00A:: { ; 9
    global nb_repetitions := 9
}

; === MAIN GAUCHE ===

; ÀYOWB
SC00F:: {
    Send("{LAlt Down}{Escape}{LAlt Up}") ; Meilleur Alt + Tab
    global nb_repetitions := 1
}
SC010:: {
    Send("{Shift Down}^{Home}{Shift Up}") ; Sélection de tout ce qui est au-dessus
    global nb_repetitions := 1
}
SC011:: {
    Send("^{Home}") ; Aller au début du document
    global nb_repetitions := 1
}
SC012:: {
    Send("^{End}") ; Aller à la fin du document
    global nb_repetitions := 1
}
SC013:: {
    Send("{Shift Down}^{End}{Shift Up}") ; Sélection de tout ce qui est en-dessous
    global nb_repetitions := 1
}
SC014:: {
    Send("{Tab}")
    global nb_repetitions := 1
}

; AIEU,
; Ctrl & SC03A::	Send("^{Delete}")
SC03A:: {
    Send("{Delete " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC01E:: {
    Send("^+{Up " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC01F:: { ; ⇧
    Send("{Up " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC020:: { ; ⇩
    Send("{Down " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC021:: {
    Send("^+{Down " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC022:: {
    Send("+!{Left " . nb_repetitions . "}") ; Dans VSCode, réduit la sélection
    global nb_repetitions := 1
}

; È.Ê★É
; SC02A::	Send("^h")
SC056:: { ; Dupliquer la ligne vers le haut
    Send("!+{Up " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC02C:: { ; Déplacer la ligne vers le haut
    Send("!{Up " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC02D:: { ; Déplacer la ligne vers le bas
    Send("!{Down " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC02E:: { ; Dupliquer la ligne vers le bas
    Send("!+{Down " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC02F:: {
    Send("+!{Right " . nb_repetitions . "}") ; Dans VSCode, étend la sélection
    global nb_repetitions := 1
}
SC030::
{ ; Dupliquer la ligne vers le bas
    Send("!+{Down " . nb_repetitions . "}")
    global nb_repetitions := 1
}

; === MAIN DROITE ===

; DLP’
SC015:: { ; Sélection de tout jusqu’au début de la ligne
    Send("+{Home}")
    global nb_repetitions := 1
}
SC016:: { ; Déplacement de mot en mot + sélection vers la gauche
    Send("^+{Left " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC017:: { ; Sélection vers la gauche
    Send("+{Left " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC018:: { ; Sélection vers la droite
    Send("+{Right " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC019:: { ; Déplacement de mot en mot + sélection vers la droite
    Send("^+{Right " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC01A:: { ; Sélection de tout jusqu’à la fin de la ligne
    Send("+{End}")
    global nb_repetitions := 1
}

; SNTR
SC023:: { ; Début de la ligne
    Send("{Home}")
    global nb_repetitions := 1
}
SC024:: { ; Déplacement de mot en mot vers la gauche
    Send("^{Left " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC025:: { ; ⇦
    Send("{Left " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC026:: { ; ⇨
    Send("{Right " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC027:: { ; Déplacement de mot en mot vers la droite
    Send("^{Right " . nb_repetitions . "}")
    global nb_repetitions := 1
}
SC028:: { ; Fin de la ligne
    Send("{End}")
    global nb_repetitions := 1
}

; CHGX
SC031:: { ; Passer la fenêtre en plein écran
    WinMaximize("A")
    global nb_repetitions := 1
}
SC032:: { ; Déplacer à l’écran de gauche
    Send("#+{Left}")
    global nb_repetitions := 1
}
SC033:: { ; Déplacer la fenêtre à gauche
    Send("#{Left}")
    global nb_repetitions := 1
}
SC034:: { ; Déplacer la fenêtre à droite
    Send("#{Right}")
    global nb_repetitions := 1
}
SC035:: {
    Send("#+{Right}") ; Déplacer à l’écran de droite
    global nb_repetitions := 1
}
; Send("{Ctrl Down}{Down}{Ctrl Up}{Up}{End}") ; Aller à la fin du paragraphe
; Send("{Ctrl Down}{Up}{Ctrl Up}{Home}") ; Aller au début du paragraphe
#HotIf

; ===============================================
; ===============================================
; ===============================================
; ================ 3/ RACCOURCIS ================
; ===============================================
; ===============================================
; ===============================================

#InputLevel 51
; Touche de répétition et d’expansion de texte
SC02E:: Send("★") ; Remplacement par la touche ★ de : la touche "J" sur le pilote HyperTexte, la touche "V" en AZERTY
#InputLevel 49

; Capslock est transformé en BackSpace
SC03A::BackSpace
+SC03A::Delete ; Shift + "Capslock"
<^>!SC03A:: Send("{LCtrl Down}{BackSpace}{LCtrl Up}") ; AltGr + "Capslock"
+<^>!SC03A:: Send("{LCtrl Down}{Delete}{LCtrl Up}") ; Shift + AltGr + "Capslock"
#SC03A:: { ; Win + "Capslock"
    if GetKeyState("CapsLock", "T")
        SetCapsLockState("AlwaysOff")
    else
        SetCapsLockState("AlwaysOn")
}

+SC039:: Send("{U+002D}") ; -, Résout le problème du double tiret dans Google Docs

; ======= Ctrl + Alt différent de AltGr sur la rangée des chiffres =======
^!SC002:: Send("^!{Numpad1}") ; Ctrl + Alt + 1
^!SC003:: Send("^!{Numpad2}") ; Ctrl + Alt + 2
^!SC004:: Send("^!{Numpad3}") ; Ctrl + Alt + 3
^!SC005:: Send("^!{Numpad4}") ; Ctrl + Alt + 4
^!SC006:: Send("^!{Numpad5}") ; Ctrl + Alt + 5
^!SC007:: Send("^!{Numpad6}") ; Ctrl + Alt + 6
^!SC008:: Send("^!{Numpad7}") ; Ctrl + Alt + 7
^!SC009:: Send("^!{Numpad8}") ; Ctrl + Alt + 8
^!SC00A:: Send("^!{Numpad9}") ; Ctrl + Alt + 9
^!SC00B:: Send("^!{Numpad0}") ; Ctrl + Alt + 0

; ==============================================================================================
; ==============================================================================================
; ==============================================================================================
; ================ 4/ RÉDUCTION DES DISTANCES, DES SFBs ET MEILLEURS ROULEMENTS ================
; ==============================================================================================
; ==============================================================================================
; ==============================================================================================

SendMode("Event") ; Tout ce qui concerne les hotstrings DOIT être en Event et non Input qui est la valeur par défaut
#InputLevel 40

; =====================================================
; ======= 4.1) , DEVIENT UN J AVEC LES VOYELLES =======
; =====================================================

:*?C:,è::
:*?C:,à::
{
    Send("j")
}
:*?C: ;è::
:*?C: ;È::
:*?C:,È::
:*?C: ;à::
:*?C:,À::
:*?C: ;À::
{
    Send("J")
}

; JA
:*?C:,a::
{
    Send("ja")
}
:*?C:,A::
{
    Send("jA")
}
:*?C: ;a::
{
    Send("Ja")
}
:*?C: ;A::
{
    Send("JA")
}

; JI
:*?C:,i::
{
    Send("ji")
}
:*?C:,I::
{
    Send("jI")
}
:*?C: ;i::
{
    Send("Ji")
}
:*?C: ;I::
{
    Send("JI")
}

; JE
:*?C:,e::
{
    Send("je")
}
:*?C:,E::
{
    Send("jE")
}
:*?C: ;e::
{
    Send("Je")
}
:*?C: ;E::
{
    Send("JE")
}

; JO
:*?C:,o::
{
    Send("jo")
}
:*?C:,O::
{
    Send("jO")
}
:*?C: ;o::
{
    Send("Jo")
}
:*?C: ;O::
{
    Send("JO")
}

; JU
:*?C:,u::
:*?C:,ê::
{
    Send("ju")
}
:*?C:,U::
:*?C:,Ê::
{
    Send("jU")
}
:*?C: ;u::
:*?C: ;ê::
{
    Send("Ju")
}
:*?C: ;U::
:*?C: ;Ê::
{
    Send("JU")
}

; JÉ
:*?C:,é::
{
    Send("jé")
}
:*?C:,É::
{
    Send("jÉ")
}
:*?C: ;é::
{
    Send("Jé")
}
:*?C: ;É::
{
    Send("JÉ")
}

; J’
:*?C:,'::
{
    Send("j’")
}
:*?C: ;'::
{
    Send("J’")
}
:*?CB0: ; ?::
{
    Send("{BackSpace 4}J’")
}

; =====================================================================
; ======= 4.2) AUTRES RACCOURCIS AVEC , : POUR RÉDUIRE LES SFBs =======
; =====================================================================

; ======= Rangée du haut =======

; Yi
:*?C:,y::
{
    Send("yi")
}
:*?C:,Y::
{
    Send("yI")
}
:*?C: ;y::
{
    Send("Yi")
}
:*?C: ;Y::
{
    Send("YI")
}

; Ds
:*?C:,f::
{
    Send("fs")
}
:*?C:,F::
{
    Send("fS")
}
:*?C: ;f::
{
    Send("Fs")
}
:*?C: ;F::
{
    Send("FS")
}

; Ds
:*?C:,d::
{
    Send("ds")
}
:*?C:,D::
{
    Send("dS")
}
:*?C: ;d::
{
    Send("Ds")
}
:*?C: ;D::
{
    Send("DS")
}

; cL
:*?C:,l::
{
    Send("cl")
}
:*?C:,L::
{
    Send("cL")
}
:*?C: ;l::
{
    Send("Cl")
}
:*?C: ;L::
{
    Send("CL")
}

; xP
:*?C:,p::
{
    Send("xp")
}
:*?C:,P::
{
    Send("xP")
}
:*?C: ;p::
{
    Send("Xp")
}
:*?C: ;P::
{
    Send("XP")
}

; bj
:*?C:,z::
{
    Send("bj")
}
:*?C:,Z::
{
    Send("bJ")
}
:*?C: ;z::
{
    Send("Bj")
}
:*?C: ;Z::
{
    Send("BJ")
}

; ======= Rangée du milieu =======

; dV
:*?C:,v::
{
    Send("dv")
}
:*?C:,V::
{
    Send("dV")
}
:*?C: ;v::
{
    Send("Dv")
}
:*?C: ;V::
{
    Send("DV")
}

; Sc
:*?C:,s::
{
    Send("sc")
}
:*?C:,S::
{
    Send("sC")
}
:*?C: ;s::
{
    Send("Sc")
}
:*?C: ;S::
{
    Send("SC")
}

; Nl
:*?C:,n::
{
    Send("nl")
}
:*?C:,N::
{
    Send("nL")
}
:*?C: ;n::
{
    Send("Nl")
}
:*?C: ;N::
{
    Send("NL")
}

; pT
:*?C:,t::
{
    Send("pt")
}
:*?C:,T::
{
    Send("pT")
}
:*?C: ;t::
{
    Send("Pt")
}
:*?C: ;T::
{
    Send("PT")
}

; Rq
:*?C:,r::
{
    Send("rq")
}
:*?C:,R::
{
    Send("rQ")
}
:*?C: ;r::
{
    Send("Rq")
}
:*?C: ;R::
{
    Send("RQ")
}

; Qu’
:*?C:,q::
:*?C:,Q::
{
    Send("qu’")
}
:*?C: ;q::
{
    Send("Qu’")
}
:*?C: ;Q::
{
    Send("QU’")
}

; ======= Rangée du bas =======

; mpl
:*?C:,m::
{
    Send("mpl")
}
:*?C: ;M::
{
    Send("MPL")
}

; Cd
:*?:,c::
{
    Send("cd")
}
:*?:,C::
{
    Send("cD")
}
:*?C: ;c::
{
    Send("Cd")
}
:*?C: ;C::
{
    Send("CD")
}

; pH
:*?C:,h::
{
    Send("ph")
}
:*?C:,H::
{
    Send("pH")
}
:*?C: ;h::
{
    Send("ph")
}
:*?C: ;H::
{
    Send("PH")
}

; Gl
:*?C:,g::
{
    Send("gl")
}
:*?C:,G::
{
    Send("gL")
}
:*?C: ;g::
{
    Send("Gl")
}
:*?C: ;G::
{
    Send("GL")
}

; 're (pour we're, you're, etc.)
:*?C:,x::
{
    Send("'re")
}
:*?C:,x::
:*?C:,X::
{
    Send("'RE")
}

; ==============================================================
; ======= 4.3) RACCOURCIS AVEC Ê : POUR RÉDUIRE LES SFBs =======
; ==============================================================

; eO
:*?C:êe::
{
    Send("eo")
}
:*?C:êE::
{
    Send("eO")
}
:*?C:Êe::
{
    Send("Eo")
}
:*?C:ÊE::
{
    Send("EO")
}

; Oe
:*?C:eê::
{
    Send("oe")
}
:*?C:eÊ::
{
    Send("oE")
}
:*?C:Eê::
{
    Send("Oe")
}
:*?C:EÊ::
{
    Send("OE")
}

; Pour éviter le SFB AÎ
:*?C:êé::
{
    Send("aî")
}
:*?C:êÉ::
{
    Send("aÎ")
}
:*?C:Êé::
{
    Send("Aî")
}
:*?C:ÊÉ::
{
    Send("AÎ")
}

; Pour éviter le SFB Â
:*?C:éê::
{
    Send("â")
}
:*?C:éÊ::
:*?C:Éê::
:*?C:ÉÊ::
{
    Send("Â")
}

; ==============================================================
; ======= 4.4) RACCOURCIS AVEC È : POUR RÉDUIRE LES SFBs =======
; ==============================================================

; Oe
:*?C:èo::
{
    Send("oe")
}
:*?C:Èo::
{
    Send("Oe")
}
:*?C:èO::
{
    Send("oE")
}
:*?C:ÈO::
{
    Send("OE")
}

; Eo
:*?C:èe::
{
    Send("eo")
}
:*?C:Èe::
{
    Send("Eo")
}
:*?C:èE::
{
    Send("eO")
}
:*?C:ÈE::
{
    Send("EO")
}

; bu
:*?C:uè::
{
    Send("ub")
}
:*?C:uÈ::
{
    Send("uB")
}
:*?C:Uè::
{
    Send("Ub")
}
:*?C:UÈ::
{
    Send("UB")
}

; ub
:*?C:èu::
{
    Send("bu")
}
:*?C:èU::
{
    Send("bU")
}
:*?C:Èu::
{
    Send("Bu")
}
:*?C:ÈU::
{
    Send("BU")
}

; u.
:*?C:è.::
{
    Send("u.")
}
:*?C:È.::
:*?C:È `:::
{
    Send("U.")
}

; u,
:*?C:è,::
{
    Send("u,")
}
:*?C:È,:: {
    Send("U,")
}
:*?CB0:È `;::
{
    Send("{BackSpace 3}U,")
}

; ===========================================
; ======= 4.5) ROULEMENTS MAIN GAUCHE =======
; ===========================================

; Pour éviter le SFB ÉI
:*?C:yè::
{
    Send("éi")
}
:*?C:yÈ::
{
    Send("éI")
}
:*?C:Yè::
{
    Send("Éi")
}
:*?C:YÈ::
{
    Send("ÉI")
}

; Pour éviter le SFB IÉ
:*?C:èy::
{
    Send("ié")
}
:*?C:éY::
{
    Send("iÉ")
}
:*?C:Èy::
{
    Send("Ié")
}
:*?C:ÈY::
{
    Send("IÉ")
}

; Pour faire EZ
:*?C:eé::
{
    Send("ez")
}
:*?C:eÉ::
{
    Send("eZ")
}
:*?C:Eé::
{
    Send("Ez")
}
:*?C:EÉ::
{
    Send("EZ")
}

; Meilleur moyen de commenter, avec un roulement
:*?:\"::
{
    Send("/*")
}
:*?:"\::
{
    Send("*/")
}

; ===========================================
; ======= 4.6) ROULEMENTS MAIN DROITE =======
; ===========================================

; ======= Rangée du haut =======

:*?:=$::
{
    Send(" = `"")
}

; Roulement assignation
:*?:?+::
{
    Send(" <- ")
}
:*?:+?::
{
    Send("➜")
}

; qu’
:?*C:p'::
{
    Send("qu’")
}
:*C:P'::
{
    Send("Qu’")
}
:*CB0:P ?::
{
    Send("{BackSpace 3}QU’")
}

; ======= Rangée du milieu =======

; Roulement ("
:*?:(=::
{
    Send("(`"")
}

; ======= Rangée du bas =======

; Roulement :=
:*?:ç#::
{
    Send("{Space}:={Space}")
}

; Roulement !=
:*?:#ç::
{
    Send(" {!}= ")
}

; GHt
:*?C:ghc::
{
    Send("ght")
}
:*?C:GHC::
{
    Send("GHT")
}

; Gt
:*?C:gx::
{
    Send("gt")
}
:*?C:gX::
{
    Send("gT")
}
:*?C:Gx::
{
    Send("Gt")
}
:*?C:GX::
{
    Send("GT")
}

; wh
:*?CB0:hc::
{
    Send("{BackSpace 2}wh")
}
:*?C:Hc::
{
    Send("Wh")
}
:*?C:HC::
{
    Send("WH")
}

; ===========================================================
; ===========================================================
; ===========================================================
; ================ 5/ CORRECTION AUTOMATIQUE ================
; ===========================================================
; ===========================================================
; ===========================================================

SendMode("Event") ; Tout ce qui concerne les hotstrings DOIT être en Event et non Input qui est la valeur par défaut
#InputLevel 30

; ==========================================================
; ======= 5.1) Q devient QU si une voyelle est après =======
; ==========================================================

; Problème : Q + lettre ne fonctionne pas avec one shot shift

; Qua
:*?C:qa::
{
    Send("qua")
}
:*?C:Qa::
{
    Send("Qua")
}
:*?C:QA::
{
    Send("QUA")
}

; Que
:*?C:qe::
{
    Send("que")
}
:*?C:Qe::
{
    Send("Que")
}
:*?C:QE::
{
    Send("QUE")
}

; Qué
:*?C:qé::
{
    Send("qué")
}
:*?C:Qé::
{
    Send("Qué")
}
:*?C:QÉ::
{
    Send("QUÉ")
}

; Què
:*?C:qé::
{
    Send("què")
}
:*?C:Qè::
{
    Send("Què")
}
:*?C:QÈ::
{
    Send("QUÈ")
}

; Quê
:*?C:qê::
{
    Send("quê")
}
:*?C:Qê::
{
    Send("Quê")
}
:*?C:QÊ::
{
    Send("QUÊ")
}

; Qui
:*?C:qi::
{
    Send("qui")
}
:*?C:Qi::
{
    Send("Qui")
}
:*?C:QI::
{
    Send("QUI")
}

; Quo
:*?C:qo::
{
    Send("quo")
}
:*?C:Qo::
{
    Send("Quo")
}
:*?C:QO::
{
    Send("QUO")
}

; Qu’
:*?C:q'::
{
    Send("qu’")
}
:*?C:Q'::
{
    Send("Qu’")
}
:*?CB0:Q ?::
{
    Send("{BackSpace 3}QU’")
}

; ====================================================================================================
; ======= 5.2) CONVERSION AUTOMATIQUE DE L’APOSTROPHE DROITE EN TYPOGRAPHIQUE POUR LE FRANÇAIS =======
; ====================================================================================================

; c’
:*C:c'::
{
    Send("c’")
}
:*C:C'::
{
    Send("C’")
}
:*CB0:C ?::
{
    Send("{BackSpace 3}C’")
}

; d’
:*C:d'::
{
    Send("d’")
}
:*C:D'::
{
    Send("D’")
}
:*CB0:D ?::
{
    Send("{BackSpace 3}D’")
}

; j’
:*C:j'::
{
    Send("j’")
}
:*C:J'::
{
    Send("J’")
}
:*CB0:J ?::
{
    Send("{BackSpace 3}J’")
}

; l’
:*C:l'::
{
    Send("l’")
}
:*C:L'::
{
    Send("L’")
}
:*CB0:L ?::
{
    Send("{BackSpace 3}L’")
}

; m’
:*C:m'::
{
    Send("m’")
}
:*C:M'::
{
    Send("M’")
}
:*CB0:M ?::
{
    Send("{BackSpace 3}M’")
}

; n’
:*C:n'::
{
    Send("n’")
}
:*C:N'::
{
    Send("N’")
}
:*CB0:N ?::
{
    Send("{BackSpace 3}N’")
}

; s’
:*C:s'::
{
    Send("s’")
}
:*C:S'::
{
    Send("S’")
}
:*CB0:S ?::
{
    Send("{BackSpace 3}S’")
}

; t’
:*C:t'::
{
    Send("t’")
}
:*C:T'::
{
    Send("T’")
}
:*CB0:T ?::
{
    Send("{BackSpace 3}T’")
}

; ====================================================================
; ======= 5.3) Ê fait office de touche morte ^ sur clavier ISO =======
; ====================================================================

:*?C:êa::â
:*?C:êA::Â
:*?C:Êa::Â
:*?C:ÊA::Â

:*?C:êi::î
:*?C:êI::Î
:*?C:Êi::Î
:*?C:ÊI::Î

:*?C:êo::ô
:*?C:êO::Ô
:*?C:Êo::Ô
:*?C:ÊO::Ô

:*?C:êu::û
:*?C:êU::Û
:*?C:Êu::Û
:*?C:ÊU::Û

; ====================================
; ======= 5.4) Suffixes avec À =======
; ====================================

; Aire
:*?C:àa::
{
    Send("aire")
}
:*?C:Àa::
:*?C:àA::
{
    Send("Aire")
}
:*?C:ÀA::
{
    Send("AIRE")
}

; En I ?

; ement
:*?C:àe::
{
    Send("ement")
}
:*?C:àE::
{
    Send("Ement")
}

; Able
:*?C:àê::
{
    Send("able")
}
:*?C:àÊ::
:*?C:Àê::
{
    Send("Able")
}
:*?C:ÀÊ::
{
    Send("ABLE")
}
; eZ-vous
:*?C:àz::
{
    Send("ez-vous")
}
:*?C:àZ::
{
    Send("Ez-vous")
}
; ique
:*?C:àk::
{
    Send("ique")
}
:*?C:àK::
:*?C:Àk::
{
    Send("Ique")
}
:*?C:ÀK::
{
    Send("IQUE")
}

; En miroir du M qui fait isMe, en F c’est isTe
:*?C:àf::
{
    Send("iste")
}
:*?C:Àf::
:*?C:àF::
{
    Send("Iste")
}
:*?C:ÀF::
{
    Send("ISTE")
}
; coulD
:*?C:càd::
{
    Send("could")
}
:*?C:Càd::
{
    Send("Could")
}
; shoulD
:*?C:shàd::
{
    Send("should")
}
:*?C:Shàd::
{
    Send("Should")
}
; oulD
:*?C:àd::
{
    Send("ould")
}
:*?C:àD::
:*?C:Àd::
{
    Send("Ould")
}
:*?C:ÀD::
{
    Send("OULD")
}
; eLLe
:*?C:àl::
{
    Send("elle")
}
:*?C:àL::
{
    Send("Elle")
}
; ouGht
:*?C:àp::
{
    Send("ought")
}
:*?C:àP::
:*?C:Àp::
{
    Send("Ought")
}
:*?C:ÀP::
{
    Send("OUGHT")
}
; ettRe
:*?C:à'::
{
    Send("ettre")
}
:*?CB0: `;'::
:*?CB0:à ?::
{
    Send("{Backspace 3}Ettre")
}
:*?CB0: `; ?::
{
    Send("{Backspace 4}ETTRE")
}

; isMe
:*?C:àm::
{
    Send("isme")
}
:*?C:àM::
{
    Send("ISME")
}
; ement
:*?C:às::
{
    Send("ement")
}
:*?C:Às::
:*?C:àS::
{
    Send("Ement")
}
:*?C:ÀS::
{
    Send("EMENT")
}
; atioN
:*?C:àn::
{
    Send("ation")
}
:*?C:àN::
{
    Send("Ation")
}
; cTion
:*?C:àt::
{
    Send("ction")
}
:*?C:àT::
:*?C:Àt::
{
    Send("Ction")
}
:*?C:ÀT::
{
    Send("CTION")
}
; eRRe
:*?C:àr::
{
    Send("erre")
}
:*?C:àR::
{
    Send("Erre")
}

; Ying (même colonne que le Y et I, mais sur une touche plus accessible)
:*?C:àé::
{
    Send("ying")
}
:*?C:Àé::
{
    Send("Ying")
}
:*?C:ÀÉ::
{
    Send("YING")
}

; Ub
:*?C:àu::
{
    Send("ub")
}
:*?C:àU::
{
    Send("uB")
}
:*?C:Àu::
{
    Send("Ub")
}
:*?C:ÀU::
{
    Send("UB")
}

; Les hotstrings doivent être définis avant bu, sinon ne sont jamais activées
:*:aà★::aujourd’hui
:*:mà★::mise à jour
:*:pià★::pièce jointe
:*:tà★::toujours
; bu
:*?C:à★::
{
    Send("bu")
}
:*?C:À★::
{
    Send("Bu")
}

; enCe
:*?C:àc::
{
    Send("ence")
}
:*?C:Àc::
:*?C:àC::
{
    Send("Ence")
}
:*?C:ÀC::
{
    Send("ENCE")
}

; tecHn
:*?C:àh::
{
    Send("techn")
}
:*?C:àH::
{
    Send("Techn")
}

; iGht
:*?C:àg::
{
    Send("ight")
}
:*?C:ÀG::
{
    Send("IGHT")
}

; ieuX
:*?C:àx::
{
    Send("ieux")
}
:*?C:àX::
{
    Send("Ieux")
}

; iQue
:*?C:àq::
{
    Send("ique")
}
:*?C:Àq::
{
    Send("Ique")
}
:*?C:ÀQ::
{
    Send("IQUE")
}

; =======================================================================
; ======= 5.5) Correction automatique (notamment ajout d’accents) =======
; =======================================================================

; Il peut y avoir des conflits, notamment en anglais
#InputLevel 29

; Pour pouvoir enchaîner deux fois des suffixes, comme aim|able|ement
:?*:eement::ement
:?*:éement::ement
:*?:elleence::ellence
:*?:elleance::ellance
:*?:elleement::ellement
:*:règleement::règlement
:*:probableement::probablement
:*?:qement::quement

#HotIf autocorrection

:*?:°C::℃
:*:(_::({Space}
:*:)_::){Space}
:*:+_::{+}{Space}
:*:#_::#{Space}
:*:$_::${Space}
:*:=_::={Space}
:*:[_::[{Space}
:*:]_::]{Space}
:*:~_::~{Space}
:*:*_::*{Space}
:*?:=_::={Space}
:*:abime::abîme
:*:accroit::accroît
:*:affut::affût
::agé::âgé
::agée::âgée
::agés::âgés
::agées::âgées
:*:ainé::aîné
::alexei::Alexeï
:*:ambigue::ambiguë
:*:ambigui::ambiguï
::ame::âme
::ames::âmes
::anais::Anaïs
::ane::âne
:*:anerie::ânerie
::anes::ânes
::angstrom::ångström
:*:aout::août
::apre::âpre
:*:appat::appât
:*:archaique::archaïque
:*:archaisme::archaïsme
::arome::arôme
::aromes::arômes
:*:aout::août
:*:auà::aujourd’hui
:*:aumone::aumône
::aussitot::aussitôt
:*:autohot::AutoHotkey
::avant-gout::avant-goût
::avec excel::avec Excel
::avec word::avec Word
::babord::bâbord
::baille::bâille
:*:bailler::bâiller
:*:baillon::bâillon
:*:batard::bâtard
:*:bati::bâti
:*:baton::bâton
::benoit::benoît
:*:bientot::bientôt
:*:binome::binôme
:*?:boeuf::bœuf
:*?:boit::boît
:*:brul::brûl
:*:buche::bûche
:*:cable::câble
:*:calin::câlin
::canoe::canoë
::canoes::canoës
::cdiers::CDIERS
::chaine::chaîne
:*?:chainé::chaîné
:*:chassis::châssis
:*:chateau::château
:*:chatg::ChatGPT
::chatier::châtier
::chatiment::châtiment
::chatiments::châtiments
:*:chomage::chômage
:*:chomer::chômer
:*:chomeu::chômeu
:*:citroen::Citroën
:*:Cleopatre::Cléopâtre
:*:Cléopatre::Cléopâtre
:*:cloture::clôture
:*:clotures::clôtures
:*:cloturé::clôturé
::coeur::cœur
:*:coincide::coïncide
:*:cone::cône
:*:cones::cônes
:*?:connait::connaît
:*:controlé::contrôlé
:*:controle::contrôle
::cout::coût
::coute::coûte
::couter::coûter
:*:couteu::coûteu
::couts::coûts
::cote::côte
::cotes::côtes
:*:coté::côté
:*:cotoie::côtoie
:*:cotoy::côtoy ; côtoyer
:?:connaitre::connaître
:*?:croitre::croître
:*:crouton::croûton
::csp::CSP
:*:débacle::débâcle
:*:dégat::dégât
:*:dégout::dégoût
::dépot::dépôt
:*:dépots::dépôts
:*:diplome::diplôme
:*:diplomé::diplômé
:*:doisje::dois-je
:*:drole::drôle
::dubai::Dubaï
:*?:dument::dûment
:*:egoiste::egoïste
:*:embuch::embûch
::en excel::en Excel
::en word::en Word
:*:enchaine::enchaîne
::enjoleur::enjôleur
:*:enrole::enrôle
:*:entrainant::entraînant
:*:entrepot::entrepôt
:*:envout::envoût
::et excel::et Excel
::et word::et Word
:*?:eua::eau ; Correction d’un mauvais enchaînement eau
:*?:aeu::eau ; Correction d’un mauvais enchaînement eau
:*b0:htt::{Space}{BackSpace 4}https:// ; Gère le cas de l’autocomplétion du navigateur
:*:faché::fâché
:*:fache::fâche
:*:fantome::fantôme
:*:fichier excel::fichier Excel
:*:fichier word::fichier Word
:*:fichiers excel::fichiers Excel
:*:fichiers word::fichiers Word
::flane::flâne
::flanes::flânes
::flanez::flânez
:*:flaner::flâner
:*:flaneu::flâneu
:*:flute::flûte
:*:foetus::fœtus
::foret::forêt
::forets::forêts
::froler::frôler
:*?:fraich::fraîch
:*:gach::gâch
::gateau::gâteau
::gateaux::gâteaux
:*:gaté::gâté
::gater::gâter
::geole::geôle
::geoles::geôles
:*:geolier::geôlier
::gout::goût
:*:gouter::goûter
:*:héroique::héroïque
:*:héroisme::héroïsme
:*:heroique::héroïque
:*:heroisme::héroïsme
:*?:honnete::honnête
:*:hopita::hôpita
:*:hotel::hôtel
::huitre::huître
::huitres::huîtres
:*:icone::icône
::idolatr::idolâtr
::ile::île
::iles::îles
::ilot::îlot
::ilots::îlots
::impot::impôt
::impots::impôts
::indument::indûment
::infame::infâme
::infames::infâmes
:*:infamie::infâmie
:*:inoui::inouï
::insee::INSEE
:*:israel::Israël
:*:it’s::it's
:*:jerome::Jérôme
:*:jérome::Jérôme
::jeuner::jeûner
:*:joel::Joël
:*:jus’::jusqu’
::kpi::KPI
:*:lache::lâche
:*:laique::laïque
:*:latex::LaTeX
:*:le excel::le Excel
:*:le word::le Word
:*:les notres::les nôtres
:*:les votres::les vôtres
:*:lualatex::LuaLaTeX
::mache::mâche
::macher::mâcher
::machoire::mâchoire
::machoires::mâchoires
::machouille::mâchouille
:*:maelstrom::maelström
:*:malstrom::malström
:*:maitr::maîtr
::male::mâle
::males::mâles
:*:manoeuvr::manœuvr
::maratre::marâtre
::mbti::MBTI
:*?:meler::mêler
::mome::môme
::momes::mômes
:*:mosaique::mosaïque
:*:multitache::multitâche
:*:murement::mûrement
:*:murir::mûrir
:*?:nt'::n't ; Meilleur roulement en anglais
:*:naif::naïf
:*:naive::naïve
:*:naitre::naître
:*:noel::Noël
::oecuméni::œcuméni
:*:oeil::œil
::oesophage::œsophage
:*:oeuf::œuf
:*:oeuvre::œuvre
:*?:oiaque::oïaque
:*?:oide::oïde
:*:onedrive::OneDrive
:*:onenote::OneNote
:*:opiniatre::opiniâtre
:*:ouie::ouïe
::ouvre-boites::ouvre-boîtes
:*:où .::où.
:*:où ,::où,
:*:oter::ôter
:*:paella::paëlla
::pale::pâle
::pales::pâles
::palir::pâlir
:*?:parait::paraît
:*?:paraitre::paraître
::paté::pâté
:*:patés::pâtés
::pate::pâte
:*:pates::pâtes
:*:patir::pâtir
:*:patiss::pâtiss
:*:patur::pâtur
::peuxtu::peux-tu
:*:phoenix::phœnix
:*:photovoltai::photovoltaï
:*:piqure::piqûre
::plait::plaît
:*:platre::plâtre
:*:plutot::plutôt
::pole::pôle
::poles::pôles
:*:polynom::polynôm
:*:powerbi::PowerBI
:*:powerpoint::PowerPoint
:*:prosaique::prosaïque
::pylone::pylône
::pylones::pylônes
:*:raler::râler
:*:raphael::Raphaël
:*:relache::relâche
:*:roti::rôti
:*:samourai::samouraï
:*:sharepoint::SharePoint
:*:soeur::sœur
::soule::soûle
:*:souler::soûler
::soules::soûles
:*:stoique::stoïque
:*:stoicisme::stoïcisme
:*:sur excel::sur Excel
:*:sur office::sur Office
:*:sur outlook::sur Outlook
:*:sur word::sur Word
:*:sur teams::sur Teams
:*:surement::sûrement
::sureté::sûreté
:*:surcout::surcoût
:*:surcroit::surcroît
:*:surs::sûrs
:*?:symptom::symptôm
:*:taiwan::Taïwan
:*:tantot::tantôt
:*:theatr::théâtr
:*:théatr::théâtr
::tole::tôle
::toles::tôles
::tolstoi::Tolstoï
:*:traitr::traîtr
:*?:traine::traîne
:*:trinome::trinôme
:*?:trone::trône
::veuxtu::veux-tu
::voeu::vœu
:*:voeux::vœux
:*:vscode::VSCode
:*?:ww::www.
::yatil::y a-t-il
#HotIf

; =================================================
; =================================================
; =================================================
; ================ 6/ ABRÉVIATIONS ================
; =================================================
; =================================================
; =================================================

SendMode("Event") ; Tout ce qui concerne les hotstrings DOIT être en Event et non Input qui est la valeur par défaut

:*:1er★::premier
:*:1ere★::première
:*:2e★::deuxième
:*:3e★::troisième
:*:4e★::quatrième
:*:5e★::cinquième
:*:6e★::sixième
:*:7e★::septième
:*:8e★::huitième
:*:9e★::neuvième
:*:10e★::dixième
:*:11e★::onzième
:*:12e★::douzième
:*:20e★::vingtième
:*:100e★::centième
:*:1000e★::millième
:*://★::rapport
:*:+m★::meilleur
:*:!★::{!}important
:*:!i★::{!}important
:*:àpad★::à partir de
:*:a★::ainsi
:*:abr★::abréviation
:*:abrs★::abréviations
:*:acqui★::acquisition
:*:actus★::actualités
:*:add★::addresse
:*:adds★::addresses
:*:ade★::Assurance des Emprunteurs
:*:admin★::administrateur
:*:adt★::arrêt de travail
:*:aé★::assuré
:*:aés★::assurés
:*:afn★::affaire nouvelle
:*:afns★::affaires nouvelles
:*:afr★::à faire
:*:ahk★::AutoHotkey
:*:ai★::intelligence artificielle
:*:aije★::ai-je
:*:ajd★::aujourd’hui
:*:algo★::algorithme
:*:algos★::algorithmes
:*:am★::Adrien Moyaux
:*:amé★::amélioration
:*:amélio★::amélioration
:*:ano★::anomalie
:*:anos★::anomalies
:*:ans★::affaires nouvelles
:*:anniv★::anniversaire
:*:aoa★::absence d’opportunité d’arbitrage
:*:apad★::à partir de
:*:apm★::après-midi
:*:app★::application
:*:apps★::applications
:*:appart★::appartement
:*:appli★::application
:*:applis★::applications
:*:approx★::approximation
:*:approx★::approximation
:*:approxs★::approximations
:*:ass★::assurance
:*:assé★::assuré
:*:assr★::assureur
:*:assrs★::assureurs
:*:asss★::assurances
:*:asso★::association
:*:assos★::associations
:*:asap★::le plus rapidement possible
:*:atd★::attend
:*:atelle★::a-t-elle
:*:atil★::a-t-il
:*:aton★::a-t-on
:*:att★::attention
:*:aud★::aujourd’hui
:*:auj★::aujourd’hui
:*:auto★::automatique
:*:autos★::automatiques
:*:autot★::automatiquement
:*:av★::avant
:*:avv★::avez-vous
:*:avvd★::avez-vous déjà
:*:b★::bonjour
:*:b7★::BeSeven
:*:bb★::bébé
:*:bc★::because
:*:bcp★::beaucoup
:*:bdd★::base de données
:*:bdds★::bases de données
:*:bec★::because
:*:bg★::background
:*:bgc★::background-color:
:*:bib★::bibliographie
:*:biblio★::bibliographie
:*:bjr★::bonjour
:*:brain★::brainstorming
:*:bs★::beseven
:*:b7★::BeSeven
:*:bsr★::bonsoir
:*:btw★::between
:*:bv★::bravo
:*:bvn★::bienvenue
:*:bvs★::bravos
:*:bwe★::bon week-end
:*:c★::c’est
:*:ca★::Crédit Agricole
:*:càd★::c’est-à-dire
:*:cad★::c’est-à-dire
:*:caf★::chiffre d’affaires
:*:caff★::chiffre d’affaires
:*:camp★::campagne
:*:camps★::campagnes
:*:carac★::caractère
:*:caracs★::caractères
:*:caracq★::caractéristique
:*:caracqs★::caractéristiques
:*:carto★::cartographie
:*:cartos★::cartographies
:*:cb★::combien
:*:cc★::copier-coller
:*:ccé★::copié-collé
:*:ccl★::conclusion
:*:ccls★::conclusions
:*:cdg★::Charles de Gaulle
:*:cdr★::compte de résultat
:*:cdt★::cordialement
:*:certif★::certification
:*:cg★::conditions générales
:*:cgs★::conditions générales
:*:chg★::charge
:*:chap★::chapitre
:*:chr★::chercher
:*:ci★::ci-joint
:*:cj★::ci-joint
:*:coeff★::coefficient
:*:coeffs★::coefficients
:*:cog★::cognition
:*:cogv★::cognitive
:*:comp★::comprendre
:*:cond★::condition
:*:conds★::conditions
:*:config★::configuration
:*:configs★::configurations
:*:chgt★::changement
:*:chgts★::changements
:*:cnp★::ce n’est pas
:*:cols★::columns
:*:contrib★::contribution
:*:couv★::couverture
:*:cov★::covariance
:*:cp★::code postal
:*:cpd★::cependant
:*:cpdt★::cependant
:*:cr★::compte-rendu
:*:csp★::catégorie socioprofessionnelle
:*:csps★::catégories socioprofessionnelles
:*:ct★::c’était
:*:cv★::ça va ?
:*:cvt★::ça va toi ?
:*:ctc★::est-ce que cela te convient ?
:*:ctr★::contrat
:*:ctrs★::contrats
:*:cvc★::est-ce que cela vous convient ?
:*:d★::donc
:*:dac★::d’accord
:*:dacty★::dactylographie
:*:dactyq★::dactylographique
:*:db★::database
:*:dc★::décès
:*:dctc★::décès toutes causes
:*:dd★::dossier-dossier
:*:dde★::dégât des eaux
:*:ddl★::download
:*:dê★::d’être
:*:dé★::déjà
:*:déc★::décembre
:*:dec★::décembre
:*:dedt★::d’emploi du temps
:*:def★::définition
:*:defs★::définitions
:*:démo★::démonstration
:*:demo★::démonstration
:*:dep★::département
:*:deux★::deuxième
:*:deuxt★::deuxièmement
:*:desc★::description
:*:descs★::descriptions
:*:dév★::développeur
:*:dev★::développeur
:*:devr★::développer
:*:devt★::développement
:*:df★::dataframe
:*:dico★::dictionnaire
:*:dicos★::dictionnaires
:*:diff★::différence
:*:diffs★::différences
:*:difft★::différent
:*:diffts★::différents
:*:difftes★::différentes
:*:dim★::dimension
:*:dims★::dimensions
:*:dispo★::disponible
:*:dispos★::disponibles
:*:dispot★::disponibilité
:*:dispots★::disponibilités
:*:distri★::distributeur
:*:distrib★::distributeur
:*:dj★::déjà
:*:dm★::donne-moi
:*:la doc★::la documentation
:*:une doc★::une documentation
:*:doc★::document
:*:docs★::documents
:*:dp★::de plus
:*:ds★::datascience
:*:dst★::datascientist
:*:dsl★::désolé
:*:dsls★::désolés
:*:dt★:: ; This hotstring replaces dt★ with the current date via the commands below.
{
    CurrentDateTime := FormatTime(, "dd/MM/yyyy") ; It will look like 19/01/2005
    Send(CurrentDateTime)
}
:*:dtm★::détermine
:*:dtmr★::déterminer
:*:dtmé★::déterminé
:*:dtmés★::déterminés
:*:dvlp★::développe
:*:dvlpr★::développer
:*:dvlpt★::développent
:*:dwh★::Data Warehouse
:*:ém★::écris-moi
:*:é★::écart
:*:e★::est
:*:echant★::échantillon
:*:echants★::échantillons
:*:eco★::économie
:*:ecos★::économies
:*:ecoq★::économique
:*:ecoqs★::économiques
:*:ecq★::est-ce que
:*:edt★::emploi du temps
:*:eef★::en effet
:*:elt★::élément
:*:elts★::éléments
:*:eo★::en outre
:?:eme★::ᵉ
:?:ème★::ᵉ
:*:enc★::encore
:*:eng★::english
:*:enft★::en fait
:*:ens★::ensemble
:*:enss★::ensembles
:*:ent★::entreprise
:*:ents★::entreprises
:*:env★::environ
:*:ep★::épisode
:*:eps★::épisodes
:*:eq★::équation
:*:eqs★::équations
:*:este★::est-elle
:*:estelle★::est-elle
:*:esti★::est-il
:*:estil★::est-il
:*:ety★::étymologie
:*:eve★::événement
:*:eves★::événements
:*:evtl★::éventuel
:*:evtle★::éventuelle
:*:evtlt★::éventuellement
:*:ex★::exemple
:*:exo★::exercice
:*:exos★::exercices
:*:exs★::exemples
:*:exp★::expérience
:*:expo★::exposition
:*:exps★::expériences
:*:êe★::est-ce
:*:éq★::équation
:*:éqs★::équations
:*:ê★::être
:*:êt★::es-tu
:*:f★::faire
:*:fam★::famille
:*:fb★::Facebook
:*:fig★::figure
:*:fct★::fonction
:*:fcts★::fonctions
:*:fcte★::fonctionne
:*:fctet★::fonctionnent
:*:fctr★::fonctionner
:*:fea★::feature
:*:fev★::février
:*:fi★::financier
:*:fiè★::financière
:*:ff★::Firefox
:*:fl★::falloir
:*:fpdf★::filetype:pdf
:*:freq★::fréquence
:*:freqs★::fréquences
:*:fr★::France
:*:frs★::français
:*:fs★::fais
:*:ft★::fait
:*:g★::j’ai
:*:gar★::garantie
:*:gars★::garanties
:*:gb★::gradient boosting
:*:gc★::git commit
:*:gca★::git commit --amend
:*:gcm★::git commit -m ""{Left}
:*:gd★::grand
:*:gg★::Google
:*:ges★::gestion
:*:gf★::J’ai fait
:*:ggl★::Google
:*:gh★::GitHub
:*:gm★::git merge
:*:goo★::Google
:*:gov★::government
:*:gouv★::gouvernement
:*:indiv★::individuel
:*:gpa★::je n’ai pas
:*:gt★::j’étais
:*:gvt★::gouvernement
:*:gvts★::gouvernements
:*:h★::heure
:*:his★::historique
:*:histo★::historique
:*:hy★::HyperTexte
:*:hyp★::hypothèse
:*:hyps★::hypothèses
:*:ia★::intelligence artificielle
:*:ic★::intervalle de confiance
:*:ics★::intervalles de confiance
:*:id★::identifiant
:*:idf★::Île-de-France
:*:idk★::I don't know
:*:ids★::identifiants
:*:img★::image
:*:imgs★::images
:*:imm★::immeuble
:*:imo★::in my opinion
:*:imp★::impossible
:*:inf★::inférieur
:*:info★::information
:*:infos★::informations
:*:insta★::Instagram
:*:intart★::intelligence artificielle
:*:inter★::international
:*:intro★::introduction
:*:intros★::introductions
:*:j★::bonjour
:*:ja★::jamais
:*:janv★::janvier
:*:jm★::j’aime
:*:jms★::jamais
:*:jnsp★::je ne sais pas
:*:js★::je suis
:*:jsp★::je sais pas
:*:jtm★::je t’aime
:*:jui★::juillet
:*:ju★::jusque
:*:k★::contacter
:*:kb★::keyboard
:*:kbd★::keyboard
:*:km★::kilomètre
:*:kn★::construction
:*:ko★::❌
:*:ks★::KOMA-Script
:*:lê★::l’être
:*:lds★::Livre de Savoir
:*:ledt★::l’emploi du temps
:*:lex★::l’exemple
:*:lim★::limite
:*:llm★::large language model
:*:lsex★::les exemples
:*:m★::mais
:*:ma★::madame
:*:maj★::mise à jour
:*:màj★::mise à jour
:*:math★::mathématique
:*:manip★::manipulation
:*:maths★::mathématiques
:*:max★::maximum
:*:maxs★::maximums
:*:md★::milliard
:*:mds★::milliards
:*:mdav★::merci d’avance
:*:mdb★::merci de bien vouloir
:*:mdl★::modèle
:*:mdls★::modèles
:*:mdp★::mot de passe
:*:mdps★::mots de passe
:*:méthodo★::méthodologie
:*:més★::multiéquipés
:*:min★::minimum
:*:mins★::minimums
:*:mio★::million
:*:mios★::millions
:*:mjo★::mettre à jour
:*:ml★::machine learning
:*:mm★::même
:*:mme★::madame
:*:mms★::mêmes
:*:modif★::modification
:*:modifs★::modifications
:*:mom★::moi-même
:*:morta★::mortalité
:*:mortas★::mortalités
:*:mrc★::merci
:*:msg★::message
:*:msgs★::messages
:*:mt★::montant
:*:mtn★::maintenant
:*:moy★::moyenne
:*:moys★::moyennes
:*:mq★::montre que
:*:mr★::monsieur
:*:mrc★::merci
:*:mtn★::maintenant
:*:mtnt★::maintenant
:*:mtq★::montrent que
:*:mutu★::mutualiser
:*:mvt★::mouvement
:*:mvts★::mouvements
:*:mzq★::montrez que
:*:n★::nouveau
:*:nat★::Natixis
:*:nav★::navigation
:*:nb★::nombre
:*:nbs★::nombres
:*:nean★::néanmoins
:*:new★::nouveau
:*:newx★::nouveaux
:*:newe★::nouvelle
:*:newes★::nouvelles
:*:nimp★::n’importe
:*:niv★::niveau
:*:nivs★::niveaux
:*:nivx★::niveaux
:*:norm★::normalement
:*:not★::notebook
:*:nota★::notamment
:*:notm★::notamment
:*:nouv★::nouvelle
:*:nouvs★::nouvelles
:*:nov★::novembre
:*:now★::maintenant
:*:np★::ne pas
:*:nrj★::énergie
:*:nrjs★::énergies
:*:ns★::nous
:*:num★::numéro
:*:nums★::numéros
:*:o★::ajout
:*:o-★::au moins
:*:o+★::au plus
:*:obj★::objectif
:*:objs★::objectifs
:*:obs★::observation
:*:oct★::octobre
:*:odj★::ordre du jour
:*:ok★::✔️
:*:opé★::opération
:*:oqp★::occupé
:*:oqpe★::occupe
:*:ordi★::ordinateur
:*:ordis★::ordinateurs
:*:org★::organisation
:*:orga★::organisation
:*:out★::Où es-tu ?
:*:outv★::Où êtes-vous ?
:*:ouv★::ouverture
:*:ouvs★::ouvertures
:*:p//★::par rapport
:*:p★::prendre
:*:par★::paragraphe
:*:pars★::paragraphes
:*:param★::paramètre
:*:params★::paramètres
:*:pb★::problème
:*:pbi★::Power BI
:*:pbs★::problèmes
:*:pc★::prime commerciale
:*:pcd★::précède
:*:pcdt★::précédent
:*:pcdmt★::précédemment
:*:pcq★::parce que
:*:pck★::parce que
:*:pcqil★::parce qu’il
:*:pckil★::parce qu’il
:*:pcqon★::parce qu’on
:*:pckon★::parce qu’on
:*:pd★::pendant
:*:pdt★::pendant
:*:pdv★::point de vue
:*:pdvs★::points de vue
:*:perf★::performance
:*:perfs★::performances
:*:perso★::personne
:*:persos★::personnes
:*:pê★::peut-être
:*:pé★::prime émise
:*:péri★::périmètre
:*:périm★::périmètre
:*:pés★::primes émises
:*:peut-ê★::peut-être
:*:pex★::par exemple
:*:pf★::portefeuille
:*:pfs★::portefeuilles
:*:pg★::pas grave
:*:pgm★::programme
:*:pi★::pour information
:*:pic★::picture
:*:pics★::pictures
:*:piè★::pièce jointe
:*:pj★::pièce jointe
:*:pjs★::pièces jointes
:*:pk★::pourquoi
:*:pks★::pourquois
:*:pls★::please
:*:poum★::plus ou moins
:*:poss★::possible
:*:possb★::possibilité
:*:possbs★::possibilités
:*:pourcent★::pourcentage
:*:ppt★::PowerPoint
:*:pq★::pourquoi
:*:pqs★::pourquois
:*:prd★::produit
:*:prdt★::produit
:*:prem★::premier
:*:preme★::première
:*:prez★::présentation
:*:prg★::programme
:*:pro★::professionnel
:*:proba★::probabilité
:*:probas★::probabilités
:*:prod★::production
:*:prog★::programme
:*:prop★::propriété
:*:propo★::proposition
:*:propos★::propositions
:*:props★::propriétés
:*:pros★::professionnels
:*:prot★::professionnellement
:*:prov★::provision
:*:provs★::provisions
:*:psycha★::psychanalyse
:*:psycho★::psychologie
:*:psychoq★::psychologique
:*:prof★::professeur
:*:profs★::professeurs
:*:prog★::programme
:*:psb★::possible
:*:psbs★::possibles
:*:psy★::psychologie
:*:psyq★::psychologique
:*:pt★::point
:*:ptf★::portefeuille
:*:ptfs★::portefeuilles
:*:pts★::points
:*:pub★::publicité
:*:pvv★::pouvez-vous
:*:py★::python
:*C:pys★::pyspark
:*C:Pys★::PySpark
:*:q★::question
:*:qc★::qu’est-ce
:*:qcq★::qu’est-ce que
:*:qcq'★::qu’est-ce qu’
:*:qdd★::qualité des données
:*:qq★::quelque
:*:qqch★::quelque chose
:*:qqs★::quelques
:*:qqn★::quelqu’un
:*:qs★::questions
:*:qss★::questionnaire de santé simplifié
:*:quasi★::quasiment
:*:ques★::question
:*:quess★::questions
:*:quid★::qu’en est-il de
:*:r7★::recette
:*:r★::rien
:*:rapidt★::rapidement
:*:rc★::responsabilité civile
:*:rdv★::rendez-vous
:*:réass★::réassurance
:*:rép★::répertoire
:*:résil★::résiliation
:*:résils★::résiliations
:*:reass★::réassurance
:*:ref★::référence
:*:refs★::références
:*:rep★::répertoire
:*:rex★::retour d’expérience
:*:renta★::rentabilité
:*:resp★::responsabilité
:*:rmd★::R Markdown
:*:rmq★::remarque
:*:rmqs★::remarques
:*:rn★::risque-neutre
:*:rpz★::représente
:*:rs★::résultat
:*:rsls★::risques spéciaux lignes spécialisées
:*:rss★::résultats
:*:rt★::risque technique
:*:s★::sous
:*:s2★::Solvabilité II
:*:seg★::segment
:*:segm★::segment
:*:sep★::septembre
:*:sept★::septembre
:*:simplt★::simplement
:*:sin★::sinistre
:*:situ★::situation
:*:situs★::situations
:*:sg★::Société Générale
:*:smth★::something
; :*:sol★::solution ; Conflit avec sollicitation
:*:sp★::SharePoint
:*:sql★::SQL
:*:srx★::sérieux
:*:ssi★::si et seulement si
:*:st★::s’était
:*:stat★::statistique
:*:stats★::statistiques
:*:sth★::something
:*:sto★::stochastique
:*:stp★::s’il te plaît
:*:strat★::stratégique
:*:stream★::streaming
:*:suff★::suffisant
:*:sufft★::suffisament
:*:supé★::supérieur
:*:surv★::survenance
:*:svp★::s’il vous plaît
:*:svt★::souvent
:*:sya★::s’il y a
:*:syn★::synonyme
:*:sync★::synchronisation
:*:syncs★::synchronisations
:*:sys★::système
:*:t★::très
:*:tàf★::tout à fait
:*:taf★::travail à faire
:*:tarif★::tarification
:*:tb★::très bien
:*:tdb★::tableau de bord
:*:tdbs★::tableaux de bord
:*:temp★::temporaire
:*:tél★::téléphone ; Pas tel car sinon problème pour écrire tel★e que
:*:téls★::téléphones
:*:teq★::telle que
:*:teqs★::telles que
:*:tff★::tenfastfingers
:*:tfk★::qu’est-ce que tu fais ?
:*:tgh★::together
:*:théo★::théorie
:*:thm★::théorème
:*:thms★::théorèmes
:*:tj★::toujours
:*:tjr★::toujours
:*:tjrs★::toujours
:*:tlm★::tout le monde
:*:tnr★::Times New Roman
:*:tq★::tel que
:*:tqs★::tels que
:*:tout★::toutefois
:*:trkl★::tranquille
:*:ts★::tous
:*:tt★::télétravail
:*:tte★::toute
:*:ttes★::toutes
:*:tv★::télévision
:*:tvl★::travail
:*:tvlr★::travailler
:*:tvs★::télévisions
:*:tw★::Twitter
:*:twi★::Twitter
:*:ty★::thank you
:*:uniqt★::uniquement
:*:usa★::États-Unis
:*:v★::version
:*:vàv★::vis-à-vis
:*:va★::variable aléatoire
:*:var★::variable
:*:vars★::variables
:*:vas★::variables aléatoires
:*:vav★::vous avez
:*:vect★::vecteur
:*:vérif★::vérification
:*:verif★::vérification
:*:vit★::vitamine
:*:vocab★::vocabulaire
:*:volat★::volatilité
:*:vrm★::vraiment
:*:vrmt★::vraiment
:*:vrt★::vraiment
:*:vs★::vous êtes
:*:vsc★::VSCode
:*:w★::with
:*:wd★::Windows
:*:wknd★::week-end
:*:what★::WhatsApp
:*:wiki★::Wikipédia
:*:wk★::week-end
:*:ya★::il y a
:*:yapa★::il n’y a pas
:*:yatil★::y a-t-il
:*:yc★::y compris
:*:yt★::YouTube
:*:x★::exemple
:*:xg★::XGBoost

; ========================
; ======= Symboles =======
; ========================

:*:1/★::⅟
:*:1/2★::½
:*:0/3★::↉
:*:1/3★::⅓
:*:2/3★::⅔
:*:1/4★::¼
:*:3/4★::¾
:*:1/5★::⅕
:*:2/5★::⅖
:*:3/5★::⅗
:*:4/5★::⅘
:*:1/6★::⅙
:*:5/6★::⅚
:*:1/8★::⅛
:*:3/8★::⅜
:*:5/8★::⅝
:*:7/8★::⅞
:*:1/7★::⅐
:*:1/9★::⅑
:*:1/10★::⅒
:*:(0)★::•
:*:(1)★::➀
:*:(2)★::➁
:*:(3)★::➂
:*:(4)★::➃
:*:(5)★::➄
:*:(6)★::➅
:*:(7)★::➆
:*:(8)★::➇
:*:(9)★::➈
:*:(10)★::➉
:*:(1n)★::➊
:*:(2n)★::➋
:*:(3n)★::➌
:*:(4n)★::➍
:*:(5n)★::➎
:*:(6n)★::➏
:*:(7n)★::➐
:*:(8n)★::➑
:*:(9n)★::➒
:*:(10n)★::➓
:*:(1b)★::𝟏
:*:(2b)★::𝟐
:*:(3b)★::𝟑
:*:(4b)★::𝟒
:*:(5b)★::𝟓
:*:(6b)★::𝟔
:*:(7b)★::𝟕
:*:(8b)★::𝟖
:*:(9b)★::𝟗
:*:(0b)★::𝟎
:*:(1g)★::𝟭
:*:(2g)★::𝟮
:*:(3g)★::𝟯
:*:(4g)★::𝟰
:*:(5g)★::𝟱
:*:(6g)★::𝟲
:*:(7g)★::𝟳
:*:(8g)★::𝟴
:*:(9g)★::𝟵
:*:(0g)★::𝟬
:*:(a)★::➢
:*:(b)★::•
:*:(c)★::©
:*:(é)★::★
:*:(inf)★::∞
:*:(f)★::⌕
:*:(l)★::⌕
:*:(m)★::¶ ; Pied de Mouche
:*:(m2)★::⁋ ; Pied de Mouche
:*:(o)★::⭮
:*:(p)★::★
:*:(r)★::®
:*:(s)★::★
:*:(tm)★::™
:*:(v)★::✓
:*:(x)★::✗
:*:<==★::⇐
:*:<=>★::⇔
:*:<==>★::⇔
:*:==>★::⇒
:*:-->★::➜
:*:/!\★::⚠
:*:***★::⁂
:*:[v]★::☑
:*:[x]★::☒
:*:|->★::↪
:*:<-|★::↩
:*:^||★::↑
:*:||^★::↓
:*:||v★::↓

; ======================
; ======= Emojis =======
; ======================

#InputLevel 28

:*::)★::😀
:*::3★::😗
:*::D★::😁
:*::P★::😛
:*:abeille★::🐝
:*:aigle★::🦅
:*:aimant★::🧲
:*:amour★::🥰
:*:ampoule★::💡
:*:araignée★::🕷️
:*:arbre★::🌲
:*:argent★::💰
:*:attention★::⚠️
:*:aubergine★::🍆
:*:balance★::⚖️
:*:banane★::🍌
:*:batterie★::🔋
:*:lunettes★::😎
:*:bisou★::😘
:*:blanc★::🏳️
:*:bombe★::💣
:*:bouche★::🤭
:*:boussole★::🧭
:*:burger★::🍔
:*:caca★::💩
:*:cadeau★::🎁
:*:cadenas★::🔒
:*:carotte★::🥕
:*:chameau★::🐪
:*:clavier★::⌨️
:*:chat★::🐈
:*:chèvre★::🐐
:*:check★::✔️
:*:cheval★::🐎
:*:chien★::🐕
:*:chocolat★::🍫
:*:clé★::🔑
:*:clin★::😉
:*:cloche★::🔔
:*:cochon★::🐖
:*:coco★::🥥
:*:coeur★::❤️
:*:cœur★::❤️
:*:cookie★::🍪
:*:couronne★::👑
:*:cowboy★::🤠
:*:croco★::🐊
:*:crocodile★::🐊
:*:croissant★::🥐
:*:croix★::❌
:*:cygne★::🦢
:*:dauphin★::🐬
:*:délice★::😋
:*:délicieux★::😋
:*:diamant★::💎
:*:dislike★::👎
:*:douche★::🛁
:*:dragon★::🐉
:*:éclair★::⚡
:*:éléphant★::🐘
:*:eau★::💧
:*:email★::📧
:*:escargot★::🐌
:*:étoile★::⭐
:*:effroi★::😱
:*:facepalm★::🤦
:*:faux★::❌
:*:feu★::🔥
:*:fete★::🎉
:*:fête★::🎉
:*:film★::🎬
:*:fourmi★::🐜
:*:frites★::🍟
:*:girafe★::🦒
:*:hamburger★::🍔
:*:hotdog★::🌭
:*:idée★::💡
:*:idee★::💡
:*:innocent★::😇
:*:intello★::🤓
:*:interdit★::⛔
:*:journal★::📰
:*:koala★::🐨
:*:lama★::🦙
:*:lapin★::🐇
:*:larme★::😢
:*:larmes★::😭
:*:licorne★::🦄
:*:like★::👍
:*:lion★::🦁
:*:lit★::🛏️
:*:lol★::😂
:*:loupe★::🔎
:*:lunettes★::🤓
; :*:mail★::📧 ; Mail★e ne fonctionne alors plus
:*:mdr★::😂
:*:médaille★::🥇
:*:medaille★::🥇
:*:mignon★::🥺
:*:monocle★::🧐
:*:montre★::⌚
:*:mouton★::🐑
:*:nice::👌
:*:noel★::🎄
:*:olaf★::⛄
:*:ordi★::💻
:*:ordinateur★::💻
:*:ouf★::😅
:*:oups★::😅
:*:ours★::🐻
:*:panda★::🐼
:*:papillon★::🦋
:*:parfait★::👌
:*:paresseux★::🦥
:*:pates★::🍝
:*:pc★::💻
:*:penser★::🤔
:*:pensif★::🤔
:*:perroquet★::🦜
:*:pingouin★::🐧
:*:pirate★::🏴‍☠️
:*:pizza★::🍕
:*:pleur★::😭
:*:pleurer★::😭
:*:poisson★::🐟
:*:pomme★::🍎
:*:popcorn★::🍿
:*:pouce★::👍
:*:poussin★::🐣
:*:radioactif★::☢️
:*:rat★::🐀
:*:requin★::🦈
:*:rhinocéros★::🦏
:*:rhinoceros★::🦏
:*:rire★::😂
; :*:sac★::💼 ; Sacc ne fonctionne pas
:*:sacoche★::💼
:*:sandwich★::🥪
:*:serpent★::🐍
:*:singe★::🐒
:*:snif::😢
:*:souris★::🐁
:*:spaghetti★::🍝
:*:tacos★::🌮️
:*:terre★::🌍
:*:thermomètre★::🌡️
:*:timer★::⏲️
:*:tomate★::🍅
:*:toilette★::🧻
:*:tortue★::🐢
:*:trex★::🦖
:*:telephone★::☎️
:*:téléphone★::☎️
:*:triste★::😢
:*:vache★::🐄
:*:voiture★::🚗

; =========================================
; ======= 6.6) Touche de répétition =======
; =========================================

; ★ = Touche de répétition par défaut, ne s’active que si cela ne correspond pas à un mot défini dans les listes de raccourcis définies plus haut

:?*:0★::
{
    Send(00)
}
:?*:1★::
{
    Send(11)
}
:?*:2★::
{
    Send(22)
}
:?*:3★::
{
    Send(33)
}
:?*:4★::
{
    Send(44)
}
:?*:5★::
{
    Send(55)
}
:?*:6★::
{
    Send(66)
}
:?*:7★::
{
    Send(77)
}
:?*:8★::
{
    Send(88)
}
:?*:9★::
{
    Send(99)
}

:?*C:à★::
{
    Send("àà")
}
:?*C:À★::
{
    Send("ÀÀ")
}

:?*C:a★::
{
    Send("aa")
}
:?*C:A★::
{
    Send("AA")
}

:?*C:b★::
{
    Send("bb")
}
:?*C:B★::
{
    Send("BB")
}

:?*C:c★::
{
    Send("cc")
}
:?*C:C★::
{
    Send("CC")
}

:?*C:d★::
{
    Send("dd")
}
:?*C:D★::
{
    Send("DD")
}

:?*C:é★::
{
    Send("éé")
}
:?*C:É★::
{
    Send("ÉÉ")
}

:?*C:è★::
{
    Send("èè")
}
:?*C:È★::
{
    Send("ÈÈ")
}

:?*C:ê★::
{
    Send("êê")
}
:?*C:Ê★::
{
    Send("ÊÊ")
}

:?*C:e★::
{
    Send("ee")
}
:?*C:E★::
{
    Send("EE")
}

:?*C:f★::
{
    Send("ff")
}
:?*C:F★::
{
    Send("FF")
}

:?*C:g★::
{
    Send("gg")
}
:?*C:G★::
{
    Send("GG")
}

:?*C:h★::
{
    Send("hh")
}
:?*C:H★::
{
    Send("HH")
}

:?*C:i★::
{
    Send("ii")
}
:?*C:I★::
{
    Send("II")
}

:?*C:j★::
{
    Send("jj")
}
:?*C:J★::
{
    Send("JJ")
}

:?*C:k★::
{
    Send("kk")
}
:?*C:K★::
{
    Send("KK")
}

:?*C:l★::
{
    Send("ll")
}
:?*C:L★::
{
    Send("LL")
}

:?*C:m★::
{
    Send("mm")
}
:?*C:M★::
{
    Send("MM")
}

:?*C:n★::
{
    Send("nn")
}
:?*C:N★::
{
    Send("NN")
}

:?*C:o★::
{
    Send("oo")
}
:?*C:O★::
{
    Send("OO")
}

:?*C:p★::
{
    Send("pp")
}
:?*C:P★::
{
    Send("PP")
}

:?*C:q★::
{
    Send("qq")
}
:?*C:Q★::
{
    Send("QQ")
}

:?*C:r★::
{
    Send("rr")
}
:?*C:R★::
{
    Send("RR")
}

:?*C:s★::
{
    Send("ss")
}
:?*C:S★::
{
    Send("SS")
}

:?*C:t★::
{
    Send("tt")
}
:?*C:T★::
{
    Send("TT")
}

:?*C:u★::
{
    Send("uu")
}
:?*C:U★::
{
    Send("UU")
}

:?*C:v★::
{
    Send("vv")
}
:?*C:V★::
{
    Send("VV")
}

:?*C:w★::
{
    Send("ww")
}
:?*C:W★::
{
    Send("WW")
}

:?*C:x★::
{
    Send("xx")
}
:?*C:X★::
{
    Send("XX")
}

:?*C:y★::
{
    Send("yy")
}
:?*C:Y★::
{
    Send("YY")
}

:?*C:z★::
{
    Send("zz")
}
:?*C:Z★::
{
    Send("ZZ")
}

:?*:-★::
{
    Send("--")
}
:?*:_★::
{
    Send("__")
}

:?*:``★::
{
    Send("````")
}
:?*:@★::
{
    Send("@@")
}
:?*:$★::
{
    Send("$$")
}
:?*:=★::
{
    Send("==")
}
:?*:+★::
{
    Send("++")
}
:?*:?★::
{
    Send("??")
}
:?*:!★::
{
    Send("!!")
}

:?*:<★::
{
    Send("<<")
}
:?*:>★::
{
    Send(">>")
}
:?*:`{★::
{
    Send("{{}{{}")
}
:?*:`}★::
{
    Send("{}}{}}")
}
:?*:`;★::
{
    Send("`;`;")
}
:?*:|★::
{
    Send("||")
}
:?*:(★::
{
    Send("((")
}
:?*:)★::
{
    Send("))")
}
:?*:[★::
{
    Send("[[")
}
:?*:]★::
{
    Send("]]")
}

:?*:^★::
{
    Send("{^}{^}")
}
:?*:/:★::
{
    Send("//")
}
:?*:\★::
{
    Send("\\")
}
:?*:&★::
{
    Send("&&")
}
:?*:#★::
{
    Send("##")
}
:?*:~★::
{
    Send("~~")
}
:?*:*★::
{
    Send("**")
}

#InputLevel 1
; Correction du problème de SFB ★U

:?*C:ccê::
{
    Send("ccu")
}
:?*C:CCê::
:?*C:CCÊ::
{
    Send("CCU")
}

:?*C:ddê::
{
    Send("ddu")
}
:?*C:DDê::
:?*C:DDÊ::
{
    Send("DDU")
}

:?*C:ffê::
{
    Send("ffu")
}
:?*C:FFê::
:?*C:FFÊ::
{
    Send("FFU")
}

:?*:llê::
{
    Send("llu")
}
:?*:LLê::
:?*:LLÊ::
{
    Send("LLU")
}

:?*C:mmê::
{
    Send("mmu")
}
:?*C:MMê::
:?*C:MMÊ::
{
    Send("MMU")
}

; Cas particulier de honnête
:?*C:honnê::
{
    Send("honnê")
}
:?*C:Honnê::
{
    Send("Honnê")
}
:?*C:HONNÊ::
{
    Send("HONNÊ")
}

:?*C:nnê::
{
    Send("nnu")
}
:?*C:NNê::
:?*C:NNÊ::
{
    Send("NNU")
}

:?*C:ppê::
{
    Send("ppu")
}
:?*C:PPê::
:?*C:PPÊ::
{
    Send("PPU")
}

; Cas particulier de arrêt
:?*C:arrê::
{
    Send("arrê")
}
:?*C:Arrê::
{
    Send("Arrê")
}
:?*C:ARRÊ::
{
    Send("ARRÊ")
}
:?*:rrê::rru

:?*C:ssê::
{
    Send("ssu")
}
:?*C:SSê::
:?*C:SSÊ::
{
    Send("SSU")
}

:?*C:ttê::
{
    Send("ttu")
}
:?*C:TTê::
:?*C:TTÊ::
{
    Send("TTU")
}
