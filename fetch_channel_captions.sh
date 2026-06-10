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
# Dependências: yt-dlp, python3, sed, awk, mktemp
# Sem chaves de API — acessa apenas conteúdo público do YouTube.
#------------------------------------------------------------------------------

# SEGURANÇA DO SCRIPT:
#   -e  : encerra imediatamente se qualquer comando retornar erro
#   -u  : trata variável não definida como erro (evita bugs silenciosos)
#   -o pipefail : propaga erro de qualquer etapa de um pipeline (cmd1 | cmd2)
set -euo pipefail

# ---------- Aparência/cores (opcional) ----------
# Detecta suporte a formatação terminal via tput.
# Se não disponível (ex: CI/CD sem TTY), usa strings vazias.
if command -v tput >/dev/null 2>&1; then
  bold="$(tput bold)"; dim="$(tput dim)"; reset="$(tput sgr0)"
  green="$(tput setaf 2)"; yellow="$(tput setaf 3)"; blue="$(tput setaf 4)"; red="$(tput setaf 1)"
else
  bold=""; dim=""; reset=""; green=""; yellow=""; blue=""; red=""
fi

# ---------- Configurações padrão ----------
# Todos os parâmetros abaixo podem ser sobrescritos via linha de comando.
# A ordem de preferência de idiomas: pt genérico, depois pt-BR, depois pt-PT.
# Isso garante que legendas manuais em qualquer variante do português sejam aceitas.
LANG_CODES_DEFAULT="pt,pt-BR,pt-PT"

# Diretório raiz onde ficam as pastas de cada canal com transcrições
ROOT_OUT_DIR="downloads"

# Diretório onde ficam os arquivos TSV de listagem de vídeos (Passo 01)
INDEX_DIR="data"

# Por padrão, apaga os .srt/.vtt após converter para .txt
KEEP_SUBS="false"

# "uploader" usa o nome do canal como palestrante (fallback)
# "fixed"    usa o nome definido em --speaker-name para todos os vídeos
SPEAKER_MODE="uploader"
SPEAKER_FIXED=""

# Número de episódio inicial (incrementa a cada vídeo processado com sucesso)
START_NUMBER="1"

# Modo de execução padrão: roda tudo
RUN_MODE="all"

# Caminho padrão do arquivo de transformações textuais (Passo 2.5)
TRANSFORMS_FILE="transforms.txt"

# Se "true", pula vídeos que já têm id_*.txt ou registro no index.csv
SKIP_EXISTING="false"

# ---------- Ajuda ----------
# Exibe instruções de uso quando chamado com -h ou --help.
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
# Verifica se um binário está disponível no PATH.
# Encerra o script com erro descritivo se estiver faltando.
require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "${red}Erro:${reset} dependência ausente: '$1'. Instale antes de continuar." >&2
    exit 1
  fi
}

# Wrapper portável para sed -i (edição in-place):
# - GNU sed (Linux): aceita -i -e "expressão"
# - BSD sed (macOS): exige -i '' -e "expressão" (o '' é o backup suffix vazio)
# A detecção é feita testando se `sed --version` funciona (GNU) ou não (BSD).
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i -e "$1" "$2"
  else
    sed -i '' -e "$1" "$2"
  fi
}

# ---------- Utils ----------

# Converte uma URL de canal YouTube em um slug de pasta seguro.
# Ex: "https://www.youtube.com/@oextensionista" → "oextensionista"
# Passos:
#   1) Remove o prefixo https://(www.)youtube.com/
#   2) Remove o @
#   3) Substitui qualquer caractere não alfanumérico/ponto/hífen por hífen
#   4) Colapsa hífens consecutivos em um só
#   5) Remove hífens nas bordas
slugify() {
  echo "$1" | sed -E 's#https?://(www\.)?youtube\.com/##; s#@##; s#[^a-zA-Z0-9._-]#-#g; s#-+#-#g; s#^[-]+|[-]+$##g'
}

# Remove caracteres inválidos para nomes de arquivo em sistemas de arquivo comuns.
# Substitui \ / : * ? " < > | por hífens e normaliza espaços múltiplos.
sanitize_filename() {
  echo "$1" | sed -E 's/[\/:*?"<>|]/-/g; s/ +/ /g; s/ $//; s/^ //'
}

# Exibe linha de progresso no formato: [idx/total  XX%] mensagem
# Útil para acompanhar o processamento de listas longas de vídeos.
progress() {
  local idx="$1"; local total="$2"; local msg="$3"
  local pct=0
  if [[ "$total" -gt 0 ]]; then
    pct=$(( 100 * idx / total ))
  fi
  printf "%s[%d/%d %3d%%]%s %s\n" "$dim" "$idx" "$total" "$pct" "$reset" "$msg"
}

# Monta o nome base do arquivo de transcrição no padrão:
#   "#NNN - Título {Palestrante}"
# onde NNN é o número do episódio com 3 dígitos (ex: #001, #042).
# Se não houver palestrante, omite a parte entre chaves.
# O resultado passa por sanitize_filename para garantir nome válido.
compose_basename() {
  local ep="$1"; local title="$2"; local speaker="$3"
  local prefix; prefix=$(printf "#%03d" "$ep")
  local body="$title"
  # Normaliza espaços do título (remove múltiplos/bordas)
  body=$(printf '%s' "$body" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+|[[:space:]]+$//g')
  if [[ -n "$speaker" ]]; then
    echo "$(sanitize_filename "$prefix - $body {$speaker}")"
  else
    echo "$(sanitize_filename "$prefix - $body")"
  fi
}

# Cria os diretórios raiz de saída se ainda não existirem.
ensure_dirs() {
  mkdir -p "$ROOT_OUT_DIR" "$INDEX_DIR"
}

# ---------- Parser e transformações (Python embutido) ----------
#
# Esta função recebe até 3 argumentos:
#   $1: arquivo de entrada (SRT ou VTT)
#   $2: arquivo de saída (TXT com timestamps)
#   $3: (opcional) caminho para transforms.txt externo
#
# O código Python é passado via heredoc (<<'PY'...'PY') diretamente para
# `python3 -` (lê stdin como script). O uso de aspas simples no 'PY' previne
# que o Bash expanda variáveis dentro do bloco Python.
#
# Por que Python e não awk/sed?
#   - SRT/VTT são formatos em blocos (múltiplas linhas por entrada)
#   - Python trata Unicode nativamente (acentos, emojis, ♪)
#   - Expressões regulares Python são mais expressivas para limpezas complexas
py_convert_and_transform() {
python3 - "$@" <<'PY'
import sys, re
from pathlib import Path

# Recebe argumentos posicionais do Bash
inp = Path(sys.argv[1])          # arquivo de entrada: .srt ou .vtt
outp = Path(sys.argv[2])         # arquivo de saída: .txt
transforms_file = Path(sys.argv[3]) if len(sys.argv) > 3 else None

# Lê o arquivo ignorando erros de encoding (caracteres malformados)
text = inp.read_text(encoding='utf-8', errors='ignore')
ext = inp.suffix.lower()

# VTT começa com "WEBVTT" + cabeçalho opcional; remove a primeira linha
if ext == '.vtt' and text.startswith('WEBVTT'):
    text = '\n'.join(text.splitlines()[1:])

# Divide o texto em blocos separados por linha(s) em branco.
# Cada bloco SRT/VTT contém: [número] + [timestamps] + [texto(s)]
blocks = re.split(r'\r?\n\r?\n+', text.strip())
entries = []

for block in blocks:
    # Limpa cada linha interna e descarta as vazias
    lines = [ln.strip() for ln in block.splitlines() if ln.strip()]
    if not lines:
        continue

    # SRT começa o bloco com um número sequencial (1, 2, 3…) — remove-o
    if re.fullmatch(r'\d+', lines[0]):
        lines.pop(0)
    if not lines:
        continue

    # A linha de timing tem o formato: 00:00:00,000 --> 00:00:02,500
    timing_line = ""
    if '-->' in lines[0]:
        timing_line = lines.pop(0)
    if not lines:
        continue

    # Junta as linhas de conteúdo do bloco em uma única string
    content = " ".join(lines)
    # Remove tags HTML/VTT (ex: <b>, <c.yellow>, <00:00:01.000>)
    content = re.sub(r"<[^>]+>", "", content)
    # Normaliza espaços múltiplos
    content = re.sub(r"\s+", " ", content).strip()

    # Extrai apenas HH:MM:SS do início do timing (descarta milissegundos)
    timestamp = ""
    if timing_line:
        m = re.search(r'(\d{1,2}):(\d{2}):(\d{2})', timing_line)
        if m:
            h, m_, s = map(int, m.groups())
            timestamp = f"{h:02d}:{m_:02d}:{s:02d}"

    if content:
        entries.append([content, timestamp])

# Monta o texto de saída: cada entrada tem texto + timestamp em linhas separadas,
# com uma linha em branco entre entradas para facilitar a leitura e o parse posterior
lines_out = []
for content, ts in entries:
    lines_out.append(content)
    if ts:
        lines_out.append(f" {ts}")   # timestamp indentado com espaço inicial
    lines_out.append("")             # linha em branco separadora
result = "\n".join(lines_out).strip() + "\n"

# ── Limpeza básica embutida (Passo 2.5) ────────────────────────────────────
# Aplicada sempre, independente de transforms.txt existir ou não.
def apply_basic_cleanup(t: str) -> str:
    # Remove marcadores de sons não-verbais entre colchetes: [Música], [Aplausos], etc.
    t = re.sub(r"\[(?:m[uú]sica|aplausos?|risos?|ru[ií]dos?|barulhos?|barulho|suspira[cç][oõ]es?)\]", "", t, flags=re.IGNORECASE)
    # Mesmos marcadores entre parênteses: (música), (aplausos), etc.
    t = re.sub(r"\((?:m[uú]sica|aplausos?|risos?|ru[ií]dos?|barulhos?|barulho|suspira[cç][oõ]es?)\)", "", t, flags=re.IGNORECASE)
    # Remove linhas que após a limpeza ficaram só com pontuação ou espaços
    t = re.sub(r"^[\s\.\,\;\:!\?\"'\-\–\—]+$", "", t, flags=re.MULTILINE)
    # Colapsa múltiplos espaços/tabs em um espaço simples
    t = re.sub(r"[ \t]+", " ", t)
    # Garante que timestamps indentados permaneçam com um único espaço à esquerda
    t = re.sub(r"\n +(\d{2}:\d{2}:\d{2})", r"\n \1", t)
    # Converte reticências Unicode (…) para três pontos ASCII (...)
    t = re.sub(r"…", "...", t)
    # Colapsa três ou mais linhas em branco consecutivas em duas
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip() + "\n"

result = apply_basic_cleanup(result)

# ── Transformações externas (transforms.txt) ────────────────────────────────
# Lê o arquivo de transformações linha a linha.
# Formato aceito: s/regex/substituto/flags   (estilo sed)
# Linhas vazias e comentários (#) são ignorados.
def apply_external_transforms(t: str, file: Path) -> str:
    if not file or not file.exists():
        return t
    for raw in file.read_text(encoding='utf-8', errors='ignore').splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # Regex para extrair padrão/substituto/flags da sintaxe s/A/B/flags
        m = re.match(r'^s/(.*?)/(.*?)/([a-zA-Z]*)$', line)
        if not m:
            continue
        pattern, repl, flags = m.groups()
        re_flags = 0
        if 'i' in flags: re_flags |= re.IGNORECASE
        if 'm' in flags: re_flags |= re.MULTILINE
        if 's' in flags: re_flags |= re.DOTALL
        # 'g' em sed = substituir todas as ocorrências; sem 'g' = apenas a primeira
        if 'g' in flags:
            t = re.sub(pattern, repl, t, flags=re_flags)
        else:
            t = re.sub(pattern, repl, t, count=1, flags=re_flags)
    return t

result = apply_external_transforms(result, transforms_file)

# Cria o diretório de saída se necessário e grava o arquivo final
outp.parent.mkdir(parents=True, exist_ok=True)
outp.write_text(result, encoding='utf-8')
PY
}

# ---------- Baixa legendas para um vídeo ----------
#
# Esta é a função central do Passo 02. Para cada vídeo:
#   1) Consulta metadados (título, uploader, id, data, descrição)
#   2) Extrai nome do palestrante da descrição (via Python inline)
#   3) Tenta baixar legenda manual; se falhar, baixa a automática
#   4) Converte SRT/VTT → TXT com timestamps (chama py_convert_and_transform)
#   5) Grava id_<ID>.txt com metadados e linha no index.csv
#
# Parâmetros:
#   $1  video_url       URL completa do vídeo
#   $2  langs_csv       Idiomas separados por vírgula (ex: "pt,pt-BR")
#   $3  keep_subs       "true" para manter .srt/.vtt
#   $4  out_dir         Pasta de saída do canal
#   $5  ep_number       Número sequencial do episódio
#   $6  speaker_mode    "uploader" ou "fixed"
#   $7  speaker_fixed   Nome fixo (usado quando speaker_mode=fixed)
#   $8  transforms_path Caminho do arquivo de transformações
download_captions_for_video() {
  local video_url="$1"
  local langs_csv="$2"
  local keep_subs="$3"
  local out_dir="$4"
  local ep_number="$5"
  local speaker_mode="$6"
  local speaker_fixed="$7"
  local transforms_path="$8"

  # Cria diretório temporário isolado para os arquivos de legenda baixados.
  # A trap garante que o tmpdir seja removido mesmo se o script falhar ou
  # for interrompido (RETURN = ao sair da função, por qualquer motivo).
  local tmpdir
  tmpdir=$(mktemp -d)
  trap '[[ -n "${tmpdir:-}" && -d "$tmpdir" ]] && rm -rf "$tmpdir"' RETURN

  # --- Coleta de metadados do vídeo via yt-dlp ---
  # --skip-download : consulta apenas metadados, sem baixar vídeo/áudio
  # --no-warnings   : suprime avisos de formato (mais saída limpa)
  # --print         : imprime um campo específico dos metadados
  # 2>/dev/null     : descarta stderr (erros de rede, etc.)
  # || echo "..."   : valor de fallback se o comando falhar
  local title uploader id description upload_date
  title=$(yt-dlp --skip-download --no-warnings --print "%(title)s" "$video_url" 2>/dev/null || echo "Sem título")
  uploader=$(yt-dlp --skip-download --no-warnings --print "%(uploader)s" "$video_url" 2>/dev/null || echo "")
  id=$(yt-dlp --skip-download --no-warnings --print "%(id)s" "$video_url" 2>/dev/null || echo "")
  upload_date=$(yt-dlp --skip-download --no-warnings --print "%(upload_date)s" "$video_url" 2>/dev/null || echo "")

  # Obtém a descrição completa via JSON (-J) para preservar quebras de linha.
  # --print "%(description)s" às vezes trunca ou formata diferente.
  # O Python inline extrai o campo "description" do JSON com segurança.
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

  # Fallback: se a descrição veio vazia (ex: vídeo privado ou problema de rede),
  # tenta obter via --print (menos confiável para textos longos)
  if [[ -z "$description" ]]; then
    description=$(yt-dlp --skip-download --no-warnings --print "%(description)s" "$video_url" 2>/dev/null || echo "")
  fi

  # Remove carriage returns (\r) que às vezes aparecem em textos vindos da API
  description=$(printf "%s" "$description" | sed 's/\r$//')

  # --- Extração do palestrante a partir da descrição ---
  # Prioridade: descrição do vídeo > speaker_mode (uploader ou fixed)
  local speaker=""
  local lattes_url=""
  if [[ -n "$description" ]]; then
    local extracted=""
    local _py_tmp
    _py_tmp=$(mktemp)
    # Script Python gravado em arquivo temporário para evitar problemas de
    # escaping quando a descrição contém aspas, barras ou caracteres especiais.
    cat > "${_py_tmp}" <<'PY'
import sys, re
desc = sys.argv[1].replace('\r\n','\n').replace('\r','\n')

# Rótulos que indicam seções na descrição (usados como delimitadores/stop words)
LABELS_BLOCK = (
    r'(?:palestrantes?|convidados?|convidada|convidado|'
    r'mediador(?:a)?|moderador(?:a)?|apresentador(?:a)?|ministrante|'
    r'participa[cç][aã]o|local|data|hor[aá]rio|transmiss[aã]o|tema|t[ií]tulo)'
)

def clean(s):
    # Remove espaços não-quebráveis, espaços zero-width e espaços nas bordas
    s = s.replace('\u00A0', ' ').replace('\u200B','')
    s = re.sub(r'[ \t]+$', '', s)
    return s.strip()

lines = desc.split('\n')
speakers = []

# Estratégia 1: "Palestrante(s): Nome" ou "Palestrante - Nome" na mesma linha
# Suporta múltiplos nomes separados por ponto-e-vírgula
pat_same = re.compile(r'(?i)\bpalestrantes?\b\s*[:\-–—]+\s*(.+)$')
for ln in lines:
    m = pat_same.search(ln)
    if m:
        candidate = clean(m.group(1))
        # Remove possível link Lattes que apareça após o nome
        candidate = re.sub(r'(?i)\b(?:cv\s+)?lattes\s*:.+$', '', candidate).strip()
        if candidate:
            parts = [p.strip() for p in re.split(r'\s*;\s*', candidate) if p.strip()]
            speakers.extend(parts or [candidate])

# Estratégia 2: Rótulo "Palestrante(s)" sozinho em uma linha,
# seguido pelo nome(s) nas próximas linhas (até 5)
pat_label_alone = re.compile(r'(?i)^[ \t]*palestrantes?[ \t]*(?:[:\-–—][ \t]*)?$')
i = 0
while i < len(lines):
    ln = lines[i]
    if pat_label_alone.match(ln):
        for j in range(i+1, min(i+6, len(lines))):
            cand = clean(lines[j])
            if not cand:
                continue
            # Ignora linhas que são URLs
            if re.match(r'^https?://', cand, flags=re.I):
                continue
            # Para se encontrar outro rótulo de seção
            if re.match(r'(?i)^[ \t]*' + LABELS_BLOCK + r'\b[ \t]*[:\-–—]?', cand):
                break
            # Divide múltiplos nomes na mesma linha (separados por ;)
            parts = [p.strip() for p in re.split(r'\s*;\s*', cand) if p.strip()]
            speakers.extend(parts or [cand])
        break
    i += 1

# Deduplica preservando ordem de aparecimento
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

    # Extrai o primeiro link Lattes do CNPq da descrição, se houver.
    # O link é salvo no id_*.txt para rastreabilidade acadêmica.
    # A limpeza de códigos ANSI é necessária porque yt-dlp pode incluí-los
    # em saídas de terminal mesmo com redirecionamento.
    lattes_url="$(
      python3 - "$description" <<'PY' 2>/dev/null || true
import sys, re
d = sys.argv[1]
url = None
m = re.search(r'https?://lattes\.cnpq\.br/[A-Za-z0-9/_-]+', d)
if m:
    url = m.group(0)
if url:
    # Remove sequências de escape ANSI (ex: \x1b[32m) que podem contaminar a URL
    url = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', url)
    url = re.sub(r'\[[0-9;]*m\[K', '', url)
    url = re.sub(r'\[[0-9;]*m', '', url)
    print(url)
PY
    )"
  fi

  # Hierarquia para definir o nome do palestrante:
  # 1°) Extraído da descrição (mais preciso)
  # 2°) Nome fixo via --speaker-name (se speaker_mode=fixed)
  # 3°) Nome do canal (uploader) como último recurso
  if [[ -z "$speaker" ]]; then
    if [[ "$speaker_mode" == "fixed" && -n "$speaker_fixed" ]]; then
      speaker="$speaker_fixed"
    else
      speaker="$uploader"
    fi
  fi

  # --- Download das legendas ---
  # Converte langs_csv ("pt,pt-BR,pt-PT") em array Bash para iterar
  IFS=',' read -ra langs <<< "$langs_csv"
  local subtitle_file=""; local detected_lang=""; local subtitle_mode=""

  # Tentativa 1: Legendas MANUAIS (criadas pelo criador do vídeo)
  # São preferidas pois têm melhor qualidade e revisão humana.
  # --write-sub      : baixa legenda manual
  # --sub-langs      : idioma específico a tentar
  # --convert-subs   : converte qualquer formato para SRT
  # --sub-format     : ordem de preferência de formato: srt > srv3 > vtt
  # || true          : impede que falha quebre o script (alguns vídeos não têm legenda manual)
  for lang in "${langs[@]}"; do
    yt-dlp --skip-download --write-sub --sub-langs "$lang" \
      --convert-subs "srt" --sub-format "srt/srv3/vtt" \
      --output "$tmpdir/%(id)s.%(ext)s" "$video_url" >/dev/null 2>&1 || true
    # Procura arquivo gerado; -quit retorna o primeiro encontrado
    subtitle_file=$(find "$tmpdir" -maxdepth 1 -type f \( -name "*.${lang}.srt" -o -name "*.${lang}.vtt" \) -print -quit)
    if [[ -n "$subtitle_file" ]]; then detected_lang="$lang"; subtitle_mode="manual"; break; fi
  done

  # Tentativa 2: Legendas AUTOMÁTICAS (geradas por IA do YouTube / Whisper)
  # Fallback quando não há legenda manual em nenhum idioma preferido.
  # --write-auto-sub / --write-auto-subs : flags equivalentes para legendas automáticas
  if [[ -z "$subtitle_file" ]]; then
    for lang in "${langs[@]}"; do
      yt-dlp --skip-download --write-auto-sub --write-auto-subs --sub-langs "$lang" \
        --convert-subs "srt" --sub-format "srt/srv3/vtt" \
        --output "$tmpdir/%(id)s.%(ext)s" "$video_url" >/dev/null 2>&1 || true
      subtitle_file=$(find "$tmpdir" -maxdepth 1 -type f \( -name "*.${lang}.srt" -o -name "*.${lang}.vtt" \) -print -quit)
      if [[ -n "$subtitle_file" ]]; then detected_lang="$lang"; subtitle_mode="auto"; break; fi
    done
  fi

  # Se não encontrou legenda em nenhum formato/idioma, avisa e pula o vídeo
  if [[ -z "$subtitle_file" ]]; then
    echo "${yellow}Aviso:${reset} sem legendas para ${video_url} nas línguas: $langs_csv"
    return 1
  fi

  # --- Saídas padronizadas ---
  local basename; basename=$(compose_basename "$ep_number" "$title" "$speaker")
  local txt_out="${out_dir}/${basename}.txt"
  local id_txt="${out_dir}/id_${id}.txt"

  # Formata a data de upload de YYYYMMDD para MM/DD/YYYY (compatibilidade com CSV)
  local date_fmt=""
  if [[ "$upload_date" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})$ ]]; then
    date_fmt="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}/${BASH_REMATCH[1]}"
  fi

  # Grava arquivo de metadados do vídeo (id_<VIDEOID>.txt)
  # Este arquivo serve para process_transcripts.py correlacionar transcrição ↔ metadados.
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

  # Converte SRT/VTT → TXT com timestamps e aplica todas as transformações
  py_convert_and_transform "$subtitle_file" "$txt_out" "$transforms_path"

  # Se --keep-subs foi passado, copia o arquivo original para a pasta de saída
  # com o mesmo nome base da transcrição (mas com extensão .srt ou .vtt)
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

  # Adiciona registro ao index.csv do canal.
  # Cria o arquivo com cabeçalho se ainda não existir.
  local csv="${out_dir}/index.csv"
  if [[ ! -f "$csv" ]]; then
    echo "ep_number,video_id,video_url,title,speaker,subtitle_mode,lang,txt_path" > "$csv"
  fi
  echo "${ep_number},${id},https://www.youtube.com/watch?v=${id},\"${title}\",\"${speaker}\",${subtitle_mode},${detected_lang},\"${txt_out}\"" >> "$csv"

  # Remove tmpdir manualmente (a trap também faria, mas ser explícito é bom)
  rm -rf "$tmpdir"
  trap - RETURN
}

# ---------- Lista vídeos do canal (Passo 01) ----------
#
# Usa o modo --flat-playlist do yt-dlp para listar todos os vídeos do canal
# sem baixar nada. Salva o resultado em formato TSV: <id>\t<título>
#
# Parâmetros:
#   $1  channel_url  URL do canal YouTube
#   $2  out_list     Caminho do arquivo TSV de saída
list_videos_for_channel() {
  local channel_url="$1"
  local out_list="$2"
  if ! yt-dlp --flat-playlist --skip-download --no-warnings \
      --print "%(id)s\t%(title)s" "$channel_url" > "$out_list"; then
    echo "${red}Erro:${reset} Falha ao listar vídeos do canal: $channel_url"
    return 1
  fi
  # Remove linhas completamente vazias que podem surgir em alguns canais
  sed_inplace '/^[[:space:]]*$/d' "$out_list"
}

# ---------- Orquestração por canal ----------
#
# Função principal que coordena todos os passos para um único canal.
# É chamada uma vez para cada canal informado em --channels.
#
# Parâmetros (na ordem):
#   $1  channel_url       URL do canal
#   $2  langs_csv         Idiomas de legenda
#   $3  keep_subs         "true"/"false"
#   $4  speaker_mode      "uploader"/"fixed"
#   $5  speaker_fixed     Nome fixo (se mode=fixed)
#   $6  start_number      Número inicial do episódio
#   $7  transforms_global Caminho do transforms.txt global
#   $8  mode              "all"|"list"|"download"|"transform-only"
run_for_channel() {
  local channel_url="$1"
  local langs_csv="$2"
  local keep_subs="$3"
  local speaker_mode="$4"
  local speaker_fixed="$5"
  local start_number="$6"
  local transforms_global="$7"
  local mode="$8"

  # Deriva o slug do canal (ex: "oextensionista") e monta os caminhos
  local channel_slug; channel_slug=$(slugify "$channel_url")
  local channel_dir="${ROOT_OUT_DIR}/${channel_slug}"   # downloads/oextensionista/
  local list_dir="${INDEX_DIR}/${channel_slug}"          # data/oextensionista/
  local list_file="${list_dir}/videos.tsv"               # data/oextensionista/videos.tsv
  local transforms_path="$transforms_global"

  mkdir -p "$channel_dir" "$list_dir"

  # Override de transforms: se existir um transforms.txt específico do canal
  # (dentro de downloads/<slug>/), usa ele no lugar do global.
  # Permite customização por canal sem afetar os outros.
  if [[ -f "${channel_dir}/${TRANSFORMS_FILE}" ]]; then
    transforms_path="${channel_dir}/${TRANSFORMS_FILE}"
  fi

  echo "${bold}${blue}Canal:${reset} ${channel_url}  ${dim}(slug: ${channel_slug})${reset}"

  # ── PASSO 01: Listar vídeos ──────────────────────────────────────────────
  if [[ "$mode" == "all" || "$mode" == "list" ]]; then
    echo "${bold}Passo 01:${reset} Listando vídeos..."
    list_videos_for_channel "$channel_url" "$list_file"
    local count; count=$(wc -l < "$list_file" | tr -d ' ')
    echo "  ${green}OK${reset}: ${count} vídeos listados → ${list_file}"
    # No modo "list", encerra aqui sem baixar nada
    [[ "$mode" == "list" ]] && return 0
  fi

  # ── PASSO 02/03: Baixar legendas e converter ────────────────────────────
  if [[ "$mode" == "all" || "$mode" == "download" ]]; then
    # Gera a lista automaticamente se não existir (download sem list prévio)
    if [[ ! -f "$list_file" ]]; then
      echo "${yellow}Aviso:${reset} lista não encontrada; gerando agora..."
      list_videos_for_channel "$channel_url" "$list_file"
    fi
    echo "${bold}Passo 02:${reset} Baixando legendas e convertendo"
    local total; total=$(wc -l < "$list_file" | tr -d ' ')
    local idx=0; local ep="$start_number"

    # Itera linha a linha no TSV: cada linha = um vídeo
    # IFS=$'\t' garante split correto quando título contém espaços
    while IFS=$'\t' read -r vid vid_title; do
      [[ -z "$vid" ]] && continue
      idx=$((idx+1))

      # Skip inteligente: pula vídeos já processados quando --skip-existing está ativo.
      # Verifica por id_*.txt (mais rápido) e depois por linha no CSV (mais seguro).
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

      # Chama a função de download; incrementa ep apenas se tiver sucesso.
      # Vídeos sem legenda retornam exit code 1 e são pulados (ep não avança).
      if download_captions_for_video "$video_url" "$langs_csv" "$keep_subs" "$channel_dir" "$ep" "$speaker_mode" "$speaker_fixed" "$transforms_path"; then
        ep=$((ep+1))
      else
        echo "${yellow}Pulado (falha):${reset} ${video_url}"
      fi
    done < "$list_file"
  fi

  # ── PASSO 2.5 APENAS: Reaplica transforms em TXTs existentes ────────────
  # Útil quando transforms.txt foi editado e queremos re-normalizar sem rebaixar.
  if [[ "$mode" == "transform-only" ]]; then
    echo "${bold}Passo 2.5:${reset} Reaplicando transformações em TXT existentes"
    shopt -s nullglob   # glob vazio retorna array vazio (não o padrão literal "*.txt")
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
      # Usa arquivo temporário para evitar leitura/escrita simultânea no mesmo arquivo
      local tmp_out; tmp_out="$(mktemp)"
      py_convert_and_transform "$f" "$tmp_out" "$transforms_path"
      mv "$tmp_out" "$f"   # substitui o original apenas após sucesso
    done
  fi
}

# ---------- Parse CLI ----------
# Inicializa variáveis que podem ser sobrescritas pelos argumentos CLI
CHANNELS=""
LANG_CODES="$LANG_CODES_DEFAULT"

# Loop de parsing: processa pares --flag valor até esgotar os argumentos
# shift 2 avança dois argumentos por vez (flag + valor)
# shift   avança um argumento (flags booleanas sem valor)
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
# Verifica todas as dependências antes de começar qualquer processamento.
require_bin yt-dlp
require_bin python3
require_bin mktemp
require_bin sed
require_bin awk

# --channels é o único parâmetro verdadeiramente obrigatório
if [[ -z "$CHANNELS" ]]; then
  echo "${red}Erro:${reset} --channels é obrigatório."
  usage; exit 1
fi

# Aviso não-fatal: speaker-mode fixed sem nome resulta em speaker vazio
if [[ "$SPEAKER_MODE" == "fixed" && -z "$SPEAKER_FIXED" ]]; then
  echo "${yellow}Aviso:${reset} --speaker-mode=fixed sem --speaker-name; usará vazio."
fi

# Valida o modo de execução contra os valores permitidos
case "$RUN_MODE" in
  all|list|download|transform-only) ;;
  *) echo "${red}Erro:${reset} --run deve ser: all | list | download | transform-only"; exit 1 ;;
esac

# Cria diretórios raiz antes de qualquer operação
ensure_dirs

# ---------- Execução ----------
# Converte a string de canais em array e processa cada um sequencialmente.
# Ex: "https://...canal1,https://...canal2" → array de dois elementos
IFS=',' read -ra CHANNEL_ARR <<< "$CHANNELS"
for ch in "${CHANNEL_ARR[@]}"; do
  run_for_channel "$ch" "$LANG_CODES" "$KEEP_SUBS" "$SPEAKER_MODE" "$SPEAKER_FIXED" "$START_NUMBER" "$TRANSFORMS_FILE" "$RUN_MODE"
done

echo "${green}${bold}Concluído.${reset}"
