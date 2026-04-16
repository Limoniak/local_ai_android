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
BOOT_SCRIPT="$HOME/.termux/boot/start-gemma.sh"
LOG_FILE="$HOME/gemma4-server.log"
PORT="${PORT:-8080}"
THREADS="${THREADS:-4}"
CONTEXT="${CONTEXT:-4096}"
API_KEY="${API_KEY:-}"
NO_AUTH="${NO_AUTH:-0}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "[ERR] PORT invalide : '$PORT' (doit être 1-65535)" >&2
  exit 1
fi
NGL_FILE="$INSTALL_DIR/.ngl"
API_KEY_FILE="$INSTALL_DIR/.api_key"

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
  echo "  --ssh              Active l'accès SSH (port 8022, auth par mot de passe)"
  echo "  --model <url>      Utilise un autre modèle GGUF (ex: depuis HuggingFace)"
  echo "  --help             Affiche cette aide"
  echo ""
  echo -e "${BOLD}Variables d'environnement :${RESET}"
  echo "  PORT=8080          Port du serveur"
  echo "  THREADS=4          Nombre de threads CPU"
  echo "  CONTEXT=4096       Taille du contexte en tokens"
  echo "  API_KEY=...        Clé API personnalisée (sinon auto-générée)"
  echo "  NO_AUTH=1          Désactive l'authentification (non recommandé)"
  echo ""
}

# ============================================================
# Configuration clé API
# ============================================================
setup_api_key() {
  step "Configuration de la clé API"

  if [ "$NO_AUTH" = "1" ]; then
    warn "NO_AUTH=1 — serveur lancé SANS authentification"
    rm -f "$API_KEY_FILE"
    API_KEY=""
    return
  fi

  mkdir -p "$INSTALL_DIR"

  if [ -n "$API_KEY" ]; then
    echo "$API_KEY" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
    success "Clé API personnalisée enregistrée"
  elif [ -f "$API_KEY_FILE" ]; then
    API_KEY=$(cat "$API_KEY_FILE")
    success "Clé API existante réutilisée"
  else
    API_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | head -c 32)
    echo "$API_KEY" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
    success "Clé API générée automatiquement"
  fi
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

  if [ -f "/system/lib64/libvulkan.so" ] || [ -f "/vendor/lib64/libvulkan.so" ]; then
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
# Configuration SSH (accès distant depuis PC)
# ============================================================
setup_ssh() {
  step "Configuration de l'accès SSH"

  log "Installation d'openssh..."
  pkg install -y openssh

  echo ""
  echo -e "${BOLD}Définis le mot de passe pour te connecter depuis ton PC :${RESET}"
  passwd

  # Démarrer sshd (le relancer s'il tourne déjà)
  pkill -x sshd 2>/dev/null || true
  sshd

  SSH_USER=$(whoami)
  success "SSH activé — utilisateur : ${SSH_USER} — port : 8022"
}

# ============================================================
# ÉTAPE 1 — Mise à jour et paquets
# ============================================================
install_packages() {
  step "Installation des dépendances"
  log "Mise à jour des paquets..."
  pkg update -y && pkg upgrade -y

  log "Installation de : git cmake clang wget curl make..."
  pkg install -y git cmake clang wget curl make

  if [ "$VULKAN_AVAILABLE" = true ]; then
    log "Installation des paquets Vulkan (headers, loader, shaderc)..."
    # vulkan-headers + vulkan-loader-generic = build, shaderc fournit glslc
    if ! pkg install -y vulkan-headers vulkan-loader-generic shaderc vulkan-tools 2>/dev/null; then
      warn "Paquets Vulkan dev indisponibles — le build Vulkan échouera probablement, fallback CPU"
      VULKAN_AVAILABLE=false
      NGL=0
    fi
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
    CMAKE_FLAGS=(-DGGML_OPENMP=ON -DCMAKE_BUILD_TYPE=Release)
    CURRENT_NGL=$NGL

    if [ "$VULKAN_AVAILABLE" = true ]; then
      log "Ajout du support Vulkan..."
      CMAKE_FLAGS+=(-DGGML_VULKAN=ON)
    fi

    if ! cmake .. "${CMAKE_FLAGS[@]}"; then
      if [ "$CURRENT_NGL" != "0" ]; then
        warn "Échec cmake avec Vulkan — fallback CPU..."
        CURRENT_NGL=0
        # Nettoyer le cache CMake pour ne pas re-tenter Vulkan
        rm -rf ./* ./.??* 2>/dev/null || true
        cmake .. -DGGML_OPENMP=ON -DCMAKE_BUILD_TYPE=Release
      else
        error "Échec de la configuration CMake"
      fi
    fi

    # Max 2 threads pour éviter la surchauffe pendant la compilation
    JOBS=$(( $(nproc) > 2 ? 2 : $(nproc) ))
    log "Compilation avec -j${JOBS} (10-20 minutes)..."
    make -j"$JOBS" llama-server

    # Sauvegarder depuis le subshell — NGL modifié ici ne remonte pas au parent
    echo "$CURRENT_NGL" > "$NGL_FILE"
  )

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

  # Téléchargement dans un .tmp puis rename : évite les fichiers partiels
  # considérés comme complets si le téléchargement est interrompu
  MODEL_TMP="${MODEL_PATH}.tmp"
  wget -c --show-progress -O "$MODEL_TMP" "$MODEL_URL"

  mv "$MODEL_TMP" "$MODEL_PATH"
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

LLAMA_BIN="${INSTALL_DIR}/llama.cpp/build/bin/llama-server"
MODEL="${INSTALL_DIR}/${MODEL_FILE}"
LOG="${LOG_FILE}"
NGL=\$(cat "${NGL_FILE}" 2>/dev/null || echo 0)
API_KEY=\$(cat "${API_KEY_FILE}" 2>/dev/null || echo "")

# Attendre que le Wi-Fi soit up (max 120s)
for i in \$(seq 1 60); do
  ip route get 1 &>/dev/null && break
  sleep 2
done

# Démarrer sshd si installé (accès distant depuis PC)
if command -v sshd &>/dev/null && ! pgrep -x sshd > /dev/null; then
  sshd
  echo "[BOOT] sshd démarré (port 8022)" >> "\$LOG"
fi

if pgrep -x llama-server > /dev/null; then
  echo "[BOOT] llama-server déjà en cours" >> "\$LOG"
  exit 0
fi

# Empêcher Android de suspendre le CPU
command -v termux-wake-lock &>/dev/null && termux-wake-lock

echo "[BOOT] \$(date) — Démarrage de llama-server (ngl=\$NGL)" >> "\$LOG"

AUTH_ARGS=()
[ -n "\$API_KEY" ] && AUTH_ARGS=(--api-key "\$API_KEY")

"\$LLAMA_BIN" \\
  -m "\$MODEL" \\
  --host 0.0.0.0 \\
  --port ${PORT} \\
  -ngl "\$NGL" \\
  -t ${THREADS} \\
  -c ${CONTEXT} \\
  "\${AUTH_ARGS[@]}" \\
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

  # Lire la clé API sauvegardée
  if [ -z "$API_KEY" ] && [ -f "$API_KEY_FILE" ]; then
    API_KEY=$(cat "$API_KEY_FILE")
  fi

  WIFI_IP=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
  if [ -z "$WIFI_IP" ]; then
    WIFI_IP=$(ip route get 1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')
  fi
  [ -z "$WIFI_IP" ] && WIFI_IP="<ip-introuvable>"

  GPU_MODE="CPU uniquement"
  [ "$NGL" != "0" ] && GPU_MODE="GPU Vulkan (ngl=$NGL)"

  AUTH_STATUS="désactivée (NO_AUTH=1)"
  [ -n "$API_KEY" ] && AUTH_STATUS="activée"

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║         Local AI — Serveur API prêt !        ║${RESET}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════╣${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  IP du téléphone : ${BOLD}${CYAN}${WIFI_IP}${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  API endpoint    : ${BOLD}${CYAN}http://${WIFI_IP}:${PORT}${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Mode            : ${BOLD}${GPU_MODE}${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Threads         : ${BOLD}${THREADS}${RESET}  |  Contexte : ${BOLD}${CONTEXT} tokens${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Auth            : ${BOLD}${AUTH_STATUS}${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
  echo ""

  if [ -n "$API_KEY" ]; then
    echo -e "  ${BOLD}Clé API :${RESET} ${CYAN}${API_KEY}${RESET}"
    echo -e "  ${BOLD}Fichier :${RESET} ${API_KEY_FILE}"
    echo ""
    echo -e "  ${BOLD}Exemple depuis ton PC :${RESET}"
    echo -e "  ${CYAN}curl http://${WIFI_IP}:${PORT}/v1/models \\\\${RESET}"
    echo -e "  ${CYAN}  -H \"Authorization: Bearer ${API_KEY}\"${RESET}"
  else
    echo -e "  ${YELLOW}⚠  API accessible à tous sur le réseau local sans authentification !${RESET}"
  fi
  echo ""
  if command -v sshd &>/dev/null; then
    if ! pgrep -x sshd > /dev/null; then
      sshd
    fi
    echo -e "  ${BOLD}Accès SSH depuis PC :${RESET}"
    echo -e "  ${CYAN}ssh -p 8022 $(whoami)@${WIFI_IP}${RESET}"
    echo ""
  fi
  echo "  Logs : tail -f ${LOG_FILE}"
  echo ""

  LAUNCH_ARGS=(
    -m "$MODEL_PATH"
    --host 0.0.0.0
    --port "$PORT"
    -ngl "$NGL"
    -t "$THREADS"
    -c "$CONTEXT"
  )
  [ -n "$API_KEY" ] && LAUNCH_ARGS+=(--api-key "$API_KEY")

  # Empêcher Android de suspendre le CPU pendant l'inférence
  if command -v termux-wake-lock &>/dev/null; then
    termux-wake-lock
    trap 'termux-wake-unlock 2>/dev/null || true' EXIT
  fi

  log "Démarrage du serveur (Ctrl+C pour arrêter)..."
  "$LLAMA_BIN" "${LAUNCH_ARGS[@]}"
}

# ============================================================
# Arrêter le serveur
# ============================================================
stop_server() {
  step "Arrêt du serveur"
  if pgrep -x llama-server > /dev/null; then
    pkill -x llama-server
    command -v termux-wake-unlock &>/dev/null && termux-wake-unlock 2>/dev/null || true
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
    --ssh)          MODE="ssh";   shift ;;
    --help|-h)      MODE="help";  shift ;;
    --model)
      [ -z "$2" ] && error "--model nécessite une URL en argument"
      MODEL_URL="$2"
      MODEL_FILE="$(basename "$2" | cut -d'?' -f1)"
      if [[ ! "$MODEL_FILE" =~ \.gguf$ ]]; then
        error "L'URL --model doit pointer vers un fichier .gguf (reçu: $MODEL_FILE)"
      fi
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
  ssh)
    check_termux
    setup_ssh
    # Régénérer le boot script pour y inclure sshd si Termux:Boot est là
    if [ -d "/data/data/com.termux.boot" ]; then
      BOOT_AVAILABLE=true
      setup_autostart
    fi
    exit 0
    ;;
esac

# --- Installation complète ---
print_banner
echo ""

check_termux
detect_vulkan
install_packages
build_llamacpp
download_model
setup_api_key

echo ""
read -p "Activer l'accès SSH pour gérer le téléphone depuis ton PC ? [o/N] " SSH_CONFIRM
if [[ "$SSH_CONFIRM" =~ ^[oOyY]$ ]]; then
  setup_ssh
fi

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
