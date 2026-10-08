#!/usr/bin/env python3
"""
Menage sur les 142 pages de ukrainefrance.org :

  1. Supprime le bandeau de consentement du traducteur IONOS (div #pbModal).
     Ce bloc n'est plus affiche depuis la migration — le JavaScript qui le
     declenchait a ete retire — mais son texte francais pollue l'index de
     recherche de toutes les pages.

  2. Met a jour la mention de copyright en pied de page.

Usage :
    python3 menage.py                   -> pied de page « © 2026 »
    python3 menage.py "жовтень 2026"    -> pied de page « © жовтень 2026 »
    python3 menage.py --verif           -> n'ecrit rien, montre ce qui serait fait

Relancez ensuite  python3 recherche.py  pour reconstruire l'index.
"""
import pathlib, re, sys

ROOT = pathlib.Path("site-mirror")
if not ROOT.is_dir():
    sys.exit("Dossier site-mirror introuvable. Lancez le script depuis /workspaces/ukrainefrance")

arg = sys.argv[1] if len(sys.argv) > 1 else ""
VERIF = (arg == "--verif")
MENTION = "2026" if (VERIF or not arg) else arg

# Le bloc va de <div class="page-blocker-modal" id="pbModal"> jusqu'a la
# fermeture de ce div. On compte les div ouverts/fermes pour trouver la bonne
# balise fermante, plutot que de se fier a une expression reguliere.
OUVERTURE = '<div class="page-blocker-modal" id="pbModal">'


def retire_bandeau(h: str):
    i = h.find(OUVERTURE)
    if i < 0:
        return h, False
    profondeur, j = 0, i
    for m in re.finditer(r'<div\b[^>]*>|</div>', h[i:]):
        profondeur += 1 if m.group(0).startswith('<div') else -1
        if profondeur == 0:
            j = i + m.end()
            break
    else:
        return h, False          # structure inattendue : on ne touche a rien
    return h[:i] + h[j:], True


def maj_pied(h: str, mention: str):
    neuf = f'<p style="text-align:center;">© {mention}</p>'
    nouveau, n = re.subn(
        r'<p style="text-align:center;">©[^<]*</p>', neuf, h)
    return nouveau, n > 0


pages = [f for f in sorted(ROOT.rglob("*.html"))
         if not f.name.startswith("_") and f.name != "poshuk.html"]

nb_bandeau = nb_pied = nb_ecrits = 0
for f in pages:
    avant = f.read_text(encoding="utf-8", errors="replace")
    h, fait_b = retire_bandeau(avant)
    h, fait_p = maj_pied(h, MENTION)
    nb_bandeau += fait_b
    nb_pied += fait_p
    if h != avant:
        nb_ecrits += 1
        if not VERIF:
            f.write_text(h, encoding="utf-8")

print(f"{len(pages)} page(s) examinee(s)")
print(f"  bandeau de consentement : {nb_bandeau} supprime(s)")
print(f"  pied de page            : {nb_pied} mis a jour -> « © {MENTION} »")
print(f"  fichiers modifies       : {nb_ecrits}")
if VERIF:
    print("\n(mode --verif : aucun fichier n'a ete ecrit)")
else:
    print("\nPensez a relancer :  python3 recherche.py")
