---
name: vision
description: Analyzes images, screenshots, diagrams, and photos by constructing OpenAI-compatible vision payloads (base64 data URIs inside content arrays) and querying the connected FastAPI or OpenAI endpoint. Usable by smolagent, oh-my-pi (omp), and CLI scripts.
---

# Skill: Vision (OpenAI & FastAPI Compatible)

Provides native visual understanding and multimodal reasoning capabilities for agents (`smolagent`, `oh-my-pi` / `omp`, and bash/CLI tools) by communicating with OpenAI-compatible vision endpoints (such as `gemini-fastapi` or standard `v1/chat/completions`).

## Wire Protocol & Payload Specification

For OpenAI-compatible endpoints, image parts are formatted inside the `content` array of a message alongside text:

```json
{
  "model": "gemini-flash",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "What is in this image?"
        },
        {
          "type": "image_url",
          "image_url": {
            "url": "data:image/jpeg;base64,<BASE64_DATA>",
            "detail": "auto"
          }
        }
      ]
    }
  ],
  "stream": true
}
```

### Supported MIME Types & Formats
- `image/jpeg` (`.jpg`, `.jpeg`)
- `image/png` (`.png`)
- `image/webp` (`.webp`)
- `image/gif` (`.gif`)
- `image/bmp` (`.bmp`)
- Remote URLs (`http://...`, `https://...`) are also automatically fetched and converted into base64 data URIs.

---

## 🛠️ Usage by Agent Ecosystems

### 1. Smolagent (`agent.sh`)

#### A. CLI Invocation via `agent.sh`
You can pass one or more image files directly with `-i` or `--image`:
```bash
~/agent.sh -i /path/to/screenshot.png "What does this error message say?"
```

With thinking model (`gemini-pro`) enabled:
```bash
~/agent.sh -t -i /path/to/diagram.png "Analyze this architecture diagram and list potential bottlenecks"
```

#### B. Tool Calling (`vision_tool`)
`smolagent` registers `vision_tool` as a first-class tool. The agent can invoke it autonomously during multi-step execution (e.g. after capturing a screenshot with `agentic-browser`):
```python
vision_tool(
    image_path="/path/to/screenshot.png",
    prompt="Extract all text and identify any failing tests in the UI"
)
```

#### C. Interactive Session (`/image` command)
In interactive conversation mode:
```text
You: /image /home/user/diagram.png Explain the flow in this diagram
```

---

### 2. Oh My Pi (`omp`)

`oh-my-pi` automatically discovers this skill from `~/.agents/skills/vision/SKILL.md`.

When `omp` needs to inspect an image or screenshot during a task, it executes the standalone Python helper tool via its bash environment:

```bash
python3 ~/.agents/skills/vision/scripts/vision_tool.py -i /path/to/image.png "Analyze this image and describe the code"
```

Multiple images:
```bash
python3 ~/.agents/skills/vision/scripts/vision_tool.py -i img1.png -i img2.jpg "Compare these two UI mockups"
```

With reasoning/thinking:
```bash
python3 ~/.agents/skills/vision/scripts/vision_tool.py -t -i error.png "Diagnose this stack trace and propose a fix"
```

---

### 3. Standalone CLI & Scripting

The skill includes a standalone script `scripts/vision_tool.py`:

```bash
# Basic inspection (default streams output to terminal)
python3 vision_tool.py -i /path/to/photo.jpg "Describe what you see"

# Non-streaming (for pipes / scripts)
python3 vision_tool.py -i /path/to/photo.jpg --no-stream "Output only the detected license plate"

# Inspect generated OpenAI JSON payload without sending
python3 vision_tool.py -i /path/to/photo.jpg --json "Question"
```

#### CLI Options:
| Flag | Description |
|---|---|
| `-i, --image` | Path to image file, directory of images, or URL (repeatable) |
| `-m, --model` | Target model name (default: `gemini-flash`) |
| `-t, --thinking` | Force reasoning model (`gemini-pro`) |
| `--api-base` | OpenAI/FastAPI base URL (default: `http://127.0.0.1:8000/v1`) |
| `--detail` | Image detail resolution (`auto`, `low`, `high`) |
| `--no-stream` | Disable streaming |
| `--json` | Print raw JSON payload instead of querying server |

---

### 4. Python API

Other Python scripts can import the skill library directly:

```python
from vision_tool import query_vision_model, build_vision_payload, encode_image_data_uri

# One-line vision query
response = query_vision_model(
    image_inputs="/path/to/screenshot.png",
    prompt="What is the result shown in the terminal?",
    model="gemini-flash"
)
print(response)

# Low-level payload generation
payload = build_vision_payload(
    image_inputs=["/path/to/image1.png", "/path/to/image2.jpg"],
    prompt="Compare these images"
)
```
