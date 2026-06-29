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

        # — ações —
        af = ttk.Frame(main)
        af.grid(row=2, column=0, sticky="ew", **pad)
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
        pf.grid(row=3, column=0, sticky="ew", **pad)
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
        logf.grid(row=4, column=0, sticky="nsew", **pad)
        logf.columnconfigure(0, weight=1)
        logf.rowconfigure(0, weight=1)
        main.rowconfigure(4, weight=2)
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

        params = dict(
            sh=self.sh, script=self.script, mode=self.mode_var.get(),
            dest=self.dest_var.get().strip(), skip_sys=self.skip_sys_var.get(),
            isos=list(self.isos),
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
            rc = run_one(cmd, cwd,
                         lambda kind, text: self.events.put((kind, text)),
                         self.cancel_flag.is_set)
            results.append((iso, rc))
            self.events.put(("file_done", iso, rc))
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
    root = tk.Tk()
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
