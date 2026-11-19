#!/usr/bin/env bash
# =============================================================================
# icinga-theme.sh - Installa il tema "IcingaCarra" in Icinga Web 2
#   logo icingacarra (al posto di quello Icinga) + sfondo personalizzato ovunque
#
# Uso (come root, dopo runsetup.sh):
#   sudo ./icinga-theme.sh            # installa e imposta come tema predefinito
#   sudo ./icinga-theme.sh --remove   # toglie il tema e torna a quello di Icinga
#
# Cerca la cartella "theme/" accanto allo script. Lo sfondo e' theme/img/icingacarra/background.jpg:
# se manca si usa uno sfondo segnaposto generato (background-placeholder.svg).
# =============================================================================
set -Eeuo pipefail

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_off=$'\e[0m'
info() { echo "${c_blu}==>${c_off} $*"; }
ok()   { echo "${c_grn} OK${c_off} $*"; }
warn() { echo "${c_ylw}WARN${c_off} $*" >&2; }
die()  { echo "${c_red}ERRORE${c_off} $*" >&2; exit 1; }

THEME_NAME=IcingaCarra
IW2_PUBLIC=${IW2_PUBLIC:-/usr/share/icingaweb2/public}
IW2_CONF=${IW2_CONF:-/etc/icingaweb2/config.ini}
SRC_DIR="$(dirname "$(readlink -f "$0")")/theme"

[[ $EUID -eq 0 ]] || die "eseguire come root (sudo ./icinga-theme.sh)"
[[ -d $IW2_PUBLIC/css/themes ]] || die "Icinga Web 2 non trovato in $IW2_PUBLIC (esegui prima runsetup.sh)"

# set_ini FILE SEZIONE CHIAVE VALORE: imposta chiave = "valore" nella sezione, creandola se serve
set_ini() {
  local file=$1 section=$2 key=$3 value=$4 tmp
  [[ -f $file ]] || : >"$file"
  tmp=$(mktemp)
  awk -v sec="[$section]" -v key="$key" -v val="$value" '
    BEGIN { insec = 0; done = 0 }
    /^\[/ { if (insec && !done) { print key " = \"" val "\""; done = 1 } insec = ($0 == sec) }
    insec && $0 ~ "^" key "[ \t]*=" { print key " = \"" val "\""; done = 1; next }
    { print }
    END { if (insec && !done) { print key " = \"" val "\""; done = 1 }
          if (!done) { print ""; print sec; print key " = \"" val "\"" } }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"; rm -f "$tmp"     # cat > file: mantiene proprietario e permessi
}
del_ini_key() { # FILE SEZIONE CHIAVE
  local file=$1 section=$2 key=$3 tmp; [[ -f $file ]] || return 0
  tmp=$(mktemp)
  awk -v sec="[$section]" -v key="$key" '/^\[/ { insec = ($0 == sec) } !(insec && $0 ~ "^" key "[ \t]*=") { print }' "$file" >"$tmp"
  cat "$tmp" >"$file"; rm -f "$tmp"
}

if [[ ${1:-} == --remove ]]; then
  info "Rimozione del tema $THEME_NAME"
  del_ini_key "$IW2_CONF" themes default
  rm -f "$IW2_PUBLIC/css/themes/$THEME_NAME.less"
  rm -rf "$IW2_PUBLIC/img/icingacarra"
  ok "tema rimosso: Icinga Web 2 usa di nuovo il tema predefinito"
  exit 0
fi

[[ -f $SRC_DIR/IcingaCarra.less ]] || die "cartella theme/ non trovata accanto allo script ($SRC_DIR)"

info "Installazione tema $THEME_NAME"
install -d -m 0755 "$IW2_PUBLIC/img/icingacarra"
install -m 0644 "$SRC_DIR"/img/icingacarra/logo*.svg "$IW2_PUBLIC/img/icingacarra/"

LESS_DST="$IW2_PUBLIC/css/themes/$THEME_NAME.less"
install -m 0644 "$SRC_DIR/IcingaCarra.less" "$LESS_DST"

if [[ -f $SRC_DIR/img/icingacarra/background.jpg ]]; then
  install -m 0644 "$SRC_DIR/img/icingacarra/background.jpg" "$IW2_PUBLIC/img/icingacarra/background.jpg"
  ok "sfondo: background.jpg"
else
  warn "theme/img/icingacarra/background.jpg non trovato: uso lo sfondo segnaposto"
  install -m 0644 "$SRC_DIR/img/icingacarra/background-placeholder.svg" "$IW2_PUBLIC/img/icingacarra/background.svg"
  sed -i "s#icingacarra/background\.jpg#icingacarra/background.svg#" "$LESS_DST"
fi

# Tema predefinito per tutti gli utenti (chi ha scelto un tema nelle proprie preferenze lo mantiene)
set_ini "$IW2_CONF" themes default "$THEME_NAME"
chgrp icingaweb2 "$IW2_CONF" 2>/dev/null || true
chmod 660 "$IW2_CONF" 2>/dev/null || true
ok "tema impostato come predefinito in $IW2_CONF"

echo
echo "Fatto. Ricarica la pagina di Icinga Web 2 (Ctrl+F5)."
echo "Se non cambia: Configurazione > Applicazione > Generale > Tema predefinito = $THEME_NAME,"
echo "e nelle proprie Preferenze scegliere il tema \"$THEME_NAME\"."
