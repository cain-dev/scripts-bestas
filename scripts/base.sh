#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC2059
# Justificativa do SC2059: as variáveis de cor (${amarelo}, ${verde}, etc.)
# guardam apenas sequências de escape ANSI fixas, nunca dados externos ou
# input do usuário. Não há risco de injeção via "%" nessas strings.

# ------------------------------------------------------------------------
# ITEM — "set -u": TRATA VARIÁVEL NÃO DEFINIDA COMO ERRO
# ------------------------------------------------------------------------
# Por que isso existe: sem "set -u", referenciar uma variável que nunca
# foi definida (por exemplo, por um erro de digitação no nome dela, ou
# por uma função que deveria ter setado algo e não setou) simplesmente
# expande para uma string vazia, silenciosamente. Isso é uma fonte clássica
# de bugs sutis em shell script: um "if [ "$variavel_com_nome_errado" = ...
# ]" nunca vai disparar erro nenhum, só vai se comportar de forma errada
# sem deixar pista de qual foi o problema.
#
# Com "set -u" ativo, qualquer expansão de variável não definida interrompe
# o script imediatamente com uma mensagem clara apontando o NOME da
# variável (ex: "variavel_x: parameter not set"), em vez de seguir adiante
# silenciosamente com um valor vazio inesperado.
#
# Isso é compatível com o padrão "${variavel:-valor_padrao}" usado em todo
# este script (testado e confirmado): essa sintaxe tem uma proteção
# embutida contra "set -u" — se "variavel" não existir, o "${...:-...}"
# já fornece o valor padrão sem disparar erro, exatamente como esperado.
# O que "set -u" pega é o caso diferente: uma variável referenciada SEM
# nenhum fallback (ex: "$variavel" sozinho, sem ":-"), quando ela nunca
# foi definida em nenhum ponto anterior do script.
# ------------------------------------------------------------------------
set -u

# ==============================================================================
# SCRIPT: base.sh
# OPERAÇÃO: Base genérica de transcodificação de FLAC
# USO: defina CODEC_FILE antes de chamar, ou exporte via wrapper (ex: flac_to_aac.sh)
# DEPENDÊNCIAS: ffmpeg, metaflac, imagemagick (convert/magick)
# CONTRATO COM O CODEC:
#   O arquivo de codec (ex: codec_aac.sh) deve definir:
#     - menu_qualidade()      -> define AUDIO_CMD e INFO_BR
#     - converter()           -> recebe 3 args: entrada, saida, capa (ou "")
#                                 deve retornar 0 em sucesso, != 0 em falha
#     - EXTENSAO_SAIDA        -> ex: "m4a", "opus"
# ==============================================================================

# ------------------------------------------------------------------------
# cores (POSIX, sem tput colors check — fallback simples)
# ------------------------------------------------------------------------
# shellcheck disable=SC2034
# negrito é usado pelos arquivos de codec (ex: codec_aac.sh), não diretamente aqui
if [ -t 1 ]; then
    vermelho="\033[31m"; verde="\033[32m"; amarelo="\033[33m"; azul="\033[34m"
    negrito="\033[1m"; cinza="\033[90m"; reset="\033[0m"
else
    vermelho=""; verde=""; amarelo=""; azul=""; negrito=""; cinza=""; reset=""
fi

# ------------------------------------------------------------------------
# ITEM 1 — VERIFICAÇÃO DE DEPENDÊNCIAS EXTERNAS
# ------------------------------------------------------------------------
# Por que isso existe: sem essa checagem, o script só descobriria que falta
# o "metaflac" ou o "magick" quando chegasse na metade do loop, no meio da
# conversão do arquivo de número 47 de 200. Isso é ruim por dois motivos:
# (a) o usuário perde tempo esperando até o ponto da falha, e (b) a mensagem
# de erro que aparece é a do comando que faltou (ex: "command not found"),
# que não deixa claro que o problema é uma dependência ausente do sistema,
# e não um defeito do script ou do arquivo de áudio.
#
# Por isso verificamos tudo ANTES de mostrar qualquer menu. Se faltar algo,
# o script para imediatamente e lista exatamente o que precisa ser instalado.
#
# NOTA: "metaflac" é sempre exigido aqui no base.sh, porque é usado pela
# função processar_capa() (que pertence ao base.sh, não ao codec). Já o
# binário de transcodificação de áudio (ffmpeg, ffmpeg-libfdk, opusenc etc.)
# é responsabilidade do PRÓPRIO ARQUIVO DE CODEC verificar, porque cada
# codec pode exigir um binário diferente (ex: codec_aac.sh usa um ffmpeg
# customizado com libfdk_aac, que já tem sua própria checagem feita logo
# no topo daquele arquivo). Por isso esta função não verifica "ffmpeg"
# genericamente — isso ficaria por conta de cada codec_*.sh.
# ------------------------------------------------------------------------
verificar_dependencias() {
    faltando=""

    if ! command -v metaflac >/dev/null 2>&1; then
        faltando="${faltando}  - metaflac (pacote 'flac' na maioria das distros)\n"
    fi

    # ImageMagick: aceita tanto o binário novo (magick, IM7+) quanto o
    # legado (convert, IM6). Só reportamos falta se NENHUM dos dois existir.
    if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
        faltando="${faltando}  - ImageMagick (binário 'magick' ou 'convert')\n"
    fi

    if [ -n "$faltando" ]; then
        printf "${vermelho}Erro: dependências obrigatórias não encontradas no sistema:${reset}\n"
        printf "%b" "$faltando"
        printf "${amarelo}Instale os pacotes acima antes de executar este script novamente.${reset}\n"
        exit 1
    fi
}

# ------------------------------------------------------------------------
# carregamento do codec (precisa vir depois das cores, antes dos menus)
# ------------------------------------------------------------------------
# NOTA sobre "${CODEC_FILE:-}" em vez de "$CODEC_FILE": com "set -u" ativo
# (ver topo do arquivo), referenciar uma variável NUNCA declarada (não
# apenas vazia) interrompe o script imediatamente com um erro genérico do
# próprio shell, antes mesmo de chegar à mensagem de erro amigável que
# queremos mostrar aqui. A sintaxe "${CODEC_FILE:-}" devolve uma string
# vazia tanto se a variável for vazia quanto se nunca tiver existido,
# permitindo que o "[ -z ... ]" abaixo trate os dois casos de forma
# unificada e mostre a mensagem de erro pretendida, em vez de um erro
# técnico de "parameter not set" sem contexto para quem está usando o
# script.
# ------------------------------------------------------------------------
if [ -z "${CODEC_FILE:-}" ]; then
    printf "${vermelho}Erro: variável CODEC_FILE não definida. Use um wrapper (ex: flac_to_aac.sh).${reset}\n" >&2
    exit 1
fi

if [ ! -f "$CODEC_FILE" ]; then
    printf "${vermelho}Erro: arquivo de codec '%s' não encontrado.${reset}\n" "$CODEC_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$CODEC_FILE"

# verifica se o codec definiu o que precisa
if [ -z "$EXTENSAO_SAIDA" ]; then
    printf "${vermelho}Erro: o codec (%s) não definiu EXTENSAO_SAIDA.${reset}\n" "$CODEC_FILE" >&2
    exit 1
fi

if ! command -v menu_qualidade >/dev/null 2>&1; then
    printf "${vermelho}Erro: o codec (%s) não definiu a função menu_qualidade().${reset}\n" "$CODEC_FILE" >&2
    exit 1
fi

if ! command -v converter >/dev/null 2>&1; then
    printf "${vermelho}Erro: o codec (%s) não definiu a função converter().${reset}\n" "$CODEC_FILE" >&2
    exit 1
fi

# ------------------------------------------------------------------------
# ITEM 5 — LIMPEZA GARANTIDA EM CASO DE INTERRUPÇÃO (trap)
# ------------------------------------------------------------------------
# Por que isso existe: sem um "trap", se o usuário apertar Ctrl+C no meio
# da conversão (ou o processo for encerrado por qualquer outro motivo:
# fechar o terminal, "kill", falta de energia detectável via sinal etc.),
# os arquivos temporários de capa em /tmp (cover_*.png) e o arquivo
# temporário da lista de FLACs encontrados (flac_lista_$$) ficam órfãos
# no disco. Isso não quebra nada de imediato, mas acumula lixo em /tmp
# ao longo de várias execuções interrompidas.
#
# A variável "$$" usada nos nomes dos arquivos temporários é o PID do
# processo do script. Cada execução tem um PID diferente, então os nomes
# não colidem entre execuções simultâneas — mas ainda assim, se a execução
# for interrompida, o arquivo daquele PID específico precisa ser apagado.
#
# Guardamos os nomes dos arquivos temporários em variáveis GLOBAIS
# (declaradas aqui, no escopo principal do script, fora de qualquer
# função) para que a função limpeza_em_saida(), chamada pelo trap,
# consiga "ver" e remover exatamente os arquivos que estavam em uso
# no momento da interrupção — não importa em qual ponto do script ela
# aconteceu.
#
# "trap ... INT TERM EXIT" cobre três cenários:
#   INT  = Ctrl+C (sinal de interrupção do teclado)
#   TERM = encerramento "educado" pedido por outro processo (ex: kill PID)
#   EXIT = qualquer saída do script, incluindo término normal — isso
#          garante que a limpeza roda mesmo quando tudo correu bem,
#          então este trap substitui a necessidade de "rm -f" manual
#          espalhado pelo resto do script.
# ------------------------------------------------------------------------

# nomes dos arquivos temporários, declarados aqui no escopo global para
# que a função de limpeza abaixo tenha acesso a eles em qualquer momento
tmp_cover=""
tmp_cover_resized=""
tmp_lista=""

# ------------------------------------------------------------------------
# LIMITAÇÃO REAL DESCOBERTA EM TESTE, IMPORTANTE DE DOCUMENTAR:
#
# Em dash (o /bin/sh padrão em Debian/Ubuntu), quando o script está
# bloqueado dentro de um wait() por um comando externo em primeiro plano
# (por exemplo, o "ffmpeg" dentro da função converter(), ou o "magick"
# dentro de processar_capa()), um SIGTERM enviado APENAS ao PID do
# processo do script — sem afetar o filho em execução — NÃO dispara
# o trap. Isso foi confirmado por teste isolado, reproduzido três vezes:
# o processo morre imediatamente ao receber o SIGTERM nesse estado, SEM
# rodar a função registrada via "trap", e os arquivos temporários ficam
# órfãos. Esse comportamento é uma característica de implementação do
# dash (entrega do sinal interrompe o wait() de forma que o trap não
# chega a ser processado antes do processo terminar), não um bug deste
# script — e por isso este comentário documenta a limitação em vez de
# fingir que ela foi resolvida.
#
# O QUE O TRAP ABAIXO CONSEGUE GARANTIR, DE FATO (testado e confirmado):
#   1. Ctrl+C digitado no terminal onde o script está rodando: funciona
#      corretamente. Isso porque o terminal envia o SIGINT para TODO O
#      GRUPO DE PROCESSOS em primeiro plano — script E ffmpeg recebem o
#      sinal ao mesmo tempo, o ffmpeg aborta sozinho (ele mesmo trata
#      SIGINT), o controle volta ao shell, e SÓ ENTÃO o trap roda. Este
#      é o cenário de uso real esperado (usuário cancelando manualmente)
#      e está coberto.
#   2. Encerramento normal do script (sem nenhuma interrupção): o trap
#      de EXIT sempre dispara, garantindo limpeza mesmo em caminhos de
#      saída antecipada (ex: "exit 1" em qualquer checagem de erro acima).
#
# O QUE NÃO ESTÁ GARANTIDO (limitação aceita, não um requisito do uso
# normal deste script):
#   Um "kill <PID>" disparado de OUTRO terminal/processo, visando
#   especificamente o PID do script (e não o ffmpeg, nem o grupo todo),
#   enquanto uma conversão está em andamento. Nesse caso raro e externo
#   ao fluxo normal de uso, os arquivos temporários de /tmp podem ficar
#   órfãos até a próxima execução do script (que os recria com um nome
#   diferente, baseado no PID daquela execução — então não há colisão,
#   apenas acúmulo de lixo inofensivo em /tmp ao longo do tempo).
# ------------------------------------------------------------------------

limpeza_em_saida() {
    # o '2>/dev/null' aqui não é para esconder erros graves: é porque
    # "rm -f" em uma variável vazia (ex: tmp_cover="") tentaria remover
    # um caminho vazio, o que o 'rm' já ignora silenciosamente por causa
    # do '-f' — mas deixamos o redirecionamento como segurança redundante
    rm -f "$tmp_cover" "$tmp_cover_resized" "$tmp_lista" 2>/dev/null
}

# Handler específico para INT (Ctrl+C): cobre o cenário 1 descrito acima.
# Chamamos "exit 130" no final (130 = 128 + sinal 2/SIGINT, convenção
# padrão de shells para processos terminados por sinal) para garantir que
# o script realmente pare aqui, em vez de continuar executando a partir
# do ponto em que foi interrompido.
interrupcao_handler() {
    limpeza_em_saida
    exit 130
}

# trap separado por tipo de sinal, de propósito:
#   INT  -> interrupcao_handler (limpa E força saída com código 130)
#   TERM -> mesmo handler (cobre o "kill" padrão sem flag, que envia TERM;
#            funciona quando o TERM chega enquanto o script NÃO está
#            bloqueado em um comando filho — ex: durante os menus de
#            input, ou entre uma conversão e outra dentro do loop)
#   EXIT -> limpeza_em_saida (sem exit explícito: o script já está
#            terminando de qualquer forma nesse ponto; chamar "exit" de
#            novo dentro de um trap de EXIT não tem efeito útil e pode
#            mascarar o código de saída original do script)
trap interrupcao_handler INT TERM
trap limpeza_em_saida EXIT

# ------------------------------------------------------------------------
# diretório de saída (pode ser sobrescrito pelo codec antes do source, se quiser)
# ------------------------------------------------------------------------
diretorio="${DEST_DIR:-convertidos_$EXTENSAO_SAIDA}"

# ------------------------------------------------------------------------
# banner
# ------------------------------------------------------------------------
banner() {
    msg="$1"
    if cols=$(tput cols 2>/dev/null); then
        padding=$(( (cols - ${#msg}) / 2 ))
        printf "${azul}%${cols}s${reset}\n" | tr ' ' '#'
        printf "%*s${amarelo}%s${reset}%*s\n" "$padding" "" "$msg" "$padding" ""
        printf "${azul}%${cols}s${reset}\n" | tr ' ' '#'
    else
        printf "%s\n" "$msg"
    fi
}

# ------------------------------------------------------------------------
# ITEM — VALIDAÇÃO DE ENTRADA COM NOVA TENTATIVA (em vez de matar o script)
# ------------------------------------------------------------------------
# Por que isso existe: antes, qualquer opção de menu fora da lista esperada
# (ex: digitar "abc" em vez de um número) encerrava o script imediatamente
# com "exit 1". Isso é uma escolha de design legítima, mas tem um custo
# real: se o usuário já respondeu três menus corretamente e erra a
# digitação só no quarto, ele perde todo o progresso e precisa recomeçar
# do zero. A alternativa mais amigável, sem abandonar o estilo direto do
# restante do script, é simplesmente perguntar de novo até receber uma
# opção válida — sem sair do script por um erro de digitação.
#
# Esta função é genérica e usada pelos quatro menus abaixo. Ela recebe:
#   $1 = a lista de opções válidas, separadas por espaço (ex: "1 2 3 4")
#   $2 = o valor padrão a usar se o usuário só apertar Enter
# E devolve (via "echo", capturado com "$(...)" por quem chamar) a opção
# escolhida, já validada — garantidamente um dos valores de $1.
#
# A "pergunta" em si (texto do menu) é responsabilidade de quem chama esta
# função, que deve imprimir o menu ANTES de invocá-la. Isso evita duplicar
# a lógica de "ler + validar + repetir se inválido" em cada menu individual.
# ------------------------------------------------------------------------
ler_opcao_valida() {
    opcoes_validas="$1"
    valor_padrao="$2"

    while true; do
        read -r resposta
        resposta=${resposta:-$valor_padrao}

        # verifica se "$resposta" está dentro da lista de opções válidas,
        # comparando contra cada item separado por espaço em "$opcoes_validas"
        for opcao in $opcoes_validas; do
            if [ "$resposta" = "$opcao" ]; then
                echo "$resposta"
                return 0
            fi
        done

        printf "${vermelho}Opção inválida: '%s'. Escolha uma das opções listadas acima.${reset}\n" "$resposta" >&2
    done
}

# ------------------------------------------------------------------------
# menu: escopo de busca
# ------------------------------------------------------------------------
menu_escopo() {
    printf "${amarelo}Escolha o escopo de busca:${reset}\n"
    printf "${verde}1)${reset} Apenas nesta pasta ${verde}[padrão]${reset}\n"
    printf "${verde}2)${reset} Incluir subpastas\n"
    printf "${amarelo}(Tecle ${azul}Enter${amarelo} para ${verde}1${amarelo})${reset}\n"
    escopo=$(ler_opcao_valida "1 2" "1")

    # ------------------------------------------------------------------
    # CORREÇÃO DE BUG REAL: uso de "%p" em vez de "%P" no find -printf
    # ------------------------------------------------------------------
    # Por que isso existe: "%P" no "find -printf" devolve o caminho SEM
    # o prefixo "./" (ex: "musica.flac"). Isso parece inofensivo, mas
    # quebra de forma real quando o nome do arquivo começa com um hífen
    # (ex: "-faixa-promocional.flac"). Sem o "./" na frente, ao passar
    # esse nome para comandos como "basename" ou "metaflac", o shell e
    # esses programas interpretam o "-" inicial como início de uma FLAG
    # de linha de comando, não como parte do nome do arquivo. Isso foi
    # reproduzido e confirmado: "basename -faixa.flac" falhou com erro
    # "invalid option -- 'f'", e o nome do arquivo virou uma string vazia
    # no restante do processamento daquela música.
    #
    # "%p" devolve o caminho COMPLETO retornado pelo find, que já inclui
    # o prefixo "./" (porque a busca começa em "find ." — o ponto vira
    # parte do caminho retornado). Com o "./" na frente, um nome como
    # "-faixa-promocional.flac" se torna "./-faixa-promocional.flac",
    # que nenhum comando confunde com uma flag, porque a string não
    # COMEÇA mais com "-".
    # ------------------------------------------------------------------
    # CORREÇÃO DE BUG REAL (portabilidade): "-printf" e "-not" REMOVIDOS.
    # ------------------------------------------------------------------
    # Por que isso existe: tanto "-printf" quanto "-not" são EXTENSÕES
    # GNU do "find", não fazem parte do POSIX e não existem em todo
    # "find". Isso foi confirmado testando o script em "busybox sh", que
    # tem seu próprio "find" embutido (comum em containers minimalistas,
    # Alpine Linux, sistemas embarcados como NAS e roteadores): o
    # "busybox find" não reconhece "-printf" (erro "unrecognized:
    # -printf"), o que fazia "$lista" ficar permanentemente vazia nesse
    # ambiente — o script rodava sem erro aparente, mas reportava "0
    # arquivos encontrados" mesmo numa pasta cheia de FLACs, um bug
    # silencioso e enganoso.
    #
    # A correção usa "find" sem nenhuma flag não-POSIX: por padrão, sem
    # "-printf", o "find ." já devolve o caminho completo de cada
    # resultado PRECEDIDO de "./" (testado e confirmado também no
    # busybox), que é exatamente o formato que "%p" nos dava antes — então
    # a proteção contra nomes de arquivo começando com hífen (explicada
    # acima) continua intacta sem precisar de "-printf".
    #
    # Para a negação de caminho (excluir a pasta de destino da busca
    # recursiva), troca-se "-not -path" (GNU) por "! -path" (POSIX/BSD/
    # busybox) — o "!" é o operador de negação padrão do "find" desde a
    # especificação original do POSIX, reconhecido universalmente.
    # ------------------------------------------------------------------
    case "$escopo" in
        1) lista=$(find . -maxdepth 1 -type f -iname "*.flac") ;;
        2) lista=$(find . -type f -iname "*.flac" ! -path "./$diretorio/*") ;;
    esac
    # nenhum "*) ... exit 1" aqui: "$escopo" já chega validado pela função
    # ler_opcao_valida() acima, que só devolve "1" ou "2" — qualquer outra
    # entrada já foi reperguntada ao usuário antes de chegar até este ponto.
}

# ------------------------------------------------------------------------
# menu: pular arquivos já convertidos
# ------------------------------------------------------------------------
menu_pular_existentes() {
    printf "${amarelo}Pular arquivos já convertidos?${reset}\n"
    printf "${verde}1)${reset} Sim, pular se o destino já existir ${verde}[padrão]${reset}\n"
    printf "${verde}2)${reset} Não, reconverter tudo\n"
    printf "${amarelo}(Tecle ${azul}Enter${amarelo} para ${verde}1${amarelo})${reset}\n"
    pular_opt=$(ler_opcao_valida "1 2" "1")

    case "$pular_opt" in
        1) pular_existentes=1 ;;
        2) pular_existentes=0 ;;
    esac
}

# ------------------------------------------------------------------------
# menu: qualidade da capa
# ------------------------------------------------------------------------
menu_thumb() {
    printf "${amarelo}Escolha o perfil de otimização da capa:${reset}\n"
    printf "${verde}1)${reset} Perfil Legado        (200x200${cinza}px${reset}    | 10${cinza}KB${reset})\n"
    printf "${verde}2)${reset} Perfil MP3 CD        (300x300${cinza}px${reset}    | 30${cinza}KB${reset}) - ${verde}(padrão)${reset}\n"
    printf "${verde}3)${reset} Perfil iPod / SD     (600x600${cinza}px${reset}    | 100${cinza}KB${reset})\n"
    printf "${verde}4)${reset} Perfil iPad Retina   (1400x1400${cinza}px${reset} | 300${cinza}KB${reset})\n"
    printf "${verde}5)${reset} Perfil HI-DPI        (2400x2400${cinza}px${reset} | 600${cinza}KB${reset})\n"
    printf "${verde}6)${reset} ${vermelho}Não otimizar - Manter imagem original${reset}\n"
    printf "${amarelo}Perfil ${azul}[${verde}${negrito}2${reset}${azul}]${azul}/${cinza}1/3/4/5/6${reset} ${amarelo}(Enter para ${verde}2${amarelo}):${reset} "
    opt_perfil=$(ler_opcao_valida "1 2 3 4 5 6" "2")

    case "$opt_perfil" in
        1) res="200";  thumb_info="LEGADO" ;;
        2) res="300";  thumb_info="MP3 CD" ;;
        3) res="600";  thumb_info="IPOD/SD" ;;
        4) res="1400"; thumb_info="RETINA" ;;
        5) res="2400"; thumb_info="HI-DPI" ;;
        6) res="0";    thumb_info="ORIGINAL" ;;
    esac
}

# ------------------------------------------------------------------------
# detecta binário do imagemagick (convert legado ou magick novo)
# ------------------------------------------------------------------------
detectar_imagemagick() {
    if command -v magick >/dev/null 2>&1; then
        img_cmd="magick"
    else
        img_cmd="convert"
    fi
}

# ------------------------------------------------------------------------
# extrai e (opcionalmente) redimensiona a capa de um FLAC
# retorna (via stdout) o caminho do arquivo de capa, ou nada se não houver
#
# NOTA SOBRE ESCOPO: "tmp_cover" e "tmp_cover_resized" são reaproveitadas
# aqui de propósito — são as MESMAS variáveis globais declaradas lá no
# início do script (na seção do trap, item 5). POSIX sh não tem variáveis
# "local" dentro de função (esse é um recurso de bash/zsh, não de sh puro),
# então qualquer atribuição direta dentro de uma função em sh sempre afeta
# a variável global do mesmo nome, mesmo que ela já existisse antes. Isso é
# intencional aqui: queremos que a função limpeza_em_saida() (chamada pelo
# trap) sempre veja o caminho mais recente desses arquivos temporários,
# para conseguir apagá-los se o script for interrompido no meio do processo
# de extração ou redimensionamento da capa.
# ------------------------------------------------------------------------
processar_capa() {
    arquivo="$1"
    n="$2"

    tmp_cover="/tmp/cover_${n}_$$.png"
    tmp_cover_resized="/tmp/cover_${n}_$$_resized.png"

    rm -f "$tmp_cover" "$tmp_cover_resized"

    # ------------------------------------------------------------------
    # ITEM 6 — VALIDAÇÃO DE ARQUIVO FLAC ANTES DE TENTAR LER A CAPA
    # ------------------------------------------------------------------
    # Por que isso existe: se "$arquivo" não for um FLAC válido (arquivo
    # corrompido, truncado, ou renomeado incorretamente com extensão .flac
    # mas conteúdo de outro formato), o comando "metaflac --list" abaixo
    # vai falhar. Sem essa checagem explícita, o erro do metaflac aparece
    # misturado com a saída normal do script, sem deixar claro qual
    # arquivo causou o problema nem que o problema é "arquivo inválido"
    # (em vez de, por exemplo, "sem capa", que é um caso normal e não um
    # erro). Validamos aqui, ANTES de tentar extrair a capa, e devolvemos
    # uma string vazia silenciosamente — o arquivo de áudio em si ainda
    # será testado de verdade na hora da conversão (função converter()),
    # que é o ponto certo para decidir se o arquivo é processável ou não.
    # Aqui só evitamos esse ruído de erro especificamente da etapa de capa.
    # ------------------------------------------------------------------
    if ! metaflac --list "$arquivo" >/dev/null 2>&1; then
        printf "${amarelo}Aviso: '%s' não pôde ser lido pelo metaflac (arquivo inválido ou corrompido). Pulando extração de capa.${reset}\n" "$(basename "$arquivo")" >&2
        return 0
    fi

    if metaflac --list --block-type=PICTURE "$arquivo" 2>/dev/null | grep -q "type: 3"; then
        metaflac --export-picture-to="$tmp_cover" "$arquivo" 2>/dev/null
    elif metaflac --list --block-type=PICTURE "$arquivo" 2>/dev/null | grep -q "type: 0"; then
        metaflac --export-picture-to="$tmp_cover" "$arquivo" 2>/dev/null
    fi

    if [ -f "$tmp_cover" ] && [ "$res" -ne 0 ] 2>/dev/null; then
        "$img_cmd" "$tmp_cover" -filter Lanczos -resize "${res}x${res}>" -strip "$tmp_cover_resized"
        echo "$tmp_cover_resized"
    elif [ -f "$tmp_cover" ]; then
        echo "$tmp_cover"
    fi
}

# ------------------------------------------------------------------------
# ITEM 4 — VERIFICAÇÃO DE ESPAÇO EM DISCO ANTES DE INICIAR O LOTE
# ------------------------------------------------------------------------
# Por que isso existe: conversões em lote de bibliotecas de música grandes
# (centenas de álbuns) podem consumir um espaço considerável em disco antes
# de terminar. Sem nenhuma checagem prévia, o cenário mais comum de falha
# é o disco enchendo no meio da conversão do arquivo 150 de 300 — nesse
# ponto, o "ffmpeg" simplesmente falha por falta de espaço, o que o script
# já trata como "conversão falhou" (incrementa o contador de pulados), mas
# sem deixar claro PARA O USUÁRIO que a causa raiz foi disco cheio, e não
# um problema no áudio em si.
#
# Esta função NÃO calcula o tamanho exato que a conversão vai ocupar (isso
# dependeria do codec, bitrate e duração de cada faixa, então seria uma
# estimativa frágil). Em vez disso, fazemos uma verificação mais simples e
# honesta: olhamos o espaço livre atual no destino e emitimos um AVISO se
# estiver criticamente baixo (definido aqui como menos de 100 MB livres).
# Isso não impede a execução — é só um alerta. A decisão de continuar ou
# não é do usuário, porque ele conhece melhor o tamanho médio dos arquivos
# que está convertendo.
# ------------------------------------------------------------------------
# ------------------------------------------------------------------------
# ITEM 4 — VERIFICAÇÃO DE ESPAÇO EM DISCO: ANTES E DURANTE O LOTE
# ------------------------------------------------------------------------
# Por que isso existe: conversões em lote de bibliotecas de música grandes
# (centenas de álbuns) podem consumir um espaço considerável em disco antes
# de terminar. A checagem feita só uma vez, antes de começar, tem uma
# lacuna real: ela vê o disco "OK" no início, mas não detecta o disco
# enchendo PROGRESSIVAMENTE ao longo de uma conversão longa — só vai
# descobrir isso quando o "ffmpeg" já estiver falhando arquivo após
# arquivo, silenciosamente acumulado como "pulados" no contador final,
# sem nenhum aviso de que a causa raiz é espaço em disco esgotado.
#
# Por isso esta função agora é chamada duas vezes: uma vez ANTES do loop
# (modo "preventivo": só avisa, não interrompe — o usuário pode decidir
# seguir mesmo com pouco espaço, é a decisão dele), e uma vez DENTRO do
# loop, a cada arquivo processado (modo "critico": usa um limiar bem mais
# baixo, e quando esse limiar é cruzado, AGORA SIM interrompe o restante
# do lote, porque nesse ponto continuar tentando converter os arquivos
# restantes não tem mais sentido — eles vão falhar um a um de qualquer
# forma, e é melhor parar de forma clara do que acumular "pulados" sem
# explicação visível na tela.
#
# $1 = modo: "preventivo" ou "critico"
#   preventivo: limiar de 100 MB, só avisa, sempre retorna 0 (continua)
#   critico:    limiar de 20 MB, avisa E retorna 1 (sinaliza para quem
#               chamou que deve interromper o loop)
# ------------------------------------------------------------------------
verificar_espaco_disco() {
    modo="$1"

    # "df -Pk" = saída portátil (-P) em blocos de 1KB (-k), evita variações
    # de formatação entre diferentes implementações de "df" (GNU vs BSD).
    # O "awk 'NR==2 {print $4}'" pega a 4ª coluna (espaço disponível) da
    # segunda linha (a primeira linha é o cabeçalho da tabela do df).
    disponivel_kb=$(df -Pk "$diretorio" 2>/dev/null | awk 'NR==2 {print $4}')

    # se por algum motivo não conseguimos ler o valor (df indisponível,
    # saída inesperada), não bloqueamos a execução — só seguimos sem aviso,
    # já que essa checagem é um "nice to have", não um requisito crítico.
    if [ -z "$disponivel_kb" ]; then
        return 0
    fi

    if [ "$modo" = "critico" ]; then
        limite_kb=20480  # 20 MB em KB — limiar de emergência, durante o loop
    else
        limite_kb=102400  # 100 MB em KB — limiar preventivo, antes do loop
    fi

    if [ "$disponivel_kb" -lt "$limite_kb" ] 2>/dev/null; then
        disponivel_mb=$((disponivel_kb / 1024))

        if [ "$modo" = "critico" ]; then
            printf "${vermelho}Erro: espaço em disco esgotado no destino '%s' (apenas %d MB livres). Interrompendo o restante do lote.${reset}\n" "$diretorio" "$disponivel_mb"
            return 1
        else
            printf "${vermelho}Aviso: espaço em disco baixo no destino '%s' (apenas %d MB livres).${reset}\n" "$diretorio" "$disponivel_mb"
            printf "${amarelo}A conversão pode falhar no meio do processo se o disco esgotar. Considere liberar espaço.${reset}\n"
        fi
    fi

    return 0
}

# ------------------------------------------------------------------------
# loop principal de conversão
# ------------------------------------------------------------------------
loop_de_conversao() {
    total=$(printf "%s\n" "$lista" | grep -c .)

    # convertidos/pulados/n precisam ser inicializados ANTES da checagem de
    # "nenhum arquivo encontrado" abaixo. Se a checagem retornar mais cedo
    # (return 0) e essas variáveis ainda não tivessem valor nenhum, a
    # mensagem final do script ("Convertidos: X | Pulados: Y") imprimiria
    # os campos vazios em vez de "0", o que pareceria um bug visual mesmo
    # sem ser um erro de fato — confuso para quem está lendo a saída.
    convertidos=0
    pulados=0
    n=0

    # ------------------------------------------------------------------
    # ITEM 2 — NENHUM ARQUIVO FLAC ENCONTRADO
    # ------------------------------------------------------------------
    # Por que isso existe: antes desta checagem, se a pasta escolhida não
    # tivesse nenhum arquivo .flac, o script seguia adiante normalmente e
    # só ao final mostrava "Convertidos: 0 | Pulados: 0" — uma mensagem
    # tecnicamente correta, mas que não deixa claro SE o script funcionou
    # e simplesmente não havia nada para converter, ou se algo deu errado
    # silenciosamente na busca de arquivos (ex: escopo errado, pasta errada).
    # Por isso, paramos aqui, de forma explícita, com uma mensagem que
    # orienta o usuário a checar se está na pasta certa ou se o escopo
    # escolhido (apenas esta pasta vs. subpastas) foi o pretendido.
    # ------------------------------------------------------------------
    if [ "$total" -eq 0 ]; then
        printf "${amarelo}Nenhum arquivo .flac encontrado com o escopo de busca escolhido.${reset}\n"
        printf "${amarelo}Verifique se você está na pasta correta e se o escopo (apenas esta pasta vs. subpastas) está certo.${reset}\n"
        return 0
    fi

    printf "Convertendo ${verde}${total}${reset} arquivos | Capa: ${verde}${thumb_info}${reset} | Áudio: ${verde}${INFO_BR}${reset}\n"

    # ------------------------------------------------------------------
    # ITEM 3 — TRATAMENTO DE ERRO NA CRIAÇÃO DO DIRETÓRIO DE SAÍDA
    # ------------------------------------------------------------------
    # Por que isso existe: "mkdir -p" pode falhar por motivos como permissão
    # negada no diretório pai, sistema de arquivos somente leitura, ou nome
    # de caminho inválido. Sem checar o código de saída do "mkdir", o script
    # original seguia adiante mesmo se a pasta não tivesse sido criada, e o
    # erro real só apareceria depois, de forma confusa, quando o "ffmpeg"
    # tentasse escrever no arquivo de saída e falhasse por causa de um
    # diretório que não existe. Aqui interrompemos imediatamente, com uma
    # mensagem que aponta exatamente qual foi o problema.
    # ------------------------------------------------------------------
    if ! mkdir -p "$diretorio"; then
        printf "${vermelho}Erro: não foi possível criar o diretório de saída '%s'.${reset}\n" "$diretorio" >&2
        printf "${vermelho}Verifique permissões de escrita e se o caminho é válido.${reset}\n" >&2
        exit 1
    fi

    verificar_espaco_disco "preventivo"

    # ------------------------------------------------------------------
    # ITEM 7 — REGISTRO EM ARQUIVO DE LOG
    # ------------------------------------------------------------------
    # Por que isso existe: numa conversão de centenas de arquivos, é comum
    # o usuário não estar olhando a tela o tempo todo. Sem um log persistido
    # em disco, qualquer falha que role pela tela é perdida assim que sai da
    # área visível do terminal, e não há como revisar depois quais arquivos
    # exatamente falharam (e por quê) sem ter prestado atenção em tempo real.
    #
    # O log é salvo DENTRO do próprio diretório de saída, com timestamp no
    # nome para não sobrescrever logs de execuções anteriores. Tudo que
    # aparece na tela (progresso, sucesso, falha) também é escrito no log,
    # usando a técnica de "tee" mais adiante nas mensagens — mas como
    # "tee" também herda o problema de subshell explicado no item da
    # correção do bug de contagem (e quebraria os contadores de novo se
    # usássemos um pipe aqui), em vez disso cada mensagem importante é
    # gravada no log de forma explícita, linha a linha, com uma função
    # auxiliar "log_e_tela()" que faz as duas coisas: imprime na tela E
    # grava no arquivo de log, sem depender de pipe.
    # ------------------------------------------------------------------
    arquivo_log="$diretorio/log_conversao_$(date +%Y%m%d_%H%M%S).txt"

    # ------------------------------------------------------------------
    # CORREÇÃO DE BUG REAL (portabilidade): "\x1b" trocado por caractere
    # ESC literal interpolado.
    # ------------------------------------------------------------------
    # Por que isso existe: a notação "\x1b" (escape hexadecimal) dentro de
    # uma expressão "sed" é uma extensão do GNU sed — não é reconhecida
    # por todo "sed". Isso foi confirmado testando em "busybox sed", onde
    # "s/\x1b\[[0-9;]*m//g" simplesmente não casava com nada, e os códigos
    # de cor ANSI continuavam intactos (e ilegíveis) no arquivo de log
    # final, derrotando o propósito de "log_e_tela()" descrito abaixo.
    #
    # A correção usa "$(printf '\033')" para gerar o caractere ESC real
    # (não a notação de escape, o BYTE em si) e interpola esse caractere
    # diretamente dentro da expressão regular do "sed". Isso funciona em
    # QUALQUER "sed" (GNU, BSD, busybox), porque nesse caso o "sed" está
    # recebendo um caractere literal para casar, não uma notação especial
    # que ele precisa interpretar.
    # ------------------------------------------------------------------
    esc_ansi=$(printf '\033')

    log_e_tela() {
        # "$1" é a mensagem JÁ FORMATADA com cores (para a tela). Gravamos
        # no log uma versão sem os códigos de cor ANSI, porque um arquivo
        # de texto aberto num editor comum mostraria os códigos de escape
        # como caracteres ilegíveis em vez de cor real. O "sed" abaixo
        # remove qualquer sequência de escape ANSI (ESC[...m) da mensagem
        # antes de gravar no arquivo, usando o caractere ESC literal
        # guardado em "$esc_ansi" (ver explicação completa acima).
        printf "%b\n" "$1"
        printf "%b\n" "$1" | sed "s/${esc_ansi}\[[0-9;]*m//g" >> "$arquivo_log"
    }

    # cabeçalho do log com informações da execução, para contexto futuro
    {
        printf "Log de conversão — %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf "Total de arquivos encontrados: %s\n" "$total"
        printf "Perfil de capa: %s | Perfil de áudio: %s\n" "$thumb_info" "$INFO_BR"
        printf "%s\n" "----------------------------------------"
    } >> "$arquivo_log"

    # IMPORTANTE: usamos redirecionamento de arquivo temporário (em vez de
    # 'printf ... | while read') porque um pipe coloca o 'while' num subshell
    # em sh/dash. Isso faria 'convertidos', 'pulados' e 'n' serem perdidos
    # ao final do loop (cada iteração teria sua própria cópia das variáveis).
    tmp_lista="/tmp/flac_lista_$$"
    printf "%s\n" "$lista" > "$tmp_lista"

    while IFS= read -r arquivo; do
        [ -z "$arquivo" ] && continue
        n=$((n + 1))

        # checagem CRÍTICA de espaço em disco, repetida a cada arquivo do
        # lote (diferente da checagem PREVENTIVA, feita uma única vez antes
        # do loop começar — ver a explicação completa na definição da
        # função verificar_espaco_disco() acima). Se o disco esgotar de
        # verdade no meio do processo, interrompemos o restante do lote
        # aqui, em vez de deixar cada arquivo subsequente falhar um a um
        # silenciosamente até o fim da lista.
        if ! verificar_espaco_disco "critico"; then
            log_e_tela "${vermelho}Lote interrompido em [$n/$total] por falta de espaço em disco.${reset}"
            break
        fi

        # ------------------------------------------------------------------
        # "arquivo" aqui já vem com o prefixo "./" (ver correção do %p em
        # menu_escopo, acima). Isso é necessário para proteger chamadas
        # como "basename" e "metaflac" de interpretarem mal um nome que
        # comece com hífen. Mas para CONSTRUIR O CAMINHO DE SAÍDA, esse
        # "./" sobrando é só ruído visual (ex: "saida/./musica.m4a" em vez
        # de "saida/musica.m4a" — funcionalmente idêntico para o sistema
        # de arquivos, mas feio de ler em logs e mensagens de progresso).
        # Por isso removemos o "./" aqui, só para fins de exibição e
        # construção de caminho, mantendo "$arquivo" original (com o
        # "./") para todas as chamadas de comando abaixo.
        # ------------------------------------------------------------------
        nome_base="${arquivo#./}"
        musica=$(basename "$arquivo")

        # ------------------------------------------------------------------
        # CORREÇÃO DE BUG REAL: remoção de extensão case-insensitive
        # ------------------------------------------------------------------
        # Por que isso existe: a busca de arquivos em menu_escopo() usa
        # "find -iname *.flac", que é case-insensitive — ou seja, encontra
        # tanto "musica.flac" quanto "MUSICA.FLAC" ou "Musica.Flac". Porém,
        # o operador POSIX "${variavel%.flac}" (remoção de sufixo) É
        # sensível a maiúsculas/minúsculas: ele só remove o sufixo se a
        # caixa bater exatamente. Sem esta correção, um arquivo chamado
        # "Faixa.FLAC" virava "Faixa.FLAC.m4a" em vez de "Faixa.m4a",
        # porque "${arquivo%.flac}" não reconhecia ".FLAC" como o sufixo
        # a ser removido, e mantinha a string inteira intacta antes de
        # colar a nova extensão. Isso foi reproduzido e confirmado em
        # teste antes desta correção.
        #
        # POSIX sh não tem um operador de remoção de sufixo "ignore-case"
        # nativo (isso existe em bash via nocasematch/shopt, mas não em sh
        # puro). A solução portátil é normalizar o NOME-BASE comparando
        # manualmente a extensão com um "case" — que em sh/dash, por
        # padrão, também é sensível a maiúsculas/minúsculas, mas permite
        # listar múltiplos padrões explicitamente no mesmo "case", o que
        # cobre as variações reais de caixa sem depender de nenhuma
        # extensão não-POSIX do shell.
        #
        # Cobrimos aqui as três variações de caixa realistas: tudo
        # minúsculo (".flac"), tudo maiúsculo (".FLAC", comum em rips
        # antigos de CD) e capitalizado (".Flac", raro mas possível em
        # renomeações manuais ou ferramentas específicas).
        # ------------------------------------------------------------------
        case "$nome_base" in
            *.flac) nome_base="${nome_base%.flac}" ;;
            *.FLAC) nome_base="${nome_base%.FLAC}" ;;
            *.Flac) nome_base="${nome_base%.Flac}" ;;
        esac

        outpath="$diretorio/${nome_base}.$EXTENSAO_SAIDA"

        if ! mkdir -p "$(dirname "$outpath")"; then
            log_e_tela "${vermelho}[$n/$total] Erro: não foi possível criar subpasta de destino para '$musica'. Pulando.${reset}"
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

        rm -f "$tmp_cover" "$tmp_cover_resized"
    done < "$tmp_lista"

    rm -f "$tmp_lista"

    printf "Log completo salvo em: ${azul}%s${reset}\n" "$arquivo_log"
}

# ==============================================================================
# EXECUÇÃO
# ==============================================================================
banner "Transcodificação FLAC -> ${EXTENSAO_SAIDA}"

# verifica dependências ANTES de qualquer menu — ver item 1, explicado
# em detalhe na definição da função verificar_dependencias() acima.
verificar_dependencias

detectar_imagemagick
menu_escopo
menu_qualidade
menu_thumb
menu_pular_existentes

loop_de_conversao

banner "Fim!"
printf "Convertidos: ${verde}${convertidos}${reset} | Pulados: ${vermelho}${pulados}${reset}\n"
