# Splatcap

App iOS (iPhone con LiDAR) che cattura dati per il Gaussian splatting ed esporta una cartella Nerfstudio per Spirula Studio. Solo cattura ed esportazione, nessun training sul telefono.

- `Sources/SplatcapCore`: logica testabile (Swift Package).
- `App`: app iOS, progetto generato con XcodeGen.
- `tools`: convertitore Python da capture Splatking.

La CI su GitHub Actions costruisce `Splatcap.ipa` non firmato; si installa con Sideloadly o AltStore.
