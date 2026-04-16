# Local AI on Android

Run a local LLM (Gemma 4) on your Android phone via Termux and expose an OpenAI-compatible API accessible from any device on your local network.

## Requirements

- Android phone with [Termux](https://f-droid.org/packages/com.termux/) (from F-Droid)
- [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) (optional, for autostart on reboot)
- Wi-Fi connection
- ~3 GB free storage

## Installation

Copy the script to your phone (via USB, Syncthing, etc.) then run in Termux:

```bash
bash setup_local_ai_android.sh
```

The script will automatically:
1. Install dependencies (`git`, `cmake`, `clang`, `wget`, `make`)
2. Compile [llama.cpp](https://github.com/ggerganov/llama.cpp)
3. Download the Gemma 4 E2B model (~1.3 GB, quantized Q4_K_M)
4. Configure autostart on boot (if Termux:Boot is installed)

## Usage

### Start the server

```bash
bash setup_local_ai_android.sh --start
```

The server starts on port `8080` and displays your phone's local IP.

### Query the API from another device

```bash
# List available models
curl http://<phone-ip>:8080/v1/models

# Chat completion
curl http://<phone-ip>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-e2b-it-Q4_K_M",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Compatible clients

Any OpenAI-compatible client works — just set the base URL to `http://<phone-ip>:8080/v1`:

- [Open WebUI](https://github.com/open-webui/open-webui)
- [Cursor](https://cursor.sh) / VS Code with Continue
- Python `openai` SDK

## Manual battery optimization

To prevent Android from killing the server in the background:

**Settings → Battery → App optimization → Disable for Termux and Termux:Boot**

## Security

The API is exposed on all network interfaces with no authentication. **Do not use on public or untrusted Wi-Fi networks.**

## Logs

```bash
tail -f ~/gemma4-server.log
```
