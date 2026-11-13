#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ ${1:-} != @ ]] || shift
[[ ${1:-} != install ]] || shift
directory=$(mktemp -d /tmp/remnacust-install.XXXXXXXX)
trap '[[ $directory == /tmp/remnacust-install.* ]] && rm -rf -- "$directory"' EXIT
cat > "$directory/installer.sh" <<'REMNACUST_INSTALLER_PAYLOAD_V1'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1
HELPER_BUNDLE_SHA256='7bfdff97af4a4b8a2ecc6a4016a36fc590b1b52c7eb8deaa80df649b47fbb507'
ENTRY_SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"
HELPER_ROOT='' HELPER_ENTRY='' INSTALLED_HELPER_ROOT=''

REPO=${REMNACUST_REPOSITORY:-lottman/Remnacust-installer}
ROOT=${REMNACUST_ROOT:-/opt/remnacust}
export REMNACUST_ROOT="$ROOT"
ACTION='' VERSION='' COMPONENT='' DIRECTORY='' COMPOSE_FILE='' CONTAINER=''
PAGE_ID='' PAGE_OPERATION='' PAGE_PANEL_URL='' PAGE_TOKEN_FILE=''
DOMAIN_PLAN=''
PROJECT='' DOMAIN=${REMNACUST_PANEL_DOMAIN:-} NODE_DOMAIN='' EMAIL='' PANEL_IP=''
SUBSCRIPTION_URLS=${REMNACUST_SUBSCRIPTION_URLS:-} SUBSCRIPTION_SET=false
SUBSCRIPTION_PAGE=false SUBSCRIPTION_PAGE_SET=false SUBSCRIPTION_PORT=3010 SUBSCRIPTION_IMAGE='' SUBSCRIPTION_IMAGE_VERSION=''
PANEL_NET_ADMIN=false PANEL_NET_ADMIN_SET=false
PANEL_IPV6_MODE=auto PANEL_IPV6_MODE_SET=false
NODE_NET_ADMIN=false
NODE_NET_ADMIN_ADDED=false
NODE_DOMAIN_CONFIRMED=''
NODE_SITE_MODE='' NODE_SITE_PORT='' NODE_INBOUND_PORT=''
NODE_MIGRATION_TLS=false
ALLOW_DISRUPTION=false
PORT='' PROXY=caddy PROXY_SET=false TLS_METHOD='' CERT_FILE='' KEY_FILE='' DNS_CREDENTIALS='' ACME_ROOT='' CERTBOT='' YES=false WORK='' SOURCE='' HELPER='' LOG=''
STATE='' DEPLOY='' CHANGED=false BACKUP='' IMAGE='' TAG='' COMPONENT_VERSION=''
DB_CHANGED=false MARZBAN_URL='' DESTINATION_URL='' INTERNAL_SQUAD='' DRY_RUN=false
REINSTALL_RECORD=''
SERVER_IPS='' HTTPS_TIMEOUT=180
QUOTA_MODE=remaining PRESERVE_SUBHASH=false
declare -a FILES=() APPS=() START_APPS=() RUNNING_APPS=() EXTRAS=()
TEAL='' PURPLE='' ROSE='' DIM='' GRAY='' RESET=''
BOLD='' ACCENT=''
OPERATION_LOG_PID='' OPERATION_STDERR='' OPERATION_STARTED=0 OPERATION_LOG_ACTIVE=false
Y_LABEL=y N_LABEL=n
if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
    TEAL=$'\033[38;2;25;190;160m'; PURPLE=$'\033[38;2;167;139;250m'
    ROSE=$'\033[38;2;239;128;153m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    Y_LABEL=$'\033[1;32my\033[0m'; N_LABEL=$'\033[1;31mn\033[0m'
    BOLD=$'\033[1m'
    ACCENT=$'\033[38;2;231;111;122m'
    GRAY=$'\033[38;2;128;132;142m'
    PURPLE=$ACCENT
fi
info() { printf '%s  %s%s\n' "$TEAL" "$*" "$RESET"; operation_log_event INFO "$*"; }
die() { printf '%s  Ошибка: %s%s\n' "$ROSE" "$*" "$RESET" >&2; exit 1; }
ask() { local value display_default=${3:-${2:-}}; [[ -t 0 ]] || die "Задайте параметр: $1"; IFS= read -r -p "$1${2:+ [$display_default]}: " value || return 1; value=$(trim_answer "$value"); printf '%s' "${value:-${2:-}}"; }
ask_required() {
    local value
    while true; do
        value=$(ask "$1") || return $?
        if [[ -n $value ]]; then printf '%s' "$value"; return 0; fi
        printf '  ! пустой ответ, повторите ввод\n' >&2
    done
}
ask_node_secret() {
    [[ -t 0 ]] || die 'Задайте REMNACUST_NODE_SECRET или введите ключ интерактивно'
    REMNACUST_NODE_SECRET=$(ask_required 'SECRET_KEY из панели') || return 1
    export REMNACUST_NODE_SECRET
}
trim_answer() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}
discard_pending_input() {
    [[ -t 0 ]] || return 0
    if command -v python3 >/dev/null; then
        python3 -c 'import sys,termios; termios.tcflush(sys.stdin.fileno(),termios.TCIFLUSH)' 2>/dev/null || true
    else
        local discarded attempt
        for ((attempt=0; attempt<64; attempt++)); do IFS= read -r -t .01 -N 4096 discarded || break; done
    fi
}
ask_yes_no() {
    local answer default=${2:-n} display_default=$N_LABEL
    [[ $default == y || $default == n ]] || die 'Некорректный ответ по умолчанию'
    [[ $default != y ]] || display_default=$Y_LABEL
    while true; do
        answer=$(ask "$1 $Y_LABEL/$N_LABEL" "$default" "$display_default") || return $?
        answer=$(trim_answer "$answer")
        [[ -n $answer ]] || answer=$default
        # Literal Cyrillic alternatives also work with the byte-oriented C locale.
        case "${answer,,}" in
            y|yes|д|Д|да|Да|дА|ДА) printf yes; return 0;;
            n|no|н|Н|нет|Нет|нЕт|неТ|НЕт|НеТ|нЕТ|НЕТ) printf no; return 0;;
            *) printf '  Введите %s/%s.\n' "$Y_LABEL" "$N_LABEL" >&2; discard_pending_input;;
        esac
    done
}
ask_confirmed_domain() {
    local title=$1 value=${2:-} answer
    while true; do
        [[ -n $value ]] || value=$(ask_required "$title") || return $?
        value=$(trim_answer "$value")
        if ! helper validate --domain "$value" >/dev/null; then
            [[ -t 0 ]] && ! $YES || return 1
            value=''; continue
        fi
        if [[ -t 0 ]] && ! $YES; then
            answer=$(ask_yes_no "Использовать домен $value?" y) || return $?
            if [[ $answer != yes ]]; then value=''; continue; fi
        fi
        printf '%s' "${value,,}"; return 0
    done
}
ask_menu_choice() {
    local answer maximum=$1
    while true; do
        answer=$(ask 'Действие') || return $?
        answer=$(trim_answer "$answer")
        if [[ $answer =~ ^[0-9]{1,2}$ ]] && ((10#$answer<=maximum)); then printf '%s' "$((10#$answer))"; return 0; fi
        printf '  Выберите номер от 0 до %s.\n' "$maximum" >&2
        discard_pending_input
    done
}
valid_version() { [[ $1 == latest || $1 =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]]; }
download() { curl --fail --show-error --silent --location --retry 3 --connect-timeout 15 --max-time 600 --proto '=https' --proto-redir '=https' --tlsv1.2 "$1" -o "$2"; }
usage() {
    cat <<'HELP'
Remnacust · installer.sh
  sudo bash installer.sh
  sudo bash installer.sh COMMAND [--version latest|1.2.24] [--yes]

  install-panel             Установить панель: Docker, БД, кеш, HTTPS
  normalize-layout          Постоянный каталог панели/ноды (--component panel|node)
  cleanup-backups           Убрать старые копии конфигов в backups (все компоненты)
  install-subscription-page Установить страницу подписки
  upgrade-subscription-page Обновить выбранную страницу подписки
  manage-subscription-page  Список, запуск, остановка или перезапуск страниц
  configure-subscription-page Сменить панель и API-токен выбранной страницы
  manage-panel | manage-node Меню управления установленной панелью или нодой
  change-domain             Сменить домен --component panel|node|subscription-page
  show-config               Показать адреса и пути настроек без секретов
  install-node              Установить ноду и Xray; TLS/XHTTP по желанию
  upgrade-panel             Все процессы панели; БД и настройки сохраняются
  upgrade-node              Полное обновление ноды и встроенного Xray
  uninstall-panel           Удалить контейнеры панели; сохранить данные и копии
  uninstall-node            Удалить контейнеры ноды; сохранить конфигурацию
  uninstall-subscription-page Удалить выбранную страницу; сохранить настройки и данные
  migrate-remnawave-panel    Переход существующей панели на Remnacust
  migrate-remnawave-node     Переход существующей ноды на Remnacust
  migrate-remnawave-subscription-page Перенос страницы подписки с сохранением настроек
  migrate-marzban-panel      Перенос пользователей Marzban через API
  --check-release           Скачать и проверить выпуск без установки
  status                    Состояние установленных компонентов
  check-panel               Проверить DNS и HTTPS без изменения установки
  logs                      Журнал приложения, последние 100 строк
  start | stop | restart    Управление процессами приложения
  backup-panel              Копия БД и конфигурации панели
  restore-panel             Данные и ключи из копии; текущая версия сохраняется
  renew-node-certificate    Копирование обновлённого TLS и перезапуск ноды
  configure-node-site       Случайный новый сайт selfsteal; прежний сохраняется в копии
  renew-panel-certificate   Копирование обновлённого TLS и reload Caddy
  --help, -h                Эта справка

  --page-id ID              ID зарегистрированной страницы (из списка)
  --page-operation ACTION   list, status, logs, start, stop или restart
  --panel-url URL           HTTPS панели; auto для панели на этом сервере
  --panel-token-file FILE   Файл API-токена страницы с правами 0600
  --component COMPONENT    panel, node или subscription-page для управления
  --directory PATH          Каталог существующей установки
  --compose-file PATH       Основной Compose-файл при миграции
  --panel-ipv6 MODE         IPv6 egress панели: auto (по умолчанию), on или off
  --container NAME          Контейнер приложения при миграции
  --project-name NAME       Имя новой установки Compose
  --domain DOMAIN           Домен установки / новый домен для change-domain
  --net-admin               Добавить NET_ADMIN новой панели или устанавливаемой/обновляемой ноде
  --node-site-mode          standalone (отдельный HTTPS) или selfsteal (сокет за Xray)
  --node-site-port          Порт отдельного HTTPS-сайта (по умолчанию 443)
  --node-inbound-port       Порт входа Xray для настройки профиля панели (по умолчанию 8443)
  --no-net-admin            Новая панель/нода без NET_ADMIN; при обновлении включённое право сохраняется
  --subscription-urls URLS  Один или два адреса сайта подписки через запятую; первый — основной
  --subscription-page       Установить сайт подписки / перенести найденный при миграции
  --no-subscription-page    Не устанавливать / не переносить существующий сайт подписки
  --subscription-port PORT Порт сайта на loopback для вашего reverse proxy (3010)
  --server-ip IP[,IP]        Публичные IP сервера для проверки A/AAAA (NAT)
  --port PORT               Порт панели на loopback / API ноды
  --proxy caddy|existing    Новый Caddy (по умолчанию) / собственный proxy
  --node-domain DOMAIN      TLS и Nginx для XHTTP/self-steal при установке или переносе ноды
  --email EMAIL             Email для регистрации ACME (панель и нода)
  --tls-method METHOD       auto (Caddy), http (нода), cloudflare, gcore, existing
  --cert-file PATH          Готовый fullchain.pem для --tls-method existing
  --key-file PATH           Его приватный ключ privkey.pem
  --dns-credentials PATH    Закрытый INI-файл выбранного DNS-провайдера
  --panel-ip IP[/CIDR]      Все входящие порты и ping только от панели, кроме SSH
  --backup PATH             Каталог копии для restore-panel
  --yes                     Пропустить подтверждение выбранного действия
  --allow-disruption        upgrade-panel: пропустить диагностику автономности нод
  --source-url URL          Адрес Marzban для переноса
  --destination-url URL     Адрес уже установленной панели Remnacust
  --internal-squad UUID     Внутренний сквад для перенесённых пользователей
  --quota-mode remaining|total  Остаток квоты / полная квота (см. README)
  --dry-run                 Отчёт Marzban без записи пользователей
  --preserve-subhash        Перенос короткого токена подписки, если совместим

Версия запрашивается перед установкой/обновлением/миграцией; Enter = latest.
Подтверждение: y/n; Enter = n. Регистр и пробелы не важны.
Перед действиями CLI: apt update -y и apt upgrade -y (кроме проверки выпуска и фонового обновления панели).
Продолжение APT подтверждается автоматически. На вопросы настройки пакетов отвечайте в SSH-терминале.
Без терминала изменение пакетов требует SSH; --yes не выбирает настройки пакетов.
Справка, меню, выход и --dry-run пакеты не изменяют. Автоматической перезагрузки сервера нет.
После удаления доступна только новая установка через install-panel/install-node.
Установка и обновление: Ubuntu 22.04 / 24.04 / 26.04 LTS, Debian 12 / 13; amd64 / arm64.
SECRET_KEY виден при вводе или задаётся через REMNACUST_NODE_SECRET. В журналы он не записывается.
Существующие APP_SECRET, SECRET_KEY, БД, сети и тома не пересоздаются.
Если панель подключена к нескольким сетям Docker, сеть БД выбирается по DATABASE_URL и работающему контейнеру базы. Для внешней БД без Docker-алиаса укажите REMNACUST_DATABASE_NETWORK; сеть должна быть подключена к панели.
Новая панель: REMNACUST_BACKUP_PASSWORD задаёт пароль копий (16–256 ASCII без пробелов).
Без него установщик спрашивает пароль; Enter или запуск без терминала создаёт его.
Пароль сохраняется в закрытом backup-password.txt и показывается после установки.
HELP
}
show_menu() {
    local panel_note='' node_note='' panel_upgrade='Не установлена' node_upgrade='Не установлена' page_upgrade='Не установлена'
    local panel_available=false node_available=false page_available=false panel_install=true node_install=true service_available=false service_note='Компоненты не установлены'
    if component_installed panel; then panel_available=true; panel_install=false; panel_note='Уже установлена. Обновить: пункт 4; удалить: пункт 15.'; panel_upgrade=''; fi
    if component_installed node; then node_available=true; node_install=false; node_note='Уже установлена. Обновить: пункт 5; удалить: пункт 16.'; node_upgrade=''; fi
    if subscription_page_installed; then page_available=true; page_upgrade=''; fi
    if $panel_available || $node_available || $page_available; then service_available=true; service_note=''; fi
    terminal_banner
    terminal_server_card
    terminal_section 'Установка'
    terminal_action 1 'Установить панель' install-panel "$panel_note" "$panel_install"
    terminal_action 2 'Установить ноду и Xray' install-node "$node_note" "$node_install"
    terminal_action 3 'Установить страницу подписки' install-subscription-page
    terminal_section 'Обновление'
    terminal_action 4 'Обновить панель' upgrade-panel "$panel_upgrade" "$panel_available"
    terminal_action 5 'Обновить ноду и Xray' upgrade-node "$node_upgrade" "$node_available"
    terminal_action 6 'Обновить страницу подписки' upgrade-subscription-page "$page_upgrade" "$page_available"
    terminal_section 'Перенос'
    terminal_action 7 'Панель из Remnawave' migrate-remnawave-panel
    terminal_action 8 'Нода из Remnawave' migrate-remnawave-node
    terminal_action 9 'Пользователи из Marzban' migrate-marzban-panel
    terminal_action 10 'Страница подписки из Remnawave' migrate-remnawave-subscription-page
    terminal_section 'Обслуживание'
    terminal_action 11 'Проверить выпуск' --check-release
    terminal_action 12 'Состояние компонентов' status
    terminal_action 13 'Управление компонентами' ''
    terminal_action 14 'Логи, запуск и резервные копии' '' "$service_note" "$service_available"
    terminal_section 'Удаление'
    terminal_text 'Данные, тома, настройки и резервные копии сохраняются.' '      ' '      ' "$DIM"
    terminal_action 15 'Удалить панель' uninstall-panel "$panel_upgrade" "$panel_available"
    terminal_action 16 'Удалить ноду' uninstall-node "$node_upgrade" "$node_available"
    terminal_action 17 'Удалить страницу подписки' uninstall-subscription-page "$page_upgrade" "$page_available"
    terminal_rule
    terminal_action 0 Выход ''
    printf '\n'
}
terminal_width() {
    local width=${COLUMNS:-}
    [[ $width =~ ^[0-9]{1,3}$ ]] || width=$(tput cols 2>/dev/null || printf 80)
    [[ $width =~ ^[0-9]{1,3}$ ]] || width=80
    ((width < 24)) && width=24
    ((width > 88)) && width=88
    printf '%s' "$width"
}
terminal_rule() {
    local width; width=$(terminal_width)
    printf '  %s' "$DIM"
    printf '%*s' "$((width-4))" '' | tr ' ' '-'
    printf '%s\n' "$RESET"
}
terminal_section() {
    printf '\n'
    terminal_text "$1" '  ' '  ' "$BOLD"
    terminal_rule
}
terminal_banner() {
    printf '\n  %s▂▄▆█▆▄▂%s  %sREMNACUST%s\n' "$ACCENT" "$RESET" "$BOLD" "$RESET"
    terminal_text 'Установка и обслуживание' '  ' '  ' "$DIM"
}
terminal_text() {
    local LC_ALL=C.UTF-8
    local text prefix=${2:-'  '} continuation=${3:-${2:-'  '}} color=${4:-} width available line
    text=$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')
    width=$(terminal_width)
    while [[ -n $text ]]; do
        available=$((width-${#prefix}))
        ((available > 0)) || available=1
        if ((${#text} > available)); then
            line=${text:0:available}
            if [[ $line == *' '* ]]; then line=${line% *}; fi
        else line=$text; fi
        printf '%s%s%s%s\n' "$prefix" "$color" "$line" "$RESET"
        text=${text:${#line}}
        text=${text#"${text%%[![:space:]]*}"}
        prefix=$continuation
    done
}
terminal_value() {
    local LC_ALL=C.UTF-8
    local padding prefix
    if (($(terminal_width) >= 64)); then
        padding=$((14-${#1})); ((padding > 0)) || padding=1
        printf -v prefix '  %s%*s' "$1" "$padding" ''
        terminal_text "$2" "$prefix" '                ' "$BOLD"
    else
        terminal_text "$1: $2" '  ' '    '
    fi
}
terminal_server_card() {
    local system='Linux' memory='—' available='—' panel='не установлена' node='не установлена'
    [[ ! -r /etc/os-release ]] || system=$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release)
    [[ ! -r /proc/meminfo ]] || read -r memory available < <(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {available=$2} END {printf "%.1f %.1f\n",total/1048576,available/1048576}' /proc/meminfo)
    component_installed panel && panel='установлена'
    component_installed node && node='установлена'
    printf '\n'
    terminal_value 'Система' "$system"
    terminal_value 'Архитектура' "$(uname -m) · $(uname -r)"
    terminal_value 'Память' "$memory GiB · доступно $available GiB"
    terminal_value 'Панель' "$panel"
    terminal_value 'Нода' "$node"
}
terminal_action() {
    local LC_ALL=C.UTF-8
    local number=$1 title=$2 command=${3:-} note=${4:-} available=${5:-true} number_color=$ACCENT padding width first remaining command_prefix='      '
    [[ $available != false ]] || number_color=$GRAY
    width=$(terminal_width)
    if ((width >= 74)); then
        padding=$((30-${#title})); ((padding > 0)) || padding=1
        printf '  %s%2s%s  %s%s%s' "$number_color" "$number" "$RESET" "$BOLD" "$title" "$RESET"
        [[ -z $command ]] || printf '%*s%s%s%s' "$padding" '' "$DIM" "$command" "$RESET"
        printf '\n'
    else
        first=$title
        if ((${#title} > width-6)); then
            first=${title:0:width-6}
            [[ $first != *' '* ]] || first=${first% *}
        fi
        printf '  %s%2s%s  %s%s%s\n' "$number_color" "$number" "$RESET" "$BOLD" "$first" "$RESET"
        remaining=${title:${#first}}; remaining=${remaining#"${remaining%%[![:space:]]*}"}
        [[ -z $remaining ]] || terminal_text "$remaining" '      ' '      ' "$BOLD"
        ((width >= 32)) || command_prefix='  '
        [[ -z $command ]] || terminal_text "$command" "$command_prefix" "$command_prefix" "$DIM"
    fi
    [[ -z $note ]] || terminal_text "$note" '      ' '      ' "$DIM"
}
parse_args() {
    while (($#)); do
        case "$1" in
            manage-panel|manage-node|configure-node-site|change-domain|show-config|install-subscription-page|upgrade-subscription-page|uninstall-subscription-page|manage-subscription-page|configure-subscription-page|normalize-layout|cleanup-backups|install-panel|install-node|upgrade-panel|upgrade-node|uninstall-panel|uninstall-node|migrate-remnawave-panel|migrate-remnawave-node|migrate-remnawave-subscription-page|migrate-marzban-panel|--check-release|status|check-panel|logs|start|stop|restart|backup-panel|restore-panel|renew-node-certificate|renew-panel-certificate)
                [[ -z $ACTION ]] || die 'Укажите одно действие'; ACTION=$1 ;;
            --panel-ipv6|--node-site-mode|--node-site-port|--node-inbound-port|--page-id|--page-operation|--panel-url|--panel-token-file|--version|--component|--directory|--compose-file|--container|--project-name|--domain|--subscription-urls|--subscription-port|--server-ip|--port|--proxy|--node-domain|--email|--tls-method|--cert-file|--key-file|--dns-credentials|--panel-ip|--backup|--source-url|--destination-url|--internal-squad|--quota-mode)
                (($#>=2)) && [[ -n $2 && $2 != --* ]] || die "Нужно значение после $1"
                case "$1" in
                    --panel-ipv6) PANEL_IPV6_MODE=$2; PANEL_IPV6_MODE_SET=true;;
                    --node-site-mode) NODE_SITE_MODE=$2;; --node-site-port) NODE_SITE_PORT=$2;; --node-inbound-port) NODE_INBOUND_PORT=$2;;
                    --page-id) PAGE_ID=$2;; --page-operation) PAGE_OPERATION=$2;; --panel-url) PAGE_PANEL_URL=$2;; --panel-token-file) PAGE_TOKEN_FILE=$2;;
                    --version) VERSION=$2;; --component) COMPONENT=$2;; --directory) DIRECTORY=$2;; --compose-file) COMPOSE_FILE=$2;;
                    --container) CONTAINER=$2;; --project-name) PROJECT=$2;; --domain) DOMAIN=$2;; --port) PORT=$2;; --proxy) PROXY=$2; PROXY_SET=true;;
                    --subscription-urls) SUBSCRIPTION_URLS=$2; SUBSCRIPTION_SET=true;;
                    --subscription-port) SUBSCRIPTION_PORT=$2; SUBSCRIPTION_SET=true;;
                    --server-ip) SERVER_IPS=$2;;
                    --node-domain) NODE_DOMAIN=$2;; --email) EMAIL=$2;; --tls-method) TLS_METHOD=$2;; --cert-file) CERT_FILE=$2;; --key-file) KEY_FILE=$2;; --dns-credentials) DNS_CREDENTIALS=$2;; --panel-ip) PANEL_IP=$2;; --backup) BACKUP=$2;;
                    --source-url) MARZBAN_URL=$2;; --destination-url) DESTINATION_URL=$2;; --internal-squad) INTERNAL_SQUAD=$2;; --quota-mode) QUOTA_MODE=$2;;
                esac; shift ;;
            --subscription-page|--no-subscription-page)
                $SUBSCRIPTION_PAGE_SET && die 'Выберите один вариант установки сайта подписки'
                SUBSCRIPTION_PAGE_SET=true; [[ $1 != --subscription-page ]] || SUBSCRIPTION_PAGE=true;;
            --net-admin|--no-net-admin)
                $PANEL_NET_ADMIN_SET && die 'Выберите один вариант NET_ADMIN для панели'
                PANEL_NET_ADMIN_SET=true; [[ $1 != --net-admin ]] || PANEL_NET_ADMIN=true;;
            --allow-disruption) ALLOW_DISRUPTION=true;;
            --yes) YES=true;; --dry-run) DRY_RUN=true;; --preserve-subhash) PRESERVE_SUBHASH=true;;
            --help|-h) usage; return 10;; *) die "Неизвестная команда или параметр: $1";;
        esac; shift
    done
    [[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Некорректный REMNACUST_REPOSITORY'
    [[ $ROOT == /* && $ROOT != / && $ROOT != /opt && $ROOT != /usr ]] || die 'Некорректный корневой каталог'
    [[ -z $VERSION ]] || valid_version "$VERSION" || die 'Версия: latest или SemVer'
    [[ -z $COMPONENT || $COMPONENT == panel || $COMPONENT == node || $COMPONENT == subscription-page ]] || die 'Компонент: panel, node или subscription-page'
    if [[ $COMPONENT == subscription-page ]]; then
        case "$ACTION" in status|logs|start|stop|restart|show-config|change-domain|cleanup-backups|*subscription-page) ;; *) die 'Этот компонент доступен только в командах управления страницами';; esac
    fi
    [[ $PROXY == caddy || $PROXY == existing ]] || die 'Proxy: caddy или existing'
    [[ $PANEL_IPV6_MODE == auto || $PANEL_IPV6_MODE == on || $PANEL_IPV6_MODE == off ]] || die 'IPv6: auto, on или off'
    [[ $PANEL_IPV6_MODE_SET == false || -z $ACTION || $ACTION == install-panel || $ACTION == upgrade-panel || $ACTION == migrate-remnawave-panel ]] || die '--panel-ipv6 доступен для установки, обновления и переноса панели'
    [[ -z $ACTION || $ACTION == install-panel || $ACTION == install-subscription-page || $SUBSCRIPTION_SET == false ]] || die '--subscription-urls доступен для новой панели; обновление сохраняет существующие адреса подписки'
    [[ -z $ACTION || $ACTION == install-panel || $ACTION == upgrade-panel || $ACTION == migrate-remnawave-panel || $SUBSCRIPTION_PAGE_SET == false ]] || die 'Установка сайта подписки доступна для новой панели или миграции Remnawave'
    [[ -z $ACTION || $ACTION == install-panel || $ACTION == install-node || $ACTION == upgrade-node || $ACTION == migrate-remnawave-node || $PANEL_NET_ADMIN_SET == false ]] || die '--net-admin/--no-net-admin доступны для новой панели, установки, переноса или обновления ноды'
    [[ -z $TLS_METHOD || $TLS_METHOD =~ ^(auto|http|cloudflare|gcore|existing)$ ]] || die 'Способ TLS: auto, http, cloudflare, gcore или existing'
    [[ -z $NODE_SITE_MODE || $NODE_SITE_MODE == selfsteal || $NODE_SITE_MODE == standalone ]] || die 'Режим сайта: selfsteal или standalone'
    local website_port
    for website_port in "${NODE_SITE_PORT:-443}" "${NODE_INBOUND_PORT:-8443}"; do
        [[ $website_port =~ ^[0-9]{1,5}$ ]] && ((10#$website_port >= 1 && 10#$website_port <= 65535)) || die 'Порт должен быть от 1 до 65535'
    done
    [[ -z $NODE_SITE_MODE$NODE_SITE_PORT$NODE_INBOUND_PORT || $ACTION == install-node || $ACTION == migrate-remnawave-node || ( $ACTION == change-domain && $COMPONENT == node ) ]] || die 'Параметры сайта ноды доступны при установке, переносе и смене домена ноды'
    [[ $ACTION == install-* || $ACTION == migrate-remnawave-node || $ACTION == change-domain || -z $TLS_METHOD$CERT_FILE$KEY_FILE$DNS_CREDENTIALS$EMAIL$NODE_DOMAIN ]] || die 'Параметры TLS доступны при установке, переносе ноды и смене домена; обновление сохраняет ваш proxy и сертификаты'
    [[ $QUOTA_MODE == remaining || $QUOTA_MODE == total ]] || die 'Quota: remaining или total'
    [[ $ALLOW_DISRUPTION == false || $ACTION == upgrade-panel ]] || die '--allow-disruption доступен только для upgrade-panel'
    if [[ $ACTION != migrate-marzban-panel ]] && { $DRY_RUN || $PRESERVE_SUBHASH || [[ -n $MARZBAN_URL$DESTINATION_URL$INTERNAL_SQUAD ]]; }; then die 'Параметры Marzban предназначены только для migrate-marzban-panel'; fi
}
subscription_page_installed() {
    if command -v python3 >/dev/null && python3 - "$ROOT" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
def load(path):
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size>1024*1024:return {}
        value=json.loads(path.read_text())
        return value if isinstance(value,dict) else {}
    except (OSError,ValueError):return {}
def present(item):
    try:
        directory=Path(item.get('directory',''))
        files=item.get('composeFiles',[])
        return not item.get('uninstalled') and directory.is_absolute() and directory.is_dir() and not directory.is_symlink() and isinstance(files,list) and bool(files) and all(isinstance(value,str) and (path:=directory/value).is_file() and not path.is_symlink() for value in files)
    except (OSError,TypeError,ValueError):return False
try:
    folder=root/'registry/subscription-pages'
    if not folder.is_symlink():
        for path in folder.glob('*.json'):
            if present(load(path)):raise SystemExit(0)
    panel=load(root/'registry/panel.json')
    if not panel.get('uninstalled'):
        if panel.get('subscriptionPage') and present(panel):raise SystemExit(0)
        migrated=panel.get('subscriptionMigration')
        if isinstance(migrated,dict) and present(migrated):raise SystemExit(0)
except (OSError,TypeError,ValueError):pass
raise SystemExit(1)
PY
    then return 0; fi
    command -v docker >/dev/null || return 1
    local image rows
    rows=$(docker ps --all --format '{{.Image}}' 2>/dev/null) || return 1
    while IFS= read -r image; do
        case "${image%%@*}" in
            ghcr.io/lottman/remnacust-subscription-page|ghcr.io/lottman/remnacust-subscription-page:*|remnawave/subscription-page|remnawave/subscription-page:*|docker.io/remnawave/subscription-page|docker.io/remnawave/subscription-page:*|ghcr.io/remnawave/subscription-page|ghcr.io/remnawave/subscription-page:*) return 0;;
        esac
    done <<< "$rows"
    return 1
}
component_installed() {
    local component=$1 directory="$ROOT/$1" registry="$ROOT/registry/$1.json" file
    if [[ -f $registry && ! -L $registry ]] && command -v python3 >/dev/null; then
        directory=$(python3 - "$registry" "$component" <<'PY'
import json,sys
try:
    state=json.load(open(sys.argv[1]))
    if state.get('component')!=sys.argv[2] or state.get('uninstalled'): raise SystemExit(1)
    print(state['directory'])
except (OSError,ValueError,KeyError,TypeError): raise SystemExit(1)
PY
        ) || directory="$ROOT/$component"
    fi
    [[ -z $DIRECTORY || $COMPONENT != "$component" ]] || directory=$DIRECTORY
    if ! retired_installation "$component" && [[ ! -f $directory/.remnacust-uninstalled && -d $directory && ! -L $directory ]]; then
        for file in compose.json compose.yml compose.yaml docker-compose.yml docker-compose.yaml Dockerfile; do
            [[ ! -f $directory/$file || -L $directory/$file ]] || return 0
        done
    fi
    [[ -n $(component_containers "$component") || -n $(component_project_containers "$component") ]]
}
component_containers() {
    # Also find installations made before the registry existed, including stopped containers.
    command -v docker >/dev/null || return 0
    local component=$1 main=remnawave project="${PROJECT:-remnacust-$1}" rows id name image
    [[ $component != node ]] || main=remnanode
    rows=$(docker ps --all --filter "label=com.docker.compose.service=$main" --format '{{.ID}}|{{.Label "com.docker.compose.project"}}|{{.Image}}' 2>/dev/null) || return 0
    while IFS='|' read -r id name image; do
        [[ -n $id ]] || continue
        if [[ $name == "$project" || $image == *remnacust-"$component"* ]]; then printf '%s\n' "$id"; fi
    done <<< "$rows"
}
component_project_containers() {
    command -v docker >/dev/null || return 0
    docker ps --all --quiet --filter "label=com.docker.compose.project=${PROJECT:-remnacust-$1}" 2>/dev/null || true
    docker ps --all --quiet --filter "label=io.remnacust.installer-managed=$1" 2>/dev/null || true
}
assert_fresh_target() {
    local directory="${DIRECTORY:-$ROOT/$COMPONENT}" project="${PROJECT:-remnacust-$COMPONENT}" existing
    component_installed "$COMPONENT" && die "$COMPONENT уже установлен (в том числе остановленные контейнеры). Используйте upgrade-$COMPONENT; для старой установки укажите --directory или --container."
    if [[ -e $ROOT/registry/$COMPONENT.json || -L $ROOT/registry/$COMPONENT.json ]]; then
        retired_installation "$COMPONENT" || die 'Найдена запись установки, но её файлы недоступны. Проверьте каталог; новая установка поверх неё не выполняется.'
    fi
    [[ $directory == /* && $directory != / && ! -L $directory ]] || die 'Укажите безопасный абсолютный каталог'
    if [[ -d $directory && -n $(find "$directory" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        if [[ -n $DIRECTORY ]] || ! retired_installation "$COMPONENT"; then
            die "Каталог $directory не пуст. Используйте upgrade/migrate или другой --directory."
        fi
    fi
    if command -v docker >/dev/null; then
        existing=$(docker ps --all --filter "label=com.docker.compose.project=$project" --format '{{.Names}} · {{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null) || die 'Не удалось проверить контейнеры: Docker daemon недоступен. Запустите Docker и повторите проверку.'
        [[ -z $existing ]] || die "Проект $project уже существует: $existing. Используйте upgrade/migrate с --directory."
    fi
}
retired_installation() {
    [[ -f $ROOT/registry/$1.json && ! -L $ROOT/registry/$1.json ]] || return 1
    command -v python3 >/dev/null || return 1
    python3 - "$ROOT/registry/$1.json" "$1" <<'PY'
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    raise SystemExit(0 if isinstance(s,dict) and s.get('component')==sys.argv[2] and s.get('uninstalled') is True else 1)
except (OSError,ValueError,TypeError):raise SystemExit(1)
PY
}
assert_not_uninstalled() {
    case "$ACTION" in start|restart|restore-panel)
        if retired_installation "$COMPONENT" || [[ -n $DIRECTORY && -f $DIRECTORY/.remnacust-uninstalled || -n $DEPLOY && -f $DEPLOY/.remnacust-uninstalled ]]; then
            die "$COMPONENT удалён. Доступна только новая установка: remnacust install-$COMPONENT. Прежние данные сохраняются."
        fi;;
    esac
}
project_has_volumes() {
    docker volume ls --quiet > "$WORK/existing-volumes" || die 'Не удалось проверить тома: Docker недоступен'
    python3 - "$WORK/existing-volumes" "$1" <<'PY'
import sys
raise SystemExit(0 if any(n.startswith(sys.argv[2]+'_') for n in open(sys.argv[1]).read().splitlines()) else 1)
PY
}
select_fresh_target() {
    local stamp project="${PROJECT:-remnacust-$COMPONENT}" collision=false
    stamp="$(date -u +%Y%m%d%H%M%S)-$$"
    REINSTALL_RECORD=''
    if retired_installation "$COMPONENT"; then
        REINSTALL_RECORD="$WORK/retired-registry.json"
        install -m 0600 "$ROOT/registry/$COMPONENT.json" "$REINSTALL_RECORD"
        [[ -n $PROJECT ]] || project="remnacust-$COMPONENT-$stamp"
        [[ -n $DIRECTORY ]] || DIRECTORY="$ROOT/$COMPONENT"
        if [[ -d $DIRECTORY && -n $(find "$DIRECTORY" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
            python3 - "$DIRECTORY" <<'PY'
import json,subprocess,sys
directory=sys.argv[1]
ids=subprocess.run(['docker','ps','--all','--quiet'],capture_output=True,text=True,check=True).stdout.split()
containers=json.loads(subprocess.run(['docker','inspect',*ids],capture_output=True,text=True,check=True).stdout) if ids else []
for item in containers:
 labels=item.get('Config',{}).get('Labels') or {}
 paths=[labels.get('com.docker.compose.project.working_dir',''),*labels.get('com.docker.compose.project.config_files','').split(','),*[mount.get('Source','') for mount in item.get('Mounts',[])]]
 if any(path==directory or path.startswith(directory+'/') for path in paths):raise SystemExit('Каталог используется другим контейнером; новая установка остановлена без переноса файлов')
PY
            local retired_path="$ROOT/backups/reinstalled-$COMPONENT-$stamp"
            mkdir -p "$ROOT/backups"
            mv -- "$DIRECTORY" "$retired_path"
            info "Файлы удалённой установки сохранены: $retired_path"
        fi
        info 'Рабочий каталог постоянный; прежние данные находятся в backups и сохранённых томах.'
    fi
    if project_has_volumes "$project"; then collision=true; fi
    if $collision; then
        [[ -z $PROJECT ]] || die "Тома проекта $PROJECT уже существуют. Для новой установки укажите другое --project-name; прежние данные сохраняются."
        project="remnacust-$COMPONENT-$stamp"
        [[ -n $DIRECTORY ]] || DIRECTORY="$ROOT/$COMPONENT"
        info 'Прежние тома сохраняются; для новой установки выбран отдельный проект Docker.'
    fi
    PROJECT=$project
    info "Каталог: ${DIRECTORY:-$ROOT/$COMPONENT} · проект: $PROJECT"
}
archive_retired_registry() {
    [[ -n $REINSTALL_RECORD ]] || return 0
    local snapshot="$ROOT/backups/reinstall-$COMPONENT-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    cmp -- "$REINSTALL_RECORD" "$ROOT/registry/$COMPONENT.json" >/dev/null || die 'Запись прежней установки изменилась; повторите установку'
    install -d -m 0700 "$snapshot"
    install -m 0600 "$REINSTALL_RECORD" "$snapshot/registry.json"
    info "Параметры прежней установки сохранены: $snapshot/registry.json"
}
confirm() {
    $YES && return 0
    local answer
    answer=$(ask_yes_no "$1. Продолжить?") || exit 1
    [[ $answer == yes ]] || { info 'Действие отменено'; exit 0; }
}
cleanup() {
    local result=0
    if [[ -n ${DOMAIN_PLAN:-} && -f $DOMAIN_PLAN && -n ${HELPER_ROOT:-} ]]; then
        python3 -I "$HELPER_ROOT/management.py" rollback --root "$ROOT" --plan "$DOMAIN_PLAN" || { result=$?; printf '  Не удалось завершить откат. План восстановления: %s\n' "$DOMAIN_PLAN" >&2; }
    fi
    if [[ -n $WORK && -f $WORK/.installer-owned ]]; then rm -rf -- "$WORK" || result=$?; fi
    return "$result"
}
operation_log_event() {
    $OPERATION_LOG_ACTIVE || return 0
    printf '[%s] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}" >> "$LOG"
}
operation_log_error() {
    local result=$1 line=$2 context=$3
    operation_log_event ERROR "exit=$result line=$line functions=$context"
    return "$result"
}
operation_log_finish() {
    local result=$1 cleanup_status=0
    trap - EXIT ERR INT TERM HUP
    set +e
    cleanup || cleanup_status=$?
    ((result != 0 || cleanup_status == 0)) || result=$cleanup_status
    if $OPERATION_LOG_ACTIVE; then
        operation_log_event FINISH "action=$ACTION exit=$result elapsed=$((SECONDS-OPERATION_STARTED))s"
        if [[ -n $OPERATION_STDERR ]]; then exec 2>&"$OPERATION_STDERR"; exec {OPERATION_STDERR}>&-; fi
        [[ -z $OPERATION_LOG_PID ]] || wait "$OPERATION_LOG_PID"
        if ((result)); then printf '\n  Действие не завершено (код %s). Подробный журнал: %s\n  Просмотр: sudo less -- %q\n' "$result" "$LOG" "$LOG" >&2
        else printf '  Подробный журнал: %s (будет заменён при следующем действии).\n' "$LOG"; fi
    fi
    exit "$result"
}
start_operation_log() {
    [[ $EUID == 0 && $(uname -s) == Linux ]] || die 'Нужен root на Linux'
    [[ ! -L $ROOT && ! -L $ROOT/logs ]] || die 'Каталог журнала не может быть символической ссылкой'
    install -d -m 0700 "$ROOT/logs"
    command -v flock >/dev/null || die 'Нужен util-linux (flock)'
    [[ ! -L $ROOT/logs/.operation.lock ]] || die 'Некорректный файл блокировки журнала'
    exec 8>"$ROOT/logs/.operation.lock"
    flock -n 8 || die 'Другое действие ещё выполняется; предыдущий журнал сохранён'
    local created kind=${COMPONENT:-maintenance}
    case "$ACTION" in
        *subscription-page) kind=subscription-page;;
        *panel|renew-panel-certificate) kind=panel;;
        *node|renew-node-certificate|configure-node-site) kind=node;;
    esac
    case "$ACTION" in status|logs|show-config|check-panel|--check-release) kind=diagnostics;; esac
    case "$kind" in panel|node|subscription-page|maintenance|diagnostics) ;; *) die 'Некорректный компонент журнала';; esac
    created=$(mktemp "$ROOT/logs/.installer-log.XXXXXXXX")
    chmod 0600 "$created"
    LOG="$ROOT/logs/installer-$kind.log"
    mv -fT -- "$created" "$LOG"
    OPERATION_LOG_ACTIVE=true; OPERATION_STARTED=$SECONDS
    trap 'operation_log_finish "$?"' EXIT
    trap 'operation_log_error "$?" "$LINENO" "${FUNCNAME[*]}"' ERR
    trap 'operation_log_event INTERRUPTED signal=INT; exit 130' INT
    trap 'operation_log_event INTERRUPTED signal=TERM; exit 143' TERM
    trap 'operation_log_event INTERRUPTED signal=HUP; exit 129' HUP
    operation_log_event START "action=$ACTION requested=${VERSION:-latest} architecture=$(uname -m) kernel=$(uname -r)"
    printf '  Подробный журнал: %s\n' "$LOG"
    exec {OPERATION_STDERR}>&2
    exec 2> >(tee -a -- "$LOG" >&"$OPERATION_STDERR")
    OPERATION_LOG_PID=$!
}
report_update_progress() {
    [[ -n ${REMNACUST_UPDATE_JOB:-} && -n ${HELPER_ROOT:-} ]] || return 0
    python3 "$HELPER_ROOT/update-agent.py" --root "$ROOT" progress --job "$REMNACUST_UPDATE_JOB" \
        --stage "$1" --label "$2" --event "$3" >> "$LOG" 2>&1 || true
}
step() {
    local title=$1 pid status=0 i=0 display width stage=preparation started=$SECONDS; shift
    case "$1" in
        fetch_source) stage=checking;;
        prepare_image|prepare_subscription_image) stage=download;;
        backup_panel_data) stage=backup;;
        wait_ready) stage=readiness;;
        verify_database) stage=verifying;;
        compose) stage=applying;;
    esac
    [[ -n $LOG ]] || die 'Не настроен журнал операции'
    operation_log_event STEP "started: $title"
    report_update_progress "$stage" "$title" running
    "$@" >> "$LOG" 2>&1 & pid=$!
    local LC_ALL=C.UTF-8
    if [[ -t 1 && -n $ACCENT ]]; then
        local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        while kill -0 "$pid" 2>/dev/null; do
            width=$(terminal_width); display=$title
            ((${#display} <= width-5)) || display="${display:0:width-6}…"
            printf '\r  %s%s%s %s' "$ACCENT" "${frames[i%10]}" "$RESET" "$display"
            i=$((i+1)); sleep .12
        done
        printf '\r\033[2K'
    else
        terminal_text "… $title" '  ' '    '
    fi
    wait "$pid" || status=$?
    operation_log_event STEP "finished: $title; exit=$status elapsed=$((SECONDS-started))s"
    if ((status)); then report_update_progress "$stage" "$title" failed
    else report_update_progress "$stage" "$title" done; fi
    if ((status)); then printf '%s  × %s · журнал: %s%s\n' "$ROSE" "$title" "$LOG" "$RESET" >&2; return "$status"; fi
    info "✓ $title"
}
package_step() {
    if [[ -n $OPERATION_STDERR ]] && [[ -t $OPERATION_STDERR ]]; then
        package_step_command "$@" 2>&"$OPERATION_STDERR"
    else package_step_command "$@"; fi
}
package_step_command() {
    local title=$1 operation=$2 status=0 plan='' stage=checking; shift 2
    [[ -z ${SOURCE:-} ]] || stage=preparation
    local -a apt_command=(apt-get -y -o DPkg::Lock::Timeout=120 -o APT::Get::Assume-No=false "$operation" "$@")
    command -v apt-get >/dev/null || die 'Нужен APT: системные пакеты обновляются на сервере Ubuntu/Debian'
    info "$title"
    [[ -z ${LOG:-} ]] || printf 'APT %s: started\n' "$operation" >> "$LOG"
    report_update_progress "$stage" "$title" running
    if [[ ! -t 0 || ! -t 1 || ! -t 2 ]]; then
        if [[ $operation != update ]]; then
            plan=$(mktemp "${WORK:-${TMPDIR:-/tmp}}/remnacust-apt-plan.XXXXXXXX") || return $?
            LC_ALL=C DEBIAN_FRONTEND=readline NEEDRESTART_MODE=l "${apt_command[@]}" --simulate > "$plan" 2>&1 || status=$?
            if ((status)); then
                cat -- "$plan" >&2; rm -f -- "$plan"
                report_update_progress "$stage" "$title" failed
                return "$status"
            fi
            if grep -Eq '^(Inst|Conf|Remv) ' "$plan" || ! grep -Eq '^0 upgraded, 0 newly installed, 0 to remove' "$plan"; then
                cat -- "$plan" >&2; rm -f -- "$plan"
                printf 'Системные пакеты требуют обновления в SSH-терминале для возможных вопросов настройки dpkg/debconf. Продолжение APT подтверждается автоматически (-y); --yes не выбирает настройки пакетов.\n' >&2
                report_update_progress "$stage" 'Обновите системные пакеты в SSH-терминале' failed
                return 75
            fi
            rm -f -- "$plan"
        fi
    fi
    if $OPERATION_LOG_ACTIVE && [[ -t 0 && -t 1 && -t 2 ]]; then
        command -v script >/dev/null || die 'Нужен util-linux (script) для интерактивного журнала APT'
        local package_command
        printf -v package_command '%q ' env DEBIAN_FRONTEND=readline NEEDRESTART_MODE=l "${apt_command[@]}"
        script --quiet --return --flush --append --echo never --log-out "$LOG" --command "$package_command" || status=$?
    elif $OPERATION_LOG_ACTIVE; then
        DEBIAN_FRONTEND=readline NEEDRESTART_MODE=l "${apt_command[@]}" 2>&1 | tee -a -- "$LOG" || status=$?
    else
        DEBIAN_FRONTEND=readline NEEDRESTART_MODE=l "${apt_command[@]}" || status=$?
    fi
    [[ -z ${LOG:-} ]] || printf 'APT %s: exit %s\n' "$operation" "$status" >> "$LOG"
    if ((status)); then
        report_update_progress "$stage" "$title" failed
        printf 'Обновление системных пакетов не завершено (код %s). Действие остановлено; исправьте ошибку APT/dpkg и повторите команду.\n' "$status" >&2
        return "$status"
    fi
    report_update_progress "$stage" "$title" done
    info "✓ $title"
}
update_system_packages() {
    [[ $ACTION != --check-release ]] || return 0
    if $DRY_RUN; then
        info 'Пробный запуск: системные пакеты не изменяются'
        return 0
    fi
    case "$ACTION" in install-*|upgrade-*|migrate-remnawave-*) supported_os_codename >/dev/null || return $?;; esac
    if [[ $ACTION == upgrade-panel && ${REMNACUST_UPDATE_JOB:-} =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ &&
          ${REMNACUST_RELEASE_ENTRY_FILE:-} == "$ROOT/control/release-${REMNACUST_UPDATE_JOB}.sh" &&
          ( ! -t 0 || ! -t 1 || ! -t 2 ) ]]; then
        info 'Обновление панели без APT. Обслуживание ОС отложено: выполните обновление системных пакетов отдельно в SSH-терминале.'
        report_update_progress checking 'Обслуживание ОС отложено до SSH; обновляется только панель' done
        return 0
    fi
    package_step 'Обновление списка системных пакетов' update -o APT::Update::Error-Mode=any || return $?
    package_step 'Обновление системных пакетов' upgrade --with-new-pkgs || return $?
    if [[ -f /var/run/reboot-required ]]; then
        info 'Системе нужна перезагрузка. Выполните её отдельно в удобное время; установщик сервер не перезагружает.'
    fi
}
helper() {
    if $OPERATION_LOG_ACTIVE; then python3 "$HELPER" "$@"
    elif [[ -n ${LOG:-} ]]; then python3 "$HELPER" "$@" 2> >(tee -a -- "$LOG" >&2)
    else python3 "$HELPER" "$@"; fi
}
get() { helper get --state "$STATE" --key "$1"; }
compose() {
    local -a args=(); local file
    for file in "${FILES[@]}"; do args+=(-f "$file"); done
    docker compose --project-name "$PROJECT" --project-directory "$DEPLOY" "${args[@]}" "$@"
}
load_state() {
    [[ -f $STATE ]] || die 'Установка не зарегистрирована; используйте migrate-remnawave-panel/node'
    DEPLOY=$(get directory); PROJECT=$(get project)
    mapfile -t FILES < <(get composeFiles); mapfile -t APPS < <(get applications); mapfile -t EXTRAS < <(get extraServices)
    ((${#FILES[@]}&&${#APPS[@]})) || die 'Неполные метаданные установки'
}
capture_running_apps() {
    local service id
    RUNNING_APPS=()
    for service in "${APPS[@]}"; do
        id=$(compose ps --all --quiet "$service")
        if [[ -n $id && $(docker inspect --format '{{.State.Running}}' "$id") == true ]]; then
            RUNNING_APPS+=("$service")
        fi
    done
}
load_restore_apps() {
    # An explicitly empty list means all applications were stopped in the backup.
    python3 - "$STATE" > "$WORK/restore-applications" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]));apps=s.get('runningApplications',s['applications'])
if not isinstance(apps,list) or any(a not in s['applications'] for a in apps):raise SystemExit('Invalid application state')
if apps:print('\n'.join(apps))
PY
    local status=$?
    ((status==0)) || return "$status"
    mapfile -t START_APPS < "$WORK/restore-applications"
}
supported_os_codename() {
    local release=${1:-/etc/os-release} id version
    [[ -f $release ]] || die 'Не определена ОС: отсутствует /etc/os-release'
    # shellcheck disable=SC1090,SC1091
    id=$(unset ID; . "$release"; printf '%s' "${ID:-}")
    # shellcheck disable=SC1090,SC1091
    version=$(unset VERSION_ID; . "$release"; printf '%s' "${VERSION_ID:-}")
    case "$id:$version" in
        ubuntu:22.04) printf jammy;;
        ubuntu:24.04) printf noble;;
        ubuntu:26.04) printf resolute;;
        debian:12) printf bookworm;;
        debian:13) printf trixie;;
        *) die "Поддерживаются Ubuntu 22.04 LTS, Ubuntu 24.04 LTS, Ubuntu 26.04 LTS, Debian 12 и Debian 13. Обнаружено: ${id:-неизвестно} ${version:-неизвестно}";;
    esac
}
prepare_host() {
    local id codename
    codename=$(supported_os_codename) || return $?
    [[ $EUID == 0 && $(uname -s) == Linux ]] || die 'Для установки нужен root на Linux'
    case "$(uname -m)" in x86_64|aarch64) ;; *) die 'Нужна архитектура amd64 или arm64';; esac
    id=$(unset ID; . /etc/os-release; printf '%s' "${ID:-}")
    case "$id" in ubuntu|debian) ;; *) die 'Не определён репозиторий Docker для ОС';; esac
    if ! command -v python3 >/dev/null || ! command -v curl >/dev/null || ! command -v flock >/dev/null || ! command -v tar >/dev/null || ! command -v openssl >/dev/null; then
        package_step 'Подготовка системных пакетов' update -o APT::Update::Error-Mode=any || return $?
        package_step 'Python, curl, util-linux, OpenSSL' install ca-certificates curl python3 util-linux tar openssl || return $?
    fi
    installed_helper || return $?
    if ! command -v docker >/dev/null; then
        package_step 'Индекс пакетов' update -o APT::Update::Error-Mode=any || return $?
        package_step 'Ключи репозитория Docker' install ca-certificates curl || return $?
        install -d -m 0755 /etc/apt/keyrings
        download "https://download.docker.com/linux/$id/gpg" "$WORK/docker.asc"
        install -m 0644 "$WORK/docker.asc" /etc/apt/keyrings/remnacust-docker.asc
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/remnacust-docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$id" "$codename" > /etc/apt/sources.list.d/remnacust-docker.list
        package_step 'Индекс Docker' update -o APT::Update::Error-Mode=any || return $?
        package_step 'Docker Engine и Compose' install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return $?
        systemctl enable --now docker
    fi
    docker info >/dev/null 2>&1 || die 'Docker установлен, но daemon недоступен; текущая установка не изменена'
    if ! docker compose version >/dev/null 2>&1; then
        package_step 'Индекс Compose' update -o APT::Update::Error-Mode=any || return $?
        if apt-cache show docker-compose-plugin >/dev/null 2>&1; then package_step 'Docker Compose plugin' install docker-compose-plugin || return $?
        elif apt-cache show docker-compose-v2 >/dev/null 2>&1; then package_step 'Docker Compose v2' install docker-compose-v2 || return $?
        else die 'Нет пакета Compose v2 в настроенных репозиториях; Docker daemon не изменён'; fi
    fi
    docker compose version >/dev/null || die 'Нужен Docker Compose v2'
}
port_free() {
    python3 - "$1" <<'PY'
import socket,sys
port=int(sys.argv[1])
for family,address in [(socket.AF_INET,'0.0.0.0'),(socket.AF_INET6,'::')]:
    s=socket.socket(family,socket.SOCK_STREAM)
    try:
        if family==socket.AF_INET6:s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
        s.bind((address,port))
    except OSError as e:
        if e.errno not in (97,99):raise SystemExit('Порт занят: '+str(port))
    finally:s.close()
PY
}
choose_subscription_port() {
    local candidate=$1 reserved=${2:-}
    while true; do
        if [[ $candidate == 80 || $candidate == 443 || -n $reserved && $candidate == "$reserved" ]]; then
            printf '  Порт сайта подписки должен отличаться от портов панели и HTTPS.\n' >&2
        elif helper validate --port "$candidate" >/dev/null && port_free "$candidate"; then
            printf '%s' "$candidate"; return 0
        fi
        [[ -t 0 ]] && ! $YES || return 1
        printf '  Выберите другой свободный порт; работающие сервисы сохраняются.\n' >&2
        candidate=$(ask_required 'Свободный порт страницы подписки') || return $?
    done
}
panel_processes_ready() {
    local id=$1 service=$2
    [[ $COMPONENT == panel && " ${APPS[*]} " == *" $service "* ]] || return 0
    [[ $service != remnawave-subscription-page ]] || return 0
    docker exec "$id" node -e 'const fs=require("node:fs");if(!fs.existsSync("/opt/pm2/package.json"))process.exit(0);try{const {execFileSync}=require("node:child_process");const rows=JSON.parse(execFileSync("pm2",["jlist"],{timeout:5000,maxBuffer:16*1024*1024,encoding:"utf8"}));const names=new Set(["remnawave-api","remnawave-jobs","remnawave-scheduler"]);const apps=rows.filter(x=>names.has(x.name));process.exit(apps.length&&apps.every(x=>x.pm2_env.status==="online"&&x.pm2_env.restart_time===0)?0:1);}catch{process.exit(1)}' >/dev/null 2>&1
}
wait_ready() {
    local service id state before attempt ready
    for service in "${START_APPS[@]}"; do
        id=$(compose ps --all --quiet "$service")
        [[ -n $id ]] || return 1
        ready=false
        for ((attempt=1; attempt<=90; attempt++)); do
            state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")
            if [[ $state == healthy ]] && panel_processes_ready "$id" "$service"; then ready=true; break; fi
            if [[ $state == unhealthy || $state == exited || $state == dead ]]; then return 1; fi
            if (( $(docker inspect --format '{{.RestartCount}}' "$id") >= 3 )); then return 1; fi
            if [[ $state == running ]]; then
                before=$(docker inspect --format '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}}' "$id")
                sleep 5
                if [[ $(docker inspect --format '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}}' "$id") == "$before" ]]; then
                    if { [[ $COMPONENT != node || $service != "$(get mainService)" ]] || docker exec "$id" node -e 'const s=require("net").connect(Number(process.env.NODE_PORT||2222),"127.0.0.1");s.on("connect",()=>{s.destroy();process.exit(0)});s.on("error",()=>process.exit(1));setTimeout(()=>process.exit(1),3000)' >/dev/null 2>&1; } && panel_processes_ready "$id" "$service"; then ready=true; break; fi
                fi
            fi
            sleep 2
        done
        $ready || return 1
    done
}
prepare_image() {
    [[ -f $SOURCE/images.json ]] || die 'В этом старом выпуске нет готовых Docker-образов. Выберите latest; сборка на сервере отключена.'
    if docker image inspect "$IMAGE" > "$WORK/image.inspect.json" 2>/dev/null; then
        verify_loaded_image
        return
    fi
    local docker_directory free_kb needed_kb
    docker_directory=$(docker info --format '{{.DockerRootDir}}')
    free_kb=$(df -Pk "$docker_directory" | awk 'NR==2 {print $4}')
    needed_kb=$(( $(image_field size) * 4 / 1024 + 512 * 1024 ))
    ((free_kb >= needed_kb)) || die 'Недостаточно места для скачивания и распаковки Docker-образа; текущая установка не изменена'
    if docker pull "$(image_field registry)"; then
        docker tag "$(image_field registry)" "$IMAGE"
        docker image inspect "$IMAGE" > "$WORK/image.inspect.json"
        verify_loaded_image
        return
    fi
    info 'GHCR недоступен; скачиваем тот же проверенный образ из GitHub Release'
    download "$(image_field url)" "$WORK/image.tar.gz"
    python3 "$HELPER_ROOT/images.py" archive --image "${IMAGE_METADATA:-$WORK/image.json}" --file "$WORK/image.tar.gz"
    docker load --input "$WORK/image.tar.gz"
    docker image inspect "$IMAGE" > "$WORK/image.inspect.json"
    verify_loaded_image
}
verify_loaded_image() {
    if python3 "$HELPER_ROOT/images.py" inspect --image "${IMAGE_METADATA:-$WORK/image.json}" --file "$WORK/image.inspect.json" --quiet; then return; fi
    # Import into containerd may regenerate the manifest. Verify its exact config,
    # including layer digests, without writing another image copy to the server.
    docker save "$IMAGE" | python3 "$HELPER_ROOT/images.py" saved --image "${IMAGE_METADATA:-$WORK/image.json}"
}
image_field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "${IMAGE_METADATA:-$WORK/image.json}" "$1"; }
select_subscription_image() {
    python3 "$HELPER_ROOT/images.py" select --root "$SOURCE" --tag "$TAG" --assets "$WORK/release.json" \
        --repository "$REPO" --component subscription-page --architecture "$(dpkg --print-architecture)" > "$WORK/subscription-image.json"
    local IMAGE_METADATA="$WORK/subscription-image.json"
    SUBSCRIPTION_IMAGE=$(image_field image)
    SUBSCRIPTION_IMAGE_VERSION=$(image_field version)
}
prepare_subscription_image() {
    local IMAGE=$SUBSCRIPTION_IMAGE IMAGE_METADATA="$WORK/subscription-image.json"
    prepare_image
}
find_existing() {
    local main id
    main=remnawave; [[ $COMPONENT != node ]] || main=remnanode
    if [[ -n $CONTAINER ]]; then id=$CONTAINER
    elif [[ -n $DIRECTORY || -n $COMPOSE_FILE ]]; then
        DEPLOY=${DIRECTORY:-$(dirname "$COMPOSE_FILE")}; DEPLOY=$(realpath "$DEPLOY")
        if [[ -n $COMPOSE_FILE ]]; then FILES=("$(realpath "$COMPOSE_FILE")")
        else for id in compose.json compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do [[ ! -f $DEPLOY/$id ]] || { FILES=("$DEPLOY/$id"); break; }; done; fi
        ((${#FILES[@]})) || die 'В каталоге нет Compose-файла'
        local -a args=(); for id in "${FILES[@]}"; do args+=(-f "$id"); done
        id=$(docker compose --project-directory "$DEPLOY" "${args[@]}" ps --all --quiet "$main")
        [[ -n $id ]] || die 'Не найден контейнер приложения; укажите --container'
    else
        local -a ids=(); mapfile -t ids < <(docker ps --all --filter "label=com.docker.compose.service=$main" --format '{{.ID}}')
        ((${#ids[@]}==1)) || die 'Укажите --directory или --container: контейнер не найден либо их несколько'
        id=${ids[0]}
    fi
    docker inspect "$id" > "$WORK/container.before.json"
    local -a discovery=(); [[ -z $DIRECTORY ]] || discovery=(--directory "$DIRECTORY")
    [[ -z $COMPOSE_FILE ]] || discovery+=(--compose-file "$(realpath "$COMPOSE_FILE")")
    helper discover --inspect "$WORK/container.before.json" --component "$COMPONENT" --target "$WORK/state.json" "${discovery[@]}"
    if [[ -f $ROOT/registry/$COMPONENT.json ]]; then
        python3 - "$WORK/state.json" "$ROOT/registry/$COMPONENT.json" <<'PY'
import json,sys
p=sys.argv[1];new=json.load(open(p));old=json.load(open(sys.argv[2]))
if new['project']==old['project'] and new['directory']==old['directory']:
 for key in ['nodeDomain','nodeSiteMode','nodeSitePort','nodeInboundPort','panelDomain','proxy','apiPort','extraServices','version','image','ownedServices','tls','subscriptionUrls','subscriptionPage','subscriptionPort','subscriptionTokenUuid','subscriptionMigration','composeEntryPoint']:
  if key in old and (key != 'apiPort' or key not in new) and (key != 'composeEntryPoint' or old[key] in new.get('composeFiles',[])):new[key]=old[key]
 json.dump(new,open(p,'w'),indent=2)
PY
    fi
    STATE="$WORK/state.json"; load_state
    cp "$STATE" "$WORK/state.before.json"
    compose --profile '*' config --no-interpolate --no-env-resolution --format json > "$WORK/compose.before.json"
    local -a project_ids=(); mapfile -t project_ids < <(docker ps --all --quiet --filter "label=com.docker.compose.project=$PROJECT")
    docker inspect "${project_ids[@]}" > "$WORK/project-containers.json"
    local -a subscription_options=()
    if [[ $COMPONENT == panel && $IMAGE != discovery-only ]]; then subscription_migration_wizard; fi
    if [[ $COMPONENT == panel && $IMAGE != discovery-only ]] && python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));sys.exit(not (s.get("subscriptionPage") or s.get("subscriptionMigration")))' "$STATE"; then
        select_subscription_image
        step 'Готовый образ сайта подписки' prepare_subscription_image
        subscription_options=(--subscription-image "$SUBSCRIPTION_IMAGE")
    fi
    helper transform --source "$WORK/compose.before.json" --inspect "$WORK/container.before.json" --roles "$WORK/project-containers.json" --component "$COMPONENT" --image "$IMAGE" "${subscription_options[@]}" --target "$WORK/compose.after.json" --state "$STATE"
    panel_ipv6_candidate "$WORK/compose.after.json"
    mapfile -t APPS < <(get applications)
    capture_running_apps
    START_APPS=("${RUNNING_APPS[@]}")
    local primary; primary=$(get mainService)
    [[ " ${START_APPS[*]} " == *" $primary "* ]] || START_APPS+=("$primary")
    python3 - "$WORK/state.before.json" "${APPS[@]}" <<'PY'
import json,sys
p=sys.argv[1];s=json.load(open(p));s['applications']=sys.argv[2:];json.dump(s,open(p,'w'),indent=2)
PY
}
subscription_migration_wizard() {
    local script="$HELPER_ROOT/subscription_migration.py" count choice index
    [[ -f $script ]] || return 0
    if python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));sys.exit(not (s.get("subscriptionMigration") or s.get("subscriptionPage")))' "$STATE"; then return 0; fi
    [[ $ACTION == migrate-remnawave-panel || $ACTION == upgrade-panel ]] || return 0
    local -a candidates=()
    mapfile -t candidates < <(docker ps --all --quiet)
    (("${#candidates[@]}")) || return 0
    docker inspect "${candidates[@]}" > "$WORK/subscription-containers.json"
    python3 -I "$script" discover --panel "$WORK/container.before.json" --containers "$WORK/subscription-containers.json" --output "$WORK/subscription-candidates.json"
    count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$WORK/subscription-candidates.json")
    ((count > 0)) || return 0
    python3 - "$WORK/subscription-candidates.json" <<'PY'
import json,sys
for index,item in enumerate(json.load(open(sys.argv[1])),1):
 print(f"  {index}. Сайт подписки: {item['project']}/{item['service']} · {item['directory']}")
PY
    if $SUBSCRIPTION_PAGE_SET; then
        choice=no; if $SUBSCRIPTION_PAGE; then choice=yes; fi
    elif [[ -t 0 ]]; then
        choice=$(ask_yes_no 'Перенести установленную страницу подписки на Remnacust?') || return $?
    else choice=no; fi
    if [[ $choice != yes ]]; then info 'Страница подписки сохранена без изменений.'; return 0; fi
    index=1
    if ((count > 1)); then
        while true; do
            index=$(ask_required 'Номер страницы для переноса') || return $?
            if [[ $index =~ ^[0-9]{1,3}$ ]] && ((10#$index>=1 && 10#$index<=count)); then index=$((10#$index)); break; fi
            printf '  Выберите номер от 1 до %s.\n' "$count" >&2
        done
    fi
    python3 -I "$script" select --source "$WORK/subscription-candidates.json" --index "$((index-1))" --state "$STATE"
    if [[ -z $PAGE_PANEL_URL && -t 0 ]] && ! $YES; then
        choice=$(ask_yes_no 'Использовать эту панель для переносимой страницы подписки?' y) || return $?
        if [[ $choice != yes ]]; then PAGE_PANEL_URL=$(ask_required 'HTTPS адрес другой панели') || return $?; fi
    fi
}
subscription_migration_apply() {
    local script="$HELPER_ROOT/subscription_migration.py" token_uuid id
    [[ -n $SUBSCRIPTION_IMAGE && -f $script ]] || return 1
    token_uuid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["subscriptionMigration"]["tokenUuid"])' "$STATE")
    id=$(compose ps --quiet "$(get mainService)")
    local -a connection_options=()
    if [[ -n $PAGE_PANEL_URL && $PAGE_PANEL_URL != auto ]]; then
        subscription_page_token "$PAGE_PANEL_URL" "$WORK/migration-subscription-token.txt" || return $?
        connection_options=(--panel-url "$PAGE_PANEL_URL")
    else
        docker exec -i --env "REMNACUST_SUBSCRIPTION_TOKEN_UUID=$token_uuid" "$id" node - < "$HELPER_ROOT/subscription.cjs" > "$WORK/migration-subscription-token.txt"
    fi
    chmod 600 "$WORK/migration-subscription-token.txt"
    local result=0
    python3 -I "$script" upgrade --state "$STATE" --image "$SUBSCRIPTION_IMAGE" --token "$WORK/migration-subscription-token.txt" --backup-root "$ROOT/backups" --version "${COMPONENT_VERSION:-${TAG#v}}" --release "$TAG" "${connection_options[@]}" || result=$?
    rm -f -- "$WORK/migration-subscription-token.txt"
    if ((result != 0)); then info 'Панель обновлена. Перенос сайта не завершён; предыдущая конфигурация сайта восстановлена.'; return "$result"; fi
}

backup_panel_data() {
    local id
    id=$(compose ps --all --quiet "$(get mainService)")
    [[ -n $id ]] || return 1
    local backup_image=${IMAGE:-$(docker inspect --format '{{.Config.Image}}' "$id")}
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" --entrypoint node "$backup_image" - > "$BACKUP/database.dump" <<'JS'
const {spawnSync}=require('node:child_process');const u=new URL(process.env.DATABASE_URL);
const env={...process.env,PGHOST:u.hostname,PGPORT:u.port||'5432',PGUSER:decodeURIComponent(u.username),PGPASSWORD:decodeURIComponent(u.password),PGDATABASE:decodeURIComponent(u.pathname.slice(1))};
if(u.searchParams.has('sslmode'))env.PGSSLMODE=u.searchParams.get('sslmode');
const result=spawnSync('pg_dump',['--format=custom'],{env,stdio:'inherit'});process.exit(result.status??1);
JS
    [[ -s $BACKUP/database.dump ]] || return 1
    docker run --rm -i --entrypoint pg_restore "$backup_image" --list < "$BACKUP/database.dump" > "$BACKUP/database.toc"
    grep -q 'TABLE DATA public users ' "$BACKUP/database.toc"
}
backup_current() {
    capture_running_apps
    BACKUP="$ROOT/backups/$COMPONENT-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$BACKUP"; chmod 700 "$BACKUP"
    if [[ -f $WORK/state.before.json ]]; then cp "$WORK/state.before.json" "$BACKUP/state.before.json"; else cp "$STATE" "$BACKUP/state.before.json"; fi
    compose --profile '*' config --no-interpolate --no-env-resolution --format json > "$BACKUP/compose.before.json"
    local i=0 file; for file in "${FILES[@]}"; do cp -p "$file" "$BACKUP/original-$i"; i=$((i+1)); done
    [[ ! -f $DEPLOY/.env ]] || cp -L -p "$DEPLOY/.env" "$BACKUP/environment.before"
    docker inspect "$(compose ps --all --quiet "$(get mainService)")" > "$BACKUP/container.before.json"
    python3 - "$BACKUP" "${RUNNING_APPS[@]}" <<'PY'
import json,pathlib,shutil,sys
p=pathlib.Path(sys.argv[1]);s=json.load(open(p/'state.before.json'));c=json.load(open(p/'container.before.json'))[0]
s['image']=c['Config']['Image'];s['runningApplications']=sys.argv[2:];(p/'state.before.json').write_text(json.dumps(s,indent=2))
config=json.load(open(p/'compose.before.json'));files={}
for service in config['services'].values():
 for item in service.get('env_file',[]):
  f=pathlib.Path(item.get('path') if isinstance(item,dict) else item)
  if f.is_file():files[str(f.resolve())]=None
for i,path in enumerate(files):
 name='env-file-'+str(i);shutil.copyfile(path,p/name);files[path]=name
(p/'env-files.json').write_text(json.dumps(files,indent=2))
PY
    if [[ $COMPONENT == panel ]]; then step 'Согласованная копия PostgreSQL' backup_panel_data; fi
    find "$BACKUP" -maxdepth 1 -type f -exec chmod 600 {} +
    backup_hashes
    info "Резервная копия: $BACKUP"
}
recover() {
    local result=$?; trap - ERR; set +e
    operation_log_event ERROR "exit=$result line=${BASH_LINENO[0]} functions=${FUNCNAME[*]} rollback=$CHANGED database-changed=$DB_CHANGED"
    if $CHANGED && [[ -n $BACKUP ]]; then
        if [[ $COMPONENT == node ]] || ! $DB_CHANGED; then
            if [[ $COMPONENT == node ]] && ! compose stop "${APPS[@]}" >> "$LOG" 2>&1; then
                info 'Не удалось остановить новую ноду; автоматический откат не запускает второй экземпляр'
                exit "${result:-1}"
            fi
            helper restore-compose --directory "$BACKUP" >> "$LOG" 2>&1 || { info 'Не удалось восстановить Compose; приложения не запускаются'; exit "${result:-1}"; }
            STATE="$BACKUP/state.before.json"; load_state
            if [[ $COMPONENT == node ]] && ! verify_node_image_policy >> "$LOG" 2>&1; then
                info 'Предыдущий образ не поддерживает сохранённые квоты или состояние портов; нода оставлена остановленной. Установите совместимый выпуск, не обнуляя состояние.'
                exit "${result:-1}"
            fi
            if ! compose up -d --no-deps --no-build --pull never "${START_APPS[@]}" >> "$LOG" 2>&1; then
                info 'Предыдущую версию не удалось запустить; сохранённое состояние не обнулялось'
                exit "${result:-1}"
            fi
            if ! wait_ready >> "$LOG" 2>&1; then
                info 'Готовность предыдущей версии не подтверждена; проверьте status и журнал'
                exit "${result:-1}"
            fi
            if ! helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json" >> "$LOG" 2>&1; then
                info 'Предыдущая версия запущена, но реестр управления не обновился; сохраните журнал и проверьте status'
                exit "${result:-1}"
            fi
            info 'Возвращена предыдущая конфигурация приложения; проверьте status'
        else
            compose stop "${APPS[@]}" >> "$LOG" 2>&1
            printf '%s  Процессы панели остановлены. Копия: %s\n  Восстановление: remnacust restore-panel --backup %q%s\n' "$ROSE" "$BACKUP" "$BACKUP" "$RESET" >&2
        fi
    fi
    printf '%s  Операция не завершена; журнал: %s%s\n' "$ROSE" "$LOG" "$RESET" >&2
    exit "${result:-1}"
}
verify_node_image_policy() {
    # The probe has no public ports and starts no daemon. An old image must not
    # silently ignore reserves already issued to this persistent node state.
    compose run --rm --no-deps --pull never -T --entrypoint node "$(get mainService)" -e '
const fs=require("node:fs");let policy={};
try{policy=JSON.parse(fs.readFileSync("/var/lib/remnanode/host-policy.json","utf8"));}
catch(error){if(error.code!=="ENOENT")process.exit(2);}
const required=[];
const userQuota="remnacust-user-quota-reserves-v1";let userRequired=false;
function privateState(file,limit){
 let info;try{info=fs.lstatSync(file);}catch(error){if(error.code==="ENOENT")return null;throw error;}
 if(!info.isFile()||info.isSymbolicLink()||info.size>limit)throw Error("Invalid private quota state");
 const parent=fs.lstatSync(require("node:path").dirname(file)),uid=process.getuid?.();if(!parent.isDirectory()||parent.isSymbolicLink()||((info.mode|parent.mode)&0o077)||(uid!==undefined&&(info.uid!==uid||parent.uid!==uid)))throw Error("Quota state must remain private");
 const fd=fs.openSync(file,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW||0)|(fs.constants.O_NONBLOCK||0));
 try{const opened=fs.fstatSync(fd);if(!opened.isFile()||opened.dev!==info.dev||opened.ino!==info.ino||opened.size>limit)throw Error("Private state changed");const data=Buffer.alloc(limit+1);let count=0;while(count<data.length){const n=fs.readSync(fd,data,count,data.length-count,count);if(n===0)break;count+=n;}if(count>limit)throw Error("Private state too large");return data.subarray(0,count);}finally{fs.closeSync(fd);}
}
try{
 const portPlan=privateState("/var/lib/remnanode/core/port-plan-state.json",1024);
 if(portPlan){
  const state=JSON.parse(portPlan.toString());
  const counter=value=>typeof value==="string"&&/^[1-9][0-9]{0,18}$/.test(value)&&BigInt(value)<=9223372036854775807n;
  if(!state||![1,2].includes(state.version)||!counter(state.revision)||typeof state.enabled!=="boolean"||typeof state.required!=="boolean"||
   (state.appliedRevision!==null&&(!counter(state.appliedRevision)||BigInt(state.appliedRevision)>BigInt(state.revision)))||
   (state.enabled&&!state.required)||(state.appliedRevision===state.revision&&state.required!==state.enabled))process.exit(4);
  if(state.version===2){
   const capability="remnacust-port-plan-delivery-v2",boot=require("/etc/s6-overlay/scripts/core-boot.cjs");
   if(boot.PORT_PLAN_DELIVERY_CAPABILITY!==capability||typeof boot.validateSavedPortPlan!=="function")process.exit(4);
   boot.validateSavedPortPlan(state);
   const file="/opt/app/dist/main.js",info=fs.lstatSync(file);
   if(!info.isFile()||info.isSymbolicLink()||info.size>64*1024*1024)process.exit(4);
   const fd=fs.openSync(file,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW||0)|(fs.constants.O_NONBLOCK||0));
   try{
    const opened=fs.fstatSync(fd);if(!opened.isFile()||opened.dev!==info.dev||opened.ino!==info.ino||opened.size>64*1024*1024)process.exit(4);
    const data=Buffer.alloc(opened.size+1);let count=0;while(count<data.length){const n=fs.readSync(fd,data,count,data.length-count,count);if(n===0)break;count+=n;}
    if(count!==opened.size||!data.subarray(0,count).includes(Buffer.from(capability)))process.exit(4);
   }finally{fs.closeSync(fd);}
  }else if(state.delivery!==undefined||state.pluginDirty!==undefined||state.appliedInputsHash!==undefined||state.desiredPluginHash!==undefined)process.exit(4);
  if(state.required)required.push("remnacust-live-ports-v1");
 }
 const recoveryRequired=privateState("/var/lib/remnanode/quota/recovery-required.json",8192);
 let recovery;try{recovery=privateState("/var/lib/remnanode/quota/recovery.json",8192);}catch(error){if(!recoveryRequired)throw error;recovery=Buffer.from("{}");}
 if(recovery||recoveryRequired){
  const capability="remnacust-quota-recovery-fence-v1",boot=require("/etc/s6-overlay/scripts/core-boot.cjs");
  if(boot.QUOTA_RECOVERY_FENCE!==capability||typeof boot.verifyRecoveryState!=="function")process.exit(4);
  boot.verifyRecoveryState(recoveryRequired,recovery);required.push(capability);
  const file="/opt/app/dist/main.js",info=fs.lstatSync(file);
  if(!info.isFile()||info.isSymbolicLink()||info.size>64*1024*1024)process.exit(4);
  const fd=fs.openSync(file,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW||0)|(fs.constants.O_NONBLOCK||0));
  try{
   const opened=fs.fstatSync(fd);if(!opened.isFile()||opened.dev!==info.dev||opened.ino!==info.ino||opened.size>64*1024*1024)process.exit(4);
   const data=Buffer.alloc(opened.size+1);let count=0;while(count<data.length){const n=fs.readSync(fd,data,count,data.length-count,count);if(n===0)break;count+=n;}
   if(count!==opened.size||!data.subarray(0,count).includes(Buffer.from(capability)))process.exit(4);
  }finally{fs.closeSync(fd);}
 }
 const marker=privateState("/var/lib/remnanode/quota/user-quota-required",128);
 const ledger=privateState("/var/lib/remnanode/quota/ledger.json",16*1024*1024);
 let registered=false,watermarked=false;
 if(ledger){
  const frames=ledger.toString().split("\n");if(frames.length>1&&frames.at(-1)!=="")process.exit(2);
  for(let i=0;i<frames.length;i++){
   const frame=frames[i];if(!frame&&i===frames.length-1&&i>0)break;
   const record=JSON.parse(frame),start=frame.indexOf("\"payload\":"),end=frame.lastIndexOf(",\"sha256\":");
   if(start<0||end<start||require("node:crypto").createHash("sha256").update(frame.slice(start+10,end)).digest("hex")!==record.sha256||
    !["remnacust-quota-reserves-v1","remnacust-quota-registrations-v1","remnacust-quota-watermarks-v1"].includes(record.payload?.version)||
    (registered&&record.payload.version==="remnacust-quota-reserves-v1")||
    (watermarked&&record.payload.version!=="remnacust-quota-watermarks-v1"))process.exit(2);
   registered=record.payload.version!=="remnacust-quota-reserves-v1";
   watermarked=record.payload.version==="remnacust-quota-watermarks-v1";
  }
 }
 if(registered||policy.quotaRegistrations){
  const capability="remnacust-quota-registrations-v1";
  if(policy.quotaRegistrations!==capability||policy.offlineReserves!=="remnacust-quota-reserves-v1")process.exit(2);
  const boot=require("/etc/s6-overlay/scripts/core-boot.cjs");
  if(boot.QUOTA_REGISTRATION_CAPABILITY!==capability||typeof boot.registeredQuotaJournal!=="function")process.exit(4);
  const bundlePath="/opt/app/dist/main.js",bundleInfo=fs.lstatSync(bundlePath);
  if(!bundleInfo.isFile()||bundleInfo.isSymbolicLink()||bundleInfo.size>64*1024*1024)process.exit(4);
  const bundle=fs.readFileSync(bundlePath);
  if(bundle.length>64*1024*1024||!bundle.includes(Buffer.from(capability)))process.exit(4);
  required.push(capability);
 }
 if(watermarked||policy.quotaCheckpoint){
  const capability="remnacust-quota-watermarks-v1",boot=require("/etc/s6-overlay/scripts/core-boot.cjs");
  if(boot.QUOTA_WATERMARK_CAPABILITY!==capability||typeof boot.quotaJournalCheckpoint!=="function"||typeof boot.verifyQuotaCheckpoint!=="function")process.exit(4);
  boot.verifyQuotaCheckpoint(policy,boot.quotaJournalCheckpoint(ledger));
  const file="/opt/app/dist/main.js",info=fs.lstatSync(file);
  if(!info.isFile()||info.isSymbolicLink()||info.size>64*1024*1024)process.exit(4);
  const bytes=fs.readFileSync(file);if(bytes.length>64*1024*1024||!bytes.includes(Buffer.from(capability)))process.exit(4);
  required.push(capability);
 }
 if(marker){if(marker.toString()!==userQuota+"\n")process.exit(2);userRequired=true;}
 const cached=privateState("/var/lib/remnacust/run/core-state/checkpoint.pb",16*1024*1024+128);
 if(cached){
  const global="REMNACUST-CORE-STATE-2-USER-QUOTA\n",legacy="REMNACUST-CORE-STATE-1\n";
  const header=cached.subarray(0,global.length).toString()===global?global:legacy;
  const checksum=cached.subarray(header.length,header.length+64).toString(),payload=cached.subarray(header.length+65);
  if(cached.subarray(0,header.length).toString()!==header||!/^[a-f0-9]{64}$/.test(checksum)||cached[header.length+64]!==10||payload.length>16*1024*1024||require("node:crypto").createHash("sha256").update(payload).digest("hex")!==checksum)process.exit(2);
  userRequired ||= header===global;
 }
}catch{process.exit(2);}
if(userRequired||policy.userQuota){if(policy.userQuota!==userQuota)process.exit(2);required.push(userQuota);}
try{fs.lstatSync("/var/lib/remnanode/usage");required.push("remnacust-usage-receipts-v1");}
catch(error){if(error.code!=="ENOENT")process.exit(2);}
if(policy.offlineReserves){
 if(policy.offlineReserves!=="remnacust-quota-reserves-v1")process.exit(3);
 required.push("remnacust-quota-reserves-v1");
}
if(Object.values(policy.groups??{}).some(group=>group?.fenceAll===true||Object.values(group?.fencedOwners??{}).includes(true)))required.push("remnacust-quota-fences-v1");
if(required.some(marker=>marker===userQuota||marker==="remnacust-usage-receipts-v1"||marker==="remnacust-quota-reserves-v1"))required.push("remnacust-unreserved-usage-v1");
if(required.length){
 try{
  const details=fs.statSync("/usr/local/bin/xray");if(!details.isFile()||details.size>192*1024*1024)process.exit(3);
  const binary=fs.readFileSync("/usr/local/bin/xray");
  if(required.some(marker=>!binary.includes(Buffer.from(marker))))process.exit(3);
 }catch{process.exit(3);}
}
'
}
install_cli() {
    local bin_directory=${1:-/usr/local/bin} cache_directory=${2:-/usr/local/lib/remnacust-installer/helpers} temporary
    prepare_helpers_install "$cache_directory"
    bash -n "$WORK/installer-entry.sh"
    install -d -m 0755 "$bin_directory"
    temporary=$(mktemp "$bin_directory/.remnacust.XXXXXXXX")
    if ! install -m 0755 "$WORK/installer-entry.sh" "$temporary"; then rm -f -- "$temporary"; return 1; fi
    mv -f -- "$temporary" "$bin_directory/remnacust"
    ln -sfn "$bin_directory/remnacust" "$bin_directory/remnacust-installer"
    ln -sfn "$bin_directory/remnacust" "$bin_directory/remnacust-setup"
}
configure_panel_updates() {
    [[ $COMPONENT == panel && -f $HELPER_ROOT/update-agent.py ]] || return 0
    if [[ ! -d /run/systemd/system ]]; then
        info 'Обновление из панели требует systemd; обновление через remnacust доступно'
        return 0
    fi
    prepare_helpers_install
    local target=$1
    local -a options=()
    [[ ! -f $WORK/container.before.json ]] || options+=(--inspect "$WORK/container.before.json")
    python3 -B "$INSTALLED_HELPER_ROOT/update-agent.py" --root "$ROOT" setup --state "$STATE" --compose "$target" "${options[@]}" >> "$LOG" 2>&1
}
management_menu() {
    local choice
    terminal_section 'Выберите компонент'
    terminal_action 1 'Панель' ''
    terminal_action 2 'Нода' ''
    terminal_action 3 'Страница подписки' ''
    terminal_action 0 'Назад' ''
    choice=$(ask_menu_choice 3) || return $?
    case "$choice" in
        1) COMPONENT=panel;; 2) COMPONENT=node;; 3) COMPONENT=subscription-page;; 0) ACTION=''; return 0;;
    esac
    component_menu
}
component_title() {
    case "$COMPONENT" in panel) printf 'Панель';; node) printf 'Нода';; subscription-page) printf 'Страница подписки';; esac
}
component_menu() {
    local choice maximum=7
    terminal_section "Управление · $(component_title)"
    terminal_action 1 'Состояние' status
    terminal_action 2 'Адреса и файлы настроек' show-config
    terminal_action 3 'Журнал приложения' logs
    terminal_action 4 'Запустить' start
    terminal_action 5 'Остановить' stop
    terminal_action 6 'Перезапустить' restart
    terminal_action 7 'Сменить домен и сертификат' change-domain
    if [[ $COMPONENT == panel ]]; then
        terminal_action 8 'Перечитать сертификат' renew-panel-certificate
        maximum=8
    elif [[ $COMPONENT == node ]]; then
        terminal_action 8 'Перечитать сертификат' renew-node-certificate
        terminal_action 9 'Выбрать другой случайный сайт' configure-node-site
        maximum=9
    elif [[ $COMPONENT == subscription-page ]]; then
        terminal_action 8 'Удалить страницу; сохранить настройки и данные' uninstall-subscription-page
        terminal_action 9 'Сменить панель и API-токен' configure-subscription-page
        maximum=9
    fi
    terminal_action 0 'Назад' ''
    choice=$(ask_menu_choice "$maximum") || return $?
    case "$choice" in
        1) ACTION=status;; 2) ACTION=show-config;; 3) ACTION=logs;; 4) ACTION=start;;
        5) ACTION=stop;; 6) ACTION=restart;; 7) ACTION=change-domain;;
        8) if [[ $COMPONENT == subscription-page ]]; then ACTION=uninstall-subscription-page; else ACTION=renew-$COMPONENT-certificate; fi;;
        9) if [[ $COMPONENT == node ]]; then ACTION=configure-node-site; else ACTION=configure-subscription-page; fi;; 0) ACTION='';;
    esac
}
service_menu() {
    local selected_component
    terminal_section 'Компонент для обслуживания'
    terminal_action 1 'Панель' ''; terminal_action 2 'Нода' ''; terminal_action 3 'Страница подписки' ''; terminal_action 0 'Назад' ''
    selected_component=$(ask_menu_choice 3) || return $?
    case "$selected_component" in
        1) COMPONENT=panel;; 2) COMPONENT=node;; 3) COMPONENT=subscription-page; component_menu; return;; 0) ACTION=''; return 0;;
    esac
    local panel_available=false node_available=false current_available=false
    local panel_note='Панель не установлена' node_note='Нода не установлена' current_note='Компонент не найден'
    if component_installed panel; then panel_available=true; panel_note=''; fi
    if component_installed node; then node_available=true; node_note=''; fi
    case "$COMPONENT" in
        panel) current_available=$panel_available; current_note=$panel_note;;
        node) current_available=$node_available; current_note=$node_note;;
    esac
    terminal_section "Обслуживание · $(component_title)"
    terminal_action 1 'Проверить состояние' status "$current_note" "$current_available"
    terminal_action 2 'Журнал приложения' logs "$current_note" "$current_available"
    terminal_action 3 'Запустить' start "$current_note" "$current_available"
    terminal_action 4 'Остановить' stop "$current_note" "$current_available"
    terminal_action 5 'Перезапустить' restart "$current_note" "$current_available"
    terminal_action 6 'Создать копию панели' backup-panel "$panel_note" "$panel_available"
    terminal_action 7 'Восстановить из копии' restore-panel "$panel_note" "$panel_available"
    terminal_action 8 'Сертификат ноды' renew-node-certificate "$node_note" "$node_available"
    terminal_action 9 'Проверить панель' check-panel "$panel_note" "$panel_available"
    terminal_action 10 'Сертификат панели' renew-panel-certificate "$panel_note" "$panel_available"
    terminal_action 0 'Назад' ''
    terminal_rule
    local choice
    choice=$(ask_menu_choice 10) || return $?
    case "$choice" in 1) ACTION=status;;2) ACTION=logs;;3) ACTION=start;;4) ACTION=stop;;5) ACTION=restart;;6) ACTION=backup-panel;;7) ACTION=restore-panel;;8) ACTION=renew-node-certificate; COMPONENT=node;;9) ACTION=check-panel; COMPONENT=panel;;10) ACTION=renew-panel-certificate; COMPONENT=panel;;0) ACTION='';;esac
}
select_managed_page() {
    [[ -z $PAGE_ID ]] || return 0
    local count choice
    python3 -I "$HELPER_ROOT/subscription_pages.py" list --root "$ROOT" > "$WORK/managed-pages.json"
    count=$(python3 - "$WORK/managed-pages.json" <<'PY'
import json,sys
print(len(json.load(open(sys.argv[1]))))
PY
    )
    ((count > 0)) || die 'Зарегистрированных страниц подписки нет'
    python3 - "$WORK/managed-pages.json" <<'PY'
import json,sys
states={'running':'работает','healthy':'работает, исправна','exited':'остановлена','created':'создана, не запущена','missing':'контейнер отсутствует, сохранены только настройки','unavailable':'состояние Docker недоступно','unhealthy':'неисправна','restarting':'перезапускается','starting':'запускается','dead':'аварийно остановлена','paused':'приостановлена'}
for number,item in enumerate(json.load(open(sys.argv[1])),1):
 print(f"  {number:2}  {item['name']} · {item['domain']} · {states.get(item['status'],item['status'])}")
print('   0  Назад')
PY
    choice=$(ask_menu_choice "$count") || return $?
    [[ $choice != 0 ]] || return 1
    PAGE_ID=$(python3 - "$WORK/managed-pages.json" "$choice" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))[int(sys.argv[2])-1]['id'])
PY
    )
}
domain_plan_value() {
    python3 - "$DOMAIN_PLAN" "$1" <<'PY'
import json,sys
value=json.load(open(sys.argv[1])).get(sys.argv[2],'')
print(value if isinstance(value,str) else json.dumps(value))
PY
}
manage_component_action() {
    local requested_component=${COMPONENT:-panel} requested_domain=${DOMAIN:-${NODE_DOMAIN:-}} method
    local -a options=()
    [[ $requested_component != subscription-page ]] || select_managed_page || return $?
    [[ -z $PAGE_ID ]] || options=(--page-id "$PAGE_ID")
    if [[ $ACTION == show-config ]]; then
        python3 -I "$HELPER_ROOT/management.py" info --root "$ROOT" --component "$requested_component" "${options[@]}"
        return
    fi
    if ! $NODE_MIGRATION_TLS; then
        requested_domain=$(ask_confirmed_domain 'Новый домен (без https:// и пути)' "$requested_domain") || return $?
        confirm "Сменить домен $requested_component на $requested_domain"
    elif [[ -n $TLS_METHOD ]]; then options+=(--tls-method "$TLS_METHOD"); fi
    if [[ $requested_component == node && -z $PANEL_IP ]] && ! $NODE_MIGRATION_TLS; then
        PANEL_IP=$(python3 -I "$HELPER_ROOT/node_firewall.py" owned-panel --owner-root "$ROOT") || return $?
    fi
    if [[ $requested_component == node && -z $PANEL_IP ]]; then options+=(--no-firewall); fi
    if [[ $requested_component == node && -n $NODE_SITE_MODE ]]; then
        options+=(--site-mode "$NODE_SITE_MODE" --site-port "${NODE_SITE_PORT:-443}" --inbound-port "${NODE_INBOUND_PORT:-8443}")
    fi
    DOMAIN_PLAN=$(python3 -I "$HELPER_ROOT/management.py" prepare --root "$ROOT" --component "$requested_component" --domain "$requested_domain" "${options[@]}") || return $?
    info "Копия настроек: ${DOMAIN_PLAN%/plan.json}"
    method=$(domain_plan_value method) || return $?
    [[ -z $TLS_METHOD || $TLS_METHOD == "$method" ]] || die 'При смене домена сохраняется способ TLS. Для другого способа сначала настройте сертификат отдельно.'
    TLS_METHOD=$method
    PROJECT=$(domain_plan_value project) || return $?; DEPLOY=$(domain_plan_value directory) || return $?
    COMPONENT=$(domain_plan_value tlsComponent) || return $?; DOMAIN=$(domain_plan_value certificateDomain) || return $?
    PROXY=caddy; NODE_DOMAIN=''; [[ $COMPONENT != node ]] || NODE_DOMAIN=$DOMAIN
    STATE="$WORK/domain-state.json"; domain_plan_value tlsState > "$STATE" || return $?
    SUBSCRIPTION_URLS=$(domain_plan_value certificateSubscriptions) || return $?
    SUBSCRIPTION_PAGE=false; [[ -z $SUBSCRIPTION_URLS ]] || SUBSCRIPTION_PAGE=true
    if [[ $TLS_METHOD == auto || $TLS_METHOD == http ]]; then check_dns "$requested_domain" || return 1; fi
    if [[ $TLS_METHOD == existing ]]; then
        [[ -n $CERT_FILE ]] || CERT_FILE=$(ask_required 'Сертификат для нового домена: путь к fullchain.pem') || return $?
        [[ -n $KEY_FILE ]] || KEY_FILE=$(ask_required 'Приватный ключ: путь к privkey.pem') || return $?
    elif [[ $TLS_METHOD != auto ]]; then
        if [[ -z $EMAIL ]]; then
            while true; do
                EMAIL=$(ask_required "Email для Let's Encrypt") || return $?
                [[ $EMAIL =~ ^[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
                printf '  Некорректный email, повторите ввод.\n' >&2
            done
        fi
        [[ $EMAIL =~ ^[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'Некорректный email'
        if [[ $TLS_METHOD == cloudflare || $TLS_METHOD == gcore ]]; then
            DNS_CREDENTIALS=${DNS_CREDENTIALS:-$ROOT/acme/$PROJECT/dns.ini}
            [[ -f $DNS_CREDENTIALS ]] || DNS_CREDENTIALS=$(ask_required 'Путь к INI DNS-провайдера (права 600)') || return $?
        fi
        if [[ $TLS_METHOD == http ]]; then
            python3 -I "$HELPER_ROOT/management.py" stop-proxy --root "$ROOT" --plan "$DOMAIN_PLAN" || return $?
        fi
        obtain_certificate || return $?
    fi
    local -a certificate=()
    [[ $TLS_METHOD == auto ]] || certificate=(--certificate "$CERT_FILE" --key "$KEY_FILE")
    info 'Применяем адрес и проверяем готовность приложений.'
    python3 -I "$HELPER_ROOT/management.py" apply --root "$ROOT" --plan "$DOMAIN_PLAN" "${certificate[@]}" || return $?
    if [[ $TLS_METHOD != auto ]]; then
        STATE="$ROOT/registry/$COMPONENT.json"
        schedule_certificate_renewal || return $?
    fi
    info 'Проверяем новый HTTPS-адрес (до 2 минут для работающего Caddy).'
    python3 -I "$HELPER_ROOT/management.py" complete --root "$ROOT" --plan "$DOMAIN_PLAN" || return $?
    info "Новый домен: https://$requested_domain"
    [[ $requested_component != node ]] || info 'Обновите адрес и SNI этой ноды в хостах панели; существующие ссылки клиента сами домен не меняют.'
    DOMAIN_PLAN=''
}
node_migration_wizard() {
    local previous choice
    [[ $ACTION == migrate-remnawave-node ]] || return 0
    PORT=$(get apiPort)
    info "Сохраняем ключ панели, порт API $PORT, конфигурацию Xray и данные ноды."
    previous=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("nodeDomain", ""))' "$STATE")
    if [[ -n $previous && -z $NODE_DOMAIN$TLS_METHOD$CERT_FILE$KEY_FILE$DNS_CREDENTIALS$EMAIL$NODE_SITE_MODE$NODE_SITE_PORT$NODE_INBOUND_PORT ]]; then
        if [[ ! -t 0 ]] || $YES; then return 0; fi
        choice=$(ask_yes_no "TLS/XHTTP уже настроен для $previous. Изменить настройки?") || return $?
        [[ $choice == yes ]] || return 0
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$previous") || return $?
        NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN
    elif [[ -n $NODE_DOMAIN ]]; then
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$NODE_DOMAIN") || return $?
        NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN
    elif [[ -n $previous ]]; then
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$previous") || return $?
        NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN
    fi
    certificate_wizard || return $?
    if [[ -n $NODE_DOMAIN ]]; then
        NODE_MIGRATION_TLS=true
        certificate_preflight || return $?
        dns_preflight || return $?
    fi
}
node_migration_finish() {
    [[ $ACTION == migrate-remnawave-node ]] || return 0
    if [[ -z $PANEL_IP ]]; then
        node_acl_without_panel || return $?
        local renewal_project
        renewal_project=$(get project) || return $?
        if [[ -n $renewal_project ]]; then
            python3 -I "$HELPER_ROOT/node_firewall.py" detach-renewal --owner-root "$ROOT" --project "$renewal_project" || return $?
        fi
    fi
    if $NODE_MIGRATION_TLS; then
        local ACTION=change-domain DOMAIN=$NODE_DOMAIN
        info 'Нода перенесена. Настраиваем сайт и TLS/XHTTP с сохранением её данных.'
        if ! manage_component_action; then
            printf 'Перенос ноды завершён, но настройка TLS/XHTTP не завершена. Нода и исходные данные сохранены; подробности в журнале.\n' >&2
            return 1
        fi
        STATE="$ROOT/registry/node.json"; load_state
    fi
    node_acl
}
configure_node_site() {
    COMPONENT=node
    installed_helper; lock_operation
    STATE="$ROOT/registry/node.json"
    [[ -f $STATE && ! -L $STATE ]] || die 'Нода не зарегистрирована'
    load_state; assert_not_uninstalled
    if retired_installation node; then die 'Нода удалена. Сначала установите её заново; файлы сайта не изменены.'; fi
    local domain id status running=false
    domain=$(get nodeDomain)
    [[ -n $domain && " ${EXTRAS[*]} " == *' node-nginx '* ]] || die 'Сначала настройте домен и сайт selfsteal для ноды'
    confirm 'Заменить сайт случайным вариантом? Текущие файлы сохранятся в резервной копии'
    if ! id=$(compose ps --all --quiet node-nginx); then die 'Не удалось проверить состояние сайта. Файлы не изменены.'; fi
    if [[ -n $id ]]; then
        if ! status=$(docker inspect --format '{{.State.Running}}' "$id"); then die 'Не удалось проверить контейнер сайта. Файлы не изменены.'; fi
        case "$status" in true) running=true;; false) ;; *) die 'Неизвестное состояние контейнера сайта. Файлы не изменены.';; esac
    fi
    python3 -I "$HELPER_ROOT/node_site.py" --directory "$DEPLOY" --domain "$domain" --template random --replace --backup-root "$ROOT/backups/node-sites" > "$WORK/node-site-result.json"
    if $running; then
        if ! compose up -d --no-deps --no-build --pull never --force-recreate node-nginx || ! compose exec -T node-nginx nginx -t; then
            local -a rollback=()
            mapfile -t rollback < <(python3 - "$WORK/node-site-result.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('backup') and result.get('generation'):
    print(result['backup'])
    print(result['generation'])
PY
            )
            if ((${#rollback[@]} == 2)) && python3 -I "$HELPER_ROOT/node_site.py" --directory "$DEPLOY" --restore "${rollback[0]}" --expected-generation "${rollback[1]}" --backup-root "$ROOT/backups/node-sites" > "$WORK/node-site-rollback.json"; then
                if compose up -d --no-deps --no-build --pull never --force-recreate node-nginx && compose exec -T node-nginx nginx -t; then
                    info 'Новый сайт не запущен; предыдущий сайт восстановлен.'
                else info 'Предыдущие файлы восстановлены. Nginx не запущен; проверьте Docker и журнал.'; fi
            else info 'Не удалось перезапустить сайт. Проверьте журнал и сохранённую резервную копию.'; fi
            return 1
        fi
    fi
    python3 - "$WORK/node-site-result.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
print('  Сайт обновлён. Файлы: '+result['directory'])
if result.get('backup'): print('  Предыдущий сайт: '+result['backup'])
PY
}
main() {
    local result
    parse_args "$@" || { result=$?; [[ $result == 10 ]] && return 0; return "$result"; }
    if [[ -z $ACTION ]]; then
        interactive_menu "$@"
        return
    fi
    case "$ACTION" in manage-panel) COMPONENT=panel; component_menu;; manage-node) COMPONENT=node; component_menu;; esac
    [[ -n $ACTION ]] || return 0
    run_action
}
interactive_menu() {
    local choice
    local -a selection=()
    WORK=$(mktemp -d -t remnacust-menu.XXXXXXXX)
    touch "$WORK/.installer-owned"; trap cleanup EXIT
    while true; do
        ACTION=''; COMPONENT=''
        show_menu
        choice=$(ask_menu_choice 17) || return $?
        case "$choice" in
            1) ACTION=install-panel;;
            2) ACTION=install-node;;
            3) ACTION=install-subscription-page;;
            4) ACTION=upgrade-panel;;
            5) ACTION=upgrade-node;;
            6) ACTION=upgrade-subscription-page;;
            7) ACTION=migrate-remnawave-panel;;
            8) ACTION=migrate-remnawave-node;;
            9) ACTION=migrate-marzban-panel;;
            10) ACTION=migrate-remnawave-subscription-page;;
            11) ACTION=--check-release;;
            12) ACTION=status;;
            13) management_menu || return $?;;
            14) service_menu || return $?;;
            15) ACTION=uninstall-panel;;
            16) ACTION=uninstall-node;;
            17) ACTION=uninstall-subscription-page;;
            0) return 0;;
        esac
        [[ -n $ACTION ]] || { discard_pending_input; continue; }
        selection=("$ACTION")
        [[ -z $COMPONENT ]] || selection+=(--component "$COMPONENT")
        # A separate shell preserves errexit and confines exit/traps/locks to one action.
        if REMNACUST_MENU_COMPLETION_FD=3 bash "${BASH_SOURCE[0]}" "${selection[@]}" "$@" 3> "$WORK/menu-completed"; then
            [[ ! -s $WORK/menu-completed ]] || return 0
            discard_pending_input
            info 'Возврат в меню'
        else
            discard_pending_input
            info 'Действие не завершено. Исправьте указанную причину и повторите его в меню.'
        fi
    done
}
cleanup_backups_action() {
    installed_helper; lock_operation
    local -a cleanup_options=()
    [[ -z $COMPONENT ]] || cleanup_options=(--component "$COMPONENT")
    python3 -I "$HELPER_ROOT/deployment_layout.py" --root "$ROOT" --cleanup-backups "${cleanup_options[@]}"
}
run_action() {
    local result
    WORK=$(mktemp -d -t remnacust-installer.XXXXXXXX); touch "$WORK/.installer-owned"; trap cleanup EXIT
    start_operation_log
    if [[ $ACTION == --check-release ]]; then
        for result in curl python3 tar; do command -v "$result" >/dev/null || die "Нужен $result"; done
        [[ -n $VERSION ]] || VERSION=latest
        installed_helper
        TAG=$(resolve_release); fetch_source
        if [[ -n ${REMNACUST_RELEASE_INFO_FILE:-} ]]; then
            python3 - "$WORK/source" "$TAG" "$REMNACUST_RELEASE_INFO_FILE" "$HELPER_ROOT" "$HELPER_ENTRY" <<'PY'
import json,sys,os,subprocess
from pathlib import Path
source=Path(sys.argv[1]);sys.path.insert(0,sys.argv[4])
import helper_bundle
lock=json.loads((source/'component-sources.json').read_text())
entry=os.environ.get('REMNACUST_RELEASE_ENTRY_FILE')
if entry:
    own=Path(sys.argv[5]).read_bytes();raw=helper_bundle.read(Path(sys.argv[4])/helper_bundle.CONTRACT,32768)
    files=helper_bundle.read_files(Path(sys.argv[4]),raw)
    if helper_bundle.version_key(sys.argv[2].removeprefix('v'))>helper_bundle.version_key(helper_bundle.manifest(raw)['version']):
        own,raw,files=helper_bundle.source_bundle(source)
    script=helper_bundle.render(own,raw,files)
    subprocess.run(['bash','-n'],input=script,check=True)
    Path(entry).write_bytes(script);Path(entry).chmod(0o600)
Path(sys.argv[3]).write_text(json.dumps({'installerVersion':sys.argv[2].removeprefix('v'),'panelVersion':lock['panel']['version']}))
PY
        fi
        info "Выпуск $TAG проверен"; return 0
    fi
    case "$ACTION" in configure-node-site) COMPONENT=node;; *subscription-page) COMPONENT=subscription-page;; *panel|renew-panel-certificate) COMPONENT=panel;; *node|renew-node-certificate) COMPONENT=node;; esac
    case "$ACTION" in
        *subscription-page) ;;
        upgrade-*)
            if ! component_installed "$COMPONENT" && [[ -z $CONTAINER ]]; then
                die "$COMPONENT не установлен. Сначала install-$COMPONENT; для существующего Remnawave используйте migrate-remnawave-$COMPONENT с --directory или --container."
            fi;;
        install-*) assert_fresh_target;;
    esac
    [[ $EUID == 0 && $(uname -s) == Linux ]] || die 'Нужен root на Linux'
    update_system_packages || return $?
    case "$ACTION" in
        change-domain|show-config) installed_helper; lock_operation; manage_component_action;;
        configure-node-site) configure_node_site;;
        status|logs|start|stop|restart)
            if [[ $COMPONENT == subscription-page ]]; then
                PAGE_OPERATION=$ACTION; ACTION=manage-subscription-page; subscription_page_action
            else service_action; fi;;
        normalize-layout) installed_helper; lock_operation; python3 -I "$HELPER_ROOT/deployment_layout.py" --root "$ROOT" --component "${COMPONENT:-panel}";;
        cleanup-backups) cleanup_backups_action;;
        install-subscription-page|upgrade-subscription-page|uninstall-subscription-page|manage-subscription-page|configure-subscription-page) subscription_page_action;;
        migrate-remnawave-subscription-page) migrate_subscription_page_action;;
        migrate-marzban-panel) migrate_marzban;;
        install-*|upgrade-*|migrate-*) deploy;;
        *) service_action;;
    esac
}

# Release validation and deployment functions are defined below.

resolve_release() {
    local endpoint
    if [[ $VERSION == latest ]]; then endpoint="latest?remnacust_check=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
    else endpoint="tags/v${VERSION#v}"; fi
    download "https://api.github.com/repos/$REPO/releases/$endpoint" "$WORK/release.json" ||
        die "Релиз $VERSION недоступен в GitHub ($REPO). Проверьте публикацию релиза и сеть. Установка не изменена."
    python3 - "$WORK/release.json" "$REPO" "$VERSION" "$WORK/resolved.json" <<'PY'
import json, re, sys
release=json.load(open(sys.argv[1]))
repo, requested=sys.argv[2:4]
tag=release.get('tag_name','')
if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?',tag):
    raise SystemExit('Неподдерживаемый тег: нужен vMAJOR.MINOR.PATCH')
if release.get('draft') or (requested=='latest' and release.get('prerelease')):
    raise SystemExit('latest должен быть опубликованным стабильным выпуском')
if requested!='latest' and tag!='v'+requested.removeprefix('v'):
    raise SystemExit('Версия ответа GitHub не совпадает с выбранной')
assets={a['name']:a for a in release.get('assets',[]) if a.get('state')=='uploaded'}
runtime=f'remnacust-runtime-{tag}.tar.gz'
name=runtime if runtime in assets else f'remnacust-source-{tag}.tar.gz'
expected=f'https://github.com/{repo}/releases/download/{tag}/'
result={'tag':tag,'archive':name,'kind':'runtime' if name==runtime else 'source'}
for key, asset_name in [('source',name),('checksums','SHA256SUMS')]:
    asset=assets.get(asset_name,{})
    url=asset.get('browser_download_url','')
    if url!=expected+asset_name: raise SystemExit('Отсутствует готовый файл релиза: '+asset_name)
    result[key]=url
    if key=='source': result['digest']=asset.get('digest')
json.dump(result,open(sys.argv[4],'w'))
print(tag)
PY
}
json_value() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/resolved.json" "$1"; }
fetch_source() {
    local archive
    archive=$(json_value archive)
    download "$(json_value checksums)" "$WORK/SHA256SUMS"
    download "$(json_value source)" "$WORK/$archive"
    python3 - "$WORK" "$archive" "$REPO" "$HELPER_ROOT/images.py" <<'PY'
import hashlib,json,pathlib,re,sys,tarfile
root=pathlib.Path(sys.argv[1]);name=sys.argv[2]
lines=(root/'SHA256SUMS').read_text().splitlines()
matches=[line for line in lines if line.endswith('  '+name)]
if len(matches)!=1 or not re.fullmatch(r'[a-f0-9]{64}  '+re.escape(name),matches[0]):
    raise SystemExit('Нет однозначной SHA-256 суммы исходников')
hasher=hashlib.sha256()
with (root/name).open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024*1024), b''): hasher.update(chunk)
actual=hasher.hexdigest()
if actual!=matches[0].split()[0]: raise SystemExit('SHA-256 исходников не совпадает')
digest=json.load(open(root/'resolved.json')).get('digest')
if digest and digest!='sha256:'+actual: raise SystemExit('SHA-256 не совпадает с метаданными GitHub')
destination=root/'source';destination.mkdir()
with tarfile.open(root/name) as archive:
    members=archive.getmembers()
    if len(members)>50000 or sum(m.size for m in members)>1024**3: raise SystemExit('Архив исходников слишком большой')
    paths=set()
    for m in members:
        p=pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not (m.isdir() or m.isfile()):
            raise SystemExit('Небезопасный путь или тип файла в архиве: '+m.name)
        if p in paths: raise SystemExit('Повторяющийся путь в архиве')
        paths.add(p)
    archive.extractall(destination, members=members, filter='data') if sys.version_info >= (3,12) else archive.extractall(destination,members=members)
kind=json.load(open(root/'resolved.json'))['kind']
required_files=['installer/installer.sh','installer/runtime.py','installer/database.cjs','installer/marzban.py','panel/backend/.env.sample']
required_files+=['installer/images.py','images.json','component-sources.json'] if kind=='runtime' else ['panel/Dockerfile','node/docker/Dockerfile','xray/core/core.go']
for required in required_files:
    if not (destination/required).is_file(): raise SystemExit('Неполный архив: '+required)
version=json.load(open(root/'resolved.json'))['tag'][1:]
if (destination/'VERSION').read_text().strip()!=version:
    raise SystemExit('VERSION не совпадает с тегом')
lock_path=destination/'component-sources.json'
lock=json.loads(lock_path.read_text()) if lock_path.is_file() else {}
if lock_path.is_file() and (not isinstance(lock,dict) or set(lock)!={'panel','node','core'}):
    raise SystemExit('Неверный список компонентов выпуска')
versions={}
for kind in ['panel','node','core']:
    entry=lock.get(kind,{})
    if not isinstance(entry,dict): raise SystemExit('Неверный компонент: '+kind)
    expected=entry.get('version',version)
    version_pattern=r'\d+\.\d+\.\d+'+(r'(?:\.\d+)?' if kind=='panel' else '')+r'(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?'
    if not isinstance(expected,str) or not re.fullmatch(version_pattern,expected):
        raise SystemExit('Неверная версия компонента: '+kind)
    versions[kind]=expected
if json.load(open(root/'resolved.json'))['kind']=='runtime':
    import subprocess
    subprocess.run([sys.executable,sys.argv[4],'validate','--root',str(destination),
        '--tag','v'+version,'--assets',str(root/'release.json'),'--repository',sys.argv[3]],check=True)
    (root/'source.sha256').write_text(actual+'\n')
    raise SystemExit(0)
for package in ['panel/frontend','panel/backend','node','subscription-page/frontend','subscription-page/backend']:
    actual_version=json.load(open(destination/package/'package.json'))['version']
    expected=versions['node' if package=='node' else 'panel']
    if actual_version!=expected:
        raise SystemExit('Версия исходников не совпадает с закреплённым компонентом: '+package)
core=(destination/'xray/core/core.go').read_text()
numbers=[re.search(rf'Version_{axis}\s+byte\s*=\s*(\d+)',core) for axis in 'xyz']
if not all(numbers) or '.'.join(m.group(1) for m in numbers)!=versions['core'].split('-')[0]:
    raise SystemExit('Версия Xray не совпадает с закреплённым компонентом')
(root/'source.sha256').write_text(actual+'\n')
PY
}

choose_version() {
    if [[ -z $VERSION ]]; then
        if [[ -t 0 ]] && ! $YES; then VERSION=$(ask 'Версия установки' latest); else VERSION=latest; fi
    fi
    valid_version "$VERSION" || die 'Версия: latest или SemVer'
}
release_source() {
    choose_version
    installed_helper
    if [[ $ACTION == install-panel ]]; then DOMAIN=$(ask_confirmed_domain 'Домен панели' "$DOMAIN") || return $?; fi
    if [[ $ACTION == install-node && -n $NODE_DOMAIN && $NODE_DOMAIN_CONFIRMED != "$NODE_DOMAIN" ]]; then
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$NODE_DOMAIN") || return $?
        NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN
    fi
    if [[ $ACTION == install-node && -z ${REMNACUST_NODE_SECRET:-} ]]; then
        ask_node_secret || return 1
    fi
    installed_helper
    prepare_helpers_install
    TAG=$(resolve_release)
    step "Проверка выпуска $TAG" fetch_source
    SOURCE="$WORK/source"
    bash -n "$SOURCE/installer/installer.sh"
    [[ -f $SOURCE/images.json ]] || die 'В этом старом выпуске нет готовых Docker-образов. Выберите latest; сборка на сервере отключена.'
    python3 "$HELPER_ROOT/images.py" select --root "$SOURCE" --tag "$TAG" --assets "$WORK/release.json" \
        --repository "$REPO" --component "$COMPONENT" --architecture "$(dpkg --print-architecture)" > "$WORK/image.json"
    IMAGE=$(image_field image)
    COMPONENT_VERSION=$(image_field version)
}
installed_helper() {
    [[ -z $HELPER_ROOT ]] || return 0
    HELPER_ROOT=$(python3 -I - "$ENTRY_SCRIPT_PATH" "$WORK" "$HELPER_BUNDLE_SHA256" <<'PY'
import base64,gzip,hashlib,io,json,pathlib,re,sys,tarfile
entry=pathlib.Path(sys.argv[1]).resolve();body=entry.read_bytes().replace(b'\r\n',b'\n');work=pathlib.Path(sys.argv[2]);expected=sys.argv[3]
destination=work/('helpers-'+expected);contract='helper-contract.json';footer=b'\n# REMNACUST_HELPERS_V1\n';cache=pathlib.Path('/usr/local/lib/remnacust-installer/helpers')
def read(path,limit):
    if path.is_symlink() or not path.is_file():raise ValueError('not a regular helper')
    with path.open('rb') as stream:data=stream.read(limit+1)
    if len(data)>limit:raise ValueError('helper too large')
    return data.replace(b'\r\n',b'\n')
def module(raw,code):
    if hashlib.sha256(raw).hexdigest()!=expected:raise ValueError('helper manifest mismatch')
    item=json.loads(raw)['files']['helper_bundle.py']
    if len(code)!=item['bytes'] or hashlib.sha256(code).hexdigest()!=item['sha256']:raise ValueError('helper verifier mismatch')
    namespace={'__name__':'verified_helper_bundle','__file__':'<verified helper_bundle.py>'}
    exec(compile(code,namespace['__file__'],'exec'),namespace)
    return namespace
def finish(raw,files,verified):
    verified['snapshot'](body,raw,files,destination)
    saved=work/('helper-entry-'+expected+'.sh');saved.write_bytes(body);saved.chmod(0o600)
    print(destination);raise SystemExit(0)
hints=re.findall(rb'(?m)^# CACHE ([a-f0-9]{64}(?:-[a-f0-9]{32})?)$',body)
locations=[entry.parent]+([cache/hints[0].decode()] if len(hints)==1 else [])+[cache/expected]
for location in locations:
    try:
        raw=read(location/contract,32768);verified=module(raw,read(location/'helper_bundle.py',2*1024*1024))
        finish(raw,verified['read_files'](location,raw,source=location==entry.parent and location.name=='installer'),verified)
    except (OSError,ValueError,KeyError,TypeError):pass
try:
    tail=body.split(footer)[1]
    encoded=b''.join(line[7:] for line in tail.splitlines() if line.startswith(b'# DATA '))
    if not encoded or len(encoded)>6*1024*1024:raise ValueError('invalid helper payload')
    with gzip.GzipFile(fileobj=io.BytesIO(base64.b64decode(encoded,validate=True))) as stream:data=stream.read(16*1024*1024+1)
    if len(data)>16*1024*1024:raise ValueError('helper payload too large')
    files={}
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:') as archive:
        members=archive.getmembers()
        if len(members)>33:raise ValueError('too many helpers')
        for member in members:
            if not member.isfile() or member.size>2*1024*1024 or '/' in member.name or '\\' in member.name or member.name in files:raise ValueError('unsafe helper payload')
            files[member.name]=archive.extractfile(member).read()
    raw=files.pop(contract);verified=module(raw,files['helper_bundle.py']);finish(raw,files,verified)
except Exception:pass
raise SystemExit('Не найден проверенный комплект помощников этого скрипта. Используйте installer.sh из выпуска или полный каталог исходников; данные не изменены.')
PY
    ) || return $?
    HELPER="$HELPER_ROOT/runtime.py"
    HELPER_ENTRY="$WORK/helper-entry-$HELPER_BUNDLE_SHA256.sh"
}
prepare_helpers_install() {
    installed_helper
    [[ -z $INSTALLED_HELPER_ROOT ]] || return 0
    INSTALLED_HELPER_ROOT=$(python3 -I "$HELPER_ROOT/helper_bundle.py" install --entry "$HELPER_ENTRY" --cohort "$HELPER_ROOT" \
        --cache-root "${1:-/usr/local/lib/remnacust-installer/helpers}" --output "$WORK/installer-entry.sh")
}
lock_operation() {
    command -v flock >/dev/null || die 'Нужен util-linux (flock)'
    mkdir -p "$ROOT/registry"
    exec 9>"$ROOT/.installer.lock"
    flock -n 9 || die 'Другой установщик уже работает'
}
database_environment() {
    python3 - "$WORK/container.before.json" "$WORK/database.env" <<'PY'
import json,pathlib,sys
c=json.load(open(sys.argv[1]))[0];e=dict(x.split('=',1) for x in c['Config']['Env'] if '=' in x)
values={k:e[k] for k in ['DATABASE_URL','APP_SECRET'] if k in e}
if any('\n' in v or '\r' in v for v in values.values()):raise SystemExit('Unsupported database environment')
pathlib.Path(sys.argv[2]).write_text(''.join(k+'='+v+'\n' for k,v in values.items()))
PY
    python3 - "$WORK/container.before.json" "$WORK/database-networks.txt" <<'PY'
import json,pathlib,sys
c=json.load(open(sys.argv[1]))[0]
networks=c.get('NetworkSettings',{}).get('Networks') or {}
pathlib.Path(sys.argv[2]).write_text(''.join(name+'\n' for name in networks))
PY
    local network
    local -a ids=()
    : > "$WORK/database-peer-ids.txt"
    while IFS= read -r network; do
        docker ps --quiet --filter "network=$network" >> "$WORK/database-peer-ids.txt"
    done < "$WORK/database-networks.txt"
    mapfile -t ids < <(sort -u "$WORK/database-peer-ids.txt")
    if ((${#ids[@]})); then
        docker inspect "${ids[@]}" | python3 -c '
import json,sys
peers=json.load(sys.stdin)
json.dump([{"Id":c.get("Id"),"Name":c.get("Name"),
           "State":{"Running":c.get("State",{}).get("Running")},
           "NetworkSettings":{"Networks":c.get("NetworkSettings",{}).get("Networks") or {}}}
          for c in peers],sys.stdout)
' > "$WORK/network-containers.json"
    else printf '[]\n' > "$WORK/network-containers.json"; fi
    helper database-network --inspect "$WORK/container.before.json" --roles "$WORK/network-containers.json" \
        --network "${REMNACUST_DATABASE_NETWORK:-}" --target "$WORK/database.network"
}
database_run() {
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" \
        --entrypoint node "$IMAGE" - "$@" < "$(dirname "$HELPER")/database.cjs"
}
verify_database() {
    # The verified helper script and the snapshot use separate input channels.
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" \
        --mount "type=bind,src=$(dirname "$HELPER")/database.cjs,dst=/tmp/verify.cjs,readonly" \
        --entrypoint node "$IMAGE" /tmp/verify.cjs verify < "$BACKUP/fingerprints.json"
}
check_writers() {
    local -a ids=(); mapfile -t ids < <(docker ps --quiet)
    ((${#ids[@]})) || return 0
    docker inspect "${ids[@]}" > "$WORK/running-containers.json"
    python3 - "$WORK/running-containers.json" "$WORK/container.before.json" "$PROJECT" <<'PY'
import json,sys
env=lambda c:dict(s.split('=',1) for s in c['Config'].get('Env',[]) if '=' in s)
database=env(json.load(open(sys.argv[2]))[0]).get('DATABASE_URL')
for c in json.load(open(sys.argv[1])):
 if database and env(c).get('DATABASE_URL')==database and (c['Config'].get('Labels') or {}).get('com.docker.compose.project')!=sys.argv[3]:
  raise SystemExit('Found an external application using this database; stop it before migration')
PY
}
backup_hashes() {
    helper hash-backup --directory "$BACKUP"
}
validate_node_key() {
    python3 - "$WORK/node-check.env" <<'PY'
import os,pathlib,sys
pathlib.Path(sys.argv[1]).write_text('SECRET_KEY='+os.environ['REMNACUST_NODE_SECRET']+'\n')
PY
    docker run --rm -i --env-file "$WORK/node-check.env" --entrypoint node "$IMAGE" - <<'JS'
const crypto=require('node:crypto');
try {
 const p=JSON.parse(Buffer.from(process.env.SECRET_KEY,'base64').toString());
 const ca=new crypto.X509Certificate(p.caCertPem),cert=new crypto.X509Certificate(p.nodeCertPem);
 const key=crypto.createPrivateKey(p.nodeKeyPem);crypto.createPublicKey(p.jwtPublicKey);
 if (!ca.verify(ca.publicKey)||!cert.verify(ca.publicKey)||!cert.checkPrivateKey(key)||Date.parse(cert.validTo)<Date.now()||Date.parse(cert.validFrom)>Date.now()||Date.parse(ca.validTo)<Date.now())throw Error();
}catch{console.error('Invalid or expired node certificate package');process.exit(1)}
JS
}
backup_password_wizard() {
    local password=${REMNACUST_BACKUP_PASSWORD:-} repeated
    while true; do
        if [[ -z $password && -t 0 ]]; then
            printf '  Защита резервных копий · 16–256 символов без пробелов. Enter — создать пароль автоматически.\n' >&2
            IFS= read -r -s -p 'Пароль резервных копий: ' password || return 1
            printf '\n' >&2
            if [[ -n $password ]]; then
                IFS= read -r -s -p 'Повторите пароль: ' repeated || return 1
                printf '\n' >&2
                if [[ $password != "$repeated" ]]; then
                    printf '  Пароли не совпадают.\n' >&2; password=''; continue
                fi
            fi
        fi
        if [[ -z $password ]]; then password=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))'); fi
        if REMNACUST_BACKUP_PASSWORD="$password" python3 - "$WORK/backup-password.txt" <<'PY'
import os,re,sys
password=os.environ['REMNACUST_BACKUP_PASSWORD']
if not re.fullmatch(r'[\x21-\x7e]{16,256}',password): raise SystemExit(1)
fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w') as file: file.write(password)
PY
        then break; fi
        [[ -t 0 && -z ${REMNACUST_BACKUP_PASSWORD:-} ]] || die 'Пароль резервных копий должен содержать 16–256 символов ASCII без пробелов'
        printf '  Нужно 16–256 символов ASCII без пробелов.\n' >&2; password=''
    done
    unset REMNACUST_BACKUP_PASSWORD
}
initialize_panel_backups() {
    local encrypted
    # Fresh Compose has an image only, so run never builds it; refuse any pull here.
    compose run --rm --no-deps --pull never -T --entrypoint node \
        -v "$DEPLOY/backup-password.txt:/run/remnacust-backup-password:ro" "$(get mainService)" - \
        > "$WORK/backup-envelope" <<'JS'
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
try {
    const password = fs.readFileSync('/run/remnacust-backup-password');
    if (!/^[\x21-\x7e]{16,256}$/.test(password.toString()) || !process.env.APP_SECRET) throw Error();
    const directory = process.env.XERA_BACKUPS_DIR || '/opt/app/backups';
    if (!fs.lstatSync(directory).isDirectory()) throw Error();
    fs.chmodSync(directory, 0o700);
    const salt = crypto.randomBytes(16);
    const derived = crypto.scryptSync(password, salt, 32);
    fs.writeFileSync(path.join(directory, '.backup-key'), Buffer.concat([salt, derived]), {flag: 'wx', mode: 0o600});
    const key = crypto.createHmac('sha256', process.env.APP_SECRET).update('xera-keyring-v1').digest();
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
    const ciphertext = Buffer.concat([cipher.update(password), cipher.final()]);
    process.stdout.write('xera1:' + Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64'));
    password.fill(0); derived.fill(0); key.fill(0);
} catch {
    console.error('Не удалось подготовить защиту резервных копий. Проверьте доступ к тому backups.');
    process.exitCode = 1;
}
JS
    encrypted=$(cat "$WORK/backup-envelope")
    [[ $encrypted =~ ^xera1:[A-Za-z0-9+/=]+$ ]] || return 1
    # Override a sample value without putting the password in arguments or the log.
    sed -i '/^XERA_BACKUP_PASSWORD_ENC=/d' "$DEPLOY/.env"
    printf '\nXERA_BACKUP_PASSWORD_ENC=%s\n' "$encrypted" >> "$DEPLOY/.env"
}

panel_net_admin_wizard() {
    [[ $COMPONENT == panel ]] || return 0
    if [[ -t 0 ]] && ! $YES && ! $PANEL_NET_ADMIN_SET; then
        info 'NET_ADMIN разрешает управление сетью внутри контейнера панели.'
        info 'Для сетевых ограничений и закрытия соединений разрешите NET_ADMIN на нодах при их установке.'
        local choice
        choice=$(ask_yes_no 'Добавить NET_ADMIN контейнеру панели?') || return $?
        PANEL_NET_ADMIN=false; [[ $choice != yes ]] || PANEL_NET_ADMIN=true
        PANEL_NET_ADMIN_SET=true
    fi
    if $PANEL_NET_ADMIN && ! python3 "$HELPER" --help | grep -q -- '--panel-net-admin'; then
        die 'Этот выпуск не поддерживает выбор NET_ADMIN панели. Выберите latest.'
    fi
}

node_effective_net_admin() {
    local id=${1:-${CONTAINER:-}}
    if [[ -z ${1:-} && -n ${WORK:-} && -f $WORK/container.before.json ]]; then
        id=$(python3 -c 'import json,sys;v=json.load(open(sys.argv[1]));print((v[0] if isinstance(v,list) else v).get("Id",""))' "$WORK/container.before.json") || return 1
    fi
    [[ -n $id ]] || return 1
    # Read the effective capability of an actual process in this container.
    timeout 10 docker exec "$id" node -e 'const fs=require("node:fs");const m=fs.readFileSync("/proc/self/status","utf8").match(/^CapEff:\s*([a-f0-9]+)/mi);if(!m)process.exit(2);process.stdout.write((BigInt("0x"+m[1])&(1n<<12n))!==0n?"yes":"no")' 2>/dev/null
}
node_net_admin_wizard() {
    [[ $COMPONENT == node ]] || return 0
    local choice enabled=no effective=unknown
    if [[ -n ${1:-} ]]; then
        enabled=$(helper node-capability --source "$1" --state "$STATE")
        effective=$(node_effective_net_admin) || effective=unknown
        if [[ $effective == yes ]]; then
            if [[ $enabled != yes ]]; then
                helper node-capability --source "$1" --state "$STATE" --key enable >/dev/null
            fi
            info 'NET_ADMIN ноды включён; право сохранится после обновления.'
            NODE_NET_ADMIN=true
            return 0
        fi
        if [[ $enabled == yes ]]; then
            info 'NET_ADMIN указан в Compose, но фактическое право контейнера не подтверждено.'
        fi
        NODE_NET_ADMIN=false
    fi
    if $PANEL_NET_ADMIN_SET; then
        NODE_NET_ADMIN=$PANEL_NET_ADMIN
    elif [[ -t 0 ]] && ! $YES; then
        info 'NET_ADMIN нужен для сетевых ограничений и принудительного закрытия соединений. Без него эти возможности ограничены.'
        choice=$(ask_yes_no 'Добавить NET_ADMIN контейнеру ноды?') || return $?
        NODE_NET_ADMIN=false; [[ $choice != yes ]] || NODE_NET_ADMIN=true
    fi
    if [[ -n ${1:-} ]] && $NODE_NET_ADMIN; then
        helper node-capability --source "$1" --state "$STATE" --key enable >/dev/null
        NODE_NET_ADMIN_ADDED=true
    fi
}


subscription_panel_endpoint() {
    local endpoint=${PAGE_PANEL_URL:-} choice
    if [[ -z $endpoint && -f $ROOT/registry/panel.json ]]; then
        endpoint=auto
        if [[ -t 0 ]] && ! $YES; then
            choice=$(ask_yes_no 'Использовать локальную панель для страницы подписки?' y) || return $?
            [[ $choice == yes ]] || endpoint=''
        fi
    fi
    while true; do
        [[ -n $endpoint ]] || endpoint=$(ask_required 'HTTPS адрес панели') || return $?
        if [[ $endpoint == auto ]]; then printf auto; return; fi
        if ! endpoint=$(python3 -I "$HELPER_ROOT/subscription_pages.py" panel-url --root "$ROOT" --panel-url "$endpoint"); then
            [[ -t 0 ]] && ! $YES || return 1
            printf '  Укажите HTTPS адрес панели без пути, пароля и параметров.\n' >&2
            endpoint=''; continue
        fi
        if [[ -t 0 ]] && ! $YES; then
            choice=$(ask_yes_no "Использовать панель $endpoint?" y) || return $?
            if [[ $choice != yes ]]; then endpoint=''; continue; fi
        fi
        printf '%s' "$endpoint"; return
    done
}
subscription_page_token() {
    local endpoint=$1 token_file=$2
    if [[ -n $PAGE_TOKEN_FILE ]]; then
        python3 -I "$HELPER_ROOT/subscription_pages.py" token-file --root "$ROOT" --token-file "$PAGE_TOKEN_FILE" --target "$token_file" || return $?
    elif [[ -n ${REMNACUST_SUBSCRIPTION_TOKEN:-} ]]; then
        printf '%s' "$REMNACUST_SUBSCRIPTION_TOKEN" > "$token_file"
    elif [[ $endpoint == auto ]]; then
        local panel_id
        panel_id=$(python3 -I - "$ROOT/registry/panel.json" "$HELPER_ROOT" <<'PY'
import json,sys
sys.path.insert(0,sys.argv[2])
from subscription_pages import inspect
s=json.load(open(sys.argv[1]));c=inspect({**s,'service':s['mainService']})
if not c or not c.get('State',{}).get('Running'):raise SystemExit('Локальная панель не запущена')
print(c['Id'])
PY
        )
        local reuse_env="$WORK/subscription-reuse.env"
        python3 -I "$HELPER_ROOT/subscription_pages.py" reuse-token-env --root "$ROOT" --directory "$DEPLOY" --project "$PROJECT" --token-file "$reuse_env"
        docker exec -i --env-file "$reuse_env" --env "REMNACUST_SUBSCRIPTION_TOKEN_UUID=$(python3 -c 'import uuid;print(uuid.uuid4())')" "$panel_id" node - < "$HELPER_ROOT/subscription.cjs" > "$token_file"
        rm -f -- "$reuse_env"
    else
        if [[ -t 0 ]]; then
            local token
            while true; do
                read -r -s -p 'API-токен с правами страницы подписки: ' token || return 1
                printf '\n' >&2
                [[ -z $token ]] || break
                info 'Пустой токен: повторите ввод.'
            done
            printf '%s' "$token" > "$token_file"; unset token
        else die 'Нужен REMNACUST_SUBSCRIPTION_TOKEN или локальная панель (--panel-url auto)'; fi
    fi
    chmod 600 "$token_file"
}

migrate_subscription_page_action() {
    installed_helper
    local script="$HELPER_ROOT/subscription_pages.py" count index=1 selected_container needs_connection endpoint token_file result
    local -a selectors=() connection_options=()
    [[ -z $CONTAINER ]] || selectors+=(--container "$CONTAINER")
    [[ -z $DIRECTORY ]] || selectors+=(--directory "$DIRECTORY")
    [[ -z $COMPOSE_FILE$PROJECT ]] || die 'Выберите существующую страницу через --container или --directory; её Compose-проект сохраняется.'
    python3 -I "$script" migration-candidates --root "$ROOT" "${selectors[@]}" > "$WORK/page-migration-candidates.json" || return $?
    count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$WORK/page-migration-candidates.json")
    if ((count == 0)); then
        [[ -z $CONTAINER$DIRECTORY ]] || die 'Указанный источник не распознан; его контейнеры и файлы не изменены. Проверьте --container/--directory либо выберите install-subscription-page для новой установки.'
        info 'Страница для переноса не найдена. Открываем мастер установки: укажите панель, API-токен, домен и порт. Существующие контейнеры и файлы не перезаписываются.'
        ACTION=install-subscription-page
        subscription_page_action
        return $?
    fi
    lock_operation
    python3 - "$WORK/page-migration-candidates.json" <<'PYMIGRATE'
import json,sys
for number,item in enumerate(json.load(open(sys.argv[1])),1):
    print(f"  {number}. {item['project']}/{item['service']} · {item['directory']}")
PYMIGRATE
    if ((count > 1)); then
        [[ -t 0 ]] || die 'Найдено несколько страниц; укажите точный --container или --directory.'
        while true; do
            index=$(ask_required 'Номер страницы для переноса') || return $?
            if [[ $index =~ ^[0-9]{1,3}$ ]] && ((10#$index >= 1 && 10#$index <= count)); then index=$((10#$index)); break; fi
            printf '  Выберите номер от 1 до %s.\n' "$count" >&2
        done
    fi
    selected_container=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[int(sys.argv[2])-1]["container"])' "$WORK/page-migration-candidates.json" "$index")
    needs_connection=$(python3 -c 'import json,sys;print("yes" if json.load(open(sys.argv[1]))[int(sys.argv[2])-1].get("needsConnection") else "no")' "$WORK/page-migration-candidates.json" "$index")
    prepare_host; choose_version
    confirm "Перенести выбранную страницу подписки на Remnacust ($VERSION); подключение к панели и настройки сохраняются"
    release_source; select_subscription_image
    step 'Готовый образ сайта подписки' prepare_subscription_image
    if [[ $needs_connection == yes || -n $PAGE_PANEL_URL$PAGE_TOKEN_FILE ]]; then
        info 'Укажите подключение страницы к панели; изменения будут применены только после проверки адреса и API-токена.'
        endpoint=$(subscription_panel_endpoint) || return $?
        token_file="$WORK/page-migration-token.txt"
        subscription_page_token "$endpoint" "$token_file" || return $?
        connection_options=(--panel-url "$endpoint" --token-file "$token_file")
    fi
    result=0
    step 'Перенос страницы подписки' python3 -I "$script" migrate --root "$ROOT" --container "$selected_container" --image "$SUBSCRIPTION_IMAGE" --version "$SUBSCRIPTION_IMAGE_VERSION" --release "$TAG" "${connection_options[@]}" || result=$?
    [[ -z ${token_file:-} ]] || rm -f -- "$token_file"
    ((result == 0)) || return "$result"
    install_cli
    info 'Страница перенесена. Домен, API-токен, сети, тома и состояние запуска сохранены. Панель не обновлялась.'
    if [[ ${REMNACUST_MENU_COMPLETION_FD:-} == 3 ]]; then printf 'completed\n' >&3; fi
}

subscription_page_action() {
    local script choice token_file endpoint
    if [[ $ACTION == uninstall-subscription-page ]]; then
        command -v python3 >/dev/null || die 'Для удаления нужен python3'
        command -v docker >/dev/null || die 'Docker недоступен'
        lock_operation
        installed_helper
        select_managed_page || return $?
        info 'Удаляется только выбранная страница и её отдельный proxy, если он принадлежит этой странице. Панель, БД, настройки и тома сохраняются.'
        confirm "Удалить страницу подписки $PAGE_ID"
        local archive
        archive=$(python3 -I "$HELPER_ROOT/subscription_pages.py" uninstall --root "$ROOT" --page-id "$PAGE_ID") || return $?
        info "Страница подписки удалена. Настройки сохранены на месте; копия Compose: $archive"
        return
    fi
    if [[ $ACTION == configure-subscription-page ]]; then
        command -v python3 >/dev/null || die 'Для настройки нужен python3'
        command -v docker >/dev/null || die 'Docker недоступен'
        lock_operation; installed_helper
        select_managed_page || return $?
        local info_file="$WORK/page-connection-info.json"
        python3 -I "$HELPER_ROOT/subscription_pages.py" connection-info --root "$ROOT" --page-id "$PAGE_ID" > "$info_file" || return $?
        DEPLOY=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["directory"])' "$info_file")
        PROJECT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["project"])' "$info_file")
        endpoint=$(subscription_panel_endpoint) || return $?
        confirm 'Сменить панель и API-токен страницы подписки; при ошибке сохранить прежнее подключение'
        token_file="$WORK/subscription-token.txt"
        subscription_page_token "$endpoint" "$token_file" || return $?
        python3 -I "$HELPER_ROOT/subscription_pages.py" configure --root "$ROOT" --page-id "$PAGE_ID" --panel-url "$endpoint" --token-file "$token_file" || return $?
        rm -f -- "$token_file"
        info 'Панель и токен страницы обновлены. Прежняя конфигурация сохранена в backups; состояние запуска страницы сохранено.'
        return
    fi
    if [[ $ACTION == manage-subscription-page ]]; then
        command -v python3 >/dev/null || die 'Для управления нужен python3'
        command -v docker >/dev/null || die 'Docker недоступен'
        lock_operation
        installed_helper
        script="$HELPER_ROOT/subscription_pages.py"
        [[ -f $script ]] || die 'Обновите установщик: управление страницами недоступно в старом выпуске'
        case "${PAGE_OPERATION:-list}" in list|status|logs|start|stop|restart) ;; *) die 'Действие страницы: list, status, logs, start, stop, restart';; esac
        if [[ ${PAGE_OPERATION:-list} == list ]]; then
            python3 -I "$script" list --root "$ROOT"
            [[ -t 0 ]] || return 0
            select_managed_page || return $?
            COMPONENT=subscription-page
            component_menu || return $?
            [[ -n $ACTION ]] || return 0
            if [[ $ACTION == change-domain || $ACTION == show-config ]]; then manage_component_action; return; fi
            if [[ $ACTION == uninstall-subscription-page || $ACTION == configure-subscription-page ]]; then subscription_page_action; return; fi
            PAGE_OPERATION=$ACTION
        fi
        if [[ -z $PAGE_ID ]]; then
            select_managed_page || return $?
        fi
        case "$PAGE_OPERATION" in status|logs) ;; *) confirm "$PAGE_OPERATION страницы $PAGE_ID";; esac
        python3 -I "$script" "$PAGE_OPERATION" --root "$ROOT" --page-id "$PAGE_ID"
        return
    fi
    if [[ $ACTION == install-subscription-page ]]; then
        installed_helper
        local target_project=${PROJECT:-remnacust-subscription-page} target_directory=${DIRECTORY:-$ROOT/subscription-page} existing
        if [[ -z $DIRECTORY && $target_project != remnacust-subscription-page ]]; then target_directory="$ROOT/subscription-pages/$target_project"; fi
        existing=$(python3 -I "$HELPER_ROOT/subscription_pages.py" existing-target --root "$ROOT" --directory "$target_directory" --project "$target_project") || return $?
        if [[ $existing != null ]]; then
            PAGE_ID=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["id"])' "$existing")
            python3 -c 'import json,sys;v=json.loads(sys.argv[1]);print("  Страница уже установлена: "+v["name"]+" · "+v["domain"])' "$existing"
            [[ -t 0 ]] || die "Повторная установка не нужна. Используйте upgrade-subscription-page --page-id $PAGE_ID или manage-subscription-page --page-id $PAGE_ID."
            info 'Открываем управление существующей страницей; новая копия и новый токен не создаются.'
            ACTION=manage-subscription-page; PAGE_OPERATION=list
            subscription_page_action
            return
        fi
    fi
    prepare_host; lock_operation
    choose_version
    confirm "Выполнить $ACTION ($VERSION)"
    release_source
    script="$HELPER_ROOT/subscription_pages.py"
    select_subscription_image
    step 'Готовый образ сайта подписки' prepare_subscription_image
    if [[ $ACTION == install-subscription-page && -z $PROJECT && -z $DIRECTORY ]]; then
        local owner
        owner=$(python3 -I "$script" reuse-port --root "$ROOT" --port "${PORT:-$SUBSCRIPTION_PORT}") || return $?
        if [[ $owner != null ]]; then
            PAGE_ID=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["id"])' "$owner")
            if [[ -n $DOMAIN ]]; then
                local current_domain
                current_domain=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["domain"])' "$owner")
                [[ $DOMAIN == "$current_domain" ]] || die 'На этом порту уже работает ваша страница. Сначала обновите её без --domain; смена адреса доступна в управлении страницей.'
            fi
            info "Порт ${PORT:-$SUBSCRIPTION_PORT} занят нашей страницей: обновляем её на месте. Пересоздаётся только контейнер страницы; токен, настройки и остальные сервисы сохраняются."
            ACTION=upgrade-subscription-page
        fi
    fi
    if [[ $ACTION == upgrade-subscription-page ]]; then
        if [[ -z $PAGE_ID ]]; then
            python3 -I "$script" list --root "$ROOT"
            PAGE_ID=$(ask_required 'ID страницы для обновления') || return $?
        fi
        python3 -I "$script" upgrade --root "$ROOT" --page-id "$PAGE_ID" --image "$SUBSCRIPTION_IMAGE" --version "$SUBSCRIPTION_IMAGE_VERSION" --release "$TAG"
        python3 -I "$HELPER_ROOT/deployment_layout.py" --root "$ROOT" --cleanup-backups --component subscription-page
        info "Страница подписки обновлена до $SUBSCRIPTION_IMAGE_VERSION; состояние запуска сохранено."
        if [[ ${REMNACUST_MENU_COMPLETION_FD:-} == 3 ]]; then printf 'completed\n' >&3; fi
        return
    fi
    endpoint=$(subscription_panel_endpoint) || return $?
    DOMAIN=$(ask_confirmed_domain 'Домен страницы подписки' "$DOMAIN") || return $?
    PROJECT=${PROJECT:-remnacust-subscription-page}
    DEPLOY=${DIRECTORY:-$ROOT/subscription-page}
    if [[ -z $DIRECTORY && $PROJECT != remnacust-subscription-page ]]; then DEPLOY="$ROOT/subscription-pages/$PROJECT"; fi
    PORT=$(choose_subscription_port "${PORT:-$SUBSCRIPTION_PORT}") || return $?
    if ! $PROXY_SET; then
        PROXY=existing
        if [[ -t 0 ]] && ! $YES; then
            choice=$(ask_yes_no 'Установить отдельный Caddy для HTTPS? Только если порты 80/443 свободны') || return $?
            [[ $choice != yes ]] || PROXY=caddy
        fi
    fi
    if [[ $PROXY == caddy ]]; then port_free 80; port_free 443; docker pull caddy:2-alpine; fi
    token_file="$WORK/subscription-token.txt"
    subscription_page_token "$endpoint" "$token_file" || return $?
    chmod 600 "$token_file"
    PAGE_ID=$(python3 -I "$script" install --root "$ROOT" --directory "$DEPLOY" --project "$PROJECT" --panel-url "$endpoint" --token-file "$token_file" --port "$PORT" --image "$SUBSCRIPTION_IMAGE" --domain "$DOMAIN" --proxy "$PROXY")
    rm -f -- "$token_file"
    install_cli
    info "Страница установлена. ID: $PAGE_ID. Каталог: $DEPLOY"
    info "Версия страницы подписки: $SUBSCRIPTION_IMAGE_VERSION. Установка страницы не обновляет панель."
    [[ $PROXY != existing ]] || info "Направьте HTTPS домена $DOMAIN на 127.0.0.1:$PORT в вашем reverse proxy."
    if [[ ${REMNACUST_MENU_COMPLETION_FD:-} == 3 ]]; then printf 'completed\n' >&3; fi
}

subscription_wizard() {
    local normalized preset=false choice operation=subscription-urls
    [[ -z $SUBSCRIPTION_URLS && $SUBSCRIPTION_SET == false ]] || preset=true
    if ! python3 "$HELPER" --help | grep -q -- '--subscription-urls'; then
        if $preset || $SUBSCRIPTION_PAGE; then die 'Этот выпуск не поддерживает адреса сайта подписки. Выберите latest.'; fi
        return 0
    fi
    if [[ -t 0 ]] && ! $YES && ! $SUBSCRIPTION_PAGE_SET; then
        info 'Сайт подписки — отдельная страница для пользователей; нужен отдельный домен.'
        choice=$(ask_yes_no 'Установить сайт подписки?') || return $?
        [[ $choice != yes ]] || SUBSCRIPTION_PAGE=true
    fi
    if $SUBSCRIPTION_PAGE; then
        [[ -f ${HELPER%/*}/subscription.cjs ]] && python3 "$HELPER" --help | grep -q -- '--subscription-image' || die 'Для установки сайта подписки выберите latest.'
        operation=subscription-domains
    elif ! $preset; then
        SUBSCRIPTION_URLS="https://$DOMAIN/api/sub"
        info 'Сайт подписки не устанавливается; ссылки выдаёт панель. Позже: remnacust install-subscription-page.'
        return 0
    fi
    while true; do
        if [[ -t 0 ]] && ! $YES && ! $preset; then
            info 'Укажите один или два отдельных домена через запятую; первый — основной.'
            info "HTTPS сайта: тот же способ, что у панели ($PROXY / ${TLS_METHOD:-ваш proxy})."
            SUBSCRIPTION_URLS=$(ask_required 'Домены сайта подписки') || return $?
        fi
        if normalized=$(helper "$operation" --domain "$DOMAIN" --subscription-urls "$SUBSCRIPTION_URLS"); then
            if [[ -t 0 ]] && ! $YES; then
                choice=$(ask_yes_no "Использовать адреса сайта подписки: ${normalized//$'\n'/, }?" y) || return $?
                if [[ $choice != yes ]]; then preset=false; SUBSCRIPTION_URLS=''; continue; fi
            fi
            if $SUBSCRIPTION_PAGE; then
                SUBSCRIPTION_URLS="https://${normalized//$'\n'/,https://}"
            else SUBSCRIPTION_URLS=${normalized//$'\n'/,}; fi
            if $SUBSCRIPTION_PAGE; then info "Будет установлен сайт подписки: $SUBSCRIPTION_URLS"
            else info "Используем существующий сайт: $SUBSCRIPTION_URLS; новый контейнер сайта не создаётся."; fi
            return 0
        fi
        [[ -t 0 ]] && ! $YES && ! $preset || die 'Исправьте --subscription-urls: один или два адреса сайта подписки'
    done
}
panel_ipv6_candidate() {
    [[ $COMPONENT == panel ]] || return 0
    case "$ACTION" in install-panel|upgrade-panel|migrate-remnawave-panel) ;; *) return 0;; esac
    helper panel-ipv6 --source "$1" --state "$STATE" --key "$PANEL_IPV6_MODE"
}
fresh_files() {
    local -a subscription_options=()
    local -a capability_options=()
    if [[ $COMPONENT == panel ]] && $PANEL_NET_ADMIN; then capability_options=(--panel-net-admin); fi
    if [[ $COMPONENT == node ]] && ! $NODE_NET_ADMIN; then capability_options=(--node-no-net-admin); fi
    if [[ $COMPONENT == node ]]; then capability_options+=(--node-site-mode "${NODE_SITE_MODE:-selfsteal}" --node-site-port "${NODE_SITE_PORT:-443}" --node-inbound-port "${NODE_INBOUND_PORT:-8443}"); fi
    [[ $COMPONENT != panel || -z $SUBSCRIPTION_URLS ]] || subscription_options=(--subscription-urls "$SUBSCRIPTION_URLS")
    if [[ $COMPONENT == panel ]] && $SUBSCRIPTION_PAGE; then
        subscription_options+=(--subscription-image "$SUBSCRIPTION_IMAGE" --subscription-port "$SUBSCRIPTION_PORT")
    fi
    DEPLOY=${DIRECTORY:-$ROOT/$COMPONENT}; PROJECT=${PROJECT:-remnacust-$COMPONENT}
    [[ $DEPLOY == /* && $DEPLOY != / && ! -L $DEPLOY ]] || die 'Укажите безопасный абсолютный каталог'
    if [[ -d $DEPLOY ]] && [[ -n $(find "$DEPLOY" -mindepth 1 -maxdepth 1 -print -quit) ]]; then die 'Каталог не пуст: выберите upgrade или migrate'; fi
    if [[ -e $ROOT/registry/$COMPONENT.json || -L $ROOT/registry/$COMPONENT.json ]]; then
        [[ -n $REINSTALL_RECORD && ! -L $ROOT/registry/$COMPONENT.json ]] && cmp -- "$REINSTALL_RECORD" "$ROOT/registry/$COMPONENT.json" >/dev/null || die 'Компонент уже зарегистрирован'
    fi
    if [[ $COMPONENT == panel ]]; then
        [[ -z $NODE_DOMAIN$PANEL_IP ]] || die '--node-domain и --panel-ip предназначены для install-node'
        [[ -n $DOMAIN ]] || DOMAIN=$(ask_confirmed_domain 'Домен панели') || return $?
        PORT=${PORT:-3000}
    else
        PORT=${PORT:-2222}
        if [[ -z ${REMNACUST_NODE_SECRET:-} ]]; then
            ask_node_secret || return 1
        fi
        export REMNACUST_NODE_SECRET
    fi
    local -a validation=(--domain "$DOMAIN" --node-domain "$NODE_DOMAIN" --port "$PORT" --project "$PROJECT")
    [[ -z $PANEL_IP ]] || validation+=(--key "$PANEL_IP")
    helper validate "${validation[@]}"
    local project_containers
    project_containers=$(docker ps --all --quiet --filter "label=com.docker.compose.project=$PROJECT") || die 'Не удалось повторно проверить проект Compose: Docker недоступен'
    [[ -z $project_containers ]] || die 'Проект Compose уже существует; используйте upgrade или migrate'
    if project_has_volumes "$PROJECT"; then die 'Тома выбранного проекта уже существуют; для новой установки выберите другое --project-name'; fi
    port_free "$PORT"
    if [[ $COMPONENT == panel && $PROXY == caddy ]]; then port_free 80; port_free 443; fi
    if [[ $COMPONENT == node ]]; then step 'Проверка ключа ноды' validate_node_key; fi
    mkdir -p "$DEPLOY"; chmod 700 "$DEPLOY"
    if [[ $COMPONENT == panel ]]; then
        [[ -f $WORK/backup-password.txt && ! -L $WORK/backup-password.txt ]] || backup_password_wizard
        cp -- "$WORK/backup-password.txt" "$DEPLOY/backup-password.txt"; chmod 600 "$DEPLOY/backup-password.txt"
        helper panel-env --source "$SOURCE/panel/backend/.env.sample" --target "$DEPLOY/.env" --domain "$DOMAIN" --port "$PORT" "${subscription_options[@]}"
        if $SUBSCRIPTION_PAGE; then
            : > "$DEPLOY/subscription.env"; chmod 600 "$DEPLOY/subscription.env"
            tls_helper caddy --domain "$DOMAIN" --email "$EMAIL" --method "${TLS_METHOD:-auto}" --directory "$DEPLOY" --subscription-urls "$SUBSCRIPTION_URLS"
        elif [[ ${TLS_METHOD:-auto} == auto ]]; then
            { [[ -z $EMAIL ]] || printf '{\n    email %s\n}\n\n' "$EMAIL"; printf '%s {\n    reverse_proxy remnawave:3000\n}\n' "$DOMAIN"; } > "$DEPLOY/Caddyfile"
        else tls_helper caddy --domain "$DOMAIN" --email "$EMAIL" --method "$TLS_METHOD" --directory "$DEPLOY"; fi
    else
        helper node-env --target "$DEPLOY/.env" --port "$PORT"
        mkdir -p "$DEPLOY/run" "$DEPLOY/logs"
        install -d -m 0700 "$DEPLOY/state/host-policy" "$DEPLOY/state/core-manager"
    fi
    STATE="$WORK/state.json"
    helper fresh --component "$COMPONENT" --directory "$DEPLOY" --project "$PROJECT" --image "$IMAGE" --domain "$DOMAIN" \
        --port "$PORT" --proxy "$PROXY" --node-domain "$NODE_DOMAIN" "${subscription_options[@]}" "${capability_options[@]}" --target "$DEPLOY/docker-compose.yml" --state "$STATE"
    panel_ipv6_candidate "$DEPLOY/docker-compose.yml"
    if [[ $COMPONENT == panel && $PROXY == caddy && ${TLS_METHOD:-auto} != auto ]]; then
        python3 - "$DEPLOY/docker-compose.yml" "$DEPLOY" <<'PY'
import json,sys
p=sys.argv[1];s=json.load(open(p));s['services']['caddy']['volumes'].append(sys.argv[2]+'/certs:/var/lib/remnacust/tls:ro')
json.dump(s,open(p,'w'),indent=2)
PY
    fi
    load_state; START_APPS=("${APPS[@]}" "${EXTRAS[@]}")
    if [[ $COMPONENT == panel ]] && $SUBSCRIPTION_PAGE; then START_APPS=(remnawave "${EXTRAS[@]}"); fi
}

managed_subscription_options() {
    local urls=''
    if [[ -n $STATE && -f $STATE ]]; then
        urls=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(",".join(s.get("subscriptionUrls",[])) if s.get("subscriptionPage") else "")' "$STATE")
    elif $SUBSCRIPTION_PAGE; then urls=$SUBSCRIPTION_URLS; fi
    [[ -z $urls ]] || printf '%s' "$urls"
}
initialize_subscription_page() {
    local urls script id token_uuid
    urls=$(managed_subscription_options); [[ -n $urls ]] || return 0
    [[ ! -L $DEPLOY/subscription.env ]] || die 'subscription.env не должен быть символической ссылкой'
    if [[ ! -s $DEPLOY/subscription.env ]]; then
        script="${HELPER%/*}/subscription.cjs"
        [[ -f $script ]] || die 'Не найден помощник настройки сайта подписки'
        id=$(compose ps --quiet "$(get mainService)"); token_uuid=$(get subscriptionTokenUuid)
        # stdout contains the credential: keep it out of the operation log.
        docker exec -i --env "REMNACUST_SUBSCRIPTION_TOKEN_UUID=$token_uuid" "$id" node - < "$script" > "$WORK/subscription-token.txt"
        chmod 600 "$WORK/subscription-token.txt"
        helper subscription-env --source "$WORK/subscription-token.txt" --target "$DEPLOY/subscription.env"
        rm -f -- "$WORK/subscription-token.txt"
    fi
    chmod 600 "$DEPLOY/subscription.env"
    compose up -d --no-build --pull never remnawave-subscription-page
    local -a START_APPS=(remnawave-subscription-page)
    wait_ready
}
tls_helper() {
    local script="${HELPER%/*}/tls.py"
    [[ -f $script ]] || die 'В выбранном выпуске нет настройки TLS. Используйте latest.'
    python3 "$script" "$@"
}
node_site_wizard() {
    [[ -n $NODE_DOMAIN ]] || return 0
    local choice
    if [[ -n $STATE && -f $STATE ]]; then
        [[ -n $NODE_SITE_PORT ]] || NODE_SITE_PORT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("nodeSitePort",443))' "$STATE") || return $?
        [[ -n $NODE_INBOUND_PORT ]] || NODE_INBOUND_PORT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("nodeInboundPort",8443))' "$STATE") || return $?
    fi
    if [[ -z $NODE_SITE_MODE && -t 0 && ( $ACTION == install-node || $ACTION == migrate-remnawave-node ) ]] && ! $YES; then
        printf '\n  Сайт ноды\n  1  Отдельный HTTPS-сайт\n  2  Selfsteal через Xray\n'
        choice=$(ask 'Режим сайта' 1) || return $?
        case "$choice" in 1) NODE_SITE_MODE=standalone;; 2) NODE_SITE_MODE=selfsteal;; *) die 'Выберите 1 или 2';; esac
    fi
    NODE_SITE_MODE=${NODE_SITE_MODE:-selfsteal}
    [[ $NODE_SITE_MODE == selfsteal || $NODE_SITE_MODE == standalone ]] || die 'Режим сайта: selfsteal или standalone'
    if [[ $NODE_SITE_MODE == standalone ]]; then
        helper validate --port "${PORT:-2222}" >/dev/null || return $?
        if [[ -t 0 ]] && ! $YES; then
            while true; do
                NODE_SITE_PORT=$(ask 'Порт HTTPS-сайта' "${NODE_SITE_PORT:-443}") || return $?
                NODE_INBOUND_PORT=$(ask 'Порт входа Xray в профиле панели' "${NODE_INBOUND_PORT:-8443}") || return $?
                if helper validate --port "$NODE_SITE_PORT" >/dev/null && helper validate --port "$NODE_INBOUND_PORT" >/dev/null &&
                   [[ $((10#$NODE_SITE_PORT)) != $((10#${PORT:-2222})) && $((10#$NODE_INBOUND_PORT)) != $((10#${PORT:-2222})) && $((10#$NODE_SITE_PORT)) != $((10#$NODE_INBOUND_PORT)) ]]; then break; fi
                printf '  Порты API, сайта и входа Xray должны быть разными числами от 1 до 65535.\n' >&2
            done
        fi
        NODE_SITE_PORT=${NODE_SITE_PORT:-443}; NODE_INBOUND_PORT=${NODE_INBOUND_PORT:-8443}
        helper validate --port "$NODE_SITE_PORT" >/dev/null || return $?
        helper validate --port "$NODE_INBOUND_PORT" >/dev/null || return $?
        NODE_SITE_PORT=$((10#$NODE_SITE_PORT)); NODE_INBOUND_PORT=$((10#$NODE_INBOUND_PORT))
        [[ $NODE_SITE_PORT != "$((10#${PORT:-2222}))" && $NODE_INBOUND_PORT != "$((10#${PORT:-2222}))" && $NODE_SITE_PORT != "$NODE_INBOUND_PORT" ]] || die 'Порты API, сайта и входа Xray должны отличаться'
    fi
}
certificate_wizard() {
    local choice domain suggested
    if [[ $COMPONENT == panel ]]; then
        [[ -n $DOMAIN ]] || DOMAIN=$(ask_confirmed_domain 'Домен панели') || return $?
        if [[ -t 0 ]] && ! $YES && ! $PROXY_SET; then
            printf '\n  HTTPS панели\n  1  Caddy в Docker (новая установка)\n  2  Свой существующий Nginx/Caddy\n'
            choice=$(ask 'Reverse proxy' 1)
            case "$choice" in 1) PROXY=caddy;;2) PROXY=existing;;*) die 'Выберите 1 или 2';;esac
        fi
        if [[ $PROXY == existing ]]; then
            [[ -z $TLS_METHOD$CERT_FILE$KEY_FILE$DNS_CREDENTIALS$EMAIL ]] || die 'При --proxy existing сертификат настраивается в вашем proxy; параметры TLS здесь не нужны'
            info 'Ваш proxy и сертификаты сохраняются. Backend будет доступен на 127.0.0.1.'
            return 0
        fi
        domain=$DOMAIN; suggested=auto
    else
        if [[ -t 0 ]] && ! $YES; then
            [[ -n $PORT ]] || PORT=$(ask 'Порт API ноды' 2222)
            [[ -n $PANEL_IP ]] || PANEL_IP=$(ask 'IP/CIDR главного сервера: все входящие порты кроме SSH только от него (Enter — свой firewall)')
        fi
        if [[ -t 0 && -z $NODE_DOMAIN ]] && ! $YES; then
            choice=$(ask_yes_no 'Настроить TLS/XHTTP на ноде?')
            case "$choice" in
                yes) NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды') || return $?; NODE_DOMAIN_CONFIRMED=$NODE_DOMAIN;;
                no) ;;
            esac
        fi
        if [[ -z $NODE_DOMAIN ]]; then
            [[ -z $TLS_METHOD$CERT_FILE$KEY_FILE$DNS_CREDENTIALS$EMAIL$NODE_SITE_PORT$NODE_INBOUND_PORT && $NODE_SITE_MODE != standalone ]] || die 'Для TLS и сайта ноды укажите --node-domain'
            return 0
        fi
        domain=$NODE_DOMAIN; suggested=http
        node_site_wizard || return $?
    fi
    if [[ -z $TLS_METHOD ]]; then
        if [[ -t 0 ]] && ! $YES; then
            printf '\n  Сертификат для %s\n  1  Автоматически · %s\n  2  Cloudflare DNS · API token\n  3  Gcore DNS · API token\n  4  Уже есть сертификат и приватный ключ\n' "$domain" "$suggested"
            case "$(ask 'Способ получения сертификата' 1)" in
                1) TLS_METHOD=$suggested;;2) TLS_METHOD=cloudflare;;3) TLS_METHOD=gcore;;4) TLS_METHOD=existing;;*) die 'Выберите 1–4';;
            esac
        else TLS_METHOD=$suggested; fi
    fi
    [[ $COMPONENT != node || $TLS_METHOD != auto ]] || die 'auto используется только Caddy панели; для ноды выберите http, DNS или existing'
    if [[ $COMPONENT == panel && $TLS_METHOD == http ]]; then TLS_METHOD=auto; fi
    if [[ $TLS_METHOD == existing ]]; then
        [[ -n $CERT_FILE ]] || CERT_FILE=$(ask 'Путь к fullchain.pem' "/etc/letsencrypt/live/$domain/fullchain.pem")
        [[ -n $KEY_FILE ]] || KEY_FILE=$(ask 'Путь к privkey.pem' "/etc/letsencrypt/live/$domain/privkey.pem")
        [[ -z $EMAIL$DNS_CREDENTIALS ]] || die 'Для готового сертификата email и DNS credentials не нужны'
    else
        [[ -z $CERT_FILE$KEY_FILE ]] || die 'Пути к сертификату доступны при --tls-method existing'
        if [[ -z $EMAIL ]]; then
            while true; do
                EMAIL=$(ask_required "Email для Let's Encrypt") || return $?
                [[ $EMAIL =~ ^[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
                printf '  ! некорректный email, повторите ввод\n' >&2
            done
        else
            [[ $EMAIL =~ ^[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'Некорректный email'
        fi
        if [[ $TLS_METHOD == cloudflare || $TLS_METHOD == gcore ]]; then
            if [[ -z $DNS_CREDENTIALS ]]; then
                [[ -t 0 ]] || die 'Укажите --dns-credentials (INI, права 600)'
                local secret
                while true; do
                    IFS= read -r -s -p "API token $TLS_METHOD (ввод скрыт): " secret || return 1
                    printf '\n'
                    secret=$(trim_answer "$secret")
                    [[ $secret =~ ^[A-Za-z0-9_.=-]+$ ]] && break
                    printf '  ! введите API token без пробелов\n' >&2
                done
                DNS_CREDENTIALS="$WORK/dns.ini"
                if [[ $TLS_METHOD == cloudflare ]]; then printf 'dns_cloudflare_api_token = %s\n' "$secret" > "$DNS_CREDENTIALS"
                else printf 'dns_gcore_apitoken = %s\n' "$secret" > "$DNS_CREDENTIALS"; fi
                unset secret
            fi
        else
            [[ -z $DNS_CREDENTIALS ]] || die 'DNS credentials нужны только для Cloudflare/Gcore'
            info "A/AAAA $domain должны указывать на сервер; для HTTP-01 нужен доступ к TCP 80."
        fi
    fi
}
certificate_preflight() {
    if [[ $COMPONENT == node && $TLS_METHOD == http && ( $((10#${NODE_SITE_PORT:-443})) == 80 || $((10#${NODE_INBOUND_PORT:-8443})) == 80 ) ]]; then
        die 'HTTP-01 использует TCP 80. Выберите другой порт сайта/входа Xray или DNS-сертификат.'
    fi
    if [[ $COMPONENT == node && ${NODE_SITE_MODE:-selfsteal} == standalone ]]; then
        local current_site=''
        if [[ -n $STATE && -f $STATE ]]; then current_site=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s.get("nodeSitePort",443) if s.get("nodeSiteMode")=="standalone" else "")' "$STATE"); fi
        [[ $current_site == "$NODE_SITE_PORT" ]] || port_free "$NODE_SITE_PORT" || return $?
    fi
    if [[ $COMPONENT == node && -n $PANEL_IP && $TLS_METHOD == http ]]; then
        info 'Для HTTP-01 TCP 80 временно открывается во время выпуска и продления сертификата; затем снова закрывается.'
    fi
    local domain=${NODE_DOMAIN:-$DOMAIN}
    local -a subscription_options=(); local subscriptions
    subscriptions=$(managed_subscription_options)
    [[ -z $subscriptions ]] || subscription_options=(--subscription-urls "$subscriptions")
    [[ $COMPONENT != panel || $PROXY == caddy ]] || return 0
    if [[ $COMPONENT == panel && ( $PORT == 80 || $PORT == 443 ) ]]; then die 'Порты 80/443 нужны Caddy. Выберите другой --port для backend панели (по умолчанию 3000).'; fi
    if [[ $COMPONENT == node && $TLS_METHOD == http && $PORT == 80 ]]; then die 'HTTP-01 и его продление используют порт 80. Выберите другой API-порт ноды или DNS/готовый сертификат.'; fi
    [[ -n $TLS_METHOD ]] || return 0
    if [[ $TLS_METHOD == existing ]]; then
        tls_helper validate --domain "$domain" --certificate "$CERT_FILE" --key "$KEY_FILE" "${subscription_options[@]}"
    elif [[ $TLS_METHOD == cloudflare || $TLS_METHOD == gcore ]]; then
        tls_helper credentials --method "$TLS_METHOD" --source "$DNS_CREDENTIALS" --target "$WORK/dns-validated.ini"
    elif [[ $TLS_METHOD == http ]]; then port_free 80; fi
}
dns_addresses() {
    # Query public DNS rather than /etc/hosts; bound even hostname resolution time.
    timeout 25 python3 - "$1" <<'PY'
import ipaddress,json,re,sys,urllib.request
host=sys.argv[1]
if not re.fullmatch(r'(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}',host):
    raise SystemExit('Некорректный домен; укажите имя без https://, порта и пути')
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
addresses=None
for endpoint in ['https://dns.google/resolve','https://cloudflare-dns.com/dns-query']:
    try:
        found=set()
        for kind in [1,28]:
            request=urllib.request.Request(endpoint+'?name='+host+'&type='+str(kind),headers={'Accept':'application/dns-json'})
            with opener.open(request,timeout=5) as response:body=response.read(131073)
            if len(body)>131072:raise ValueError()
            data=json.loads(body)
            if not isinstance(data,dict) or type(data.get('Status')) is not int or data['Status'] not in [0,3] or data.get('TC') is not False:raise ValueError()
            for row in data.get('Answer',[]):
                if row.get('type')==kind:
                    address=ipaddress.ip_address(row['data'])
                    if address.version!=(4 if kind==1 else 6):raise ValueError()
                    found.add(str(address))
        addresses=found;break
    except (OSError,ValueError,KeyError,TypeError,AttributeError):continue
if addresses is None:raise SystemExit('Публичный DNS недоступен или ответ A/AAAA неполный: '+host)
if not addresses:raise SystemExit('У домена нет A/AAAA: '+host)
print('\n'.join(sorted(addresses)))
PY
}
server_addresses() {
    local addresses='' external family endpoint
    if [[ -n $SERVER_IPS ]]; then
        addresses=${SERVER_IPS//,/$'\n'}
    else
        # Public interfaces cover multihomed servers; HTTPS discovery also covers NAT.
        addresses=$(python3 - <<'PY'
import ipaddress,json,subprocess
try:
    rows=json.loads(subprocess.run(['ip','-j','address','show','scope','global'],capture_output=True,text=True,check=True,timeout=5).stdout)
    print('\n'.join(a['local'] for row in rows for a in row.get('addr_info',[]) if ipaddress.ip_address(a['local']).is_global))
except (OSError,ValueError,KeyError,subprocess.SubprocessError):pass
PY
        )
        for family in 4 6; do
            endpoint=https://api.ipify.org
            [[ $family != 6 ]] || endpoint=https://api6.ipify.org
            if external=$(curl "-$family" --fail --silent --show-error --noproxy '*' --connect-timeout 3 --max-time 5 --max-filesize 128 --proto '=https' "$endpoint" 2>/dev/null); then
                addresses+=$'\n'"$external"
            fi
        done
    fi
    python3 - "$addresses" <<'PY'
import ipaddress,sys
try:
    addresses={ipaddress.ip_address(value.strip()) for value in sys.argv[1].splitlines() if value.strip()}
    if not addresses or any(not a.is_global for a in addresses):raise ValueError()
except ValueError:raise SystemExit('Не удалось определить публичные IP сервера. Укажите --server-ip IPv4[,IPv6].')
print('\n'.join(sorted(map(str,addresses))))
PY
}
check_dns() {
    local domain=$1 actual expected address mismatch=false
    if ! actual=$(dns_addresses "$domain"); then
        printf '  DNS %s не подтверждён. Проверьте записи A/AAAA и доступность DNS; повторите действие.\n' "$domain" >&2
        return 1
    fi
    expected=$(server_addresses) || return $?
    while IFS= read -r address; do
        if ! grep -Fxq -- "$address" <<< "$expected"; then mismatch=true; fi
    done <<< "$actual"
    if $mismatch; then
        info "DNS $domain: ${actual//$'\n'/, }"
        info "IP сервера: ${expected//$'\n'/, }"
        printf '  A/AAAA %s ведут на другой IP. Исправьте записи, включая IPv6, и дождитесь обновления DNS.\n  Для сервера за NAT укажите --server-ip IPv4[,IPv6].\n' "$domain" >&2
        return 1
    fi
    info "✓ A/AAAA $domain указывают на сервер"
}
dns_preflight() {
    # DNS-01 and an external proxy may legitimately use a different frontend IP.
    [[ $TLS_METHOD == auto || $TLS_METHOD == http ]] || return 0
    [[ $COMPONENT != panel || $PROXY == caddy ]] || return 0
    check_dns "${NODE_DOMAIN:-$DOMAIN}" || die 'DNS не соответствует серверу. Контейнеры установки не созданы; исправьте домен и повторите действие.'
    if [[ $COMPONENT == panel ]] && $SUBSCRIPTION_PAGE; then
        local host; local -a hosts=()
        local validated_hosts
        validated_hosts=$(helper subscription-domains --domain "$DOMAIN" --subscription-urls "$SUBSCRIPTION_URLS") || return 1
        mapfile -t hosts <<< "$validated_hosts"
        for host in "${hosts[@]}"; do check_dns "$host" || die 'DNS сайта подписки не соответствует серверу. Исправьте записи и повторите установку.'; done
    fi
}
valid_panel_response() {
    python3 - "$1" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1]));response=data.get('response') if isinstance(data,dict) else None
    if not isinstance(response,dict) or any(type(response.get(k)) is not bool for k in ['isLoginAllowed','isRegisterAllowed']):raise ValueError()
except (OSError,ValueError,TypeError):raise SystemExit('Адрес отвечает, но /api/auth/status не вернул ответ панели. Проверьте домен и reverse proxy.')
PY
}
wait_panel_https() {
    local deadline=$((SECONDS+HTTPS_TIMEOUT)) remaining limit
    while ((SECONDS<deadline)); do
        remaining=$((deadline-SECONDS)); limit=8
        ((remaining>=limit)) || limit=$remaining
        if curl --fail --silent --show-error --noproxy '*' --connect-timeout 3 --max-time "$limit" --max-filesize 1048576 --proto '=https' \
            "https://$DOMAIN/api/auth/status" -o "$WORK/https-status.json" 2> "$WORK/https-error.txt"; then
            if valid_panel_response "$WORK/https-status.json" 2> "$WORK/https-error.txt"; then return 0; fi
        fi
        ((SECONDS<deadline)) || break
        sleep 2
    done
    cat "$WORK/https-error.txt" >&2
    return 1
}
wait_subscription_https() {
    local urls host code deadline remaining limit
    local -a hosts=()
    urls=$(managed_subscription_options); [[ -n $urls ]] || return 0
    local validated_hosts
    validated_hosts=$(helper subscription-domains --domain "$DOMAIN" --subscription-urls "$urls") || return 1
    mapfile -t hosts <<< "$validated_hosts"
    for host in "${hosts[@]}"; do
        deadline=$((SECONDS+HTTPS_TIMEOUT))
        while ((SECONDS<deadline)); do
            remaining=$((deadline-SECONDS)); limit=8; ((remaining>=limit)) || limit=$remaining
            code=$(curl --silent --show-error --noproxy '*' --connect-timeout 3 --max-time "$limit" --max-filesize 1048576 --proto '=https' \
                "https://$host/" -o /dev/null -w '%{http_code}' 2> "$WORK/subscription-https-error.txt") || code=''
            # The page needs a user's short UUID; the bare domain normally returns 404.
            [[ $code != 200 && $code != 404 ]] || break
            sleep 2
        done
        if [[ $code != 200 && $code != 404 ]]; then
            printf '  HTTPS сайта %s не подтверждён; проверьте DNS и Caddy.\n' "$host" >&2
            return 1
        fi
    done
}
https_diagnostics() {
    printf '  HTTPS %s не подтверждён. Проверьте A/AAAA, доступ к TCP 80/443 и firewall сервера/провайдера.\n' "$DOMAIN" >&2
    if [[ -f $WORK/https-error.txt ]]; then head -c 600 "$WORK/https-error.txt" >&2; printf '\n' >&2; fi
    if [[ " ${EXTRAS[*]} " == *' caddy '* ]]; then compose logs --tail 30 --no-color caddy >> "$LOG" 2>&1 || true; fi
    printf '  Запущенная панель и данные сохранены. После исправления: sudo bash installer.sh check-panel\n  Журнал, включая Caddy: %s\n' "$LOG" >&2
}
obtain_certificate() {
    local domain=${NODE_DOMAIN:-$DOMAIN} lineage
    local -a domains=(--domain "$domain") hosts=(); local subscriptions host
    subscriptions=$(managed_subscription_options)
    if [[ -n $subscriptions ]]; then
        local validated_hosts
        validated_hosts=$(helper subscription-domains --domain "$domain" --subscription-urls "$subscriptions") || return 1
        mapfile -t hosts <<< "$validated_hosts"
        for host in "${hosts[@]}"; do domains+=(--domain "$host"); done
    fi
    [[ $COMPONENT != panel || $PROXY == caddy ]] || return 0
    [[ -n $TLS_METHOD && $TLS_METHOD != auto && $TLS_METHOD != existing ]] || return 0
        ACME_ROOT="$ROOT/acme/${PROJECT:-remnacust-$COMPONENT}"
        install -d -m 0700 "$ACME_ROOT"
        CERTBOT="$ROOT/tools/certbot/bin/certbot"
        if [[ ! -x $CERTBOT ]] || ! "$CERTBOT" plugins --authenticators --config-dir "$ACME_ROOT/config" --work-dir "$ACME_ROOT/work" --logs-dir "$ACME_ROOT/logs" 2>/dev/null | grep -q dns-gcore; then
            package_step 'Пакеты для ACME' update -o APT::Update::Error-Mode=any || return $?
            package_step 'Python venv и OpenSSL' install python3-venv openssl || return $?
            [[ -x $ROOT/tools/certbot/bin/python ]] || step 'Среда Certbot' python3 -m venv "$ROOT/tools/certbot"
            step 'Certbot и DNS-плагины' "$ROOT/tools/certbot/bin/pip" install --disable-pip-version-check --only-binary=:all: certbot==5.8.0 certbot-dns-cloudflare==5.8.0 certbot-dns-gcore==0.1.8
        fi
        local -a auth=(--standalone)
        if [[ $TLS_METHOD == cloudflare || $TLS_METHOD == gcore ]]; then
            tls_helper credentials --method "$TLS_METHOD" --source "$DNS_CREDENTIALS" --target "$ACME_ROOT/dns.ini"
            auth=(--authenticator "dns-$TLS_METHOD" "--dns-$TLS_METHOD-credentials" "$ACME_ROOT/dns.ini" "--dns-$TLS_METHOD-propagation-seconds" 90)
        else port_free 80; fi
        local acme_open=false cert_status=0
        if [[ $COMPONENT == node && $TLS_METHOD == http && -n $PANEL_IP ]] && command -v nft >/dev/null; then
            python3 -I "$HELPER_ROOT/node_firewall.py" acme-open
            acme_open=true
        fi
        step 'Сертификат Let’s Encrypt' acme_certbot "$CERTBOT" certonly --config-dir "$ACME_ROOT/config" --work-dir "$ACME_ROOT/work" --logs-dir "$ACME_ROOT/logs"             --non-interactive --agree-tos --email "$EMAIL" --cert-name "$domain" "${domains[@]}" "${auth[@]}" || cert_status=$?
        if $acme_open; then python3 -I "$HELPER_ROOT/node_firewall.py" acme-close || cert_status=1; fi
        if ((cert_status != 0)); then
            info "Подробности ACME: $ACME_ROOT/logs/letsencrypt.log"
            return "$cert_status"
        fi
        lineage="$ACME_ROOT/config/live/$domain"
        CERT_FILE="$lineage/fullchain.pem"; KEY_FILE="$lineage/privkey.pem"
}
acme_certbot() {
    if [[ $TLS_METHOD == http && ( $COMPONENT != node || -n $PANEL_IP ) ]]; then
        python3 -I "$HELPER_ROOT/ufw_guard.py" --root "$ROOT" -- "$@"
    else "$@"; fi
}
configure_certificate() {
    local domain=${NODE_DOMAIN:-$DOMAIN} hook service renew_cli
    local -a subscription_options=(); local subscriptions
    subscriptions=$(managed_subscription_options)
    [[ -z $subscriptions ]] || subscription_options=(--subscription-urls "$subscriptions")
    [[ $COMPONENT != panel || $PROXY == caddy ]] || return 0
    [[ -n $TLS_METHOD && $TLS_METHOD != auto ]] || return 0
    tls_helper copy --domain "$domain" --certificate "$CERT_FILE" --key "$KEY_FILE" --directory "$DEPLOY" "${subscription_options[@]}"
    tls_helper record --state "$STATE" --method "$TLS_METHOD" --certificate "$CERT_FILE" --key "$KEY_FILE"
    helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json"
    if [[ $COMPONENT == node ]]; then
        helper node-proxy --directory "$DEPLOY" --domain "$domain" --node-site-mode "${NODE_SITE_MODE:-selfsteal}" --node-site-port "${NODE_SITE_PORT:-443}"
        step 'Проверка Nginx' compose run --rm --no-deps --entrypoint nginx node-nginx -t
    else step 'Проверка Caddy' compose run --rm --no-deps --entrypoint caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; fi
    schedule_certificate_renewal
}
schedule_certificate_renewal() {
    local domain=${NODE_DOMAIN:-$DOMAIN} hook service renew_cli
    [[ $TLS_METHOD != auto ]] || return 0
    ACME_ROOT=${ACME_ROOT:-$ROOT/acme/$PROJECT}
    CERTBOT=${CERTBOT:-$ROOT/tools/certbot/bin/certbot}
    install -d -m 0700 "$ACME_ROOT"
    if [[ $TLS_METHOD != existing ]]; then
        hook="$ACME_ROOT/deploy-hook.sh"; renew_cli="$ACME_ROOT/renew.sh"
        printf '#!/usr/bin/env bash\nset -eu\nexport REMNACUST_ROOT=%q\nexec /usr/local/bin/remnacust renew-%s-certificate --yes\n' "$ROOT" "$COMPONENT" > "$hook"
        local -a renewal_hooks=()
        if [[ $COMPONENT == node && $TLS_METHOD == http && -n $PANEL_IP ]]; then
            printf '#!/usr/bin/env bash\nset -eu\nexec /usr/bin/python3 -I /etc/remnacust-node-firewall/guard.py acme-open\n' > "$ACME_ROOT/acme-open.sh"
            printf '#!/usr/bin/env bash\nset -eu\nexec /usr/bin/python3 -I /etc/remnacust-node-firewall/guard.py acme-close\n' > "$ACME_ROOT/acme-close.sh"
            chmod 0700 "$ACME_ROOT/acme-open.sh" "$ACME_ROOT/acme-close.sh"
            renewal_hooks=(--pre-hook "$ACME_ROOT/acme-open.sh" --post-hook "$ACME_ROOT/acme-close.sh")
        fi
        local -a renewal_command=("$CERTBOT")
        if [[ $COMPONENT != node || -n $PANEL_IP ]]; then
            install -m 0700 "${HELPER%/*}/ufw_guard.py" "$ACME_ROOT/ufw_guard.py"
            renewal_command=(/usr/bin/python3 -I "$ACME_ROOT/ufw_guard.py" --root "$ROOT" -- "$CERTBOT")
        fi
        { printf '#!/usr/bin/env bash\nset -eu\nexec '; printf '%q ' "${renewal_command[@]}"; printf 'renew --quiet --config-dir %q --work-dir %q --logs-dir %q --deploy-hook %q' "$ACME_ROOT/config" "$ACME_ROOT/work" "$ACME_ROOT/logs" "$hook"; if ((${#renewal_hooks[@]})); then printf ' %q' "${renewal_hooks[@]}"; fi; printf '\n'; } > "$renew_cli"
        chmod 0700 "$hook" "$renew_cli"
        service="remnacust-acme-$PROJECT"
        tls_helper timer --service "$service" --script "$renew_cli"
        systemctl daemon-reload
        systemctl enable --now "$service.timer"
    else info "Готовый сертификат подключён. После продления выполните remnacust renew-$COMPONENT-certificate."; fi
}
panel_continuity_preflight() {
    [[ $ACTION == upgrade-panel && $COMPONENT == panel ]] || return 0
    if $ALLOW_DISRUPTION; then
        info 'ВНИМАНИЕ: --allow-disruption: работа нод во время обновления панели не гарантируется.'
        return 0
    fi
    local id count
    # Discovery captured the current container before any Compose changes.
    if ! id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["Id"])' "$WORK/container.before.json" 2>/dev/null) ||
       [[ ! $id =~ ^[a-f0-9]{12,64}$ ]]; then
        info 'ВНИМАНИЕ: проверить автономность нод не удалось. Обновление продолжается; у зависимых от панели нод возможен перерыв связи.'
        return 0
    fi
    # Inspect the entry without executing it: an old CLI may open an interactive menu.
    if ! timeout --kill-after=5s 10s docker exec "$id" node -e '
try {
    const fs = require("node:fs"), file = "/opt/app/dist/cli.js";
    const stat = fs.statSync(file);
    if (!stat.isFile() || stat.size > 16 * 1024 * 1024 ||
        !fs.readFileSync(file, "utf8").includes("check-node-continuity")) process.exit(1);
} catch { process.exit(1); }
' >/dev/null 2>&1; then
        # Use the already verified candidate image to check older panels without
        # executing their interactive CLI or stopping their applications.
        if ! count=$(python3 -I "$HELPER_ROOT/panel_continuity.py" --inspect "$WORK/container.before.json" --image "$IMAGE" 2>/dev/null) ||
           [[ ! $count =~ ^[0-9]{1,5}$ ]]; then
            info 'ВНИМАНИЕ: автономность нод не подтверждена. Обновление продолжается; у зависимых от панели нод возможен перерыв связи.'
            return 0
        fi
        info "Непрерывность работы нод подтверждена: $count."
        return 0
    fi
    # Bound both runtime and output inside the container. Only a validated count
    # crosses into installer output; CLI diagnostics may contain private details.
    if ! count=$(timeout --kill-after=5s 130s docker exec "$id" node -e '
try {
    const result = require("node:child_process").spawnSync(process.execPath,
        ["/opt/app/dist/cli.js", "check-node-continuity"],
        { timeout: 120000, maxBuffer: 16384, killSignal: "SIGKILL", stdio: ["ignore", "pipe", "ignore"] });
    if (result.error || result.signal || result.status !== 0) process.exit(1);
    const value = JSON.parse(result.stdout.toString("utf8"));
    if (value?.ready !== true || !Number.isSafeInteger(value.nodeCount) || value.nodeCount < 0) process.exit(1);
    process.stdout.write(String(value.nodeCount));
} catch { process.exit(1); }
' 2>/dev/null) || [[ ! $count =~ ^[0-9]{1,16}$ ]]; then
        info 'ВНИМАНИЕ: автономность нод не подтверждена. Обновление продолжается; у зависимых от панели нод возможен перерыв связи.'
        return 0
    fi
    info "Непрерывность работы нод подтверждена: $count."
}
node_firewall_cleanup() {
    local record=${1:-$STATE}
    local -a cleanup_options=(--owner-root "$ROOT")
    if [[ -n $record && -f $record ]]; then
        local previous_api previous_https
        previous_api=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("apiPort",0))' "$record") || return $?
        previous_https=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s.get("nodeSitePort",443) if s.get("nodeSiteMode")=="standalone" else 0)' "$record") || return $?
        cleanup_options+=(--api-port "$previous_api" --https-port "$previous_https")
    fi
    python3 -I "$HELPER_ROOT/node_firewall.py" uninstall --owner-root "$ROOT" || return $?
    if ((${#cleanup_options[@]} > 2)); then
        python3 -I "$HELPER_ROOT/node_firewall.py" uninstall "${cleanup_options[@]}" || return $?
    fi
}
node_acl_without_panel() {
    [[ -z $PANEL_IP ]] || return 0
    node_firewall_cleanup
}
node_acl() {
    local https_port=0
    if [[ $PANEL_IP == managed ]]; then PANEL_IP=$(python3 -c 'import json;print(json.load(open("/etc/remnacust-node-firewall/state.json"))["panel"])') || return $?; fi
    if [[ -z $PANEL_IP ]]; then
        node_acl_without_panel || return $?
        info "IP панели не задан: правила доступа не добавляются. Доступ к TCP $PORT настройте в своём firewall."
        return 0
    fi
    if [[ -n $STATE && -f $STATE ]]; then
        https_port=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s.get("nodeSitePort",443) if s.get("nodeSiteMode")=="standalone" else 0)' "$STATE") || return $?
    fi
    if [[ $https_port != 0 || ( -n $NODE_SITE_MODE && ( -f /etc/ufw/applications.d/remnacust-node-site || -f /etc/remnacust-node-firewall/state.json ) ) ]]; then
        python3 -I "$HELPER_ROOT/node_firewall.py" site --https-port "$https_port" || return $?
    fi
    command -v nft >/dev/null || package_step 'Сетевая защита ноды' install --no-install-recommends nftables || return $?
    local api_port inbound_port
    api_port=$(get apiPort)
    inbound_port=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s.get("nodeInboundPort",8443) if s.get("nodeSiteMode")=="standalone" else "")' "$STATE") || return $?
    local -a control_options=(--api-port "$api_port")
    [[ -z $inbound_port ]] || control_options+=(--inbound-port "$inbound_port")
    python3 -I "$HELPER_ROOT/node_firewall.py" apply --panel "$PANEL_IP" --https-port "$https_port" --owner-root "$ROOT" "${control_options[@]}"
    if [[ $https_port == 0 ]]; then
        info "Все входящие порты и ping разрешены только от $PANEL_IP; SSH сохранён. Клиенты VPN должны идти через главный сервер."
    else
        info "HTTPS сайта TCP $https_port доступен посетителям; остальные порты и ping только от $PANEL_IP. SSH сохранён."
    fi
    info 'Отмена ограничения: python3 /etc/remnacust-node-firewall/guard.py remove'
}
deploy() {
    [[ $PANEL_IPV6_MODE_SET == false || $COMPONENT == panel ]] || die '--panel-ipv6 доступен только для панели'
    [[ $ACTION == install-panel || $ACTION == install-node || $ACTION == upgrade-node || $ACTION == migrate-remnawave-node || $PANEL_NET_ADMIN_SET == false ]] || die '--net-admin/--no-net-admin доступны для новой панели, установки, переноса или обновления ноды'
    [[ $ACTION == install-* || -z $PORT ]] || die '--port задаёт порт новой установки. Обновление и миграция сохраняют фактический порт существующего контейнера.'
    if [[ $ACTION == install-* ]]; then
        info "$ACTION · новая установка $COMPONENT"
    else info "$ACTION · настройки и данные будут сохранены"; fi
    choose_version
    confirm "Выполнить $ACTION ($VERSION)"
    prepare_host; lock_operation
    if [[ $ACTION == install-* ]]; then
        assert_fresh_target; select_fresh_target; certificate_wizard
    fi
    trap recover ERR
    release_source
    if [[ $ACTION == install-* ]]; then
        if [[ $COMPONENT == panel ]]; then panel_net_admin_wizard; else node_net_admin_wizard; fi
        if [[ $COMPONENT == panel ]]; then subscription_wizard; fi
        if [[ $COMPONENT == panel ]]; then PORT=${PORT:-3000}; else PORT=${PORT:-2222}; fi
        local -a installation_validation=(--domain "$DOMAIN" --node-domain "$NODE_DOMAIN" --port "$PORT" --project "${PROJECT:-remnacust-$COMPONENT}")
        [[ -z $PANEL_IP ]] || installation_validation+=(--key "$PANEL_IP")
        helper validate "${installation_validation[@]}"
        port_free "$PORT"
        if [[ $COMPONENT == panel ]] && $SUBSCRIPTION_PAGE; then
            SUBSCRIPTION_PORT=$(choose_subscription_port "$SUBSCRIPTION_PORT" "$PORT") || return $?
        fi
        if [[ $COMPONENT == panel && $PROXY == caddy ]]; then port_free 80; port_free 443; fi
        certificate_preflight
        dns_preflight
        if [[ $COMPONENT == panel ]]; then backup_password_wizard; fi
    fi
    step "Подготовка образа $COMPONENT" prepare_image
    if [[ $ACTION == install-panel ]] && $SUBSCRIPTION_PAGE; then
        select_subscription_image
        step 'Готовый образ сайта подписки' prepare_subscription_image
    fi
    if [[ $ACTION == install-* ]]; then
        if [[ $COMPONENT == node && -z $PANEL_IP ]]; then node_acl_without_panel || return $?; fi
        obtain_certificate
        fresh_files
        helper record --state "$STATE" --version "${COMPONENT_VERSION:-${TAG#v}}" --image "$IMAGE" --running "${START_APPS[@]}"
        archive_retired_registry
        helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json"
        # Keep recovery commands available if first boot or certificate issuance fails.
        install_cli
        configure_panel_updates "$DEPLOY/docker-compose.yml"
        if [[ $COMPONENT == panel ]]; then step 'Защита резервных копий' initialize_panel_backups; fi
        configure_certificate
        if [[ $COMPONENT == node ]]; then node_acl; fi
        step 'Запуск установки' compose up -d --no-build
        # Compose may create its bridge only on first start. Refresh the owned
        # guard before readiness checks so container-originated traffic works.
        if [[ $COMPONENT == node && -n $PANEL_IP ]]; then node_acl; fi
    else
        if [[ $ACTION == upgrade-* && -z $DIRECTORY$CONTAINER$COMPOSE_FILE && -f $ROOT/registry/$COMPONENT.json ]]; then
            STATE="$ROOT/registry/$COMPONENT.json"; load_state
            CONTAINER=$(compose ps --all --quiet "$(get mainService)")
        fi
        if [[ -z $CONTAINER$DIRECTORY$COMPOSE_FILE ]]; then
            local -a detected=(); mapfile -t detected < <(component_containers "$COMPONENT")
            ((${#detected[@]} != 1)) || CONTAINER=${detected[0]}
        fi
        find_existing
        helper check-upgrade --source "$WORK/compose.before.json" --state "$STATE" --inspect "$WORK/project-containers.json" --version "${COMPONENT_VERSION:-${TAG#v}}" --key "$TAG" || return $?
        node_migration_wizard
        if [[ $COMPONENT == node ]]; then node_net_admin_wizard "$WORK/compose.after.json"; fi
        if [[ $COMPONENT == panel ]]; then
            database_environment; check_writers
            step 'Проверка истории миграций и исходных ключей' database_run preflight
        fi
        report_update_progress preparation 'Проверка текущей установки' done
        report_update_progress backup 'Резервная копия текущей установки' running
        backup_current
        report_update_progress backup 'Резервная копия текущей установки' done
        configure_panel_updates "$WORK/compose.after.json"
        if [[ $COMPONENT == node ]]; then
            helper plan-node-state --source "$WORK/compose.after.json" --inspect "$WORK/container.before.json" --directory "$DEPLOY" --target "$WORK/node-state-plan.json"
        fi
        # Validate the merged candidate while the original applications run.
        docker compose --project-name "$PROJECT" --project-directory "$DEPLOY" -f "$WORK/compose.after.json" \
            --profile '*' config --no-interpolate --no-env-resolution --format json > "$WORK/compose.validated.json"
        report_update_progress applying 'Обновление приложений' running
        panel_continuity_preflight
        CHANGED=true
        helper commit-compose --source "$WORK/compose.after.json" --state "$STATE" --directory "$BACKUP" \
            --version "${COMPONENT_VERSION:-${TAG#v}}" --key "$TAG"
        load_state
        compose --profile '*' config --no-interpolate --no-env-resolution --format json > "$WORK/compose.committed.json"
        python3 - "$WORK/compose.validated.json" "$WORK/compose.committed.json" <<'PY'
import json,sys
before,after=[json.load(open(path)) for path in sys.argv[1:]]
before.pop('x-remnacust-release',None);after.pop('x-remnacust-release',None)
if before!=after:raise SystemExit('Основной Compose отличается от проверенной конфигурации; обновление остановлено')
PY
        compose stop "${APPS[@]}"
        if [[ $COMPONENT == node ]]; then
            step 'Сохранение настроек и лимитов ноды' helper snapshot-node-state --source "$WORK/node-state-plan.json"
            helper preserve-node-state-rollback --source "$WORK/node-state-plan.json" --directory "$BACKUP"
            step 'Проверка совместимости обновления ноды' verify_node_image_policy
        fi
        if [[ $COMPONENT == panel ]]; then
            # Refresh the dump after all known writers have stopped. Infrastructure stays running.
            step 'Финальная копия PostgreSQL' backup_panel_data
            database_run snapshot > "$BACKUP/fingerprints.json"; backup_hashes
            DB_CHANGED=true
            step 'Совместимость старой базы' docker run --rm --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" --entrypoint node "$IMAGE" dist/database-compatibility.js --apply
        fi
        step 'Запуск обновлённых приложений' compose up -d --no-deps --no-build --pull never "${START_APPS[@]}"
    fi
    step 'Проверка готовности приложений' wait_ready
    if [[ $COMPONENT == node ]] && python3 -c 'import json,sys;sys.exit(json.load(open(sys.argv[1])).get("nodeSiteMode")!="standalone")' "$STATE"; then
        step 'Проверка HTTPS-сайта' helper node-https --state "$STATE"
    fi
    if [[ $COMPONENT == node ]] && $NODE_NET_ADMIN; then
        local actual_capability
        actual_capability=$(node_effective_net_admin "$(compose ps --all --quiet "$(get mainService)")") || actual_capability=unknown
        if [[ $actual_capability != yes ]]; then
            info 'NET_ADMIN запрошен в Compose, но после запуска не подтверждён. Сетевые функции могут быть ограничены настройками хоста.'
        fi
    fi
    if [[ $ACTION == install-panel ]] && $SUBSCRIPTION_PAGE; then
        step 'Подключение сайта подписки' initialize_subscription_page
        START_APPS+=(remnawave-subscription-page)
    fi
    if [[ $ACTION == install-panel && $PROXY == caddy ]]; then
        if ! step 'Ожидание HTTPS панели (до 3 минут)' wait_panel_https; then https_diagnostics; return 1; fi
        if ! step 'Проверка HTTPS сайта подписки' wait_subscription_https; then https_diagnostics; return 1; fi
    fi
    if [[ $ACTION != install-* ]]; then
        docker inspect "$(compose ps --all --quiet "$(get mainService)")" > "$WORK/container.after.json"
        local -a compare_options=()
        if [[ $COMPONENT == node ]] && $NODE_NET_ADMIN_ADDED; then compare_options=(--key net-admin-added); fi
        helper compare --source "$WORK/container.before.json" --inspect "$WORK/container.after.json" "${compare_options[@]}"
        if [[ $COMPONENT == panel ]]; then step 'Проверка сохранности данных' verify_database; fi
    fi
    helper record --state "$STATE" --version "${COMPONENT_VERSION:-${TAG#v}}" --image "$IMAGE" --running "${START_APPS[@]}"
    helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json"
    if [[ $ACTION != install-* ]]; then install_cli; fi
    CHANGED=false; trap - ERR
    node_migration_finish
    if [[ $COMPONENT == panel ]] && python3 -c 'import json,sys;sys.exit(not json.load(open(sys.argv[1])).get("subscriptionMigration"))' "$STATE"; then
        step 'Перенос и проверка страницы подписки' subscription_migration_apply
        helper_file_copy "$STATE" "$ROOT/registry/$COMPONENT.json"
    fi
    step 'Подготовка рабочего каталога' python3 -I "$HELPER_ROOT/deployment_layout.py" --root "$ROOT" --component "$COMPONENT"
    helper_file_copy "$ROOT/registry/$COMPONENT.json" "$STATE"
    load_state
    compose --profile '*' config --no-interpolate --no-env-resolution --format json > "$WORK/compose.layout.json"
    helper layout --state "$STATE" --source "$WORK/compose.layout.json"
    if ! python3 -I "$HELPER_ROOT/deployment_layout.py" --root "$ROOT" --cleanup-backups; then
        info 'Не все старые копии удалось архивировать. Рабочие файлы сохранены; повторите cleanup-backups после проверки журнала.'
    fi
    if [[ $ACTION == upgrade-* || $ACTION == migrate-remnawave-* ]]; then
        cleanup_old_images
    fi
    completion_summary
    if [[ ${REMNACUST_MENU_COMPLETION_FD:-} == 3 ]]; then printf 'completed\n' >&3; fi
}
cleanup_old_images() {
    report_update_progress cleanup 'Очистка старых образов' running
    local cleaner="$HELPER_ROOT/image_cleanup.py"
    [[ -f $cleaner ]] || return 0
    local -a options=(--component "$COMPONENT" --keep "$IMAGE")
    [[ ! -f $WORK/project-containers.json ]] || options+=(--before "$WORK/project-containers.json")
    [[ -z $SUBSCRIPTION_IMAGE ]] || options+=(--keep "$SUBSCRIPTION_IMAGE")
    if python3 "$cleaner" "${options[@]}" >> "$LOG" 2>&1; then
        report_update_progress cleanup 'Очистка старых образов' done
        info 'Старые образы очищены; текущая и предыдущая версии сохранены'
    else
        report_update_progress cleanup 'Очистка образов отложена; обновление завершено' done
        info 'Обновление готово; очистка образов отложена, подробности в журнале'
    fi
}

completion_row() {
    if (($(terminal_width) >= 64)); then
        printf '  %s %s%s%s\n' "$1" "$BOLD" "$2" "$RESET"
    else
        terminal_text "$1" '  ' '  ' "$DIM"
        printf '    %s%s%s\n' "$BOLD" "$2" "$RESET"
    fi
}
completion_summary() {
    local -a details=()
    python3 - "$STATE" "$DOMAIN" "$NODE_DOMAIN" "$PORT" "$PROXY" "$TLS_METHOD" "$CERT_FILE" "$KEY_FILE" > "$WORK/completion-details" <<'PY'
import json,sys
from pathlib import Path
s=json.load(open(sys.argv[1]));directory=s['directory'];env={}
p=Path(directory)/'.env'
if p.is_file():
 for line in p.read_text().splitlines():
  key,sep,value=line.partition('=')
  if sep and key in {'FRONT_END_DOMAIN','PANEL_DOMAIN','NODE_PORT','SUB_PUBLIC_DOMAIN'}:env[key]=value.strip().strip('"\'')
panel=sys.argv[2] or s.get('panelDomain') or env.get('FRONT_END_DOMAIN') or env.get('PANEL_DOMAIN','')
if panel and not panel.startswith(('http://','https://')):panel='https://'+panel
tls=s.get('tls',{})
subscriptions=s.get('subscriptionUrls',[])
primary=env.get('SUB_PUBLIC_DOMAIN','')
if primary:
 primary=primary if primary.startswith(('http://','https://')) else 'https://'+primary
 subscriptions=[primary]+[url for url in subscriptions[1:] if url!=primary]
for value in [directory,panel,sys.argv[3] or s.get('nodeDomain',''),s.get('apiPort') or s.get('nodePort') or s.get('port') or sys.argv[4] or env.get('NODE_PORT',''),s.get('proxy',sys.argv[5]),tls.get('method',sys.argv[6]),tls.get('certificate',sys.argv[7]),tls.get('key',sys.argv[8]),', '.join(s.get('composeFiles',[])),', '.join(subscriptions)]:
 print(str(value).replace('\n',' ').replace('\r',' '))
PY
    mapfile -t details < "$WORK/completion-details"
    local directory=${details[0]} url=${details[1]} node_domain=${details[2]} port=${details[3]} proxy=${details[4]} method=${details[5]} certificate=${details[6]} key=${details[7]}
    local heading='Установка завершена'
    case "$ACTION" in upgrade-*) heading='Обновление завершено';; migrate-*) heading='Перенос завершён';; esac
    terminal_section "$heading"
    completion_row 'Компонент:' "$COMPONENT v${COMPONENT_VERSION:-${TAG#v}} · установщик $TAG"
    if [[ $COMPONENT == panel ]]; then
        if [[ -n $url ]]; then completion_row 'Адрес входа:' "$url"
        else completion_row 'Адрес входа:' 'Ваш прежний домен панели'; fi
        if [[ -n ${details[9]} ]]; then
            local -a subscriptions=()
            IFS=',' read -r -a subscriptions <<< "${details[9]}"
            completion_row 'Сайт подписки:' "${subscriptions[0]}"
            if ((${#subscriptions[@]} > 1)); then completion_row 'Дополнительный адрес:' "${subscriptions[1]# }"; fi
        fi
        if [[ $ACTION == install-panel ]]; then
            completion_row 'Администратор:' 'Создайте аккаунт при первом входе'
            completion_row 'Пароль:' 'От 24 символов: A–Z, a–z и цифры'
            if [[ -f $directory/backup-password.txt && ! -L $directory/backup-password.txt ]]; then
                completion_row 'Пароль резервных копий:' "$(cat "$directory/backup-password.txt")"
                completion_row 'Сохранён в файле:' "$directory/backup-password.txt · доступ только root"
                completion_row 'Резервные копии:' 'Используйте этот пароль для открытия раздела и расшифровки копий; сохраните отдельно от сервера'
            fi
        else completion_row 'Авторизация:' 'Прежние имя пользователя и пароль'; fi
        if [[ $proxy == caddy ]]; then completion_row 'HTTPS:' 'Caddy в Docker'
        else
            completion_row 'HTTPS:' 'Ваш существующий Nginx/Caddy'
            completion_row 'Сертификат:' 'Путь указан в конфигурации вашего proxy; установщик его не меняет'
        fi
        if [[ -n $(managed_subscription_options) ]]; then
            completion_row 'Сайт подписки установлен:' 'Токен только для чтения подписок и оформления'
            completion_row 'Настройки сайта:' "$directory/subscription.env · доступ только root"
            if [[ $proxy == existing ]]; then
                completion_row 'Upstream сайта:' "http://127.0.0.1:$(get subscriptionPort) · для обоих доменов сайта"
                completion_row 'Пример Caddy:' "$directory/Caddyfile · внутри Docker; для системного proxy используйте loopback upstream"
            fi
        fi
    else
        local addresses address
        if addresses=$(server_addresses 2>/dev/null); then
            while IFS= read -r address; do
                completion_row 'Адрес в панели:' "$address"
            done <<< "$addresses"
        else completion_row 'Адрес в панели:' 'Публичный IP этого сервера (не IP панели)'; fi
        completion_row 'API ноды:' "Адрес этого сервера · TCP ${port:-2222}"
        completion_row 'Порт в панели:' "${port:-2222}"
        completion_row 'Подключение:' 'Ноды → создать/редактировать → адрес, порт ноды и профиль'
        completion_row 'SSH:' 'Отдельный порт доступа к серверу; установщик его не меняет'
        [[ -z $node_domain ]] || completion_row 'TLS/XHTTP домен:' "$node_domain"
        local site_mode site_port inbound_port
        site_mode=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("nodeSiteMode","selfsteal"))' "$STATE")
        if [[ $site_mode == standalone ]]; then
            site_port=$(get nodeSitePort); inbound_port=$(get nodeInboundPort)
            completion_row 'HTTPS-сайт:' "https://$node_domain:$site_port/"
            completion_row 'Вход Xray в панели:' "TCP $inbound_port — задайте этот порт в профиле"
            completion_row 'REALITY target:' "127.0.0.1:$site_port · xver: 0"
        fi
        if [[ $ACTION == install-node ]]; then completion_row 'Ключ ноды:' "$directory/.env · SECRET_KEY"
        else completion_row 'Ключ ноды:' 'Сохранён из прежнего контейнера · SECRET_KEY в Compose'; fi
    fi
    completion_row 'Карта файлов:' "$directory/FILES.txt (скрытые .env: ls -la)"
    completion_row 'Файл настроек:' "$directory/.env"
    [[ -z ${details[8]:-} ]] || completion_row 'Compose:' "${details[8]}"
    if [[ -n $certificate ]]; then
        completion_row 'Исходный сертификат:' "$certificate"
        completion_row 'Исходный ключ TLS:' "$key"
        completion_row 'Копия сертификата:' "$directory/certs/fullchain.pem"
        completion_row 'Копия ключа TLS:' "$directory/certs/privkey.pem"
        if [[ $COMPONENT == node ]]; then completion_row 'В Xray:' '/var/lib/remnacust/tls/fullchain.pem и /var/lib/remnacust/tls/privkey.pem'; fi
        if [[ $method == existing ]]; then completion_row 'После продления:' "remnacust renew-$COMPONENT-certificate"
        else completion_row 'Продление TLS:' "remnacust-acme-$(get project).timer"; fi
    elif [[ $COMPONENT == panel && $proxy == caddy ]]; then
        completion_row 'Сертификат:' 'Caddy получает и продлевает автоматически; хранилище /data в контейнере caddy'
    fi
    completion_row 'Состояние:' "remnacust status --component $COMPONENT"
    completion_row 'Журнал приложений:' "remnacust logs --component $COMPONENT"
    [[ -z $LOG ]] || completion_row 'Журнал установки:' "$LOG"
    printf '\n'
}
helper_file_copy() {
    python3 - "$HELPER" "$1" "$2" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location('installer_runtime',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.write(sys.argv[3],m.load(sys.argv[2]))
PY
}
service_action() {
    if [[ $ACTION == uninstall-* ]]; then
        command -v python3 >/dev/null || die 'Для удаления нужен python3'
        command -v docker >/dev/null || die 'Docker недоступен'
        lock_operation; uninstall_component; return
    fi
    if [[ $ACTION != status || -n $COMPONENT ]]; then
        COMPONENT=${COMPONENT:-panel}; assert_not_uninstalled
    fi
    installed_helper; lock_operation
    if [[ $ACTION == status && -z $COMPONENT ]]; then
        local item found=false
        for item in panel node; do if [[ -f $ROOT/registry/$item.json ]]; then STATE="$ROOT/registry/$item.json"; load_state; compose ps --all; found=true; fi; done
        python3 -I "$HELPER_ROOT/subscription_pages.py" list --root "$ROOT" > "$WORK/managed-page-status.json"
        if [[ $(cat "$WORK/managed-page-status.json") != '[]' ]]; then cat "$WORK/managed-page-status.json"; found=true; fi
        $found || info 'Нет зарегистрированных установок'; return 0
    fi
    COMPONENT=${COMPONENT:-panel}; STATE="$ROOT/registry/$COMPONENT.json"
    if [[ ! -f $STATE ]]; then
        IMAGE=discovery-only
        find_existing
    else load_state; fi
    assert_not_uninstalled
    case "$ACTION" in
        status) compose ps --all;;
        check-panel)
            DOMAIN=${DOMAIN:-$(get panelDomain)}
            [[ -n $DOMAIN ]] || die 'Домен не записан в старой установке; укажите check-panel --domain DOMAIN'
            PROXY=$(get proxy)
            TLS_METHOD=$(python3 - "$STATE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get('tls',{}).get('method','auto'))
PY
            )
            if [[ $PROXY == caddy && $TLS_METHOD == auto ]]; then check_dns "$DOMAIN" || return 1; fi
            if [[ $PROXY == caddy && $TLS_METHOD == auto && -n $(managed_subscription_options) ]]; then
                local checked_hosts host; local -a subscription_hosts=()
                checked_hosts=$(helper subscription-domains --domain "$DOMAIN" --subscription-urls "$(managed_subscription_options)") || return 1
                mapfile -t subscription_hosts <<< "$checked_hosts"
                for host in "${subscription_hosts[@]}"; do check_dns "$host" || return 1; done
            fi
            if ! step 'Ожидание HTTPS панели (до 3 минут)' wait_panel_https; then https_diagnostics; return 1; fi
            if ! step 'Проверка HTTPS сайта подписки' wait_subscription_https; then https_diagnostics; return 1; fi
            info "✓ Панель отвечает по HTTPS: https://$DOMAIN";;
        logs) compose logs --tail 100 --no-color "${APPS[@]}" "${EXTRAS[@]}";;
        start)
            mapfile -t START_APPS < <(get runningApplications)
            ((${#START_APPS[@]})) || START_APPS=("${APPS[@]}")
            local extra
            for extra in "${EXTRAS[@]}"; do [[ " ${START_APPS[*]} " == *" $extra "* ]] || START_APPS+=("$extra"); done
            if [[ $COMPONENT == panel && -n $(managed_subscription_options) ]]; then
                [[ " ${START_APPS[*]} " == *' remnawave-subscription-page '* ]] || START_APPS+=(remnawave-subscription-page)
            fi
            if [[ $COMPONENT == panel && -n $(managed_subscription_options) && ! -s $DEPLOY/subscription.env ]]; then
                local -a bootstrap_apps=()
                for extra in "${START_APPS[@]}"; do [[ $extra == remnawave-subscription-page ]] || bootstrap_apps+=("$extra"); done
                local -a START_APPS=("${bootstrap_apps[@]}")
                compose up -d --no-build --pull never "${START_APPS[@]}"
                wait_ready
                step 'Подключение сайта подписки' initialize_subscription_page
            else compose up -d --no-build --pull never "${START_APPS[@]}"; fi
            ;;
        stop) confirm 'Остановить приложения'; compose stop "${APPS[@]}" "${EXTRAS[@]}";;
        restart) confirm 'Перезапустить приложения'; compose restart "${APPS[@]}" "${EXTRAS[@]}";;
        backup-panel)
            docker inspect "$(compose ps --all --quiet "$(get mainService)")" > "$WORK/container.before.json"
            IMAGE=$(get image); database_environment; backup_current;;
        restore-panel) restore_panel;;
        renew-node-certificate|renew-panel-certificate) renew_certificate;;
        uninstall-panel|uninstall-node) uninstall_component;;
        *) die 'Неизвестное действие обслуживания';;
    esac
}
uninstall_component() {
    local -a ids=() removed=()
    local snapshot="$ROOT/backups/uninstall-$COMPONENT-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    if [[ $COMPONENT == node ]]; then installed_helper || return $?; fi
    docker ps --all --quiet --no-trunc > "$WORK/uninstall-inventory.ids" || die 'Не удалось проверить Docker; удаление не выполнялось'
    mapfile -t ids < "$WORK/uninstall-inventory.ids"
    if ((${#ids[@]})); then docker inspect "${ids[@]}" > "$WORK/uninstall-inventory.json" || die 'Не удалось прочитать контейнеры; повторите удаление'
    else printf '[]' > "$WORK/uninstall-inventory.json"; fi
    python3 - "$WORK/uninstall-inventory.json" "$ROOT/registry/$COMPONENT.json" "$COMPONENT" "$DIRECTORY" "$CONTAINER" "$PROJECT" "$COMPOSE_FILE" "$ROOT" "$WORK" <<'PY'
import json,re,sys
from pathlib import Path
inventory,registry,kind,directory,container,project,compose_file,root,work=sys.argv[1:]
all_containers=json.load(open(inventory));record={};registry_path=Path(registry)
if registry_path.is_symlink():raise SystemExit('Запись установки не должна быть символьной ссылкой')
if registry_path.is_file():
 try:record=json.loads(registry_path.read_text())
 except (ValueError,OSError):record={}
 if not isinstance(record,dict) or record.get('component')!=kind:record={}
def labels(c):return c.get('Config',{}).get('Labels') or {}
def group(c):return labels(c).get('com.docker.compose.project','')
def service(c):return labels(c).get('com.docker.compose.service','')
def image(c):return c.get('Config',{}).get('Image','')
def protected(c):return image(c).split('@')[0].rsplit('/',1)[-1].split(':')[0] in {'caddy','nginx','nginx-proxy','nginx-proxy-manager','traefik','postgres','postgresql','valkey','redis'}
def app(c):
 env=dict(v.split('=',1) for v in c.get('Config',{}).get('Env',[]) if '=' in v)
 return not protected(c) and (service(c)==('remnawave' if kind=='panel' else 'remnanode') or ('remnacust-'+kind) in image(c) or (kind=='panel' and env.get('INSTANCE_TYPE') in {'api','processor','scheduler'}))
def working(c):
 value=labels(c).get('com.docker.compose.project.working_dir','')
 return str(Path(value).resolve()) if value else ''
selector=directory or (str(Path(compose_file).resolve().parent) if compose_file else '')
if selector:selector=str(Path(selector).resolve())
expected='remnacust-'+kind
explicit=[]
if container:
 explicit=[c for c in all_containers if c['Id'].startswith(container) or c.get('Name','').lstrip('/')==container]
 if len(explicit)!=1:raise SystemExit('Контейнер не найден либо идентификатор неоднозначен')
 if not app(explicit[0]) and not (group(explicit[0])==expected or labels(explicit[0]).get('io.remnacust.installer-managed')==kind):raise SystemExit('Указанный контейнер не принадлежит выбранному компоненту')
 project=group(explicit[0]) or ''
 if selector and working(explicit[0])!=selector:raise SystemExit('Указанный каталог не совпадает с контейнером')
elif project:
 explicit=[c for c in all_containers if group(c)==project and (not selector or working(c)==selector)]
elif record.get('project') and (not selector or str(Path(record.get('directory','')).resolve())==selector):
 project=record['project']
 explicit=[c for c in all_containers if group(c)==project]
else:
 candidates=[c for c in all_containers if (not selector or working(c)==selector) and (group(c)==expected or labels(c).get('io.remnacust.installer-managed')==kind or (app(c) and 'remnacust-'+kind in image(c)))]
 projects={group(c) for c in candidates if group(c)}
 if len(projects)>1:raise SystemExit('Найдено несколько установок: укажите --container или --directory')
 project=next(iter(projects),'')
 explicit=candidates
if project:
 peers=[c for c in all_containers if group(c)==project]
 anchors=[c for c in explicit if app(c)]
 same_record=record.get('project')==project
 owned=record.get('ownedServices') if same_record else None
 if owned is not None and (not isinstance(owned,list) or any(not isinstance(v,str) or not v or v.startswith('-') for v in owned)):raise SystemExit('Неверный список собственных сервисов в записи установки')
 if owned is not None:
  selected=[c for c in peers if service(c) in owned or (kind=='node' and service(c)=='node-nginx' and service(c) in record.get('extraServices',[]) and labels(c).get('io.remnacust.installer-managed')=='node')]
 elif project==expected:selected=peers
 else:
  app_images={image(c) for c in anchors}
  selected=[c for c in peers if labels(c).get('io.remnacust.installer-managed')==kind or (app(c) and (image(c) in app_images or service(c) in record.get('applications',[])))]
else:selected=explicit
if not selected and not record and not selector:raise SystemExit('Не найдены контейнеры компонента; укажите --container или --directory')
if any(not re.fullmatch(r'[a-f0-9]{64}',c.get('Id','')) for c in selected):raise SystemExit('Некорректный идентификатор контейнера')
anchor=next((c for c in selected if app(c)),selected[0] if selected else {})
path=selector or (record.get('directory') if record.get('project')==project else '') or working(anchor) or str(Path(root)/kind)
path=str(Path(path).resolve())
if path in {'/','/opt','/usr','/etc','/root'}:raise SystemExit('Небезопасный каталог установки')
files=record.get('composeFiles',[]) if record.get('project')==project else []
if not files:
 files=[str((Path(path)/f).resolve()) for f in labels(anchor).get('com.docker.compose.project.config_files','').split(',') if f]
if compose_file:files=[str(Path(compose_file).resolve())]
state=record.copy() if record.get('project')==project else {}
proxies=[service(c) for c in selected if image(c).split('@')[0].rsplit('/',1)[-1].split(':')[0] in {'caddy','nginx'} and service(c)]
state.update({'schema':1,'component':kind,'directory':path,'project':project or expected,'composeFiles':files,'mainService':state.get('mainService') or service(anchor),'applications':state.get('applications') or list(dict.fromkeys(service(c) for c in selected if app(c) and service(c))),'extraServices':state.get('extraServices',proxies),'image':state.get('image') or image(anchor),'uninstalled':True,'recoverable':False,'reinstallOnly':True})
if 'runningApplications' not in state:state['runningApplications']=list(dict.fromkeys(service(c) for c in selected if c.get('State',{}).get('Running') and service(c) and (app(c) or service(c) in proxies)))
if not state.get('ownedServices'):state['ownedServices']=list(dict.fromkeys(service(c) for c in selected if service(c)))
p=Path(work)
(p/'uninstall-containers.json').write_text(json.dumps(selected,indent=2)+'\n')
(p/'uninstall-state.json').write_text(json.dumps(state,indent=2)+'\n')
(p/'uninstall-targets.ids').write_text(''.join(c['Id']+'\n' for c in selected))
PY
    mapfile -t removed < "$WORK/uninstall-targets.ids"
    info "Будут удалены контейнеры $COMPONENT (${#removed[@]}):"
    python3 - "$WORK/uninstall-containers.json" <<'PY'
import json,sys
for c in json.load(open(sys.argv[1])):print('    '+c.get('Name',c['Id']).lstrip('/'))
PY
    confirm "Удалить контейнеры $COMPONENT. Томы, БД, файлы и сертификаты сохраняются"
    install -d -m 0700 "$snapshot"
    install -m 0600 "$WORK/uninstall-containers.json" "$snapshot/containers.json"
    install -m 0600 "$WORK/uninstall-state.json" "$snapshot/state.json"
    [[ ! -f $ROOT/registry/$COMPONENT.json ]] || install -m 0600 "$ROOT/registry/$COMPONENT.json" "$snapshot/registry.before.json"
    if ((${#removed[@]})); then step 'Удаление найденных контейнеров' remove_container_ids "${removed[@]}"; fi
    python3 - "$WORK/uninstall-state.json" "$snapshot" "$ROOT/registry/$COMPONENT.json" <<'PY'
import json,os,sys
from pathlib import Path
p=Path(sys.argv[1]);s=json.loads(p.read_text());s['uninstallSnapshot']=sys.argv[2]
directory=Path(s['directory'])
if directory.is_dir() and not directory.is_symlink():(directory/'.remnacust-uninstalled').touch(mode=0o600)
target=Path(sys.argv[3]);pending=target.with_suffix('.json.pending')
pending.write_text(json.dumps(s,indent=2)+'\n');pending.chmod(0o600);os.replace(pending,target)
print('Данные и прежний каталог: '+s['directory'])
print('Повторная установка: remnacust install-'+s['component'])
PY
    if [[ $COMPONENT == node ]]; then
        local renewal_project
        node_firewall_cleanup "$WORK/uninstall-state.json" || return $?
        renewal_project=$(python3 -c 'import json,re,sys;p=json.load(open(sys.argv[1]))["project"];assert re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,62}",p);print(p)' "$WORK/uninstall-state.json") || return $?
        if [[ -f /etc/systemd/system/remnacust-acme-$renewal_project.timer && ! -L /etc/systemd/system/remnacust-acme-$renewal_project.timer ]]; then
            systemctl disable --now "remnacust-acme-$renewal_project.timer" || return $?
        fi
    fi
    info "$COMPONENT удалён. Копия описаний контейнеров: $snapshot"
}
remove_container_ids() {
    # IDs are immutable; never remove by a name that another process can reuse.
    docker stop --time 30 "$@" || true
    docker rm --force "$@" || true
    docker ps --all --quiet --no-trunc > "$WORK/uninstall-after.ids" || return 1
    python3 - "$WORK/uninstall-after.ids" "$@" <<'PY'
import sys
remaining=set(open(sys.argv[1]).read().splitlines()).intersection(sys.argv[2:])
if remaining:raise SystemExit('Docker не удалил все выбранные контейнеры; данные и запись установки сохранены')
PY
}
restore_panel() {
    [[ -n $BACKUP && -d $BACKUP && ! -L $BACKUP ]] || die 'Укажите --backup с каталогом копии'
    local requested; requested=$(realpath "$BACKUP")
    helper verify-backup --directory "$requested"
    docker inspect "$(compose ps --all --quiet "$(get mainService)")" > "$WORK/container.before.json"
    IMAGE=$(python3 - "$WORK/container.before.json" <<'PY'
import json,re,sys
image=json.load(open(sys.argv[1]))[0]['Image']
if not re.fullmatch(r'sha256:[a-f0-9]{64}',image):raise SystemExit('Не определён установленный образ панели')
print(image)
PY
    )
    helper_file_copy "$STATE" "$WORK/restore-current-state.json"
    compose --profile '*' config --no-interpolate --no-env-resolution --format json > "$WORK/restore-current-compose.json"
    compose --profile '*' config --no-env-resolution --format json > "$WORK/restore-environment-paths.json"
    compose --profile '*' config --format json > "$WORK/restore-current-effective.json"
    helper plan-panel-data-restore --source "$WORK/restore-current-compose.json" --state "$WORK/restore-current-state.json" \
        --roles "$WORK/restore-current-effective.json" --environment-source "$WORK/restore-environment-paths.json" \
        --current-inspect "$WORK/container.before.json" --directory "$requested" --image "$IMAGE" \
        --plan "$WORK/panel-restore-plan.json" --target "$WORK/panel-restore-compose.json"
    docker compose --project-name "$PROJECT" --project-directory "$DEPLOY" -f "$WORK/panel-restore-compose.json" --profile '*' config --quiet
    confirm "Восстановить данные и ключи из $requested; установленная версия и подключения сохранятся"
    database_environment; check_writers
    backup_current; info "Копия текущей БД перед восстановлением: $BACKUP"
    compose stop "${APPS[@]}"
    # Do not start an old panel against a partially restored database on failure.
    CHANGED=true; DB_CHANGED=true; trap recover ERR
    helper validate-panel-data-restore --source "$WORK/panel-restore-plan.json"
    python3 - "$WORK/panel-restore-plan.json" "$WORK/database.env" <<'PY'
import json,pathlib,sys
values=json.load(open(sys.argv[1]))['database']
if set(values)!={'DATABASE_URL','APP_SECRET'} or any('\n' in v or '\r' in v for v in values.values()):raise SystemExit('Некорректные данные восстановления')
pathlib.Path(sys.argv[2]).write_text(''.join(k+'='+v+'\n' for k,v in values.items()))
PY
    RESTORE_DUMP="$requested/database.dump"
    step 'Восстановление схемы и данных одной транзакцией' restore_dump
    # Persist the restored signing identity even if a later migration fails.
    # Creating the API container stopped makes the next backup/restore inspect
    # the correct key without publishing an API or starting dependent services.
    helper commit-panel-data-restore --source "$WORK/panel-restore-plan.json" --state "$WORK/panel-restored-state.json"
    STATE="$WORK/panel-restored-state.json"; load_state
    helper_file_copy "$STATE" "$ROOT/registry/panel.json"
    compose up --no-start --no-deps --no-build --pull never "$(get mainService)"
    refresh_restored_update_identity
    step 'Совместимость восстановленной базы' docker run --rm --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" --entrypoint node "$IMAGE" dist/database-compatibility.js --apply
    step 'Защита резервов после восстановления' quarantine_restored_quotas
    refresh_restored_subscription_page
    load_restore_apps
    if ((${#START_APPS[@]})); then
        compose up -d --no-deps --no-build --pull never "${START_APPS[@]}"
        step 'Проверка восстановленной панели' wait_ready
    else
        info 'База восстановлена; приложения остаются остановленными'
    fi
    BACKUP=$requested
    if [[ -f $BACKUP/fingerprints.json ]]; then step 'Проверка данных восстановленной панели' verify_database; fi
    helper_file_copy "$STATE" "$ROOT/registry/panel.json"; CHANGED=false; trap - ERR
    info 'Копия восстановлена'
}


refresh_restored_update_identity() {
    [[ -e $ROOT/update-agent.json || -L $ROOT/update-agent.json ]] || return 0
    local script="${HELPER%/*}/update-agent.py"
    [[ -f $script ]] || die 'Не найден помощник обновления панели'
    docker inspect "$(compose ps --all --quiet "$(get mainService)")" > "$WORK/container.restored.json"
    python3 "$script" --root "$ROOT" restore-identity --inspect "$WORK/container.restored.json"
}

refresh_restored_subscription_page() {
    local count script token_uuid
    count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("subscriptionServices",[])))' "$WORK/panel-restore-plan.json")
    [[ $count != 0 ]] || return 0
    script="${HELPER%/*}/subscription.cjs"
    [[ -f $script ]] || die 'Не найден помощник настройки сайта подписки'
    token_uuid=$(get subscriptionTokenUuid)
    # Credential stdout must never enter the operation log. Provisioning honors
    # token expiry/scope revocations and does not start the page or API.
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" \
        --env "REMNACUST_SUBSCRIPTION_TOKEN_UUID=$token_uuid" --entrypoint node "$IMAGE" - \
        < "$script" > "$WORK/subscription-token.txt"
    chmod 600 "$WORK/subscription-token.txt"
    helper restore-panel-subscription-token --plan "$WORK/panel-restore-plan.json" --source "$WORK/subscription-token.txt"
    rm -f -- "$WORK/subscription-token.txt"
}

quarantine_restored_quotas() {
    # Called with all panel writers stopped, after migration and before start.
    # Existing node reserves keep working; restored SQL cannot mint fresh credit.
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" --entrypoint node "$IMAGE" - <<'JS'
const {spawnSync}=require('node:child_process');const u=new URL(process.env.DATABASE_URL);
const env={...process.env,PGHOST:u.hostname,PGPORT:u.port||'5432',PGUSER:decodeURIComponent(u.username),PGPASSWORD:decodeURIComponent(u.password),PGDATABASE:decodeURIComponent(u.pathname.slice(1))};
if(u.searchParams.has('sslmode'))env.PGSSLMODE=u.searchParams.get('sslmode');
const sql="DO $$ BEGIN IF to_regprocedure('public.xera_quarantine_restored_quotas()') IS NOT NULL THEN PERFORM public.xera_quarantine_restored_quotas(); END IF; END $$";
const result=spawnSync('psql',['--quiet','--set','ON_ERROR_STOP=on','-c',sql],{env,stdio:'inherit'});process.exit(result.status??1);
JS
}
restore_dump() {
    docker run --rm -i --network "$(cat "$WORK/database.network")" --env-file "$WORK/database.env" \
        --mount "type=bind,src=$RESTORE_DUMP,dst=/tmp/database.dump,readonly" --entrypoint node "$IMAGE" - <<'JS'
const {spawnSync,spawn}=require('node:child_process'),fs=require('node:fs');const u=new URL(process.env.DATABASE_URL);
const env={...process.env,PGHOST:u.hostname,PGPORT:u.port||'5432',PGUSER:decodeURIComponent(u.username),PGPASSWORD:decodeURIComponent(u.password),PGDATABASE:decodeURIComponent(u.pathname.slice(1))};
if(u.searchParams.has('sslmode'))env.PGSSLMODE=u.searchParams.get('sslmode');
const schemas=spawnSync('psql',['-At','-c',"SELECT count(*) FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname NOT IN ('public','information_schema')"],{env,encoding:'utf8'});
if(schemas.status!==0||schemas.stdout.trim()!=='0'){console.error('Automatic restore requires a dedicated database with only the public user schema');process.exit(1)}
const sql='/tmp/restore.sql';const generated=spawnSync('pg_restore',['--file',sql,'/tmp/database.dump'],{env,stdio:'inherit'});
if(generated.status!==0)process.exit(generated.status??1);
const fd=fs.openSync(sql,'r'),head=Buffer.alloc(65536),count=fs.readSync(fd,head,0,head.length,0);fs.closeSync(fd);const prefix=head.subarray(0,count).toString('utf8');
const create=/^CREATE SCHEMA (?:public|"public");$/m.test(prefix)?'':'CREATE SCHEMA public;\n';
const child=spawn('psql',['--quiet','--set','ON_ERROR_STOP=on'],{env,stdio:['pipe','inherit','inherit']});
child.on('error',()=>process.exit(1));child.stdin.on('error',()=>{});
child.stdin.write('BEGIN;\nDROP SCHEMA public CASCADE;\n'+create);
const input=fs.createReadStream(sql);input.on('error',()=>{child.stdin.destroy();process.exitCode=1});
input.pipe(child.stdin,{end:false});input.on('end',()=>child.stdin.end('\nCOMMIT;\n'));
child.on('close',code=>process.exit(code??1));
JS
}

renew_certificate() {
    local domain certificate key
    local -a subscription_options=(); local subscriptions
    subscriptions=$(managed_subscription_options)
    [[ -z $subscriptions ]] || subscription_options=(--subscription-urls "$subscriptions")
    local -a tls_paths=()
    domain=$(get nodeDomain); [[ $COMPONENT != panel ]] || domain=$(get panelDomain)
    [[ -n $domain ]] || die 'У этой установки нет управляемого сертификата'
    if [[ -n ${RENEWED_LINEAGE:-} ]]; then
        [[ $(python3 - "$STATE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get('uninstalled',False))
PY
        ) != True ]] || return 0
    fi
    if ! tls_helper paths --state "$STATE" > "$WORK/tls-paths"; then
        # Compatibility with node certificates installed before TLS metadata was introduced.
        [[ $COMPONENT == node ]] || die 'Caddy панели сам продлевает автоматический сертификат'
        certificate="/etc/letsencrypt/live/$domain/fullchain.pem"; key="/etc/letsencrypt/live/$domain/privkey.pem"
    else
        mapfile -t tls_paths < "$WORK/tls-paths"; certificate=${tls_paths[0]}; key=${tls_paths[1]}
    fi
    if [[ -n ${RENEWED_LINEAGE:-} && $(realpath -m "$RENEWED_LINEAGE") != $(realpath -m "$(dirname "$certificate")") ]]; then return 0; fi
    tls_helper copy --domain "$domain" --certificate "$certificate" --key "$key" --directory "$DEPLOY" "${subscription_options[@]}"
    if [[ $COMPONENT == panel ]]; then
        compose exec -T caddy caddy reload --force --config /etc/caddy/Caddyfile --adapter caddyfile
        info 'Сертификат обновлён; Caddy перечитал конфигурацию'
    else compose restart "${EXTRAS[@]}" "${APPS[@]}"; info 'Сертификат обновлён; Nginx и нода перезапущены'; fi
}
migrate_marzban() {
    prepare_host; lock_operation; release_source
    [[ -n $MARZBAN_URL ]] || MARZBAN_URL=$(ask_required 'URL Marzban (https://...)')
    [[ -n $DESTINATION_URL ]] || DESTINATION_URL=$(ask_required 'URL установленной Remnacust (https://...)')
    [[ -n $INTERNAL_SQUAD ]] || INTERNAL_SQUAD=$(ask_required 'UUID внутреннего сквада в Remnacust')
    local output; output="$ROOT/backups/marzban-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    local -a args=(--source-url "$MARZBAN_URL" --destination-url "$DESTINATION_URL" --internal-squad "$INTERNAL_SQUAD" --quota-mode "$QUOTA_MODE" --output "$output")
    $YES && args+=(--yes); $DRY_RUN && args+=(--dry-run); $PRESERVE_SUBHASH && args+=(--preserve-subhash)
    python3 "$HELPER_ROOT/marzban.py" "${args[@]}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

# REMNACUST_HELPERS_V1
# DATA H4sIAAAAAAAC/+y9a3MjyXUgqs/1K2oohQHMgCAeBECyRY05bPYMrW6yTbJnNObQ2EJVgSw1gIKrALKpNiNsa/feG+GN61+w9xH3
# DATA D8he61rrtaS/0P2P9rzyVSiQ7JE1jl2rbQ0BVFbmyZMnzztPPj/cPzg6Pfje7/NfE/71NjfpL/xz/7aa7Va7p36T33v97ub3/Ob3
# DATA voN/i3weZDDk9/59/vv86JW/9+zZwcmx//nB0cHJ3nP/5avPnh/u+8+ZMrwv4yxP0qnfqfvb/p8E00WQ3frtZrvrefvp7DZLLq/m
# DATA fnW/Rr/5J/FkGtwE17H/w6v5fJbvbGxcJvOrxbARppONTD39kXdwHWe36TT2k9yfxdkkmc/jyJ+nfgid+sE08qMkn2fJcDGPfWg7
# DATA DObJBB8mce6lI39+BS+OkzCe5rEfpeFiEk/ndR+a++FVML1Mppd+Msfep+ncD8bj9CaOGp7ny7+XWRxMhuPY886uYp/QMBrFWep/
# DATA Hk/jLBj7LxdD6N5/LkNAR4E/yuK4ThCO49FcDz9KMy9PR/ObIIsJ9HR+FWf+62Qa5T7AepNmr/O6n8/iMBklIQBz60dxnlxOecrQ
# DATA ySKLvTBNARMwT8D2DSAN5hjDYJPJYprMb/1kyj8EMCJ0Oo3n2K+fxxmgx1fjN3hCAlqOsPmTNJ/7JQDOsiCcIzwMoY9PFVwewDUP
# DATA XkPzm+DWv00XGc0+SicIcX6leiJkxwQZddLw/c9uAerpPAvyed3DF8tRyuMl03k8jRgPl0BbAXyPi+N5S+MBDpEqkDIJxQFMJr3M
# DATA gsn6OnQ0QcARp0gCQHRBAq2wO7NMiBfsJJnn/gJwmAPivrqKAfMxLlTwGnvFVzTi6vgIX81iIJQMCQyGEiDrSGbeLIOpAQaOH5i0
# DATA vfgG1vlVMMeZe1e4fxCjFsat3cCbYAk+vyr4yS6ZJKGHiZ+MsEugp/yqVtdDwBzCOLnGlxdZiF1GQFQZENfUv4zntHPoRe8GFgS+
# DATA Wq9iG2vV9fDwOiDSB9hChg47mQKd3ngEpywQbASEU3f3epre6H6jFPvMsWfAL67J0/g6HuO+yPkVHOI+moJR5nE4Zwoi5pR7vJlu
# DATA gGznMbAkv9qq+UEOiz6nvcwsLJ0602Eoq+0azASW20MIiecohnBzlYRX/iUgMSfwx/ElgEOsLCeGKbysbi2dB31u0IaMktGtMx5M
# DATA dQ/2MmycCBnsEKY3AgQCGiMgt2mE5Ib0SrRa0ZSRMFq8ZAITv46RCeZAUhFuLGg/j7NpwAxUbxUcVdaijqsM3289RQ83CdDmDHhj
# DATA hCMBPwWIJkD210EyDoBd0r5h7hFZK5N6yTRMs1kK7As3wItgems3WKJV/N9VHGSw+WEbAFq8GDpYZMElfB0yarI4X4znOHGLM0Ln
# DATA XwArhwnVCxzR7G2APML1dFlkXucF5G4BSbf+CGbF64RzHKaLeUOLgxVygGUV4vg1LQmvZQIDCo5pMuN4ToATrrmDIIRtkeOmwDaK
# DATA bSNpwrA+TgggG8dBzpIr9+ytOU+trhofILM0p3GED6wXyxwiHkJkvgBqRkwSmmIzLRsMpobckIMngGkpBctziCz3LxYJ4Jme8dIh
# DATA 2SCbLogtgAQJN4kUM7HY0cgFROE3W0yngttMYcajbcGvAJPgzgGWM2wDJAuULMuwYOm5vG51WBcvkGaAI16vBGmeu6vLZl9eU0EC
# DATA A+/dBzzu8qmfjiOYuoho0CdgTVAWQPv71xMpi0bOr3iXcHMQTEHuyBSAK53MsJ2fJxNYqsy/TINxThgBqkhymClABm8DwzCQkKqk
# DATA ES1zUDC9fM7qlXy/CnKPCRY3MLL51S8Ks1R7B16jEXEVFyD8UVQZbU7IG5hQmKAkgJdyFv3AG5M5sTHkQshcoQeLv6rdx1gPWZMa
# DATA paj7YacHJy9O/b2jp/7+8dHTw7PD46NTz2s2/KfAaafcMTRbO7O4/BoLe1piNbuOmt+DGxB70zryGrDjHMR9HAD8WuysjxMQ/+Pg
# DATA RsRbMJvR/iyokJ5SIXGXwmLn8SRBdCxC3FiTIH8toMeg2BJrtyFHZqxHJC5OW1DwHfEaEHP0FOS+fxDAUNKE1d8ogi1Nq537ayDy
# DATA 1qDVmrwQ52uE+jVcNVABQAytEYsdoiSKEtjhC5g/KglpdhlMk58FCuFnqb/GAhG6YMgYScoYGGUg6FBdi4IZqfL4ZQayQy0EvuOh
# DATA vAOGnl8RjyAGxKJDCXgjmuuCXcA4SxBh5sgXpl78BrRieo8ZiCWHCDhAhezYQAC3NviawOSBbBsnyODxFQSeP60NAxZOazSw3Yo0
# DATA gLUQpHgGLfCXNUFEnAi4INqmekRZaKtz6tsTRUYeC4KByc6CSxDOyziOiEBI4WKzA0QUiwURTp6NuZt0MY5YaUWtJwI2H86BZAEK
# DATA pb0k8HWcKG0BFmaEK0G6iZAaUjnsT2xh1gc2Qd2P34QxLHL8Jg4Xc7HhcFd7yNBAg0LyEfWJxS+o3NcBK8W4Xi9lnkgEoJKMF8AW
# DATA NafwHE5RpcmmRgbbbAN0ZSXhteojooZ5P+uHKDhRdwDVBQwe0sppqdCuugaWgrIyB7thPJZ1AAxdx0VCx/2JOx1pZ2ZNgDhCPMXB
# DATA pWMPyR57VYZDmmlVns0CVL5isavIvFPGZECqI/SZpYvLK+D/GqMiknm9QQb4YLpN81EsEpuVWDGkGX7AC0syPcp1zN3TD6MAZDjg
# DATA ejYOboFV7M1wUlmCy/SctOSjFMxOYBlKfYjfzJE4aL5kNcjCBTzeFPkJ4Rs6miRT+AYkdp2QdPZGcTDX5hOq9npk2N2BNbYhtSmN
# DATA r1V8bw4LxIJdcBTMRb2gaYN8zdAwvSW5oziOXxViFbqwJyEvJGLviYoTKQtMsdWcWCTjlPqgfg07VoKEIb0CQwnlUAKilpfFV44Q
# DATA w7YPR2j3WesAcjQnqyCAYXPimTRJVNkCki6wzjNixka+BB7s1kWdzWrGOCwMmpPMXKinSRzPcx4/zOBpxgpOq+Gfshq3D5qQSPM1
# DATA S7NbY+PbYUMs8NGuBs4GjycObycnBm9He5PSNkjmKIaOhz+NiWtj92ZXTdPpuqhlqtPAYran8wAZVuQfKnSZly0U8j5kJpzQM7AJ
# DATA kzAJxl6ueohQiWCtLMAtmV6CjEP1WRrk/jCNYB+ly3aLHihXWjrjALGP2z1coAInJtsEkTAG63sBphLqrLEYgDnZbrAvyPoJJim0
# DATA sywwnDTxU2Erqgu1Pqe3Oa7v82SYBcjI1lgaCic2SoPsTS0yRJZ6WpZSKyQhUPrScSwUXw1qiDp5O1IomMKiAD+QtQHuFr4OLpmx
# DATA vwh+CijYByaVTrVrj/VI4UVGBYABqLlnNae9Payx8g5UPmW9itmpMgM0wOJvA0QujYtbHsgM9GkWYYG/TDa0XAwcaBC6rcihfEmI
# DATA KAOC5IcxeRAPQM173loBijUhGtxqKQz6BuASQoWNgU1RMwOGA8gM1Ute9TWY//EYGfs0AuaR0xozakAVBSmncKCsQzHWcAW4sVdN
# DATA kAxuayiFeYLMsF2qAJssr7MmgsMn4zhjOmT7DvRU4yLkdrCHzJblvQYMYG7ewz5xcwt97qfAGvJZyp4QZjAOI0ncHomkBEXjsVc0
# DATA LqdxrJyOpLrPY8QwbNbxWEhnxFCamRJzrhFYZNZag5FDK7XdOjxRJnfCJnDI2Zw8JeQbTcfQLEWbTmsKjmdjDmpZzGSudpzqtpJ7
# DATA xc1KKOWJjNdni2yGPc/TlBVueYA2rXHjoDNUeeQU5SrXiaVkAlaBIhCZbHK7IOOe9MzL7qZkaGFWz5A83wS4Kep+2Tp6WuBb6oM2
# DATA yvxRMiY9Kk9DlOMRb1ZZTX4o7k5BO/sX4+LWYq91BMJL0MZhhttpMGG/iDdOpq+RZy+GGjVKF9C6/0ovvjg96p4SokP02c+TCeoe
# DATA UTAPlJdEDFMyYZkURmChgqU0v4njKSPZs2GwPPaA3dxBL2+PMqwSjTsUpNV85UnNcg+9rlmsNoEfLOYpACzTY8treWRnOI+Huw8S
# DATA d5sWOZ52YubBRM+q3fA/C3LgSC+18YHG4h5Yf+zV9S8pVhCVqEtEjOqxUtnQj4AyZsnj+1L5QhHNFJKAGVynbJ4ozY3paY7k51l+
# DATA CGw+iefKr6LGj9+gfZOglhqApoAODPJHL6bjZJJgH66fWPGUZetOTFAwT0BX5/VQ/i+0iYytSGapfCf/qQUOyT729EpP7Muakp+R
# DATA BAoKOviQz5M52ASseZvOi/MDMT1Nb8AEvmTnd+bJmqCfN0g4EKAdxbgvroMxS+XcoHR461p/sLxfg0mJKjHaNnVCi2j9bLw6QOUm
# DATA hgAmLIZfWJHWdqvtMAJxN0aNKJCVUKE7gvAG/UwSJkI/ApAMhXEUNKKgFwYXH02uKSxPkWCY+2KI8iq4Fj/lhI01V3cF62G8yGEZ
# DATA xmxXAFzEx5U/lKIvyOmAHyZj5rfYzvg/kRmLY8iiUxWmQQ/gLeHCU/SfFw0G3I7apCPXCnKrLGGdTOQCY9gT848Yll43ogySNlcL
# DATA 7RR3gCwsmidT9SeLHIUcroyNCdgQtEDD+CoYj+qyu+kn9jUk6KZlbyCCUqdtTHOjqQMirpIhuTAA7bRhlCHPXjAOnXnUo55GHJmJ
# DATA A+Xk4o9OyCfP63WVzFjwwJsNjH0rrIlLA3pncg+TLFxMUO9Hjd4JbyOFoIYuPs/YoVBiLjBv9Fb6/ikpiOIkdaPYT9DTQiKk1fSQ
# DATA sCiqAAjHwFseZLcAXqeBHAQjYfj+Kw4asfF9wlv1GaJmD+TT+j4BfI3qI/T5nDbiUeosG4pOII4hymXQbCMt5lFDGo1i9gDAcFfT
# DATA dJxeovgACzKgEIPBj+X2ge3ujxZjkN5johiY7KXsC2mPhg8oXa2WEjpfHb48thjGPAO7H/qMwHjlcE+76T8FFEyG8Hpre7uHu8lT
# DATA /m9ysSriUEQaozuIURQ6SIAhUYqrOejgMG8s4gYuh6xzlDVANOBUJRoIy0XWAxD9MAHJURzEwZivRvNdtwiHZuxX0dpjtDMbBSU1
# DATA CxMiFWHEJUKRiBdlM6qtoIcWtyYLQHbq5eE4SCY0EwrQz0VQkfjyTZoCINhxttsmFdmArIHDz/EUuSoZjMDKUdW2FVrSReq8zYmb
# DATA JhnTGOzWiiBTZqaxubRkXjk2Ye02G77Zr1+qZJJ9dpgZqSMrW8g2UZMSiVzJHQWGBYqOnyYcTUPEwTZJFpNy1jzNZ2DWp4t8TLku
# DATA nuWmgl8kxoM0HaMXXlJi7nVmPfFex/EMVwu917hZ+XdmLFrpc9UkVHimtx56SZRCcq0jLpHY6RhMypTSLYynbwIVTEbRPQAI/oIh
# DATA WKghR98APcqn9oTAuKSNA4aaiR+s8HFBq1R5ql0/t15GToHAQSghAylqmspnFD8GqfaSoOrgqS2A/VDgH3bfbJYis8uMG1CSDDi8
# DATA hKrtKEb9t2uT2QulyYkOLHlUJfRme++XlFLRLYpuL21VJ6IVOi+Jd0W5vGx6VYwh9rRCoBZ1s4xWJWgVS+BlJPkZRnDteF5QIyWV
# DATA /Xko1kNA1K3lOiwlRUKzIMlLxGMDdMDuHwwtXmPuSYQZBZ43/FZjUAaYCVOWmQq8B2xJzJTPbQU3Xl+pwGLlkSdIoM8lW8E8QCNH
# DATA IRUXa23F1liDiYU11jNxTkorJeYPbC3TFq3lT1uO1kmMD32B0MbnGD2MBjSf5nmcq6BsYKJa1ss3IIPZ242Bct7YdXuXFUS35gEe
# DATA IIpQBsyWiKmu+AFBagsDMa4k34psyTosy2WQRWOMoKO2jN7tK9wO6DAnR2AcFQ0PjsBP04L9ZONNWZlGIbsJbtl7aHlVQM0HkyRB
# DATA 4mL5anUoKVOUhZXHACxzZWHxETulopp/aAm7qyC/JxgCmCGewzovhye8lWGRJ4gL8QM5oqc4iu05JnJnO0iN4K8cgSUtRxu0l4BM
# DATA FNKaSSsnDzk787Rsd3Uepg7GscKTRMWieIZZfdO5Cly7TiJO8AHtesqhG1J0nAQlRzEhruz2AIANyd+uIpbK6cLqwQSjHSgFtN+8
# DATA joYdmqQYJr5Ox4uJ5IHk8xSzjvCZEx5U4tsK9069teDyEskW46iJgtSgiCY/z53MJSWmBXJPuTdZlSLByFkkAICj6KRL/VckVdEb
# DATA xrDZESXimzIRdjFO2eTAcNCUTKuy5aOIOfy/mpHxOIbBglPwzMZDDmNLfBONNPJddQSU07Ml4RGoFyIEn8HSlEpA15VR4srVcotZ
# DATA jWfkVg48FhHfXSm+rADbBLYh0M06ZrgRNyv1VxUGK6ogTEvT2IhDYDEiCPf1WAUHN4lyME5AZpBeRcG1q9ucdFWW5nOvajzG1tMS
# DATA uqzVJcknmCY6Y84rd74lb1ivCPxokbFXS/XMnXkh8KV0wpF7ok/ylqp0OuIynPHJgvjfbI6Bd5OhJT1l3azuEw9nHQykJwh53A+Y
# DATA aHgbBxk7Tq0muWf5gJR6N2N5Q4QMxjthwlL72LnDjgUCH4Q+hlQwciDGnpK7ImxV2puFGYkdUt6pZ5Ta+7ylLJPtReDkA4ZCtJuV
# DATA Lr96+Xp7jFj/0etdV3FI0p1B7k5SjrSLlwa2UZ5OJZGDg8tqLLRj7MhBknvG06SVUqIYzLI1qXSimK+iZlR2l9IIA9T/RPFnnUpo
# DATA 1OKMrjVnL4/kR1gL49IZQmVnKZYBprQqlXNLxmCuXDbsgk3DMMhJX2KzD8PTGBNA4x1/Iy3JU95aK007KgeZZZ7eDNpW8+TpUKlq
# DATA vSFrLCs27lBsHdqSvA6CZo5vkNcbNApAf/USLX/aKkwZjPMaK3iMLePvdRMkyxdUbBX2/Qe3KkHF/MgD0wp7o0XGPjZeaXbRag1G
# DATA VHDfsiEfpKeCNWmhhZIpOFhLEFDoblbC9vIleqyvJBNPcuJ4e+oMTCHjKntWeD8Tj0IUG2/Ibc3j/FZmTrmNaklysrzFljxkkxYN
# DATA kGTqhcAoLW8qyHzQv7Rgt2aWB9TjjUq0HSUcWPNWbIATR6G/MZm4oNDmlCpS/mpdaB0hVK5A+2SMbcu5mejAyhVLNxHdHCmU47C5
# DATA Y5eh5hGv3AUL8p/N4jhbn6fr+JcToXTqm8ImnQVIpmxdc3AsphQLxlNJbLgsXub6yjJMrmbOOCKGLsshsVudcEy7QBwcYqFa2zyS
# DATA UwSoixPfByKx3HIWWKiRo9vedg0kEpPAKWqfQvmmQZJ3gtDAu/Q2HOqAbuTGF5aYmE7EQQc1Wjko29YIEEtiUtZcvpiwMk9NlEGh
# DATA M328OZ75ojnDUpBJirZPDHvGThrBbBNb5qnGIOeCCUjDupciscJzsGAjFczJjZRSEVQd+CXBOebezBkI8tGiAQ6bHLP/MGEOlXF4
# DATA DzXKZCr7ipMF1bSYlRQnW/eidDGcjxZjzs83vnhYmHR8zVgeBdecYk8aQUDM8Vkhh0hrD1qsULaSlWSE5kXdX3MQ5WQSe/PbGelr
# DATA KWeQAXHpVBogznAc8OZXsPuuka+iqAs5wxcXB/d5ErQxAjrzZpJOCk09MIIXCkpeovgNOrdJOhExz9hDDoDTYRY5+YKAYZaNVulK
# DATA 0V6AXC2W1QeZ47j95gFl3nhGlqMwjhao0TKq0MOqB2BwF1PqmmQ4/gLjSaoeeeZJC0AaI7cfO5tiSd6zTvHQXDxv7ZBzV9gMPSTe
# DATA RJ9Vioy9waz8uAlMKo3yOlJGGEfoLq9jDsBVmkmGtv86vmXkMqtLTN+KtRKCJXmGTHXOmVk+/ZCX+BBUPpoDIHIfr+RoDR0qy1fr
# DATA X7EDHnpbvHyBqXpxUZhI8A1s9AWygsWUOKiops7JDWZYnuKQeKIt5dQ9WC4MPjATYFcMz4vTUyjUN4zJmHajJEg3Q0z1wINasHqH
# DATA IyewNF1ikrbjUjF7sbZwMA502XkpIzmMxyaYjVuTHWNp42G4QGsp93RYj0VfoIaydqHkToxs3yJ2aejSc9YSkzskn9iSa1pFkwyj
# DATA WTxf4CFXpVd6bLVS0ka11FHoQpiTSgjfQIv9mSTartD4eN6uN1ghlRx0w9i2Oz05jbZqh+GB18VcHS0zPmDtTSG/iZfgiV0WarjW
# DATA 05RDopZuB2/P6aAqB0tQibu1d1aBIuWQFGvPDsYpdU0nXNkuSo+oTjpkuXFy/KImqTs29JbFs2riyxlqgVfoQu0wuztlWKNmSEnY
# DATA KqpC5LyYoUuWswQkLkL71WwZjYXMmog+MShUVRdC8paQo2k5eahTFBHafAk8peGLAh/F5JS4uYqnSwEaZFLxeKRTClSQL0I+FnNS
# DATA EMkpczzO0tLUQADLdZKOER08ucWYU9aQWc/TELP7RiKGTVZZEGZpntsdUbLCPfuAOcLKVVZaLzm97Fhg6cbhUzj0svZRqCN1njqm
# DATA D3ijs8oSXfAL+bKrk2W9YuqY2J00urL+gD0TL0QVELSRGwQY0ARyjChiMcXgAgWi0QkoqQBiPQGu+g1/z8Q1zmJ2WK5Zv5lQAR56
# DATA ymI7/QSpW/KEl9yHOuIyvFU5KXyCgI+0Ua7dNOYDLlmshJ0JTDW8ciDk5JjEbiRKo1IIOIqkAgikOgIX4OwJPsqFuVJsb4OqzEdH
# DATA 7CRt26nk5CV4SpByyIb9bEvnezCviwzpoBR2j73KKjvbzh7V0Ux2v+ET2XukvpvIjKcYearO53LfHPQpwYKqCHCJiggn7XtLqRKY
# DATA QMaCR027fAYrUkPYlVSWJIKTCOSAOh+8ALY5SSVxpHwQFeMN5nIcB9kbuWgwyM1I88jhX11BI4I65dcy+aoSiUlvBAx4D402sJzQ
# DATA GmeL40ZNsJDh3KiZJDlykngrwEcOIcywLvFV8XCQjeRGe9zMMwrDqdIE5HEtzYIwo1H20hyXkM5eqNQvVfIixXNDitvaxM2HTCQJ
# DATA DHM6AM4S8PQaUma8qMpGBBmIruiYLyWb0cKpvmv3Mgk3XYcecWDhqSTlkOWoEhEwZoRxJDoUkiilQfuVVApvWbg/91tdYp6tXnHs
# DATA J6hPoqP/RB+jJNMku9aCyhxUsVzAHL7SaR9goRF6gNq1az/XCr/Jt8uUD3ApXulJvFJFNBnNHOJC3SJgQzqZM8RhDbe4zvACetA2
# DATA lSNhYcUuk6k2Wg1lQifm5Cg/KzNhyGbT8A/x/Gj2mvilZ2Hjho6g5ZaXTztVGIBAlzBh8KMaLIAsppxFYycFiT9cWOWPoPovwYQ/
# DATA cPA7zSyMa1tbAckDxDVMkBsz0jCAgURUyBjLwCTB6XCGnpgR5K6fAA3hUx65bpqyeSj6HOEi5/FGNgVhUHgydVLFDOSUHWCDHsw9
# DATA g+BbN7sBeWzuTM+vqlOhhaUCnljjncQVachjgEcJFhMRuwSGpW0X1EjUGCifz7QRqcdJMKV96kOxoNiklH/tsXAqnbBktTN/KqRi
# DATA FTMsSNKiIwE0MuRIa+IQ93QqIyklOGPZU2jrq4iLzho1rm0lEt00tojy2MREUTI54RRxtlEC2eZl6TaWWF2ZuRWwaadURNAZlydi
# DATA WK3IR0Z9TGekUKNYqv+k4fN0h77VIekDZUUI+CiGk89rK2yW3C4TCYYM3ZlboWr71KdVrcqNV1PKVgnUaGdR9nW+gC12LQkrq+A3
# DATA /gQCllXTtMTtskqXp9l6pFKTTNfpZDolyz56U6cUCkAA4V8cAEtk69Y24M0gr5OhJ8SE0bqQ6MlbCjo4yq1o5XtLCUjW3kmLu6mu
# DATA lCBJtZaQqjkYaiX7KD1Jl8ZADjdXKrNR2594bK0jedqRBpmsWPwgCgDarQaZE8mU/QYmC4LOTekzDqY+UGHN5LgxjY9iLQfVV1PQ
# DATA cmob2q+oUMI8gDFZJx3YGNejeTIaV0u7ThOxCCkvzD0PNBfwY7u8kl3CQ+10O8ZPLGRu1RlZProTsx8E3U8BPJtdOeyqhQ6KL6yU
# DATA KFK1MaOPy4CRkVyq0s1Fb808XaqN45qWK7mosPnkxyEvABuqNU8rjRykFc8tOb3AsBiX6n3OGSCw2UfJ1EWhexDFnFdFeg34iHvd
# DATA 5BhJ5550joWLaFvjxhlJrJDbGnQAE6LiBJZOQp5fLFPGh1p7TT8iLWU0l3WgEwRCni/ACk0J586RmUeh0LNQaM1oaULqDZpHEufW
# DATA TLyHZyIVnRLWBkZJhvkfySTWhoMRaMJhoOuV9KLOfLKGWTM2l1cE16TKhwsJ+ZleNXY7NnY9yZcAcGbaxGWg0P1m+AI+W9pdrrNF
# DATA O97MfkR86e2FzlmpE4EaE1lQGhEqDUIPQNPEuSzvY5azNjTUF/nM9NiRpDLM7YW21r9uHdHy/wJ0JbIgU123AisHOeUKVeTfaIBO
# DATA Li7qL5633SDv3IyO2WBeo6iaEtj7gs9eOSn+KnfQDlsEIZdwKJyJAsHIaR8KSLQM8DSanSRindHbm4bALQNOSNb1O5ZT7sjTTuqw
# DATA xAcCFXoCmFR2/AOBaM8CS+DBIkLE2jVlKOM+0DiyjhejMkFRTKcMjp1mi/yZ96KbaFsmNzh7unBYMJZzwmzxcQEYa9cLE5dTZSWL
# DATA 4NbuQoeZrvnCR+QYyUvHIJnYRI8QMWVwsLTjufwNJbuiVrynpJ00EMX5aXoDtIwFQ4HIVGoJvEIlkjS/WXEuyI12OPJUcafcUmWX
# DATA bURtNNTlqGhd6wfsC5YV4cIjNGa+4BAB6VoOUt19gC5hKaKCIQN1RIfPDiaEseGtexrH0hdNlau9qb+GPjY0j0xUZo01eztOoyNB
# DATA PAofJuSyS3ZZKFa3TGQVN8qYbKyY803BGFRtKL+LFY3lPiZxdsk0Y9ecIq62aqNyVjRn8Ko8qKm/PDtJ6ebQDSEaBIU9V2S91gLb
# DATA jINzPjA1VTfAbBncnIaLq1x6joFw+Pu2gofY4ohO+rHjhAKPYC0Aa47YEFiMI488ZUa9wlBlki4o9Z41LFCVxwuES07TFc8KrAyf
# DATA 2VPQxLoCJlRgvOJzSmKfF6qNyuE0Ld7j0QgTnApKstjTyHFKDKVcRcPkOJyORxYOjKOQp1PZq9Rmp2CBmH6ePb7ZrVgPOEtvg7HE
# DATA r1IrPY3PGhlYvAcPrhu9Qs8YayDg7saULqZWN4GWwj3rfFyPV5+yN+k7BWPw4OMC3SAY1LpUprpnqeXS2DDqyEQo6iyNgKVwFkvd
# DATA ZApS1eNgzBsRMZNpz5VdmgzHMWlIdHai1Wr4L2nsXBU9m7KHMM3WVBJMQUHE3aS9rZQHX3YQxhXMVmk0p3qJegwj0aErFjae7LRF
# DATA birjmeR/lTAgYMI+tKHW5d/k1ITTzpRmsREusSPka87PHgibOLKqQ4xt57LuuG7Sh8YYx8KClaLWwLqg6GSlXv1aV/IBy7dRoM5a
# DATA a1KuQXWbomqrjyt7y0nFoyJZkOOPz/BKsKqIkrqHXhdR/1SkmKe6EiQKB1EZqoJqpHZ92aHTkrF5L3u225QmZIqL1GUZ0/GaKTtm
# DATA 0hyUk9STJcrVqWw6YEXFdxBp7JLLqYlOJXXcARQEcGTmAR9CNDBbSldAngt9LB6r7mXjCOs7aW6zzhVcHMPaYvguCa6gQFQoPC61
# DATA QPlRuJKywTkjnHY3b21ThISrJdyjhvDoMu1VZIFuKnVKEXOkmXVQnWglosi3tOZOkdnD9Fa5QDxoGovviUPhyZx9a3KGCgP1qRgq
# DATA XOCUMoGoxANZsRTKrOrCZ1PV85LmS7XSzTs83nU8DfjwIZUpX4jHnlvYlQ9ryGRSf41WeU1StwuOEU40YI1Cl2eU+uCc6b1itkvz
# DATA UoRhH7WmfpezjQrqKhb2AJjpvNuY9e3pEqB8ImtleqitIqjSBW7aLrnzPV0hm2pDY+6iOrkbPXgER+eJB54p2asHKRwP0IKZIv5u
# DATA cV92JHhzHeJEx6eVfqoOQ62YK8wBPYqpSUw2yaIYpLtkIyPGOpVsj1BqiKDIKvNNpztccmBjOMltX4uuoFXt6BHqNi/yHsGLlsP6
# DATA FNKPhE5oS4xtE0nbPya1Hqvu/bhILKp8nva/SHREl4uRyqIoEpSpXyAtXypzWEnD3pLrWgpuss6lPCsMGB+SKztH6LlvstzRxqmd
# DATA epHg0UUQMJxEzZqKClx60oE5Yyb+FdRdmRzGSXwdm6QI2nNYgDrLFwEnRrGaDJOcxk6JThSqYze1DQNQvMzM16zT6rYpTJYaZnEu
# DATA lG0FLcTmrS8ZyXTUmqJ/ZTyI1AE7PzfOxVQtK+mi1TJd7Ebl22rYlKjwdKAC56pqztmW0ZLtPC2hEUrAZ/BRGjguaiZkce5gsShz
# DATA FsQdgtU9cnRTPFkfvycVda+IFhhoDetiZAkJkzS7pROgZYXaOPrGJedgblYmD2dm13UdkrxorrAunZsSU6YiAGsExrAppAppncWk
# DATA A7kpoautDqvSkSnxWjSIxWNDKqsxelEkGeLUoT0rqVEifJ7EkIaoN0oipznyR/4wde8CA2gSQEgAzoLbCeUcpSZcICM4dROkZIry
# DATA oUqpultOjBeWUqgUZ49X7Jt1sroqoq3ZtHGuMhdR/rilvaGcq3U67mOTT5HZU4XMZZ7gnlpz2JlOZJVUmirnsSWx3AAh1nmaq9rA
# DATA NRYcGGQAOOj4HydaTqOyofUGlTzzXJQOdRw5V/yQYq4l21cCJQhbTB6BiKsSCIEapubpQ5YuTrCuvdBt3fjV21v+iyCD1Wo3m33O
# DATA 9rnSpU0t554+J0GFzbKFjt2J8Wwlz5A5jGmICdUHFGPS3HQx0i4Zp5q1pI8AX9OK8TB28xe1Y92OX6ppUqmlVrvhH6X+6QK0C2oI
# DATA a31MlcUq/jO+5oO1tkLdOXZGRFIxy68qe5DKqi2oYgmHKiyd0QBaU9lkmMIQJaFOiVdDlAXTblWlNUAiClkcV/uAVr+rwwjo8bFZ
# DATA jCvY81QO8KsDXHkyWYznwTTmQjmcMbdUKcpxAKhyHupcFvokaOrmNRErS55329EjAAJ3D6hgR9EppLghopYcdSbKrc6vURSdNFyw
# DATA 4LHsh7LcSPHRBxm1nmPtVngLWMvEEvVeISFSzofI1Uzs89NoG6ak9aXO5QkOlrTJTaGEUYbbl3MkVcaYe2jL1NhpdRp4x1cK8zsS
# DATA HfvQVBp/grnWRutcfY3Kt83RE7ybNERPI4WoY+nECKcxWFXD2brVN+l4upyGVf0+owmOzVnU5WLplP1HQ8pInj6TSbaaVX69Ric6
# DATA 6CFf5GXFb1YV09QCTM2DlTvl6XauHSk9ZvrwMWljQZG6pwtZ60PwAcgoXb5LTpUGuqiFPsUt1xdJoZZSYJgR23VsV597l+irfbBd
# DATA X7zhWRdvrLgiRSUUWdcRRY7mzRkfyuOgfQ3fliC1oVMsSDN9LdISy5QsxciUpuTcwyF5zKX3jKy64YfPGLLZ4JmiKKYMrl39onCT
# DATA hRyZKs9Rp+wP+/yGU/6DcsL0ucrlgi0q8drMVR+6oKIFungLaeh07tfOnVJ76hEoQJ60iTwJVghe/tK56MpxuOFcUZ4CuUmhg2dg
# DATA yUVyViwwZdcy6Usu67JuthE/3mPuXmJ2jrFBRBn8pZqOgAK7O48QgP4DqVKIhaNmSZbo49iSvmouKULMIrCcVYovRHhsCK+x8uSG
# DATA FhoCaBY0jYnobCDfsqkOWSoKA/RwGVjSTZEuFjB/JA/VYrrAaoo6XdDT5wgk/VcZGzpfnF9wj+yVI8wrIGxNdj8eeDH+dNaaRPWa
# DATA m/1G0HD2PLEny4e44sogcemoZDwFqKcBzVRlOgcC37lwaV6kIc/Q0HJSpbYMGV231t1KPLwyKB4kJ5OBGF6lKgSm+iI3pwbTKwPT
# DATA InXWJW0wlxYTaOfNLd/HB08iddfdaIHFmrziXXIP7wXsSY5t1HUxlTe3lVxcd24CoRuuNyiz04isSJBSsxgv1Lt6Q3mYjPrynJZW
# DATA Kfh6JojYS/HP2Tm3VBNKsrc9+8yHVaodBKr9hqWeFpR0PKUuCfFpSc4U6aNyN52S/jQpddEkkTjozA55IvvrNvThACapr+R4ADK9
# DATA Lw5ODvzDU//o2P9q7+Rk7+jsa//Z8YkPD/yXJ8efn+y9qPtnx/T94CdnB0dn/suDkxeHZ2cHT/3Pvvb2Xr58fri/99nzA//53ld4
# DATA L9RP9g9envlffXFw5B9j918dnh74p2d7+MLhkf/VyeHZ4dHn1OH+8cuvTw4//+LM++L4+dODE7p+awNGpxf9l3snZ4cHpwjHl4dP
# DATA D2yY/LW9UwB7zf/q8OyL41dnGnjv+Bl08rX/48Ojp3X/4JA6OvjJy5OD01MAAPo+fAEQH8DDw6P956+eAix1/zPo4ej4zH9+CDOD
# DATA ZmfHdUSNaqt6R2Cg/xcHJ/tfwNe9zw6fHwK+8M6wZ4dnRzAE4W6PId9/9XzvxHv56uTl8ekBClNEIXQCCD85PP2xDzMQxP7pqz3d
# DATA EWAX+nixd7R/gGNZc/ZgmXC6/tfHr1BawLyfP3WQgog68J8ePDvYPzv88qCOLWGY01cvDgTfp2fQqbf3/Ll/dLAP8O6dfO2fHpx8
# DATA ebhPeDg5eLl3eIJY2j8+OcFejo+QhHoNPnqgA2rPVb47sosjpJ6DL5E2Xh09RyycHPzpK5gnUojvUgj2vff5yQEh2aIH76tDAApX
# DATA ThOFz0RRp1fggSGKr4G8jv0Xx08Pn+GSCNHsHx99efD1qWdjBHBsyHXvs2NEymcAyCHBAxAghnDNnu692Pv84NSiChzTk0uP6/7p
# DATA y4P9Q/wAz4EWYfGfM5qOTmGuuKzwg3Ti78H6Yg9ImLyG3ivYBEh8R4poYGz8zQa2asZeJkj/+fEpUp/3dO9szyeI4e9nB9j65OAI
# DATA EEX7a29//9UJ7DVsgW8ANKevYPcdHvFq4Hxpex+ePPXUBiOafbZ3+PzVSZHocORjQCF2ScRnrQS3OK3VPVx8//AZDLX/hSyb72zj
# DATA r/0vYCk+O4Bme0+/PKStKOMAkIeCE5gd9SB4RMrrN9iAxMs/NPWdLh1RMlIrclidPgmFzcYOCZsjG7pwC+dpixNiGIv2M06xoAUf
# DATA XuKqypIbL5yXD8hxgrmHymF8w1bQgsw9Mm5YO5aeght1eAjrlI5TPvOLh5ve0G0QuYd+02GejrFKAhWNZuUDVe7kOhlbsJf45Ryz
# DATA VyUjO2fCzGEUFxHmWHteKESmUyKwqgOIebewLZAfLWfpDYpf8LVUe4QBzvw7U6cOvkYpdgTqqPSf6/CjXE0kN0fO7DsYuJI23Tgl
# DATA 4TUB8pIOreYgilMJ3i3ywiHhuoTV8jkXk8IMzysKx+hMYQmpJnPPvZKWlZxY3UvOF2NY1y5bt0/r4GRuziKcSSphHTPuA/ElG71U
# DATA nYrTer1KHT0kkygPRjgxhFe/PdEXi87lCA5lnFmnL/jSGYxXqhrs41uPlClxhlvFH916y9QTdZFfkTOIlGpVRI9snLXQXF05ZiMW
# DATA rzycpeTbYCeVKng0WuiitjibEWqbgJMfIiLpXVUuz5p7JaeTZNLtMEviEQbeAl07SmIrjR8VLpr/IRb3+5Hv/5BeT9UpzB+hiZfk
# DATA qnuCw17gHX3LtLOsydx3bmX2knl58Pkxmm6QP14RryuTZMngN/k2mVd1jwrXli2UxvK8zfT0TVtXGIhSh7SU2QnbB1aOzXWlaCH/
# DATA V8rWE/t+Yu5HOckNuxl5RX0JcLlKXfKNunQax48zfuQOe7o3HU1dlRVoU65Ob3cTLR/s23PqvxkssjEHFI1ZMbH/w6v5fJbvbGzc
# DATA 3Nw0LqeLRppdbqhMoI0f0RG+nAwBpwIN1nph7khBEr6WnAr2o0s4S6dY0gsvOAlmmNQEc9P5GVY9xjAwFy0ypHzb8T1uSk/f6Xhr
# DATA EMWlvN3r5pO5ko4sQ3TpGL7Vm7MzVcX7ci94ZlMe9BEPVaiDqRzvmDH3OrGrWlUoDvw1dZUXucz4nFwcRLmGgWOMwMSvY09HwSKd
# DATA IM5X8HBB+dvc8oZLeU8pMEc3PWlTjiQvKRhqJwzj+Vyynsx5XXUB0xOiAX38oKMMSx1gLRaZ+7qAdEQjYSoGxKW3mFkinmxzU4K6
# DATA 3y/OapRVh7YfbE2+fo0ikFgNiquhKW5odKE1k05hXe1u3QjyTOc2uPSJRO9cL8maDP4gFqfeR3QDNGDCe3A3fO8P//4n+Qc2yOH+
# DATA QWMS/R7HaMK/3uYm/YV/xb+tzU5LfZbf++3N/vf85neBgAUqVzDkv9P1/76/N3cuT9dHsTzvJJ5MA4wFyQltPurMRUTZHTpO53Pg
# DATA vZjNPY3Hcg4sQjlN2W7kA6debki7nEZS44p4yXqn0VzHMOYTc9ZFacl8aS6VnGAVRq7skJstGxS4+EnG4uq1rpyFomoxk1S1FzBE
# DATA u9HU3j45pYb98/swNqqmoAzO6TIg00d6MwXLfP/gCBWVz0BhwxzsdByenO0r9ZtQosrch7emJJ8CmoNoALPJafnq7NnL508kCEJZ
# DATA kSD5AXEbU3UH5mUmruQzTEJZ5yQUPQqabXSThLqaiu7yQUyrRQPZ80rNnwHd8RWzvgTNYTFsABI3MrUmG8MgfA2d1+9vBQuJCb0P
# DATA NZtSYdGSJj85e366gcu1juiQWAye76FbMcm5iyX4mWzk0M29I9nvrtO71a1Gs9GsKVQrAmuAfZUb+qJF3T+wyi84JMc0EKPp8u9k
# DATA /+O9lJhA1Qh/mv/b8P92s9vvu/y/1Wy3u3/g/9/Fv42P/ZMFlQRUxc3BquQUCmJNYO9RLdljvoBS1/+4CsDEzbHoL/quQjzeRQcM
# DATA gLV+vOFV0C/D57IqTyghee6Pcn9X6cnVCrKKnVFeqanHYXY7A+2z2IR/Ns3e+i+zJJ8E+2Ouz8Lf/Dv7xQ0wlTdAjSV+NACrHgvn
# DATA bfzxjJpuhPSm6TEawrvVas3f/ZH/1vPhHyb38if8x63khnRoekSRuyoP/GmDe5Ww86cN7v3TBpg3ybxaaVRq580L/9NP/WbN/9Gu
# DATA 3/c/tbrGf0EUzMDy2CE3WPWRc5CX1meXlVqDIXl5Wau6PQvw4jo8nWPa2g6lCINN0Iin1w30MH+2d3oweHXyHItjvNnx2/V7+jgD
# DATA SyNdzF/gpX35jt9qDmC7gqEB4rHwqMOPnL7u6rB6YNbEk4BnC6NWV4FTa+QxWn0vAzTAGmBAVSv8bqWG6Kywu6/i39XMKHf+DrF/
# DATA uon9if5ZHJpTckMa4qnKmta45R3Y2XNQMgwS0ay+odcOsizNqpWnwizlVN5YlcjFagx4LSNtnVvfnkdF9e7d1apIc1Qgef8qDl9T
# DATA p5KvnPMQ/ts7b2ODlRMlsjgAHvmnf/rcVOYD454KTAScS0pHQSjHmSvl6Nom0JkKsbLaAi+lGehPx1RwjxyYYM5jLeMEL8Kh0s68
# DATA t0kgmvryT7AvPB0T4f21vlyp5U8SUVk404rToMEul6ttdKGUhuw2M8wL9SZuKkZ6pd1s95rbrVa72QHyGcRZMAjGaNcPdE7lgErJ
# DATA V3asdRJYCKn5YrLjV1rbzU4UDLfawagzard67U67udnZ6vab/U632d7qjfr9Vmsr3OqFw61hJ9pqxc2wvd0NtqMgbvaHFUNT6uSs
# DATA 6h2I+9wh68pmGPXbo2gU96O424TXg260HffCMGi1t9rhVru3NQqD3jDob/c3t8LmECDqdprxdr8TRt2oX3G3SSUcBd1uP+wNh9uj
# DATA eDMahdvb7SjoRP2tVqs1avWD1nbUa0WjDk6mPdrqdLr9Nsxma9QO2kHQtfq74I93de9Osbucb23fxaMJixiZ3p+cHh81cmIPQL1V
# DATA +r3uVwd1/5qY4vx2FmPZDH93d9evDJEs5xXgY9eNecpcBZjnDjRWQyD92AMwD2+E5L3/Ah7CVr4K2t0eMC+u91plqHjsWq0RJZdx
# DATA Djv+Kn6DG0iVZ1b37sXR8xi0wFzBOgvmOOD5RV0F0IGi7mpCIsnI54b+H/2RngzDhhPiaroVfPjRXgY6aiPJ6a9AQw+kAyppMQ2x
# DATA B+AF8uyzBfqL4C3+oCbhECgCdV5ANEJduwBQrwglAkfN8C306FQZpVi8FNOCqU0DS3LrYUpxcg5NABvnjUYDh6n7/J0B0QwvHufx
# DATA o4Djsfg14ab82hPvzlqdMagGCmsG9w7KP0KU8zAV/y//0v+Ifm5QhCP/ClT9auUNbPvWTgWmJkNREx6csTG8xfI5u75gHs2FqvSD
# DATA hlC1B2ZABRl1b1Ph06Bxt0CPkyDU9Fh3xOPey5eD04P9k4MzTacE3Dp0gxNYv25VNK0644TJDB37haGexvx7cl2tBHG+DiOuX4aT
# DATA Cq1OnWfVAMsmIOoDwdpq11S39CLIxPkeWC1nwWW10LrVrvvtrZq7RoIfTP8K5tVz6USmUugAX66rcahYUbV2UTNbvLKYj7YQm3de
# DATA kN9OQ10z3c+nwSy/SudVxSrV4jMuaGfjaoHlhhGdYeMHf7GIs9uT4ObVFMNe1bXTg+cH+2fcckBBnWcnxy9sT+WAZX9DOvuKslq4
# DATA PT/ZVQrBmrMQXCRxl4T4KegQ/H5jEsyqc+JtDTOoQp617WZ4lznQ7vl5JYgmyRSWiihgwN9wh1W0UTqA1cEculy3Knl0cWEzBtwe
# DATA BGIDtlkVRwNtkbhK4dfWRa1m6SNGf6hWANLRWC4xxhh2eCsoN6qHwQc6DIy8xX/kZgeZVkkihBsWMpsPFgv+hg8REvw8z9KfBtOB
# DATA KqmMP11j6Fk3ho/64YWRQYQqHKCsU/XCANkM/pCl49h+G2eXXA5gW1K5OFAcF3hGeRmz8oRnbJOAJRHsn5PpECNxsJVs+lgmgfMw
# DATA mGKchu4ISeJxlF9YnDjGc83AdAmvDs/nt2VBdn3dCwsdph8QojY5gRDlrxX/E/PCk0KXSn4bCtFNQTO2BtqxmjAc+FwgYnQ9cSjx
# DATA I+oaJkHfChATnVRWESElxmHtRG71RGcOPxHyM/Cb0zH3sISKsIQQL2qc3s8TuE0pU/hBi7IVzB7f/UHbPz7B7JXPMEwZIZ8bzNKc
# DATA 0veIIJmL1PmdWhH5aqxdrRd+2jAUcvGpBgZEG1MLftJTJsYTkk7UsKZWA4aL14bxo49gqxCLjgbBHGFi6UHfLhqqSEE1rNXc5ZOh
# DATA G5jOLz2ZgenHAH8M7JFpbaGnh9ZVKxmCAbQvHCpdwlQS4fq64y/PXGgLOQMSJ3/CfQB/ij3mFDSNsV/Ua9SWPcd6hfBdpn9Ruyi+
# DATA CBO7V/78ByG2H7xVQ5h1qqxVPgk/gf/WGj9NQbup1Cu1OybFtR+8JSK5W/sPS7MXEwqZjmIbn90eRhYXKrAZRD6wFQS1VvAQlGzG
# DATA AlesFF/RO9pVaKH3Br/6aUP4H4yGWph5oh80wOq7BCVwBWXI2FTNZ5oqdprb+mvJNKWZTLU4ZNk09FSkEQjsSwTZ4t/E4azHD1Iz
# DATA BnkXHKGONUjwYhnwNL41VhBFzljLb9x5q79ZqJCNhNpFmWx1pGnN2uCUopXe1PA/5/wT6umsfFu/FSBjijwXbQ7bJdGF0fCXKZ+6
# DATA uqgVujG0XNaVSEVUyA+UZFzq+Dws8TG59F2iOKFSxCBRE5Re6EtDl0/RAhLInUGcidwVLTPDwXGHCiepaycnT3rHmvydy3pLhUHN
# DATA USNIxWdboUyBUD1Y7zd4+FoZP5DVRKuOTCruuGz/CLFR3hryH70etsgp33bi+RxHz1iSGaFnQ8lIgZkjMIiAiyerN7HuTBt3eC63
# DATA /AVpUECU6YFlSvWcDVyy/y7IYWEsTYtaNXTwH3zjomznlvxGG4+x9zBHFBmJQRWN8qKkhM+VHf5JuhXB4leKm+2uQLF35QZ4wR7D
# DATA EG3VNsCVTRtkl9fnbd4/AG0MZsPl1byyrLVObNfcgzqabk0SHWxI8ZThvplSJtwAS35wJasBBhzhu4jQATu0B2bEtcqyMDWuSXTy
# DATA lMrPBK8ixPJUuqOybYOtGi4gNaOqesvEzzoK9d5w5/lkqfOPNv78PFj/2d76nzXXtwcXn/xgo4HJqmTgsZSlbiykrKIkPLyIGVZz
# DATA y79alE1mxBEMd/G2t3mnBqRh1CrUVg/CN7YYD25oHKhAnQR2GU7E22ZCFBKUMKjfUO8jrZvfG/lfjCtlPSp/zihvxG9gsfNTIGh2
# DATA QQGPh1+xbM8z0Das34sGjGVzjaAr6vLTJfcF9EQ1zasb32TfTDcuYdN9s4RaxTLF4at6A1DO6UMdhsD/WZ1JVxl2dsGijktgPdL/
# DATA Ka0Lnk+c5flFybpr2Iw5UFz0VZIAK/FMjagGQXJ8M62WueXrTAIw7bKn5/jwonQZNJg8FlJ+CcD0sFHw3fM+4UdLnvcPmawbv7Hp
# DATA fjFlsOwbIzSJGtL3Pyntkzz0T3zEBxpDzo5xoELSf6LDJG7DqkbHeesCZ1whVVrU0yUxsKxGkkKnF6UxWwBNlezXuxKNh9m59tkV
# DATA bEirUyXslPTI51G6mDewMD7w/i+Rd9Dhaos7L7OSnCdsdWuEHWLI3XzlQ+momxZZdK9XHJmXxZW9Utip6TqyrnQ0CUQUsVQA9qHx
# DATA OBBYIll1HdZdDrvMgiyPq0UO10QvGfErCzkFkLSz9SH0vdRqCTln6nKhJ7mcME0cA4h8VTTZkpQao7RunQywNHXeWwVRoq+yYz8x
# DATA KyINCqtWY4pvoq5JqEjHcYN+kgdWZMUKjn7qm9UnkpJQK1MVvdmYYIbrZYxOgxVtJSyrI6rGr1+3SJZp9FYdG9Y+VXEZY4kWK80B
# DATA q9FgWZoGOrt00OBNMt/HVK5dv/UEtMmGFP2X7ALUoTBjl+PpVVzcf/v8nxgTkjF2PBgHt0g2s9vvNv9ns91tdQv5P+1Ws/OH/J/v
# DATA JP/zo41Fnm0Mk+lGPL32Z7fzq3Ta8dbW1l7wjXQ+l6M1dMIn8XPLoCGFUB0UIaMG983TNHyNtZNgTzagO0+VEc0uiemp75jMrj6P
# DATA phPkFerrT3O8RZs/pzmXNMGxxslQFSV9CV9Vk0z3md/m6iNWXlCf0bnoefCQYqKgTQA/nCOzBS5YxZ6qgwHywMEA9US6WhvYF0CL
# DATA mllND4N3fkykwoqdh2iMGF/PbTIJMGuSElfzeIDMyfO8KMY6urNZHKkINli1mEt1U9tRVluSK5ao2gCU8tiyAhF0fA/YIQd+QWxX
# DATA 8UfosVbbucCuVLDbV7/T1aJW3BXXTr9EOjuILmLz1Go1SGPgmcswncvcUB+ypsZXpKOdlkhM92J1z1iRarnntyC7dvx7uicvizNG
# DATA A7/l1ZpjO/O0eCHU2iBN5FX2SC4tiA4iIbk2ojie4QdpXdMxI3UHWqLMc0lc4p8xMPgWpAKNDiCZ6UmD8wrsQSLBCjqiZJ4lD+1p
# DATA A/rMEyogIkDQAp5fONbyNbq2YqsVA8g/I3znFxZYJatDDWV5SFTyL9wNRvqBcjhNZBpVdpaUVm59XuFsJHuWxSfWFJ0ZkG4O8FfF
# DATA CU7R1jwG0TzPKwXYv++fCi7oBnus8iVnDjnZIueCwJhRRIwlfyKZ1VEcjoPMKuMwjMfpTWPJlauyQhxsshdkCZH3kzrhsqLXkB7t
# DATA lFogvM0rRSpxfi4ib0TlpdPF7DGYcyZmkTF1sIqC/zVm921nZoja3nSGpsshfoiwK1GMS8oAW0QeYY56Nkhnc+nbnYiiY7vZxbnq
# DATA rITgVzQsTtTx+gnrAr0bRBMorWpeCXlpRexUoTOSwdhZZUbLvb4O+ih/+ItFEoNBJJmqNcWKKYMvypeZ+oUNBormxjgNIuSYJaMB
# DATA XvFoAoz0MXQGwpMB1tswqrLXVvKJyS7hXEEMauHe3D1Kp7FMayTF8KmlnIiX1wyc4wA2KU9fHvJ67ROxCxnQL8+pZYXE4Ns7myBc
# DATA EPg4DDXmF2GqDZ5kQ6RGQ5oy13Nf3yk6lcjLaKw1ZDjo0HzcCA08KQh61SBKMlzASm05iuJ//Mi+JH7IwUPqTCUs18v7PZ9g0WPu
# DATA lw9s8mtyNHdBxc6LmH+Bv4tQubiw8RxMJbtOaSXs01ullvBT0Usc9kRILOxAIdGzTJAt35+B1aZkPprSAyWVq6iV1fWtppzIvNva
# DATA akq/EZjmdFBol+t4TVLYI6j6VhEmaU8tb67oTH6x0Q91Fxb3cXYqQ7Bqj8ImIuDcvUpERTVDUS/50A1J7A9gKCoJ8DNqkNIxUTV+
# DATA 5/H52Mx4XA2FErDSgL2zThbTKXmw2Ipe0eqLOBjPr+xfsMkCdySKpyO63KdyRa1uZcVDoi+BqnS95WGRzL4FEJSSMFXjPzT8MIuD
# DATA 1yZnHBc/H4OCWG0L4w6wLOyXSLHiLtnfOzo+Otzfez54vvf18auzwdHx2eDkYO/p1xXFKOXA82AxxaJZ1SxN53Vz/M3mmxaLJDsM
# DATA lRGwPeSlxuU4HVb1i7iH1j+u1FwxyHdBNbCGA9lfVfgS52Ewi82bSOpZZf2b6G1r8w7+fFLhtNsG+4hl9EaSD/LbCR7lrtb4As65
# DATA fgCMi3+8RwrUHmCaghc87QGz8zcwzTN8vZjlG0AFeM3JOnsxKvBIg1d8W0y6xuQ1gjRJo3i3mfbxJAM/yHeRd6BAAvNmkL6mrzWH
# DATA sKQjjlYU9SADpGqHnIyiRlX1i4qOrKMjCw3TBv5nE+zNq/jN+c6WFb6meQBc1utFMhGFTuiECoDYWLVlKZjiewIf+8ElIUzVmaab
# DATA V+jmGFMomWqigLF3bSnSZNMTfeNC8HoYq1kS7RTZ7TJMWi7xz6R/Fg/yVbQmYl7nUwWguNKRJHwNT8WseN3SXJZ23uHRl3vPD58O
# DATA 9o9fvDw+Ojg6k9Es78Yu+RSqBC9wULrJGTSsyoWGyzQuJXf3MRH9fSC9Ojrde3YweHrw8vnx1y9WgGT1WUAx1iqNAg6fUVy7jBPY
# DATA IMHKEkwoAUrsi6rLCCqiOXzTyNRhYOQBW3dn8N/e3Z8hJ/imgcLH4QdlhotiEZL25Vf2gyi6RRWkMaRr/tbp/s7169m0UtaBvmRy
# DATA ic9wBQ3+Ffur1i5sbdbgaEmpxX3hWcKCesGlh30IWz9Pfhb7P/K3/I/9VrO9qf7YGDad37vKzw8+39v/Guju6Nnh54Oz42Ng/Sef
# DATA H1TURlE7FWPNRqnnXaCfJTkBzDLb/C5KziXe+ZFxehxR74UWDEDDeNOzIYiq4p78GpB3rZGRqKh8zKtZEBHcg4P2ghBeRdgnB58f
# DATA np6dfG2tqYG1gaYQqCriUyMFpspj1bh9wOebMW9FKT62G8l05dqv6LQkS0G8RBSaY1+MxTFemOA62wKFSTmqJnVpcbA8fibqc6mp
# DATA z4BTuhj7Ful9l6PACvBpCbOreYrf9/d5CHMnVTIVVOhAzTxNG/4eM+6IazlhpZh8LiVNgqn0pbxDdR+9Mqyu1yWzmi/wQh8AVz+1
# DATA rnjK5ykaqtq34Zl8bEt1tV2bzDVrpLoKmMikP6YkVmWGwbNpuk4FYWZ4ZW6sfwM41wkRC5WNu77O2b74mcmSgNDVroqKr/HGWQ4f
# DATA aRMtJrO8ql8F8T7FMjiDIA+TZJesA36VPVADZZ+9pdWTUy2wFayvuB9UGbeqeEwtvr1huU/LciKN96ggHB3SulsCSiUNOEMRW3Ud
# DATA ZJrBksS8TKZvyPCr1GolKqPp3tn4Ll9dzYSXPEGPYqXL22aZj5wevzrZP1jFOg1P0ev9yS6FakGvEs0piAbz+M28Co9T1Gd2Mbi6
# DATA viU9zPCC9IxSnc7n6etYysbSJ+IwGMWL0OrJKpXK+Z9/k69V3t49qV98Al/r1sDsiv2YHEb8OvRT+bTw/dx8ZwZN25FGv8/GXuH+
# DATA eLT9jbBZ/Z+hp7YublrLY+uABIg8tz1feREoy92t99W9Hm+vbBc8wiX9O3mhL0SfEgSI1bHK4clzXyJnJPoVbsslI8XsVzxZvswQ
# DATA agUlzhpGvbbLOzPNdLkR9nWI6ZKXbJyC12PJ8/EIddF6rHawhlQp4SyF7tHP7rPudCNnJVZ0ZrRFGdpstXuGRzVO4ogN+RuiaDJH
# DATA RXG319S88Ysgl7jAyqSfElKpaghhSzQ2NMfhX7Tjqvbh6iivslhVFrPOxA4So7di+QQsetZvy4cNetPl6lmZ+VKV35VZa7H7zLZn
# DATA Hqv7fba3/+NXLwcv986+qNQK4JVY3yvsbWkfXkHbKjUV1VCb2Xqe1Qpbs+usCpQa187LS1CIaEz4yOL52wqdVNuxF1Yl7+2oUHCD
# DATA gsb8Ky950YVawQFUL0Yo4q/+H/kwcL9/t2InittdRuKcHjVzUOBBB0uwcqiywd5aCuYO0aDhP6iYsct3h2d4VxN2f81mw4Uqf+Hy
# DATA Rt7GMV16B7D9LJlVDXx17mqFAlCksJUY8z/a5RHOFXovHqMciFaA1Sc/P3g6ePrq5PDo88Heyf4Xh18WVYQSP4rtJXIbE06UeWK4
# DATA FHv4/c+Aoxyo0gbLyGJmheU5gcVRT7VSgUJjl2y2e3UrstLL4Fdzc3kq4YyZCmYsVSvv/t/3f/PuF+//6v3fvvul/+6f3/3m3W/f
# DATA /erdr/jjr9//R/jyX9///P1fQZv/jR/89t0v4esv3/0a/v41/n3/t5yAheSlPFJOlErVa5QI+zgOpovZwBhrRYemE+xZyqtAv07u
# DATA 6ywPtA6ZT5PenBvKddVf11nk8EdKYF6ygZGBKL9cwzI3VhH0t7eAlxRrtyueV6lxzBLFnj1qaW8//pjtXMu5tlPmHbsrWM+ES1oN
# DATA o6Rd3OuT4KHjeLpkk3PdYWXOuGaEZeEspqTHYQ4+m92We5pyD9nzZiaCJ1xK5Vyp8qXZn79r8npKvHlFk1s59/TrpJDG08c5pB/y
# DATA wNasVI94Sl4BPZJy5k7R1B2DnVTcHSYp6EGX6Lfyfq724IrjaMVeccIK9oZhStj1y9w63jJFmKWuOUvtK6IqIZz75qnnR4GVw6PT
# DATA s73nzw+eCnAUVp/jDVj3OXvrasoamod3BcwKOkflnbvf+fZU8gHxn+WMMOjVgkdMBsQsTQm9Y+Oo1HX9bYJA2BeJHzPb7/sHb/B0
# DATA ZTKn6kbZNBhvSDVEo4xwXg1djpOM+VIXlrnfHmllCMABZLo6/sSrs4QBbGZ0syi+Vihzf32EM98E+CzVN3HSH4gK7ewHoUGVT3DB
# DATA rFFAdXQEqxd+7GDjfjc0xxufHuLVH8cnX8PmGLw6PTAQlo1Hd4trlD0Y0DCTP0M/DW9CPaJyukiGBciu0AqwWr5uPHb3uASO2uOS
# DATA M4oIZjE3vFV5AOjq+92HlM6AQfnWxGTQO5sqFQrwFtJ4WpWvxAHxuwGMxkSzdnmLVs731v8sWP8ZngAzHweN9Yu3zXqr3b+r1CXf
# DATA LdNOG6UgWQM8Rmi8PDn+E1hCoBi8B8asJOXb7/olbmB+TKGd8gQFyXr4vfmKnZwm1FVsnP6Q1ReGr8xp9UDUjrU6vJRFo4bv2VG7
# DATA iYOou4X8Uh6vbkshbi4lH6y0T2Z0qxqeu67iCw77ZMISUFYzZa4rygRWVxHdrtgFntW+fYn3OlA/K0Y4b2pbFJM8cEDH6VxnWjdI
# DATA Vqm3pLk8lDFyIZoDxxyKfbsd05rajiHuRHY0+UaWMwQq7B+g9AByDLhZEatdBfz+A9kCtRIzXSCx1CaJdCpj3donq95Uq+e+yN/u
# DATA fxOLAxqvAFpV4hDAJG+s55PKdyEuLL4ji7GjMIrODl4RakufxGmgTtNwkQuvPKZRJKFlG0yAtzcJy0b2lHomeizDnSu/Gh4dDNAX
# DATA OZinnO2OtFst+Pxr9fucLira9jQeBXTvGtjsY7xGQBczxF8yVRoVjxKaYw/sEKHrUBpLARU1sWm8mGfBeKAmqPrLeZbnpH/OxB25
# DATA Em92gPH3iYlVtEQungINajhqVgA6ux1ojm9RhcLKI+LOO78nk1vSDf1la1o3mQKaBqpdyfkMmwsryWJe+Wi3LEBQQEv5mpH9TYtm
# DATA AobKKWc576UMkFjtxu0hijKss7JqLC4gxwTXjXGz7OQrCGTc6CxRJbkRv3SamDtoSVAbDQW10UWBPHQ9bwpYa4eD+i1tio8ULpzg
# DATA hi0aNC3uLHn8fGWNSYy01E1ZDrh2Gi6mTH1GIXD2yb0it86KgE1lN4MypUmkbm1pVdQLD6pKktHt+l2IZxedGEsdL2ZaswITLddf
# DATA hotkHPG32YKzUqnis25AmbpIGTKSM7pIkceOHmk1LoxBuWN6/2C4PpZRXX+uyZR1c38NFKWvLYdeuZ9lQpFKEVXd+lxZERelFsT5
# DATA fdbDhbecPSWHV3ctPYjP4JedMpE8n5XAHEyvGRIMrgLnkvZqlHub2yg5rxxifXD20Zm35cfyAyylXny6wPBkQDcvHp59rTz6JZlg
# DATA wCcGEhz2NeBVye45wmgNSDr5+jTGW40lxUeS1W1+sSJObsXIOY7M45UAg+TzuwLzUNT+8dCww0cD9NGuDd9jF+Pp8f6PYSW+PH7+
# DATA 6sXBYxZEKePGxsaD36eKlMvHtWwMmT2ZHjZhRRX37JqSmHX7dJIjXZXBUSoFRPVQvXjuMn6Y5Nf+HO7LPq+gVZvlOyryjUqJhHkg
# DATA 3pHQifP5bQnpAcwyN5JSJslYvVM186qVBTXKxZnuuG7hpXzZNQgfMQzla11QXFRcQ79dmi66QvJSEA40op0HJrEafrcdw1T3l6Sv
# DATA 00zOxisZ7cj0+0OClHZzXZTAjvZVFIylWsGHq2Ucx6b6Azv31Vvz71VfypZdv3yP3uQMUr6MthJX96topNSxJEtcc1S68k39gCbG
# DATA fVpdLr3saqVoNZUk+Cst9f5Ef91qhfr6uzCvArW6PGzJSnZSCNxdt/N7UHzV5rH8GI/RO5d1TqVFfqCm98E653enb5adMFtqaGLz
# DATA Rj0tBpXKoyCaEakzSd6jokZ2Y4mWSE+ehzcNDkh+DAakZgwGKMcHAznGTVUbMjrUwhUcGnvZ5QJDOS/pSTWKtQjbHQyAlwwGNetN
# DATA DHoOAnmlCohE8LDQLig2uy+JXcvtJ5HlUVvxrn2GJLxKEcm75485HnJxf7ecqbBu8qsCqqm3W6GCTwMsVqjcuxkVjpaO6A92pZIc
# DATA HQ5PDOUyb6hECOm+QKPLWRL0Eq8iv68Dcd5qWahLFZh48iP6sRNE/p93v3j39+9+8/5/f/erd/8N80J+gRkj7/77u9+8+6+c+CFl
# DATA M5ePx4gwrBqFsu4fn8qHH8e39GnJs356CxOeHLzBA6jv/r93v4Wx/+r93737R4HhH2DwX8PfX/rv/yN8/G8EyT/4mI/iv/sn+OUf
# DATA MEHl/f9BKSq/afjv/u/3f4Ut6Nf/DLBDs9/CT9QTfP31+7/Fef3/lOXya5zZE//dr97/NQ787r+//8/v/un9z6Gvf6EMGTXk+7+V
# DATA ATF15j9RX7+CTz9//3++/5v3f/3+7xpAF/8T1n+5isczEvnTOV4vSxrid3z/Y6/T7hXq/7T6m60/1P/5Lv5hgbI18mRLOt7ajr+2
# DATA GbS3436/vzVstuJes7vda202m3Gw2ekGwajfjZrtoBNsbg3joLPV2tre7ofbW/A87gTboxj6wPzHNXIar6mLetbkPsU1c3PPGlVT
# DATA hB86na3+lsqZXLPg6G+3+qMIqCEYRkEzjEa9TjSMm9v9oDdqt+Ct7bDb7Wx3o1Gzv9kfduJ+M2714mHQ6Y2CqLumbr+hfvVVp2Ug
# DATA 9Lc7JQD04rgFMw3icBhtDfvDrSDa6sfRsNdub4etXnfYiqLNoNXqtVotLGUVRO1NQMwobIa9rWgrcgGw79org2Gr2++WABH3h/1N
# DATA WBIYZas/3I5H3aDXC7eDdtzZDGHC0Wa72xmOhqMoCLdgHaJgO9zqbG8Hm8POZmt7WACipOBXGTCtPuzBMpREW12kivZwBIvS6W8O
# DATA e1Ev7nW6m53NEV6yFDWDEdAHEMN2CxDRHgGu4qjV6nT68SgMXWiY/QyGdMXmKkha3VLq2O4AZWw3O5tx1GsH3e6w39yMtlodQFO7
# DATA F7TC9lZn1G/3toa9XhB1ujFgZrPd24y2+/3Wdhh1XEjonruBCOEVkGxud8tQ0uy2OjD7drO9FWxvhUEnbAW9eLPX6vVhSbqjeHt7
# DATA swf4aQ/bAGq4GQ+bUdiLt5ubsFxAVyWA5Csg2O6VkkgUxs1w2N7ujsJREHa2gm7Y3OoBLeAWbvZ7w1YrHo7Cbq8dNZvBVnMLSDVs
# DATA 9vvDYb+/3Q0LGwVUZQCBjouWQwFz7fVLwOi2o2446gDljbb73c1ouNVrd/rbm1HY2up126Mw7m4PkWO0+0CyQSsGYHthM2oD+ba7
# DATA 3WYRjOxnw2C6iio2W5vtEhgAhFFnOBwGvS503QR+tD1qb/Zh8FZztLk52uqGcT/oN/vb26PRaLgdbLe3+1ubWx1YsWa713ZhoNv3
# DATA RqDl3IAdvQobzXarWQLJMGqF27DM/a1uHHWD7nZ/e6u31RluwbBbIfwB8m2FQCNbwFNhA4Vxp9VshRGQK0jA7nYJJDlYXaug6JTv
# DATA 1yFMemsrgCUD+u+HPZh1H3j6sNtpd+Jt+L3T3RoCC223hoDQcCuAZet2N7vtcDOCvdVfAcUgBGY2Ti9XQAOUtl1Kqa3ecLQ96nbj
# DATA ZhDFQ8B7f2trCHwz6oTNoDfc3I5b3S7wkGHUBFLdjrd6/c1mL+gOh60wiFsFEiGFfyBJmcn8dtW+3eyWMZBoO2oBYwhb8D/Yn5uw
# DATA NTfj7mYwinvdfrMbtyLgraPtVjfuR2EUtVtb8fZms7XV6bdb8XZUgEWZxis2bmtrq2x5gBU1W/0QpBn8EIP02gIZGrd7naDf3uxt
# DATA BS2QtVub22EbZPBW1BkFcQwsJYBNDhjph7ELA1cvHZA8X4WLVikYwKK6wMa2w7DbiYFsgbW3mvFWC4in09zcDIfdsD/abve6o2bc
# DATA bm6NOlsx8PVO2Meb6Iq81Da7Vgk7UCi2S5l6G4VsDAOHQa8TBu0O0OxmFACr7PeieLsL+7YH8n2ztxlsd0DY9YDzxe0ogpfCVnc1
# DATA IANzj+UK1ABTKCNZWKAAlBtYv2C4udlqbwG3bUVdXNDt7jBsAUaARIdbwF9gRYJw1OyFPVBB2sDfkYrvASlK0cReRTKwRct20OZ2
# DATA swvoiIch0G8vAjHcbgWjDjCSEDZxD9C23Wv2ADqQ1L0WMD6EOt5s9dtN2Ef3LJUpYLiK57a3tjfLQApA7rRBjR+F/U3YJptd2B5A
# DATA vWETFMgA5DPwoGAbFgwIGFSpfrsTjAKQITCHoN/q3QfS7B5h2Om2mmX7egvocrPTCYHVB93NJqxHszsCSdfBvQy6RBSjEhB32hHI
# DATA wajTATVp2OxuhaClwFvtlgvOfLxSGG9u9crYSmu7D0QB8hZk6xD2NZBNGIYdQAOIpX4zHG2BBgkEMtqM2nEw3N6OoGUHJPKw1+x3
# DATA CvSyGN0MLhdBFq3itEAOZWraCORrB7ZsN4RNFLRGML8INNleK2yBojQawVptRdsAVXuzBQpduA2qNGCsBfuq2yzqJOwkWoe1WK0T
# DATA dEEDL1OOtsNg2Im6MFYIZBK1gi5wjPao294OgHl0egFgpT0EwmmCYtABCo5BVetHLRCSsFJba/rmAwJmjW92QmKkr9d88S5RYaPd
# DATA aPUBfXfe9/7w74Psf6OA/xvc/90D7axo/4Mq8gf7/9+2/u9nWCsimPrq0EUmCW9S/hdLByWTyYI0jrqfjkZUI43pyQ9TvEfwvrq/
# DATA fD2n+hZn2TRVXy5/lszUZ7zoZpwM1dck/d2LA18t5slY1wcOMvRT6K/xZGZ/55LBmJ9wsrd/hrdelDnMKt6z4+OzgxNMzqh8M/2+
# DATA f3Lw4mhv/9Xp2eCLg+cvD05OB1+2voFmB0dPqc33ffg0WNVq72j/i+MTutGcXLV4QiwbrlU/ndT+nFsOPnt19PT5weD0iz1gs7sV
# DATA +xaQyg/Wat6zw+cHp5iOUilu8ArneYqqit9st0TRaV72m6Mm2JcXV4zFhu9oQ5ZujxyrTwVZoltatrdy4duWlzNQQc9dgnBmjbxa
# DATA B1x6qtUxQkuJowR/d6xjmpAloflOyyWjRE9IDDjnu2VK4e/iJ8OP2mNVqXkv9n4yONn7CkvL99wiGvQIFxyetQuPCifLoioutqpr
# DATA iJW5ozgEOKpORQyJDNFzdcXJkC83qROB6zJ1cluJ1am8K9u2IUd8qQFmVKvLcuV9kd6D17G6bXnHW1mUrkK1ptR/qp/urFunH/D7
# DATA eWP9wv6p9nHt04qKkd57xkHuLxDmJVDp4kyYrz/AGxJidZ2HJGpi2GdOV0dWK+vqEA3lXowSPiI2X8xg82KNcQytYIRXSi9iPaIk
# DATA B3RgPUeuHFNtcZ2imndf9QF1dtNAo0p3Niq6a2cdGQa8kybho2OZ/Qre+ou4HqbpuGo6hV+tmehS2UAqtOkEnSwRdm0C48dqFXmH
# DATA hpjSVGUeWfN/5LfuW4yn+mY+WY5Rms7jzJxREl6LRUemTpiNvtalvS/nyWWqMnix7CG3bcTTiLN3gC0/mGN8aG5nKoNQLRSJw2Qq
# DATA D8931vFUD/Z/wSDh87ISyghWFR/aWUUoMp7une35FamgaG8MfLi/t//FgW/LAdog6nunfUd7Afut1R5zsv7VNH4z43tDnFn6clWR
# DATA WQ+cF4ssXSmHiYAyC+9d6xdyIaPRMWSsYBqCAuHyI17ODC8Pn1WZDfmfMD8S+lQQOzQqbxcgtEi5dt6UJakO1yprtfPWhWaLVBxK
# DATA szud0HLPACBQoJtyMb1G8DYrwJ17m/gZhqvbu8rUSQ5U9ZRJ8CaZLCa7iskbDvlgwc3i0fJl/H/B2KbTDlgxDHNSFuMgo5oO5oy/
# DATA degcqZEHSGew7hUgvpof5NgsDiZmLLoCb1d+plMIVZkJ9NlyaIeEA3AFef4IeKnW2TxN/TFm2rhUUpR1+roFrpNRzQLrkgUcHn+A
# DATA 0Tvtfm/rMbiSjpbGlxlb59ywZ33cORYxiXvibYWtWLpDW4RNHav4mzBcRdfquKPrSuHVc/XWxYP76tU0X8xmlI2qdpSCu1L715ew
# DATA DJ2aycW3l7XlUDnarRrNQdYHDclCiy4cd6u9cMeMdadkj1V6ip6qylOy33BtSeHWpwq5JIo62infkMbuB7MoV9iKqtQ8N1VOqQB8
# DATA Kmcpbawcibh65oTo+gWsMfw0u/1L0PBrfylK51+yxvkNqJw1OTr6CHHoYBeBopo5S7LWwiIXq9BIRJSR2iKbQ+8Aci7xDniYLrAH
# DATA Uz3mQ+FWObMu3JicVOWOGRbMyc7l3OFcwdX0f+g7jZAOFMP+QDiwUJ7ZDfli4g7v6IBMAKpuB1KYWAmP4GNMW6u4KG4FSxZxpXhJ
# DATA KAO2VpeyZFI20ZGDb3H1d1iE0el5XZ2JT+voImd0tlwO8LwtN3vksjFJe1yu0mOfAXI4vN7Gd8rSkPvqqqIk0iTsykXCvp1edMVf
# DATA tlpIUmCdIlfNIP7MLYoKAjUv41f38wHX4YJ4chiCH6VcRA33QcURMcJqPtrVAkdj4v7zzMvaHl8svoL1OD0vsyB9+aUtjqk1H1mp
# DATA LdWbl/svEXKX3i3kLrUprxS1muTV1YwTvK8UcGdddLqC+PV1e0tkA+zLnOeQqd9DZKZ4tH6pJPl2qQPcRNYrsAmUL6rOGkutbm9Q
# DATA qymNXisWx5BSiAaGFfXPzJFuWUncox9/LDNXMOzgGHfLy6/PIbqgO8fvJGWa0+tpsasWrai1rhXbqypwPQRVtP7JMI6igtZvKdUF
# DATA u1HOjBdsx2IFvnuMyDror2Aj2BadGMM4aEQOvgrfc4nm1nl/56LEIHSMQNoGq00+RzlSw4hyIV+R+fdWFVddLXQU7kqkz88SOYnP
# DATA ntrGsLcpVpEMWdfkauXrkn2ADtzG5/AfPL5M+z4d/nQ3SRuf4TofHle571qp5QAkVTAclOuraDiI5v4ImXfgTjNfEntKBZQzyzQL
# DATA cQ2zoVMyCRyeTxfsVrIdNoMkA9vAMkEMkytIVRwEKpYfq0tsUB6Qrth5iKudwRxAXN0WFzEvOCK4UxKR3H2py4GfgdkolX71iw0p
# DATA 3au9jOaJEr2MPawxslEx4zR05ZFvvin+/DgPBF4zvkSigsdK8aQLChdrhAsL5fEb8tXTzLhJjSlL3dBxM9Bm3a5oVbN0VlV8rraK
# DATA u+vXHDavrmpafq5VqmkUZ2UyJQxASNnV8B4SKeliPlvQuQFDmLUHaJjfUaR7s4JyS2WAnHB8SBQUvVrTUcoHjQiYsyA7hF+qy/oc
# DATA NiR6q/NHhFB9xIiFv+toC3UfBMHmJvwpO5aD2f205Ph+3UaQK10svq05Hf9WJUaGVlkW53mV8YYbmFRurKhAUO02dUVtERosKHTV
# DATA NlzUh+yzB1131MuHWjX0kl+wxwTMTzgSxZ5DKoiCjRsydeX60i624psi4oyYwht5GZXnCdD3mx36L3LtZvNCdcP2Cz3AI1DB9DJG
# DATA 77gtyer4gltP0pLm0JGCAoNoSk/j+uUc5RI7hdrbe2mVt1o7qpVpZ25Z0AUrtIdyQ39qoAOBC2yw/lLT7IRid2L/OG9XSjQ4RSYF
# DATA A0a7U1Df1T19eXByenh8pAbmyh4N9ok+xtUnvUohMY5mqN9KzAotFwtGnWXNfZAJ52KC7w56jBH3GFZou4ntp4pE8GZtqrShzjM5
# DATA VUBXLLBDOESGpqyKs+rfNabI4SSIkfV7LJnY9q52RWJCjfFG7qhOi27JnZWmrlvzWBcaFny8rSx1oJm42Ho7Dm+/u1cAOa6v2t2d
# DATA tfGq1m0POMk6vYMhRnWvE7Kf6Xy3rS91VzxPyiEvuQDU+j/SxW+5C3TP2ttv2SR8atsygKxn97OOmvMawaluhKTWaouwv0Bkx4DZ
# DATA Iksx5bMxvEp8Cyv4kyJvy9hUnWs0PcL8pRvZuMxRVjVQWXe8UZz5mzfNJke6TJsVdYAeKQLNSTV1cZLul03ge67+Ek0J7ONuV073
# DATA KQPXdAOIs9bde6gwztIJcNO4LKSzsv7io9FwGU9jddmNV7h1ddnnoA9S3+tuUOUnXU+DOgOoz/3ZhwFLzgByCa6XoGLF2TUX2ooC
# DATA zAiJLKAbvlSK8ylxJIddeitX3VA9zEJvkqSEO+yJLzkMdAUDwAu6LizViIpozk0OkyGRRkn5ouJaV22f4P3140TfW00KMeYaBcRh
# DATA qByYSkJCysTPGJYfJW92Kw0x8NYxCpJku9YGqq2mrN/RmaNrjhs4RR45TEjx7ce8p504m5tue93UVPtXW+7e0glprs/eqx7Ki3YI
# DATA bQppot0T44fSm5rpSYMy05TT6C19axwc/OTwFLaEfAMRfvDi5dnXd/eUWFl68n1/b0p3LVnBb7y+abYYjpP8irZBjrLe7AF1v+hV
# DATA kpd0N8vSEKwUPIxP5UPmsGXiBTAFvtLPV8ElldiBxR8kTa9s9r8LM7qfIQGlqOPuJbyJ66EQ7ssuiP7XZVWl9TFw8poOVxdIcJoV
# DATA 0WSeyO0V5h6Vj2xOYv2ukKvfRHp2KsuY7f9onIsPRXn3gDSQhUqmXUklGE6ObGSTeRZbm8n2Nbiqx0pPhhAJbXjndceDa6cp0Qs6
# DATA XA+mZe33UnggnSlas0sHoHVA9dQwRlCpa73rgYIBxRoG9zYmLD26tQR/H90caerD4OEFWW7+QGkDVc1AI5KqRRACDVmStaXrDoga
# DATA PS5/lXFuvesY80ud2AUPuGSB0nqpqaQJWQaarnrA+ip/sTRiBonV4trDhTCYNv8XOWNQTL397vP/W61uu7+U/9/q/SH//7v4t7a2
# DATA dhJjhSo/X8zowpo4siojcw631LIO0CmACaERNA5R2RgtxvbdtPek+1O6/gck6S+Gos/oX271R/S5et7Jwcvj08Oz45NDynTnA0lS
# DATA Agb9DZdXYdZI0o1xOp+DSb9hLrDVZWKWfipe27S6j+XKMk5/JY+LfY9T0MDKoCo+KLnFhTvjMjf3z1VVwln+pTgM/Q4933l84yIh
# DATA 1cLn1Xw+y3c2Ni5BF1kM0SuuhzspTOLOmawB81FdMBx33uGLvc+x/mDhHIT4kXbOm+vbwfqIk39q3tODvafPD48wB55iuCrQMkvz
# DATA hKop6VsTTPZf5Y8rzrVyS9Fgc9m15Ev/cYWCv6oQerFVJs12dDMFBuywYDzAktxV3lKYTp7OKeNi+aYXXcLHuteIXkNw+X0rnKDT
# DATA tDEKhA+5YORhxDc1FuMOCq9W9MF0QWqo1SPfXcBwPnATjnPjatUC5AQW4Sy4zE0F0U+Wnj8la9o08ZbvUbTeeOT1DGl2SYEvc61E
# DATA gzuRiyyt2sM36D09hylIsbaRe98gF3u0aYlq1Nks6Fwv4lJBVvS1y+UNTheOcs/bkWdg7nyUrWh1XruwFxQALxZbvrykom8yUsJO
# DATA 6SLw1izpIBdvBnPP4l3Bn0IyAk0HNEvJasKR6Mpga1Z+MM5TpnayQHNxicHvSZDHeaPQ6951CvZgkL/Gnp9S8UH03HAHePaM3oOO
# DATA /J9ihjL/HmHH8Xjkdla+gqVz4wR6Fx/ytAR7FyXFtVQFS2vjYGo9noRJwnkDxRy6m/HK51rN9oyNdexPUdbOihtAS9e+7NbPlfCc
# DATA my8XbjSNX1JHeAjt1Y9RCa6TmB6wKlzI7UOtl2996DQRTs1wnVvJ9a/rJKUbkxSmi3GCqnUJjurqh7t+s+jIPePSlsplQExPtFPQ
# DATA NIKIkmhAuQftPTJ3yZDjY9fSGhrZYlo9l4KWWKQPp3dR5xQwceqGwWyOF0DLdPlHjJSojwzK7gTU/U6zbgCvOVkoasR8HkFrysPZ
# DATA fHwijlA9LAmsMTxDB1Uc5XrO42SSzN3cTCvDvDg2gGStIC+J20ZWfYh8H2wjzh1VN+/xfVt8yagTmpVmHJk107lN4nHER6HwNgJ4
# DATA c4ff55ivjIW1CAcstZRJn1D5eiG9iqqzGHBhRV3I3EmRUkvNsmjp8rnLLF3Q/QlqZjCEfeWfelHfnS1jg+mIeY/FC2Tevm0Q7d1h
# DATA YvHH1LkLjrMiunf3wsOqVXqRa3xKWd3XcTwT4PDyA2Cmat/Qb5YuU9xEiNl2cwkXDooVcVpDWra1JDTm7lEF8jtbLzhxw/syuXV/
# DATA zAAfzE94KfcRWFXVVRfISRL2Edq3xRZXjlM/VdlxOx1aw7L6El/3Hmk7DR2FdJlqhAf1WJ+aiJZfqVkXqGtOjgDguu48CHlUAFuT
# DATA ohrA0KTu3eXMlG5XdtywRAYt9T4u322q0ukcOGdY2Hsuw7OGpMN8aLPfx+J0npoYkzj3YbqYkqXpeCKlgaP3lmxsM7ylBfNhY7xv
# DATA DgThPSjlzbwSn0rH2JWcopGjD9cdnXD6wYq98hsXd/WPdvWm3ykryXmiZaagCBgPbp5oZ7VwZE/sLtjNyPrjLHO9vUNo9/recKRr
# DATA BpRw8QcvQf++r8XbCN5HlK1jRIJtmSgex2jTPgGe4lMR3rpihzMgQkodlNr1rq63tLrZhOrw6qWpFXQ2XtJPdv3W44KUlh5xqj+W
# DATA hS1leVhNMWsisw7TxZivz0Mn/PhWKbbJfNXicH+jyj4uKoD8VmC/s70z2lQWYniiqwfTremKwRYopVL7Nq71Dy7Ca5tEH1LQl2UP
# DATA xjX5KqZdZbmuaI+s1irPywqw9bqyIR/wZStJ7ZbFFZewuquNvpDM/l/POayLNPwex3ig/ku73+q4/t9mv9v/Q/3X78r/+6VEVXU+
# DATA oHAOuciLna5i+6PCAhY6M7j7/L2Fui33un/r/kuww16Cyf1mhTfY8v1KvRa7/gQfdCa1Vc5ysddht1iGwkqM5nvXSNO9/yAzJSZd
# DATA Laavyfc2B544DibDKNhxjihY1l4Na2QUI7QMkVIEqT/3yBE/L6mQoULeHKqaB5fAj3KwfZTyI5c303xMlMxKZ7e0fGqwoQqz8GUg
# DATA y4r+GBa39D3NH9fZSbG6CyubVa7W5CRDrghAJwicx0J5/BzmeJ86+e6/vPsl1/ZWhbz/Af789v3P3//1u38Wylx/95t3f49X2L/7
# DATA JywErit5CPy5ddCvcAW1XP5pn6kzz+R86iPKzN89OAOqNS4zoNLjWID8Nw/MgBKnSTt9G5xXKK37YscPiEgDJFAmDZ4TfzYXCQWy
# DATA FHQFJ98ktJjhAoNyYK7qs4Sg5ERPLcQtpwfNEnS8Ic2cMz7ce8pxFP6ZnBGCO8eHyQFbgk2fBqcLZZKpnQWdZnZLvNEhmVsN5YcH
# DATA zwK++78UXrmeO2H9N+//hkgKK7nDJyz//v5vqCb8+/8Ej/+Rys//M7z0L3xksKSAvhCLBSIdQ0BLAJibulOWCSiYRL1NJJwgm8CH
# DATA uwdh/i9YeP43SOTv/h6oBmH5DZfFx7L0QClWYXqsd//un2EqP4fvf7sSXiIZgLBuIgsE+3kB7ovyjDC57mxkBZbe6lHu1t/CJr5b
# DATA B3tk8Wb9LXZ41wDO3bj8WaWQjjVTLozRPUEsq+edtwylLvx3oQbjYSpLVowJG9DFebQE6mSS9ZCNCed872OyLG1uBAsBy/Crd//y
# DATA /u9KdvEvKrWyc1cr7lx/JDr+WKJhFb6avXgi3kxPX7jJDowPnRoz2l+8+0f48sv3f+3jH/wAZAazu5dnPf7YiwuxqQKAt6WVVwBQ
# DATA scCVndBHFQn74FnDlvo7n/bar2mifDsE/wxz//m7f4H/+8Uj1ppYMV3uQvybYOOUTCVrjEWJqZ60H0qipW+Zp5+vmfgFbIANEZ/5
# DATA RpTeTJGjb9CW2Pgf7L1tdxzJdSaoz/gVSWqOs5JdVQD41lKRRQ2aRHfDIgEOAKq7BcI1iaoEUGKhqlRZRRCCcI5s2evxsXbsmd0P
# DATA s3vO7KzP7tc9R25LdltSS+fsLyD/wvySjfsSETciI7MKILvlWUvjaaIyI+M97r1xX55bOAz4Oc3MwWR0qq5EHf1JZzYZMDmlLrxn
# DATA Ton4iqQTKqdnHwgMznNZQPZihBg54i+YEP/k9T+qv//T6y8jNcO/xPQjv8AsILATf/P6i+ij/vTj2YEfwF2upxRjoBhXRORKJIID
# DATA Ftmj14jgoMHUbty4daXzwpsBBvCTik3CIqAWSHS4ilrT7rQo9jkJfYDkJS1f4quQGZdEfivj1FrBjwKj/G/IEH/Bi0Q5VTgHSqQW
# DATA is6IOjMR1qroYUS1uqEUurt7UvTa942oxJraJZxpD35zClw+YJDwrVaQh/a0LLSPY9eSEwgnvHGRNew763F+4wa+dKJiuCNGKsEM
# DATA rCh4mHdaEPHiYWTfVWFivTEcupbeecEjCU3glmy5G1QDW6BFi7ND1egfpoC8MQZoGqfciuqlFp+qLegmdFF844yAUBho8pwX+5wf
# DATA 1Hw2yplcoDQQV+6tvy2KMIq+yjPj0AqSzVRxkOJgP1LKn58KbDIc1Rx3AEfq5DE5cudCtYDerVBNUSoNjPo/Y6//VA3kb0B8UPJd
# DATA UfRUjz5XZOWnyIe+8KYExFf11Zu/FEcRHjpXI6Q3Bnaxf3jW4ThZBhqTe6YfuFqLUS2CYrLz8VpDFQrRPSF4f65Wkki7IvJxWeAy
# DATA dTCetJT8+I7D7NF6gT4Xs5PaCcW6m8ysoty3ynhB+S5+/Xlw8GrcsFb/AeWK30SQaQtIpnrw29f/LOQGoFG5Y+dcMKCfRXNHp1IT
# DATA kfFFVgmO5v28kx7ko8Fsys7ocbOJ7lH4FoAu85JYfs1DawZCAMMCBE6ABhVYXABTFxoUItXuUPPF4ufvcPv/LApO7C/j4Lj0CPKF
# DATA mgbe9jkwMcg/po7SX0EGNDpOl2ocWwSdtRfjDvY5cqIIQRPERifh5WllcUZ/PZoUd3nhYw3bEPRDKJ95RTSciuYIt7qsY06ucUeL
# DATA 506XLuqBcgBh9N3FVKE9Jjl0Pdvfv8ThQwJj5BSghr8A5vD6H+CgCQpqaO6XcKPBY6lFmNILDTE4pI5lOBNiYDaddmFNZUXBdS2p
# DATA 5+rLy/eZP1ej/gdisG/+J/X3F3NW2kI6iS5LFA3tVCluBZ76VYeISTWn4Cr6rjZ/jf8LLCvcydSy/jlpZujQXoHb4NikDCX0njZE
# DATA mZijyz7Zplzjf8HeK3noN6OHAyWx9bvWCAoa7Bxd6KgtZrL3rDNEzyllZHpWD5OoOxiMTkkH6E9cXU+lue3vG59Udl1d3b9wbPm6
# DATA 7/ZEmke44dBbgS8K3PIC7kyYlfEf8LT9E5yusqOnBTXwhGg7LS8V1uXcF6HJnWLNET6VlDDKzbutnCV0PDT6qT5DF+FlzdOXWa9G
# DATA yn13Ra9fv/4QeoRro875LB0gpe/xPYW95IfatjE9TkFjwdFt5LhoqSsYT1yeYMCnONerxSMqygJ4/LWTQjnUix4GoxT9uALrxUoV
# DATA hdd/kCqM+xRM+3ttCY1UKXVolC78gX4eVuAkAv6tt1Qy2Hyk8tT9I+ZCBY2kOnILKKjKBJbLAESVsqJS/xAwE4kVB1uBK8UU67Gn
# DATA xYobFTBPfuJ4t0WL+x2z1BRxrDRtzb3WTVQS1OKDweiAEiHQ1afEA4YY5IKwU95MXJZxtucxTldWKYBjcaVLYQETNq0W4wxr4AeX
# DATA FtV+L2KaL7DQ/d0fAjMDa7c0MfLk1lw5iHI55DJHcY6Acgnh5OvN4E2+N04UrdY84klBBSZpFQmxzfHDi5HPvsvw2ml6VO0zZAyi
# DATA i9Vndezx7yMXuatuqyqp/eAWGxaqOhctrH1Dr5oGXQf80vekbQ5sEqFxpkVy/Q+oCjJtB/2StZpXLBnh/0HosHlWyMfOvYKjYjrV
# DATA CoOj+CnUC0r1cDJ2cugTiESs1q+ozs/Rzr/ldtAOuW57WlnuT5xWTwbmLeT26c+MPr1F5uKpEfFD2F2GIhV4r1830YDSmlkUJyfJ
# DATA /rB5MAPUlpLq86y0Hn1T82fGXGH1xBSqDuWz1xA2dQloSN6hJYAizF6xTTxRxZ7SRgFUJPw+meO9S8xo5yxXN5r1V+p+t3pFn0Mn
# DATA m9Hvw/9PiYvv3/L8/1ZXbv8h//vX5v+3O0mHOR1KdaGlHFiKkUH8T84xDqBNyCbqBmuDvRWdAsl5NJtSWcQVUUXAZzwd5IunfuuO
# DATA xmdvn9Stf6Q6b35N0+nikeQ61dtkACI3Ic+4z8CNGSyz2B9+hiOKbDlUs9Thr9kQ/3ZTyMFBprwsQ8UopxBYBYcdb9Ed1KUpWcui
# DATA wTBsjCLVeqiUsk2Myst2BqQH/zBjG/AEhnO3RWb6TxQN0LEKinvD6ihZsgvKq+iJIQ8k81o6aHUia1Gvnx4NR0qw7pLOQ8nOCDsz
# DATA HUX58ejUbBQkcrhRUJqdcU8ogAx3DNu+1cdkecJX9Wg0pt3pxCQygCNOIeX4kncZnQTHVT/QN23r/tmkTEPmZSXKnD8bi2gVwFvk
# DATA T9l75J/BkOemOtEjo2wIc5P3FHvwf6vLwj+Dhq3QEJoAwU3FdWsLpvXR6YQ03JGNWXb7Y6YJjhgiSnYKeoybb9frSvuYtY+CWwXp
# DATA s7/03S7Udez171znCuizgYpVN7BpJ0UAC+k1zAfC5OWTm8wm7+vA5qxZ9+F6ZGMbGOdYTBC5ZqiPEdI8nTZ3OhtPth6t1wjpeNqB
# DATA d9ZnFgr+UbQyUmyxHJoenNr4a0Va4OY9wrttpn4tsmP+d7yl/lzNo7qS0r3zV+hj81vQIf0O7MuwLOoa+ms1s4U7+W/e/JTs73D7
# DATA /ifyQ0SD/a/f/MfYBYLs8FzzVZVn23GyiOFR3LL7EeBAKRakFRH8c4x6Vf4Z/RimZ3UVEzS+VHctUOvybKgHeMUkuAn9VP32k4CE
# DATA +9WyulQ1oXlXHYE+dwrluuEU4sE9gOwZ6FSEq2ymnqC2t8blw1DYnFUA9sjhCNTqmujkTOIK8iM25CoQeT/tPN78rrufjO7UFNle
# DATA /6hYxLx9tLFd8XZn66FXf6nGdXECCdsOqdLPYdP9Sm5JspGLTRl2JKzoH1Ev+YhO1fvvk4Gj9PBcYmB/p/Y7KXf+Hof0y+jNnxNR
# DATA A5fc6gGp44Te3//I/rt6IuAjRenQ3gwKpF+BB696RC5vNdHA3RUlQHitfBFB/g7j5JGOx4Ozjkvt6B+Iy8KLvMNO9SUFi7RK8oag
# DATA HDECHdIoJ0sDld+jc7xfh+dbne1HW5uPP1NnFX+p7bX+cHdr2zzY3Ppw6/HjrU8YTFVeQvl8qGKHeDpsm46VseaceXHUURNpOsUk
# DATA Yr8e6SdEHfadHV4kyNriZSpikiQqIqIUTjN1WZr7BXkJoqvPr9ndAHYFEGD2dQLSS8WFDOG41eKKhrUXBXoXmlWYcsLms2/tcPUE
# DATA EIIDtkUe/f58LAVxFVXl3YGSLp2WOYbHXCnYX1FoPkCg7fR7EsS9EF1Q1KuJ3USGRUoHTKqXrMfNcN3OTNpob2gjHaI7l7fCjKHB
# DATA 8Mza0rqM+j6yItS1tE7miaqiCaVUstEULii5+aQwyBzgoGs8BgCgDfiMOBJdcBTkWOX0lpmw1yvV4VC3xEiWClWrV4W61TNZubOY
# DATA +sx5qtMFJJr/rCjk36MEiK6Dum34XAuMxV2SSPnO3jj8MeI8207amWY7LETTwNQU5tCEEEEJ2lSzocZ67cWGAmVeBBIZU8zPReQ5
# DATA JZQhlfiSrBGRYkxgQ/g1OVBbswlyFXTd/wd0MERfQhS9MZakKDLXqYd1cIblv2JAaSa5C5/sxaAv2OGHxi2VMZc7x+paqG9xJp4W
# DATA SIXLdYSnNhdWc58UZGB8hw/VPRtwL/jeTR+hFa21TDlo6AkFHWlPerj4uDdFVUETuoj2RzXt1MWKdvmbmZoFbaWG32N1WT4dTXrm
# DATA t7pJzF+5v7XxFH8qlSeuqQsZx5ewokoc+DPygCcG8RPkCL+JcCGVIMJxSyCqv/lLNDn9c/kF1ICMWZVFrQZ9x1g9vUx1Hh7sBfjr
# DATA h7MMkF7hz8NJenRi06g44EJlS8F4RRonTRVgrxSNFYMBkp1s+LIGKllO3i0Bal5kZ/zUVB2KSkunqvMQmTaJ/6T2nVb2ClZkL3o+
# DATA 3X8v+Q7sAxtqo2rk6Bl4faPdvPFvYklGIV12BkruGtdKKEEgRTWfeHQVXhBgHSQJMOUpZDTqtKD7QEPaZivqyg4H6VHexior7Alc
# DATA P/yjMyHrRMiYXeW9YgP8yoHaVZ/zhI8no1dnpP6mfjiHtB696A977bib9npnsdW7mLmtfef+NZFWtNnYT9zJpepofmvfKZRlCyfo
# DATA GsGjCeVRljUNDan5CdyHoyGipekPl1w0LJAgZkO7DMPQOvDweAnM5G9IpzDdK/0XOrZDzQ9EwiEXU4u3DMwahT4e9YeOz7s+dLxD
# DATA YFJOkj+pPc9vIPr9BM23z/P3ktren9xTe7V2LylARwpvCBoPJzPEf9RZwgWgqaNHNxFzj/6+tU87LmRBUqIYcsMV4bA6lIAsfm5z
# DATA 3IcCKQZAEsCngvAeioCBZI+nTHdEAr7pICqKU8d9UZ3B21x8HlMkKlUCj/hvXdO5rqmYDccNrgJ8j0MKspI9oe8DDidD5O88oVQF
# DATA nrdz1KNhVW6sN/b8PeNh0cRNAw0kUcN/eOFdbnEeNZ4bZmsv7h2ZXTB3tIm8U+dznr8DpgK3S+AQv0AB4pcgK6CQ8CVeM39BTz4H
# DATA aeJ36KvwuZIo/kY9/Q0ynUkGMRIZUZB78hKDFxm4xFCoBiqUzJs3fx2Xg9GZdJsAqFOPhFqmIKcRSzKKYauEAwLYtvokcyTVY5Yw
# DATA oXKTW6iQsryQ36eoHEVWZvRx2D1Z5Z5qax/RU40mq5BZDHOB6zTz2AQ2X0hABX+Vn3+OLTohjZenmDV6j/fff7+8AQRiv5Aronqv
# DATA M2v2+joCxKwHU4+WnOvAqi2FZ8XcE5mJ6YaGLxF2DOzjKEjWbTYOmwhvxj6QWIKkZviQw3oROLRKpixClJk69+gvB9Z1z+411Pba
# DATA DsGNAD/QWg8PVoyZCuGK4SQTByPYTU920ZKPNomg8NOfjIZ4I6YZVfeGKWXjzgMSUUmYA88TCHjqczPxe1qAhyVBXzChe9HEji8z
# DATA 2iQke+RPv34RC7cCXErUchaWlfoC8hp0xWbl2XdDXBaT8sTRBnAO6j7rPrHdQNYGLKRPqJXrvWtz4MtvRrvHmeK4+TTSuw5OUzqb
# DATA Ho8mfXXq+i8zDjwcZqfQqXsszlI2IbJ7jQGQdToaFXNuHGrzVH9Y1gXUpEz6R4i/2naPFy6I0KKbwD5a97qga74XSGD8wHixE3uN
# DATA 1X0CTNVCcJlATYKnkaJVi7qrQUnZcd4I0hlxF7A1natmWrRuFy4woV3+8i0qyZ/bHf5mzym/j07pUK0+pGATwF4BQWf8QPPQzYMu
# DATA 0EdjPkgEsqcY5g/Urm9gEKrVkPBjFAAZKpAfqcPhBZPaSuwJqrN7uzhT0NxhXOdkW7qXmuKArxccR550Ggze6XkgMMao7RiGsWOJ
# DATA cFJ3/Y3YmFyDonqs7G8W34itK74GG+wrWWgyHg3YGwyfqQVooB18xu6FDjCn1L1or/gA6uEeJwjXaol6dEPoWkA13u+i8ZnxUdz3
# DATA 6Li7o8kkFtj32kTSWSS/0gGcxirp7b5RGSEannHvr6DiGtpNKzG1KxNEJ+OCCX0MfCrgBHQ7e9rj92A0GtQkVhz/TYPemdIqGMLB
# DATA Cbf0bMNWQaEGiXcr0s3jZy1041DyTDaGP2q0jaQtT4cmG2ue+wG99vf5hLvQMoOxA855xPmFkDWgk0AMWYCGnxarU1NX2hu8rT/0
# DATA xUBPmkHeXzhZIANYOWfhT5gkNLjt5tnJIC72r1ZRAaZ9bE5fwWEgIzSOGx1l/RJJIedshYdDYBwFay1Mp9EbZOCiUlTZa22aq7yv
# DATA gztK5yRTvFI/AGs6yqjyNzAV/t0fIkiofETOaopTTLLTdDCQt0yjxLPSC3ky1fQbm5PvbIzhebIqwxngjAAPqVEmVKcQ3zq1Kvha
# DATA e3EN9f+h7lu/Agv5m79kO88vnXuVuTOZtuBWhno7VQpUeS62Ahjn6YYFcfB/bX1K7DQ7oj4aRANdx1xV9hOjggeNKZBbLbkg7R6M
# DATA Zr3DQYowjfFRF851sqCPzC8IvQiVmQCQY1Cvfou2sL+Pdh/vlAxK7f/RpGc00WzSWcBqZDXweqctPCX2CzMjADmfT7MUDRMg6PfS
# DATA gfry7WbgJ+RgASrcP4VLN9zK/fFr7xHTJdduAH3eUe+eaDdz088kbC+jQcLoFxzgYuOD6//nrK7+smp0nxdV0j9/8xf+qFFlj2df
# DATA nGj4WTN0wiwt/fAvtoE5ekoJtW7fvsU87dUkPQs2IokPCZfy95ymNqgwt/Yt29y8tUBzpp15fAGBOOfuBJDZJR33sQUQXuxs1e2Y
# DATA LtCQdGv+8v03MiW8+eto7elG3VksgJ1gHIqfR5+qmguuCxZ5gl0XeAHz43RC2tM51lp21ghZXpEQO/JMwFgGtZLFEGsSpUTOV4yW
# DATA 8hmqX16L26K0lcAtNcGBFWzMViCzA2ihbxjJJ6MBTEbNWKwco5QdPTEtxquypqkFrN7GgzA4lUuer7w1nYkJkJU+myBQ+F6sxr63
# DATA sn+5vhRak7MMa/WIhlmsi1eS7HZwPLhk4npNqsl0mXHFnFQNUBA3WiB3WvaKX+w7k1HdKcNT5p/B/2LxXsJK2UrLbTN6/XdIVf8S
# DATA fUx+DubBX2JxCpYjs7i2KgJe4Jf4KT1nrvRzfvgrA6BDU+LJU+oh6ivhJS1TrGfBCmFtMxuuQGI4r8OTQ4F2xSn6fzC27s/k1JAH
# DATA FqLlWJdEsoIKUnSQdl/MxsJ/gR6QCwWfuIYDkzgnoy99z4mjdW5o8MiSSaStChRvTSihk58jwrRqrQBSsZYUX2I1deqJ+i84OdL2
# DATA b1m5uiTN+gUm+QJRyfyky1BLXV/Vj/ExAKy21B8kuSMmHg2Eu0U/kguB4Foh/brsKyhiyVQIBEresfza5+rV3NpzpHCEnqTAN0mx
# DATA be2F6j7vtCyEC+11O6eK/mFoDNfaXt1e8BdezeDlhzyHsWcWKNYpLshu1bQs2eGhYkegaWyz64lDQa+FqSAnmyjyVxzluem0w8L0
# DATA zoyDqe6k04cGVhDaFlfForagV0Kgo3naFlWWzc2oVq+6Cz+EYqT992wze4xywTqLoKbLTGXCmNFcuQ4pKLap0668gjK4Bxtk362G
# DATA vKXRzBMAqV6Wxks19naDGVSJetQRh+lwkuXHNR10anpf9+WZeoVVwF8rE9JNLlUdoklt92KtpztcJY4ONr/pduC1QBVCUOHFe2i/
# DATA BKsqwTv3h808m3I+gFrMmSRIm+cCX6BNH9An8ONWOPs7vqQTRM/ixDP7YAnH7EPfmKSA4OdCjjGxac5hoYX027hHll+mk+VB/8Ai
# DATA wC4rphov7qr8f5nLlWGYBN36M/JE/XsKDzFx6sbn1NdYqEu6kjT+q7y9kWDxS4xtlzLL59oJSf33P0rAKJxjrZ87j0EZA0TmoI/p
# DATA G2JOzUccyZ5Jddq72QQSBKoyPP+t0qlBVpj2OpD5XAvhAlgNlMmD/o+yXsdslz3eBNULWm2H9QZDrAU3gEjzt6ypLm9IZ8yF/bKy
# DATA L4cb2E4X1V0KbO+qMQISi9ib+yILI/gPi4lyKi5OqBm6e15KdrOiXS4iONx5uUkLPsEPDHIDTrb11DY7iOfVBEH43+nkj3i5tC/3
# DATA qELE++AF1BcqZAeyJFeh7gFOgNmCvuD/1fexwFiIv0BV4JfgsqmvAL+qdBrnI32PPCx+y9iXPyOJnvwCS+baSa716syegnn0e89Q
# DATA 0f1gFXs3CVjEsQSYeUu87dTRPh2BmXVg1cNrxOvsORmVmEvQbCWgTS2nwaRSZmPvxTvcA3eLO5aSJzhYC6wvtvqjDNSllF6+cr+z
# DATA 0sd8yM0mBT8ows3DXtJZuFTsjXEFRmXyz5y9Arc/YAHsQxreXj7+kbNy3C/pvaV6LI4L55Izwpma0uLbcnsEC9BYeA3jDFCAdmNa
# DATA ZF2+JNLrZb2nsEHxO+ADXgmyXqmN5QqhUHpvjkWwHgmppX94aQGuZNW2pVsVQ8N4DlgabPl/JlWyd39H0EqMnSxqBb5chHV/wWi6
# DATA LqwN6fp+gXF+gIH+W6tfDow8NGD/jRYC8HPHlA8l2VJrV9DbG1SbNhAKCdN7gfUU7idekF3R0fYydlds2sNxL+3e2xthUYrnLY1/
# DATA 2XuJPphScKqRE2oTLKxzbiriQjXvulILr5FrPBG6gKItsqQC1CZYLz8zKifLDBBCfePB0Wl8JFSaVOsSrqBK8AYwLxijAK6pDusm
# DATA 9NJ3kvy5Jyffg5PHgWB8Ot/8J+PqD/p2p7hR6H2O1F3q8LRiz/fc5IQ5qEv8AuUNiYOpvddDM2vtuotqT3DWAl7G3IrwPJ+73nXS
# DATA htk+xItfvLkLvouRaUi6Q5PLUa8oxKA7Q/hMkMZakDmqY89RdMNZdXTGjvvhefzh9tbmbmd981Hn0daTtY1NuEVIA4EY+dO1zfXH
# DATA tph+Y+UaUGFTLmwRgqMeepNI3ogQRwOpU6uNAF7WcWjBo8Z60EV9OSvVfbkGe3mtvah23p0zJaY9+6Dz9NkHjzce6qnQDaEHeDG+
# DATA xEXDq/Kz3BuSQ46Zlz1Xm4V3+CHq2lCmO01fZo0Aupdx1Vwy+EeBvRrYOMLsEdw3XFBnE5MUrE0h85LstaVx0DNPto2xMCl2oygS
# DATA OTJTqWB0aU6uGxydDrOe02DIs0uKZe4X9fByJXVHWbefiAWZE/B55aMUOgj7S1c4LV/ndj0PnKpWxZm6cJead2XhKD/RkDOlCx8u
# DATA Df7BJacA146sHRY6VASjtpbevo35C/VVUFiXVZr2yzrJ3l9s99nfQ/MS/kpwK9H3ISc1LrVUuAtpskKetroH6DDNntkiSveRMVcL
# DATA ouWBHRIpF47aXOeFSVWo9l+vI2ijMQOXnVBi8OYLqoeMjO1I2pJIG2ikaSoDHUQHp2rxIZ1NR7HvJf325hZZb6nDlsxswcOyBY2B
# DATA znPawor12BZx3kIVWKlHCjfc1j2+sh9Qwc/rczd/2C/vlYDSmxgiT2yOrW1V71aU59r4X2H2aDtaZMUI2AOR/kEpEMwhbd84UgT3
# DATA zSaQClvRVN7k7ZpD7+RhSOZsW0MeKpvZEfsqb8d1jvkqpbKWkCTWeOucqlI/GVnNU8qCx1aJYg/VLnyoq2wXGkE3T7zDtrmjntsM
# DATA Nl09BhnFi9StbFKQGvoTEyLViVeh7iNZY2/c4E89soUzIT14pJd2LYY0dN1jsDKNM0g/rnZP/6UicPgzKXUnDpg01F+Of+rCjj6+
# DATA JxJ5H3TKMCRCYA30SRG/wFTE0W/md1UQnClJBs3UqjVKxAEuh/oVjH2fnnHbpfw6ocgUdPD0NDYU+9gxQ3KvcAyoV/HJFWWEeRVd
# DATA TVwom73QjaxMEJDLuG/jmLmX1Z7f9kv/4rbAWK+1F+h/IDyXWrUOdfTA1bVxqx7oRCBq9wXe4z3Tv2hC/0iWwoDpYZmbKnalbt2n
# DATA q4ndc4I7rXUxJJzPX4xK0f2b0WMMpCcEyVnOWb4JQCXOo/HsQI0oerb9OCKYMkpewvHwBAujZniS5XlzMe0IxTlAVr1JNqCkGEMm
# DATA Abx5yT2qNNiPP5uD0lOacqBMr8vVeqDCw95Y8RZJH+WO0HWhWUnra9efbK59sva99Q7padTUkTNnSP+By6IbSRwgEkUZFhxR2Vbn
# DATA ESF2i/n70p49/GW1c0+x0L6nDl/oSAWqgUtpaEpbLsCMnkOfovrJVYFv0Da7JMhSCGHJsDxTaQnYUpDAmo+K9CdMy+0H+0V+7dWG
# DATA jAR8n0y0OwdG2Y59E1IZYECgDWDMEdPhOOtPbJgpC8WEW/BqyvgginOfMR2wkaymHjBzkM8lmB/M44YBHnVitTApLoVqJaF51kM9
# DATA nSiaYOMYPQ8mmamKghC9YE0ZeSyDNufGKRIGPgejOH0xg4zxKsLgX/C3EzYVKmZgkghRnyGKs5z3h55+B6FvgVVl3inHir66ejXJ
# DATA 9dso5Sg9pTpzG1MUYuV3iR9JHg579K162rxjYnZJ5C839hj9jdDRJS7cCJvRUPDGCWHQ1WKGonAfzQBYI+mbB0mzTlMNt3B+ux9K
# DATA 7ZOHyDJvuEKgLDjhjk0IazdrqEM6yWS0ay8b5+bHwaw/6HGQsLpeoFoFzMEVCDA3antxo8e4fDxN5AJJVaLvEepAb1AOIhe+1Jug
# DATA Arctm62g9EZMPO2dVUWn6uzG7NqqvYtrqIRuFQEhLX53U3WjtgdA2tmrrDubpgcDDDLeiINY2uBvRcHUuLNMS82x2nkJZtXV64Aa
# DATA 8saYbIRIoKAzQCUg9wp6c9cRK3w0m7ZvraywAplyA4gO7pg/190kAJfx0JA2evLQkKGA0etfRR/v7j7daegwnTc/DboA2UDCLzQG
# DATA CwH1snPRP6KaBdyQfq0OIgKF42WO6ZKS9oBsSWRcdmUvR7ojmkSO5vt0S4YjMchonqHOrNeAaum+zH7oSRBslOvTKbutD/UaCB/u
# DATA Z4HdFHC9tiCWCzPJBS0YkvGJoFz2rkdn5bdng1djbZMT2uKKzUhCFLs2EUkVBj3MEYTj8DnFBzQiik5y8Fj5u2WDdYB5ZvImTbnO
# DATA SRrANZdcVXNDroIrTRzti4AFcfEvChcG47przctUQQA0iIfBqC4W7DQPQEVQvc3ZEF2WTvo5XJs6oxdedUWfEld4oGrqAhqI0YC8
# DATA TliUoLru3wlh2FICngDMrzg40ncqscC/tqtzJRA3lsWe77Z7ogPiEVnXSRxisq92YQeVtIsTlkKrOGJgR3OaFAEAzknT7mol7I3b
# DATA IxebxCjb5tGBoBDgyFMYVoun0G1C4jXzAITKk0PfX2RnEgX3krTYQquK4B8zj4vEr3NAmVbLaz/yf0LnEuA6/8FRzX/1p9Ve5AvY
# DATA WnxAJYaXC7XFBapVmbqBa22fLCzq5lvIx+DgPGMc38/mIT03I5mUWvv1sJcQIPEbxz3HLHLlA+PIXpehLS7yMHaBrW2oDyQbkkdI
# DATA /exTbGBogsK2M077mkUWrC/I5uzDOuFFUWEH/2aeBcHT95BEZ5OclORzKl92m8CJZSpKJ+P75HPo1jDa8y0SSk73rv9N8iKpJYH0
# DATA jmzvn7KG+VxPectbgXok54CjK5DDi8dJU7iyqy/UnMqSAJMqS1wUbhKLH3ad8pLu7gbiKzDLzmYVjZh7f5Ap6l6hTFU3Up5NzuAw
# DATA hKTk2qOh6q7pC3WYABTFpqD4x2KRFv6wawEQLqqpEFuazJkaK3+RYU/KXXXXwH/Zqt6uDiONuvUUtDau46wjbu4znqMUB8ub9ila
# DATA qCRV78mZhRFXDIJegRxM/1/xVcRv7UyyQaYIr8esQoPTWhdthHRkeBedqOUy+mB3Ex/R6CKIMMfaT3NEi2SmVYYLxzrOELRCKaof
# DATA ik/yQwdjwf3MmN/LgeKoJn+kRuHlTaxfLlgtJcRCBbrsZ4nFsmxuTC3oOcE/rjBV7qdvN1m6rnc2XfPPWZW4XYYot6A2MiBfGDf4
# DATA tvb1bQVvy4xGB2E3eAPWd2JH/YYZedCIgPpfrE7+IbOWQs5XrR9ezqbdZSy1bN3nsUzaS8dTxv/zHOvD98MFtQ2luaocZahJWMUp
# DATA B/BHTbAnGdlsZCeWrpJ3NY+kXnCVDVBsGju4xoEbaGG9i5qgOJkXb691RYXon8XZxqK6pQJDs1KRkfZ8khuUi0Iij/A/X1BzVaip
# DATA M0jPRjMMYHE4eZHXLHggC/ymlLUHLySwLEuLLQWL5R+o79fxT0WKxZXVUVW6N1mTYsbQ8oVyzLwl5JjJbVYG8GGPXisI2uktSAiv
# DATA 0IMBMTAhBSShZCGXoncD0oN6Qa9n6m7yRF9KFnHMJF/DOiObPEnH8g4yDxMxMZneKPEvKvaJnLQW0QfxddEs277nExnSFzl61FZx
# DATA S6dK0ERqbDsjL3xJhfLbsrhrhsXpsOZgV5w8DV6dOolPeIy0pCK1ihN+4nIH9aAWL6fj/jKAHy8TNGdMtnBog/bFsgYRGgPkA/m1
# DATA i2SqTTR2dehtzXuHfO9jNeMD9e5cA/32srTHCNU4tScjNRGjYb9bA4X56k2Cazk9BmTmQoH75vNWefprSv6HXaLsZuilpS0/dzAP
# DATA oGJXauZC2aZFYJu/Mq7wZvwbSoRtsWoFZwM1weGPDka9MxeNV/cUNWE1SM7JOTphtsrxnz3sdKhXAAQE3tLe063B4a0qvWdL8q7t
# DATA 549H6visgYMRGHbqGCRZgRdNuherpkFtGyjJ0LL1c5NVh5yHdW7Qn0K+0d8S0gXEs/4Oo+V+CZq4gGDvrQHzIJkkuAl2uCo1ESGG
# DATA EzqCEn0nWTELFbpWKcaoSkWQUyjOo2fPNh41fbmQU7Giv5WiQ9R+l0Pvbq/cTqrIwuKbLzzo2tYOJzyXadCdqVDDkFmBrU04t6Es
# DATA eCTzQZaNazeZUYZVp2jfjDiS8bdefDKFMWtlKa/mT17/o/r7P73+kk2hgDtJkCWhtLjFcMlfm8wUGoyfzJZvYf68JuSc+fr1/9WG
# DATA X//yzV9B0KefOwNGFwd0tEVOVy53GWvs1yZ49fMxYATU0slRbjN+wS+gr5z/ua111LGnesbPmmSPwj8dnS8+Aa2kDQkKVKx7GQc6
# DATA bqqvrsJMm2PtoQ2yYBVg+GkQMxdma2sNE9XQzCHUnsl9MsmRg+pE6s21ydEMts9TfFMT8m270+mNup1OIr5sgmdgyp/UYtOzGBwc
# DATA RuD30d7TliFjGNKw9dJ6r033YjSYcPdwZNCxQg2qmyKA39URebn9lHIOKk6vxLieNC+Gv7WSitNdJ0dgPSTUVndJSWANI3XaeheN
# DATA namuHC6HjRPqma27DGF3gbrQNyW5V1aG4Wm5WFVt6q6uL7IxZPfEPRPTBXyqlsKz3+lQr6Os0Ufx3OKTwm6NPcMCWw2cRGzBboBQ
# DATA aYMeYPejRy6WxX+gdF5LHIoxHLlghDXvoAHJ1dsY+CGRjEq8bm4yIzLsTI+LwI04PQEEbm4vEvs0okYqiJ3upARI7IM/LIOq4yd0
# DATA x3THwL9pEfgHXz35l40S4wcGjUH+pmBg/C2RjYsI65gR2Jv7pJzUURiaJh+SZEhSIsiHhIUgldZhdzgdOCzMsQl79LY0LTFqjNAF
# DATA jDJ01WLFsVVXEs5Q/HB7fW1X5yPefvTJtp+buE6ZkWwzOjH4YQ8bkEly49MYrwbQgisA4Wiah/CiBv+p85PHWw+/21n/1BU7XW4Z
# DATA CAelXYISfm92Ms4l4Z+7abSKApKV5+CJnebdfr/N/pRgjhpO2zcTYEBqYTvoOtfp4H7tdGC/dTqx9UPN+0fD2QkuOPyZDpo7Gx/t
# DATA rm8/qUf298fPnkovLXpO/9SoApOS70ZHXfPRta8/renLiSPoEEeUcklNiqNGRv1udkaiaEAqJ/Fr50xR4ZP1V/2psNd6uGgZVVbT
# DATA AtJDdmDHfc4teWJcosPmXv+dFVXNZcTIrQWXiaD73hyXPUTp+QnmVQfp93MNCPIrTLP+BULufWOR/52kkx8dqKMyPvvGV/Y/SFh/
# DATA 9/Zt/Ff9z/v31q3b79/Vz/j5++/fvfuNaOUbX8P/ZuAhq5r8xr/O/33z2vIsnywf9IfL2fBlND5TrGN4a+n69evbWdpTWxy3h7qW
# DATA rj3dILgi9F/Gy2oeTY8no9nRcShmSJVvqlqWmKxr0VX/BlMKHCw4pL2pfqpuq3hl5J/q5nKs7pj6JxA+/fcoX0L/Crh7qCKae4Bw
# DATA qYtMTGOKsOg/oU39t7zBes+cvrrKKfN01u9RH5hG6D7gXUoRNnVBVLS0O1ADiowJkS585jZlJHw1aL56mjTArPtXjPJkDIlV+j31
# DATA QuY8IW8L5HkcVWP9s5ekR2N1PmMMJVWkN5/2+sNmP0+n07Na0SfMHUH8hPweIxHPo6qd9MErm8TH0RDTO6WEV3yiv29FrvDHXeKl
# DATA b/K/NRo2kmUaORHX/nA8m+qXZno3R9sZaYV9TSLoEvQ7Vijy0Cj8gt50uHgNRHS8nChGPQYNP8hNJ/mRmn51HNSWr0NyN9XG3PmB
# DATA hk396o8fYO75e3Bw8LgcUnQNqnQgoskOZm3ctz3sdPrD/rTT4Z6RPnL0Qm2E2AEqsfpVuiGa8DLoq+PPzPmdtU/gOSl6DW7AhdEk
# DATA 2Xg0MDe5Ka/dhNeUFZr+1Fmhg05y3hw9U89SOwcoYo1mU5kKux6ZunXNcXg87bZGdUBNve29GejqzfebK+r/rcJgMYMwlIEfrdZq
# DATA fLFIj7ezk9GUaV2uL7HkkE9Lm0aUmnhn5+NoOhvCyOAwQIlYRtQMDpu4lvgXLiitoMnqvAyiKr5wv+J9iN5enzY+HE1O00kv6zWe
# DATA TkbgYBfZ5ZRv1V/wzs7ABc2dTeqwwAQxXPiF26GF9PvigIKEac+fPHYGlQE1BKArZudXSP+mBVX2t3YCozBhjJgX8EkcY4SjiFRc
# DATA ZtedGzfkPF44SKNmMdy9wGX34jVK9vgjDgwHndoHmbqxTZCm2c/9nLK+bynq6ktzEfJHNf9As3srfIx0EaaF1kRcCfBt0uSySXgc
# DATA DykJcWOX4VTdiXrVOD09xZx7DdMq4RnbFosz61inIeG2otCwrSYQJFi7JQBL4KR+tL7LBsTVZAGvULVRijtsW+wemB8wVOHWgQls
# DATA w38M2W4b8u0ggBTV/njLE/uabpPIELQZ6PY8O5Cb7dq1wty6qW0wwhRTZokB7FeuKIkeRP638wwkPvECEU73BnKQqrvX5CgrcWpi
# DATA tuwkd6SehFxmL2UXMT5TJEEEDRpVhjH3OMkavf3l1Qw07vbNb9ejOys34T+34D+3L7CY3rD3o5vhpqX1QtEQ/UFSuvqFQO15C4Ob
# DATA OTpM+4Os10KOEWlnUTuIRMZqBRaiFjTL1KNd2rwhI03F5P3eZ0V9MsxQSckTcw8sZeAjcKKKdqOnWzu7sCvQu84PYoPOqdvdyZhC
# DATA aqz9oZiruYbB44dqo0+dhG465Xpv2tQ3FoSi86quQwF49iPVenM27Ya0N6WV9fMRJTilypo613z8fWC9762stFZWPAd7qqs5/REo
# DATA 38NhSqY5LqtrpW/awQ47Odmbaa5L1PzSTdvnxPaXu6o6/X1hShu+zCZKDs3BXzb/4SztgUw3mqaU/BHQMdL+kFTtxo0Wbn4Oi+fc
# DATA jlALGY21OCrQFfguM1GzOhsMEJy6Non31hrfTxs/Wml8u9PYP79Vv3X3IqZk2nNl+Gda5O2NMmLWh/0pSu89i/Md0Tx4G3OSqQ8x
# DATA uEbkfO2cpGMUUOhOBALK2sPdje+to2Zd3bzU3Qn8ZOJHGztrHzxef4RyWP9E3Sfx8eONJxu79DR7NQbzCTxd//TpxjY9HQ07x5Q9
# DATA yFZh8vnYuWOPDQOeb3s3d0aGL4aj06HWC0S6piVCojgBQELVTg8TJ9OiszeS4sYdLECwYytJ3SsBn3Wmk/TwsN/VZeSyrkT329QE
# DATA /PHtlZX3V7/97Zt3br9/e+Xb317VtxYshT0IFJo3uo0henlG3Au1d2dwg83NIoI/7dEZymaBkXVg9047uhgNIh6O6HmcNGfjsZKF
# DATA LSSWrs/cUDa3OtvrO4r6qrV8tPYZ/PPJ+vp34d8nW5u7H8Mfn62vbcvLStlC5aq10QR8krH5yHaL3GTSCRw6DJjfL/QIuAA2JK2V
# DATA ZvS2n/dMPRrNGz+LDrLuCKLxTUF5DDh3Ee24PZjJPb0l9/flbrWPsUNmd1udvN/41mbn463Hj6D+szzSZ+AeGrpe0nEFvtZjRa65
# DATA wUEepuzU0hFLoMiIbGgU5WSE1ZZQGt/PJiPFQNNhHkFYKB5YxtKQpKIZrb86Tmc5Oop3u5R24UT9jqiBiA9407ngwmZ+0PYbNQdO
# DATA zeaq7y7C84x7ylIYTT4uwoFEuDCmUIWfMjXboHPm3J/0Frkm94jnYuUv2baeW5r0CFNj64/vWeSY6HA2neFSDcEMlUfoZ2r1SvJ6
# DATA Hdqq1mgF3a7YQ89ycMyhpC1KoIl+pBb3npKXp+paT108Sc8i1eqQeEE6QNCDKB+DwK9pR3qE3pdLDis+t2yrxc7BeovrFNeGtq/B
# DATA BdbKGXQe6FVMeScsDeLH2gBxUxG7xurNxq3V3Zu3Wne+rf7v+wUMiZh7+hhW8wMIk1TtMQl33u1owtEyEwtOAsjCNoA+DtPBDvB1
# DATA xAICcRWz5oEfUw35fZIUUK5iYbkCl2MzEkUKGZgyDnEu0j73Ouk0Lohpe/rtGjo1FuZOfCtyefURM8S2wM9imS1kJohpGzzCa1wq
# DATA iRpqTV8OIAISZ230AzKK58dpb3QKEZK5GIat5jLkewyane5o0BJngUUu1LoyIg9pn2U6cf5OSV2YXKSuY2wh7rBme02Gffz5TC0c
# DATA 6J1qYiha02cH+FQ/wZJyqF7xPLdFXVQF3TfN+ng+/fgN776gFd5cek/XQm5uNMrEzzMQiCys1mibvlk1pKtyFLm57Ky5LeieuqeB
# DATA riEyBIT7+C2UbdRtn0rAr1s3F+nzU91Xo491RFUppnIAi/oTRdVJxqnYXNLJR4mGCKeoYCooLFW4Z5ujqLiFpWZX5g8RUr+D/FKu
# DATA 1bayrPD76aj3mngkTYSrFOpUDYOn/txrrO77+6Ty2rB6t373NtwbVHPJIgsj44xJjav1fWmUH4OZCHYE6YwH2VHaPQs4h/IEFpcn
# DATA xipw32Fw5OygeH2rG85mXMowWw/fxMA2M+xlPR7NN6OHZmkiJRSpzTJFFaV21Iqyl2oMp8cZ1X+CmhvkwCmAQIEXEEgwfCHH+yNR
# DATA on426KGU6VzZ7MEpkhWXciA11aO1/LIeYmBlnGvfEEWGoKZeOSSJ3+h5ISuC3mbgZghSjX6LeNj+fRsnHy+tBtw5yL6BP2Ft9rWp
# DATA VxYpmO1s3Wpy+kdDZEfnuZpZ2gmuaiN3chHm5LaBkF3m8ASZOKJzXsgNBRzP9jD40T4SLd0tG3ejyU8HGq2l475z9dZkUj3XWt0a
# DATA ap8gsA4CDNDMvHxw1tB7B8MRHJoAIpmJk0oPMzCMWTOBBDqxpk/pg26spMW87kKXpJZF7cEO8Rgah0iueQBHS4eY5KhnRnkR7Dto
# DATA 2YEUvGTLgLm0PHp0eJhnQk2+Uo9WyQvCrVQDbM2dq+9QjW2tOaSfCCj0RyjcmTdUvcvYUMYNg97gK0LN3Ivxl5ulzXmBmxu/KMYA
# DATA QEGrwkFUGkjzsBhVxeln5wMNQ6ouc2iIxhW6R9pA/TCNEL0vUvfu/qgXeyF04FXL8KN73Jv9YkhmUeWUEGaabyYq7/ejGRlLMhbF
# DATA qGmM4ssRxwz6YPLGefGH2RDcJ2uhfiT3aC703QV+JH4mRSyBIcS4JG6fD5RQ/MJnhc6EQDdFNQ9CtZSpU7TXnx42rZHl/KLea4Xu
# DATA hStdxyr4DgpK7wyMU6zTQC92B2Kb/Zsa1LIO3z/nwbX0aeWN26I+XDgUA4toXLTZ0PNlx7g0coOcTcezaVk+uzJ7MnnDmC6jNgDW
# DATA 4ABsyaqegxF400BtcUmiYqdxRddGg5fa8GfKMp6EzE9ej9DHWQNX1SMfbKJ/KL6Xg0Lf2uFZTbxVvADqTxZRqapxqRt8BHaCM7jI
# DATA OBOgg8byZvdYdagmiKzoGm+nNvhK0PjpScd4O0jJVxRzOBLY34W7DQHNPny2s9tZe7rR2d367vomENdtnbgRfaDIPByZhGxaRdx2
# DATA qnqytv39D9Y2O8921rc3156g+kXrTNOeEp5UDcalRySjM2J8uLqnazs7n2xtP5LV6U+gT2JyjFMB/zQsAyQ0wzOwL8tY1BwLVk/o
# DATA P+WdrmVau2CrPPJXkAkgdLtDFRFfwKt/jnGzVgEWZFx9FiUa9AlAWVj2vBf3PUlDXkZgG1r5p93WPs30RQcrtIIP1Z/MVwPT51Te
# DATA 3qjwvEA9PZnl0zJ9NVZXTND3brGJsX/Iejt5/0cCWK1OlsqchYU9K7JqNoVtVAQvjtMzMNTWpWrXtb4EJocfWn2n9hbWdzJ1t4Br
# DATA mW/1pegId3VJxhMP6rpPQvbfLwAom8qk/KVh1/SlRRcyVSYL815BCXAqCfaLLP29/uFhhjBfdCO4h42O1JwBL1ESr8eN0a3cJK/m
# DATA ruCx4LmP9eSrh/pPGU7SCg5X4FRrO647DDf0Trs41yNw4Cj1dsbqcFPZLnsH3BcoKHM2plCK5vlGuz3UukdtQ2ESTdMaX5QyaImc
# DATA bNkynYiYeg+Thn+oJ7hRMVdjy9+5F1qpB3alQxYUWtG5FTIuQDpMe2fqobrBYkzlbO+6XpDrlOBoplEVoLjW7VJ6iq4ST+jTOZ+B
# DATA ok6x7WnOzVP3k4tYdhGVN+gVyGSD0mGoKlrG8G9z1xieTHXNo2FPJ5nqwdHx1NjNJUdU93USnpvRNlo+IrsMbuBKb3LWUUKPH4MQ
# DATA P1Krp56bQDgyzBMZLB4dN7TdBJWcKcIKYyanzvihdC1GY/70WB0S6Np3cKdH6gNgc2hfOAOFtd+th7BBB+XjhRgq0RmWPkAxz9ph
# DATA UGHvo1KUF1w/oGnEXzYdDCJD8LrLixoSA7CBUl4hJhP797QZO0AWy+m6RTqsprXWpTaAYhi81JW6W3kSVInwQIfVUuRCNUzL3L0Z
# DATA bu2b0Zr1TQL7ipJ/ByPFblnHFBksEvJAR0diwOkYdvsAA4042dGBElB7gzO6AzaDDTkhyW8/xeFp1tdezb34dRXzKj/KD3m8pM2G
# DATA cN8+7O9JBudvbM75dGTnIxjPDlvdWEFs+uXimFAtfYmu66rtmamsPOQyN59169u+YkPdzA4byY7m1w68UmjvlTBJPQA+4/tBdsmy
# DATA cIA9Cu4dYHCsDGUWR02VcsOdj9du3rm78+zJDvq1UGorDoNo5sepelkbe8imx9mrXv8IjieqeSJkHmPKi6h+Px/GZA5CCRj18eLm
# DATA djQYHdTiG0z6k8TloUSRe8zFeJqu8xa6vg+sTnJGWcg8p2Larc0pQw+hgOU6/lrMZXTpBHXWZP66F4npRr1Sjk3P1GOwvrPoxXxK
# DATA SX50TEc9PFRxMPr6SoHXxTBelIfAoTb2o5/vBYoLshP8pqQV9yq1UEukOVi0Aby6NODqouO50XNOTVqqpr29qm7ooUZQSitGREvf
# DATA L607tJWJ12XdUeJJg/DIQqHMoZ6coZmgNPC5+IG+CTX4JlT1tQ5kDsYww05bRS25eweER3dWVoT8oOOR7WS3otX//pP/5Q74AdJ9
# DATA 09gUA3c6k6qEA0nnBnTOi7O85F1EBGOi+/Af72xtPkL45dKrChGcq904zFNDZDBtA0mVKF+C3oa89JrCzCUIADavpGFA9lRVtDkc
# DATA SjWblMeOri4YYvkv+n9+aoyvP/7z/VsrKzfd+M/V1dVbt/4Q//n7jf/cOh1Go6ESpqcIYtTLoqNZOulFaK+4F73IsjFGOcEBUzwE
# DATA UQTQL+XM+kC9VAcSigcjQfGGx2mlRAgnPyEkAhOXqY7icKR/9MecdO7tI0OPB9kr+2M27Q/Mr2lqYj1tjhcTR5qdjIFULC3tgoth
# DATA pNP8gZ6Y4N5wtuKl7a2tXa2pJ7BQU66ByHEGjiNZerT+4dqzx7udrU8217c7/GW8PBpP7Ufx0rPNDa/GHIlSj/8ta6CpkZ+SpYdb
# DATA m7vbW487T7e3ADzPrW12eLosM7w1e36NsESTEfR4Z2N3/aq15CSwP1n7tAOfdz74bHd9B7wZbYSLeQnPleyLY+/srn+KExPHe8+G
# DATA /en+0iMhhlltPe5ZVkPhYiytwV2yPcymp6PJC2DsTXbl6QGU/URP0NIH6FHVPlFCSB8tz1xuaY8T4+0vAbNrq5se5HRbWn+VdXfA
# DATA X7BtDhMfpKhqxZexV4roagjUJfKFxG4Ci2krYWVpb4MAXPeXPkmBSX1wFuiYmgu9FusfbnwKs7NnZ2ITZgKDFPefQ5bVAWSV0I8U
# DATA FzyApXg+lNIsYRv0aBJNCdj6eTsWxrAbIGK4iZIw+spB0yQnAjeRE32HPJpDteDUcxXddAy+nh2STelhRZ5Mah3/K/M0aWmeF9yJ
# DATA AjEumYaWNPvjjlMSU0H1u1Npn7GhF3AD7b8aZIjoshIhtDa+6OcdXJ9umk/dxzPMNYk3Df9WI7Hs1iIu1uXQ2I2nUI+av2E2lS45
# DATA sWOmpNTv0FZiksupJQWjn6pEDSY/RpAXNesHk35PXRjrEcaK4tP2iglFJ5hIPRX4m2Vj+BotSniJBE8GU2kS/Tg6v3nzwjHt8psH
# DATA 0d3b2mYIV4baONHK7z6lzzSi8Rj+c/fOnVt37J2VaqmaMa1zBnaEpV0LMw8XOrJ681u6J9U+X80WeH3VV++A09cBpeY9gN7oyhbp
# DATA zyMkK/yJ9sxMT/oD9Ezuj+9iUGXciskLwWJn9sexa+c8jM/pw4soh/0anWPxC3Ajh1BXFuPJtbwd1eJ+/xAVAOeoDYDrFekSZKSo
# DATA GJVYUj1AykIVmSZQJueXOj+48XOCVbWbKbS8GJhhi5h1XmQeiU4J1wEmSDgx0+446mGV57Z602vED7Ctyn7zuTlUtJN8MPpwvs6R
# DATA n19E5+dL4Kuj6jkh6Fb1BMeJxTrMKu5Fh4NU3fmY6NyLLi6WIkwLztcPqIY+U9ICaDKPRyN9NVG3jtEE3OwaqyvqqgqG/jPu9z31
# DATA lV7C64PRdX6snnanBk+aJqc3GY3V83PaK6CbFjNyHp3btT9Jx3DFqvOJSi5Ub23F9qt/a8ds3p7zlF/ILmTovNLPj7NeXafz7Wpj
# DATA PoVXgDhoKjnJpmk0uI3eoIrwvrzb6HdP1BlX/3l5l2ZJ9XjYawyz/tHxwWjSyGFSwCNdPkx7YNPEZxM16Zl+AsNRh0pN8ZjcQ27e
# DATA uXPZxh29y3CSpWoxMc/gOIVsN43paNQ46B8Rm2lo/xPMJa3WCvqiGlAfnDhzS2tk98YhBeaX7A79ds7+WGAnXHmlzpmWXMjOq/8D
# DATA OcNAO3ZB72rUZMwcgAkssfe2Dt0sQJTEilJ3lBC6uf5wd2Nrk2L42D/XId22EnRguk0QNOYh+PEqztrrH8GHQp0AnUGvKVAruOVD
# DATA 2FJABxFZGBzxlHASoxyXgyCnOByl5NyFHk57asNRR6F8OEG1w1PwRD3vvRdjouNg4kyns1BIz8Se6W0BibU866TjMci2Dk22bawX
# DATA embgUEn2pVyjyPIx6JDR/GlbYnjipK9Wu828DF7+0JsQu3J96Vor7WQSnLi0bU7JDVANqiLdhjdxlBUsZxsbbaotzuokQzesnxvO
# DATA gNbs8+cG5r7JNwDuRpOKN9nbz8vg5P1PD2MFmQ2Z/DbRpoe6Np4xZj0HE8Q+pFIbvXh/r7V6U6+yluSIGROVNtKaEeoo7zWyLDWL
# DATA AyOLCKcMnNzh4ZTiRwnCAz+g+c3gAfI5Lbm7Iq6uqUkdwuB5TORSVm0euxWJD33+vk1gSdq2lQ5JTsAlj1TdVJ0+o+kwTzUNqR3G
# DATA vQy9CYvs+jnB1Ic6juI5830QaXDKjIZUD6fRxf8e4n9jvsSI9pPiFxVlOaMfsNHT/rA3Oq0BjAT/bTzu15CJ9MyoVS8poqc7GEEQ
# DATA HHrcq1E9VLztYISSFOhiAJMl4hMfdSepIup509xOrrbywQWrqm6hFb/aqouToCZpcxSNTsHTnbRPfXDkwvsw2EDVjZE8tfSVOlf8
# DATA rg/woIBBWTkpOU6FNyWxkXzixeYHvYXs0oYiAkSY6LPx0STFsxRRCiceEzoQgKOYBkCiQ45OQtOcdmyk08Y1JXhz2W6suSiUkE0m
# DATA IkdzIeJeWrR9LlBeqF61FiB4QQ/duknCrZApZV1J8XTRScdIdzoUcxYrRjn3Wwg+cBGHyVpwoWSjapau1iLPEfy5eueE+qCpgITW
# DATA Zr0Ce9oCvKjxI8ZopSrXYXkx2s4OZ4SdEnF5fbvs1VE1OZqk6CCs1ZTNkxegGhyD5beNTZErMEIuHPZfteMm7sVGCGLcQz497FnE
# DATA U6jbQzyF1mjMpG8xb41Pr+kgzYRTwqBU2DIWXhwx0wZnzgkc5RToxck8zXe+vJDrhL22hE5KC4i4nN3SXhUReA+NQVdQatpl/bpv
# DATA xqqHoKFBTXbz9LivZNBYPXMRMtSD0pzbNOiCv7d+Ttum8JoDA70i6BIe+BroWA0Eu85MjeEaXg+UJJapX3PKY0T+H0Uro5WbN6vm
# DATA 59kQQoGiZx9+Eon10vXK0ENqSKeCFWZQdV1kIC5diLrhk3942tzpbOxsr39U01/pvuJo5MOSAfvfFcf4FuOkI/5V64RRyqZQZDtl
# DATA 6KkCil1KvOtPN3k8OtMLM2Cs4qs3vdy8ZXXUdBC063/l3sXUN3k3Bf0jTggKg/HeSuPboOm7c7GsuNVzcCWgupJKCgwzzj3B/B2z
# DATA 4QnPDjkq5SFC6uiiPFgE4hJUo6bK7AQqycd7Ucz9TPxcXzV1rAm9HxjQbKyz1YXWvPxrSMKywFfoI2YnPQxkZ6sVaectZ1+0LQ7V
# DATA x1VnIr5Ifgqng8XOVZ7+r2AEpaMIe8V5G4L35Dtac5mjg415Jr8zWQvYUnAlHmjMg+BTdDJ6mTlITlflUIwU3rLE4HKmClZ6Frxx
# DATA hKFC/br5tRgqkILyNPkWi///cWAzUIcrGV5h1lPdiTp6Taso/r80Ju2/Q/b1ALjXJdh3eJLmMVXhtaVYHIK9OdrH5z7Hf0jNPHeZ
# DATA PjfusvunuBRsgqoBn0wbh2uND5ut5f33Es34a5aB1r7TqttfyXcSn6P6q4K9nDtHxcmp5Lj+TtLUARsDjaqLowf0iUQI+9G1NtMW
# DATA uHMTBQHbCXo6UjU39zWaRB28ZvEL7/QvPpqDbDCCcK3pSHVkND3GcC/UccgQM0VzQYQLr2dsIXXVVdwEngXIr8M4btT2AoxtX8wM
# DATA il97kCHWMjtwr4ktqkw8HSEvHJ7FhhWp/yYC5Re9G+TBnct8cRjMi3gUbkrtOdzd47QMB6CDXb8yxmvG7YzD7KywTEjjK0gn86Sr
# DATA YvUlUzVX+nCxQ9ATRd6wzblAV6/CKWktXbpH3hwfxnvnauYuLkuU2Ahu7iBo6S4xdgYl5wUX0m7GhfKi6e3uiVuBWWYJbJClw9m4
# DATA M8bkzIRgrB30nbML77SXlZN6joL2SYGUHuSjwUxNLwHhNJvsXUA6n2lewbQPNUPiHuFXLZjm6fGFQJbqqo2AybARSurGBGJv8ozS
# DATA 4bHEAIYL+LlfEbCK2KVtW1tz4DFvnmdIebs5mn4IHoaBEKICTBQD4CG/f7z53Rq0Y3j9HAJdmAIWstQsmH5eSDgolLFMQL6dGTwd
# DATA oDeb2MWUPTS9YmFjJWRlcrpuxA0dG1srtobRdLJLFF7nVGLm5nu7nyZJuFm/CkeGerSx7c5puBLC/fAqqhWkMacmmC79AKkUjGxV
# DATA PmXhyvUaTJJLrytyXrk4oRXm4wpT651VBPOms0qwKl6HnANbOOABPhDOYoUNcI6qrc3Hn/lZquzvzQ8gp5RDnyrOjQ+kXZXcanIQ
# DATA 0vXy4YVv8NQiZ4H/DEe1pFr+Ll1xcRSi4M5fdHcEsDIX2xEesRNo/EbyrpFviYPbzt4KUDRZuPmHcicaOHavB7xQeLXoYQyFui1P
# DATA DxvfsgDLvLm6x/1Bb8KbhvdfJWexLFlykKI4xl1gzwHdjPUl0Hsnx+MzofYxxkPxbwcpDngHPESgrcJb6fbBjSQAfGp8gMvCBp1Z
# DATA 3VUTqS4GZ86y5oF1NYPRHBV71nSTmRYmEb+Qs0hf8VX7cAQysr6Y58y8A21OMgMjgL+dxdYlfPFACTI+kjlqKRg0sMSyQNhWlzEq
# DATA GO5vzQpO3iC3W2iUrIU2HDiwhzccnymHmKK7+zLhu2U6XHL17q1v3bZwNPBZQdz3aRl0bpz2Jzmmi89DcO7COYRB4eoaA2yIvhnF
# DATA bcnwcFTFAjtRYD6RlZccsRAPwde+EqgfQMo5gIsFSD+DoZy5ib7Jf3p0ADmGOjj0DjiStfFP54hLeLgpZtFFiLhFdoUYhe94rB7x
# DATA pkBTPYn+Nfh70oGMhHa/or3cPK9qlgT9gRqG2ons8ZxHjQZ+TQllGSrolNLPgKbc2X54qEUnmlYyLuxKi5uUOJPsbfIlIV46xgba
# DATA tOhNhC1uY/9QiQQ/C5vVdUHVKgqsRee23U8Mit407R53GPdYjAjVs7DmV5nfbaqOa6+c4eLe4XbRQz4JG1viPfKk3t+zKJor9bs3
# DATA L2K/29Xbjoetv/EW/R0sOClXuojLQNUuk6E/Vn9wq7QnUCSCaGAojJHdqmvN/DguSnNGZ+eQOKrBoWosqj0b9k18ZAHUQi8Vd0AH
# DATA pPZaUgdGyVlKMTfKdCWiFDo0qi5TUenkCLFeilXlMjJYd4J0Uot3UHeoBnweq8djcitiF8x8r3UT8QP3Yi827SDNj58P2XcnamSz
# DATA 50NEp3NoKWxEqgZUdIjhDfIJQGRn3Sg2m9WUgXFRCdAMJIGUvDSW4MQCKAXcatqmvr07LY0t62wIRMZCiwREnLHykD+3VatXRMuo
# DATA EPxXFwJFRt5/xQEy49mwO50RTEX3OJ3k7fjeH/34/oNaEnu1gYllmuVj8BnEVlX1UIdXClrJMNkBRlY5N1VwmaphMYbpw6GwncQ/
# DATA 9dyNfXB4xZLz3CddlEn1gbNs32Q833+DWgzCNIPf/975vWj90OHRBGSuFPISwoDuQ1olVGroZ6Ziio9g8F5+lvs3zdJt4m0VPuiW
# DATA xF1yp7EPIPE5Q6fUtWGQL/NLPCn8tyXd1G08VW11qvh9ncmXA7BgmzMuA3uxH9KGfmYbMdL+miaFs8PTjo5mQxQpk/PddJeegmuW
# DATA 3wO/p2iRIxM9UgL6+3LzBfIPJYPDCP4G/GbQDt1n+LcB110g4dQ7dcSmpUXRKxPLanBcnbggNK00qGEvg1kUI6Ir03EfHebg7X18
# DATA y5ur5cKx4nxgsX3YgTQoUunAp++BLVJ+ju/kZ1AE1x0/3XNq9KFOqXw7ulmhHDdj1rcXp8YkXOGqXuAKZgjrTIyn2mHYYzUeBiwJ
# DATA Mw4aqG4mzE0MJyH2AA4XSHpRhWwGmzCOioNBycx5C51TJ263qB/qOUYim4zypxOYtQmukuaLuDCFyzyeGC2iS4kvHffJE6T11Qm/
# DATA 0wnEuvQ6tvKQcGtOrVM6aK0olCrKxT7KtVqwj2YUBGOECdM4oDsjwxFJPUzFxSDqMI42JEQh4PWjYEMAUM6CvhGO/VBsjZTGi2Ju
# DATA BHgM/XkJ3lqv3JV0CKhxGB2F+BZ4Wdcditl28hRdC3SKp8wLkNFLu+cWLyDjS8Gf3EIQsFkDA5soT+M74Wgsxgm54HtuEvpr4ZoB
# DATA q2crnGdJFcmaYJ4jZwyOak4ujwMwWaOmKNWdLqQzUpheoso6UBA0lQW985wtrFfKgoqS4T44iLIxhHK9YbMkGzJJoq3ESwGwk0q4
# DATA kUcI2r1nOzQidLV4KVhnLVRpXHn8kXuUCGbudjd9ZOAfPsviEGE36cRfku783uatdAvIJTY5MJFP0MU77yqZRCtaloq9DE+dS5kQ
# DATA uOMe2GqZbIDDxHDkbS9PvUjW2FxzHeF1qEPmT0YvATbHaH4Jq0s84KBch89LiIg6OMXoi++YsC/broJTMBvsAfQVGG+SOIoXF6jf
# DATA 9tVoaPrTrHRTmLZhi1Gf25GET+Csm1xM2o4L4hBOiZaGvMHW5jkIJkmlrMWRgZyXin292WlE7CgzHC1TwHfLOgNtry+QdOOiCqs4
# DATA Q9o/xVtIDzRErKUW7/i7Uo8Fh+vo2DuxIzHzhIdp7Drx+BoyF22SpqFj+1+LS/yfSjwN4rkXycP4Et4Ic2sreis4sX9Jub8vONAY
# DATA lmQG3C5MQgit0duzhXWtFVx92Jcj5OlT5pCUJAvhPnp7/KHnGiV2uWYFNNvL+F3lJjeqcxqvxl7Mfbo3SIelNE8TxbqgdQsQzCUd
# DATA CeOnVxRq44IoyA0VmnQMK8bKB4ItG1Mmo3EfdUuAjtMEvQlivdXwp4aBbPZkajCwSyshp1Ar1yVdLMOOhRBEftZwvAIb4BXYBOjj
# DATA mHw/mi76p3T6i7gTxkd1nksH+L5pD75yjxKGcvFhXfjPWn9sc9U2EBeBUC3UDzT8jImb9McFF5SQ2qbM98TWhjKm7gf4yEBsxjUI
# DATA YweT9Rj+RC0DlRCJdJsUzJfMmxZcBTVatp0d8rKc98cXTYhpWyqmI3dIOhavR7dXvn1XDtlw5sPYIB49HxqUo6ejnJGOMEJeNRQ1
# DATA DquRjtx+SUJbxEPxJ0xRtbseLop2ygISP6mIQqx9p4WBiD9mSIUk8mFUbFCIWvWLqMgAJhJh5PbtWxy+GLHCNLo+6Ta6qapCDder
# DATA raGKX3coNxjkFG1+mU76Ka5GbW4Ipdom3FWel4vI7U8VzzqMDQIEJq9i+y6lta0ciVqpYvcx92/H7iU4Rfq+xNtdv/SvWg75iNW6
# DATA xByKDbQpOV+to2FIp5j3m7QTFtgcBAoBFGLecXJ62G57y+EkA5PNuofQnwRHmd4Pegjh+ZLcGTviVFQMosybEN2smOIeVYJHqJg9
# DATA oaKnAQYLTi8n6QT4KHgiE/1Abo98weyxFuwsXw2RH6tJ7lLs9kFmoKjjSwixh0pcgCaJN1YZiqg/ahvqwMZhv0C+gMH5PgJUjngh
# DATA IsUJ9xOcVe4JvE9ETlj4LCi4+iIKQM5FvnBSZog7zgZjx1DpuDpYjbnuPZcvu7jU6L1rIQkiOD4ffgUQjkAMoHBhl12vBkFUnUH1
# DATA NQ0uWMElYBKd2pLQweGlKpnmBW9b1NkF1jjYpvBicaTRUiFvaenfesiXUkgdjLomJJwRKA+7w+mADLfqZYddDXX78CwuuuSYoiZL
# DATA UtHp0JRhz8OH2+tru9rRcPvRJ9vznBBBTX5Xq8ldZ3fPadC2//v2GHTdNy/rOghTBtjmeuaknxmuU/MQV1D6VdJzmK/O+qe2+Bk4
# DATA CIWj3SGAHmxQzrSFlTgdcrvXLva56yGinwZNf1eIzyuH+OAoEn1wRNRs3sKW+hDIY4iMd0Wpa6ko1OPKyMwb8KGUu9RVw4Q90JQp
# DATA ik9BNrWQfaVN2RoDAImX8rLRPp5V7jVXttssVei3hTZHateM+Wip8Mq/vl7GBeoSKlc2m22OpENZUc1aFDPuWZf8F31FbItedA7a
# DATA SqdefXmHW7+/xklx0srOk++jc0+D7O0VhjYqqpXNEGCnUt/2k6AdGz+u20Q1ixsI/c3a8w3oMhWF721QrRuxbr8h/jRv81RvoIo9
# DATA UjWRlXvhLSexfCLLJzPQizLW7+/Kkvl2w+ZyG5ZRpNQLIzBdjTxzT1C9VBa9N6zFhEbdnQ6QMvdzjULVUAIdKhfn41QL4UyAnsXx
# DATA VQ6q1HuB02sTdJsvsrO8JjlkiGOUBg8Ghpmq5ocNda+ChE9u4zYQRvWgNk9XV/c6FMzTZPO4TE5QjbYUSL/EmIEluW9kVrEmoqzr
# DATA G30NfzXXN7fWN3frkfm1u/7k6e5n5sH6pxs7u1UJjcpJJR0Az/JGC6jIPUXCGucJQsEyKRt0Qi+XgjLwGqB/6ehRycLrBu2AdPTE
# DATA AOzJl7DVFegCar5Azi7E4KP07wCTVFoAqHghFB+FWe+VlGnnAJOQZEpz6adVxVopFazN9uolgjX+nS/7o1neCbibBy85Miodlarh
# DATA UmZyUKF3bqBC7aJgoLtsvMxQJExO/KV2v8C6nVfWWQbXuaQN692CgKSRdiuhb5zaQdFUkNU8PxoXbRuSixnM1CWtwUQYTgenuxyj
# DATA 212Zt4R5BAKH1onCLbkeBUMxgELtFywIWI0b110OZLbAjhXYByMMzTmnGFSs1UcTkvFKFiio2D/tr0f5eqx5sIAo4kdmO3vI1xf4
# DATA tYWBVJwq/AjowNzjpup0YB46HfdUlXzsrJLA9z5nM2nLmO/y/JjOT0vvMmFjb0US/Mw9by13GOq1PSotcUYuCp0kFZ1Rxl2FdxZL
# DATA ZkO9ya8qQhBuqnTMDQRyF1iut+aC3Rbu6u411mjFEfixiRFGIbgh3nKVCRsXlk6qLa8iDF920Zdg5aRpysOIvCSN8qMywFVfXa2G
# DATA v4eUpHyAlcLjvAUPULpFd1zJpxIryckLhyngrpQcDt97icYIOtbJjoZiDA0a9x2PX3EQhCrQ+ouYj2OvQecd9SDgf9pgr1T6DnhM
# DATA XBduz+YHKpUwrqI/FY0YHKf9im43uNHKIkhYGmPy5CkmjVup/FjdxfxPIbFbuHB/iErswgdVDRQUMmUDdSKQdKo3KhvK94aZ2TR6
# DATA cdssQfEajtyfsm4Tod67eRNTgHMubiEBlIX3OFBFIEO2yvOWxdsszXh5RAJdlttKwoqTZCyD/fBLIQu5EkEBJYRd+K1IXRyS3xdv
# DATA T8vIeSc+zuuJyWdOIWcLNAZXH/d08aFzvfOLy4uFyEfU7YPjF0zfVerI5mlP5mtQ3okWJaDD0Du/6cjSJSJ00RM7eUt3MHfuGHNp
# DATA b2XfSxfoeCkjxCS2hDxpxVRoFcDhLaPbKZ7CBXesR0YtbkflzSiMzOrbfAA9/LD/CkIPVI8btKgCauPlCCD+QS23jLbKiWLjeZR2
# DATA J6PcImhPLG544T77NdwxdbOXvgFfuW8wH8LS5RjLFrV2OdYtDzcDKioDR5Z2IIY9CluAAjuJJIGwM+UeBa6DsGlC2GuhDcy8UeMQ
# DATA H+ri1mgA0ZT2MmQOHWpTJH/yzoO5s5YyATSxzzkeYRJ4KbWDTyBNonlBrSqDtc2t3h+JuNpjkINDh1hfVknGWotQVu31eOV0fLKy
# DATA ajuemCUoKHF4y9FQvRuu64xbDweTVGCSBctbh8nL3XbxeTJny6GA6200gf5dSue1+8WChPvdbeJSza89mP4qVA5iPnpZ2dyU++Uv
# DATA oPktOf90q3nXB3+e2q1EI0BieGFPewCyGBqARYwyZT9JhLqufJ4q9iaKnGUXM29jyawiBT5hqlgg6zMnev7GH/73r/h/6KUF5/wr
# DATA yv08N//z6srq+6t3vPzPKzffv/OH/M9fx//8pMz6dz69XH7mLqha8mC25uM0h0TM5uf0ZHDJvM316Olskj0F/IuSNM5ZV4lTeTB1
# DATA 85l5PFPXC0UWH67trj3e+qjzdG33Yy1qWYW7NcnG5mx0lOiVDkZH5EMIrmK6Dp2z+CYnLJZ5i5+sbW58uL6zaxMbg6MqvgIT6uM1
# DATA enqXHmHkmE51fPd2MS0yJEMQtaPZdWPzI/ONeu++0B/evR3onCn1aP0pTsO3lnZ2VY86m2tP0JGzadKZEMNd+uOtZ9uba48DBRoi
# DATA 9xUXxktNoCpyS9xef7i+8XTXFLA1HaTdF7MxV7L1+FFnZ/fZB4BJE9+/1hvhJsMN9OA+/DcapMOj9vVseP3BfUzviFAo2bR9HSHy
# DATA 1FMM8nrAMQz3l+nn/bF+Apcf6+F6f3n84P4yVg8RChuP1jd3Nz7cWN+m8Jfu6GTcB0kBoY00rhHCGt1+/+L599XW+Hj900DZQ8TE
# DATA vnubyuxufXd9s7TUrZtUav3T3fXNnY2tzR0EsWhCrzBipZvnlNGT/slfHuG/01dTfoyCcdx8xeVPswN1VPuHStiKL9Tu7w7SPI92
# DATA 1GTThdnenY1eO9chUp0ijJoPoTYXPq0aOo2Vk6Y38aNnTx9vPISN+Mc7W5ud765/5thwwkBpLkga9x1mghAZW0HbntAXEX7awdm0
# DATA 4AbCQHVB+EUvfGsBPLaOAGTTGR0l8hNfaGDkjzLxdDvrzjDcgdYp4MlRmMeNze+tPd54hLOo7rZIWfEbPT1I4jw0QS/Y32bBTpzc
# DATA BxCjz5iD6tfqt1BdEz9/jmFP+KKiY882d9Y+XO+s7eys7yIJjhMH21gSeplBCq5fYYhjuLQT5uQ1jXaokQkM6DHAE9zxgYLmZoHe
# DATA lwmh8aB/G/NBQ5VBWCN4AZNwTiEnzWZ8QZFuk6kAmmqGU0p63ah9p6VY7Y/Hk+GP09mrHw9ngx8rerG3qrr148F4in8kqtDzZvNG
# DATA 8h3uFdy2mxvFK9kh98KFgk5MGF4+Ozzsv1Lb9xSuSVqjYYlQcoUVDWBGdnojvHVcet85y8p770F0886tBY7Ao60naxuboXw8hphh
# DATA jc0J5Hsf4/qo1aLD3u8NU/VTn/007/b76jdPVBmE22VOqO6ePKMSI41zutNwq5KX855VW0KyprurF/oN7hLF6qTNpTx0DCYbylrS
# DATA rVMeNOMkSS478UEaDaraAi6t44P1DgDP9SaHO7Cpqal22rGTLLdsX1NIv93W/6MDoMN0HClhaarIJrwAu++UxF941j9QU5mjxgLU
# DATA 7a9ur6zMYdk4QTufPXm8sfld10M0jE9ejSU+pzG5KGubD5V4vbXtNlob5eRICSoPxMwjy0t5k0FHvUrk9SpE9UVm65PtDfTLKhmC
# DATA nbe2mDfhP5pj1OHbzyZ2ZnNrt6M+XH+o+vHZpTuC3hJXh3ZfuIeqvmeP17bxulOKzt4hu5NAwGYKIimNVUQXjrI5yBxzeUMe6P2k
# DATA kPrVntywErhzkr7ILAK+BexHJLE7d8pPCxIqW32BWmHtOChRpx1ZaGrcrtAAxSZBU1aHxmoxvOm35+A3KXVQwvkSxj83v2fRE0md
# DATA VbtkeGw5Oyr8B5lC57DXphapnuJK8vh8RP7yDSAcfCjFbduD2NfkcQSebtbyR0Sx8PqDjc01dXDgZcgm2BFI/thcIjD1lcSRpScB
# DATA 3FgTIkclFkTW19Ct4sjZR278m30+DzPfP42olXi88WRjt4iSz70tw8lPD6fZZO7oQmj66F5t+9wfjureEOTvEwh16AwJWraGrZqv
# DATA zC/6yPw031SIBDj+hx+vbX60/qgI0F8Sw+mcqZa3iU0eXscsrlnYNcPCWm6AoGulFabE8IbGX4bG+xbtpcr8E0x79OYtStGhuwXk
# DATA jEPha2+15eFMasx92wZcW7Byc+BDcaGlEZDOfV2OAlsKCVyV8adaPXBF/l8GDX8ZEYCW2Hbu0uGgBZoTyDn9Tuh9RdYS0W4yP5Kl
# DATA hD5fzmY5d3sULZPyCLvzLd44x4GYFJ2zgmtIkG3xmoBuSGuSayGl1Dg9gzLArQhwSyiqnTjQgga6Ou3LIrdRomxc55ONnZ2NzY+K
# DATA d1Knuwx71db99hVkFn/j+YRwu10sFJOVWDcLuir4XWBx2JAEPdAJfFk7wAVcKG9K3ocvEPCEnwL/m8Pl9P3VmZNH6l+Jra2KT9IB
# DATA phiFNvYExK9BAGc0HUDUQAstmFXIVbTG3/O5jLOX6SBOKoA3bTXNg1HvrI5VPRzha4LixFQgXrGmmxpEcdt3MHTgbzwWHkUHuu+3
# DATA 7eVZHE9q8CGBfNJn76Avk/QUs9y/mhqNjVTPhpWsO2fDafoqqFtVfFhN4+XVrIE+BvQ5qM5JTxPGG3CO8KJnUwpeLHSRqhsqLlGo
# DATA kT4aM33gqcimLFxdA9tC3j3OTlLt/52TyhJ3ExTa0+/3/Qwz7lvvYC00U1qEGp3mrGTf4z7sl4wEigr4WUclDe9QI+1Y2K7YpYCZ
# DATA Q9WPd0TVjAvKUuyjN9nqCc91v4cxWmCGIj99EyKAaHsQiIrzX+BaxTb2oLJ9V01qTVZSNajLYjHzy+r1Qu1pJaPXJphevKwf/LRJ
# DATA ylOD66ufw2Y/SV/1T2YnZUD9EpXfA+TnCeeajLFJVwjat5qZzlUl2wB6oTurt+6uJPtJcgViI+N3GcsPZ4+WqQommQO8zSaA17f0
# DATA PqVwY71Rrd33Mj3ED5z44kEPEdtgu7lhxySviAgkwqsJxiCRVciF7dMjVA+bXSV/QVMQfzfUjfL4xPC5MbtR4uevVlZQLav7wbuE
# DATA f/rEO5mDyHL5CdLYfOfnpJW+uHC6owV7HKWw1KDZNVlUpqeqO4rwPFz/eOvxo/XtDoBrrn+66/WEZg4iTGrevLqqzBgx9KkX2ihD
# DATA WxEm9fbK7fCrIPU4j9OD0WxqLMn4a1k0cNHsYwKQDA35vE0X0s9tr/+7Z+py+UhJqh+t71jx0cFfyXl3emH54Ak3BC9G0AGhvGzC
# DATA Ns32dZ/o+8jQMxbittXKOtKB2zrhJt2MFxoNiNtq3R4/3gDTV9H8bCjoPhGEUvOGJ+vrPHrnioS1DFXTRI18ACv4Q3IhuZB3myBB
# DATA T53nfasOQ39GYkZodStY8GHCWvoIWGldHJE6OltoTEOqph79cDaasj9vYkhD4dDYKOxMYOtV0CV2tZQkVlMpzrjBe8XYAOeTDdct
# DATA ns1Yeq6IP89Oqiqs/v4Kctz2+ibQBSnGhfYOLR96H5l5V3OhlmiqFbb0GOQ/tqryMkuZytsmBjuda9KEw5VpAkaX725ufbJJlFVL
# DATA Vm7nxX7L93T1+2brGYPf2bArFWFC19UO6LoW01FUq69on11GHxbUOwc1F6hIgiGFFA7BmOAqpY0MxyWRvaC0uYQ2+5NtOVgnrGX9
# DATA 04ePv3I1N6t+IBymRNnNyl8aNl5I/FeHg1l+LOQZM98FvTFPIZ3fnuNgwDu0JoIF2MMgG+aKg3TQqN9mwH6gQh2AheFMW3mmdkGq
# DATA lilv1+I6EOVWnOiEMEnh1sn9UB+c9Ls8HbIzJSsHJ2Y0STGHNO5a4YYoHO1wqhoAnQq+jE34z21F/I8zzivEW8jUVvdnJKC+rdC8
# DATA LX785qgJee00ixH9K6ZbDYerh77moy1OeT7pdpyzqw5SPu2UHGdLjZryVeHcMsGkNksMfRyMb8qZncAvgsp/Z8Lfnf3NAN1V2t1E
# DATA x3j2wmpLddLg7meyeHLMJ42CwiULmYThcXkmYWO7mGRdde8TGOnT0RR1ahSkCYCanF6LG1I3OZE/i9+33FvQBALLx0gmuUBzPBrX
# DATA Em/D67JuWJLDRhwbyxxOVVhBqr/0wJTyLPruK+VanHmZGtVZm0VnINOu+OUn2+CRFYcezOi8WN5nL/8zbwyT/tlzdgblEy7xg6jo
# DATA y9wq9W0KC2S72+tFc6Z/pgALHYcdLdNIcIHCQyAbE5Wi1OjBrNDhsKlMyU39l5lmA/p3ZzqqMR4khHWpvVdLyiaw2tEFF/Nt/H/K
# DATA rDZh8BE7MFxRk3QitqG5dTPqpPx7fZT19ywl4S4AE3P4y3LokwVsTiUGQQEY67naN4h+tSqd6664CS11fK/tdKW0dK9/lOVAqTn+
# DATA opkfpzfv3K2V1/9VOEMEYWfewkEi9L9LOE2UrO07dKS45i4P+i3oB/3hCI+g48cgv1A/k9Zc38xF3BLKz6FNWun2vPIzYrjm4/l9
# DATA POBQe+kQcqLuqJCE/m7d1pTMd0Xl9cEaWwtlen2bCbJHpzkbg1tVDRue/5Gd2QbpeRf4jpRUZoJWv+LFX8z9pqSjX7v3zbscfYH9
# DATA IM6c5TzF4fAeUFcr+qsmA3iDV/tSsekSjgosIXsk21zitIqMxaMkkf0zOhZEi3GVLMZfWoJTOl7UIeAPT1x3zI3S364Y7Za4yiHM
# DATA O6J6xX2juz53N/TO9Lt2RUvmi/6QNKmsiUJlKqqirJ0NXqu7TdHedjXbp32MjeNDH64M8QdCKcu9Ie7Zji9i4fM/KYSXGA0hFuSJ
# DATA 2MdZcx8FjDlUgBWydu4LQzD2LeeDgJ2rtA1cDW+8H69/WhwollsoBIF803etutJqnlk+6g8jp8NFw1jIKBawsWN1lZ3HEpcyRMqe
# DATA L+BoCAxHkQclFQ9GZwBbFtIa2rfqLmPiNB0JGDPETDDsMrCBGy9XdQInV5Ek9ZdURcEvaR3JjxfDUIyL8Nx5M0iQh/XhlqW/L2sR
# DATA hKHGhdCKp9kEARTZ/6MEJDnMdj54tvNZ0c/DudVL2VYiClUJ1QEdXWiGpDZiOI0DYJIU9XySv+xOpoW39BgDcpXM4mSm4FeP1c74
# DATA 4DGk81hdRENXgKhyrhaLJMFQ8yJ+b35QWKxqJOvLLNLVM210VF8Qero2yA4h3q5/dDx1GW1+ljeBEitac+Kk6lEMdvYqTsJJoAmg
# DATA qn/AWmAKqG8+fPT4MecpmOVZBwPrBZTO4WzI6B9mS3EVhPmoNkg6vam2FQZV6U6aryqzUjsNNNPJEfYIk91T37odhHE0v8BhozMW
# DATA D+a8nqn3+24rgAkDMd5tp5KifhTmHu+H8EdH63r1W1oTeI1/dQJKVN1izakABWNW6cMLymBYd6pxS+EbXewmpbouzTHMYNc9MT61
# DATA arSo1jiHBSCI1CCu73y2Y+DWkaaZX1tPN7d2d549fXpRsYZ0MPjw1LroogqaP8VHzRNrQkH4fHJqBAVLPlWHA2bK0V7r93YnauZi
# DATA yntqYfEmpBkO+1Osg3plbXdja5N0LTsif+3ChyxwRuYertLTM/cEBUeztrv1ZONhRxuAFb/tPNtc+97axmNwAZd+PF/LcVv0yBWO
# DATA HS07KWbwz8LRkxsGionfnRLDkTmKXpXymLEjL5+zYqVuabnX+JNVHxbVBk9WHcfiqs49RgbgqZRBoy0LhcrQMVsqstir7Scyb/HM
# DATA SaOAdxrZnnRNuzI3/XXqaBO394khGYTagUh5Qrx0DZ/G7YQIhQjvD0IRkqnBVqZ7uRzF1Foew99GKIXrnENvdHttUQn6P9JzEPv9
# DATA ynM2LOjS1uOD3y8YLPzB2sPvPnuKgKdVwc+UfaYgrIdVACMAXwRLnSJ34C2GDlPi24IlOqgamKSn+ppdckdwbgcWEcZz9ai6+ReR
# DATA +UWuX5suw8D1W4elbqYkLWcDpZPuMdgFWmX6By6g+ioxZSo0Eu9Ap2A7aFQIdcam+7p1CYyXU1Ap8KXedhRrKO64MkSMajAG91rL
# DATA h9hxlNqTF/WiOkJPCE7ZfiFXbC2oHeDS89UDXDBJFtcQ0ImNpSRjd5Y9Bc4lmUIP/G0oC5ccjmDpJJDIwmxYjxaAp7883Uju0tMi
# DATA +USxxSp5eGLmSV1MvlylarEJwR88FZ6NRwhpLigkcgJuNZlz2AUXqUfT0YtMiZCjQa8eDbNTxlWsM4uSGBF6HUKkbclmHSjpOkUf
# DATA i6YdMU+wCItE3MtewpyKb9yXC91KaY5RH/bZzu76EyED6u3hNKE2S03gZIELEE6RcGvwAry5Gow0X1lxo3HKVlKoccJb2gSZBEu6
# DATA NNhorQ0RbUWrmo62KulZvSB8SWLWClAyTYlbuGWKn9Peb0Vvc5RkdhOSiTR/0vuMnGUcHhqfnp5S2BlsQkW2wjsVCqgXl4s9Zobo
# DATA zS/uC/U3HyGWlzhXC4gNcrdD7ohBj6dNyVPZqfobDpwzhVBm5x3MoFerXhQ+2zEdbniAf1zIuCmzm5A3a9dbD2PvRnRz3gyaL6S1
# DATA XfvrOSsnAe/IITMIIUQy0WF/2M+Py+iZowflG4Twcs0OYPP70hfuHJlR8ahQxHEOxBIhyiAyRi1CUQpNB7WPLkVFvk27n0eTOEkP
# DATA 6JXuCKpJVA2BMGBO3kfl6npqfP3jYh1oQ/K2U/EGZ6iicaPa4yrqNOtJIFqZbkQuo5ERh7zIdbv/CgkG8zyYY2beVqJqfqBOyBB9
# DATA 5Ur3rFRJcvGi+U+/uLIFkCuolxzHtxe7iZy5dIypFhOsuqBPRhK35OTdyeQLmO2ws56QioiPRSsWFU3CsrsY7L5Gppe7ICS5Fy/R
# DATA IWl6QYE+jCHnS/iwCvv1yPygRQiI/MHZgsVbQKDHYqWXCFrkhW8RXNy0GoyV8qDVLJWUOJ2xHreu8zI3jt3ttc2dtYe7NsJIA5+H
# DATA DOL2UoNSaentyb06cEWk+lyEb7gbc+kywmjgU8F2rIhoOctcrpe9GitRFqMaxT4o5J92Fp2x2eniCedGV/KW69JZRD0y7yLSnU1Q
# DATA h9V+KxmK7UQvNXeCNh2+V+ffdvkTbZiEbE9Q3viTYNKE8HQWrqG6++Y+ac+7TW0zwM1i5x3f4My0dQfmqv1pXl1Rl5JBCqKzVCWI
# DATA VOmS5O5wxIBLqAi4rp6ZeyPZGAVrKXESeuBJ/wgDuNyj5X665BrFi+OiWpLqTX/J2749Y0eZI8fp5YVZp2RWPBFBO4i5EfFI5W0o
# DATA 3Mcr9NOKjW4r9cg/AL4oHT4mcN/wRskfeLu6fOx2Wwau19hV22hAxkX5NiCMip76QHCl4mjBVE/tmzrdjXuJTgoKVC+ehwpaVA8e
# DATA GRwzzrvcbnMmXixRhYbnMkMJDECSQOzgYlyFbTMPt763vv0ZhIF/+Hjj4W6cVNEtM9z5x6s4rOJKFheHbJ0lJMucdtMnzHTEH8+l
# DATA lpUD/jp5Ixe4ZhiOm9K3nIsthHMa4E3z0/HpKDArS1QeUdZG2NKs/kxKhR9prMP59VvSPeDrmrQQ+kvBl75zvoOw0kizz9Detfqd
# DATA KD7KhtkEt6T6UJ8TT+9jPBVbRmAzvotzhJELfUtWl+RpPx1QhLQ+rY4bDj8sj0MzLhnhqK/LxCYbncNlwpN1B99RrJejptExFpcP
# DATA 7yLzh2EQHOYPLlehwK3D/gSDTIaQiIlL+P4S2s6PRcvT/nqL4n9pERElKAZcG4tNV3tfFxxkvNAtam7R0K1Q+MhbAi4XoXIfkE3Q
# DATA iSy5Ru62OktGsuBAC9o8Z8FBehLzWwiMYv2WIYsVVYVCwhbrkWNoLuuYM3ZU6ulfBWWc6W29CI6XvO0IQuHCi8QBVPkYApBaNnkZ
# DATA 8uV1Ifi0zsBnqq5tcalkMlhJmRQrFCG6zAzgzQwywcemc6BjIxkVDAgcPy8C+4hxBKwh744d+AyHnxnOJVkGZz1lTA1xg/LxNdrx
# DATA RBHN0QnGh2DMuQYHEBc1aYKsROKA6HFQOHJVhjYdjEaDgCu87oRVi5lH5AVAXTM37mBAgEEKWVgfBRA+6zsGWM6umeOw4xjc7Nmw
# DATA qpyAizlfxmzpRVXXNvy7oL1WsxJSXDsh6DTdNs6Fa4PfvmRgClVJFZIwBc8nlpJX+Xa5Z1TBNkQYidBjIco5N5ElYa/2WyVZpMz9
# DATA XwdAvcxY/bOIscp0Sn/nX1bEJAep9wIkgxA2ChTD3L2C4VySXJjeuQEzLk0QhcTzfUkmRBF+tn/hx3rIDXXlDbTYJrqU2jHAB0LX
# DATA jMAowirUcrF58c6Tti6wf0nKoimCt6AcPncaKAt929t3Xdrqi31lIv0qhIe6/7l544T/lXagcquE7vnwjJGXnMm4ylRXAD0R2vao
# DATA 3yU34n5Pfdg/7GcTNOWIn4wApbtfm79JLN4mSKbwRFTXbhf5eGIVmXk20Hr92oL83qM3xP856V+ThljjkRIkmWGZbcEy8Sv9xrm5
# DATA 6x4F4bAuDYklASMdXCzdjsDFsrH9LzKQIHxcn4L9P8BhK70AfBnWdxNiJZGXjuKywJHTdKKuOBjvDd1cjgrwGMy5qGDTxyiR4EVY
# DATA wjTs+7VaUKzbt93+MkCHRZI757HdkBg/DCGoyCql7D7KmpOjweigFt+Ik+SiDlh87UF6ctBLsVjLzyRW11lCKFIgpIn1EVKGGau9
# DATA is46Fc5QTvxqy2xSG8na0pJrOOyZIxpbGujPI3Jl0JuOsm3+Prgoa53dsaTnhUMoHaceM0Mlnj2LqOaCnj2OGcJoaa4FPEAWDS2X
# DATA uu7LujF2HPukeFTIJiilJ6Z6vVhIiUHeggQu5ntOUNgK+NWVCV9lm8+RrQJjslKVnikpVGl0Q0z9XbyKUcG6URx2bGult68gWHrx
# DATA 63Ivg0Dxhe9NH61vrm+vCXPxV3p1uurtwlrxRY+oVOLFTXBRERUiG9Wgzwv6R+jKMAjnUtET8aIXG/AsKr1HJs6Vsapc2P+pCrDH
# DATA +Al0nq5vPnLxbq01o0QGvozipmi4CGxYHN+CPhFc00LjtPs7QArZHE1iTrnFPeSISPPi+YU44zWFtUEQ+LZ+Bt6y1KIe2FvZupke
# DATA 9TreugQ99flaTI3P98Kx8UiyCX+R3NdytfSY/cuB12OnvbnSpI3GWpSF8aaxdsa61wfjm+8c+mq+Rt+/pVLAVQh40+hcLLxJK3FL
# DATA xjodLmeHLFUGCAZdYG2o/1Mi7Es3j6WSFyfoCEV51ptrk6MZTPZTfFMTQM/teIMYeHQwG/YUG48U+UsHERBZzS5yJIyj2TTCeQO9
# DATA FuREgD7nTZNQF2oGjPFOyo3V4kZD4q6BXrL91KgJyr4gabOyjMBZUZOQqpkxStTK72j2GhNy6lysPywBAXvp0oSRMDFVG6e6NZij
# DATA K3zG22bhDmry3BCbSPNhBFjj7/Af+DLHDZME01TD6yZ0vHD+6QAXr/zoSoGfcccLTjn40sniaM396k2IvfhltBiqf7MKvNLuxsOm
# DATA aFk7r2osP5ypzuSR2J1IFINTWTd732wF6IW3Twvz5Iic7gTUndmql04CvwmqSotW/PnzbOdssfnyJ4e/T+0U9qLZUN3NYCZhy0DV
# DATA s1xR1ZI5cSwiwTnRphH8YU0TcgtUzcp40ldHQgAvU9OLIC8nBdaxMs+MFcAFKXTgPMYSzFTwb7j0F/uj5GK457YBZyCfquv8pNCh
# DATA VUXyzXE1CWdA1WaTrAjIfnNS95fCVlSnCgDyh4srog91OqjI6nRgNTod9kKArin5dlpDnqMm7BuX/x9wFVx/rTtsjs++8Y7/t6L+
# DATA d/f2bfxX/c/59+bq6q3bt97Xz+j56ur779/5RrTyja/hfzPAjlDNf+Nf5//83Gvn10k9db21Wr+Oosb11t759X7veus6CnZTRR/U
# DATA Ublev45ZKtTj13/75idv/uL1F2/+7PUvX//qzZ+9+embn7z+efT6i+j179Rfv33zp+qZevL6S/jr9eevf6s+FgIPVPF/qtf/9Prv
# DATA VeGflHxVj9S/f6Fa+M2bv1ZFXv8aXqlGVVFV5a+gNfV/v1JPf/3mZ6obP1X//o36kGpUxX/75q/Uy1+8/qKpmkcV1vXW+XWdQ0V1
# DATA 4v613ghhIDDpxYPnz4f34Y9ooCSs9vPn17Oh+s+D+8dZ2ntw/ySbppihKM+m8BK1Z/ge38Chhccv+9kpwCKpP7UGDR6f9nvT43ZP
# DATA SZXdrIE/6toS0MiVsJe1V21dx9PpuAH0/SV8+pBqaexA3rL+9KzxdDTod8+8BlgIa+STbvQ8zrPB4fP4XkRT7j+cng0y71n/5Mh5
# DATA gq5yrXvR6OAHavn51VAxLSh8kOZZQ/VFPAJQlgaJWfZpcXbEJvD6vxa97OczlHqn2cFo9CLCdDVKyj06hjvJsWIkx6NBL0dWOD1W
# DATA knGq2GKUn4DgTJcJSKgcgbZbPVds6STK0hzME9MRMMVmtDOd9c7w29Gk1x8C7BIjySqBDkTqEwCExF7jVn/wFFTbIN4cgvdI9OPo
# DATA 38362TR6ORoo0e/+MhW6j/46k2wAw+h3aWSqu4fweznN1X7Jl+F5M395BO9QpoSyJ6r6ZfXwvVcnA2xV1oSrlB9n2TRUHyxBs5vn
# DATA l/wM7Xz6M1oKgNAvFPkBlADBPps8uL9MBdUfeBLgmEC6P9wiqASCzyWpwNrVYRmoKrFPL/pj2ZtvAvuCQjvqBawO74P7yymdNmhV
# DATA fH8AFwtnONa0B9W4q6LqGKYvlYzSTxuD9ICm5QnITepx/yjlzQctlNS39TKbwDnGukSpXO2ffpabcjvjFA5wxM/94rAFTdlt2I+n
# DATA o8kLXBssuqz6w5MKAybRsAef6vm5z6mZ7FSMwdYDXxBlWn2we5yqJRyDTGwC2tQWV38rWW3YVNWvPrg/VsWyCL5Vx+MsOk5fqj9G
# DATA L0G7C5n/jvEAQCpHfA2rgWIm7NRRM1LfqmszusMpSVydtikcsbPRDJYOPtaKKn10VavjB/d7/Ze230Qacn9nHMymU+/AuEvxgRIy
# DATA dTMHmbr3At4uT7RXC5gHR8OeOtVOfYss2rLqK+xzmu3AtPMDmvSbD7Ym0bivOjYbq0lSpOVwpiZlNBrAdN+E6X6YDrozNEceDkYo
# DATA /Wcp+XdHSO2j3iQ9BYoDfn0ww2q9zOaIeqOMlrKXTQGtUN0glOw6g7OlOg52XwSuQSCj7kiJ6H1QgtOsX2b/mfEuw4Z7cP9QifKw
# DATA E8fuiVK7S04FaH3plgD12txRqj5V8IFee6crNhEZfLOGlP2P0pPxPZDXX6bdM+hQ9P/+U3Sp/tOq6V4vA1GC88S8XDF92+wfuP0f
# DATA uP08bk/b8gpM/h3z+Kux+Pkc/n8gBv+O+ftC7P1y3P1rYe60I+XwDUP/l3OCkODP552K0o/yTHPQNc02SZ2nWkTurvmnHDLINakd
# DATA 5uiQAyDV2NW2QrUKLxFPQbc/QeaLCjxvInB6UKTRLDhHddogSycI5X+imLbaWYM6MmA1iP5J1osOZv3BFEYA9DGnIauePsvhE5S2
# DATA dP/0CKAFy9G7Wh7IfYGAxIHRcHDWjDamWobrQp5v4PgwcYptoabZmrW1KJD2gMOgehG7CIvSQLEAznqeI45RtJNlL6Ifqr0Czlra
# DATA uHCcDcaoq4JORunhIawSCCTpYTY9MyP8bDSbWB7NQ1OSTh5NZkMjah6As1M2aUbrnGgIphTGMRuDtAJypt6FsMdzlGFUAUihMAIh
# DATA SZGHHMqkg7Npv4vSjRpbNpmCjf9IDSEF/wvt2gZ1dY+z7gtUeaJpB9WeTmf++0/+t5zHClpe9AvKu6OxqgflSbFmzeghrH+EdnlE
# DATA vFADO4ORc13wBXT1JTSRnaiVOtSVosb1/2PvXZscOc783q9SDlnLbhHAoAr3bs7Iw5tEL0nRHEoMh6gXBaDQKA2AAquA7mnNToQu
# DATA 3pUd2jhy7Ik4G+EI2+GIc95TWtHmUhIVYX+B7q+wn+Q8/+fJzMoqXBrd091zS4lkA4WqrLznk09m/n/U1sOY+qJJVGE7EBQTGMqS
# DATA t7M85tQmFlzY9AzdYXLE44MBqmLN772dnMzEzENGys6yAdUY7FgrRU3qqdySwQinqFIrRw83iKSij5NMihZ7ClM28R9G0Txv1OFg
# DATA ANt/kqAxDAZ8/QgBxVBIhPASZyaNHggnq3kfJnzfkkuNbo9SLjLkpWlRCHSOCI8j3UlQ9fkAvU28kCRQ0HZzoRxbUuXmaq5aq26V
# DATA 0SMyFpHEEwrMZMWIJy+FgnyPYmw2LmUQ98BuvKF0MB6Ol1AJpbE+VzoMEcWa9yY6H9l7gCJJMS5G1Leo6krvwfkt/k2qlLL2rzzN
# DATA 2W2w2WmGs6OZfGvG/lVs/Wsw9YtGE9n733ncTx6R+fIz4Gv6XEurdOUJHnpMFk8ymVT7Ec2F4yQ9yKYU9PgJwn08DVOqDQf1Q6xw
# DATA HKVw/Rwch+letToP51G6fzhIJvSIXCK7bP8Q/deB35k/uuPX2i1PfkFY+4fYZU5d/kn1JA3nB32qgQ+rlLbhk/CxBBPPqIHEi0No
# DATA +1eX2DpKtl5UTUYjStBBLQii6ZPwYIxwHvM9Q7BAuJFUqfIPHs6o7R4E80dPpJJU4tl8uajI/q0KnsBY85ijqN6l76zJ38fDOKNh
# DATA +JR+5lePJtGjQxotjmZV3vJ3MIiAiT78KbXOeHRaVe1LX6b5KRktGFcPms35o8O5GAcHlBPUZ3p+zcffQymBA3/+yMtoSjP0rPxb
# DATA yWh0HrNFMacpvfqyKs00HMbLTP0sXyoUAymP6onEqd2qH9JUKqNw5gnzrg9L2XiACYzKk5ppYjp38iuPrWhSNzXLZMfUSnVQQf2Y
# DATA LVTs5c6i4V0sOv/k8UpCOfl2AFLFVBAHVDIYVYaPk3k4oNngQa3V0qlRc0CqHCMyELIq2YMxRiD1aPEiV4rSNakipYu6wpTvXU6p
# DATA WZwWrz6mpo0ac9AoFSrfRXVfftZ1mYrmicSD+uu9H/MUiYdxapU/2bcuoiiTn+yv1GGeSR/49fq3C5WuTZVuQ+3C6/d3b8d51UXN
# DATA rXWsiqsrW0MnohT/inVR4q+iG1DTPFRR5c9SiaurnQg1u2o2TunLQf1JITiy1X/yWEeu/sRkiJULfrdOYVNli38WHbDlRMPUE54f
# DATA mfZ9lMbDwyPqhmoNTlmhmdTrcneNk2Se2dQZcDAdhFJu/3aoTQp1BOoClf/jrWWkU+fXgpYOVTKQ4hUd0Sj+2A64U6+bR+perUmP
# DATA PBn7lXFQGTcqc9WFVxfJnB4f+9L7yeswv4KZLAFVQFrGeDed7wW1Jl5daddaxyeVVg1f9qlHrzdVTFWe7B9OyBKiKgG3KyIgv1KX
# DATA wGSNSrVWb7To0cNp+EilwW8PxocqUv2E2ueUEtrgSAe7Rc6X7rTSoKgFnPGImt+9IGoUl6CF7Cy+m9/ckDfTSzyV6xRioxxg8Ulu
# DATA GU+QwTpp7c5g/CSeHlWy4yNTa5iEdmi1V1VBwuUieSJz4grvM5ARXTUV4OL8oE4VuYIJ0x6e9KpeG326iYgMUnZIF9bV8sDF7nIa
# DATA +xcnUTTjmuzXWqWq7Ndbplsx2bau5j6psfdC8rIjedmUvAxW81LnWlCnCrF2HKK5RDFB3C+w9YD/SMML1NDKf5+wO+TCXCi3001v
# DATA 90IZuZRX/y5M4J+UTY8DY6kclprlkxq8QY8hnsA3juJH0fDwZ1X2wVC6D9Eoqz5K+RDEDcppZPSGLtp0C0gnhyxD0GOEgief1Mik
# DATA SXTnWBVmYBtlV+z16D9mzxr63uV0lh34o9Sjfzf1b9xAOXyvRpYDvYbTyl2sNmvyIm22qCHI3aP4aJlGxpDMrw5C9oZa4dS6QZq3
# DATA T6Sq1uXXqqnExXWhW3relzZaUwZ/KWta9bxa893r67R6mDukYhR2bkx2plL3vdL9texY8os86gyLd1HWoeQe71CWaTSnWeFeo0L1
# DATA nAplr16hkqVuI4/Rk9ogTIePrZHFGnXaPNSXa2G2TEc4wn2BfbHdHJX3evMDzP6rg3E8Ga4mk2+pwX1eqU2XNCl9bBsIfIUCwu92
# DATA 5elJHp5gW75tDfTWtqn15nOLOtkm/dugf9swrUrlxPWzUADssys2lw2GuhlgEEipN5Q0H8wWY8mTvWC27+m0bCqJYNVqe1IzftNy
# DATA XadugJKFTsLc4ilrQDLQDPwYWjHq4wNChK/SGuQ6XbRtvurZg1+njuuUnnixSx2lzFQ9ju5eCq2EoTZPavAtGGsvuMl6iTfxYs6q
# DATA iajHlpqYb5dogcHaFshhyWbAx4XOSsw9u5/3VJ3bUgdUynj8aK6bUVptoSHd0cmYD0uitzqgSRn3ojpGB5SUxalJI4+ENdm2XrCx
# DATA ay1tNavmF0i3on2Rayztpp26+iHuqvICjnpL7secxI93MDdKcxTqOWjeFA+ix3aWlOdjujnq5iHjbk0KhaaXR5YRZaJe32GYkGe9
# DATA ENMNmg/uUEkKdcMz3wJ8g0232iDsMaXYX3v13Qy0Yiy9uTUwq58yGtxnR49LfgNqIOFR2Tsipu2WumkKKJBJZFqsM9326qRyQ9Ps
# DATA hyXbVreklbG1ZBeUu3AxCFSQnkwK8ciBb82z/Cb3lNIU8owuO2+GYTaOihn843E8HEaznxQa0L8SPGA4Wzyh5vbY+MEeseluz40w
# DATA P8jf17yg6dtZ2d3UsEtut3B2egI39BOsjUgpj8JpPDk9eItMrITG5cpnr70f9/Xe9w+SWfLZa5Up/eFwi22e8nJI43A8yaxsCnav
# DATA j8qX8rjklSo7rUr2un6nV5jdchNWk6iLmuthcXTkGAdq4pOH2LCH+3VG5w4GYLnKd/NYWq3PqgMtjK/qhoJbg2cqu/knqcfOvdWl
# DATA meiG6lCbx5NJNU1OLraylU29iOam1HU32sx/Qidu2n9TddALuPA4vHIreMI/6YKjLnISzjOyStQHewJt10AemBfjymIo0zLOiwPE
# DATA pjCO7lQZF9tsrSc1ikH0mHty6cAP/DtVn8dGy0dkGQ1iMyTLxXy54BMJ5cySORXv0q9i2WaNNYvjaeEiSR/rYXedLSs1Wnd0pkI/
# DATA +TfTaBiHe5aJ1qZubf/xRqeD7WlotNH3Kq9CsbUom2R1dOLKIqcoMN2VbLLrDM9PN84/S42ygZmrnZXF+aRxurS4r+a50aWMMW2s
# DATA bo6P/fL1U8gGFhuKM8Qds2XFYNg8LQ9G2sfYsqwU/eA9ey5lV8+gZD5rM3a1XjQbXC84Dyvayt0YH3bLiOuFR/VeXjiFCUUgbjo1
# DATA 1SwOD7unfufkcieyZv7DHTlVJZPuOS9pZtU0Gi4H0bA6TbhY5Cu1jnVrYhz4dyrfOZBNH/QhHKHdhLN4mruM8nH+kBdF4jW/6GjI
# DATA 6RzdFqUZVvRiVNnhIfYxl6YyPyyXr6zUWb0CWwFqbtin+elDM9so3/TkSWHFUO/awg5B+uM9mk5mvPaJfXkHd+6cnJzUThq1JD26
# DATA E9Tr9Ttqgxc2EL2ZPMKNda/utZv0Dy/7osZ7sgGQvvNFTzqy/HvKz/kBPo9oCOI9U416Y9jsYePjvTdYroR3C33gtz2/N24Ex93v
# DATA B81jvz6m/3a/77d/Vnh4FIwao4Y8jCgWV0UzGiGjp09klybyNJnnFCQTtb+Nb8w3Y1HF7Z/iF943l++uU5ufzFV70fkg39Fj9gBE
# DATA Q14LPzUb8Kws6dW9ZrPlNXpNL2jVJ4164PndRrVR73h+s1HMmGF72I/qq7naaXiNbuNHfqc9CQK/2mt5gU+P17vH9Pd9BN2qB8Wg
# DATA otHI5zzm6cJDTv+3mq1WvRXlF6um6BsrL0WoXf+4GfjTejXwm3hltdfjyKiIeL7Uiiu+IQjqXtD0j/2gMfF932t1fxT0uj/7oNno
# DATA eQ2fqk/Qnfj1TrXZ+VHQ7haT1x30ojBcCbLTolzpjf2gPq226/TPMT426XKj2R37Pl1uteifY/pYinm/3a83R+ti3txYU9X2Raqo
# DATA BzhZ+Fh5gg9UDT/k+f2BaiyHemp78K12q91v4ILxPtEj/L9DY9CsXgkOvhX5USvqHCof28G3Wr12p9M6FAvj4Fv90aA7wBPsdqaf
# DATA h+1GMDyU5f2Dz157EB0lkffD92i68Ek4Jtuzcp+3j2XUFVazKI3xrO7Sdrod3VMNuy3JZMq79AOxJr2g6HTuiiFgbjejkZrffC+i
# DATA Nh2HFQm6tDR3WHaEwTirdGrN45NKRxxhHLDaKbfL9H6rf4tmqsUQy45y28xTBbP6gPahF8eJwl3zglUpJiffgPFnEGMn0eNLLA/k
# DATA awHiASyZReK0ql/OuPHgoi1vxCh6BeobjdlCaisrSbvIuFOevZU6xmbDTVoqT1bb+k/R1D97Dbv3qJOIBwveST7jDZDev4a+mHf3
# DATA ntkCWft8GaWnD3hfQJLuZfvWvebm+2kantZGaTLdW//c/cmEHrWeVXv5/jo6hfSifgYtvIbtgBRbnlt6r3ufvXZgR3AaTXE6W7Bj
# DATA H4TzPQ7UsMJZzvhhdFrxRuFkgsq97z3GgX/6rwQgMvm8p+yBRAJE6vcoq/esSL0OjbL9Q0MVZroKvXQ5mXjf9fYkFrVxmOFl+3RJ
# DATA XaGg5MqBFYEDD0c/RYuAxfYPvSc4qjwYU6zUGy4TIh5/YqeaD9VLshUq9rF+PJPH9Q+HKi8K6c82pL8i8UYtmR3Fo1ONrTLZgi02
# DATA a9IywuHu1UiGp3uYPO+booggUPuv9z577Vvi+f3sNQoaYkPRBIjWGu5WpzPoRnw7LAU5Tk42hinG6KXDnC2ne/FwP0/Nh8tpP0r3
# DATA OMzPIPpHv9Z0bhYeHapNpHsi54bARc+C3vTZa/h6h5pzPDvUx1zkjMtreeyXKaL/w4/fr8mOyx/w8RD6DvU2701o6P0Y4fyk4j1G
# DATA wE9QGPJoaDckefqdScR6GZ+9FnI2hDXs/oNmTTrBNx1ftCaKMS4NJvHgIbUpbD39JJ5GyXKxt7ePNo5IpdExGRV5pCgccN/JflVZ
# DATA IVHB+oYuBcwm8HI7n5IZNjTvjWZIOMoGD7AQ3hRCH+8cU6TfV1orFEa27E9jKsiKFx1zsd2jx/hjDaox9Pdt2Zi1p4qaA6LpOE2F
# DATA fgR6R7w43dun8Ge44YmK6r9G9H4sBy7C4+gnFMkaPfhOOBjvqc2f/KIJGc1ZKGJ03LtQhPAV8fnxT9Qb/5X0gHHGf/f4Bnqjfu7H
# DATA P9GlRPmP3fHQ5dyX8OX6KStZ8v01GlUmy2GUqWjkHSL9Su8zm+QW97W0PUrY2vqGqD3gRrt3CrVO80yx8uOd36WK+UCSQx2MfMZ5
# DATA oyeHOqp7+eNryobrC96nk3MdWaU/75AdlAC5i4xqmtruHSMWYAff9dbefuD9uFbjz8PKujtMQZEFnCGZHA/uXq3ESKQLWYTeLX/G
# DATA ZKvZh76cD/Vm8sIGfpXvb6pt7+v3uB/KMxIWb2nP1HZ2nAklg+I4qnELfyL/Fqu3WfAq1vHkUV7B+ZZMFxv9ZDLFPLy5COVhKkMT
# DATA CgoRgazYAJ+9tm4nnx0t/l0ixh8lAlwMEnxeH+R33RPLt3VVlE/e2HVUmSC5Rq5lv2yL9oGKy2eQ8JyS7SG1zURhU83ZkJ86Aqr2
# DATA 6K9k382OaDII08djM94z76WLpVqmW8uGenVoDlSsr1moNnm9UXVH5w/MVTNC8zfVk8sNNOrT3IqNMb5Ffy9399I03xMtU5P9nMms
# DATA T8whf1dy0fubv6FYo0JQ/zXdoz/J+8lJlL5FmbdnspgaQsbia/qVhafJSkLCuV7jxATdVz/0rAaBTC1WOrpgVw0WXYR4D123O81i
# DATA bPKayGnZ9/7qr7w9HbW7d3VMECkOyFQBk29376qkoP7iFlnWozf/K46CNDf+uC9pef11KShl7GDlUGc/f8nNHXzblzvyYCU/0DvW
# DATA 8xFJKRVJGeIGE4j8tq/uKQ0fEhbXUo5hlPHAQSWvS3RNY+R2hLZoVQokx5Tj1gZceIhehDiqakqZrAPZL9Y43Kgsjr39u/fYZvzs
# DATA tXfNoTA0k9f3YPZ99po0PUr/d+Q7zwG5uS+Sd7Gtbi/Yfx0J/t+/r31G/5u9rWfJSbJgV6sXLjyfZiyvSwB82IwCoIfWv4eMpzvF
# DATA W/N3+fyu//OP1oM6Qjs8N5hK45YZYH4g0x3MdgezLzqY7Q5kv9QHsr3CdmN1Dvq5PqhtPGf8c+EE4MQ6vv1gzmp5GNniIWAj+vR2
# DATA fjtvK+Zzcs/Xee4X5VTjRcIttqOU4y8e53tvUE9bboZ6kQzRMCsVXVnvslbw5EI44W/Fg+rlxStp0oMEmStvOp0NdDSUH/veD1bW
# DATA vthMJXugdPDfeoa/cDo4A+b3uGgPqNyhB0PlBXsoXZxiU7F5fi66Adk45BOxukZ5asMFTQv5OPKyT+OaB6+uhzkIhfk5x4N3KcVJ
# DATA WvN+MI9mfM53xGf36SF1mJ8rq0dhjVHrqE56sg2BMUy4m94MxgIFNFO6ATsq73glH7fWEeDzxBxtshbIyD7CuTQjw/PXOOaMCofT
# DATA 3Ux08D5aGnevN8NlVj+Sd8T003IOsyGrebCl+MeMTapkBCcPtZghLDXVbMhcTlgCYLRMyYpYrqohvJyHbU0Iznpz1ttF1luxhjl9
# DATA Haevc1mzbaOBeFO6Ow+whc2Sg8Br4NuEcJ5R4Hl2Gm/bhkvs7vNsubqCJcfrH2x/YFFEbcnR17iw0QmJHcs+AZ3Jygu4N91/Q3yi
# DATA ugHOeD0KhSShmedMd5VfYa8Yb/+otXgTkdawpuTzhihcnIa836ilNpNEc959VJOe/Q7HsRRV8UKY6oBvO0RUP2XiaS6YaDZq7WuM
# DATA pnhG6GftpeELb4ijVUVK32MiZR56I+EOP49cgDff8w+C+ht3EmUVlu9pqXtaW+7x6+om+pDfdUeilSdF2eo6N9UqGD2YN4OFLXlE
# DATA ZgM/wYZEOqX38p5glU61GorRS1fN/JL0PPExv2hO4/RCcuCOBIH5k8otWae1Q8kv6R1q5so9y+AMMSGzOgBbmoqNRmn2S0oVhF+M
# DATA QfkBDYbUP4vRqL3WVvvHGBvNuOWzoWgG2jgVO7Lm3R8OPT4Tq8yCTA+fuQ3pvY81FKXqiYmAGWmXkE0XRy8bpWKIU4+DN2IXBr1t
# DATA vpxM+McllmFpUI9Tbfz/MItEeUdEbET3J+7HlMUiMa9FpHSdx4JtxlEgswSGBZvS6Ikwr4kzTAspSTPp/LTKFdvrEwjfW70cxsB+
# DATA xHqZnGncwUuRcGm8/FazPQA6w9kZzhcZziUDyVnOznLebg4/B4qVn9DbuHFkopkXDlVryM3mkmYjBhej88aKiA+jBRXo7Eik7YrS
# DATA i8IES0YYtxIlAZkrJYoeYtlILvlnsV1RSkFtWXxj3GD9OS3krBs7xbghLjMjUgkLBvuUoLcYSnRZDDsZjbD9CzJ93Bdk3jg5oZ89
# DATA KiEZLjmva54yLiBpSbE7xriLfiYZccfAeW7JV4rPipNTHPQWIXsz76cYriZmpDMpspP2PjvlwgHZOBDSPKEeK08ZRt4qTxlkQzSj
# DATA TsNJxtvFYOkgiUdki2W6VxtS4Y2pN+NS4mTKKR8KYcai4nAjkul0JHMnMWK0vyyZktW4UOqCIayCh55WCtmSzrfDU+6JtycUZSiu
# DATA SpSxTuMD5X8cRRElaxiPWNqPZncw1CBwiD2M2IdA1WohWzCYbky/oCniFzYBvU8Yw+MxXxABsmXFTFk4Bqkq6oQYi66/PJVKfbpA
# DATA fcYm0S2J/DjK1iRQzIpCFV4VVDVVnaxU9lueQBUelWyCJsijThqtM2JRpBVtR4LwFg5jnL2TgU7sVCUmSbX3Y+i/DCkTyS5k2w/J
# DATA h523JGOCn3goHlftUmZIGWr3VN4p9qSeSmup01GcTnlxZN3clhP1CeWNzMfB6J3jGCmZSUZtnVqQsZ7zxe9M/NdyP+UHV0cyBdT0
# DATA PMzEFubeyftAi3tS78qwBzalFYjb+JCp8Txk8xhTAzJ8qaTD5SJGtxGmrNM1VcqTrH4qHQq4UOI2JgsB19WUYmNq/3qWnEj9RCuh
# DATA JoI+EoKtOsFvJxz+AvsqkdvSFilBc7gSuGvksU3sEsuvgMZPpYwtDfHEwLVSni6kVNyUfWQjUYZJCqnIcUAaOzLCFQXZQjfMU4TZ
# DATA aVlN1swnbFlZy84Xm/kltPafPKkYhs7iCHDe9NQm6Px/5786+8PZN2f/8+xLxcj58uzP9P8vzn/rnf0TmDb0w8/p39+uonP+G/3w
# DATA Fd30Fe5n+M2fz39z9qVHX35nIDpfU6Bymb8CtPPL899UvPP/QM/RM7gN9Jxv6E1/ZIzP39EPwtT549lX57/WkfkL3fIHAfUAtuNY
# DATA Oi/AbAadMo4vUYfTpz+Lgmj2UZRQOGk80CZYzXvn0Xwi4/OEe8RI+oZsHM+pt5hY3gjdOWIVcR7lPoN8LpRMJmp8opdqmd+tUB0s
# DATA J6rwVEtxaJ3i/Eb3ILcN1llXMjeH18mrjrkVJl1+ufzARPSmzd3vy3ce0a+ZsMPjmhrWE7W5FYOpA+zsWGzXj9jB2nvE1icKp5K7
# DATA GNn4Re7BIZNFUcEwHdN4wvnIcvvZAjPV0m5ljdREEOZQSrxY4etcXP02OzTXtKxnhdm5OBmOs+MsgZuwBDRw54oGwCvi3Ly1wf9G
# DATA xv6dhv7Ljvy3M/BL9VzNh5zB8/y1rpuA8Vg5wCie4qvXpHcV5EGvm87VSqIqPMqzFC9V4JtIsiZTeVPxlAS2l45PF+MphyIHTDiD
# DATA dkXwqCLLFyKpI54wXmaJlVqopC+Q2wvln5VjcqPwOMGooFgzOsZ4gcBNeDilB7XFoM7VHeb2ghCL4PuBGXESzha2W2yQzB1jxzF2
# DATA HGPnJhk7u44qO01zdrWSb9nkv4rFfx0Gv6PtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqO
# DATA o+042o6j7TjajqPtONqOo+042s7zRNsJWuFVaTudUWs0eIFoO6trzzsxdzh3Ve5hV6bH72q3CwpprWYp15vtbpGbE0XdkQIb4XAj
# DATA RW/AgTbaLAMy4FADCYalMvxmuwjxaVCGr0EjdZpeM6h7oNv4rd7E79a9oF2i9rT9VqvbXyXlNBte0+/9yO81x83ucRC0pn7H9+o/
# DATA 8uuNcbNz3PCLURgEw2a/vyYRrW49T4Qf9EwiGsUAgl4wbK0SeyhjvWYnGKtctOg55oEVek77CvQcrrEWPYcqf4Ge02p2w6vQc1rD
# DATA aOTn9Jx20PY7Q0PPGXT7o2Evp+e02y2/e/P0HFXHq1yNzbjQEIKOHm4LN61zVDV4HKn0jk8qXbakCmtMrcH4cGfSTvltysFtu7bE
# DATA xFB34WjB9eB27BBXcTtqotk1xirK+JB3cozDYXJyUPfg3ah7uiQLgB5u16uv0G53Y5p3ZP2kkOulmwprZTKcl2A4hxv2A6yOVoqS
# DATA tM5TK+u2W0JWXY0a2nRDyWtG08TvYleq6jM2U3wKpX2BjVjIPLswVWL05AVWiKPsOMqOo+w4yo6j7DjKjqPsOMqOo+w4yo6j7DjK
# DATA zqtF2YlHYr9h3QM1/rH9TerOXTViqoFLfqtwXdw/fGJheh5LviEz7nIwOHVkgnmdngB+57PXXl99h6rUh3pAUS9ZvTG/RR3QoLvY
# DATA zj1UkKAPcYxLWj6b8pNTPp2j31qOUs379+oMvHUojQ+eoaypQpkoVPUN9MN3t43415QVxmY2SeXFqdri0SJPM/WOn732vnXyziSD
# DATA ukuVApnols75uCPo7gj6zkfQiwfC3Fl0dxZ99dTgRr3N5+GMeqmOF1qLLU7Dnj8WoEVlznK1FCV8Gw+jMCugW/hENJQtQS7ikSaj
# DATA 7kzOCWslFd5KVzotu+sZdE4C6zNiLGdxPiUJSq+CC3Uuenx9ll1E/NYcBlW7rFb165XtiirIn5QavBIO1z/meubmCm+3hfxnxOGY
# DATA 6MWZldWbVd6NQczS6PK5qPFu3WG6T/upFYV2WJQ43IkOTe5jcddNgu6qS+Wwvqc+b75bjtezyh1/2nwn97lKZnYQbb5P+m1OP3/a
# DATA IiovB021nLvYobaaO4aYLVruhZoA/7kt65r/Am89d3V6HiCfdJ6X86wktslufdMLiFXNNS9dcm78yz/+Z5OOcsSt/J+zRCn6nEk4
# DATA z/VX1VIi70lLl5BIgI2WsBTDDErwrEUNtdKYaiFDmcL5nOok6+tSx4zWR5PY2UKO/0OPdQH9I61Dy1rVvPihRWZPqHKrw+LK52W3
# DATA zPzks24a+cFq4zjDZZUUkzP66CVdYF8w1xS61wIBlFVbL1VEeUW9bAH97f/YXEC60kvxvIdioIqc6QL65CShNppSx+bpU36ZMkGo
# DATA T1rO4ImkIWle896jUR5GzjQ5FkEKSgMLDkDY4CjibhUFJPuHVTlFWt1CldbTl4pJwa2Vi+kWLlssf//fNheL6mKkVEQOdJCkNBkx
# DATA LWemJsJymac5fdZ0ZV1l+eTNQzSsoZgOouA7oj48OVFFVLQjWZqdzeLCOGhdjhcwop++lOwU3VpB5f3ypXu4324uKd3HS1F9GqZT
# DATA j3d35V3cCa4JHGd4DC1sKpkjKhhev0BfF8lwPxuKlEbE6rHQmY5mgOBICajZQD9icke8EE0O7I61f2bqxNOXT56MWyudpxmB/p9/
# DATA 2n0EeguDbJTKkGDpgE/ZrqZ4pQ+Vpc1NKpywennoTZc0/kzCFPvk5pBPRkZ7PxLjUQ0wZCKBYSDNBiX+9CVRiO6L0FT+Ydem8iAZ
# DATA Lbw+qn2I0sm7NYzxfcqiKbRsoBkzoJEHkwNWhA6HPw2xP0fV+AyFlbI9Hk/jCc4bIKegUkGW+ufLWNRqoILIwipSgFoR+hqaSiEZ
# DATA VyqgohEoHk3bCDRXJLvvfZho36PWFOLZh/IJJqlQGTFAJ9yJ64JVwj9Pww56NcRdHJzbudKu4EpznrNXxHN2WV73c6HuWNh/uR3b
# DATA LXNuGkgX2KpJFuURO7U2krufUxXIF0g07SJtaHvf401QvFdbybWzvNfKiG4ieq+mXN1m1LHF+YJJUM3zjSQ2O5Mq4jsSNciTxDgu
# DATA cieTovYph/AUUG4j85cXdMVbZoIvhSwgBYOdEZKErKyFvabWKH1urpO5nuaVtMA/hKdrdgRooADGRbfHSIFbyoIafKM0sw6MnCjM
# DATA 6lxU1FYS9dhnQhbrQkoL8x5Y3x424kJv87hQH2Qzm2QWb1eFJuosb/CiXahzCzlce5WMRzsIZz4683Fn89Gua24d1q3DPqXVuNFI
# DATA vZl12A+E+2krRefEw2dDqrgNSjjv/UH14mODhWVO9VOO11a3rqwX5gtJ+fLYprVFe3nDXq3ZdH/J0V5aStj0VMH9W/Bpb3qi7KYs
# DATA u1k3PVf2npW9ghtXTgulwJusEFNUp2E85PogC03ffUPLV6piUfeCXy57ToUlrs6ZatJ5eREch8w1f8+2qDzNvadO3bapxGWmX70D
# DATA RZw3FUxPCw3oxUWIY6FpwSTUOXr6TFmqycR+SzTX44nMONkEj/RMykAkqf2Y1aolmwoUGj2D597WHQn6Fnt49pRACE8AjMmunvoU
# DATA lrj0PbLuOBTXMu8rp5hAuBsLNOqJO8lqweXzxvVO47yu5XsLwfHUfRSVdKmEL2aAvzxWsgUHZCmkZFpgA/5nBfH75uzP9O+fzr4C
# DATA hu8rD98Yy/cNWH9/PvsSUL5VOuD/OPsLE/9+r+7+6uxrj0GBvzv74/n/dfaHsy/Of0nP/lEF+rVCCH59/itco9++Of+5R19AJBQQ
# DATA IMiEiIM8B2AhcwP/4mCAL4LVX+i7R9EJ2Q48iZ6HkK5VEAD06tMR5CP6kOzSGBDq+LAqe19hdZM+Mw9U99zXnZbus5dzfg2aEIdH
# DATA RsZA/CfRYjnfigC8D6kLb7jMsNmF2rMDABbsfd1L3Db/b7VYbo7+xxYWE1byWwv1rcwzvxOdRvM4ImtD3/+OuuBBZQgI7SS9Zgwg
# DATA q4cxEnq54PFfndGiJuZIgLsW4fWjAKmvwSI4tflZPEKnwzB4hjhju1yaPIKGTsRnl8WUh8GKWkid22CBLQxLlv6XHzO1+UTvPdEV
# DATA TVyqZIkz4wbTuPhotoIF3L1abrZ1Vhres4ID7p4YBwl0FsL1WQgaDXglw+DVcALemlFwAzbBTibBpS2C2zUIpIqWs8OYAc9Nq7oJ
# DATA JKCVarX8tSGKGi7G7ouHp95RGg6XoYL+ZfnqA2QMi2tsjBosLkqcyqZPLM0fs+sJa20si5jNowFGfmOK7QQHNOM6K3NTgjPZR0cZ
# DATA OAK+jCtgNRlVUTm5n6U6VPOgYovjs6FYDvDRMQFPxUGx1ZD8eUqXMl5LVaWtzDdZJOTI8o0m+2rehxEAcnJBNu09WMIMSZPl0dhb
# DATA zqiYFnKGnV+cOYygwwg6jOANYgR3HoZ2miRd1qC+1TnCVaYI1zlDcFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0
# DATA VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXxuqIJRJxqO/CtSBf1uEDXDF4gqWF6B3okpWITn9ZoWPK9TN/C8TjFf
# DATA h4OoORytoe+1A5u+18zpe+3exrzNC2bq17te4Hc832963Y7Xa1X9VuD5TZ/Ki64GHa/bLWH5Ou1et99dh+UrRJn3Ya7Gl15oIQ/9
# DATA jolvqwiYrEftQWfN80EQ5M836jkysbvb8w15pcqvVpDn127PN1tW/BtWfu/4/lbXQj42G53Lvt9v2+Xt5/Fv7Bh/u75I2fLjzd0e
# DATA b3fs5Nuwxx2zXx5RyW/3Lvv+Yu7Vd3j9ZSCR0kg0JFL6MgsSOeiEw45fhESaRwwkMqg3+q1eARIZ9JuddiuHRA7qw/pwZCCRzUG7
# DATA 223mkMiRP2x3RzcOiZyhP69mD0/zdQ45QnkcXcO6Q2C5OrTNxfaDea22CAumj7yMZjOY1q/Zw6Iy3A6mBu2ion1vhWLfqa2c3YiV
# DATA hYjqRQ/FRZQS1PeoLHm8a67V2hbV0LOzRd3m6V0txbzRs1bsky84WktAxy07FNR+BElHNaMfptEBRC83UxpNPlRKyd1i+pULubK1
# DATA vNiZYopM7MGVaiLmU7BLTnEIjgLpKJCOAukokI4C6SiQjgLpKJCOAukokI4C6SiQrxgFchXiOA2P7sLUo14dZ8woyXfkqz7JgkxQ
# DATA yMUPbEUBtKrX6WmqC+9iQ+Sev//6Z6/9n3+sMfHw/lqdAX5mT8IP53LYAG+kYPZNOAHC+d9fSDhvocXz8aVpOFuOQtbpl1Ndch6R
# DATA mvNcjr7hUFUoyIXoEd3Ihz/JHMhoaCsQEgtndNzpe3f6/oLT92uOcLmz+O4s/tOcxd+ox3mjZ/RFETHhg8j5cW8ZVr5r9DmfvXzM
# DATA bWh1ymgHGVUThREfkFVW5950uq8oibqFztgBkgv66SBMt2YuGEXLTquoJDmNZ7LuVVeqk7wKpPQmsd+Gf93MUzSDsl1VLhtvKxAT
# DATA dfuaiX3QWhf5wIp6txDxeq21OepmvLejri+qerQ3jI7SiKbqF6TACsukwL5mUtBem/0NO/f9YEvmb1To1K0ENVo6iBdVndMacZmH
# DATA SHem0pr1EfeC2Yd502J9k6FXxTiy3j/NG7l9A4vsi3y+FHeULaQrkScFz2iqRB4G39w/FZRjoV/SugOsX6FDo36EjEBlIGK+Nxez
# DATA YRhj7sePQUOYJTVOwlMZeKQ4eezPtLDG0TKkEWcRRSwNroQtPqcOjswvHK1XoiBrYrSDgOfLd2C9NCo6y9pZ1hdY1iWjyVnVzqou
# DATA WNWb2UrPk/JVsRWEJr+M+NUPwd8zakdYxc61jlhPBi7xitFvEnRxNI2zOUvQeJ8Yugob76ybE8EzdxIxmbXi6T0bGJWiOZbxU3oE
# DATA 9adsURcJjitiV+Y+GvrfjZX00ThJ458lRvJGKfiHXhaOwNeJUjKKWILJlEo2T3KFdJYoYtEoNYuIwuyUR95xMo0gysOzCbL7KsLJ
# DATA ECke3EujNQ2sMUwI7qwyyi2sIig1cGxV2DBlKNg2w0jH/X0I8xQ7QGydUKo94EHmHaKxiZazkA0bqlc17814lqAO0TMas6sNgVn0
# DATA aMGGJC+pIINUP5pkcFupHlaZQFIFpvwyCxS6zphYm7a/tsEIk+RIp/BjnGiWcpNqVZizxViQhfpHnIsVGe6CSHhNTpVaPvf42UOp
# DATA afm4oTdFivxrxvqvI0i1cyK0IilDTxkX5vFZMOC2kb2LbFuiPhI5L2kV0amSzMJIPZ9yFyZpFFUwkZ/t5+XBDsDcOA0XRjAsH48o
# DATA L6jCUhplwqn0lCjLsMt1gv0lXJVxhCa1K/RpBt84x+YRBbAg4zAeggZb895OuEli+DPKZBCBUwbjCJ1fasVmhYDEltWFuq8mLv1Q
# DATA FfbSUtA36ymGSWquyCBxKhe0yL6anBWf5x+LUy+9OFWYVtV5CqT6s7wvY2KB1Nwcaq9k9p/qfb4hT0zCU4UOL5oqGfWE1/vOgIdQ
# DATA xvUM46n0P9f7BmxTvPehHjuQpnk0G8ST630L7+F+R7cgvYRm96DX+76WACxGkdkzRA2PbckZtbbiu+4sJzfGoH355leOROumVrtL
# DATA BruJ1Es/kbosevb5khA2e3pvgmFazuxrJ5iuUTq+mF86KRAURAOY3ZBFXeEteN3nS0f5RZQQ3RG34BU2lmsjPJdblXwxk43ayuQ4
# DATA n/ZWvCMoNOdzGszCvBATYGy1MvPQAU2Bbf1YUW3FpClblGaluTeh5EnQ9rcI6BZqLVkvx9HFQtKok9NwrkEOO5XBmhL9KI3Yo15Q
# DATA w86iLNOswlfIdMsJV/3wYZQW8Fb//exLUKfOf372Z8Wg+gNjrr44/4+Mq/pn7/xvgZk6+90q3Oq/gFbFQCpwrH5+/vfe2e/Pf3P2
# DATA l7Mvz39NgX5V8c7+F93yJ/r+S3z3zr4xoYGatRl49Utwrei/jmn1IpBsqQ7jeTgbqIKxBHbIuGcZIsjainkkGMI1Ably1TlhTiYu
# DATA jRk7LbhfGikwz1AuJejjZH+tMPKo58jY07UVYfUmNtCinUToLBzAyjZApRO4bXpVuURujl0FSehh6b1rkVVcxcyNb3OFuxlYFY16
# DATA c7XpF7UUm4STYXjK+wipfjyMHLDqonK7dk7Vm2gGXALzKMVZUVasx3G8EQO25fSlR7Y7tEzUKoi1BU+v90Ms/yiNhnEEbzQYBdSn
# DATA Rim8XflyiuoX4xmZQ0vJYW+6zKQ/EzPsVKjeg3gerVCsdqmpm+2ZUtN7VvSqXRLhuFXOCriyFaAxVVcY/F8Jz9MtDfzXPu7vNOzv
# DATA Ourf1qAvlbGYejPIP6vGchP0qWISvXE0mcM6IcMDCGYTuTzB6fh0MZ5iRVaSfiBDLYTeccJlwR+Alka2yOoodZigGb1HBn54TONk
# DATA prMjFWkz3nqANdl0yVqKFP9pbLhA29lTancEPEwRlqgjPtMlAzHHfsNgLi4OyyBgPBGPBZmYEFW0/2HBvOB9gHoThUIB8UtYQAGo
# DATA KfoHeypg5+k18uUigTzUgEldDjDlAFMOMHVzgKmLxpGd5jK7m7q3aLVfxWi/HpvdkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGk
# DATA HEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJ6rkhSbUbzXbQuSJJajQatYaDF4gkVVx53okjZWdK0PYa
# DATA ne7n1WbV73Y9v9WsBvWA/vqeT/80ex59LebQIOr2G61VHlSv4wWgPjU8v96dVv2A/mmqryUQFGVyfdBfB4LyexIwpT+mgVujjxoW
# DATA eqnRaltFrzhIAiUqgquiZhi1opWINju+F3Qp2S3PbwTTRrfqN1vq20o8o35/tDaejdX6VW95zVZr3K77H/jNwGt2/XFL68VZDKxW
# DATA M4jWBblaY9tNimnD/1GvOa17QatK//jdaUCvoWLp4nM16NKX1R9KL+12241gsOWll0EdSQvRqCNpbBbqqF/v+MGwiDoa8f9s1BF9
# DATA DUf1Aupo5A9HfT9HHXX6lFWhQR0Nw0Gr18pRR91mq+63bhx1xDtMqmx62CwhFdni7NPHSOjJf6mZ25MBm2kkM4NtkB8eufI370Af
# DATA Kjjh2sYJJ0tvq4AiK+xVhzyPsLJtjh6KHu4KJ9KWRlAOwLvEeL3lse2D90YIkVWCti/QExN6c3pKhdtBqXZU0RbzZ3NyHEnIkYQc
# DATA SciRhBxJyJGEHEnIkYQcSciRhBxJyJGEXnmS0EhxhPjoFSW4cnJ39B25ND4dyuohYD9k3FQy81MWskXJV0/N1dOIemR1WdOH3kW4
# DATA TBAavU45dMR8oE8phnLxpAgiUr8/oOD552ztz+/NIIoEY4Hex/edrr3vk2QRTuR8H9/1QbgY19hvsDd6/eT17PVTdbPNGcpPsrij
# DATA 0u6odPGotHWuyR2YdgemN0v5PQcHqXEmdZRX8/DUC/F7Qd58wconUp9RAkYiHPWmgp8hmzeZJCfbz/pO40d8/HieJslInz+Gzrhp
# DATA qDT+YivKMo2yp9A2pxExPUVSFpQlSJ8+bnnfy5ZzdKrRULXoODPkI7JsFNgopQEPtRNyepN4gUWchCYPGSthC8hkkC6n/UNow8Qz
# DATA Po+dmUPVIzh7j/n87qdw4RYUTFLWdBcF7WyQJPzEYDmHzLaca96moP0WbIj0VPbReTxE5UkbQWQdKoAIkkt1FkXDTHdnkt5skYq5
# DATA TOU4TiZDPuuKmFNiaQ7McuAolRF+O6IoT05ZKNxkmyk7UdZhmXScSteq6JwGTOQmyQJJp0v95GTihZMs4YPBWyXC36XqzU1Hjm3T
# DATA W6PUKjwWbO6ztcnZpW+OM32K/gR1Ed0zi/tMcL4X/XjNY0X1vCcfYENKBHn0eMInc3E2Pqt5b7FaM9ddTwNqUB0o8ggVqQ2H2AjE
# DATA YZljiErVP1xcJOrOOcdxPqGBxOgKYjsqzr97OEqDl1HTCaf8OhrouHSUJPxguZDCxbaauToNLDrx5rw3rkxiReFCtfgZZOoZjpMZ
# DATA RfOHEp74VzhEMg0ndpbE5jx3mE6vpmv+pghRI+uo8V9a2ByN8LqVzT9G5qPwRnBOS+90A4LmOdtSBI9QFGyIerkewQ1omhtlRjZq
# DATA ZqrtoZvFmHcDEuf3uds3tpJSk7g9JfCX5yB3HoibUbgZRXFGUa5SblrhphU7Tx82Tj9ublrxAFmR43AkOnpK8dxrA94GolQcaXSZ
# DATA PV/e3tFFWEz9gOmwzIWczlG/CpC0vhnrmbv26Jbv6y/e3rcviqz9oIlw4WJO8eyui3OzZUW5tytBlf2NTCiZLHaIpbo9R7yq7wWT
# DATA aiVqdmY2ioTULVETpyf9XPBK7hBJ/aCJpbmQ27W1zkURDbZFdCMIVeavGK2slvbi0lClqcVZUezIaJa+S30LtQ7vyMzFK167+23P
# DATA 1FtvSiZ15jWa6p4T+Kdplk8T6egoRUfJT2lkFqbfws3iG7k74q9Kh01mpgZyGrNabTwwXR3eGD2SNRM9ZcAyGCb1CKskZcbyXFZf
# DATA pgVsM2GVydOyCoFJfz4tkdip0weRVkHbgXL68tjejr7jbO/t3nxnaL+UhvZlKTvPWAiVdwDnG2RXDVAbQsOig6H2YBu9UEnCZgrN
# DATA M5VPfSFkBfm/18w0Kgm9XjfRaEUqdy3PaAfxWmsfdS5hi28RhCuTcFQxBB22spbZWBlYpXqKneJSsmq3+Bvjxr130xjrNtilyF5E
# DATA ugRGffwINgx7/+U8F9MO46K5QxNIzAKjdcsuSlVThExFn1QdZOAtXMrkKRowNC21PKrGajHRteP9AGtWiDnZd6WYi+yuWVSh2PH6
# DATA hWkTojGql2UUgxTHybA921otYvlUXnrCWcQtEUaz3zG2fKxtljD9l+P7ACtBaoFOT5+jojhqWFzY4yWTiVn1ozgq+CRWILAItjmi
# DATA 9LJ1+frKaHda5CAy3Abg8FjsoH84+/Lsj2ffnP/i7CtAf87+cP4bhvqAHvQLZvj8nH4DXei3q/CglYfP/nz+G+CGfnH2l/Ofn31x
# DATA 9nv68dfMIPq64tGnL8++rtITXyFoj+/5hu6hdwhaaCNMiELHW76gN9CNDij0/FvUP4R+Ga8Tc2+iaGGnFVkQxCXpaNXu1DQ6An9Z
# DATA yznLwr+qr2ZwT1m0uUCZpt54K0PorXEoqgaWZLjjCFnWteoSbpsktK5cbo4mxBsCxsnc3PipurCeKTSK82763XhhPMHXTBMSqDHb
# DATA C+Irsog+rzpHaJcSu3aa0H1PwOsAgVcXy35kSl48+DH20E492Qle8z5IqAbMDAiRCvEYeu+Q9MAaAWt4wCwL1WaXEJ8nsukjhftw
# DATA yjxGcdax8SWwRojEluFB26vkZiNmTTt7Vuig7Ulw0CA30l9mpNecoCsO8K+G6+y2BvcbGdt3GtovN7Lf/MAu1XI1B/KNrrfXWm4C
# DATA FJSnDCJaFEC2GucFPG7YrKk3/+n4Lk3a+ZAT40R0AYIAE/PvzDfBEhjTVtSWUH7LNJxR6jKTbkmtCV4wQ9M5dWGzxU7YINhXCxzk
# DATA Rz5QSKOUert80I9luV8vbCEYFpNjiJEhAKWRZJVBIp8KULlijfQJMD/JSNDFeBFVRO/BAsmO2eMRjzxqVQ+FhnJCHQX2DKIN8gaD
# DATA FHmnHaKOHuToQY4edIP0oN3GlB2h5hfbvLdsvF/Fdn9a092xgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvI
# DATA sYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvouWEHRfVRfRRckR3kdxuDVv0FYgetrjvvxA86MknmXYRF1sywFQ1H9U2smXtv
# DATA DOIU9r+AfQJJiAL7dFikgeUNfF8Rhgq3t+vNC263OD8Utkf3ePRb1e/R3zr922t9n65P/F6drrW9wG/StXa106sGzWDc7H0QAFjU
# DATA 6Y47zanfaFWbrXF7XUyawaaIK4DRnaNCBWoGPiJDb5hWfa9+LIieLdkYjfq99npEUn2lelKcW0F93G7WP0Cqm73WcbM+bdab1Wad
# DATA PpURRL2w02+vCzq4PA1I6rymAUnzsWhAlIxBp1GkAfmdRrfZs2lAQb3ZbQ0LNKCg22q0w5wG1B8Nm8OhoQG1Gp1+N8ppQKPRYNQd
# DATA 3DQNSBkl6x0fOq0lW0uNRNi4Vt1uhXh0M4ad/N4y+MdMlNZNirQbDXPdSrPWZP5PwPyf1fWodjFS2rixummxXTghlONhWj3C1Bg8
# DATA i/owOqpYa+/2Zy/ozR9VvtWotzrtPrv99iubQ+pdMigd5WweDS5LJdI2L7yHKyaVtSK3eXFcLYWLT7ia0Q/T6GAYpg83s4fyHK7Y
# DATA Ud9sc5TMXqlDbDs5kpAjCTmSkCMJOZKQIwk5kpAjCTmSkCMJOZKQIwm9siQhRfr5xDrWlZ/nLp7jKmN4hBskp7wpjzRdCDsC0IxA
# DATA 5xlMawzzeSuZsgD6yiFvPt6GpSRRqwpxUCWZqeNrWpC2eFBM2qhM5PRJC3fG2Z1xLhy1cUed3VHnKx513ig+eDNHoN+NWeuCz9Ky
# DATA C7J8elYfhX7e5DZuQ49bDS6oOlRflWQ4Urk3mF4k0WyeNR1WfsWINHfXanO3bJFm368XZZpbW6SuefCDpIvqvfjCG2LLGhVluScX
# DATA uNYPvZFwZ2pLSLd5uedj6vsUXojryRt3EiUSuOaJNmcXjS3eHW+RRg9ZK/LCx1r8ItsMmMKgYfnk4rN3JDU7CFW/o+snqqyHKvvi
# DATA qlR/EIXZEqLROFg7CNNcoPrBQiT5qCdJkoXcIMeaIesTHkHsGf6oExqzat4PeXCbRMdUadABolOdqrC5GSs4TZIa4aE0IXOy5n3M
# DATA CwBiGskDrLeohP1oODlFQVNBxIuCfDVgWoVj+3KO1EuXOOONI9chDthDw9GM59APJIuN6iwXfkazs2U2j0T/kBWzw9lyhIE4xVxK
# DATA AgQXaRiPRriy7LOeeoxxmgJj7M46W0+JEFASFjsLXL8s53ydvLUzXy3z1dmrr4S9ellt62cs2cPr2vkC7HZt6/s0GrHRyAYk27FZ
# DATA LkXBHIVsi8b1bYv9vBB6Fzcha71ar69d2nqtptNV5a3zRX9tjolFoWyfCGRRrnO5qDWbP6dk0ghQk5eC6HU1703RDaJZkojVROEM
# DATA JsqnEBESuZcMgxtjRoXgyNUNZhRZXbEWfiYbLiGbh4y6h/QGTQy5XMX5gRZiMapOxh3+aimeFHLGGUPOGCr1qc6b57x5xb5zoxX1
# DATA jAUNmQcMcHEymYjOfhnYrdpJmOUSfjXvXeF0s5W0Tp6voOU3T5NBNASNW6TokvTzZSS+nKfhc9+PDdTZ0HgXNIJqJuA0XghqWkZS
# DATA j7VcOAZLbuRH4fKIRs2PaRjWtMAKByBmiSz3KLwDOoxwNIJTjF0lucvTjNPvzTDeL4Rfu1S0iGjaj4YQQRtG/ZRGZKEi8xDKIoDY
# DATA obQVZS2jfy7PKDjgkKoC/KCsKahMg0xbF1COg78mFWepEp8mG2A4ifphWvPeh/2EaFIlpcwNFQhsGKKDARKhPxHhtTEL460TMuSP
# DATA maVaKC7ZDNTrz6ng4xF03qYR1v7iwVYY+ZhVrbnyzBbw4LAX2ST5U0A5ktHIO6IhSydR9kl6kyVl6iCEYiPXY+DVw5PwVBxTOp6q
# DATA DDPt1uHs43GAglExp3zJRIEb/iVW4T5UsoaQwkz5ZIGquKY6F8AaC9Qf5o14fYpAtNHrrFLNI42MLZAJZz54LlQNwSnTssiMSSjx
# DATA McgkLP8UT+jnivZDcQJy2M4gTNNTVm68T3kWst9OBSSEeYHHaY7PcciSfHkmfRjFnCrxEyv1S7jkjpJkaLnb5a0JNTQaDUfS1opF
# DATA eDXYN9ryKas+Uh/z3UvDvhG364Z9i10eSwNX+oXxDOD4aHgD0O83wbxXcqFq68gNML4/LamQ3sibGO79PpqG9DE0rsm2nEyIOdf7
# DATA Nj4F9KmhJGKFaB7GqfcQ3uJwNXU3SRR/OaY6FlwmCdPhEXzrNl7mvyqMzDcMdQEd5kvv7Kuzfzr/+flvVnky/53u+8PZ7wT5wncx
# DATA +QVUmG/O/kQfv2CWzFcVz/Blvjr749kXwNV8hZ+q+qmvPPr6hQ6KbqMX/vL8VwouQ/E4/1uPGTO/A5sGFBoHlXkBMI0zzexa8cXN
# DATA owQIaDVyL0Rg+i09XxO/xxFv28Ygp6BhrN3L8sI5ucsMfBQ9PRQuZ8OtlJn7fEv+ZseYKczmTM9w25SZ1XK5OcYMJ9Dc9T0IiVNe
# DATA T0bl+4bQfjZAL+z3XaTh6XWiZagNZGRjpyJgTjMNWGM8E0NBOLjM9qK6dqqM6YSGMZnxfGJPTB0yX/EURO7jRx7XC+9j3h4gbtsj
# DATA 7I9ct6lc2IfQaNdK3yizWbRgTXPs/aAxPFthyGyreZvtlJU29Kz4Mdui7+gxbkh/qiFd42SuNJK/Gj7Z2xvFb2AQ32kM33EIv+kR
# DATA XOpiOdn5tsln2GJuAilTTmhOljGaE3nMKTejUCFm4H5juQF4umZUpJms1iIZhp8hwyrQE8dxyrgYFJbGylDKwwwXcWTcEIWxGioD
# DATA 6yUgMqewtti3KyEeyTYzTBPoY38iHrejNOLzAJLtequb8q3T6A8pBP5+IY/kEOM/Z0lq2QxFzEiUOliMg8U4WMwNwmIuGDN2Q8Jf
# DATA aNneqnl+JU71Uxnnjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j
# DATA +DCOD+P4MM8NH6bdafab9SvyYUajUTAcvUB8mPKa8050GDtbGnXPb3XGjU7jOOg1v0/fiznS73Q6zeFqdrYCz+/WKUM7x0Gz/X36
# DATA XnyO6ma3r7gsXJZSVlJwp8JhCQq6Es1esYybzVJE+lGvUw4wCBpXDXBY7wWd9kqA3eB6Y9ho+tcbw6ZUneuLoV0oVJbXkIdWoVwy
# DATA wA2lbBXKtcTQLpRriaFdKNcSQ7tQGhL49bWUSwZ4cUu5lhjahXItMbQL5VpiWCiUVvN6W8olA7y4pVxLDAuFch0xLBTKdcSwFVht
# DATA uVcsZb9RClFdSFXulwf/dtQoobjavWbYXAtLWwcda7UaFnRMwk8NEswyUnSoK/y0oPV0AbS6PSuAVu/yARSS0Gs/ZRJ2C+AyPDOx
# DATA 0TTPTMw9i2cWNtvNRlTkmY34fzbPjL72olGBZxZ1h2F/mPPMOv12u9U2PLNhe+CH3Zxn1h00w+DGeWbK66E2NJiZkDjjyZZkB4Xl
# DATA vdCL1GZ+1uWVyjWL/sWQyxyz70VkxMZhRWJS2ouyJjjbEcmLPMXQ1brvxdEw05f1u+T07TQ5Pop2Wypq7bI4bYVaXnW2fSa6jhTd
# DATA zoFM5FdWD/2GtUis7vWDohdGV1feYzkOh8kJL8Rgxa3u6Tpn5W2PHRY8KzazuQ376fQkVuV2fTMDzc7TCzwaVm6V6iRPlgMHQnMg
# DATA NAdCcyA0B0JzIDQHQnMgNAdCcyA0B0JzILRXG4T2WNXumArurkKZ4TMlusJJUhdxdA8ZIbeL6uZd6tiozuyhasV364fxG/zEYfz6
# DATA 6/uPcZFvO4xHeyfxjKwrssNO54vkuzDiPwYUY/ojDmf/sW5B87sMWmMQyF4z6DV77U7Qa9/hKO1/h/+oKPTvwgb8Ic3eG4F0vP7+
# DATA 4TB5LO8ov2Kvv3/4hGUz9/o/rv/k3l161/6hSL7hwrc56Nf9wycRGetKC86Ki/DfOMA9FY99ulupj86XNOqpbu+JRA+V4676+adJ
# DATA PNvj3opyEHw4NIbX1Y+yQLu3F1b6VBzh6/0KWY+5Ja9SO4nvbrRmJzEKZhLbFfKuNA8qN3qTpI1mjngt2/gyI8ABcrT7ObYSzIZ7
# DATA k3j/UPKo+DuvStPEXXXF9/z6fvEGDMEqPm/h3pqcnqbK9kQj68zRT6es4pRVVpVVzGFgp67i1FUuqa6yURT7BlRXPoYcl1YAmSSs
# DATA 98GaXUZ45dkKed0GnY5NAboqniAvGXFiLsDSqYfyHkl9L6jJrhDpfAtI17ZxdP4WGB2bL6j6+ID5B4qiBKNT9+QwOv3QCiOuLUE9
# DATA EhNpM0uOx6R34F2/6E5f1IDJAr3oRlbY/eQkmlAnesG9QV3dOyMTuHTv7ug6rt5o5VyiLyy17q81o0HGo4ysh2hopPaMvA4ZWUYW
# DATA R8z3stQOk+R2k+1hERsvS5YpWL4jwalAf1usRmg45Hw68VqQkThTMj6UxFNPHbo3YjH0zhW1mHHjnq3/Q2lqUMFMdKGwRWbnprVR
# DATA V5XAZCfa3MugGJKPJc7odEbnqtGZWxfO6nRWZ3ahPfnMtP4eMGqII8kubiBHUf2N0WmAZNN4kCaWBN6SLVSlfxdS65oNQLdY1b4z
# DATA g2LeotRgqCElLCU3SKbTKB3EegxkyzWNsNKCjQs7a/9xyub3Hoi3qn8Kn1mEXSYYRg1ASdi/NJhiL8Ua/S113m3VRFXuWdRE/qSM
# DATA U2Vz6B9zA8hc4YPPQKdFHI6Knyw3iOCgjvxa29P4fMEJUp+Llqd1h+ko7adWDDs4TdEWwJqS++JtdqA2zt9mA27TXYMExA1qLsd8
# DATA 81v5183PcCXC3R/hwxbrUgZmbeGJC9U2STBIbDHvCiWMPR/SoNXRzhzpQJ2SYXewx1pWd1Re2nlRwgHxbhjTzsUZzLUpXfLtwb/8
# DATA /P9um1SUo61yVpliSqqSKki6OBVjjOw7HpnA5NGWJA9CNO2rwu4a8nzRuz8cQhqPnhYW0ACNjWo/TxSZnwz2Ch5k809GRyaiaGIy
# DATA bFN6S817M5zlVMDZUCal8tO7IMLgJY06DbKGEqSPnVwpX0u15wrZ29ycvYW6KLkMe1lseErIIpzofL7PPBkaJOYVyTU9seZcC7EJ
# DATA YBFPIxvKNp8sefZM88ulWPRMQFIefe9+PEVejchay8aAVbHpjUt+gK/zJGMTvea9A/giXjOMs8EyQwFxSLIoeR25bNrbZfN3c96q
# DATA lqtzFT0+db0LfNB5+jb29oRe4//8YwOspCHlCRYPZuCZnwAfRHVrSXlHZSFT/MzzqUB7cFrI+ssgojlIzfuIumyaet+Xii3VFwQo
# DATA 5iTxeUUP7o1D7037DpwhFHcJz6TVJq+a9336GnFFpvK/top85Sze3kMUsvlTGmhpkkFBpDqPjTk7ooZfFT2nnAUG7UCqX6hMc8lD
# DATA WfHJpC+Qu1FJ4acJFXocE0J58ENol+JkYMa6paEJJJxpKFVFXka/YQlF4saZfhSL5Cl4ZMdxQi1EPRxKz/N8dB7tS3Ue/24Z88qn
# DATA Hrx1IUgGU/2lMQ4Vmysg20DaMJLpELLdyybxnPKTGwf3LQCd8fSmz/qm2iMIBVWM6qLEyl2TdxQtpOg4C7GQmCXTCBeOlhF3HHg6
# DATA nslEhfqlxbV0Hzc/+L3F4xKYSLGp2qZbFLfG4iSRDlmyFr1xJghNEUqO4pRGtxOEousxy9jGRuGXputo+qlq+WQLsqoz3kldE04r
# DATA Um99rCZ3FDaemCZYyOW5A3oKxk5I9wKbtZy5RXNFlo1tc8Vckcy6Rw1MLfBqIWEZv8VUtMxXam5jbnhSKLWLWE8vg8sln205l4tz
# DATA uawhKDgvy8vvZdnoQHmuiAqFowKrI+XEZi14k3iBI86shMJITFAs1WjCLpj8QT5Pwhn7rBEMz7NW+UX8JOvgh6xK8tGXe29QR1pu
# DATA b/roe+F4XVfO8lnn8uVCOJHusIyTWDmSLu13kKB2yNtOZwMdFaXymPvdbDF7Lo81YA7rOf7C6VErMePg3gO2yU0VAQQ5nJ2aVavv
# DATA JyfAIZ+quvNdjy8s4Z0iq+q73lt0f0SdKYwhGCG5JfxdTMLiKVe4WXYis4cFNtp5vHTM+vuxIrpqNhVgtCHZZuDjQruMDK9+8iha
# DATA 4UUVa8u7MQMz2QFJ2bEcLCiRUuyvwpKTzblMmMdtUy7/C2Mp/yeQk+e/9UCkPPv92ddnX6wSLkt3/iUHXuL+inf+C7r2Ff33m7Ov
# DATA vfNfn//y7Es8gXu/wu1/FAQm3f7N2e/P/xPglR59+Dnd9ie51XEsXwCTzcvY75+qA4imr0eieXLOPUHNk93yXraUCatsyGdurTzI
# DATA DRhjBg8m7BGYyTRqhAkrNzj4ybC0MObN81solm+KDJigMhzCsmjCSaO/bYBlqUhujl4JO+DY6u5VxWMKuvxUfkJVQfPEx6pKogrO
# DATA 4BG7VqAl75YYhxn7a4D+UY5yZcE4qOWuJXjteMv7sEuPxFYx7OgKd5tDONg0IMj0WWJovx2PRvEAG/KxbVl23ESaAa5vnUUUBv2c
# DATA irt/hWi5Ux3cbJYUW9ez4lrulAgHuHRj/VOM9Rpvefkh/hXx0NzS8H7do/tOg/ulx/ZbG9qlWhayIcdcPrN2cxOQy0IaMSUPiwnD
# DATA tlJJAIKdzhcyFM5TdD3g1I3DfswLf4tMlxo9cXSEBZaHVA0ymcdTPVbL3Jhuy8hsRuBJTBUSy19C+Mug+JfuirhENhomIKYNFP8J
# DATA dfU4w4Y1EIV21LHnba8rWElVk6oFY0EWhDiWLJGCUJCHyACsfGbVeZRW2aqjElhOuZc9tMwE3IgoV8lg22g2OAamY2A6BuaNMDB3
# DATA HmB2mslcwh6+PdP+Kpb9NRn2Do7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O
# DATA 6eCYDo7p4JgOjungmM8NHDNoNyJmbl0RjtmLei8QHLOw8rwTGdNCvfmtnLLYKFLFOqUMb8jvkuNFZFmz26531mQ4sJvtYNxsTqvN
# DATA pud3x4I6s8BjZRpZDh5rrEDf6lZcS0i1lbjW25vi2u+3u61wJa5BQHHttq8rrj0rrp3u1rgqmN3auDb7Xf61GNeGX/cCqr/XE9dG
# DATA 91rqQGfQbYf+Slyb9eusA83OtdSBYScctlfra7N3nXWg1b6WOtBpd/ud/kpcW92nrwNWcBRas90Ztxv1Y7/9/W4Jj0sd6qB1NYgd
# DATA 9aUaYifdsgWxa7ap2+juALEbjlpFiF0zag7rOcSu1Wm3Oi0DsRt0B1F/kEPsGr1WtxPcOMQOe6iqsrqhR9emxa+zaHVdtjnz+y/H
# DATA pSs7XRv5UmtbnK4cMp9T2c2X2t7mS9VzwjzQ1VUZ5WvW0wxMFNSUq9daocPBp4YFJ/lPg383XLh4RnXK6woZTipDs0inU7VmHWXv
# DATA asQ4WTFQi7hri8C49sr+go2wOasEttimqzXG8eUcX87x5RxfzvHlHF/O8eUcX87x5RxfzvHlHF/O8eUMX47VGxVKjn2elOjvyFc+
# DATA vEdf7+hfBTTHxuZnr72jjv8NzUlIHNZjkhkz2QZRPNnj0JmsJvqZWe0z+t/s/gK3SbDqBwVgU98YDqPDHdKE2+MTPGsCv1MOhYOx
# DATA Hs14RDC4M6eD6A7abz5o7w7Yv8QH7C+rfvjcHLzPHVvb1RBZ5I1Ps85ohCLLAgLLY/q+TQvx2Z7Tf8FOrF6kvpM7Km9CG7GkQnDN
# DATA wohlHYcLVBHvK0APiyFQrlIbyjgwIy300RLeGN7B4B0tAQXrR8wGCy3Vb+ge0GQd47T3Ll1NIHKv1Q9FJooRDUpdgeptogWc5UQ5
# DATA V3Ul3oDs5zPlOIfelwqBp1HnokdzmVYolemy6uFWJaVSk4P32oZfsOr2g4RGurE6rS6bX7X49och5BaNTH8anYQpDtQrQdGTcCJH
# DATA 80NVQb0JEsKcBHagx2EqwhQS+eJ56EXIIqk/WC6QJHMIuqxRvhpHncuG2jCTkmCKDXcQ2ITh4cswCo2UepixSoMS1goZT8On1ePF
# DATA lui9B+rNJSKHXsREzBLS0BUJApgZFX6YKoBBMskUj9HQdDiY9KF3gl6I44vT9lsi+ZG8Zk0mvkIn1u1QnI3sbOSyjVyqVU6WyslS
# DATA XcU63miN35hc1fdibgNsJIRK6Ekr2FCOPbS0q25ZE/E24MDi3GEIDqzHNELOQaVyOx5YP2Z6J3MhJ9w26xchght1MWR3oASL1wnI
# DATA XuNg4kvsEsLLL4iwft5E2FzII9xaH2GJo4qyX45yfXOc2TVmV11UrT1+8R3xTO1fmM1FCrP+nsc5WBvn1lWjrB1mdMMH631uF8Q4
# DATA D8BE2rpk5fXaaFuxVtVHR7pViPNGIPKby3gytEY09BYvLhf5AxmGZXQP53z0hhew9VzKgJO59+JTIkodSpI/poci8Ljue6PohF3a
# DATA 7DheGI8qdLDWCMkfpSxUZ8b/WXSsmVdGAuyHql/XXSGAayGw6Ng/ywZ5zfv3ZCkMed5DPaPVzZLZP8TOIFFd04xMcWVLR8qNhVIk
# DATA b2bTA1M6mmYIBy5ebJqyvcRGuD26OiPcGeErjuoVa8vZ4c4O32ZWPz+ysWqw082AfWBoC7YKPHA7NFaZVnicD3VKorSSq5jyUGME
# DATA TqHXib1VGHUQ+FwkOzG8Kici2txIgCjZMhbMjBwG2aS5emV6cv5SbtiQwO+jUuhZBI3OQ8dP3oWfPGMfKp4Qb+rmO8WdLFMIfNpC
# DATA TtZuRcv5B4rt809QznPjkhjJTzYjJHW+CkTyfsFzD5c2VRlAadMIxVQCpqbREeWY8c+yH1aQWPSfEebOSn2WamTGN9Jts0VME2ZZ
# DATA geC5cs17K0zTU4iyJrOiezwNmdnIVusiPVVeYhZlxR7IVCIGn3ky035yNXmwG2m++qObSL66ZPZAyii/Jfkmf7WKIl3gzb7cMEMw
# DATA Ts1M5KlYoXlVvmQxv7O5mHWjUMVsnP75kozsteAeQxf0++hiYeSEwmRNyWLXqxyZhawXLQBRiualFwk8myQnk1ORhE5Z2RidK8Yi
# DATA s9RDZc4b+NBBjk2v+FRFuD1pt1aIhV7mkuX48RaYcd5f6RYr6BElkZxGYLHSkDMbKjFwLklNAsvb6TAOaRY4ZQN1FC1OaTxdIo9j
# DATA 5bwKdUtWuDEzmedFFxpdcz5aZpZwaPB9hBkp+9zYA4YFwliAa0/dNrcl9NbK9cp98IOd+2CqsAu6Rei6kTdj9nb28HSl/9VsGylW
# DATA WDUiNM1Gxjiaxtmcta+997nHDNlLMAnTI8hKQ5lxlmlO/UmSSv8qbUU611EIRDLcAtfSLten6vnvVr+/c7eqxi6yryCvj6SGaqAa
# DATA hppgbZqkrHuju0y0sSh2KLwtfDoO4jgoSsW3jo9mcPXIRFRbmHCssDQ4jM50nrJePfW6Uswcj+toezsk7IXoWt++VNeqZd1hmAzT
# DATA 8AQNhHcnTOKRtVCtnGv6DmU9RCG2hVLmQPZe7B3bnsGMhgtLmzyD5aLmscvPrGWr7QGDNJwjz/lIqN5PoT1kT1euW1N4pRK9XYD3
# DATA U3loX36fYo7AHEQ02seDrIjA/PL852dfnP3p7KvzX9PnX4BnCWzln+jPL8CxPP+5vrgOi/nN2R/p/1+efX3+d4y7PP8PDMX8kyAx
# DATA Oejf05VfMz/zayZneue/Ov9bADTPf8V0TAr77I/nf09B/Ir+/pbeSSHgpl/QD3+gn+mef6KXfHX25/PfOEzmC+EoxbY0dFeqW1Q1
# DATA j4PODsQXxUNYn6YHFf5+hM3u8KIOgKxToJbjkD1XoZkiGJ9r6MELNxjXvHcezScwX6gzRWEh1sqgydWBt/Iz35rQ+CUtEfFzBE3b
# DATA h6r7jNsmaK4Uys0xNLlSmruwtZDX1JUHcIW4SVU7TsztD/irB9Gu5QQiYdcJ0IwziQq8h7KzMcKZ3xD8oNNo4eiZu5TdDZAzeZWU
# DATA V8vjKaa6CM1UANU9LSI+ojZAPeZj/d4HUZgt1fIt5dgSUCimK6DkqK80vueMOUPeIp5EymWdsr+cDKThcrKK09ytSm62dMpt7VkR
# DATA NXdLh0NqOrvgJuwCzdq8ijnwSiyn3popcP2WwE6GwKXsgNszA6RelnLBxm0+b23qJjicpeRzouGmZnahiUwZvqkVivPMOYYTY6J4
# DATA nPZBGs4tXno2yn85gE+/DZkhvhyNr8weRosB/N674jjzEd+yGChyWT78T8VOGGJfHlSjoFBD8fUkRD5ZU7AHeOGb4pYMq8qPj3ae
# DATA ZbyPzOM9XGKLaKcijUpIrvijFK2TN0qw2yo0y2gOvenQmw69eSPozZ3Gmp2mQJcxmm9zCnCVGcB1TQAcetOhNx1606E3HXrToTcd
# DATA etOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3nxv0ZqPVHLaDq6I326POqPsCoTdL
# DATA i887wTcp9JiGRW8gMmM9zsvBqdANe3nGBk3RoeJfgnaRX9gbjqLuai6DCRg0xn7Q+rza9Vq+F/ieX+/xn0ar2m16ZB9Xe41qq9rp
# DATA Vf2g7QW9aifw/A59aRQLo93ttnqRvKMY56AZ5HGm9+Vxbgd5lIUsalWMVqMdraIsOz3Pb3XG3e6k6tcpep3PexTZdqMa0A/tbtX3
# DATA u9VOtdWq+s1eqbb40SDyS8zDfjschcE65mFzXVKaEvuBinHHgjA2raQU6/iwOxj01xAZ/a7XCLqfd9vVJqWk0fPqlKau5wf1z6tU
# DATA Fo0mpdD3SmjFMOo022vj1up28rhRwFY296yaUS/SIv3moNm+AqmRm54mNUortkiNFJdBbxdSY+EKSI1B1I2GFqkxbA87w5zU2BkG
# DATA w9AiNfqtQbdx46RG7G2vbjNpaMC1fFxiG5uHtCVjQwmRypFfmhE3u9/28C+ZGh6bG3kQery1lhjlVzYnd/T6B1b81s4lOEQICts+
# DATA /zru5jmINk0PLQO84ApV5X45sKK4v3IoZClPWpQn9G9D/i2sVjVbBhvZaX17LeFRjEVKs8z58uVSawFrPcJxI6rxwsqg7cn1tUAy
# DATA JbCLb+dwSkXDs9jSZMhxIB0H0nEgHQfScSAdB9JxIB0H0nEgHQfScSAdB9JxIEchGvddvyo8Rdl0DPgjWTMa+fhAn3c/iZQ/k3GP
# DATA ewoXiQt4QoJCVX0XG/32fEYyDqbCfiwEouaqVihy5eJgREQW4snqOL0ctffmcTSI9GlEnJGD/7CP8ihyIPOTN+50uDsdvvPp8PIR
# DATA LXdQ3B0U3667/dwcIH8QP5ImVKHxaXaKJf9YDlna4Btz5NESTUWTmcihTjz7cPXUM46Ccs+rzk6PEIqczMzCSXRJ+WyjaimuR27i
# DATA dHMyhWvUPuftlLN3Uc7mHSVcFfFh833oL3Hbj+jvFs1sGhQXgj/8SD6+CHrZJg8uKRL55maRSJWbIhD5Jk5xjnCsG4NSrgeJzTIe
# DATA We5UVXAeHKfzwWWlKc8pBDwn8UhOMCcLpkBkPDTBBYVgvFFE9WgCg4gmLIkcPOaUaCLK02hnXjVL3toxS97RmqA0JusMeTOcQFeA
# DATA tXo5utSY+II5cy1LOCwr6o3gXaankVO8QMLzOjDnaGjGH2qCZP3FcjIfgc2uI2N0O7hkvvxoc75Ii1I1ZTlkyySvI7MwpTmpN6M5
# DATA rYd+hsGgkG7FggRkBnL4DywarlLRTAhlECTImCNCn+fo749PtXHzDOvIv92xjnyULFnD4qfLozw/tNr0XKtPJ9MRNo0A00CdwBzT
# DATA KzQIphkpjNGQTA0azAaUcZNxssSJt5r3CSYErK3ASgli1x1Nwp8ZoY6nVJ/Nu8JL5s9HW7RndacqOUTza2+uL0kOfZQmx6gDlGaa
# DATA 3RxFBh3Lm+So0oTLAVQ47s+85QzJ1T0MBIIZiAos0wTK+5CK5sXlZ9huPt6x3XClVsotFrKWFRmmyRLq40soVUzEeEj5jCz8/aBi
# DATA DYe6Z4HScixdKZtlthBvKNWF+utyftyulO2rotCQm9luEu4m4TtPwt2M+yWfcW+cTD/Xkm28j8XsaBEqK+9qufcGNehyCev9l0iu
# DATA 2VbXla2U1uZQuRBO+FtZ/mxlX6RUmEGCnUPystPZQMdEnTS+94OVbZV6kr+qLmc9xl84NYXxfVIgewE+wawXVhwbUvWkCbz2L+QP
# DATA 8dFpHm6eU926F0nOaUdhW89sqZLqWzAczAaqLYbav/zjP2gzgl85DkTKTixIbxFNJjx1UaAJUfT6HuzPzDsSKytcMC1iCBU2mrGM
# DATA l9O+Lq7QS8eni/FUWbNssPLc4CiWn8XyYzEyTJshamZpfnm85xEiXUoauUK5lUa54JxRA9Qr0IIZytEVJ2G6oqlbLFCGGhnDkYlV
# DATA r6CslhWMs9qc1baz1bZS39zaiVs7uYLFttE4vEnxXQY0jZSOPou5I695Ib6gwfvsBeG3GQI45+fZay0rSydiK7JtOSxcK6xpyFI/
# DATA XX6X+l8++81XvL3B9CLQvX7UdGfmgllhkAMiZWS8XwTd28j4es3fvP6iNhTYkZVLu8TWPGyim18x8e1dZ3TVxgv6/QOt/7tIFoUq
# DATA sffti6JtAjHRzq9ckM11K96NrdFW5qtZMJNdqbzKJVU+4i0epilkFiIKNezeG3ImWMVZbU+2nWr5Jel/YkFVzWnsVkbsHQniKeFP
# DATA YlsxSivvAmxV6h9mZn8JGp8xbj8QZ6pRambk8Mk4nkR5PxFDrXaBvTopS96alQ5qzVEu3szywGqFEyaubFyRrW9k6paqgN5p5Q0V
# DATA qs/0Blo7GF2q1fdQqpZTuh/bg/NwWE96EM6gHTynBMQ4pximc17oZc8xUORwV56MIzHg844LKYPQNPdrvLBFRkfNUzA7pNAITWfL
# DATA OXU9Sj+4KC59h/P9VbGeLQgXz9F5DmFzuP6RGVxfnv9SeFcgZ31z9k8KzQU4F1hcX6wSuP473fYVAF2C1jr7X1Y49IkBW3+kezRk
# DATA 68/nvzn7Z0PpOvuCbvyK3/X78//EhC6cdPDOfnf25dn/okoTThxw64Ww/9m4t7ZuABWYJsC7TtFPcH0zdgyTWjPIk1OXxOp91DPO
# DATA RPX7hHXDZelCy25XFDf0CI19HPbRT8lsXdSwuc5A7LwfYYawDbb1Kd1lIuRQWwXTP+8Zbpu2VSqVm2NtCe3b8J94S7b1VuvOn2ZU
# DATA 3PrGYgW7TsRWKGArDVdQC4SSGIfXuqC4rh2t9VFIRid+pli36pV6vc6jBmUAdVE17yMaQIzVwwQLnnSNwznWgvXO/0XYP0QkBUed
# DATA GQgFiit6RAMBzhaUGVoXVrfNZkqx8TwreNaFCXDcLDe8X/fwrplZlx/VXw1n3i2O6Nc9oO80nu88nN/KaC61sZB020f3PLWhm2Bk
# DATA FRLOiJ9MMdvtZNKkO8zUotkQi2Z9WOYhdhJXKKExkD7UaGJKwiQGS2o21K8dhfEE/spBCFYRs4WKycJoG5qMntIApxeY41k2R5Lg
# DATA IqUWsistKw+ZNQMyeR/FnylNvBV9THUO7hW6yGfK+bQ5+zdmWOHjOeySCVHzUBywyZCRWWIWZOasOKXowSkZb4/gKYuHoTrJHolh
# DATA GGXYhxhnY6xjhvBqDIS7gnTFI2xAHIyjaejxznemcM15LHIoLYfSciitG0RpXTgG7TTV2dF8vr1ZwFUmAdcwB3DoLIfOcugsh85y
# DATA 6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh856btBZQbNZb10ZndUcdUad
# DATA FwidVVh13gmcxRnLcelxxgmaqe4X5CjafreY4Y1eb3OO1xu95irIqRcwkkoFZcGlOvVur9dfB5dqSCCDOGUJKvWytsWWanA8+cBc
# DATA t0iTGvYanfa651utnZ7v9Xvt/rrnu81dnu9G/U7olzNhGjQbXhC0q1SxWz2u3sG04beqfuB7fK0q16q+36j6zU610/H8rm8HzRtG
# DATA S3iu7rA77K3LQcaFlWp+p+c1Gz5VeLzaq4979VJwJu9WgutdAYHFTUgjsKQ1WgisRrvd7wRXQWDVo14UWgisgALq5AisYFgfNnME
# DATA VtBt++3ezSOwaCZUpd93mrQHAY2VRb9VYaSREU+H6PEBOcN90jacMj51gnUAqXatrAvEW04el1wm1hiwcndYMvuNKd5Vpnj+gB61
# DATA y/PAdXM+7SXsspdQVgfhJ1yz2NYuJqK4ECBzRM+e+ChDLn/CDINrVuzKGK61Hh9dUYsehk3QLuM8VtGB39iafvH3C/Kp+KI2ksN+
# DATA xcLWk83Pm3H6gtdsmMJtxnqZCr4Tjmtb5d08rS9V5nV1cjm5cHLJUXCcL8f5cpwvx/lynC/H+XKcL8f5cpwvx/lynC/H+XrFOF+o
# DATA C+qEfDQ8tKlfCyyZckYgdXelrifLdBChgnCtOoxHbGSqhnmvVYfBsxgDVvBOmiaI49vK8kLzIpOH+uj0SPpk89q7JWPamhOwCVvB
# DATA 5KIi9C9sa+Ry2BfmmAmEvlNX8dlrbNeIee69mx/9Jzv6NFvTF+wfPmEb/XEeG2y1HMUzyg5FNWMZUaX7cGwF/xY6H2qucKlWcI5x
# DATA GsoZKi51vLWPPco0v+QXWfFTgrrU1eAk1IeJsU+9E5xZVNYn/cYRpGrNuY9TO1X9I/3y3W12B5chlU+errt5yvYfFyIjYlQmDlqk
# DATA Ub0JpwERD7H6D58YY/6z10zgNcSN3mouvE59FShsdI1ae34M8o7cqHODzx6V06uSayrb1vbC6VxXeLsFQ5M5vJ4CYntZ8mxPbOjB
# DATA Ip3QlO9v/ka+YjMgfd3/q7+S7/Qo5elnr73DiIfX9h9vsLyV0U1dYbZ4wBb7nhSqk7h3agpXUlNwKgovt4rCZdXtn6m6gnHASopE
# DATA rM9Scl+EqG73PtQy3JxSPsi6hLRlvDkhb+uz+7nygMQSD2178AG3W97mhUWhjU8VskOMBavt5U/dQUy1DiEfjd0ocG9ITEoKgVr1
# DATA dnH7505s4gU4XM3/vWZyQlEU47q5CWWtkbXUhMuqZH2axsp0i2fMaiTbDcaMUckyOiCsXJbBAj6BkNl0KRoOp+ynrhgBfamMqvJw
# DATA RcEomYmivaXpAY2DkC36ZLRguFIasRudCVwKuMWGvscLg6w3PosesY9XKWtcyDF6Oc7JmxCcceeMu52Mu5JSjtPMcppZl7DqNpqO
# DATA N6Wl9Z4INlHFVnN55UTgap6TfW5bsfE2RO6VZ0Fnrk76G3onhlYc17dBNV08ZbjMzrKCwDpl5GTCHm0GIGCtmEe3v4KL6RB9mnw6
# DATA UBeURS3fKvKH3eLqth/7laDS+AkNijpGGyTllVON3vUef+IqW0QQm1tM35o/tEIADhjZcJJ4vJVkC3i4KYY3uIelO1dAwRvF5I0P
# DATA K686L66OPKY8Ii+lbKR1EmdLI3A2l1ZTURJm/zY8Dh9IF6vUzEBY0W5QNBOVD6z3djIraqGJalYISIvtklP6WDRgQvRMEEmTU+UI
# DATA Nc0dClciwEVPn+B0Fw+drDlluf9qnikujIhkIy8Hi6WiME3iKS7yRiMIVkEkjmkX0O7KdFRKFSGfithmcj61kNIquk4xt9Qr/MZ1
# DATA qOZ8puZcLDv/clio+TDjTFRnou5kotq2iDNQnYG61fB81mKvHxYayQwD3SKe5lCmB7JMygKoFYsCKKnz3tEyiBBYxPEdzi76HU1l
# DATA mPBYDV1OVgsNjyhe2HI2OzV6kDsquHJ0TWyEBEW1AIKOYhBQY6V2H7G+JTqPNd46deJ4jaUqexRQwfiTogMpS0b/mBtX5gpLTwA5
# DATA H3E4Knay58Z0S5tZRWbjA0N/5HPRrrTuMF2i/dSKyYidAxgd0THKffE2CxMtUvuSN99l6dgKxtF83RJylMVHnPa3+dMW27XIBped
# DATA BLbBomjmm8zGQhljd7U01isA2HVuXBLA/vjJZgK7ZKwQ2DGJizQjXTntTzWJ/RNsGaWUp8tMtntxDZyxdqoS0sUcCGROvQIdYxNG
# DATA iA0UXn9Jhq5STI0HNe/tmAVWlyy0603jjGePstcF25WYIsqbQOQat1ZeGRYSAxBE9LpU8dmeGm1fqkGXzOB/+bs/bs7hQm2UjGZJ
# DATA 1zQS4V/4VeNBvDDIe/4lpy+x9i0Z1aKlmsz1qfsF1baUdXxxeHURi31+f8SHwmluMO3HR0twH5Xrt6K7O0FFCf0xJGOfJXzjIf8m
# DATA E/bryNEr1tVptltd/TCcSlWAlHWedVJbMMWBgq3s8xVVW+hUT6IFkFiyu8k87THGA70Xgz5OgZYVWtcMyoBoEGT9UXSo96SiUBsU
# DATA TAN59tXv312q8gnrjGNPqfh8GS0jnX/vYwaHSRtNoHMl5pMwZmcOX1DHzSMAoN+WBslrElJxsryicsDI+hGOFnB+UgbO4ELigBby
# DATA FDC9ESiKNFSi0K6l6pmu/ZIZ+d6WuqcGCcnD8gqlt0jDYxo3TygNOjM/VkcJxkogO5RqmZINEw0zZRRQLzdbMDgOYcEukfkJNeSZ
# DATA 6RlUrzqlXiPjuWQMiUdrWTWHyy1iJece0fxXq3DD9num+frJrvn6CRP4rOUqnG/MW7daDkujI+wHlwMilJBMDRkYbXL1eiN5nrGv
# DATA IrcMo9GIc9juB8J+xuLVNENj947co6ozelOx+mJ0tj+V3aylDC0aCbJn0TYSzBXJHrJr9e5CPbFjZ4va9Ucd0WCcQD8rhL+USlIX
# DATA xCux8GZj9KgkIpug91/Ovjn/D2dfnv3z2Z/Pfwvu3fkvgMSj/35z9rvz3wga7/dnX5z//Owr/D3789lX579dJerZ4TAr7xdM48Oz
# DATA 35z/Gk+dfU0Xmbcn6D36+yePbvny/O/oub+c/xI4PcSgn0YnVYPe+/r8V/T3t/iZiXt/cmi9F8FbIzXN5s3LlPNhjFY6k23BIDb8
# DATA 0PhmRPke5hhZDEMo/bClIOsb+P2h3k6SRoN4rmyubIn+iFv7NGGx/q0kvbckXlYDcjA920uD3Lltjt5qmdwcSk+qTr6S+LFUJZE8
# DATA Kd+Mnshac4xOboSWzTuq5+rQBWWFTBjxtmk0Wzqe3g5ldu1IPTHruS/nrgdeZvGb9cmA0L2b2PPcjX2Sd0tUXZMTBfXRhHPWWRP0
# DATA Lx86QKHF0ynO6AAmRIVtYMSXqn9bMMDlRvWsEHsXJ8Ix9tw4/5TjvEbqXWl4f0UWYG5laL+BkX2ngf0y4/rtDOtSJcs5YKH1nmXT
# DATA uQmSXjmpelFEXKohy02WRsTMHhIR/5UxsSJQLFmclTVWUbI4jhbJnJ+JMj7QnpC5tBgnw2wXTN7HyENZxirHiLIXHgLeuEvJn8bY
# DATA YJKQVYY9WzLQ59WF3hlmyxRgsJAFRimT2Z9f0W77NEL74RSdcsmIDo6QAOFYYVKdrgxZOBHc1wDOas0zczQ8R8NzNLwbpOHtMnrs
# DATA NFfZ1di9Vbv9Kmb7dVjtjornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4
# DATA jornqHiOiueoeM8NFa/VDvqNzlWpeKNRLxq+QFS88srzTmC8AvWt0bOocY16w1Df/E6nyI0bDbo9lTcUwZhGVhNEIw+i2aznZRMI
# DATA bU8OTwW9QnidZjBoDFYKKmj5XhAE46BTP/abzc+rba/nV/1Gy+sF9Kde7eJLtResKblVNF8roNBa9XGz/Xmn43X8apPqgd+8gDpn
# DATA AlvBxAWdtRnQtch9FHmrcjZaeQY0Cu/9VnMQtBv1lSg32nXPb/mfVymtTaot1Y4/bTUp7p9Xg56+cuUE+MEVQHfcKjToThqYBbrr
# DATA NBuNZnMH0N1w1C6C7sJhb9DMQXeddqvXbhnQ3bAzqPct0F3Hb/jNzi2A7tCkqtvtDY+HF+vWMh/uexH1AnFYkYBLi3krqLgGL5jl
# DATA y2XFoJXdsuKk0jm04ogs+fvtsNZ54C81qHrse6uz4aSeUUtga5Nu3KqrkTRmeREhp8IWdN36rQJlot0qZm1tzpiBT69+1bfR4Hao
# DATA BTdliji0m0O7ObSbQ7s5tJtDuzm0m0O7ObSbQ7s5tJtDu71iaDcb5ibJ5gNbdwWkNsQpt9f2vyPfeMmRsVwKeZYswoncjxb1+gfh
# DATA YlzjmeQeX9x/nXIAx1HpPcqJNofGzHLOt+8V3nFHvtGPGfcii+RdbMfb8+1QPpXDZFYg5XeWguFnV46caYKYTAHNkQ53iNodol53
# DATA iLp0zMcdp3bHqS97nHqL8O1NHbOWVsB2MPTaZZXVHLN+hkIet0FdGKrj2apm4Ku3d7SvJG11s5uxAyMXgFdP5X2T+p4zC4oshmnM
# DATA AnQthW1g378sOmGLBa9F1fzNwrcynkKK2QxrKAYcqpb8vyC6+nkTX3PBRNhvr4tw14pwsHt8eVAFpY3jwdGkKxdEUj2U6/aq7wUO
# DATA xEoMfSuGXTuCxeht5D28pVpUZESDXlzcw1ts5fEwxgAvTE70geT3RlDZRB/Cx/AzHujQ9jIyS+YV9mlSK53A6z859aCkiUoWg5cn
# DATA RpF464XOJbWOz41TM1QhDikIChBmzlgHOEhg9KiQ9HFw5k9wTY6yBdbdeUrFEkxTtogtEQCcBmcFRl5GHeIkmSdrN4e2GABMNvR+
# DATA WTKNdEf0Ps1ejjFDGjMAg9v3ALuDVYIQ7byvuRjQ8PIcLHaQWGfJbrdknd36ktutl4XCPnN5IF4wtxaCV42+SUESkKk/GYtuK/5B
# DATA n4+RwhTZylB95qpCL4gCx01gU1cUkK6bnLpGTWo9PHU3JcRS/UNW2zQFFpF+M0Va1bDOqu25gjTv6dEToWUmcCrNT2VbLMI8a3ha
# DATA kHQJPWyUWE6VfYYKRh+ySBlKCExqUtFAUejkd/kGY5SUJbg5zh+z2KtEOaIs1jF+z0zUYp4DUlRFz2gRpxVWZufYaFX2goWmFe9t
# DATA fAAbpAiKrAAcwdgS7Y+wMLc91g8AXVGx5m1K0VBH/B0tcTWk2S1iQ0ng3KvwlK/inWKzrKg6ocdYJEcRVKxqnmVUJ6wsOvUYVKCo
# DATA L5uiq1+4GuNXSMDG7pOcpekszXWWZmGcch5T5zG9yEB99sKUEoNMKSumSTJllTpuELk85WQiTWWtSGJN1fOKOCsqMhhBdw7NCOvT
# DATA TAVjz4onq3eqXfEy4uUoYO+ylaDUHaVNquVGDhM935yxm3ABhxNsYBCBbAcF2wUKJhaXbVptutP4uZnuor9svl+rdHKuqs+b79Yy
# DATA nkXz4/nHiOX5d0mOi3/gtzejXHRhCMrlB7OIOpM5uxarOLKoLUOsb/gt78heyQiadbqg3IifRopARlMQbJWbnFbIbsfe3z7VixG+
# DATA LjBeImTsIcmw5iGnOjLuIWBsnYTZWLRUtYVOlyaT7Do4OLeSf5+cJJx/Qxqn5sXca9SLudfsWrn3gBdqkGzua1UmQbEUQOcFy1GK
# DATA NKbcJX7hSQR8ETbreuoQrgiVXkNuFdrg5TOstTnDrAYtefY96lMpdu+mPJWdywQmz7egVOsanZaVbwuYUrxMxoZTPFsuMORAtHRS
# DATA nFjxiMGwHqp5NLtSFDwzCTvGjsbJc5B37Uvk3VuoAqnISuTrg4XsK1W7RlAvZV+Fp9Jsoh5JUWQ0TxWlVBD7pDViP/owDU+wlVcv
# DATA DbDebL408DR5Zvfhl8yyDzbnVz4aKIRf8jDU1rXOpHeZUyHcCKD7hF54TDaHMdPJwn1IDW+i0E5DVh2eJkMm+XljrAN7H4tQMDOt
# DATA cMUsn5hVmYwGesp11uRFi76ObLMHs0vXtGBzxuUDo2SccQwUDTSdhw9wVXldZp7fpRo21HkVeo027xmiioptgexCoOmScsSI7cYY
# DATA ea5riXe0jBXfi7mxynvDZiNvOX9eEV4vi0Mix3iN4gUkZm2O1/979tX5L8/+fPYlGFtfeWd/OPv92Vdn//PsS0ZvfbkK7Pqv9NPv
# DATA zr4BY+v8P+IWT5BcZ385+yP99PX5L85/U0E4FCaF9Wf67Z+98/+fvbdrcuM48z3nWp+i7AlHd5sAiAJQeCHV1FIU9TIjyTwkbe1Z
# DATA S6soAIVGiQAKQgHdbMuKkK2ZMzMxjuOI3YnYiImzO7FxLvZmLzT26FiWLc3FfoHurzCfZJ//82RmZeGt0a9skimbJFCoysr3fPLJ
# DATA zP/v7/BTke74hn7/Nb/pm6Pv6M1fH3/BeDAguxQB7Nf09Y8UIP3kmF3Pg0slg/qhyxzaPCDpQ9IYPlBqkhoXOJl1pqx+Lx0KZVg0
# DATA FfjiPqZ/8VBckNJu4ULt4fQ5OABQKOGnwGHkjai83bOjNPKTcLAW43UfK+Pd8NDE1HG8bF+L6iCuGuS1pFQuj+SlamG2ZPRIVctB
# DATA TPGcHM7fL7VR3/xOrpJeJMwLLkMVE9HCl535kY6XA3ptVnQXzvR6FGWgg4wFMQEkVXdZhsrBJeel6G2wF0hkhBmqYE4Rw/NziK8l
# DATA 7+24q2fH1LvJ9FqcUyqlC2SvkyvjantmsZU9K7TXyalwaC9nDly8OaBpX2ezAl6K1ZarsgAuwwDYaPw/5fB/NaO/VMyFXLCgX9es
# DATA UV0GB2wh+YCaYm0oZc77+pQVuAZC9YqTMJ/Od6ZqawRvgWCRkDicmDfpoDjlsuCE4lSug43IYI/Z1wt/EDbgpHC9RZNwUFCWHA1o
# DATA cXeG4ou6XIww1iZUQ3gNuZthnjjC2hQwO0ZgHlCg4vKAc4raOFwz8ahIWcwgdo+si2k8irSjipfPEDqWoWG2FMRmoReLHWJAUI4S
# DATA 5ihhjhJ2eZSwDYecjeZAm5rOVzsNOMss4CImAY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U
# DATA 5khhjhTmSGGOFOZIYY4U5khhjhTmSGHXhhRWa1e7/POZSGGNXtBrP0eksIWl541QYXa++IFX9Zv9oN6ao03VqXdsRstoU9Wm5BCX
# DATA kZRBjRUphZTl+zmlnvmyq/h24dVz+W/emQs9aPmXGHqrngVea+UCl1RlgfvVug0BywXe6jXb7d584PWgdeGh50BvNWGxCaTMr2eg
# DATA t6CZCyAKwrBZXWgW9Ljn+839WjCoND2/cQKBbHWdaJwBQMaNTQPIpN3mAGRB2KpvACDLXQGALOh2euUMQFbvBFGzbABknV6n0o0s
# DATA AFlQ67Ralw4g0w10LXyq5AeaQpa734yOeoEg2IQ2lg9C88ayflzn1IIj03q0jUWZJc9suixQqisLpGI7HiqlJWvCPhtEuTfnPApi
# DATA GeA5nr8Yb5IfkJ0Ak2qJR7JiPJKSKfPLLEsW+oKFF1Ru67kW9d5+ZpfMRb/J9twyLlqr1crT0LDKvJpSliu3wlxZrLF28jfO+R6M
# DATA +9BhyByGzGHIHIbMYcgchsxhyByGzGHIHIbMYcgchuwlw5ChLlAo3UFUiHiZqLtbLrDTnT+NyeyO0t2ff1SAQ3U/2mULtoCO9gF+
# DATA 2kWVvG0qNJ8ug3U02d75LO5ty0M7n+mgqYXCBAlHnag0Igt1p6heddsO/jarOuuDG9sSvZ3b6Ao+3HqcHWPrCk7sc2uOg32E+v1S
# DATA ijj2sea9SD89RUllJQ+aGE+2VW8FfWJJPyVg1L2xO1a799Mfw7C7TelD4K/Sbzuf8dO749t8JoPiRD/+gK9RPJamJpdgk/W3TYbf
# DATA llqHCT03+qyGUZ6/qfSdKe8VEk6f/DHKz95jHJLKn7+cUPSZ4EH5ESeSfWLL3/589euY9NaJ4sH2NiW1iDTv3GTTFpA3lSUUE0qy
# DATA qRfUkDj1JXbj7nyWVRjrssTdvo8yzubiZTVIxRK5KjmkxoKdz7IMQ9GhOGPKxvhVRc5jSTekM75xQ99cGs/INPlMxfyW3IlTdnRf
# DATA gSNCE+sPcOruP774J3WmEdi8+Ia/Q10MRWIh+KK/syZsHI+0w36I45K8/LEY+udZXfhc1RGeTOo2uViV1QO3c7X/ttSzXcxgddWz
# DATA bihUgnK+RU1mI5ESFkIfVwduZXThtXUGbtbm1VMTnCE96SkuX7u7sGp+lgNz/cy6JvEQKqtZe1CJQlR0kswccEm0+AxKPKD5kOlT
# DATA dQ00j8lYsZOLNAV7EI9ourgsUKyk0UPRXCY5ZozTmTijzoTTl3jx9SVOS5K5DroTvLKS89evx8m8h0PwIHJAfFUfnA738KppMkwm
# DATA NDNby5S5jqIVz88R7ssgzSxqbFw0amaZiMkZWTNebolIqjSvsN3xy1oaWDCbRk6MXqZugYCn1JNM5MMWen9CVllBXE+iZY/IG8tb
# DATA VvOSMWaRgOsJ66E/m0xZ6itW7x3TyD8S/YRESX0YEfs1Qh8nKY++QEf0cw3HmVDOhNrQhJrrX51olxPtsobflcbXdRDzen0Wg6mV
# DATA l60yUl5viS6U3ZQw8oyjBA3toJ/kRihBCOgBrOTdhYgNio41dUKZCyv4WPSEmmM4iHtQvIHoNpwPIiE1iqKuxoydlp9iIqqAD0pO
# DATA G9LqhSVKWg6esgk8ZZhI0bHevfq8DogyYTeaSODL59V3Y7ePcLPv8afVd2pzR/GF+PPzgE6xc++UKvlNGI6rdfKzssixLNirp8Xx
# DATA eVaUjWwYvybJbK+fNYZPGPbOEh4alzQbkfHIWlTZhmm05/0kZm2rDpuHnj5BD6txxmJzY5bvhbFJcdiLphdBGThH/gWny783ovSJ
# DATA x852Cy0AbVwFdzLpZck4cYWnzDO0TYeDcPCE8krLB3J4uG02AKabUY1eNOIyYPE2nILwurOJFtelQepimBZZMzwtnKGyPt+yVi35
# DATA 9jqN8bLvj5k6s9jUPmVbUZ2LopVChlg9GoFlIXnJ0nSymJAqeleUTkveXzMQI+r0R/Gns8goKFIlpQkdWAnTPqYd/ZBrIvJ1qiru
# DATA BeRm1k2dNi9PqIO615Oc/IDqDqsgaqlmgyE1mURp5CrEFqpCjRokPFm4nSeQgpwzZVXuhSy7qJB/g0hNMjnblYacEfXu5YfhZ9WC
# DATA 66drwa+HA7Yj1FQhslk0MA44Q9LZGBMwSmA4aR+quUFHdBZlp3PJ45Ua5C7LkU8U241yrRdFEFHEVIssiigdR52YibCifjk5ZD1D
# DATA MwkfRQcXkYP22HfaClhen4XZUKpgK6hcE3NRU3Bp2jXkrg2dvSL1mGlYJwSVhzLqgAxsmOrYQeH1ySJE/UKWsQooCx9SpYYO5D62
# DATA iqk9NtcWqvICuTayIJxfw/k1NvRr5Guac2s4t8YZ14RWukAuTaNcVdkc/RWmOFVz49145qyMdd4NZjKu5NjzRm9e5sDub3VyUV8z
# DATA k17e1WCPnOaKnvVyLmXnI7EzhL4lvZ6YBmFX7IKcQ4J3tdDPbCOZXmdbbU/ZUX4R3cJHvKEfr5BIqadNz6i/m3l+VY5vYhiYkHFP
# DATA xgufucPFYfhU7ijLOblozEfzVvtOeJMMp8Qq042jqp42UdXfTVQrJ0bVb24cVdn2g8jyp5Pipm/PYmeumPjVlkXPt6JXWRM7tSpo
# DATA /FlyLoCnf+Dt3eR9ikMyseVGNj8mwzuvirRCloU4FmLXwexSrs6NaXCfynHcmxJEVpGNb8ZqH+bSCgeOmEQ0GexapnZO4f8/k23a
# DATA 0RNUmpj3MEoakI5MGQ5CGt4B2xnTo2SgYQamqEDZLFYDKRWdUE22hJJq9v5aSEsMycmgyDBL3rFFb+mCh5kITRRelILXjX/xixhD
# DATA CrtXRrMUgvzpIdm+yTDNvKh2zPrRYHzCwvFcqWaLx7ZfNVsGlvyXPVv0+AN8yEr8TIHJVi5plNHUqj5iw3KJvRxWucU6nE3IJiaT
# DATA zqYd/jeGF34N2mCeQXj8G/y9SDv856OvmEf4p6Pvj37vHf/N8ZdH3x19e/xf6Mnv6ZPiFjLjEMRCCZxD9hiI+BUwisdf0A2/O/4H
# DATA euhb3Pb90b9ROPrJ3x99D1ziN4xBpCAd8/B5mGGY6pVNLLjCg3iCHKVnCspfyR2ORmKwcJKhO0uEySJ6QKUoNAIYVobgQT2pNnrG
# DATA cdSh2fg6uOFDvY2BBgBGqzm0oTWZ0AV21XDDhVK5PLShqiP6NnA2NHGHf1m4H9tXrA73UdJTe1ouHG3IEciBDeOUK7vDGm5WbBeO
# DATA Nbz/dDxALxNqZ8gw6c4GIcjryZQ1e0reB+j7ue/K9nnx4hc2xtOzZv8TxWE25J4ylW1QcKEk01CvZYUjQccsAA1ProKrrZb5lvWs
# DATA cIYnp8HhDN1If46RXnMLzzLAvxyewisb3C9+bN9oaD/lyH41A7tUy7k8sJiFz6rlXAaccC6VWAEACUhx/uKOlVh9znE+QaG4NBVU
# DATA DrQ1vYk6RfHw5mvZVqwlumEljdgrOp9vGxIJjZc1i106TTq84sjjsUbFMT+Oa0mX5tqj1EQ/mk0SLxwy/o2H/IjMhrgTY2k8ZxPk
# DATA LIDoKQ4WI/BuBG+U2lGt1grJeqDifC8KU0SIbbvOFK4YMRLZqyOUOllbV0Xdnh1K/XK0QkcrdLTCy6IVbjjUbDS12dQyvkob/ywm
# DATA /kVY+I5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIXX
# DATA hlUY+LVa0DkjqzDq9vyo8RyxCucWnk9NKgx8r+qX94ut1qd+o1hteI2A/u5Xg8qntZZX8eoVr9rYb7VyudTx29VObx5jR2HVl2Ls
# DATA agtkQznpJwC/Vh7gF1T9OYJfrZmVtRxbywh+UTMKO4vgRIsP2AxywVeqrXzwrerK0E0yc6HXysGa0IMzhW6XSNP3arXGfq01pK61
# DATA WGvt11ob57S/CCNs+F7gN/r1IJgLpRN02u3OUhTl6bGD0m40dlCaoIUdrHeDZqN7InYw7LV79Rx2sEt/dysWdrBbDxqBwQ62O51a
# DATA u2ZhBytBrVm9dOyg2aYG4f+9jebra7h9Yt96C3aRNsfn3mYGSjX1eiui7iYOCxK/pQDDQK3EVRZofVhYXHjBnNvdNhp1geTn3WTu
# DATA eT7sAK8uf+ww2TrdOIcCbTohU8TIzQd1J5w3VCxsYD6y9uYCPaKrZa/yMm+vLKbkk1aB75P/Un/sGfd64uBcthbm82SN2bI2yWxP
# DATA OOCgAw464KADDjrgoAMOOuCgAw464KADDjrgoAMOvmTAQZvvJskWL4aQ0vioOKK/8+Nm+UalXKCZpfrpgItwR6ZsGvN1Xw7J8EE3
# DATA NLIb/Cu4dJ0hAo68/+//8FplfOtG0bj0If03Am2Nwr2zW37tw60PWEudz9HxQg0CoR8liBJPeSjCEpY5fIO4eO1D3Mt0vLCdIsQd
# DATA 8xQ+8bvesY+ySeq8KJ3Cjxzd8v7j1/8vIrOQ9u1qpXxDrrK4J7oGBKlRZg4h5s52n3S2253pftHPdJ+WFHYdznrPudjWY8LeRdMw
# DATA T5S891DtbW2XpXCwZ3o6/Pk5GnkZFLD5w+wXzQBblAQ4KwEs76/VZ/XfZWqXVAR5TS8yujZvwPUYet2EfkgP+Iz2AzghUbVYCqgf
# DATA xpOS9yiesvtJC75LBRTh8tlYjierws0d3w8zKaMxRBuTHp9FzkRz5hRuFsr5SQRTOTRyO7CJrl7p5hmdgrVakDOGnDE0bwwt9KhO
# DATA 9MaJ3pxkRl0PMZwHUl+ZaNFNDP7ik6RtFHEeGu0Gaobx3kiRv5SGmsJHTmhY6EDcooebRUkiDYFfhXtU43F4Qz7Ld4gODdyQA1u7
# DATA ZYlmysbgr8dQnYF/LFOysXkw7LsQ1Q6H+9oM90VJgT6JSvqUW81q2Be7HUUWmj+uvpe353LP8pg/PQ/wLisvTsldebSGn6RzVYgr
# DATA 99AqqHTFthLgyuODRMSakhkEY0LIsQhkZYiWoiUSUcND9kKJLJOYhzSu7cOL/AvIs0yGefUiUSki2y/JxrsQgjBUO0LRqO+xoazP
# DATA nEqjUbOD5cLOiwLQZuFNbJIsgSbHtJQDxgYsKHPG0AOWIPT5+FdnLrmHG5fcQzlgLla6Lrp3YYugIwyZDUDFsafUv1MmfUVjVsdR
# DATA LKE8OgzFx5I+ovZNRSCT1LuazwiPodoXxb3pIJoqsMBExSUdJ9PzF1kuZVdXZllvcsoy+8k6Wpnql6TMfgIBIuRjO6EI2YAolibS
# DATA 6yha0GxPGFmUu9SJ42LSI2vE8LR60YFoTunBbSqS8LhTFne4pA+Y/sbMFdPouPTbs/Tw/KWVT9NzUFzvb1xc74cAt/NiBvX1GY8q
# DATA 7YuWvmkM1OvtwR/+JDoUa78dQkHL6ydDaViYHIw4NNaoG3lUUBPQwoDKAa+KHfC9+Kng4xiakBXmvPDb+Qstn7IrK7RsFD5lmT1e
# DATA XWZ6PFe9oigH4lpWXuKPwD58DAPUhFJhBQ7EEcPyyB01TrA3zrvL5dtjfBd1QhAhw7gnlieOTXnjGR+eY/GEEdAuF9DvZXG//iVS
# DATA 2bRE3o+Uch2Gj6n6SREu5XxQpAcYaU5ibYhQX+Lx8S60gEMRJBQwoGo13L/xzBoBwOzmoSxOtZGC0hX9uwtoM4sJOVMxXS1h7lwY
# DATA k5fBz2YF4RxtztE272izq5TzsTkf2xkXG1f65C5JcFqm5DLTwwiIyg0b07jYniHU4JLIczlPlt57AnufN1lj+anJ+2Z4Jqx+PwF0
# DATA loViuivrUkaNOwl1Vt+Qw3agvWUG3MXzArVrb7szPBFwJwFkgDv13QLcLcXG+XJZg+PKG0PuZDcP3IX4IIwxoSBDpZjzas6BqB7I
# DATA vIc6hAWfXaPM2C9sa/cOsJDJ+4sa5dVePt/nRx5HT9ETda2n6Jc1j9X4sbfp7kP7mVp5jZtwJaJOm6bYTUuW2vT5hdTZrruDPoXi
# DATA fUKW5yg6LNmSz0rXWToBOIQOEs/nlhZOFCxOb1gb0zRJme5YdabOguKE6RUP3BS0cceLQ4P7FvHYK3e/VtfmF6ttZx4DLqnAqpUy
# DATA 1zurhVMfNdPwS7Unt5OvqdCbVjLsFIpWYS+Qhf9Uur4RxXEgU0VWzR7PJgC9y8J2krJ+qiWQvQFE7gUxnjOEHPUiUWcS9qYWQu49
# DATA fa14/LdH3x//6vjXgMgd/X4RHfcvS/Fv9OVreurL4y+Of4XLHv3zNV38Hf/9FcBxdOXbo6+O/84g4b45+loppEPhawztVBqyHSbu
# DATA 2pv6bJmHnqkz3l+F+6F3vxvLWSwRvVf7Snj225vE0ahLHQh/O0gmg66x/uH5no3FdwpXgrjOBodM103g0haKKDsNsgUK1fPgqegp
# DATA NbTuWoTc6xDQYK0Jj/8WnoTjyGUzAtMpXDVHbnnRXB5Mrk/RYXJBBqfm+qqvnwSTuxeKJPhlAOV48xXZjvQvjQniusJojgbjgHKb
# DATA Fd2FA+Ukz0I2c0bo3GReZaZT2rBRk6mhdFBkueiKwgt8NLyh32Vre28WUqOYRtS3vRGnTwqwfujpew9+6qXjSJEycPyd0qZUYWZs
# DATA A8G1ON2ANre8jq42cZa2weuCnVueGIeec9bDJVkPGkt3ZqPhpXAhXp3BcEn2wkbmwimthaszFqSSLssMYyhcz4Z2GRQ7KxsAmsMi
# DATA cTcag0NFpowZqE0O8Wx+RbZ0kuFwhu4aC3jvYAbRYYcFS4qklC+dyB7xJxE7KMT7hwxL1WZ7GumpyPh6L57wKdo03ZhwB5BWqnyz
# DATA GiZGGbJPFuFE/Bzq1x7NlWM+4MA7gt5LPqERzePkdSgDk9605D3U8ZYDCgoWNu8EXrBb5KyARpAZTQsmmSE/oIsD6eA+ZXLcEe8x
# DATA p30k7hreyxmNmKODE/JoXQCRqSpBueqYd45555h3l8i823D0OtPBrnVm+ZXPNC7Co3rWeYYD4DkAngPgOQCeA+A5AJ4D4DkAngPg
# DATA OQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQDetQHgVfxqt1o5OwCv+lwB8JatQG9EwbN4cZUM
# DATA Ryen0bJ8b8wplAbNXHbVglYjiObIapUKFUBtDVnNenXrzK9uVtqVevXsr67Uz/zqarPRrnXP/upq9cyvrlda1Vrj7K+ulZ9ZWdca
# DATA z6ysg9ozK+u6/8zKOteuW82rzPBcuz7dq8+b4bl2fbpXnzfDc+36dK8+d+MqP7OyzrXrqy3rXLu+2rLOteurLWu7XVeC+lVmuN2u
# DATA T/nq82a43a5P+erzZrjdrk/56nM3rvIzK2u7XV9xWdvt+orL2m7XV1zWdruu+rUrNRVaZ371eTPcbtenfPV5M9xu16d89bkbV/mZ
# DATA lbXdrq+4rO12fcVlbbfrKylr2/VQKXvVRqUf1Mv7jeBt+pp3OjTa9aDWWfpYrdbgx6r1xcdqcHQ0TmOOqQmIBZf367kg/Wa1WlmM
# DATA SVAOvEoQ9CvlYTXwyv1KeS432kEUtBtLkezNM9HUqxlNXfw5Fk29WQ6joJ6nqfutql8JcjT1Ob46aOrtqNXpZTT1oFKv19qGph62
# DATA 2r2wnNHUa37QqZQvnabOzuBimzfpG0+nLLZrLHrmbW2Kw9p+Zh6Ibpbili276Y0aDd6gie2ZzERf3O1Yh59VXsMHwTbbllG3tmWs
# DATA BLpboa5nrUtxKadlYJZddI3gYwn9sJsc3GrRj/hT9lQpfl6iVw3hAluxBFtZCG59HmYBemqrqd6/JstW5tfxkt0Haq1X1zCzDKD2
# DATA gmae7sLciYL88nZ5NWzdLqk17vBldY2d3OxXd1B1B1V3UHUHVXdQdQdVd1B1B1V3UHUHVXdQdQdVf8mg6pnFqLQbtneMfUep9h6K
# DATA 9kcm/HFbiFXcZbOtPDhkXLmIihSHSTfaFXQFXZRttmjU2TURmSjCBtmtBEE94KuY5YlsWrqr2eg8NVaIc/UbGqUGpCNicEFMIcy2
# DATA 25TA46GCjWS/1OUFybSLkLkw8QXVnNtGKaWhOtouF+q1HRhHOKiyffPnH6r/bu3+5Q/w74SD+ejmXoHK1eK0c9l6i3B6qArsfrYf
# DATA juLBILxVKYwHM5r2p7eqBUjG3Qo+/zlHhaexJi4faTz9o9neXpTKuMgCZN7Du+/dMtj4ThQPtvGGG/PZ8+OS32Sa/Fvx6wKtf53l
# DATA fzId3rlQJAARwKFJPoLQ/PhxLFB5v1TRQaJzViwRjAoieAFNPRE65BeqOgNNvCnk+aZkLusaJEpCkGxRQHrOhExDlq6+ts6c4gyO
# DATA eyss2c/MRAMSaXPytPR0Vsl3bmNkgeNqTiMHYh8qAVBysSVvOMYyEPywkBfocDp1TqfuNDp1c2IuTrHOKdYt0fxZzbK4Lkp23niC
# DATA dsoaWvk4GSm7u3lJt70ZpHEhzLRKu02BLUbgzcadWAWN+R2rsWqxKqbRzkvS5dFaC3J05r5+5c4DDE3UteiIizdcy039TMZtpZiW
# DATA ka9gAydMqAcGEKgbLOMUWUV/ygL1ElwKLV9Pxnw91b0NsVhoTSm1OSC2POtJxnlC2YriHEEbn5ISw7jWHEI+8pf0ODrRU0DURNYL
# DATA PZV5mEaqVUp9nO43lF3EcnuZ0q0aGnX6HxlDytOGFBTrgPcRpWKaDwv1ROVQzDoWJe9nGDkXHun0Z9At1vpjylwpeTxpyA20ggcW
# DATA AKp4ags5qnBmUZBxCYU+6bnRxzJmJUaEGVRMrzJnCdJ1OXJXdfGSI6pX58ZicmOajBXbgOtKMmE1OaifpbMxRmhsOYaeM9W1TtS1
# DATA +v9p+ETgCrAK2Z7B5Gt8qApVDy7hQXiYWVQyAEns4av2HkfsyNRxY7BraJliDCK2hxyuW/F0XbL5/XjbJwllWhuDYch1juYNOuHv
# DATA woPiWba9VgVkGlReL1BoqCzaRVHCwtaYS46l5MIudeGxIdsoQTmdAJGh0/AnPcHIBOU064YBnWHWyoypxlQ7bcqpbKA+Z5Acstd3
# DATA HrImymAvvsBZNuo4A9UZqKcxUJ05+vKYoyvNzGsurGwv8C8izAY5O1VaDP097fOABFtFWajZI6zXo1BY11V++flSEz0J6GBt5RDc
# DATA HG+RufMqddDzLVUfR8tt8mqW5zZ5qaNm4YC/LWsvi8fEpPV3Eril5I2Ho46OjlJfuvOThVNm7MEnm2eFkLf1LH/hdM1BwPRGGq2V
# DATA /bqyGftaeZrzRxtjbLAtF29WVpmWB2Zex2xs2ZKGwUmDPexRPV0wmK+8gZk3Ry0H3xy+Yr4uvD6LUfMX9balUiwQu04kfIzUiwsU
# DATA kUlEpkvYJqtbAT7m2jtOv0pT0ATgfvXOo6EAvyk3DQ2Zmxtr+YaKiLyfn7WwDDio7+MoGQ+ohX7A6x7Ii2z+wWpmirgoMsk5nfC8
# DATA 4TgNUXE16M1Yi/NIaY6yKj0dXTX5M8Y+Zg+6PBUzTWYY2AkhM07GkmCWoroqVdprIvZgQkZkZ7o+Yvd4vcFLYfEf6uipizKTZgvc
# DATA C1GVOI+QkwcTVs1ODkY0ZaOf4iHk0HVlXRqbezLZW4zNSyhS7LjJzoo/qxU/X+Wcn9n5mc9twK+cLlyen9nwxOd5HAardi0xX1fB
# DATA X9Yrv/TD/adj2bfDq+BkykTJLNW+1hN4xlkwpt+zLhmAb/MkALO/MdDYGP0fcDeIiOUBxvqGjLFspgnzXGG1yo7flON+NYNYrcPL
# DATA NI8/rr4Xpc5mG/vt1zCKF1PGa+kmdfjGiAllmG+/Fb9+ImLaCiafB/qiiWftpGIJTsGZ5lV/Bf2jqMoF7Amh9kqZsD7S5nELO62v
# DATA ZLzpk6Jb3TS2vJEj68CG1DFQ3zEXR+zOsVHj026eMy7fTezueilZTHqZxo7qBkzq+xqVzB3EJOI1C+2Zfn4B1WatQDrgQTgb0XwI
# DATA CwLpNM+oNunvAk7DZhevEViUIfTsE5CZgZCWXqbk3cXl/ZjsHXuRjC2h6GlHrWZ4sh6hjjr0FDUTGzxCAdgcptiwxrMOnrGJEcVr
# DATA FcpQmoSxojeBJR2OpaeeK8/MgaJ6x2wTSS5jLfeIQfIscpGzYpc8msMxLeEw8QrbPIiJmVbdJBJ8lJr5eeBEHaCSUWYwMrQzVXgf
# DATA MwqdzMl+0WZNFjB7lsYdeHnixEJmH/234y+P/nD8j6BaH/3p+DdH3x19dfxbD+xs+uHfjr45/u0iPfufjr4/+jPd9/dH3x3/lu4+
# DATA +gM9/O9076+Of1Pw6NP39OTvj74//jUo2ghaSNq/or+/OfqGOdpf0CP/SreApP1Hj+4Cr/s3FOw3FOxXeProdxStP/KTFMTv6O/v
# DATA gOU+/sLRta//hJA6sWQYFUGWE0SW5k5xX9WhZgoQ3oCXgXm1/IEaIUJt0xYECcbOKTLjxoNI8cIU7Yp6v4mG2jMbLDNa11K0H+Ih
# DATA 6oMih87Ozfey7uGq4dlWiVweMVvVqtSa6fEFrpjp/N3tKMy669fpC1fGdkRj/UWisilcZlfHeiRTWysWJnUvKSt7g0K7cFL2vX4C
# DATA nfoQEHMaU0fafqUMZreTIkpyb0LltrAHXHy+ZLFQJ7UfDW4jrn3eJkX2XWp7qcJUekO9OeU09W+1BZO1pmfFvj4x8g577Yb1cw7r
# DATA Gm99utH85fDcXuFIfpED+Ubj+KmG8SsZxaUmmqRnu32faVO5DEC1SaNsD12VPO68lceHy7kgOykpDXsslRFO+5KGHjZC9mXJVlaf
# DATA aXoeCpl20j+c9odZgVl7IUOdGwpZjKF4EyL1+4lnoivgXc1c5tiMEk9azXI4b8m7yz+yQHcqZGJWdJYlLNWrIqB0mozJ2uorCu40
# DATA bCPD5ICdWA9Zqgwgm/KrE6eiT6GztANnhONLO76040tfIl96oyFlo/nKhobv1djuZzHdL8BydyBpB5J2IGkHknYgaQeSdiBpB5J2
# DATA IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHkr42IOlapRoGwRlB0r1qr9wLniOQtFlx3oge
# DATA becHXKxB0K+XK/vVavlt+v6L+XyMgtYSvFXT85u1flCr7zeBt2rmH+v43UbXn39s6NcCr0KPVstFv+FVqvTBqzaLtZpXpf/Tb41i
# DATA 06tVPcCz/GK1ydcquD3wqi2v6uNuXC57La/WLFZ8+628EzLPtqp2g7BeXsa2WlI3AsSnse9X5gFt7Xrbb3eWhVJbgPHZlLRqHhks
# DATA 4VoAr3pWfat5knkUBo32Qgwrlfr5Y1jxq1kMg+oFx7DVuoAYNutZDBv1i41htVE5fwyr3CQuqZRr1EjOHcNatXJ5pRz4zfPHMCgH
# DATA l1fKQcu/gBg2mhdcyqcB6ckgpEF6Mp5ZIL1WLfCrrTxIbx6bx1fCeZBer9uKggykVw+DqNE0IL1Oo92lOboB6bXIOq42Lx2kx9s/
# DATA i+us+1J1jk/3ufXQIosu5xLym/lZj84EtrHgsqW8x6bH7WKlG+3t5EKeI/S9FdG4HocFifu887vKrm9Z8mY43/z6vQqZJ2ubrqmV
# DATA tPnO/tyqlXQE4+mNRznL3TgWcMRA+8KxMax4yiWg2jIHNPvhrPCUF2wRz6dqU740UBiWV6KB5ZXl26EWXlFCrMlmtWb5ZKLqxmCX
# DATA MFnFQae1GrqXlXDBLpM1s4jF2qaSa1Uj5exeXzg8FUCtXzmNygrqdPNRBwF0EEAHAXQQQAcBdBBABwF0EEAHAXQQQAcBdBDAlwwC
# DATA iLqgJoq7bJ0WQhz6LEDCd1JgGbbybckPPh22K7Ul7v6vu/ixiNpymwMR8YhdNbyprxS3n5cLlUKtUKc+Mu7N95Dqtp0d/bi5+za/
# DATA zlTE7VEhBv9tpLu9XfWE1evt3B6tzSUA5PSIlcVPvUdGyae7d57qN0hPRleUnftUdWf0H+h19hxjjKNj2zuf5XLyNh8C1rYiZ+jO
# DATA XKpGu3coQXz8EsYoz9vR/PgcHJJQkpOfCvNHQXOvpCB4O2zO5aehH26p837oKLJauUujLkvIyiljqo/CwHsoh46RhDF1sIy5Mwmb
# DATA ssUL5N4P1Nt3xPJfXjYnpGSa7O0NcikpxNTOUYskSRzoz/H9I1MECqiY7HKt1LZ/2oHOI5K7U9jL/fQWTSKoYic0ZEWUMaPOoRQa
# DATA v4beVn7Nb5ZvVavl23ulPboXxuLPcMNdNuq3cWqhoAKUbei4vKPvjp6OkxEE28LBw3A4fpzkny37i8/eKJXriBAlZERFtL2HwPQX
# DATA uRtKevGIVzZxJ3ugtuVTMt5eFmKDikkK8IFkJgsmAu64jQ83fGY2Jj2vyUXKide//Kh5m+virjWRQUkXqmWswAkAEm6UhOva52pO
# DATA wsr4GsGoq8NnWd2/rarG57oN8BR4iu1GXIR37+0exCOaWJX4VDnXy6fTX/5SXTyI2k/iqf2T9Bb3dqZ9Gqe9+5MJ1245km6N00gf
# DATA Z5HUg1/+EvPBu/coQuFBGNPsj7MP/fQQ4+SSynzKVpSMrUYk/aM0lNuf82zfzhMpI4lz3rxYPL4uokeiwAPpQznF3Y68iKZpum1S
# DATA v2Omsku6Oj4fFw9oWpfr9FBk5jEZ8nasWFKgqhSWBIk1fnrEBGU9x1n7mrR6CUZ8auZQrdOycVo2y7Rs8getnaiNE7XZVNRmpQD5
# DATA ZYnd3Me6C4+uUJsYRbZsixa+eXYCalehMi6mAF1+jA/eNoojvTmMR7NpdJKOtX7WdE7mgpFcVqrh85LQsjdEaUJX1klY62O+FG0+
# DATA rgvF+EN0WZzfCQtnUOnwAlpfVpq4OCkAuT+fMWY9ycoJ8yObpbxkLXnDU6Ay35nPCO3BybLC3JolnR/059St17/L3/xdfj6b8WDl
# DATA VO+qbP6uSu5d/GD1VO+qbv6uau5d/GDtVO+qbf6u2oLU+p3gVO8KNn9XkHsXP1g/1bvqm7+rnnsXP9g41bsam7+rsaD/fqdp3qX1
# DATA VUwbXqmubk9fXwAxdT1UCNJFKxFZow31fU8ErYSjMzSVkw5MRkjMHoBN5kn6EFJLk1yXJyH4Ba9a8AIejhqgaEUjFlL1sIOAgxag
# DATA 8NCQwKyI0UC13H/qoX9lmIEl+2W87ZmqFA1TmDdoRTAMgghTrMbT64FtIGX+/IsJOWirmzqtnzq5mdKLOVM6LYj1mcuC8uaubJ/X
# DATA ZSA8LfnNC+Z22uKlS2GdK3GyrCHIJw9NSxUuCmTG12Blr4E46nMiFrihvLmX7RzUxpV4LfV8WU7sUO7QZBoqmlBJMobWXaXQGk5Y
# DATA 5AqOUTKG8DSZVWRfMf+U115ErHUs03je2gUdRszTeVdTAQ+ogsqUG3lCT4UUD+gd+9iJKFSgPbDJWH6SXs6MHOjyaTH00+cizD7W
# DATA jJzTjr1KyfRnYynlqqUzlpyxtMxYynVVzs380ruZVxpZz15TXdd8qs4hy0ofwgMwovt4M1KmsT6eoGlCBniuke3NaH7MruZJpDSw
# DATA F+S9qbkYBXBLGTxRU3yuQ3OO5ZzVsCiibu6jcVU3Yx6RqHSNvjKGzaTX88L9JO7y6ucoiVN2iU+0prZ0Bxl4PEuYVnQreY9oiPZ6
# DATA FJqIqKe8TipHiTH4DiQuKe9fRCCHRgucepZZO6VGP5uK4cYycmB+dzURDjEuee8pnW1vGHcmybjPDhiFj4vCDrvl8TzlAHSr0X0t
# DATA 98Rn7p6QbY2RUoPXmfIomooZkWbSz4MEG1mmoPnKBrxxyFBDq9vTAL2SdxeZSUHH47ECbyMIdsnd9rCwjauM3g7lLrvMPZyRQF88
# DATA Qu5o9Lukm1PlHdDbeGV8TfLeD2HXCLd4LzGq87jK5haVBMxiKWCNnadSl0o+TYbJZJIcKH1vqf68Sq6Lhqu+J5k4wr7OZNaBBgxj
# DATA 0MV3lR3izdImDHcDTaeiwsCnKMvr0vMmy/OzZwwLPAuAnAFZdDwFiWAtigWqFOETDFJTHsL6ZDLYhiW1SUwa2NRLxTSk23s4oY6m
# DATA YMZBqQ7AIQomAC96EjF8HjWPsnEohcTkabIs91CVByDRU2RmIwzMWFNKxul8IsWeOokU9LrUc165QnwkRyUXZvMeYUSbB5vcRlqr
# DATA 1y1qxzGGuZVe5XVO5PxCiSmFNZmX+ZX5led8rS+vpV+kWZnGd7Gv4eUSaTQZC0uYBdyILvZtvGDykEvWVNYpOh2rE0ZLudi38tIJ
# DATA 9n2vbpj5F96cDc7pi39xZz8Z4pLe1k2SSWrzLf/l6PvjvwWQ8vgfmTv5KyZcfnH826P/AaLk0TdHXy8CLv+FCZbAU37hHX2Lfxhm
# DATA +e3RN8d/6zH68ovjv6c/XwrhUgVML2Ks5XcU+NdHf9b0SgZj0m3fgnL59fE/0G9/dAjL6z9veyQzrUkCI4lNYSwaJbO9/pQZOSIz
# DATA rYbXQTyFuoacIjYTsdlI2y5kSmHUCxneKgM+WzCpzNyAQYFZGPIZ1LX8yke844L6wnjgfUIWIxtRjmSZzeF0L3DVGMulBXN5QEuu
# DATA l6k1f9TVVJBH+ZtRWc2tD1TNxfB2kTRLMlZZSEGtYcpeE2oSY0ey3KC0LhxkeVdtrRpQ8zgsHoSDJxmpicxq8HaA/1HJgq3bCXHc
# DATA iEbZCeTZFF4n7GKEMNCoURSRkY8FeKqXhzw3UBQknJ8fL5AsT6h5q82SZc3pWREtT0iE41m6Mf48Y7yGWZ51aH8pXLNXNqxfzqi+
# DATA 0aB+mjH9CoZ0qZdLcsAM6M+w/VwG4XJJUj2ah9InZs+FaplUkotYFnidM0S2xx2Ms0gxJ3dZlHnjs3p4kggoUPqmNtbNOb4hx22U
# DATA Q+1tArfMOboRJZUMo/3J7m5s9fMOaI6NNWBRPkiFCuj9NM1MKBn5yXLDLu8exSyGISBownjEa0uGdglrJ5YXKM8wCo0Xsu5aaEjl
# DATA W+1GNEYOYzIbDvoRxyL02DThDXa9yNEuHe3S0S4vkXa5yRCz0ZRmI5v4qs37s1j35zbuHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIh
# DATA Lx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhL68N8rJSq4VB/azIy2bUaveeI+TlkpXn08IvaxWv
# DATA Vq97lG+eXy0P/HLg+Y3yu7VG02s0B5Vmxas257iWdG97EYc59FtVr0IZHfjFJv3d8lr1Yi0o+n6xQuEHv3iv5lPYzWBQrxb9csNr
# DATA Njy/0igGdEutWKXXt4qVoFhtzJVJEDXa3UU+YJWi3fjUD8rFoOxVmr5XntaqTa+832i+Xavmw6h3mt1GZTGMZs0LauVPi5Vyo9ik
# DATA SFVqRZ/ygmIUIKbFZuMEsqaJ3AJHz2/K6zrxBLOlDhd/nSPhdbhofam5EwEV5uLbDZq1Wu0MtDyuv5qWJ03BouW160FU9Teg5dW7
# DATA UY6WFzW6Qaud0fKCXh22taHlVdu1ZiWj5TUbNd+PLp2Wx9W+uN4wYO/+nG+aigpnLz+3AtC2QY6dJolexLmpfF30/+EPtfDbJ60h
# DATA LDd2VsHfrFieTOGzIXvy4Okge7VFyF4WzCkge9oBuTKP7JxWGaowdqr+2R6jCttpbAyYQWzFNgI9dqsFrvJq9l2WrwU7q9aYEyfk
# DATA hCHaOficg885+JyDzzn4nIPPOficg885+JyDzzn4nIPPvUTwOU4bTiMUtc1DaXxt3YDGCCLJIZYbWtqfeoY+ht5gsHtne7DAd1Ip
# DATA 3tEd2WsUzNOPZFrzcw8fdm4M8pWMa/5O6ZMkHlEAH9J/4EPdNublh1v62HkWl9L0KfL1w603Fk6kqwBu4LMmRd0zOxR0qBr8pNlK
# DATA TiHcHaxec7DaHah+SQ5Un1Yv/NketGa/ZOZKW8QRDXJamHtJ0sXZYo/9hOaYLZMkEMgane1nfT77eTijyH9fsFb7soPkF63avvxc
# DATA /lL99g2OyWd+WqMfHolAHUpby06qymE0Zh5HFIU0GUYQguGjtVLV+AS8cr8xkUV0A/Pny7OT4wXIIJOtmTV2njNCzxQe4KTXg2Na
# DATA H2gW3UMELlWNXzF/+Pw0IuIL1UQO5IaZdfJsxGqexWlW87wzqJxBtUSNLqtQTrDGCdac1Y5aaa9djpAN9+m6GZAlJdoVrIHRT6bJ
# DATA 3iQc9y1R8Wemm3YBAEsal99QMjTW6HVKzWIxBhDIBQoWq7FfD+bDcMyZY435y5RvL0S1+AOW95a+kWojFFLQ812CcPGbsNX5RSMv
# DATA ekr56KWjC5cPZtHid0bpbBBORb38UCXvAAkdUyfe86i/GwwuQ7Z4xppKU82dmbEG+FxruNj3BqI8DYnvrici9Hqco+HvYt/F9McH
# DATA 0SRlKSasVDHfXmRhmG1UDGMy4GdjapDRBatRN7JOdM6CpuIMwYMVBogY3BcsET3HmsymZRJk3jFJD2mtIG94aMwP6W0MjjIDQNqK
# DATA 6mY5KFOUx+TArj+qCR1m6lMyoMmJo3SFtFQHgEWtK2XpUkEViMWlvEcQ+I5GHoNXRh0qKC0/1VPUA8r7glHISlTvrCVNsfB0qLWS
# DATA eEY0mbXbEMnncmEmMapJMmB8sYwDonE0mUHIy9OZZnS8lHszkheYxe5Q6aZuhnp8caYflkHhJiBuArIwAclbmG4K4qYg+SnIyonF
# DATA s9bSVLwOZlr0wzHDhkPMMGxx7DRSuntaCnJOLJJRO1odUqGPIpnMWDqPU1sAEmPl4AD8pJngQuYlHqXFzqgpU99FpbAfLVF63FRt
# DATA k1M7vvMmL21m8W4fZrMj5i63Z/Gga7T4VGTY0bjoNlaHRy0AvUZvy2o/A6vwSVlYygLSP2bwbHOFVQT6zIrhnk0WZ2X3Cg3dVlLy
# DATA EHD1XrOFAFap+vyqbIxQL7fuMD2r/dSrCfewmeGHNXiMsdRs1H1sWybKkTt/O01Q1WGGt/jT6js7g3jY5ojiw+r7qGNOsCmL7rwv
# DATA H7N7b0ra7sxhyrWtKavxtqmJEWWNoZkrXWwGlmavzkhnlnM46ZrpKW9+kImqysd8PsyBuXgntekOZGeBTGxnfHvNezI0yZiPt8lU
# DATA KEdW7zyMmdXUjRgmRK21Kl6CYZJOB4cKfomfYCUaKXZeqxFeVzyayhAYiRwmdkmm/UTpiYYCPdfisQwUHxmpWWq5PC3W7m0lhenB
# DATA MlPWoTqodbUZWD9FBn5Ac+IB++7jSYemi1kWYo5KHQNQXHZHp2Y58JRQt/CJ2qJDPdk9XiVg25j3VsJsHyZtPEK9XyR1moriSSqL
# DATA ZooCxmVxEdlltZJT5ldrbX6ZJicZ9hNIflK72ItMVsGbwPfk88gguCQjS94HNGYWPFbJi8kIO1T+JwURo+5cKHGyW0XcYZozT8MG
# DATA Y9yi7kVklel4TplRjbUZpXoxyaa34ccRcz4eWbWKX00V4oBimbIjJpwM1Oqp9s3AiYBtcCG0amWli6fZ+Bnev73DzF8YYQkQe/KF
# DATA nAvgGPd53A4hqcvoCr7pmbbJ4BRt8l2A6NCnUbsrUqKLArkytc2+TM1NqHUqI62VtyhMD7G4p4lw9AjZ/CI9zPkptkgKjJc1I3+W
# DATA FcyvbF7D3k2oiGmMHESH7CbI6tiAfsksHOXdFYcfzW6pCbInLjPWkCHUw7PDSi+iqkVRsbagDowTOYmqo2StiAsKNMJJ3Fmab/mB
# DATA WPbW2QOxuSLZcOf9RO+C08rTbIKp3WlwiqiSVJRond+lkxhiL4oDImOJjaMp0Lw2Suy/C0jMO/rD0VceY71A//rz8X85+uroz0ff
# DATA LGLE/p+jr4++LR79CQCw418DQPbvwIUd/4qu/9vRd/T37+jv749+f/S9d/ylhI6gvwF07KujPx3/5ujb4y/p39/iTWCR0ZspjK8o
# DATA hK80mOzPR185mthzQIEeycoP9vF0lEp9RoEeR8mY+Y0MWOehndqeGIjdBMrn7G3EQGO5pJUYLt+FPjoTVuc3UA8Si4Q8O4/XUsXe
# DATA grnE7PbRocOJ2T4U1RFcNU0sXyCXixGLR9Ya7n1dS/Uviyyx0RSHAE0fi68y0kWTi+SJhVNBFPTDlIZTWLBk6Sa9nsOJbVpqF84U
# DATA uxcOOlh1jGQB7DADVIdD3mnPSyADXifxephKeMyFY7k/s8oBku5wGPHkF2MJryPGv4iYvuF142i6BCN2YqVbbZ3k2tKzY4idmALH
# DATA EXOj+0WM7pondupB/aVYFLmqAf2Cx/ONF0NONZpf0WAuNdLOg2y71bNvOpeBErPTKo5htYOjn9BzWHzIJxQpMLHUhYVFojVJfwcM
# DATA 9sE4FaoSJ20apk/UXhVEIB7h5BiO8aks2QwlBoCRDNX74HUpWFM3IztJtZFhvaNtAsCnEmy0g02Ata2YDIQldsEMugvxdJk9oKwB
# DATA Bh/BDsDqVfqEAjPxiOEc59pE9WuAXdrYQzabTmIps2TUiSaj1HHEHEfMccQumSO20Uiz4QmMDY3jKzPyz+Z7vAAT39HEHE3M0cQc
# DATA TczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTez60MQ6QWWRdLUpTazX
# DATA q0XN54gmZi87nxYj5gdVr9pqfFqslos+5U+jWvSD+qBYA1bL/9T3q8XA82sVzy9XvEal2PBwF+7wm8CA5bOu22u1Gr0FwhgAX7Vy
# DATA y6vQO2oNr9YqtuhCxWvWEWTgBcB4eT7CbuF11VY+2KDe7DZ7S8Bc1bIF5qq0AgPm8sv5+tCuNWrRkgCCmhVA1SJ7NRerRG0ZGazS
# DATA OO3zVr5Uqw2vSvlQCbxmkf7y/WGl5lMeecjcMmfx6oTYpUh31oKgHzSac6Qz88AC6ax+Bk4ZtwzDKeNGZnHKqB41GuEGnLKwV81x
# DATA ynqVbqNTtzhlrXqvkXHKus1OrV3LOGWVZr1ab1w6p2wcTU+klGF80fdtgPmyHGVVdpOVmrw8hiFtZ5EEZkLWmLPcTLcW/MgL6E8l
# DATA YKdjDs0lOSohqAhv5lRTqTKOtYqZ7s69vVJjXyC78eZsG/E8rUF46XQVcvFbM4TnbtMuMIfscsguh+xyyC6H7HLILofscsguh+xy
# DATA yC6H7HLIrpcM2aUsDovD1Q0P0933wmm/1BskNLGB2ffhFg5jUep/DJPmprrG56NwUb7SNAuGKrUatj4/3Lo7pgneU7goo8Eh5cYN
# DATA BH2DcqU3E7kwPh7Ws3Su1FkrXkUCKQtILX2YK1SHs6BBhiDl2E3Ih7RxQMWcwRK9P0fZcseOT3vs2B03flGPG58Fr3UNjiGz+077
# DATA u9ZTtkTAysR76VHlJXyt63J4+bk6w3cZwK38cesLJm3NVYazIrYsR2p2iFzldIYFgTyjCMgr1RXOrn71zps8wWddOa1Dx9UHQqEj
# DATA pTcnB2FN9TkI6Yl2coDTztHebAD5Pi07N4ScaNKDGn53NuEKGk6GWvpenYnnd+sI3CXbOibjl7fN6ihoShhlTw+LpG3W4pzCT+Tx
# DATA 5hSxTLDUOuC0Qc+O2wJOVLYjvLhLNtls0jbCky/JUU8rDGdXObtqjVibXbmcrovTdTmtQbUGt3U5ei9/PUoO0P2L4kA73BONNUhu
# DATA qIHNv3o5sQuga/EKhNoBoq/ltOF5ok9XfzqC3kKkZFiMW8zbfrK3M0cCGvE6UAbaUUGYbkp/z+GQKNHUJUNPZhizvG25hD6behbZ
# DATA kiPGEfZyZj+ukLMXPwSAPrZgyxhbXGmw3z4xvvr5rF/VFzIIV7O8LM52jLFdx47ymgizp4QpTXBXZzo2yKgT4qoeNVHV33O4sLXx
# DATA 9NfEco6gpNaX0FqV00XUyLmqW5QkVKo7r8peUxVPtcZoa/lml6R3ifclBTT+KmbrTQnifBQoi9lktW9b+Ejp0yvES4hmb/QB78P1
# DATA ZDdgbtCslRI9jUXFhYc79DjaBfXpjHohaJWns729iD3QAEbwyoTqIJIJMBaAKrGqNEZhDnQEQMVA07iEgca+cdXuIKBCpvyM/fFU
# DATA NNCDgUJwuGcYsVCggnGaykjejXssnTIV/SFWdvbUVt7IxEfk6CFNxNFYok6USRKxrDI8jYiMF46pzmGA25Tt9IIYu7kRzJm7ztxd
# DATA ae4umDbO4nUW72oT9pooHN5j9T1oFvcwyMQjljFbznfSfNlMCnASDWNGdBRWqe69KUzBheGGhc32ZnEXOMNsYKTQqL12ZwAQ8vA2
# DATA bwLnoQkLAofmPhrXDdNU+554qP8pcwIwnk0SGjrCqR5z2Q4fUgOfwYRSdkC4N4k0vnJxyFT6hxRSl4Zqkxy4qhYGTpYGhLgMe44i
# DATA 1oTzwikqNEX4tk1t12TI6Clvj8I7YkANKNdXzAhE4i3Z5/1NisGp+bljzfDCRk4BhTyNJp0Y+x1zEFTJcC4YFu2zhAqVl6zkvQXO
# DATA Fnej7E1jaFcfNhffxQATECvhrns3mnI/y8mAaRNO5/xtOLhmIuvx4QawT9al8a6WozT9vU7kB5i1afaO6vuhMlkQzT0NJsIjWH+k
# DATA gh6kBaZjpIbaqY0uMZPeR2DoKQ9hgqmNljyyTHhIasPSjrpxJ5QSVPhMZOVCTbcwZ9FTGvMGh+tS+T4fKTbmF+NLdDrv8k5PdUhk
# DATA NinAk8wK40Nd/Dx9VKScGPATZb6OoMSnxD8tRhonKa9UWfIeRdETpoTALcs8D+Ql36qqhVaszPFl2H8q3BCoLcJBrB3FYcqT2nBv
# DATA lKRxukDmYEPsJJ3vxwl1TJyfWRfErebUpGj2aesx6EI40ZabWzUGuLfZiX0JZOj3UH31PhhqriGqrui/62nKJVCi7+Wc5WizVN5C
# DATA l70EUvS78ZRnZRPqtiAEKVBIxazhnlMEJi8BFv1gIO9EB8mpzRoXT7O6lwCKvksdkG7x6KW6Rl+XixTeokn3gtnJL/r8zeLi0FPT
# DATA 1Mbi/DMgOEffHX11/Ouj747/8ehr7/gLIGro69d0+Zvj3y6Scf6FUTf/ylCb/N1Hf2RKjkc//erod0dfH/+DCuW/gotD174//ls8
# DATA Qa/6Lf3yZ3rhH73jv8uRdiyYjkPjPAdkYQazGe1aYWTB8wukR0G2oQoXuMfd1gGg3AfKotqLWDH4CRzOghOealYiQ0Z5EAVDcG+w
# DATA noDzbhT2+C0Of5ObY3J7v2r6jVUYl4e+kaRl3SLXnR7Pw+ZvxchhbuSp3qR/OO0PLxJ3w5tsadrTR43v8owAyD3eionbHfbmxBK7
# DATA cN4NJrlJG3NMrmfaY42dImo6zP3LIJwM1dJUNvmMU3FFL+yhFv10tm1lLkGlRb0YpnVkusDBvYC/WV//VhsfWTt6Vtib9TF3xBs3
# DATA aJ9i0NZgm9ON1S+HL/hqxumLHKY3GqU3H6Qvf4yW6mcSbQbkq2sLl0GqMekRQnI6nxC9/yLbxMD2RD8ZahiMVSYy06UBDYNd2OWE
# DATA MgXdEClSxVjuJLOJsCmy8VUnXI6y00uQVxz8ZtwaNcXPjcGhca7r0duM2ynd2J0NIr0lkpew4FX00nHUiaO0YOKfsYuVo3UQi+s1
# DATA os427EXTw5wrUKWDcbqMiWYUcEcSlU+QA9Q4QI0D1Fw8oObkgWOjOccm9uvV2N9nMb/Pa307GI2D0TgYjYPROBiNg9E4GI2D0TgY
# DATA jYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPRXB8YTbUWVbtnhdH4veC5gtGY5ebTkmiqlaZX
# DATA rZX7jJ+p1Dy/Vn27GlTy2dHpNcvBIv+kRgmo1ho/8yvVef5JLejUmsv4J1xK+WCqrZZXqVX+k9+qeJVKmf40vJb/qR80vabnNyqe
# DATA H/j0rqpXaVU/rfj1ol+lMgQxp1b063RLkb7RTTW6yacHav+p0qJHK16VQqg2P/XhRa55NbqnWs+lqxY1W/XyIiBGIlQkE77o+82h
# DATA X6N8wYvqZeB55tLaaXVbYWdZWhV6hkoxJvNDsWtq5SBj19RaZasC1+TL4ZLa3O1E9U7vDOwYrsiGHcNtwmLH1CqNMKieyI5p97q9
# DATA eo4dQ/FpdtoWO6Zab3FAwo6hTqIVRhY7Jgja1dqls2MG1ApOhMfAafR5dquhvFgcF5W6RcceO/cq9G/zR7a53WDzIQvyZCSNzZvh
# DATA zXayt3hZLIzrqrRk/ZQsLA9LlV5d/uRC85RFY4AyPIqa3j9HrpEinksxhQnLyAvkj3GNSrKbMK5sf45vrfGoIBqUYT79Uf9qC5Ot
# DATA Vx4QV9JqNijLfNbl59hLM2JlQA5q46A2DmrjoDYOauOgNg5q46A2DmrjoDYOauOgNi8Z1EYbhFraZ2vntXWjGcNvdK/Ppy7UYwX0
# DATA gUu7Vk+lzKpUu3di3Xvtskm8cxvt/MOte5maFw6rWHIuI8phpemC6WueWWNOPrhzw+7csHXyxZ0edqeHTzo9vFJr8lJOFb+Omgul
# DATA uSxwc7L4mepPXIBeOrTm8OaDKHrCJxylzZ5Ray4bWy5ObS6KBkqVuy2rJJQhWn1QObovQXZOnzdW4LYxlWp3Au05j+ZI0eDwEjTn
# DATA 3hnhUPNUethUKWXDXu5lAtWXID73mF1fKo1kgqjenOoEjR1FqF93L0F37qEcJYYPkEw5lWQDF7iUcmXtufdx1jo0AnRoeTLCwWQh
# DATA 8xJ7oWaT6ILV55QHxkjHZ5qMOWWA7HCrTog5NUsZhi5gmutBLIn6TBReJOAhoTp3WJ97o1KmrtmdHOqMzlAN4eAA3MJhxBLyuAUL
# DATA VWRoDAYl7924Z5pDAbiHwWJbVCqqI0Rl4vXpx0mEBavBoTzJ3ctBmEp0NFFIqdVyHRSVdzQ2eHNFu5omFVhi31cBUOugaEp96cM3
# DATA OFEn4qGTSY/2aEhZJRmgc0Uf96ducoST77zNgMYTlgKgkXpe4mdupHoY4TigOsUtk1a5Q8adk2Xjn/OTxw456ez3zH53FvsLZ7Gf
# DATA Fin5DHWAeDHfLESv50i+GbP8uYKjQPR85PFe3jUQySuWD7r2chqXwYfMRI4uGg5py0GdlQxpbVLQ06aHOFZlqoNM/Fg4RQlPVeYK
# DATA ErsapBTV7kYQG1+fyMOgAWALnYY23vUGs2E8SmY0RTQ20YgqeQIRm3E0GEDaHWNoXymuk/01Knk/aYvcPhkm2HQNLaU+maQKc8A8
# DATA G/12OxpvwUDjuzgxOhbvwy6iICh2VHmp1lhmF5t8fH4k4m0Ihym01MOUJdSlhWiN5yEkrCfr3s9uaC/37rekBaVkXqa8FF3y3kvS
# DATA qbb/RFyI2T861reRQdK+wF6C8g3117ANIGxP3QhVdZYNmY/Jiy4SY/UMzlZztpo9Mjhn68vrbF3NnHyWEo7v8WKlrs9KgI2PXltQ
# DATA SkjrMRxhH9pt0n4y502B3QgMmGQnmnYclrwHmRggTuGISptB+3AZstMgtPQD2afJvoNe3PFSmu53jGelzVvJMs1A0VzcUAOSUyyO
# DATA j6zxy1ofYjIKJxPNE+LDJXgPvD5LjER1xnGRdqnWuVFJ+ZPykylPlv4xAyKaK5zjwI5EHI48rdxPyWBgpWApAdIsnnM1kc+vypYA
# DATA 9XLrDtNR2k+9mnCHmbnvsPqMEXMw0EujMfyhibLm5m8nu4FbVXKw+p49NnsYmcWfVt/ZZjuNNbInYqXoO29KqrJ8kPFYewtlBdr2
# DATA 82FoWOMqXGszWp7PcNI1Tnhe8Bd3vMpBKwfmQFK8M9i0fllK5yo0mXFO3DUJmI+x5OWYDbZ7EHGMJxAyRb3PzFbYa0WlyVkQidEi
# DATA ZmZag5SGsWHSjdiPP4U9C8NPW3CCUrKdiXBAGqnOiIWGtJE99X5BA27J9q9u6Ev1zDY5tjTySTFZoyXMAHjFcjc3InrGcrrO27Kn
# DATA Kp6s8p2yhB6tLiFdjaWQHo3ZB5svIWrG3JGIxx3YF2hl9sn+ETdo6EldV1a/xQ40ayB4XlZBRGo1gfoophwoXexgVFbK+cvGTsH1
# DATA L5gHmxbMg3AyYFHZcDDUBfMo6TGMdUSjGmumHmCSRyPoXn5uVvLu7icxZsaU98atX7Bd31wqY+pfMDnrqlkipofnLg874ldWHlnf
# DATA e8ry+KvV5aF7cSmPvyKDZaEjm3U6swGryWIRUJ0kVI1DT1YVS496KV5JwHlsGjJK3tvUug4LVIRkhiTxQFSOh9yLJcOhyD+TcTEU
# DATA lhj9FCMHzXrx+QsqS9H1L6aHmxbTw1m7Pd+fvc4i1qo3i0afJIdZD6bFuEreBzFNd7sz6uj3ZCnKyCfrVaHMwgNTm/KqE86Ejnfu
# DATA srCjff07sTc37cRejydd3jEwggOIGsfIajx9Ubzuz4Zxt4iFQpYYV+XBo07Khj2khaawzD8INZc6W+e3eXsoYdPbUUhkPKltE9BC
# DATA hnvo3OW0mKAzlVbe/pNtjLb9Z65I3t95P9EbDrUGt5j8YnHz0j9DLUOasSA7dCmrhdPLYaI91x6vjIWW9pMoh0L7v47+9fjLo98d
# DATA /wasMmDM6POvjr4++rej7+jv3zEe7Y8ew86+OfrT8W8WwWj/zBi1r47+RM/+3qO/OMCjbwoU4tEf6Bujz+h/3x99bV5ik9Topj8f
# DATA fY1PiqP2b6Ci4f3y3u+P/v34Hx0V7TmAcpttDrzlNZkeaOyqIXNDvFjIqwWeGfE2qwgmnmYBABoKdwLLyFAHIHAGdKBj0A0U0ZXq
# DATA 8WTKe8bwXE+WsIxTAJ6OteQ0KMujKYid7/Bptq+Pu4irpqfNF8jlIdRotAgHyV6G+OIdhvzyeQ73zV6cddNvxlML33FxDDWY0urc
# DATA BmpoIiM4Z4PDp51cWhfOT3tPMOBem4wL7OiieX+fxh0zvSxoIytNcBgKGQlDFslEd6f2tGJ+o0jjT6GSEmWdE+t8FcimkuXIScSe
# DATA RSbM6mMCQyoiwWtgsJousNXW18vVRsxcK3tWgLX10XeANTf+X/D4ryFsZxj2X4rlvasZ8i98xN9owD/FeH/5w71UxHzSzSh/vZrP
# DATA ZXDb8gnnQZIzxEDHTKrbhwipIGcYJzN5lcR1KkCndBhi4cssvXnSL7WjFC6taIKlSU40DdTZsQUVvW7cM2w3Svahp0gmGzLbJspc
# DATA 4201OLJCBgX7JaLOE4xNCk3GdUy4V3xqmHcCCW0uTnkPVToVGhcvzUbpVEwF5EtmOdxWFDPQs6YzCmEYjmY9fJ7YRoLyvMJPwDbN
# DATA 5LCYjByyzSHbHLLtEpFtG4wuG010NjGJr9CuP4tZf16r3oHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B
# DATA 2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuO3agNv8oNqpls8Kbgt69aj3HIHb8mvOp6W3ka3qVWvNT+tBsVr3mtWiX60M6J9K
# DATA xWsGnl+mX6qeX6FP9WKlOqi3vKDutcpepfFptUZXvWrg1Spv+37r02KzWG14Fb8YzGVp1OpVuu056JnfqNWrtWXQs9ZiyVXKXq0c
# DATA 9INGZb9af5u+5l9gwspT2CqUgko98Bp+0W8Oi7WGV2t6jXLRb9CXmlere/Umfdk4Yn51IWaBD0hc49NilQq1iLyov0cBILaDKl3I
# DATA 0eJ4J2f+ZVGvUV+BuVMVuBNP+ITdU6n0lQz95jcYJMeqBvV8CzDBUgAwbDx5uoys9eThZjNf7Xs9/q77X5ZDZfHXapPqDYVxSmwc
# DATA NyONjZMWaWHjoqBZC4I8No5uqlXqOWzcHEhOsHGtbivDxtU69SBoZNi4bqfT7mXYuFa32ipHl46NQ/s7GRtX1UaBmAT6mRX8OCRz
# DATA zr8Y/Mir0Z8q/akHP7KDmOPFvTOkqcS0gK3AiK/3Pit20Fc75vY0KSiXb88788TdU2juHxR4lWzFipiKBuBV4882XSoo1ay88KqT
# DATA fDCe3k+RM0jMfAm7qrWLT3s580w7lUkV+uMH2uRnX1E8JQurkwPZaR829cuVBfxceTVfzuR+wc6BNabICQlkK8Fx5BxHznHkHEfO
# DATA ceQcR85x5BxHznHkHEfOceQcR+4l48gpiyPfAcQjCn8X9t6HW9LmKOE35DsUYTgb2MT8cOtxOIEKLT/iyc1oXjf4AlWLN7GZbtvf
# DATA uUG50RmWPqT/RnetU+L3f5o/hscPvxdO+yWeoW9zOD/2SwFCyI73LTk0ninfQorLdPsaNZcdW3GHqN0h6k0OUdtHm9xZaneWeo1e
# DATA 8rM9Yy1Hgwv6rO+Sk9YPzblAqSOFvLKaOdQrB1aVIAufJYYdfaB0mOUkb8Qq+9nhyXF4iMm0HJ6E1srIOjm5sQbym6J63BZGVBcE
# DATA Krw6NB06OgKne7yJ7nEnTGehkk3Dp9V3okulrMWtH8jH1fdSB9tNEs7on8jH50EBOcuLU4og3lstgqhzVUQQySibHHahQxSO9sM0
# DATA U0DEyUlqXlAQ7yTsNpmNxzj3jI0GOIzmTUQWMgWeQw6zsxeMmlpU8qhVxzg6PKejw+Nhd3JY8KIwPeSGcn7dw7k0XJlEpVX/Lk4x
# DATA 1NRkpVMN22EygxmZlU1nlvap5kYskosz6HKEOhS5ajZzMiMCViXsEsEwoKD64N6hi8iUqZWeAx8Pn6F+wF/a1syTc6lTZwl4Dgrm
# DATA g40L5iFV9SLcKofQALeUQ/lgc4FKZBxx6+FmoxsIg2RQcNQfoeFo3VCcI4RiFRTDozHbhshwS01DBAewtiXjWzzoJzOWHj2/vmsu
# DATA KVdWSmfu3N7dtHN7L8bOGWh4zCaWMjJNUGjOh12B02Ssm04vngwhTjobe6pgkglLsPGvol5yQImaJG3p7iYRvrJu2GzUJ6MK6ga2
# DATA jMd5iiQX8ysrEWuQPGWRPF5dJGa4lTJ5PAnjgeilhGTWmEKh71MYJ7DfEsnhLk17YOShahoa5iRUzUFpVgMmrJVmMiWJTOxNRFgG
# DATA h6L2du6CyUf/+reVR5u2lQ9kTkoT1HhMVdgUDGo3LGeaussWIRjWPIzzdBSqHuOUx3tM88GjxcZchcxKRTNciYRPWdQapQvP6bmL
# DATA Yi7GL6/W8YsgJ6Ifd94t593axLtlVzHn3XLerY29WCudYJfj3WLhLQPAC729JBFRPO3burb6tet8XzjS4NkesAWnltBNsWFE7UPW
# DATA 13LeJrU8w2imEfbf80RVLZRud4Y7yu2lG6ZMSlGKEqp53nRl2RXj+qnw7toJem70YsOYDaQKb6sehrzlVW/kjca89brkr3aQ8QoS
# DATA anmiynVsVMvyfjJ1o4mZfnDBNeUrQi/snu4tz/c6w9V+LL8UsAOBAoujCd1dCnL3L/iylIVlHIWy6YaCuK/lC+d6WctMQvlRFPhw
# DATA kU6V7L6yTZfskjTxWMyzMY2HU9mQflOCOKcBJEYKBiOrvdlqlo8n4n4VYiz6gQWV6AHrNY60l7YgMwa24dgrEu6Fsey6wpZ4wUjR
# DATA 7KHkGchdVk9LHhdagQc/C8jC4pVZkNCrTLV1jNfBmhrHI8FYIUyyiI0EIRYUWUENh8Yg6dg+lOYpwnwhFCjtVcR0tgd+Le8UyNYw
# DATA 1bR1pCUoWa8yk52csYV66JntAnpP3JhtGI2XRVa/8IZnNtQ409OZnpuYns7WfHFtzZXW4TVUq+YTHeZ0waIZNrDM0LdgdnKsQCGf
# DATA RLJMmGorNHuIZZe4871+6tbXX/KV/5ZzOndepR50vmHpY4EI1xzhasoJP+vMolwIB/xtXoR7/rieNNNOgsmCvOtw1BHz2+hf3fnJ
# DATA wmk/3sFHhbggbm49xV84LRsIi2fHVrQ9NgcHPwgPefoCPWdjmN3jJTuZHI3MoiD8iXsU0vhQlhdl7gQa4Tjc57lLyXvIy1lTbUGp
# DATA e5R9hloJl7E449jgmV/rCrEeTlaapnVsVAnmK9P9p+MBQk3jp9i6LsuQUr2vHO5x5cZThimjCrUfDfZm1F3YsLJ/Of7y+NeMJQNB
# DATA 7Bv+/Cegyxgb9nsQxfDL8ZeLlLL/3fz4q6Nvj74Biuzf+cLvj788+hMuFbyjPxx9xSiyX+M7buDXHf89/QGI7Hf0OoDMvqGfv2KU
# DATA 2bcUwHf47fgLCuZbwMqOv/AojK/owt/jItBojl32XFiHSBtPveAPYblyXXtvgUgaTp5glS8cRQW4PWhWOuG54ziU6Q8GGZqh4qg0
# DATA ryFBL8ObjTgw1iafxQNmo1KLDnk3J00sw6lAUiNs1afObC21TGDSkQyUDlpm24pWh3HV6LK5Urk8clk3lnOYqbnzDXWFK+oCvQzj
# DATA nrmTKp3UxMkFw8t4nh+nvAEBzYF3humoOoLZZqV24RQz3dn0Yn4uHIhTKe30o+5MtokMhB0PyQ8GOXMv5rHaq+cHxWE8gq0dDqhy
# DATA Yx/Jbe3pZXSGWGGTiAIWkEI8QhcsZqCyjKRNDgy+edOqudrEyTe1Z4UvWxt5Ry9zFsCFWQCaW3b6gf+lcBBd5aB/0WP+RkP+KUf8
# DATA Sx/wpT7mEm/Ty65F87kMblkuxV4kc/RUPFJM4faSXn7fHmfDtE+x3ON1EzS6GPs0jWXEiKNhOOaEy2vRR8m5AaqdoC5hqUUjk2S/
# DATA Jo+4Uu89I86Wbogt45xTlcKj7JjhdTLgAwgi7rIDbRhQEaSIpdfFgR+8/MkoOZDTEV21uRTYqHHERd1PZhOwv5hBFbfjAbIK1h2D
# DATA Vmg8YtwUjAXRQGA8lzlDoEBOo2Q5fMpxzBzHzHHMLpFjtuFIs9GUZwP7+OpM/LNY+Oc08B3IzIHMHMjMgcwcyMyBzBzIzIHMHMjM
# DATA gcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcyuDcis0qwFjcpZQWa9XtgrP0cgs9yK82k5ZnXK
# DATA k3KtX68396ut2tv1eQRZJap3eos5WfYpK2v9oNngz1VAxtTnGmUsf242PZ9yuForD/1muUj/qs++/jwH9aKc7/Yqy6BeleZCFCoB
# DATA RaFc+dRvlD3fB4LNq/jlqQ+3cfMkfFgjCBudpW8K6gs4NL8RgEvmVSvFVs3z6zVA0PyAMs6vMvmt1jrhdZ1qvb2cVmZB1IqYDoQQ
# DATA 6Jca7bWWgMwoLhnIjCJlQGaCY8taQK3aa1Q2zt/6kldVyo3sVVXfv8RXVYXIJq+q1BuX+KqgYqeqWb7EV9UZRadTVb3gDDwVVI67
# DATA NA2Vk97RgsrVKvVqs5uHys0j5JZC5SI/anSDDCoXdOtRs2qgcp16J+pYULkqvbdZv3SonOwuLMoygx7mqjyD8PTqlLFdmmL+2c/M
# DATA Q+Heiqgzj8PCIv2ttoz+Bv9nY/+gUBf/pwp5GG4GeSs11rk19fQsC3R+gcQ273X5LHg2VcnkwmFxixWur79sN6kD6+adXqezwzx2
# DATA 12KpajUYzsqqNfbcQpzz06JLtA4dY84x5hxjzjHmHGPOMeYcY84x5hxjzjHmHGPOMeZeMsYc6kI8pRn+JIQWO1Ww2wY7t3vnMzMn
# DATA Gae7XE+kl+Lzy7j6kdXypeHv3jHNPu5t/4AfVQ135zPFpdPKRRBDlTNfjDgac1ctxuXtz+XV3ZmsPe/aAf1YcHe4lCHwmEsnSzr2
# DATA vUV/58d+cMMPEB0d2h0JoD2j+SIK1cSM5WZZgXYURd0UvDv9DCB5IkOQGu2lXnQgHchYTuWJ2Bdd4hOMueQgo3GKcVeb9RO8WLJK
# DATA Fp+2eUK3U5LFh+3tsLBfiKkQwhvK0N7f+fF2TE2j/Fq9fMvfKZSx6YtbPdafdoe7d7aHd3b9Wq382odb71OV5COWHCoySBk+nE+9
# DATA QUJz1uHNennnR5XaDs3AuqxntV0pfLhVxt38mH5m+CO6cfGm21nNkSxHDdhOOdaq6sB5tMvx20bqGTX4H1/8EzI2vY0rN3aXFeZ2
# DATA /Gq+EF/zg1tlnZsc6u3Pd0qfJPGInmVwoURafbyx5JW9eBSnfSWK6ge6MHFaVhwuAkD86QgqE4IDwPMMPdyeqzBFXSt27GpBjYfr
# DATA kcmWHYrkbS5wKominlXQ86+tMxm55aHxZOF8hnGQjCF16FgrZ2hxCx2yZivqSmfmXRS4Pg9dmj5FP2PFUcJ+pMPUD9GAi7AMplEf
# DATA RHNKEU4pYr1ShHVM0elFOL2IU+tFrNQpvRQdiQezadYAeNeW1vSUkd2ISlxHGaOr0LEXY0Vk3Cdixcwp1+NSpluv7zedl7lghN7L
# DATA rVtqwVwJ16/Qo1cDLivST3GynHlIRth7W428Jynpm2BMlLIrmZJ+rbxMSr9qS+k3KmVbS98PVkvpWwYNos8Rp4kJzaq4WuXl9HM3
# DATA W/lmB7Ggls8xu1Mta/tjta5+jeNZC06+s85h1peEuaC9rw8wUrr5IOIdZRQLMwgth26VX1TOZEwoTBo4Tfly046P+UzIldN72XjG
# DATA Q6FMQO5Yl+cK5GJe+xDjJrd4+63Z1ct5qRx89GignVA3kXtz/qcM75mVy0o6gvRkChPw/CIR3oV/T6RulLGiLXlbOcNozHRpQmfZ
# DATA /blOns0gCH/kblECvFSFWXsGkjOsp8FwAxZz0AyCVRo0edEZmwq2yP9azgmTDMzNHzAS6hUK9m3pIciGgJ3IN3j+xS3yFoabl7h5
# DATA yQnzkpz96aYmbmpy8ozjmUrcYYxHBdeRQOYMMpW7N81ERIAHrPlk2hqVXpiyyBUEp1hzzIhQFUQ5bRiK49IIoWmxhvnJxRx6Adts
# DATA bOy38GhtA0z4mh+I8FwkhFm4StG+KTFUoVMzpWFGF2VP+ukM0dzj32bpIY25I2Z6UQKlsygoCJFMj/RAy0B67i7SJzrQcT+ZJnuT
# DATA cMxD9TiCIa3kfeMJS49JEvPD3jRkrPJ7yUSUddVYNw83FUSyZflJasUcsXBo3JGhbztQGGRsE1Qdm/jusTp1ABQ59OHuCj9NsBL9
# DATA 0MaLwkMOwgBLrcG3ty72cZeturWRnzceJQUGKSAQ4dQQhKHiPzWg5w4Lwin8hdYkzpT1hGWb195TxdJGly18AqvXDqX+rknTXeyw
# DATA HyUgt84nS8yEPDd2QVXRVGQyCx/Ava/ejHwls60Pgq9CNkgW8A8A9iLyWEvusGwbjJoCKtFIkgLmHby3ySxV+aECjikf7u4ncZcl
# DATA qVmlDQAFyVIaoBImxg4htTbmk268O2X5lJ5j/ddCE1EOcJmU6ThjQT0nXJ30ZBYGHbrhMOlK40bh8WVTVp4+PJf0evCp67LTGtZS
# DATA hgVvPGuThWI9x/pz3AjDLiwgb8J1WCorjV0ML+ZXeiCx06BDlnZKbXJdEh8BDa7gXlMMIlYSQSiTF1LPEEPbi7o7SuuYnu/NBoND
# DATA xVtRMWU3TsoVVdI9zJEKWVlQ+oSDfqLUEamDxE5QKuJJH+1QCgx9/DyiVgzTF8+edrQwZ0tvrAbtTOcX2nQ+LSvsGatD23v+18PC
# DATA HmMk0LBLNqqkvq+nhV0fNennQlL1JIJEtu9fs7wuEiqWV8i+aKbYvOL4UqSYcr+xmjcKlXehkREkNSIVsyYZ2O7QaKw7sTvvs3aJ
# DATA cMVoqsL6xDJpovfR77jnzTiznNF7QDJ7BLtcaGRUb7J7ZWYCm1Z2pyew8GJIkR2qm24mg1XNU+xl2Lmovjy1CJc5GNdiQuCKNSTn
# DATA Bf1xWGAsQzyeoEankWlmouAcmumqbLMhw36Iu8jOzXlbyeaGaLGthc6WNk8hJadmLEquDdyFdbYFW+9Fs/IyrNlB1Fbi1zbV7H87
# DATA +vroX4vHf3v0PVPGvjn67uj3TBejT8d/c/zF0Vc2Yez4S1xZBJz937h89Dt6+GtGlH3t0Zev6OI3dPk7kMmOfufxPX9gxtk/yH3H
# DATA v1Ugs69AUqMXfEn//laBzDg+XyFOx38HBhrzzn5/9D39QPf/0bHNnhdbVho5Gp4WX+clK0PexDoQzeFEXZwnbwkFN0WrRxyplf8U
# DATA KovMkBfvUbLPXp5wknmVLBIimsdalNnb89FwODPbps06iqummS0pmMsjmolPJV14ubo+f7vsIDB3P4xSGoE6MmBzIV0w2kzcS6Ln
# DATA D9eKLPwxtcCBzTYqvAvnmt31LL3zbGZgagAvGkNIZzZgCkf7EH/jNIVyz4F6IhEUO+feg5/S/aJpXtCcCr3fxUBM2P7ZB7zYo4uD
# DATA BZ7ZhjVztY2z2OyeFd1sw6Q4zpmzBs5qDWis2dmMgJfCqXWFBsBljP8bDf+nG/2vcPCX+rmQExbq7Jm0oMsgmy0kkulmlFXpYrTA
# DATA OJNlZY+qJ2rqLQE9Fby3Hz9+8KigDpaqlWEuGd4zOiH7gVd2OBkYoeGUyGhKE1WW2vOg81SPuZvizUxV8CivoQyWNwCQsrgDzFlm
# DATA BOQBZ+NJ1IVvJG8U2MZAgZspOgsPBsaoo8wDtgrAoRLzUJBTHP+UXpPRzdipkh6mfJRS3dN2fDPHN3N8s0vlm2021mw08TmVgXy1
# DATA Fv9ZDP4Ls/cd9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2
# DATA zGHPrg/2rFVr1etnxZ5Ve41e+znCni2sP2+EPuPMVZnHlDChbdUqucNifr2Sz/WqsJwk25u5jOs2oyDqzeGbqs0gEFTXPL6pJlls
# DATA xUPeLfEQ9lUWj+r8obVKFo3aPLZuGS+sbvHC/FbTMKhyhLS/rHWbfqO6WHOaNao6zb7UOSt5Yb3d6oRL+WnrklcRUtolJa9i0bw2
# DATA Th49dGHJqwrj65KSV1VPnyp59NC5kletVK5FI6lWm5fXSKp1/xyNpNosn7uR2Mm78EaSS96pGwmSd95GYifvwhtJLnmnbiRI3nkb
# DATA SeA3r0UjCaq1y2skFItzNJKgUT93I7GTd+GNJJe8UzcSJO+8jcRO3oU3klzyTt1IkLyzNRIb2FpuerUg2K/V+9VWbb9Yqw+Lfqvu
# DATA 1er71ZMAqqsbwVlomGzpGhomG80WDbParleawVlomOUo7PkWDbNaj5o1Q8NsdzrdbseiYfqB/Hy5NEy1mVdmd5azRy27GT4mT9jJ
# DATA RLedai1eY1+ybSIXKuavi/fMb1VYXDJr8pJZqYmtMrJolgtVLZivDbnOq2f5x/QscPlmw+xumk3uTcJhbo3upOSqZ5Yszy/eoFfq
# DATA F/J88e7Mi7hqh6S8yJciElfAQiBYalhEfapql18uaLVa8MCcDt7JHqMlqWK34YLveXG70Erup6N1Olqno3U6WqejdTpap6N1Olqn
# DATA o3U6WqejdTpap6N1XgCtcxHNuRe3FUARq3MwPRUcUzOo6MpNv1xrBo367dycRT3Gh4fxmEYckmE+G+PKDR9PVmq3FRvzvjrGDv2A
# DATA 0bQ/ODScK0YkUkyoXr2J/f3bFcYivhW/LkjFd3HOXE4pjwez1INgs6dexM+qKK16/q5XCX5k3pYJ7ci8lPJgP2JU5zbF4cdY499Z
# DATA FpLNMrTOmTpBGCcIkxOEWTx07NRhnDrM2dVhViopX6ZqjO6sIQch7QXFxUoO2GjDO28sCZnro2N2FUBDGSoZ9CEDGatw8NUTQIL6
# DATA yVw3n+aQbXAjLAUJ+hZHkG8q6zsNTnA1TdAM52AJqs8ImwVLxhgUdRK87b+OXz8JiGgFZ5JiXzOpCU5OS+UUyRBrAz0AvKJiEmy/
# DATA d3J89XMmsuaCFdPNMn3DmGo7iNsphBIhOZLZLdR1jePopOqSBZKBJ7NLJuqNk2JeXxPrlZA/0wXoKROPh6qQn3vo3zLSn7EQI9P7
# DATA oWeiOiYsD24eXSOvA9uAizQc8hyAl2dYEEbNNTs0qWK1aIaaYG8kTW8K3kGfKh8Zh5O9yApN5W6vR31tezaBbwPP0eRqEkGhKZ5q
# DATA gR/lr5aZR8qy3KzERFXqUAxk1sG061nJu5cM2S1GXV9BifWMukb/KRNdUpO5rjwRTpQuUmbLZJDZIcVrNmHfqhIf2oAa+KIpxTjm
# DATA iZsIrJgIOJv/pbD5T0s6uS5KkfZOifXIk7diHjFFLZHXoyESN2LVHmpbw2gt++TZyUs+X+pqJ6lLz+3xuAzwyaKA5kXDT5bpkC4F
# DATA oOTKTm+JkYq8DPD3Jux5bSIsvYNVPdfe8bqY1sbQOKXctyL/Ma4yZsFBgERE4zOcSpkrc3MTHOajbNqt8YpvP37v3YJ379GjghqH
# DATA pb3wsKC03AGxlHmRCC2OoRIaaiVVVmqkUjCyn3GazRs02I4beDzFsL2GqPhIOgPZ8LYeFnnXioSqxDpFd6EEOlLyqBw7ThAlrBuB
# DATA 5heNOlAEHUUUP6XHWqDaS9W1r5fZRJ41r8q6Fs2Z70BOiLoWnBVrWkdbwRTZ4FYHDCPxZwiMFGa/aN+zAT05VJKYKpYl74Hm1CDm
# DATA vDqmO7LQ64XxYDZZR7N8KMFg4WoVz/IlssDt/trZ4M4GX2qDq0riPPHOE5+z7lYa79dHv53rNEbqDOcceuIpNB548dXEKTbuJTxI
# DATA 5sXHtQt9nn42GwMnWPJ+hj3ihwbRQnd0Zx2IyAwxFhtpY+NvZ6Ix2zsbC7lnugXSPPH1zqva8HuEY97csKFfkSoAtsw4VF/w6k1j
# DATA JU6l955O8FGEufGqjjjryd6YJDQGU8PuL73hpzKm90BtXnHLBzDZkErR4maxadx6E++8qd8vg9F8NJShqgw4Y/Hwm7p33lCbE7kG
# DATA FzwMKz3q+xMqM8Z+UlWbdvlONUYUPBmMC1pqG5w7YIrTvoTbVdFaEY/3whHVqa5tC5rI3M0k8Od+lyjYppuxv6hEJxHEu3nxQFte
# DATA J0fkZ/FkOoOiOkuJW3FQBcxmHtdWlpTnPmWSDExkfjJmRRVzA1XyaMoq6WMePCmDBgNd1VMrPjdVQd1UlW4Fl3499vuRtvOyvBeT
# DATA L+wOadDXs5yM7aOVxBWpPe0ns0GX26WYsyNYfth4jqmVqKtLAZc8ti/JAh4kh0MOguxz8KxDiMNbMvRg0X+StHngVBLzsxGzEFVI
# DATA 64Dgo+RA6ZVr0zmc9nX0P5iwnD3Ve4/FTcTZzest2m/MTmeyximYUHub0UtRZ8f34AdmpGY2LpBQgCzq23liBFL9CA52Gs6jkb63
# DATA q1iP2drgusS8J65olZ5QxPPhVzfufeVZR8T0ekbGVehHg7Hqz2TB0+qLWAafBsokB1UYR+ETlLD0mKh7WLPsRkO8wJ5hKbAChSLz
# DATA QcbCoxXYUzNlx9jgc7P+ifoZDzdkiL9Ytv3nn3/0+YejrVf+4kX/j7I+GnyMDiMezQBVHR9e+Duwdlmv1f5CrRvP/euXg6DyF+Xs
# DATA v78o+36jXP8Lr3wVGTBDm6PX/8XL+d8Pf/jDhzMhRHSoA4m7PM6gUmylvBe5yNiPrIJ49959h3oNXuak9p0MuryETw+UKKxXRCqF
# DATA bNs9Pmyjv39C9qH+nKSv8OiFTn8Qtz11+QF91bdMzIPprK38M/oKjmRhONDfZ2S6vPLKBw/vPnhw/yE2UG9tbb3CZ2xeURsse7Kv
# DATA mp1N2zSZ7Ea3eunWDu9mxMmQLTD4blKveBNU35udQUwzmK3br8hW615aQj7AzffocNTZxkMFb4vm680tawfqFjuFigi9mOXW1s6O
# DATA 9i+VoqfxdNvfuf3K/L7PfNT4HNnH6iF6A/WOByN+cxZQ1EFuFbyfq8gsf/dHhVc8z/tsKqdIbvm83aEwDJ++Puth76NfrzZrhSdk
# DATA ZT6K90bh4NbWo3fe+ut33n13q5BOu3Fy6+dbdJ2Gh63C1jge4x/1/aPPd1T2qI2p0WRCQ88vf6k3qqYcoH2BF8tl4+vqLJE9xLu5
# DATA 01r6+S7GgmmijlWo/NfR4Adf44I65JfgYBRe/wM5PFSK00dhL3qH7KI9HFLA7SXk1z2sZO/gzrlr3qteednlO3zaZmka9BUV1wMY
# DATA MtsqvvNvpPuzU1vzQXmfv4JK/MorNIWGm/Jjphttx6N0TKPwx1LoPPnfuYUiRhbwCjouwQbgDyW2JlJMoba3ils7+GEQjbblQUpI
# DATA 4FdwDU9OohL2E/A24u3J1s/vFv+XsPiLcrH1cenmrf+p+NGNrfwL8d8kxFTuZ0jYfRT/9tY7o32c9rF6En5ma4efUQPxLrf0XGJ2
# DATA dCLkFq4s21Tzpx/jpC7FtOb92MOGXvXP+jhwuF70tEO2bioTSRUD2JuTLnoD9Ecl3v2wrd6JqvMx9ldv7+zk8jSlmE7DUQdVkR8v
# DATA eDg9YLJTXd2hauf5G+WOmuoqjGk0UbHT13d1PH9e/kh+0Ddiz7fcxIcSt97pUrFsqcej0X48SUZDtTfcvo+mc714j+797PMduXJ/
# DATA tC9HguykzleCsNijGvDRZ/Xa53SzicWOrjRW1lgvn8se65cd1XjOk0k4DS0HXPgrJuvSacQjOweyVywWI99fwNFbjuQW2Xl4WoLh
# DATA C5P5C0/L5blLu1tqz4pcy963PFk/HaWzMYYrml1Y0VSJwn982vNjSpn0FLxjcJteU/D8nfnELG+tH39kNduPfkxP4tTqSTHTGW5X
# DATA H3rOihlneYmGx2jUVQdQTXudDbdRyLilRJMN6t74nB/KHusQlD38NEq+EtQ3aL73rWgsa8J/ibUlODa8oeJ4vZF0nuB0Df6hykcP
# DATA Tg55+lSQ+XKH6yNOMqDg0CkLTI9M/5IKEjuwqO9VtDzYMpjTMr1PLRLdFvoZXFJ65g8fNEuGYrqY9kPsv5Lmanq/XYrsKOKL4shS
# DATA pkvpcQTbJZwcvsHCgsnkkIXt4qe7W/TiUdiZ4UC5GcnRedNUtatvzjKQSu1jZcVwr2pu2fFuelt2TTOPaJ95gu4kSUsghG3rcAq4
# DATA 8pOPP3j4k/ff/c/eL+XbvYf37z7WX+7/z/feLXjlBEgPEyanjn7udTm07BXUPR1I5Km5ReEwXxvlmhoo0Q5Ln1DBbasqc4ObZvaS
# DATA qZ1wzmjFU9u1rMQSFdj2z3O34b+tLtcSdJfyFD4Vxb2LjybXS1mu7+KwF6zLEv6q0YDUj54WFoMuFlWV4NB1f3ULT5tv/DZjTsvL
# DATA aZpd7E6S8e5dWFzLwk31Eg3Zp7ujhN5zUMTMNwZIJpVQqOSKKLkt7tFMQe4sDRCxpCqCJ7XNq0PRrQbfYaboAR8/44sysPPBflSA
# DATA s2A6m0QfyxbK3ceTmTp4rT+K9blbLRdk3ZSv7+QL0moxqlC1EQU/1Xg7f/tmw5UOc64HXNlCN+sm2RLzYvaJTe1eUuwLZdHP10er
# DATA +rFRJpkeTqdhp2/H9aPFUlv236Z57q/NdHUyL29gb57fH3Y/8wuBWAZsQ8PuHE231TdlJ986Rd5ak0yJ1EL2shxA9hLzaw9bPgZz
# DATA 3QNF22TsYjTWFNFkKOVDw1gnyhePJ9m0az39xv2fvf/Td989seToSZolLXsyK69AF9ebEHDYUTMAjETbqhrzpAg9t55hl+5O9tir
# DATA /4B/UUUnt+Es38eh+p3mAEVldFOa9N4Lq2KseoZN+KVP0G2wxdSD/A8eTVUkch02n9vYziYzuK+k4lPw5BtPMJQ1+xQYTu8+/wMh
# DATA VhPQX6oR/+Ybr3s87UwZDaq6WtthXfJ+gkE79Bjd42H30gheyo5H41M4JqNmzhB5xM79+5iFbb2fYB93ViM7xofe5uu9eDKMulso
# DATA I6poH38Mc+Bjst92va2PP0aJffzxlkRaiu+auhInOMU+jC7D7beZ/69Sr1YDf87/Vy77Nef/u4r//vIHN2fp5GY7Ht0k08EbH077
# DATA yaj6yg9/+EMW7hBeLRZfZGEMawxY8cVyRTKONPRWb+B6qM0oj2dbgwF1C2u8glimqNf0N+xp0p/7YQrfoP4aQx9sYjkBz+5PlBVE
# DATA 87U/m8YD843nEOZbOljthaT8MA7JcGL7I+f9k9P+RGB45gK1t5zzkmM/mwwo8tKJ6iTQNZ4HUh/D6yieTORnku0yemYDqRohKL/v
# DATA 2n0drGua/njtQy4iUzBstGNFZRJ9EqmlQOSNTEBTLjf93p+O9yZhN/oZhA/0ixfjYoYoyiYZubChbJumSWnmOZKedklC9G3qUZbx
# DATA QZHq52Twtxw3POHhOyznDU9CsUF0izdUbe3o8GSSMWa3qfIAYMPPrsxk5B1THIyZ6rkUB61nuvJTKU4/Tg+H2C+zbdmVnMyto//z
# DATA 6Gvv6A9HXx39+9E3x786/sej39Hnr4/+7B3/DX3449GfvOO/O/r6+Au69gfv+FdH3xz9mW75/uhPdDt++NXRt8dfHv9X+omf/hO+
# DATA 3vIwj4BlLzFQw6OKjpx7LA1h1G/Ll1TZgDyf/TixLT9eOt3V/pLeKp9IRKaH5HN3Nhyn+rdohHXOj8O0E8din2DLGcba3YqerIlP
# DATA plvgyTGrO6kJ7/AJuo+xmeWWsmkumRYU+91cipbYD3NTTLyEppaIVr7AsTR/gBnkLs8eV009EVKnTzVgW01CEc1Rsr0j1WJn9TwV
# DATA ubj0595gBiWahddgm/L8W7K7EiwvMIhMi1ZJOds+H7qHM/QHZFzQDC2fEjPl/7jXtWb0ufxU0/qHb9jT+jfeeXj/3uOfPPzP+Sgv
# DATA TLNz6bDfln9uqQ2unmVM/JJnF56RxKLllbgCp5wpOwtlNxtxG+QfVQOXtWXloDJucXinlCIbXFDVFQ7v7dduZc6zj3Lfih99Vi7U
# DATA /c+t33de+7C0c0Nd+OizSqFexTzIfrXVLfz3o2+p+f8PauS/Rgfxb9Ti/0xdwHf/P3vv3tzWdeUL3r/5KY6dTB9AAsCHHlagwG5K
# DATA om22JYqXpOykKQYFEockIhBAcABJbBpdTtzp5E5cyaQrNTXVVd19UzMfQFGsjuLYzleQvsJ8ktnrtd8HAGU7fefeTt9rEefss59r
# DATA r732evxW8uJ3yAle/FmxhC/Vyy9VQeAGTyrqmXrykXr2JHnxHEp8rP5+rtXYyApJUdgFOJSSTII6qLRHZBOOD9m9oDKzppKvdJ7u
# DATA kiveTcFjNK8vLgLv4XnVFcBWX2wNOouqrXQvPs9LV5aCafg/XnwKrE9xuSfA/BRDpOGpkao5QZapxv8c3gFD/DlOxucwX+rniy9e
# DATA fKFY4jOt61bXVNQDO9rSSuros5eT7zZYB43Fy/B7Zdb6QG+ew+o8h4ah/afQzSfzdt+weDoLXv7q5U+ArevFYx2BpcFG7QtpsLGj
# DATA tn5vhBg9+G9wOVfjpBdMBI7FR6+ht3ucKnev1ffs6mS2TukCb+tqY0v5ygv5R+tqL1g//pbc/cHi3sVySW3GRbP3as2/r6qnF8qL
# DATA b6Ws7A3U41QhuPH1ANTpCJXJanbP0hpc7Gu1dEIewOYVfrK7sieUpGatPGPo/njrztYm4sHIj6qhnQS/g8388tcvPq8YDiC7HXf+
# DATA E1X4CVSkiinO8OIp8ADmD6pymes/vfxEUdiXQJ5Auer3r6xZJSDD2E6msS7vwU6WcdtTCF92ekyo0ydhxl7ACfmT2lpqyRMc1B9Y
# DATA 2FE9fvmJknLsHrMiig0NgGxoczt6G2NzNKzzcbpzbX29rNOHy0MBrksqwBmcGEvDL7RnqSKwGZEweQXgK81ggZYVWcJzNH+oYvhv
# DATA oxFy6EN5yYXz8FD6LQ3j5ceRVfvi5cdqTpCM4Vj6FGnrE9q38fMLT6frzjtFxmrCntFEQtUByb78JKES8FBTAi83dju22uqWWhr1
# DATA H2Q9d32LDdiKXdyvTf+tuIJdpS/SU88/Bs6uRra6uV41m3EOguARldLVzc3m5t2tncalpeWl+72ttTsbqx+svr/W3FzdWLvdvLd1
# DATA u8FpbFA6ftR6mNUvAe5DL3V2YWq+VJ1p7tx9b20DjRU4CBLF1zd21rY2Vm83/+aDneb22s2ttR0swvffGhZtHmePS5dAenfrv9/b
# DATA 2bq3vdPc3Lr7ve83lu/37qxu/e2N1Y3m7bV3Vm9+v3l7feO95trG6o3ba7caiDWLhhpaLbi5+lJYbIVQV88aZLjfMLStCGh4eIPK
# DATA kKUK9evqlSuXrgRL9G/EOw2zIdJ8+QuiMEXBqi54Sd+7i2IakN6TQzCq8+YZBUuEu5qYQFhcmSINKoqCA1F1GYSEzxThfKH6/Qx4
# DATA zucvf8XCIL95IrqWiODH/bVMfCVjoa+7osbZJDSW68LTXARwNXb3HPkcTN9xszeasA80PN00Q7bp3q76ag/B7PC7QpYvbq1NNraV
# DATA LNvaIMuGubrjPMyGw46606ep0YUQiiSqPsRy2wfP4s4BBRYgfoX2mRUemuxn4EBMWhAUUkAd3PBnDZxew5nboHbugBVNC6RUAZzI
# DATA 6pvUvfFwv1G7pn+8FpYNTq4/IJNV55KiHMVznhHJ//rFb5CzwiPgtcCKPwVVhNoKSgCBSqtS+uUvHVbtHMe4CNQHfMrzl4fzwCPe
# DATA zkZgQs8jk5ETLTEl8maSCsNzOUGh8QuUa/4InQPpwTtUvuABwT/qN/sBgJgJ+0hteCVfqAMOPlLVwWkFE/bMLEl83tmto7hv88w8
# DATA HwWfqb78ks4N7kQwLDqB/QVgUVw6UQbKWQ4uaj3QeHUAdVcXVHwsuMRrom5ojWIpzjd201urO6s3VrfX4DRK98o1+dY2ypTey05R
# DATA Z1dJAu2j1562rvKKy6voQavWCsj0T7hywLqRGT4jAQRkNHhoZGlaUCVZKtb5h8TpuJGtuB/yp74u64sH3iItBgm8BNYfeYqzTeGJ
# DATA 9rvCFfF2AT7mKugJBOJk9m7YIncSVa6T44SAds7zaiCbkzFKi7EZLG1ZcVsbanjW9oWxkEJJSdNo2YdRlazy8+/Zcq1DSJ6BgRWn
# DATA t3DHFA4JjYfdDsL/qNnHP2VpKAALnmCHpffUs1X6SA6msqfGxM9IjTmJNQbGTVDFlfxpQ5+utFzr0hUb7n/SH/fQYjsE9ZscLqz+
# DATA YZoAqcoajnqOg0nXN1epAriIvtPt77e665sPr8pDr9dqcJqG1ecyYyzd68fSpXDimcIBqpwDelnJCEkJymWcDiEvW7GMFxgoUhv3
# DATA lNBduiAVkW0AfLzgSOP9gwpjLG7zLq4JFQnFyiCzi+OHFTLJH5NiTN0TPkOl+fPo8YAv6BS4LnLUU2Sxn+D1zuYQCeknnllaNetA
# DATA cLa9zEjskOAZePUTGjqopuLXIL8WnQ4F3M06B6RbNqflbr8yo3U7q8pRAT1tz+AuaB1cteTFb+jkfYpd/zm++COP9Q+8qn/ElcD7
# DATA y024YehxbaztfHB36z1PXopNsaTr6PN4+XeOzpUlLl4G31kSHA9IhG7aJ54n2LNQnONxFbRkZJbQYAIRWeXgCxLQCz9C/9j6QuA1
# DATA dDZxuLfWCkZE7dCrFUsT6wv5AK/9PyV4D6fr6TNtyLVdPx2Vjb5FoST1Ed55nyfvrX2/8f7q7XtroidRDzxPHbwJ6PzX9qWA9JUQ
# DATA Q4/5deFiEHU2UjVMGUa051+gke1TFLa+JK3Ej/Gibl2uWDdL2hy4eP0xneNSgq6uMhpid47bmHtfMT2dOsHeNVX9+b/ztQ+1pTS1
# DATA 1nrhU28A6uuf6ou3eNSrntmGU4mpMAbVhal+0Y73Nl++Xdd26yYLQi5M4x+Qxf1MdEQBHyN+DGP6koauBvWryK3WbFuwlDXz49bK
# DATA lav2aNqdI4hmbIiHQI2LlI2XrWUXRktYOtyP2wFhkx0cj3sPYJOhGN1tney3W3Wx6GEuBivuoFxJ9lNfn049qlGMcgnrc8bF74+z
# DATA x/SXttVQJGoTBqKOVOO5y5f3fn8UevWy1axLyUqI5Q1IbkWdLTg1w0jAHoxn9ABM1vCB+gkn2MBYErffXVUzt33vzrbhuqBlHDhW
# DATA 7jkiREiDRjWXTWewm3MpQJBojJEcrSdI6E9pjxJBqY2gD2syxcJwF+1xQDQE+RA75FO+mCZJepF6eBEd/r1eypo8RDSCJi2NmfcK
# DATA nSI9MHanFB03e5nQQVwEKX2/GPYfoSgY9N32YiiT2gQdoW2pu9BUotahVT1E39dykpS81SmD+17/UbGhRMwAKMZDt6MSTeHKCZP6
# DATA 0pJh8LhgtfHLn8IJ8rHiWp9b7BaTMjZwBhdjdgi0AsdIUV4wWaunAbMAAhc7R3Qs/+z3kiU06iUo+qdRYZF6xRodTiMK2DI24QoM
# DATA eqXOe+MtXqM47Bq4XbCX8CjzH4qrd66fsGzjFNTSiiZZVDsR1dpSB/UDu5iKAgxdPsTI2nUqQecDUGn5O/pe70EPovU17Ct/kXrB
# DATA RTzu7zZ8ErPIC1XtshjuCsAjWQE6y32lCU6anHS0v8J5LMenB0fGMfrwCd4NraEUD38D4U7gFXeA5iF1l1vOh1SSw1chd8Sw1CGG
# DATA 2UHuDWgNGE+DFe3K8iLCXLpXLsertIbrUUjZ3NeiX+JRIIoC6MGuHTLC0wZ0dthRPRuiCy9XvUfRn9Aqsn1x1zDBc9wlHgN3y1kJ
# DATA /U0RVU751mKJvc4hiQTWRMzzpT8boOPY5SwiKRniMC0NXkKokV1KOkKjp/I4hqyd7jncVT4gOgLiQFXQVp/yB/oyhDtsjONFEqgO
# DATA +QOPdufbUP8PH6jMkv9Bca7fK6FYXZVf/qPhYqSqVMwc78pKOlPXURBNAz6OPFBzSBKd3SvWwDkFXRMIc3s8KN0gMpult/bzfhfy
# DATA qVkTxF/qehfhwcJch4SSyPvdh5gpKG8Os25r1HmYNUd9O04KBAGnLJpUw1ArR6Svamllijz/CxaIjQMgCfFPwcKKM4uKDLDe42X8
# DATA xe/h3KFbyxOc76eWGVEGK5sGmVV4HM7uMB5dv1J1q9s63vF/DOy0uMOumO7O1QJTQC8bj4YtAJIgShCNhJJrNZYMoAjB/BvbDKAJ
# DATA HvUgxJfyKHVbp9kwTyCTa9I6HAGOeb+HCWTRT/Q6g7VQEDqhreiGtKUm5mBj+JucmPJd7bR10rWPUvOCnlNYSLXwu8L36vVeSMQG
# DATA WWcx0Xp1fyMULnHE9zSqX+XW3H1pLYS5BlqUhbpEXKEZtQcegrz6GAqiOuqFbyv+dM2N38ZxmfsobLizVNCT0npyNjGaELE53N2e
# DATA ZnJwe4Heqf7M8utCyfYJSrTPcXeCVKvd3EXnh9IGbJOfsqPI56BmeKqNPGygeFrAb8nSRtf3T1HnRmpL5MXPHEWE6wljFitmF2XQ
# DATA Itl5wT2SpbL4FcU6PKnctJNzwbk58PkWO8Kxk8m3Eka1JVwmBhrq9Kro7Kqnl7G91H3+IYEo9bttjdqE5LTgn6mznLCjlxQQ6lHt
# DATA 8A+gUH75E+lANbhbUvS9yBPSKrtQm/3LM4qFZPIi4uZuqucc7GmGc/KoqDWnFMiaIBuaxlyvCIM6oOUR9I+4dGn+2XCOneK5EFWD
# DATA xUtFJvJ6YJrWXvSF7IckJ3hsi01GSego10JJqz5HdKKQsRa30d8EYSwcMa9YWTrDUaNwyrSXsiBR673ltuwPQspHpRn7ZfzaKyXw
# DATA pkIt0Rt/vs5zCQ4HOcfN111L3XPUbmD+JXU2II53VpIgDSuQs2uwBtiEpNXHsnag+ofrkG1tOsMT7JCFuUrSBDAFUe9McFKgWIFO
# DATA 6jdqxL9D0wcZjZ6Im2oSik9PQ22UJAR1iVdv7jkuARj1SVZaIRcI4C+8Cdi7w3wbJR33dZx4TBmcKdnaYZejypRNM3zrGiwdpmBJ
# DATA ifXBTzIC2iYY7fGJrROyZxJZq9U11xgvBWexzvl7zD4/AHDYUjN3rERNU4/dyWHnpIU+1MUCltU9Lu7dEKUStiROp99XmHXANmz1
# DATA kjErZ+S4RabregkIQ7f7TLl7/OV246NoM9Ize3DFEVNAdm7kEv9j7l6vOTJyXPd834oesnaIBgC4hP53bkOkmzbtixZ84+6tteb2
# DATA zurOmo6HWV/bxh3LTBThgeCE5c6YcaGSvYi5zlgeytvkpgJOjZY44HxiDkV6cOzT2kblmy+tODEOlznp5ABW7UaFkaovjxsY+Xt9
# DATA IfH4BscqwUR69hjulYDC6Gg82w4STh2p9aODb+AM/FWy1H/jjTfMjVjPsh0gvpURigQjB2cPO/1xnqzfWX1nrZKMc0qMAP6AjzIr
# DATA XXRvxLo/tVkGgIZp1UhId8mPxv1RK/mhIgk42HEhH2Fc+DBTUzvOMPq8g6hFkL2rzbdYDMsYD0y4OQcjEguoeDsP3Qn33D0q9zO3
# DATA pK0ddCcTb9Lz3wDlIMWv1GJyz4oWCMtVgjub9qHttnpNApYEvXKTpfkSDa1Cswwx/wfHHUwDb7lyMuYIM4R2A0haFAf8w1JRNqlK
# DATA fGGrFej2YHJNiAeVDnlV2xCowGI1jzqA04Zr+qg1bBt9Ath+i1XCpFbHYBMezrRygeDxT+iCYSt8/kTWUYoUeyJG3gSltGfq8vkx
# DATA ecZ4WiL0EzHq8V8W+BR6Fl+ebEHCciDkYkhxig9TsmdgwvmHAIv14f1vR6DhbO95x7mEVIvQr+cv/kBWbFBCKYkaDUkfR6aCLyxw
# DATA 8cYIktjQHlJgMuZ710vFDwtHz+/d8ce81C+W3qrfr9Gf5bPlCgX70dfzDFrcP8kZ6cdovogPlcxM4fiEtppmoC65BWMNvmB/Q/eI
# DATA CCfF/+4VZ8evpjyvQZHMPPZMuU6/EembsUvQaY0M+Owxkyieq6TdEng0qHv8oISgYI5bek0dSRAHtbu0l1xILpd365c9MQ0qDmYF
# DATA 9gS9mTq+37JXBFyznyAJ83JzvJEeGeiNPiVtEg8cfD+mWSCvk94eOMW/a46hSOqntJkcL+RPWbH/nALSSeMrlGWwoHN3+9hvuLA6
# DATA ApveBy4ZRr6RLDt+UX6+an9RCVow1iSfTq1Cls8K5h6we8iczKmTsYnUO9e1s3fqt8LOklN2gAkKdm3uAL9n/CG0q6bTDa99NPyp
# DATA qXEK6Zur/6m/cf2ZM5NyjkHafQ2Wwq/KR8ekBbUWY/62+FvtdgTTIM/0DFiFwiFZfsgBlcZaOodfiuPdQLHa/4g6xB9TbKbHnwID
# DATA zjMdT+hzLsqtAP3FBB3O9oMn2yReAVSxu3mcl2T7ZkmMnNaUTEQFtYCG3t1Gk9rpyWz5u8V+pytVz3UvC2Y5mM9/VfNDU6C9X/+E
# DATA gYW/CyI5vkSW9DH+9ycvnrKMc965HAzQq2KXkp2wb3qjYXqOjnuBzZspwolkB/qjCg358W9N2BbFFVIbfxPMzX9XQ/odBlc+efnL
# DATA l/+NmbfMj4Q0RLVuf6a4FlUBSw3gOv0TpNiPVU3PQjHqMx3zwgAvjYKoMXax39zkgEELXJYFhUsron+mqlDtfHnpO1dlVg6OiW6w
# DATA HfKvI7vbfURWu49eKwinuhfOyj85Iy4giqg2+zmefOiMiA+sMRTp7dnFYopyXuu+Cy9R7B3pxNVFXTf2orAEpIxEzf2KzfnYJW2G
# DATA zvJfrChdX8SWefmC6eyjQI8ZsC5RZWrdlmQG4LHTc2f42LFKcDvKszVw8t1ENMlyWVv/UT4DUQycpmsAevQgO81Luxe4Hm5iz/6k
# DATA lj0egSp4Pvuy+PLZ6nfPeqEv0lB7PXA3m9u4PsfBEaqO44F2uqei9z4j0wi6oZL1DzzCSJlfj/i6BZ3XHsrC8iHVO06EY39Oa4oP
# DATA pGZuJFUThd34l2ygUPqrHDtbtKuR619r9gWVpk8FpZQwqN1ZFX9lktOxOCktp3jg04iN2/1c4M/nsfzggmqw3UIbL2K1RBd5iguM
# DATA 7iyukm31tR1cjGcMDdZZSaPNsT214pTv7j5qtPzN7gSzA5QMBUEtxge8aL4cj7Nval8o/sGumIA9V2tn2QD+YEWV5SloBCo42dOK
# DATA cHmOFgft8GuN4GGRK06Bf8CvxEn+CzSrweGOyBQJxEqpOfs9OONguKgJEX/5sRztNkaCJQxGnGDiUpts/obMyq7Z4Hs4dgNaEd9a
# DATA XDwIinEDUGxR5XNtlig67R1xu4hWssPDDBWEqvMl0RzOYlfzjEhXPG1Mxfoe+PFHGQ/KedqHtXD1zd3iSdFwEbQa1lZ3jwZIz504
# DATA 6zAEiQoFMUhOvTDWUiR632XoXNxDBHCmk4pQ7zp9Y7Wp8VqAUTOjUNrUJuAqpCJM48GmjQZeUQqZ9zmuHagi+ZwiUoDYTLQTR6px
# DATA yE0M1MOCEQ73nTAsl76ivlTDTNF/BwRQIF5vRTl7hkSU8mL8NS7G7tJebajRivBJdVnjF9WljL0cVluIhqR+jY6GBCQuf/+I4dDb
# DATA HXys1hSSAQAmuJJRHqOjXKvdxidKIMsOOw/SqHXyxb8V7lzY7D9X1A+C6c8wVkutz2cUBSoaqoR20HPYKLhFMAANyiGY1kfoQflL
# DATA +870sbUwvA67PIEQyYV/+QVqg/6glO6PO11IpIFGBMvms3PcyZmFAE4ImBD6CFcHLk6YHEC7eMDr4aDfJRM3nJgiK1j1DSEfatYD
# DATA +iBgYrZBQV6BnuoRQHB2IXhHVdjDxAc6fgzgitWBWAtHaEP8wzjPLlyIBTz60pdJQAFnqHVdqvPlTYMSpqDfT7/9bYlN1iRqnzIx
# DATA rmufH1rbAZ2yzFJ2F8OK8Sa/F+szpwJRZQnmyq6HnUzpMzduFhXjdFJY6nASC6R3se8W3IB6S04OOx2GygvnKjx6o4yheKKmrGV4
# DATA RjiF/wc7IfTaFc65NjkOkTtKyfWN7Z3VjZtrzZ3vb67BsgI3UzsEGRnh9PYJbP/gOGuPu9kwnfhaQ/pfab/f784gPebCJAk78yn8
# DATA udFIiqrQPKhc0AFr5tV8sG4UWlK/rE1Iu5DaEsIvO4ctzxPoEb7GY1cLOSa29gkZ8P6AOHXPlFj6nMODHe+p6YcvwdritriYpNdD
# DATA 20iodXWCR8lMpp1pnxabUbX/urYGuy5aIT+oW5lvUKaMcBePhrv6yHaI2OjPLPkSvnC0ZfBgblXZbMHzy5jg+SyOSYNm5s84Rn+G
# DATA cD2Fdc9i/zMYOV3FDrotuos5LU5lDWpG9Xc2Q8c8sfwitodeQyCcuNgyfY6eOjcWATO0oihC27wx7f4e1iYCXHFdCPxzvhWjcfAL
# DATA kXrA8kfAfOekeI/qz9xprCfIb2KH/8QNpHAvx3jLtbFMdfwUMLqGOHCE5r0GacMria0bbeziZZ5Uf+U9/dKoEBt2ASvzVETutnyQ
# DATA Ed4O0NUDw6P95Q4Uu6dKsWxQWHCTGD0hnRh9Z0Fd/pYv+GJTS/fevdP0fqb5HaN+r02q+u/Lk+pl/eOSenHtO639PeeJ/L1MfnK6
# DATA sTibIVSPqTCfYWDEk+R858MzZP9PyDHiZ4CHIq4ABk/9kyBCYrdgAUAQNsOyQyfOtKdEPVmG6B2t/q/7fqMoS5DnJmucmAbdTC86
# DATA oBOcoPTf6mPSrKFiyqiyKEMUOHjVRc8i0b7qCY0KusW7FkrxnxX3rN42nlfRrTARX6yZWnzUhAuUroZEwZ9BUEehJcQC4sWLZswX
# DATA 33bbJPTHa5Md+uPq5G/ZQf++xDZjt+CS6wGA62Q8oT47Es4qYVl+wLQf9RUP9ip4Ct9S/GvQvIlpDWCVTcc9SCT3SHfAjr6EE0Xr
# DATA M9ARLGbIqavzQN2df4fHgxwfuK9Y/2owqatVO8AnhBIqXGHTffCVsXMr5RGFtDvxQQBhbnA+HnKakZjDIDgSGpKEX563EwKTYASn
# DATA fpf7kGtzeuIVRsr8GZx3wMpWeOTGtdihyRE6OSscqGSVpKHsFX0S+Eq7xgY9IwcBQCUrsb1WXGV24csIAOs8E/QlBdCgUxcLS5/Z
# DATA mu0pZmvbSX33AnXMcF0lM1wwg2Wui3alMPzS8lsPoo909tViQ4KJnwgxgGBHcBUzAnBcbCDxZ/AsI+TpwC6SbOYn2z9MqpzBv+e8
# DATA AU/pHJ6yAOwv9hSKGybhBCEiRL0O6D7pjIq2JJs/mi7I0PRd/KpbYp5YC6zDi7IQg3MkcC0goPrccbNx0iFLdRCtGQZ5UKcsSz8+
# DATA MJZ++jk/a5pl3n+quRdBzRVSh4OqY9zScaJch/TZNvRC/3E7A0/oOm5KGOLyWJSONpeYVyI2R/5BsY+p1Mb0Rrdwijzti+71pNVT
# DATA Eng7AbWHlTeOnfapEXBdhGTm8K+4kduu4THJfU6PwXMhkwvV8C8lQEDy9vM4sVmCNj06D4b5X3DnssZdAMtY6HZtseaAEuossLVa
# DATA TJRcz5+ily1hqJGn8RSWOX3WaFfp+wlUEDrjWYJJTHoPcnDbLne+m5l3JDvOtnuO4Cu1nMM7HYCS0cGecSHgEudr8GbTSawTMRsz
# DATA LZujI4LP9r4hA0cEMF/xHdxLkxjnEwcAwYTPoPqsCYFcTWJPEshV4mAXYFbnCr13kcboHwdmrGfgw6ENvSGkPRc/hTeDH7VHMjf1
# DATA hgLwuRoTY1oEkRRueSozS4KVUkbu3jPgSSKrzx+0GUTT6RA6nJVIzKYPQOUjBJmhz0IJskAHvskOB0Gmc7DOAJFI3ahcycTlo8Gg
# DATA I8Oduj1lWW3X470i4SokxPlCR/9XDRstphkKG2XldgvpoZuBpbj/qAcpG3utQX7cH4XGbxvzOX3Y745P5Lgx7lSj0wGomNL9Tq+N
# DATA 5jLqdN3ONwiGflqneuIOjYW2VwpdJ35rPgWJ8JV0cYnraVt32Y92wMVySJN1j0RtjRz9MXHZRjQM3rsm+kHqNLx5GI3ZyWWLS2s0
# DATA 0a+qKfc7EsMVpF9l68gSTFL6Jcdgc0xZQCUISnwph1k3a+UZ56yuL8x0vPTAZd9MLi8FmkZ9t+4pwh12DrRDqNrD/YcZ5ZFUhE2K
# DATA e+6C7wY6PfPMdyYmcg1/6ug1brNc3CuJN6MIMx1bxh860WWu7gs+u5iUlirl5EJSupxU+eKnnpeDiUZbSskOrpwZw+mHbQZDSNnT
# DATA pWIGox1TxE8m8DRacF2VHGznUesIEUm5jtrQAneup55wKxjK4NFEyazU5/UQSJkrC7pqqGH2Oi4UIqamJbQ+c10XVV1lVUW19DB4
# DATA XH4LX7xVb520r17+sDU8uXpZPcRz4sgDZTKzI8ijGiTf6IsqFtZq8NJf//GAgIhLpnI3G655bqf+K6VHxwfDWqdv8kgtkleX/hXS
# DATA Gh8bTQZQN96cWpzSTZuBIkpFwyfYmI+EgcTFxdDdDl3YFjyfmTPjcaZ90PCP6mDYf3zq/azSpX5oO6hZ7m2hq5vxcCOnt0lAjQZN
# DATA bG6vGnCwwGjU+Rwx4g44lme7gymDdUddN9Dw7SK2TvPvCMZHUCFgKTaSEqvLRW8uZKSlKHiF/7pmMbtYpA+xjlWivY2W9JqCc0pJ
# DATA NE4vnb5N7E1jX6lpxJChA/6gOyhlduFJ5G3SysFBzz8Bcx/SgCQlEzvNv/l4soAO8kap7CSdblpwtOFJ69ZrZ+pomnzexd/p9uWo
# DATA NugfWuK2OsBIIkbstRoJUEbOE8o93QFeKxF0T/Q8G0Wu7knknT2FccgGPhKGDxgcw/j1P64aeuVZ8jNWWVuUqgi8wh1UYdiLVC60
# DATA Q9kU5vsB+mMXcd2uSxvArKtTMDGxD3WpVAsmhpsPOr0e2KOjJMWs3Uyrw9j5gJ/j5CoYJMd57cbwG6Rne/OMVr+ZLy7WXmM/Fl4V
# DATA LIyHh88E7Nh+UwitXCqO7bXdQ+RpWY5AHoa6rhBmeFCx0+vO7BM9N6EPNHb7iJ+EWjxsuR5xWJ+LYApbLUeo6PyUNH3LUP/8KKs5
# DATA KeeQfNmIXzsZEy2NZhs8wbuRjHicFdB3tTUetPQhFb4d98tlacmWItRYa+SOUBM9Tu7Egce9jsR6W/bdQyP1mbKRkKZEKEMixD3q
# DATA iCcw85bUJ8wzpoK6OyvrRBrqLGcJq85dn4RC6RzxFXORa6wDzsSeiy69vmDvu7iN7TXoD48wUYmhrxrdwlxQl+mkruvuRC7q8rIc
# DATA ur37W+Rc24NCPisGrexYEVCvwm7ycikH5udMTCkcRiWQQkJhKnXQUSgjDoOgPEOXyidK7iMlhCsglsJBVQLJJhTW3PZc7wSM2f8M
# DATA W0RZqijqlWbIowvtaTBLo8L/BjhdUoPv8yrP3+SxhEFSw1ZHrcg9avZ9ahWxlNn11cWTsX20JZs9ZG37b+RoXI+7uj7B72gK1IcV
# DATA dk5C45K8JUrx3A0Ewtg2AGsvI9/GohGY9HRVjKEmppKaao2JGUcWv3bTCCyW+VbrgoGp2lVKF01JJXQeO3jX54P3LcSUb0nYZFxr
# DATA GkUtYA94gi34BlAJUs+B41zoC9S5AMsj6meh8YK63ZLn3hN4OcyE1Qf3nCCG9eUvIZJNkskbjFl6Y6EwGYMPE1sRmoLnWFI/Fyap
# DATA bUrH5C7fpJ8mojACTAOBekukHCW1I3PBOFfn1f5pkrWG3Q7KWMyLczqjs1bbqq6PaI8DdYdvjRjBsaMq75xk6qsTkI7z41a7/8jF
# DATA m62FMAuu3+jif6TX6OIMn1Hd5/8hXUbnoDk9AHYaNYvg+YwuxjxGXVhSG5qEXUjd3VCTAGG3rnoEdteFN4i5adUD6AZzrbA3Evsk
# DATA 93vqDtb1MzzESMPRFsiHbn9MfcU9ouUP60+IASOKNxzUHqQSOa1YuQ4kLkUzZYhH4YDcf9d+glZQ9ZdOrrZf0bPzUYUe3ysjvTBD
# DATA jxi6XYEhkhjK8l2cAvAgB6LrFBs8hTMkRBKyi9qPTWFTQazWvyRwBB/vcAgKAywGEHM1AzQU1w0piupEpPOlhYlTDJ8yBQjCjQB8
# DATA 5g7Al/3qUXgIR7yLekIgh55awsMTsS7s5gYXNhVL9OY3Fi3jNVcyO61IKW3BVlBNMVnZ9NVP/BzDaNKeURdw5wlG0yvlD5mSO8Tz
# DATA KBcnviks7TqCf1HeOHX+/UE9/aPEz31JMpgHpImPDFKuk/TD9xjutbPHFS0JZmgabGmE6pmwObFsOG8m1y5ADhz8zxTHcAMbhS7f
# DATA z1/+XHLA/o7Gqh646WvRBQeMNxGUHMmdUXd7WUkkHUU9CVNmcIY6mAQoeUIWlaX+1aWlSeHAPdQO1SdRiSKKtzclNqh3JSFvikbg
# DATA gF+O+BFHc2pUJD1VcaoJO+IFl1zrN1RNttOEkOls15RDdj3hCifTXClsSbQp55IBpKNzycoEivjpStxtOKkyZvI8ceCKmTXQi9Ky
# DATA BNQNU7CMFPWYIx/YS3X8HP9FpOBEixV4UxpZfk2zZHU7A2k+T4DXJJDe61RupYRG3hqCshFzphKaO1Zq1QWzX0vWMIEYCAvqsxxB
# DATA 39ETrNtmSOsBAHZgIyxRoEf3qBaHWQ/lrVne7fZeiMuhjKD9tdy4/NuWL6sK4n85KBFC/c/vn69lqa/NPynu9W+FGHP6rzX8R1Gb
# DATA kzbdSXxl77B4te6+sxgBKMXkHt4beSBClthiwxSgRoNgDNxhkUqr3cnx9luysO0t3aZmKIxpL9IuELONZq/tBXHzghXTFbEhsDw5
# DATA 24SgVf6eG+i5LA+aJ1GjrFzhMsER/89hhnCEOPW80DlUjOcfPfIdSG0vDEqdij8xie2L5OVfaq0LdrUJe6nEP/gE6A8fEGi1qyyc
# DATA 33xS4ypAw2cQnKIaQS7pqAN1B7gH6WJa4MtvZb1PcOYIVul5YZKvQompWjXHXAECKjzY02ZufsBy6ZzzQodBk85MH9qq4jcMW6sk
# DATA k7GYDKwp9DONI/d1VJb02AKipsCVsq/om56s3JlihOZ1wGafJZYKcPYUR1QphKsRh+SdL5czj7cALkO2on5to+PGdUqiCAoHa1cN
# DATA KSdMXdcD+dyGNoZL50e4n39hBc5wAghPG4q6SafH1ELzvbXvR7bB/x1v+BmpmiG3LTWprpF2PY5m4Ayhgk5aDAtgi0EW1w7kQKZM
# DATA 8k8mHloXtuLBBHhuyox567gC1BPtdGcug+SWTH/vputtJYS5FTv377raMlTHHkr9o2HLQgrY3ZtMyX5dd894uNl3NvtDCrsZqD8M
# DATA ABO6v2/e3UKI6BX1v9T1c8UK+CRUXejlap+daGep+JHIjqyOi1TFBTcghJE01Z6IUYASW9z8Sucng7Kf6xS0/E0YHaXY38RDYg/j
# DATA peaCNCwET2dmlHqXDhKHtQ9jDOoq5g3D12LwPoSfZ6WD+WayPHvi6i7zK8dBvtAfw/XDmBQDs02FYyvF2CnBewXkBo8Dcbk0xQG0
# DATA /KrAWx4vjoAYhr2LfTEN1TBwV3pVpMooDto3hFP5H+X/+6qwozpTiyvghjm3SR/7GXgYaDPhr1/8ppIwxlpU7enAO30D0IHsu4wb
# DATA 3XXaKsLfM1euvvasLNhfJax9Trw+ywVcu65XnfLmsfWldVdV32t+h0h/LhecDunnll0ooAiR1gl6z7RYf4U9NxO39By7PH7GE5r3
# DATA VII27ilTRFJH3zDsj5S8Q+6Jai/VpYpd9YPiktUfZFm1BDC8R/AL/mBSXPeuJXMgK4Q7N8gk/GmxXFKOqWlC2OrInohiYM4MUN5F
# DATA E3fNioJppMDhwBemAeoCM6aCknvRBm1gpkjtoLXSC4E3MjK1H+LGHREvjXd67xwDFDMdLJwMiLwveJ0rxhlD90cOYVlxFnhUxTH9
# DATA FFpp+ctzzv3ZhQvqUSW5cEHXMAkzp1ec7egAZamvS6qvgy668x+rk4IkC/irCfTmSqS5EUalLJiA+7CzSvJEjJx5/ojyihPIXl4j
# DATA iLLj7HHp0kp5Qec+QPEqBsvnfaFIfPPu9s47W2vbzc3V7e0P7m7dQgU/NeQFSViF722vbWGshHUo6pe3briv/Fo8DMFD6zitLy7K
# DATA j/qZdGPy14ZJt/frVy5fWlksrv3trbsbO821jVvNW3fvrK5DlH56PBoNclU3kJpZkXRzdWPttimm3/hVbt+70dy8d+P2+k1T2BGk
# DATA xsNuXnJW1aw8bK3da3W4TL37wfot1bPVG7fXVO/W3l69dxuWRkkZ4ywcyJ21na31m2auW+2TDvqSyAtYsejKrlwuB7V9sHbj3bt3
# DATA 32OCaL67tnoLq43SBSvk1UaFAEUmZi0pu1uUCC4Ukget0Sgb9jDO7gcw8cOshijUGez8MgbHNWoXvp26cpukh+TPK9gLMDrW7nhs
# DATA lLsHn4z3TXnO39esJwGDkcoOu62jvIFVTslfi/VfbCCOqqohZFcX8ZXNHOATZgYI9AC8gCYYAzv3M3HAox9yKeZXbpwj5j8SlFc/
# DATA JRL8fj29P7zfA3jX18/l1oe4pFqvcR28eDgbFOs+zQnLSaRs5HXAY4c/yJTIkptjuhm0TsFwrQYH1oYa/A3Gqzy7erm2f/UyG9Nk
# DATA WgT2iQKKHEfpSPI3rhtP2gdlFyWH3+0+YIGBHbFaN7PhaDM7gZ3zw0ejzfG+4tvvMSK96on1Gn6qN/DLB8wlr9f3Yd3J2dWxLZTM
# DATA i0qyczqgP4NVsSf2U9DssZ8jYhRLisUnmECANH8GQO4JIMYAMuyP0aH4Jy+eo06a1LOI1PQ8nteUKfPwdS3YNM6I3ib3e6ZDjfSM
# DATA gVsVTb/ONPyo1RkRYgky0JKEqHVOsv541FhZMiHFVqQAxrordnAH0UcohFCtXrvVVZJkGgUWCU8+1h9BXbfwiWA8uDvHKgZNkq6J
# DATA fXrUunYO4YjOpiTswtB6VTJfBKPawbFqqTZQ66+VXKaWAFACiG4p+a5TxjPVf7eRLF9aXnpjJbpBf4dOBeBF8ATufm6im+hKP0ne
# DATA 3dnZ3K4aGB0d8NbjlPd2b4wRmHVZWeuQWaYk4a3C/26svbO+kdxc29pZf3v95urOGj6tXXgL/1VnafAutXJrq+q2HeYFzQQD/m04
# DATA nGAwfGW1tOWiz308kPuBlyU8z7u1zbU7TRh2c9RXx+oW/l2CTqijt1yuSbJwM1F4cMCXlOS7ySgXTX5ZOmihFQ1uCNZ0lp0aagy/
# DATA g4dJ8iHV9/7a1vrb329+78rSd9TxrKZs9Xbz5rtKYnC+VOd452R8YqXihW93bm+zOz38+XC5ucKe4q22ojkgYth4tZO+mmLwfSvB
# DATA Gcp7kUxOx2BKCQp9V1dhYakEyGqd0XGSg3ZtJJOietsDE7u6IZTS5ZU3akvq/5ZTfZIZRqDGU1qBsPTHpdpyRTdX9bsCiXJbueKl
# DATA jyJpwaEDMkGPhq1Bk3pTUqVJLZcNm8InGlq4gvoU4xoPiwR9RZI+xVBxYFaDLBsiseyrW/pQrWV/eMIHkaYaYGBCfvXCa5UBuSeM
# DATA xY/AP85BuwL7IkSD/EzSk9jAlWrBq7ThEb7+x2m54NZCXc8zYKfd0mH6ztqOYmGwjxaXa8sgELyrpqaenMkMTeDZTb2U6mbdBXcB
# DATA kBzU/4f8bXgcl8tFs7eytARsrIO6H2pesc+HpSvLK6KnK+8u7wGdXV5aKp4hi93bJ+fdbT427SN0HRyG/DNUrkCGiIG88m6WDUo1
# DATA vv3QMrhsxU5kzGvwEWJM/ymx0C+/oKSYLz+5Lko1Ct35RPIs45pWomwZE6f/OyWVAVspCn9VUjWKNR9/cR68krmD5B3wLVDHlm2y
# DATA n3kRRBlGvU1TPHulDh12jZf3w5QSEAAcULKEu3dJXarw2JQvyhNgPdfv96yiu/X6XmE5R9w9TNOUdmZydrZgVTHudR7XFx+2hotq
# DATA 3y1qJfbicNxbxImoweaGKhNUuTbhrt0/6HevL5zR4CZySVe7HqfCEPR1spLk3aZ9xEdaG3W9Uz36ZRME+4KvB8POQ/Xa/Vb6mifI
# DATA pmsr/O8lKgKi0krS711fsIaAt6s86R8eXmcbiDomF8f5cFExpWFGk7J4PDrp0vvWeNRHrznzSQbboYlAk5eXLieL6j8164N2W13e
# DATA Wm21FN+r3qSTuQqSaPUuXUgVTea9zqGSqruPWqd58NUWAKYMs2F1s6+m/xQk687BiD35qo+Os171YNjPc37iVNPtkyIk+cHfJ4uP
# DATA YQLAW2ZRiAKPvm4HgvXUEdHc77dPSTpauq7fHw0HB00SV+hQSS4tLeXee2B7094Dd8C/1FV/GgliF5EEqYLJxB2GGsX9+7XSW689
# DATA yrrdKuI6LJbVaNTJ1jsFP+frwScwWDhVySsh+fZ42MH/LCYNtVBYXv0/tV8UOyC1w/rm+1ebG2s7H9zdeg+2su5iszN4eLWZgXYj
# DATA T+3CN+9uvL3+Dqh2sO20ragTrbvp/rDTJviLrNfa72ZQxWX1AoPXnKeQ5hAOuIpdRbM/QJj5M9vG1stGoJSuUd21I7VV1Iqju6VU
# DATA lPZao3TCVekI2zPXcAVlqzwa9ckyfOBCy+N4mTOKgdfNQ079b1fEMG4zyzlMuDwUy6JqI5vJWzfBtZ91nAsFgA104qxvPrxapywG
# DATA 5E8kt7nnlI4Mc8QxWjIDfWq3BrLweLZW1YMImYCllztiOaeD2yy5GsnL3fDbPS8yvD8Qs6x8T7c3myIiWZ5KsdJAeEyCdN/jH2jx
# DATA ccrb5KlDiQ16jP2/Kd9eNd8CLUeKPgZdUKtLI3DfYaI1fBdr0hvfbLusTd40+OU0VjHPd2DKnrnNKrTNqG746yvUrqdQMeL8R+MM
# DATA nP7JzDmWpcM/ozMjbnmYm86ZJQGD5wIXk7QJWrKQCAkWfnaxqE8R77HniLpLM17l/fNc/PsDpyltKLWl7YLQkWfaF/48uU51HpEi
# DATA HFrYNd+EsX82ZILTKpMCUpbvKIBGIWSxRdZpmny7jgQTsjyDvIl0nwFJmgJ1PxELtiVIQ8hwgX8XO6Q8k8yZX778KUd6Yyz4LFt1
# DATA azRqgenWB9XSfL1ckKZOPowa6axaySKJgrVliZQCDnvUX1kASKYmVdWkuJWUT6SU2ppMySprel6YVHb2iYTOeLGMXsZb1p26KInk
# DATA p/nBKEQ048fBERIxnlLJQkupaQBTBmI4SJgxUMBjuXRgyAZdsuc5r+jjPrLv++hRer9Wu3hf3fpzc8pUErRUoIV/NBSwSeCSS2ns
# DATA nhsaR7g7Yh0pT9tetIN4JRhqXI8+dOPAhAx+hi/t9CGhtza0eLCVdH9FGLDIOjToWLMJWwD8igPOHb/+B1s2FELOJhjbK/2w77G4
# DATA 7Pwm5jrQUTeSEXgUOYegPFeLuBR+Jcds0ddHj5rTKwj3pJSHwPMRkr2u/LvJUiRFl98H82HQO1VBfGbPsdf/aPpT6Owqx2lMNqLp
# DATA 2TUTC9ZyUPktV3TNUz6zZ9T60h9qWIMQJLmC6HWaQpaGkUbnTM4F5xIgn5g7QNB+TKbGWDkZVj1ZUrKUPVD1ZLLguCVEhHp2ZZB2
# DATA ZiV1DeyUeseCO09EmFqI0G28sShFkSQFWdUUWT3BOEI0UD1DHdoXREOUoFASKj9jE1bIsmIZlvU5DdMpHVsoOnNiqxcOuuLdBoNb
# DATA dNnyE59+0SJ/J5gzdYQ40xX/rlQghLC0h0zX8jINxccaWdSd00KPetoa89o6HTcdEDqji3Hdy4NHvmCeyOS4vIRXdkBQ7naOjkdy
# DATA NajwcdUE9VaDo07A225RPV9UlS/Cd4vQA3CNareykz5lIpDC2ehgka4ui/SWI5h5KqAD/fFoMB6VWsOjMTjt2BEXgVWDPf3I75V/
# DATA 1IbjnvkakAQGapRZk+pF7T/5CcifbORYvlIuVl5b1e9Q+bXHA0jNN0M2M7sKtM+fuBIzbTS4IunugkHLxaLgMeFKgSb/G2xPEKi5
# DATA zXzUVuOsgaJwUCov6AUiGijhPfuwBaEIIEUFGZIsUkkWE11a/a2K+7KvC64zZYxxV3ZqC4dmGlL3zxo7doRj1DHAZD11R8nyZDjQ
# DATA 1BEfRVTkQHBpF3hE2uoSwgsfO+WoRikiEWKelZ+SreLFs+syMpL6nEQ1sofVGqE/mOWMwVtoN+0MoBPVH+J/UdWAxdGP9rj/yO6h
# DATA xOvr+nbxLxwb/QXMjF4ixPBY/AHaGUCsAzOyHmLeAFX9GEA8cgY01b+cGCyqtFDjZs9H0frzIKgq647vddzy8Ner1aB3uziMPZ8u
# DATA izMz1ep/XQUs8eUrAAev63v1u9ofEzxuf4Lmp3+g9MzRgcnlf07qLOpQAfGFnVDTPqUb1pqL4YTSrZfSYUvNzHf4fhX2tnUATLap
# DATA SlFXV9LiudtarWK2oY9e/hyxsX7iayd6Ganq8KpXCxmBbqyxYidJvoVnEdDKo9YQ4r3n2HGE+nlyooZVSdjUjwNWG47OttQKgoed
# DATA VwW7cwuEz/TsrLaNJqMa+wJMJhAzX1q5VgHpcqkcePb5cSV2I+zAH7SnNvdwRPVWkkuX4BZtcyAL8V4o+wcP3yrdb18s36/Z/6ja
# DATA mJfwgEMUVqoLcKDdPAf4vHakyGMAog6Yj3muila5ilnXSPHnLy+v0xrY0bJk5dpFMMlKyPVK7dKl2vJFo1m3BI/YoUKvXZZpf2Kd
# DATA C24icZJYSJ03uDqCvZaTqhpV3MXky93XHwV773qysbrDNPd7zIr8BLehlQ9Z5CmUmKaQZ6Szh0pSeaROpKqgoBM37h3yEOwdKieX
# DATA 2RJa7V08Pqkp4QYC3eEfZEyUZt5WazzTqH/n2oVsP48GaE9RPetv4YjT56TZUSwhw5/dPLJ5N8BCPQHoRtRRgRtMbsVqs04ZG4ha
# DATA cGKndLT1Ti8Hn5SUoFLV6WxHQOmYRVdPXwASXGQKYsvxHGagW2QGmmH8WcO7HFCEa7+ZbfrRX/pWo7Do+lTzznmAi/nHK1Qjy4TV
# DATA FNDY/5/NQ1OEmEIFv2OwgZvHF4g6CMzrcy7OWd85iu0V8MiuJ071XvpbVH8KWizhO0r+T5hJPxEDTHHUvzWeDRqmGc0ifM1WjHI8
# DATA 6sPs0aHbPzxMC8zGyApB2Psc/T7UmdqTWVBfoaswcsOPQTABd+Gf2FCNn0JAYMzz14u+jWFysUOsk5CtklyYjlkPaZENZj+OGU4L
# DATA GGA9vEfNZ+BnRwUf2i7qXR7RP8S/e4V+0JU/Xp1c+m/a4KAR5zWtFNCO4JXkveyU3NnAXxE9eZxoYjOJvTTmdx42WQKDREZVuvaU
# DATA jFoMP2H0N3NT/rkist+h0UDP5PWkGCAwvqMIEMnJY63ko5y8Wr+RPqY2TmRvVOLmQIpPVtX+qU9HkSBzsWdlfPmLmtqk5PR7iqoN
# DATA 1cVIZvuYhwmxlEPF3o5LMXwebRjXAAXajTXV3rSN9NLS0hIZ0R+fNnTAMnrfkxMglvZDxwrgDbzH6GCoWljGFnAvKNbfxIiiBu89
# DATA bMk8pZ1A6UrBCxCh19I86x4Cqm43td9R9ZcvX5Knnd5+f9xr84tr8MbOPmbXafilXbcdMRAPbgFCfMpLzJ7zho26HuUY55KWF2bF
# DATA tLr9arhxC1oNbK1I0LHfEC/2LeGAjhpxdTc4158iED1nBP5aumu6pgMCd9GlMwZ5zQFI/pJGFjPEFwZsbGqCwLEvReFg/o1don+R
# DATA rG6uV5z1gaTzjA/zJPnesHVqYmO+YEhsNDr8jCJjLJCXzqFPy5HsVT7QjUCKInIxAIgroay5euvO+oYb5zTfqWtgSSMHsMF8ChDj
# DATA g0TXRTBSxYFi3f7REd0ZzixPQLg/EDIQyBwDgXQ5U2f84yo4XUKhS0sY7gSPsKh6dCVlj0a4yPclgxdmhIPX414XpLd81B8MMkz0
# DATA yc1DRg36K4g4LHQIFNhABlpo2wg5k6Cacbdz0mH3xF6f+3uW5v1D6Nny0uVrV964qjp0rK6G5sFkMpkP+Eid/+JaQENnLt1gXp31
# DATA HhKkGgJJmSVdTMB3/mFa3osqZGC58sbuoQmcqEvYVR05ffwzzrLa2GVQiSoFQZAjK7iuGqwJAqvL64tqlRfVKBb5QUHN7QwQA/Jm
# DATA v9ewsRDa++z32WtjMDhmS+PkKseKF4+OT9OJA5NAGBezP5pEu0GvMdmp6sdIURiACqU379yqbr+7dvs2aq3Gw25SPcy30Ze6vrgI
# DATA XrZdODRh6pYXqQ6EkkQlnpoT9Cxdwgs522uQqHNCeBgNKW3rVTpYhqPmIBt2+m3aC7mN9xDylACFAWIKB+pdm2L1U81ALPVwuzVq
# DATA QchjnLR0wHN9+VoNrnCvSGRkRz0+QW/qRnpleeVkn2qTkHY1xzt/C8O8t3MT1tHQl/TQ+EhboCZTmptnAQdHzU4OWrLTpHov+fa3
# DATA z5y48UlSbTsPb92YBIt5adZarixNbPlM0WTBXNOO4Y1T/0611R10esAe591rRZPBKk/re1TcsoZVbRX4i34RXAfoLynMlJ4q/nuS
# DATA nah1rg7Q557eZWobjbSmFtzYqV/w2+sa/4Oe7H5xReHI5N944w16BRwJ/loqHFDx0hqUm+pBFzFXqvkc/RnAAfHVVtYCw7LYliql
# DATA ptRhS8jIhKijDAv/dbRYoejs+bbZ70nkKw7zL/4SQ3MkYNV/EbhnRD5tiBgArgPBa0C3ubZUSZSUPSkEF2IBzJG8yNZE7mGfscij
# DATA Y5Jjchc+1LFQFHbsyEzPScxNo5g0+a4NthO4s+7F92+4RiH1kqTROLtwgb7dFdkDaa/QsTaaGDRybE3hzvb3wqlBmjskOFvnfWzf
# DATA xcSEYIVBYliObtv4of5qh/P03U/5WdW+D4EqWE47zMBS9Dof2WY80PdFcbrns/v1cm10rC4Pw8ab4k2QPe6oq3yt/+CtpfpyuVw7
# DATA QMNTqeyVUK+K+JfDZa7M4jLLKxFhYMUVBviEkJyJAGPspXkRhmMxSMOttUA28Vw2HpObGt3x6wV7hd4W7Ap6W18xp5l76L9z99ba
# DATA jXvvwJhOxt1RB+xWo4NBYwmEACa69NpS/RooBODmXqfbu/y5OG4PpkkBcaE12B43oZeEUwr6mTr692DXF/Wr+hCPQ3xahfmsL8J/
# DATA zTN2WFqkf23lntW4wEmfWRUh7rRXjY9FraOHziiKwWBvJjZ+tfwJy0wNAno5/WV5+AFYJl619epFFpxUXLt7lrkVQSKtDRxJXeMU
# DATA wt049xXG9tpvpHBgvbrIyaJvwxF7tVbHXMR5jJUpxKHkBiGLaJheWkmCb9RdM3c+6h8t5uMBrA7iucW6HDJtUO8uwjyI4BXrBnO8
# DATA gq8P+sNMAwXGPsck6U6pvbhUg4okWMMYHXkOJxHNEx4DFCRsvS+Hlxah2z0BjwtGhjgYxUsy6uawV4vOdivmuYhp4dv6cm3lmuFb
# DATA MeJcOB+XoYhi8io0bIZCatHdo73IDipYCBnOdM72ilNz3lpn74BzVvjo0SOpMBZbDH302KfFsuwFfFX+OPk6IJGNmmw2KHKAihyS
# DATA RySBFkhpHm4y/PKr9nGREeY2AopMk8hSEsPV1O3t6leMKgZdUIf7Fyir2CbCUJePT2kuHp+G3SWw5Xoi+ty0/6iXta2eohFQFqs8
# DATA p4qMzWG2XHpv2M1DPNmpMGjnunjZGSLOnJY3Kc0vmSfcNzT2QHyetomcCnYgSP/euNNmOhyrP2vwn8ulctmLCohmrhLOOvWeE8tL
# DATA 54zXxk9quFp+0sgL0lGDdMKOzr5MRdZJZ++VcjT55RiqoY26DUSh+IeD/irJoFqHI6CvVrfbf+Sbkthe0++2gbs/8lBAqYayI7CW
# DATA sLqyDTAH4rWqwbGSomoBJPYcwGJKhEIPu+JvPthpOgiE8GNr7dY6/YWwezZwHvwteHiQJ900eeaCE6pyt9a31m7uyK8AXLASQweE
# DATA hwalVP1yQEVd6NsQLFgNm2JdXoOA7keEdZadFsaOvfi/tE32+Ys/MSww+1N9ju4QH0VjMSjziPZ+PlGkQcm7CEDvQG0CRSdZu7Rb
# DATA OiFfADBog+M+/9zuj4cH9oNbGTji4G6wnm59kHKmBXSDZNDvO9icmg90JxCKaVIvkHCaukf0hyEd/m1RDYTJqDs9wEqn+51emwU3
# DATA tLr08xrTGvdn7c7G6s172zvNrbt3cUVQha5PXtVbY57Bw58qxzziqO0yqXbklWSNttIBYn/YuGlGxhYqeotRJjJOO9hDnoHmov8w
# DATA K/EHVP23krvgCAmpjEbHwywzSU+rg24LcnHzAcwtnrROk/0MsD6ydi1Zw/xIAkzMFWJJDIVo7Xe6GIvGSKWEOYj2RhLUFKtAPRjw
# DATA WQzjHvWZU3RyyZVqcp/QGn1VmPdoQhSZamkMw9JDRjM1+wP67Ix7uEZ4NJqpDyOkdUlrNaUCgM9F3zegPfP00p7t5xYBSo4FRkpT
# DATA uyt7Qj/IPxTX2FlrEj+6u7W+tj1nfTluU7FBUtXLnhg4zLotzm9Ixc0OqMm75qhPG0pSVtiJVOBQ9z/s5M25vkXxxvEg0Wig3CtY
# DATA WzA2ywMEL87RS3WFIgtcP3w7GxaKtbghqrut6iGmxLq0Ak75bm0Q6sJ1OY+X96CZ+ArsykLthWsR7mL8penWoiJi9AEfiLF3zKby
# DATA CRmj0VuuOMjO1VRt0Pa9w3o8kAxuKGKFxGnw+2ZrsNpu81+3hn0MDNkcdh4qsRpMtHvOSeyd+wYSHB05wrq8zaT4jH3QCC54PTlD
# DATA xL3WoKxkIXWpR+KDqQPfn85jVfOqOvA5j0MLk+6UvKwcgH4WMBoNP6/OGjcUHRYBekMHDvcL/jGHDf6yjpoIiLuMmPmkVNTQ1Scf
# DATA KsnCKEwm83MCuwmcyuI2quduQ9VvJwufMneKQi1OXlww6vwRyiemAhJC6IKwsBDfZQbxqOCaXMerNCh7+cacRlQ5AANtqXyiBUOl
# DATA DSa1tH5b2EXqrCVwVGQusdQ05iJbP6dDCAdP6PdOZi+rGr+eWqt3cBxBng0TfUXBR710Xy8/ZmRgcnNBG5Hrn8RaydI5c+OU508I
# DATA Z6e3Kc4qPHO8ECbm5LzRaZ3IkyeAHXkuD2EGvnz5K4e1YtBiI7HVDKU0fuYAedsXydpx9pidfhQBoZJkWqKmGdoR6Ag/hz/LqGUZ
# DATA dJxUTcAtKdtsRTPp+EYLMR8wASGJcnTWuTKTt+y2TA9rR61ingh4E7kkJLpv9s2uoDSY01G7tZi6fmjSy3os1B2ABqQAhqI2+NzB
# DATA VuooV9Ax7jQGwLFyfSG/4OIL2D+7uyagGovaHLgVjKqL+ZWpVz9xr2k0STOQcLSkx0G1sNpBPlcLp4jSNtkwCKIkxiUUdcYZRWvW
# DATA E7lapdQQEx79ANKjTqrH9IelMgFa3xXS3DMV64qEQE0dVtUTR1cBdSkefNAFtL8N0IfARttpDdd7h33Iq4zpXPm3FTjeROVHpqSu
# DATA bNQC+1AJPE4rCQAhK3HPjiPvq/uUmkbVkdZIdYNLqN41DUqf1EJZghElBBJ5qipr4I7j4jDxw+TNBBM3X1hBwsdm1KOryQV5HjtA
# DATA YYx8peOeJNI4OqVn7Rxvg3nrMEvQW85S0vMXtcKeA64wdMQEcAPCJYApPi6cIBxQOJ9S0PebRguNYn2mYl3Sa/SoN+72e0ffTMNS
# DATA eVHjuRL486ywbcZwx0KcGJIyC4+gnQHqSvBKb5brpHM0ZE7HUgOqig9GluDQ5JbAHpO1Tip6K8DqNHE5GyuaQC5VKBULv1heUv/j
# DATA Pr7++us3YGISQvQkVUO3f9Q5UFSGxELCHqa1xdTFPXV3B8JB33Xwpn8InVbdyGqqMiunu8grNheSTXKAh0EjWVrQMM6yB/tql5fg
# DATA r/7+DxsyPDL0DD9McaQdtUcb/ibGKAmeFu+2nqEfDFw5/NfE46AvFxvJsocaPEQ9El2AsQrKfkxXvDDpEdTypj3RsF3Dr5VQ1tpX
# DATA Ytt4lJFkltZqKSV/Ho7youPiXg83ai/c1YiMoJPtYDfSKHwL96KTk0worun6Macm1ROmHjFxl6f0ShNxL8ZwoJ6wN1w/gd0TzJH9
# DATA 6E2LitUFBWmmqAcWmwu4mt5ICfowu91om2MbmBmJEz/sd3own6ULpCuITaP1oa+sYEqfo68yQ5TbRHEARWptW8YpmDJevCi+ljWF
# DATA 03Cf7vU0Lr4RRSX9hsuJuJeRqEh7Ek4eQJ9why7131hagmARSI2VczgIhlo2+w8II32+SyzxCbUnrUEVLV+Nmvsq/YDj9ng86nQB
# DATA yu1Bc5yra5usZu0Q1KXfdSj0YnL1ctHxawXqqd1xeNg5ABBjSMz9AJmsErNOCM/H29A234+q4uRU5uMA9yv1KhwNfcOQaOcgSEkJ
# DATA ob48UfsfI7Wdr78FOdG74xwLA+Y/bCBOe69oeEymLdn7OUV6gSQtBwiZrWJ5BKDLFWdl8SxIH++nyNwptrk+lRgPjhUBlHD9rT2B
# DATA wS5/lSz1l5eXSXO41L+6FEFoIz013V2KSM9kTdCl4/ttvwt45ZZytNUuQdYD/VkluXrlyqWrxTD6wG+wllk5BCIr+UjN2Gg47sFq
# DATA tAtSA9CM1ihlPTYUL2empdrAu09BWa7vUNHHcSnyOq8d5qe9g5KUU5PY65dcqyKeYNqaODiNST2WukTIxuG96m9yT7BQLQappWZB
# DATA dwe4IvFGgfthDV0V2Y0hCgK1ifQIlYOlCICMGvbb9c01fJ4Nh/5zln46JxiWAxaYFmhREfdpWFoGT1wp/qDT7VrFaxpYQke903O8
# DATA +kpGIQiDVEW0PtyJfg0QrqbIky5OUyW4QnI86xr+A1tfURmQ4HjocRnpEr+MIWzhUC0y8TCiMOeE9brdaR31+mqrH+SE0SCFVVO0
# DATA uZavXrp2uVzjZFHpeHRYvQZea9CVXImPmboFHtjHmVeJ36L2Y5FykNuoZGUyMo52xCvB1+5mf9xtcx54JWKhqAzMAmU8ewyIj8F8
# DATA 2nnjwKfiNLI9COEttdxGTc4Z+ZvebPXw0qEOne4pbizr7LmubXvWFlFMHYMT2hKvi30Jb0ua0AE6pZspbrNJD3iniJsA+KJYo2R7
# DATA AzTatYkVifsAIn5t2rBgywZ9oJr42VZAWfarYA2J1eS91iA/7tubogRKA9X/ca/hIsERUCAVahTwKDt0deSpMqLprL6VrCYcKidk
# DATA cdJ6oO6LdGBCjB6YVrskumHumU5GVPSjsRKXVF0HWWcA1mKu76B/nGFKVRlbLdlScwcexsmDLBuQqBxZ+W7rVP1XseH+GDEiaSSE
# DATA HYKww4CGZzNXgysiAxXl5N6emix0DychbF7gPNlcplMOzInuDDMLDWTCZnRLv7jeZmQOv2cJQi45ZfE+aWugt8a9HspAga743zTc
# DATA k0Z+wmwwYGKLavO+dNTizwl5DAxzFMZKOJis8/u4KBiUBmHnIvNsAKxktgqjtndPq8bhZ5CUDB+yGG28GF6zldUMRftqNlOo3jP1
# DATA zE45aKtHvTl+Mk1faqnbI3cCfQuwfC9sLOiinerKGZAhWX2wK7pIReU45fSQ1ZEu6iLv6anGeaPZhslnhWyBFZnq24sazwpn9c+I
# DATA cvfJHNNn9DjBJJYt9bCapjan0bCYprPPAhnN1cJDDYVQlN9ilKs0N1fmXnugrul4o4ILxbiTHyMfTFr7OXC7bnbUwlw0kn7UVGbI
# DATA GQ80Eq0WIeoNDlP1J97SWGTJa8lGBmmK8kdoukZu2cWMoTX/vjXl1NdmKBwoSRoYk+XQg/O60GbwLyEYp2ODeh5dXLJqSeLOPzPk
# DATA AbyI5oufjgIW1+DJLkJlFLgOiD7yAtPQ8Kjb3y+lF9KyR7GgywMJCzDSupQI0Z9cgVwL8iiW5I22crrobOVpEzkVNRGBhf6s8yqC
# DATA 7e9pOK/PY5tmikpRazVg0DrdozVCVsHRDbVIw4jqW9sUYCl6Cwf820KSEIp4+vIXL38uaeaiSSaBxpAo0DfQZcjeBOCAvLt4sFgy
# DATA C1Nv52BIxyQ1j0elUozHTuHeCCDjsGn0iphlvi/bee1x4ockdpfwLwnnYJThGp4ojgFUXNlBVol+4+wZkungLgUbh4GkLDAlUK50
# DATA +uM8LTuPFScDtcppsKMoLSEY2E3NtgGd3sd1xPRuTk8Tzn/I0Lz0i7usHpHl1VXaYXZErywlWIyULkBLFdHi6uUJXiigyukb3TsJ
# DATA EVlM+B4igRHkCmUUUez1c3KSegpoH8xYBZBF7Z5P4VHYVWcygMgglgIxCBbVq8XHw9YpQyLKotDwKbMKfrI/7rW7gGwxt6OP3ehr
# DATA sykbU5nTjBVO2D95o34mY/6SEBZJWn0uGXKeEkC0dQip4pS5CubLFeNePEGwNajmZ/hMZlmQpOl4+zNW9BSM2iYJFgO8PXUhHp0O
# DATA xulHNiBTisVm1aaAv5qc4tMtR9Lv1Kn6l7mgsZ25+bXGpVSDRqA6SP/o5fA1NKaRo/s5ys+E12fnKIBbI6rblBiGAkcHEnJYemdw
# DATA vEsG/UdwrevnubqAga4hP2gNyerQyx5ZldEdwHIhSjD1dX6MEs2j475qQW6TYhls9U4TVq2AD23NUthQLR1CErKwrUCyBcg4JFxb
# DATA bkCh3cgKwbFhuXDYn7HPudWg47SBUEPktIF/sicoqCYA4ZbTiNd9AwOGYKASS00/qv6gvQr8utvcunV34/b3kw/plwjm+sHG3bfv
# DATA 3r599wOXJEcx3qq1oqZJL+OKryOxviSVlf0lZ+EGlW5TXeTV5VhScDP2WD24KH4lZ3e2hw+6/dMTSiZdlDbb++akNXyA9/p0SypO
# DATA /t+PfoNyhiTkMh6qsNdEGlMbTJKKSkQq5RIS4dFLl1DsAqbTJrgWY50YyM7KIE2Rn4u7GoSKRZdC6wj0IezgNadfIkEHHvhMi6g1
# DATA jPqnYxYnl/C4CjEH8lqrTaGatEHMJrIsz5Qmx6zbIhYyGI0l5x3H98aQj8NWY18y/hRA26JfGC6+oqwX/4xOybDaBKr3E/JdYvox
# DATA 4X/g1vbivysKAASun8nlxTpd5Du7fR/4GuPhGDiZkZ7r6tGF3TTBrwOGZHdD4gX39mK1QhpnJ63Sc8jc+Bkij5rwmemNERvTE1re
# DATA czDt9XMz9zSfF8HUkdiBDHBdQcH8C8lT/OJzGXBV76Nn1z3YOTyIYL3kEhhPjFdjI4nVOswAfog7+Mc47l8Adpt1stUSwbrDU1KV
# DATA +hyh9z8ifY5gijwJ2wXskWeKgedJtdsKAlzZcfPPquDvQEpQjfMnOJaKxvR++WMEc4TOIaQjhDohAAk7xD9FcvqCcpxJdrPntbDB
# DATA lGgR7kiUfVt/g7k6uVKC435iKJr8LWFPCMpDORzL/2lSQqvLmetNi4iUqsqwQopxD2uDTj4jsvQ9cxVxhvUMsyN1m4HrQXzQtFuh
# DATA CnV1rCcH7eimUw8T0g4nvHOSAUYMoCmReT1srbFa0aoJJI1v/L1IZIIBiahEAFU0jkYVsvs+6g/btdFjhNewwr4rEqFdoaDqCs9i
# DATA he9q8AfERrtRDC5zI5ee8Aaod4d4LWLPwegYmS+pp6xdywYkdLG8wTb5cn3BV4pIw3Q7LdSTeAD0mL290ztqsIWs7LjRImP2VScE
# DATA mopqBHU7sLM3wQZ/e/322jbMcCDsmuFah0tBcneyQrtDNpnL1Wy4x4puFNYJktKD804JJx39fe/LPZtSYk8/c17+ogJc56eaVQDc
# DATA K7MtxJOMMfI03bNzNzANI3lSNLRA4DgGH3XNaBtvW7PhwB3c1ALAtJ6uAGOb4GvrCiPGQPNCL75nGMRmsiFqa1EvQZ94VyacKmDo
# DATA Tk9oFU0VjlhXFCmt9jr6OH+EuFG27GaIAoWZgnrL7iIXprDA41TOcqyZhDEHrNS0YcFxy3lO4aR7vhw2u3fFMlE4oTAd/+pSERxp
# DATA c88E46t4WrYjSibrDs5mh3cKnIqQgxxls3r8Wzqekeb/MQL/VWdB5iibiyam04WFM+ZNTNDAvMThE0jQRIRWqDFP4jM7nXewEdeC
# DATA s3MxiN9XR3ONL7WSm2y3fmnFPVlm7uFAC8TrH93OvMBEEeOehPu201mVWgQQjOMcyz0PvceXlSg9VudcW92MunCTW0O0ILcWUXa1
# DATA Zbg/kwbLPys+Zvzhj1A7hUOjJO3PdFbo56HMKK18N6zxzUWyWTHcVPXCIovRQKcgSHuyZTwT9fMKaKO07o6+ev7iD6S4p1vTs6hW
# DATA LuwsCEI8H/8+hzxKKGlM/XKJnyZ4Up4hjE/X0/6EGoGp/B2X/JOOqnKQkkMx97fWheMZ32Ceqr59inDQMHDKbMtXCLyJmFniC6GY
# DATA 6JXYL9rNqPZOiQkSSvvypzWTdwz5AKgNtZxiZSBgGUZ4RVx6QcI00gupchCmiXct+mMP0Rf0CP+urXLWvU18ozVBasc2mk0lgzeb
# DATA ZetLuKI3JVFfKe0PsqGESR0c90Ev0mBMH4DkQ1kYlIV9higdDVu9HFLXIKwMyDhVFrfxG/tvAp2BnD8QJyB5pVpDQb3rtFnEPiLc
# DATA O+JfKWIy58dV2i2cg6pzeGo9cLgSoMcEDxl1M3jO/UN/lOp4cCSpSgBxqjOqWomvAMUaFOfWI0Htq1r5dMDcZPk9YIOsHfUeizOV
# DATA 7SUxZGccXRPNKDRU5Q7Yk1XwmjsffynjoLfOZIwAuEYvl0FxMEsrqWJIiyjuDFFCqlbZwla+XlSADXbFBcSJaGoz5lpoU6wnbhe3
# DATA Yc6aqa3olD7FnT1BWJ7C97Twxe+ZsAhKfWpfAHU0n1LTkF2UIE5zeJQ3QG8+dWyK0qZ1bDwEE4BZjcKSlrpJr/60hs2+4cjBRjqj
# DATA p0iF6rMqAgaoD1toOGukSNRNSis0tUlEJ+t/9ToAKql6QjAIhuyKkk/sWUM0ZeZshSGXdQWYB+P61O8Yoin4lHJoTGuWOKW7JIVt
# DATA +dUjJP10phBh1XMuvvMp7bb5eukKrUGXl5dmbn08t8wqS1aVVHKGOetLb2ev7blmGhDEi99KVsay7evOZfEfKG0lkINfNX3UG7Q2
# DATA YvAFbgv4ET4pe9HA6PwTSYVlfSbBvWx4wocAlgXRbpjhquxpfazPtJ3Kh5LDptahy4AhV5BHOxKwHMtXtVeQaDvaLcsjo+ylEaKk
# DATA p5xe0pZR6XpSShEBQcdtpzormDscwupDW7ionZ+B15WVbzyyiJacZhYR3JvJHRnflPzFnF4lH/V1dx7EjujXVUmCNZ+jx5aoUQ9J
# DATA K6jRxz/V5Ocsst81f70taxXmhgcRGrIxzwUdgwA1BiVFsYLV27ddSBnHUiipHvDOiaTlvB4YhBx0Y3fSGcrEwXaBKaP+mkxCQW57
# DATA a2qcqHynExpk0IwiCslKaSragBmDeSpgdNNG2SbQH4ZumG82wYchlv5iTm7gLqIzd7wnTyH7KMROcCnaXb1+Op047XuHmV560ISX
# DATA GUU01AyYxtT6/MvBuYidcT6K8GJYOmsqaYO+5wdlZrZeF+ecWquI+G9CB6YPM3bhsc6USFjFOZnG1KuTdcPmYnYshhRzh32eRXTv
# DATA ilYGoFw1NmryiyYfyXnsEAy5Jv7gT8zpOBs43dQky63ZBT8gWi/NmFHvvmsTJrxo8gvn+Jsyg0UDmt4J/4pt20hINne6cZ5NF7kL
# DATA +xtaPCmKdou9/0jGQfALrm6+ZcYn3Jx2AGXsLNICVzzri9nU5jMTouJ+yuseJrcwHcGrYznCLfiS1zRcw3xkXeuazv4MfLynDa2S
# DATA zBqB57VKnrud3mA8csBe0I+mbkyIcNMij9G6472HL+MCHIVxGU42hdVh4IKVMKCIzKbpZJwselhqLgqaa8tObY5373zk6sv3s7Zp
# DATA oQYp3LfUAQdSGYta3cDFqFhbkPs1w0qtqpvF21x1obUW+LxJz8/FUrQCtD6NeqRUadbRbIGYR9kocz00Kc4Ya6CSnN5DLt3k0tN6
# DATA GvIQ/MFfzuiW0RL7Ig9mzkXwICkSI83zziBnrPD7rM9G/Ckno1B+ACY+lTdEr6SRq/L1OMY33DbUwK/H3clA0NY2MatZG+90b76b
# DATA aeGxqHX1U0mEdq4qVpq2M7WQSTD19IOgf8O5Ba3PDHoJtUR1X6TXFpIQOj7epNPF8nk6IMaDOfsgGb6+7m7MXCunrZlLppnnHBf0
# DATA mU2jhA1NFjsOU9AiAihTaIdFJvP0gXMWmDWYJbB1TjCvWX5qwuchKTP5RPVAWC8tWfjeTeSvzaa1xzgAthzUqcHyHT+wwSKl4phi
# DATA sLdiUOYBzoTY4c/QMRGTpIWhZbojkg4Vf5QGFUnm4hCb/sx0lSI5XSCc69Z7HbF15YrPDlUZx3cOf0he9JAduAkGNCuekS5ZgzrP
# DATA IBGyKYani7Blyqs913GrM5PYR8lU9kZpNKzxOAWLWEAkJV3khd2Mm1G0gtof02ivb7+LTG50IeyHTmIHX9n6VU4ot4o1wCXbhIhd
# DATA yv0xo5o5TuHrr3YGiv3ZEZiDZBWB8DG3WCIaO21sqiJ6fhrojF/81vggo+Phn3Wia3A7nIbSHclBn853U0nrgYqRs0LFmEdQ1k4j
# DATA 5XwQzR8lXwFp1SmHpeH+YSnagnU3o7X9qhxTj9aTzkDNMKjea52Blmq1OgVIrXMwsgP9iyYJwUMX/GCOQKcsVTs4slZ4B35YwaQA
# DATA YSaAorAOX7hQ++Mhp1qHWzaFelgAPE4OGFODFRJSfJVDF4tzGHy8lDpieKp7Cp+U7HN1i4dOwiVjQ7UNZlOPpcfhcquBBG1VMlsa
# DATA XlhQ7TaRlJpNHH6zCUTabPIEOLFY5GOzYCEchRg6AHWEEDj1aUKH7PF/fflztXl/R/EMBQ5bM737sTnFXzDnHogzhA9gIRQh3s/2
# DATA aT7KTtYo1aU9iNL7QBXY+0ryXnbKf0FKFv7z7jb/geAqf7N9d+MWoifh07IdZ7iOqhlMDNLpHXTHbQGvw2wfeT3pIVgCjj8ZZj8k
# DATA rBiKr8JQy3G3m0ADtW94+mrJi38zUZgvPyGkFUa+0MEgFRd85RcUxWrxZYoLcVPivPwFgISdazX+y3/+L/Y/tUv3u3Dyqm1YG5x+
# DATA I20ATsLVy5fxX/U//9+lq5cu6b/x+fLy0vLl/5Is/SUmYAwxF6r5/0XX//XXX4eNqLgrmYIlGhSjLyU1ESntOgAjOcy6WSsH4CsK
# DATA Ol6urdS+s1JbWNg5Brduu+CPxkrET0bH6pxBgEGOGUJY2M4RZDo6zroDDE06BvYD0JXqbX98dLyAhfSFJNm5uVklXN3DrAW4VWiG
# DATA hbBp00fO6J4ctx5mqncZBBuA1bNdU33LhhiR3VZH8j4cxYC91utrU/aBfcggiO/j7GBMWBCApQYSKeFaLgC28qwjLeA/6c6s8Ryr
# DATA Q83udPoX4lhOyNbBD/P/gP3/xtUry/7+X1m69J/7/y/xv3ScZyygp9cXFtRGyEfJWbI57OQnrZvdDl7Y6VcywRgX3Nal9K8H+HDx
# DATA AMuk5ev87Q8fjexiIM48yvbJRFHWLWzfvLuJuWHuYh4yxPb9u6y0S3ldctw5dUGI9/2H8zrAACrhVtJCczqYIEyC3+d19m0uLgBX
# DATA BVXNHvTwcNwjsJZhNs7hdCwN+4/KnMVGUi72HyV/9VfwT42T/Djh83ZDGAiRqtJGDwSfZY8HaoJWR/hpD2SyDz9MnBdvYgLGWyDy
# DATA l8vB9/mBulTkNcVXjxDppMFzKk8+/NCR6ef65mKyLKPioixh5m4wE85n2e0U1wSy52kJv04ab0arwt9lNdOThYUWAC4kesbVNfNh
# DATA B+4yJaKuCmZfkUx2sgag9Xtt8Qe7S9XvtKqHe2fXJlX99+VJ9bL+cUm9uPad1v6e80T+Xl6ZfHuxNsryESYLhfmHFCXWxEHmjP6h
# DATA 5NF7jbRkkIokhcL0WObuu8mllTIgyirKgHVjuM/1Hl785ZyiA0Z911abptOCpDrXBV9R0Q3R0nRKssuLJyTcysDhLKFpq7UGHcyH
# DATA mtcABe1er/Ojsbo3Jo/gHKyr7Y3jnSQTbnxxMdnK8rFqG/NEJS08sKt4pxMUtoo4dkBzSKOneAgD6kgHg0RVD1tdgPLoH/A5epgM
# DATA O0fHo7yml013WJHZa3p/ydOyrDBOvj+V7ESWIC9JDo5bvaOsfV2snSgNKPoZ0X3HjsEn324aKmXV6arlhNobZgbVghZMIaJrw/Rh
# DATA fnurh0SbsGaVRHZt3Wxa+E+t139UgkCS5aXkQnLp6hX132tXL+M5B36ZuDXqyW6tVqMNxDFcztrsgAjV77aTo2FLDYfudwf9oRr5
# DATA oA+5NCCNI+DujZXYpNYBkaY1Pl9NrS2IFFJbn/JPtoB6Wgcapg+xiJ1FBhmsg3Q6oqXGMbIYFFtQ+Xsu5mHNI61EweyL0oNo9wzm
# DATA fFLBlTjj2bMmbzJxlpmZtTqSaiBxls54ydSZN4RlqyPjBRicLsSxrW6uWyFNnZZazDtgtjjs9vtDZKBECu1VzG8EmNGYY3QZF1N/
# DATA qLpTwOHfSs4A47AFavA6gIJnk0QRlCoYtCQfhw1NysmkYjljAhOqqD3d6h711YY9PlEjeXcbHDOQhqYw2bf7w3ViS1F2CyCxvTYq
# DATA LW3OGzyUDXXQbXVO8us23LXqFj0F1Fi1CmT8N1WYps5092E78AD21ADUVjgAyDFV1eKFZDVpdw4PCU0XFfOImqpYzgNF8YatQvKf
# DATA XLEx2ItCwrXkwmIycUxH3DdFuvQXWqjpLAdagBd8BPB75JsN+xywTkDcX1/nqWQ16uwXw/+n7hyb9Qvnh7rq9mj0jrHnxRF8yjp1
# DATA U3A4W/XoM9rUNgl34ozzHamVOoDiY40y1GEKsvZYLY1i0gL/3BoePaT0ng1Ai5f5oXmh2gF6T+0bJYacuUQZmck+SZaA3Y7p10sk
# DATA 875Vo6reJxXrWzUSd9+q5YMu3OtqKSAeJ2+9BQmk3mwkb8AeD3TLSoodjCBFJtBjScvGCObUGgwWUXdPQ8wXRbDmj6qDo7Rco95s
# DATA HpVLZ1HvRDWIHqHZbSNh1vU8qYOwZqfFrkBOtXqyUplRzw4BQN/pdJVsXFesp7kEsL2ddjfzXl2iV0F9E+BK+cFxdtKikavWS0Xd
# DATA KtfyDJBlN1vDliIpip/Hb9XSqulNMXDzAHia2xJwUEgopahdSQMRXAts2r7PlHitbVIVHuOihPkSyC323FECTwfYTOfvSNABEQlE
# DATA EWJviZOFPNwQ5RI/m8aI7Xky1vzteze2b26tb+6s391o7tx9b22jee/e+i23OCRWJ4t/JQDYn1Ld1to91WWs1GhSayBRlEjiUvvI
# DATA ywxASn96y7Gy1qc4pbIBcZsp7lrLaCqLIHRf/AEeIWAfGOM16MHPLJgTtMx9hokwDYxAAIkQVz//+sVv0LgXBwP0AWxqGP0jc/e4
# DATA M7qJ1vJkWR1L1kgZGI7Hyoz42+iJhtupRLcd2uFwtPcppdWZIYFKjBoqck+eXF/4C+h/mmb3f62q4On6n+UrVy/7+t9LK2/8p/7n
# DATA L6X/3UQ5yqy9uMtiVhFQs6p9izeKQH3i3LKytrqBYeo5NicBp7x6WX6BIkj+7ucLiPsNTkHdzr7Yn8AdQYoMM/kL7Ij6b53+QZ6M
# DATA spMB3O+owvFQHUn7FHwntYLvBxzWC7pqyjbMUf3km4Vusei6TBrcw/Y8aJMCLml+b9y4fffme2WTTQ9AJduUSq8NceCcQony6VkG
# DATA TELfRghKwN6m915iHguCDgrVtpvr21tr75Rs/GYH0FmyVkI6llh+EmOVLKXrG++v3l6/xacKwCK4kEce8ikhXUlDIBYzgPrZEk6V
# DATA OsAz9bRUnkQRppfeeKM8q0emJ807cFrdWGtubq2/v7qz5sCg49HEE2rSz1zx089oz7sFxyOcVh7/62Q/widMItHCTloRy/cA36LP
# DATA Ay5FV38QLsSMRZD8CUSutcDPkDstZEyOO4ToKnd/7SxT2F1TUnpMwW2M7c8jkN8wiJWly9cwgPT+fUylY5eFUL7+sF06KIM+7BI8
# DATA 4p9KSl9eeYNi2OyvyvNMB8WYojSFpdnFxE60hGFm3BG4EWB0a+hhIZNJUD0+XhDeKH24LzvzCc9m6ezCBfZykNhHDI0I41snwc41
# DATA 1fFcv0Lqk/hsKc6zelvmamP1/dX126s3nG0sYbYUumm3ukFvtrMRKHByu/0NLzbXr02DwiN7sNEBdXMwdHjGLKKEudwR8WfYaWNA
# DATA edoDv8Oyg/iObZBC1O9t6yQjb1ZIVQC7GrJK+zMt/YtlTEl3V6t/26r+HSCYmz+bteqe4l+KUCcpKfbONekc/1ww+YY8kxRCguuL
# DATA CAOuAQk1AiSTKHpryQ/bM05PBi8QyPubd7fQv5egALTXpu2iZLWv/4SMGdgPex9TmCZGLXMf5RXWpc5TVYWcqoY1yDZUb2p4c7PX
# DATA W1WGkDIYJK3ZDBQFUsA5UM/gt+jm5LcAR8rvH40zyoIDPw6HrSMUPnRhdeTqVhEwmVrDl3D4K96w9Cosxx3Yaw0Zi44HZmqbVve7
# DATA Ozub21zz1tp/vbe+tXYrdU4drbMdGrKuSNWK029u3b2xBmxMiVmkt5B0weoysToeHfeHfCetJ+kNdaFWbAaRwvzr3wer7681VzfX
# DATA 6aRR1wv0pI6W0jPB6JQfADqlpmBSTHEvdtPvVdXt5VFr2M7a8Bf6i6VqP9WW1P8tp9fjJTeHfcWt9xI9q3Bb8rSWQOoooEF7NPbW
# DATA Pq4o3tBX4e+bhGTVhZjnis7yl5MGFQLn6YKG39Xwv1DuGmhV1Y1cVEOsWkPlep5p/dphBoxjxhwxmrBinzxQwDYnV+d6ildfRZSg
# DATA i25169QN+kFaODRsScO1/gOxJzH9UPBI6wA6QHoFULuCkNdYAqCMce9B3tjdgxfAhqnbJRoOvkWLjFS/32+fqsmEzy828DWbsq53
# DATA Dkvw9M3LFzCbCfynfOZM2vVIv6Ri1bMJ9aU2gPSTN8agsK2BfF7C5+oyPNHTjH5pDXRHoxzHXFy9PVByMFVUro36pNdCaU4Jc2a6
# DATA yEn0ww9FU4u/X2s00j5altFSR4Vqekm90vqF9Vl06q0hLug961ahXkwEKD45O+iqPSjEh/QIY58slJC4S+XGm5qYxdjdoGVDzr7Y
# DATA GnQWyRi+qI3h5etq4CXuvzwVH1AYAaumy5EBaMSS69IsG8DDVotM5da3qvq8sToctk5rnRz/5bj4vPyWGNb53xr/q75VnX/N/Qjq
# DATA Kce6azepPoNyu0t7b5FGfO4eL6YXMYYxu7e1flOiEKQy1q4rhlMulbXKSq2Lr6+ydEnkDGmBjGjo6ieAVKe1U1DqC/J5JCzyT+lp
# DATA VDOFh0MlUWUQ/Q7Sb1BOH9KFmQYQpNuGA8XUQZ7uS02Zr7ZqLF8HLoP+S3hlUAX2sxKHQJh7AF9g+NBRfIVilCviYMUiUfENKrxk
# DATA cBv2DQMfTTssN1ffWWuu34H/hvIUJarnq39tJ4OLfWt4ektiSkoEdQGpRiUrHlIEDrlKV/DDflcxaAc+X2Kb6FWZY6ZFJQbhWKbD
# DATA LJiRChTRzdPIedCwxSfSkUbOXyzlqFFjInuJV8JJIvQqgnuQ/QJtYZHKi+8idP33pWz+0xL9qSDXbfJAxjLrIHGZbJZ7CPSUHWAy
# DATA YAiFqzLKOPpj9x6WNWXuQpV7AjoHxeG/KCp5aCWByz62DI6LPRQjrJGoC41a2GFJD8TcVsrzdZ6hzKtVQmmsVgfq9oFXnYxRHG0o
# DATA NupFMfRE0Rzgc7WgSGCpmQTectG5EKd07XNue6dbGVa39Z++F3rRlgWqX715c217u/m22rEg3lKGP7ynE9sBPaHBT8FEHEXMh1tU
# DATA LGuLzlr1veLHWRt07A/hRi9zQtrH60l+3BqS90dC2UgUBzq1MqgC97M83ikfE9wgFkyexTiwEecvc4GM2KteCd+xzZ/WrZGlkX2v
# DATA CuCAJwuSWATqMp0CloNJpfKShF5RN2yoXvyWx01gSgIMEa2oPzoG7PWCetz0SnyXryT4kcngYk9MDWoC6Hu55L+mU3LKXDloFdgL
# DATA hmkjbI+zFJdKTcbZZCInCA2o7qXA3E2tizBeGM4uXBBWLAH79l2Zsx5K3hj9KWgaLlyg5ZtELsvW1BmMNbtiwrI4S9FhSnVdCDqF
# DATA savf8M+kkgRkU2GaMUelf29Uz+xe8/sm5SebvQXVeSl6iDsQ+3tvY/veJqgH9F0z1ARBUh4bskrDsVUcLDYMrIspeyoG9Vk+tcki
# DATA jMyizDtwNJD0TCMFrQ5qCmX7I3CqOcABW9TR8kCHbD2TPpSsFuXlLsSLScvmsKLnTgdea3j8Z87pvnl34+3b6zd3ItNszy6GxJ2p
# DATA s20Eio6uohXKuEzN1+Uba95bo1ELuBfgNYSUgZDaKdfu5bq15kEq4SlwRyYvw35OpkW8WR0DB9oS1IwXPfVtXtq9YNqESS6Xg92s
# DATA h4BxZVzacRhBLBjiD3tOSi1k+CV8UxEfQA4xrC+43EsTJ2VHYsq0eItaC0iGiPaq2v7Vy2w5wO92U4p0gLxZnkWBwOLJ+xCVZvwB
# DATA 8YS9AlmR+gRtVuQD3Nt7QXWcffMv5v/P4aNfexjQdPvvysrlNy579t+Vy//p//8Xs/9un/YO1N27B8ZCCE4hTxvX85iS08Meatkp
# DATA TMgFz+Cso3yFAh8mjnk8sqy7/IRTYIox9vCgN+rKDwD3U1/ITx1W/LXakOHC/yrW4vfWvg8Kyu17N5qb924oRt+8dffO6vpGurC6
# DATA vb3+zsadtY0djHxAQQTykAzTH5TeqpO7x25yf7R3sfxW8Dm+uNCoXfg2JGjPanfAonfQbeV5cgu3Ix015tTRCPRqXogh9vrDE3BG
# DATA Yo5VaOvjw9e+hhNrZCsffZ28mVxZXiG/SnbKgnSv9/P79/+3t751//HSUvX+4+XD+4/fONxLmYUFVjy76ykNtMmqdT4ePTMC82jL
# DATA HkFPQmOEFWBdqJSf05bAqCJkLoArSiW5fPlS1Dxx/gHClzRCXUmN9FCltNPutVJ9npRrXcgLyqZp53buRNbznyWozgkvNsRhAbUA
# DATA fYTH9ry9B5UA0AS2BVbfK2jNTWs6kTqOTz2Cf9XA2pS2ClwiIQUdZtw1f6HBz0s7BSrqbrfk5RVWO2bpsXjDXvwQ/lL7JgVMpOGo
# DATA zFeJoe6B5YgZ1I5AHWELu2z3Uy3xn2j1u7o8kTflt+Zq7xWonpNHiq1qt15d3hMypkxiMpFouULql3eyLl1xVYFlubxEy1JL5XIF
# DATA v+kKaJJSOeNf5IGvVv9WDbbW/Pvq3kX1aNF/Vr5A0w75ws4/UhbgkErIKGI53IhLzYCCRhy5zc6viY3b3CySP1OyzWvoEmAE8GSe
# DATA Pqvb0erbcGXfeTeNbL+vww2I9ygguGz0R28D1Iu3VcG7hmeiHnNg1U4OeizfqH9R6fwORksrl5ML9I/1tgdYTLAay2HGXFPq/L5D
# DATA KyvRi9l864up/Vqjlu8zZA3hYrJctjcbFC+7w3w12uL1hPrUZvhrTyKCzdEF/SF5prjbQXxVajrgGRjrg3SGt9oHW0KUN7fWVndm
# DATA UWxF7hxF9NW6WEBfEbe0QmLTpPTVVjFQY6MsCTE0Bw+4zQo/g7E1176nhmv93rgRqERvwLed3tH6XW+LFvTv3uat1Z215o172993
# DATA NJ3yyWkn67aZ7/Fq22srXkmI+QEuSXkJiXGqY5ImTQKFMRm2MBsLwXqTrgQBz02hguRjxdO+cXeneWd1Y/UdrTrS+sIp2aVtdm3y
# DATA lwc827xyGLdpwSkTx3Y7D8WA/IXJqWO4kLQaCDBllXGxtxZs9mgrmKBiBhsSqWM5+W4DWQe+LMOv5atF4olXFwvocHhHBBc6oNFR
# DATA abmyvHJNOyq5nlfYbKxBqzEeb1HX+TV2/tor0otkBD8zyyqJ5eokCIQvLLEAcfEmCwZZDuuamNTi2EVKAYidtcVfZJt29VTGPwS0
# DATA ODKFsWiceGuj4qEQmFRsS8q9XieG4DN9Dm/evbN5d9tT20Y4S3i7iyZXL0fVfeds3ohDsJy7MFmgr8NjzJ0i85J+L/imBE2c0bwJ
# DATA UcsLjghJ3LdZ4olD5WIGRS+fYpilPpZTHvfB7l6sKcdrluuJgoz5Le3qH269MCmEAoLud0FScbuuCD2X8NtdQube89S9+M5JcY9P
# DATA QisPrak0sSc7Qh44ghAlQ1eS0KWVV+MHIgAZ7EfmnjyZTEViKVR9wNs+bTat1sCd28k95DJfWEauifOPummjpMHASDTuoueMp9Qt
# DATA OwcYV1LcimDUccFddZ8DrxK+JTYUN1su7y7vOc7nAkK3W4fLH3gqvq7KvZ6+btHRj8Z9FA2o4JKdN6Utj3EgJSxZEZGVtOudrv4U
# DATA yiuBtq67wK7SEK24xOqV1GYr8O67CV4rS1iTXCPhh52hOv1WWp6bsbiXQ3vmqJvLddXuXkRhIcVAGYWTqs5B1KV9S5RPGNGI7xrL
# DATA ZZx8a65tJy0mK0mFUZpFhsbTBXtgyJH2THh07bnrG9KoGEIrTMOFJgkrubhcjsSjKtjBYf/owiLJWJ3W+Sgz9dXIHhlA5k5n2HSn
# DATA hCTfllN9zAA7hZ9bfiWuaTZs6TAB7SsqoKHNetRNQuaByuyqL/aMp5KdosY53+UrX4m6cM5jnUlRGiNtIuo1WHI+ylAfyDruGqdL
# DATA KC/E6YJzGjvkYbVG1Qk4gk7KIApGQJzYT0FXi9mvvDaRPGpUBfED4aiCB0l8YT896eQ5+vs4m+ksxcEqEY4HrS4qFLqoHnHPjrPH
# DATA 0oCkzqTynfZE9qGxO3DYCmF6NDAEgJG04CbEdw28OJnbgrmjhpdm565SsLs5rEBfyUxiEkI2a5yDUdj8kwYR7n1rAqmFQOdiC3NY
# DATA iWWuzrMRP8RrkiwBOkkNEPJkS9ZgEtO20Le7Yek9qI46tGvWcW9+ifHd1Y131mKM3ewoaZz6TDmqvGch9Tni7km/DbhybSP/vzI7
# DATA ncZKvcR6LM4uFDnGTGGOryjVWp2Vr6OENFPSPReT9kXhabw4xo/l7lggUhd3vfikLB5LbdAflFTzfqhQIDVHvf3C+vCgEDmksLzO
# DATA y+Y7IFElwXfsU4AXxvb4ZJBrl7esl4MzUSs/6HRI8V3BROi9UWNFUk7P4bbIDSAzh/nfT9PAQSF2kOIeeM29SZD0ogU9S1Rm+x80
# DATA VrCMhdTHHbQrG+9jUA7WFqw97XqvOJCZmpKGNvzx1wvTKEnzkVcaEPcb/tFhOOCSy0uj/gk6FVs1cOOCKvSJ/BrdmMNGhbfpu7Pz
# DATA nX/jl9LzHCw6xZYoFOlBvsj6QXWHjOXcqMLAwEyOzvGXS2U4zZ2OUD2u5o6efTWVLtdL6RFARdxY6r8BsCOUEiInjVCBY41JdHXS
# DATA 6nUOQQrhFFjGw3DX6V40q5VkLMKHJhE858zChIa2HiR6bnl+vCZTlieJWRWVbZFprkYmgcCOva3oYy7rjU8Q7LQkRGOmbs9L0TVC
# DATA F2hL8RFq100DJXPoluMNRURWi3xiJkBcWaAja9zxDXoeWcRqtGA+C9qIU1YpThOMDM61BxqFhem1m8mc/SUvlaRlc/WWYsRo5dka
# DATA /glxgMEaCnUMwQ09V3Iz13nepSJUJotz1YtkBW/mpx/0aMsd90jVv3D+gz02t3MvjjGuWkxVXwMuOPeF/zkgxR3/v5POEeP7fa0u
# DATA gNP9/y4tL1+66uO/LK8s/af/31/if996bXGcDxf3O71FCJoYnI6O+71LECV2dzCqKjbBmVUhdLTVM3CZAS6pAx0JWJyeVyC707WG
# DATA R+hvt6C9Agen5I0HmgzYueKJJ78pkPfv4Db4ld0AA/gYSHkgSDLg5TfbL9D2Ilx45cxWUSiadkZTqk40E+NPnK7b2ldsL0RCuMkA
# DATA yEaVdhtLOjFfttWWKtJW4xoFLMmtUPK81MArWy1kU31KQAsCWAZv567G+tTchWd8KqES5tPAlmzroDm+3xpiA4L+HTCS49YQ8UhW
# DATA NB4JPrEhSdQDOBNNPjO50sqQ3RtusT1AozfYKXSc7Dk8HN+2OxuPgtsuFzcuBqc5F5lupGR1YjgNtltU3KnXNmE2AKlfNJliwqbn
# DATA U2ZF7D4HljKtYanVuEsNnQWMB9vgfyuxmDttnG+wOg6Dqe6pndmAXWjfYMqCkyPhNK1uR4lJudloftBZzhGVGHj5ymAp9FjH0ko4
# DATA xVfazqKFxQxFqKsW/1HKViTRDuauc6Eko2HEEBq8GDshFsorcWtjG0BWrCIhHs40LJbK7JG9y06xnJbQQMmegz/QV3v69i+qZcrZ
# DATA Rk7rjlO0c6v5OlyQC0FPzjzQk8lfFvRkDkdCelYyXa+4zspMVBXjKg0mwcuXL3kDbhi/a5yqa0vlYuuJTnlUwC1o/Sgh3qhPKYxL
# DATA +F+LpEBh9lDNADBqd7dWOIx7Om5OJfoeW6Gec7hDwyUkd4vEAj6RKDXrlKCJAku1MQ5xxEUjOXPaU53D6DTa1xzsJmG2HHygWnx7
# DATA 6+7GTnNt45Y8YxPvQ+wn5H+f+D3qcZNBn7SNDES6phUliPaHV2eDC17QYZ7xfL8CRwW0eSWZYVB+yeknNfOt5BayDMFEy9n3q3Uw
# DATA 7Od5ghkKdLC3DmEb9RHw/AB9KzHJI1f2Q4Dhh1fyCcfaEgaBek5BMPsZCL7ky9kmfPTWyX7naNwf5/9fe2/f3NZ13ov2b36Kbbm+
# DATA G5AAkJRkOYGDOhQJy2wkkoek7LggigGJTRIxCKDYoCRG5p3YPr1NJ5l0Tuf8cebMtJ3ee+b8rTh2LNux8xXIb3TW87Le197YpGg3
# DATA zRXbWMDG2uv1Wc961vPyezgul6NoU/ZkhrekhtKcDAiQxx+wvPGswfRIAe/hyzFD8peMWPySUc+F1yzrD/uH1NQiJwb3YOU4Y3mo
# DATA ks1EdyqwbiEriwo81hte0rKa3ZyNtR9GJbBdr9UomIe6I2HuE44J9dTfepeJ5VLIV6oRYF0AmvUoG7sryLrVxrTGyJ6lEk499Thl
# DATA arDKBtmkCe+/A2kALL97sVuOB1OtBEwTAlYU3dRGao1eR2Y0bsXMxAe4oAUEm1VMVWhJnT9GMG1V1ejxEA1+WGVtwoXq5FKz0KaE
# DATA kYd7k1p/ND8YTcGPel6HC3twMJaTizEJRMrQ1oyVnSRCAOnzPcru1Dx1qrqoPH/q9lhQk6ZeVyKC30kr5Nn/+XQ29UHlxc9PdBvT
# DATA X1w9s17imXQ/TY7AQS10h3UiyEse+IDEI5D3RvVABc5TIDm04RuH5S+wkNACTy8QsOtmCKrTXg8PRWeXAfFLtSrUZnk8sDcGlcJo
# DATA 5sZA8J9eFxuuyxHldL+svMAJKgSCjYXYDQkzURppGLgb4qu7J8WjUuu68VKbDGENih3f644hi1hndDwdH8uHU8Kdaiz+YEExTR4n
# DATA DQsUoXqCjBylHONP4q91p4CmDVsb0LDMwRTFY7xFMkYmfDxG+ZeBUNLpiL4iHIoEQ0GIl1OwuzB0iuFtSoln0PcLe01pHjHeyQDi
# DATA SbopAfeX7IRHMeR3O947jIwbA2SWPP/F2aeAkxSdfXv+8flHmI4Ssld+ev4JJJeMzj6VqSljB2oeXOg/GApWEe0PujhiRnD6CFMC
# DATA s9TBL0voJwRm+gyb/f3Zc4BvolacjJZ+W5ApBNxvRgB7MuwnPWzQgIeKzr4Q7/8R82T+I4CY+3Usd4cMMQogRlLG4Y72uskRmsdi
# DATA foBwVib+1OehOplHdNnVyVD14PtfYQ7lX2AGz48B7UrMTDhxqPghMNFlZ2UVNaJdFoiRMhQS/ZMhgyhAkCX9pK7D/aEkIvkICI3h
# DATA uEzwLTkBz7O6+pvIJJ2zZ7GbbFReKPx0taX9+Ox/UippMR2fnT2TrZWeqi13WmZy+QIRvqBjv8SU088AGL9Cvfoseupt39M6PITx
# DATA n9YiM5+1TG3/qfjnU3wZkMEgc+r5x7Yzrt5cglloLoVOIsBwSoTRgyoW0zXLiwXxIWUcZ61QUAgYen0NHtany3WHe4f2jZFnG1a3
# DATA BNP7DNPPQoru381GR8sgdEuF1nL9ZcZWl2Tcs80dSQ+GQWs4F3YASbltzoIqKnVoMrQRfiiVLVOdp16zh/8/rPy5XyoO9EITwdSh
# DATA IK0qkRwOo1nRvq+yCieo93RORYeVGJVooiEFutbDiuMO0n3jdCDQk5wOgricoCtrK67u85vwW7ndllghbL2gOKUOWQMZGguVhfyI
# DATA DLwd8kJU6bQ512nofBaNDZJk3CBkbvioUazMTaIND6EsCxBJp7/NZQJV697zRiJZi8OUzMofSAuejlfyQ7Rgh3mbFaUnLqtWTJdU
# DATA j+qWxOfSeG7wFKZOafjMpTyXFWRjS0tEMAyBFl8nkpTCR7U6HFVRNTDGdAXqGUCEIR/CfK70eB9cE/HMYg8RWGEQu1xjhSPGzTm+
# DATA eZZrthN6g3edzD37z2Kn/pY3Jx2S9m4NJDQpIrDMmZj4yEU1mZdrlOsATlMbDX8WxLzlFQsWu1pPUDx8YK+2sqsyDwCo8ce2VbTF
# DATA Kevb8kpl/YqufvHucX8Awo9299NvXxAOzNbguYBgsyHadMOkpZZtOhUPLKU91Nwf1dS1Tqqwq5BtTNQfuAWezlnuW7iQBo8q+55b
# DATA CG8JumlpNsXMg9JyWjue7uGS78OTUvza+68dvdbbfu2d1x68tvU35NsW9Ppq1X/AiqYLuGYh4kMkPcLAIYuiUHGv0TyySwXNHgkY
# DATA RhBrcE4qkQWtX5ebEKKSzWDOeqRI7XTO9wjBzlVUD8pzeY5k1G8ifelMVuxNaa6w36VvzO+k1saaKfXUmC27DSN5nrn5HnfTzoTg
# DATA OUWFWgUmcT2NXAnqYt7BUAWHydItrlrt0gWtWv274z6mz1XzLZmlG9Rk1qsZn+5AgLFbiJn65mjWZDBnU6Nij9dCGM2ELeWADLZO
# DATA DB8RiJj2KTeSSOj+Kzf2XsVIeWDgwkoh19ulbO438S1Za9CpO87LZmdMyFkfK9PsjoOWmeEXmUEwthuVrjbLehLAhw2ZQAxRX9ZY
# DATA n/PTy9Us9OHAoEhZqcCHeeIMDUg9W5eiT3IyhNDU1mf6jRrjdTauqiQAEuLR8gxR2dMVZQjCAS2ZlnN1Fs72TMFIbmA5Nd48wAj6
# DATA 0w53WrJIg25oinzRuBxaWROfz5k3tByIUo+CcmDFlnqxG2XvFqUqejXamo7GY4QhO5BQryk9qkVLkeQOmKmqn4o+c/pWNN2Iy26E
# DATA qLDSX0nM4BO0sa7crXlrS51WKi0ULHuJZJXiixRSAji/1wVlVHsUoWtyLVRktuh1dGmBG5LPZU01p/G679jZQWUIRNWU7iyUwxHR
# DATA AbavhnZJxm81caW83j1TaMae+vFNh0l3gOHR+cfAO1jMfAJFjtOwv3CxI4UsddwB0IcS34rpyYmrsM+qP8s+gh7RZFMBQLZsvuxx
# DATA ZC3BYh3IVWd7zfLt5F+U6hLuGay8RPR60CJ8A9ozUi99y5eYL1B3Vihh4wydRBw2Bu6KrftBaJnk2jfE3hzKWceIt9z1kytPOuye
# DATA uBiRNlrwoV7WojmT9O8z72sa/P/8l6DMi0zV49lX559EZ7+DSx0+YrD/4AyghqF0swiceUA39DGqZb8++xbUgaCZ/QPoZL9FffRn
# DATA PIB/utDKZFz9C7Dv8BncGXRPIEUGaT+uXmnBnOP6dSm86yP6bY4MCQ3p1JaYfNHBVCvhZ8vxJcMRX1bBWK/q2KVDtviRqmFv7agY
# DATA R57/DzyxyJ2eNHFwdyspTKtJiql5pDdwbWlycAzsbAN/KUkrohh7o9MRx0anUzbeBBtep8uvlGKlRiccfdA3NIBM0r0RI+2nQlyR
# DATA JilUCEo5gtSKyaBHakSKiyLxie2e8I3MamTEYtUSgcmgvUsaspHFxiqCqAp3APgqk66gaRfFJjSAYYaT48nAVKkFh1fFmzn2MmcS
# DATA qlWMS4HwupNx0lAZudBi15Dv4D/wVqqvbfCtZlj/BCdVc5clM9M7OC0V0//A4gBYiLyqxGnuSHf4o2Feth0TkKLlPSXcR15TQw6n
# DATA pXf5EL5Ky2XJUvgc50xFILI2fgEcXI2ff4S+r1y9657hHZyuBYwOym/QAiTY/oX4bFAbTAPS3EYVzFQFg2REvW/pYbXzlpazG5o8
# DATA zTptpF7dLExV04UOP/NNDj9bGnZ8ou4S+E3p2pUWXVNPR+wSsJ+LReugYaHTQQrodICpdDpxwLeT2E2mG6JKffGT5GR24gvQ0ycO
# DATA vOoE/Hjis3/Do/xzOr0LWlwsMx8Ybt+MAjZJ1ulWyPLISYAwbzWc6N+e/xM0ApWRxRIO+S+hdmi/FglKfMa9gcxD2PSn+O5HaCpD
# DATA GU7IBCjSVSLx2keUyQiU0f9gJOXGnj0H2kVjEbYJEK9w22xA/ANZ5Q1SPKGcQ6XFP48IqT/vP0vlj/foK4d/z4//Wly4ffu2h/9+
# DATA 89biy/iv/9j4r00N846JOpIJIXCQdt+L/0rfFGen4OW7/Smk4pJODiyMpsViwHzUeJk9scP+CWGk+MtHhGH2xT/5+LALmZGxj+G4
# DATA To3Fr1VvKrFbxXDeM4W6iuUFz+J8HwAr+tMTMuDWLchnO8a9FO8sxLWfjcCBHqKn4Z71gfRpJ492U+sZGw5F0u5aLmtkIytOvlW/
# DATA ebutcKX3RhNAUNUwQBiErj1aKa2bAYeg8FU9a1MaS+mYXsoFIDUzwjCuwWbz3urW9ub7sY3vZCI7Ub0Hg9FuKb4usV0tz2TpERJo
# DATA +CKNGx4DlhxpB4/L9iDZJCqdAgtcJG3uPWh/eX1zxU/IDDXlQtGqNfMdMcldPrB0BjTunBoHPNKuNNLJXj0PTGhQ0jYiQnzMXZNm
# DATA NkhXJxuaDbrrjTSYUZxcgR93HyXVoD2U4DqgIADt8xYLdvChYE+QJ6iNdm7Y/t0h4XXBTeu0yBj1feKFBpp/U+HcEMP+3yGElIH1
# DATA ihQMgQBQmXERwaJm3iKbcMmMYqFY0ithGEuTprfX1wG+8n0k6i3bLYrqkHG7fFu2McjwCO32quhjrl2sR/sR+ZCSWeIITRfMvWUY
# DATA iriPJk+6e5JiZdI6YsMOIHjeRlBE33Gcy5Admc9DvI3DDE+NtrN3iQ0WapQOUIdufiaEdVZ3rLue5A1sU4C9ZFRv7SivWdOloGJs
# DATA uLh86vEvfDkYnWHYJPq91DCuWDaPDAOLjH8o2wEKQ0HJKaXeuCPDmQN57LvVfQgafrp4s3Ln9mkcdkyEmoqy8OX1te2l1bXmJmB2
# DATA Nte21+2DRBHyRWw816ED5MIvpofUiFr/IOZj9Jiw3fQCzGdwPAwG7Y/mcwuG1PcqVmRGExcJKTn1o2JR3kBmZXEtI94iwwijT8cL
# DATA BMsEwmLAS58m1NDwyDgCg1C1usxYikIxPkF4IKPKGuS2E8TgxyW1VHVtM4bTsWsE9DVSTVMuAPRszjv3yD+PyLVMBYzHITS54BjZ
# DATA iTHD43kuBGeDHibspAD/sJifngaBBfWmDVgkwoYpM2WKE5scwLH2c6jko/Fwajxx2KgsNMFRSjTSFtlDrmM7PNSMaMWgkzXNVMY4
# DATA vFSimfZV72hTkA6YZweATNK8oWeK1yjjOsBlTtujtCZzocZDU0ftQxBiXhaWvLvTUjkPK7FoypRSKGeKGWtKM0O+9/DYK7+4sLBQ
# DATA LufDJ+ZP0Pp74ggJ50oOef8WyE1cLgjyTsyuZcuBbcvVkMN0hUCADmGnrpRBVczNTJZcSHsckmHm5u437y0tk2xJac63vuPzr+gR
# DATA KDEU2ByDgbooplpACjyUjOxyOrNrgdPKnwkJEHw8HuNleUYnsnpKWyGzhzZg7cyeXjTctKywKA4SQ1nTmSRC7IO7gvTcqEt3ROnT
# DATA ke+BV/ale40XoNzXZkAUZAf+O65tygSN0V5g7cYzM68t7XliwCHkZKorEOGsFFgd09ZImNFSouDwZg0vY4ZhGI5EWWnRCiDwuKhM
# DATA BQVp7ROpg5xUqmI71KnsJ8oJFFBHWhFVlHtcvegF5Tu+nFzmYnLVlxI3FH5fuxNZwryxUcilznQ5Wu0ZGFZZwE+BKRJVFcAYsMlZ
# DATA f3vF6UUYnkfLAr7/0KzuqT1ALfd7Jh6X/rVcLFI9yOOLucZdIiLd5KCOYhIPC3t/Zsj4MMfOpizSlVk3Du+2cYGbRvFbhuXn3fLz
# DATA 0Vzw9uHfPGBOja8OP6O8AnSbCANuX+YqoQeltYyT0szLhXPvLHC1eMFrxaWuFEWvEwWvEld3jci9HFzBHePi94sMt0RNHnMFbyLF
# DATA byEBlBATSUJfOTD/haub1n5m4kfBSrMEd3DNS3rpshLHUJU5Q648vVoIi4qaXtlljWpB8lniimQq1tYPqSXBVXfflNa0ZqqQ3Ofg
# DATA jLB8It21MP9onniB1PRg9d7m0vbq+lpna/3h5nIztgJtpfMUhx+NCeJGM3Wxtro8PXLXy+T2Y0izQbBQltESTzeoXOvRuaRtFuSH
# DATA HqW/0ijAtTMmALeTSv/2YHXrwdL28ju+BRF069y+4MtI3HTASI8wWh1ChC2++u6DirH00EbDg2SBFuQ9ET0B2foi20YdaEebZiys
# DATA Iz+jG71kpkbPEIRuohSEq1REaKVb7YpNTzNWnZSXqc5h4I6l7sk4jgUqv86ZuwESt5ERubnZXImzcUuLXJpcJJwis7bV3Hx3Ve3C
# DATA V1GgSCNx/qPZq0rIUNLyRad5CnFwYgqi3cnocYrK6/HxNK3NeZJNKxBYdT20cdpeOsmQhnV2ZupLmPBdgSDjrJJaGPFA5sxjgOaO
# DATA kMmBCGhL+EirWSAexkVTj6Qgsq3OuNfi/YQ9ZcFKfifIFnMDcK6AOV9SycIVMSa54eSMdT3/ATSPvrTN44H7immd8yhy6cHd1XsP
# DATA 1x9u0ZJsL23ea27HF8sRaIxdJwpckIHwHu9ycm2h4EBVxBhBWA9EECpPAG1F4kd49ztVPjLHIAgLUYDbGx4f7Sp1BlqskY9EDIzG
# DATA GGzQ+psKVkQigo+TCeAopIgphIhjuCkxyA40RspsDR5HmG1bieTYA267sFbiP4kywrIEXoU2wthWnl3RaIyZfKF4NZghE5StJmRV
# DATA Cag93RsbpWDVdiFf5vBAw/ZuiOUT92/cW7C40CMuBJ3ijylDB1uGOdFYRRcA7y/d6RxwSmjRhADl7CJtCfjZ399PUD2zuqFrP4J4
# DATA UADrjLrYz1q0hieEEOeAjrtDw10RcoQmAFcYZBKODOnsb6198bb3TFQ8QwOR3cAs9YEUSK3bBXMRPiMdocP4ET08G6qkLzroYmYP
# DATA jVczeRhX8FT5PLJOQDk8OptP1+pFYmHSOz8uLuuaPxOQSukAZms9Tq9GgH412hZ8Ui0IbDBy8pF8VS4fnFePEmS9k/SwPwbE2iHB
# DATA HcmLVo/xJz3LUui0MGc1eGboAqGToyDWl288CGR4hzCPLoQbd6YjpBaDFAqaCfSmuATS6FwGjqey/bCxp+Zaf1Ty93BK+qyE9g3y
# DATA 0zKejCaOrVL15ZUL2pfcqhw5WyOCZ4OMZngWlst5vC4oiDLDlNRdhuzCl/CuI8oLQO7PAsbnhzbMjp/ZzMwqQRRMj83gVXpUon8o
# DATA Oyr1ysyVbIdMFfEnBsge5NOQN4q8fU3fxBcQ9/QopJgnHeEM113zjJKSiL+WeSgA7j3ORX9hoElqJWfbFrSCvJCpjRu9BAgBgcyw
# DATA BZyuUqZTp2sZkh7m/uHqX3q8S7qXplRKs/Dc20J+FDz51Rqur8alK6MP9EqoYS2GSeeICppkA768s4586SVqOJt5xg2NFGERqw3X
# DATA y/UEsWcMCdd7CVVrhpNnNvADptbVBfkxeIjIzMf26PnMCfZo9skz05+kkBeJHmVFdSg+HnYfdfuD7i5hwMRZ+ugruU5mq6mpX5g8
# DATA kToYc+y4eLQ7Gg1M/3R1Jcmpj4Kr6zTOVl1c8NqO/zrWqrupf8qrVvv/ZJL9aQAkVd2iu70TRqxRIMs3JeQKYElwzl08Io5Ggt+N
# DATA hv09zMrN5Qmy6xAALb1CP1JVhEC0wtvlwlvF9vO3b4eOZ/9mggZe/bu/Ycpa2pjo0kBINrCG937OzoTaHDCVIDR+xpCsevx+2Ps+
# DATA pxs2sEgeO9ZYoBKpI1e9urTyvvIR4lPVUmCraHets9YB8Fq4QxgGE147MR5JbjYYiet0cX31+kaTrCG22rqYnl2DUVg9lr3N6BHF
# DATA U+dJJgBKYQsnjkTSthtEjABqTwJXYKNYgTjsUbxZXFhQgBh7o8FoEqjWtBMbJJfXV9ULxtJQ4BuBPsoFkzqfsi9q+bP5SoNX3BS0
# DATA JFeSVKWCLsxT2lD1TcWNhTR9oMGTq6vATdFoO4VQFEBX7E9FOVYHAlIWmBCTMWh8MHOpVPbNkg/+ZDFgbehXjWEaQnU1jSqBK5cs
# DATA PNPOwmYO0BZsra7dk/CtqLlX+j6TFFndtY5xjGC56nUHYCRi8RNMg4goievEYS1pLZJa3elhd2roFWDpuUaMGQUqIJXEAajCUM8w
# DATA fTyqSoLQGR2lraUrk+EgSdQY17LXO0Go5kxdAdyVlmUxElVErzqEwNYAEEzxWyzlVVoBa0gUyqYu5XZwoSEC0HGTqAz3KfLzp55l
# DATA m1u0XWXQvUn2MhBOaP2mVQG0bRyxybxSi/1EG63hXkLF1TB6ujOk3YzZeXlOvPtk/dbC4sLO8NTMOn40EpdSSq5Eg23xsNrUlUeC
# DATA /I+sucMNCYp7TlBk+spWMFsfu/JSBQAswyci6FjjzAREXJ4xcvANwizkCbNrRXLneueT6d48lpvXBEIqOiAHGmLZTBGjqEZ/BtcV
# DATA Gpa9hBr+GIOJBe9qyDTA0LhcF81uVY1yya+EyDQl8E6XwjkX0MA8YMfo6pRykjHI9shvmcgsgRrSDqU7Py07WbL4Tesyg7mRukfS
# DATA G8pkXIHs3Rkc7J2lrc5Kc6O5ttJc25b8TGpzCkBGZ2Wop9z0RtRgNYx2HM5SfwGsYnVXvQAMsQs33NZRqrhceqnqhva3ycco5Ag7
# DATA 7g4YvIuOc4CuFNx7JO6c4gL3JnssyVMyEjNk+qu/amfwiFiCiI4gUxkpV1K4BghG3h1GxiTiOayVxopPQK/beAPcV05TLSMPkbkO
# DATA MOtQTTuzGinQQC3xcBRfHGFZow7lv1a8/Gw45sw3bUBmGxGOzt3MkNxiasBLxPaSw3930KEOuBG5RrfKZMFR35WHopNHSdWoAu0z
# DATA Qnx1eG9edfq++hSoom7G5vI+00G5UOK0HNo/p+wPBqCmPQvW+j8egTeTRAoj8mp2jLkEHaiTkgGuFMYcc2B7M3ZHDilLWF9MGhqr
# DATA DN5Jhx21XGBBtQ4qVoM8v3rdaeIRYbA7IX8yk+9qPEau1TPGeYse1GL708/34+veUXjBeih9FV4fMGTcr5BP7gIUb6ZbC1B/uZDh
# DATA cbP5YF3c3VGrsLy+9vbq5oOmA75hb+664zpO+90+o+03HCXoflgOCnmHY7ZKDymjbW1lJb9K2yanucyFoHB7pF5G8VsawuVTzp15
# DATA kGT0kYzrBZsyOqdZQzkbn9QoL1lOOTexijN9nj9zxtYIxsqqrLGW0AKYls59KhZy8aSrHpQz42q5xgAp+X2H7LUgSyBhmxRu/AwG
# DATA IV/IbQdnHfQeecTsH+T6qGKv0ywoV+OMrBhcyQSuILAUBfCJWm55Dkh9Mav3A7CvELRDDDTMzWfBwQb3sslCLjIVM/a3K19coBVr
# DATA Hp16XPziDNEk0IRR6nhIF20vdoMuMzZ6AQcSeQavYCRV7ih5pJxvAq0Ojo062+cqHIkxU7F1ceTe3JAME9U3H9EXZtJF8TVDCTTV
# DATA K4sI6BJ7BZ1O5dFvcMq6l/ZLMca6fNuGRsoC49AScUFp3PaacuVyRaIviABm+vz7onrZbocVTSbcvfR6l9UYcQAhhB0FeWWVMZUW
# DATA Wl43XUMpW5QZdZy1lhXm1FqhvNFNU3YclQTBYIF44dkT32GmxXfU5yCe4J40DqRiGXQ2baVOzvFP9mJqPY+cQn4Z5YsurOuaLbNt
# DATA sc3VCu4otitk/HdkujKLbkP0d+yGgpDj2PCRphPriOFfrHmAZxQRBvFXaf/nSfRX0Z3XX7915yLe6M21dw1ZSDulgidHHxTRg9Ik
# DATA /ttAGHijZIQGVNs3dmr538t/SQlX8vR1EEtSe+AhJimHzYblsGkuk+OgaR9elDGN6FrmA1t+uLXd2Xp4d2t5c3UDQ4Q2mw+3mjw2
# DATA UIdQ1YJx7AyVRe/FwmHI7umEwJjx7ByXZMnsdvGylorlIz+9839aM00B1SItYzgXXdCukmdjZ4gJDaRpXmByJ9ranWipMEz0bsB4
# DATA WcZw0YVEh9qxt6/r80fBry8WRV3slpkRIJcxNz4iB3emJTvSbnEH2g4Epb0TrDCogkgaM0Yi7shrzWXeyP/l4aqOcApnBMvsEqQi
# DATA LrDsnuuTZDniuEwm0w5zig6zhdSPqyVir7xAqjzXFpEtJ3rKbXernPov+wytxSvSNhLdKPu26wol5+MhTcS7VBsuWQB43U+5HHiP
# DATA l3pl/b01QbYrzc7d++vLP2muiNkSfBpETawVvL/B8IlfHKtMODOl/j0rN2UGxfh0oZPCyaPJfS9QNDcBHTFxXZjZWDk7/dqF/NhQ
# DATA luDBk7ctPa64Q1HdNPK38fFwmYx3WbWH8h7SvYwHhda/Ylmcilij/oQsUPm7u8Am/i5sMpe3sVzYmpNnk/mOUv69CicJ5etME7GK
# DATA 4sPg5E28shjBMDKWI00guph+HQ0G0F5E5vDa3H96i0XIHnN1lrCrt21d0rZ2NZYw6/i/csuNf/Rev156GruGHInzPOt0QpbpCzX6
# DATA wgCuBbPsQcVTQV7ecnQJrXiunec7T5IVdOmbldXRdOm7mPXl4ladFzE2FFa5+ynrcpTHfkCAr/62rD32b3nmI65cmYWwnuKvZ5m6
# DATA LjThGQYyAwz9BUw/lzOCyDR83IqTLzg3qd1VWDcum/DupWUkxzLyfWcDzGR0ZjJAoqvjia0fcwR9HbmWgUFJpTLRZzh4QPo2uDq2
# DATA kttcWUfPGU7TIc23fyNBKAOl4SOHzga5VIyenDRiCcsRz8bdKAi2wagKIUSFuau6Mxaaeg7os9TwNghKgZhZYMT2PNS6w73D0WS2
# DATA C+LK6mZzGfAX0AOi+WBj+30dBdiXwe0X0MRbNgUl1UlABGMwQuRHeLOyASmK7bxAn1HTDy6nKsJDkY7yIC0WyLG5/lOjUiJJIzhb
# DATA RtqGw17tvjS0T7YcqVtf1kDXHyyteoo2tLoWxx8lPXB/MKV70gAifxuighqjIcuLJ68i6uTlisooVbQHGUvEsJn+LYy8pLE7g/Sq
# DATA e5G7chI7QKzcXwvq6DR/urq1vRV7W5FUN8xqslUvxP4svUt/3xq+T+Wmv+qSjgiZJMwTo+5k77D/KOGbLdeFTqPRaLiXvCmzuxvq
# DATA tFej4yGG/Se6xT7kPOkOOYogAVMApT3ZncC21y6q3F6WSkZ17IIOwkbVhXQ0HlvID/F3ngDbM4EPAtVcFhfKxVnAc0JO2ry8wh9b
# DATA rky6fP7QKwQm1Rl9YMyEfnnvULxYwvfKOQjWViIyUYSPDtHX8aC7lwRBqhuH0+m4Pq9hyuu3FihQK1QYlllug9pEg9yGdEi+fbVi
# DATA 9tuCU3lqR58asXV18AsSNJ9WwatwnFBooRBTUX1Sj1qWM4Nqquwo3uMxotqI8vvx4s03agvi/xbrT+HpKQZ4uJp6YjrwxlMH6oDE
# DATA repkNMhyjnBrGh0cUFju07g36WOuXzKxVaUOaDSW+sOn8VH3SRUMx1BoceGIdJBPqjze+FZ86jZAEZN7h8neB1jDVMwdDDVefrCC
# DATA 0qWgOuSp+N/9BHAArvG668mAWZhHU6GQleepzmvlmuA+w9Kk8VcyWBrzjU5qow/eWqgvlsu1PYQVKJWdEuInjvsXFQqJBrr+OjJ5
# DATA DsvVDwRvAy4lHizepFDKybQzTib9EfiBxTcXUjHkrMMVZrwlF0tc42bCUsDVjj7a9tWnMkTbc4GhZfHXmWK7ddf4OHD7xo+lqz8D
# DATA CKi81JbahKyn1htP1RuiF6fqLegS5H6BxdLecjwErkB3zZUtspS11kbSUUFSzL5c1FTZG6BhHpZxUxYToIf1m0I6GfeHSVyAH0i2
# DATA ghNzb32leffhPSh8JGauD1e26d64sRDjBEpWEP9gof4D5HW3b9+qi/8ZH+ePe2MkYBnKFWI1eobQmakeCqmqT0ZKnKxC/GZ9Hv6r
# DATA n9Gk1OdZBWy5XdN0yS7QJOmaJEWY9eCz01nsmOSoqpSjxD3B1ex/N35jDuOyHWPriAJS8onEQRdw3df9dQkMr2xhLdCH0xfAl8l0
# DATA ZTOVabl60EyVfwHlaW+2MkHey2y1ZlAHVdgcduqG5BAkpo2FxjDFmBS8zof8JEU0HJmNtrY0OTiG3bqBv5QkZhvoCjodsXqdTtl4
# DATA sybou9PlV0qxCs0GmiW44EYrVqr0qsYvJnQR9EuPCYNmyvcdVmJo08vxJFEsuXo8GfAvfBGoAqI2Hl4gUaljWzkC4i1F0AvjHuAl
# DATA ssrRlsi8jtOkCnxHf6OaSCxyg/XlKRgCG2jnzEy1CuQrSkP4aGMDtV/Sc8MQLE3vcNvzJUZhHiHvMjPFWlNkz4cesRxr/8jOn0lV
# DATA PcE62aBCgyPbiYlSEB4gSKDaZxYS16M1H8viP1A61VBJmNreRgEIUooLj4DuVr3jo3FaCiJjY72k3MCPBhA3fjf5ZDJMBXl1uule
# DATA v8/YyCzGD/J6mMSWzhft7ViY9GtiBdCHST8nj1KM+n1B9xwTLtW0XzUipwcVW9EFToSotHL7U1ZroV51jHd66iXC+awp5qsCflbG
# DATA OXop09svMKgZa4HbOoc6JHKV6u1lFtzlGTntuajD7iwZqjaab9aLXKJXBtvK6ZABdOv2BR5evmHNIU3kjbDrdMFZ4G8GYeb2Q3J3
# DATA d/RSbX2xVo1Ng/pXtyuGE67SYhkTCcqOGK+qAfpn+RyKxLpxCtA3NOL5w5WHopHyl3X93sKit2Gv6EbMb1YfwHVH9AWrRX7TF2dE
# DATA s7pinfge+rvy4s3oVjl7nzz9IDlhByIMxrJCxoKHbfn0EntHH88+4o9nkvBHoaZTWidaC+38Bg0RIOtaaZC7dPi+itXS4pc7VA3H
# DATA k7VOsmbTSC6hofJJToNFCVFXdKyDFqNOB7vU6cA+7HS4R7DGaf9geIyIgCX42B3UtlbvbTc3H1Qi/f2dhxtmhnR6Tv+UqIJKxDlE
# DATA rnfETexEq1l81xeSvecu7fdJ4sLWCeSnb0Ir2osTlCujR8l4kuz3n+S4ftoYs1Z+WYXGVyijY6B74iqcYipvF6Y4W6oRPTr75+js
# DATA j+e/OPv87Pdn34j/fhmdf3T+sXjwTHx9fv7/nH0ewfPzj0Wxs2/PPjv76uzr89+c/4MoCr//U3T2FfzyDF/++ux5LTr7/0SZZ6K6
# DATA 5+cfw9vPzj6D+s8/sspF8P/Q8POzT8+eiZLfnP8KGv+vosiXZ19HSxurVfH0W1EXtPTsTejXJ+f/CBWJ55+Kz78R356JHjgdfoYd
# DATA FvWffXH2B3wZK6i5t2xS3y4tLze3tjpvL63e5wn5N1HXt6JTn4t/v4LaCo2bG/0jvvylKE+NRmZ157/GGXlne3tjq6rnpRKJ4t/i
# DATA KD4RVX7Dn38tntNrH4kGfxOevWcwe5E5Uc50nP9KDuCP4utHohQs0b+IiaNi0NmvVPetOTv/lTdnGHHSeVvMVecBBKXcBVvR6rtL
# DATA 202cuv+VsXg4QNHv38NXuezfwAyIh0B5z2C8ZGDBwUEn8JExyIU7Cwui6/+vrFbOOH5/JjouRux1WNoidcexow6Jfnv22/NfibUl
# DATA GrwIWUbYPZw0nMw/cK9+i+P9XHxcvBP9pH83s2M6LWagX1lb57fiwxfQz09EuecV/BWb/xoI87n8/oynEQmwHoFqO63Ps7th8qR7
# DATA NB6gI6DXOaRQ7prFLP47tSB6JUj1d0A8ds+wsc/FbH6CDX8kCmNdYt341a95ub4+/zVQulsB0ugfcSS/PvtCVPMlzkT3eDoye3ma
# DATA zZQlG0TvKc2hhfxw9q+iZlimZ4JLPPcYR2Cn8GJ+gRQIO/GXOdtafPxv0dnvxZr8Amn7a1yJr0SpbwT5PD/7Hf5Cbf8G2Jmo6ytc
# DATA Xkllgqv9SlQpugC/it8EUX5cg0PjL/6M/6YDIUqcfLdtLIi/O7dv47/iz/n35s3bi3fkM37+xuLNO38RLXwfE3AMGizR5F/8//Pv
# DATA 2rVry8lkSqG4ScRuPiDMcl5RbT4mFV3yONqUtizpKkWBBhi02z/Ca6FUqsrvVBGpxOQzuIbIz6N0DiNxwCgy6O9G/BhkdFlkoirT
# DATA kpl6cqI+Ck40BjF9jipkIVNWSFfSimUa6tDDtBLhxYB1xUKiHqbpoHQd5OsKglxyWOZ+tz+A6w/zukYsDvTPgdUIlvELZCuSpWw0
# DATA hTwNDEywrufn/5WZFnA8Zjks1sCZi/z3WygoDhiSfCxR6DnyLNHEx1CVKPUVnpDPYheZ3JBbxeBLrZhHAp58MBZI5AepsRowJHHn
# DATA 6Y6nMJrR8RQeks1OoRq/bjiOII40qdf3Rr28LGLODAWQlGuEcSTdATUFdsbd/qR0OEqnDOegf6pQ8hhz6dJGrDzqyH9JvslmC/E2
# DATA eHf1H1GMDd75jCrLrPUQFRuI6Xgtsl61Y6zBDWwP8fLEATcm4Cr8Hu8MdyY7C/FMTSfJ/Sg/AJHwSSfFNHEyRygTgQwGUilLYeII
# DATA R7H7+fnfAzGAnPYpviKoxM8zPDaQBGBUfgj44sLN29F1/Gdmh//dpz0+YZmCVefhJJedF2OrSukNBaLnpoQmju5fgowWPejfVane
# DATA NsXFG32JonTksiNY+uTvjsHBBNyrwQn1OGXMUoliCyYEoKGaIoAOEbpYY/wEfpDiKd3wd09Ab15WC209pXAQ5gPxk9cXfog2reEI
# DATA PAXgE3o3JEO0TPzgzm10UUFGoZqVo1oXtWxt3ZfxGmnUw4xFiGnZTzEmHbxtpoyb/qbYJqBtEQs5/HkyGUlUewrP4PK0Y1XCot24
# DATA N0pSim83t00sXQlnjgT2jvimN589lnx0kdCfzymDZASC12fAFoGKHBH3d7AXgLboYvQs3/nxKupXfADmAXd54KwoWVxIzxmaFKzf
# DATA ZNirbTa5yrV68XW6wFrZV0m4ToCgTNc1uDF+CqeUMaOCG4gnz/Am8cwT8Qtwyu+lF5xQiGSJdEAkAOID2NUs+YG/0xH5c2knejWC
# DATA dZJh+Gm0O5oeRptbS7hhm8srW0tvigOKU6QcgZMd/no06h0P+oiZYrCr8fHuoL8HiLYeEYifBBuz6CHEb5iZBWoay9fFT5Kexl1I
# DATA dUFW1DStyzolv9Quu0bnXmk4jeTuyn/zrvT63IDjQCzDt0L2+RiFnY+lign1XiGh5/wT6ckIVs/gROndggbqHhnbnbmq9RIQZEpe
# DATA KhtRVw2LwSJ3pqNOKgoOe2kJG5TJoRqUHGqxDakHJWHUhqPHJUkbtePpXrkG30QvjsalGbwL5b2vIlRffUmzwDflkOAHV95/hEvv
# DATA N6QlfHb+D3izF9d+OwtO4AxUYRjjk9kCl2FAypK99LF6OTGOlzMBi5DEkHDCIuZjqCNVeDhG4cIIPmf/k6YORabfYadSR/ZCjqJk
# DATA L0PIUhoTMcEfCRr+GpULX8Ze1wNetSE/WuMFz5MW5gzouhRDjqS9Q3Hi1MbJEZlh+o8gYSN8ZQFl0NP5iEwvCqzFMEJQHkLZ6jz8
# DATA bEFvXChP7dn/Rp3R53i4fm4JeiAA2vKsKRK6cype/wNebtSsopxoyLNigBIhe2zJZ9RrP+42YH2w8eFAgBQT9HOx53GSiDM4Y+5O
# DATA R0f9PW7LnThVj2VSYCtC8WbF0NzAzbxVMhDrsK40I+5sLEPBOIuRTXrZwZjesMfOON04LrswuvbI8jIZjkx8SahykBSHL+hin4Da
# DATA cAx7vIHxa+R8jjC0+/0njbg2HaTVOLCaCJc7Smv7PeD8JbOR+PFujPYZwdKT7pGbNQmesf3PG5hRYn9wnB46gXTQXnoy3CvJMmIM
# DATA w1HJiIcepcqrnRYdw8RpX0Ks38AYAnI3lBgz14p5tIJNS0tHyfRw1KswkoCDwGamqKYCVnyWzERt3AjhiX8pvHPrB7cDPwM/i/6v
# DATA aGG08MYbeTx2ZW3L7HNd8AJxlP9e2QyMqx9w09W1VcU4IlS1S5MDsoU74k7lYE6ZqqQaYZWwx56GlJIYWuarxDrgpB8elOJWb5i2
# DATA d4bxDRym4eQg1ysZYEZiSIKgvD/FO8rVLZkc9acUvF56Cr909gaj497+oAuW8XGfjMcxhtzTupExXxXihC/07sHeiF7jt9TSZbwq
# DATA UwBQPynhgNuJ5IiT3AQ6B2KgkYjAHI1RrZKHjJZA8lOljWTLj9CrQ8wosDj+MuEvKn8DVVKjhO0zwqHO/hmIQ9k/iYrEcXH+9yTA
# DATA f432Ujx/fst2hG/4QidosKrUZ8/IIAhFYgcZzIR7k2NlgJvCIsW/IEl/fvaFaAwMPx9pO9YneOAZm8Fqn9ndZYJwLLZLtUGQa+1n
# DATA o/6wtB8//eAUzNCPwM+dPDoq1vTL7A41hNXD3KvMa8Bn25DakIIqkWQ7BQTBkBLOpmIwJtk+hNiKEUJpJIacxAY0YO3GTrV948f6
# DATA Sc0ED2w/vVmBxJFY22zxJUtlS5tG8/RDwRnQTTjmEAPqbXwD/70RYzQBUr0ciJkmFFd7kGp0SPvM1ZV7xeXH+Ufdyfygv6tTwc6L
# DATA x/OWXJhVyJAVZZ4YxUWp6RtypW5gCEV8Q7x2I/YjKexALCPvjKvtMMYmak5JHV1ce+K4WkU3GshSbgAXI+rGastFu1udmTjH8AUy
# DATA 7xpmmIn0Lqc9Are5iUz1IjYC1q5TtAVIWOfR6O4dJdUWEW+7pRAvAWyHK5zNaxyiFVwHPQf+APfEj5HZ/cFidtwnEguos36EttZo
# DATA Y4lcjfYFNpPigWjE/QyvqM+jpeUHTaXuTdF2LA6zcbInLoiQyB51Jk+SvS1MavJ3xyNwE4xAZ9JDl8G9Kelm0sNkMJC/k/5ECILd
# DATA MZ1iOBAdZbizAzS0I/5iI/bwGj28Zj57DZ699hr30KAPSk7EHeZ/4/K8pIUbsQzDsxNkxq2Hw/5UyBorRkDBZmIb0rbvb5l35J3h
# DATA 0r6QZRocM1UdgYiYsKNaxAHH3NrO8L0unBbBssibrM5wZIvozzb44wshKT0ciXIPH3TTDxoLQrrbGarZb1wTjI7m9EZ8bQeURHxQ
# DATA 3bl9+xIThJun0PTIiTEmRewrMWndAYyptQ01ibfWh8tdIYf3upPG9ar4v2jhVmXx9frCQh34lDX0TUFY4tz8edJbSQbdk61kr3Hr
# DATA DpTaAKV8CpeBxlScsVj/Klk22zS7Se/uSQM7n6qJdeYiEGFyqeCSQnElEo2BAkLGqNIz5QwFFYBhDIAQQuq96aGKdpxISdZw+WwZ
# DATA ERGmVlp8Zb2h5RJKpzrGg1CmLyvaImWwPRV8BR9x0Gaug7EfTHFDWeP8H6VMy+GHDZlZ1y9pcf7jCU6K+xYorcbhCA3Hq1NNuOEN
# DATA 7Gq7ujVpXe7WLH1Xt4Yar64dCw19Ml1JPa/f8YnleyxVdbObMT2+L9amQUJG08YNtFuTwqComW+h3ZopQocrdgI8SdA0R8Kipln/
# DATA pYdB5F23ErPCvKlDW3ykkzDkb8twjAa0MXkK1wiY0L8rZpAM7ztbEn01+kmSjNFSKRGAInkU440bcjoP9wbHgHYdgWfG7mgap9EA
# DATA 4vn5QpLW/CzZrXg6kLGYvC3rxmRau5liJnlQpjG8poWCMm95qyzsS7OMnS6RDgKeJgvGMaxsIkHXSMI7HaSBfN4sv4CfEkGeGSNB
# DATA 2cX6FfocQkkKyixkXvj2/O/p+nj+38gxAy+YaJyHC6Y4mZ0UMOTNLZpsWZ1pl980f4KetAt4Y89wkg57KcPR7TksW4qRSzkxg/X9
# DATA ZwT5gQk8WUVGIpl4+VEfrisGP9Ap5ySGRxINRgc1x/M9PvtXw7FFzGhdXKAM90AEtdO5JxM3MTrrdmPTJYb9/tDFZnVttaIdKsT/
# DATA s7kdAl9hIA0jlVa27+Lin7enX4b72/7jzsFxd9L7Dr0A8/3/Fm++fuem7f+3uHBrceGl/9/35P+3nYBtuzvpDwAyIQVDC+SNZCSf
# DATA h2+/J6RYzKbKx1GF9O/9ISUdBUvEhBIMn+S5AO7vDaeDC/j7pYfH0756gcJOLuYByN8B/UcquNBhhwKlZvjNkdtf2DtOHP6Oo9zt
# DATA 1/O9LpLho8bT69dHaY0DBMX5en+5s3QfPc+XDYXvTD+7TfJoNM4x8BH7jKya5x/BbVsHEjyXNjeMahD//Sd4KF4Ry/pmFOCn+0Lo
# DATA egxIT2efgo8MuuV/cv6beKYPn5izjnEcynwQEsTvsI9mSmOSN9B2Y+FT2Vi5bL2GN2uPu4JBy8l+/fZCEUhKenMKyuoh9KicDckf
# DATA aGRxwQOqNzq/TaWaT8Y23puu7IP+YOBCMepW8sxptiGNbplawSTtOJnaaZ8+8vXTYIpF6+vHqEMHcvhaxdkIMtEW7hew5IljJmjJ
# DATA A6Mamb/N+nHExax9f17GvkmyOxpNO5KdlsS0VVhFtjcV1yOxyYREM4L07w1WuXiq3yrMtawBJKDjYX/ayFTQeC8iwqpWZWnKo3av
# DATA hPa+svwwClIgt1/IveKoO/kANev0EoGnEOZEzJrHbcSbE9NdRQevn412xQYXgwZ0u/HosXhpMEpTmL5B/4NEKirFXWw66Q7TPhx7
# DATA eLF0NY9iFl9c7cicAJaukqUiw4XCTeic3qIbYtakDhH6o1SFVs52yPTQ61NWzulhE/0oGjJBBs1gmdIa7Qwz9YZ2jabmEGDZeFZE
# DATA JdcizpkqzsLu7iAxtIwbo3TamD9OJ/O7/eH85Ciq7kdeN6xmslR0CKxUPYYLkKGmM7SV6BFvbKiYUmgLsoervlSJeaWoyzHtpRrm
# DATA ubbWiXoJiRdQaJKtSn8ePsooVrbOxDmDFaBQnvTkAVmJKPZXdI3DEBIxfeIezt8eH/b3DhskM9XwS0VKZWbiKPE6YfNh9iGShvgo
# DATA xdrEj/ITwBjaZzoh7e4/FoWwhVIsvthmBvHAO8G5QvuoZ4fmBs018jkJONP2/fHwhxq68qVwHFAqj+MU8krTlFsWipx2uZ85NQbq
# DATA C/G2fw+JVOz49C0H9X7GPlKCp70ppWcjqu2PFFJ79g3PobSFqOnlB1UxR1YRQZRuIfHIXglZGWtIVKkZw+JAQYdrS0fpT3FYJFqq
# DATA h+C46cbn0lwoxw9/IL1+2p0cdYD/ggcFkyoSnX0GlkOHIIM+i80YoaYtcPQF0T+Z9S8JHiPrl6nEQLYAnRuoMKQQXIuWIpDjBAeT
# DATA OKMTwC1FP15QVQyiPjvgGyyj54LG7o0GA8YpqlbxNMa+EW+vVgX7IZprILKiZnTiNzxhIDHHWFDPSWNpb+940t1D28UiaMto4+hs
# DATA 1JJTtcvB5BNypxkvwEIYb8zaP55sY2g0sbPi3nck5uvxYTJkuHYOHuv2B4bmMtwZu/emSTWHSxTcxVkkr7ctuoWzF/IvxOZ9DlGk
# DATA n9q0ffb5mxH5J6FP85fSApspwiA/4B/kw2+hCjCTglM0ekBacK5qZ5TK9nyZRxJDcOEeAKA3ZdP5zqHOCgJ6Bd9lWorhDiEu2A3V
# DATA o80mAEWvNDcLYWhxNTSktMZfW4v1toJ0ks/qi21QuwJOfdwmPaL5u8kyZa3MMilYjKtZaDtm81mir3Z6e3b2W3RwByryLeNfKS1/
# DATA 2XPji+fFsjsCOvgQ1AajvQ+8exk4wiMSyJBvkOLbemd5s7m0HX1IXzZX3tuUn9fW316/f3/9PUtSIfx7ITZOjseAKCNhPvYncHtx
# DATA HFsRbd7BEFld2zYhRPIhRXxYEQmkr9/orN5bc5W2P0lOdkdCPFqVPS2V85FNLtSrMNCJMSts+J59LYVlMuYMFGDitikeluA/FX4C
# DATA +CSd5k9zNNOeLKhxvV7cwuBNZg7mSqyEGBRwxP8wnPXNbP73LYIKnP89RtwQrwxro2Lb7GFuJ8PwcTF7Rg5mTNjkYLaqjA6m7QKD
# DATA ef8R1Wq/ytShBQYoJYr4T83GQKleqt0DcEX8jkwAufr/xYXX79y+5er/31h4Gf//vfy9+oq6eEMG6vHJ9HA0vDV37dq1+5y6G3Lp
# DATA EJVIJ7Ua7BNO9U1pvDFHAKKqQWaAyej44BAlQiU1FzYMHHZTMAior0fdPbIUAH4K6jHgyKEfQe8LACebEBOcTt8RrHFwFfACQoRU
# DATA n8HVakrNZhsfgGdY1gZs7HgyEG3VJtQ72SZ3tgI/w8ExpzpAvMdoRTs8IMRv8BdGDZ+j7NRoUGd7fQdd/YUkZ2QZmFu+vwo3Jlxz
# DATA zM1OKhcpYcRzy+tr20IQa24CZNX25vp9LG6LIaBMnYwG8dxWc/Pd1eWmfQdjrDekGKVGnHu4trrd2Vxf39ayTchZbG7j4SYkwYBU
# DATA nhl1Vh8tipa3l+41tzBECrUYnB+lN3o8REUORkpRmkZGc6W8ETEnxzzhF8CZoz8US8nYr/19+cueIOeheKE892Dpp5376/c6d9/f
# DATA xiaNsHmltqUkTJPRgZjrlPPLTORKC4ICKELEg69EySMdHiN2xQaET6aH0S6Y2MQ+EvMwpjJphfNjSLlUitEpXpO7jyMmQxkJDnuM
# DATA 7m9EcQ1Qanb6kDMRH7Ayiq7cdooKKxMperjA9lHA07zi86w2MRLysXaGXThEezKLteyE1D/oQlkKG6O+g0QGQvNCQxZ7mBOdFoez
# DATA UNGqExw7XDGTnq+5eYh04+fHubfZ3NqyxW5nwJRlRK4rqhTkuJyslcMRqMUwAhT+Uwrcv2U11gxrqwFLPgAgvjaavg3k4ESTGRU8
# DATA jXGW0D+HclPgv6hOTXpLAJUtegQ3aqQkACRHrHGGckkNRHaxTx71R6iLkw20uPa2Qi+AlwSzEFsqwUQuwIMEoaZSGwL4e+TVJAgW
# DATA zIfaFwo23mMhX6YKqYDWtAYG5CclbAkiaK2nslNlf/QtYxTtliwIrk9H3SelhQouRdUdi56ZdtmrskachfrS4Bm1X2uIWjkVPGxj
# DATA XENwSoMQhZ0nCwvVnSeL+ztP3tgXH3643+akY1i2LO6gNxfac/YgeGGg36XA0xtR62nc1euINQEaPTERKii+47+n7XKrevN23W2D
# DATA 8/jBoEUzoqK5UO47zArI74R8WqkWl7uRf1fdYTg+L7Ad47Gcp6kNJ0sN7pfZG9ThecZGtW8Y6k5helhJb6pydh/DOx3JVjx3qNjZ
# DATA T0p7MR4kHG2lJ2x8iGjj7P3JRWKeYDjlKcW16ojNen2u6lm5AbQffMNzWTwfsmJoornUzb2KOgK5/eCQ5iqtTen67wHkKTF1wbn1
# DATA 23hbl49p3lo4b/V2MNGhngJ0Rynxdk+Pj0qq0hZW2M6tWzCH0kweUfaTdaJzhupEI1qoB10+3LXiXFoDNCmC5UX5zPX66XjQPYm6
# DATA GFHXhRQH0bWFiMEGrtVc/4N8kjW8Ar1ksEJUNUhZHx4egcqDZBXmCjIfIVnfiBblD8ti6oHvDJJhieY1lAgDSXdriokprLKc+o3J
# DATA Hy/Y2ISbGCmZ7BF/W1xYCLxDBECdu45l5s1W3C6lxrFobBn9mLJYSGZZD7NQp9Jk0B2nkCkEV0u8ZFFlyWhnX5BDekgNkTz0GIgw
# DATA 2BM8vsreCCAi/Ag6simpy2hXPjKPe/9IORXsfG8gSMGShwwnS6ksFsRCjF8ifAxGB8z02dOBz1zIOgrJfgI5LSVXwcwRflbFotGV
# DATA q0N0vFcIXqI6XUuBdGYXS2DGMqCZtUWF3+/3wurV9zbX1+6/L3WqlrK1+dPl+7nKVg+hQIliwCf9PJN1l7Gq8hCUC52HW4IVfeYu
# DATA lV68GsEVybBL9dhK0Ul+v/oXCh4PAA7IMlYK2ixUBDEjewNIArzfc/2gDC6lVav7PY7r9+myg9RdogsQ360gzmOqg0D5ckTSTilu
# DATA gYxAmemmk308wePX3q++dlR9rbf92jv11x7UX9v6m5hc+2oHR3TGoxjRRq8EuodA0in4Rk2Rl0SsImrj4+l+9QcQjQojTxsxu3lI
# DATA GYT7JD2P/GExGhNTWmLsT5toClHl0sZGc23FJcVMBys13aBRpZ7WXQf4jPmPGcmZbEMSnlsppyEdlfLsoB/LRWsWN3AIkwTEPbgy
# DATA 5VOYwcQoc5tEt/JYmdwWmVOMk5PJCZkBfr8zxRsEfrL4LPOr/KkxxVmaIak0MUaH7m7a4nNFnN26h4NG5eHa0rtiGpbu3m/GmSxY
# DATA 9sVfmlmmr80VcxdIutff1xAavpij4UTCimDQk73KR4IHMAQS+g0CZgaVC/gNOk4ota3O6tZm815JViKxNjKjWArMor4BHA/3unTR
# DATA MOtnqA9LsWUb5aj3aZJ8IAUa7/2q/b4zRFBPNWQ9cNso2aUDNJppwMkfMQUD44sKw0GO26wJ+iP+C8bkKTq9lXaRZ7du0oVFlWjV
# DATA odhESG09LgICMBUC12+uh8HDsll9Tm+SYY9vMjDJkK+1NImr8AeMGhANovZ1xnaPftJ8H3+KyfNcz/NuctAfDjMqutu8t7pWuCpA
# DATA L6A+wZGPgB66dlC+4Y/kaSHkgh/pX+Uzh155ouLWZnNlaXm7uRIZfWjjGSxKtLhewHYqs/pCXH8Ej0o1ppW15/lXCQjl32Mtgxbd
# DATA XluUDkRevy+qAFDXJzN7cSN6Kluk3JcVxRk5s6n8GshYx2IOJfMzeKp8JC/9oFWGpjAFofyxdjAY7Zbi61Kp0arfuQ36IiykSgVb
# DATA ToWE4r1966aGDqMmQfzkxnO0CQjiYqsS8B2P1RlmVnyHrjyGGI/HeoDfGfMNbiRk1sAqWsbr7XL5yi/K+1ZuekMa7yd5UxI8kEIp
# DATA hy91PL3IEZV16mSeVznHEONzTPvD42QuEOhiJIHO5v8F2ad5OyK0VKTNGjBnuBcJbve3O+n10lv15AkYx3bSG+W3SgwJ02kb6DHt
# DATA 62VRsAGFa9fLf2nnfQZjTe1BuR7W+WjOStznQ6CTx4LUP0S+8iFLeR/qwMgPAWPprQ+Skw/hyAQlGcQsf5h2B9MPeylCB8BgWott
# DATA bHk1Y5blFqPCN9uGxxsmud65thPH5eCrouOgEMEaytFfNaLb9cwAJYen0jvunvIESW/DUDWIIjICbUbpKfUf0Z/wE/zE3D3AF4gN
# DATA 4AHkdP0UMSMbA8hvz0gvdKM39iKdN/CP8qmntirGIdSWMSh8jEsVfumt/lG51D2eHoot/nNUJQpCadUbbSKuXUEAyeRDsZD9vTLQ
# DATA 2M4WYNJM4p1Fo27zUHVbiLkNUVnrmuBZb+3sWsQpnm81lzeb2x9uLG1tvbe+ufIhZk35kI/Nzlvi3PxQFFhprm2vLt3/cGljlZ4t
# DATA Pdx+Z31z9W+WILtQ2a2UG1ODKbf+dmeyM2zfiOOLDWC2UNHaSXe22tffEq3OEmU+/MtyXMkUDvK6sbObnPy1MUgTAirr+25s00Be
# DATA /SWA5RGvt/lfUceNWrV9vT4/D1OXzv+43r5Rp0/tGz/25vDH+b1/sri702otVN9qX29F1Xnx3x9X/29pLfLek5Bee4fdSXcPAqwR
# DATA mEd9E/sJS4KC1HwI8RHTGOQ2waT027iZbt2MyMfR+uGVRrR48408kVUJdCt8XYw49WVKUd/ddEpI7rVo+zBRCltLdUeaSvAcIax2
# DATA dKuoAQwfy4O2llre/MRVWH6kBLhT0g3DGwA5IjsLj+TnU77cDgCxd9pRjigd9lMpaQv8JhnBo6PjKXgfR/fxFcSgr0A/h4IdTbHD
# DATA 4D1BTgLia3dKwPPRtHtgmN7Ho7TPV2Ud7Ukiz2bzwdrSMmRu2mxurG+tbq9vvk/pdafTo+5wXqHeVFV3XftZJjaaoPN55zvQpupO
# DATA MaP4ZvN+c2mrqaI9pVmPnVZKWvEUy3xG4qSrHQip5HgXXGrnscX5p7rh03npGTRPa/GWcuvooOtG46nrpX9qOMETTlnaeBov7cE5
# DATA BGoRcOCAgBTAR3007HHzN1CirUACdFFvdZkNhHUQyKt78CwOxOjGDwUVVpcOOL20XgLzHhGf0puG4yd775SUk4eRMgOEsEmSjkfD
# DATA NPFuoPycZKKbr99hTxK4Yqq1huNPFAeruC5xqQXEmbfRTKBik6iMY1ilqAXUy8tQjNgKOEashlE9ugeo1NKUXHJaFSX46GdfEYfM
# DATA H+30BE+X/wE+2T1wojUndpu9SXcfbC39FOvDDJVeobE40WWGZ6vkZQbOeR1gLOCFboV98TNmSLIkiTf1jJUwBaLwrFiTIo5c/Lf8
# DATA lpges+YZg3i3ubklpAalfJvgvXt6LFh36ag7BkRVrk+CnkNCLI2SNDwpwUtAp4u337j9g1t3br9Blgx4Kk4irPIyfeG5oy7diEoL
# DATA lbLYB6XbURV3B9Wrw2Ytd5p6rsUmfO0K+nSjJnySASjMGj8OEMbtDNi5r1u7GHGlJapuoWnY2oZ8fkxVLP8bu9dC5A8TTfHNa7bF
# DATA E4518LSyJ8WFKBWU0sjPHz5cXeFXUbzAjwV31n952Nzazu5XKh6NTTeUjoyYPxKnjvzGuWIVFHB9hvcbO0AEnMDmDNxt8d02kYkx
# DATA 5+meiivEH65tLb3d7Gwsbb8TWz0qZteUhT2rpu/Vp+dMUZKeLAOalZ6h9thFw9LlswGxDCJRVVVQTeVaMo2G1OfWQttR+lGwKJrl
# DATA zCzb6o0y8fWljY0OXaVQrA5hfIGncyOikTB8lqlPUooaa2xGCAXoIWyV69/qVhtwhdgHhM+nd26fSk0Daxj8IUlFAMLkUh4gA0CW
# DATA 2QiVBr3rrZu5RPRgdWtrde2enAA+lUFLAZivR9292jB5zNUp+N9KxF63Fel+XUsPu0LyQGms1z8A0a8c8B3LpvuKEN9J6Vqn5k8d
# DATA FG9ZEdBUydy4ZS+PAa+QIfWlJoIguxgrZPCWBBwE90AM1dYrB84riDrGjuyCkzAmYCl+NBocHyXgCNyyXASVd2QLXydVFH6C5E1U
# DATA Y38/qFwpGVsASzJzpjxO8EDKSAiaiK5fngM2sJiitSsFiu/GLTsrD/J6XBZSyc12uW1oetQ2FKt3MoaLV7zbH5oQjwQIx8ymrAEf
# DATA 636T7F7dgTgB8TuwqtO5kPeC6WUAR0VLdqQdit606J2b6jxYf7i2DQ2/fX91eTuQDI2rdwx3uHpS7yVbDVG6fbRIRGCjATklqHc3
# DATA vaRVfoqsPOQZL8IOYp++Osml4NOOLoJiVfo9hCNgJ8s6mnMvmveJl47zbstKohg1sfz11Ad8BcDdpNfhg9TIJS/t0eVMVAsO2C7N
# DATA wHwFJYG44gNhQ8rfqET8BfUG0q1Tolu4WLgOIIUPeJv2QTFhYtyqABgOfomqd9H0bgyNoitC40JHEIqIxZfM2YGfUMfhdQrAO6Dp
# DATA 0bDKngk7Q36GsLQ2HG9xrIsQ6erIi/mIAzYqHHzuLq2XOlJjC/hQGRXCjzBEkPzXFYZGXK0OR4/FB+7NhWua0Exl1iAvBQiQIiRY
# DATA 0MlPT1hgNCQXQwMEALiAeTYAjnWi8p4KXoiH2puS7iCms9uLpoAdQ8dq0hVHNk630gFlipgq8UD2wZmThsASNaVs+kICpsTWpLYC
# DATA jErHZWjp0QR7zRXM5DOecXEOJKbcmCeuccdu3Yx+1LAFoEZ0e+GHdxRm+aG2KbBulHCMdyYIsYP6IHDPj9vlPyG5SaZs8GUk5aOJ
# DATA Gqm6isnudPpix3Y6oguDfbItmxHL4mEtm+xUEX3F0W+Y9xzVHIpc2JbvCG/cI8w63XPPqKz7KOF+e6oJa1ry6uN3nfgEHbJO+tKe
# DATA 32c0aDfcXrsWd07L7ni792VoF0PPghAAXtoU4cSG/0jZzamUYK2yN2H4CYvw1ta3O6tr4iJ+H7zBdNNSTUQ1t2L+HoDp8EroaQGH
# DATA LiYYqaYENwDzPjw7XkzhzoEzfSjjlLxg4sQS5Xg+ALkxYlfg6STtA5FcFqm/dUO2xJTEOaDEvn5jzMFAGYq4WF32bt6G9CNQvJjr
# DATA Vljd4U5q5m4rxdAUjg+Xxg1zCU8+T8V3vQBOx/JXgenYckNUm9TwRdR0jb4s/lbXQJ5O5GxtgIkjjGrLlt81JMQhxwKownFkcp08
# DATA 4A/A4oqtDVTdEuI6hnSFV4hXSdRpxwFhmKOYs+MEL2Ay4JEueEb8UVTV75qBBAugeHzj5kJGnAq8w3Fv2GJDxk+yL0ZDUOh2c3Pz
# DATA 4ca2xZlUl3FkohaCHRcSVF31A5DCzcQCJuGJoZhJDXi46t6B9rADUM3EDsD47ADJcNdUwJRlXBxzcAqt+alxXPnh1cxE9w67Q597
# DATA os4YCQCRPciEAArj7h5h4gQ5jPwRdaYG48wK5sqT6zZWwEHg7sOt9z3/z5NQIBV5D/vDrAHi5aEQ3/o/T8wdSOMuhxYjVMsK/pPl
# DATA 0pk9EMPVmXw6yUfZ3PQdcjak5SDOrGhJHXIXPdl0qKoKLpb3C4myZFw5hMx+MOn2kgJnezaHR4YT5FRiaKiEMOefBiokitHjTq+f
# DATA Im6ZBbXkDQRCCGU/kV1Ag0RaR92hqK5HNi8k1pnj2Fi61+w8WL23iS4mOJzVTYsnZO4B+JqxA+in75T+2Zu88Mk5e/MY6sBQDHdG
# DATA fI5/9jZyzt7gy5pl4sGtvmZ7dV1Y5HAYhGx/9sAucWDZFTin1o9yTq0LrX/xE0M5srnyFx0UEFBHYfZ6Heom6zEWt66Fba2v07Ni
# DATA xiIac+Lq3ew9GYjYdvJrZFJshiqFsBhzkQpZp1ZFmDcAAzQADE1ojgNLyg5rIcV7CsRQq7aoQvUDoy896D4BJRjQABRw1XP40l1Q
# DATA /qBSLrM9BqmDU0WLfRWWTiFTVjLh9uFBvxdLRisegeigzhNLu2Q5eoSIrXRJrCqL8GYIZuK6uLndURFELC81/FCnubC7pzpZCorq
# DATA gYKTuMo3n2r76a07pztcMBTVdQESztji1oCdQBMZDAUAtbawAItsyQqXFBCu/EZ4IdZ86UPMOZTL9RkXTP8YK3J3JKO/B2IA+hFm
# DATA elkiqPUY3AMdtZSMaSsVpNKyW2Fnb5Jw9BNKJLOZJUXnIRKKDvgz9gvktmE3xGIbwqduu1/AUsIsoKWuQW1GdRLfywGBJDPCEDeN
# DATA 3LsNc/r0yaXgvo0lNESNcvjad8Wiq5p9Lb/KOdB9aYfkkCuReF9I8r3ye8QLiW+hw0OJYS/Ck8kxKhDhqtLGE2Bra/n+qh6bn36V
# DATA TlypqkRcG/AJjds5q4n+EFwxrWVWvbgnTeWC+twOn4SObHSdkr6EZYITcCiACer1hw3jzZXmu2sP79/HX0AukPuP8k2pryER4o3F
# DATA hYWwDJ6zrZfXH2zcb27jyW9v7WL0oKFlpDyhM6VfMI7qchJOf99kgmFy4gB5ggmYPUUyXF58liLIpQQr3O/rG03e70GBgzmTAerR
# DATA DuABFdhjlrXl2NNn5qrVw9g/gYtWBsgI6gbvLLiJazAfQIe0mzxOUtfb+8cHXvd07ixO2ZXYU9PFpIaNGcbefsro6PZlBbrQ1jvp
# DATA 9bKRMQnBeYJKN2jRJzjA5+kJMSiiW4EG6BkkXdFDgDPbnYwep5CcmLUWAD0DFDBNBie1MLfMUodkXvizfyxkZckW3CzyCFhixHQZ
# DATA S1/PdSOxdhHD1rN3SgEtMmjz5bZpGIRazm8Th4xWRPt08vM4HU8mHHkI72iz4AVDRMtZ1QZ1ydevc87LuPtIDB7dHOrqJXYtZ+ca
# DATA 1SXtdsMF/YuswjUThVwQNkPGokk5Nc1+e/LeA8mm3FA5MjDf96iN7MyYyLHTKfWHwyQUlIvPMU6U4Q7IVVo6Wrs2XMYBRcDyig9C
# DATA bgHmuCA5MKE3AnJLUHR3EbZ1Px2cbdFaCTGlYG5IuDB+X7tbztWKBQV2mYcMGhai1up6hpbJnr/c082aZovqAp3ybze8lk/QZwDr
# DATA qkTXO+EAV93UhXvM7d/H+6V1oCktvfR18O/e9EsHXfkrxk1cx1Kgo0kl82p+ea1zhtplFnsNG7Jn6XItDcUL6TMvaWnP62Bm52ah
# DATA C15qAMqxiVYd3HnkarsMu1hT4D6x1nyvuek09Gq0PkwUpi4KGj8biYF2B8CP0+P9/f5eHx27IK5PxihCiBZoHWBWuuICd9hPEdTG
# DATA C0U3gbpMjsfoCgqPUsIs1IvzMCZ2C6arBS5QBspluV7FJ1x7OzME/MWRvfIRvgreGTLqzVG6K89XujCFFOnS9VVr211/VmY94TFd
# DATA ShGfKYl8P+r3LFW3p5IPO8BUMtXwM3X2349q3tTK/6mo4AvJuFepkJ/hvAQB51ahC6nhcwn4qpTvht79Mhp3V2+ddaK/sN9ZIWzy
# DATA HJ11f7g/CmnmOaw0Dy5cRyIRAlDhOtLDC+q54XfThBDSrs8gufKVKM6xF6w9n03CV6w474Rt9IZak6jsoF5QHYeaJq1i5ylLesR8
# DATA Wa2OvbFPJXQDA9JvGDMdPr8pSs3NGm2ACKyvb3M8jsVFdQkWxP56/a51Tpo4BBjE3Flde3u987bY4FwfUHY5M54kUEFzbXvzfbMG
# DATA JGzHgctZJjrTYZF0Doe5C93/7f1p52AwiE+P3MwVcfZvOnEP5fb59PxXmJfrI/hqeTBk3ItkSsBGDsxEIcUzKbeFAAD9q8qwdEdX
# DATA ripvY0RhA6IKi4T8zNRYIy2zuho/h87aH2apqjXIgDYlIv1klEbP9J6GCWgRL1AbJIyEpNyh6fVw5WCeI0Xr/rV3ZWIavUxP1cfT
# DATA Oie2eSorPFUhHuIV/i28gU93htdUCEB2P0JZpY2DyRtQ9CN9FQq2W76Qq4/cmHBB2mwurbwfX6QrF7qWXeJ6ZjnYMxWoxdGs8pWG
# DATA Xr1LOjqZIA2B1pFNeVE2IBSoX2bdjC7d/KvRXdIqQ3uUYhdx8Y+6J3DdwoxL3WiYAG78mLLE6DxLtbmZ2llFzzyhjTBdSRWNLCXJ
# DATA QAm7WF02G/yOuPM/a2Zs5ViDrHJ1yNUJeeY+P/v6/NcRnaSy15QOphjf1TeY3a6QrCrG0WVYMSXAY5gbm8bB74stZ9Kzu11hC4WX
# DATA /UIEzdgcnQerWw+WtpffiV9klTmxEizyv5791s+W+gVmSoV0er+kFILxjEWdeV0rYvKcJeo5Ztd8IS9cdabOh9oNZDvxnX7yUxGV
# DATA Z1bvZs9x8j8YaXRch83Z6XTy/QvClgE70QiExJk5ioK9Ps0Qly9h2MnVRn2nRvBXESWNrx6EIQNBhBFq2HvR7gnFmI5H/eG0Fm2I
# DATA SYBA4mgDFS3zw2QKl+xAraxsgOjUUQXvN6KNaG80hrxmStHZ63cPhqN02t8DFeZ0ROfLnkyLfimTfYY9vmNC2BdXgxrbYabp69K8
# DATA yCN/8m3mlgmHQx9KhcLrM3jaN5mMTSYtm7tKevZoGRXXtCgYgL/1/tZ280FnY2n5J5AxRXo2iYvgxsPtOG+kwbypxh5YxpNnw94G
# DATA wx4RgGOkf+P1vJZw/mdlbDWOKZmwlW+9QYXVpdR7PHFuwJuTCP1y/iGFJCi4TknF+1E/FZNwYIP/eCqlzNIqB8yw/2QL8RdLZo7L
# DATA 2vYhpUQ8eNB/sjqsWAkwa/gS8ip6VaYHQGCAzhRfTU3lDGgDwdrDO851cRGnwZCiwStRt9fj/Z4ej0WvMBJEvVgOvAPoLXw7Lb3u
# DATA 2SQDdSv4KNH3Esbcc19oSjh/aCmcVrRs5h0gdngk6hTVsKrTM69am5AQCcaDExlLJrZABTHEnLd2R70TG1cDC6kbZ8AekQx7HYkr
# DATA WIJSWYUITLEULxOEZhUAMWRGTAmoGFBSBiqwIBYrCLGIaAtx0abvJ8ODqZS4wZgF43b9TfF1/XYaGv1jNEyTiIF1WFN+iIuXRX9m
# DATA YHw+UZlwAFo8I9yGIsjzIVM0wgqAaNqdJB1GC8De8GgZH8EEJSaIBPGfuwhIjDcfbKGcbdnFcw8p7/bCLRCwpHkrfnt98+7qykpz
# DATA LT4toOKVtwuZjRR8NO81t8nbFn8hNTPkiyU5Is63h+uO3QRMM5o39oULh8gWaJ/SEaQg+JTieVByU2j/fKafbV5vlBYbqiYrrFNn
# DATA +2p7epBkdlSiM2b0h95sS3in+XxccMJPhNvhze8ugix7TrF5RD+nTwuXn0YiOI7mvXhvKJT8BVu33JEpCvZStB+IPC7Ys431rRft
# DATA 2gA5sqIwgwl1IIGjz7lb7VwS4/oIW1qFeVq8bXvSHab7yaTahMONYgVZ/cZvC8qo9VPBHPtTrZpbiH4Et5aSLoMqSxsk98qImXE+
# DATA DQREWj08dxD20+lLOdcdwxBhoWaJCIfzM2W80FfABQLxTjAunnHJNpNHfVQvnH7fWzZEmNjTFyRO3Hzz3T2Kp/zzpMqbr9/5MyJK
# DATA WLEAhoMODfsuaFNzao7/hw61ZF/aJEZbsULyke5XuzjZ37zU2ZBJ5CQWviTv/wzkbatxvyfCNmnas81cBR1ny9TW5eC2dTkA093b
# DATA 6w/XVtzLwXeqFrU69EPy4FEKINhOpm8p6Xtui3MqT42kx3QJXZK7jsZc9EYdIQ8CPJx1xzR/B54QLkBqFemYQ8vke81DKYUIaLyi
# DATA oPqQhI3nYSxA5+WQtdP9Hb+WZoctM6bg1vryT5omlZv1WR6j6HFjKp+mUgFFLjoVqYYhzHUsVA9WK4Gu75iOCayown86+yNMFoQJ
# DATA VvvgD8/JNYGOOh2QYjqdWGY9nqToyCH2H36uLU0OjgHGcAN/UZm2wELaETLQXqdTNt6E/GSdLr9S0i6O6Ly5gRpwBhrGb+J+NhpP
# DATA 55XLprTcBCszT9q9wxEgGzcI5BjFQ+006SAbIEy6DDoVU1GVSJhYVoaWtHOHIeMgcwuR8rz8Ztbvg+5uMsj5Hc1s+U2AN2h2Bag2
# DATA zfmd0XtzSjAuJXeCg1m5LP4DpaX+CUJV8TBNjvtsY11w0SW30M23+QTu4pvHlO+G3EpobyvYasgVArSikyqIhmp2KKyOA5rLMm/g
# DATA W2TewI9iwvgTrg5/xpXgzzjrEh093C5RkIkzCcD7blMc/ISfeab5G89qfiMedVqQbjaEq9t0oQZ4R+hqEVtT11WuocOqnLb8ysw9
# DATA llOjxp/Ah/i139NrE0KlJ720W1V57i9e/r38e/n38u/l38u/l38v/17+vfx7+ffy7+Xfy7+Xfy//Xv69/Lvs3/8BreeNIwBQDwA=
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
