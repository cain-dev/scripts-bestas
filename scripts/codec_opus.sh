#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC2059,SC2034,SC2154
# SC2059: variáveis de cor contêm apenas escapes ANSI fixos (ver base.sh)
# SC2034: EXTENSAO_SAIDA é lida pelo base.sh via source
# SC2154: amarelo, verde, azul, reset etc. são definidas em base.sh
#         e chegam aqui via 'source' — o shellcheck não enxerga esse link
#         porque analisa cada arquivo isoladamente.

# ==============================================================================
# CODEC: codec_opus.sh
# Define tudo que é específico da transcodificação para Opus (opusenc)
# Carregado via 'source' pelo base.sh — não execute diretamente.
#
# NOTA SOBRE A CAPA: a extração e o redimensionamento da capa (metaflac +
# ImageMagick) já são feitos pelo base.sh, em processar_capa() — o mesmo
# código reaproveitado pelo codec_aac.sh. O menu de perfil de capa
# (menu_thumb) também já está no base.sh e não precisa ser duplicado aqui,
# porque a escolha de resolução de capa não depende do codec de áudio —
# só a etapa de QUALIDADE DE ÁUDIO (bitrate) é específica de cada codec,
# e é só isso que este arquivo precisa definir.
# ==============================================================================

EXTENSAO_SAIDA="opus"

if ! command -v opusenc >/dev/null 2>&1; then
    printf "${vermelho}Erro: o binário 'opusenc' não foi encontrado no sistema (pacote 'opus-tools' na maioria das distros).${reset}\n" >&2
    exit 1
fi

# ------------------------------------------------------------------------
# menu de qualidade específico do Opus — mesmos 3 perfis de bitrate do
# flac2opus.sh original, agora usando ler_opcao_valida() (definida no
# base.sh) para manter a consistência de validação/retry entre os codecs.
# ------------------------------------------------------------------------
menu_qualidade() {
    printf "${amarelo}Escolha a qualidade do áudio:${reset}\n"
    printf "${verde}1)${reset} Perfil exagerado    (256 kbps)\n"
    printf "${verde}2)${reset} Perfil transparente (192 kbps) ${verde}[padrão]${reset}\n"
    printf "${verde}3)${reset} Perfil eficiente    (128 kbps)\n"
    printf "${amarelo}(Tecle ${azul}Enter${amarelo} para ${verde}2${amarelo})${reset}\n"
    qualidade=$(ler_opcao_valida "1 2 3" "2")

    case "$qualidade" in
        1) bitrate="256"; INFO_BR="256k (overkill)" ;;
        2) bitrate="192"; INFO_BR="192k (transparente)" ;;
        3) bitrate="128"; INFO_BR="128k (eficiente)" ;;
    esac
}

# ------------------------------------------------------------------------
# função de conversão chamada pelo base.sh
#   $1 = arquivo de entrada (.flac)
#   $2 = arquivo de saída (.opus)
#   $3 = caminho da capa (ou vazio, se não houver)
# precisa retornar 0 em sucesso e != 0 em falha
#
# Diferente do codec_aac.sh (que usa um ffmpeg customizado com libfdk_aac),
# aqui usamos "opusenc" diretamente — é o encoder de referência do Opus,
# não um wrapper via ffmpeg. "opusenc" já sabe ler metadados Vorbis Comment
# do FLAC de entrada e copiá-los para o Ogg Opus de saída automaticamente
# (não precisa de "-map_metadata" como no ffmpeg), e tem um parâmetro
# próprio para embutir a capa: "--picture".
#
# Formato do "--picture" do opusenc: TYPE||DESCRIPTION|RESOLUTIONxRESxDEPTH|FILE
# (com os componentes do meio vazios, como no script original do usuário,
# já que opusenc consegue inferir MIME/resolução automaticamente a partir
# do próprio arquivo de imagem quando esses campos ficam em branco).
# Usamos "3" como TYPE (Front Cover), seguindo o mesmo padrão usado em
# processar_capa() do base.sh, que já prioriza esse tipo ao extrair a capa.
# ------------------------------------------------------------------------
converter() {
    entrada="$1"
    saida="$2"
    capa="$3"

    if [ -n "$capa" ]; then
        # ------------------------------------------------------------------
        # CORREÇÃO DE BUG REAL: "--discard-pictures" é necessário aqui.
        # ------------------------------------------------------------------
        # Por que isso existe: diferente do ffmpeg (usado no codec_aac.sh),
        # que só copia o stream de imagem que for explicitamente mapeado
        # via "-map", o opusenc copia AUTOMATICAMENTE qualquer capa que já
        # exista embutida no FLAC de entrada, além de adicionar a nova
        # capa passada via "--picture". Sem o "--discard-pictures", isso
        # resultava em DUAS capas embutidas no arquivo .opus final: a
        # original (sem redimensionar, do FLAC) e a processada (já
        # redimensionada pelo base.sh). Isso foi reproduzido e confirmado
        # com "opusinfo", que mostrou dois blocos METADATA_BLOCK_PICTURE
        # no mesmo arquivo de saída antes desta correção.
        # "--discard-pictures" descarta a capa herdada do FLAC original,
        # deixando só a capa processada que estamos anexando explicitamente
        # a seguir, via "--picture".
        # ------------------------------------------------------------------
        opusenc --bitrate "$bitrate" --discard-pictures --picture "3||||$capa" "$entrada" "$saida"
    else
        opusenc --bitrate "$bitrate" "$entrada" "$saida"
    fi
}
