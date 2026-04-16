#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  GEMMA 4 — Setup automatique pour Termux (OnePlus 7T)
#  Usage : bash setup_local_ai_android.sh [--start]
# ============================================================

set -e

# --- Couleurs ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

INSTALL_DIR="$HOME/gemma4"
MODEL_FILE="gemma-4-e2b-it-Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/bartowski/gemma-4-e2b-it-GGUF/resolve/main/${MODEL_FILE}"
# SHA256 du modèle — trouve-le sur la page HuggingFace du modèle (onglet "Files").
# Laisse vide pour désactiver la vérification.
MODEL_SHA256=""
BOOT_SCRIPT="$HOME/.termux/boot/start-gemma.sh"
LOG_FILE="$HOME/gemma4-server.log"
PORT=8080
BOOT_AVAILABLE=false

# ============================================================
print_banner() {
cat << 'EOF'
  ____                                _  _
 / ___| ___ _ __ ___  _ __ ___   __ _| || |
| |  _ / _ \ '_ ` _ \| '_ ` _ \ / _` | || |_
| |_| |  __/ | | | | | | | | | | (_| |__   _|
 \____|\___|_| |_| |_|_| |_| |_|\__,_|  |_|

  Setup automatique — OnePlus 7T / Termux
EOF
}

log()     { echo -e "${CYAN}[INFO]${RESET}  $1"; }
success() { echo -e "${GREEN}[OK]${RESET}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $1"; }
error()   { echo -e "${RED}[ERR]${RESET}   $1"; exit 1; }
step()    { echo -e "\n${BOLD}${GREEN}▶ $1${RESET}"; }

# ============================================================
# ÉTAPE 0 — Vérifications
# ============================================================
check_termux() {
  step "Vérification de l'environnement"
  if [ ! -d "/data/data/com.termux" ]; then
    error "Ce script doit être exécuté dans Termux !"
  fi
  success "Termux détecté"

  if [ ! -d "/data/data/com.termux.boot" ]; then
    warn "Termux:Boot n'est pas installé. Le démarrage automatique ne fonctionnera pas."
    warn "Installe Termux:Boot depuis F-Droid, puis relance ce script."
    BOOT_AVAILABLE=false
  else
    success "Termux:Boot détecté"
    BOOT_AVAILABLE=true
  fi
}

# ============================================================
# ÉTAPE 1 — Mise à jour et paquets
# ============================================================
install_packages() {
  step "Installation des dépendances"
  log "Mise à jour des paquets..."
  pkg update -y && pkg upgrade -y

  log "Installation de : git cmake clang wget python make..."
  pkg install -y git cmake clang wget python make

  success "Dépendances installées"
}

# ============================================================
# ÉTAPE 2 — Compiler llama.cpp
# ============================================================
build_llamacpp() {
  step "Compilation de llama.cpp"

  if [ -f "$INSTALL_DIR/llama.cpp/build/bin/llama-server" ]; then
    warn "llama-server déjà compilé, on passe cette étape."
    warn "Pour forcer la recompilation : rm -rf $INSTALL_DIR/llama.cpp/build et relancer."
    return
  fi

  mkdir -p "$INSTALL_DIR"

  # Subshell pour isoler les cd du reste du script
  (
    cd "$INSTALL_DIR"

    if [ ! -d "llama.cpp" ]; then
      log "Clonage de llama.cpp..."
      git clone --depth=1 https://github.com/ggerganov/llama.cpp
    else
      log "Dossier llama.cpp déjà présent, mise à jour..."
      cd llama.cpp && git pull && cd ..
    fi

    cd llama.cpp
    mkdir -p build
    cd build

    log "Configuration CMake..."
    cmake .. \
      -DGGML_OPENMP=ON \
      -DLLAMA_BUILD_SERVER=ON \
      -DCMAKE_BUILD_TYPE=Release

    # Limité à 2 threads pour éviter la surchauffe sur mobile
    JOBS=$(( $(nproc) > 2 ? 2 : $(nproc) ))
    log "Compilation avec -j${JOBS} (peut prendre 10-20 minutes)..."
    make -j"$JOBS" llama-server
  )

  success "llama-server compilé avec succès"
}

# ============================================================
# ÉTAPE 3 — Télécharger le modèle
# ============================================================
download_model() {
  step "Téléchargement du modèle Gemma 4 E2B"
  MODEL_PATH="$INSTALL_DIR/$MODEL_FILE"

  if [ -f "$MODEL_PATH" ]; then
    warn "Modèle déjà présent : $MODEL_PATH"
    warn "Supprime le fichier pour le re-télécharger."
    return
  fi

  log "Téléchargement depuis Hugging Face (~1.3 Go)..."
  log "URL : $MODEL_URL"
  wget -c --show-progress -O "$MODEL_PATH" "$MODEL_URL"

  if [ -n "$MODEL_SHA256" ]; then
    log "Vérification de l'intégrité du modèle..."
    echo "${MODEL_SHA256}  ${MODEL_PATH}" | sha256sum -c - || {
      rm -f "$MODEL_PATH"
      error "Checksum invalide ! Fichier supprimé. Relance le script."
    }
    success "Intégrité vérifiée"
  else
    warn "Aucun checksum configuré — intégrité du modèle non vérifiée."
  fi

  success "Modèle téléchargé : $MODEL_PATH"
}

# ============================================================
# ÉTAPE 4 — Script de démarrage automatique
# ============================================================
setup_autostart() {
  step "Configuration du démarrage automatique"

  if [ "$BOOT_AVAILABLE" = false ]; then
    warn "Termux:Boot absent — démarrage automatique ignoré"
    return
  fi

  mkdir -p "$HOME/.termux/boot"

  cat > "$BOOT_SCRIPT" << BOOTEOF
#!/data/data/com.termux/files/usr/bin/bash
# Démarrage automatique de Gemma 4 après reboot
sleep 30

LLAMA_BIN="${INSTALL_DIR}/llama.cpp/build/bin/llama-server"
MODEL="${INSTALL_DIR}/${MODEL_FILE}"
LOG="${LOG_FILE}"

if pgrep -f llama-server > /dev/null; then
  echo "[BOOT] llama-server déjà en cours" >> "\$LOG"
  exit 0
fi

echo "[BOOT] \$(date) — Démarrage de llama-server" >> "\$LOG"
"\$LLAMA_BIN" \\
  -m "\$MODEL" \\
  --host 0.0.0.0 \\
  --port ${PORT} \\
  -ngl 0 \\
  -c 2048 \\
  >> "\$LOG" 2>&1 &

echo "[BOOT] PID: \$!" >> "\$LOG"
BOOTEOF

  chmod +x "$BOOT_SCRIPT"
  success "Script de boot créé : $BOOT_SCRIPT"
}

# ============================================================
# ÉTAPE 5 — Désactiver l'optimisation batterie (rappel)
# ============================================================
battery_reminder() {
  step "Optimisation batterie"
  echo ""
  echo -e "${YELLOW}  ⚡ ACTION MANUELLE REQUISE :${RESET}"
  echo "  Va dans : Paramètres → Batterie → Optimisation des applis"
  echo "  Puis désactive l'optimisation pour : Termux et Termux:Boot"
  echo "  Sans ça, Android peut tuer le serveur en arrière-plan."
  echo ""
}

# ============================================================
# ÉTAPE 6 — Afficher l'IP et lancer le serveur
# ============================================================
launch_server() {
  step "Lancement du serveur"

  LLAMA_BIN="$INSTALL_DIR/llama.cpp/build/bin/llama-server"
  MODEL_PATH="$INSTALL_DIR/$MODEL_FILE"

  if [ ! -f "$LLAMA_BIN" ]; then
    error "llama-server introuvable. Lance d'abord l'installation complète (sans --start)."
  fi
  if [ ! -f "$MODEL_PATH" ]; then
    error "Modèle introuvable : $MODEL_PATH. Lance d'abord l'installation complète (sans --start)."
  fi

  WIFI_IP=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
  if [ -z "$WIFI_IP" ]; then
    WIFI_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
  fi

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║         GEMMA 4 — Serveur API prêt !         ║${RESET}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════╣${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  IP du téléphone : ${BOLD}${CYAN}${WIFI_IP}${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  API endpoint    : ${BOLD}${CYAN}http://${WIFI_IP}:${PORT}${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Depuis ton PC   : ${BOLD}curl http://${WIFI_IP}:${PORT}/v1/models${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Logs : tail -f ${LOG_FILE}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${YELLOW}  ⚠  L'API est accessible à tous sur le réseau Wi-Fi local.${RESET}"
  echo -e "${YELLOW}     Ne l'utilise pas sur un réseau public non sécurisé.${RESET}"
  echo ""

  log "Démarrage du serveur (Ctrl+C pour arrêter)..."
  "$LLAMA_BIN" \
    -m "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port "$PORT" \
    -ngl 0 \
    -c 2048
}

# ============================================================
# MAIN
# ============================================================
SCRIPT_PATH="$(realpath "$0")"

# Mode --start : bypass l'installation, lance juste le serveur
if [ "$1" = "--start" ]; then
  check_termux
  launch_server
  exit 0
fi

clear
print_banner
echo ""

check_termux
install_packages
build_llamacpp
download_model
setup_autostart
battery_reminder

echo -e "${BOLD}${GREEN}✅ Installation terminée !${RESET}"
echo ""
echo "  Pour relancer manuellement le serveur plus tard :"
echo -e "  ${CYAN}bash ${SCRIPT_PATH} --start${RESET}"
echo ""

read -p "Lancer le serveur maintenant ? [o/N] " CONFIRM
if [[ "$CONFIRM" =~ ^[oOyY]$ ]]; then
  launch_server
else
  echo ""
  echo "  Lance le serveur quand tu veux avec :"
  echo -e "  ${CYAN}bash ${SCRIPT_PATH} --start${RESET}"
fi
