# Spirula Studio: formato dataset (da docs/datasets.md, letto il 2026-10-27)

Fonte: https://github.com/harry7557558/spirula-studio/blob/master/docs/datasets.md

Verificato nel documento:
- Auto-rilevamento nell'ordine Nerfstudio, COLMAP, Metashape.
- Sottocartelle predefinite `images/`, `masks/`, `depths/`, `normals/`; maschere, profondità e normali sono cercate "per nome relativo alla cartella immagini".
- Profondità: PNG 16 bit in millimetri, 0 dove non c'è misura (descritto per i dataset da E57). Profondità lungo l'asse ottico per camere pinhole. Perdita "scale-and-shift invariant".
- La supervisione con profondità è spenta di default: va attivata con `--depth-supervision-weight` o con "Use dataset depth maps" nella GUI (preset, oppure 0,05).
- Seed: PLY con `x y z red green blue`, parametro `seed_pointcloud`. Senza punti parte da punti casuali.
- `--exif-orientation` deve avere lo stesso valore in `spirula sfm` e `spirula train`. Le mappe sono scritte "nel frame memorizzato" dell'immagine.

NON verificato (scelta mia, da confermare provando in Spirula):
- Nome esatto del file di profondità: uso `depths/<nome immagine>.png` per analogia con le maschere (`frame.png`).
- Risoluzione: la profondità resta a 256x192 (rapporto 4:3, come la foto). Il documento non dice come Spirula la ridimensiona.

Verificato il 2026-10-28 provando in Spirula: con `seed.ply` il log dice "Seed points drawn at random" (palla di punti). Il nome di default che Spirula cerca è `sparse_pc.ply` (override: `--seed-pointcloud`). Convertitore corretto.
