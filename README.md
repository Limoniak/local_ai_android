# 📱 Local AI on Android

> Transforme ton téléphone Android en serveur IA local accessible depuis tout ton réseau Wi-Fi.

Un seul script installe **llama.cpp** + **Gemma 4**, compile tout dans Termux et expose une API compatible OpenAI sur ton réseau local.

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

Lance cette commande dans Termux pour télécharger et exécuter le script :

```bash
wget -O setup.sh https://raw.githubusercontent.com/Limoniak/local_ai_android/main/setup_local_ai_android.sh && bash setup.sh
```

Le script s'occupe de tout automatiquement :

1. 📦 Installation des dépendances (`git`, `cmake`, `clang`, `wget`, `make`)
2. 🔨 Compilation de [llama.cpp](https://github.com/ggerganov/llama.cpp) *(10-20 min)*
3. 📥 Téléchargement du modèle Gemma 4 E2B Q4_K_M *(~1.3 Go)*
4. 🔁 Configuration du démarrage automatique *(si Termux:Boot est installé)*

---

## 🖥️ Utilisation

### Démarrer le serveur

```bash
bash setup_local_ai_android.sh --start
```

Le terminal affiche l'IP de ton téléphone et l'URL de l'API.

### Appeler l'API depuis un autre appareil

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

### Clients compatibles

L'API est compatible OpenAI — configure juste l'URL de base sur `http://<ip>:8080/v1` :

- [Open WebUI](https://github.com/open-webui/open-webui)
- [Continue](https://continue.dev) (VS Code / JetBrains)
- Python `openai` SDK

---

## 🔋 Optimisation batterie (important)

Sans cette étape, Android peut tuer le serveur en arrière-plan :

**Paramètres → Batterie → Optimisation des applications**
→ Désactiver pour **Termux** et **Termux:Boot**

---

## 📄 Logs

```bash
tail -f ~/gemma4-server.log
```

---

## ⚠️ Sécurité

L'API est exposée sur tout le réseau local **sans authentification**.
Ne l'utilise pas sur un réseau Wi-Fi public ou non sécurisé.
