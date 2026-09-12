#!/usr/bin/env bash
#
# Reprise apres l'aspiration : nettoyage, inventaire, finalisation.
# A lancer dans le meme dossier que site-mirror/ et rapport/.
#
set -uo pipefail   # volontairement sans -e : un lien mort ne doit pas tout arreter

DOMAIN="www.ukrainefrance.org"
BASE="https://${DOMAIN}"
OUT="site-mirror"
REPORT="rapport"

[[ -d "$OUT" ]] || { echo "Dossier $OUT introuvable. Lancez le script depuis /workspaces/ukrainefrance"; exit 1; }
pipi() { pip3 install --quiet "$@" 2>/dev/null || pip3 install --quiet --break-system-packages "$@"; }
python3 -c "import bs4, lxml" 2>/dev/null || pipi beautifulsoup4 lxml
mkdir -p "$REPORT"

echo "==> Reprise sur $(find "$OUT" -name '*.html' | wc -l) pages deja aspirees"

# ---------------------------------------------------------------------------
# 4. Nettoyage : suppression du bagage IONOS, inventaire des liens
# ---------------------------------------------------------------------------
echo "==> Nettoyage et inventaire"
python3 - "$OUT" "$DOMAIN" "$REPORT" <<'EOF'
import csv, pathlib, re, sys
from urllib.parse import urljoin, urlparse
from bs4 import BeautifulSoup

root, domain, report = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
INTERNAL = {domain, domain.removeprefix("www.")}

# Signatures du bagage MyWebsite à retirer
KILL_SCRIPT = re.compile(
    r"(ionos|1and1|websitetranslator|siteanalytics|cookie|consent|privacy-?settings"
    r"|gtag|googletagmanager|matomo|piwik)", re.I)
KILL_BLOCK = re.compile(
    r"(cookie|consent|privacy-settings|website-?translator|cc-banner)", re.I)

liens, medias, pages = [], [], 0

for f in sorted(root.rglob("*.html")):
    if f.name.endswith(".rendered.html"):
        continue
    pages += 1
    html = f.read_text(encoding="utf-8", errors="replace")
    soup = BeautifulSoup(html, "lxml")
    rel = f.relative_to(root).as_posix()

    # -- scripts et trackers
    for tag in soup.find_all("script"):
        blob = (tag.get("src") or "") + (tag.string or "")
        if KILL_SCRIPT.search(blob):
            tag.decompose()
    for tag in soup.find_all("noscript"):
        tag.decompose()

    # -- bandeaux cookies / traducteur
    for tag in soup.find_all(True):
        ident = " ".join(filter(None, [
            tag.get("id", ""), " ".join(tag.get("class", [])), tag.get("data-testid", "")]))
        if ident and KILL_BLOCK.search(ident):
            tag.decompose()

    # -- lazy-load : data-src -> src
    for img in soup.find_all("img"):
        for a, b in (("data-src", "src"), ("data-srcset", "srcset")):
            val = img.get(a)
            if val:
                img[b] = val
                del img[a]
        img.attrs.setdefault("loading", "lazy")
        src = img.get("src", "")
        if src:
            medias.append({
                "page": rel, "src": src, "alt": img.get("alt", ""),
                # /images/assets/ = banque d'images IONOS (licence NON transférable)
                # /images/files/  = vos propres téléversements
                "origine": "banque IONOS" if "/images/assets/" in src else "téléversement",
            })

    # -- inventaire + normalisation des liens
    for a in soup.find_all("a", href=True):
        href = a["href"].strip()
        texte = a.get_text(" ", strip=True)[:120]
        p = urlparse(href)
        if p.scheme in ("mailto", "tel"):
            kind = p.scheme
        elif not p.netloc:
            kind = "interne"
        elif p.netloc in INTERNAL:
            kind = "interne"
            # absolu -> relatif
            a["href"] = (p.path or "/") + (f"?{p.query}" if p.query else "") \
                        + (f"#{p.fragment}" if p.fragment else "")
        else:
            kind = "externe"
            a["rel"] = "noopener noreferrer"
            a["target"] = "_blank"
        liens.append({"page": rel, "type": kind, "url": href,
                      "domaine": p.netloc, "ancre": texte})

    f.write_text(str(soup), encoding="utf-8")

report.mkdir(exist_ok=True)
def dump(name, rows, cols):
    with open(report / name, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, delimiter=";")
        w.writeheader(); w.writerows(rows)

dump("liens.csv", liens, ["page", "type", "url", "domaine", "ancre"])
dump("medias.csv", medias, ["page", "src", "alt", "origine"])

ext = {}
for l in liens:
    if l["type"] == "externe":
        ext[l["domaine"]] = ext.get(l["domaine"], 0) + 1
ionos_imgs = sum(1 for m in medias if m["origine"] == "banque IONOS")

(report / "RAPPORT.md").write_text(f"""# Rapport de capture — {domain}

- Pages HTML capturées : **{pages}**
- Liens totaux : **{len(liens)}** ({sum(1 for l in liens if l['type']=='interne')} internes,
  {sum(1 for l in liens if l['type']=='externe')} externes,
  {sum(1 for l in liens if l['type']=='mailto')} mailto)
- Images : **{len(medias)}**, dont **{ionos_imgs}** issues de la banque IONOS
  → licence non transférable, à remplacer avant mise en ligne ailleurs.

## Domaines externes les plus liés
{chr(10).join(f"- `{d}` — {n}" for d, n in sorted(ext.items(), key=lambda x: -x[1])[:25])}

## À faire manuellement
- [ ] Remplacer les {ionos_imgs} visuels de la banque IONOS
- [ ] Reconstruire le formulaire de contact (Formspree / Web3Forms / Pages Function)
- [ ] Remplacer le traducteur IONOS par un lien translate.goog
- [ ] Vérifier les liens Telegram/Google Docs (voir liens.csv, colonne domaine)
""", encoding="utf-8")
print(f"    {pages} pages, {len(liens)} liens, {len(medias)} images")
EOF

# ---------------------------------------------------------------------------
# 5. Vérification des liens morts (optionnel mais recommandé)
# ---------------------------------------------------------------------------
echo "==> Controle des liens externes (en parallele, quelques minutes)"
python3 - "$REPORT/liens.csv" "$REPORT/liens-morts.csv" <<'EOF' || true
import csv, sys, ssl, urllib.request, concurrent.futures
ctx = ssl.create_default_context(); ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8-sig"), delimiter=";"))
urls = sorted({r["url"] for r in rows if r["type"] == "externe"})
print(f"    {len(urls)} liens externes uniques a tester")

def test(u):
    try:
        req = urllib.request.Request(u, method="HEAD",
              headers={"User-Agent": "Mozilla/5.0"})
        urllib.request.urlopen(req, timeout=5, context=ctx)
        return None
    except Exception as e:
        return (u, type(e).__name__ + ": " + str(e)[:70])

morts = []
with concurrent.futures.ThreadPoolExecutor(max_workers=25) as ex:
    for i, res in enumerate(ex.map(test, urls), 1):
        if res: morts.append(res)
        if i % 100 == 0: print(f"    {i}/{len(urls)}...", flush=True)

pages = {}
for r in rows:
    pages.setdefault(r["url"], []).append(r["page"])

with open(sys.argv[2], "w", newline="", encoding="utf-8-sig") as fh:
    w = csv.writer(fh, delimiter=";")
    w.writerow(["url", "erreur", "pages concernees"])
    for u, e in morts:
        w.writerow([u, e, " | ".join(sorted(set(pages.get(u, []))))[:500]])

print(f"    {len(morts)} liens en echec -> rapport/liens-morts.csv")
EOF

# ---------------------------------------------------------------------------
# 6. Finalisation pour le déploiement
# ---------------------------------------------------------------------------
echo "==> Finalisation"

# Sitemap propre
python3 - "$OUT" "$DOMAIN" <<'EOF'
import pathlib, sys
root, domain = pathlib.Path(sys.argv[1]), sys.argv[2]
urls = []
for f in sorted(root.rglob("*.html")):
    if f.name.endswith(".rendered.html"): continue
    p = f.relative_to(root).as_posix().removesuffix(".html")
    urls.append("/" if p == "index" else "/" + p)
body = "".join(f"  <url><loc>https://{domain}{u}</loc></url>\n" for u in urls)
(root / "sitemap.xml").write_text(
  f'<?xml version="1.0" encoding="UTF-8"?>\n'
  f'<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n{body}</urlset>\n',
  encoding="utf-8")
EOF

cat > "$OUT/robots.txt" <<EOF
User-agent: *
Allow: /
Sitemap: ${BASE}/sitemap.xml
EOF

# En-têtes de sécurité (Cloudflare Pages / Netlify)
cat > "$OUT/_headers" <<'EOF'
/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  X-Frame-Options: SAMEORIGIN
  Permissions-Policy: geolocation=(), microphone=(), camera=()
EOF

find "$OUT" -name "*.rendered.html" -delete 2>/dev/null || true

echo
echo "======================================================================"
echo " Terminé."
echo "   Site      : $OUT/          ($(du -sh "$OUT" | cut -f1))"
echo "   Rapports  : $REPORT/RAPPORT.md, liens.csv, medias.csv"
echo
echo " Test local     : npx wrangler pages dev $OUT"
echo "                  (les URL propres type /2 exigent un serveur qui résout"
echo "                   /2 -> 2.html ; python -m http.server ne le fait pas)"
echo " Déploiement    : npx wrangler pages deploy $OUT --project-name=ukrainefrance"
echo "======================================================================"
