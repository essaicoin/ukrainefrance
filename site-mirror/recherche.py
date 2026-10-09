#!/usr/bin/env python3
"""
Moteur de recherche par mots-cles pour ukrainefrance.org

Tout se passe dans le navigateur du lecteur : le script extrait le texte
de chaque page dans un fichier JSON, et la page de recherche le filtre en
local. Aucun serveur, aucune base de donnees, aucun appel reseau pendant
la recherche. Compatible avec un hebergement statique (Cloudflare Pages).

Caracteristiques :
  - cherche en ukrainien, russe et francais, accents et casse ignores
  - recherche par fragment : « житл » trouve « житлові » (utile pour une
    langue a declinaisons)
  - plusieurs mots = toutes les pages contenant TOUS les mots
  - extrait de contexte avec le mot surligne
  - les pages dont le titre contient le mot remontent en premier

Usage :
    python3 recherche.py              construit l'index et la page de recherche
    python3 recherche.py --lien       ajoute en plus un bouton de recherche
                                      flottant sur toutes les pages du site
    python3 recherche.py --retirer    retire ce bouton de toutes les pages

Sortie :
    site-mirror/poshuk.html             la page de recherche
    site-mirror/recherche-index.json    l'index
"""
import json, pathlib, re, sys, unicodedata
from bs4 import BeautifulSoup

ROOT = pathlib.Path("site-mirror")
MAX_TEXTE = 12000
EXCLURE = {"poshuk.html"}

# Blocs d'habillage repetes sur les 142 pages : ils ne doivent jamais servir
# de titre de resultat, ni polluer les extraits. « Маєте кориснішу
# інформацію? » est un <h1> place hors <footer> par MyWebsite, donc le
# retrait des balises <footer> ne suffit pas a l'ecarter.
HABILLAGE = [
    "Маєте кориснішу інформацію",
    "Зв'яжіться з нами",
    "Зв\u2019яжіться з нами",
    "Напишіть нам",
]


def est_habillage(t: str) -> bool:
    t = t.strip().lower()
    return any(b.lower() in t for b in HABILLAGE)
MARQUE_DEBUT = "<!-- bouton-recherche -->"
MARQUE_FIN = "<!-- /bouton-recherche -->"

if not ROOT.is_dir():
    sys.exit("Dossier site-mirror introuvable. Lancez le script depuis /workspaces/ukrainefrance")

MODE = sys.argv[1] if len(sys.argv) > 1 else ""


# ---------------------------------------------------------------------------
# Bouton flottant injecte dans les pages (--lien / --retirer)
# ---------------------------------------------------------------------------
BOUTON = MARQUE_DEBUT + """
<a href="/poshuk.html" aria-label="Пошук по сайту" style="position:fixed;right:18px;
bottom:18px;z-index:9999;display:flex;align-items:center;gap:8px;background:#005c99;
color:#fff;text-decoration:none;font:600 15px/1 Roboto,system-ui,sans-serif;
padding:13px 18px;border-radius:30px;box-shadow:0 3px 12px rgba(0,0,0,.3)">
<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#fff"
stroke-width="2.6" stroke-linecap="round"><circle cx="11" cy="11" r="7"/>
<path d="M20 20l-4.3-4.3"/></svg>Пошук</a>
""" + MARQUE_FIN


def pages_html():
    """Toutes les pages du site, y compris en sous-dossier."""
    for f in sorted(ROOT.rglob("*.html")):
        if f.name in EXCLURE or f.name.startswith("_"):
            continue
        yield f


if MODE in ("--lien", "--retirer"):
    n = 0
    for f in pages_html():
        t = f.read_text(encoding="utf-8", errors="replace")
        avant = t
        # on retire toujours l'ancien bouton avant d'en remettre un
        t = re.sub(re.escape(MARQUE_DEBUT) + r".*?" + re.escape(MARQUE_FIN),
                   "", t, flags=re.S)
        if MODE == "--lien":
            if "</body>" in t:
                t = t.replace("</body>", BOUTON + "\n</body>", 1)
            else:
                t += BOUTON
        if t != avant:
            f.write_text(t, encoding="utf-8")
            n += 1
    print(f"{n} page(s) modifiee(s) — bouton "
          f"{'ajoute' if MODE == '--lien' else 'retire'}")
    sys.exit(0)


# ---------------------------------------------------------------------------
# Construction de l'index
# ---------------------------------------------------------------------------
docs = []
for f in pages_html():
    soup = BeautifulSoup(f.read_text(encoding="utf-8", errors="replace"), "lxml")
    for tag in soup(["script", "style", "noscript", "nav", "header", "footer"]):
        tag.decompose()

    titre = ""
    for h in soup.find_all(["h1", "h2", "h3"]):
        t = h.get_text(" ", strip=True)
        if t and not est_habillage(t):
            titre = t
            break
    if not titre and soup.title:
        titre = soup.title.get_text(strip=True)
    titre = re.sub(r"\s+", " ", titre)[:110] or f.stem

    main = soup.find("main") or soup.body or soup
    texte = re.sub(r"\s+", " ", main.get_text(" ", strip=True))
    for b in HABILLAGE:
        texte = texte.replace(b, " ")
    texte = re.sub(r"\s+", " ", texte).strip()[:MAX_TEXTE]
    if len(texte) < 40:
        continue

    # u = chemin depuis la racine du site, sans .html (sous-dossiers compris)
    # t = titre, x = texte.
    # La version normalisee est calculee une seule fois par le navigateur
    # au chargement : cela divise par deux le poids du fichier a telecharger.
    url = f.relative_to(ROOT).as_posix()[:-5]
    docs.append({"u": url, "t": titre, "x": texte})

index = ROOT / "recherche-index.json"
index.write_text(json.dumps(docs, ensure_ascii=False, separators=(",", ":")),
                 encoding="utf-8")


# ---------------------------------------------------------------------------
# Page de recherche
# ---------------------------------------------------------------------------
PAGE = r"""<!doctype html>
<html lang="uk">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Пошук по сайту — Україна Франція</title>
<meta name="robots" content="noindex">
<style>
  :root{--bleu:#005c99;--fonce:#02426b;--fond:#e9e5e6;--texte:#383838}
  *{box-sizing:border-box}
  body{margin:0;background:var(--fond);color:var(--texte);
       font-family:Roboto,system-ui,-apple-system,sans-serif;font-size:16px;line-height:1.55}
  header{background:var(--bleu);color:#fff;padding:14px 16px;display:flex;
         align-items:center;gap:14px;flex-wrap:wrap}
  header a{color:#fff;text-decoration:none;font-weight:600;white-space:nowrap}
  header a:hover{text-decoration:underline}
  header .titre{font-family:Raleway,Roboto,sans-serif;font-size:19px;
                font-weight:700;margin-right:auto}
  main{max-width:880px;margin:0 auto;padding:16px 16px 70px}
  .boite{position:sticky;top:0;background:var(--fond);padding:14px 0 10px;z-index:5}
  input{width:100%;padding:14px 16px;font-size:18px;border:2px solid var(--bleu);
        border-radius:8px;background:#fff;color:var(--texte);-webkit-appearance:none}
  input:focus{outline:3px solid rgba(0,92,153,.32);outline-offset:1px}
  .etat{margin:8px 2px 16px;color:#5b6572;font-size:14px;min-height:20px}
  .sugg{margin:2px 0 18px;display:flex;flex-wrap:wrap;gap:8px}
  .sugg button{background:#fff;border:1px solid #c6cdd4;color:var(--bleu);
       font:500 14px Roboto,system-ui,sans-serif;padding:7px 13px;border-radius:16px;
       cursor:pointer}
  .sugg button:hover{background:var(--bleu);color:#fff;border-color:var(--bleu)}
  .res{display:block;background:#fff;border-radius:8px;padding:14px 16px;
       margin-bottom:11px;text-decoration:none;color:inherit;
       box-shadow:0 1px 3px rgba(0,0,0,.13)}
  .res:hover,.res:focus{box-shadow:0 2px 11px rgba(0,0,0,.24);outline:none}
  .res h2{font-family:Raleway,Roboto,sans-serif;font-size:17px;color:var(--bleu);
          margin:0 0 6px;line-height:1.35}
  .res p{margin:0;font-size:15px;color:#4a545f}
  mark{background:#ffdf7e;color:inherit;padding:0 2px;border-radius:2px}
  .vide{background:#fff;border-radius:8px;padding:22px 18px;color:#5b6572}
  .vide b{color:var(--texte)}
  footer{background:var(--fonce);color:#d7dde2;text-align:center;
         padding:18px 16px;font-size:14px}
  footer a{color:#fff}
</style>

<header>
  <span class="titre">Пошук по сайту</span>
  <a href="/index.html">← На головну</a>
</header>

<main>
  <div class="boite">
    <input id="q" type="search" autocomplete="off" autofocus enterkeyhint="search"
           placeholder="Введіть слово: житло, лікар, APS, префектура…"
           aria-label="Пошук по сайту">
  </div>
  <div class="etat" id="etat" role="status" aria-live="polite"></div>
  <div class="sugg" id="sugg"></div>
  <div id="res"></div>
</main>

<footer>Україна — Франція · <a href="/index.html">ukrainefrance.org</a></footer>

<script>
var DOCS = [], PRET = false;
var q = document.getElementById('q'),
    res = document.getElementById('res'),
    etat = document.getElementById('etat'),
    sugg = document.getElementById('sugg');

function norm(t){
  return t.toLowerCase().normalize('NFKD')
          .replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ');
}
function echappe(t){
  return t.replace(/[&<>"]/g, function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];
  });
}

etat.textContent = 'Завантаження…';
fetch('/recherche-index.json?v=__VERSION__')
  .then(function(r){ if(!r.ok) throw 0; return r.json(); })
  .then(function(d){
    DOCS = d;
    for (var i = 0; i < DOCS.length; i++){
      DOCS[i].n = norm(DOCS[i].t + ' ' + DOCS[i].x);
    }
    PRET = true;
    repos();
    if (q.value) lancer();
  })
  .catch(function(){
    etat.textContent = 'Не вдалося завантажити пошуковий індекс. Оновіть сторінку.';
  });

var MOTS_SUGG = ['житло','APS','префектура','лікар','робота','школа',
                 'податки','CAF','банк','транспорт'];
function repos(){
  etat.textContent = 'Доступно сторінок для пошуку: ' + DOCS.length;
  sugg.innerHTML = MOTS_SUGG.map(function(m){
    return '<button type="button">' + m + '</button>';
  }).join('');
  res.innerHTML = '';
}
sugg.addEventListener('click', function(e){
  if (e.target.tagName === 'BUTTON'){
    q.value = e.target.textContent;
    q.focus();
    lancer();
  }
});

function extrait(doc, mots){
  var n = norm(doc.x), pos = -1;
  for (var i = 0; i < mots.length; i++){
    var p = n.indexOf(mots[i]);
    if (p >= 0 && (pos < 0 || p < pos)) pos = p;
  }
  var debut, fin;
  if (pos < 0){ debut = 0; fin = Math.min(doc.x.length, 190); }
  else { debut = Math.max(0, pos - 75); fin = Math.min(doc.x.length, pos + 200); }
  var bout = echappe(doc.x.slice(debut, fin));
  mots.forEach(function(m){
    var re = new RegExp('(' + m.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi');
    bout = bout.replace(re, '<mark>$1</mark>');
  });
  return (debut > 0 ? '…' : '') + bout + (fin < doc.x.length ? '…' : '');
}

function lancer(){
  if (!PRET) return;
  var brut = q.value.trim();
  if (brut.length < 2){ repos(); return; }
  sugg.innerHTML = '';

  var mots = norm(brut).split(' ').filter(function(m){ return m.length > 1; });
  if (!mots.length){ repos(); return; }

  var sortie = [];
  for (var i = 0; i < DOCS.length; i++){
    var d = DOCS[i], score = 0, tous = true;
    for (var j = 0; j < mots.length; j++){
      var occ = d.n.split(mots[j]).length - 1;
      if (!occ){ tous = false; break; }
      score += occ;
      if (norm(d.t).indexOf(mots[j]) >= 0) score += 30;
    }
    if (tous) sortie.push({ d: d, s: score });
  }
  sortie.sort(function(a, b){ return b.s - a.s; });

  if (!sortie.length){
    etat.textContent = '';
    res.innerHTML = '<div class="vide">Нічого не знайдено за запитом <b>' +
      echappe(brut) + '</b>.<br><br>Спробуйте коротшу форму слова ' +
      '(наприклад <b>житл</b> замість <b>житлові</b>) або інше слово.</div>';
    return;
  }
  etat.textContent = 'Знайдено сторінок: ' + sortie.length;
  res.innerHTML = sortie.slice(0, 60).map(function(r){
    return '<a class="res" href="/' + r.d.u + '.html">' +
           '<h2>' + echappe(r.d.t) + '</h2>' +
           '<p>' + extrait(r.d, mots) + '</p></a>';
  }).join('');
}

var minuteur;
q.addEventListener('input', function(){
  clearTimeout(minuteur);
  minuteur = setTimeout(lancer, 130);
});
q.addEventListener('keydown', function(e){
  if (e.key === 'Enter'){ e.preventDefault(); clearTimeout(minuteur); lancer(); }
});

// permet d'arriver directement avec /poshuk.html?q=mot
var p = new URLSearchParams(location.search).get('q');
if (p) q.value = p;
</script>
</html>
"""

# Empreinte du contenu : elle change des qu'une page change, donc l'URL de
# l'index change aussi et le navigateur du lecteur retelecharge au lieu de
# servir une version perimee depuis son cache.
import hashlib
version = hashlib.sha1(index.read_bytes()).hexdigest()[:10]
(ROOT / "poshuk.html").write_text(PAGE.replace("__VERSION__", version),
                                  encoding="utf-8")

ko = index.stat().st_size / 1024
print(f"{len(docs)} pages indexees")
print(f"index : {ko:.0f} Ko brut (environ {ko*0.28:.0f} Ko compresse a la livraison)")
print(f"page  : {ROOT / 'poshuk.html'}  ->  /poshuk.html")
print(f"version de l'index : {version}")
print()
print("Pour ajouter un bouton de recherche sur toutes les pages :")
print("    python3 recherche.py --lien")
