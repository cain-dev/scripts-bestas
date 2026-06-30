#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
flac_converter_gui.py — Interface gráfica (Tkinter) unificada para converter
FLAC em AAC (m4a), MP3 ou Opus, com extração/redimensionamento de capa,
progresso em tempo real e log.

É um programa AUTÔNOMO: não depende dos scripts .sh. Reimplementa a mesma
lógica em Python, chamando diretamente ffmpeg / opusenc / metaflac / ImageMagick.

Dependências externas (verificadas na inicialização):
  - metaflac, ImageMagick (magick OU convert)  -> capa
  - ffmpeg                                       -> MP3 (libmp3lame) e AAC
  - opusenc                                      -> Opus
  - ffmpeg com libfdk_aac (opcional)             -> AAC de melhor qualidade;
        sem ele, usa o encoder 'aac' nativo do ffmpeg automaticamente.

Uso:  python3 flac_converter_gui.py
"""

import os
import re
import shutil
import subprocess
import tempfile
import threading
import queue


# ==========================================================================
# MOTOR DE CONVERSÃO  (sem nenhuma dependência de tkinter)
# ==========================================================================

# Perfis de capa: rótulo -> resolução-alvo (0 = manter original, sem resize).
COVER_PROFILES = [
    ("Legado (200px)",      200),
    ("MP3 CD (300px)",      300),
    ("iPod / SD (600px)",   600),
    ("iPad Retina (1400px)", 1400),
    ("HI-DPI (2400px)",     2400),
    ("Original (sem resize)", 0),
]
COVER_DEFAULT_INDEX = 1  # MP3 CD / 300px


def which(name):
    return shutil.which(name)


def ffmpeg_has_encoder(ffmpeg_bin, encoder, env=None):
    """Retorna True se o ffmpeg informado lista o encoder pedido.

    Aceita 'env' porque builds de ffmpeg instaladas fora do padrão
    (ex.: /opt/.../bin/ffmpeg) frequentemente dependem de LD_LIBRARY_PATH
    só para INICIAR; sem isso o próprio '-encoders' falha e o encoder
    pareceria inexistente.
    """
    try:
        out = subprocess.run(
            [ffmpeg_bin, "-hide_banner", "-encoders"],
            capture_output=True, text=True, timeout=15, env=env,
        )
        haystack = (out.stdout or "") + "\n" + (out.stderr or "")
        return re.search(r"\b" + re.escape(encoder) + r"\b", haystack) is not None
    except Exception:
        return False


class ConversionError(Exception):
    pass


class Cancelled(Exception):
    pass


class ConversionEngine:
    """
    Motor de transcodificação. A UI fornece callbacks:
      log_cb(texto, nivel)         nivel in {"info","ok","erro","aviso","passo"}
      file_progress_cb(percent)    0..100 do arquivo atual (ou None p/ indeterminado)
      overall_progress_cb(feitos, total)
    e um threading.Event 'cancel_event' para cancelamento cooperativo.
    """

    def __init__(self, log_cb=None, file_progress_cb=None,
                 overall_progress_cb=None, cancel_event=None):
        self.log = log_cb or (lambda *_: None)
        self.file_progress = file_progress_cb or (lambda *_: None)
        self.overall_progress = overall_progress_cb or (lambda *_: None)
        self.cancel_event = cancel_event or threading.Event()
        self._proc = None  # subprocess em execução (para poder cancelar)

        # Detecção de binários.
        self.metaflac = which("metaflac")
        self.img_cmd = which("magick") or which("convert")
        self.ffmpeg = which("ffmpeg")
        self.opusenc = which("opusenc")

    # ---- descoberta de binário de AAC (libfdk preferido) -----------------
    def resolve_aac(self, libfdk_path=None):
        """
        Decide qual ffmpeg/encoder usar para AAC.
        Retorna (ffmpeg_bin, encoder, env_extra) ou (None, None, None).
        Preferência: ffmpeg com libfdk_aac (caminho informado ou padrão);
        senão, ffmpeg do sistema com o encoder 'aac' nativo.
        """
        candidates = []
        if libfdk_path:
            candidates.append(libfdk_path)
        if "/opt/ffmpeg-libfdk/bin/ffmpeg" not in candidates:
            candidates.append("/opt/ffmpeg-libfdk/bin/ffmpeg")
        for c in candidates:
            if c and os.path.isfile(c) and os.access(c, os.X_OK):
                # Monta o ambiente ANTES de sondar: uma build em /opt pode
                # precisar de LD_LIBRARY_PATH apenas para rodar '-encoders'.
                env = dict(os.environ)
                prefix = os.path.dirname(os.path.dirname(c))
                libdirs = [d for d in (os.path.join(prefix, "lib"),
                                       os.path.join(prefix, "lib64"))
                           if os.path.isdir(d)]
                if libdirs:
                    atual = env.get("LD_LIBRARY_PATH", "")
                    env["LD_LIBRARY_PATH"] = os.pathsep.join(
                        libdirs + ([atual] if atual else []))
                if ffmpeg_has_encoder(c, "libfdk_aac", env=env):
                    return c, "libfdk_aac", env
        if self.ffmpeg and ffmpeg_has_encoder(self.ffmpeg, "aac"):
            return self.ffmpeg, "aac", dict(os.environ)
        return None, None, None

    def diagnose_aac(self, libfdk_path=None):
        """Retorna (encoder, mensagem) amigável para a UI exibir na partida."""
        fb, enc, _ = self.resolve_aac(libfdk_path)
        if enc == "libfdk_aac":
            return enc, "AAC: usando libfdk_aac (%s)." % fb
        cand = libfdk_path or "/opt/ffmpeg-libfdk/bin/ffmpeg"
        if enc == "aac":
            if cand and os.path.isfile(cand):
                return enc, ("AAC: '%s' existe mas não respondeu com libfdk_aac "
                             "(binário não executável ou bibliotecas ausentes); "
                             "usando encoder 'aac' nativo." % cand)
            return enc, ("AAC: libfdk não encontrado em '%s'; "
                         "usando encoder 'aac' nativo." % cand)
        return None, "AAC: nenhum encoder disponível."

    # ---- presets de qualidade por codec ---------------------------------
    def quality_presets(self, codec, libfdk_path=None):
        """
        Retorna lista de (rótulo, dados) para o codec. 'dados' é específico:
          opus -> {"bitrate": "192"}
          mp3  -> {"args": ["-c:a","libmp3lame","-q:a","0"], "info": "V0"}
          aac  -> {"args": [...], "info": "..."}  (depende do encoder achado)
        """
        if codec == "opus":
            return [
                ("Exagerado (256 kbps)",   {"bitrate": "256"}),
                ("Transparente (192 kbps)", {"bitrate": "192"}),
                ("Eficiente (128 kbps)",   {"bitrate": "128"}),
            ], 1
        if codec == "mp3":
            mk = lambda flag, val, info: {"args": ["-c:a", "libmp3lame", flag, val], "info": info}
            return [
                ("V0 VBR (~245k) [moderno]", mk("-q:a", "0", "V0 VBR")),
                ("V2 VBR (~190k)",           mk("-q:a", "2", "V2 VBR")),
                ("320 kbps CBR",             mk("-b:a", "320k", "320k CBR")),
                ("256 kbps CBR",             mk("-b:a", "256k", "256k CBR")),
                ("128 kbps CBR",             mk("-b:a", "128k", "128k CBR")),
            ], 0
        if codec == "aac":
            _, enc, _ = self.resolve_aac(libfdk_path)
            if enc == "libfdk_aac":
                a = lambda *x: {"args": ["-c:a", "libfdk_aac", *x[0]], "info": x[1]}
                return [
                    ("512 kbps CBR", a(["-b:a", "512k"], "512k CBR")),
                    ("256 kbps CBR (iTunes)", a(["-b:a", "256k"], "256k CBR")),
                    ("192 kbps CBR", a(["-b:a", "192k"], "192k CBR")),
                    ("128 kbps CBR", a(["-b:a", "128k"], "128k CBR")),
                    ("VBR 5 [moderno]", a(["-vbr", "5"], "VBR 5")),
                    ("VBR 4 (alta)", a(["-vbr", "4"], "VBR 4")),
                ], 4
            # encoder nativo 'aac'
            a = lambda *x: {"args": ["-c:a", "aac", *x[0]], "info": x[1]}
            return [
                ("256 kbps CBR (iTunes)", a(["-b:a", "256k"], "256k CBR")),
                ("192 kbps CBR", a(["-b:a", "192k"], "192k CBR")),
                ("128 kbps CBR", a(["-b:a", "128k"], "128k CBR")),
                ("VBR q5 [moderno]", a(["-q:a", "1.4"], "VBR ~5")),
            ], 0
        raise ValueError("codec desconhecido: %r" % codec)

    # ---- localização de arquivos -----------------------------------------
    @staticmethod
    def find_flacs(root, recursive, out_dir_name):
        """Lista FLACs (case-insensitive) abaixo de 'root'."""
        achados = []
        if recursive:
            for dirpath, dirnames, filenames in os.walk(root):
                # não desce na pasta de saída
                dirnames[:] = [d for d in dirnames if d != out_dir_name]
                for f in filenames:
                    if f.lower().endswith(".flac"):
                        achados.append(os.path.join(dirpath, f))
        else:
            for f in sorted(os.listdir(root)):
                full = os.path.join(root, f)
                if os.path.isfile(full) and f.lower().endswith(".flac"):
                    achados.append(full)
        return sorted(achados)

    # ---- duração (para % por arquivo) ------------------------------------
    def _duration(self, flac):
        try:
            out = subprocess.run(
                [self.metaflac, "--show-total-samples", "--show-sample-rate", flac],
                capture_output=True, text=True, timeout=15,
            )
            samples_s, rate_s = out.stdout.split()[:2]
            samples, rate = int(samples_s), int(rate_s)
            if rate > 0:
                return samples / rate
        except Exception:
            pass
        return 0.0

    # ---- capa -------------------------------------------------------------
    def _extract_cover(self, flac, idx, workdir, res):
        """Extrai (e opcionalmente redimensiona) a capa. Retorna caminho ou None."""
        cover = os.path.join(workdir, "cover_%d.png" % idx)
        resized = os.path.join(workdir, "cover_%d_resized.png" % idx)
        for p in (cover, resized):
            try:
                os.remove(p)
            except OSError:
                pass

        # valida FLAC
        chk = subprocess.run([self.metaflac, "--list", flac],
                             capture_output=True, text=True)
        if chk.returncode != 0:
            self.log("  capa: '%s' ilegível pelo metaflac; sem capa." % os.path.basename(flac), "aviso")
            return None

        lst = subprocess.run([self.metaflac, "--list", "--block-type=PICTURE", flac],
                             capture_output=True, text=True).stdout
        if ("type: 3" in lst) or ("type: 0" in lst):
            subprocess.run([self.metaflac, "--export-picture-to=" + cover, flac],
                           capture_output=True)
        if not os.path.isfile(cover):
            return None

        if res and res > 0:
            r = subprocess.run(
                [self.img_cmd, cover, "-filter", "Lanczos",
                 "-resize", "%dx%d>" % (res, res), "-strip", resized],
                capture_output=True,
            )
            if r.returncode == 0 and os.path.isfile(resized):
                return resized
            self.log("  capa: redimensionamento falhou; usando original.", "aviso")
        return cover

    # ---- execução de subprocesso com cancelamento ------------------------
    def _run(self, cmd, env=None, progress_parser=None):
        """
        Executa cmd. Se progress_parser for dado, lê stdout linha a linha e
        chama self.file_progress(pct). Respeita cancelamento. Retorna rc.
        """
        if self.cancel_event.is_set():
            raise Cancelled()
        self._proc = subprocess.Popen(
            cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        try:
            for line in self._proc.stdout:
                if self.cancel_event.is_set():
                    self._terminate()
                    raise Cancelled()
                if progress_parser:
                    pct = progress_parser(line)
                    if pct is not None:
                        self.file_progress(max(0, min(100, pct)))
            self._proc.wait()
        finally:
            rc = self._proc.returncode
            self._proc = None
        if self.cancel_event.is_set():
            raise Cancelled()
        return rc

    def _terminate(self):
        if self._proc and self._proc.poll() is None:
            try:
                self._proc.terminate()
                self._proc.wait(timeout=3)
            except Exception:
                try:
                    self._proc.kill()
                except Exception:
                    pass

    @staticmethod
    def _ffmpeg_progress_parser(duration):
        """Fecha sobre a duração; interpreta linhas '-progress' do ffmpeg."""
        def parse(line):
            line = line.strip()
            if line.startswith("out_time_us=") and duration > 0:
                try:
                    us = int(line.split("=", 1)[1])
                    return (us / 1_000_000.0) / duration * 100.0
                except ValueError:
                    return None
            if line == "progress=end":
                return 100.0
            return None
        return parse

    @staticmethod
    def _opus_progress_parser(line):
        m = re.search(r"(\d+)%", line)
        if m:
            return float(m.group(1))
        return None

    # ---- conversão de UM arquivo -----------------------------------------
    def _convert_one(self, flac, out_path, cover, codec, quality, aac_runtime):
        dur = self._duration(flac)
        if codec == "opus":
            cmd = [self.opusenc, "--bitrate", quality["bitrate"]]
            if cover:
                cmd += ["--discard-pictures", "--picture", "3||||" + cover]
            cmd += [flac, out_path]
            rc = self._run(cmd, progress_parser=self._opus_progress_parser)
        else:
            # mp3 ou aac via ffmpeg
            if codec == "aac":
                ffmpeg_bin, _, env = aac_runtime
                audio_args = quality["args"]
                tail = ["-c:v", "mjpeg", "-disposition:v:0", "attached_pic",
                        "-movflags", "+faststart"]
                tail_noc = ["-movflags", "+faststart"]
            else:  # mp3
                ffmpeg_bin, env = self.ffmpeg, dict(os.environ)
                audio_args = quality["args"]
                tail = ["-id3v2_version", "3",
                        "-metadata:s:v", "title=Album cover",
                        "-metadata:s:v", "comment=Cover (Front)",
                        "-disposition:v:0", "attached_pic"]
                tail_noc = ["-id3v2_version", "3"]

            base = [ffmpeg_bin, "-nostdin", "-v", "error",
                    "-progress", "pipe:1", "-i", flac]
            if cover:
                cmd = base + ["-i", cover, "-map", "0:a", "-map", "1:v",
                              "-map_metadata", "0"] + audio_args + tail + [out_path, "-y"]
            else:
                cmd = base + ["-map", "0:a", "-map_metadata", "0"] + \
                      audio_args + tail_noc + [out_path, "-y"]
            rc = self._run(cmd, env=env, progress_parser=self._ffmpeg_progress_parser(dur))
        return rc

    # ---- conversão do LOTE inteiro ---------------------------------------
    def convert_batch(self, source_dir, codec, quality, res, recursive,
                      skip_existing, out_dir, libfdk_path=None):
        """Executa o lote. Lança Cancelled se cancelado; ConversionError em erro fatal."""
        if not self.metaflac:
            raise ConversionError("metaflac não encontrado (pacote 'flac').")
        if not self.img_cmd:
            raise ConversionError("ImageMagick não encontrado (magick/convert).")

        ext = {"opus": "opus", "mp3": "mp3", "aac": "m4a"}[codec]

        aac_runtime = (None, None, None)
        if codec == "aac":
            aac_runtime = self.resolve_aac(libfdk_path)
            if aac_runtime[0] is None:
                raise ConversionError("Nenhum encoder AAC disponível (libfdk nem aac nativo).")
            self.log("AAC via: %s (encoder %s)" % (aac_runtime[0], aac_runtime[1]), "info")
        elif codec == "mp3" and not self.ffmpeg:
            raise ConversionError("ffmpeg não encontrado.")
        elif codec == "opus" and not self.opusenc:
            raise ConversionError("opusenc não encontrado (pacote 'opus-tools').")

        out_dir_name = os.path.basename(os.path.normpath(out_dir))
        flacs = self.find_flacs(source_dir, recursive, out_dir_name)
        total = len(flacs)
        if total == 0:
            self.log("Nenhum .flac encontrado com o escopo escolhido.", "aviso")
            self.overall_progress(0, 0)
            return (0, 0)

        os.makedirs(out_dir, exist_ok=True)
        self.log("Convertendo %d arquivo(s) | Capa: %dpx | Codec: %s"
                 % (total, res, codec.upper()), "info")

        workdir = tempfile.mkdtemp(prefix="flac2x_gui.")
        convertidos = pulados = 0
        try:
            for i, flac in enumerate(flacs, start=1):
                if self.cancel_event.is_set():
                    raise Cancelled()
                self.overall_progress(i - 1, total)
                self.file_progress(0)
                rel = os.path.relpath(flac, source_dir)
                nome = os.path.basename(flac)
                base_noext = re.sub(r"\.flac$", "", rel, flags=re.IGNORECASE)
                out_path = os.path.join(out_dir, base_noext + "." + ext)
                os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)

                if skip_existing and os.path.isfile(out_path):
                    self.log("[%d/%d] %s (já existe, pulado)" % (i, total, nome), "passo")
                    pulados += 1
                    self.file_progress(100)
                    continue

                self.log("[%d/%d] %s" % (i, total, nome), "passo")
                cover = self._extract_cover(flac, i, workdir, res)
                try:
                    rc = self._convert_one(flac, out_path, cover, codec, quality, aac_runtime)
                except Cancelled:
                    # remove saída parcial
                    if os.path.isfile(out_path):
                        try:
                            os.remove(out_path)
                        except OSError:
                            pass
                    raise
                if rc == 0:
                    self.log("    %s convertido com sucesso!" % nome, "ok")
                    convertidos += 1
                else:
                    self.log("    A conversão de %s falhou (rc=%s)!" % (nome, rc), "erro")
                    pulados += 1
                self.file_progress(100)
                # limpa capas desta faixa
                for p in (os.path.join(workdir, "cover_%d.png" % i),
                          os.path.join(workdir, "cover_%d_resized.png" % i)):
                    try:
                        os.remove(p)
                    except OSError:
                        pass
            self.overall_progress(total, total)
        finally:
            shutil.rmtree(workdir, ignore_errors=True)
        return (convertidos, pulados)


# ==========================================================================
# INTERFACE GRÁFICA  (tkinter)
# ==========================================================================
def launch_gui():
    import tkinter as tk
    from tkinter import ttk, filedialog, scrolledtext, messagebox

    engine_probe = ConversionEngine()

    # Codecs como radio buttons, na ordem pedida e sem extensão no rótulo.
    # Padrão da interface é sempre AAC (definido no StringVar).
    CODEC_ORDER = [("Opus", "opus"), ("AAC", "aac"), ("MP3", "mp3")]

    # Perfis de capa como radio buttons.
    COVER_RADIOS = [
        ("200x200px", 200), ("300x300px", 300), ("600x600px", 600),
        ("1400x1400px", 1400), ("2400x2400px", 2400), ("Original", 0),
    ]
    COVER_DEFAULT = 300

    def audio_quality_groups(codec, libfdk_path):
        """
        Opções de qualidade separadas em campos VBR e CBR (apenas visual; a
        seleção é um único radio compartilhado). Retorna:
          {"vbr": [(rótulo, dados)], "cbr": [(rótulo, dados)], "default": (campo, idx)}
        'dados' é o mesmo formato consumido por convert_batch.
        """
        if codec == "opus":
            vbr = [("256 kbps", {"bitrate": "256"}),
                   ("192 kbps", {"bitrate": "192"}),
                   ("128 kbps", {"bitrate": "128"})]
            return {"vbr": vbr, "cbr": [], "default": ("vbr", 1)}  # 192
        if codec == "mp3":
            mk = lambda flag, val, info: {"args": ["-c:a", "libmp3lame", flag, val],
                                          "info": info}
            vbr = [("V0 (~245 kbps)", mk("-q:a", "0", "V0 VBR")),
                   ("V2 (~190 kbps)", mk("-q:a", "2", "V2 VBR"))]
            cbr = [("320 kbps", mk("-b:a", "320k", "320k CBR")),
                   ("256 kbps", mk("-b:a", "256k", "256k CBR")),
                   ("128 kbps", mk("-b:a", "128k", "128k CBR"))]
            return {"vbr": vbr, "cbr": cbr, "default": ("vbr", 0)}  # V0
        if codec == "aac":
            _, enc, _ = engine_probe.resolve_aac(libfdk_path)
            enc = enc or "aac"
            vbr_extra = ["-vbr", "5"] if enc == "libfdk_aac" else ["-q:a", "1.4"]
            vbr = [("Q5", {"args": ["-c:a", enc, *vbr_extra], "info": "VBR Q5"})]
            cbr = [("256 kbps", {"args": ["-c:a", enc, "-b:a", "256k"], "info": "256k CBR"}),
                   ("192 kbps", {"args": ["-c:a", enc, "-b:a", "192k"], "info": "192k CBR"}),
                   ("128 kbps", {"args": ["-c:a", enc, "-b:a", "128k"], "info": "128k CBR"})]
            return {"vbr": vbr, "cbr": cbr, "default": ("vbr", 0)}  # Q5
        raise ValueError("codec desconhecido: %r" % codec)

    class App(tk.Tk):
        def __init__(self):
            super().__init__()
            self.title("Conversor FLAC — Opus / MP3 / AAC")
            self.geometry("800x780")
            self.minsize(720, 680)

            self.q = queue.Queue()
            self.cancel_event = threading.Event()
            self.worker = None
            self.libfdk_path = tk.StringVar(value="/opt/ffmpeg-libfdk/bin/ffmpeg")

            self._build()
            self._check_deps()
            self.after(80, self._drain_queue)
            self.protocol("WM_DELETE_WINDOW", self._on_close)

        # ---------- construção da UI ----------
        def _build(self):
            pad = {"padx": 8, "pady": 4}

            # ---- bloco: pasta de origem + operação de arquivos ----
            src_box = ttk.LabelFrame(self, text="Pasta de origem")
            src_box.pack(fill="x", **pad)
            self.src_var = tk.StringVar()
            ttk.Entry(src_box, textvariable=self.src_var).grid(
                row=0, column=0, sticky="ew", padx=6, pady=4)
            ttk.Button(src_box, text="Escolher…", command=self._pick_dir).grid(
                row=0, column=1, padx=6)
            ops = ttk.Frame(src_box)
            ops.grid(row=1, column=0, columnspan=2, sticky="w", padx=6, pady=(0, 4))
            self.recursive_var = tk.BooleanVar(value=False)
            ttk.Checkbutton(ops, text="Incluir subpastas",
                            variable=self.recursive_var).pack(side="left")
            self.skip_var = tk.BooleanVar(value=False)
            ttk.Checkbutton(ops, text="Pular convertidos",
                            variable=self.skip_var).pack(side="left", padx=18)
            src_box.columnconfigure(0, weight=1)

            # ---- bloco: opções de codec (codec + qualidade de áudio) ----
            codec_box = ttk.LabelFrame(self, text="Opções de Codec")
            codec_box.pack(fill="x", **pad)

            crow = ttk.Frame(codec_box)
            crow.pack(fill="x", padx=6, pady=(6, 2))
            ttk.Label(crow, text="Codec:").pack(side="left")
            self.codec_sel = tk.StringVar(value="aac")  # padrão SEMPRE AAC
            for label, key in CODEC_ORDER:
                ttk.Radiobutton(crow, text=label, value=key,
                                variable=self.codec_sel,
                                command=self._rebuild_quality).pack(side="left", padx=10)

            ttk.Label(codec_box, text="Qualidade de áudio:").pack(
                anchor="w", padx=6, pady=(6, 0))
            qrow = ttk.Frame(codec_box)
            qrow.pack(fill="x", padx=6, pady=(2, 8))
            self.vbr_box = ttk.LabelFrame(qrow, text="VBR")
            self.vbr_box.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
            self.cbr_box = ttk.LabelFrame(qrow, text="CBR")
            self.cbr_box.grid(row=0, column=1, sticky="nsew")
            qrow.columnconfigure(0, weight=1, uniform="qcol")
            qrow.columnconfigure(1, weight=1, uniform="qcol")
            self.quality_sel = tk.StringVar()   # radio único: "vbr:i" ou "cbr:i"
            self._quality_map = {}              # chave -> (rótulo, dados)

            # ---- bloco: qualidade de capa ----
            cover_box = ttk.LabelFrame(self, text="Qualidade de Capa")
            cover_box.pack(fill="x", **pad)
            self.cover_sel = tk.IntVar(value=COVER_DEFAULT)
            crow2 = ttk.Frame(cover_box)
            crow2.pack(fill="x", padx=6, pady=6)
            for label, val in COVER_RADIOS:
                ttk.Radiobutton(crow2, text=label, value=val,
                                variable=self.cover_sel).pack(side="left", padx=6)

            # ações
            act = ttk.Frame(self); act.pack(fill="x", **pad)
            self.start_btn = ttk.Button(act, text="Converter", command=self._start)
            self.start_btn.pack(side="left")
            self.cancel_btn = ttk.Button(act, text="Cancelar", command=self._cancel, state="disabled")
            self.cancel_btn.pack(side="left", padx=6)
            self.clear_btn = ttk.Button(act, text="Limpar log", command=self._clear_log)
            self.clear_btn.pack(side="left")

            # progresso
            prog = ttk.Frame(self); prog.pack(fill="x", **pad)
            ttk.Label(prog, text="Total:").grid(row=0, column=0, sticky="w")
            self.overall = ttk.Progressbar(prog, mode="determinate", maximum=100)
            self.overall.grid(row=0, column=1, sticky="ew", padx=6)
            self.overall_lbl = ttk.Label(prog, text="0/0")
            self.overall_lbl.grid(row=0, column=2)
            ttk.Label(prog, text="Arquivo:").grid(row=1, column=0, sticky="w")
            self.filebar = ttk.Progressbar(prog, mode="determinate", maximum=100)
            self.filebar.grid(row=1, column=1, sticky="ew", padx=6, pady=2)
            self.file_lbl = ttk.Label(prog, text="—")
            self.file_lbl.grid(row=1, column=2)
            prog.columnconfigure(1, weight=1)

            # log
            self.log = scrolledtext.ScrolledText(self, height=12, wrap="word",
                                                 state="disabled", font=("monospace", 10))
            self.log.pack(fill="both", expand=True, **pad)
            self.log.tag_config("ok", foreground="#1a7f37")
            self.log.tag_config("erro", foreground="#cf222e")
            self.log.tag_config("aviso", foreground="#9a6700")
            self.log.tag_config("info", foreground="#0969da")
            self.log.tag_config("passo", foreground="#24292f")

            self.status = ttk.Label(self, text="Pronto.", anchor="w", relief="sunken")
            self.status.pack(fill="x", side="bottom")

            self._rebuild_quality()

        # ---------- dependências / qualidade ----------
        def _check_deps(self):
            faltando = []
            if not engine_probe.metaflac: faltando.append("metaflac (flac)")
            if not engine_probe.img_cmd:  faltando.append("ImageMagick (magick/convert)")
            if not engine_probe.ffmpeg:   faltando.append("ffmpeg")
            if not engine_probe.opusenc:  faltando.append("opusenc (opus-tools)")
            if faltando:
                self._log_line("Dependências ausentes: " + ", ".join(faltando), "aviso")
                self._log_line("Codecs que dependem delas ficarão indisponíveis.", "aviso")
            else:
                self._log_line("Todas as dependências encontradas.", "ok")
            enc, msg = engine_probe.diagnose_aac(self.libfdk_path.get())
            self._log_line(msg, "info" if enc == "libfdk_aac" else "aviso")

        def _rebuild_quality(self):
            """Repovoa os campos VBR/CBR conforme o codec e marca o padrão."""
            codec = self.codec_sel.get()
            groups = audio_quality_groups(codec, self.libfdk_path.get())
            for w in self.vbr_box.winfo_children():
                w.destroy()
            for w in self.cbr_box.winfo_children():
                w.destroy()
            self._quality_map = {}

            def preencher(box, campo, itens):
                if not itens:
                    ttk.Label(box, text="— não se aplica —",
                              foreground="#999").pack(anchor="w", padx=6, pady=4)
                    return
                for i, (rotulo, dados) in enumerate(itens):
                    chave = "%s:%d" % (campo, i)
                    self._quality_map[chave] = (rotulo, dados)
                    ttk.Radiobutton(box, text=rotulo, value=chave,
                                    variable=self.quality_sel).pack(
                                        anchor="w", padx=6, pady=1)

            preencher(self.vbr_box, "vbr", groups["vbr"])
            preencher(self.cbr_box, "cbr", groups["cbr"])
            dcampo, didx = groups["default"]
            self.quality_sel.set("%s:%d" % (dcampo, didx))

        # ---------- ações ----------
        def _pick_dir(self):
            d = filedialog.askdirectory(title="Escolha a pasta com os FLAC")
            if d:
                self.src_var.set(d)

        def _clear_log(self):
            self.log.configure(state="normal")
            self.log.delete("1.0", "end")
            self.log.configure(state="disabled")

        def _start(self):
            src = self.src_var.get().strip()
            if not src or not os.path.isdir(src):
                messagebox.showerror("Erro", "Escolha uma pasta de origem válida.")
                return
            codec = self.codec_sel.get()
            qkey = self.quality_sel.get()
            if qkey not in self._quality_map:
                messagebox.showerror("Erro", "Escolha uma qualidade de áudio.")
                return
            qinfo, quality = self._quality_map[qkey]
            res = int(self.cover_sel.get())
            recursive = self.recursive_var.get()
            skip = self.skip_var.get()
            ext = {"opus": "opus", "mp3": "mp3", "aac": "m4a"}[codec]
            out_dir = os.path.join(src, "convertidos_" + ext)

            self.cancel_event.clear()
            self.start_btn.configure(state="disabled")
            self.cancel_btn.configure(state="normal")
            self.status.configure(text="Convertendo…")
            self._log_line("=== Início | %s | %s ===" % (codec.upper(), qinfo), "info")

            engine = ConversionEngine(
                log_cb=lambda t, n="passo": self.q.put(("log", t, n)),
                file_progress_cb=lambda p: self.q.put(("file", p)),
                overall_progress_cb=lambda d, t: self.q.put(("overall", d, t)),
                cancel_event=self.cancel_event,
            )

            def run():
                try:
                    conv, pul = engine.convert_batch(
                        src, codec, quality, res, recursive, skip, out_dir,
                        libfdk_path=self.libfdk_path.get())
                    self.q.put(("done", conv, pul))
                except Cancelled:
                    self.q.put(("cancelled",))
                except ConversionError as e:
                    self.q.put(("fatal", str(e)))
                except Exception as e:  # rede de segurança
                    self.q.put(("fatal", "Erro inesperado: %s" % e))

            self.worker = threading.Thread(target=run, daemon=True)
            self.worker.start()

        def _cancel(self):
            self.cancel_event.set()
            self.status.configure(text="Cancelando…")
            self.cancel_btn.configure(state="disabled")

        def _on_close(self):
            if self.worker and self.worker.is_alive():
                if not messagebox.askyesno("Sair", "Conversão em andamento. Cancelar e sair?"):
                    return
                self.cancel_event.set()
            self.destroy()

        # ---------- fila de eventos do worker ----------
        def _drain_queue(self):
            try:
                while True:
                    msg = self.q.get_nowait()
                    kind = msg[0]
                    if kind == "log":
                        self._log_line(msg[1], msg[2])
                    elif kind == "file":
                        self.filebar["value"] = msg[1]
                        self.file_lbl.configure(text="%d%%" % int(msg[1]))
                    elif kind == "overall":
                        done, total = msg[1], msg[2]
                        self.overall["value"] = (done / total * 100) if total else 0
                        self.overall_lbl.configure(text="%d/%d" % (done, total))
                    elif kind in ("done", "cancelled", "fatal"):
                        self._finish(msg)
            except queue.Empty:
                pass
            self.after(80, self._drain_queue)

        def _finish(self, msg):
            self.start_btn.configure(state="normal")
            self.cancel_btn.configure(state="disabled")
            if msg[0] == "done":
                conv, pul = msg[1], msg[2]
                self._log_line("=== Fim | Convertidos: %d | Pulados: %d ===" % (conv, pul), "info")
                self.status.configure(text="Concluído: %d convertidos, %d pulados." % (conv, pul))
            elif msg[0] == "cancelled":
                self._log_line("=== Cancelado pelo usuário ===", "aviso")
                self.status.configure(text="Cancelado.")
            else:  # fatal
                self._log_line("ERRO: " + msg[1], "erro")
                self.status.configure(text="Erro.")
                messagebox.showerror("Erro", msg[1])

        def _log_line(self, text, level="passo"):
            self.log.configure(state="normal")
            self.log.insert("end", text + "\n", level)
            self.log.see("end")
            self.log.configure(state="disabled")

    App().mainloop()


if __name__ == "__main__":
    launch_gui()
