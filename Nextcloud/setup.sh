#!/bin/bash

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Nextcloud Docker Setup ===${NC}"

# Проверка наличия файла с настройками
CONFIG_FILE="config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Файл $CONFIG_FILE не найден!${NC}"
    echo -e "${YELLOW}Создаю шаблон файла конфигурации...${NC}"
    
    cat > "$CONFIG_FILE" << EOF
# Настройки доменов
NEXTCLOUD_DOMAIN="nextcloud.yourdomain.com"
TRAEFIK_DOMAIN="traefik.yourdomain.com"

# Email для Let's Encrypt
LETSENCRYPT_EMAIL="your-email@example.com"

# Пароли (сгенерируйте сильные пароли!)
MYSQL_ROOT_PASSWORD="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
MYSQL_PASSWORD="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
REDIS_PASSWORD="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
NEXTCLOUD_ADMIN_PASSWORD="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"


# Имя администратора Nextcloud
NEXTCLOUD_ADMIN_USER="admin"

# Настройки производительности
PHP_MEMORY_LIMIT="1024M"
PHP_UPLOAD_LIMIT="10G"
MYSQL_BUFFER_POOL="512M"
EOF
    
    echo -e "${YELLOW}Файл $CONFIG_FILE создан с шаблонными значениями.${NC}"
    echo -e "${YELLOW}Отредактируйте его и запустите скрипт снова.${NC}"
    echo -e "${RED}ВАЖНО: Обязательно измените домены, email и пароли!${NC}"
    exit 1
fi

# Загрузка конфигурации
echo -e "${GREEN}Загружаю конфигурацию из $CONFIG_FILE...${NC}"
source "$CONFIG_FILE"

# Проверка обязательных переменных
required_vars=(
    "NEXTCLOUD_DOMAIN"
    "TRAEFIK_DOMAIN" 
    "LETSENCRYPT_EMAIL"
    "MYSQL_ROOT_PASSWORD"
    "MYSQL_PASSWORD"
    "REDIS_PASSWORD"
    "NEXTCLOUD_ADMIN_PASSWORD"
)

echo -e "${GREEN}Проверяю обязательные переменные...${NC}"
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Ошибка: переменная $var не задана в $CONFIG_FILE${NC}"
        exit 1
    fi
done

# Проверка доменов
if [[ "$NEXTCLOUD_DOMAIN" == *"yourdomain.com"* ]] || [[ "$LETSENCRYPT_EMAIL" == *"example.com"* ]]; then
    echo -e "${RED}Ошибка: Необходимо изменить домены и email в $CONFIG_FILE${NC}"
    exit 1
fi

echo -e "${GREEN}Создаю структуру директорий...${NC}"
mkdir -p nextcloud-config db-config backups

echo -e "${GREEN}Создаю docker-compose.yml...${NC}"
cat > docker-compose.yml << EOF
version: '3.8'

services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"  # Traefik dashboard
    command:
      - --api.dashboard=true
      - --api.insecure=true
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencrypt.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/acme.json
      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
      # Redirect HTTP to HTTPS
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./acme.json:/acme.json
    networks:
      - traefik
      - nextcloud
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\`${TRAEFIK_DOMAIN}\`)"
      - "traefik.http.routers.traefik.tls.certresolver=letsencrypt"

  db:
    image: mariadb:10.11
    container_name: nextcloud-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW
    volumes:
      - db:/var/lib/mysql
      - ./db-config/my.cnf:/etc/mysql/conf.d/my.cnf:ro
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MARIADB_AUTO_UPGRADE=1
      - MARIADB_DISABLE_UPGRADE_BACKUP=1
    networks:
      - nextcloud

  redis:
    image: redis:7-alpine
    container_name: nextcloud-redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD}
    networks:
      - nextcloud

  app:
    image: nextcloud:29.0.16-apache
    container_name: nextcloud-app
    restart: unless-stopped
    volumes:
      - nextcloud:/var/www/html
      - ./nextcloud-config/php.ini:/usr/local/etc/php/php.ini:ro
    environment:
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_HOST=db
      - REDIS_HOST=redis
      - REDIS_HOST_PASSWORD=${REDIS_PASSWORD}
      - NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER:-admin}
      - NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=${NEXTCLOUD_DOMAIN}
      - OVERWRITEPROTOCOL=https
      - OVERWRITEHOST=${NEXTCLOUD_DOMAIN}
      - APACHE_DISABLE_REWRITE_IP=1
      - TRUSTED_PROXIES=traefik
    depends_on:
      - db
      - redis
    networks:
      - nextcloud
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nextcloud.rule=Host(\`${NEXTCLOUD_DOMAIN}\`)"
      - "traefik.http.routers.nextcloud.tls.certresolver=letsencrypt"
      - "traefik.http.routers.nextcloud.middlewares=nextcloud-headers,nextcloud-redirectregex"
      - "traefik.http.middlewares.nextcloud-headers.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.middlewares.nextcloud-headers.headers.referrerPolicy=no-referrer"
      - "traefik.http.middlewares.nextcloud-headers.headers.stsSeconds=31536000"
      - "traefik.http.middlewares.nextcloud-headers.headers.stsIncludeSubdomains=true"
      - "traefik.http.middlewares.nextcloud-headers.headers.stsPreload=true"
      - "traefik.http.middlewares.nextcloud-headers.headers.customFrameOptionsValue=SAMEORIGIN"
      - "traefik.http.middlewares.nextcloud-redirectregex.redirectregex.permanent=true"
      - "traefik.http.middlewares.nextcloud-redirectregex.redirectregex.regex=^https://(.*)/.well-known/(card|cal)dav"
      - "traefik.http.middlewares.nextcloud-redirectregex.redirectregex.replacement=https://\$\${1}/remote.php/dav/"

  cron:
    image: nextcloud:29.0.16-apache
    container_name: nextcloud-cron
    restart: unless-stopped
    volumes:
      - nextcloud:/var/www/html
    entrypoint: /cron.sh
    depends_on:
      - db
      - redis
    networks:
      - nextcloud

  # Сервис для резервного копирования
  backup:
    image: mariadb:10.11
    container_name: nextcloud-backup
    restart: "no"
    volumes:
      - db:/var/lib/mysql:ro
      - nextcloud:/var/www/html:ro
      - ./backups:/backups
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
    entrypoint: |
      bash -c '
      set -e
      echo "Starting backup at \$\$(date)"
      mysqldump -h db -u root -p\$\$MYSQL_ROOT_PASSWORD nextcloud > /backups/nextcloud-\$\$(date +%Y%m%d_%H%M%S).sql
      tar -czf /backups/nextcloud-files-\$\$(date +%Y%m%d_%H%M%S).tar.gz -C /var/www/html .
      echo "Backup completed at \$\$(date)"
      '
    networks:
      - nextcloud

volumes:
  nextcloud:
  db:

networks:
  traefik:
    external: false
  nextcloud:
    external: false
EOF

echo -e "${GREEN}Создаю конфигурационные файлы...${NC}"

# PHP конфигурация
cat > nextcloud-config/php.ini << EOF
memory_limit = ${PHP_MEMORY_LIMIT:-1024M}
upload_max_filesize = ${PHP_UPLOAD_LIMIT:-10G}
post_max_size = ${PHP_UPLOAD_LIMIT:-10G}
max_execution_time = 3600
max_input_time = 3600
output_buffering = 0
opcache.enable = 1
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 128
opcache.save_comments = 1
opcache.revalidate_freq = 1
EOF

# MariaDB конфигурация
cat > db-config/my.cnf << EOF
[mysqld]
skip-name-resolve
innodb_buffer_pool_size = ${MYSQL_BUFFER_POOL:-512M}
innodb_buffer_pool_instances = 1
innodb_flush_log_at_trx_commit = 2
innodb_log_buffer_size = 32M
innodb_max_dirty_pages_pct = 90
query_cache_type = 1
query_cache_limit = 2M
query_cache_size = 64M
tmp_table_size = 64M
max_heap_table_size = 64M
slow_query_log = 1
slow_query_log_file = /var/lib/mysql/slow.log
long_query_time = 1
max_connections = 100
EOF

# Создание .gitignore
cat > .gitignore << 'EOF'
# Файлы с паролями и конфигурацией
config.env

# Docker данные
docker-compose.yml

# Резервные копии
backups/

# Системные файлы
.DS_Store
Thumbs.db

# Логи
*.log
EOF

# Установка прав доступа
chmod 600 nextcloud-config/php.ini db-config/my.cnf
chmod 755 backups

# Создание файла acme.json с правильными правами
touch acme.json
chmod 600 acme.json

echo -e "${GREEN}=== Настройка завершена! ===${NC}"
echo ""
echo -e "${GREEN}Создано:${NC}"
echo -e "  ✓ docker-compose.yml"
echo -e "  ✓ nextcloud-config/php.ini" 
echo -e "  ✓ db-config/my.cnf"
echo -e "  ✓ .gitignore"
echo ""
echo -e "${GREEN}Настройки:${NC}"
echo -e "  🌐 Nextcloud: https://$NEXTCLOUD_DOMAIN"
echo -e "  🔧 Traefik: http://$TRAEFIK_DOMAIN:8080"
echo -e "  👤 Админ: $NEXTCLOUD_ADMIN_USER"
echo ""
echo -e "${YELLOW}Для запуска выполните:${NC}"
echo -e "  docker-compose up -d"
echo ""
echo -e "${YELLOW}Для мониторинга:${NC}"
echo -e "  docker-compose logs -f"
echo ""
echo -e "${RED}ВАЖНО:${NC}"
echo -e "  • Файл config.env добавлен в .gitignore"
echo -e "  • docker-compose.yml добавлен в .gitignore (будет генерироваться)"
echo -e "  • Убедитесь что DNS записи настроены правильно"
