# icinga-pgsql

Installazione guidata di **Icinga** con database **PostgreSQL**, pronta all'uso, su una VM (o su qualsiasi server Debian/Ubuntu), con una **libreria di template Director** gia' importata.

Componenti installati e configurati (seguendo la documentazione dei repository GitHub ufficiali Icinga):

| Componente | Note |
|---|---|
| Icinga 2 | feature `api` e `icingadb`, plugin `monitoring-plugins` |
| Icinga DB + `icingadb-redis` | database `icingadb` su PostgreSQL (`type: pgsql`) |
| Icinga Web 2 | database `icingaweb2` su PostgreSQL, utente admin creato senza wizard |
| Icinga DB Web | modulo abilitato, command transport verso l'API |
| Icinga Director | database `director` su PostgreSQL, kickstart e daemon `icinga-director` |
| Libreria di template | comandi, template host/servizio, campi dati e basket di [zampat/icinga2-monitoring-templates](https://github.com/zampat/icinga2-monitoring-templates) (senza NetEye) |
| PostgreSQL | locale (predefinito) oppure un server esistente |

Sistemi supportati: Debian 12/13, Ubuntu 22.04/24.04 (RAM consigliata: 2 GB o piu').

## Uso su un server o VM esistente

```bash
git clone https://github.com/NicolaCaragia/icingacarra.git icinga-pgsql && cd icinga-pgsql
sudo ./runsetup.sh          # guidato: FQDN, fuso orario, admin web, PostgreSQL locale/remoto
sudo ./runsetup.sh --yes    # senza domande (valori predefiniti)
```

`runsetup.sh`, `icinga-templates.sh`, `icinga-theme.sh` e la cartella `theme/` devono restare nella stessa cartella (per i template, se manca lo script, `runsetup.sh` prova a scaricarlo da GitHub).

Parametri preimpostabili via ambiente: `ICINGA_FQDN`, `TIMEZONE`, `WEB_ADMIN_USER`, `WEB_ADMIN_PASS`, `PG_LOCAL=0 PG_HOST PG_PORT PG_ADMIN_USER PG_ADMIN_PASS`, `WITH_TEMPLATES=0` (salta la libreria di template), `WITH_THEME=0` (salta il tema).

Al termine: `http://<ip>/icingaweb2`. Le password generate sono in `/root/icinga-credentials.txt` (permessi 600), il log in `/var/log/icinga-setup.log` (template: `/var/log/icinga-templates.log`). Gli script sono rieseguibili.

## VM su Proxmox

Sull'host Proxmox (come root) `proxmox/create-vm.sh` crea una VM Debian 12 gia' pronta: scarica l'immagine cloud, imposta IP (statico o DHCP), DNS, utente e password, abilita il login SSH con password e installa `git` e `qemu-guest-agent` al primo avvio.

```bash
git clone https://github.com/NicolaCaragia/icingacarra.git && cd icingacarra
./proxmox/create-vm.sh            # guidato
IP=10.0.0.50/24 GW=10.0.0.1 STORAGE=local-lvm ./proxmox/create-vm.sh --yes
```

Le immagini cloud Debian accettano solo chiavi SSH e non hanno password: per questo lo script crea un file cloud-init (snippet) con la password, scritto con permessi 600. Se lo storage non ha il contenuto "Snippets", lo script propone di abilitarlo. Per usare anche la tua chiave: `SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub`. Poi, nella VM, `sudo ./runsetup.sh` come sopra.

## VM con Vagrant

```bash
vagrant up                      # VirtualBox
vagrant up --provider=hyperv    # Hyper-V (PowerShell come amministratore)
```

Interfaccia su `http://localhost:8080/icingaweb2`. Credenziali: `vagrant ssh -c 'sudo cat /root/icinga-credentials.txt'`.

## Cosa fa runsetup.sh

1. Repository `packages.icinga.com` con keyring firmato
2. PostgreSQL (locale o esistente)
3. Database/utenti `icingadb`, `icingaweb2`, `director` (estensione `citext`)
4. Icinga 2, API, Redis, feature `icingadb`
5. Daemon Icinga DB con schema PostgreSQL
6. Icinga Web 2 + Icinga DB Web su Apache/PHP, utente admin
7. Director: migrazione, kickstart (con l'endpoint corretto e ritentativi), servizio systemd
8. Verifica dei servizi e riepilogo
9. Libreria di template Director e plugin (`icinga-templates.sh`)
10. Tema icingacarra: logo e sfondo personalizzati (`icinga-theme.sh`)

Prima di iniziare attende la fine di cloud-init e il lock di apt, e controlla che DNS e rete funzionino (con un messaggio chiaro se non e' cosi').

## Libreria di template (icinga-templates.sh)

Si puo' lanciare anche da solo, dopo l'installazione: `sudo ./icinga-templates.sh`. Importa da [zampat/icinga2-monitoring-templates](https://github.com/zampat/icinga2-monitoring-templates) e [zampat/neteye4](https://github.com/zampat/neteye4) (i repo vengono scaricati in `/opt/icinga-templates`):

1. dipendenze (`snmp`, plugin Debian, `dos2unix`, ...);
2. campi dati e liste di Director: il file SQL originale e' per MariaDB e viene convertito al volo per PostgreSQL;
3. comandi, template host/servizio, periodi, notifiche: gli script `.sh` originali, eseguiti con `bash` (usano `[[ ]]`);
4. i basket di `baskets/monitoring_templates` (ethernetbox, ibm, linux, microsoft, network_traffic, oracle, sap, vmware), in piu' passate per risolvere le dipendenze. Si saltano i file che non sono basket Director (dashboard Grafana) e i duplicati. Per ogni basket non importato lo script dice il motivo (comando o template mancante);
5. plugin copiati in `/usr/lib/nagios/plugins` e `PluginContribDir` impostato; alla fine elenca i plugin ancora da installare a mano (`check_vmware_api`, `check_nwc_health`, ...);
6. deploy della configurazione.

Variabili: `WITH_NETEYE=1` (importa anche i template NetEye, inutili senza NetEye), `BASKET_DIRS="linux vmware"` (limita le cartelle di basket), `DIRECTOR_DB` (nome del database Director).

## Tema icingacarra (logo e sfondo)

`icinga-theme.sh` installa in Icinga Web 2 il tema **IcingaCarra**: il logo icingacarra (menu, menu compresso, pagina di accesso) al posto di quello Icinga e uno sfondo a tutto schermo su tutta l'interfaccia, con menu e contenuti semitrasparenti per la leggibilita'. Il tema e' scuro.

```bash
sudo ./icinga-theme.sh            # installa e imposta come tema predefinito
sudo ./icinga-theme.sh --remove   # torna al tema Icinga
```

- File in `theme/`: `IcingaCarra.less`, i loghi in `img/icingacarra/` e `preview.html` (anteprima da aprire nel browser).
- Lo sfondo e' `theme/img/icingacarra/background.jpg`: sostituiscilo con un'altra immagine per cambiarlo. Se il file manca si usa uno sfondo segnaposto.
- Dopo l'installazione ricarica la pagina con Ctrl+F5. Chi ha scelto un altro tema nelle proprie preferenze lo mantiene.

## Problemi noti e soluzioni

| Sintomo | Causa e soluzione |
|---|---|
| `Could not get lock /var/lib/apt/lists/lock` | cloud-init sta ancora installando pacchetti: lo script ora attende da solo (fino a 5 minuti) |
| `DNS non funzionante` | la VM non risolve i nomi: imposta il DNS (su Proxmox `qm set <vmid> --nameserver 1.1.1.1`) |
| Il Director mostra il wizard "Kickstart" | l'endpoint non coincideva con il nome del nodo Icinga 2: ora si usa `NodeName`; si puo' rifare con `icingacli director kickstart run` |
| `There is no such module or command: 'setup'` | le versioni recenti di Icinga Web 2 non hanno piu' il modulo `setup`: la configurazione Apache viene scritta a mano |
| Interfaccia web `404` | configurazione Apache non attiva: `a2enmod rewrite && a2enconf icingaweb2 && systemctl restart apache2` |
| Template senza campi personalizzati | l'import SQL dei campi e' fallito: dettagli in `/var/log/icinga-templates.log` |
| Il primo deploy di Director fallisce con "bind message supplies 0 parameters" | bug di Director su PostgreSQL quando non c'e' ancora uno stage attivo: `icinga-templates.sh` crea prima uno stage iniziale vuoto tramite l'API di Icinga 2 |
| `check_interfaces`, `check_wmi_plus`, `check_oracle_health`, ... mancanti | sono plugin esterni non inclusi nel repo di origine (per `check_interfaces` solo binari RHEL): vanno installati a mano, e i basket che li usano restano non importati |

## Collaudo

L'installazione completa (`runsetup.sh`, con template e tema) e' stata provata da zero su **Debian 13 (WSL2, systemd)**: servizi attivi, interfaccia web raggiungibile, kickstart e primo deploy di Director riusciti, 16 template host, 95 template servizio, 10 service set, 269 comandi, 242 campi dati, tema attivo. Rieseguendo `icinga-templates.sh` il risultato non cambia. Non provati: Ubuntu, Debian 12, Vagrant e `proxmox/create-vm.sh`.

## Sicurezza

Password casuali per ogni database e utente API. Cambiare la password admin al primo accesso e limitare l'accesso alla porta 80/5665 con un firewall; per produzione abilitare HTTPS su Apache.
