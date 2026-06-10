#!/usr/bin/env python3
"""
process_transcripts.py

Este script percorre uma pasta contendo transcrições de vídeos (no formato
`#NNN - Título {Palestrante}.txt`) e arquivos de metadados
(`id_<IDDOYOUTUBE>.txt`). Ele gera uma estrutura organizada que pode ser
utilizada em pipelines RAG ou outros sistemas de busca semântica.

Cada transcrição é convertida numa lista de trechos, mantendo o carimbo de
tempo original e os metadados associados ao vídeo (URL, título, palestrante).
Os trechos são armazenados em um arquivo JSON (``.json``) por vídeo e um
arquivo CSV com índice geral é gerado.

Uso:
    python3 process_transcripts.py --input ./downloads/canal --output ./organized

Se a pasta de saída não existir ela será criada automaticamente. O script
assume que as transcrições foram geradas pelo script ``fetch_channel_captions.sh``
e seguem o padrão descrito acima. Se um arquivo de metadados não for
encontrado ou o título não corresponder, o URL do vídeo será deixado em branco.

Autor: ChatGPT
"""

import argparse
import csv
import json
import re
import unicodedata
from pathlib import Path
from typing import Dict, List, Tuple, Optional


def normalize_title(title: str) -> str:
    """
    Normaliza um título removendo pontuação, acentos e convertendo para minúsculas.

    Usa NFKD para decompor caracteres acentuados e descarta marcas combinantes
    antes de aplicar a limpeza por regex.
    """
    decomposed = unicodedata.normalize("NFKD", title)
    without_accents = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    return re.sub(r"\W+", "", without_accents).lower()


def parse_metadata_files(metadata_dir: Path) -> Dict[str, Dict[str, str]]:
    """
    Lê todos os arquivos `id_*.txt` no diretório e retorna um dicionário
    mapeando um título normalizado para um dicionário com metadados
    (video_id, video_url, title, uploader, speaker, subtitle_mode, subtitle_lang, date).
    """
    meta = {}
    for meta_file in metadata_dir.glob("id_*.txt"):
        with meta_file.open("r", encoding="utf-8", errors="ignore") as f:
            data = {}
            for line in f:
                line = line.strip()
                if not line or ':' not in line:
                    continue
                key, value = line.split(":", 1)
                data[key.strip()] = value.strip()
            if 'title' in data:
                norm = normalize_title(data['title'])
                meta[norm] = data
    return meta


def parse_videos_tsv(tsv_path: Path) -> Dict[str, Dict[str, str]]:
    """
    Lê `videos.tsv` (gerado no Passo 01) e devolve um mapa título-normalizado -> metadados mínimos.

    O arquivo pode conter tabs literais ou a sequência '\\t'. Ambos são tratados.
    """
    result: Dict[str, Dict[str, str]] = {}
    if not tsv_path.is_file():
        return result

    with tsv_path.open("r", encoding="utf-8", errors="ignore") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue
            video_id: Optional[str] = None
            title: Optional[str] = None

            if "\t" in line:
                video_id, title = line.split("\t", 1)
            elif "\\t" in line:
                video_id, title = line.split("\\t", 1)
            else:
                parts = line.split(maxsplit=1)
                if len(parts) == 2:
                    video_id, title = parts

            if not video_id or not title:
                continue

            key = normalize_title(title)
            if key and key not in result:
                result[key] = {
                    "video_id": video_id.strip(),
                    "video_url": f"https://www.youtube.com/watch?v={video_id.strip()}",
                    "title": title.strip(),
                }
    return result


def locate_videos_tsv(input_dir: Path) -> Optional[Path]:
    """
    Procura `data/<slug>/videos.tsv` tomando como base o diretório de entrada.
    Retorna o caminho quando encontrado.
    """
    slug = input_dir.name
    search_roots = [input_dir] + list(input_dir.parents)
    for base in search_roots:
        candidate = base / "data" / slug / "videos.tsv"
        if candidate.is_file():
            return candidate
    return None


def parse_transcript_file(path: Path) -> List[Tuple[str, str]]:
    """
    Converte o conteúdo de uma transcrição em uma lista de tuplas (texto, timestamp).

    O formato esperado tem linhas alternando texto e carimbo de tempo. Exemplo:
        Olá
         00:00:00

        a todos e todas extensionistas...
         00:00:02
        ...
    A função ignora linhas em branco e utiliza o timestamp da linha iniciada por
    espaço como carimbo de tempo.
    """
    entries: List[Tuple[str, str]] = []
    last_text: Optional[str] = None
    with path.open("r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.rstrip("\n")
            # ignora linhas totalmente vazias
            if not line.strip():
                continue
            # linha que contém timestamp começa com espaço e tem HH:MM:SS
            if re.match(r"\s*\d{2}:\d{2}:\d{2}", line):
                ts = line.strip()
                if last_text:
                    entries.append((last_text.strip(), ts))
                    last_text = None
                continue
            # linha de conteúdo
            txt = line.strip()
            if last_text:
                # se houver conteúdo acumulado, junta com espaço
                last_text += " " + txt
            else:
                last_text = txt
        # caso haja texto sem timestamp final
        # (última linha de texto sem timestamp, define timestamp vazio)
        if last_text:
            entries.append((last_text.strip(), ""))
    return entries


def parse_episode_name(filename: str) -> Tuple[int, str, str]:
    """
    Extrai número do episódio, título e palestrante a partir do nome do arquivo.

    Formato esperado: "#NNN - Título {Palestrante}.txt"
    Retorna uma tupla (numero, titulo, palestrante). Se não houver palestrante,
    o campo correspondente será string vazia.
    """
    name = filename
    if name.startswith("#"):
        # remove '#' e pega o número
        try:
            num = int(name[1:4])
        except ValueError:
            num = 0
        # remove prefixo "#NNN - "
        rest = name[6:] if len(name) > 6 else name
    else:
        num = 0
        rest = name
    # remove extensão
    if rest.endswith(".txt"):
        rest = rest[:-4]
    # extrai palestrante entre { }
    speaker = ""
    title = rest
    m = re.search(r"\{([^{}]+)\}$", rest)
    if m:
        speaker = m.group(1).strip()
        title = rest[:m.start()].strip()
    return num, title.strip(), speaker


def sanitize_filename(name: str) -> str:
    """Remove caracteres inválidos para nomes de arquivos e normaliza espaços."""
    name = re.sub(r"[\\/:*?\"<>|]", "-", name)
    name = re.sub(r"\s+", " ", name)
    return name.strip()


def process_transcripts(input_dir: Path, output_dir: Path) -> None:
    """
    Processa todos os arquivos de transcrição e metadados em `input_dir` e
    salva os trechos organizados em `output_dir`.

    Para cada vídeo, gera um arquivo JSON contendo uma lista de objetos com as
    chaves: content, start_time, end_time, video_url, episode, title, speaker.
    Também gera um índice CSV na raiz do `output_dir`.
    """
    if not input_dir.is_dir():
        raise ValueError(f"Diretório de entrada {input_dir} não encontrado")
    output_dir.mkdir(parents=True, exist_ok=True)

    # Lê metadados
    metadata = parse_metadata_files(input_dir)
    videos_tsv = locate_videos_tsv(input_dir)
    videos_fallback = parse_videos_tsv(videos_tsv) if videos_tsv else {}

    index_path = output_dir / "index.csv"
    with index_path.open("w", newline="", encoding="utf-8") as index_csv:
        writer = csv.writer(index_csv)
        writer.writerow([
            "episode", "title", "speaker", "video_url", "num_segments", "file_name"
        ])

        # Percorre todos os arquivos de transcrição
        for transcript in sorted(input_dir.glob("#*.txt")):
            episode_num, title, speaker = parse_episode_name(transcript.name)
            norm_title = normalize_title(title)
            meta = metadata.get(norm_title)
            if meta and "video_url" in meta:
                video_url = meta["video_url"]
            else:
                video_url = ""
                fallback = videos_fallback.get(norm_title)
                if fallback:
                    video_url = fallback.get("video_url", "")

            # Lê entradas (texto, timestamp)
            entries = parse_transcript_file(transcript)
            segments = []
            for i, (content, start_time) in enumerate(entries):
                end_time = entries[i + 1][1] if i + 1 < len(entries) else ""
                seg = {
                    "content": content,
                    "start_time": start_time,
                    "end_time": end_time,
                    "video_url": video_url,
                    "episode": episode_num,
                    "title": title,
                    "speaker": speaker,
                }
                segments.append(seg)

            # Nome do arquivo de saída
            base_name = f"{episode_num:03d}_{sanitize_filename(title) if title else 'untitled'}"
            out_path = output_dir / f"{base_name}.json"
            with out_path.open("w", encoding="utf-8") as out_f:
                json.dump(segments, out_f, ensure_ascii=False, indent=2)

            writer.writerow([
                episode_num,
                title,
                speaker,
                video_url,
                len(segments),
                out_path.name,
            ])

    print(f"Processamento concluído. Arquivos organizados em {output_dir}.")


def main():
    parser = argparse.ArgumentParser(description="Processa transcrições e metadados em uma estrutura organizada.")
    parser.add_argument(
        "--input",
        type=str,
        default="./downloads",
        help="Diretório contendo transcrições e arquivos de metadados (id_*.txt)",
    )
    parser.add_argument(
        "--output",
        type=str,
        default="./organized",
        help="Diretório para salvar os arquivos JSON e o índice CSV",
    )
    args = parser.parse_args()
    input_dir = Path(args.input)
    output_dir = Path(args.output)
    process_transcripts(input_dir, output_dir)


if __name__ == "__main__":
    main()
