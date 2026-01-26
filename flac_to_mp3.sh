#!/bin/bash

# ==============================================================================
# SCRIPT: flac_to_mp3.sh
# OPERAÇÃO: Transcodificação de FLAC para MP3 (LAME)
# DEPENDÊNCIAS: ffmpeg, metaflac, imagemagick
# FORMATO DE TAGS: ID3v2.3
# ==============================================================================

# Definição de cores e estilos para o terminal
if [[ -t 1 ]] && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    AZUL=$(tput setaf 4); VERDE=$(tput setaf 2); AMARELO=$(tput setaf 3)
    VERMELHO=$(tput setaf 1); CINZA=$(tput setaf 8); NEGRITO=$(tput bold); NC=$(tput sgr0)
else
    AZUL=''; VERDE=''; AMARELO=''; VERMELHO=''; CINZA=''; NEGRITO=''; NC=''
fi

DEST_DIR="convertidos_mp3"

echo -e "${AZUL}################################################${NC}"
echo -e "${AZUL}#   TRANSCODIFICAÇÃO: FLAC PARA MP3 (LAME)     #${NC}"
echo -e "${AZUL}################################################${NC}"

# Seleção do escopo de busca (Diretório atual ou recursivo)
echo -e "\n${AMARELO}Escolha o escopo de busca:${NC}"
echo -e "${VERDE}1)${NC} Apenas nesta pasta."
echo -e "${VERDE}2)${NC} Incluir subpastas."
printf "${AMARELO}Escopo ${AZUL}[${VERDE}${NEGRITO}1${NC}${AZUL}]${AZUL}/${CINZA}2${NC} ${AMARELO}(Enter para ${VERDE}1${AMARELO}):${NC} "
read -r opt_escopo
opt_escopo=${opt_escopo:-1}

# Configuração de qualidade e bitrate MP3
echo -e "\n${AMARELO}Escolha a qualidade do áudio (MP3 LAME):${NC}"
echo -e "${NEGRITO}MODO VBR (Bitrate Variável):${NC}"
echo -e "  ${VERDE}1)${NC} V0 (~245 kbps) - Perfil Moderno ${VERDE}(padrão)${NC}"
echo -e "  ${VERDE}2)${NC} V2 (~190 kbps) - Perfil Balanceado"
echo -e "${NEGRITO}MODO CBR (Bitrate Constante):${NC}"
echo -e "  ${VERDE}3)${NC} 320 kbps       - Perfil Limite"
echo -e "  ${VERDE}4)${NC} 256 kbps       - Perfil iTunes"
echo -e "  ${VERDE}5)${NC} ${VERMELHO}128 kbps       - Perfil Legado (compatibilidade)${NC}"
printf "${AMARELO}Qualidade ${AZUL}[${VERDE}${NEGRITO}1${NC}${AZUL}]${AZUL}/${CINZA}2/3/4/5${NC} ${AMARELO}(Enter para ${VERDE}1${AMARELO}):${NC} "
read -r opt_q
opt_q=${opt_q:-1}

case $opt_q in
    1) BITRATE_CMD="-q:a 0"; INFO_BR="V0 VBR (~245k)" ;;
    2) BITRATE_CMD="-q:a 2"; INFO_BR="V2 VBR (~190k)" ;;
    3) BITRATE_CMD="-b:a 320k"; INFO_BR="320k CBR" ;;
    4) BITRATE_CMD="-b:a 256k"; INFO_BR="256k CBR" ;;
    5) BITRATE_CMD="-b:a 128k"; INFO_BR="128k CBR" ;;
    *) BITRATE_CMD="-q:a 0"; INFO_BR="V0 VBR (~245k)" ;;
esac

# Configuração de otimização e resolução da capa
echo -e "\n${AMARELO}Escolha o perfil de otimização da capa:${NC}"
echo -e "${VERDE}1)${NC} Perfil Legado        (200x200${CINZA}px${NC}   | 10${CINZA}KB${NC})"
echo -e "${VERDE}2)${NC} Perfil MP3 CD        (300x300${CINZA}px${NC}   | 30${CINZA}KB${NC}) - ${VERDE}(padrão)${NC}"
echo -e "${VERDE}3)${NC} Perfil iPod / SD     (600x600${CINZA}px${NC}   | 100${CINZA}KB${NC})"
echo -e "${VERDE}4)${NC} Perfil iPad Retina   (1400x1400${CINZA}px${NC} | 300${CINZA}KB${NC})"
echo -e "${VERDE}5)${NC} Perfil HI-DPI        (2400x2400${CINZA}px${NC} | 600${CINZA}KB${NC})"
echo -e "${VERDE}6)${NC} ${VERMELHO}Não otimizar - Manter imagem original${NC}"
printf "${AMARELO}Perfil ${AZUL}[${VERDE}${NEGRITO}2${NC}${AZUL}]${AZUL}/${CINZA}1/3/4/5/6${NC} ${AMARELO}(Enter para ${VERDE}2${AMARELO}):${NC} "
read -r opt_perfil
opt_perfil=${opt_perfil:-2}

case $opt_perfil in
    1) res=200; p_nome="LEGADO" ;; 2) res=300; p_nome="MP3 CD" ;; 3) res=600; p_nome="IPOD/SD" ;;
    4) res=1400; p_nome="RETINA" ;; 5) res=2400; p_nome="HI-DPI" ;; 6) opt_otimizar=0; p_nome="ORIGINAL" ;;
    *) res=300; p_nome="MP3 CD" ;;
esac

# Verificação da versão do ImageMagick instalada
IMG_CMD="convert"; command -v magick &> /dev/null && IMG_CMD="magick"

# Localização de arquivos FLAC conforme escopo
if [[ "$opt_escopo" == "2" ]]; then
    mapfile -d $'\0' files < <(find . -type f -name "*.flac" -not -path "./$DEST_DIR/*" -print0)
else
    files=(*.flac); [[ ! -e "${files[0]}" ]] && files=()
fi

total=${#files[@]}; mkdir -p "$DEST_DIR"
echo -e "\nIniciando: ${AMARELO}$total arquivos${NC} | Capa: ${AMARELO}$p_nome${NC} | Áudio: ${AMARELO}$INFO_BR${NC}"

# Processamento individual dos arquivos
for f in "${files[@]}"; do
    ((atual++))
    filename=$(basename "$f"); clean_path="${f#./}"
    out_file="$DEST_DIR/${clean_path%.flac}.mp3"

    # Pula arquivos já convertidos
    [[ -f "$out_file" ]] && { ((pulei++)); continue; }
    mkdir -p "$(dirname "$out_file")"

    # Extração e redimensionamento da capa via /tmp
    tmp_img="/tmp/mp3_orig_$$.jpg"; final_img="/tmp/mp3_final_$$.jpg"
    metaflac --export-picture-to="$tmp_img" "$f" 2>/dev/null
    process_img=""

    if [[ -f "$tmp_img" ]]; then
        if [[ "$opt_perfil" != "6" ]]; then
            $IMG_CMD "$tmp_img" -filter Lanczos -resize ${res}x${res}\> -quality 90 -sampling-factor 4:2:0 -strip "$final_img"
            process_img="$final_img"
        else
            process_img="$tmp_img"
        fi
    fi

    # Transcodificação FFmpeg com injeção de metadados e imagem
    if [[ -f "$process_img" ]]; then
        ffmpeg -v quiet -i "$f" -i "$process_img" -map 0:a -map 1:v $BITRATE_CMD -id3v2_version 3 \
        -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (Front)" -disposition:v:0 default "$out_file" -y
    else
        ffmpeg -v quiet -i "$f" -map 0:a $BITRATE_CMD -id3v2_version 3 "$out_file" -y
    fi

    [[ $? -eq 0 ]] && { ((converti++)); echo -e "[${VERDE}${atual}/${total}${NC}] ${VERDE}OK:${NC} $filename"; }
    rm -f "$tmp_img" "$final_img"
done

echo "--------------------------------------------------------------------------------"
echo -e "${VERDE}Fim.${NC} Convertidos: ${AMARELO}$converti${NC} | Pulados: ${AMARELO}$pulei${NC}"
