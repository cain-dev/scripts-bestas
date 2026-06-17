#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC2059,SC2034,SC2154
# SC2059: variáveis de cor contêm apenas escapes ANSI fixos (ver base.sh)
# SC2034: EXTENSAO_SAIDA, FFMPEG_BIN etc. são lidas pelo base.sh via source
# SC2154: amarelo, verde, azul, negrito, reset etc. são definidas em base.sh
#         e chegam aqui via 'source' — o shellcheck não enxerga esse link
#         porque analisa cada arquivo isoladamente.

# ==============================================================================
# CODEC: codec_aac.sh
# Define tudo que é específico da transcodificação para AAC (Fraunhofer FDK)
# Carregado via 'source' pelo base.sh — não execute diretamente.
# ==============================================================================

EXTENSAO_SAIDA="m4a"

# binário customizado do ffmpeg com libfdk_aac
FFMPEG_BIN="/opt/ffmpeg-libfdk/bin/ffmpeg"
# ------------------------------------------------------------------------
# CORREÇÃO DE BUG REAL: "${LD_LIBRARY_PATH:-}" em vez de "$LD_LIBRARY_PATH"
# ------------------------------------------------------------------------
# Por que isso existe: com "set -u" ativo (definido no base.sh, herdado
# aqui via source), referenciar "$LD_LIBRARY_PATH" quando essa variável
# NUNCA foi definida no sistema do usuário interrompe o script com o erro
# "LD_LIBRARY_PATH: parameter not set" (ou "variável não associada", em
# sistemas com locale em português). Isso foi reportado e reproduzido:
# a maioria dos sistemas Linux não tem "LD_LIBRARY_PATH" setada por
# padrão — ela só existe depois que algum programa a define explicitamente
# em algum momento da sessão. "${LD_LIBRARY_PATH:-}" devolve uma string
# vazia nesse caso (em vez de erro), permitindo o "append" funcionar
# normalmente independente de a variável já existir ou não no ambiente.
# ------------------------------------------------------------------------
export LD_LIBRARY_PATH="/opt/ffmpeg-libfdk/lib:${LD_LIBRARY_PATH:-}"

if [ ! -x "$FFMPEG_BIN" ]; then
    printf "${vermelho}Erro: Binário do FFmpeg não encontrado em '%s'.${reset}\n" "$FFMPEG_BIN" >&2
    exit 1
fi

# ------------------------------------------------------------------------
# menu de qualidade específico do AAC (CBR/VBR via libfdk_aac)
# ------------------------------------------------------------------------
menu_qualidade() {
    printf "${amarelo}Escolha a qualidade do áudio (FDK-AAC):${reset}\n"
    printf "${negrito}MODO CBR (Bitrate Constante):${reset}\n"
    printf "  ${verde}1)${reset} 512 kbps - Perfil Limite\n"
    printf "  ${verde}2)${reset} 256 kbps - Perfil iTunes\n"
    printf "  ${verde}3)${reset} 192 kbps - Perfil FDK\n"
    printf "  ${verde}4)${reset} 128 kbps - Perfil Streaming\n"
    printf "${negrito}MODO VBR (Bitrate Variável):${reset}\n"
    printf "  ${verde}5)${reset} VBR 5 - Perfil Moderno ${verde}[padrão]${reset}\n"
    printf "  ${verde}6)${reset} VBR 4 - Qualidade Alta\n"
    printf "${amarelo}(Tecle ${azul}Enter${amarelo} para ${verde}5${amarelo})${reset}\n"
    # ler_opcao_valida() é definida no base.sh e chega aqui via 'source' —
    # reaproveitada para manter o mesmo comportamento de "repetir a
    # pergunta até receber uma opção válida" em todos os menus do projeto,
    # tanto os genéricos (base.sh) quanto os específicos de cada codec.
    opt_q=$(ler_opcao_valida "1 2 3 4 5 6" "5")

    case "$opt_q" in
        1) AUDIO_CMD="-c:a libfdk_aac -b:a 512k"; INFO_BR="512k CBR" ;;
        2) AUDIO_CMD="-c:a libfdk_aac -b:a 256k"; INFO_BR="256k CBR" ;;
        3) AUDIO_CMD="-c:a libfdk_aac -b:a 192k"; INFO_BR="192k CBR" ;;
        4) AUDIO_CMD="-c:a libfdk_aac -b:a 128k"; INFO_BR="128k CBR" ;;
        5) AUDIO_CMD="-c:a libfdk_aac -vbr 5"; INFO_BR="VBR 5" ;;
        6) AUDIO_CMD="-c:a libfdk_aac -vbr 4"; INFO_BR="VBR 4" ;;
    esac
}

# ------------------------------------------------------------------------
# função de conversão chamada pelo base.sh
#   $1 = arquivo de entrada (.flac)
#   $2 = arquivo de saída (.m4a)
#   $3 = caminho da capa (ou vazio, se não houver)
# precisa retornar 0 em sucesso e != 0 em falha
#
# NOTA sobre $AUDIO_CMD sem aspas: é intencional. AUDIO_CMD guarda múltiplas
# flags (ex: "-c:a libfdk_aac -vbr 5") que precisam ser expandidas como
# argumentos separados do ffmpeg. Em POSIX sh não há arrays, então não dá
# para citar a variável sem colapsar tudo em um argumento só. AUDIO_CMD é
# definido só pelo menu_qualidade() acima, nunca por input livre do usuário
# nem por nome de arquivo, então não há risco de globbing/injeção aqui.
# shellcheck disable=SC2086
# ------------------------------------------------------------------------
converter() {
    entrada="$1"
    saida="$2"
    capa="$3"

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
