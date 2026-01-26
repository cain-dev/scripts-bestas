#!/bin/bash

# ==============================================================================
# SCRIPT: type3fix.sh
# OPERAÇÃO: Modular (Picture Type / Real MD5 Fix / Ambos)
# DEPENDÊNCIAS: metaflac, flac, imagemagick
# FUNÇÃO: Corrige blocos Type 0 para Type 3 e injeta MD5 real via stream
# ==============================================================================

if [[ -t 1 ]] && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    AZUL=$(tput setaf 4); VERDE=$(tput setaf 2); AMARELO=$(tput setaf 3)
    VERMELHO=$(tput setaf 1); CINZA=$(tput setaf 8); NEGRITO=$(tput bold); NC=$(tput sgr0)
else
    AZUL=''; VERDE=''; AMARELO=''; VERMELHO=''; CINZA=''; NEGRITO=''; NC=''
fi

# Limpeza preventiva de temporários
rm -f /tmp/flac_orig_*.img /tmp/flac_final_*.img

echo -e "${AZUL}################################################${NC}"
echo -e "${AZUL}#    METADADOS: PICTURE TYPE & REAL MD5 FIX    #${NC}"
echo -e "${AZUL}################################################${NC}"

# MENU DE OPERAÇÃO
echo -e "\n${AMARELO}O que deseja processar?${NC}"
echo -e "${VERDE}1)${NC} Tudo (Capa + MD5). ${VERDE}(padrão)${NC}"
echo -e "${VERDE}2)${NC} Apenas Corrigir Capa (Type 0 -> 3)."
echo -e "${VERDE}3)${NC} Apenas Corrigir MD5 (Fix MD5)."
printf "${AMARELO}Operação ${AZUL}[${VERDE}${NEGRITO}1${NC}${AZUL}]${AZUL}/${CINZA}2/3${NC} ${AMARELO}(Enter para ${VERDE}1${AMARELO}):${NC} "
read -r opt_operacao
opt_operacao=${opt_operacao:-1}

# Flags de controle
do_img=0; do_md5=0
[[ "$opt_operacao" == "1" ]] && { do_img=1; do_md5=1; }
[[ "$opt_operacao" == "2" ]] && { do_img=1; do_md5=0; }
[[ "$opt_operacao" == "3" ]] && { do_img=0; do_md5=1; }

# ESCOPO DA BUSCA
echo -e "\n${AMARELO}Escolha o escopo de busca:${NC}"
echo -e "${VERDE}1)${NC} Apenas nesta pasta."
echo -e "${VERDE}2)${NC} Incluir subpastas."
printf "${AMARELO}Escopo ${AZUL}[${VERDE}${NEGRITO}1${NC}${AZUL}]${AZUL}/${CINZA}2${NC} ${AMARELO}(Enter para ${VERDE}1${AMARELO}):${NC} "
read -r opt_escopo
opt_escopo=${opt_escopo:-1}

# PERGUNTAS DE IMAGEM (Apenas se do_img=1)
if [[ "$do_img" == "1" ]]; then
    echo -e "\n${AMARELO}Deseja manter os blocos de imagem originais?${NC}"
    echo -e "${VERDE}1)${NC} ${VERMELHO}REMOVER TUDO EXCETO CAPA.${NC} ${VERDE}(recomendado)${NC}"
    echo -e "${VERDE}2)${NC} Sim, manter todos os blocos originais."
    printf "${AMARELO}Limpeza ${AZUL}[${VERDE}${NEGRITO}1${NC}${AZUL}]${AZUL}/${CINZA}2${NC} ${AMARELO}(Enter para ${VERDE}1${AMARELO}):${NC} "
    read -r opt_limpeza
    opt_limpeza=${opt_limpeza:-1}

    echo -e "\n${AMARELO}Escolha o perfil de otimização da capa Master:${NC}"
    echo -e "${VERDE}1)${NC} Perfil Legado        (200x200${CINZA}px${NC}   | 10${CINZA}KB${NC})"
    echo -e "${VERDE}2)${NC} Perfil MP3 CD        (300x300${CINZA}px${NC}   | 30${CINZA}KB${NC})"
    echo -e "${VERDE}3)${NC} Perfil iPod / SD     (600x600${CINZA}px${NC}   | 100${CINZA}KB${NC})"
    echo -e "${VERDE}4)${NC} Perfil iPad Retina   (1400x1400${CINZA}px${NC} | 300${CINZA}KB${NC}) - ${VERDE}(padrão)${NC}"
    echo -e "${VERDE}5)${NC} Perfil HI-DPI        (2400x2400${CINZA}px${NC} | 600${CINZA}KB${NC})"
    echo -e "${VERDE}6)${NC} ${VERMELHO}Não otimizar - Manter imagem original${NC}"
    printf "${AMARELO}Perfil ${AZUL}[${VERDE}${NEGRITO}4${NC}${AZUL}]${AZUL}/${CINZA}1/2/3/5/6${NC} ${AMARELO}(Enter para ${VERDE}4${AMARELO}):${NC} "
    read -r opt_perfil
    opt_perfil=${opt_perfil:-4}

    case $opt_perfil in
        1) res=200 ;; 2) res=300 ;; 3) res=600 ;;
        4) res=1400 ;; 5) res=2400 ;; 6) opt_otimizar=0 ;;
        *) res=1400 ;;
    esac
fi

IMG_CMD="convert"; command -v magick &> /dev/null && IMG_CMD="magick"

if [[ "$opt_escopo" == "2" ]]; then
    mapfile -d $'\0' files < <(find . -type f -name "*.flac" -print0)
else
    files=(*.flac); [[ ! -e "${files[0]}" ]] && files=()
fi

total=${#files[@]}; atual=0; corrigidos=0; pulados=0
echo -e "\nIniciando processamento de ${AMARELO}$total arquivos${NC}..."

for f in "${files[@]}"; do
    ((atual++))
    filename=$(basename "$f")
    status_img=""
    status_md5=""
    fez_algo=0

    # 1. TRATAMENTO DE IMAGEM
    if [[ "$do_img" == "1" ]]; then
        has_type3=$(metaflac --list --block-type=PICTURE "$f" | grep -q "type: 3 (Front Cover)" && echo "yes" || echo "no")
        if [[ "$has_type3" == "no" ]]; then
            bloco_id=$(metaflac --list --block-type=PICTURE "$f" | awk '/METADATA block #/ { b=$3; gsub(/[^0-9]/,"",b) } /type: 0 \(Other\)/ { print b; exit }')
            if [[ -n "$bloco_id" ]]; then
                orig="/tmp/flac_orig_$$.img"; final="/tmp/flac_final_$$.img"
                if metaflac --block-number="$bloco_id" --export-picture-to="$orig" "$f" 2>/dev/null; then
                    if [[ "$opt_perfil" != "6" ]]; then
                        $IMG_CMD "$orig" -filter Lanczos -resize ${res}x${res}\> -quality 90 -sampling-factor 4:2:2 -colorspace sRGB -strip "$final"
                        process_img="$final"
                    else
                        process_img="$orig"
                    fi
                    [[ "$opt_limpeza" == "1" ]] && metaflac --remove --block-type=PICTURE "$f"
                    metaflac --import-picture-from="3||||$process_img" "$f"
                    status_img="${AZUL}(IMG-FIXED)${NC} "
                    fez_algo=1
                fi
                rm -f "$orig" "$final"
            fi
        fi
    fi

    # 2. FIX MD5 (MÉTODO RAW)
    if [[ "$do_md5" == "1" ]]; then
        real_md5=$(flac --silent --decode --stdout --force-raw-format --sign=signed --endian=little "$f" 2>/dev/null | md5sum | awk '{print $1}')
        if [[ -n "$real_md5" ]]; then
            metaflac --preserve-modtime --set-md5sum="$real_md5" "$f" 2>/dev/null
            if flac --silent --test "$f" 2>/dev/null; then
                status_md5="${VERDE}(MD5-OK)${NC}"
                fez_algo=1
            else
                status_md5="${VERMELHO}(MD5-FAIL)${NC}"
            fi
        fi
    fi

    if [[ "$fez_algo" == "1" ]]; then
        echo -e "[${VERDE}${atual}/${total}${NC}] ${status_img}${status_md5} $filename"
        ((corrigidos++))
    else
        echo -e "[${CINZA}${atual}/${total}${NC}] ${CINZA}(SKIPPED)${NC} $filename"
        ((pulados++))
    fi
done

echo "--------------------------------------------------------------------------------"
echo -e "${VERDE}Fim.${NC} Corrigidos: ${AMARELO}${corrigidos:-0}${NC} | Ignorados: ${AMARELO}${pulados:-0}${NC}"
