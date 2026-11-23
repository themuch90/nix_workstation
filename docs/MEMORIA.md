# Memoria del progetto

Diario tecnico: perché la configurazione è fatta così, cosa è stato
verificato sul PC reale, problemi incontrati e soluzioni, cosa resta da fare.
La wiki del repository (pagine in italiano e, con prefisso `en-`, in inglese; repository git `nix_workstation.wiki.git`) spiega *come usarla*; il README è solo una panoramica; questo file spiega *come ci si è arrivati*.

> Aggiornare questo file a ogni modifica significativa.
> Repository pubblico: **mai** inserire password, token, IP interni o nomi utente reali.

Ultimo aggiornamento: 2026-11-17

---

## 1. Obiettivo

Workstation NixOS aziendale "come Windows", configurata in modo dichiarativo
e modulare, così che ogni funzione si possa modificare o spegnere da sola:

- utente amministratore locale sempre disponibile;
- login con utenti Active Directory, anche fuori rete, con l'ultimo utente
  proposto alla schermata di accesso;
- applicazioni da ufficio e sviluppo;
- Proxmox VE sul PC, con una rete NAT per le VM;
- un'interfaccia stile VMware Workstation (VM Station) per aprire le
  console delle VM (RDP e SSH).

## 2. Decisioni principali e motivazioni

| Decisione | Motivazione |
|---|---|
| Flake + moduli `my.*` attivabili, valori solo in `hosts/<host>/default.nix` | modificare una funzione senza toccare le altre; più PC con lo stesso codice |
| nixpkgs `nixos-26.05` | stessa release della ISO di installazione |
| proxmox-nixos senza `inputs.nixpkgs.follows` | il progetto supporta solo la propria versione di nixpkgs |
| `users.mutableUsers = false` | utenti e password dichiarativi; l'utente creato dall'installer sparisce |
| Password di default `CHANGEME` in chiaro, opzione `hashedPassword` con precedenza | repository pubblico; avviso in build finché resta CHANGEME |
| SSSD + adcli (script `ad-join`), non realmd | realmd su NixOS è poco affidabile; adcli è ciò che realmd usa comunque |
| `cache_credentials`, `offline_credentials_expiration = 0` | login offline senza scadenza, come Windows |
| `use_fully_qualified_names = false` | si entra con `nome.cognome`, non `nome.cognome@dominio` |
| KDE Plasma 6 + SDDM con lista utenti nascosta | il tema Breeze precompila il campo utente con l'ultimo accesso (comportamento Windows) |
| Proxmox `ipAddress` = IP del bridge VM (172.30.20.1) | non cambia quando il portatile cambia rete |
| Bridge `vmbr1` senza porte fisiche + NAT con `externalInterface = null` | NAT verso qualunque interfaccia (cavo, Wi-Fi, VPN) |
| dnsmasq con `resolveLocalQueries = false` | l'host continua a usare il DNS di NetworkManager, necessario per AD |
| `pve-admin-users`: servizio che rende `localadmin@pam` Administrator | su NixOS root non ha password, quindi `root@pam` non è utilizzabile |
| Opzione `my.users.localAdmin.rootHashedPassword` (default null) per il login root@pam | Proxmox concede solo a root@pam (non al ruolo Administrator) USB/PCI reali e il restore di backup che li contengono; solo hash, impostato sul PC (repo pubblico); SSH resta `prohibit-password` |
| KWin `FocusStealingPreventionLevel=0` in /etc/xdg/kwinrc (opzione `raiseNewWindows`) | con il default "Bassa" il browser aperto da un link o il lettore aperto da un file restano dietro e lampeggiano; su Wayland lo stesso livello vale per le richieste di attivazione xdg-activation |
| Import WireGuard "non è una configurazione client OpenVPN valida" | KDE prova l'import WireGuard e, se fallisce, ritenta come OpenVPN mostrando quell'errore. Causa: nome del file (= nome interfaccia) oltre 15 caratteri | rinominare il `.conf` con al massimo 15 caratteri `[A-Za-z0-9_=+.-]` |
| Plugin VPN di NetworkManager: OpenVPN, OpenConnect, L2TP (opzione `my.core.vpnPlugins`) | WireGuard è integrato in NetworkManager, gli altri tipi no ("Manca il supporto di NetworkManager per OpenVPN"). vpnc, FortiSSL e SSTP esclusi: in nixpkgs 26.05 sono segnati come insicuri e bloccano la build; per Fortinet si usa OpenConnect |
| SolidCraft come input del flake, senza `follows` | il flake asserisce una versione minima di Rust (oggi 1.95, uguale a quella di nixos-26.05): con `follows` un aggiornamento di SolidCraft potrebbe bloccare la valutazione dell'intero sistema. Nessuna cache binaria: viene compilato sul PC (circa 1 GB di dipendenze e circa 30 minuti al primo build). Anche la sola valutazione del sistema lo compila: `system.replaceDependencies` (popup Proxmox) deve conoscere la chiusura del sistema e la costruisce durante la valutazione. Una build interrotta riparte da zero |
| WhatsApp → ZapZap | non esiste client ufficiale; ZapZap è Qt, si integra con KDE |
| Office: Microsoft 365 come PWA via Edge (policy `WebAppInstallForceList`) | Office desktop per Linux non esiste; ONLYOFFICE resta disponibile ma commentato |
| VS Code: pacchetto normale, non `vscode-fhs` | serve per applicare la correzione al bug nixpkgs (vedi §4) |
| `flakeHost` passato da `mkHost` in `flake.nix` | il nome della macchina (`my.core.hostName`) è indipendente dal profilo del flake |
| Repository specifico per PC con questo come input `base` (`lib.mkHost`, `nixosModules.default`), al posto del fork o del clone con commit locali | il generico resta il master senza dati di macchine; niente rebase e conflitti su `hosts/workstation/default.nix`; la configurazione del PC è salvata sul server; `flake.lock` del PC fissa la versione del generico (rollback con `git revert`). `mkHost` aggiunge i moduli da sé: la cartella host si copia così com'è. Gli script riconoscono il repository del PC dall'input `base` e solo lì fanno `nix flake update base` e `git push` (dopo uno switch riuscito, opzione `pushConfig`) |
| Popup "No valid subscription" rimosso con `system.replaceDependencies` | pve-manager usa la copia interna di `proxmox-widget-toolkit`: un overlay non basta |
| Aggiornamenti: solo notifica, mai automatici | `system-update` (pacchetti) e `config-update` (configurazione dal git) si lanciano a mano |
| Driver: `my.hardware.drivers` + comando `driver-check` che stampa il blocco da incollare | la scelta del driver video non si può fare in automatico in fase di build (valutazione pura); l'host resta generico, i valori si ricavano sul PC |
| NVIDIA: opzione `nvidia.driver` (stable / legacy_580 / 470 / 390) | in nixpkgs `stable` è il ramo 595, che non supporta più Maxwell/Pascal/Volta: per queste serve `legacy_580` |
| `system-clean` interattivo, oltre a `nix.gc` settimanale | si sceglie quante versioni tenere; aggiorna anche il menu di avvio (`switch-to-configuration boot`) |

## 3. VM Station (pkgs/vmstation)

- Python + PySide6 (Qt6), pacchettizzato con `wrapQtAppsHook`.
- API Proxmox con token API o ticket da password (la password non viene salvata).
- Più server: `servers` nella config utente (id, nome, URL, utente, token); la
  vecchia sezione `proxmox` diventa il server `local`, le chiavi VM passano da
  `pve:<vmid>` a `pve:<server>:<vmid>` (le password RDP/SSH già salvate per VM
  Proxmox vanno reinserite una volta). Con token, il login fa una chiamata di
  prova a `/version` per segnalare subito token errati.
- Riepiloghi: server da `/nodes`, `/nodes/<n>/status`, `/nodes/<n>/storage`;
  VM da `cluster/resources` + `config` (ostype, description). La selezione di
  una VM apre una scheda anteprima (sostituita alla selezione successiva).
- Opzioni RDP a caselle (`RDP_FLAGS`): default globali in `rdp.flags`; per
  connessione si salvano solo le caselle diverse dai default. Al caricamento gli
  argomenti extra che ora sono caselle (es. `/dynamic-resolution`,
  `/drive:home,<home>`) vengono tolti e convertiti.
- Tastiera RDP: layout di sistema (`keyboard` in /etc/vmstation/config.json da
  `my.core.keyboardLayout`, ripiego `localectl`) convertito nel codice Windows
  per `/kbd:layout:`; non aggiunto se negli argomenti extra c'è già `/kbd`.
- Prima connessione a una VM Proxmox senza voce in `vms`: si apre prima
  *Impostazioni connessione*, poi la connessione.
- Token con "Separazione privilegi" attiva: API 200 ma elenco vuoto (nessun
  permesso). Serve `--privsep 0` o ACL propri.
- Console: xfreerdp avviato con `/parent-window:<XID>` dentro un widget nativo
  della scheda. Per questo l'app gira forzatamente su X11/XWayland
  (`QT_QPA_PLATFORM=xcb`). Ridimensionamento con `xdotool windowsize` +
  `/dynamic-resolution`.
- SSH: xterm incorporato con `-into <XID>` (font, tema scuro, Ctrl+Shift+C/V
  via `-xrm`), oppure Konsole in finestra. La console incorporata (xfreerdp o
  xterm) si trova con `xwininfo -children` sulla finestra della scheda, poi
  `xdotool windowsize` / `windowfocus`. Il comando ssh gira in `sh -c` che, se
  la connessione cade, lascia il terminale aperto col motivo.
- IP della VM dal QEMU guest agent, con preferenza per la rete VM: prefisso
  ricavato da `vmNetwork.address` nel modulo (es. `172.30.20.`).
- Utente e password per ogni connessione; password nel portafoglio KDE con la
  libreria `keyring` (Secret Service / KWallet), chiave `<vm>/<utente>`.
  RDP: `/p:` (FreeRDP la maschera in argv). SSH: `sshpass -e`, password nella
  variabile SSHPASS e non in argv. Container LXC: default SSH.
- Configurazione: `~/.config/vmstation/config.json` (600), default in
  `/etc/vmstation/config.json` generato dal modulo. Il file utente salva solo
  le differenze dai default: prima salvava tutto e "congelava" anche l'URL di
  Proxmox, che quindi non seguiva più la configurazione NixOS.

## 4. Problemi incontrati e soluzioni

| Problema | Causa | Soluzione |
|---|---|---|
| Primo `nixos-rebuild --flake` fallisce subito | flake non abilitati sul sistema dell'installer | `export NIX_CONFIG=...` con experimental-features e cache Proxmox (README §2.3) |
| Rebuild fallito ma riavviato: hostname ancora `nixos` | l'errore era sfuggito nell'output | `tee /root/rebuild.log`, riavviare solo se non ci sono errori |
| Build `update-check` fallisce (SC2034) | `writeShellApplication` esegue shellcheck; variabile usata solo con `notifyUsers` non vuoto | variabile usata sempre |
| Build VS Code 1.144 fallisce: `rm .../@vscode/ripgrep/bin/rg` | bug della ricetta nixpkgs: il file è stato spostato upstream | `overrideAttrs` che rende il comando tollerante (no-op quando nixpkgs sarà corretto) |
| `fatal: detected dubious ownership` | repo in `/etc/nixos` di proprietà di un altro utente | lavorare come root, `chown -R root:root`, `safe.directory` (gestito da `config-update`) |
| Popup sottoscrizione ancora presente dopo le patch | **cache del browser**: la pagina carica `/proxmoxlib.js?ver=<prima riga del file>`; con Nix la prima riga è sempre `// v-t315532800` (SOURCE_DATE_EPOCH) e `Last-Modified` è 1970, quindi URL identico e risposta 304: il browser tiene il JS vecchio anche dopo un aggiornamento. Il file servito era già patchato (verificato con curl) | la patch cambia la prima riga in `// v-t…-<versione>-nonagN` (cambiare N se si modifica la patch); patch resa valida anche per `proxmoxlib.min.js` (parametro minificato `a`), la build fallisce se un file non è patchato |
| Storage NFS non montabile in Proxmox | mancano `nfs-utils`/`rpcbind`; i demoni PVE non li trovano nel PATH | opzione `nfsClient`: `boot.supportedFilesystems`, rpcbind, `path` di pvedaemon/pvestatd/pveproxy |
| Repo "pubblico" non visibile senza login | il server Gitea ha `REQUIRE_SIGNIN_VIEW = true` | da cambiare in `app.ini` se si vuole l'accesso anonimo |
| `config-update` senza credenziali sul PC | come root non c'è un gestore credenziali; il token non va salvato in chiaro | file `git-credentials` in una Cassaforte KDE (Plasma Vault) aperta, letto come l'utente di sudo (root non accede al mount FUSE), copia temporanea cancellata a fine esecuzione. `fetch` separato da `rebase`: un login fallito non viene più segnalato come "conflitto" |
| Login git da salvare senza file | l'utente vuole che le credenziali digitate vengano proposte per il salvataggio | portafoglio KDE via `secret-tool` (Secret Service di KWallet) eseguito come l'utente di sudo con il suo `DBUS_SESSION_BUS_ADDRESS`; attributi `service=nixconfiguration-git host=<server>`, segreto `utente\npassword`. Lettura: helper git che stampa username/password da variabili d'ambiente. Cattura di quanto digitato: helper che su `store` scrive in un file temporaneo 600; poi domanda [S/n]. Helper e formato provati con `git credential fill/approve`; flusso completo con sudo non provato |
| `sudo` per gruppi AD: maiuscole e `Administrators` | SSSD restituisce nomi minuscoli; i gruppi BUILTIN (S-1-5-32-*) sono ignorati | `sudoGroups` in minuscolo, usare `domain admins` o un gruppo globale dedicato; opzione `sudoUsers` |
| Script esterno `post-pve-install.sh` | pensato per Proxmox su Debian (apt, /usr/share) | non usarlo su NixOS; equivalenti dichiarativi nei moduli |
| Dopo la sospensione il blocco schermo non accetta la password | `security.krb5.enable` attiva da solo pam_krb5 + pam_ccreds; in `/etc/pam.d/kde` pam_ccreds ha `[default=die]` e il suo helper manca | `security.pam.krb5.enable = false` (SSSD gestisce già Kerberos e cache offline) |
| Dopo uno spegnimento brutale `id utente: no such user` | all’avvio nscd riavviato 5 volte in un secondo → `start-limit-hit`; SSSD lo richiede e non parte (cache integra) | `startLimitIntervalSec = 0` per nscd (SSSD ha già i suoi limiti nel modulo NixOS). Sblocco immediato: `systemctl reset-failed nscd sssd; systemctl start nscd sssd` |
| Login AD riuscito ma schermo nero | scritto `DOMINIOutente` alla schermata di login: SSSD accetta, systemd-logind rifiuta il nome con `` (niente `/run/user/UID`, KWin si chiude) | entrare con il solo nome (`utente`); `re_expression` in SSSD accetta solo nomi semplici, così il login fallisce subito; SDDM ricorda l’ultimo nome digitato (`/var/lib/sddm/state.conf`) |
| Wi-Fi alla schermata di login | SDDM non ha selettore di reti; Plasma salva le password Wi-Fi nel portafoglio utente (non disponibile prima del login) | `wifiForAllUsers`: plasma-nm crea le nuove reti come connessioni di sistema (`/etc/xdg/plasma-nm`, `SystemConnectionsByDefault`) e una regola polkit consente agli utenti locali attivi (anche AD non admin) di salvarle; per le reti esistenti: tutti gli utenti + password per tutti gli utenti |
| Web app Microsoft 365 non installate (solo Outlook, a mano) | Edge non leggeva nessuna policy: il file era in `/etc/opt/microsoft/msedge/policies/managed`, ma l'eseguibile cerca in `/etc/opt/edge/policies` | file spostato in `/etc/opt/edge/policies/managed`; verificato leggendo `edge://policy` (stato OK) con Edge headless + DevTools, montando la cartella di prova su `/etc/opt` in un namespace utente. Outlook ora su `outlook.cloud.microsoft`, aggiunto `fallback_app_name` |
| Word/Excel/PowerPoint/OneDrive senza icona (cubo generico) | i loro URL rimandano a `*.cloud.microsoft` o al login, senza manifest PWA: Edge installa un segnaposto. Teams (manifest in pagina) e Outlook funzionano | per questi servizi voci di menu con `microsoft-edge --class=m365-<app> --app=<url>` e icone Fluent dal CDN Microsoft (`fetchurl`); `StartupWMClass` = classe, verificato in Xvfb. Policy anche in `/etc/opt/microsoft/msedge/...` come protezione |
| `nix flake update base` su un repository privato | il server richiede il login anche in lettura; nix non ha un suo login per git+https | nix scarica gli input git con il comando `git` ereditando l'ambiente (verificato: con `GIT_CONFIG_*` che svuota `credential.helper` il download fallisce). Gli script passano il login con `GIT_CONFIG_COUNT/KEY/VALUE` (helper `store --file` o helper da variabili), valido sia per git sia per nix. Flusso config-update/system-update e update-check provati in una cartella di prova (generico con `git+file`, server finto bare); con login reale e con sudo non ancora provato |
| Wizard `new-pc` bloccato sul PC con Proxmox | `find` sulla cartella clonata si fermava sul mount FUSE `/etc/pve`; inoltre un repository non vuoto con HEAD su un ramo inesistente veniva clonato senza file e sembrava vuoto | controllo con `git ls-remote --heads` prima del clone, niente `find` |
| Fork del generico per i dati di un PC | rebase a ogni aggiornamento, conflitti sullo stesso `default.nix`, rischio di pull request verso il generico | sostituito dal repository specifico con input `base` (§2) |
| Estensione Claude Code in VS Code: "Could not start dynamically linked executable" | NixOS non esegue binari Linux generici (manca il loader in /lib64) | `programs.nix-ld` nel modulo vscode (opzione `nixLd`) |

## 5. Stato verificato sul PC reale

| Funzione | Stato |
|---|---|
| Installazione e applicazione del flake | ✅ funziona (dopo le correzioni del §4) |
| VS Code | ✅ installato con la correzione |
| Join AD e login con utente di dominio | ✅ funziona |
| Login AD fuori rete | ⏳ da provare |
| SDDM con ultimo utente precompilato | ⏳ da confermare |
| sudo per utente/gruppo AD | ⏳ in corso di configurazione |
| Popup sottoscrizione Proxmox | ⏳ file servito già patchato; da riverificare nel browser dopo il cambio di `?ver=` |
| Storage NFS | ⏳ supporto aggiunto, da provare con `showmount -e` |
| `config-update` | ✅ funziona |
| Bloc Num, Dolphin vista Dettagli | ⏳ aggiunti, da verificare |
| Microsoft 365 (PWA Edge) | ⏳ da verificare |
| VM Station | ⏳ RDP verso VM reale funzionante (console a 640x480 corretta); più server, riepiloghi e caselle RDP provati in Xvfb con API simulate |
| Rete VM 172.30.20.0/24, DHCP, NAT | ⏳ da verificare con una VM |
| Controllo aggiornamenti e notifica | ⏳ da verificare (`update-check` manuale) |
| `system-clean` | ⏳ da verificare sul PC (build e shellcheck OK) |
| `driver-check` / `my.hardware.drivers` | ⏳ script provato su un portatile ibrido Intel + NVIDIA Maxwell (rilevamento e consigli corretti); driver NVIDIA non ancora installato su un PC |

## 6. Da fare / idee

- Verificare il popup sottoscrizione nel browser. Controlli lato server:
  `curl -sk https://localhost:8006/ | grep -o 'proxmoxlib.js?ver=[^"]*'` (deve finire con `-nonag2`)
  e `curl -sk https://localhost:8006/proxmoxlib.js | grep -o 'orig_cmd(); return;'`.
- Eventuale: popup anche nella Web UI mobile (`pve-yew-mobile-gui`), che lo
  script della community patcha a parte; qui non è ancora gestita.
- Opzione per spegnere i servizi HA di Proxmox (`pve-ha-lrm`, `pve-ha-crm`),
  inutili su un nodo singolo.
- Vista dettagliata di default anche nelle finestre Apri/Salva KDE
  (`kdeglobals`, `[KFileDialog Settings]`), attenzione a conflitti con il
  modulo Plasma.
- Eventuale WinApps (Office desktop in VM Windows tramite RemoteApp xfreerdp).
- `flake.lock` non è nel repository generico: lo tiene ogni PC (nel repository
  specifico del PC è versionato e fissa anche gli input di `base`).
- Provare sul PC reale il passaggio al repository specifico e il wizard `new-pc` (README §5ter; provato solo con --target e --no-switch in una cartella di prova):
  login per `base` alla prima build, `config-update` con push, `update-check`
  con `gitCredentialsFile`.
- Valutare un file `hosts/<host>/local.nix`, solo locale, per le impostazioni
  private, così da ridurre i conflitti durante `config-update`.

## 7. Storia

Le modifiche sono in `git log`. Prima del primo commit: passaggio da GNOME a KDE,
generalizzazione per il repository pubblico (utente `localadmin`, password
`CHANGEME`, dominio `example.local`), ONLYOFFICE sostituito da Microsoft 365,
nome macchina spostato in `my.core.hostName`.
