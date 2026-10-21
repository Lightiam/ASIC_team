#!/usr/bin/env bash
# Re-generate the fabrication package from lightrail_dual_nce.kicad_pcb.
#
# Exists because the first package was produced by hand-typed kicad-cli calls,
# which is not reproducible and went stale the moment the copper changed.
# Copper pours in particular MUST be re-poured and re-exported together: a
# Gerber set exported before a re-pour ships the old copper.
#
# Settings follow the standard fab expectations: Protel extensions, drill
# origin included, Excellon in 4.6 mm, PTH and NPTH both emitted with maps.
set -euo pipefail

BOARD="${1:-lightrail_dual_nce.kicad_pcb}"
OUT="${2:-fab}"
KC="${KICAD_CLI:-/c/Users/$USER/AppData/Local/Programs/KiCad/10.0/bin/kicad-cli.exe}"

[ -x "$KC" ] || { echo "kicad-cli not found at $KC (set KICAD_CLI)" >&2; exit 1; }
[ -f "$BOARD" ] || { echo "no board at $BOARD" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"

echo "== DRC gate =="
# Errors block the export. Warnings do not: the isolated-copper warnings are
# the expected signature of planes whose net has no pads yet, and gating on
# them would mean never exporting until the schematic exists.
"$KC" pcb drc --severity-error --exit-code-violations -o "$OUT/drc_errors.txt" "$BOARD" \
  || { echo "DRC ERRORS present -- not exporting" >&2; exit 1; }
echo "0 errors"

echo "== copper, mask, silk, outline =="
LAYERS=$(python - "$BOARD" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
names = re.findall(r'^\s*\(\s*\d+\s+"([^"]+)"\s+(?:signal|power|mixed|jumper|user)',
                   src, re.M)
keep = [n for n in names]
keep += ["F.Mask", "B.Mask", "F.SilkS", "B.SilkS", "F.Paste", "B.Paste", "Edge.Cuts"]
seen, out = set(), []
for n in keep:
    if n not in seen:
        seen.add(n); out.append(n)
print(",".join(out))
PY
)
"$KC" pcb export gerbers --layers "$LAYERS" --use-drill-file-origin \
      --check-zones --precision 6 -o "$OUT/" "$BOARD" >/dev/null

echo "== drill =="
"$KC" pcb export drill --format excellon --drill-origin plot \
      --excellon-separate-th --generate-map --map-format gerberx2 \
      --excellon-units mm --generate-report --report-path "$OUT/drill_report.txt" \
      -o "$OUT/" "$BOARD" >/dev/null

echo "== position file =="
"$KC" pcb export pos --format csv --units mm --side both \
      -o "$OUT/cpl.csv" "$BOARD" >/dev/null 2>&1 || echo "  (no footprints -- CPL empty)"

echo
echo "== verify (reads the exported gerbers, not the plot result) =="
python verify_fab.py "$OUT" || { echo "VERIFY FAILED" >&2; exit 1; }

echo "files : $(ls -1 "$OUT" | wc -l)"
echo "copper: $(ls -1 "$OUT" | grep -cE '\.(gtl|gbl|g[0-9]+|gp[0-9]+)$' || true)"
echo "drill : $(ls -1 "$OUT" | grep -cE '\.drl$' || true)"
