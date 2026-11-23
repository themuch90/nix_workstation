# nix_workstation

> **Avviso: progetto sperimentale, non consigliato per l'uso in produzione.**
> Proxmox VE è fornito da [proxmox-nixos](https://github.com/SaumonNet/proxmox-nixos),
> un progetto della comunità in sviluppo e non supportato da Proxmox Server
> Solutions. Usare la configurazione su macchine di test o dove
> un'interruzione è accettabile, con backup di dati e VM.
>
> **Notice: experimental project, not recommended for production use.**
> The documentation is in the Wiki tab of this repository (English: page `en-Home`).

Configurazione [NixOS](https://nixos.org) modulare per workstation aziendali:
Active Directory, KDE Plasma, applicazioni da ufficio,
[Proxmox VE](https://www.proxmox.com/proxmox-virtual-environment) con una rete
dedicata alle VM e VM Station, console RDP/SSH per le VM Proxmox.

Documentazione: scheda **Wiki** di questo repository, pagina `Home` (italiano) ·
`en-Home` (English).

## Architettura

Questo repository è **generico**: contiene i moduli `my.*`, i pacchetti e il
modello `hosts/workstation`, nessun dato di una macchina specifica. Ogni PC ha
un repository **privato** `nix_workstation_<pc>` in `/etc/nixos`, che usa
questo come input `base` del flake e contiene solo `flake.nix`, `flake.lock` e
`hosts/<pc>/`.

```nix
{
  inputs = {
    base.url = "git+https://git.example.com/it/nix_workstation.git";
    # packages locked in the PC repository, updated only by system-update
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    proxmox-nixos.url = "github:SaumonNet/proxmox-nixos";
    solidcraft.url = "github:tangency-labs/solidcraft/v0.44.1";   # stable releases only
    base.inputs.nixpkgs.follows = "nixpkgs";
    base.inputs.proxmox-nixos.follows = "proxmox-nixos";
    base.inputs.solidcraft.follows = "solidcraft";
  };
  outputs = { base, ... }: {
    nixosConfigurations.pc01 = base.lib.mkHost { name = "pc01"; path = ./hosts/pc01; };
  };
}
```

## Installazione di un nuovo PC

1. Installare NixOS 26.05 dalla [ISO ufficiale](https://nixos.org/download/).
2. Creare sul server git un repository privato vuoto, ad esempio `nix_workstation_pc01`.
3. Clonare questo repository e avviare il wizard. L'indirizzo da incollare è
   quello del pulsante *Code* / *Clone* di questa pagina; `install.sh` lo legge
   dal clone e lo propone al wizard come repository generico:

```bash
read -rp "Indirizzo del repository: " URL && nix-shell -p git --run "git clone '$URL' ~/nix_workstation" && sudo ~/nix_workstation/install.sh
```

Procedura completa: pagine `Installazione` e `Nuovo-PC` della wiki.

## Comandi di gestione

| Comando | Funzione |
|---|---|
| `sudo nix-tools` | menu di gestione: aggiornamenti, rollback, diagnostica, dominio, rete |
| `sudo config-update` | aggiorna la configurazione del PC e `base`, applica e invia al server |
| `sudo system-update` | aggiorna i pacchetti e applica |
| `update-check` | controllo giornaliero degli aggiornamenti con notifica |
| `sudo driver-check` | analizza l'hardware e propone la configurazione dei driver |
| `sudo app-manager` | attiva o disattiva le applicazioni (anche quelle spente all'installazione) |
| `sudo repo-urls` | cambia gli URL del repository generico e di quello del PC |
| `remote-update pc01 …` | allinea subito i PC al loro repository (con `configSync` si allineano da soli) |

## Struttura

```
flake.nix            input, lib.mkHost, nixosModules.default, app new-pc
hosts/workstation/   modello per i PC
modules/             core, users, identity, desktop, apps, virtualization,
                     vmstation, hardware, maintenance
pkgs/vmstation/      VM Station (Python, PySide6)
pkgs/new-pc/         wizard di installazione
docs/MEMORIA.md      decisioni tecniche e problemi risolti
```

## Componenti esterni

| Componente | Provenienza |
|---|---|
| [NixOS / nixpkgs](https://github.com/NixOS/nixpkgs) 26.05 | cache binaria ufficiale |
| [Proxmox VE](https://www.proxmox.com/proxmox-virtual-environment) | [proxmox-nixos](https://github.com/SaumonNet/proxmox-nixos), cache del progetto `cache.saumon.network` |
| [SSSD](https://sssd.io), [adcli](https://gitlab.freedesktop.org/realmd/adcli) | nixpkgs |
| [KDE Plasma 6](https://kde.org/plasma-desktop/) | nixpkgs |
| [FreeRDP](https://www.freerdp.com) | nixpkgs |
| [Microsoft Edge](https://www.microsoft.com/edge), [Visual Studio Code](https://code.visualstudio.com) | nixpkgs, licenza proprietaria |
| [SolidCraft](https://github.com/tangency-labs/solidcraft) | flake del progetto, solo release stabili, compilato localmente |
| [Bambu Studio](https://github.com/bambulab/BambuStudio) (spento di default) | nixpkgs, compilato localmente |

**Compilati localmente:** SolidCraft (nessuna cache binaria, circa 30 minuti
al primo build), Bambu Studio se attivato (escluso dalla cache ufficiale
perché non libero), Visual Studio Code con una correzione alla ricetta nixpkgs,
VM Station e gli script di gestione di questo repository. Elenco completo:
pagina `Riferimenti` della wiki.

## Licenza

[MIT](LICENSE). Vale per il contenuto di questo repository; i componenti
esterni mantengono le proprie licenze.
