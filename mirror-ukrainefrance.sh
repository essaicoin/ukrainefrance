#!/usr/bin/env bash
#
# Capture complète de https://www.ukrainefrance.org/ (IONOS MyWebsite)
# et reconstruction d'une version statique autonome, prête pour
# Cloudflare Pages / Netlify / GitHub Pages.
#
# Produit :
#   ./site-mirror/       arborescence statique déployable
#   ./rapport/urls.txt   liste des pages découvertes
#   ./rapport/liens.csv  inventaire complet des liens (internes + externes)
#   ./rapport/medias.csv inventaire des images + statut de licence présumé
#   ./rapport/RAPPORT.md synthèse
#
# Usage :  bash mirror-ukrainefrance.sh
#          bash mirror-ukrainefrance.sh --prerender   (si images en lazy-load)
#
set -euo pipefail

DOMAIN="www.ukrainefrance.org"
BASE="https://${DOMAIN}"
OUT="site-mirror"
REPORT="rapport"
PRERENDER=0
[[ "${1:-}" == "--prerender" ]] && PRERENDER=1

# ---------------------------------------------------------------------------
# 0. Dépendances
# ---------------------------------------------------------------------------
for bin in wget curl python3; do
  command -v "$bin" >/dev/null || { echo "Manque : $bin"; exit 1; }
done
pipi() { pip3 install --quiet "$@" 2>/dev/null || pip3 install --quiet --break-system-packages "$@"; }
python3 -c "import bs4, lxml" 2>/dev/null || pipi beautifulsoup4 lxml

mkdir -p "$REPORT"

# ---------------------------------------------------------------------------
# 1. Découverte des URL (sitemap d'abord, sinon on laisse wget explorer)
# ---------------------------------------------------------------------------
echo "==> Découverte des URL"
: > "$REPORT/urls.txt"

for candidate in sitemap.xml sitemap_index.xml sitemap-index.xml; do
  if curl -sfL "${BASE}/${candidate}" -o "$REPORT/_sitemap.xml"; then
    python3 - "$REPORT/_sitemap.xml" >> "$REPORT/urls.txt" <<'EOF'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for loc in re.findall(r"<loc>\s*(.*?)\s*</loc>", xml):
    print(loc.strip())
EOF
    echo "    sitemap trouvé : ${candidate}"
    break
  fi
done

# robots.txt peut référencer d'autres sitemaps
curl -sfL "${BASE}/robots.txt" -o "$REPORT/robots.txt" || true

sort -u "$REPORT/urls.txt" -o "$REPORT/urls.txt"
echo "    $(wc -l < "$REPORT/urls.txt") URL depuis le sitemap"

# ---------------------------------------------------------------------------
# 2. Miroir
# ---------------------------------------------------------------------------
echo "==> Aspiration (comptez plusieurs minutes)"

WGET_ARGS=(
  --mirror
  --convert-links
  --adjust-extension
  --page-requisites
  --no-parent
  --restrict-file-names=windows
  --domains="${DOMAIN},ukrainefrance.org"
  --user-agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
  --wait=0.5 --random-wait
  --tries=3 --timeout=30
  --reject-regex="(_x_tr_|\?ref=|/-_-/api/)"
  -e robots=off
  --no-verbose
  --directory-prefix="$OUT"
  --no-host-directories
)

if [[ -s "$REPORT/urls.txt" ]]; then
  wget "${WGET_ARGS[@]}" --input-file="$REPORT/urls.txt" 2>&1 | tail -5
else
  wget "${WGET_ARGS[@]}" "$BASE/" 2>&1 | tail -5
fi

# Deuxième passe : rattrape les pages liées mais absentes du sitemap
wget "${WGET_ARGS[@]}" --no-clobber "$BASE/" 2>&1 | tail -3 || true

# ---------------------------------------------------------------------------
# 3. Pré-rendu optionnel (uniquement si des images restent en data-src)
# ---------------------------------------------------------------------------
if [[ $PRERENDER -eq 1 ]]; then
  echo "==> Pré-rendu headless"
  pipi playwright && python3 -m playwright install chromium
  python3 - "$REPORT/urls.txt" "$OUT" <<'EOF'
import sys, pathlib
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright

urls = [l.strip() for l in open(sys.argv[1]) if l.strip()]
out = pathlib.Path(sys.argv[2])
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1400, "height": 2000})
    for u in urls:
        try:
            pg.goto(u, wait_until="networkidle", timeout=45000)
            pg.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            pg.wait_for_timeout(1200)
            path = urlparse(u).path.strip("/") or "index"
            dest = out / f"{path}.rendered.html"
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(pg.content(), encoding="utf-8")
        except Exception as e:
            print("  échec", u, e)
    b.close()
EOF
fi

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
echo "==> Contrôle des liens externes (échantillon)"
python3 - "$REPORT/liens.csv" <<'EOF' || true
import csv, sys, urllib.request, ssl
ctx = ssl.create_default_context(); ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
vus, morts = set(), []
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8-sig"), delimiter=";"))
for r in rows:
    u = r["url"]
    if r["type"] != "externe" or u in vus:
        continue
    vus.add(u)
    try:
        req = urllib.request.Request(u, method="HEAD",
              headers={"User-Agent": "Mozilla/5.0"})
        urllib.request.urlopen(req, timeout=8, context=ctx)
    except Exception as e:
        morts.append((u, str(e)[:60]))
print(f"    {len(vus)} liens externes testés, {len(morts)} en échec")
for u, e in morts[:30]:
    print("     ✗", u, "—", e)
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
