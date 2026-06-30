#!/bin/sh
# ==============================================================================
# WRAPPER: flac_to_aac.sh
# Ponto de entrada: aponta o codec e delega tudo para o base.sh.
# Para criar um novo conversor, copie este arquivo e troque o codec_*.sh.
# ==============================================================================

DIR_SCRIPT=$(dirname -- "$0")
DIR_SCRIPT=$(cd -- "$DIR_SCRIPT" && pwd)

export CODEC_FILE="$DIR_SCRIPT/codec_aac.sh"

. "$DIR_SCRIPT/base.sh"
