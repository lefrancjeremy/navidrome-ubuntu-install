#!/usr/bin/env bash
#
# install-navidrome.sh — Installation de Navidrome sur Ubuntu/Debian
# Paquet .deb officiel publié sur les releases GitHub, vérifié par SHA256
# contre le fichier checksums.txt signé publié par le projet dans la même release.
#
# Usage :
#   sudo ./install-navidrome.sh
#   sudo ./install-navidrome.sh --music-dir /srv/musique
#   sudo ./install-navidrome.sh --dry-run
#
# Le script est idempotent.
#
# Sécurité : contrairement à Plex, Navidrome ne signe pas ses paquets avec une
# clé GPG. En revanche chaque release GitHub publie un fichier
# navidrome_checksums.txt contenant les SHA256 de tous les binaires. Ce
# script télécharge ce fichier et VÉRIFIE le .deb contre lui avant toute
# installation — c'est un contrôle d'intégrité réel, pas un affichage
# cosmétique. Il s'arrête si le hash ne correspond pas.

set -Eeuo pipefail

MUSIC_DIR="/srv/musique"
CONFIGURE_FIREWALL=1
CREATE_MUSIC_DIR=1
DRY_RUN=0
ND_PORT=4533

GH_LATEST_PAGE="https://github.com/navidrome/navidrome/releases/latest"
TMPDIR_ND=""

if [[ -t 1 ]]; then
  C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_WARN=$'\033[0;33m'
  C_INFO=$'\033[0;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()    { printf '%s [OK]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()   { trap - ERR; printf '%s[ERREUR]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
dry()   { printf '%s[dry-run]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "$*"
  else
    "$@"
  fi
}

cleanup() {
  [[ -n "$TMPDIR_ND" && -d "$TMPDIR_ND" ]] && rm -rf -- "$TMPDIR_ND"
}
trap cleanup EXIT
trap 'die "Échec à la ligne $LINENO (commande : $BASH_COMMAND)"' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --music-dir)     MUSIC_DIR="${2:?chemin manquant après --music-dir}"; shift 2 ;;
    --no-music-dir)  CREATE_MUSIC_DIR=0; shift ;;
    --no-firewall)   CONFIGURE_FIREWALL=0; shift ;;
    -n|--dry-run)    DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Option inconnue : $1 (voir --help)" ;;
  esac
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_WARN" "$C_OFF"
  printf '%s║  MODE SIMULATION — aucune modification ne sera écrite     ║%s\n' "$C_WARN" "$C_OFF"
  printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$C_WARN" "$C_OFF"
fi

info "Vérifications préalables"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  [[ "$DRY_RUN" -eq 1 ]] \
    && warn "Pas root : certaines vérifications (apt) peuvent être limitées." \
    || die "Ce script doit être lancé en root : sudo $0"
fi

[[ -r /etc/os-release ]] || die "/etc/os-release introuvable."
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
  die "Distribution non supportée : ${PRETTY_NAME:-inconnue}."
fi
ok "Système : ${PRETTY_NAME:-$ID $VERSION_ID}"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64|armhf|i386) ok "Architecture : $ARCH" ;;
  *) die "Architecture non supportée par les releases Navidrome : $ARCH" ;;
esac

if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${ND_PORT}\$"; then
  if systemctl is-active --quiet navidrome 2>/dev/null; then
    ok "Le port $ND_PORT est déjà utilisé par un service Navidrome existant."
  else
    die "Le port $ND_PORT est déjà occupé par un autre processus."
  fi
fi

if ! curl -fsSI --max-time 15 "$GH_LATEST_PAGE" >/dev/null; then
  die "Impossible de joindre GitHub — vérifiez DNS / réseau / proxy."
fi
ok "Accès réseau à GitHub confirmé"

info "Installation des dépendances (curl, ffmpeg)"
export DEBIAN_FRONTEND=noninteractive
run apt-get update -qq
run apt-get install -y -qq curl ffmpeg
[[ "$DRY_RUN" -eq 1 ]] || ok "Dépendances en place"

# ----------------------------------------------------------------------------
# Résolution de la dernière version + téléchargement + vérification SHA256
# ----------------------------------------------------------------------------
info "Résolution de la dernière version Navidrome"
TMPDIR_ND="$(mktemp -d)"
chmod 700 "$TMPDIR_ND"

FINAL_URL="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 30 -o /dev/null -w '%{url_effective}' "$GH_LATEST_PAGE")"
ND_TAG="$(basename "$FINAL_URL")"
[[ "$ND_TAG" == v* ]] || die "Impossible de déterminer la dernière version (résolu : '$ND_TAG')."
ND_VERSION="${ND_TAG#v}"
DEB_NAME="navidrome_${ND_VERSION}_linux_${ARCH}.deb"
DEB_URL="https://github.com/navidrome/navidrome/releases/download/${ND_TAG}/${DEB_NAME}"
CHECKSUMS_URL="https://github.com/navidrome/navidrome/releases/download/${ND_TAG}/navidrome_checksums.txt"

ok "Dernière version : $ND_VERSION ($DEB_NAME)"

info "Téléchargement du paquet et du fichier de contrôle"
curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o "$TMPDIR_ND/$DEB_NAME" "$DEB_URL"
curl -fsSL --retry 3 --retry-delay 2 --max-time 30  -o "$TMPDIR_ND/navidrome_checksums.txt" "$CHECKSUMS_URL"

info "Vérification SHA256 contre le fichier officiel de la release"
EXPECTED_SUM="$(grep " ${DEB_NAME}\$" "$TMPDIR_ND/navidrome_checksums.txt" | awk '{print $1}')"
[[ -n "$EXPECTED_SUM" ]] || die "Le fichier $DEB_NAME n'apparaît pas dans navidrome_checksums.txt — release incohérente, installation annulée."

ACTUAL_SUM="$(sha256sum "$TMPDIR_ND/$DEB_NAME" | awk '{print $1}')"
if [[ "$ACTUAL_SUM" != "$EXPECTED_SUM" ]]; then
  die "SHA256 invalide pour $DEB_NAME !
      attendu : $EXPECTED_SUM
      obtenu  : $ACTUAL_SUM
   Fichier corrompu ou altéré — installation annulée par sécurité."
fi
ok "SHA256 vérifié : $ACTUAL_SUM"

# ----------------------------------------------------------------------------
# Installation
# ----------------------------------------------------------------------------
info "Installation du paquet navidrome"
run apt-get install -y "$TMPDIR_ND/$DEB_NAME"

ND_INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' navidrome 2>/dev/null || echo "non installée")"
[[ "$DRY_RUN" -eq 1 ]] || ok "Navidrome installé — version $ND_INSTALLED_VERSION"

# ----------------------------------------------------------------------------
# Bibliothèque musicale
# ----------------------------------------------------------------------------
if [[ "$CREATE_MUSIC_DIR" -eq 1 ]]; then
  info "Préparation du dossier musique : $MUSIC_DIR"
  run install -d -m 0755 "$MUSIC_DIR"

  NAVIDROME_CONF="/etc/navidrome/navidrome.toml"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "écriture de MusicFolder = \"$MUSIC_DIR\" dans $NAVIDROME_CONF"
  else
    install -d -m 0755 /etc/navidrome
    if [[ -f "$NAVIDROME_CONF" ]] && grep -q '^MusicFolder' "$NAVIDROME_CONF"; then
      sed -i "s|^MusicFolder.*|MusicFolder = \"$MUSIC_DIR\"|" "$NAVIDROME_CONF"
    else
      printf 'MusicFolder = "%s"\n' "$MUSIC_DIR" >> "$NAVIDROME_CONF"
    fi
    ok "Configuration écrite : $NAVIDROME_CONF"
  fi

  if id navidrome >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1; then
    parent="$MUSIC_DIR"
    while [[ "$parent" != "/" ]]; do
      run setfacl -m u:navidrome:rx "$parent" 2>/dev/null || true
      parent="$(dirname "$parent")"
    done
    run setfacl -R  -m u:navidrome:rX "$MUSIC_DIR"
    run setfacl -dR -m u:navidrome:rX "$MUSIC_DIR"
    [[ "$DRY_RUN" -eq 1 ]] || ok "ACL en lecture accordées à l'utilisateur navidrome sur $MUSIC_DIR"
  else
    warn "Utilisateur 'navidrome' ou 'setfacl' introuvable — ACL non appliquées."
  fi
fi

# ----------------------------------------------------------------------------
# Service
# ----------------------------------------------------------------------------
info "Activation du service"
run systemctl daemon-reload
run systemctl restart navidrome
run systemctl enable navidrome

READY=0
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "attente du port $ND_PORT (ignorée en simulation)"
else
  info "Attente du démarrage sur le port $ND_PORT…"
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:${ND_PORT}/"; then
      READY=1; break
    fi
    sleep 1
  done
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  :
elif [[ "$READY" -eq 1 ]]; then
  ok "Navidrome répond sur http://127.0.0.1:${ND_PORT}"
else
  warn "Navidrome ne répond pas encore. Diagnostic :
      systemctl status navidrome
      journalctl -u navidrome -n 80 --no-pager"
fi

# ----------------------------------------------------------------------------
# Pare-feu
# ----------------------------------------------------------------------------
if [[ "$CONFIGURE_FIREWALL" -eq 1 ]] && command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "^Status: active"; then
    info "Ouverture du port Navidrome dans UFW"
    run ufw allow "${ND_PORT}/tcp" comment 'Navidrome - acces web'
    ok "Règle UFW appliquée"
  else
    info "UFW présent mais inactif — aucune règle ajoutée."
  fi
fi

# ----------------------------------------------------------------------------
# Récapitulatif
# ----------------------------------------------------------------------------
IP_LAN="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP_LAN="${IP_LAN:-<ip-du-serveur>}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF

────────────────────────────────────────────────────────────────
 ${C_WARN}Simulation terminée — rien n'a été modifié${C_OFF}
────────────────────────────────────────────────────────────────
 Version détectée en ligne : $ND_VERSION
 Le téléchargement, la vérification SHA256 et les vérifications
 système ont été effectués pour de bon.

 Pour lancer l'installation :  sudo $0 ${*:-}
────────────────────────────────────────────────────────────────
EOF
  exit 0
fi

SVC_ACTIVE="$(systemctl is-active navidrome 2>/dev/null || true)"
SVC_ENABLED="$(systemctl is-enabled navidrome 2>/dev/null || true)"

cat <<EOF

────────────────────────────────────────────────────────────────
 ${C_OK}Installation terminée${C_OFF}
────────────────────────────────────────────────────────────────
 Version         : $ND_INSTALLED_VERSION
 Service         : ${SVC_ACTIVE:-inconnu} / ${SVC_ENABLED:-inconnu}
 Port            : $ND_PORT
 Config          : /etc/navidrome/navidrome.toml
 Dossier musique : $([[ "$CREATE_MUSIC_DIR" -eq 1 ]] && echo "$MUSIC_DIR" || echo "non créé (/opt/navidrome/music par défaut)")

 ${C_INFO}Accès${C_OFF}
   Local  : http://127.0.0.1:${ND_PORT}
   Réseau : http://${IP_LAN}:${ND_PORT}

 Le premier compte créé à la connexion devient administrateur —
 connectez-vous tout de suite pour éviter qu'un autre ne le fasse.

 ${C_INFO}Commandes utiles${C_OFF}
   systemctl status navidrome
   journalctl -u navidrome -f
────────────────────────────────────────────────────────────────
EOF
