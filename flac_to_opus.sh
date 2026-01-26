#!/bin/bash

# ==============================================================================
# SCRIPT: flac_to_opus.sh
# OPERAÇÃO: Transcodificação de FLAC para Opus (OGG)
# DEPENDÊNCIAS: opusenc, metaflac, imagemagick
# FORMATO DE TAGS: Vorbis Comments (Ogg)
# ==============================================================================

if [[ -t 1 ]] && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    AZUL=$(tput setaf 4); VERDE=$(tput setaf 2); AMARELO=$(tput setaf 3)
    VERMELHO=$(tput setaf 1); CINZA=$(tput setaf 8); NEGRITO=$(tput bold); NC=$(tput sgr0)
else
    AZUL=''; VERDE=''; AMARELO=''; VERMELHO=''; CINZA=''; NEGRITO=''; NC=''
fi

DEST_DIR="convertidos_opus"

echo -e "${AZUL}################################################${NC}"
echo -e "${AZUL}#   TRANSCODIFICAÇÃO: FLAC PARA OPUS (OGG)     #${NC}"
echo -e "${AZUL}################################################${NC}"

# Definição do escopo da busca
echo -e "\n${AMARELO}Escolha o escopo de busca:${NC}"
echo -e "${VERDE}1)${NC} Apenas nesta pasta."
echo -e "${VERDE}2)${NC} Incluir subpastas."
printf "${AMARELO}Escopo ${AZUL}[${VERDE}${NEGRITO}1${NC}${AZUL}]${AZUL}/${CINZA}2${NC} ${AMARELO}(Enter para ${VERDE}1${AMARELO}):${NC} "
read -r opt_escopo
opt_escopo=${opt_escopo:-1}

# Definição do bitrate Opus VBR
echo -e "\n${AMARELO}Escolha a qualidade do áudio (Opus):${NC}"
echo -e "${NEGRITO}MODO VBR (Nativo):${NC}"
echo -e "  ${VERDE}1)${NC} 256 kbps - Perfil Overkill"
echo -e "  ${VERDE}2)${NC} 192 kbps - Perfil Transparente ${VERDE}(padrão)${NC}"
echo -e "  ${VERDE}3)${NC} 128 kbps - Perfil Eficiente"
printf "${AMARELO}Qualidade ${AZUL}[${VERDE}${NEGRITO}2${NC}${AZUL}]${AZUL}/${CINZA}1/3${NC} ${AMARELO}(Enter para ${VERDE}2${AMARELO}):${NC} "
read -r opt_sel

case $opt_sel in
    1) BITRATE="256"; INFO_BR="256k (Overkill)" ;;
    2|*) BITRATE="192"; INFO_BR="192k (Transparente)" ;;
    3) BITRATE="128"; INFO_BR="128k (Eficiente)" ;;
esac

# Definição do perfil de processamento de imagem
echo -e "\n${AMARELO}Escolha o perfil de otimização da capa:${NC}"
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
    1) res=200; p_nome="LEGADO" ;; 2) res=300; p_nome="MP3 CD" ;; 3) res=600; p_nome="IPOD" ;;
    4) res=1400; p_nome="RETINA" ;; 5) res=2400; p_nome="HI-DPI" ;; 6) opt_otimizar=0; p_nome="ORIGINAL" ;;
    *) res=1400; p_nome="RETINA" ;;
esac

IMG_CMD="convert"; command -v magick &> /dev/null && IMG_CMD="magick"

# Busca de arquivos conforme escopo
if [[ "$opt_escopo" == "2" ]]; then
    mapfile -d $'\0' files < <(find . -type f -name "*.flac" -not -path "./$DEST_DIR/*" -print0)
else
    files=(*.flac); [[ ! -e "${files[0]}" ]] && files=()
fi

total=${#files[@]}; mkdir -p "$DEST_DIR"
echo -e "\nIniciando: ${AMARELO}$total arquivos${NC} | Capa: ${AMARELO}$p_nome${NC} | Áudio: ${AMARELO}$INFO_BR${NC}"

# Execução da transcodificação Opus
for f in "${files[@]}"; do
    ((atual++))
    filename=$(basename "$f"); clean_path="${f#./}"
    out_file="$DEST_DIR/${clean_path%.flac}.opus"

    [[ -f "$out_file" ]] && { ((pulei++)); continue; }
    mkdir -p "$(dirname "$out_file")"

    # Extração e processamento de imagem
    tmp_img="/tmp/opus_orig_$$.jpg"; final_img="/tmp/opus_final_$$.jpg"; EXTRA_ARGS=""
    metaflac --export-picture-to="$tmp_img" "$f" 2>/dev/null

    if [[ -f "$tmp_img" ]]; then
        if [[ "$opt_perfil" != "6" ]]; then
            $IMG_CMD "$tmp_img" -filter Lanczos -resize ${res}x${res}\> -quality 90 -sampling-factor 4:2:0 -strip "$final_img"
            EXTRA_ARGS="--picture 3||||$final_img"
        else
            EXTRA_ARGS="--picture 3||||$tmp_img"
        fi
    fi

    # Codificação nativa via opusenc
    if opusenc --bitrate "$BITRATE" --vbr --quiet $EXTRA_ARGS "$f" "$out_file"; then
        ((converti++)); echo -e "[${VERDE}${atual}/${total}${NC}] ${VERDE}OK:${NC} $filename"
    fi
    rm -f "$tmp_img" "$final_img"
done

echo "--------------------------------------------------------------------------------"
echo -e "${VERDE}Fim.${NC} Convertidos: ${AMARELO}$converti${NC} | Pulados: ${AMARELO}$pulei${NC}"
