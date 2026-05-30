#!/bin/bash
#
# backup_mysql.sh — Backup automático do MySQL (Docker) + Upload S3
#
# Execução: ./backup_mysql.sh  (ou via crontab)
# Requer:   Docker rodando com o container "mysql" ativo.
#
# Decisão de Design — mysqldump:
#   Usamos mysqldump com --all-databases porque o MySQL hospeda múltiplos bancos de
#   dados (como 'gestao'). Usamos --single-transaction e --quick para garantir
#   que o backup seja feito sem bloquear as tabelas (ideal para InnoDB) e de forma
#   eficiente em termos de memória. Incluímos --routines e --triggers para capturar
#   procedimentos armazenados e gatilhos.
# ---------------------------------------------------------------------------

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 0. Configuração inicial
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
LOCK_FILE="/tmp/backup_mysql.lock"
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
BACKUP_FILE="${BACKUP_DIR}/db_backup_mysql_all_${TIMESTAMP}.sql.gz"
CHECKSUM_FILE="${BACKUP_FILE}.sha256"
START_TIME=$(date +%s)

# Cria o diretório de backups se não existir
mkdir -p "${BACKUP_DIR}"

# Protege os arquivos de backup: somente o dono pode ler/escrever
umask 077

# ---------------------------------------------------------------------------
# 1. Lockfile — impede execuções simultâneas (ex: cron sobreposto)
# ---------------------------------------------------------------------------

exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    echo "WARNING: Outra instância do backup do MySQL já está em execução. Abortando." >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# 1.5. Notificação via Telegram
# ---------------------------------------------------------------------------

send_telegram_notification() {
    local status="$1"
    local exit_val="${2:-0}"
    
    # Se as credenciais do Telegram não estiverem configuradas, ignora silenciosamente
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        return 0
    fi

    # Verifica se curl está instalado
    if ! command -v curl &>/dev/null; then
        echo "WARNING: curl não está instalado. Não foi possível enviar notificação para o Telegram." >&2
        return 0
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    local duration_str=""
    if [ ${minutes} -gt 0 ]; then
        duration_str="${minutes}m ${seconds}s"
    else
        duration_str="${seconds}s"
    fi

    local message=""
    if [ "${status}" = "SUCCESS" ]; then
        local file_size="N/A"
        if [ -f "${BACKUP_FILE}" ]; then
            file_size=$(du -sh "${BACKUP_FILE}" | cut -f1)
        fi
        local file_name
        file_name=$(basename "${BACKUP_FILE}")

        message="<b>✅ Backup do MySQL concluído com sucesso!</b>

<b>Servidor:</b> <code>oracle-host</code>
<b>Arquivo:</b> <code>${file_name}</code>
<b>Tamanho:</b> <code>${file_size}</code>
<b>Tempo decorrido:</b> <code>${duration_str}</code>
<b>Data:</b> <code>$(date +"%d/%m/%Y %H:%M:%S")</code>"
    else
        message="<b>❌ Falha no Backup do MySQL!</b>

<b>Servidor:</b> <code>oracle-host</code>
<b>Status:</b> Erro no script (código de saída: ${exit_val})
<b>Tempo decorrido:</b> <code>${duration_str}</code>
<b>Data:</b> <code>$(date +"%d/%m/%Y %H:%M:%S")</code>"
    fi

    echo "Enviando notificação para o Telegram..."
    
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${message}" || echo "000")

    if [ "${http_code}" -ne 200 ]; then
        echo "WARNING: Falha ao enviar notificação do Telegram (HTTP Status: ${http_code})" >&2
    else
        echo "Notificação enviada para o Telegram com sucesso."
    fi
}

# ---------------------------------------------------------------------------
# 2. Trap — limpeza automática em caso de erro ou interrupção
# ---------------------------------------------------------------------------

cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo "ERROR: Script encerrado com código ${exit_code}. Removendo backup parcial..." >&2
        send_telegram_notification "FAILURE" "${exit_code}"
        rm -f "${BACKUP_FILE}" "${CHECKSUM_FILE}"
    fi
    # Remove FIFO temporário caso exista (falha antes da limpeza normal)
    rm -f "${BACKUP_DIR}/.mysql_dump_pipe_"*
    exit ${exit_code}
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 3. Carrega variáveis do .env
# ---------------------------------------------------------------------------

if [ -f "${SCRIPT_DIR}/.env" ]; then
    # Lê linha a linha, ignora comentários e linhas vazias
    set +u  # Temporariamente desativa para evitar erro em variáveis com valor vazio
    while IFS='=' read -r key value; do
        # Remove aspas ao redor do valor, se existirem
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        export "${key}=${value}"
    done < <(grep -v '^\s*#' "${SCRIPT_DIR}/.env" | grep -v '^\s*$')
    set -u
else
    echo "WARNING: Arquivo .env não encontrado em ${SCRIPT_DIR}. Usando variáveis de ambiente do shell." >&2
fi

# Credenciais do MySQL lidas do .env (previsível e auditável)
DB_USER="root"
DB_PASS="${MYSQL_ROOT_PASSWORD:-}"

if [ -z "${DB_PASS}" ]; then
    echo "ERROR: MYSQL_ROOT_PASSWORD não definida no .env ou no ambiente!" >&2
    exit 1
fi

echo "=========================================="
echo "Iniciando Backup do MySQL ($(date))"
echo "=========================================="

# ---------------------------------------------------------------------------
# 4. Verifica se o container está rodando e saudável
# ---------------------------------------------------------------------------

if ! docker ps --format '{{.Names}}' | grep -q "^mysql$"; then
    echo "ERROR: O container 'mysql' não está em execução!" >&2
    exit 1
fi

# Espera o MySQL responder ao ping do mysqladmin (timeout: 30s)
echo "Verificando se o MySQL está pronto..."
for i in $(seq 1 6); do
    if docker exec -e MYSQL_PWD="${DB_PASS}" mysql mysqladmin ping -u "${DB_USER}" &>/dev/null; then
        break
    fi
    if [ "${i}" -eq 6 ]; then
        echo "ERROR: MySQL não ficou pronto após 30 segundos!" >&2
        exit 1
    fi
    sleep 5
done
echo "MySQL está pronto."

# ---------------------------------------------------------------------------
# 5. Executa mysqldump com captura confiável de erros no pipeline
# ---------------------------------------------------------------------------
#
# Problema do pipeline simples (mysqldump | gzip):
#   Com pipefail, qualquer falha no mysqldump propaga corretamente.
#   Porém, para ter uma mensagem de erro clara e separar os exit codes,
#   usamos um FIFO (named pipe) para desacoplar os processos.
# ---------------------------------------------------------------------------

echo "Executando dump de todos os bancos..."

FIFO_PATH="${BACKUP_DIR}/.mysql_dump_pipe_${TIMESTAMP}"
mkfifo "${FIFO_PATH}"

# Inicia o gzip em background lendo do FIFO
gzip < "${FIFO_PATH}" > "${BACKUP_FILE}" &
GZIP_PID=$!

# Executa o mysqldump escrevendo no FIFO e captura o exit code
DUMP_EXIT=0
docker exec -e MYSQL_PWD="${DB_PASS}" mysql \
    mysqldump -u "${DB_USER}" \
    --all-databases \
    --single-transaction \
    --quick \
    --routines \
    --triggers > "${FIFO_PATH}" || DUMP_EXIT=$?

# Aguarda o gzip finalizar e captura seu exit code
wait ${GZIP_PID} || true
GZIP_EXIT=$?

# Remove o FIFO temporário
rm -f "${FIFO_PATH}"

# Avalia os resultados
if [ ${DUMP_EXIT} -ne 0 ]; then
    echo "ERROR: mysqldump falhou com código ${DUMP_EXIT}!" >&2
    exit 1
fi

if [ ${GZIP_EXIT} -ne 0 ]; then
    echo "ERROR: gzip falhou com código ${GZIP_EXIT}!" >&2
    exit 1
fi

if [ ! -s "${BACKUP_FILE}" ]; then
    echo "ERROR: Arquivo de backup está vazio!" >&2
    exit 1
fi

echo "Backup concluído com sucesso!"
echo "  Arquivo: ${BACKUP_FILE}"
echo "  Tamanho: $(du -sh "${BACKUP_FILE}" | cut -f1)"

# ---------------------------------------------------------------------------
# 6. Gera checksum SHA256 para validação futura de integridade
# ---------------------------------------------------------------------------

echo "Gerando checksum SHA256..."
sha256sum "${BACKUP_FILE}" > "${CHECKSUM_FILE}"
echo "  Checksum: $(cat "${CHECKSUM_FILE}")"

# ---------------------------------------------------------------------------
# 7. Upload para AWS S3 (via container Docker — ARM64 compatível)
# ---------------------------------------------------------------------------

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
AWS_STORAGE_BUCKET_NAME="${AWS_STORAGE_BUCKET_NAME:-}"

if [ -n "${AWS_ACCESS_KEY_ID}" ] && [ -n "${AWS_SECRET_ACCESS_KEY}" ] && [ -n "${AWS_STORAGE_BUCKET_NAME}" ]; then
    BACKUP_FILENAME="$(basename "${BACKUP_FILE}")"
    CHECKSUM_FILENAME="$(basename "${CHECKSUM_FILE}")"
    S3_PREFIX="s3://${AWS_STORAGE_BUCKET_NAME}/backups"

    echo "Enviando backup para AWS S3 (Bucket: ${AWS_STORAGE_BUCKET_NAME})..."

    if docker run --rm \
        --read-only \
        -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        -e AWS_DEFAULT_REGION="${AWS_S3_REGION_NAME:-us-east-1}" \
        -v "${BACKUP_DIR}:/backups:ro" \
        amazon/aws-cli:latest s3 cp "/backups/${BACKUP_FILENAME}" "${S3_PREFIX}/${BACKUP_FILENAME}"; then

        echo "Upload do backup para S3 concluído com sucesso!"
    else
        echo "WARNING: Falha ao enviar o backup para o S3!" >&2
    fi

    # Envia também o checksum para o S3
    if docker run --rm \
        --read-only \
        -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        -e AWS_DEFAULT_REGION="${AWS_S3_REGION_NAME:-us-east-1}" \
        -v "${BACKUP_DIR}:/backups:ro" \
        amazon/aws-cli:latest s3 cp "/backups/${CHECKSUM_FILENAME}" "${S3_PREFIX}/${CHECKSUM_FILENAME}"; then

        echo "Upload do checksum para S3 concluído com sucesso!"
    else
        echo "WARNING: Falha ao enviar o checksum para o S3!" >&2
    fi
else
    echo "Credenciais AWS S3 não configuradas no .env. Upload para nuvem ignorado."
fi

# ---------------------------------------------------------------------------
# 8. Limpeza local — remove backups e checksums com mais de 7 dias
# ---------------------------------------------------------------------------

echo "Limpando backups locais com mais de 7 dias..."
DELETED_COUNT=$(find "${BACKUP_DIR}" -type f \( -name "db_backup_mysql_all_*.sql.gz" -o -name "db_backup_mysql_all_*.sql.gz.sha256" \) -mtime +7 -print -delete | wc -l)
echo "  ${DELETED_COUNT} arquivo(s) antigo(s) removido(s)."

# ---------------------------------------------------------------------------
# 9. Resumo final
# ---------------------------------------------------------------------------

echo "=========================================="
echo "Backup finalizado com sucesso em $(date)"
echo "=========================================="

send_telegram_notification "SUCCESS"
