# 📱 Local AI on Android

> Transforme ton téléphone Android en serveur IA local accessible depuis tout ton réseau Wi-Fi.

Un seul script installe **llama.cpp** + **Gemma 4**, compile tout dans Termux et expose une API compatible OpenAI sur ton réseau local. Détecte automatiquement si Vulkan est disponible pour accélérer l'inférence via le GPU.

---

## ✅ Prérequis

| Requis | Optionnel |
|--------|-----------|
| [Termux](https://f-droid.org/packages/com.termux/) (via F-Droid) | [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) — démarrage auto au reboot |
| Connexion Wi-Fi | |
| ~3 Go de stockage libre | |

> ⚠️ Installe Termux depuis **F-Droid**, pas depuis le Play Store (version non maintenue).

---

## 🚀 Installation

Lance cette commande dans Termux :

```bash
wget -O setup.sh https://raw.githubusercontent.com/Limoniak/local_ai_android/main/setup_local_ai_android.sh && bash setup.sh
```

Le script s'occupe de tout automatiquement :

1. 🔍 Détection du support GPU Vulkan
2. 📦 Installation des dépendances (`git`, `cmake`, `clang`, `wget`, `make`)
3. 🔨 Compilation de [llama.cpp](https://github.com/ggerganov/llama.cpp) avec GPU si disponible *(10-20 min)*
4. 📥 Téléchargement du modèle Gemma 4 E2B Q4_K_M *(~1.3 Go)*
5. 🔁 Configuration du démarrage automatique *(si Termux:Boot est installé)*

---

## 🖥️ Utilisation

### Démarrer le serveur

```bash
bash setup.sh --start
```

### Arrêter le serveur

```bash
bash setup.sh --stop
```

### Utiliser un autre modèle GGUF

```bash
bash setup.sh --model https://huggingface.co/.../model.gguf
```

### Personnaliser les paramètres

```bash
PORT=9090 THREADS=6 CONTEXT=8192 bash setup.sh --start
```

---

## 🌐 Appeler l'API depuis un autre appareil

```bash
# Lister les modèles disponibles
curl http://<ip-du-téléphone>:8080/v1/models

# Chat
curl http://<ip-du-téléphone>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-e2b-it-Q4_K_M",
    "messages": [{"role": "user", "content": "Bonjour !"}]
  }'
```

L'IP du téléphone est affichée au démarrage du serveur.

### Clients compatibles

L'API est compatible OpenAI — configure l'URL de base sur `http://<ip>:8080/v1` :

| Client | Usage |
|--------|-------|
| [Open WebUI](https://github.com/open-webui/open-webui) | Interface web complète |
| [Continue](https://continue.dev) | VS Code / JetBrains |
| Python `openai` SDK | Intégration dans tes scripts |

---

## ⚡ Accélération GPU (Vulkan)

Le script détecte automatiquement si ton téléphone supporte Vulkan (la majorité des Android modernes).
Si c'est le cas, llama.cpp est compilé avec `-DGGML_VULKAN=ON` et le serveur utilise le GPU pour l'inférence — ce qui peut être **3 à 5x plus rapide** qu'en CPU seul.

Le mode utilisé est affiché au démarrage du serveur.

---

## 🔋 Optimisation batterie (important)

Sans cette étape, Android peut tuer le serveur en arrière-plan :

**Paramètres → Batterie → Optimisation des applications**
→ Désactiver pour **Termux** et **Termux:Boot**

---

## 🛠️ Dépannage

**`pkg update` bloqué ou lent**
```bash
termux-change-repo   # Changer de miroir
```

**Erreur de compilation CMake**
```bash
rm -rf ~/gemma4/llama.cpp/build
bash setup.sh        # Relancer, le modèle ne sera pas re-téléchargé
```

**Port déjà utilisé**
```bash
bash setup.sh --stop
# ou
PORT=9090 bash setup.sh --start
```

**Téléchargement interrompu**
Relance simplement le script — `wget -c` reprend là où il s'est arrêté.

**Retrouver l'IP si elle n'est pas affichée**
```bash
ip addr show wlan0
```

---

## 📄 Logs

```bash
tail -f ~/gemma4-server.log
```

---

## ⚠️ Sécurité

L'API est exposée sur tout le réseau local **sans authentification**.
Ne l'utilise pas sur un réseau Wi-Fi public ou non sécurisé.
