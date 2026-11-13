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
HELPER_BUNDLE_SHA256='e1adc905d0c513c36b8c0be7f7f44d50ed5f043c0ad3f97f0f5bf168e8fc2b43'
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
# DATA osJGu9Hqg9i88773h38fZP8bBfzf4P7vPmhnefsfVJE/2P//tvV/P8NaEcHUV4cu5pLwJuV/sXRQMpksSeOo++loRDXSmJ78MMV7
# DATA BO+r+8vXc6pv8Xw+TdWXy58lM/UZL7oZJ0P1NUl/9+LAV8tFMtb1gYM5+in013gys79zyWDMTzje2T3FWy/KHGYV7/nR0eneMSZn
# DATA VL6Zft8/3ntxuLP76uT04ou9g5d7xycXX7a+gWZ7h8+ozfd9+HSxqtXO4e4XR8d0ozm5avGE2Hy4Vv10Uvtzbnnx2avDZwd7Fydf
# DATA 7ACb3a7Yt4BUfrBW857vH+ydYDpKJb/BK5znKaoqfrPdEnmnedlvjppgX15cMRYbvqMNWbo9cqw+5WSJbmnZ3sqFb1tezkA5PbcA
# DATA 4cwaebUOWHiq1TFCS4mjBH93rGOakCWh+U7LglGiJyQGnPPdMqXwd/GT4UftsarUvBc7P7k43vkKS8v33SIa9AgXHJ61c49yJ8ui
# DATA Ki62qmuIlbmjOAQ4qk5FDIkM0XN1xcmQLzepE4HrMnVyW4nVqbwr27YhR3ypAWZUq8ty5X2R3hevY3Xb8pa3sihdhWpNqf9UP91a
# DATA t04/4Pezxvq5/VPt49qnFRUjvfeMg9xfIMxLoNLFmTBf/wJvSIjVdR6SqIlhnwVdHVmtrKtDNJR7MUr4iNhiOYPNizXGMbSCEV4p
# DATA vYj1iJIM0IH1HLlyTLXFdYpq3n3VB9TZTQONKt3ZqOiunXVkGPBOmoSPjs3tV/DWX8T1ME3HVdMp/GrNRJfKBlKhTSfoZImwbRMY
# DATA P1aryDs0xJSmKvPImv8jv3XfYjzTN/PJcozSdBHPzRkl4bVYdGTqhNnoa13a+3KeXKYqg+fLHnLbRjyNOHsH2PKDOcb75namMgjV
# DATA QpE4TKby8GxrHU/1YP/nDBI+LyuhjGBV8aGdVYQi49nO6Y5fkQqK9sbAh7s7u1/s+bYcoA2ivnfad7QXsN9a7TEn619N4zczvjfE
# DATA maUvVxWZ9cB5scjSlXKYCCiz8N61fiEXMhodQ8YKpiEoEC4/4uWc4+XhsyqzIf8T5kdCnwpih0bl7RyEFinXzpqyJNXhWmWtdtY6
# DATA 12yRikNpdqcTWu4ZAAQKdFMuptcI3mYFuHO/i59huLq9q0yd5EBVT5kEb5LJcrKtmLzhkA8W3MwfLS/i/wvGNp12wIphmJOyHAdz
# DATA qulgzvhbh86RGnmAdAbrXgHiq/lBhs3iYGLGoivwtuVnOoVQlZlAny2Hdkg4AFeQ54+Al2qdLdLUH2OmjUsleVmnr1vgOhnVeWBd
# DATA soDD4w8weqc96G88BlfSUWF8mbF1zg171sedYxGTuCfeVtiKpTu0RdjUsYq/CcNVdK2OO7quFF49U2+dP7ivXk2z5WxG2ahqRym4
# DATA K7V/fQnL0KmZnH97WVsOlaPdqtEcZH3QkCy06MJxt9oLd8xYd0r2WKWn6KmqPCX7DdeWFG59qpBLoqijnfINaex+MPNyha2oSs1z
# DATA U+WUCsCncgppY+VIxNUzJ0TXz2GN4afZ7V+Chl/7S1E6/5I1zm9A5azJ0dFHiEMHuwgU1cwpyFoLi1ysQiMRUUZqi2wOvQPIucQ7
# DATA 4GG6wB5M9ZgPhVvlzLpwY3JSlTtmWDAnO5NzhwsFV9P/oe80QjpQDPsD4cBCeWY3ZMuJO7yjAzIBqLodSGFiJTyCjzFtreKiuBUs
# DATA WcSV4iWhDNhaXcqSSdlERw6+xdXfYhFGp+d1dSY+raOLnNHZcjnA87bc7JHLxiTtsVilxz4D5HB4vY3vlKUh99VVRUmkSdiVi4R9
# DATA O73oir9stZCkwDpFrppB/Jlb5BUEal7Gr+7nA67DBfHkMAQ/SrmIGu6DiiNihNV8tK0FjsbE/eeZi9oeXyy+gvU4PRdZkL780hbH
# DATA 1JqPrNQK9ebl/kuE3KV3C7mFNuWVolaTvLqacYL3lQLurItOVxC/vm6vQDbAvsx5Dpn6PURmikfrl0qSbwsd4CayXoFNoHxRddZY
# DATA anV7g1pNafRavjiGlEI0MKyof2aOdMtK4h79+GOZuYJhC8e4Ky6/Pofogu4cv5OUaU6vp8WuWrSi1rqWb6+qwPURVNH6J8M4inJa
# DATA v6VU5+xGOTOesx3zFfjuMSLroL+CjWBbdGIM46AROfgqfM8lmltng63zEoPQMQJpG6w2+RzlSA0jyoV8RebfX1VcdbXQUbgrkT4/
# DATA S+QkPntqG8N+V6wiGbKuydXK1yX7AB24jc/hP3h8mfZ9OvzpdpI2PsN13j+qct+1UssBSCpnOCjXV95wEM39ETJvz51mVhB7SgWU
# DATA M8s0C3ENs6FTMgkcnk8XbFfmW2wGSQa2gWWCGCZXkKo4CFQsP1YLbFAekK7YeYirncIcQFzd5hcxyzkiuFMSkdx9qcuBn4HZKJV+
# DATA 9YsNKd2rvYzmiRK9jD2sMfKkYsZp6Moj33yT//lxHgi8ZrxAooLHSv6kCwoXa4RzC+XxG/LV08y4SY0pS93QcXOhzbpt0apm6ayq
# DATA +FxtFXfXrzlsXl3VVHyuVappFM/LZEoYgJCyq+E9JFLS5WK2pHMDhjBrD9Awv6NI92YF5ZbKADnh+JAoyHu1pqOUDxoRMKfBfB9+
# DATA qRb1OWxI9Fbnjwih+ogRC3/b0RbqPgiCbhf+lB3Lwex+WnJ8v24jyJUuFt/WnI5/qxIjQ6tsHmdZlfGGG5hUbqyoQFBtN3VFbREa
# DATA LCh01TZc1Ifsswddd9TLh1o19JKfs8cEzE84EsWeQyqIgo0bMnXl+tIutvybIuKMmMIbeRmVZwnQ95st+i9y7WbzXHXD9gs9wCNQ
# DATA wfQyRu+4Lcnq+IJbT9KS5tCRggKDaEpP4/rlHOUSO4Xa23tplbdaO6qVaWduWdAFK7SH8on+1EAHAhfYYP2lptkJxe7E/nHerpRo
# DATA cIpMcgaMdqegvqt7+nLv+GT/6FANzJU9GuwTfYyrT3qVQmIczVC/lZgVWi7mjDrLmvsgE87FBN8d9Bgj7jGs0HYT208VieDN2lRp
# DATA Q51ncqqArlhgh3CIDE1ZFWfVv2tMkcNJECPr91gyse1d7YrEhBrjjdxSnebdklsrTV235rEuNCz4eFspdKCZuNh6Ww5vv7tXADmu
# DATA r9rdnbXxqtZtDzjJOr2DIUZ1rxOyn+liu60vdVc8T8ohF1wAav0f6eK33AW6Z+3tt2wSPrVtGUDWs/tZR815jeBUN0JSa7VF2F8g
# DATA suOC2SJLMeWzMbxKfAsr+JMib8vYVJ1rND3C/KUb2bjM0bxqoLLueKM48zdvmk2OdJk2K+oAPVIEmpNq6uIk3S+bwPdc/SWaEtjH
# DATA vZ6c7lMGrukGEGetu/dQYZzCCXDTuCyks7L+4qPRcBlPY3XZjZe7dbXoc9AHqe91N6jyk66nQZ0B1Of+7MOAJWcAuQTXS1Cx4vk1
# DATA F9qKAswIiSygG75UivMpcSSDXXorV91QPcxcb5KkhDvsqS85DHQFA8ALui4s1YiKaC5MDpMhkUZJ+aL8Wldtn+D99eNE31tNCjHm
# DATA GgXEYagcmEpCQsrEzxiWHyVvtisNMfDWMQqSzLetDVRbTVm/ozNH1xw3cIo8cpiQ4tuPeU87cbpdt71uaqr9qy13b+mENNNn71UP
# DATA 5UU7hDaFNNHuifFD6U3N9KRBmWnKafSWvjX29n6yfwJbQr6BCN978fL067t7SqwUnnzf35nSXUtW8Buvb5oth+Mku6JtkKGsN3tA
# DATA 3S96lWQl3c3maQhWCh7Gp/IhC9gy8RKYAl/p56vgkkrswOIPkqZXNvvfhRndz5CAUtRx9xLexPVQCPdlF0T/67Kq0voYOHlNh6sL
# DATA JDjN8mgyT+T2CnOPykc2J7F+V8jVbyI9O5VlzPZ/NM7Fh6K8e0AayEIl066kEgwnRzbmk8U8tjaT7WtwVY+VngwhEtrwzuuOB9dO
# DATA U6IXdLgeTMva76XwQDpTtGaXDkDrgOqpYYygUtd61wMFA/I1DO5tTFh6dGsJ/j66OdLUh8HDC1Js/kBpA1XNQCOSqkUQAg1ZkrWl
# DATA 6w6IGj0uf5Vxbr3rGPOFTuyCB1yyQGm91FTShCwDTVc9YH2Vv1gaMYPEanHt4UIYTJv/i5wxyKfefvf5/61Wrz0o5P+3+n/I//8u
# DATA /q2trR3HWKHKz5YzurAmjqzKyJzDLbWsA3QKYEJoBI1DVDZGy7F9N+096f6Urv8BSfrLoegz+pdb/RF9rp53vPfy6GT/9Oh4nzLd
# DATA +UCSlIBBf8PlVThvJOmTcbpYgEn/xFxgq8vEFH7KX9u0uo9iZRmnv5LH+b7HKWhgZVDlH5Tc4sKdcZmb++eqKuEUf8kPQ79Dz3ce
# DATA 37hISLXwebVYzLKtJ08uQRdZDtErroc7zk3izpmsAfNRXTAcd97+i53Psf5g7hyE+JG2zprrm8H6iJN/at6zvZ1nB/uHmANPMVwV
# DATA aJmlWULVlPStCSb7r/LHFedauUI02Fx2LfnSf1yh4K8qhJ5vNZdmW7qZAgN2WDC+wJLcVd5SmE6eLijjonjTiy7hY91rRK8huPy+
# DATA FU7QadoYBcKHXDByP+KbGvNxB4VXK/pguiA11OqR7y5gOB+4Cce5cbVqAXIMi3AaXGamgugnhefPyJo2TbziPYrWG4+8niGdX1Lg
# DATA y1wr0eBO5CJLq/bwDXpPz2AKUqxt5N43yMUebVqiGnU2CzrTi1goyIq+drm8wenCUe55O/IMzJ2PshWtzmvn9oIC4Pliy5eXVPRN
# DATA RkrYKZ0H3polHeTizWDuWbzL+VNIRqDpgGYpWU04El0ZbM3KD8ZZytROFmgmLjH4PQmyOGvket25TsEeDLLX2PMzKj6InhvuAM+e
# DATA 0XvQkf9TzFDm3yPsOB6P3M7KV7B0bpxA7+JDnpZg77ykuJaqYGltHEytx5MwSbhooJhDdzNe+Vyr2Z6xsY79KcraWnEDaOnal936
# DATA uRKeM/Pl3I2m8UvqCA+hvfoxKsF1EtMXrArncvtQ6+VbHzpNhFMzXOdWcv3rOknpxiSF6WKcoGpdgqO6+uG238w7ck+5tKVyGRDT
# DATA E+0UNI0goiQaUO5Be4/MXTLk+Ni2tIbGfDmtnklBSyzSh9M7r3MKmDh1w2C2wAugZbr8I0ZK1EcGZXsC6n6nWTeA15wsFDVitoig
# DATA NeXhdB+fiCNUD0sCawzP0EEVR5me8ziZJAs3N9PKMM+PDSBZK8hL4raRVR8i3wfbiHNH1c17fN8WXzLqhGalGUdmzXRuk3gc8VEo
# DATA vI0A3tzi9znmK2NhLcILllrKpE+ofL2QXkXVWQy4sKIuZO6kSKmlZllUuHzucp4u6f4ENTMYwr7yT72o786WscF0xLzH/AUyb982
# DATA iPbuMLH4Y+rcBcdZEd27e+Fh1Sq9yDU+pazu6zieCXB4+QEwU7Vv6DdLl8lvIsRsu1nAhYNiRZzWkJZtLQmNmXtUgfzO1gtO3PC+
# DATA TG7dHzPAB/MTXsp9BFZVddUFcpKEfYT2bbH5lePUT1V23E6H1rCsvsTXvUfaTkNHIV2mGuFBPdanJqLlV2rWBeqakyMAuK5bD0Ie
# DATA 5cDWpKgGMDSpe3c5M6XblR03LJFBhd7H5btNVTpdAOcMc3vPZXjWkHSYD232+1iczlMTYxLnPkyXU7I0HU+kNHD03pKNbYa3tGA+
# DATA bIz3zYEgvAelvJlX4lPpGNuSUzRy9OG6oxNOP1ixV37j/K7+0bbe9FtlJTmPtcwUFAHjwc0Tba0WjuyJ3Qa7GVl/PJ+73t4htHt9
# DATA bzjSNQNKuPiDl6B/39fibQTvI8rWMSLBtkwUj2O0aZ8CT/GpCG9dscMZECGlDkrtelfXK6zufEJ1ePXS1HI6Gy/pJ9t+63FBSkuP
# DATA ONEfy8KWsjysppg1kVmH6XLM1+ehE358qxTbZLFqcbi/UWUXFxVAfiuw39neGW0qCzE81dWD6dZ0xWBzlFKpfRvX+gcX4bVNog8p
# DATA 6MuyB+OafBXTtrJcV7RHVmuV52UF2Hpd2ZAP+LKVpHbL4opLWN3VRl9IZv+v5xzWRRp+j2M8UP+lPWh1XP9vc9Ab/KH+63fl//1S
# DATA oqo6H1A4h1zkxU5Xsf1RYQELnRncff7eXN2We92/df8l2GEvweR+s8IbbPl+pV6LXX+CDzqT2ipnudjrsJ0vQ2ElRvO9a6Tp3n+Q
# DATA mRKTrpbT1+R7WwBPHAeTYRRsOUcULGuvhjUy8hFahkgpgtSfe+SIn5dUyFAhbw5VLYJL4EcZ2D5K+ZHLm2k+JkpmpbNbWj41eKIK
# DATA s/BlIEVFfwyLW/qe5o/r7KRY3YWVzSpXa3KSIVcEoBMEzmOhPH4Oc7xPnXz3X979kmt7q0Le/wB/fvv+5+//+t0/C2Wuv/vNu7/H
# DATA K+zf/RMWAteVPAT+zDrol7uCWi7/tM/UmWdyPvURZebvHpwB1RqXGVDpcSxA/psHZkCJ06Sdvg3OKpTWfb7lB0SkARIokwbPiT+b
# DATA i4QCWQq6gpNvElrOcIFBOTBX9VlCUHKipxbiiulBswQdb0gzZ4wP955yHIV/JmeE4M7xYXLAlmDTp8HpQplkamdBp3O7Jd7okCys
# DATA hvLDg2cB3/1fCq9cz52w/pv3f0MkhZXc4ROWf3//N1QT/v1/gsf/SOXn/xle+hc+MlhSQF+IxQKRjiGgJQDMTd0pywQUTKJ+Fwkn
# DATA mE/gw92DMP8XLDz/GyTyd38PVIOw/IbL4mNZeqAUqzA91rt/988wlZ/D979dCS+RDEBYN5EFgv0sB/d5eUaYXHc2sgJLb/Uod+tv
# DATA YRPfrYM9snyz/hY7vGsA525c/qySS8eaKRfG6J4gltXz1luGUhf+O1eD8TCVghVjwgZ0cR4tgTqZZD1kY8I53/uYLEubG8FCwDL8
# DATA 6t2/vP+7kl38i0qt7NzVijvXH4mOP5ZoWIWvZs+fiDfT0xdusgPjQ6fGjPYX7/4Rvvzy/V/7+Ac/AJnB7O7lWY8/9uJCbKoA4G1p
# DATA 5RUAVCxwZSf0UUXCPnjWsKX+zqe99muaKN8OwT/D3H/+7l/g/37xiLUmVkyXuxD/Jtg4JVPJGmNRYqon7YeSaOlb5ulnayZ+ARvg
# DATA f7D3tt1xJNeZoD7jVySpOc5KdlUB4FtLRRY1aBLdDYsEOACo7hYI1ySqEkCJhapSZRVBCMI5smWvx8fasWd2P8zuObOzPrtf9xy5
# DATA LdltSS2ds7+A/AvzSzbuS0TciIzMKoDslmctjaeJyoyM97j3xn157jKzz3y5NzodAkVfxiOxXDgM+DnNzMFkdKquRB39SWc2GTA5
# DATA pS68Z06J+IqkEyqnZx8IDM5zWUD2YoQYOeIvmBD/5PU/qr//0+svIzXDv8T0I7/ALCCwE3/z+ovoo/7049mBH8BdrqcUY6AYV0Tk
# DATA SiSCAxbZo9eI4KDB1G7cuHWl88KbAQbwk4pNwiKgFkh0uIpa0+60KPY5CX2A5CUtX+KrkBmXRH4r49RawY8Co/xvyBB/wYtEOVU4
# DATA B0qkForOiDozEdaq6GFEtbqhFLq7e1L02veNqMSa2iWcaQ9+cwpcPmCQ8K1WkIf2tCy0j2PXkhMIJ7xxkTXsO+txfuMGvnSiYrgj
# DATA RirBDKwoeJh3WhDx4mFk31VhYr0xHLqW3nnBIwlN4JZsuRtUA1ugRYuzQ9XoH6aAvDEGaBqn3IrqpRafqi3oJnRRfOOMgFAYaPKc
# DATA F/ucH9R8NsqZXKA0EFfurb8tijCKvsoz49AKks1UcZDiYD9Syp+fCmwyHNUcdwBH6uQxOXLnQrWA3q1QTVEqDYz6P2Ov/1QN5G9A
# DATA fFDyXVH0VI8+V2Tlp8iHvvCmBMRX9dWbvxRHER46VyOkNwZ2sX941uE4WQYak3umH7hai1EtgmKy8/FaQxUK0T0heH+uVpJIuyLy
# DATA cVngMnUwnrSU/PiOw+zReoE+F7OT2gnFupvMrKLct8p4Qfkufv15cPBq3LBW/wHlit9EkGkLSKZ68NvX/yzkBqBRuWPnXDCgn0Vz
# DATA R6dSE5HxRVYJjub9vJMe5KPBbMrO6HGzie5R+BaALvOSWH7NQ2sGQgDDAgROgAYVWFwAUxcaFCLV7lDzxeLn73D7/ywKTuwv4+C4
# DATA 9AjyhZoG3vY5MDHIP6aO0l9BBjQ6TpdqHFsEnbUX4w72OXKiCEETxEYn4eVpZXFGfz2aFHd54WMN2xD0QyifeUU0nIrmCLe6rGNO
# DATA rnFHi+dOly7qgXIAYfTdxVShPSY5dD3b37/E4UMCY+QUoIa/AObw+h/goAkKamjul3CjwWOpRZjSCw0xOKSOZTgTYmA2nXZhTWVF
# DATA wXUtqefqy8v3mT9Xo/4HYrBv/if19xdzVtpCOokuSxQN7VQpbgWe+lWHiEk1p+Aq+q42f43/Cywr3MnUsv45aWbo0F6B2+DYpAwl
# DATA 9J42RJmYo8s+2aZc43/B3it56DejhwMlsfW71ggKGuwcXeioLWay96wzRM8pZWR6Vg+TqDsYjE5JB+hPXF1Ppbnt7xufVHZdXd2/
# DATA cGz5uu/2RJpHuOHQW4EvCtzyAu5MmJXxH/C0/ROcrrKjpwU18IRoOy0vFdbl3BehyZ1izRE+lZQwys27rZwldDw0+qk+QxfhZc3T
# DATA l1mvRsp9d0WvX7/+EHqEa6PO+SwdIKXv8T2FveSH2rYxPU5BY8HRbeS4aKkrGE9cnmDApzjXq8UjKsoCePy1k0I51IseBqMU/bgC
# DATA 68VKFYXXf5AqjPsUTPt7bQmNVCl1aJQu/IF+HlbgJAL+rbdUMth8pPLU/SPmQgWNpDpyCyioygSWywBElbKiUv8QMBOJFQdbgSvF
# DATA FOuxp8WKGxUwT37ieLdFi/sds9QUcaw0bc291k1UEtTig8HogBIh0NWnxAOGGOSCsFPeTFyWcbbnMU5XVimAY3GlS2EBEzatFuMM
# DATA a+AHlxbVfi9imi+w0P3dHwIzA2u3NDHy5NZcOYhyOeQyR3GOgHIJ4eTrzeBNvjdOFK3WPOJJQQUmaRUJsc3xw4uRz77L8NppelTt
# DATA M2QMoovVZ3Xs8e8jF7mrbqsqqf3gFhsWqjoXLax9Q6+aBl0H/NL3pG0ObBKhcaZFcv0PqAoybQf9krWaVywZ4f9B6LB5VsjHzr2C
# DATA o2I61QqDo/gp1AtK9XAydnLoE4hErNavqM7P0c6/5XbQDrlue1pZ7k+cVk8G5i3k9unPjD69RebiqRHxQ9hdhiIVeK9fN9GA0ppZ
# DATA FCcnyf6weTAD1JaS6vOstB59U/Nnxlxh9cQUqg7ls9cQNnUJaEjeoSWAIsxesU08UcWe0kYBVCT8PpnjvUvMaOcsVzea9Vfqfrd6
# DATA RZ9DJ5vR78P/T4mL79/y/P9WV27/If/71+b/tztJhzkdSnWhpRxYipFB/E/OMQ6gTcgm6gZrg70VnQLJeTSbUlnEFVFFwGc8HeSL
# DATA p37rjsZnb5/UrX+kOm9+TdPp4pHkOtXbZAAiNyHPuM/AjRkss9gffoYjimw5VLPU4a/ZEP92U8jBQaa8LEPFKKcQWAWHHW/RHdSl
# DATA KVnLosEwbIwi1XqolLJNjMrLdgakB/8wYxvwBIZzt0Vm+k8UDdCxCop7w+ooWbILyqvoiSEPJPNaOmh1ImtRr58eDUdKsO6SzkPJ
# DATA zgg7Mx1F+fHo1GwUJHK4UVCanXFPKIAMdwzbvtXHZHnCV/VoNKbd6cQkMoAjTiHl+JJ3GZ0Ex1U/0Ddt6/7ZpExD5mUlypw/G4to
# DATA FcBb5E/Ze+SfwZDnpjrRI6NsCHOT9xR78H+ry8I/g4at0BCaAMFNxXVrC6b10emENNyRjVl2+2OmCY4YIkp2CnqMm2/X60r7mLWP
# DATA glsF6bO/9N0u1HXs9e9c5wros4GKVTewaSdFAAvpNcwHwuTlk5vMJu/rwOasWffhemRjGxjnWEwQuWaojxHSPJ02dzobT7YerdcI
# DATA 6XjagXfWZxYK/lG0MlJssRyaHpza+GtFWuDmPcK7baZ+LbJj/ne8pf5czaO6ktK981foY/Nb0CH9DuzLsCzqGvprNbOFO/lv3vyU
# DATA 7O9w+/4n8kNEg/2v3/zH2AWC7PBc81WVZ9txsojhUdyy+xHgQCkWpBUR/HOMelX+Gf0Ypmd1FRM0vlR3LVDr8myoB3jFJLgJ/VT9
# DATA 9pOAhPvVsrpUNaF5Vx2BPncK5brhFOLBPYDsGehUhKtspp6gtrfG5cNQ2JxVAPbI4QjU6pro5EziCvIjNuQqEHk/7Tze/K67n4zu
# DATA 1BTZXv+oWMS8fbSxXfF2Z+uhV3+pxnVxAgnbDqnSz2HT/UpuSbKRi00ZdiSs6B9RL/mITtX775OBo/TwXGJgf6f2Oyl3/h6H9Mvo
# DATA zZ8TUQOX3OoBqeOE3t//yP67eiLgI0Xp0N4MCqRfgQevekQubzXRwN0VJUB4rXwRQf4O4+SRjseDs45L7egfiMvCi7zDTvUlBYu0
# DATA SvKGoBwxAh3SKCdLA5Xfo3O8X4fnW53tR1ubjz9TZxV/qe21/nB3a9s82Nz6cOvx461PGExVXkL5fKhih3g6bJuOlbHmnHlx1FET
# DATA aTrFJGK/HuknRB32nR1eJMja4mUqYpIkKiKiFE4zdVma+wV5CaKrz6/Z3QB2BRBg9nUC0kvFhQzhuNXiioa1FwV6F5pVmHLC5rNv
# DATA 7XD1BBCCA7ZFHv3+fCwFcRVV5d2Bki6dljmGx1wp2F9RaD5AoO30exLEvRBdUNSrid1EhkVKB0yql6zHzXDdzkzaaG9oIx2iO5e3
# DATA woyhwfDM2tK6jPo+siLUtbRO5omqogmlVLLRFC4oufmkMMgc4KBrPAYAoA34jDgSXXAU5Fjl9JaZsNcr1eFQt8RIlgpVq1eFutUz
# DATA WbmzmPrMearTBSSa/6wo5N+jBIiug7pt+FwLjMVdkkj5zt44/DHiPNtO2plmOyxE08DUFObQhBBBCdpUs6HGeu3FhgJlXgQSGVPM
# DATA z0XkOSWUIZX4kqwRkWJMYEP4NTlQW7MJchV03f8HdDBEX0IUvTGWpCgy16mHdXCG5b9iQGkmuQuf7MWgL9jhh8YtlTGXO8fqWqhv
# DATA cSaeFkiFy3WEpzYXVnOfFGRgfIcP1T0bcC/43k0foRWttUw5aOgJBR1pT3q4+Lg3RVVBE7qI9kc17dTFinb5m5maBW2lht9jdVk+
# DATA HU165re6Scxfub+18RR/KpUnrqkLGceXsKJKHPgz8oAnBvET5Ai/iXAhlSDCcUsgqr/5SzQ5/XP5BdSAjFmVRa0GfcdYPb1MdR4e
# DATA 7AX464ezDJBe4c/DSXp0YtOoOOBCZUvBeEUaJ00VYK8UjRWDAZKdbPiyBipZTt4tAWpeZGf81FQdikpLp6rzEJk2if+k9p1W9gpW
# DATA ZC96Pt1/L/kO7AMbaqNq5OgZeH2j3bzxb2JJRiFddgZK7hrXSihBIEU1n3h0FV4QYB0kCTDlKWQ06rSg+0BD2mYr6soOB+lR3sYq
# DATA K+wJXD/8ozMh60TImF3lvWID/MqB2lWf84SPJ6NXZ6T+pn44h7QevegPe+24m/Z6Z7HVu5i5rX3n/jWRVrTZ2E/cyaXqaH5r3ymU
# DATA ZQsn6BrBownlUZY1DQ2p+Qnch6MhoqXpD5dcNCyQIGZDuwzD0Drw8HgJzORvSKcw3Sv9Fzq2Q80PRMIhF1OLtwzMGoU+HvWHjs+7
# DATA PnS8Q2BSTpI/qT3PbyD6/QTNt8/z95La3p/cU3u1di8pQEcKbwgaDyczxH/UWcIFoKmjRzcRc4/+vrVPOy5kQVKiGHLDFeGwOpSA
# DATA LH5uc9yHAikGQBLAp4LwHoqAgWSPp0x3RAK+6SAqilPHfVGdwdtcfB5TJCpVAo/4b13Tua6pmA3HDa4CfI9DCrKSPaHvAw4nQ+Tv
# DATA PKFUBZ63c9SjYVVurDf2/D3jYdHETQMNJFHDf3jhXW5xHjWeG2ZrL+4dmV0wd7SJvFPnc56/A6YCt0vgEL9AAeKXICugkPAlXjN/
# DATA QU8+B2nid+ir8LmSKP5GPf0NMp1JBjESGVGQe/ISgxcZuMRQqAYqlMybN38dl4PRmXSbAKhTj4RapiCnEUsyimGrhAMC2Lb6JHMk
# DATA 1WOWMKFyk1uokLK8kN+nqBxFVmb0cdg9WeWeamsf0VONJquQWQxzges089gENl9IQAV/lZ9/ji06IY2Xp5g1eo/333+/vAEEYr+Q
# DATA K6J6rzNr9vo6AsSsB1OPlpzrwKothWfF3BOZiemGhi8Rdgzs4yhI1m02DpsIb8Y+kFiCpGb4kMN6ETi0SqYsQpSZOvfoLwfWdc/u
# DATA NdT22g7BjQA/0FoPD1aMmQrhiuEkEwcj2E1PdtGSjzaJoPDTn4yGeCOmGVX3hill484DElFJmAPPEwh46nMz8XtagIclQV8woXvR
# DATA xI4vM9okJHvkT79+EQu3AlxK1HIWlpX6AvIadMVm5dl3Q1wWk/LE0QZwDuo+6z6x3UDWBiykT6iV671rc+DLb0a7x5niuPk00rsO
# DATA TlM6mx6PJn116vovMw48HGan0Kl7LM5SNiGye40BkHU6GhVzbhxq81R/WNYF1KRM+keIv9p2jxcuiNCim8A+Wve6oGu+F0hg/MB4
# DATA sRN7jdV9AkzVQnCZQE2Cp5GiVYu6q0FJ2XHeCNIZcRewNZ2rZlq0bhcuMKFd/vItKsmf2x3+Zs8pv49O6VCtPqRgE8BeAUFn/EDz
# DATA 0M2DLtBHYz5IBLKnGOYP1K5vYBCq1ZDwYxQAGSqQH6nD4QWT2krsCaqze7s4U9DcYVznZFu6l5rigK8XHEeedBoM3ul5IDDGqO0Y
# DATA hrFjiXBSd/2N2Jhcg6J6rOxvFt+IrSu+BhvsK1loMh4N2BsMn6kFaKAdfMbuhQ4wp9S9aK/4AOrhHicI12qJenRD6FpANd7vovGZ
# DATA 8VHc9+i4u6PJJBbY99pE0lkkv9IBnMYq6e2+URkhGp5x76+g4hraTSsxtSsTRCfjggl9DHwq4AR0O3va4/dgNBrUJFYc/02D3pnS
# DATA KhjCwQm39GzDVkGhBol3K9LN42ctdONQ8kw2hj9qtI2kLU+HJhtrnvsBvfb3+YS70DKDsQPOecT5hZA1oJNADFmAhp8Wq1NTV9ob
# DATA vK0/9MVAT5pB3l84WSADWDln4U+YJDS47ebZySAu9q9WUQGmfWxOX8FhICM0jhsdZf0SSSHnbIWHQ2AcBWstTKfRG2TgolJU2Wtt
# DATA mqu8r4M7SuckU7xSPwBrOsqo8jcwFf7dHyJIqHxEzmqKU0yy03QwkLdMo8Sz0gt5MtX0G5uT72yM4XmyKsMZ4IwAD6lRJlSnEN86
# DATA tSr4WntxDfX/oe5bvwIL+Zu/ZDvPL517lbkzmbbgVoZ6O1UKVHkutgIY5+mGBXHwf219Suw0O6I+GkQDXcdcVfYTo4IHjSmQWy25
# DATA IO0ejGa9w0GKMI3xURfOdbKgj8wvCL0IlZkAkGNQr36LtrC/j3Yf75QMSu3/0aRnNNFs0lnAamQ18HqnLTwl9gszIwA5n0+zFA0T
# DATA IOj30oH68u1m4CfkYAEq3D+FSzfcyv3xa+8R0yXXbgB93lHvnmg3c9PPJGwvo0HC6Bcc4GLjg+v/56yu/rJqdJ8XVdI/f/MX/qhR
# DATA ZY9nX5xo+FkzdMIsLf3wL7aBOXpKCbVu377FPO3VJD0LNiKJDwmX8vecpjaoMLf2LdvcvLVAc6adeXwBgTjn7gSQ2SUd97EFEF7s
# DATA bNXtmC7QkHRr/vL9NzIlvPnraO3pRt1ZLICdYByKn0efqpoLrgsWeYJdF3gB8+N0QtrTOdZadtYIWV6REDvyTMBYBrWSxRBrEqVE
# DATA zleMlvIZql9ei9uitJXALTXBgRVszFYgswNooW8YySejAUxGzVisHKOUHT0xLcarsqapBazexoMwOJVLnq+8NZ2JCZCVPpsgUPhe
# DATA rMa+t7J/ub4UWpOzDGv1iIZZrItXkux2cDy4ZOJ6TarJdJlxxZxUDVAQN1ogd1r2il/sO5NR3SnDU+afwf9i8V7CStlKy20zev13
# DATA SFX/En1Mfg7mwV9icQqWI7O4tioCXuCX+Ck9Z670c374KwOgQ1PiyVPqIeor4SUtU6xnwQphbTMbrkBiOK/Dk0OBdsUp+n8wtu7P
# DATA 5NSQBxai5ViXRLKCClJ0kHZfzMbCf4EekAsFn7iGA5M4J6Mvfc+Jo3VuaPDIkkmkrQoUb00ooZOfI8K0aq0AUrGWFF9iNXXqifov
# DATA ODnS9m9ZubokzfoFJvkCUcn8pMtQS11f1Y/xMQCsttQfJLkjJh4NhLtFP5ILgeBaIf267CsoYslUCARK3rH82ufq1dzac6RwhJ6k
# DATA wDdJsW3theo+77QshAvtdTuniv5haAzX2l7dXvAXXs3g5Yc8h7FnFijWKS7IbtW0LNnhoWJHoGlss+uJQ0GvhakgJ5so8lcc5bnp
# DATA tMPC9M6Mg6nupNOHBlYQ2hZXxaK2oFdCoKN52hZVls3NqFavugs/hGKk/fdsM3uMcsE6i6Cmy0xlwpjRXLkOKSi2qdOuvIIyuAcb
# DATA ZN+thryl0cwTAKlelsZLNfZ2gxlUiXrUEYfpcJLlxzUddGp6X/flmXqFVcBfKxPSTS5VHaJJbfdirac7XCWODja/6XbgtUAVQlDh
# DATA xXtovwSrKsE794fNPJtyPoBazJkkSJvnAl+gTR/QJ/DjVjj7O76kE0TP4sQz+2AJx+xD35ikgODnQo4xsWnOYaGF9Nu4R5ZfppPl
# DATA Qf/AIsAuK6YaL+6q/H+Zy5VhmATd+jPyRP17Cg8xcerG59TXWKhLupI0/qu8vZFg8UuMbZcyy+faCUn99z9KwCicY62fO49BGQNE
# DATA 5qCP6RtiTs1HHMmeSXXau9kEEgSqMjz/rdKpQVaY9jqQ+VwL4QJYDZTJg/6Psl7HbJc93gTVC1pth/UGQ6wFN4BI87esqS5vSGfM
# DATA hf2ysi+HG9hOF9VdCmzvqjECEovYm/siCyP4D4uJciouTqgZunteSnazol0uIjjceblJCz7BDwxyA0629dQ2O4jn1QRB+N/p5I94
# DATA ubQv96hCxPvgBdQXKmQHsiRXoe4BToDZgr7g/9X3scBYiL9AVeCX4LKprwC/qnQa5yN9jzwsfsvYlz8jiZ78Akvm2kmu9erMnoJ5
# DATA 9HvPUNH9YBV7NwlYxLEEmHlLvO3U0T4dgZl1YNXDa8Tr7DkZlZhL0GwloE0tp8GkUmZj78U73AN3izuWkic4WAusL7b6owzUpZRe
# DATA vnK/s9LHfMjNJgU/KMLNw17SWbhU7I1xBUZl8s+cvQK3P2AB7EMa3l4+/pGzctwv6b2leiyOC+eSM8KZmtLi23J7BAvQWHgN4wxQ
# DATA gHZjWmRdviTS62W9p7BB8TvgA14Jsl6pjeUKoVB6b45FsB4JqaV/eGkBrmTVtqVbFUPDeA5YGmz5fyZVsnd/R9BKjJ0sagW+XIR1
# DATA f8Foui6sDen6foFxfoCB/lurXw6MPDRg/40WAvBzx5QPJdlSa1fQ2xtUmzYQCgnTe4H1FO4nXpBd0dH2MnZXbNrDcS/t3tsbYVGK
# DATA 5y2Nf9l7iT6YUnCqkRNqEyysc24q4kI177pSC6+RazwRuoCiLbKkAtQmWC8/MyonywwQQn3jwdFpfCRUmlTrEq6gSvAGMC8YowCu
# DATA qQ7rJvTSd5L8uScn34OTx4FgfDrf/Cfj6g/6dqe4Ueh9jtRd6vC0Ys/33OSEOahL/ALlDYmDqb3XQzNr7bqLak9w1gJextyK8Dyf
# DATA u9510obZPsSLX7y5C76LkWlIukOTy1GvKMSgO0P4TJDGWpA5qmPPUXTDWXV0xo774Xn84fbW5m5nffNR59HWk7WNTbhFSAOBGPnT
# DATA tc31x7aYfmPlGlBhUy5sEYKjHnqTSN6IEEcDqVOrjQBe1nFowaPGetBFfTkr1X25Bnt5rb2odt6dMyWmPfug8/TZB483Huqp0A2h
# DATA B3gxvsRFw6vys9wbkkOOmZc9V5uFd/gh6tpQpjtNX2aNALqXcdVcMvhHgb0a2DjC7BHcN1xQZxOTFKxNIfOS7LWlcdAzT7aNsTAp
# DATA dqMoEjkyU6lgdGlOrhscnQ6zntNgyLNLimXuF/XwciV1R1m3n4gFmRPweeWjFDoI+0tXOC1f53Y9D5yqVsWZunCXmndl4Sg/0ZAz
# DATA pQsfLg3+wSWnANeOrB0WOlQEo7aW3r6N+Qv1VVBYl1Wa9ss6yd5fbPfZ30PzEv5KcCvR9yEnNS61VLgLabJCnra6B+gwzZ7ZIkr3
# DATA kTFXC6LlgR0SKReO2lznhUlVqPZfryNoozEDl51QYvDmC6qHjIztSNqSSBtopGkqAx1EB6dq8SGdTUex7yX99uYWWW+pw5bMbMHD
# DATA sgWNgc5z2sKK9dgWcd5CFVipRwo33NY9vrIfUMHP63M3f9gv75WA0psYIk9sjq1tVe9WlOfa+F9h9mg7WmTFCNgDkf5BKRDMIW3f
# DATA OFIE980mkApb0VTe5O2aQ+/kYUjmbFtDHiqb2RH7Km/HdY75KqWylpAk1njrnKpSPxlZzVPKgsdWiWIP1S58qKtsFxpBN0+8w7a5
# DATA o57bDDZdPQYZxYvUrWxSkBr6ExMi1YlXoe4jWWNv3OBPPbKFMyE9eKSXdi2GNHTdY7AyjTNIP652T/+lInD4Myl1Jw6YNNRfjn/q
# DATA wo4+vicSeR90yjAkQmAN9EkRv8BUxNFv5ndVEJwpSQbN1Ko1SsQBLof6FYx9n55x26X8OqHIFHTw9DQ2FPvYMUNyr3AMqFfxyRVl
# DATA hHkVXU1cKJu90I2sTBCQy7hv45i5l9We3/ZL/+K2wFivtRfofyA8l1q1DnX0wNW1case6EQgavcF3uM9079oQv9IlsKA6WGZmyp2
# DATA pW7dp6uJ3XOCO611MSScz1+MStH9m9FjDKQnBMlZzlm+CUAlzqPx7ECNKHq2/TgimDJKXsLx8AQLo2Z4kuV5czHtCMU5QFa9STag
# DATA pBhDJgG8eck9qjTYjz+bg9JTmnKgTK/L1XqgwsPeWPEWSR/ljtB1oVlJ62vXn2yufbL2vfUO6WnU1JEzZ0j/gcuiG0kcIBJFGRYc
# DATA UdlW5xEhdov5+9KePfxltXNPsdC+pw5f6EgFqoFLaWhKWy7AjJ5Dn6L6yVWBb9A2uyTIUghhybA8U2kJ2FKQwJqPivQnTMvtB/tF
# DATA fu3VhowEfJ9MtDsHRtmOfRNSGWBAoA1gzBHT4TjrT2yYKQvFhFvwasr4IIpznzEdsJGsph4wc5DPJZgfzOOGAR51YrUwKS6FaiWh
# DATA edZDPZ0ommDjGD0PJpmpioIQvWBNGXksgzbnxikSBj4Hozh9MYOM8SrC4F/wtxM2FSpmYJIIUZ8hirOc94eefgehb4FVZd4px4q+
# DATA uno1yfXbKOUoPaU6cxtTFGLld4kfSR4Oe/Stetq8Y2J2SeQvN/YY/Y3Q0SUu3Aib0VDwxglh0NVihqJwH80AWCPpmwdJs05TDbdw
# DATA frsfSu2Th8gyb7hCoCw44Y5NCGs3a6hDOslktGsvG+fmx8GsP+hxkLC6XqBaBczBFQgwN2p7caPHuHw8TeQCSVWi7xHqQG9QDiIX
# DATA vtSboAK3LZutoPRGTDztnVVFp+rsxuzaqr2La6iEbhUBIS1+d1N1o7YHQNrZq6w7m6YHAwwy3oiDWNrgb0XB1LizTEvNsdp5CWbV
# DATA 1euAGvLGmGyESKCgM0AlIPcKenPXESt8NJu2b62ssAKZcgOIDu6YP9fdJACX8dCQNnry0JChgNHrX0Uf7+4+3WnoMJ03Pw26ANlA
# DATA wi80BgsB9bJz0T+imgXckH6tDiICheNljumSkvaAbElkXHZlL0e6I5pEjub7dEuGIzHIaJ6hzqzXgGrpvsx+6EkQbJTr0ym7rQ/1
# DATA Gggf7meB3RRwvbYglgszyQUtGJLxiaBc9q5HZ+W3Z4NXY22TE9riis1IQhS7NhFJFQY9zBGE4/A5xQc0IopOcvBY+btlg3WAeWby
# DATA Jk25zkkawDWXXFVzQ66CK00c7YuABXHxLwoXBuO6a83LVEEANIiHwaguFuw0D0BFUL3N2RBdlk76OVybOqMXXnVFnxJXeKBq6gIa
# DATA iNGAvE5YlKC67t8JYdhSAp4AzK84ONJ3KrHAv7arcyUQN5bFnu+2e6ID4hFZ10kcYrKvdmEHlbSLE5ZCqzhiYEdzmhQBAM5J0+5q
# DATA JeyN2yMXm8Qo2+bRgaAQ4MhTGFaLp9BtQuI18wCEypND319kZxIF95K02EKriuAfM4+LxK9zQJlWy2s/8n9C5xLgOv/BUc1/9afV
# DATA XuQL2Fp8QCWGlwu1xQWqVZm6gWttnyws6uZbyMfg4DxjHN/P5iE9NyOZlFr79bCXECDxG8c9xyxy5QPjyF6XoS0u8jB2ga1tqA8k
# DATA G5JHSP3sU2xgaILCtjNO+5pFFqwvyObswzrhRVFhB/9mngXB0/eQRGeTnJTkcypfdpvAiWUqSifj++Rz6NYw2vMtEkpO967/TfIi
# DATA qSWB9I5s75+yhvlcT3nLW4F6JOeAoyuQw4vHSVO4sqsv1JzKkgCTKktcFG4Six92nfKS7u4G4iswy85mFY2Ye3+QKepeoUxVN1Ke
# DATA Tc7gMISk5Nqjoequ6Qt1mAAUxaag+MdikRb+sGsBEC6qqRBbmsyZGit/kWFPyl1118B/2arerg4jjbr1FLQ2ruOsI27uM56jFAfL
# DATA m/YpWqgkVe/JmYURVwyCXoEcTP9f8VXEb+1MskGmCK/HrEKD01oXbYR0ZHgXnajlMvpgdxMf0egiiDDH2k9zRItkplWGC8c6zhC0
# DATA QimqH4pP8kMHY8H9zJjfy4HiqCZ/pEbh5U2sXy5YLSXEQgW67GeJxbJsbkwt6DnBP64wVe6nbzdZuq53Nl3zz1mVuF2GKLegNjIg
# DATA Xxg3+Lb29W0Fb8uMRgdhN3gD1ndiR/2GGXnQiID6X6xO/iGzlkLOV60fXs6m3WUstWzd57FM2kvHU8b/8xzrw/fDBbUNpbmqHGWo
# DATA SVjFKQfwR02wJxnZbGQnlq6SdzWPpF5wlQ1QbBo7uMaBG2hhvYuaoDiZF2+vdUWF6J/F2caiuqUCQ7NSkZH2fJIblItCIo/wP19Q
# DATA c1WoqTNIz0YzDGBxOHmR1yx4IAv8ppS1By8ksCxLiy0Fi+UfqO/X8U9FisWV1VFVujdZk2LG0PKFcsy8JeSYyW1WBvBhj14rCNrp
# DATA LUgIr9CDATEwIQUkoWQhl6J3A9KDekGvZ+pu8kRfShZxzCRfwzojmzxJx/IOMg8TMTGZ3ijxLyr2iZy0FtEH8XXRLNu+5xMZ0hc5
# DATA etRWcUunStBEamw7Iy98SYXy27K4a4bF6bDmYFecPA1enTqJT3iMtKQitYoTfuJyB/WgFi+n4/4ygB8vEzRnTLZwaIP2xbIGERoD
# DATA 5AP5tYtkqk00dnXobc17h3zvYzXjA/XuXAP99rK0xwjVOLUnIzURo2G/WwOF+epNgms5PQZk5kKB++bzVnn6a0r+h12i7GbopaUt
# DATA P3cwD6BiV2rmQtmmRWCbvzKu8Gb8G0qEbbFqBWcDNcHhjw5GvTMXjVf3FDVhNUjOyTk6YbbK8Z897HSoVwAEBN7S3tOtweGtKr1n
# DATA S/Ku7eePR+r4rIGDERh26hgkWYEXTboXq6ZBbRsoydCy9XOTVYech3Vu0J9CvtHfEtIFxLP+DqPlfgmauIBg760B8yCZJLgJdrgq
# DATA NREhhhM6ghJ9J1kxCxW6VinGqEpFkFMozqNnzzYeNX25kFOxor+VokPUfpdD726v3E6qyMLimy886NrWDic8l2nQnalQw5BZga1N
# DATA OLehLHgk80GWjWs3mVGGVado34w4kvG3XnwyhTFrZSmv5k9e/6P6+z+9/pJNoYA7SZAlobS4xXDJX5vMFBqMn8yWb2H+vCbknPn6
# DATA 9f/Vhl//8s1fQdCnnzsDRhcHdLRFTlcudxlr7NcmePXzMWAE1NLJUW4zfsEvoK+c/7mtddSxp3rGz5pkj8I/HZ0vPgGtpA0JClSs
# DATA exkHOm6qr67CTJtj7aENsmAVYPhpEDMXZmtrDRPV0Mwh1J7JfTLJkYPqROrNtcnRDLbPU3xTE/Jtu9PpjbqdTiK+bIJnYMqf1GLT
# DATA sxgcHEbg99He05YhYxjSsPXSeq9N92I0mHD3cGTQsUINqpsigN/VEXm5/ZRyDipOr8S4njQvhr+1korTXSdHYD0k1FZ3SUlgDSN1
# DATA 2noXjZ2prhwuh40T6pmtuwxhd4G60DcluVdWhuFpuVhVbequri+yMWT3xD0T0wV8qpbCs9/pUK+jrNFH8dzik8JujT3DAlsNnERs
# DATA wW6AUGmDHmD3o0culsV/oHReSxyKMRy5YIQ176ABydXbGPghkYxKvG5uMiMy7EyPi8CNOD0BBG5uLxL7NKJGKoid7qQESOyDPyyD
# DATA quMndMd0x8C/aRH4B189+ZeNEuMHBo1B/qZgYPwtkY2LCOuYEdib+6Sc1FEYmiYfkmRIUiLIh4SFIJXWYXc4HTgszLEJe/S2NC0x
# DATA aozQBYwydNVixbFVVxLOUPxwe31tV+cj3n70ybafm7hOmZFsMzox+GEPG5BJcuPTGK8G0IIrAOFomofwogb/qfOTx1sPv9tZ/9QV
# DATA O11uGQgHpV2CEn5vdjLOJeGfu2m0igKSlefgiZ3m3X6/zf6UYI4aTts3E2BAamE76DrX6eB+7XRgv3U6sfVDzftHw9kJLjj8mQ6a
# DATA Oxsf7a5vP6lH9vfHz55KLy16Tv/UqAKTku9GR13z0bWvP63py4kj6BBHlHJJTYqjRkb9bnZGomhAKifxa+dMUeGT9Vf9qbDXerho
# DATA GVVW0wLSQ3Zgx33OLXliXKLD5l7/nRVVzWXEyK0Fl4mg+94clz1E6fkJ5lUH6fdzDQjyK0yz/gVC7n1jkf+dpJMfHaijMj77xlf2
# DATA P0hYf/f2bfxX/c/799at2+/f1c/4+fvv3737jWjlG1/D/2bgIaua/Ma/zv9989ryLJ8sH/SHy9nwZTQ+U6xjeGvp+vXr21naU1sc
# DATA t4e6lq493SC4IvRfxstqHk2PJ6PZ0XEoZkiVb6palpisa9FV/wZTChwsOKS9qX6qbqt4ZeSf6uZyrO6Y+icQPv33KF9C/wq4e6gi
# DATA mnuAcKmLTExjirDoP6FN/be8wXrPnL66yinzdNbvUR+YRug+4F1KETZ1QVS0tDtQA4qMCZEufOY2ZSR8NWi+epo0wKz7V4zyZAyJ
# DATA Vfo99ULmPCFvC+R5HFVj/bOXpEdjdT5jDCVVpDef9vrDZj9Pp9OzWtEnzB1B/IT8HiMRz6OqnfTBK5vEx9EQ0zulhFd8or9vRa7w
# DATA x13ipW/yvzUaNpJlGjkR1/5wPJvql2Z6N0fbGWmFfU0i6BL0O1Yo8tAo/ILedLh4DUR0vJwoRj0GDT/ITSf5kZp+dRzUlq9DcjfV
# DATA xtz5gYZN/eqPH2Du+XtwcPC4HFJ0Dap0IKLJDmZt3Lc97HT6w/600+GekT5y9EJthNgBKrH6VbohmvAy6Kvjz8z5nbVP4Dkpeg1u
# DATA wIXRJNl4NDA3uSmv3YTXlBWa/tRZoYNOct4cPVPPUjsHKGKNZlOZCrsembp1zXF4PO22RnVATb3tvRno6s33myvq/63CYDGDMJSB
# DATA H63WanyxSI+3s5PRlGldri+x5JBPS5tGlJp4Z+fjaDobwsjgMECJWEbUDA6buJb4Fy4oraDJ6rwMoiq+cL/ifYjeXp82PhxNTtNJ
# DATA L+s1nk5G4GAX2eWUb9Vf8M7OwAXNnU3qsMAEMVz4hduhhfT74oCChGnPnzx2BpUBNQSgK2bnV0j/pgVV9rd2AqMwYYyYF/BJHGOE
# DATA o4hUXGbXnRs35DxeOEijZjHcvcBl9+I1Svb4Iw4MB53aB5m6sU2QptnP/Zyyvm8p6upLcxHyRzX/QLN7K3yMdBGmhdZEXAnwbdLk
# DATA skl4HA8pCXFjl+FU3Yl61Tg9PcWcew3TKuEZ2xaLM+tYpyHhtqLQsK0mECRYuyUAS+CkfrS+ywbE1WQBr1C1UYo7bFvsHpgfMFTh
# DATA 1oEJbMN/DNluG/LtIIAU1f54yxP7mm6TyBC0Gej2PDuQm+3atcLcuqltMMIUU2aJAexXriiJHkT+t/MMJD7xAhFO9wZykKq71+Qo
# DATA K3FqYrbsJHeknoRcZi9lFzE+UyRBBA0aVYYx9zjJGr395dUMNO72zW/XozsrN+E/t+A/ty+wmN6w96Ob4aal9ULREP1BUrr6hUDt
# DATA eQuDmzk6TPuDrNdCjhFpZ1E7iETGagUWohY0y9SjXdq8ISNNxeT93mdFfTLMUEnJE3MPLGXgI3Ciinajp1s7u7Ar0LvOD2KDzqnb
# DATA 3cmYQmqs/aGYq7mGweOHaqNPnYRuOuV6b9rUNxaEovOqrkMBePYj1XpzNu2GtDellfXzESU4pcqaOtd8/H1gve+trLRWVjwHe6qr
# DATA Of0RKN/DYUqmOS6ra6Vv2sEOOznZm2muS9T80k3b58T2l7uqOv19YUobvswmSg7NwV82/+Es7YFMN5qmlPwR0DHS/pBU7caNFm5+
# DATA Dovn3I5QCxmNtTgq0BX4LjNRszobDBCcujaJ99Ya308bP1ppfLvT2D+/Vb919yKmZNpzZfhnWuTtjTJi1of9KUrvPYvzHdE8eBtz
# DATA kqkPMbhG5HztnKRjFFDoTgQCytrD3Y3vraNmXd281N0J/GTiRxs7ax88Xn+Eclj/RN0n8fHjjScbu/Q0ezUG8wk8Xf/06cY2PR0N
# DATA O8eUPchWYfL52Lljjw0Dnm97N3dGhi+Go9Oh1gtEuqYlQqI4AUBC1U4PEyfTorM3kuLGHSxAsGMrSd0rAZ91ppP08LDf1WXksq5E
# DATA 99vUBPzx7ZWV91e//e2bd26/f3vl299e1bcWLIU9CBSaN7qNIXp5RtwLtXdncIPNzSKCP+3RGcpmgZF1YPdOO7oYDSIejuh5nDRn
# DATA 47GShS0klq7P3FA2tzrb6zuK+qq1fLT2Gfzzyfr6d+HfJ1ubux/DH5+tr23Ly0rZQuWqtdEEfJKx+ch2i9xk0gkcOgyY3y/0CLgA
# DATA NiStlWb0tp/3TD0azRs/iw6y7gii8U1BeQw4dxHtuD2YyT29Jff35W61j7FDZndbnbzf+NZm5+Otx4+g/rM80mfgHhq6XtJxBb7W
# DATA Y0WuucFBHqbs1NIRS6DIiGxoFOVkhNWWUBrfzyYjxUDTYR5BWCgeWMbSkKSiGa2/Ok5nOTqKd7uUduFE/Y6ogYgPeNO54MJmftD2
# DATA GzUHTs3mqu8uwvOMe8pSGE0+LsKBRLgwplCFnzI126Bz5tyf9Ba5JveI52LlL9m2nlua9AhTY+uP71nkmOhwNp3hUg3BDJVH6Gdq
# DATA 9Uryeh3aqtZoBd2u2EPPcnDMoaQtSqCJfqQW956Sl6fqWk9dPEnPItXqkHhBOkDQgygfg8CvaUd6hN6XSw4rPrdsq8XOwXqL6xTX
# DATA hravwQXWyhl0HuhVTHknLA3ix9oAcVMRu8bqzcat1d2bt1p3vq3+7/sFDImYe/oYVvMDCJNU7TEJd97taMLRMhMLTgLIwjaAPg7T
# DATA wQ7wdcQCAnEVs+aBH1MN+X2SFFCuYmG5ApdjMxJFChmYMg5xLtI+9zrpNC6IaXv67Ro6NRbmTnwrcnn1ETPEtsDPYpktZCaIaRs8
# DATA wmtcKokaak1fDiACEmdt9AMyiufHaW90ChGSuRiGreYy5HsMmp3uaNASZ4FFLtS6MiIPaZ9lOnH+TkldmFykrmNsIe6wZntNhn38
# DATA +UwtHOidamIoWtNnB/hUP8GScqhe8Ty3RV1UBd03zfp4Pv34De++oBXeXHpP10JubjTKxM8zEIgsrNZom75ZNaSrchS5ueysuS3o
# DATA nrqnga4hMgSE+/gtlG3UbZ9KwK9bNxfp81PdV6OPdURVKaZyAIv6E0XVScap2FzSyUeJhginqGAqKCxVuGebo6i4haVmV+YPEVK/
# DATA g/xSrtW2sqzw++mo95p4JE2EqxTqVA2Dp/7ca6zu+/uk8tqwerd+9zbcG1RzySILI+OMSY2r9X1plB+DmQh2BOmMB9lR2j0LOIfy
# DATA BBaXJ8YqcN9hcOTsoHh9qxvOZlzKMFsP38TANjPsZT0ezTejh2ZpIiUUqc0yRRWldtSKspdqDKfHGdV/gpob5MApgECBFxBIMHwh
# DATA x/sjUaJ+NuihlOlc2ezBKZIVl3IgNdWjtfyyHmJgZZxr3xBFhqCmXjkkid/oeSErgt5m4GYIUo1+i3jY/n0bJx8vrQbcOci+gT9h
# DATA bfa1qVcWKZjtbN1qcvpHQ2RH57maWdoJrmojd3IR5uS2gZBd5vAEmTiic17IDQUcz/Yw+NE+Ei3dLRt3o8lPBxqtpeO+c/XWZFI9
# DATA 11rdGmqfILAOAgzQzLx8cNbQewfDERyaACKZiZNKDzMwjFkzgQQ6saZP6YNurKTFvO5Cl6SWRe3BDvEYGodIrnkAR0uHmOSoZ0Z5
# DATA Eew7aNmBFLxky4C5tDx6dHiYZ0JNvlKPVskLwq1UA2zNnavvUI1trTmknwgo9Eco3Jk3VL3L2FDGDYPe4CtCzdyL8Zebpc15gZsb
# DATA vyjGAEBBq8JBVBpI87AYVcXpZ+cDDUOqLnNoiMYVukfaQP0wjRC9L1L37v6oF3shdOBVy/Cje9yb/WJIZlHllBBmmm8mKu/3oxkZ
# DATA SzIWxahpjOLLEccM+mDyxnnxh9kQ3CdroX4k92gu9N0FfiR+JkUsgSHEuCRunw+UUPzCZ4XOhEA3RTUPQrWUqVO0158eNq2R5fyi
# DATA 3muF7oUrXccq+A4KSu8MjFOs00Avdgdim/2bGtSyDt8/58G19GnljduiPlw4FAOLaFy02dDzZce4NHKDnE3Hs2lZPrsyezJ5w5gu
# DATA ozYA1uAAbMmqnoMReNNAbXFJomKncUXXRoOX2vBnyjKehMxPXo/Qx1kDV9UjH2yifyi+l4NC39rhWU28VbwA6k8WUamqcakbfAR2
# DATA gjO4yDgToIPG8mb3WHWoJois6Bpvpzb4StD46UnHeDtIyVcUczgS2N+Fuw0BzT58trPbWXu60dnd+u76JhDXbZ24EX2gyDwcmYRs
# DATA WkXcdqp6srb9/Q/WNjvPdta3N9eeoPpF60zTnhKeVA3GpUckozNifLi6p2s7O59sbT+S1elPoE9icoxTAf80LAMkNMMzsC/LWNQc
# DATA C1ZP6D/lna5lWrtgqzzyV5AJIHS7QxURX8Crf45xs1YBFmRcfRYlGvQJQFlY9rwX9z1JQ15GYBta+afd1j7N9EUHK7SCD9WfzFcD
# DATA 0+dU3t6o8LxAPT2Z5dMyfTVWV0zQ926xibF/yHo7ef9HAlitTpbKnIWFPSuyajaFbVQEL47TMzDU1qVq17W+BCaHH1p9p/YW1ncy
# DATA dbeAa5lv9aXoCHd1ScYTD+q6T0L23y8AKJvKpPylYdf0pUUXMlUmC/NeQQlwKgn2iyz9vf7hYYYwX3QjuIeNjtScAS9REq/HjdGt
# DATA 3CSv5q7gseC5j/Xkq4f6TxlO0goOV+BUazuuOww39E67ONcjcOAo9XbG6nBT2S57B9wXKChzNqZQiub5Rrs91LpHbUNhEk3TGl+U
# DATA MmiJnGzZMp2ImHoPk4Z/qCe4UTFXY8vfuRdaqQd2pUMWFFrRuRUyLkA6THtn6qG6wWJM5Wzvul6Q65TgaKZRFaC41u1SeoquEk/o
# DATA 0zmfgaJOse1pzs1T95OLWHYRlTfoFchkg9JhqCpaxvBvc9cYnkx1zaNhTyeZ6sHR8dTYzSVHVPd1Ep6b0TZaPiK7DG7gSm9y1lFC
# DATA jx+DED9Sq6eem0A4MswTGSweHTe03QSVnCnCCmMmp874oXQtRmP+9FgdEujad3CnR+oDYHNoXzgDhbXfrYewQQfl44UYKtEZlj5A
# DATA Mc/aYVBh76NSlBdcP6BpxF82HQwiQ/C6y4saEgOwgVJeISYT+/e0GTtAFsvpukU6rKa11qU2gGIYvNSVult5ElSJ8ECH1VLkQjVM
# DATA y9y9GW7tm9Ga9U0C+4qSfwcjxW5ZxxQZLBLyQEdHYsDpGHb7AAONONnRgRJQe4MzugM2gw05IclvP8XhadbXXs29+HUV8yo/yg95
# DATA vKTNhnDfPuzvSQbnb2zO+XRk5yMYzw5b3VhBbPrl4phQLX2Jruuq7ZmprDzkMjefdevbvmJD3cwOG8mO5tcOvFJo75UwST0APuP7
# DATA QXbJsnCAPQruHWBwrAxlFkdNlXLDnY/Xbt65u/PsyQ76tVBqKw6DaObHqXpZG3vIpsfZq17/CI4nqnkiZB5jyouofj8fxmQOQgkY
# DATA 9fHi5nY0GB3U4htM+pPE5aFEkXvMxXiarvMWur4PrE5yRlnIPKdi2q3NKUMPoYDlOv5azGV06QR11mT+uheJ6Ua9Uo5Nz9RjsL6z
# DATA 6MV8Skl+dExHPTxUcTD6+kqB18UwXpSHwKE29qOf7wWKC7IT/KakFfcqtVBLpDlYtAG8ujTg6qLjudFzTk1aqqa9vapu6KFGUEor
# DATA RkRL3y+tO7SViddl3VHiSYPwyEKhzKGenKGZoDTwufiBvgk1+CZU9bUOZA7GMMNOW0UtuXsHhEd3VlaE/KDjke1kt6LV//6T/+UO
# DATA +AHSfdPYFAN3OpOqhANJ5wZ0zouzvORdRARjovvwH+9sbT5C+OXSqwoRnKvdOMxTQ2QwbQNJlShfgt6GvPSawswlCAA2r6RhQPZU
# DATA VbQ5HEo1m5THjq4uGGL5L/p/fmqMrz/+8/1bKys33fjP1dXVW7f+EP/5+43/3DodRqOhEqanCGLUy6KjWTrpRWivuBe9yLIxRjnB
# DATA AVM8BFEE0C/lzPpAvVQHEooHI0HxhsdppUQIJz8hJAITl6mO4nCkf/THnHTu7SNDjwfZK/tjNu0PzK9pamI9bY4XE0eanYyBVCwt
# DATA 7YKLYaTT/IGemODecLbipe2trV2tqSewUFOugchxBo4jWXq0/uHas8e7na1PNte3O/xlvDwaT+1H8dKzzQ2vxhyJUo//LWugqZGf
# DATA kqWHW5u721uPO0+3twA8z61tdni6LDO8NXt+jbBEkxH0eGdjd/2qteQksD9Z+7QDn3c++Gx3fQe8GW2Ei3kJz5Xsi2Pv7K5/ihMT
# DATA x3vPhv3p/tIjIYZZbT3uWVZD4WIsrcFdsj3MpqejyQtg7E125ekBlP1ET9DSB+hR1T5RQkgfLc9cbmmPE+PtLwGza6ubHuR0W1p/
# DATA lXV3wF+wbQ4TH6SoasWXsVeK6GoI1CXyhcRuAotpK2FlaW+DAFz3lz5JgUl9cBbomJoLvRbrH258CrOzZ2diE2YCgxT3n0OW1QFk
# DATA ldCPFBc8gKV4PpTSLGEb9GgSTQnY+nk7FsawGyBiuImSMPrKQdMkJwI3kRN9hzyaQ7Xg1HMV3XQMvp4dkk3pYUWeTGod/yvzNGlp
# DATA nhfciQIxLpmGljT7445TElNB9btTaZ+xoRdwA+2/GmSI6LISIbQ2vujnHVyfbppP3cczzDWJNw3/ViOx7NYiLtbl0NiNp1CPmr9h
# DATA NpUuObFjpqTU79BWYpLLqSUFo5+qRA0mP0aQFzXrB5N+T10Y6xHGiuLT9ooJRSeYSD0V+JtlY/gaLUp4iQRPBlNpEv04Or9588Ix
# DATA 7fKbB9Hd29pmCFeG2jjRyu8+pc80ovEY/nP3zp1bd+ydlWqpmjGtcwZ2hKVdCzMPFzqyevNbuifVPl/NFnh91VfvgNPXAaXmPYDe
# DATA 6MoW6c8jJCv8ifbMTE/6A/RM7o/vYlBl3IrJC8FiZ/bHsWvnPIzP6cOLKIf9Gp1j8QtwI4dQVxbjybW8HdXifv8QFQDnqA2A6xXp
# DATA EmSkqBiVWFI9QMpCFZkmUCbnlzo/uPFzglW1mym0vBiYYYuYdV5kHolOCdcBJkg4MdPuOOphlee2etNrxA+wrcp+87k5VLSTfDD6
# DATA cL7OkZ9fROfnS+Cro+o5IehW9QTHicU6zCruRYeDVN35mOjciy4uliJMC87XD6iGPlPSAmgyj0cjfTVRt47RBNzsGqsr6qoKhv4z
# DATA 7vc99ZVewuuD0XV+rJ52pwZPmianNxmN1fNz2iugmxYzch6d27U/ScdwxarziUouVG9txfarf2vHbN6e85RfyC5k6LzSz4+zXl2n
# DATA 8+1qYz6FV4A4aCo5yaZpNLiN3qCK8L682+h3T9QZV/95eZdmSfV42GsMs/7R8cFo0shhUsAjXT5Me2DTxGcTNemZfgLDUYdKTfGY
# DATA 3ENu3rlz2cYdvctwkqVqMTHP4DiFbDeN6WjUOOgfEZtpaP8TzCWt1gr6ohpQH5w4c0trZPfGIQXml+wO/XbO/lhgJ1x5pc6ZllzI
# DATA zqv/AznDQDt2Qe9q1GTMHIAJLLH3tg7dLECUxIpSd5QQurn+cHdja5Ni+Ng/1yHdthJ0YLpNEDTmIfjxKs7a6x/Bh0KdAJ1BrylQ
# DATA K7jlQ9hSQAcRWRgc8ZRwEqMcl4MgpzgcpeTchR5Oe2rDUUehfDhBtcNT8EQ9770XY6LjYOJMp7NQSM/EnultAYm1POuk4zHItg5N
# DATA tm2sF3pm4FBJ9qVco8jyMeiQ0fxpW2J44qSvVrvNvAxe/tCbELtyfelaK+1kEpy4tG1OyQ1QDaoi3YY3cZQVLGcbG22qLc7qJEM3
# DATA rJ8bzoDW7PPnBua+yTcA7kaTijfZ28/L4OT9Tw9jBZkNmfw20aaHujaeMWY9BxPEPqRSG714f6+1elOvspbkiBkTlTbSmhHqKO81
# DATA siw1iwMjiwinDJzc4eGU4kcJwgM/oPnN4AHyOS25uyKurqlJHcLgeUzkUlZtHrsViQ99/r5NYEnatpUOSU7AJY9U3VSdPqPpME81
# DATA Dakdxr0MvQmL7Po5wdSHOo7iOfN9EGlwyoyGVA+n0cX/HuJ/Y77EiPaT4hcVZTmjH7DR0/6wNzqtAYwE/2087teQifTMqFUvKaKn
# DATA OxhBEBx63KtRPVS87WCEkhToYgCTJeITH3UnqSLqedPcTq628sEFq6puoRW/2qqLk6AmaXMUjU7B0520T31w5ML7MNhA1Y2RPLX0
# DATA lTpX/K4P8KCAQVk5KTlOhTclsZF84sXmB72F7NKGIgJEmOiz8dEkxbMUUQonHhM6EICjmAZAokOOTkLTnHZspNPGNSV4c9lurLko
# DATA lJBNJiJHcyHiXlq0fS5QXqhetRYgeEEP3bpJwq2QKWVdSfF00UnHSHc6FHMWK0Y591sIPnARh8lacKFko2qWrtYizxH8uXrnhPqg
# DATA qYCE1ma9AnvaAryo8SPGaKUq12F5MdrODmeEnRJxeX277NVRNTmapOggrNWUzZMXoBocg+W3jU2RKzBCLhz2X7XjJu7FRghi3EM+
# DATA PexZxFOo20M8hdZozKRvMW+NT6/pIM2EU8KgVNgyFl4cMdMGZ84JHOUU6MXJPM13vryQ64S9toROSguIuJzd0l4VEXgPjUFXUGra
# DATA Zf26b8aqh6ChQU128/S4r2TQWD1zETLUg9Kc2zTogr+3fk7bpvCaAwO9IugSHvga6FgNBLvOTI3hGl4PlCSWqV9zymNE/h9FK6OV
# DATA mzer5ufZEEKBomcffhKJ9dL1ytBDakinghVmUHVdZCAuXYi64ZN/eNrc6WzsbK9/VNNf6b7iaOTDkgH73xXH+BbjpCP+VeuEUcqm
# DATA UGQ7ZeipAopdSrzrTzd5PDrTCzNgrOKrN73cvGV11HQQtOt/5d7F1Dd5NwX9I04ICoPx3krj26Dpu3OxrLjVc3AloLqSSgoMM849
# DATA wfwds+EJzw45KuUhQuroojxYBOISVKOmyuwEKsnHe1HM/Uz8XF81dawJvR8Y0Gyss9WF1rz8a0jCssBX6CNmJz0MZGerFWnnLWdf
# DATA tC0O1cdVZyK+SH4Kp4PFzlWe/q9gBKWjCHvFeRuC9+Q7WnOZo4ONeSa/M1kL2FJwJR5ozIPgU3Qyepk5SE5X5VCMFN6yxOBypgpW
# DATA eha8cYShQv26+bUYKpCC8jT5Fov//3FgM1CHKxleYdZT3Yk6ek2rKP6/NCbtv0P29QC41yXYd3iS5jFV4bWlWByCvTnax+c+x39I
# DATA zTx3mT437rL7p7gUbIKqAZ9MG4drjQ+breX99xLN+GuWgda+06rbX8l3Ep+j+quCvZw7R8XJqeS4/k7S1AEbA42qi6MH9IlECPvR
# DATA tTbTFrhzEwUB2wl6OlI1N/c1mkQdvGbxC+/0Lz6ag2wwgnCt6Uh1ZDQ9xnAv1HHIEDNFc0GEC69nbCF11VXcBJ4FyK/DOG7U9gKM
# DATA bV/MDIpfe5Ah1jI7cK+JLapMPB0hLxyexYYVqf8mAuUXvRvkwZ3LfHEYzIt4FG5K7Tnc3eO0DAegg12/MsZrxu2Mw+yssExI4ytI
# DATA J/Okq2L1JVM1V/pwsUPQE0XesM25QFevwilpLV26R94cH8Z752rmLi5LlNgIbu4gaOkuMXYGJecFF9JuxoXyount7olbgVlmCWyQ
# DATA pcPZuDPG5MyEYKwd9J2zC++0l5WTeo6C9kmBlB7ko8FMTS8B4TSb7F1AOp9pXsG0DzVD4h7hVy2Y5unxhUCW6qqNgMmwEUrqxgRi
# DATA b/KM0uGxxACGC/i5XxGwitilbVtbc+Axb55nSHm7OZp+CB6GgRCiAkwUA+Ahv3+8+d0atGN4/RwCXZgCFrLULJh+Xkg4KJSxTEC+
# DATA nRk8HaA3m9jFlD00vWJhYyVkZXK6bsQNHRtbK7aG0XSySxRe51Ri5uZ7u58mSbhZvwpHhnq0se3OabgSwv3wKqoVpDGnJpgu/QCp
# DATA FIxsVT5l4cr1GkySS68rcl65OKEV5uMKU+udVQTzprNKsCpeh5wDWzjgAT4QzmKFDXCOqq3Nx5/5Wars780PIKeUQ58qzo0PpF2V
# DATA 3GpyENL18uGFb/DUImeB/wxHtaRa/i5dcXEUouDOX3R3BLAyF9sRHrETaPxG8q6Rb4mD287eClA0Wbj5h3InGjh2rwe8UHi16GEM
# DATA hbotTw8b37IAy7y5usf9QW/Cm4b3XyVnsSxZcpCiOMZdYM8B3Yz1JdB7J8fjM6H2McZD8W8HKQ54BzxEoK3CW+n2wY0kAHxqfIDL
# DATA wgadWd1VE6kuBmfOsuaBdTWD0RwVe9Z0k5kWJhG/kLNIX/FV+3AEMrK+mOfMvANtTjIDI4C/ncXWJXzxQAkyPpI5aikYNLDEskDY
# DATA VpcxKhjub80KTt4gt1tolKyFNhw4sIc3HJ8ph5iiu/sy4btlOlxy9e6tb922cDTwWUHc92kZdG6c9ic5povPQ3DuwjmEQeHqGgNs
# DATA iL4ZxW3J8HBUxQI7UWA+kZWXHLEQD8HXvhKoH0DKOYCLBUg/g6GcuYm+yX96dAA5hjo49A44krXxT+eIS3i4KWbRRYi4RXaFGIXv
# DATA eKwe8aZAUz2J/jX4e9KBjIR2v6K93DyvapYE/YEahtqJ7PGcR40Gfk0JZRkq6JTSz4Cm3Nl+eKhFJ5pWMi7sSoublDiT7G3yJSFe
# DATA OsYG2rToTYQtbmP/UIkEPwub1XVB1SoKrEXntt1PDIreNO0edxj3WIwI1bOw5leZ322qjmuvnOHi3uF20UM+CRtb4j3ypN7fsyia
# DATA K/W7Ny9iv9vV246Hrb/xFv0dLDgpV7qIy0DVLpOhP1Z/cKu0J1AkgmhgKIyR3aprzfw4LkpzRmfnkDiqwaFqLKo9G/ZNfGQB1EIv
# DATA FXdAB6T2WlIHRslZSjE3ynQlohQ6NKouU1Hp5AixXopV5TIyWHeCdFKLd1B3qAZ8HqvHY3IrYhfMfK91E/ED92IvNu0gzY+fD9l3
# DATA J2pks+dDRKdzaClsRKoGVHSI4Q3yCUBkZ90oNpvVlIFxUQnQDCSBlLw0luDEAigF3Grapr69Oy2NLetsCETGQosERJyx8pA/t1Wr
# DATA V0TLqBD8VxcCRUbef8UBMuPZsDudEUxF9zid5O343h/9+P6DWhJ7tYGJZZrlY/AZxFZV9VCHVwpayTDZAUZWOTdVcJmqYTGG6cOh
# DATA sJ3EP/XcjX1weMWS89wnXZRJ9YGzbN9kPN9/g1oMwjSD3//e+b1o/dDh0QRkrhTyEsKA7kNaJVRq6GemYoqPYPBefpb7N83SbeJt
# DATA FT7olsRdcqexDyDxOUOn1LVhkC/zSzwp/Lcl3dRtPFVtdar4fZ3JlwOwYJszLgN7sR/Shn5mGzHS/pomhbPD046OZkMUKZPz3XSX
# DATA noJrlt8Dv6dokSMTPVIC+vty8wXyDyWDwwj+Bvxm0A7dZ/i3AdddIOHUO3XEpqVF0SsTy2pwXJ24IDStNKhhL4NZFCOiK9NxHx3m
# DATA 4O19fMubq+XCseJ8YLF92IE0KFLpwKfvgS1Sfo7v5GdQBNcdP91zavShTql8O7pZoRw3Y9a3F6fGJFzhql7gCmYI60yMp9ph2GM1
# DATA HgYsCTMOGqhuJsxNDCch9gAOF0h6UYVsBpswjoqDQcnMeQudUydut6gf6jlGIpuM8qcTmLUJrpLmi7gwhcs8nhgtokuJLx33yROk
# DATA 9dUJv9MJxLr0OrbykHBrTq1TOmitKJQqysU+yrVasI9mFARjhAnTOKA7I8MRST1MxcUg6jCONiREIeD1o2BDAFDOgr4Rjv1QbI2U
# DATA xotibgR4DP15Cd5ar9yVdAiocRgdhfgWeFnXHYrZdvIUXQt0iqfMC5DRS7vnFi8g40vBn9xCELBZAwObKE/jO+FoLMYJueB7bhL6
# DATA a+GaAatnK5xnSRXJmmCeI2cMjmpOLo8DMFmjpijVnS6kM1KYXqLKOlAQNJUFvfOcLaxXyoKKkuE+OIiyMYRyvWGzJBsySaKtxEsB
# DATA sJNKuJFHCNq9Zzs0InS1eClYZy1UaVx5/JF7lAhm7nY3fWTgHz7L4hBhN+nEX5Lu/N7mrXQLyCU2OTCRT9DFO+8qmUQrWpaKvQxP
# DATA nUuZELjjHthqmWyAw8Rw5G0vT71I1thccx3hdahD5k9GLwE2x2h+CatLPOCgXIfPS4iIOjjF6IvvmLAv266CUzAb7AH0FRhvkjiK
# DATA Fxeo3/bVaGj606x0U5i2YYtRn9uRhE/grJtcTNqOC+IQTomWhrzB1uY5CCZJpazFkYGcl4p9vdlpROwoMxwtU8B3yzoDba8vkHTj
# DATA ogqrOEPaP8VbSA80RKylFu/4u1KPBYfr6Ng7sSMx84SHaew68fgaMhdtkqahY/tfi0v8n0o8DeK5F8nD+BLeCHNrK3orOLF/Sbm/
# DATA LzjQGJZkBtwuTEIIrdHbs4V1rRVcfdiXI+TpU+aQlCQL4T56e/yh5xoldrlmBTTby/hd5SY3qnMar8ZezH26N0iHpTRPE8W6oHUL
# DATA EMwlHQnjp1cUauOCKMgNFZp0DCvGygeCLRtTJqNxH3VLgI7TBL0JYr3V8KeGgWz2ZGowsEsrIadQK9clXSzDjoUQRH7WcLwCG+AV
# DATA 2ATo45h8P5ou+qd0+ou4E8ZHdZ5LB/i+aQ++co8ShnLxYV34z1p/bHPVNhAXgVAt1A80/IyJm/THBReUkNqmzPfE1oYypu4H+MhA
# DATA bMY1CGMHk/UY/kQtA5UQiXSbFMyXzJsWXAU1WradHfKynPfHF02IaVsqpiN3SDoWr0e3V759Vw7ZcObD2CAePR8alKOno5yRjjBC
# DATA XjUUNQ6rkY7cfklCW8RD8SdMUbW7Hi6KdsoCEj+piEKsfaeFgYg/ZkiFJPJhVGxQiFr1i6jIACYSYeT27VscvhixwjS6Puk2uqmq
# DATA Qg3Xq62hil93KDcY5BRtfplO+imuRm1uCKXaJtxVnpeLyO1PFc86jA0CBCavYvsupbWtHIlaqWL3Mfdvx+4lOEX6vsTbXb/0r1oO
# DATA +YjVusQcig20KTlfraNhSKeY95u0ExbYHAQKARRi3nFyethue8vhJAOTzbqH0J8ER5neD3oI4fmS3Bk74lRUDKLMmxDdrJjiHlWC
# DATA R6iYPaGipwEGC04vJ+kE+Ch4IhP9QG6PfMHssRbsLF8NkR+rSe5S7PZBZqCo40sIsYdKXIAmiTdWGYqoP2ob6sDGYb9AvoDB+T4C
# DATA VI54ISLFCfcTnFXuCbxPRE5Y+CwouPoiCkDORb5wUmaIO84GY8dQ6bg6WI257j2XL7u41Oi9ayEJIjg+H34FEI5ADKBwYZddrwZB
# DATA VJ1B9TUNLljBJWASndqS0MHhpSqZ5gVvW9TZBdY42KbwYnGk0VIhb2np33rIl1JIHYy6JiScESgPu8PpgAy36mWHXQ11+/AsLrrk
# DATA mKImS1LR6dCUYc/Dh9vra7va0XD70Sfb85wQQU1+V6vJXWd3z2nQtv/79hh03Tcv6zoIUwbY5nrmpJ8ZrlPzEFdQ+lXSc5ivzvqn
# DATA tvgZOAiFo90hgB5sUM60hZU4HXK71y72ueshop8GTX9XiM8rh/jgKBJ9cETUbN7ClvoQyGOIjHdFqWupKNTjysjMG/ChlLvUVcOE
# DATA PdCUKYpPQTa1kH2lTdkaAwCJl/Ky0T6eVe41V7bbLFXot4U2R2rXjPloqfDKv75exgXqEipXNpttjqRDWVHNWhQz7lmX/Bd9RWyL
# DATA XnQO2kqnXn15h1u/v8ZJcdLKzpPvo3NPg+ztFYY2KqqVzRBgp1Lf9pOgHRs/rttENYsbCP3N2vMN6DIVhe9tUK0bsW6/If40b/NU
# DATA b6CKPVI1kZV74S0nsXwiyycz0Isy1u/vypL5dsPmchuWUaTUCyMwXY08c09QvVQWvTesxYRG3Z0OkDL3c41C1VACHSoX5+NUC+FM
# DATA gJ7F8VUOqtR7gdNrE3SbL7KzvCY5ZIhjlAYPBoaZquaHDXWvgoRPbuM2EEb1oDZPV1f3OhTM02TzuExOUI22FEi/xJiBJblvZFax
# DATA JqKs6xt9DX811ze31jd365H5tbv+5OnuZ+bB+qcbO7tVCY3KSSUdAM/yRguoyD1FwhrnCULBMikbdEIvl4Iy8Bqgf+noUcnC6wbt
# DATA gHT0xADsyZew1RXoAmq+QM4uxOCj9O8Ak1RaAKh4IRQfhVnvlZRp5wCTkGRKc+mnVcVaKRWszfbqJYI1/p0v+6NZ3gm4mwcvOTIq
# DATA HZWq4VJmclChd26gQu2iYKC7bLzMUCRMTvyldr/Aup1X1lkG17mkDevdgoCkkXYroW+c2kHRVJDVPD8aF20bkosZzNQlrcFEGE4H
# DATA p7sco9tdmbeEeQQCh9aJwi25HgVDMYBC7RcsCFiNG9ddDmS2wI4V2AcjDM05pxhUrNVHE5LxShYoqNg/7a9H+XqsebCAKOJHZjt7
# DATA yNcX+LWFgVScKvwI6MDc46bqdGAeOh33VJV87KySwPc+ZzNpy5jv8vyYzk9L7zJhY29FEvzMPW8tdxjqtT0qLXFGLgqdJBWdUcZd
# DATA hXcWS2ZDvcmvKkIQbqp0zA0EchdYrrfmgt0W7uruNdZoxRH4sYkRRiG4Id5ylQkbF5ZOqi2vIgxfdtGXYOWkacrDiLwkjfKjMsBV
# DATA X12thr+HlKR8gJXC47wFD1C6RXdcyacSK8nJC4cp4K6UHA7fe4nGCDrWyY6GYgwNGvcdj19xEIQq0PqLmI9jr0HnHfUg4H/aYK9U
# DATA +g54TFwXbs/mByqVMK6iPxWNGByn/YpuN7jRyiJIWBpj8uQpJo1bqfxY3cX8TyGxW7hwf4hK7MIHVQ0UFDJlA3UikHSqNyobyveG
# DATA mdk0enHbLEHxGo7cn7JuE6Heu3kTU4BzLm4hAZSF9zhQRSBDtsrzlsXbLM14eUQCXZbbSsKKk2Qsg/3wSyELuRJBASWEXfitSF0c
# DATA kt8Xb0/LyHknPs7riclnTiFnCzQGVx/3dPGhc73zi8uLhchH1O2D4xdM31XqyOZpT+ZrUN6JFiWgw9A7v+nI0iUidNETO3lLdzB3
# DATA 7hhzaW9l30sX6HgpI8QktoQ8acVUaBXA4S2j2ymewgV3rEdGLW5H5c0ojMzq23wAPfyw/wpCD1SPG7SoAmrj5Qgg/kEtt4y2yoli
# DATA 43mUdiej3CJoTyxueOE++zXcMXWzl74BX7lvMB/C0uUYyxa1djnWLQ83AyoqA0eWdiCGPQpbgAI7iSSBsDPlHgWug7BpQthroQ3M
# DATA vFHjEB/q4tZoANGU9jJkDh1qUyR/8s6DubOWMgE0sc85HmESeCm1g08gTaJ5Qa0qg7XNrd4fibjaY5CDQ4dYX1ZJxlqLUFbt9Xjl
# DATA dHyysmo7npglKChxeMvRUL0bruuMWw8Hk1RgkgXLW4fJy9128XkyZ8uhgOttNIH+XUrntfvFgoT73W3iUs2vPZj+KlQOYj56Wdnc
# DATA lPvlL6D5LTn/dKt51wd/ntqtRCNAYnhhT3sAshgagEWMMmU/SYS6rnyeKvYmipxlFzNvY8msIgU+YapYIOszJ3r+xh/+96/4f+il
# DATA Bef8K8r9PDf/8+rK6vurd7z8zys337/zh/zPX8f//KTM+nc+vVx+5i6oWvJgtubjNIdEzObn9GRwybzN9ejpbJI9BfyLkjTOWVeJ
# DATA U3kwdfOZeTxT1wtFFh+u7a493vqo83Rt92MtalmFuzXJxuZsdJTolQ5GR+RDCK5iug6ds/gmJyyWeYufrG1ufLi+s2sTG4OjKr4C
# DATA E+rjNXp6lx5h5JhOdXz3djEtMiRDELWj2XVj8yPzjXrvvtAf3r0d6Jwp9Wj9KU7Dt5Z2dlWPOptrT9CRs2nSmRDDXfrjrWfbm2uP
# DATA AwUaIvcVF8ZLTaAqckvcXn+4vvF01xSwNR2k3RezMVey9fhRZ2f32QeASRPfv9Yb4SbDDfTgPvw3GqTDo/b1bHj9wX1M74hQKNm0
# DATA fR0h8tRTDPJ6wDEM95fp5/2xfgKXH+vhen95/OD+MlYPEQobj9Y3dzc+3FjfpvCX7uhk3AdJAaGNNK4Rwhrdfv/i+ffV1vh4/dNA
# DATA 2UPExL57m8rsbn13fbO01K2bVGr90931zZ2Nrc0dBLFoQq8wYqWb55TRk/7JXx7hv9NXU36MgnHcfMXlT7MDdVT7h0rYii/U7u8O
# DATA 0jyPdtRk04XZ3p2NXjvXIVKdIoyaD6E2Fz6tGjqNlZOmN/GjZ08fbzyEjfjHO1ubne+uf+bYcMJAaS5IGvcdZoIQGVtB257QFxF+
# DATA 2sHZtOAGwkB1QfhFL3xrATy2jgBk0xkdJfITX2hg5I8y8XQ7684w3IHWKeDJUZjHjc3vrT3eeISzqO62SFnxGz09SOI8NEEv2N9m
# DATA wU6c3AcQo8+Yg+rX6rdQXRM/f45hT/iiomPPNnfWPlzvrO3srO8iCY4TB9tYEnqZQQquX2GIY7i0E+bkNY12qJEJDOgxwBPc8YGC
# DATA 5maB3pcJofGgfxvzQUOVQVgjeAGTcE4hJ81mfEGRbpOpAJpqhlNKet2ofaelWO2Px5Phj9PZqx8PZ4MfK3qxt6q69ePBeIp/JKrQ
# DATA 82bzRvId7hXctpsbxSvZIffChYJOTBhePjs87L9S2/cUrklao2GJUHKFFQ1gRnZ6I7x1XHrfOcvKe+9BdPPOrQWOwKOtJ2sbm6F8
# DATA PIaYYY3NCeR7H+P6qNWiw97vDVP1U5/9NO/2++o3T1QZhNtlTqjunjyjEiONc7rTcKuSl/OeVVtCsqa7qxf6De4SxeqkzaU8dAwm
# DATA G8pa0q1THjTjJEkuO/FBGg2q2gIureOD9Q4Az/Umhzuwqampdtqxkyy3bF9TSL/d1v+jA6DDdBwpYWmqyCa8ALvvlMRfeNY/UFOZ
# DATA o8YC1O2vbq+szGHZOEE7nz15vLH5XddDNIxPXo0lPqcxuShrmw+VeL217TZaG+XkSAkqD8TMI8tLeZNBR71K5PUqRPVFZuuT7Q30
# DATA yyoZgp23tpg34T+aY9Th288mdmZza7ejPlx/qPrx2aU7gt4SV4d2X7iHqr5nj9e28bpTis7eIbuTQMBmCiIpjVVEF46yOcgcc3lD
# DATA Huj9pJD61Z7csBK4c5K+yCwCvgXsRySxO3fKTwsSKlt9gVph7TgoUacdWWhq3K7QAMUmQVNWh8ZqMbzpt+fgNyl1UML5EsY/N79n
# DATA 0RNJnVW7ZHhsOTsq/AeZQuew16YWqZ7iSvL4fET+8g0gHHwoxW3bg9jX5HEEnm7W8kdEsfD6g43NNXVw4GXIJtgRSP7YXCIw9ZXE
# DATA kaUnAdxYEyJHJRZE1tfQreLI2Udu/Jt9Pg8z3z+NqJV4vPFkY7eIks+9LcPJTw+n2WTu6EJo+uhebfvcH47q3hDk7xMIdegMCVq2
# DATA hq2ar8wv+sj8NN9UiAQ4/ocfr21+tP6oCNBfEsPpnKmWt4lNHl7HLK5Z2DXDwlpugKBrpRWmxPCGxl+GxvsW7aXK/BNMe/TmLUrR
# DATA obsF5IxD4WtvteXhTGrMfdsGXFuwcnPgQ3GhpRGQzn1djgJbCglclfGnWj1wRf5fBg1/GRGAlth27tLhoAWaE8g5/U7ofUXWEtFu
# DATA Mj+SpYQ+X85mOXd7FC2T8gi78y3eOMeBmBSds4JrSJBt8ZqAbkhrkmshpdQ4PYMywK0IcEsoqp040IIGujrtyyK3UaJsXOeTjZ2d
# DATA jc2PindSp7sMe9XW/fYVZBZ/4/mEcLtdLBSTlVg3C7oq+F1gcdiQBD3QCXxZO8AFXChvSt6HLxDwhJ8C/5vD5fT91ZmTR+pfia2t
# DATA ik/SAaYYhTb2BMSvQQBnNB1A1EALLZhVyFW0xt/zuYyzl+kgTiqAN201zYNR76yOVT0c4WuC4sRUIF6xppsaRHHbdzB04G88Fh5F
# DATA B7rvt+3lWRxPavAhgXzSZ++gL5P0FLPcv5oajY1Uz4aVrDtnw2n6KqhbVXxYTePl1ayBPgb0OajOSU8TxhtwjvCiZ1MKXix0kaob
# DATA Ki5RqJE+GjN94KnIpixcXQPbQt49zk5S7f+dk8oSdxMU2tPv9/0MM+5b72AtNFNahBqd5qxk3+M+7JeMBIoK+FlHJQ3vUCPtWNiu
# DATA 2KWAmUPVj3dE1YwLylLsozfZ6gnPdb+HMVpghiI/fRMigGh7EIiK81/gWsU29qCyfVdNak1WUjWoy2Ix88vq9ULtaSWj1yaYXrys
# DATA H/y0ScpTg+urn8NmP0lf9U9mJ2VA/RKV3wPk5wnnmoyxSVcI2reamc5VJdsAeqE7q7furiT7SXIFYiPjdxnLD2ePlqkKJpkDvM0m
# DATA gNe39D6lcGO9Ua3d9zI9xA+c+OJBDxHbYLu5Ycckr4gIJMKrCcYgkVXIhe3TI1QPm10lf0FTEH831I3y+MTwuTG7UeLnr1ZWUC2r
# DATA +8G7hH/6xDuZg8hy+QnS2Hzn56SVvrhwuqMFexylsNSg2TVZVKanqjuK8Dxc/3jr8aP17Q6Aa65/uuv1hGYOIkxq3ry6qswYMfSp
# DATA F9ooQ1sRJvX2yu3wqyD1OI/Tg9FsaizJ+GtZNHDR7GMCkAwN+bxNF9LPba//u2fqcvlISaofre9Y8dHBX8l5d3ph+eAJNwQvRtAB
# DATA obxswjbN9nWf6PvI0DMW4rbVyjrSgds64SbdjBcaDYjbat0eP94A01fR/Gwo6D4RhFLzhifr6zx654qEtQxV00SNfAAr+ENyIbmQ
# DATA d5sgQU+d532rDkN/RmJGaHUrWPBhwlr6CFhpXRyROjpbaExDqqYe/XA2mrI/b2JIQ+HQ2CjsTGDrVdAldrWUJFZTKc64wXvF2ADn
# DATA kw3XLZ7NWHquiD/PTqoqrP7+CnLc9vom0AUpxoX2Di0feh+ZeVdzoZZoqhW29BjkP7aq8jJLmcrbJgY7nWvShMOVaQJGl+9ubn2y
# DATA SZRVS1Zu58V+y/d09ftm6xmD39mwKxVhQtfVDui6FtNRVKuvaJ9dRh8W1DsHNReoSIIhhRQOwZjgKqWNDMclkb2gtLmENvuTbTlY
# DATA J6xl/dOHj79yNTerfiAcpkTZzcpfGjZeSPxXh4NZfizkGTPfBb0xTyGd357jYMA7tCaCBdjDIBvmioN00KjfZsB+oEIdgIXhTFt5
# DATA pnZBqpYpb9fiOhDlVpzohDBJ4dbJ/VAfnPS7PB2yMyUrBydmNEkxhzTuWuGGKBztcKoaAJ0KvoxN+M9tRfyPM84rxFvI1Fb3ZySg
# DATA vq3QvC1+/OaoCXntNIsR/SumWw2Hq4e+5qMtTnk+6Xacs6sOUj7tlBxnS42a8lXh3DLBpDZLDH0cjG/KmZ3AL4LKf2fC3539zQDd
# DATA VdrdRMd49sJqS3XS4O5nsnhyzCeNgsIlC5mE4XF5JmFju5hkXXXvExjp09EUdWoUpAmAmpxeixtSNzmRP4vft9xb0AQCy8dIJrlA
# DATA czwa1xJvw+uybliSw0YcG8scTlVYQaq/9MCU8iz67ivlWpx5mRrVWZtFZyDTrvjlJ9vgkRWHHszovFjeZy//M28Mk/7Zc3YG5RMu
# DATA 8YOo6MvcKvVtCgtku9vrRXOmf6YACx2HHS3TSHCBwkMgGxOVotTowazQ4bCpTMlN/ZeZZgP6d2c6qjEeJIR1qb1XS8omsNrRBRfz
# DATA bfx/yqw2YfAROzBcUZN0IrahuXUz6qT8e32U9fcsJeEuABNz+Mty6JMFbE4lBkEBGOu52jeIfrUqneuuuAktdXyv7XSltHSvf5Tl
# DATA QKk5/qKZH6c379ytldf/VThDBGFn3sJBIvS/SzhNlKztO3SkuOYuD/ot6Af94QiPoOPHIL9QP5PWXN/MRdwSys+hTVrp9rzyM2K4
# DATA 5uP5fTzgUHvpEHKi7qiQhP5u3daUzHdF5fXBGlsLZXp9mwmyR6c5G4NbVQ0bnv+RndkG6XkX+I6UVGaCVr/ixV/M/aako1+79827
# DATA HH2B/SDOnOU8xeHwHlBXK/qrJgN4g1f7UrHpEo4KLCF7JNtc4rSKjMWjJJH9MzoWRItxlSzGX1qCUzpe1CHgD09cd8yN0t+uGO2W
# DATA uMohzDuiesV9o7s+dzf0zvS7dkVL5ov+kDSprIlCZSqqoqydDV6ru03R3nY126d9jI3jQx+uDPEHQinLvSHu2Y4vYuHzPymElxgN
# DATA IRbkidjHWXMfBYw5VIAVsnbuC0Mw9i3ng4Cdq7QNXA1vvB+vf1ocKJZbKASBfNN3rbrSap5ZPuoPI6fDRcNYyCgWsLFjdZWdxxKX
# DATA MkTKni/gaAgMR5EHJRUPRmcAWxbSGtq36i5j4jQdCRgzxEww7DKwgRsvV3UCJ1eRJPWXVEXBL2kdyY8Xw1CMi/DceTNIkIf14Zal
# DATA vy9rEYShxoXQiqfZBAEU2f+jBCQ5zHY+eLbzWdHPw7nVS9lWIgpVCdUBHV1ohqQ2YjiNA2CSFPV8kr/sTqaFt/QYA3KVzOJkpuBX
# DATA j9XO+OAxpPNYXURDV4Cocq4WiyTBUPMifm9+UFisaiTryyzS1TNtdFRfEHq6NsgOId6uf3Q8dRltfpY3gRIrWnPipOpRDHb2Kk7C
# DATA SaAJoKp/wFpgCqhvPnz0+DHnKZjlWQcD6wWUzuFsyOgfZktxFYT5qDZIOr2pthUGVelOmq8qs1I7DTTTyRH2CJPdU9+6HYRxNL/A
# DATA YaMzFg/mvJ6p9/tuK4AJAzHebaeSon4U5h7vh/BHR+t69VtaE3iNf3UCSlTdYs2pAAVjVunDC8pgWHeqcUvhG13sJqW6Ls0xzGDX
# DATA PTE+tWq0qNY4hwUgiNQgru98tmPg1pGmmV9bTze3dneePX16UbGGdDD48NS66KIKmj/FR80Ta0JB+HxyagQFSz5VhwNmytFe6/d2
# DATA J2rmYsp7amHxJqQZDvtTrIN6ZW13Y2uTdC07In/twocscEbmHq7S0zP3BAVHs7a79WTjYUcbgBW/7TzbXPve2sZjcAGXfjxfy3Fb
# DATA 9MgVjh0tOylm8M/C0ZMbBoqJ350Sw5E5il6V8pixIy+fs2Klbmm51/iTVR8W1QZPVh3H4qrOPUYG4KmUQaMtC4XK0DFbKrLYq+0n
# DATA Mm/xzEmjgHca2Z50TbsyN/116mgTt/eJIRmE2oFIeUK8dA2fxu2ECIUI7w9CEZKpwVame7kcxdRaHsPfRiiF65xDb3R7bVEJ+j/S
# DATA cxD7/cpzNizo0tbjg98vGCz8wdrD7z57ioCnVcHPlH2mIKyHVQAjAF8ES50id+Athg5T4tuCJTqoGpikp/qaXXJHcG4HFhHGc/Wo
# DATA uvkXkflFrl+bLsPA9VuHpW6mJC1nA6WT7jHYBVpl+gcuoPoqMWUqNBLvQKdgO2hUCHXGpvu6dQmMl1NQKfCl3nYUayjuuDJEjGow
# DATA Bvday4fYcZTakxf1ojpCTwhO2X4hV2wtqB3g0vPVA1wwSRbXENCJjaUkY3eWPQXOJZlCD/xtKAuXHI5g6SSQyMJsWI8WgKe/PN1I
# DATA 7tLTIvlEscUqeXhi5kldTL5cpWqxCcEfPBWejUcIaS4oJHICbjWZc9gFF6lH09GLTImQo0GvHg2zU8ZVrDOLkhgReh1CpG3JZh0o
# DATA 6TpFH4umHTFPsAiLRNzLXsKcim/clwvdSmmOUR/22c7u+hMhA+rt4TShNktN4GSBCxBOkXBr8AK8uRqMNF9ZcaNxylZSqHHCW9oE
# DATA mQRLujTYaK0NEW1Fq5qOtirpWb0gfEli1gpQMk2JW7hlip/T3m9Fb3OUZHYTkok0f9L7jJxlHB4an56eUtgZbEJFtsI7FQqoF5eL
# DATA PWaG6M0v7gv1Nx8hlpc4VwuIDXK3Q+6IQY+nTclT2an6Gw6cM4VQZucdzKBXq14UPtsxHW54gH9cyLgps5uQN2vXWw9j70Z0c94M
# DATA mi+ktV376zkrJwHvyCEzCCFEMtFhf9jPj8vomaMH5RuE8HLNDmDz+9IX7hyZUfGoUMRxDsQSIcogMkYtQlEKTQe1jy5FRb5Nu59H
# DATA kzhJD+iV7giqSVQNgTBgTt5H5ep6anz942IdaEPytlPxBmeoonGj2uMq6jTrSSBamW5ELqOREYe8yHW7/woJBvM8mGNm3laian6g
# DATA TsgQfeVK96xUSXLxovlPv7iyBZArqJccx7cXu4mcuXSMqRYTrLqgT0YSt+Tk3cnkC5jtsLOekIqIj0UrFhVNwrK7GOy+RqaXuyAk
# DATA uRcv0SFpekGBPowh50v4sAr79cj8oEUIiPzB2YLFW0Cgx2Kllwha5IVvEVzctBqMlfKg1SyVlDidsR63rvMyN47d7bXNnbWHuzbC
# DATA SAOfhwzi9lKDUmnp7cm9OnBFpPpchG+4G3PpMsJo4FPBdqyIaDnLXK6XvRorURajGsU+KOSfdhadsdnp4gnnRlfyluvSWUQ9Mu8i
# DATA 0p1NUIfVfisZiu1ELzV3gjYdvlfn33b5E22YhGxPUN74k2DShPB0Fq6huvvmPmnPu01tM8DNYucd3+DMtHUH5qr9aV5dUZeSQQqi
# DATA s1QliFTpkuTucMSAS6gIuK6emXsj2RgFaylxEnrgSf8IA7jco+V+uuQaxYvjolqS6k1/ydu+PWNHmSPH6eWFWadkVjwRQTuIuRHx
# DATA SOVtKNzHK/TTio1uK/XIPwC+KB0+JnDf8EbJH3i7unzsdlsGrtfYVdtoQMZF+TYgjIqe+kBwpeJowVRP7Zs63Y17iU4KClQvnocK
# DATA WlQPHhkcM8673G5zJl4sUYWG5zJDCQxAkkDs4GJchW0zD7e+t779GYSBf/h44+FunFTRLTPc+cerOKziShYXh2ydJSTLnHbTJ8x0
# DATA xB/PpZaVA/46eSMXuGYYjpvSt5yLLYRzGuBN89Px6SgwK0tUHlHWRtjSrP5MSoUfaazD+fVb0j3g65q0EPpLwZe+c76DsNJIs8/Q
# DATA 3rX6nSg+yobZBLek+lCfE0/vYzwVW0ZgM76Lc4SRC31LVpfkaT8dUIS0Pq2OGw4/LI9DMy4Z4aivy8QmG53DZcKTdQffUayXo6bR
# DATA MRaXD+8i84dhEBzmDy5XocCtw/4Eg0yGkIiJS/j+EtrOj0XL0/56i+J/aRERJSgGXBuLTVd7XxccZLzQLWpu0dCtUPjIWwIuF6Fy
# DATA H5BN0IksuUbutjpLRrLgQAvaPGfBQXoS81sIjGL9liGLFVWFQsIW65FjaC7rmDN2VOrpXwVlnOltvQiOl7ztCELhwovEAVT5GAKQ
# DATA WjZ5GfLldSH4tM7AZ6qubXGpZDJYSZkUKxQhuswM4M0MMsHHpnOgYyMZFQwIHD8vAvuIcQSsIe+OHfgMh58ZziVZBmc9ZUwNcYPy
# DATA 8TXa8UQRzdEJxodgzLkGBxAXNWmCrETigOhxUDhyVYY2HYxGg4ArvO6EVYuZR+QFQF0zN+5gQIBBCllYHwUQPus7BljOrpnjsOMY
# DATA 3OzZsKqcgIs5X8Zs6UVV1zb8u6C9VrMSUlw7Ieg03TbOhWuD375kYApVSRWSMAXPJ5aSV/l2uWdUwTZEGInQYyHKOTeRJWGv9lsl
# DATA WaTM/V8HQL3MWP2ziLHKdEp/519WxCQHqfcCJIMQNgoUw9y9guFcklyY3rkBMy5NEIXE831JJkQRfrZ/4cd6yA115Q202Ca6lNox
# DATA wAdC14zAKMIq1HKxefHOk7YusH9JyqIpgregHD53GigLfdvbd13a6ot9ZSL9KoSHuv+5eeOE/5V2oHKrhO758IyRl5zJuMpUVwA9
# DATA Edr2qN8lN+J+T33YP+xnEzTliJ+MAKW7X5u/SSzeJkim8ERU124X+XhiFZl5NtB6/dqC/N6jN8T/Oelfk4ZY45ESJJlhmW3BMvEr
# DATA /ca5ueseBeGwLg2JJQEjHVws3Y7AxbKx/S8ykCB8XJ+C/T/AYSu9AHwZ1ncTYiWRl47issCR03SirjgY7w3dXI4K8BjMuahg08co
# DATA keBFWMI07Pu1WlCs27fd/jJAh0WSO+ex3ZAYPwwhqMgqpew+ypqTo8HooBbfiJPkog5YfO1BenLQS7FYy88kVtdZQihSIKSJ9RFS
# DATA hhmrvYrOOhXOUE78astsUhvJ2tKSazjsmSMaWxrozyNyZdCbjrJt/j64KGud3bGk54VDKB2nHjNDJZ49i6jmgp49jhnCaGmuBTxA
# DATA Fg0tl7ruy7oxdhz7pHhUyCYopSemer1YSIlB3oIELuZ7TlDYCvjVlQlfZZvPka0CY7JSlZ4pKVRpdENM/V28ilHBulEcdmxrpbev
# DATA IFh68etyL4NA8YXvTR+tb65vrwlz8Vd6dbrq7cJa8UWPqFTixU1wUREVIhvVoM8L+kfoyjAI51LRE/GiFxvwLCq9RybOlbGqXNj/
# DATA qQqwx/gJdJ6ubz5y8W6tNaNEBr6M4qZouAhsWBzfgj4RXNNC47T7O0AK2RxNYk65xT3kiEjz4vmFOOM1hbVBEPi2fgbestSiHthb
# DATA 2bqZHvU63roEPfX5WkyNz/fCsfFIsgl/kdzXcrX0mP3Lgddjp7250qSNxlqUhfGmsXbGutcH45vvHPpqvkbfv6VSwFUIeNPoXCy8
# DATA SStxS8Y6HS5nhyxVBggGXWBtqP9TIuxLN4+lkhcn6AhFedaba5OjGUz2U3xTE0DP7XiDGHh0MBv2FBuPFPlLBxEQWc0uciSMo9k0
# DATA wnkDvRbkRIA+502TUBdqBozxTsqN1eJGQ+KugV6y/dSoCcq+IGmzsozAWVGTkKqZMUrUyu9o9hoTcupcrD8sAQF76dKEkTAxVRun
# DATA ujWYoyt8xttm4Q5q8twQm0jzYQRY4+/wH/gyxw2TBNNUw+smdLxw/ukAF6/86EqBn3HHC045+NLJ4mjN/epNiL34ZbQYqn+zCrzS
# DATA 7sbDpmhZO69qLD+cqc7kkdidSBSDU1k3e99sBeiFt08L8+SInO4E1J3ZqpdOAr8JqkqLVvz582znbLH58ieHv0/tFPai2VDdzWAm
# DATA YctA1bNcUdWSOXEsIsE50aYR/GFNE3ILVM3KeNJXR0IAL1PTiyAvJwXWsTLPjBXABSl04DzGEsxU8G+49Bf7o+RiuOe2AWcgn6rr
# DATA /KTQoVVF8s1xNQlnQNVmk6wIyH5zUveXwlZUpwoA8oeLK6IPdTqoyOp0YDU6HfZCgK4p+XZaQ56jJuwbl/8fcBVcf607bI7PvvGO
# DATA /7ei/nf39m38V/3P+ffm6uqt27fe18/o+erq++/f+Ua08o2v4X8zwI5QzX/jX+f//Nxr59dJPXW9tVq/jqLG9dbe+fV+73rrOgp2
# DATA U0Uf1FG5Xr+OWSrU49d/++Ynb/7i9Rdv/uz1L1//6s2fvfnpm5+8/nn0+ovo9e/UX79986fqmXry+kv46/Xnr3+rPhYCD1Txf6rX
# DATA //T671Xhn5R8VY/Uv3+hWvjNm79WRV7/Gl6pRlVRVeWvoDX1f79ST3/95meqGz9V//6N+pBqVMV/++av1MtfvP6iqZpHFdb11vl1
# DATA nUNFdeL+td4IYSAw6cWD58+H9+GPaKAkrPbz59ezofrPg/vHWdp7cP8km6aYoSjPpvAStWf4Ht/AoYXHL/vZKcAiqT+1Bg0en/Z7
# DATA 0+N2T0mV3ayBP+raEtDIlbCXtVdtXcfT6bgB9P0lfPqQamnsQN6y/vSs8XQ06HfPvAZYCGvkk270PM6zweHz+F5EU+4/nJ4NMu9Z
# DATA /+TIeYKucq170ejgB2r5+dVQMS0ofJDmWUP1RTwCUJYGiVn2aXF2xCbw+r8WveznM5R6p9nBaPQiwnQ1Sso9OoY7ybFiJMejQS9H
# DATA Vjg9VpJxqthilJ+A4EyXCUioHIG2Wz1XbOkkytIczBPTETDFZrQznfXO8NvRpNcfAuwSI8kqgQ5E6hMAhMRe41Z/8BRU2yDeHIL3
# DATA SPTj6N/N+tk0ejkaKNHv/jIVuo/+OpNsAMPod2lkqruH8Hs5zdV+yZfheTN/eQTvUKaEsieq+mX18L1XJwNsVdaEq5QfZ9k0VB8s
# DATA QbOb55f8DO18+jNaCoDQLxT5AZQAwT6bPLi/TAXVH3gS4JhAuj/cIqgEgs8lqcDa1WEZqCqxTy/6Y9mbbwL7gkI76gWsDu+D+8sp
# DATA nTZoVXx/ABcLZzjWtAfVuKui6himL5WM0k8bg/SApuUJyE3qcf8o5c0HLZTUt/Uym8A5xrpEqVztn36Wm3I74xQOcMTP/eKwBU3Z
# DATA bdiPp6PJC1wbLLqs+sOTCgMm0bAHn+r5uc+pmexUjMHWA18QZVp9sHucqiUcg0xsAtrUFld/K1lt2FTVrz64P1bFsgi+VcfjLDpO
# DATA X6o/Ri9BuwuZ/47xAEAqR3wNq4FiJuzUUTNS36prM7rDKUlcnbYpHLGz0QyWDj7Wiip9dFWr4wf3e/2Xtt9EGnJ/ZxzMplPvwLhL
# DATA 8YESMnUzB5m69wLeLk+0VwuYB0fDnjrVTn2LLNqy6ivsc5rtwLTzA5r0mw+2JtG4rzo2G6tJUqTlcKYmZTQawHTfhOl+mA66MzRH
# DATA Hg5GKP1nKfl3R0jto94kPQWKA359MMNqvczmiHqjjJayl00BrVDdIJTsOoOzpToOdl8ErkEgo+5Iieh9UILTrF9m/5nxLsOGe3D/
# DATA UInysBPH7olSu0tOBWh96ZYA9drcUao+VfCBXnunKzYRGXyzhpT9j9KT8T2Q11+m3TPoUPT//lN0qf7TquleLwNRgvPEvFwxfdvs
# DATA H7j9H7j9PG5P2/IKTP4d8/irsfj5HP5/IAb/jvn7Quz9ctz9a2HutCPl8A1D/5dzgpDgz+editKP8kxz0DXNNkmdp1pE7q75pxwy
# DATA yDWpHebokAMg1djVtkK1Ci8RT0G3P0Hmiwo8byJwelCk0Sw4R3XaIEsnCOV/opi22lmDOjJgNYj+SdaLDmb9wRRGAPQxpyGrnj7L
# DATA 4ROUtnT/9AigBcvRu1oeyH2BgMSB0XBw1ow2plqG60Keb+D4MHGKbaGm2Zq1tSiQ9oDDoHoRuwiL0kCxAM56niOOUbSTZS+iH6q9
# DATA As5a2rhwnA3GqKuCTkbp4SGsEggk6WE2PTMj/Gw0m1gezUNTkk4eTWZDI2oegLNTNmlG65xoCKYUxjEbg7QCcqbehbDHc5RhVAFI
# DATA oTACIUmRhxzKpIOzab+L0o0aWzaZgo3/SA0hBf8L7doGdXWPs+4LVHmiaQfVnk5n/vtP/recxwpaXvQLyrujsaoH5UmxZs3oIax/
# DATA hHZ5RLxQAzv7/9h71yZHjjO/96uUQ6tltwhgUIV7N2fk4U2il6RoDiWGQ9SLAlBolAZAgVVA97RmJ0KX3ZUd2jhy+EScjXCE7XDE
# DATA Oe8prWjTlERF2F+g+yvsJznP/3kys7IKl0b3dPfcUiLZQKEqK+/55JOZ/x9SrsLCE4jqMV4RTamkRjpQ9rhSWw9j6osmUYXtQFBM
# DATA YChL3s7ymFObWHBh0zN0h8kRjw8GqIo1v/d2cjITMw8ZKTvLBlRjsGOtFDWpp3JLBiOcokqtHD3cIJKKPk4yKVrsKUzZxH8YRfO8
# DATA UYeDAWz/SYLGMBjw9SMEFEMhEcJLnJk0eiCcrOZ9mPB9Sy41uj1KuciQl6ZFIdA5IjyOdCdB1ecD9DbxQpJAQdvNhXJsSZWbq7lq
# DATA rbpVRo/IWEQSTygwkxUjnrwUCvI9irHZuJRB3AO78YbSwXg4XkIllMb6XOkwRBRr3pvofGTvAYokxbgYUd+iqiu9B+e3+DepUsra
# DATA v/I0Z7fBZqcZzo5m8q0Z+1ex9a/B1C8aTWTvf+dxP3lE5svPgK/pcy2t0pUneOgxWTzJZFLtRzQXjpP0IJtS0OMnCPfxNEypNhzU
# DATA D7HCcZTC9XNwHKZ71eo8nEfp/uEgmdAjconssv1D9F8Hfmf+6I5fa7c8+QVh7R9ilzl1+SfVkzScH/SpBj6sUtqGT8LHEkw8owYS
# DATA Lw6h7V9dYuso2XpRNRmNKEEHtSCIpk/CgzHCecz3DMEC4UZSpco/eDijtnsQzB89kUpSiWfz5aIi+7cqeAJjzWOOonqXvrMmfx8P
# DATA 44yG4VP6mV89mkSPDmm0OJpVecvfwSACJvrwp9Q649FpVbUvfZnmp2S0YFw9aDbnjw7nYhwcUE5Qn+n5NR9/D6UEDvz5Iy+jKc3Q
# DATA s/JvJaPRecwWxZym9OrLqjTTcBgvM/WzfKlQDKQ8qicSp3arfkhTqYzCmSfMuz4sZeMBJjAqT2qmiencya88tqJJ3dQskx1TK9VB
# DATA BfVjtlCxlzuLhnex6PyTxysJ5eTbAUgVU0EcUMlgVBk+TubhgGaDB7VWS6dGzQGpcozIQMiqZA/GGIHUo8WLXClK16SKlC7qClO+
# DATA dzmlZnFavPqYmjZqzEGjVKh8F9V9+VnXZSqaJxIP6q/3fsxTJB7GqVX+ZN+6iKJMfrK/Uod5Jn3g1+vfLlS6NlW6DbULr9/fvR3n
# DATA VRc1t9axKq6ubA2diFL8K9ZFib+KbkBN81BFlT9LJa6udiLU7KrZOKUvB/UnheDIVv/JYx25+hOTIVYu+N06hU2VLf5ZdMCWEw1T
# DATA T3h+ZNr3URoPD4+oG6o1OGWFZlKvy901TpJ5ZlNnwMF0EEq5/duhNinUEagLVP6Pt5aRTp1fC1o6VMlAild0RKP4YzvgTr1uHql7
# DATA tSY98mTsV8ZBZdyozFUXXl0kc3p87EvvJ6/D/ApmsgRUAWkZ4910vhfUmnh1pV1rHZ9UWjV82acevd5UMVV5sn84IUuIqgTcroiA
# DATA /EpdApM1KtVavdGiRw+n4SOVBr89GB+qSPUTap9TSmiDIx3sFjlfutNKg6IWcMYjan73gqhRXIIWsrP4bn5zQ95ML/FUrlOIjXKA
# DATA xSe5ZTxBBuuktTuD8ZN4elTJjo9MrWES2qHVXlUFCZeL5InMiSu8z0BGdNVUgIvzgzpV5AomTHt40qt6bfTpJiIySNkhXVhXywMX
# DATA u8tp7F+cRNGMa7Jfa5Wqsl9vmW7FZNu6mvukxt4LycuO5GVT8jJYzUuda0GdKsTacYjmEsUEcb/A1gP+Iw0vUEMr/33C7pALc6Hc
# DATA Tje93Qtl5FJe/bswgX9SNj0OjKVyWGqWT2rwBj2GeALfOIofRcPDn1XZB0PpPkSjrPoo5UMQNyinkdEbumjTLSCdHLIMQY8RCp58
# DATA UiOTJtGdY1WYgW2UXbHXo/+YPWvoe5fTWXbgj1KP/t3Uv3ED5fC9GlkO9BpOK3ex2qzJi7TZooYgd4/io2UaGUMyvzoI2RtqhVPr
# DATA BmnePpGqWpdfq6YSF9eFbul5X9poTRn8paxp1fNqzXevr9PqYe6QilHYuTHZmUrd90r317JjyS/yqDMs3kVZh5J7vENZptGcZoV7
# DATA jQrVcyqUvXqFSpa6jTxGT2qDMB0+tkYWa9Rp81BfroXZMh3hCPcF9sV2c1Te680PMPuvDsbxZLiaTL6lBvd5pTZd0qT0sW0g8BUK
# DATA CL/blacneXiCbfm2NdBb26bWm88t6mSb9G+D/m3DtCqVE9fPQgGwz67YXDYY6maAQSCl3lDSfDBbjCVP9oLZvqfTsqkkglWr7UnN
# DATA +E3LdZ26AUoWOglzi6esAclAM/BjaMWojw8IEb5Ka5DrdNG2+apnD36dOq5TeuLFLnWUMlP1OLp7KbQShto8qcG3YKy94CbrJd7E
# DATA izmrJqIeW2pivl2iBQZrWyCHJZsBHxc6KzH37H7eU3VuSx1QKePxo7luRmm1hYZ0RydjPiyJ3uqAJmXci+oYHVBSFqcmjTwS1mTb
# DATA esHGrrW01ayaXyDdivZFrrG0m3bq6oe4q8oLOOotuR9zEj/ewdwozVGo56B5UzyIHttZUp6P6eaom4eMuzUpFJpeHllGlIl6fYdh
# DATA Qp71Qkw3aD64QyUp1A3PfAvwDTbdaoOwx5Rif+3VdzPQirH05tbArH7KaHCfHT0u+Q2ogYRHZe+ImLZb6qYpoEAmkWmxznTbq5PK
# DATA DU2zH5ZsW92SVsbWkl1Q7sLFIFBBejIpxCMHvjXP8pvcU0pTyDO67LwZhtk4Kmbwj8fxcBjNflJoQP9K8IDhbPGEmttj4wd7xKa7
# DATA PTfC/CB/X/OCpm9nZXdTwy653cLZ6Qnc0E+wNiKlPAqn8eT04C0ysRIalyufvfZ+3Nd73z9IZslnr1Wm9IfDLbZ5ysshjcPxJLOy
# DATA Kdi9PipfyuOSV6rstCrZ6/qdXmF2y01YTaIuaq6HxdGRYxyoiU8eYsMe7tcZnTsYgOUq381jabU+qw60ML6qGwpuDZ6p7OafpB47
# DATA 91aXZqIbqkNtHk8m1TQ5udjKVjb1IpqbUtfdaDP/CZ24af9N1UEv4MLj8Mqt4An/pAuOushJOM/IKlEf7Am0XQN5YF6MK4uhTMs4
# DATA Lw4Qm8I4ulNlXGyztZ7UKAbRY+7JpQM/8O9UfR4bLR+RZTSIzZAsF/Plgk8klDNL5lS8S7+KZZs11iyOp4WLJH2sh911tqzUaN3R
# DATA mQr95F9Po2Ec7lkmWpu6tf3HG50Otqeh0Ubfq7wKxdaibJLV0Ykri5yiwHRXssmuMzw/3Tj/LDXKBmaudlYW55PG6dLivprnRpcy
# DATA xrSxujk+9svXTyEbWGwozhB3zJYVg2HztDwYaR9jy7JS9IP37LmUXT2DkvmszdjVetFscL3gPKxoK3djfNgtI64XHtV7eeEUJhSB
# DATA uOnUVLM4POye+p2Ty53ImvkPd+RUlUy657ykmVXTaLgcRMPqNOFika/UOtatiXHg36l850A2fdCHcIR2E87iae4yysf5Q14Uidf8
# DATA oqMhp3N0W5RmWNGLUWWHh9jHXJrK/LBcvrJSZ/UKbAWouWGf5qcPzWyjfNOTJ4UVQ71rCzsE6Y/3aDqZ8don9uUd3LlzcnJSO2nU
# DATA kvToTlCv1++oDV7YQPRm8gg31r26127SP7zsixrvyQZA+s4XPenI8u8pP+cH+DyiIYj3TDXqjWGzh42P995guRLeLfSB3/b83rgR
# DATA HHe/HzSP/fqY/tv9vt/+WeHhUTBqjBryMKJYXBXNaISMnj6RXZrI02SeU5BM1P42vjHfjEUVt3+KX3jfXL67Tm1+MlftReeDfEeP
# DATA 2QMQDXkt/NRswLOypFf3ms2W1+g1vaBVnzTqged3G9VGveP5zUYxY4btYT+qr+Zqp+E1uo0f+Z32JAj8aq/lBT49Xu8e09/3EXSr
# DATA HhSDikYjn/OYpwsPOf3farZa9VaUX6yaom+svBShdv3jZuBP69XAb+KV1V6PI6Mi4vlSK674hiCoe0HTP/aDxsT3fa/V/VHQ6/7s
# DATA g2aj5zV8qj5Bd+LXO9Vm50dBu1tMXnfQi8JwJchOi3KlN/aD+rTartM/x/jYpMuNZnfs+3S51aJ/juljKeb9dr/eHK2LeXNjTVXb
# DATA F6miHuBk4WPlCT5QNfyQ5/cHqrEc6qntwbfarXa/gQvG+0SP8P8OjUGzeiU4+FbkR62oc6h8bAffavXanU7rUCyMg2/1R4PuAE+w
# DATA 25l+HrYbwfBQlvcPPnvtQXSURN4P36PpwifhmGzPyn3ePpZRV1jNojTGs7pL2+l2dE817LYkkynv0g/EmvSCotO5K4aAud2MRmp+
# DATA 872I2nQcViTo0tLcYdkRBuOs0qk1j08qHXGEccBqp9wu0/ut/i2aqRZDLDvKbTNPFczqA9qHXhwnCnfNC1almJx8A8afQYydRI8v
# DATA sTyQrwWIB7BkFonTqn4548aDi7a8EaPoFahvNGYLqa2sJO0i40559lbqGJsNN2mpPFlt6z9FU//sNezeo04iHix4J/mMN0B6fwV9
# DATA Me/uPbMFsvb5MkpPH/C+gCTdy/ate83N99M0PK2N0mS6t/65+5MJPWo9q/by/U10CulF/QxaeA3bASm2PLf0Xvc+e+3AjuA0muJ0
# DATA tmDHPgjnexyoYYWznPHD6LTijcLJBJV733uMA//0XwlAZPJ5T9kDiQSI1O9RVu9ZkXodGmX7h4YqzHQVeulyMvG+6+1JLGrjMMPL
# DATA 9umSukJByZUDKwIHHo5+ihYBi+0fek9wVHkwplipN1wmRDz+xE41H6qXZCtU7GP9eCaP6x8OVV4U0p9tSH9F4o1aMjuKR6caW2Wy
# DATA BVts1qRlhMPdq5EMT/cwed43RRFBoPav9j577Vvi+f3sNQoaYkPRBIjWGu5WpzPoRnw7LAU5Tk42hinG6KXDnC2ne/FwP0/Nh8tp
# DATA P0r3OMzPIPpHv9Z0bhYeHapNpHsi54bARc+C3vTZa/h6h5pzPDvUx1zkjMtreeyXKaL/w4/fr8mOyx/w8RD6DvU2701o6P0Y4fyk
# DATA 4j1GwE9QGPJoaDckefqdScR6GZ+9FnI2hDXs/oNmTTrBNx1ftCaKMS4NJvHgIbUpbD39JJ5GyXKxt7ePNo5IpdExGRV5pCgccN/J
# DATA flVZIVHB+oYuBcwm8HI7n5IZNjTvjWZIOMoGD7AQ3hRCH+8cU6TfV1orFEa27E9jKsiKFx1zsd2jx/hjDaox9Pdt2Zi1p4qaA6Lp
# DATA OE2FfgR6R7w43dun8Ge44YmK6l8hej+WAxfhcfQTimSNHnwnHIz31OZPftGEjOYsFDE67l0oQviK+Pz4J+qN/0p6wDjjv3t8A71R
# DATA P/fjn+hSovzH7njocu5L+HL9lJUs+f4ajSqT5TDKVDTyDpF+pfeZTXKL+1raHiVsbX1D1B5wo907hVqneaZY+fHO71LFfCDJoQ5G
# DATA PuO80ZNDHdW9/PE1ZcP1Be/TybmOrNKfd8gOSoDcRUY1TW33jhELsIPvemtvP/B+XKvx52Fl3R2moMgCzpBMjgd3r1ZiJNKFLELv
# DATA lj9jstXsQ1/Oh3ozeWEDv8r3N9W29/V73A/lGQmLt7Rnajs7zoSSQXEc1biFP5F/i9XbLHgV63jyKK/gfEumi41+MpliHt5chPIw
# DATA laEJBYWIQFZsgM9eW7eTz44W/y4R448SAS4GCT6vD/K77onl27oqyidv7DqqTJBcI9eyX7ZF+0DF5TNIeE7J9pDaZqKwqeZsyE8d
# DATA AVV79Fey72ZHNBmE6eOxGe+Z99LFUi3TrWVDvTo0ByrW1yxUm7zeqLqj8wfmqhmh+ZvqyeUGGvVpbsXGGN+iv5e7e2ma74mWqcl+
# DATA zmTWJ+aQvyu56P3t31KsUSGo/5ru0Z/k/eQkSt+izNszWUwNIWPxNf3KwtNkJSHhXK9xYoLuqx96VoNAphYrHV2wqwaLLkK8h67b
# DATA nWYxNnlN5LTse3/9196ejtrduzomiBQHZKqAybe7d1VSUH9xiyzr0Zv/FUdBmht/3Je0vP66FJQydrByqLOfv+TmDr7tyx15sJIf
# DATA 6B3r+YiklIqkDHGDCUR+21f3lIYPCYtrKccwynjgoJLXJbqmMXI7Qlu0KgWSY8pxawMuPEQvQhxVNaVM1oHsF2scblQWx97+3Xts
# DATA M3722rvmUBiayet7MPs+e02aHqX/O/Kd54Dc3BfJu9hWtxfsv44E/+/f1z6j/83e1rPkJFmwq9ULF55PM5bXJQA+bEYB0EPr30PG
# DATA 053irfm7fH7X//kn60EdoR2eG0ylccsMMD+Q6Q5mu4PZFx3MdgeyX+oD2V5hu7E6B/1cH9Q2njP+uXACcGId334wZ7U8jGzxELAR
# DATA fXo7v523FfM5uefrPPeLcqrxIuEW21HK8ReP8703qKctN0O9SIZomJWKrqx3WSt4ciGc8LfiQfXy4pU06UGCzJU3nc4GOhrKj33v
# DATA BytrX2ymkj1QOvhvPcNfOB2cAfN7XLQHVO7Qg6Hygj2ULk6xqdg8PxfdgGwc8olYXaM8teGCpoV8HHnZp3HNg1fXwxyEwvyc48G7
# DATA lOIkrXk/mEczPuc74rP79JA6zM+V1aOwxqh1VCc92YbAGCbcTW8GY4ECmindgB2Vd7ySj1vrCPB5Yo42WQtkZB/hXJqR4fkbHHNG
# DATA hcPpbiY6eB8tjbvXm+Eyqx/JO2L6aTmH2ZDVPNhS/GPGJlUygpOHWswQlppqNmQuJywBMFqmZEUsV9UQXs7DtiYEZ7056+0i661Y
# DATA w5y+jtPXuazZttFAvCndnQfYwmbJQeA18G1COM8o8Dw7jbdtwyV293m2XF3BkuP1D7Y/sCiituToa1zY6ITEjmWfgM5k5QXcm+6/
# DATA IT5R3QBnvB6FQpLQzHOmu8qvsFeMt3/UWryJSGtYU/J5QxQuTkPeb9RSm0miOe8+qknPfofjWIqqeCFMdcC3HSKqnzLxNBdMNBu1
# DATA 9jVGUzwj9LP20vCFN8TRqiKl7zGRMg+9kXCHn0cuwJvv+QdB/Y07ibIKy/e01D2tLff4dXUTfcjvuiPRypOibHWdm2oVjB7Mm8HC
# DATA ljwis4GfYEMindJ7eU+wSqdaDcXopatmfkl6nviYXzSncXohOXBHgsD8SeWWrNPaoeSX9A41c+WeZXCGmJBZHYAtTcVGozT7JaUK
# DATA wi/GoPyABkPqn8Vo1F5rq/1jjI1m3PLZUDQDbZyKHVnz7g+HHp+JVWZBpofP3Ib03scailL1xETAjLRLyKaLo5eNUjHEqcfBG7EL
# DATA g942X04m/OMSy7A0qMepNv5/mEWivCMiNqL7E/djymKRmNciUrrOY8E24yiQWQLDgk1p9ESY18QZpoWUpJl0flrliu31CYTvrV4O
# DATA Y2A/Yr1MzjTu4KVIuDRefqvZHgCd4ewM54sM55KB5CxnZzlvN4efA8XKT+ht3Dgy0cwLh6o15GZzSbMRg4vReWNFxIfRggp0diTS
# DATA dkXpRWGCJSOMW4mSgMyVEkUPsWwkl/yz2K4opaC2LL4xbrD+nBZy1o2dYtwQl5kRqYQFg31K0FsMJboshp2MRtj+BZk+7gsyb5yc
# DATA 0M8elZAMl5zXNU8ZF5C0pNgdY9xFP5OMuGPgPLfkK8VnxckpDnqLkL2Z91MMVxMz0pkU2Ul7n51y4YBsHAhpnlCPlacMI2+Vpwyy
# DATA IZpRp+Ek4+1isHSQxCOyxTLdqw2p8MbUm3EpcTLllA+FMGNRcbgRyXQ6krmTGDHaX5ZMyWpcKHXBEFbBQ08rhWxJ59vhKffE2xOK
# DATA MhRXJcpYp/GB8j+OooiSNYxHLO1HszsYahA4xB5G7EOgarWQLRhMN6Zf0BTxC5uA3ieM4fGYL4gA2bJipiwcg1QVdUKMRddfnkql
# DATA Pl2gPmOT6JZEfhxlaxIoZkWhCq8KqpqqTlYq+y1PoAqPSjZBE+RRJ43WGbEo0oq2I0F4C4cxzt7JQCd2qhKTpNr7MfRfhpSJZBey
# DATA 7Yfkw85bkjHBTzwUj6t2KTOkDLV7Ku8Ue1JPpbXU6ShOp7w4sm5uy4n6hPJG5uNg9M5xjJTMJKO2Ti3IWM/54ncm/mu5n/KDqyOZ
# DATA Amp6HmZiC3Pv5H2gxT2pd2XYA5vSCsRtfMjUeB6yeYypARm+VNLhchGj2whT1umaKuVJVj+VDgVcKHEbk4WA62pKsTG1fzNLTqR+
# DATA opVQE0EfCcFWneC3Ew5/gX2VyG1pi5SgOVwJ3DXy2CZ2ieVXQOOnUsaWhnhi4FopTxdSKm7KPrKRKMMkhVTkOCCNHRnhioJsoRvm
# DATA KcLstKwma+YTtqysZeeLzfwSWvtPnlQMQ2dxBDhvemoTdP6/81+d/eHsm7P/cfalYuR8efZn+v8X57/1zv4ZTBv64ef0729X0Tn/
# DATA lX74im76Cvcz/ObP5785+9KjL78zEJ2vKVC5zF8B2vnl+W8q3vnf0XP0DG4DPecbetMfGePzD/SDMHX+ePbV+a91ZP5Ct/xBQD2A
# DATA 7TiWzgswm0GnjONL1OH06c+iIJp9FCUUThoPtAlW8955NJ/I+DzhHjGSviEbx3PqLSaWN0J3jlhFnEe5zyCfCyWTiRqf6KVa5ncr
# DATA VAfLiSo81VIcWqc4v9E9yG2DddaVzM3hdfKqY26FSZdfLj8wEb1pc/f78p1H9Gsm7PC4pob1RG1uxWDqADs7Ftv1I3aw9h6x9YnC
# DATA qeQuRjZ+kXtwyGRRVDBMxzSecD6y3H62wEy1tFtZIzURhDmUEi9W+DoXV7/NDs01LetZYXYuTobj7DhL4CYsAQ3cuaIB8Io4N29t
# DATA 8L+RsX+nof+yI//tDPxSPVfzIWfwPH+t6yZgPFYOMIqn+Oo16V0FedDrpnO1kqgKj/IsxUsV+CaSrMlU3lQ8JYHtpePTxXjKocgB
# DATA E86gXRE8qsjyhUjqiCeMl1lipRYq6Qvk9kL5Z+WY3Cg8TjAqKNaMjjFeIHATHk7pQW0xqHN1h7m9IMQi+H5gRpyEs4XtFhskc8fY
# DATA cYwdx9i5ScbOrqPKTtOcXa3kWzb5r2LxX4fB72g7jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO46242g7
# DATA jrbjaDuOtuNoO46242g7jrbjaDuOtvM80XaCVnhV2k5n1BoNXiDazura807MHc5dlXvYlenxu9rtgkJaq1nK9Wa7W+TmRFF3pMBG
# DATA ONxI0RtwoI02y4AMONRAgmGpDL/ZLkJ8GpTha9BInabXDOoe6DZ+qzfxu3UvaJeoPW2/1er2V0k5zYbX9Hs/8nvNcbN7HAStqd/x
# DATA vfqP/Hpj3OwcN/xiFAbBsNnvr0lEq1vPE+EHPZOIRjGAoBcMW6vEHspYr9kJxioXLXqOeWCFntO+Aj2Ha6xFz6HKX6DntJrd8Cr0
# DATA nNYwGvk5PacdtP3O0NBzBt3+aNjL6Tntdsvv3jw9R9XxKldjMy40hKCjh9vCTescVQ0eRyq945NKly2pwhpTazA+3Jm0U36bcnDb
# DATA ri0xMdRdOFpwPbgdO8RV3I6aaHaNsYoyPuSdHONwmJwc1D14N+qeLskCoIfb9eortNvdmOYdWT8p5HrppsJamQznJRjO4Yb9AKuj
# DATA laIkrfPUyrrtlpBVV6OGNt1Q8prRNPG72JWq+ozNFJ9CaV9gIxYyzy5MlRg9eYEV4ig7jrLjKDuOsuMoO46y4yg7jrLjKDuOsuMo
# DATA O46y82pRduKR2G9Y90CNf2x/k7pzV42YauCS3ypcF/cPn1iYnseSb8iMuxwMTh2ZYF6nJ4Df+ey111ffoSr1oR5Q1EtWb8xvUQc0
# DATA 6C62cw8VJOhDHOOSls+m/OSUT+fot5ajVPP+nToDbx1K44NnKGuqUCYKVX0D/fDdbSP+NWWFsZlNUnlxqrZ4tMjTTL3jZ6+9b528
# DATA M8mg7lKlQCa6pXM+7gi6O4K+8xH04oEwdxbdnUVfPTW4UW/zeTijXqrjhdZii9Ow548FaFGZs1wtRQnfxsMozAroFj4RDWVLkIt4
# DATA pMmoO5NzwlpJhbfSlU7L7noGnZPA+owYy1mcT0mC0qvgQp2LHl+fZRcRvzWHQdUuq1X9emW7ogryJ6UGr4TD9Y+5nrm5wtttIf8Z
# DATA cTgmenFmZfVmlXdjELM0unwuarxbd5ju035qRaEdFiUOd6JDk/tY3HWToLvqUjms76nPm++W4/WscsefNt/Jfa6SmR1Em++TfpvT
# DATA z5+2iMrLQVMt5y52qK3mjiFmi5Z7oSbAf27Luua/wFvPXZ2eB8gnneflPCuJbbJb3/QCYlVzzUuXnBv/8k//0aSjHHEr/+csUYo+
# DATA ZxLOc/1VtZTIe9LSJSQSYKMlLMUwgxI8a1FDrTSmWshQpnA+pzrJ+rrUMaP10SR2tpDj/9BjXUD/SOvQslY1L35okdkTqtzqsLjy
# DATA edktMz/5rJtGfrDaOM5wWSXF5Iw+ekkX2BfMNYXutUAAZdXWSxVRXlEvW0B//983F5Cu9FI876EYqCJnuoA+OUmojabUsXn6lF+m
# DATA TBDqk5YzeCJpSJrXvPdolIeRM02ORZCC0sCCAxA2OIq4W0UByf5hVU6RVrdQpfX0pWJScGvlYrqFyxbLP/7XzcWiuhgpFZEDHSQp
# DATA TUZMy5mpibBc5mlOnzVdWVdZPnnzEA1rKKaDKPiOqA9PTlQRFe1IlmZns7gwDlqX4wWM6KcvJTtFt1ZQeb986R7ut5tLSvfxUlSf
# DATA hunU491deRd3gmsCxxkeQwubSuaICobXL9DXRTLcz4YipRGxeix0pqMZIDhSAmo20I+Y3BEvRJMDu2Ptn5k68fTlkyfj1krnaUag
# DATA /+efdx+B3sIgG6UyJFg64FO2qyle6UNlaXOTCiesXh560yWNP5MwxT65OeSTkdHej8R4VAMMmUhgGEizQYk/fUkUovsiNJX/tGtT
# DATA eZCMFl4f1T5E6eTdGsb4PmXRFFo20IwZ0MiDyQErQofDn4bYn6NqfIbCStkej6fxBOcNkFNQqSBL/fNlLGo1UEFkYRUpQK0IfQ1N
# DATA pZCMKxVQ0QgUj6ZtBJorkt33Pky071FrCvHsQ/kEk1SojBigE+7EdcEq4Z+nYQe9GuIuDs7tXGlXcKU5z9kr4jm7LK/7uVB3LOy/
# DATA 3I7tljk3DaQLbNUki/KInVobyd3PqQrkCySadpE2tL3v8SYo3qut5NpZ3mtlRDcRvVdTrm4z6tjifMEkqOb5RhKbnUkV8R2JGuRJ
# DATA YhwXuZNJUfuUQ3gKKLeR+csLuuItM8GXQhaQgsHOCElCVtbCXlNrlD4318lcT/NKWuAfwtM1OwI0UADjottjpMAtZUENvlGaWQdG
# DATA ThRmdS4qaiuJeuwzIYt1IaWFeQ+sbw8bcaG3eVyoD7KZTTKLt6tCE3WWN3jRLtS5hRyuvUrGox2EMx+d+biz+WjXNbcO69Zhn9Jq
# DATA 3Gik3sw67AfC/bSVonPi4bMhVdwGJZz3/qB68bHBwjKn+inHa6tbV9YL84WkfHls09qivbxhr9Zsur/kaC8tJWx6quD+Lfi0Nz1R
# DATA dlOW3aybnit7z8pewY0rp4VS4E1WiCmq0zAecn2QhabvvqHlK1WxqHvBL5c9p8ISV+dMNem8vAiOQ+aav2dbVJ7m3lOnbttU4jLT
# DATA r96BIs6bCqanhQb04iLEsdC0YBLqHD19pizVZGK/JZrr8URmnGyCR3omZSCS1H7MatWSTQUKjZ7Bc2/rjgR9iz08e0oghCcAxmRX
# DATA T30KS1z6Hll3HIprmfeVU0wg3I0FGvXEnWS14PJ543qncV7X8r2F4HjqPopKulTCFzPAXx4r2YIDshRSMi2wAf+jgvh9c/Zn+vdP
# DATA Z18Bw/eVh2+M5fsGrL8/n30JKN8qHfC/n/2FiX+/V3d/dfa1x6DA35398fz/OvvD2Rfnv6Rn/6gC/VohBL8+/xWu0W/fnP/coy8g
# DATA EgoIEGRCxEGeA7CQuYF/cTDAF8HqL/Tdo+iEbAeeRM9DSNcqCAB69ekI8hF9SHZpDAh1fFiVva+wukmfmQeqe+7rTkv32cs5vwZN
# DATA iMMjI2Mg/pNosZxvRQDeh9SFN1xm2OxC7dkBAAv2vu4lbpv/t1osN0f/YwuLCSv5rYX6VuaZ34lOo3kckbWh739HXfCgMgSEdpJe
# DATA MwaQ1cMYCb1c8PivzmhRE3MkwF2L8PpRgNTXYBGc2vwsHqHTYRg8Q5yxXS5NHkFDJ+Kzy2LKw2BFLaTObbDAFoYlS//Lj5nafKL3
# DATA nuiKJi5VssSZcYNpXHw0W8EC7l4tN9s6Kw3vWcEBd0+MgwQ6C+H6LASNBrySYfBqOAFvzSi4AZtgJ5Pg0hbB7RoEUkXL2WHMgOem
# DATA Vd0EEtBKtVr+2hBFDRdj98XDU+8oDYfLUEH/snz1ATKGxTU2Rg0WFyVOZdMnluaP2fWEtTaWRczm0QAjvzHFdoIDmnGdlbkpwZns
# DATA o6MMHAFfxhWwmoyqqJzcz1IdqnlQscXx2VAsB/jomICn4qDYakj+PKVLGa+lqtJW5pssEnJk+UaTfTXvwwgAObkgm/YeLGGGpMny
# DATA aOwtZ1RMCznDzi/OHEbQYQQdRvAGMYI7D0M7TZIua1Df6hzhKlOE65whOKqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqg
# DATA owo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCj43VMGoEw1H/hWpgn43iJrhC0QVLK9A78QULMLzek0LntepG3he
# DATA p5ivw0HUHI7W0PfagU3fa+b0vXZvY97mBTP1610v8Due7ze9bsfrtap+K/D8pk/lRVeDjtftlrB8nXav2++uw/IVosz7MFfjSy+0
# DATA kId+x8S3VQRM1qP2oLPm+SAI8ucb9RyZ2N3t+Ya8UuVXK8jza7fnmy0r/g0rv3d8f6trIR+bjc5l3++37fL28/g3doy/XV+kbPnx
# DATA 5m6Ptzt28m3Y447ZL4+o5Ld7l31/MffqO7z+MpBIaSQaEil9mQWJHHTCYccvQiLNIwYSGdQb/VavAIkM+s1Ou5VDIgf1YX04MpDI
# DATA 5qDd7TZzSOTIH7a7oxuHRM7Qn1ezh6f5OoccoTyOrmHdIbBcHdrmYvvBvFZbhAXTR15GsxlM69fsYVEZbgdTg3ZR0b63QrHv1FbO
# DATA bsTKQkT1oofiIkoJ6ntUljzeNddqbYtq6NnZom7z9K6WYt7oWSv2yRccrSWg45YdCmo/gqSjmtEP0+gAopebKY0mHyql5G4x/cqF
# DATA XNlaXuxMMUUm9uBKNRHzKdglpzgER4F0FEhHgXQUSEeBdBRIR4F0FEhHgXQUSEeBdBTIV4wCuQpxnIZHd2HqUa+OM2aU5DvyVZ9k
# DATA QSYo5OIHtqIAWtXr9DTVhXexIXLP33/9s9f+zz/VmHh4f63OAD+zJ+GHczlsgDdSMPsmnADh/O8vJJy30OL5+NI0nC1HIev0y6ku
# DATA OY9IzXkuR99wqCoU5EL0iG7kw59kDmQ0tBUIiYUzOu70vTt9f8Hp+zVHuNxZfHcW/2nO4m/U47zRM/qiiJjwQeT8uLcMK981+pzP
# DATA Xj7mNrQ6ZbSDjKqJwogPyCqrc2863VeURN1CZ+wAyQX9dBCmWzMXjKJlp1VUkpzGM1n3qivVSV4FUnqT2G/Dv27mKZpB2a4ql423
# DATA FYiJun3NxD5orYt8YEW9W4h4vdbaHHUz3ttR1xdVPdobRkdpRFP1C1JghWVSYF8zKWivzf6Gnft+sCXzNyp06laCGi0dxIuqzmmN
# DATA uMxDpDtTac36iHvB7MO8abG+ydCrYhxZ75/mjdy+gUX2RT5fijvKFtKVyJOCZzRVIg+Db+6fCsqx0C9p3QHWr9ChUT9CRqAyEDHf
# DATA m4vZMIwx9+PHoCHMkhon4akMPFKcPPZnWljjaBnSiLOIIpYGV8IWn1MHR+YXjtYrUZA1MdpBwPPlO7BeGhWdZe0s6wss65LR5Kxq
# DATA Z1UXrOrNbKXnSfmq2ApCk19G/OqH4O8ZtSOsYudaR6wnA5d4xeg3Cbo4msbZnCVovE8MXYWNd9bNieCZO4mYzFrx9J4NjErRHMv4
# DATA KT2C+lO2qIsExxWxK3MfDf3vxkr6aJyk8c8SI3mjFPxDLwtH4OtEKRlFLMFkSiWbJ7lCOksUsWiUmkVEYXbKI+84mUYQ5eHZBNl9
# DATA FeFkiBQP7qXRmgbWGCYEd1YZ5RZWEZQaOLYqbJgyFGybYaTj/j6EeYodILZOKNUe8CDzDtHYRMtZyIYN1aua92Y8S1CH6BmN2dWG
# DATA wCx6tGBDkpdUkEGqH00yuK1UD6tMIKkCU36ZBQpdZ0ysTdvf2GCESXKkU/gxTjRLuUm1KszZYizIQv0jzsWKDHdBJLwmp0otn3v8
# DATA 7KHUtHzc0JsiRf41Y/3XEaTaORFakZShp4wL8/gsGHDbyN5Fti1RH4mcl7SK6FRJZmGknk+5C5M0iiqYyM/28/JgB2BunIYLIxiW
# DATA j0eUF1RhKY0y4VR6SpRl2OU6wf4Srso4QpPaFfo0g2+cY/OIAliQcRgPQYOteW8n3CQx/BllMojAKYNxhM4vtWKzQkBiy+pC3VcT
# DATA l36oCntpKeib9RTDJDVXZJA4lQtaZF9NzorP84/FqZdenCpMq+o8BVL9Wd6XMbFAam4OtVcy+0/1Pt+QJybhqUKHF02VjHrC631n
# DATA wEMo43qG8VT6n+t9A7Yp3vtQjx1I0zyaDeLJ9b6F93C/o1uQXkKze9DrfV9LABajyOwZoobHtuSMWlvxXXeWkxtj0L588ytHonVT
# DATA q90lg91E6qWfSF0WPft8SQibPb03wTAtZ/a1E0zXKB1fzC+dFAgKogHMbsiirvAWvO7zpaP8IkqI7ohb8Aoby7URnsutSr6YyUZt
# DATA ZXKcT3sr3hEUmvM5DWZhXogJMLZamXnogKbAtn6sqLZi0pQtSrPS3JtQ8iRo+1sEdAu1lqyX4+hiIWnUyWk41yCHncpgTYl+lEbs
# DATA US+oYWdRlmlW4StkuuWEq374MEoLeKv/dvYlqFPnPz/7s2JQ/YExV1+c/3vGVf0v7/zvgZk6+90q3Oo/g1bFQCpwrH5+/o/e2e/P
# DATA f3P2l7Mvz39NgX5V8c7+J93yJ/r+S3z3zr4xoYGatRl49Utwrei/jmn1IpBsqQ7jeTgbqIKxBHbIuGcZIsjainkkGMI1Ably1Tlh
# DATA TiYujRk7LbhfGikwz1AuJejjZH+tMPKo58jY07UVYfUmNtCinUToLBzAyjZApRO4bXpVuURujl0FSehh6b1rkVVcxcyNb3OFuxlY
# DATA FY16c7XpF7UUm4STYXjK+wipfjyMHLDqonK7dk7Vm2gGXALzKMVZUVasx3G8EQO25fSlR7Y7tEzUKoi1BU+v90Ms/yiNhnEEbzQY
# DATA BdSnRim8XflyiuoX4xmZQ0vJYW+6zKQ/EzPsVKjeg3gerVCsdqmpm+2ZUtN7VvSqXRLhuFXOCriyFaAxVVcY/F8Jz9MtDfzXPu7v
# DATA NOzvOurf1qAvlbGYejPIP6vGchP0qWISvXE0mcM6IcMDCGYTuTzB6fh0MZ5iRVaSfiBDLYTeccJlwR+Alka2yOoodZigGb1HBn54
# DATA TONkprMjFWkz3nqANdl0yVqKFP9pbLhA29lTancEPEwRlqgjPtMlAzHHfsNgLi4OyyBgPBGPBZmYEFW0/2HBvOB9gHoThUIB8UtY
# DATA QAGoKfoHeypg5+k18uUigTzUgEldDjDlAFMOMHVzgKmLxpGd5jK7m7q3aLVfxWi/HpvdkaQcScqRpBxJypGkHEnKkaQcScqRpBxJ
# DATA ypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJ6rkhSbUbzXbQuSJJajQatYaDF4gkVVx53okjZWdK
# DATA 0PYane7n1WbV73Y9v9WsBvWA/vqeT/80ex59LebQIOr2G61VHlSv4wWgPjU8v96dVv2A/mmqryUQFGVyfdBfB4LyexIwpT+mgVuj
# DATA jxoWeqnRaltFrzhIAiUqgquiZhi1opWINju+F3Qp2S3PbwTTRrfqN1vq20o8o35/tDaejdX6VW95zVZr3K77H/jNwGt2/XFL68VZ
# DATA DKxWM4jWBblaY9tNimnD/1GvOa17QatK//jdaUCvoWLp4nM16NKX1R9KL+12241gsOWll0EdSQvRqCNpbBbqqF/v+MGwiDoa8f9s
# DATA 1BF9DUf1Aupo5A9HfT9HHXX6lFWhQR0Nw0Gr18pRR91mq+63bhx1xDtMqmx62CwhFdni7NPHSOjJf6mZ25MBm2kkM4NtkB8eufI3
# DATA 70AfKjjh2sYJJ0tvq4AiK+xVhzyPsLJtjh6KHu4KJ9KWRlAOwLvEeL3lse2D90YIkVWCti/QExN6c3pKhdtBqXZU0RbzZ3NyHEnI
# DATA kYQcSciRhBxJyJGEHEnIkYQcSciRhBxJyJGEXnmS0EhxhPjoFSW4cnJ39B25ND4dyuohYD9k3FQy81MWskXJV0/N1dOIemR1WdOH
# DATA 3kW4TBAavU45dMR8oE8phnLxpAgiUr8/oOD552ztz+/NIIoEY4Hex/edrr3vk2QRTuR8H9/1QbgY19hvsDd6/eT17PVTdbPNGcpP
# DATA srij0u6odPGotHWuyR2YdgemN0v5PQcHqXEmdZRX8/DUC/F7Qd58wconUp9RAkYiHPWmgp8hmzeZJCfbz/pO40d8/HieJslInz+G
# DATA zrhpqDT+YivKMo2yp9A2pxExPUVSFpQlSJ8+bnnfy5ZzdKrRULXoODPkI7JsFNgopQEPtRNyepN4gUWchCYPGSthC8hkkC6n/UNo
# DATA w8QzPo+dmUPVIzh7j/n87qdw4RYUTFLWdBcF7WyQJPzEYDmHzLaca96moP0WbIj0VPbReTxE5UkbQWQdKoAIkkt1FkXDTHdnkt5s
# DATA kYq5TOU4TiZDPuuKmFNiaQ7McuAolRF+O6IoT05ZKNxkmyk7UdZhmXScSteq6JwGTOQmyQJJp0v95GTihZMs4YPBWyXC36XqzU1H
# DATA jm3TW6PUKjwWbO6ztcnZpW+OM32K/gR1Ed0zi/tMcL4X/XjNY0X1vCcfYENKBHn0eMInc3E2Pqt5b7FaM9ddTwNqUB0o8ggVqQ2H
# DATA 2AjEYZljiErVP1xcJOrOOcdxPqGBxOgKYjsqzr97OEqDl1HTCaf8OhrouHSUJPxguZDCxbaauToNLDrx5rw3rkxiReFCtfgZZOoZ
# DATA jpMZRfOHEp74VzhEMg0ndpbE5jx3mE6vpmv+pghRI+uo8V9a2ByN8LqVzT9G5qPwRnBOS+90A4LmOdtSBI9QFGyIerkewQ1omhtl
# DATA RjZqZqrtoZvFmHcDEuf3uds3tpJSk7g9JfCX5yB3HoibUbgZRXFGUa5SblrhphU7Tx82Tj9ublrxAFmR43AkOnpK8dxrA94GolQc
# DATA aXSZPV/e3tFFWEz9gOmwzIWczlG/CpC0vhnrmbv26Jbv6y/e3rcviqz9oIlw4WJO8eyui3OzZUW5tytBlf2NTCiZLHaIpbo9R7yq
# DATA 7wWTaiVqdmY2ioTULVETpyf9XPBK7hBJ/aCJpbmQ27W1zkURDbZFdCMIVeavGK2slvbi0lClqcVZUezIaJa+S30LtQ7vyMzFK167
# DATA +23P1FtvSiZ15jWa6p4T+Kdplk8T6egoRUfJT2lkFqbfws3iG7k74q9Kh01mpgZyGrNabTwwXR3eGD2SNRM9ZcAyGCb1CKskZcby
# DATA XFZfpgVsM2GVydOyCoFJfz4tkdip0weRVkHbgXL68tjejr7jbO/t3nxnaL+UhvZlKTvPWAiVdwDnG2RXDVAbQsOig6H2YBu9UEnC
# DATA ZgrNM5VPfSFkBfm/18w0Kgm9XjfRaEUqdy3PaAfxWmsfdS5hi28RhCuTcFQxBB22spbZWBlYpXqKneJSsmq3+Bvjxr130xjrNtil
# DATA yF5EugRGffwINgx7/+U8F9MO46K5QxNIzAKjdcsuSlVThExFn1QdZOAtXMrkKRowNC21PKrGajHRteP9AGtWiDnZd6WYi+yuWVSh
# DATA 2PH6hWkTojGql2UUgxTHybA921otYvlUXnrCWcQtEUaz3zG2fKxtljD9l+P7ACtBaoFOT5+jojhqWFzY4yWTiVn1ozgq+CRWILAI
# DATA tjmi9LJ1+frKaHda5CAy3Abg8FjsoP909uXZH8++Of/F2VeA/pz94fw3DPUBPegXzPD5Of0GutBvV+FBKw+f/fn8N8AN/eLsL+c/
# DATA P/vi7Pf046+ZQfR1xaNPX559XaUnvkLQHt/zDd1D7xC00EaYEIWOt3xBb6AbHVDo+beofwj9Ml4n5t5E0cJOK7IgiEvS0ardqWl0
# DATA BP6ylnOWhX9VX83gnrJoc4EyTb3xVobQW+NQVA0syXDHEbKsa9Ul3DZJaF253BxNiDcEjJO5ufFTdWE9U2gU5930u/HCeIKvmSYk
# DATA UGO2F8RXZBF9XnWO0C4ldu00ofuegNcBAq8ulv3IlLx48GPsoZ16shO85n2QUA2YGRAiFeIx9N4h6YE1AtbwgFkWqs0uIT5PZNNH
# DATA CvfhlHmM4qxj40tgjRCJLcODtlfJzUbMmnb2rNBB25PgoEFupL/MSK85QVcc4F8N19ltDe43MrbvNLRfbmS/+YFdquVqDuQbXW+v
# DATA tdwEKChPGUS0KIBsNc4LeNywWVNv/tPxXZq08yEnxonoAgQBJubfmW+CJTCmragtofyWaTij1GUm3ZJaE7xghqZz6sJmi52wQbCv
# DATA FjjIj3ygkEYp9Xb5oB/Lcr9e2EIwLCbHECNDAEojySqDRD4VoHLFGukTYH6SkaCL8SKqiN6DBZIds8cjHnnUqh4KDeWEOgrsGUQb
# DATA 5A0GKfJOO0QdPcjRgxw96AbpQbuNKTtCzS+2eW/ZeL+K7f60prtjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMH
# DATA OXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXbQc8MOiuqj+ii4IjvI7zYGrfoLxA5aXXfeiR90ZJLMuwiLrJlhKxqO6ptY
# DATA M/feGMQp7H8B+wSSEAX26bBIA8sb+L4iDBVub9ebF9xucX4obI/u8ei3qt+jv3X6t9f6Pl2f+L06XWt7gd+ka+1qp1cNmsG42fsg
# DATA ALCo0x13mlO/0ao2W+P2upg0g00RVwCjO0eFCtQMfESG3jCt+l79WBA9W7IxGvV77fWIpPpK9aQ4t4L6uN2sf4BUN3ut42Z92qw3
# DATA q806fSojiHphp99eF3RweRqQ1HlNA5LmY9GAKBmDTqNIA/I7jW6zZ9OAgnqz2xoWaEBBt9VohzkNqD8aNodDQwNqNTr9bpTTgEaj
# DATA wag7uGkakDJK1js+dFpLtpYaibBxrbrdCvHoZgw7+b1l8I+ZKK2bFGk3Gua6lWatyfyfgPk/q+tR7WKktHFjddNiu3BCKMfDtHqE
# DATA qTF4FvVhdFSx1t7tz17Qmz+qfKtRb3XafXb77Vc2h9S7ZFA6ytk8GlyWSqRtXngPV0wqa0Vu8+K4WgoXn3A1ox+m0cEwTB9uZg/l
# DATA OVyxo77Z5iiZvVKH2HZyJCFHEnIkIUcSciQhRxJyJCFHEnIkIUcSciQhRxJ6ZUlCivTziXWsKz/PXTzHVcbwCDdITnlTHmm6EHYE
# DATA oBmBzjOY1hjm81YyZQH0lUPefLwNS0miVhXioEoyU8fXtCBt8aCYtFGZyOmTFu6MszvjXDhq4446u6POVzzqvFF88GaOQL8bs9YF
# DATA n6VlF2T59Kw+Cv28yW3chh63GlxQdai+KslwpHJvML1Iotk8azqs/IoRae6u1eZu2SLNvl8vyjS3tkhd8+AHSRfVe/GFN8SWNSrK
# DATA ck8ucK0feiPhztSWkG7zcs/H1PcpvBDXkzfuJEokcM0Tbc4uGlu8O94ijR6yVuSFj7X4RbYZMIVBw/LJxWfvSGp2EKp+R9dPVFkP
# DATA VfbFVan+IAqzJUSjcbB2EKa5QPWDhUjyUU+SJAu5QY41Q9YnPILYM/xRJzRm1bwf8uA2iY6p0qADRKc6VWFzM1ZwmiQ1wkNpQuZk
# DATA zfuYFwDENJIHWG9RCfvRcHKKgqaCiBcF+WrAtArH9uUcqZcuccYbR65DHLCHhqMZz6EfSBYb1Vku/IxmZ8tsHon+IStmh7PlCANx
# DATA irmUBAgu0jAejXBl2Wc99RjjNAXG2J11tp4SIaAkLHYWuH5Zzvk6eWtnvlrmq7NXXwl79bLa1s9YsofXtfMF2O3a1vdpNGKjkQ1I
# DATA tmOzXIqCOQrZFo3r2xb7eSH0Lm5C1nq1Xl+7tPVaTaerylvni/7aHBOLQtk+EciiXOdyUWs2f07JpBGgJi8F0etq3puiG0SzJBGr
# DATA icIZTJRPISIkci8ZBjfGjArBkasbzCiyumIt/Ew2XEI2Dxl1D+kNmhhyuYrzAy3EYlSdjDv81VI8KeSMM4acMVTqU503z3nzin3n
# DATA RivqGQsaMg8Y4OJkMhGd/TKwW7WTMMsl/Greu8LpZitpnTxfQctvniaDaAgat0jRJenny0h8OU/D574fG6izofEuaATVTMBpvBDU
# DATA tIykHmu5cAyW3MiPwuURjZof0zCsaYEVDkDMElnuUXgHdBjhaASnGLtKcpenGaffm2G8Xwi/dqloEdG0Hw0hgjaM+imNyEJF5iGU
# DATA RQCxQ2krylpG/1yeUXDAIVUF+EFZU1CZBpm2LqAcB39NKs5SJT5NNsBwEvXDtOa9D/sJ0aRKSpkbKhDYMEQHAyRCfyLCa2MWxlsn
# DATA ZMgfM0u1UFyyGajXn1PBxyPovE0jrP3Fg60w8jGrWnPlmS3gwWEvsknyp4ByJKORd0RDlk6i7JP0JkvK1EEIxUaux8CrhyfhqTim
# DATA dDxVGWbarcPZx+MABaNiTvmSiQI3/Euswn2oZA0hhZnyyQJVcU11LoA1Fqg/zBvx+hSBaKPXWaWaRxoZWyATznzwXKgaglOmZZEZ
# DATA k1DiY5BJWP4pntDPFe2H4gTksJ1BmKanrNx4n/IsZL+dCkgI8wKP0xyf45Al+fJM+jCKOVXiJ1bql3DJHSXJ0HK3y1sTamg0Go6k
# DATA rRWL8Gqwb7TlU1Z9pD7mu5eGfSNu1w37Frs8lgau9AvjGcDx0fAGoN9vgnmv5ELV1pEbYHx/WlIhvZE3Mdz7fTQN6WNoXJNtOZkQ
# DATA c673bXwK6FNDScQK0TyMU+8hvMXhaupukij+ckx1LLhMEqbDI/jWbbzMf1EYmW8Y6gI6zJfe2Vdn/3z+8/PfrPJk/hvd94ez3wny
# DATA he9i8guoMN+c/Yk+fsEsma8qnuHLfHX2x7MvgKv5Cj9V9VNfefT1Cx0U3UYv/OX5rxRchuJx/vceM2Z+BzYNKDQOKvMCYBpnmtm1
# DATA 4oubRwkQ0GrkXojA9Ft6viZ+jyPeto1BTkHDWLuX5YVzcpcZ+Ch6eihczoZbKTP3+Zb8zY4xU5jNmZ7htikzq+Vyc4wZTqC563sQ
# DATA Eqe8nozK9w2h/WyAXtjvu0jD0+tEy1AbyMjGTkXAnGYasMZ4JoaCcHCZ7UV17VQZ0wkNYzLj+cSemDpkvuIpiNzHjzyuF97HvD1A
# DATA 3LZH2B+5blO5sA+h0a6VvlFms2jBmubY+0FjeLbCkNlW8zbbKStt6FnxY7ZF39Fj3JD+VEO6xslcaSR/NXyytzeK38AgvtMYvuMQ
# DATA ftMjuNTFcrLzbZPPsMXcBFKmnNCcLGM0J/KYU25GoULMwP3GcgPwdM2oSDNZrUUyDD9DhlWgJ47jlHExKCyNlaGUhxku4si4IQpj
# DATA NVQG1ktAZE5hbbFvV0I8km1mmCbQx/5EPG5HacTnASTb9VY35Vun0R9SCPz9Qh7JIcZ/zpLUshmKmJEodbAYB4txsJgbhMVcMGbs
# DATA hoS/0LK9VfP8SpzqpzLOHR/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFh
# DATA HB/G8WEcH8bxYZ4bPky70+w361fkw4xGo2A4eoH4MOU1553oMHa2NOqe3+qMG53GcdBrfp++F3Ok3+l0msPV7GwFnt+tU4Z2joNm
# DATA +/v0vfgc1c1uX3FZuCylrKTgToXDEhR0JZq9Yhk3m6WI9KNepxxgEDSuGuCw3gs67ZUAu8H1xrDR9K83hk2pOtcXQ7tQqCyvIQ+t
# DATA QrlkgBtK2SqUa4mhXSjXEkO7UK4lhnahNCTw62splwzw4pZyLTG0C+VaYmgXyrXEsFAoreb1tpRLBnhxS7mWGBYK5TpiWCiU64hh
# DATA K7Dacq9Yyn6jFKK6kKrcLw/+7ahRQnG1e82wuRaWtg461mo1LOiYhJ8aJJhlpOhQV/hpQevpAmh1e1YArd7lAygkodd+yiTsFsBl
# DATA eGZio2memZh7Fs8sbLabjajIMxvx/2yeGX3tRaMCzyzqDsP+MOeZdfrtdqtteGbD9sAPuznPrDtohsGN88yU10NtaDAzIXHGky3J
# DATA DgrLe6EXqc38rMsrlWsW/Yshlzlm34vIiI3DisSktBdlTXC2I5IXeYqhq3Xfi6Nhpi/rd8np22lyfBTttlTU2mVx2gq1vOps+0x0
# DATA HSm6nQOZyK+sHvoNa5FY3esHRS+Mrq68x3IcDpMTXojBilvd03XOytseOyx4Vmxmcxv20+lJrMrt+mYGmp2nF3g0rNwq1UmeLAcO
# DATA hOZAaA6E5kBoDoTmQGgOhOZAaA6E5kBoDoTmQGivNgjtsardMRXcXYUyw2dKdIWTpC7i6B4yQm4X1c271LFRndlD1Yrv1g/jN/iJ
# DATA w/j11/cf4yLfdhiP9k7iGVlXZIedzhfJd2HEfwwoxvRHHM7+Y92C5ncZtMYgkL1m0Gv22p2g177DUdr/Dv9RUejfhQ34Q5q9NwLp
# DATA eP39w2HyWN5RfsVef//wCctm7vV/XP/Jvbv0rv1DkXzDhW9z0K/7h08iMtaVFpwVF+G/cYB7Kh77dLdSH50vadRT3d4TiR4qx131
# DATA 80+TeLbHvRXlIPhwaAyvqx9lgXZvL6z0qTjC1/sVsh5zS16ldhLf3WjNTmIUzCS2K+RdaR5UbvQmSRvNHPFatvFlRoAD5Gj3c2wl
# DATA mA33JvH+oeRR8XdelaaJu+qK7/n1/eINGIJVfN7CvTU5PU2V7YlG1pmjn05ZxSmrrCqrmMPATl3FqatcUl1loyj2DaiufAw5Lq0A
# DATA MklY74M1u4zwyrMV8roNOh2bAnRVPEFeMuLEXIClUw/lPZL6XlCTXSHS+RaQrm3j6PwtMDo2X1D18QHzDxRFCUan7slhdPqhFUZc
# DATA W4J6JCbSZpYcj0nvwLt+0Z2+qAGTBXrRjayw+8lJNKFO9IJ7g7q6d0YmcOne3dF1XL3RyrlEX1hq3d9oRoOMRxlZD9HQSO0ZeR0y
# DATA sowsjpjvZakdJsntJtvDIjZelixTsHxHglOB/rZYjdBwyPl04rUgI3GmZHwoiaeeOnRvxGLonStqMePGPVv/h9LUoIKZ6EJhi8zO
# DATA TWujriqByU60uZdBMSQfS5zR6YzOVaMzty6c1emszuxCe/KZaf09YNQQR5Jd3ECOovobo9MAyabxIE0sCbwlW6hK/y6k1jUbgG6x
# DATA qn1nBsW8RanBUENKWEpukEynUTqI9RjIlmsaYaUFGxd21v7jlM3vPRBvVf8UPrMIu0wwjBqAkrB/aTDFXoo1+lvqvNuqiarcs6iJ
# DATA /EkZp8rm0D/mBpC5wgefgU6LOBwVP1luEMFBHfm1tqfx+YITpD4XLU/rDtNR2k+tGHZwmqItgDUl98Xb7EBtnL/NBtymuwYJiBvU
# DATA XI755rfyr5uf4UqEuz/Chy3WpQzM2sITF6ptkmCQ2GLeFUoYez6kQaujnTnSgTolw+5gj7Ws7qi8tPOihAPi3TCmnYszmGtTuuTb
# DATA g3/5+f/dNqkoR1vlrDLFlFQlVZB0cSrGGNl3PDKByaMtSR6EaNpXhd015Pmid384hDQePS0soAEaG9V+nigyPxnsFTzI5p+MjkxE
# DATA 0cRk2Kb0lpr3ZjjLqYCzoUxK5ad3QYTBSxp1GmQNJUgfO7lSvpZqzxWyt7k5ewt1UXIZ9rLY8JSQRTjR+XyfeTI0SMwrkmt6Ys25
# DATA FmITwCKeRjaUbT5Z8uyZ5pdLseiZgKQ8+t79eIq8GpG1lo0Bq2LTG5f8AF/nScYmes17B/BFvGYYZ4NlhgLikGRR8jpy2bS3y+bv
# DATA 5rxVLVfnKnp86noX+KDz9G3s7Qm9xv/5pwZYSUPKEywezMAzPwE+iOrWkvKOykKm+JnnU4H24LSQ9ZdBRHOQmvcRddk09b4vFVuq
# DATA LwhQzEni84oe3BuH3pv2HThDKO4SnkmrTV417/v0NeKKTOV/bRX5ylm8vYcoZPOnNNDSJIOCSHUeG3N2RA2/KnpOOQsM2oFUv1CZ
# DATA 5pKHsuKTSV8gd6OSwk8TKvQ4JoTy4IfQLsXJwIx1S0MTSDjTUKqKvIx+wxKKxI0z/SgWyVPwyI7jhFqIejiUnuf56Dzal+o8/u0y
# DATA 5pVPPXjrQpAMpvpLYxwqNldAtoG0YSTTIWS7l03iOeUnNw7uWwA64+lNn/VNtUcQCqoY1UWJlbsm7yhaSNFxFmIhMUumES4cLSPu
# DATA OPB0PJOJCvVLi2vpPm5+8HuLxyUwkWJTtU23KG6NxUkiHbJkLXrjTBCaIpQcxSmNbicIRddjlrGNjcIvTdfR9FPV8skWZFVnvJO6
# DATA JpxWpN76WE3uKGw8MU2wkMtzB/QUjJ2Q7gU2azlzi+aKLBvb5oq5Ipl1jxqYWuDVQsIyfoupaJmv1NzG3PCkUGoXsZ5eBpdLPtty
# DATA LhfncllDUHBelpffy7LRgfJcERUKRwVWR8qJzVrwJvECR5xZCYWRmKBYqtGEXTD5g3yehDP2WSMYnmet8ov4SdbBD1mV5KMv996g
# DATA jrTc3vTR98Lxuq6c5bPO5cuFcCLdYRknsXIkXdrvIEHtkLedzgY6KkrlMfe72WL2XB5rwBzWc/yF06NWYsbBvQdsk5sqAghyODs1
# DATA q1bfT06AQz5Vdee7Hl9YwjtFVtV3vbfo/og6UxhDMEJyS/i7mITFU65ws+xEZg8LbLTzeOmY9fdjRXTVbCrAaEOyzcDHhXYZGV79
# DATA 5FG0wosq1pZ3YwZmsgOSsmM5WFAipdhfhSUnm3OZMI/bplz+Z8ZS/g8gJ89/64FIefb7s6/PvlglXJbu/EsOvMT9Fe/8F3TtK/rv
# DATA N2dfe+e/Pv/l2Zd4Avd+hdv/KAhMuv2bs9+f/wfAKz368HO67U9yq+NYvgAmm5ex3z9VBxBNX49E8+Sce4KaJ7vlvWwpE1bZkM/c
# DATA WnmQGzDGDB5M2CMwk2nUCBNWbnDwk2FpYcyb57dQLN8UGTBBZTiEZdGEk0Z/2wDLUpHcHL0SdsCx1d2riscUdPmp/ISqguaJj1WV
# DATA RBWcwSN2rUBL3i0xDjP21wD9oxzlyoJxUMtdS/Da8Zb3YZceia1i2NEV7jaHcLBpQJDps8TQfjsejeIBNuRj27LsuIk0A1zfOoso
# DATA DPo5FXf/CtFypzq42Swptq5nxbXcKREOcOnG+qcY6zXe8vJD/Cviobml4f26R/edBvdLj+23NrRLtSxkQ465fGbt5iYgl4U0Ykoe
# DATA FhOGbaWSAAQ7nS9kKJyn6HrAqRuH/ZgX/haZLjV64ugICywPqRpkMo+neqyWuTHdlpHZjMCTmCoklr+E8JdB8S/dFXGJbDRMQEwb
# DATA KP4T6upxhg1rIArtqGPP215XsJKqJlULxoIsCHEsWSIFoSAPkQFY+cyq8yitslVHJbCcci97aJkJuBFRrpLBttFscAxMx8B0DMwb
# DATA YWDuPMDsNJO5hD18e6b9VSz7azLsHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPB
# DATA MR0c08ExHRzTwTEdHNPBMZ8bOGbQbkTM3LoiHLMX9V4gOGZh5XknMqaFevNbOWWxUaSKdUoZ3pDfJceLyLJmt13vrMlwYDfbwbjZ
# DATA nFabTc/vjgV1ZoHHyjSyHDzWWIG+1a24lpBqK3GttzfFtd9vd1vhSlyDgOLabV9XXHtWXDvdrXFVMLu1cW32u/xrMa4Nv+4FVH+v
# DATA J66N7rXUgc6g2w79lbg269dZB5qda6kDw044bK/W12bvOutAq30tdaDT7vY7/ZW4trpPXwes4Ci0Zrszbjfqx377+90SHpc61EHr
# DATA ahA76ks1xE66ZQti12xTt9HdAWI3HLWKELtm1BzWc4hdq9NudVoGYjfoDqL+IIfYNXqtbie4cYgd9lBVZXVDj65Ni19n0eq6bHPm
# DATA 91+OS1d2ujbypda2OF05ZD6nspsvtb3Nl6rnhHmgq6syytespxmYKKgpV6+1QoeDTw0LTvKfBv9uuHDxjOqU1xUynFSGZpFOp2rN
# DATA Osre1YhxsmKgFnHXFoFx7ZX9BRthc1YJbLFNV2uM48s5vpzjyzm+nOPLOb6c48s5vpzjyzm+nOPLOb6c48sZvhyrNyqUHPs8KdHf
# DATA ka98eI++3tG/CmiOjc3PXntHHf8bmpOQOKzHJDNmsg2ieLLHoTNZTfQzs9pn9L/Z/QVuk2DVDwrApr4xHEaHO6QJt8cneNYEfqcc
# DATA CgdjPZrxiGBwZ04H0R2033zQ3h2wf4kP2F9W/fC5OXifO7a2qyGyyBufZp3RCEWWBQSWx/R9mxbisz2n/4KdWL1IfSd3VN6ENmJJ
# DATA heCahRHLOg4XqCLeV4AeFkOgXKU2lHFgRlrooyW8MbyDwTtaAgrWj5gNFlqq39A9oMk6xmnvXbqaQOReqx+KTBQjGpS6AtXbRAs4
# DATA y4lyrupKvAHZz2fKcQ69LxUCT6PORY/mMq1QKtNl1cOtSkqlJgfvtQ2/YNXtBwmNdGN1Wl02v2rx7Q9DyC0amf40OglTHKhXgqIn
# DATA 4USO5oeqgnoTJIQ5CexAj8NUhCkk8sXz0IuQRVJ/sFwgSeYQdFmjfDWOOpcNtWEmJcEUG+4gsAnDw5dhFBop9TBjlQYlrBUynoZP
# DATA q8eLLdF7D9SbS0QOvYiJmCWkoSsSBDAzKvwwVQCDZJIpHqOh6XAw6UPvBL0Qxxen7bdE8iN5zZpMfIVOrNuhOBvZ2chlG7lUq5ws
# DATA lZOluop1vNEavzG5qu/F3AbYSAiV0JNWsKEce2hpV92yJuJtwIHFucMQHFiPaYScg0rldjywfsz0TuZCTrht1i9CBDfqYsjuQAkW
# DATA rxOQvcbBxJfYJYSXXxBh/byJsLmQR7i1PsISRxVlvxzl+uY4s2vMrrqoWnv84jvimdq/MJuLFGb9PY9zsDbOratGWTvM6IYP1vvc
# DATA LohxHoCJtHXJyuu10bZiraqPjnSrEOeNQOQ3l/FkaI1o6C1eXC7yBzIMy+gezvnoDS9g67mUASdz78WnRJQ6lCR/TA9F4HHd90bR
# DATA Cbu02XG8MB5V6GCtEZI/Slmozoz/s+hYM6+MBNgPVb+uu0IA10Jg0bF/lg3ymvfvyFIY8ryHekarmyWzf4idQaK6phmZ4sqWjpQb
# DATA C6VI3symB6Z0NM0QDly82DRle4mNcHt0dUa4M8JXHNUr1pazw50dvs2sfn5kY9Vgp5sB+8DQFmwVeOB2aKwyrfA4H+qURGklVzHl
# DATA ocYInEKvE3urMOog8LlIdmJ4VU5EtLmRAFGyZSyYGTkMsklz9cr05Pyl3LAhgd9HpdCzCBqdh46fvAs/ecY+VDwh3tTNd4o7WaYQ
# DATA +LSFnKzdipbzDxTb55+gnOfGJTGSn2xGSOp8FYjk/YLnHi5tqjKA0qYRiqkETE2jI8ox459lP6wgseg/I8ydlfos1ciMb6TbZouY
# DATA JsyyAsFz5Zr3VpimpxBlTWZF93gaMrORrdZFeqq8xCzKij2QqUQMPvNkpv3kavJgN9J89Uc3kXx1yeyBlFF+S/JN/moVRbrAm325
# DATA YYZgnJqZyFOxQvOqfMlifmdzMetGoYrZOP3zJRnZa8E9hi7o99HFwsgJhcmaksWuVzkyC1kvWgCiFM1LLxJ4NklOJqciCZ2ysjE6
# DATA V4xFZqmHypw38KGDHJte8amKcHvSbq0QC73MJcvx4y0w47y/0i1W0CNKIjmNwGKlIWc2VGLgXJKaBJa302Ec0ixwygbqKFqc0ni6
# DATA RB7HynkV6pascGNmMs+LLjS65ny0zCzh0OD7CDNS9rmxBwwLhLEA1566bW5L6K2V65X74Ac798FUYRd0i9B1I2/G7O3s4elK/6vZ
# DATA NlKssGpEaJqNjHE0jbM5a19773OPGbKXYBKmR5CVhjLjLNOc+pMklf5V2op0rqMQiGS4Ba6lXa5P1fPfrX5/525VjV1kX0FeH0kN
# DATA 1UA1DDXB2jRJWfdGd5loY1HsUHhb+HQcxHFQlIpvHR/N4OqRiai2MOFYYWlwGJ3pPGW9eup1pZg5HtfR9nZI2AvRtb59qa5Vy7rD
# DATA MBmm4QkaCO9OmMQja6FaOdf0Hcp6iEJsC6XMgey92Du2PYMZDReWNnkGy0XNY5efWctW2wMGaThHnvORUL2fQnvInq5ct6bwSiV6
# DATA uwDvp/LQvvw+xRyBOYhotI8HWRGB+eX5z8++OPvT2Vfnv6bPvwDPEtjKP9GfX4Bjef5zfXEdFvObsz/S/788+/r8Hxh3ef53DMX8
# DATA kyAxOejf05VfMz/zayZneue/Ov97ADTPf8V0TAr77I/n/0hB/Ir+/pbeSSHgpl/QD3+gn+mef6aXfHX25/PfOEzmC+EoxbY0dFeq
# DATA W1Q1j4PODsQXxUNYn6YHFf5+hM3u8KIOgKxToJbjkD1XoZkiGJ9r6MELNxjXvHcezScwX6gzRWEh1sqgydWBt/Iz35rQ+CUtEfFz
# DATA BE3bh6r7jNsmaK4Uys0xNLlSmruwtZDX1JUHcIW4SVU7TsztD/irB9Gu5QQiYdcJ0IwziQq8h7KzMcKZ3xD8oNNo4eiZu5TdDZAz
# DATA eZWUV8vjKaa6CM1UANU9LSI+ojZAPeZj/d4HUZgt1fIt5dgSUCimK6DkqK80vueMOUPeIp5EymWdsr+cDKThcrKK09ytSm62dMpt
# DATA 7VkRNXdLh0NqOrvgJuwCzdq8ijnwSiyn3popcP2WwE6GwKXsgNszA6RelnLBxm0+b23qJjicpeRzouGmZnahiUwZvqkVivPMOYYT
# DATA Y6J4nPZBGs4tXno2yn85gE+/DZkhvhyNr8weRosB/N674jjzEd+yGChyWT78T8VOGGJfHlSjoFBD8fUkRD5ZU7AHeOGb4pYMq8qP
# DATA j3aeZbyPzOM9XGKLaKcijUpIrvijFK2TN0qw2yo0y2gOvenQmw69eSPozZ3Gmp2mQJcxmm9zCnCVGcB1TQAcetOhNx1606E3HXrT
# DATA oTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3nxv0ZqPVHLaDq6I326POqPsC
# DATA oTdLi887wTcp9JiGRW8gMmM9zsvBqdANe3nGBk3RoeJfgnaRX9gbjqLuai6DCRg0xn7Q+rza9Vq+F/ieX+/xn0ar2m16ZB9Xe41q
# DATA q9rpVf2g7QW9aifw/A59aRQLo93ttnqRvKMY56AZ5HGm9+Vxbgd5lIUsalWMVqMdraIsOz3Pb3XG3e6k6tcpep3PexTZdqMa0A/t
# DATA btX3u9VOtdWq+s1eqbb40SDyS8zDfjschcE65mFzXVKaEvuBinHHgjA2raQU6/iwOxj01xAZ/a7XCLqfd9vVJqWk0fPqlKau5wf1
# DATA z6tUFo0mpdD3SmjFMOo022vj1up28rhRwFY296yaUS/SIv3moNm+AqmRm54mNUortkiNFJdBbxdSY+EKSI1B1I2GFqkxbA87w5zU
# DATA 2BkGw9AiNfqtQbdx46RG7G2vbjNpaMC1fFxiG5uHtCVjQwmRypFfmhE3u9/28C+ZGh6bG3kQery1lhjlVzYnd/T6B1b81s4lOEQI
# DATA Cts+/zru5jmINk0PLQO84ApV5X45sKK4v3IoZClPWpQn9G9D/i2sVjVbBhvZaX17LeFRjEVKs8z58uVSawFrPcJxI6rxwsqg7cn1
# DATA tUAyJbCLb+dwSkXDs9jSZMhxIB0H0nEgHQfScSAdB9JxIB0H0nEgHQfScSAdB9JxIEchGvddvyo8Rdl0DPgjWTMa+fhAn3c/iZQ/
# DATA k3GPewoXiQt4QoJCVX0XG/32fEYyDqbCfiwEouaqVihy5eJgREQW4snqOL0ctffmcTSI9GlEnJGD/7CP8ihyIPOTN+50uDsdvvPp
# DATA 8PIRLXdQ3B0U3667/dwcIH8QP5ImVKHxaXaKJf9YDlna4Btz5NESTUWTmcihTjz7cPXUM46Ccs+rzk6PEIqczMzCSXRJ+Wyjaimu
# DATA R27idHMyhWvUPuftlLN3Uc7mHSVcFfFh833oL3Hbj+jvFs1sGhQXgj/8SD6+CHrZJg8uKRL55maRSJWbIhD5Jk5xjnCsG4NSrgeJ
# DATA zTIeWe5UVXAeHKfzwWWlKc8pBDwn8UhOMCcLpkBkPDTBBYVgvFFE9WgCg4gmLIkcPOaUaCLK02hnXjVL3toxS97RmqA0JusMeTOc
# DATA QFeAtXo5utSY+II5cy1LOCwr6o3gXaankVO8QMLzOjDnaGjGH2qCZP3FcjIfgc2uI2N0O7hkvvxoc75Ii1I1ZTlkyySvI7MwpTmp
# DATA N6M5rYd+hsGgkG7FggRkBnL4DywarlLRTAhlECTImCNCn+fo749PtXHzDOvIv9mxjnyULFnD4qfLozw/tNr0XKtPJ9MRNo0A00Cd
# DATA wBzTKzQIphkpjNGQTA0azAaUcZNxssSJt5r3CSYErK3ASgli1x1Nwp8ZoY6nVJ/Nu8JL5s9HW7RndacqOUTza2+uL0kOfZQmx6gD
# DATA lGaa3RxFBh3Lm+So0oTLAVQ47s+85QzJ1T0MBIIZiAos0wTK+5CK5sXlZ9huPt6x3XClVsotFrKWFRmmyRLq40soVUzEeEj5jCz8
# DATA /aBiDYe6Z4HScixdKZtlthBvKNWF+utyftyulO2rotCQm9luEu4m4TtPwt2M+yWfcW+cTD/Xkm28j8XsaBEqK+9qufcGNehyCev9
# DATA l0iu2VbXla2U1uZQuRBO+FtZ/mxlX6RUmEGCnUPystPZQMdEnTS+94OVbZV6kr+qLmc9xl84NYXxfVIgewE+wawXVhwbUvWkCbz2
# DATA L+QP8dFpHm6eU926F0nOaUdhW89sqZLqWzAczAaqLYbav/zTf9JmBL9yHIiUnViQ3iKaTHjqokATouj1PdifmXckVla4YFrEECps
# DATA NGMZL6d9XVyhl45PF+OpsmbZYOW5wVEsP4vlx2JkmDZD1MzS/PJ4zyNEupQ0coVyK41ywTmjBqhXoAUzlKMrTsJ0RVO3WKAMNTKG
# DATA IxOrXkFZLSsYZ7U5q21nq22lvrm1E7d2cgWLbaNxeJPiuwxoGikdfRZzR17zQnxBg/fZC8JvMwRwzs+z11pWlk7EVmTbcli4VljT
# DATA kKV+uvwu9b989puveHuD6UWge/2o6c7MBbPCIAdEysh4vwi6t5Hx9Zq/ef1FbSiwIyuXdomtedhEN79i4tu7zuiqjRf0+wda/3eR
# DATA LApVYu/bF0XbBGKinV+5IJvrVrwbW6OtzFezYCa7UnmVS6p8xFs8TFPILEQUati9N+RMsIqz2p5sO9XyS9L/xIKqmtPYrYzYOxLE
# DATA U8KfxLZilFbeBdiq1D/MzP4SND5j3H4gzlSj1MzI4ZNxPInyfiKGWu0Ce3VSlrw1Kx3UmqNcvJnlgdUKJ0xc2bgiW9/I1C1VAb3T
# DATA yhsqVJ/pDbR2MLpUq++hVC2ndD+2B+fhsJ70IJxBO3hOCYhxTjFM57zQy55joMjhrjwZR2LA5x0XUgahae7XeGGLjI6ap2B2SKER
# DATA ms6Wc+p6lH5wUVz6Duf7q2I9WxAunqPzHMLmcP0TM7i+PP+l8K5Azvrm7J8VmgtwLrC4vlglcP03uu0rALoErXX2P61w6BMDtv5I
# DATA 92jI1p/Pf3P2vwyl6+wLuvErftfvz/8DE7pw0sE7+93Zl2f/kypNOHHArRfC/mfj3tq6AVRgmgDvOkU/wfXN2DFMas0gT05dEqv3
# DATA Uc84E9XvE9YNl6ULLbtdUdzQIzT2cdhHPyWzdVHD5joDsfN+hBnCNtjWp3SXiZBDbRVM/7xnuG3aVqlUbo61JbRvw3/iLdnWW607
# DATA f5pRcesbixXsOhFboYCtNFxBLRBKYhxe64Liuna01kchGZ34mWLdqlfq9TqPGpQB1EXVvI9oADFWDxMseNI1DudYC9Y7/xdh/xCR
# DATA FBx1ZiAUKK7oEQ0EOFtQZmhdWN02mynFxvOs4FkXJsBxs9zwft3Du2ZmXX5UfzWcebc4ol/3gL7TeL7zcH4ro7nUxkLSbR/d89SG
# DATA boKRVUg4I34yxWy3k0mT7jBTi2ZDLJr1YZmH2ElcoYTGQPpQo4kpCZMYLKnZUL92FMYT+CsHIVhFzBYqJgujbWgyekoDnF5gjmfZ
# DATA HEmCi5RayK60rDxk1gzI5H0Uf6Y08Vb0MdU5uFfoIp8p59Pm7N+YYYWP57BLJkTNQ3HAJkNGZolZkJmz4pSiB6dkvD2Cpywehuok
# DATA eySGYZRhH2KcjbGOGcKrMRDuCtIVj7ABcTCOpqHHO9+ZwjXnscihtBxKy6G0bhCldeEYtNNUZ0fz+fZmAVeZBFzDHMChsxw6y6Gz
# DATA HDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrruUFnBc1mvXVldFZz
# DATA 1Bl1XiB0VmHVeSdwFmcsx6XHGSdoprpfkKNo+91ihjd6vc05Xm/0mqsgp17ASCoVlAWX6tS7vV5/HVyqIYEM4pQlqNTL2hZbqsHx
# DATA 5ANz3SJNathrdNrrnm+1dnq+1++1++ue7zZ3eb4b9TuhX86EadBseEHQrlLFbvW4egfTht+q+oHv8bWqXKv6fqPqNzvVTsfzu74d
# DATA NG8YLeG5usPusLcuBxkXVqr5nZ7XbPhU4fFqrz7u1UvBmbxbCa53BQQWNyGNwJLWaCGwGu12vxNcBYFVj3pRaCGwAgqokyOwgmF9
# DATA 2MwRWEG37bd7N4/AoplQlX7fadIeBDRWFv1WhZFGRjwdoscH5Az3SdtwyvjUCdYBpNq1si4Qbzl5XHKZWGPAyt1hyew3pnhXmeL5
# DATA A3rULs8D1835tJewy15CWR2En3DNYlu7mIjiQoDMET174qMMufwJMwyuWbErY7jWenx0RS16GDZBu4zzWEUHfmNr+sXfL8in4ova
# DATA SA77FQtbTzY/b8bpC16zYQq3GetlKvhOOK5tlXfztL5UmdfVyeXkwsklR8Fxvhzny3G+HOfLcb4c58txvhzny3G+HOfLcb4c5+sV
# DATA 43yhLqgT8tHw0KZ+LbBkyhmB1N2Vup4s00GECsK16jAesZGpGua9Vh0Gz2IMWME7aZogjm8rywvNi0we6qPTI+mTzWvvloxpa07A
# DATA JmwFk4uK0L+wrZHLYV+YYyYQ+k5dxWevsV0j5rn3bn70n+zo02xNX7B/+IRt9Md5bLDVchTPKDsU1YxlRJXuw7EV/FvofKi5wqVa
# DATA wTnGaShnqLjU8dY+9ijT/JJfZMVPCepSV4OTUB8mxj71TnBmUVmf9BtHkKo15z5O7VT1j/TLd7fZHVyGVD55uu7mKdt/XIiMiFGZ
# DATA OGiRRvUmnAZEPMTqP3xijPnPXjOB1xA3equ58Dr1VaCw0TVq7fkxyDtyo84NPntUTq9KrqlsW9sLp3Nd4e0WDE3m8HoKiO1lybM9
# DATA saEHi3RCU76//Vv5is2A9HX/r/9avtOjlKefvfYOIx5e23+8wfJWRjd1hdniAVvse1KoTuLeqSlcSU3BqSi83CoKl1W3f6bqCsYB
# DATA KykSsT5LyX0Rorrd+1DLcHNK+SDrEtKW8eaEvK3P7ufKAxJLPLTtwQfcbnmbFxaFNj5VyA4xFqy2lz91BzHVOoR8NHajwL0hMSkp
# DATA BGrV28XtnzuxiRfgcDX/95rJCUVRjOvmJpS1RtZSEy6rkvVpGivTLZ4xq5FsNxgzRiXL6ICwclkGC/gEQmbTpWg4nLKfumIE9KUy
# DATA qsrDFQWjZCaK9pamBzQOQrbok9GC4UppxG50JnAp4BYb+h4vDLLe+Cx6xD5epaxxIcfo5Tgnb0Jwxp0z7nYy7kpKOU4zy2lmXcKq
# DATA 22g63pSW1nsi2EQVW83llROBq3lO9rltxcbbELlXngWduTrpb+idGFpxXN8G1XTxlOEyO8sKAuuUkZMJe7QZgIC1Yh7d/houpkP0
# DATA afLpQF1QFrV8q8gfdour237sV4JK4yc0KOoYbZCUV041etd7/ImrbBFBbG4xfWv+0AoBOGBkw0ni8VaSLeDhphje4B6W7lwBBW8U
# DATA kzc+rLzqvLg68pjyiLyUspHWSZwtjcDZXFpNRUmY/ZvwOHwgXaxSMwNhRbtB0UxUPrDe28msqIUmqlkhIC22S07pY9GACdEzQSRN
# DATA TpUj1DR3KFyJABc9fYLTXTx0suaU5f6reaa4MCKSjbwcLJaKwjSJp7jIG40gWAWROKZdQLsr01EpVYR8KmKbyfnUQkqr6DrF3FKv
# DATA 8BvXoZrzmZpzsez8y2Gh5sOMM1GdibqTiWrbIs5AdQbqVsPzWYu9flhoJDMMdIt4mkOZHsgyKQugViwKoKTOe0fLIEJgEcd3OLvo
# DATA dzSVYcJjNXQ5WS00PKJ4YcvZ7NToQe6o4MrRNbEREhTVAgg6ikFAjZXafcT6lug81njr1InjNZaq7FFABeNPig6kLBn9Y25cmSss
# DATA PQHkfMThqNjJnhvTLW1mFZmNDwz9kc9Fu9K6w3SJ9lMrJiN2DmB0RMco98XbLEy0SO1L3nyXpWMrGEfzdUvIURYfcdrf5k9bbNci
# DATA G1x2EtgGi6KZbzIbC2WM3dXSWK8AYNe5cUkA++MnmwnskrFCYMckLtKMdOW0P9Uk9k+wZZRSni4z2e7FNXDG2qlKSBdzIJA59Qp0
# DATA jE0YITZQeP0lGbpKMTUe1Ly3YxZYXbLQrjeNM549yl4XbFdiiihvApFr3Fp5ZVhIDEAQ0etSxWd7arR9qQZdMoP/5R/+uDmHC7VR
# DATA MpolXdNIhH/hV40H8cIg7/mXnL7E2rdkVIuWajLXp+4XVNtS1vHF4dVFLPb5/REfCqe5wbQfHy3BfVSu34ru7gQVJfTHkIx9lvCN
# DATA h/ybTNivI0evWFen2W519cNwKlUBUtZ51kltwRQHCrayz1dUbaFTPYkWQGLJ7ibztMcYD/ReDPo4BVpWaF0zKAOiQZD1R9Gh3pOK
# DATA Qm1QMA3k2Ve/f3upyiesM449peLzZbSMdP69jxkcJm00gc6VmE/CmJ05fEEdN48AgH5bGiSvSUjFyfKKygEj60c4WsD5SRk4gwuJ
# DATA A1rIU8D0RqAo0lCJQruWqme69ktm5Htb6p4aJCQPyyuU3iINj2ncPKE06Mz8WB0lGCuB7FCqZUo2TDTMlFFAvdxsweA4hAW7ROYn
# DATA 1JBnpmdQveqUeo2M55IxJB6tZdUcLreIlZx7RPNfrcIN2++Z5usnu+brJ0zgs5arcL4xb91qOSyNjrAfXA6IUEIyNWRgtMnV643k
# DATA eca+itwyjEYjzmG7Hwj7GYtX0wyN3Ttyj6rO6E3F6ovR2f5UdrOWMrRoJMieRdtIMFcke8iu1bsL9cSOnS1q1x91RINxAv2sEP5S
# DATA KkldEK/EwpuN0aOSiGyC3n8+++b8786+PPtfZ38+/y24d+e/ABKP/vvN2e/OfyNovN+ffXH+87Ov8Pfsz2dfnf92lahnh8OsvF8w
# DATA jQ/PfnP+azx19jVdZN6eoPfo7588uuXL83+g5/5y/kvg9BCDfhqdVA167+vzX9Hf3+JnJu79yaH1XgRvjdQ0mzcvU86HMVrpTLYF
# DATA g9jwQ+ObEeV7mGNkMQyh9MOWgqxv4PeHejtJGg3iubK5siX6I27t04TF+reS9N6SeFkNyMH0bC8Ncue2OXqrZXJzKD2pOvlK4sdS
# DATA lUTypHwzeiJrzTE6uRFaNu+onqtDF5QVMmHE26bRbOl4ejuU2bUj9cSs576cux54mcVv1icDQvduYs9zN/ZJ3i1RdU1OFNRHE85Z
# DATA Z03Qv3zoAIUWT6c4owOYEBW2gRFfqv5twQCXG9WzQuxdnAjH2HPj/FOO8xqpd6Xh/RVZgLmVof0GRvadBvbLjOu3M6xLlSzngIXW
# DATA e5ZN5yZIeuWk6kURcamGLDdZGhEze0hE/FfGxIpAsWRxVtZYRcniOFokc34myvhAe0Lm0mKcDLNdMHkfIw9lGascI8peeAh44y4l
# DATA fxpjg0lCVhn2bMlAn1cXemeYLVOAwUIWGKVMZn9+Rbvt0wjth1N0yiUjOjhCAoRjhUl1ujJk4URwXwM4qzXPzNHwHA3P0fBukIa3
# DATA y+ix01xlV2P3Vu32q5jt12G1Oyqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkq
# DATA nqPiOSqeo+I5Kp6j4j03VLxWO+g3Olel4o1GvWj4AlHxyivPO4HxCtS3Rs+ixjXqDUN98zudIjduNOj2VN5QBGMaWU0QjTyIZrOe
# DATA l00gtD05PBX0CuF1msGgMVgpqKDle0EQjINO/dhvNj+vtr2eX/UbLa8X0J96tYsv1V6wpuRW0XytgEJr1cfN9uedjtfxq02qB37z
# DATA AuqcCWwFExd01mZA1yL3UeStytlo5RnQKLz3W81B0G7UV6LcaNc9v+V/XqW0Nqm2VDv+tNWkuH9eDXr6ypUT4AdXAN1xq9CgO2lg
# DATA Fuiu02w0ms0dQHfDUbsIuguHvUEzB9112q1eu2VAd8POoN63QHcdv+E3O7cAukOTqm63NzweXqxby3y470XUC8RhRQIuLeatoOIa
# DATA vGCWL5cVg1Z2y4qTSufQiiOy5O+3w1rngb/UoOqx763OhpN6Ri2BrU26cauuRtKY5UWEnApb0HXrtwqUiXarmLW1OWMGPr36Vd9G
# DATA g9uhFtyUKeLQbg7t5tBuDu3m0G4O7ebQbg7t5tBuDu3m0G4O7faKod1smJskmw9s3RWQ2hCn3F7b/4584yVHxnIp5FmyCCdyP1rU
# DATA 6x+Ei3GNZ5J7fHH/dcoBHEel9ygn2hwaM8s5375XeMcd+UY/ZtyLLJJ3sR1vz7dD+VQOk1mBlN9ZCoafXTlypgliMgU0RzrcIWp3
# DATA iHrdIerSMR93nNodp77sceotwrc3dcxaWgHbwdBrl1VWc8z6GQp53AZ1YaiOZ6uaga/e3tG+krTVzW7GDoxcAF49lfdN6nvOLCiy
# DATA GKYxC9C1FLaBff+y6IQtFrwWVfM3C9/KeAopZjOsoRhwqFry/4Lo6udNfM0FE2G/vS7CXSvCwe7x5UEVlDaOB0eTrlwQSfVQrtur
# DATA vhc4ECsx9K0Ydu0IFqO3kffwlmpRkRENenFxD2+xlcfDGAO8MDnRB5LfG0FlE30IH8PPeKBD28vILJlX2KdJrXQCr//k1IOSJipZ
# DATA DF6eGEXirRc6l9Q6PjdOzVCFOKQgKECYOWMd4CCB0aNC0sfBmT/BNTnKFlh35ykVSzBN2SK2RABwGpwVGHkZdYiTZJ6s3RzaYgAw
# DATA 2dD7Zck00h3R+zR7OcYMacwADG7fA+wOVglCtPO+5mJAw8tzsNhBYp0lu92SdXbrS263XhYK+8zlgXjB3FoIXjX6JgVJQKb+ZCy6
# DATA rfgHfT5GClNkK0P1masKvSAKHDeBTV1RQLpucuoaNan18NTdlBBL9Q9ZbdMUWET6zRRpVcM6q7bnCtK8p0dPhJaZwKk0P5VtsQjz
# DATA rOFpQdIl9LBRYjlV9hkqGH3IImUoITCpSUUDRaGT3+UbjFFSluDmOH/MYq8S5YiyWMf4PTNRi3kOSFEVPaNFnFZYmZ1jo1XZCxaa
# DATA Vry38QFskCIosgJwBGNLtD/Cwtz2WD8AdEXFmrcpRUMd8Xe0xNWQZreIDSWBc6/CU76Kd4rNsqLqhB5jkRxFULGqeZZRnbCy6NRj
# DATA UIGivmyKrn7haoxfIQEbu09ylqazNNdZmoVxynlMncf0IgP12QtTSgwypayYJsmUVeq4QeTylJOJNJW1Iok1Vc8r4qyoyGAE3Tk0
# DATA I6xPMxWMPSuerN6pdsXLiJejgL3LVoJSd5Q2qZYbOUz0fHPGbsIFHE6wgUEEsh0UbBcomFhctmm16U7j52a6i/6y+X6t0sm5qj5v
# DATA vlvLeBbNj+cfI5bn3yU5Lv6B396MctGFISiXH8wi6kzm7Fqs4siitgyxvuG3vCN7JSNo1umCciN+GikCGU1BsFVuclohux17f/tU
# DATA L0b4usB4iZCxhyTDmoec6si4h4CxdRJmY9FS1RY6XZpMsuvg4NxK/n1yknD+DWmcmhdzr1Ev5l6za+XeA16oQbK5r1WZBMVSAJ0X
# DATA LEcp0phyl/iFJxHwRdis66lDuCJUeg25VWiDl8+w1uYMsxq05Nn3qE+l2L2b8lR2LhOYPN+CUq1rdFpWvi1gSvEyGRtO8Wy5wJAD
# DATA 0dJJcWLFIwbDeqjm0exKUfDMJOwYOxonz0HetS+Rd2+hCqQiK5GvDxayr1TtGkG9lH0VnkqziXokRZHRPFWUUkHsk9aI/ejDNDzB
# DATA Vl69NMB6s/nSwNPkmd2HXzLLPticX/looBB+ycNQW9c6k95lToVwI4DuE3rhMdkcxkwnC/chNbyJQjsNWXV4mgyZ5OeNsQ7sfSxC
# DATA wcy0whWzfGJWZTIa6CnXWZMXLfo6ss0ezC5d04LNGZcPjJJxxjFQNNB0Hj7AVeV1mXl+l2rYUOdV6DXavGeIKiq2BbILgaZLyhEj
# DATA thtj5LmuJd7RMlZ8L+bGKu8Nm4285fx5RXi9LA6JHOM1iheQmLU5Xv/v2Vfnvzz789mXYGx95Z394ez3Z1+d/Y+zLxm99eUqsOu/
# DATA 0E+/O/sGjK3zf49bPEFynf3l7I/009fn/z9779bkxpHlefazPkVUtZVlZhEAEbiDVFJLUdRlWlJxSFZpZ0taWQAIJEIEEFAEkMks
# DATA lcyk0vR0t3XZlNnumK3Z2Oy2rc3DvuyDuqo1pVKV1A/7BTK/Qn+SPf9z3D08cEvklUnSVUUSCER4+N2PH3f//748/scCwqEwKazv
# DATA 6bc/ecd/h5+KdMe39Ptv+E3fHn1Pb/7m+AvGgwHZpQhgv6Gvf6IA6SfH7HoeXCoZ1A9d5sjmAUkfkkbwgVKT1LjAZNadsvq9dCiU
# DATA YeFU4Iv7mP5FI3FBSruFC7WP0+fgAEChhJ8Ch5E3ovJ2z67SyI+D4VqM132sjPeCQxNTx/GyfS2qg7hqkNeSUrk8kpeqhdmS0SNV
# DATA LYcRxTM5nL9faqO++Z1cJb1ImBdchiomooUvO/NDHS8H9Nqs6C6c6fUozEAHGQsiASRVd1mGysEl56XobbAXSGSEGapgThHD83OI
# DATA ryXv7ainZ8fUu8n0WpxTKqULZK+TK+Nqe2axlT0rtNfJqXBoL2cOXLw5oGlfZ7MCXorVlquyAC7DANho/D/l8H81o79UzIVcsKBf
# DATA 16xRXQYHbCH5gJpibShlzvv6lBW4BkL1ipMwn853pmprBG+BYJGQKEjMm3RQnHJZcEJxKtfBRmSwx+zrhT8IG3BSuN7CJBgWlCVH
# DATA A1rUm6H4wh4XI4y1hGoIryH3MswTR1ibAmbHCMwDClRcHnBOURuHayYaFymLGcTukXUxjcahdlTx8hlCxzI0zJaC2Cz0YrFDDAjK
# DATA UcIcJcxRwi6PErbhkLPRHGhT0/lqpwFnmQVcxCTAkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnM
# DATA kcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwp7NqQwmqdao9/PhMprNmv9zvPESlsYel5I1SYnS9+3av6rUG90Z6jTTWod2yFy2hT1Zbk
# DATA EJeRlEGNFSmFlOX7OaWe+bKr+HbhNXL5b96ZC73e9i8x9HYjC7zWzgUuqcoC96sNGwKWC7zdb3U6/fnAG/X2hYeeA73VhMUmkDK/
# DATA kYHe6q1cAGE9CFrVhWZBj3u+39qv1YeVluc3TyCQra4TzTMAyLixaQCZtNscgKwetBsbAMhyVwAgq/e6/XIGIGt062GrbABk3X63
# DATA 0gstAFm91m23Lx1AphvoWvhUya9rClnufjM66gWC+ia0sXwQmjeW9eM6pxYcmdajHSzKLHlm02WBUkNZIBXb8VApLVkT9tkgyr05
# DATA 51EQywDP8fzFeJP8OtkJMKmWeCQrxiMpmTK/zLJkoa++8ILKbT3Xot7bz+ySuei32J5bxkVrt9t5GhpWmVdTynLlVpgrizXWTv7G
# DATA Od+DcR86DJnDkDkMmcOQOQyZw5A5DJnDkDkMmcOQOQyZw5C9ZBgy1AUKpTcMCyEvE/V2ywV2uvOnCZndYbr7y48KcKjuh7tswRbQ
# DATA 0T7AT7uokrdNhebTZbCOku2dz6L+tjy085kOmlooTJBg3A1LY7JQd4rqVbft4G+zqrM+uLEt0du5ja7gw63H2TG2nuDEPrfmONhH
# DATA qN8vpYhjH2vei/TTU5RUVvKgiXGyrXor6BNL+ikB496N3YnavZ/+FIbdbUofAn+Vftv5jJ/endzmMxkUJ/rxR3yN4rE0NbkEm6y/
# DATA bTL8ttQ6TOi50Wc1jPL8TaXvTHmvkHD65I9RfvYe45BU/vxlQtFnggflRxRL9oktf/vz1a9j0ls3jIbb25TUItK8c5NNW0DeVJZQ
# DATA TCjJpl5QQ+LUl9iNu/NZVmGsyxJ3+z7KOJuLl9UgFUvkquSQGgt2PssyDEWH4owoG6NXFTmPJd2QzujGDX1zaTIj0+QzFfNbcidO
# DATA 2dF9BY4ITaw/wKm7f/viv6gzjcDmRTf8HepiKBILwRf9nTVh43ikHfZDHJfk5Y/F0D/P6sLnqo7wZFK3ycWqrB64nav9t6We7WIG
# DATA q6uedUOhUi/nW1QyG4uUsBD6uDpwK6MLr60zcLM2r55KcIb0pKe4fO3uwqr5WQ7M9TPrmsRDqKxm7UElClHRSTJzwCXR4jMo0ZDm
# DATA Q6ZP1TXQPCZjxU4u0hTsQTSm6eKyQLGSRg+Fc5nkmDFOZ+KMOhNOX+LF15c4LUnmOuhO8MpKzl+/HifzHg7Bg8gB8VV9cDrYw6um
# DATA 8ShOaGa2lilzHUUrnp8j3JdBmlnU2Lho1MwyEZMzsma83BKRVGleYbvjl7U0sGA2jZwYvUzdAgFPqSeZyIct9P6ErLKCuJ5Eyx6R
# DATA N5a3rObFE8wiAdcT1sNglkxZ6itS753QyD8W/YRYSX0YEfs1Qh8nKY++QEf0cw3HmVDOhNrQhJrrX51olxPtsobflcbXdRDzen0W
# DATA gamVl60yUl5viS6U3ZQw8kzCGA3tYBDnRihBCOgBrOTdhYgNio41dQKZCyv4WPiEmmMwjPpQvIHoNpwPIiE1DsOexoydlp9iIqqA
# DATA D0pOG9LqhSVKWg6esgk8ZRRL0bHevfq8DoiSsBtNJPDl8+q7sdtHuNn3+NPqO7W5o/hC/Pl5QKfYuXdKlfwWDMfVOvlZWeRYFuzV
# DATA 0+L4PCvKRjaMX0k82xtkjeEThr2zhIfGJc3GZDyyFlW2YRrteT+OWNuqy+ahp0/Qw2qcsdjchOV7YWxSHPbC6UVQBs6Rf/XT5d8b
# DATA YfrEY2e7hRaANq6CO5n0smScuMJT5hnapsNBMHxCeaXlAzk83DYbAtPNqEYvHHMZsHgbTkF4vVmixXVpkLoYpkXWDE8LZ6isz7es
# DATA VUu+vU5jvOz7Y6bOLDK1T9lWVOfCcKWQIVaPxmBZSF6yNJ0sJqSK3hWm05L3NwzECLuDcfTpLDQKilRJaUIHVsJ0gGnHIOCaiHyd
# DATA qop7AbmZdVOnzcsT6qDu9SQnP6C6wyqIWqrZYEhNJlEauQqxhapQowYJTxZu9wmkIOdMWZV7AcsuKuTfMFSTTM52pSFnRL37+WH4
# DATA WbXgxula8OvBkO0INVUIbRYNjAPOkHQ2wQSMEhgknUM1N+iKzqLsdC55vFKD3GU58kSx3SjX+mEIEUVMtciiCNNJ2I2YCCvql8kh
# DATA 6xmaSfg4PLiIHLTHvtNWwPL6LMyGUgVbQeVKzEVNwaVp14i7NnT2itRjpmHdAFQeyqgDMrBhqmMHhTcgixD1C1nGKqAsfEiVGjqQ
# DATA +9gqpvbYXFuoygvk2siCcH4N59fY0K+Rr2nOreHcGmdcE1rpArk0jXJVZXP0V5jiVM2Nd+OZszLWeTeYybiSY88bvXmZA7u/1clF
# DATA fc1MenlXgz1ymit61su5lJ2PxM4Q+hb3+2IaBD2xC3IOCd7VQj+zjWR6nW21PWVH+UV0Cx/zhn68QiKlnjY9o/5u5vlVOb6JYSAh
# DATA 456MFz5zh4uj4KncUZZzcuGEj+at9p3wJhlOiVWmG0dVPW2iqr+bqFZOjKrf2jiqsu0HkeVPJ8VN357Fzlwx8asti55vRa+yJnZq
# DATA VdD4s+RcAE//wNu7yfsUR2Riy41sfiSjO6+KtEKWhTgWYtfB7FKuzk1ocJ/KcdybEkRWkY1vxmof5tIKB46YRDQZ7Fmmdk7h/z+Q
# DATA bdrVE1SamPcxShqQjkwZDgIa3gHbmdCjZKBhBqaoQNksVgMpFZ1QTbaEkmr2/lpISwzJ8bDIMEvesUVv6YGHGQtNFF6UgteLfvWr
# DATA CEMKu1fGsxSC/Okh2b7xKM28qHbMBuFwcsLC8VypZovHtl81WwaW/Jc9W/T4A3zISvxMgclWLmmU4dSqPmLDcom9HFa5xTqcJWQT
# DATA k0ln0w7/G8MLvwFtMM8gPP4t/l6kHf7Xo6+ZR/jnox+O/uAd/8fjr46+P/ru+D/Rkz/QJ8UtZMYhiIUSOIfsMRDxa2AUj7+gG35/
# DATA /A/00He47Yejf6Fw9JN/OPoBuMRvGYNIQTrm4fMwwzDVK5tYcIUH8QQ5Ss8UlL+SOxyNxGDhJEN3lgiTRfSASlFoBDCsDMGDelJt
# DATA 9EyisEuz8XVww4d6GwMNAIxWc2hDazKhC+yq4YYLpXJ5aENVR/Rt4Gxo4g7/snA/tq9YHe6juK/2tFw42pAjkAMbRilXdoc13KzY
# DATA LhxreP/pZIheJtDOkFHcmw0DkNfjKWv2lLwP0Pdz35Xt8+LFL2yMp2fN/ieKw2zEPWUq26DgQomngV7LCsaCjlkAGp5cBVdbLfMt
# DATA 61nhDE9Og8MZupH+HCO95haeZYB/OTyFVza4X/zYvtHQfsqR/WoGdqmWc3lgMQufVcu5DDjhXCqxAgASkOL8RV0rsfqc43yCAnFp
# DATA KqgcaGt6E3WK4uHN17KtWEt0w0oas1d0Pt82JBIaL2sWu3Qad3nFkcdjjYpjfhzXkh7NtcepiX44S2IvGDH+jYf8kMyGqBthaTxn
# DATA E+QsgPApDhYj8F4Ib5TaUa3WCsl6oOJ8LwxSRIhtu+4UrhgxEtmrI5Q6WVtXRd2ZHUr9crRCRyt0tMLLohVuONRsNLXZ1DK+Shv/
# DATA LCb+RVj4jlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehY
# DATA hdeGVVj3a7V694yswrDX98Pmc8QqnFt4PjWpsO57Vb+8X2y3P/WbxWrTa9bp70G1Xvm01vYqXqPiVZv77XYul7p+p9rtz2PsKKzG
# DATA UoxdbYFsKCf9BODXzgP86lV/juBXa2VlLcfWMoJf2AqD7iI40eIDtuq54CvVdj74dnVl6CaZudBr5fqa0OtnCt0ukZbv1WrN/Vp7
# DATA RF1rsdber7U3zml/EUbY9L263xw06vW5ULr1bqfTXYqiPD12UNqNxg5KE7Swg41evdXsnYgdDPqdfiOHHezR372KhR3sNerNusEO
# DATA drrdWqdmYQcr9VqreunYQbNNDcL/exvN19dw+8S+9RbsIm2Oz73NDJRq6vVWSN1NFBQkfksBhnW1EldZoPVhYXHhBXNud9to1AWS
# DATA n3eTuef5sAO8hvyxw2TrdOMcqmvTCZkiRm4+qDvBvKFiYQPzkbU3F+gRXS17lZd5e2UxJZ+0Cnyf/Jf6Y8+41xMH57K1MJ8na8yW
# DATA tUlme8IBBx1w0AEHHXDQAQcdcNABBx1w0AEHHXDQAQcdcPAlAw7afDdJtngxhJTGR8UR/Z2ftso3KuUCzSzVTwdchDsyZdOYr/ty
# DATA SIYPuqGR3eBfwaXrjhBw6P1//4fXLuNbLwwnpQ/pvzFoaxTund3yax9ufcBa6nyOjhdqEAj9KEGUeMpDEZawzOEbxMXrHOJepuMF
# DATA nRQh7pin8Inf9Y59lE1S54XpFH7k8Jb3b7/5fxGZhbRvVyvlG3KVxT3RNSBIjTJzCDF3tvuks93uTPeLfqb7tKSw63DWe87Fth4T
# DATA 9i6ahnmi5L2Ham9ruyyFgz3T0+HPz9HIy6CAzR9mv2gG2KIkwFkJYHl/rT6r/y5Tu6QiyGv6odG1eQOux8DrxfRDesBntB/ACYmq
# DATA xVJAgyBKSt6jaMruJy34LhVQhMtnEzmerAo3d3w/yKSMJhBtjPt8FjkTzZlTuFko5ychTOXAyO3AJrp6pZtndArWakHOGHLG0Lwx
# DATA tNCjOtEbJ3pzkhl1PcRwHkh9ZaJFLzb4i0/ijlHEeWi0G6gZRntjRf5SGmoKH5nQsNCFuEUfN4uSRBoAvwr3qMbj8IZ8lu8QHRq4
# DATA IYe2dssSzZSNwV+PoToD/1imZGPzYNh3IaodDve1Ge6LkgJ9EpX0Kbea1bAvdjuKLDR/XH0vb8/lnuUxf3oe4F1WXpySu/JoDT9J
# DATA 56oQV+6hVVDpim0lwJXHB7GINcUzCMYEkGMRyMoILUVLJKKGB+yFElkmMQ9pXNuHF/lXkGdJRnn1IlEpItsvzsa7AIIwVDsC0ajv
# DATA s6Gsz5xKo1Gzg+XCzosC0GbhTWySLIEmx7SUA8YGLChzxtADliD0+fhXZy65hxuX3EM5YC5Wui66d2GLoCMMmA1AxbGn1L9TJn2F
# DATA E1bHUSyhPDoMxceSPqL2TUUgk9S7ms8Ij6HaF8W96TCcKrBAouKSTuLp+Yssl7KrK7OsNzllmf1sHa1M9UtSZj+DABHysRNThGxA
# DATA FEsT6XUULWi2J4wsyl3qxHEx7pM1Ynha/fBANKf04DYVSXjcKYs7XNIHTH9j5oppdFz6nVl6eP7SyqfpOSiu9zcurvcDgNt5MYP6
# DATA +oxHlQ5ES980Bur19uAPfxIeirXfCaCg5Q3ikTQsTA7GHBpr1I09KqgEtDCgcsCrYgd8P3oq+DiGJmSFOS/8dv5Cy6fsygotG4VP
# DATA WWaPV5eZHs9VryjKgbiWlZf4I7APH8MANaFUWIFDccSwPHJXjRPsjfPucvn2Gd9FnRBEyDDuieWJY1PeZMaH51g8YQy0ywX0e1nc
# DATA r3+JVDYtkfdDpVyH4WOqflKESzkfFOoBRpqTWBsi1Bd7fLwLLeBQBAkFDKhaDfdvPLNGADC7eSiLUm2koHRF/+4C2sxiQs5UTFdL
# DATA mDsXxuRl8LNZQThHm3O0zTva7CrlfGzOx3bGxcaVPrlLEpyWKbnM9DAConLDxjQutmcINbgk8lzOk6X3nsDe503WWH5q8b4Zngmr
# DATA 308AnWWhmO7KupRR405CnTU25LAdaG+ZAXfxvEDt2tvujk4E3EkAGeBOfbcAd0uxcb5c1uC48saQO9nNA3chPghjTCjIUCnmvJpz
# DATA IKoHMu+hDmHBZ9csM/YL29q9Ayxk8v6iZnm1l8/3+ZHH4VP0RD3rKfplzWM1fuxtuvvQfqZWXuMmXImo06YpdtOSpTZ9fiF1tuvu
# DATA YECheJ+Q5TkOD0u25LPSdZZOAA6hg9jzuaUFiYLF6Q1rE5omKdMdq87UWVCcML3igZuCNu54cWhw3yIee+Xu1+ra/GK17cxjwCUV
# DATA WLVS5npntXDqo2Yafqn25HbzNRV600qGnULRKuwFsvCfStc3pjgOZarIqtmTWQLQuyxsxynrp1oC2RtA5F4Q4zlDyFEvEnaToD+1
# DATA EHLv6WvF4789+uH4y+PfACJ39IdFdNw/LcW/0Zdv6Kmvjr84/hKXPfrnG7r4e/77a4Dj6Mp3R18f/51Bwn179I1SSIfC1wTaqTRk
# DATA O0zctTf12TIPPFNnvH8X7Afe/V4kZ7FE9F7tK+HZbz+JwnGPOhD+dhAnw56x/uH5nk3EdwpXgrjOhodM143h0haKKDsNsgUK1fPg
# DATA qfApNbTeWoTc6xDQYK0Jj/8WnoTjyGUzAtMpXDVHbnnRXB5MbkDRYXJBBqfm+qqvnwSTuxeIJPhlAOV48xXZjvQvjQniusJojgbj
# DATA gHKbFd2FA+UkzwI2c8bo3GReZaZT2rBRk6mRdFBkueiKwgt8NLyh32Vre28WUKOYhtS3vRGlTwqwfujpew9+7qWTUJEycPyd0qZU
# DATA YWZsA8G1ON2ANre8jq42cZa2weuCnVueGIeec9bDJVkPGkt3ZqPhpXAhXp3BcEn2wkbmwimthaszFqSSLssMYyhcz4Z2GRQ7KxsA
# DATA msMicS+cgENFpowZqE0O8Wx+RbZ049Fohu4aC3jvYAbRZYcFS4qklC/d0B7xk5AdFOL9Q4alarM9jfRUZHy9HyV8ijZNNybcAaSV
# DATA Kt+sholRhuyTRZiIn0P92qe5csQHHHhH0HvxJzSieZy8LmVg3J+WvIc63nJAQcHC5p3AC3aLnBXQCDKjacEkM+QHdHEgHTygTI66
# DATA 4j3mtI/FXcN7OcMxc3RwQh6tCyAyVSUoVx3zzjHvHPPuEpl3G45eZzrYtc4sv/KZxkV4VM86z3AAPAfAcwA8B8BzADwHwHMAPAfA
# DATA cwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8C7NgC8il/tVStnB+BVnysA3rIV6I0oeBYv
# DATA rpLh6OQ0WpbvzTmF0norl121ertZD+fIapUKFUBtDVnNenX7zK9uVTqVRvXsr640zvzqaqvZqfXO/upq9cyvblTa1Vrz7K+ulZ9Z
# DATA Wdeaz6ys67VnVtYN/5mVda5dt1tXmeG5dn26V583w3Pt+nSvPm+G59r16V597sZVfmZlnWvXV1vWuXZ9tWWda9dXW9Z2u67UG1eZ
# DATA 4Xa7PuWrz5vhdrs+5avPm+F2uz7lq8/duMrPrKztdn3FZW236ysua7tdX3FZ2+266teu1FRon/nV581wu12f8tXnzXC7XZ/y1edu
# DATA XOVnVtZ2u77isrbb9RWXtd2ur6SsbddDpexVm5VBvVHeb9bfpq95p0Oz06jXuksfq9Wa/Fi1sfhYDY6O5mnMMTUBseDyfiMXpN+q
# DATA ViuLMamX616lXh9UyqNq3SsPKuW53OjUw3qnuRTJ3joTTb2a0dTFn2PR1FvlIKw38jR1v131K/UcTX2Orw6aeidsd/sZTb1eaTRq
# DATA HUNTD9qdflDOaOo1v96tlC+dps7O4GKHN+kbT6cstmsseuZtbYnD2n5mHohuluKWLbvpjRpN3qCJ7ZnMRF/c7diAn1VewwfBNtuW
# DATA 0bC2ZawEuluhrmetS3Epp2XdLLvoGsHHEgZBLz641aYf8afsqVL8vESvGsEFtmIJtrIQ3Po8zAL01FZTvX9Nlq3Mr5Mluw/UWq+u
# DATA YWYZQO0FzTzdhbkTBfnl7fJq2LpdUmvc4cvqGju52a/uoOoOqu6g6g6q7qDqDqruoOoOqu6g6g6q7qDqDqr+kkHVM4tRaTds7xj7
# DATA jlLtPRTtj0z447YQq7jLZlt5eMi4chEVKY7iXrgr6Aq6KNts0aizayIyUYQNslup1xt1vopZnsimpbuajc5TY4U4V7+hUWpAOiIG
# DATA F8QUwmy7LQk8GinYSPZLQ14QT3sImQsTX1DNuW2UUhqqw+1yoVHbgXGEgyrbN3/5ofrv1u5f/wj/JhzMRzf3ClSuFqedy9ZbhNND
# DATA VWD3s/1gHA2Hwa1KYTKc0bQ/vVUtQDLuVv3zX3JUeBpr4vKRxtM/mu3thamMiyxA5j28+94tg43vhtFwG2+4MZ89Py35LabJvxW9
# DATA LtD611n+J9PhnQtFAhABHJrkIwjNj59EApX3SxUdJDpnxRLBqCCCF9DUE6FDfqGqM9DEm0Keb0rmsq5BoiQEyRYFpOdMyDRk6epr
# DATA 68wpzuCov8KS/cxMNCCRNidPS09nlXznNkYWOK7mNHIg9qESACUXW/KGYywDwY8LeYEOp1PndOpOo1M3J+biFOucYt0SzZ/VLIvr
# DATA omTnTRK0U9bQysfJSNndzUu67c0gjQthplXabQpsMQZvNupGKmjM71iNVYtVMY12XpIuj9ZakKMz9w0qdx5gaKKuRUdcvOFabuoX
# DATA Mm4rxbSMfAUbOGZCPTCAQN1gGafIKvpTFqiX4FJo+Xoy5uup7m2IxUJrSqnNAbHlWU8yzhPKVhTnENr4lJQIxrXmEPKRv7jP0Qmf
# DATA AqImsl7oqczDNFKtUurjdL+h7CKW28uUbtXQqNP/yBhSnjakoFgHvI8oFdN8WKgnKoci1rEoeb/AyLnwSHcwg26x1h9T5krJ40lD
# DATA bqAVPLAAUMVTW8hRhTOLgoxLKPRJz40+ljErESLMoGJ6lTlLkK7Lkbuqi5ccUb06NxaTG9N4otgGXFfihNXkoH6WziYYobHlGHrO
# DATA VNe6Yc/q/6fBE4ErwCpkewaTr8mhKlQ9uAQHwWFmUckAJLGHr9p7HLIjU8eNwa6BZYoxiNgecrhuRdN1yeb3422fxJRpHQyGAdc5
# DATA mjfohL8LD4pn2fZaFZBpUHm9QKGhsmgXRQkLWxMuOZaSC3rUhUeGbKME5XQCRIZOw5/0BCMTlNOsGwZ0BlkrM6YaU+20Kaeygfqc
# DATA YXzIXt95yJoog734AmfZqOMMVGegnsZAdeboy2OOrjQzr7mwsr3Av4gwG+bsVGkx9Pd0wAMSbBVloWaPsF6PQmFdV/nl50tN9CSg
# DATA g7WVQ3BzvEXmzqvUQc+3VH0cLbfJq1We2+SljpoFQ/62rL0sHhOT1t+N4ZaSNx6Ouzo6Sn3pzs8WTpmxB59snhVC3taz/IXTNQcB
# DATA 0xtptFb268pmHGjlac4fbYyxwbZcvFlZZVoemHkds4llSxoGJw32sEf1dMFgvvIGZt4ctRx8c/iK+brw+ixCzV/U25ZKsUDsOpHw
# DATA MVYvLlBEkpBMl6BDVrcCfMy1d5x+laagCcCD6p1HIwF+U24aGjI3N9byDRQReT8/a2EZcFDfJ2E8GVIL/YDXPZAX2fyD1cwUcVFk
# DATA knM64XnDcRqg4mrQm7EW55HSHGVVejq6avJnjH3MHnR5KmaazDCwE0JmnIwlwSxFdVWqtNdE7EFCRmR3uj5i93i9wUth8R/q6KmL
# DATA MpNmC9wLUJU4j5CTBwmrZscHY5qy0U/RCHLourIujc09mewtxuYlFCl23GRnxZ/Vip+vcs7P7PzM5zbgV04XLs/PbHji8zwOg1W7
# DATA lpivq+Av65Vf+uH+04ns2+FVcDJlwniWal/rCTzjLBjT71mXDMC3dRKA2d8YaGyM/g+4G0TE8gBjfUPGWDbThHmusFplx2/Kcb+a
# DATA QazW4WWaxx9X34tSZ7ON/fZrGMWLKeO1dJM6fGPEhDLMt9+KXj8RMW0Fk88DfdHEs3ZSsdRPwZnmVX8F/aOoygXsCaH2SpmwPtLm
# DATA cQs7ra9kvOmTolvdNLa8kSPrwEbUMVDfMRdH7M6xUePTXp4zLt9N7O56KVlMepnGjuoGTOr7GpXMHUQS8pqF9kw/v4Bqs1YgHfAw
# DATA mI1pPoQFgXSaZ1Sb9PcAp2Gzi9cILMoQevYEZGYgpKWXKXl3cXk/InvHXiRjSyh82lWrGZ6sR6ijDn1FzcQGj0AANocpNqzxrINn
# DATA bGJE8VqFMpSSIFL0JrCkg4n01HPlmTlQVO+YbSLJZazlHjFInkUuclbskkdzOKYlHCZeYZsHMTHTqheHgo9SMz8PnKgDVDLKDEaG
# DATA dqcK72NGoZM52S/arMkCZs/SqAsvTxRbyOyj/3b81dEfj/8RVOujPx//9uj7o6+Pf+eBnU0//MvRt8e/W6Rn/5ejH47+Qvf9/dH3
# DATA x7+ju4/+SA//K9375fFvCx59+oGe/MPRD8e/AUUbQQtJ+0v6+9ujb5mj/QU98s90C0jaf/LoLvC6f0vBfkvBfo2nj35P0foTP0lB
# DATA /J7+/h5Y7uMvHF37+k8IqROLR2ERZDlBZGnuFPdVXWqmAOENeRmYV8sfqBEi0DZtQZBg7JwiM24yDBUvTNGuqPdLNNSe2WCZ0bqW
# DATA ov0QD1EfFDp0dm6+l3UPVw3Ptkrk8ojZqlal1kyPL3DFTOfv7oRB1l2/Tl+4MnZCGusvEpVN4TK7OtIjmdpasTCpe0lZ2RsU2oWT
# DATA su8NYujUB4CY05g61vYrZTC7nRRRknsTKreFPeDi8yWLhTqp/XB4G3Ed8DYpsu9S20sVpNIb6s0pp6l/qy2YrDU9K/b1iZF32Gs3
# DATA rJ9zWNd469ON5i+H5/YKR/KLHMg3GsdPNYxfySguNdEkPdvt+0ybymUAqk0aZXvoquRx5608PlzOBdlJSWnYY6mMYDqQNPSxEXIg
# DATA S7ay+kzT80DItMngcDoYZQVm7YUMdG4oZDGG4k2I1O/HnomugHc1c5ljM449aTXL4bwl7y7/yALdqZCJWdFZlrBUr4qA0mk8IWtr
# DATA oCi406CDDJMDdmI9ZKkygGzKr26Uij6FztIunBGOL+340o4vfYl86Y2GlI3mKxsavldju5/FdL8Ay92BpB1I2oGkHUjagaQdSNqB
# DATA pB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUj62oCka5VqUK+fESTdr/bL/fpzBJI2
# DATA K84b0aPt/ICLtV4fNMqV/Wq1/DZ9/9V8Pob19hK8VcvzW7VBvdbYbwFv1co/1vV7zZ4//9jIr9W9Cj1aLRf9plep0gev2irWal6V
# DATA /k+/NYstr1b1AM/yi9UWX6vg9rpXbXtVH3fjctlre7VWseLbb+WdkHm2VbVXDxrlZWyrJXWjjvg09/3KPKCt0+j4ne6yUGoLMD6b
# DATA klbNI4MlXAvg1ciqbzVPMg+DerOzEMNKpXH+GFb8ahbDevWCY9huX0AMW40shs3Gxcaw2qycP4ZVbhKXVMo1aiTnjmGtWrm8Uq77
# DATA rfPHsF6uX14p19v+BcSw2brgUj4NSE8GIQ3Sk/HMAum1a3W/2s6D9OaxeXwlmAfp9XvtsJ6B9BpBPWy2DEiv2+z0aI5uQHptso6r
# DATA rUsH6fH2z+I6675UnePTfW49tMiiy7mE/FZ+1qMzgW0suGwp77HpcbtY6YV7O7mQ5wh9b4U0rkdBQeI+7/yusutblrwZzje/fq9C
# DATA 5snapmtqJW2+sz+3aiUdwXh641HOcjeOBRwx0L5wbAwrnnIJqLbMAc1+OCs85QVbxPOp2pQvDRSG5ZVoYnll+XaohVeUEGuyWa1Z
# DATA PpmoujHYJUxWcb3bXg3dy0q4YJfJmlnEYm1TybWqkXJ2ry8cngqg1q+cRmUFdbr5qIMAOgiggwA6CKCDADoIoIMAOgiggwA6CKCD
# DATA ADoI4EsGAURdUBPFXbZOCwEOfRYg4ZsUWIatfFvyg0+H7UptiXr/6y5+LKK23OZARDxiVw1v6ivF7ZflQqVQKzSoj4z68z2kum1n
# DATA Rz9u7r7NrzMVcXtciMB/G+tub1c9YfV6O7fHa3MJADk9YmXxU++RUfLp7p2n+g3Sk9EVZec+Vd0Z/Qd6nT3HmODo2PbOZ7mcvM2H
# DATA gLWtyBm6M5eq8e4dShAfv4QxyvN2ND8+B4cklOTkp8L8UdDcKykI3g6bc/lp6Idb6rwfOoqsVu7SqMsSsnLKmOqjMPAeyqFjJGFC
# DATA HSxj7kzCpmzxArn3I/X2HbH8l5fNCSmZxnt7w1xKChG1c9QiSRIH+kt8/8gUgQIqxrtcK7Xtn3ah84jk7hT2cj+9RZMIqtgxDVkh
# DATA Zcy4eyiFxq+ht5Vf81vlW9Vq+fZeaY/uhbH4C9xwl436bZxaKKgAZRs6Lu/ou8Onk3gMwbZg+DAYTR7H+WfL/uKzN0rlBiJECRlT
# DATA EW3vITD9Re6Gkl405pVN3MkeqG35FE+2l4XYpGKSAnwgmcmCiYA7buPDDZ+ZjXHfa3GRcuL1Lz9p3ea6uGtNZFDShWoZK3ACgIQb
# DATA Jea69rmak7AyvkYw6urwWVb3b6uq8bluAzwFnmK7ERfh3Xu7B9GYJlYlPlXO9fLp9Ne/VhcPws6TaGr/JL3FvZ3pgMZp736ScO2W
# DATA I+nWOI30cRZJPfj1rzEfvHuPIhQcBBHN/jj70E+PME4uqcynbEXxxGpE0j9KQ7n9Oc/27TyRMpI4582LxePrInokCjyQPpRT3J3Q
# DATA C2maptsm9TtmKrukq+PzcdGQpnW5Tg9FZh6TIW/HiiUFqkphSZBY46dHTFDWc5y1r0mrl2DEp2YO1TotG6dls0zLJn/Q2onaOFGb
# DATA TUVtVgqQX5bYzX2su/DoCrWJcWjLtmjhm2cnoHYVKuNiCtDlx/jgbaM40pujaDybhifpWOtnTedkLhjJZaUaPi8JLXtDlCZ0ZZ2E
# DATA tT7mS9Hm47pQjD9El8X5HbNwBpUOL6ANZKWJi5MCkPvzGWPWk6ycMD+yWcpL1pI3PAUq8535jNAenCwrzK1Z0vlBf07dev27/M3f
# DATA 5eezGQ9WTvWuyubvquTexQ9WT/Wu6ubvqubexQ/WTvWu2ubvqi1Ird+pn+pd9c3fVc+9ix9snOpdjc3f1ci9ix9snupdzc3f1VzQ
# DATA f7/TMu/S+iqmDa9UV7enry+AmLoeKgTpopWIrNGG+r4nglbC0RmaykkHJiMkZg/AJvMkfQSppSTX5UkIfsGrFrw6D0dNULTCMQup
# DATA ethBwEELUHhkSGBWxGigWu4/9dC/MszAkv0y3vZMVYqGKcwbtCIYBkGEKVbj6fXANpAyf/7FhBy01U2d1k+d3EzpxZwpnRbE+sxl
# DATA QXlzV7bP6zIQnpb85gVzO23x0qWwzpU4WdYQ5JOHpqUKFwUy42uwstdAHPU5EQvcUN7cy3YOauNKvJZ6viwndih3aDINFU2oJBlD
# DATA 665SaA0SFrmCY5SMITxNZhXZV8w/5bUXEWudyDSet3ZBhxHzdN7VVMADqqAy5Uae0FMhRUN6xz52IgoVaA9sMpafpJczIwe6fFoM
# DATA /fS5CLOPNSPntGOvUjL92VhKuWrpjCVnLC0zlnJdlXMzv/Ru5pVG1rPXVNc1n6pzwLLSh/AAjOk+3oyUaaxPEjRNyADPNbK9Gc2P
# DATA 2dWchEoDe0Hem5qLUQC3lMFjNcXnOjTnWM5ZDYsi6uY+Gld1M+YRiUrX6Ctj2Iz7fS/Yj6Mer36O4yhll3iiNbWlO8jA41nCtKJb
# DATA yXtEQ7TXp9BERD3ldVI5SozBdyhxSXn/IgI5NFrg1LPMOik1+tlUDDeWkQPzu6eJcIhxyXtP6Wx7o6ibxJMBO2AUPi4MuuyWx/OU
# DATA A9CtRve13BOfuXsCtjXGSg1eZ8qjcCpmRJpJPw9jbGSZguYrG/AmAUMNrW5PA/RK3l1kJgUdTSYKvI0g2CV328PCNq4yejuQu+wy
# DATA 93BGAn3xGLmj0e+Sbk6Vd0Bv45XxNcl7P4BdI9zivdiozuMqm1tUEjCLpYA1dp5KXSr5NB7FSRIfKH1vqf68Sq6Lhqu+J5k4xr7O
# DATA eNaFBgxj0MV3lR3izdImDHcDTaeiwsCnKMvr0vMmy/OzZwwLPAuAnCFZdDwFCWEtigWqFOFjDFJTHsIGZDLYhiW1SUwa2NRLxTSk
# DATA 2/s4oY6mYMZBqQ7AIQomAC96EjJ8HjWPsnEkhcTkabIs91CVhyDRU2RmYwzMWFOKJ+l8IsWeOokU9LrUc165QnwkRyUXZvMeYUSb
# DATA B5vcRlqr1y1qxzGGuZVe5XVO5PxCiSmFNZmX+ZX5led8rS+vpV+kWZnGd7Gv4eUSaTQZC0uYBdyILvZtvGDykEvWVNYpOh2rE0ZL
# DATA udi38tIJ9n2vbpj5F96cDc/pi39xZz8Z4pLe1ovjJLX5lv909MPx3wJIefyPzJ38kgmXXxz/7uh/gCh59O3RN4uAy39igiXwlF94
# DATA R9/hH4ZZfnf07fHfeoy+/OL47+nPV0K4VAHTixhr+T0F/s3RXzS9ksGYdNt3oFx+c/wP9NufHMLy+s/bHslMK4lhJLEpjEWjeLY3
# DATA mDIjR2Sm1fA6jKZQ15BTxGYiNhtr24VMKYx6AcNbZcBnCyaVmRswKDALAz6DupZf+Yh3XFBfGA29T8hiZCPKkSyzOZzuBa4aY7m0
# DATA YC4PaMn1MrXmj7qaCvIofzMqq7n1gaq5GN4ukmZJxioLKag1TNlrQk1i4kiWG5TWhYMs76qtVUNqHofFg2D4JCM1kVkN3g7wPypZ
# DATA sHW7AY4b0SibQJ5N4XWCHkYIA40ahyEZ+ViAp3p5yHMDRUHC+fnJAsnyhJq32ixZ1pyeFdHyhEQ4nqUb488zxmuY5VmH9pfCNXtl
# DATA w/rljOobDeqnGdOvYEiXerkkB8yA/gzbz2UQLpck1aN5KH1i9lyglkkluYhlgdc5A2R71MU4ixRzcpdFmTc+q4eTWECB0jd1sG7O
# DATA 8Q04buMcam8TuGXO0Y0oqWQY7U92d2Orn3dAc2ysAYvyQSpUQO/naWZCychPlht2efcpZhEMAUETRmNeWzK0S1g7kbxAeYZRaLyQ
# DATA dddCQyrfai+kMXIUkdlwMAg5FoHHpglvsOuHjnbpaJeOdnmJtMtNhpiNpjQb2cRXbd6fxbo/t3HvkJcOeemQlw556ZCXDnnpkJcO
# DATA eemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw55eW2Ql5VaLag3zoq8bIXtTv85Ql4uWXk+
# DATA LfyyVvFqjYZH+eb51fLQL9c9v1l+t9Zsec3WsNKqeNXWHNeS7u0s4jBHfrvqVSij636xRX+3vXajWKsXfb9YofDrv3qv5lPYrfqw
# DATA US365abXanp+pVms0y21YpVe3y5W6sVqc65M6mGz01vkA1Yp2s1P/Xq5WC97lZbvlae1assr7zdbb9eq+TAa3VavWVkMo1Xz6rXy
# DATA p8VKuVlsUaQqtaJPeUExqiOmxVbzBLKmidwCR89vyeu6UYLZUpeLv8GR8LpctL7U3ERAhbn49uqtWq12Bloe119Ny5OmYNHyOo16
# DATA WPU3oOU1emGOlhc2e/V2J6Pl1fsN2NaGllft1FqVjJbXatZ8P7x0Wh5X++J6w4C9+3O+aSoqnL383ApA2wY5dpokehHnpvJ10f+H
# DATA P9TCb5+0hrDc2FkFf7NieTKFz4bsyYOng+zVFiF7WTCngOxpB+TKPLJzWmWowtip+md7jCpsp7ExYAaxFdsI9NitFrjKq9l3Wb4W
# DATA 7KxaY06ckBOGaOfgcw4+5+BzDj7n4HMOPufgcw4+5+BzDj7n4HMOPvcSwec4bTiNUNQ2D6XxtXUDGiOIJIdYbmhpf+oZ+hh6g+Hu
# DATA ne3hAt9JpXhHd2SvUTBPP5JpzS89fNi5McxXMq75O6VP4mhMAXxI/4EPdduYlx9u6WPnWVxK06fI1w+33lg4ka4CuIHPmhR1z+xQ
# DATA 0KFq8JNmKzmFcHewes3Baneg+iU5UH1avfBne9Ca/ZKZK20RRzTMaWHuxXEPZ4s99hOaY7ZMkkAga3S2n/X57OfhjCL/fcFa7csO
# DATA kl+0avvyc/lL9ds3OCaf+WmNfngoAnUobS07qSqH0Zh5HFIU0ngUQgiGj9ZKVeMT8Mr9xkQW0Q3Mny/PTo4XIINMtmbW2HnOCD1T
# DATA eIDjfh+OaX2gWXQPEbhUNX7F/OHz04iIL1QTOZAbZNbJsxGreRanWc3zzqByBtUSNbqsQjnBGidYc1Y7aqW9djlCNtyn62ZAlpRo
# DATA V7AGxiCexntJMBlYouLPTDftAgCWNC6/oWRorNHrlJrFYgwgkAsULFZjvx7MR8GEM8ca85cp316IavEHLO8tfSPVRiikoOe7BOHi
# DATA N2Gr84vGXviU8tFLxxcuH8yixe+M09kwmIp6+aFK3gESOqFOvO9RfzccXoZs8Yw1laaaOzNjDfC51nCx762L8jQkvnueiNDrcY6G
# DATA v4t9F9MfH4RJylJMWKlivr3IwjDbqBhEZMDPJtQgwwtWo25mneicBU3FGYAHKwwQMbgvWCJ6jjWZTcskyLxjkh7SWkHe6NCYH9Lb
# DATA GBxlBoC0FdXNclCmKI/JgV1/VBM6zNSnZECTE0fpCmmpLgCLWlfK0qWCKhCLS3mPIPAdjj0Gr4y7VFBafqqvqAeU9wWjkBWr3llL
# DATA mmLh6VBrJfGMKJl1OhDJ53JhJjGqSTxkfLGMA6JxlMwg5OXpTDM6Xsq9GcoLzGJ3oHRTN0M9vjjTD8ugcBMQNwFZmIDkLUw3BXFT
# DATA kPwUZOXE4llraSpeBzMtBsGEYcMBZhi2OHYaKt09LQU5JxbJqB2tDqnQR6FMZiydx6ktAImxcngAftJMcCHzEo/SYmfUlKnvolLY
# DATA D5coPW6qtsmpndx5k5c2s3h3DrPZEXOXO7No2DNafCoy7GhcdBurw6MWgF6jt2W1n4FV+KQsLGUB6R8zeLa5wioCA2bFcM8mi7Oy
# DATA e4WGbispeQi4eq/ZQgCrVH1+VTZGqJdbd5ie1X7q1Zh72Mzwwxo8xlhqNuo+ti1j5cidv50mqOoww1v8afWd3WE06nBE8WH1fdQx
# DATA x9iURXfel4/ZvTclbXfmMOXa1pTVeNvUxIiyxtDMlS42A0uzV2ekM8s5SHpmesqbH2SiqvIxnw9zYC7eSW26A9lZIBPbGd9e856M
# DATA TDLm420yFcqR1TsPI2Y19UKGCVFrrYqXYBSn0+Ghgl/iJ1iJRoqd12qE1xWNpzIEhiKHiV2S6SBWeqKBQM+1eCwDxcdGapZaLk+L
# DATA tXtbSWF6sMyUdagOal1tBjZOkYEf0Jx4yL77KOnSdDHLQsxRqWMAisvu6NQsB54S6hY+UVt0qCe7x6sEbBvz3kqY7aO4g0eo9wul
# DATA TlNRPEll0UxRwLgsLiK7rFZyyvxqr80v0+Qkw34GyU9qF3uhySp4E/iefB4ZBJdkZMn7gMbMgscqeREZYYfK/6QgYtSdCyVOdquI
# DATA O0xz5mnYYIxb2LuIrDIdzykzqrk2o1QvJtn0Nvw4Ys5HY6tW8aupQhxQLFN2xATJUK2eat8MnAjYBhdAq1ZWuniajZ/h/ds7zPyF
# DATA IZYAsSdfyLkAjnGfx+0QkrqMruCbnmmbrJ+iTb4LEB36NGp3RUp0USBXprbZl6m5CbVOZaS18hYG6SEW9zQRjh4hm1+khzk/xRZJ
# DATA gfGyZuTPsoL5lc1r2LsxFTGNkcPwkN0EWR0b0i+ZhaO8u+Lwo9ktNUH2xGXGGjKEenh2WOlFVLUoKtYW1IFxIidWdZSsFXFBgUaY
# DATA RN2l+ZYfiGVvnT0QmyuSDXfej/UuOK08zSaY2p0Gp4gqSUWJ1vldOokh9qI4IDKW2CScAs1ro8T+u4DEvKM/Hn3tMdYL9K+/HP+n
# DATA o6+P/nL07SJG7P85+ubou+LRnwEAO/4NAGT/ClzY8Zd0/V+Ovqe/f09//3D0h6MfvOOvJHQE/S2gY18f/fn4t0ffHX9F//4ObwKL
# DATA jN5MYXxNIXytwWR/Ofra0cSeAwr0WFZ+sI+nq1TqMwr0JIwnzG9kwDoP7dT2xEDsxVA+Z28jBhrLJa3EcPku9NGZsDq/gXqQSCTk
# DATA 2Xm8lir2FswlZrePDx1OzPahqI7gqmli+QK5XIxYNLbWcO/rWqp/WWSJjac4BGj6WHyVkS5MLpInFkwFUTAIUhpOYcGSpRv3+w4n
# DATA tmmpXThT7F4w7GLVMZQFsMMMUB2MeKc9L4EMeZ3E62Mq4TEXjuX+zCoHSLqjUciTX4wlvI4Y/Spk+obXi8LpEozYiZVutXWSa0vP
# DATA jiF2YgocR8yN7hcxumue2KkH9ZdiUeSqBvQLHs83Xgw51Wh+RYO51Eg7D7LtVs++6VwGSsxOqziG1Q6OQUzPYfEhn1CkwMRSFxYW
# DATA idYk/R0w2IeTVKhKnLRpkD5Re1UQgWiMk2M4xqeyZDOUGABGMlTvg9elYE29jOwk1UaG9a62CQCfirHRDjYB1rYiMhCW2AUz6C5E
# DATA 02X2gLIGGHwEOwCrV+kTCszEI4JznGsT1a8hdmljD9lsmkRSZvG4Gybj1HHEHEfMccQumSO20Uiz4QmMDY3jKzPyz+Z7vAAT39HE
# DATA HE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTez60MS69coi
# DATA 6WpTmli/XwtbzxFNzF52Pi1GzK9XvWq7+WmxWi76lD/NatGvN4bFGrBa/qe+Xy3WPb9W8fxyxWtWik0Pd+EOvwUMWD7rev12u9lf
# DATA IIwB8FUrt70KvaPW9GrtYpsuVLxWA0HWvTowXp6PsNt4XbWdD7beaPVa/SVgrmrZAnNV2nUD5vLL+frQqTVr4ZIA6jUrgKpF9mot
# DATA VonaMjJYpXna5618qVabXpXyoVL3WkX6y/dHlZpPeeQhc8ucxasTYpci3Vmr1wf1ZmuOdGYeWCCdNc7AKeOWYThl3MgsThnVo2Yz
# DATA 2IBTFvSrOU5Zv9JrdhsWp6zd6DczTlmv1a11ahmnrNJqVBvNS+eUTcLpiZQyjC/6vg0wX5ajrMpuslKLl8cwpO0sksBMyBpzlpvp
# DATA 1uo/8er0p1Jnp2MOzSU5KiGoCG/mVFOpMo61ipnuzr29UmNfILvx5mwb8TytQXjpdBVy8VszhOdu0y4wh+xyyC6H7HLILofscsgu
# DATA h+xyyC6H7HLILofscsiulwzZpSwOi8PVCw7T3feC6aDUH8Y0sYHZ9+EWDmNR6n8Kk+amusbno3BRvtI0C4YqtRq2Pj/cujuhCd5T
# DATA uCjD4SHlxg0EfYNypT8TuTA+Hta3dK7UWSteRQIpC0gtfZgrUIezoEGGIOXYTcCHtHFAxZzBEr0/R9lyx45Pe+zYHTd+UY8bnwWv
# DATA dQ2OIbP7Tvu71lO2RMDKxHvpUeUlfK3rcnj5uTrDdxnArfxx6wsmbc1VhrMitixHanaIXOV0hgWBPKMIyCvVFc6uQfXOmzzBZ105
# DATA rUPH1QdCoWOlNycHYU31OQjoiU58gNPO4d5sCPk+LTs3gpxo3Icafm+WcAUNkpGWvldn4vndOgJ3ybaOyPjlbbM6CpoSRtnTxyJp
# DATA h7U4p/ATebw5RSwTLLUOOW3Qs+O2gBOVnRAv7pFNNks6RnjyJTnqaYXh7CpnV60Ra7Mrl9N1cboupzWo1uC2Lkfv5W/G8QG6f1Ec
# DATA 6AR7orEGyQ01sPlXLyd2AXQtXoFQO0D0tZw2PE/06erPx9BbCJUMi3GLedtP9nbmSEBjXgfKQDsqCNNN6e85HBIlmrpk6MmMIpa3
# DATA LZfQZ1PPIltyxDjCXs7sxxVy9uKHANDHFmyZYIsrDfbbJ8ZXP5/1q/pCBuFqlZfF2Y4xtuvYUV4TYfaUMKUJ7upMxwYZdUJc1aMm
# DATA qvp7Dhe2Np7+mljOEZTU+hJaq3K6iBo5V3WLkoRKdedV2Wuq4qnWGG0t3+yS9C7RvqSAxl/FbL0pQZyPAmUxm6z2bQsfKX16hXgJ
# DATA 0OyNPuB9uJ7sBswNmrVSwqeRqLjwcIceR7ugPp1RLwSt8nS2txeyBxrACF6ZUB1EnABjAagSq0pjFOZAxwBUDDWNSxho7BtX7Q4C
# DATA KmTKz9gfT0UDPRgoBAd7hhELBSoYp6mM5L2oz9IpU9EfYmVnT23lDU18RI4e0kQcjSXqRJkkEcsqw9OIyHjBhOocBrhN2U4viLGb
# DATA G8GcuevM3ZXm7oJp4yxeZ/GuNmGvicLhPVbfg2ZxH4NMNGYZs+V8J82XzaQAk3AUMaKjsEp1701hCi4MNyxstjeLesAZZgMjhUbt
# DATA tTcDgJCHt3kTOA9NWBA4NPfRuG6Yptr3xEP9z5kTgPEsiWnoCKZ6zGU7fEQNfAYTStkBwV4Sanzl4pCp9A8ppB4N1SY5cFUtDJws
# DATA DQhxGfYchawJ5wVTVGiK8G2b2q7JkOFT3h6Fd0SAGlCur5gRiMRbvM/7mxSDU/NzJ5rhhY2cAgp5GibdCPsdcxBUyXAuGBbts4QK
# DATA lZes5L0FzhZ3o+xNY2jXADYX38UAExAr4a57N5xyP8vJgGkTTOf8bTi4ZiLr8eEGsE/WpfGulqM0/b1O5AeYtWn2jur7oTJZEM09
# DATA DSbCI1h/pIIepgWmY6SG2qmNLjGT3kdg6CkPYYKpjZY8siQ8JHVgaYe9qBtICSp8JrJyoaZbmLPwKY15w8N1qXyfjxQb84vxJTqd
# DATA d3mnpzokMksK8CSzwvhIFz9PHxUpJwL8RJmvYyjxKfFPi5HGScorVZa8R2H4hCkhcMsyzwN5ybeqaqEVK3N8GfafCjcEaotwEGtH
# DATA cZDypDbYG8dplC6QOdgQO0nn+3FMHRPnZ9YFcas5NSmafdp6DLoQTrTl5laNAe5tdmJfAhn6PVRfvQ+GmmuAqiv673qacgmU6Hs5
# DATA ZznaLJW30GUvgRT9bjTlWVlC3RaEIAUKqZg13HOKwOQlwKIfDOWd6CA5tVnj4mlW7xJA0XepA9ItHr1Uz+jrcpHCW5T0Lpid/KLP
# DATA 3ywuDj01TW0szn8FBOfo+6Ovj39z9P3xPx594x1/AUQNff2GLn97/LtFMs4/Mermnxlqk7/76E9MyfHopy+Pfn/0zfE/qFD+M7g4
# DATA dO2H47/FE/Sq39Evf6EX/sk7/rscaceC6Tg0znNAFmYwm9GuFUYWPL9AehRkG6pwgfvcbR0Ayn2gLKq9kBWDn8DhLDjhqWYlMmSU
# DATA B1EwBPeG6wk474ZBn9/i8De5OSa396um31iFcXnoG0la1i1y3enzPGz+Vowc5kae6iWDw+lgdJG4G95kS9OeAWp8j2cEQO7xVkzc
# DATA 7rA3J5bYhfNuMMmNO5hjcj3THmvsFFHTYe5fhkEyUktT2eQzSsUVvbCHWvTT2baVuQSVFvVimNaR6QIH9wL+Zn39W218ZO3oWWFv
# DATA 1sfcEW/coH2KQVuDbU43Vr8cvuCrGacvcpjeaJTefJC+/DFaqp9JtBmQr64tXAapxqRHCMnpfEL0/otsEwPbE4N4pGEwVpnITJcG
# DATA NAx2QY8TyhR0Q6RIFWO5G88SYVNk46tOuBxlp5cgrzj4zbg1aoqfG4MD41zXo7cZt1O6sTcbhnpLJC9hwavopZOwG4VpwcQ/Yxcr
# DATA R+swEtdrSJ1t0A+nhzlXoEoH43QZE80o4K4kKp8gB6hxgBoHqLl4QM3JA8dGc45N7Nersb/PYn6f1/p2MBoHo3EwGgejcTAaB6Nx
# DATA MBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejuT4wmmotrPbOCqPx+/XnCkZjlptP
# DATA S6KpVlpetVYeMH6mUvP8WvXtar2Sz45uv1WuL/JPapSAaq35C79Sneef1OrdWmsZ/4RLKR9Mtd32KrXKv/fbFa9SKdOfptf2P/Xr
# DATA La/l+c2K59d9elfVq7Srn1b8RtGvUhmCmFMr+g26pUjf6KYa3eTTA7V/X2nToxWvSiFUW5/68CLXvBrdU23k0lULW+1GeREQIxEq
# DATA kglf9P3WyK9RvuBFjTLwPHNp7bZ77aC7LK0KPUOlGJH5odg1tXI9Y9fU2mWrAtfky+GS2tzrho1u/wzsGK7Ihh3DbcJix9QqzaBe
# DATA PZEd0+n3+o0cO4bi0+p2LHZMtdHmgIQdQ51EOwgtdky93qnWLp0dM6RWcCI8Bk6jz7NbDeXF4rio1C069ti5V6F/Wz+xze0mmw9Z
# DATA kCcjaWzeDG+2k73Fy2JhXFelJeunZGF5WKr0GvInF5qnLBoDlOFR1PT+OXKNFPFciilMWEZeXf4Y16gkuwXjyvbn+NYajwqiSRnm
# DATA 0x/1r7Yw2XrlAXElrWaDssxnXX6OvTQjVgbkoDYOauOgNg5q46A2DmrjoDYOauOgNg5q46A2DmrzkkFttEGopX22dl5bN5ox/Eb3
# DATA +nzqQj1WQB+4tGv1VMqsSrV7J9K91y6bxDu30c4/3LqXqXnhsIol5zKmHFaaLpi+5pk15uSDOzfszg1bJ1/c6WF3evik08MrtSYv
# DATA 5VTx66i5UJrLAjcni5+p/sQF6KVDaw5vPgjDJ3zCUdrsGbXmsrHl4tTmwnCoVLk7skpCGaLVB5Wj+xJk5/R5YwVum1Cp9hJoz3k0
# DATA RwqHh5egOffOGIeap9LDpkopG/ZyPxOovgTxucfs+lJpJBNE9eZUJ2jsKEL9uncJunMP5SgxfIBkyqkkG7jApZQra8+9j7PWgRGg
# DATA Q8uTEQ4mC5mX2As1S8ILVp9THhgjHZ9pMuaUAbLDrToh5tQsZRi6gGmuB7Ek6jNReJGAh4Tq3GF97o1KmbpmLznUGZ2hGoLhAbiF
# DATA o5Al5HELFqrI0BgOS967Ud80hwJwD8PFtqhUVMeISuIN6MckxILV8FCe5O7lIEglOpoopNRquQ6KyjsaG7y5ol1Nkwosse+rAKh1
# DATA UDSlvgzgG0zUiXjoZNKjfRpSVkkG6FzRx/2pmxzj5DtvM6DxhKUAaKSel/iZG6kehjgOqE5xy6RV7pBx52TZ+Of85LFDTjr7PbPf
# DATA ncX+wlnsp0VKPkMdIF7MNwvR6zmSb0Ysf67gKBA9H3u8l3cNRPKK5YOuvZzGZfAhM5Gji4ZD2nJQZyVDWpsU9LTpIY5VmeogEz8W
# DATA TlHCU5W5gsSuBilFtbsRxMbXE3kYNABsodPQxrvecDaKxvGMpojGJhpTJY8hYjMJh0NIu2MMHSjFdbK/xiXvZx2R2yfDBJuuoaU0
# DATA IJNUYQ6YZ6PfbkfjLRhofBcnRsfifdhFFATFjiov1RrL7GKTj8+PhLwN4TCFlnqQsoS6tBCt8TyChHWy7v3shvZy735LWlBK5mXK
# DATA S9El7704nWr7T8SFmP2jY30bGSTtC+wlKN9Qfw3bAML21I1QVWfZkPmYvOgiMVbP4Gw1Z6vZI4Nztr68ztbVzMlnKeH4Hi9W6vqs
# DATA BNj46LUFpYS0HsMR9qHdJu0nc94U2I3AgEl2omnHYcl7kIkB4hSOqLQZtA+XITsNAks/kH2a7DvoR10vpel+13hWOryVLNMMFM3F
# DATA DTUgOcXi+Mgav6z1ISbjIEk0T4gPl+A98PosMRLVGcdF2qVa50Yl5U/KT6Y8WfrHDIhornCOAzsScjjytHI/xcOhlYKlBEizeM7V
# DATA RD6/KlsC1MutO0xHaT/1aswdZua+w+ozRszhUC+NRvCHxsqam7+d7AZuVfHB6nv22OxhZBZ/Wn1nh+001shOxErRd96UVGX5IOOx
# DATA 9hbKCrTt58PQsMZVuNZmtDyfQdIzTnhe8Bd3vMpBKwfmQFK8M9i0fllK5yqUzDgn7poEzMdY8nLCBts9iDhGCYRMUe8zsxX2WlFp
# DATA chZEYrSImZnWIKVhbBT3QvbjT2HPwvDTFpyglGxnIhyQRqozZKEhbWRPvV/RgFuy/asb+lI9s02OLY18UkzWaAkzAF6x3M2NiJ6x
# DATA nK7ztuypiierfKcsoUerS0hXYymkRxP2weZLiJoxdyTicQf2BVqZA7J/xA0aeFLXldVvsQPNGgiel1UQkVqNoT6KKQdKFzsYlZVy
# DATA /rKxU3D9C+bBpgXzIEiGLCobDEe6YB7FfYaxjmlUY83UA0zyaATdy8/NSt7d/TjCzJjy3rj1C7brm0tlQv0LJmc9NUvE9PDc5WFH
# DATA /MrKI+t7T1ke/251eeheXMrj35HBstCRzbrd2ZDVZLEIqE4SqsahJ6uKpUe9FK8k4Dw2DRkl721qXYcFKkIyQ+JoKCrHI+7F4tFI
# DATA 5J/JuBgJS4x+ipCDZr34/AWVpej6F9PDTYvp4azTme/PXmcRa9WbheNP4sOsB9NiXCXvg4imu70ZdfR7shRl5JP1qlBm4YGpTXnV
# DATA DWZCxzt3WdjRvv6d2JubdmKvR0mPdwyM4QCixjG2Gs9AFK8Hs1HUK2KhkCXGVXnwqJOyYQ9poSks8w8CzaXO1vlt3h5K2PR2FBIZ
# DATA T2rbBLSQ4R46dzktJuhMpZW3/2Qbo23/mSuS93fej/WGQ63BLSa/WNy89M9Qy4BmLMgOXcpq4fRymGjPtccrY6GlgzjModD+r6N/
# DATA Pv7q6PfHvwWrDBgz+vzl0TdH/3L0Pf39e8aj/clj2Nm3R38+/u0iGO2/Mkbt66M/07N/8OgvDvDo2wKFePRH+sboM/rfD0ffmJfY
# DATA JDW66S9H3+CT4qj9C6hoeL+894ejfz3+R0dFew6g3GabA295jacHGrtqyNwQLxbyaoFnRrzNKoSJp1kAgIbCncAyMtQBCJwBHegE
# DATA dANFdKV6nEx5zxie68sSlnEKwNOxlpwGZXk0BbHzHT7N9vVxF3HV9LT5Ark8hBqNFsEw3ssQX7zDkF8+z+G+2Y+ybvrNaGrhOy6O
# DATA oQZTWp3bQA2NZQTnbHD4tJNL68L5ae8JBtzrkHGBHV007x/QuGOmlwVtZKUxDkMhI2HIIpno7tSeVsxvFGn8KVRSwqxzYp2vAtlU
# DATA shyZhOxZZMKsPiYwoiISvAYGq+kCW219vVxtxMy1smcFWFsffQdYc+P/BY//GsJ2hmH/pVjeu5oh/8JH/I0G/FOM95c/3EtFzCfd
# DATA jPLXq/lcBrctn3AeJDlDDHTMpLpziJAKcoYxmcmrJK5TATqlowALX2bpzZN+qROmcGmFCZYmOdE0UGfHFlT0elHfsN0o2YeeIpls
# DATA yGxLlLnG22pwZIUMCvZLhN0nGJsUmozrmHCv+NQw7wQS2lyU8h6qdCo0Ll6aDdOpmArIl8xyuK0oZqBnTWcUwigYz/r4nNhGgvK8
# DATA wk/ANk1yWIzHDtnmkG0O2XaJyLYNRpeNJjqbmMRXaNefxaw/r1XvwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObA
# DATA bQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7cdm3AbX692q2Wzwpuq/cbYf85Arfl15xPS28jW9Wr1lqfNurFasNrVYt+
# DATA tTKkfyoVr1X3/DL9UvX8Cn1qFCvVYaPt1Rteu+xVmp9Wa3TVq9a9WuVt329/WmwVq02v4hfrc1katvuVXmcOeuY3a41qbRn0rL1Y
# DATA cpWyVyvXB/VmZb/aeJu+5l9gwspT2CqUgkqj7jX9ot8aFWtNr9bymuWi36QvNa/W8Bot+rJxxPzqQszqPiBxzU+LVSrUIvKi8R4F
# DATA gNgOq3QhR4vjnZz5l4X9ZmMF5k5V4G6U8Am7p1LpKxn6zW8ySI5VDRr5FmCCpQBg2HjydBlZ68nDrVa+2vf7/F33vyyHyuKv1RbV
# DATA GwrjlNg4bkYaGyct0sLGhfVWrV7PY+PoplqlkcPGzYHkBBvX7rUzbFyt26jXmxk2rtftdvoZNq7dq7bL4aVj49D+TsbGVbVRICaB
# DATA fmYFPw7JnPMv1n/i1ehPlf406j+xg5jjxb0zoqnEtICtwIiv9z4rdtBXO+b2NKleLt+ed+aJu6fQ2j8o8CrZihUxFQ3AqyafbbpU
# DATA UKpZeeFVk3wwnt5PkTNIzHwJu6q1i097OfNMO5VJFfrj17XJz76iaEoWVjcHstM+bOqXKwv4ufJqvpzJ/YKdA2tMkRMSyFaC48g5
# DATA jpzjyDmOnOPIOY6c48g5jpzjyDmOnOPIOY7cS8aRUxZHvgOIxhT+Luy9D7ekzVHCb8h3KMJwNrCJ+eHW4yCBCi0/4snNaF43+AJV
# DATA izexmW7b37lBudEdlT6k/8Z3rVPi93+eP4bHD78XTAclnqFvczg/9Ut1hJAd71tyaDxTvoUUl+n2NWouO7biDlG7Q9SbHKK2jza5
# DATA s9TuLPUaveRne8ZajgYX9FnfJSetH5pzgVJHCnllNXOoVw6sKkEWPksMO/pA6TDLSd6QVfazw5OT4BCTaTk8Ca2VsXVycmMN5DdF
# DATA 9bgjjKgeCFR4dWA6dHQETvd4E93jbpDOAiWbhk+r70SXSlmLWz+Qj6vvpQ62F8ec0T+Tj8+DAnKWF6cUQby3WgRR56qIIJJRlhz2
# DATA oEMUjPeDNFNAxMlJal5QEO/G7DaZTSY494yNBjiM5iUiC5kCzyGH2dkLRk0tLHnUqiMcHZ7T0eHxsJccFrwwSA+5oZxf93AuDVcm
# DATA UWnVv4tTDDU1WelUw3ZIZjAjs7LpztIB1dyQRXJxBl2OUAciV81mTmZEwKqEXSIYBhTUANw7dBGZMrXSc+Dj4TPUD/hLO5p5ci51
# DATA 6iwBz0HBfLBxwTykql6EW+UQGuCWcigfbC5QiUxCbj3cbHQDYZAMCo76IzQcrRuKc4RQrIJieDhh2xAZbqlpiOAA1rZkfIuGg3jG
# DATA 0qPn13fNJeXKSunMndu7m3Zu70XYOQMNj1liKSPTBIXmfNgVOI0nuun0o2QEcdLZxFMFEycswca/inrJASUqiTvS3SUhvrJu2Gw8
# DATA IKMK6ga2jMd5iiQX8ysrEWuQPGWRPF5dJGa4lTJ5nATRUPRSAjJrTKHQ9ymME9hvseRwj6Y9MPJQNQ0NMwlUc1Ca1YAJa6WZTEki
# DATA E3sTEZbhoai9nbtg8tG//m3l0aZt5QOZk9IENZpQFTYFg9oNy5mm7rJFCIY1D+M8HYWqxyTl8R7TfPBosTFXIbNS0QxXIuFTFrVG
# DATA 6cJzeu6imIvxy6t1/CLIiejHnXfLebc28W7ZVcx5t5x3a2Mv1kon2OV4t1h4ywDwAm8vjkUUT/u2rq1+7TrfF440eLYHbMGpJXRT
# DATA bBhR+5D1tZy3SS3PMJppjP33PFFVC6Xb3dGOcnvphimTUpSihGqeN11ZdsW4fiq8uzZBz41ebBSxgVThbdWjgLe86o284YS3Xpf8
# DATA 1Q4yXkFCLY9VuU6MalneT6ZuNDHTDy64pnxF6IXd07vl+V53tNqP5Zfq7ECgwKIwobtL9dz9C74sZWEZR6FsuqEg7mv5wrle1jKT
# DATA UH4UBT5cpFMlu69s0yW7JE08EvNsQuPhVDak35QgzmkAiZGCwchqb7aa5eNE3K9CjEU/sKASPWS9xrH20hZkxsA2HHtFgr0gkl1X
# DATA 2BIvGCmaPZQ8A7nL6mnJ40Ir8OBnAVlYvDILEnqVqbaO8TpYU5NoLBgrhEkWsZEgxIIiK6jh0BgkHTuH0jxFmC+AAqW9ipjO9sCv
# DATA 5Z0C2RqmmraOtQQl61VmspMztlAPPbNdQO+Jm7ANo/GyyOoX3vDMhhpnejrTcxPT09maL66tudI6vIZq1Xyiw5wuWDTDhpYZ+hbM
# DATA To4VKORJKMuEqbZCs4dYdok73+unbn39JV/5bzmnc+dV6kHnG5Y+FohwzRGulpzws84syoVgyN/mRbjnj+tJM+3GmCzIuw7HXTG/
# DATA jf7VnZ8tnPbjHXxUiAvi5tZT/IXTsoGweHZsRdtjc3Dwg+CQpy/QczaG2T1espPJ0dgsCsKfuEchTQ5leVHmTqARToJ9nruUvIe8
# DATA nDXVFpS6R9lnqJVwGYszjg2e+bWuAOvhZKVpWsdGlWC+Mt1/Ohki1DR6iq3rsgwp1fvK4R5XbjxlmDKqUPvhcG9G3YUNK/un46+O
# DATA f8NYMhDEvuXPfwa6jLFhfwBRDL8cf7VIKfvfzY9fHn139C1QZP/KF/5w/NXRn3Gp4B398ehrRpH9Bt9xA7/u+O/pD0Bkv6fXAWT2
# DATA Lf38NaPMvqMAvsdvx19QMN8BVnb8hUdhfE0X/h4XgUZz7LLnwjpE2njqBX8Iy5Xr2nsLRNIgeYJVvmAcFuD2oFlpwnPHSSDTHwwy
# DATA NEPFUWleQ4Jehjcbc2CsTT6LhsxGpRYd8G5OmlgGU4GkhtiqT53ZWmqZwKRDGSgdtMy2Fa0O46rRZXOlcnnksl4k5zBTc+cb6gpX
# DATA 1AV6GcY9cydVOqmJyQXDy3ieH6W8AQHNgXeG6ag6gtlmpXbhFDPd2fQjfi4YilMp7Q7C3ky2iQyFHQ/JDwY5cy/msdqr59eLo2gM
# DATA WzsYUuXGPpLb2tPL6AyxwpKQAhaQQjRGFyxmoLKMpE0ODb5506q52sTJN7VnhS9bG3lHL3MWwIVZAJpbdvqB/6VwEF3loH/RY/5G
# DATA Q/4pR/xLH/ClPuYSb9PLrkXzuQxuWS7FXihz9FQ8Ukzh9uJ+ft8eZ8N0QLHc43UTNLoI+zSNZcSIo1Ew4YTLa9FHybkBqp2gLmGp
# DATA RSOTZL8mj7hS7z0jzpZuiC3jnFOVwqPsmOF1MuADCCLusgNtGFARpIil18OBH7z8yTg+kNMRPbW5FNioSchFPYhnCdhfzKCKOtEQ
# DATA WQXrjkErNB4xbgrGgmggMJ7LnCFQIKdxvBw+5ThmjmPmOGaXyDHbcKTZaMqzgX18dSb+WSz8cxr4DmTmQGYOZOZAZg5k5kBmDmTm
# DATA QGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZtcGZFZp1erNyllBZv1+0C8/RyCz3Irz
# DATA aTlmDcqTcm3QaLT2q+3a2415BFklbHT7izlZ9ikra4N6q8mfq4CMqc81ylj+3Gp5PuVwtVYe+a1ykf5Vn339eQ7qRTnf61eWQb0q
# DATA rYUoVOoUhXLlU79Z9nwfCDav4penPtzGrZPwYc160OwufVO9sYBD85t1cMm8aqXYrnl+owYIml+njPOrTH6rtU94Xbfa6CynlVkQ
# DATA tSKmAwEE+qVGe+0lIDOKSwYyo0gZkJng2LIWUKv2m5WN87ex5FWVcjN7VdX3L/FVVSGyyasqjeYlvqpesVPVKl/iqxqMotOpql5w
# DATA Bp4KKsddmobKSe9oQeVqlUa11ctD5eYRckuhcqEfNnv1DCpX7zXCVtVA5bqNbti1oHJVem+rcelQOdldWJRlBj3MVXkG4enVKWO7
# DATA tMT8s5+Zh8K9FVJnHgWFRfpbbRn9Df7P5v5BoSH+TxXyKNgM8lZqrnNr6ulZFuj8Aolt3uvyWfBsqpLJhcPiFitcX3/daVEH1ss7
# DATA vU5nh3nsrsVS1WownJVVa+y5hTjnp0WXaB06xpxjzDnGnGPMOcacY8w5xpxjzDnGnGPMOcacY8y9ZIw51IVoSjP8JIAWO1Ww2wY7
# DATA t3vnMzMnmaS7XE+kl+Lzy7j6kdXypeHv3jHNPupv/4gfVQ135zPFpdPKRRBDlTNfjDiacFctxuXtz+XVvZmsPe/aAf1UcHe4lCHw
# DATA mEsnSzr2vUV/56d+/YZfR3R0aHckgM6M5osoVBMzlptlBdpxGPZS8O70M4DkiQxBarSX+uGBdCATOZUnYl90iU8w5pKDjMYpxl1t
# DATA 1id4sWSVLD5t84RupySLD9vbQWG/EFEhBDeUob2/89PtiJpG+bVG+Za/Uyhj0xe3eqw/7Y5272yP7uz6tVr5tQ+33qcqyUcsOVRk
# DATA kDJ8OJ/6w5jmrKObjfLOTyq1HZqB9VjPartS+HCrjLv5Mf3M6Cd04+JNt7OaI1mOGrCdcqxV1YHzaJfjt43UM2rw3774L8jY9Dau
# DATA 3NhdVpjb0av5QnzNr98q69zkUG9/vlP6JI7G9CyDCyXS6uONJa/sR+MoHShRVL+uCxOnZcXhIgDEn4+hMiE4ADzP0MPtuQpT1LVi
# DATA x64W1Hi4Hpls2aFI3uYCp5Io6lkFPf/aOpORWx4aTxbOZxgHyRhSh461coYWt9Aha7airnRm3kWB6/PQpelT9DNWHCXsRzpM/RAN
# DATA uAjLYBr1QTSnFOGUItYrRVjHFJ1ehNOLOLVexEqd0kvRkXgwm2YNgHdtaU1PGdmNqMR1lDG6Ch17MVZExj0RK2ZOuR6XMt16fb/p
# DATA vMwFI/Rebt9SC+ZKuH6FHr0acFmRfoqT5cxDMsLe22rkPUlJ3wRjopRdyZT0a+VlUvpVW0q/WSnbWvp+fbWUvmXQIPoccZqY0KyK
# DATA q1VeTj93s5VvdhALavkcszvVsrY/Vuvq1zietfrJdzY4zMaSMBe09/UBRko3H0S8o4xiYQah5dCt8ovKmYwJhUkDpylfbtrxMZ8J
# DATA uXJ6LxvPeCiUCcgd6/JcgVzMax9i3OQWb781u3o5L5WDjx4NtAl1E7k353/K8J5ZuaykI0hPpjABzy8S4V3490TqRhkr2pK3lTOM
# DATA xkyPJnSW3Z/r5NkMgvBH7hYlwEtVmLVnIDnDehoMN2AxB80gWKVBkxedsalgi/yv5ZwwycDc/AEjoV6hYN+WHoJsCNiJfIPnX9wi
# DATA b2G4eYmbl5wwL8nZn25q4qYmJ884nqnEHcZ4VHAdCWTOMFO5e9NMRAR4wJpPpq1R6QUpi1xBcIo1x4wIVUGU00aBOC6NEJoWa5if
# DATA XMyhF7DNxsZ+C4/WNsCEr/mBCM+FQpiFqxTtmxJDFTo1UxpmdFH2pJ/OEM09/m2WHtKYO2amFyVQOouCghDJ9EgPtAyk5+4ifaID
# DATA nQziabyXBBMeqichDGkl7xslLD0mScwPe9OAscrvxYko66qxbh5uKohky/KT1Io5YuHQuCND33agMMjYJqg6NvHdY3XqAChy6MPd
# DATA FX6aYCUGgY0XhYcchAGWWoNvb13sox5bdWsjP288SgoMUkAgwqkhCEPFf2pAz10WhFP4C61JnCnrCcs2r72niqWDLlv4BFavHUj9
# DATA XZOmu9hhP45Bbp1PlpgJeW7sgqqiqchkFj6Ae1+9GflKZtsABF+FbJAs4B8A7EXksZbcZdk2GDUFVKKxJAXMO3hv41mq8kMFHFE+
# DATA 3N2Pox5LUrNKGwAKkqU0QMVMjB1Bam3CJ914d8ryKT3H+m+EJqIc4DIp03HGgnpOuDruyywMOnSjUdyTxo3C48umrDx9eC7u9+FT
# DATA 12WnNaylDAveZNYhC8V6jvXnuBEGPVhAXsJ1WCorjV0ML+ZXeiCx06BDlnZKbXJdEh8BDa7gXlMMIlYSQSiTF1LPEEHbi7o7SuuE
# DATA nu/PhsNDxVtRMWU3TsoVVdI9ypEKWVlQ+oSDQazUEamDxE5QKuJkgHYoBYY+fh5RK4bpi2dPO1qYs6U3VoN2pvMLbTqflhX2jNWh
# DATA 7T3/62FhjzESaNglG1VS39fTwq6PmvRzIal6EkEi2/evWV4XCRXLK2RfNFNsXnF8KVJMud9YzRuFyrvQyAiSGpGKWRMPbXdoONGd
# DATA 2J33WbtEuGI0VWF9Ypk00fvod9zzZpRZzug9IJk9hl0uNDKqN9m9MjOBTSu702NYeBGkyA7VTTfj4armKfYy7FxUX55aBMscjGsx
# DATA IXDFGpLzgv44LDCWIZ4kqNFpaJqZKDgHZroq22zIsB/hLrJzc95WsrkhWmxrobOlzVNIyakZi5JrA3dhnW3B1nvRrLwMa3YQdpT4
# DATA tU01+9+Ovjn65+Lx3x79wJSxb4++P/oD08Xo0/F/PP7i6GubMHb8Fa4sAs7+b1w++j09/A0jyr7x6MvXdPFbuvw9yGRHv/f4nj8y
# DATA 4+wf5L7j3ymQ2dcgqdELvqJ/f6dAZhyfrxGn478DA415Z384+oF+oPv/5Nhmz4stK40cDU+Lr/OSlSFvYh2I5nCiLs6Tt5iCm6LV
# DATA I47Uyn8OlUVmyIv3KN5nL0+QZF4li4SI5rEWZfb2fDQczsy2abOO4qppZksK5vKIZuJTSRderq7P3y47CMzdD8OURqCuDNhcSBeM
# DATA NhP3kuj5w7UiC39MLXBgs40K78K5Znc9S+88mxmYGsCLxhDSmQ2ZwtE5xN84TaHcc6CeSATFzrn34Od0v2iaFzSnQu93MRATtn/2
# DATA AS/26OJwgWe2Yc1cbeMsNrtnRTfbMCmOc+asgbNaAxprdjYj4KVwal2hAXAZ4/9Gw//pRv8rHPylfi7khIU6eyYt6DLIZguJZLoZ
# DATA ZVW6GC0wzmRZ2aPqiZp6S0BPBe/tx48fPCqog6VqZZhLhveMJmQ/8MoOJwMjNJwSGU0pUWWpPQ86T/WYuynezFQFj/IaymB5AwAp
# DATA i7rAnGVGQB5wNknCHnwjeaPANgYK3EzRWXgwMMZdZR6wVQAOlZiHgpzi+Kf0moxuxk6V9DDlo5Tqno7jmzm+meObXSrfbLOxZqOJ
# DATA z6kM5Ku1+M9i8F+Yve+wZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+aw
# DATA Zw575rBnDnt2fbBn7Vq70Tgr9qzab/Y7zxH2bGH9eSP0GWeuyjymhAltq1bJHRbzG5V8rleF5STZ3splXK8V1sP+HL6p2qrXBdU1
# DATA j2+qSRZb8ZB3SzyEfZXFozp/aK2SRaM2j61bxgtrWLwwv90yDKocIe2va72W36wu1pxWjapOayB1zkpe0Oi0u8FSftq65FWElHZJ
# DATA yatYNK+Nk0cPXVjyqsL4uqTkVdXTp0oePXSu5FUrlWvRSKrV1uU1kmrDP0cjqbbK524kdvIuvJHkknfqRoLknbeR2Mm78EaSS96p
# DATA GwmSd95GUvdb16KR1Ku1y2skFItzNJJ6s3HuRmIn78IbSS55p24kSN55G4mdvAtvJLnknbqRIHlnayQ2sLXc8mr1+n6tMai2a/vF
# DATA WmNU9NsNr9bYr54EUF3dCM5Cw2RL19Aw2Wi2aJjVTqPSqp+FhlkOg75v0TCrjbBVMzTMTrfb63UtGqZfl58vl4apNvPK7M5y9qhl
# DATA N8PH5Ak7mei2U63Na+xLtk3kQsX8dfGe+a0Ki0tmLV4yK7WwVUYWzXKhqgXztSE3ePUs/5ieBS7fbJjdTbPJvSQY5dboTkquembJ
# DATA 8vziDXqlfiHPF+/OvIirdkjKi3wpInEFLASCpYZF1Keqdvnlgna7DQ/M6eCd7DFakip2Gy74nhe3C63kfjpap6N1Olqno3U6Wqej
# DATA dTpap6N1Olqno3U6WqejdTpa5wXQOhfRnHtRRwEUsToH01PBMTWDiq7c9Mu1Vr3ZuJ2bs6jH+PAwHtOIQzLMZxNcueHjyUrttmJj
# DATA 3lfH2KEfMJ4OhoeGc8WIRIoJ1as3sb9/u8JYxLei1wWp+C7Omcsp5clwlnoQbPbUi/hZFaVVz9/1KvWfmLdlQjsyL6U82A8Z1blN
# DATA cfgp1vh3loVkswytc6ZOEMYJwuQEYRYPHTt1GKcOc3Z1mJVKypepGqM7a8hBSHtBcbGSAzba8M4bS0Lm+uiYXQXQUIZKBn3IQMYq
# DATA HHz1BJCgfjLXzac5ZBvcCEtBgr7FEeSbyvpOgxNcTRM0wzlYguozwmbBkgkGRZ0Eb/tvotdPAiJawZmk2NdMauonp6VyimSItYEe
# DATA AF5RMQm23zs5vvo5E1lzwYrpZpm+YUy1HcTtFEKJkBzJ7BbquiZReFJ1yQLJwJPZJRP15kkxb6yJ9UrIn+kC9JSJx0NVyM899G8Z
# DATA 6c9YiKHp/dAzUR0Tlgc3j56R14FtwEUajHgOwMszLAij5ppdmlSxWjRDTbA3kqY3Be9gQJWPjMNkL7RCU7nb71Nf25kl8G3gOZpc
# DATA JSEUmqKpFvhR/mqZeaQsy81KTFSlDsVAZh1Mu56VvHvxiN1i1PUVlFjPuGf0nzLRJTWZ68kTQaJ0kTJbJoPMjihes4R9q0p8aANq
# DATA 4IumFOOYJ24isGIi4Gz+l8LmPy3p5LooRdo7JdYjT96KeMQUtURej4ZI3JhVe6htjcK17JNnJy/5fKmrnaQuPbfH4zLAJ4sCmhcN
# DATA P1mmQ7oUgJIrO70lRiryMsDfm7DntYmw9A5W9Vx7x+tiWhtD45Ry34r8x7jKiAUHARIRjc9gKmWuzM1NcJiPsmm3xiu+/fi9dwve
# DATA vUePCmoclvbCw4LScgfEUuZFIrQ4gUpooJVUWamRSsHIfkZpNm/QYDtu4NEUw/YaouIj6Qxkw9t6WORdKxKqEusU3YUS6FjJo3Ls
# DATA OEGUsF4Iml847kIRdBxS/JQea4FqL1XXgV5mE3nWvCrrWjRnvgM5IepacFasaR1tBVNkg1sdMAzFnyEwUpj9on3PBnRyqCQxVSxL
# DATA 3gPNqUHMeXVMd2SB1w+i4SxZR7N8KMFg4WoVz/IlssDt/trZ4M4GX2qDq0riPPHOE5+z7lYa79dHv53rNEbqDOcceOIpNB548dVE
# DATA KTbuxTxI5sXHtQt9nn42mwAnWPJ+gT3ihwbRQnf0Zl2IyIwwFhtpY+NvZ6Ix2zsbC7lnugXSPPH1zqva8HuEY97csKFfkSoAtsw4
# DATA VF/w6k1jJU6l954m+CjC3HhVV5z1ZG8kMY3B1LAHS2/4uYzpfVCbV9zyAUw2pFK0uFlsGrfexDtv6vfLYDQfDWWoKgPOWDz8pt6d
# DATA N9TmRK7BBQ/DSp/6/pjKjLGfVNWmPb5TjREFTwbjgpbaBucOmOJ0IOH2VLRWxOO9YEx1qmfbgiYydzMJ/LnfJQq26WbsLyrRJIR4
# DATA Ny8eaMvr5Ij8IkqmMyiqs5S4FQdVwGzmcW1lSXnuU5J4aCLzswkrqpgbqJKHU1ZJn/DgSRk0HOqqnlrxuakK6qaqdCu49Oux34+0
# DATA nZflvZh8QW9Eg76e5WRsH60krkjt6SCeDXvcLsWcHcPyw8ZzTK1EXV0KuOSxfUkW8DA+HHEQZJ+DZx1AHN6SoQeL/pO4wwOnkpif
# DATA jZmFqEJaBwQfxwdKr1ybzsF0oKP/QcJy9lTvPRY3EWc3r7dovzE7nckap2AC7W1GL0WdHd+DH5iRmtm4QEIBsqhv54kRSPVjONhp
# DATA OA/H+t6eYj1ma4PrEvOeuKJVegIRz4df3bj3lWcdEdPrGRlXYRAOJ6o/kwVPqy9iGXwaKOMcVGESBk9QwtJjou5hzbIXjvACe4al
# DATA wAoUiswHGQuPVmBPzZQdY4PPzfon6mc02pAh/mLZ9p9//tHnH463XvmrF/0/yvpw+DE6jGg8A1R1cnjh78DaZaNW+yu1bjz3r1+u
# DATA 1yt/Vc7++6uy7zfLjb/yyleRATO0OXr9X72c//34xz9+OBNCRJc6kKjH4wwqxVbKe5GLjP3IKoh37913qNfgZU5q3/Gwx0v49ECJ
# DATA wnpFpFLItt3jwzb6+ydkH+rPcfoKj17o9IdRx1OXH9BXfUtiHkxnHeWf0VdwJAvDgf4+I9PllVc+eHj3wYP7D7GBemtr6xU+Y/OK
# DATA 2mDZl33V7GzapslkL7zVT7d2eDcjToZsgcF3k3rFm6D63uwOI5rBbN1+RbZa99MS8gFuvkeH4+42Hip4WzRfb21ZO1C32ClUROjF
# DATA LLe2dna0f6kUPo2m2/7O7Vfm933mo8bnyD5WD9EbqHc8GPObs4DCLnKr4P1SRWb5uz8qvOJ53mdTOUVyy+ftDoVR8PT1WR97H/1G
# DATA tVUrPCEr81G0Nw6Gt7YevfPW37zz7rtbhXTai+Jbv9yi6zQ8bBW2JtEE/6jvH32+o7JHbUwNk4SGnl//Wm9UTTlA+wIvlsvG19VZ
# DATA InuId3OntfTzPYwF01gdq1D5r6PBD77GBXXIL8HBKLz+R3J4qBSlj4J++A7ZRXs4pIDbS8ive1jJ3sGdc9e8V73ysst3+LTN0jTo
# DATA KyquBzBktlV8599I92entuaD8j5/BZX4lVdoCg035cdMN9qOxumERuGPpdB58r9zC0WMLOAVdFyCDcAfSmxNpJhCbW8Vt3bwwzAc
# DATA b8uDlJC6X8E1PJmEJewn4G3E28nWL+8W/5eg+Ktysf1x6eat/6n40Y2t/AvxXxJgKvcLJOw+in97653xPk77WD0JP7O1w8+ogXiX
# DATA W3ouMTs6EXILV5ZtqvnTj3FSl2Ja837qYUOv+md9HDhcL3zaJVs3lYmkigHszaSH3gD9UYl3P2yrd6LqfIz91ds7O7k8TSmm02Dc
# DATA RVXkxwseTg+Y7FRXd6jaef5GuaOmugpjGiYqdvr6ro7nL8sfyQ/6Ruz5lpv4UOLWOz0qli31eDjej5J4PFJ7w+37aDrXj/bo3s8+
# DATA 35Er98f7ciTITup8JQiKfaoBH33WqH1ON5tY7OhKY2WN9fK57LF+2VGN5zyZhNPQcsCFv2KyLp1GNLZzIHvFYjHy/QUcveVIbpGd
# DATA h6clGL6QzF94Wi7PXdrdUntW5Fr2vuXJ+vk4nU0wXNHswoqmShT+49OeH1PKpKfgHYPb9JqC5+/MJ2Z5a/34I6vZfvRTehKnVk+K
# DATA mc5wu/rQc1bMOMtLNDyG4546gGra62y0jULGLSWabFD3xuf8UPZYh6Ds4adR8pV6Y4Pme9+KxrIm/NdYW4JjwxspjtcbcfcJTtfg
# DATA H6p89GByyNOngsyXu1wfcZIBBYdOWWB6ZPqXVJDYgUV9r6LlwZbBnJbpfWqR6LbQz+CS0jN/+KBZMhTTxXQQYP+VNFfT++1SZMch
# DATA XxRHljJdSo9D2C5BcvgGCwvGySEL20VPd7foxeOgO8OBcjOSo/OmqWpP35xlIJXax8qK4V7V3LLj3fS27JpmHtE+8xjdSZyWQAjb
# DATA 1uEUcOVnH3/w8Gfvv/sfvF/Lt3sP7999rL/c/5/vvVvwyjGQHiZMTh393O9xaNkrqHs6kMhTcwuDUb42yjU1UKIdlj6hgttWVeYG
# DATA N83sJVM74ZzRiqe2a1mJJSqw7V/mbsN/Wz2uJegu5Sl8Kop7Fx9NrpeyXN/FYS9YlyX8VaMBaRA+LSwGXSyqKsGh6/7qFp423/ht
# DATA xpyWl9M0u9hL4snuXVhcy8JN9RIN2ae745jec1DEzDcCSCaVUKjkiii5Le7RTEHuLA0QsaQqgie1zatD0a0G32Gm6AEfP+OLMrDz
# DATA wX5UgLNgOkvCj2UL5e7jZKYOXuuPYn3uVssFWTfl6zv5grRajCpUbUTBTzXZzt++2XClw5zrAVe20M26SbbEvIh9YlO7lxT7Qln0
# DATA 8/XRqn5slEmmB9Np0B3Ycf1osdSW/bdpnvtrM12dzMsb2Jvn94e9z/xCXSwDtqFhd46n2+qbspNvnSJvrUmmRGohe1kOIHuJ+bWP
# DATA LR/Due6Bom0ydjEaa4ooGUn50DDWDfPF40k27VpPv3H/F+///N13Tyw5epJmScuezMqrrovrTQg47KgZAEaibVWNeVKEnlvPsEt3
# DATA kz326j/gX1TRyW04y/dxoH6nOUBRGd2UJr33wqoYq55hE37pE3QbbDH1IP+DR1MViVyHzec2trPJDO4rqfgUPPnGEwxlzT4FhtO7
# DATA z/9AiNUE9NdqxL/5xuseTztTRoOqrtZ2WJe8n2HQDjxG93jYvTSGl7Lr0fgUTMiomTNEHrFz/z5mYVvvx9jHndXIrvGhd/h6P0pG
# DATA YW8LZUQV7eOPYQ58TPbbrrf18ccosY8/3pJIS/FdU1diglPso/Ay3H6b+f8qtXKt7s/5/+AVdP6/q/jvr390c5YmNzvR+CaZDt7k
# DATA cDqIx9VXfvzjH7Nwh/BqsfgiC2NYY8CKL5Yr4kmoobd6A9dDbUZ5PNsaDqlbWOMVxDJFo6a/YU+T/jwIUvgG9dcI+mCJ5QQ8uz9R
# DATA VhDN18FsGg3NN55DmG/pcI0XMkhsJ+S8U3I6SISAZy5QI8t5LDnKs2RIMZaeU8ebrvHkjzoWXjzxZPY+k7yWITMbPdWwQJl81+7g
# DATA YFLTnMfrHHK5mNJgSx3LKEn4SajW/5AhMutMubD0e38+2UuCXvgLqB3oFy/GxYxLlDcyXGEX2TbNjdLMXSTd65KE6NvUo6zdg3LU
# DATA z8mIb3lreJbDd1geG555YlfoFu+i2trR4cnMYsK+UjXtxy6fXZm+yDumOA0z1RMoDlpPb+WnUpR+nB6OsElm2zImOZlbR//n0Tfe
# DATA 0R+Pvj7616Nvj788/sej39Pnb47+4h3/R/rwp6M/e8d/d/TN8Rd07Y/e8ZdH3x79hW754ejPdDt++PLou+Ovjv8z/cRP/xlfb3mY
# DATA PMCclxioMVFFRw47lkaw5LflS6oMP57Efhzb5h6vl+5qJ0l/lSMkJHtD8rk3G01S/Vs4xuLmx0HajSIxSrDPDAPsbkXP0MQR0yvw
# DATA jJglndQsd/QEfcbETG1L2dyW7AmK/W4uRUuMBkwpuwMqsm2Ej6JbOefEDTTXRJTzlQFr9QeYUu7ydHKjuSgybWfZz/3hDGozuZ8Q
# DATA B2xF3tb3UNrHsXYjqjuSkGFjWphKitX269A9nH8/IgOCZmH5yJlp/cf9njVrz2Wfmro/fMOeur/xzsP79x7/7OF/yEd5YSqdS4f9
# DATA tvxzS+1s9Syj4Jc8u/CMJBYNrcT1NeVMmZum0R2zMTc5/lG1Z1k/Vk4o4/qGB0qprsHNVF3h1N5+7VbmIPso96340WflQsP/3Pp9
# DATA 57UPSzs31IWPPqsUGlXMdexXW73Afz/6jlr7/6A2/f+z9+7NbVxXvuj8zU/RdpJptAyAD8myAgX2UBJtc6wHr0jFSSgMCiRAEhEI
# DATA IGhAEofGlB8nM5kbV3KTSt06NVUzc1L3fgBFscaKYztfQfoK95PcvV773QAoP+bUOZM5xyK6d+/n2muvvR6/9SHwg0/UBv9c7fgv
# DATA kmd/wI3/7C+KA3ypXn6pCsLmf1RWz9ST99WzR8mzp1DiI/X3U62qRs5HysAeQJ6UZBLUYaS9HptwWshmBbWYNZV8bfP0k1zxbgpe
# DATA oXlteRlYDc+rrgB29nJr2F1WbaWN+DyvvLoSTMP/9ewT4HSKqT0CXqf4Hw1PjVTNCXJINf6n8A743y9wMj6H+VI/n33x7AvFAZ9o
# DATA fTYkvM99jWg5dXTWq8kP6qxnxuIZ/F6btz7Qm6ewOk+hYWj/MXTz0aLdNxydWP/zXz//ELi4XjzWA1haatSwkJYaO2rr8MaIw4P/
# DATA BhdwNU56wUTgWHX0Gnq7x6ly91KtYVcns3VCl3RbHxtbyhdeyD9Z13fB8/G35O7fLTdeyUpqMy6bvVdt/kNFPT2XLb+RskI3UIFT
# DATA heCq1wfgpkNUGKvZPU2rcHmvVtMpefmaV/jJ7lpDKEnNWjZn6P54a87WJuLB6I6KoZ0Ev4PN/Pw3zz4vGw4gux13/iNV+BFUpIop
# DATA zvDsMfAA5g+qcpnrPz//WFHYl0CeQLnq96+tWSWwwthOprGuNmAny7jtKYQvu30m1NmTMGcv4IT8WW0tteQJDupTlm1Uj59/rIQa
# DATA u8esbGJjAqAX2tyO3sbYHA3rbJzuTFtfL+vs4fJQgOuSmm8OJ8bS8AttVqoIbEYkTF4B+EozWKBlRZbwHE0cqhj+W6+HHPpAXnLh
# DATA PDyUfk/DeP5RZNW+eP6RmhMkYziWPkHa+pj2bfz8wtPpsvNOkbGasCc0kVB1QLLPP06oBDzUlMDLjd2Orba6iZbGg3udvru+xUZq
# DATA xS7uVmf/VlzBrtKX4KnnHwFnVyNb39qsmM24AEHwiErp+tZWc+vW7Z36+ZXVlbv92xs3bq6/u/7DjebW+s2N6807t6/XOVUNCsMP
# DATA Wvc7tfOA7dBPnV2Ymi9VZ5o7t97ZuIkGCRwESd6bN3c2bt9cv97823d3mtsbV29v7GARvuNWsWjzqPOwdB6Edbf+u/2d23e2d5pb
# DATA t2/96Mf11bv9G+u3f3Jl/Wbz+sZb61d/3Ly+efOd5sbN9SvXN67VEU8WjTG0WnBR9aWw2AqhPp61xHCdYfhaEdDw8Aa1IEsV6tfF
# DATA V189/2qwRP9OvNMwGyLN578kClMUrOqCl/S9uyimAek9Of2iym6RUbBEuKuJCYTFtRnSoKIoOBBVl0FI+EwRzheq30+A53z+/Ncs
# DATA DPKbR6JPiQh+3F/LjFcyVviaK2qcTkODuC48yw0AV2O34cjnYN6Om7bRTL2vIehmGatN93bVVw0ErMPvClm+uK422aBWsuxnw05n
# DATA lKs7zv3OaNRVV/g0NaoPQopETYdYZwfgPdzdp+ABxKjQfrHCQ5O9DjgJk9IDhRRQ+db9WQPH1nDmblI7N8BSpgVSqgBOZPVN6t54
# DATA uN+oQdM/XgrLBifXp8hk1bmkKEfxnCdE8r959jvkrPAIeC2w4k9A86C2ghJAoNKKlH7+K4dVO8cxLgL1AZ/y/OXhPPCItztjMJPn
# DATA kcnIiZaYEnkzSYXhuZyg0PgFyjV/gs6B9OAdKl/wgOAf9Ztt/SBmwj5SG17JF+qAg49UdXBawYQ9MUsSn3d23Sju2yIzz0fBZ6ov
# DATA v6JzgzsRDItOYH8BWBSXTmRAOavBRa0PCq4uIOvqgoqPBZd4TdR1rUAsxfnGbnptfWf9yvr2BpxGaSOryre24aX0TucEVXTlJFA2
# DATA eu1pCyqvuLyKHrRqrYBM/4wrB6wbmeETEkBARoOHRpamBVWSpWKdnyZOx41sxf2QP/V1WV888BZpMUjgJbD+yFOcbQpPtG8Vroi3
# DATA C/AxV0FPINimY++G2+Qyosp1c5wQUMZ5ngtkVzKGZzEogzWtU9zWTTU8a/vCWEihpKRptN7DqEpW+cX3bFbtElpnYETF6S3cMYVD
# DATA QgNhr4sQP2r28U9ZGgqygifYYek99WydPpKDKfO0lvgZaS2nscbAgAmquJI/bei3lWbVHl2x4f4n/XEPLbY1UL/JqcLqH6YCkKqs
# DATA 4ajnOJh0c2udKoCL6Fu9wV6rt7l1/6I89HqtBqdpWH0uM8bSvX4sXQonnikc4Mg5aJeVjJB4IMtwOoS8bD0yXmCgSHXSV0J36ZxU
# DATA RKYA8OOCI433D+qHsbjNu7gmVCQUK4PMLo4fVsgkPyDFmLonfIY68qfR4wFf0ClwWeSox8hiP8brnc0hEtJPPLG0ataB4Gx7mZHY
# DATA IcEz8OInNHRQTcVvQH4tOh0KuJt1Dki3bE7L3X5hRut2VpWjAnransBd0Dq4qsmz39HJ+xi7/gt88Sce66e8qn/ClcD7y1W4Yehx
# DATA 3dzYeffW7Xc8eSk2xZKSY8Dj5d85OlCWuHgG/rEkOO6TCN20TzxPsGehOMfjKmjJyCyhfQSirrLgCxLQCz9CH9jaUuAZdDp1uLfW
# DATA CkZE7dBzFUsT6wv5AK/9bxO8h9P19Ik21trunY7KRt+iUJJ6H++8T5N3Nn5c/+H69TsboidRDzxvHLwJ6BzX9qWA9JUQJ485dOFi
# DATA EHUoUjXMGEa051+gTe0TFLa+JK3EB3hRty5XrJslbQ5cvP6ULnApQXdWGQ2xO8c1zL2vmJ7OnGDvmqr+/D/52ofaUppaa73wqTcA
# DATA 9fXP9cVbvOZVz2w7qcRNGPvp0kzfZ8dDmy/frvu6dZMFIRem8VNkcf8kOqKAjxE/hjF9SUNXg/p15FZrti1Yypr5UWvt1Yv2aNrd
# DATA Q4hYrIsXQJWLZMaT1jIDoyUsHe3FTXuwyfaPJv17sMlQjO61jvfarZpY9DDfghVbkJWTvdTXp1OPqhSHXML6nHHx+6POQ/pL22oo
# DATA 2rQJA1FHqvHO5cv7YDAOPXfZatajhCTE8oYkt6LOFhyXYSRg/sUzeggWavhA/YQTbGgsidtvr6uZ275zY9twXdAyDh2j9gJRIKRB
# DATA o5oz0xns5kIKECQaYxNH6wkS+mPao0RQaiPow5pMsTDcZXscEPFAfsIO+WSvpEmSvkI9fAWd+r1eyprcR8SBJi2NmfcynSJ9sG2n
# DATA FAE3f5nQCVwEKX2/GA0eoCgY9N12WshIbYLOzrbUXWgqUevQqhygf2uWJCVvdTJw0Rs8KDaUiBkAxXjodlSiKVw5YVJfWjIMHhes
# DATA Nn7+czhBPlJc63OL3WLixTrO4HLMDoFW4Bgpygsma/U0YBZA4GLniI7lX/xesoRGvQRF/ywqLFKvWKPDaUQBW8YmXIGBrdR5bzzC
# DATA qxRrXQUvC/YEHnf8h+LOnesnLNs4BbW0okkW1U5EtbbUQf3ALqaiAEMPDzGy9pxK0PkAVFr+jr7Tv9eHiHwN7cpfpF4AEY/7B3Wf
# DATA xCzyQlW7LIa7AvBIVoDOcl9pgpMmJx3tr3Aes/j04Mg4Dh8+wbuhNZTi4d9ESBN4xR2geUjd5ZbzIZUE8BXIDzEqdYlhdpF7AyID
# DATA xsxgRbuyvIgilzayLF6lNVyPQjJzX4t+iUeBKAqgB7t2WAhPG9DZQVf1bIRuulx1gyI8oVVk++KuYQLkuEs8Bu6WsxL6myKqnPGt
# DATA xRL73QMSCayJWORLfzZAx7HLmUJSMsRh6hm8hFAju5RYhEZP5XEMnXbacLirfEB0BMSBqqDbA8oR6MsQ7rAxVhdJoDLiDzzaXWxD
# DATA /b98oDJL/m+Kc/1RCcXqqvz8Hw0XI1WlYuZ4V1bSmbqOgmga8HHkgZpDkujsXrGGzinomkCY2+NB6QaK2Sy9tZcPepAzzZog/lLX
# DATA uwwPlhY6JJREPujdx2xAeXPU6bXG3fud5nhgx0KBIOCURZNqGE7liPQVLa3MkOd/yQKx8fcjIf4xWFhxZlGRAdZ7vIw/+yOcO3Rr
# DATA eYTz/dgyI8pgZdMgswqPw/kdxqPr16pudVvHO/4HwE6LO+yK6e5cLTEF9DuT8agFYBFECaKRUHKtxosBpCCYf2ObAcTAwz6E8VKu
# DATA pF7rpDPKE8jWmrQOxoBVPuhjklh0C73MgCwUaE6IKrohbamJOdgY/iYnpnxXPWkd9+yj1Lyg5xT6USn8rvC9et0Iidig5ywnWq/u
# DATA b4TCJY64mkb1q9yauy+thTDXQIuyUJeIKzSn9sBDkFcfwz1UR70QbcWfLrkx2jgucx+FDXeaCkJSWktOp0YTIjaHW9uzTA5uL9AZ
# DATA 1Z9Zfl0o2T5CifYp7k6QarUru+j8UNqAbfJzdhT5HNQMj7WRhw0Ujwv4LVna6Pr+CercSG2JvPiJo4hwPWHMYsXsogxMJDsvuEey
# DATA VBa/oliHJ5WbdXIuOTcHPt9iRzh2MvlOwsi1hL3EYELdfgWdXfX0Mn6Xus/fJ6CkQa+tkZmQnJb8M3Wez3X0kgJCPaod/hsolJ9/
# DATA KB2oBHdLirAXeUJaZY9ps395RrGQTF5E3NxN9ZyDPc1wTh4VteaUAlkTZEPTmOsVYZAFtDyC/hHnzy8+G86xUzwXomqweKnIRF4P
# DATA TNPaab6Q/ZDkBI9tsckoCR3lWihp1RaIQBQy1uI2+psgVIUj5hUrS+c4ahROmfZSFrRpvbfclv1BSPmoNGO/jF97pQTeVKgleuPP
# DATA 11kuweEgF7j5umupe47aDcyxpM4GxOrulCQmwwrW7Bk8ATYhafWxrB2o/uE6ZFubTvEEO2Bhrpw0ATBB1DtTnBQoVqCT+p0a8R/Q
# DATA 9EFGo0fippqE4tPjUBslST9d4tWbe4FLAEZ2kpVWyAWC9AtvAvbuMN9GScd9HSceUwZnSrZ22OWoMmXLDN+6BkuHKSBSQnvwkw6B
# DATA aRNU9uTY1gnZM4ms1eqaa4yXgvNY5+I9Zp8fADFsqZk7UqKmqcfu5Kh73EIf6mIBy+oeF/duiFIJWxJn0+8LzDrgF7b6yYSVM3Lc
# DATA ItN1vQSEodt9pvw8/nK74VC0GemZPbjiACkgOzdQif8xd6+XHBk5rnu+awULWTtEB/mfR/87tyHSTZv2RQt+89a1jeb2zvrOho6H
# DATA 2dzYxh3LTBQhgOCE5c6YcaGSvYi5zlkeys3kpvtNjZY44HxiDkV6cOzT2kblmy+tsDAOlznu5gBI7QaBkaovjxsY+Xt9IfH4Bscq
# DATA wUR69hjulQC/6OA72w4STh2p9aODr+MM/HWyMnjttdfMjVjPsh0EfrtDSBGMDty53x1M8mTzxvpbG+VkklPyA/AHfNCxUkL3x6z7
# DATA U5tlCIiXVo2EZpf8bDIYt5KfKpKAgx0X8gHGfo86amonHYww7yIyEWToavMtFsMyJkMTUs6xh8QCyt7OQ3fChrtH5X7mlrS1g+5k
# DATA 4k168RugHKT4lVpM7lnRAmG5cnBn0z60vVa/SeCRoFdusjRfoqGVaZYhrn//qIup3i1XTsYVYYbQrgNJi+KAf1gqyiZViS9stQLd
# DATA Hkw+CfGg0hGuahsCFVis5kEXsNhwTR+0Rm2jTwDbb7FKmNTqGGzCw5lVLhA8fosuGLbC589kHaVIsUdi5E1QSnuiLp8fkWeMpyVC
# DATA PxGjHv9VgU+hZ/HlyRa0KwcmLoYGp/gwJXQGJpy/B9BX7939bgT+zfaed5xLSLUI/Xr67FOyYoMSSknUaEj6KDIVfGGBizdGkMSG
# DATA dp/ikDGnu14qflg4en7vjj/mpf5K6Y3a3Sr9mZ2ulinYj75eZNDi/knOSB+g+SI+VDIzheMT2mqagbrkFow1+IL9Dd0jIpwU/7sX
# DATA nB2/mmxRgyKZeeyZcp1+I9I345Og0xoZ8NljJlE8V0m7JfBoUPf4YQmBvxy39Ko6kiAOanelkZxLLmS7tQuemAYVB7MCe4LezBzf
# DATA 79krAq7Zj5CEebk53kiPDPRGn5A2iQcOvh+zLJCXSW8PnOI/NMdQJPVz2kyOF/InrNh/SvHnpPEVyjJ4z7m7few3XFgdgU3vA5cM
# DATA I99IJh2/KD9ft78oBy0Ya5JPp1Yhy2cF8wvYPWRO5tTJ+EPqneva2T/xW2FnyRk7wAQFuzZ3gNgz/hDaVdPphtc+Gv7U1DiF9M3V
# DATA /9TfuP7MmUk5wyDtvgZL4VflI2DSglqLsXhb/K12O4JpkGd6BqxC4ZAsP+SASmMtncEvxfFuoFjtf0Qd4gcUm+nxp8CA80THE/qc
# DATA i/InQH8xCYez/eDJNolXAEfsbh7nJdm+WRIjpzUlE1FBLaChd7fRpHb7Mlv+brHf6UrVc93LglkO5vPf1PzQFGjv1z9jYOEfgkiO
# DATA L5ElfYT//fDZY5ZxzjqXwyF6VexSQhP2Ta/XTc/RcS+weTNFOJHsQH9UoSE//q0J26K4Qmrjb4K5+R9qSH/A4MpHz3/1/J+Zecv8
# DATA SEhDVOv2F4prURWw1ACu0x8ixX6kanoSilGf6ZgXxnOpF0SNsYv91hYHDFoAsiwonF8T/TNVhWrnCyvfvyizsn9EdIPtkH8d2d3u
# DATA InraXfRaQcjURjgrv3VGXEAUUW32Uzz50BkRH1hjKNLbs4vFDOW81n0XXqLYO9KJq4u6bjSisASkjETN/ZrN+dglbY7O8l+tKF1f
# DATA xJZ5+YLp7P1AjxmwLlFlat2WoP/z2Om5M3zsWDm4HeWdDXDy3ULEyCzT1n+Uz0AUA6fpKmAc3euc5KXdc1wPN9GwP6l2Ho5BFbyY
# DATA fVl8+Wz1u2e90BdpqL0WuJstbFxf4OAIVcfxQDvdU9F7n5JpBN1QyfoHHmGkzK9FfN2CzmsPZWH5kM4dJ8KxP6dVxQdSMzeSjonC
# DATA bvxLNlAo/ZXFzhbtauT615p9QaXpU0EiJZxpd1bFX5nkdCxOSssZHvg0YuN2vxDA81ksP7igGlC30MaLWC3RRZ7hAqM7i6tkW31t
# DATA BxfjGUODdVbSaHNsT6045bu7jxrNvtmdYHaAkqEgqMX4gBfNl+Nx9k3tC8U/2BUT8OWq7U5nCH+wosryFDQCFZzsaVm4PEeLg3b4
# DATA pXrwsMgVp8A/4NfiJP8FmtXgcEdkigRipdSc/RGccTBc1ISIP/9IjnYbI8ESBiNOMHGpTTZ/XWZl12zwBo7dgFbEtxYXD4Ji3AAU
# DATA W1T5XJslik57R9wuopXOwUEHFYSq8yXRHM5jV4uMSFc8a0zF+h748ScZD8p52oe1cPXN3eJR0XARmBrWVnePBkjPnTjrMASJCgUx
# DATA SE69MNZSJHrfZehc3EMEcKaTilDvugNjtanyWoBRs0OhtKlNwBVIN5jGg03rdbyiFDLvM1w7UEXyOUWkALGZaCeOVOOQmxiohwUV
# DATA HO47YVgufUV9qUYdRf9dEECBeL0V5QwZElHKi/E3uBi7K43qSKMV4ZPKqsYvqkkZezmsthANSf0aH44ILFz+/hlDnre7+FitKQD+
# DATA A+63klEeoqNcq93GJ0og6xx076VR6+Szfy/cubDZf6GoHwTTf8JYLbU+n1EUqGioEtpBT2Gj4BbBADQoh2Ba76MH5a/sO9NH1sLw
# DATA OuzyBEIkF/7lF6gOB8NSujfp9iBZBhoRLJvPzlE3ZxYCOCFgQhggXB24OGECAO3iAa9Hw0GPTNxwYoqsYNU3gpynnT7QB4EPsw0K
# DATA cgf0VY8AcbMHwTuqwj4mN9DxYwBJrA7EajhCG8Yfxnl67lws4NGXvkySCThDretSjS9vGpQwBf1++t3vSmyyJlH7lIlxXfv80NoO
# DATA 6JRllrK7GFaMN/lGrM+c7kOVJZgrux52MqXP3LhZVIzTSWGpw0kskN7FvltyA+otOTnsdBgqL5yr8OiNMobiiZqxluEZ4RT+n+yE
# DATA 0GtXOOfa5DhC7iglN29u76zfvLrR3Pnx1gYsK3AztUOQkREW74AA9fePOu1JrzNKp77WkP5X2hsMenNIj7kwScLOfAp/rteToio0
# DATA D8oKOmDNvJoP1o1CS+qXtQlpF1JbQviZc9jyPIEe4Ws8drWQY2JrH5EB71PEqXuixNKnHB7seE/NPnwJxRa3xStJejm0jYRaVyd4
# DATA lMxk2pn2cbEZVfuva2uw66IV8oOald0GZcoId/FouKePbIeIjf7Mki/hC0dbBg8WVpXNFzy/jAmeT+KYNGhm/oxj9OcI1zNY9zz2
# DATA P4eR01Vsv9eiu5jT4kzWoGZUf2czdMwFyy9ie+glBMKJiy2z5+ixc2MRMEMriiK0zRvT7h9hbSLAFZeFwD/nWzEaB78QqQcsfwTM
# DATA d0aK96j+1J3GWoL8Jnb4T91ACvdyjLdcG8tUx08Bo6uLA0do3quTNryc2LrR+i5e5kn1lzX0S6NCrNsFrOxSEbnb8kFGeDsAUw8M
# DATA j/aXO1DsjirFskFhwS1i9IR0YvSdBXX5W77giy0t3Xv3TtP7ueZ3jPq9NK3ovy9MKxf0j/PqxaXvt/YazhP5e5X85HRjcTZDqB4z
# DATA YT7DwIhHydnOhyfI/h+RY8Q/AR6KuAIY+PSPgwiJ3YIFAEHYDMsOnTjVnhK1ZBWid7T6v+b7jaIsQZ6brHFiGnSzueiATnCC0n+r
# DATA j0mzhoopo8qiLFDg4FUTPYtE+6onNCroFu9aKMV/lt2zett4XkW3wlR8seZq8VETLlC6GhIFfwZBHYWWEAuIFy+aMV98222T0B8v
# DATA TXfoj4vTn7CD/l2JbcZuwSXXAwDXCXdCfXYknFXCsvyAaT/qKx7sVfAUvqX416B5E9MawCqbjnuQSO6R7oAdfQknitZnoCNYzJBT
# DATA U+eBujv/AY8HOT5wX7H+1WBSVyp2gE8IJVS4wqb74Ctj50/KIwppd+KDAMLc4Hzc51QiMYdBcCQ0JAm/PG8nBCbBCE79Lvch1xb0
# DATA xCuMlPkLOO+Ala3wyI1rsUOTI3RyXjhQySpJQ2kUfRL4SrvGBj0j+wFAJSuxvVZcZXbhywgA6yIT9CUF0KBTFwtLn9ma7Rlma9tJ
# DATA ffccdcxwXSUznDODZa6LdqUw/NLyWw+ij3SG1WJDgomfCDGAYEdwFXMCcFxsIPFn8Cwj5OnALpJs5ifbP0yqnMF/5LwBj+kcnrEA
# DATA 7C/2GIobJuEEISJEvQ7oPu6Oi7Ykmz+aLsjQ7F38oltikVgLrMOLshCDcyRwLSCg2sJxs3HSIUt1EK0ZBnlQpyxLPz4wln76uThr
# DATA mmfef6y5F0HNFVKHg6pj3NJxolyH9Pk29EL/cTvhTug6bkoY4vJYlI42l5hXIjZH/kGxj6nUxvRGt3CKPB2I7vW41VcSeDsBtYeV
# DATA G46d9qkRcF2EhOXwr7iR267hMcl9QY/BMyGTC9XwLyVAQIL2szixWYI2PToLhvm3uHNZ4y6AZSx0u7ZYc0AJdRbYWi0mSq7nj9HL
# DATA ljDUyNN4BsucPWu0q/T9BCoInfEswSQmvQd5tm2XO9/NzDuSHWfbhiP4Si1n8E4HoGR0sGdcCLjE+Rq8+XQS60TMxkzL5uiI4LPG
# DATA N2TgiADmK76De2ka43ziACCY8B2ovtOEQK4msScJ5CpxsAswqzOF3rtIY/SPAzPWN/Dh0IbeENKei5/Cm8GP2iOZm3pDAfhcjYkx
# DATA LYJICrc8lZknwUopI3c3DHiSyOqLB20G0XQ6hA5nJRKz6QNQ+QhBZujzUIIs0IFvssNBkOkCrDNAJFI3KlcycfloMOjIcGduT1lW
# DATA 2/W4USRchYS4WOjo/65ho8U0Q2GjrNxuIT30OmApHjzoQ4bGfmuYHw3GofHbxnxO7w96k2M5bow71fhkCCqmdK/bb6O5jDpds9ML
# DATA gqGf1qmWuENjoe2FQteJ35pPQSJ8IV1c4nra1lz2ox1wsRzSZM0jUVsjR39MXbYRDYP3rol+kDoNbxFGY3ZyZnFpjSb6VTXlfkdi
# DATA uIL0K7OOLMEkpV9yDDYnlPRTgqDEl3LU6XVaeYfzUteW5jpeeuCyrycXVgJNo75b9xXhjrr72iFU7eHB/Q6ljVSETYp77oLvBjo7
# DATA 88z3pyZyDX/q6DVuMyvulcSbUYSZji3jD53oMlf3BZ+9kpRWyllyLildSCp88VPPs2Ci0ZZSsoMr58Zw+mGbwRBS9nQpm8FoxxTx
# DATA kwk8jZZcVyUH23ncOkREUq6jOrLAnWupJ9wKhjJ4NFEyK/V5LQRS5sqCrhpqmL+OS4WIqWkJrc9c1yuqrkxVUSndDx5nb+CLN2qt
# DATA 4/bFC++1RscXL6iHeE4ceqBMZnYEeVSD5Bt9UdnCWg1e+us/GRIQcclU7ia/Nc/t1H+l9PBof1TtDkweqWXy6tK/QlrjY6PJAOrG
# DATA m1OLU7ppM1BEqaj7BBvzkTCQuLgYutuhC9uS5zNzajzOtA8a/lEZjgYPT7yfFbrUj2wHNcu9LXR1Mx5u5PQ2DajRoIkt7FUDDhYY
# DATA jbqYI0bcAcfybHcwZbDuqOsGGr5dxNZZ/h3B+AgqBCzFRlJidbnozYWMtBQFr/Bf1yxmF4v0IdaxcrS30ZJeU3BOKYnG6aXTt6m9
# DATA aewrNY0YMnTAH3QHpcwuPIm8TVo5OOj5J2DuQxqQpGRip/k3H08W0EFeL2VOjummBUcbnrRuvXamjqZJ3138nW5fjmqD/qElbqsD
# DATA jCRixF6rkQBl5Cyh3LMd4LUSQfdEz7NR5OqeRN7ZUxiHbOAjYXSPwTGMX//DiqFXniU/Y5W1RamKwCvcQRWGvUjlQjuUTWG+H6A/
# DATA dhHX7bq0Acy6OgUTE/tQl0q1YGK4+bDb74M9OkpSzNrNtDqMnQ/4BU6ugkFynNduDL9BetZYZLT6zWJxsfYa+7HwqmBhPDx8JmDH
# DATA 9ptCaOVScWyv7R4iTzM5AnkY6rpCmOFBxU6vu/NP9NyEPtDY7SN+GmrxsOVaxGF9IYIpbDWLUNHZKWn2lqH++VFWC1LOAfmyEb92
# DATA MiZaGs02eIL3IhnxOCug72prPGjpQyp8Pe6Xy9KSLUWosVbJHaEqepzciQOPex2J9Tbz3UMj9ZmykZCmRChDIsQ96ognMPOW1CfM
# DATA U6aCmjsrm0Qa6ixnCavGXZ+GQukC8RULkWusA87Enokuvb5g73u4je01GIwOMVGJoa8q3cJcUJfZpK7r7kYu6vIyC93e/S1ypu1B
# DATA IZ9lg1Z2pAioX2Y3ebmUA/NzJqYUDqMcSCGhMJU66CiUEYdBUJ6gS+UjJfeREsIVEEvhoMqBZBMKa257rncCxux/hi2iLFUU9Uoz
# DATA 5NGF9jSYp1HhfwOcLqnB93mV56/zWMIgqVGrq1bkDjX7Q2oVsZTZ9dXFk7F9tCWbPWRt+2dyNK7FXV0f4Xc0BerDMjsnoXFJ3hKl
# DATA eO4GAmFsG4C1l5FvY9EITHq6ysZQE1NJzbTGxIwjy1+7aQQWy3yrdcHAVO0qpYumpBI6jxy867PB+xZiyrckbDKuNY2iFrAHPMEW
# DATA fAOoBKnnwHEm9AXqXIDlEfWz0HhBvV7Jc+8JvBzmwuqDe04Qw/r8VxDJJsnkDcYsvbFQmIzBh4mtCE3BcyypnQmT1DalY3KXb9JP
# DATA E1EYAaaBQL0lUo6S2pG5YJKr82rvJOm0Rr0uyljMi3M6ozuttlXdANEeh+oO3xozgmNXVd497qivjkE6zo9a7cEDF2+2GsIsuH6j
# DATA y/+ZXqPLc3xGdZ//p3QZXYDm9ADYadQsguczuhzzGHVhSW1oEnYhdXdDVQKE3bpqEdhdF94g5qZVC6AbzLXC3kjskzzoqztYz8/w
# DATA ECMNR1sgH7r9MfUV94iWP6w/IQaMKN5wUHuQSuS0YuU6kLgUzZQhHoUDcv9D+wlaQdVfOrnafk3PzkYVenwvjPTCDD1i6HYFhkhi
# DATA KMt3cQbAgxyIrlNs8BTOkBBJyC5qPzaFTQWxWr9N4Ag+3uEQFAZYDCDmagZoKK4bUhTViUjnSwsTpxg+ZQYQhBsB+MQdgC/71aLw
# DATA EI54F/WEQA49s4SHJ2Jd2M0NLmwqlujNbyxaxmuuZHZakVLagq2gmmKysumrn/g5htGkPaPO4c4TjKYXyh8yI3eI51EuTnwzWNpl
# DATA BP+ivHHq/PtUPf2TxM99STKYB6SJjwxSrpP0w/cY7rc7D8taEuygabClEarnwubEsuG8nlw6Bzlw8D8zHMMNbBS6fD99/gvJAfsH
# DATA Gqt64KavRRccMN5EUHIkd0bN7WU5kXQUtSRMmcEZ6mASoOQxWVRWBhdXVqaFA/dQO1SfRCWKKN7elNig3uWEvCnqgQN+FvEjjubU
# DATA KEt6quJUE3bECy651m+ommynCSHT+a4pB+x6whVOZ7lS2JJoU84lA0hH55KVCRTx05W4W3dSZczleeLAFTNroBelZQmoGaZgGSlq
# DATA MUc+sJfq+Dn+i0jBiRYr8KY0svyGZsnqdgbSfJ4Ar0kgvdeJ3EoJjbw1AmUj5kwlNHes1KoLZr+abGACMRAW1Gc5gr6jJ1ivzZDW
# DATA QwDswEZYokCP7nE1DrMeylvzvNvtvRCXQxlB+2u5cfm3LV9WFcT/LCgRQv0v7p+vZamvzT8p7vVvhRhz+q8N/EdRm5M23Ul8Ze+w
# DATA eLXuvrMYASjF5B7eH3sgQpbYYsMUoEaDYAzcYZFKq93N8fZbsrDtLd2mZiiMaS/SLhCzjWav7QVx84IV0xWxIbA8Od+EoFX+nhvo
# DATA mSwPmidRo6xc4TLBEf8vYYZwhDj1vNA5VIznHz3yHUhtLwxKnYofmsT2RfLyr7TWBbvahL1U4h98AgxG9wi02lUWLm4+qXIVoOEz
# DATA CE5RjSCXdNSBugPcg3Q5LfDlt7LeJzhzBKv0tDDJV6HEVKmYY64AARUeNLSZmx+wXLrgvNBh0KQz04e2KvsNw9YqyWQsJ0NrCv1M
# DATA 48h9HZUlPbaAqClwJfMVfbOTlTtTjNC8Dtjsk8RSAc6f4ogqhXA14pC8i+Vy5vEWwGXIVtSvbXTcuE5JFEHhYO2qIeWEqetyIJ/b
# DATA 0MZw6Xwf9/MvrcAZTgDhaUNRN+n0mFpovrPx48g2+H/iDT8hVTPktqUm1TXSrsfRDJwiVNBxi2EBbDHI4tqBHMiUSf7JxENrwlY8
# DATA mADPTZkxbx1XgFqine7MZZDckunv3XSzrYQwt2Ln/l1TW4bqaKDUPx61LKSA3cZ0RvbrmnvGw82+uzUYUdjNUP1hAJjQ/X3r1m2E
# DATA iF5T/0tdP1esgE9C1YV+rvbZsXaWih+J7MjquEiVXXADQhhJU+2JGAUoscXNr3R+Mij7mU5By9+E0VGK/U08JPYwXmohSMNC8HRm
# DATA Rql36SBxWPswxqCuYt4wfC0G70P4eVraX2wms/kTV3OZXxYH+UJ/DNcPY1oMzDYTjq0UY6cE7xWQGzwOxOXSDAfQ7EWBtzxeHAEx
# DATA DHsX+2IWqmHgrvSiSJVRHLRvCKfyP8v/90VhR3WmFlfADXNukz72M/Aw0GbC3zz7XTlhjLWo2tOBd/oGoAPZdxk3uuu0VYS/Z65c
# DATA A+1ZWbC/Slj7gnh9lgu4dl2vOOXNY+tL666qvtf8DpH+XC44G9LPLbtUQBEirRP0nmmx9gJ7bi5u6Rl2efyMJzTvmQRt3FNmiKSO
# DATA vmE0GCt5h9wT1V6qSRW76gfFJas/yLJqCWB4j+AX/MG0uO5dS+ZAVgh3bpBJ+NNiuSSLqWlC2OrInohiYM4NUN5FE3fVioKpp8Dh
# DATA wBemDuoCM6aCko1ogzYwU6R20FrphcAbGZnaD3DjjomXxjvdOMMAxUwHCycDIu8LXueyccbQ/ZFDWFacBR5VcUw/hVZa/vKMc396
# DATA 7px6VE7OndM1TMPM6WVnOzpAWerrkurrsIfu/EfqpCDJAv5qAr25EmluhFEpCybgAeyskjwRI2eeP6C84gSyl1cJouyo87B0fi1b
# DATA 0rkPULyKwfJ5XygS37q1vfPW7Y3t5tb69va7t25fQwU/NeQFSViF72xv3MZYCetQ1C+vXXFf+bV4GIIH1nFaW16WH7VT6cb0bwyT
# DATA bu/VXr1wfm25uPY3b9+6udPcuHmtee3WjfVNiNJPj8bjYa7qBlIzK5Jurd/cuG6K6Td+ldt3rjS37ly5vnnVFHYEqcmol5ecVTUr
# DATA D1tr91INLlNvv7t5TfVs/cr1DdW7jTfX71yHpVFSxqQTDuTGxs7tzatmrlvt4y76ksgLWLHoyq5dyILa3t248vatW+8wQTTf3li/
# DATA htVG6YIV8mqjQoAiE7OWlN0tSgQXCsnD1njcGfUxzu7vYOJHnSqiUHdg52cYHFevnvtu6sptkh6SPy9jL8DoWL3hsVHuHnwy2TPl
# DATA OX9fs5YEDEYqO+i1DvM6Vjkjfy3W/0odcVRVDSG7egVf2cwBPmFmgEAPwAtogjGwc68jDnj0Qy7F/MqNc8T8R4Ly6qdEgt8vp3dH
# DATA d/sA7/rymdz6EJdU6zUugxcPZ4Ni3ac5YTmJlI28Dnjs8AeZEllyc0w3w9YJGK7V4MDaUIW/wXiVdy5eqO5dvMDGNJkWgX2igCLH
# DATA UTqS/I3rxpP2Xuai5PC73XssMLAjVutqZzTe6hzDzvnpg/HWZE/x7XcYkV71xHoNP9Ub+OUD5pLX6w9h3cnZ1bEtlMyLcrJzMqQ/
# DATA g1WxJ/YT0OyxnyNiFEuKxUeYQIA0fwZA7hEgxgAy7AfoUPzhs6eokyb1LCI1PY3nNWXKPHhZCzb1U6K36d2+6VA9PWXgVkXTLzMN
# DATA P2h1x4RYggy0JCFq3ePOYDKur62YkGIrUgBj3RU7uIHoIxRCqFav3eopSTKNAouEJx/rj6Cua/hEMB7cnWMVgyZJ18Q+PWpduwdw
# DATA RHdmJOzC0HpVMl8Go9r+kWqpOlTrr5VcppYAUAKIbiX5gVPGM9X/oJ6snl9deW0tukH/gE4F4EXwCO5+bqKb6Eo/St7e2dnarhgY
# DATA HR3w1ueU93ZvjBGYdVmd1gGzTEnCW4H/Xdl4a/NmcnXj9s7mm5tX13c28Gn13Bv4rzpLg3eplVtbVbftMC9oJhjw78PhBIPhK6ul
# DATA LRd97sOh3A+8LOF53qtubdxowrCb44E6Vm/j3yXohDp6s6wqycLNROHBAV9Sku8mo1w0+WVpv4VWNLghWNOZOTVUGX4HD5PkParv
# DATA hxu3N9/8cfNHr658Xx3PasrWrzevvq0kBudLdY53jyfHVipe+Hbn+ja708Of91eba+wp3mormgMiho1XPR6oKQbftxKcobwXyeR0
# DATA BKaUoNAPdBUWlkqArNYdHyU5aNfGMimqt30wsasbQildXXutuqL+bzXVJ5lhBGo8pTUIS39Yqq6WdXMVvyuQKLeVK176IJIWHDog
# DATA E/Rg1Bo2qTclVZrUcp1RU/hEXQtXUJ9iXJNRkaCvSNKnGCoOzGrY6YyQWPbULX2k1nIwOuaDSFMNMDAhv1rhtcqA3BPG4vvgH+eg
# DATA XYF9EaJB/knSk9jAlWrBK7ThEb7+gzQruLVQ1/MOsNNe6SB9a2NHsTDYR8ur1VUQCN5WU1NLTmWGpvDsql5KdbPugbsASA7q/0P+
# DATA NjyOs6xo9tZWVoCNdVH3Q80r9nm/9Orqmujpst3VBtDZhZWV4hmy2L19ct7a5mPTPkI3wWHIP0PlCmSIGMgr73U6w1KVbz+0DC5b
# DATA sRMZ8xq8jxjTf04s9MsvKCnm848vi1KNQnc+ljzLuKblKFvGxOn/QUllwFaKwl+FVI1izcdfnAevZO4geRd8C9SxZZvs514EUYZR
# DATA b9MUz16pQ4dd4+X9IKUEBAAHlKzg7l1Rlyo8NuWLbAqs5/LdvlV0t1ZrFJZzxN2DNE1pZyanp0tWFZN+92Ft+X5rtKz23bJWYi+P
# DATA Jv1lnIgqbG6oMkGVaxPu2oP9Qe/y0ikNbiqXdLXrcSoMQV8mK0nea9pHfKS1cc871aNfNkGwL/h6OOreV6/db6WveYJsurrG/56n
# DATA IiAqrSWD/uUlawh4u8qTwcHBZbaBqGNyeZKPlhVTGnVoUpaPxsc9et+ajAfoNWc+6cB2aCLQ5IWVC8my+k/V+qDdVpe3VlstxY8q
# DATA V+lkroAkWrlFF1JFk3m/e6Ck6t6D1kkefHUbAFNGnVFla6Cm/wQk6+7+mD35Kg+OOv3K/miQ5/zEqaY3IEVI8nf/kCw/hAkAb5ll
# DATA IQo8+npdCNZTR0Rzb9A+Ielo5bJ+fzga7jdJXKFDJTm/spJ774HtzXoP3AH/Ulf9WSSIXUQSpAqmU3cYahR371ZLb7z0oNPrVRDX
# DATA YTlTo1EnW/8E/JwvB5/AYOFUJa+E5LuTURf/s5zU1UJhefX/1H5hdnAw6uRHpZg7T1lbf8WeqU+9VB++9VQNfyUt0/apa/sGCuvE
# DATA M7C0r2kqsIZ6j5EfqRZWsQXUavU74yYqICggjlsyT+HQ5IfINNBTUzGH3gEE4fRS+x1Vf+HCeXna7e8NJmpp6cUleGODFdl1iuKv
# DATA 5NRtXzDid2HA8HzM5n0WtN8nJ/dnnyeuAIrX4jRbmqcCd/tVd685OueltSJBxygvAh5BFOH2sQ6miEjGJizuE4xbZQDRr6W7pmta
# DATA f7iLJ0AsQo71Ff6SRhYzDEeCUDpqgmLpzhelUEEJ6pfJ+tZm2VkfwKhmd5JHyY9GrRNzlf6CI+gkpwqc5pZPSPfAp+UI2E0BtPtv
# DATA MdAJ4g1vqvvy+rUb6rrkJqT7hOWHjwAPG+70H9rxVJ/QSpsohhjau3YRCwJMA1zcIq+zYr1Sb3B4SP5op2lbHWvoFpKChqbCaXTT
# DATA wVA8QE5TxagrwKOh0PkV1I7AIyyqHr2aMgOEuNuBAP4ggBS8nvQVE8wr+XgA6VrgY24eAvDpr0BBqSP0T13Dt/YyZrts23aomQbV
# DATA THrd4+6Y6ukPuL+naT44gJ6trly49OprF1WH1LHbNg+m0+liflKt4VCSl9HQmUtL0hpJ2keurGZJJVVy1ijHJGRYrry+e2DuWTXR
# DATA 0tSQ08c/Y1DG+i7boCt0Z6JzD046Y5om39a8tqxWeVmNYpkfFNTc7oCBMW8O+nXbdNrew9lUYmwbbUcIrsRYDEqQ6I2PTtKpY1Ul
# DATA k/j8j6bRbtBrxEZU/RgrCgMfpPTqjWuV7bc3rmN+rH3IflU5yLdR9FJHPxzKPTg0YepWl6kO9DzHJItqTqAHqytotWBxAok6J4Ow
# DATA knzQ1+kiHSyjcXOorvqDNu2F3DYPhzwlMNqCCnKo3lFOmd1UM5C0EUuxFCEtbR+prV6qXkxfmMjoCnl0jMJXPVUXuOM9qk0sYGqO
# DATA d34Cw7yzcxXW0dCX9NCIVJYPxIzmFlnA4WGzm4Psd5JU7iTf/e6pY2aaJpW28/DalWmwmOfnreXaytQO21A0WTDXtGN449S+X2n1
# DATA ht0+sMdF91rRZEA76ryxvserAXSzUsnVVsFcb/iLrPsAMk9aaXqq+O9x51itc2WIIjq966hthJsKy4DUS/2C317X+B8UfP3iisKR
# DATA yb/22mv0CjgS/LVSOKDipTVOMRUl92N9+QL9gfykX3FlLd85i22pUmpKHbaEjMxKjBQyLPzXCVIKRedacSJfEvmKrYLFX+JNXvTb
# DATA /ovAQyPyaV3EAPAmCV6DM8yllXKipOxpoS8SC2Czc3bZJoyY3EW57ER1QlYKR2Z6SmJuGnVhyXdt35zA1a0R37/hGoXUS5JGnWDg
# DATA 1be7Insg7RU63UVxBCPH1gzubH8vnBqkuQOKfnHex/ZdTEwIVhgkhtXoto0f6i92OM/e/QTnqPZ9aNdmOe2gA/FLL/ORbcYDfV9G
# DATA BtBv9fjsfjmrjo/U5WFUf519tyBWcFwaVQf33liprWZZdR/DoUqZV0K9KuJfDpd5dR6XWV2LCANrrjDAJ4RArEHUk4cKoZOyGQZp
# DATA uLUWyNzISLjgUyQY3vFrBXuF3hbsCnpbWzOnmXvov3Xr2saVO2/BmI4nvXEX1Dfj/WF9BYQAJrr00krtEigE4OZeo9u7/Lk8aQ9n
# DATA SQFxoTXYHlehlxTWAMb12rKikWXs+rJ+VRsNdArxCsxnbRn+a56RirW27Cad8RqX6LNTqyIMU/Oq8UPXtL/4KUX5G1f9xA53kz9h
# DATA mRk3vSZNTy0V+HjUwqu2Xr3IgpMyd9cIi+xTbm3gCNKFUwh348JXGCXKgjciq3DgwHpxkZNF37oj9mqtjrmI8xjLM4hDyQ1CFlGt
# DATA XlpOgm/UXTN3PhocLueTIawOun/GuhwybbAaL8M8iOAV6wZzvIKv9wejjvYrjn2OmMpOqUZcqkFFEqxhjI4abjxPRPOExwDZFKz3
# DATA WXhpEbptiK9pMDI0mxcvybiXw14tOtstE0kR08K3tdXq2iXDt2LEuXQ2LkMGCNjfNpshDTw8rbaX2R6MhZDhzOZsLzg1Z611/g44
# DATA Y4UPHjyQCmOmCOijxz4tlmUv4Ivyx+nXEUFl1GTzY6iCIKqQPCJ4OyCleWFW8Muv2g+jwqiYSAwVTSJLSezdUrO3q18xqhh0QW0d
# DATA LFBWETNN2TP+4QnNxcOTsLsUm1VLRJ+bYkYQq6eI46EzQS2oImMvG1suvTMC6doPP5npNXmmi5cdUH4aJkiuJWSecN/Q2APxedYm
# DATA KkgWTHQIiYKr8J8LpSybZmEPfaAb4awz7zkxGCtnvLa7Vd3V8pNGXhyj6qQTdnT2GRXZJJ29V8rR5GcxJ2g7SA+IQvEPJ1hEsGMw
# DATA HV4ZLGeDB74pie01g14buPsDL2iAM4s4AmsJq8tsf1QQr1UNTogWqhbslAbgDw274m/f3Wk6Dssp5ve6tkl/oZeu7WcLf4v7LMAq
# DATA mya9fOiqHKXykV+BL3I55kwMD01Qg/rlxCC4kTJhbJEaNkVJvFSH+SPXyM5JVni3/+86J+jTZ3/mKCJMtI3BtJBmOxI09PzXBFQA
# DATA NVNkoyINwvohf9t9tQkUnXTapd3SMTkCgvkZQiD45zYl/TEPrqlLY7ePu8F6evvdlAOzMRsUxwjewOY4KWsmFNOkXiDhNHWP6A9D
# DATA OvzbohrwM1J3eohCk8xFsIPR6jLIq0xr3B9I/Hb1zvZO8/atW7giqELXJ6/qrZVFapniblXlCDuM2i6DzCGvBGTWQg/D/rBx04yM
# DATA LVT0FuI89TjN8ppnnNmmxB9Q9d9Jbkm2yvHRqNMxGIkVSGOEKaDwAOYWj1snyV4HXAM67WqygXAqEsfEFWJJwGAbtva6ve74hC6J
# DATA ZXFRRnsjCWqKVaAeDPgsgjqMB8wpurlAKxqoBFqjrxoVGsVPkKmWxqCPEUYzM1gcaBKGDiuBR6OZ+izYl7qktZpSAUTbgLURac88
# DATA Pd8QPF44ryJxVX6Ynt0U5INh+omnFluwPsrNJTZIqnrVEwNHnV6L4dCouNkBVXnXHA9oQ0mEu427AIe6/2E3by70bZg4WQcPcK9g
# DATA bcHYLA+qlBwJpJU1fPlCad3c2sC1lOtyHq9i8o/4CuzKQjXCtQh3Mf7SdGtRETH6gA/E2DuCL3xMxujPUYkbMvZI3k11Xafte4P1
# DATA eCAZXFHECjhL8Ptqa7jebvNf10aDIRYade8rsRpMtA3nJPbOfRNBiI4cYV0+CnpraB80EkZYS07RQbc1zJQspC71SHx2aq+r6+rA
# DATA 57DvFmJ0lLwgfnCWDBiNjlZVZ40bTwiLAL2hA4f7Bf+YwwZ/WUdNJOZTRsx8Uiqq6+qT95RkYRQm08U5gd0ETmVxG5Uzt6Ezc86d
# DATA O0WhFicvLhh1/gjlE1NBTQOKg19lfJfBTRLrTQuuyTW8SoOyl2/MaUSVA1FjlsonWjBU2iAGnvW7vDSV4EBIumqyv8aQLPzkr4s7
# DATA hAgwuLx3ccFNNX49s1DBXVygaKzCXIxw3z+JtZKlM0JpZIvjR9loGMUgpHPHS5mKLYgMjQJDnjwQsfP854xHz3yUHsIMfPn81w5r
# DATA RW/PemKrGUpp/MwB8rYvktWjzkMng+/pTFyXOdoR6Ag/hz8zO6elILsc6JxNZc2kC3KVBjF/iFdGohydda7M5C27LdObLFIYVg5v
# DATA IpcEK42qdbMrKA3mdNRuLaeuH5r0MoRpUMsEQQxSoAzXnTqfO9hKDeUKOsadxiDORK4vnNCh8AL2L+6uCajGojayuXLMHqYfj/mV
# DATA qVcfutc0zrw6G+RBS3rkjYyrHcA/Wvl7CeXlqyaFpR9OUlj6w1KZuPlVTcW6IiFQU4dV9dRNmKnqUjx4vwfOwTclD+tOa7TZPxgA
# DATA DCuiP/Jv4byQ1hCVHx0ldXXGLbAPlcDjtJxA3BRkL7CCaQZjxO1WHWmNVTe4hOpdU+9xXQuBiqpZWQHahCqr4I7jqLvkISC2A87r
# DATA uTUkfGxGPbqYnJPnsQMUxshXOu5JIo1j1EWnneNtMG8ddBL0lrOU9PxFtbDnEIYEHVkyEwUW1+ZQ7ZuiCcIBhfMpBf1sgmihUazP
# DATA VKxLeo0e9ieQCvubaVgqL2o8VwI/pBopaJtDPrEQ48gREOkY2hmirgSv9Ga5jruHI+Z0LDWgqnh/bKeN55ZKlDvIZM6B1WnictbX
# DATA NIGcLxNyA79YXVH/4z6+/PLLV2BiEgoAIFVDb3CIoPFILJzRBFAwEem0r+7uQDjouw5Al/eh06obnaqqbCnM0W1zIdkk+3gY1JOV
# DATA JR31JXsQMhiV4K/B3k/rMjwy9Izeo7zaXbVH6/4mxiAwnhbvtt5BPxi4cvivicdBX16pJ6tekBFl5qULMFZBYKl0xQsxUiaYMMea
# DATA aNiu4ddKKGvtKbFtMu6QZJZWqylhxY7GedFxcaePG7Uf7moEk9XYHNiNNIueadSLbk4yobim68eMZKgnTD1i4s5m9EoTcT/GcKCe
# DATA sDdcP8XGJitWk8zvDBWrCwrSTFEPLDYXcDW9kRL0YXa70TbHNjAzEid+Ouj2McnAOdIVxKbR+tBXVjClL9BXmSGCQlAcQJFa25Zx
# DATA CqaMFy+KGGxNYTz+TtZMh9EaUVSi9V1OxL2MhCHak3B8D/qEO3Rl8NrKCgSLAJJOzuEgCOjdHNyzkoXOvcQSn1B70hpU0fJVqbmv
# DATA 0g84bo8m426v2u7m95qTHFK48WpWD0Bd+gOHQl9JLl4oOn7NTG+q3XFw0N2HmCfA8b2HTFaJWcfIlvwNbfP9qCpOTmU+DnC/Uq/C
# DATA 0dA3QZLVuQQpEeTqy2O1/8EX0638OwCh3JvkWBhChGEDMUq2ouEJmbZk71tI2XKAkNkqFnYMXS47K4tnQfpwL0XmPpiMh5NILjL7
# DATA i/0jRQAlXH9rT2h0+NXVVdIcIvh8SIykp6a7SxHpmSBrXTq+3/Z6EN5oKUdb7RIESevPysnFV189f7E46hb4DdYyL+Q4spIP1IyN
# DATA R5M+rEa7IJKYZrTKQPjQULycmZYKJb4qKMv1HSj6OIpAhg/y6kF+0t8vSTk1if1BybUq4gmmrYnDk5jUY6lLhGwc3qv+JvcEUhSg
# DATA W9gwtdQs6O6AkNu0UeB+WEVXRXZjYP9BMlaLM+EW0iNUDpaiNgS92283tzbweWc08p+z9NM9xrAcsMC0QIta3YEnpVXwxJXi97q9
# DATA nlW82m51KLYG2Jb1HK++AkACUaGqiNaHO5H9QZj/DHlSekHDKwdXSB9GHfYlkOBk5HEZ6RK/XPLA2PRQS3bCH7vtKoaoW6/b3dZh
# DATA f6C2+j4si1VYNUWba/Xi+UsX/EQNZepKrsTHjroF7ruJp5xK/Ba1H4uUAyiUkgV8YhztiFeCr93VwaTXZthoJWKhqAzMAmU8ewwI
# DATA Gch82nlj3wJpGv38jCi3UZMxgJqrduIyzsp4tdXHS4c6dHonuLGss+eyyatmtogkhWiD8hyTKkBN4W1JEzrgxPY6itts0QPeKeIm
# DATA AL4o1igFoFs12rOJFYl7H3B+bNogl0hsZjgAqomfbQWUZb8K1pBYTd5vDfOjgb0pSqA0UP2f9O3trH6WiTFhoXoBj7JDV8eeKiOK
# DATA fvOdZD3hUDkhi+PWPXVfpAMTYvTAtNoj0Q2hKrodoqKfTZS4BFlDOt0hWIu5vv3BUQcRGGVs1eS2mjvwME7udTrD3M2oZ1aeEmYo
# DATA NjyYABpmVRKma/QVNQclm7nyO4gT5oGKcrIB+RvQPZyEMCXuqhF3mnQC8ENA+5A/vc1lOuUASenOMLPIrCRunn5xs03wQ0HPEjsv
# DATA M1t8YaptDfTtSb+PMlAktRCltfsE1HP0J4JHYGqdmDbvS0ctzvnQbFR0TCdEOr+PioJBaRAzkoOyktkqjNrehlaNw88Awwgfshht
# DATA vBhespXVjHT0YjZTqN4z9Zwt8ag3x49m6UstdXvkTqBvAZbvBaZogqRH3X7hTnXlDABUxYRBrItUVI5TTg9ZHdlw3ddoT880zhvN
# DATA Nkw+K2QLrMhUX6Mol2N8Vv+C+N4fLzB9Ro8TTKKdRlpNU5uB0y2m6eyzQEZztfBQQ5X4IBzbNe+2cY2YTG6uzP02Zf1UNyq4UEy6
# DATA kBdJ8cGktZcDt+t1DlsIXSFohaYyQ854oJFotQxRb3CYqj/xlsYiS15NbkIeoSR/gKZr5JY9BBis+vetGae+NkPhQEnSwJgshx6c
# DATA 14U2g3+lzCaf0L4go75tg3oaXVxJYkY4f39hyIMvJLVHNH8KQiVQVoXfaPytYg2en/doV/SR55iGRoe9wV4pPZdmHsWCLo8zcVZ7
# DATA hJsWS5cUhV3T2Xa1ldNNv5vNmki2qgjgHuSwfASg2AQLAUkt/6Jh2MD29zic16exTTNDpai1GjBojQ5njZBVcHRDLdIwovrWNgVY
# DATA it7CAf++kCSEIh4//+XzXwgqVRSTDmgMiQJ9A12G7E0ADsi7iweLJbMw83a+T+m0+wDIVorx2BncGwGaHTaNXhHzzPeZDYONEz8i
# DATA sbuEf0k4h59W0fPM1XlEI984e4ZkOrhLwcZhdEULSRGUK93BJE8z5/GIsiKfBDuKUMwIW19qtg3o9D6uI6Z3C3qaMFwa7vk6/+Iu
# DATA Q+JAtLy6SjsEU/PKEh5bpDR3yZM4tGhx8cIULxRQ5eyN7p2EmPpC+B5ifBHkCmXEUOz1c3KSspPNCyCL2j2fwKOwq85kAJFBLAVi
# DATA ECyrV8sPR60Tzgwhi0LDPyZ8TPhkb9Jv9wDZYmFHH7vRl+ZTNiIf04wVTthvvVE/kTFTal+WVp9K5gHKA2wfQpCXQE0gZwN2xDjM
# DATA COwl3vKTR/uJu7CqJzqrAaLUcvZZv4Nx+pENyJRisVm1KewMkW45kn5nTlXkNLZB4+zTWObGSl7/B8qzC2hxHuSnobEl7feXUy5A
# DATA WGQIhbHSFq4nqG5TYhgKHOpa3LX1zuB4lwwHD+BaN8hzSJmMOeVaI7I69DsPrMroDmC5ECWIlJsfoUTz4AiSLshtUiyDrf5JwqoV
# DATA 8KGtWgobqqVLSEIWthVItko2wPPbkRtQaDeyQnBsWC4c9mfsc2416DhtINQQOW3gn+wJCqoJAN9k1OGab2DAEAxUYqnpR9Ufp//L
# DATA q7eat6/dunn9x8l79EsEc/3g5q03b12/futdlyTHMd6qtaKmSferQEdifUkqK/tLBu0FlW5TXeTV5VgQezmfUS24KH4lZ3e2h+tk
# DATA 5cUou943xy1O8pHeloqT/+/936GcIUnP7HwliZ12XjAIJSIVNbUdER7pWNU5fIpdwKqEQlXy/LtFnPBTOjQZJGnXB4YmVCy6FFpH
# DATA YOaliIDXZYxyZCEPHvhMi6h1KZaNUyaX8LgKMQfyaqtNoZq0QcwmsizP2L6TZN5KkQu5jdwE9BTfa7hnbam41diXjD+lroTIDGjx
# DATA FWVhAsfPcbXRh+75h5ILE+nHzRn77H/MyEtocmjaWXW9cDeMzsErpaS1gsxB53bTBL8OGJLdDYkXbDRitQLqqz6c/kR+j5CT531B
# DATA bEO/rNmNERvTE5o1nDSE+rmZe5rPV8DUkdiBDHBdQcHcpBL6PPETQj97ctmDncODCNZLLoFe8kFOOFRlI4nVOswAfog7+AMc9y8B
# DATA u8062aqJYN3hKalKfY5Jx94nfY5gijwqSHqoGHieVHqtMEcCOW7+RRX8A4HS6zyJVcziodN/f+BkEMRQJwQgYYf4x0hOlJ9Q3O2e
# DATA Pa2GDaZEi3YycP4Gk4FzpTC1SKGGMlmlo1EewgwNz/5vgyCrLmeuNy2mQVRVhhVSjHtYG3TyCZGl75mriDOsZ9Q5VLcZuB7EB027
# DATA FapQV8dast+Objr1MCHtsGSPSoYYMYCmROb1sLUmuaSyxEDS+MZvRCITDEhEOQKoonE0KpI9pDp+ONYZvijsuywR2mUKqi7zLJb5
# DATA rgZ/QGy0G8XgMjdy6YmnLMfdYedoQqNjZL6knky7lg1J6GJ5g23y85LElwr1JCaXeTwVuONGi4zZV51IPuPfQ+Jiyg9IAjhu8Dc3
# DATA r29swwwHwq6V1zjMv+5hQdtpo2XIBuhYzYZ7rOhGYZ0Awxqcd0o46Rkn5eCzDBF0Z585z39ZBq7zc5Og+amdjjXOyNPUUKahYSRP
# DATA ioYWCBzH4LNPuXuCDQfu4KYWNQBfV4CxTfC1dYURY6B5oRffMwxiM50RamtRL0GfeFcmnKpXJFGv9IRW0VThiHVFkdJqr6OP8/uI
# DATA G2XLboYoUJgpqDdzFzkragePUznLEzeNlAYrNW3oIAJznlM4acOXw+b3rlgmCicUpuPfXCqCI23hmWB8FU/Lhgnp/MHZ7PBGgVMR
# DATA cpDDzrwe/56OZ6T5f4zAf9VYkDnsLEQTs+nCwhnzJiZoYFHi8AkkaCJCK9SYJ/GZnc472Ihrwdm5HMTvq6O5ypda3tXZbu38mnuy
# DATA zN3DgRaI1z+6nXmBiSImfQn3bafzKrUIIBjHGZZ7EXqPLytReqzOhba6GXXhJreGaEFuLaPsastwfyENln9WfMT4w++jdgqHluBH
# DATA TyQz/LOnocworfwgrPH1ZbJZMdxU5dwyi9FApyBIe7JlNBv9s6dl0EZp3R19BfmArGzuT6JaubCzIAjxfPzHAvIooaQx9cslfpbg
# DATA mZZ1hLye9kecNgFEDC75Zx1V5SAlh2Lu760LxxO+wTxWfcNs4wkMHDv0KV8h8CZiZokvhGKilyzi2ubjae+UmCChtM9/LnchNq2j
# DATA 2lDLKVY6LJZhhFfEpRckTCO9kCoHYZp416I/9gh9QQ/x7+r66HACTW3hG60JUju23mwqGbzZzKwv4YrebPEnpXQw7IwkTGr/aAB6
# DATA kTpj+mCupxRDyXI0NHAiXErBjbAyIONUWNzGb+y/dU5djBNIGcmnNRLUO0z3BX8fEu4d8a8UMZnzowrtFiyLCXasBw5XAvSY4CGj
# DATA bgbPuX/oj1KZDNXJSHHNgDjVHQvYD/UmH4Pi3HokqH0VxjTAKei1+pbfAzbI2lHvsThT2V4SI3bG0TXRjEJDFe6APVkFr7nz8Zcy
# DATA DnrrTAYmo9DLZVAc8B6EekNxYIiSTqXCNrXsclEBNtEVFxC3oZnNmIugTaOegF3chjldZrYiiFEzOksJfQvf01IXv2dSIvD0mX3B
# DATA jMkzahqxUxJEZo4O8zpoymeOTdHWrI5R4luzGoUlLQWTXv1ZDZudwrGC9XROT5FM1WcVSXPZQlNZPUUybmKKzNlNIh7Z4KvXAeBI
# DATA lWMCPjBkV5RuomEN0ZRZsBUGWdYVYOaLyzO/Y1Cm4FPKmjGrWeKN7pIUtuVXjyD0s5lChDkvuPjOp7TbFuulK6YGXV5dmbv18aQy
# DATA q6zzxKN+hfGodY30dv7anmmmATO8+C2niONG2budy+I/UDo3MADwq6oPd50DhA91I5X4qR3xJoEfIzfLBHYsXiWfEjVXgyNGJ7+u
# DATA cmI9oRDd2dX751LNi0qWm49dow+WiY5KQQiz37VdB9bP0gR0+q29HqpMIAvpYjgjiGZiIDUUFa1fv+7ijzhmJckLgBcUVNk5r4cG
# DATA TgV9nnUUgL3UAEQGU0b9NWlnuP9RtGAnhNvphEakM6MoSC8Pn7UBYASTGsDoZo2yTQgxHOe/2GyCwTuWK8EoDK3l1yZONxJBL6Iz
# DATA d6zSPFEUQenQqRTBJvYH6WzitIVUM730oAkvO+T+XjXICzPr8yXJMxE7g0IUgYvwwd5UBxV9zw+ychLr4oJTaxURZz/owOxhxqRj
# DATA y28q4oN/RqYxU862rmNczHbcl2LusM+yiO7FwkoXk+eQl5RfSMLPPBybwyOZa+IP/qSst/t8lG1Tkyy3Zhf8gGi9NGdGvcuRTZjw
# DATA oskvrE5zL+MzWDSg2Z3w72O2Qp3EOqcbZ9l0kYuTv6HF7F60W+z9R4lgECmBq1tsmfEJN6e9BRloiVSGZU9Vbza1+czEM7if8rqH
# DATA mRBMR/DWkUW4Bd8PmoZrmI+sG0HT2Z+BQ/CsoZWTeSPwXBzJzbPbH07GDjIIOl3UjL0JhHRyL6w5rl74chrlZRTzYzjZDFaHXu4W
# DATA unwRmc26wDsp17DUQhS00Jad2Rzv3sXI1aLUhbZpoboh3LfUAQd/F4ta3cDFKFtbkPs1x6SpqpvH21zdkrUWlNSZnp+JpWhtWW0W
# DATA 9Uip0ryj2UK8jrJR5npof5oz1kB/NbuHXLrJpWf1NOQh+IO/nNMto1L0RZ4yQNAj0owUiZHmWWeQ0xv4fdZnI/6Uk1EoP0Censkb
# DATA fEnJcQe3ttLlOCA03DbUwC/HfY9A0NYGFKtZGxyzEZXjLMfyOceiVuzOJBHauapYadbO1EImYZrTD8KJDecWFAZz6CVUMNR8kV6r
# DATA 00Oc8XiTThezs3RANM0L9kHSQX3d3Zi7Vk5bc5dMM88FLuhzm0YJG5os9jKlCDdE26U4AItMFukDA9ybNZgnsHWPMQlWfmJirdXf
# DATA VXKg6YOwXlqxwKCbyF+bTWuPcbRkFtSpkdUdp6HhMuVtmGHdtQIWFkFZhEDTz9CLDTNqhXFIuiOSOxN/lIZlyfzhEJv+zHSVwv5c
# DATA 1JTL1nsd3vPqqz47VGUcRysn7XnIDlw0es2K5+TW1QjAc0iEDFDh6SJsmZIwL3Tc6jQW9lEyk71RzgVrPE7BIhYQyV8WeWE346af
# DATA LKP2xzTaH9jvIpMbXQj7oZMFwE/y8FVOKLeKDQCx2oLwTkoUMaeaBU7hyy92Boqx0hGYg8wGgfCxsFgiGjttp6gg1LqDTSEud9ph
# DATA Fb3U/qKzIoOP2ixI5wCfVPOHeTeVtBaoGDmFUIx5BGXtnEPOB9FkQ/IVkFaNEh4a7h+Woi1Yc9Mf26+ymHq0lnSHaoZHgODQHWqp
# DATA VqtTONO9HRVeNEmINLnke/4HOmWp2gEdtWIB8MMyIsiHsPFFMQC+cKH2x33Oyw23bIoLsNBanIQhpgYrfqD4Kof2+NpcKXapIP+K
# DATA 2CxqnsInJdNOzeKh03DJ2MZpI5/UYrlUuNx6IEFblcyXhpeWVLtNJKVmE4ffbAKRNps8AU7gDjlkLFlwOCHgCuDiIF5KbZbQIXv8
# DATA 357/Qm3eP5Dze4F3z1xXcGxO8RdM0AbiDAWTW3A2CA6zfZKPO8cblBfRHkTph0AV2Pty8k7nhP+C/B38561t/gOROP52+9bNawi1
# DATA g08zOyhtE1UzmEWi29/vTdqCdIapIfJa0sfIehx/Mur8lIBFOOs8xOVNer0EGqh+w9NXTZ79uwnZe/4xwXIwTIKOHCi7SB2/pJBH
# DATA iy9TEIGbP+X5LwFR6kyr8Vf/a/5P7bK9HpycahtVhyffSBsQFH/xwgX8V/3P/3fl4vnz+m98vrq6snrhr5KVb2MCJuBgr5r/q/89
# DATA //fyyy/DRlLckUy5EvqHoXaSh4aUbl3ADBx1ep1WDihHFGG6Wl2rfn+turS0cwQ+vHbBn02UiJ6Mj9Q5gWhyHCCCGKDdQ0hrc9Tp
# DATA DTEO5QjYB+AUqreDyeHREhbSF4pk5+pWhUBUDzotAClCMyrEyJo+cvru5Kh1v6N61wHPcrBatquqb50Rht+21ZG6B0cpAG31B9oU
# DATA vW8fEojY+rCzP6HAfwDOAomSQAyXAEh33pEU8I90Z954jtShZHc6/ZY4jhOfs//T/D9h/7928dVVf/+vrZz/r/3/bfwvneQdFrDT
# DATA y0tLaiPk4+Q02Rp18+PW1V4XL9z0K5liQANu61L6N0N8uLyPZdLsMn/70wdjuxiIIw86e2RiyHQL21dvbWEikFuYdAqBXP++U9ql
# DATA JB457pyawIH7zqJ5DTDflHAqOYA590fgE8/v8xo7shYXAFFfVdOAHh5M+oTMMepMcjgdS6PBg4xTlkh+vcGD5K//Gv6pckYXJ1ba
# DATA bgi93lNV2uhx4LPOw6GaoPUxftoHmeq99xLnxeuYbe8aiOxZFnyf76tLQV5VfPUQYS3qPKfy5L33HJl8oW9eSVZlVFyUJcTcjVzB
# DATA +czcTnFNIDuelPDrpP56tCr8namZni4ttSC6PtEzrq6J97twFykRdZUx1YakLZM1AK3dS8t/t7tS+X6rctA4vTSt6L8vTCsX9I/z
# DATA 6sWl77f2Gs4T+Xt1bfrd5SokRsfMkDD/kI/CmjhIkzA4kKRpL5GWC/JOpFCYHsvc/SA5v5YBfKiiDFg3xnbc7OPFXc4pOmDUd221
# DATA abotyKByWcD0FN0QLc2mJLu8OMHBrQocxhKatmpr2MXkl3kVIK/u9Ls/m6h7X/IAzsGa2t443mky5caXl5PbnXyi2sakQEkLD+wK
# DATA 3skEcqssjhnQHNLoCR7CADHRxYhA1cNWD3AbBvt8jh4ko+7h0Tiv6mXTHVZk9pLeX/I0kxXGyfenkp3AEuQlyf5Rq3/YaV8WayVK
# DATA A4p+xnRfsQOuya2XhkopVHpqOaH2uplBtaAFU4hQyjB9mMzc6iHRJqxZOZFdWzObFv5T7Q8elCBqYHUlOZecv/iq+u+lixfwnAPM
# DATA INwatWS3Wq3SBuKAHWdtdkCEGvTayeGopYZD97P9wUiNfDiAxAmQsw9A1iZKbFLrgLDCGoytqtYWRAqpbUDJBltAPa19jcmGwLPO
# DATA IoMM1kU6HdNS4xhZDIotqPy9EPOw5pFWomD2RWlBtHsKcz4t40qc8uxZkzedOsvMzFodSVWQOEunvGTqzBvBstWQ8QLmSQ+Clta3
# DATA Nq34lW5LLeYNMDsc9AaDETJQIoX2OiazAYBgTCi5ioupP1TdKeDwbySnAGjXAjV2DRCgO9NEEZQqGLQkH4cNTbNkWracKYEJldWe
# DATA bvUOB2rDHh2rkby9DY4VSEMzmOybg9EmsaUouwVE0H4blY425w0eyoba77W6x/llG9tYdYueAkSoWgUy3psqTFOnuvuwHXgADTUA
# DATA tRX2AV9KVbV8LllP2t2DA4JORcU6QmQqlnNPUbxhq5DpJVdsDPaikHA1ObecTB3TD/dNkS79hRZmOsuBFuAFHwH8Hvlm3T4HrBMQ
# DATA 99fXeSpZjTr7xfD/mTvHZv3C+aGumj0avWPseXEEn0zn6QkOZ6sefUab2qbhTpxzviO1UgdQfKxSOjLMN9WeqKVRTFqwflujw/uU
# DATA y7EO0OAyPzQvVDvgrKl9o8SQU5coIzM5IMkSgLox13aJZN43qlTVD0lF+kaVxN03qvmwB/e6agrwtskbb0C2oNfryWuwxwPdsJJi
# DATA h2PIhwj0WNKyMSL3tIbDZdS90xDzZRGs+aPK8DDNqtSbrcOsdBr1LlSD6BN02TYSZk3PkzoIq3YO5DIk0Kola+U59ewQ2u+Nbk/J
# DATA xjXFeporgNHabfc63qvz9CqobwpciRLG08hV66WibmXVvAMwolutUUuRFAVLU7L5DKY3xSi9feBpbkvAQSF7kKJ2JQ1EQAywafs+
# DATA U+K1tklVeIwLCeVLINfY80YJPF1gM92/J0EHRCQQRYi9JU7K6XBDZCV+NosR2/NkrPHbd65sX729ubWzeetmc+fWOxs3m3fubF5z
# DATA i0MWbbLYlwM09RnV3d64o7qMlRpNaBUkihJJXGofeTDwpLSntxwYaX2KUyobELeZ4q7VDk1lEV7qs0/hEaKzgTFdR7j/k4VpgZa1
# DATA zzDroYkZD+Lf4+rj3zz7HRrn4shvPlpJFQM/ZO4edsdX0dqdrKpjyRopo4DxWJkRfxc9yXA7lei2QzscjvYB5S86NSRQjlFDWe7J
# DATA 08tL34L+p2l2/9eqCp6t/1l99eIFX/97fu21/9L/fFv63y2Uo8zai7srppAANavat3ijCNQnzi2r01Y3MMwzxuYg4JQXL8gvUATJ
# DATA 34N8CUGewamn190T+xG4E0iRUUf+Ajug/ltj/cuTced4CPc7qnAyUkfSHsVdSa3guwGH9ZKumlLLcgg3+VahWyu6HpMG96C9CLSg
# DATA IAma3zevXL919Z3MpE4DBME25U1rQ9Av58uh5GmWAZKglhFvEICW6b2XhcXCG4NC1e3m5vbtjbdKNlivg94rKQoh90YsGYWxKpbS
# DATA zZs/XL++eY1PFYiBd/FtPJhLgjWShkAsZrTs0xWcKnWAd9TTUjaNwgmvvPZaNq9HpifNG3BaXdlobt3e/OH6zoaDeY1HE0+oyTXy
# DATA qp9rRHvOLTke3bTy+F8n1Q0+YRKJFnZySFi+A/gWfRZwKXr6g3Ah5iyCgOUTuVYDP0HutJAxOd4QfKfc/bWzS2F3TUnpMQWnMZA7
# DATA j0B+wyDWVi5cwtx4d+9i3hS7LITiDUbt0n4G+rDz8Ih/Kil9de01ikGzv8oWmY6t9Zsb10maWqJU7OgiYmfVwTAx7gjcCFqT8SDi
# DATA ISGTSbgsPjgM3ih9bCc7zQXPZun03Dn2UpDYRQxtQLcHJ15xGuxcUx3P9QvkuYjPluI869dlrm6u/3B98/r6FWcb87zlFHppt8rZ
# DATA 5Lc74zFnkNft8yud69mvTSOAI3uwoeB0c5L3nFlECRN3I7zLqNvGWOK0D36DmQPvjW2QQtTvbeu4Q96ogEsPuxpSCPszLf2LpcdI
# DATA d9crP2lV/h7gqs2fzWqlofiXItRpSoq9M036zY2dd2/dfqdg8g15JimE9NaWlyVVukl5BXB/TKLobSU/bM82PRm8QCDvb926jf65
# DATA FAWuvS5tFyOrff0npEfAftj7mMIsMeqY+yivsC51nqoq5FQ1rEG2oXpTxZubvd6qMsQPwSBnzWagKJACzoF6Br9FNye/BSVQfv9s
# DATA 0qGUJ/DjYNQ6ROFDF1ZHrm4V0XGpNXwJh7/iDSsvwnLcgb1Ul7HoeF6mtll1v72zs7XNNd/e+D/ubN7euJY6p47W2Y4MWZelasXp
# DATA t27furIBbEyJWaS3kNyw6jKxPhkfDUZ8J60l6RV1oVZsBmGh/Ovfu+s/3Giub23SSaOuF+gJHS2lZ4KhCN8FKEJNwaSY4l7spj+q
# DATA qNvLg9ao3WnDX+jvlar9VF1R/7eaXo6X3BoNFLduJHpW4bbkaS2B1FFAg/Zo7K09XFG8oa/D31cJtqgHMctlndItJw0qBL7TBQ2/
# DATA q+J/odwl0KqqG7mohli1hsr1vKP1awcdYBxz5oihYxX75IECkDW5KtdSvPoqogRddKtXo27QD9LCoWFLGq4O7ok9iemHgj9a+9AB
# DATA 0iuA2hWEvPoKYCRM+vfy+m4DXgAbpm6XaDj4Fi0yUv3eoH2iJhM+f6WOr9mUdbl7UIKnr184h6kr4D/ZqTNplyP9kopVz6bUl+oQ
# DATA cg1emYDCtgryeQmfq8vwVE8z+pXV0Z2MEtpycfV2X8nBVFFWHQ9Ir4XSnBLmzHSRk+d774mmFn+/VK+nA7Qso6WOClX1knql9Qvr
# DATA s+jUW0Nc0nvWrUK9mAoqeHK631N7UIgP6RHGPl0qIXGXsvrrmpjF2F2nZUPOvtwadpfJGL6sjeHZZTXwEvdfnooPJ4yAVdNZZAAa
# DATA rOKyNMsG8LDVIlO59a2qPq+vj0atk2o3x385rj3P3hDDOv9b5X/Vt6rzL7kfQT1ZrLt2k+ozKLe70niDNOIL93g5fQVjEDt3bm9e
# DATA lSgCqYy164rhZKVMq6zUuvj6KkuXRM6MFuqZxil+BLBkWjsFpb4gn0UCnv6EnkY1U3g4lBNVBqHOINcCJXAhXZhpABGZbexHzBPj
# DATA 6b7UlPlqq/rqZeAy6L+EVwZVYK9T4hAGcw/gCwwfOoqvUIxxWRysWCQqvkGFlwxuw75h4KNZh+XW+lsbzc0b8N9QnqKs5Hz1r+50
# DATA 4GLfGp1ck5iQEkFVQF5JSYGGFIFDrtAV/GDQUwzawUqX2CR6lXHMs6jEIJzKdJgFM1KBIpR1GjkP6rb4RDrSyPmLpRw1akxkL/FK
# DATA OBljXkRwD1IdoC0sUnnxXYSu/76UzX9aoj8V5LpN0r9YGhUkLpO6sIEYP519zPwKoWwVhpRGf+r+/UxT5i5U2RC8MSgO/0VRyUMb
# DATA CVzusWVwXOyjGGGNRF1o1MKOSnog5raSLdZ5xq2uVAiSr1IZqtsHXnU6DNlno3BRL4qhI4rmAJ+rBUUCS80k8JaLzoU4lWufcdu7
# DATA 3Eqnua3/9L3Ii7YsUP361asb29vNN9WOBfGW0rnhPZ3YDugJDf4JZl0oYj7comJZt+msVd8rftxpg479PiaW5zkh7ePlJD9qjcj7
# DATA I6HUE4oDnVjpMoH7WR7rlHwHbhBLJqleHJiIk1W5QETsFa+E79jmT2vWyNLIvlcFcMDTJckiAXWZTgHLwQxCeUlCp6gbNi4rfsvj
# DATA JjAkAXaIVjQYHwHQdkE9bi4dvsuXE/zIpOuwJ6YKNQHOuVzyX9L5F2WuHLQJ7AUjdBE2x2mKS6Um43Q6XdI532FANS/f4W5qXYTx
# DATA wnB67pywYgm4t+/KnOJOkoToT0HTcO4cLd80clm2pk58g92KCYviNEWHKdV1IegUxq5+wz/TchKQTZlpxhyV/r1RPbN7ze+blIxq
# DATA /hZU56XoIW5A7O6dm9t3tkA9oO+aoSYIMrDYkFPylli//ggD42LKnrKB+JVPbbIII6sozQocDSQ900hBq4OaQtn+iJJpDnCAlXS0
# DATA PNAhW8+kDyWrRXm5C/Fe0rI5rOi504GX6h7/WXC6r966+eb1zas7kWm2ZxdD2k7V2TYGRUdP0Qql16Xma/KNNe+t8bgF3AvwFkLK
# DATA QPzklGv3Epta8yCV8BS4I5OXYT+nsyLWrI6BA20JasaLnvo2L+2eM23CJGdZsJv1EDAujEs7DiOI5UL8oeHkT0KGX8I3ZfEB5BDB
# DATA 2pLLvTRxUiocpkyLt6i1gMx3aK+q7l28wJYD/G43pUgHSJLkWRQIGZy8D1Fpxh8QT2gUyIrUJ2izLB/g3m4E1XGqxW/N/5/DP7/2
# DATA MKDZ9t+1tQuvXfDsv2sX/sv//1uz/26f9PfV3bsPxkIITiFPG9fzmDKRwx5q2fkqyAXPgGqjfIUCH2YJeTi2rLv8hPMdijH2YL8/
# DATA 7skPAOdTX8hPHRb8tdqQ4cL/ItbidzZ+DArK7TtXmlt3rihG37x268b65s10aX17e/Otmzc2bu5g5AMKIpB0YpT+XemNGrl77CZ3
# DATA x41XsjeCz/HFuXr13HchG3enegMsevu9Vp4n13A70lFjTh0NN67mhRhifzA6Bmck5liFtj4+fO1rOLFGtvLR18nryaura+RXyU5Z
# DATA kNvzbn737vfe+M7dhysrlbsPVw/uPnztoJEyCwuseHbXUxpok1XrfDx6ZgTm0ZY9gp6ExggrQLpQKb+gLYFRQchcAFeUcnLhwvmo
# DATA eeLsA4QvaYS6kirpoUppt91vpfo8yao9SALJpmnndu5ExvOfJajOCQ82xGEBrQB9hMf2or0HlQDQBLYFVt9X0ZqbVnXWbByfegT/
# DATA qoG1KUcRuERCvjFMr2r+QoOfl2MIVNS9XslLIqt2zMpD8YZ95T34S+2bFDCNRuOMrxIj3QPLETOoHYE2whZ22e6nWuI/0ep3cXUq
# DATA b7I3FmrvBaieMwWKrWq3VlltCBlT2iiZSLRcIfXLO1mXnriqwLJcWKFlqaZyuYLfdAU0GYic8S/zwNcrP1GDrTb/odJ4RT1a9p9l
# DATA 52jaITnU2UfKAhxSCRlFLIcbcakZUtCII7fZyRSxcZubRZIlSmpxDT0CjACeLNJndTtafxOu7Dtvp5Ht93W4AfEeBQSWm4PxmwDV
# DATA 4m1V8K7hmajFHFi1k4MeyzfqX1Q6u4PRytoFTnRuv+0DlhKsxmqYHtWUOrvv0Npa9GK22PpiHrfWuOX7DFlDeCVZzezNBsUzd5gv
# DATA Rlu8nlCf2gx/40lEsDl6oD8kzxR3O4ivSlUHPANjvZfO8VZ797YQ5dXbG+s78yi2bKd3j9FX65UC+oq4pRUSmyalr7aKgRobZUmI
# DATA odm/x22W+RmMrbnxIzVc6/fNK4FK9Ap82+0fbt7ytmhB/+5sXVvf2WheubP9Y0fTKZ+cdDu9NvM9Xm17bcUrCTE7wCUpLyExznRM
# DATA 0qRpJZw3iTgIlpt0JQhYbgoVZJoqnvabt3aaN9Zvrr+lVUdaXzgjlbDNrk2y6oBnm1cO4zYtOGXi2GxnoRiQvzATcQzXkVYDAaKs
# DATA Mi521pLNHm0FE1TMYEEidawmP6gj68CXGfxavVgknnh1sYAOh3dEcKEDGh2VVsura5e0o5LreYXNxhq0GuPxFnWdX2PnL70gvUj6
# DATA 51OzrJJFrEaCQPjCEgsQ1266ZJDhsK6pySONXaR8b9hZW/xFtmlXT2X8Q0CLIzMYi8Z5tzYqHgqBScW2pNzpd2MIPLPn8OqtG1u3
# DATA tj21bYSzhLe7aCbtLKruO2PzRhyC5dyFyQJ9HR5j7hSZl/R7yTclaOKM5j2IWl5wREjivs0STxwqFzMoesnzwpTksQTiuA92G7Gm
# DATA HK9ZricKEua3tKt/uPXCpBAKCLrfBRmk7boi9FzCb3cJWbvhqXvxnZPPHJ+EVh5aU2miITtCHjiCEGW+VpLQ+bUX4wciABnsRuae
# DATA PJlMRWIpVH3A2z5tNq3WwJ3bzT3kMV9YRq6J84+6aaOkwcBINO6i54yn1M2cA4wrKW5FMOa44K66z4FXCd8S64qbrWa7qw3H+VxA
# DATA 5HZrcPkDT8WXVbmX05ctOvrZZICiARVcsfOetOUxDqSEJcsispJ2vdvTn0J5JdDWdBfYVRqiFVdYvZLabAXe/SDBa2UJa5JrJPyw
# DATA 0xGn30mzhRmLezm0Z466uVpT7TYiCgspBsoonFR1DqIu7TuifMKIRnxXX81w8q25tp20mKwklUVpHhkaTxfsgSFH2jPh0dVw1zek
# DATA UTGElpmGC00SViZpuRyJR1Wwg8P+0YVFMm86rfNRZuqrkj0ygLydzbDpTgkZnS2n+pgBdgY/t/xKXNNs2NJBAtpXVEBDm7Wom4TM
# DATA A5XZVV80jKeSnWLGOd/lK1+JunTGY51JURojbSLqNVhyPuygPpB13FVOd5AtxemCE9g65GG1RtUJOIJOqiAKRkCc2EtBVwsa05LX
# DATA JpJHlaogfiAcVfAciS/spcfdPEd/H2cznaY4WCXC8aDVRYVCF9Uj7tlR56E0IHkSqXy3PZV9aOwOHLZCmB51DAFgJC24CfFdAy9O
# DATA 5rZg7qjhpdm5qxTsbg4r0Fcyk1iEkM3qZ2AUNv+kQYR735pAaiHQudjCHFZimavzzpgf4jVJlgCdpIYIeXJb1mAa07bQt7th6QZU
# DATA Rx3aNevYWFxifHv95lsbMcZudpQ0Tn2mHFPes5D6HHH3eNAGXLm2kf9fmJ3OYqVa0HfE2aUix5gZzPEFpVqrs/J1lJDmSrpnYtK+
# DATA KDyLF8f4sdwdC0Tq4q4Xn5TFY6kOB8OSat4PFQqk5qi3X1gfHhQihxSW13nVfAckqiT4jn0K8MLYnhwPc+3y1unn4EzUyve7XVJ8
# DATA lzHrdX9cX5P8wgu4LXIDyMxh/vfSNHBQiB2kuAdecm8SJL1oQc8Sldn+B40VLGMh9XEH7comexiUg7UFa0+73isOZKampK4Nf/z1
# DATA 0ixK0nzkhQbE/YZ/dBgOuOTy0qh/gk7FVg3cuKAKfSK/RDfmsFHhbfru7Hzn3/il9CIHi06RJQpFSXTO+kF1h4zlzKjAwMBMjs7x
# DATA F0oZnOZOR6geV3NHz76aSpfrpfQGoCKurwxeA9gRSumQk0aowLHGJKo6bvW7ByCFcAor42G463QvmpVKMg7hQ5P1m3NeYUJCWw8S
# DATA Pbc8P16T6cqTxKyKMltkWqiRaSCwY2/L+pjr9CfHCHZaEqIxU9fwUmyN0QXaUnyE2nXTQMkculm8oYjIapFPzASIKwt0ZI07vkHP
# DATA IotYjRbMZ0EbccoqxWmCkb259kCjsDS7djOZ87/kpZK0aq7eUowYrbyzgX9CHGCwhkIdI3BDz5XczHWedakIlcniXLUiWcGb+dkH
# DATA PdpyJ31S9S+d/WCPze3Ci2OMqxZT1deAc8594X8NSHDH/++4e8j4fl+rC+Bs/7/zq6vnL/r4L6trK//l//dt/O87Ly1P8tHyXre/
# DATA DEETw5Px0aB/HqLEbg0h73zCmVEhdLTVN3CZAS6pAx0JWJyeVyC707VGh+hvt6S9Aocn5I0HmgzYueKJJ78pkPfv4Tb4ld0AA/gY
# DATA SFkgSDLg5TffL9D2Ilx64cxUUSiadoemVJ1oJsafOF2vtafYXoiEcJUBkI0q7TqWdGK+bKstVaStxlUKWJJboeRpqYJXtlrIpvqU
# DATA gBYEsAzeLlyN9am5C8/5VEIlzKeBLdnWQXN8vzXEOgT9O2AkR60R4pGsaTwSfGJDkqgHcCaafGRypZUhuzfcYnuARm+wU+A42W94
# DATA OL5tdz4eBbedFTcuBqcFF5lupGR1YjgNtluU3anXNmE2AKlfNJliwqbnM2ZF7D77ljKtbqnVuEt1ncWLB1vnf8uxmDttnK+zOg6D
# DATA qe6onVmHXWjfYDLByZFwmlavq8Sk3Gw0P+gs54hKDLx8YbAUeqxjaSWc4ittZ9HCYoYh1FWL/yhlG5JoB3PXOVeS0TBiCA1ejJ0Q
# DATA C+WVuHZzG0BWrCIhHs4sLJby/JG9zU6xnFbQQMmegT/QVw19+xfVMuVcI6d1xynaudV8HS7IhaAnpx7oyfTbBT1ZwJGQnpVM18uu
# DATA szITVdm4SoNJ8MKF896A68bvGqfq0kpWbD3RKYsKuAWtHyW0Gw8oBXEJ/2uRFCjM7qsZAEbt7tYyh3HPxs0pR99jK9RzDneou4Tk
# DATA bpFYwCcSpWadEjRRYKk2xiGOuKgnp057qnMYnUb7moPdJMyWgw9Ui2/evnVzp7lx85o8YxPvfewn5G+f+j3qc5NBn7SNDES6phUl
# DATA iPaHF2eDS17QYd7h+X4Bjgpo80oyw6D8ktNPauY7yTVkGYKJlrPvV2t/NMjzBDMU6GBvHcI2HiDg+T76VmKSRq7spwDDD6/kE461
# DATA JQwC9ZyCYPY6IPiSL2eb8NFbx3vdw8lgknNcLkfR5uzJDF+JhtKeDAiQxxdY3npWZ3qkgPf45Zgh+UtWLH7JqufMa1b0P+wfUtMu
# DATA OTH4ByvHGcuhSjYT06nIusWsLDrw2Gx4oWU9uzM21kEclcB1vdajYB7qj4S5TzwmNFB/m12mlksjX+lGgHUBaNb9YuyuKOvWG9MZ
# DATA I3uWCpx6HnDK3GKVdbJJE95/E9IAOH73ardMemOjBMw7BKyoummM1Aa9jsxo3IqdSQ9wQRcQbDYx1aAjdf4NgmnrqgYP+mjwwyqr
# DATA Iy5UI5ealQYlfDzaH1W7g+XeYAx+1MsmXDiAg3GcXKxJIFKGtuas7KijBJAu36PcTi1Tpyqr2vOn5o4FNWn6cy0ihJ10Qp7D19P5
# DATA 1AeVL35+otuY+eHrmc0Sz6X7cecYHNRid1gvgrwUgA8IHoHcG/UDHThPgeTQRmgcljewkNACTy8QsO9mCKrTdhsPRW+XAfGLWhVq
# DATA czwe2BuDSmE0c72n+E+7hQ3XZEQzup9pL3CCCoFgYyV2Q8JLlEbqFu6G+unvSfWotHvO+qhBhrA6xY7vt4aQRaw5mIyHE3k4Jtyp
# DATA +uqlFc00eZw0LFCEmgmycoxyjD+Jv86dApq2bG1Aw5KDKUmHeItkjEz4c4LyLwOh5OMB/UQ4FAFDQYiXKdhdGDrF8jalxDPo+4W9
# DATA pjSNGO9kAfF0WjkB95fchEcp5Heb7B8l1o0BMkM+f//ZY8BJSp59+fzD5x9gOknIPvn4+UeQHDJ59lhSS6Ye1Dy40N/rK1aRHPRa
# DATA OGJGcPoAU/qy1MEfC/QTAjN9gs3+x7OnAN9ErXgZKcO2IFMIuN8MAPak3+20sUELHip59qn6/i+Y5/KfAcQ8rONqq88QowBiJDIO
# DATA d7Td6hyjeSzlBwhnZeNPPYnVyTyixa5OlqoHv/8McyC/jxk4PwS0KzUz8cSf6kVkojNvZTU1ol0WiJEyFBL9kyGDKECRJb3S1+Fu
# DATA X4hIHgGhMRyXDb4lE/C0qKu/SmzSefYo9ZOFyoUiTDdbOkif/QulglbT8cmzR9Ja6VRvuWnG5PIpInxBx36BKaMfATB+mXr1SXIa
# DATA bN9pDR7C+KfVxM5HLanpH6t/HuPHgAwGmU+ff+g645rNpZiF4VLoJAIMp0QYPahisV2zgliQEFLGc9aKBYWAoTfU4GF9plyrv3/k
# DATA 3hh5tmF1SzC9jzB9LKTY/uN8dLQCQndUaLu+v8zQ6ZLEPbvckfRgGLSGc+EGkGQNexZ0UdGhSWgjvChljqkuUK+5w//vTv7bP2kO
# DATA 9JUmgqlDQ1qVExkOo1nRvq+wCieq9/RORY+VWJUYoiEFutHDquMO0nXjdCDQk0wHQVyO0JV1N60c8JfwLms0BCuErRcUp9QkayBD
# DATA Y6GykB+RgbdJXog6HTbnOo2dz6qxXqczrBMyN/xpUKzsTWIMD7EsCxBJZ34tFQJVm97zRiJZi8OU7MpviAXPxCuFIVqww4LNitIT
# DATA l9UrZkrqRzVH4vNpfGbwFKZOqYfMJVsqCrJxpSUiGIZAS88RSYrwUan0BxVUDQwxXYF+BhBhyIcwnys9PgDXRDyz2EMEVhjELt9Y
# DATA 4YlxS55vnuOa7YXe4F2ncM/+Vu3UP/DmpEPS3a2RhCaLCCxLNiY+clFD5lmVch3Aaeqi4c+DmHe8YsFiV20rioc/2Kst81XmEQA1
# DATA /rPhFN3llPMNuVI5b9HVL92bdHsg/Bh3P/P1GeHAXA2eDwg2H6LNNExaamnTq7jnKO2h5u6gqq91osKuQLYxVX/kFjhdcty3cCEt
# DATA HpWFnlsIbwm6aTGbYuZBsZxWJ+N9XPIDeFJKv/fj7x1/r73zvbe/d+N72z8h37ao19du7RIrms7gmoWID4l4hIFDFkWh4l6jeWSX
# DATA Cpo9EjCsINbonJQTB1q/JpsQopLtYM5aokltuhR6hGDnyroH2dIsRzLqN5G+OJMt9qWYK9xv6RfzO9HaODOln1qz5bZhJc+zN9+D
# DATA Vt4cETynqtCowATX08qVoC/mTQxV8Jgs3eIqlRZd0CqVn026mD5Xz7cwSz+oya7XMD7TgQhjdxAzzc3RrslizrZGxR2vgzBaCFvK
# DATA ARlsnejfJxAx41NuJZEw/ddu7O2ylfLAwoUVITfYpWzut/EtWWvQrHnOy3ZnbMjZECvT7o6HllngF1lAMK4blam2yHoSwYeNmUAs
# DATA UV9qrC2F6eWqDvpwZFCkrNTgwzxxlgakVqxLMSc5GUJoamtz/Uat8XobV1cSAQkJaHmOqBzoigoE4YiWzMi5JgtnY65gJBtYpiaY
# DATA BxhBd9zkTguLtOiGpigUjbPYytr4fN68oeVAlboflQPLrtSL3ciCW5Su6DvJ9ngwHCIM2aFAveb0qJqsJ8IdMFNVN1d95vStaLpR
# DATA l90EUWHFX0nN4EO0sV67Ug3WljqtVVooWLY7wirVDxFSIji/5xRlVNoUoWtzLVRk7tLn6NICN6SQy9pqTuvz0LGzicoQiKopXVzJ
# DATA 4hHREbavh/aCjN9p4mvl9f6ZQjN2GsY3HXVaPQyPnn0MvI3F7CdQZJLH/YUXO1LIUscdAH0o8a2Unpz4Cvui+ovsI+gRTTYVAGQr
# DATA 5ssBRzYSLNaBXHW+1yzfTv5Vqy7hnsHKS0SvBy3CF6A9I/XSl3yJ+RR1ZwslbJyjk0jjxsA9tXXvxZZJ1r6u9mZfZh0j3maun6w8
# DATA 6bDb6mJE2mjFh9pFi+ZN0u/n3tcM+P/zX4AyL7FVj88+e/5R8uyPcKnDRwz2H50B1DCU1haBM4/ohj5Eteyfn30J6kDQzH4OOtkv
# DATA UR/9CQ/g12damYKr/wLsO34GN3utE0iRQdqPr19pwZzj3DkR3s0R/SZHhsSGNHUlplB0sNVK+Lfj+FLgiC9VMNarPnbpkF38SDWw
# DATA t25UjCfP/yeeWOROT5o4uLuVNKbVKMfUPOINXF0fHU6AnW3hm5JYEdXY682mOjaazcz6Emx4zRZ/Ukq1Gp1w9EHfUAcyyfcHjLSf
# DATA K3FFTFKoEBQ5gtSKnV6b1IgUF0XiE9s94ReZ1ciIxaolApNBe5cYspHFpjqCqAJ3APgpSVfQtItiExrAMMPJZNSzVWrR4VXwZo69
# DATA nDEJlQrGpUB43cmwU9cZudBiV5dv8B/4KjfXNvhVtax/ipPquSuSmekbnJay7X/gcAAsRF5V6jT3pDt8aZmXXccEpGi5p8T7yGtq
# DATA yeG09D4fwk9puRxZCp/jnOkIRNbGr4CDq/X6B+j7ytX77hnBwelbwOig/AItQIrtn4nPRrXBNCDDbXTBQlUwSEbU+10zrMaspeXs
# DATA hjZPc04b0avbhalqutDh33yTw78dDTs+0XcJ/KV17VqLbqinqXYJ2M/VojXRsNBsIgU0m8BUms004ttJ7KbQDVGnvninczI/8QXo
# DATA 6TsevOro/2/vW5/buK4885l/RVsebwMSAD5EyQkUjEORsMyJRHJAyo4XRFAg0CQRgwAGDUpiJG7FzmRnppLK1Eztp62aSc3u1n5W
# DATA nDiR7dj5F6j/aO953GffbjQf8iRZcSYW0Lh9n+eee+55/A748YRnv8Kj/DM6vXNaXCwzHxhu7wQemyTrdEtkeeQkQJi3Gk70r1/+
# DATA MzQClZHFEg75z6F2aL8SCEp8zr2BzEPY9Kf47sdoKkMZTsgEKNKVAvHax5TJCJTR/2Ak5caevQDaRWMRtgkQr3DbrEH8A1nlDVI8
# DATA oZxDhcW/jAipv+w/S+WP9+grh3/Pjv9aXFheXk7gvy/dXHwd//WfG//V0DDvmKgjmhACB2n3E/Ff8R1xdgpevtefQiou6eTAwmic
# DATA LwYsiRovsye22T/BjxR/8YgwzL74Jx8fdi4zMvbRH9epsfi16k0ldisZznumUFeyvOBZnO8DYEV/ekIG3KoF+WzHuBfC3YWw8qMR
# DATA ONBD9DTcsz6SPu3k0W5qPUPDoUjaXYtFjWxkxck3q0vLLYUr3R1NAEFVwwBhELr2aKW0bgYcgsJXTVib4lBKx/RSJgCpmRGGcQ0a
# DATA 9Xvr2zuND0Mb38lEdqJ6DwajvUJ4XWK7Wp7J0iPE0/B5Gjc8Biw50g4el+1BsklUOnkWOE/a3HvQ/upmYy2ZkBlqyoSiVWuWdMQk
# DATA d3nP0hnQuHNqHPBIu9JIJ3v13DOhXknbiAhJYu6aNLNFujrZ0GzQ3cRIvRnFyRX4cedRVPbaQwmuAwoC0D5vMW8HHwr2BHmCWmjn
# DATA hu3fGRJeF9y0TvOMUd8nLjXQ7JsK54YY9v8OIaQMrFekYAgEgMqMiwgWNfMW2YRLZhQLxZJe8cNYmjS9s7kJ8JUfIlFv225RVIeM
# DATA 2+Xbso1Bhkdop1dGH3PtYj3aD8iHlMwSR2i6YO4tw1DEfTR60ulKipVJ64gNO4DgWRtBEX3bcS5DdmQ+9/E2DjM8NdpO3yU2WKhR
# DATA 2kMduvmZENZp3bHuepI3sE0B9pJRvbWjEs2aLgUlY8OFxdME/8KXvdEZhk2i34sN44pl80gxsMj4h6IdoDAUlBxT6o3bMpzZk8e+
# DATA U96HoOGni0ul28unod8xEWrKy8JXNzd2VtY36g3A7Kxv7GzaB4ki5PPYeK5DB8iFX0wPqRG1/kHMx+gxYbvpBZhP4XgYDNofzWcW
# DATA 9KnvVazIjCbOE1JymoyKRXkDmZXFtYx4ixQjjD4dzxEs4wmLAS99mlBDwyPjCAxC1eoyYylyxfh44YGMKiuQ204QQzIuqamqa5kx
# DATA nI5dw6OvkWqaYg6gZ3PeuUfJ84hcy1TAeOhDk/OOkZ0YUzye53xwNuhhwk4K8A+L+fGpF1hQb1qPRcJvmDJTpjixyR4c62QOlWw0
# DATA Hk6NJw4blYXGO0qJRtoke8h1bIeHmhKt6HWypplKGUcilWiqfTVxtClIB8yzA0AmcdbQU8VrlHEd4DKn7VFckblQw6Gpo05CEGJe
# DATA Fpa8O9NCMQsrMW/KlIIvZ4oZa0ozQ7738DhRfnFhYaFYzIZPzJ6gzQ/EEeLPlezz/s2Rm7iYE+SdmF3TlgNblqshh+kKgQAdwk5d
# DATA KYOqmJuZLDmX9tgnw8zN3a/fW1kl2ZLSnG+/4vMv7xEoMRTYHIOBuiimWkAKPJSU7HI6s2uO0yo5ExIg+Hg8xsvyjE6k9ZS2QmoP
# DATA bcDamT09b7hpUWFRHESGsqY9iYTYB3cF6blRle6I0qcj2wOvmJTuNV6Acl+bAVGQHvjvuLYpEzRGe4G1G8/MrLa054kBh5CRqS5H
# DATA hLNSYLVNWyNhRkuJgsObNbyMGYZhOBKlpUXLgcDjojLlFKS1T6QOclKpiu1Qp2IyUY6ngDrS8qii3OPqsheUV3w5ucjF5KovJW4o
# DATA /L52J7KEeWOjkEud6XK03jMwrNKAnzxTJKrKgTFgk7P+9obTCz88j5YFkv5Ds7qn9gC13O+ZeFz612K+SHUvj8/nGneBiHSTgzqK
# DATA STws7P2ZIuPDHDubMk9XZt04EreNc9w08t8yLD/vZjIfzTlvH8mbB8yp8dXhZ5RXgG4TfsDti1wl9KC0lnFSmHm5cO6dOa4Wl7xW
# DATA XOhKkfc6kfMqcXXXiMzLwRXcMc5/v0hxS9TkMZfzJpL/FuJBCTGRJPSVA/NfuLpp7WcmfhSsNE1wB9e8qBevKnEMVZkz5MrTq4Ww
# DATA KKnplV3WqBYkn0WuSKZibZMhtSS46u6b0prWTOWS+xycEZZPpLsW5h/NEi+Qmh6s32us7KxvbrS3Nx82VuuhFWgrnac4/GhMEDea
# DATA qYu11eXpkbteJrcfQ5oNgoWyjJZ4ukHlWo/OJW2zID9MUPobtRxcO2UCcDup9G8P1rcfrOysvpe0IIJundsXfBmJmw4Y6RFGq0OI
# DATA sPlX331QMpYe2qglIFmgBXlPRE9Atr7ItlEH2tamGQvrKJnRjV4yU6OnCEJLKAXhKuURWulWu2bT04xVJ+VlrHMYuGOpJmQcxwKV
# DATA XefM3QCJ28iIXG/U18J03NI8lyYXCSfPrG3XG++vq134JgoUcSDOfzR7lQkZSlq+6DSPIQ5OTEGwNxk9jlF5PT6expW5hGTT9ARW
# DATA XfdtnFYinaRPwzo7M/UFTPiuQJByVkktjHggc+YxQHNbyORABLQlkkiraSAexkVTjyQnsq3OuNfk/YQ9ZcFKfifIFnMDcK6AuaSk
# DATA koYrYkxyzckZ63r+A2gefWmZxwP3FdM6Z1HkyoO76/cebj7cpiXZWWncq++E58sRaIxdJwpckIHwCd7l5NpCwYGqCDGCsOqJIFSe
# DATA ANqKxI/w7neqfGSOQRAWogC3Nzw+2lPqDLRYIx8JGBiNMdig9TsKVkQigo+jCeAoxIgphIhjuCkxyA40RspsDR5HmG1bieTYA247
# DATA t1biz0QZYVkCr0IbYWyrhF3RaIyZfK54NZghE5StImRVCag97Y6NUrBqe5Avc3igYXu3xPKJ+zfuLVhc6BEXgk7xx5ihgy3DnGis
# DATA pAuA95fudAY4JbRoQoBydpGWBPzs7+9HqJ5Z39K1H0E8KIB1Bh3sZyXYwBNCiHNAx52h4a4IOUIjgCv0MglHhnT2t9a+JLb3TFQ8
# DATA QwOR3sAs9YEUSK3bBXMRPiMdocP4ET08a6pkUnTQxcweGq+m8jCu4KnyeWSdgHJ4dDafrjURiYVJ75JxcWnX/JmAVEoHMFvrcXo1
# DATA AvSbwY7gk2pBYIORk4/kq3L54Lx6FCHrncSH/TEg1g4J7khetHqMP5mwLPlOC3NWvWeGLuA7OXJifSWNB54M7xDm0YFw4/Z0hNRi
# DATA kEJOM4HeFBdAGp1LwfFUth829lRc649K/u5PSZ+W0L5GflrGk9HEsVWqvrxxTvuSW5UjZ2tE8HSQ0RTPwmIxi9d5BVFmmJK6i5Bd
# DATA +ALedUR5Hsj9WcD4/NCG2UlmNjOzShAF02MzeJUeFegfyo5KvTJzJdshU3n8iQGyB/k05I0ib1/TN/ES4p4ehRTzpCOc4bprnlFS
# DATA EkmuZRYKgHuPc9FfGGiSWsnYtjmtIJcytXGjFwAhIJAZtoDTVcp06nQtQ9LDPHm4Ji89iUt6Ik2plGbheWILJaPgya/WcH01Ll0p
# DATA faBXfA1rMUw6R5TQJOvx5Z115EsvUcPZLGHc0EgRFrHacL1cjxd7xpBwEy+has1w8kwHfsDUurogPwYPEZn52B49nzneHs0+eWb6
# DATA k+TyItGjLKkOhcfDzqNOf9DZIwyYME0ffSXXyXQ1NfULkydSB0OOHReP9kajgemfrq4kGfVRcHWVxtmsigtey/Ffx1p1N/VPWdVq
# DATA /59Usj/1gKSqW3Snd8KINQpkeUlCrgCWBOfcxSPiaCT43WjY72JWbi5PkF2HAGiZKPRdVYUPRMu/Xc69VWw/f/t26Hj2NyI08Orf
# DATA kxumqKWNiS4NhGQDayTez9iZUJsDpuKFxk8ZklVPsh/2vs/ohg0sksWONRaoROrIVK+urH2ofIT4VLUU2CraXeusdQC8Fu4QhsGE
# DATA 146MR5KbDUbiOp1fX725VSdriK22zqdn12AUVo9lb1N6RPHUWZIJgFLYwokjkbTsBhEjgNqTwBXYKFYgDnsUbxYXFhQgRnc0GE08
# DATA 1Zp2YoPksvqqesFYGgp8w9NHuWBS51NMilrJ2XyjxituClqSK0mqUkEX5iltqPqm4sZCmj7Q4MnVVeCmaLSdQigKoCv2p6IcqwMB
# DATA KQtMiNEYND6YuVQq+2bJB3+yGLA29KvGMPWhuppGFc+VSxaeaWdhMwdoC7bXN+5J+FbU3Ct9n0mKrO7axDhGsFz1OgMwErH4CaZB
# DATA RJTEdeKwlrgSSK3u9LAzNfQKsPRcI8aMAhWQSuIAVGGoZ5g+HpUlQeiMjtLW0pHJcJAkKoxr2eudIFRzqq4A7kqrshiJKqJXbUJg
# DATA qwEIpvgtlPIqrYA1JAplU5dyO7jQEAHouIlUhvsY+fnThGWbW7RdZdC9SfbSE05o/aZVAbRtHLHJvFKL/UQbreZeQsXVMHi6O6Td
# DATA jNl5eU4S98nqzYXFhd3hqZl1/GgkLqWUXIkG2+RhtagrjwT5H1lzhxsSFPecoMj0lS1htj525aUKAFiGT0TQsYapCYi4PGPk4BuE
# DATA WcgTZteK5M71zkfT7jyWm9cEQio6IAcaYtFMEaOoRn8G1xUalr2EGv4Yg4kF76rJNMDQuFwXzW5VjXLJr4TINCXwTpfCORfQwDxg
# DATA x+jolHKSMcj2yG+ZyCyCGuI2pTs/LTpZsvhN6zKDuZE6R9IbymRcnuzdKRzsvZXt9lp9q76xVt/YkfxManNyQEanZain3PRG1GDZ
# DATA j3bsz1J/DqxidVc9BwyxCzfc0lGquFx6qaqG9rfOxyjkCDvuDBi8i45zgK4U3Hsk7pziAneHPZbkKRmIGTL91d+0M3gELEEER5Cp
# DATA jJQrMVwDBCPvDANjEvEc1kpjxSeg1y28Ae4rp6mmkYfIXAeYdaimlVqNFGiglnA4Cs+PsKxRh7Jfy19+Nhxz6ps2ILONCEfnbmpI
# DATA bj414AVie8nhvzNoUwfciFyjW0Wy4KjvykPRyaOkalSB9ikhvjq8N6s6fV99ClRRNWNzeZ/poFwocVr07Z9T9gcDUNOeBWv9n4/A
# DATA m0oiuRF5NTvGXIIO1EnBAFfyY445sL0puyODlCWsLyYNDVUG76jNjlousKBaBxWrQZ5fvc40ShChtzs+fzKT72o8Rq41YYxLLLpX
# DATA i52cfr4fX08cheesh9JX4fUBQ8aTFfLJnYPizXRrHuov5jI8NuoPNsXdHbUKq5sb7643HtQd8A17c1cd13Ha7/YZbb/hKEH3/XKQ
# DATA zzscs1UmkDJa1lZW8qu0bXKay0wICrdH6mUUv6UhXD7l3JkHUUofybiesymjc5o1FNPxSY3ykuUUMxOrONOX8GdO2RreWFmVNdYS
# DATA WgDT0rlPhUIunnTUg2JqXC3X6CGlZN8hey3IEkjYJoUbP4NBKCnktryzDnqPLGJOHuT6qGKv0zQoV+OMLBlcyQSuILAUBfCJWm55
# DATA Dkh9Mav3PbCvELRDDNTPzWfBwXr3sslCzjMVM/a3K1+coxVrHp16XPziFNHE04RR6nhIF+1E7AZdZmz0Ag4kShi8vJFUmaPkkXK+
# DATA CbQ6ODbqdJ8rfyTGTMXW+ZF7M0MyTFTfbERfmEkXxdcMJdBUrywioEvs5XQ6lUe/wSmribRfijFW5ds2NFIaGIeWiHNK47bXlCuX
# DATA KxK9JAKY6fOfFNWLdjusaDLh7qXXu6zGiAPwIewoyCurjKm00PK66RpK2aLMqOO0tSwxp9YK5a1OHLPjqCQIBgvEC09XfIeZFt9R
# DATA n4N4gl1pHIjFMuhs2kqdnOGfnIipTXjk5PLLKJ53YV3XbJlti22uVnBHvl0h478D05VZdBuiv0M3FIQcx4aPNJ1YRwz/Ys0DPKOI
# DATA MIi/ivs/joK/Dm7funXz9nm80esb7xuykHZKBU+OPiiiB4VJ+ENPGHitYIQGlFs3divZ34t/RQlXsvR1EEtSeZBATFIOmzXLYdNc
# DATA JsdB0z68KGMa0bXMB7b6cHunvf3w7vZqY30LQ4Qa9YfbdR4bqEOoasE4dofKone5cBiyezohMGY8O8clWTK7XbyopWL5KJne+c/W
# DATA TJNDtUjL6M9F57WrZNnYGWJCA2maF5jMibZ2J1oqDBO9GzBelDFcdCHRoXbs7ev6/FHw6+WiqPPdMlMC5FLmJonIwZ1pyo60mtyB
# DATA lgNBae8EKwwqJ5LGjJGIO/JGfZU38t8+XNcRTv6MYKldglTEOZY94fokWY44LqPJtM2cos1sIU7G1RKxly6RKs+1RaTLiQnltrtV
# DATA TpMvJxlak1ekZSS6UfZt1xVKzsdDmoj3qTZcMg/wejLlsuc9Xuq1zQ82BNmu1dt372+ufr++JmZL8GkQNbFW8P4Gwyd+cawy/syU
# DATA +ve03JQpFJOkC50UTh5N7nueopkJ6IiJ68LMxorp6dfO5ceGsgQPnrxt6XHJHYrqppG/jY+Hi2S8S6vdl/eQ7mU8KLT+5cvilMca
# DATA 9Sdkgcre3Tk28auwyVzcxnJua06WTeYVpfx7E04SytcZR2IVxYfByR28shjBMDKWI44guph+HQ0G0F5A5vDK3J+9xcJnj7k6S9jV
# DATA 27YuaFu7GkuYdfxfueUmefRev154GrqGHInzPOt0QpaZFGr0hQFcC2bZg/Kngry45egCWvFMO88rT5LldembldXRdOk7n/Xl/Fad
# DATA yxgbcqvckynrMpTHyYCApPrbsvbYv2WZj7hyZRbCevK/nmbqOteEpxjIDDD0S5h+LmYEkWn4uBUnX3BmUrursG5cNOHda8tIhmXk
# DATA m84GmMrozGSARFfHE1s/5gj6OnItBYOSSqWiz3DwgPRtcHVsBbe5oo6eM5ymfZrv5I0EoQyUho8cOmvkUjF6clILJSxHOBt3IyfY
# DATA BqMq+BAV5q7qzphr6jmgz1LD2yAoOWJmgRHb81DpDLuHo8lsF8S19UZ9FfAX0AOi/mBr50MdBdiXwe3n0MRbNgUl1UlABGMwQuRH
# DATA eLOiASmK7Vyiz6jpB5dTFeGhSEd5kOYL5Ghs/sColEjSCM6Wkbb+sFe7LzXtky1H6taXNtDNByvrCUUbWl3z44+SHrg/mNI9aQCR
# DATA vzVRQYXRkOXFk1cRdfJyRWWUKtqDjCVi2MzkLYy8pLE7g/iqe5G5chI7QKzc3wjqaNd/sL69sx0mtiKpbpjVpKteiP1Zepf+vjX8
# DATA JJWb/qorOiJkEjFPDDqT7mH/UcQ3W64LnUaD0bAb3ZHZ3Q112pvB8RDD/iPdYh9ynnSGHEUQgSmA0p7sTWDbaxdVbi9NJaM6dk4H
# DATA YaPqXDqaBFvIDvF3ngDbM4EPPNVcFBfKxVnAc0JO2ry8wh9brky6fPbQSwQm1R59ZMyEfrl7KF4s4HvFDARrKxGZKMJHh+jreNDp
# DATA Rl6Q6trhdDquzmuY8urNBQrU8hWGZZbboDLRILc+HVLSvloy+23BqTy1o0+N2Loq+AUJmo/L4FU4jii0UIipqD6pBk3LmUE1VXQU
# DATA 7+EYUW1E+f1wcentyoL4v8XqU3h6igEerqaemA688dSBOiBxqzwZDdKcI9yaRgcHFJb7NOxN+pjrl0xsZakDGo2l/vBpeNR5UgbD
# DATA MRRaXDgiHeSTMo83vBmeug1QxGT3MOp+hDVMxdzBUMPVB2soXQqqQ56K/92PAAfgGq+7ngyYhXk0FQpZeZ7qvFasCO4zLExqfy2D
# DATA pTHf6KQy+uidhepisVjpIqxAoeiUED9x3L+oUEg00PVbyOQ5LFc/ELwNuJR4sLhEoZSTaXscTfoj8AMLlxZiMeS0wxVmvCkXS1zj
# DATA ZsJSwNWOPtr21acyRDvhAkPLklxniu3WXePjwO0bP5au/gwgoPJSW2oTsp5abzxVb4henKq3oEuQ+wUWS3vL8RC4At01V7ZIU9Za
# DATA G0lHBUkx+2JRU8XEAA3zsIybspgAPawuCelk3B9GYQ5+INkKTsy9zbX63Yf3oPCRmLk+XNmm3XFtIcQJlKwg/PZC9dvI65aXb1bF
# DATA /4yP88e9MRKwDOXysRo9Q+jMVPWFVFUnIyVOliF+szoP/9XPaFKq86wCttyuabpkF2iSdE2SIsx68NnpLHZMclRZylHinuBq9l+N
# DATA 35jDuGzH2CqigBSSROKgC7ju68l18QyvaGEt0IfTS+DLpLqymcq0TD1oqso/h/K0N1uZIO9ltlrTq4PKbQ47dUNyCBLTxkJjmGJM
# DATA Cl7lQ34SIxqOzEZbWZkcHMNu3cJfChKzDXQF7bZYvXa7aLxZEfTd7vArhVCFZgPNElxwrRkqVXpZ4xcTugj6pYeEQTPl+w4rMbTp
# DATA 5XgSKZZcPp4M+Be+CJQBURsPL5Co1LGtHAHxliLohXEP8BJZ5mhLZF7HcVQGvqO/UU0kFrnB+vIU9IENtDJmplwG8hWlIXy0toXa
# DATA L+m5YQiWpne47fkSojCPkHepmWKtKbLnQ49YjrV/ZOfPpKqeYJ1sUKHBke3ERCnwDxAkUO0zC4nr0ZqPZfEfKB1rqCRMbW+jAHgp
# DATA xYVHQHer3vHROC54kbGxXlJu4EcDiBu/m3wyGsaCvNqduNvvMzYyi/GDrB5GoaXzRXs7Fib9mlgB9GHSz8mjFKN+L+meY8Klmvar
# DATA WuD0oGQrusCJEJVWbn+Kai3Uq47xTk+9RDifNcV8VcDPyjhHL6V6+3kGNWMtcFtnUIdErlK9vciCuzwjoz0XddidJUPVRvPNepEL
# DATA 9MpgWxkdMoBu3b7Aw4s3rDmkibzhd53OOQv8zSDMzH5I7u6OXqqtz9eqsWlQ/+p2xXDCVVosYyJB2RHiVdVD/yyfQ5FQN04B+oZG
# DATA PHu48lA0Uv6yrj+xsOht2Mu7EbOb1Qdw1RF9wWqR3fT5GdGsrlgnfgL9XXnxpnSrmL5Pnn4UnbADEQZjWSFj3sO2eHqBvaOP5yTi
# DATA T8IkkRyFmk5pnWgutLIbNESAtGulQe7S4fsqVkuLX+5QNRxP2jrJmk0juYSGyiY5DRYlRF3RsTZajNpt7FK7Dfuw3eYewRrH/YPh
# DATA MSICFuBjZ1DZXr+3U288KAX6+3sPt8wM6fSc/ilQBaWAc4hcb4ub2IlWsyRdX0j2nruw3yeJC9snkJ++Dq1oL05QroweReNJtN9/
# DATA kuH6aWPMWvllFRpfroyOnu6Jq3CMqbxdmOJ0qUb06Oxfg7M/vvzJ2Wdnvzv7Svz38+Dlxy8/EQ+ei68vXv73s88CeP7yE1Hs7Ouz
# DATA 3559cfbly1++/AdRFH7/5+DsC/jlOb785dmLSnD2v0WZ56K6Fy8/gbefn/0W6n/5sVUugP+Hhl+cfXr2XJT86uXPofG/F0U+P/sy
# DATA WNlaL4unX4u6oKXnd6BfP335T1CReP6p+PxL8e256IHT4efYYVH/2e/P/oAvYwUV95ZN6tuV1dX69nb73ZX1+zwhvxJ1fS069Zn4
# DATA 9wuoLde4udE/4sufi/LUaGBW9/IXOCPv7exsbZf1vJQCUfxrHMVPRZVf8edfiOf02seiwV/6Z+85zF5gTpQzHS9/LgfwR/H1Y1EK
# DATA lujfxMRRMejsF6r71py9/HlizjDipP2umKv2AwhKuQu2ovX3V3bqOHX/J2XxcICi37+Dr3LZv4IZEA+B8p7DeMnAgoODTuAjY5AL
# DATA txcWRNf/l6xWzjh+fy46Lkac6LC0ReqOY0cdEv367Ncvfy7WlmjwPGQZYPdw0nAy/8C9+jWO9zPxcfF28P3+3dSO6bSYnn6lbZ1f
# DATA iw+/h37+VJR7UcJfsfkvgTBfyO/PeRqRAKsBqLbj6jy7G0ZPOkfjAToCJjqHFMpds5jF/6AWRK8Eqf4GiMfuGTb2mZjNn2LDH4vC
# DATA WJdYN371S16uL1/+AijdrQBp9I84kl+c/V5U8znOROd4OjJ7eZrOlCUbRO8pzaGF/HD276JmWKbngku8SDAOz07hxfw9UiDsxH/M
# DATA 2Nbi478EZ78Ta/ITpO0vcSW+EKW+EuTz4uw3+Au1/UtgZ6KuL3B5JZUJrvZzUaXoAvwqfhNE+UkFDo1v/QX/TQdClDh5tW0siL/b
# DATA y8v4r/hz/l1aWl68LZ/x87cXl25/K1j4JibgGDRYoslv/f/5d+3atdVoMqVQ3ChgNx8QZjmvqDYfk4ouehw0pC1LukpRoAEG7faP
# DATA 8FoolaryO1VEKjH5DK4h8vMonsNIHDCKDPp7AT8GGV0WmajKtGSmnpyoj4ITjUFMn6MKWciUFdKVtGSZhtr0MC4FeDFgXbGQqIdx
# DATA PChcB/m6hCCXHJa53+kP4PrDvK4WigP9M2A1gmX8BNmKZClbdSFPAwMTrOvFy79npgUcj1kOizVw5iL//RoKigOGJB9LFHqBPEs0
# DATA 8QlUJUp9gSfk89BFJjfkVjH4QjPkkYAnH4wFEvlBaqwaDEnceTrjKYxmdDyFh2SzU6jGtwzHEcSRJvV6d9TLyiLmzJAHSblCGEfS
# DATA HVBTYHvc6U8Kh6N4ynAO+qcSJY8xly6uhcqjjvyX5JtsthBvg3dX/xHF2OCdz6iyyFoPUbGBmI7XIutVO8Ya3MC6iJcnDrgxAVfh
# DATA 93B3uDvZXQhnajpJ7kf5AYiETzoppomTOUCZCGQwkEpZChNHOIrdL17+DIgB5LRP8RVBJck8w2MDSQBGlQwBX1xYWg6u4z8zO/wf
# DATA SdrjE5YpWHUeTnLZeTG2spTeUCB6YUpo4uj+R5DRggf9uyrVW0NcvNGXKIhHLjuCpY/+7hgcTMC9GpxQj2PGLJUotmBCABqqKAJo
# DATA E6GLNcZP4AcpntINf+8E9OZFtdDWUwoHYT4QPrm18B20aQ1H4CkAn9C7IRqiZeLbt5fRRQUZhWpWjmpT1LK9fV/Ga8RBDzMWIaZl
# DATA P8aYdPC2mTJu+h2xTUDbIhZy+ONoMpKo9hSeweVpx6qERXthbxTFFN9ubptQuhLOHAnsHfFNbz57LNnoIr6/JKf0khEIXr8FtghU
# DATA 5Ii4v4G9ALRFF6Pn2c6PV1G/4gMwD7jLPWdFweJCes7QpGD9JsNebbPJVa7V5dfpHGtlXyXhOgGCMl3X4Mb4KZxSxowKbiCePMeb
# DATA xPOEiJ+DU34jveCEQiRLxAMiARAfwK5myQ/8nY7IH0s70ZsBrJMMw4+DvdH0MGhsr+CGra+uba/cEQcUp0g5Aic7/PVo1Dse9BEz
# DATA xWBX4+O9Qb8LiLYJIhA/CTZm0YOP3zAz89Q0lq+LnyQ9jTuQ6oKsqHFclXVKfqlddo3OvVFzGsnclb9KXOn1uQHHgViGr4Xs8wkK
# DATA O59IFRPqvXxCz8ufSk9GsHp6J0rvFjRQ98jY7sxVpReBIFNIpLIRdVWwGCxyezpqx6LgsBcXsEGZHKpGyaEWW5B6UBJGZTh6XJC0
# DATA UTmedosV+CZ6cTQuzOBdKO99EaD66nOaBb4p+wQ/uPL+E1x6vyIt4fOX/4A3e3Htt7PgeM5AFYYxPpktcBkGpDTZSx+rFxPjeDkj
# DATA sAhJDAknLGI+hDpihYdjFM6N4HP2P2nqUGT6DXYqdmQv5ChK9jKELKUxERP8saDhL1G58HmY6LrHq9bnR2u8kPCkhTkDui6EkCOp
# DATA eyhOnMo4OiIzTP8RJGyEryygDHo6H5HpRYG1GEYIykMoW52Hny3ojXPlqT37v6gz+gwP188sQQ8EQFueNUVCd07F63/Ay42aVZQT
# DATA DXlWDFAiZI8t+Yx6nYy79VgfbHw4ECDFBP1Y7HmcJOIMzpg709FRv8ttuROn6rFMCmxFyN+sGJobuJm1SgZiHdYVp8SdjWUoGGcx
# DATA skkvPRgzMeyxM043jssujK49srxMhiMTXxKqHCTF4Qu62CegNhzDHq9h/Bo5nyMM7X7/SS2sTAdxOfSsJsLljuLKfg84f8FsJHy8
# DATA F6J9RrD0qHPkZk2CZ2z/SwzMKLE/OI4PnUA6aC8+GXYLsowYw3BUMOKhR7HyaqdFxzBx2pcQ6zcwhoDcDSXG1LViHq1g0+LCUTQ9
# DATA HPVKjCTgILCZKaqpgBWfJTNRGzdCeJK8FN6++e1lz8/Az4L/EiyMFt5+O4vHrm1sm32uCl4gjvLfKZuBcfUDbrq+sa4YR4Cqdmly
# DATA QLZwW9ypHMwpU5VUIawS9tjTkFISQ8t8lVgHnPTDg0LY7A3j1u4wvIHDNJwc5HpFA8xIDEkQlPeneEe5ukWTo/6UgtcLT+GXdncw
# DATA Ou7tDzpgGR/3yXgcYsg9rRsZ81UhTvhC7x50R/Qav6WWLuVVmQKA+kkJB9xOREec5MbTORADjUQE5miMapU8ZLQEkp8qbSRbfoRe
# DATA HWJGgcXxlwl/UfkbqJIKJWyfEQ519q9AHMr+SVQkjouXPyMB/ku0l+L582u2I3zFFzpBg2WlPntOBkEoEjrIYCbcmxwrA9zkFin+
# DATA DUn6s7Pfi8bA8POxtmP9FA88YzNY7TO7u0gQjsV2qTYIcq38aNQfFvbDpx+dghn6Efi5k0dHyZp+md2hgrB6mHuVeQ34bBtSG1JQ
# DATA KZBsJ4cg6FPC2VQMxiTbhxBbMUIojcSQk9CABqzc2C23bnxPP6mY4IGtp0slSByJtc0WX9JUtrRpNE8/FJwB3YRDDjGg3oY38N8b
# DATA IUYTINXLgZhpQnG1B7FGh7TPXF15orj8OP+oM5kf9Pd0Kth58XjekgvTChmyoswTo7goNX1DrtQNDKEIb4jXboTJSAo7EMvIO+Nq
# DATA O4yxiZpjUkfn1544rlbBjRqylBvAxYi6sdpi3u6WZybOMXyBzLuGGWYivctpj8BtbiJTvYiNgLXrFG0eEtZ5NDrdo6jcJOJtNRXi
# DATA JYDtcIWzeY1DtILroOfAH+Ce+Akyuz9YzI77RGIBdTYZoa012lgiU6N9js2keCAacX+LV9QXwcrqg7pS98ZoOxaH2TjqigsiJLJH
# DATA ncmTqLuNSU3+7ngEboIB6Ex66DLYnZJuJj6MBgP5O+lPhCDYGdMphgPRUYa7u0BDu+IvNGIPr9HDa+azt+DZW29xDw36oORE3GH+
# DATA NyzOS1q4EcowPDtBZth8OOxPhayxZgQUNCLbkLZzf9u8I+8OV/aFLFPjmKnyCETEiB3VAg445tZ2hx904LTwlkXeZHWGI1tEf3bA
# DATA H18ISfHhSJR7+KATf1RbENLd7lDNfu2aYHQ0pzfCa7ugJOKD6vby8gUmCDdPrumRE2NMithXYtI6AxhTcwdqEm9tDlc7Qg7vdSa1
# DATA 62Xxf8HCzdLirerCQhX4lDX0hiAscW7+OOqtRYPOyXbUrd28DaW2QCkfw2WgNhVnLNa/TpbNFs1u1Lt7UsPOx2pinbnwRJhcKLgk
# DATA V1yJRGOggJAxqvRMOUNBBWAYAyCEkHpveqiiHSdSkjVcPptGRISplRZfWW9ouYTSqY7xIJTpy4q2iBlsTwVfwUcctJnrYJwMprih
# DATA rHHJH6VMy+GHNZlZN1nS4vzHE5wU9y1QWo39ERqOV6eacMMb2NV2dSrSutypWPquTgU1Xh07Fhr6ZLqSJrx+xyeW77FU1c1uxvT4
# DATA Pl+bBgkZTRs30E5FCoOiZr6FdiqmCO2v2AnwJEHTHAmLmmb9Fx4GkXfVSswK86YObfGRTkKfvy3DMRrQxuQpXCFgwuRdMYVkeN/Z
# DATA kuibwfejaIyWSokAFMijGG/ckNN52B0cA9p1AJ4Ze6NpGAcDiOfnC0lcSWbJbobTgYzF5G1ZNSbT2s0UM8mDMo3hFS0UFHnLW2Vh
# DATA X5pl7HSJdBDwNFkwjn5lEwm6RhLe6SD25PNm+QX8lAjyzBgJyi7Wr9BnH0qSV2Yh88LXL39G18eX/0KOGXjBROM8XDDFyeykgCFv
# DATA btFk0+pMq3jH/Al60srhjT3DSdrvpQxHd8Jh2VKMXMiJGazvPyLID0zgySoyEsnEy4/6cF0x+IFOOScxPKJgMDqoOJ7v4dm/G44t
# DATA Ykar4gJluAciqJ3OPRm5idFZtxuaLjHs94cuNusb6yXtUCH+n83tEPgKA6kZqbTSfRcX/7I9/VLc3/Yftw+OO5PeK/QCzPb/W1y6
# DATA dXvJ9v9bXLi5uPDa/+8b8v/bicC23Zn0BwCZEIOhBfJGMpLPw3c/EFIsZlPl46hE+vf+kJKOgiViQgmGT7JcAPe7w+ngHP5+8eHx
# DATA tK9eoLCT83kA8ndA/5EKLnTYoUCpGX5z5Pbn944Th7/jKLd8K9vrIho+qj29fn0UVzhAUJyv91fbK/fR83zVUPjO9LNrkEejcY6B
# DATA j9hvyar58mO4betAghfS5oZRDeK//wwPxStiWe8EHn66L4Sux4D0dPYp+MigW/5PX/4ynOnDJ+asbRyHMh+EBPE77KOZ0pjkLbTd
# DATA WPhUNlYuW6/hzcrjjmDQcrJvLS/kgaSkN6egrB5Cj4rpkPyeRhYXEkD1Rud3qFT9ydjGe9OVfdQfDFwoRt1KljnNNqTRLVMrmKQd
# DATA J1U7naSPbP00mGLR+voJ6tCBHL5UcTaCTLSF+xKWPHHMeC15YFQj87dZP444n7XvL8vYN4n2RqNpW7LTgpi2EqvIulNxPRKbTEg0
# DATA I0j/XmOVS0L1W4a5ljWABHQ87E9rqQqaxIuIsKpVWZryqN0rob0vLD+MnBTI7edyrzjqTD5CzTq9ROAphDkRsuZxB/HmxHSX0cHr
# DATA R6M9scHFoAHdbjx6LF4ajOIYpm/Q/yiSikpxF5tOOsO4D8ceXixdzaOYxcurHZkTwNKV0lRkuFC4CZ3TW3RDzJrUIUJ/lKrQytkO
# DATA mR56fcrKOT2sox9FTSbIoBksUlqj3WGq3tCu0dQcAiwbz4qo5FrAOVPFWdjZG0SGlnFrFE9r88fxZH6vP5yfHAXl/SDRDauZNBUd
# DATA AiuVj+ECZKjpDG0lesQbGyqkFNqC7OGqL1ViiVLU5ZD2UgXzXFvrRL2ExAsoNMlWpT8PH2UUK1tl4pzBClAoj3rygCwFFPsrusZh
# DATA CJGYPnEP52+PD/vdwxrJTBX8UpJSmZk4SrxO2HyYfYikIT5KsTbxo/wEMIb2mU5Iu/uPRSFsoRCKL7aZQTxInOBcoX3Us0NzjeYa
# DATA +ZwEnGkl/fHwhwq68sVwHFAqj+MY8krTlFsWiox2uZ8ZNXrq8/G2//CJVOz49DUH9f6WfaQET7sjpWcjqu2PFFJ79hXPobSFqOnl
# DATA B2UxR1YRQZRuIfHIXglZGWtIVKkZw+JAQYdrS0fpT3FYJFqqh+C46cbn0lwox4/kQHr9uDM5agP/BQ8KJlUkOvsMLPoOQQZ9Fpsx
# DATA QE2b5+jzon8y618RPEbWL1OJgWwBOjdQYUghuBKsBCDHCQ4mcUYngFuKfrygqhgEfXbAN1hGzwWN7Y4GA8YpKpfxNMa+EW8vlwX7
# DATA IZqrIbKiZnTiNzxhIDHHWFDPSW2l2z2edLpou1gEbRltHJ2NWnKqVtGbfELuNOMFWAjjjVn7JyHbGBpN7Ky49x2J+Xp8GA0Zrp2D
# DATA xzr9gaG59HfG7r1pUs3gEjl3cRrJ622LbuHshfwTsXlfQBTppzZtn312JyD/JPRp/lxaYFNFGOQH/IN8+DVUAWZScIpGD0gLzlXt
# DATA jELRni/zSGIILtwDAPSmbDqvHOosJ6CX912mpRDuEOKCXVM9atQBKHqt3siFocXV0JDiCn9tLlZbCtJJPqsutkDtCjj1YYv0iObv
# DATA JsuUtTLLpGAxrmah5ZjNZ4m+2unt+dmv0cEdqChpGf9CafmLCTe+cF4suyOggw9BZTDqfpS4l4EjPCKBDPkGKb5ttlcb9ZWd4Bl9
# DATA aax90JCfNzbf3bx/f/MDS1Ih/HshNk6Ox4AoI2E+9idwe3EcWxFt3sEQWd/YMSFEsiFFkrAiEkhfv9Fev7fhKm2/H53sjYR4tC57
# DATA WihmI5ucq1d+oBNjVtjwPftaCstkzBkowMRtUzwswH9K/ATwSdr1H2RophOyoMb1uryFITGZGZgroRJiUMAR/8Nw1jvp/O9rBBV4
# DATA +TOMuCFe6ddGhbbZw9xOhuHjfPaMDMwYv8nBbFUZHUzbBQbz/hOq1X6eqkPzDFBKFOGfmo2BUr2UOwfgiviKTACZ+v/FhVu3l2+6
# DATA +v+3F17H/38jf2++oS7ekIF6fDI9HA1vzl27du0+p+6GXDpEJdJJrQL7hFN9UxpvzBGAqGqQGWAyOj44RIlQSc25DQOHnRgMAurr
# DATA UadLlgLAT0E9Bhw59CPofQHgpAExwfH0PcEaB1cBLyBESPUZXK2m1Gy68QF4hmVtwMaOJwPRVmVCvZNtcmdL8DMcHHOqA8R7jFa0
# DATA wwNC/Hp/YdTwOcpOjQZ1tte30dVfSHJGloG51fvrcGPCNcfc7KRykRJGOLe6ubEjBLF6AyCrdhqb97G4LYaAMnUyGoRz2/XG++ur
# DATA dfsOxlhvSDFKjTj3cGN9p93Y3NzRso3PWWxu62EDkmBAKs+UOsuPFkXLOyv36tsYIoVaDM6P0hs9HqIiByOlKE0jo7lS3oiQk2Oe
# DATA 8AvgzNEfiqVk7Nf+vvylK8h5KF4ozj1Y+UH7/ua99t0Pd7BJI2xeqW0pCdNkdCDmOub8MhO50oKgAIoQ8eBLQfRIh8eIXbEF4ZPx
# DATA YbAHJjaxj8Q8jKlMXOL8GFIulWJ0jNfkzuOAyVBGgsMeo/sbUVwNlJrtPuRMxAesjKIrt52iwspEih4usH0U8DSv+DyrTYyEfKyd
# DATA YRcO0Z7MYi07IfUPulCawsao7yCSgdC80JDFHuZEp8XhLFS06gTHDlfMqJfU3DxEuknmx7nXqG9v22K3M2DKMiLXFVUKclxO1srh
# DATA CNRiGAEK/yl47t+yGmuGtdWAJR8AEN8YTd8FcnCiyYwKnoY4S+ifQ7kp8F9Up0a9FYDKFj2CGzVSEgCSI9Y4Q7nEBiK72CeP+iPU
# DATA xckGmlx7S6EXwEuCWYgtFWEiF+BBglBjqQ0B/D3yahIEC+ZD7QsFG++xkC9jhVRAa1oBA/KTArYEEbTWU9mpYnL0TWMUraYsCK5P
# DATA R50nhYUSLkXZHYuemVYxUWWFOAv1pcYzar9WE7VyKnjYxriG4JQGIQq7TxYWyrtPFvd3n7y9Lz58Z7/FScewbFHcQZcWWnP2IHhh
# DATA oN8Fz9MbQfNp2NHriDUBGj0xESoovuO/p61is7y0XHXb4Dx+MGjRjKhozpf7DrMC8js+n1aqxeVu5N9VdRhOkhfYjvFYLqGp9SdL
# DATA 9e6X2RvU4XnGRrVvGOpOYXpYSW+qYnof/TsdyVY8d6jY2U9KezEeRBxtpSdsfIho4+z9yUVCnmA45SnFteqIzXqTXDVh5QbQfvAN
# DATA z2TxfMiKoYnmYjf3KuoI5PaDQ5qrtDal678HkKfE1AXn1m/jbV0+pnlr4rxVW95Eh3oK0B2lwNs9Pj4qqEqbWGErs27BHAozeUQx
# DATA mawTnTNUJ2rBQtXr8uGuFefSGqBJESwvymeu14/Hg85J0MGIug6kOAiuLQQMNnCt4vofZJOs4RWYSAYrRFWDlPXhkSBQeZCsw1xB
# DATA 5iMk6xvBovxhVUw98J1BNCzQvPoSYSDpbk8xMYVVllO/MfnjBRubcBMjRZMu8bfFhQXPO0QA1LnrWGbebMXtUmwci8aW0Y8pi4Vk
# DATA llU/C3UqjQadcQyZQnC1xEsWVRaMdvYFOcSH1BDJQ4+BCL09weOrmBgBRIQfQUcakrqMduUj87hPHimngp13B4IULHnIcLKUymJB
# DATA LMT4JcLHYHTATJ89HfjMhayjkOzHk9NSchXMHJHMqpg3unJ9iI73CsFLVKdryZHO7HwJzFgGNLO2qPD7/Z5fvfpBY3Pj/odSp2op
# DATA W+s/WL2fqWxNIBQoUQz4ZDLPZNVlrKo8BOVC5+GWYEWfuUulF69CcEUy7FI9tlJ0kt+v/oWCxz2AA7KMlYI2DRVBzEh3AEmA93uu
# DATA H5TBpbRqdb/Hcf1JumwjdRfoAsR3K4jzmOogUL4ckbRTCJsgI1BmuulkH0/w8K0Py28dld/q7bz1XvWtB9W3tv9rSK59lYMjOuNR
# DATA jGihVwLdQyDpFHyjpshLIlQRteHxdL/8bYhGhZHHtZDdPKQMwn2SnkfJYTEaE1NaZOxPm2hyUeXK1lZ9Y80lxVQHKzXdoFGlnlZd
# DATA B/iU+Q8ZyZlsQxKeWymnIR2V8uygH4t5axY3cAiTBMQ9uDJlU5jBxChzm0S3SrAyuS1SpxgnJ5UTMgP8ZmeKNwj8ZPFZ5lfZU2OK
# DATA szRDUmlijA7d3bTF54o4u3UPB43Kw42V98U0rNy9Xw9TWbDsS3JpZpm+GmvmLpB0r79vIDR8PkfDiYQVwaAne5WPBA9gCCT0GwTM
# DATA DCrn8Rt0nFAq2+317Ub9XkFWIrE2UqNYcsyivgEcD7sdumiY9TPUh6XYso1y1Ps4ij6SAk3i/bL9vjNEUE/VZD1w2yjYpT00mmrA
# DATA yR4xBQPjiwrDQY7brAn6I/4LxuQpOr0V9pBnN5fowqJKNKtQbCKkth4XAQGYCoHrN9fD4GHprD6jN9GwxzcZmGTI11qYhGX4A0YN
# DATA iAZB6zpjuwffr3+IP4Xkea7neS866A+HKRXdrd9b38hdFaAXUJ/gyEdAD107KN/wR/K0EHLBd/Wv8plDrzxRYbNRX1tZ3amvBUYf
# DATA WngGixJNrhewnYqsvhDXH8GjYo1pZe15/lUCQiXvsZZBi26vTUoHIq/f51UAqOuTmb24FjyVLVLuy5LijJzZVH71ZKxjMYeS+Rk8
# DATA VT6Sl37QKkNTmIJQ/lg5GIz2CuF1qdRoVm8vg74IC6lS3pZjIaEk3r65pKHDqEkQP7nxDG0CgrjYqgR8J8HqDDMrvkNXHkOMx2Pd
# DATA w++M+QY3EjJrYBVN4/VWsXjlF+V9Kze9IY33o6wp8R5IvpTDFzqeLnNEpZ06qedVxjHE+BzT/vA4mvMEuhhJoNP5f072ad6OCC0V
# DATA abMCzBnuRYLb/XA3vl54pxo9AePYbnyj+E6BIWHaLQM9pnW9KArWoHDlevGv7LzPYKypPChW/TofzVmJ+zwDOnksSP0Z8pVnLOU9
# DATA 04GRzwBj6Z2PopNncGSCkgxilp/FncH0WS9G6AAYTHOxhS2vp8yy3GJUeKlleLxhkuvda7thWPS+KjoOChGsoRj8dS1YrqYGKDk8
# DATA ld5x91RCkExsGKoGUURGoM0oPKX+I/oTfoKfmLt7+AKxATyAnK6fImZkbQD57RnphW70xl6k8wb+UT711FbJOIRaMgaFj3Gpwi+8
# DATA 0z8qFjrH00OxxX+MqkRBKM1qrUXEtScIIJo8EwvZ7xaBxna3AZNmEu4uGnWbh6rbQshtiMqa1wTPemd3zyJO8Xy7vtqo7zzbWtne
# DATA /mCzsfYMs6Y842Oz/Y44N5+JAmv1jZ31lfvPVrbW6dnKw533Nhvr/3UFsgsV3Uq5MTWYYvOHu5PdYetGGJ5vALOFiuZuvLvduv6O
# DATA aHWWKPPsr4phKVU4yOrG7l508jfGIE0IqLTve6FNA1n1FwCWR7ze4n9FHTcq5db16vw8TF08/71q60aVPrVufC8xh9/L7v2Txb3d
# DATA ZnOh/E7rejMoz4v/fq/836S1KPGehPTqHnYmnS4EWCMwj/om9hOWBAWp+RDiI6YhyG2CSem3cTPdXArIx9H64Y1asLj0dpbIqgS6
# DATA Nb4uBpz6Mqao7048JST3SrBzGCmFraW6I00leI4QVju6VVQAho/lQVtLLW9+4iosP1IC3CnphuENgByRnYVH8vMpX24HgNg7bStH
# DATA lDb7qRS0Bb5BRvDg6HgK3sfBfXwFMehL0M+hYEdT7DB4T5CTgPjamRLwfDDtHBim9/Eo7vNVWUd7ksjTqD/YWFmFzE2N+tbm9vrO
# DATA ZuNDSq87nR51hvMK9aasuuvaz1Kx0QSdzzvfgTZVd/IZxRv1+/WV7bqK9pRmPXZaKWjFUyjzGYmTrnIgpJLjPXCpnccW55/qhk/n
# DATA pWfQPK3FO8qto42uG7Wnrpf+qeEETzhlce1puNKFcwjUIuDAAQEpgI/6aNjj5m+gRFuCBOii3vIqGwirIJCXu/As9MTohg8FFZZX
# DATA Dji9tF4C8x4RntKbhuMne+8UlJOHkTIDhLBJFI9HwzhK3ED5OclES7dusycJXDHVWsPxJ4qDVVyXuNAC4szbaCZQsUlUxjGsUtQC
# DATA 6uVFKEZsBRwjVsOoHp0DVGppSi44rYoSfPSzr4hD5o92e4Kny/8An+wcONGaE7vN3qSzD7aWfoz1YYbKRKGxONFlhmer5EUGznkd
# DATA YCzghW6FffEzZkiyJIk31ZSVMAUi/6xYkyKOXPy3+I6YHrPmGYN4v97YFlKDUr5N8N49PRasu3DUGQOiKtcnQc8hIZZGSRqeFOAl
# DATA oNPF5beXv33z9vLbZMmAp+Ikwiov0heeO+rSjaCwUCqKfVBYDsq4O6heHTZrudNUMy02/muX16cbNeGTFEBh1vhxgDBuZ8DOvWXt
# DATA YsSVlqi6uaZhewfy+TFVsfxv7F4Lkd9PNPk3r9kWTzjWwdPKnhTnolRQSiM/f/hwfY1fRfECP+bcWX/7sL69k96vWDwam24obRkx
# DATA fyROHfmNc8UqKODqDO83doDwOIHNGbjb4rttIhNjztI95VeIP9zYXnm33t5a2XkvtHqUz64pCyesmkmvPj1nipL0ZBnQrPQMtccu
# DATA GpYunw6IZRCJqqqEairXkmk0pD43F1qO0o+CRdEsZ2bZVm8Uia+vbG216SqFYrUP4ws8nWsBjYThs0x9klLUWGMzQihAD2GrXH+o
# DATA W63BFWIfED6f3l4+lZoG1jAkhyQVAQiTS3mADABZZiNUGvSuN5cyiejB+vb2+sY9OQF8KoOWAjBfjzrdyjB6zNUp+N9SwF63Jel+
# DATA XYkPO0LyQGms1z8A0a/o8R1Lp/uSEN9J6Vql5k8dFG9ZEdBUwdy4xUQeA14hQ+qLTQRBdjFWyOBNCTgI7oEYqq1XDpxXEHWMHdkF
# DATA J2FMwEL4aDQ4PorAEbhpuQgq78gmvk6qKPwEyZuoxv6+V7lSMLYAlmTmTHmc4IGUkRA0EV2/Eg7YwGLy1q4UKEk3btlZeZBXw6KQ
# DATA SpZaxZah6VHbUKzeyRguXuFef2hCPBIgHDObogZ8rCabZPfqNsQJiN+BVZ3O+bwXTC8DOCqasiMtX/SmRe/cVPvB5sONHWj43fvr
# DATA qzueZGhcvWO4w9WTei/Zqo/S7aNFIgIbDcgpQb276SWt8lOk5SFPeRF2EPv0VUkuBZ92dBEUq9LvIRwBO1lW0Zx73rxPvHScd1tW
# DATA EoSoieWvp0nAVwDcjXptPkiNXPLSHl1MRbXggO3CDMxXUBKIKz4QNqT8DQrEX1BvIN06JbqFi4XrAFIkAW/jPigmTIxbFQDDwS9B
# DATA +S6a3o2hUXSFb1zoCEIRsfiSOTvwE+o4Ep0C8A5oejQss2fC7pCfISytDcebH+vCR7o68mI+4ICNEgefu0ubSB2psQWSUBklwo8w
# DATA RJDs1xWGRlguD0ePxQfuzblrmtBMpdYgLwUIkCIkWNDJT09YYDQkF0MDBAC4gHk2AI51ovKeCl6Ih9odSXcQ09npBVPAjqFjNeqI
# DATA IxunW+mAUkVMlXgg/eDMSENgiZpSNr2UgCmxNaktD6PScRlaejTBXjMFM/mMZ1ycA5EpN2aJa9yxm0vBd2u2AFQLlhe+c1thlh9q
# DATA mwLrRgnHeHeCEDuoDwL3/LBV/BOSm2TKhqSMpHw0USNVVTHZ7XZf7Nh2W3RhsE+2ZTNiWTyspJOdKqKvOPoN856jmkORC9tKOsIb
# DATA 9wizTvfcMyrrPIq43wnVhDUtWfXxu058gg5ZJ31pL9lnNGjX3F67FndOy+54u/dlaBdDz4IQAF7aFOHEhv9A2c2plGCtsjd++AmL
# DATA 8DY2d9rrG+Iifh+8wXTTUk1ENTdD/u6B6UiU0NMCDl1MMFJNCW4A5n14dryYwp0DZ3pfxil5wcSJJcpJ+ABkxohdgaeTtA8Eclmk
# DATA /tYN2RJTEmaAEif1G2MOBkpRxIXqsre0DOlHoHg+1y2/usOd1NTdVgihKRwfLo0b5uKffJ6KV70ATseyV4Hp2HJDVJvU8EXUdI2+
# DATA LMmtroE8ncjZygATRxjVFi2/a0iIQ44FUIXjyOQ6ecAfgMXlWxuouinEdQzp8q8Qr5Ko044DwjBHMWfHEV7AZMAjXfCM+KOgrN81
# DATA AwkWQPH49tJCSpwKvMNxb9hiTcZPsi9GTVDoTr3ReLi1Y3Em1WUcmaiFYMeFBFVV/QCkcDOxgEl4YihmUgMerrp3oD3sAFQzoQMw
# DATA PjtA0t81FTBlGRfHHJxCa35qHFfJ8Gpmot3DzjDJPVFnjASAyB5kQgCFcadLmDheDiN/RJ2pwTjTgrmy5LqtNXAQuPtw+8OE/+eJ
# DATA L5CKvIeTw6wA4uWhEN/6P47MHUjjLvoWw1fLGv6T5tKZPhDD1Zl8OslH2dz0bXI2pOUgzqxoSR1y5z3ZdKiqCi6W9wuJsmRcOYTM
# DATA fjDp9KIcZ3s6h0eG4+VUYmiohDDnnwYqJIrR43avHyNumQW1lBgIhBDKfiK7gAaJtI46Q1Fdj2xeSKwzx7G1cq/efrB+r4EuJjic
# DATA 9YbFE1L3AHxN2QH00yulf/Ymz31yzt48hjrQF8OdEp+TPHtrGWev92XNMvHgVl/TvbrOLXI4DEK2P3tgFziw7AqcU+u7GafWudY/
# DATA /4mhHNlc+YsOCgioozB7vQ5Vk/UYi1vVwrbW1+lZMWMRjTlx9W72nvREbDv5NVIpNkWVQliMmUiFrFMrI8wbgAEaAIYmNMeBJWX7
# DATA tZDiPQViqFVbVKH6gdGXHnSegBIMaAAKuOo5fOkuKH9QKZfaHoPUwamixb4SS6eQKSuacPvwoN8LJaMVj0B0UOeJpV2yHD18xFa4
# DATA IFaVRXgzBDNxXWzstFUEEctLtWSo05zf3VOdLDlFdU/BSVjmm0+59fTm7dNdLuiL6joHCadscWvATqCJDIYCgFpbWIBFtmSFCwoI
# DATA V34jPBdrvvAh5hzKxeqMC2byGMtzdySjfwLEAPQjzPTSRFDrMbgHOmopGdNWyEmlRbfCdncScfQTSiSzmSVF5yESig74M/YL5LZh
# DATA N8R8GyJJ3Xa/gKX4WUBTXYNajOokvhc9AklqhCFuGrl3a+b06ZNLwX0bS2iIGkX/te+KRVc1+1p+lXOg+9LyySFXIvFeSvK98nvE
# DATA pcQ33+GhxLDL8GRyjPJEuKq08QTY2ly9v67Hlky/SieuVFUirg34hIatjNVEfwiumNYyrV7ck6ZyQX1u+U9CRza6Tklf/DLBCTgU
# DATA wAT1+sOa8eZa/f2Nh/fv4y8gF8j9R/mm1FefCPH24sKCXwbP2Narmw+27td38OS3t3Y+etDQMlKe0JnSzxlHdTEJp79vMkE/OXGA
# DATA PMEEzJ4iGS4vPksR5EKCFe73za0673evwMGcyQD1aHnwgHLsMcvacpzQZ2aq1f3YP56LVgrICOoGby+4iWswH0CbtJs8TlLX2/sn
# DATA Cbye0LmzOGVXYk9NB5Ma1mYYe/sxo6PblxXoQkvvpFtFI2MSgvN4lW7QYpLgAJ+nJ8SggG4FGqBnEHVEDwHObG8yehxDcmLWWgD0
# DATA DFDANBqcVPzcMk0dknrhT/8xl5UlXXCzyMNjiRHTZSx9NdONxNpFDFvP3ik5tMigzZfbpmYQajG7TRwyWhHt0ymZx+l4MuHIQ3hH
# DATA mwXPGSJaTKvWq0u+fp1zXoadR2Lw6OZQVS+xazk716guabcbLpi8yCpcM1HIBWEzZCyalFPT7NeV9x5INuWGypGB+X6C2sjOjIkc
# DATA 2+1CfziMfEG5+BzjRBnugFylpaO1a8NlHFAELC8lQcgtwBwXJAcm9IZHbvGK7i7Ctu6ng7MtWisgphTMDQkXxu8bd4uZWjGvwC7z
# DATA kEHDQtRa30zRMtnzl3m6WdNsUZ2nU8nbDa/lE/QZwLpKwfW2P8BVN3XuHnP79/F+aR1oSksvfR2Sd2/6pY2u/CXjJq5jKdDRpJR6
# DATA Nb+41jlF7TKLvfoN2bN0uZaG4lL6zAta2rM6mNq5WeiCFxqAcmyiVQd3HrnaLsPO1xS4T2zUP6g3nIbeDDaHkcLURUHjRyMx0M4A
# DATA +HF8vL/f7/bRsQvi+mSMIoRogdYBZqUjLnCH/RhBbRKh6CZQl8nxGF1B4VFKmIVqfh7GxG7BdDXBBcpAuSxWy/iEa2+lhoBfHtkr
# DATA G+Er550hpd4MpbvyfKULk0+RLl1ftbbd9Wdl1uMf04UU8amSyDejfk9TdSdU8n4HmFKqGn6mzv6bUc2bWvk/FRV8Lhn3KhXyM5yX
# DATA IODcKnQuNXwmAV+V8t3Qu19E4+7qrdNO9Ev7neXCJs/QWfeH+yOfZp7DSrPgwnUkEiEA5a4jPjynnht+N00IPu36DJIrXoniHHvB
# DATA 2vPZJHzFivO230ZvqDWJyg6qOdVxqGnSKnaesqhHzJfV6tgb+1RCNzAg/Zox0/7zm6LU3KzRBojA5uYOx+NYXFSXYEHsbzbvWuek
# DATA iUOAQczt9Y13N9vvig3O9QFlF1PjSTwV1Dd2Gh+aNSBhOw5czjLRmQ6LpHM4zJ3r/m/vTzsHg0F8euRmroizX+nEPZTb59OXP8e8
# DATA XB/DV8uDIeVeJFMC1jJgJnIpnkm5LQQA6F9ZhqU7unJVeQsjCmsQVZgn5GemxhppmdXV+Nl31n4nTVWtQQa0KRHpJ6U0eqb3NExA
# DATA k3iB2iB+JCTlDk2v+ysH8xwpWvevvS8T0+hleqo+nlY5sc1TWeGpCvEQr/Bv/g18uju8pkIA0vvhyyptHEyJAQXf1Vchb7vFc7n6
# DATA yI0JF6RGfWXtw/A8XTnXtewC1zPLwZ6pQC2OZpVv1PTqXdDRyQRp8LSObCoRZQNCgfpl1s3ows2/GdwlrTK0Ryl2ERf/qHMC1y3M
# DATA uNQJhhHgxo8pS4zOs1SZm6mdVfTME1rz05VU0chSkgyUsIvVpbPBV8Sd/1UzYyvHGmSVq0KuTsgz99nZly9/EdBJKntN6WDy8V19
# DATA g9nrCMmqZBxdhhVTAjz6ubFpHPym2HIqPbvbFbaQf9nPRdCMzdF+sL79YGVn9b3wMqvMiZVgkf/97NfJbKm/x0ypkE7vHymFYDhj
# DATA UWde1/KYPGeJeo7ZNVvI81edqvOhdj3ZTpJOP9mpiIozq3ez5zj5H4w0Oq7D5ux0Otn+BX7LgJ1oBELizBxF3l6fpojLFzDsZGqj
# DATA XqkR/E1ESeOrB2HIQBBhgBr2XrB3QjGm41F/OK0EW2ISIJA42EJFy/wwmsIl21MrKxsgOnVUwvuNaCPojsaQ10wpOnv9zsFwFE/7
# DATA XVBhTkd0vnRlWvQLmexT7PFtE8I+vxrU2A4zTV8X5kUJ8iffZm6ZcDj0oZQrvD6Fp32Vythk0rK5q6TnBC2j4poWBQPwtz/c3qk/
# DATA aG+trH4fMqZIzyZxEdx6uBNmjdSbN9XYA6t48mzZ22DYIwJwjPRv38pqCed/VsZW45iSCVv51utVWF1IvccT5wa8OYnQL+YfkkuC
# DATA guuUVLwf9WMxCQc2+E9CpZRaWuWAGfafbCP+YsHMcVnZOaSUiAcP+k/WhyUrAWYFX0JeRa/K9AAIDNCe4quxqZwBbSBYe3jHuS4u
# DATA 4jQYUjR4Kej0erzf4+Ox6BVGgqgXi553AL2Fb6eFWwmbpKduBR8l+l7AmHvuC00J5w8t+NOKFs28A8QOj0SdohpWdSbMq9YmJESC
# DATA 8eBExpKJLVBCDDHnrb1R78TG1cBC6sbpsUdEw15b4goWoFRaIQJTLISrBKFZBkAMmRFTAip6lJSeCiyIxRJCLCLaQpi36fvR8GAq
# DATA JW4wZsG4XX9TfF2/HftG/xgN0yRiYB3WlB/i4qXRnxkYn01UJhyAFs8ItyEP8rzPFI2wAiCadiZRm9ECsDc8WsZHMEGJCSJB/Ocu
# DATA AhLjzQdbKKZbdvHcQ8pbXrgJApY0b4Xvbjburq+t1TfC0xwqXnm7kNlIwUfzXn2HvG3xF1IzQ75YkiPCbHu47tgSYJrRvLEvnD9E
# DATA Nkf7lI4gBsGnEM6DkptC++dT/WyzeqO02FA1WWGdOltX29ODKLWjEp0xpT/0ZkvCO81n44ITfiLcDpdeXQRZ+pxi84h+Tp8WLj6N
# DATA RHAczXv+3lAo+SVbt9yRKQr2QrTviTzO2bOtze3Ldm2AHFlRmMGE2pDAMcm5m61MEuP6CFtahXlavG1n0hnG+9GkXIfDjWIFWf3G
# DATA bwvKqPRjwRz7U62aWwi+C7eWgi6DKksbJPfKiJlxPg0ERFo9PHcQ9tPpSzHTHcMQYaFmiQiH8zNlvNA3wAUC8U4wLp5xyRrRoz6q
# DATA F06/6S3rI0zs6SWJEzfffKdL8ZR/mVS5dOv2XxBRwop5MBx0aNiroE3NqTn+HzrUlH1pkRhtxQrJR7pfrfxkv3ShsyGVyEksfE3e
# DATA fw7kbatxvyHCNmk6YZu5CjpOl6mty8GydTkA0927mw831tzLwStVi1od+g558CgFEGwn07eU9D3L4pzKUiPpMV1Al+SuozEXvVFb
# DATA yIMAD2fdMc3fgSf4C5BaRTrm0DIlveahlEIENF5RUH1IwsZzPxag87LP2un+jl8Ls8OWGVNwe3P1+3WTys36LI9R9LgxlU9TqYAi
# DATA F52SVMMQ5joWqnqrlUDXt03HBFZU4T/t/REmC8IEq33wh+fkmkBH7TZIMe12KLMeT2J05BD7Dz9XViYHxwBjuIW/qExbYCFtCxmo
# DATA 224XjTchP1m7w68UtIsjOm9uoQacgYbxm7ifjcbTeeWyKS033srMk7Z7OAJk4xqBHKN4qJ0mHWQDhEmXQadiKsoSCRPLytCSVuYw
# DATA ZBxkZiFSnhfvpP0+6OxFg4zf0cyW3QR4g6ZXgGrTjN8ZvTejBONScic4mJXL4j9QWuqfIFQVD9PouM821gUXXXIb3XzrT+Au3jim
# DATA fDfkVkJ7W8FWQ64QoBWdVEE0VLFDYXUc0FyaeQPfIvMGfhQTxp9wdfgzrgR/xlmX6Oj+domCTJxJAN53m+LgJ/zMM83feFazG0lQ
# DATA pwXpZkO4uk3naoB3hK4WsTV1XcUKOqzKacuuzNxjGTVq/Al8iF/7Pb02PlR60ku7VRXnvvX67/Xf67/Xf6//Xv+9/nv99/rv9d/r
# DATA v9d/r/9e/73+e/13mb//B9GSXMUAKA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
