# PinShift — Prototipo iOS On-Device GPS Location Changer

**PinShift** è un'app iOS (SwiftUI + libreria Rust `idevice`) che permette di cambiare la posizione GPS dell'iPhone **direttamente dal telefono**, senza tenere il cavo USB collegato dopo il setup iniziale e **senza possedere un Mac** (la compilazione dell'`.ipa` avviene gratuitamente nel cloud tramite GitHub Actions).

---

## Funzionalità incluse nel prototipo

- **Mappa interattiva (Apple MapKit):** tocca qualsiasi punto del mondo per posizionare il pin.
- **Ricerca indirizzi e coordinate:** autocomplete di città/indirizzi oppure inserimento diretto `latitudine, longitudine`.
- **Preferiti:** salva i tuoi luoghi preferiti (oltre a 5 città rapide preimpostate) e imposta la posizione con un tocco.
- **Keep-alive automatico:** mantiene attiva la simulazione GPS su iOS 17/18+ tramite tunnel `CoreDevice` / `RSD` + `DVT LocationSimulation` (con fallback automatico per iOS ≤ 16).
- **Ripristino GPS reale:** un pulsante dedicato riporta istantaneamente l'iPhone alla posizione reale.

---

## Architettura del progetto

```text
pinshift-ios/
├── .github/workflows/build-ipa.yml   # Compilazione automatica su macOS cloud -> PinShift-unsigned.ipa
├── rust/locbridge/                   # Bridge Rust (idevice 0.1.68) compilato come libreria statica iOS
│   ├── Cargo.toml
│   ├── include/locbridge.h           # Header C esposto a Swift
│   └── src/lib.rs                    # Tunnel CoreDevice/RSD + DVT LocationSimulation
├── ios/
│   ├── project.yml                   # Specifica XcodeGen (genera PinShift.xcodeproj su CI)
│   └── PinShift/                     # App SwiftUI (Mappa, Preferiti, Configurazione)
└── windows/setup-helper.ps1          # Script PowerShell di controllo driver e link rapidi
```

---

## Guida passo-passo (da Windows, senza Mac)

### Fase 1 — Compila `PinShift-unsigned.ipa` gratis su GitHub

1. Crea un account gratuito su [github.com/signup](https://github.com/signup).
2. Crea una **nuova repository** (es. `pinshift-ios`). Può essere pubblica o privata (le repo pubbliche hanno minuti GitHub Actions illimitati; le private includono 2.000 minuti/mese gratuiti, dove macOS consuma 10×).
3. Carica tutti i file di questa cartella nella repository:
   - **Metodo più semplice:** installa [GitHub Desktop](https://desktop.github.com/), apri questa cartella (`File -> Add local repository`) e clicca **Publish repository**.
   - **Oppure da browser:** clicca *Add file -> Upload files* e trascina le cartelle (assicurati di includere anche la cartella `.github/workflows/build-ipa.yml`!).
4. Vai nella scheda **Actions** della tua repository su GitHub:
   - Vedrai partire automaticamente il workflow **Build Unsigned iOS IPA** (puoi anche avviarlo manualmente con *Run workflow*).
   - Attendi ~5–10 minuti (la prima volta compila Rust + Swift da zero; le build successive sono molto più rapide grazie alla cache).
5. A build completata, clicca sulla run e scarica l'artifact **`PinShift-unsigned-ipa`** in fondo alla pagina, quindi estrai **`PinShift-unsigned.ipa`**.

---

### Fase 2 — Installa l'app sull'iPhone da Windows

1. Esegui `windows\setup-helper.ps1` in PowerShell per verificare i driver Apple USB e aprire i link ufficiali.
2. Assicurati di avere installato **iTunes (versione Desktop da apple.com, non Microsoft Store)** oppure **Apple Devices** così Windows riconosce l'iPhone via USB.
3. Scarica e installa **[Sideloadly](https://sideloadly.io/)** su Windows.
4. Collega l'iPhone al PC con un cavo USB dati, sbloccalo e tocca **Autorizza** (*Trust This Computer*).
5. Apri **Sideloadly**:
   - Trascina `PinShift-unsigned.ipa` dentro Sideloadly.
   - Inserisci il tuo **Apple ID** (anche gratuito, va benissimo crearne uno secondario per test).
   - Premi **Start** e attendi l'installazione sull'iPhone.
6. Sull'iPhone vai in **Impostazioni → Generali → VPN e gestione dispositivi**, seleziona il tuo profilo sviluppatore e tocca **Autorizza**.
7. Attiva la **Modalità sviluppatore** sull'iPhone: **Impostazioni → Privacy e sicurezza → Modalità sviluppatore → Attiva** (l'iPhone si riavvierà).

> **Nota sulla scadenza dei 7 giorni:** con un Apple ID gratuito l'app va ri-firmata ogni 7 giorni (con Sideloadly in 10 secondi oppure installandola tramite [SideStore](https://sidestore.io/) per rinnovarla direttamente in Wi-Fi dal telefono).

---

### Fase 3 — Configurazione una tantum per usarla dal telefono senza PC

1. **Installa LocalDevVPN** (gratuita) dall'App Store sul tuo iPhone.
2. **Genera il Pairing File dal PC Windows (una sola volta):**
   - Scarica `idevice_pair` (Windows `.exe`) da [github.com/jkcoxson/idevice_pair/releases](https://github.com/jkcoxson/idevice_pair/releases).
   - Con l'iPhone collegato via USB e sbloccato, apri `idevice_pair`, seleziona il tuo iPhone e genera/salva il **pairing file standard (Lockdown / `.mobiledevicepairing` o `.plist`)**.
   - Trasferisci quel file sull'iPhone (via iCloud Drive, email a te stesso, oppure direttamente nella cartella **PinShift** tramite *Send to app* / app File).
   - **Non condividere mai il tuo pairing file**: contiene le chiavi crittografiche del tuo dispositivo.

---

### Fase 4 — Cambia la tua posizione GPS direttamente dall'iPhone!

1. Assicurati che il **Wi-Fi** sia acceso sull'iPhone.
2. Apri **LocalDevVPN** e attiva la connessione (IP predefinito `10.7.0.1`).
3. Apri **PinShift**:
   - Vai nella scheda **Configura** → tocca **Importa Pairing File** e seleziona il file generato con `idevice_pair`.
   - Tocca **Testa Connessione** per verificare che il tunnel `CoreDevice / RSD` risponda.
4. Vai nella scheda **Mappa**:
   - Tocca qualsiasi punto sulla mappa, cerca una città oppure scegli un **Preferito**.
   - Premi **Imposta Posizione**: apri Apple Maps o qualsiasi altra app e vedrai la tua nuova posizione GPS!
   - Quando vuoi tornare alla realtà, premi il pulsante di ripristino rosso (**Ripristina GPS reale**).

---

## Risoluzione problemi comuni

- **Timeout connessione (15s):** controlla che **LocalDevVPN** risulti attiva (icona VPN in alto), che il **Wi-Fi** sia acceso e che tu abbia concesso a PinShift il permesso **Rete locale** (*Impostazioni → Privacy e sicurezza → Rete locale → PinShift*).
- **Errore DVT RemoteServer / Developer Disk Image:** dopo un riavvio completo dell'iPhone, iOS smonta la *Developer Disk Image (DDI)*. Montala una volta con il tool `StikDebug` / `SideStore` oppure collegando l'iPhone al PC con `idevice` / `3uTools`.
- **La posizione torna reale quando chiudo completamente l'app:** è un comportamento normale di iOS 17+ — il canale DVT deve restare aperto per mantenere il GPS simulato. Tieni PinShift aperta in background senza chiuderla con lo swipe verso l'alto.
