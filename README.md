# icinga-pgsql

Installazione guidata di **Icinga** con database **PostgreSQL**, pronta all'uso, su una VM (o su qualsiasi server Debian/Ubuntu).

Componenti installati e configurati (seguendo la documentazione dei repository GitHub ufficiali Icinga):

| Componente | Note |
|---|---|
| Icinga 2 | feature `api` e `icingadb`, plugin `monitoring-plugins` |
| Icinga DB + `icingadb-redis` | database `icingadb` su PostgreSQL (`type: pgsql`) |
| Icinga Web 2 | database `icingaweb2` su PostgreSQL, utente admin creato senza wizard |
| Icinga DB Web | modulo abilitato, command transport verso l'API |
| Icinga Director | database `director` su PostgreSQL, kickstart e daemon `icinga-director` |
| PostgreSQL | locale (predefinito) oppure un server esistente |

Sistemi supportati: Debian 12/13, Ubuntu 22.04/24.04 (RAM consigliata: 2 GB o piu').

## Uso su un server o VM esistente

```bash
git clone <URL-del-repo> icinga-pgsql && cd icinga-pgsql
sudo ./runsetup.sh          # guidato: FQDN, fuso orario, admin web, PostgreSQL locale/remoto
sudo ./runsetup.sh --yes    # senza domande (valori predefiniti)
```

Parametri preimpostabili via ambiente: `ICINGA_FQDN`, `TIMEZONE`, `WEB_ADMIN_USER`, `WEB_ADMIN_PASS`, `PG_LOCAL=0 PG_HOST PG_PORT PG_ADMIN_USER PG_ADMIN_PASS`.

Al termine: `http://<ip>/icingaweb2`. Le password generate sono in `/root/icinga-credentials.txt` (permessi 600), il log in `/var/log/icinga-setup.log`. Lo script e' rieseguibile.

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
7. Director: migrazione, kickstart, servizio systemd
8. Verifica dei servizi e riepilogo

## Sicurezza

Password casuali per ogni database e utente API. Cambiare la password admin al primo accesso e limitare l'accesso alla porta 80/5665 con un firewall; per produzione abilitare HTTPS su Apache.
