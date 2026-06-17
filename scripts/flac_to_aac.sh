#!/bin/sh

# ==============================================================================
# WRAPPER: flac_to_aac.sh
# Ponto de entrada: aponta o codec correto e delega tudo para base.sh
# Para criar um novo conversor (ex: flac_to_mp3.sh), copie este arquivo e
# troque apenas a linha CODEC_FILE para o novo codec_*.sh
# ==============================================================================

DIR_SCRIPT=$(dirname -- "$0")
DIR_SCRIPT=$(cd -- "$DIR_SCRIPT" && pwd)

export CODEC_FILE="$DIR_SCRIPT/codec_aac.sh"

. "$DIR_SCRIPT/base.sh"
