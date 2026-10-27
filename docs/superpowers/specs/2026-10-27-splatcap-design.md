# Splatcap: app iOS di cattura LiDAR per Gaussian Splatting

Nome di lavoro "Splatcap" (scelta mia, modificabile).

## Intento

Angelo usa oggi Splatking (iOS) per catturare scene e Spirula Studio (PC) per addestrare lo splat. Splatking gli sembra "castrato": qualità bassa, il LiDAR cede già a 2 m, e il risultato in Spirula viene storto e povero di dettaglio. Vuole una app sua che catturi dati di qualità massima e li esporti, senza addestrare nulla sul telefono.

Evidenza dalla capture di prova `C:\Users\angel\Downloads\LidarSeries_20260715_101053_141` (Splatking 1.4.0):
- 235 foto JPEG a 1920x1440 (circa 2,8 MP), circa una al secondo, orientamento EXIF 6 (ruotate).
- Profondità grezza 256x192 float32 + confidenza 256x192 uint8 per fotogramma: questo è il limite fisico del sensore LiDAR dell'iPhone, non migliorabile via software.
- Esporta COLMAP testo (`sparse/0/cameras.txt`, `images.txt`, `points3D.txt` da 26 MB di punti LiDAR) più JSON per fotogramma con trasformata ARKit e intrinseci.
- Caricata in Spirula: viene storta e di bassa qualità. Cause ipotizzate (non verificate): conflitto tra orientamento EXIF e geometria del modello COLMAP; risoluzione e numero di foto bassi.

Il margine di miglioramento reale sta in: risoluzione delle foto, qualità e coerenza delle pose, selezione dei fotogrammi, uso corretto della confidenza della profondità, formato di export che Spirula legge senza ambiguità.

## Obiettivi

1. Cattura su iPhone 17 Pro con ARKit + LiDAR, usando il sensore al massimo (profondità `sceneDepth` e confidenza a piena risoluzione sensore).
2. Foto alla massima risoluzione che ARKit consente (via `captureHighResolutionFrame`, circa 12 MP; da verificare sul dispositivo se 17 Pro offre di più), con esposizione, fuoco e bilanciamento del bianco bloccati durante la cattura.
3. Vista in tempo reale: camera a tutto schermo con punti LiDAR sovrapposti, colorati con i colori della camera (scelta A di Angelo). Barra in alto con numero di foto, percentuale di punti affidabili, fps. Pulsante rosso avvia/ferma.
4. Pausa + "termocamera": in pausa la cattura si ferma e la scena si colora per qualità del dettaglio: rosso basso, giallo medio, blu buono (blu al posto del verde per richiesta di Angelo). Le zone mai viste restano senza colore. Si riprende dal punto in cui ci si era fermati. Calcolo sul telefono in tempo reale.
5. Selezione automatica dei fotogrammi: scartare quelli mossi o sfocati e quelli quasi identici al precedente.
6. Export per Spirula: sessione = cartella autosufficiente.
7. Sessioni salvate sul telefono; trasferimento via cavo USB-C o scrittura diretta su disco/SD esterno dall'app File di iOS.

## Non-obiettivi

- Nessun training di splat sul telefono, nessuna ricostruzione mesh.
- Nessuna elaborazione cloud, nessun account, nessuna pubblicazione sull'App Store.
- Nessun supporto ad altri iPhone senza LiDAR o a Android.
- Nessuna vista di copertura separata (solo la termocamera in pausa).

## Anti-obiettivi (sarebbe un fallimento anche se funziona)

- Risultato in Spirula storto o con orientamento ambiguo come ora con Splatking.
- Una app che dichiara "qualità massima" ma salva foto a 2,8 MP.
- Cattura che scatta a raffica ma produce centinaia di fotogrammi sfocati o ridondanti.

## Vincoli

- Sviluppo da Windows. Nessun Mac. Il codice Swift si scrive qui e si compila con GitHub Actions su runner macOS, senza firma. L'IPA si firma e si installa con Sideloadly o AltStore da Windows, con Apple ID gratuito (certificati da 7 giorni, massimo 3 app, Modalità sviluppatore attiva sull'iPhone). Nessuna spesa. Con repo pubblico i minuti di build sono gratuiti; con repo privato la quota macOS è limitata. Il debug è più lento che con Xcode locale.
- Nessun entitlement a pagamento: ARKit, camera, File sharing (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`) funzionano con provisioning gratuito.
- Nessun test su portatili o dispositivi di terzi: l'unico dispositivo di prova è l'iPhone 17 Pro di Angelo.
- Le scelte tecniche che dipendono dall'hardware (risoluzione foto massima, formato di cattura) vanno decise a runtime interrogando il dispositivo, non fissate.

## Export (parte decisa da Angelo + scelte mie)

Decisione di Angelo: i dati restano sul telefono e li trasferisce poi al PC con cavo o disco esterno. Spirula Studio è il consumatore.

Cosa legge Spirula (da `docs/datasets.md` del repo harry7557558/spirula-studio): auto-rileva Nerfstudio (`transforms.json` + PLY opzionale), poi COLMAP, poi Metashape. Cartelle `images/`, `masks/`, `depths/`, `normals/`. Seed PLY con `x y z red green blue`. Profondità letta da `depths/` ma la supervisione è spenta di default. Controlla che la dimensione delle foto corrisponda a quella del modello. `--exif-orientation` deve essere uguale in `spirula sfm` e `spirula train`.

Scelte mie (modificabili):
- Formato principale Nerfstudio `transforms.json`, perché è provato per primo e non ambiguo; con `camera_distortion` esplicito.
- Ogni cartella contiene `images/` con JPEG già ruotati nel verso corretto, senza orientamento EXIF che cambi la geometria (EXIF rimosso o neutro), così non c'è dipendenza da `--exif-orientation`.
- PLY di seme `seed.ply` con punti LiDAR filtrati per confidenza e colorati dalle foto.
- `depths/` con la profondità per fotogramma, più confidenza in file affiancato.
- Come extra, lo stesso modello in COLMAP testo (`sparse/0`), stesso layout di Splatking, per usarlo con altri trainer.
- Convenzione di sistema di riferimento dichiarata nel file e verificata in prova: gravità +Y su, mano destra, poi conversione ARKit→formato di export. L'errore di orientamento ("storto") è il rischio principale.

## Decisioni dopo la verifica del design

Risposte di Angelo:
- Risoluzione contro numero di foto: vuole un bilancio adeguato, non ha una preferenza netta. Ha osservato che le foto si possono sincronizzare con il LiDAR, e che il video tiene il LiDAR sempre attivo.
- Scene: interni, esterni e piccoli oggetti, un po' di tutto. Nessuna scala tipica.
- Repository pubblico: va bene.

Mie scelte (da confermare nella lettura del documento):
- Due modalità di cattura, selezionabili nell'app. Predefinita "Continua": flusso video ARKit al formato più alto disponibile (probabilmente 4K), con profondità e confidenza associate a ogni fotogramma e quindi sincronizzate per costruzione. Seconda "Dettaglio": foto fisse con `captureHighResolutionFrame` (circa 12 MP) a ritmo più lento, per oggetti piccoli e dettagli. Il builder misura frequenza reale e perdite di tracking sul dispositivo e può cambiare la modalità predefinita se i numeri lo impongono.
- Nella modalità "Dettaglio" la profondità associata è quella del fotogramma ARKit più vicino nel tempo; il timestamp di entrambi va salvato.
- Griglia della termocamera adattiva (voxel sparsi), senza ipotesi sulla dimensione della scena. Deve funzionare da un oggetto da 30 cm a una facciata.
- Durante la pausa la sessione ARKit resta attiva, per non perdere l'origine del mondo.
- Spirula usa le pose ARKit come sono (nessun `spirula sfm`). Se Angelo usa invece l'SfM di Spirula, il formato di export non cambia ma cambia la diagnosi del "storto".
- Il repository GitHub è pubblico e contiene solo codice: nessuna cattura, nessun dato, `.superpowers/` in `.gitignore`.
- Il primo passo del piano è un convertitore Python da PC: prende la capture Splatking di riferimento, la riscrive nel formato Nerfstudio descritto sopra (foto già ruotate, PLY di seme) e Angelo la carica in Spirula. Serve a trovare la causa del "storto" prima di scrivere Swift.

## Lasciato al builder

- Come calcolare esattamente il punteggio di dettaglio per zona della termocamera: ipotesi di partenza è numero di viste nitide, diversità degli angoli, distanza di ripresa (più vicino = più pixel per mm), affidabilità LiDAR. Pesi e griglia (voxel o proiezione per fotogramma) a scelta del builder, purché reggano il tempo reale.
- Soglie di nitidezza e di somiglianza per la selezione dei fotogrammi.
- Struttura del codice Swift, scelta tra SceneKit, RealityKit o Metal per i punti, workflow GitHub Actions, nome del bundle.
- Formato interno di salvataggio durante la cattura.

## Verifica richiesta prima di considerare finito

- Una sessione catturata con l'app, caricata in Spirula, parte dritta (non storta) e con foto a risoluzione più alta di 1920x1440.
- Confronto visivo con la capture Splatking di riferimento sulla stessa scena.
- Da fare sul telefono reale di Angelo: non verificabile da questo PC.

## Rischi noti

- Foto ad alta risoluzione tramite ARKit hanno frequenza limitata e mettono in pausa il flusso video per un istante: va misurato.
- 7 giorni di certificato gratuito: reinstallazione settimanale.
- Il LiDAR resta 256x192: il guadagno sul LiDAR è nell'uso della confidenza, non nella risoluzione.
