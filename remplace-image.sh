#!/usr/bin/env bash
#
# Remplace une vignette MyWebsite par une image de votre choix,
# en regenerant automatiquement TOUTES les variantes de taille
# aux dimensions exactes attendues par le HTML.
#
# Le HTML n'est jamais modifie : les fichiers sont ecrases sur place,
# donc le srcset, la mise en page et les titres incrustes restent intacts.
#
# Usage :
#   bash remplace-image.sh --liste
#         -> affiche toutes les vignettes de la banque IONOS
#            avec leur identifiant court et leur libelle
#
#   bash remplace-image.sh <identifiant> <mon-image.jpg>
#         -> remplace toutes les variantes de cette vignette
#
#   bash remplace-image.sh --restaure <identifiant>
#         -> revient a l'image d'origine (sauvegarde automatique)
#
set -uo pipefail

OUT="site-mirror"
REPORT="rapport"
BACKUP=".images-origine"

[[ -d "$OUT" ]] || { echo "Dossier $OUT introuvable. Lancez le script depuis /workspaces/ukrainefrance"; exit 1; }

pipi() { pip3 install --quiet "$@" 2>/dev/null || pip3 install --quiet --break-system-packages "$@"; }
python3 -c "import PIL" 2>/dev/null || pipi Pillow

# ---------------------------------------------------------------------------
# Mode liste
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--liste" ]]; then
  python3 - "$OUT" "$REPORT" <<'EOF'
import csv, pathlib, re, sys, collections
root, report = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

# libelles depuis medias.csv (alt = titre de la rubrique)
libelle, page_de = {}, {}
f = report / "medias.csv"
if f.exists():
    for r in csv.DictReader(open(f, encoding="utf-8-sig"), delimiter=";"):
        m = re.search(r"/assets/([0-9a-f-]{8,})", r["src"])
        if m:
            libelle.setdefault(m.group(1), r["alt"] or "(sans libelle)")
            page_de.setdefault(m.group(1), r["page"])

# assets reellement presents sur le disque
assets = collections.defaultdict(list)
for d in root.rglob("assets/*/*"):
    if d.is_dir() and re.fullmatch(r"\d+-\d+", d.name):
        assets[d.parent.name].append(d.name)

print(f"\n{len(assets)} vignettes trouvees sur le disque\n")
print(f"{'IDENTIFIANT':<14} {'VARIANTES':<10} {'PAGE':<22} LIBELLE")
print("-" * 92)
for uid, tailles in sorted(assets.items(), key=lambda x: page_de.get(x[0], "zzz")):
    court = uid[:8]
    lab = libelle.get(uid, "")
    if not lab:
        for k, v in libelle.items():
            if k.startswith(court):
                lab = v; break
    pg = page_de.get(uid, "")
    if not pg:
        for k, v in page_de.items():
            if k.startswith(court):
                pg = v; break
    print(f"{court:<14} {len(tailles):<10} {pg[:22]:<22} {lab[:44]}")
print("\nPour remplacer :  bash remplace-image.sh <IDENTIFIANT> mon-image.jpg\n")
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# Mode restauration
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--restaure" ]]; then
  ID="${2:-}"
  [[ -n "$ID" ]] || { echo "Usage : bash remplace-image.sh --restaure <identifiant>"; exit 1; }
  n=0
  while IFS= read -r -d '' f; do
    dest="$OUT/${f#$BACKUP/}"
    mkdir -p "$(dirname "$dest")" && cp "$f" "$dest" && n=$((n+1))
  done < <(find "$BACKUP" -path "*${ID}*" -type f -print0 2>/dev/null)
  echo "$n fichier(s) restaure(s)."
  [[ $n -eq 0 ]] && echo "Aucune sauvegarde trouvee pour cet identifiant."
  exit 0
fi

# ---------------------------------------------------------------------------
# Mode remplacement
# ---------------------------------------------------------------------------
ID="${1:-}"
SRC="${2:-}"
if [[ -z "$ID" || -z "$SRC" ]]; then
  echo "Usage :"
  echo "  bash remplace-image.sh --liste"
  echo "  bash remplace-image.sh <identifiant> <mon-image.jpg>"
  echo "  bash remplace-image.sh --restaure <identifiant>"
  exit 1
fi
[[ -f "$SRC" ]] || { echo "Image introuvable : $SRC"; exit 1; }

python3 - "$OUT" "$BACKUP" "$ID" "$SRC" <<'EOF'
import pathlib, re, shutil, sys
from PIL import Image, ImageOps

root, backup, uid, src = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]

# repertoires de variantes correspondant a l'identifiant (prefixe suffisant)
dossiers = [d for d in root.rglob("assets/*/*")
            if d.is_dir() and re.fullmatch(r"\d+-\d+", d.name) and d.parent.name.startswith(uid)]

if not dossiers:
    print(f"Aucune vignette ne correspond a « {uid} ».")
    print("Verifiez l'identifiant avec : bash remplace-image.sh --liste")
    sys.exit(1)

source = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
print(f"Source : {src}  ({source.width}x{source.height})")
print(f"Vignette {dossiers[0].parent.name[:8]} — {len(dossiers)} variante(s)\n")

faits = 0
for d in sorted(dossiers, key=lambda p: p.name):
    w, h = (int(x) for x in d.name.split("-"))
    for f in d.iterdir():
        if not f.is_file():
            continue

        # format d'origine (les fichiers MyWebsite n'ont pas d'extension)
        try:
            with Image.open(f) as im:
                fmt = im.format or "JPEG"
        except Exception:
            fmt = "JPEG"

        # sauvegarde avant premiere modification
        sauve = backup / f.relative_to(root)
        if not sauve.exists():
            sauve.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, sauve)

        # recadrage centre aux dimensions exactes, sans deformation
        vignette = ImageOps.fit(source, (w, h), method=Image.LANCZOS, centering=(0.5, 0.5))
        if fmt == "PNG":
            vignette.save(f, "PNG", optimize=True)
        else:
            vignette.save(f, "JPEG", quality=86, optimize=True, progressive=True)
        print(f"  {w:>4}x{h:<4}  {fmt:<5}  {f.name[:40]}")
        faits += 1

print(f"\n{faits} fichier(s) remplace(s). Sauvegarde dans {backup}/")
print("Pour annuler :  bash remplace-image.sh --restaure " + uid)
EOF
