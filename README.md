# ollama-update

Check for Ollama model updates **without pulling** — by comparing local digests against the registry manifest. Only pulls when there's actually an update.

## Why?

If you manage dozens of models, pulling each one just to check for updates wastes time and bandwidth. This script queries the registry first, so you get a fast dry-run view of what's outdated before committing to any downloads.

**Features:**

- **Digest-based dry run** — check what's outdated without pulling anything
- **Custom Modelfile rebuild** — detects when a base model updates and rebuilds your custom models
- **VRAM lifecycle** — unloads and reloads running models after update, preserving keep_alive timers
- **Pinned models** — skip specific models you don't want touched
- **Config file** — persistent settings without editing the script
- **Remote endpoint** — manage models on any Ollama instance
- **JSON output** — machine-readable results for scripting/CI
- **CI-friendly exit codes** — `0` all up to date, `1` updates available, `2` usage error

## Quick start

```bash
# Check for updates (dry run — nothing is pulled)
ollama-update

# Actually pull updates and rebuild custom Modelfiles
ollama-update --update

# Pin models you don't want updated
ollama-update --pin llama3:70b,mistral:7b

# Check a remote Ollama instance
ollama-update --endpoint http://gpu-server:11434

# JSON output for scripting
ollama-update --json
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--update` | Pull updates and rebuild custom Modelfiles | dry run |
| `--json` | Output results as JSON | off |
| `--quiet` | Only show UPDATE and SKIP lines | off |
| `--defer-reload` | Skip reloading updated models in VRAM | off |
| `--config <path>` | Config file path | `~/.config/ollama-update/config` |
| `--modelfile-dir <path>` | Custom Modelfile directory | `~/.config/ollama-update/modelfiles` |
| `--endpoint <url>` | Ollama API endpoint | `http://localhost:11434` |
| `--pin <models>` | Comma-separated models to skip | (none) |
| `--jobs <N>` | Parallel digest check jobs | unlimited (`0`) |

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | All models up to date (or updates applied with `--update`) |
| `1` | Updates available (dry run) |
| `2` | Usage error (bad args, endpoint unreachable) |

## Install

```bash
# Homebrew
brew tap bgupta/tap
brew install ollama-update

# Clone and symlink
git clone https://github.com/bgupta/ollama-update.git
ln -s "$(pwd)/ollama-update/ollama-update" ~/bin/ollama-update

# Or just download the script
curl -o ~/bin/ollama-update https://raw.githubusercontent.com/bgupta/ollama-update/main/ollama-update
chmod +x ~/bin/ollama-update
```

### Update

```bash
# Homebrew
brew upgrade ollama-update

# Git clone
cd ollama-update && git pull

# Curl
# Re-run the curl command above
```

**Requirements:** `bash` 4.0+, `curl`, `jq`, `ollama`

## Platform support

| Platform | Status | Notes |
|----------|--------|-------|
| Linux | Fully supported | Works with system Bash |
| macOS (Homebrew) | Fully supported | `brew install bash` (Bash 4.0+ required) |
| macOS (stock) | Not supported | Ships Bash 3.2 -- install via Homebrew |
| WSL / Windows | Fully supported | Works with system Bash |

## Configuration

Settings are loaded from `~/.config/ollama-update/config` (bash key=value format):

```bash
# ~/.config/ollama-update/config
MODELFILE_DIR=$HOME/my-modelfiles
OLLAMA_ENDPOINT=http://gpu-server:11434
PINNED_MODELS=llama3:70b,codellama:34b
```

CLI flags override config file values. Config file overrides defaults.

| Setting | CLI Flag | Config Key | Default |
|---------|----------|------------|---------|
| Config file | `--config <path>` | — | `~/.config/ollama-update/config` |
| Modelfile dir | `--modelfile-dir <path>` | `MODELFILE_DIR` | `~/.config/ollama-update/modelfiles` |
| Ollama endpoint | `--endpoint <url>` | `OLLAMA_ENDPOINT` | `http://localhost:11434` |
| Pinned models | `--pin <model>[,...]` | `PINNED_MODELS` | (empty) |

## Custom Modelfiles

If you use `ollama create` with custom Modelfiles (system prompts, parameters, etc.), put them in your modelfile directory as `Modelfile-<name>`, where `<name>` matches the installed model name (the `:latest` tag is implied):

```
~/.config/ollama-update/modelfiles/
  Modelfile-my-assistant     # FROM llama3:8b + custom system prompt
  Modelfile-coding-helper    # FROM codellama:7b + custom params
```

When a base model gets an upstream update, the script detects the digest mismatch and rebuilds your custom model automatically.

## Output

```
Checking 24 models against registry (unlimited parallel)...

OK    llama3:8b
OK    mistral:7b
UPDATE codellama:7b
PIN   llama3:70b
SKIP  my-local-only-model:latest (not in registry)
OK    my-assistant (custom: base llama3:8b up to date)

Done: 3 ok, 1 update, 1 skip, 1 pin (2.4s)
Run with --update to pull updates and rebuild custom Modelfiles.
```

## VRAM reload

When `--update` is used (without `--defer-reload`), the script:

1. Snapshots which models are currently loaded in VRAM and their `keep_alive` expiry
2. After updating, unloads and reloads affected models
3. Preserves the original `keep_alive` duration so they don't expire early

Use `--defer-reload` to skip this — updated models will cold-load on next use instead.

## How it works

1. Discovers installed models via the Ollama HTTP API (`/api/tags`)
2. For each model, extracts the local weight blob digest via `/api/show`
3. Fetches the registry manifest from `registry.ollama.ai` and extracts the remote digest
4. Compares digests — if they differ, the model has an update
5. For custom Modelfile-based models, checks both the base model's registry digest *and* whether the custom model's blob matches its base
6. With `--update`: pulls changed models, rebuilds custom Modelfiles, reloads VRAM

The registry is always `registry.ollama.ai` regardless of your local endpoint setting — the endpoint only controls where `ollama pull` and VRAM operations target.

## Contributing

Feature requests and bug reports are welcome — please [open an issue](https://github.com/bgupta/ollama-update/issues).

## License

MIT
