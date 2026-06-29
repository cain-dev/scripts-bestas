#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
xiso_gui.py — interface Tkinter para o xiso.sh (extrator de Xbox ISO / XDVDFS).

Envolve o script POSIX xiso.sh em uma GUI:
  * seleção de um ou vários arquivos .iso (processados em sequência);
  * modo Extrair ou Listar;
  * pasta de destino (com subpasta por ISO quando há vários);
  * opção de pular $SystemUpdate;
  * log ao vivo + barra de progresso por arquivo e geral;
  * leitura do contador de progresso que o xiso.sh emite no stderr;
  * mapeamento dos códigos de saída do script (0 ok / 1 avisos / 2 truncamento).

Requer: Python 3 com Tkinter, e um shell `sh` no PATH (Linux/macOS; no Windows,
use WSL ou Git Bash). O xiso.sh é localizado automaticamente ao lado deste
arquivo; é possível apontar outro caminho na interface.

Uso: python3 xiso_gui.py
"""

import os
import re
import sys
import time
import queue
import shutil
import ftplib
import threading
import subprocess

import tkinter as tk
from tkinter import ttk, filedialog, messagebox


# ──────────────────────────────────────────────────────────────────────────────
# Núcleo (sem Tk) — testável isoladamente
# ──────────────────────────────────────────────────────────────────────────────

# Significado dos códigos de saída definidos no xiso.sh (v1.8).
EXIT_MEANING = {
    0: ("ok", "Concluído sem avisos"),
    1: ("warn", "Concluído com avisos (verifique o log)"),
    2: ("error", "Truncamento — extração incompleta"),
}

# Linha do contador de progresso emitida pelo xiso.sh: "<n> arquivos, <m>
# bytes...". É específica o bastante para não casar com as linhas de resumo
# ("N arquivo(s), ... total" / "N arquivo(s) extraídos para ..."), que têm
# parênteses e devem ir para o log, não para o label de status.
PROGRESS_RE = re.compile(r"^\d+ arquivos, \d+ bytes\.\.\.$")


def script_path():
    """Caminho do xiso.sh — presumido no mesmo diretório deste arquivo."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "xiso.sh")


def iso_basename(iso_path):
    """Nome do ISO sem extensão .iso (case-insensitive), como o script faz."""
    base = os.path.basename(iso_path)
    root, ext = os.path.splitext(base)
    return root if ext.lower() == ".iso" else base


def build_command(sh, script, iso, mode, dest, skip_sys):
    """
    Monta (cmd, cwd, target_dir) para um ISO.

    Destino (decisão da interface, não do script): em modo extrair, CADA ISO
    vai para uma pasta própria com o nome do ISO. Se `dest` foi informado,
    extrai em dest/<nome do ISO>; sem `dest`, usa o padrão do script (cria
    ./<nome>/) com cwd na pasta do próprio ISO. Ex.: dest="/mnt/BACKUP_2TB" e
    iso="Assassin's Creed (USA).iso" -> "/mnt/BACKUP_2TB/Assassin's Creed (USA)".

    Isto é feito só repassando "-d <pasta>" ao script — sem alterá-lo.

    target_dir é a pasta onde o conteúdo será escrito (para a GUI medir
    velocidade/progresso pelo crescimento da pasta); None no modo listar.
    """
    cmd = [sh, script]
    cmd.append("-l" if mode == "list" else "-x")
    if skip_sys:
        cmd.append("-s")

    cwd = None
    target_dir = None
    if mode == "extract":
        name = iso_basename(iso)
        if dest:
            target_dir = os.path.join(dest, name)
            cmd += ["-d", target_dir]
        else:
            iso_dir = os.path.dirname(os.path.abspath(iso)) or "."
            cwd = iso_dir
            target_dir = os.path.join(iso_dir, name)  # script cria ./<nome>/

    cmd.append(iso)
    return cmd, cwd, target_dir


def dir_size(path):
    """Soma o tamanho dos arquivos sob `path` (recursivo, tolerante a erros).
    Usado para medir o quanto já foi extraído sem instrumentar o script."""
    total = 0
    try:
        with os.scandir(path) as it:
            for entry in it:
                try:
                    if entry.is_file(follow_symlinks=False):
                        total += entry.stat(follow_symlinks=False).st_size
                    elif entry.is_dir(follow_symlinks=False):
                        total += dir_size(entry.path)
                except OSError:
                    pass
    except OSError:
        pass
    return total


def human_bytes(n):
    """Formata bytes em unidade legível (decimal: KB=1000)."""
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000


def human_speed(bps):
    """Formata uma taxa em bytes/s."""
    return human_bytes(bps) + "/s"


def _now():
    """Relógio monotônico (imune a ajustes do relógio do sistema)."""
    return time.monotonic()


def iter_output(stream):
    """
    Itera a saída combinada (stdout+stderr) byte a byte, emitindo segmentos
    sempre que encontra '\\n' ou '\\r'. Necessário porque o contador de
    progresso do xiso.sh usa '\\r' sem newline para reescrever a linha.

    IMPORTANTE: opera em BYTES, não texto. O modo texto do Python aplica
    "universal newlines" e converte '\\r' em '\\n', o que apagaria justamente
    as atualizações de progresso. Por isso o stream deve ser binário e a
    decodificação é feita aqui (utf-8, erros substituídos).

    Produz tuplas (texto, terminador) com terminador '\\n' (linha completa,
    vai para o log) ou '\\r' (atualização transitória de status).
    """
    buf = bytearray()
    while True:
        ch = stream.read(1)
        if ch == b"":
            break
        if ch == b"\n" or ch == b"\r":
            yield buf.decode("utf-8", "replace"), ch.decode("ascii")
            buf = bytearray()
        else:
            buf += ch
    if buf:
        yield buf.decode("utf-8", "replace"), "\n"


def run_one(cmd, cwd, emit, should_cancel):
    """
    Executa um comando, encaminhando saída via callback `emit(kind, text)`
    onde kind ∈ {'log', 'status'}. Retorna o código de saída (-1 cancelado,
    -2 erro ao iniciar).

    stdout e stderr são lidos em pipes SEPARADOS (uma thread para o stderr).
    Mesclá-los embaralha o parsing: o contador de progresso do xiso.sh vive no
    stderr e usa '\\r' sem '\\n', enquanto o stdout entrega linhas de log
    terminadas por '\\n'. Num cano único, o contador gruda na próxima linha de
    log. Separados, cada canal fica limpo:
      * stdout  -> sempre log;
      * stderr  -> progresso (vira status) ou AVISO/ERRO (vira log).

    Sem dependência de Tk — usado tanto pela GUI quanto pelos testes.
    """
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,  # binário, sem buffer; iter_output decodifica
        )
    except FileNotFoundError as exc:
        emit("log", f"ERRO: não foi possível executar: {exc}")
        return -2

    def pump_stderr():
        # stderr carrega o progresso (\r) e mensagens AVISO/ERRO (\n).
        for text, term in iter_output(proc.stderr):
            s = text.strip()
            if not s:
                continue
            if PROGRESS_RE.match(s) or term == "\r":
                emit("status", s)
            else:
                emit("log", s)  # AVISO:/ERRO: → log

    err_thread = threading.Thread(target=pump_stderr, daemon=True)
    err_thread.start()

    for text, term in iter_output(proc.stdout):
        if should_cancel():
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
            emit("log", "— cancelado pelo usuário —")
            err_thread.join(timeout=2)
            return -1
        emit("log", text)

    proc.wait()
    err_thread.join(timeout=2)
    return proc.returncode


# ──────────────────────────────────────────────────────────────────────────────
# Envio FTP (opcional, pós-extração) — sem Tk, testável
# ──────────────────────────────────────────────────────────────────────────────
#
# Apenas FTP explícito (sem criptografia), que é o que os dashboards de Xbox
# expõem — no máximo com usuário/senha, ou convidado (anônimo). Dependência
# ZERO (módulo ftplib da stdlib). O envio é um passo isolado APÓS uma extração
# bem-sucedida — não toca no fluxo de extração nem no xiso.sh.

def _walk_files(local_dir):
    """Gera (caminho_local, caminho_relativo) para cada arquivo sob local_dir,
    em ordem estável (pastas/arquivos ordenados)."""
    base = os.path.abspath(local_dir)
    for root_, dirs, files in os.walk(base):
        dirs.sort()
        for fn in sorted(files):
            full = os.path.join(root_, fn)
            yield full, os.path.relpath(full, base)


def _remote_join(*parts):
    """Junta componentes de caminho remoto sempre com '/' (FTP usa POSIX),
    preservando uma eventual barra inicial absoluta."""
    absolute = parts[0].startswith("/") if parts else False
    segs = []
    for p in parts:
        for s in p.replace("\\", "/").split("/"):
            if s:
                segs.append(s)
    return ("/" if absolute else "") + "/".join(segs)


def _ftp_ensure_dir(ftp, path):
    """Cria `path` no servidor FTP nível a nível, ignorando os que já existem."""
    absolute = path.startswith("/")
    built = ""
    for seg in [s for s in path.split("/") if s]:
        built = _remote_join(built, seg) if built else (("/" + seg) if absolute else seg)
        try:
            ftp.mkd(built)
        except ftplib.error_perm:
            pass  # 550: provavelmente já existe — segue


def upload_tree_ftp(cfg, local_dir, emit, should_cancel):
    """Envia recursivamente local_dir para cfg['remote_dir']/<nome> via FTP.
    cfg: host, port, user, password, guest, remote_dir.
    Retorna True em sucesso. Reporta via emit(kind, value)."""
    game = os.path.basename(os.path.normpath(local_dir))
    base = _remote_join(cfg["remote_dir"], game)

    emit("log", f"Conectando (FTP) a {cfg['host']}:{cfg['port']}…")
    ftp = ftplib.FTP()
    try:
        ftp.connect(cfg["host"], int(cfg["port"]), timeout=30)
        if cfg.get("guest"):
            ftp.login()  # anônimo
        else:
            ftp.login(cfg["user"], cfg["password"])

        files = list(_walk_files(local_dir))
        total = sum((os.path.getsize(f) for f, _ in files), 0) or 1
        sent = [0]
        t0 = _now()
        last = [0.0]

        def report(force=False):
            now = _now()
            if not force and now - last[0] < 0.3:
                return
            last[0] = now
            pct = min(100.0, sent[0] / total * 100.0)
            spd = sent[0] / max(1e-6, now - t0)
            emit("progress", pct)
            emit("status", f"Enviando {game}: {pct:.0f}% — {human_speed(spd)}")

        _ftp_ensure_dir(ftp, base)
        for full, rel in files:
            if should_cancel():
                emit("log", "— envio cancelado —")
                ftp.close()
                return False
            relposix = rel.replace(os.sep, "/")
            rdir = os.path.dirname(relposix)
            if rdir:
                _ftp_ensure_dir(ftp, _remote_join(base, rdir))
            rpath = _remote_join(base, relposix)

            def cb(block):
                sent[0] += len(block)
                report()

            with open(full, "rb") as fh:
                ftp.storbinary("STOR " + rpath, fh, blocksize=65536, callback=cb)
            report(force=True)

        try:
            ftp.quit()
        except Exception:
            ftp.close()
        emit("progress", 100.0)
        emit("log", f"Envio concluído: {len(files)} arquivo(s) -> {base}")
        return True
    except Exception as exc:
        emit("log", f"ERRO no envio FTP: {exc}")
        try:
            ftp.close()
        except Exception:
            pass
        return False


# Alias mantido para os chamadores; só FTP.
def upload_tree(cfg, local_dir, emit, should_cancel):
    return upload_tree_ftp(cfg, local_dir, emit, should_cancel)


# ──────────────────────────────────────────────────────────────────────────────
# GUI
# ──────────────────────────────────────────────────────────────────────────────

class XisoGUI:
    POLL_MS = 40

    def __init__(self, root):
        self.root = root
        self.root.title("xiso — extrator de Xbox ISO")
        self.root.minsize(680, 560)

        self.events = queue.Queue()
        self.worker = None
        self.cancel_flag = threading.Event()

        self.sh = shutil.which("sh")
        self.script = script_path()
        self.mode_var = tk.StringVar(value="extract")
        self.dest_var = tk.StringVar(value="")
        self.skip_sys_var = tk.BooleanVar(value=False)
        self.isos = []  # caminhos absolutos

        # campos de envio FTP (opcional, pós-extração) — só FTP explícito
        self.up_enable_var = tk.BooleanVar(value=False)
        self.up_host_var = tk.StringVar(value="")
        self.up_port_var = tk.StringVar(value="21")
        self.up_user_var = tk.StringVar(value="")
        self.up_pass_var = tk.StringVar(value="")
        self.up_guest_var = tk.BooleanVar(value=False)
        self.up_remote_var = tk.StringVar(value="/")

        # estado do amostrador de velocidade (mede crescimento da pasta-alvo)
        self._sampler_id = None
        self._spl_target = None
        self._spl_isosize = 0
        self._spl_t0 = 0.0
        self._spl_last_t = 0.0
        self._spl_last_bytes = 0
        self._spl_ema = 0.0  # B/s suavizado

        self._build_ui()
        self._refresh_state()
        self.root.after(self.POLL_MS, self._poll_events)

        problems = []
        if not self.sh:
            problems.append("• Interpretador 'sh' não encontrado no PATH "
                            "(use WSL/Git Bash no Windows).")
        if not os.path.isfile(self.script):
            problems.append(f"• xiso.sh não encontrado em:\n  {self.script}\n"
                            "  Mantenha xiso_gui.py e xiso.sh na mesma pasta.")
        if problems:
            messagebox.showwarning("Atenção", "\n\n".join(problems))

    # ── construção da interface ─────────────────────────────────────────────
    def _build_ui(self):
        pad = {"padx": 8, "pady": 4}
        main = ttk.Frame(self.root, padding=10)
        main.pack(fill="both", expand=True)
        main.columnconfigure(0, weight=1)

        # — ISOs —
        lf = ttk.LabelFrame(main, text="Arquivos ISO")
        lf.grid(row=0, column=0, sticky="nsew", **pad)
        lf.columnconfigure(0, weight=1)
        lf.rowconfigure(0, weight=1)
        main.rowconfigure(0, weight=1)

        self.iso_list = tk.Listbox(lf, height=5, selectmode="extended",
                                   activestyle="none")
        self.iso_list.grid(row=0, column=0, sticky="nsew", padx=6, pady=6)
        sb = ttk.Scrollbar(lf, orient="vertical",
                           command=self.iso_list.yview)
        sb.grid(row=0, column=1, sticky="ns", pady=6)
        self.iso_list.config(yscrollcommand=sb.set)

        btns = ttk.Frame(lf)
        btns.grid(row=1, column=0, columnspan=2, sticky="ew", padx=6, pady=4)
        ttk.Button(btns, text="Adicionar…",
                   command=self._add_isos).pack(side="left")
        ttk.Button(btns, text="Remover selecionados",
                   command=self._remove_isos).pack(side="left", padx=6)
        ttk.Button(btns, text="Limpar",
                   command=self._clear_isos).pack(side="left")

        # — opções —
        of = ttk.LabelFrame(main, text="Opções")
        of.grid(row=1, column=0, sticky="ew", **pad)
        of.columnconfigure(1, weight=1)

        ttk.Label(of, text="Modo:").grid(row=0, column=0, sticky="w",
                                         padx=6, pady=4)
        mode_frame = ttk.Frame(of)
        mode_frame.grid(row=0, column=1, sticky="w")
        ttk.Radiobutton(mode_frame, text="Extrair", value="extract",
                        variable=self.mode_var,
                        command=self._refresh_state).pack(side="left")
        ttk.Radiobutton(mode_frame, text="Listar", value="list",
                        variable=self.mode_var,
                        command=self._refresh_state).pack(side="left", padx=10)

        ttk.Label(of, text="Pasta de destino:").grid(
            row=1, column=0, sticky="w", padx=6, pady=4)
        dest_frame = ttk.Frame(of)
        dest_frame.grid(row=1, column=1, sticky="ew", padx=6)
        dest_frame.columnconfigure(0, weight=1)
        self.dest_entry = ttk.Entry(dest_frame, textvariable=self.dest_var)
        self.dest_entry.grid(row=0, column=0, sticky="ew")
        self.dest_btn = ttk.Button(dest_frame, text="Procurar…",
                                   command=self._pick_dest)
        self.dest_btn.grid(row=0, column=1, padx=6)

        self.dest_hint = ttk.Label(
            of, foreground="#666",
            text="Cada ISO é extraído para uma pasta própria, com o nome do ISO. "
                 "Vazio: ao lado de cada ISO.")
        self.dest_hint.grid(row=2, column=1, sticky="w", padx=6)

        ttk.Checkbutton(of, text="Pular $SystemUpdate",
                        variable=self.skip_sys_var).grid(
            row=3, column=1, sticky="w", padx=6, pady=4)

        # — envio FTP (opcional, pós-extração) —
        ff = ttk.LabelFrame(main, text="Enviar após extrair (FTP)")
        ff.grid(row=2, column=0, sticky="ew", **pad)
        for c in (1, 3):
            ff.columnconfigure(c, weight=1)

        ttk.Checkbutton(ff, text="Habilitar envio", variable=self.up_enable_var,
                        command=self._refresh_state).grid(
            row=0, column=0, columnspan=4, sticky="w", padx=6, pady=4)

        ttk.Label(ff, text="Servidor:").grid(row=1, column=0, sticky="e", padx=6)
        self.up_host = ttk.Entry(ff, textvariable=self.up_host_var)
        self.up_host.grid(row=1, column=1, sticky="ew", padx=6, pady=2)
        ttk.Label(ff, text="Porta:").grid(row=1, column=2, sticky="e", padx=6)
        self.up_port = ttk.Entry(ff, textvariable=self.up_port_var, width=8)
        self.up_port.grid(row=1, column=3, sticky="w", padx=6, pady=2)

        ttk.Label(ff, text="Usuário:").grid(row=2, column=0, sticky="e", padx=6)
        self.up_user = ttk.Entry(ff, textvariable=self.up_user_var)
        self.up_user.grid(row=2, column=1, sticky="ew", padx=6, pady=2)
        ttk.Label(ff, text="Senha:").grid(row=2, column=2, sticky="e", padx=6)
        self.up_pass = ttk.Entry(ff, textvariable=self.up_pass_var, show="•")
        self.up_pass.grid(row=2, column=3, sticky="ew", padx=6, pady=2)

        self.up_guest = ttk.Checkbutton(
            ff, text="Convidado (anônimo)", variable=self.up_guest_var,
            command=self._refresh_state)
        self.up_guest.grid(row=3, column=0, columnspan=2, sticky="w", padx=6)

        ttk.Label(ff, text="Pasta de jogos (remota):").grid(
            row=4, column=0, sticky="e", padx=6, pady=2)
        self.up_remote = ttk.Entry(ff, textvariable=self.up_remote_var)
        self.up_remote.grid(row=4, column=1, columnspan=3, sticky="ew",
                            padx=6, pady=2)

        self.up_hint = ttk.Label(
            ff, foreground="#666",
            text="Cada jogo é enviado para <pasta remota>/<nome do ISO>. "
                 "FTP é sem criptografia — a senha trafega em texto puro.")
        self.up_hint.grid(row=5, column=0, columnspan=4, sticky="w", padx=6, pady=2)

        self._ftp_widgets = [self.up_host, self.up_port,
                             self.up_user, self.up_pass, self.up_guest,
                             self.up_remote]

        # — ações —
        af = ttk.Frame(main)
        af.grid(row=3, column=0, sticky="ew", **pad)
        self.run_btn = ttk.Button(af, text="Executar", command=self._start)
        self.run_btn.pack(side="left")
        self.cancel_btn = ttk.Button(af, text="Cancelar",
                                     command=self._cancel, state="disabled")
        self.cancel_btn.pack(side="left", padx=6)
        ttk.Button(af, text="Limpar log",
                   command=self._clear_log).pack(side="left")

        # — progresso —
        # Uma única barra. Sua cor muda a cada ISO (ver _set_bar_color), de modo
        # que, ao processar vários ISOs em fila, a troca de cor sinaliza
        # visualmente o início de uma nova ação. O "qual de quantos" aparece no
        # texto de status ("[i/total] nome").
        pf = ttk.Frame(main)
        pf.grid(row=4, column=0, sticky="ew", **pad)
        pf.columnconfigure(0, weight=1)

        self._bar_styles = []
        style = ttk.Style()
        palette = ["#2a7ade", "#7a3fd0", "#0a9d6b", "#d08a1f", "#c0457a"]
        for i, color in enumerate(palette):
            name = f"Iso{i}.Horizontal.TProgressbar"
            try:
                style.configure(name, background=color)
            except tk.TclError:
                pass
            self._bar_styles.append(name)
        # estilo distinto para a fase de ENVIO (ação diferente da extração)
        self._upload_style = "Upload.Horizontal.TProgressbar"
        try:
            style.configure(self._upload_style, background="#1f9bb3")
        except tk.TclError:
            self._upload_style = None

        self.file_bar = ttk.Progressbar(pf, mode="determinate", maximum=100)
        self.file_bar.grid(row=0, column=0, sticky="ew")
        self.status_var = tk.StringVar(value="Pronto.")
        ttk.Label(pf, textvariable=self.status_var).grid(
            row=1, column=0, sticky="w", pady=(4, 0))
        # linha de velocidade/throughput
        self.speed_var = tk.StringVar(value="")
        ttk.Label(pf, textvariable=self.speed_var,
                  foreground="#0a5").grid(row=2, column=0, sticky="w")

        # — log —
        logf = ttk.LabelFrame(main, text="Saída")
        logf.grid(row=5, column=0, sticky="nsew", **pad)
        logf.columnconfigure(0, weight=1)
        logf.rowconfigure(0, weight=1)
        main.rowconfigure(5, weight=2)
        self.log = tk.Text(logf, height=10, wrap="none",
                           state="disabled", font=("monospace", 10))
        self.log.grid(row=0, column=0, sticky="nsew", padx=6, pady=6)
        lsb = ttk.Scrollbar(logf, orient="vertical", command=self.log.yview)
        lsb.grid(row=0, column=1, sticky="ns", pady=6)
        self.log.config(yscrollcommand=lsb.set)
        self.log.tag_config("warn", foreground="#b36b00")
        self.log.tag_config("error", foreground="#b00020")
        self.log.tag_config("ok", foreground="#0a7d20")

    # ── handlers de UI ───────────────────────────────────────────────────────
    def _add_isos(self):
        paths = filedialog.askopenfilenames(
            title="Selecione um ou mais ISOs",
            filetypes=[("Xbox ISO", "*.iso *.ISO"), ("Todos", "*.*")])
        for p in paths:
            ap = os.path.abspath(p)
            if ap not in self.isos:
                self.isos.append(ap)
                self.iso_list.insert("end", ap)
        self._refresh_state()

    def _remove_isos(self):
        for i in reversed(self.iso_list.curselection()):
            self.iso_list.delete(i)
            del self.isos[i]
        self._refresh_state()

    def _clear_isos(self):
        self.iso_list.delete(0, "end")
        self.isos.clear()
        self._refresh_state()

    def _pick_dest(self):
        path = filedialog.askdirectory(title="Pasta de destino")
        if path:
            self.dest_var.set(path)

    def _clear_log(self):
        self.log.config(state="normal")
        self.log.delete("1.0", "end")
        self.log.config(state="disabled")

    def _refresh_state(self):
        extracting = self.mode_var.get() == "extract"
        state = "normal" if extracting else "disabled"
        self.dest_entry.config(state=state)
        self.dest_btn.config(state=state)
        self.dest_hint.config(foreground="#666" if extracting else "#bbb")

        # painel de envio: só faz sentido ao extrair e quando habilitado
        up_on = extracting and self.up_enable_var.get()
        for w in getattr(self, "_ftp_widgets", []):
            w.config(state="normal" if up_on else "disabled")
        # convidado desativa usuário/senha
        if up_on and self.up_guest_var.get():
            self.up_user.config(state="disabled")
            self.up_pass.config(state="disabled")

    # ── execução ──────────────────────────────────────────────────────────────
    def _start(self):
        if self.worker and self.worker.is_alive():
            return
        if not self.sh:
            messagebox.showerror("Erro", "Interpretador 'sh' não encontrado.")
            return
        if not os.path.isfile(self.script):
            messagebox.showerror(
                "Erro", f"xiso.sh não encontrado em:\n{self.script}\n\n"
                        "Mantenha xiso_gui.py e xiso.sh na mesma pasta.")
            return
        if not self.isos:
            messagebox.showinfo("Nada a fazer", "Adicione ao menos um ISO.")
            return

        self.cancel_flag.clear()
        self.run_btn.config(state="disabled")
        self.cancel_btn.config(state="normal")
        self.file_bar.config(value=0)
        self.speed_var.set("")

        upload = None
        if self.mode_var.get() == "extract" and self.up_enable_var.get():
            host = self.up_host_var.get().strip()
            if not host:
                messagebox.showerror("Erro", "Envio habilitado, mas o servidor "
                                              "FTP está vazio.")
                self.run_btn.config(state="normal")
                self.cancel_btn.config(state="disabled")
                return
            try:
                port = int(self.up_port_var.get().strip())
            except ValueError:
                messagebox.showerror("Erro", "Porta inválida.")
                self.run_btn.config(state="normal")
                self.cancel_btn.config(state="disabled")
                return
            upload = dict(
                host=host, port=port,
                user=self.up_user_var.get(), password=self.up_pass_var.get(),
                guest=self.up_guest_var.get(),
                remote_dir=self.up_remote_var.get().strip() or "/",
            )

        params = dict(
            sh=self.sh, script=self.script, mode=self.mode_var.get(),
            dest=self.dest_var.get().strip(), skip_sys=self.skip_sys_var.get(),
            isos=list(self.isos), upload=upload,
        )
        self.worker = threading.Thread(target=self._work, args=(params,),
                                       daemon=True)
        self.worker.start()

    def _cancel(self):
        self.cancel_flag.set()
        self.status_var.set("Cancelando…")

    def _work(self, p):
        """Roda em thread separada; comunica-se via self.events."""
        results = []
        total = len(p["isos"])
        emit = lambda kind, value=None: self.events.put((kind, value))
        for idx, iso in enumerate(p["isos"], start=1):
            if self.cancel_flag.is_set():
                break
            cmd, cwd, target = build_command(
                p["sh"], p["script"], iso, p["mode"], p["dest"], p["skip_sys"])
            try:
                iso_size = os.path.getsize(iso)
            except OSError:
                iso_size = 0
            self.events.put(("file_start", iso, idx, total, target, iso_size))
            self.events.put(("log", "$ " + " ".join(cmd)))
            rc = run_one(cmd, cwd, emit, self.cancel_flag.is_set)
            results.append((iso, rc))
            self.events.put(("file_done", iso, rc))

            # envio opcional: só após extração que produziu arquivos (rc 0 ou 1)
            up = p.get("upload")
            if (up and p["mode"] == "extract" and rc in (0, 1)
                    and target and os.path.isdir(target)
                    and not self.cancel_flag.is_set()):
                self.events.put(("upload_start", None))
                upload_tree(up, target, emit, self.cancel_flag.is_set)

        self.events.put(("all_done", results))

    # ── bombeamento de eventos do worker para a UI ───────────────────────────
    def _poll_events(self):
        try:
            while True:
                evt = self.events.get_nowait()
                self._handle(evt)
        except queue.Empty:
            pass
        self.root.after(self.POLL_MS, self._poll_events)

    def _handle(self, evt):
        kind = evt[0]
        if kind == "log":
            self._append(evt[1])
        elif kind == "status":
            self.status_var.set(evt[1])
        elif kind == "progress":
            self.file_bar.config(value=evt[1])
        elif kind == "upload_start":
            # nova ação (envio): barra com cor distinta e zerada
            if self._upload_style:
                self.file_bar.configure(style=self._upload_style)
            self.file_bar.config(value=0)
            self.speed_var.set("")
        elif kind == "file_start":
            _, iso, idx, total, target, iso_size = evt
            self.status_var.set(f"[{idx}/{total}] {os.path.basename(iso)}")
            self._append(f"\n=== [{idx}/{total}] {iso} ===")
            self._set_bar_color(idx - 1)  # cor distinta por ISO na fila
            self._start_sampler(target, iso_size)
        elif kind == "file_done":
            _, iso, rc = evt
            self._stop_sampler()
            tag, msg = EXIT_MEANING.get(rc, ("error", f"código {rc}"))
            if rc == -1:
                tag, msg = "warn", "cancelado"
            self._append(f"→ {os.path.basename(iso)}: {msg}", tag)
        elif kind == "all_done":
            self._finish(evt[1])

    def _set_bar_color(self, idx):
        """Aplica uma cor da paleta à barra única, ciclando por ISO. A troca
        de cor entre ISOs sinaliza que uma nova ação começou."""
        if self._bar_styles:
            self.file_bar.configure(
                style=self._bar_styles[idx % len(self._bar_styles)])

    # ── amostrador de velocidade ──────────────────────────────────────────────
    # Mede a velocidade observando o crescimento da pasta-alvo no tempo, sem
    # instrumentar o script. Funciona bem para jogos (poucos arquivos grandes),
    # onde o contador interno do xiso.sh (a cada 50 arquivos) quase nunca dispara.
    SAMPLE_MS = 700

    def _start_sampler(self, target, iso_size):
        self._spl_target = target
        self._spl_isosize = iso_size
        self._spl_t0 = self._spl_last_t = _now()
        self._spl_last_bytes = 0
        self._spl_ema = 0.0
        self.file_bar.config(value=0)
        if target is None:  # modo listar: nada a medir
            self.speed_var.set("")
            return
        self._sampler_id = self.root.after(self.SAMPLE_MS, self._sample)

    def _sample(self):
        if self._spl_target is None:
            return
        now = _now()
        size = dir_size(self._spl_target)
        dt = now - self._spl_last_t
        if dt > 0:
            inst = (size - self._spl_last_bytes) / dt
            # média móvel exponencial leve para suavizar a leitura
            self._spl_ema = inst if self._spl_ema == 0 else \
                0.6 * self._spl_ema + 0.4 * inst
        self._spl_last_t = now
        self._spl_last_bytes = size

        if self._spl_isosize > 0:
            pct = min(100.0, size / self._spl_isosize * 100.0)
            self.file_bar.config(value=pct)
            self.speed_var.set(
                f"{human_speed(self._spl_ema)} — "
                f"{human_bytes(size)} / {human_bytes(self._spl_isosize)} "
                f"({pct:.0f}%)")
        else:
            self.speed_var.set(
                f"{human_speed(self._spl_ema)} — {human_bytes(size)}")
        self._sampler_id = self.root.after(self.SAMPLE_MS, self._sample)

    def _stop_sampler(self):
        if self._sampler_id is not None:
            self.root.after_cancel(self._sampler_id)
            self._sampler_id = None
        if self._spl_target is not None and self._spl_isosize >= 0:
            elapsed = max(1e-6, _now() - self._spl_t0)
            final = dir_size(self._spl_target) if self._spl_target else 0
            if final > 0:
                avg = final / elapsed
                self.file_bar.config(value=100)
                self.speed_var.set(
                    f"média {human_speed(avg)} — {human_bytes(final)} "
                    f"em {elapsed:.1f}s")
        self._spl_target = None

    def _finish(self, results):
        self._stop_sampler()
        self.run_btn.config(state="normal")
        self.cancel_btn.config(state="disabled")
        if self.cancel_flag.is_set():
            self.status_var.set("Cancelado.")
            return
        ok = sum(1 for _, rc in results if rc == 0)
        warn = sum(1 for _, rc in results if rc == 1)
        bad = sum(1 for _, rc in results if rc not in (0, 1))
        self.status_var.set(
            f"Concluído: {ok} ok, {warn} com avisos, {bad} com erro.")

    def _append(self, text, tag=None):
        self.log.config(state="normal")
        if tag:
            self.log.insert("end", text + "\n", tag)
        else:
            self.log.insert("end", text + "\n")
        self.log.see("end")
        self.log.config(state="disabled")


def main():
    # className define o WM_CLASS (e, sob XWayland, o app_id derivado dele).
    # É o que KDE e GNOME usam para identificar a janela — nome, ícone e
    # agrupamento na barra de tarefas — em vez de tratá-la como uma janela X
    # genérica. (O Tk não tem backend Wayland nativo; em Wayland ele roda via
    # XWayland de qualquer modo, então esta é a forma de tornar a janela
    # "reconhecível" sem trocar de toolkit nem adicionar dependências.)
    # Para o ícone aparecer, instale um xiso.desktop com:
    #   StartupWMClass=xiso   (igual ao className abaixo)
    root = tk.Tk(className="xiso")
    try:
        # tema mais agradável quando disponível
        style = ttk.Style()
        if "clam" in style.theme_names():
            style.theme_use("clam")
    except tk.TclError:
        pass
    XisoGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
