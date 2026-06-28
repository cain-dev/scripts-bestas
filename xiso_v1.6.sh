#!/bin/sh
# xiso.sh — extrator e listador de Xbox ISO (XDVDFS)
# POSIX sh + extensão "local" (dash, ash, busybox sh, ksh93, zsh).
# Dependências: dd, od, tr, awk, wc — todas POSIX.
# Compatível com Linux, macOS, FreeBSD.
#
# Versão: 1.6

XISO_VERSION="1.6"

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
VISITED=""

# ── output ────────────────────────────────────────────────────────────────────
log()  { [ "$QUIET"  -eq 0 ] && [ "$SILENT" -eq 0 ] && printf '%s\n' "$*"; }
warn() { HAD_WARNINGS=1; [ "$SILENT" -eq 0 ] && printf 'AVISO: %s\n' "$*" >&2; }
die()  { [ "$SILENT" -eq 0 ] && printf 'ERRO: %s\n' "$*" >&2; exit 1; }

# ── leitura eficiente de bytes do ISO ─────────────────────────────────────────
# Dois dd em pipeline: o primeiro salta em blocos de READ_BLOCK (rápido),
# o segundo extrai os bytes exatos. Evita dd bs=1 skip=N com N na casa
# de centenas de MB (que faria N leituras individuais).
# ISO sempre passado como caminho absoluto — imune a cd do chamador.
read_bytes() {
    local file offset count bskip byskip
    file="$1"; offset="$2"; count="$3"
    bskip=$(( offset / READ_BLOCK ))
    byskip=$(( offset % READ_BLOCK ))
    dd if="$file" bs="$READ_BLOCK" skip="$bskip" 2>/dev/null \
    | dd bs=1 skip="$byskip" count="$count" 2>/dev/null
}

# ── ler N bytes little-endian no offset e retornar decimal ───────────────────
# printf "%.0f" evita notação científica em valores uint32 grandes.
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

# ── detecção de ciclos ────────────────────────────────────────────────────────
mark_visited() {
    NODE_COUNT=$(( NODE_COUNT + 1 ))
    if [ "$NODE_COUNT" -gt "$MAX_NODES" ]; then
        die "limite de nós excedido ($MAX_NODES) — ISO possivelmente cíclica"
    fi
    case " $VISITED " in
        *" $1 "*) return 1 ;;
    esac
    VISITED="$VISITED $1"
    return 0
}

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
    local l_off r_off sector fsize attr name_len name
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

    l_off=$(read_le "$iso" "$node_pos" 2)
    [ -z "$l_off" ] && return 0
    [ "$l_off" -eq 65535 ] && return 0

    r_off=$(read_le    "$iso" $(( node_pos + 2  )) 2)
    sector=$(read_le   "$iso" $(( node_pos + 4  )) 4)
    fsize=$(read_le    "$iso" $(( node_pos + 8  )) 4)
    attr=$(read_le     "$iso" $(( node_pos + 12 )) 1)
    name_len=$(read_le "$iso" $(( node_pos + 13 )) 1)

    [ -z "$r_off"    ] && return 0
    [ -z "$sector"   ] && return 0
    [ -z "$fsize"    ] && return 0
    [ -z "$attr"     ] && return 0
    [ -z "$name_len" ] && return 0

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

            if [ "$mode" = "extract" ]; then
                off=$(( sector * SECTOR + disc_off ))

                if ! check_bounds "${cur_path}${name}" "$off" "$fsize"; then
                    warn "offset/tamanho inválido: ${cur_path}${name} — pulando"
                else
                    full_target="$dest_root/${cur_path}${name}"
                    if [ "$fsize" -eq 0 ]; then
                        touch "$full_target"
                    else
                        # extração: dd bs=SECTOR para blocos completos (rápido),
                        # read_bytes para o bloco parcial final (seek eficiente)
                        local secs tail
                        secs=$(( fsize / SECTOR ))
                        tail=$(( fsize % SECTOR ))
                        if [ "$secs" -gt 0 ]; then
                            dd if="$iso" of="$full_target" bs="$SECTOR" \
                                skip=$(( off / SECTOR )) \
                                count="$secs" 2>/dev/null
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
    name="${base%.iso}"

    NODE_COUNT=0
    VISITED=""

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

exit 0
