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
HELPER_BUNDLE_SHA256='d3d861c13d57f7b42659827e76d404c21c07247ba49d8e89e67dfaeb3c41a4b8'
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
            --node-site-mode|--node-site-port|--node-inbound-port|--page-id|--page-operation|--panel-url|--panel-token-file|--version|--component|--directory|--compose-file|--container|--project-name|--domain|--subscription-urls|--subscription-port|--server-ip|--port|--proxy|--node-domain|--email|--tls-method|--cert-file|--key-file|--dns-credentials|--panel-ip|--backup|--source-url|--destination-url|--internal-squad|--quota-mode)
                (($#>=2)) && [[ -n $2 && $2 != --* ]] || die "Нужно значение после $1"
                case "$1" in
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
# DATA H4sIAAAAAAAC/+y9a3MjyXUgqs/1K2oohQHMgGi8QbJFjTls9gwtNtkm2TMac2huoapAlhpAwSiAbKrNCNvavfdGeOP6F+x9xP0D
# DATA ste61not6S90/6M9r3xVFUj2yBrHrtW2hgAqK/PkyZPnnScP9nf3Dk/2vvf7/NeEf/1ul/7CP/dvq9lutfvqN/m9P+h1v+c3v/cd
# DATA /Ftmi2AOQ37v3+e/zw9f+TvPn+8dH/mf7x3uHe8c+C9ffXawv+sfMGV4X8bzLEmnfqfub/p/EkyXwfzWbzfbPc/bTWe38+TyauFX
# DATA d2v0m38cT6bBTXAd+z+8Wixm2daTJ5fJ4mo5bITp5MlcPf2Rt3cdz2/TaewnmT+L55NksYgjf5H6IXTqB9PIj5JsMU+Gy0XsQ9th
# DATA sEgm+DCJMy8d+YsreHGchPE0i/0oDZeTeLqo+9DcD6+C6WUyvfSTBfY+TRd+MB6nN3HU8Dxf/r2cx8FkOI497/Qq9gkNo1E8T/3P
# DATA 42k8D8b+y+UQuvcPZAjoKPBH8ziuE4TjeLTQw4/SuZelo8VNMI8J9HRxFc/918k0ynyA9Sadv87qfjaLw2SUhADMrR/FWXI55SlD
# DATA J8t57IVpCpiAeQK2bwBpMMcYBptMltNkcesnU/4hgBGh02m8wH79LJ4Denw1foMnJKBlCJs/SbOFXwLgbB6EC4SHIfTxqYLLA7gW
# DATA wWtofhPc+rfpck6zj9IJQpxdqZ4I2TFBRp00fP+zW4B6upgH2aLu4YvlKOXxkukinkaMh0ugrQC+x/nxvMJ4gEOkCqRMQnEAk0kv
# DATA 58FkfR06miDgiFMkASC6IIFW2J1ZJsQLdpIsMn8JOMwAcV9dxYD5GBcqeI294isacXV8hK/OYyCUORIYDCVA1pHMvNkcpgYYOHpg
# DATA 0vbiG1gXV8ECZ+5d4f5BjFoYt3YDb4ICfH5V8DO/ZJKEHiZ+MsIugZ6yq1pdDwFzCOPkGl9ezkPsMgKimgNxTf3LeEE7h170bmBB
# DATA 4Kv1KraxVl0PD68DIn2ALWTosJMp0OmNR3DKAsFGQDh1d6+n6Y3uN0qxzwx7BvzimjyLr+Mx7ouMX8Eh7qMpGGURhwumIGJOmceb
# DATA 6QbIdhEDS/KrrZofZLDoC9rLzMLSqTMdhrLarsFMYLk9hJB4jmIIN1dJeOVfAhIzAn8cXwI4xMoyYpjCy+rW0nnQ5xPakFEyunXG
# DATA g6nuwF6GjRMhgx3C9EaAQEBjBOQ2jZDckF6JViuaMhJGi5dMYOLXMTLBDEgqwo0F7RfxfBowA9VbBUeVtajjKsP3W0/Rw00CtDkD
# DATA 3hjhSMBPAaIJkP11kIwDYJe0b5h7RNbKpF4yDdP5LAX2hRvgRTC9tRsUaBX/dxUHc9j8sA0ALV4MHSznwSV8HTJq5nG2HC9w4hZn
# DATA hM6/AFYOE6rnOKLZ2wB5hOvpssiszgvI3QKSbv0RzIrXCec4TJeLhhYHK+QAyyrE8WtaEl7LBAYUHNNkxvGCACdccwdBCNsiw02B
# DATA bRTbRtKEYX2cEEA2joOMJVfm2VtzkVpdNT5AZmlO4wgfWC+WOUQ8hMhsCdSMmCQ0xWZaNhhMDZkhB08A01IKlmcfWe5fLBPAMz3j
# DATA pUOyQTadE1sACRJuEilmYrGjkQuIwu98OZ0KbucKMx5tC34FmAR3DrCcYhsgWaBkWYYlS8/iutVhXbxAmgGOeL0SpHnuri6bvbim
# DATA ggQG3rsPeNzlUz8dRzB1EdGgT8CaoCyA9vevJ1IWjZxd8S7h5iCYgsyRKQBXOplhOz9LJrBUc/8yDcYZYQSoIslgpgAZvA0Mw0BC
# DATA qpJGtMxBwfTygNUr+X4VZB4TLG5gZPOrXxRmqfYOvEYj4iouQfijqDLanJA3MKEwQUkAL2Us+oE3JgtiY8iFkLlCDxZ/VbuPsR6y
# DATA JjVKUffDTveOX5z4O4fP/N2jw2f7p/tHhyee12z4z4DTTrljaLZ2anH5NRb2tMRqdh01vwc3IPamdeQ1YMcZiPs4APi12FkfJyD+
# DATA x8GNiLdgNqP9mVMhPaVC4i6Fxc7iSYLoWIa4sSZB9lpAj0GxJdZuQ47MWI9IXJy2oOA74jUg5ugpyH1/L4ChpAmrv1EEW5pWO/PX
# DATA QOStQas1eSHO1gj1a7hqoAKAGFojFjtESRQlsMOXMH9UEtL5ZTBNfhYohJ+m/hoLROiCIWMkKWNgNAdBh+paFMxIlccvM5AdaiHw
# DATA HQ/lHTD07Ip4BDEgFh1KwBvRXBfsAsZZgggzR74w9eI3oBXTe8xALDlEwAEqZMcGAri1wdcEJg9k2zhBBo+vIPD8aW0YsHBao4Ht
# DATA VqQBrIUgxefQAn9ZE0TEiYALom2qR5SFtjqnvj1RZOSxIBiY7Cy4BOFcxHFEBEIKF5sdIKJYLIhw8mzM3aTLccRKK2o9EbD5cAEk
# DATA C1Ao7SWBr+NEaQuwMCNcCdJNhNSQymF/YguzPrAJ6n78JoxhkeM3cbhciA2Hu9pDhgYaFJKPqE8sfkHlvg5YKcb1einzRCIAlWS8
# DATA BLaoOYXncIoqTTY1MthmG6ArKwmvVR8RNcz7WT9EwYm6A6guYPCQVk5LhXbVNbAUlJUZ2A3jsawDYOg6zhM67k/c6Ug7M2sCxBHi
# DATA KQ4uHXtI9tirMhzSuVbl2SxA5SsWu4rMO2VMBqQ6Qp/zdHl5BfxfY1REMq83yAAfTLdpNopFYrMSK4Y0ww94YUmmR7mOuXv6YRSA
# DATA DAdcz8bBLbCKnRlOap7gMh2QlnyYgtkJLEOpD/GbBRIHzZesBlm4gMebIj8hfENHk2QK34DErhOSzt4oDhbafELVXo8Muzuwxjak
# DATA NqXxtYrvLWCBWLALjoKFqBc0bZCvczRMb0nuKI7jV4VYhS7sScgLidh7ouJEygJTbDUjFsk4pT6oX8OOlSBhSK/AUEI5lICo5WXx
# DATA lSPEsO39Edp91jqAHM3IKghg2Ix4Jk0SVbaApAus84yYsZEvgQe7dVlns5oxDguD5iQzF+ppEseLjMcP5/B0zgpOq+GfsBq3C5qQ
# DATA SPM1S7NbY+PbYUMs8NGuBs4GjycObycnBm9He5PSNkgWKIaOhj+NiWtj92ZXTdPpuqhlqtPAYrYniwAZVuTvK3SZly0U8j5kJpzQ
# DATA M7AJkzAJxl6meohQiWCtLMAtmV6CjEP1WRpk/jCNYB+lRbtFD5QpLZ1xgNjH7R4uUYETk22CSBiD9b0EUwl11lgMwIxsN9gXZP0E
# DATA kxTaWRYYTpr4qbAV1YVan5PbDNf3IBnOA2RkaywNhRMbpUH2phYZIks9LUupFZIQKH3pOBaKrwY1RJ28HSkUTGFRgB/I2gB3C18H
# DATA l8zYXwQ/BRTsApNKp9q1x3qk8CKjAsAA1NyzmtPeHtZYeQcqn7JexexUmQEaYPG3ASIL4+KWBzIDfZpFWOAXyYaWi4EDDUK3FTmU
# DATA FYSIMiBIfhiTB/EA1LzjreWgWBOiwa2WwqBvAC4hVNgY2BQ1M2A4gMxQveRVX4P5H4+RsU8jYB4ZrTGjBlRRkHIKB8o6FGMNV4Ab
# DATA e9UEyeC2hlKYJ8gM26UKsMmyOmsiOHwyjudMh2zfgZ5qXITcDvaQ2bK814ABLMx72CdubqHP3RRYQzZL2RPCDMZhJInbI5GUoGg8
# DATA 9vLG5TSOldORVPdFjBiGzToeC+mMGEozU2LONQKLzFprMHJopbZbhyfK5E7YBA45W5CnhHyj6RiapWjTaU3B8WwsQC2LmczVjlPd
# DATA VjIvv1kJpTyR8fpsOZ9hz4s0ZYVbHqBNa9w46AxVHjlFucp1YimZgFWgCEQmm9wuyLgnPfOyuykZWpjVcyTPNwFuirpfto6eFviW
# DATA +qCNMn+UjEmPytIQ5XjEm1VWkx+Ku1PQzv7FOL+12GsdgfAStHGY4XYaTNgv4o2T6Wvk2cuhRo3SBbTuv9KLL06PuqeE6BB99otk
# DATA grpHFCwC5SURw5RMWCaFEVioYCktbuJ4ykj2bBgsjz1gN3PQy9ujDKtE4w4FaTVfeVLnmYde13msNoEfLBcpACzTY8urOLIznMfD
# DATA 3QeJu03zHE87MbNgomfVbvifBRlwpJfa+EBjcQesP/bq+pcUK4hK1CUiRvVYqWzoR0AZU/D4vlS+UEQzhSRgBtcpmydKc2N6WiD5
# DATA eZYfAptP4oXyq6jx4zdo3ySopQagKaADg/zRy+k4mSTYh+snVjylaN2JCQrmCejqvB7K/4U2kbEVySyV7+Q/tcAh2ceeXumJfVlT
# DATA 8jOSQEFBBx+yRbIAm4A1b9N5fn4gpqfpDZjAl+z8nnuyJujnDRIOBGhHMe6L62DMUjkzKB3eutYfLO/XYFKiSoy2TZ3QIlo/G68O
# DATA UJmJIYAJi+EXVqS13Wo7jEDcjVEjCmQlVOiOILxBP5OEidCPACRDYRwFjSjoucHFR5NpCstSJBjmvhiivAquxU85YWPN1V3Behgv
# DATA M1iGMdsVABfxceUPpegLcjrgh8mY+S22M/5PZMbiGLLoVIVp0AN4S7jwFP1neYMBt6M26ci1gtxqnrBOJnKBMeyJ+UcMS68bUQZJ
# DATA m6uldoo7QOYWzZOp+pNlhkIOV8bGBGwIWqBhfBWMR3XZ3fQT+xoSdNOyNxBBqdM2prnR1AERV8mQXBiAdtowypBnLxiHzjzqUU8j
# DATA jszEgXIy8Ucn5JPn9bpKZix44M0Gxr4V1sSlAb0zuYfJPFxOUO9Hjd4JbyOFoIYuPs/YoVBiLjBv9Fb6/gkpiOIkdaPYT9HTQiKk
# DATA 1fSQsCiqAAjHwFsWzG8BvE4DOQhGwvD9Vxw0YuP7mLfqc0TNDsin9V0C+BrVR+jzgDbiYeosG4pOII4hymXQbCMt5lFDGo1i9gDA
# DATA cFfTdJxeovgACzKgEIPBj+X2ge3uj5ZjkN5johiY7KXsC2mPhg8oXa2WEjpf7b88shjGYg52P/QZgfHK4Z52038GKJgM4fXW5mYf
# DATA d5On/N/kYlXEoYg0RncQoyh0kABDohRXc9DBYd5YxA1cDlnnKGuAaMCpSjQQlousByD6YQKSIz+IgzFfjea7bhEOzdivorXHaGc2
# DATA CkrqPEyIVIQRlwhFIl6Uzai2gh6a35osANmpl4XjIJnQTChAvxBBReLLN2kKgGDH2W6bVGQDsgYOP8dT5KpkMAIrR1XbVmhJF6nz
# DATA NidumsyZxmC3VgSZMjONzcKSeeXYhLXrNnyzX79UySS77DAzUkdWNpdtoiYlErmSOQoMCxQdP004moaIg22SLCflrHmazcCsT5fZ
# DATA mHJdPMtNBb9IjAdpOkYvvKTE3OvMeuq9juMZrhZ6r3Gz8u/MWLTS56pJqPBMbz30kiiF5FpHXCKx0zGYNFdKtzCegQlUMBlF9wAg
# DATA +AuGYKGGHH0D9Cif2lMC45I2DhhqJn6wwscFrVLlqXb93HoZOQUCB6GEDKSoaSqfUfwYpNpLgqqDp7YA9kOBf9h9s1mKzG5u3ICS
# DATA ZMDhJVRtRzHqvz2bzF4oTU50YMmjKqE323tfUEpFt8i7vbRVnYhW6Lwk3hXl8rLpVTGG2NMKgVrUbhmtStAqlsDLSPIzjODa8ryg
# DATA Rkoq+/NQrIeAqFvLdVhKioRmQZKXiMcG6IDdPxhavMbckwgzCjxv+K3GoAwwE6YsMxV4D9iSmCmf2wpuvIFSgcXKI0+QQJ9JtoJ5
# DATA gEaOQiou1tqKrbEGEwtrrGfinJRWSswf2NpcW7SWP60YrZMYH/oCoY3PMXoYDWg+zbI4U0HZwES1rJdvQAaztxsD5byx6/Yuy4lu
# DATA zQM8QBShDJgtEVNd8QOC1BYGYlxJvhXZknVYlstgHo0xgo7aMnq3r3A7oMOcHIFxlDc8OAI/TXP2k403ZWUahewmuGXvoeVVATUf
# DATA TJIEiYvlq9WhpExRFlYWA7DMlYXFR+yUimr+viXsroLsnmAIYIZ4Duu8HJ7wVoZFniIuxA/kiJ78KLbnmMid7SA1gr9yBJa0HG3Q
# DATA XgIyUUhrJq2cPOTszNOy3dV5mDoYxwpPEhWL4hlm9U0XKnDtOok4wQe06ymHbkjRcRKUHMWEuLLbAwA2JH+7ilgqpwurBxOMdqAU
# DATA 0H7zOhp2aJJimPg6HS8nkgeSLVLMOsJnTnhQiW8r3Dv11oLLSyRbjKMmClKDIpr8InMyl5SYFsg95d5kVYoEI2eRAACOopMW+q9I
# DATA qqI3jGGzI0rEN2Ui7GKcssmB4aApmVZly0cRc/h/NSPjcQyDJafgmY2HHMaW+CYaaeS76ggop29LwkNQL0QIPoelKZWAriujxJWr
# DATA 5RazGs/IrQx4LCK+t1J8WQG2CWxDoJt1zHAjblbqr8oNlldBmJamsRGHwGJEEO7qsXIObhLlYJyAzCC9ioJrV7cZ6aoszRde1XiM
# DATA racldFmrS5JPME10xpxX7nxL3rBeEfjRcs5eLdUzd+aFwJfSCUfuiT7JW6rS6YjLcMYnC+J/szkG3s0cLekp62Z1n3g462AgPUHI
# DATA 437ARMPbOJiz49RqknmWD0ipdzOWN0TIYLwTJiy1j5077Fgg8EHoY0gFIwdi7Cm5K8JWpb1ZmJHYIeWdekapvc9byjLZXgROPmAo
# DATA RLtZ6fKrl6+3x4j1H73edRWHJN0Z5O4k5Ui7eGlgG2XpVBI5OLisxkI7xo4cJJlnPE1aKSWKwSxbk0onivkqakZlt5BGGKD+J4o/
# DATA 61RCoxZndK05e3kkP8JaGJfOECo7S7EMMKVVqZxbMgYz5bJhF2wahkFG+hKbfRiexpgAGu/4G2lJnvLWWmnaUTnILPP0ZtC2midP
# DATA h0pV6w9ZY1mxcYdi69CW5HUQNHN8g7zeoFEA+quXaPnTVmHKYJzXWMFjbBl/r5sgWb6gYquw7z+4VQkq5kcemFbYGy3n7GPjlWYX
# DATA rdZgRAX3LRvyQXrKWZMWWiiZgoO1BAGF7mYlbC8r0GN9JZl4khPH21NnYAoZV9mzwvuZeBSi2HhDbmse57cyc8psVEuSk+UttuQh
# DATA m7RogCRTLwRGaXlTQeaD/qUFuzWzLKAeb1Si7SjhwJq3YgMcOwr9jcnEBYU2o1SR8lfrQusIoXIF2idjbFvOzUQHVq5YuonoZkih
# DATA HIfNHLsMNY945S5Ykv9sFsfz9UW6jn85EUqnvils0lmAZMrWNQfHYkqxYDyVxIbL4mWur2yOydXMGUfE0GU5JHarE45pF4iDQyxU
# DATA a5tHcooAdXHi+0AkllvOAgs1cnTb266BRGISOEXtUyjfNEjyThAaeJfehkMd0I3c+EKBielEHHRQo5WDsm2NALEkJmXNZcsJK/PU
# DATA RBkUOtPHW+CZL5ozLAWZpGj7xLBn7KQRzDaxZZ5qDHIumIA0rHspEis8Bws2UsGczEgpFUHVgV8SnGPuzZyBIB8tGuCwyTH7DxPm
# DATA UBmH91CjTKayrzhZUE2LWUl+snUvSpfDxWg55vx844uHhUnH14zlUXDNKfakEQTEHJ/ncoi09qDFCmUrWUlGaF7U/TUHUU4msbe4
# DATA nZG+lnIGGRCXTqUB4gzHAW9+BbvvGvkqirqUM3xxfnCfJ0EbI6AzbybpJNfUAyN4qaDkJYrfoHObpBMR84w95AA4HWaRky8IGGbZ
# DATA aJWuFO05yNViWX2QOY7bbxFQ5o1nZDkK42iJGi2jCj2segAGdzmlrkmG4y8wnqTqkWeetACkMXL7sbMpluQ96xQPzcXz1vY5d4XN
# DATA 0H3iTfRZpcjYG8zKj5vApNIoqyNlhHGE7vI65gBcpXPJ0PZfx7eMXGZ1ielbsVZCsCTPkKnOOTPF0w9ZiQ9B5aM5ACL38UqO1tCh
# DATA smy1/hU74KG3xcuWmKoX54WJBN/ARl8iK1hOiYOKauqc3GCG5SkOiSfaUk7dg+XC4AMzAXbF8Lw4PYVCfcOYjGk3SoJ0M8RUDzyo
# DATA Bau3P3ICS9MCk7Qdl4rZi7WFg3Ggy85LGclhPDbBbNya7BhLGw/DJVpLmafDeiz6AjWUtQsld2Jk+xaxS0OXnrOWmNwh+cSWXNMq
# DATA mmQYzeLFEg+5Kr3SY6uVkjaqpY5CF8KMVEL4BlrszyTRdoXGx/N2vcEKqeSgG8a23enJabRVOwwPvC4X6miZ8QFrbwr5TbwET+yy
# DATA UMO1nqYcErV0O3h7QQdVOViCStytvbNyFCmHpFh7djBOqWs64cp2UXpEddIhy43joxc1Sd2xobcsnlUTL2aoBV6uC7XD7O6UYY2a
# DATA ISVhq6gKkfNyhi5ZzhKQuAjtV7NlNBbm1kT0iUGhqroQkldAjqbl5KFOUURo8yXwlIYvCnwUk1Pi5iqeFgI0yKTi8UinFKggX4R8
# DATA LOakIJJT5nicpaWpgQCW6yQdIzp4cssxp6whs16kIWb3jUQMm6yyIJynWWZ3RMkK9+wD5ggrV1lpveT0smOBpRuHT+HQy9pHoY7U
# DATA eeqYPuCNzipLdMHP5cuuTpb18qljYnfS6Mr6A/ZMvBBVQNBGbhBgQBPIMaKI5RSDCxSIRiegpAKI9QS4GjT8HRPXOI3ZYblm/WZC
# DATA BXjoaR7b6SdI3ZInXHAf6ojL8FblpPAJAj7SRrl205gPuMxjJexMYKrhlQMhJ8ckdiNRGpVCwFEkFUAg1RG4AGdP8FEuzJViextU
# DATA ZT46Yidp204lJy/BU4KUQzbsZyuc78G8LjKkg1LYPfYqq+xsO3tURzPZ/YZPZO+R+m4iM55i5Kk6n8t9c9CnBAuqIsAlKiKctO8V
# DATA UiUwgYwFj5p2+QxWpIawK6ksSQQnEcgBdT54AWxzkkriSPkgKsYbLOQ4DrI3ctFgkJuR5pHDv7qCRgR1yq9l8lUlEpPeCBjwHhpt
# DATA YDmhNc4Wx42aYC7DuVEzSXLkJPFWgI8cQphhXeKr4uEgG8mN9riZZxSGU6UJyONamgVhRqPspQUuIZ29UKlfquRFiueGFLe1iZsP
# DATA mUgSGOZ0AJwl4Ok1pMx4UZWNCDIQXdExX0o2o4VTfdfuZRJuug494sDCM0nKIctRJSJgzAjjSHQoJFFKg/YrqRTesnB/5rd6xDxb
# DATA /fzYT1GfREf/sT5GSabJ/FoLKnNQxXIBc/hKp32AhUboAWrXrv1MK/wm326ufICFeKUn8UoV0WQ0c4gLdYuADelkwRCHNdziOsML
# DATA 6EHbVI6EhRW7TKbaaDWUCZ2Yk6P8rMyEIZtNwz/E86Pz18QvPQsbN3QELbO8fNqpwgAEuoQJgx/VYAFkMeUsGjspSPzhwip/BNV/
# DATA CSb8gYPf6dzCuLa1FZA8QFzDBLkxIw0DGEhEuYyxOZgkOB3O0BMzgtz1E6AhfMoj101TNg9FnyNcZDzeyKYgDApPpk6qmIGcsgNs
# DATA 0IOFZxB862Y3II/NnOn5VXUqNLdUwBNrvJO4Ig15DPAowXIiYpfAsLTtnBqJGgPl85k2IvU4Caa0T30oFhSblPKvPRZOpROWrHbm
# DATA T7lUrHyGBUladCSARoYcaU0c4p5OZSSlBGcsewptfRVx0VmjxrWtRKKbxhZRHpuYKEomJ5wizjZKINu8LN3GEqsrM7cCNu2Uigg6
# DATA Y3EihtWKfGTUx3RGCjWKQv0nDZ+nO/StDkkfKCtCwEcxnHxeW2Gz5HaZSDBk6M7cClXbpz6talVuvJpStkqgRjuLsq+zJWyxa0lY
# DATA WQW/8ScQsKyapiVul1W6PM3WI5WaZLpOJ9MpWfbRmzqlUAACCP/iACiQrVvbgDeDvE6GnhATRutCoievEHRwlFvRyncKCUjW3knz
# DATA u6mulCBJtZaQqjkYaiX7KD1Jl8ZADrdQKrNR2596bK0jedqRBpmsWPwgCgDajQaZE8mU/QYmC4LOTekzDqY+UG7N5LgxjY9iLQPV
# DATA V1NQMbUN7VdUKGEewJiskw5sjOvRPBmNq6Vdp4lYhJQX5p4HWgj4sV1eyS7hoXa6HeMnFrKw6owUj+7E7AdB91MAz2ZXDrtqoYPi
# DATA CyslilRtzOjjMmBkJJeqdAvRW+eeLtXGcU3LlZxX2Hzy45AXgA3VmqeVRg7SiueWnF5gWIxL9T7nDBDY7KNk6qLQPYhizqsivQZ8
# DATA xL1ucoykc086x8JFtK1x44wkVshtDTqACVFxAksnIc8vlinjQ639ph+RljJayDrQCQIhzxdghaaEc+fIzKNQ6FkotGZUmJB6g+aR
# DATA xJk1E+/hmUhFp4S1gVEyx/yPZBJrw8EINOEw0PVKelFnPlnDrBmby8uDa1Llw6WE/EyvGrsdG7ue5EsAODNt4jJQ6H4zfAGfFXaX
# DATA 62zRjjezHxFfenuhc1bqRKDGRBaURoRKg9AD0DRxLsV9zHLWhob6Ip+ZHjuSVIaFvdDW+tetI1r+X4CuRBZkqutWYOUgp1yhivwb
# DATA DdDJxUX9xfM2G+Sdm9ExG8xrFFVTAntf8NkrJ8Vf5Q7aYYsg5BIOuTNRIBg57UMBiZYBnkazk0SsM3o70xC4ZcAJybp+RzHljjzt
# DATA pA5LfCBQoSeASWXHPxCI9iywBB4sIkSsXVOGMu4DjSPreDEqExTFdMrg2Gm2yJ95L7qJtmVyg7Onc4cFYzknzBYfF4Cxdr0wcTlV
# DATA VrIIbu0udJjpmi98RI6RXDgGycQmeoSIKYODwo7n8jeU7Ipa8Y6SdtJAFOdn6Q3QMhYMBSJTqSXwCpVI0vxmxbkgN9rhyFPFnTJL
# DATA lS3aiNpoqMtR0brWD9gXLCvChUdozGzJIQLStRykuvsAXcJSRAVDBuqIDp8dTAhjw1v3NI6lL5oqVztTfw19bGgemajMGmv2dpxG
# DATA R4J4FD5MyGWX7LJQrG6ZyCpulDHZWDHnm4IxqNpQfhcrGsU+JvH8kmnGrjlFXG3VRuWsaM7gVXlQU784O0np5tANIRoEhT1XZL3W
# DATA AtuMg3M+MDVVN8BsGdychourXHqOgXD4+7aCh9jiiE76seOEAo9gLQBrjtgQWI4jjzxlRr3CUGWSLin1njUsUJXHS4RLTtPlzwqs
# DATA DJ/ZU9DEugImVGC8/HNKYl/kqo3K4TQt3uPRCBOcckqy2NPIcUoMpUxFw+Q4nI5H5g6Mo5CnU9mr1GanYIGYfp49vtmtWA94nt4G
# DATA Y4lfpVZ6Gp81MrB4Dx5cN3qFnjHWQMDdjSldTK1uAi2Fe9b5uB6vPmVv0ncKxuDBxyW6QTCodalMdc9Sy6WxYdSRiVDUWRoBS+Es
# DATA lrrJFKSqx8GYNyJiZq49V3ZpMhzHpCHR2YlWq+G/pLEzVfRsyh7CdL6mkmByCiLuJu1tpTz4soMwrmC2SqM51UvUYxiJDl2xsPFk
# DATA py0zUxnPJP+rhAEBE/ahDbUu/yanJpx2pjSLjXCJHSFfc372QNjEkVUdYmw7l3XHdZM+NMY4FhasFLUG1gVFJyv16te6kg9Yvo0C
# DATA ddZak3INqtsUVVt9XNkrJhWP8mRBjj8+wyvBqjxK6h56XUT9U5FinupKkCgcRGWocqqR2vVlh05Lxua97NluU5qQKS5Sl2VMx2um
# DATA 7JhJc1BOUk+WKFOnsumAFRXfQaSxSy6jJjqV1HEHUBDAkZl7fAjRwGwpXQF5LvSxeKy6Nx9HWN9Jc5t1ruDiGNYWw3dJcAUFokLh
# DATA cakFyo/ClZQNzhnhtLt5a5siJFwt4R41hEeXaa8iC3RTqVOKmCPNrIPqRCsRRb6lNXeKzB6mt8oF4kHTWHxPHApPFuxbkzNUGKhP
# DATA xVDhAqeUCUQlHsiKpVBmVRc+m6qeC5ov1Uo37/B41/E04MOHVKZ8KR57bmFXPqwhk0n9NVrlNUndzjlGONGANQpdnlHqg3Om94rZ
# DATA FualCMM+ak39FrONcuoqFvYAmOm825j17WkBUD6RtTI91FYRVOkCN22X3PmerpBNtaExd1Gd3I0ePIKj88QDz5Ts1YPkjgdowUwR
# DATA f7e4LzsSvIUOcaLj00o/VYehVswV5oAexdQkJptkUQzSXbKREWOdSrZHKDVEUGSV+abTHS45sDGcZLavRVfQqnb0CHWbF3mP4EXF
# DATA sD6F9COhE9oSY9tE0vaPSa3Hqns/zhOLKp+n/S8SHdHlYqSyKIoEZernSMuXyhxW0rBXcF1LwU3WuZRnhQHjQ3Jl5wg9902WO9o4
# DATA tVMvEjy6CAKGk6hZU1GBS086MGfMxL+CuiuTwziJr2OTFEF7DgtQz7NlwIlRrCbDJKexU6ITherYTW3DABQvM/M167S6bQqTpYZZ
# DATA nEtlW0ELsXnrBSOZjlpT9K+MB5E6YOfnxpmYqmUlXbRapovdqHxbDZsSFZ4OVOBcVc052zIq2M7TEhqhBHwGH6WB46JmQhbnDhaL
# DATA MmdB3CFY3SNHN8WT9fF7UlF38miBgdawLsY8IWGSzm/pBGhZoTaOvnHJOZiblcnDmdl1XYcky5srrEtnpsSUqQjAGoExbHKpQlpn
# DATA MelAbkroaqvDqnRkSrzmDWLx2JDKaoxeFEmGOHVoz0pqlAifJzGkIeqNkshpjvyRP0zdu8AAmgQQEoCz4HZCOUepCRfICE7dBCmZ
# DATA onyoUqrulhPjhaXkKsXZ4+X7Zp2sropoazZtnKvMRZQ/rrA3lHO1Tsd9bPLJM3uqkFnkCe6pNYed6URWSaWpch5bEssNEGKdp5mq
# DATA DVxjwYFBBoCDjv9xouU0Khtab1DJM89E6VDHkTPFDynmWrJ9JVCCsMXkEYi4KoEQqGFqnj5k6eIE69oL3daNX7294b8I5rBa7WZz
# DATA wNk+V7q0qeXc0+ckqLDZfKljd2I8W8kzZA5jGmJC9QHFmDQ3XYy0S8apZi3pI8DXtGI8jN38Re1Yt+OXappUaqnVbviHqX+yBO2C
# DATA GsJaH1FlsYr/nK/5YK0tV3eOnRGRVMzyq8oepLJqS6pYwqEKS2c0gNZUNhmmMERJqFPi1RBlwbRbVWkNkIhCFsfVPqDV7+owAnp8
# DATA bBbjCvYslQP86gBXlkyW40UwjblQDmfMFSpFOQ4AVc5DnctCnwRN3bwmYqXgebcdPQIgcPeACnbknUKKGyJqyVFnotzq/BpF0UnD
# DATA BQsey34oy40UH32QUes51m6Ft4C1TCxR7+USIuV8iFzNxD4/jbZhSlpf6lye4GBJm9wUShjNcftyjqTKGHMPbZkaO61OA+/4SmF+
# DATA h6Jj75tK408x19ponauvUfm2OXqCd5OG6GmkEHUUToxwGoNVNZytW32TjqfLaVjV7+c0wbE5i1oslk7ZfzSkjOTpM5lkq1nl12t0
# DATA ooMe8kVeVvxmVTFNLcDUPFi5U55u59qR0mOmDx+TNhYUqXu6kLU+BB+AjNLlu+RUaaCLWuhT3HJ9kRRqKQWGGbFdx3b1uXeJvtoH
# DATA 2/XFG5518caKK1JUQpF1HVHkaN6c8aE8DtrX8G0JUhs6+YI009ciLbFMSSFGpjQl5x4OyWMuvWdk1Q0/fMaQzQbPFEUxZXDt6he5
# DATA myzkyFR5jjplf9jnN5zyH5QTps9VFgu2qMRrM1d96IKKFujiLaSh07lfO3dK7alHoAB5Uhd5EqwQvPylc9GV43DDuaI8BXKTQgfP
# DATA wZKL5KxYYMquzaUvuazLutlG/HiPuXuJ2TnGBhFl8JdqOgIK7O48QgD6D6RKIRaOmiXzRB/HlvRVc0kRYhaB5axSfCHCY0N4jZUn
# DATA N7TQEECzoGlMRGcD+Taf6pClojBAD5eBJd0U6WIJ80fyUC2mS6ymqNMFPX2OQNJ/lbGh88X5BffIXjnCvBzC1mT344EX409nrUlU
# DATA r4XZbwQNZ88Te7J8iCuuDBKXjkrGU4B6GtC5qkznQOA7Fy4t8jTkGRoqJlVqy5DRdWvdrcTDK4PiQXIyGYjhVapCYKovcnNqML0y
# DATA MC1SZ13SBrOwmEA7b275Pj54Eqm77kZLLNbk5e+Se3gvYE9ybKOui6m8ua1k4rpzEwjdcL1BmZ1GZEWClJrFeKHe1RvKw2TUlwNa
# DATA WqXg65kgYi/FP2fn3FJNKMne9uwzH1apdhCo9huWeppT0vGUuiTEpyU5U6SPyt10SvrTpNRFk0TioDM75Insr9fQhwOYpL6S4wHI
# DATA 9L7YO97z90/8wyP/q53j453D06/950fHPjzwXx4ffX6886Lunx7R972fnO4dnvov945f7J+e7j3zP/va23n58mB/d+ezgz3/YOcr
# DATA vBfqJ7t7L0/9r77YO/SPsPuv9k/2/JPTHXxh/9D/6nj/dP/wc+pw9+jl18f7n39x6n1xdPBs75iu33oCo9OL/sud49P9vROE48v9
# DATA Z3s2TP7azgmAveZ/tX/6xdGrUw28d/QcOvna//H+4bO6v7dPHe395OXx3skJAAB9778AiPfg4f7h7sGrZwBL3f8Mejg8OvUP9mFm
# DATA 0Oz0qI6oUW1V7wgM9P9i73j3C/i689n+wT7gC+8Me75/eghDEO52GPLdVwc7x97LV8cvj072UJgiCqETQPjx/smPfZiBIPZPX+3o
# DATA jgC70MeLncPdPRzLmrMHy4TT9b8+eoXSAuZ98MxBCiJqz3+293xv93T/y706toRhTl692BN8n5xCp97OwYF/uLcL8O4cf+2f7B1/
# DATA ub9LeDjee7mzf4xY2j06PsZejg6RhPoNPnqgA2oHKt8d2cUhUs/el0gbrw4PEAvHe3/6CuaJFOK7FIJ973x+vEdItujB+2ofgMKV
# DATA 00ThM1HU6RV4YIjiayCvI//F0bP957gkQjS7R4df7n194tkYARwbct357AiR8hkAsk/wAASIIVyzZzsvdj7fO7GoAsf05NLjun/y
# DATA cm93Hz/Ac6BFWPwDRtPhCcwVlxV+kE78HVhf7AEJk9fQewWbAInvUBENjI2/2cBWzdhFgvQPjk6Q+rxnO6c7PkEMfz/bw9bHe4eA
# DATA KNpfO7u7r45hr2ELfAOgOXkFu2//kFcD50vbe//4mac2GNHs8539g1fHeaLDkY8AhdglEZ+1EtzipFb3cPH9/ecw1O4Xsmy+s42/
# DATA 9r+ApfhsD5rtPPtyn7aijANA7gtOYHbUg+ARKW/QYAMSL//Q1HdSOKJkpFbksDp9EgqbjR0SNkc2dOEWztMWJ8QwFu1nnGJBCz68
# DATA xFWVJTdeOC8fkOMEcw+Vw/iGraAlmXtk3LB2LD0FN+rwENYpHad85hcPN72h2yAyD/2mwywdY5UEKhrNygeq3Ml1MrZgL/HLOWav
# DATA SkZ2zoSZwyguIsyx9ixXiEynRGBVBxDzbmFbID9aztIbFL/ga6l2CAOc+XeqTh18jVLsENRR6T/T4Ue5mkhujpzZdzBwJW26cUrC
# DATA awLkJR1azUAUpxK8W2a5Q8J1CatlCy4mhRmeVxSO0ZnCElJNFp57JS0rObG6l5wvxrCuXbZun9bBycycRTiVVMI6ZtwH4ks2eqk6
# DATA Faf1epU6uk8mURaMcGIIr357oi8WXcgRHMo4s05f8KUzGK9UNdjHtx4pU+IMt4o/uvWWqSfqIrsiZxAp1aqIHtk4a6G5unLMRixe
# DATA eThLybfBTipV8Gi01EVtcTYj1DYBJz9ERNK7qlyeNfdKRifJpNvhPIlHGHgLdO0oia00fpS7aP6HWNzvR77/Q3o9Vacwf4QmXpKp
# DATA 7gkOe4G39C3TzrImC9+5ldlLFuXB58doukH2eEW8rkySgsFv8m3mXtU9KlwrWiiN4rzN9PRNW1cYiFKHtJTZCdsHVo7NdaVoIf9X
# DATA ytZT+35i7kc5yQ27GXl5fQlwuUpd8o26dBLHjzN+5A57ujcdTV2VFWhTrk5vdxMtH+zbc+q/GSyyMQcUjVkxsf/Dq8Vilm09eXJz
# DATA c9O4nC4b6fzyicoEevIjOsKXkSHgVKDBWi/MHSlIwteSU8F+dAnP0ymW9MILToIZJjXB3HR+hlWPMQzMRYsMKd92fI+b0tN3Ot4a
# DATA RHEpb/e6+WShpCPLEF06hm/15uxMVfG+3As+tykP+oiHKtTBVI53zJh7ndhVrSoUB/6ausqLXGZ8Ti4OokzDwDFGYOLXsaejYJFO
# DATA EOcreLig/G1mecOlvKcUmKObnrQpR5KXFAy1E4bxYiFZT+a8rrqA6SnRgD5+0FGGpQ6w5ovMfZ1DOqKRMBUD4tJbzCwRT7a5KUHd
# DATA 7xfPa5RVh7YfbE2+fo0ikFgNiquhKW5odKE1k05hXe1u3QjyXOc2uPSJRO9cL8maDP4gFqfeR3QDNGDCe3A3fO8P//4n+Qc2yP7u
# DATA XmMS/R7HaMK/frdLf+Ff/m+r22mpz/L7oN0dfM9vfhcIWKJyBUP+O13/7/s7C+fydH0Uy/OO48k0wFiQnNDmo85cRJTdoeN0sQDe
# DATA i9nc03gs58AilNOU7UY+cOrlhrTLaSQ1roiXrHcazXUMYz41Z12UlsyX5lLJCVZh5MoOudmyQYGLn8xZXL3WlbNQVC1nkqr2AoZo
# DATA N5ra2yen1LB/fh/GRtUUlMEFXQZk+khvpmCZ7+4doqLyGShsmIOdjsPj012lfhNKVJn78NaU5FNAcxANYDY5LV+dPn958FSCIJQV
# DATA CZIfEPdkqu7AvJyLK/kUk1DWOQlFj4JmG90koa6mort8ENNq0UD2vFLzZ0C3fMWsL0FzWA4bgMQnc7UmT4ZB+Bo6r9/fChYSE3of
# DATA ajalwqIlTX5yenDyBJdrHdEhsRg830O3YpJzF0vwM9nIoZt7R7LfXad3qxuNZqNZU6hWBNYA+yoz9EWLurtnlV9wSI5pIEbT5d/J
# DATA /sd7KTGBqhH+NPu34f/tZm8wcPl/q9lu9/7A/7+Lf08+9o+XVBJQFTcHq5JTKIg1gb1HtWSP+AJKXf/jKgATN8Oiv+i7CvF4Fx0w
# DATA ANb68ROvgn4ZPpdVeUoJyQt/lPnbSk+uVpBVbI2ySk09Due3M9A+8034Z9Psrf9ynmSTYHfM9Vn4m39nv/gETOUnoMYSP7oAqx4L
# DATA 5z354xk1fRLSm6bHaAjvVqs1f/tH/lvPh3+Y3Muf8B+3khvSoekhRe6qPPCnDe5Vws6fNrj3Txtg3iSLaqVRqZ01z/1PP/WbNf9H
# DATA 2/7A/9TqGv8FUTADy2OL3GDVR85BXlqfXVZqDYbk5WWt6vYswIvr8GSBaWtblCIMNkEjnl430MP82c7J3sWr4wMsjvFmy2/X7+nj
# DATA FCyNdLl4gZf2ZVt+q3kB2xUMDRCPuUcdfuT0dVeH1QOzJp4EPFsYtboKnFoji9HqexmgAdYAA6pa4XcrNURnhd19Ff+uZka587eI
# DATA /dNN7E/1z+LQnJIb0hBPVda0xi3vwM5egJJhkIhm9Q29tjefp/Nq5ZkwSzmVN1YlcrEaA17LSFvn1rfnUVG9e3e1KtIcFUjevYrD
# DATA 19Sp5CtnPIT/9s578oSVEyWyOAAe+Sd/emAq84FxTwUmAs4lpaMglOPMlXJ0bRPoTIVYWW2Bl9I56E9HVHCPHJhgzmMt4wQvwqHS
# DATA zry3SSCa+vJPsS88HRPh/bW+XKnlTxJRWTjTitOgwS6Xq210oZSG7DYzzAv1Jm4qRnql3Wz3m5utVrvZAfK5iOfBRTBGu/5C51Re
# DATA UCn5ypa1TgILITVbTrb8Smuz2YmC4UY7GHVG7Va/3Wk3u52N3qA56PSa7Y3+aDBotTbCjX443Bh2oo1W3Azbm71gMwri5mBYMTSl
# DATA Ts6q3oG4zxyyrnTDaNAeRaN4EMW9Jrwe9KLNuB+GQau90Q432v2NURj0h8Fgc9DdCJtDgKjXacabg04Y9aJBxd0mlXAU9HqDsD8c
# DATA bo7ibjQKNzfbUdCJBhutVmvUGgStzajfikYdnEx7tNHp9AZtmM3GqB20g6Bn9XfOH+/q3p1idxnf2r6NRxOWMTK9Pzk5OmxkxB6A
# DATA eqv0e92vXtT9a2KKi9tZjGUz/O3tbb8yRLJcVICPXTcWKXMVYJ5b0FgNgfRjD8A8vBGS9/4LeAhb+Spo9/rAvLjea5Wh4rFrtUaU
# DATA XMYZ7Pir+A1uIFWeWd27F0cHMWiBmYJ1FixwwLPzugqgA0Xd1YREkpHPDf0/+iM9GYYNJ8TVdCv48KOdOeiojSSjvwINPZAOqKTF
# DATA NMQegBfIs8+W6C+Ct/iDmoRDoAjUWQ7RCHXtHEC9IpQIHDXDt9CjU2WUYvFSTAumNg0sya2HKcXJGTQBbJw1Gg0cpu7zdwZEM7x4
# DATA nMWPAo7H4teEm/JrT707a3XGoBoorBncOyj/CFHOw1T8v/xL/yP6uUERjuwrUPWrlTew7VtbFZiaDEVNeHDGxvAWy+ds+4J5NBeq
# DATA 0g8aQtU+mAEVZNT9rsKnQeN2jh4nQajpse6Ix52XLy9O9naP9041nRJw69ANTmD9ulXRtOqMEyYzdOznhnoW8+/JdbUSxNk6jLh+
# DATA GU4qtDp1nlUDLJuAqA8Ea6tdU93SiyATFztgtZwGl9Vc61a77rc3au4aCX4w/StYVM+kE5lKrgN8ua7GoWJF1dp5zWzxynIx2kBs
# DATA 3nlBdjsNdc10P5sGs+wqXVQVq1SLz7ignY2rBZYbRnSGjR/8xTKe3x4HN6+mGPaqrp3sHeztnnLLCwrqPD8+emF7Ki9Y9jeks68o
# DATA q4Xb85NtpRCsOQvBRRK3SYifgA7B7zcmway6IN7WMIMq5FnbboZ3mQPtnp1VgmiSTGGpiAIu+BvusIo2Si9gdTCHLtOtSh6dn9uM
# DATA AbcHgdiAbVbF0UBbJK6S+7V1XqtZ+ojRH6oVgHQ0lkuMMYYd3grKjeph8IEOAyNv8R+52UGmVZII4YaFnC8ulkv+hg8REvy8mKc/
# DATA DaYXqqQy/nSNoWfdGD7qh+dGBhGqcICyTtULF8hm8Id5Oo7tt3F2yeUFbEsqFweK4xLPKBcxK094xjYJWBLB/jmZDjESB1vJpo8i
# DATA CZyFwRTjNHRHSBKPo+zc4sQxnmsGpkt4dXg+vy0Lsu3rXljoMP2AELXJCYQof634n5gXnua6VPLbUIhuCpqxNdCW1YThwOcCEaPr
# DATA qUOJH1HXMAn6loOY6KSyiggpMQ5rJ3Krpzpz+KmQn4HfnI65hyVUhCWEeFHj9H6ewG1KmcIPWpStYPb49g/a/tExZq98hmHKCPnc
# DATA xSzNKH2PCJK5SJ3fqeWRr8ba1nrhpw1DIeefamBAtDG14Cc9ZWI8IelEDWtqNWC4eG0YP/oItgqx6OgiWCBMLD3o23lDFSmohrWa
# DATA u3wydAPT+aUnMzD9GOCPgT0yrS309NC6aiVDMID2hUOlBUwlEa6vO35x5kJbyBmQOPkT7gP4k+8xo6BpjP2iXqO27BnWK4TvMv3z
# DATA 2nn+RZjYvfLnPwix/eCtGsKsU2Wt8kn4Cfy31vhpCtpNpV6p3TEprv3gLRHJ3dp/KMxeTChkOoptfHa7H1lcKMdmEPnAVhDUWs5D
# DATA ULIZc1yxkn9F72hXoYXeG/zqpw3hfzAaamHmiX7QAKvvEpTAFZQhY1M1n2mq2Glm668l05RmMtX8kGXT0FORRiCwLxFki38Th7Me
# DATA P0jNGORdcoQ61iDBi2XA0/jWWEEUOWMV37jzVn+zUCEbCbWLMtnqSNOatcEpRSu9qeF/zvgn1NNZ+bZ+y0HGFHkm2hy2S6Jzo+EX
# DATA KZ+6Oq/lujG0XNaVSEVUyPeUZCx0fBaW+Jhc+i5RnFApYpCoCUov9KWhyydvAQnkziDORO7ylpnh4LhDhZPUtZOTJ71lTf7OZb2l
# DATA wqDmqBGk4rOtUKZAqB6s9xs8fK2MH8hqolVHJhV3XLZ/hNgobw35j14PW+SUbzvxfI6j5yzJjNCzoWSkwMwRGETA+dPVm1h3po07
# DATA PJdb/oI0yCHK9MAypXrGBi7Zf+fksDCWpkWtGjr4D75xXrZzS36jjcfYe5gjiozEoIpGeV5SwufKFv8k3Ypg8Sv5zXaXo9i7cgM8
# DATA Z49hiLZqG+DKpg3ml9dnbd4/AG0MZsPl1aJS1FontmvuQR1NtyaJDjakeMpw30wpE+4CS35wJasLDDjCdxGhF+zQvjAjrlWKwtS4
# DATA JtHJUyo/E7yKEMtT6Y7Ktg22ariA1Iyq6hWJn3UU6r3hzvNpofOPnvz5WbD+s531P2uub16cf/KDJw1MViUDj6UsdWMhZRUl4eFF
# DATA zLBaWP7VvGwyI45guPO3/e6dGpCGUatQWz0I39hiPLihcaACdRLYZTgRb5sJUUhQwqD+iXofad383sj+Ylwp61H5c0ZZI34Di52d
# DATA AEGzCwp4PPyKZXueg7Zh/Z43YCybawRdUZefFtwX0BPVNK8++Wb+zfTJJWy6bwqoVSxTHL6qNwDljD7UYQj8n9WZdDXHzs5Z1HEJ
# DATA rEf6P6V1zvOJszw7L1l3DZsxB/KLvkoSYCWeqRHVIEiObqbVMrd8nUkApl329AwfnpcugwaTx0LKLwGYHjZyvnveJ/yo4Hn/kMm6
# DATA 8Rub7pdTBsu+MUKTqCF9/5PSPslD/9RHfKAx5OwYByok/ac6TOI2rGp0nLXOccYVUqVFPS2IgaIaSQqdXpTGbAk0VbJf70o0Hmbn
# DATA 2meXsyGtTpWwU9IjW0TpctHAwvjA+79E3kGHqy3uXGQlGU/Y6tYIO8SQu/nKh9JRNy2y6F6vODIviyt7pbBT03VkXeloEojIYykH
# DATA 7EPjcSCwRLLqOqzbHHaZBfMsruY5XBO9ZMSvLOTkQNLO1ofQ91KrJeScqcuFnuRywjRxDCDyVdFkS1JqjNK6dTJAYeq8t3KiRF9l
# DATA x35iVkQaFFatxhTfRF2TUJGO4wb9JA+syIoVHP3UN6tPJCWhVqYqerMxwQzXyxidBivaSlhWR1SNX79ukSzT6K06Nqx9quIyxhIt
# DATA VpoDVqPBsjQNdHbpoMGbZLGLqVzbfuspaJMNKfov2QWoQ2HGLsfTq7i4//b5PzEmJGPs+GIc3CLZzG6/2/yfbrvX6uXyf9qtZucP
# DATA +T/fSf7nR0+W2fzJMJk+iafX/ux2cZVOO97a2toLvpHO53K0hk74JH5mGTSkEKqDImTU4L55loavsXYS7MkGdOepMqLzS2J66jsm
# DATA s6vPo+kEeYX6+tMMb9Hmz2nGJU1wrHEyVEVJX8JX1WSu+8xuM/URKy+oz+hc9Dx4SDFR0CaAHy6Q2QIXrGJP1YsL5IEXF6gn0tXa
# DATA wL4AWtTManoYvPNjIhVW7DxEY8T4em6TSYBZk5S4msUXyJw8z4tirKM7m8WRimCDVYu5VDe1LWW1JZliiaoNQCmPLSsQQcf3gB1y
# DATA 4BfEdhV/hB5rta1z7EoFu331O10tasVdce30S6Szg+giNk+tVoM0Bp5ZhOlM5ob6kDU1viId7bREYrrnq3vGilTFnt+C7Nry7+me
# DATA vCzOGA38llVrju3M0+KFUGuDNJFV2SNZWBAdREJybURxPMMP0rqmY0bqDrREmeeSuMQ/Y2DwLUgFGh1AMtOTBmcV2INEghV0RMk8
# DATA Sx7a0wb0mSdUQESAoAU8O3es5Wt0bcVWKwaQf0b4zs4tsEpWhxrK8pCo5F+4G4z0A+Vwmsg0qmwVlFZufVbhbCR7lvkn1hSdGZBu
# DATA DvBXxQlO0dYsBtG8yCo52L/vnwgu6AZ7rPIlZw452SLjgsCYUUSMJXsqmdVRHI6DuVXGYRiP05tGwZWrskIcbLIXpIDI+0mdcFnR
# DATA a0iPtkotEN7mlTyVOD/nkTei8tLpcvYYzDkTs8iYOlhFwf8as/u2MzNEbW86Q9PlED9E2JUoxiVlgC0ijzBHfX6RzhbStzsRRcd2
# DATA s/Mz1VkJwa9omJ+o4/UT1gV6N4gmUFrVvBLy0orYqUJnJIOxs8qMlnt9HfRR/vAXyyQGg0gyVWuKFVMGX5QVmfq5DQaK5sY4DSLk
# DATA mCWjAV7xaAKM9DF0BsKTAdbbMKqy11byicku4VxBDGrh3tw+TKexTGskxfCppZyIl9cMnOMANilPXx7yeu0SsQsZ0C8H1LJCYvDt
# DATA nU0QLgh8HIYa84sw1QZPsiFSoyFNmeu5r2/lnUrkZTTWGjIcdGg+boQGnhQEveoiSua4gJVaMYrif/zIviR+yMFD6kwlLNfL+z2b
# DATA YNFj7pcPbPJrcjR3ScXO85h/gb+LUDk/t/EcTCW7Tmkl7NNbpZbwU9FLHPZESMztQCHR07kgW74/B6tNyXw0pS+UVK6iVlbXt5py
# DATA IvN2a6Mp/UZgmtNBoW2u4zVJYY+g6ltFmKQ9tby5ojP5+UY/1F1Y3MfZqQzBqj0Km4iAc/cqERXVDEW95EM3JLE/gCGvJMDPqEFK
# DATA x0TV+J3H52Mz43E1FErASgP2zjpeTqfkwWIrekWrL+JgvLiyf8EmS9yRKJ4O6XKfyhW1upUVD4m+BKrS9ZaHeTL7FkBQSsJUjf/Q
# DATA 8MN5HLw2OeO4+NkYFMRqWxh3gGVhv0SKFXfJ7s7h0eH+7s7BxcHO10evTi8Oj04vjvd2nn1dUYxSDjxfLKdYNKs6T9NF3Rx/s/mm
# DATA xSLJDkNlBGwPealxOU6HVf0i7qH1jys1VwzyXVANrOFA9lcVvsRZGMxi8yaS+ryy/k30ttW9gz+fVDjttsE+Yhm9kWQX2e0Ej3JX
# DATA a3wB50I/AMbFP94jBWoPME3BC572gNn5TzDNM3y9nGVPgArwmpN19mJU4JEGL/+2mHSNyWsEaZJG8XYzHeBJBn6QbSPvQIEE5s1F
# DATA +pq+1hzCko44WpHXgwyQqh1yMooaVdUvKjqyjo4sNEwb+J8u2JtX8ZuzrQ0rfE3zALis1/NkIgqd0AkVALGxastSMMV3BD72g0tC
# DATA mKozTTev0M0xplAy1UQBY+/aUqTJpif6xoXg9TBWsyTaKbLbZpi0XOKfSf/MH+SraE3EvM6nCkBxpSNJ+BqeilnxuqW5FHbe/uGX
# DATA Owf7zy52j168PDrcOzyV0Szvxjb5FKoEL3BQuskZNKzKuYbLNC4ld/cxEf19IL06PNl5vnfxbO/lwdHXL1aAZPWZQzHWKo0CDp9R
# DATA XLuME9ggwcoSTCgBSuyLqssIKqI5fNOYq8PAyAM27k7hv/27P0NO8E0DhY/DD8oMF8UiJO3Lr+wGUXSLKkhjSNf8rdP9nevXs2ml
# DATA rAN9yWSBz3AFDf4V+6vWzm1t1uCooNTivvAsYUG94NLDPoStnyU/i/0f+Rv+x36r2e6qPzaGTef3rvLB3uc7u18D3R0+3//84vTo
# DATA CFj/8ed7FbVR1E7FWLNR6nkX6GdJRgCzzDa/i5JziXd+zDk9jqj3XAsGoGG86dkQRFVxT34NyLvWmJOoqHzMq5kTEdyDg/acEF5F
# DATA 2Md7n++fnB5/ba2pgbWBphCoKuJTIwWmymPVuH3A55sxb0UpPrYbyXTl2q/otCRLQbxEFJpjX4zFMV6Y4DrbArlJOaomdWlxsCx+
# DATA LupzqanPgFO6GPsW6X2Xo8AK8GkJs6t5it/3d3kIcydVMhVU6EDNIk0b/g4z7ohrOWGlmGwhJU2CqfSlvEN1H70yrK7XJbOaL/BC
# DATA HwBXP7WueMoWKRqq2rfhmXxsS3W1XZvMNWukugqYyKQ/piRWZYbBs2m6TgVhZnhlbqx/AzjXCRFLlY27vs7ZvviZyZKA0NWu8oqv
# DATA 8cZZDh9pEy0ns6yqXwXxPsUyOBdBFibJNlkH/Cp7oC6UffaWVk9OtcBWsL7iflBl3KriMbX49hPLfVqWE2m8Rznh6JDWXQEolTTg
# DATA DEVs1XWQaQZLEvMymb4hw69Sq5WojKZ7Z+O7fHU1Ey54gh7FSovbpshHTo5eHe/urWKdhqfo9f5km0K1oFeJ5hREF4v4zaIKj1PU
# DATA Z7YxuLq+IT3M8IL0OaU6nS3S17GUjaVPxGEwiheh1TOvVCpnf/5NtlZ5e/e0fv4JfK1bA7Mr9mNyGPHr0E/l09z3M/OdGTRtRxr9
# DATA Pht7hfvj0fY3wmb1f4qe2rq4aS2PrQMSIPLM9nxleaAsd7feV/d6vL2yXfAIl/Tv5IU+F31KECBWxyqHJ8+9QM5I9CvclgUjxexX
# DATA PFleZAi1nBJnDaNe2+admc51uRH2dYjpkpVsnJzXo+D5eIS6aD1WO1hDqpRwlkL36Gf3WXe6kbMSKzoz2qIMbbbaPcOjGidxxIb8
# DATA DVE0maOiuNtrat74RZBLXGBl0k8JqVQ1hLAlGk80x+FftOOq9uHqKK+yWFUWs56LHSRGb8XyCVj0rN+WD0/oTZerz8vMl6r8rsxa
# DATA i93PbXvmsbrfZzu7P3718uLlzukXlVoOvBLre4W9Le3DK2hbpaaiGmozW8+zWmFrdp1VgVLj2nm5AIWIxoSPLJ69rdBJtS17YVXy
# DATA 3pYKBTcoaMy/8pLnXagVHED1YoQi/ur/kQ8DDwZ3K3aiuN1lJM7pUTMHBR50sAQrhyob7K2lYG4RDRr+g4oZu3y3eIZ3NWH312w2
# DATA nKvyFy5v5G0c06V3ANvPklnVwFfnrlYoAHkKW4kx/6NtHuFMoff8McqBaAVYffLzvWcXz14d7x9+frFzvPvF/pd5FaHEj2J7idzG
# DATA hBNlnhguxR5+/zPgKHuqtEERWcyssDwnsDjqqVYqUGjsks12r25FVnoZ/GpuLk8lnDFTwYylauXd//v+b9794v1fvf/bd7/03/3z
# DATA u9+8++27X737FX/89fv/CF/+6/ufv/8raPO/8YPfvvslfP3lu1/D37/Gv+//lhOwkLyUR8qJUql6jRJhH8fBdDm7MMZa3qHpBHsK
# DATA eRXo18l8neWB1iHzadKbM0O5rvrrOosc/kgJzAUbGBmI8ss1LHNjFUF/ewu4oFi7XfG8So1jlij27FFLe/vxx2znWs61rTLv2F3O
# DATA eiZc0moYJe38Xp8EDx3H04JNznWHlTnjmhGWhbOckh6HOfhsdlvuaco9ZM+bmQiecCmVc6XKl2Z//rbJ6ynx5uVNbuXc06+TQhpP
# DATA H+eQfsgDW7NSPeIpeQX0SMqZO0VTdwx2Un53mKSgB12i38r7udqDK46jFXvFCSvYG4YpYdsvc+t4RYowS11zltpXRFVCOPfNU8+P
# DATA Aiv7hyenOwcHe88EOAqrL/AGrPucvXU1ZQ3Nw7sCZgWdo/LO3W99eyr5gPhPMSMMerXgEZMBMUtTQu/YOCp1XX+bIBD2ReLHzPb7
# DATA /t4bPF2ZLKi60XwajJ9INUSjjHBeDV2Ok4z5UheWud8eaWUIwAFkujr+xKtTwAA2M7pZFF8rlLm/PsKZbwJ8luqbOOkPRIV29oPQ
# DATA oMonOGfWKKA6OoLVCz92sHG/G5rjjc/28eqPo+OvYXNcvDrZMxCWjUd3i2uUPRjQMJM/RT8Nb0I9onK6SIYFyK7QCrBavm48dve4
# DATA BI7a45Iz8ghmMTe8VXkA6Or73YeUzoBB+dbEZNA7myoVCvAW0nhala/EAfG7AYzGRLO2uEUrZzvrfxas/wxPgJmPF43187fNeqs9
# DATA uKvUJd9trp02SkGyBniM0Hh5fPQnsIRAMXgPjFlJyrff9kvcwPyYQjvlCQqS9fB78xU7OU2oq9g4/SGrLwxfmdPqgagda3V4KYtG
# DATA Dd+zo3YTB1G3c/mlPF7dlkLcXEo+WGmfzOhWNTxzXcXnHPaZC0tAWc2Uua4oE1hdRXS7fBd4Vvv2Jd7rQP2sGOGsqW1RTPLAAR2n
# DATA c51p3SBZpd6S5vJQxsi5aA4cc8j37XZMa2o7hrgT2dHkGylmCFTYP0DpAeQYcLMiVrsK+P0HsgVqJWa6QGKpTRLpVMa6tU9WvalW
# DATA z32Rv93/JhYHNF4BtKrEIYBJ3ljPJ5XvQlxYfEcWY0thFJ0dvCLUlj6J00CdpuEiF155TCNPQkUbTIC3NwnLRvaUeiZ6LMOdKb8a
# DATA Hh0M0Bd5sUg52x1pt5rz+dfq9zldVLTtWTwK6N41sNnHeI2ALmaIv8xVaVQ8SmiOPbBDhK5DaRQCKmpi03i5mAfjCzVB1V/Gszwj
# DATA /XMm7siVeLMDjL9PTKyiJXLx5GhQw1GzAtDz2wvN8S2qUFh5RNx56/dkcku6oV+0pnWTKaDpQrUrOZ9hc2ElWcwrH22XBQhyaClf
# DATA M7K/adFMwFA55SznvZQBEqvduD1EUYZ1VlaNxQXkmOC6MW6KTr6cQMaNzhJVkhvxS6eJuYOWBLXRkFMbXRTIQ9fzpoC1djio39Im
# DATA /0jhwglu2KJB0+JWwePnK2tMYqSlbspywLXTcDll6jMKgbNP7hW5dVYEbCq7uShTmkTq1gqrol54UFWSjG7X70I8O+/EKHS8nGnN
# DATA Cky0TH8ZLpNxxN9mS85KpYrPugFl6iJlyEjO6CJFHjt6pNW4MAbljun9g+H6WEZ1/bkmU9bN/TVQlL5WDL1yP0VCkUoRVd36TFkR
# DATA 56UWxNl91sO5V8yeksOr25YexGfwy06ZSJ7PSmD2ptcMCQZXgXNJezXKvc1tlJxV9rE+OPvozNvyY/kBllIvPl1geHxBNy/un36t
# DATA PPolmWDAJy4kOOxrwKuS3XOI0RqQdPL1WYy3GkuKjySr2/xiRZzcipFzHJnHKwEGyed3BeahqP3joWGHjwboo20bvscuxrOj3R/D
# DATA Snx5dPDqxd5jFkQp48bGxoPfJ4qUy8e1bAyZPZkeNmFFFffsmpKYdft0kiNdlcFRKgVE9VC9eO4yfpjk1/4c7ss+r6BVm+IdFdmT
# DATA SomEeSDekdCJ88VtCekBzDI3klImyVi9UzXzqpUFNcrFme64buGlfNk1CB8xDOVrnVNcVFxDv12aLrpC8lIQDjSirQcmsRp+tx3D
# DATA VPcL0tdpJmfjlYx2ZPr9IUFKu7nOS2BH+8oLxlKt4MPVMo5jU/2Brfvqrfn3qi9ly65fvkdvcgYpX0Zbiav7VTRS6liSJa45Kl35
# DATA pn5AE+M+rS4LL7taKVpNJQn+Sku9P9Fft1qhvv4uzCtHrS4PK1jJTgqBu+u2fg+Kr9o8lh/jMXpnUedUWuQHanofrHN+d/pm2Qmz
# DATA QkMTmzfqaT6oVB4F0YxInUnyHhU1shtLtER68jy8afCC5MfFBakZFxcoxy8u5Bg3VW2Y06EWruDQ2JlfLjGU85KeVKNYi7Dtiwvg
# DATA JRcXNetNDHpeBPJKFRCJ4GGhXVBstl8Su5bbTyLLo7biXfsMSXiVIpK3zx5zPOT8/m45U2Hd5FcFVFNvu0IFny6wWKFy786pcLR0
# DATA RH+wK5Xk6HB4YiiXWUMlQkj3ORotZknQS7yK/L4OxHmrZaEuVWDiyY/ox04Q+X/e/eLd37/7zfv//d2v3v03zAv5BWaMvPvv737z
# DATA 7r9y4oeUzSwejxFhWDUKZd0/OpEPP45v6VPBs35yCxOe7L3BA6jv/r93v4Wx/+r93737R4HhH2DwX8PfX/rv/yN8/G8EyT/4mI/i
# DATA v/sn+OUfMEHl/f9BKSq/afjv/u/3f4Ut6Nf/DLBDs9/CT9QTfP31+7/Fef3/lOXya5zZU//dr97/NQ787r+//8/v/un9z6Gvf6EM
# DATA GTXk+7+VATF15j9RX7+CTz9//3++/5v3f/3+7xpAF/8T1n+5isczEvnTBV4vSxrid3z/Y7/T7ufq/7QG3dYf6v98F/+wQNkaebIl
# DATA HW9ty19r9wdhsNEeRZ3BaLPb7nQ2+u1o2G0POkEcRMPBZgTfN8J+ZxREYbsbbXb6m91WL4o2W1Hcbm2uYf7jGjmN19RFPWtyn+Ka
# DATA ublnjaopwg8wwGBD5UyuGTi6g83WYBQBNQTDKGiG0ajfiYZxc3MQ9EftFry1GfZ6nc1eNGoOuoNhJx4041Y/HgadPoDWW1O331C/
# DATA +qrTMhAGm50SAPpx3Ao6QRCHw2hjOBhuBNHGII6G/XZ7M2z1e8NWFHWDVqvfarWwlFUQtbudoDsKm2F/I9qIXADsu/bKYNjoDXol
# DATA QMSD4aDbDdowysZguBmPekG/H24G7bjTDWHCUbfd6wxHw1EUhBubG80o2Aw3OpubQXfY6bY2hzkgSgp+lQHTGsAeLENJtNFrtuJ+
# DATA eziCRekMusN+1I/7nV630x3hJUtRMxg124CzzmYLENEeAa7iqNXqdAbxKAxdaJj9XAzpis1VkLR6pdSx2QHK2Gx2ujGQY9DrDQfN
# DATA brTR6gCa2v2gFbY3OqNBu78x7PeDqNOLATPddh+odTBobYZRx4WE7rm7ECG8ApLuZq8MJc1eqwOzbzfbG8HmRhh0wlbQj7v9Vn8A
# DATA S9IbxZub3T7gpz1sA6hhNx42o7Afbza7sFxAVyWAZCsg2OyXkkgUxs1w2N7sjcJREHY2gl7Y3OgDLQw2hs3moD9steLhKOzBtm02
# DATA g43mBpBq2BwMhsPBYLMX5jYKqMoAAh0XLYcC5toflIDRa0e9cNQByhttDnrdaAh8ozPY7EZha6Pfa4/CuLc57GzA+gyAZINWDMD2
# DATA w2bUBvJt93rNPBjznw2D6Sqq6La67RIYAIRRZzgcBv0edN3cBOyP2t0BDN5qjrrd0UYvjAfBoDnY3ByNRsPNYLO9OdjobnRgxZrt
# DATA ftuFgW7fG4GWcwN29CpsNNutZgkkw6gVbsIyDzZ6cdQLepuDzY3+Rme4AcNuhPAHyLcVAo1sBKMBbKAw7rSarTACcgUJ2NssgSQD
# DATA q2sVFJ3y/TqESW9sBLBkQP+DsA+zHsT95rDXaXfiTfi909sYAgttt4aA0HAjgGXr9bq9dtiNYG8NVkBxEQIzG6eXK6ABStsspdRW
# DATA fzjaHPV6cTOI4iHgfbCxMQS+GXXCZtAfdjfjVq8HPGQYNYFUN+ON/qDb7Ae94bAVBnErRyKk8F9IUmayuF21b7u9MgYSbUYtYAxh
# DATA C/4H+7MLW7Mb97rBKO73Bs1eDMIsAkpu9eJBFEZRu7URb3abrY3OoN2KN6McLMo0Lgdho91ulW2ZYbvZaW0APWx2YPUHMbKtHuyH
# DATA XthtbSCZAjcL+oO4F4NA6TaD5rDVCUIgW5R4nVbXhYGrl16QPF+Fi1YZlcBu6PaAjW2GYa8TA9kCa281440WEE+n2e2GABDoAu1+
# DATA b9SM282NUWcjBr7eCQd4E12el9pm1yph14XVLWXqbRSyMQwcBv1OGLQ7QLPdKABWOehH8WYP9m0f5Hu33w02OyDs+sD54nYUwUth
# DATA q7cakAtzj+UK1AC2y0h2s9kKmnGwsdEKht1uq70B3LYV9Vrww2ZvGLYAI0Ciww3gLy3Qm8JRsx/2QQVpA39HKr4HpChFE3sVr4ct
# DATA WraDupvNHqAjHoZAv/0IxHC7FYw6wEhC2MR9QNtmv9kH6EBS91vA+BDquNsatJuwj+5ZKlPAcBXPbW9sdstACkDutEGNH4WDLmyT
# DATA bg+2R7ePdx0C7kA+Aw8KNmHBos4IVKlBuxOMApAhMIdg0OrfB9LsHmHY6bWaZft6A+iy2+mEwOqDXrcJ69HsjUDSdXAvgy4RxagE
# DATA xB3QYUFj6HRATRo2exshaCnwVrvlgrMYrxTG3Y1+GVtpbQ6AKEDegmwdtto9IJswDDuABhBLg2Y42gANEghk1I3acTDc3IygZQck
# DATA 8rDfHHRy9LIc3VxcLoN5tIrTAjmUqWkjkK+ovvdC2ERBawTzi0CT7bfCFihKoxGs1Ua0CVC1QXMHsbMJqjRgrAX7qtfM6yTsJFqH
# DATA tVitE/RAAy9TjjbDYNiJejBWCGQStYIecIz2qNfeDIB5dPoBYKU9BMJpgmLQAQoGXrcxiFogJGGlNtb0zQcEzBrf7ITESF+v+eJd
# DATA osJGu9Hq99e8O+97f/j3Qfa/UcD/De7/7oN2lrf/QRX5g/3/b1v/9zOsFRFMfXXoYi4Jb1L+F0sHJZPJkjSOup+ORlQjjenJD1O8
# DATA R/C+ur98Paf6Fs/n01R9ufxZMlOf8aKbcTJUX5P0dy8OfLVcJGNdHziYo59Cf40nM/s7lwzG/ITjnd1TvPWizGFW8Z4fHZ3uHWNy
# DATA RuWb6ff9470Xhzu7r05OL77YO3i5d3xy8WXrG2i2d/iM2nzfh08Xq1rtHO5+cXRMN5qTqxZPiM2Ha9VPJ7U/55YXn706fHawd3Hy
# DATA xQ6w2e2KfQtI5QdrNe/5/sHeCaajVPIbvMJ5nqKq4jfbLZF3mpf95qgJ9uXFFWOx4TvakKXbI8fqU06W6JaW7a1c+Lbl5QyU03ML
# DATA EM6skVfrgIWnWh0jtJQ4SvB3xzqmCVkSmu+0LBglekJiwDnfLVMKfxc/GX7UHqtKzXux85OL452vsLR83y2iQY9wweFZO/cod7Is
# DATA quJiq7qGWJk7ikOAo+pUxJDIED1XV5wM+XKTOhG4LlMnt5VYncq7sm0bcsSXGmBGtbosV94X6X3xOla3LW95K4vSVajWlPpP9dOt
# DATA dev0A34/a6yf2z/VPq59WlEx0nvPOMj9BcK8BCpdnAnz9S/whoRYXechiZoY9lnQ1ZHVyro6REO5F6OEj4gtljPYvFhjHEMrGOGV
# DATA 0otYjyjJAB1Yz5Erx1RbXKeo5t1XfUCd3TTQqNKdjYru2llHhgHvpEn46NjcfgVv/UVcD9N0XDWdwq/WTHSpbCAV2nSCTpYI2zaB
# DATA 8WO1irxDQ0xpqjKPrPk/8lv3LcYzfTOfLMcoTRfx3JxREl6LRUemTpiNvtalvS/nyWWqMni+7CG3bcTTiLN3gC0/mGO8b25nKoNQ
# DATA LRSJw2QqD8+21vFUD/Z/ziDh87ISyghWFR/aWUUoMp7tnO74FamgaG8MfLi7s/vFnm/LAdog6nunfUd7Afut1R5zsv7VNH4z43tD
# DATA nFn6clWRWQ+cF4ssXSmHiYAyC+9d6xdyIaPRMWSsYBqCAuHyI17OOV4ePqsyG/I/YX4k9KkgdmhU3s5BaJFy7awpS1IdrlXWamet
# DATA c80WqTiUZnc6oeWeAUCgQDflYnqN4G1WgDv3u/gZhqvbu8rUSQ5U9ZRJ8CaZLCfbiskbDvlgwc380fIi/r9gbNNpB6wYhjkpy3Ew
# DATA p5oO5oy/degcqZEHSGew7hUgvpofZNgsDiZmLLoCb1t+plMIVZkJ9NlyaIeEA3AFef4IeKnW2SJN/TFm2rhUkpd1+roFrpNRnQfW
# DATA JQs4PP4Ao3fag/7GY3AlHRXGlxlb59ywZ33cORYxiXvibYWtWLpDW4RNHav4mzBcRdfquKPrSuHVM/XW+YP76tU0W85mlI2qdpSC
# DATA u1L715ewDJ2ayfm3l7XlUDnarRrNQdYHDclCiy4cd6u9cMeMdadkj1V6ip6qylOy33BtSeHWpwq5JIo62infkMbuBzMvV9iKqtQ8
# DATA N1VOqQB8KqeQNlaORFw9c0J0/RzWGH6a3f4laPi1vxSl8y9Z4/wGVM6aHB19hDh0sItAUc2cgqy1sMjFKjQSEWWktsjm0DuAnEu8
# DATA Ax6mC+zBVI/5ULhVzqwLNyYnVbljhgVzsjM5d7hQcDX9H/pOI6QDxbA/EA4slGd2Q7acuMM7OiATgKrbgRQmVsIj+BjT1iouilvB
# DATA kkVcKV4SyoCt1aUsmZRNdOTgW1z9LRZhdHpeV2fi0zq6yBmdLZcDPG/LzR65bEzSHotVeuwzQA6H19v4Tlkacl9dVZREmoRduUjY
# DATA t9OLrvjLVgtJCqxT5KoZxJ+5RV5BoOZl/Op+PuA6XBBPDkPwo5SLqOE+qDgiRljNR9ta4GhM3H+euajt8cXiK1iP03ORBenLL21x
# DATA TK35yEqtUG9e7r9EyF16t5BbaFNeKWo1yaurGSd4XyngzrrodAXx6+v2CmQD7Muc55Cp30Nkpni0fqkk+bbQAW4i6xXYBMoXVWeN
# DATA pVa3N6jVlEav5YtjSClEA8OK+mfmSLesJO7Rjz+WmSsYtnCMu+Ly63OILujO8TtJmeb0elrsqkUraq1r+faqClwfQRWtfzKMoyin
# DATA 9VtKdc5ulDPjOdsxX4HvHiOyDvor2Ai2RSfGMA4akYOvwvdcorl1Ntg6LzEIHSOQtsFqk89RjtQwolzIV2T+/VXFVVcLHYW7Eunz
# DATA s0RO4rOntjHsd8UqkiHrmlytfF2yD9CB2/gc/oPHl2nfp8Ofbidp4zNc5/2jKvddK7UcgKRyhoNyfeUNB9HcHyHz9txpZgWxp1RA
# DATA ObNMsxDXMBs6JZPA4fl0wXZlvsVmkGRgG1gmiGFyBamKg0DF8mO1wAblAemKnYe42inMAcTVbX4Rs5wjgjslEcndl7oc+BmYjVLp
# DATA V7/YkNK92stonijRy9jDGiNPKmachq488s03+Z8f54HAa8YLJCp4rORPuqBwsUY4t1AevyFfPc2Mm9SYstQNHTcX2qzbFq1qls6q
# DATA is/VVnF3/ZrD5tVVTcXnWqWaRvG8TKaEAQgpuxreQyIlXS5mSzo3YAiz9gAN8zuKdG9WUG6pDJATjg+JgrxXazpK+aARAXMazPfh
# DATA l2pRn8OGRG91/ogQqo8YsfC3HW2h7oMg6HbhT9mxHMzupyXH9+s2glzpYvFtzen4tyoxMrTK5nGWVRlvuIFJ5caKCgTVdlNX1Bah
# DATA wYJCV23DRX3IPnvQdUe9fKhVQy/5OXtMwPyEI1HsOaSCKNi4IVNXri/tYsu/KSLOiCm8kZdReZYAfb/Zov8i1242z1U3bL/QAzwC
# DATA FUwvY/SO25Ksji+49SQtaQ4dKSgwiKb0NK5fzlEusVOovb2XVnmrtaNamXbmlgVdsEJ7KJ/oTw10IHCBDdZfapqdUOxO7B/n7UqJ
# DATA BqfIJGfAaHcK6ru6py/3jk/2jw7VwFzZo8E+0ce4+qRXKSTG0Qz1W4lZoeVizqizrLkPMuFcTPDdQY8x4h7DCm03sf1UkQjerE2V
# DATA NtR5JqcK6IoFdgiHyNCUVXFW/bvGFDmcBDGyfo8lE9ve1a5ITKgx3sgt1WneLbm10tR1ax7rQsOCj7eVQgeaiYutt+Xw9rt7BZDj
# DATA +qrd3Vkbr2rd9oCTrNM7GGJU9zoh+5kuttv6UnfF86QccsEFoNb/kS5+y12ge9befssm4VPblgFkPbufddSc1whOdSMktVZbhP0F
# DATA IjsumC2yFFM+G8OrxLewgj8p8raMTdW5RtMjzF+6kY3LHM2rBirrjjeKM3/zptnkSJdps6IO0CNFoDmppi5O0v2yCXzP1V+iKYF9
# DATA 3OvJ6T5l4JpuAHHWunsPFcYpnAA3jctCOivrLz4aDZfxNFaX3Xi5W1eLPgd9kPped4MqP+l6GtQZQH3uzz4MWHIGkEtwvQQVK55f
# DATA c6GtKMCMkMgCuuFLpTifEkcy2KW3ctUN1cPM9SZJSrjDnvqSw0BXMAC8oOvCUo2oiObC5DAZEmmUlC/Kr3XV9gneXz9O9L3VpBBj
# DATA rlFAHIbKgakkJKRM/Ixh+VHyZrvSEANvHaMgyXzb2kC11ZT1OzpzdM1xA6fII4cJKb79mPe0E6fbddvrpqbav9py95ZOSDN99l71
# DATA UF60Q2hTSBPtnhg/lN7UTE8alJmmnEZv6Vtjb+8n+yewJeQbiPC9Fy9Pv767p8RK4cn3/Z0p3bVkBb/x+qbZcjhOsivaBhnKerMH
# DATA 1P2iV0lW0t1snoZgpeBhfCofsoAtEy+BKfCVfr4KLqnEDiz+IGl6ZbP/XZjR/QwJKEUddy/hTVwPhXBfdkH0vy6rKq2PgZPXdLi6
# DATA QILTLI8m80RurzD3qHxkcxLrd4Vc/SbSs1NZxmz/R+NcfCjKuwekgSxUMu1KKsFwcmRjPlnMY2sz2b4GV/VY6ckQIqEN77zueHDt
# DATA NCV6QYfrwbSs/V4KD6QzRWt26QC0DqieGsYIKnWtdz1QMCBfw+DexoSlR7eW4O+jmyNNfRg8vCDF5g+UNlDVDDQiqVoEIdCQJVlb
# DATA uu6AqNHj8lcZ59a7jjFf6MQueMAlC5TWS00lTcgy0HTVA9ZX+YulETNIrBbXHi6EwbT5v8gZg3zq7Xef/99q9dqDQv5/q/+H/P/v
# DATA 4t/a2tpxjBWq/Gw5owtr4siqjMw53FLLOkCnACaERtA4RGVjtBzbd9Pek+5P6fofkKS/HIo+o3+51R/R5+p5x3svj072T4+O9ynT
# DATA nQ8kSQkY9DdcXoXzRpI+GaeLBZj0T8wFtrpMTOGn/LVNq/soVpZx+it5nO97nIIGVgZV/kHJLS7cGZe5uX+uqhJO8Zf8MPQ79Hzn
# DATA 8Y2LhFQLn1eLxSzbevLkEnSR5RC94nq449wk7pzJGjAf1QXDceftv9j5HOsP5s5BiB9p66y5vhmsjzj5p+Y929t5drB/iDnwFMNV
# DATA gZZZmiVUTUnfmmCy/yp/XHGulStEg81l15Iv/ccVCv6qQuj5VnNptqWbKTBghwXjCyzJXeUthenk6YIyLoo3vegSPta9RvQagsvv
# DATA W+EEnaaNUSB8yAUj9yO+qTEfd1B4taIPpgtSQ60e+e4ChvOBm3CcG1erFiDHsAinwWVmKoh+Unj+jKxp08Qr3qNovfHI6xnS+SUF
# DATA vsy1Eg3uRC6ytGoP36D39AymIMXaRu59g1zs0aYlqlFns6AzvYiFgqzoa5fLG5wuHOWetyPPwNz5KFvR6rx2bi8oAJ4vtnx5SUXf
# DATA ZKSEndJ54K1Z0kEu3gzmnsW7nD+FZASaDmiWktWEI9GVwdas/GCcpUztZIFm4hKD35Mgi7NGrted6xTswSB7jT0/o+KD6LnhDvDs
# DATA Gb0HHfk/xQxl/j3CjuPxyO2sfAVL58YJ9C4+5GkJ9s5LimupCpbWxsHUejwJk4SLBoo5dDfjlc+1mu0ZG+vYn6KsrRU3gJaufdmt
# DATA nyvhOTNfzt1oGr+kjvAQ2qsfoxJcJzF9wapwLrcPtV6+9aHTRDg1w3VuJde/rpOUbkxSmC7GCarWJTiqqx9u+828I/eUS1sqlwEx
# DATA PdFOQdMIIkqiAeUetPfI3CVDjo9tS2tozJfT6pkUtMQifTi98zqngIlTNwxmC7wAWqbLP2KkRH1kULYnoO53mnUDeM3JQlEjZosI
# DATA WlMeTvfxiThC9bAksMbwDB1UcZTpOY+TSbJwczOtDPP82ACStYK8JG4bWfUh8n2wjTh3VN28x/dt8SWjTmhWmnFk1kznNonHER+F
# DATA wtsI4M0tfp9jvjIW1iK8YKmlTPqEytcL6VVUncWACyvqQuZOipRaapZFhcvnLufpku5PUDODIewr/9SL+u5sGRtMR8x7zF8g8/Zt
# DATA g2jvDhOLP6bOXXCcFdG9uxceVq3Si1zjU8rqvo7jmQCHlx8AM1X7hn6zdJn8JkLMtpsFXDgoVsRpDWnZ1pLQmLlHFcjvbL3gxA3v
# DATA y+TW/TEDfDA/4aXcR2BVVVddICdJ2Edo3xabXzlO/VRlx+10aA3L6kt83Xuk7TR0FNJlqhEe1GN9aiJafqVmXaCuOTkCgOu69SDk
# DATA UQ5sTYpqAEOTuneXM1O6XdlxwxIZVOh9XL7bVKXTBXDOMLf3XIZnDUmH+dBmv4/F6Tw1MSZx7sN0OSVL0/FESgNH7y3Z2GZ4Swvm
# DATA w8Z43xwIwntQypt5JT6VjrEtOUUjRx+uOzrh9IMVe+U3zu/qH23rTb9VVpLzWMtMQREwHtw80dZq4cie2G2wm5H1x/O56+0dQrvX
# DATA 94YjXTOghIs/eAn6930t3kbwPqJsHSMSbMtE8ThGm/Yp8BSfivDWFTucARFS6qDUrnd1vcLqzidUh1cvTS2ns/GSfrLttx4XpLT0
# DATA iBP9sSxsKcvDaopZE5l1mC7HfH0eOuHHt0qxTRarFof7G1V2cVEB5LcC+53tndGmshDDU109mG5NVww2RymV2rdxrX9wEV7bJPqQ
# DATA gr4sezCuyVcxbSvLdUV7ZLVWeV5WgK3XlQ35gC9bSWq3LK64hNVdbfSFZPb/es5hXaTh9zjGA/Vf2oNWx/X/Nge9wR/qv35X/t8v
# DATA Jaqq8wGFc8hFXux0FdsfFRaw0JnB3efvzdVtudf9W/dfgh32EkzuNyu8wZbvV+q12PUn+KAzqa1ylou9Dtv5MhRWYjTfu0aa7v0H
# DATA mSkx6Wo5fU2+twXwxHEwGUbBlnNEwbL2algjIx+hZYiUIkj9uUeO+HlJhQwV8uZQ1SK4BH6Uge2jlB+5vJnmY6JkVjq7peVTgyeq
# DATA MAtfBlJU9MewuKXvaf64zk6K1V1Y2axytSYnGXJFADpB4DwWyuPnMMf71Ml3/+XdL7m2tyrk/Q/w57fvf/7+r9/9s1Dm+rvfvPt7
# DATA vML+3T9hIXBdyUPgz6yDfrkrqOXyT/tMnXkm51MfUWb+7sEZUK1xmQGVHscC5L95YAaUOE3a6dvgrEJp3edbfkBEGiCBMmnwnPiz
# DATA uUgokKWgKzj5JqHlDBcYlANzVZ8lBCUnemohrpgeNEvQ8YY0c8b4cO8px1H4Z3JGCO4cHyYHbAk2fRqcLpRJpnYWdDq3W+KNDsnC
# DATA aig/PHgW8N3/pfDK9dwJ6795/zdEUljJHT5h+ff3f0M14d//J3j8j1R+/p/hpX/hI4MlBfSFWCwQ6RgCWgLA3NSdskxAwSTqd5Fw
# DATA gvkEPtw9CPN/wcLzv0Eif/f3QDUIy2+4LD6WpQdKsQrTY737d/8MU/k5fP/blfASyQCEdRNZINjPcnCfl2eEyXVnIyuw9FaPcrf+
# DATA Fjbx3TrYI8s362+xw7sGcO7G5c8quXSsmXJhjO4JYlk9b71lKHXhv3M1GA9TKVgxJmxAF+fREqiTSdZDNiac872PybK0uREsBCzD
# DATA r979y/u/K9nFv6jUys5drbhz/ZHo+GOJhlX4avb8iXgzPX3hJjswPnRqzGh/8e4f4csv3/+1j3/wA5AZzO5envX4Yy8uxKYKAN6W
# DATA Vl4BQMUCV3ZCH1Uk7INnDVvq73zaa7+mifLtEPwzzP3n7/4F/u8Xj1hrYsV0uQvxb4KNUzKVrDEWJaZ60n4oiZa+ZZ5+tvY/2Hvb
# DATA 7jiS60xQn/ErktQcZyW7qgDwraUiixo0ie6GRQIcAFR3C4RrElUJoMRCVamyiiAE4RzZstfjY+3YM7sfZvec2Vmf3a97jtyW7Lak
# DATA ls7ZX0D+hfklG/clIm5ERmYVQHbLs5bG00RlRsZ73HvjvjzX2i/UAVhm9pkv90anQ6Doy3gklguHAT+nmTmYjE7VlaijP+nMJgMm
# DATA p9SF98wpEV+RdELl9OwDgcF5LgvIXowQI0f8BRPin7z+R/X3f3r9ZaRm+JeYfuQXmAUEduJvXn8RfdSffjw78AO4y/WUYgwU44qI
# DATA XIlEcMAie/QaERw0mNqNG7eudF54M8AAflKxSVgE1AKJDldRa9qdFsU+J6EPkLyk5Ut8FTLjkshvZZxaK/hRYJT/DRniL3iRKKcK
# DATA 50CJ1ELRGVFnJsJaFT2MqFY3lEJ3d0+KXvu+EZVYU7uEM+3Bb06BywcMEr7VCvLQnpaF9nHsWnIC4YQ3LrKGfWc9zm/cwJdOVAx3
# DATA xEglmIEVBQ/zTgsiXjyM7LsqTKw3hkPX0jsveCShCdySLXeDamALtGhxdqga/cMUkDfGAE3jlFtRvdTiU7UF3YQuim+cERAKA02e
# DATA 82Kf84Oaz0Y5kwuUBuLKvfW3RRFG0Vd5ZhxaQbKZKg5SHOxHSvnzU4FNhqOa4w7gSJ08JkfuXKgW0LsVqilKpYFR/2fs9Z+qgfwN
# DATA iA9KviuKnurR54qs/BT50BfelID4qr5685fiKMJD52qE9MbALvYPzzocJ8tAY3LP9ANXazGqRVBMdj5ea6hCIbonBO/P1UoSaVdE
# DATA Pi4LXKYOxpOWkh/fcZg9Wi/Q52J2UjuhWHeTmVWU+1YZLyjfxa8/Dw5ejRvW6j+gXPGbCDJtAclUD377+p+F3AA0KnfsnAsG9LNo
# DATA 7uhUaiIyvsgqwdG8n3fSg3w0mE3ZGT1uNtE9Ct8C0GVeEsuveWjNQAhgWIDACdCgAosLYOpCg0Kk2h1qvlj8/B1u/59FwYn9ZRwc
# DATA lx5BvlDTwNs+ByYG+cfUUforyIBGx+lSjWOLoLP2YtzBPkdOFCFogtjoJLw8rSzO6K9Hk+IuL3ysYRuCfgjlM6+IhlPRHOFWl3XM
# DATA yTXuaPHc6dJFPVAOIIy+u5gqtMckh65n+/uXOHxIYIycAtTwF8AcXv8DHDRBQQ3N/RJuNHgstQhTeqEhBofUsQxnQgzMptMurKms
# DATA KLiuJfVcfXn5PvPnatT/QAz2zf+k/v5izkpbSCfRZYmioZ0qxa3AU7/qEDGp5hRcRd/V5q/xf4FlhTuZWtY/J80MHdorcBscm5Sh
# DATA hN7ThigTc3TZJ9uUa/wv2HslD/1m9HCgJLZ+1xpBQYOdowsdtcVM9p51hug5pYxMz+phEnUHg9Ep6QD9iavrqTS3/X3jk8quq6v7
# DATA F44tX/fdnkjzCDcceivwRYFbXsCdCbMy/gOetn+C01V29LSgBp4QbaflpcK6nPsiNLlTrDnCp5ISRrl5t5WzhI6HRj/VZ+givKx5
# DATA +jLr1Ui5767o9evXH0KPcG3UOZ+lA6T0Pb6nsJf8UNs2pscpaCw4uo0cFy11BeOJyxMM+BTnerV4REVZAI+/dlIoh3rRw2CUoh9X
# DATA YL1YqaLw+g9ShXGfgml/ry2hkSqlDo3ShT/Qz8MKnETAv/WWSgabj1Seun/EXKigkVRHbgEFVZnAchmAqFJWVOofAmYiseJgK3Cl
# DATA mGI99rRYcaMC5slPHO+2aHG/Y5aaIo6Vpq2517qJSoJafDAYHVAiBLr6lHjAEINcEHbKm4nLMs72PMbpyioFcCyudCksYMKm1WKc
# DATA YQ384NKi2u9FTPMFFrq/+0NgZmDtliZGntyaKwdRLodc5ijOEVAuIZx8vRm8yffGiaLVmkc8KajAJK0iIbY5fngx8tl3GV47TY+q
# DATA fYaMQXSx+qyOPf595CJ31W1VJbUf3GLDQlXnooW1b+hV06DrgF/6nrTNgU0iNM60SK7/AVVBpu2gX7JW84olI/w/CB02zwr52LlX
# DATA cFRMp1phcBQ/hXpBqR5Oxk4OfQKRiNX6FdX5Odr5t9wO2iHXbU8ry/2J0+rJwLyF3D79mdGnt8hcPDUifgi7y1CkAu/16yYaUFoz
# DATA i+LkJNkfNg9mgNpSUn2eldajb2r+zJgrrJ6YQtWhfPYawqYuAQ3JO7QEUITZK7aJJ6rYU9oogIqE3ydzvHeJGe2c5epGs/5K3e9W
# DATA r+hz6GQz+n34/ylx8f1bnv/f6srtP+R//9r8/3Yn6TCnQ6kutJQDSzEyiP/JOcYBtAnZRN1gbbC3olMgOY9mUyqLuCKqCPiMp4N8
# DATA 8dRv3dH47O2TuvWPVOfNr2k6XTySXKd6mwxA5CbkGfcZuDGDZRb7w89wRJEth2qWOvw1G+Lfbgo5OMiUl2WoGOUUAqvgsOMtuoO6
# DATA NCVrWTQYho1RpFoPlVK2iVF52c6A9OAfZmwDnsBw7rbITP+JogE6VkFxb1gdJUt2QXkVPTHkgWReSwetTmQt6vXTo+FICdZd0nko
# DATA 2RlhZ6ajKD8enZqNgkQONwpKszPuCQWQ4Y5h27f6mCxP+Koejca0O52YRAZwxCmkHF/yLqOT4LjqB/qmbd0/m5RpyLysRJnzZ2MR
# DATA rQJ4i/wpe4/8Mxjy3FQnemSUDWFu8p5iD/5vdVn4Z9CwFRpCEyC4qbhubcG0PjqdkIY7sjHLbn/MNMERQ0TJTkGPcfPtel1pH7P2
# DATA UXCrIH32l77bhbqOvf6d61wBfTZQseoGNu2kCGAhvYb5QJi8fHKT2eR9HdicNes+XI9sbAPjHIsJItcM9TFCmqfT5k5n48nWo/Ua
# DATA IR1PO/DO+sxCwT+KVkaKLZZD04NTG3+tSAvcvEd4t83Ur0V2zP+Ot9Sfq3lUV1K6d/4KfWx+Czqk34F9GZZFXUN/rWa2cCf/zZuf
# DATA kv0dbt//RH6IaLD/9Zv/GLtAkB2ea76q8mw7ThYxPIpbdj8CHCjFgrQign+OUa/KP6Mfw/SsrmKCxpfqrgVqXZ4N9QCvmAQ3oZ+q
# DATA 334SkHC/WlaXqiY076oj0OdOoVw3nEI8uAeQPQOdinCVzdQT1PbWuHwYCpuzCsAeORyBWl0TnZxJXEF+xIZcBSLvp53Hm99195PR
# DATA nZoi2+sfFYuYt482tive7mw99Oov1bguTiBh2yFV+jlsul/JLUk2crEpw46EFf0j6iUf0al6/30ycJQenksM7O/Ufiflzt/jkH4Z
# DATA vflzImrgkls9IHWc0Pv7H9l/V08EfKQoHdqbQYH0K/DgVY/I5a0mGri7ogQIr5UvIsjfYZw80vF4cNZxqR39A3FZeJF32Km+pGCR
# DATA VkneEJQjRqBDGuVkaaDye3SO9+vwfKuz/Whr8/Fn6qziL7W91h/ubm2bB5tbH249frz1CYOpyksonw9V7BBPh23TsTLWnDMvjjpq
# DATA Ik2nmETs1yP9hKjDvrPDiwRZW7xMRUySREVElMJppi5Lc78gL0F09fk1uxvArgACzL5OQHqpuJAhHLdaXNGw9qJA70KzClNO2Hz2
# DATA rR2ungBCcMC2yKPfn4+lIK6iqrw7UNKl0zLH8JgrBfsrCs0HCLSdfk+CuBeiC4p6NbGbyLBI6YBJ9ZL1uBmu25lJG+0NbaRDdOfy
# DATA VpgxNBieWVtal1HfR1aEupbWyTxRVTShlEo2msIFJTefFAaZAxx0jccAALQBnxFHoguOghyrnN4yE/Z6pToc6pYYyVKhavWqULd6
# DATA Jit3FlOfOU91uoBE858Vhfx7lADRdVC3DZ9rgbG4SxIp39kbhz9GnGfbSTvTbIeFaBqYmsIcmhAiKEGbajbUWK+92FCgzItAImOK
# DATA +bmIPKeEMqQSX5I1IlKMCWwIvyYHams2Qa6Crvv/gA6G6EuIojfGkhRF5jr1sA7OsPxXDCjNJHfhk70Y9AU7/NC4pTLmcudYXQv1
# DATA Lc7E0wKpcLmO8NTmwmruk4IMjO/wobpnA+4F37vpI7SitZYpBw09oaAj7UkPFx/3pqgqaEIX0f6opp26WNEufzNTs6Ct1PB7rC7L
# DATA p6NJz/xWN4n5K/e3Np7iT6XyxDV1IeP4ElZUiQN/Rh7wxCB+ghzhNxEupBJEOG4JRPU3f4kmp38uv4AakDGrsqjVoO8Yq6eXqc7D
# DATA g70Af/1wlgHSK/x5OEmPTmwaFQdcqGwpGK9I46SpAuyVorFiMECykw1f1kAly8m7JUDNi+yMn5qqQ1Fp6VR1HiLTJvGf1L7Tyl7B
# DATA iuxFz6f77yXfgX1gQ21UjRw9A69vtJs3/k0sySiky85AyV3jWgklCKSo5hOPrsILAqyDJAGmPIWMRp0WdB9oSNtsRV3Z4SA9yttY
# DATA ZYU9geuHf3QmZJ0IGbOrvFdsgF85ULvqc57w8WT06ozU39QP55DWoxf9Ya8dd9Ne7yy2ehczt7Xv3L8m0oo2G/uJO7lUHc1v7TuF
# DATA smzhBF0jeDShPMqypqEhNT+B+3A0RLQ0/eGSi4YFEsRsaJdhGFoHHh4vgZn8DekUpnul/0LHdqj5gUg45GJq8ZaBWaPQx6P+0PF5
# DATA 14eOdwhMyknyJ7Xn+Q1Ev5+g+fZ5/l5S2/uTe2qv1u4lBehI4Q1B4+FkhviPOku4ADR19OgmYu7R37f2aceFLEhKFENuuCIcVocS
# DATA kMXPbY77UCDFAEgC+FQQ3kMRMJDs8ZTpjkjANx1ERXHquC+qM3ibi89jikSlSuAR/61rOtc1FbPhuMFVgO9xSEFWsif0fcDhZIj8
# DATA nSeUqsDzdo56NKzKjfXGnr9nPCyauGmggSRq+A8vvMstzqPGc8Ns7cW9I7ML5o42kXfqfM7zd8BU4HYJHOIXKED8EmQFFBK+xGvm
# DATA L+jJ5yBN/A59FT5XEsXfqKe/QaYzySBGIiMKck9eYvAiA5cYCtVAhZJ58+av43IwOpNuEwB16pFQyxTkNGJJRjFslXBAANtWn2SO
# DATA pHrMEiZUbnILFVKWF/L7FJWjyMqMPg67J6vcU23tI3qq0WQVMothLnCdZh6bwOYLCajgr/Lzz7FFJ6Tx8hSzRu/x/vvvlzeAQOwX
# DATA ckVU73VmzV5fR4CY9WDq0ZJzHVi1pfCsmHsiMzHd0PAlwo6BfRwFybrNxmET4c3YBxJLkNQMH3JYLwKHVsmURYgyU+ce/eXAuu7Z
# DATA vYbaXtshuBHgB1rr4cGKMVMhXDGcZOJgBLvpyS5a8tEmERR++pPREG/ENKPq3jClbNx5QCIqCXPgeQIBT31uJn5PC/CwJOgLJnQv
# DATA mtjxZUabhGSP/OnXL2LhVoBLiVrOwrJSX0Beg67YrDz7bojLYlKeONoAzkHdZ90nthvI2oCF9Am1cr13bQ58+c1o9zhTHDefRnrX
# DATA wWlKZ9Pj0aSvTl3/ZcaBh8PsFDp1j8VZyiZEdq8xALJOR6Nizo1DbZ7qD8u6gJqUSf8I8Vfb7vHCBRFadBPYR+teF3TN9wIJjB8Y
# DATA L3Zir7G6T4CpWgguE6hJ8DRStGpRdzUoKTvOG0E6I+4CtqZz1UyL1u3CBSa0y1++RSX5c7vD3+w55ffRKR2q1YcUbALYKyDojB9o
# DATA Hrp50AX6aMwHiUD2FMP8gdr1DQxCtRoSfowCIEMF8iN1OLxgUluJPUF1dm8XZwqaO4zrnGxL91JTHPD1guPIk06DwTs9DwTGGLUd
# DATA wzB2LBFO6q6/ERuTa1BUj5X9zeIbsXXF12CDfSULTcajAXuD4TO1AA20g8/YvdAB5pS6F+0VH0A93OME4VotUY9uCF0LqMb7XTQ+
# DATA Mz6K+x4dd3c0mcQC+16bSDqL5Fc6gNNYJb3dNyojRMMz7v0VVFxDu2klpnZlguhkXDChj4FPBZyAbmdPe/wejEaDmsSK479p0DtT
# DATA WgVDODjhlp5t2Coo1CDxbkW6efyshW4cSp7JxvBHjbaRtOXp0GRjzXM/oNf+Pp9wF1pmMHbAOY84vxCyBnQSiCEL0PDTYnVq6kp7
# DATA g7f1h74Y6EkzyPsLJwtkACvnLPwJk4QGt908OxnExf7VKirAtI/N6Ss4DGSExnGjo6xfIinknK3wcAiMo2Cthek0eoMMXFSKKnut
# DATA TXOV93VwR+mcZIpX6gdgTUcZVf4GpsK/+0MECZWPyFlNcYpJdpoOBvKWaZR4VnohT6aafmNz8p2NMTxPVmU4A5wR4CE1yoTqFOJb
# DATA p1YFX2svrqH+P9R961dgIX/zl2zn+aVzrzJ3JtMW3MpQb6dKgSrPxVYA4zzdsCAO/q+tT4mdZkfUR4NooOuYq8p+YlTwoDEFcqsl
# DATA F6Tdg9GsdzhIEaYxPurCuU4W9JH5BaEXoTITAHIM6tVv0Rb299Hu452SQan9P5r0jCaaTToLWI2sBl7vtIWnxH5hZgQg5/NplqJh
# DATA AgT9XjpQX77dDPyEHCxAhfuncOmGW7k/fu09Yrrk2g2gzzvq3RPtZm76mYTtZTRIGP2CA1xsfHD9/5zV1V9Wje7zokr652/+wh81
# DATA quzx7IsTDT9rhk6YpaUf/sU2MEdPKaHW7du3mKe9mqRnwUYk8SHhUv6e09QGFebWvmWbm7cWaM60M48vIBDn3J0AMruk4z62AMKL
# DATA na26HdMFGpJuzV++/0amhDd/Ha093ag7iwWwE4xD8fPoU1VzwXXBIk+w6wIvYH6cTkh7Osday84aIcsrEmJHngkYy6BWshhiTaKU
# DATA yPmK0VI+Q/XLa3FblLYSuKUmOLCCjdkKZHYALfQNI/lkNIDJqBmLlWOUsqMnpsV4VdY0tYDV23gQBqdyyfOVt6YzMQGy0mcTBArf
# DATA i9XY91b2L9eXQmtylmGtHtEwi3XxSpLdDo4Hl0xcr0k1mS4zrpiTqgEK4kYL5E7LXvGLfWcyqjtleMr8M/hfLN5LWClbabltRq//
# DATA DqnqX6KPyc/BPPhLLE7BcmQW11ZFwAv8Ej+l58yVfs4Pf2UAdGhKPHlKPUR9JbykZYr1LFghrG1mwxVIDOd1eHIo0K44Rf8Pxtb9
# DATA mZwa8sBCtBzrkkhWUEGKDtLui9lY+C/QA3Kh4BPXcGAS52T0pe85cbTODQ0eWTKJtFWB4q0JJXTyc0SYVq0VQCrWkuJLrKZOPVH/
# DATA BSdH2v4tK1eXpFm/wCRfICqZn3QZaqnrq/oxPgaA1Zb6gyR3xMSjgXC36EdyIRBcK6Rfl30FRSyZCoFAyTuWX/tcvZpbe44UjtCT
# DATA FPgmKbatvVDd552WhXChvW7nVNE/DI3hWtur2wv+wqsZvPyQ5zD2zALFOsUF2a2aliU7PFTsCDSNbXY9cSjotTAV5GQTRf6Kozw3
# DATA nXZYmN6ZcTDVnXT60MAKQtviqljUFvRKCHQ0T9uiyrK5GdXqVXfhh1CMtP+ebWaPUS5YZxHUdJmpTBgzmivXIQXFNnXalVdQBvdg
# DATA g+y71ZC3NJp5AiDVy9J4qcbebjCDKlGPOuIwHU6y/Limg05N7+u+PFOvsAr4a2VCusmlqkM0qe1erPV0h6vE0cHmN90OvBaoQggq
# DATA vHgP7ZdgVSV45/6wmWdTzgdQizmTBGnzXOALtOkD+gR+3Apnf8eXdILoWZx4Zh8s4Zh96BuTFBD8XMgxJjbNOSy0kH4b98jyy3Sy
# DATA POgfWATYZcVU48Vdlf8vc7kyDJOgW39Gnqh/T+EhJk7d+Jz6Ggt1SVeSxn+VtzcSLH6Jse1SZvlcOyGp//5HCRiFc6z1c+cxKGOA
# DATA yBz0MX1DzKn5iCPZM6lOezebQIJAVYbnv1U6NcgK014HMp9rIVwAq4EyedD/UdbrmO2yx5ugekGr7bDeYIi14AYQaf6WNdXlDemM
# DATA ubBfVvblcAPb6aK6S4HtXTVGQGIRe3NfZGEE/2ExUU7FxQk1Q3fPS8luVrTLRQSHOy83acEn+IFBbsDJtp7aZgfxvJogCP87nfwR
# DATA L5f25R5ViHgfvID6QoXsQJbkKtQ9wAkwW9AX/L/6PhYYC/EXqAr8Elw29RXgV5VO43yk75GHxW8Z+/JnJNGTX2DJXDvJtV6d2VMw
# DATA j37vGSq6H6xi7yYBiziWADNvibedOtqnIzCzDqx6eI14nT0noxJzCZqtBLSp5TSYVMps7L14h3vgbnHHUvIEB2uB9cVWf5SBupTS
# DATA y1fud1b6mA+52aTgB0W4edhLOguXir0xrsCoTP6Zs1fg9gcsgH1Iw9vLxz9yVo77Jb23VI/FceFcckY4U1NafFtuj2ABGguvYZwB
# DATA CtBuTIusy5dEer2s9xQ2KH4HfMArQdYrtbFcIRRK782xCNYjIbX0Dy8twJWs2rZ0q2JoGM8BS4Mt/8+kSvbu7whaibGTRa3Al4uw
# DATA 7i8YTdeFtSFd3y8wzg8w0H9r9cuBkYcG7L/RQgB+7pjyoSRbau0KenuDatMGQiFhei+wnsL9xAuyKzraXsbuik17OO6l3Xt7IyxK
# DATA 8byl8S97L9EHUwpONXJCbYKFdc5NRVyo5l1XauE1co0nQhdQtEWWVIDaBOvlZ0blZJkBQqhvPDg6jY+ESpNqXcIVVAneAOYFYxTA
# DATA NdVh3YRe+k6SP/fk5Htw8jgQjE/nm/9kXP1B3+4UNwq9z5G6Sx2eVuz5npucMAd1iV+gvCFxMLX3emhmrV13Ue0JzlrAy5hbEZ7n
# DATA c9e7Ttow24d48Ys3d8F3MTINSXdocjnqFYUYdGcInwnSWAsyR3XsOYpuOKuOzthxPzyPP9ze2tztrG8+6jzaerK2sQm3CGkgECN/
# DATA ura5/tgW02+sXAMqbMqFLUJw1ENvEskbEeJoIHVqtRHAyzoOLXjUWA+6qC9npbov12Avr7UX1c67c6bEtGcfdJ4+++DxxkM9Fboh
# DATA 9AAvxpe4aHhVfpZ7Q3LIMfOy52qz8A4/RF0bynSn6cusEUD3Mq6aSwb/KLBXAxtHmD2C+4YL6mxikoK1KWRekr22NA565sm2MRYm
# DATA xW4URSJHZioVjC7NyXWDo9Nh1nMaDHl2SbHM/aIeXq6k7ijr9hOxIHMCPq98lEIHYX/pCqfl69yu54FT1ao4UxfuUvOuLBzlJxpy
# DATA pnThw6XBP7jkFODakbXDQoeKYNTW0tu3MX+hvgoK67JK035ZJ9n7i+0++3toXsJfCW4l+j7kpMallgp3IU1WyNNW9wAdptkzW0Tp
# DATA PjLmakG0PLBDIuXCUZvrvDCpCtX+63UEbTRm4LITSgzefEH1kJGxHUlbEmkDjTRNZaCD6OBULT6ks+ko9r2k397cIustddiSmS14
# DATA WLagMdB5TltYsR7bIs5bqAIr9Ujhhtu6x1f2Ayr4eX3u5g/75b0SUHoTQ+SJzbG1rerdivJcG/8rzB5tR4usGAF7INI/KAWCOaTt
# DATA G0eK4L7ZBFJhK5rKm7xdc+idPAzJnG1ryENlMztiX+XtuM4xX6VU1hKSxBpvnVNV6icjq3lKWfDYKlHsodqFD3WV7UIj6OaJd9g2
# DATA d9Rzm8Gmq8cgo3iRupVNClJDf2JCpDrxKtR9JGvsjRv8qUe2cCakB4/00q7FkIauewxWpnEG6cfV7um/VAQOfyal7sQBk4b6y/FP
# DATA XdjRx/dEIu+DThmGRAisgT4p4heYijj6zfyuCoIzJcmgmVq1Rok4wOVQv4Kx79MzbruUXycUmYIOnp7GhmIfO2ZI7hWOAfUqPrmi
# DATA jDCvoquJC2WzF7qRlQkCchn3bRwz97La89t+6V/cFhjrtfYC/Q+E51Kr1qGOHri6Nm7VA50IRO2+wHu8Z/oXTegfyVIYMD0sc1PF
# DATA rtSt+3Q1sXtOcKe1LoaE8/mLUSm6fzN6jIH0hCA5yznLNwGoxHk0nh2oEUXPth9HBFNGyUs4Hp5gYdQMT7I8by6mHaE4B8iqN8kG
# DATA lBRjyCSANy+5R5UG+/Fnc1B6SlMOlOl1uVoPVHjYGyveIumj3BG6LjQraX3t+pPNtU/WvrfeIT2Nmjpy5gzpP3BZdCOJA0SiKMOC
# DATA Iyrb6jwixG4xf1/as4e/rHbuKRba99ThCx2pQDVwKQ1NacsFmNFz6FNUP7kq8A3aZpcEWQohLBmWZyotAVsKEljzUZH+hGm5/WC/
# DATA yK+92pCRgO+TiXbnwCjbsW9CKgMMCLQBjDliOhxn/YkNM2WhmHALXk0ZH0Rx7jOmAzaS1dQDZg7yuQTzg3ncMMCjTqwWJsWlUK0k
# DATA NM96qKcTRRNsHKPnwSQzVVEQohesKSOPZdDm3DhFwsDnYBSnL2aQMV5FGPwL/nbCpkLFDEwSIeozRHGW8/7Q0+8g9C2wqsw75VjR
# DATA V1evJrl+G6UcpadUZ25jikKs/C7xI8nDYY++VU+bd0zMLon85cYeo78ROrrEhRthMxoK3jghDLpazFAU7qMZAGskffMgadZpquEW
# DATA zm/3Q6l98hBZ5g1XCJQFJ9yxCWHtZg11SCeZjHbtZePc/DiY9Qc9DhJW1wtUq4A5uAIB5kZtL270GJePp4lcIKlK9D1CHegNykHk
# DATA wpd6E1TgtmWzFZTeiImnvbOq6FSd3ZhdW7V3cQ2V0K0iIKTF726qbtT2AEg7e5V1Z9P0YIBBxhtxEEsb/K0omBp3lmmpOVY7L8Gs
# DATA unodUEPeGJONEAkUdAaoBOReQW/uOmKFj2bT9q2VFVYgU24A0cEd8+e6mwTgMh4a0kZPHhoyFDB6/avo493dpzsNHabz5qdBFyAb
# DATA SPiFxmAhoF52LvpHVLOAG9Kv1UFEoHC8zDFdUtIekC2JjMuu7OVId0STyNF8n27JcCQGGc0z1Jn1GlAt3ZfZDz0Jgo1yfTplt/Wh
# DATA XgPhw/0ssJsCrtcWxHJhJrmgBUMyPhGUy9716Kz89mzwaqxtckJbXLEZSYhi1yYiqcKghzmCcBw+p/iARkTRSQ4eK3+3bLAOMM9M
# DATA 3qQp1zlJA7jmkqtqbshVcKWJo30RsCAu/kXhwmBcd615mSoIgAbxMBjVxYKd5gGoCKq3ORuiy9JJP4drU2f0wquu6FPiCg9UTV1A
# DATA AzEakNcJixJU1/07IQxbSsATgPkVB0f6TiUW+Nd2da4E4say2PPddk90QDwi6zqJQ0z21S7soJJ2ccJSaBVHDOxoTpMiAMA5adpd
# DATA rYS9cXvkYpMYZds8OhAUAhx5CsNq8RS6TUi8Zh6AUHly6PuL7Eyi4F6SFltoVRH8Y+Zxkfh1DijTanntR/5P6FwCXOc/OKr5r/60
# DATA 2ot8AVuLD6jE8HKhtrhAtSpTN3Ct7ZOFRd18C/kYHJxnjOP72Tyk52Ykk1Jrvx72EgIkfuO455hFrnxgHNnrMrTFRR7GLrC1DfWB
# DATA ZEPyCKmffYoNDE1Q2HbGaV+zyIL1BdmcfVgnvCgq7ODfzLMgePoekuhskpOSfE7ly24TOLFMRelkfJ98Dt0aRnu+RULJ6d71v0le
# DATA JLUkkN6R7f1T1jCf6ylveStQj+QccHQFcnjxOGkKV3b1hZpTWRJgUmWJi8JNYvHDrlNe0t3dQHwFZtnZrKIRc+8PMkXdK5Sp6kbK
# DATA s8kZHIaQlFx7NFTdNX2hDhOAotgUFP9YLNLCH3YtAMJFNRViS5M5U2PlLzLsSbmr7hr4L1vV29VhpFG3noLWxnWcdcTNfcZzlOJg
# DATA edM+RQuVpOo9ObMw4opB0CuQg+n/K76K+K2dSTbIFOH1mFVocFrroo2QjgzvohO1XEYf7G7iIxpdBBHmWPtpjmiRzLTKcOFYxxmC
# DATA VihF9UPxSX7oYCy4nxnzezlQHNXkj9QovLyJ9csFq6WEWKhAl/0ssViWzY2pBT0n+McVpsr99O0mS9f1zqZr/jmrErfLEOUW1EYG
# DATA 5AvjBt/Wvr6t4G2Z0egg7AZvwPpO7KjfMCMPGhFQ/4vVyT9k1lLI+ar1w8vZtLuMpZat+zyWSXvpeMr4f55jffh+uKC2oTRXlaMM
# DATA NQmrOOUA/qgJ9iQjm43sxNJV8q7mkdQLrrIBik1jB9c4cAMtrHdRExQn8+Ltta6oEP2zONtYVLdUYGhWKjLSnk9yg3JRSOQR/ucL
# DATA aq4KNXUG6dlohgEsDicv8poFD2SB35Sy9uCFBJZlabGlYLH8A/X9Ov6pSLG4sjqqSvcma1LMGFq+UI6Zt4QcM7nNygA+7NFrBUE7
# DATA vQUJ4RV6MCAGJqSAJJQs5FL0bkB6UC/o9UzdTZ7oS8kijpnka1hnZJMn6VjeQeZhIiYm0xsl/kXFPpGT1iL6IL4ummXb93wiQ/oi
# DATA R4/aKm7pVAmaSI1tZ+SFL6lQflsWd82wOB3WHOyKk6fBq1Mn8QmPkZZUpFZxwk9c7qAe1OLldNxfBvDjZYLmjMkWDm3QvljWIEJj
# DATA gHwgv3aRTLWJxq4Ova1575DvfaxmfKDenWug316W9hihGqf2ZKQmYjTsd2ugMF+9SXAtp8eAzFwocN983ipPf03J/7BLlN0MvbS0
# DATA 5ecO5gFU7ErNXCjbtAhs81fGFd6Mf0OJsC1WreBsoCY4/NHBqHfmovHqnqImrAbJOTlHJ8xWOf6zh50O9QqAgMBb2nu6NTi8VaX3
# DATA bEnetf388UgdnzVwMALDTh2DJCvwokn3YtU0qG0DJRlatn5usuqQ87DODfpTyDf6W0K6gHjW32G03C9BExcQ7L01YB4kkwQ3wQ5X
# DATA pSYixHBCR1Ci7yQrZqFC1yrFGFWpCHIKxXn07NnGo6YvF3IqVvS3UnSI2u9y6N3tldtJFVlYfPOFB13b2uGE5zINujMVahgyK7C1
# DATA Cec2lAWPZD7IsnHtJjPKsOoU7ZsRRzL+1otPpjBmrSzl1fzJ639Uf/+n11+yKRRwJwmyJJQWtxgu+WuTmUKD8ZPZ8i3Mn9eEnDNf
# DATA v/6/2vDrX775Kwj69HNnwOjigI62yOnK5S5jjf3aBK9+PgaMgFo6Ocptxi/4BfSV8z+3tY469lTP+FmT7FH4p6PzxSeglbQhQYGK
# DATA dS/jQMdN9dVVmGlzrD20QRasAgw/DWLmwmxtrWGiGpo5hNozuU8mOXJQnUi9uTY5msH2eYpvakK+bXc6vVG300nEl03wDEz5k1ps
# DATA ehaDg8MI/D7ae9oyZAxDGrZeWu+16V6MBhPuHo4MOlaoQXVTBPC7OiIvt59SzkHF6ZUY15PmxfC3VlJxuuvkCKyHhNrqLikJrGGk
# DATA TlvvorEz1ZXD5bBxQj2zdZch7C5QF/qmJPfKyjA8LRerqk3d1fVFNobsnrhnYrqAT9VSePY7Hep1lDX6KJ5bfFLYrbFnWGCrgZOI
# DATA LdgNECpt0APsfvTIxbL4D5TOa4lDMYYjF4yw5h00ILl6GwM/JJJRidfNTWZEhp3pcRG4EacngMDN7UVin0bUSAWx052UAIl98Idl
# DATA UHX8hO6Y7hj4Ny0C/+CrJ/+yUWL8wKAxyN8UDIy/JbJxEWEdMwJ7c5+UkzoKQ9PkQ5IMSUoE+ZCwEKTSOuwOpwOHhTk2YY/elqYl
# DATA Ro0RuoBRhq5arDi26krCGYofbq+v7ep8xNuPPtn2cxPXKTOSbUYnBj/sYQMySW58GuPVAFpwBSAcTfMQXtTgP3V+8njr4Xc765+6
# DATA YqfLLQPhoLRLUMLvzU7GuST8czeNVlFAsvIcPLHTvNvvt9mfEsxRw2n7ZgIMSC1sB13nOh3cr50O7LdOJ7Z+qHn/aDg7wQWHP9NB
# DATA c2fjo9317Sf1yP7++NlT6aVFz+mfGlVgUvLd6KhrPrr29ac1fTlxBB3iiFIuqUlx1Mio383OSBQNSOUkfu2cKSp8sv6qPxX2Wg8X
# DATA LaPKalpAesgO7LjPuSVPjEt02Nzrv7OiqrmMGLm14DIRdN+b47KHKD0/wbzqIP1+rgFBfoVp1r9AyL1vLPK/k3TyowN1VMZn3/jK
# DATA /gcJ6+/evo3/qv95/966dfv9u/oZP3///bt3vxGtfONr+N8MPGRVk9/41/m/b15bnuWT5YP+cDkbvozGZ4p1DG8tXb9+fTtLe2qL
# DATA 4/ZQ19K1pxsEV4T+y3hZzaPp8WQ0OzoOxQyp8k1VyxKTdS266t9gSoGDBYe0N9VP1W0Vr4z8U91cjtUdU/8Ewqf/HuVL6F8Bdw9V
# DATA RHMPEC51kYlpTBEW/Se0qf+WN1jvmdNXVzllns76PeoD0wjdB7xLKcKmLoiKlnYHakCRMSHShc/cpoyErwbNV0+TBph1/4pRnowh
# DATA sUq/p17InCfkbYE8j6NqrH/2kvRorM5njKGkivTm015/2Ozn6XR6Viv6hLkjiJ+Q32Mk4nlUtZM+eGWT+DgaYnqnlPCKT/T3rcgV
# DATA /rhLvPRN/rdGw0ayTCMn4tofjmdT/dJM7+ZoOyOtsK9JBF2CfscKRR4ahV/Qmw4Xr4GIjpcTxajHoOEHuekkP1LTr46D2vJ1SO6m
# DATA 2pg7P9CwqV/98QPMPX8PDg4el0OKrkGVDkQ02cGsjfu2h51Of9ifdjrcM9JHjl6ojRA7QCVWv0o3RBNeBn11/Jk5v7P2CTwnRa/B
# DATA DbgwmiQbjwbmJjfltZvwmrJC0586K3TQSc6bo2fqWWrnAEWs0WwqU2HXI1O3rjkOj6fd1qgOqKm3vTcDXb35fnNF/b9VGCxmEIYy
# DATA 8KPVWo0vFunxdnYymjKty/UllhzyaWnTiFIT7+x8HE1nQxgZHAYoEcuImsFhE9cS/8IFpRU0WZ2XQVTFF+5XvA/R2+vTxoejyWk6
# DATA 6WW9xtPJCBzsIruc8q36C97ZGbigubNJHRaYIIYLv3A7tJB+XxxQkDDt+ZPHzqAyoIYAdMXs/Arp37Sgyv7WTmAUJowR8wI+iWOM
# DATA cBSRisvsunPjhpzHCwdp1CyGuxe47F68Rskef8SB4aBT+yBTN7YJ0jT7uZ9T1vctRV19aS5C/qjmH2h2b4WPkS7CtNCaiCsBvk2a
# DATA XDYJj+MhJSFu7DKcqjtRrxqnp6eYc69hWiU8Y9ticWYd6zQk3FYUGrbVBIIEa7cEYAmc1I/Wd9mAuJos4BWqNkpxh22L3QPzA4Yq
# DATA 3DowgW34jyHbbUO+HQSQotofb3liX9NtEhmCNgPdnmcHcrNdu1aYWze1DUaYYsosMYD9yhUl0YPI/3aegcQnXiDC6d5ADlJ195oc
# DATA ZSVOTcyWneSO1JOQy+yl7CLGZ4okiKBBo8ow5h4nWaO3v7yagcbdvvntenRn5Sb85xb85/YFFtMb9n50M9y0tF4oGqI/SEpXvxCo
# DATA PW9hcDNHh2l/kPVayDEi7SxqB5HIWK3AQtSCZpl6tEubN2SkqZi83/usqE+GGSopeWLugaUMfAROVNFu9HRrZxd2BXrX+UFs0Dl1
# DATA uzsZU0iNtT8UczXXMHj8UG30qZPQTadc702b+saCUHRe1XUoAM9+pFpvzqbdkPamtLJ+PqIEp1RZU+eaj78PrPe9lZXWyornYE91
# DATA Nac/AuV7OEzJNMdlda30TTvYYScnezPNdYmaX7pp+5zY/nJXVae/L0xpw5fZRMmhOfjL5j+cpT2Q6UbTlJI/AjpG2h+Sqt240cLN
# DATA z2HxnNsRaiGjsRZHBboC32UmalZngwGCU9cm8d5a4/tp40crjW93Gvvnt+q37l7ElEx7rgz/TIu8vVFGzPqwP0XpvWdxviOaB29j
# DATA TjL1IQbXiJyvnZN0jAIK3YlAQFl7uLvxvXXUrKubl7o7gZ9M/GhjZ+2Dx+uPUA7rn6j7JD5+vPFkY5eeZq/GYD6Bp+ufPt3Ypqej
# DATA YeeYsgfZKkw+Hzt37LFhwPNt7+bOyPDFcHQ61HqBSNe0REgUJwBIqNrpYeJkWnT2RlLcuIMFCHZsJal7JeCzznSSHh72u7qMXNaV
# DATA 6H6bmoA/vr2y8v7qt799887t92+vfPvbq/rWgqWwB4FC80a3MUQvz4h7ofbuDG6wuVlE8Kc9OkPZLDCyDuzeaUcXo0HEwxE9j5Pm
# DATA bDxWsrCFxNL1mRvK5lZne31HUV+1lo/WPoN/Pllf/y78+2Rrc/dj+OOz9bVteVkpW6hctTaagE8yNh/ZbpGbTDqBQ4cB8/uFHgEX
# DATA wIaktdKM3vbznqlHo3njZ9FB1h1BNL4pKI8B5y6iHbcHM7mnt+T+vtyt9jF2yOxuq5P3G9/a7Hy89fgR1H+WR/oM3END10s6rsDX
# DATA eqzINTc4yMOUnVo6YgkUGZENjaKcjLDaEkrj+9lkpBhoOswjCAvFA8tYGpJUNKP1V8fpLEdH8W6X0i6cqN8RNRDxAW86F1zYzA/a
# DATA fqPmwKnZXPXdRXiecU9ZCqPJx0U4kAgXxhSq8FOmZht0zpz7k94i1+Qe8Vys/CXb1nNLkx5hamz98T2LHBMdzqYzXKohmKHyCP1M
# DATA rV5JXq9DW9UaraDbFXvoWQ6OOZS0RQk00Y/U4t5T8vJUXeupiyfpWaRaHRIvSAcIehDlYxD4Ne1Ij9D7cslhxeeWbbXYOVhvcZ3i
# DATA 2tD2NbjAWjmDzgO9iinvhKVB/FgbIG4qYtdYvdm4tbp781brzrfV/32/gCERc08fw2p+AGGSqj0m4c67HU04WmZiwUkAWdgG0Mdh
# DATA OtgBvo5YQCCuYtY88GOqIb9PkgLKVSwsV+BybEaiSCEDU8YhzkXa514nncYFMW1Pv11Dp8bC3IlvRS6vPmKG2Bb4WSyzhcwEMW2D
# DATA R3iNSyVRQ63pywFEQOKsjX5ARvH8OO2NTiFCMhfDsNVchnyPQbPTHQ1a4iywyIVaV0bkIe2zTCfO3ympC5OL1HWMLcQd1myvybCP
# DATA P5+phQO9U00MRWv67ACf6idYUg7VK57ntqiLqqD7plkfz6cfv+HdF7TCm0vv6VrIzY1Gmfh5BgKRhdUabdM3q4Z0VY4iN5edNbcF
# DATA 3VP3NNA1RIaAcB+/hbKNuu1TCfh16+YifX6q+2r0sY6oKsVUDmBRf6KoOsk4FZtLOvko0RDhFBVMBYWlCvdscxQVt7DU7Mr8IULq
# DATA d5BfyrXaVpYVfj8d9V4Tj6SJcJVCnaph8NSfe43VfX+fVF4bVu/W796Ge4NqLllkYWScMalxtb4vjfJjMBPBjiCd8SA7SrtnAedQ
# DATA nsDi8sRYBe47DI6cHRSvb3XD2YxLGWbr4ZsY2GaGvazHo/lm9NAsTaSEIrVZpqii1I5aUfZSjeH0OKP6T1Bzgxw4BRAo8AICCYYv
# DATA 5Hh/JErUzwY9lDKdK5s9OEWy4lIOpKZ6tJZf1kMMrIxz7RuiyBDU1CuHJPEbPS9kRdDbDNwMQarRbxEP279v4+TjpdWAOwfZN/An
# DATA rM2+NvXKIgWzna1bTU7/aIjs6DxXM0s7wVVt5E4uwpzcNhCyyxyeIBNHdM4LuaGA49keBj/aR6Klu2XjbjT56UCjtXTcd67emkyq
# DATA 51qrW0PtEwTWQYABmpmXD84aeu9gOIJDE0AkM3FS6WEGhjFrJpBAJ9b0KX3QjZW0mNdd6JLUsqg92CEeQ+MQyTUP4GjpEJMc9cwo
# DATA L4J9By07kIKXbBkwl5ZHjw4P80yoyVfq0Sp5QbiVaoCtuXP1HaqxrTWH9BMBhf4IhTvzhqp3GRvKuGHQG3xFqJl7Mf5ys7Q5L3Bz
# DATA 4xfFGAAoaFU4iEoDaR4Wo6o4/ex8oGFI1WUODdG4QvdIG6gfphGi90Xq3t0f9WIvhA68ahl+dI97s18MySyqnBLCTPPNROX9fjQj
# DATA Y0nGohg1jVF8OeKYQR9M3jgv/jAbgvtkLdSP5B7Nhb67wI/Ez6SIJTCEGJfE7fOBEopf+KzQmRDopqjmQaiWMnWK9vrTw6Y1spxf
# DATA 1Hut0L1wpetYBd9BQemdgXGKdRroxe5AbLN/U4Na1uH75zy4lj6tvHFb1IcLh2JgEY2LNht6vuwYl0ZukLPpeDYty2dXZk8mbxjT
# DATA ZdQGwBocgC1Z1XMwAm8aqC0uSVTsNK7o2mjwUhv+TFnGk5D5yesR+jhr4Kp65INN9A/F93JQ6Fs7PKuJt4oXQP3JIipVNS51g4/A
# DATA TnAGFxlnAnTQWN7sHqsO1QSRFV3j7dQGXwkaPz3pGG8HKfmKYg5HAvu7cLchoNmHz3Z2O2tPNzq7W99d3wTiuq0TN6IPFJmHI5OQ
# DATA TauI205VT9a2v//B2mbn2c769ubaE1S/aJ1p2lPCk6rBuPSIZHRGjA9X93RtZ+eTre1Hsjr9CfRJTI5xKuCfhmWAhGZ4BvZlGYua
# DATA Y8HqCf2nvNO1TGsXbJVH/goyAYRud6gi4gt49c8xbtYqwIKMq8+iRIM+ASgLy5734r4nacjLCGxDK/+029qnmb7oYIVW8KH6k/lq
# DATA YPqcytsbFZ4XqKcns3xapq/G6ooJ+t4tNjH2D1lvJ+//SACr1clSmbOwsGdFVs2msI2K4MVxegaG2rpU7brWl8Dk8EOr79TewvpO
# DATA pu4WcC3zrb4UHeGuLsl44kFd90nI/vsFAGVTmZS/NOyavrToQqbKZGHeKygBTiXBfpGlv9c/PMwQ5otuBPew0ZGaM+AlSuL1uDG6
# DATA lZvk1dwVPBY897GefPVQ/ynDSVrB4Qqcam3HdYfhht5pF+d6BA4cpd7OWB1uKttl74D7AgVlzsYUStE832i3h1r3qG0oTKJpWuOL
# DATA UgYtkZMtW6YTEVPvYdLwD/UENyrmamz5O/dCK/XArnTIgkIrOrdCxgVIh2nvTD1UN1iMqZztXdcLcp0SHM00qgIU17pdSk/RVeIJ
# DATA fTrnM1DUKbY9zbl56n5yEcsuovIGvQKZbFA6DFVFyxj+be4aw5Oprnk07OkkUz04Op4au7nkiOq+TsJzM9pGy0dkl8ENXOlNzjpK
# DATA 6PFjEOJHavXUcxMIR4Z5IoPFo+OGtpugkjNFWGHM5NQZP5SuxWjMnx6rQwJd+w7u9Eh9AGwO7QtnoLD2u/UQNuigfLwQQyU6w9IH
# DATA KOZZOwwq7H1UivKC6wc0jfjLpoNBZAhed3lRQ2IANlDKK8RkYv+eNmMHyGI5XbdIh9W01rrUBlAMg5e6UncrT4IqER7osFqKXKiG
# DATA aZm7N8OtfTNas75JYF9R8u9gpNgt65gig0VCHujoSAw4HcNuH2CgESc7OlACam9wRnfAZrAhJyT57ac4PM362qu5F7+uYl7lR/kh
# DATA j5e02RDu24f9Pcng/I3NOZ+O7HwE49lhqxsriE2/XBwTqqUv0XVdtT0zlZWHXObms25921dsqJvZYSPZ0fzagVcK7b0SJqkHwGd8
# DATA P8guWRYOsEfBvQMMjpWhzOKoqVJuuPPx2s07d3eePdlBvxZKbcVhEM38OFUva2MP2fQ4e9XrH8HxRDVPhMxjTHkR1e/nw5jMQSgB
# DATA oz5e3NyOBqODWnyDSX+SuDyUKHKPuRhP03XeQtf3gdVJzigLmedUTLu1OWXoIRSwXMdfi7mMLp2gzprMX/ciMd2oV8qx6Zl6DNZ3
# DATA Fr2YTynJj47pqIeHKg5GX18p8LoYxovyEDjUxn70871AcUF2gt+UtOJepRZqiTQHizaAV5cGXF10PDd6zqlJS9W0t1fVDT3UCEpp
# DATA xYho6fuldYe2MvG6rDtKPGkQHlkolDnUkzM0E5QGPhc/0DehBt+Eqr7WgczBGGbYaauoJXfvgPDozsqKkB90PLKd7Fa0+t9/8r/c
# DATA AT9Aum8am2LgTmdSlXAg6dyAznlxlpe8i4hgTHQf/uOdrc1HCL9celUhgnO1G4d5aogMpm0gqRLlS9DbkJdeU5i5BAHA5pU0DMie
# DATA qoo2h0OpZpPy2NHVBUMs/0X/z0+N8fXHf75/a2Xlphv/ubq6euvWH+I/f7/xn1unw2g0VML0FEGMell0NEsnvQjtFfeiF1k2xign
# DATA OGCKhyCKAPqlnFkfqJfqQELxYCQo3vA4rZQI4eQnhERg4jLVURyO9I/+mJPOvX1k6PEge2V/zKb9gfk1TU2sp83xYuJIs5MxkIql
# DATA pV1wMYx0mj/QExPcG85WvLS9tbWrNfUEFmrKNRA5zsBxJEuP1j9ce/Z4t7P1yeb6doe/jJdH46n9KF56trnh1ZgjUerxv2UNNDXy
# DATA U7L0cGtzd3vrcefp9haA57m1zQ5Pl2WGt2bPrxGWaDKCHu9s7K5ftZacBPYna5924PPOB5/tru+AN6ONcDEv4bmSfXHsnd31T3Fi
# DATA 4njv2bA/3V96JMQwq63HPctqKFyMpTW4S7aH2fR0NHkBjL3Jrjw9gLKf6Ala+gA9qtonSgjpo+WZyy3tcWK8/SVgdm1104Ocbkvr
# DATA r7LuDvgLts1h4oMUVa34MvZKEV0NgbpEvpDYTWAxbSWsLO1tEIDr/tInKTCpD84CHVNzoddi/cONT2F29uxMbMJMYJDi/nPIsjqA
# DATA rBL6keKCB7AUz4dSmiVsgx5NoikBWz9vx8IYdgNEDDdREkZfOWia5ETgJnKi75BHc6gWnHquopuOwdezQ7IpPazIk0mt439lniYt
# DATA zfOCO1EgxiXT0JJmf9xxSmIqqH53Ku0zNvQCbqD9V4MMEV1WIoTWxhf9vIPr003zqft4hrkm8abh32oklt1axMW6HBq78RTqUfM3
# DATA zKbSJSd2zJSU+h3aSkxyObWkYPRTlajB5McI8qJm/WDS76kLYz3CWFF82l4xoegEE6mnAn+zbAxfo0UJL5HgyWAqTaIfR+c3b144
# DATA pl1+8yC6e1vbDOHKUBsnWvndp/SZRjQew3/u3rlz6469s1ItVTOmdc7AjrC0a2Hm4UJHVm9+S/ek2uer2QKvr/rqHXD6OqDUvAfQ
# DATA G13ZIv15hGSFP9GemelJf4Ceyf3xXQyqjFsxeSFY7Mz+OHbtnIfxOX14EeWwX6NzLH4BbuQQ6spiPLmWt6Na3O8fogLgHLUBcL0i
# DATA XYKMFBWjEkuqB0hZqCLTBMrk/FLnBzd+TrCqdjOFlhcDM2wRs86LzCPRKeE6wAQJJ2baHUc9rPLcVm96jfgBtlXZbz43h4p2kg9G
# DATA H87XOfLzi+j8fAl8dVQ9JwTdqp7gOLFYh1nFvehwkKo7HxOde9HFxVKEacH5+gHV0GdKWgBN5vFopK8m6tYxmoCbXWN1RV1VwdB/
# DATA xv2+p77SS3h9MLrOj9XT7tTgSdPk9CajsXp+TnsFdNNiRs6jc7v2J+kYrlh1PlHJheqtrdh+9W/tmM3bc57yC9mFDJ1X+vlx1qvr
# DATA dL5dbcyn8AoQB00lJ9k0jQa30RtUEd6Xdxv97ok64+o/L+/SLKkeD3uNYdY/Oj4YTRo5TAp4pMuHaQ9smvhsoiY9009gOOpQqSke
# DATA k3vIzTt3Ltu4o3cZTrJULSbmGRynkO2mMR2NGgf9I2IzDe1/grmk1VpBX1QD6oMTZ25pjezeOKTA/JLdod/O2R8L7IQrr9Q505IL
# DATA 2Xn1fyBnGGjHLuhdjZqMmQMwgSX23tahmwWIklhR6o4SQjfXH+5ubG1SDB/75zqk21aCDky3CYLGPAQ/XsVZe/0j+FCoE6Az6DUF
# DATA agW3fAhbCuggIguDI54STmKU43IQ5BSHo5Scu9DDaU9tOOoolA8nqHZ4Cp6o5733Ykx0HEyc6XQWCumZ2DO9LSCxlmeddDwG2dah
# DATA ybaN9ULPDBwqyb6UaxRZPgYdMpo/bUsMT5z01Wq3mZfByx96E2JXri9da6WdTIITl7bNKbkBqkFVpNvwJo6yguVsY6NNtcVZnWTo
# DATA hvVzwxnQmn3+3MDcN/kGwN1oUvEme/t5GZy8/+lhrCCzIZPfJtr0UNfGM8as52CC2IdUaqMX7++1Vm/qVdaSHDFjotJGWjNCHeW9
# DATA RpalZnFgZBHhlIGTOzycUvwoQXjgBzS/GTxAPqcld1fE1TU1qUMYPI+JXMqqzWO3IvGhz9+3CSxJ27bSIckJuOSRqpuq02c0Heap
# DATA piG1w7iXoTdhkV0/J5j6UMdRPGe+DyINTpnRkOrhNLr430P8b8yXGNF+Uvyioixn9AM2etof9kanNYCR4L+Nx/0aMpGeGbXqJUX0
# DATA dAcjCIJDj3s1qoeKtx2MUJICXQxgskR84qPuJFVEPW+a28nVVj64YFXVLbTiV1t1cRLUJG2OotEpeLqT9qkPjlx4HwYbqLoxkqeW
# DATA vlLnit/1AR4UMCgrJyXHqfCmJDaST7zY/KC3kF3aUESACBN9Nj6apHiWIkrhxGNCBwJwFNMASHTI0UlomtOOjXTauKYEby7bjTUX
# DATA hRKyyUTkaC5E3EuLts8FygvVq9YCBC/ooVs3SbgVMqWsKymeLjrpGOlOh2LOYsUo534LwQcu4jBZCy6UbFTN0tVa5DmCP1fvnFAf
# DATA NBWQ0NqsV2BPW4AXNX7EGK1U5TosL0bb2eGMsFMiLq9vl706qiZHkxQdhLWasnnyAlSDY7D8trEpcgVGyIXD/qt23MS92AhBjHvI
# DATA p4c9i3gKdXuIp9AajZn0Leat8ek1HaSZcEoYlApbxsKLI2ba4Mw5gaOcAr04maf5zpcXcp2w15bQSWkBEZezW9qrIgLvoTHoCkpN
# DATA u6xf981Y9RA0NKjJbp4e95UMGqtnLkKGelCac5sGXfD31s9p2xRec2CgVwRdwgNfAx2rgWDXmakxXMPrgZLEMvVrTnmMyP+jaGW0
# DATA cvNm1fw8G0IoUPTsw08isV66Xhl6SA3pVLDCDKquiwzEpQtRN3zyD0+bO52Nne31j2r6K91XHI18WDJg/7viGN9inHTEv2qdMErZ
# DATA FIpspww9VUCxS4l3/ekmj0dnemEGjFV89aaXm7esjpoOgnb9r9y7mPom76agf8QJQWEw3ltpfBs0fXculhW3eg6uBFRXUkmBYca5
# DATA J5i/YzY84dkhR6U8REgdXZQHi0BcgmrUVJmdQCX5eC+KuZ+Jn+urpo41ofcDA5qNdba60JqXfw1JWBb4Cn3E7KSHgexstSLtvOXs
# DATA i7bFofq46kzEF8lP4XSw2LnK0/8VjKB0FGGvOG9D8J58R2suc3SwMc/kdyZrAVsKrsQDjXkQfIpORi8zB8npqhyKkcJblhhczlTB
# DATA Ss+CN44wVKhfN78WQwVSUJ4m32Lx/z8ObAbqcCXDK8x6qjtRR69pFcX/l8ak/XfIvh4A97oE+w5P0jymKry2FItDsDdH+/jc5/gP
# DATA qZnnLtPnxl12/xSXgk1QNeCTaeNwrfFhs7W8/16iGX/NMtDad1p1+yv5TuJzVH9VsJdz56g4OZUc199JmjpgY6BRdXH0gD6RCGE/
# DATA utZm2gJ3bqIgYDtBT0eq5ua+RpOog9csfuGd/sVHc5ANRhCuNR2pjoymxxjuhToOGWKmaC6IcOH1jC2krrqKm8CzAPl1GMeN2l6A
# DATA se2LmUHxaw8yxFpmB+41sUWViacj5IXDs9iwIvXfRKD8oneDPLhzmS8Og3kRj8JNqT2Hu3ucluEAdLDrV8Z4zbidcZidFZYJaXwF
# DATA 6WSedFWsvmSq5kofLnYIeqLIG7Y5F+jqVTglraVL98ib48N471zN3MVliRIbwc0dBC3dJcbOoOS84ELazbhQXjS93T1xKzDLLIEN
# DATA snQ4G3fGmJyZEIy1g75zduGd9rJyUs9R0D4pkNKDfDSYqeklIJxmk70LSOczzSuY9qFmSNwj/KoF0zw9vhDIUl21ETAZNkJJ3ZhA
# DATA 7E2eUTo8lhjAcAE/9ysCVhG7tG1raw485s3zDClvN0fTD8HDMBBCVICJYgA85PePN79bg3YMr59DoAtTwEKWmgXTzwsJB4UylgnI
# DATA tzODpwP0ZhO7mLKHplcsbKyErExO1424oWNja8XWMJpOdonC65xKzNx8b/fTJAk361fhyFCPNrbdOQ1XQrgfXkW1gjTm1ATTpR8g
# DATA lYKRrcqnLFy5XoNJcul1Rc4rFye0wnxcYWq9s4pg3nRWCVbF65BzYAsHPMAHwlmssAHOUbW1+fgzP0uV/b35AeSUcuhTxbnxgbSr
# DATA kltNDkK6Xj688A2eWuQs8J/hqJZUy9+lKy6OQhTc+YvujgBW5mI7wiN2Ao3fSN418i1xcNvZWwGKJgs3/1DuRAPH7vWAFwqvFj2M
# DATA oVC35elh41sWYJk3V/e4P+hNeNPw/qvkLJYlSw5SFMe4C+w5oJuxvgR67+R4fCbUPsZ4KP7tIMUB74CHCLRVeCvdPriRBIBPjQ9w
# DATA WdigM6u7aiLVxeDMWdY8sK5mMJqjYs+abjLTwiTiF3IW6Su+ah+OQEbWF/OcmXegzUlmYATwt7PYuoQvHihBxkcyRy0FgwaWWBYI
# DATA 2+oyRgXD/a1Zwckb5HYLjZK10IYDB/bwhuMz5RBTdHdfJny3TIdLrt699a3bFo4GPiuI+z4tg86N0/4kx3TxeQjOXTiHMChcXWOA
# DATA DdE3o7gtGR6OqlhgJwrMJ7LykiMW4iH42lcC9QNIOQdwsQDpZzCUMzfRN/lPjw4gx1AHh94BR7I2/ukccQkPN8UsuggRt8iuEKPw
# DATA HY/VI94UaKon0b8Gf086kJHQ7le0l5vnVc2SoD9Qw1A7kT2e86jRwK8poSxDBZ1S+hnQlDvbDw+16ETTSsaFXWlxkxJnkr1NviTE
# DATA S8fYQJsWvYmwxW3sHyqR4Gdhs7ouqFpFgbXo3Lb7iUHRm6bd4w7jHosRoXoW1vwq87tN1XHtlTNc3DvcLnrIJ2FjS7xHntT7exZF
# DATA c6V+9+ZF7He7etvxsPU33qK/gwUn5UoXcRmo2mUy9MfqD26V9gSKRBANDIUxslt1rZkfx0VpzujsHBJHNThUjUW1Z8O+iY8sgFro
# DATA peIO6IDUXkvqwCg5SynmRpmuRJRCh0bVZSoqnRwh1kuxqlxGButOkE5q8Q7qDtWAz2P1eExuReyCme+1biJ+4F7sxaYdpPnx8yH7
# DATA 7kSNbPZ8iOh0Di2FjUjVgIoOMbxBPgGI7KwbxWazmjIwLioBmoEkkJKXxhKcWAClgFtN29S3d6elsWWdDYHIWGiRgIgzVh7y57Zq
# DATA 9YpoGRWC/+pCoMjI+684QGY8G3anM4Kp6B6nk7wd3/ujH99/UEtirzYwsUyzfAw+g9iqqh7q8EpBKxkmO8DIKuemCi5TNSzGMH04
# DATA FLaT+Keeu7EPDq9Ycp77pIsyqT5wlu2bjOf7b1CLQZhm8PvfO78XrR86PJqAzJVCXkIY0H1Iq4RKDf3MVEzxEQzey89y/6ZZuk28
# DATA rcIH3ZK4S+409gEkPmfolLo2DPJlfoknhf+2pJu6jaeqrU4Vv68z+XIAFmxzxmVgL/ZD2tDPbCNG2l/TpHB2eNrR0WyIImVyvpvu
# DATA 0lNwzfJ74PcULXJkokdKQH9fbr5A/qFkcBjB34DfDNqh+wz/NuC6CySceqeO2LS0KHplYlkNjqsTF4SmlQY17GUwi2JEdGU67qPD
# DATA HLy9j295c7VcOFacDyy2DzuQBkUqHfj0PbBFys/xnfwMiuC646d7To0+1CmVb0c3K5TjZsz69uLUmIQrXNULXMEMYZ2J8VQ7DHus
# DATA xsOAJWHGQQPVzYS5ieEkxB7A4QJJL6qQzWATxlFxMCiZOW+hc+rE7Rb1Qz3HSGSTUf50ArM2wVXSfBEXpnCZxxOjRXQp8aXjPnmC
# DATA tL464Xc6gViXXsdWHhJuzal1SgetFYVSRbnYR7lWC/bRjIJgjDBhGgd0Z2Q4IqmHqbgYRB3G0YaEKAS8fhRsCADKWdA3wrEfiq2R
# DATA 0nhRzI0Aj6E/L8Fb65W7kg4BNQ6joxDfAi/rukMx206eomuBTvGUeQEyemn33OIFZHwp+JNbCAI2a2BgE+VpfCccjcU4IRd8z01C
# DATA fy1cM2D1bIXzLKkiWRPMc+SMwVHNyeVxACZr1BSlutOFdEYK00tUWQcKgqayoHees4X1SllQUTLcBwdRNoZQrjdslmRDJkm0lXgp
# DATA AHZSCTfyCEG792yHRoSuFi8F66yFKo0rjz9yjxLBzN3upo8M/MNnWRwi7Cad+EvSnd/bvJVuAbnEJgcm8gm6eOddJZNoRctSsZfh
# DATA qXMpEwJ33ANbLZMNcJgYjrzt5akXyRqba64jvA51yPzJ6CXA5hjNL2F1iQcclOvweQkRUQenGH3xHRP2ZdtVcApmgz2AvgLjTRJH
# DATA 8eIC9du+Gg1Nf5qVbgrTNmwx6nM7kvAJnHWTi0nbcUEcwinR0pA32No8B8EkqZS1ODKQ81Kxrzc7jYgdZYajZQr4bllnoO31BZJu
# DATA XFRhFWdI+6d4C+mBhoi11OIdf1fqseBwHR17J3YkZp7wMI1dJx5fQ+aiTdI0dGz/a3GJ/1OJp0E89yJ5GF/CG2FubUVvBSf2Lyn3
# DATA 9wUHGsOSzIDbhUkIoTV6e7awrrWCqw/7coQ8fcockpJkIdxHb48/9FyjxC7XrIBmexm/q9zkRnVO49XYi7lP9wbpsJTmaaJYF7Ru
# DATA AYK5pCNh/PSKQm1cEAW5oUKTjmHFWPlAsGVjymQ07qNuCdBxmqA3Qay3Gv7UMJDNnkwNBnZpJeQUauW6pItl2LEQgsjPGo5XYAO8
# DATA ApsAfRyT70fTRf+UTn8Rd8L4qM5z6QDfN+3BV+5RwlAuPqwL/1nrj22u2gbiIhCqhfqBhp8xcZP+uOCCElLblPme2NpQxtT9AB8Z
# DATA iM24BmHsYLIew5+oZaASIpFuk4L5knnTgqugRsu2s0NelvP++KIJMW1LxXTkDknH4vXo9sq378ohG858GBvEo+dDg3L0dJQz0hFG
# DATA yKuGosZhNdKR2y9JaIt4KP6EKap218NF0U5ZQOInFVGIte+0MBDxxwypkEQ+jIoNClGrfhEVGcBEIozcvn2LwxcjVphG1yfdRjdV
# DATA VajherU1VPHrDuUGg5yizS/TST/F1ajNDaFU24S7yvNyEbn9qeJZh7FBgMDkVWzfpbS2lSNRK1XsPub+7di9BKdI35d4u+uX/lXL
# DATA IR+xWpeYQ7GBNiXnq3U0DOkU836TdsICm4NAIYBCzDtOTg/bbW85nGRgsln3EPqT4CjT+0EPITxfkjtjR5yKikGUeROimxVT3KNK
# DATA 8AgVsydU9DTAYMHp5SSdAB8FT2SiH8jtkS+YPdaCneWrIfJjNcldit0+yAwUdXwJIfZQiQvQJPHGKkMR9UdtQx3YOOwXyBcwON9H
# DATA gMoRL0SkOOF+grPKPYH3icgJC58FBVdfRAHIucgXTsoMccfZYOwYKh1XB6sx173n8mUXlxq9dy0kQQTH58OvAMIRiAEULuyy69Ug
# DATA iKozqL6mwQUruARMolNbEjo4vFQl07zgbYs6u8AaB9sUXiyONFoq5C0t/VsP+VIKqYNR14SEMwLlYXc4HZDhVr3ssKuhbh+exUWX
# DATA HFPUZEkqOh2aMux5+HB7fW1XOxpuP/pke54TIqjJ72o1uevs7jkN2vZ/3x6DrvvmZV0HYcoA21zPnPQzw3VqHuIKSr9Keg7z1Vn/
# DATA 1BY/AwehcLQ7BNCDDcqZtrASp0Nu99rFPnc9RPTToOnvCvF55RAfHEWiD46Ims1b2FIfAnkMkfGuKHUtFYV6XBmZeQM+lHKXumqY
# DATA sAeaMkXxKcimFrKvtClbYwAg8VJeNtrHs8q95sp2m6UK/bbQ5kjtmjEfLRVe+dfXy7hAXULlymazzZF0KCuqWYtixj3rkv+ir4ht
# DATA 0YvOQVvp1Ksv73Dr99c4KU5a2XnyfXTuaZC9vcLQRkW1shkC7FTq234StGPjx3WbqGZxA6G/WXu+AV2movC9Dap1I9btN8Sf5m2e
# DATA 6g1UsUeqJrJyL7zlJJZPZPlkBnpRxvr9XVky327YXG7DMoqUemEEpquRZ+4JqpfKoveGtZjQqLvTAVLmfq5RqBpKoEPl4nycaiGc
# DATA CdCzOL7KQZV6L3B6bYJu80V2ltckhwxxjNLgwcAwU9X8sKHuVZDwyW3cBsKoHtTm6erqXoeCeZpsHpfJCarRlgLplxgzsCT3jcwq
# DATA 1kSUdX2jr+Gv5vrm1vrmbj0yv3bXnzzd/cw8WP90Y2e3KqFROamkA+BZ3mgBFbmnSFjjPEEoWCZlg07o5VJQBl4D9C8dPSpZeN2g
# DATA HZCOnhiAPfkStroCXUDNF8jZhRh8lP4dYJJKCwAVL4TiozDrvZIy7RxgEpJMaS79tKpYK6WCtdlevUSwxr/zZX80yzsBd/PgJUdG
# DATA paNSNVzKTA4q9M4NVKhdFAx0l42XGYqEyYm/1O4XWLfzyjrL4DqXtGG9WxCQNNJuJfSNUzsomgqymudH46JtQ3Ixg5m6pDWYCMPp
# DATA 4HSXY3S7K/OWMI9A4NA6Ubgl16NgKAZQqP2CBQGrceO6y4HMFtixAvtghKE55xSDirX6aEIyXskCBRX7p/31KF+PNQ8WEEX8yGxn
# DATA D/n6Ar+2MJCKU4UfAR2Ye9xUnQ7MQ6fjnqqSj51VEvje52wmbRnzXZ4f0/lp6V0mbOytSIKfueet5Q5DvbZHpSXOyEWhk6SiM8q4
# DATA q/DOYslsqDf5VUUIwk2VjrmBQO4Cy/XWXLDbwl3dvcYarTgCPzYxwigEN8RbrjJh48LSSbXlVYThyy76EqycNE15GJGXpFF+VAa4
# DATA 6qur1fD3kJKUD7BSeJy34AFKt+iOK/lUYiU5eeEwBdyVksPhey/RGEHHOtnRUIyhQeO+4/ErDoJQBVp/EfNx7DXovKMeBPxPG+yV
# DATA St8Bj4nrwu3Z/EClEsZV9KeiEYPjtF/R7QY3WlkECUtjTJ48xaRxK5Ufq7uY/ykkdgsX7g9RiV34oKqBgkKmbKBOBJJO9UZlQ/ne
# DATA MDObRi9umyUoXsOR+1PWbSLUezdvYgpwzsUtJICy8B4HqghkyFZ53rJ4m6UZL49IoMtyW0lYcZKMZbAffilkIVciKKCEsAu/FamL
# DATA Q/L74u1pGTnvxMd5PTH5zCnkbIHG4Orjni4+dK53fnF5sRD5iLp9cPyC6btKHdk87cl8Dco70aIEdBh65zcdWbpEhC56Yidv6Q7m
# DATA zh1jLu2t7HvpAh0vZYSYxJaQJ62YCq0COLxldDvFU7jgjvXIqMXtqLwZhZFZfZsPoIcf9l9B6IHqcYMWVUBtvBwBxD+o5ZbRVjlR
# DATA bDyP0u5klFsE7YnFDS/cZ7+GO6Zu9tI34Cv3DeZDWLocY9mi1i7HuuXhZkBFZeDI0g7EsEdhC1BgJ5EkEHam3KPAdRA2TQh7LbSB
# DATA mTdqHOJDXdwaDSCa0l6GzKFDbYrkT955MHfWUiaAJvY5xyNMAi+ldvAJpEk0L6hVZbC2udX7IxFXewxycOgQ68sqyVhrEcqqvR6v
# DATA nI5PVlZtxxOzBAUlDm85Gqp3w3WdcevhYJIKTLJgeeswebnbLj5P5mw5FHC9jSbQv0vpvHa/WJBwv7tNXKr5tQfTX4XKQcxHLyub
# DATA m3K//AU0vyXnn2417/rgz1O7lWgESAwv7GkPQBZDA7CIUabsJ4lQ15XPU8XeRJGz7GLmbSyZVaTAJ0wVC2R95kTP3/jD//4V/w+9
# DATA tOCcf0W5n+fmf15dWX1/9Y6X/3nl5vt3/pD/+ev4n5+UWf/Op5fLz9wFVUsezNZ8nOaQiNn8nJ4MLpm3uR49nU2yp4B/UZLGOesq
# DATA cSoPpm4+M49n6nqhyOLDtd21x1sfdZ6u7X6sRS2rcLcm2dicjY4SvdLB6Ih8CMFVTNehcxbf5ITFMm/xk7XNjQ/Xd3ZtYmNwVMVX
# DATA YEJ9vEZP79IjjBzTqY7v3i6mRYZkCKJ2NLtubH5kvlHv3Rf6w7u3A50zpR6tP8Vp+NbSzq7qUWdz7Qk6cjZNOhNiuEt/vPVse3Pt
# DATA caBAQ+S+4sJ4qQlURW6J2+sP1zee7poCtqaDtPtiNuZKth4/6uzsPvsAMGni+9d6I9xkuIEe3If/RoN0eNS+ng2vP7iP6R0RCiWb
# DATA tq8jRJ56ikFeDziG4f4y/bw/1k/g8mM9XO8vjx/cX8bqIUJh49H65u7Ghxvr2xT+0h2djPsgKSC0kcY1Qlij2+9fPP++2hofr38a
# DATA KHuImNh3b1OZ3a3vrm+Wlrp1k0qtf7q7vrmzsbW5gyAWTegVRqx085wyetI/+csj/Hf6asqPUTCOm6+4/Gl2oI5q/1AJW/GF2v3d
# DATA QZrn0Y6abLow27uz0WvnOkSqU4RR8yHU5sKnVUOnsXLS9CZ+9Ozp442HsBH/eGdrs/Pd9c8cG04YKM0FSeO+w0wQImMraNsT+iLC
# DATA Tzs4mxbcQBioLgi/6IVvLYDH1hGAbDqjo0R+4gsNjPxRJp5uZ90ZhjvQOgU8OQrzuLH5vbXHG49wFtXdFikrfqOnB0mchyboBfvb
# DATA LNiJk/sAYvQZc1D9Wv0Wqmvi588x7AlfVHTs2ebO2ofrnbWdnfVdJMFx4mAbS0IvM0jB9SsMcQyXdsKcvKbRDjUygQE9BniCOz5Q
# DATA 0Nws0PsyITQe9G9jPmioMghrBC9gEs4p5KTZjC8o0m0yFUBTzXBKSa8bte+0FKv98Xgy/HE6e/Xj4WzwY0Uv9lZVt348GE/xj0QV
# DATA et5s3ki+w72C23Zzo3glO+ReuFDQiQnDy2eHh/1XavuewjVJazQsEUqusKIBzMhOb4S3jkvvO2dZee89iG7eubXAEXi09WRtYzOU
# DATA j8cQM6yxOYF872NcH7VadNj7vWGqfuqzn+bdfl/95okqg3C7zAnV3ZNnVGKkcU53Gm5V8nLes2pLSNZ0d/VCv8FdolidtLmUh47B
# DATA ZENZS7p1yoNmnCTJZSc+SKNBVVvApXV8sN4B4Lne5HAHNjU11U47dpLllu1rCum32/p/dAB0mI4jJSxNFdmEF2D3nZL4C8/6B2oq
# DATA c9RYgLr91e2VlTksGydo57Mnjzc2v+t6iIbxyauxxOc0JhdlbfOhEq+3tt1Ga6OcHClB5YGYeWR5KW8y6KhXibxehai+yGx9sr2B
# DATA flklQ7Dz1hbzJvxHc4w6fPvZxM5sbu121IfrD1U/Prt0R9Bb4urQ7gv3UNX37PHaNl53StHZO2R3EgjYTEEkpbGK6MJRNgeZYy5v
# DATA yAO9nxRSv9qTG1YCd07SF5lFwLeA/YgkdudO+WlBQmWrL1ArrB0HJeq0IwtNjdsVGqDYJGjK6tBYLYY3/fYc/CalDko4X8L45+b3
# DATA LHoiqbNqlwyPLWdHhf8gU+gc9trUItVTXEken4/IX74BhIMPpbhtexD7mjyOwNPNWv6IKBZef7CxuaYODrwM2QQ7Askfm0sEpr6S
# DATA OLL0JIAba0LkqMSCyPoaulUcOfvIjX+zz+dh5vunEbUSjzeebOwWUfK5t2U4+enhNJvMHV0ITR/dq22f+8NR3RuC/H0CoQ6dIUHL
# DATA 1rBV85X5RR+Zn+abCpEAx//w47XNj9YfFQH6S2I4nTPV8jaxycPrmMU1C7tmWFjLDRB0rbTClBje0PjL0Hjfor1UmX+CaY/evEUp
# DATA OnS3gJxxKHztrbY8nEmNuW/bgGsLVm4OfCgutDQC0rmvy1FgSyGBqzL+VKsHrsj/y6DhLyMC0BLbzl06HLRAcwI5p98Jva/IWiLa
# DATA TeZHspTQ58vZLOduj6JlUh5hd77FG+c4EJOic1ZwDQmyLV4T0A1pTXItpJQap2dQBrgVAW4JRbUTB1rQQFenfVnkNkqUjet8srGz
# DATA s7H5UfFO6nSXYa/aut++gszibzyfEG63i4VishLrZkFXBb8LLA4bkqAHOoEvawe4gAvlTcn78AUCnvBT4H9zuJy+vzpz8kj9K7G1
# DATA VfFJOsAUo9DGnoD4NQjgjKYDiBpooQWzCrmK1vh7Ppdx9jIdxEkF8Katpnkw6p3VsaqHI3xNUJyYCsQr1nRTgyhu+w6GDvyNx8Kj
# DATA 6ED3/ba9PIvjSQ0+JJBP+uwd9GWSnmKW+1dTo7GR6tmwknXnbDhNXwV1q4oPq2m8vJo10MeAPgfVOelpwngDzhFe9GxKwYuFLlJ1
# DATA Q8UlCjXSR2OmDzwV2ZSFq2tgW8i7x9lJqv2/c1JZ4m6CQnv6/b6fYcZ96x2shWZKi1Cj05yV7Hvch/2SkUBRAT/rqKThHWqkHQvb
# DATA FbsUMHOo+vGOqJpxQVmKffQmWz3hue73MEYLzFDkp29CBBBtDwJRcf4LXKvYxh5Utu+qSa3JSqoGdVksZn5ZvV6oPa1k9NoE04uX
# DATA 9YOfNkl5anB99XPY7Cfpq/7J7KQMqF+i8nuA/DzhXJMxNukKQftWM9O5qmQbQC90Z/XW3ZVkP0muQGxk/C5j+eHs0TJVwSRzgLfZ
# DATA BPD6lt6nFG6sN6q1+16mh/iBE1886CFiG2w3N+yY5BURgUR4NcEYJLIKubB9eoTqYbOr5C9oCuLvhrpRHp8YPjdmN0r8/NXKCqpl
# DATA dT94l/BPn3gncxBZLj9BGpvv/Jy00hcXTne0YI+jFJYaNLsmi8r0VHVHEZ6H6x9vPX60vt0BcM31T3e9ntDMQYRJzZtXV5UZI4Y+
# DATA 9UIbZWgrwqTeXrkdfhWkHudxejCaTY0lGX8tiwYumn1MAJKhIZ+36UL6ue31f/dMXS4fKUn1o/UdKz46+Cs5704vLB884YbgxQg6
# DATA IJSXTdim2b7uE30fGXrGQty2WllHOnBbJ9ykm/FCowFxW63b48cbYPoqmp8NBd0nglBq3vBkfZ1H71yRsJahapqokQ9gBX9ILiQX
# DATA 8m4TJOip87xv1WHoz0jMCK1uBQs+TFhLHwErrYsjUkdnC41pSNXUox/ORlP2500MaSgcGhuFnQlsvQq6xK6WksRqKsUZN3ivGBvg
# DATA fLLhusWzGUvPFfHn2UlVhdXfX0GO217fBLogxbjQ3qHlQ+8jM+9qLtQSTbXClh6D/MdWVV5mKVN528Rgp3NNmnC4Mk3A6PLdza1P
# DATA NomyasnK7bzYb/mern7fbD1j8DsbdqUiTOi62gFd12I6imr1Fe2zy+jDgnrnoOYCFUkwpJDCIRgTXKW0keG4JLIXlDaX0GZ/si0H
# DATA 64S1rH/68PFXruZm1Q+Ew5Qou1n5S8PGC4n/6nAwy4+FPGPmu6A35imk89tzHAx4h9ZEsAB7GGTDXHGQDhr12wzYD1SoA7AwnGkr
# DATA z9QuSNUy5e1aXAei3IoTnRAmKdw6uR/qg5N+l6dDdqZk5eDEjCYp5pDGXSvcEIWjHU5VA6BTwZexCf+5rYj/ccZ5hXgLmdrq/owE
# DATA 1LcVmrfFj98cNSGvnWYxon/FdKvhcPXQ13y0xSnPJ92Oc3bVQcqnnZLjbKlRU74qnFsmmNRmiaGPg/FNObMT+EVQ+e9M+Luzvxmg
# DATA u0q7m+gYz15YbalOGtz9TBZPjvmkUVC4ZCGTMDwuzyRsbBeTrKvufQIjfTqaok6NgjQBUJPTa3FD6iYn8mfx+5Z7C5pAYPkYySQX
# DATA aI5H41ribXhd1g1LctiIY2OZw6kKK0j1lx6YUp5F332lXIszL1OjOmuz6Axk2hW//GQbPLLi0IMZnRfL++zlf+aNYdI/e87OoHzC
# DATA JX4QFX2ZW6W+TWGBbHd7vWjO9M8UYKHjsKNlGgkuUHgIZGOiUpQaPZgVOhw2lSm5qf8y02xA/+5MRzXGg4SwLrX3aknZBFY7uuBi
# DATA vo3/T5nVJgw+YgeGK2qSTsQ2NLduRp2Uf6+Psv6epSTcBWBiDn9ZDn2ygM2pxCAoAGM9V/sG0a9WpXPdFTehpY7vtZ2ulJbu9Y+y
# DATA HCg1x1808+P05p27tfL6vwpniCDszFs4SIT+dwmniZK1fYeOFNfc5UG/Bf2gPxzhEXT8GOQX6mfSmuubuYhbQvk5tEkr3Z5XfkYM
# DATA 13w8v48HHGovHUJO1B0VktDfrduakvmuqLw+WGNroUyvbzNB9ug0Z2Nwq6phw/M/sjPbID3vAt+RkspM0OpXvPiLud+UdPRr9755
# DATA l6MvsB/EmbOcpzgc3gPqakV/1WQAb/BqXyo2XcJRgSVkj2SbS5xWkbF4lCSyf0bHgmgxrpLF+EtLcErHizoE/OGJ6465UfrbFaPd
# DATA Elc5hHlHVK+4b3TX5+6G3pl+165oyXzRH5ImlTVRqExFVZS1s8Frdbcp2tuuZvu0j7FxfOjDlSH+QChluTfEPdvxRSx8/ieF8BKj
# DATA IcSCPBH7OGvuo4AxhwqwQtbOfWEIxr7lfBCwc5W2gavhjffj9U+LA8VyC4UgkG/6rlVXWs0zy0f9YeR0uGgYCxnFAjZ2rK6y81ji
# DATA UoZI2fMFHA2B4SjyoKTiwegMYMtCWkP7Vt1lTJymIwFjhpgJhl0GNnDj5apO4OQqkqT+kqoo+CWtI/nxYhiKcRGeO28GCfKwPtyy
# DATA 9PdlLYIw1LgQWvE0myCAIvt/lIAkh9nOB892Piv6eTi3einbSkShKqE6oKMLzZDURgyncQBMkqKeT/KX3cm08JYeY0CuklmczBT8
# DATA 6rHaGR88hnQeq4to6AoQVc7VYpEkGGpexO/NDwqLVY1kfZlFunqmjY7qC0JP1wbZIcTb9Y+Opy6jzc/yJlBiRWtOnFQ9isHOXsVJ
# DATA OAk0AVT1D1gLTAH1zYePHj/mPAWzPOtgYL2A0jmcDRn9w2wproIwH9UGSac31bbCoCrdSfNVZVZqp4FmOjnCHmGye+pbt4MwjuYX
# DATA OGx0xuLBnNcz9X7fbQUwYSDGu+1UUtSPwtzj/RD+6Ghdr35LawKv8a9OQImqW6w5FaBgzCp9eEEZDOtONW4pfKOL3aRU16U5hhns
# DATA uifGp1aNFtUa57AABJEaxPWdz3YM3DrSNPNr6+nm1u7Os6dPLyrWkA4GH55aF11UQfOn+Kh5Yk0oCJ9PTo2gYMmn6nDATDnaa/3e
# DATA 7kTNXEx5Ty0s3oQ0w2F/inVQr6ztbmxtkq5lR+SvXfiQBc7I3MNVenrmnqDgaNZ2t55sPOxoA7Dit51nm2vfW9t4DC7g0o/nazlu
# DATA ix65wrGjZSfFDP5ZOHpyw0Ax8btTYjgyR9GrUh4zduTlc1as1C0t9xp/surDotrgyarjWFzVucfIADyVMmi0ZaFQGTpmS0UWe7X9
# DATA ROYtnjlpFPBOI9uTrmlX5qa/Th1t4vY+MSSDUDsQKU+Il67h07idEKEQ4f1BKEIyNdjKdC+Xo5hay2P42wilcJ1z6I1ury0qQf9H
# DATA eg5iv195zoYFXdp6fPD7BYOFP1h7+N1nTxHwtCr4mbLPFIT1sApgBOCLYKlT5A68xdBhSnxbsEQHVQOT9FRfs0vuCM7twCLCeK4e
# DATA VTf/IjK/yPVr02UYuH7rsNTNlKTlbKB00j0Gu0CrTP/ABVRfJaZMhUbiHegUbAeNCqHO2HRfty6B8XIKKgW+1NuOYg3FHVeGiFEN
# DATA xuBea/kQO45Se/KiXlRH6AnBKdsv5IqtBbUDXHq+eoALJsniGgI6sbGUZOzOsqfAuSRT6IG/DWXhksMRLJ0EElmYDevRAvD0l6cb
# DATA yV16WiSfKLZYJQ9PzDypi8mXq1QtNiH4g6fCs/EIIc0FhUROwK0mcw674CL1aDp6kSkRcjTo1aNhdsq4inVmURIjQq9DiLQt2awD
# DATA JV2n6GPRtCPmCRZhkYh72UuYU/GN+3KhWynNMerDPtvZXX8iZEC9PZwm1GapCZwscAHCKRJuDV6AN1eDkeYrK240TtlKCjVOeEub
# DATA IJNgSZcGG621IaKtaFXT0VYlPasXhC9JzFoBSqYpcQu3TPFz2vut6G2OksxuQjKR5k96n5GzjMND49PTUwo7g02oyFZ4p0IB9eJy
# DATA scfMEL35xX2h/uYjxPIS52oBsUHudsgdMejxtCl5KjtVf8OBc6YQyuy8gxn0atWLwmc7psMND/CPCxk3ZXYT8mbteuth7N2Ibs6b
# DATA QfOFtLZrfz1n5STgHTlkBiGESCY67A/7+XEZPXP0oHyDEF6u2QFsfl/6wp0jMyoeFYo4zoFYIkQZRMaoRShKoemg9tGlqMi3affz
# DATA aBIn6QG90h1BNYmqIRAGzMn7qFxdT42vf1ysA21I3nYq3uAMVTRuVHtcRZ1mPQlEK9ONyGU0MuKQF7lu918hwWCeB3PMzNtKVM0P
# DATA 1AkZoq9c6Z6VKkkuXjT/6RdXtgByBfWS4/j2YjeRM5eOMdViglUX9MlI4pacvDuZfAGzHXbWE1IR8bFoxaKiSVh2F4Pd18j0cheE
# DATA JPfiJTokTS8o0Icx5HwJH1Zhvx6ZH7QIAZE/OFuweAsI9Fis9BJBi7zwLYKLm1aDsVIetJqlkhKnM9bj1nVe5saxu722ubP2cNdG
# DATA GGng85BB3F5qUCotvT25VweuiFSfi/ANd2MuXUYYDXwq2I4VES1nmcv1sldjJcpiVKPYB4X8086iMzY7XTzh3OhK3nJdOouoR+Zd
# DATA RLqzCeqw2m8lQ7Gd6KXmTtCmw/fq/Nsuf6INk5DtCcobfxJMmhCezsI1VHff3CftebepbQa4Wey84xucmbbuwFy1P82rK+pSMkhB
# DATA dJaqBJEqXZLcHY4YcAkVAdfVM3NvJBujYC0lTkIPPOkfYQCXe7TcT5dco3hxXFRLUr3pL3nbt2fsKHPkOL28MOuUzIonImgHMTci
# DATA Hqm8DYX7eIV+WrHRbaUe+QfAF6XDxwTuG94o+QNvV5eP3W7LwPUau2obDci4KN8GhFHRUx8IrlQcLZjqqX1Tp7txL9FJQYHqxfNQ
# DATA QYvqwSODY8Z5l9ttzsSLJarQ8FxmKIEBSBKIHVyMq7Bt5uHW99a3P4Mw8A8fbzzcjZMqumWGO/94FYdVXMni4pCts4RkmdNu+oSZ
# DATA jvjjudSycsBfJ2/kAtcMw3FT+pZzsYVwTgO8aX46Ph0FZmWJyiPK2ghbmtWfSanwI411OL9+S7oHfF2TFkJ/KfjSd853EFYaafYZ
# DATA 2rtWvxPFR9kwm+CWVB/qc+LpfYynYssIbMZ3cY4wcqFvyeqSPO2nA4qQ1qfVccPhh+VxaMYlIxz1dZnYZKNzuEx4su7gO4r1ctQ0
# DATA Osbi8uFdZP4wDILD/MHlKhS4ddifYJDJEBIxcQnfX0Lb+bFoedpfb1H8Ly0iogTFgGtjselq7+uCg4wXukXNLRq6FQofeUvA5SJU
# DATA 7gOyCTqRJdfI3VZnyUgWHGhBm+csOEhPYn4LgVGs3zJksaKqUEjYYj1yDM1lHXPGjko9/augjDO9rRfB8ZK3HUEoXHiROIAqH0MA
# DATA UssmL0O+vC4En9YZ+EzVtS0ulUwGKymTYoUiRJeZAbyZQSb42HQOdGwko4IBgePnRWAfMY6ANeTdsQOf4fAzw7kky+Csp4ypIW5Q
# DATA Pr5GO54oojk6wfgQjDnX4ADioiZNkJVIHBA9DgpHrsrQpoPRaBBwhdedsGox84i8AKhr5sYdDAgwSCEL66MAwmd9xwDL2TVzHHYc
# DATA g5s9G1aVE3Ax58uYLb2o6tqGfxe012pWQoprJwSdptvGuXBt8NuXDEyhKqlCEqbg+cRS8irfLveMKtiGCCMReixEOecmsiTs1X6r
# DATA JIuUuf/rAKiXGat/FjFWmU7p7/zLipjkIPVegGQQwkaBYpi7VzCcS5IL0zs3YMalCaKQeL4vyYQows/2L/xYD7mhrryBFttEl1I7
# DATA BvhA6JoRGEVYhVouNi/eedLWBfYvSVk0RfAWlMPnTgNloW97+65LW32xr0ykX4XwUPc/N2+c8L/SDlRuldA9H54x8pIzGVeZ6gqg
# DATA J0LbHvW75Ebc76kP+4f9bIKmHPGTEaB092vzN4nF2wTJFJ6I6trtIh9PrCIzzwZar19bkN979Ib4Pyf9a9IQazxSgiQzLLMtWCZ+
# DATA pd84N3fdoyAc1qUhsSRgpIOLpdsRuFg2tv9FBhKEj+tTsP8HOGylF4Avw/puQqwk8tJRXBY4cppO1BUH472hm8tRAR6DORcVbPoY
# DATA JRK8CEuYhn2/VguKdfu2218G6LBIcuc8thsS44chBBVZpZTdR1lzcjQYHdTiG3GSXNQBi689SE8OeikWa/mZxOo6SwhFCoQ0sT5C
# DATA yjBjtVfRWafCGcqJX22ZTWojWVtacg2HPXNEY0sD/XlErgx601G2zd8HF2WtszuW9LxwCKXj1GNmqMSzZxHVXNCzxzFDGC3NtYAH
# DATA yKKh5VLXfVk3xo5jnxSPCtkEpfTEVK8XCykxyFuQwMV8zwkKWwG/ujLhq2zzObJVYExWqtIzJYUqjW6Iqb+LVzEqWDeKw45trfT2
# DATA FQRLL35d7mUQKL7wvemj9c317TVhLv5Kr05XvV1YK77oEZVKvLgJLiqiQmSjGvR5Qf8IXRkG4VwqeiJe9GIDnkWl98jEuTJWlQv7
# DATA P1UB9hg/gc7T9c1HLt6ttWaUyMCXUdwUDReBDYvjW9AngmtaaJx2fwdIIZujScwpt7iHHBFpXjy/EGe8prA2CALf1s/AW5Za1AN7
# DATA K1s306Nex1uXoKc+X4up8fleODYeSTbhL5L7Wq6WHrN/OfB67LQ3V5q00ViLsjDeNNbOWPf6YHzznUNfzdfo+7dUCrgKAW8anYuF
# DATA N2klbslYp8Pl7JClygDBoAusDfV/SoR96eaxVPLiBB2hKM96c21yNIPJfopvagLouR1vEAOPDmbDnmLjkSJ/6SACIqvZRY6EcTSb
# DATA RjhvoNeCnAjQ57xpEupCzYAx3km5sVrcaEjcNdBLtp8aNUHZFyRtVpYROCtqElI1M0aJWvkdzV5jQk6di/WHJSBgL12aMBImpmrj
# DATA VLcGc3SFz3jbLNxBTZ4bYhNpPowAa/wd/gNf5rhhkmCaanjdhI4Xzj8d4OKVH10p8DPueMEpB186WRytuV+9CbEXv4wWQ/VvVoFX
# DATA 2t142BQta+dVjeWHM9WZPBK7E4licCrrZu+brQC98PZpYZ4ckdOdgLozW/XSSeA3QVVp0Yo/f57tnC02X/7k8PepncJeNBuquxnM
# DATA JGwZqHqWK6paMieORSQ4J9o0gj+saUJugapZGU/66kgI4GVqehHk5aTAOlbmmbECuCCFDpzHWIKZCv4Nl/5if5RcDPfcNuAM5FN1
# DATA nZ8UOrSqSL45ribhDKjabJIVAdlvTur+UtiK6lQBQP5wcUX0oU4HFVmdDqxGp8NeCNA1Jd9Oa8hz1IR94/L/A66C6691h83x2Tfe
# DATA 8f9W1P/u3r6N/6r/Of/eXF29dfvW+/oZPV9dff/9O9+IVr7xNfxvBtgRqvlv/Ov8n5977fw6qaeut1br11HUuN7aO7/e711vXUfB
# DATA bqrogzoq1+vXMUuFevz6b9/85M1fvP7izZ+9/uXrX735szc/ffOT1z+PXn8Rvf6d+uu3b/5UPVNPXn8Jf73+/PVv1cdC4IEq/k/1
# DATA +p9e/70q/JOSr+qR+vcvVAu/efPXqsjrX8Mr1agqqqr8FbSm/u9X6umv3/xMdeOn6t+/UR9Sjar4b9/8lXr5i9dfNFXzqMK63jq/
# DATA rnOoqE7cv9YbIQwEJr148Pz58D78EQ2UhNV+/vx6NlT/eXD/OEt7D+6fZNMUMxTl2RReovYM3+MbOLTw+GU/OwVYJPWn1qDB49N+
# DATA b3rc7impsps18EddWwIauRL2svaqret4Oh03gL6/hE8fUi2NHchb1p+eNZ6OBv3umdcAC2GNfNKNnsd5Njh8Ht+LaMr9h9OzQeY9
# DATA 658cOU/QVa51Lxod/EAtP78aKqYFhQ/SPGuovohHAMrSIDHLPi3OjtgEXv/Xopf9fIZS7zQ7GI1eRJiuRkm5R8dwJzlWjOR4NOjl
# DATA yAqnx0oyThVbjPITEJzpMgEJlSPQdqvnii2dRFmag3liOgKm2Ix2prPeGX47mvT6Q4BdYiRZJdCBSH0CgJDYa9zqD56CahvEm0Pw
# DATA Hol+HP27WT+bRi9HAyX63V+mQvfRX2eSDWAY/S6NTHX3EH4vp7naL/kyPG/mL4/gHcqUUPZEVb+sHr736mSArcqacJXy4yybhuqD
# DATA JWh28/ySn6GdT39GSwEQ+oUiP4ASINhnkwf3l6mg+gNPAhwTSPeHWwSVQPC5JBVYuzosA1Ul9ulFfyx7801gX1BoR72A1eF9cH85
# DATA pdMGrYrvD+Bi4QzHmvagGndVVB3D9KWSUfppY5Ae0LQ8AblJPe4fpbz5oIWS+rZeZhM4x1iXKJWr/dPPclNuZ5zCAY74uV8ctqAp
# DATA uw378XQ0eYFrg0WXVX94UmHAJBr24FM9P/c5NZOdijHYeuALokyrD3aPU7WEY5CJTUCb2uLqbyWrDZuq+tUH98eqWBbBt+p4nEXH
# DATA 6Uv1x+glaHch898xHgBI5YivYTVQzISdOmpG6lt1bUZ3OCWJq9M2hSN2NprB0sHHWlGlj65qdfzgfq//0vabSEPu74yD2XTqHRh3
# DATA KT5QQqZu5iBT917A2+WJ9moB8+Bo2FOn2qlvkUVbVn2FfU6zHZh2fkCTfvPB1iQa91XHZmM1SYq0HM7UpIxGA5jumzDdD9NBd4bm
# DATA yMPBCKX/LCX/7gipfdSbpKdAccCvD2ZYrZfZHFFvlNFS9rIpoBWqG4SSXWdwtlTHwe6LwDUIZNQdKRG9D0pwmvXL7D8z3mXYcA/u
# DATA HypRHnbi2D1RanfJqQCtL90SoF6bO0rVpwo+0GvvdMUmIoNv1pCy/1F6Mr4H8vrLtHsGHYr+33+KLtV/WjXd62UgSnCemJcrpm+b
# DATA /QO3/wO3n8ftaVtegcm/Yx5/NRY/n8P/D8Tg3zF/X4i9X467fy3MnXakHL5h6P9yThAS/Pm8U1H6UZ5pDrqm2Sap81SLyN01/5RD
# DATA BrkmtcMcHXIApBq72laoVuEl4ino9ifIfFGB500ETg+KNJoF56hOG2TpBKH8TxTTVjtrUEcGrAbRP8l60cGsP5jCCIA+5jRk1dNn
# DATA OXyC0pbunx4BtGA5elfLA7kvEJA4MBoOzprRxlTLcF3I8w0cHyZOsS3UNFuzthYF0h5wGFQvYhdhURooFsBZz3PEMYp2suxF9EO1
# DATA V8BZSxsXjrPBGHVV0MkoPTyEVQKBJD3MpmdmhJ+NZhPLo3loStLJo8lsaETNA3B2yibNaJ0TDcGUwjhmY5BWQM7UuxD2eI4yjCoA
# DATA KRRGICQp8pBDmXRwNu13UbpRY8smU7DxH6khpOB/oV3boK7ucdZ9gSpPNO2g2tPpzH//yf+W81hBy4t+QXl3NFb1oDwp1qwZPYT1
# DATA j9Auj4gX/x9777rkyHHt975KOWRtdosABlW4d3NGZ3iT6E1SNIcS44SoDwWg0CgNgAKrgO5pzZ4IXby37JDjyOETcXaEI2yHI875
# DATA TmmL9lgXKsJ+ge5X2E9y1n+tzKyswqXRPd09t5RINlCoysp7rlyZ+f9Rwk6RchUWnkBUj/GKaEolNdKBsseV2noYU180iSpsB4Ji
# DATA AkNZ8naWx5zaxIILm56hO0yOeHwwQFWs+b13k5OZmHnISNlZNqAagx1rpahJPZVbMhjhFFVq5ejhBpFU9HGSSdFiT2HKJv7DKJrn
# DATA jTocDGD7TxI0hsGArx8hoBgKiRBe4syk0QPhZDXv44TvW3Kp0e1RykWGvDQtCoHOEeFxpDsJqj4fobeJF5IECtpuLpRjS6rcXM1V
# DATA a9WtMnpExiKSeEKBmawY8eSlUJAfUIzNxqUM4h7YjTeUDsbD8RIqoTTW50qHIaJY895G5yN7D1AkKcbFiPoWVV3pPTi/xb9JlVLW
# DATA /pWnObsNNjvNcHY0k2/N2L+KrX8Npn7RaCJ7/zuP+8kjMl9+BnxNn2tpla48wUOPyeJJJpNqP6K5cJykB9mUgh4/QbiPp2FKteGg
# DATA fogVjqMUrp+D4zDdq1bn4TxK9w8HyYQekUtkl+0fov868DvzR3f8WrvlyS8Ia/8Qu8ypyz+pnqTh/KBPNfBhldI2fBI+lmDiGTWQ
# DATA eHEIbf/qEltHydaLqsloRAk6qAVBNH0SHowRzmO+ZwgWCDeSKlX+wcMZtd2DYP7oiVSSSjybLxcV2b9VwRMYax5zFNW79J01+ft4
# DATA GGc0DJ/Sz/zq0SR6dEijxdGsylv+DgYRMNGHP6XWGY9Oq6p96cs0PyWjBePqQbM5f3Q4F+PggHKC+kzPr/n4eyglcODPH3kZTWmG
# DATA npV/KxmNzmO2KOY0pVdfVqWZhsN4mamf5UuFYiDlUT2ROLVb9UOaSmUUzjxh3vVhKRsPMIFReVIzTUznTn7lsRVN6qZmmeyYWqkO
# DATA Kqgfs4WKvdxZNLyLReefPF5JKCffDkCqmArigEoGo8rwcTIPBzQbPKi1Wjo1ag5IlWNEBkJWJXswxgikHi1e5EpRuiZVpHRRV5jy
# DATA vcspNYvT4tXH1LRRYw4apULlu6juy8+6LlPRPJF4UH+992OeIvEwTq3yJ/vWRRRl8pP9lTrMM+kDv17/dqHStanSbahdeP3+7u04
# DATA r7qoubWOVXF1ZWvoRJTiX7EuSvxVdANqmocqqvxZKnF1tROhZlfNxil9Oag/KQRHtvpPHuvI1Z+YDLFywe/WKWyqbPHPogO2nGiY
# DATA esLzI9O+j9J4eHhE3VCtwSkrNJN6Xe6ucZLMM5s6Aw6mg1DK7d8OtUmhjkBdoPJ/vLWMdOr8WtDSoUoGUryiIxrFH9sBd+p180jd
# DATA qzXpkSdjvzIOKuNGZa668OoimdPjY196P3kd5lcwkyWgCkjLGO+m872g1sSrK+1a6/ik0qrhyz716PWmiqnKk/3DCVlCVCXgdkUE
# DATA 5FfqEpisUanW6o0WPXo4DR+pNPjtwfhQRaqfUPucUkIbHOlgt8j50p1WGhS1gDMeUfO7F0SN4hK0kJ3Fd/ObG/Jmeomncp1CbJQD
# DATA LD7JLeMJMlgnrd0ZjJ/E06NKdnxkag2T0A6t9qoqSLhcJE9kTlzhfQYyoqumAlycH9SpIlcwYdrDk17Va6NPNxGRQcoO6cK6Wh64
# DATA 2F1OY//iJIpmXJP9WqtUlf16y3QrJtvW1dwnNfZeSF52JC+bkpfBal7qXAvqVCHWjkM0lygmiPsFth7wH2l4gRpa+e8TdodcmAvl
# DATA drrp7V4oI5fy6t+FCfyTsulxYCyVw1KzfFKDN+gxxBP4xlH8KBoe/qzKPhhK9yEaZdVHKR+CuEE5jYze0EWbbgHp5JBlCHqMUPDk
# DATA kxqZNInuHKvCDGyj7Iq9Hv3H7FlD37uczrIDf5R69O+m/o0bKIfv1chyoNdwWrmL1WZNXqTNFjUEuXsUHy3TyBiS+dVByN5QK5xa
# DATA N0jz9olU1br8WjWVuLgudEvP+9JGa8rgL2VNq55Xa757fZ1WD3OHVIzCzo3JzlTqvle6v5YdS36RR51h8S7KOpTc4x3KMo3mNCvc
# DATA a1SonlOh7NUrVLLUbeQxelIbhOnwsTWyWKNOm4f6ci3MlukIR7gvsC+2m6PyXm9+gNl/dTCOJ8PVZPItNbjPK7Xpkialj20Dga9Q
# DATA QPjdrjw9ycMTbMu3rYHe2ja13nxuUSfbpH8b9G8bplWpnLh+FgqAfXbF5rLBUDcDDAIp9YaS5oPZYix5shfM9j2dlk0lEaxabU9q
# DATA xm9aruvUDVCy0EmYWzxlDUgGmoEfQytGfXxAiPBVWoNcp4u2zVc9e/Dr1HGd0hMvdqmjlJmqx9HdS6GVMNTmSQ2+BWPtBTdZL/Em
# DATA XsxZNRH12FIT8+0SLTBY2wI5LNkM+LjQWYm5Z/fznqpzW+qAShmPH811M0qrLTSkOzoZ82FJ9FYHNCnjXlTH6ICSsjg1aeSRsCbb
# DATA 1gs2dq2lrWbV/ALpVrQvco2l3bRTVz/EXVVewFFvyf2Yk/jxDuZGaY5CPQfNm+JB9NjOkvJ8TDdH3Txk3K1JodD08sgyokzU6zsM
# DATA E/KsF2K6QfPBHSpJoW545luAb7DpVhuEPaYU+2uvvpuBVoylN7cGZvVTRoP77OhxyW9ADSQ8KntHxLTdUjdNAQUyiUyLdabbXp1U
# DATA bmia/bBk2+qWtDK2luyCchcuBoEK0pNJIR458K15lt/knlKaQp7RZefNMMzGUTGDfzyOh8No9pNCA/oXggcMZ4sn1NweGz/YIzbd
# DATA 7bkR5gf5+5oXNH07K7ubGnbJ7RbOTk/ghn6CtREp5VE4jSenB++QiZXQuFz54o0P477e+/5RMku+eKMypT8cbrHNU14OaRyOJ5mV
# DATA TcHu9VH5Uh6XvFJlp1XJXtfv9AqzW27CahJ1UXM9LI6OHONATXzyEBv2cL/O6NzBACxX+W4eS6v1WXWghfFV3VBwa/BMZTf/JPXY
# DATA ube6NBPdUB1q83gyqabJycVWtrKpF9HclLruRpv5T+jETftvqg56ARceh1duBU/4J11w1EVOwnlGVon6YE+g7RrIA/NiXFkMZVrG
# DATA eXGA2BTG0Z0q42KbrfWkRjGIHnNPLh34gX+n6vPYaPmILKNBbIZkuZgvF3wioZxZMqfiXfpVLNussWZxPC1cJOljPeyus2WlRuuO
# DATA zlToJ//HNBrG4Z5lorWpW9t/vNHpYHsaGm30vcqrUGwtyiZZHZ24ssgpCkx3JZvsOsPz043zz1KjbGDmamdlcT5pnC4t7qt5bnQp
# DATA Y0wbq5vjY798/RSygcWG4gxxx2xZMRg2T8uDkfYxtiwrRT94z55L2dUzKJnP2oxdrRfNBtcLzsOKtnI3xofdMuJ64VG9lxdOYUIR
# DATA iJtOTTWLw8Puqd85udyJrJn/cEdOVcmke85Lmlk1jYbLQTSsThMuFvlKrWPdmhgH/p3Kdw5k0wd9CEdoN+EsnuYuo3ycP+RFkXjN
# DATA LzoacjpHt0VphhW9GFV2eIh9zKWpzA/L5SsrdVavwFaAmhv2aX760Mw2yjc9eVJYMdS7trBDkP54j6aTGa99Yl/ewZ07JycntZNG
# DATA LUmP7gT1ev2O2uCFDURvJ49wY92re+0m/cPLvqjxnmwApO980ZOOLP+e8nN+gM8jGoJ4z1Sj3hg2e9j4eO8tlivh3UIf+W3P740b
# DATA wXH3+0Hz2K+P6b/d7/vtnxUeHgWjxqghDyOKxVXRjEbI6NkT2aWJPE3mOQXJRO1v4xvzzVhUcfun+IX3zeW769TmJ3PVXnQ+yHf0
# DATA mD0A0ZDXwk/NBjwrS3p1r9lseY1e0wta9UmjHnh+t1Ft1Due32wUM2bYHvaj+mqudhpeo9v4kd9pT4LAr/ZaXuDT4/XuMf39EEG3
# DATA 6kExqGg08jmPebrwkNP/rWarVW9F+cWqKfrGyksRatc/bgb+tF4N/CZeWe31ODIqIp4vteKKbwiCuhc0/WM/aEx83/da3R8Fve7P
# DATA Pmo2el7Dp+oTdCd+vVNtdn4UtLvF5HUHvSgMV4LstChXemM/qE+r7Tr9c4yPTbrcaHbHvk+XWy3655g+lmLeb/frzdG6mDc31lS1
# DATA fZEq6gFOFj5WnuADVcMPeX5/oBrLoZ7aHnyr3Wr3G7hgvE/0CP/v0Bg0q1eCg29FftSKOofKx3bwrVav3em0DsXCOPhWfzToDvAE
# DATA u53p52G7EQwPZXn/4Is3HkRHSeT98AOaLnwWjsn2rNzn7WMZdYXVLEpjPKu7tJ1uR/dUw25LMpnyLv1ArEkvKDqdu2IImNvNaKTm
# DATA N9+LqE3HYUWCLi3NHZYdYTDOKp1a8/ik0hFHGAesdsrtMr3f6t+imWoxxLKj3DbzVMGsPqB96MVxonDXvGBVisnJN2D8GcTYSfT4
# DATA EssD+VqAeABLZpE4reqXM248uGjLGzGKXoH6RmO2kNrKStIuMu6UZ2+ljrHZcJOWypPVtv5TNPUv3sDuPeok4sGCd5LPeAOk9y+h
# DATA L+bdvWe2QNa+XEbp6QPeF5Cke9m+da+5+X6ahqe1UZpM99Y/d38yoUetZ9Vevr+NTiG9qJ9BC69hOyDFlueW3pveF28c2BGcRlOc
# DATA zhbs2EfhfI8DNaxwljN+GJ1WvFE4maBy73uPceCf/isBiEw+7yl7IJEAkfoDyuo9K1JvQqNs/9BQhZmuQi9dTibed709iUVtHGZ4
# DATA 2T5dUlcoKLlyYEXgwMPRT9EiYLH9Q+8JjioPxhQr9YbLhIjHn9ip5kP1kmyFin2sH8/kcf3DocqLQvqzDemvSLxRS2ZH8ehUY6tM
# DATA tmCLzZq0jHC4ezWS4ekeJs/7pigiCNT+y70v3viWeH6/eIOChthQNAGitYa71ekMuhHfDktBjpOTjWGKMXrpMGfL6V483M9T8/Fy
# DATA 2o/SPQ7zC4j+0a81nZuFR4dqE+meyLkhcNGzoDd98Qa+3qHmHM8O9TEXOePyRh77ZYro//DTD2uy4/IHfDyEvkO9zXsbGno/Rjg/
# DATA qXiPEfATFIY8GtoNSZ5+bxKxXsYXb4ScDWENu/+gWZNO8E3HF62JYoxLg0k8eEhtCltPP4unUbJc7O3to40jUml0TEZFHikKB9x3
# DATA sl9VVkhUsL6hSwGzCbzczqdkhg3Ne6MZEo6ywQMshDeF0Md7xxTpD5XWCoWRLfvTmAqy4kXHXGz36DH+WINqDP19VzZm7ami5oBo
# DATA Ok5ToR+B3hEvTvf2KfwZbniiovovEb0fy4GL8Dj6CUWyRg++Fw7Ge2rzJ79oQkZzFooYHfcuFCF8RXx+/BP1xn8hPWCc8d89voHe
# DATA qJ/78U90KVH+Y3c8dDn3JXy5fspKlnx/jUaVyXIYZSoaeYdIv9L7zCa5xX0tbY8Stra+IWoPuNHunUKt0zxTrPx453epYj6Q5FAH
# DATA I59x3ujJoY7qXv74mrLh+oL36eRcR1bpzztkByVA7iKjmqa2e8eIBdjBd721tx94P67V+POwsu4OU1BkAWdIJseDu1crMRLpQhah
# DATA d8ufMdlq9qEv50O9mbywgV/l+9tq2/v6Pe6H8oyExVvaM7WdHWdCyaA4jmrcwp/Iv8XqbRa8inU8eZRXcL4l08VGP5lMMQ9vLkJ5
# DATA mMrQhIJCRCArNsAXb6zbyWdHi3+XiPFHiQAXgwSf1wf5XffE8m1dFeWTN3YdVSZIrpFr2S/bon2g4vIFJDynZHtIbTNR2FRzNuSn
# DATA joCqPfor2XezI5oMwvTx2Iz3zHvpYqmW6dayoV4dmgMV62sWqk1eb1Td0fkDc9WM0PxN9eRyA436NLdiY4xv0d/L3b00zQ9Ey9Rk
# DATA P2cy6xNzyN+VXPT+7u8o1qgQ1H9N9+hP8mFyEqXvUObtmSymhpCx+Jp+ZeFpspKQcK7XODFB99UPPatBIFOLlY4u2FWDRRch3kPX
# DATA 7U6zGJu8JnJa9r2/+RtvT0ft7l0dE0SKAzJVwOTb3bsqKai/uEWW9ejN/4KjIM2NP+5LWt58UwpKGTtYOdTZz19ycwff9uWOPFjJ
# DATA D/SO9XxEUkpFUoa4wQQiv+2re0rDh4TFtZRjGGU8cFDJ6xJd0xi5HaEtWpUCyTHluLUBFx6iFyGOqppSJutA9os1Djcqi2Nv/+49
# DATA thm/eON9cygMzeTNPZh9X7whTY/S/x35znNAbu6L5H1sq9sL9t9Egv/X72tf0P9m7+pZcpIs2NXqhQvPpxnLmxIAHzajAOih9e8h
# DATA 4+lO8db8XT6/63//o/WgjtAOzw2m0rhlBpgfyHQHs93B7IsOZrsD2a/0gWyvsN1YnYN+oQ9qG88Z/1w4ATixjm8/mLNaHka2eAjY
# DATA iD69nd/O24r5nNyLdZ77ZTnVeJFwi+0o5fiLx/neW9TTlpuhXiRDNMxKRVfWu6wVPLkQTvhb8aB6efFKmvQgQebKm05nAx0N5ce+
# DATA 94OVtS82U8keKB38t57hL5wOzoD5PS7aAyp36MFQecEeShen2FRsnp+LbkA2DvlErK5RntpwQdNCPo687NO45sGr62EOQmF+yfHg
# DATA XUpxkta8H8yjGZ/zHfHZfXpIHebnyupRWGPUOqqTnmxDYAwT7qY3g7FAAc2UbsCOyjteycetdQT4PDFHm6wFMrKPcC7NyPD8LY45
# DATA o8LhdDcTHbxPlsbd681wmdWP5B0x/bScw2zIah5sKf4xY5MqGcHJQy1mCEtNNRsylxOWABgtU7IilqtqCK/mYVsTgrPenPV2kfVW
# DATA rGFOX8fp61zWbNtoIN6U7s4DbGGz5CDwGvg2IZxnFHien8bbtuESu/s8W66uYMnx+gfbH1gUUVty9DUubHRCYseyT0BnsvIC7k33
# DATA 3xKfqG6AM16PQiFJaOY5013lV9grxts/ai3eRKQ1rCn5vCEKF6ch7zdqqc0k0Zx3H9WkZ7/DcSxFVbwQpjrg2w4R1U+ZeJoLJpqN
# DATA WvsaoymeEfpZe2n4wlviaFWR0veYSJmH3kq4w88jF+DN9/yDoP7WnURZheV7Wuqe1pZ7/Lq6iT7kd92RaOVJUba6zk21CkYP5s1g
# DATA YUsekdnAT7AhkU7pvbwnWKVTrYZi9NJVM78kPU98zC+a0zi9kBy4I0Fg/qRyS9Zp7VDyS3qHmrlyzzI4Q0zIrA7AlqZio1Ga/ZJS
# DATA BeEXY1B+RIMh9c9iNGqvtdX+McZGM275bCiagTZOxY6sefeHQ4/PxCqzINPDZ25Deh9iDUWpemIiYEbaJWTTxdHLRqkY4tTj4I3Y
# DATA hUFvmy8nE/5xiWVYGtTjVBv/P8wiUd4RERvR/Yn7MWWxSMxrESld57Fgm3EUyCyBYcGmNHoizGviDNNCStJMOj+tcsX2+gTC91Yv
# DATA hzGwH7FeJmcad/BSJFwar77VbA+AznB2hvNFhnPJQHKWs7Oct5vDL4Bi5Wf0Nm4cmWjmhUPVGnKzuaTZiMHF6LyxIuLDaEEFOjsS
# DATA abui9KIwwZIRxq1ESUDmSomih1g2kkv+WWxXlFJQWxbfGjdYf04LOevGTjFuiMvMiFTCgsE+JegthhJdFsNORiNs/4JMH/cFmTdO
# DATA Tuhnj0pIhkvO65qnjAtIWlLsjjHuop9JRtwxcJ5b8pXis+LkFAe9RcjezPsphquJGelMiuykfchOuXBANg6ENE+ox8pThpG3ylMG
# DATA 2RDNqNNwkvF2MVg6SOIR2WKZ7tWGVHhj6s24lDiZcsqHQpixqDjciGQ6HcncSYwY7S9LpmQ1LpS6YAir4KGnlUK2pPPd8JR74u0J
# DATA RRmKqxJlrNP4QPkfR1FEyRrGI5b2o9kdDDUIHGIPI/YhULVayBYMphvTL2iK+IVNQO8zxvB4zBdEgGxZMVMWjkGqijohxqLrL0+l
# DATA Up8uUJ+xSXRLIj+NsjUJFLOiUIVXBVVNVScrlf2WJ1CFRyWboAnyqJNG64xYFGlF25EgvIXDGGfvZKATO1WJSVLt/RT6L0PKRLIL
# DATA 2fZD8mHnLcmY4CceisdVu5QZUobaPZV3ij2pp9Ja6nQUp1NeHFk3t+VEfUZ5I/NxMHrnOEZKZpJRW6cWZKznfPE7E/+13E/5wdWR
# DATA TAE1PQ8zsYW5d/I+0uKe1Lsy7IFNaQXiNj5kajwP2TzG1IAMXyrpcLmI0W2EKet0TZXyJKufSocCLpS4jclCwHU1pdiY2r+dJSdS
# DATA P9FKqImgj4Rgq07wuwmHv8C+SuS2tEVK0ByuBO4aeWwTu8TyK6DxUyljS0M8MXCtlKcLKRU3ZR/ZSJRhkkIqchyQxo6McEVBttAN
# DATA 8xRhdlpWkzXzCVtW1rLzxWZ+Ba39J08qhqGzOAKcNz21CTr/3/mvzv5w9s3Zfz/7WjFyvj77C/3/q/Pfemf/BKYN/fBz+ve3q+ic
# DATA /0I/PKWbnuJ+ht/85fw3Z1979OV3BqLzRwpULvNXgHZ+ef6binf+b+g5ega3gZ7zDb3pT4zx+Qf6QZg6fzp7ev5rHZm/0i1/EFAP
# DATA YDuOpfMSzGbQKeP4EnU4ffqzKIhmH0UJhZPGA22C1bz3Hs0nMj5PuEeMpG/IxvGceouJ5Y3QnSNWEedR7jPI50LJZKLGJ3qplvnd
# DATA CtXBcqIKT7UUh9Ypzm90D3LbYJ11JXNzeJ286phbYdLll8sPTERv2tz9oXznEf2aCTs8rqlhPVGbWzGYOsDOjsV2/YgdrL1HbH2i
# DATA cCq5i5GNX+QeHDJZFBUM0zGNJ5yPLLefLTBTLe1W1khNBGEOpcSLFb7OxdVvs0NzTct6Xpidi5PhODvOErgJS0ADd65oALwmzs1b
# DATA G/xvZOzfaei/7Mh/OwO/VM/VfMgZPC9e67oJGI+VA4ziKb56TXpXQR70uulcrSSqwqM8S/FSBb6JJGsylTcVT0lge+n4dDGecihy
# DATA wIQzaFcEjyqyfCGSOuIJ42WWWKmFSvoCub1Q/lk5JjcKjxOMCoo1o2OMFwjchIdTelBbDOpc3WFuLwixCL4fmBEn4Wxhu8UGydwx
# DATA dhxjxzF2bpKxs+uostM0Z1cr+ZZN/qtY/Ndh8DvajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7Tja
# DATA jqPtONqOo+042o6j7TjajqPtONqOo+28SLSdoBVelbbTGbVGg5eItrO69rwTc4dzV+UedmV6/K52u6CQ1mqWcr3Z7ha5OVHUHSmw
# DATA EQ43UvQGHGijzTIgAw41kGBYKsNvtosQnwZl+Bo0UqfpNYO6B7qN3+pN/G7dC9olak/bb7W6/VVSTrPhNf3ej/xec9zsHgdBa+p3
# DATA fK/+I7/eGDc7xw2/GIVBMGz2+2sS0erW80T4Qc8kolEMIOgFw9YqsYcy1mt2grHKRYueYx5Yoee0r0DP4Rpr0XOo8hfoOa1mN7wK
# DATA Pac1jEZ+Ts9pB22/MzT0nEG3Pxr2cnpOu93yuzdPz1F1vMrV2IwLDSHo6OG2cNM6R1WDx5FK7/ik0mVLqrDG1BqMD3cm7ZTfphzc
# DATA tmtLTAx1F44WXA9uxw5xFbejJppdY6yijA95J8c4HCYnB3UP3o26p0uyAOjhdr36Cu12N6Z5R9ZPCrleuqmwVibDeQmGc7hhP8Dq
# DATA aKUoSes8tbJuuyVk1dWooU03lLxmNE38Lnalqj5jM8WnUNoX2IiFzLMLUyVGT15ghTjKjqPsOMqOo+w4yo6j7DjKjqPsOMqOo+w4
# DATA yo6j7LxelJ14JPYb1j1Q4x/b36Tu3FUjphq45LcK18X9wycWpuex5Bsy4y4Hg1NHJpg36Qngd754483Vd6hKfagHFPWS1RvzW9QB
# DATA DbqL7dxDBQn6GMe4pOWzKT855dM5+q3lKNW8/1OdgbcOpfHBM5Q1VSgThaq+gX747rYR/5qywtjMJqm8OFVbPFrkaabe8Ys3PrRO
# DATA 3plkUHepUiAT3dI5H3cE3R1B3/kIevFAmDuL7s6ir54a3Ki3+SKcUS/V8UJrscVp2PPHArSozFmulqKEb+NhFGYFdAufiIayJchF
# DATA PNJk1J3JOWGtpMJb6UqnZXc9g85JYH1GjOUszqckQelVcKHORY+vz7KLiN+aw6Bql9Wqfr2yXVEF+ZNSg1fC4frHXM/cXOHttpD/
# DATA jDgcE704s7J6s8q7MYhZGl0+FzXerTtM92k/taLQDosShzvRocl9LO66SdBddakc1vfU5813y/F6VrnjT5vv5D5XycwOos33Sb/N
# DATA 6edPW0Tl5aCplnMXO9RWc8cQs0XLvVAT4D+3ZV3zX+Ct565OzwPkk87zcp6VxDbZrW96AbGquealS86Nf/7H/2DSUY64lf9zlihF
# DATA nzMJ57n+qlpK5D1p6RISCbDREpZimEEJnrWooVYaUy1kKFM4n1OdZH1d6pjR+mgSO1vI8X/osS6gf6R1aFmrmhc/tMjsCVVudVhc
# DATA +bzslpmffNZNIz9YbRxnuKySYnJGH72kC+wL5ppC91oggLJq66WKKK+oly2gv/9vmwtIV3opng9QDFSRM11An50k1EZT6tg8fcov
# DATA UyYI9UnLGTyRNCTNa94HNMrDyJkmxyJIQWlgwQEIGxxF3K2igGT/sCqnSKtbqNJ69lIxKbi1cjHdwmWL5d//l83ForoYKRWRAx0k
# DATA KU1GTMuZqYmwXOZpTp81XVlXWT558xANayimgyj4jqgPT05UERXtSJZmZ7O4MA5al+MFjOhnLyU7RbdWUHm/fOke7rebS0r38VJU
# DATA n4fp1OPdXXkXd4JrAscZHkMLm0rmiAqG1y/Q10Uy3M+GIqURsXosdKajGSA4UgJqNtCPmNwRL0STA7tj7Z+ZOvHs5ZMn49ZK51lG
# DATA oP/nn3Yfgd7BIBulMiRYOuBTtqspXulDZWlzkwonrF4eetMljT+TMMU+uTnkk5HR3o/EeFQDDJlIYBhIs0GJP3tJFKL7MjSV/7hr
# DATA U3mQjBZeH9U+ROnk3RrG+D5l0RRaNtCMGdDIg8kBK0KHw5+G2J+janyGwkrZHo+n8QTnDZBTUKkgS/3LZSxqNVBBZGEVKUCtCH0N
# DATA TaWQjCsVUNEIFI+mbQSaK5Ld9z5OtO9Rawrx7EP5BJNUqIwYoBPuxHXBKuGfZ2EHvR7iLg7O7VxpV3ClOc/Za+I5uyyv+4VQdyzs
# DATA v9yO7ZY5Nw2kC2zVJIvyiJ1aG8ndL6gK5EskmnaRNrS97/EmKN6rreTaWd5rZUQ3Eb1XU65uM+rY4nzBJKjm+UYSm51JFfEdiRrk
# DATA SWIcF7mTSVH7lEN4Cii3kfnLC7riLTPBl0IWkILBzghJQlbWwl5Ta5Q+N9fJXE/zSlrgH8PTNTsCNFAA46LbY6TALWVBDb5RmlkH
# DATA Rk4UZnUuKmoriXrsMyGLdSGlhXkPrG8PG3Ght3lcqA+ymU0yi7erQhN1ljd40S7UuYUcrr1OxqMdhDMfnfm4s/lo1zW3DuvWYZ/R
# DATA atxopN7MOuxHwv20laJz4uHzIVXcBiWc9/6gevGxwcIyp/opx2urW1fWC/OFpHx5bNPaor28Ya/WbLq/5GgvLSVseqrg/i34tDc9
# DATA UXZTlt2sm54re8/KXsGNK6eFUuBNVogpqtMwHnJ9kIWm776l5StVsah7wS+XPafCElfnTDXpvLwIjkPmmr9nW1Se5t5Tp27bVOIy
# DATA 06/egSLOmwqmp4UG9PIixLHQtGAS6hw9faYs1WRivyWa6/FEZpxsgkd6JmUgktR+zGrVkk0FCo2ewXPv6o4EfYs9PHtKIIQnAMZk
# DATA V099Dktc+h5ZdxyKa5n3lVNMINyNBRr1xJ1kteDyeeN6p3Fe1/K9heB46j6KSrpUwhczwF8dK9mCA7IUUjItsAH/g4L4fXP2F/r3
# DATA z2dPgeF76uEbY/m+AevvL2dfA8q3Sgf8b2d/ZeLf79XdT8/+6DEo8Hdnfzr/v87+cPbV+S/p2T+pQP+oEIJ/PP8VrtFv35z/3KMv
# DATA IBIKCBBkQsRBngOwkLmBf3UwwJfB6i/03aPohGwHnkTPQ0jXKggAevXpCPIRfUh2aQwIdXxYlb2vsLpJn5kHqnvu605L99nLOb8G
# DATA TYjDIyNjIP6TaLGcb0UA3ofUhTdcZtjsQu3ZAQAL9r7uJW6b/7daLDdH/2MLiwkr+a2F+lbmmd+JTqN5HJG1oe9/T13woDIEhHaS
# DATA XjMGkNXDGAm9XPD4r85oURNzJMBdi/D6UYDU12ARnNr8LB6h02EYPEOcsV0uTR5BQyfis8tiysNgRS2kzm2wwBaGJUv/y4+Z2nyi
# DATA 957oiiYuVbLEmXGDaVx8NFvBAu5eLTfbOisN73nBAXdPjIMEOgvh+iwEjQa8kmHwejgBb80ouAGbYCeT4NIWwe0aBFJFy9lhzIAX
# DATA plXdBBLQSrVa/toQRQ0XY/fFw1PvKA2Hy1BB/7J89QEyhsU1NkYNFhclTmXTJ5bmj9n1hLU2lkXM5tEAI78xxXaCA5pxnZW5KcGZ
# DATA 7KOjDBwBX8YVsJqMqqic3M9SHap5ULHF8dlQLAf46JiAp+Kg2GpI/jylSxmvparSVuabLBJyZPlGk3017+MIADm5IJv2HixhhqTJ
# DATA 8mjsLWdUTAs5w84vzhxG0GEEHUbwBjGCOw9DO02SLmtQ3+oc4SpThOucITiqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqq
# DATA oKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowq+MFTBqBMNR/4VqYJ+N4ia4UtEFSyvQO/EFCzC83pNC57XqRt4
# DATA XqeYr8NB1ByO1tD32oFN32vm9L12b2Pe5gUz9etdL/A7nu83vW7H67Wqfivw/KZP5UVXg47X7ZawfJ12r9vvrsPyFaLM+zBX40sv
# DATA tJCHfsfEt1UETNaj9qCz5vkgCPLnG/Ucmdjd7fmGvFLlVyvI82u355stK/4NK793fH+rayEfm43OZd/vt+3y9vP4N3aMv11fpGz5
# DATA 8eZuj7c7dvJt2OOO2S+PqOS3e5d9fzH36ju8/jKQSGkkGhIpfZkFiRx0wmHHL0IizSMGEhnUG/1WrwCJDPrNTruVQyIH9WF9ODKQ
# DATA yOag3e02c0jkyB+2u6Mbh0TO0J9Xs4en+TqHHKE8jq5h3SGwXB3a5mL7wbxWW4QF00deRrMZTOvX7GFRGW4HU4N2UdG+t0Kx79RW
# DATA zm7EykJE9aKH4iJKCep7VJY83jXXam2LaujZ2aJu8/SulmLe6Fkr9skXHK0loOOWHQpqP4Kko5rRD9PoAKKXmymNJh8qpeRuMf3K
# DATA hVzZWl7sTDFFJvbgSjUR8ynYJac4BEeBdBRIR4F0FEhHgXQUSEeBdBRIR4F0FEhHgXQUyNeMArkKcZyGR3dh6lGvjjNmlOQ78lWf
# DATA ZEEmKOTiR7aiAFrVm/Q01YX3sSFyz99/84s3/vc/1ph4eH+tzgA/syfhh3M5bIA3UjD7JpwA4fyvryScd9Di+fjSNJwtRyHr9Mup
# DATA LjmPSM15LkffcKgqFORC9Ihu5MOfZA5kNLQVCImFMzru9L07fX/B6fs1R7jcWXx3Fv9ZzuJv1OO80TP6ooiY8EHk/Li3DCvfNfqc
# DATA z18+5ja0OmW0g4yqicKID8gqq3NvOt1XlETdQmfsAMkF/XQQplszF4yiZadVVJKcxjNZ96or1UleBVJ6k9hvw79u5imaQdmuKpeN
# DATA txWIibp9zcQ+aK2LfGBFvVuIeL3W2hx1M97bUdcXVT3aG0ZHaURT9QtSYIVlUmBfMylor83+hp37frAl8zcqdOpWghotHcTLqs5p
# DATA jbjMQ6Q7U2nN+oh7wezDvGmxvsnQq2IcWe+f5o3cvoFF9kU+X4o7yhbSlciTgmc0VSIPg2/unwrKsdAvad0B1q/QoVE/QkagMhAx
# DATA 35uL2TCMMffjx6AhzJIaJ+GpDDxSnDz2Z1pY42gZ0oiziCKWBlfCFl9SB0fmF47WK1GQNTHaQcDz1TuwXhoVnWXtLOsLLOuS0eSs
# DATA amdVF6zqzWylF0n5qtgKQpNfRvzqh+DvGbUjrGLnWkesJwOXeMXoNwm6OJrG2ZwlaLzPDF2FjXfWzYngmTuJmMxa8fSeDYxK0RzL
# DATA +Ck9gvpTtqiLBMcVsStzHw3978dK+micpPHPEiN5oxT8Qy8LR+DrRCkZRSzBZEolmye5QjpLFLFolJpFRGF2yiPvOJlGEOXh2QTZ
# DATA fRXhZIgUD+6l0ZoG1hgmBHdWGeUWVhGUGji2KmyYMhRsm2Gk4/4hhHmKHSC2TijVHvAg8w7R2ETLWciGDdWrmvd2PEtQh+gZjdnV
# DATA hsAserRgQ5KXVJBBqh9NMritVA+rTCCpAlN+mQUKXWdMrE3b39pghElypFP4KU40S7lJtSrM2WIsyEL9I87Figx3QSS8JqdKLZ97
# DATA /Oyh1LR83NCbIkX+NWP91xGk2jkRWpGUoaeMC/P4LBhw28jeRbYtUZ+InJe0iuhUSWZhpJ5PuQuTNIoqmMjP9vPyYAdgbpyGCyMY
# DATA lo9HlBdUYSmNMuFUekqUZdjlOsH+Eq7KOEKT2hX6NINvnGPziAJYkHEYD0GDrXnvJtwkMfwZZTKIwCmDcYTOL7Vis0JAYsvqQt1X
# DATA E5d+qAp7aSnom/UUwyQ1V2SQOJULWmRfTc6Kz/OPxamXXpwqTKvqPAVS/VnelzGxQGpuDrVXMvvP9D7fkCcm4alChxdNlYx6wut9
# DATA Z8BDKON6hvFU+p/rfQO2Kd77WI8dSNM8mg3iyfW+hfdwv6dbkF5Cs3vQ631fSwAWo8jsGaKGx7bkjFpb8V13lpMbY9C+evMrR6J1
# DATA U6vdJYPdROqVn0hdFj37YkkImz29N8EwLWf2tRNM1ygdX8wvnRQICqIBzG7Ioq7wFrzui6Wj/DJKiO6IW/AKG8u1EZ7LrUq+mMlG
# DATA bWVynE97K94RFJrzOQ1mYV6ICTC2Wpl56ICmwLZ+rKi2YtKULUqz0tybUPIkaPtbBHQLtZasl+PoYiFp1MlpONcgh53KYE2JfpJG
# DATA 7FEvqGFnUZZpVuFrZLrlhKt++DBKC3ir/3r2NahT5z8/+4tiUP2BMVdfnf9bxlX9T+/874GZOvvdKtzqP4FWxUAqcKx+fv7vvbPf
# DATA n//m7K9nX5//mgJ9WvHO/gfd8mf6/kt8986+MaGBmrUZePVLcK3ov45p9TKQbKkO43k4G6iCsQR2yLhnGSLI2op5JBjCNQG5ctU5
# DATA YU4mLo0ZOy24XxopMM9QLiXo42R/rTDyqOfI2NO1FWH1NjbQop1E6CwcwMo2QKUTuG16VblEbo5dBUnoYem9a5FVXMXMje9yhbsZ
# DATA WBWNenO16Re1FJuEk2F4yvsIqX48jByw6qJyu3ZO1dtoBlwC8yjFWVFWrMdxvBEDtuX0pUe2O7RM1CqItQVPr/dDLP8ojYZxBG80
# DATA GAXUp0YpvF35corqF+MZmUNLyWFvusykPxMz7FSo3oN4Hq1QrHapqZvtmVLTe170ql0S4bhVzgq4shWgMVVXGPxfC8/TLQ381z7u
# DATA 7zTs7zrq39agL5WxmHozyD+vxnIT9KliEr1xNJnDOiHDAwhmE7k8wen4dDGeYkVWkn4gQy2E3nHCZcEfgJZGtsjqKHWYoBl9QAZ+
# DATA eEzjZKazIxVpM956gDXZdMlaihT/aWy4QNvZU2p3BDxMEZaoIz7TJQMxx37DYC4uDssgYDwRjwWZmBBVtP9hwbzgfYB6E4VCAfFL
# DATA WEABqCn6B3sqYOfpNfLlIoE81IBJXQ4w5QBTDjB1c4Cpi8aRneYyu5u6t2i1X8Vovx6b3ZGkHEnKkaQcScqRpBxJypGkHEnKkaQc
# DATA ScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcSeqFIUm1G8120LkiSWo0GrWGg5eIJFVced6JI2Vn
# DATA StD2Gp3ul9Vm1e92Pb/VrAb1gP76nk//NHsefS3m0CDq9hutVR5Ur+MFoD41PL/enVb9gP5pqq8lEBRlcn3QXweC8nsSMKU/poFb
# DATA o48aFnqp0WpbRa84SAIlKoKromYYtaKViDY7vhd0Kdktz28E00a36jdb6ttKPKN+f7Q2no3V+lVvec1Wa9yu+x/5zcBrdv1xS+vF
# DATA WQysVjOI1gW5WmPbTYppw/9Rrzmte0GrSv/43WlAr6Fi6eJzNejSl9UfSi/tdtuNYLDlpZdBHUkL0agjaWwW6qhf7/jBsIg6GvH/
# DATA bNQRfQ1H9QLqaOQPR30/Rx11+pRVoUEdDcNBq9fKUUfdZqvut24cdcQ7TKpsetgsIRXZ4uzTx0joyX+pmduTAZtpJDODbZAfHrny
# DATA N+9AHyo44drGCSdLb6uAIivsVYc8j7CybY4eih7uCifSlkZQDsC7xHi95bHtg/dGCJFVgrYv0BMTenN6SoXbQal2VNEW82dzchxJ
# DATA yJGEHEnIkYQcSciRhBxJyJGEHEnIkYQcSciRhF57ktBIcYT46BUluHJyd/QduTQ+HcrqIWA/ZNxUMvNTFrJFyVdPzdXTiHpkdVnT
# DATA h95HuEwQGr1JOXTEfKDPKYZy8aQIIlK/P6Dg+eds7c8fzCCKBGOB3sf3na6977NkEU7kfB/f9VG4GNfYb7A3evPkzezNU3WzzRnK
# DATA T7K4o9LuqHTxqLR1rskdmHYHpjdL+b0AB6lxJnWUV/Pw1Avxe0HefMHKJ1KfUQJGIhz1poKfIZs3mSQn28/6TuNHfPx4nibJSJ8/
# DATA hs64aag0/mIryjKNsmfQNqcRMT1FUhaUJUifPm5538uWc3Sq0VC16Dgz5COybBTYKKUBD7UTcnqTeIFFnIQmDxkrYQvIZJAup/1D
# DATA aMPEMz6PnZlD1SM4e4/5/O7ncOEWFExS1nQXBe1skCT8xGA5h8y2nGvepqD9DmyI9FT20Xk8ROVJG0FkHSqACJJLdRZFw0x3Z5Le
# DATA bJGKuUzlOE4mQz7riphTYmkOzHLgKJURfjuiKE9OWSjcZJspO1HWYZl0nErXquicBkzkJskCSadL/eRk4oWTLOGDwVslwt+n6s1N
# DATA R45t01uj1Co8Fmzus7XJ2aVvjjN9iv4EdRHdM4v7THC+F/14zWNF9bwnH2BDSgR59HjCJ3NxNj6ree+wWjPXXU8DalAdKPIIFakN
# DATA h9gIxGGZY4hK1T9cXCTqzjnHcT6hgcToCmI7Ks6/ezhKg5dR0wmn/Doa6Lh0lCT8YLmQwsW2mrk6DSw68ea8N65MYkXhQrX4GWTq
# DATA GY6TGUXzhxKe+Fc4RDINJ3aWxOY8d5hOr6Zr/rYIUSPrqPFfWtgcjfC6lc0/Reaj8EZwTkvvdAOC5jnbUgSPUBRsiHq5HsENaJob
# DATA ZUY2amaq7aGbxZh3AxLn97nbN7aSUpO4PSXwV+cgdx6Im1G4GUVxRlGuUm5a4aYVO08fNk4/bm5a8QBZkeNwJDp6SvHCawPeBqJU
# DATA HGl0mT1f3t7RRVhM/YDpsMyFnM5RvwqQtL4Z65m79uiW7+sv3t63L4qs/aCJcOFiTvHsrotzs2VFubcrQZX9jUwomSx2iKW6PUe8
# DATA qu8Fk2olanZmNoqE1C1RE6cn/VzwSu4QSf2giaW5kNu1tc5FEQ22RXQjCFXmrxitrJb28tJQpanFWVHsyGiWvk99C7UO78jMxSte
# DATA u/ttz9Rbb0omdeY1muqeE/inaZZPE+noKEVHyU9pZBam38LN4hu5O+KvSodNZqYGchqzWm08MF0d3hg9kjUTPWXAMhgm9QirJGXG
# DATA 8lxWX6YFbDNhlcnTsgqBSX8+LZHYqdMHkVZB24Fy+urY3o6+42zv7d58Z2i/kob2ZSk7z1kIlXcA5xtkVw1QG0LDooOh9mAbvVBJ
# DATA wmYKzXOVT30pZAX5v9fMNCoJvV430WhFKnctz2gH8VprH3UuYYtvEYQrk3BUMQQdtrKW2VgZWKV6ip3iUrJqt/hb48a999MY6zbY
# DATA pcheRLoERn38CDYMe//lPBfTDuOiuUMTSMwCo3XLLkpVU4RMRZ9UHWTgLVzK5CkaMDQttTyqxmox0bXj/QBrVog52XelmIvsrllU
# DATA odjx+oVpE6IxqpdlFIMUx8mwPdtaLWL5VF56wlnELRFGs98xtnysbZYw/Zfj+wArQWqBTk+fo6I4alhc2OMlk4lZ9aM4KvgkViCw
# DATA CLY5ovSydfn62mh3WuQgMtwG4PBY7KD/ePb12Z/Ovjn/xdlTQH/O/nD+G4b6gB70C2b4/Jx+A13ot6vwoJWHz/5y/hvghn5x9tfz
# DATA n599dfZ7+vHXzCD6Y8WjT1+f/bFKTzxF0B7f8w3dQ+8QtNBGmBCFjrd8RW+gGx1Q6MW3qH8I/TJeJ+beRNHCTiuyIIhL0tGq3alp
# DATA dAT+spZzloV/VV/N4J6yaHOBMk298VaG0DvjUFQNLMlwxxGyrGvVJdw2SWhdudwcTYg3BIyTubnxc3VhPVNoFOfd9PvxwniCr5km
# DATA JFBjthfEV2QRfV53jtAuJXbtNKH7noDXAQKvLpb9yJS8ePBj7KGderITvOZ9lFANmBkQIhXiMfTeIemBNQLW8IBZFqrNLiE+T2TT
# DATA Rwr34ZR5jOKsY+NLYI0QiS3Dg7ZXyc1GzJp29rzQQduT4KBBbqS/zEivOUFXHOBfD9fZbQ3uNzK27zS0X25kv/mBXarlag7kG11v
# DATA r7XcBCgoTxlEtCiAbDXOC3jcsFlTb/7T8V2atPMhJ8aJ6AIEASbm35lvgiUwpq2oLaH8lmk4o9RlJt2SWhO8YIamc+rCZoudsEGw
# DATA rxY4yI98oJBGKfV2+aAfy3K/XthCMCwmxxAjQwBKI8kqg0Q+FaByxRrpE2B+kpGgi/EiqojegwWSHbPHIx551KoeCg3lhDoK7BlE
# DATA G+QNBinyTjtEHT3I0YMcPegG6UG7jSk7Qs0vtnlv2Xi/iu3+rKa7Ywc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBj
# DATA Bzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl20AvDDorqo/oouCI7yO82Bq36S8QOWl133okfdGSSzLsIi6yZYSsajuqb
# DATA WDP33hrEKex/AfsEkhAF9umwSAPLG/i+IgwVbm/XmxfcbnF+KGyP7vHot6rfo791+rfX+j5dn/i9Ol1re4HfpGvtaqdXDZrBuNn7
# DATA KACwqNMdd5pTv9GqNlvj9rqYNINNEVcAoztHhQrUDHxEht4wrfpe/VgQPVuyMRr1e+31iKT6SvWkOLeC+rjdrH+EVDd7reNmfdqs
# DATA N6vNOn0qI4h6YaffXhd0cHkakNR5TQOS5mPRgCgZg06jSAPyO41us2fTgIJ6s9saFmhAQbfVaIc5Dag/GjaHQ0MDajU6/W6U04BG
# DATA o8GoO7hpGpAyStY7PnRaS7aWGomwca263Qrx6GYMO/m9ZfCPmSitmxRpNxrmupVmrcn8n4D5P6vrUe1ipLRxY3XTYrtwQijHw7R6
# DATA hKkxeBb1YXRUsdbe7c9e0Js/qnyrUW912n12++1XNofUu2RQOsrZPBpclkqkbV54D1dMKmtFbvPiuFoKF59wNaMfptHBMEwfbmYP
# DATA 5TlcsaO+2eYomb1Sh9h2ciQhRxJyJCFHEnIkIUcSciQhRxJyJCFHEnIkIUcSem1JQor085l1rCs/z108x1XG8Ag3SE55Ux5puhB2
# DATA BKAZgc4zmNYY5vNOMmUB9JVD3ny8DUtJolYV4qBKMlPH17QgbfGgmLRRmcjpkxbujLM741w4auOOOrujzlc86rxRfPBmjkC/H7PW
# DATA BZ+lZRdk+fSsPgr9oslt3IYetxpcUHWovirJcKRybzC9SKLZPGs6rPyKEWnurtXmbtkizb5fL8o0t7ZIXfPgB0kX1XvxhbfEljUq
# DATA ynJPLnCtH3or4c7UlpBu83LPp9T3KbwQ15O37iRKJHDNE23OLhpbvDveIo0eslbkhY+1+EW2GTCFQcPyycVn70hqdhCqfk/XT1RZ
# DATA D1X25VWp/igKsyVEo3GwdhCmuUD1g4VI8lFPkiQLuUGONUPWJzyC2DP8USc0ZtW8H/LgNomOqdKgA0SnOlVhczNWcJokNcJDaULm
# DATA ZM37lBcAxDSSB1hvUQn70XByioKmgogXBflqwLQKx/blHKmXLnHGG0euQxywh4ajGc+hH0gWG9VZLvyMZmfLbB6J/iErZoez5QgD
# DATA cYq5lAQILtIwHo1wZdlnPfUY4zQFxtiddbaeEiGgJCx2Frh+Vc75OnlrZ75a5quzV18Le/Wy2tbPWbKH17XzBdjt2tb3aTRio5EN
# DATA SLZjs1yKgjkK2RaN69sW+3kp9C5uQtZ6tV5fu7T1Wk2nq8pb54v+2hwTi0LZPhHIolznclFrNn9OyaQRoCYvBdHrat7bohtEsyQR
# DATA q4nCGUyUzyEiJHIvGQY3xowKwZGrG8wosrpiLfxMNlxCNg8ZdQ/pDZoYcrmK8wMtxGJUnYw7/PVSPCnkjDOGnDFU6lOdN89584p9
# DATA 50Yr6jkLGjIPGODiZDIRnf0ysFu1kzDLJfxq3vvC6WYraZ08X0HLb54mg2gIGrdI0SXpl8tIfDnPwue+Hxuos6HxLmgE1UzAabwQ
# DATA 1LSMpB5ruXAMltzIj8LlEY2an9IwrGmBFQ5AzBJZ7lF4B3QY4WgEpxi7SnKXpxmnP5hhvF8Iv3apaBHRtB8NIYI2jPopjchCReYh
# DATA lEUAsUNpK8paRv9cnlFwwCFVBfhBWVNQmQaZti6gHAd/TSrOUiU+TTbAcBL1w7TmfQj7CdGkSkqZGyoQ2DBEBwMkQn8iwmtjFsZb
# DATA J2TIHzNLtVBcshmo119Swccj6LxNI6z9xYOtMPIxq1pz5Zkt4MFhL7JJ8ueAciSjkXdEQ5ZOouyT9CZLytRBCMVGrsfAq4cn4ak4
# DATA pnQ8VRlm2q3D2cfjAAWjYk75kokCN/xLrMJ9qGQNIYWZ8skCVXFNdS6ANRaoP8wb8foUgWij11mlmkcaGVsgE8588FyoGoJTpmWR
# DATA GZNQ4mOQSVj+KZ7QzxXth+IE5LCdQZimp6zceJ/yLGS/nQpICPMCj9Mcn+OQJfnyTPo4ijlV4idW6pdwyR0lydByt8tbE2poNBqO
# DATA pK0Vi/BqsG+05VNWfaQ+5ruXhn0jbtcN+xa7PJYGrvQL4xnA8dHwBqDfb4N5r+RC1daRG2B8f15SIb2RNzHc+0M0DeljaFyTbTmZ
# DATA EHOu9218CuhzQ0nECtE8jFPvIbzF4WrqbpIo/mpMdSy4TBKmwyP41m28zH9WGJlvGOoCOszX3tnTs386//n5b1Z5Mv+V7vvD2e8E
# DATA +cJ3MfkFVJhvzv5MH79ilszTimf4Mk/P/nT2FXA1T/FTVT/11KOvX+mg6DZ64S/Pf6XgMhSP87/3mDHzO7BpQKFxUJmXANM408yu
# DATA FV/cPEqAgFYj90IEpt/R8zXxexzxtm0Mcgoaxtq9LC+ck7vMwEfR00PhcjbcSpm5z7fkb3aMmcJszvQMt02ZWS2Xm2PMcALNXd+D
# DATA kDjl9WRUvm8I7WcD9MJ+30Uanl4nWobaQEY2dioC5jTTgDXGMzEUhIPLbC+qa6fKmE5oGJMZzyf2xNQh8xVPQeQ+fuRxvfA+5e0B
# DATA 4rY9wv7IdZvKhX0IjXat9I0ym0UL1jTH3g8aw7MVhsy2mrfZTllpQ8+LH7Mt+o4e44b0ZxrSNU7mSiP56+GTvb1R/AYG8Z3G8B2H
# DATA 8JsewaUulpOdb5t8ji3mJpAy5YTmZBmjOZHHnHIzChViBu43lhuAp2tGRZrJai2SYfgZMqwCPXEcp4yLQWFprAylPMxwEUfGDVEY
# DATA q6EysF4CInMKa4t9uxLikWwzwzSBPvYn4nE7SiM+DyDZrre6Kd86jf6QQuDvF/JIDjH+c5akls1QxIxEqYPFOFiMg8XcICzmgjFj
# DATA NyT8hZbtrZrnV+JUP5Nx7vgwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P
# DATA 4/gwjg/j+DCOD/PC8GHanWa/Wb8iH2Y0GgXD0UvEhymvOe9Eh7GzpVH3/FZn3Og0joNe8/v0vZgj/U6n0xyuZmcr8PxunTK0cxw0
# DATA 29+n78XnqG52+4rLwmUpZSUFdyoclqCgK9HsFcu42SxFpB/1OuUAg6Bx1QCH9V7Qaa8E2A2uN4aNpn+9MWxK1bm+GNqFQmV5DXlo
# DATA FcolA9xQylahXEsM7UK5lhjahXItMbQLpSGBX19LuWSAF7eUa4mhXSjXEkO7UK4lhoVCaTWvt6VcMsCLW8q1xLBQKNcRw0KhXEcM
# DATA W4HVlnvFUvYbpRDVhVTlfnnwb0eNEoqr3WuGzbWwtHXQsVarYUHHJPzUIMEsI0WHusJPC1rPFkCr27MCaPUuH0AhCb32MyZhtwAu
# DATA wzMTG03zzMTcs3hmYbPdbERFntmI/2fzzOhrLxoVeGZRdxj2hznPrNNvt1ttwzMbtgd+2M15Zt1BMwxunGemvB5qQ4OZCYkznmxJ
# DATA dlBY3gu9SG3mZ11eqVyz6F8Mucwx+15ERmwcViQmpb0oa4KzHZG8yFMMXa37XhwNM31Zv0tO306T46Not6Wi1i6L01ao5VVn22ei
# DATA 60jR7RzIRH5l9dBvWIvE6l4/KHphdHXlPZbjcJic8EIMVtzqnq5zVt722GHBs2Izm9uwn05PYlVu1zcz0Ow8vcCjYeVWqU7yZDlw
# DATA IDQHQnMgNAdCcyA0B0JzIDQHQnMgNAdCcyA0B0J7vUFoj1Xtjqng7iqUGT5ToiucJHURR/eQEXK7qG7epY6N6sweqlZ8t34Yv8VP
# DATA HMZvvrn/GBf5tsN4tHcSz8i6IjvsdL5Ivgsj/lNAMaY/4nD2H+sWNL/LoDUGgew1g16z1+4EvfYdjtL+d/iPikL/LmzAH9LsvRFI
# DATA x+vvHw6Tx/KO8iv2+vuHT1g2c6//4/pP7t2ld+0fiuQbLnybg37TP3wSkbGutOCsuAj/jQPcU/HYp7uV+uh8SaOe6vaeSPRQOe6q
# DATA n3+axLM97q0oB8GHQ2N4U/0oC7R7e2GlT8URvtmvkPWYW/IqtZP47kZrdhKjYCaxXSHvSvOgcqM3Sdpo5ojXso0vMwIcIEe7n2Mr
# DATA wWy4N4n3DyWPir/zqjRN3FVXfM+v7xdvwBCs4vMO7q3J6WmqbE80ss4c/XTKKk5ZZVVZxRwGduoqTl3lkuoqG0Wxb0B15VPIcWkF
# DATA kEnCeh+s2WWEV56vkNdt0OnYFKCr4gnykhEn5gIsnXoo75HU94Ka7AqRzreAdG0bR+dvgdGx+YKqjw+Yf6AoSjA6dU8Oo9MPrTDi
# DATA 2hLUIzGRNrPkeEx6D971i+70RQ2YLNCLbmSF3c9Oogl1ohfcG9TVvTMygUv37o6u4+qNVs4l+tJS6/5WMxpkPMrIeoiGRmrPyOuQ
# DATA kWVkccR8L0vtMEluN9keFrHxsmSZguU7EpwK9LfFaoSGQ86nE68FGYkzJeNDSTz11KF7IxZD71xRixk37tn6P5SmBhXMRBcKW2R2
# DATA blobdVUJTHaizb0KiiH5WOKMTmd0rhqduXXhrE5ndWYX2pPPTevvAaOGOJLs4gZyFNXfGJ0GSDaNB2liSeAt2UJV+nchta7ZAHSL
# DATA Ve07MyjmLUoNhhpSwlJyg2Q6jdJBrMdAtlzTCCst2Liws/Yfp2x+74F4q/qn8JlF2GWCYdQAlIT9S4Mp9lKs0d9S591WTVTlnkVN
# DATA 5E/KOFU2h/4xN4DMFT74DHRaxOGo+MlygwgO6sivtT2NzxecIPW5aHlad5iO0n5qxbCD0xRtAawpuS/eZgdq4/xdNuA23TVIQNyg
# DATA 5nLMN7+Tf938DFci3P0JPmyxLmVg1haeuFBtkwSDxBbzrlDC2PMhDVod7cyRDtQpGXYHe6xldUflpZ0XJRwQ74Yx7VycwVyb0iXf
# DATA Hvzzz//vtklFOdoqZ5UppqQqqYKki1Mxxsi+45EJTB5tSfIgRNO+KuyuIc8XvfvDIaTx6GlhAQ3Q2Kj280SR+clgr+BBNv9kdGQi
# DATA iiYmwzalt9S8t8NZTgWcDWVSKj+9DyIMXtKo0yBrKEH62MmV8rVUe66Qvc3N2Vuoi5LLsJfFhqeELMKJzuf7zJOhQWJekVzTE2vO
# DATA tRCbABbxNLKhbPPJkmfPNL9cikXPBCTl0ffux1Pk1YistWwMWBWb3rjkB/g6TzI20Wvee4Av4jXDOBssMxQQhySLkteRy6a9XTZ/
# DATA N+etark6V9HjU9e7wAedp+9ib0/oNf73PzbAShpSnmDxYAae+QnwQVS3lpR3VBYyxc88nwq0B6eFrL8MIpqD1LxPqMumqfd9qdhS
# DATA fUGAYk4Sn1f04N449N6278AZQnGX8ExabfKqed+nrxFXZCr/a6vIV87i7T1EIZs/p4GWJhkURKrz2JizI2r4VdFzyllg0A6k+oXK
# DATA NJc8lBWfTPoCuRuVFH6aUKHHMSGUBz+GdilOBmasWxqaQMKZhlJV5GX0G5ZQJG6c6UexSJ6CR3YcJ9RC1MOh9DwvRufRvlTn8a+X
# DATA Ma986sFbF4JkMNVfGuNQsbkCsg2kDSOZDiHbvWwSzyk/uXFw3wLQGU9v+qxvqj2CUFDFqC5KrNw1eUfRQoqOsxALiVkyjXDhaBlx
# DATA x4Gn45lMVKhfWlxL93Hzg987PC6BiRSbqm26RXFrLE4S6ZAla9EbZ4LQFKHkKE5pdDtBKLoes4xtbBR+abqOpp+qlk+2IKs6453U
# DATA NeG0IvXWx2pyR2HjiWmChVyeO6CnYOyEdC+wWcuZWzRXZNnYNlfMFcmse9TA1AKvFhKW8VtMRct8peY25oYnhVK7iPX0Krhc8tmW
# DATA c7k4l8sagoLzsrz6XpaNDpQXiqhQOCqwOlJObNaCN4kXOOLMSiiMxATFUo0m7ILJH+TzJJyxzxvB8CJrlV/ET7IOfsiqJB99ufcW
# DATA daTl9qaPvheO13XlLJ91Ll8uhBPpDss4iZUj6dJ+Bwlqh7ztdDbQUVEqj7nfzRaz5/JYA+awnuMvnB61EjMO7j1gm9xUEUCQw9mp
# DATA WbX6fnICHPKpqjvf9fjCEt4psqq+671D90fUmcIYghGSW8LfxSQsnnKFm2UnMntYYKOdx0vHrL8fK6KrZlMBRhuSbQY+LrTLyPDq
# DATA J4+iFV5Usba8HzMwkx2QlB3LwYISKcX+Oiw52ZzLhHncNuXyPzGW8r8DOXn+Ww9EyrPfn/3x7KtVwmXpzr/mwEvcX/HOf0HXntJ/
# DATA vzn7o3f+6/Nfnn2NJ3DvU9z+J0Fg0u3fnP3+/N8BXunRh5/TbX+WWx3H8iUw2byM/f6pOoBo+nokmifn3BPUPNkt72VLmbDKhnzm
# DATA 1sqD3IAxZvBgwh6BmUyjRpiwcoODnwxLC2PePL+FYvm2yIAJKsMhLIsmnDT62wZYlork5uiVsAOOre5eVTymoMtP5SdUFTRPfKqq
# DATA JKrgDB6xawVa8m6JcZixvwboH+UoVxaMg1ruWoLXjre8D7v0SGwVw46ucLc5hINNA4JMnyWG9rvxaBQPsCEf25Zlx02kGeD61llE
# DATA YdDPqbj7V4iWO9XBzWZJsXU9L67lTolwgEs31j/DWK/xlpcf4l8TD80tDe/XPbrvNLhfemy/taFdqmUhG3LM5XNrNzcBuSykEVPy
# DATA sJgwbCuVBCDY6XwhQ+E8RdcDTt047Me88LfIdKnRE0dHWGB5SNUgk3k81WO1zI3ptozMZgSexFQhsfwlhL8Min/prohLZKNhAmLa
# DATA QPGfUFePM2xYA1FoRx173va6gpVUNalaMBZkQYhjyRIpCAV5iAzAymdWnUdpla06KoHllHvZQ8tMwI2IcpUMto1mg2NgOgamY2De
# DATA CANz5wFmp5nMJezh2zPtr2LZX5Nh7+CYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgO
# DATA jungmA6O6eCYDo7p4JgOjvnCwDGDdiNi5tYV4Zi9qPcSwTELK887kTEt1JvfyimLjSJVrFPK8Ib8LjleRJY1u+16Z02GA7vZDsbN
# DATA 5rTabHp+dyyoMws8VqaR5eCxxgr0rW7FtYRUW4lrvb0prv1+u9sKV+IaBBTXbvu64tqz4trpbo2rgtmtjWuz3+Vfi3Ft+HUvoPp7
# DATA PXFtdK+lDnQG3Xbor8S1Wb/OOtDsXEsdGHbCYXu1vjZ711kHWu1rqQOddrff6a/EtdV99jpgBUehNdudcbtRP/bb3++W8LjUoQ5a
# DATA V4PYUV+qIXbSLVsQu2abuo3uDhC74ahVhNg1o+awnkPsWp12q9MyELtBdxD1BznErtFrdTvBjUPssIeqKqsbenRtWvw6i1bXZZsz
# DATA v/9yXLqy07WRL7W2xenKIfM5ld18qe1tvlQ9J8wDXV2VUb5mPc3AREFNuXqtFTocfGpYcJL/NPh3w4WLZ1SnvK6Q4aQyNIt0OlVr
# DATA 1lH2rkaMkxUDtYi7tgiMa6/sL9gIm7NKYIttulpjHF/O8eUcX87x5RxfzvHlHF/O8eUcX87x5RxfzvHlHF/O8OVYvVGh5NjnSYn+
# DATA jnzlw3v09Y7+VUBzbGx+8cZ76vjf0JyExGE9Jpkxk20QxZM9Dp3JaqKfmdW+oP/N7i9wmwSrflAANvWN4TA63CFNuD0+wbMm8Dvl
# DATA UDgY69GMRwSDO3M6iO6g/eaD9u6A/St8wP6y6ocvzMH73LG1XQ2RRd74NOuMRiiyLCCwPKbv27QQn+85/ZfsxOpF6ju5o/ImtBFL
# DATA KgTXLIxY1nG4QBXxvgL0sBgC5Sq1oYwDM9JCnyzhjeEdDN7RElCwfsRssNBS/YbuAU3WMU5779PVBCL3Wv1QZKIY0aDUFajeJlrA
# DATA WU6Uc1VX4g3Ifj5TjnPofakQeBp1Lno0l2mFUpkuqx5uVVIqNTl4r234BatuP0hopBur0+qy+VWLb38cQm7RyPSn0UmY4kC9EhQ9
# DATA CSdyND9UFdSbICHMSWAHehymIkwhkS+eh16ELJL6g+UCSTKHoMsa5atx1LlsqA0zKQmm2HAHgU0YHr4Mo9BIqYcZqzQoYa2Q8TR8
# DATA Wj1ebIneB6DeXCJy6EVMxCwhDV2RIICZUeGHqQIYJJNM8RgNTYeDSR96J+iFOL44bb8lkp/Ia9Zk4mt0Yt0OxdnIzkYu28ilWuVk
# DATA qZws1VWs443W+I3JVX0v5jbARkKohJ60gg3l2ENLu+qWNRFvAw4szh2G4MB6TCPkHFQqt+OB9WOmdzIXcsJts34RIrhRF0N2B0qw
# DATA eJ2A7DUOJr7ELiG8/III6+dNhM2FPMKt9RGWOKoo++Uo1zfHmV1jdtVF1drjF98Rz9T+hdlcpDDr73mcg7Vxbl01ytphRjd8tN7n
# DATA dkGM8wBMpK1LVl6vjbYVa1V9dKRbhThvBCK/vYwnQ2tEQ2/x8nKRP5JhWEb3cM5Hb3gBW8+lDDiZey8+JaLUoST5Y3ooAo/rvjeK
# DATA TtilzY7jhfGoQgdrjZD8UcpCdWb8n0XHmnllJMB+qPp13RUCuBYCi479s2yQ17z/kyyFIc97qGe0ulky+4fYGSSqa5qRKa5s6Ui5
# DATA sVCK5M1semBKR9MM4cDFi01TtlfYCLdHV2eEOyN8xVG9Ym05O9zZ4dvM6hdHNlYNdroZsA8MbcFWgQduh8Yq0wqP86FOSZRWchVT
# DATA HmqMwCn0OrG3CqMOAp+LZCeGV+VERJsbCRAlW8aCmZHDIJs0V69MT85fyg0bEvh9VAo9i6DReej4ybvwk2fsQ8UT4k3dfKe4k2UK
# DATA gU9byMnarWg5/0CxffEJynluXBIj+dlmhKTOV4FI3i947uHSpioDKG0aoZhKwNQ0OqIcM/5Z9sMKEov+M8LcWanPUo3M+Ea6bbaI
# DATA acIsKxA8V65574RpegpR1mRWdI+nITMb2WpdpKfKS8yirNgDmUrE4DNPZtpPriYPdiPNV390E8lXl8weSBnltyTf5K9WUaQLvNmX
# DATA G2YIxqmZiTwTKzSvypcs5vc2F7NuFKqYjdM/X5KRvRbcY+iC/hBdLIycUJisKVnsepUjs5D1ogUgStG89CKBZ5PkZHIqktApKxuj
# DATA c8VYZJZ6qMx5Ax86yLHpFZ+pCLcn7dYKsdDLXLIcP90CM877K91iBT2iJJLTCCxWGnJmQyUGziWpSWB5Ox3GIc0Cp2ygjqLFKY2n
# DATA S+RxrJxXoW7JCjdmJvO86EKja85Hy8wSDg2+jzAjZZ8be8CwQBgLcO2Z2+a2hN5auV65D36wcx9MFXZBtwhdN/JmzN7OHp6u9L+a
# DATA bSPFCqtGhKbZyBhH0zibs/a19yH3mCF7CSZhegRZaSgzzjLNqT9JUulfpa1I5zoKgUiGW+Ba2uX6VL343er3d+5W1dhF9hXk9ZHU
# DATA UA1Uw1ATrE2TlHVvdJeJNhbFDoW3hU/HQRwHRan41vHRDK4emYhqCxOOFZYGh9GZzlPWq6deV4qZ43EdbW+HhL0UXeu7l+pataw7
# DATA DJNhGp6ggfDuhEk8shaqlXNN36GshyjEtlDKHMjei71j2zOY0XBhaZNnsFzUPHb5mbVstT1gkIZz5DkfCdX7KbSH7NnKdWsKr1Si
# DATA twvwfiYP7avvU8wRmIOIRvt4kBURmF+f//zsq7M/nz09/zV9/gV4lsBW/pn+/AIcy/Of64vrsJjfnP2J/v/12R/P/4Fxl+f/hqGY
# DATA fxYkJgf9e7rya+Zn/pHJmd75r87/HgDN818xHZPCPvvT+b+nIH5Ff39L76QQcNMv6Ic/0M90zz/RS56e/eX8Nw6T+VI4SrEtDd2V
# DATA 6hZVzeOgswPxRfEQ1qfpQYW/H2GzO7yoAyDrFKjlOGTPVWimCMbnGnrwwg3GNe+9R/MJzBfqTFFYiLUyaHJ14K38zHcmNH5JS0T8
# DATA HEHT9qHqPuO2CZorhXJzDE2ulOYubC3kNXXlAVwhblLVjhNz+wP+6kG0azmBSNh1AjTjTKIC76HsbIxw5jcEP+g0Wjh65i5ldwPk
# DATA TF4l5dXyeIqpLkIzFUB1T4uIj6gNUI/5WL/3URRmS7V8Szm2BBSK6QooOeorje85Y86Qt4gnkXJZp+wvJwNpuJys4jR3q5KbLZ1y
# DATA W3teRM3d0uGQms4uuAm7QLM2r2IOvBbLqbdmCly/JbCTIXApO+D2zACpl6VcsHGbL1qbugkOZyn5nGi4qZldaCJThm9qheI8c47h
# DATA xJgoHqd9kIZzi5eejfJfDuDTb0NmiC9H4yuzh9FiAL/3rjjOfMS3LAaKXJYP/1OxE4bYlwfVKCjUUHw9CZFP1hTsAV74prglw6ry
# DATA 46OdZxnvI/N4D5fYItqpSKMSkiv+KEXr5I0S7LYKzTKaQ2869KZDb94IenOnsWanKdBljObbnAJcZQZwXRMAh9506E2H3nToTYfe
# DATA dOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nTozRcGvdloNYft4KrozfaoM+q+
# DATA ROjN0uLzTvBNCj2mYdEbiMxYj/NycCp0w16esUFTdKj4l6Bd5Bf2hqOou5rLYAIGjbEftL6sdr2W7wW+59d7/KfRqnabHtnH1V6j
# DATA 2qp2elU/aHtBr9oJPL9DXxrFwmh3u61eJO8oxjloBnmc6X15nNtBHmUhi1oVo9VoR6soy07P81udcbc7qfp1il7nyx5Ftt2oBvRD
# DATA u1v1/W61U221qn6zV6otfjSI/BLzsN8OR2GwjnnYXJeUpsR+oGLcsSCMTSspxTo+7A4G/TVERr/rNYLul912tUkpafS8OqWp6/lB
# DATA /csqlUWjSSn0vRJaMYw6zfbauLW6nTxuFLCVzT2rZtSLtEi/OWi2r0Bq5KanSY3Sii1SI8Vl0NuF1Fi4AlJjEHWjoUVqDNvDzjAn
# DATA NXaGwTC0SI1+a9Bt3DipEXvbq9tMGhpwLR+X2MbmIW3J2FBCpHLkl2bEze63PfxLpobH5kYehB5vrSVG+ZXNyR29/oEVv7VzCQ4R
# DATA gsK2z7+Ou3kOok3TQ8sAL7hCVblfDqwo7q8cClnKkxblCf3bkH8Lq1XNlsFGdlrfXkt4FGOR0ixzvny51FrAWo9w3IhqvLAyaHty
# DATA fS2QTAns4ts5nFLR8Cy2NBlyHEjHgXQcSMeBdBxIx4F0HEjHgXQcSMeBdBxIx4F0HMhRiMZ9168KT1E2HQP+SNaMRj4+0OfdTyLl
# DATA z2Tc457CReICnpCgUFXfx0a/PZ+RjIOpsB8Lgai5qhWKXLk4GBGRhXiyOk4vR+29eRwNIn0aEWfk4D/sozyKHMj85I07He5Oh+98
# DATA Orx8RMsdFHcHxbfrbr8wB8gfxI+kCVVofJqdYsk/lkOWNvjGHHm0RFPRZCZyqBPPPlw99YyjoNzzqrPTI4QiJzOzcBJdUj7bqFqK
# DATA 65GbON2cTOEatc95O+XsXZSzeUcJV0V82Hwf+kvc9iP6u0UzmwbFheAPP5GPL4NetsmDS4pEvr1ZJFLlpghEvo1TnCMc68aglOtB
# DATA YrOMR5Y7VRWcB8fpfHBZacpzCgHPSTySE8zJgikQGQ9NcEEhGG8UUT2awCCiCUsiB485JZqI8izamVfNknd2zJL3tCYojck6Q94O
# DATA J9AVYK1eji41Jr5gzlzLEg7LinojeJfpaeQUL5DwvA7MORqa8YeaIFl/sZzMR2Cz68gY3Q4umS8/2pwv0qJUTVkO2TLJ68gsTGlO
# DATA 6s1oTuuhn2EwKKRbsSABmYEc/gOLhqtUNBNCGQQJMuaI0Oc5+vvjU23cPMc68q92rCOfJEvWsPjp8ijPD602Pdfq08l0hE0jwDRQ
# DATA JzDH9AoNgmlGCmM0JFODBrMBZdxknCxx4q3mfYYJAWsrsFKC2HVHk/BnRqjjGdVn867wkvnzyRbtWd2pSg7R/Nqb60uSQ5+kyTHq
# DATA AKWZZjdHkUHH8iY5qjThcgAVjvszbzlDcnUPA4FgBqICyzSB8j6konlx+Tm2m093bDdcqZVyi4WsZUWGabKE+vgSShUTMR5SPiML
# DATA fz+oWMOh7lmgtBxLV8pmmS3EG0p1of66nB+3K2X7uig05Ga2m4S7SfjOk3A3437FZ9wbJ9MvtGQb72MxO1qEysq7Wu69RQ26XMJ6
# DATA /yWSa7bVdWUrpbU5VC6EE/5Wlj9b2RcpFWaQYOeQvOx0NtAxUSeN7/1gZVulnuSvqstZj/EXTk1hfJ8UyF6ATzDrhRXHhlQ9aQKv
# DATA /Qv5Q3x0moebF1S37mWSc9pR2NYzW6qk+hYMB7OBaouh9s//+B+1GcGvHAciZScWpLeIJhOeuijQhCh6fQ/2Z+YdiZUVLpgWMYQK
# DATA G81YxstpXxdX6KXj08V4qqxZNlh5bnAUy89i+bEYGabNEDWzNL883vMIkS4ljVyh3EqjXHDOqAHqFWjBDOXoipMwXdHULRYoQ42M
# DATA 4cjEqtdQVssKxlltzmrb2WpbqW9u7cStnVzBYttoHN6k+C4DmkZKR5/F3JHXvBBf0OB9/oLw2wwBnPPz7LWWlaUTsRXZthwWrhXW
# DATA NGSpny6/T/0vn/3mK97eYHoR6F4/arozc8GsMMgBkTIy3i+C7m1kfL3mb15/URsK7MjKpV1iax420c2vmPj2rjO6auMF/f6R1v9d
# DATA JItCldj79kXRNoGYaOdXLsjmuhXvxtZoK/PVLJjJrlRe5ZIqH/EWD9MUMgsRhRp27y05E6zirLYn2061/JL0P7GgquY0disj9o4E
# DATA 8YzwJ7GtGKWVdwG2KvUPM7O/BI3PGLcfiTPVKDUzcvhkHE+ivJ+IoVa7wF6dlCVvzUoHteYoF29meWC1wgkTVzauyNY3MnVLVUDv
# DATA tPKGCtVnegOtHYwu1ep7KFXLKd2P7cF5OKwnPQhn0A6eUwJinFMM0zkv9LLnGChyuCtPxpEY8HnHhZRBaJr7NV7YIqOj5imYHVJo
# DATA hKaz5Zy6HqUfXBSXvsP5/rpYzxaEi+foPIewOVz/yAyur89/KbwrkLO+OfsnheYCnAssrq9WCVz/lW57CkCXoLXO/ocVDn1iwNaf
# DATA 6B4N2frL+W/O/qehdJ19RTc+5Xf9/vzfMaELJx28s9+dfX32P6jShBMH3Hop7H827q2tG0AFpgnwrlP0E1zfjB3DpNYM8uTUJbF6
# DATA H/WMM1H9PmHdcFm60LLbFcUNPUJjH4d99FMyWxc1bK4zEDvvR5ghbINtfU53mQg51FbB9M97htumbZVK5eZYW0L7Nvwn3pJtvdW6
# DATA 86cZFbe+sVjBrhOxFQrYSsMV1AKhJMbhtS4ormtHa30SktGJnynWrXqlXq/zqEEZQF1UzfuEBhBj9TDBgidd43COtWC9838R9g8R
# DATA ScFRZwZCgeKKHtFAgLMFZYbWhdVts5lSbDzPC551YQIcN8sN79c9vGtm1uVH9dfDmXeLI/p1D+g7jec7D+e3MppLbSwk3fbRvUht
# DATA 6CYYWYWEM+InU8x2O5k06Q4ztWg2xKJZH5Z5iJ3EFUpoDKQPNZqYkjCJwZKaDfVrR2E8gb9yEIJVxGyhYrIw2oYmo6c0wOkF5niW
# DATA zZEkuEiphexKy8pDZs2ATN5H8WdKE29FH1Odg3uFLvKZcj5tzv6NGVb4eA67ZELUPBQHbDJkZJaYBZk5K04penBKxtsjeMriYahO
# DATA skdiGEYZ9iHG2RjrmCG8GgPhriBd8QgbEAfjaBp6vPOdKVxzHoscSsuhtBxK6wZRWheOQTtNdXY0n29vFnCVScA1zAEcOsuhsxw6
# DATA y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzXhh0VtBs1ltXRmc1
# DATA R51R5yVCZxVWnXcCZ3HGclx6nHGCZqr7BTmKtt8tZnij19uc4/VGr7kKcuoFjKRSQVlwqU692+v118GlGhLIIE5Zgkq9rG2xpRoc
# DATA Tz4w1y3SpIa9Rqe97vlWa6fne/1eu7/u+W5zl+e7Ub8T+uVMmAbNhhcE7SpV7FaPq3cwbfitqh/4Hl+ryrWq7zeqfrNT7XQ8v+vb
# DATA QfOG0RKeqzvsDnvrcpBxYaWa3+l5zYZPFR6v9urjXr0UnMm7leB6V0BgcRPSCCxpjRYCq9Fu9zvBVRBY9agXhRYCK6CAOjkCKxjW
# DATA h80cgRV02367d/MILJoJVen3nSbtQUBjZdFvVRhpZMTTIXp8QM5wn7QNp4xPnWAdQKpdK+sC8ZaTxyWXiTUGrNwdlsx+Y4p3lSme
# DATA P6BH7fI8cN2cT3sJu+wllNVB+AnXLLa1i4koLgTIHNGzJz7KkMufMMPgmhW7MoZrrcdHV9Sih2ETtMs4j1V04De2pl/8/YJ8Kr6o
# DATA jeSwX7Gw9WTz82acvuA1G6Zwm7FepoLvhOPaVnk3T+tLlXldnVxOLpxcchQc58txvhzny3G+HOfLcb4c58txvhzny3G+HOfLcb5e
# DATA M84X6oI6IR8ND23q1wJLppwRSN1dqevJMh1EqCBcqw7jERuZqmHea9Vh8CzGgBW8l6YJ4viusrzQvMjkoT46PZI+2bz2bsmYtuYE
# DATA bMJWMLmoCP0L2xq5HPaFOWYCoe/UVXzxBts1Yp577+dH/8mOPs3W9AX7h0/YRn+cxwZbLUfxjLJDUc1YRlTpPhxbwb+DzoeaK1yq
# DATA FZxjnIZyhopLHW/tY48yzS/5RVb8lKAudTU4CfVxYuxT7wRnFpX1Sb9xBKlac+7j1E5V/0i/fHeb3cFlSOWTp+tunrL9x4XIiBiV
# DATA iYMWaVRvwmlAxEOs/sMnxpj/4g0TeA1xo7eaC29SXwUKG12j1p4fg7wjN+rc4LNH5fSq5JrKtrW9cDrXFd5uwdBkDq+ngNheljzb
# DATA Ext6sEgnNOX7u7+Tr9gMSF/3/+Zv5Ds9Snn6xRvvMeLhjf3HGyxvZXRTV5gtHrDFvieF6iTunZrCldQUnIrCq62icFl1++eqrmAc
# DATA sJIiEeuzlNwXIarbvY+1DDenlA+yLiFtGW9OyLv67H6uPCCxxEPbHnzA7Za3eWFRaONThewQY8Fqe/lTdxBTrUPIR2M3CtwbEpOS
# DATA QqBWvV3c/oUTm3gJDlfzf6+ZnFAUxbhubkJZa2QtNeGyKlmfp7Ey3eIZsxrJdoMxY1SyjA4IK5dlsIBPIGQ2XYqGwyn7qStGQF8q
# DATA o6o8XFEwSmaiaG9pekDjIGSLPhktGK6URuxGZwKXAm6xoe/xwiDrjc+iR+zjVcoaF3KMXo1z8iYEZ9w5424n466klOM0s5xm1iWs
# DATA uo2m401paX0ggk1UsdVcXjkRuJrnZJ/bVmy8DZF75VnQmauT/pbeiaEVx/VtUE0XTxkus7OsILBOGTmZsEebAQhYK+bR7W/gYjpE
# DATA nyafDtQFZVHLt4r8Ybe4uu3HfiWoNH5Cg6KO0QZJeeVUo3d9wJ+4yhYRxOYW07fmD60QgANGNpwkHm8l2QIeborhDe5h6c4VUPBG
# DATA MXnjw8qrzsurI48pj8hLKRtpncTZ0giczaXVVJSE2b8Kj8MH0sUqNTMQVrQbFM1E5QPrvZ3MilpoopoVAtJiu+SUPhYNmBA9E0TS
# DATA 5FQ5Qk1zh8KVCHDR0yc43cVDJ2tOWe6/mmeKCyMi2cjLwWKpKEyTeIqLvNEIglUQiWPaBbS7Mh2VUkXIpyK2mZxPLaS0iq5TzC31
# DATA Cr9xHao5n6k5F8vOvxoWaj7MOBPVmag7mai2LeIMVGegbjU8n7fY68eFRjLDQLeIpzmU6YEsk7IAasWiAErqvPe0DCIEFnF8h7OL
# DATA fkdTGSY8VkOXk9VCwyOKF7aczU6NHuSOCq4cXRMbIUFRLYCgoxgE1Fip3Uesb4nOY423Tp04XmOpyh4FVDD+pOhAypLRP+bGlbnC
# DATA 0hNAzkccjoqd7Lkx3dJmVpHZ+MDQH/lctCutO0yXaD+1YjJi5wBGR3SMcl+8zcJEi9S+5M13WTq2gnE0X7eEHGXxEaf9Xf60xXYt
# DATA ssFlJ4FtsCia+SazsVDG2F0tjfUKAHadG5cEsD9+spnALhkrBHZM4iLNSFdO+1NNYv8MW0Yp5ekyk+1eXANnrJ2qhHQxBwKZU69A
# DATA x9iEEWIDhddfkqGrFFPjQc17N2aB1SUL7XrTOOPZo+x1wXYlpojyJhC5xq2VV4aFxAAEEb0uVXy2Z0bbl2rQJTP4n//hT5tzuFAb
# DATA JaNZ0jWNRPgXftV4EC8M8p5/yelLrH1LRrVoqSZzfep+QbUtZR1fHF5dxGKf3x/xoXCaG0z78dES3Efl+q3o7k5QUUJ/DMnYZwnf
# DATA eMi/yYT9OnL0inV1mu1WVz8Op1IVIGWdZ53UFkxxoGAr+3xF1RY61ZNoASSW7G4yT3uM8UDvxaCPU6BlhdY1gzIgGgRZfxQd6j2p
# DATA KNQGBdNAnn/1+9eXqnzCOuPYUyq+XEbLSOffh5jBYdJGE+hcifkkjNmZwxfUcfMIAOh3pUHymoRUnCyvqBwwsn6EowWcn5SBM7iQ
# DATA OKCFPAVMbwSKIg2VKLRrqXqma79kRn6wpe6pQULysLxC6S3S8JjGzRNKg87MT9VRgrESyA6lWqZkw0TDTBkF1MvNFgyOQ1iwS2R+
# DATA Qg15ZnoG1atOqdfIeC4ZQ+LRWlbN4XKLWMm5RzT/1SrcsP2ea75+tmu+fsYEPmu5Cucb89atlsPS6Aj7weWACCUkU0MGRptcvd5I
# DATA nmfsq8gtw2g04hy2+4Gwn7F4Nc3Q2L0j96jqjN5UrL4Yne1PZTdrKUOLRoLsWbSNBHNFsofsWr27UE/s2Nmidv1RRzQYJ9DPCuEv
# DATA pZLUBfFaLLzZGD0qicgm6P2ns2/O/83Z12f/8+wv578F9+78F0Di0X+/Ofvd+W8Ejff7s6/Of372FH/P/nL29Py3q0Q9Oxxm5f2C
# DATA aXx49pvzX+Opsz/SRebtCXqP/v7Zo1u+Pv8Heu6v578ETg8x6KfRSdWg9/54/iv6+1v8zMS9Pzu03svgrZGaZvPmZcr5MEYrncm2
# DATA YBAbfmh8M6J8D3OMLIYhlH7YUpD1Dfz+UG8nSaNBPFc2V7ZEf8StfZqwWP9Wkt47Ei+rATmYnu2lQe7cNkdvtUxuDqUnVSdfSfxU
# DATA qpJInpRvRk9krTlGJzdCy+Yd1XN16IKyQiaMeNs0mi0dT2+HMrt2pJ6Y9dyXc9cDL7P4zfpkQOjeTex57sY+y7slqq7JiYL6aMI5
# DATA 66wJ+pcPHaDQ4ukUZ3QAE6LCNjDiS9W/LRjgcqN6Xoi9ixPhGHtunH/GcV4j9a40vL8mCzC3MrTfwMi+08B+mXH9doZ1qZLlHLDQ
# DATA es+z6dwESa+cVL0oIi7VkOUmSyNiZg+JiP/KmFgRKJYszsoaqyhZHEeLZM7PRBkfaE/IXFqMk2G2CybvU+ShLGOVY0TZCw8Bb9yl
# DATA 5E9jbDBJyCrDni0Z6PPqQu8Ms2UKMFjIAqOUyezPr2i3fRqh/XCKTrlkRAdHSIBwrDCpTleGLJwI7msAZ7XmmTkanqPhORreDdLw
# DATA dhk9dpqr7Grs3qrdfhWz/TqsdkfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxH
# DATA xXNUPEfFc1Q8R8VzVLwXhorXagf9RueqVLzRqBcNXyIqXnnleScwXoH61uhZ1LhGvWGob36nU+TGjQbdnsobimBMI6sJopEH0WzW
# DATA 87IJhLYnh6eCXiG8TjMYNAYrBRW0fC8IgnHQqR/7zeaX1bbX86t+o+X1AvpTr3bxpdoL1pTcKpqvFVBorfq42f6y0/E6frVJ9cBv
# DATA XkCdM4GtYOKCztoM6FrkPoq8VTkbrTwDGoX3fqs5CNqN+kqUG+2657f8L6uU1ibVlmrHn7aaFPcvq0FPX7lyAvzgCqA7bhUadCcN
# DATA zALddZqNRrO5A+huOGoXQXfhsDdo5qC7TrvVa7cM6G7YGdT7Fuiu4zf8ZucWQHdoUtXt9obHw4t1a5kP972IeoE4rEjApcW8FVRc
# DATA gxfM8uWyYtDKbllxUukcWnFElvz9dljrPPCXGlQ99r3V2XBSz6glsLVJN27V1Ugas7yIkFNhC7pu/VaBMtFuFbO2NmfMwKdXv+rb
# DATA aHA71IKbMkUc2s2h3RzazaHdHNrNod0c2s2h3RzazaHdHNrNod1eM7SbDXOTZPOBrbsCUhvilNsb+9+Rb7zkyFguhTxLFuFE7keL
# DATA evOjcDGu8Uxyjy/uv0k5gOOo9B7lRJtDY2Y559v3Cu+4I9/ox4x7kUXyPrbj7fl2KJ/LYTIrkPI7S8HwsytHzjRBTKaA5kiHO0Tt
# DATA DlGvO0RdOubjjlO749SXPU69Rfj2po5ZSytgOxh67bLKao5ZP0chj9ugLgzV8WxVM/DV2zvaV5K2utnN2IGRC8Crp/K+SX3PmQVF
# DATA FsM0ZgG6lsI2sO9fFp2wxYLXomr+ZuFbGU8hxWyGNRQDDlVL/l8QXf28ia+5YCLst9dFuGtFONg9vjyogtLG8eBo0pULIqkeynV7
# DATA 1fcCB2Ilhr4Vw64dwWL0NvIe3lEtKjKiQS8v7uEdtvJ4GGOAFyYn+kDyByOobKIP4WP4GQ90aHsZmSXzCvs0qZVO4PWfnHpQ0kQl
# DATA i8HLE6NIvPVC55Jax+fGqRmqEIcUBAUIM2esAxwkMHpUSPo4OPMnuCZH2QLr7jylYgmmKVvElggAToOzAiMvow5xksyTtZtDWwwA
# DATA Jht6vyyZRroj+pBmL8eYIY0ZgMHte4DdwSpBiHbe11wMaHh1DhY7SKyzZLdbss5ufcXt1stCYZ+7PBAvmFsLwatG36QgCcjUn4xF
# DATA txX/oM/HSGGKbGWoPndVoZdEgeMmsKkrCkjXTU5doya1Hp66mxJiqf4hq22aAotIv50irWpYZ9X2XEGa9/ToidAyEziV5qeyLRZh
# DATA njU8LUi6hB42Siynyj5DBaMPWaQMJQQmNalooCh08vt8gzFKyhLcHOdPWexVohxRFusYf2AmajHPASmqome0iNMKK7NzbLQqe8FC
# DATA 04r3Nj6ADVIERVYAjmBsifYnWJjbHusHgK6oWPM2pWioI/6elrga0uwWsaEkcO5VeMpX8U6xWVZUndBjLJKjCCpWNc8yqhNWFp16
# DATA DCpQ1JdN0dUvXI3xayRgY/dJztJ0luY6S7MwTjmPqfOYXmSgPn9hSolBppQV0ySZskodN4hcnnIykaayViSxpup5RZwVFRmMoDuH
# DATA ZoT1aaaCsWfFk9U71a54GfFyFLD32UpQ6o7SJtVyI4eJnm/O2E24gMMJNjCIQLaDgu0CBROLyzatNt1p/NxMd9FfNt+vVTo5V9Xn
# DATA zXdrGc+i+fHiY8Ty/Lskx8U/8NubUS66MATl8oNZRJ3JnF2LVRxZ1JYh1jf8lndkr2QEzTpdUG7EzyNFIKMpCLbKTU4rZLdj72+f
# DATA 6sUIXxcYLxEy9pBkWPOQUx0Z9xAwtk7CbCxaqtpCp0uTSXYdHJxbyb/PThLOvyGNU/Ni7jXqxdxrdq3ce8ALNUg297Uqk6BYCqDz
# DATA guUoRRpT7hK/8CQCvgibdT11CFeESq8htwpt8PIZ1tqcYVaDljz7HvWpFLv3U57KzmUCk+dbUKp1jU7LyrcFTCleJmPDKZ4tFxhy
# DATA IFo6KU6seMRgWA/VPJpdKQqemYQdY0fj5AXIu/Yl8u4dVIFUZCXy9cFC9pWqXSOol7KvwlNpNlGPpCgymqeKUiqIfdIasR99mIYn
# DATA 2MqrlwZYbzZfGniWPLP78Etm2Ueb8ysfDRTCL3kYautaZ9L7zKkQbgTQfUIvPCabw5jpZOE+pIY3UWinIasOT5Mhk/y8MdaBvU9F
# DATA KJiZVrhilk/MqkxGAz3lOmvyokVfR7bZg9mla1qwOePygVEyzjgGigaazsMHuKq8LjPP71ING+q8Cr1Gm/cMUUXFtkB2IdB0STli
# DATA xHZjjDzXtcQ7WsaK78XcWOW9YbORt5y/qAivV8UhkWO8RvECErM2x+v/PXt6/suzv5x9DcbWU+/sD2e/P3t69t/Pvmb01terwK7/
# DATA TD/97uwbMLbO/y1u8QTJdfbXsz/RT/8/e+/W5MaR5Xn2sz5FVLWVZWYRABEAAhdSSQ1FUZdpScUhWaWdLWllASCQCBFAQAggk1kq
# DATA mUml6elu67Ips90xW7Ox2W1bm4d92Qd1VWtLpSqpH/YLZH6F/iR7/ue4e3jglsgrk6SriiQQiPDwux8/7v7/fXf85fE/FhAOhUlh
# DATA fU+//ck7/jv8VKQ7vqXff8Nv+vboe3rzN8dfMB4MyC5FAPsNff0TBUg/OWbX8+BSyaB+6DKHNg9I+pA0hg+UmqTGBU5mnSmr30uH
# DATA QhkWTQW+uI/pXzwUF6S0W7hQezh9Dg4AFEr4KXAYeSMqb/fsKI38JBysxXjdx8p4Nzw0MXUcL9vXojqIqwZ5LSmVyyN5qVqYLRk9
# DATA UtVyEFM8J4fz90tt1De/k6ukFwnzgstQxUS08GVnfqTj5YBemxXdhTO9HkUZ6CBjQUwASdVdlqFycMl5KXob7AUSGWGGKphTxPD8
# DATA HOJryXs77urZMfVuMr0W55RK6QLZ6+TKuNqeWWxlzwrtdXIqHNrLmQMXbw5o2tfZrICXYrXlqiyAyzAANhr/Tzn8X83oLxVzIRcs
# DATA 6Nc1a1SXwQFbSD6gplgbSpnzvj5lBa6BUL3iJMyn852p2hrBWyBYJCQOJ+ZNOihOuSw4oTiV62AjMthj9vXCH4QNOClcb9EkHBSU
# DATA JUcDWtydofiiLhcjjLUJ1RBeQ+5mmCeOsDYFzI4RmAcUqLg84JyiNg7XTDwqUhYziN0j62IajyLtqOLlM4SOZWiYLQWxWejFYocY
# DATA EJSjhDlKmKOEXR4lbMMhZ6M50Kam89VOA84yC7iISYAjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5
# DATA UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVLYtSGF1drVLv98JlJYoxf02s8RKWxh6XkjVJidL37gVf1mP6i35mhTdeodm9Ey2lS1
# DATA KTnEZSRlUGNFSiFl+X5OqWe+7Cq+XXj1XP6bd+ZCD1r+JYbeqmeB11q5wCVVWeB+tW5DwHKBt3rNdrs3H3g9aF146DnQW01YbAIp
# DATA 8+sZ6C1o5gKIgjBsVheaBT3u+X5zvxYMKk3Pb5xAIFtdJxpnAJBxY9MAMmm3OQBZELbqGwDIclcAIAu6nV45A5DVO0HULBsAWafX
# DATA qXQjC0AW1Dqt1qUDyHQDXQufKvmBppDl7jejo14gCDahjeWD0LyxrB/XObXgyLQebWNRZskzmy4LlOrKAqnYjodKacmasM8GUe7N
# DATA OY+CWAZ4jucvxpvkB2QnwKRa4pGsGI+kZMr8MsuShb5g4QWV23quRb23n9klc9Fvsj23jIvWarXyNDSsMq+mlOXKrTBXFmusnfyN
# DATA c74H4z50GDKHIXMYMochcxgyhyFzGDKHIXMYMochcxgyhyF7yTBkqAsUSncQFSJeJurulgvsdOdPYzK7o3T3lx8V4FDdj3bZgi2g
# DATA o32An3ZRJW+bCs2ny2AdTbZ3Pot72/LQzmc6aGqhMEHCUScqjchC3SmqV922g7/Nqs764Ma2RG/nNrqCD7ceZ8fYuoIT+9ya42Af
# DATA oX6/lCKOfax5L9JPT1FSWcmDJsaTbdVbQZ9Y0k8JGHVv7I7V7v30pzDsblP6EPir9NvOZ/z07vg2n8mgONGPP+JrFI+lqckl2GT9
# DATA bZPht6XWYULPjT6rYZTnbyp9Z8p7hYTTJ3+M8rP3GIek8ucvJxR9JnhQfsSJZJ/Y8rc/X/06Jr11oniwvU1JLSLNOzfZtAXkTWUJ
# DATA xYSSbOoFNSROfYnduDufZRXGuixxt++jjLO5eFkNUrFErkoOqbFg57Msw1B0KM6YsjF+VZHzWNIN6Yxv3NA3l8YzMk0+UzG/JXfi
# DATA lB3dV+CI0MT6A5y6+7cv/qs60whsXnzD36EuhiKxEHzR31kTNo5H2mE/xHFJXv5YDP3zrC58ruoITyZ1m1ysyuqB27naf1vq2S5m
# DATA sLrqWTcUKkE536Ims5FICQuhj6sDtzK68No6Azdr8+qpCc6QnvQUl6/dXVg1P8uBuX5mXZN4CJXVrD2oRCEqOklmDrgkWnwGJR7Q
# DATA fMj0qboGmsdkrNjJRZqCPYhHNF1cFihW0uihaC6THDPG6UycUWfC6Uu8+PoSpyXJXAfdCV5Zyfnr1+Nk3sMheBA5IL6qD06He3jV
# DATA NBkmE5qZrWXKXEfRiufnCPdlkGYWNTYuGjWzTMTkjKwZL7dEJFWaV9ju+GUtDSyYTSMnRi9Tt0DAU+pJJvJhC70/IausIK4n0bJH
# DATA 5I3lLat5yRizSMD1hPXQn02mLPUVq/eOaeQfiX5CoqQ+jIj9GqGPk5RHX6Aj+rmG40woZ0JtaELN9a9OtMuJdlnD70rj6zqIeb0+
# DATA i8HUystWGSmvt0QXym5KGHnGUYKGdtBPciOUIAT0AFby7kLEBkXHmjqhzIUVfCx6Qs0xHMQ9KN5AdBvOB5GQGkVRV2PGTstPMRFV
# DATA wAclpw1p9cISJS0HT9kEnjJMpOhY7159XgdEmbAbTSTw5fPqu7HbR7jZ9/jT6ju1uaP4Qvz5eUCn2Ll3SpX8JgzH1Tr5WVnkWBbs
# DATA 1dPi+DwrykY2jF+TZLbXzxrDJwx7ZwkPjUuajch4ZC2qbMM02vN+ErO2VYfNQ0+foIfVOGOxuTHL98LYpDjsRdOLoAycI/+C0+Xf
# DATA G1H6xGNnu4UWgDaugjuZ9LJknLjCU+YZ2qbDQTh4Qnml5QM5PNw2GwDTzahGLxpxGbB4G05BeN3ZRIvr0iB1MUyLrBmeFs5QWZ9v
# DATA WauWfHudxnjZ98dMnVlsap+yrajORdFKIUOsHo3AspC8ZGk6WUxIFb0rSqcl728YiBF1+qP401lkFBSpktKEDqyEaR/Tjn7INRH5
# DATA OlUV9wJyM+umTpuXJ9RB3etJTn5AdYdVELVUs8GQmkyiNHIVYgtVoUYNEp4s3M4TSEHOmbIq90KWXVTIv0GkJpmc7UpDzoh69/LD
# DATA 8LNqwfXTteDXwwHbEWqqENksGhgHnCHpbIwJGCUwnLQP1dygIzqLstO55PFKDXKX5cgniu1GudaLIogoYqpFFkWUjqNOzERYUb+c
# DATA HLKeoZmEj6KDi8hBe+w7bQUsr8/CbChVsBVUrom5qCm4NO0acteGzl6Resw0rBOCykMZdUAGNkx17KDw+mQRon4hy1gFlIUPqVJD
# DATA B3IfW8XUHptrC1V5gVwbWRDOr+H8Ghv6NfI1zbk1nFvjjGtCK10gl6ZRrqpsjv4KU5yqufFuPHNWxjrvBjMZV3LseaM3L3Ng97c6
# DATA uaivmUkv72qwR05zRc96OZey85HYGULfkl5PTIOwK3ZBziHBu1roZ7aRTK+zrban7Ci/iG7hI97Qj1dIpNTTpmfU3808vyrHNzEM
# DATA TMi4J+OFz9zh4jB8KneU5ZxcNOajeat9J7xJhlNilenGUVVPm6jq7yaqlROj6jc3jqps+0Fk+dNJcdO3Z7EzV0z8asui51vRq6yJ
# DATA nVoVNP4sORfA0z/w9m7yPsUhmdhyI5sfk+GdV0VaIctCHAux62B2KVfnxjS4T+U47k0JIqvIxjdjtQ9zaYUDR0wimgx2LVM7p/D/
# DATA H8k27egJKk3MexglDUhHpgwHIQ3vgO2M6VEy0DADU1SgbBargZSKTqgmW0JJNXt/LaQlhuRkUGSYJe/Yord0wcNMhCYKL0rB68a/
# DATA +lWMIYXdK6NZCkH+9JBs32SYZl5UO2b9aDA+YeF4rlSzxWPbr5otA0v+y54tevwBPmQlfqbAZCuXNMpoalUfsWG5xF4Oq9xiHc4m
# DATA ZBOTSWfTDv87wwu/AW0wzyA8/i3+XqQd/rejr5lH+OejH47+4B3/p+Ovjr4/+u74P9OTP9AnxS1kxiGIhRI4h+wxEPFrYBSPv6Ab
# DATA fn/8D/TQd7jth6N/oXD0k384+gG4xG8Zg0hBOubh8zDDMNUrm1hwhQfxBDlKzxSUv5I7HI3EYOEkQ3eWCJNF9IBKUWgEMKwMwYN6
# DATA Um30jOOoQ7PxdXDDh3obAw0AjFZzaENrMqEL7KrhhgulcnloQ1VH9G3gbGjiDv+ycD+2r1gd7qOkp/a0XDjakCOQAxvGKVd2hzXc
# DATA rNguHGt4/+l4gF4m1M6QYdKdDUKQ15Mpa/aUvA/Q93Pfle3z4sUvbIynZ83+J4rDbMg9ZSrboOBCSaahXssKR4KOWQAanlwFV1st
# DATA 8y3rWeEMT06Dwxm6kf4cI73mFp5lgH85PIVXNrhf/Ni+0dB+ypH9agZ2qZZzeWAxC59Vy7kMOOFcKrECABKQ4vzFHSux+pzjfIJC
# DATA cWkqqBxoa3oTdYri4c3Xsq1YS3TDShqxV3Q+3zYkEhovaxa7dJp0eMWRx2ONimN+HNeSLs21R6mJfjSbJF44ZPwbD/kRmQ1xJ8bS
# DATA eM4myFkA0VMcLEbg3QjeKLWjWq0VkvVAxfleFKaIENt2nSlcMWIksldHKHWytq6Kuj07lPrlaIWOVuhohZdFK9xwqNloarOpZXyV
# DATA Nv5ZTPyLsPAdq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r
# DATA 0LEKrw2rMPBrtaBzRlZh1O35UeM5YhXOLTyfmlQY+F7VL+8XW61P/Uax2vAaAf3drwaVT2str+LVK161sd9q5XKp47ernd48xo7C
# DATA qi/F2NUWyIZy0k8Afq08wC+o+nMEv1ozK2s5tpYR/KJmFHYWwYkWH7AZ5IKvVFv54FvVlaGbZOZCr5WDNaEHZwrdLpGm79Vqjf1a
# DATA a0hda7HW2q+1Ns5pfxFG2PC9wG/060EwF0on6LTbnaUoytNjB6XdaOygNEELO1jvBs1G90TsYNhr9+o57GCX/u5WLOxgtx40AoMd
# DATA bHc6tXbNwg5WglqzeunYQbNNDcL/exvN19dw+8S+9RbsIm2Oz73NDJRq6vVWRN1NHBYkfksBhoFaiass0PqwsLjwgjm3u2006gLJ
# DATA z7vJ3PN82AFeXf7YYbJ1unEOBdp0QqaIkZsP6k44b6hY2MB8ZO3NBXpEV8te5WXeXllMySetAt8n/6X+2DPu9cTBuWwtzOfJGrNl
# DATA bZLZnnDAQQccdMBBBxx0wEEHHHTAQQccdMBBBxx0wEEHHHzJgIM2302SLV4MIaXxUXFEf+enzfKNSrlAM0v10wEX4Y5M2TTm674c
# DATA kuGDbmhkN/hXcOk6QwQcef/f/+61yvjWjaJx6UP6bwTaGoV7Z7f82odbH7CWOp+j44UaBEI/ShAlnvJQhCUsc/gGcfHah7iX6Xhh
# DATA O0WIO+YpfOJ3vWMfZZPUeVE6hR85uuX922/+H0RmIe3b1Ur5hlxlcU90DQhSo8wcQsyd7T7pbLc70/2in+k+LSnsOpz1nnOxrceE
# DATA vYumYZ4oee+h2tvaLkvhYM/0dPjzczTyMihg84fZL5oBtigJcFYCWN5fq8/qv8vULqkI8ppeZHRt3oDrMfS6Cf2QHvAZ7QdwQqJq
# DATA sRRQP4wnJe9RPGX3kxZ8lwoowuWzsRxPVoWbO74fZlJGY4g2Jj0+i5yJ5swp3CyU85MIpnJo5HZgE1290s0zOgVrtSBnDDljaN4Y
# DATA WuhRneiNE705yYy6HmI4D6S+MtGimxj8xSdJ2yjiPDTaDdQM472RIn8pDTWFj5zQsNCBuEUPN4uSRBoCvwr3qMbj8IZ8lu8QHRq4
# DATA IQe2dssSzZSNwV+PoToD/1imZGPzYNh3IaodDve1Ge6LkgJ9EpX0Kbea1bAvdjuKLDR/XH0vb8/lnuUxf3oe4F1WXpySu/JoDT9J
# DATA 56oQV+6hVVDpim0lwJXHB4mINSUzCMaEkGMRyMoQLUVLJKKGh+yFElkmMQ9pXNuHF/lXkGeZDPPqRaJSRLZfko13IQRhqHaEolHf
# DATA Y0NZnzmVRqNmB8uFnRcFoM3Cm9gkWQJNjmkpB4wNWFDmjKEHLEHo8/GvzlxyDzcuuYdywFysdF1078IWQUcYMhuAimNPqX+nTPqK
# DATA xqyOo1hCeXQYio8lfUTtm4pAJql3NZ8RHkO1L4p700E0VWCBiYpLOk6m5y+yXMqursyy3uSUZfazdbQy1S9Jmf0MAkTIx3ZCEbIB
# DATA USxNpNdRtKDZnjCyKHepE8fFpEfWiOFp9aID0ZzSg9tUJOFxpyzucEkfMP2NmSum0XHpt2fp4flLK5+m56C43t+4uN4PAW7nxQzq
# DATA 6zMeVdoXLX3TGKjX24M//El0KNZ+O4SCltdPhtKwMDkYcWisUTfyqKAmoIUBlQNeFTvge/FTwccxNCErzHnht/MXWj5lV1Zo2Sh8
# DATA yjJ7vLrM9HiuekVRDsS1rLzEH4F9+BgGqAmlwgociCOG5ZE7apxgb5x3l8u3x/gu6oQgQoZxTyxPHJvyxjM+PMfiCSOgXS6g38vi
# DATA fv1LpLJpibwfKeU6DB9T9ZMiXMr5oEgPMNKcxNoQob7E4+NdaAGHIkgoYEDVarh/45k1AoDZzUNZnGojBaUr+ncX0GYWE3KmYrpa
# DATA wty5MCYvg5/NCsI52pyjbd7RZlcp52NzPrYzLjau9MldkuC0TMllpocREJUbNqZxsT1DqMElkedyniy99wT2Pm+yxvJTk/fN8ExY
# DATA /X4C6CwLxXRX1qWMGncS6qy+IYftQHvLDLiL5wVq1952Z3gi4E4CyAB36rsFuFuKjfPlsgbHlTeG3MluHrgL8UEYY0JBhkox59Wc
# DATA A1E9kHkPdQgLPrtGmbFf2NbuHWAhk/cXNcqrvXy+z488jp6iJ+paT9Evax6r8WNv092H9jO18ho34UpEnTZNsZuWLLXp8wups113
# DATA B30KxfuELM9RdFiyJZ+VrrN0AnAIHSSezy0tnChYnN6wNqZpkjLdsepMnQXFCdMrHrgpaOOOF4cG9y3isVfufq2uzS9W2848BlxS
# DATA gVUrZa53VgunPmqm4ZdqT24nX1OhN61k2CkUrcJeIAv/qXR9I4rjQKaKrJo9nk0AepeF7SRl/VRLIHsDiNwLYjxnCDnqRaLOJOxN
# DATA LYTce/pa8fhvj344/vL4N4DIHf1hER33T0vxb/TlG3rqq+Mvjr/EZY/++YYu/p7//hrgOLry3dHXx39nkHDfHn2jFNKh8DWGdioN
# DATA 2Q4Td+1NfbbMQ8/UGe/fh/uhd78by1ksEb1X+0p49tubxNGoSx0IfztIJoOusf7h+Z6NxXcKV4K4zgaHTNdN4NIWiig7DbIFCtXz
# DATA 4KnoKTW07lqE3OsQ0GCtCY//Fp6E48hlMwLTKVw1R2550VweTK5P0WFyQQan5vqqr58Ek7sXiiT4ZQDlePMV2Y70L40J4rrCaI4G
# DATA 44BymxXdhQPlJM9CNnNG6NxkXmWmU9qwUZOpoXRQZLnoisILfDS8od9la3tvFlKjmEbUt70Rp08KsH7o6XsPfu6l40iRMnD8ndKm
# DATA VGFmbAPBtTjdgDa3vI6uNnGWtsHrgp1bnhiHnnPWwyVZDxpLd2aj4aVwIV6dwXBJ9sJG5sIprYWrMxakki7LDGMoXM+GdhkUOysb
# DATA AJrDInE3GoNDRaaMGahNDvFsfkW2dJLhcIbuGgt472AG0WGHBUuKpJQvncge8ScROyjE+4cMS9Vmexrpqcj4ei+e8CnaNN2YcAeQ
# DATA Vqp8sxomRhmyTxbhRPwc6tcezZVjPuDAO4LeSz6hEc3j5HUoA5PetOQ91PGWAwoKFjbvBF6wW+SsgEaQGU0LJpkhP6CLA+ngPmVy
# DATA 3BHvMad9JO4a3ssZjZijgxPyaF0AkakqQbnqmHeOeeeYd5fIvNtw9DrTwa51ZvmVzzQuwqN61nmGA+A5AJ4D4DkAngPgOQCeA+A5
# DATA AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkA3rUB4FX8ardaOTsAr/pcAfCWrUBvRMGz
# DATA eHGVDEcnp9GyfG/MKZQGzVx21YJWI4jmyGqVChVAbQ1ZzXp168yvblbalXr17K+u1M/86mqz0a51z/7qavXMr65XWtVa4+yvrpWf
# DATA WVnXGs+srIPaMyvruv/MyjrXrlvNq8zwXLs+3avPm+G5dn26V583w3Pt+nSvPnfjKj+zss6166st61y7vtqyzrXrqy1ru11XgvpV
# DATA Zrjdrk/56vNmuN2uT/nq82a43a5P+epzN67yMytru11fcVnb7fqKy9pu11dc1na7rvq1KzUVWmd+9Xkz3G7Xp3z1eTPcbtenfPW5
# DATA G1f5mZW13a6vuKztdn3FZW236yspa9v1UCl71UalH9TL+43gbfqadzo02vWg1ln6WK3W4Meq9cXHanB0NE5jjqkJiAWX9+u5IP1m
# DATA tVpZjElQDrxKEPQr5WE18Mr9SnkuN9pBFLQbS5HszTPR1KsZTV38ORZNvVkOo6Cep6n7rapfCXI09Tm+Omjq7ajV6WU09aBSr9fa
# DATA hqYettq9sJzR1Gt+0KmUL52mzs7gYps36RtPpyy2ayx65m1tisPafmYeiG6W4pYtu+mNGg3eoIntmcxEX9ztWIefVV7DB8E225ZR
# DATA t7ZlrAS6W6GuZ61LcSmnZWCWXXSN4GMJ/bCbHNxq0Y/4U/ZUKX5eolcN4QJbsQRbWQhufR5mAXpqq6nevybLVubX8ZLdB2qtV9cw
# DATA swyg9oJmnu7C3ImC/PJ2eTVs3S6pNe7wZXWNndzsV3dQdQdVd1B1B1V3UHUHVXdQdQdVd1B1B1V3UHUHVX/JoOqZxai0G7Z3jH1H
# DATA qfYeivZHJvxxW4hV3GWzrTw4ZFy5iIoUh0k32hV0BV2UbbZo1Nk1EZkowgbZrQRBPeCrmOWJbFq6q9noPDVWiHP1GxqlBqQjYnBB
# DATA TCHMttuUwOOhgo1kv9TlBcm0i5C5MPEF1ZzbRimloTraLhfqtR0YRziosn3zlx+q/27t/vWP8O+Eg/no5l6BytXitHPZeotweqgK
# DATA 7H62H47iwSC8VSmMBzOa9qe3qgVIxt0KPv8lR4WnsSYuH2k8/aPZ3l6UyrjIAmTew7vv3TLY+E4UD7bxhhvz2fPTkt9kmvxb8esC
# DATA rX+d5X8yHd65UCQAEcChST6C0Pz4cSxQeb9U0UGic1YsEYwKIngBTT0ROuQXqjoDTbwp5PmmZC7rGiRKQpBsUUB6zoRMQ5auvrbO
# DATA nOIMjnsrLNnPzEQDEmlz8rT0dFbJd25jZIHjak4jB2IfKgFQcrElbzjGMhD8uJAX6HA6dU6n7jQ6dXNiLk6xzinWLdH8Wc2yuC5K
# DATA dt54gnbKGlr5OBkpu7t5Sbe9GaRxIcy0SrtNgS1G4M3GnVgFjfkdq7FqsSqm0c5L0uXRWgtydOa+fuXOAwxN1LXoiIs3XMtN/ULG
# DATA baWYlpGvYAMnTKgHBhCoGyzjFFlFf8oC9RJcCi1fT8Z8PdW9DbFYaE0ptTkgtjzrScZ5QtmK4hxBG5+SEsO41hxCPvKX9Dg60VNA
# DATA 1ETWCz2VeZhGqlVKfZzuN5RdxHJ7mdKtGhp1+h8ZQ8rThhQU64D3EaVimg8L9UTlUMw6FiXvFxg5Fx7p9GfQLdb6Y8pcKXk8acgN
# DATA tIIHFgCqeGoLOapwZlGQcQmFPum50ccyZiVGhBlUTK8yZwnSdTlyV3XxkiOqV+fGYnJjmowV24DrSjJhNTmon6WzMUZobDmGnjPV
# DATA tU7Utfr/afhE4AqwCtmeweRrfKgKVQ8u4UF4mFlUMgBJ7OGr9h5H7MjUcWOwa2iZYgwitoccrlvxdF2y+f142ycJZVobg2HIdY7m
# DATA DTrh78KD4lm2vVYFZBpUXi9QaKgs2kVRwsLWmEuOpeTCLnXhsSHbKEE5nQCRodPwJz3ByATlNOuGAZ1h1sqMqcZUO23KqWygPmeQ
# DATA HLLXdx6yJspgL77AWTbqOAPVGainMVCdOfrymKMrzcxrLqxsL/AvIswGOTtVWgz9Pe3zgARbRVmo2SOs16NQWNdVfvn5UhM9Cehg
# DATA beUQ3BxvkbnzKnXQ8y1VH0fLbfJqluc2eamjZuGAvy1rL4vHxKT1dxK4peSNh6OOjo5SX7rzs4VTZuzBJ5tnhZC39Sx/4XTNQcD0
# DATA Rhqtlf26shn7Wnma80cbY2ywLRdvVlaZlgdmXsdsbNmShsFJgz3sUT1dMJivvIGZN0ctB98cvmK+Lrw+i1HzF/W2pVIsELtOJHyM
# DATA 1IsLFJFJRKZL2CarWwE+5to7Tr9KU9AE4H71zqOhAL8pNw0NmZsba/mGioi8n5+1sAw4qO/jKBkPqIV+wOseyIts/sFqZoq4KDLJ
# DATA OZ3wvOE4DVFxNejNWIvzSGmOsio9HV01+TPGPmYPujwVM01mGNgJITNOxpJglqK6KlXaayL2YEJGZGe6PmL3eL3BS2HxH+roqYsy
# DATA k2YL3AtRlTiPkJMHE1bNTg5GNGWjn+Ih5NB1ZV0am3sy2VuMzUsoUuy4yc6KP6sVP1/lnJ/Z+ZnPbcCvnC5cnp/Z8MTneRwGq3Yt
# DATA MV9XwV/WK7/0w/2nY9m3w6vgZMpEySzVvtYTeMZZMKbfsy4ZgG/zJACzvzHQ2Bj9H3A3iIjlAcb6hoyxbKYJ81xhtcqO35TjfjWD
# DATA WK3DyzSPP66+F6XOZhv77dcwihdTxmvpJnX4xogJZZhvvxW/fiJi2gomnwf6ooln7aRiCU7BmeZVfwX9o6jKBewJofZKmbA+0uZx
# DATA Czutr2S86ZOiW900tryRI+vAhtQxUN8xF0fszrFR49NunjMu303s7nopWUx6mcaO6gZM6vsalcwdxCTiNQvtmX5+AdVmrUA64EE4
# DATA G9F8CAsC6TTPqDbp7wJOw2YXrxFYlCH07BOQmYGQll6m5N3F5f2Y7B17kYwtoehpR61meLIeoY469BQ1Exs8QgHYHKbYsMazDp6x
# DATA iRHFaxXKUJqEsaI3gSUdjqWnnivPzIGiesdsE0kuYy33iEHyLHKRs2KXPJrDMS3hMPEK2zyIiZlW3SQSfJSa+XngRB2gklFmMDK0
# DATA M1V4HzMKnczJftFmTRYwe5bGHXh54sRCZh/99+Ovjv54/I+gWh/9+fi3R98ffX38Ow/sbPrhX46+Pf7dIj37vx79cPQXuu/vj74/
# DATA /h3dffRHevhf6d4vj39b8OjTD/TkH45+OP4NKNoIWkjaX9Lf3x59yxztL+iRf6ZbQNL+k0d3gdf9Wwr2Wwr2azx99HuK1p/4SQri
# DATA 9/T398ByH3/h6NrXf0JInVgyjIogywkiS3OnuK/qUDMFCG/Ay8C8Wv5AjRChtmkLggRj5xSZceNBpHhhinZFvd9EQ+2ZDZYZrWsp
# DATA 2g/xEPVBkUNn5+Z7Wfdw1fBsq0Quj5italVqzfT4AlfMdP7udhRm3fXr9IUrYzuisf4iUdkULrOrYz2Sqa0VC5O6l5SVvUGhXTgp
# DATA +14/gU59CIg5jakjbb9SBrPbSREluTehclvYAy4+X7JYqJPajwa3Edc+b5Mi+y61vVRhKr2h3pxymvq32oLJWtOzYl+fGHmHvXbD
# DATA +jmHdY23Pt1o/nJ4bq9wJL/IgXyjcfxUw/iVjOJSE03Ss92+z7SpXAag2qRRtoeuSh533srjw+VckJ2UlIY9lsoIp31JQw8bIfuy
# DATA ZCurzzQ9D4VMO+kfTvvDrMCsvZChzg2FLMZQvAmR+v3EM9EV8K5mLnNsRoknrWY5nLfk3eUfWaA7FTIxKzrLEpbqVRFQOk3GZG31
# DATA FQV3GraRYXLATqyHLFUGkE351YlT0afQWdqBM8LxpR1f2vGlL5EvvdGQstF8ZUPD92ps97OY7hdguTuQtANJO5C0A0k7kLQDSTuQ
# DATA tANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0lfG5B0rVINg+CMIOletVfuBc8RSNqs
# DATA OG9Ej7bzAy7WIOjXy5X9arX8Nn3/1Xw+RkFrCd6q6fnNWj+o1febwFs18491/G6j688/NvRrgVehR6vlot/wKlX64FWbxVrNq9L/
# DATA 6bdGsenVqh7gWX6x2uRrFdweeNWWV/VxNy6XvZZXaxYrvv1W3gmZZ1tVu0FYLy9jWy2pGwHi09j3K/OAtna97bc7y0KpLcD4bEpa
# DATA NY8MlnAtgFc9q77VPMk8CoNGeyGGlUr9/DGs+NUshkH1gmPYal1ADJv1LIaN+sXGsNqonD+GVW4Sl1TKNWok545hrVq5vFIO/Ob5
# DATA YxiUg8sr5aDlX0AMG80LLuXTgPRkENIgPRnPLJBeqxb41VYepDePzeMr4TxIr9dtRUEG0quHQdRoGpBep9Hu0hzdgPRaZB1Xm5cO
# DATA 0uPtn8V11n2pOsen+9x6aJFFl3MJ+c38rEdnAttYcNlS3mPT43ax0o32dnIhzxH63opoXI/DgsR93vldZde3LHkznG9+/V6FzJO1
# DATA TdfUStp8Z39u1Uo6gvH0xqOc5W4cCzhioH3h2BhWPOUSUG2ZA5r9cFZ4ygu2iOdTtSlfGigMyyvRwPLK8u1QC68oIdZks1qzfDJR
# DATA dWOwS5is4qDTWg3dy0q4YJfJmlnEYm1TybWqkXJ2ry8cngqg1q+cRmUFdbr5qIMAOgiggwA6CKCDADoIoIMAOgiggwA6CKCDADoI
# DATA 4EsGAURdUBPFXbZOCyEOfRYg4TspsAxb+bbkB58O25XaEnf/l138WERtuc2BiHjErhre1FeK2y/LhUqhVqhTHxn35ntIddvOjn7c
# DATA 3H2bX2cq4vaoEIP/NtLd3q56wur1dm6P1uYSAHJ6xMrip94jo+TT3TtP9RukJ6Mrys59qroz+g/0OnuOMcbRse2dz3I5eZsPAWtb
# DATA kTN0Zy5Vo907lCA+fgljlOftaH58Dg5JKMnJT4X5o6C5V1IQvB025/LT0A+31Hk/dBRZrdylUZclZOWUMdVHYeA9lEPHSMKYOljG
# DATA 3JmETdniBXLvR+rtO2L5Ly+bE1IyTfb2BrmUFGJq56hFkiQO9Jf4/pEpAgVUTHa5VmrbP+1A5xHJ3Sns5X56iyYRVLETGrIiyphR
# DATA 51AKjV9Dbyu/5jfLt6rV8u290h7dC2PxF7jhLhv12zi1UFAByjZ0XN7Rd0dPx8kIgm3h4GE4HD9O8s+W/cVnb5TKdUSIEjKiItre
# DATA Q2D6i9wNJb14xCubuJM9UNvyKRlvLwuxQcUkBfhAMpMFEwF33MaHGz4zG5Oe1+Qi5cTrX37SvM11cdeayKCkC9UyVuAEAAk3SsJ1
# DATA 7XM1J2FlfI1g1NXhs6zu31ZV43PdBngKPMV2Iy7Cu/d2D+IRTaxKfKqc6+XT6a9/rS4eRO0n8dT+SXqLezvTPo3T3v3JhGu3HEm3
# DATA xmmkj7NI6sGvf4354N17FKHwIIxp9sfZh356iHFySWU+ZStKxlYjkv5RGsrtz3m2b+eJlJHEOW9eLB5fF9EjUeCB9KGc4m5HXkTT
# DATA NN02qd8xU9klXR2fj4sHNK3LdXooMvOYDHk7ViwpUFUKS4LEGj89YoKynuOsfU1avQQjPjVzqNZp2Tgtm2VaNvmD1k7UxonabCpq
# DATA s1KA/LLEbu5j3YVHV6hNjCJbtkUL3zw7AbWrUBkXU4AuP8YHbxvFkd4cxqPZNDpJx1o/azonc8FILivV8HlJaNkbojShK+skrPUx
# DATA X4o2H9eFYvwhuizO74SFM6h0eAGtLytNXJwUgNyfzxiznmTlhPmRzVJespa84SlQme/MZ4T24GRZYW7Nks4P+nPq1uvf5W/+Lj+f
# DATA zXiwcqp3VTZ/VyX3Ln6weqp3VTd/VzX3Ln6wdqp31TZ/V21Bav1OcKp3BZu/K8i9ix+sn+pd9c3fVc+9ix9snOpdjc3f1VjQf7/T
# DATA NO/S+iqmDa9UV7enry+AmLoeKgTpopWIrNGG+r4nglbC0RmaykkHJiMkZg/AJvMkfQippUmuy5MQ/IJXLXgBD0cNULSiEQupethB
# DATA wEELUHhoSGBWxGigWu4/9dC/MszAkv0y3vZMVYqGKcwbtCIYBkGEKVbj6fXANpAyf/7FhBy01U2d1k+d3EzpxZwpnRbE+sxlQXlz
# DATA V7bP6zIQnpb85gVzO23x0qWwzpU4WdYQ5JOHpqUKFwUy42uwstdAHPU5EQvcUN7cy3YOauNKvJZ6viwndih3aDINFU2oJBlD665S
# DATA aA0nLHIFxygZQ3iazCqyr5h/ymsvItY6lmk8b+2CDiPm6byrqYAHVEFlyo08oadCigf0jn3sRBQq0B7YZCw/SS9nRg50+bQY+ulz
# DATA EWYfa0bOacdepWT6s7GUctXSGUvOWFpmLOW6KudmfundzCuNrGevqa5rPlXnkGWlD+EBGNF9vBkp01gfT9A0IQM818j2ZjQ/Zlfz
# DATA JFIa2Avy3tRcjAK4pQyeqCk+16E5x3LOalgUUTf30biqmzGPSFS6Rl8Zw2bS63nhfhJ3efVzlMQpu8QnWlNbuoMMPJ4lTCu6lbxH
# DATA NER7PQpNRNRTXieVo8QYfAcSl5T3LyKQQ6MFTj3LrJ1So59NxXBjGTkwv7uaCIcYl7z3lM62N4w7k2TcZweMwsdFYYfd8niecgC6
# DATA 1ei+lnviM3dPyLbGSKnB60x5FE3FjEgz6edBgo0sU9B8ZQPeOGSoodXtaYBeybuLzKSg4/FYgbcRBLvkbntY2MZVRm+Hcpdd5h7O
# DATA SKAvHiF3NPpd0s2p8g7obbwyviZ574ewa4RbvJcY1XlcZXOLSgJmsRSwxs5TqUslnybDZDJJDpS+t1R/XiXXRcNV35NMHGFfZzLr
# DATA QAOGMejiu8oO8WZpE4a7gaZTUWHgU5Tldel5k+X52TOGBZ4FQM6ALDqegkSwFsUCVYrwCQapKQ9hfTIZbMOS2iQmDWzqpWIa0u09
# DATA nFBHUzDjoFQH4BAFE4AXPYkYPo+aR9k4lEJi8jRZlnuoygOQ6CkysxEGZqwpJeN0PpFiT51ECnpd6jmvXCE+kqOSC7N5jzCizYNN
# DATA biOt1esWteMYw9xKr/I6J3J+ocSUwprMy/zK/MpzvtaX19Iv0qxM47vY1/ByiTSajIUlzAJuRBf7Nl4wecglayrrFJ2O1QmjpVzs
# DATA W3npBPu+VzfM/Atvzgbn9MW/uLOfDHFJb+smySS1+Zb/dPTD8d8CSHn8j8yd/JIJl18c/+7o/wVR8ujbo28WAZf/xARL4Cm/8I6+
# DATA wz8Ms/zu6Nvjv/UYffnF8d/Tn6+EcKkCphcx1vJ7Cvybo79oeiWDMem270C5/Ob4H+i3PzmE5fWftz2SmdYkgZHEpjAWjZLZXn/K
# DATA jByRmVbD6yCeQl1DThGbidhspG0XMqUw6oUMb5UBny2YVGZuwKDALAz5DOpafuUj3nFBfWE88D4hi5GNKEeyzOZwuhe4aozl0oK5
# DATA PKAl18vUmj/qairIo/zNqKzm1geq5mJ4u0iaJRmrLKSg1jBlrwk1ibEjWW5QWhcOsryrtlYNqHkcFg/CwZOM1ERmNXg7wP+oZMHW
# DATA 7YQ4bkSj7ATybAqvE3YxQhho1CiKyMjHAjzVy0OeGygKEs7PjxdIlifUvNVmybLm9KyIlickwvEs3Rh/njFewyzPOrS/FK7ZKxvW
# DATA L2dU32hQP82YfgVDutTLJTlgBvRn2H4ug3C5JKkezUPpE7PnQrVMKslFLAu8zhki2+MOxlmkmJO7LMq88Vk9PEkEFCh9Uxvr5hzf
# DATA kOM2yqH2NoFb5hzdiJJKhtH+ZHc3tvp5BzTHxhqwKB+kQgX0fp5mJpSM/GS5YZd3j2IWwxAQNGE84rUlQ7uEtRPLC5RnGIXGC1l3
# DATA LTSk8q12IxojhzGZDQf9iGMRemya8Aa7XuRol4526WiXl0i73GSI2WhKs5FNfNXm/Vms+3Mb9w556ZCXDnnpkJcOeemQlw556ZCX
# DATA DnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJfXBnlZqdXCoH5W5GUzarV7zxHycsnK82nh
# DATA l7WKV6vXPco3z6+WB3458PxG+d1ao+k1moNKs+JVm3NcS7q3vYjDHPqtqlehjA78YpP+bnmterEWFH2/WKHwg1+9V/Mp7GYwqFeL
# DATA frnhNRueX2kUA7qlVqzS61vFSlCsNubKJIga7e4iH7BK0W586gflYlD2Kk3fK09r1aZX3m80365V82HUO81uo7IYRrPmBbXyp8VK
# DATA uVFsUqQqtaJPeUExChDTYrNxAlnTRG6Bo+c35XWdeILZUoeLv86R8DpctL7U3ImACnPx7QbNWq12Bloe119Ny5OmYNHy2vUgqvob
# DATA 0PLq3ShHy4sa3aDVzmh5Qa8O29rQ8qrtWrOS0fKajZrvR5dOy+NqX1xvGLB3f843TUWFs5efWwFo2yDHTpNEL+LcVL4u+v/wh1r4
# DATA 7ZPWEJYbO6vgb1YsT6bw2ZA9efB0kL3aImQvC+YUkD3tgFyZR3ZOqwxVGDtV/2yPUYXtNDYGzCC2YhuBHrvVAld5Nfsuy9eCnVVr
# DATA zIkTcsIQ7Rx8zsHnHHzOweccfM7B5xx8zsHnHHzOweccfM7B514i+BynDacRitrmoTS+tm5AYwSR5BDLDS3tTz1DH0NvMNi9sz1Y
# DATA 4DupFO/ojuw1CubpRzKt+aWHDzs3BvlKxjV/p/RJEo8ogA/pP/Chbhvz8sMtfew8i0tp+hT5+uHWGwsn0lUAN/BZk6LumR0KOlQN
# DATA ftJsJacQ7g5WrzlY7Q5UvyQHqk+rF/5sD1qzXzJzpS3iiAY5Lcy9JOnibLHHfkJzzJZJEghkjc72sz6f/TycUeS/L1irfdlB8otW
# DATA bV9+Ln+pfvsGx+QzP63RD49EoA6lrWUnVeUwGjOPI4pCmgwjCMHw0VqpanwCXrnfmMgiuoH58+XZyfECZJDJ1swaO88ZoWcKD3DS
# DATA 68ExrQ80i+4hApeqxq+YP3x+GhHxhWoiB3LDzDp5NmI1z+I0q3neGVTOoFqiRpdVKCdY4wRrzmpHrbTXLkfIhvt03QzIkhLtCtbA
# DATA 6CfTZG8SjvuWqPgz0027AIAljctvKBkaa/Q6pWaxGAMI5AIFi9XYrwfzYTjmzLHG/GXKtxeiWvwBy3tL30i1EQop6PkuQbj4Tdjq
# DATA /KKRFz2lfPTS0YXLB7No8TujdDYIp6JefqiSd4CEjqkT73nU3w0GlyFbPGNNpanmzsxYA3yuNVzsewNRnobEd9cTEXo9ztHwd7Hv
# DATA Yvrjg2iSshQTVqqYby+yMMw2KoYxGfCzMTXI6ILVqBtZJzpnQVNxhuDBCgNEDO4LloieY01m0zIJMu+YpIe0VpA3PDTmh/Q2BkeZ
# DATA ASBtRXWzHJQpymNyYNcf1YQOM/UpGdDkxFG6QlqqA8Ci1pWydKmgCsTiUt4jCHxHI4/BK6MOFZSWn+op6gHlfcEoZCWqd9aSplh4
# DATA OtRaSTwjmszabYjkc7kwkxjVJBkwvljGAdE4mswg5OXpTDM6Xsq9GckLzGJ3qHRTN0M9vjjTD8ugcBMQNwFZmIDkLUw3BXFTkPwU
# DATA ZOXE4llraSpeBzMt+uGYYcMhZhi2OHYaKd09LQU5JxbJqB2tDqnQR5FMZiydx6ktAImxcnAAftJMcCHzEo/SYmfUlKnvolLYj5Yo
# DATA PW6qtsmpHd95k5c2s3i3D7PZEXOX27N40DVafCoy7GhcdBurw6MWgF6jt2W1n4FV+KQsLGUB6R8zeLa5wioCfWbFcM8mi7Oye4WG
# DATA bispeQi4eq/ZQgCrVH1+VTZGqJdbd5ie1X7q1YR72Mzwwxo8xlhqNuo+ti0T5cidv50mqOoww1v8afWdnUE8bHNE8WH1fdQxJ9iU
# DATA RXfel4/ZvTclbXfmMOXa1pTVeNvUxIiyxtDMlS42A0uzV2ekM8s5nHTN9JQ3P8hEVeVjPh/mwFy8k9p0B7KzQCa2M7695j0ZmmTM
# DATA x9tkKpQjq3cexsxq6kYME6LWWhUvwTBJp4NDBb/ET7ASjRQ7r9UIryseTWUIjEQOE7sk036i9ERDgZ5r8VgGio+M1Cy1XJ4Wa/e2
# DATA ksL0YJkp61Ad1LraDKyfIgM/oDnxgH338aRD08UsCzFHpY4BKC67o1OzHHhKqFv4RG3RoZ7sHq8SsG3Meythtg+TNh6h3i+SOk1F
# DATA 8SSVRTNFAeOyuIjsslrJKfOrtTa/TJOTDPsZJD+pXexFJqvgTeB78nlkEFySkSXvAxozCx6r5MVkhB0q/5OCiFF3LpQ42a0i7jDN
# DATA madhgzFuUfcissp0PKfMqMbajFK9mGTT2/DjiDkfj6xaxa+mCnFAsUzZERNOBmr1VPtm4ETANrgQWrWy0sXTbPwM79/eYeYvjLAE
# DATA iD35Qs4FcIz7PG6HkNRldAXf9EzbZHCKNvkuQHTo06jdFSnRRYFcmdpmX6bmJtQ6lZHWylsUpodY3NNEOHqEbH6RHub8FFskBcbL
# DATA mpE/ywrmVzavYe8mVMQ0Rg6iQ3YTZHVsQL9kFo7y7orDj2a31ATZE5cZa8gQ6uHZYaUXUdWiqFhbUAfGiZxE1VGyVsQFBRrhJO4s
# DATA zbf8QCx76+yB2FyRbLjzfqJ3wWnlaTbB1O40OEVUSSpKtM7v0kkMsRfFAZGxxMbRFGheGyX2PwQk5h398ehrj7FeoH/95fg/H319
# DATA 9JejbxcxYv/30TdH3xWP/gwA2PFvACD7V+DCjr+k6/9y9D39/Xv6+4ejPxz94B1/JaEj6G8BHfv66M/Hvz367vgr+vd3eBNYZPRm
# DATA CuNrCuFrDSb7y9HXjib2HFCgR7Lyg308HaVSn1Ggx1EyZn4jA9Z5aKe2JwZiN4HyOXsbMdBYLmklhst3oY/OhNX5DdSDxCIhz87j
# DATA tVSxt2AuMbt9dOhwYrYPRXUEV00TyxfI5WLE4pG1hntf11L9yyJLbDTFIUDTx+KrjHTR5CJ5YuFUEAX9MKXhFBYsWbpJr+dwYpuW
# DATA 2oUzxe6Fgw5WHSNZADvMANXhkHfa8xLIgNdJvB6mEh5z4Vjuz6xygKQ7HEY8+cVYwuuI8a8ipm943TiaLsGInVjpVlsnubb07Bhi
# DATA J6bAccTc6H4Ro7vmiZ16UH8pFkWuakC/4PF848WQU43mVzSYS4208yDbbvXsm85loMTstIpjWO3g6Cf0HBYf8glFCkwsdWFhkWhN
# DATA 0t8Bg30wToWqxEmbhukTtVcFEYhHODmGY3wqSzZDiQFgJEP1PnhdCtbUzchOUm1kWO9omwDwqQQb7WATYG0rJgNhiV0wg+5CPF1m
# DATA DyhrgMFHsAOwepU+ocBMPGI4x7k2Uf0aYJc29pDNppNYyiwZdaLJKHUcMccRcxyxS+aIbTTSbHgCY0Pj+MqM/LP5Hi/AxHc0MUcT
# DATA czQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxO7PjSxTlBZJF1t
# DATA ShPr9WpR8zmiidnLzqfFiPlB1au2Gp8Wq+WiT/nTqBb9oD4o1oDV8j/1/Wox8PxaxfPLFa9RKTY83IU7/CYwYPms6/ZarUZvgTAG
# DATA wFet3PIq9I5aw6u1ii26UPGadQQZeAEwXp6PsFt4XbWVDzaoN7vN3hIwV7VsgbkqrcCAufxyvj60a41atCSAoGYFULXIXs3FKlFb
# DATA RgarNE77vJUv1WrDq1I+VAKvWaS/fH9YqfmURx4yt8xZvDohdinSnbUg6AeN5hzpzDywQDqrn4FTxi3DcMq4kVmcMqpHjUa4Aacs
# DATA 7FVznLJepdvo1C1OWavea2Scsm6zU2vXMk5ZpVmv1huXzikbR9MTKWUYX/R9G2C+LEdZld1kpSYvj2FI21kkgZmQNeYsN9OtBT/x
# DATA AvpTCdjpmENzSY5KCCrCmznVVKqMY61iprtzb6/U2BfIbrw520Y8T2sQXjpdhVz81gzhudu0C8whuxyyyyG7HLLLIbscssshuxyy
# DATA yyG7HLLLIbscsuslQ3Ypi8PicHXDw3T3vXDaL/UGCU1sYPZ9uIXDWJT6n8Kkuamu8fkoXJSvNM2CoUqthq3PD7fujmmC9xQuymhw
# DATA SLlxA0HfoFzpzUQujI+H9SydK3XWileRQMoCUksf5grV4SxokCFIOXYT8iFtHFAxZ7BE789Rttyx49MeO3bHjV/U48ZnwWtdg2PI
# DATA 7L7T/q71lC0RsDLxXnpUeQlf67ocXn6uzvBdBnArf9z6gklbc5XhrIgty5GaHSJXOZ1hQSDPKALySnWFs6tfvfMmT/BZV07r0HH1
# DATA gVDoSOnNyUFYU30OQnqinRzgtHO0NxtAvk/Lzg0hJ5r0oIbfnU24goaToZa+V2fi+d06AnfJto7J+OVtszoKmhJG2dPDImmbtTin
# DATA 8BN5vDlFLBMstQ44bdCz47aAE5XtCC/ukk02m7SN8ORLctTTCsPZVc6uWiPWZlcup+vidF1Oa1CtwW1djt7L34ySA3T/ojjQDvdE
# DATA Yw2SG2pg869eTuwC6Fq8AqF2gOhrOW14nujT1Z+PoLcQKRkW4xbztp/s7cyRgEa8DpSBdlQQppvS33M4JEo0dcnQkxnGLG9bLqHP
# DATA pp5FtuSIcYS9nNmPK+TsxQ8BoI8t2DLGFlca7LdPjK9+PutX9YUMwtUsL4uzHWNs17GjvCbC7ClhShPc1ZmODTLqhLiqR01U9fcc
# DATA LmxtPP01sZwjKKn1JbRW5XQRNXKu6hYlCZXqzquy11TFU60x2lq+2SXpXeJ9SQGNv4rZelOCOB8FymI2We3bFj5S+vQK8RKi2Rt9
# DATA wPtwPdkNmBs0a6VET2NRceHhDj2OdkF9OqNeCFrl6WxvL2IPNIARvDKhOohkAowFoEqsKo1RmAMdAVAx0DQuYaCxb1y1OwiokCk/
# DATA Y388FQ30YKAQHO4ZRiwUqGCcpjKSd+MeS6dMRX+IlZ09tZU3MvEROXpIE3E0lqgTZZJELKsMTyMi44VjqnMY4DZlO70gxm5uBHPm
# DATA rjN3V5q7C6aNs3idxbvahL0mCof3WH0PmsU9DDLxiGXMlvOdNF82kwKcRMOYER2FVap7bwpTcGG4YWGzvVncBc4wGxgpNGqv3RkA
# DATA hDy8zZvAeWjCgsChuY/GdcM01b4nHup/zpwAjGeThIaOcKrHXLbDh9TAZzChlB0Q7k0ija9cHDKV/iGF1KWh2iQHrqqFgZOlASEu
# DATA w56jiDXhvHCKCk0Rvm1T2zUZMnrK26PwjhhQA8r1FTMCkXhL9nl/k2Jwan7uWDO8sJFTQCFPo0knxn7HHARVMpwLhkX7LKFC5SUr
# DATA eW+Bs8XdKHvTGNrVh83FdzHABMRKuOvejabcz3IyYNqE0zl/Gw6umch6fLgB7JN1abyr5ShNf68T+QFmbZq9o/p+qEwWRHNPg4nw
# DATA CNYfqaAHaYHpGKmhdmqjS8yk9xEYespDmGBqoyWPLBMektqwtKNu3AmlBBU+E1m5UNMtzFn0lMa8weG6VL7PR4qN+cX4Ep3Ou7zT
# DATA Ux0SmU0K8CSzwvhQFz9PHxUpJwb8RJmvIyjxKfFPi5HGScorVZa8R1H0hCkhcMsyzwN5ybeqaqEVK3N8GfafCjcEaotwEGtHcZjy
# DATA pDbcGyVpnC6QOdgQO0nn+3FCHRPnZ9YFcas5NSmafdp6DLoQTrTl5laNAe5tdmJfAhn6PVRfvQ+GmmuIqiv673qacgmU6Hs5Zzna
# DATA LJW30GUvgRT9bjzlWdmEui0IQQoUUjFruOcUgclLgEU/GMg70UFyarPGxdOs7iWAou9SB6RbPHqprtHX5SKFt2jSvWB28os+f7O4
# DATA OPTUNLWxOP8NEJyj74++Pv7N0ffH/3j0jXf8BRA19PUbuvzt8e8WyTj/xKibf2aoTf7uoz8xJcejn748+v3RN8f/oEL5L+Di0LUf
# DATA jv8WT9Crfke//IVe+Cfv+O9ypB0LpuPQOM8BWZjBbEa7VhhZ8PwC6VGQbajCBe5xt3UAKPeBsqj2IlYMfgKHs+CEp5qVyJBRHkTB
# DATA ENwbrCfgvBuFPX6Lw9/k5pjc3q+afmMVxuWhbyRpWbfIdafH87D5WzFymBt5qjfpH077w4vE3fAmW5r29FHjuzwjAHKPt2Lidoe9
# DATA ObHELpx3g0lu0sYck+uZ9lhjp4iaDnP/MggnQ7U0lU0+41Rc0Qt7qEU/nW1bmUtQaVEvhmkdmS5wcC/gb9bXv9XGR9aOnhX2Zn3M
# DATA HfHGDdqnGLQ12OZ0Y/XL4Qu+mnH6IofpjUbpzQfpyx+jpfqZRJsB+erawmWQakx6hJCczidE77/INjGwPdFPhhoGY5WJzHRpQMNg
# DATA F3Y5oUxBN0SKVDGWO8lsImyKbHzVCZej7PQS5BUHvxm3Rk3xc2NwaJzrevQ243ZKN3Zng0hvieQlLHgVvXQcdeIoLZj4Z+xi5Wgd
# DATA xOJ6jaizDXvR9DDnClTpYJwuY6IZBdyRROUT5AA1DlDjADUXD6g5eeDYaM6xif16Nfb3Wczv81rfDkbjYDQORuNgNA5G42A0Dkbj
# DATA YDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNNcHRlOtRdXuWWE0fi94rmA0Zrn5tCSa
# DATA aqXpVWvlPuNnKjXPr1XfrgaVfHZ0es1ysMg/qVECqrXGL/xKdZ5/Ugs6teYy/gmXUj6YaqvlVWqV/+C3Kl6lUqY/Da/lf+oHTa/p
# DATA +Y2K5wc+vavqVVrVTyt+vehXqQxBzKkV/TrdUqRvdFONbvLpgdp/qLTo0YpXpRCqzU99eJFrXo3uqdZz6apFzVa9vAiIkQgVyYQv
# DATA +n5z6NcoX/Ciehl4nrm0dlrdVthZllaFnqFSjMn8UOyaWjnI2DW1VtmqwDX5crikNnc7Ub3TOwM7hiuyYcdwm7DYMbVKIwyqJ7Jj
# DATA 2r1ur55jx1B8mp22xY6p1lsckLBjqJNohZHFjgmCdrV26eyYAbWCE+ExcBp9nt1qKC8Wx0WlbtGxx869Cv3b/IltbjfYfMiCPBlJ
# DATA Y/NmeLOd7C1eFgvjuiotWT8lC8vDUqVXlz+50Dxl0RigDI+ipvfPkWukiOdSTGHCMvIC+WNco5LsJowr25/jW2s8KogGZZhPf9S/
# DATA 2sJk65UHxJW0mg3KMp91+Tn20oxYGZCD2jiojYPaOKiNg9o4qI2D2jiojYPaOKiNg9o4qM1LBrXRBqGW9tnaeW3daMbwG93r86kL
# DATA 9VgBfeDSrtVTKbMq1e6dWPdeu2wS79xGO/9w616m5oXDKpacy4hyWGm6YPqaZ9aYkw/u3LA7N2ydfHGnh93p4ZNOD6/UmryUU8Wv
# DATA o+ZCaS4L3Jwsfqb6Exeglw6tObz5IIqe8AlHabNn1JrLxpaLU5uLooFS5W7LKglliFYfVI7uS5Cd0+eNFbhtTKXanUB7zqM5UjQ4
# DATA vATNuXdGONQ8lR42VUrZsJd7mUD1JYjPPWbXl0ojmSCqN6c6QWNHEerX3UvQnXsoR4nhAyRTTiXZwAUupVxZe+59nLUOjQAdWp6M
# DATA cDBZyLzEXqjZJLpg9TnlgTHS8ZkmY04ZIDvcqhNiTs1ShqELmOZ6EEuiPhOFFwl4SKjOHdbn3qiUqWt2J4c6ozNUQzg4ALdwGLGE
# DATA PG7BQhUZGoNByXs37pnmUADuYbDYFpWK6ghRmXh9+nESYcFqcChPcvdyEKYSHU0UUmq1XAdF5R2NDd5c0a6mSQWW2PdVANQ6KJpS
# DATA X/rwDU7UiXjoZNKjPRpSVkkG6FzRx/2pmxzh5DtvM6DxhKUAaKSel/iZG6keRjgOqE5xy6RV7pBx52TZ+Of85LFDTjr7PbPfncX+
# DATA wlnsp0VKPkMdIF7MNwvR6zmSb8Ysf67gKBA9H3m8l3cNRPKK5YOuvZzGZfAhM5Gji4ZD2nJQZyVDWpsU9LTpIY5VmeogEz8WTlHC
# DATA U5W5gsSuBilFtbsRxMbXJ/IwaADYQqehjXe9wWwYj5IZTRGNTTSiSp5AxGYcDQaQdscY2leK62R/jUrez9oit0+GCTZdQ0upTyap
# DATA whwwz0a/3Y7GWzDQ+C5OjI7F+7CLKAiKHVVeqjWW2cUmH58fiXgbwmEKLfUwZQl1aSFa43kICevJuvezG9rLvfstaUEpmZcpL0WX
# DATA vPeSdKrtPxEXYvaPjvVtZJC0L7CXoHxD/TVsAwjbUzdCVZ1lQ+Zj8qKLxFg9g7PVnK1mjwzO2fryOltXMyefpYTje7xYqeuzEmDj
# DATA o9cWlBLSegxH2Id2m7SfzHlTYDcCAybZiaYdhyXvQSYGiFM4otJm0D5chuw0CC39QPZpsu+gF3e8lKb7HeNZafNWskwzUDQXN9SA
# DATA 5BSL4yNr/LLWh5iMwslE84T4cAneA6/PEiNRnXFcpF2qdW5UUv6k/GTKk6V/zICI5grnOLAjEYcjTyv3UzIYWClYSoA0i+dcTeTz
# DATA q7IlQL3cusN0lPZTrybcYWbuO6w+Y8QcDPTSaAx/aKKsufnbyW7gVpUcrL5nj80eRmbxp9V3ttlOY43siVgp+s6bkqosH2Q81t5C
# DATA WYG2/XwYGta4CtfajJbnM5x0jROeF/zFHa9y0MqBOZAU7ww2rV+W0rkKTWacE3dNAuZjLHk5ZoPtHkQc4wmETFHvM7MV9lpRaXIW
# DATA RGK0iJmZ1iClYWyYdCP2409hz8Lw0xacoJRsZyIckEaqM2KhIW1kT71f0YBbsv2rG/pSPbNNji2NfFJM1mgJMwBesdzNjYiesZyu
# DATA 87bsqYonq3ynLKFHq0tIV2MppEdj9sHmS4iaMXck4nEH9gVamX2yf8QNGnpS15XVb7EDzRoInpdVEJFaTaA+iikHShc7GJWVcv6y
# DATA sVNw/QvmwaYF8yCcDFhUNhwMdcE8SnoMYx3RqMaaqQeY5NEIupefm5W8u/tJjJkx5b1x6xds1zeXypj6F0zOumqWiOnhucvDjviV
# DATA lUfW956yPP796vLQvbiUx78ng2WhI5t1OrMBq8liEVCdJFSNQ09WFUuPeileScB5bBoySt7b1LoOC1SEZIYk8UBUjofciyXDocg/
# DATA k3ExFJYY/RQjB8168fkLKkvR9S+mh5sW08NZuz3fn73OItaqN4tGnySHWQ+mxbhK3gcxTXe7M+ro92Qpysgn61WhzMIDU5vyqhPO
# DATA hI537rKwo339O7E3N+3EXo8nXd4xMIIDiBrHyGo8fVG87s+GcbeIhUKWGFflwaNOyoY9pIWmsMw/CDWXOlvnt3l7KGHT21FIZDyp
# DATA bRPQQoZ76NzltJigM5VW3v6TbYy2/WeuSN7feT/RGw61BreY/GJx89I/Qy1DmrEgO3Qpq4XTy2GiPdcer4yFlvaTKIdC+z+P/vn4
# DATA q6PfH/8WrDJgzOjzl0ffHP3L0ff09+8Zj/Ynj2Fn3x79+fi3i2C0/8YYta+P/kzP/sGjvzjAo28LFOLRH+kbo8/ofz8cfWNeYpPU
# DATA 6Ka/HH2DT4qj9i+gouH98t4fjv71+B8dFe05gHKbbQ685TWZHmjsqiFzQ7xYyKsFnhnxNqsIJp5mAQAaCncCy8hQByBwBnSgY9AN
# DATA FNGV6vFkynvG8FxPlrCMUwCejrXkNCjLoymIne/wabavj7uIq6anzRfI5SHUaLQIB8lehvjiHYb88nkO981enHXTb8ZTC99xcQw1
# DATA mNLq3AZqaCIjOGeDw6edXFoXzk97TzDgXpuMC+zoonl/n8YdM70saCMrTXAYChkJQxbJRHen9rRifqNI40+hkhJlnRPrfBXIppLl
# DATA yEnEnkUmzOpjAkMqIsFrYLCaLrDV1tfL1UbMXCt7VoC19dF3gDU3/l/w+K8hbGcY9l+K5b2rGfIvfMTfaMA/xXh/+cO9VMR80s0o
# DATA f72az2Vw2/IJ50GSM8RAx0yq24cIqSBnGCczeZXEdSpAp3QYYuHLLL150i+1oxQurWiCpUlONA3U2bEFFb1u3DNsN0r2oadIJhsy
# DATA 2ybKXONtNTiyQgYF+yWizhOMTQpNxnVMuFd8aph3AgltLk55D1U6FRoXL81G6VRMBeRLZjncVhQz0LOmMwphGI5mPXye2EaC8rzC
# DATA T8A2zeSwmIwcss0h2xyy7RKRbRuMLhtNdDYxia/Qrj+LWX9eq96B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHb
# DATA HLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjt2oDb/KDaqZbPCm4LevWo9xyB2/Jrzqelt5Gt6lVrzU/rQbFa95rVol+t
# DATA DOifSsVrBp5fpl+qnl+hT/VipTqot7yg7rXKXqXxabVGV71q4NUqb/t+69Nis1hteBW/GMxladTqVbrtOeiZ36jVq7Vl0LPWYslV
# DATA yl6tHPSDRmW/Wn+bvuZfYMLKU9gqlIJKPfAaftFvDou1hldreo1y0W/Ql5pXq3v1Jn3ZOGJ+dSFmgQ9IXOPTYpUKtYi8qL9HASC2
# DATA gypdyNHieCdn/mVRr1FfgblTFbgTT/iE3VOp9JUM/eY3GCTHqgb1fAswwVIAMGw8ebqMrPXk4WYzX+17Pf6u+1+WQ2Xx12qT6g2F
# DATA cUpsHDcjjY2TFmlh46KgWQuCPDaObqpV6jls3BxITrBxrW4rw8bVOvUgaGTYuG6n0+5l2LhWt9oqR5eOjUP7OxkbV9VGgZgE+pkV
# DATA /Dgkc86/GPzEq9GfKv2pBz+xg5jjxb0zpKnEtICtwIiv9z4rdtBXO+b2NCkol2/PO/PE3VNo7h8UeJVsxYqYigbgVePPNl0qKNWs
# DATA vPCqk3wwnt5PkTNIzHwJu6q1i097OfNMO5VJFfrjB9rkZ19RPCULq5MD2WkfNvXLlQX8XHk1X87kfsHOgTWmyAkJZCvBceQcR85x
# DATA 5BxHznHkHEfOceQcR85x5BxHznHkHEfuJePIKYsj3wHEIwp/F/beh1vS5ijhN+Q7FGE4G9jE/HDrcTiBCi0/4snNaF43+AJVizex
# DATA mW7b37lBudEZlj6k/0Z3rVPi93+eP4bHD78XTvslnqFvczg/9UsBQsiO9y05NJ4p30KKy3T7GjWXHVtxh6jdIepNDlHbR5vcWWp3
# DATA lnqNXvKzPWMtR4ML+qzvkpPWD825QKkjhbyymjnUKwdWlSALnyWGHX2gdJjlJG/EKvvZ4clxeIjJtByehNbKyDo5ubEG8puietwW
# DATA RlQXBCq8OjQdOjoCp3u8ie5xJ0xnoZJNw6fVd6JLpazFrR/Ix9X3UgfbTRLO6J/Jx+dBATnLi1OKIN5bLYKoc1VEEMkomxx2oUMU
# DATA jvbDNFNAxMlJal5QEO8k7DaZjcc494yNBjiM5k1EFjIFnkMOs7MXjJpaVPKoVcc4Ojyno8PjYXdyWPCiMD3khnJ+3cO5NFyZRKVV
# DATA /y5OMdTUZKVTDdthMoMZmZVNZ5b2qeZGLJKLM+hyhDoUuWo2czIjAlYl7BLBMKCg+uDeoYvIlKmVngMfD5+hfsBf2tbMk3OpU2cJ
# DATA eA4K5oONC+YhVfUi3CqH0AC3lEP5YHOBSmQccevhZqMbCINkUHDUH6HhaN1QnCOEYhUUw6Mx24bIcEtNQwQHsLYl41s86Cczlh49
# DATA v75rLilXVkpn7tze3bRzey/GzhloeMwmljIyTVBozoddgdNkrJtOL54MIU46G3uqYJIJS7Dxr6JeckCJmiRt6e4mEb6ybths1Cej
# DATA CuoGtozHeYokF/MrKxFrkDxlkTxeXSRmuJUyeTwJ44HopYRk1phCoe9TGCew3xLJ4S5Ne2DkoWoaGuYkVM1BaVYDJqyVZjIliUzs
# DATA TURYBoei9nbugslH//q3lUebtpUPZE5KE9R4TFXYFAxqNyxnmrrLFiEY1jyM83QUqh7jlMd7TPPBo8XGXIXMSkUzXImET1nUGqUL
# DATA z+m5i2Iuxi+v1vGLICeiH3feLefd2sS7ZVcx591y3q2NvVgrnWCX491i4S0DwAu9vSQRUTzt27q2+rXrfF840uDZHrAFp5bQTbFh
# DATA RO1D1tdy3ia1PMNophH23/NEVS2UbneGO8rtpRumTEpRihKqed50ZdkV4/qp8O7aCXpu9GLDmA2kCm+rHoa85VVv5I3GvPW65K92
# DATA kPEKEmp5osp1bFTL8n4ydaOJmX5wwTXlK0Iv7J7uLc/3OsPVfiy/FLADgQKLowndXQpy9y/4spSFZRyFsumGgriv5QvnelnLTEL5
# DATA URT4cJFOley+sk2X7JI08VjMszGNh1PZkH5TgjinASRGCgYjq73ZapaPJ+J+FWIs+oEFlegB6zWOtJe2IDMGtuHYKxLuhbHsusKW
# DATA eMFI0eyh5BnIXVZPSx4XWoEHPwvIwuKVWZDQq0y1dYzXwZoaxyPBWCFMsoiNBCEWFFlBDYfGIOnYPpTmKcJ8IRQo7VXEdLYHfi3v
# DATA FMjWMNW0daQlKFmvMpOdnLGFeuiZ7QJ6T9yYbRiNl0VWv/CGZzbUONPTmZ6bmJ7O1nxxbc2V1uE1VKvmEx3mdMGiGTawzNC3YHZy
# DATA rEAhn0SyTJhqKzR7iGWXuPO9furW11/ylf+Wczp3XqUedL5h6WOBCNcc4WrKCT/rzKJcCAf8bV6Ee/64njTTToLJgrzrcNQR89vo
# DATA X9352cJpP97BR4W4IG5uPcVfOC0bCItnx1a0PTYHBz8ID3n6Aj1nY5jd4yU7mRyNzKIg/Il7FNL4UJYXZe4EGuE43Oe5S8l7yMtZ
# DATA U21BqXuUfYZaCZexOOPY4Jlf6wqxHk5WmqZ1bFQJ5ivT/afjAUJN46fYui7LkFK9rxzuceXGU4Ypowq1Hw32ZtRd2LCyfzr+6vg3
# DATA jCUDQexb/vxnoMsYG/YHEMXwy/FXi5Sy/838+OXRd0ffAkX2r3zhD8dfHf0Zlwre0R+PvmYU2W/wHTfw647/nv4ARPZ7eh1AZt/S
# DATA z18zyuw7CuB7/Hb8BQXzHWBlx194FMbXdOHvcRFoNMcuey6sQ6SNp17wh7Bcua69t0AkDSdPsMoXjqIC3B40K53w3HEcyvQHgwzN
# DATA UHFUmteQoJfhzUYcGGuTz+IBs1GpRYe8m5MmluFUIKkRtupTZ7aWWiYw6UgGSgcts21Fq8O4anTZXKlcHrmsG8s5zNTc+Ya6whV1
# DATA gV6Gcc/cSZVOauLkguFlPM+PU96AgObAO8N0VB3BbLNSu3CKme5sejE/Fw7EqZR2+lF3JttEBsKOh+QHg5y5F/NY7dXzg+IwHsHW
# DATA DgdUubGP5Lb29DI6Q6ywSUQBC0ghHqELFjNQWUbSJgcG37xp1Vxt4uSb2rPCl62NvKOXOQvgwiwAzS07/cD/UjiIrnLQv+gxf6Mh
# DATA /5Qj/qUP+FIfc4m36WXXovlcBrcsl2Ivkjl6Kh4ppnB7SS+/b4+zYdqnWO7xugkaXYx9msYyYsTRMBxzwuW16KPk3ADVTlCXsNSi
# DATA kUmyX5NHXKn3nhFnSzfElnHOqUrhUXbM8DoZ8AEEEXfZgTYMqAhSxNLr4sAPXv5klBzI6Yiu2lwKbNQ44qLuJ7MJ2F/MoIrb8QBZ
# DATA BeuOQSs0HjFuCsaCaCAwnsucIVAgp1GyHD7lOGaOY+Y4ZpfIMdtwpNloyrOBfXx1Jv5ZLPxzGvgOZOZAZg5k5kBmDmTmQGYOZOZA
# DATA Zg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBm1wZkVmnWgkblrCCzXi/slZ8jkFluxfm0
# DATA HLM65Um51q/Xm/vVVu3t+jyCrBLVO73FnCz7lJW1ftBs8OcqIGPqc40ylj83m55POVytlYd+s1ykf9VnX3+eg3pRznd7lWVQr0pz
# DATA IQqVgKJQrnzqN8qe7wPB5lX88tSH27h5Ej6sEYSNztI3BfUFHJrfCMAl86qVYqvm+fUaIGh+QBnnV5n8Vmud8LpOtd5eTiuzIGpF
# DATA TAdCCPRLjfZaS0BmFJcMZEaRMiAzwbFlLaBW7TUqG+dvfcmrKuVG9qqq71/iq6pCZJNXVeqNS3xVULFT1Sxf4qvqjKLTqapecAae
# DATA CirHXZqGyknvaEHlapV6tdnNQ+XmEXJLoXKRHzW6QQaVC7r1qFk1ULlOvRN1LKhcld7brF86VE52FxZlmUEPc1WeQXh6dcrYLk0x
# DATA /+xn5qFwb0XUmcdhYZH+VltGf4P/s7F/UKiL/1OFPAw3g7yVGuvcmnp6lgU6v0Bim/e6fBY8m6pkcuGwuMUK19dft5vUgXXzTq/T
# DATA 2WEeu2uxVLUaDGdl1Rp7biHO+WnRJVqHjjHnGHOOMecYc44x5xhzjjHnGHOOMecYc44x5xhzLxljDnUhntIMfxJCi50q2G2Dndu9
# DATA 85mZk4zTXa4n0kvx+WVc/chq+dLwd++YZh/3tn/Ej6qGu/OZ4tJp5SKIocqZL0YcjbmrFuPy9ufy6u5M1p537YB+Krg7XMoQeMyl
# DATA kyUd+96iv/NTP7jhB4iODu2OBNCe0XwRhWpixnKzrEA7iqJuCt6dfgaQPJEhSI32Ui86kA5kLKfyROyLLvEJxlxykNE4xbirzfoJ
# DATA XixZJYtP2zyh2ynJ4sP2dljYL8RUCOENZWjv7/x0O6amUX6tXr7l7xTK2PTFrR7rT7vD3Tvbwzu7fq1Wfu3DrfepSvIRSw4VGaQM
# DATA H86n3iChOevwZr2885NKbYdmYF3Ws9quFD7cKuNufkw/M/wJ3bh40+2s5kiWowZspxxrVXXgPNrl+G0j9Ywa/Lcv/isyNr2NKzd2
# DATA lxXmdvxqvhBf84NbZZ2bHOrtz3dKnyTxiJ5lcKFEWn28seSVvXgUp30liuoHujBxWlYcLgJA/PkIKhOCA8DzDD3cnqswRV0rduxq
# DATA QY2H65HJlh2K5G0ucCqJop5V0POvrTMZueWh8WThfIZxkIwhdehYK2docQsdsmYr6kpn5l0UuD4PXZo+RT9jxVHCfqTD1A/RgIuw
# DATA DKZRH0RzShFOKWK9UoR1TNHpRTi9iFPrRazUKb0UHYkHs2nWAHjXltb0lJHdiEpcRxmjq9CxF2NFZNwnYsXMKdfjUqZbr+83nZe5
# DATA YITey61basFcCdev0KNXAy4r0k9xspx5SEbYe1uNvCcp6ZtgTJSyK5mSfq28TEq/akvpNyplW0vfD1ZL6VsGDaLPEaeJCc2quFrl
# DATA 5fRzN1v5ZgexoJbPMbtTLWv7Y7Wufo3jWQtOvrPOYdaXhLmgva8PMFK6+SDiHWUUCzMILYdulV9UzmRMKEwaOE35ctOOj/lMyJXT
# DATA e9l4xkOhTEDuWJfnCuRiXvsQ4ya3ePut2dXLeakcfPRooJ1QN5F7c/6nDO+ZlctKOoL0ZAoT8PwiEd6Ff0+kbpSxoi15WznDaMx0
# DATA aUJn2f25Tp7NIAh/5G5RArxUhVl7BpIzrKfBcAMWc9AMglUaNHnRGZsKtsj/Ws4JkwzMzR8wEuoVCvZt6SHIhoCdyDd4/sUt8haG
# DATA m5e4eckJ85Kc/emmJm5qcvKM45lK3GGMRwXXkUDmDDKVuzfNRESAB6z5ZNoalV6YssgVBKdYc8yIUBVEOW0YiuPSCKFpsYb5ycUc
# DATA egHbbGzst/BobQNM+JofiPBcJIRZuErRvikxVKFTM6VhRhdlT/rpDNHc499m6SGNuSNmelECpbMoKAiRTI/0QMtAeu4u0ic60HE/
# DATA mSZ7k3DMQ/U4giGt5H3jCUuPSRLzw940ZKzye8lElHXVWDcPNxVEsmX5SWrFHLFwaNyRoW87UBhkbBNUHZv47rE6dQAUOfTh7go/
# DATA TbAS/dDGi8JDDsIAS63Bt7cu9nGXrbq1kZ83HiUFBikgEOHUEISh4j81oOcOC8Ip/IXWJM6U9YRlm9feU8XSRpctfAKr1w6l/q5J
# DATA 013ssB8lILfOJ0vMhDw3dkFV0VRkMgsfwL2v3ox8JbOtD4KvQjZIFvAPAPYi8lhL7rBsG4yaAirRSJIC5h28t8ksVfmhAo4pH+7u
# DATA J3GXJalZpQ0ABclSGqASJsYOIbU25pNuvDtl+ZSeY/03QhNRDnCZlOk4Y0E9J1yd9GQWBh264TDpSuNG4fFlU1aePjyX9Hrwqeuy
# DATA 0xrWUoYFbzxrk4ViPcf6c9wIwy4sIG/CdVgqK41dDC/mV3ogsdOgQ5Z2Sm1yXRIfAQ2u4F5TDCJWEkEokxdSzxBD24u6O0rrmJ7v
# DATA zQaDQ8VbUTFlN07KFVXSPcyRCllZUPqEg36i1BGpg8ROUCriSR/tUAoMffw8olYM0xfPnna0MGdLb6wG7UznF9p0Pi0r7BmrQ9t7
# DATA /tfDwh5jJNCwSzaqpL6vp4VdHzXp50JS9SSCRLbvX7O8LhIqllfIvmim2Lzi+FKkmHK/sZo3CpV3oZERJDUiFbMmGdju0GisO7E7
# DATA 77N2iXDFaKrC+sQyaaL30e+45804s5zRe0AyewS7XGhkVG+ye2VmAptWdqcnsPBiSJEdqptuJoNVzVPsZdi5qL48tQiXORjXYkLg
# DATA ijUk5wX9cVhgLEM8nqBGp5FpZqLgHJrpqmyzIcN+iLvIzs15W8nmhmixrYXOljZPISWnZixKrg3chXW2BVvvRbPyMqzZQdRW4tc2
# DATA 1ex/Pfrm6J+Lx3979ANTxr49+v7oD0wXo0/H/+n4i6OvbcLY8Ve4sgg4+79w+ej39PA3jCj7xqMvX9PFb+ny9yCTHf3e43v+yIyz
# DATA f5D7jn+nQGZfg6RGL/iK/v2dAplxfL5GnI7/Dgw05p394egH+oHu/5Njmz0vtqw0cjQ8Lb7OS1aGvIl1IJrDibo4T94SCm6KVo84
# DATA Uiv/OVQWmSEv3qNkn7084STzKlkkRDSPtSizt+ej4XBmtk2bdRRXTTNbUjCXRzQTn0q68HJ1ff522UFg7n4YpTQCdWTA5kK6YLSZ
# DATA uJdEzx+uFVn4Y2qBA5ttVHgXzjW761l659nMwNQAXjSGkM5swBSO9iH+xmkK5Z4D9UQiKHbOvQc/p/tF07ygORV6v4uBmLD9sw94
# DATA sUcXBws8sw1r5mobZ7HZPSu62YZJcZwzZw2c1RrQWLOzGQEvhVPrCg2Ayxj/Nxr+Tzf6X+HgL/VzIScs1NkzaUGXQTZbSCTTzSir
# DATA 0sVogXEmy8oeVU/U1FsCeip4bz9+/OBRQR0sVSvDXDK8Z3RC9gOv7HAyMELDKZHRlCaqLLXnQeepHnM3xZuZquBRXkMZLG8AIGVx
# DATA B5izzAjIA87Gk6gL30jeKLCNgQI3U3QWHgyMUUeZB2wVgEMl5qEgpzj+Kb0mo5uxUyU9TPkopbqn7fhmjm/m+GaXyjfbbKzZaOJz
# DATA KgP5ai3+sxj8F2bvO+yZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZ
# DATA w5457JnDnl0f7Fmr1qrXz4o9q/YavfZzhD1bWH/eCH3GmasyjylhQtuqVXKHxfx6JZ/rVWE5SbY3cxnXbUZB1JvDN1WbQSCornl8
# DATA U02y2IqHvFviIeyrLB7V+UNrlSwatXls3TJeWN3ihfmtpmFQ5Qhpf13rNv1GdbHmNGtUdZp9qXNW8sJ6u9UJl/LT1iWvIqS0S0pe
# DATA xaJ5bZw8eujCklcVxtclJa+qnj5V8uihcyWvWqlci0ZSrTYvr5FU6/45Gkm1WT53I7GTd+GNJJe8UzcSJO+8jcRO3oU3klzyTt1I
# DATA kLzzNpLAb16LRhJUa5fXSCgW52gkQaN+7kZiJ+/CG0kueaduJEjeeRuJnbwLbyS55J26kSB5Z2skNrC13PRqQbBfq/errdp+sVYf
# DATA Fv1W3avV96snAVRXN4Kz0DDZ0jU0TDaaLRpmtV2vNIOz0DDLUdjzLRpmtR41a4aG2e50ut2ORcP0A/n5cmmYajOvzO4sZ49adjN8
# DATA TJ6wk4luO9VavMa+ZNtELlTMXxfvmd+qsLhk1uQls1ITW2Vk0SwXqlowXxtynVfP8o/pWeDyzYbZ3TSb3JuEw9wa3UnJVc8sWZ5f
# DATA vEGv1C/k+eLdmRdx1Q5JeZEvRSSugIVAsNSwiPpU1S6/XNBqteCBOR28kz1GS1LFbsMF3/PidqGV3E9H63S0TkfrdLROR+t0tE5H
# DATA 63S0TkfrdLROR+t0tE5H67wAWucimnMvbiuAIlbnYHoqOKZmUNGVm3651gwa9du5OYt6jA8P4zGNOCTDfDbGlRs+nqzUbis25n11
# DATA jB36AaNpf3BoOFeMSKSYUL16E/v7tyuMRXwrfl2Qiu/inLmcUh4PZqkHwWZPvYifVVFa9fxdrxL8xLwtE9qReSnlwX7EqM5tisNP
# DATA sca/sywkm2VonTN1gjBOECYnCLN46Nipwzh1mLOrw6xUUr5M1RjdWUMOQtoLiouVHLDRhnfeWBIy10fH7CqAhjJUMuhDBjJW4eCr
# DATA J4AE9ZO5bj7NIdvgRlgKEvQtjiDfVNZ3GpzgapqgGc7BElSfETYLlowxKOokeNt/E79+EhDRCs4kxb5mUhOcnJbKKZIh1gZ6AHhF
# DATA xSTYfu/k+OrnTGTNBSumm2X6hjHVdhC3UwglQnIks1uo6xrH0UnVJQskA09ml0zUGyfFvL4m1ishf6YL0FMmHg9VIT/30L9lpD9j
# DATA IUam90PPRHVMWB7cPLpGXge2ARdpOOQ5AC/PsCCMmmt2aFLFatEMNcHeSJreFLyDPlU+Mg4ne5EVmsrdXo/62vZsAt8GnqPJ1SSC
# DATA QlM81QI/yl8tM4+UZblZiYmq1KEYyKyDadezkncvGbJbjLq+ghLrGXWN/lMmuqQmc115IpwoXaTMlskgs0OK12zCvlUlPrQBNfBF
# DATA U4pxzBM3EVgxEXA2/0th85+WdHJdlCLtnRLrkSdvxTxiiloir0dDJG7Eqj3UtobRWvbJs5OXfL7U1U5Sl57b43EZ4JNFAc2Lhp8s
# DATA 0yFdCkDJlZ3eEiMVeRng703Y89pEWHoHq3quveN1Ma2NoXFKuW9F/mNcZcyCgwCJiMZnOJUyV+bmJjjMR9m0W+MV33783rsF796j
# DATA RwU1Dkt74WFBabkDYinzIhFaHEMlNNRKqqzUSKVgZD/jNJs3aLAdN/B4imF7DVHxkXQGsuFtPSzyrhUJVYl1iu5CCXSk5FE5dpwg
# DATA Slg3As0vGnWgCDqKKH5Kj7VAtZeqa18vs4k8a16VdS2aM9+BnBB1LTgr1rSOtoIpssGtDhhG4s8QGCnMftG+ZwN6cqgkMVUsS94D
# DATA zalBzHl1THdkodcL48Fsso5m+VCCwcLVKp7lS2SB2/21s8GdDb7UBleVxHninSc+Z92tNN6vj34712mM1BnOOfTEU2g88OKriVNs
# DATA 3Et4kMyLj2sX+jz9bDYGTrDk/QJ7xA8NooXu6M46EJEZYiw20sbG385EY7Z3NhZyz3QLpHni651XteH3CMe8uWFDvyJVAGyZcai+
# DATA 4NWbxkqcSu89neCjCHPjVR1x1pO9MUloDKaG3V96w89lTO+B2rzilg9gsiGVosXNYtO49SbeeVO/Xwaj+WgoQ1UZcMbi4Td177yh
# DATA NidyDS54GFZ61PcnVGaM/aSqNu3ynWqMKHgyGBe01DY4d8AUp30Jt6uitSIe74UjqlNd2xY0kbmbSeDP/S5RsE03Y39RiU4iiHfz
# DATA 4oG2vE6OyC/iyXQGRXWWErfioAqYzTyurSwpz33KJBmYyPxszIoq5gaq5NGUVdLHPHhSBg0GuqqnVnxuqoK6qSrdCi79euz3I23n
# DATA ZXkvJl/YHdKgr2c5GdtHK4krUnvaT2aDLrdLMWdHsPyw8RxTK1FXlwIueWxfkgU8SA6HHATZ5+BZhxCHt2TowaL/JGnzwKkk5mcj
# DATA ZiGqkNYBwUfJgdIr16ZzOO3r6H8wYTl7qvcei5uIs5vXW7TfmJ3OZI1TMKH2NqOXos6O78EPzEjNbFwgoQBZ1LfzxAik+hEc7DSc
# DATA RyN9b1exHrO1wXWJeU9c0So9oYjnw69u3PvKs46I6fWMjKvQjwZj1Z/JgqfVF7EMPg2USQ6qMI7CJyhh6TFR97Bm2Y2GeIE9w1Jg
# DATA BQpF5oOMhUcrsKdmyo6xwedm/RP1Mx5uyBB/sWz7zz//6PMPR1uv/NWL/h9lfTT4GB1GPJoBqjo+vPB3YO2yXqv9lVo3nvvXLwdB
# DATA 5a/K2X9/Vfb9Rrn+V175KjJghjZHr/+rl/O/H//4xw9nQojoUAcSd3mcQaXYSnkvcpGxH1kF8e69+w71GrzMSe07GXR5CZ8eKFFY
# DATA r4hUCtm2e3zYRn//hOxD/TlJX+HRC53+IG576vID+qpvmZgH01lb+Wf0FRzJwnCgv8/IdHnllQ8e3n3w4P5DbKDe2tp6hc/YvKI2
# DATA WPZkXzU7m7ZpMtmNbvXSrR3ezYiTIVtg8N2kXvEmqL43O4OYZjBbt1+Rrda9tIR8gJvv0eGos42HCt4WzdebW9YO1C12ChURejHL
# DATA ra2dHe1fKkVP4+m2v3P7lfl9n/mo8Tmyj9VD9AbqHQ9G/OYsoKiD3Cp4v1SRWf7ujwqveJ732VROkdzyebtDYRg+fX3Ww95Hv15t
# DATA 1gpPyMp8FO+NwsGtrUfvvPU377z77lYhnXbj5NYvt+g6DQ9bha1xPMY/6vtHn++o7FEbU6PJhIaeX/9ab1RNOUD7Ai+Wy8bX1Vki
# DATA e4h3c6e19PNdjAXTRB2rUPmvo8EPvsYFdcgvwcEovP5HcnioFKePwl70DtlFezikgNtLyK97WMnewZ1z17xXvfKyy3f4tM3SNOgr
# DATA Kq4HMGS2VXzn30j3Z6e25oPyPn8FlfiVV2gKDTflx0w32o5H6ZhG4Y+l0Hnyv3MLRYws4BV0XIINwB9KbE2kmEJtbxW3dvDDIBpt
# DATA y4OUkMCv4BqenEQl7CfgbcTbk61f3i3+z2HxV+Vi6+PSzVv/rvjRja38C/HfJMRU7hdI2H0U//bWO6N9nPaxehJ+ZmuHn1ED8S63
# DATA 9FxidnQi5BauLNtU86cf46QuxbTm/dTDhl71z/o4cLhe9LRDtm4qE0kVA9ibky56A/RHJd79sK3eiarzMfZXb+/s5PI0pZhOw1EH
# DATA VZEfL3g4PWCyU13doWrn+RvljprqKoxpNFGx09d3dTx/Wf5IftA3Ys+33MSHErfe6VKxbKnHo9F+PElGQ7U33L6PpnO9eI/u/ezz
# DATA Hblyf7QvR4LspM5XgrDYoxrw0Wf12ud0s4nFjq40VtZYL5/LHuuXHdV4zpNJOA0tB1z4Kybr0mnEIzsHslcsFiPfX8DRW47kFtl5
# DATA eFqC4QuT+QtPy+W5S7tbas+KXMvetzxZPx+lszGGK5pdWNFUicJ/fNrzY0qZ9BS8Y3CbXlPw/J35xCxvrR9/ZDXbj35KT+LU6kkx
# DATA 0xluVx96zooZZ3mJhsdo1FUHUE17nQ23Uci4pUSTDere+Jwfyh7rEJQ9/DRKvhLUN2i+961oLGvCf421JTg2vKHieL2RdJ7gdA3+
# DATA ocpHD04OefpUkPlyh+sjTjKg4NApC0yPTP+SChI7sKjvVbQ82DKY0zK9Ty0S3Rb6GVxSeuYPHzRLhmK6mPZD7L+S5mp6v12K7Cji
# DATA i+LIUqZL6XEE2yWcHL7BwoLJ5JCF7eKnu1v04lHYmeFAuRnJ0XnTVLWrb84ykErtY2XFcK9qbtnxbnpbdk0zj2ifeYLuJElLIIRt
# DATA 63AKuPKzjz94+LP33/2P3q/l272H9+8+1l/u/0/33i145QRIDxMmp45+7nU5tOwV1D0dSOSpuUXhMF8b5ZoaKNEOS59QwW2rKnOD
# DATA m2b2kqmdcM5oxVPbtazEEhXY9i9zt+G/rS7XEnSX8hQ+FcW9i48m10tZru/isBesyxL+qtGA1I+eFhaDLhZVleDQdX91C0+bb/w2
# DATA Y07Ly2maXexOkvHuXVhcy8JN9RIN2ae7o4Tec1DEzDcGSCaVUKjkiii5Le7RTEHuLA0QsaQqgie1zatD0a0G32Gm6AEfP+OLMrDz
# DATA wX5UgLNgOptEH8sWyt3Hk5k6eK0/ivW5Wy0XZN2Ur+/kC9JqMapQtREFP9V4O3/7ZsOVDnOuB1zZQjfrJtkS82L2iU3tXlLsC2XR
# DATA z9dHq/qxUSaZHk6nYadvx/WjxVJb9t+mee6vzXR1Mi9vYG+e3x92P/MLgVgGbEPD7hxNt9U3ZSffOkXeWpNMidRC9rIcQPYS82sP
# DATA Wz4Gc90DRdtk7GI01hTRZCjlQ8NYJ8oXjyfZtGs9/cb9X7z/83ffPbHk6EmaJS17MiuvQBfXmxBw2FEzAIxE26oa86QIPbeeYZfu
# DATA TvbYq/+Af1FFJ7fhLN/Hofqd5gBFZXRTmvTeC6tirHqGTfilT9BtsMXUg/wPHk1VJHIdNp/b2M4mM7ivpOJT8OQbTzCUNfsUGE7v
# DATA Pv8DIVYT0F+rEf/mG697PO1MGQ2qulrbYV3yfoZBO/QY3eNh99IIXsqOR+NTOCajZs4QecTO/fuYhW29n2Afd1YjO8aH3ubrvXgy
# DATA jLpbKCOqaB9/DHPgY7Lfdr2tjz9GiX388ZZEWorvmroSJzjFPowuw+23mf+vUivXAn/O/wevoPP/XcV/f/2jm7N0crMdj26S6eCN
# DATA D6f9ZFR95cc//jELdwivFosvsjCGNQas+GK5IhlHGnqrN3A91GaUx7OtwYC6hTVeQSxT1Gv6G/Y06c/9MIVvUH+NoQ82sZyAZ/cn
# DATA ygqi+dqfTeOB+cZzCPMtHazxQoYT2wk575Sc9idCwDMXqJHlPJYc5dlkQDGWnlPHm67x5I86Fl488WT2PpO8liEzGz3VsECZfNfu
# DATA 4GBS05zHax9yuZjSYEsdyyiT6JNIrf8hQ2TWmXJh6ff+fLw3CbvRL6B2oF+8GBczLlHeyHCFXWTbNDdKM3eRdK9LEqJvU4+ydg/K
# DATA UT8nI77lreFZDt9heWx45oldoVu8i2prR4cnM4sx+0rVtB+7fHZl+iLvmOI0zFRPoDhoPb2Vn0px+nF6OMQmmW3LmORkbh39H0ff
# DATA eEd/PPr66F+Pvj3+8vgfj35Pn785+ot3/J/ow5+O/uwd/93RN8df0LU/esdfHn179Be65YejP9Pt+OHLo++Ovzr+L/QTP/1nfL3l
# DATA YfIAc15ioMZEFR057FgawpLfli+pMvx4EvtxYpt7vF66q50kvVWOkIjsDcnn7mw4TvVv0QiLmx+HaSeOxSjBPjMMsLsVPUMTR0y3
# DATA wDNilnRSs9zhE/QZYzO1LWVzW7InKPa7uRQtMRowpez0qci2ET6KbuWcEzfQXBNRzlcGrNUfYEq5y9PJjeaiyLSdZT/3BjOozeR+
# DATA QhywFXlb30NpHyXajajumEQMG9PCVFKstl+H7uH8+xEZEDQLy0fOTOs/7nWtWXsu+9TU/eEb9tT9jXce3r/3+GcP/2M+ygtT6Vw6
# DATA 7Lfln1tqZ6tnGQW/5NmFZySxaGglrq8pZ8rcNI3umI24yfGPqj3L+rFyQhnXNzxQSnUNbqbqCqf29mu3MgfZR7lvxY8+Kxfq/ufW
# DATA 7zuvfVjauaEufPRZpVCvYq5jv9rqBf7H0XfU2v9/9t69uY3ryhedv/kp2k4yjZYB8CFZVqAgHkqibY714BUpOwmFoEACJBGBAIIG
# DATA JHFoTPlxMpO5cSU3qdStU1M1Myd17wdQFCtWHNv5CtJXuJ/k7vXa7wZA2c6cOmcy51hE9+79XHvttdfjt/6o9vSHwA8+URv8c7Xj
# DATA v0ie/R43/rO/KA7wpXr5pSoIm/9RWT1TT95Xzx4lz55CiY/U30+1qho5HykDewB5UpJJUIeR9npswmkhmxXUYtZU8rXN009yxbsp
# DATA eIXmteVlYDU8r7oC2NnLrWF3WbWVNuLzvPLqSjAN/9ezT4DTKab2CHid4n80PDVSNSfIIdX4n8I74H8/x8n4HOZL/Xz2xbMvFAd8
# DATA ovXZkPA+9zWi5dTRWa8m36uznhmLZ/B7bd76QG+ewuo8hYah/cfQzUeLdt9wdGL9z3/1/EPg4nrxWA9gaalRw0JaauyorcMbIw4P
# DATA /htcwNU46QUTgWPV0Wvo7R6nyt1LtYZdnczWCV3SbX1sbClfeCH/ZF3fBc/H35K7P15uvJKV1GZcNnuv2vzHinp6Llt+PWWFbqAC
# DATA pwrBVa8PwE2HqDBWs3uaVuHyXq2mU/LyNa/wk921hlCSmrVsztD98dacrU3Eg9EdFUM7CX4Hm/n5r599XjYcQHY77vxHqvAjqEgV
# DATA U5zh2WPgAcwfVOUy139+/rGisC+BPIFy1e9fWbNKYIWxnUxjXW3ATpZx21MIX3b7TKizJ2HOXsAJ+bPaWmrJExzUpyzbqB4//1gJ
# DATA NXaPWdnExgRAL7S5Hb2NsTka1tk43Zm2vl7W2cPloQDXJTXfHE6MpeEX2qxUEdiMSJi8AvCVZrBAy4os4TmaOFQx/LdeDzn0gbzk
# DATA wnl4KP2OhvH8o8iqffH8IzUnSMZwLH2CtPUx7dv4+YWn02XnnSJjNWFPaCKh6oBkn3+cUAl4qCmBlxu7HVttdRMtjQf3On13fYuN
# DATA 1Ipd3K3O/q24gl2lL8FTzz8Czq5Gtr61WTGbcQGC4BGV0vWtrebWrds79fMrqyt3+7c3btxcf3f9nY3m1vrNjevNO7ev1zlVDQrD
# DATA D1r3O7XzgO3QT51dmJovVWeaO7fe3riJBgkcBEnemzd3Nm7fXL/e/Pt3d5rbG1dvb+xgEb7jVrFo86jzsHQehHW3/rv9ndt3tnea
# DATA W7dv/eCH9dW7/Rvrt390Zf1m8/rGm+tXf9i8vnnz7ebGzfUr1zeu1RFPFo0xtFpwUfWlsNgKoT6etcRwnWH4WhHQ8PAGtSBLFerX
# DATA xVdfPf9qsET/QbzTMBsizee/IApTFKzqgpf0vbsopgHpPTn9ospukVGwRLiriQmExbUZ0qCiKDgQVZdBSPhMEc4Xqt9PgOd8/vxX
# DATA LAzym0eiT4kIftxfy4xXMlb4mitqnE5Dg7guPMsNAFdjt+HI52Dejpu20Uy9ryHoZhmrTfd21VcNBKzD7wpZvriuNtmgVrLsZ8NO
# DATA Z5SrO879zmjUVVf4NDWqD0KKRE2HWGcH4D3c3afgAcSo0H6xwkOTvQ44CZPSA4UUUPnW/VkDx9Zw5m5SOzfAUqYFUqoATmT1Tere
# DATA eLjfqEHTP14KywYn16fIZNW5pChH8ZwnRPK/fvZb5KzwCHgtsOJPQPOgtoISQKDSipR+/kuHVTvHMS4C9QGf8vzl4TzwiLc7YzCT
# DATA 55HJyImWmBJ5M0mF4bmcoND4Bco1f4LOgfTgHSpf8IDgH/Wbbf0gZsI+UhteyRfqgIOPVHVwWsGEPTFLEp93dt0o7tsiM89HwWeq
# DATA L7+kc4M7EQyLTmB/AVgUl05kQDmrwUWtDwquLiDr6oKKjwWXeE3Uda1ALMX5xm56bX1n/cr69gacRmkjq8q3tuGl9HbnBFV05SRQ
# DATA NnrtaQsqr7i8ih60aq2ATP+MKwesG5nhExJAQEaDh0aWpgVVkqVinZ8mTseNbMX9kD/1dVlfPPAWaTFI4CWw/shTnG0KT7RvFa6I
# DATA twvwMVdBTyDYpmPvhtvkMqLKdXOcEFDGeZ4LZFcyhmcxKIM1rVPc1k01PGv7wlhIoaSkabTew6hKVvnF92xW7RJaZ2BExekt3DGF
# DATA Q0IDYa+LED9q9vFPWRoKsoIn2GHpPfVsnT6SgynztJb4GWktp7HGwIAJqriSP23ot5Vm1R5dseH+J/1xDy22NVC/yanC6h+mApCq
# DATA rOGo5ziYdHNrnSqAi+ibvcFeq7e5df+iPPR6rQanaVh9LjPG0r1+LF0KJ54pHODIOWiXlYyQeCDLcDqEvGw9Ml5goEh10ldCd+mc
# DATA VESmAPDjgiON9w/qh7G4zbu4JlQkFCuDzC6OH1bIJD8gxZi6J3yGOvKn0eMBX9ApcFnkqMfIYj/G653NIRLSTzyxtGrWgeBse5mR
# DATA 2CHBM/DiJzR0UE3Fr0F+LTodCribdQ5It2xOy91+YUbrdlaVowJ62p7AXdA6uKrJs9/SyfsYu/5zfPEnHuunvKp/wpXA+8tVuGHo
# DATA cd3c2Hn31u23PXkpNsWSkmPA4+XfOTpQlrh4Bv6xJDjukwjdtE88T7BnoTjH4ypoycgsoX0Eoq6y4AsS0As/Qh/Y2lLgGXQ6dbi3
# DATA 1gpGRO3QcxVLE+sL+QCv/W8SvIfT9fSJNtba7p2OykbfolCSeh/vvE+Ttzd+WH9n/fqdDdGTqAeeNw7eBHSOa/tSQPpKiJPHHLpw
# DATA MYg6FKkaZgwj2vMv0Kb2CQpbX5JW4gO8qFuXK9bNkjYHLl5/She4lKA7q4yG2J3jGubeV0xPZ06wd01Vf/6ffO1DbSlNrbVe+NQb
# DATA gPr6Z/riLV7zqme2nVTiJoz9dGmm77Pjoc2Xb9d93brJgpAL0/gpsrh/Fh1RwMeIH8OYvqShq0H9KnKrNdsWLGXN/Ki19upFezTt
# DATA 7iFELNbFC6DKRTLjSWuZgdESlo724qY92GT7R5P+PdhkKEb3Wsd77VZNLHqYb8GKLcjKyV7q69OpR1WKQy5hfc64+P1R5yH9pW01
# DATA FG3ahIGoI9V45/LlfTAYh567bDXrUUISYnlDkltRZwuOyzASMP/iGT0ECzV8oH7CCTY0lsTtt9bVzG3fubFtuC5oGYeOUXuBKBDS
# DATA oFHNmekMdnMhBQgSjbGJo/UECf0x7VEiKLUR9GFNplgY7rI9Doh4ID9hh3yyV9IkSV+hHr6CTv1eL2VN7iPiQJOWxsx7mU6RPti2
# DATA U4qAm79M6AQugpS+X4wGD1AUDPpuOy1kpDZBZ2db6i40lah1aFUO0L81S5KStzoZuOgNHhQbSsQMgGI8dDsq0RSunDCpLy0ZBo8L
# DATA Vhs//xmcIB8prvW5xW4x8WIdZ3A5ZodAK3CMFOUFk7V6GjALIHCxc0TH8q9+L1lCo16Con8WFRapV6zR4TSigC1jE67AwFbqvDce
# DATA 4VWKta6ClwV7Ao87/kNx5871E5ZtnIJaWtEki2onolpb6qB+YBdTUYChh4cYWXtOJeh8ACotf0ff6d/rQ0S+hnblL1IvgIjH/b26
# DATA T2IWeaGqXRbDXQF4JCtAZ7mvNMFJk5OO9lc4j1l8enBkHIcPn+Dd0BpK8fBvIqQJvOIO0Dyk7nLL+ZBKAvgK5IcYlbrEMLvIvQGR
# DATA AWNmsKJdWV5EkUsbWRav0hquRyGZua9Fv8SjQBQF0INdOyyEpw3o7KCrejZCN12uukERntAqsn1x1zABctwlHgN3y1kJ/U0RVc74
# DATA 1mKJ/e4BiQTWRCzypT8boOPY5UwhKRniMPUMXkKokV1KLEKjp/I4hk47bTjcVT4gOgLiQFXQ7QHlCPRlCHfYGKuLJFAZ8Qce7S62
# DATA of5fPlCZJf83xbn+oIRidVV+/k+Gi5GqUjFzvCsr6UxdR0E0Dfg48kDNIUl0dq9YQ+cUdE0gzO3xoHQDxWyW3trLBz3ImWZNEH+p
# DATA 612GB0sLHRJKIh/07mM2oLw56vRa4+79TnM8sGOhQBBwyqJJNQynckT6ipZWZsjzv2CB2Pj7kRD/GCysOLOoyADrPV7Gn/0Bzh26
# DATA tTzC+X5smRFlsLJpkFmFx+H8DuPR9StVt7qt4x3/A2CnxR12xXR3rpaYAvqdyXjUArAIogTRSCi5VuPFAFIQzL+xzQBi4GEfwngp
# DATA V1KvddIZ5Qlka01aB2PAKh/0MUksuoVeZkAWCjQnRBXdkLbUxBxsDH+TE1O+q560jnv2UWpe0HMK/agUflf4Xr1uhERs0HOWE61X
# DATA 9zdC4RJHXE2j+lVuzd2X1kKYa6BFWahLxBWaU3vgIcirj+EeqqNeiLbiT5fcGG0cl7mPwoY7TQUhKa0lp1OjCRGbw63tWSYHtxfo
# DATA jOrPLL8ulGwfoUT7FHcnSLXalV10fihtwDb5GTuKfA5qhsfayMMGiscF/JYsbXR9/wR1bqS2RF78xFFEuJ4wZrFidlEGJpKdF9wj
# DATA WSqLX1Gsw5PKzTo5l5ybA59vsSMcO5l8K2HkWsJeYjChbr+Czq56ehm/S93n7xNQ0qDX1shMSE5L/pk6z+c6ekkBoR7VDv8NFMrP
# DATA P5QOVIK7JUXYizwhrbLHtNm/PKNYSCYvIm7upnrOwZ5mOCePilpzSoGsCbKhacz1ijDIAloeQf+I8+cXnw3n2CmeC1E1WLxUZCKv
# DATA B6Zp7TRfyH5IcoLHtthklISOci2UtGoLRCAKGWtxG/1NEKrCEfOKlaVzHDUKp0x7KQvatN5bbsv+IKR8VJqxX8avvVICbyrUEr3x
# DATA 5+ssl+BwkAvcfN211D1H7QbmWFJnA2J1d0oSk2EFa/YMngCbkLT6WNYOVP9wHbKtTad4gh2wMFdOmgCYIOqdKU4KFCvQSf1Wjfj3
# DATA aPogo9EjcVNNQvHpcaiNkqSfLvHqzb3AJQAjO8lKK+QCQfqFNwF7d5hvo6Tjvo4TjymDMyVbO+xyVJmyZYZvXYOlwxQQKaE9+EmH
# DATA wLQJKntybOuE7JlE1mp1zTXGS8F5rHPxHrPPD4AYttTMHSlR09Rjd3LUPW6hD3WxgGV1j4t7N0SphC2Js+n3BWYd8Atb/WTCyhk5
# DATA bpHpul4CwtDtPlN+Hn+53XAo2oz0zB5ccYAUkJ0bqMT/mLvXS46MHNc937WChawdooP8z6P/ndsQ6aZN+6IFv3nr2kZze2d9Z0PH
# DATA w2xubOOOZSaKEEBwwnJnzLhQyV7EXOcsD+VmctP9pkZLHHA+MYciPTj2aW2j8s2XVlgYh8scd3MApHaDwEjVl8cNjPy9vpB4fINj
# DATA lWAiPXsM90qAX3TwnW0HCaeO1PrRwddxBv42WRm89tpr5kasZ9kOAr/dIaQIRgfu3O8OJnmyeWP9zY1yMskp+QH4Az7oWCmh+2PW
# DATA /anNMgTES6tGQrNLfjoZjFvJTxRJwMGOC/kAY79HHTW1kw5GmHcRmQgydLX5FothGZOhCSnn2ENiAWVv56E7YcPdo3I/c0va2kF3
# DATA MvEmvfgNUA5S/EotJvesaIGwXDm4s2kf2l6r3yTwSNArN1maL9HQyjTLENe/f9TFVO+WKyfjijBDaNeBpEVxwD8sFWWTqsQXtlqB
# DATA bg8mn4R4UOkIV7UNgQosVvOgC1hsuKYPWqO20SeA7bdYJUxqdQw24eHMKhcIHr9BFwxb4fNnso5SpNgjMfImKKU9UZfPj8gzxtMS
# DATA oZ+IUY//ssCn0LP48mQL2pUDExdDg1N8mBI6AxPO3wPoq/fufjsC/2Z7zzvOJaRahH49ffYpWbFBCaUkajQkfRSZCr6wwMUbI0hi
# DATA Q7tPcciY010vFT8sHD2/d8cf81J/pfR67W6V/sxOV8sU7EdfLzJocf8kZ6QP0HwRHyqZmcLxCW01zUBdcgvGGnzB/obuERFOiv/d
# DATA C86OX022qEGRzDz2TLlOvxHpm/FJ0GmNDPjsMZMonquk3RJ4NKh7/LCEwF+OW3pVHUkQB7W70kjOJRey3doFT0yDioNZgT1Bb2aO
# DATA 73fsFQHX7EdIwrzcHG+kRwZ6o09Im8QDB9+PWRbIy6S3B07xR80xFEn9jDaT44X8CSv2n1L8OWl8hbIM3nPubh/7DRdWR2DT+8Al
# DATA w8g3kknHL8rP1+0vykELxprk06lVyPJZwfwCdg+Zkzl1Mv6Qeue6dvZP/FbYWXLGDjBBwa7NHSD2jD+EdtV0uuG1j4Y/NTVOIX1z
# DATA 9T/1N64/c2ZSzjBIu6/BUvhV+QiYtKDWYizeFn+r3Y5gGuSZngGrUDgkyw85oNJYS2fwS3G8GyhW+59Qh/gBxWZ6/Ckw4DzR8YQ+
# DATA 56L8CdBfTMLhbD94sk3iFcARu5vHeUm2b5bEyGlNyURUUAto6N1tNKndvsyWv1vsd7pS9Vz3smCWg/n8dzU/NAXa+/XPGFj4+yCS
# DATA 40tkSR/hfz989phlnLPO5XCIXhW7lNCEfdPrddNzdNwLbN5MEU4kO9AfVWjIj39rwrYorpDa+Jtgbv6HGtLvMbjy0fNfPv8XZt4y
# DATA PxLSENW6/YXiWlQFLDWA6/SHSLEfqZqehGLUZzrmhfFc6gVRY+xiv7XFAYMWgCwLCufXRP9MVaHa+cLKdy/KrOwfEd1gO+RfR3a3
# DATA u4iedhe9VhAytRHOym+cERcQRVSb/RRPPnRGxAfWGIr09uxiMUM5r3XfhZco9o504uqirhuNKCwBKSNRc79mcz52SZujs/w3K0rX
# DATA F7FlXr5gOns/0GMGrEtUmVq3Jej/PHZ67gwfO1YObkd5ZwOcfLcQMTLLtPUf5TMQxcBpugoYR/c6J3lp9xzXw0007E+qnYdjUAUv
# DATA Zl8WXz5b/e5ZL/RFGmqvBe5mCxvXFzg4QtVxPNBO91T03qdkGkE3VLL+gUcYKfNrEV+3oPPaQ1lYPqRzx4lw7M9pVfGB1MyNpGOi
# DATA sBv/kg0USn9lsbNFuxq5/rVmX1Bp+lSQSAln2p1V8VcmOR2Lk9Jyhgc+jdi43S8E8HwWyw8uqAbULbTxIlZLdJFnuMDozuIq2VZf
# DATA 28HFeMbQYJ2VNNoc21MrTvnu7qNGs292J5gdoGQoCGoxPuBF8+V4nH1T+0LxD3bFBHy5arvTGcIfrKiyPAWNQAUne1oWLs/R4qAd
# DATA fqkePCxyxSnwD/iVOMl/gWY1ONwRmSKBWCk1Z38AZxwMFzUh4s8/kqPdxkiwhMGIE0xcapPNX5dZ2TUbvIFjN6AV8a3FxYOgGDcA
# DATA xRZVPtdmiaLT3hG3i2ilc3DQQQWh6nxJNIfz2NUiI9IVzxpTsb4HfvxJxoNynvZhLVx9c7d4VDRcBKaGtdXdowHScyfOOgxBokJB
# DATA DJJTL4y1FInedxk6F/cQAZzppCLUu+7AWG2qvBZg1OxQKG1qE3AF0g2m8WDTeh2vKIXM+wzXDlSRfE4RKUBsJtqJI9U45CYG6mFB
# DATA BYf7ThiWS19RX6pRR9F/FwRQIF5vRTlDhkSU8mL8HS7G7kqjOtJoRfiksqrxi2pSxl4Oqy1EQ1K/xocjAguXv3/KkOftLj5WawqA
# DATA /4D7rWSUh+go12q38YkSyDoH3Xtp1Dr57D8Kdy5s9p8r6gfB9J8xVkutz2cUBSoaqoR20FPYKLhFMAANyiGY1vvoQflL+870kbUw
# DATA vA67PIEQyYV/+QWqw8GwlO5Nuj1IloFGBMvms3PUzZmFAE4ImBAGCFcHLk6YAEC7eMDr0XDQIxM3nJgiK1j1jSDnaacP9EHgw2yD
# DATA gtwBfdUjQNzsQfCOqrCPyQ10/BhAEqsDsRqO0Ibxh3GenjsXC3j0pS+TZALOUOu6VOPLmwYlTEG/n3772xKbrEnUPmViXNc+P7S2
# DATA AzplmaXsLoYV402+Eeszp/tQZQnmyq6HnUzpMzduFhXjdFJY6nASC6R3se+W3IB6S04OOx2GygvnKjx6o4yheKJmrGV4RjiF/yc7
# DATA IfTaFc65NjmOkDtKyc2b2zvrN69uNHd+uLUBywrcTO0QZGSExTsgQP39o0570uuM0qmvNaT/lfYGg94c0mMuTJKwM5/Cn+v1pKgK
# DATA zYOygg5YM6/mg3Wj0JL6ZW1C2oXUlhB+5hy2PE+gR/gaj10t5JjY2kdkwPsUceqeKLH0KYcHO95Tsw9fQrHFbfFKkl4ObSOh1tUJ
# DATA HiUzmXamfVxsRtX+69oa7LpohfygZmW3QZkywl08Gu7pI9shYqM/s+RL+MLRlsGDhVVl8wXPL2OC55M4Jg2amT/jGP05wvUM1j2P
# DATA /c9h5HQV2++16C7mtDiTNagZ1d/ZDB1zwfKL2B56CYFw4mLL7Dl67NxYBMzQiqIIbfPGtPsHWJsIcMVlIfDP+VaMxsEvROoByx8B
# DATA 852R4j2qP3WnsZYgv4kd/lM3kMK9HOMt18Yy1fFTwOjq4sARmvfqpA0vJ7ZutL6Ll3lS/WUN/dKoEOt2ASu7VETutnyQEd4OwNQD
# DATA w6P95Q4Uu6NKsWxQWHCLGD0hnRh9Z0Fd/pYv+GJLS/fevdP0fq75HaN+L00r+u8L08oF/eO8enHpu629hvNE/l4lPzndWJzNEKrH
# DATA TJjPMDDiUXK28+EJsv9H5Bjxz4CHIq4ABj794yBCYrdgAUAQNsOyQydOtadELVmF6B2t/q/5fqMoS5DnJmucmAbdbC46oBOcoPTf
# DATA 6mPSrKFiyqiyKAsUOHjVRM8i0b7qCY0KusW7Fkrxn2X3rN42nlfRrTAVX6y5WnzUhAuUroZEwZ9BUEehJcQC4sWLZswX33bbJPTH
# DATA S9Md+uPi9EfsoH9XYpuxW3DJ9QDAdcKdUJ8dCWeVsCw/YNqP+ooHexU8hW8p/jVo3sS0BrDKpuMeJJJ7pDtgR1/CiaL1GegIFjPk
# DATA 1NR5oO7Ov8fjQY4P3FesfzWY1JWKHeATQgkVrrDpPvjK2PmT8ohC2p34IIAwNzgf9zmVSMxhEBwJDUnCL8/bCYFJMIJTv8t9yLUF
# DATA PfEKI2X+As47YGUrPHLjWuzQ5AidnBcOVLJK0lAaRZ8EvtKusUHPyH4AUMlKbK8VV5ld+DICwLrIBH1JATTo1MXC0me2ZnuG2dp2
# DATA Ut89Rx0zXFfJDOfMYJnrol0pDL+0/NaD6COdYbXYkGDiJ0IMINgRXMWcABwXG0j8GTzLCHk6sIskm/nJ9g+TKmfwHzhvwGM6h2cs
# DATA APuLPYbihkk4QYgIUa8Duo+746ItyeaPpgsyNHsXv+iWWCTWAuvwoizE4BwJXAsIqLZw3GycdMhSHURrhkEe1CnL0o8PjKWffi7O
# DATA muaZ9x9r7kVQc4XU4aDqGLd0nCjXIX2+Db3Qf9xOuBO6jpsShrg8FqWjzSXmlYjNkX9Q7GMqtTG90S2cIk8Hons9bvWVBN5OQO1h
# DATA 5YZjp31qBFwXIWE5/Ctu5LZreExyX9Bj8EzI5EI1/EsJEJCg/SxObJagTY/OgmH+V9y5rHEXwDIWul1brDmghDoLbK0WEyXX88fo
# DATA ZUsYauRpPINlzp412lX6fgIVhM54lmASk96DPNu2y53vZuYdyY6zbcMRfKWWM3inA1AyOtgzLgRc4nwN3nw6iXUiZmOmZXN0RPBZ
# DATA 4xsycEQA8xXfwb00jXE+cQAQTPgOVN9pQiBXk9iTBHKVONgFmNWZQu9dpDH6x4EZ6xv4cGhDbwhpz8VP4c3gR+2RzE29oQB8rsbE
# DATA mBZBJIVbnsrMk2CllJG7GwY8SWT1xYM2g2g6HUKHsxKJ2fQBqHyEIDP0eShBFujAN9nhIMh0AdYZIBKpG5Urmbh8NBh0ZLgzt6cs
# DATA q+163CgSrkJCXCx09H/XsNFimqGwUVZut5Aeeh2wFA8e9CFDY781zI8G49D4bWM+p/cHvcmxHDfGnWp8MgQVU7rX7bfRXEadrtnp
# DATA BcHQT+tUS9yhsdD2QqHrxG/NpyARvpAuLnE9bWsu+9EOuFgOabLmkaitkaM/pi7biIbBe9dEP0idhrcIozE7ObO4tEYT/aqacr8j
# DATA MVxB+pVZR5ZgktIvOQabE0r6KUFQ4ks56vQ6rbzDealrS3MdLz1w2e8nF1YCTaO+W/cV4Y66+9ohVO3hwf0OpY1UhE2Ke+6C7wY6
# DATA O/PMd6cmcg1/6ug1bjMr7pXEm1GEmY4t4w+d6DJX9wWfvZKUVspZci4pXUgqfPFTz7NgotGWUrKDK+fGcPphm8EQUvZ0KZvBaMcU
# DATA 8ZMJPI2WXFclB9t53DpERFKuozqywJ1rqSfcCoYyeDRRMiv1eS0EUubKgq4aapi/jkuFiKlpCa3PXNcrqq5MVVEp3Q8eZ6/ji9dr
# DATA reP2xQvvtUbHFy+oh3hOHHqgTGZ2BHlUg+QbfVHZwloNXvrrPxkSEHHJVO4mvzXP7dR/pfTwaH9U7Q5MHqll8urSv0Ja42OjyQDq
# DATA xptTi1O6aTNQRKmo+wQb85EwkLi4GLrboQvbkuczc2o8zrQPGv5RGY4GD0+8nxW61I9sBzXLvS10dTMebuT0Ng2o0aCJLexVAw4W
# DATA GI26mCNG3AHH8mx3MGWw7qjrBhq+XcTWWf4dwfgIKgQsxUZSYnW56M2FjLQUBa/wX9csZheL9CHWsXK0t9GSXlNwTimJxuml07ep
# DATA vWnsKzWNGDJ0wB90B6XMLjyJvE1aOTjo+Sdg7kMakKRkYqf5Nx9PFtBBXi9lTo7ppgVHG560br12po6mSd9d/J1uX45qg/6hJW6r
# DATA A4wkYsReq5EAZeQsodyzHeC1EkH3RM+zUeTqnkTe2VMYh2zgI2F0j8ExjF//w4qhV54lP2OVtUWpisAr3EEVhr1I5UI7lE1hvh+g
# DATA P3YR1+26tAHMujoFExP7UJdKtWBiuPmw2++DPTpKUszazbQ6jJ0P+AVOroJBcpzXbgy/QXrWWGS0+s1icbH2Gvux8KpgYTw8fCZg
# DATA x/abQmjlUnFsr+0eIk8zOQJ5GOq6QpjhQcVOr7vzT/TchD7Q2O0jfhpq8bDlWsRhfSGCKWw1i1DR2Slp9pah/vlRVgtSzgH5shG/
# DATA djImWhrNNniC9yIZ8TgroO9qazxo6UMqfD3ul8vSki1FqLFWyR2hKnqc3IkDj3sdifU2891DI/WZspGQpkQoQyLEPeqIJzDzltQn
# DATA zFOmgpo7K5tEGuosZwmrxl2fhkLpAvEVC5FrrAPOxJ6JLr2+YO97uI3tNRiMDjFRiaGvKt3CXFCX2aSu6+5GLuryMgvd3v0tcqbt
# DATA QSGfZYNWdqQIqF9mN3m5lAPzcyamFA6jHEghoTCVOugolBGHQVCeoEvlIyX3kRLCFRBL4aDKgWQTCmtue653Asbsf4YtoixVFPVK
# DATA M+TRhfY0mKdR4X8DnC6pwfd5leff57GEQVKjVletyB1q9h1qFbGU2fXVxZOxfbQlmz1kbfsXcjSuxV1dH+F3NAXqwzI7J6FxSd4S
# DATA pXjuBgJhbBuAtZeRb2PRCEx6usrGUBNTSc20xsSMI8tfu2kEFst8q3XBwFTtKqWLpqQSOo8cvOuzwfsWYsq3JGwyrjWNohawBzzB
# DATA FnwDqASp58BxJvQF6lyA5RH1s9B4Qb1eyXPvCbwc5sLqg3tOEMP6/JcQySbJ5A3GLL2xUJiMwYeJrQhNwXMsqZ0Jk9Q2pWNyl2/S
# DATA TxNRGAGmgUC9JVKOktqRuWCSq/Nq7yTptEa9LspYzItzOqM7rbZV3QDRHofqDt8aM4JjV1XePe6or45BOs6PWu3BAxdvthrCLLh+
# DATA o8v/mV6jy3N8RnWf/6d0GV2A5vQA2GnULILnM7oc8xh1YUltaBJ2IXV3Q1UChN26ahHYXRfeIOamVQugG8y1wt5I7JM86Ks7WM/P
# DATA 8BAjDUdbIB+6/TH1FfeIlj+sPyEGjCjecFB7kErktGLlOpC4FM2UIR6FA3L/qP0EraDqL51cbb+iZ2ejCj2+F0Z6YYYeMXS7AkMk
# DATA MZTluzgD4EEORNcpNngKZ0iIJGQXtR+bwqaCWK1/TeAIPt7hEBQGWAwg5moGaCiuG1IU1YlI50sLE6cYPmUGEIQbAfjEHYAv+9Wi
# DATA 8BCOeBf1hEAOPbOEhydiXdjNDS5sKpbozW8sWsZrrmR2WpFS2oKtoJpisrLpq5/4OYbRpD2jzuHOE4ymF8ofMiN3iOdRLk58M1ja
# DATA ZQT/orxx6vz7VD39k8TPfUkymAekiY8MUq6T9MP3GO63Ow/LWhLsoGmwpRGq58LmxLLhfD+5dA5y4OB/ZjiGG9godPl++vznkgP2
# DATA 9zRW9cBNX4suOGC8iaDkSO6MmtvLciLpKGpJmDKDM9TBJEDJY7KorAwurqxMCwfuoXaoPolKFFG8vSmxQb3LCXlT1AMH/CziRxzN
# DATA qVGW9FTFqSbsiBdccq3fUDXZThNCpvNdUw7Y9YQrnM5ypbAl0aacSwaQjs4lKxMo4qcrcbfupMqYy/PEgStm1kAvSssSUDNMwTJS
# DATA 1GKOfGAv1fFz/BeRghMtVuBNaWT5Dc2S1e0MpPk8AV6TQHqvE7mVEhp5awTKRsyZSmjuWKlVF8x+NdnABGIgLKjPcgR9R0+wXpsh
# DATA rYcA2IGNsESBHt3jahxmPZS35nm323shLocygvbXcuPyb1u+rCqI/1lQIoT6X9w/X8tSX5t/Utzr3wox5vRfG/iPojYnbbqT+Mre
# DATA YfFq3X1nMQJQisk9vD/2QIQsscWGKUCNBsEYuMMilVa7m+Ptt2Rh21u6Tc1QGNNepF0gZhvNXtsL4uYFK6YrYkNgeXK+CUGr/D03
# DATA 0DNZHjRPokZZucJlgiP+X8MM4Qhx6nmhc6gYzz965DuQ2l4YlDoVPzSJ7Yvk5V9qrQt2tQl7qcQ/+AQYjO4RaLWrLFzcfFLlKkDD
# DATA ZxCcohpBLumoA3UHuAfpclrgy29lvU9w5ghW6Wlhkq9CialSMcdcAQIqPGhoMzc/YLl0wXmhw6BJZ6YPbVX2G4atVZLJWE6G1hT6
# DATA mcaR+zoqS3psAVFT4ErmK/pmJyt3phiheR2w2SeJpQKcP8URVQrhasQheRfL5czjLYDLkK2oX9vouHGdkiiCwsHaVUPKCVPX5UA+
# DATA t6GN4dL5Pu7nX1iBM5wAwtOGom7S6TG10Hx744eRbfD/xBt+QqpmyG1LTaprpF2Poxk4Raig4xbDAthikMW1AzmQKZP8k4mH1oSt
# DATA eDABnpsyY946rgC1RDvdmcsguSXT37vpZlsJYW7Fzv27prYM1dFAqX88allIAbuN6Yzs1zX3jIebfXdrMKKwm6H6wwAwofv71q3b
# DATA CBG9pv6Xun6uWAGfhKoL/Vzts2PtLBU/EtmR1XGRKrvgBoQwkqbaEzEKUGKLm1/p/GRQ9jOdgpa/CaOjFPubeEjsYbzUQpCGheDp
# DATA zIxS79JB4rD2YYxBXcW8YfhaDN6H8PO0tL/YTGbzJ67mMr8sDvKF/hiuH8a0GJhtJhxbKcZOCd4rIDd4HIjLpRkOoNmLAm95vDgC
# DATA Yhj2LvbFLFTDwF3pRZEqozho3xBO5X+W/++Lwo7qTC2ugBvm3CZ97GfgYaDNhL9+9ttywhhrUbWnA+/0DUAHsu8ybnTXaasIf89c
# DATA uQbas7Jgf5Ww9gXx+iwXcO26XnHKm8fWl9ZdVX2v+R0i/blccDakn1t2qYAiRFon6D3TYu0F9txc3NIz7PL4GU9o3jMJ2rinzBBJ
# DATA HX3DaDBW8g65J6q9VJMqdtUPiktWf5Bl1RLA8B7BL/iDaXHdu5bMgawQ7twgk/CnxXJJFlPThLDVkT0RxcCcG6C8iybuqhUFU0+B
# DATA w4EvTB3UBWZMBSUb0QZtYKZI7aC10guBNzIytR/gxh0TL413unGGAYqZDhZOBkTeF7zOZeOMofsjh7CsOAs8quKYfgqttPzlGef+
# DATA 9Nw59aicnDuna5iGmdPLznZ0gLLU1yXV12EP3fmP1ElBkgX81QR6cyXS3AijUhZMwAPYWSV5IkbOPH9AecUJZC+vEkTZUedh6fxa
# DATA tqRzH6B4FYPl875QJL51a3vnzdsb282t9e3td2/dvoYKfmrIC5KwCt/Z3riNsRLWoahfXrvivvJr8TAED6zjtLa8LD9qp9KN6d8Z
# DATA Jt3eq7164fzacnHtb9y+dXOnuXHzWvParRvrmxClnx6Nx8Nc1Q2kZlYk3Vq/uXHdFNNv/Cq371xpbt25cn3zqinsCFKTUS8vOatq
# DATA Vh621u6lGlym3np385rq2fqV6xuqdxtvrN+5DkujpIxJJxzIjY2d25tXzVy32sdd9CWRF7Bi0ZVdu5AFtb27ceWtW7feZoJovrWx
# DATA fg2rjdIFK+TVRoUARSZmLSm7W5QILhSSh63xuDPqY5zdj2HiR50qolB3YOdnGBxXr577durKbZIekj8vYy/A6Fi94bFR7h58Mtkz
# DATA 5Tl/X7OWBAxGKjvotQ7zOlY5I38t1v9KHXFUVQ0hu3oFX9nMAT5hZoBAD8ALaIIxsHOvIw549EMuxfzKjXPE/EeC8uqnRILfL6d3
# DATA R3f7AO/68pnc+hCXVOs1LoMXD2eDYt2nOWE5iZSNvA547PAHmRJZcnNMN8PWCRiu1eDA2lCFv8F4lXcuXqjuXbzAxjSZFoF9ooAi
# DATA x1E6kvyN68aT9l7mouTwu917LDCwI1bramc03uocw875yYPx1mRP8e23GZFe9cR6DT/VG/jlA+aS1+s7sO7k7OrYFkrmRTnZORnS
# DATA n8Gq2BP7CWj22M8RMYolxeIjTCBAmj8DIPcIEGMAGfYDdCj+8NlT1EmTehaRmp7G85oyZR68rAWb+inR2/Ru33Sonp4ycKui6ZeZ
# DATA hh+0umNCLEEGWpIQte5xZzAZ19dWTEixFSmAse6KHdxA9BEKIVSr1271lCSZRoFFwpOP9UdQ1zV8IhgP7s6xikGTpGtinx61rt0D
# DATA OKI7MxJ2YWi9Kpkvg1Ft/0i1VB2q9ddKLlNLACgBRLeSfM8p45nqv1dPVs+vrry2Ft2gv0enAvAieAR3PzfRTXSlHyVv7exsbVcM
# DATA jI4OeOtzynu7N8YIzLqsTuuAWaYk4a3A/65svLl5M7m6cXtn843Nq+s7G/i0eu51/FedpcG71MqtrarbdpgXNBMM+HfhcILB8JXV
# DATA 0paLPvfhUO4HXpbwPO9VtzZuNGHYzfFAHau38e8SdEIdvVlWlWThZqLw4IAvKcl3k1EumvyytN9CKxrcEKzpzJwaqgy/g4dJ8h7V
# DATA 987G7c03ftj8wasr31XHs5qy9evNq28picH5Up3j3ePJsZWKF77dub7N7vTw5/3V5hp7irfaiuaAiGHjVY8HaorB960EZyjvRTI5
# DATA HYEpJSj0PV2FhaUSIKt1x0dJDtq1sUyK6m0fTOzqhlBKV9deq66o/1tN9UlmGIEaT2kNwtIflqqrZd1cxe8KJMpt5YqXPoikBYcO
# DATA yAQ9GLWGTepNSZUmtVxn1BQ+UdfCFdSnGNdkVCToK5L0KYaKA7MadjojJJY9dUsfqbUcjI75INJUAwxMyK9WeK0yIPeEsfg++Mc5
# DATA aFdgX4RokH+W9CQ2cKVa8ApteISv/yDNCm4t1PW8A+y0VzpI39zYUSwM9tHyanUVBIK31NTUklOZoSk8u6qXUt2se+AuAJKD+v+Q
# DATA vw2P4ywrmr21lRVgY13U/VDzin3eL726uiZ6umx3tQF0dmFlpXiGLHZvn5y3tvnYtI/QTXAY8s9QuQIZIgbyynudzrBU5dsPLYPL
# DATA VuxExrwG7yPG9J8TC/3yC0qK+fzjy6JUo9CdjyXPMq5pOcqWMXH6HympDNhKUfirkKpRrPn4i/PglcwdJO+Cb4E6tmyT/dyLIMow
# DATA 6m2a4tkrdeiwa7y8H6SUgADggJIV3L0r6lKFx6Z8kU2B9Vy+27eK7tZqjcJyjrh7kKYp7czk9HTJqmLS7z6sLd9vjZbVvlvWSuzl
# DATA 0aS/jBNRhc0NVSaocm3CXXuwP+hdXjqlwU3lkq52PU6FIejLZCXJe037iI+0Nu55p3r0yyYI9gVfD0fd++q1+630NU+QTVfX+N/z
# DATA VAREpbVk0L+8ZA0Bb1d5Mjg4uMw2EHVMLk/y0bJiSqMOTcry0fi4R+9bk/EAvebMJx3YDk0EmrywciFZVv+pWh+02+ry1mqrpfhB
# DATA 5SqdzBWQRCu36EKqaDLvdw+UVN170DrJg69uA2DKqDOqbA3U9J+AZN3dH7MnX+XBUadf2R8N8pyfONX0BqQISX78j8nyQ5gA8JZZ
# DATA FqLAo6/XhWA9dUQ09wbtE5KOVi7r94ej4X6TxBU6VJLzKyu59x7Y3qz3wB3wL3XVn0WC2EUkQapgOnWHoUZx92619PpLDzq9XgVx
# DATA HZYzNRp1svVPwM/5cvAJDBZOVfJKSL49GXXxP8tJXS0Ullf/T+0XZgcHo05+VIq585S19VfsmfrUS/XhW0/V8FfSMm2furZvoLBO
# DATA PANL+5qmAmuo9xj5kWphFVtArVa/M26iAoIC4rgl8xQOTX6ITAM9NRVz6B1AEE4vtd9R9RcunJen3f7eYKKWll5cgjc2WJFdpyj+
# DATA Sk7d9gUjfhcGDM/HbN5nQft9cnJ/9nniCqB4LU6zpXkqcLdfdfeao3NeWisSdIzyIuARRBFuH+tgiohkbMLiPsG4VQYQ/Vq6a7qm
# DATA 9Ye7eALEIuRYX+EvaWQxw3AkCKWjJiiW7nxRChWUoH6RrG9tlp31AYxqdid5lPxg1DoxV+kvOIJOcqrAaW75hHQPfFqOgN0UQLv/
# DATA BgOdIN7wprovr1+7oa5LbkK6T1h++AjwsOFO/6EdT/UJrbSJYoihvWsXsSDANMDFLfI6K9Yr9QaHh+SPdpq21bGGbiEpaGgqnEY3
# DATA HQzFA+Q0VYy6AjwaCp1fQe0IPMKi6tGrKTNAiLsdCOAPAkjB60lfMcG8ko8HkK4FPubmIQCf/goUlDpC/9Q1fGsvY7bLtm2HmmlQ
# DATA zaTXPe6OqZ7+gPt7muaDA+jZ6sqFS6++dlF1SB27bfNgOp0u5ifVGg4leRkNnbm0JK2RpH3kymqWVFIlZ41yTEKG5crruwfmnlUT
# DATA LU0NOX38MwZlrO+yDbpCdyY69+CkM6Zp8m3Na8tqlZfVKJb5QUHN7Q4YGPPmoF+3TaftPZxNJca20XaE4EqMxaAEid746CSdOlZV
# DATA MonP/2ga7Qa9RmxE1Y+xojDwQUqv3rhW2X5r4zrmx9qH7FeVg3wbRS919MOh3INDE6ZudZnqQM9zTLKo5gR6sLqCVgsWJ5CoczII
# DATA K8kHfZ0u0sEyGjeH6qo/aNNeyG3zcMhTAqMtqCCH6h3llNlNNQNJG7EUSxHS0vaR2uql6sX0hYmMrpBHxyh81VN1gTveo9rEAqbm
# DATA eOdHMMw7O1dhHQ19SQ+NSGX5QMxobpEFHB42uznIfidJ5U7y7W+fOmamaVJpOw+vXZkGi3l+3lqurUztsA1FkwVzTTuGN07tu5VW
# DATA b9jtA3tcdK8VTQa0o84b63u8GkA3K5VcbRXM9Ya/yLoPIPOklaaniv8ed47VOleGKKLTu47aRripsAxIvdQv+O11jf9Bwdcvrigc
# DATA mfxrr71Gr4AjwV8rhQMqXlrjFFNRcj/Wly/QH8hP+hVX1vKds9iWKqWm1GFLyMisxEghw8J/nSClUHSuFSfyJZGv2CpY/CXe5EW/
# DATA 7b8IPDQin9ZFDABvkuA1OMNcWiknSsqeFvoisQA2O2eXbcKIyV2Uy05UJ2SlcGSmpyTmplEXlnzX9s0JXN0a8f0brlFIvSRp1AkG
# DATA Xn27K7IH0l6h010URzBybM3gzvb3wqlBmjug6BfnfWzfxcSEYIVBYliNbtv4of5ih/Ps3U9wjmrfh3ZtltMOOhC/9DIf2WY80Pdl
# DATA ZAD9Vo/P7pez6vhIXR5G9e+z7xbECo5Lo+rg3usrtdUsq+5jOFQp80qoV0X8y+Eyr87jMqtrEWFgzRUG+IQQiDWIevJQIXRSNsMg
# DATA DbfWApkbGQkXfIoEwzt+rWCv0NuCXUFva2vmNHMP/TdvXdu4cudNGNPxpDfugvpmvD+sr4AQwESXXlqpXQKFANzca3R7lz+XJ+3h
# DATA LCkgLrQG2+Mq9JLCGsC4XltWNLKMXV/Wr2qjgU4hXoH5rC3Df80zUrHWlt2kM17jEn12alWEYWpeNX7omvYXP6Uof+Oqn9jhbvIn
# DATA LDPjptek6amlAh+PWnjV1qsXWXBS5u4aYZF9yq0NHEG6cArhblz4CqNEWfBGZBUOHFgvLnKy6Ft3xF6t1TEXcR5jeQZxKLlByCKq
# DATA 1UvLSfCNumvmzkeDw+V8MoTVQffPWJdDpg1W42WYBxG8Yt1gjlfw9f5g1NF+xbHPEVPZKdWISzWoSII1jNFRw43niWie8Bggm4L1
# DATA PgsvLUK3DfE1DUaGZvPiJRn3ctirRWe7ZSIpYlr4trZaXbtk+FaMOJfOxmXIAAH722YzpIGHp9X2MtuDsRAynNmc7QWn5qy1zt8B
# DATA Z6zwwYMHUmHMFAF99NinxbLsBXxR/jj9OiKojJpsfgxVEEQVkkcEbwekNC/MCn75VfthVBgVE4mhoklkKYm9W2r2dvUrRhWDLqit
# DATA gwXKKmKmKXvGPzyhuXh4EnaXYrNqiehzU8wIYvUUcTx0JqgFVWTsZWPLpXdGIF374SczvSbPdPGyA8pPwwTJtYTME+4bGnsgPs/a
# DATA RAXJgokOIVFwFf5zoZRl0yzsoQ90I5x15j0nBmPljNd2t6q7Wn7SyItjVJ10wo7OPqMim6Sz90o5mvws5gRtB+kBUSj+4QSLCHYM
# DATA psMrg+Vs8MA3JbG9ZtBrA3d/4AUNcGYRR2AtYXWZ7Y8K4rWqwQnRQtWCndIA/KFhV/z9uztNx2E5xfxe1zbpL/TStf1s4W9xnwVY
# DATA ZdOklw9dlaNUPvIr8EUux5yJ4aEJalC/nBgEN1ImjC1Sw6YoiZfqMH/kGtk5yQrv9v9d5wR9+uzPHEWEibYxmBbSbEeChp7/ioAK
# DATA oGaKbFSkQVg/5G+7rzaBopNOu7RbOiZHQDA/QwgE/9ympD/mwTV1aez2cTdYT2+/m3JgNmaD4hjBG9gcJ2XNhGKa1AsknKbuEf1h
# DATA SId/W1QDfkbqTg9RaJK5CHYwWl0GeZVpjfsDid+u3tnead6+dQtXBFXo+uRVvbWySC1T3K2qHGGHUdtlkDnklYDMWuhh2B82bpqR
# DATA sYWK3kKcpx6nWV7zjDPblPgDqv5byS3JVjk+GnU6BiOxAmmMMAUUHsDc4nHrJNnrgGtAp11NNhBOReKYuEIsCRhsw9Zet9cdn9Al
# DATA sSwuymhvJEFNsQrUgwGfRVCH8YA5RTcXaEUDlUBr9FWjQqP4CTLV0hj0McJoZgaLA03C0GEl8Gg0U58F+1KXtFZTKoBoG7A2Iu2Z
# DATA p+cbgscL51UkrsoP07ObgnwwTD/x1GIL1ke5ucQGSVWvemLgqNNrMRwaFTc7oCrvmuMBbSiJcLdxF+BQ9z/s5s2Fvg0TJ+vgAe4V
# DATA rC0Ym+VBlZIjgbSyhi9fKK2bWxu4lnJdzuNVTP4RX4FdWahGuBbhLsZfmm4tKiJGH/CBGHtH8IWPyRj9OSpxQ8Yeybupruu0fW+w
# DATA Hg8kgyuKWAFnCX5fbQ3X223+69poMMRCo+59JVaDibbhnMTeuW8iCNGRI6zLR0FvDe2DRsIIa8kpOui2hpmShdSlHonPTu11dV0d
# DATA +Bz23UKMjpIXxA/OkgGj0dGq6qxx4wlhEaA3dOBwv+Afc9jgL+uoicR8yoiZT0pFdV198p6SLIzCZLo4J7CbwKksbqNy5jZ0Zs65
# DATA c6co1OLkxQWjzh+hfGIqqGlAcfCrjO8yuElivWnBNbmGV2lQ9vKNOY2ociBqzFL5RAuGShvEwLN+l5emEhwISVdN9tcYkoWf/HVx
# DATA hxABBpf3Li64qcavZxYquIsLFI1VmIsR7vsnsVaydEYojWxx/CgbDaMYhHTueClTsQWRoVFgyJMHInae/4zx6JmP0kOYgS+f/8ph
# DATA rejtWU9sNUMpjZ85QN72RbJ61HnoZPA9nYnrMkc7Ah3h5/BnZue0FGSXA52zqayZdEGu0iDmD/HKSJSjs86Vmbxlt2V6k0UKw8rh
# DATA TeSSYKVRtW52BaXBnI7areXU9UOTXoYwDWqZIIhBCpThulPncwdbqaFcQce40xjEmcj1hRM6FF7A/tXdNQHVWNRGNleO2cP04zG/
# DATA MvXqQ/eaxplXZ4M8aEmPvJFxtQP4Ryt/L6G8fNWksPTDSQpLf1gqEze/qqlYVyQEauqwqp66CTNVXYoH7/fAOfim5GHdaY02+wcD
# DATA gGFF9Ef+LZwX0hqi8qOjpK7OuAX2oRJ4nJYTiJuC7AVWMM1gjLjdqiOtseoGl1C9a+o9rmshUFE1KytAm1BlFdxxHHWXPATEdsB5
# DATA PbeGhI/NqEcXk3PyPHaAwhj5Ssc9SaRxjLrotHO8Deatg06C3nKWkp6/qBb2HMKQoCNLZqLA4tocqn1TNEE4oHA+paCfTRAtNIr1
# DATA mYp1Sa/Rw/4EUmF/Mw1L5UWN50rgh1QjBW1zyCcWYhw5AiIdQztD1JXgld4s13H3cMScjqUGVBXvj+208dxSiXIHmcw5sDpNXM76
# DATA miaQ82VCbuAXqyvqf9zHl19++QpMTEIBAKRq6A0OETQeiYUzmgAKJiKd9tXdHQgHfdcB6PI+dFp1o1NVlS2FObptLiSbZB8Pg3qy
# DATA sqSjvmQPQgajEvw12PtJXYZHhp7Re5RXu6v2aN3fxBgExtPi3dY76AcDVw7/NfE46Msr9WTVCzKizLx0AcYqCCyVrnghRsoEE+ZY
# DATA Ew3bNfxaCWWtPSW2TcYdkszSajUlrNjROC86Lu70caP2w12NYLIamwO7kWbRM4160c1JJhTXdP2YkQz1hKlHTNzZjF5pIu7HGA7U
# DATA E/aG66fY2GTFapL5naFidUFBminqgcXmAq6mN1KCPsxuN9rm2AZmRuLETwbdPiYZOEe6gtg0Wh/6ygqm9AX6KjNEUAiKAyhSa9sy
# DATA TsGU8eJFEYOtKYzH38ma6TBaI4pKtL7LibiXkTBEexKO70GfcIeuDF5bWYFgEUDSyTkcBAG9m4N7VrLQuZdY4hNqT1qDKlq+KjX3
# DATA VfoBx+3RZNztVdvd/F5zkkMKN17N6gGoS7/nUOgrycULRcevmelNtTsODrr7EPMEOL73kMkqMesY2ZK/oW2+H1XFyanMxwHuV+pV
# DATA OBr6JkiyOpcgJYJcfXms9j/4YrqVfwsglHuTHAtDiDBsIEbJVjQ8IdOW7H0LKVsOEDJbxcKOoctlZ2XxLEgf7qXI3AeT8XASyUVm
# DATA f7F/pAighOtv7QmNDr+6ukqaQwSfD4mR9NR0dykiPRNkrUvH99teD8IbLeVoq12CIGn9WTm5+Oqr5y8WR90Cv8Fa5oUcR1bygZqx
# DATA 8WjSh9VoF0QS04xWGQgfGoqXM9NSocRXBWW5vgNFH0cRyPBBXj3IT/r7JSmnJrE/KLlWRTzBtDVxeBKTeix1iZCNw3vV3+SeQIoC
# DATA dAsbppaaBd0dEHKbNgrcD6voqshuDOw/SMZqcSbcQnqEysFS1Iagd/vt5tYGPu+MRv5zln66xxiWAxaYFmhRqzvwpLQKnrhS/F63
# DATA 17OKV9utDsXWANuynuPVVwBIICpUFdH6cCeyPwjznyFPSi9oeOXgCunDqMO+BBKcjDwuI13il0seGJseaslO+GO3XcUQdet1u9s6
# DATA 7A/UVt+HZbEKq6Zoc61ePH/pgp+ooUxdyZX42FG3wH038ZRTid+i9mORcgCFUrKAT4yjHfFK8LW7Opj02gwbrUQsFJWBWaCMZ48B
# DATA IQOZTztv7FsgTaOfnxHlNmoyBlBz1U5cxlkZr7b6eOlQh07vBDeWdfZcNnnVzBaRpBBtUJ5jUgWoKbwtaUIHnNheR3GbLXrAO0Xc
# DATA BMAXxRqlAHSrRns2sSJx7wPOj00b5BKJzQwHQDXxs62AsuxXwRoSq8n7rWF+NLA3RQmUBqr/k769ndXPMjEmLFQv4FF26OrYU2VE
# DATA 0W++lawnHConZHHcuqfui3RgQowemFZ7JLohVEW3Q1T004kSlyBrSKc7BGsx17c/OOogAqOMrZrcVnMHHsbJvU5nmLsZ9czKU8IM
# DATA xYYHE0DDrErCdI2+ouagZDNXfgdxwjxQUU42IH8DuoeTEKbEXTXiTpNOAH4IaB/yp7e5TKccICndGWYWmZXEzdMvbrYJfijoWWLn
# DATA ZWaLL0y1rYG+Pen3UQaKpBaitHafgHqO/kTwCEytE9PmfemoxTkfmo2KjumESOf3UVEwKA1iRnJQVjJbhVHb29CqcfgZYBjhQxaj
# DATA jRfDS7aympGOXsxmCtV7pp6zJR715vjRLH2ppW6P3An0LcDyvcAUTZD0qNsv3KmunAGAqpgwiHWRispxyukhqyMbrvsa7emZxnmj
# DATA 2YbJZ4VsgRWZ6msU5XKMz+pfEN/74wWmz+hxgkm000iraWozcLrFNJ19FshorhYeaqgSH4Rju+bdNq4Rk8nNlbnfpqyf6kYFF4pJ
# DATA F/IiKT6YtPZy4Ha9zmELoSsErdBUZsgZDzQSrZYh6g0OU/Un3tJYZMmryU3II5TkD9B0jdyyhwCDVf++NePU12YoHChJGhiT5dCD
# DATA 87rQZvBvlNnkE9oXZNS3bVBPo4srScwI5+8vDHnwhaT2iOZPQagEyqrwa42/VazB8/Me7Yo+8hzT0OiwN9grpefSzKNY0OVxJs5q
# DATA j3DTYumSorBrOtuutnK66XezWRPJVhUB3IMclo8AFJtgISCp5V80DBvY/h6H8/o0tmlmqBS1VgMGrdHhrBGyCo5uqEUaRlTf2qYA
# DATA S9FbOODfFZKEUMTj5794/nNBpYpi0gGNIVGgb6DLkL0JwAF5d/FgsWQWZt7O9ymddh8A2UoxHjuDeyNAs8Om0Stinvk+s2GwceJH
# DATA JHaX8C8J5/DTKnqeuTqPaOQbZ8+QTAd3Kdg4jK5oISmCcqU7mORp5jweUVbkk2BHEYoZYetLzbYBnd7HdcT0bkFPE4ZLwz1f51/c
# DATA ZUgciJZXV2mHYGpeWcJji5TmLnkShxYtLl6Y4oUCqpy90b2TEFNfCN9DjC+CXKGMGIq9fk5OUnayeQFkUbvnE3gUdtWZDCAyiKVA
# DATA DIJl9Wr54ah1wpkhZFFo+MeEjwmf7E367R4gWyzs6GM3+tJ8ykbkY5qxwgn7jTfqJzJmSu3L0upTyTxAeYDtQwjyEqgJ5GzAjhiH
# DATA GYG9xFt+8mg/cRdW9URnNUCUWs4+63cwTj+yAZlSLDarNoWdIdItR9LvzKmKnMY2aJx9GsvcWMnrf095dgEtzoP8NDS2pP3+csoF
# DATA CIsMoTBW2sL1BNVtSgxDgUNdi7u23hkc75Lh4AFc6wZ5DimTMadca0RWh37ngVUZ3QEsF6IEkXLzI5RoHhxB0gW5TYplsNU/SVi1
# DATA Aj60VUthQ7V0CUnIwrYCyVbJBnh+O3IDCu1GVgiODcuFw/6Mfc6tBh2nDYQaIqcN/JM9QUE1AeCbjDpc8w0MGIKBSiw1/aj64/R/
# DATA efVW8/a1Wzev/zB5j36JYK4f3Lz1xq3r12+965LkOMZbtVbUNOl+FehIrC9JZWV/yaC9oNJtqou8uhwLYi/nM6oFF8Wv5OzO9nCd
# DATA rLwYZdf75rjFST7S21Jx8v+9/1uUMyTpmZ2vJLHTzgsGoUSkoqa2I8IjHas6h0+xC1iVUKhKnn+3iBN+SocmgyTt+sDQhIpFl0Lr
# DATA CMy8FBHwuoxRjizkwQOfaRG1LsWyccrkEh5XIeZAXm21KVSTNojZRJblGdt3ksxbKXIht5GbgJ7iew33rC0Vtxr7kvGn1JUQmQEt
# DATA vqIsTOD4Oa42+tA9/1ByYSL9uDljn/2PGXkJTQ5NO6uuF+6G0Tl4pZS0VpA56NxumuDXAUOyuyHxgo1GrFZAfdWH05/I7xFy8rwv
# DATA iG3olzW7MWJjekKzhpOGUD83c0/z+QqYOhI7kAGuKyiYm1RCnyd+QuhnTy57sHN4EMF6ySXQSz7ICYeqbCSxWocZwA9xB3+A4/4F
# DATA YLdZJ1s1Eaw7PCVVqc8x6dj7pM8RTJFHBUkPFQPPk0qvFeZIIMfNv6iCvydQep0nsYpZPHT67w+cDIIY6oQAJOwQ/xjJifITirvd
# DATA s6fVsMGUaNFOBs7fYDJwrhSmFinUUCardDTKQ5ih4dn/bRBk1eXM9abFNIiqyrBCinEPa4NOPiGy9D1zFXGG9Yw6h+o2A9eD+KBp
# DATA t0IV6upYS/bb0U2nHiakHZbsUckQIwbQlMi8HrbWJJdUlhhIGt/4jUhkggGJKEcAVTSORkWyh1THD8c6wxeFfZclQrtMQdVlnsUy
# DATA 39XgD4iNdqMYXOZGLj3xlOW4O+wcTWh0jMyX1JNp17IhCV0sb7BNfl6S+FKhnsTkMo+nAnfcaJEx+6oTyWf8O0hcTPkBSQDHDf7G
# DATA 5vWNbZjhQNi18hqH+dc9LGg7bbQM2QAdq9lwjxXdKKwTYFiD804JJz3jpBx8liGC7uwz5/kvysB1fmYSND+107HGGXmaGso0NIzk
# DATA SdHQAoHjGHz2KXdPsOHAHdzUogbg6wowtgm+tq4wYgw0L/Tie4ZBbKYzQm0t6iXoE+/KhFP1iiTqlZ7QKpoqHLGuKFJa7XX0cX4f
# DATA caNs2c0QBQozBfVm7iJnRe3gcSpneeKmkdJgpaYNHURgznMKJ234ctj83hXLROGEwnT8u0tFcKQtPBOMr+Jp2TAhnT84mx3eKHAq
# DATA Qg5y2JnX49/R8Yw0/08R+K8aCzKHnYVoYjZdWDhj3sQEDSxKHD6BBE1EaIUa8yQ+s9N5BxtxLTg7l4P4fXU0V/lSy7s6262dX3NP
# DATA lrl7ONAC8fpHtzMvMFHEpC/hvu10XqUWAQTjOMNyL0Lv8WUlSo/VudBWN6Mu3OTWEC3IrWWUXW0Z7i+kwfLPio8Yf/h91E7h0BL8
# DATA 6Ilkhn/2NJQZpZXvhTV+f5lsVgw3VTm3zGI00CkI0p5sGc1G/+xpGbRRWndHX0E+ICub+5OoVi7sLAhCPB9/XEAeJZQ0pn65xM8S
# DATA PNOyjpDX0/6I0yaAiMEl/6yjqhyk5FDM/Z114XjCN5jHqm+YbTyBgWOHPuUrBN5EzCzxhVBM9JJFXNt8PO2dEhMklPb5z+QuxKZ1
# DATA VBtqOcVKh8UyjPCKuPSChGmkF1LlIEwT71r0xx6hL+gh/l1dHx1OoKktfKM1QWrH1ptNJYM3m5n1JVzRmy3+pJQOhp2RhEntHw1A
# DATA L1JnTB/M9ZRiKFmOhgZOhEspuBFWBmScCovb+I39t86pi3ECKSP5tEaCeofpvuDvQ8K9I/6VIiZzflSh3YJlMcGO9cDhSoAeEzxk
# DATA 1M3gOfcP/VEqk6E6GSmuGRCnumMB+6He5GNQnFuPBLWvwpgGOAW9Vt/ye8AGWTvqPRZnKttLYsTOOLommlFoqMIdsCer4DV3Pv5S
# DATA xkFvncnAZBR6uQyKA96DUG8oDgxR0qlU2KaWXS4qwCa64gLiNjSzGXMRtGnUE7CL2zCny8xWBDFqRmcpoW/he1rq4vdMSgSePrMv
# DATA mDF5Rk0jdkqCyMzRYV4HTfnMsSnamtUxSnxrVqOwpKVg0qs/q2GzUzhWsJ7O6SmSqfqsImkuW2gqq6dIxk1MkTm7ScQjG3z1OgAc
# DATA qXJMwAeG7IrSTTSsIZoyC7bCIMu6Asx8cXnmdwzKFHxKWTNmNUu80V2Swrb86hGEfjZTiDDnBRff+ZR222K9dMXUoMurK3O3Pp5U
# DATA ZpV1nnjUrzAeta6R3s5f2zPNNGCGF7/lFHHcKHu3c1n8B0rnBgYAflX14a5zgPChbqQSP7Uj3iTwY+RmmcCOxavkU6LmanDE6OTX
# DATA VU6sJxSiO7t6/1yqeVHJcvOxa/TBMtFRKQhh9ru268D6WZqATr+110OVCWQhXQxnBNFMDKSGoqL169dd/BHHrCR5AfCCgio75/XQ
# DATA wKmgz7OOArCXGoDIYMqovybtDPc/ihbshHA7ndCIdGYUBenl4bM2AIxgUgMY3axRtgkhhuP8F5tNMHjHciUYhaG1/NrE6UYi6EV0
# DATA 5o5VmieKIigdOpUi2MT+IJ1NnLaQaqaXHjThZYfc36sGeWFmfb4keSZiZ1CIInARPtib6qCi7/lBVk5iXVxwaq0i4uwHHZg9zJh0
# DATA bPlNRXzwz8g0ZsrZ1nWMi9mO+1LMHfZZFtG9WFjpYvIc8pLyC0n4mYdjc3gkc038wZ+U9Xafj7JtapLl1uyCHxCtl+bMqHc5sgkT
# DATA XjT5hdVp7mV8BosGNLsT/n3MVqiTWOd04yybLnJx8je0mN2Ldou9/ygRDCIlcHWLLTM+4ea0tyADLZHKsOyp6s2mNp+ZeAb3U173
# DATA MBOC6QjeOrIIt+D7QdNwDfORdSNoOvszcAieNbRyMm8EnosjuXl2+8PJ2EEGQaeLmrE3gZBO7oU1x9ULX06jvIxifgwnm8Hq0Mvd
# DATA QpcvIrNZF3gn5RqWWoiCFtqyM5vj3bsYuVqUutA2LVQ3hPuWOuDg72JRqxu4GGVrC3K/5pg0VXXzeJurW7LWgpI60/MzsRStLavN
# DATA oh4pVZp3NFuI11E2ylwP7U9zxhror2b3kEs3ufSsnoY8BH/wl3O6ZVSKvshTBgh6RJqRIjHSPOsMcnoDv8/6bMSfcjIK5QfI0zN5
# DATA gy8pOe7g1la6HAeEhtuGGvjluO8RCNragGI1a4NjNqJynOVYPudY1IrdmSRCO1cVK83amVrIJExz+kE4seHcgsJgDr2ECoaaL9Jr
# DATA dXqIMx5v0ulidpYOiKZ5wT5IOqivuxtz18ppa+6Saea5wAV9btMoYUOTxV6mFOGGaLsUB2CRySJ9YIB7swbzBLbuMSbByk9MrLX6
# DATA u0oONH0Q1ksrFhh0E/lrs2ntMY6WzII6NbK64zQ0XKa8DTOsu1bAwiIoixBo+hl6sWFGrTAOSXdEcmfij9KwLJk/HGLTn5muUtif
# DATA i5py2Xqvw3tefdVnh6qM42jlpD0P2YGLRq9Z8ZzcuhoBeA6JkAEqPF2ELVMS5oWOW53Gwj5KZrI3yrlgjccpWMQCIvnLIi/sZtz0
# DATA k2XU/phG+wP7XWRyowthP3SyAPhJHr7KCeVWsQEgVlsQ3kmJIuZUs8ApfPnFzkAxVjoCc5DZIBA+FhZLRGOn7RQVhFp3sCnE5U47
# DATA rKKX2l90VmTwUZsF6Rzgk2r+MO+mktYCFSOnEIoxj6CsnXPI+SCabEi+AtKqUcJDw/3DUrQFa276Y/tVFlOP1pLuUM3wCBAcukMt
# DATA 1Wp1Cme6t6PCiyYJkSaXfM//QKcsVTugo1YsAH5YRgT5EDa+KAbAFy7U/rjPebnhlk1xARZai5MwxNRgxQ8UX+XQHl+bK8UuFeRf
# DATA EZtFzVP4pGTaqVk8dBouGds4beSTWiyXCpdbDyRoq5L50vDSkmq3iaTUbOLwm00g0maTJ8AJ3CGHjCULDicEXAFcHMRLqc0SOmSP
# DATA //vzn6vN+3tyfi/w7pnrCo7NKf6CCdpAnKFgcgvOBsFhtk/yced4g/Ii2oMovQNUgb0vJ293TvgvyN/Bf97a5j8QiePvt2/dvIZQ
# DATA O/g0s4PSNlE1g1kkuv393qQtSGeYGiKvJX2MrMfxJ6POTwhYhLPOQ1zepNdLoIHqNzx91eTZf5iQvecfEywHwyToyIGyi9TxCwp5
# DATA tPgyBRG4+VOe/wIQpc60Gn/zv+b/1C7b68HJqbZRdXjyjbQBQfEXL1zAf9X//H9XLp4/r//G56urK6sX/iZZ+WtMwAQc7FXzf/O/
# DATA 5/9efvll2EiKO5IpV0L/MNRO8tCQ0q0LmIGjTq/TygHliCJMV6tr1e+uVZeWdo7Ah9cu+NOJEtGT8ZE6JxBNjgNEEAO0ewhpbY46
# DATA vSHGoRwB+wCcQvV2MDk8WsJC+kKR7FzdqhCI6kGnBSBFaEaFGFnTR07fnRy17ndU7zrgWQ5Wy3ZV9a0zwvDbtjpS9+AoBaCt/kCb
# DATA ovftQwIRWx929icU+A/AWSBREojhEgDpzjuSAv6R7swbz5E6lOxOp38ljuPE5+z/JP9P2P+vXXx11d//ayvn/2v//zX+l07yDgvY
# DATA 6eWlJbUR8nFymmyNuvlx62qvixdu+pVMMaABt3Up/bshPlzexzJpdpm//cmDsV0MxJEHnT0yMWS6he2rt7YwEcgtTDqFQK7/0Cnt
# DATA UhKPHHdOTeDAfWfRvAaYb0o4lRzAnPsj8Inn93mNHVmLC4Cor6ppQA8PJn1C5hh1JjmcjqXR4EHGKUskv97gQfK3fwv/VDmjixMr
# DATA bTeEXu+pKm30OPBZ5+FQTdD6GD/tg0z13nuJ8+L7mG3vGojsWRZ8n++rS0FeVXz1EGEt6jyn8uS99xyZfKFvXklWZVRclCXE3I1c
# DATA wfnM3E5xTSA7npTw66T+/WhV+DtTMz1dWmpBdH2iZ1xdE+934S5SIuoqY6oNSVsmawBau5eWf7y7Uvluq3LQOL00rei/L0wrF/SP
# DATA 8+rFpe+29hrOE/l7dW367eUqJEbHzJAw/5CPwpo4SJMwOJCkaS+RlgvyTqRQmB7L3H0vOb+WAXyoogxYN8Z23OzjxV3OKTpg1Hdt
# DATA tWm6LcigclnA9BTdEC3NpiS7vDjBwa0KHMYSmrZqa9jF5Jd5FSCv7vS7P52oe1/yAM7BmtreON5pMuXGl5eT2518otrGpEBJCw/s
# DATA Ct7JBHKrLI4Z0BzS6AkewgAx0cWIQNXDVg9wGwb7fI4eJKPu4dE4r+pl0x1WZPaS3l/yNJMVxsn3p5KdwBLkJcn+Uat/2GlfFmsl
# DATA SgOKfsZ0X7EDrsmtl4ZKKVR6ajmh9rqZQbWgBVOIUMowfZjM3Ooh0SasWTmRXVszmxb+U+0PHpQgamB1JTmXnL/4qvrvpYsX8JwD
# DATA zCDcGrVkt1qt0gbigB1nbXZAhBr02snhqKWGQ/ez/cFIjXw4gMQJkLMPQNYmSmxS64CwwhqMrarWFkQKqW1AyQZbQD2tfY3JhsCz
# DATA ziKDDNZFOh3TUuMYWQyKLaj8vRDzsOaRVqJg9kVpQbR7CnM+LeNKnPLsWZM3nTrLzMxaHUlVkDhLp7xk6swbwbLVkPEC5kkPgpbW
# DATA tzat+JVuSy3mDTA7HPQGgxEyUCKF9jomswGAYEwouYqLqT9U3Sng8K8npwBo1wI1dg0QoDvTRBGUKhi0JB+HDU2zZFq2nCmBCZXV
# DATA nm71Dgdqwx4dq5G8tQ2OFUhDM5jsG4PRJrGlKLsFRNB+G5WONucNHsqG2u+1usf5ZRvbWHWLngJEqFoFMt6bKkxTp7r7sB14AA01
# DATA ALUV9gFfSlW1fC5ZT9rdgwOCTkXFOkJkKpZzT1G8YauQ6SVXbAz2opBwNTm3nEwd0w/3TZEu/YUWZjrLgRbgBR8B/B75Zt0+B6wT
# DATA EPfX13kqWY06+8Xw/5k7x2b9wvmhrpo9Gr1j7HlxBJ9M5+kJDmerHn1Gm9qm4U6cc74jtVIHUHysUjoyzDfVnqilUUxasH5bo8P7
# DATA lMuxDtDgMj80L1Q74KypfaPEkFOXKCMzOSDJEoC6Mdd2iWTe16tU1TukIn29SuLu69V82IN7XTUFeNvk9dchW9D368lrsMcD3bCS
# DATA YodjyIcI9FjSsjEi97SGw2XUvdMQ82URrPmjyvAwzarUm63DrHQa9S5Ug+gTdNk2EmZNz5M6CKt2DuQyJNCqJWvlOfXsENrvjW5P
# DATA ycY1xXqaK4DR2m33Ot6r8/QqqG8KXIkSxtPIVeulom5l1bwDMKJbrVFLkRQFS1Oy+QymN8UovX3gaW5LwEEhe5CidiUNREAMsGn7
# DATA PlPitbZJVXiMCwnlSyDX2PNGCTxdYDPdfyBBB0QkEEWIvSVOyulwQ2QlfjaLEdvzZKzx23eubF+9vbm1s3nrZnPn1tsbN5t37mxe
# DATA c4tDFm2y2JcDNPUZ1d3euKO6jJUaTWgVJIoSSVxqH3kw8KS0p7ccGGl9ilMqGxC3meKu1Q5NZRFe6rNP4RGis4ExXUe4/7OFaYGW
# DATA tc8w66GJGQ/i3+Pq418/+y0a5+LIbz5aSRUDP2TuHnbHV9HanayqY8kaKaOA8ViZEX8bPclwO5XotkM7HI72AeUvOjUkUI5RQ1nu
# DATA ydPLS38F/U/T7P6vVRU8W/+z+urFC77+9/zaa/+l//lr6X+3UI4yay/urphCAtSsat/ijSJQnzi3rE5b3cAwzxibg4BTXrwgv0AR
# DATA JH8P8iUEeQannl53T+xH4E4gRUYd+QvsgPpvjfUvT8ad4yHc76jCyUgdSXsUdyW1gu8GHNZLumpKLcsh3ORbhW6t6HpMGtyD9iLQ
# DATA goIkaH7fvHL91tW3M5M6DRAE25Q3rQ1Bv5wvh5KnWQZIglpGvEEAWqb3XhYWC28MClW3m5vbtzfeLNlgvQ56r6QohNwbsWQUxqpY
# DATA SjdvvrN+ffManyoQA+/i23gwlwRrJA2BWMxo2acrOFXqAO+op6VsGoUTXnnttWxej0xPmjfgtLqy0dy6vfnO+s6Gg3mNRxNPqMk1
# DATA 8qqfa0R7zi05Ht208vhfJ9UNPmESiRZ2ckhYvgP4Fn0WcCl6+oNwIeYsgoDlE7lWAz9B7rSQMTneEHyn3P21s0thd01J6TEFpzGQ
# DATA O49AfsMg1lYuXMLceHfvYt4UuyyE4g1G7dJ+Bvqw8/CIfyopfXXtNYpBs7/KFpmOrfWbG9dJmlqiVOzoImJn1cEwMe4I3Ahak/Eg
# DATA 4iEhk0m4LD44DN4ofWwnO80Fz2bp9Nw59lKQ2EUMbUC3BydecRrsXFMdz/UL5LmIz5biPOvXZa5urr+zvnl9/YqzjXnecgq9tFvl
# DATA bPLbnfGYM8jr9vmVzvXs16YRwJE92FBwujnJe84sooSJuxHeZdRtYyxx2ge/wcyB98Y2SCHq97Z13CFvVMClh10NKYT9mZb+xdJj
# DATA pLvrlR+1Kv8AcNXmz2a10lD8SxHqNCXF3pkm/ebGzru3br9dMPmGPJMUQnpry8uSKt2kvAK4PyZR9LaSH7Znm54MXiCQ97du3Ub/
# DATA XIoC116XtouR1b7+E9IjYD/sfUxhlhh1zH2UV1iXOk9VFXKqGtYg21C9qeLNzV5vVRnih2CQs2YzUBRIAedAPYPfopuT34ISKL9/
# DATA OulQyhP4cTBqHaLwoQurI1e3iui41Bq+hMNf8YaVF2E57sBeqstYdDwvU9usut/a2dna5ppvb/wfdzZvb1xLnVNH62xHhqzLUrXi
# DATA 9Fu3b13ZADamxCzSW0huWHWZWJ+MjwYjvpPWkvSKulArNoOwUP717931dzaa61ubdNKo6wV6QkdL6ZlgKMJ3AYpQUzApprgXu+kP
# DATA Kur28qA1anfa8Bf6e6VqP1VX1P+tppfjJbdGA8WtG4meVbgteVpLIHUU0KA9GntrD1cUb+jr8PdVgi3qQcxyWad0y0mDCoHvdEHD
# DATA 76r4Xyh3CbSq6kYuqiFWraFyPe9o/dpBBxjHnDli6FjFPnmgAGRNrsq1FK++iihBF93q1agb9IO0cGjYkoarg3tiT2L6oeCP1j50
# DATA gPQKoHYFIa++AhgJk/69vL7bgBfAhqnbJRoOvkWLjFS/N2ifqMmEz1+p42s2ZV3uHpTg6fcvnMPUFfCf7NSZtMuRfknFqmdT6kt1
# DATA CLkGr0xAYVsF+byEz9VleKqnGf3K6uhORgltubh6u6/kYKooq44HpNdCaU4Jc2a6yMnzvfdEU4u/X6rX0wFaltFSR4Wqekm90vqF
# DATA 9Vl06q0hLuk961ahXkwFFTw53e+pPSjEh/QIY58ulZC4S1n9+5qYxdhdp2VDzr7cGnaXyRi+rI3h2WU18BL3X56KDyeMgFXTWWQA
# DATA GqzisjTLBvCw1SJTufWtqj6vr49GrZNqN8d/Oa49z14Xwzr/W+V/1beq8y+5H0E9Way7dpPqMyi3u9J4nTTiC/d4OX0FYxA7d25v
# DATA XpUoAqmMteuK4WSlTKus1Lr4+ipLl0TOjBbqmcYpfgSwZFo7BaW+IJ9FAp7+hJ5GNVN4OJQTVQahziDXAiVwIV2YaQARmW3sR8wT
# DATA 4+m+1JT5aqv66mXgMui/hFcGVWCvU+IQBnMP4AsMHzqKr1CMcVkcrFgkKr5BhZcMbsO+YeCjWYfl1vqbG83NG/DfUJ6irOR89a/u
# DATA dOBi3xqdXJOYkBJBVUBeSUmBhhSBQ67QFfxg0FMM2sFKl9gkepVxzLOoxCCcynSYBTNSgSKUdRo5D+q2+EQ60sj5i6UcNWpMZC/x
# DATA SjgZY15EcA9SHaAtLFJ58V2Erv++lM1/WqI/FeS6TdK/WBoVJC6TurCBGD+dfcz8CqFsFYaURn/q/v1MU+YuVNkQvDEoDv9FUclD
# DATA Gwlc7rFlcFzsoxhhjURdaNTCjkp6IOa2ki3WecatrlQIkq9SGarbB151OgzZZ6NwUS+KoSOK5gCfqwVFAkvNJPCWi86FOJVrn3Hb
# DATA u9xKp7mt//S9yIu2LFD9+tWrG9vbzTfUjgXxltK54T2d2A7oCQ3+CWZdKGI+3KJiWbfprFXfK37caYOO/T4mluc5Ie3j5SQ/ao3I
# DATA +yOh1BOKA51Y6TKB+1ke65R8B24QSyapXhyYiJNVuUBE7BWvhO/Y5k9r1sjSyL5XBXDA0yXJIgF1mU4By8EMQnlJQqeoGzYuK37L
# DATA 4yYwJAF2iFY0GB8B0HZBPW4uHb7LlxP8yKTrsCemCjUBzrlc8l/S+Rdlrhy0CewFI3QRNsdpikulJuN0Ol3SOd9hQDUv3+Fual2E
# DATA 8cJweu6csGIJuLfvypziTpKE6E9B03DuHC3fNHJZtqZOfIPdigmL4jRFhynVdSHoFMaufsM/03ISkE2ZacYclf69UT2ze83vm5SM
# DATA av4WVOel6CFuQOzunZvbd7ZAPaDvmqEmCDKw2JBT8pZYv/4IA+Niyp6ygfiVT22yCCOrKM0KHA0kPdNIQauDmkLZ/oiSaQ5wgJV0
# DATA tDzQIVvPpA8lq0V5uQvxXtKyOazoudOBl+oe/1lwuq/euvnG9c2rO5FptmcXQ9pO1dk2BkVHT9EKpdel5mvyjTXvrfG4BdwL8BZC
# DATA ykD85JRr9xKbWvMglfAUuCOTl2E/p7Mi1qyOgQNtCWrGi576Ni/tnjNtwiRnWbCb9RAwLoxLOw4jiOVC/KHh5E9Chl/CN2XxAeQQ
# DATA wdqSy700cVIqHKZMi7eotYDMd2ivqu5dvMCWA/xuN6VIB0iS5FkUCBmcvA9RacYfEE9oFMiK1Cdosywf4N5uBNVxqsW/mv8/h39+
# DATA 7WFAs+2/a2sXXrvg2X/XLvyX//9fzf67fdLfV3fvPhgLITiFPG1cz2PKRA57qGXnqyAXPAOqjfIVCnyYJeTh2LLu8hPOdyjG2IP9
# DATA /rgnPwCcT30hP3VY8NdqQ4YL/4tYi9/e+CEoKLfvXGlu3bmiGH3z2q0b65s306X17e3NN2/e2Li5g5EPKIhA0olR+uPS6zVy99hN
# DATA 7o4br2SvB5/ji3P16rlvQzbuTvUGWPT2e608T67hdqSjxpw6Gm5czQsxxP5gdAzOSMyxCm19fPja13BijWzlo6+T7yevrq6RXyU7
# DATA ZUFuz7v53bvfef1bdx+urFTuPlw9uPvwtYNGyiwssOLZXU9poE1WrfPx6JkRmEdb9gh6EhojrADpQqX8grYERgUhcwFcUcrJhQvn
# DATA o+aJsw8QvqQR6kqqpIcqpd12v5Xq8ySr9iAJJJumndu5ExnPf5agOic82BCHBbQC9BEe24v2HlQCQBPYFlh9X0VrblrVWbNxfOoR
# DATA /KsG1qYcReASCfnGML2q+QsNfl6OIVBR93olL4ms2jErD8Ub9pX34C+1b1LANBqNM75KjHQPLEfMoHYE2ghb2GW7n2qJ/0Sr38XV
# DATA qbzJXl+ovReges4UKLaq3VpltSFkTGmjZCLRcoXUL+9kXXriqgLLcmGFlqWayuUKftMV0GQgcsa/zANfr/xIDbba/MdK4xX1aNl/
# DATA lp2jaYfkUGcfKQtwSCVkFLEcbsSlZkhBI47cZidTxMZtbhZJliipxTX0CDACeLJIn9XtaP0NuLLvvJVGtt/X4QbEexQQWG4Oxm8A
# DATA VIu3VcG7hmeiFnNg1U4OeizfqH9R6ewORitrFzjRuf22D1hKsBqrYXpUU+rsvkNra9GL2WLri3ncWuOW7zNkDeGVZDWzNxsUz9xh
# DATA vhht8XpCfWoz/J0nEcHm6IH+kDxT3O0gvipVHfAMjPVeOsdb7d3bQpRXb2+s78yj2LKd3j1GX61XCugr4pZWSGyalL7aKgZqbJQl
# DATA IYZm/x63WeZnMLbmxg/UcK3fN68EKtEr8G23f7h5y9uiBf27s3VtfWejeeXO9g8dTad8ctLt9NrM93i17bUVryTE7ACXpLyExDjT
# DATA MUmTppVw3iTiIFhu0pUgYLkpVJBpqnjab97aad5Yv7n+plYdaX3hjFTCNrs2yaoDnm1eOYzbtOCUiWOznYViQP7CTMQxXEdaDQSI
# DATA ssq42FlLNnu0FUxQMYMFidSxmnyvjqwDX2bwa/VikXji1cUCOhzeEcGFDmh0VFotr65d0o5KrucVNhtr0GqMx1vUdX6Nnb/0gvQi
# DATA 6Z9PzbJKFrEaCQLhC0ssQFy76ZJBhsO6piaPNHaR8r1hZ23xF9mmXT2V8Q8BLY7MYCwa593aqHgoBCYV25Jyp9+NIfDMnsOrt25s
# DATA 3dr21LYRzhLe7qKZtLOouu+MzRtxCJZzFyYL9HV4jLlTZF7S7yXflKCJM5r3IGp5wREhifs2SzxxqFzMoOglzwtTkscSiOM+2G3E
# DATA mnK8ZrmeKEiY39Ku/uHWC5NCKCDofhdkkLbritBzCb/dJWTthqfuxXdOPnN8Elp5aE2liYbsCHngCEKU+VpJQufXXowfiABksBuZ
# DATA e/JkMhWJpVD1AW/7tNm0WgN3bjf3kMd8YRm5Js4/6qaNkgYDI9G4i54znlI3cw4wrqS4FcGY44K76j4HXiV8S6wrbraa7a42HOdz
# DATA AZHbrcHlDzwVX1blXk5ftujop5MBigZUcMXOe9KWxziQEpYsi8hK2vVuT38K5ZVAW9NdYFdpiFZcYfVKarMVePe9BK+VJaxJrpHw
# DATA w05HnH4rzRZmLO7l0J456uZqTbXbiCgspBgoo3BS1TmIurRvifIJIxrxXX01w8m35tp20mKyklQWpXlkaDxdsAeGHGnPhEdXw13f
# DATA kEbFEFpmGi40SViZpOVyJB5VwQ4O+0cXFsm86bTOR5mpr0r2yADydjbDpjslZHS2nOpjBtgZ/NzyK3FNs2FLBwloX1EBDW3Wom4S
# DATA Mg9UZld90TCeSnaKGed8l698JerSGY91JkVpjLSJqNdgyfmwg/pA1nFXOd1BthSnC05g65CH1RpVJ+AIOqmCKBgBcWIvBV0taExL
# DATA XptIHlWqgviBcFTBcyS+sJced/Mc/X2czXSa4mCVCMeDVhcVCl1Uj7hnR52H0oDkSaTy3fZU9qGxO3DYCmF61DEEgJG04CbEdw28
# DATA OJnbgrmjhpdm565SsLs5rEBfyUxiEUI2q5+BUdj8kwYR7n1rAqmFQOdiC3NYiWWuzjtjfojXJFkCdJIaIuTJbVmDaUzbQt/uhqUb
# DATA UB11aNesY2NxifGt9ZtvbsQYu9lR0jj1mXJMec9C6nPE3eNBG3Dl2kb+f2F2OouVakHfEWeXihxjZjDHF5Rqrc7K11FCmivpnolJ
# DATA +6LwLF4c48dydywQqYu7XnxSFo+lOhwMS6p5P1QokJqj3n5hfXhQiBxSWF7nVfMdkKiS4Dv2KcALY3tyPMy1y1unn4MzUSvf73ZJ
# DATA 8V3GrNf9cX1N8gsv4LbIDSAzh/nfS9PAQSF2kOIeeMm9SZD0ogU9S1Rm+x80VrCMhdTHHbQrm+xhUA7WFqw97XqvOJCZmpK6Nvzx
# DATA 10uzKEnzkRcaEPcb/tFhOOCSy0uj/gk6FVs1cOOCKvSJ/BLdmMNGhbfpu7PznX/jl9KLHCw6RZYoFCXROesH1R0yljOjAgMDMzk6
# DATA x18oZXCaOx2helzNHT37aipdrpfSG4CKuL4yeA1gRyilQ04aoQLHGpOo6rjV7x6AFMIprIyH4a7TvWhWKsk4hA9N1m/OeYUJCW09
# DATA SPTc8vx4TaYrTxKzKspskWmhRqaBwI69LetjrtOfHCPYaUmIxkxdw0uxNUYXaEvxEWrXTQMlc+hm8YYiIqtFPjETIK4s0JE17vgG
# DATA PYssYjVaMJ8FbcQpqxSnCUb25toDjcLS7NrNZM7/kpdK0qq5eksxYrTyzgb+CXGAwRoKdYzADT1XcjPXedalIlQmi3PVimQFb+Zn
# DATA H/Roy530SdW/dPaDPTa3Cy+OMa5aTFVfA84594X/NSDBHf+/4+4h4/t9rS6As/3/zq+unr/o47+srq38l//fX+N/33ppeZKPlve6
# DATA /WUImhiejI8G/fMQJXZrCHnnE86MCqGjrb6BywxwSR3oSMDi9LwC2Z2uNTpEf7sl7RU4PCFvPNBkwM4VTzz5TYG8/wC3wa/sBhjA
# DATA x0DKAkGSAS+/+X6Bthfh0gtnpopC0bQ7NKXqRDMx/sTpeq09xfZCJISrDIBsVGnXsaQT82VbbakibTWuUsCS3AolT0sVvLLVQjbV
# DATA pwS0IIBl8HbhaqxPzV14zqcSKmE+DWzJtg6a4/utIdYh6N8BIzlqjRCPZE3jkeATG5JEPYAz0eQjkyutDNm94RbbAzR6g50Cx8l+
# DATA w8Pxbbvz8Si47ay4cTE4LbjIdCMlqxPDabDdouxOvbYJswFI/aLJFBM2PZ8xK2L32beUaXVLrcZdqussXjzYOv9bjsXcaeN8ndVx
# DATA GEx1R+3MOuxC+waTCU6OhNO0el0lJuVmo/lBZzlHVGLg5QuDpdBjHUsr4RRfaTuLFhYzDKGuWvxHKduQRDuYu865koyGEUNo8GLs
# DATA hFgor8S1m9sAsmIVCfFwZmGxlOeP7C12iuW0ggZK9gz8gb5q6Nu/qJYp5xo5rTtO0c6t5utwQS4EPTn1QE+mf13QkwUcCelZyXS9
# DATA 7DorM1GVjas0mAQvXDjvDbhu/K5xqi6tZMXWE52yqIBb0PpRQrvxgFIQl/C/FkmBwuy+mgFg1O5uLXMY92zcnHL0PbZCPedwh7pL
# DATA SO4WiQV8IlFq1ilBEwWWamMc4oiLenLqtKc6h9FptK852E3CbDn4QLX4xu1bN3eaGzevyTM28d7HfkL+9qnfoz43GfRJ28hApGta
# DATA UYJof3hxNrjkBR3mHZ7vF+CogDavJDMMyi85/aRmvpVcQ5YhmGg5+3619keDPE8wQ4EO9tYhbOMBAp7vo28lJmnkyn4CMPzwSj7h
# DATA WFvCIFDPKQhmrwOCL/lytgkfvXW81z2cDCY5x+VyFG3OnszwlWgo7cmAAHl8geWtZ3WmRwp4j1+OGZK/ZMXil6x6zrxmRf/D/iE1
# DATA 7ZITg3+wcpyxHKpkMzGdiqxbzMqiA4/Nhhda1rM7Y2MdxFEJXNdrPQrmof5ImPvEY0ID9bfZZWq5NPKVbgRYF4Bm3S/G7oqybr0x
# DATA nTGyZ6nAqecBp8wtVlknmzTh/TchDYDjd692y6Q3NkrAvEPAiqqbxkht0OvIjMat2Jn0ABd0AcFmE1MNOlLn3yGYtq5q8KCPBj+s
# DATA sjriQjVyqVlpUMLHo/1RtTtY7g3G4Ee9bMKFAzgYx8nFmgQiZWhrzsqOOkoA6fI9yu3UMnWqsqo9f2ruWFCTpj/XIkLYSSfkOXw9
# DATA nU99UPni5ye6jZkfvp7ZLPFcuh93jsFBLXaH9SLISwH4gOARyL1RP9CB8xRIDm2ExmF5AwsJLfD0AgH7boagOm238VD0dhkQv6hV
# DATA oTbH44G9MagURjPXe4r/tFvYcE1GNKP7mfYCJ6gQCDZWYjckvERppG7hbqif/p5Uj0q756yPGmQIq1Ps+H5rCFnEmoPJeDiRh2PC
# DATA naqvXlrRTJPHScMCRaiZICvHKMf4k/jr3CmgacvWBjQsOZiSdIi3SMbIhD8nKP8yEEo+HtBPhEMRMBSEeJmC3YWhUyxvU0o8g75f
# DATA 2GtK04jxThYQT6eVE3B/yU14lEJ+t8n+UWLdGCAz5PP3nz0GnKTk2ZfPP3z+AaaThOyTj59/BMkhk2ePJbVk6kHNgwv9vb5iFclB
# DATA r4UjZgSnDzClL0sd/LFAPyEw0yfY7B+fPQX4JmrFy0gZtgWZQsD9ZgCwJ/1up40NWvBQybNP1fd/wTyX/wIg5mEdV1t9hhgFECOR
# DATA cbij7VbnGM1jKT9AOCsbf+pJrE7mES12dbJUPfj9Z5gD+X3MwPkhoF2pmYkn/lQvIhOdeSurqRHtskCMlKGQ6J8MGUQBiizplb4O
# DATA d/tCRPIICI3huGzwLZmAp0Vd/WVik86zR6mfLFQuFGG62dJB+uxfKRW0mo5Pnj2S1kqnestNMyaXTxHhCzr2c0wZ/QiA8cvUq0+S
# DATA 02D7TmvwEMY/rSZ2PmpJTf9Y/fMYPwZkMMh8+vxD1xnXbC7FLAyXQicRYDglwuhBFYvtmhXEgoSQMp6zViwoBAy9oQYP6zPlWv39
# DATA I/fGyLMNq1uC6X2E6WMhxfYf5qOjFRC6o0Lb9f1lhk6XJO7Z5Y6kB8OgNZwLN4Aka9izoIuKDk1CG+FFKXNMdYF6zR3+f3fy3/5J
# DATA c6CvNBFMHRrSqpzIcBjNivZ9hVU4Ub2ndyp6rMSqxBANKdCNHlYdd5CuG6cDgZ5kOgjicoSurLtp5YC/hHdZoyFYIWy9oDilJlkD
# DATA GRoLlYX8iAy8TfJC1OmwOddp7HxWjfU6nWGdkLnhT4NiZW8SY3iIZVmASDrza6kQqNr0njcSyVocpmRXfkMseCZeKQzRgh0WbFaU
# DATA nrisXjFTUj+qORKfT+Mzg6cwdUo9ZC7ZUlGQjSstEcEwBFp6jkhShI9KpT+ooGpgiOkK9DOACEM+hPlc6fEBuCbimcUeIrDCIHb5
# DATA xgpPjFvyfPMc12wv9AbvOoV79jdqp/6eNycdku5ujSQ0WURgWbIx8ZGLGjLPqpTrAE5TFw1/HsS84xULFrtqW1E8/MFebZmvMo8A
# DATA qPGfDafoLqecb8iVynmLrn7p3qTbA+HHuPuZr88IB+Zq8HxAsPkQbaZh0lJLm17FPUdpDzV3B1V9rRMVdgWyjan6I7fA6ZLjvoUL
# DATA afGoLPTcQnhL0E2L2RQzD4rltDoZ7+OSH8CTUvqdH37n+Dvtne+89Z0b39n+Efm2Rb2+dmuXWNF0BtcsRHxIxCMMHLIoChX3Gs0j
# DATA u1TQ7JGAYQWxRueknDjQ+jXZhBCVbAdz1hJNatOl0CMEO1fWPciWZjmSUb+J9MWZbLEvxVzhfku/mN+J1saZKf3Umi23DSt5nr35
# DATA HrTy5ojgOVWFRgUmuJ5WrgR9MW9iqILHZOkWV6m06IJWqfx00sX0uXq+hVn6QU12vYbxmQ5EGLuDmGlujnZNFnO2NSrueB2E0ULY
# DATA Ug7IYOtE/z6BiBmfciuJhOm/dmNvl62UBxYurAi5wS5lc7+Nb8lag2bNc162O2NDzoZYmXZ3PLTMAr/IAoJx3ahMtUXWkwg+bMwE
# DATA Yon6UmNtKUwvV3XQhyODImWlBh/mibM0ILViXYo5yckQQlNbm+s3ao3X27i6kghISEDLc0TlQFdUIAhHtGRGzjVZOBtzBSPZwDI1
# DATA wTzACLrjJndaWKRFNzRFoWicxVbWxufz5g0tB6rU/agcWHalXuxGFtyidEXfSrbHg+EQYcgOBeo1p0fVZD0R7oCZqrq56jOnb0XT
# DATA jbrsJogKK/5KagYfoo312pVqsLbUaa3SQsGy3RFWqX6IkBLB+T2nKKPSpghdm2uhInOXPkeXFrghhVzWVnNan4eOnU1UhkBUTeni
# DATA ShaPiI6wfT20F2T8ThNfK6/3zxSasdMwvumo0+phePTsY+AtLGY/gSKTPO4vvNiRQpY67gDoQ4lvpfTkxFfYF9VfZB9Bj2iyqQAg
# DATA WzFfDjiykWCxDuSq871m+Xbyb1p1CfcMVl4iej1oEb4A7Rmpl77kS8ynqDtbKGHjHJ1EGjcG7qmtey+2TLL2dbU3+zLrGPE2c/1k
# DATA 5UmH3VYXI9JGKz7ULlo0b5J+N/e+ZsD/n/8clHmJrXp89tnzj5Jnf4BLHT5isP/oDKCGobS2CJx5RDf0Iapl//zsS1AHgmb2c9DJ
# DATA fon66E94AL8608oUXP0XYN/xM7jZa51AigzSfnz9SgvmHOfOifBujug3ODIkNqSpKzGFooOtVsK/HceXAkd8qYKxXvWxS4fs4keq
# DATA gb11o2I8ef4/8cQid3rSxMHdraQxrUY5puYRb+Dq+uhwAuxsC9+UxIqoxl5vNtWx0Wxm1pdgw2u2+JNSqtXohKMP+oY6kEm+P2Ck
# DATA /VyJK2KSQoWgyBGkVuz02qRGpLgoEp/Y7gm/yKxGRixWLRGYDNq7xJCNLDbVEUQVuAPAT0m6gqZdFJvQAIYZTiajnq1Siw6vgjdz
# DATA 7OWMSahUMC4FwutOhp26zsiFFru6fIP/wFe5ubbBr6pl/VOcVM9dkcxM3+C0lG3/A4cDYCHyqlKnuSfd4UvLvOw6JiBFyz0l3kde
# DATA U0sOp6X3+RB+SsvlyFL4HOdMRyCyNn4FHFyt199D31eu3nfPCA5O3wJGB+UXaAFSbP9MfDaqDaYBGW6jCxaqgkEyot7vmmE1Zi0t
# DATA Zze0eZpz2ohe3S5MVdOFDv/mmxz+7WjY8Ym+S+AvrWvXWnRDPU21S8B+rhatiYaFZhMpoNkEptJsphHfTmI3hW6IOvXF252T+Ykv
# DATA QE/f+f/b+9bnNq4rz3zmX9GWx9uABIAPUXICBeNQJCxzIpEckLLjBREUCDRJxCCAQYOSGIlbsTPZmamkMjVT+2mrZlKzu7WfFSdO
# DATA ZDt2/gXqP9p7HvfZtxvNhzxJVpyJBTRu3+e55557Hr/jwKtOwI8nPPsVHuWf0emd0+JimfnAcHsn8NgkWadbIssjJwHCvNVwon/9
# DATA 8p+hEaiMLJZwyH8OtUP7lUBQ4nPuDWQewqY/xXc/RlMZynBCJkCRrhSI1z6mTEagjP4HIyk39uwF0C4ai7BNgHiF22YN4h/IKm+Q
# DATA 4gnlHCos/mVESP1l/1kqf7xHXzn8e3b81+LC8vJyAv996ebi6/iv/9z4r4aGecdEHdGEEDhIu5+I/4rviLNT8PK9/hRScUknBxZG
# DATA 43wxYEnUeJk9sc3+CX6k+ItHhGH2xT/5+LBzmZGxj/64To3Fr1VvKrFbyXDeM4W6kuUFz+J8HwAr+tMTMuBWLchnO8a9EO4uhJUf
# DATA jcCBHqKn4Z71kfRpJ492U+sZGg5F0u5aLGpkIytOvlldWm4pXOnuaAIIqhoGCIPQtUcrpXUz4BAUvmrC2hSHUjqmlzIBSM2MMIxr
# DATA 0KjfW9/eaXwY2vhOJrIT1XswGO0VwusS29XyTJYeIZ6Gz9O44TFgyZF28LhsD5JNotLJs8B50ubeg/ZXNxtryYTMUFMmFK1as6Qj
# DATA JrnLe5bOgMadU+OAR9qVRjrZq+eeCfVK2kZESBJz16SZLdLVyYZmg+4mRurNKE6uwI87j6Ky1x5KcB1QEID2eYt5O/hQsCfIE9RC
# DATA Ozds/86Q8LrgpnWaZ4z6PnGpgWbfVDg3xLD/dwghZWC9IgVDIABUZlxEsKiZt8gmXDKjWCiW9IofxtKk6Z3NTYCv/BCJett2i6I6
# DATA ZNwu35ZtDDI8Qju9MvqYaxfr0X5APqRkljhC0wVzbxmGIu6j0ZNOV1KsTFpHbNgBBM/aCIro245zGbIj87mPt3GY4anRdvouscFC
# DATA jdIe6tDNz4SwTuuOddeTvIFtCrCXjOqtHZVo1nQpKBkbLiyeJvgXvuyNzjBsEv1ebBhXLJtHioFFxj8U7QCFoaDkmFJv3JbhzJ48
# DATA 9p3yPgQNP11cKt1ePg39jolQU14Wvrq5sbOyvlFvAGZnfWNn0z5IFCGfx8ZzHTpALvxiekiNqPUPYj5GjwnbTS/AfArHw2DQ/mg+
# DATA s6BPfa9iRWY0cZ6QktNkVCzKG8isLK5lxFukGGH06XiOYBlPWAx46dOEGhoeGUdgEKpWlxlLkSvGxwsPZFRZgdx2ghiScUlNVV3L
# DATA jOF07BoefY1U0xRzAD2b8849Sp5H5FqmAsZDH5qcd4zsxJji8Tzng7NBDxN2UoB/WMyPT73AgnrTeiwSfsOUmTLFiU324Fgnc6hk
# DATA o/Fwajxx2KgsNN5RSjTSJtlDrmM7PNSUaEWvkzXNVMo4EqlEU+2riaNNQTpgnh0AMomzhp4qXqOM6wCXOW2P4orMhRoOTR11EoIQ
# DATA 87Kw5N2ZFopZWIl5U6YUfDlTzFhTmhnyvYfHifKLCwsLxWI2fGL2BG1+II4Qf65kn/dvjtzExZwg78TsmrYc2LJcDTlMVwgE6BB2
# DATA 6koZVMXczGTJubTHPhlmbu5+/d7KKsmWlOZ8+xWff3mPQImhwOYYDNRFMdUCUuChpGSX05ldc5xWyZmQAMHH4zFelmd0Iq2ntBVS
# DATA e2gD1s7s6XnDTYsKi+IgMpQ17UkkxD64K0jPjap0R5Q+HdkeeMWkdK/xApT72gyIgvTAf8e1TZmgMdoLrN14Zma1pT1PDDiEjEx1
# DATA OSKclQKrbdoaCTNaShQc3qzhZcwwDMORKC0tWg4EHheVKacgrX0idZCTSlVshzoVk4lyPAXUkZZHFeUeV5e9oLziy8lFLiZXfSlx
# DATA Q+H3tTuRJcwbG4Vc6kyXo/WegWGVBvzkmSJRVQ6MAZuc9bc3nF744Xm0LJD0H5rVPbUHqOV+z8Tj0r8W80Wqe3l8Pte4C0SkmxzU
# DATA UUziYWHvzxQZH+bY2ZR5ujLrxpG4bZzjppH/lmH5eTeT+WjOeftI3jxgTo2vDj+jvAJ0m/ADbl/kKqEHpbWMk8LMy4Vz78xxtbjk
# DATA teJCV4q814mcV4mru0ZkXg6u4I5x/vtFiluiJo+5nDeR/LcQD0qIiSShrxyY/8LVTWs/M/GjYKVpgju45kW9eFWJY6jKnCFXnl4t
# DATA hEVJTa/sska1IPksckUyFWubDKklwVV335TWtGYql9zn4IywfCLdtTD/aJZ4gdT0YP1eY2VnfXOjvb35sLFaD61AW+k8xeFHY4K4
# DATA 0UxdrK0uT4/c9TK5/RjSbBAslGW0xNMNKtd6dC5pmwX5YYLS36jl4NopE4DbSaV/e7C+/WBlZ/W9pAURdOvcvuDLSNx0wEiPMFod
# DATA QoTNv/rug5Kx9NBGLQHJAi3IeyJ6ArL1RbaNOtC2Ns1YWEfJjG70kpkaPUUQWkIpCFcpj9BKt9o1m55mrDopL2Odw8AdSzUh4zgW
# DATA qOw6Z+4GSNxGRuR6o74WpuOW5rk0uUg4eWZtu954f13twjdRoIgDcf6j2atMyFDS8kWneQxxcGIKgr3J6HGMyuvx8TSuzCUkm6Yn
# DATA sOq6b+O0EukkfRrW2ZmpL2DCdwWClLNKamHEA5kzjwGa20ImByKgLZFEWk0D8TAumnokOZFtdca9Ju8n7CkLVvI7QbaYG4BzBcwl
# DATA JZU0XBFjkmtOzljX8x9A8+hLyzweuK+Y1jmLIlce3F2/93Dz4TYtyc5K4159JzxfjkBj7DpR4IIMhE/wLifXFgoOVEWIEYRVTwSh
# DATA 8gTQViR+hHe/U+UjcwyCsBAFuL3h8dGeUmegxRr5SMDAaIzBBq3fUbAiEhF8HE0ARyFGTCFEHMNNiUF2oDFSZmvwOMJs20okxx5w
# DATA 27m1En8mygjLEngV2ghjWyXsikZjzORzxavBDJmgbBUhq0pA7Wl3bJSCVduDfJnDAw3buyWWT9y/cW/B4kKPuBB0ij/GDB1sGeZE
# DATA YyVdALy/dKczwCmhRRMClLOLtCTgZ39/P0L1zPqWrv0I4kEBrDPoYD8rwQaeEEKcAzruDA13RcgRGgFcoZdJODKks7+19iWxvWei
# DATA 4hkaiPQGZqkPpEBq3S6Yi/AZ6Qgdxo/o4VlTJZOigy5m9tB4NZWHcQVPlc8j6wSUw6Oz+XStiUgsTHqXjItLu+bPBKRSOoDZWo/T
# DATA qxGg3wx2BJ9UCwIbjJx8JF+Vywfn1aMIWe8kPuyPAbF2SHBH8qLVY/zJhGXJd1qYs+o9M3QB38mRE+sraTzwZHiHMI8OhBu3pyOk
# DATA FoMUcpoJ9Ka4ANLoXAqOp7L9sLGn4lp/VPJ3f0r6tIT2NfLTMp6MJo6tUvXljXPal9yqHDlbI4Kng4ymeBYWi1m8ziuIMsOU1F2E
# DATA 7MIX8K4jyvNA7s8CxueHNsxOMrOZmVWCKJgem8Gr9KhA/1B2VOqVmSvZDpnK408MkD3IpyFvFHn7mr6JlxD39CikmCcd4QzXXfOM
# DATA kpJIci2zUADce5yL/sJAk9RKxrbNaQW5lKmNG70ACAGBzLAFnK5SplOnaxmSHubJwzV56Ulc0hNpSqU0C88TWygZBU9+tYbrq3Hp
# DATA SukDveJrWIth0jmihCZZjy/vrCNfeokazmYJ44ZGirCI1Ybr5Xq82DOGhJt4CVVrhpNnOvADptbVBfkxeIjIzMf26PnM8fZo9skz
# DATA 058klxeJHmVJdSg8HnYedfqDzh5hwIRp+ugruU6mq6mpX5g8kToYcuy4eLQ3Gg1M/3R1Jcmoj4KrqzTOZlVc8FqO/zrWqrupf8qq
# DATA Vvv/pJL9qQckVd2iO70TRqxRIMtLEnIFsCQ45y4eEUcjwe9Gw34Xs3JzeYLsOgRAy0Sh76oqfCBa/u1y7q1i+/nbt0PHs78RoYFX
# DATA /57cMEUtbUx0aSAkG1gj8X7GzoTaHDAVLzR+ypCsepL9sPd9RjdsYJEsdqyxQCVSR6Z6dWXtQ+UjxKeqpcBW0e5aZ60D4LVwhzAM
# DATA Jrx2ZDyS3GwwEtfp/Prqza06WUNstXU+PbsGo7B6LHub0iOKp86STACUwhZOHImkZTeIGAHUngSuwEaxAnHYo3izuLCgADG6o8Fo
# DATA 4qnWtBMbJJfVV9ULxtJQ4BuePsoFkzqfYlLUSs7mGzVecVPQklxJUpUKujBPaUPVNxU3FtL0gQZPrq4CN0Wj7RRCUQBdsT8V5Vgd
# DATA CEhZYEKMxqDxwcylUtk3Sz74k8WAtaFfNYapD9XVNKp4rlyy8Ew7C5s5QFuwvb5xT8K3ouZe6ftMUmR11ybGMYLlqtcZgJGIxU8w
# DATA DSKiJK4Th7XElUBqdaeHnamhV4Cl5xoxZhSogFQSB6AKQz3D9PGoLAlCZ3SUtpaOTIaDJFFhXMte7wShmlN1BXBXWpXFSFQRvWoT
# DATA AlsNQDDFb6GUV2kFrCFRKJu6lNvBhYYIQMdNpDLcx8jPnyYs29yi7SqD7k2yl55wQus3rQqgbeOITeaVWuwn2mg19xIqrobB090h
# DATA 7WbMzstzkrhPVm8uLC7sDk/NrONHI3EppeRKNNgmD6tFXXkkyP/ImjvckKC45wRFpq9sCbP1sSsvVQDAMnwigo41TE1AxOUZIwff
# DATA IMxCnjC7ViR3rnc+mnbnsdy8JhBS0QE50BCLZooYRTX6M7iu0LDsJdTwxxhMLHhXTaYBhsblumh2q2qUS34lRKYpgXe6FM65gAbm
# DATA ATtGR6eUk4xBtkd+y0RmEdQQtynd+WnRyZLFb1qXGcyN1DmS3lAm4/Jk707hYO+tbLfX6lv1jbX6xo7kZ1KbkwMyOi1DPeWmN6IG
# DATA y360Y3+W+nNgFau76jlgiF244ZaOUsXl0ktVNbS/dT5GIUfYcWfA4F10nAN0peDeI3HnFBe4O+yxJE/JQMyQ6a/+pp3BI2AJIjiC
# DATA TGWkXInhGiAYeWcYGJOI57BWGis+Ab1u4Q1wXzlNNY08ROY6wKxDNa3UaqRAA7WEw1F4foRljTqU/Vr+8rPhmFPftAGZbUQ4OndT
# DATA Q3LzqQEvENtLDv+dQZs64EbkGt0qkgVHfVceik4eJVWjCrRPCfHV4b1Z1en76lOgiqoZm8v7TAflQonTom//nLI/GICa9ixY6/98
# DATA BN5UEsmNyKvZMeYSdKBOCga4kh9zzIHtTdkdGaQsYX0xaWioMnhHbXbUcoEF1TqoWA3y/Op1plGCCL3d8fmTmXxX4zFyrQljXGLR
# DATA vVrs5PTz/fh64ig8Zz2UvgqvDxgynqyQT+4cFG+mW/NQfzGX4bFRf7Ap7u6oVVjd3Hh3vfGg7oBv2Ju76riO0363z2j7DUcJuu+X
# DATA g3ze4ZitMoGU0bK2spJfpW2T01xmQlC4PVIvo/gtDeHyKefOPIhS+kjG9ZxNGZ3TrKGYjk9qlJcsp5iZWMWZvoQ/c8rW8MbKqqyx
# DATA ltACmJbOfSoUcvGkox4UU+NquUYPKSX7DtlrQZZAwjYp3PgZDEJJIbflnXXQe2QRc/Ig10cVe52mQbkaZ2TJ4EomcAWBpSiAT9Ry
# DATA y3NA6otZve+BfYWgHWKgfm4+Cw7Wu5dNFnKeqZixv1354hytWPPo1OPiF6eIJp4mjFLHQ7poJ2I36DJjoxdwIFHC4OWNpMocJY+U
# DATA 802g1cGxUaf7XPkjMWYqts6P3JsZkmGi+mYj+sJMuii+ZiiBpnplEQFdYi+n06k8+g1OWU2k/VKMsSrftqGR0sA4tEScUxq3vaZc
# DATA uVyR6CURwEyf/6SoXrTbYUWTCXcvvd5lNUYcgA9hR0FeWWVMpYWW103XUMoWZUYdp61liTm1VihvdeKYHUclQTBYIF54uuI7zLT4
# DATA jvocxBPsSuNALJZBZ9NW6uQM/+RETG3CIyeXX0bxvAvrumbLbFtsc7WCO/LtChn/HZiuzKLbEP0duqEg5Dg2fKTpxDpi+BdrHuAZ
# DATA RYRB/FXc/3EU/HVw+9atm7fP441e33jfkIW0Uyp4cvRBET0oTMIfesLAawUjNKDcurFbyf5e/CtKuJKlr4NYksqDBGKSctisWQ6b
# DATA 5jI5Dpr24UUZ04iuZT6w1YfbO+3th3e3VxvrWxgi1Kg/3K7z2EAdQlULxrE7VBa9y4XDkN3TCYEx49k5LsmS2e3iRS0Vy0fJ9M5/
# DATA tmaaHKpFWkZ/LjqvXSXLxs4QExpI07zAZE60tTvRUmGY6N2A8aKM4aILiQ61Y29f1+ePgl8vF0Wd75aZEiCXMjdJRA7uTFN2pNXk
# DATA DrQcCEp7J1hhUDmRNGaMRNyRN+qrvJH/9uG6jnDyZwRL7RKkIs6x7AnXJ8lyxHEZTaZt5hRtZgtxMq6WiL10iVR5ri0iXU5MKLfd
# DATA rXKafDnJ0Jq8Ii0j0Y2yb7uuUHI+HtJEvE+14ZJ5gNeTKZc97/FSr21+sCHIdq3evnt/c/X79TUxW4JPg6iJtYL3Nxg+8YtjlfFn
# DATA ptS/p+WmTKGYJF3opHDyaHLf8xTNTEBHTFwXZjZWTE+/di4/NpQlePDkbUuPS+5QVDeN/G18PFwk411a7b68h3Qv40Gh9S9fFqc8
# DATA 1qg/IQtU9u7OsYlfhU3m4jaWc1tzsmwyryjl35twklC+zjgSqyg+DE7u4JXFCIaRsRxxBNHF9OtoMID2AjKHV+b+7C0WPnvM1VnC
# DATA rt62dUHb2tVYwqzj/8otN8mj9/r1wtPQNeRInOdZpxOyzKRQoy8M4Fowyx6UPxXkxS1HF9CKZ9p5XnmSLK9L36ysjqZL3/msL+e3
# DATA 6lzG2JBb5Z5MWZehPE4GBCTV35a1x/4ty3zElSuzENaT//U0U9e5JjzFQGaAoV/C9HMxI4hMw8etOPmCM5PaXYV146IJ715bRjIs
# DATA I990NsBURmcmAyS6Op7Y+jFH0NeRaykYlFQqFX2Ggwekb4OrYyu4zRV19JzhNO3TfCdvJAhloDR85NBZI5eK0ZOTWihhOcLZuBs5
# DATA wTYYVcGHqDB3VXfGXFPPAX2WGt4GQckRMwuM2J6HSmfYPRxNZrsgrq036quAv4AeEPUHWzsf6ijAvgxuP4cm3rIpKKlOAiIYgxEi
# DATA P8KbFQ1IUWznEn1GTT+4nKoID0U6yoM0XyBHY/MHRqVEkkZwtoy09Ye92n2paZ9sOVK3vrSBbj5YWU8o2tDqmh9/lPTA/cGU7kkD
# DATA iPytiQoqjIYsL568iqiTlysqo1TRHmQsEcNmJm9h5CWN3RnEV92LzJWT2AFi5f5GUEe7/oP17Z3tMLEVSXXDrCZd9ULsz9K79Pet
# DATA 4Sep3PRXXdERIZOIeWLQmXQP+48ivtlyXeg0GoyG3eiOzO5uqNPeDI6HGPYf6Rb7kPOkM+QogghMAZT2ZG8C2167qHJ7aSoZ1bFz
# DATA OggbVefS0STYQnaIv/ME2J4JfOCp5qK4UC7OAp4TctLm5RX+2HJl0uWzh14iMKn26CNjJvTL3UPxYgHfK2YgWFuJyEQRPjpEX8eD
# DATA TjfyglTXDqfTcXVew5RXby5QoJavMCyz3AaViQa59emQkvbVktlvC07lqR19asTWVcEvSNB8XAavwnFEoYVCTEX1STVoWs4Mqqmi
# DATA o3gPx4hqI8rvh4tLb1cWxP8tVp/C01MM8HA19cR04I2nDtQBiVvlyWiQ5hzh1jQ6OKCw3Kdhb9LHXL9kYitLHdBoLPWHT8OjzpMy
# DATA GI6h0OLCEekgn5R5vOHN8NRtgCImu4dR9yOsYSrmDoYarj5YQ+lSUB3yVPzvfgQ4ANd43fVkwCzMo6lQyMrzVOe1YkVwn2FhUvtr
# DATA GSyN+UYnldFH7yxUF4vFShdhBQpFp4T4ieP+RYVCooGu30Imz2G5+oHgbcClxIPFJQqlnEzb42jSH4EfWLi0EIshpx2uMONNuVji
# DATA GjcTlgKudvTRtq8+lSHaCRcYWpbkOlNst+4aHwdu3/ixdPVnAAGVl9pSm5D11HrjqXpD9OJUvQVdgtwvsFjaW46HwBXorrmyRZqy
# DATA 1tpIOipIitkXi5oqJgZomIdl3JTFBOhhdUlIJ+P+MApz8APJVnBi7m2u1e8+vAeFj8TM9eHKNu2OawshTqBkBeG3F6rfRl63vHyz
# DATA Kv5nfJw/7o2RgGUol4/V6BlCZ6aqL6SqOhkpcbIM8ZvVefivfkaTUp1nFbDldk3TJbtAk6RrkhRh1oPPTmexY5KjylKOEvcEV7P/
# DATA avzGHMZlO8ZWEQWkkCQSB13AdV9ProtneEULa4E+nF4CXybVlc1UpmXqQVNV/jmUp73ZygR5L7PVml4dVG5z2KkbkkOQmDYWGsMU
# DATA Y1LwKh/ykxjRcGQ22srK5OAYdusW/lKQmG2gK2i3xeq120XjzYqg73aHXymEKjQbaJbggmvNUKnSyxq/mNBF0C89JAyaKd93WImh
# DATA TS/Hk0ix5PLxZMC/8EWgDIjaeHiBRKWObeUIiLcUQS+Me4CXyDJHWyLzOo6jMvAd/Y1qIrHIDdaXp6APbKCVMTPlMpCvKA3ho7Ut
# DATA 1H5Jzw1DsDS9w23PlxCFeYS8S80Ua02RPR96xHKs/SM7fyZV9QTrZIMKDY5sJyZKgX+AIIFqn1lIXI/WfCyL/0DpWEMlYWp7GwXA
# DATA SykuPAK6W/WOj8ZxwYuMjfWScgM/GkDc+N3kk9EwFuTV7sTdfp+xkVmMH2T1MAotnS/a27Ew6dfECqAPk35OHqUY9XtJ9xwTLtW0
# DATA X9UCpwclW9EFToSotHL7U1RroV51jHd66iXC+awp5qsCflbGOXop1dvPM6gZa4HbOoM6JHKV6u1FFtzlGRntuajD7iwZqjaab9aL
# DATA XKBXBtvK6JABdOv2BR5evGHNIU3kDb/rdM5Z4G8GYWb2Q3J3d/RSbX2+Vo1Ng/pXtyuGE67SYhkTCcqOEK+qHvpn+RyKhLpxCtA3
# DATA NOLZw5WHopHyl3X9iYVFb8Ne3o2Y3aw+gKuO6AtWi+ymz8+IZnXFOvET6O/KizelW8X0ffL0o+iEHYgwGMsKGfMetsXTC+wdfTwn
# DATA EX8SJonkKNR0SutEc6GV3aAhAqRdKw1ylw7fV7FaWvxyh6rheNLWSdZsGsklNFQ2yWmwKCHqio610WLUbmOX2m3Yh+029wjWOO4f
# DATA DI8REbAAHzuDyvb6vZ1640Ep0N/fe7hlZkin5/RPgSooBZxD5Hpb3MROtJol6fpCsvfchf0+SVzYPoH89HVoRXtxgnJl9CgaT6L9
# DATA /pMM108bY9bKL6vQ+HJldPR0T1yFY0zl7cIUp0s1okdn/xqc/fHlT84+O/vd2Vfiv58HLz9++Yl48Fx8ffHyv599FsDzl5+IYmdf
# DATA n/327IuzL1/+8uU/iKLw+z8HZ1/AL8/x5S/PXlSCs/8tyjwX1b14+Qm8/fzst1D/y4+tcgH8PzT84uzTs+ei5Fcvfw6N/70o8vnZ
# DATA l8HK1npZPP1a1AUtPb8D/frpy3+CisTzT8XnX4pvz0UPnA4/xw6L+s9+f/YHfBkrqLi3bFLfrqyu1re32++urN/nCfmVqOtr0anP
# DATA xL9fQG25xs2N/hFf/lyUp0YDs7qXv8AZeW9nZ2u7rOelFIjiX+Mofiqq/Io//0I8p9c+Fg3+0j97z2H2AnOinOl4+XM5gD+Krx+L
# DATA UrBE/yYmjopBZ79Q3bfm7OXPE3OGESftd8VctR9AUMpdsBWtv7+yU8ep+z8pi4cDFP3+HXyVy/4VzIB4CJT3HMZLBhYcHHQCHxmD
# DATA XLi9sCC6/r9ktXLG8ftz0XEx4kSHpS1Sdxw76pDo12e/fvlzsbZEg+chywC7h5OGk/kH7tWvcbyfiY+Lt4Pv9++mdkynxfT0K23r
# DATA /Fp8+D3086ei3IsS/orNfwmE+UJ+f87TiARYDUC1HVfn2d0wetI5Gg/QETDROaRQ7prFLP4HtSB6JUj1N0A8ds+wsc/EbP4UG/5Y
# DATA FMa6xLrxq1/ycn358hdA6W4FSKN/xJH84uz3oprPcSY6x9OR2cvTdKYs2SB6T2kOLeSHs38XNcMyPRdc4kWCcXh2Ci/m75ECYSf+
# DATA Y8a2Fh//JTj7nViTnyBtf4kr8YUo9ZUgnxdnv8FfqO1fAjsTdX2ByyupTHC1n4sqRRfgV/GbIMpPKnBofOsv+G86EKLEyattY0H8
# DATA 3V5exn/Fn/Pv0tLy4m35jJ+/vbh0+1vBwjcxAcegwRJNfuv/z79r166tRpMpheJGAbv5gDDLeUW1+ZhUdNHjoCFtWdJVigINMGi3
# DATA f4TXQqlUld+pIlKJyWdwDZGfR/EcRuKAUWTQ3wv4McjosshEVaYlM/XkRH0UnGgMYvocVchCpqyQrqQlyzTUpodxKcCLAeuKhUQ9
# DATA jONB4TrI1yUEueSwzP1OfwDXH+Z1tVAc6J8BqxEs4yfIViRL2aoLeRoYmGBdL17+PTMt4HjMclisgTMX+e/XUFAcMCT5WKLQC+RZ
# DATA oolPoCpR6gs8IZ+HLjK5IbeKwReaIY8EPPlgLJDID1Jj1WBI4s7TGU9hNKPjKTwkm51CNb5lOI4gjjSp17ujXlYWMWeGPEjKFcI4
# DATA ku6AmgLb405/UjgcxVOGc9A/lSh5jLl0cS1UHnXkvyTfZLOFeBu8u/qPKMYG73xGlUXWeoiKDcR0vBZZr9ox1uAG1kW8PHHAjQm4
# DATA Cr+Hu8Pdye5COFPTSXI/yg9AJHzSSTFNnMwBykQgg4FUylKYOMJR7H7x8mdADCCnfYqvCCpJ5hkeG0gCMKpkCPjiwtJycB3/mdnh
# DATA /0jSHp+wTMGq83CSy86LsZWl9IYC0QtTQhNH9z+CjBY86N9Vqd4a4uKNvkRBPHLZESx99HfH4GAC7tXghHocM2apRLEFEwLQUEUR
# DATA QJsIXawxfgI/SPGUbvh7J6A3L6qFtp5SOAjzgfDJrYXvoE1rOAJPAfiE3g3REC0T3769jC4qyChUs3JUm6KW7e37Ml4jDnqYsQgx
# DATA LfsxxqSDt82UcdPviG0C2haxkMMfR5ORRLWn8AwuTztWJSzaC3ujKKb4dnPbhNKVcOZIYO+Ib3rz2WPJRhfx/SU5pZeMQPD6LbBF
# DATA oCJHxP0N7AWgLboYPc92fryK+hUfgHnAXe45KwoWF9JzhiYF6zcZ9mqbTa5yrS6/TudYK/sqCdcJEJTpugY3xk/hlDJmVHAD8eQ5
# DATA 3iSeJ0T8HJzyG+kFJxQiWSIeEAmA+AB2NUt+4O90RP5Y2oneDGCdZBh+HOyNpodBY3sFN2x9dW175Y44oDhFyhE42eGvR6Pe8aCP
# DATA mCkGuxof7w36XUC0TRCB+EmwMYsefPyGmZmnprF8Xfwk6WncgVQXZEWN46qsU/JL7bJrdO6NmtNI5q78VeJKr88NOA7EMnwtZJ9P
# DATA UNj5RKqYUO/lE3pe/lR6MoLV0ztRereggbpHxnZnriq9CASZQiKVjairgsVgkdvTUTsWBYe9uIANyuRQNUoOtdiC1IOSMCrD0eOC
# DATA pI3K8bRbrMA30YujcWEG70J574sA1Vef0yzwTdkn+MGV95/g0vsVaQmfv/wHvNmLa7+dBcdzBqowjPHJbIHLMCClyV76WL2YGMfL
# DATA GYFFSGJIOGER8yHUESs8HKNwbgSfs/9JU4ci02+wU7EjeyFHUbKXIWQpjYmY4I8FDX+JyoXPw0TXPV61Pj9a44WEJy3MGdB1IYQc
# DATA Sd1DceJUxtERmWH6jyBhI3xlAWXQ0/mITC8KrMUwQlAeQtnqPPxsQW+cK0/t2f9FndFneLh+Zgl6IADa8qwpErpzKl7/A15u1Kyi
# DATA nGjIs2KAEiF7bMln1Otk3K3H+mDjw4EAKSbox2LP4yQRZ3DG3JmOjvpdbsudOFWPZVJgK0L+ZsXQ3MDNrFUyEOuwrjgl7mwsQ8E4
# DATA i5FNeunBmIlhj51xunFcdmF07ZHlZTIcmfiSUOUgKQ5f0MU+AbXhGPZ4DePXyPkcYWj3+09qYWU6iMuhZzURLncUV/Z7wPkLZiPh
# DATA 470Q7TOCpUedIzdrEjxj+19iYEaJ/cFxfOgE0kF78cmwW5BlxBiGo4IRDz2KlVc7LTqGidO+hFi/gTEE5G4oMaauFfNoBZsWF46i
# DATA 6eGoV2IkAQeBzUxRTQWs+CyZidq4EcKT5KXw9s1vL3t+Bn4W/JdgYbTw9ttZPHZtY9vsc1XwAnGU/07ZDIyrH3DT9Y11xTgCVLVL
# DATA kwOyhdviTuVgTpmqpAphlbDHnoaUkhha5qvEOuCkHx4UwmZvGLd2h+ENHKbh5CDXKxpgRmJIgqC8P8U7ytUtmhz1pxS8XngKv7S7
# DATA g9Fxb3/QAcv4uE/G4xBD7mndyJivCnHCF3r3oDui1/gttXQpr8oUANRPSjjgdiI64iQ3ns6BGGgkIjBHY1Sr5CGjJZD8VGkj2fIj
# DATA 9OoQMwosjr9M+IvK30CVVChh+4xwqLN/BeJQ9k+iInFcvPwZCfBfor0Uz59fsx3hK77QCRosK/XZczIIQpHQQQYz4d7kWBngJrdI
# DATA 8W9I0p+d/V40Boafj7Ud66d44BmbwWqf2d1FgnAstku1QZBr5Uej/rCwHz796BTM0I/Az508OkrW9MvsDhWE1cPcq8xrwGfbkNqQ
# DATA gkqBZDs5BEGfEs6mYjAm2T6E2IoRQmkkhpyEBjRg5cZuuXXje/pJxQQPbD1dKkHiSKxttviSprKlTaN5+qHgDOgmHHKIAfU2vIH/
# DATA 3ggxmgCpXg7ETBOKqz2INTqkfebqyhPF5cf5R53J/KC/p1PBzovH85ZcmFbIkBVlnhjFRanpG3KlbmAIRXhDvHYjTEZS2IFYRt4Z
# DATA V9thjE3UHJM6Or/2xHG1Cm7UkKXcAC5G1I3VFvN2tzwzcY7hC2TeNcwwE+ldTnsEbnMTmepFbASsXado85CwzqPR6R5F5SYRb6up
# DATA EC8BbIcrnM1rHKIVXAc9B/4A98RPkNn9wWJ23CcSC6izyQhtrdHGEpka7XNsJsUD0Yj7W7yivghWVh/Ulbo3RtuxOMzGUVdcECGR
# DATA PepMnkTdbUxq8nfHI3ATDEBn0kOXwe6UdDPxYTQYyN9JfyIEwc6YTjEciI4y3N0FGtoVf6ERe3iNHl4zn70Fz956i3to0AclJ+IO
# DATA 879hcV7Swo1QhuHZCTLD5sNhfypkjTUjoKAR2Ya0nfvb5h15d7iyL2SZGsdMlUcgIkbsqBZwwDG3tjv8oAOnhbcs8iarMxzZIvqz
# DATA A/74QkiKD0ei3MMHnfij2oKQ7naHavZr1wSjozm9EV7bBSURH1S3l5cvMEG4eXJNj5wYY1LEvhKT1hnAmJo7UJN4a3O42hFyeK8z
# DATA qV0vi/8LFm6WFm9VFxaqwKesoTcEYYlz88dRby0adE62o27t5m0otQVK+RguA7WpOGOx/nWybLZodqPe3ZMadj5WE+vMhSfC5ELB
# DATA JbniSiQaAwWEjFGlZ8oZCioAwxgAIYTUe9NDFe04kZKs4fLZNCIiTK20+Mp6Q8sllE51jAehTF9WtEXMYHsq+Ao+4qDNXAfjZDDF
# DATA DWWNS/4oZVoOP6zJzLrJkhbnP57gpLhvgdJq7I/QcLw61YQb3sCutqtTkdblTsXSd3UqqPHq2LHQ0CfTlTTh9Ts+sXyPpapudjOm
# DATA x/f52jRIyGjauIF2KlIYFDXzLbRTMUVof8VOgCcJmuZIWNQ067/wMIi8q1ZiVpg3dWiLj3QS+vxtGY7RgDYmT+EKARMm74opJMP7
# DATA zpZE3wy+H0VjtFRKBKBAHsV444aczsPu4BjQrgPwzNgbTcM4GEA8P19I4koyS3YznA5kLCZvy6oxmdZupphJHpRpDK9ooaDIW94q
# DATA C/vSLGOnS6SDgKfJgnH0K5tI0DWS8E4HsSefN8sv4KdEkGfGSFB2sX6FPvtQkrwyC5kXvn75M7o+vvwXcszACyYa5+GCKU5mJwUM
# DATA eXOLJptWZ1rFO+ZP0JNWDm/sGU7Sfi9lOLoTDsuWYuRCTsxgff8RQX5gAk9WkZFIJl5+1IfrisEPdMo5ieERBYPRQcXxfA/P/t1w
# DATA bBEzWhUXKMM9EEHtdO7JyE2Mzrrd0HSJYb8/dLFZ31gvaYcK8f9sbofAVxhIzUille67uPiX7emX4v62/7h9cNyZ9F6hF2C2/9/i
# DATA 0q3bS7b/3+LCzcWF1/5/35D/304Etu3OpD8AyIQYDC2QN5KRfB6++4GQYjGbKh9HJdK/94eUdBQsERNKMHyS5QK43x1OB+fw94sP
# DATA j6d99QKFnZzPA5C/A/qPVHChww4FSs3wmyO3P793nDj8HUe55VvZXhfR8FHt6fXro7jCAYLifL2/2l65j57nq4bCd6afXYM8Go1z
# DATA DHzEfktWzZcfw21bBxK8kDY3jGoQ//1neCheEct6J/Dw030hdD0GpKezT8FHBt3yf/ryl+FMHz4xZ23jOJT5ICSI32EfzZTGJG+h
# DATA 7cbCp7Kxctl6DW9WHncEg5aTfWt5IQ8kJb05BWX1EHpUTIfk9zSyuJAAqjc6v0Ol6k/GNt6bruyj/mDgQjHqVrLMabYhjW6ZWsEk
# DATA 7Tip2ukkfWTrp8EUi9bXT1CHDuTwpYqzEWSiLdyXsOSJY8ZryQOjGpm/zfpxxPmsfX9Zxr5JtDcaTduSnRbEtJVYRdadiuuR2GRC
# DATA ohlB+vcaq1wSqt8yzLWsASSg42F/WktV0CReRIRVrcrSlEftXgntfWH5YeSkQG4/l3vFUWfyEWrW6SUCTyHMiZA1jzuINyemu4wO
# DATA Xj8a7YkNLgYN6Hbj0WPx0mAUxzB9g/5HkVRUirvYdNIZxn049vBi6WoexSxeXu3InACWrpSmIsOFwk3onN6iG2LWpA4R+qNUhVbO
# DATA dsj00OtTVs7pYR39KGoyQQbNYJHSGu0OU/WGdo2m5hBg2XhWRCXXAs6ZKs7Czt4gMrSMW6N4Wps/jifze/3h/OQoKO8HiW5YzaSp
# DATA 6BBYqXwMFyBDTWdoK9Ej3thQIaXQFmQPV32pEkuUoi6HtJcqmOfaWifqJSReQKFJtir9efgoo1jZKhPnDFaAQnnUkwdkKaDYX9E1
# DATA DkOIxPSJezh/e3zY7x7WSGaq4JeSlMrMxFHidcLmw+xDJA3xUYq1iR/lJ4AxtM90QtrdfywKYQuFUHyxzQziQeIE5wrto54dmms0
# DATA 18jnJOBMK+mPhz9U0JUvhuOAUnkcx5BXmqbcslBktMv9zKjRU5+Pt/2HT6Rix6evOaj3t+wjJXjaHSk9G1Ftf6SQ2rOveA6lLURN
# DATA Lz8oizmyigiidAuJR/ZKyMpYQ6JKzRgWBwo6XFs6Sn+KwyLRUj0Ex003PpfmQjl+JAfS68edyVEb+C94UDCpItHZZ2DRdwgy6LPY
# DATA jAFq2jxHnxf9k1n/iuAxsn6ZSgxkC9C5gQpDCsGVYCUAOU5wMIkzOgHcUvTjBVXFIOizA77BMnouaGx3NBgwTlG5jKcx9o14e7ks
# DATA 2A/RXA2RFTWjE7/hCQOJOcaCek5qK93u8aTTRdvFImjLaOPobNSSU7WK3uQTcqcZL8BCGG/M2j8J2cbQaGJnxb3vSMzX48NoyHDt
# DATA HDzW6Q8MzaW/M3bvTZNqBpfIuYvTSF5vW3QLZy/kn4jN+wKiSD+1afvsszsB+SehT/Pn0gKbKsIgP+Af5MOvoQowk4JTNHpAWnCu
# DATA amcUivZ8mUcSQ3DhHgCgN2XTeeVQZzkBvbzvMi2FcIcQF+ya6lGjDkDRa/VGLgwtroaGFFf4a3Ox2lKQTvJZdbEFalfAqQ9bpEc0
# DATA fzdZpqyVWSYFi3E1Cy3HbD5L9NVOb8/Pfo0O7kBFScv4F0rLX0y48YXzYtkdAR18CCqDUfejxL0MHOERCWTIN0jxbbO92qiv7ATP
# DATA 6Etj7YOG/Lyx+e7m/fubH1iSCuHfC7FxcjwGRBkJ87E/gduL49iKaPMOhsj6xo4JIZINKZKEFZFA+vqN9vq9DVdp+/3oZG8kxKN1
# DATA 2dNCMRvZ5Fy98gOdGLPChu/Z11JYJmPOQAEmbpviYQH+U+IngE/Srv8gQzOdkAU1rtflLQyJyczAXAmVEIMCjvgfhrPeSed/XyOo
# DATA wMufYcQN8Uq/Niq0zR7mdjIMH+ezZ2RgxvhNDmaryuhg2i4wmPefUK3281QdmmeAUqII/9RsDJTqpdw5AFfEV2QCyNT/Ly7cur18
# DATA 09X/v73wOv7/G/l78w118YYM1OOT6eFoeHPu2rVr9zl1N+TSISqRTmoV2Cec6pvSeGOOAERVg8wAk9HxwSFKhEpqzm0YOOzEYBBQ
# DATA X486XbIUAH4K6jHgyKEfQe8LACcNiAmOp+8J1ji4CngBIUKqz+BqNaVm040PwDMsawM2djwZiLYqE+qdbJM7W4Kf4eCYUx0g3mO0
# DATA oh0eEOLX+wujhs9Rdmo0qLO9vo2u/kKSM7IMzK3eX4cbE6455mYnlYuUMMK51c2NHSGI1RsAWbXT2LyPxW0xBJSpk9EgnNuuN95f
# DATA X63bdzDGekOKUWrEuYcb6zvtxubmjpZtfM5ic1sPG5AEA1J5ptRZfrQoWt5ZuVffxhAp1GJwfpTe6PEQFTkYKUVpGhnNlfJGhJwc
# DATA 84RfAGeO/lAsJWO/9vflL11BzkPxQnHuwcoP2vc377XvfriDTRph80ptS0mYJqMDMdcx55eZyJUWBAVQhIgHXwqiRzo8RuyKLQif
# DATA jA+DPTCxiX0k5mFMZeIS58eQcqkUo2O8JnceB0yGMhIc9hjd34jiaqDUbPchZyI+YGUUXbntFBVWJlL0cIHto4CnecXnWW1iJORj
# DATA 7Qy7cIj2ZBZr2Qmpf9CF0hQ2Rn0HkQyE5oWGLPYwJzotDmeholUnOHa4Yka9pObmIdJNMj/OvUZ9e9sWu50BU5YRua6oUpDjcrJW
# DATA DkegFsMIUPhPwXP/ltVYM6ytBiz5AID4xmj6LpCDE01mVPA0xFlC/xzKTYH/ojo16q0AVLboEdyokZIAkByxxhnKJTYQ2cU+edQf
# DATA oS5ONtDk2lsKvQBeEsxCbKkIE7kADxKEGkttCODvkVeTIFgwH2pfKNh4j4V8GSukAlrTChiQnxSwJYigtZ7KThWTo28ao2g1ZUFw
# DATA fTrqPCkslHApyu5Y9My0iokqK8RZqC81nlH7tZqolVPBwzbGNQSnNAhR2H2ysFDefbK4v/vk7X3x4Tv7LU46hmWL4g66tNCaswfB
# DATA CwP9Lnie3giaT8OOXkesCdDoiYlQQfEd/z1tFZvlpeWq2wbn8YNBi2ZERXO+3HeYFZDf8fm0Ui0udyP/rqrDcJK8wHaMx3IJTa0/
# DATA Wap3v8zeoA7PMzaqfcNQdwrTw0p6UxXT++jf6Ui24rlDxc5+UtqL8SDiaCs9YeNDRBtn708uEvIEwylPKa5VR2zWm+SqCSs3gPaD
# DATA b3gmi+dDVgxNNBe7uVdRRyC3HxzSXKW1KV3/PYA8JaYuOLd+G2/r8jHNWxPnrdryJjrUU4DuKAXe7vHxUUFV2sQKW5l1C+ZQmMkj
# DATA islkneicoTpRCxaqXpcPd604l9YATYpgeVE+c71+PB50ToIORtR1IMVBcG0hYLCBaxXX/yCbZA2vwEQyWCGqGqSsD48EgcqDZB3m
# DATA CjIfIVnfCBblD6ti6oHvDKJhgebVlwgDSXd7iokprLKc+o3JHy/Y2ISbGCmadIm/LS4seN4hAqDOXccy82Yrbpdi41g0tox+TFks
# DATA JLOs+lmoU2k06IxjyBSCqyVesqiyYLSzL8ghPqSGSB56DETo7QkeX8XECCAi/Ag60pDUZbQrH5nHffJIORXsvDsQpGDJQ4aTpVQW
# DATA C2Ihxi8RPgajA2b67OnAZy5kHYVkP56clpKrYOaIZFbFvNGV60N0vFcIXqI6XUuOdGbnS2DGMqCZtUWF3+/3/OrVDxqbG/c/lDpV
# DATA S9la/8Hq/UxlawKhQIliwCeTeSarLmNV5SEoFzoPtwQr+sxdKr14FYIrkmGX6rGVopP8fvUvFDzuARyQZawUtGmoCGJGugNIArzf
# DATA c/2gDC6lVav7PY7rT9JlG6m7QBcgvltBnMdUB4Hy5YiknULYBBmBMtNNJ/t4godvfVh+66j8Vm/nrfeqbz2ovrX9X0Ny7ascHNEZ
# DATA j2JEC70S6B4CSafgGzVFXhKhiqgNj6f75W9DNCqMPK6F7OYhZRDuk/Q8Sg6L0ZiY0iJjf9pEk4sqV7a26htrLimmOlip6QaNKvW0
# DATA 6jrAp8x/yEjOZBuS8NxKOQ3pqJRnB/1YzFuzuIFDmCQg7sGVKZvCDCZGmdskulWClcltkTrFODmpnJAZ4Dc7U7xB4CeLzzK/yp4a
# DATA U5ylGZJKE2N06O6mLT5XxNmtezhoVB5urLwvpmHl7v16mMqCZV+SSzPL9NVYM3eBpHv9fQOh4fM5Gk4krAgGPdmrfCR4AEMgod8g
# DATA YGZQOY/foOOEUtlur2836vcKshKJtZEaxZJjFvUN4HjY7dBFw6yfoT4sxZZtlKPex1H0kRRoEu+X7fedIYJ6qibrgdtGwS7todFU
# DATA A072iCkYGF9UGA5y3GZN0B/xXzAmT9HprbCHPLu5RBcWVaJZhWITIbX1uAgIwFQIXL+5HgYPS2f1Gb2Jhj2+ycAkQ77WwiQswx8w
# DATA akA0CFrXGds9+H79Q/wpJM9zPc970UF/OEyp6G793vpG7qoAvYD6BEc+Anro2kH5hj+Sp4WQC76rf5XPHHrliQqbjfrayupOfS0w
# DATA +tDCM1iUaHK9gO1UZPWFuP4IHhVrTCtrz/OvEhAqeY+1DFp0e21SOhB5/T6vAkBdn8zsxbXgqWyRcl+WFGfkzKbyqydjHYs5lMzP
# DATA 4Knykbz0g1YZmsIUhPLHysFgtFcIr0ulRrN6exn0RVhIlfK2HAsJJfH2zSUNHUZNgvjJjWdoExDExVYl4DsJVmeYWfEduvIYYjwe
# DATA 6x5+Z8w3uJGQWQOraBqvt4rFK78o71u56Q1pvB9lTYn3QPKlHL7Q8XSZIyrt1Ek9rzKOIcbnmPaHx9GcJ9DFSAKdzv9zsk/zdkRo
# DATA qUibFWDOcC8S3O6Hu/H1wjvV6AkYx3bjG8V3CgwJ024Z6DGt60VRsAaFK9eLf2XnfQZjTeVBserX+WjOStznGdDJY0Hqz5CvPGMp
# DATA 75kOjHwGGEvvfBSdPIMjE5RkELP8LO4Mps96MUIHwGCaiy1seT1lluUWo8JLLcPjDZNc717bDcOi91XRcVCIYA3F4K9rwXI1NUDJ
# DATA 4an0jrunEoJkYsNQNYgiMgJtRuEp9R/Rn/AT/MTc3cMXiA3gAeR0/RQxI2sDyG/PSC90ozf2Ip038I/yqae2SsYh1JIxKHyMSxV+
# DATA 4Z3+UbHQOZ4eii3+Y1QlCkJpVmstIq49QQDR5JlYyH63CDS2uw2YNJNwd9Go2zxU3RZCbkNU1rwmeNY7u3sWcYrn2/XVRn3n2dbK
# DATA 9vYHm421Z5g15Rkfm+13xLn5TBRYq2/srK/cf7aytU7PVh7uvLfZWP+vK5BdqOhWyo2pwRSbP9yd7A5bN8LwfAOYLVQ0d+Pd7db1
# DATA d0Srs0SZZ39VDEupwkFWN3b3opO/MQZpQkClfd8LbRrIqr8AsDzi9Rb/K+q4USm3rlfn52Hq4vnvVVs3qvSpdeN7iTn8Xnbvnyzu
# DATA 7TabC+V3WtebQXle/Pd75f8mrUWJ9ySkV/ewM+l0IcAagXnUN7GfsCQoSM2HEB8xDUFuE0xKv42b6eZSQD6O1g9v1ILFpbezRFYl
# DATA 0K3xdTHg1JcxRX134ikhuVeCncNIKWwt1R1pKsFzhLDa0a2iAjB8LA/aWmp58xNXYfmREuBOSTcMbwDkiOwsPJKfT/lyOwDE3mlb
# DATA OaK02U+loC3wDTKCB0fHU/A+Du7jK4hBX4J+DgU7mmKHwXuCnATE186UgOeDaefAML2PR3Gfr8o62pNEnkb9wcbKKmRuatS3NrfX
# DATA dzYbH1J63en0qDOcV6g3ZdVd136Wio0m6Hze+Q60qbqTzyjeqN+vr2zXVbSnNOux00pBK55Cmc9InHSVAyGVHO+BS+08tjj/VDd8
# DATA Oi89g+ZpLd5Rbh1tdN2oPXW99E8NJ3jCKYtrT8OVLpxDoBYBBw4ISAF81EfDHjd/AyXaEiRAF/WWV9lAWAWBvNyFZ6EnRjd8KKiw
# DATA vHLA6aX1Epj3iPCU3jQcP9l7p6CcPIyUGSCETaJ4PBrGUeIGys9JJlq6dZs9SeCKqdYajj9RHKziusSFFhBn3kYzgYpNojKOYZWi
# DATA FlAvL0IxYivgGLEaRvXoHKBSS1NywWlVlOCjn31FHDJ/tNsTPF3+B/hk58CJ1pzYbfYmnX2wtfRjrA8zVCYKjcWJLjM8WyUvMnDO
# DATA 6wBjAS90K+yLnzFDkiVJvKmmrIQpEPlnxZoUceTiv8V3xPSYNc8YxPv1xraQGpTybYL37umxYN2Fo84YEFW5Pgl6DgmxNErS8KQA
# DATA LwGdLi6/vfztm7eX3yZLBjwVJxFWeZG+8NxRl24EhYVSUeyDwnJQxt1B9eqwWcudppppsfFfu7w+3agJn6QACrPGjwOEcTsDdu4t
# DATA axcjrrRE1c01Dds7kM+PqYrlf2P3Woj8fqLJv3nNtnjCsQ6eVvakOBelglIa+fnDh+tr/CqKF/gx587624f17Z30fsXi0dh0Q2nL
# DATA iPkjcerIb5wrVkEBV2d4v7EDhMcJbM7A3RbfbROZGHOW7im/QvzhxvbKu/X21srOe6HVo3x2TVk4YdVMevXpOVOUpCfLgGalZ6g9
# DATA dtGwdPl0QCyDSFRVJVRTuZZMoyH1ubnQcpR+FCyKZjkzy7Z6o0h8fWVrq01XKRSrfRhf4OlcC2gkDJ9l6pOUosYamxFCAXoIW+X6
# DATA Q91qDa4Q+4Dw+fT28qnUNLCGITkkqQhAmFzKA2QAyDIbodKgd725lElED9a3t9c37skJ4FMZtBSA+XrU6VaG0WOuTsH/lgL2ui1J
# DATA 9+tKfNgRkgdKY73+AYh+RY/vWDrdl4T4TkrXKjV/6qB4y4qApgrmxi0m8hjwChlSX2wiCLKLsUIGb0rAQXAPxFBtvXLgvIKoY+zI
# DATA LjgJYwIWwkejwfFRBI7ATctFUHlHNvF1UkXhJ0jeRDX2973KlYKxBbAkM2fK4wQPpIyEoIno+pVwwAYWk7d2pUBJunHLzsqDvBoW
# DATA hVSy1Cq2DE2P2oZi9U7GcPEK9/pDE+KRAOGY2RQ14GM12SS7V7chTkD8DqzqdM7nvWB6GcBR0ZQdafmiNy1656baDzYfbuxAw+/e
# DATA X1/d8SRD4+odwx2untR7yVZ9lG4fLRIR2GhATgnq3U0vaZWfIi0PecqLsIPYp69Kcin4tKOLoFiVfg/hCNjJsorm3PPmfeKl47zb
# DATA spIgRE0sfz1NAr4C4G7Ua/NBauSSl/boYiqqBQdsF2ZgvoKSQFzxgbAh5W9QIP6CegPp1inRLVwsXAeQIgl4G/dBMWFi3KoAGA5+
# DATA Ccp30fRuDI2iK3zjQkcQiojFl8zZgZ9Qx5HoFIB3QNOjYZk9E3aH/AxhaW043vxYFz7S1ZEX8wEHbJQ4+Nxd2kTqSI0tkITKKBF+
# DATA hCGCZL+uMDTCcnk4eiw+cG/OXdOEZiq1BnkpQIAUIcGCTn56wgKjIbkYGiAAwAXMswFwrBOV91TwQjzU7ki6g5jOTi+YAnYMHatR
# DATA RxzZON1KB5QqYqrEA+kHZ0YaAkvUlLLppQRMia1JbXkYlY7L0NKjCfaaKZjJZzzj4hyITLkxS1zjjt1cCr5bswWgWrC88J3bCrP8
# DATA UNsUWDdKOMa7E4TYQX0QuOeHreKfkNwkUzYkZSTlo4kaqaqKyW63+2LHttuiC4N9si2bEcviYSWd7FQRfcXRb5j3HNUcilzYVtIR
# DATA 3rhHmHW6555RWedRxP1OqCasacmqj9914hN0yDrpS3vJPqNBu+b22rW4c1p2x9u9L0O7GHoWhADw0qYIJzb8B8puTqUEa5W98cNP
# DATA WIS3sbnTXt8QF/H74A2mm5ZqIqq5GfJ3D0xHooSeFnDoYoKRakpwAzDvw7PjxRTuHDjT+zJOyQsmTixRTsIHIDNG7Ao8naR9IJDL
# DATA IvW3bsiWmJIwA5Q4qd8YczBQiiIuVJe9pWVIPwLF87lu+dUd7qSm7rZCCE3h+HBp3DAX/+TzVLzqBXA6lr0KTMeWG6LapIYvoqZr
# DATA 9GVJbnUN5OlEzlYGmDjCqLZo+V1DQhxyLIAqHEcm18kD/gAsLt/aQNVNIa5jSJd/hXiVRJ12HBCGOYo5O47wAiYDHumCZ8QfBWX9
# DATA rhlIsACKx7eXFlLiVOAdjnvDFmsyfpJ9MWqCQnfqjcbDrR2LM6ku48hELQQ7LiSoquoHIIWbiQVMwhNDMZMa8HDVvQPtYQegmgkd
# DATA gPHZAZL+rqmAKcu4OObgFFrzU+O4SoZXMxPtHnaGSe6JOmMkAET2IBMCKIw7XcLE8XIY+SPqTA3GmRbMlSXXba2Bg8Ddh9sfJvw/
# DATA T3yBVOQ9nBxmBRAvD4X41v9xZO5AGnfRtxi+WtbwnzSXzvSBGK7O5NNJPsrmpm+TsyEtB3FmRUvqkDvvyaZDVVVwsbxfSJQl48oh
# DATA ZPaDSacX5Tjb0zk8MhwvpxJDQyWEOf80UCFRjB63e/0YccssqKXEQCCEUPYT2QU0SKR11BmK6npk80JinTmOrZV79faD9XsNdDHB
# DATA 4aw3LJ6Qugfga8oOoJ9eKf2zN3nuk3P25jHUgb4Y7pT4nOTZW8s4e70va5aJB7f6mu7VdW6Rw2EQsv3ZA7vAgWVX4Jxa3804tc61
# DATA /vlPDOXI5spfdFBAQB2F2et1qJqsx1jcqha2tb5Oz4oZi2jMiat3s/ekJ2Lbya+RSrEpqhTCYsxEKmSdWhlh3gAM0AAwNKE5Diwp
# DATA 26+FFO8pEEOt2qIK1Q+MvvSg8wSUYEADUMBVz+FLd0H5g0q51PYYpA5OFS32lVg6hUxZ0YTbhwf9XigZrXgEooM6TyztkuXo4SO2
# DATA wgWxqizCmyGYietiY6etIohYXqolQ53m/O6e6mTJKap7Ck7CMt98yq2nN2+f7nJBX1TXOUg4ZYtbA3YCTWQwFADU2sICLLIlK1xQ
# DATA QLjyG+G5WPOFDzHnUC5WZ1wwk8dYnrsjGf0TIAagH2GmlyaCWo/BPdBRS8mYtkJOKi26Fba7k4ijn1Aimc0sKToPkVB0wJ+xXyC3
# DATA Dbsh5tsQSeq2+wUsxc8Cmuoa1GJUJ/G96BFIUiMMcdPIvVszp0+fXAru21hCQ9Qo+q99Vyy6qtnX8qucA92Xlk8OuRKJ91KS75Xf
# DATA Iy4lvvkODyWGXYYnk2OUJ8JVpY0nwNbm6v11PbZk+lU6caWqEnFtwCc0bGWsJvpDcMW0lmn14p40lQvqc8t/Ejqy0XVK+uKXCU7A
# DATA oQAmqNcf1ow31+rvbzy8fx9/AblA7j/KN6W++kSItxcXFvwyeMa2Xt18sHW/voMnv72189GDhpaR8oTOlH7OOKqLSTj9fZMJ+smJ
# DATA A+QJJmD2FMlwefFZiiAXEqxwv29u1Xm/ewUO5kwGqEfLgweUY49Z1pbjhD4zU63ux/7xXLRSQEZQN3h7wU1cg/kA2qTd5HGSut7e
# DATA P0ng9YTOncUpuxJ7ajqY1LA2w9jbjxkd3b6sQBdaeifdKhoZkxCcx6t0gxaTBAf4PD0hBgV0K9AAPYOoI3oIcGZ7k9HjGJITs9YC
# DATA oGeAAqbR4KTi55Zp6pDUC3/6j7msLOmCm0UeHkuMmC5j6auZbiTWLmLYevZOyaFFBm2+3DY1g1CL2W3ikNGKaJ9OyTxOx5MJRx7C
# DATA O9oseM4Q0WJatV5d8vXrnPMy7DwSg0c3h6p6iV3L2blGdUm73XDB5EVW4ZqJQi4ImyFj0aScmma/rrz3QLIpN1SODMz3E9RGdmZM
# DATA 5NhuF/rDYeQLysXnGCfKcAfkKi0drV0bLuOAImB5KQlCbgHmuCA5MKE3PHKLV3R3EbZ1Px2cbdFaATGlYG5IuDB+37hbzNSKeQV2
# DATA mYcMGhai1vpmipbJnr/M082aZovqPJ1K3m54LZ+gzwDWVQqut/0Brrqpc/eY27+P90vrQFNaeunrkLx70y9tdOUvGTdxHUuBjial
# DATA 1Kv5xbXOKWqXWezVb8iepcu1NBSX0mde0NKe1cHUzs1CF7zQAJRjE606uPPI1XYZdr6mwH1io/5BveE09GawOYwUpi4KGj8aiYF2
# DATA BsCP4+P9/X63j45dENcnYxQhRAu0DjArHXGBO+zHCGqTCEU3gbpMjsfoCgqPUsIsVPPzMCZ2C6arCS5QBsplsVrGJ1x7KzUE/PLI
# DATA XtkIXznvDCn1ZijdlecrXZh8inTp+qq17a4/K7Me/5gupIhPlUS+GfV7mqo7oZL3O8CUUtXwM3X234xq3tTK/6mo4HPJuFepkJ/h
# DATA vAQB51ahc6nhMwn4qpTvht79Ihp3V2+ddqJf2u8sFzZ5hs66P9wf+TTzHFaaBReuI5EIASh3HfHhOfXc8LtpQvBp12eQXPFKFOfY
# DATA C9aezybhK1act/02ekOtSVR2UM2pjkNNk1ax85RFPWK+rFbH3tinErqBAenXjJn2n98UpeZmjTZABDY3dzgex+KiugQLYn+zedc6
# DATA J00cAgxibq9vvLvZfldscK4PKLuYGk/iqaC+sdP40KwBCdtx4HKWic50WCSdw2HuXPd/e3/aORgM4tMjN3NFnP1KJ+6h3D6fvvw5
# DATA 5uX6GL5aHgwp9yKZErCWATORS/FMym0hAED/yjIs3dGVq8pbGFFYg6jCPCE/MzXWSMusrsbPvrP2O2mqag0yoE2JSD8ppdEzvadh
# DATA AprEC9QG8SMhKXdoet1fOZjnSNG6f+19mZhGL9NT9fG0yoltnsoKT1WIh3iFf/Nv4NPd4TUVApDeD19WaeNgSgwo+K6+CnnbLZ7L
# DATA 1UduTLggNeorax+G5+nKua5lF7ieWQ72TAVqcTSrfKOmV++Cjk4mSIOndWRTiSgbEArUL7NuRhdu/s3gLmmVoT1KsYu4+EedE7hu
# DATA YcalTjCMADd+TFlidJ6lytxM7ayiZ57Qmp+upIpGlpJkoIRdrC6dDb4i7vyvmhlbOdYgq1wVcnVCnrnPzr58+YuATlLZa0oHk4/v
# DATA 6hvMXkdIViXj6DKsmBLg0c+NTePgN8WWU+nZ3a6whfzLfi6CZmyO9oP17QcrO6vvhZdZZU6sBIv872e/TmZL/T1mSoV0ev9IKQTD
# DATA GYs687qWx+Q5S9RzzK7ZQp6/6lSdD7XryXaSdPrJTkVUnFm9mz3Hyf9gpNFxHTZnp9PJ9i/wWwbsRCMQEmfmKPL2+jRFXL6AYSdT
# DATA G/VKjeBvIkoaXz0IQwaCCAPUsPeCvROKMR2P+sNpJdgSkwCBxMEWKlrmh9EULtmeWlnZANGpoxLeb0QbQXc0hrxmStHZ63cOhqN4
# DATA 2u+CCnM6ovOlK9OiX8hkn2KPb5sQ9vnVoMZ2mGn6ujAvSpA/+TZzy4TDoQ+lXOH1KTztq1TGJpOWzV0lPSdoGRXXtCgYgL/94fZO
# DATA /UF7a2X1+5AxRXo2iYvg1sOdMGuk3rypxh5YxZNny94Gwx4RgGOkf/tWVks4/7MythrHlEzYyrder8LqQuo9njg34M1JhH4x/5Bc
# DATA EhRcp6Ti/agfi0k4sMF/Eiql1NIqB8yw/2Qb8RcLZo7Lys4hpUQ8eNB/sj4sWQkwK/gS8ip6VaYHQGCA9hRfjU3lDGgDwdrDO851
# DATA cRGnwZCiwUtBp9fj/R4fj0WvMBJEvVj0vAPoLXw7LdxK2CQ9dSv4KNH3Asbcc19oSjh/aMGfVrRo5h0gdngk6hTVsKozYV61NiEh
# DATA EowHJzKWTGyBEmKIOW/tjXonNq4GFlI3To89Ihr22hJXsACl0goRmGIhXCUIzTIAYsiMmBJQ0aOk9FRgQSyWEGIR0RbCvE3fj4YH
# DATA UylxgzELxu36m+Lr+u3YN/rHaJgmEQPrsKb8EBcvjf7MwPhsojLhALR4RrgNeZDnfaZohBUA0bQzidqMFoC94dEyPoIJSkwQCeI/
# DATA dxGQGG8+2EIx3bKL5x5S3vLCTRCwpHkrfHezcXd9ba2+EZ7mUPHK24XMRgo+mvfqO+Rti7+QmhnyxZIcEWbbw3XHlgDTjOaNfeH8
# DATA IbI52qd0BDEIPoVwHpTcFNo/n+pnm9UbpcWGqskK69TZutqeHkSpHZXojCn9oTdbEt5pPhsXnPAT4Xa49OoiyNLnFJtH9HP6tHDx
# DATA aSSC42je8/eGQskv2brljkxRsBeifU/kcc6ebW1uX7ZrA+TIisIMJtSGBI5Jzt1sZZIY10fY0irM0+JtO5POMN6PJuU6HG4UK8jq
# DATA N35bUEalHwvm2J9q1dxC8F24tRR0GVRZ2iC5V0bMjPNpICDS6uG5g7CfTl+Kme4YhggLNUtEOJyfKeOFvgEuEIh3gnHxjEvWiB71
# DATA Ub1w+k1vWR9hYk8vSZy4+eY7XYqn/MukyqVbt/+CiBJWzIPhoEPDXgVtak7N8f/QoabsS4vEaCtWSD7S/WrlJ/ulC50NqUROYuFr
# DATA 8v5zIG9bjfsNEbZJ0wnbzFXQcbpMbV0Olq3LAZju3t18uLHmXg5eqVrU6tB3yINHKYBgO5m+paTvWRbnVJYaSY/pArokdx2NueiN
# DATA 2kIeBHg4645p/g48wV+A1CrSMYeWKek1D6UUIqDxioLqQxI2nvuxAJ2XfdZO93f8WpgdtsyYgtubq9+vm1Ru1md5jKLHjal8mkoF
# DATA FLnolKQahjDXsVDVW60Eur5tOiawogr/ae+PMFkQJljtgz88J9cEOmq3QYppt0OZ9XgSoyOH2H/4ubIyOTgGGMMt/EVl2gILaVvI
# DATA QN12u2i8CfnJ2h1+paBdHNF5cws14Aw0jN/E/Ww0ns4rl01pufFWZp603cMRIBvXCOQYxUPtNOkgGyBMugw6FVNRlkiYWFaGlrQy
# DATA hyHjIDMLkfK8eCft90FnLxpk/I5mtuwmwBs0vQJUm2b8zui9GSUYl5I7wcGsXBb/gdJS/wShqniYRsd9trEuuOiS2+jmW38Cd/HG
# DATA MeW7IbcS2tsKthpyhQCt6KQKoqGKHQqr44Dm0swb+BaZN/CjmDD+hKvDn3El+DPOukRH97dLFGTiTALwvtsUBz/hZ55p/sazmt1I
# DATA gjotSDcbwtVtOlcDvCN0tYitqesqVtBhVU5bdmXmHsuoUeNP4EP82u/ptfGh0pNe2q2qOPet13+v/17/vf57/ff67/Xf67/Xf6//
# DATA Xv+9/nv99/rv9d/rv8v8/T9xn7KzACgPAA==
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
