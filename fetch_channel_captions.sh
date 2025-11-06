#!/usr/bin/env bash
#------------------------------------------------------------------------------
# fetch_channel_captions.sh
#
# Objetivo:
#   1) (Passo 01) Listar TODOS os vídeos dos canais YouTube informados
#   2) (Passo 02) Baixar legendas (manuais -> auto), converter p/ TXT com timestamps
#   2.5) Aplicar transformações (remoção de artefatos e normalização)
#   3) (Passo 03) Salvar com nome padronizado: "#NNN - Título {Palestrante}.txt"
#   + Gerar CSV de índice por canal e "id_<VIDEOID>.txt" com metadados
#
# Modos:
#   --run all            : Passo 01 + 02 + 2.5 + 03
#   --run list           : Só Passo 01 (gera/atualiza lista de vídeos)
#   --run download       : Passo 02 + 2.5 + 03 usando listas já criadas
#   --run transform-only : Reaplica somente as transformações (2.5/03) nos TXT existentes
#
# Saída:
#   downloads/<slug-do-canal>/
#     #NNN - Título {Palestrante}.txt   (texto com timestamps por fala)
#     id_<VIDEOID>.txt                  (metadados resumidos)
#     index.csv                         (índice geral)
#   data/<slug-do-canal>/videos.tsv     (lista Passo 01: <id>\t<title>)
#
#------------------------------------------------------------------------------

set -euo pipefail

# ---------- Aparência/cores (opcional) ----------
if command -v tput >/dev/null 2>&1; then
  bold="$(tput bold)"; dim="$(tput dim)"; reset="$(tput sgr0)"
  green="$(tput setaf 2)"; yellow="$(tput setaf 3)"; blue="$(tput setaf 4)"; red="$(tput setaf 1)"
else
  bold=""; dim=""; reset=""; green=""; yellow=""; blue=""; red=""
fi

# ---------- Configurações padrão ----------
LANG_CODES_DEFAULT="pt,pt-BR,pt-PT"
ROOT_OUT_DIR="downloads"
INDEX_DIR="data"
KEEP_SUBS="false"
SPEAKER_MODE="uploader"    # "uploader" | "fixed"
SPEAKER_FIXED=""
START_NUMBER="1"
RUN_MODE="all"             # all | list | download | transform-only
TRANSFORMS_FILE="transforms.txt"
SKIP_EXISTING="false"

# ---------- Ajuda ----------
usage() {
  cat <<EOF
${bold}Uso:${reset}
  $(basename "$0") --channels "<url1>,<url2>" [opções]

${bold}Parâmetros principais:${reset}
  --channels           Lista de URLs de canais, separadas por vírgula.
                       Ex.: "https://www.youtube.com/@redeauroraater,https://www.youtube.com/@oextensionista"

  --run                Modo de execução (default: all):
                         - all            : Passo 01 + 02 + 2.5 + 03 (tudo)
                         - list           : Somente Passo 01 (gerar/atualizar lista dos vídeos)
                         - download       : Passo 02 + 2.5 + 03, usando listas já geradas
                         - transform-only : Apenas Passo 2.5/03 nos TXT já existentes

${bold}Opções úteis:${reset}
  --lang               Códigos de legenda (ordem de preferência). Padrão: ${LANG_CODES_DEFAULT}
  --keep-subs          Mantém os .srt/.vtt baixados (off por padrão).
  --skip-existing      Pula vídeos já processados (por id_*.txt ou index.csv).
  --speaker-mode       "uploader" (padrão) ou "fixed"
  --speaker-name       Nome fixo do palestrante (usa com --speaker-mode fixed)
  --start-number       Número inicial do episódio por canal (default: 1)
  --transforms-file    Caminho para arquivo de transformações extras (default: ${TRANSFORMS_FILE})
EOF
}

# ---------- Dependências ----------
require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "${red}Erro:${reset} dependência ausente: '$1'. Instale antes de continuar." >&2
    exit 1
  fi
}

# In-place sed (portável para GNU/Linux e macOS/BSD)
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i -e "$1" "$2"
  else
    sed -i '' -e "$1" "$2"
  fi
}

# ---------- Utils ----------
slugify() {
  echo "$1" | sed -E 's#https?://(www\.)?youtube\.com/##; s#@##; s#[^a-zA-Z0-9._-]#-#g; s#-+#-#g; s#^[-]+|[-]+$##g'
}

sanitize_filename() {
  echo "$1" | sed -E 's/[\/:*?"<>|]/-/g; s/ +/ /g; s/ $//; s/^ //'
}

progress() {
  local idx="$1"; local total="$2"; local msg="$3"
  local pct=0
  if [[ "$total" -gt 0 ]]; then
    pct=$(( 100 * idx / total ))
  fi
  printf "%s[%d/%d %3d%%]%s %s\n" "$dim" "$idx" "$total" "$pct" "$reset" "$msg"
}

compose_basename() {
  local ep="$1"; local title="$2"; local speaker="$3"
  local prefix; prefix=$(printf "#%03d" "$ep")
  local body="$title"
  body=$(printf '%s' "$body" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+|[[:space:]]+$//g')
  if [[ -n "$speaker" ]]; then
    echo "$(sanitize_filename "$prefix - $body {$speaker}")"
  else
    echo "$(sanitize_filename "$prefix - $body")"
  fi
}

ensure_dirs() {
  mkdir -p "$ROOT_OUT_DIR" "$INDEX_DIR"
}

# ---------- Parser e transformações (Python embutido) ----------
py_convert_and_transform() {
python3 - "$@" <<'PY'
import sys, re
from pathlib import Path

inp = Path(sys.argv[1])
outp = Path(sys.argv[2])
transforms_file = Path(sys.argv[3]) if len(sys.argv) > 3 else None

text = inp.read_text(encoding='utf-8', errors='ignore')
ext = inp.suffix.lower()

if ext == '.vtt' and text.startswith('WEBVTT'):
    text = '\n'.join(text.splitlines()[1:])

blocks = re.split(r'\r?\n\r?\n+', text.strip())
entries = []

for block in blocks:
    lines = [ln.strip() for ln in block.splitlines() if ln.strip()]
    if not lines:
        continue
    if re.fullmatch(r'\d+', lines[0]):
        lines.pop(0)
    if not lines:
        continue
    timing_line = ""
    if '-->' in lines[0]:
        timing_line = lines.pop(0)
    if not lines:
        continue

    content = " ".join(lines)
    content = re.sub(r"<[^>]+>", "", content)
    content = re.sub(r"\s+", " ", content).strip()

    timestamp = ""
    if timing_line:
        m = re.search(r'(\d{1,2}):(\d{2}):(\d{2})', timing_line)
        if m:
            h, m_, s = map(int, m.groups())
            timestamp = f"{h:02d}:{m_:02d}:{s:02d}"

    if content:
        entries.append([content, timestamp])

lines_out = []
for content, ts in entries:
    lines_out.append(content)
    if ts:
        lines_out.append(f" {ts}")
    lines_out.append("")
result = "\n".join(lines_out).strip() + "\n"

def apply_basic_cleanup(t: str) -> str:
    t = re.sub(r"\[(?:m[uú]sica|aplausos?|risos?|ru[ií]dos?|barulhos?|barulho|suspira[cç][oõ]es?)\]", "", t, flags=re.IGNORECASE)
    t = re.sub(r"\((?:m[uú]sica|aplausos?|risos?|ru[ií]dos?|barulhos?|barulho|suspira[cç][oõ]es?)\)", "", t, flags=re.IGNORECASE)
    t = re.sub(r"^[\s\.\,\;\:!\?\"'\-\–\—]+$", "", t, flags=re.MULTILINE)
    t = re.sub(r"[ \t]+", " ", t)
    t = re.sub(r"\n +(\d{2}:\d{2}:\d{2})", r"\n \1", t)
    t = re.sub(r"…", "...", t)
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip() + "\n"

result = apply_basic_cleanup(result)

def apply_external_transforms(t: str, file: Path) -> str:
    if not file or not file.exists():
        return t
    for raw in file.read_text(encoding='utf-8', errors='ignore').splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^s/(.*?)/(.*?)/([a-zA-Z]*)$', line)
        if not m:
            continue
        pattern, repl, flags = m.groups()
        re_flags = 0
        if 'i' in flags: re_flags |= re.IGNORECASE
        if 'm' in flags: re_flags |= re.MULTILINE
        if 's' in flags: re_flags |= re.DOTALL
        if 'g' in flags:
            t = re.sub(pattern, repl, t, flags=re_flags)
        else:
            t = re.sub(pattern, repl, t, count=1, flags=re_flags)
    return t

result = apply_external_transforms(result, transforms_file)

outp.parent.mkdir(parents=True, exist_ok=True)
outp.write_text(result, encoding='utf-8')
PY
}

# ---------- Baixa legendas para um vídeo ----------
download_captions_for_video() {
  local video_url="$1"
  local langs_csv="$2"
  local keep_subs="$3"
  local out_dir="$4"
  local ep_number="$5"
  local speaker_mode="$6"
  local speaker_fixed="$7"
  local transforms_path="$8"

  local tmpdir
  tmpdir=$(mktemp -d)
  trap '[[ -n "${tmpdir:-}" && -d "$tmpdir" ]] && rm -rf "$tmpdir"' RETURN

  # --- Metadados do vídeo ---
  local title uploader id description upload_date
  title=$(yt-dlp --skip-download --no-warnings --print "%(title)s" "$video_url" 2>/dev/null || echo "Sem título")
  uploader=$(yt-dlp --skip-download --no-warnings --print "%(uploader)s" "$video_url" 2>/dev/null || echo "")
  id=$(yt-dlp --skip-download --no-warnings --print "%(id)s" "$video_url" 2>/dev/null || echo "")
  upload_date=$(yt-dlp --skip-download --no-warnings --print "%(upload_date)s" "$video_url" 2>/dev/null || echo "")

  description="$(
    yt-dlp -J --no-warnings "$video_url" 2>/dev/null \
    | python3 - <<'PY' 2>/dev/null || true
import sys, json
try:
    data = json.load(sys.stdin)
    desc = data.get("description", "") or ""
    if not isinstance(desc, str):
        desc = ""
    print(desc)
except Exception:
    pass
PY
  )"

  # Fallback: se descrição veio vazia, tenta via --print
  if [[ -z "$description" ]]; then
    description=$(yt-dlp --skip-download --no-warnings --print "%(description)s" "$video_url" 2>/dev/null || echo "")
  fi

  # Normaliza para evitar problemas de espaços estranhos
  description=$(printf "%s" "$description" | sed 's/\r$//')

  # --- Define palestrante (prioriza descrição) ---
  local speaker=""
  local lattes_url=""
  if [[ -n "$description" ]]; then
    local extracted=""
    local _py_tmp
    _py_tmp=$(mktemp)
    cat > "${_py_tmp}" <<'PY'
import sys, re
desc = sys.argv[1].replace('\r\n','\n').replace('\r','\n')

LABELS_BLOCK = (
    r'(?:palestrantes?|convidados?|convidada|convidado|'
    r'mediador(?:a)?|moderador(?:a)?|apresentador(?:a)?|ministrante|'
    r'participa[cç][aã]o|local|data|hor[aá]rio|transmiss[aã]o|tema|t[ií]tulo)'
)

def clean(s):
    s = s.replace('\u00A0', ' ').replace('\u200B','')
    s = re.sub(r'[ \t]+$', '', s)
    return s.strip()

lines = desc.split('\n')
speakers = []

# 1) Mesma linha: "Palestrante(s) :|-|–|—  <NOME>" (pode ter múltiplos separados por ';')
pat_same = re.compile(r'(?i)\bpalestrantes?\b\s*[:\-–—]+\s*(.+)$')
for ln in lines:
    m = pat_same.search(ln)
    if m:
        candidate = clean(m.group(1))
        candidate = re.sub(r'(?i)\b(?:cv\s+)?lattes\s*:.+$', '', candidate).strip()
        if candidate:
            parts = [p.strip() for p in re.split(r'\s*;\s*', candidate) if p.strip()]
            speakers.extend(parts or [candidate])

# 2) Rótulo sozinho → linhas seguintes (até 5), coletando múltiplos
pat_label_alone = re.compile(r'(?i)^[ \t]*palestrantes?[ \t]*(?:[:\-–—][ \t]*)?$')
i = 0
while i < len(lines):
    ln = lines[i]
    if pat_label_alone.match(ln):
        for j in range(i+1, min(i+6, len(lines))):
            cand = clean(lines[j])
            if not cand:
                continue
            if re.match(r'^https?://', cand, flags=re.I):
                continue
            if re.match(r'(?i)^[ \t]*' + LABELS_BLOCK + r'\b[ \t]*[:\-–—]?', cand):
                break
            # divide em múltiplos se vierem numa única linha
            parts = [p.strip() for p in re.split(r'\s*;\s*', cand) if p.strip()]
            speakers.extend(parts or [cand])
        break
    i += 1

# Normaliza e imprime único, preservando ordem
out = []
seen = set()
for s in speakers:
    if s and s not in seen:
        out.append(s)
        seen.add(s)
if out:
    print('; '.join(out))
PY
    extracted="$(python3 "${_py_tmp}" "$description" 2>/dev/null || true)"
    rm -f "${_py_tmp}"
    if [[ -n "$extracted" ]]; then
      speaker="$extracted"
    fi

    # Extrai primeiro link Lattes, se houver (via Python, removendo possíveis códigos ANSI)
    lattes_url="$(
      python3 - "$description" <<'PY' 2>/dev/null || true
import sys, re
d = sys.argv[1]
url = None
m = re.search(r'https?://lattes\.cnpq\.br/[A-Za-z0-9/_-]+', d)
if m:
    url = m.group(0)
if url:
    # remove sequências ANSI caso existam
    url = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', url)
    url = re.sub(r'\[[0-9;]*m\[K', '', url)
    url = re.sub(r'\[[0-9;]*m', '', url)
    print(url)
PY
    )"
  fi

  if [[ -z "$speaker" ]]; then
    if [[ "$speaker_mode" == "fixed" && -n "$speaker_fixed" ]]; then
      speaker="$speaker_fixed"
    else
      speaker="$uploader"
    fi
  fi

  # --- Download das legendas ---
  IFS=',' read -ra langs <<< "$langs_csv"
  local subtitle_file=""; local detected_lang=""; local subtitle_mode=""

  for lang in "${langs[@]}"; do
    yt-dlp --skip-download --write-sub --sub-langs "$lang" \
      --convert-subs "srt" --sub-format "srt/srv3/vtt" \
      --output "$tmpdir/%(id)s.%(ext)s" "$video_url" >/dev/null 2>&1 || true
    subtitle_file=$(find "$tmpdir" -maxdepth 1 -type f \( -name "*.${lang}.srt" -o -name "*.${lang}.vtt" \) -print -quit)
    if [[ -n "$subtitle_file" ]]; then detected_lang="$lang"; subtitle_mode="manual"; break; fi
  done

  if [[ -z "$subtitle_file" ]]; then
    for lang in "${langs[@]}"; do
      yt-dlp --skip-download --write-auto-sub --write-auto-subs --sub-langs "$lang" \
        --convert-subs "srt" --sub-format "srt/srv3/vtt" \
        --output "$tmpdir/%(id)s.%(ext)s" "$video_url" >/dev/null 2>&1 || true
      subtitle_file=$(find "$tmpdir" -maxdepth 1 -type f \( -name "*.${lang}.srt" -o -name "*.${lang}.vtt" \) -print -quit)
      if [[ -n "$subtitle_file" ]]; then detected_lang="$lang"; subtitle_mode="auto"; break; fi
    done
  fi

  if [[ -z "$subtitle_file" ]]; then
    echo "${yellow}Aviso:${reset} sem legendas para ${video_url} nas línguas: $langs_csv"
    return 1
  fi

  # --- Saídas ---
  local basename; basename=$(compose_basename "$ep_number" "$title" "$speaker")
  local txt_out="${out_dir}/${basename}.txt"
  local id_txt="${out_dir}/id_${id}.txt"
  # Formata data (upload_date -> MM/DD/YYYY)
  local date_fmt=""
  if [[ "$upload_date" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})$ ]]; then
    date_fmt="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}/${BASH_REMATCH[1]}"
  fi

  {
    echo "video_id: ${id}"
    echo "video_url: https://www.youtube.com/watch?v=${id}"
    echo "title: ${title}"
    echo "uploader: ${uploader}"
    echo "speaker: ${speaker}"
    if [[ -n "$lattes_url" ]]; then echo "Lattes: ${lattes_url}"; fi
    echo "subtitle_mode: ${subtitle_mode}"
    echo "subtitle_lang: ${detected_lang}"
    if [[ -n "$date_fmt" ]]; then echo "date: ${date_fmt}"; fi
  } > "$id_txt"

  py_convert_and_transform "$subtitle_file" "$txt_out" "$transforms_path"

  if [[ "$keep_subs" == "true" ]]; then
    local base_noext="${out_dir}/${basename}"
    if [[ "$subtitle_file" == *.vtt ]]; then
      mv "$subtitle_file" "${base_noext}.${detected_lang}.vtt"
      echo "${dim}Salvo VTT:${reset} ${base_noext}.${detected_lang}.vtt"
    else
      mv "$subtitle_file" "${base_noext}.${detected_lang}.srt"
      echo "${dim}Salvo SRT:${reset} ${base_noext}.${detected_lang}.srt"
    fi
  fi

  local csv="${out_dir}/index.csv"
  if [[ ! -f "$csv" ]]; then
    echo "ep_number,video_id,video_url,title,speaker,subtitle_mode,lang,txt_path" > "$csv"
  fi
  echo "${ep_number},${id},https://www.youtube.com/watch?v=${id},\"${title}\",\"${speaker}\",${subtitle_mode},${detected_lang},\"${txt_out}\"" >> "$csv"

  rm -rf "$tmpdir"
  trap - RETURN
}

# ---------- Lista vídeos do canal (Passo 01) ----------
list_videos_for_channel() {
  local channel_url="$1"
  local out_list="$2"
  if ! yt-dlp --flat-playlist --skip-download --no-warnings \
      --print "%(id)s\t%(title)s" "$channel_url" > "$out_list"; then
    echo "${red}Erro:${reset} Falha ao listar vídeos do canal: $channel_url"
    return 1
  fi
  # Remove linhas vazias (GNU/macOS)
  sed_inplace '/^[[:space:]]*$/d' "$out_list"
}

# ---------- Orquestração por canal ----------
run_for_channel() {
  local channel_url="$1"
  local langs_csv="$2"
  local keep_subs="$3"
  local speaker_mode="$4"
  local speaker_fixed="$5"
  local start_number="$6"
  local transforms_global="$7"
  local mode="$8"

  local channel_slug; channel_slug=$(slugify "$channel_url")
  local channel_dir="${ROOT_OUT_DIR}/${channel_slug}"
  local list_dir="${INDEX_DIR}/${channel_slug}"
  local list_file="${list_dir}/videos.tsv"
  local transforms_path="$transforms_global"

  mkdir -p "$channel_dir" "$list_dir"

  if [[ -f "${channel_dir}/${TRANSFORMS_FILE}" ]]; then
    transforms_path="${channel_dir}/${TRANSFORMS_FILE}"
  fi

  echo "${bold}${blue}Canal:${reset} ${channel_url}  ${dim}(slug: ${channel_slug})${reset}"

  if [[ "$mode" == "all" || "$mode" == "list" ]]; then
    echo "${bold}Passo 01:${reset} Listando vídeos..."
    list_videos_for_channel "$channel_url" "$list_file"
    local count; count=$(wc -l < "$list_file" | tr -d ' ')
    echo "  ${green}OK${reset}: ${count} vídeos listados → ${list_file}"
    [[ "$mode" == "list" ]] && return 0
  fi

  if [[ "$mode" == "all" || "$mode" == "download" ]]; then
    if [[ ! -f "$list_file" ]]; then
      echo "${yellow}Aviso:${reset} lista não encontrada; gerando agora..."
      list_videos_for_channel "$channel_url" "$list_file"
    fi
    echo "${bold}Passo 02:${reset} Baixando legendas e convertendo"
    local total; total=$(wc -l < "$list_file" | tr -d ' ')
    local idx=0; local ep="$start_number"
    while IFS=$'\t' read -r vid vid_title; do
      [[ -z "$vid" ]] && continue
      idx=$((idx+1))
      # Skip se já processado
      if [[ "$SKIP_EXISTING" == "true" ]]; then
        if [[ -f "${channel_dir}/id_${vid}.txt" ]]; then
          progress "$idx" "$total" "Pulado (existente por id): ${vid_title}"
          continue
        fi
        if [[ -f "${channel_dir}/index.csv" ]] && grep -q ",${vid}," "${channel_dir}/index.csv"; then
          progress "$idx" "$total" "Pulado (existente no índice): ${vid_title}"
          continue
        fi
      fi

      progress "$idx" "$total" "Processando #$(printf "%03d" "$ep") - ${vid_title}"
      local video_url="https://www.youtube.com/watch?v=${vid}"
      if download_captions_for_video "$video_url" "$langs_csv" "$keep_subs" "$channel_dir" "$ep" "$speaker_mode" "$speaker_fixed" "$transforms_path"; then
        ep=$((ep+1))
      else
        echo "${yellow}Pulado (falha):${reset} ${video_url}"
      fi
    done < "$list_file"
  fi

  if [[ "$mode" == "transform-only" ]]; then
    echo "${bold}Passo 2.5:${reset} Reaplicando transformações em TXT existentes"
    shopt -s nullglob
    local txts=("${channel_dir}"/*.txt)
    local total=${#txts[@]}
    if [[ "$total" -eq 0 ]]; then
      echo "${yellow}Aviso:${reset} nenhum .txt encontrado em ${channel_dir}"
      return 0
    fi
    local idx=0
    for f in "${txts[@]}"; do
      idx=$((idx+1))
      progress "$idx" "$total" "Transformando novamente: $(basename "$f")"
      local tmp_out; tmp_out="$(mktemp)"
      py_convert_and_transform "$f" "$tmp_out" "$transforms_path"
      mv "$tmp_out" "$f"
    done
  fi
}

# ---------- Parse CLI ----------
CHANNELS=""
LANG_CODES="$LANG_CODES_DEFAULT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channels) CHANNELS="$2"; shift 2 ;;
    --run) RUN_MODE="$2"; shift 2 ;;
    --lang) LANG_CODES="$2"; shift 2 ;;
    --keep-subs) KEEP_SUBS="true"; shift ;;
    --skip-existing) SKIP_EXISTING="true"; shift ;;
    --speaker-mode) SPEAKER_MODE="$2"; shift 2 ;;
    --speaker-name) SPEAKER_FIXED="$2"; shift 2 ;;
    --start-number) START_NUMBER="$2"; shift 2 ;;
    --transforms-file) TRANSFORMS_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "${red}Opção desconhecida:${reset} $1" >&2; usage; exit 1 ;;
  esac
done

# ---------- Validações ----------
require_bin yt-dlp
require_bin python3
require_bin mktemp
require_bin sed
require_bin awk

if [[ -z "$CHANNELS" ]]; then
  echo "${red}Erro:${reset} --channels é obrigatório."
  usage; exit 1
fi

if [[ "$SPEAKER_MODE" == "fixed" && -z "$SPEAKER_FIXED" ]]; then
  echo "${yellow}Aviso:${reset} --speaker-mode=fixed sem --speaker-name; usará vazio."
fi

case "$RUN_MODE" in
  all|list|download|transform-only) ;;
  *) echo "${red}Erro:${reset} --run deve ser: all | list | download | transform-only"; exit 1 ;;
esac

ensure_dirs

# ---------- Execução ----------
IFS=',' read -ra CHANNEL_ARR <<< "$CHANNELS"
for ch in "${CHANNEL_ARR[@]}"; do
  run_for_channel "$ch" "$LANG_CODES" "$KEEP_SUBS" "$SPEAKER_MODE" "$SPEAKER_FIXED" "$START_NUMBER" "$TRANSFORMS_FILE" "$RUN_MODE"
done

echo "${green}${bold}Concluído.${reset}"
