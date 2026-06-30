#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC2034  # EXTENSAO_SAIDA é lida pelo base.sh via source
# shellcheck disable=SC2154  # cores (vermelho, verde...) vêm do base.sh via source
# ==============================================================================
# codec_mp3.sh  —  específico do MP3 (LAME via ffmpeg)
# Carregado via 'source' pelo base.sh. Não execute diretamente.
#
# CAPA: como usa ffmpeg (não um encoder dedicado), o mapeamento de streams é
# EXPLÍCITO ("-map 0:a -map 1:v"). Isso evita por construção a capa duplicada
# que o opusenc sofre — o ffmpeg só embute a imagem do 2º input (a capa já
# processada pelo base.sh), ignorando qualquer arte que já houvesse no FLAC.
# ==============================================================================

EXTENSAO_SAIDA="mp3"
FFMPEG_BIN="ffmpeg"

if ! command -v "$FFMPEG_BIN" >/dev/null 2>&1; then
    erro "${vermelho}Erro: '$FFMPEG_BIN' não encontrado no PATH.${reset}"
    exit 1
fi

# BITRATE_CMD guarda as flags de qualidade (definido só por menu_qualidade()).
BITRATE_CMD=""
INFO_BR=""

menu_qualidade() {
    diga "${amarelo}Escolha a qualidade do áudio (MP3 LAME):${reset}"
    diga "${negrito}MODO VBR:${reset}"
    diga "  ${verde}1)${reset} V0 (~245 kbps) — Perfil Moderno ${verde}[padrão]${reset}"
    diga "  ${verde}2)${reset} V2 (~190 kbps) — Perfil Balanceado"
    diga "${negrito}MODO CBR:${reset}"
    diga "  ${verde}3)${reset} 320 kbps        — Perfil Limite"
    diga "  ${verde}4)${reset} 256 kbps        — Perfil iTunes"
    diga "  ${verde}5)${reset} 128 kbps        — Perfil Legado"
    diga "${amarelo}(Enter para ${verde}1${amarelo})${reset}"
    opt_q=$(ler_opcao_valida "1 2 3 4 5" "1")
    case "$opt_q" in
        1) BITRATE_CMD="-q:a 0";    INFO_BR="V0 VBR (~245k)" ;;
        2) BITRATE_CMD="-q:a 2";    INFO_BR="V2 VBR (~190k)" ;;
        3) BITRATE_CMD="-b:a 320k"; INFO_BR="320k CBR" ;;
        4) BITRATE_CMD="-b:a 256k"; INFO_BR="256k CBR" ;;
        5) BITRATE_CMD="-b:a 128k"; INFO_BR="128k CBR" ;;
    esac
}

# converter ENTRADA SAIDA CAPA(ou "")
# "-id3v2_version 3" força ID3v2.3 (em vez do ID3v2.4 padrão do ffmpeg), com
# compatibilidade mais ampla em players antigos e sistemas embarcados.
#
# $BITRATE_CMD intencionalmente SEM aspas: guarda múltiplas flags (ex.:
# "-q:a 0") que precisam virar argumentos separados. POSIX sh não tem arrays;
# o valor vem só do case acima (nunca de input livre), então não há injeção.
# shellcheck disable=SC2086
converter() {
    entrada="$1"; saida="$2"; capa="$3"
    if [ -n "$capa" ]; then
        "$FFMPEG_BIN" -nostdin -v warning -stats -i "$entrada" -i "$capa" \
            -map 0:a -map 1:v -map_metadata 0 $BITRATE_CMD \
            -id3v2_version 3 \
            -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (Front)" \
            -disposition:v:0 attached_pic "$saida" -y
    else
        "$FFMPEG_BIN" -nostdin -v warning -stats -i "$entrada" \
            -map 0:a -map_metadata 0 $BITRATE_CMD \
            -id3v2_version 3 "$saida" -y
    fi
}
