#!/bin/sh
# xiso.sh — extrator e listador de Xbox ISO (XDVDFS)
# POSIX sh + extensão "local" (dash, ash, busybox sh, ksh93, zsh).
# Dependências: dd, od, tr, awk, wc — todas POSIX.
#   (mktemp é opcional; veja a nota em mark_visited / detecção de ciclos)
# Compatível com Linux, macOS, FreeBSD.
#
# Versão: 1.8
#
# Mudanças 1.7 -> 1.8 (todas marcadas com "# [1.8]" no corpo):
#   * CORREÇÃO: re-extração por cima de arquivo existente corrompia o
#     resultado em arquivos < 1 setor (o tail parcial usava ">>" e nada
#     truncava o conteúdo antigo). Agora o alvo é zerado antes de escrever
#     e o dd usa conv=notrunc. (Bug latente desde a 1.6.)
#   * Códigos de saída para automação: 0=ok, 1=avisos, 2=truncamento.
#     Permite "xiso.sh "$f" || ..." em laços detectar falhas de fato.
#   * Progresso opcional em stderr durante extração (contador de arquivos),
#     respeitando -q/-Q. Útil em ISOs de vários GB.
#   * Strip de extensão case-insensitive (.iso/.ISO/.Iso...).
#   * Aviso ao sobrescrever alvo já existente — protege contra colisão
#     silenciosa em filesystem case-insensitive (HFS+/APFS/exFAT), onde
#     "File" e "file" do XDVDFS mapeiam para o mesmo nome.
#
# Mudanças 1.6 -> 1.7 (marcadas com "# [1.7]"):
#   * Hot path: header de 14 bytes do nó lido e parseado num único awk
#     (read_node_header), em vez de 6 chamadas read_le por nó.
#     ~4-6x menos processos por nó na travessia.
#   * Detecção de ciclos O(1) por nó via diretório temporário (set baseado
#     em filesystem), substituindo a string $VISITED com glob O(n^2).
#     Inclui fallback estritamente-POSIX comentado (sem mktemp).
#   * export LC_ALL=C — torna tr/od/awk determinísticos em bytes,
#     independente do locale; reforça validate_name.
#   * Preflight de dependências com command -v (POSIX) — falha clara.
#   * read_bytes limita o 1o dd ao nº exato de blocos (não lê até EOF).
#   * -d passa a rejeitar ".." (defesa extra contra path traversal).
#
# Nota de portabilidade (32-bit): a aritmética de shell é signed long.
# Em plataformas 32-bit, "sector * SECTOR" pode estourar para ISOs muito
# grandes. Em 64-bit (caso usual) não há problema.

XISO_VERSION="1.8"

# [1.7] locale fixo em C: garante que tr '[:cntrl:]', od e awk operem em
# bytes de forma determinística, independente do ambiente do usuário.
export LC_ALL=C

# ── constantes em hex nativo ──────────────────────────────────────────────────
readonly SECTOR=2048
readonly DWORD=4
readonly HEADER_OFF=$(( 0x10000 ))
readonly OFF_GLOBAL=$(( 0x0FD90000 ))
readonly OFF_XGD3=$(( 0x02080000 ))
readonly OFF_XGD1=$(( 0x18300000 ))
readonly ATTR_DIR=$(( 0x10 ))
readonly TAIL_UNUSED=$(( 0x7C8 ))
readonly NODE_HEADER=14
readonly MAX_DEPTH=512
readonly MAX_NODES=65536
readonly READ_BLOCK=4096
readonly PROGRESS_EVERY=50   # [1.8] cadência do contador de progresso (stderr)

# magic "MICROSOFT*XBOX*MEDIA" em hex — comparado em hex para evitar
# descarte de bytes nulos em $() ao ler dados binários
readonly MAGIC_HEX="4d4943524f534f46542a58424f582a4d45444941"

# ── variáveis de controle ─────────────────────────────────────────────────────
MODE="extract"
OUTDIR=""
SKIP_SYS=0
QUIET=0
SILENT=0
TOTAL_FILES=0
TOTAL_BYTES=0
TRUNCATED=0
HAD_WARNINGS=0
ISO_SIZE=0
NODE_COUNT=0
VISITED_DIR=""   # [1.7] diretório temporário usado como set de nós visitados

# ── output ────────────────────────────────────────────────────────────────────
log()  { [ "$QUIET"  -eq 0 ] && [ "$SILENT" -eq 0 ] && printf '%s\n' "$*"; }
warn() { HAD_WARNINGS=1; [ "$SILENT" -eq 0 ] && printf 'AVISO: %s\n' "$*" >&2; }
die()  { [ "$SILENT" -eq 0 ] && printf 'ERRO: %s\n' "$*" >&2; exit 1; }

# [1.7] preflight de dependências — command -v é POSIX. Falha cedo e claro
# em vez de erro críptico no meio de uma extração.
for _cmd in dd od tr awk wc; do
    command -v "$_cmd" >/dev/null 2>&1 || die "dependência ausente: $_cmd"
done
unset _cmd

# ── leitura eficiente de bytes do ISO ─────────────────────────────────────────
# Dois dd em pipeline: o primeiro salta em blocos de READ_BLOCK (rápido),
# o segundo extrai os bytes exatos. Evita dd bs=1 skip=N com N na casa
# de centenas de MB (que faria N leituras individuais).
# ISO sempre passado como caminho absoluto — imune a cd do chamador.
read_bytes() {
    local file offset count bskip byskip nblk
    file="$1"; offset="$2"; count="$3"
    bskip=$(( offset / READ_BLOCK ))
    byskip=$(( offset % READ_BLOCK ))
    # [1.7] limita o 1o dd ao nº exato de blocos que cobrem os bytes
    # pedidos. Antes ele lia até EOF e dependia de SIGPIPE para parar —
    # desperdício em arquivos grandes.
    nblk=$(( (byskip + count + READ_BLOCK - 1) / READ_BLOCK ))
    dd if="$file" bs="$READ_BLOCK" skip="$bskip" count="$nblk" 2>/dev/null \
    | dd bs=1 skip="$byskip" count="$count" 2>/dev/null
}

# ── ler N bytes little-endian no offset e retornar decimal ───────────────────
# printf "%.0f" evita notação científica em valores uint32 grandes.
# Mantido para as poucas leituras de metadados em process_iso.
read_le() {
    local file offset nbytes
    file="$1"; offset="$2"; nbytes="$3"
    read_bytes "$file" "$offset" "$nbytes" \
    | od -An -tx1 \
    | tr -d ' \t\n' \
    | awk '{
        n = length($0) / 2
        val = 0
        for (i = n; i >= 1; i--) {
            chunk = substr($0, (i-1)*2+1, 2)
            hi = index("0123456789abcdef", substr(chunk,1,1)) - 1
            lo = index("0123456789abcdef", substr(chunk,2,1)) - 1
            val = val * 256 + hi * 16 + lo
        }
        printf "%.0f\n", val
    }'
}

# [1.7] ── ler o cabeçalho de 14 bytes do nó de uma só vez ─────────────────────
# Substitui as 6 chamadas read_le por nó (cada uma = dd|dd|od|tr|awk) por
# um único pipeline. A matemática little-endian é idêntica à de read_le,
# apenas aplicada a 6 campos no mesmo awk.
#
# Saída: "l_off r_off sector fsize attr name_len" (decimais, espaço-sep.)
# Layout do header XDVDFS:
#   off  0  uint16 l_off     off  8  uint32 fsize
#   off  2  uint16 r_off     off 12  uint8  attr
#   off  4  uint32 sector    off 13  uint8  name_len
read_node_header() {
    read_bytes "$1" "$2" "$NODE_HEADER" \
    | od -An -tx1 \
    | tr -d ' \t\n' \
    | awk '
    function le(s, nb,   i, c, hi, lo, v) {
        v = 0
        for (i = nb; i >= 1; i--) {
            c  = substr(s, (i-1)*2+1, 2)
            hi = index("0123456789abcdef", substr(c,1,1)) - 1
            lo = index("0123456789abcdef", substr(c,2,1)) - 1
            v  = v * 256 + hi * 16 + lo
        }
        return v
    }
    {
        # 14 bytes = 28 chars hex; leitura curta => header incompleto
        if (length($0) < 28) exit 1
        printf "%.0f %.0f %.0f %.0f %.0f %.0f\n",
            le(substr($0, 1,  4), 2),   # l_off    (bytes 0-1)
            le(substr($0, 5,  4), 2),   # r_off    (bytes 2-3)
            le(substr($0, 9,  8), 4),   # sector   (bytes 4-7)
            le(substr($0, 17, 8), 4),   # fsize    (bytes 8-11)
            le(substr($0, 25, 2), 1),   # attr     (byte 12)
            le(substr($0, 27, 2), 1)    # name_len (byte 13)
    }'
}

# ── ler N bytes como hex — imune a bytes nulos em $() ────────────────────────
read_hex() {
    read_bytes "$1" "$2" "$3" \
    | od -An -tx1 \
    | tr -d ' \t\n'
}

# ── ler N bytes como string — para nomes de arquivo ───────────────────────────
read_str() {
    read_bytes "$1" "$2" "$3"
}

# ── localizar disc_lseek comparando magic em hex ─────────────────────────────
find_disc_off() {
    local file hex try
    file="$1"
    for try in 0 $OFF_GLOBAL $OFF_XGD3 $OFF_XGD1; do
        hex=$(read_hex "$file" $(( HEADER_OFF + try )) 20)
        if [ "$hex" = "$MAGIC_HEX" ]; then
            printf '%d' "$try"
            return 0
        fi
    done
    return 1
}

# ── verificar bounds antes de qualquer leitura ───────────────────────────────
check_bounds() {
    local desc offset len
    desc="$1"; offset="$2"; len="$3"
    if [ "$offset" -lt 0 ] || [ "$(( offset + len ))" -gt "$ISO_SIZE" ]; then
        warn "fora dos limites: $desc (offset=$offset len=$len iso=${ISO_SIZE}B)"
        return 1
    fi
    return 0
}

# [1.7] ── detecção de ciclos O(1) por nó ──────────────────────────────────────
# Antes: VISITED era uma string que crescia até centenas de KB e era varrida
# por glob a cada nó -> comportamento O(n^2). Agora cada nó visitado vira um
# arquivo vazio em $VISITED_DIR; o teste de existência é O(1) no filesystem.
# node_pos é sempre um inteiro decimal (só dígitos), então o nome de arquivo
# é seguro — sem barras, sem metacaracteres.
#
# Custo: até MAX_NODES inodes de 0 byte num tmpdir (em tmpfs, irrelevante).
mark_visited() {
    NODE_COUNT=$(( NODE_COUNT + 1 ))
    if [ "$NODE_COUNT" -gt "$MAX_NODES" ]; then
        die "limite de nós excedido ($MAX_NODES) — ISO possivelmente cíclica"
    fi
    [ -e "$VISITED_DIR/$1" ] && return 1
    : > "$VISITED_DIR/$1" || die "falha ao marcar nó $1"
    return 0
}
#
# ── ALTERNATIVA ESTRITAMENTE-POSIX (sem mktemp) ───────────────────────────────
# mktemp NÃO faz parte do POSIX (vem de coreutils/BSD; presente na prática em
# todo lugar). Se você quer manter a lista de dependências exatamente em
# {dd,od,tr,awk,wc}, remova VISITED_DIR/mktemp/trap e troque mark_visited por
# esta versão: ela abre mão da detecção exata de ciclo e confia apenas em
# MAX_NODES + MAX_DEPTH. Uma ISO cíclica/corrompida ainda faz trabalho
# *limitado* (para em MAX_NODES) em vez de loop infinito — você só pode acabar
# extraindo um subtree duplicado, de forma limitada.
#
# mark_visited() {
#     NODE_COUNT=$(( NODE_COUNT + 1 ))
#     if [ "$NODE_COUNT" -gt "$MAX_NODES" ]; then
#         die "limite de nós excedido ($MAX_NODES) — ISO possivelmente cíclica"
#     fi
#     return 0
# }

# ── validação de segurança do nome de arquivo ─────────────────────────────────
validate_name() {
    local name clean
    name="$1"
    [ -z "$name" ] && die "nome vazio no dir table — abortando"
    clean=$(printf '%s' "$name" | tr -d '[:cntrl:]')
    [ "$clean" != "$name" ] && \
        die "nome com caracteres de controle: '$name' — abortando"
    [ "$name" = "." ]  && die "nome inválido: '.' — abortando"
    [ "$name" = ".." ] && die "nome inválido: '..' — abortando"
    case "$name" in
        */* | *\\*) die "nome com separador de path: '$name' — abortando" ;;
    esac
}

# ── travessia recursiva da árvore AVL do dir table ────────────────────────────
#
# Estrutura de cada nó (NODE_HEADER=14 bytes + nome):
#   uint16 l_off    offset em dwords do filho esquerdo
#   uint16 r_off    offset em dwords do filho direito
#   uint32 sector   setor de início do conteúdo
#   uint32 size     tamanho em bytes
#   uint8  attr     0x10=dir, 0x20=arquivo
#   uint8  name_len comprimento do nome
#   char   name[name_len]
#
# Sem cd: caminhos construídos como strings absolutas "$dest_root/$cur_path$name".
# O ISO é resolvido para caminho absoluto em process_iso antes de qualquer
# chamada — dd if="$iso" funciona independente do diretório atual.
#
# ll_compat: ISOs de ferramentas antigas empilham tudo à direita (lista
# ligada). Corrige r_offset quando ultrapassa o setor atual do dir table.
# Ref: extract-xiso.c linha 1351-1353.

traverse_node() {
    local iso dir_start node_pos cur_path disc_off mode ll depth dest_root
    local l_off r_off sector fsize attr name_len name hdr
    local is_dir child_ll sub full_target actual
    local off r_pos cur_sec r_sec corr skip_file

    iso="$1"; dir_start="$2"; node_pos="$3"
    cur_path="$4"; disc_off="$5"; mode="$6"; ll="$7"; depth="$8"; dest_root="$9"

    if [ "$depth" -gt "$MAX_DEPTH" ]; then
        warn "profundidade máxima ($MAX_DEPTH) em ${cur_path} — abortando ramo"
        return 0
    fi

    if ! mark_visited "$node_pos"; then
        warn "ciclo detectado: node_pos=$node_pos — abortando ramo"
        return 0
    fi

    check_bounds "nó em ${cur_path}" "$node_pos" "$NODE_HEADER" || return 0

    # [1.7] lê e parseia o header inteiro de uma vez. set -- separa a linha
    # de saída ("l_off r_off sector fsize attr name_len") nos campos via IFS
    # padrão (espaço). Seguro porque os 9 posicionais originais já foram
    # copiados para variáveis locais acima; e a saída do awk é só dígitos.
    hdr=$(read_node_header "$iso" "$node_pos") || return 0
    [ -z "$hdr" ] && return 0
    # shellcheck disable=SC2086  # split intencional em campos numéricos
    set -- $hdr
    [ "$#" -ge 6 ] || return 0
    l_off=$1; r_off=$2; sector=$3; fsize=$4; attr=$5; name_len=$6

    [ "$l_off" -eq 65535 ] && return 0
    [ "$name_len" -eq 0 ]   && return 0
    [ "$name_len" -gt 255 ] && return 0

    check_bounds "nome em ${cur_path}" \
        $(( node_pos + NODE_HEADER )) "$name_len" || return 0

    name=$(read_str "$iso" $(( node_pos + 14 )) "$name_len")
    validate_name "$name"

    if [ "$l_off" -ne 0 ]; then
        check_bounds "filho esq. de $name" \
            $(( dir_start + l_off * DWORD )) "$NODE_HEADER" || l_off=0
    fi
    if [ "$r_off" -ne 0 ]; then
        check_bounds "filho dir. de $name" \
            $(( dir_start + r_off * DWORD )) "$NODE_HEADER" || r_off=0
    fi

    child_ll="$ll"
    if [ "$l_off" -ne 0 ]; then
        child_ll=0
        traverse_node "$iso" "$dir_start" \
            $(( dir_start + l_off * DWORD )) \
            "$cur_path" "$disc_off" "$mode" "$child_ll" $(( depth + 1 )) "$dest_root"
    fi

    is_dir=$(( attr & ATTR_DIR ))

    if [ "$is_dir" -ne 0 ]; then
        log "${cur_path}${name}/"

        if [ "$mode" = "extract" ]; then
            if [ "$SKIP_SYS" -eq 1 ] && [ "$name" = '$SystemUpdate' ]; then
                :
            else
                mkdir -p "$dest_root/${cur_path}${name}" || \
                    die "não foi possível criar: $dest_root/${cur_path}${name}"
                if [ "$fsize" -gt 0 ]; then
                    sub=$(( sector * SECTOR + disc_off ))
                    if check_bounds "subdir ${cur_path}${name}" "$sub" "$SECTOR"; then
                        traverse_node "$iso" "$sub" "$sub" \
                            "${cur_path}${name}/" "$disc_off" "$mode" \
                            1 $(( depth + 1 )) "$dest_root"
                    fi
                fi
            fi
        else
            if [ "$fsize" -gt 0 ]; then
                sub=$(( sector * SECTOR + disc_off ))
                if check_bounds "subdir ${cur_path}${name}" "$sub" "$SECTOR"; then
                    traverse_node "$iso" "$sub" "$sub" \
                        "${cur_path}${name}/" "$disc_off" "$mode" \
                        1 $(( depth + 1 )) "$dest_root"
                fi
            fi
        fi

    else
        skip_file=0
        if [ "$SKIP_SYS" -eq 1 ]; then
            case "$cur_path" in *'$SystemUpdate'*) skip_file=1 ;; esac
        fi

        if [ "$skip_file" -eq 0 ]; then
            TOTAL_FILES=$(( TOTAL_FILES + 1 ))
            TOTAL_BYTES=$(( TOTAL_BYTES + fsize ))
            log "${cur_path}${name} (${fsize} bytes)"

            # [1.8] progresso leve em stderr durante extração de ISOs grandes.
            # Vai em stderr para não poluir o stdout (a listagem). Suprimido
            # por -Q (SILENT); independe de -q, que afeta só o stdout normal.
            # "\r" reescreve a mesma linha; PROGRESS_EVERY controla a cadência.
            if [ "$mode" = "extract" ] && [ "$SILENT" -eq 0 ] \
               && [ $(( TOTAL_FILES % PROGRESS_EVERY )) -eq 0 ]; then
                printf '\r%d arquivos, %d bytes...' \
                    "$TOTAL_FILES" "$TOTAL_BYTES" >&2
            fi

            if [ "$mode" = "extract" ]; then
                off=$(( sector * SECTOR + disc_off ))

                if ! check_bounds "${cur_path}${name}" "$off" "$fsize"; then
                    warn "offset/tamanho inválido: ${cur_path}${name} — pulando"
                else
                    full_target="$dest_root/${cur_path}${name}"

                    # [1.8] aviso de colisão: o XDVDFS pode ter entradas que
                    # diferem só por maiúsc./minúsc. (ex.: "File" e "file").
                    # Em filesystem case-insensitive (HFS+/APFS/exFAT) ambas
                    # mapeiam para o mesmo arquivo e uma sobrescreve a outra
                    # silenciosamente. Como não dá para resolver sem renomear,
                    # ao menos avisamos para que a perda não seja silenciosa.
                    if [ -e "$full_target" ]; then
                        warn "alvo já existe (possível colisão case-insensitive): ${cur_path}${name}"
                    fi

                    if [ "$fsize" -eq 0 ]; then
                        : > "$full_target" || \
                            die "não foi possível criar: $full_target"
                    else
                        # extração: dd bs=SECTOR para blocos completos (rápido),
                        # read_bytes para o bloco parcial final (seek eficiente)
                        #
                        # [1.8] trunca o alvo ANTES de escrever. Sem isto, uma
                        # re-extração por cima de um arquivo existente corrompe
                        # o resultado: o tail usa ">>" (append) e, quando o
                        # arquivo é menor que um setor (secs=0), não há dd of=
                        # para truncar — o conteúdo antigo permanece e o novo é
                        # acrescentado (ex.: "hello world" -> "hello worldhello
                        # world"). ":> " zera o arquivo de forma atômica e POSIX.
                        local secs tail
                        : > "$full_target" || \
                            die "não foi possível criar: $full_target"
                        secs=$(( fsize / SECTOR ))
                        tail=$(( fsize % SECTOR ))
                        if [ "$secs" -gt 0 ]; then
                            # conv=notrunc: não retrunca o arquivo já zerado;
                            # escreve a partir do início (seek=0 implícito).
                            dd if="$iso" of="$full_target" bs="$SECTOR" \
                                skip=$(( off / SECTOR )) \
                                count="$secs" conv=notrunc 2>/dev/null
                        fi
                        if [ "$tail" -gt 0 ]; then
                            read_bytes "$iso" \
                                $(( off + secs * SECTOR )) \
                                "$tail" >> "$full_target"
                        fi

                        # detecção de truncamento (C linha 1675)
                        actual=$(wc -c < "$full_target" 2>/dev/null || printf '0')
                        actual=$(printf '%d' "$actual")
                        if [ "$actual" -lt "$fsize" ]; then
                            warn "truncado: ${cur_path}${name} (esperado ${fsize}B, lido ${actual}B)"
                            TRUNCATED=$(( TRUNCATED + 1 ))
                        fi
                    fi
                fi
            fi
        fi
    fi

    if [ "$r_off" -ne 0 ]; then
        r_pos=$(( dir_start + r_off * DWORD ))

        # ll_compat: corrige r_offset que ultrapassa o setor atual
        # Ref: extract-xiso.c linha 1351-1353
        if [ "$ll" -eq 1 ]; then
            cur_sec=$(( (node_pos - dir_start) / SECTOR ))
            r_sec=$(( r_off * DWORD / SECTOR ))
            if [ "$r_sec" -gt "$cur_sec" ]; then
                corr=$(( (cur_sec + 1) * (SECTOR / DWORD) ))
                r_pos=$(( dir_start + corr * DWORD ))
            fi
        fi

        traverse_node "$iso" "$dir_start" "$r_pos" \
            "$cur_path" "$disc_off" "$mode" "$child_ll" $(( depth + 1 )) "$dest_root"
    fi

    return 0
}

# ── processar o ISO ───────────────────────────────────────────────────────────
process_iso() {
    local iso iso_abs disc_off tail_off tail_hex
    local root_sect root_size base name dest

    iso="$1"
    [ -f "$iso" ] || die "arquivo não encontrado: $iso"

    # resolver para caminho absoluto — dd if="$iso_abs" funciona
    # independente de qualquer cd feito pelo script ou pelo chamador
    case "$iso" in
        /*) iso_abs="$iso" ;;
        *)  iso_abs="$(pwd)/$iso" ;;
    esac

    ISO_SIZE=$(wc -c < "$iso_abs" 2>/dev/null | awk '{print $1}')
    [ -z "$ISO_SIZE" ] || [ "$ISO_SIZE" -eq 0 ] && \
        die "$iso: não foi possível determinar o tamanho"

    disc_off=$(find_disc_off "$iso_abs") || \
        die "$iso: magic XDVDFS não encontrado — não é um XISO válido"

    tail_off=$(( HEADER_OFF + disc_off + 20 + 4 + 4 + 8 + TAIL_UNUSED ))
    check_bounds "magic de cauda" "$tail_off" 20 || \
        die "$iso: magic de cauda fora dos limites — ISO corrompido"
    tail_hex=$(read_hex "$iso_abs" "$tail_off" 20)
    [ "$tail_hex" = "$MAGIC_HEX" ] || \
        die "$iso: magic de cauda ausente — ISO possivelmente corrompido"

    root_sect=$(read_le "$iso_abs" $(( HEADER_OFF + disc_off + 20 )) 4)
    root_size=$(read_le "$iso_abs" $(( HEADER_OFF + disc_off + 24 )) 4)

    [ -z "$root_sect" ] && die "$iso: não foi possível ler root_sect"
    [ -z "$root_size" ] && die "$iso: não foi possível ler root_size"

    if [ "$root_sect" -eq 0 ] && [ "$root_size" -eq 0 ]; then
        log "$iso: imagem sem arquivos"
        return 0
    fi

    check_bounds "dir table raiz" \
        $(( root_sect * SECTOR + disc_off )) "$SECTOR" || \
        die "$iso: dir table raiz fora dos limites — ISO corrompido"

    base="${iso##*/}"
    # [1.8] strip case-insensitive: .iso/.ISO/.Iso/.iSo etc.
    name="${base%.[Ii][Ss][Oo]}"

    NODE_COUNT=0

    # [1.7] cria o set de visitados como diretório temporário seguro
    # (sem nome previsível, sem risco de symlink em /tmp) e garante a
    # limpeza com trap em qualquer saída. Se você adotar o fallback
    # estritamente-POSIX de mark_visited, remova estas 3 linhas e o trap.
    VISITED_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xiso.XXXXXX") \
        || die "não foi possível criar diretório temporário"
    trap 'rm -rf "$VISITED_DIR"' EXIT INT TERM HUP

    # dest também resolvido como caminho absoluto
    dest="${OUTDIR:-$name}"
    case "$dest" in
        /*) ;;
        *)  dest="$(pwd)/$dest" ;;
    esac

    log ""
    if [ "$MODE" = "list" ]; then
        log "listando $base:"
        log ""
        traverse_node "$iso_abs" \
            $(( root_sect * SECTOR + disc_off )) \
            $(( root_sect * SECTOR + disc_off )) \
            "" "$disc_off" list 1 0 ""
        log ""
        log "$TOTAL_FILES arquivo(s), $TOTAL_BYTES bytes total"
    else
        log "extraindo $base:"
        log ""
        mkdir -p "$dest" || die "não foi possível criar: $dest"
        traverse_node "$iso_abs" \
            $(( root_sect * SECTOR + disc_off )) \
            $(( root_sect * SECTOR + disc_off )) \
            "" "$disc_off" extract 1 0 "$dest"
        # [1.8] fecha a linha do contador de progresso (que usa "\r" sem
        # newline). Só emite se houve progresso impresso.
        [ "$SILENT" -eq 0 ] && [ "$TOTAL_FILES" -ge "$PROGRESS_EVERY" ] && \
            printf '\n' >&2
        log ""
        log "$TOTAL_FILES arquivo(s) extraídos para '$dest' ($TOTAL_BYTES bytes)"
        if [ "$TRUNCATED" -gt 0 ]; then
            warn "$TRUNCATED arquivo(s) truncado(s) — ISO pode estar corrompido"
        fi
    fi
}

# ── ajuda ─────────────────────────────────────────────────────────────────────
help() {
    cat <<'HELP'
xiso.sh — extrator/listador de Xbox ISO (XDVDFS)
POSIX sh. Dependências: dd, od, tr, awk, wc (Linux/macOS/FreeBSD)
  (mktemp opcional — usado na detecção de ciclos; veja comentários no script)

  xiso.sh <arquivo.iso>              Extrair para ./<nome>/
  xiso.sh -x <arquivo.iso>          Extrair (explícito)
  xiso.sh -l <arquivo.iso>          Listar conteúdo
  xiso.sh -d <dir> <arquivo.iso>    Extrair para <dir>
  xiso.sh -s                        Pular $SystemUpdate
  xiso.sh -q                        Silencioso (suprime output normal)
  xiso.sh -Q                        Silêncio total (suprime tudo)
  xiso.sh -v                        Versão
  xiso.sh -h                        Ajuda

Para múltiplos ISOs:
  for f in *.iso; do xiso.sh "$f"; done

Códigos de saída:
  0  sucesso        1  concluiu com avisos        2  truncamento (incompleto)
HELP
}

# ── parse de argumentos ───────────────────────────────────────────────────────
[ $# -eq 0 ] && { help; exit 1; }

ISO_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -x) MODE="extract" ;;
        -l) MODE="list" ;;
        -s) SKIP_SYS=1 ;;
        -q) QUIET=1 ;;
        -Q) SILENT=1; QUIET=1 ;;
        -v) printf 'xiso.sh versão %s\n' "$XISO_VERSION"; exit 0 ;;
        -h|--help) help; exit 0 ;;
        -d)
            shift
            [ $# -eq 0 ] && die "-d requer um diretório"
            OUTDIR="$1"
            [ "$OUTDIR" = "/" ] && die "-d / não é permitido"
            # [1.7] rejeita ".." — o denylist literal abaixo é burlável por
            # path não normalizado (ex.: -d /tmp/../etc casaria como /tmp).
            # A proteção real continua sendo validate_name (sem / \ .. ctrl),
            # mas isto fecha o vetor no próprio argumento -d.
            case "$OUTDIR" in
                *..*) die "-d não pode conter '..'" ;;
            esac
            case "$OUTDIR" in
                /etc | /etc/* | /sys | /sys/* | \
                /proc | /proc/* | /dev | /dev/* | \
                /boot | /boot/*)
                    die "-d aponta para diretório do sistema: '$OUTDIR'"
                    ;;
            esac
            ;;
        -*)
            die "opção desconhecida: $1"
            ;;
        *)
            [ -n "$ISO_FILE" ] && \
                die "apenas um ISO por vez. Para múltiplos: for f in *.iso; do xiso.sh \"\$f\"; done"
            ISO_FILE="$1"
            ;;
    esac
    shift
done

[ -z "$ISO_FILE" ] && die "nenhum arquivo ISO especificado"

process_iso "$ISO_FILE"

[ "$HAD_WARNINGS" -eq 1 ] && [ "$SILENT" -eq 0 ] && \
    printf 'AVISO: avisos emitidos — verifique stderr\n' >&2

# [1.8] códigos de saída para automação (ex.: for f in *.iso; do xiso.sh "$f"
# || echo "FALHOU: $f"; done). Distinguem "corrompeu" de "passou com ressalva":
#   0 = sucesso limpo
#   1 = concluiu com avisos (bounds, colisão de nome, etc.)
#   2 = truncamento — extração incompleta (mais grave; tem precedência)
# Nota: die() ainda sai com 1 em erros fatais antes de chegar aqui.
if [ "$TRUNCATED" -gt 0 ]; then
    exit 2
elif [ "$HAD_WARNINGS" -eq 1 ]; then
    exit 1
fi

exit 0
