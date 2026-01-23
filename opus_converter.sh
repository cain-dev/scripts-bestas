#!/bin/bash

# Cores ANSI
AZUL='\033[0;34m'
VERDE='\033[0;32m'
AMARELO='\033[1;33m'
VERMELHO='\033[0;31m'
CINZA='\033[0;90m'
NC='\033[0m'

DEST_DIR="convertidos"

echo -e "${AZUL}=== CONFIGURAÇÃO DO ENCODER OPUS (VBR Nativo) ===${NC}"

# Seleção de Bitrate
echo -e "Escolha o Bitrate:"
echo -e "1) 192 kbps (${VERDE}Recomendado${NC})"
echo -e "2) 256 kbps (${AMARELO}Alta Fidelidade${NC})"
printf "Opção [1/2]: "
read -r opt_br
[[ "$opt_br" == "1" ]] && BITRATE="192" || BITRATE="256"

# Seleção de Escopo
echo -e "\nEscolha o Escopo de busca:"
echo -e "1) Apenas nesta pasta"
echo -e "2) Incluir subpastas"
printf "Opção [1/2]: "
read -r opt_escopo

# Busca os arquivos
if [[ "$opt_escopo" == "2" ]]; then
    mapfile -d $'\0' files < <(find . -type f -name "*.flac" -not -path "./$DEST_DIR/*" -print0)
    MODO_BUSCA="Recursivo"
else
    files=(*.flac)
    if [ ! -e "${files[0]}" ]; then files=(); fi
    MODO_BUSCA="Local"
fi

total=${#files[@]}
[[ "$total" -eq 0 ]] && { echo -e "${VERMELHO}Nenhum FLAC encontrado.${NC}"; exit 1; }

mkdir -p "$DEST_DIR"

current=0
pulei=0
converti=0

echo -e "\n${AZUL}Configuração:${NC} ${AMARELO}${BITRATE} kbps VBR${NC} | ${AZUL}Busca:${NC} ${AMARELO}${MODO_BUSCA}${NC}"
echo -e "${AZUL}-------------------------------------------------------${NC}"

for f in "${files[@]}"; do
    ((current++))

    clean_path="${f#./}"
    out_file="$DEST_DIR/${clean_path%.flac}.opus"
    filename=$(basename "$f")

    # Verifica se já existe
    if [[ -f "$out_file" ]]; then
        ((pulei++))
        # Mantemos o \r para ignorados para não encher a tela de cinza
        printf "\r${CINZA}[%d/%d] Ignorado: %-45.45s${NC}" "$current" "$total" "$filename"
        continue
    fi

    # Se não existe, converte
    ((converti++))
    mkdir -p "$(dirname "$out_file")"

    # Removido o \r inicial para que cada conversão crie uma nova linha
    printf "${AZUL}[${AMARELO}%d${AZUL}/${AMARELO}%d${AZUL}]${NC} ${VERDE}Convertendo:${NC} %s\n" "$current" "$total" "$filename"

    opusenc --bitrate "$BITRATE" --vbr --comp 10 --music --quiet "$f" "$out_file"
done

echo -e "\n${AZUL}-------------------------------------------------------${NC}"
echo -e "${VERDE}Concluído!${NC}"
echo -e "Arquivos Novos: ${AMARELO}$converti${NC}"
echo -e "Arquivos Pulados: ${AMARELO}$pulei${NC}"
echo -e "Pasta de destino: ${AMARELO}./$DEST_DIR/${NC}"
