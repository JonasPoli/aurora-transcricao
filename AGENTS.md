# Repository Guidelines

## Purpose & Workflow
- Goal: extract captions and basic metadata from two YouTube channels — `https://www.youtube.com/@redeauroraater` and `https://www.youtube.com/@oextensionista` — apply textual cleanups, and organize outputs per channel.
- Steps: Passo 01 (listar vídeos), Passo 02 (baixar legendas), Passo 2.5 (transformações textuais — remoção de artefatos como [Música], [Aplausos] e normalização de quebras), Passo 03 (salvar arquivos padronizados). Barra de progresso detalha `idx/total %` e episódio/título.
- Modes: rodar apenas Passo 01 (`--run list`), pular Passo 01 usando lista existente (`--run download`), ou executar apenas Passo 2.5/03 em TXT já baixados (`--run transform-only`). Transformações extensas podem ser mantidas em `transforms.txt` e ampliadas futuramente.

## Project Structure & Module Organization
- `fetch_channel_captions.sh`: main CLI to list channel videos, fetch captions (manual → auto), convert to timestamped TXT, and index results.
- `downloads/<channel_slug>/`: outputs per channel — `#NNN - Title {Speaker}.txt`, `index.csv`, optional `.srt/.vtt` when `--keep-subs` is set. Supports per‑channel `transforms.txt` overrides.
- `data/<channel_slug>/videos.tsv`: cached video list (id and title) used for download passes.

## Build, Test, and Development Commands
- `chmod +x fetch_channel_captions.sh`: ensure the script is executable.
- `bash -n fetch_channel_captions.sh`: syntax check for the bash script.
- `shellcheck fetch_channel_captions.sh`: lint and style suggestions (install ShellCheck locally).
- Example (two target channels):
  - `./fetch_channel_captions.sh --channels "https://www.youtube.com/@redeauroraater,https://www.youtube.com/@oextensionista" --run list`
  - `./fetch_channel_captions.sh --channels "https://www.youtube.com/@redeauroraater,https://www.youtube.com/@oextensionista" --run download`
  - `./fetch_channel_captions.sh --channels "https://www.youtube.com/@redeauroraater,https://www.youtube.com/@oextensionista" --run all`
  - `./fetch_channel_captions.sh --channels "https://www.youtube.com/@redeauroraater" --run transform-only`

## Coding Style & Naming Conventions
- Bash with `set -euo pipefail`; prefer small functions, `local` variables, and clear helpers (`slugify`, `compose_basename`).
- Indentation: 2 spaces; avoid tabs. Quote variables (`"$var"`) and check command exits.
- Output naming: `#NNN - Title {Speaker}.txt` (speaker optional). Channel folder names are slugified from YouTube URLs.

## Testing Guidelines
- Lint: run `shellcheck` and fix warnings of levels info–error.
- Smoke tests: run `--run list` first; confirm `data/<slug>/videos.tsv` has entries. Then run `--run download` on a single channel to validate `index.csv` and TXT format.
- Transform rules: validate custom `transforms.txt` with 1–2 lines (e.g., `s/\bné\b/não é/gi`) before large runs.

## Commit & Pull Request Guidelines
- Commits: follow Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`). Keep messages imperative and scoped.
- PRs: include a short description, example command(s) used, sample output paths created, and rationale for options added/changed. Link related issues and attach before/after snippets when modifying TXT formatting or CSV columns.

## Security & Configuration Tips
- Dependencies: `yt-dlp`, `python3`, `sed`, `awk`, `mktemp`. No API keys required. Respect YouTube ToS and avoid excessive parallelism.
- Large runs: prefer `--run list`, review TSV, then `--run download` to control volume and retries.
