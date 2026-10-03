# Oh My Pi (OMP) - Geoblocked Gemini WebAPI Stack

This repository provides an automated, self-contained one-script installer and offline bundle for **[Oh My Pi (`omp`)](https://github.com/can1357/oh-my-pi)**, powered by a localized **Gemini WebAPI proxy** (`gemini-fastapi`).

It is engineered specifically to operate out-of-the-box in **geoblocked locations** without requiring an external system VPN or GUI keyring unlock prompts (e.g. KDE Wallet / GNOME Keyring / SecretService).

---

## 🌟 Key Architecture & Capabilities

1. **Embedded Oh My Pi Native Engine (`omp`)**:
   - High-performance coding agent runtime with native tool support (ripgrep, bash execution, file read/write, LSP, DAP).
   - Pre-configured to communicate via OpenAI-compatible endpoints (`http://127.0.0.1:8000/v1`) using `openai-completions` wire protocol.

2. **Zero-Keyring Cookie Extraction (`rookiepy`)**:
   - Directly extracts active session cookies (`__Secure-1PSID`, `__Secure-1PSIDTS`, `__Secure-1PSIDCC` / `__Secure-3PSIDCC` / `SIDCC`) from Firefox profile database (`cookies.sqlite`).
   - Completely bypasses OS keyring daemons (`kwalletd5`, `gnome-keyring`), allowing seamless execution in headless SSH sessions.

3. **Built-in DNS-over-HTTPS (DoH) SNI Geoblock Bypass & Rate Limiting**:
   - Routes outbound requests to `gemini.google.com` through automatic Firefox DoH auto-detection (with fallback to `https://dns.bezmezhau.com/dns-query`, `https://dns.comss.one/dns-query`, or custom `GEMINI_DOH_URL`).
   - Transparently handles Google regional filtering at the TLS/SNI layer with zero system network configuration changes.
   - Enforces a 1 request per 2 seconds rate limit to prevent Google quota violations and server-side rate drops.
   - Includes automatic port occupancy detection with user notification and termination of conflicting processes.

4. **Self-Sustaining Offline Bundle**:
   - Ships with pre-compiled native binaries (`omp`), server sources, and complete runtime patches packaged into `oh-my-pi-offline.tar.gz`.

---

## 🚀 Quick Start & Installation

### ⚡ One-Liner Quick Install (Google Drive Self-Sufficient Bundle)

Download the pre-packaged standalone bundle directly from Google Drive and install in a single command:
```bash
curl -sSL "https://drive.usercontent.google.com/download?id=1EBJ6bqYXOG6qV-IezG2tuASbxbdEzV63&export=download&confirm=t" -o oh-my-pi-offline.tar.gz && tar -xzf oh-my-pi-offline.tar.gz && bash install_oh_my_pi.sh
```

### Option 1: One-Script Local / Cloned Installation
Clone the repository (or extract the archive) and run:
```bash
./install_oh_my_pi.sh
```

The script will automatically:
1. Validate Python (>= 3.10) and system utilities (including `bwrap`).
2. Deploy the `omp` native binary to `~/.local/bin/omp` and `~/local-ai-stack/bin/omp`.
3. Set up `gemini-fastapi` under `~/local-ai-stack/gemini-fastapi`.
4. Configure isolated local hosts DNS resolution (`~/.local/share/gemini-spoof/hosts`) via `bwrap`.
5. Apply geoblock bypass, DoH resolver, and keyring-free cookie extraction patches.
6. Generate `~/.omp/agent/models.json` and `~/.omp/agent/config.yml`.
7. Create the executable launcher `~/omp.sh`.

---

## 💻 Usage

Once installed, use the generated `~/omp.sh` launcher. It automatically starts `gemini-fastapi` if it is not already running, verifies its health check, clears loopback proxy variables, and launches `omp`.

### One-Shot Execution
```bash
~/omp.sh -p "Analyze this directory and list files with line counts"
```

```bash
~/omp.sh -p "What is 15 + 27? Output only the number."
```

### Interactive Terminal UI
```bash
~/omp.sh
```

### Selecting Models
The default model is `gemini-fastapi:gemini-flash`. You can also target pro/reasoning models:
```bash
# Enable reasoning / pro model:
~/omp.sh -t -p "Explain how quantum computers factor primes step by step"

# Target specific model:
~/omp.sh -m gemini-pro -p "Explain quantum entanglement in 2 sentences"

# List dynamically available models:
~/omp.sh -l
```

---

## ⚙️ Configuration

Configurations are stored in `~/.omp/agent/` (and mirrored to `~/.pi/agent/`):

### Provider & Model Definition (`~/.omp/agent/models.json`)
```json
{
  "providers": {
    "gemini-fastapi": {
      "name": "Gemini FastAPI (Local)",
      "baseUrl": "http://127.0.0.1:8000/v1",
      "apiKey": "sk-gemini-local",
      "api": "openai-completions",
      "models": [
        {
          "id": "gemini-flash",
          "name": "Gemini Flash (Local)",
          "reasoning": false,
          "input": ["text", "image"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 1048576,
          "maxTokens": 65536
        },
        {
          "id": "gemini-pro",
          "name": "Gemini Pro (Local)",
          "reasoning": true,
          "input": ["text", "image"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 1048576,
          "maxTokens": 65536
        },
        {
          "id": "gemini-flash-lite",
          "name": "Gemini Flash-Lite (Local)",
          "reasoning": false,
          "input": ["text", "image"],
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "contextWindow": 1048576,
          "maxTokens": 65536
        }
      ]
    }
  }
}
```

### Default Agent Config (`~/.omp/agent/config.yml`)
```yaml
model: "gemini-fastapi:gemini-flash"
```

---

## 📦 Building the Offline Archive

To generate a standalone distribution package containing the binary, source code, and installer:
```bash
tar -czvf oh-my-pi-offline.tar.gz \
    install_oh_my_pi.sh \
    omp.sh \
    bin/omp \
    gemini-fastapi \
    README.md
```
Transfer `oh-my-pi-offline.tar.gz` to any target machine, extract, and execute `./install_oh_my_pi.sh`.
