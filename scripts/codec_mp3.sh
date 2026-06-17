#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC2059,SC2034,SC2154
# SC2059: variáveis de cor contêm apenas escapes ANSI fixos (ver base.sh)
# SC2034: EXTENSAO_SAIDA é lida pelo base.sh via source
# SC2154: amarelo, verde, azul, reset etc. são definidas em base.sh
#         e chegam aqui via 'source' — o shellcheck não enxerga esse link
#         porque analisa cada arquivo isoladamente.

# ==============================================================================
# CODEC: codec_mp3.sh
# Define tudo que é específico da transcodificação para MP3 (LAME via ffmpeg)
# Carregado via 'source' pelo base.sh — não execute diretamente.
#
# NOTA SOBRE A CAPA: assim como no codec_aac.sh, e diferente do
# codec_opus.sh, este codec usa "ffmpeg" (não um encoder dedicado), então
# o mapeamento de streams é EXPLÍCITO via "-map 0:a -map 1:v". Isso evita
# de origem o bug de capa duplicada que encontramos no opusenc (que herda
# automaticamente qualquer picture já embutida no FLAC de entrada, exigindo
# "--discard-pictures" para evitar duplicação) — com "-map" explícito,
# o ffmpeg só usa a imagem do segundo input (a capa já processada pelo
# base.sh), ignorando qualquer imagem que porventura já estivesse dentro
# do FLAC original. Por isso não há correção equivalente a fazer aqui.
# ==============================================================================

EXTENSAO_SAIDA="mp3"

FFMPEG_BIN="ffmpeg"

if ! command -v "$FFMPEG_BIN" >/dev/null 2>&1; then
    printf "${vermelho}Erro: o binário '%s' não foi encontrado no PATH.${reset}\n" "$FFMPEG_BIN" >&2
    exit 1
fi

# ------------------------------------------------------------------------
# menu de qualidade específico do MP3 — mesmos 5 perfis (2 VBR + 3 CBR)
# do flac_to_mp3.sh original, usando ler_opcao_valida() (definida no
# base.sh) para manter a consistência de validação/retry entre codecs.
# ------------------------------------------------------------------------
menu_qualidade() {
    printf "${amarelo}Escolha a qualidade do áudio (MP3 LAME):${reset}\n"
    printf "${negrito}MODO VBR:${reset}\n"
    printf "  ${verde}1)${reset} V0 (~245 kbps) - Perfil Moderno ${verde}[padrão]${reset}\n"
    printf "  ${verde}2)${reset} V2 (~190 kbps) - Perfil Balanceado\n"
    printf "${negrito}MODO CBR:${reset}\n"
    printf "  ${verde}3)${reset} 320 kbps        - Perfil Limite\n"
    printf "  ${verde}4)${reset} 256 kbps        - Perfil iTunes\n"
    printf "  ${verde}5)${reset} 128 kbps        - Perfil Legado\n"
    printf "${amarelo}(Tecle ${azul}Enter${amarelo} para ${verde}1${amarelo})${reset}\n"
    opt_q=$(ler_opcao_valida "1 2 3 4 5" "1")

    case "$opt_q" in
        1) BITRATE_CMD="-q:a 0"; INFO_BR="V0 VBR (~245k)" ;;
        2) BITRATE_CMD="-q:a 2"; INFO_BR="V2 VBR (~190k)" ;;
        3) BITRATE_CMD="-b:a 320k"; INFO_BR="320k CBR" ;;
        4) BITRATE_CMD="-b:a 256k"; INFO_BR="256k CBR" ;;
        5) BITRATE_CMD="-b:a 128k"; INFO_BR="128k CBR" ;;
    esac
}

# ------------------------------------------------------------------------
# função de conversão chamada pelo base.sh
#   $1 = arquivo de entrada (.flac)
#   $2 = arquivo de saída (.mp3)
#   $3 = caminho da capa (ou vazio, se não houver)
# precisa retornar 0 em sucesso e != 0 em falha
#
# NOTA sobre $BITRATE_CMD sem aspas: intencional, mesmo motivo documentado
# em codec_aac.sh — a variável guarda múltiplas flags (ex: "-q:a 0") que
# precisam ser expandidas como argumentos separados do ffmpeg. POSIX sh
# não tem arrays, então não dá para citar a variável sem colapsar tudo em
# um argumento só. BITRATE_CMD só é definida por menu_qualidade() acima,
# nunca por input livre do usuário nem por nome de arquivo.
# shellcheck disable=SC2086
#
# "-id3v2_version 3" força tags ID3v2.3 (em vez do padrão ID3v2.4 do
# ffmpeg), seguindo o mesmo formato de tags do script original do
# usuário — ID3v2.3 tem compatibilidade mais ampla com players antigos
# e alguns sistemas embarcados (carros, players portáteis) que não
# reconhecem ID3v2.4 corretamente.
# ------------------------------------------------------------------------
converter() {
    entrada="$1"
    saida="$2"
    capa="$3"

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
