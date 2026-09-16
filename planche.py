#!/usr/bin/env python3
"""
Planche de contrôle complète des images de ukrainefrance.org.

Contrairement a la version precedente, celle-ci part du HTML : elle lit
chaque page, releve toutes les balises <img> reellement affichees, et les
regroupe par page avec le titre de la page.

Sortie : site-mirror/_planche.html
  - une section par page, titre et nombre d'images
  - sous chaque vignette : l'identifiant a passer a remplace-image.sh,
    l'origine (banque IONOS ou televersement), les dimensions du fichier
  - une derniere section listant les images presentes sur le disque
    mais referencees par aucune page

Usage :  python3 planche.py
"""
import pathlib, re, collections, html as H
from urllib.parse import unquote
from bs4 import BeautifulSoup
from PIL import Image

ROOT = pathlib.Path("site-mirror")
SORTIE = ROOT / "_planche.html"

if not ROOT.is_dir():
    raise SystemExit("Dossier site-mirror introuvable. Lancez depuis /workspaces/ukrainefrance")


def resoudre(src: str, page: pathlib.Path):
    """Convertit une URL d'image en chemin de fichier local, ou None."""
    if not src or src.startswith(("data:", "http://", "https://", "//")):
        return None
    src = unquote(src.split("?")[0].split("#")[0])
    cible = (ROOT / src.lstrip("/")) if src.startswith("/") else (page.parent / src)
    try:
        cible = cible.resolve()
        if ROOT.resolve() in cible.parents and cible.is_file():
            return cible
    except Exception:
        pass
    return None


def identifiant(chemin: pathlib.Path):
    """Identifiant court utilisable avec remplace-image.sh, et origine."""
    p = chemin.as_posix()
    m = re.search(r"/assets/([0-9a-f][0-9a-f-]{7,})", p)
    if m:
        return m.group(1)[:8], "banque IONOS"
    m = re.search(r"/files/([0-9a-f][0-9a-f-]{7,})", p)
    if m:
        return m.group(1)[:8], "televersement"
    return "", "autre"


# --- relever les images page par page ---------------------------------------
pages = collections.OrderedDict()
vus_global = set()

for page in sorted(ROOT.rglob("*.html")):
    if page.name.startswith("_"):
        continue
    soup = BeautifulSoup(page.read_text(encoding="utf-8", errors="replace"), "lxml")
    titre = soup.title.get_text(strip=True) if soup.title else ""
    if not titre:
        h = soup.find(["h1", "h2"])
        titre = h.get_text(" ", strip=True) if h else ""

    trouvees, vus_page = [], set()
    for img in soup.find_all("img"):
        src = img.get("src") or ""
        if not src and img.get("srcset"):
            src = img["srcset"].split(",")[0].strip().split(" ")[0]
        f = resoudre(src, page)
        if not f or f in vus_page:
            continue
        vus_page.add(f); vus_global.add(f)
        uid, origine = identifiant(f)
        try:
            with Image.open(f) as im:
                dims = f"{im.width}x{im.height}"
        except Exception:
            dims = "?"
        trouvees.append({
            "url": "/" + f.relative_to(ROOT.resolve()).as_posix(),
            "uid": uid, "origine": origine, "dims": dims,
            "alt": img.get("alt", "").strip(),
        })

    if trouvees:
        pages[page.relative_to(ROOT).as_posix()] = (titre[:90], trouvees)

# --- images orphelines -------------------------------------------------------
EXT = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ""}
orphelines = []
for f in ROOT.rglob("*"):
    if not f.is_file() or f.suffix.lower() not in EXT:
        continue
    if "/res/" not in f.as_posix() or f.resolve() in vus_global:
        continue
    try:
        with Image.open(f) as im:
            if im.width < 60:      # ignorer les pixels de suivi et puces
                continue
            dims = f"{im.width}x{im.height}"
    except Exception:
        continue
    uid, origine = identifiant(f)
    orphelines.append({"url": "/" + f.relative_to(ROOT).as_posix(),
                       "uid": uid, "origine": origine, "dims": dims, "alt": ""})

# ne garder qu'une taille par identifiant orphelin, la plus grande
meilleur = {}
for o in orphelines:
    cle = o["uid"] or o["url"]
    larg = int(o["dims"].split("x")[0]) if "x" in o["dims"] else 0
    if cle not in meilleur or larg > meilleur[cle][0]:
        meilleur[cle] = (larg, o)
orphelines = [v[1] for v in meilleur.values()]

# --- rendu -------------------------------------------------------------------
total = sum(len(v[1]) for v in pages.values())
ionos = sum(1 for _, (_, imgs) in pages.items() for i in imgs if i["origine"] == "banque IONOS")

CSS = """
body{font-family:system-ui,sans-serif;background:#eceff3;margin:0;padding:24px;color:#1b2430}
h1{font-size:20px;margin:0 0 4px}
.resume{color:#55606e;font-size:14px;margin-bottom:20px}
h2{font-size:15px;margin:26px 0 10px;padding:8px 12px;background:#23374d;color:#fff;border-radius:5px}
h2 span{float:right;font-weight:400;opacity:.8}
figure{display:inline-block;width:206px;margin:0 8px 12px 0;background:#fff;padding:8px;
       border-radius:6px;vertical-align:top;box-shadow:0 1px 3px rgba(0,0,0,.12)}
figure.ionos{outline:2px solid #d98324}
img{width:100%;display:block;border-radius:3px;background:#f4f4f4}
figcaption{font:12px ui-monospace,monospace;padding-top:6px;line-height:1.5;word-break:break-all}
.uid{font-weight:700;color:#b3430f}
.meta{color:#6b7684;font-size:11px}
.alt{color:#2c6e49;font-family:system-ui,sans-serif;font-size:11px}
.legende{background:#fff;padding:10px 14px;border-radius:6px;font-size:13px;line-height:1.7}
"""

out = [f'<!doctype html><meta charset="utf-8"><title>Planche des images</title><style>{CSS}</style>',
       "<h1>Planche de contrôle des images</h1>",
       f'<div class="resume">{total} images affichées sur {len(pages)} pages — '
       f'dont <b>{ionos}</b> issues de la banque IONOS (encadrées en orange).</div>',
       '<div class="legende">Pour remplacer&nbsp;: '
       '<code>bash remplace-image.sh IDENTIFIANT mon-image.jpg</code><br>'
       'Les images sans identifiant ne sont pas dans une arborescence de variantes '
       'et se remplacent directement par écrasement du fichier.</div>']

def bloc(i):
    cls = "ionos" if i["origine"] == "banque IONOS" else ""
    uid = f'<span class="uid">{i["uid"]}</span>' if i["uid"] else '<span class="meta">(sans id)</span>'
    alt = f'<div class="alt">{H.escape(i["alt"][:60])}</div>' if i["alt"] else ""
    return (f'<figure class="{cls}"><img src="{i["url"]}" loading="lazy">'
            f'<figcaption>{uid}<div class="meta">{i["origine"]} · {i["dims"]}</div>{alt}</figcaption></figure>')

for page, (titre, imgs) in pages.items():
    n_i = sum(1 for i in imgs if i["origine"] == "banque IONOS")
    out.append(f'<h2>{H.escape(page)} — {H.escape(titre or "?")}'
               f'<span>{len(imgs)} images · {n_i} IONOS</span></h2>')
    out += [bloc(i) for i in imgs]

if orphelines:
    out.append(f'<h2>Images présentes sur le disque mais affichées par aucune page'
               f'<span>{len(orphelines)}</span></h2>')
    out += [bloc(i) for i in orphelines]

SORTIE.write_text("\n".join(out), encoding="utf-8")
print(f"{total} images sur {len(pages)} pages, dont {ionos} de la banque IONOS")
print(f"{len(orphelines)} image(s) non référencée(s)")
print(f"-> {SORTIE}")
