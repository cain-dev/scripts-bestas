#!/bin/bash

# ==============================================================================
# SCRIPT: type3fix.sh
# OPERAÇÃO: Reatribuição de Picture Type em metadados FLAC
# DEPENDÊNCIAS: metaflac, imagemagick
# FUNÇÃO: Corrige blocos de imagem Type 0 (Other) para Type 3 (Front Cover)
# ==============================================================================

if [[ -t 1 ]] && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    AZUL=$(tput setaf 4); VERDE=$(tput setaf 2); AMARELO=$(tput setaf 3)
    VERMELHO=$(tput setaf 1); CINZA=$(tput setaf 8); NEGRITO=$(tput bold); NC=$(tput sgr0)
else
    AZUL=''; VERDE=''; AMARELO=''; VERMELHO=''; CINZA=''; NEGRITO=''; NC=''
fi

echo -e "${AZUL}################################################${NC}"
echo -e "${AZUL}#    METADADOS: REATRIBUIÇÃO DE PICTURE TYPE   #${NC}"
echo -e "${AZUL}################################################${NC}"

# Escopo da correção
echo -e "\n${AMARELO}Escolha o escopo de busca:${NC}"
echo -e "${VERDE}1)${NC} Apenas nesta pasta."
echo -e "${VERDE}2)${NC} Incluir subpastas."
printf "${AMARELO}Escopo ${AZUL}[${VERDE}${NEGRITO}1${NC}${AZUL}]${AZUL}/${CINZA}2${NC} ${AMARELO}(Enter para ${VERDE}1${AMARELO}):${NC} "
read -r opt_escopo
opt_escopo=${opt_escopo:-1}

# Opção de limpeza de blocos de imagem excedentes
echo -e "\n${AMARELO}Deseja manter os blocos de imagem originais?${NC}"
echo -e "${VERDE}1)${NC} ${VERMELHO}REMOVER TUDO EXCETO CAPA.${NC} ${VERDE}(recomendado)${NC}"
echo -e "${VERDE}2)${NC} Sim, manter todos os blocos originais."
printf "${AMARELO}Limpeza ${AZUL}[${VERDE}${NEGRITO}1${NC}${AZUL}]${AZUL}/${CINZA}2${NC} ${AMARELO}(Enter para ${VERDE}1${AMARELO}):${NC} "
read -r opt_limpeza
opt_limpeza=${opt_limpeza:-1}

# Definição da resolução da capa corrigida
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
    1) res=200; p_nome="LEGADO" ;; 2) res=300; p_nome="MP3 CD" ;; 3) res=600; p_nome="IPOD" ;;
    4) res=1400; p_nome="RETINA" ;; 5) res=2400; p_nome="HI-DPI" ;; 6) opt_otimizar=0; p_nome="ORIGINAL" ;;
    *) res=1400; p_nome="RETINA" ;;
esac

IMG_CMD="convert"; command -v magick &> /dev/null && IMG_CMD="magick"

# Busca de arquivos
if [[ "$opt_escopo" == "2" ]]; then
    mapfile -d $'\0' files < <(find . -type f -name "*.flac" -print0)
else
    files=(*.flac); [[ ! -e "${files[0]}" ]] && files=()
fi

total=${#files[@]}; atual=0; corrigidos=0; pulados=0
echo -e "\nIniciando: ${AMARELO}$total arquivos${NC}"

# Loop de identificação e correção de blocos PICTURE
for f in "${files[@]}"; do
    ((atual++))
    filename=$(basename "$f")

    # Verifica se o arquivo já possui Picture Type 3
    if metaflac --list --block-type=PICTURE "$f" | grep -q "type: 3 (Front Cover)"; then ((pulados++)); continue; fi

    # Localiza bloco de imagem Type 0
    bloco_id=$(metaflac --list --block-type=PICTURE "$f" | awk '/METADATA block #/ { b=$3; gsub(/[^0-9]/,"",b) } /type: 0 \(Other\)/ { print b; exit }')

    if [[ -n "$bloco_id" ]]; then
        orig="/tmp/flac_orig_$$.img"; final="/tmp/flac_final_$$.img"
        # Extração da imagem original
        if metaflac --block-number="$bloco_id" --export-picture-to="$orig" "$f" 2>/dev/null; then
            if [[ "$opt_perfil" != "6" ]]; then
                # Processamento Lanczos sRGB
                $IMG_CMD "$orig" -filter Lanczos -resize ${res}x${res}\> -quality 90 -sampling-factor 4:2:2 -colorspace sRGB -strip "$final"
                process_img="$final"
            else
                process_img="$orig"
            fi
            # Remoção de blocos antigos e importação como Type 3
            [[ "$opt_limpeza" == "1" ]] && metaflac --remove --block-type=PICTURE "$f"
            metaflac --import-picture-from="3||||$process_img" "$f"
            echo -e "[${VERDE}${atual}/${total}${NC}] ${VERDE}FIXED:${NC} $filename"
            ((corrigidos++))
        fi
        rm -f "$orig" "$final"
    else
        ((pulados++))
    fi
done

echo "--------------------------------------------------------------------------------"
echo -e "${VERDE}Fim.${NC} Corrigidos: ${AMARELO}$corrigidos${NC} | Ignorados/OK: ${AMARELO}$pulados${NC}"
