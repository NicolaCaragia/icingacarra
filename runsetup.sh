#!/usr/bin/env bash
# =============================================================================
# runsetup.sh - Installazione guidata di Icinga su PostgreSQL
#
#   Icinga 2 + Icinga DB (PostgreSQL) + Icinga Web 2 + Icinga DB Web + Director
#
# Sistemi supportati: Debian 12/13, Ubuntu 22.04/24.04
# Uso:
#   sudo ./runsetup.sh              # guidato (domande con valori predefiniti)
#   sudo ./runsetup.sh --yes        # non interattivo, usa i valori predefiniti
#   sudo ./runsetup.sh --help
# Ogni parametro puo' essere preimpostato via variabile d'ambiente, es.:
#   sudo ICINGA_FQDN=mon.example.org WEB_ADMIN_PASS=segreta ./runsetup.sh --yes
#   sudo WITH_TEMPLATES=0 ./runsetup.sh   # salta la libreria di template (step 9, icinga-templates.sh)
#   sudo WITH_THEME=0 ./runsetup.sh       # salta il tema icingacarra (step 10, icinga-theme.sh)
# Lo script e' rieseguibile: le password vengono salvate in $CRED_FILE.
# =============================================================================
set -Eeuo pipefail

VERSION="1.1.0"
CRED_FILE="${CRED_FILE:-/root/icinga-credentials.txt}"
LOG_FILE="${LOG_FILE:-/var/log/icinga-setup.log}"
ASSUME_YES=0

# ----------------------------------------------------------------- utilita' --
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_off=$'\e[0m'
[[ -t 1 ]] || { c_red=; c_grn=; c_ylw=; c_blu=; c_off=; }
info() { echo "${c_blu}==>${c_off} $*"; }
ok()   { echo "${c_grn} OK${c_off} $*"; }
warn() { echo "${c_ylw}WARN${c_off} $*" >&2; }
die()  { echo "${c_red}ERRORE${c_off} $*" >&2; exit 1; }
trap 'die "fallito alla riga $LINENO (comando: $BASH_COMMAND). Log: $LOG_FILE"' ERR

usage() { sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }

# ask VAR "Domanda" "default"  -> usa env se gia' valorizzata
ask() {
  local var=$1 prompt=$2 def=${3:-} cur=${!1:-} ans
  [[ -n $cur ]] && def=$cur
  if (( ASSUME_YES )); then printf -v "$var" '%s' "$def"; return; fi
  read -r -p "$prompt [$def]: " ans || true
  printf -v "$var" '%s' "${ans:-$def}"
}
confirm() { # confirm "Domanda" default(y/n)
  local def=${2:-y} ans
  (( ASSUME_YES )) && return 0
  read -r -p "$1 [${def}]: " ans || true
  ans=${ans:-$def}; [[ $ans =~ ^[yYsS] ]]
}
genpass() { openssl rand -hex 12; }

# Ricorda un segreto tra le esecuzioni: secret VAR
secret() {
  local var=$1
  if [[ -z ${!var:-} ]]; then printf -v "$var" '%s' "$(genpass)"; fi
}
save_creds() {
  umask 077
  {
    echo "# Generato da runsetup.sh $VERSION il $(date -Is)"
    for v in ICINGA_FQDN TIMEZONE PG_HOST PG_PORT PG_ADMIN_USER PG_ADMIN_PASS \
             DB_ICINGADB_PASS DB_WEB_PASS DB_DIRECTOR_PASS \
             API_ROOT_PASS API_WEB_PASS WEB_ADMIN_USER WEB_ADMIN_PASS; do
      printf "%s='%s'\n" "$v" "${!v:-}"
    done
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
}

# Attende fino a 5 minuti il blocco di apt/dpkg (su una VM appena creata, cloud-init sta ancora
# installando pacchetti e tiene il lock: senza attesa apt fallisce con "Could not get lock").
APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3)
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -y -qq "$@" >>"$LOG_FILE" 2>&1; }

# psql come amministratore (locale = utente postgres, remoto = PG_ADMIN_*)
psql_admin() {
  if [[ $PG_LOCAL == 1 ]]; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -X -q "$@"
  else
    PGPASSWORD=$PG_ADMIN_PASS psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 -X -q "$@"
  fi
}
psql_user() { # psql_user db user pass [args]
  local db=$1 user=$2 pass=$3; shift 3
  PGPASSWORD=$pass psql -h "$PG_HOST" -p "$PG_PORT" -U "$user" -d "$db" -v ON_ERROR_STOP=1 -X -q "$@"
}

# ------------------------------------------------------------ argomenti -----
for a in "$@"; do
  case $a in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage ;;
    *) die "opzione sconosciuta: $a" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "eseguire come root (sudo ./runsetup.sh)"
mkdir -p "$(dirname "$LOG_FILE")"; : >>"$LOG_FILE"

# Su una VM appena creata cloud-init puo' ancora essere al lavoro (e tenere il lock di apt): lo si attende.
if command -v cloud-init >/dev/null 2>&1; then
  info "Attendo il termine di cloud-init"
  timeout 600 cloud-init status --wait >>"$LOG_FILE" 2>&1 || true
fi

# Riutilizza le credenziali di una esecuzione precedente (senza sovrascrivere l'ambiente)
if [[ -f $CRED_FILE ]]; then
  info "Trovato $CRED_FILE: riutilizzo i valori precedenti"
  while IFS='=' read -r k v; do
    [[ $k =~ ^[A-Z_]+$ ]] || continue
    [[ -z ${!k:-} ]] && printf -v "$k" '%s' "${v//\'/}"
  done < "$CRED_FILE"
fi

# ------------------------------------------------------------- preflight ----
info "Controlli preliminari"
# shellcheck disable=SC1091
. /etc/os-release
case "$ID:$VERSION_ID" in
  debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ok "Sistema: $PRETTY_NAME" ;;
  *) die "Sistema non supportato: $PRETTY_NAME (servono Debian 12/13 o Ubuntu 22.04/24.04)" ;;
esac
CODENAME=${VERSION_CODENAME:-}
[[ -n $CODENAME ]] || die "VERSION_CODENAME non trovato in /etc/os-release"
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
(( mem_mb >= 1800 )) || warn "RAM ${mem_mb} MB: consigliati almeno 2 GB"
getent hosts packages.icinga.com >/dev/null || die "DNS non funzionante: packages.icinga.com non si risolve (controlla /etc/resolv.conf, il gateway e la rete della VM)"
curl -fsI https://packages.icinga.com >/dev/null || die "packages.icinga.com non raggiungibile (controlla rete, gateway ed eventuale proxy)"

# ---------------------------------------------------------- domande guidate --
echo
echo "${c_blu}=== Configurazione guidata (Invio = valore predefinito) ===${c_off}"
default_fqdn=$(hostname -f 2>/dev/null || hostname)
default_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)

ask ICINGA_FQDN   "Nome host (FQDN) di questo server di monitoraggio" "$default_fqdn"
ask TIMEZONE      "Fuso orario PHP"                                   "$default_tz"
ask WEB_ADMIN_USER "Utente amministratore Icinga Web"                 "icingaadmin"
if [[ -z ${WEB_ADMIN_PASS:-} ]]; then
  if (( ASSUME_YES )); then WEB_ADMIN_PASS=$(genpass)
  else
    read -r -s -p "Password per $WEB_ADMIN_USER [Invio = generata]: " WEB_ADMIN_PASS || true; echo
    [[ -n $WEB_ADMIN_PASS ]] || WEB_ADMIN_PASS=$(genpass)
  fi
fi

PG_LOCAL=${PG_LOCAL:-1}
if (( ! ASSUME_YES )) && [[ -z ${PG_HOST:-} ]]; then
  confirm "Installare PostgreSQL in locale su questo server?" y || PG_LOCAL=0
fi
if [[ $PG_LOCAL == 1 ]]; then
  PG_HOST=127.0.0.1; PG_PORT=5432; PG_ADMIN_USER=postgres; PG_ADMIN_PASS=
else
  ask PG_HOST "Host PostgreSQL esistente" "127.0.0.1"
  ask PG_PORT "Porta PostgreSQL" "5432"
  ask PG_ADMIN_USER "Utente amministratore PostgreSQL (CREATEDB/CREATEROLE)" "postgres"
  if [[ -z ${PG_ADMIN_PASS:-} ]]; then read -r -s -p "Password amministratore PostgreSQL: " PG_ADMIN_PASS; echo; fi
fi
for v in DB_ICINGADB_PASS DB_WEB_PASS DB_DIRECTOR_PASS API_ROOT_PASS API_WEB_PASS; do secret "$v"; done
export PG_LOCAL

echo
echo "Riepilogo:"
echo "  FQDN ............ $ICINGA_FQDN"
echo "  Fuso orario ..... $TIMEZONE"
echo "  PostgreSQL ...... $([[ $PG_LOCAL == 1 ]] && echo "locale (da installare)" || echo "$PG_HOST:$PG_PORT")"
echo "  Admin Web ....... $WEB_ADMIN_USER"
echo "  Database ........ icingadb, icingaweb2, director"
echo
confirm "Procedere con l'installazione?" y || die "annullato dall'utente"
save_creds

# ------------------------------------------------------ repository Icinga ----
info "[1/10] Repository Icinga"
export DEBIAN_FRONTEND=noninteractive
apt-get "${APT_OPTS[@]}" update -qq >>"$LOG_FILE" 2>&1
apt_install apt-transport-https wget curl gnupg ca-certificates openssl
KEYRING=/usr/share/keyrings/icinga-archive-keyring.gpg
if [[ ! -f $KEYRING ]]; then
  tmpdeb=$(mktemp --suffix=.deb)
  wget -q -O "$tmpdeb" "https://packages.icinga.com/icinga-archive-keyring_latest+${ID}${VERSION_ID}.deb"
  apt_install "$tmpdeb"; rm -f "$tmpdeb"
fi
REPO_URL="https://packages.icinga.com/${ID}"
cat > "/etc/apt/sources.list.d/${CODENAME}-icinga.list" <<EOF
deb [signed-by=$KEYRING] $REPO_URL icinga-${CODENAME} main
deb-src [signed-by=$KEYRING] $REPO_URL icinga-${CODENAME} main
EOF
apt-get "${APT_OPTS[@]}" update -qq >>"$LOG_FILE" 2>&1
ok "repository configurato"

# ------------------------------------------------------------ PostgreSQL ----
info "[2/10] PostgreSQL"
if [[ $PG_LOCAL == 1 ]]; then
  apt_install postgresql postgresql-contrib
  systemctl enable --now postgresql >>"$LOG_FILE" 2>&1
  for _ in $(seq 1 20); do runuser -u postgres -- pg_isready -q && break; sleep 1; done
fi
apt_install postgresql-client
ok "PostgreSQL pronto"

create_db() { # create_db db user pass
  local db=$1 user=$2 pass=$3
  if [[ $(psql_admin -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$user'") == 1 ]]; then
    psql_admin -d postgres -c "ALTER USER $user WITH PASSWORD '$pass'"
  else
    psql_admin -d postgres -c "CREATE USER $user WITH PASSWORD '$pass'"
  fi
  if [[ $(psql_admin -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'") != 1 ]]; then
    psql_admin -d postgres -c "CREATE DATABASE $db WITH ENCODING 'UTF8' TEMPLATE template0 OWNER $user"
  fi
  psql_admin -d "$db" -c "CREATE EXTENSION IF NOT EXISTS citext"
}
info "[3/10] Database icingadb, icingaweb2, director"
create_db icingadb   icingadb   "$DB_ICINGADB_PASS"
create_db icingaweb2 icingaweb2 "$DB_WEB_PASS"
create_db director   director   "$DB_DIRECTOR_PASS"
ok "database creati"

# --------------------------------------------------------------- Icinga 2 ----
info "[4/10] Icinga 2 + plugin + Redis (Icinga DB)"
apt_install icinga2 monitoring-plugins icingadb-redis
systemctl enable --now icingadb-redis >>"$LOG_FILE" 2>&1
if [[ ! -e /etc/icinga2/features-enabled/api.conf ]]; then
  icinga2 api setup >>"$LOG_FILE" 2>&1
fi
cat > /etc/icinga2/conf.d/api-users.conf <<EOF
object ApiUser "root" {
  password = "$API_ROOT_PASS"
  permissions = [ "*" ]
}

object ApiUser "icingadb-web" {
  password = "$API_WEB_PASS"
  permissions = [ "actions/*", "objects/modify/*", "objects/query/*", "status/query" ]
}
EOF
icinga2 feature enable icingadb >>"$LOG_FILE" 2>&1 || true
icinga2 daemon -C >>"$LOG_FILE" 2>&1 || die "configurazione Icinga 2 non valida (vedi $LOG_FILE)"
systemctl enable icinga2 >>"$LOG_FILE" 2>&1
systemctl restart icinga2
ok "Icinga 2 attivo (API su :5665)"

# -------------------------------------------------------------- Icinga DB ----
info "[5/10] Daemon Icinga DB"
apt_install icingadb
if [[ $(psql_user icingadb icingadb "$DB_ICINGADB_PASS" -tAc "SELECT to_regclass('public.host') IS NOT NULL") != t ]]; then
  psql_user icingadb icingadb "$DB_ICINGADB_PASS" -f /usr/share/icingadb/schema/pgsql/schema.sql >>"$LOG_FILE" 2>&1
  ok "schema icingadb importato"
fi
cat > /etc/icingadb/config.yml <<EOF
database:
  type: pgsql
  host: $PG_HOST
  port: $PG_PORT
  database: icingadb
  user: icingadb
  password: '$DB_ICINGADB_PASS'

redis:
  host: 127.0.0.1
  port: 6380

logging:
  level: info
  output: systemd-journald
EOF
chmod 640 /etc/icingadb/config.yml; chown root:icingadb /etc/icingadb/config.yml 2>/dev/null || true
systemctl enable icingadb >>"$LOG_FILE" 2>&1
systemctl restart icingadb
ok "icingadb attivo"

# ------------------------------------------------------------ Icinga Web 2 ---
info "[6/10] Icinga Web 2 + Icinga DB Web + Director (Apache/PHP)"
apt_install apache2 libapache2-mod-php php-pgsql icingaweb2 icingacli icingadb-web icinga-director
for ini in /etc/php/*/apache2/conf.d; do
  echo "date.timezone = $TIMEZONE" > "$ini/99-icinga.ini"
done
getent group icingaweb2 >/dev/null || groupadd -r icingaweb2
usermod -a -G icingaweb2 www-data
icingacli setup config directory --group icingaweb2 >>"$LOG_FILE" 2>&1 || true

ETC=/etc/icingaweb2
install -d -m 2770 -g icingaweb2 "$ETC" "$ETC/modules" "$ETC/modules/icingadb" "$ETC/modules/director"

db_resource() { # name dbname user pass charset
  cat <<EOF
[$1]
type = "db"
db = "pgsql"
host = "$PG_HOST"
port = "$PG_PORT"
dbname = "$2"
username = "$3"
password = "$4"
charset = "$5"
use_ssl = "0"

EOF
}
{
  db_resource icingaweb2 icingaweb2 icingaweb2 "$DB_WEB_PASS" ""
  db_resource icingadb   icingadb   icingadb   "$DB_ICINGADB_PASS" ""
  db_resource director   director   director   "$DB_DIRECTOR_PASS" "utf8"
} > "$ETC/resources.ini"

cat > "$ETC/config.ini" <<EOF
[global]
show_stacktraces = "0"
show_application_state_messages = "1"
config_resource = "icingaweb2"

[logging]
log = "syslog"
level = "ERROR"
application = "icingaweb2"
facility = "user"
EOF
printf '[icingaweb2]\nbackend = "db"\nresource = "icingaweb2"\n' > "$ETC/authentication.ini"
printf '[icingaweb2]\nbackend = "db"\nresource = "icingaweb2"\n' > "$ETC/groups.ini"
cat > "$ETC/roles.ini" <<EOF
[Administrators]
users = "$WEB_ADMIN_USER"
permissions = "*"
EOF
printf '[icingadb]\nresource = "icingadb"\n' > "$ETC/modules/icingadb/config.ini"
printf '[redis1]\nhost = "127.0.0.1"\nport = "6380"\n' > "$ETC/modules/icingadb/redis.ini"
cat > "$ETC/modules/icingadb/commandtransports.ini" <<EOF
[icinga2]
transport = "api"
host = "127.0.0.1"
port = "5665"
username = "icingadb-web"
password = "$API_WEB_PASS"
EOF
printf '[db]\nresource = "director"\n' > "$ETC/modules/director/config.ini"
cat > "$ETC/modules/director/kickstart.ini" <<EOF
[config]
endpoint = "$ICINGA_FQDN"
host = "127.0.0.1"
port = "5665"
username = "root"
password = "$API_ROOT_PASS"
EOF
chgrp -R icingaweb2 "$ETC"; find "$ETC" -type d -exec chmod 2770 {} +; find "$ETC" -type f -exec chmod 660 {} +

# schema e utente amministratore di Icinga Web
if [[ $(psql_user icingaweb2 icingaweb2 "$DB_WEB_PASS" -tAc "SELECT to_regclass('public.icingaweb_user') IS NOT NULL") != t ]]; then
  psql_user icingaweb2 icingaweb2 "$DB_WEB_PASS" -f /usr/share/icingaweb2/schema/pgsql.schema.sql >>"$LOG_FILE" 2>&1
  ok "schema icingaweb2 importato"
fi
pw_hash=$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$WEB_ADMIN_PASS")
psql_user icingaweb2 icingaweb2 "$DB_WEB_PASS" -v u="$WEB_ADMIN_USER" -v h="$pw_hash" >>"$LOG_FILE" 2>&1 <<'SQL'
UPDATE icingaweb_user SET password_hash = :'h', active = 1, mtime = now() WHERE name = :'u';
INSERT INTO icingaweb_user (name, active, password_hash, ctime)
  SELECT :'u', 1, :'h', now() WHERE NOT EXISTS (SELECT 1 FROM icingaweb_user WHERE name = :'u');
SQL

for m in icingadb director; do icingacli module enable "$m" >>"$LOG_FILE" 2>&1 || true; done

# Apache: configurazione scritta a mano (il modulo "setup" di icingacli non esiste piu' nelle
# versioni recenti, e "icingacli setup" esce comunque con codice 0 stampando solo un errore).
mod_php_conf=$(ls /etc/apache2/mods-available/php*.load 2>/dev/null | head -1 || true)
a2enmod rewrite >>"$LOG_FILE" 2>&1 || true
[[ -n $mod_php_conf ]] && a2enmod "$(basename "$mod_php_conf" .load)" >>"$LOG_FILE" 2>&1 || true
{
  cat > /etc/apache2/conf-available/icingaweb2.conf <<'APACHE'
Alias /icingaweb2 "/usr/share/icingaweb2/public"

<Directory "/usr/share/icingaweb2/public">
    Options SymLinksIfOwnerMatch
    AllowOverride None
    SetEnv ICINGAWEB_CONFIGDIR "/etc/icingaweb2"
    EnableSendfile Off
    Require all granted
    DirectoryIndex index.php
    RewriteEngine on
    RewriteBase /icingaweb2/
    RewriteCond %{REQUEST_FILENAME} -s [OR]
    RewriteCond %{REQUEST_FILENAME} -l [OR]
    RewriteCond %{REQUEST_FILENAME} -d
    RewriteRule ^.*$ - [NC,L]
    RewriteRule ^.*$ index.php [NC,L]
</Directory>
APACHE
}
echo 'RedirectMatch ^/$ /icingaweb2' > /etc/apache2/conf-available/icingaweb2-redirect.conf
a2enmod rewrite >>"$LOG_FILE" 2>&1
a2enconf icingaweb2 icingaweb2-redirect >>"$LOG_FILE" 2>&1
systemctl enable apache2 >>"$LOG_FILE" 2>&1
systemctl restart apache2
ok "Icinga Web 2 configurato"

# --------------------------------------------------------------- Director ----
info "[7/10] Director (migrazione, kickstart, daemon)"
icingacli director migration run >>"$LOG_FILE" 2>&1

# Il kickstart parla con l'API di Icinga 2: l'endpoint deve avere ESATTAMENTE il nome dell'oggetto
# Endpoint di Icinga 2 (NodeName), che non coincide per forza con l'FQDN scelto per l'interfaccia web
# (es. NodeName "icinga" ma FQDN "icinga.lan": con il nome sbagliato il kickstart fallisce e Director
# mostra il wizard "Kickstart" nella UI). Si legge quindi NodeName e si aspetta che l'API risponda.
ICINGA_NODENAME=$(icinga2 variable get NodeName 2>/dev/null || true)
ICINGA_NODENAME=${ICINGA_NODENAME:-$(hostname -f 2>/dev/null || hostname)}
sed -i "s/^endpoint = .*/endpoint = \"$ICINGA_NODENAME\"/" "$ETC/modules/director/kickstart.ini"
for _ in $(seq 1 30); do
  curl -ks -o /dev/null -u "root:$API_ROOT_PASS" https://127.0.0.1:5665/v1/status && break; sleep 2
done
kick_ok=0
for attempt in 1 2 3; do
  if icingacli director kickstart run >>"$LOG_FILE" 2>&1; then kick_ok=1; break; fi
  sleep 5
done
if (( kick_ok )) && [[ $(icingacli director command exists icinga 2>&1) != *"does not exist"* ]]; then
  ok "kickstart eseguito (ITL e oggetti di Icinga 2 importati)"
else
  warn "kickstart non riuscito (vedi $LOG_FILE): endpoint '$ICINGA_NODENAME', API root su 127.0.0.1:5665. Si puo' rifare dalla UI di Director."
fi
if ! getent passwd icingadirector >/dev/null; then
  useradd -r -g icingaweb2 -d /var/lib/icingadirector -s /bin/false icingadirector
fi
install -d -o icingadirector -g icingaweb2 -m 0750 /var/lib/icingadirector
if ! systemctl cat icinga-director.service >/dev/null 2>&1; then
  cp /usr/share/icingaweb2/modules/director/contrib/systemd/icinga-director.service /etc/systemd/system/
  systemctl daemon-reload
fi
systemctl enable --now icinga-director.service >>"$LOG_FILE" 2>&1
ok "Director pronto"

# ----------------------------------------------------------- verifiche ------
info "[8/10] Verifica servizi"
fail=0
for s in postgresql icingadb-redis icinga2 icingadb apache2 icinga-director; do
  [[ $s == postgresql && $PG_LOCAL != 1 ]] && continue
  if systemctl is-active --quiet "$s"; then ok "$s attivo"; else warn "$s NON attivo"; fail=1; fi
done
# La pagina di login risponde 200 oppure 302 (redirect verso se' stessa con ?_checkCookie=1): seguendo
# il redirect senza cookie si ottiene 403, quindi qui il redirect NON si segue.
web_code=000
for _ in 1 2 3 4 5; do
  web_code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/icingaweb2/authentication/login || true)
  [[ $web_code == 200 || $web_code == 302 ]] && break; sleep 2
done
if [[ $web_code == 200 || $web_code == 302 ]]; then ok "interfaccia web raggiungibile (HTTP $web_code)"
else warn "interfaccia web non raggiungibile (HTTP $web_code)"; fail=1; fi
save_creds

# ------------------------------------------------------ template Director ----
info "[9/10] Template Director e plugin (libreria zampat)"
if [[ "${WITH_TEMPLATES:-1}" == 1 ]]; then
  TPL_SCRIPT="$(dirname "$(readlink -f "$0")")/icinga-templates.sh"
  if [[ ! -f $TPL_SCRIPT ]]; then
    TPL_SCRIPT=/tmp/icinga-templates.sh
    curl -fsSL -o "$TPL_SCRIPT" https://raw.githubusercontent.com/NicolaCaragia/icingacarra/main/icinga-templates.sh \
      || warn "icinga-templates.sh non trovato: copialo accanto a runsetup.sh"
  fi
  if [[ -f $TPL_SCRIPT ]]; then
    bash "$TPL_SCRIPT" || warn "template non installati del tutto (vedi /var/log/icinga-templates.log)"
  fi
else
  warn "WITH_TEMPLATES=0: template saltati"
fi

# ------------------------------------------------------------------ tema ------
info "[10/10] Tema icingacarra (logo e sfondo)"
if [[ "${WITH_THEME:-1}" == 1 ]]; then
  THEME_SCRIPT="$(dirname "$(readlink -f "$0")")/icinga-theme.sh"
  if [[ -f $THEME_SCRIPT && -d "$(dirname "$THEME_SCRIPT")/theme" ]]; then
    bash "$THEME_SCRIPT" || warn "tema non installato (vedi i messaggi sopra)"
  else
    warn "icinga-theme.sh o la cartella theme/ non trovati accanto a runsetup.sh: tema saltato"
  fi
else
  warn "WITH_THEME=0: tema saltato"
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<EOF

${c_grn}=====================================================================${c_off}
 Icinga e' installato.
   URL ........ http://${IP:-$ICINGA_FQDN}/icingaweb2
   Utente ..... $WEB_ADMIN_USER
   Password ... $WEB_ADMIN_PASS
 Credenziali complete (DB, API): $CRED_FILE
 Log installazione: $LOG_FILE
${c_grn}=====================================================================${c_off}
EOF
exit $fail
