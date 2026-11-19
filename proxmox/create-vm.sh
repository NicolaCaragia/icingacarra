#!/usr/bin/env bash
# =============================================================================
# proxmox/create-vm.sh - Crea su Proxmox VE una VM Debian 12 pronta per runsetup.sh
#
# Da eseguire come root SULL'HOST PROXMOX (non nella VM):
#   ./create-vm.sh                      # chiede i valori (Invio = predefinito)
#   ./create-vm.sh --yes                # nessuna domanda, usa variabili d'ambiente/predefiniti
#
# Variabili (tutte facoltative):
#   VMID=120  VM_NAME=icinga  STORAGE=local-lvm  BRIDGE=vmbr0
#   IP=10.0.0.50/24 GW=10.0.0.1   (senza IP: DHCP)   DNS="1.1.1.1 8.8.8.8"
#   MEMORY=4096  CORES=2  DISK=20G
#   CI_USER=debian  CI_PASS=...    (senza password: ne viene generata una)
#   SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub   (se indicato, aggiunge anche la chiave)
#   SNIPPET_STORAGE=local   IMG_DIR=/var/lib/vz/template/iso
#
# Perche' serve: le immagini cloud Debian disabilitano il login SSH con password e non hanno una
# password per l'utente. Qui un file cloud-init (snippet) imposta utente, password, login SSH a
# password e installa git e qemu-guest-agent al primo avvio.
# =============================================================================
set -Eeuo pipefail

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_off=$'\e[0m'
info() { echo "${c_blu}==>${c_off} $*"; }
ok()   { echo "${c_grn} OK${c_off} $*"; }
warn() { echo "${c_ylw}WARN${c_off} $*" >&2; }
die()  { echo "${c_red}ERRORE${c_off} $*" >&2; exit 1; }
trap 'die "fallito alla riga $LINENO (comando: $BASH_COMMAND)"' ERR

ASSUME_YES=0
for a in "$@"; do
  case $a in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "opzione sconosciuta: $a" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "eseguire come root sull'host Proxmox"
command -v qm >/dev/null && command -v pvesm >/dev/null || die "qm/pvesm non trovati: questo script va eseguito sull'host Proxmox VE"

ask() { # ask VAR "Domanda" "default"
  local var=$1 prompt=$2 def=${3:-} cur=${!1:-} ans
  [[ -n $cur ]] && def=$cur
  if (( ASSUME_YES )); then printf -v "$var" '%s' "$def"; return; fi
  read -r -p "$prompt [$def]: " ans || true
  printf -v "$var" '%s' "${ans:-$def}"
}

# ------------------------------------------------------------------ valori ----
next_id=$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"' || echo 120)
# storage per i dischi VM: il primo che accetta immagini (preferisce lvmthin/zfs/dir)
default_storage=$(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
echo
echo "${c_blu}=== Configurazione VM (Invio = valore predefinito) ===${c_off}"
ask VMID     "ID della VM"                                  "$next_id"
ask VM_NAME  "Nome della VM"                                "icinga"
ask STORAGE  "Storage per il disco (pvesm status)"          "${default_storage:-local-lvm}"
ask BRIDGE   "Bridge di rete"                               "vmbr0"
ask IP       "IP con prefisso (es. 10.0.0.50/24; vuoto = DHCP)" ""
if [[ -n $IP ]]; then ask GW "Gateway" ""; [[ -n ${GW:-} ]] || die "con IP statico serve il gateway"; fi
ask DNS      "Server DNS (separati da spazio)"              "1.1.1.1 8.8.8.8"
ask MEMORY   "RAM in MB"                                    "4096"
ask CORES    "Core CPU"                                     "2"
ask DISK     "Dimensione disco"                             "20G"
ask CI_USER  "Utente della VM"                              "debian"
SNIPPET_STORAGE=${SNIPPET_STORAGE:-local}
IMG_DIR=${IMG_DIR:-/var/lib/vz/template/iso}
GW=${GW:-}
if [[ -z ${CI_PASS:-} ]]; then CI_PASS=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-14); GEN_PASS=1; else GEN_PASS=0; fi

qm status "$VMID" >/dev/null 2>&1 && die "la VM $VMID esiste gia' (per rifarla: qm stop $VMID; qm destroy $VMID --purge)"
pvesm status 2>/dev/null | awk -v s="$STORAGE" 'NR>1 && $1==s {f=1} END {exit !f}' || die "storage '$STORAGE' non esiste (vedi: pvesm status)"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge '$BRIDGE' non esiste"

echo
echo "Riepilogo: VM $VMID '$VM_NAME', ${CORES} core, ${MEMORY} MB, disco $DISK su $STORAGE, rete $BRIDGE,"
echo "           $([[ -n $IP ]] && echo "IP $IP gw $GW" || echo "DHCP"), DNS $DNS, utente $CI_USER"
if (( ! ASSUME_YES )); then read -r -p "Creare la VM? [S/n]: " a || true; [[ ${a:-s} =~ ^[sSyY] ]] || die "annullato"; fi

# ---------------------------------------------------------------- immagine ----
info "[1/5] Immagine Debian 12 cloud"
IMG="$IMG_DIR/debian-12-genericcloud-amd64.qcow2"
mkdir -p "$IMG_DIR"
if [[ ! -s $IMG ]]; then
  curl -fL --retry 3 -o "$IMG.part" https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
  mv "$IMG.part" "$IMG"
fi
ok "$IMG"

# ----------------------------------------------------------- snippet cloud-init
info "[2/5] File cloud-init (snippet)"
snip_path=$(pvesm path "$SNIPPET_STORAGE:snippets/x" 2>/dev/null | sed 's#/x$##' || true)
if ! pvesm status --content snippets 2>/dev/null | awk -v s="$SNIPPET_STORAGE" 'NR>1 && $1==s {f=1} END {exit !f}'; then
  warn "lo storage '$SNIPPET_STORAGE' non ha il tipo di contenuto 'Snippets'"
  cur=$(awk -v s="$SNIPPET_STORAGE" '$0 ~ "^[a-z]+: "s"$" {f=1; next} /^[a-z]+: / {f=0} f && $1=="content" {print $2}' /etc/pve/storage.cfg)
  if (( ASSUME_YES )) || { read -r -p "Abilitarlo ora (pvesm set $SNIPPET_STORAGE --content ${cur:+$cur,}snippets)? [S/n]: " a && [[ ${a:-s} =~ ^[sSyY] ]]; }; then
    pvesm set "$SNIPPET_STORAGE" --content "${cur:+$cur,}snippets"
  else
    die "senza snippets non si puo' impostare la password: abilitali da Datacenter > Storage > $SNIPPET_STORAGE > Contenuti"
  fi
  snip_path=$(pvesm path "$SNIPPET_STORAGE:snippets/x" | sed 's#/x$##')
fi
mkdir -p "$snip_path"
SNIP_NAME="icinga-vm-$VMID.yaml"
umask 077
{
  cat <<EOF
#cloud-config
hostname: $VM_NAME
ssh_pwauth: true
users:
  - name: $CI_USER
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
EOF
  if [[ -n ${SSH_PUBKEY_FILE:-} && -f ${SSH_PUBKEY_FILE/#\~/$HOME} ]]; then
    echo "    ssh_authorized_keys:"; echo "      - $(cat "${SSH_PUBKEY_FILE/#\~/$HOME}")"
  fi
  cat <<EOF
chpasswd:
  expire: false
  users:
    - {name: $CI_USER, password: "$CI_PASS", type: text}
package_update: true
packages: [qemu-guest-agent, git, curl]
runcmd:
  - sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf
  - systemctl restart ssh
  - systemctl enable --now qemu-guest-agent
EOF
} > "$snip_path/$SNIP_NAME"
chmod 600 "$snip_path/$SNIP_NAME"
ok "$snip_path/$SNIP_NAME (contiene la password in chiaro: permessi 600)"

# ---------------------------------------------------------------------- VM ----
info "[3/5] Creazione VM $VMID"
qm create "$VMID" --name "$VM_NAME" --memory "$MEMORY" --cores "$CORES" --cpu host \
  --net0 "virtio,bridge=$BRIDGE" --ostype l26 --agent enabled=1 \
  --scsihw virtio-scsi-pci --serial0 socket --vga serial0 >/dev/null

info "[4/5] Disco e cloud-init"
if ! qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMG,discard=on" >/dev/null 2>&1; then
  # Proxmox piu' vecchi (< 7.4): importdisk e poi collegamento del disco "unused"
  qm importdisk "$VMID" "$IMG" "$STORAGE" >/dev/null
  disk=$(qm config "$VMID" | awk -F': ' '/^unused0:/ {print $2}')
  [[ -n $disk ]] || die "disco importato non trovato (qm config $VMID)"
  qm set "$VMID" --scsi0 "$disk,discard=on" >/dev/null
fi
qm resize "$VMID" scsi0 "$DISK" >/dev/null
qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 >/dev/null
qm set "$VMID" --cicustom "user=$SNIPPET_STORAGE:snippets/$SNIP_NAME" --nameserver "$DNS" >/dev/null
if [[ -n $IP ]]; then qm set "$VMID" --ipconfig0 "ip=$IP,gw=$GW" >/dev/null; else qm set "$VMID" --ipconfig0 ip=dhcp >/dev/null; fi

info "[5/5] Avvio"
qm start "$VMID"
ok "VM $VMID avviata"

addr=${IP%/*}
echo
echo "${c_grn}=====================================================================${c_off}"
echo " VM pronta (il primo avvio richiede 1-2 minuti: aggiornamenti e pacchetti)."
echo "   Accesso SSH ..... ssh $CI_USER@${addr:-<IP della VM>}"
echo "   Password ........ $CI_PASS$([[ $GEN_PASS == 1 ]] && echo '   (generata: annotala)')"
[[ -z $IP ]] && echo "   IP (DHCP) ....... qm guest cmd $VMID network-get-interfaces   (dopo 1-2 minuti)"
echo
echo " Poi, nella VM:"
echo "   git clone https://github.com/NicolaCaragia/icingacarra.git icinga-pgsql"
echo "   cd icinga-pgsql && sudo ./runsetup.sh"
echo "${c_grn}=====================================================================${c_off}"
