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
s~INSERT IGNORE\s+(?:INTO\s+)?(.*?);[ \t]*$~INSERT INTO $1 ON CONFLICT DO NOTHING;~gms;
s~'((?:[^'\x5c]|\x5c.|'')*)'|"([^"\n]*)"~defined $1 ? fix($1) : "'$2'"~ge;
print;
PERL

run_sql() { # file
  local out
  out=$(perl "$CONV" <"$1" | psql_dir -1 2>&1) && return 0
  echo "$out" >>"$LOG"; return 1
}

# ----------------------------------------------------- [3] campi dati Director
info "[3/7] Campi dati Director (director_datafield, liste)"
F="$BASE/templates/director_fields/0001-director_datafield.sql"
if run_sql "$F"; then
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
      if run_sql "$f"; then nsql=$((nsql+1)); else nfail=$((nfail+1)); failed+=("$f"); fi ;;
  esac
done
ok "script .sh eseguiti: $nsh, file .sql convertiti: $nsql, falliti: $nfail"
((nfail>0)) && warn "falliti: ${failed[*]}  (dettagli: $LOG)"

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
    if ((rc==0)); then unset 'WHY[$f]'; else next+=("$f"); WHY[$f]="$out"; fi
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
copy_plugin check_interfaces        || warn "check_interfaces non trovato nel repo"
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
if icingacli director config deploy >>"$LOG" 2>&1; then ok "deploy eseguito"
else warn "deploy non riuscito: verificare da UI (Director > Activity log)"; fi

cat <<EOF

${c_grn}=====================================================================${c_off}
 Template installati. Verifica in Director:
   Hosts > Host Templates   |   Services > Service Templates
 Log completo: $LOG
 Plugin mancanti: ${missing[*]:-nessuno}
${c_grn}=====================================================================${c_off}
EOF
