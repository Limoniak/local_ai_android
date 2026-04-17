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
MODEL_FILE="${MODEL_FILE:-gemma-4-E2B-it-Q4_K_M.gguf}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/${MODEL_FILE}}"
BOOT_SCRIPT="$HOME/.termux/boot/start-gemma.sh"
LOG_FILE="$HOME/gemma4-server.log"
INSTALL_LOG="$HOME/gemma4-install.log"
PORT="${PORT:-8080}"
THREADS="${THREADS:-4}"
CONTEXT="${CONTEXT:-4096}"
API_KEY="${API_KEY:-}"
NO_AUTH="${NO_AUTH:-0}"

# --- Optimisations runtime (surchargables) ---
PARALLEL="${PARALLEL:-1}"          # -np : nb de slots parallèles (1 = économise KV cache × N)
FLASH_ATTN="${FLASH_ATTN:-1}"      # -fa : flash attention (RAM + vitesse)
MLOCK="${MLOCK:-1}"                # --mlock : verrouille le modèle en RAM (pas de swap)
KV_QUANT="${KV_QUANT:-q8_0}"       # --cache-type-k/v : f16 | q8_0 | q4_0 (q8_0 = -50% RAM KV)

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "[ERR] PORT invalide : '$PORT' (doit être 1-65535)" >&2
  exit 1
fi
NGL_FILE="$INSTALL_DIR/.ngl"
BACKEND_FILE="$INSTALL_DIR/.backend"
API_KEY_FILE="$INSTALL_DIR/.api_key"

BOOT_AVAILABLE=false
VULKAN_AVAILABLE=false
OPENCL_AVAILABLE=false
BACKEND="cpu"
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
  echo "  (aucune option)    Menu interactif (SSH / IA / start / stop)"
  echo "  --start            Démarre le serveur en foreground (Ctrl+C pour arrêter)"
  echo "  --daemon, -d       Démarre le serveur en arrière-plan (survit à la déco SSH)"
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
detect_gpu() {
  step "Détection de l'accélération GPU"

  VULKAN_AVAILABLE=false
  OPENCL_AVAILABLE=false
  BACKEND="cpu"
  NGL=0

  # Marqueur utilisateur : forcer CPU-only (posé par l'option "Recompiler en CPU pur")
  if [ -f "$INSTALL_DIR/.cpu_only" ]; then
    warn "Marqueur .cpu_only présent — GPU désactivé volontairement"
    return
  fi

  # 1. OpenCL — backend préféré sur Adreno (Qualcomm) et Mali, supporté nativement par llama.cpp
  #    Pilotes Android installés par le vendor dans /vendor/lib64/libOpenCL.so
  if [ -f "/vendor/lib64/libOpenCL.so" ] || [ -f "/system/lib64/libOpenCL.so" ] \
     || [ -f "/system/vendor/lib64/libOpenCL.so" ]; then
    OPENCL_AVAILABLE=true
    BACKEND="opencl"
    NGL=99
    success "OpenCL détecté — accélération GPU activée (backend OpenCL, optimal sur Adreno)"
    return
  fi

  # 2. Vulkan — fallback pour GPU Mali récents / Adreno 7xx+ (Vulkan 1.2 requis par llama.cpp)
  #    Adreno 640 (OnePlus 7T) n'a que Vulkan 1.1 → échouera au runtime, OpenCL reste préférable
  if [ -f "/system/lib64/libvulkan.so" ] || [ -f "/vendor/lib64/libvulkan.so" ]; then
    VULKAN_AVAILABLE=true
    BACKEND="vulkan"
    NGL=99
    success "Vulkan détecté — accélération GPU activée (backend Vulkan, nécessite Vulkan 1.2+)"
    return
  fi

  warn "Aucun GPU détecté — inférence CPU uniquement"
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

  log "Installation de : git cmake clang wget curl make libandroid-spawn..."
  pkg install -y git cmake clang wget curl make libandroid-spawn

  if [ "$OPENCL_AVAILABLE" = true ]; then
    log "Installation des paquets OpenCL (headers, loader ICD)..."
    # opencl-headers : CL/cl.h ; opencl-clhpp : API C++ ; ocl-icd : loader standard
    # clinfo : utilitaire de diagnostic (équivalent de vulkaninfo)
    if ! pkg install -y opencl-headers opencl-clhpp ocl-icd clinfo 2>/dev/null; then
      warn "Paquets OpenCL indisponibles — fallback Vulkan/CPU"
      OPENCL_AVAILABLE=false
      BACKEND="cpu"
      NGL=0
      # Tenter Vulkan si libvulkan présent
      if [ -f "/system/lib64/libvulkan.so" ] || [ -f "/vendor/lib64/libvulkan.so" ]; then
        VULKAN_AVAILABLE=true
        BACKEND="vulkan"
        NGL=99
      fi
    else
      # Configurer le loader ICD pour trouver le driver Android
      # ocl-icd cherche les .icd dans /data/data/com.termux/files/usr/etc/OpenCL/vendors/
      ICD_DIR="$PREFIX/etc/OpenCL/vendors"
      mkdir -p "$ICD_DIR"
      # Pointer vers le libOpenCL.so Android du vendor
      VENDOR_OCL=""
      for p in /vendor/lib64/libOpenCL.so /system/vendor/lib64/libOpenCL.so /system/lib64/libOpenCL.so; do
        [ -f "$p" ] && VENDOR_OCL="$p" && break
      done
      if [ -n "$VENDOR_OCL" ]; then
        echo "$VENDOR_OCL" > "$ICD_DIR/android-vendor.icd"
        log "OpenCL ICD configuré : $VENDOR_OCL"
      fi
    fi
  fi

  if [ "$VULKAN_AVAILABLE" = true ]; then
    log "Installation des paquets Vulkan (headers, loader Android, shaderc, spirv)..."
    # vulkan-loader-android : charge les drivers Android (ex: /vendor/lib64/hw/vulkan.adreno.so)
    # vulkan-loader-generic ne fonctionne PAS sur Android (utilise ICD-JSON absent sur Android)
    # Retirer generic s'il est déjà installé (conflit sur libvulkan.so)
    if pkg list-installed 2>/dev/null | grep -q "^vulkan-loader-generic/"; then
      log "Remplacement de vulkan-loader-generic par vulkan-loader-android..."
      pkg uninstall -y vulkan-loader-generic 2>/dev/null || true
    fi
    # vulkan-headers + loader = build ; shaderc = glslc ; spirv-headers = spirv.hpp
    if ! pkg install -y vulkan-headers vulkan-loader-android shaderc spirv-headers spirv-tools vulkan-tools 2>/dev/null; then
      warn "vulkan-loader-android indisponible — fallback sur generic (Vulkan ne fonctionnera probablement pas à l'exécution)"
      if ! pkg install -y vulkan-headers vulkan-loader-generic shaderc spirv-headers spirv-tools vulkan-tools 2>/dev/null; then
        warn "Paquets Vulkan dev indisponibles — fallback CPU direct"
        VULKAN_AVAILABLE=false
        BACKEND="cpu"
        NGL=0
      fi
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
    # GGML_NATIVE=ON    : auto-détecte NEON / fp16 / dotprod sur Snapdragon 855+
    # GGML_LLAMAFILE=ON : kernels matmul optimisés (Mozilla Llamafile)
    # GGML_OPENMP=ON    : parallélisme CPU multi-cœurs
    CMAKE_FLAGS=(
      -DGGML_OPENMP=ON
      -DGGML_LLAMAFILE=ON
      -DGGML_NATIVE=ON
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_EXE_LINKER_FLAGS=-landroid-spawn
      -DCMAKE_SHARED_LINKER_FLAGS=-landroid-spawn
    )
    CURRENT_NGL=$NGL
    CURRENT_BACKEND="cpu"

    if [ "$OPENCL_AVAILABLE" = true ]; then
      log "Ajout du support OpenCL (backend Adreno/Mali)..."
      # GGML_OPENCL=ON                     : active le backend OpenCL
      # GGML_OPENCL_USE_ADRENO_KERNELS=ON  : kernels spécialisés Adreno (Qualcomm)
      # GGML_OPENCL_EMBED_KERNELS=ON       : embarque les .cl dans le binaire (pas de fichiers externes)
      CMAKE_FLAGS+=(-DGGML_OPENCL=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=ON -DGGML_OPENCL_EMBED_KERNELS=ON)
      CURRENT_BACKEND="opencl"
    elif [ "$VULKAN_AVAILABLE" = true ]; then
      log "Ajout du support Vulkan..."
      CMAKE_FLAGS+=(-DGGML_VULKAN=ON)
      CURRENT_BACKEND="vulkan"
    fi

    CMAKE_CPU_FALLBACK_FLAGS=(
      -DGGML_OPENMP=ON
      -DGGML_LLAMAFILE=ON
      -DGGML_NATIVE=ON
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_EXE_LINKER_FLAGS=-landroid-spawn
      -DCMAKE_SHARED_LINKER_FLAGS=-landroid-spawn
    )

    if ! cmake .. "${CMAKE_FLAGS[@]}"; then
      if [ "$CURRENT_NGL" != "0" ]; then
        warn "Échec cmake avec GPU ($CURRENT_BACKEND) — fallback CPU..."
        CURRENT_NGL=0
        CURRENT_BACKEND="cpu"
        # Nettoyer le cache CMake pour ne pas re-tenter GPU
        rm -rf ./* ./.??* 2>/dev/null || true
        cmake .. "${CMAKE_CPU_FALLBACK_FLAGS[@]}"
      else
        error "Échec de la configuration CMake"
      fi
    fi

    # Max 2 threads pour éviter la surchauffe pendant la compilation
    JOBS=$(( $(nproc) > 2 ? 2 : $(nproc) ))
    log "Compilation avec -j${JOBS} (10-20 minutes)..."

    if ! make -j"$JOBS" llama-server; then
      if [ "$CURRENT_NGL" != "0" ]; then
        warn "Échec make avec GPU ($CURRENT_BACKEND) — fallback CPU (recompilation complète)..."
        CURRENT_NGL=0
        CURRENT_BACKEND="cpu"
        rm -rf ./* ./.??* 2>/dev/null || true
        cmake .. "${CMAKE_CPU_FALLBACK_FLAGS[@]}"
        make -j"$JOBS" llama-server
      else
        error "Échec de la compilation"
      fi
    fi

    # Sauvegarder depuis le subshell — les modifs ici ne remontent pas au parent
    echo "$CURRENT_NGL" > "$NGL_FILE"
    echo "$CURRENT_BACKEND" > "$BACKEND_FILE"
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
  if [ -f "$BACKEND_FILE" ]; then
    BACKEND=$(cat "$BACKEND_FILE")
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

  case "$BACKEND" in
    opencl) GPU_MODE="GPU OpenCL (Adreno, ngl=$NGL)" ;;
    vulkan) GPU_MODE="GPU Vulkan (ngl=$NGL)" ;;
    *)      GPU_MODE="CPU uniquement (ngl=0)" ;;
  esac

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
    -np "$PARALLEL"
  )

  # KV cache quantifié — divise la RAM du cache par ~2 (f16 → q8_0) sans perte perceptible
  # Requiert flash attention pour les types != f16
  if [ "$KV_QUANT" != "f16" ] && [ "$FLASH_ATTN" = "1" ]; then
    LAUNCH_ARGS+=(--cache-type-k "$KV_QUANT" --cache-type-v "$KV_QUANT")
  fi
  # Flash attention — accélère l'inférence et réduit la RAM (obligatoire si KV quantifié)
  [ "$FLASH_ATTN" = "1" ] && LAUNCH_ARGS+=(-fa)
  # mlock — empêche le swap, garde le modèle en RAM (critique sur phone)
  [ "$MLOCK" = "1" ] && LAUNCH_ARGS+=(--mlock)

  [ -n "$API_KEY" ] && LAUNCH_ARGS+=(--api-key "$API_KEY")

  # Empêcher Android de suspendre le CPU pendant l'inférence
  if command -v termux-wake-lock &>/dev/null; then
    termux-wake-lock
    # En mode daemon, le wake-lock doit persister (libéré par --stop)
    [ "$DAEMON" = "0" ] && trap 'termux-wake-unlock 2>/dev/null || true' EXIT
  fi

  if [ "$DAEMON" = "1" ]; then
    log "Démarrage du serveur en arrière-plan..."
    nohup "$LLAMA_BIN" "${LAUNCH_ARGS[@]}" >> "$LOG_FILE" 2>&1 &
    SERVER_PID=$!
    disown "$SERVER_PID" 2>/dev/null || true

    sleep 2
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      success "Serveur lancé en arrière-plan (PID: $SERVER_PID)"
      echo ""
      echo -e "  ${BOLD}Suivre les logs :${RESET} ${CYAN}tail -f ${LOG_FILE}${RESET}"
      echo -e "  ${BOLD}Arrêter        :${RESET} ${CYAN}bash $(basename "$0") --stop${RESET}"
      echo ""
    else
      error "Le serveur s'est arrêté immédiatement — consulte ${LOG_FILE}"
    fi
  else
    log "Démarrage du serveur (Ctrl+C pour arrêter)..."
    "$LLAMA_BIN" "${LAUNCH_ARGS[@]}"
  fi
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
DAEMON=0

# Tout ce qui suit est écrit à la fois à l'écran ET dans $INSTALL_LOG
mkdir -p "$(dirname "$INSTALL_LOG")"
exec > >(tee -a "$INSTALL_LOG") 2>&1

while [ $# -gt 0 ]; do
  case "$1" in
    --start)        MODE="start"; shift ;;
    --daemon|-d)    MODE="start"; DAEMON=1; shift ;;
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

log_session_header() {
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Session : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "  Action  : $1"
  echo "═══════════════════════════════════════════════════════"
}

install_ssh_with_banner() {
  log_session_header "Installation SSH"
  check_termux
  pkg update -y
  setup_ssh
  if [ -d "/data/data/com.termux.boot" ]; then
    BOOT_AVAILABLE=true
    setup_autostart
  fi
  WIFI_IP=$(ip route get 1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')
  [ -z "$WIFI_IP" ] && WIFI_IP="<ip-introuvable>"
  echo ""
  echo -e "${BOLD}${GREEN}▶ SSH prêt — tu peux te connecter depuis ton PC :${RESET}"
  echo -e "  ${CYAN}ssh -p 8022 $(whoami)@${WIFI_IP}${RESET}"
  echo -e "  ${CYAN}Log d'installation : ${INSTALL_LOG}${RESET}"
  echo ""
}

install_ai() {
  log_session_header "Installation IA"
  check_termux
  detect_gpu
  install_packages
  build_llamacpp
  download_model
  setup_api_key
  setup_autostart
  battery_reminder

  echo -e "${BOLD}${GREEN}✅ Installation IA terminée !${RESET}"
  echo ""
  echo "  Commandes utiles :"
  echo -e "  ${CYAN}bash ${SCRIPT_PATH} --start${RESET}   Démarrer le serveur"
  echo -e "  ${CYAN}bash ${SCRIPT_PATH} --stop${RESET}    Arrêter le serveur"
  echo -e "  ${CYAN}Log d'installation : ${INSTALL_LOG}${RESET}"
  echo ""
}

rebuild_cpu_only() {
  step "Recompilation CPU uniquement"
  echo ""
  warn "Cette opération va :"
  warn "  - Arrêter le serveur s'il tourne"
  warn "  - Supprimer le build actuel (~300 Mo)"
  warn "  - Recompiler llama.cpp en CPU pur (10-20 min)"
  warn "  - Créer un marqueur pour désactiver Vulkan à l'avenir"
  echo ""
  read -p "Confirmer ? [o/N] " C
  [[ "$C" =~ ^[oOyY]$ ]] || { warn "Annulé"; return; }

  # Arrêter le serveur s'il tourne
  if pgrep -x llama-server > /dev/null; then
    log "Arrêt du serveur en cours..."
    pkill -x llama-server 2>/dev/null || true
    command -v termux-wake-unlock &>/dev/null && termux-wake-unlock 2>/dev/null || true
    sleep 2
  fi

  # Marqueur persistant pour les futurs runs
  mkdir -p "$INSTALL_DIR"
  touch "$INSTALL_DIR/.cpu_only"

  # Nettoyage du build Vulkan et du cache NGL
  rm -rf "$INSTALL_DIR/llama.cpp/build"
  rm -f "$NGL_FILE"

  # Forcer CPU pour ce run
  VULKAN_AVAILABLE=false
  NGL=0

  # Recompilation
  check_termux
  install_packages
  build_llamacpp

  success "Recompilation CPU terminée — lance le serveur (option 4) pour tester"
}

rebuild_gpu() {
  step "Recompilation GPU (OpenCL prioritaire, Vulkan en fallback)"
  echo ""
  warn "Cette opération va :"
  warn "  - Arrêter le serveur s'il tourne"
  warn "  - Retirer le marqueur .cpu_only (si présent)"
  warn "  - Supprimer le build actuel (~300 Mo)"
  warn "  - Recompiler llama.cpp avec le backend GPU détecté (10-20 min)"
  warn "  - Priorité : OpenCL (Adreno/Mali) > Vulkan > CPU"
  echo ""
  read -p "Confirmer ? [o/N] " C
  [[ "$C" =~ ^[oOyY]$ ]] || { warn "Annulé"; return; }

  # Arrêter le serveur s'il tourne
  if pgrep -x llama-server > /dev/null; then
    log "Arrêt du serveur en cours..."
    pkill -x llama-server 2>/dev/null || true
    command -v termux-wake-unlock &>/dev/null && termux-wake-unlock 2>/dev/null || true
    sleep 2
  fi

  # Retirer le marqueur CPU-only si présent
  rm -f "$INSTALL_DIR/.cpu_only"

  # Nettoyage du build et des caches
  rm -rf "$INSTALL_DIR/llama.cpp/build"
  rm -f "$NGL_FILE" "$BACKEND_FILE"

  # Recompilation avec détection GPU
  check_termux
  detect_gpu
  install_packages
  build_llamacpp

  # Afficher ce qui a réellement été compilé
  FINAL_BACKEND="cpu"
  [ -f "$BACKEND_FILE" ] && FINAL_BACKEND=$(cat "$BACKEND_FILE")
  success "Recompilation terminée — backend actif : $FINAL_BACKEND"
  if [ "$FINAL_BACKEND" = "cpu" ]; then
    warn "Aucun GPU utilisable détecté — compilé en CPU"
  fi
}

status_server() {
  step "Statut & diagnostic"

  # Serveur en cours ?
  if pgrep -x llama-server > /dev/null; then
    SERVER_PID=$(pgrep -x llama-server | head -1)
    success "llama-server en cours (PID: $SERVER_PID)"
  else
    warn "llama-server n'est pas lancé"
  fi

  # IP + endpoint
  WIFI_IP=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
  [ -z "$WIFI_IP" ] && WIFI_IP=$(ip route get 1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')
  [ -z "$WIFI_IP" ] && WIFI_IP="<ip-introuvable>"
  echo -e "  ${BOLD}IP${RESET}          : $WIFI_IP"
  echo -e "  ${BOLD}Endpoint${RESET}    : http://$WIFI_IP:$PORT"

  # Clé API
  if [ -f "$API_KEY_FILE" ]; then
    echo -e "  ${BOLD}Clé API${RESET}     : $(cat "$API_KEY_FILE")"
  fi

  # Health endpoint
  if command -v curl &>/dev/null; then
    HEALTH=$(curl -sf --max-time 2 "http://localhost:$PORT/health" 2>/dev/null || echo "")
    if [ -n "$HEALTH" ]; then
      success "/health répond : $HEALTH"
    else
      warn "/health ne répond pas (serveur non démarré ou qui charge encore le modèle)"
    fi
  fi

  # Backend compilé
  echo ""
  echo -e "${BOLD}Backend compilé :${RESET}"
  if [ -f "$BACKEND_FILE" ]; then
    COMPILED_BACKEND=$(cat "$BACKEND_FILE")
    echo "  $COMPILED_BACKEND (ngl=$(cat "$NGL_FILE" 2>/dev/null || echo 0))"
  else
    warn "  Inconnu — llama.cpp pas encore compilé"
  fi
  [ -f "$INSTALL_DIR/.cpu_only" ] && warn "  Marqueur .cpu_only présent → GPU forcé désactivé"

  # OpenCL
  echo ""
  echo -e "${BOLD}OpenCL :${RESET}"
  if command -v clinfo &>/dev/null; then
    CL_DEV=$(clinfo 2>/dev/null | grep -E "Device Name" | head -1 | sed 's/^[ \t]*//')
    if [ -n "$CL_DEV" ]; then
      echo "  $CL_DEV"
    else
      warn "  Aucun GPU détecté par clinfo"
    fi
  else
    warn "  clinfo absent — installe-le via l'option 2 (Installer IA)"
  fi
  for p in /vendor/lib64/libOpenCL.so /system/vendor/lib64/libOpenCL.so /system/lib64/libOpenCL.so; do
    [ -f "$p" ] && echo "  Driver Android : $p" && break
  done

  # Vulkan
  echo ""
  echo -e "${BOLD}Vulkan :${RESET}"
  if command -v vulkaninfo &>/dev/null; then
    VK_DEV=$(vulkaninfo --summary 2>/dev/null | grep -E "deviceName" | head -1)
    if [ -n "$VK_DEV" ]; then
      echo "  $VK_DEV"
    else
      warn "  Aucun GPU détecté par vulkaninfo"
      # Détecter le loader actif
      if pkg list-installed 2>/dev/null | grep -q "^vulkan-loader-generic/"; then
        warn "  vulkan-loader-generic installé → ne marche pas sur Android"
        warn "  Relance l'installation IA (option 2) pour basculer sur vulkan-loader-android"
      fi
    fi
  else
    warn "  vulkaninfo absent"
  fi

  # Logs llama-server
  if [ -f "$LOG_FILE" ]; then
    echo ""
    echo -e "${BOLD}Logs backend (dans $LOG_FILE) :${RESET}"
    grep -iE "opencl|vulkan|adreno|offloaded|backend|device" "$LOG_FILE" 2>/dev/null | tail -10 | sed 's/^/  /'

    echo ""
    echo -e "${BOLD}20 dernières lignes du log :${RESET}"
    tail -20 "$LOG_FILE" | sed 's/^/  /'
  else
    warn "  Aucun log serveur : $LOG_FILE"
  fi
}

change_model_menu() {
  step "Changer de modèle"
  echo ""
  echo "  1) Gemma 4 E2B Q4_K_M (3.1 Go) — actuel par défaut"
  echo "  2) Gemma 4 E2B Q4_0   (3.0 Go) — plus rapide sur ARM"
  echo "  3) Gemma 2 2B  Q4_K_M (1.6 Go) — plus léger, plus rapide"
  echo "  4) Llama 3.2 3B Q4_K_M (2.0 Go)"
  echo "  5) URL personnalisée"
  echo "  0) Retour"
  echo ""
  read -p "Choix : " MC
  case "$MC" in
    1) MODEL_URL="https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf" ;;
    2) MODEL_URL="https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf" ;;
    3) MODEL_URL="https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf" ;;
    4) MODEL_URL="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf" ;;
    5) read -p "URL .gguf : " MODEL_URL ;;
    0|"") return ;;
    *) warn "Choix invalide"; return ;;
  esac
  MODEL_FILE="$(basename "$MODEL_URL" | cut -d'?' -f1)"
  check_termux
  download_model
  warn "Modèle téléchargé. Redémarre le serveur (option 4) pour l'utiliser."
}

main_menu() {
  while true; do
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${GREEN}║              Local AI — Menu                 ║${RESET}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  1) Installer SSH (accès distant depuis PC)"
    echo "  2) Installer / mettre à jour l'IA (llama.cpp + modèle)"
    echo "  3) Tout installer (SSH puis IA)"
    echo "  4) Démarrer le serveur en arrière-plan (recommandé)"
    echo "  5) Démarrer le serveur en foreground (debug, Ctrl+C pour quitter)"
    echo "  6) Arrêter le serveur"
    echo "  7) Statut & diagnostic (IP, backend, OpenCL/Vulkan, logs)"
    echo "  8) Changer de modèle"
    echo "  9) Recompiler avec GPU (OpenCL prioritaire, recommandé sur Adreno)"
    echo " 10) Recompiler en CPU pur (si GPU incompatible)"
    echo "  0) Quitter"
    echo ""
    read -p "Ton choix [0-10] : " CHOICE
    echo ""
    case "$CHOICE" in
      1) install_ssh_with_banner ;;
      2) install_ai
         read -p "Lancer le serveur maintenant en arrière-plan ? [o/N] " CONFIRM
         if [[ "$CONFIRM" =~ ^[oOyY]$ ]]; then
           DAEMON=1; launch_server; return
         fi
         ;;
      3) install_ssh_with_banner
         install_ai
         read -p "Lancer le serveur maintenant en arrière-plan ? [o/N] " CONFIRM
         if [[ "$CONFIRM" =~ ^[oOyY]$ ]]; then
           DAEMON=1; launch_server; return
         fi
         ;;
      4) check_termux; DAEMON=1; launch_server ;;
      5) check_termux; DAEMON=0; launch_server; return ;;
      6) stop_server ;;
      7) status_server ;;
      8) change_model_menu ;;
      9) rebuild_gpu ;;
      10) rebuild_cpu_only ;;
      0) echo "Au revoir !"; return ;;
      *) warn "Choix invalide : $CHOICE" ;;
    esac
  done
}

# --- Menu interactif par défaut ---
print_banner
main_menu
