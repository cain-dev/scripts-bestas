#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC2034  # EXTENSAO_SAIDA/FFMPEG_BIN são lidas pelo base.sh
# shellcheck disable=SC2154  # cores (vermelho, verde...) vêm do base.sh via source
# ==============================================================================
# codec_aac.sh  —  específico do AAC (Fraunhofer FDK via ffmpeg customizado)
# Carregado via 'source' pelo base.sh. Não execute diretamente.
# ==============================================================================

EXTENSAO_SAIDA="m4a"

# ffmpeg compilado com libfdk_aac (não redistribuível na build padrão).
# Ajuste este caminho se o seu binário estiver em outro lugar.
FFMPEG_BIN="/opt/ffmpeg-libfdk/bin/ffmpeg"

# "${LD_LIBRARY_PATH:-}" (e não "$LD_LIBRARY_PATH"): sob set -u (herdado do
# base.sh), referenciar a variável quando ela NUNCA foi definida aborta o
# script. A maioria dos Linux não a define por padrão. ":-" devolve vazio
# nesse caso, deixando o append funcionar exista a variável ou não.
export LD_LIBRARY_PATH="/opt/ffmpeg-libfdk/lib:${LD_LIBRARY_PATH:-}"

if [ ! -x "$FFMPEG_BIN" ]; then
    erro "${vermelho}Erro: ffmpeg (libfdk) não encontrado em '$FFMPEG_BIN'.${reset}"
    exit 1
fi

# AUDIO_CMD guarda as flags de qualidade (definido só por menu_qualidade()).
AUDIO_CMD=""
INFO_BR=""

menu_qualidade() {
    diga "${amarelo}Escolha a qualidade do áudio (FDK-AAC):${reset}"
    diga "${negrito}MODO CBR:${reset}"
    diga "  ${verde}1)${reset} 512 kbps — Perfil Limite"
    diga "  ${verde}2)${reset} 256 kbps — Perfil iTunes"
    diga "  ${verde}3)${reset} 192 kbps — Perfil FDK"
    diga "  ${verde}4)${reset} 128 kbps — Perfil Streaming"
    diga "${negrito}MODO VBR:${reset}"
    diga "  ${verde}5)${reset} VBR 5 — Perfil Moderno ${verde}[padrão]${reset}"
    diga "  ${verde}6)${reset} VBR 4 — Qualidade Alta"
    diga "${amarelo}(Enter para ${verde}5${amarelo})${reset}"
    opt_q=$(ler_opcao_valida "1 2 3 4 5 6" "5")
    case "$opt_q" in
        1) AUDIO_CMD="-c:a libfdk_aac -b:a 512k"; INFO_BR="512k CBR" ;;
        2) AUDIO_CMD="-c:a libfdk_aac -b:a 256k"; INFO_BR="256k CBR" ;;
        3) AUDIO_CMD="-c:a libfdk_aac -b:a 192k"; INFO_BR="192k CBR" ;;
        4) AUDIO_CMD="-c:a libfdk_aac -b:a 128k"; INFO_BR="128k CBR" ;;
        5) AUDIO_CMD="-c:a libfdk_aac -vbr 5";    INFO_BR="VBR 5" ;;
        6) AUDIO_CMD="-c:a libfdk_aac -vbr 4";    INFO_BR="VBR 4" ;;
    esac
}

# converter ENTRADA SAIDA CAPA(ou "")
# Capa embutida como mjpeg via mapeamento explícito (-map 0:a -map 1:v);
# "-movflags +faststart" move o índice para o início (streaming/seek rápido).
#
# $AUDIO_CMD intencionalmente SEM aspas: múltiplas flags (ex.: "-c:a
# libfdk_aac -vbr 5") que precisam virar argumentos separados. Conteúdo só
# do case acima, nunca de input livre — sem risco de globbing/injeção.
# shellcheck disable=SC2086
converter() {
    entrada="$1"; saida="$2"; capa="$3"
    if [ -n "$capa" ]; then
        "$FFMPEG_BIN" -nostdin -v warning -stats -i "$entrada" -i "$capa" \
            -map 0:a -map 1:v -map_metadata 0 $AUDIO_CMD \
            -c:v mjpeg -disposition:v:0 attached_pic \
            -movflags +faststart "$saida" -y
    else
        "$FFMPEG_BIN" -nostdin -v warning -stats -i "$entrada" \
            -map 0:a -map_metadata 0 $AUDIO_CMD \
            -movflags +faststart "$saida" -y
    fi
}
