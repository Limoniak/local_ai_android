#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Local AI — Setup automatique pour Termux (Android)
#  Usage : bash setup_local_ai_android.sh [--start|--stop|--help]
#  Repo  : https://github.com/Limoniak/local_ai_android
# ============================================================

set -e

# --- Couleurs ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# --- Config (overridable via variables d'env) ---
INSTALL_DIR="$HOME/gemma4"
MODEL_FILE="${MODEL_FILE:-gemma-4-e2b-it-Q4_K_M.gguf}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/bartowski/gemma-4-e2b-it-GGUF/resolve/main/${MODEL_FILE}}"
MODEL_SHA256=""
BOOT_SCRIPT="$HOME/.termux/boot/start-gemma.sh"
LOG_FILE="$HOME/gemma4-server.log"
PORT="${PORT:-8080}"
THREADS="${THREADS:-4}"
CONTEXT="${CONTEXT:-4096}"
NGL_FILE="$INSTALL_DIR/.ngl"

BOOT_AVAILABLE=false
VULKAN_AVAILABLE=false
NGL=0

# ============================================================
print_banner() {
cat << 'EOF'
  ____                                _  _
 / ___| ___ _ __ ___  _ __ ___   __ _| || |
| |  _ / _ \ '_ ` _ \| '_ ` _ \ / _` | || |_
| |_| |  __/ | | | | | | | | | | (_| |__   _|
 \____|\___|_| |_| |_|_| |_| |_|\__,_|  |_|

  Local AI — Android / Termux
EOF
}

log()     { echo -e "${CYAN}[INFO]${RESET}  $1"; }
success() { echo -e "${GREEN}[OK]${RESET}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $1"; }
error()   { echo -e "${RED}[ERR]${RESET}   $1"; exit 1; }
step()    { echo -e "\n${BOLD}${GREEN}▶ $1${RESET}"; }

usage() {
  echo ""
  echo -e "${BOLD}Usage :${RESET} bash $(basename "$0") [option] [--model <url>]"
  echo ""
  echo "  (aucune option)    Installation complète puis démarrage optionnel"
  echo "  --start            Démarre le serveur sans réinstaller"
  echo "  --stop             Arrête le serveur en cours"
  echo "  --model <url>      Utilise un autre modèle GGUF (ex: depuis HuggingFace)"
  echo "  --help             Affiche cette aide"
  echo ""
  echo -e "${BOLD}Variables d'environnement :${RESET}"
  echo "  PORT=8080          Port du serveur"
  echo "  THREADS=4          Nombre de threads CPU"
  echo "  CONTEXT=4096       Taille du contexte en tokens"
  echo ""
}

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
    warn "Termux:Boot absent — démarrage auto au reboot désactivé."
    warn "Installe Termux:Boot depuis F-Droid pour l'activer."
    BOOT_AVAILABLE=false
  else
    success "Termux:Boot détecté"
    BOOT_AVAILABLE=true
  fi
}

# ============================================================
# ÉTAPE 0b — Détection Vulkan
# ============================================================
detect_vulkan() {
  step "Détection de l'accélération GPU (Vulkan)"

  if [ -f "/system/lib64/libvulkan.so" ] || [ -f "/vendor/lib64/vulkan.so" ]; then
    VULKAN_AVAILABLE=true
    NGL=99
    success "Vulkan détecté — accélération GPU activée (-ngl 99)"
  else
    VULKAN_AVAILABLE=false
    NGL=0
    warn "Vulkan non détecté — inférence CPU uniquement (-ngl 0)"
  fi
}

# ============================================================
# ÉTAPE 1 — Mise à jour et paquets
# ============================================================
install_packages() {
  step "Installation des dépendances"
  log "Mise à jour des paquets..."
  pkg update -y && pkg upgrade -y

  log "Installation de : git cmake clang wget make..."
  pkg install -y git cmake clang wget make

  if [ "$VULKAN_AVAILABLE" = true ]; then
    log "Installation des outils Vulkan..."
    pkg install -y vulkan-tools 2>/dev/null || warn "vulkan-tools indisponible — Vulkan peut quand même fonctionner"
  fi

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
    # Restaurer le NGL stocké lors de la précédente compilation
    if [ -f "$NGL_FILE" ]; then
      NGL=$(cat "$NGL_FILE")
    fi
    return
  fi

  mkdir -p "$INSTALL_DIR"

  (
    cd "$INSTALL_DIR"

    if [ ! -d "llama.cpp" ]; then
      log "Clonage de llama.cpp..."
      git clone --depth=1 https://github.com/ggerganov/llama.cpp
    else
      log "Dossier llama.cpp présent, mise à jour..."
      cd llama.cpp && git pull && cd ..
    fi

    cd llama.cpp
    mkdir -p build
    cd build

    log "Configuration CMake..."
    CMAKE_FLAGS="-DGGML_OPENMP=ON -DCMAKE_BUILD_TYPE=Release"

    if [ "$VULKAN_AVAILABLE" = true ]; then
      log "Ajout du support Vulkan..."
      CMAKE_FLAGS="$CMAKE_FLAGS -DGGML_VULKAN=ON"
    fi

    if ! cmake .. $CMAKE_FLAGS; then
      if [ "$VULKAN_AVAILABLE" = true ]; then
        warn "Échec cmake avec Vulkan — fallback CPU..."
        VULKAN_AVAILABLE=false
        NGL=0
        cmake .. -DGGML_OPENMP=ON -DCMAKE_BUILD_TYPE=Release
      else
        error "Échec de la configuration CMake"
      fi
    fi

    # Max 2 threads pour éviter la surchauffe pendant la compilation
    JOBS=$(( $(nproc) > 2 ? 2 : $(nproc) ))
    log "Compilation avec -j${JOBS} (10-20 minutes)..."
    make -j"$JOBS" llama-server
  )

  # Sauvegarder le mode GPU pour les lancements futurs
  echo "$NGL" > "$NGL_FILE"

  success "llama-server compilé avec succès"
}

# ============================================================
# ÉTAPE 3 — Télécharger le modèle
# ============================================================
download_model() {
  step "Téléchargement du modèle"
  MODEL_PATH="$INSTALL_DIR/$MODEL_FILE"

  if [ -f "$MODEL_PATH" ]; then
    warn "Modèle déjà présent : $MODEL_PATH"
    warn "Supprime le fichier pour le re-télécharger."
    return
  fi

  log "Modèle    : $MODEL_FILE"
  log "Source    : $MODEL_URL"
  wget -c --show-progress -O "$MODEL_PATH" "$MODEL_URL"

  if [ -n "$MODEL_SHA256" ]; then
    log "Vérification de l'intégrité..."
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
sleep 30

LLAMA_BIN="${INSTALL_DIR}/llama.cpp/build/bin/llama-server"
MODEL="${INSTALL_DIR}/${MODEL_FILE}"
LOG="${LOG_FILE}"
NGL=\$(cat "${NGL_FILE}" 2>/dev/null || echo 0)

if pgrep -f llama-server > /dev/null; then
  echo "[BOOT] llama-server déjà en cours" >> "\$LOG"
  exit 0
fi

echo "[BOOT] \$(date) — Démarrage de llama-server (ngl=\$NGL)" >> "\$LOG"
"\$LLAMA_BIN" \\
  -m "\$MODEL" \\
  --host 0.0.0.0 \\
  --port ${PORT} \\
  -ngl "\$NGL" \\
  -t ${THREADS} \\
  -c ${CONTEXT} \\
  >> "\$LOG" 2>&1 &

echo "[BOOT] PID: \$!" >> "\$LOG"
BOOTEOF

  chmod +x "$BOOT_SCRIPT"
  success "Script de boot créé : $BOOT_SCRIPT"
}

# ============================================================
# ÉTAPE 5 — Rappel optimisation batterie
# ============================================================
battery_reminder() {
  step "Optimisation batterie"
  echo ""
  echo -e "${YELLOW}  ⚡ ACTION MANUELLE REQUISE :${RESET}"
  echo "  Paramètres → Batterie → Optimisation des applications"
  echo "  → Désactiver pour : Termux et Termux:Boot"
  echo "  Sans ça, Android peut tuer le serveur en arrière-plan."
  echo ""
}

# ============================================================
# Lancer le serveur
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

  # Lire le mode GPU de la compilation
  if [ -f "$NGL_FILE" ]; then
    NGL=$(cat "$NGL_FILE")
  fi

  WIFI_IP=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
  if [ -z "$WIFI_IP" ]; then
    WIFI_IP=$(ip route get 1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')
  fi
  [ -z "$WIFI_IP" ] && WIFI_IP="<ip-introuvable>"

  GPU_MODE="CPU uniquement"
  [ "$NGL" != "0" ] && GPU_MODE="GPU Vulkan (ngl=$NGL)"

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║         Local AI — Serveur API prêt !        ║${RESET}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════╣${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  IP du téléphone : ${BOLD}${CYAN}${WIFI_IP}${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  API endpoint    : ${BOLD}${CYAN}http://${WIFI_IP}:${PORT}${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Depuis ton PC   : ${BOLD}curl http://${WIFI_IP}:${PORT}/v1/models${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Mode            : ${BOLD}${GPU_MODE}${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Threads         : ${BOLD}${THREADS}${RESET}  |  Contexte : ${BOLD}${CONTEXT} tokens${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Logs : tail -f ${LOG_FILE}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${YELLOW}  ⚠  API accessible à tous sur le réseau local — réseau de confiance uniquement.${RESET}"
  echo ""

  log "Démarrage du serveur (Ctrl+C pour arrêter)..."
  "$LLAMA_BIN" \
    -m "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port "$PORT" \
    -ngl "$NGL" \
    -t "$THREADS" \
    -c "$CONTEXT"
}

# ============================================================
# Arrêter le serveur
# ============================================================
stop_server() {
  step "Arrêt du serveur"
  if pgrep -f llama-server > /dev/null; then
    pkill -f llama-server
    success "Serveur arrêté"
  else
    warn "Aucun serveur llama-server en cours d'exécution"
  fi
}

# ============================================================
# MAIN — Parsing des arguments
# ============================================================
SCRIPT_PATH="$(realpath "$0")"
MODE="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --start)        MODE="start"; shift ;;
    --stop)         MODE="stop";  shift ;;
    --help|-h)      MODE="help";  shift ;;
    --model)
      [ -z "$2" ] && error "--model nécessite une URL en argument"
      MODEL_URL="$2"
      MODEL_FILE="$(basename "$2" | cut -d'?' -f1)"
      shift 2
      ;;
    *) error "Option inconnue : $1. Lance avec --help pour l'aide." ;;
  esac
done

case "$MODE" in
  help)
    print_banner
    usage
    exit 0
    ;;
  stop)
    stop_server
    exit 0
    ;;
  start)
    check_termux
    launch_server
    exit 0
    ;;
esac

# --- Installation complète ---
clear
print_banner
echo ""

check_termux
detect_vulkan
install_packages
build_llamacpp
download_model
setup_autostart
battery_reminder

echo -e "${BOLD}${GREEN}✅ Installation terminée !${RESET}"
echo ""
echo "  Commandes utiles :"
echo -e "  ${CYAN}bash ${SCRIPT_PATH} --start${RESET}   Démarrer le serveur"
echo -e "  ${CYAN}bash ${SCRIPT_PATH} --stop${RESET}    Arrêter le serveur"
echo ""

read -p "Lancer le serveur maintenant ? [o/N] " CONFIRM
if [[ "$CONFIRM" =~ ^[oOyY]$ ]]; then
  launch_server
fi
