# extensionista-legenda

Pipeline de extração, limpeza e organização de legendas de canais do YouTube para uso em assistentes de IA (RAG — *Retrieval-Augmented Generation*).

> **Contexto acadêmico:** Este repositório é parte integrante da dissertação de mestrado desenvolvida no **Programa de Pós-Graduação em Ciência, Tecnologia e Sociedade (PPGCTS)** da **Universidade Federal de São Carlos (UFSCar)**. As transcrições contidas em `downloads/` constituem o **corpus primário** da pesquisa e são versionadas intencionalmente para garantir rastreabilidade, reprodutibilidade e integridade científica dos dados.

> **Canais-alvo (fontes primárias):**
> - [`@redeauroraater`](https://www.youtube.com/@redeauroraater) — Rede Aurora ATER
> - [`@oextensionista`](https://www.youtube.com/@oextensionista) — O Extensionista

---

## Sumário

1. [Visão geral do pipeline](#1-visão-geral-do-pipeline)
2. [Estrutura de arquivos](#2-estrutura-de-arquivos)
3. [Dependências e instalação](#3-dependências-e-instalação)
4. [Como usar — passo a passo](#4-como-usar--passo-a-passo)
5. [Referência de parâmetros](#5-referência-de-parâmetros)
6. [O arquivo `transforms.txt`](#6-o-arquivo-transformstxt)
7. [Como o conteúdo chega ao assistente GPT (RAG)](#7-como-o-conteúdo-chega-ao-assistente-gpt-rag)
8. [Leitura dos códigos-fonte](#8-leitura-dos-códigos-fonte)
9. [Exemplos de uso](#9-exemplos-de-uso)
10. [Convenções e boas práticas](#10-convenções-e-boas-práticas)

---

## 1. Visão geral do pipeline

O pipeline é dividido em quatro grandes passos, executados de forma sequencial (ou seletiva via `--run`):

```
YouTube Channel
      │
      ▼
 ┌──────────────────────────────────────────────────┐
 │  Passo 01 — Listagem de vídeos                   │
 │  fetch_channel_captions.sh --run list            │
 │  → data/<slug>/videos.tsv                        │
 └──────────────────────────────────────────────────┘
      │
      ▼
 ┌──────────────────────────────────────────────────┐
 │  Passo 02 — Download de legendas                 │
 │  fetch_channel_captions.sh --run download        │
 │  Tenta legenda manual → fallback automática      │
 │  Converte .srt/.vtt → .txt com timestamps        │
 └──────────────────────────────────────────────────┘
      │
      ▼
 ┌──────────────────────────────────────────────────┐
 │  Passo 2.5 — Transformações textuais             │
 │  Remove artefatos: [Música], [Aplausos]...       │
 │  Normaliza pontuação, corrige abreviações        │
 │  Aplica regras em transforms.txt                 │
 └──────────────────────────────────────────────────┘
      │
      ▼
 ┌──────────────────────────────────────────────────┐
 │  Passo 03 — Salvamento padronizado               │
 │  Gera: #NNN - Título {Palestrante}.txt           │
 │  Gera: id_<VIDEOID>.txt (metadados)              │
 │  Gera: index.csv (índice por canal)              │
 └──────────────────────────────────────────────────┘
      │
      ▼
 ┌──────────────────────────────────────────────────┐
 │  process_transcripts.py                          │
 │  Lê transcrições + metadados                     │
 │  Divide em segmentos com timestamps              │
 │  Gera: organized/<NNN>_Titulo.json (por episódio)│
 │  Gera: organized/index.csv                       │
 └──────────────────────────────────────────────────┘
      │
      ▼
 ┌──────────────────────────────────────────────────┐
 │  Assistente GPT / RAG                            │
 │  Cada segmento JSON = um chunk de busca          │
 │  Campos: content, start_time, video_url,         │
 │          episode, title, speaker                 │
 └──────────────────────────────────────────────────┘
```

---

## 2. Estrutura de arquivos

```
extensionista-legenda/
│
├── fetch_channel_captions.sh      # Script principal (Bash): lista, baixa, limpa e salva
├── process_transcripts.py         # Script Python: organiza transcrições para RAG
├── transforms.txt                 # Regras sed-like de limpeza textual (Passo 2.5)
├── AGENTS.md                      # Diretrizes do projeto para agentes de IA
│
├── data/                          # Saídas do Passo 01 (listas de vídeos)
│   ├── oextensionista/
│   │   └── videos.tsv             # id <TAB> título — um vídeo por linha
│   └── redeauroraater/
│       └── videos.tsv
│
├── downloads/                     # Saídas dos Passos 02–03 (transcrições)
│   ├── oextensionista/
│   │   ├── #001 - Título {Palestrante}.txt   # Texto com timestamps por fala
│   │   ├── id_<VIDEOID>.txt                   # Metadados do vídeo
│   │   ├── index.csv                          # Índice do canal
│   │   └── transforms.txt                     # (opcional) regras específicas do canal
│   └── redeauroraater/
│       └── ...
│
└── organized/                     # Saídas do process_transcripts.py (para RAG)
    ├── 001_Titulo do Episodio.json   # Lista de segmentos estruturados
    ├── 002_Outro Titulo.json
    ├── index.csv                     # Índice geral de episódios
    └── todos.json                    # (gerado externamente) todos os segmentos em um único arquivo
```

### Formato dos arquivos de saída

#### `data/<slug>/videos.tsv`
```
<video_id>	<título do vídeo>
XWWEGyi2lwM	Meu Imóvel Rural ferramenta para autonomia
...
```

#### `downloads/<slug>/#NNN - Título {Palestrante}.txt`
Texto legível com timestamps intercalados:
```
Olá
 00:00:00

a todos e todos extensionistas rurais,
 00:00:02

agricultores e agricultoras, jovens
 00:00:05
```

#### `downloads/<slug>/id_<VIDEOID>.txt`
Metadados resumidos do vídeo:
```
video_id: XWWEGyi2lwM
video_url: https://www.youtube.com/watch?v=XWWEGyi2lwM
title: Meu Imóvel Rural ferramenta para autonomia
uploader: O Extensionista
speaker: Carlos Mário Guedes de Guedes - INCRA
subtitle_mode: manual
subtitle_lang: pt
date: 06/15/2023
```

#### `organized/<NNN>_Titulo.json`
Array JSON de segmentos — cada objeto é um "chunk" para o RAG:
```json
[
  {
    "content": "Olá a todos e todos extensionistas rurais,",
    "start_time": "00:00:00",
    "end_time": "00:00:05",
    "video_url": "https://www.youtube.com/watch?v=XWWEGyi2lwM",
    "episode": 1,
    "title": "Meu Imóvel Rural ferramenta para autonomia",
    "speaker": "Carlos Mário Guedes de Guedes - INCRA"
  },
  ...
]
```

---

## 3. Dependências e instalação

### Dependências do sistema

| Ferramenta | Função | Instalação (macOS) |
|---|---|---|
| `yt-dlp` | Download de metadados e legendas do YouTube | `brew install yt-dlp` |
| `python3` | Parser de legendas e organização para RAG | Incluso no macOS ou `brew install python` |
| `sed` / `awk` | Manipulação de texto | Incluso no macOS |
| `mktemp` | Arquivos temporários | Incluso no macOS |

> **Importante:** não são necessárias chaves de API do YouTube. O `yt-dlp` acessa o conteúdo público diretamente.

### Instalação do `yt-dlp`

```bash
# macOS com Homebrew
brew install yt-dlp

# ou via pip
pip install yt-dlp

# Manter atualizado (importante: o YouTube muda frequentemente)
yt-dlp -U
```

### Tornar o script executável

```bash
chmod +x fetch_channel_captions.sh
```

---

## 4. Como usar — passo a passo

### Fluxo completo (recomendado para primeira execução)

```bash
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@oextensionista,https://www.youtube.com/@redeauroraater" \
  --run all
```

Isso executa os Passos 01, 02, 2.5 e 03 em sequência para ambos os canais.

### Apenas listar vídeos (Passo 01)

Gera `data/<slug>/videos.tsv` sem baixar nada. Útil para revisar a lista antes de rodar o download:

```bash
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@oextensionista" \
  --run list
```

### Apenas baixar legendas (Passos 02–03), usando lista já existente

```bash
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@oextensionista" \
  --run download
```

### Reaplicar somente as transformações em TXTs já baixados (Passo 2.5)

Útil quando você modifica o `transforms.txt` e quer reprocessar sem rebaixar tudo:

```bash
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@oextensionista" \
  --run transform-only
```

### Organizar para RAG (após o download)

```bash
python3 process_transcripts.py \
  --input ./downloads/oextensionista \
  --output ./organized
```

---

## 5. Referência de parâmetros

| Parâmetro | Padrão | Descrição |
|---|---|---|
| `--channels` | *(obrigatório)* | URLs dos canais, separadas por vírgula |
| `--run` | `all` | Modo: `all`, `list`, `download`, `transform-only` |
| `--lang` | `pt,pt-BR,pt-PT` | Idiomas de legenda em ordem de preferência |
| `--keep-subs` | *(desligado)* | Mantém os `.srt`/`.vtt` baixados |
| `--skip-existing` | *(desligado)* | Pula vídeos que já possuem `id_*.txt` ou linha no `index.csv` |
| `--speaker-mode` | `uploader` | `uploader` (nome do canal) ou `fixed` (nome fixo) |
| `--speaker-name` | *(vazio)* | Nome fixo do palestrante (requer `--speaker-mode fixed`) |
| `--start-number` | `1` | Número inicial do episódio para numeração sequencial |
| `--transforms-file` | `transforms.txt` | Caminho para arquivo de transformações |

---

## 6. O arquivo `transforms.txt`

O arquivo `transforms.txt` contém regras de substituição no estilo `sed` que são aplicadas sobre o texto das legendas durante o Passo 2.5.

### Formato

```
s/padrão-regex/substituto/flags
```

**Flags suportadas:**
- `i` — ignora maiúsculas/minúsculas
- `g` — substitui todas as ocorrências (global)
- `m` — modo multilinha (`^` e `$` batem em cada linha)
- `s` — modo ponto-tudo (`dotall`, `.` inclui `\n`)

**Linhas começando com `#` são comentários e são ignoradas.**

### Categorias de regras presentes

1. **Remoção de marcadores não-verbais** — `[Música]`, `[Aplausos]`, `(risos)`, etc.
2. **Normalização de pontuação** — aspas tipográficas → ASCII, travessões → hífens, reticências Unicode → `...`
3. **Limpeza de espaços** — múltiplos espaços → um, espaços ao final da linha
4. **Correções ortográficas informais** — abreviações como `vc` → `você`, `pq` → `porque`
5. **Correções de nomes próprios** — variações de transcrição automática incorreta, ex: `Zqueledim` → `Ezequiel Redin`

### Transformações por canal

Para aplicar regras específicas a um canal sem afetar o outro, crie um arquivo `transforms.txt` dentro da pasta do canal:

```
downloads/oextensionista/transforms.txt   ← sobrescreve o global para este canal
```

O script detecta automaticamente esse arquivo e o usa no lugar do global.

---

## 7. Como o conteúdo chega ao assistente GPT (RAG)

### O que é RAG?

*Retrieval-Augmented Generation* (RAG) é uma técnica em que o modelo de linguagem (GPT) não tenta memorizar todo o conteúdo, mas sim **busca** trechos relevantes de uma base de conhecimento no momento da resposta.

### Fluxo de integração

```
1. Ingestão
   ─────────
   organized/*.json  ──▶  [Upload no OpenAI Assistants]
                           ou [Banco vetorial: Chroma, Pinecone, pgvector...]
                           ou [Arquivo único: todos.json]

2. Pergunta do usuário
   ───────────────────
   "Quais são os desafios da ATER Digital?"

3. Busca semântica
   ────────────────
   Sistema recupera os N segmentos JSON mais relevantes

4. Geração
   ────────
   GPT recebe os segmentos como contexto e responde com base neles,
   podendo citar: episódio, palestrante, timestamp e URL do vídeo
```

### Por que segmentos e não transcrições inteiras?

Cada episódio pode ter 1–2 horas de fala. Enviar tudo de uma vez ultrapassa os limites de contexto dos modelos. Ao dividir em segmentos de ~2–5 segundos com metadados (timestamp, URL, palestrante), o sistema de busca consegue retornar **apenas os trechos mais relevantes**, economizando tokens e aumentando a precisão.

### Campos de cada segmento JSON

| Campo | Tipo | Descrição |
|---|---|---|
| `content` | string | Texto da fala naquele trecho |
| `start_time` | string | Início do trecho (`HH:MM:SS`) |
| `end_time` | string | Fim do trecho (`HH:MM:SS`) |
| `video_url` | string | Link direto para o vídeo no YouTube |
| `episode` | int | Número sequencial do episódio |
| `title` | string | Título do vídeo |
| `speaker` | string | Nome do palestrante (extraído da descrição ou nome do canal) |

### Carregando no OpenAI Assistants

1. Acesse [platform.openai.com](https://platform.openai.com)
2. Crie um **Assistant** com *File Search* habilitado
3. Faça upload dos arquivos `.json` da pasta `organized/`
4. O assistente passará a citar as falas com timestamps e links

### Carregando em banco vetorial (LangChain/LlamaIndex)

```python
import json
from pathlib import Path

segments = []
for json_file in Path("organized").glob("*.json"):
    segments.extend(json.loads(json_file.read_text(encoding="utf-8")))

# Cada item de `segments` é um documento pronto para indexação
# com metadata: video_url, episode, title, speaker, start_time
```

---

## 8. Leitura dos códigos-fonte

### `fetch_channel_captions.sh`

O script é estruturado em blocos funcionais bem delimitados:

| Bloco | Linhas (aprox.) | Responsabilidade |
|---|---|---|
| Configurações padrão | 37–47 | Variáveis globais e valores iniciais |
| `usage()` | 50–74 | Exibe ajuda no terminal |
| `require_bin()` | 77–82 | Verifica se uma dependência está instalada |
| `sed_inplace()` | 85–91 | Wrapper portável para `sed -i` (GNU vs. macOS/BSD) |
| `slugify()` | 94–96 | Converte URL de canal em slug de pasta |
| `sanitize_filename()` | 98–100 | Remove caracteres inválidos de nomes de arquivo |
| `progress()` | 102–109 | Exibe barra de progresso `[idx/total %]` |
| `compose_basename()` | 111–121 | Monta o nome `#NNN - Título {Palestrante}` |
| `py_convert_and_transform()` | 128–220 | **Núcleo Python embutido**: converte SRT/VTT → TXT com timestamps, aplica limpezas e transforms externos |
| `download_captions_for_video()` | 223–436 | Baixa metadados + legendas de um vídeo; escreve TXT, id_*.txt e linha no CSV |
| `list_videos_for_channel()` | 439–449 | Passo 01: lista vídeos e salva TSV |
| `run_for_channel()` | 452–535 | Orquestra todos os passos para um canal |
| Parse CLI | 537–555 | Lê argumentos da linha de comando |
| Validações | 557–576 | Verifica dependências e argumentos obrigatórios |
| Execução | 579–587 | Loop principal: itera sobre os canais recebidos |

#### Por que há Python embutido dentro do Bash?

A função `py_convert_and_transform()` usa um *heredoc* (`<< 'PY' ... PY`) para embutir código Python diretamente no script Bash. Isso evita a necessidade de um arquivo `.py` externo para essa etapa, mantendo o script como uma unidade independente. O Python é usado aqui porque:

- Expressões regulares em Python são mais poderosas e legíveis que em `sed`/`awk`
- O parsing de SRT/VTT envolve múltiplos blocos e lógica de estado que seriam muito complexos em Bash puro
- Python trata Unicode (caracteres acentuados, emojis) de forma nativa

### `process_transcripts.py`

O script Python é uma ferramenta standalone com as seguintes funções:

| Função | Responsabilidade |
|---|---|
| `normalize_title()` | Remove acentos e pontuação para comparação fuzzy de títulos |
| `parse_metadata_files()` | Lê todos os `id_*.txt` e indexa por título normalizado |
| `parse_videos_tsv()` | Lê `videos.tsv` como fallback de metadados |
| `locate_videos_tsv()` | Procura `data/<slug>/videos.tsv` subindo a hierarquia de pastas |
| `parse_transcript_file()` | Converte o `.txt` em lista de tuplas `(texto, timestamp)` |
| `parse_episode_name()` | Extrai número, título e palestrante do nome do arquivo |
| `sanitize_filename()` | Remove caracteres inválidos para nomes de arquivo |
| `process_transcripts()` | **Função principal**: orquestra leitura, conversão e gravação dos JSONs e CSV |
| `main()` | Entry point com argumentos `--input` e `--output` |

---

## 9. Exemplos de uso

### Exemplo 1 — Execução completa dos dois canais

```bash
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@redeauroraater,https://www.youtube.com/@oextensionista" \
  --run all \
  --skip-existing
```

### Exemplo 2 — Somente listar vídeos, revisar, depois baixar

```bash
# Passo 1: listar
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@oextensionista" \
  --run list

# Verificar o TSV gerado
cat data/oextensionista/videos.tsv | head -10

# Passo 2: baixar (pula os já processados)
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@oextensionista" \
  --run download \
  --skip-existing
```

### Exemplo 3 — Reaplicar transforms após editar `transforms.txt`

```bash
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@oextensionista" \
  --run transform-only
```

### Exemplo 4 — Manter os arquivos SRT originais

```bash
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@oextensionista" \
  --run download \
  --keep-subs
```

### Exemplo 5 — Organizar transcrições para RAG

```bash
# Processa um canal
python3 process_transcripts.py \
  --input ./downloads/oextensionista \
  --output ./organized

# Confere o índice
cat organized/index.csv

# Confere um episódio
cat "organized/001_Meu Imóvel Rural ferramenta para autonomia.json" | python3 -m json.tool | head -40
```

---

## 10. Convenções e boas práticas

### Nomenclatura de arquivos

- **Transcrições:** `#NNN - Título {Palestrante}.txt` — o prefixo `#NNN` (3 dígitos com zeros à esquerda) garante ordenação alfabética correta
- **Metadados:** `id_<VIDEOID>.txt` — permite localizar o metadado de um vídeo pelo ID do YouTube sem precisar abrir o CSV
- **Slugs de canal:** derivados da URL, ex: `@oextensionista` → `oextensionista`

### Adicionando novas correções de nomes próprios ao `transforms.txt`

1. Identifique a variação incorreta que aparece nas transcrições automáticas
2. Adicione uma linha `s/\bVariaçãoErrada\b/NomeCorreto/g` ao `transforms.txt`
3. Reaplique com `--run transform-only` (não é necessário rebaixar as legendas)

### Checklist antes de rodar em larga escala

- [ ] `yt-dlp` está atualizado (`yt-dlp -U`)
- [ ] `transforms.txt` foi revisado
- [ ] Listagem (`--run list`) foi verificada para confirmar a quantidade de vídeos
- [ ] `--skip-existing` está habilitado se for uma execução incremental
- [ ] Espaço em disco suficiente (transcrições de 100+ vídeos podem ocupar vários GB em JSON)

### Comandos de diagnóstico

```bash
# Verificar sintaxe do script Bash
bash -n fetch_channel_captions.sh

# Lint completo com ShellCheck
shellcheck fetch_channel_captions.sh

# Contar vídeos listados
wc -l data/oextensionista/videos.tsv

# Contar transcrições baixadas
ls downloads/oextensionista/#*.txt | wc -l

# Ver índice de um canal
cat downloads/oextensionista/index.csv
```

---

## Contexto acadêmico e citação

Este repositório foi desenvolvido no âmbito da dissertação de mestrado:

> **Programa:** Pós-Graduação em Ciência, Tecnologia e Sociedade (PPGCTS)
> **Instituição:** Universidade Federal de São Carlos (UFSCar)
> **Linha de pesquisa:** Tecnologia, Inovação e Sociedade

### Sobre o corpus

As transcrições armazenadas em `downloads/` foram obtidas de vídeos públicos dos canais [`@redeauroraater`](https://www.youtube.com/@redeauroraater) e [`@oextensionista`](https://www.youtube.com/@oextensionista) e constituem o **corpus primário** da pesquisa. Elas são mantidas no repositório para assegurar:

- **Rastreabilidade** — cada arquivo `id_<VIDEOID>.txt` preserva a URL, data e metadados da fonte original
- **Reprodutibilidade** — o corpus pode ser reprocessado a partir do mesmo conjunto de fontes
- **Integridade científica** — os dados brutos estão disponíveis para auditoria e revisão por pares

### Uso ético e legal

- O conteúdo dos vídeos pertence aos respectivos criadores e canais
- A coleta respeita os Termos de Serviço do YouTube para fins de pesquisa acadêmica
- As transcrições não substituem nem redistribuem o conteúdo original em vídeo
- Evite paralelismo excessivo de requisições ao servidor do YouTube (`yt-dlp`)
- Mantenha o `yt-dlp` atualizado (`yt-dlp -U`) para garantir compatibilidade contínua

### Reproduzindo o corpus

Para recriar as transcrições a partir do zero (ex: verificação independente):

```bash
# 1. Listar vídeos atuais dos canais
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@redeauroraater,https://www.youtube.com/@oextensionista" \
  --run list

# 2. Baixar legendas
./fetch_channel_captions.sh \
  --channels "https://www.youtube.com/@redeauroraater,https://www.youtube.com/@oextensionista" \
  --run download
```

> **Nota:** vídeos podem ser removidos ou suas legendas alteradas ao longo do tempo. A versão arquivada no repositório (`downloads/`) representa o estado do corpus na data de coleta registrada nos arquivos `id_*.txt`.
