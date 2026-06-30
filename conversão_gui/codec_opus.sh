#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC2034  # EXTENSAO_SAIDA é lida pelo base.sh via source
# shellcheck disable=SC2154  # cores (vermelho, verde...) vêm do base.sh via source
# ==============================================================================
# codec_opus.sh  —  específico do Opus (encoder de referência: opusenc)
# Carregado via 'source' pelo base.sh. Não execute diretamente.
#
# A extração/resize da capa e o menu de perfil de capa ficam no base.sh
# (não dependem do codec). Aqui só definimos a QUALIDADE DE ÁUDIO e a
# chamada de conversão.
# ==============================================================================

EXTENSAO_SAIDA="opus"

if ! command -v opusenc >/dev/null 2>&1; then
    erro "${vermelho}Erro: 'opusenc' não encontrado (pacote 'opus-tools').${reset}"
    exit 1
fi

# bitrate (kbps) é definido aqui e consumido por converter().
bitrate=""
INFO_BR=""

menu_qualidade() {
    diga "${amarelo}Escolha a qualidade do áudio (Opus):${reset}"
    diga "${verde}1)${reset} Perfil exagerado    (256 kbps)"
    diga "${verde}2)${reset} Perfil transparente (192 kbps) ${verde}[padrão]${reset}"
    diga "${verde}3)${reset} Perfil eficiente    (128 kbps)"
    diga "${amarelo}(Enter para ${verde}2${amarelo})${reset}"
    qualidade=$(ler_opcao_valida "1 2 3" "2")
    case "$qualidade" in
        1) bitrate="256"; INFO_BR="256k (overkill)" ;;
        2) bitrate="192"; INFO_BR="192k (transparente)" ;;
        3) bitrate="128"; INFO_BR="128k (eficiente)" ;;
    esac
}

# converter ENTRADA SAIDA CAPA(ou "")
# opusenc lê Vorbis Comments do FLAC e os copia automaticamente (não precisa
# de -map_metadata). Capa via "--picture TYPE||DESC|RESxRESxDEPTH|FILE"; com
# os campos do meio vazios, o opusenc infere MIME/resolução do arquivo.
#
# COMPORTAMENTO ÍMPAR DO OPUSENC (corrigido aqui): ao contrário do ffmpeg,
# o opusenc COPIA AUTOMATICAMENTE qualquer capa já embutida no FLAC de
# entrada, ALÉM da que passamos em --picture. Sem "--discard-pictures" o
# .opus final fica com DUAS capas (a original sem resize + a processada).
# "--discard-pictures" descarta a herdada do FLAC, deixando só a nossa.
converter() {
    entrada="$1"; saida="$2"; capa="$3"
    if [ -n "$capa" ]; then
        opusenc --bitrate "$bitrate" --discard-pictures \
            --picture "3||||$capa" "$entrada" "$saida"
    else
        opusenc --bitrate "$bitrate" "$entrada" "$saida"
    fi
}
