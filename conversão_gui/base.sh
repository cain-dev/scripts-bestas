#!/bin/sh
# ==============================================================================
# base.sh  —  Núcleo genérico de transcodificação de FLAC
# ------------------------------------------------------------------------------
# Não é executado diretamente: é carregado via 'source' por um wrapper
# (ex.: flac_to_aac.sh), que antes de chamar define a variável CODEC_FILE
# apontando para o arquivo de codec correspondente (ex.: codec_aac.sh).
#
# Fluxo: banner -> checagem de dependências -> menus (escopo, qualidade de
# áudio [definida pelo codec], perfil de capa, pular existentes) -> loop de
# conversão com progresso e log.
#
# CONTRATO COM O CODEC (codec_*.sh deve fornecer):
#   EXTENSAO_SAIDA   variável  -> ex.: "m4a", "mp3", "opus"
#   menu_qualidade() função    -> define INFO_BR (rótulo) e a config de bitrate
#   converter()      função    -> recebe: entrada, saida, capa(ou ""); 0=ok
#
# DEPENDÊNCIAS DO NÚCLEO: metaflac, ImageMagick (magick OU convert).
#   O encoder de áudio é responsabilidade de cada codec_*.sh (cada um checa
#   o seu próprio binário, pois variam: ffmpeg, ffmpeg+libfdk, opusenc...).
#
# PORTABILIDADE: escrito para POSIX sh (testado em dash e busybox sh). Sem
# 'local', sem arrays, sem bashismos. Único utilitário não-POSIX usado é o
# 'mktemp', com fallback manual quando ausente.
# ==============================================================================

# set -u: tratar variável não definida como erro fatal. Pega cedo erros de
# digitação em nomes de variável que, de outro modo, expandiriam para vazio
# silenciosamente. O idioma "${VAR:-padrao}" continua seguro sob set -u.
set -u

# ------------------------------------------------------------------------
# Cores ANSI.
#
# Guardamos o caractere ESC REAL (byte 0x1B) nas variáveis, em vez da
# notação "\033". Isso permite imprimir SEMPRE com 'printf "%s"' (string
# literal como formato), eliminando de vez o risco de SC2059/format-string
# injection: nenhum dado — cor, nome de arquivo ou mensagem — entra no
# argumento de formato do printf; tudo vai pelos argumentos.
# ------------------------------------------------------------------------
# O byte ESC é definido SEMPRE (é usado pelo sed que limpa ANSI do log,
# independentemente de haver terminal). Só as cores em si dependem do tty.
esc=$(printf '\033')
# shellcheck disable=SC2034  # 'negrito' é usado pelos codecs (via source)
if [ -t 1 ]; then
    vermelho="${esc}[31m"; verde="${esc}[32m"; amarelo="${esc}[33m"
    azul="${esc}[34m";     negrito="${esc}[1m"; cinza="${esc}[90m"
    reset="${esc}[0m"
else
    vermelho=''; verde=''; amarelo=''; azul=''; negrito=''; cinza=''; reset=''
fi

# Atalhos de impressão. 'diga' imprime uma linha; 'erro' imprime em stderr.
# Todo conteúdo já vem montado pelo chamador e sai via %s — nunca interpretado.
diga()  { printf '%s\n' "$1"; }
erro()  { printf '%s\n' "$1" >&2; }

# ------------------------------------------------------------------------
# Área temporária privada (mktemp -d). Tudo (capas extraídas, lista de
# arquivos) vive aqui dentro, com permissão 0700, evitando nomes
# previsíveis em /tmp (mitiga ataque de symlink em diretório compartilhado).
# O trap remove o diretório inteiro na saída — não dependemos de variáveis
# globais setadas dentro de subshells para a limpeza.
# ------------------------------------------------------------------------
criar_workdir() {
    base_tmp="${TMPDIR:-/tmp}"
    if work_dir=$(mktemp -d "${base_tmp}/flac2x.XXXXXX" 2>/dev/null); then
        return 0
    fi
    # Fallback sem mktemp: cria com umask restrito; se já existir, falha.
    work_dir="${base_tmp}/flac2x.$$"
    ( umask 077 && mkdir "$work_dir" ) || {
        erro "${vermelho}Erro: não foi possível criar diretório temporário.${reset}"
        exit 1
    }
}

limpeza_em_saida() {
    [ -n "${work_dir:-}" ] && rm -rf "$work_dir" 2>/dev/null
}

# INT/TERM: limpa e sai com código convencional (128+sinal). EXIT: só limpa
# (não re-invoca exit, para não mascarar o código de saída original).
#
# Limitação conhecida (dash): se um SIGTERM atingir SÓ o PID do script
# enquanto ele aguarda um filho em primeiro plano (ffmpeg/convert), o trap
# pode não rodar. Ctrl+C (SIGINT ao grupo de processos) e saída normal
# estão cobertos — que é o uso real esperado.
interrupcao_handler() { limpeza_em_saida; exit 130; }
trap interrupcao_handler INT TERM
trap limpeza_em_saida EXIT

# ------------------------------------------------------------------------
# Checagem de dependências do núcleo. Roda ANTES de qualquer menu para
# falhar cedo e claro, em vez de quebrar no arquivo 47 de 200.
# ------------------------------------------------------------------------
verificar_dependencias() {
    faltando=''
    command -v metaflac >/dev/null 2>&1 || \
        faltando="${faltando}  - metaflac (pacote 'flac')
"
    if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
        faltando="${faltando}  - ImageMagick (binário 'magick' ou 'convert')
"
    fi
    if [ -n "$faltando" ]; then
        erro "${vermelho}Erro: dependências obrigatórias ausentes:${reset}"
        printf '%s' "$faltando" >&2
        erro "${amarelo}Instale os pacotes acima e tente novamente.${reset}"
        exit 1
    fi
}

# ------------------------------------------------------------------------
# Carregamento e validação do codec.
# ------------------------------------------------------------------------
carregar_codec() {
    if [ -z "${CODEC_FILE:-}" ]; then
        erro "${vermelho}Erro: CODEC_FILE não definida. Use um wrapper (ex.: flac_to_aac.sh).${reset}"
        exit 1
    fi
    if [ ! -f "$CODEC_FILE" ]; then
        erro "${vermelho}Erro: arquivo de codec '$CODEC_FILE' não encontrado.${reset}"
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$CODEC_FILE"

    if [ -z "${EXTENSAO_SAIDA:-}" ]; then
        erro "${vermelho}Erro: o codec não definiu EXTENSAO_SAIDA.${reset}"
        exit 1
    fi
    command -v menu_qualidade >/dev/null 2>&1 || {
        erro "${vermelho}Erro: o codec não definiu menu_qualidade().${reset}"; exit 1; }
    command -v converter >/dev/null 2>&1 || {
        erro "${vermelho}Erro: o codec não definiu converter().${reset}"; exit 1; }
}

# ------------------------------------------------------------------------
# Banner centralizado (degrada para texto simples sem tput).
# ------------------------------------------------------------------------
banner() {
    msg="$1"
    if cols=$(tput cols 2>/dev/null) && [ "$cols" -gt 0 ] 2>/dev/null; then
        linha=$(printf '%*s' "$cols" '' | tr ' ' '#')
        padding=$(( (cols - ${#msg}) / 2 ))
        [ "$padding" -lt 0 ] && padding=0
        diga "${azul}${linha}${reset}"
        printf '%*s%s%s%s\n' "$padding" '' "$amarelo" "$msg" "$reset"
        diga "${azul}${linha}${reset}"
    else
        diga "$msg"
    fi
}

# ------------------------------------------------------------------------
# Leitura validada de opção de menu, com nova tentativa em vez de abortar.
#   $1 = opções válidas separadas por espaço (ex.: "1 2 3")
#   $2 = valor padrão (usado em Enter vazio ou EOF)
# Emite a opção escolhida no stdout. O texto do menu é do chamador.
# ------------------------------------------------------------------------
ler_opcao_valida() {
    opcoes_validas="$1"
    valor_padrao="$2"
    while true; do
        if ! IFS= read -r resposta; then
            # EOF (stdin fechado): assume o padrão e não entra em loop infinito.
            resposta=''
        fi
        resposta=${resposta:-$valor_padrao}
        for opcao in $opcoes_validas; do
            if [ "$resposta" = "$opcao" ]; then
                printf '%s\n' "$resposta"
                return 0
            fi
        done
        erro "${vermelho}Opção inválida: '$resposta'. Escolha uma das opções acima.${reset}"
        # Se a entrada era EOF/padrão inválido (não deveria ocorrer: padrões
        # são sempre válidos), evita loop eterno saindo com o padrão.
    done
}

# ------------------------------------------------------------------------
# Menu: escopo de busca (pasta atual x recursivo).
#
# 'find .' já devolve caminhos com prefixo "./", o que protege nomes que
# começam com hífen de serem lidos como flags por basename/metaflac. Usamos
# apenas operadores POSIX: '-iname' (amplamente suportado, inclusive busybox)
# e '!' para negação (POSIX, ao contrário do GNU '-not'). Sem '-printf'.
# ------------------------------------------------------------------------
menu_escopo() {
    diga "${amarelo}Escolha o escopo de busca:${reset}"
    diga "${verde}1)${reset} Apenas nesta pasta ${verde}[padrão]${reset}"
    diga "${verde}2)${reset} Incluir subpastas"
    diga "${amarelo}(Enter para ${verde}1${amarelo})${reset}"
    escopo=$(ler_opcao_valida "1 2" "1")
    case "$escopo" in
        1) lista=$(find . -maxdepth 1 -type f -iname '*.flac') ;;
        2) lista=$(find . -type f -iname '*.flac' ! -path "./$diretorio/*") ;;
    esac
}

# ------------------------------------------------------------------------
# Menu: pular arquivos já convertidos.
# ------------------------------------------------------------------------
menu_pular_existentes() {
    diga "${amarelo}Pular arquivos já convertidos?${reset}"
    diga "${verde}1)${reset} Sim, pular se o destino já existir ${verde}[padrão]${reset}"
    diga "${verde}2)${reset} Não, reconverter tudo"
    diga "${amarelo}(Enter para ${verde}1${amarelo})${reset}"
    pular_opt=$(ler_opcao_valida "1 2" "1")
    case "$pular_opt" in
        1) pular_existentes=1 ;;
        2) pular_existentes=0 ;;
    esac
}

# ------------------------------------------------------------------------
# Menu: perfil de capa (resolução-alvo do redimensionamento).
# res=0 significa "manter original, sem redimensionar".
# ------------------------------------------------------------------------
menu_thumb() {
    diga "${amarelo}Escolha o perfil de otimização da capa:${reset}"
    diga "${verde}1)${reset} Perfil Legado        (200x200${cinza}px${reset}    | ~10${cinza}KB${reset})"
    diga "${verde}2)${reset} Perfil MP3 CD        (300x300${cinza}px${reset}    | ~30${cinza}KB${reset}) ${verde}[padrão]${reset}"
    diga "${verde}3)${reset} Perfil iPod / SD     (600x600${cinza}px${reset}    | ~100${cinza}KB${reset})"
    diga "${verde}4)${reset} Perfil iPad Retina   (1400x1400${cinza}px${reset} | ~300${cinza}KB${reset})"
    diga "${verde}5)${reset} Perfil HI-DPI        (2400x2400${cinza}px${reset} | ~600${cinza}KB${reset})"
    diga "${verde}6)${reset} ${vermelho}Não otimizar — manter imagem original${reset}"
    diga "${amarelo}(Enter para ${verde}2${amarelo})${reset}"
    opt_perfil=$(ler_opcao_valida "1 2 3 4 5 6" "2")
    case "$opt_perfil" in
        1) res=200;  thumb_info="LEGADO" ;;
        2) res=300;  thumb_info="MP3 CD" ;;
        3) res=600;  thumb_info="IPOD/SD" ;;
        4) res=1400; thumb_info="RETINA" ;;
        5) res=2400; thumb_info="HI-DPI" ;;
        6) res=0;    thumb_info="ORIGINAL" ;;
    esac
}

# ------------------------------------------------------------------------
# Detecta o binário do ImageMagick (magick novo x convert legado).
# ------------------------------------------------------------------------
detectar_imagemagick() {
    if command -v magick >/dev/null 2>&1; then
        img_cmd="magick"
    else
        img_cmd="convert"
    fi
}

# ------------------------------------------------------------------------
# processar_capa ENTRADA INDICE
#   Extrai a capa do FLAC para $work_dir/cover_INDICE.png e, se houver
#   perfil de resize (res != 0), gera cover_INDICE_resized.png.
#   Emite no stdout o caminho da capa a usar (ou nada, se não houver capa).
#
# Roda em command substitution (subshell) — por isso NÃO depende de variável
# global para limpeza: os arquivos ficam em $work_dir (removido pelo trap), e
# o chamador apaga cover_INDICE.* explicitamente após cada faixa.
#
# Redimensionamento: filtro Lanczos (melhor nitidez em downscale) e
# "${res}x${res}>" (só reduz, nunca amplia — preserva qualidade quando a
# capa original já é menor). '-strip' remove metadados da imagem.
# ------------------------------------------------------------------------
processar_capa() {
    pc_entrada="$1"
    pc_idx="$2"
    pc_cover="$work_dir/cover_${pc_idx}.png"
    pc_resized="$work_dir/cover_${pc_idx}_resized.png"
    rm -f "$pc_cover" "$pc_resized"

    # Valida o FLAC antes de tentar ler a capa. Arquivo inválido => sem capa
    # (silencioso aqui; a falha real do áudio será tratada em converter()).
    if ! metaflac --list "$pc_entrada" >/dev/null 2>&1; then
        erro "${amarelo}Aviso: '$(basename "$pc_entrada")' ilegível pelo metaflac; sem capa.${reset}"
        return 0
    fi

    # Prefere capa tipo 3 (Front Cover); aceita tipo 0 (Other) como fallback.
    if metaflac --list --block-type=PICTURE "$pc_entrada" 2>/dev/null | grep -q "type: 3"; then
        metaflac --export-picture-to="$pc_cover" "$pc_entrada" 2>/dev/null
    elif metaflac --list --block-type=PICTURE "$pc_entrada" 2>/dev/null | grep -q "type: 0"; then
        metaflac --export-picture-to="$pc_cover" "$pc_entrada" 2>/dev/null
    fi

    [ -f "$pc_cover" ] || return 0

    if [ "$res" -ne 0 ] 2>/dev/null; then
        if "$img_cmd" "$pc_cover" -filter Lanczos -resize "${res}x${res}>" -strip "$pc_resized" 2>/dev/null \
           && [ -f "$pc_resized" ]; then
            printf '%s\n' "$pc_resized"
            return 0
        fi
        # Resize falhou: degrada para a capa original em vez de perder a arte.
        erro "${amarelo}Aviso: redimensionamento da capa falhou; usando original.${reset}"
    fi
    printf '%s\n' "$pc_cover"
}

# ------------------------------------------------------------------------
# Verifica espaço livre no destino.
#   $1 = "preventivo" (limiar 100 MB; só avisa; sempre retorna 0)
#        "critico"    (limiar  20 MB; avisa e retorna 1 para abortar o lote)
# 'df -Pk' = saída portátil em blocos de 1 KB; coluna 4 = disponível.
# ------------------------------------------------------------------------
verificar_espaco_disco() {
    modo="$1"
    disponivel_kb=$(df -Pk "$diretorio" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -z "$disponivel_kb" ] && return 0

    if [ "$modo" = "critico" ]; then
        limite_kb=20480
    else
        limite_kb=102400
    fi

    if [ "$disponivel_kb" -lt "$limite_kb" ] 2>/dev/null; then
        disponivel_mb=$((disponivel_kb / 1024))
        if [ "$modo" = "critico" ]; then
            diga "${vermelho}Erro: disco esgotado em '$diretorio' (~${disponivel_mb} MB). Interrompendo o lote.${reset}"
            return 1
        fi
        diga "${vermelho}Aviso: pouco espaço em '$diretorio' (~${disponivel_mb} MB).${reset}"
        diga "${amarelo}A conversão pode falhar se o disco esgotar. Considere liberar espaço.${reset}"
    fi
    return 0
}

# ------------------------------------------------------------------------
# Loop principal de conversão.
# ------------------------------------------------------------------------
loop_de_conversao() {
    total=$(printf '%s\n' "$lista" | grep -c .)
    convertidos=0
    pulados=0
    n=0

    if [ "$total" -eq 0 ]; then
        diga "${amarelo}Nenhum .flac encontrado com o escopo escolhido.${reset}"
        diga "${amarelo}Confirme a pasta atual e o escopo (apenas esta pasta x subpastas).${reset}"
        return 0
    fi

    diga "Convertendo ${verde}${total}${reset} arquivos | Capa: ${verde}${thumb_info}${reset} | Áudio: ${verde}${INFO_BR}${reset}"

    if ! mkdir -p "$diretorio"; then
        erro "${vermelho}Erro: não foi possível criar o destino '$diretorio'.${reset}"
        erro "${vermelho}Verifique permissões de escrita e validade do caminho.${reset}"
        exit 1
    fi

    verificar_espaco_disco "preventivo"

    arquivo_log="$diretorio/log_conversao_$(date +%Y%m%d_%H%M%S).txt"

    # log_e_tela: imprime na tela (com cor) e grava no log SEM cor. O sed usa
    # o byte ESC literal ($esc) — funciona em GNU/BSD/busybox sed (a notação
    # "\x1b" é exclusiva do GNU sed e não casaria no busybox).
    log_e_tela() {
        printf '%s\n' "$1"
        printf '%s\n' "$1" | sed "s/${esc}\\[[0-9;]*m//g" >> "$arquivo_log"
    }

    {
        printf 'Log de conversão — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'Total encontrado: %s\n' "$total"
        printf 'Perfil de capa: %s | Perfil de áudio: %s\n' "$thumb_info" "$INFO_BR"
        printf '%s\n' "----------------------------------------"
    } >> "$arquivo_log"

    # Lista vai para arquivo (não pipe): um pipe colocaria o 'while' num
    # subshell em sh/dash, e os contadores seriam perdidos ao fim do loop.
    tmp_lista="$work_dir/flac_lista"
    printf '%s\n' "$lista" > "$tmp_lista"

    while IFS= read -r arquivo; do
        [ -z "$arquivo" ] && continue
        n=$((n + 1))

        if ! verificar_espaco_disco "critico"; then
            log_e_tela "${vermelho}Lote interrompido em [$n/$total] por falta de espaço.${reset}"
            break
        fi

        nome_base="${arquivo#./}"
        musica=$(basename "$arquivo")

        # Remoção de sufixo .flac case-insensitive (o operador %.flac do
        # POSIX é sensível à caixa; '-iname' acha .FLAC/.Flac também).
        case "$nome_base" in
            *.flac) nome_base="${nome_base%.flac}" ;;
            *.FLAC) nome_base="${nome_base%.FLAC}" ;;
            *.Flac) nome_base="${nome_base%.Flac}" ;;
        esac

        outpath="$diretorio/${nome_base}.$EXTENSAO_SAIDA"

        if ! mkdir -p "$(dirname "$outpath")"; then
            log_e_tela "${vermelho}[$n/$total] Erro: subpasta de destino para '$musica' falhou. Pulando.${reset}"
            pulados=$((pulados + 1))
            continue
        fi

        if [ "$pular_existentes" -eq 1 ] && [ -f "$outpath" ]; then
            log_e_tela "[${verde}$n${reset}/${verde}$total${reset}] ${cinza}$musica (já existe, pulado)${reset}"
            pulados=$((pulados + 1))
            continue
        fi

        log_e_tela "[${verde}$n${reset}/${verde}$total${reset}] $musica"

        capa=$(processar_capa "$arquivo" "$n")

        if converter "$arquivo" "$outpath" "$capa"; then
            log_e_tela "${verde}$musica convertido com sucesso!${reset}"
            convertidos=$((convertidos + 1))
        else
            log_e_tela "${vermelho}A conversão de $musica falhou!${reset}"
            pulados=$((pulados + 1))
        fi

        rm -f "$work_dir/cover_${n}.png" "$work_dir/cover_${n}_resized.png"
    done < "$tmp_lista"

    diga "Log salvo em: ${azul}${arquivo_log}${reset}"
}

# ==============================================================================
# EXECUÇÃO
# ==============================================================================
criar_workdir
carregar_codec

# Destino padrão (o codec pode sobrescrever via DEST_DIR antes do source).
diretorio="${DEST_DIR:-convertidos_$EXTENSAO_SAIDA}"

banner "Transcodificação FLAC -> ${EXTENSAO_SAIDA}"
verificar_dependencias
detectar_imagemagick
menu_escopo
menu_qualidade
menu_thumb
menu_pular_existentes
loop_de_conversao

banner "Fim!"
diga "Convertidos: ${verde}${convertidos}${reset} | Pulados: ${vermelho}${pulados}${reset}"
