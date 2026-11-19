#!/usr/bin/env bash
# icinga-templates.sh - Installa in Icinga Director (PostgreSQL) la libreria di
# template "alla NetEye" di zampat/icinga2-monitoring-templates + plugin da zampat/neteye4.
#
# Uso (dopo runsetup.sh, come root):   sudo ./icinga-templates.sh
# Rieseguibile: gli script originali controllano se l'oggetto esiste gia'.
#
# Variabili opzionali:
#   DIRECTOR_DB=director     nome database Director
#   WITH_NETEYE=0            1 = importa anche i template specifici NetEye (inutili senza NetEye)
#   BASKET_DIRS="ethernetbox ibm linux microsoft network_traffic oracle sap vmware"   (cartelle di baskets/monitoring_templates)
set -u
DIRECTOR_DB="${DIRECTOR_DB:-director}"
WITH_NETEYE="${WITH_NETEYE:-0}"
BASKET_DIRS="${BASKET_DIRS:-ethernetbox ibm linux microsoft network_traffic oracle sap vmware}"
[[ $WITH_NETEYE == 1 ]] && BASKET_DIRS="$BASKET_DIRS neteye"
BASE=/opt/icinga-templates
LOG=/var/log/icinga-templates.log
PLUGDIR=/usr/lib/nagios/plugins

c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_red=$'\e[31m'; c_blu=$'\e[34m'; c_off=$'\e[0m'
info() { echo "${c_blu}==>${c_off} $*"; }
ok()   { echo "${c_grn} OK${c_off} $*"; }
warn() { echo "${c_ylw}WARN${c_off} $*" >&2; }
die()  { echo "${c_red}ERRORE${c_off} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "eseguire come root (sudo)"
: >"$LOG"
export DEBIAN_FRONTEND=noninteractive

psql_dir() { sudo -u postgres psql -d "$DIRECTOR_DB" -v ON_ERROR_STOP=1 -q "$@"; }

# ------------------------------------------------------------ [1] dipendenze
info "[1/7] Dipendenze"
apt-get update -qq >>"$LOG" 2>&1
apt-get install -y -qq git dos2unix perl curl snmp libnet-snmp-perl \
  libmonitoring-plugin-perl monitoring-plugins >>"$LOG" 2>&1 || warn "alcuni pacchetti base non installati (vedi $LOG)"
apt-get install -y -qq nagios-plugins-contrib >>"$LOG" 2>&1 || warn "nagios-plugins-contrib non disponibile"
icingacli director --help >/dev/null 2>&1 || die "icingacli/Director non disponibile: esegui prima runsetup.sh"
if icingacli director command exists icinga 2>&1 | grep -q "does not exist"; then
  # ITL non ancora importata (kickstart non riuscito o non eseguito): si prova a farlo ora
  warn "ITL non importata: provo ad eseguire il kickstart di Director"
  icingacli director kickstart run >>"$LOG" 2>&1 || true
  icingacli director command exists icinga 2>&1 | grep -q "does not exist" \
    && die "kickstart non riuscito (vedi $LOG): eseguilo dalla UI di Director (Director > Kickstart) e rilancia questo script"
fi
sudo -u postgres psql -d "$DIRECTOR_DB" -c 'select 1' >/dev/null 2>&1 || die "database '$DIRECTOR_DB' non raggiungibile"
ok "prerequisiti"

# ------------------------------------------------------------ [2] repository
info "[2/7] Download repository"
mkdir -p "$BASE"
sync_repo() { # url dir
  if [[ -d $2/.git ]]; then git -C "$2" pull -q --ff-only >>"$LOG" 2>&1 || warn "pull fallito per $2"
  else git clone -q --depth 1 "$1" "$2" >>"$LOG" 2>&1 || die "clone fallito: $1"; fi
}
sync_repo https://github.com/zampat/icinga2-monitoring-templates.git "$BASE/templates"
sync_repo https://github.com/zampat/neteye4.git                      "$BASE/neteye4"
sync_repo https://github.com/Napsty/check_esxi_hardware.git          "$BASE/check_esxi_hardware"
ok "repository in $BASE"

# --------------------------------------------- convertitore SQL MariaDB -> PG
CONV=$BASE/sql2pg.pl
cat >"$CONV" <<'PERL'
undef $/; $_ = <STDIN>;
my $B = "\x5c";
s/\r//g;
sub fix {
  my $s = shift;
  $s =~ s/\x5c(.)/$1 eq "'" ? "''" : ($1 eq $B ? $B : ($1 eq '"' ? '"' : $B.$1))/gse;
  return "'".$s."'";
}
s~/\*!.*?\*/;?[ \t]*\n~~gs;
s~^[ \t]*(?:LOCK|UNLOCK) TABLES[^\n]*\n~~gmi;
s~^[ \t]*ALTER TABLE [^\n]*AUTO_INCREMENT[^\n]*\n~~gmi;
s~`director`\.~~g;
s~`~~g;
s~^[ \t]*(?:--|\#)[^\n]*\n~~gm;
# Le tabelle director_datafield e director_datalist, in PostgreSQL, hanno una colonna "uuid" (bytea,
# 16 byte, NOT NULL) che il dump MariaDB non conosce: si inseriscono prima in una tabella
# d'appoggio e poi si copiano nella tabella vera con un uuid stabile ricavato dal nome (md5 = 16 byte).
s~INSERT IGNORE\s+(?:INTO\s+)?director_datafield\s*\(([^)]*)\)\s*VALUES(.*?);[ \t]*$~CREATE TEMP TABLE IF NOT EXISTS stg_datafield AS SELECT id, varname, caption, description, datatype, format FROM director_datafield WHERE false;\nINSERT INTO stg_datafield ($1) VALUES$2;\nINSERT INTO director_datafield (id, uuid, varname, caption, description, datatype, format) SELECT id, decode(md5('datafield:' || varname), 'hex'), varname, caption, description, datatype, format FROM stg_datafield ON CONFLICT DO NOTHING;\nTRUNCATE stg_datafield;~gms;
s~INSERT IGNORE\s+(?:INTO\s+)?director_datalist\s*\(([^)]*)\)\s*VALUES(.*?);[ \t]*$~CREATE TEMP TABLE IF NOT EXISTS stg_datalist AS SELECT id, list_name, owner FROM director_datalist WHERE false;\nINSERT INTO stg_datalist ($1) VALUES$2;\nINSERT INTO director_datalist (id, uuid, list_name, owner) SELECT id, decode(md5('datalist:' || list_name), 'hex'), list_name, owner FROM stg_datalist ON CONFLICT DO NOTHING;\nTRUNCATE stg_datalist;~gms;
s~INSERT IGNORE\s+(?:INTO\s+)?(.*?);[ \t]*$~INSERT INTO $1 ON CONFLICT DO NOTHING;~gms;
s~'((?:[^'\x5c]|\x5c.|'')*)'|"([^"\n]*)"~defined $1 ? fix($1) : "'$2'"~ge;
print;
PERL

run_sql() { # file  -> importazione atomica (tutto o niente), per i campi dati
  local out
  out=$(perl "$CONV" <"$1" | psql_dir -1 2>&1) && return 0
  echo "$out" >>"$LOG"; return 1
}
SKIPPED_ROWS=0
# Importazione tollerante, per i file "template -> campo": ogni istruzione e' indipendente, e quelle che
# puntano a campi/template/comandi che nella libreria originale non esistono (incoerenze del repo di
# origine) vengono saltate e contate invece di far fallire tutto il file. Rieseguibile (ON CONFLICT).
run_sql_lenient() { # file
  local out n
  out=$(perl "$CONV" <"$1" | sudo -u postgres psql -d "$DIRECTOR_DB" -X -q -v ON_ERROR_STOP=0 2>&1) || true
  n=$(grep -c '^ERROR:' <<<"$out" || true)
  if ((n>0)); then echo "$out" >>"$LOG"; SKIPPED_ROWS=$((SKIPPED_ROWS+n)); fi
  return 0
}

# ----------------------------------------------------- [3] campi dati Director
info "[3/7] Campi dati Director (director_datafield, liste)"
F="$BASE/templates/director_fields/0001-director_datafield.sql"
# Gia' importati in una esecuzione precedente (marcatore: lista 50 "Host Service" e campo "host_os")?
if [[ $(psql_dir -tAc "SELECT count(*) FROM director_datalist l, director_datafield f WHERE l.id = 50 AND l.list_name = 'Host Service' AND f.varname = 'host_os'" 2>/dev/null) == 1 ]]; then
  ok "campi dati gia' presenti: salto l'importazione"
elif run_sql "$F"; then
  psql_dir -c "SELECT setval(pg_get_serial_sequence('director_datafield','id'), GREATEST((SELECT COALESCE(max(id),0) FROM director_datafield),10001));" >/dev/null 2>&1
  psql_dir -c "SELECT setval(pg_get_serial_sequence('director_datalist','id'), GREATEST((SELECT COALESCE(max(id),0) FROM director_datalist),10001));" >/dev/null 2>&1
  ok "campi dati importati"
else
  warn "import campi dati fallito (dettagli in $LOG): i template funzioneranno senza campi personalizzati"
fi

# --------------------------------------------- [4] comandi/template (.sh/.sql)
info "[4/7] Comandi, template host/servizio, notifiche (puo' richiedere qualche minuto)"
cd "$BASE/templates/icinga_objects" || die "cartella icinga_objects mancante"
nsh=0; nsql=0; nfail=0; failed=()
for f in $(ls | sort); do
  [[ $WITH_NETEYE == 1 ]] || { [[ $f == 1001* ]] && continue; }
  case $f in
    *.sh)
      dos2unix -q "$f" 2>/dev/null
      echo "=== $f" >>"$LOG"
      if bash "$f" >>"$LOG" 2>&1; then nsh=$((nsh+1)); else nfail=$((nfail+1)); failed+=("$f"); fi ;;
    *.sql)
      echo "=== $f" >>"$LOG"
      run_sql_lenient "$f"; nsql=$((nsql+1)) ;;
  esac
done
ok "script .sh eseguiti: $nsh, file .sql applicati: $nsql, falliti: $nfail"
((nfail>0)) && warn "falliti: ${failed[*]}  (dettagli: $LOG)"
SQL_FILES=(); for f in $(ls | sort); do
  [[ $f == *.sql ]] || continue; [[ $WITH_NETEYE == 1 || $f != 1001* ]] && SQL_FILES+=("$PWD/$f"); done

# ------------------------------------------------------------- [5] basket
info "[5/7] Basket Director ($BASKET_DIRS)"
cd "$BASE/templates/baskets/monitoring_templates" || die "cartella baskets mancante"

# Un vero basket di Director e' un JSON con almeno una di queste sezioni (nella cartella ci sono
# anche file che non lo sono, per esempio dashboard Grafana: vanno saltati).
is_director_basket() {
  perl -MJSON::PP -e 'local $/; my $j = eval { decode_json(<STDIN>) }; exit 1 unless ref $j eq "HASH";
    exit((grep { exists $j->{$_} } qw(Command ExternalCommand HostTemplate ServiceTemplate ServiceSet Datafield DataList)) ? 0 : 1)' <"$1"
}
BFILES=(); declare -A SEEN_SUM; SKIPPED=()
while IFS= read -r f; do
  if ! is_director_basket "$f"; then SKIPPED+=("$f (non e' un basket Director)"); continue; fi
  sum=$(sha256sum "$f" | cut -d' ' -f1)
  if [[ -n ${SEEN_SUM[$sum]:-} ]]; then SKIPPED+=("$f (identico a ${SEEN_SUM[$sum]})"); continue; fi
  SEEN_SUM[$sum]=$f; BFILES+=("$f")
done < <(for d in $BASKET_DIRS; do [[ -d $d ]] && find "$d" -type f -name '*.json'; done | sort)
((${#SKIPPED[@]}>0)) && printf '     saltato: %s\n' "${SKIPPED[@]}" | tee -a "$LOG" >/dev/null

# Piu' passate: un basket puo' dipendere da oggetti di un altro (ordine alfabetico non garantisce nulla).
pending=("${BFILES[@]}"); declare -A WHY
for pass in 1 2 3 4; do
  next=()
  for f in "${pending[@]}"; do
    echo "=== basket pass $pass: $f" >>"$LOG"
    out=$(icingacli director basket restore <"$f" 2>&1); rc=$?
    echo "$out" >>"$LOG"
    if ((rc==0)); then unset 'WHY[$f]'; else
      next+=("$f"); WHY[$f]="$out"
      # Alcuni basket assegnano host/servizi a gruppi che non vengono definiti da nessuna parte
      # (es. "linux servers", "tsm-server"): si creano al volo e il basket si riprova alla passata dopo.
      while IFS= read -r g; do
        [[ -n $g ]] || continue
        for kind in hostgroup servicegroup; do
          icingacli director "$kind" exists "$g" 2>&1 | grep -q "does not exist" \
            && icingacli director "$kind" create --json "{\"object_name\":\"$g\",\"object_type\":\"object\"}" >>"$LOG" 2>&1
        done
        echo "     creato il gruppo mancante '$g'" | tee -a "$LOG" >/dev/null
      done < <(sed -n 's/.*The group "\([^"]*\)" doesn.t exist.*/\1/p' <<<"$out" | sort -u)
    fi
  done
  pending=("${next[@]}")
  ((${#pending[@]}==0)) && break
done
ok "basket importati: $(( ${#BFILES[@]} - ${#pending[@]} )) / ${#BFILES[@]}"
MISSING_CMDS=()
if ((${#pending[@]}>0)); then
  warn "basket non importati:"
  for f in "${pending[@]}"; do
    cmd=$(sed -n 's/.*check_command: \([^)]*\)).*/\1/p' <<<"${WHY[$f]}" | head -1)
    tpl=$(sed -n "s/.*object_name = '\([^']*\)' AND object_type = 'template'.*/\1/p" <<<"${WHY[$f]}" | head -1)
    if [[ -n $cmd ]]; then reason="manca il comando '$cmd'"; MISSING_CMDS+=("$cmd")
    elif [[ -n $tpl ]]; then reason="manca il template '$tpl'"
    else reason=$(grep -m1 ERROR <<<"${WHY[$f]}" | cut -c1-140); fi
    echo "     - $f: $reason" >&2
  done
  ((${#MISSING_CMDS[@]}>0)) && warn "comandi da definire in Director (e relativi plugin da installare): $(printf '%s\n' "${MISSING_CMDS[@]}" | sort -u | tr '\n' ' ')"
fi

# Seconda passata sui collegamenti template-campo: i basket hanno creato campi che nella prima passata
# non esistevano ancora (l'operazione e' rieseguibile, ON CONFLICT DO NOTHING).
SKIPPED_ROWS=0
for f in "${SQL_FILES[@]}"; do echo "=== (2a passata) $f" >>"$LOG"; run_sql_lenient "$f"; done
((SKIPPED_ROWS>0)) && warn "$SKIPPED_ROWS collegamenti template-campo saltati perche' puntano a oggetti inesistenti nella libreria originale (dettagli: $LOG)"

# ------------------------------------------------------------- [6] plugin
info "[6/7] Plugin"
install -d "$PLUGDIR"
N4="$BASE/neteye4/monitoring/monitoring-plugins"
copy_plugin() { # nome
  local src; src=$(find "$N4" "$BASE/check_esxi_hardware" -type f -name "$1" 2>/dev/null | head -1)
  if [[ -n $src ]]; then install -m 0755 "$src" "$PLUGDIR/$1" && return 0; fi
  return 1
}
copy_plugin check_mem.pl            || warn "check_mem.pl non trovato nel repo"
copy_plugin check_interfaces        || warn "check_interfaces: il repo contiene solo binari per RHEL/CentOS (non usabili su Debian): va compilato o installato a mano"
copy_plugin check_interface_table_v3t.pl || true
[[ -f $BASE/check_esxi_hardware/check_esxi_hardware.py ]] && install -m 0755 "$BASE/check_esxi_hardware/check_esxi_hardware.py" "$PLUGDIR/check_esxi_hardware"
missing=()
for p in check_vmware_api check_interface_table_v3t.pl check_nwc_health check_interfaces check_mem.pl check_esxi_hardware; do
  [[ -x $PLUGDIR/$p || -x $PLUGDIR/$p.pl ]] || missing+=("$p")
done
grep -qE '^const PluginContribDir' /etc/icinga2/constants.conf 2>/dev/null \
  || echo "const PluginContribDir = \"$PLUGDIR\"" >>/etc/icinga2/constants.conf
((${#missing[@]}>0)) && warn "plugin ancora da installare a mano: ${missing[*]}" || ok "plugin presenti"

# ----------------------------------------------------------- [7] deploy
info "[7/7] Deploy configurazione"
# La libreria di template definisce oggetti che Icinga 2 ha gia' nella sua configurazione predefinita
# (conf.d: generic-service, generic-host, periodi di tempo, utenti, comandi di notifica...). Con
# entrambe attive Icinga 2 rifiuta la configurazione ("Object 'generic-service' of type 'Service'
# re-defined") e dopo il deploy non riparte. Come consiglia la documentazione di Director, conf.d
# si disattiva e gli oggetti li gestisce Director; si tengono solo gli utenti API (api-users.conf).
ICINGA2_CONF=/etc/icinga2/icinga2.conf
if grep -q '^include_recursive "conf.d"' "$ICINGA2_CONF"; then
  cp -n "$ICINGA2_CONF" "$ICINGA2_CONF.icingacarra.bak"
  sed -i 's|^include_recursive "conf.d"|// conf.d disattivato da icinga-templates.sh: gli oggetti li gestisce Director\n// include_recursive "conf.d"\ninclude "conf.d/api-users.conf"|' "$ICINGA2_CONF"
  if icinga2 daemon -C >>"$LOG" 2>&1; then systemctl restart icinga2
  else warn "icinga2.conf non valido dopo la modifica: ripristino il backup"; cp "$ICINGA2_CONF.icingacarra.bak" "$ICINGA2_CONF"; fi
  ok "configurazione predefinita (conf.d) disattivata: backup in $ICINGA2_CONF.icingacarra.bak"
fi
# Il server stesso non e' piu' monitorato dalla configurazione predefinita (conf.d): lo si ricrea in
# Director, con gli stessi controlli che Icinga 2 aveva di serie (conf.d/hosts.conf e services.conf):
# ping4, ping6, ssh, http, disk, "disk /", load, procs, swap, users, apt e icinga.
NODE=$(icinga2 variable get NodeName 2>/dev/null || true)
if [[ -n $NODE ]]; then
  if icingacli director host exists "$NODE" 2>&1 | grep -q "does not exist"; then
    icingacli director host create --json "{\"object_name\":\"$NODE\",\"object_type\":\"object\",\"address\":\"127.0.0.1\",\"address6\":\"::1\",\"imports\":[\"generic-host\"],\"vars\":{\"os\":\"Linux\"}}" >>"$LOG" 2>&1 \
      && echo "     host '$NODE' creato in Director (monitora il server stesso)" || true
  elif ! icingacli director host show "$NODE" --json 2>/dev/null | grep -q '"address6"'; then
    # host gia' esistente (esecuzione precedente) ma senza address6: ping6 non avrebbe l'indirizzo
    icingacli director host set "$NODE" --address6 "::1" >>"$LOG" 2>&1 || true
  fi
  LOCAL_NEW=0; LOCAL_FAIL=0; LOCAL_ERR=""
  add_local_check() { # nome comando [attributi JSON aggiuntivi]
    local out
    if out=$(icingacli director service create --json "{\"object_name\":\"$1\",\"object_type\":\"object\",\"host\":\"$NODE\",\"imports\":[\"generic-service\"],\"check_command\":\"$2\"${3:+,$3}}" 2>&1); then
      LOCAL_NEW=$((LOCAL_NEW+1))
    elif grep -q "DuplicateKeyException" <<<"$out"; then :     # gia' presente da una esecuzione precedente
    else
      LOCAL_FAIL=$((LOCAL_FAIL+1)); echo "controllo '$1': $out" >>"$LOG"
      [[ -n $LOCAL_ERR ]] || LOCAL_ERR="'$1': $(grep -m1 ERROR <<<"$out" | sed 's/.*with message: //' | cut -c1-200)"
    fi
  }
  add_local_check ping4 ping4
  add_local_check ping6 ping6
  add_local_check ssh   ssh
  add_local_check http  http '"vars":{"http_uri":"/"}'
  add_local_check disk  disk
  add_local_check "disk /" disk '"vars":{"disk_partitions":"/"}'
  add_local_check load  load
  add_local_check procs procs
  add_local_check swap  swap
  add_local_check users users
  add_local_check apt   apt '"check_interval":"3600"'
  add_local_check icinga icinga '"check_interval":"60"'
  if ((LOCAL_FAIL>0)); then
    warn "controlli del server '$NODE': $LOCAL_FAIL non creati. Primo errore: $LOCAL_ERR"
  else
    ok "controlli del server '$NODE' in Director (nuovi: $LOCAL_NEW, gia' presenti: $((12-LOCAL_NEW)))"
  fi
fi
# Bug di Director su PostgreSQL: se il pacchetto "director" non ha ancora nessuno stage attivo (primo
# deploy in assoluto) il deploy fallisce con "bind message supplies 0 parameters". Si crea quindi
# prima uno stage iniziale vuoto tramite l'API di Icinga 2 e si aspetta che diventi attivo.
CRED_FILE=${CRED_FILE:-/root/icinga-credentials.txt}
if [[ -r $CRED_FILE ]]; then
  # shellcheck disable=SC1090
  API_ROOT_PASS=$(. "$CRED_FILE"; echo "${API_ROOT_PASS:-}")
  api() { curl -ks -u "root:$API_ROOT_PASS" -H 'Accept: application/json' "$@"; }
  if api https://127.0.0.1:5665/v1/config/packages | grep -Eq '"active-stage":"","name":"director"'; then
    echo "stage iniziale del pacchetto director" >>"$LOG"
    api -X POST https://127.0.0.1:5665/v1/config/stages/director \
      -d '{"files":{"zones.d/director-global/icingacarra-init.conf":"// stage iniziale (evita il bug del primo deploy su PostgreSQL)\n"}}' >>"$LOG" 2>&1 || true
    for _ in $(seq 1 30); do
      api https://127.0.0.1:5665/v1/config/packages | grep -Eq '"active-stage":"","name":"director"' || break; sleep 2
    done
  fi
else
  warn "$CRED_FILE non leggibile: salto la preparazione dello stage iniziale"
fi
deployed=0
for attempt in 1 2 3 4; do
  if icingacli director config deploy >>"$LOG" 2>&1; then deployed=1; break; fi
  sleep 8     # "ongoing package update in progress": si riprova
done
if ((deployed)); then
  # Il deploy "riuscito" significa solo che la configurazione e' stata caricata: si controlla anche
  # che Icinga 2 l'abbia accettata e sia ripartito (startup_succeeded nel registro di Director).
  res=""
  for _ in $(seq 1 45); do
    res=$(psql_dir -tAc "SELECT COALESCE(startup_succeeded::text,'') FROM director_deployment_log ORDER BY id DESC LIMIT 1" 2>/dev/null | tr -d '[:space:]')
    [[ $res == y || $res == n ]] && break; sleep 2
  done
  if [[ $res == y ]]; then ok "deploy eseguito e accettato da Icinga 2"
  elif [[ $res == n ]]; then
    warn "configurazione caricata ma Icinga 2 l'ha RIFIUTATA all'avvio:"
    psql_dir -tAc "SELECT startup_log FROM director_deployment_log ORDER BY id DESC LIMIT 1" 2>/dev/null | grep -i "critical\|error" | head -5 | cut -c1-240 >&2
  else warn "deploy caricato, esito dell'avvio di Icinga 2 non ancora noto: controlla in Director > Activity log"; fi
else warn "deploy non riuscito: verificare da UI (Director > Activity log) o in $LOG"; fi

cat <<EOF

${c_grn}=====================================================================${c_off}
 Template installati. Verifica in Director:
   Hosts > Host Templates   |   Services > Service Templates
 Log completo: $LOG
 Plugin mancanti: ${missing[*]:-nessuno}
${c_grn}=====================================================================${c_off}
EOF
