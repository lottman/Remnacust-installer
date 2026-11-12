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
HELPER_BUNDLE_SHA256='6578eeac5ce867571d9726ca8e3f2257c5a83f7acf87b984df364db8ea85ca9f'
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
# DATA osJGu9Hqwwt33vf+8O+D7H+jgP8b3P/dB+0sb/+DKvIH+//ftv7vZ1grIpj66tDFXBLepPwvlg5KJpMlaRx1Px2NqEYa05MfpniP
# DATA 4H11f/l6TvUtns+nqfpy+bNkpj7jRTfjZKi+JunvXhz4arlIxro+cDBHP4X+Gk9m9ncuGYz5Ccc7u6d460WZw6ziPT86Ot07xuSM
# DATA yjfT7/vHey8Od3ZfnZxefLF38HLv+OTiy9Y30Gzv8Bm1+b4Pny5Wtdo53P3i6JhuNCdXLZ4Qmw/Xqp9Oan/OLS8+e3X47GDv4uSL
# DATA HWCz2xX7FpDKD9Zq3vP9g70TTEep5Dd4hfM8RVXFb7ZbIu80L/vNURPsy4srxmLDd7QhS7dHjtWnnCzRLS3bW7nwbcvLGSin5xYg
# DATA nFkjr9YBC0+1OkZoKXGU4O+OdUwTsiQ032lZMEr0hMSAc75bphT+Ln4y/Kg9VpWa92LnJxfHO19hafm+W0SDHuGCw7N27lHuZFlU
# DATA xcVWdQ2xMncUhwBH1amIIZEheq6uOBny5SZ1InBdpk5uK7E6lXdl2zbkiC81wIxqdVmuvC/S++J1rG5b3vJWFqWrUK0p9Z/qp1vr
# DATA 1ukH/H7WWD+3f6p9XPu0omKk955xkPsLhHkJVLo4E+brX+ANCbG6zkMSNTHss6CrI6uVdXWIhnIvRgkfEVssZ7B5scY4hlYwwiul
# DATA F7EeUZIBOrCeI1eOqba4TlHNu6/6gDq7aaBRpTsbFd21s44MA95Jk/DRsbn9Ct76i7gepum4ajqFX62Z6FLZQCq06QSdLBG2bQLj
# DATA x2oVeYeGmNJUZR5Z83/kt+5bjGf6Zj5ZjlGaLuK5OaMkvBaLjkydMBt9rUt7X86Ty1Rl8HzZQ27biKcRZ+8AW34wx3jf3M5UBqFa
# DATA KBKHyVQenm2t46ke7P+cQcLnZSWUEawqPrSzilBkPNs53fErUkHR3hj4cHdn94s935YDtEHU9077jvYC9lurPeZk/atp/GbG94Y4
# DATA s/TlqiKzHjgvFlm6Ug4TAWUW3rvWL+RCRqNjyFjBNAQFwuVHvJxzvDx8VmU25H/C/EjoU0Hs0Ki8nYPQIuXaWVOWpDpcq6zVzlrn
# DATA mi1ScSjN7nRCyz0DgECBbsrF9BrB26wAd+538TMMV7d3lamTHKjqKZPgTTJZTrYVkzcc8sGCm/mj5UX8f8HYptMOWDEMc1KW42BO
# DATA NR3MGX/r0DlSIw+QzmDdK0B8NT/IsFkcTMxYdAXetvxMpxCqMhPos+XQDgkH4Ary/BHwUq2zRZr6Y8y0cakkL+v0dQtcJ6M6D6xL
# DATA FnB4/AFG77QH/Y3H4Eo6KowvM7bOuWHP+rhzLGIS98TbCluxdIe2CJs6VvE3YbiKrtVxR9eVwqtn6q3zB/fVq2m2nM0oG1XtKAV3
# DATA pfavL2EZOjWT828va8uhcrRbNZqDrA8akoUWXTjuVnvhjhnrTskeq/QUPVWVp2S/4dqSwq1PFXJJFHW0U74hjd0PZl6usBVVqXlu
# DATA qpxSAfhUTiFtrByJuHrmhOj6Oawx/DS7/UvQ8Gt/KUrnX7LG+Q2onDU5OvoIcehgF4GimjkFWWthkYtVaCQiykhtkc2hdwA5l3gH
# DATA PEwX2IOpHvOhcKucWRduTE6qcscMC+ZkZ3LucKHgavo/9J1GSAeKYX8gHFgoz+yGbDlxh3d0QCYAVbcDKUyshEfwMaatVVwUt4Il
# DATA i7hSvCSUAVurS1kyKZvoyMG3uPpbLMLo9LyuzsSndXSRMzpbLgd43pabPXLZmKQ9Fqv02GeAHA6vt/GdsjTkvrqqKIk0CbtykbBv
# DATA pxdd8ZetFpIUWKfIVTOIP3OLvIJAzcv41f18wHW4IJ4chuBHKRdRw31QcUSMsJqPtrXA0Zi4/zxzUdvji8VXsB6n5yIL0pdf2uKY
# DATA WvORlVqh3rzcf4mQu/RuIbfQprxS1GqSV1czTvC+UsCdddHpCuLX1+0VyAbYlznPIVO/h8hM8Wj9UknybaED3ETWK7AJlC+qzhpL
# DATA rW5vUKspjV7LF8eQUogGhhX1z8yRbllJ3KMffywzVzBs4Rh3xeXX5xBd0J3jd5Iyzen1tNhVi1bUWtfy7VUVuD6CKlr/ZBhHUU7r
# DATA t5TqnN0oZ8ZztmO+At89RmQd9FewEWyLToxhHDQiB1+F77lEc+tssHVeYhA6RiBtg9Umn6McqWFEuZCvyPz7q4qrrhY6Cncl0udn
# DATA iZzEZ09tY9jvilUkQ9Y1uVr5umQfoAO38Tn8B48v075Phz/dTtLGZ7jO+0dV7rtWajkASeUMB+X6yhsOork/QubtudPMCmJPqYBy
# DATA ZplmIa5hNnRKJoHD8+mC7cp8i80gycA2sEwQw+QKUhUHgYrlx2qBDcoD0hU7D3G1U5gDiKvb/CJmOUcEd0oikrsvdTnwMzAbpdKv
# DATA frEhpXu1l9E8UaKXsYc1Rp5UzDgNXXnkm2/yPz/OA4HXjBdIVPBYyZ90QeFijXBuoTx+Q756mhk3qTFlqRs6bi60WbctWtUsnVUV
# DATA n6ut4u76NYfNq6uais+1SjWN4nmZTAkDEFJ2NbyHREq6XMyWdG7AEGbtARrmdxTp3qyg3FIZICccHxIFea/WdJTyQSMC5jSY78Mv
# DATA 1aI+hw2J3ur8ESFUHzFi4W872kLdB0HQ7cKfsmM5mN1PS47v120EudLF4tua0/FvVWJkaJXN4yyrMt5wA5PKjRUVCKrtpq6oLUKD
# DATA BYWu2oaL+pB99qDrjnr5UKuGXvJz9piA+QlHothzSAVRsHFDpq5cX9rFln9TRJwRU3gjL6PyLAH6frNF/0Wu3Wyeq27YfqEHeAQq
# DATA mF7G6B23JVkdX3DrSVrSHDpSUGAQTelpXL+co1xip1B7ey+t8lZrR7Uy7cwtC7pghfZQPtGfGuhA4AIbrL/UNDuh2J3YP87blRIN
# DATA TpFJzoDR7hTUd3VPX+4dn+wfHaqBubJHg32ij3H1Sa9SSIyjGeq3ErNCy8WcUWdZcx9kwrmY4LuDHmPEPYYV2m5i+6kiEbxZmypt
# DATA qPNMThXQFQvsEA6RoSmr4qz6d40pcjgJYmT9Hksmtr2rXZGYUGO8kVuq07xbcmulqevWPNaFhgUfbyuFDjQTF1tvy+Htd/cKIMf1
# DATA Vbu7szZe1brtASdZp3cwxKjudUL2M11st/Wl7ornSTnkggtArf8jXfyWu0D3rL39lk3Cp7YtA8h6dj/rqDmvEZzqRkhqrbYI+wtE
# DATA dlwwW2Qppnw2hleJb2EFf1LkbRmbqnONpkeYv3QjG5c5mlcNVNYdbxRn/uZNs8mRLtNmRR2gR4pAc1JNXZyk+2UT+J6rv0RTAvu4
# DATA 15PTfcrANd0A4qx19x4qjFM4AW4al4V0VtZffDQaLuNprC678XK3rhZ9Dvog9b3uBlV+0vU0qDOA+tyffRiw5Awgl+B6CSpWPL/m
# DATA QltRgBkhkQV0w5dKcT4ljmSwS2/lqhuqh5nrTZKUcIc99SWHga5gAHhB14WlGlERzYXJYTIk0igpX5Rf66rtE7y/fpzoe6tJIcZc
# DATA o4A4DJUDU0lISJn4GcPyo+TNdqUhBt46RkGS+ba1gWqrKet3dObomuMGTpFHDhNSfPsx72knTrfrttdNTbV/teXuLZ2QZvrsveqh
# DATA vGiH0KaQJto9MX4ovamZnjQoM005jd7St8be3k/2T2BLyDcQ4XsvXp5+fXdPiZXCk+/7O1O6a8kKfuP1TbPlcJxkV7QNMpT1Zg+o
# DATA +0Wvkqyku9k8DcFKwcP4VD5kAVsmXgJT4Cv9fBVcUokdWPxB0vTKZv+7MKP7GRJQijruXsKbuB4K4b7sguh/XVZVWh8DJ6/pcHWB
# DATA BKdZHk3midxeYe5R+cjmJNbvCrn6TaRnp7KM2f6Pxrn4UJR3D0gDWahk2pVUguHkyMZ8spjH1mayfQ2u6rHSkyFEQhveed3x4Npp
# DATA SvSCDteDaVn7vRQeSGeK1uzSAWgdUD01jBFU6lrveqBgQL6Gwb2NCUuPbi3B30c3R5r6MHh4QYrNHyhtoKoZaERStQhCoCFLsrZ0
# DATA 3QFRo8flrzLOrXcdY77QiV3wgEsWKK2XmkqakGWg6aoHrK/yF0sjZpBYLa49XAiDafN/kTMG+dTb7z7/v9XqtQeF/P9W/w/5/9/F
# DATA v7W1teMYK1T52XJGF9bEkVUZmXO4pZZ1gE4BTAiNoHGIysZoObbvpr0n3Z/S9T8gSX85FH1G/3KrP6LP1fOO914eneyfHh3vU6Y7
# DATA H0iSEjDob7i8CueNJH0yThcLMOmfmAtsdZmYwk/5a5tW91GsLOP0V/I43/c4BQ2sDKr8g5JbXLgzLnNz/1xVJZziL/lh6Hfo+c7j
# DATA GxcJqRY+rxaLWbb15Mkl6CLLIXrF9XDHuUncOZM1YD6qC4bjztt/sfM51h/MnYMQP9LWWXN9M1gfcfJPzXu2t/PsYP8Qc+AphqsC
# DATA LbM0S6iakr41wWT/Vf644lwrV4gGm8uuJV/6jysU/FWF0POt5tJsSzdTYMAOC8YXWJK7ylsK08nTBWVcFG960SV8rHuN6DUEl9+3
# DATA wgk6TRujQPiQC0buR3xTYz7uoPBqRR9MF6SGWj3y3QUM5wM34Tg3rlYtQI5hEU6Dy8xUEP2k8PwZWdOmiVe8R9F645HXM6TzSwp8
# DATA mWslGtyJXGRp1R6+Qe/pGUxBirWN3PsGudijTUtUo85mQWd6EQsFWdHXLpc3OF04yj1vR56BufNRtqLVee3cXlAAPF9s+fKSir7J
# DATA SAk7pfPAW7Okg1y8Gcw9i3c5fwrJCDQd0CwlqwlHoiuDrVn5wThLmdrJAs3EJQa/J0EWZ41crzvXKdiDQfYae35GxQfRc8Md4Nkz
# DATA eg868n+KGcr8e4Qdx+OR21n5CpbOjRPoXXzI0xLsnZcU11IVLK2Ng6n1eBImCRcNFHPobsYrn2s12zM21rE/RVlbK24ALV37sls/
# DATA V8JzZr6cu9E0fkkd4SG0Vz9GJbhOYvqCVeFcbh9qvXzrQ6eJcGqG69xKrn9dJyndmKQwXYwTVK1LcFRXP9z2m3lH7imXtlQuA2J6
# DATA op2CphFElEQDyj1o75G5S4YcH9uW1tCYL6fVMyloiUX6cHrndU4BE6duGMwWeAG0TJd/xEiJ+sigbE9A3e806wbwmpOFokbMFhG0
# DATA pjyc7uMTcYTqYUlgjeEZOqjiKNNzHieTZOHmZloZ5vmxASRrBXlJ3Day6kPk+2Abce6ounmP79viS0ad0Kw048ismc5tEo8jPgqF
# DATA txHAm1v8Psd8ZSysRXjBUkuZ9AmVrxfSq6g6iwEXVtSFzJ0UKbXULIsKl89dztMl3Z+gZgZD2Ff+qRf13dkyNpiOmPeYv0Dm7dsG
# DATA 0d4dJhZ/TJ274Dgront3LzysWqUXucanlNV9HcczAQ4vPwBmqvYN/WbpMvlNhJhtNwu4cFCsiNMa0rKtJaExc48qkN/ZesGJG96X
# DATA ya37Ywb4YH7CS7mPwKqqrrpATpKwj9C+LTa/cpz6qcqO2+nQGpbVl/i690jbaegopMtUIzyox/rURLT8Ss26QF1zcgQA13XrQcij
# DATA HNiaFNUAhiZ17y5npnS7suOGJTKo0Pu4fLepSqcL4Jxhbu+5DM8akg7zoc1+H4vTeWpiTOLch+lySpam44mUBo7eW7KxzfCWFsyH
# DATA jfG+ORCE96CUN/NKfCodY1tyikaOPlx3dMLpByv2ym+c39U/2tabfqusJOexlpmCImA8uHmirdXCkT2x22A3I+uP53PX2zuEdq/v
# DATA DUe6ZkAJF3/wEvTv+1q8jeB9RNk6RiTYlonicYw27VPgKT4V4a0rdjgDIqTUQald7+p6hdWdT6gOr16aWk5n4yX9ZNtvPS5IaekR
# DATA J/pjWdhSlofVFLMmMuswXY75+jx0wo9vlWKbLFYtDvc3quziogLIbwX2O9s7o01lIYanunow3ZquGGyOUiq1b+Na/+AivLZJ9CEF
# DATA fVn2YFyTr2LaVpbrivbIaq3yvKwAW68rG/IBX7aS1G5ZXHEJq7va6AvJ7P/1nMO6SMPvcYwH6r+0B62O6/9tDnqDP9R//a78v19K
# DATA VFXnAwrnkIu82Okqtj8qLGChM4O7z9+bq9tyr/u37r8EO+wlmNxvVniDLd+v1Gux60/wQWdSW+UsF3sdtvNlKKzEaL53jTTd+w8y
# DATA U2LS1XL6mnxvC+CJ42AyjIIt54iCZe3VsEZGPkLLEClFkPpzjxzx85IKGSrkzaGqRXAJ/CgD20cpP3J5M83HRMmsdHZLy6cGT1Rh
# DATA Fr4MpKjoj2FxS9/T/HGdnRSru7CyWeVqTU4y5IoAdILAeSyUx89hjvepk+/+y7tfcm1vVcj7H+DPb9///P1fv/tnocz1d7959/d4
# DATA hf27f8JC4LqSh8CfWQf9cldQy+Wf9pk680zOpz6izPzdgzOgWuMyAyo9jgXIf/PADChxmrTTt8FZhdK6z7f8gIg0QAJl0uA58Wdz
# DATA kVAgS0FXcPJNQssZLjAoB+aqPksISk701EJcMT1olqDjDWnmjPHh3lOOo/DP5IwQ3Dk+TA7YEmz6NDhdKJNM7SzodG63xBsdkoXV
# DATA UH548Czgu/9L4ZXruRPWf/P+b4iksJI7fMLy7+//hmrCv/9P8Pgfqfz8P8NL/8JHBksK6AuxWCDSMQS0BIC5qTtlmYCCSdTvIuEE
# DATA 8wl8uHsQ5v+Ched/g0T+7u+BahCW33BZfCxLD5RiFabHevfv/hmm8nP4/rcr4SWSAQjrJrJAsJ/l4D4vzwiT685GVmDprR7lbv0t
# DATA bOK7dbBHlm/W32KHdw3g3I3Ln1Vy6Vgz5cIY3RPEsnreestQ6sJ/52owHqZSsGJM2IAuzqMlUCeTrIdsTDjnex+TZWlzI1gIWIZf
# DATA vfuX939Xsot/UamVnbtacef6I9HxxxINq/DV7PkT8WZ6+sJNdmB86NSY0f7i3T/Cl1++/2sf/+AHIDOY3b086/HHXlyITRUAvC2t
# DATA vAKAigWu7IQ+qkjYB88attTf+bTXfk0T5dsh+GeY+8/f/Qv83y8esdbEiulyF+LfBBunZCpZYyxKTPWk/VASLX3LPP1szcQvYAP8
# DATA D/betjuO5DoT1Gf8iiQ1x1nJrioAfGupyKIGTaK7YZEABwDV3QLhmkRVAiixUFWqrCIIQThHtuz1+Fg79szuh9k9Z3bWZ/frniO3
# DATA JbstqaVz9heQf2F+ycZ9iYgbkZFZBZDd8qyl8TRRmZHxHvfeuC/PXWb2mS/3RqdDoOjLeCSWC4cBP6eZOZiMTtWVqKM/6cwmAyan
# DATA 1IX3zCkRX5F0QuX07AOBwXkuC8hejBAjR/wFE+KfvP5H9fd/ev1lpGb4l5h+5BeYBQR24m9efxF91J9+PDvwA7jL9ZRiDBTjiohc
# DATA iURwwCJ79BoRHDSY2o0bt650XngzwAB+UrFJWATUAokOV1Fr2p0WxT4noQ+QvKTlS3wVMuOSyG9lnFor+FFglP8NGeIveJEopwrn
# DATA QInUQtEZUWcmwloVPYyoVjeUQnd3T4pe+74RlVhTu4Qz7cFvToHLBwwSvtUK8tCeloX2cexacgLhhDcusoZ9Zz3Ob9zAl05UDHfE
# DATA SCWYgRUFD/NOCyJePIzsuypMrDeGQ9fSOy94JKEJ3JItd4NqYAu0aHF2qBr9wxSQN8YATeOUW1G91OJTtQXdhC6Kb5wREAoDTZ7z
# DATA Yp/zg5rPRjmTC5QG4sq99bdFEUbRV3lmHFpBspkqDlIc7EdK+fNTgU2Go5rjDuBInTwmR+5cqBbQuxWqKUqlgVH/Z+z1n6qB/A2I
# DATA D0q+K4qe6tHniqz8FPnQF96UgPiqvnrzl+IowkPnaoT0xsAu9g/POhwny0Bjcs/0A1drMapFUEx2Pl5rqEIhuicE78/VShJpV0Q+
# DATA Lgtcpg7Gk5aSH99xmD1aL9DnYnZSO6FYd5OZVZT7VhkvKN/Frz8PDl6NG9bqP6Bc8ZsIMm0ByVQPfvv6n4XcADQqd+ycCwb0s2ju
# DATA 6FRqIjK+yCrB0byfd9KDfDSYTdkZPW420T0K3wLQZV4Sy695aM1ACGBYgMAJ0KACiwtg6kKDQqTaHWq+WPz8HW7/n0XBif1lHByX
# DATA HkG+UNPA2z4HJgb5x9RR+ivIgEbH6VKNY4ugs/Zi3ME+R04UIWiC2OgkvDytLM7or0eT4i4vfKxhG4J+COUzr4iGU9Ec4VaXdczJ
# DATA Ne5o8dzp0kU9UA4gjL67mCq0xySHrmf7+5c4fEhgjJwC1PAXwBxe/wMcNEFBDc39Em40eCy1CFN6oSEGh9SxDGdCDMym0y6sqawo
# DATA uK4l9Vx9efk+8+dq1P9ADPbN/6T+/mLOSltIJ9FliaKhnSrFrcBTv+oQManmFFxF39Xmr/F/gWWFO5la1j8nzQwd2itwGxyblKGE
# DATA 3tOGKBNzdNkn25Rr/C/YeyUP/Wb0cKAktn7XGkFBg52jCx21xUz2nnWG6DmljEzP6mESdQeD0SnpAP2Jq+upNLf9feOTyq6rq/sX
# DATA ji1f992eSPMINxx6K/BFgVtewJ0JszL+A562f4LTVXb0tKAGnhBtp+Wlwrqc+yI0uVOsOcKnkhJGuXm3lbOEjodGP9Vn6CK8rHn6
# DATA MuvVSLnvruj169cfQo9wbdQ5n6UDpPQ9vqewl/xQ2zamxyloLDi6jRwXLXUF44nLEwz4FOd6tXhERVkAj792UiiHetHDYJSiH1dg
# DATA vVipovD6D1KFcZ+CaX+vLaGRKqUOjdKFP9DPwwqcRMC/9ZZKBpuPVJ66f8RcqKCRVEduAQVVmcByGYCoUlZU6h8CZiKx4mArcKWY
# DATA Yj32tFhxowLmyU8c77Zocb9jlpoijpWmrbnXuolKglp8MBgdUCIEuvqUeMAQg1wQdsqbicsyzvY8xunKKgVwLK50KSxgwqbVYpxh
# DATA Dfzg0qLa70VM8wUWur/7Q2BmYO2WJkae3JorB1Euh1zmKM4RUC4hnHy9GbzJ98aJotWaRzwpqMAkrSIhtjl+eDHy2XcZXjtNj6p9
# DATA hoxBdLH6rI49/n3kInfVbVUltR/cYsNCVeeihbVv6FXToOuAX/qetM2BTSI0zrRIrv8BVUGm7aBfslbziiUj/D8IHTbPCvnYuVdw
# DATA VEynWmFwFD+FekGpHk7GTg59ApGI1foV1fk52vm33A7aIddtTyvL/YnT6snAvIXcPv2Z0ae3yFw8NSJ+CLvLUKQC7/XrJhpQWjOL
# DATA 4uQk2R82D2aA2lJSfZ6V1qNvav7MmCusnphC1aF89hrCpi4BDck7tARQhNkrtoknqthT2iiAioTfJ3O8d4kZ7Zzl6kaz/krd71av
# DATA 6HPoZDP6ffj/KXHx/Vue/9/qyu0/5H//2vz/difpMKdDqS60lANLMTKI/8k5xgG0CdlE3WBtsLeiUyA5j2ZTKou4IqoI+Iyng3zx
# DATA 1G/d0fjs7ZO69Y9U582vaTpdPJJcp3qbDEDkJuQZ9xm4MYNlFvvDz3BEkS2HapY6/DUb4t9uCjk4yJSXZagY5RQCq+Cw4y26g7o0
# DATA JWtZNBiGjVGkWg+VUraJUXnZzoD04B9mbAOewHDutshM/4miATpWQXFvWB0lS3ZBeRU9MeSBZF5LB61OZC3q9dOj4UgJ1l3SeSjZ
# DATA GWFnpqMoPx6dmo2CRA43CkqzM+4JBZDhjmHbt/qYLE/4qh6NxrQ7nZhEBnDEKaQcX/Iuo5PguOoH+qZt3T+blGnIvKxEmfNnYxGt
# DATA AniL/Cl7j/wzGPLcVCd6ZJQNYW7ynmIP/m91Wfhn0LAVGkITILipuG5twbQ+Op2QhjuyMctuf8w0wRFDRMlOQY9x8+16XWkfs/ZR
# DATA cKsgffaXvtuFuo69/p3rXAF9NlCx6gY27aQIYCG9hvlAmLx8cpPZ5H0d2Jw16z5cj2xsA+Mciwki1wz1MUKap9PmTmfjydaj9Roh
# DATA HU878M76zELBP4pWRootlkPTg1Mbf61IC9y8R3i3zdSvRXbM/4631J+reVRXUrp3/gp9bH4LOqTfgX0ZlkVdQ3+tZrZwJ//Nm5+S
# DATA /R1u3/9EfohosP/1m/8Yu0CQHZ5rvqrybDtOFjE8ilt2PwIcKMWCtCKCf45Rr8o/ox/D9KyuYoLGl+quBWpdng31AK+YBDehn6rf
# DATA fhKQcL9aVpeqJjTvqiPQ506hXDecQjy4B5A9A52KcJXN1BPU9ta4fBgKm7MKwB45HIFaXROdnElcQX7EhlwFIu+nnceb33X3k9Gd
# DATA miLb6x8Vi5i3jza2K97ubD306i/VuC5OIGHbIVX6OWy6X8ktSTZysSnDjoQV/SPqJR/RqXr/fTJwlB6eSwzs79R+J+XO3+OQfhm9
# DATA +XMiauCSWz0gdZzQ+/sf2X9XTwR8pCgd2ptBgfQr8OBVj8jlrSYauLuiBAivlS8iyN9hnDzS8Xhw1nGpHf0DcVl4kXfYqb6kYJFW
# DATA Sd4QlCNGoEMa5WRpoPJ7dI736/B8q7P9aGvz8WfqrOIvtb3WH+5ubZsHm1sfbj1+vPUJg6nKSyifD1XsEE+HbdOxMtacMy+OOmoi
# DATA TaeYROzXI/2EqMO+s8OLBFlbvExFTJJERUSUwmmmLktzvyAvQXT1+TW7G8CuAALMvk5Aeqm4kCEct1pc0bD2okDvQrMKU07YfPat
# DATA Ha6eAEJwwLbIo9+fj6UgrqKqvDtQ0qXTMsfwmCsF+ysKzQcItJ1+T4K4F6ILino1sZvIsEjpgEn1kvW4Ga7bmUkb7Q1tpEN05/JW
# DATA mDE0GJ5ZW1qXUd9HVoS6ltbJPFFVNKGUSjaawgUlN58UBpkDHHSNxwAAtAGfEUeiC46CHKuc3jIT9nqlOhzqlhjJUqFq9apQt3om
# DATA K3cWU585T3W6gETznxWF/HuUANF1ULcNn2uBsbhLEinf2RuHP0acZ9tJO9Nsh4VoGpiawhyaECIoQZtqNtRYr73YUKDMi0AiY4r5
# DATA uYg8p4QypBJfkjUiUowJbAi/JgdqazZBroKu+/+ADoboS4iiN8aSFEXmOvWwDs6w/FcMKM0kd+GTvRj0BTv80LilMuZy51hdC/Ut
# DATA zsTTAqlwuY7w1ObCau6TggyM7/ChumcD7gXfu+kjtKK1likHDT2hoCPtSQ8XH/emqCpoQhfR/qimnbpY0S5/M1OzoK3U8HusLsun
# DATA o0nP/FY3ifkr97c2nuJPpfLENXUh4/gSVlSJA39GHvDEIH6CHOE3ES6kEkQ4bglE9Td/iSanfy6/gBqQMauyqNWg7xirp5epzsOD
# DATA vQB//XCWAdIr/Hk4SY9ObBoVB1yobCkYr0jjpKkC7JWisWIwQLKTDV/WQCXLybslQM2L7IyfmqpDUWnpVHUeItMm8Z/UvtPKXsGK
# DATA 7EXPp/vvJd+BfWBDbVSNHD0Dr2+0mzf+TSzJKKTLzkDJXeNaCSUIpKjmE4+uwgsCrIMkAaY8hYxGnRZ0H2hI22xFXdnhID3K21hl
# DATA hT2B64d/dCZknQgZs6u8V2yAXzlQu+pznvDxZPTqjNTf1A/nkNajF/1hrx13017vLLZ6FzO3te/cvybSijYb+4k7uVQdzW/tO4Wy
# DATA bOEEXSN4NKE8yrKmoSE1P4H7cDREtDT94ZKLhgUSxGxol2EYWgceHi+BmfwN6RSme6X/Qsd2qPmBSDjkYmrxloFZo9DHo/7Q8XnX
# DATA h453CEzKSfIntef5DUS/n6D59nn+XlLb+5N7aq/W7iUF6EjhDUHj4WSG+I86S7gANHX06CZi7tHft/Zpx4UsSEoUQ264IhxWhxKQ
# DATA xc9tjvtQIMUASAL4VBDeQxEwkOzxlOmOSMA3HURFceq4L6ozeJuLz2OKRKVK4BH/rWs61zUVs+G4wVWA73FIQVayJ/R9wOFkiPyd
# DATA J5SqwPN2jno0rMqN9caev2c8LJq4aaCBJGr4Dy+8yy3Oo8Zzw2ztxb0jswvmjjaRd+p8zvN3wFTgdgkc4hcoQPwSZAUUEr7Ea+Yv
# DATA 6MnnIE38Dn0VPlcSxd+op79BpjPJIEYiIwpyT15i8CIDlxgK1UCFknnz5q/jcjA6k24TAHXqkVDLFOQ0YklGMWyVcEAA21afZI6k
# DATA eswSJlRucgsVUpYX8vsUlaPIyow+Drsnq9xTbe0jeqrRZBUyi2EucJ1mHpvA5gsJqOCv8vPPsUUnpPHyFLNG7/H++++XN4BA7Bdy
# DATA RVTvdWbNXl9HgJj1YOrRknMdWLWl8KyYeyIzMd3Q8CXCjoF9HAXJus3GYRPhzdgHEkuQ1AwfclgvAodWyZRFiDJT5x795cC67tm9
# DATA htpe2yG4EeAHWuvhwYoxUyFcMZxk4mAEu+nJLlry0SYRFH76k9EQb8Q0o+reMKVs3HlAIioJc+B5AgFPfW4mfk8L8LAk6AsmdC+a
# DATA 2PFlRpuEZI/86dcvYuFWgEuJWs7CslJfQF6DrtisPPtuiMtiUp442gDOQd1n3Se2G8jagIX0CbVyvXdtDnz5zWj3OFMcN59GetfB
# DATA aUpn0+PRpK9OXf9lxoGHw+wUOnWPxVnKJkR2rzEAsk5Ho2LOjUNtnuoPy7qAmpRJ/wjxV9vu8cIFEVp0E9hH614XdM33AgmMHxgv
# DATA dmKvsbpPgKlaCC4TqEnwNFK0alF3NSgpO84bQToj7gK2pnPVTIvW7cIFJrTLX75FJflzu8Pf7Dnl99EpHarVhxRsAtgrIOiMH2ge
# DATA unnQBfpozAeJQPYUw/yB2vUNDEK1GhJ+jAIgQwXyI3U4vGBSW4k9QXV2bxdnCpo7jOucbEv3UlMc8PWC48iTToPBOz0PBMYYtR3D
# DATA MHYsEU7qrr8RG5NrUFSPlf3N4huxdcXXYIN9JQtNxqMBe4PhM7UADbSDz9i90AHmlLoX7RUfQD3c4wThWi1Rj24IXQuoxvtdND4z
# DATA Por7Hh13dzSZxAL7XptIOovkVzqA01glvd03KiNEwzPu/RVUXEO7aSWmdmWC6GRcMKGPgU8FnIBuZ097/B6MRoOaxIrjv2nQO1Na
# DATA BUM4OOGWnm3YKijUIPFuRbp5/KyFbhxKnsnG8EeNtpG05enQZGPNcz+g1/4+n3AXWmYwdsA5jzi/ELIGdBKIIQvQ8NNidWrqSnuD
# DATA t/WHvhjoSTPI+wsnC2QAK+cs/AmThAa33Tw7GcTF/tUqKsC0j83pKzgMZITGcaOjrF8iKeScrfBwCIyjYK2F6TR6gwxcVIoqe61N
# DATA c5X3dXBH6ZxkilfqB2BNRxlV/gamwr/7QwQJlY/IWU1xikl2mg4G8pZplHhWeiFPppp+Y3PynY0xPE9WZTgDnBHgITXKhOoU4lun
# DATA VgVfay+uof4/1H3rV2Ahf/OXbOf5pXOvMncm0xbcylBvp0qBKs/FVgDjPN2wIA7+r61PiZ1mR9RHg2ig65iryn5iVPCgMQVyqyUX
# DATA pN2D0ax3OEgRpjE+6sK5Thb0kfkFoRehMhMAcgzq1W/RFvb30e7jnZJBqf0/mvSMJppNOgtYjawGXu+0hafEfmFmBCDn82mWomEC
# DATA BP1eOlBfvt0M/IQcLECF+6dw6YZbuT9+7T1iuuTaDaDPO+rdE+1mbvqZhO1lNEgY/YIDXGx8cP3/nNXVX1aN7vOiSvrnb/7CHzWq
# DATA 7PHsixMNP2uGTpilpR/+xTYwR08podbt27eYp72apGfBRiTxIeFS/p7T1AYV5ta+ZZubtxZozrQzjy8gEOfcnQAyu6TjPrYAwoud
# DATA rbod0wUakm7NX77/RqaEN38drT3dqDuLBbATjEPx8+hTVXPBdcEiT7DrAi9gfpxOSHs6x1rLzhohyysSYkeeCRjLoFayGGJNopTI
# DATA +YrRUj5D9ctrcVuUthK4pSY4sIKN2QpkdgAt9A0j+WQ0gMmoGYuVY5SyoyemxXhV1jS1gNXbeBAGp3LJ85W3pjMxAbLSZxMECt+L
# DATA 1dj3VvYv15dCa3KWYa0e0TCLdfFKkt0OjgeXTFyvSTWZLjOumJOqAQriRgvkTste8Yt9ZzKqO2V4yvwz+F8s3ktYKVtpuW1Gr/8O
# DATA qepfoo/Jz8E8+EssTsFyZBbXVkXAC/wSP6XnzJV+zg9/ZQB0aEo8eUo9RH0lvKRlivUsWCGsbWbDFUgM53V4cijQrjhF/w/G1v2Z
# DATA nBrywEK0HOuSSFZQQYoO0u6L2Vj4L9ADcqHgE9dwYBLnZPSl7zlxtM4NDR5ZMom0VYHirQkldPJzRJhWrRVAKtaS4kuspk49Uf8F
# DATA J0fa/i0rV5ekWb/AJF8gKpmfdBlqqeur+jE+BoDVlvqDJHfExKOBcLfoR3IhEFwrpF+XfQVFLJkKgUDJO5Zf+1y9mlt7jhSO0JMU
# DATA +CYptq29UN3nnZaFcKG9budU0T8MjeFa26vbC/7Cqxm8/JDnMPbMAsU6xQXZrZqWJTs8VOwINI1tdj1xKOi1MBXkZBNF/oqjPDed
# DATA dliY3plxMNWddPrQwApC2+KqWNQW9EoIdDRP26LKsrkZ1epVd+GHUIy0/55tZo9RLlhnEdR0malMGDOaK9chBcU2ddqVV1AG92CD
# DATA 7LvVkLc0mnkCINXL0nipxt5uMIMqUY864jAdTrL8uKaDTk3v6748U6+wCvhrZUK6yaWqQzSp7V6s9XSHq8TRweY33Q68FqhCCCq8
# DATA eA/tl2BVJXjn/rCZZ1POB1CLOZMEafNc4Au06QP6BH7cCmd/x5d0guhZnHhmHyzhmH3oG5MUEPxcyDEmNs05LLSQfhv3yPLLdLI8
# DATA 6B9YBNhlxVTjxV2V/y9zuTIMk6Bbf0aeqH9P4SEmTt34nPoaC3VJV5LGf5W3NxIsfomx7VJm+Vw7Ian//kcJGIVzrPVz5zEoY4DI
# DATA HPQxfUPMqfmII9kzqU57N5tAgkBVhue/VTo1yArTXgcyn2shXACrgTJ50P9R1uuY7bLHm6B6QavtsN5giLXgBhBp/pY11eUN6Yy5
# DATA sF9W9uVwA9vporpLge1dNUZAYhF7c19kYQT/YTFRTsXFCTVDd89LyW5WtMtFBIc7LzdpwSf4gUFuwMm2ntpmB/G8miAI/zud/BEv
# DATA l/blHlWIeB+8gPpChexAluQq1D3ACTBb0Bf8v/o+FhgL8ReoCvwSXDb1FeBXlU7jfKTvkYfFbxn78mck0ZNfYMlcO8m1Xp3ZUzCP
# DATA fu8ZKrofrGLvJgGLOJYAM2+Jt5062qcjMLMOrHp4jXidPSejEnMJmq0EtKnlNJhUymzsvXiHe+BuccdS8gQHa4H1xVZ/lIG6lNLL
# DATA V+53VvqYD7nZpOAHRbh52Es6C5eKvTGuwKhM/pmzV+D2ByyAfUjD28vHP3JWjvslvbdUj8Vx4VxyRjhTU1p8W26PYAEaC69hnAEK
# DATA 0G5Mi6zLl0R6vaz3FDYofgd8wCtB1iu1sVwhFErvzbEI1iMhtfQPLy3AlazatnSrYmgYzwFLgy3/z6RK9u7vCFqJsZNFrcCXi7Du
# DATA LxhN14W1IV3fLzDODzDQf2v1y4GRhwbsv9FCAH7umPKhJFtq7Qp6e4Nq0wZCIWF6L7Cewv3EC7IrOtpexu6KTXs47qXde3sjLErx
# DATA vKXxL3sv0QdTCk41ckJtgoV1zk1FXKjmXVdq4TVyjSdCF1C0RZZUgNoE6+VnRuVkmQFCqG88ODqNj4RKk2pdwhVUCd4A5gVjFMA1
# DATA 1WHdhF76TpI/9+Tke3DyOBCMT+eb/2Rc/UHf7hQ3Cr3PkbpLHZ5W7Pmem5wwB3WJX6C8IXEwtfd6aGatXXdR7QnOWsDLmFsRnudz
# DATA 17tO2jDbh3jxizd3wXcxMg1Jd2hyOeoVhRh0ZwifCdJYCzJHdew5im44q47O2HE/PI8/3N7a3O2sbz7qPNp6sraxCbcIaSAQI3+6
# DATA trn+2BbTb6xcAypsyoUtQnDUQ28SyRsR4mggdWq1EcDLOg4teNRYD7qoL2elui/XYC+vtRfVzrtzpsS0Zx90nj774PHGQz0VuiH0
# DATA AC/Gl7hoeFV+lntDcsgx87LnarPwDj9EXRvKdKfpy6wRQPcyrppLBv8osFcDG0eYPYL7hgvqbGKSgrUpZF6SvbY0DnrmybYxFibF
# DATA bhRFIkdmKhWMLs3JdYOj02HWcxoMeXZJscz9oh5erqTuKOv2E7EgcwI+r3yUQgdhf+kKp+Xr3K7ngVPVqjhTF+5S864sHOUnGnKm
# DATA dOHDpcE/uOQU4NqRtcNCh4pg1NbS27cxf6G+CgrrskrTflkn2fuL7T77e2hewl8JbiX6PuSkxqWWCnchTVbI01b3AB2m2TNbROk+
# DATA MuZqQbQ8sEMi5cJRm+u8MKkK1f7rdQRtNGbgshNKDN58QfWQkbEdSVsSaQONNE1loIPo4FQtPqSz6Sj2vaTf3twi6y112JKZLXhY
# DATA tqAx0HlOW1ixHtsizluoAiv1SOGG27rHV/YDKvh5fe7mD/vlvRJQehND5InNsbWt6t2K8lwb/yvMHm1Hi6wYAXsg0j8oBYI5pO0b
# DATA R4rgvtkEUmErmsqbvF1z6J08DMmcbWvIQ2UzO2Jf5e24zjFfpVTWEpLEGm+dU1XqJyOreUpZ8NgqUeyh2oUPdZXtQiPo5ol32DZ3
# DATA 1HObwaarxyCjeJG6lU0KUkN/YkKkOvEq1H0ka+yNG/ypR7ZwJqQHj/TSrsWQhq57DFamcQbpx9Xu6b9UBA5/JqXuxAGThvrL8U9d
# DATA 2NHH90Qi74NOGYZECKyBPiniF5iKOPrN/K4KgjMlyaCZWrVGiTjA5VC/grHv0zNuu5RfJxSZgg6ensaGYh87ZkjuFY4B9So+uaKM
# DATA MK+iq4kLZbMXupGVCQJyGfdtHDP3strz237pX9wWGOu19gL9D4TnUqvWoY4euLo2btUDnQhE7b7Ae7xn+hdN6B/JUhgwPSxzU8Wu
# DATA 1K37dDWxe05wp7UuhoTz+YtRKbp/M3qMgfSEIDnLOcs3AajEeTSeHagRRc+2H0cEU0bJSzgenmBh1AxPsjxvLqYdoTgHyKo3yQaU
# DATA FGPIJIA3L7lHlQb78WdzUHpKUw6U6XW5Wg9UeNgbK94i6aPcEbouNCtpfe36k821T9a+t94hPY2aOnLmDOk/cFl0I4kDRKIow4Ij
# DATA KtvqPCLEbjF/X9qzh7+sdu4pFtr31OELHalANXApDU1pywWY0XPoU1Q/uSrwDdpmlwRZCiEsGZZnKi0BWwoSWPNRkf6Eabn9YL/I
# DATA r73akJGA75OJdufAKNuxb0IqAwwItAGMOWI6HGf9iQ0zZaGYcAteTRkfRHHuM6YDNpLV1ANmDvK5BPODedwwwKNOrBYmxaVQrSQ0
# DATA z3qopxNFE2wco+fBJDNVURCiF6wpI49l0ObcOEXCwOdgFKcvZpAxXkUY/Av+dsKmQsUMTBIh6jNEcZbz/tDT7yD0LbCqzDvlWNFX
# DATA V68muX4bpRylp1RnbmOKQqz8LvEjycNhj75VT5t3TMwuifzlxh6jvxE6usSFG2EzGgreOCEMulrMUBTuoxkAayR98yBp1mmq4RbO
# DATA b/dDqX3yEFnmDVcIlAUn3LEJYe1mDXVIJ5mMdu1l49z8OJj1Bz0OElbXC1SrgDm4AgHmRm0vbvQYl4+niVwgqUr0PUId6A3KQeTC
# DATA l3oTVOC2ZbMVlN6Iiae9s6roVJ3dmF1btXdxDZXQrSIgpMXvbqpu1PYASDt7lXVn0/RggEHGG3EQSxv8rSiYGneWaak5Vjsvway6
# DATA eh1QQ94Yk40QCRR0BqgE5F5Bb+46YoWPZtP2rZUVViBTbgDRwR3z57qbBOAyHhrSRk8eGjIUMHr9q+jj3d2nOw0dpvPmp0EXIBtI
# DATA +IXGYCGgXnYu+kdUs4Ab0q/VQUSgcLzMMV1S0h6QLYmMy67s5Uh3RJPI0XyfbslwJAYZzTPUmfUaUC3dl9kPPQmCjXJ9OmW39aFe
# DATA A+HD/SywmwKu1xbEcmEmuaAFQzI+EZTL3vXorPz2bPBqrG1yQltcsRlJiGLXJiKpwqCHOYJwHD6n+IBGRNFJDh4rf7dssA4wz0ze
# DATA pCnXOUkDuOaSq2puyFVwpYmjfRGwIC7+ReHCYFx3rXmZKgiABvEwGNXFgp3mAagIqrc5G6LL0kk/h2tTZ/TCq67oU+IKD1RNXUAD
# DATA MRqQ1wmLElTX/TshDFtKwBOA+RUHR/pOJRb413Z1rgTixrLY8912T3RAPCLrOolDTPbVLuygknZxwlJoFUcM7GhOkyIAwDlp2l2t
# DATA hL1xe+Rikxhl2zw6EBQCHHkKw2rxFLpNSLxmHoBQeXLo+4vsTKLgXpIWW2hVEfxj5nGR+HUOKNNqee1H/k/oXAJc5z84qvmv/rTa
# DATA i3wBW4sPqMTwcqG2uEC1KlM3cK3tk4VF3XwL+RgcnGeM4/vZPKTnZiSTUmu/HvYSAiR+47jnmEWufGAc2esytMVFHsYusLUN9YFk
# DATA Q/IIqZ99ig0MTVDYdsZpX7PIgvUF2Zx9WCe8KCrs4N/MsyB4+h6S6GySk5J8TuXLbhM4sUxF6WR8n3wO3RpGe75FQsnp3vW/SV4k
# DATA tSSQ3pHt/VPWMJ/rKW95K1CP5BxwdAVyePE4aQpXdvWFmlNZEmBSZYmLwk1i8cOuU17S3d1AfAVm2dmsohFz7w8yRd0rlKnqRsqz
# DATA yRkchpCUXHs0VN01faEOE4Ci2BQU/1gs0sIfdi0AwkU1FWJLkzlTY+UvMuxJuavuGvgvW9Xb1WGkUbeegtbGdZx1xM19xnOU4mB5
# DATA 0z5FC5Wk6j05szDiikHQK5CD6f8rvor4rZ1JNsgU4fWYVWhwWuuijZCODO+iE7VcRh/sbuIjGl0EEeZY+2mOaJHMtMpw4VjHGYJW
# DATA KEX1Q/FJfuhgLLifGfN7OVAc1eSP1Ci8vIn1ywWrpYRYqECX/SyxWJbNjakFPSf4xxWmyv307SZL1/XOpmv+OasSt8sQ5RbURgbk
# DATA C+MG39a+vq3gbZnR6CDsBm/A+k7sqN8wIw8aEVD/i9XJP2TWUsj5qvXDy9m0u4yllq37PJZJe+l4yvh/nmN9+H64oLahNFeVoww1
# DATA Cas45QD+qAn2JCObjezE0lXyruaR1AuusgGKTWMH1zhwAy2sd1ETFCfz4u21rqgQ/bM421hUt1RgaFYqMtKeT3KDclFI5BH+5wtq
# DATA rgo1dQbp2WiGASwOJy/ymgUPZIHflLL24IUElmVpsaVgsfwD9f06/qlIsbiyOqpK9yZrUswYWr5Qjpm3hBwzuc3KAD7s0WsFQTu9
# DATA BQnhFXowIAYmpIAklCzkUvRuQHpQL+j1TN1NnuhLySKOmeRrWGdkkyfpWN5B5mEiJibTGyX+RcU+kZPWIvogvi6aZdv3fCJD+iJH
# DATA j9oqbulUCZpIjW1n5IUvqVB+WxZ3zbA4HdYc7IqTp8GrUyfxCY+RllSkVnHCT1zuoB7U4uV03F8G8ONlguaMyRYObdC+WNYgQmOA
# DATA fCC/dpFMtYnGrg69rXnvkO99rGZ8oN6da6DfXpb2GKEap/ZkpCZiNOx3a6AwX71JcC2nx4DMXChw33zeKk9/Tcn/sEuU3Qy9tLTl
# DATA 5w7mAVTsSs1cKNu0CGzzV8YV3ox/Q4mwLVat4GygJjj80cGod+ai8eqeoiasBsk5OUcnzFY5/rOHnQ71CoCAwFvae7o1OLxVpfds
# DATA Sd61/fzxSB2fNXAwAsNOHYMkK/CiSfdi1TSobQMlGVq2fm6y6pDzsM4N+lPIN/pbQrqAeNbfYbTcL0ETFxDsvTVgHiSTBDfBDlel
# DATA JiLEcEJHUKLvJCtmoULXKsUYVakIcgrFefTs2cajpi8XcipW9LdSdIja73Lo3e2V20kVWVh884UHXdva4YTnMg26MxVqGDIrsLUJ
# DATA 5zaUBY9kPsiyce0mM8qw6hTtmxFHMv7Wi0+mMGatLOXV/Mnrf1R//6fXX7IpFHAnCbIklBa3GC75a5OZQoPxk9nyLcyf14ScM1+/
# DATA /r/a8OtfvvkrCPr0c2fA6OKAjrbI6crlLmON/doEr34+BoyAWjo5ym3GL/gF9JXzP7e1jjr2VM/4WZPsUfino/PFJ6CVtCFBgYp1
# DATA L+NAx0311VWYaXOsPbRBFqwCDD8NYubCbG2tYaIamjmE2jO5TyY5clCdSL25NjmawfZ5im9qQr5tdzq9UbfTScSXTfAMTPmTWmx6
# DATA FoODwwj8Ptp72jJkDEMatl5a77XpXowGE+4ejgw6VqhBdVME8Ls6Ii+3n1LOQcXplRjXk+bF8LdWUnG66+QIrIeE2uouKQmsYaRO
# DATA W++isTPVlcPlsHFCPbN1lyHsLlAX+qYk98rKMDwtF6uqTd3V9UU2huyeuGdiuoBP1VJ49jsd6nWUNfoonlt8UtitsWdYYKuBk4gt
# DATA 2A0QKm3QA+x+9MjFsvgPlM5riUMxhiMXjLDmHTQguXobAz8kklGJ181NZkSGnelxEbgRpyeAwM3tRWKfRtRIBbHTnZQAiX3wh2VQ
# DATA dfyE7pjuGPg3LQL/4Ksn/7JRYvzAoDHI3xQMjL8lsnERYR0zAntzn5STOgpD0+RDkgxJSgT5kLAQpNI67A6nA4eFOTZhj96WpiVG
# DATA jRG6gFGGrlqsOLbqSsIZih9ur6/t6nzE248+2fZzE9cpM5JtRicGP+xhAzJJbnwa49UAWnAFIBxN8xBe1OA/dX7yeOvhdzvrn7pi
# DATA p8stA+GgtEtQwu/NTsa5JPxzN41WUUCy8hw8sdO82++32Z8SzFHDaftmAgxILWwHXec6HdyvnQ7st04ntn6oef9oODvBBYc/00Fz
# DATA Z+Oj3fXtJ/XI/v742VPppUXP6Z8aVWBS8t3oqGs+uvb1pzV9OXEEHeKIUi6pSXHUyKjfzc5IFA1I5SR+7ZwpKnyy/qo/FfZaDxct
# DATA o8pqWkB6yA7suM+5JU+MS3TY3Ou/s6KquYwYubXgMhF035vjsocoPT/BvOog/X6uAUF+hWnWv0DIvW8s8r+TdPKjA3VUxmff+Mr+
# DATA Bwnr796+jf+q/3n/3rp1+/27+hk/f//9u3e/Ea1842v43ww8ZFWT3/jX+b9vXlue5ZPlg/5wORu+jMZninUMby1dv359O0t7aovj
# DATA 9lDX0rWnGwRXhP7LeFnNo+nxZDQ7Og7FDKnyTVXLEpN1Lbrq32BKgYMFh7Q31U/VbRWvjPxT3VyO1R1T/wTCp/8e5UvoXwF3D1VE
# DATA cw8QLnWRiWlMERb9J7Sp/5Y3WO+Z01dXOWWezvo96gPTCN0HvEspwqYuiIqWdgdqQJExIdKFz9ymjISvBs1XT5MGmHX/ilGejCGx
# DATA Sr+nXsicJ+RtgTyPo2qsf/aS9GiszmeMoaSK9ObTXn/Y7OfpdHpWK/qEuSOIn5DfYyTieVS1kz54ZZP4OBpieqeU8IpP9PetyBX+
# DATA uEu89E3+t0bDRrJMIyfi2h+OZ1P90kzv5mg7I62wr0kEXYJ+xwpFHhqFX9CbDhevgYiOlxPFqMeg4Qe56SQ/UtOvjoPa8nVI7qba
# DATA mDs/0LCpX/3xA8w9fw8ODh6XQ4quQZUORDTZwayN+7aHnU5/2J92Otwz0keOXqiNEDtAJVa/SjdEE14GfXX8mTm/s/YJPCdFr8EN
# DATA uDCaJBuPBuYmN+W1m/CaskLTnzordNBJzpujZ+pZaucARazRbCpTYdcjU7euOQ6Pp93WqA6oqbe9NwNdvfl+c0X9v1UYLGYQhjLw
# DATA o9VajS8W6fF2djKaMq3L9SWWHPJpadOIUhPv7HwcTWdDGBkcBigRy4iawWET1xL/wgWlFTRZnZdBVMUX7le8D9Hb69PGh6PJaTrp
# DATA Zb3G08kIHOwiu5zyrfoL3tkZuKC5s0kdFpgghgu/cDu0kH5fHFCQMO35k8fOoDKghgB0xez8CunftKDK/tZOYBQmjBHzAj6JY4xw
# DATA FJGKy+y6c+OGnMcLB2nULIa7F7jsXrxGyR5/xIHhoFP7IFM3tgnSNPu5n1PW9y1FXX1pLkL+qOYfaHZvhY+RLsK00JqIKwG+TZpc
# DATA NgmP4yElIW7sMpyqO1GvGqenp5hzr2FaJTxj22JxZh3rNCTcVhQattUEggRrtwRgCZzUj9Z32YC4mizgFao2SnGHbYvdA/MDhirc
# DATA OjCBbfiPIdttQ74dBJCi2h9veWJf020SGYI2A92eZwdys127VphbN7UNRphiyiwxgP3KFSXRg8j/dp6BxCdeIMLp3kAOUnX3mhxl
# DATA JU5NzJad5I7Uk5DL7KXsIsZniiSIoEGjyjDmHidZo7e/vJqBxt2++e16dGflJvznFvzn9gUW0xv2fnQz3LS0Xigaoj9ISle/EKg9
# DATA b2FwM0eHaX+Q9VrIMSLtLGoHkchYrcBC1IJmmXq0S5s3ZKSpmLzf+6yoT4YZKil5Yu6BpQx8BE5U0W70dGtnF3YFetf5QWzQOXW7
# DATA OxlTSI21PxRzNdcwePxQbfSpk9BNp1zvTZv6xoJQdF7VdSgAz36kWm/Opt2Q9qa0sn4+ogSnVFlT55qPvw+s972VldbKiudgT3U1
# DATA pz8C5Xs4TMk0x2V1rfRNO9hhJyd7M811iZpfumn7nNj+cldVp78vTGnDl9lEyaE5+MvmP5ylPZDpRtOUkj8COkbaH5Kq3bjRws3P
# DATA YfGc2xFqIaOxFkcFugLfZSZqVmeDAYJT1ybx3lrj+2njRyuNb3ca++e36rfuXsSUTHuuDP9Mi7y9UUbM+rA/Rem9Z3G+I5oHb2NO
# DATA MvUhBteInK+dk3SMAgrdiUBAWXu4u/G9ddSsq5uXujuBn0z8aGNn7YPH649QDuufqPskPn688WRjl55mr8ZgPoGn658+3dimp6Nh
# DATA 55iyB9kqTD4fO3fssWHA823v5s7I8MVwdDrUeoFI17RESBQnAEio2ulh4mRadPZGUty4gwUIdmwlqXsl4LPOdJIeHva7uoxc1pXo
# DATA fpuagD++vbLy/uq3v33zzu33b698+9ur+taCpbAHgULzRrcxRC/PiHuh9u4MbrC5WUTwpz06Q9ksMLIO7N5pRxejQcTDET2Pk+Zs
# DATA PFaysIXE0vWZG8rmVmd7fUdRX7WWj9Y+g38+WV//Lvz7ZGtz92P447P1tW15WSlbqFy1NpqATzI2H9lukZtMOoFDhwHz+4UeARfA
# DATA hqS10oze9vOeqUejeeNn0UHWHUE0vikojwHnLqIdtwczuae35P6+3K32MXbI7G6rk/cb39rsfLz1+BHUf5ZH+gzcQ0PXSzquwNd6
# DATA rMg1NzjIw5SdWjpiCRQZkQ2NopyMsNoSSuP72WSkGGg6zCMIC8UDy1gaklQ0o/VXx+ksR0fxbpfSLpyo3xE1EPEBbzoXXNjMD9p+
# DATA o+bAqdlc9d1FeJ5xT1kKo8nHRTiQCBfGFKrwU6ZmG3TOnPuT3iLX5B7xXKz8JdvWc0uTHmFqbP3xPYscEx3OpjNcqiGYofII/Uyt
# DATA Xkler0Nb1RqtoNsVe+hZDo45lLRFCTTRj9Ti3lPy8lRd66mLJ+lZpFodEi9IBwh6EOVjEPg17UiP0PtyyWHF55Zttdg5WG9xneLa
# DATA 0PY1uMBaOYPOA72KKe+EpUH8WBsgbipi11i92bi1unvzVuvOt9X/fb+AIRFzTx/Dan4AYZKqPSbhzrsdTThaZmLBSQBZ2AbQx2E6
# DATA 2AG+jlhAIK5i1jzwY6ohv0+SAspVLCxX4HJsRqJIIQNTxiHORdrnXiedxgUxbU+/XUOnxsLciW9FLq8+YobYFvhZLLOFzAQxbYNH
# DATA eI1LJVFDrenLAURA4qyNfkBG8fw47Y1OIUIyF8Ow1VyGfI9Bs9MdDVriLLDIhVpXRuQh7bNMJ87fKakLk4vUdYwtxB3WbK/JsI8/
# DATA n6mFA71TTQxFa/rsAJ/qJ1hSDtUrnue2qIuqoPumWR/Ppx+/4d0XtMKbS+/pWsjNjUaZ+HkGApGF1Rpt0zerhnRVjiI3l501twXd
# DATA U/c00DVEhoBwH7+Fso267VMJ+HXr5iJ9fqr7avSxjqgqxVQOYFF/oqg6yTgVm0s6+SjREOEUFUwFhaUK92xzFBW3sNTsyvwhQup3
# DATA kF/KtdpWlhV+Px31XhOPpIlwlUKdqmHw1J97jdV9f59UXhtW79bv3oZ7g2ouWWRhZJwxqXG1vi+N8mMwE8GOIJ3xIDtKu2cB51Ce
# DATA wOLyxFgF7jsMjpwdFK9vdcPZjEsZZuvhmxjYZoa9rMej+Wb00CxNpIQitVmmqKLUjlpR9lKN4fQ4o/pPUHODHDgFECjwAgIJhi/k
# DATA eH8kStTPBj2UMp0rmz04RbLiUg6kpnq0ll/WQwysjHPtG6LIENTUK4ck8Rs9L2RF0NsM3AxBqtFvEQ/bv2/j5OOl1YA7B9k38Ces
# DATA zb429coiBbOdrVtNTv9oiOzoPFczSzvBVW3kTi7CnNw2ELLLHJ4gE0d0zgu5oYDj2R4GP9pHoqW7ZeNuNPnpQKO1dNx3rt6aTKrn
# DATA WqtbQ+0TBNZBgAGamZcPzhp672A4gkMTQCQzcVLpYQaGMWsmkEAn1vQpfdCNlbSY113oktSyqD3YIR5D4xDJNQ/gaOkQkxz1zCgv
# DATA gn0HLTuQgpdsGTCXlkePDg/zTKjJV+rRKnlBuJVqgK25c/UdqrGtNYf0EwGF/giFO/OGqncZG8q4YdAbfEWomXsx/nKztDkvcHPj
# DATA F8UYAChoVTiISgNpHhajqjj97HygYUjVZQ4N0bhC90gbqB+mEaL3Rere3R/1Yi+EDrxqGX50j3uzXwzJLKqcEsJM881E5f1+NCNj
# DATA ScaiGDWNUXw54phBH0zeOC/+MBuC+2Qt1I/kHs2FvrvAj8TPpIglMIQYl8Tt84ESil/4rNCZEOimqOZBqJYydYr2+tPDpjWynF/U
# DATA e63QvXCl61gF30FB6Z2BcYp1GujF7kBss39Tg1rW4fvnPLiWPq28cVvUhwuHYmARjYs2G3q+7BiXRm6Qs+l4Ni3LZ1dmTyZvGNNl
# DATA 1AbAGhyALVnVczACbxqoLS5JVOw0rujaaPBSG/5MWcaTkPnJ6xH6OGvgqnrkg030D8X3clDoWzs8q4m3ihdA/ckiKlU1LnWDj8BO
# DATA cAYXGWcCdNBY3uweqw7VBJEVXePt1AZfCRo/PekYbwcp+YpiDkcC+7twtyGg2YfPdnY7a083Ortb313fBOK6rRM3og8UmYcjk5BN
# DATA q4jbTlVP1ra//8HaZufZzvr25toTVL9onWnaU8KTqsG49IhkdEaMD1f3dG1n55Ot7UeyOv0J9ElMjnEq4J+GZYCEZngG9mUZi5pj
# DATA weoJ/ae807VMaxdslUf+CjIBhG53qCLiC3j1zzFu1irAgoyrz6JEgz4BKAvLnvfividpyMsIbEMr/7Tb2qeZvuhghVbwofqT+Wpg
# DATA +pzK2xsVnheopyezfFqmr8bqign63i02MfYPWW8n7/9IAKvVyVKZs7CwZ0VWzaawjYrgxXF6BobaulTtutaXwOTwQ6vv1N7C+k6m
# DATA 7hZwLfOtvhQd4a4uyXjiQV33Scj++wUAZVOZlL807Jq+tOhCpspkYd4rKAFOJcF+kaW/1z88zBDmi24E97DRkZoz4CVK4vW4MbqV
# DATA m+TV3BU8Fjz3sZ589VD/KcNJWsHhCpxqbcd1h+GG3mkX53oEDhyl3s5YHW4q22XvgPsCBWXOxhRK0TzfaLeHWveobShMomla44tS
# DATA Bi2Rky1bphMRU+9h0vAP9QQ3KuZqbPk790Ir9cCudMiCQis6t0LGBUiHae9MPVQ3WIypnO1d1wtynRIczTSqAhTXul1KT9FV4gl9
# DATA OuczUNQptj3NuXnqfnIRyy6i8ga9AplsUDoMVUXLGP5t7hrDk6mueTTs6SRTPTg6nhq7ueSI6r5OwnMz2kbLR2SXwQ1c6U3OOkro
# DATA 8WMQ4kdq9dRzEwhHhnkig8Wj44a2m6CSM0VYYczk1Bk/lK7FaMyfHqtDAl37Du70SH0AbA7tC2egsPa79RA26KB8vBBDJTrD0gco
# DATA 5lk7DCrsfVSK8oLrBzSN+Mumg0FkCF53eVFDYgA2UMorxGRi/542YwfIYjldt0iH1bTWutQGUAyDl7pSdytPgioRHuiwWopcqIZp
# DATA mbs3w619M1qzvklgX1Hy72Ck2C3rmCKDRUIe6OhIDDgdw24fYKARJzs6UAJqb3BGd8BmsCEnJPntpzg8zfraq7kXv65iXuVH+SGP
# DATA l7TZEO7bh/09yeD8jc05n47sfATj2WGrGyuITb9cHBOqpS/RdV21PTOVlYdc5uazbn3bV2yom9lhI9nR/NqBVwrtvRImqQfAZ3w/
# DATA yC5ZFg6wR8G9AwyOlaHM4qipUm648/HazTt3d5492UG/FkptxWEQzfw4VS9rYw/Z9Dh71esfwfFENU+EzGNMeRHV7+fDmMxBKAGj
# DATA Pl7c3I4Go4NafINJf5K4PJQoco+5GE/Tdd5C1/eB1UnOKAuZ51RMu7U5ZeghFLBcx1+LuYwunaDOmsxf9yIx3ahXyrHpmXoM1ncW
# DATA vZhPKcmPjumoh4cqDkZfXynwuhjGi/IQONTGfvTzvUBxQXaC35S04l6lFmqJNAeLNoBXlwZcXXQ8N3rOqUlL1bS3V9UNPdQISmnF
# DATA iGjp+6V1h7Yy8bqsO0o8aRAeWSiUOdSTMzQTlAY+Fz/QN6EG34SqvtaBzMEYZthpq6gld++A8OjOyoqQH3Q8sp3sVrT633/yv9wB
# DATA P0C6bxqbYuBOZ1KVcCDp3IDOeXGWl7yLiGBMdB/+452tzUcIv1x6VSGCc7Ubh3lqiAymbSCpEuVL0NuQl15TmLkEAcDmlTQMyJ6q
# DATA ijaHQ6lmk/LY0dUFQyz/Rf/PT43x9cd/vn9rZeWmG/+5urp669Yf4j9/v/GfW6fDaDRUwvQUQYx6WXQ0Sye9CO0V96IXWTbGKCc4
# DATA YIqHIIoA+qWcWR+ol+pAQvFgJCje8DitlAjh5CeERGDiMtVRHI70j/6Yk869fWTo8SB7ZX/Mpv2B+TVNTaynzfFi4kizkzGQiqWl
# DATA XXAxjHSaP9ATE9wbzla8tL21tas19QQWaso1EDnOwHEkS4/WP1x79ni3s/XJ5vp2h7+Ml0fjqf0oXnq2ueHVmCNR6vG/ZQ00NfJT
# DATA svRwa3N3e+tx5+n2FoDnubXNDk+XZYa3Zs+vEZZoMoIe72zsrl+1lpwE9idrn3bg884Hn+2u74A3o41wMS/huZJ9ceyd3fVPcWLi
# DATA eO/ZsD/dX3okxDCrrcc9y2ooXIylNbhLtofZ9HQ0eQGMvcmuPD2Asp/oCVr6AD2q2idKCOmj5ZnLLe1xYrz9JWB2bXXTg5xuS+uv
# DATA su4O+Au2zWHigxRVrfgy9koRXQ2BukS+kNhNYDFtJaws7W0QgOv+0icpMKkPzgIdU3Oh12L9w41PYXb27ExswkxgkOL+c8iyOoCs
# DATA EvqR4oIHsBTPh1KaJWyDHk2iKQFbP2/Hwhh2A0QMN1ESRl85aJrkROAmcqLvkEdzqBaceq6im47B17NDsik9rMiTSa3jf2WeJi3N
# DATA 84I7USDGJdPQkmZ/3HFKYiqofncq7TM29AJuoP1XgwwRXVYihNbGF/28g+vTTfOp+3iGuSbxpuHfaiSW3VrExbocGrvxFOpR8zfM
# DATA ptIlJ3bMlJT6HdpKTHI5taRg9FOVqMHkxwjyomb9YNLvqQtjPcJYUXzaXjGh6AQTqacCf7NsDF+jRQkvkeDJYCpNoh9H5zdvXjim
# DATA XX7zILp7W9sM4cpQGyda+d2n9JlGNB7Df+7euXPrjr2zUi1VM6Z1zsCOsLRrYebhQkdWb35L96Ta56vZAq+v+uodcPo6oNS8B9Ab
# DATA Xdki/XmEZIU/0Z6Z6Ul/gJ7J/fFdDKqMWzF5IVjszP44du2ch/E5fXgR5bBfo3MsfgFu5BDqymI8uZa3o1rc7x+iAuActQFwvSJd
# DATA gowUFaMSS6oHSFmoItMEyuT8UucHN35OsKp2M4WWFwMzbBGzzovMI9Ep4TrABAknZtodRz2s8txWb3qN+AG2VdlvPjeHinaSD0Yf
# DATA ztc58vOL6Px8CXx1VD0nBN2qnuA4sViHWcW96HCQqjsfE5170cXFUoRpwfn6AdXQZ0paAE3m8Wikrybq1jGagJtdY3VFXVXB0H/G
# DATA /b6nvtJLeH0wus6P1dPu1OBJ0+T0JqOxen5OewV002JGzqNzu/Yn6RiuWHU+UcmF6q2t2H71b+2YzdtznvIL2YUMnVf6+XHWq+t0
# DATA vl1tzKfwChAHTSUn2TSNBrfRG1QR3pd3G/3uiTrj6j8v79IsqR4Pe41h1j86PhhNGjlMCniky4dpD2ya+GyiJj3TT2A46lCpKR6T
# DATA e8jNO3cu27ijdxlOslQtJuYZHKeQ7aYxHY0aB/0jYjMN7X+CuaTVWkFfVAPqgxNnbmmN7N44pMD8kt2h387ZHwvshCuv1DnTkgvZ
# DATA efV/IGcYaMcu6F2NmoyZAzCBJfbe1qGbBYiSWFHqjhJCN9cf7m5sbVIMH/vnOqTbVoIOTLcJgsY8BD9exVl7/SP4UKgToDPoNQVq
# DATA Bbd8CFsK6CAiC4MjnhJOYpTjchDkFIejlJy70MNpT2046iiUDyeodngKnqjnvfdiTHQcTJzpdBYK6ZnYM70tILGWZ510PAbZ1qHJ
# DATA to31Qs8MHCrJvpRrFFk+Bh0ymj9tSwxPnPTVareZl8HLH3oTYleuL11rpZ1MghOXts0puQGqQVWk2/AmjrKC5Wxjo021xVmdZOiG
# DATA 9XPDGdCaff7cwNw3+QbA3WhS8SZ7+3kZnLz/6WGsILMhk98m2vRQ18YzxqznYILYh1Rqoxfv77VWb+pV1pIcMWOi0kZaM0Id5b1G
# DATA lqVmcWBkEeGUgZM7PJxS/ChBeOAHNL8ZPEA+pyV3V8TVNTWpQxg8j4lcyqrNY7ci8aHP37cJLEnbttIhyQm45JGqm6rTZzQd5qmm
# DATA IbXDuJehN2GRXT8nmPpQx1E8Z74PIg1OmdGQ6uE0uvjfQ/xvzJcY0X5S/KKiLGf0AzZ62h/2Rqc1gJHgv43H/RoykZ4ZteolRfR0
# DATA ByMIgkOPezWqh4q3HYxQkgJdDGCyRHzio+4kVUQ9b5rbydVWPrhgVdUttOJXW3VxEtQkbY6i0Sl4upP2qQ+OXHgfBhuoujGSp5a+
# DATA UueK3/UBHhQwKCsnJcep8KYkNpJPvNj8oLeQXdpQRIAIE302PpqkeJYiSuHEY0IHAnAU0wBIdMjRSWia046NdNq4pgRvLtuNNReF
# DATA ErLJRORoLkTcS4u2zwXKC9Wr1gIEL+ihWzdJuBUypawrKZ4uOukY6U6HYs5ixSjnfgvBBy7iMFkLLpRsVM3S1VrkOYI/V++cUB80
# DATA FZDQ2qxXYE9bgBc1fsQYrVTlOiwvRtvZ4YywUyIur2+XvTqqJkeTFB2EtZqyefICVINjsPy2sSlyBUbIhcP+q3bcxL3YCEGMe8in
# DATA hz2LeAp1e4in0BqNmfQt5q3x6TUdpJlwShiUClvGwosjZtrgzDmBo5wCvTiZp/nOlxdynbDXltBJaQERl7Nb2qsiAu+hMegKSk27
# DATA rF/3zVj1EDQ0qMlunh73lQwaq2cuQoZ6UJpzmwZd8PfWz2nbFF5zYKBXBF3CA18DHauBYNeZqTFcw+uBksQy9WtOeYzI/6NoZbRy
# DATA 82bV/DwbQihQ9OzDTyKxXrpeGXpIDelUsMIMqq6LDMSlC1E3fPIPT5s7nY2d7fWPavor3VccjXxYMmD/u+IY32KcdMS/ap0wStkU
# DATA imynDD1VQLFLiXf96SaPR2d6YQaMVXz1ppebt6yOmg6Cdv2v3LuY+ibvpqB/xAlBYTDeW2l8GzR9dy6WFbd6Dq4EVFdSSYFhxrkn
# DATA mL9jNjzh2SFHpTxESB1dlAeLQFyCatRUmZ1AJfl4L4q5n4mf66umjjWh9wMDmo11trrQmpd/DUlYFvgKfcTspIeB7Gy1Iu285eyL
# DATA tsWh+rjqTMQXyU/hdLDYucrT/xWMoHQUYa84b0PwnnxHay5zdLAxz+R3JmsBWwquxAONeRB8ik5GLzMHyemqHIqRwluWGFzOVMFK
# DATA z4I3jjBUqF83vxZDBVJQnibfYvH/Pw5sBupwJcMrzHqqO1FHr2kVxf+XxqT9d8i+HgD3ugT7Dk/SPKYqvLYUi0OwN0f7+Nzn+A+p
# DATA mecu0+fGXXb/FJeCTVA14JNp43Ct8WGztbz/XqIZf80y0Np3WnX7K/lO4nNUf1Wwl3PnqDg5lRzX30maOmBjoFF1cfSAPpEIYT+6
# DATA 1mbaAnduoiBgO0FPR6rm5r5Gk6iD1yx+4Z3+xUdzkA1GEK41HamOjKbHGO6FOg4ZYqZoLohw4fWMLaSuuoqbwLMA+XUYx43aXoCx
# DATA 7YuZQfFrDzLEWmYH7jWxRZWJpyPkhcOz2LAi9d9EoPyid4M8uHOZLw6DeRGPwk2pPYe7e5yW4QB0sOtXxnjNuJ1xmJ0VlglpfAXp
# DATA ZJ50Vay+ZKrmSh8udgh6osgbtjkX6OpVOCWtpUv3yJvjw3jvXM3cxWWJEhvBzR0ELd0lxs6g5LzgQtrNuFBeNL3dPXErMMssgQ2y
# DATA dDgbd8aYnJkQjLWDvnN24Z32snJSz1HQPimQ0oN8NJip6SUgnGaTvQtI5zPNK5j2oWZI3CP8qgXTPD2+EMhSXbURMBk2QkndmEDs
# DATA TZ5ROjyWGMBwAT/3KwJWEbu0bWtrDjzmzfMMKW83R9MPwcMwEEJUgIliADzk9483v1uDdgyvn0OgC1PAQpaaBdPPCwkHhTKWCci3
# DATA M4OnA/RmE7uYsoemVyxsrISsTE7XjbihY2NrxdYwmk52icLrnErM3Hxv99MkCTfrV+HIUI82tt05DVdCuB9eRbWCNObUBNOlHyCV
# DATA gpGtyqcsXLleg0ly6XVFzisXJ7TCfFxhar2zimDedFYJVsXrkHNgCwc8wAfCWaywAc5RtbX5+DM/S5X9vfkB5JRy6FPFufGBtKuS
# DATA W00OQrpePrzwDZ5a5Czwn+GollTL36UrLo5CFNz5i+6OAFbmYjvCI3YCjd9I3jXyLXFw29lbAYomCzf/UO5EA8fu9YAXCq8WPYyh
# DATA ULfl6WHjWxZgmTdX97g/6E140/D+q+QsliVLDlIUx7gL7Dmgm7G+BHrv5Hh8JtQ+xngo/u0gxQHvgIcItFV4K90+uJEEgE+ND3BZ
# DATA 2KAzq7tqItXF4MxZ1jywrmYwmqNiz5puMtPCJOIXchbpK75qH45ARtYX85yZd6DNSWZgBPC3s9i6hC8eKEHGRzJHLQWDBpZYFgjb
# DATA 6jJGBcP9rVnByRvkdguNkrXQhgMH9vCG4zPlEFN0d18mfLdMh0uu3r31rdsWjgY+K4j7Pi2Dzo3T/iTHdPF5CM5dOIcwKFxdY4AN
# DATA 0TejuC0ZHo6qWGAnCswnsvKSIxbiIfjaVwL1A0g5B3CxAOlnMJQzN9E3+U+PDiDHUAeH3gFHsjb+6RxxCQ83xSy6CBG3yK4Qo/Ad
# DATA j9Uj3hRoqifRvwZ/TzqQkdDuV7SXm+dVzZKgP1DDUDuRPZ7zqNHArymhLEMFnVL6GdCUO9sPD7XoRNNKxoVdaXGTEmeSvU2+JMRL
# DATA x9hAmxa9ibDFbewfKpHgZ2Gzui6oWkWBtejctvuJQdGbpt3jDuMeixGhehbW/Crzu03Vce2VM1zcO9wuesgnYWNLvEee1Pt7FkVz
# DATA pX735kXsd7t62/Gw9Tfeor+DBSflShdxGajaZTL0x+oPbpX2BIpEEA0MhTGyW3WtmR/HRWnO6OwcEkc1OFSNRbVnw76JjyyAWuil
# DATA 4g7ogNReS+rAKDlLKeZGma5ElEKHRtVlKiqdHCHWS7GqXEYG606QTmrxDuoO1YDPY/V4TG5F7IKZ77VuIn7gXuzFph2k+fHzIfvu
# DATA RI1s9nyI6HQOLYWNSNWAig4xvEE+AYjsrBvFZrOaMjAuKgGagSSQkpfGEpxYAKWAW03b1Ld3p6WxZZ0NgchYaJGAiDNWHvLntmr1
# DATA imgZFYL/6kKgyMj7rzhAZjwbdqczgqnoHqeTvB3f+6Mf339QS2KvNjCxTLN8DD6D2KqqHurwSkErGSY7wMgq56YKLlM1LMYwfTgU
# DATA tpP4p567sQ8Or1hynvukizKpPnCW7ZuM5/tvUItBmGbw+987vxetHzo8moDMlUJeQhjQfUirhEoN/cxUTPERDN7Lz3L/plm6Tbyt
# DATA wgfdkrhL7jT2ASQ+Z+iUujYM8mV+iSeF/7akm7qNp6qtThW/rzP5cgAWbHPGZWAv9kPa0M9sI0baX9OkcHZ42tHRbIgiZXK+m+7S
# DATA U3DN8nvg9xQtcmSiR0pAf19uvkD+oWRwGMHfgN8M2qH7DP824LoLJJx6p47YtLQoemViWQ2OqxMXhKaVBjXsZTCLYkR0ZTruo8Mc
# DATA vL2Pb3lztVw4VpwPLLYPO5AGRSod+PQ9sEXKz/Gd/AyK4Lrjp3tOjT7UKZVvRzcrlONmzPr24tSYhCtc1QtcwQxhnYnxVDsMe6zG
# DATA w4AlYcZBA9XNhLmJ4STEHsDhAkkvqpDNYBPGUXEwKJk5b6Fz6sTtFvVDPcdIZJNR/nQCszbBVdJ8ERemcJnHE6NFdCnxpeM+eYK0
# DATA vjrhdzqBWJdex1YeEm7NqXVKB60VhVJFudhHuVYL9tGMgmCMMGEaB3RnZDgiqYepuBhEHcbRhoQoBLx+FGwIAMpZ0DfCsR+KrZHS
# DATA eFHMjQCPoT8vwVvrlbuSDgE1DqOjEN8CL+u6QzHbTp6ia4FO8ZR5ATJ6affc4gVkfCn4k1sIAjZrYGAT5Wl8JxyNxTghF3zPTUJ/
# DATA LVwzYPVshfMsqSJZE8xz5IzBUc3J5XEAJmvUFKW604V0RgrTS1RZBwqCprKgd56zhfVKWVBRMtwHB1E2hlCuN2yWZEMmSbSVeCkA
# DATA dlIJN/IIQbv3bIdGhK4WLwXrrIUqjSuPP3KPEsHM3e6mjwz8w2dZHCLsJp34S9Kd39u8lW4BucQmBybyCbp4510lk2hFy1Kxl+Gp
# DATA cykTAnfcA1stkw1wmBiOvO3lqRfJGptrriO8DnXI/MnoJcDmGM0vYXWJBxyU6/B5CRFRB6cYffEdE/Zl21VwCmaDPYC+AuNNEkfx
# DATA 4gL1274aDU1/mpVuCtM2bDHqczuS8AmcdZOLSdtxQRzCKdHSkDfY2jwHwSSplLU4MpDzUrGvNzuNiB1lhqNlCvhuWWeg7fUFkm5c
# DATA VGEVZ0j7p3gL6YGGiLXU4h1/V+qx4HAdHXsndiRmnvAwjV0nHl9D5qJN0jR0bP9rcYn/U4mnQTz3InkYX8IbYW5tRW8FJ/YvKff3
# DATA BQcaw5LMgNuFSQihNXp7trCutYKrD/tyhDx9yhySkmQh3Edvjz/0XKPELtesgGZ7Gb+r3ORGdU7j1diLuU/3BumwlOZpolgXtG4B
# DATA grmkI2H89IpCbVwQBbmhQpOOYcVY+UCwZWPKZDTuo24J0HGaoDdBrLca/tQwkM2eTA0Gdmkl5BRq5bqki2XYsRCCyM8ajldgA7wC
# DATA mwB9HJPvR9NF/5ROfxF3wvioznPpAN837cFX7lHCUC4+rAv/WeuPba7aBuIiEKqF+oGGnzFxk/644IISUtuU+Z7Y2lDG1P0AHxmI
# DATA zbgGYexgsh7Dn6hloBIikW6TgvmSedOCq6BGy7azQ16W8/74ogkxbUvFdOQOScfi9ej2yrfvyiEbznwYG8Sj50ODcvR0lDPSEUbI
# DATA q4aixmE10pHbL0loi3go/oQpqnbXw0XRTllA4icVUYi177QwEPHHDKmQRD6Mig0KUat+ERUZwEQijNy+fYvDFyNWmEbXJ91GN1VV
# DATA qOF6tTVU8esO5QaDnKLNL9NJP8XVqM0NoVTbhLvK83IRuf2p4lmHsUGAwORVbN+ltLaVI1ErVew+5v7t2L0Ep0jfl3i765f+Vcsh
# DATA H7Fal5hDsYE2JeerdTQM6RTzfpN2wgKbg0AhgELMO05OD9ttbzmcZGCyWfcQ+pPgKNP7QQ8hPF+SO2NHnIqKQZR5E6KbFVPco0rw
# DATA CBWzJ1T0NMBgwenlJJ0AHwVPZKIfyO2RL5g91oKd5ash8mM1yV2K3T7IDBR1fAkh9lCJC9Ak8cYqQxH1R21DHdg47BfIFzA430eA
# DATA yhEvRKQ44X6Cs8o9gfeJyAkLnwUFV19EAci5yBdOygxxx9lg7BgqHVcHqzHXvefyZReXGr13LSRBBMfnw68AwhGIARQu7LLr1SCI
# DATA qjOovqbBBSu4BEyiU1sSOji8VCXTvOBtizq7wBoH2xReLI40WirkLS39Ww/5Ugqpg1HXhIQzAuVhdzgdkOFWveywq6FuH57FRZcc
# DATA U9RkSSo6HZoy7Hn4cHt9bVc7Gm4/+mR7nhMiqMnvajW56+zuOQ3a9n/fHoOu++ZlXQdhygDbXM+c9DPDdWoe4gpKv0p6DvPVWf/U
# DATA Fj8DB6FwtDsE0IMNypm2sBKnQ2732sU+dz1E9NOg6e8K8XnlEB8cRaIPjoiazVvYUh8CeQyR8a4odS0VhXpcGZl5Az6Ucpe6apiw
# DATA B5oyRfEpyKYWsq+0KVtjACDxUl422sezyr3mynabpQr9ttDmSO2aMR8tFV7519fLuEBdQuXKZrPNkXQoK6pZi2LGPeuS/6KviG3R
# DATA i85BW+nUqy/vcOv31zgpTlrZefJ9dO5pkL29wtBGRbWyGQLsVOrbfhK0Y+PHdZuoZnEDob9Ze74BXaai8L0NqnUj1u03xJ/mbZ7q
# DATA DVSxR6omsnIvvOUklk9k+WQGelHG+v1dWTLfbthcbsMyipR6YQSmq5Fn7gmql8qi94a1mNCou9MBUuZ+rlGoGkqgQ+XifJxqIZwJ
# DATA 0LM4vspBlXovcHptgm7zRXaW1ySHDHGM0uDBwDBT1fywoe5VkPDJbdwGwqge1Obp6upeh4J5mmwel8kJqtGWAumXGDOwJPeNzCrW
# DATA RJR1faOv4a/m+ubW+uZuPTK/dtefPN39zDxY/3RjZ7cqoVE5qaQD4FneaAEVuadIWOM8QShYJmWDTujlUlAGXgP0Lx09Kll43aAd
# DATA kI6eGIA9+RK2ugJdQM0XyNmFGHyU/h1gkkoLABUvhOKjMOu9kjLtHGASkkxpLv20qlgrpYK12V69RLDGv/NlfzTLOwF38+AlR0al
# DATA o1I1XMpMDir0zg1UqF0UDHSXjZcZioTJib/U7hdYt/PKOsvgOpe0Yb1bEJA00m4l9I1TOyiaCrKa50fjom1DcjGDmbqkNZgIw+ng
# DATA dJdjdLsr85Ywj0Dg0DpRuCXXo2AoBlCo/YIFAatx47rLgcwW2LEC+2CEoTnnFIOKtfpoQjJeyQIFFfun/fUoX481DxYQRfzIbGcP
# DATA +foCv7YwkIpThR8BHZh73FSdDsxDp+OeqpKPnVUS+N7nbCZtGfNdnh/T+WnpXSZs7K1Igp+5563lDkO9tkelJc7IRaGTpKIzyrir
# DATA 8M5iyWyoN/lVRQjCTZWOuYFA7gLL9dZcsNvCXd29xhqtOAI/NjHCKAQ3xFuuMmHjwtJJteVVhOHLLvoSrJw0TXkYkZekUX5UBrjq
# DATA q6vV8PeQkpQPsFJ4nLfgAUq36I4r+VRiJTl54TAF3JWSw+F7L9EYQcc62dFQjKFB477j8SsOglAFWn8R83HsNei8ox4E/E8b7JVK
# DATA 3wGPievC7dn8QKUSxlX0p6IRg+O0X9HtBjdaWQQJS2NMnjzFpHErlR+ru5j/KSR2CxfuD1GJXfigqoGCQqZsoE4Ekk71RmVD+d4w
# DATA M5tGL26bJShew5H7U9ZtItR7N29iCnDOxS0kgLLwHgeqCGTIVnnesnibpRkvj0igy3JbSVhxkoxlsB9+KWQhVyIooISwC78VqYtD
# DATA 8vvi7WkZOe/Ex3k9MfnMKeRsgcbg6uOeLj50rnd+cXmxEPmIun1w/ILpu0od2TztyXwNyjvRogR0GHrnNx1ZukSELnpiJ2/pDubO
# DATA HWMu7a3se+kCHS9lhJjElpAnrZgKrQI4vGV0O8VTuOCO9cioxe2ovBmFkVl9mw+ghx/2X0HogepxgxZVQG28HAHEP6jlltFWOVFs
# DATA PI/S7mSUWwTticUNL9xnv4Y7pm720jfgK/cN5kNYuhxj2aLWLse65eFmQEVl4MjSDsSwR2ELUGAnkSQQdqbco8B1EDZNCHsttIGZ
# DATA N2oc4kNd3BoNIJrSXobMoUNtiuRP3nkwd9ZSJoAm9jnHI0wCL6V28AmkSTQvqFVlsLa51fsjEVd7DHJw6BDryyrJWGsRyqq9Hq+c
# DATA jk9WVm3HE7MEBSUObzkaqnfDdZ1x6+FgkgpMsmB56zB5udsuPk/mbDkUcL2NJtC/S+m8dr9YkHC/u01cqvm1B9NfhcpBzEcvK5ub
# DATA cr/8BTS/JeefbjXv+uDPU7uVaARIDC/saQ9AFkMDsIhRpuwniVDXlc9Txd5EkbPsYuZtLJlVpMAnTBULZH3mRM/f+MP//hX/D720
# DATA 4Jx/Rbmf5+Z/Xl1ZfX/1jpf/eeXm+3f+kP/56/ifn5RZ/86nl8vP3AVVSx7M1nyc5pCI2fycngwumbe5Hj2dTbKngH9RksY56ypx
# DATA Kg+mbj4zj2fqeqHI4sO13bXHWx91nq7tfqxFLatwtybZ2JyNjhK90sHoiHwIwVVM16FzFt/khMUyb/GTtc2ND9d3dm1iY3BUxVdg
# DATA Qn28Rk/v0iOMHNOpju/eLqZFhmQIonY0u25sfmS+Ue/dF/rDu7cDnTOlHq0/xWn41tLOrupRZ3PtCTpyNk06E2K4S3+89Wx7c+1x
# DATA oEBD5L7iwnipCVRFbonb6w/XN57umgK2poO0+2I25kq2Hj/q7Ow++wAwaeL713oj3GS4gR7ch/9Gg3R41L6eDa8/uI/pHREKJZu2
# DATA ryNEnnqKQV4POIbh/jL9vD/WT+DyYz1c7y+PH9xfxuohQmHj0frm7saHG+vbFP7SHZ2M+yApILSRxjVCWKPb7188/77aGh+vfxoo
# DATA e4iY2HdvU5ndre+ub5aWunWTSq1/uru+ubOxtbmDIBZN6BVGrHTznDJ60j/5yyP8d/pqyo9RMI6br7j8aXagjmr/UAlb8YXa/d1B
# DATA mufRjppsujDbu7PRa+c6RKpThFHzIdTmwqdVQ6exctL0Jn707OnjjYewEf94Z2uz8931zxwbThgozQVJ477DTBAiYyto2xP6IsJP
# DATA OzibFtxAGKguCL/ohW8tgMfWEYBsOqOjRH7iCw2M/FEmnm5n3RmGO9A6BTw5CvO4sfm9tccbj3AW1d0WKSt+o6cHSZyHJugF+9ss
# DATA 2ImT+wBi9BlzUP1a/Raqa+LnzzHsCV9UdOzZ5s7ah+udtZ2d9V0kwXHiYBtLQi8zSMH1KwxxDJd2wpy8ptEONTKBAT0GeII7PlDQ
# DATA 3CzQ+zIhNB70b2M+aKgyCGsEL2ASzinkpNmMLyjSbTIVQFPNcEpJrxu177QUq/3xeDL8cTp79ePhbPBjRS/2VlW3fjwYT/GPRBV6
# DATA 3mzeSL7DvYLbdnOjeCU75F64UNCJCcPLZ4eH/Vdq+57CNUlrNCwRSq6wogHMyE5vhLeOS+87Z1l57z2Ibt65tcAReLT1ZG1jM5SP
# DATA xxAzrLE5gXzvY1wftVp02Pu9Yap+6rOf5t1+X/3miSqDcLvMCdXdk2dUYqRxTncablXyct6zaktI1nR39UK/wV2iWJ20uZSHjsFk
# DATA Q1lLunXKg2acJMllJz5Io0FVW8CldXyw3gHgud7kcAc2NTXVTjt2kuWW7WsK6bfb+n90AHSYjiMlLE0V2YQXYPedkvgLz/oHaipz
# DATA 1FiAuv3V7ZWVOSwbJ2jnsyePNza/63qIhvHJq7HE5zQmF2Vt86ESr7e23UZro5wcKUHlgZh5ZHkpbzLoqFeJvF6FqL7IbH2yvYF+
# DATA WSVDsPPWFvMm/EdzjDp8+9nEzmxu7XbUh+sPVT8+u3RH0Fvi6tDuC/dQ1ffs8do2XndK0dk7ZHcSCNhMQSSlsYrowlE2B5ljLm/I
# DATA A72fFFK/2pMbVgJ3TtIXmUXAt4D9iCR25075aUFCZasvUCusHQcl6rQjC02N2xUaoNgkaMrq0Fgthjf99hz8JqUOSjhfwvjn5vcs
# DATA eiKps2qXDI8tZ0eF/yBT6Bz22tQi1VNcSR6fj8hfvgGEgw+luG17EPuaPI7A081a/ogoFl5/sLG5pg4OvAzZBDsCyR+bSwSmvpI4
# DATA svQkgBtrQuSoxILI+hq6VRw5+8iNf7PP52Hm+6cRtRKPN55s7BZR8rm3ZTj56eE0m8wdXQhNH92rbZ/7w1HdG4L8fQKhDp0hQcvW
# DATA sFXzlflFH5mf5psKkQDH//Djtc2P1h8VAfpLYjidM9XyNrHJw+uYxTULu2ZYWMsNEHSttMKUGN7Q+MvQeN+ivVSZf4Jpj968RSk6
# DATA dLeAnHEofO2ttjycSY25b9uAawtWbg58KC60NALSua/LUWBLIYGrMv5UqweuyP/LoOEvIwLQEtvOXToctEBzAjmn3wm9r8haItpN
# DATA 5keylNDny9ks526PomVSHmF3vsUb5zgQk6JzVnANCbItXhPQDWlNci2klBqnZ1AGuBUBbglFtRMHWtBAV6d9WeQ2SpSN63yysbOz
# DATA sflR8U7qdJdhr9q6376CzOJvPJ8QbreLhWKyEutmQVcFvwssDhuSoAc6gS9rB7iAC+VNyfvwBQKe8FPgf3O4nL6/OnPySP0rsbVV
# DATA 8Uk6wBSj0MaegPg1COCMpgOIGmihBbMKuYrW+Hs+l3H2Mh3ESQXwpq2meTDqndWxqocjfE1QnJgKxCvWdFODKG77DoYO/I3HwqPo
# DATA QPf9tr08i+NJDT4kkE/67B30ZZKeYpb7V1OjsZHq2bCSdedsOE1fBXWrig+raby8mjXQx4A+B9U56WnCeAPOEV70bErBi4UuUnVD
# DATA xSUKNdJHY6YPPBXZlIWra2BbyLvH2Umq/b9zUlniboJCe/r9vp9hxn3rHayFZkqLUKPTnJXse9yH/ZKRQFEBP+uopOEdaqQdC9sV
# DATA uxQwc6j68Y6omnFBWYp99CZbPeG57vcwRgvMUOSnb0IEEG0PAlFx/gtcq9jGHlS276pJrclKqgZ1WSxmflm9Xqg9rWT02gTTi5f1
# DATA g582SXlqcH31c9jsJ+mr/snspAyoX6Lye4D8POFckzE26QpB+1Yz07mqZBtAL3Rn9dbdlWQ/Sa5AbGT8LmP54ezRMlXBJHOAt9kE
# DATA 8PqW3qcUbqw3qrX7XqaH+IETXzzoIWIbbDc37JjkFRGBRHg1wRgksgq5sH16hOphs6vkL2gK4u+GulEenxg+N2Y3Svz81coKqmV1
# DATA P3iX8E+feCdzEFkuP0Eam+/8nLTSFxdOd7Rgj6MUlho0uyaLyvRUdUcRnofrH289frS+3QFwzfVPd72e0MxBhEnNm1dXlRkjhj71
# DATA QhtlaCvCpN5euR1+FaQe53F6MJpNjSUZfy2LBi6afUwAkqEhn7fpQvq57fV/90xdLh8pSfWj9R0rPjr4KznvTi8sHzzhhuDFCDog
# DATA lJdN2KbZvu4TfR8ZesZC3LZaWUc6cFsn3KSb8UKjAXFbrdvjxxtg+iqanw0F3SeCUGre8GR9nUfvXJGwlqFqmqiRD2AFf0guJBfy
# DATA bhMk6KnzvG/VYejPSMwIrW4FCz5MWEsfASutiyNSR2cLjWlI1dSjH85GU/bnTQxpKBwaG4WdCWy9CrrErpaSxGoqxRk3eK8YG+B8
# DATA suG6xbMZS88V8efZSVWF1d9fQY7bXt8EuiDFuNDeoeVD7yMz72ou1BJNtcKWHoP8x1ZVXmYpU3nbxGCnc02acLgyTcDo8t3NrU82
# DATA ibJqycrtvNhv+Z6uft9sPWPwOxt2pSJM6LraAV3XYjqKavUV7bPL6MOCeueg5gIVSTCkkMIhGBNcpbSR4bgksheUNpfQZn+yLQfr
# DATA hLWsf/rw8Veu5mbVD4TDlCi7WflLw8YLif/qcDDLj4U8Y+a7oDfmKaTz23McDHiH1kSwAHsYZMNccZAOGvXbDNgPVKgDsDCcaSvP
# DATA 1C5I1TLl7VpcB6LcihOdECYp3Dq5H+qDk36Xp0N2pmTl4MSMJinmkMZdK9wQhaMdTlUDoFPBl7EJ/7mtiP9xxnmFeAuZ2ur+jATU
# DATA txWat8WP3xw1Ia+dZjGif8V0q+Fw9dDXfLTFKc8n3Y5zdtVByqedkuNsqVFTviqcWyaY1GaJoY+D8U05sxP4RVD570z4u7O/GaC7
# DATA Srub6BjPXlhtqU4a3P1MFk+O+aRRULhkIZMwPC7PJGxsF5Osq+59AiN9OpqiTo2CNAFQk9NrcUPqJifyZ/H7lnsLmkBg+RjJJBdo
# DATA jkfjWuJteF3WDUty2IhjY5nDqQorSPWXHphSnkXffaVcizMvU6M6a7PoDGTaFb/8ZBs8suLQgxmdF8v77OV/5o1h0j97zs6gfMIl
# DATA fhAVfZlbpb5NYYFsd3u9aM70zxRgoeOwo2UaCS5QeAhkY6JSlBo9mBU6HDaVKbmp/zLTbED/7kxHNcaDhLAutfdqSdkEVju64GK+
# DATA jf9PmdUmDD5iB4YrapJOxDY0t25GnZR/r4+y/p6lJNwFYGIOf1kOfbKAzanEICgAYz1X+wbRr1alc90VN6Glju+1na6Ulu71j7Ic
# DATA KDXHXzTz4/Tmnbu18vq/CmeIIOzMWzhIhP53CaeJkrV9h44U19zlQb8F/aA/HOERdPwY5BfqZ9Ka65u5iFtC+Tm0SSvdnld+RgzX
# DATA fDy/jwccai8dQk7UHRWS0N+t25qS+a6ovD5YY2uhTK9vM0H26DRnY3CrqmHD8z+yM9sgPe8C35GSykzQ6le8+Iu535R09Gv3vnmX
# DATA oy+wH8SZs5ynOBzeA+pqRX/VZABv8GpfKjZdwlGBJWSPZJtLnFaRsXiUJLJ/RseCaDGuksX4S0twSseLOgT84YnrjrlR+tsVo90S
# DATA VzmEeUdUr7hvdNfn7obemX7XrmjJfNEfkiaVNVGoTEVVlLWzwWt1tyna265m+7SPsXF86MOVIf5AKGW5N8Q92/FFLHz+J4XwEqMh
# DATA xII8Efs4a+6jgDGHCrBC1s59YQjGvuV8ELBzlbaBq+GN9+P1T4sDxXILhSCQb/quVVdazTPLR/1h5HS4aBgLGcUCNnasrrLzWOJS
# DATA hkjZ8wUcDYHhKPKgpOLB6Axgy0JaQ/tW3WVMnKYjAWOGmAmGXQY2cOPlqk7g5CqSpP6Sqij4Ja0j+fFiGIpxEZ47bwYJ8rA+3LL0
# DATA 92UtgjDUuBBa8TSbIIAi+3+UgCSH2c4Hz3Y+K/p5OLd6KdtKRKEqoTqgowvNkNRGDKdxAEySop5P8pfdybTwlh5jQK6SWZzMFPzq
# DATA sdoZHzyGdB6ri2joChBVztVikSQYal7E780PCotVjWR9mUW6eqaNjuoLQk/XBtkhxNv1j46nLqPNz/ImUGJFa06cVD2Kwc5exUk4
# DATA CTQBVPUPWAtMAfXNh48eP+Y8BbM862BgvYDSOZwNGf3DbCmugjAf1QZJpzfVtsKgKt1J81VlVmqngWY6OcIeYbJ76lu3gzCO5hc4
# DATA bHTG4sGc1zP1ft9tBTBhIMa77VRS1I/C3OP9EP7oaF2vfktrAq/xr05AiapbrDkVoGDMKn14QRkM6041bil8o4vdpFTXpTmGGey6
# DATA J8anVo0W1RrnsAAEkRrE9Z3PdgzcOtI082vr6ebW7s6zp08vKtaQDgYfnloXXVRB86f4qHliTSgIn09OjaBgyafqcMBMOdpr/d7u
# DATA RM1cTHlPLSzehDTDYX+KdVCvrO1ubG2SrmVH5K9d+JAFzsjcw1V6euaeoOBo1na3nmw87GgDsOK3nWeba99b23gMLuDSj+drOW6L
# DATA HrnCsaNlJ8UM/lk4enLDQDHxu1NiODJH0atSHjN25OVzVqzULS33Gn+y6sOi2uDJquNYXNW5x8gAPJUyaLRloVAZOmZLRRZ7tf1E
# DATA 5i2eOWkU8E4j25OuaVfmpr9OHW3i9j4xJINQOxApT4iXruHTuJ0QoRDh/UEoQjI12Mp0L5ejmFrLY/jbCKVwnXPojW6vLSpB/0d6
# DATA DmK/X3nOhgVd2np88PsFg4U/WHv43WdPEfC0KviZss8UhPWwCmAE4ItgqVPkDrzF0GFKfFuwRAdVA5P0VF+zS+4Izu3AIsJ4rh5V
# DATA N/8iMr/I9WvTZRi4fuuw1M2UpOVsoHTSPQa7QKtM/8AFVF8lpkyFRuId6BRsB40Koc7YdF+3LoHxcgoqBb7U245iDcUdV4aIUQ3G
# DATA 4F5r+RA7jlJ78qJeVEfoCcEp2y/kiq0FtQNcer56gAsmyeIaAjqxsZRk7M6yp8C5JFPogb8NZeGSwxEsnQQSWZgN69EC8PSXpxvJ
# DATA XXpaJJ8otlglD0/MPKmLyZerVC02IfiDp8Kz8QghzQWFRE7ArSZzDrvgIvVoOnqRKRFyNOjVo2F2yriKdWZREiNCr0OItC3ZrAMl
# DATA XafoY9G0I+YJFmGRiHvZS5hT8Y37cqFbKc0x6sM+29ldfyJkQL09nCbUZqkJnCxwAcIpEm4NXoA3V4OR5isrbjRO2UoKNU54S5sg
# DATA k2BJlwYbrbUhoq1oVdPRViU9qxeEL0nMWgFKpilxC7dM8XPa+63obY6SzG5CMpHmT3qfkbOMw0Pj09NTCjuDTajIVninQgH14nKx
# DATA x8wQvfnFfaH+5iPE8hLnagGxQe52yB0x6PG0KXkqO1V/w4FzphDK7LyDGfRq1YvCZzumww0P8I8LGTdldhPyZu1662Hs3YhuzptB
# DATA 84W0tmt/PWflJOAdOWQGIYRIJjrsD/v5cRk9c/SgfIMQXq7ZAWx+X/rCnSMzKh4VijjOgVgiRBlExqhFKEqh6aD20aWoyLdp9/No
# DATA EifpAb3SHUE1iaohEAbMyfuoXF1Pja9/XKwDbUjedire4AxVNG5Ue1xFnWY9CUQr043IZTQy4pAXuW73XyHBYJ4Hc8zM20pUzQ/U
# DATA CRmir1zpnpUqSS5eNP/pF1e2AHIF9ZLj+PZiN5Ezl44x1WKCVRf0yUjilpy8O5l8AbMddtYTUhHxsWjFoqJJWHYXg93XyPRyF4Qk
# DATA 9+IlOiRNLyjQhzHkfAkfVmG/HpkftAgBkT84W7B4Cwj0WKz0EkGLvPAtgoubVoOxUh60mqWSEqcz1uPWdV7mxrG7vba5s/Zw10YY
# DATA aeDzkEHcXmpQKi29PblXB66IVJ+L8A13Yy5dRhgNfCrYjhURLWeZy/WyV2MlymJUo9gHhfzTzqIzNjtdPOHc6Erecl06i6hH5l1E
# DATA urMJ6rDabyVDsZ3opeZO0KbD9+r82y5/og2TkO0Jyht/EkyaEJ7OwjVUd9/cJ+15t6ltBrhZ7LzjG5yZtu7AXLU/zasr6lIySEF0
# DATA lqoEkSpdktwdjhhwCRUB19Uzc28kG6NgLSVOQg886R9hAJd7tNxPl1yjeHFcVEtSvekvedu3Z+woc+Q4vbww65TMiiciaAcxNyIe
# DATA qbwNhft4hX5asdFtpR75B8AXpcPHBO4b3ij5A29Xl4/dbsvA9Rq7ahsNyLgo3waEUdFTHwiuVBwtmOqpfVOnu3Ev0UlBgerF81BB
# DATA i+rBI4NjxnmX223OxIslqtDwXGYogQFIEogdXIyrsG3m4db31rc/gzDwDx9vPNyNkyq6ZYY7/3gVh1VcyeLikK2zhGSZ0276hJmO
# DATA +OO51LJywF8nb+QC1wzDcVP6lnOxhXBOA7xpfjo+HQVmZYnKI8raCFua1Z9JqfAjjXU4v35Lugd8XZMWQn8p+NJ3zncQVhpp9hna
# DATA u1a/E8VH2TCb4JZUH+pz4ul9jKdiywhsxndxjjByoW/J6pI87acDipDWp9Vxw+GH5XFoxiUjHPV1mdhko3O4THiy7uA7ivVy1DQ6
# DATA xuLy4V1k/jAMgsP8weUqFLh12J9gkMkQEjFxCd9fQtv5sWh52l9vUfwvLSKiBMWAa2Ox6Wrv64KDjBe6Rc0tGroVCh95S8DlIlTu
# DATA A7IJOpEl18jdVmfJSBYcaEGb5yw4SE9ifguBUazfMmSxoqpQSNhiPXIMzWUdc8aOSj39q6CMM72tF8HxkrcdQShceJE4gCofQwBS
# DATA yyYvQ768LgSf1hn4TNW1LS6VTAYrKZNihSJEl5kBvJlBJvjYdA50bCSjggGB4+dFYB8xjoA15N2xA5/h8DPDuSTL4KynjKkhblA+
# DATA vkY7niiiOTrB+BCMOdfgAOKiJk2QlUgcED0OCkeuytCmg9FoEHCF152wajHziLwAqGvmxh0MCDBIIQvrowDCZ33HAMvZNXMcdhyD
# DATA mz0bVpUTcDHny5gtvajq2oZ/F7TXalZCimsnBJ2m28a5cG3w25cMTKEqqUISpuD5xFLyKt8u94wq2IYIIxF6LEQ55yayJOzVfqsk
# DATA i5S5/+sAqJcZq38WMVaZTunv/MuKmOQg9V6AZBDCRoFimLtXMJxLkgvTOzdgxqUJopB4vi/JhCjCz/Yv/FgPuaGuvIEW20SXUjsG
# DATA +EDomhEYRViFWi42L9550tYF9i9JWTRF8BaUw+dOA2Whb3v7rktbfbGvTKRfhfBQ9z83b5zwv9IOVG6V0D0fnjHykjMZV5nqCqAn
# DATA Qtse9bvkRtzvqQ/7h/1sgqYc8ZMRoHT3a/M3icXbBMkUnojq2u0iH0+sIjPPBlqvX1uQ33v0hvg/J/1r0hBrPFKCJDMssy1YJn6l
# DATA 3zg3d92jIBzWpSGxJGCkg4ul2xG4WDa2/0UGEoSP61Ow/wc4bKUXgC/D+m5CrCTy0lFcFjhymk7UFQfjvaGby1EBHoM5FxVs+hgl
# DATA ErwIS5iGfb9WC4p1+7bbXwbosEhy5zy2GxLjhyEEFVmllN1HWXNyNBgd1OIbcZJc1AGLrz1ITw56KRZr+ZnE6jpLCEUKhDSxPkLK
# DATA MGO1V9FZp8IZyolfbZlNaiNZW1pyDYc9c0RjSwP9eUSuDHrTUbbN3wcXZa2zO5b0vHAIpePUY2aoxLNnEdVc0LPHMUMYLc21gAfI
# DATA oqHlUtd9WTfGjmOfFI8K2QSl9MRUrxcLKTHIW5DAxXzPCQpbAb+6MuGrbPM5slVgTFaq0jMlhSqNboipv4tXMSpYN4rDjm2t9PYV
# DATA BEsvfl3uZRAovvC96aP1zfXtNWEu/kqvTle9XVgrvugRlUq8uAkuKqJCZKMa9HlB/whdGQbhXCp6Il70YgOeRaX3yMS5MlaVC/s/
# DATA VQH2GD+BztP1zUcu3q21ZpTIwJdR3BQNF4ENi+Nb0CeCa1ponHZ/B0ghm6NJzCm3uIccEWlePL8QZ7ymsDYIAt/Wz8BbllrUA3sr
# DATA WzfTo17HW5egpz5fi6nx+V44Nh5JNuEvkvtarpYes3858HrstDdXmrTRWIuyMN401s5Y9/pgfPOdQ1/N1+j7t1QKuAoBbxqdi4U3
# DATA aSVuyVinw+XskKXKAMGgC6wN9X9KhH3p5rFU8uIEHaEoz3pzbXI0g8l+im9qAui5HW8QA48OZsOeYuORIn/pIAIiq9lFjoRxNJtG
# DATA OG+g14KcCNDnvGkS6kLNgDHeSbmxWtxoSNw10Eu2nxo1QdkXJG1WlhE4K2oSUjUzRola+R3NXmNCTp2L9YclIGAvXZowEiamauNU
# DATA twZzdIXPeNss3EFNnhtiE2k+jABr/B3+A1/muGGSYJpqeN2EjhfOPx3g4pUfXSnwM+54wSkHXzpZHK25X70JsRe/jBZD9W9WgVfa
# DATA 3XjYFC1r51WN5Ycz1Zk8ErsTiWJwKutm75utAL3w9mlhnhyR052AujNb9dJJ4DdBVWnRij9/nu2cLTZf/uTw96mdwl40G6q7Gcwk
# DATA bBmoepYrqloyJ45FJDgn2jSCP6xpQm6BqlkZT/rqSAjgZWp6EeTlpMA6VuaZsQK4IIUOnMdYgpkK/g2X/mJ/lFwM99w24AzkU3Wd
# DATA nxQ6tKpIvjmuJuEMqNpskhUB2W9O6v5S2IrqVAFA/nBxRfShTgcVWZ0OrEanw14I0DUl305ryHPUhH3j8v8DroLrr3WHzfHZN97x
# DATA /1bU/+7evo3/qv85/95cXb11+9b7+hk9X119//0734hWvvE1/G8G2BGq+W/86/yfn3vt/Dqpp663VuvXUdS43to7v97vXW9dR8Fu
# DATA quiDOirX69cxS4V6/Ppv3/zkzV+8/uLNn73+5etfvfmzNz9985PXP49efxG9/p3667dv/lQ9U09efwl/vf789W/Vx0LggSr+T/X6
# DATA n17/vSr8k5Kv6pH69y9UC79589eqyOtfwyvVqCqqqvwVtKb+71fq6a/f/Ex146fq379RH1KNqvhv3/yVevmL1180VfOowrreOr+u
# DATA c6ioTty/1hshDAQmvXjw/PnwPvwRDZSE1X7+/Ho2VP95cP84S3sP7p9k0xQzFOXZFF6i9gzf4xs4tPD4ZT87BVgk9afWoMHj035v
# DATA etzuKamymzXwR11bAhq5Evay9qqt63g6HTeAvr+ETx9SLY0dyFvWn541no4G/e6Z1wALYY180o2ex3k2OHwe34toyv2H07NB5j3r
# DATA nxw5T9BVrnUvGh38QC0/vxoqpgWFD9I8a6i+iEcAytIgMcs+Lc6O2ARe/9eil/18hlLvNDsYjV5EmK5GSblHx3AnOVaM5Hg06OXI
# DATA CqfHSjJOFVuM8hMQnOkyAQmVI9B2q+eKLZ1EWZqDeWI6AqbYjHams94Zfjua9PpDgF1iJFkl0IFIfQKAkNhr3OoPnoJqG8SbQ/Ae
# DATA iX4c/btZP5tGL0cDJfrdX6ZC99FfZ5INYBj9Lo1MdfcQfi+nudov+TI8b+Yvj+AdypRQ9kRVv6wevvfqZICtyppwlfLjLJuG6oMl
# DATA aHbz/JKfoZ1Pf0ZLARD6hSI/gBIg2GeTB/eXqaD6A08CHBNI94dbBJVA8LkkFVi7OiwDVSX26UV/LHvzTWBfUGhHvYDV4X1wfzml
# DATA 0watiu8P4GLhDMea9qAad1VUHcP0pZJR+mljkB7QtDwBuUk97h+lvPmghZL6tl5mEzjHWJcolav9089yU25nnMIBjvi5Xxy2oCm7
# DATA DfvxdDR5gWuDRZdVf3hSYcAkGvbgUz0/9zk1k52KMdh64AuiTKsPdo9TtYRjkIlNQJva4upvJasNm6r61Qf3x6pYFsG36nicRcfp
# DATA S/XH6CVodyHz3zEeAEjliK9hNVDMhJ06akbqW3VtRnc4JYmr0zaFI3Y2msHSwcdaUaWPrmp1/OB+r//S9ptIQ+7vjIPZdOodGHcp
# DATA PlBCpm7mIFP3XsDb5Yn2agHz4GjYU6faqW+RRVtWfYV9TrMdmHZ+QJN+88HWJBr3VcdmYzVJirQcztSkjEYDmO6bMN0P00F3hubI
# DATA w8EIpf8sJf/uCKl91Jukp0BxwK8PZlitl9kcUW+U0VL2simgFaobhJJdZ3C2VMfB7ovANQhk1B0pEb0PSnCa9cvsPzPeZdhwD+4f
# DATA KlEeduLYPVFqd8mpAK0v3RKgXps7StWnCj7Qa+90xSYig2/WkLL/UXoyvgfy+su0ewYdiv7ff4ou1X9aNd3rZSBKcJ6Ylyumb5v9
# DATA A7f/A7efx+1pW16Byb9jHn81Fj+fw/8PxODfMX9fiL1fjrt/LcyddqQcvmHo/3JOEBL8+bxTUfpRnmkOuqbZJqnzVIvI3TX/lEMG
# DATA uSa1wxwdcgCkGrvaVqhW4SXiKej2J8h8UYHnTQROD4o0mgXnqE4bZOkEofxPFNNWO2tQRwasBtE/yXrRwaw/mMIIgD7mNGTV02c5
# DATA fILSlu6fHgG0YDl6V8sDuS8QkDgwGg7OmtHGVMtwXcjzDRwfJk6xLdQ0W7O2FgXSHnAYVC9iF2FRGigWwFnPc8Qxinay7EX0Q7VX
# DATA wFlLGxeOs8EYdVXQySg9PIRVAoEkPcymZ2aEn41mE8ujeWhK0smjyWxoRM0DcHbKJs1onRMNwZTCOGZjkFZAztS7EPZ4jjKMKgAp
# DATA FEYgJCnykEOZdHA27XdRulFjyyZTsPEfqSGk4H+hXdugru5x1n2BKk807aDa0+nMf//J/5bzWEHLi35BeXc0VvWgPCnWrBk9hPWP
# DATA 0C6PiBdqYGf/H3vv2uTIceb3fpVyaLXsFgEMqnDv5ow8vEn0khTNocRwiHpRAAqN0gAosArontbsROiyu7JDG0cOn4izEY6wHY44
# DATA 5z2lFW2akqgI+wt0f4X9JOf5P09mVlbh0uie7p5bSiQbKFRl5T2ffDLz/0PKVVh4AlE9xiuiKZXUSAfKHldq62FMfdEkqrAdCIoJ
# DATA DGXJ21kec2oTCy5seobuMDni8cEAVbHm995OTmZi5iEjZWfZgGoMdqyVoib1VG7JYIRTVKmVo4cbRFLRx0kmRYs9hSmb+A+jaJ43
# DATA 6nAwgO0/SdAYBgO+foSAYigkQniJM5NGD4ST1bwPE75vyaVGt0cpFxny0rQoBDpHhMeR7iSo+nyA3iZeSBIoaLu5UI4tqXJzNVet
# DATA VbfK6BEZi0jiCQVmsmLEk5dCQb5HMTYblzKIe2A33lA6GA/HS6iE0lifKx2GiGLNexOdj+w9QJGkGBcj6ltUdaX34PwW/yZVSln7
# DATA V57m7DbY7DTD2dFMvjVj/yq2/jWY+kWjiez97zzuJ4/IfPkZ8DV9rqVVuvIEDz0miyeZTKr9iObCcZIeZFMKevwE4T6ehinVhoP6
# DATA IVY4jlK4fg6Ow3SvWp2H8yjdPxwkE3pELpFdtn+I/uvA78wf3fFr7ZYnvyCs/UPsMqcu/6R6kobzgz7VwIdVStvwSfhYgoln1EDi
# DATA xSG0/atLbB0lWy+qJqMRJeigFgTR9El4MEY4j/meIVgg3EiqVPkHD2fUdg+C+aMnUkkq8Wy+XFRk/1YFT2CsecxRVO/Sd9bk7+Nh
# DATA nNEwfEo/86tHk+jRIY0WR7Mqb/k7GETARB/+lFpnPDqtqvalL9P8lIwWjKsHzeb80eFcjIMDygnqMz2/5uPvoZTAgT9/5GU0pRl6
# DATA Vv6tZDQ6j9mimNOUXn1ZlWYaDuNlpn6WLxWKgZRH9UTi1G7VD2kqlVE484R514elbDzABEblSc00MZ07+ZXHVjSpm5plsmNqpTqo
# DATA oH7MFir2cmfR8C4WnX/yeCWhnHw7AKliKogDKhmMKsPHyTwc0GzwoNZq6dSoOSBVjhEZCFmV7MEYI5B6tHiRK0XpmlSR0kVdYcr3
# DATA LqfULE6LVx9T00aNOWiUCpXvorovP+u6TEXzROJB/fXej3mKxMM4tcqf7FsXUZTJT/ZX6jDPpA/8ev3bhUrXpkq3oXbh9fu7t+O8
# DATA 6qLm1jpWxdWVraETUYp/xboo8VfRDahpHqqo8mepxNXVToSaXTUbp/TloP6kEBzZ6j95rCNXf2IyxMoFv1unsKmyxT+LDthyomHq
# DATA Cc+PTPs+SuPh4RF1Q7UGp6zQTOp1ubvGSTLPbOoMOJgOQim3fzvUJoU6AnWByv/x1jLSqfNrQUuHKhlI8YqOaBR/bAfcqdfNI3Wv
# DATA 1qRHnoz9yjiojBuVuerCq4tkTo+Pfen95HWYX8FMloAqIC1jvJvO94JaE6+utGut45NKq4Yv+9Sj15sqpipP9g8nZAlRlYDbFRGQ
# DATA X6lLYLJGpVqrN1r06OE0fKTS4LcH40MVqX5C7XNKCW1wpIPdIudLd1ppUNQCznhEze9eEDWKS9BCdhbfzW9uyJvpJZ7KdQqxUQ6w
# DATA +CS3jCfIYJ20dmcwfhJPjyrZ8ZGpNUxCO7Taq6og4XKRPJE5cYX3GciIrpoKcHF+UKeKXMGEaQ9PelWvjT7dREQGKTukC+tqeeBi
# DATA dzmN/YuTKJpxTfZrrVJV9ust062YbFtXc5/U2HshedmRvGxKXgarealzLahThVg7DtFcopgg7hfYesB/pOEFamjlv0/YHXJhLpTb
# DATA 6aa3e6GMXMqrfxcm8E/KpseBsVQOS83ySQ3eoMcQT+AbR/GjaHj4syr7YCjdh2iUVR+lfAjiBuU0MnpDF226BaSTQ5Yh6DFCwZNP
# DATA amTSJLpzrAozsI2yK/Z69B+zZw1973I6yw78UerRv5v6N26gHL5XI8uBXsNp5S5WmzV5kTZb1BDk7lF8tEwjY0jmVwche0OtcGrd
# DATA IM3bJ1JV6/Jr1VTi4rrQLT3vSxutKYO/lDWtel6t+e71dVo9zB1SMQo7NyY7U6n7Xun+WnYs+UUedYbFuyjrUHKPdyjLNJrTrHCv
# DATA UaF6ToWyV69QyVK3kcfoSW0QpsPH1shijTptHurLtTBbpiMc4b7Avthujsp7vfkBZv/VwTieDFeTybfU4D6v1KZLmpQ+tg0EvkIB
# DATA 4Xe78vQkD0+wLd+2Bnpr29R687lFnWyT/m3Qv22YVqVy4vpZKAD22RWbywZD3QwwCKTUG0qaD2aLseTJXjDb93RaNpVEsGq1PakZ
# DATA v2m5rlM3QMlCJ2Fu8ZQ1IBloBn4MrRj18QEhwldpDXKdLto2X/Xswa9Tx3VKT7zYpY5SZqoeR3cvhVbCUJsnNfgWjLUX3GS9xJt4
# DATA MWfVRNRjS03Mt0u0wGBtC+SwZDPg40JnJeae3c97qs5tqQMqZTx+NNfNKK220JDu6GTMhyXRWx3QpIx7UR2jA0rK4tSkkUfCmmxb
# DATA L9jYtZa2mlXzC6Rb0b7INZZ2005d/RB3VXkBR70l92NO4sc7mBulOQr1HDRvigfRYztLyvMx3Rx185BxtyaFQtPLI8uIMlGv7zBM
# DATA yLNeiOkGzQd3qCSFuuGZbwG+waZbbRD2mFLsr736bgZaMZbe3BqY1U8ZDe6zo8clvwE1kPCo7B0R03ZL3TQFFMgkMi3WmW57dVK5
# DATA oWn2w5Jtq1vSythasgvKXbgYBCpITyaFeOTAt+ZZfpN7SmkKeUaXnTfDMBtHxQz+8TgeDqPZTwoN6F8JHjCcLZ5Qc3ts/GCP2HS3
# DATA 50aYH+Tva17Q9O2s7G5q2CW3Wzg7PYEb+gnWRqSUR+E0npwevEUmVkLjcuWz196P+3rv+wfJLPnstcqU/nC4xTZPeTmkcTieZFY2
# DATA BbvXR+VLeVzySpWdViV7Xb/TK8xuuQmrSdRFzfWwODpyjAM18clDbNjD/TqjcwcDsFzlu3ksrdZn1YEWxld1Q8GtwTOV3fyT1GPn
# DATA 3urSTHRDdajN48mkmiYnF1vZyqZeRHNT6robbeY/oRM37b+pOugFXHgcXrkVPOGfdMFRFzkJ5xlZJeqDPYG2ayAPzItxZTGUaRnn
# DATA xQFiUxhHd6qMi2221pMaxSB6zD25dOAH/p2qz2Oj5SOyjAaxGZLlYr5c8ImEcmbJnIp36VexbLPGmsXxtHCRpI/1sLvOlpUarTs6
# DATA U6Gf/OtpNIzDPctEa1O3tv94o9PB9jQ02uh7lVeh2FqUTbI6OnFlkVMUmO5KNtl1huenG+efpUbZwMzVzsrifNI4XVrcV/Pc6FLG
# DATA mDZWN8fHfvn6KWQDiw3FGeKO2bJiMGyelgcj7WNsWVaKfvCePZeyq2dQMp+1GbtaL5oNrhechxVt5W6MD7tlxPXCo3ovL5zChCIQ
# DATA N52aahaHh91Tv3NyuRNZM//hjpyqkkn3nJc0s2oaDZeDaFidJlws8pVax7o1MQ78O5XvHMimD/oQjtBuwlk8zV1G+Th/yIsi8Zpf
# DATA dDTkdI5ui9IMK3oxquzwEPuYS1OZH5bLV1bqrF6BrQA1N+zT/PShmW2Ub3rypLBiqHdtYYcg/fEeTSczXvvEvryDO3dOTk5qJ41a
# DATA kh7dCer1+h21wQsbiN5MHuHGulf32k36h5d9UeM92QBI3/miJx1Z/j3l5/wAn0c0BPGeqUa9MWz2sPHx3hssV8K7hT7w257fGzeC
# DATA 4+73g+axXx/Tf7vf99s/Kzw8CkaNUUMeRhSLq6IZjZDR0yeySxN5msxzCpKJ2t/GN+absaji9k/xC++by3fXqc1P5qq96HyQ7+gx
# DATA ewCiIa+Fn5oNeFaW9Opes9nyGr2mF7Tqk0Y98Pxuo9qodzy/2ShmzLA97Ef11VztNLxGt/Ejv9OeBIFf7bW8wKfH691j+vs+gm7V
# DATA g2JQ0Wjkcx7zdOEhp/9bzVar3oryi1VT9I2VlyLUrn/cDPxpvRr4Tbyy2utxZFREPF9qxRXfEAR1L2j6x37QmPi+77W6Pwp63Z99
# DATA 0Gz0vIZP1SfoTvx6p9rs/Chod4vJ6w56URiuBNlpUa70xn5Qn1bbdfrnGB+bdLnR7I59ny63WvTPMX0sxbzf7tebo3Uxb26sqWr7
# DATA IlXUA5wsfKw8wQeqhh/y/P5ANZZDPbU9+Fa71e43cMF4n+gR/t+hMWhWrwQH34r8qBV1DpWP7eBbrV6702kdioVx8K3+aNAd4Al2
# DATA O9PPw3YjGB7K8v7BZ689iI6SyPvhezRd+CQck+1Zuc/bxzLqCqtZlMZ4VndpO92O7qmG3ZZkMuVd+oFYk15QdDp3xRAwt5vRSM1v
# DATA vhdRm47DigRdWpo7LDvCYJxVOrXm8UmlI44wDljtlNtler/Vv0Uz1WKIZUe5beapgll9QPvQi+NE4a55waoUk5NvwPgziLGT6PEl
# DATA lgfytQDxAJbMInFa1S9n3Hhw0ZY3YhS9AvWNxmwhtZWVpF1k3CnP3kodY7PhJi2VJ6tt/ado6p+9ht171EnEgwXvJJ/xBkjvr6Av
# DATA 5t29Z7ZA1j5fRunpA94XkKR72b51r7n5fpqGp7VRmkz31j93fzKhR61n1V6+v4lOIb2on0ELr2E7IMWW55be695nrx3YEZxGU5zO
# DATA FuzYB+F8jwM1rHCWM34YnVa8UTiZoHLve49x4J/+KwGITD7vKXsgkQCR+j3K6j0rUq9Do2z/0FCFma5CL11OJt53vT2JRW0cZnjZ
# DATA Pl1SVygouXJgReDAw9FP0SJgsf1D7wmOKg/GFCv1hsuEiMef2KnmQ/WSbIWKfawfz+Rx/cOhyotC+rMN6a9IvFFLZkfx6FRjq0y2
# DATA YIvNmrSMcLh7NZLh6R4mz/umKCII1P7V3mevfUs8v5+9RkFDbCiaANFaw93qdAbdiG+HpSDHycnGMMUYvXSYs+V0Lx7u56n5cDnt
# DATA R+keh/kZRP/o15rOzcKjQ7WJdE/k3BC46FnQmz57DV/vUHOOZ4f6mIuccXktj/0yRfR/+PH7Ndlx+QM+HkLfod7mvQkNvR8jnJ9U
# DATA vMcI+AkKQx4N7YYkT78ziVgv47PXQs6GsIbdf9CsSSf4puOL1kQxxqXBJB48pDaFraefxNMoWS729vbRxhGpNDomoyKPFIUD7jvZ
# DATA ryorJCpY39ClgNkEXm7nUzLDhua90QwJR9ngARbCm0Lo451jivT7SmuFwsiW/WlMBVnxomMutnv0GH+sQTWG/r4tG7P2VFFzQDQd
# DATA p6nQj0DviBene/sU/gw3PFFR/StE78dy4CI8jn5CkazRg++Eg/Ge2vzJL5qQ0ZyFIkbHvQtFCF8Rnx//RL3xX0kPGGf8d49voDfq
# DATA 5378E11KlP/YHQ9dzn0JX66fspIl31+jUWWyHEaZikbeIdKv9D6zSW5xX0vbo4StrW+I2gNutHunUOs0zxQrP975XaqYDyQ51MHI
# DATA Z5w3enKoo7qXP76mbLi+4H06OdeRVfrzDtlBCZC7yKimqe3eMWIBdvBdb+3tB96PazX+PKysu8MUFFnAGZLJ8eDu1UqMRLqQRejd
# DATA 8mdMtpp96Mv5UG8mL2zgV/n+ptr2vn6P+6E8I2HxlvZMbWfHmVAyKI6jGrfwJ/JvsXqbBa9iHU8e5RWcb8l0sdFPJlPMw5uLUB6m
# DATA MjShoBARyIoN8Nlr63by2dHi3yVi/FEiwMUgwef1QX7XPbF8W1dF+eSNXUeVCZJr5Fr2y7ZoH6i4fAYJzynZHlLbTBQ21ZwN+akj
# DATA oGqP/kr23eyIJoMwfTw24z3zXrpYqmW6tWyoV4fmQMX6moVqk9cbVXd0/sBcNSM0f1M9udxAoz7NrdgY41v093J3L03zPdEyNdnP
# DATA mcz6xBzydyUXvb/9W4o1KgT1X9M9+pO8n5xE6VuUeXsmi6khZCy+pl9ZeJqsJCSc6zVOTNB99UPPahDI1GKlowt21WDRRYj30HW7
# DATA 0yzGJq+JnJZ976//2tvTUbt7V8cEkeKATBUw+Xb3rkoK6i9ukWU9evO/4ihIc+OP+5KW11+XglLGDlYOdfbzl9zcwbd9uSMPVvID
# DATA vWM9H5GUUpGUIW4wgchv++qe0vAhYXEt5RhGGQ8cVPK6RNc0Rm5HaItWpUByTDlubcCFh+hFiKOqppTJOpD9Yo3Djcri2Nu/e49t
# DATA xs9ee9ccCkMzeX0PZt9nr0nTo/R/R77zHJCb+yJ5F9vq9oL915Hg//372mf0v9nbepacJAt2tXrhwvNpxvK6BMCHzSgAemj9e8h4
# DATA ulO8NX+Xz+/6P/9kPagjtMNzg6k0bpkB5gcy3cFsdzD7ooPZ7kD2S30g2ytsN1bnoJ/rg9rGc8Y/F04ATqzj2w/mrJaHkS0eAjai
# DATA T2/nt/O2Yj4n93yd535RTjVeJNxiO0o5/uJxvvcG9bTlZqgXyRANs1LRlfUuawVPLoQT/lY8qF5evJImPUiQufKm09lAR0P5se/9
# DATA YGXti81UsgdKB/+tZ/gLp4MzYH6Pi/aAyh16MFResIfSxSk2FZvn56IbkI1DPhGra5SnNlzQtJCPIy/7NK558Op6mINQmJ9zPHiX
# DATA UpykNe8H82jG53xHfHafHlKH+bmyehTWGLWO6qQn2xAYw4S76c1gLFBAM6UbsKPyjlfycWsdAT5PzNEma4GM7COcSzMyPH+DY86o
# DATA cDjdzUQH76Olcfd6M1xm9SN5R0w/LecwG7KaB1uKf8zYpEpGcPJQixnCUlPNhszlhCUARsuUrIjlqhrCy3nY1oTgrDdnvV1kvRVr
# DATA mNPXcfo6lzXbNhqIN6W78wBb2Cw5CLwGvk0I5xkFnmen8bZtuMTuPs+WqytYcrz+wfYHFkXUlhx9jQsbnZDYsewT0JmsvIB70/03
# DATA xCeqG+CM16NQSBKaec50V/kV9orx9o9aizcRaQ1rSj5viMLFacj7jVpqM0k0591HNenZ73AcS1EVL4SpDvi2Q0T1Uyae5oKJZqPW
# DATA vsZoimeEftZeGr7whjhaVaT0PSZS5qE3Eu7w88gFePM9/yCov3EnUVZh+Z6Wuqe15R6/rm6iD/lddyRaeVKUra5zU62C0YN5M1jY
# DATA kkdkNvATbEikU3ov7wlW6VSroRi9dNXML0nPEx/zi+Y0Ti8kB+5IEJg/qdySdVo7lPyS3qFmrtyzDM4QEzKrA7ClqdholGa/pFRB
# DATA +MUYlB/QYEj9sxiN2mtttX+MsdGMWz4bimagjVOxI2ve/eHQ4zOxyizI9PCZ25De+1hDUaqemAiYkXYJ2XRx9LJRKoY49Th4I3Zh
# DATA 0Nvmy8mEf1xiGZYG9TjVxv8Ps0iUd0TERnR/4n5MWSwS81pEStd5LNhmHAUyS2BYsCmNngjzmjjDtJCSNJPOT6tcsb0+gfC91cth
# DATA DOxHrJfJmcYdvBQJl8bLbzXbA6AznJ3hfJHhXDKQnOXsLOft5vBzoFj5Cb2NG0cmmnnhULWG3GwuaTZicDE6b6yI+DBaUIHOjkTa
# DATA rii9KEywZIRxK1ESkLlSoughlo3kkn8W2xWlFNSWxTfGDdaf00LOurFTjBviMjMilbBgsE8JeouhRJfFsJPRCNu/INPHfUHmjZMT
# DATA +tmjEpLhkvO65injApKWFLtjjLvoZ5IRdwyc55Z8pfisODnFQW8RsjfzforhamJGOpMiO2nvs1MuHJCNAyHNE+qx8pRh5K3ylEE2
# DATA RDPqNJxkvF0Mlg6SeES2WKZ7tSEV3ph6My4lTqac8qEQZiwqDjcimU5HMncSI0b7y5IpWY0LpS4Ywip46GmlkC3pfDs85Z54e0JR
# DATA huKqRBnrND5Q/sdRFFGyhvGIpf1odgdDDQKH2MOIfQhUrRayBYPpxvQLmiJ+YRPQ+4QxPB7zBREgW1bMlIVjkKqiToix6PrLU6nU
# DATA pwvUZ2wS3ZLIj6NsTQLFrChU4VVBVVPVyUplv+UJVOFRySZogjzqpNE6IxZFWtF2JAhv4TDG2TsZ6MROVWKSVHs/hv7LkDKR7EK2
# DATA /ZB82HlLMib4iYficdUuZYaUoXZP5Z1iT+qptJY6HcXplBdH1s1tOVGfUN7IfByM3jmOkZKZZNTWqQUZ6zlf/M7Efy33U35wdSRT
# DATA QE3Pw0xsYe6dvA+0uCf1rgx7YFNagbiND5kaz0M2jzE1IMOXSjpcLmJ0G2HKOl1TpTzJ6qfSoYALJW5jshBwXU0pNqb2b2bJidRP
# DATA tBJqIugjIdiqE/x2wuEvsK8SuS1tkRI0hyuBu0Ye28QusfwKaPxUytjSEE8MXCvl6UJKxU3ZRzYSZZikkIocB6SxIyNcUZAtdMM8
# DATA RZidltVkzXzClpW17HyxmV9Ca//Jk4ph6CyOAOdNT22Czv93/quzP5x9c/Y/zr5UjJwvz/5M///i/Lfe2T+DaUM//Jz+/e0qOue/
# DATA 0g9f0U1f4X6G3/z5/DdnX3r05XcGovM1BSqX+StAO788/03FO/87eo6ewW2g53xDb/ojY3z+gX4Qps4fz746/7WOzF/olj8IqAew
# DATA HcfSeQFmM+iUcXyJOpw+/VkURLOPooTCSeOBNsFq3juP5hMZnyfcI0bSN2TjeE69xcTyRujOEauI8yj3GeRzoWQyUeMTvVTL/G6F
# DATA 6mA5UYWnWopD6xTnN7oHuW2wzrqSuTm8Tl51zK0w6fLL5Qcmojdt7n5fvvOIfs2EHR7X1LCeqM2tGEwdYGfHYrt+xA7W3iO2PlE4
# DATA ldzFyMYvcg8OmSyKCobpmMYTzkeW288WmKmWditrpCaCMIdS4sUKX+fi6rfZobmmZT0rzM7FyXCcHWcJ3IQloIE7VzQAXhHn5q0N
# DATA /jcy9u809F925L+dgV+q52o+5Aye56913QSMx8oBRvEUX70mvasgD3rddK5WElXhUZ6leKkC30SSNZnKm4qnJLC9dHy6GE85FDlg
# DATA whm0K4JHFVm+EEkd8YTxMkus1EIlfYHcXij/rByTG4XHCUYFxZrRMcYLBG7Cwyk9qC0Gda7uMLcXhFgE3w/MiJNwtrDdYoNk7hg7
# DATA jrHjGDs3ydjZdVTZaZqzq5V8yyb/VSz+6zD4HW3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H
# DATA 0XYcbcfRdhxtx9F2HG3H0XYcbcfRdp4n2k7QCq9K2+mMWqPBC0TbWV173om5w7mrcg+7Mj1+V7tdUEhrNUu53mx3i9ycKOqOFNgI
# DATA hxspegMOtNFmGZABhxpIMCyV4TfbRYhPgzJ8DRqp0/SaQd0D3cZv9SZ+t+4F7RK1p+23Wt3+Kimn2fCafu9Hfq85bnaPg6A19Tu+
# DATA V/+RX2+Mm53jhl+MwiAYNvv9NYlodet5IvygZxLRKAYQ9IJha5XYQxnrNTvBWOWiRc8xD6zQc9pXoOdwjbXoOVT5C/ScVrMbXoWe
# DATA 0xpGIz+n57SDtt8ZGnrOoNsfDXs5Pafdbvndm6fnqDpe5WpsxoWGEHT0cFu4aZ2jqsHjSKV3fFLpsiVVWGNqDcaHO5N2ym9TDm7b
# DATA tSUmhroLRwuuB7djh7iK21ETza4xVlHGh7yTYxwOk5ODugfvRt3TJVkA9HC7Xn2Fdrsb07wj6yeFXC/dVFgrk+G8BMM53LAfYHW0
# DATA UpSkdZ5aWbfdErLqatTQphtKXjOaJn4Xu1JVn7GZ4lMo7QtsxELm2YWpEqMnL7BCHGXHUXYcZcdRdhxlx1F2HGXHUXYcZcdRdhxl
# DATA x1F2Xi3KTjwS+w3rHqjxj+1vUnfuqhFTDVzyW4Xr4v7hEwvT81jyDZlxl4PBqSMTzOv0BPA7n732+uo7VKU+1AOKesnqjfkt6oAG
# DATA 3cV27qGCBH2IY1zS8tmUn5zy6Rz91nKUat6/U2fgrUNpfPAMZU0VykShqm+gH767bcS/pqwwNrNJKi9O1RaPFnmaqXf87LX3rZN3
# DATA JhnUXaoUyES3dM7HHUF3R9B3PoJePBDmzqK7s+irpwY36m0+D2fUS3W80FpscRr2/LEALSpzlqulKOHbeBiFWQHdwieioWwJchGP
# DATA NBl1Z3JOWCup8Fa60mnZXc+gcxJYnxFjOYvzKUlQehVcqHPR4+uz7CLit+YwqNpltapfr2xXVEH+pNTglXC4/jHXMzdXeLst5D8j
# DATA DsdEL86srN6s8m4MYpZGl89FjXfrDtN92k+tKLTDosThTnRoch+Lu24SdFddKof1PfV5891yvJ5V7vjT5ju5z1Uys4No833Sb3P6
# DATA +dMWUXk5aKrl3MUOtdXcMcRs0XIv1AT4z21Z1/wXeOu5q9PzAPmk87ycZyWxTXbrm15ArGqueemSc+Nf/uk/mnSUI27l/5wlStHn
# DATA TMJ5rr+qlhJ5T1q6hEQCbLSEpRhmUIJnLWqolcZUCxnKFM7nVCdZX5c6ZrQ+msTOFnL8H3qsC+gfaR1a1qrmxQ8tMntClVsdFlc+
# DATA L7tl5iefddPID1Ybxxkuq6SYnNFHL+kC+4K5ptC9FgigrNp6qSLKK+plC+jv//vmAtKVXornPRQDVeRMF9AnJwm10ZQ6Nk+f8suU
# DATA CUJ90nIGTyQNSfOa9x6N8jBypsmxCFJQGlhwAMIGRxF3qygg2T+syinS6haqtJ6+VEwKbq1cTLdw2WL5x/+6uVhUFyOlInKggySl
# DATA yYhpOTM1EZbLPM3ps6Yr6yrLJ28eomENxXQQBd8R9eHJiSqioh3J0uxsFhfGQetyvIAR/fSlZKfo1goq75cv3cP9dnNJ6T5eiurT
# DATA MJ16vLsr7+JOcE3gOMNjaGFTyRxRwfD6Bfq6SIb72VCkNCJWj4XOdDQDBEdKQM0G+hGTO+KFaHJgd6z9M1Mnnr588mTcWuk8zQj0
# DATA //zz7iPQWxhko1SGBEsHfMp2NcUrfagsbW5S4YTVy0NvuqTxZxKm2Cc3h3wyMtr7kRiPaoAhEwkMA2k2KPGnL4lCdF+EpvKfdm0q
# DATA D5LRwuuj2oconbxbwxjfpyyaQssGmjEDGnkwOWBF6HD40xD7c1SNz1BYKdvj8TSe4LwBcgoqFWSpf76MRa0GKogsrCIFqBWhr6Gp
# DATA FJJxpQIqGoHi0bSNQHNFsvveh4n2PWpNIZ59KJ9gkgqVEQN0wp24Llgl/PM07KBXQ9zFwbmdK+0KrjTnOXtFPGeX5XU/F+qOhf2X
# DATA 27HdMuemgXSBrZpkUR6xU2sjufs5VYF8gUTTLtKGtvc93gTFe7WVXDvLe62M6Cai92rK1W1GHVucL5gE1TzfSGKzM6kiviNRgzxJ
# DATA jOMidzIpap9yCE8B5TYyf3lBV7xlJvhSyAJSMNgZIUnIylrYa2qN0ufmOpnraV5JC/xDeLpmR4AGCmBcdHuMFLilLKjBN0oz68DI
# DATA icKszkVFbSVRj30mZLEupLQw74H17WEjLvQ2jwv1QTazSWbxdlVoos7yBi/ahTq3kMO1V8l4tINw5qMzH3c2H+265tZh3TrsU1qN
# DATA G43Um1mH/UC4n7ZSdE48fDakitughPPeH1QvPjZYWOZUP+V4bXXrynphvpCUL49tWlu0lzfs1ZpN95cc7aWlhE1PFdy/BZ/2pifK
# DATA bsqym3XTc2XvWdkruHHltFAKvMkKMUV1GsZDrg+y0PTdN7R8pSoWdS/45bLnVFji6pypJp2XF8FxyFzz92yLytPce+rUbZtKXGb6
# DATA 1TtQxHlTwfS00IBeXIQ4FpoWTEKdo6fPlKWaTOy3RHM9nsiMk03wSM+kDESS2o9ZrVqyqUCh0TN47m3dkaBvsYdnTwmE8ATAmOzq
# DATA qU9hiUvfI+uOQ3Et875yigmEu7FAo564k6wWXD5vXO80zutavrcQHE/dR1FJl0r4Ygb4y2MlW3BAlkJKpgU24H9UEL9vzv5M//7p
# DATA 7Ctg+L7y8I2xfN+A9ffnsy8B5VulA/73s78w8e/36u6vzr72GBT4u7M/nv9fZ384++L8l/TsH1WgXyuE4Nfnv8I1+u2b85979AVE
# DATA QgEBgkyIOMhzABYyN/AvDgb4Ilj9hb57FJ2Q7cCT6HkI6VoFAUCvPh1BPqIPyS6NAaGOD6uy9xVWN+kz80B1z33daek+eznn16AJ
# DATA cXhkZAzEfxItlvOtCMD7kLrwhssMm12oPTsAYMHe173EbfP/Vovl5uh/bGExYSW/tVDfyjzzO9FpNI8jsjb0/e+oCx5UhoDQTtJr
# DATA xgCyehgjoZcLHv/VGS1qYo4EuGsRXj8KkPoaLIJTm5/FI3Q6DINniDO2y6XJI2joRHx2WUx5GKyohdS5DRbYwrBk6X/5MVObT/Te
# DATA E13RxKVKljgzbjCNi49mK1jA3avlZltnpeE9Kzjg7olxkEBnIVyfhaDRgFcyDF4NJ+CtGQU3YBPsZBJc2iK4XYNAqmg5O4wZ8Ny0
# DATA qptAAlqpVstfG6Ko4WLsvnh46h2l4XAZKuhflq8+QMawuMbGqMHiosSpbPrE0vwxu56w1sayiNk8GmDkN6bYTnBAM66zMjclOJN9
# DATA dJSBI+DLuAJWk1EVlZP7WapDNQ8qtjg+G4rlAB8dE/BUHBRbDcmfp3Qp47VUVdrKfJNFQo4s32iyr+Z9GAEgJxdk096DJcyQNFke
# DATA jb3ljIppIWfY+cWZwwg6jKDDCN4gRnDnYWinSdJlDepbnSNcZYpwnTMERxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0
# DATA VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUweeGKhh1ouHIvyJV0O8GUTN8gaiC5RXonZiCRXher2nB8zp1A8/r
# DATA FPN1OIiaw9Ea+l47sOl7zZy+1+5tzNu8YKZ+vesFfsfz/abX7Xi9VtVvBZ7f9Km86GrQ8brdEpav0+51+911WL5ClHkf5mp86YUW
# DATA 8tDvmPi2ioDJetQedNY8HwRB/nyjniMTu7s935BXqvxqBXl+7fZ8s2XFv2Hl947vb3Ut5GOz0bns+/22Xd5+Hv/GjvG364uULT/e
# DATA 3O3xdsdOvg173DH75RGV/Hbvsu8v5l59h9dfBhIpjURDIqUvsyCRg0447PhFSKR5xEAig3qj3+oVIJFBv9lpt3JI5KA+rA9HBhLZ
# DATA HLS73WYOiRz5w3Z3dOOQyBn682r28DRf55AjlMfRNaw7BJarQ9tcbD+Y12qLsGD6yMtoNoNp/Zo9LCrD7WBq0C4q2vdWKPad2srZ
# DATA jVhZiKhe9FBcRClBfY/Kkse75lqtbVENPTtb1G2e3tVSzBs9a8U++YKjtQR03LJDQe1HkHRUM/phGh1A9HIzpdHkQ6WU3C2mX7mQ
# DATA K1vLi50ppsjEHlypJmI+BbvkFIfgKJCOAukokI4C6SiQjgLpKJCOAukokI4C6SiQjgL5ilEgVyGO0/DoLkw96tVxxoySfEe+6pMs
# DATA yASFXPzAVhRAq3qdnqa68C42RO75+69/9tr/+acaEw/vr9UZ4Gf2JPxwLocN8EYKZt+EEyCc//2FhPMWWjwfX5qGs+UoZJ1+OdUl
# DATA 5xGpOc/l6BsOVYWCXIge0Y18+JPMgYyGtgIhsXBGx52+d6fvLzh9v+YIlzuL787iP81Z/I16nDd6Rl8UERM+iJwf95Zh5btGn/PZ
# DATA y8fchlanjHaQUTVRGPEBWWV17k2n+4qSqFvojB0guaCfDsJ0a+aCUbTstIpKktN4JutedaU6yatASm8S+2341808RTMo21XlsvG2
# DATA AjFRt6+Z2AetdZEPrKh3CxGv11qbo27Gezvq+qKqR3vD6CiNaKp+QQqssEwK7GsmBe212d+wc98PtmT+RoVO3UpQo6WDeFHVOa0R
# DATA l3mIdGcqrVkfcS+YfZg3LdY3GXpVjCPr/dO8kds3sMi+yOdLcUfZQroSeVLwjKZK5GHwzf1TQTkW+iWtO8D6FTo06kfICFQGIuZ7
# DATA czEbhjHmfvwYNIRZUuMkPJWBR4qTx/5MC2scLUMacRZRxNLgStjic+rgyPzC0XolCrImRjsIeL58B9ZLo6KzrJ1lfYFlXTKanFXt
# DATA rOqCVb2ZrfQ8KV8VW0Fo8suIX/0Q/D2jdoRV7FzriPVk4BKvGP0mQRdH0zibswSN94mhq7Dxzro5ETxzJxGTWSue3rOBUSmaYxk/
# DATA pUdQf8oWdZHguCJ2Ze6jof/dWEkfjZM0/lliJG+Ugn/oZeEIfJ0oJaOIJZhMqWTzJFdIZ4kiFo1Ss4gozE555B0n0wiiPDybILuv
# DATA IpwMkeLBvTRa08Aaw4Tgziqj3MIqglIDx1aFDVOGgm0zjHTc34cwT7EDxNYJpdoDHmTeIRqbaDkL2bChelXz3oxnCeoQPaMxu9oQ
# DATA mEWPFmxI8pIKMkj1o0kGt5XqYZUJJFVgyi+zQKHrjIm1afsbG4wwSY50Cj/GiWYpN6lWhTlbjAVZqH/EuViR4S6IhNfkVKnlc4+f
# DATA PZSalo8belOkyL9mrP86glQ7J0IrkjL0lHFhHp8FA24b2bvItiXqI5HzklYRnSrJLIzU8yl3YZJGUQUT+dl+Xh7sAMyN03BhBMPy
# DATA 8YjygiospVEmnEpPibIMu1wn2F/CVRlHaFK7Qp9m8I1zbB5RAAsyDuMhaLA17+2EmySGP6NMBhE4ZTCO0PmlVmxWCEhsWV2o+2ri
# DATA 0g9VYS8tBX2znmKYpOaKDBKnckGL7KvJWfF5/rE49dKLU4VpVZ2nQKo/y/syJhZIzc2h9kpm/6ne5xvyxCQ8VejwoqmSUU94ve8M
# DATA eAhlXM8wnkr/c71vwDbFex/qsQNpmkezQTy53rfwHu53dAvSS2h2D3q972sJwGIUmT1D1PDYlpxRayu+685ycmMM2pdvfuVItG5q
# DATA tbtksJtIvfQTqcuiZ58vCWGzp/cmGKblzL52gukapeOL+aWTAkFBNIDZDVnUFd6C132+dJRfRAnRHXELXmFjuTbCc7lVyRcz2ait
# DATA TI7zaW/FO4JCcz6nwSzMCzEBxlYrMw8d0BTY1o8V1VZMmrJFaVaaexNKngRtf4uAbqHWkvVyHF0sJI06OQ3nGuSwUxmsKdGP0og9
# DATA 6gU17CzKMs0qfIVMt5xw1Q8fRmkBb/Xfzr4Eder852d/VgyqPzDm6ovzf8+4qv/lnf89MFNnv1uFW/1n0KoYSAWO1c/P/9E7+/35
# DATA b87+cvbl+a8p0K8q3tn/pFv+RN9/ie/e2TcmNFCzNgOvfgmuFf3XMa1eBJIt1WE8D2cDVTCWwA4Z9yxDBFlbMY8EQ7gmIFeuOifM
# DATA ycSlMWOnBfdLIwXmGcqlBH2c7K8VRh71HBl7urYirN7EBlq0kwidhQNY2QaodAK3Ta8ql8jNsasgCT0svXctsoqrmLnxba5wNwOr
# DATA olFvrjb9opZik3AyDE95HyHVj4eRA1ZdVG7Xzql6E82AS2AepTgryor1OI43YsC2nL70yHaHlolaBbG24On1fojlH6XRMI7gjQaj
# DATA gPrUKIW3K19OUf1iPCNzaCk57E2XmfRnYoadCtV7EM+jFYrVLjV1sz1TanrPil61SyIct8pZAVe2AjSm6gqD/yvhebqlgf/ax/2d
# DATA hv1dR/3bGvSlMhZTbwb5Z9VYboI+VUyiN44mc1gnZHgAwWwilyc4HZ8uxlOsyErSD2SohdA7Trgs+APQ0sgWWR2lDhM0o/fIwA+P
# DATA aZzMdHakIm3GWw+wJpsuWUuR4j+NDRdoO3tK7Y6AhynCEnXEZ7pkIObYbxjMxcVhGQSMJ+KxIBMToor2PyyYF7wPUG+iUCggfgkL
# DATA KAA1Rf9gTwXsPL1GvlwkkIcaMKnLAaYcYMoBpm4OMHXROLLTXGZ3U/cWrfarGO3XY7M7kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJ
# DATA OZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJPTckqXaj2Q46VyRJjUaj1nDwApGkiivPO3Gk7EwJ
# DATA 2l6j0/282qz63a7nt5rVoB7QX9/z6Z9mz6OvxRwaRN1+o7XKg+p1vADUp4bn17vTqh/QP031tQSCokyuD/rrQFB+TwKm9Mc0cGv0
# DATA UcNCLzVabavoFQdJoERFcFXUDKNWtBLRZsf3gi4lu+X5jWDa6Fb9Zkt9W4ln1O+P1sazsVq/6i2v2WqN23X/A78ZeM2uP25pvTiL
# DATA gdVqBtG6IFdrbLtJMW34P+o1p3UvaFXpH787Deg1VCxdfK4GXfqy+kPppd1uuxEMtrz0MqgjaSEadSSNzUId9esdPxgWUUcj/p+N
# DATA OqKv4aheQB2N/OGo7+eoo06fsio0qKNhOGj1WjnqqNts1f3WjaOOeIdJlU0PmyWkIlucffoYCT35LzVzezJgM41kZrAN8sMjV/7m
# DATA HehDBSdc2zjhZOltFVBkhb3qkOcRVrbN0UPRw13hRNrSCMoBeJcYr7c8tn3w3gghskrQ9gV6YkJvTk+pcDso1Y4q2mL+bE6OIwk5
# DATA kpAjCTmSkCMJOZKQIwk5kpAjCTmSkCMJOZLQK08SGimOEB+9ogRXTu6OviOXxqdDWT0E7IeMm0pmfspCtij56qm5ehpRj6wua/rQ
# DATA uwiXCUKj1ymHjpgP9CnFUC6eFEFE6vcHFDz/nK39+b0ZRJFgLND7+L7Ttfd9kizCiZzv47s+CBfjGvsN9kavn7yevX6qbrY5Q/lJ
# DATA FndU2h2VLh6Vts41uQPT7sD0Zim/5+AgNc6kjvJqHp56IX4vyJsvWPlE6jNKwEiEo95U8DNk8yaT5GT7Wd9p/IiPH8/TJBnp88fQ
# DATA GTcNlcZfbEVZplH2FNrmNCKmp0jKgrIE6dPHLe972XKOTjUaqhYdZ4Z8RJaNAhulNOChdkJObxIvsIiT0OQhYyVsAZkM0uW0fwht
# DATA mHjG57Ezc6h6BGfvMZ/f/RQu3IKCScqa7qKgnQ2ShJ8YLOeQ2ZZzzdsUtN+CDZGeyj46j4eoPGkjiKxDBRBBcqnOomiY6e5M0pst
# DATA UjGXqRzHyWTIZ10Rc0oszYFZDhylMsJvRxTlySkLhZtsM2Unyjosk45T6VoVndOAidwkWSDpdKmfnEy8cJIlfDB4q0T4u1S9uenI
# DATA sW16a5RahceCzX22Njm79M1xpk/Rn6AuontmcZ8JzveiH695rKie9+QDbEiJII8eT/hkLs7GZzXvLVZr5rrraUANqgNFHqEiteEQ
# DATA G4E4LHMMUan6h4uLRN055zjOJzSQGF1BbEfF+XcPR2nwMmo64ZRfRwMdl46ShB8sF1K42FYzV6eBRSfenPfGlUmsKFyoFj+DTD3D
# DATA cTKjaP5QwhP/CodIpuHEzpLYnOcO0+nVdM3fFCFqZB01/ksLm6MRXrey+cfIfBTeCM5p6Z1uQNA8Z1uK4BGKgg1RL9cjuAFNc6PM
# DATA yEbNTLU9dLMY825A4vw+d/vGVlJqErenBP7yHOTOA3EzCjejKM4oylXKTSvctGLn6cPG6cfNTSseICtyHI5ER08pnnttwNtAlIoj
# DATA jS6z58vbO7oIi6kfMB2WuZDTOepXAZLWN2M9c9ce3fJ9/cXb+/ZFkbUfNBEuXMwpnt11cW62rCj3diWosr+RCSWTxQ6xVLfniFf1
# DATA vWBSrUTNzsxGkZC6JWri9KSfC17JHSKpHzSxNBdyu7bWuSiiwbaIbgShyvwVo5XV0l5cGqo0tTgrih0ZzdJ3qW+h1uEdmbl4xWt3
# DATA v+2ZeutNyaTOvEZT3XMC/zTN8mkiHR2l6Cj5KY3MwvRbuFl8I3dH/FXpsMnM1EBOY1arjQemq8Mbo0eyZqKnDFgGw6QeYZWkzFie
# DATA y+rLtIBtJqwyeVpWITDpz6clEjt1+iDSKmg7UE5fHtvb0Xec7b3dm+8M7ZfS0L4sZecZC6HyDuB8g+yqAWpDaFh0MNQebKMXKknY
# DATA TKF5pvKpL4SsIP/3mplGJaHX6yYarUjlruUZ7SBea+2jziVs8S2CcGUSjiqGoMNW1jIbKwOrVE+xU1xKVu0Wf2PcuPduGmPdBrsU
# DATA 2YtIl8Cojx/BhmHvv5znYtphXDR3aAKJWWC0btlFqWqKkKnok6qDDLyFS5k8RQOGpqWWR9VYLSa6drwfYM0KMSf7rhRzkd01iyoU
# DATA O16/MG1CNEb1soxikOI4GbZnW6tFLJ/KS084i7glwmj2O8aWj7XNEqb/cnwfYCVILdDp6XNUFEcNiwt7vGQyMat+FEcFn8QKBBbB
# DATA NkeUXrYuX18Z7U6LHESG2wAcHosd9J/Ovjz749k35784+wrQn7M/nP+GoT6gB/2CGT4/p99AF/rtKjxo5eGzP5//BrihX5z95fzn
# DATA Z1+c/Z5+/DUziL6uePTpy7Ovq/TEVwja43u+oXvoHYIW2ggTotDxli/oDXSjAwo9/xb1D6FfxuvE3JsoWthpRRYEcUk6WrU7NY2O
# DATA wF/Wcs6y8K/qqxncUxZtLlCmqTfeyhB6axyKqoElGe44QpZ1rbqE2yYJrSuXm6MJ8YaAcTI3N36qLqxnCo3ivJt+N14YT/A104QE
# DATA asz2gviKLKLPq84R2qXErp0mdN8T8DpA4NXFsh+ZkhcPfow9tFNPdoLXvA8SqgEzA0KkQjyG3jskPbBGwBoeMMtCtdklxOeJbPpI
# DATA 4T6cMo9RnHVsfAmsESKxZXjQ9iq52YhZ086eFTpoexIcNMiN9JcZ6TUn6IoD/KvhOrutwf1GxvadhvbLjew3P7BLtVzNgXyj6+21
# DATA lpsABeUpg4gWBZCtxnkBjxs2a+rNfzq+S5N2PuTEOBFdgCDAxPw7802wBMa0FbUllN8yDWeUusykW1JrghfM0HROXdhssRM2CPbV
# DATA Agf5kQ8U0iil3i4f9GNZ7tcLWwiGxeQYYmQIQGkkWWWQyKcCVK5YI30CzE8yEnQxXkQV0XuwQLJj9njEI49a1UOhoZxQR4E9g2iD
# DATA vMEgRd5ph6ijBzl6kKMH3SA9aLcxZUeo+cU27y0b71ex3Z/WdHfsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwg
# DATA xw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw56bthBUX1UHwVXZAf53cagVX+B2EGr68478YOOTJJ5F2GRNTNsRcNRfRNr
# DATA 5t4bgziF/S9gn0ASosA+HRZpYHkD31eEocLt7Xrzgtstzg+F7dE9Hv1W9Xv0t07/9lrfp+sTv1ena20v8Jt0rV3t9KpBMxg3ex8E
# DATA ABZ1uuNOc+o3WtVma9xeF5NmsCniCmB056hQgZqBj8jQG6ZV36sfC6JnSzZGo36vvR6RVF+pnhTnVlAft5v1D5DqZq913KxPm/Vm
# DATA tVmnT2UEUS/s9Nvrgg4uTwOSOq9pQNJ8LBoQJWPQaRRpQH6n0W32bBpQUG92W8MCDSjothrtMKcB9UfD5nBoaECtRqffjXIa0Gg0
# DATA GHUHN00DUkbJeseHTmvJ1lIjETauVbdbIR7djGEnv7cM/jETpXWTIu1Gw1y30qw1mf8TMP9ndT2qXYyUNm6sblpsF04I5XiYVo8w
# DATA NQbPoj6MjirW2rv92Qt680eVbzXqrU67z26//crmkHqXDEpHOZtHg8tSibTNC+/hikllrchtXhxXS+HiE65m9MM0OhiG6cPN7KE8
# DATA hyt21DfbHCWzV+oQ206OJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCjiTkSEKvLElIkX4+sY515ee5i+e4yhge4QbJKW/KI00Xwo4A
# DATA NCPQeQbTGsN83kqmLIC+csibj7dhKUnUqkIcVElm6viaFqQtHhSTNioTOX3Swp1xdmecC0dt3FFnd9T5ikedN4oP3swR6Hdj1rrg
# DATA s7TsgiyfntVHoZ83uY3b0ONWgwuqDtVXJRmOVO4NphdJNJtnTYeVXzEizd212twtW6TZ9+tFmebWFqlrHvwg6aJ6L77whtiyRkVZ
# DATA 7skFrvVDbyTcmdoS0m1e7vmY+j6FF+J68sadRIkErnmizdlFY4t3x1uk0UPWirzwsRa/yDYDpjBoWD65+OwdSc0OQtXv6PqJKuuh
# DATA yr64KtUfRGG2hGg0DtYOwjQXqH6wEEk+6kmSZCE3yLFmyPqERxB7hj/qhMasmvdDHtwm0TFVGnSA6FSnKmxuxgpOk6RGeChNyJys
# DATA eR/zAoCYRvIA6y0qYT8aTk5R0FQQ8aIgXw2YVuHYvpwj9dIlznjjyHWIA/bQcDTjOfQDyWKjOsuFn9HsbJnNI9E/ZMXscLYcYSBO
# DATA MZeSAMFFGsajEa4s+6ynHmOcpsAYu7PO1lMiBJSExc4C1y/LOV8nb+3MV8t8dfbqK2GvXlbb+hlL9vC6dr4Au13b+j6NRmw0sgHJ
# DATA dmyWS1EwRyHbonF922I/L4TexU3IWq/W62uXtl6r6XRVeet80V+bY2JRKNsnAlmU61wuas3mzymZNALU5KUgel3Ne1N0g2iWJGI1
# DATA UTiDifIpRIRE7iXD4MaYUSE4cnWDGUVWV6yFn8mGS8jmIaPuIb1BE0MuV3F+oIVYjKqTcYe/WoonhZxxxpAzhkp9qvPmOW9ese/c
# DATA aEU9Y0FD5gEDXJxMJqKzXwZ2q3YSZrmEX817VzjdbCWtk+craPnN02QQDUHjFim6JP18GYkv52n43PdjA3U2NN4FjaCaCTiNF4Ka
# DATA lpHUYy0XjsGSG/lRuDyiUfNjGoY1LbDCAYhZIss9Cu+ADiMcjeAUY1dJ7vI04/R7M4z3C+HXLhUtIpr2oyFE0IZRP6URWajIPISy
# DATA CCB2KG1FWcvon8szCg44pKoAPyhrCirTINPWBZTj4K9JxVmqxKfJBhhOon6Y1rz3YT8hmlRJKXNDBQIbhuhggEToT0R4bczCeOuE
# DATA DPljZqkWiks2A/X6cyr4eASdt2mEtb94sBVGPmZVa648swU8OOxFNkn+FFCOZDTyjmjI0kmUfZLeZEmZOgih2Mj1GHj18CQ8FceU
# DATA jqcqw0y7dTj7eBygYFTMKV8yUeCGf4lVuA+VrCGkMFM+WaAqrqnOBbDGAvWHeSNenyIQbfQ6q1TzSCNjC2TCmQ+eC1VDcMq0LDJj
# DATA Ekp8DDIJyz/FE/q5ov1QnIActjMI0/SUlRvvU56F7LdTAQlhXuBxmuNzHLIkX55JH0Yxp0r8xEr9Ei65oyQZWu52eWtCDY1Gw5G0
# DATA tWIRXg32jbZ8yqqP1Md899Kwb8TtumHfYpfH0sCVfmE8Azg+Gt4A9PtNMO+VXKjaOnIDjO9PSyqkN/Imhnu/j6YhfQyNa7ItJxNi
# DATA zvW+jU8BfWooiVghmodx6j2EtzhcTd1NEsVfjqmOBZdJwnR4BN+6jZf5Lwoj8w1DXUCH+dI7++rsn89/fv6bVZ7Mf6P7/nD2O0G+
# DATA 8F1MfgEV5puzP9HHL5gl81XFM3yZr87+ePYFcDVf4aeqfuorj75+oYOi2+iFvzz/lYLLUDzO/95jxszvwKYBhcZBZV4ATONMM7tW
# DATA fHHzKAECWo3cCxGYfkvP18TvccTbtjHIKWgYa/eyvHBO7jIDH0VPD4XL2XArZeY+35K/2TFmCrM50zPcNmVmtVxujjHDCTR3fQ9C
# DATA 4pTXk1H5viG0nw3QC/t9F2l4ep1oGWoDGdnYqQiY00wD1hjPxFAQDi6zvaiunSpjOqFhTGY8n9gTU4fMVzwFkfv4kcf1wvuYtweI
# DATA 2/YI+yPXbSoX9iE02rXSN8psFi1Y0xx7P2gMz1YYMttq3mY7ZaUNPSt+zLboO3qMG9KfakjXOJkrjeSvhk/29kbxGxjEdxrDdxzC
# DATA b3oEl7pYTna+bfIZtpibQMqUE5qTZYzmRB5zys0oVIgZuN9YbgCerhkVaSartUiG4WfIsAr0xHGcMi4GhaWxMpTyMMNFHBk3RGGs
# DATA hsrAegmIzCmsLfbtSohHss0M0wT62J+Ix+0ojfg8gGS73uqmfOs0+kMKgb9fyCM5xPjPWZJaNkMRMxKlDhbjYDEOFnODsJgLxozd
# DATA kPAXWra3ap5fiVP9VMa548M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M
# DATA 48M4Pozjwzg+zHPDh2l3mv1m/Yp8mNFoFAxHLxAfprzmvBMdxs6WRt3zW51xo9M4DnrN79P3Yo70O51Oc7iana3A87t1ytDOcdBs
# DATA f5++F5+jutntKy4Ll6WUlRTcqXBYgoKuRLNXLONmsxSRftTrlAMMgsZVAxzWe0GnvRJgN7jeGDaa/vXGsClV5/piaBcKleU15KFV
# DATA KJcMcEMpW4VyLTG0C+VaYmgXyrXE0C6UhgR+fS3lkgFe3FKuJYZ2oVxLDO1CuZYYFgql1bzelnLJAC9uKdcSw0KhXEcMC4VyHTFs
# DATA BVZb7hVL2W+UQlQXUpX75cG/HTVKKK52rxk218LS1kHHWq2GBR2T8FODBLOMFB3qCj8taD1dAK1uzwqg1bt8AIUk9NpPmYTdArgM
# DATA z0xsNM0zE3PP4pmFzXazERV5ZiP+n80zo6+9aFTgmUXdYdgf5jyzTr/dbrUNz2zYHvhhN+eZdQfNMLhxnpnyeqgNDWYmJM54siXZ
# DATA QWF5L/QitZmfdXmlcs2ifzHkMsfsexEZsXFYkZiU9qKsCc52RPIiTzF0te57cTTM9GX9Ljl9O02Oj6LdlopauyxOW6GWV51tn4mu
# DATA I0W3cyAT+ZXVQ79hLRKre/2g6IXR1ZX3WI7DYXLCCzFYcat7us5ZedtjhwXPis1sbsN+Oj2JVbld38xAs/P0Ao+GlVulOsmT5cCB
# DATA 0BwIzYHQHAjNgdAcCM2B0BwIzYHQHAjNgdAcCO3VBqE9VrU7poK7q1Bm+EyJrnCS1EUc3UNGyO2iunmXOjaqM3uoWvHd+mH8Bj9x
# DATA GL/++v5jXOTbDuPR3kk8I+uK7LDT+SL5Loz4jwHFmP6Iw9l/rFvQ/C6D1hgEstcMes1euxP02nc4Svvf4T8qCv27sAF/SLP3RiAd
# DATA r79/OEweyzvKr9jr7x8+YdnMvf6P6z+5d5fetX8okm+48G0O+nX/8ElExrrSgrPiIvw3DnBPxWOf7lbqo/MljXqq23si0UPluKt+
# DATA /mkSz/a4t6IcBB8OjeF19aMs0O7thZU+FUf4er9C1mNuyavUTuK7G63ZSYyCmcR2hbwrzYPKjd4kaaOZI17LNr7MCHCAHO1+jq0E
# DATA s+HeJN4/lDwq/s6r0jRxV13xPb++X7wBQ7CKz1u4tyanp6myPdHIOnP00ymrOGWVVWUVcxjYqas4dZVLqqtsFMW+AdWVjyHHpRVA
# DATA JgnrfbBmlxFeebZCXrdBp2NTgK6KJ8hLRpyYC7B06qG8R1LfC2qyK0Q63wLStW0cnb8FRsfmC6o+PmD+gaIowejUPTmMTj+0wohr
# DATA S1CPxETazJLjMekdeNcvutMXNWCyQC+6kRV2PzmJJtSJXnBvUFf3zsgELt27O7qOqzdaOZfoC0ut+xvNaJDxKCPrIRoaqT0jr0NG
# DATA lpHFEfO9LLXDJLndZHtYxMbLkmUKlu9IcCrQ3xarERoOOZ9OvBZkJM6UjA8l8dRTh+6NWAy9c0UtZty4Z+v/UJoaVDATXShskdm5
# DATA aW3UVSUw2Yk29zIohuRjiTM6ndG5anTm1oWzOp3VmV1oTz4zrb8HjBriSLKLG8hRVH9jdBog2TQepIklgbdkC1Xp34XUumYD0C1W
# DATA te/MoJi3KDUYakgJS8kNkuk0SgexHgPZck0jrLRg48LO2n+csvm9B+Kt6p/CZxZhlwmGUQNQEvYvDabYS7FGf0udd1s1UZV7FjWR
# DATA PynjVNkc+sfcADJX+OAz0GkRh6PiJ8sNIjioI7/W9jQ+X3CC1Oei5WndYTpK+6kVww5OU7QFsKbkvnibHaiN87fZgNt01yABcYOa
# DATA yzHf/Fb+dfMzXIlw90f4sMW6lIFZW3jiQrVNEgwSW8y7Qgljz4c0aHW0M0c6UKdk2B3ssZbVHZWXdl6UcEC8G8a0c3EGc21Kl3x7
# DATA 8C8//7/bJhXlaKucVaaYkqqkCpIuTsUYI/uORyYwebQlyYMQTfuqsLuGPF/07g+HkMajp4UFNEBjo9rPE0XmJ4O9ggfZ/JPRkYko
# DATA mpgM25TeUvPeDGc5FXA2lEmp/PQuiDB4SaNOg6yhBOljJ1fK11LtuUL2Njdnb6EuSi7DXhYbnhKyCCc6n+8zT4YGiXlFck1PrDnX
# DATA QmwCWMTTyIayzSdLnj3T/HIpFj0TkJRH37sfT5FXI7LWsjFgVWx645If4Os8ydhEr3nvAL6I1wzjbLDMUEAckixKXkcum/Z22fzd
# DATA nLeq5epcRY9PXe8CH3Sevo29PaHX+D//1AAraUh5gsWDGXjmJ8AHUd1aUt5RWcgUP/N8KtAenBay/jKIaA5S8z6iLpum3velYkv1
# DATA BQGKOUl8XtGDe+PQe9O+A2cIxV3CM2m1yavmfZ++RlyRqfyvrSJfOYu39xCFbP6UBlqaZFAQqc5jY86OqOFXRc8pZ4FBO5DqFyrT
# DATA XPJQVnwy6QvkblRS+GlChR7HhFAe/BDapTgZmLFuaWgCCWcaSlWRl9FvWEKRuHGmH8UieQoe2XGcUAtRD4fS8zwfnUf7Up3Hv13G
# DATA vPKpB29dCJLBVH9pjEPF5grINpA2jGQ6hGz3skk8p/zkxsF9C0BnPL3ps76p9ghCQRWjuiixctfkHUULKTrOQiwkZsk0woWjZcQd
# DATA B56OZzJRoX5pcS3dx80Pfm/xuAQmUmyqtukWxa2xOEmkQ5asRW+cCUJThJKjOKXR7QSh6HrMMraxUfil6TqafqpaPtmCrOqMd1LX
# DATA hNOK1Fsfq8kdhY0npgkWcnnugJ6CsRPSvcBmLWdu0VyRZWPbXDFXJLPuUQNTC7xaSFjGbzEVLfOVmtuYG54USu0i1tPL4HLJZ1vO
# DATA 5eJcLmsICs7L8vJ7WTY6UJ4rokLhqMDqSDmxWQveJF7giDMroTASExRLNZqwCyZ/kM+TcMY+awTD86xVfhE/yTr4IauSfPTl3hvU
# DATA kZbbmz76Xjhe15WzfNa5fLkQTqQ7LOMkVo6kS/sdJKgd8rbT2UBHRak85n43W8yey2MNmMN6jr9wetRKzDi494BtclNFAEEOZ6dm
# DATA 1er7yQlwyKeq7nzX4wtLeKfIqvqu9xbdH1FnCmMIRkhuCX8Xk7B4yhVulp3I7GGBjXYeLx2z/n6siK6aTQUYbUi2Gfi40C4jw6uf
# DATA PIpWeFHF2vJuzMBMdkBSdiwHC0qkFPursORkcy4T5nHblMv/zFjK/wHk5PlvPRApz35/9vXZF6uEy9Kdf8mBl7i/4p3/gq59Rf/9
# DATA 5uxr7/zX5788+xJP4N6vcPsfBYFJt39z9vvz/wB4pUcffk63/UludRzLF8Bk8zL2+6fqAKLp65FonpxzT1DzZLe8ly1lwiob8plb
# DATA Kw9yA8aYwYMJewRmMo0aYcLKDQ5+MiwtjHnz/BaK5ZsiAyaoDIewLJpw0uhvG2BZKpKbo1fCDji2untV8ZiCLj+Vn1BV0DzxsaqS
# DATA qIIzeMSuFWjJuyXGYcb+GqB/lKNcWTAOarlrCV473vI+7NIjsVUMO7rC3eYQDjYNCDJ9lhjab8ejUTzAhnxsW5YdN5FmgOtbZxGF
# DATA QT+n4u5fIVruVAc3myXF1vWsuJY7JcIBLt1Y/xRjvcZbXn6If0U8NLc0vF/36L7T4H7psf3WhnaploVsyDGXz6zd3ATkspBGTMnD
# DATA YsKwrVQSgGCn84UMhfMUXQ84deOwH/PC3yLTpUZPHB1hgeUhVYNM5vFUj9UyN6bbMjKbEXgSU4XE8pcQ/jIo/qW7Ii6RjYYJiGkD
# DATA xX9CXT3OsGENRKEddex52+sKVlLVpGrBWJAFIY4lS6QgFOQhMgArn1l1HqVVtuqoBJZT7mUPLTMBNyLKVTLYNpoNjoHpGJiOgXkj
# DATA DMydB5idZjKXsIdvz7S/imV/TYa9g2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4
# DATA poNjOjimg2M6OKaDYzo45nMDxwzajYiZW1eEY/ai3gsExyysPO9ExrRQb34rpyw2ilSxTinDG/K75HgRWdbstuudNRkO7GY7GDeb
# DATA 02qz6fndsaDOLPBYmUaWg8caK9C3uhXXElJtJa719qa49vvtbitciWsQUFy77euKa8+Ka6e7Na4KZrc2rs1+l38txrXh172A6u/1
# DATA xLXRvZY60Bl026G/Etdm/TrrQLNzLXVg2AmH7dX62uxdZx1ota+lDnTa3X6nvxLXVvfp64AVHIXWbHfG7Ub92G9/v1vC41KHOmhd
# DATA DWJHfamG2Em3bEHsmm3qNro7QOyGo1YRYteMmsN6DrFrddqtTstA7AbdQdQf5BC7Rq/V7QQ3DrHDHqqqrG7o0bVp8essWl2Xbc78
# DATA /stx6cpO10a+1NoWpyuHzOdUdvOltrf5UvWcMA90dVVG+Zr1NAMTBTXl6rVW6HDwqWHBSf7T4N8NFy6eUZ3yukKGk8rQLNLpVK1Z
# DATA R9m7GjFOVgzUIu7aIjCuvbK/YCNsziqBLbbpao1xfDnHl3N8OceXc3w5x5dzfDnHl3N8OceXc3w5x5dzfDnDl2P1RoWSY58nJfo7
# DATA 8pUP79HXO/pXAc2xsfnZa++o439DcxISh/WYZMZMtkEUT/Y4dCariX5mVvuM/je7v8BtEqz6QQHY1DeGw+hwhzTh9vgEz5rA75RD
# DATA 4WCsRzMeEQzuzOkguoP2mw/auwP2L/EB+8uqHz43B+9zx9Z2NUQWeePTrDMaociygMDymL5v00J8tuf0X7ATqxep7+SOypvQRiyp
# DATA EFyzMGJZx+ECVcT7CtDDYgiUq9SGMg7MSAt9tIQ3hncweEdLQMH6EbPBQkv1G7oHNFnHOO29S1cTiNxr9UORiWJEg1JXoHqbaAFn
# DATA OVHOVV2JNyD7+Uw5zqH3pULgadS56NFcphVKZbqserhVSanU5OC9tuEXrLr9IKGRbqxOq8vmVy2+/WEIuUUj059GJ2GKA/VKUPQk
# DATA nMjR/FBVUG+ChDAngR3ocZiKMIVEvngeehGySOoPlgskyRyCLmuUr8ZR57KhNsykJJhiwx0ENmF4+DKMQiOlHmas0qCEtULG0/Bp
# DATA 9XixJXrvgXpzicihFzERs4Q0dEWCAGZGhR+mCmCQTDLFYzQ0HQ4mfeidoBfi+OK0/ZZIfiSvWZOJr9CJdTsUZyM7G7lsI5dqlZOl
# DATA crJUV7GON1rjNyZX9b2Y2wAbCaESetIKNpRjDy3tqlvWRLwNOLA4dxiCA+sxjZBzUKncjgfWj5neyVzICbfN+kWI4EZdDNkdKMHi
# DATA dQKy1ziY+BK7hPDyCyKsnzcRNhfyCLfWR1jiqKLsl6Nc3xxndo3ZVRdVa49ffEc8U/sXZnORwqy/53EO1sa5ddUoa4cZ3fDBep/b
# DATA BTHOAzCRti5Zeb022lasVfXRkW4V4rwRiPzmMp4MrRENvcWLy0X+QIZhGd3DOR+94QVsPZcy4GTuvfiUiFKHkuSP6aEIPK773ig6
# DATA YZc2O44XxqMKHaw1QvJHKQvVmfF/Fh1r5pWRAPuh6td1VwjgWggsOvbPskFe8/4dWQpDnvdQz2h1s2T2D7EzSFTXNCNTXNnSkXJj
# DATA oRTJm9n0wJSOphnCgYsXm6ZsL7ERbo+uzgh3RviKo3rF2nJ2uLPDt5nVz49srBrsdDNgHxjagq0CD9wOjVWmFR7nQ52SKK3kKqY8
# DATA 1BiBU+h1Ym8VRh0EPhfJTgyvyomINjcSIEq2jAUzI4dBNmmuXpmenL+UGzYk8PuoFHoWQaPz0PGTd+Enz9iHiifEm7r5TnEnyxQC
# DATA n7aQk7Vb0XL+gWL7/BOU89y4JEbyk80ISZ2vApG8X/Dcw6VNVQZQ2jRCMZWAqWl0RDlm/LPshxUkFv1nhLmzUp+lGpnxjXTbbBHT
# DATA hFlWIHiuXPPeCtP0FKKsyazoHk9DZjay1bpIT5WXmEVZsQcylYjBZ57MtJ9cTR7sRpqv/ugmkq8umT2QMspvSb7JX62iSBd4sy83
# DATA zBCMUzMTeSpWaF6VL1nM72wuZt0oVDEbp3++JCN7LbjH0AX9PrpYGDmhMFlTstj1KkdmIetFC0CUonnpRQLPJsnJ5FQkoVNWNkbn
# DATA irHILPVQmfMGPnSQY9MrPlURbk/arRVioZe5ZDl+vAVmnPdXusUKekRJJKcRWKw05MyGSgycS1KTwPJ2OoxDmgVO2UAdRYtTGk+X
# DATA yONYOa9C3ZIVbsxM5nnRhUbXnI+WmSUcGnwfYUbKPjf2gGGBMBbg2lO3zW0JvbVyvXIf/GDnPpgq7IJuEbpu5M2YvZ09PF3pfzXb
# DATA RooVVo0ITbORMY6mcTZn7Wvvfe4xQ/YSTML0CLLSUGacZZpTf5Kk0r9KW5HOdRQCkQy3wLW0y/Wpev671e/v3K2qsYvsK8jrI6mh
# DATA GqiGoSZYmyYp697oLhNtLIodCm8Ln46DOA6KUvGt46MZXD0yEdUWJhwrLA0OozOdp6xXT72uFDPH4zra3g4JeyG61rcv1bVqWXcY
# DATA JsM0PEED4d0Jk3hkLVQr55q+Q1kPUYhtoZQ5kL0Xe8e2ZzCj4cLSJs9guah57PIza9lqe8AgDefIcz4SqvdTaA/Z05Xr1hReqURv
# DATA F+D9VB7al9+nmCMwBxGN9vEgKyIwvzz/+dkXZ386++r81/T5F+BZAlv5J/rzC3Asz3+uL67DYn5z9kf6/5dnX5//A+Muz/+OoZh/
# DATA EiQmB/17uvJr5md+zeRM7/xX538PgOb5r5iOSWGf/fH8HymIX9Hf39I7KQTc9Av64Q/0M93zz/SSr87+fP4bh8l8IRyl2JaG7kp1
# DATA i6rmcdDZgfiieAjr0/Sgwt+PsNkdXtQBkHUK1HIcsucqNFME43MNPXjhBuOa986j+QTmC3WmKCzEWhk0uTrwVn7mWxMav6QlIn6O
# DATA oGn7UHWfcdsEzZVCuTmGJldKcxe2FvKauvIArhA3qWrHibn9AX/1INq1nEAk7DoBmnEmUYH3UHY2RjjzG4IfdBotHD1zl7K7AXIm
# DATA r5Lyank8xVQXoZkKoLqnRcRH1Aaox3ys3/sgCrOlWr6lHFsCCsV0BZQc9ZXG95wxZ8hbxJNIuaxT9peTgTRcTlZxmrtVyc2WTrmt
# DATA PSui5m7pcEhNZxfchF2gWZtXMQdeieXUWzMFrt8S2MkQuJQdcHtmgNTLUi7YuM3nrU3dBIezlHxONNzUzC40kSnDN7VCcZ45x3Bi
# DATA TBSP0z5Iw7nFS89G+S8H8Om3ITPEl6PxldnDaDGA33tXHGc+4lsWA0Uuy4f/qdgJQ+zLg2oUFGoovp6EyCdrCvYAL3xT3JJhVfnx
# DATA 0c6zjPeRebyHS2wR7VSkUQnJFX+UonXyRgl2W4VmGc2hNx1606E3bwS9udNYs9MU6DJG821OAa4yA7iuCYBDbzr0pkNvOvSmQ286
# DATA 9KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvTmc4PebLSaw3ZwVfRme9QZdV8g
# DATA 9GZp8Xkn+CaFHtOw6A1EZqzHeTk4FbphL8/YoCk6VPxL0C7yC3vDUdRdzWUwAYPG2A9an1e7Xsv3At/z6z3+02hVu02P7ONqr1Ft
# DATA VTu9qh+0vaBX7QSe36EvjWJhtLvdVi+SdxTjHDSDPM70vjzO7SCPspBFrYrRarSjVZRlp+f5rc64251U/TpFr/N5jyLbblQD+qHd
# DATA rfp+t9qptlpVv9kr1RY/GkR+iXnYb4ejMFjHPGyuS0pTYj9QMe5YEMamlZRiHR92B4P+GiKj3/UaQffzbrvapJQ0el6d0tT1/KD+
# DATA eZXKotGkFPpeCa0YRp1me23cWt1OHjcK2MrmnlUz6kVapN8cNNtXIDVy09OkRmnFFqmR4jLo7UJqLFwBqTGIutHQIjWG7WFnmJMa
# DATA O8NgGFqkRr816DZunNSIve3VbSYNDbiWj0tsY/OQtmRsKCFSOfJLM+Jm99se/iVTw2NzIw9Cj7fWEqP8yubkjl7/wIrf2rkEhwhB
# DATA YdvnX8fdPAfRpumhZYAXXKGq3C8HVhT3Vw6FLOVJi/KE/m3Iv4XVqmbLYCM7rW+vJTyKsUhpljlfvlxqLWCtRzhuRDVeWBm0Pbm+
# DATA FkimBHbx7RxOqWh4FluaDDkOpONAOg6k40A6DqTjQDoOpONAOg6k40A6DqTjQDoO5ChE477rV4WnKJuOAX8ka0YjHx/o8+4nkfJn
# DATA Mu5xT+EicQFPSFCoqu9io9+ez0jGwVTYj4VA1FzVCkWuXByMiMhCPFkdp5ej9t48jgaRPo2IM3LwH/ZRHkUOZH7yxp0Od6fDdz4d
# DATA Xj6i5Q6Ku4Pi23W3n5sD5A/iR9KEKjQ+zU6x5B/LIUsbfGOOPFqiqWgyEznUiWcfrp56xlFQ7nnV2ekRQpGTmVk4iS4pn21ULcX1
# DATA yE2cbk6mcI3a57ydcvYuytm8o4SrIj5svg/9JW77Ef3doplNg+JC8IcfyccXQS/b5MElRSLf3CwSqXJTBCLfxCnOEY51Y1DK9SCx
# DATA WcYjy52qCs6D43Q+uKw05TmFgOckHskJ5mTBFIiMhya4oBCMN4qoHk1gENGEJZGDx5wSTUR5Gu3Mq2bJWztmyTtaE5TGZJ0hb4YT
# DATA 6AqwVi9HlxoTXzBnrmUJh2VFvRG8y/Q0cooXSHheB+YcDc34Q02QrL9YTuYjsNl1ZIxuB5fMlx9tzhdpUaqmLIdsmeR1ZBamNCf1
# DATA ZjSn9dDPMBgU0q1YkIDMQA7/gUXDVSqaCaEMggQZc0To8xz9/fGpNm6eYR35NzvWkY+SJWtY/HR5lOeHVpuea/XpZDrCphFgGqgT
# DATA mGN6hQbBNCOFMRqSqUGD2YAybjJOljjxVvM+wYSAtRVYKUHsuqNJ+DMj1PGU6rN5V3jJ/Ploi/as7lQlh2h+7c31Jcmhj9LkGHWA
# DATA 0kyzm6PIoGN5kxxVmnA5gArH/Zm3nCG5uoeBQDADUYFlmkB5H1LRvLj8DNvNxzu2G67USrnFQtayIsM0WUJ9fAmliokYDymfkYW/
# DATA H1Ss4VD3LFBajqUrZbPMFuINpbpQf13Oj9uVsn1VFBpyM9tNwt0kfOdJuJtxv+Qz7o2T6edaso33sZgdLUJl5V0t996gBl0uYb3/
# DATA Esk12+q6spXS2hwqF8IJfyvLn63si5QKM0iwc0hedjob6Jiok8b3frCyrVJP8lfV5azH+AunpjC+TwpkL8AnmPXCimNDqp40gdf+
# DATA hfwhPjrNw81zqlv3Isk57Shs65ktVVJ9C4aD2UC1xVD7l3/6T9qM4FeOA5GyEwvSW0STCU9dFGhCFL2+B/sz847EygoXTIsYQoWN
# DATA Zizj5bSviyv00vHpYjxV1iwbrDw3OIrlZ7H8WIwM02aImlmaXx7veYRIl5JGrlBupVEuOGfUAPUKtGCGcnTFSZiuaOoWC5ShRsZw
# DATA ZGLVKyirZQXjrDZnte1sta3UN7d24tZOrmCxbTQOb1J8lwFNI6Wjz2LuyGteiC9o8D57QfhthgDO+Xn2WsvK0onYimxbDgvXCmsa
# DATA stRPl9+l/pfPfvMVb28wvQh0rx813Zm5YFYY5IBIGRnvF0H3NjK+XvM3r7+oDQV2ZOXSLrE1D5vo5ldMfHvXGV218YJ+/0Dr/y6S
# DATA RaFK7H37omibQEy08ysXZHPdindja7SV+WoWzGRXKq9ySZWPeIuHaQqZhYhCDbv3hpwJVnFW25Ntp1p+SfqfWFBVcxq7lRF7R4J4
# DATA SviT2FaM0sq7AFuV+oeZ2V+CxmeM2w/EmWqUmhk5fDKOJ1HeT8RQq11gr07KkrdmpYNac5SLN7M8sFrhhIkrG1dk6xuZuqUqoHda
# DATA eUOF6jO9gdYORpdq9T2UquWU7sf24Dwc1pMehDNoB88pATHOKYbpnBd62XMMFDnclSfjSAz4vONCyiA0zf0aL2yR0VHzFMwOKTRC
# DATA 09lyTl2P0g8uikvf4Xx/VaxnC8LFc3SeQ9gcrn9iBteX578U3hXIWd+c/bNCcwHOBRbXF6sErv9Gt30FQJegtc7+pxUOfWLA1h/p
# DATA Hg3Z+vP5b87+l6F0nX1BN37F7/r9+X9gQhdOOnhnvzv78ux/UqUJJw649ULY/2zcW1s3gApME+Bdp+gnuL4ZO4ZJrRnkyalLYvU+
# DATA 6hlnovp9wrrhsnShZbcriht6hMY+Dvvop2S2LmrYXGcgdt6PMEPYBtv6lO4yEXKorYLpn/cMt03bKpXKzbG2hPZt+E+8Jdt6q3Xn
# DATA TzMqbn1jsYJdJ2IrFLCVhiuoBUJJjMNrXVBc147W+igkoxM/U6xb9Uq9XudRgzKAuqia9xENIMbqYYIFT7rG4RxrwXrn/yLsHyKS
# DATA gqPODIQCxRU9ooEAZwvKDK0Lq9tmM6XYeJ4VPOvCBDhulhver3t418ysy4/qr4Yz7xZH9Ose0Hcaz3cezm9lNJfaWEi67aN7ntrQ
# DATA TTCyCglnxE+mmO12MmnSHWZq0WyIRbM+LPMQO4krlNAYSB9qNDElYRKDJTUb6teOwngCf+UgBKuI2ULFZGG0DU1GT2mA0wvM8Syb
# DATA I0lwkVIL2ZWWlYfMmgGZvI/iz5Qm3oo+pjoH9wpd5DPlfNqc/RszrPDxHHbJhKh5KA7YZMjILDELMnNWnFL04JSMt0fwlMXDUJ1k
# DATA j8QwjDLsQ4yzMdYxQ3g1BsJdQbriETYgDsbRNPR45ztTuOY8FjmUlkNpOZTWDaK0LhyDdprq7Gg+394s4CqTgGuYAzh0lkNnOXSW
# DATA Q2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c9N+isoNmst66MzmqO
# DATA OqPOC4TOKqw67wTO4ozluPQ44wTNVPcLchRtv1vM8EavtznH641ecxXk1AsYSaWCsuBSnXq31+uvg0s1JJBBnLIElXpZ22JLNTie
# DATA fGCuW6RJDXuNTnvd863WTs/3+r12f93z3eYuz3ejfif0y5kwDZoNLwjaVarYrR5X72Da8FtVP/A9vlaVa1Xfb1T9Zqfa6Xh+17eD
# DATA 5g2jJTxXd9gd9tblIOPCSjW/0/OaDZ8qPF7t1ce9eik4k3crwfWugMDiJqQRWNIaLQRWo93ud4KrILDqUS8KLQRWQAF1cgRWMKwP
# DATA mzkCK+i2/Xbv5hFYNBOq0u87TdqDgMbKot+qMNLIiKdD9PiAnOE+aRtOGZ86wTqAVLtW1gXiLSePSy4TawxYuTssmf3GFO8qUzx/
# DATA QI/a5Xngujmf9hJ22Usoq4PwE65ZbGsXE1FcCJA5omdPfJQhlz9hhsE1K3ZlDNdaj4+uqEUPwyZol3Eeq+jAb2xNv/j7BflUfFEb
# DATA yWG/YmHryebnzTh9wWs2TOE2Y71MBd8Jx7Wt8m6e1pcq87o6uZxcOLnkKDjOl+N8Oc6X43w5zpfjfDnOl+N8Oc6X43w5zpfjfL1i
# DATA nC/UBXVCPhoe2tSvBZZMOSOQurtS15NlOohQQbhWHcYjNjJVw7zXqsPgWYwBK3gnTRPE8W1leaF5kclDfXR6JH2yee3dkjFtzQnY
# DATA hK1gclER+he2NXI57AtzzARC36mr+Ow1tmvEPPfezY/+kx19mq3pC/YPn7CN/jiPDbZajuIZZYeimrGMqNJ9OLaCfwudDzVXuFQr
# DATA OMc4DeUMFZc63trHHmWaX/KLrPgpQV3qanAS6sPE2KfeCc4sKuuTfuMIUrXm3Mepnar+kX757ja7g8uQyidP1908ZfuPC5ERMSoT
# DATA By3SqN6E04CIh1j9h0+MMf/ZaybwGuJGbzUXXqe+ChQ2ukatPT8GeUdu1LnBZ4/K6VXJNZVta3vhdK4rvN2CockcXk8Bsb0sebYn
# DATA NvRgkU5oyve3fytfsRmQvu7/9V/Ld3qU8vSz195hxMNr+483WN7K6KauMFs8YIt9TwrVSdw7NYUrqSk4FYWXW0Xhsur2z1RdwThg
# DATA JUUi1mcpuS9CVLd7H2oZbk4pH2RdQtoy3pyQt/XZ/Vx5QGKJh7Y9+IDbLW/zwqLQxqcK2SHGgtX28qfuIKZah5CPxm4UuDckJiWF
# DATA QK16u7j9cyc28QIcrub/XjM5oSiKcd3chLLWyFpqwmVVsj5NY2W6xTNmNZLtBmPGqGQZHRBWLstgAZ9AyGy6FA2HU/ZTV4yAvlRG
# DATA VXm4omCUzETR3tL0gMZByBZ9MlowXCmN2I3OBC4F3GJD3+OFQdYbn0WP2MerlDUu5Bi9HOfkTQjOuHPG3U7GXUkpx2lmOc2sS1h1
# DATA G03Hm9LSek8Em6hiq7m8ciJwNc/JPret2HgbIvfKs6AzVyf9Db0TQyuO69ugmi6eMlxmZ1lBYJ0ycjJhjzYDELBWzKPbX8PFdIg+
# DATA TT4dqAvKopZvFfnDbnF124/9SlBp/IQGRR2jDZLyyqlG73qPP3GVLSKIzS2mb80fWiEAB4xsOEk83kqyBTzcFMMb3MPSnSug4I1i
# DATA 8saHlVedF1dHHlMekZdSNtI6ibOlETibS6upKAmzfxMehw+ki1VqZiCsaDcomonKB9Z7O5kVtdBENSsEpMV2ySl9LBowIXomiKTJ
# DATA qXKEmuYOhSsR4KKnT3C6i4dO1pyy3H81zxQXRkSykZeDxVJRmCbxFBd5oxEEqyASx7QLaHdlOiqlipBPRWwzOZ9aSGkVXaeYW+oV
# DATA fuM6VHM+U3Mulp1/OSzUfJhxJqozUXcyUW1bxBmozkDdang+a7HXDwuNZIaBbhFPcyjTA1kmZQHUikUBlNR572gZRAgs4vgOZxf9
# DATA jqYyTHishi4nq4WGRxQvbDmbnRo9yB0VXDm6JjZCgqJaAEFHMQiosVK7j1jfEp3HGm+dOnG8xlKVPQqoYPxJ0YGUJaN/zI0rc4Wl
# DATA J4CcjzgcFTvZc2O6pc2sIrPxgaE/8rloV1p3mC7RfmrFZMTOAYyO6BjlvnibhYkWqX3Jm++ydGwF42i+bgk5yuIjTvvb/GmL7Vpk
# DATA g8tOAttgUTTzTWZjoYyxu1oa6xUA7Do3Lglgf/xkM4FdMlYI7JjERZqRrpz2p5rE/gm2jFLK02Um2724Bs5YO1UJ6WIOBDKnXoGO
# DATA sQkjxAYKr78kQ1cppsaDmvd2zAKrSxba9aZxxrNH2euC7UpMEeVNIHKNWyuvDAuJAQgiel2q+GxPjbYv1aBLZvC//MMfN+dwoTZK
# DATA RrOkaxqJ8C/8qvEgXhjkPf+S05dY+5aMatFSTeb61P2CalvKOr44vLqIxT6/P+JD4TQ3mPbjoyW4j8r1W9HdnaCihP4YkrHPEr7x
# DATA kH+TCft15OgV6+o0262ufhhOpSpAyjrPOqktmOJAwVb2+YqqLXSqJ9ECSCzZ3WSe9hjjgd6LQR+nQMsKrWsGZUA0CLL+KDrUe1JR
# DATA qA0KpoE8++r3by9V+YR1xrGnVHy+jJaRzr/3MYPDpI0m0LkS80kYszOHL6jj5hEA0G9Lg+Q1Cak4WV5ROWBk/QhHCzg/KQNncCFx
# DATA QAt5CpjeCBRFGipRaNdS9UzXfsmMfG9L3VODhORheYXSW6ThMY2bJ5QGnZkfq6MEYyWQHUq1TMmGiYaZMgqol5stGByHsGCXyPyE
# DATA GvLM9AyqV51Sr5HxXDKGxKO1rJrD5RaxknOPaP6rVbhh+z3TfP1k13z9hAl81nIVzjfmrVsth6XREfaDywERSkimhgyMNrl6vZE8
# DATA z9hXkVuG0WjEOWz3A2E/Y/FqmqGxe0fuUdUZvalYfTE625/KbtZShhaNBNmzaBsJ5opkD9m1enehntixs0Xt+qOOaDBOoJ8Vwl9K
# DATA JakL4pVYeLMxelQSkU3Q+89n35z/3dmXZ//r7M/nvwX37vwXQOLRf785+935bwSN9/uzL85/fvYV/p79+eyr89+uEvXscJiV9wum
# DATA 8eHZb85/jafOvqaLzNsT9B79/ZNHt3x5/g/03F/OfwmcHmLQT6OTqkHvfX3+K/r7W/zMxL0/ObTei+CtkZpm8+ZlyvkwRiudybZg
# DATA EBt+aHwzonwPc4wshiGUfthSkPUN/P5QbydJo0E8VzZXtkR/xK19mrBY/1aS3lsSL6sBOZie7aVB7tw2R2+1TG4OpSdVJ19J/Fiq
# DATA kkielG9GT2StOUYnN0LL5h3Vc3XogrJCJox42zSaLR1Pb4cyu3aknpj13Jdz1wMvs/jN+mRA6N5N7Hnuxj7JuyWqrsmJgvpowjnr
# DATA rAn6lw8doNDi6RRndAATosI2MOJL1b8tGOByo3pWiL2LE+EYe26cf8pxXiP1rjS8vyILMLcytN/AyL7TwH6Zcf12hnWpkuUcsNB6
# DATA z7Lp3ARJr5xUvSgiLtWQ5SZLI2JmD4mI/8qYWBEolizOyhqrKFkcR4tkzs9EGR9oT8hcWoyTYbYLJu9j5KEsY5VjRNkLDwFv3KXk
# DATA T2NsMEnIKsOeLRno8+pC7wyzZQowWMgCo5TJ7M+vaLd9GqH9cIpOuWREB0dIgHCsMKlOV4YsnAjuawBnteaZORqeo+E5Gt4N0vB2
# DATA GT12mqvsauzeqt1+FbP9Oqx2R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfF
# DATA c1Q8R8VzVDxHxXNUvOeGitdqB/1G56pUvNGoFw1fICpeeeV5JzBegfrW6FnUuEa9YahvfqdT5MaNBt2eyhuKYEwjqwmikQfRbNbz
# DATA sgmEtieHp4JeIbxOMxg0BisFFbR8LwiCcdCpH/vN5ufVttfzq36j5fUC+lOvdvGl2gvWlNwqmq8VUGit+rjZ/rzT8Tp+tUn1wG9e
# DATA QJ0zga1g4oLO2gzoWuQ+irxVORutPAMahfd+qzkI2o36SpQb7brnt/zPq5TWJtWWaseftpoU98+rQU9fuXIC/OAKoDtuFRp0Jw3M
# DATA At11mo1Gs7kD6G44ahdBd+GwN2jmoLtOu9VrtwzobtgZ1PsW6K7jN/xm5xZAd2hS1e32hsfDi3VrmQ/3vYh6gTisSMClxbwVVFyD
# DATA F8zy5bJi0MpuWXFS6RxacUSW/P12WOs88JcaVD32vdXZcFLPqCWwtUk3btXVSBqzvIiQU2ELum79VoEy0W4Vs7Y2Z8zAp1e/6tto
# DATA cDvUgpsyRRzazaHdHNrNod0c2s2h3RzazaHdHNrNod0c2s2h3V4xtJsNc5Nk84GtuwJSG+KU22v735FvvOTIWC6FPEsW4UTuR4t6
# DATA /YNwMa7xTHKPL+6/TjmA46j0HuVEm0NjZjnn2/cK77gj3+jHjHuRRfIutuPt+XYon8phMiuQ8jtLwfCzK0fONEFMpoDmSIc7RO0O
# DATA Ua87RF065uOOU7vj1Jc9Tr1F+PamjllLK2A7GHrtsspqjlk/QyGP26AuDNXxbFUz8NXbO9pXkra62c3YgZELwKun8r5Jfc+ZBUUW
# DATA wzRmAbqWwjaw718WnbDFgteiav5m4VsZTyHFbIY1FAMOVUv+XxBd/byJr7lgIuy310W4a0U42D2+PKiC0sbx4GjSlQsiqR7KdXvV
# DATA 9wIHYiWGvhXDrh3BYvQ28h7eUi0qMqJBLy7u4S228ngYY4AXJif6QPJ7I6hsog/hY/gZD3RoexmZJfMK+zSplU7g9Z+celDSRCWL
# DATA wcsTo0i89ULnklrH58apGaoQhxQEBQgzZ6wDHCQwelRI+jg48ye4JkfZAuvuPKViCaYpW8SWCABOg7MCIy+jDnGSzJO1m0NbDAAm
# DATA G3q/LJlGuiN6n2Yvx5ghjRmAwe17gN3BKkGIdt7XXAxoeHkOFjtIrLNkt1uyzm59ye3Wy0Jhn7k8EC+YWwvBq0bfpCAJyNSfjEW3
# DATA Ff+gz8dIYYpsZag+c1WhF0SB4yawqSsKSNdNTl2jJrUenrqbEmKp/iGrbZoCi0i/mSKtalhn1fZcQZr39OiJ0DITOJXmp7ItFmGe
# DATA NTwtSLqEHjZKLKfKPkMFow9ZpAwlBCY1qWigKHTyu3yDMUrKEtwc549Z7FWiHFEW6xi/ZyZqMc8BKaqiZ7SI0wors3NstCp7wULT
# DATA ivc2PoANUgRFVgCOYGyJ9kdYmNse6weArqhY8zalaKgj/o6WuBrS7BaxoSRw7lV4ylfxTrFZVlSd0GMskqMIKlY1zzKqE1YWnXoM
# DATA KlDUl03R1S9cjfErJGBj90nO0nSW5jpLszBOOY+p85heZKA+e2FKiUGmlBXTJJmySh03iFyecjKRprJWJLGm6nlFnBUVGYygO4dm
# DATA hPVppoKxZ8WT1TvVrngZ8XIUsHfZSlDqjtIm1XIjh4meb87YTbiAwwk2MIhAtoOC7QIFE4vLNq023Wn83Ex30V82369VOjlX1efN
# DATA d2sZz6L58fxjxPL8uyTHxT/w25tRLrowBOXyg1lEncmcXYtVHFnUliHWN/yWd2SvZATNOl1QbsRPI0UgoykItspNTitkt2Pvb5/q
# DATA xQhfFxgvETL2kGRY85BTHRn3EDC2TsJsLFqq2kKnS5NJdh0cnFvJv09OEs6/IY1T82LuNerF3Gt2rdx7wAs1SDb3tSqToFgKoPOC
# DATA 5ShFGlPuEr/wJAK+CJt1PXUIV4RKryG3Cm3w8hnW2pxhVoOWPPse9akUu3dTnsrOZQKT51tQqnWNTsvKtwVMKV4mY8Mpni0XGHIg
# DATA WjopTqx4xGBYD9U8ml0pCp6ZhB1jR+PkOci79iXy7i1UgVRkJfL1wUL2lapdI6iXsq/CU2k2UY+kKDKap4pSKoh90hqxH32YhifY
# DATA yquXBlhvNl8aeJo8s/vwS2bZB5vzKx8NFMIveRhq61pn0rvMqRBuBNB9Qi88JpvDmOlk4T6khjdRaKchqw5PkyGT/Lwx1oG9j0Uo
# DATA mJlWuGKWT8yqTEYDPeU6a/KiRV9HttmD2aVrWrA54/KBUTLOOAaKBprOwwe4qrwuM8/vUg0b6rwKvUab9wxRRcW2QHYh0HRJOWLE
# DATA dmOMPNe1xDtaxorvxdxY5b1hs5G3nD+vCK+XxSGRY7xG8QISszbH6/89++r8l2d/PvsSjK2vvLM/nP3+7Kuz/3H2JaO3vlwFdv0X
# DATA +ul3Z9+AsXX+73GLJ0ius7+c/ZF++vr8/2fv3ZrcOLI8z37Wp4iqtrLMLAIgAneQSmopirpMSyoOySrtbEkrCwCBRIgAAooAMpml
# DATA kplUmp7uti6bMtsdszUbm922tXnYl31QV7WmVKqS+mG/QOZX6E+y53+Ou4cHbom8Mkm6qkgCgQgPv/vx4+7/35fH/1hAOBQmhfU9
# DATA /fYn7/jv8FOR7viWfv8Nv+nbo+/pzd8cf8F4MCC7FAHsN/T1TxQg/eSYXc+DSyWD+qHLHNk8IOlD0gg+UGqSGheYzLpTVr+XDoUy
# DATA LJwKfHEf079oJC5IabdwofZx+hwcACiU8FPgMPJGVN7u2VUa+XEwXIvxuo+V8V5waGLqOF62r0V1EFcN8lpSKpdH8lK1MFsyeqSq
# DATA 5TCieCaH8/dLbdQ3v5OrpBcJ84LLUMVEtPBlZ36o4+WAXpsV3YUzvR6FGeggY0EkgKTqLstQObjkvBS9DfYCiYwwQxXMKWJ4fg7x
# DATA teS9HfX07Jh6N5lei3NKpXSB7HVyZVxtzyy2smeF9jo5FQ7t5cyBizcHNO3rbFbAS7HaclUWwGUYABuN/6cc/q9m9JeKuZALFvTr
# DATA mjWqy+CALSQfUFOsDaXMeV+fsgLXQKhecRLm0/nOVG2N4C0QLBISBYl5kw6KUy4LTihO5TrYiAz2mH298AdhA04K11uYBMOCsuRo
# DATA QIt6MxRf2ONihLGWUA3hNeRehnniCGtTwOwYgXlAgYrLA84pauNwzUTjImUxg9g9si6m0TjUjipePkPoWIaG2VIQm4VeLHaIAUE5
# DATA SpijhDlK2OVRwjYccjaaA21qOl/tNOAss4CLmAQ4UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5
# DATA UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFXRtSWK1T7fHPZyKFNfv1fuc5IoUtLD1vhAqz88Wve1W/Nag32nO0qQb1jq1wGW2q2pIc
# DATA 4jKSMqixIqWQsnw/p9QzX3YV3y68Ri7/zTtzodfb/iWG3m5kgdfaucAlVVngfrVhQ8Bygbf7rU6nPx94o96+8NBzoLeasNgEUuY3
# DATA MtBbvZULIKwHQau60Czocc/3W/u1+rDS8vzmCQSy1XWieQYAGTc2DSCTdpsDkNWDdmMDAFnuCgBk9V63X84AZI1uPWyVDYCs2+9W
# DATA eqEFIKvXuu32pQPIdANdC58q+XVNIcvdb0ZHvUBQ34Q2lg9C88ayflzn1IIj03q0g0WZJc9suixQaigLpGI7HiqlJWvCPhtEuTfn
# DATA PApiGeA5nr8Yb5JfJzsBJtUSj2TFeCQlU+aXWZYs9NUXXlC5reda1Hv7mV0yF/0W23PLuGjtdjtPQ8Mq82pKWa7cCnNlscbayd84
# DATA 53sw7kOHIXMYMochcxgyhyFzGDKHIXMYMochcxgyhyFzGLKXDEOGukCh9IZhIeRlot5uucBOd/40IbM7THd/+VEBDtX9cJct2AI6
# DATA 2gf4aRdV8rap0Hy6DNZRsr3zWdTflod2PtNBUwuFCRKMu2FpTBbqTlG96rYd/G1WddYHN7Yleju30RV8uPU4O8bWE5zY59YcB/sI
# DATA 9fulFHHsY817kX56ipLKSh40MU62VW8FfWJJPyVg3LuxO1G799OfwrC7TelD4K/Sbzuf8dO7k9t8JoPiRD/+iK9RPJamJpdgk/W3
# DATA TYbfllqHCT03+qyGUZ6/qfSdKe8VEk6f/DHKz95jHJLKn79MKPpM8KD8iGLJPrHlb3+++nVMeuuG0XB7m5JaRJp3brJpC8ibyhKK
# DATA CSXZ1AtqSJz6Ertxdz7LKox1WeJu30cZZ3PxshqkYolclRxSY8HOZ1mGoehQnBFlY/SqIuexpBvSGd24oW8uTWZkmnymYn5L7sQp
# DATA O7qvwBGhifUHOHX3b1/8F3WmEdi86Ia/Q10MRWIh+KK/syZsHI+0w36I45K8/LEY+udZXfhc1RGeTOo2uViV1QO3c7X/ttSzXcxg
# DATA ddWzbihU6uV8i0pmY5ESFkIfVwduZXThtXUGbtbm1VMJzpCe9BSXr91dWDU/y4G5fmZdk3gIldWsPahEISo6SWYOuCRafAYlGtJ8
# DATA yPSpugaax2Ss2MlFmoI9iMY0XVwWKFbS6KFwLpMcM8bpTJxRZ8LpS7z4+hKnJclcB90JXlnJ+evX42TewyF4EDkgvqoPTgd7eNU0
# DATA HsUJzczWMmWuo2jF83OE+zJIM4saGxeNmlkmYnJG1oyXWyKSKs0rbHf8spYGFsymkROjl6lbIOAp9SQT+bCF3p+QVVYQ15No2SPy
# DATA xvKW1bx4glkk4HrCehjMkilLfUXqvRMa+ceinxArqQ8jYr9G6OMk5dEX6Ih+ruE4E8qZUBuaUHP9qxPtcqJd1vC70vi6DmJer88i
# DATA MLXyslVGyust0YWymxJGnkkYo6EdDOLcCCUIAT2Alby7ELFB0bGmTiBzYQUfC59QcwyGUR+KNxDdhvNBJKTGYdjTmLHT8lNMRBXw
# DATA QclpQ1q9sERJy8FTNoGnjGIpOta7V5/XAVESdqOJBL58Xn03dvsIN/sef1p9pzZ3FF+IPz8P6BQ7906pkt+C4bhaJz8rixzLgr16
# DATA WhyfZ0XZyIbxK4lne4OsMXzCsHeW8NC4pNmYjEfWoso2TKM978cRa1t12Tz09Al6WI0zFpubsHwvjE2Kw144vQjKwDnyr366/Hsj
# DATA TJ947Gy30ALQxlVwJ5NelowTV3jKPEPbdDgIhk8or7R8IIeH22ZDYLoZ1eiFYy4DFm/DKQivN0u0uC4NUhfDtMia4WnhDJX1+Za1
# DATA asm312mMl31/zNSZRab2KduK6lwYrhQyxOrRGCwLyUuWppPFhFTRu8J0WvL+hoEYYXcwjj6dhUZBkSopTejASpgOMO0YBFwTka9T
# DATA VXEvIDezbuq0eXlCHdS9nuTkB1R3WAVRSzUbDKnJJEojVyG2UBVq1CDhycLtPoEU5Jwpq3IvYNlFhfwbhmqSydmuNOSMqHc/Pww/
# DATA qxbcOF0Lfj0Ysh2hpgqhzaKBccAZks4mmIBRAoOkc6jmBl3RWZSdziWPV2qQuyxHnii2G+VaPwwhooipFlkUYToJuxETYUX9Mjlk
# DATA PUMzCR+HBxeRg/bYd9oKWF6fhdlQqmArqFyJuagpuDTtGnHXhs5ekXrMNKwbgMpDGXVABjZMdeyg8AZkEaJ+IctYBZSFD6lSQwdy
# DATA H1vF1B6bawtVeYFcG1kQzq/h/Bob+jXyNc25NZxb44xrQitdIJemUa6qbI7+ClOcqrnxbjxzVsY67wYzGVdy7HmjNy9zYPe3Ormo
# DATA r5lJL+9qsEdOc0XPejmXsvOR2BlC3+J+X0yDoCd2Qc4hwbta6Ge2kUyvs622p+wov4hu4WPe0I9XSKTU06Zn1N/NPL8qxzcxDCRk
# DATA 3JPxwmfucHEUPJU7ynJOLpzw0bzVvhPeJMMpscp046iqp01U9XcT1cqJUfVbG0dVtv0gsvzppLjp27PYmSsmfrVl0fOt6FXWxE6t
# DATA Chp/lpwL4OkfeHs3eZ/iiExsuZHNj2R051WRVsiyEMdC7DqYXcrVuQkN7lM5jntTgsgqsvHNWO3DXFrhwBGTiCaDPcvUzin8/wey
# DATA Tbt6gkoT8z5GSQPSkSnDQUDDO2A7E3qUDDTMwBQVKJvFaiClohOqyZZQUs3eXwtpiSE5HhYZZsk7tugtPfAwY6GJwotS8HrRr34V
# DATA YUhh98p4lkKQPz0k2zcepZkX1Y7ZIBxOTlg4nivVbPHY9qtmy8CS/7Jnix5/gA9ZiZ8pMNnKJY0ynFrVR2xYLrGXwyq3WIezhGxi
# DATA Muls2uF/Y3jhN6AN5hmEx7/F34u0w/969DXzCP989MPRH7zj/3j81dH3R98d/yd68gf6pLiFzDgEsVAC55A9BiJ+DYzi8Rd0w++P
# DATA /4Ee+g63/XD0LxSOfvIPRz8Al/gtYxApSMc8fB5mGKZ6ZRMLrvAgniBH6ZmC8ldyh6ORGCycZOjOEmGyiB5QKQqNAIaVIXhQT6qN
# DATA nkkUdmk2vg5u+FBvY6ABgNFqDm1oTSZ0gV013HChVC4PbajqiL4NnA1N3OFfFu7H9hWrw30U99WelgtHG3IEcmDDKOXK7rCGmxXb
# DATA hWMN7z+dDNHLBNoZMop7s2EA8no8Zc2ekvcB+n7uu7J9Xrz4hY3x9KzZ/0RxmI24p0xlGxRcKPE00GtZwVjQMQtAw5Or4GqrZb5l
# DATA PSuc4clpcDhDN9KfY6TX3MKzDPAvh6fwygb3ix/bNxraTzmyX83ALtVyLg8sZuGzajmXASecSyVWAEACUpy/qGslVp9znE9QIC5N
# DATA BZUDbU1vok5RPLz5WrYVa4luWElj9orO59uGRELjZc1il07jLq848nisUXHMj+Na0qO59jg10Q9nSewFI8a/8ZAfktkQdSMsjeds
# DATA gpwFED7FwWIE3gvhjVI7qtVaIVkPVJzvhUGKCLFt153CFSNGInt1hFIna+uqqDuzQ6lfjlboaIWOVnhZtMINh5qNpjabWsZXaeOf
# DATA xcS/CAvfsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r
# DATA 8NqwCut+rVbvnpFVGPb6fth8jliFcwvPpyYV1n2v6pf3i+32p36zWG16zTr9PajWK5/W2l7Fa1S8anO/3c7lUtfvVLv9eYwdhdVY
# DATA irGrLZAN5aSfAPzaeYBfverPEfxqrays5dhaRvALW2HQXQQnWnzAVj0XfKXazgffrq4M3SQzF3qtXF8Tev1Modsl0vK9Wq25X2uP
# DATA qGst1tr7tfbGOe0vwgibvlf3m4NGvT4XSrfe7XS6S1GUp8cOSrvR2EFpghZ2sNGrt5q9E7GDQb/Tb+Swgz36u1exsIO9Rr1ZN9jB
# DATA Trdb69Qs7GClXmtVLx07aLapQfh/b6P5+hpun9i33oJdpM3xubeZgVJNvd4KqbuJgoLEbynAsK5W4ioLtD4sLC68YM7tbhuNukDy
# DATA 824y9zwfdoDXkD92mGydbpxDdW06IVPEyM0HdSeYN1QsbGA+svbmAj2iq2Wv8jJvryym5JNWge+T/1J/7Bn3euLgXLYW5vNkjdmy
# DATA NslsTzjgoAMOOuCgAw464KADDjrgoAMOOuCgAw464KADDr5kwEGb7ybJFi+GkNL4qDiiv/PTVvlGpVygmaX66YCLcEembBrzdV8O
# DATA yfBBNzSyG/wruHTdEQIOvf/v//DaZXzrheGk9CH9NwZtjcK9s1t+7cOtD1hLnc/R8UINAqEfJYgST3kowhKWOXyDuHidQ9zLdLyg
# DATA kyLEHfMUPvG73rGPsknqvDCdwo8c3vL+7Tf/LyKzkPbtaqV8Q66yuCe6BgSpUWYOIebOdp90ttud6X7Rz3SflhR2Hc56z7nY1mPC
# DATA 3kXTME+UvPdQ7W1tl6VwsGd6Ovz5ORp5GRSw+cPsF80AW5QEOCsBLO+v1Wf132Vql1QEeU0/NLo2b8D1GHi9mH5ID/iM9gM4IVG1
# DATA WApoEERJyXsUTdn9pAXfpQKKcPlsIseTVeHmju8HmZTRBKKNcZ/PImeiOXMKNwvl/CSEqRwYuR3YRFevdPOMTsFaLcgZQ84YmjeG
# DATA FnpUJ3rjRG9OMqOuhxjOA6mvTLToxQZ/8UncMYo4D412AzXDaG+syF9KQ03hIxMaFroQt+jjZlGSSAPgV+Ee1Xgc3pDP8h2iQwM3
# DATA 5NDWblmimbIx+OsxVGfgH8uUbGweDPsuRLXD4b42w31RUqBPopI+5VazGvbFbkeRheaPq+/l7bncszzmT88DvMvKi1NyVx6t4Sfp
# DATA XBXiyj20Cipdsa0EuPL4IBaxpngGwZgAciwCWRmhpWiJRNTwgL1QIssk5iGNa/vwIv8K8izJKK9eJCpFZPvF2XgXQBCGakcgGvV9
# DATA NpT1mVNpNGp2sFzYeVEA2iy8iU2SJdDkmJZywNiABWXOGHrAEoQ+H//qzCX3cOOSeygHzMVK10X3LmwRdIQBswGoOPaU+nfKpK9w
# DATA wuo4iiWUR4eh+FjSR9S+qQhkknpX8xnhMVT7org3HYZTBRZIVFzSSTw9f5HlUnZ1ZZb1Jqcss5+to5WpfknK7GcQIEI+dmKKkA2I
# DATA YmkivY6iBc32hJFFuUudOC7GfbJGDE+rHx6I5pQe3KYiCY87ZXGHS/qA6W/MXDGNjku/M0sPz19a+TQ9B8X1/sbF9X4AcDsvZlBf
# DATA n/Go0oFo6ZvGQL3eHvzhT8JDsfY7ARS0vEE8koaFycGYQ2ONurFHBZWAFgZUDnhV7IDvR08FH8fQhKww54Xfzl9o+ZRdWaFlo/Ap
# DATA y+zx6jLT47nqFUU5ENey8hJ/BPbhYxigJpQKK3AojhiWR+6qcYK9cd5dLt8+47uoE4IIGcY9sTxxbMqbzPjwHIsnjIF2uYB+L4v7
# DATA 9S+RyqYl8n6olOswfEzVT4pwKeeDQj3ASHMSa0OE+mKPj3ehBRyKIKGAAVWr4f6NZ9YIAGY3D2VRqo0UlK7o311Am1lMyJmK6WoJ
# DATA c+fCmLwMfjYrCOdoc462eUebXaWcj8352M642LjSJ3dJgtMyJZeZHkZAVG7YmMbF9gyhBpdEnst5svTeE9j7vMkay08t3jfDM2H1
# DATA +wmgsywU011ZlzJq3Emos8aGHLYD7S0z4C6eF6hde9vd0YmAOwkgA9yp7xbgbik2zpfLGhxX3hhyJ7t54C7EB2GMCQUZKsWcV3MO
# DATA RPVA5j3UISz47Jplxn5hW7t3gIVM3l/ULK/28vk+P/I4fIqeqGc9Rb+seazGj71Ndx/az9TKa9yEKxF12jTFblqy1KbPL6TOdt0d
# DATA DCgU7xOyPMfhYcmWfFa6ztIJwCF0EHs+t7QgUbA4vWFtQtMkZbpj1Zk6C4oTplc8cFPQxh0vDg3uW8Rjr9z9Wl2bX6y2nXkMuKQC
# DATA q1bKXO+sFk591EzDL9We3G6+pkJvWsmwUyhahb1AFv5T6frGFMehTBVZNXsySwB6l4XtOGX9VEsgewOI3AtiPGcIOepFwm4S9KcW
# DATA Qu49fa14/LdHPxx/efwbQOSO/rCIjvunpfg3+vINPfXV8RfHX+KyR/98Qxd/z39/DXAcXfnu6OvjvzNIuG+PvlEK6VD4mkA7lYZs
# DATA h4m79qY+W+aBZ+qM9++C/cC734vkLJaI3qt9JTz77SdROO5RB8LfDuJk2DPWPzzfs4n4TuFKENfZ8JDpujFc2kIRZadBtkCheh48
# DATA FT6lhtZbi5B7HQIarDXh8d/Ck3AcuWxGYDqFq+bILS+ay4PJDSg6TC7I4NRcX/X1k2By9wKRBL8MoBxvviLbkf6lMUFcVxjN0WAc
# DATA UG6zortwoJzkWcBmzhidm8yrzHRKGzZqMjWSDoosF11ReIGPhjf0u2xt780CahTTkPq2N6L0SQHWDz1978HPvXQSKlIGjr9T2pQq
# DATA zIxtILgWpxvQ5pbX0dUmztI2eF2wc8sT49Bzznq4JOtBY+nObDS8FC7EqzMYLsle2MhcOKW1cHXGglTSZZlhDIXr2dAug2JnZQNA
# DATA c1gk7oUTcKjIlDEDtckhns2vyJZuPBrN0F1jAe8dzCC67LBgSZGU8qUb2iN+ErKDQrx/yLBUbbankZ6KjK/3o4RP0abpxoQ7gLRS
# DATA 5ZvVMDHKkH2yCBPxc6hf+zRXjviAA+8Iei/+hEY0j5PXpQyM+9OS91DHWw4oKFjYvBN4wW6RswIaQWY0LZhkhvyALg6kgweUyVFX
# DATA vMec9rG4a3gvZzhmjg5OyKN1AUSmqgTlqmPeOeadY95dIvNuw9HrTAe71pnlVz7TuAiP6lnnGQ6A5wB4DoDnAHgOgOcAeA6A5wB4
# DATA DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHjXBoBX8au9auXsALzqcwXAW7YCvREFz+LF
# DATA VTIcnZxGy/K9OadQWm/lsqtWbzfr4RxZrVKhAqitIatZr26f+dWtSqfSqJ791ZXGmV9dbTU7td7ZX12tnvnVjUq7Wmue/dW18jMr
# DATA 61rzmZV1vfbMyrrhP7OyzrXrdusqMzzXrk/36vNmeK5dn+7V583wXLs+3avP3bjKz6ysc+36ass6166vtqxz7fpqy9pu15V64yoz
# DATA 3G7Xp3z1eTPcbtenfPV5M9xu16d89bkbV/mZlbXdrq+4rO12fcVlbbfrKy5ru11X/dqVmgrtM7/6vBlut+tTvvq8GW6361O++tyN
# DATA q/zMytpu11dc1na7vuKyttv1lZS17XqolL1qszKoN8r7zfrb9DXvdGh2GvVad+ljtVqTH6s2Fh+rwdHRPI05piYgFlzeb+SC9FvV
# DATA amUxJvVy3avU64NKeVSte+VBpTyXG516WO80lyLZW2eiqVczmrr4cyyaeqschPVGnqbut6t+pZ6jqc/x1UFT74Ttbj+jqdcrjUat
# DATA Y2jqQbvTD8oZTb3m17uV8qXT1NkZXOzwJn3j6ZTFdo1Fz7ytLXFY28/MA9HNUtyyZTe9UaPJGzSxPZOZ6Iu7HRvws8pr+CDYZtsy
# DATA Gta2jJVAdyvU9ax1KS7ltKybZRddI/hYwiDoxQe32vQj/pQ9VYqfl+hVI7jAVizBVhaCW5+HWYCe2mqq96/JspX5dbJk94Fa69U1
# DATA zCwDqL2gmae7MHeiIL+8XV4NW7dLao07fFldYyc3+9UdVN1B1R1U3UHVHVTdQdUdVN1B1R1U3UHVHVTdQdVfMqh6ZjEq7YbtHWPf
# DATA Uaq9h6L9kQl/3BZiFXfZbCsPDxlXLqIixVHcC3cFXUEXZZstGnV2TUQmirBBdiv1eqPOVzHLE9m0dFez0XlqrBDn6jc0Sg1IR8Tg
# DATA gphCmG23JYFHIwUbyX5pyAviaQ8hc2HiC6o5t41SSkN1uF0uNGo7MI5wUGX75i8/VP/d2v3rH+HfhIP56OZegcrV4rRz2XqLcHqo
# DATA Cux+th+Mo+EwuFUpTIYzmvant6oFSMbdqn/+S44KT2NNXD7SePpHs729MJVxkQXIvId337tlsPHdMBpu4w035rPnpyW/xTT5t6LX
# DATA BVr/Osv/ZDq8c6FIACKAQ5N8BKH58ZNIoPJ+qaKDROesWCIYFUTwApp6InTIL1R1Bpp4U8jzTclc1jVIlIQg2aKA9JwJmYYsXX1t
# DATA nTnFGRz1V1iyn5mJBiTS5uRp6emsku/cxsgCx9WcRg7EPlQCoORiS95wjGUg+HEhL9DhdOqcTt1pdOrmxFycYp1TrFui+bOaZXFd
# DATA lOy8SYJ2yhpa+TgZKbu7eUm3vRmkcSHMtEq7TYEtxuDNRt1IBY35HauxarEqptHOS9Ll0VoLcnTmvkHlzgMMTdS16IiLN1zLTf1C
# DATA xm2lmJaRr2ADx0yoBwYQqBss4xRZRX/KAvUSXAotX0/GfD3VvQ2xWGhNKbU5ILY860nGeULZiuIcQhufkhLBuNYcQj7yF/c5OuFT
# DATA QNRE1gs9lXmYRqpVSn2c7jeUXcRye5nSrRoadfofGUPK04YUFOuA9xGlYpoPC/VE5VDEOhYl7xcYORce6Q5m0C3W+mPKXCl5PGnI
# DATA DbSCBxYAqnhqCzmqcGZRkHEJhT7pudHHMmYlQoQZVEyvMmcJ0nU5cld18ZIjqlfnxmJyYxpPFNuA60qcsJoc1M/S2QQjNLYcQ8+Z
# DATA 6lo37Fn9/zR4InAFWIVsz2DyNTlUhaoHl+AgOMwsKhmAJPbwVXuPQ3Zk6rgx2DWwTDEGEdtDDtetaLou2fx+vO2TmDKtg8Ew4DpH
# DATA 8wad8HfhQfEs216rAjINKq8XKDRUFu2iKGFha8Ilx1JyQY+68MiQbZSgnE6AyNBp+JOeYGSCcpp1w4DOIGtlxlRjqp025VQ2UJ8z
# DATA jA/Z6zsPWRNlsBdf4CwbdZyB6gzU0xiozhx9eczRlWbmNRdWthf4FxFmw5ydKi2G/p4OeECCraIs1OwR1utRKKzrKr/8fKmJngR0
# DATA sLZyCG6Ot8jceZU66PmWqo+j5TZ5tcpzm7zUUbNgyN+WtZfFY2LS+rsx3FLyxsNxV0dHqS/d+dnCKTP24JPNs0LI23qWv3C65iBg
# DATA eiON1sp+XdmMA608zfmjjTE22JaLNyurTMsDM69jNrFsScPgpMEe9qieLhjMV97AzJujloNvDl8xXxden0Wo+Yt621IpFohdJxI+
# DATA xurFBYpIEpLpEnTI6laAj7n2jtOv0hQ0AXhQvfNoJMBvyk1DQ+bmxlq+gSIi7+dnLSwDDur7JIwnQ2qhH/C6B/Iim3+wmpkiLopM
# DATA ck4nPG84TgNUXA16M9biPFKao6xKT0dXTf6MsY/Zgy5PxUyTGQZ2QsiMk7EkmKWorkqV9pqIPUjIiOxO10fsHq83eCks/kMdPXVR
# DATA ZtJsgXsBqhLnEXLyIGHV7PhgTFM2+ikaQQ5dV9alsbknk73F2LyEIsWOm+ys+LNa8fNVzvmZnZ/53Ab8yunC5fmZDU98nsdhsGrX
# DATA EvN1FfxlvfJLP9x/OpF9O7wKTqZMGM9S7Ws9gWecBWP6PeuSAfi2TgIw+xsDjY3R/wF3g4hYHmCsb8gYy2aaMM8VVqvs+E057lcz
# DATA iNU6vEzz+OPqe1HqbLax334No3gxZbyWblKHb4yYUIb59lvR6ycipq1g8nmgL5p41k4qlvopONO86q+gfxRVuYA9IdReKRPWR9o8
# DATA bmGn9ZWMN31SdKubxpY3cmQd2Ig6Buo75uKI3Tk2anzay3PG5buJ3V0vJYtJL9PYUd2ASX1fo5K5g0hCXrPQnunnF1Bt1gqkAx4G
# DATA szHNh7AgkE7zjGqT/h7gNGx28RqBRRlCz56AzAyEtPQyJe8uLu9HZO/Yi2RsCYVPu2o1w5P1CHXUoa+omdjgEQjA5jDFhjWedfCM
# DATA TYwoXqtQhlISRIreBJZ0MJGeeq48MweK6h2zTSS5jLXcIwbJs8hFzopd8mgOx7SEw8QrbPMgJmZa9eJQ8FFq5ueBE3WASkaZwcjQ
# DATA 7lThfcwodDIn+0WbNVnA7FkadeHliWILmX30346/Ovrj8T+Can305+PfHn1/9PXx7zyws+mHfzn69vh3i/Ts/3L0w9Ff6L6/P/r+
# DATA +Hd099Ef6eF/pXu/PP5twaNPP9CTfzj64fg3oGgjaCFpf0l/f3v0LXO0v6BH/pluAUn7Tx7dBV73bynYbynYr/H00e8pWn/iJymI
# DATA 39Pf3wPLffyFo2tf/wkhdWLxKCyCLCeILM2d4r6qS80UILwhLwPzavkDNUIE2qYtCBKMnVNkxk2GoeKFKdoV9X6JhtozGywzWtdS
# DATA tB/iIeqDQofOzs33su7hquHZVolcHjFb1arUmunxBa6Y6fzdnTDIuuvX6QtXxk5IY/1ForIpXGZXR3okU1srFiZ1Lykre4NCu3BS
# DATA 9r1BDJ36ABBzGlPH2n6lDGa3kyJKcm9C5bawB1x8vmSxUCe1Hw5vI64D3iZF9l1qe6mCVHpDvTnlNPVvtQWTtaZnxb4+MfIOe+2G
# DATA 9XMO6xpvfbrR/OXw3F7hSH6RA/lG4/iphvErGcWlJpqkZ7t9n2lTuQxAtUmjbA9dlTzuvJXHh8u5IDspKQ17LJURTAeShj42Qg5k
# DATA yVZWn2l6HgiZNhkcTgejrMCsvZCBzg2FLMZQvAmR+v3YM9EV8K5mLnNsxrEnrWY5nLfk3eUfWaA7FTIxKzrLEpbqVRFQOo0nZG0N
# DATA FAV3GnSQYXLATqyHLFUGkE351Y1S0afQWdqFM8LxpR1f2vGlL5EvvdGQstF8ZUPD92ps97OY7hdguTuQtANJO5C0A0k7kLQDSTuQ
# DATA tANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0lfG5B0rVIN6vUzgqT71X65X3+OQNJm
# DATA xXkjerSdH3Cx1uuDRrmyX62W36bvv5rPx7DeXoK3anl+qzao1xr7LeCtWvnHun6v2fPnHxv5tbpXoUer5aLf9CpV+uBVW8VazavS
# DATA /+m3ZrHl1aoe4Fl+sdriaxXcXveqba/q425cLnttr9YqVnz7rbwTMs+2qvbqQaO8jG21pG7UEZ/mvl+ZB7R1Gh2/010WSm0BxmdT
# DATA 0qp5ZLCEawG8Gln1reZJ5mFQb3YWYlipNM4fw4pfzWJYr15wDNvtC4hhq5HFsNm42BhWm5Xzx7DKTeKSSrlGjeTcMaxVK5dXynW/
# DATA df4Y1sv1yyvletu/gBg2WxdcyqcB6ckgpEF6Mp5ZIL12re5X23mQ3jw2j68E8yC9fq8d1jOQXiOoh82WAel1m50ezdENSK9N1nG1
# DATA dekgPd7+WVxn3Zeqc3y6z62HFll0OZeQ38rPenQmsI0Fly3lPTY9bhcrvXBvJxfyHKHvrZDG9SgoSNznnd9Vdn3LkjfD+ebX71XI
# DATA PFnbdE2tpM139udWraQjGE9vPMpZ7saxgCMG2heOjWHFUy4B1ZY5oNkPZ4WnvGCLeD5Vm/KlgcKwvBJNLK8s3w618IoSYk02qzXL
# DATA JxNVNwa7hMkqrnfbq6F7WQkX7DJZM4tYrG0quVY1Us7u9YXDUwHU+pXTqKygTjcfdRBABwF0EEAHAXQQQAcBdBBABwF0EEAHAXQQ
# DATA QAcBfMkggKgLaqK4y9ZpIcChzwIkfJMCy7CVb0t+8OmwXaktUe9/3cWPRdSW2xyIiEfsquFNfaW4/bJcqBRqhQb1kVF/vodUt+3s
# DATA 6MfN3bf5daYibo8LEfhvY93t7aonrF5v5/Z4bS4BIKdHrCx+6j0ySj7dvfNUv0F6Mrqi7Nynqjuj/0Cvs+cYExwd2975LJeTt/kQ
# DATA sLYVOUN35lI13r1DCeLjlzBGed6O5sfn4JCEkpz8VJg/Cpp7JQXB22FzLj8N/XBLnfdDR5HVyl0adVlCVk4ZU30UBt5DOXSMJEyo
# DATA g2XMnUnYlC1eIPd+pN6+I5b/8rI5ISXTeG9vmEtJIaJ2jlokSeJAf4nvH5kiUEDFeJdrpbb90y50HpHcncJe7qe3aBJBFTumISuk
# DATA jBl3D6XQ+DX0tvJrfqt8q1ot394r7dG9MBZ/gRvuslG/jVMLBRWgbEPH5R19d/h0Eo8h2BYMHwajyeM4/2zZX3z2RqncQIQoIWMq
# DATA ou09BKa/yN1Q0ovGvLKJO9kDtS2f4sn2shCbVExSgA8kM1kwEXDHbXy44TOzMe57LS5STrz+5Set21wXd62JDEq6UC1jBU4AkHCj
# DATA xFzXPldzElbG1whGXR0+y+r+bVU1PtdtgKfAU2w34iK8e2/3IBrTxKrEp8q5Xj6d/vrX6uJB2HkSTe2fpLe4tzMd0Djt3U8Srt1y
# DATA JN0ap5E+ziKpB7/+NeaDd+9RhIKDIKLZH2cf+ukRxskllfmUrSieWI1I+kdpKLc/59m+nSdSRhLnvHmxeHxdRI9EgQfSh3KKuxN6
# DATA IU3TdNukfsdMZZd0dXw+LhrStC7X6aHIzGMy5O1YsaRAVSksCRJr/PSICcp6jrP2NWn1Eoz41MyhWqdl47RslmnZ5A9aO1EbJ2qz
# DATA qajNSgHyyxK7uY91Fx5doTYxDm3ZFi188+wE1K5CZVxMAbr8GB+8bRRHenMUjWfT8CQda/2s6ZzMBSO5rFTD5yWhZW+I0oSurJOw
# DATA 1sd8Kdp8XBeK8Yfosji/YxbOoNLhBbSBrDRxcVIAcn8+Y8x6kpUT5kc2S3nJWvKGp0BlvjOfEdqDk2WFuTVLOj/oz6lbr3+Xv/m7
# DATA /Hw248HKqd5V2fxdldy7+MHqqd5V3fxd1dy7+MHaqd5V2/xdtQWp9Tv1U72rvvm76rl38YONU72rsfm7Grl38YPNU72rufm7mgv6
# DATA 73da5l1aX8W04ZXq6vb09QUQU9dDhSBdtBKRNdpQ3/dE0Eo4OkNTOenAZITE7AHYZJ6kjyC1lOS6PAnBL3jVglfn4agJilY4ZiFV
# DATA DzsIOGgBCo8MCcyKGA1Uy/2nHvpXhhlYsl/G256pStEwhXmDVgTDIIgwxWo8vR7YBlLmz7+YkIO2uqnT+qmTmym9mDOl04JYn7ks
# DATA KG/uyvZ5XQbC05LfvGBupy1euhTWuRInyxqCfPLQtFThokBmfA1W9hqIoz4nYoEbypt72c5BbVyJ11LPl+XEDuUOTaahogmVJGNo
# DATA 3VUKrUHCIldwjJIxhKfJrCL7ivmnvPYiYq0Tmcbz1i7oMGKezruaCnhAFVSm3MgTeiqkaEjv2MdORKEC7YFNxvKT9HJm5ECXT4uh
# DATA nz4XYfaxZuScduxVSqY/G0spVy2dseSMpWXGUq6rcm7ml97NvNLIevaa6rrmU3UOWFb6EB6AMd3Hm5EyjfVJgqYJGeC5RrY3o/kx
# DATA u5qTUGlgL8h7U3MxCuCWMnispvhch+YcyzmrYVFE3dxH46puxjwiUekafWUMm3G/7wX7cdTj1c9xHKXsEk+0prZ0Bxl4PEuYVnQr
# DATA eY9oiPb6FJqIqKe8TipHiTH4DiUuKe9fRCCHRgucepZZJ6VGP5uK4cYycmB+9zQRDjEuee8pnW1vFHWTeDJgB4zCx4VBl93yeJ5y
# DATA ALrV6L6We+Izd0/AtsZYqcHrTHkUTsWMSDPp52GMjSxT0HxlA94kYKih1e1pgF7Ju4vMpKCjyUSBtxEEu+Rue1jYxlVGbwdyl13m
# DATA Hs5IoC8eI3c0+l3SzanyDuhtvDK+JnnvB7BrhFu8FxvVeVxlc4tKAmaxFLDGzlOpSyWfxqM4SeIDpe8t1Z9XyXXRcNX3JBPH2NcZ
# DATA z7rQgGEMuviuskO8WdqE4W6g6VRUGPgUZXldet5keX72jGGBZwGQMySLjqcgIaxFsUCVInyMQWrKQ9iATAbbsKQ2iUkDm3qpmIZ0
# DATA ex8n1NEUzDgo1QE4RMEE4EVPQobPo+ZRNo6kkJg8TZblHqryECR6isxsjIEZa0rxJJ1PpNhTJ5GCXpd6zitXiI/kqOTCbN4jjGjz
# DATA YJPbSGv1ukXtOMYwt9KrvM6JnF8oMaWwJvMyvzK/8pyv9eW19Is0K9P4LvY1vFwijSZjYQmzgBvRxb6NF0wecsmayjpFp2N1wmgp
# DATA F/tWXjrBvu/VDTP/wpuz4Tl98S/u7CdDXNLbenGcpDbf8p+Ofjj+WwApj/+RuZNfMuHyi+PfHf0PECWPvj36ZhFw+U9MsASe8gvv
# DATA 6Dv8wzDL746+Pf5bj9GXXxz/Pf35SgiXKmB6EWMtv6fAvzn6i6ZXMhiTbvsOlMtvjv+BfvuTQ1he/3nbI5lpJTGMJDaFsWgUz/YG
# DATA U2bkiMy0Gl6H0RTqGnKK2EzEZmNtu5AphVEvYHirDPhswaQycwMGBWZhwGdQ1/IrH/GOC+oLo6H3CVmMbEQ5kmU2h9O9wFVjLJcW
# DATA zOUBLbleptb8UVdTQR7lb0ZlNbc+UDUXw9tF0izJWGUhBbWGKXtNqElMHMlyg9K6cJDlXbW1akjN47B4EAyfZKQmMqvB2wH+RyUL
# DATA tm43wHEjGmUTyLMpvE7QwwhhoFHjMCQjHwvwVC8PeW6gKEg4Pz9ZIFmeUPNWmyXLmtOzIlqekAjHs3Rj/HnGeA2zPOvQ/lK4Zq9s
# DATA WL+cUX2jQf00Y/oVDOlSL5fkgBnQn2H7uQzC5ZKkejQPpU/MngvUMqkkF7Es8DpngGyPuhhnkWJO7rIo88Zn9XASCyhQ+qYO1s05
# DATA vgHHbZxD7W0Ct8w5uhEllQyj/cnubmz18w5ojo01YFE+SIUK6P08zUwoGfnJcsMu7z7FLIIhIGjCaMxrS4Z2CWsnkhcozzAKjRey
# DATA 7lpoSOVb7YU0Ro4iMhsOBiHHIvDYNOENdv3Q0S4d7dLRLi+RdrnJELPRlGYjm/iqzfuzWPfnNu4d8tIhLx3y0iEvHfLSIS8d8tIh
# DATA Lx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvrw3yslKrBfXGWZGXrbDd6T9HyMslK8+n
# DATA hV/WKl6t0fAo3zy/Wh765brnN8vv1potr9kaVloVr9qa41rSvZ1FHObIb1e9CmV03S+26O+2124Ua/Wi7xcrFH79V+/VfAq7VR82
# DATA qkW/3PRaTc+vNIt1uqVWrNLr28VKvVhtzpVJPWx2eot8wCpFu/mpXy8X62Wv0vK98rRWbXnl/Wbr7Vo1H0aj2+o1K4thtGpevVb+
# DATA tFgpN4stilSlVvQpLyhGdcS02GqeQNY0kVvg6PkteV03SjBb6nLxNzgSXpeL1peamwioMBffXr1Vq9XOQMvj+qtpedIULFpep1EP
# DATA q/4GtLxGL8zR8sJmr97uZLS8er8B29rQ8qqdWquS0fJazZrvh5dOy+NqX1xvGLB3f843TUWFs5efWwFo2yDHTpNEL+LcVL4u+v/w
# DATA h1r47ZPWEJYbO6vgb1YsT6bw2ZA9efB0kL3aImQvC+YUkD3tgFyZR3ZOqwxVGDtV/2yPUYXtNDYGzCC2YhuBHrvVAld5Nfsuy9eC
# DATA nVVrzIkTcsIQ7Rx8zsHnHHzOweccfM7B5xx8zsHnHHzOweccfM7B514i+BynDacRitrmoTS+tm5AYwSR5BDLDS3tTz1DH0NvMNy9
# DATA sz1c4DupFO/ojuw1CubpRzKt+aWHDzs3hvlKxjV/p/RJHI0pgA/pP/Chbhvz8sMtfew8i0tp+hT5+uHWGwsn0lUAN/BZk6LumR0K
# DATA OlQNftJsJacQ7g5WrzlY7Q5UvyQHqk+rF/5sD1qzXzJzpS3iiIY5Lcy9OO7hbLHHfkJzzJZJEghkjc72sz6f/TycUeS/L1irfdlB
# DATA 8otWbV9+Ln+pfvsGx+QzP63RDw9FoA6lrWUnVeUwGjOPQ4pCGo9CCMHw0VqpanwCXrnfmMgiuoH58+XZyfECZJDJ1swaO88ZoWcK
# DATA D3Dc78MxrQ80i+4hApeqxq+YP3x+GhHxhWoiB3KDzDp5NmI1z+I0q3neGVTOoFqiRpdVKCdY4wRrzmpHrbTXLkfIhvt03QzIkhLt
# DATA CtbAGMTTeC8JJgNLVPyZ6aZdAMCSxuU3lAyNNXqdUrNYjAEEcoGCxWrs14P5KJhw5lhj/jLl2wtRLf6A5b2lb6TaCIUU9HyXIFz8
# DATA Jmx1ftHYC59SPnrp+MLlg1m0+J1xOhsGU1EvP1TJO0BCJ9SJ9z3q74bDy5AtnrGm0lRzZ2asAT7XGi72vXVRnobEd88TEXo9ztHw
# DATA d7HvYvrjgzBJWYoJK1XMtxdZGGYbFYOIDPjZhBpkeMFq1M2sE52zoKk4A/BghQEiBvcFS0TPsSazaZkEmXdM0kNaK8gbHRrzQ3ob
# DATA g6PMAJC2orpZDsoU5TE5sOuPakKHmfqUDGhy4ihdIS3VBWBR60pZulRQBWJxKe8RBL7DscfglXGXCkrLT/UV9YDyvmAUsmLVO2tJ
# DATA Uyw8HWqtJJ4RJbNOByL5XC7MJEY1iYeML5ZxQDSOkhmEvDydaUbHS7k3Q3mBWewOlG7qZqjHF2f6YRkUbgLiJiALE5C8hemmIG4K
# DATA kp+CrJxYPGstTcXrYKbFIJgwbDjADMMWx05DpbunpSDnxCIZtaPVIRX6KJTJjKXzOLUFIDFWDg/AT5oJLmRe4lFa7IyaMvVdVAr7
# DATA 4RKlx03VNjm1kztv8tJmFu/OYTY7Yu5yZxYNe0aLT0WGHY2LbmN1eNQC0Gv0tqz2M7AKn5SFpSwg/WMGzzZXWEVgwKwY7tlkcVZ2
# DATA r9DQbSUlDwFX7zVbCGCVqs+vysYI9XLrDtOz2k+9GnMPmxl+WIPHGEvNRt3HtmWsHLnzt9MEVR1meIs/rb6zO4xGHY4oPqy+jzrm
# DATA GJuy6M778jG796ak7c4cplzbmrIab5uaGFHWGJq50sVmYGn26ox0ZjkHSc9MT3nzg0xUVT7m82EOzMU7qU13IDsLZGI749tr3pOR
# DATA ScZ8vE2mQjmyeudhxKymXsgwIWqtVfESjOJ0OjxU8Ev8BCvRSLHzWo3wuqLxVIbAUOQwsUsyHcRKTzQQ6LkWj2Wg+NhIzVLL5Wmx
# DATA dm8rKUwPlpmyDtVBravNwMYpMvADmhMP2XcfJV2aLmZZiDkqdQxAcdkdnZrlwFNC3cInaosO9WT3eJWAbWPeWwmzfRR38Aj1fqHU
# DATA aSqKJ6ksmikKGJfFRWSX1UpOmV/ttfllmpxk2M8g+UntYi80WQVvAt+TzyOD4JKMLHkf0JhZ8FglLyIj7FD5nxREjLpzocTJbhVx
# DATA h2nOPA0bjHELexeRVabjOWVGNddmlOrFJJvehh9HzPlobNUqfjVViAOKZcqOmCAZqtVT7ZuBEwHb4AJo1cpKF0+z8TO8f3uHmb8w
# DATA xBIg9uQLORfAMe7zuB1CUpfRFXzTM22T9VO0yXcBokOfRu2uSIkuCuTK1Db7MjU3odapjLRW3sIgPcTinibC0SNk84v0MOen2CIp
# DATA MF7WjPxZVjC/snkNezemIqYxchgespsgq2ND+iWzcJR3Vxx+NLulJsieuMxYQ4ZQD88OK72IqhZFxdqCOjBO5MSqjpK1Ii4o0AiT
# DATA qLs03/IDseytswdic0Wy4c77sd4Fp5Wn2QRTu9PgFFElqSjROr9LJzHEXhQHRMYSm4RToHltlNh/F5CYd/THo689xnqB/vWX4/90
# DATA 9PXRX46+XcSI/T9H3xx9Vzz6MwBgx78BgOxfgQs7/pKu/8vR9/T37+nvH47+cPSDd/yVhI6gvwV07OujPx//9ui746/o39/hTWCR
# DATA 0ZspjK8phK81mOwvR187mthzQIEey8oP9vF0lUp9RoGehPGE+Y0MWOehndqeGIi9GMrn7G3EQGO5pJUYLt+FPjoTVuc3UA8SiYQ8
# DATA O4/XUsXegrnE7PbxocOJ2T4U1RFcNU0sXyCXixGLxtYa7n1dS/Uviyyx8RSHAE0fi68y0oXJRfLEgqkgCgZBSsMpLFiydON+3+HE
# DATA Ni21C2eK3QuGXaw6hrIAdpgBqoMR77TnJZAhr5N4fUwlPObCsdyfWeUASXc0Cnnyi7GE1xGjX4VM3/B6UThdghE7sdKttk5ybenZ
# DATA McROTIHjiLnR/SJGd80TO/Wg/lIsilzVgH7B4/nGiyGnGs2vaDCXGmnnQbbd6tk3nctAidlpFcew2sExiOk5LD7kE4oUmFjqwsIi
# DATA 0ZqkvwMG+3CSClWJkzYN0idqrwoiEI1xcgzH+FSWbIYSA8BIhup98LoUrKmXkZ2k2siw3tU2AeBTMTbawSbA2lZEBsISu2AG3YVo
# DATA usweUNYAg49gB2D1Kn1CgZl4RHCOc22i+jXELm3sIZtNk0jKLB53w2ScOo6Y44g5jtglc8Q2Gmk2PIGxoXF8ZUb+2XyPF2DiO5qY
# DATA o4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiV0fmli3Xlkk
# DATA XW1KE+v3a2HrOaKJ2cvOp8WI+fWqV203Py1Wy0Wf8qdZLfr1xrBYA1bL/9T3q8W659cqnl+ueM1KsenhLtzht4ABy2ddr99uN/sL
# DATA hDEAvmrltlehd9SaXq1dbNOFitdqIMi6VwfGy/MRdhuvq7bzwdYbrV6rvwTMVS1bYK5Ku27AXH45Xx86tWYtXBJAvWYFULXIXq3F
# DATA KlFbRgarNE/7vJUv1WrTq1I+VOpeq0h/+f6oUvMpjzxkbpmzeHVC7FKkO2v1+qDebM2RzswDC6Szxhk4ZdwyDKeMG5nFKaN61GwG
# DATA G3DKgn41xynrV3rNbsPilLUb/WbGKeu1urVOLeOUVVqNaqN56ZyySTg9kVKG8UXftwHmy3KUVdlNVmrx8hiGtJ1FEpgJWWPOcjPd
# DATA Wv0nXp3+VOrsdMyhuSRHJQQV4c2caipVxrFWMdPdubdXauwLZDfenG0jnqc1CC+drkIufmuG8Nxt2gXmkF0O2eWQXQ7Z5ZBdDtnl
# DATA kF0O2eWQXQ7Z5ZBdDtn1kiG7lMVhcbh6wWG6+14wHZT6w5gmNjD7PtzCYSxK/U9h0txU1/h8FC7KV5pmwVClVsPW54dbdyc0wXsK
# DATA F2U4PKTcuIGgb1Cu9GciF8bHw/qWzpU6a8WrSCBlAamlD3MF6nAWNMgQpBy7CfiQNg6omDNYovfnKFvu2PFpjx2748Yv6nHjs+C1
# DATA rsExZHbfaX/XesqWCFiZeC89qryEr3VdDi8/V2f4LgO4lT9ufcGkrbnKcFbEluVIzQ6Rq5zOsCCQZxQBeaW6wtk1qN55kyf4rCun
# DATA dei4+kAodKz05uQgrKk+BwE90YkPcNo53JsNId+nZedGkBON+1DD780SrqBBMtLS9+pMPL9bR+Au2dYRGb+8bVZHQVPCKHv6WCTt
# DATA sBbnFH4ijzeniGWCpdYhpw16dtwWcKKyE+LFPbLJZknHCE++JEc9rTCcXeXsqjVibXblcrouTtfltAbVGtzW5ei9/M04PkD3L4oD
# DATA nWBPNNYguaEGNv/q5cQugK7FKxBqB4i+ltOG54k+Xf35GHoLoZJhMW4xb/vJ3s4cCWjM60AZaEcFYbop/T2HQ6JEU5cMPZlRxPK2
# DATA 5RL6bOpZZEuOGEfYy5n9uELOXvwQAPrYgi0TbHGlwX77xPjq57N+VV/IIFyt8rI42zHGdh07ymsizJ4SpjTBXZ3p2CCjToiretRE
# DATA VX/P4cLWxtNfE8s5gpJaX0JrVU4XUSPnqm5RklCp7rwqe01VPNUao63lm12S3iXalxTQ+KuYrTcliPNRoCxmk9W+beEjpU+vEC8B
# DATA mr3RB7wP15PdgLlBs1ZK+DQSFRce7tDjaBfUpzPqhaBVns729kL2QAMYwSsTqoOIE2AsAFViVWmMwhzoGICKoaZxCQONfeOq3UFA
# DATA hUz5GfvjqWigBwOF4GDPMGKhQAXjNJWRvBf1WTplKvpDrOzsqa28oYmPyNFDmoijsUSdKJMkYllleBoRGS+YUJ3DALcp2+kFMXZz
# DATA I5gzd525u9LcXTBtnMXrLN7VJuw1UTi8x+p70CzuY5CJxixjtpzvpPmymRRgEo4iRnQUVqnuvSlMwYXhhoXN9mZRDzjDbGCk0Ki9
# DATA 9mYAEPLwNm8C56EJCwKH5j4a1w3TVPueeKj/OXMCMJ4lMQ0dwVSPuWyHj6iBz2BCKTsg2EtCja9cHDKV/iGF1KOh2iQHrqqFgZOl
# DATA ASEuw56jkDXhvGCKCk0Rvm1T2zUZMnzK26PwjghQA8r1FTMCkXiL93l/k2Jwan7uRDO8sJFTQCFPw6QbYb9jDoIqGc4Fw6J9llCh
# DATA 8pKVvLfA2eJulL1pDO0awObiuxhgAmIl3HXvhlPuZzkZMG2C6Zy/DQfXTGQ9PtwA9sm6NN7VcpSmv9eJ/ACzNs3eUX0/VCYLormn
# DATA wUR4BOuPVNDDtMB0jNRQO7XRJWbS+wgMPeUhTDC10ZJHloSHpA4s7bAXdQMpQYXPRFYu1HQLcxY+pTFveLgule/zkWJjfjG+RKfz
# DATA Lu/0VIdEZkkBnmRWGB/p4ufpoyLlRICfKPN1DCU+Jf5pMdI4SXmlypL3KAyfMCUEblnmeSAv+VZVLbRiZY4vw/5T4YZAbREOYu0o
# DATA DlKe1AZ74ziN0gUyBxtiJ+l8P46pY+L8zLogbjWnJkWzT1uPQRfCibbc3KoxwL3NTuxLIEO/h+qr98FQcw1QdUX/XU9TLoESfS/n
# DATA LEebpfIWuuwlkKLfjaY8K0uo24IQpEAhFbOGe04RmLwEWPSDobwTHSSnNmtcPM3qXQIo+i51QLrFo5fqGX1dLlJ4i5LeBbOTX/T5
# DATA m8XFoaemqY3F+a+A4Bx9f/T18W+Ovj/+x6NvvOMvgKihr9/Q5W+Pf7dIxvknRt38M0Nt8ncf/YkpOR799OXR74++Of4HFcp/BheH
# DATA rv1w/Ld4gl71O/rlL/TCP3nHf5cj7VgwHYfGeQ7IwgxmM9q1wsiC5xdIj4JsQxUucJ+7rQNAuQ+URbUXsmLwEzicBSc81axEhozy
# DATA IAqG4N5wPQHn3TDo81sc/iY3x+T2ftX0G6swLg99I0nLukWuO32eh83fipHD3MhTvWRwOB2MLhJ3w5tsadozQI3v8YwAyD3eionb
# DATA HfbmxBK7cN4NJrlxB3NMrmfaY42dImo6zP3LMEhGamkqm3xGqbiiF/ZQi34627Yyl6DSol4M0zoyXeDgXsDfrK9/q42PrB09K+zN
# DATA +pg74o0btE8xaGuwzenG6pfDF3w14/RFDtMbjdKbD9KXP0ZL9TOJNgPy1bWFyyDVmPQIITmdT4jef5FtYmB7YhCPNAzGKhOZ6dKA
# DATA hsEu6HFCmYJuiBSpYix341kibIpsfNUJl6Ps9BLkFQe/GbdGTfFzY3BgnOt69Dbjdko39mbDUG+J5CUseBW9dBJ2ozAtmPhn7GLl
# DATA aB1G4noNqbMN+uH0MOcKVOlgnC5johkF3JVE5RPkADUOUOMANRcPqDl54NhozrGJ/Xo19vdZzO/zWt8ORuNgNA5G42A0DkbjYDQO
# DATA RuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A01wdGU62F1d5ZYTR+v/5cwWjMcvNp
# DATA STTVSsur1soDxs9Uap5fq75drVfy2dHtt8r1Rf5JjRJQrTV/4Veq8/yTWr1bay3jn3Ap5YOptttepVb593674lUqZfrT9Nr+p369
# DATA 5bU8v1nx/LpP76p6lXb104rfKPpVKkMQc2pFv0G3FOkb3VSjm3x6oPbvK216tOJVKYRq61MfXuSaV6N7qo1cumphq90oLwJiJEJF
# DATA MuGLvt8a+TXKF7yoUQaeZy6t3XavHXSXpVWhZ6gUIzI/FLumVq5n7Jpau2xV4Jp8OVxSm3vdsNHtn4EdwxXZsGO4TVjsmFqlGdSr
# DATA J7JjOv1ev5Fjx1B8Wt2OxY6pNtockLBjqJNoB6HFjqnXO9XapbNjhtQKToTHwGn0eXarobxYHBeVukXHHjv3KvRv6ye2ud1k8yEL
# DATA 8mQkjc2b4c12srd4WSyM66q0ZP2ULCwPS5VeQ/7kQvOURWOAMjyKmt4/R66RIp5LMYUJy8iryx/jGpVkt2Bc2f4c31rjUUE0KcN8
# DATA +qP+1RYmW688IK6k1WxQlvmsy8+xl2bEyoAc1MZBbRzUxkFtHNTGQW0c1MZBbRzUxkFtHNTGQW1eMqiNNgi1tM/WzmvrRjOG3+he
# DATA n09dqMcK6AOXdq2eSplVqXbvRLr32mWTeOc22vmHW/cyNS8cVrHkXMaUw0rTBdPXPLPGnHxw54bduWHr5Is7PexOD590enil1uSl
# DATA nCp+HTUXSnNZ4OZk8TPVn7gAvXRozeHNB2H4hE84Sps9o9ZcNrZcnNpcGA6VKndHVkkoQ7T6oHJ0X4LsnD5vrMBtEyrVXgLtOY/m
# DATA SOHw8BI0594Z41DzVHrYVCllw17uZwLVlyA+95hdXyqNZIKo3pzqBI0dRahf9y5Bd+6hHCWGD5BMOZVkAxe4lHJl7bn3cdY6MAJ0
# DATA aHkywsFkIfMSe6FmSXjB6nPKA2Ok4zNNxpwyQHa4VSfEnJqlDEMXMM31IJZEfSYKLxLwkFCdO6zPvVEpU9fsJYc6ozNUQzA8ALdw
# DATA FLKEPG7BQhUZGsNhyXs36pvmUADuYbjYFpWK6hhRSbwB/ZiEWLAaHsqT3L0cBKlERxOFlFot10FReUdjgzdXtKtpUoEl9n0VALUO
# DATA iqbUlwF8g4k6EQ+dTHq0T0PKKskAnSv6uD91k2OcfOdtBjSesBQAjdTzEj9zI9XDEMcB1SlumbTKHTLunCwb/5yfPHbISWe/Z/a7
# DATA s9hfOIv9tEjJZ6gDxIv5ZiF6PUfyzYjlzxUcBaLnY4/38q6BSF6xfNC1l9O4DD5kJnJ00XBIWw7qrGRIa5OCnjY9xLEqUx1k4sfC
# DATA KUp4qjJXkNjVIKWodjeC2Ph6Ig+DBoAtdBraeNcbzkbROJ7RFNHYRGOq5DFEbCbhcAhpd4yhA6W4TvbXuOT9rCNy+2SYYNM1tJQG
# DATA ZJIqzAHzbPTb7Wi8BQON7+LE6Fi8D7uIgqDYUeWlWmOZXWzy8fmRkLchHKbQUg9SllCXFqI1nkeQsE7WvZ/d0F7u3W9JC0rJvEx5
# DATA KbrkvRenU23/ibgQs390rG8jg6R9gb0E5Rvqr2EbQNieuhGq6iwbMh+TF10kxuoZnK3mbDV7ZHDO1pfX2bqaOfksJRzf48VKXZ+V
# DATA ABsfvbaglJDWYzjCPrTbpP1kzpsCuxEYMMlONO04LHkPMjFAnMIRlTaD9uEyZKdBYOkHsk+TfQf9qOulNN3vGs9Kh7eSZZqBorm4
# DATA oQYkp1gcH1njl7U+xGQcJInmCfHhErwHXp8lRqI647hIu1Tr3Kik/En5yZQnS/+YARHNFc5xYEdCDkeeVu6neDi0UrCUAGkWz7ma
# DATA yOdXZUuAerl1h+ko7adejbnDzNx3WH3GiDkc6qXRCP7QWFlz87eT3cCtKj5Yfc8emz2MzOJPq+/ssJ3GGtmJWCn6zpuSqiwfZDzW
# DATA 3kJZgbb9fBga1rgK19qMluczSHrGCc8L/uKOVzlo5cAcSIp3BpvWL0vpXIWSGefEXZOA+RhLXk7YYLsHEccogZAp6n1mtsJeKypN
# DATA zoJIjBYxM9MapDSMjeJeyH78KexZGH7aghOUku1MhAPSSHWGLDSkjeyp9ysacEu2f3VDX6pntsmxpZFPiskaLWEGwCuWu7kR0TOW
# DATA 03Xelj1V8WSV75Ql9Gh1CelqLIX0aMI+2HwJUTPmjkQ87sC+QCtzQPaPuEEDT+q6svotdqBZA8HzsgoiUqsx1Ecx5UDpYgejslLO
# DATA XzZ2Cq5/wTzYtGAeBMmQRWWD4UgXzKO4zzDWMY1qrJl6gEkejaB7+blZybu7H0eYGVPeG7d+wXZ9c6lMqH/B5KynZomYHp67POyI
# DATA X1l5ZH3vKcvj360uD92LS3n8OzJYFjqyWbc7G7KaLBYB1UlC1Tj0ZFWx9KiX4pUEnMemIaPkvU2t67BARUhmSBwNReV4xL1YPBqJ
# DATA /DMZFyNhidFPEXLQrBefv6CyFF3/Ynq4aTE9nHU68/3Z6yxirXqzcPxJfJj1YFqMq+R9ENF0tzejjn5PlqKMfLJeFcosPDC1Ka+6
# DATA wUzoeOcuCzva178Te3PTTuz1KOnxjoExHEDUOMZW4xmI4vVgNop6RSwUssS4Kg8edVI27CEtNIVl/kGgudTZOr/N20MJm96OQiLj
# DATA SW2bgBYy3EPnLqfFBJ2ptPL2n2xjtO0/c0Xy/s77sd5wqDW4xeQXi5uX/hlqGdCMBdmhS1ktnF4OE+259nhlLLR0EIc5FNr/dfTP
# DATA x18d/f74t2CVAWNGn788+uboX46+p79/z3i0P3kMO/v26M/Hv10Eo/1Xxqh9ffRnevYPHv3FAR59W6AQj/5I3xh9Rv/74egb8xKb
# DATA pEY3/eXoG3xSHLV/ARUN75f3/nD0r8f/6KhozwGU22xz4C2v8fRAY1cNmRvixUJeLfDMiLdZhTDxNAsA0FC4E1hGhjoAgTOgA52A
# DATA bqCIrlSPkynvGcNzfVnCMk4BeDrWktOgLI+mIHa+w6fZvj7uIq6anjZfIJeHUKPRIhjGexnii3cY8svnOdw3+1HWTb8ZTS18x8Ux
# DATA 1GBKq3MbqKGxjOCcDQ6fdnJpXTg/7T3BgHsdMi6wo4vm/QMad8z0sqCNrDTGYShkJAxZJBPdndrTivmNIo0/hUpKmHVOrPNVIJtK
# DATA liOTkD2LTJjVxwRGVESC18BgNV1gq62vl6uNmLlW9qwAa+uj7wBrbvy/4PFfQ9jOMOy/FMt7VzPkX/iIv9GAf4rx/vKHe6mI+aSb
# DATA Uf56NZ/L4LblE86DJGeIgY6ZVHcOEVJBzjAmM3mVxHUqQKd0FGDhyyy9edIvdcIULq0wwdIkJ5oG6uzYgopeL+obthsl+9BTJJMN
# DATA mW2JMtd4Ww2OrJBBwX6JsPsEY5NCk3EdE+4VnxrmnUBCm4tS3kOVToXGxUuzYToVUwH5klkOtxXFDPSs6YxCGAXjWR+fE9tIUJ5X
# DATA +AnYpkkOi/HYIdscss0h2y4R2bbB6LLRRGcTk/gK7fqzmPXnteoduM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4
# DATA zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbrg24za9Xu9XyWcFt9X4j7D9H4Lb8mvNp6W1kq3rVWuvTRr1YbXitatGv
# DATA Vob0T6XiteqeX6Zfqp5foU+NYqU6bLS9esNrl71K89Nqja561bpXq7zt++1Pi61itelV/GJ9LkvDdr/S68xBz/xmrVGtLYOetRdL
# DATA rlL2auX6oN6s7Fcbb9PX/AtMWHkKW4VSUGnUvaZf9FujYq3p1Vpes1z0m/Sl5tUaXqNFXzaOmF9diFndBySu+WmxSoVaRF403qMA
# DATA ENthlS7kaHG8kzP/srDfbKzA3KkK3I0SPmH3VCp9JUO/+U0GybGqQSPfAkywFAAMG0+eLiNrPXm41cpX+36fv+v+l+VQWfy12qJ6
# DATA Q2GcEhvHzUhj46RFWti4sN6q1et5bBzdVKs0cti4OZCcYOPavXaGjat1G/V6M8PG9brdTj/DxrV71XY5vHRsHNrfydi4qjYKxCTQ
# DATA z6zgxyGZc/7F+k+8Gv2p0p9G/Sd2EHO8uHdGNJWYFrAVGPH13mfFDvpqx9yeJtXL5dvzzjxx9xRa+wcFXiVbsSKmogF41eSzTZcK
# DATA SjUrL7xqkg/G0/spcgaJmS9hV7V28WkvZ55ppzKpQn/8ujb52VcUTcnC6uZAdtqHTf1yZQE/V17NlzO5X7BzYI0pckIC2UpwHDnH
# DATA kXMcOceRcxw5x5FzHDnHkXMcOceRcxw5x5F7yThyyuLIdwDRmMLfhb334Za0OUr4DfkORRjOBjYxP9x6HCRQoeVHPLkZzesGX6Bq
# DATA 8SY20237OzcoN7qj0of03/iudUr8/s/zx/D44feC6aDEM/RtDuenfqmOELLjfUsOjWfKt5DiMt2+Rs1lx1bcIWp3iHqTQ9T20SZ3
# DATA ltqdpV6jl/xsz1jL0eCCPuu75KT1Q3MuUOpIIa+sZg71yoFVJcjCZ4lhRx8oHWY5yRuyyn52eHISHGIyLYcnobUytk5ObqyB/Kao
# DATA HneEEdUDgQqvDkyHjo7A6R5vonvcDdJZoGTT8Gn1nehSKWtx6wfycfW91MH24pgz+mfy8XlQQM7y4pQiiPdWiyDqXBURRDLKksMe
# DATA dIiC8X6QZgqIODlJzQsK4t2Y3SazyQTnnrHRAIfRvERkIVPgOeQwO3vBqKmFJY9adYSjw3M6Ojwe9pLDghcG6SE3lPPrHs6l4cok
# DATA Kq36d3GKoaYmK51q2A7JDGZkVjbdWTqgmhuySC7OoMsR6kDkqtnMyYwIWJWwSwTDgIIagHuHLiJTplZ6Dnw8fIb6AX9pRzNPzqVO
# DATA nSXgOSiYDzYumIdU1YtwqxxCA9xSDuWDzQUqkUnIrYebjW4gDJJBwVF/hIajdUNxjhCKVVAMDydsGyLDLTUNERzA2paMb9FwEM9Y
# DATA evT8+q65pFxZKZ25c3t3087tvQg7Z6DhMUssZWSaoNCcD7sCp/FEN51+lIwgTjqbeKpg4oQl2PhXUS85oEQlcUe6uyTEV9YNm40H
# DATA ZFRB3cCW8ThPkeRifmUlYg2SpyySx6uLxAy3UiaPkyAail5KQGaNKRT6PoVxAvstlhzu0bQHRh6qpqFhJoFqDkqzGjBhrTSTKUlk
# DATA Ym8iwjI8FLW3cxdMPvrXv6082rStfCBzUpqgRhOqwqZgULthOdPUXbYIwbDmYZyno1D1mKQ83mOaDx4tNuYqZFYqmuFKJHzKotYo
# DATA XXhOz10UczF+ebWOXwQ5Ef24824579Ym3i27ijnvlvNubezFWukEuxzvFgtvGQBe4O3FsYjiad/WtdWvXef7wpEGz/aALTi1hG6K
# DATA DSNqH7K+lvM2qeUZRjONsf+eJ6pqoXS7O9pRbi/dMGVSilKUUM3zpivLrhjXT4V31yboudGLjSI2kCq8rXoU8JZXvZE3nPDW65K/
# DATA 2kHGK0io5bEq14lRLcv7ydSNJmb6wQXXlK8IvbB7erc83+uOVvux/FKdHQgUWBQmdHepnrt/wZelLCzjKJRNNxTEfS1fONfLWmYS
# DATA yo+iwIeLdKpk95VtumSXpIlHYp5NaDycyob0mxLEOQ0gMVIwGFntzVazfJyI+1WIsegHFlSih6zXONZe2oLMGNiGY69IsBdEsusK
# DATA W+IFI0Wzh5JnIHdZPS15XGgFHvwsIAuLV2ZBQq8y1dYxXgdrahKNBWOFMMkiNhKEWFBkBTUcGoOkY+dQmqcI8wVQoLRXEdPZHvi1
# DATA vFMgW8NU09axlqBkvcpMdnLGFuqhZ7YL6D1xE7ZhNF4WWf3CG57ZUONMT2d6bmJ6OlvzxbU1V1qH11Ctmk90mNMFi2bY0DJD34LZ
# DATA ybEChTwJZZkw1VZo9hDLLnHne/3Ura+/5Cv/Led07rxKPeh8w9LHAhGuOcLVkhN+1plFuRAM+du8CPf8cT1ppt0YkwV51+G4K+a3
# DATA 0b+687OF0368g48KcUHc3HqKv3BaNhAWz46taHtsDg5+EBzy9AV6zsYwu8dLdjI5GptFQfgT9yikyaEsL8rcCTTCSbDPc5eS95CX
# DATA s6baglL3KPsMtRIuY3HGscEzv9YVYD2crDRN69ioEsxXpvtPJ0OEmkZPsXVdliGlel853OPKjacMU0YVaj8c7s2ou7BhZf90/NXx
# DATA bxhLBoLYt/z5z0CXMTbsDyCK4ZfjrxYpZf+7+fHLo++OvgWK7F/5wh+Ovzr6My4VvKM/Hn3NKLLf4Dtu4Ncd/z39AYjs9/Q6gMy+
# DATA pZ+/ZpTZdxTA9/jt+AsK5jvAyo6/8CiMr+nC3+Mi0GiOXfZcWIdIG0+94A9huXJde2+BSBokT7DKF4zDAtweNCtNeO44CWT6g0GG
# DATA Zqg4Ks1rSNDL8GZjDoy1yWfRkNmo1KID3s1JE8tgKpDUEFv1qTNbSy0TmHQoA6WDltm2otVhXDW6bK5ULo9c1ovkHGZq7nxDXeGK
# DATA ukAvw7hn7qRKJzUxuWB4Gc/zo5Q3IKA58M4wHVVHMNus1C6cYqY7m37EzwVDcSql3UHYm8k2kaGw4yH5wSBn7sU8Vnv1/HpxFI1h
# DATA awdDqtzYR3Jbe3oZnSFWWBJSwAJSiMbogsUMVJaRtMmhwTdvWjVXmzj5pvas8GVrI+/oZc4CuDALQHPLTj/wvxQOoqsc9C96zN9o
# DATA yD/liH/pA77Ux1zibXrZtWg+l8Ety6XYC2WOnopHiincXtzP79vjbJgOKJZ7vG6CRhdhn6axjBhxNAomnHB5LfooOTdAtRPUJSy1
# DATA aGSS7NfkEVfqvWfE2dINsWWcc6pSeJQdM7xOBnwAQcRddqANAyqCFLH0ejjwg5c/GccHcjqipzaXAhs1CbmoB/EsAfuLGVRRJxoi
# DATA q2DdMWiFxiPGTcFYEA0ExnOZMwQK5DSOl8OnHMfMccwcx+wSOWYbjjQbTXk2sI+vzsQ/i4V/TgPfgcwcyMyBzBzIzIHMHMjMgcwc
# DATA yMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzI7NqAzCqtWr1ZOSvIrN8P+uXnCGSWW3E+
# DATA LcesQXlSrg0ajdZ+tV17uzGPIKuEjW5/MSfLPmVlbVBvNflzFZAx9blGGcufWy3Ppxyu1sojv1Uu0r/qs68/z0G9KOd7/coyqFel
# DATA tRCFSp2iUK586jfLnu8DweZV/PLUh9u4dRI+rFkPmt2lb6o3FnBofrMOLplXrRTbNc9v1ABB8+uUcX6VyW+19gmv61YbneW0Mgui
# DATA VsR0IIBAv9Ror70EZEZxyUBmFCkDMhMcW9YCatV+s7Jx/jaWvKpSbmavqvr+Jb6qKkQ2eVWl0bzEV9Urdqpa5Ut8VYNRdDpV1QvO
# DATA wFNB5bhL01A56R0tqFyt0qi2enmo3DxCbilULvTDZq+eQeXqvUbYqhqoXLfRDbsWVK5K7201Lh0qJ7sLi7LMoIe5Ks8gPL06ZWyX
# DATA lph/9jPzULi3QurMo6CwSH+rLaO/wf/Z3D8oNMT/qUIeBZtB3krNdW5NPT3LAp1fILHNe10+C55NVTK5cFjcYoXr6687LerAenmn
# DATA 1+nsMI/dtViqWg2Gs7JqjT23EOf8tOgSrUPHmHOMOceYc4w5x5hzjDnHmHOMOceYc4w5x5hzjLmXjDGHuhBNaYafBNBipwp222Dn
# DATA du98ZuYkk3SX64n0Unx+GVc/slq+NPzdO6bZR/3tH/GjquHufKa4dFq5CGKocuaLEUcT7qrFuLz9uby6N5O15107oJ8K7g6XMgQe
# DATA c+lkSce+t+jv/NSv3/DriI4O7Y4E0JnRfBGFamLGcrOsQDsOw14K3p1+BpA8kSFIjfZSPzyQDmQip/JE7Isu8QnGXHKQ0TjFuKvN
# DATA +gQvlqySxadtntDtlGTxYXs7KOwXIiqE4IYytPd3frodUdMov9Yo3/J3CmVs+uJWj/Wn3dHune3RnV2/Viu/9uHW+1Ql+Yglh4oM
# DATA UoYP51N/GNOcdXSzUd75SaW2QzOwHutZbVcKH26VcTc/pp8Z/YRuXLzpdlZzJMtRA7ZTjrWqOnAe7XL8tpF6Rg3+2xf/BRmb3saV
# DATA G7vLCnM7ejVfiK/59VtlnZsc6u3Pd0qfxNGYnmVwoURafbyx5JX9aBylAyWK6td1YeK0rDhcBID48zFUJgQHgOcZerg9V2GKulbs
# DATA 2NWCGg/XI5MtOxTJ21zgVBJFPaug519bZzJyy0PjycL5DOMgGUPq0LFWztDiFjpkzVbUlc7MuyhwfR66NH2KfsaKo4T9SIepH6IB
# DATA F2EZTKM+iOaUIpxSxHqlCOuYotOLcHoRp9aLWKlTeik6Eg9m06wB8K4trekpI7sRlbiOMkZXoWMvxorIuCdixcwp1+NSpluv7zed
# DATA l7lghN7L7VtqwVwJ16/Qo1cDLivST3GynHlIRth7W428Jynpm2BMlLIrmZJ+rbxMSr9qS+k3K2VbS9+vr5bStwwaRJ8jThMTmlVx
# DATA tcrL6edutvLNDmJBLZ9jdqda1vbHal39GsezVj/5zgaH2VgS5oL2vj7ASOnmg4h3lFEszCC0HLpVflE5kzGhMGngNOXLTTs+5jMh
# DATA V07vZeMZD4UyAbljXZ4rkIt57UOMm9zi7bdmVy/npXLw0aOBNqFuIvfm/E8Z3jMrl5V0BOnJFCbg+UUivAv/nkjdKGNFW/K2cobR
# DATA mOnRhM6y+3OdPJtBEP7I3aIEeKkKs/YMJGdYT4PhBizmoBkEqzRo8qIzNhVskf+1nBMmGZibP2Ak1CsU7NvSQ5ANATuRb/D8i1vk
# DATA LQw3L3HzkhPmJTn7001N3NTk5BnHM5W4wxiPCq4jgcwZZip3b5qJiAAPWPPJtDUqvSBlkSsITrHmmBGhKohy2igQx6URQtNiDfOT
# DATA izn0ArbZ2Nhv4dHaBpjwNT8Q4blQCLNwlaJ9U2KoQqdmSsOMLsqe9NMZornHv83SQxpzx8z0ogRKZ1FQECKZHumBloH03F2kT3Sg
# DATA k0E8jfeSYMJD9SSEIa3kfaOEpcckiflhbxowVvm9OBFlXTXWzcNNBZFsWX6SWjFHLBwad2To2w4UBhnbBFXHJr57rE4dAEUOfbi7
# DATA wk8TrMQgsPGi8JCDMMBSa/DtrYt91GOrbm3k541HSYFBCghEODUEYaj4Tw3oucuCcAp/oTWJM2U9YdnmtfdUsXTQZQufwOq1A6m/
# DATA a9J0FzvsxzHIrfPJEjMhz41dUFU0FZnMwgdw76s3I1/JbBuA4KuQDZIF/AOAvYg81pK7LNsGo6aASjSWpIB5B+9tPEtVfqiAI8qH
# DATA u/tx1GNJalZpA0BBspQGqJiJsSNIrU34pBvvTlk+pedY/43QRJQDXCZlOs5YUM8JV8d9mYVBh240invSuFF4fNmUlacPz8X9Pnzq
# DATA uuy0hrWUYcGbzDpkoVjPsf4cN8KgBwvIS7gOS2WlsYvhxfxKDyR2GnTI0k6pTa5L4iOgwRXca4pBxEoiCGXyQuoZImh7UXdHaZ3Q
# DATA 8/3ZcHioeCsqpuzGSbmiSrpHOVIhKwtKn3AwiJU6InWQ2AlKRZwM0A6lwNDHzyNqxTB98expRwtztvTGatDOdH6hTefTssKesTq0
# DATA ved/PSzsMUYCDbtko0rq+3pa2PVRk34uJFVPIkhk+/41y+sioWJ5heyLZorNK44vRYop9xureaNQeRcaGUFSI1Ixa+Kh7Q4NJ7oT
# DATA u/M+a5cIV4ymKqxPLJMmeh/9jnvejDLLGb0HJLPHsMuFRkb1JrtXZiawaWV3egwLL4IU2aG66WY8XNU8xV6GnYvqy1OLYJmDcS0m
# DATA BK5YQ3Je0B+HBcYyxJMENToNTTMTBefATFdlmw0Z9iPcRXZuzttKNjdEi20tdLa0eQopOTVjUXJt4C6ssy3Yei+alZdhzQ7CjhK/
# DATA tqlm/9vRN0f/XDz+26MfmDL27dH3R39guhh9Ov6Px18cfW0Txo6/wpVFwNn/jctHv6eHv2FE2TceffmaLn5Ll78Hmezo9x7f80dm
# DATA nP2D3Hf8OwUy+xokNXrBV/Tv7xTIjOPzNeJ0/HdgoDHv7A9HP9APdP+fHNvsebFlpZGj4WnxdV6yMuRNrAPRHE7UxXnyFlNwU7R6
# DATA xJFa+c+hssgMefEexfvs5QmSzKtkkRDRPNaizN6ej4bDmdk2bdZRXDXNbEnBXB7RTHwq6cLL1fX522UHgbn7YZjSCNSVAZsL6YLR
# DATA ZuJeEj1/uFZk4Y+pBQ5stlHhXTjX7K5n6Z1nMwNTA3jRGEI6syFTODqH+BunKZR7DtQTiaDYOfce/JzuF03zguZU6P0uBmLC9s8+
# DATA 4MUeXRwu8Mw2rJmrbZzFZves6GYbJsVxzpw1cFZrQGPNzmYEvBROrSs0AC5j/N9o+D/d6H+Fg7/Uz4WcsFBnz6QFXQbZbCGRTDej
# DATA rEoXowXGmSwre1Q9UVNvCeip4L39+PGDRwV1sFStDHPJ8J7RhOwHXtnhZGCEhlMioyklqiy150HnqR5zN8WbmargUV5DGSxvACBl
# DATA UReYs8wIyAPOJknYg28kbxTYxkCBmyk6Cw8GxrirzAO2CsChEvNQkFMc/5Rek9HN2KmSHqZ8lFLd03F8M8c3c3yzS+WbbTbWbDTx
# DATA OZWBfLUW/1kM/guz9x32zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2
# DATA zGHPHPbMYc+uD/asXWs3GmfFnlX7zX7nOcKeLaw/b4Q+48xVmceUMKFt1Sq5w2J+o5LP9aqwnCTbW7mM67XCetifwzdVW/W6oLrm
# DATA 8U01yWIrHvJuiYewr7J4VOcPrVWyaNTmsXXLeGENixfmt1uGQZUjpP11rdfym9XFmtOqUdVpDaTOWckLGp12N1jKT1uXvIqQ0i4p
# DATA eRWL5rVx8uihC0teVRhfl5S8qnr6VMmjh86VvGqlci0aSbXaurxGUm3452gk1Vb53I3ETt6FN5Jc8k7dSJC88zYSO3kX3khyyTt1
# DATA I0HyzttI6n7rWjSSerV2eY2EYnGORlJvNs7dSOzkXXgjySXv1I0EyTtvI7GTd+GNJJe8UzcSJO9sjcQGtpZbXq1e3681BtV2bb9Y
# DATA a4yKfrvh1Rr71ZMAqqsbwVlomGzpGhomG80WDbPaaVRa9bPQMMth0PctGma1EbZqhobZ6XZ7va5Fw/Tr8vPl0jDVZl6Z3VnOHrXs
# DATA ZviYPGEnE912qrV5jX3JtolcqJi/Lt4zv1VhccmsxUtmpRa2ysiiWS5UtWC+NuQGr57lH9OzwOWbDbO7aTa5lwSj3BrdSclVzyxZ
# DATA nl+8Qa/UL+T54t2ZF3HVDkl5kS9FJK6AhUCw1LCI+lTVLr9c0G634YE5HbyTPUZLUsVuwwXf8+J2oZXcT0frdLROR+t0tE5H63S0
# DATA TkfrdLROR+t0tE5H63S0TkfrvABa5yKacy/qKIAiVudgeio4pmZQ0ZWbfrnWqjcbt3NzFvUYHx7GYxpxSIb5bIIrN3w8WandVmzM
# DATA ++oYO/QDxtPB8NBwrhiRSDGhevUm9vdvVxiL+Fb0uiAV38U5czmlPBnOUg+CzZ56ET+rorTq+btepf4T87ZMaEfmpZQH+yGjOrcp
# DATA Dj/FGv/OspBslqF1ztQJwjhBmJwgzOKhY6cO49Rhzq4Os1JJ+TJVY3RnDTkIaS8oLlZywEYb3nljSchcHx2zqwAaylDJoA8ZyFiF
# DATA g6+eABLUT+a6+TSHbIMbYSlI0Lc4gnxTWd9pcIKraYJmOAdLUH1G2CxYMsGgqJPgbf9N9PpJQEQrOJMU+5pJTf3ktFROkQyxNtAD
# DATA wCsqJsH2eyfHVz9nImsuWDHdLNM3jKm2g7idQigRkiOZ3UJd1yQKT6ouWSAZeDK7ZKLePCnmjTWxXgn5M12AnjLxeKgK+bmH/i0j
# DATA /RkLMTS9H3omqmPC8uDm0TPyOrANuEiDEc8BeHmGBWHUXLNLkypWi2aoCfZG0vSm4B0MqPKRcZjshVZoKnf7feprO7MEvg08R5Or
# DATA JIRCUzTVAj/KXy0zj5RluVmJiarUoRjIrINp17OSdy8esVuMur6CEusZ94z+Uya6pCZzPXkiSJQuUmbLZJDZEcVrlrBvVYkPbUAN
# DATA fNGUYhzzxE0EVkwEnM3/Utj8pyWdXBelSHunxHrkyVsRj5iilsjr0RCJG7NqD7WtUbiWffLs5CWfL3W1k9Sl5/Z4XAb4ZFFA86Lh
# DATA J8t0SJcCUHJlp7fESEVeBvh7E/a8NhGW3sGqnmvveF1Ma2NonFLuW5H/GFcZseAgQCKi8RlMpcyVubkJDvNRNu3WeMW3H7/3bsG7
# DATA 9+hRQY3D0l54WFBa7oBYyrxIhBYnUAkNtJIqKzVSKRjZzyjN5g0abMcNPJpi2F5DVHwknYFseFsPi7xrRUJVYp2iu1ACHSt5VI4d
# DATA J4gS1gtB8wvHXSiCjkOKn9JjLVDtpeo60MtsIs+aV2Vdi+bMdyAnRF0Lzoo1raOtYIpscKsDhqH4MwRGCrNftO/ZgE4OlSSmimXJ
# DATA e6A5NYg5r47pjizw+kE0nCXraJYPJRgsXK3iWb5EFrjdXzsb3NngS21wVUmcJ9554nPW3Urj/frot3Odxkid4ZwDTzyFxgMvvpoo
# DATA xca9mAfJvPi4dqHP089mE+AES94vsEf80CBa6I7erAsRmRHGYiNtbPztTDRme2djIfdMt0CaJ77eeVUbfo9wzJsbNvQrUgXAlhmH
# DATA 6gtevWmsxKn03tMEH0WYG6/qirOe7I0kpjGYGvZg6Q0/lzG9D2rzils+gMmGVIoWN4tN49abeOdN/X4ZjOajoQxVZcAZi4ff1Lvz
# DATA htqcyDW44GFY6VPfH1OZMfaTqtq0x3eqMaLgyWBc0FLb4NwBU5wOJNyeitaKeLwXjKlO9Wxb0ETmbiaBP/e7RME23Yz9RSWahBDv
# DATA 5sUDbXmdHJFfRMl0BkV1lhK34qAKmM08rq0sKc99ShIPTWR+NmFFFXMDVfJwyirpEx48KYOGQ13VUys+N1VB3VSVbgWXfj32+5G2
# DATA 87K8F5Mv6I1o0NeznIzto5XEFak9HcSzYY/bpZizY1h+2HiOqZWoq0sBlzy2L8kCHsaHIw6C7HPwrAOIw1sy9GDRfxJ3eOBUEvOz
# DATA MbMQVUjrgODj+EDplWvTOZgOdPQ/SFjOnuq9x+Im4uzm9RbtN2anM1njFEygvc3opaiz43vwAzNSMxsXSChAFvXtPDECqX4MBzsN
# DATA 5+FY39tTrMdsbXBdYt4TV7RKTyDi+fCrG/e+8qwjYno9I+MqDMLhRPVnsuBp9UUsg08DZZyDKkzC4AlKWHpM1D2sWfbCEV5gz7AU
# DATA WIFCkfkgY+HRCuypmbJjbPC5Wf9E/YxGGzLEXyzb/vPPP/r8w/HWK3/1ov9HWR8OP0aHEY1ngKpODi/8HVi7bNRqf6XWjef+9cv1
# DATA euWvytl/f1X2/Wa58Vde+SoyYIY2R6//q5fzvx//+McPZ0KI6FIHEvV4nEGl2Ep5L3KRsR9ZBfHuvfsO9Rq8zEntOx72eAmfHihR
# DATA WK+IVArZtnt82EZ//4TsQ/05Tl/h0Qud/jDqeOryA/qqb0nMg+mso/wz+gqOZGE40N9nZLq88soHD+8+eHD/ITZQb21tvcJnbF5R
# DATA Gyz7sq+anU3bNJnshbf66dYO72bEyZAtMPhuUq94E1Tfm91hRDOYrduvyFbrflpCPsDN9+hw3N3GQwVvi+brrS1rB+oWO4WKCL2Y
# DATA 5dbWzo72L5XCp9F029+5/cr8vs981Pgc2cfqIXoD9Y4HY35zFlDYRW4VvF+qyCx/90eFVzzP+2wqp0hu+bzdoTAKnr4+62Pvo9+o
# DATA tmqFJ2RlPor2xsHw1tajd976m3fefXerkE57UXzrl1t0nYaHrcLWJJrgH/X9o893VPaojalhktDQ8+tf642qKQdoX+DFctn4ujpL
# DATA ZA/xbu60ln6+h7FgGqtjFSr/dTT4wde4oA75JTgYhdf/SA4PlaL0UdAP3yG7aA+HFHB7Cfl1DyvZO7hz7pr3qldedvkOn7ZZmgZ9
# DATA RcX1AIbMtorv/Bvp/uzU1nxQ3uevoBK/8gpNoeGm/JjpRtvROJ3QKPyxFDpP/nduoYiRBbyCjkuwAfhDia2JFFOo7a3i1g5+GIbj
# DATA bXmQElL3K7iGJ5OwhP0EvI14O9n65d3i/xIUf1Uutj8u3bz1PxU/urGVfyH+SwJM5X6BhN1H8W9vvTPex2kfqyfhZ7Z2+Bk1EO9y
# DATA S88lZkcnQm7hyrJNNX/6MU7qUkxr3k89bOhV/6yPA4frhU+7ZOumMpFUMYC9mfTQG6A/KvHuh231TlSdj7G/entnJ5enKcV0Goy7
# DATA qIr8eMHD6QGTnerqDlU7z98od9RUV2FMw0TFTl/f1fH8Zfkj+UHfiD3fchMfStx6p0fFsqUeD8f7URKPR2pvuH0fTef60R7d+9nn
# DATA O3Ll/nhfjgTZSZ2vBEGxTzXgo88atc/pZhOLHV1prKyxXj6XPdYvO6rxnCeTcBpaDrjwV0zWpdOIxnYOZK9YLEa+v4CjtxzJLbLz
# DATA 8LQEwxeS+QtPy+W5S7tbas+KXMvetzxZPx+nswmGK5pdWNFUicJ/fNrzY0qZ9BS8Y3CbXlPw/J35xCxvrR9/ZDXbj35KT+LU6kkx
# DATA 0xluVx96zooZZ3mJhsdw3FMHUE17nY22Uci4pUSTDere+Jwfyh7rEJQ9/DRKvlJvbNB871vRWNaE/xprS3BseCPF8Xoj7j7B6Rr8
# DATA Q5WPHkwOefpUkPlyl+sjTjKg4NApC0yPTP+SChI7sKjvVbQ82DKY0zK9Ty0S3Rb6GVxSeuYPHzRLhmK6mA4C7L+S5mp6v12K7Djk
# DATA i+LIUqZL6XEI2yVIDt9gYcE4OWRhu+jp7ha9eBx0ZzhQbkZydN40Ve3pm7MMpFL7WFkx3KuaW3a8m96WXdPMI9pnHqM7idMSCGHb
# DATA OpwCrvzs4w8e/uz9d/+D92v5du/h/buP9Zf7//O9dwteOQbSw4TJqaOf+z0OLXsFdU8HEnlqbmEwytdGuaYGSrTD0idUcNuqytzg
# DATA ppm9ZGonnDNa8dR2LSuxRAW2/cvcbfhvq8e1BN2lPIVPRXHv4qPJ9VKW67s47AXrsoS/ajQgDcKnhcWgi0VVJTh03V/dwtPmG7/N
# DATA mNPycppmF3tJPNm9C4trWbipXqIh+3R3HNN7DoqY+UYAyaQSCpVcESW3xT2aKcidpQEillRF8KS2eXUoutXgO8wUPeDjZ3xRBnY+
# DATA 2I8KcBZMZ0n4sWyh3H2czNTBa/1RrM/darkg66Z8fSdfkFaLUYWqjSj4qSbb+ds3G650mHM94MoWulk3yZaYF7FPbGr3kmJfKIt+
# DATA vj5a1Y+NMsn0YDoNugM7rh8tltqy/zbNc39tpquTeXkDe/P8/rD3mV+oi2XANjTszvF0W31TdvKtU+StNcmUSC1kL8sBZC8xv/ax
# DATA 5WM41z1QtE3GLkZjTRElIykfGsa6Yb54PMmmXevpN+7/4v2fv/vuiSVHT9IsadmTWXnVdXG9CQGHHTUDwEi0raoxT4rQc+sZdulu
# DATA ssde/Qf8iyo6uQ1n+T4O1O80Bygqo5vSpPdeWBVj1TNswi99gm6DLaYe5H/waKoikeuw+dzGdjaZwX0lFZ+CJ994gqGs2afAcHr3
# DATA +R8IsZqA/lqN+DffeN3jaWfKaFDV1doO65L3MwzagcfoHg+7l8bwUnY9Gp+CCRk1c4bII3bu38csbOv9GPu4sxrZNT70Dl/vR8ko
# DATA 7G2hjKiiffwxzIGPyX7b9bY+/hgl9vHHWxJpKb5r6kpMcIp9FF6G228z/1+lVq7V/Tn/H7yCzv93Ff/99Y9uztLkZica3yTTwZsc
# DATA TgfxuPrKj3/8YxbuEF4tFl9kYQxrDFjxxXJFPAk19FZv4HqozSiPZ1vDIXULa7yCWKZo1PQ37GnSnwdBCt+g/hpBHyyxnIBn9yfK
# DATA CqL5OphNo6H5xnMI8y0drvFCBonthJx3Sk4HiRDwzAVqZDmPJUd5lgwpxtJz6njTNZ78UcfCiyeezN5nktcyZGajpxoWKJPv2h0c
# DATA TGqa83idQy4XUxpsqWMZJQk/CdX6HzJEZp0pF5Z+788ne0nQC38BtQP94sW4mHGJ8kaGK+wi26a5UZq5i6R7XZIQfZt6lLV7UI76
# DATA ORnxLW8Nz3L4DstjwzNP7Ard4l1UWzs6PJlZTNhXqqb92OWzK9MXeccUp2GmegLFQevprfxUitKP08MRNslsW8YkJ3Pr6P88+sY7
# DATA +uPR10f/evTt8ZfH/3j0e/r8zdFfvOP/SB/+dPRn7/jvjr45/oKu/dE7/vLo26O/0C0/HP2ZbscPXx59d/zV8X+mn/jpP+PrLQ+T
# DATA B5jzEgM1JqroyGHH0giW/LZ8SZXhx5PYj2Pb3OP10l3tJOmvcoSEZG9IPvdmo0mqfwvHWNz8OEi7USRGCfaZYYDdregZmjhiegWe
# DATA EbOkk5rljp6gz5iYqW0pm9uSPUGx382laInRgClld0BFto3wUXQr55y4geaaiHK+MmCt/gBTyl2eTm40F0Wm7Sz7uT+cQW0m9xPi
# DATA gK3I2/oeSvs41m5EdUcSMmxMC1NJsdp+HbqH8+9HZEDQLCwfOTOt/7jfs2btuexTU/eHb9hT9zfeeXj/3uOfPfwP+SgvTKVz6bDf
# DATA ln9uqZ2tnmUU/JJnF56RxKKhlbi+ppwpc9M0umM25ibHP6r2LOvHygllXN/wQCnVNbiZqiuc2tuv3cocZB/lvhU/+qxcaPifW7/v
# DATA vPZhaeeGuvDRZ5VCo4q5jv1qqxf470ffUWv/H9Sm/3/23r25jevKF52/+SnaTjKNlgHwIVlWoMAeSqJtjvXgFak4CYVBgQRIIgIB
# DATA BA1I4tCY8uNkJnPjSm5SqVunpmpmTureD6Ao1lhxbOcrSF/hfpK712u/GwDlx5w6ZzLnWET37v1ce+211+O3PgR+8Ina4J+rHf9F
# DATA 8uwPuPGf/UVxgC/Vyy9VQdj8j8rqmXryvnr2KHn2FEp8pP5+qlXVyPlIGdgDyJOSTII6jLTXYxNOC9msoBazppKvbZ5+kiveTcEr
# DATA NK8tLwOr4XnVFcDOXm4Nu8uqrbQRn+eVV1eCafi/nn0CnE4xtUfA6xT/o+Gpkao5QQ6pxv8U3gH/+wVOxucwX+rnsy+efaE44BOt
# DATA z4aE97mvES2njs56NflBnfXMWDyD32vz1gd68xRW5yk0DO0/hm4+WrT7hqMT63/+6+cfAhfXi8d6AEtLjRoW0lJjR20d3hhxePDf
# DATA 4AKuxkkvmAgcq45eQ2/3OFXuXqo17Opktk7okm7rY2NL+cIL+Sfr+i54Pv6W3P275cYrWUltxmWz96rNf6iop+ey5TdSVugGKnCq
# DATA EFz1+gDcdIgKYzW7p2kVLu/VajolL1/zCj/ZXWsIJalZy+YM3R9vzdnaRDwY3VExtJPgd7CZn//m2edlwwFkt+POf6QKP4KKVDHF
# DATA GZ49Bh7A/EFVLnP95+cfKwr7EsgTKFf9/rU1qwRWGNvJNNbVBuxkGbc9hfBlt8+EOnsS5uwFnJA/q62lljzBQX3Kso3q8fOPlVBj
# DATA 95iVTWxMAPRCm9vR2xibo2GdjdOdaevrZZ09XB4KcF1S883hxFgafqHNShWBzYiEySsAX2kGC7SsyBKeo4lDFcN/6/WQQx/ISy6c
# DATA h4fS72kYzz+KrNoXzz9Sc4JkDMfSJ0hbH9O+jZ9feDpddt4pMlYT9oQmEqoOSPb5xwmVgIeaEni5sdux1VY30dJ4cK/Td9e32Eit
# DATA 2MXd6uzfiivYVfoSPPX8I+DsamTrW5sVsxkXIAgeUSld39pqbt26vVM/v7K6crd/e+PGzfV313+40dxav7lxvXnn9vU6p6pBYfhB
# DATA 636ndh6wHfqpswtT86XqTHPn1jsbN9EggYMgyXvz5s7G7Zvr15t/++5Oc3vj6u2NHSzCd9wqFm0edR6WzoOw7tZ/t79z+872TnPr
# DATA 9q0f/bi+erd/Y/32T66s32xe33hr/eqPm9c3b77T3Li5fuX6xrU64smiMYZWCy6qvhQWWyHUx7OWGK4zDF8rAhoe3qAWZKlC/br4
# DATA 6qvnXw2W6N+JdxpmQ6T5/JdEYYqCVV3wkr53F8U0IL0np19U2S0yCpYIdzUxgbC4NkMaVBQFB6LqMggJnynC+UL1+wnwnM+f/5qF
# DATA QX7zSPQpEcGP+2uZ8UrGCl9zRY3TaWgQ14VnuQHgauw2HPkczNtx0zaaqfc1BN0sY7Xp3q76qoGAdfhdIcsX19UmG9RKlv1s2OmM
# DATA cnXHud8ZjbrqCp+mRvVBSJGo6RDr7AC8h7v7FDyAGBXaL1Z4aLLXASdhUnqgkAIq37o/a+DYGs7cTWrnBljKtEBKFcCJrL5J3RsP
# DATA 9xs1aPrHS2HZ4OT6FJmsOpcU5Sie84RI/jfPfoecFR4BrwVW/AloHtRWUAIIVFqR0s9/5bBq5zjGRaA+4FOevzycBx7xdmcMZvI8
# DATA Mhk50RJTIm8mqTA8lxMUGr9AueZP0DmQHrxD5QseEPyjfrOtH8RM2Edqwyv5Qh1w8JGqDk4rmLAnZkni886uG8V9W2Tm+Sj4TPXl
# DATA V3RucCeCYdEJ7C8Ai+LSiQwoZzW4qPVBwdUFZF1dUPGx4BKvibquFYilON/YTa+t76xfWd/egNMobWRV+dY2vJTe6Zygiq6cBMpG
# DATA rz1tQeUVl1fRg1atFZDpn3HlgHUjM3xCAgjIaPDQyNK0oEqyVKzz08TpuJGtuB/yp74u64sH3iItBgm8BNYfeYqzTeGJ9q3CFfF2
# DATA AT7mKugJBNt07N1wm1xGVLlujhMCyjjPc4HsSsbwLAZlsKZ1itu6qYZnbV8YCymUlDSN1nsYVckqv/iezapdQusMjKg4vYU7pnBI
# DATA aCDsdRHiR80+/ilLQ0FW8AQ7LL2nnq3TR3IwZZ7WEj8jreU01hgYMEEVV/KnDf220qzaoys23P+kP+6hxbYG6jc5VVj9w1QAUpU1
# DATA HPUcB5Nubq1TBXARfas32Gv1NrfuX5SHXq/V4DQNq89lxli614+lS+HEM4UDHDkH7bKSERIPZBlOh5CXrUfGCwwUqU76SugunZOK
# DATA yBQAflxwpPH+Qf0wFrd5F9eEioRiZZDZxfHDCpnkB6QYU/eEz1BH/jR6POALOgUuixz1GFnsx3i9szlEQvqJJ5ZWzToQnG0vMxI7
# DATA JHgGXvyEhg6qqfgNyK9Fp0MBd7POAemWzWm52y/MaN3OqnJUQE/bE7gLWgdXNXn2Ozp5H2PXf4Ev/sRj/ZRX9U+4Enh/uQo3DD2u
# DATA mxs77966/Y4nL8WmWFJyDHi8/DtHB8oSF8/AP5YEx30SoZv2iecJ9iwU53hcBS0ZmSW0j0DUVRZ8QQJ64UfoA1tbCjyDTqcO99Za
# DATA wYioHXquYmlifSEf4LX/bYL3cLqePtHGWtu901HZ6FsUSlLv4533afLOxo/rP1y/fmdD9CTqgeeNgzcBnePavhSQvhLi5DGHLlwM
# DATA og5FqoYZw4j2/Au0qX2CwtaXpJX4AC/q1uWKdbOkzYGL15/SBS4l6M4qoyF257iGufcV09OZE+xdU9Wf/ydf+1BbSlNrrRc+9Qag
# DATA vv65vniL17zqmW0nlbgJYz9dmun77Hho8+XbdV+3brIg5MI0foos7p9ERxTwMeLHMKYvaehqUL+O3GrNtgVLWTM/aq29etEeTbt7
# DATA CBGLdfECqHKRzHjSWmZgtISlo724aQ822f7RpH8PNhmK0b3W8V67VROLHuZbsGILsnKyl/r6dOpRleKQS1ifMy5+f9R5SH9pWw1F
# DATA mzZhIOpINd65fHkfDMah5y5bzXqUkIRY3pDkVtTZguMyjATMv3hGD8FCDR+on3CCDY0lcfvtdTVz23dubBuuC1rGoWPUXiAKhDRo
# DATA VHNmOoPdXEgBgkRjbOJoPUFCf0x7lAhKbQR9WJMpFoa7bI8DIh7IT9ghn+yVNEnSV6iHr6BTv9dLWZP7iDjQpKUx816mU6QPtu2U
# DATA IuDmLxM6gYsgpe8Xo8EDFAWDvttOCxmpTdDZ2Za6C00lah1alQP0b82SpOStTgYueoMHxYYSMQOgGA/djko0hSsnTOpLS4bB44LV
# DATA xs9/DifIR4prfW6xW0y8WMcZXI7ZIdAKHCNFecFkrZ4GzAIIXOwc0bH8i99LltCol6Don0WFReoVa3Q4jShgy9iEKzCwlTrvjUd4
# DATA lWKtq+BlwZ7A447/UNy5c/2EZRunoJZWNMmi2omo1pY6qB/YxVQUYOjhIUbWnlMJOh+ASsvf0Xf69/oQka+hXfmL1Asg4nH/oO6T
# DATA mEVeqGqXxXBXAB7JCtBZ7itNcNLkpKP9Fc5jFp8eHBnH4cMneDe0hlI8/JsIaQKvuAM0D6m73HI+pJIAvgL5IUalLjHMLnJvQGTA
# DATA mBmsaFeWF1Hk0kaWxau0hutRSGbua9Ev8SgQRQH0YNcOC+FpAzo76KqejdBNl6tuUIQntIpsX9w1TIAcd4nHwN1yVkJ/U0SVM761
# DATA WGK/e0AigTURi3zpzwboOHY5U0hKhjhMPYOXEGpklxKL0OipPI6h004bDneVD4iOgDhQFXR7QDkCfRnCHTbG6iIJVEb8gUe7i22o
# DATA /5cPVGbJ/01xrj8qoVhdlZ//o+FipKpUzBzvyko6U9dREE0DPo48UHNIEp3dK9bQOQVdEwhzezwo3UAxm6W39vJBD3KmWRPEX+p6
# DATA l+HB0kKHhJLIB737mA0ob446vda4e7/THA/sWCgQBJyyaFINw6kckb6ipZUZ8vwvWSA2/n4kxD8GCyvOLCoywHqPl/Fnf4Rzh24t
# DATA j3C+H1tmRBmsbBpkVuFxOL/DeHT9WtWtbut4x/8A2Glxh10x3Z2rJaaAfmcyHrUALIIoQTQSSq7VeDGAFATzb2wzgBh42IcwXsqV
# DATA 1GuddEZ5Atlak9bBGLDKB31MEotuoZcZkIUCzQlRRTekLTUxBxvD3+TElO+qJ63jnn2Umhf0nEI/KoXfFb5XrxshERv0nOVE69X9
# DATA jVC4xBFX06h+lVtz96W1EOYaaFEW6hJxhebUHngI8upjuIfqqBeirfjTJTdGG8dl7qOw4U5TQUhKa8np1GhCxOZwa3uWycHtBTqj
# DATA +jPLrwsl20co0T7F3QlSrXZlF50fShuwTX7OjiKfg5rhsTbysIHicQG/JUsbXd8/QZ0bqS2RFz9xFBGuJ4xZrJhdlIGJZOcF90iW
# DATA yuJXFOvwpHKzTs4l5+bA51vsCMdOJt9JGLmWsJcYTKjbr6Czq55exu9S9/n7BJQ06LU1MhOS05J/ps7zuY5eUkCoR7XDfwOF8vMP
# DATA pQOV4G5JEfYiT0ir7DFt9i/PKBaSyYuIm7upnnOwpxnOyaOi1pxSIGuCbGgac70iDLKAlkfQP+L8+cVnwzl2iudCVA0WLxWZyOuB
# DATA aVo7zReyH5Kc4LEtNhkloaNcCyWt2gIRiELGWtxGfxOEqnDEvGJl6RxHjcIp017Kgjat95bbsj8IKR+VZuyX8WuvlMCbCrVEb/z5
# DATA OsslOBzkAjdfdy11z1G7gTmW1NmAWN2dksRkWMGaPYMnwCYkrT6WtQPVP1yHbGvTKZ5gByzMlZMmACaIemeKkwLFCnRSv1Mj/gOa
# DATA Psho9EjcVJNQfHocaqMk6adLvHpzL3AJwMhOstIKuUCQfuFNwN4d5tso6biv48RjyuBMydYOuxxVpmyZ4VvXYOkwBURKaA9+0iEw
# DATA bYLKnhzbOiF7JpG1Wl1zjfFScB7rXLzH7PMDIIYtNXNHStQ09didHHWPW+hDXSxgWd3j4t4NUSphS+Js+n2BWQf8wlY/mbByRo5b
# DATA ZLqul4AwdLvPlJ/HX243HIo2Iz2zB1ccIAVk5wYq8T/m7vWSIyPHdc93rWAha4foIP/z6H/nNkS6adO+aMFv3rq20dzeWd/Z0PEw
# DATA mxvbuGOZiSIEEJyw3BkzLlSyFzHXOctDuZncdL+p0RIHnE/MoUgPjn1a26h886UVFsbhMsfdHACp3SAwUvXlcQMjf68vJB7f4Fgl
# DATA mEjPHsO9EuAXHXxn20HCqSO1fnTwdZyBv05WBq+99pq5EetZtoPAb3cIKYLRgTv3u4NJnmzeWH9ro5xMckp+AP6ADzpWSuj+mHV/
# DATA arMMAfHSqpHQ7JKfTQbjVvJTRRJwsONCPsDY71FHTe2kgxHmXUQmggxdbb7FYljGZGhCyjn2kFhA2dt56E7YcPeo3M/ckrZ20J1M
# DATA vEkvfgOUgxS/UovJPStaICxXDu5s2oe21+o3CTwS9MpNluZLNLQyzTLE9e8fdTHVu+XKybgizBDadSBpURzwD0tF2aQq8YWtVqDb
# DATA g8knIR5UOsJVbUOgAovVPOgCFhuu6YPWqG30CWD7LVYJk1odg014OLPKBYLHb9EFw1b4/JmsoxQp9kiMvAlKaU/U5fMj8ozxtETo
# DATA J2LU478q8Cn0LL482YJ25cDExdDgFB+mhM7AhPP3APrqvbvfjcC/2d7zjnMJqRahX0+ffUpWbFBCKYkaDUkfRaaCLyxw8cYIktjQ
# DATA 7lMcMuZ010vFDwtHz+/d8ce81F8pvVG7W6U/s9PVMgX70deLDFrcP8kZ6QM0X8SHSmamcHxCW00zUJfcgrEGX7C/oXtEhJPif/eC
# DATA s+NXky1qUCQzjz1TrtNvRPpmfBJ0WiMDPnvMJIrnKmm3BB4N6h4/LCHwl+OWXlVHEsRB7a40knPJhWy3dsET06DiYFZgT9CbmeP7
# DATA PXtFwDX7EZIwLzfHG+mRgd7oE9Im8cDB92OWBfIy6e2BU/yH5hiKpH5Om8nxQv6EFftPKf6cNL5CWQbvOXe3j/2GC6sjsOl94JJh
# DATA 5BvJpOMX5efr9hfloAVjTfLp1Cpk+axgfgG7h8zJnDoZf0i9c107+yd+K+wsOWMHmKBg1+YOEHvGH0K7ajrd8NpHw5+aGqeQvrn6
# DATA n/ob1585MylnGKTd12Ap/Kp8BExaUGsxFm+Lv9VuRzAN8kzPgFUoHJLlhxxQaaylM/ilON4NFKv9j6hD/IBiMz3+FBhwnuh4Qp9z
# DATA Uf4E6C8m4XC2HzzZJvEK4IjdzeO8JNs3S2LktKZkIiqoBTT07jaa1G5fZsvfLfY7Xal6rntZMMvBfP6bmh+aAu39+mcMLPxDEMnx
# DATA JbKkj/C/Hz57zDLOWedyOESvil1KaMK+6fW66Tk67gU2b6YIJ5Id6I8qNOTHvzVhWxRXSG38TTA3/0MN6Q8YXPno+a+e/zMzb5kf
# DATA CWmIat3+QnEtqgKWGsB1+kOk2I9UTU9CMeozHfPCeC71gqgxdrHf2uKAQQtAlgWF82uif6aqUO18YeX7F2VW9o+IbrAd8q8ju9td
# DATA RE+7i14rCJnaCGflt86IC4giqs1+iicfOiPiA2sMRXp7drGYoZzXuu/CSxR7RzpxdVHXjUYUloCUkai5X7M5H7ukzdFZ/qsVpeuL
# DATA 2DIvXzCdvR/oMQPWJapMrdsS9H8eOz13ho8dKwe3o7yzAU6+W4gYmWXa+o/yGYhi4DRdBYyje52TvLR7juvhJhr2J9XOwzGoghez
# DATA L4svn61+96wX+iINtdcCd7OFjesLHByh6jgeaKd7KnrvUzKNoBsqWf/AI4yU+bWIr1vQee2hLCwf0rnjRDj257Sq+EBq5kbSMVHY
# DATA jX/JBgqlv7LY2aJdjVz/WrMvqDR9KkikhDPtzqr4K5OcjsVJaTnDA59GbNzuFwJ4PovlBxdUA+oW2ngRqyW6yDNcYHRncZVsq6/t
# DATA 4GI8Y2iwzkoabY7tqRWnfHf3UaPZN7sTzA5QMhQEtRgf8KL5cjzOvql9ofgHu2ICvly13ekM4Q9WVFmegkaggpM9LQuX52hx0A6/
# DATA VA8eFrniFPgH/Fqc5L9Asxoc7ohMkUCslJqzP4IzDoaLmhDx5x/J0W5jJFjCYMQJJi61yeavy6zsmg3ewLEb0Ir41uLiQVCMG4Bi
# DATA iyqfa7NE0WnviNtFtNI5OOigglB1viSaw3nsapER6YpnjalY3wM//iTjQTlP+7AWrr65WzwqGi4CU8Pa6u7RAOm5E2cdhiBRoSAG
# DATA yakXxlqKRO+7DJ2Le4gAznRSEepdd2CsNlVeCzBqdiiUNrUJuALpBtN4sGm9jleUQuZ9hmsHqkg+p4gUIDYT7cSRahxyEwP1sKCC
# DATA w30nDMulr6gv1aij6L8LAigQr7einCFDIkp5Mf4GF2N3pVEdabQifFJZ1fhFNSljL4fVFqIhqV/jwxGBhcvfP2PI83YXH6s1BcB/
# DATA wP1WMspDdJRrtdv4RAlknYPuvTRqnXz274U7Fzb7LxT1g2D6TxirpdbnM4oCFQ1VQjvoKWwU3CIYgAblEEzrffSg/JV9Z/rIWhhe
# DATA h12eQIjkwr/8AtXhYFhK9ybdHiTLQCOCZfPZOermzEIAJwRMCAOEqwMXJ0wAoF084PVoOOiRiRtOTJEVrPpGkPO00wf6IPBhtkFB
# DATA 7oC+6hEgbvYgeEdV2MfkBjp+DCCJ1YFYDUdow/jDOE/PnYsFPPrSl0kyAWeodV2q8eVNgxKmoN9Pv/tdiU3WJGqfMjGua58fWtsB
# DATA nbLMUnYXw4rxJt+I9ZnTfaiyBHNl18NOpvSZGzeLinE6KSx1OIkF0rvYd0tuQL0lJ4edDkPlhXMVHr1RxlA8UTPWMjwjnML/k50Q
# DATA eu0K51ybHEfIHaXk5s3tnfWbVzeaOz/e2oBlBW6mdggyMsLiHRCg/v5Rpz3pdUbp1Nca0v9Ke4NBbw7pMRcmSdiZT+HP9XpSVIXm
# DATA QVlBB6yZV/PBulFoSf2yNiHtQmpLCD9zDlueJ9AjfI3HrhZyTGztIzLgfYo4dU+UWPqUw4Md76nZhy+h2OK2eCVJL4e2kVDr6gSP
# DATA kplMO9M+Ljajav91bQ12XbRCflCzstugTBnhLh4N9/SR7RCx0Z9Z8iV84WjL4MHCqrL5gueXMcHzSRyTBs3Mn3GM/hzhegbrnsf+
# DATA 5zByuort91p0F3NanMka1Izq72yGjrlg+UVsD72EQDhxsWX2HD12biwCZmhFUYS2eWPa/SOsTQS44rIQ+Od8K0bj4Bci9YDlj4D5
# DATA zkjxHtWfutNYS5DfxA7/qRtI4V6O8ZZrY5nq+ClgdHVx4AjNe3XShpcTWzda38XLPKn+soZ+aVSIdbuAlV0qIndbPsgIbwdg6oHh
# DATA 0f5yB4rdUaVYNigsuEWMnpBOjL6zoC5/yxd8saWle+/eaXo/1/yOUb+XphX994Vp5YL+cV69uPT91l7DeSJ/r5KfnG4szmYI1WMm
# DATA zGcYGPEoOdv58ATZ/yNyjPgnwEMRVwADn/5xECGxW7AAIAibYdmhE6faU6KWrEL0jlb/13y/UZQlyHOTNU5Mg242Fx3QCU5Q+m/1
# DATA MWnWUDFlVFmUBQocvGqiZ5FoX/WERgXd4l0LpfjPsntWbxvPq+hWmIov1lwtPmrCBUpXQ6LgzyCoo9ASYgHx4kUz5otvu20S+uOl
# DATA 6Q79cXH6E3bQvyuxzdgtuOR6AOA64U6oz46Es0pYlh8w7Ud9xYO9Cp7CtxT/GjRvYloDWGXTcQ8SyT3SHbCjL+FE0foMdASLGXJq
# DATA 6jxQd+c/4PEgxwfuK9a/GkzqSsUO8AmhhApX2HQffGXs/El5RCHtTnwQQJgbnI/7nEok5jAIjoSGJOGX5+2EwCQYwanf5T7k2oKe
# DATA eIWRMn8B5x2wshUeuXEtdmhyhE7OCwcqWSVpKI2iTwJfadfYoGdkPwCoZCW214qrzC58GQFgXWSCvqQAGnTqYmHpM1uzPcNsbTup
# DATA 756jjhmuq2SGc2awzHXRrhSGX1p+60H0kc6wWmxIMPETIQYQ7AiuYk4AjosNJP4MnmWEPB3YRZLN/GT7h0mVM/iPnDfgMZ3DMxaA
# DATA /cUeQ3HDJJwgRISo1wHdx91x0ZZk80fTBRmavYtfdEssEmuBdXhRFmJwjgSuBQRUWzhuNk46ZKkOojXDIA/qlGXpxwfG0k8/F2dN
# DATA 88z7jzX3Iqi5QupwUHWMWzpOlOuQPt+GXug/bifcCV3HTQlDXB6L0tHmEvNKxObIPyj2MZXamN7oFk6RpwPRvR63+koCbyeg9rBy
# DATA w7HTPjUCrouQsBz+FTdy2zU8Jrkv6DF4JmRyoRr+pQQISNB+Fic2S9CmR2fBMP8Wdy5r3AWwjIVu1xZrDiihzgJbq8VEyfX8MXrZ
# DATA EoYaeRrPYJmzZ412lb6fQAWhM54lmMSk9yDPtu1y57uZeUey42zbcARfqeUM3ukAlIwO9owLAZc4X4M3n05inYjZmGnZHB0RfNb4
# DATA hgwcEcB8xXdwL01jnE8cAAQTvgPVd5oQyNUk9iSBXCUOdgFmdabQexdpjP5xYMb6Bj4c2tAbQtpz8VN4M/hReyRzU28oAJ+rMTGm
# DATA RRBJ4ZanMvMkWCll5O6GAU8SWX3xoM0gmk6H0OGsRGI2fQAqHyHIDH0eSpAFOvBNdjgIMl2AdQaIROpG5UomLh8NBh0Z7sztKctq
# DATA ux43ioSrkBAXCx393zVstJhmKGyUldstpIdeByzFgwd9yNDYbw3zo8E4NH7bmM/p/UFvcizHjXGnGp8MQcWU7nX7bTSXUadrdnpB
# DATA MPTTOtUSd2gstL1Q6DrxW/MpSIQvpItLXE/bmst+tAMulkOarHkkamvk6I+pyzaiYfDeNdEPUqfhLcJozE7OLC6t0US/qqbc70gM
# DATA V5B+ZdaRJZik9EuOweaEkn5KEJT4Uo46vU4r73Be6trSXMdLD1z29eTCSqBp1HfrviLcUXdfO4SqPTy436G0kYqwSXHPXfDdQGdn
# DATA nvn+1ESu4U8dvcZtZsW9kngzijDTsWX8oRNd5uq+4LNXktJKOUvOJaULSYUvfup5Fkw02lJKdnDl3BhOP2wzGELKni5lMxjtmCJ+
# DATA MoGn0ZLrquRgO49bh4hIynVURxa4cy31hFvBUAaPJkpmpT6vhUDKXFnQVUMN89dxqRAxNS2h9ZnrekXVlakqKqX7wePsDXzxRq11
# DATA 3L544b3W6PjiBfUQz4lDD5TJzI4gj2qQfKMvKltYq8FLf/0nQwIiLpnK3eS35rmd+q+UHh7tj6rdgckjtUxeXfpXSGt8bDQZQN14
# DATA c2pxSjdtBoooFXWfYGM+EgYSFxdDdzt0YVvyfGZOjceZ9kHDPyrD0eDhifezQpf6ke2gZrm3ha5uxsONnN6mATUaNLGFvWrAwQKj
# DATA URdzxIg74Fie7Q6mDNYddd1Aw7eL2DrLvyMYH0GFgKXYSEqsLhe9uZCRlqLgFf7rmsXsYpE+xDpWjvY2WtJrCs4pJdE4vXT6NrU3
# DATA jX2lphFDhg74g+6glNmFJ5G3SSsHBz3/BMx9SAOSlEzsNP/m48kCOsjrpczJMd204GjDk9at187U0TTpu4u/0+3LUW3QP7TEbXWA
# DATA kUSM2Gs1EqCMnCWUe7YDvFYi6J7oeTaKXN2TyDt7CuOQDXwkjO4xOIbx639YMfTKs+RnrLK2KFUReIU7qMKwF6lcaIeyKcz3A/TH
# DATA LuK6XZc2gFlXp2BiYh/qUqkWTAw3H3b7fbBHR0mKWbuZVoex8wG/wMlVMEiO89qN4TdIzxqLjFa/WSwu1l5jPxZeFSyMh4fPBOzY
# DATA flMIrVwqju213UPkaSZHIA9DXVcIMzyo2Ol1d/6JnpvQBxq7fcRPQy0etlyLOKwvRDCFrWYRKjo7Jc3eMtQ/P8pqQco5IF824tdO
# DATA xkRLo9kGT/BeJCMeZwX0XW2NBy19SIWvx/1yWVqypQg11iq5I1RFj5M7ceBxryOx3ma+e2ikPlM2EtKUCGVIhLhHHfEEZt6S+oR5
# DATA ylRQc2dlk0hDneUsYdW469NQKF0gvmIhco11wJnYM9Gl1xfsfQ+3sb0Gg9EhJiox9FWlW5gL6jKb1HXd3chFXV5modu7v0XOtD0o
# DATA 5LNs0MqOFAH1y+wmL5dyYH7OxJTCYZQDKSQUplIHHYUy4jAIyhN0qXyk5D5SQrgCYikcVDmQbEJhzW3P9U7AmP3PsEWUpYqiXmmG
# DATA PLrQngbzNCr8b4DTJTX4Pq/y/HUeSxgkNWp11YrcoWZ/SK0iljK7vrp4MraPtmSzh6xt/0yOxrW4q+sj/I6mQH1YZuckNC7JW6IU
# DATA z91AIIxtA7D2MvJtLBqBSU9X2RhqYiqpmdaYmHFk+Ws3jcBimW+1LhiYql2ldNGUVELnkYN3fTZ430JM+ZaETca1plHUAvaAJ9iC
# DATA bwCVIPUcOM6EvkCdC7A8on4WGi+o1yt57j2Bl8NcWH1wzwliWJ//CiLZJJm8wZilNxYKkzH4MLEVoSl4jiW1M2GS2qZ0TO7yTfpp
# DATA IgojwDQQqLdEylFSOzIXTHJ1Xu2dJJ3WqNdFGYt5cU5ndKfVtqobINrjUN3hW2NGcOyqyrvHHfXVMUjH+VGrPXjg4s1WQ5gF1290
# DATA +T/Ta3R5js+o7vP/lC6jC9CcHgA7jZpF8HxGl2Meoy4sqQ1Nwi6k7m6oSoCwW1ctArvrwhvE3LRqAXSDuVbYG4l9kgd9dQfr+Rke
# DATA YqThaAvkQ7c/pr7iHtHyh/UnxIARxRsOag9SiZxWrFwHEpeimTLEo3BA7n9oP0ErqPpLJ1fbr+nZ2ahCj++FkV6YoUcM3a7AEEkM
# DATA ZfkuzgB4kAPRdYoNnsIZEiIJ2UXtx6awqSBW67cJHMHHOxyCwgCLAcRczQANxXVDiqI6Eel8aWHiFMOnzACCcCMAn7gD8GW/WhQe
# DATA whHvop4QyKFnlvDwRKwLu7nBhU3FEr35jUXLeM2VzE4rUkpbsBVUU0xWNn31Ez/HMJq0Z9Q53HmC0fRC+UNm5A7xPMrFiW8GS7uM
# DATA 4F+UN06df5+qp3+S+LkvSQbzgDTxkUHKdZJ++B7D/XbnYVlLgh00DbY0QvVc2JxYNpzXk0vnIAcO/meGY7iBjUKX76fPfyE5YP9A
# DATA Y1UP3PS16IIDxpsISo7kzqi5vSwnko6iloQpMzhDHUwClDwmi8rK4OLKyrRw4B5qh+qTqEQRxdubEhvUu5yQN0U9cMDPIn7E0Zwa
# DATA ZUlPVZxqwo54wSXX+g1Vk+00IWQ63zXlgF1PuMLpLFcKWxJtyrlkAOnoXLIygSJ+uhJ3606qjLk8Txy4YmYN9KK0LAE1wxQsI0Ut
# DATA 5sgH9lIdP8d/ESk40WIF3pRGlt/QLFndzkCazxPgNQmk9zqRWymhkbdGoGzEnKmE5o6VWnXB7FeTDUwgBsKC+ixH0Hf0BOu1GdJ6
# DATA CIAd2AhLFOjRPa7GYdZDeWued7u9F+JyKCNofy03Lv+25cuqgvifBSVCqP/F/fO1LPW1+SfFvf6tEGNO/7WB/yhqc9KmO4mv7B0W
# DATA r9bddxYjAKWY3MP7Yw9EyBJbbJgC1GgQjIE7LFJptbs53n5LFra9pdvUDIUx7UXaBWK20ey1vSBuXrBiuiI2BJYn55sQtMrfcwM9
# DATA k+VB8yRqlJUrXCY44v8lzBCOEKeeFzqHivH8o0e+A6nthUGpU/FDk9i+SF7+lda6YFebsJdK/INPgMHoHoFWu8rCxc0nVa4CNHwG
# DATA wSmqEeSSjjpQd4B7kC6nBb78Vtb7BGeOYJWeFib5KpSYKhVzzBUgoMKDhjZz8wOWSxecFzoMmnRm+tBWZb9h2FolmYzlZGhNoZ9p
# DATA HLmvo7KkxxYQNQWuZL6ib3aycmeKEZrXAZt9klgqwPlTHFGlEK5GHJJ3sVzOPN4CuAzZivq1jY4b1ymJIigcrF01pJwwdV0O5HMb
# DATA 2hgune/jfv6lFTjDCSA8bSjqJp0eUwvNdzZ+HNkG/0+84SekaobcttSkukba9TiagVOECjpuMSyALQZZXDuQA5kyyT+ZeGhN2IoH
# DATA E+C5KTPmreMKUEu00525DJJbMv29m262lRDmVuzcv2tqy1AdDZT6x6OWhRSw25jOyH5dc894uNl3twYjCrsZqj8MABO6v2/duo0Q
# DATA 0Wvqf6nr54oV8EmoutDP1T471s5S8SORHVkdF6myC25ACCNpqj0RowAltrj5lc5PBmU/0ylo+ZswOkqxv4mHxB7GSy0EaVgIns7M
# DATA KPUuHSQOax/GGNRVzBuGr8XgfQg/T0v7i81kNn/iai7zy+IgX+iP4fphTIuB2WbCsZVi7JTgvQJyg8eBuFya4QCavSjwlseLIyCG
# DATA Ye9iX8xCNQzclV4UqTKKg/YN4VT+Z/n/vijsqM7U4gq4Yc5t0sd+Bh4G2kz4m2e/KyeMsRZVezrwTt8AdCD7LuNGd522ivD3zJVr
# DATA oD0rC/ZXCWtfEK/PcgHXrusVp7x5bH1p3VXV95rfIdKfywVnQ/q5ZZcKKEKkdYLeMy3WXmDPzcUtPcMuj5/xhOY9k6CNe8oMkdTR
# DATA N4wGYyXvkHui2ks1qWJX/aC4ZPUHWVYtAQzvEfyCP5gW171ryRzICuHODTIJf1osl2QxNU0IWx3ZE1EMzLkByrto4q5aUTD1FDgc
# DATA +MLUQV1gxlRQshFt0AZmitQOWiu9EHgjI1P7AW7cMfHSeKcbZxigmOlg4WRA5H3B61w2zhi6P3IIy4qzwKMqjumn0ErLX55x7k/P
# DATA nVOPysm5c7qGaZg5vexsRwcoS31dUn0d9tCd/0idFCRZwF9NoDdXIs2NMCplwQQ8gJ1Vkidi5MzzB5RXnED28ipBlB11HpbOr2VL
# DATA OvcBilcxWD7vC0XiW7e2d966vbHd3Frf3n731u1rqOCnhrwgCavwne2N2xgrYR2K+uW1K+4rvxYPQ/DAOk5ry8vyo3Yq3Zj+jWHS
# DATA 7b3aqxfOry0X1/7m7Vs3d5obN681r926sb4JUfrp0Xg8zFXdQGpmRdKt9Zsb100x/cavcvvOlebWnSvXN6+awo4gNRn18pKzqmbl
# DATA YWvtXqrBZertdzevqZ6tX7m+oXq38eb6neuwNErKmHTCgdzY2Lm9edXMdat93EVfEnkBKxZd2bULWVDbuxtX3r516x0miObbG+vX
# DATA sNooXbBCXm1UCFBkYtaSsrtFieBCIXnYGo87oz7G2f0dTPyoU0UU6g7s/AyD4+rVc99NXblN0kPy52XsBRgdqzc8Nsrdg08me6Y8
# DATA 5+9r1pKAwUhlB73WYV7HKmfkr8X6X6kjjqqqIWRXr+ArmznAJ8wMEOgBeAFNMAZ27nXEAY9+yKWYX7lxjpj/SFBe/ZRI8Pvl9O7o
# DATA bh/gXV8+k1sf4pJqvcZl8OLhbFCs+zQnLCeRspHXAY8d/iBTIktujulm2DoBw7UaHFgbqvA3GK/yzsUL1b2LF9iYJtMisE8UUOQ4
# DATA SkeSv3HdeNLey1yUHH63e48FBnbEal3tjMZbnWPYOT99MN6a7Cm+/Q4j0queWK/hp3oDv3zAXPJ6/SGsOzm7OraFknlRTnZOhvRn
# DATA sCr2xH4Cmj32c0SMYkmx+AgTCJDmzwDIPQLEGECG/QAdij989hR10qSeRaSmp/G8pkyZBy9rwaZ+SvQ2vds3Haqnpwzcqmj6Zabh
# DATA B63umBBLkIGWJESte9wZTMb1tRUTUmxFCmCsu2IHNxB9hEII1eq1Wz0lSaZRYJHw5GP9EdR1DZ8IxoO7c6xi0CTpmtinR61r9wCO
# DATA 6M6MhF0YWq9K5stgVNs/Ui1Vh2r9tZLL1BIASgDRrSQ/cMp4pvof1JPV86srr61FN+gf0KkAvAgewd3PTXQTXelHyds7O1vbFQOj
# DATA owPe+pzy3u6NMQKzLqvTOmCWKUl4K/C/Kxtvbd5Mrm7c3tl8c/Pq+s4GPq2eewP/VWdp8C61cmur6rYd5gXNBAP+fTicYDB8ZbW0
# DATA 5aLPfTiU+4GXJTzPe9WtjRtNGHZzPFDH6m38uwSdUEdvllUlWbiZKDw44EtK8t1klIsmvyztt9CKBjcEazozp4Yqw+/gYZK8R/X9
# DATA cOP25ps/bv7o1ZXvq+NZTdn69ebVt5XE4HypzvHu8eTYSsUL3+5c32Z3evjz/mpzjT3FW21Fc0DEsPGqxwM1xeD7VoIzlPcimZyO
# DATA wJQSFPqBrsLCUgmQ1brjoyQH7dpYJkX1tg8mdnVDKKWra69VV9T/rab6JDOMQI2ntAZh6Q9L1dWybq7idwUS5bZyxUsfRNKCQwdk
# DATA gh6MWsMm9aakSpNarjNqCp+oa+EK6lOMazIqEvQVSfoUQ8WBWQ07nRESy566pY/UWg5Gx3wQaaoBBibkVyu8VhmQe8JYfB/84xy0
# DATA K7AvQjTIP0l6Ehu4Ui14hTY8wtd/kGYFtxbqet4BdtorHaRvbewoFgb7aHm1ugoCwdtqamrJqczQFJ5d1UupbtY9cBcAyUH9f8jf
# DATA hsdxlhXN3trKCrCxLup+qHnFPu+XXl1dEz1dtrvaADq7sLJSPEMWu7dPzlvbfGzaR+gmOAz5Z6hcgQwRA3nlvU5nWKry7YeWwWUr
# DATA diJjXoP3EWP6z4mFfvkFJcV8/vFlUapR6M7HkmcZ17QcZcuYOP0/KKkM2EpR+KuQqlGs+fiL8+CVzB0k74JvgTq2bJP93IsgyjDq
# DATA bZri2St16LBrvLwfpJSAAOCAkhXcvSvqUoXHpnyRTYH1XL7bt4ru1mqNwnKOuHuQpintzOT0dMmqYtLvPqwt32+NltW+W9ZK7OXR
# DATA pL+ME1GFzQ1VJqhybcJde7A/6F1eOqXBTeWSrnY9ToUh6MtkJcl7TfuIj7Q27nmnevTLJgj2BV8PR9376rX7rfQ1T5BNV9f43/NU
# DATA BESltWTQv7xkDQFvV3kyODi4zDYQdUwuT/LRsmJKow5NyvLR+LhH71uT8QC95swnHdgOTQSavLByIVlW/6laH7Tb6vLWaqul+FHl
# DATA Kp3MFZBEK7foQqpoMu93D5RU3XvQOsmDr24DYMqoM6psDdT0n4Bk3d0fsydf5cFRp1/ZHw3ynJ841fQGpAhJ/u4fkuWHMAHgLbMs
# DATA RIFHX68LwXrqiGjuDdonJB2tXNbvD0fD/SaJK3SoJOdXVnLvPbC9We+BO+Bf6qo/iwSxi0iCVMF06g5DjeLu3WrpjZcedHq9CuI6
# DATA LGdqNOpk65+An/Pl4BMYLJyq5JWQfHcy6uJ/lpO6Wigsr/6f2i/MDg5GnfyoFHPnKWvrr9gz9amX6sO3nqrhr6Rl2j51bd9AYZ14
# DATA Bpb2NU0F1lDvMfIj1cIqtoBarX5n3EQFBAXEcUvmKRya/BCZBnpqKubQO4AgnF5qv6PqL1w4L0+7/b3BRC0tvbgEb2ywIrtOUfyV
# DATA nLrtC0b8LgwYno/ZvM+C9vvk5P7s88QVQPFanGZL81Tgbr/q7jVH57y0ViToGOVFwCOIItw+1sEUEcnYhMV9gnGrDCD6tXTXdE3r
# DATA D3fxBIhFyLG+wl/SyGKG4UgQSkdNUCzd+aIUKihB/TJZ39osO+sDGNXsTvIo+dGodWKu0l9wBJ3kVIHT3PIJ6R74tBwBuymAdv8t
# DATA BjpBvOFNdV9ev3ZDXZfchHSfsPzwEeBhw53+Qzue6hNaaRPFEEN71y5iQYBpgItb5HVWrFfqDQ4PyR/tNG2rYw3dQlLQ0FQ4jW46
# DATA GIoHyGmqGHUFeDQUOr+C2hF4hEXVo1dTZoAQdzsQwB8EkILXk75ignklHw8gXQt8zM1DAD79FSgodYT+qWv41l7GbJdt2w4106Ca
# DATA Sa973B1TPf0B9/c0zQcH0LPVlQuXXn3touqQOnbb5sF0Ol3MT6o1HEryMho6c2lJWiNJ+8iV1SyppErOGuWYhAzLldd3D8w9qyZa
# DATA mhpy+vhnDMpY32UbdIXuTHTuwUlnTNPk25rXltUqL6tRLPODgprbHTAw5s1Bv26bTtt7OJtKjG2j7QjBlRiLQQkSvfHRSTp1rKpk
# DATA Ep//0TTaDXqN2IiqH2NFYeCDlF69ca2y/fbGdcyPtQ/ZryoH+TaKXuroh0O5B4cmTN3qMtWBnueYZFHNCfRgdQWtFixOIFHnZBBW
# DATA kg/6Ol2kg2U0bg7VVX/Qpr2Q2+bhkKcERltQQQ7VO8ops5tqBpI2YimWIqSl7SO11UvVi+kLExldIY+OUfiqp+oCd7xHtYkFTM3x
# DATA zk9gmHd2rsI6GvqSHhqRyvKBmNHcIgs4PGx2c5D9TpLKneS73z11zEzTpNJ2Hl67Mg0W8/y8tVxbmdphG4omC+aadgxvnNr3K63e
# DATA sNsH9rjoXiuaDGhHnTfW93g1gG5WKrnaKpjrDX+RdR9A5kkrTU8V/z3uHKt1rgxRRKd3HbWNcFNhGZB6qV/w2+sa/4OCr19cUTgy
# DATA +ddee41eAUeCv1YKB1S8tMYppqLkfqwvX6A/kJ/0K66s5TtnsS1VSk2pw5aQkVmJkUKGhf86QUqh6FwrTuRLIl+xVbD4S7zJi37b
# DATA fxF4aEQ+rYsYAN4kwWtwhrm0Uk6UlD0t9EViAWx2zi7bhBGTuyiXnahOyErhyExPScxNoy4s+a7tmxO4ujXi+zdco5B6SdKoEwy8
# DATA +nZXZA+kvUKnuyiOYOTYmsGd7e+FU4M0d0DRL8772L6LiQnBCoPEsBrdtvFD/cUO59m7n+Ac1b4P7dospx10IH7pZT6yzXig78vI
# DATA APqtHp/dL2fV8ZG6PIzqr7PvFsQKjkuj6uDeGyu11Syr7mM4VCnzSqhXRfzL4TKvzuMyq2sRYWDNFQb4hBCINYh68lAhdFI2wyAN
# DATA t9YCmRsZCRd8igTDO36tYK/Q24JdQW9ra+Y0cw/9t25d27hy5y0Y0/GkN+6C+ma8P6yvgBDARJdeWqldAoUA3NxrdHuXP5cn7eEs
# DATA KSAutAbb4yr0ksIawLheW1Y0soxdX9avaqOBTiFegfmsLcN/zTNSsdaW3aQzXuMSfXZqVYRhal41fuia9hc/pSh/46qf2OFu8ics
# DATA M+Om16TpqaUCH49aeNXWqxdZcFLm7hphkX3KrQ0cQbpwCuFuXPgKo0RZ8EZkFQ4cWC8ucrLoW3fEXq3VMRdxHmN5BnEouUHIIqrV
# DATA S8tJ8I26a+bOR4PD5XwyhNVB989Yl0OmDVbjZZgHEbxi3WCOV/D1/mDU0X7Fsc8RU9kp1YhLNahIgjWM0VHDjeeJaJ7wGCCbgvU+
# DATA Cy8tQrcN8TUNRoZm8+IlGfdy2KtFZ7tlIiliWvi2tlpdu2T4Vow4l87GZcgAAfvbZjOkgYen1fYy24OxEDKc2ZztBafmrLXO3wFn
# DATA rPDBgwdSYcwUAX302KfFsuwFfFH+OP06IqiMmmx+DFUQRBWSRwRvB6Q0L8wKfvlV+2FUGBUTiaGiSWQpib1bavZ29StGFYMuqK2D
# DATA BcoqYqYpe8Y/PKG5eHgSdpdis2qJ6HNTzAhi9RRxPHQmqAVVZOxlY8uld0YgXfvhJzO9Js908bIDyk/DBMm1hMwT7hsaeyA+z9pE
# DATA BcmCiQ4hUXAV/nOhlGXTLOyhD3QjnHXmPScGY+WM13a3qrtaftLIi2NUnXTCjs4+oyKbpLP3Sjma/CzmBG0H6QFRKP7hBIsIdgym
# DATA wyuD5WzwwDclsb1m0GsDd3/gBQ1wZhFHYC1hdZntjwritarBCdFC1YKd0gD8oWFX/O27O03HYTnF/F7XNukv9NK1/Wzhb3GfBVhl
# DATA 06SXD12Vo1Q+8ivwRS7HnInhoQlqUL+cGAQ3UiaMLVLDpiiJl+owf+Qa2TnJCu/2/13nBH367M8cRYSJtjGYFtJsR4KGnv+agAqg
# DATA ZopsVKRBWD/kb7uvNoGik067tFs6JkdAMD9DCAT/3KakP+bBNXVp7PZxN1hPb7+bcmA2ZoPiGMEb2BwnZc2EYprUCyScpu4R/WFI
# DATA h39bVAN+RupOD1FokrkIdjBaXQZ5lWmN+wOJ367e2d5p3r51C1cEVej65FW9tbJILVPcraocYYdR22WQOeSVgMxa6GHYHzZumpGx
# DATA hYreQpynHqdZXvOMM9uU+AOq/jvJLclWOT4adToGI7ECaYwwBRQewNzicesk2euAa0CnXU02EE5F4pi4QiwJGGzD1l631x2f0CWx
# DATA LC7KaG8kQU2xCtSDAZ9FUIfxgDlFNxdoRQOVQGv0VaNCo/gJMtXSGPQxwmhmBosDTcLQYSXwaDRTnwX7Upe0VlMqgGgbsDYi7Zmn
# DATA 5xuCxwvnVSSuyg/Ts5uCfDBMP/HUYgvWR7m5xAZJVa96YuCo02sxHBoVNzugKu+a4wFtKIlwt3EX4FD3P+zmzYW+DRMn6+AB7hWs
# DATA LRib5UGVkiOBtLKGL18orZtbG7iWcl3O41VM/hFfgV1ZqEa4FuEuxl+abi0qIkYf8IEYe0fwhY/JGP05KnFDxh7Ju6mu67R9b7Ae
# DATA DySDK4pYAWcJfl9tDdfbbf7r2mgwxEKj7n0lVoOJtuGcxN65byII0ZEjrMtHQW8N7YNGwghrySk66LaGmZKF1KUeic9O7XV1XR34
# DATA HPbdQoyOkhfED86SAaPR0arqrHHjCWERoDd04HC/4B9z2OAv66iJxHzKiJlPSkV1XX3ynpIsjMJkujgnsJvAqSxuo3LmNnRmzrlz
# DATA pyjU4uTFBaPOH6F8YiqoaUBx8KuM7zK4SWK9acE1uYZXaVD28o05jahyIGrMUvlEC4ZKG8TAs36Xl6YSHAhJV0321xiShZ/8dXGH
# DATA EAEGl/cuLripxq9nFiq4iwsUjVWYixHu+yexVrJ0RiiNbHH8KBsNoxiEdO54KVOxBZGhUWDIkwcidp7/nPHomY/SQ5iBL5//2mGt
# DATA 6O1ZT2w1QymNnzlA3vZFsnrUeehk8D2diesyRzsCHeHn8Gdm57QUZJcDnbOprJl0Qa7SIOYP8cpIlKOzzpWZvGW3ZXqTRQrDyuFN
# DATA 5JJgpVG1bnYFpcGcjtqt5dT1Q5NehjANapkgiEEKlOG6U+dzB1upoVxBx7jTGMSZyPWFEzoUXsD+xd01AdVY1EY2V47Zw/TjMb8y
# DATA 9epD95rGmVdngzxoSY+8kXG1A/hHK38vobx81aSw9MNJCkt/WCoTN7+qqVhXJARq6rCqnroJM1Vdigfv98A5+KbkYd1pjTb7BwOA
# DATA YUX0R/4tnBfSGqLyo6Okrs64BfahEniclhOIm4LsBVYwzWCMuN2qI62x6gaXUL1r6j2uayFQUTUrK0CbUGUV3HEcdZc8BMR2wHk9
# DATA t4aEj82oRxeTc/I8doDCGPlKxz1JpHGMuui0c7wN5q2DToLecpaSnr+oFvYcwpCgI0tmosDi2hyqfVM0QTigcD6loJ9NEC00ivWZ
# DATA inVJr9HD/gRSYX8zDUvlRY3nSuCHVCMFbXPIJxZiHDkCIh1DO0PUleCV3izXcfdwxJyOpQZUFe+P7bTx3FKJcgeZzDmwOk1czvqa
# DATA JpDzZUJu4BerK+p/3MeXX375CkxMQgEApGroDQ4RNB6JhTOaAAomIp321d0dCAd91wHo8j50WnWjU1WVLYU5um0uJJtkHw+DerKy
# DATA pKO+ZA9CBqMS/DXY+2ldhkeGntF7lFe7q/Zo3d/EGATG0+Ld1jvoBwNXDv818Tjoyyv1ZNULMqLMvHQBxioILJWueCFGygQT5lgT
# DATA Dds1/FoJZa09JbZNxh2SzNJqNSWs2NE4Lzou7vRxo/bDXY1gshqbA7uRZtEzjXrRzUkmFNd0/ZiRDPWEqUdM3NmMXmki7scYDtQT
# DATA 9obrp9jYZMVqkvmdoWJ1QUGaKeqBxeYCrqY3UoI+zG432ubYBmZG4sRPB90+Jhk4R7qC2DRaH/rKCqb0BfoqM0RQCIoDKFJr2zJO
# DATA wZTx4kURg60pjMffyZrpMFojikq0vsuJuJeRMER7Eo7vQZ9wh64MXltZgWARQNLJORwEAb2bg3tWstC5l1jiE2pPWoMqWr4qNfdV
# DATA +gHH7dFk3O1V2938XnOSQwo3Xs3qAahLf+BQ6CvJxQtFx6+Z6U21Ow4OuvsQ8wQ4vveQySox6xjZkr+hbb4fVcXJqczHAe5X6lU4
# DATA GvomSLI6lyAlglx9eaz2P/hiupV/ByCUe5McC0OIMGwgRslWNDwh05bsfQspWw4QMlvFwo6hy2VnZfEsSB/upcjcB5PxcBLJRWZ/
# DATA sX+kCKCE62/tCY0Ov7q6SppDBJ8PiZH01HR3KSI9E2StS8f3214Pwhst5WirXYIgaf1ZObn46qvnLxZH3QK/wVrmhRxHVvKBmrHx
# DATA aNKH1WgXRBLTjFYZCB8aipcz01KhxFcFZbm+A0UfRxHI8EFePchP+vslKacmsT8ouVZFPMG0NXF4EpN6LHWJkI3De9Xf5J5AigJ0
# DATA CxumlpoF3R0Qcps2CtwPq+iqyG4M7D9IxmpxJtxCeoTKwVLUhqB3++3m1gY+74xG/nOWfrrHGJYDFpgWaFGrO/CktAqeuFL8XrfX
# DATA s4pX260OxdYA27Ke49VXAEggKlQV0fpwJ7I/CPOfIU9KL2h45eAK6cOow74EEpyMPC4jXeKXSx4Ymx5qyU74Y7ddxRB163W72zrs
# DATA D9RW34dlsQqrpmhzrV48f+mCn6ihTF3JlfjYUbfAfTfxlFOJ36L2Y5FyAIVSsoBPjKMd8Urwtbs6mPTaDButRCwUlYFZoIxnjwEh
# DATA A5lPO2/sWyBNo5+fEeU2ajIGUHPVTlzGWRmvtvp46VCHTu8EN5Z19lw2edXMFpGkEG1QnmNSBagpvC1pQgec2F5HcZstesA7RdwE
# DATA wBfFGqUAdKtGezaxInHvA86PTRvkEonNDAdANfGzrYCy7FfBGhKryfutYX40sDdFCZQGqv+Tvr2d1c8yMSYsVC/gUXbo6thTZUTR
# DATA b76TrCccKidkcdy6p+6LdGBCjB6YVnskuiFURbdDVPSziRKXIGtIpzsEazHXtz846iACo4ytmtxWcwcexsm9TmeYuxn1zMpTwgzF
# DATA hgcTQMOsSsJ0jb6i5qBkM1d+B3HCPFBRTjYgfwO6h5MQpsRdNeJOk04AfghoH/Knt7lMpxwgKd0ZZhaZlcTN0y9utgl+KOhZYudl
# DATA ZosvTLWtgb496fdRBoqkFqK0dp+Aeo7+RPAITK0T0+Z96ajFOR+ajYqO6YRI5/dRUTAoDWJGclBWMluFUdvb0Kpx+BlgGOFDFqON
# DATA F8NLtrKakY5ezGYK1XumnrMlHvXm+NEsfamlbo/cCfQtwPK9wBRNkPSo2y/cqa6cAYCqmDCIdZGKynHK6SGrIxuu+xrt6ZnGeaPZ
# DATA hslnhWyBFZnqaxTlcozP6l8Q3/vjBabP6HGCSbTTSKtpajNwusU0nX0WyGiuFh5qqBIfhGO75t02rhGTyc2Vud+mrJ/qRgUXikkX
# DATA 8iIpPpi09nLgdr3OYQuhKwSt0FRmyBkPNBKtliHqDQ5T9Sfe0lhkyavJTcgjlOQP0HSN3LKHAINV/74149TXZigcKEkaGJPl0IPz
# DATA utBm8K+U2eQT2hdk1LdtUE+jiytJzAjn7y8MefCFpPaI5k9BqATKqvAbjb9VrMHz8x7tij7yHNPQ6LA32Cul59LMo1jQ5XEmzmqP
# DATA cNNi6ZKisGs62662crrpd7NZE8lWFQHcgxyWjwAUm2AhIKnlXzQMG9j+Hofz+jS2aWaoFLVWAwat0eGsEbIKjm6oRRpGVN/apgBL
# DATA 0Vs44N8XkoRQxOPnv3z+C0GlimLSAY0hUaBvoMuQvQnAAXl38WCxZBZm3s73KZ12HwDZSjEeO4N7I0Czw6bRK2Ke+T6zYbBx4kck
# DATA dpfwLwnn8NMqep65Oo9o5Btnz5BMB3cp2DiMrmghKYJypTuY5GnmPB5RVuSTYEcRihlh60vNtgGd3sd1xPRuQU8ThkvDPV/nX9xl
# DATA SByIlldXaYdgal5ZwmOLlOYueRKHFi0uXpjihQKqnL3RvZMQU18I30OML4JcoYwYir1+Tk5SdrJ5AWRRu+cTeBR21ZkMIDKIpUAM
# DATA gmX1avnhqHXCmSFkUWj4x4SPCZ/sTfrtHiBbLOzoYzf60nzKRuRjmrHCCfutN+onMmZK7cvS6lPJPEB5gO1DCPISqAnkbMCOGIcZ
# DATA gb3EW37yaD9xF1b1RGc1QJRazj7rdzBOP7IBmVIsNqs2hZ0h0i1H0u/MqYqcxjZonH0ay9xYyev/QHl2AS3Og/w0NLak/f5yygUI
# DATA iwyhMFbawvUE1W1KDEOBQ12Lu7beGRzvkuHgAVzrBnkOKZMxp1xrRFaHfueBVRndASwXogSRcvMjlGgeHEHSBblNimWw1T9JWLUC
# DATA PrRVS2FDtXQJScjCtgLJVskGeH47cgMK7UZWCI4Ny4XD/ox9zq0GHacNhBoipw38kz1BQTUB4JuMOlzzDQwYgoFKLDX9qPrj9H95
# DATA 9Vbz9rVbN6//OHmPfolgrh/cvPXmrevXb73rkuQ4xlu1VtQ06X4V6EisL0llZX/JoL2g0m2qi7y6HAtiL+czqgUXxa/k7M72cJ2s
# DATA vBhl1/vmuMVJPtLbUnHy/73/O5QzJOmZna8ksdPOCwahRKSiprYjwiMdqzqHT7ELWJVQqEqef7eIE35KhyaDJO36wNCEikWXQusI
# DATA zLwUEfC6jFGOLOTBA59pEbUuxbJxyuQSHlch5kBebbUpVJM2iNlEluUZ23eSzFspciG3kZuAnuJ7DfesLRW3GvuS8afUlRCZAS2+
# DATA oixM4Pg5rjb60D3/UHJhIv24OWOf/Y8ZeQlNDk07q64X7obROXillLRWkDno3G6a4NcBQ7K7IfGCjUasVkB91YfTn8jvEXLyvC+I
# DATA beiXNbsxYmN6QrOGk4ZQPzdzT/P5Cpg6EjuQAa4rKJibVEKfJ35C6GdPLnuwc3gQwXrJJdBLPsgJh6psJLFahxnAD3EHf4Dj/iVg
# DATA t1knWzURrDs8JVWpzzHp2PukzxFMkUcFSQ8VA8+TSq8V5kggx82/qIJ/IFB6nSexilk8dPrvD5wMghjqhAAk7BD/GMmJ8hOKu92z
# DATA p9WwwZRo0U4Gzt9gMnCuFKYWKdRQJqt0NMpDmKHh2f9tEGTV5cz1psU0iKrKsEKKcQ9rg04+IbL0PXMVcYb1jDqH6jYD14P4oGm3
# DATA QhXq6lhL9tvRTaceJqQdluxRyRAjBtCUyLwettYkl1SWGEga3/iNSGSCAYkoRwBVNI5GRbKHVMcPxzrDF4V9lyVCu0xB1WWexTLf
# DATA 1eAPiI12oxhc5kYuPfGU5bg77BxNaHSMzJfUk2nXsiEJXSxvsE1+XpL4UqGexOQyj6cCd9xokTH7qhPJZ/x7SFxM+QFJAMcN/ubm
# DATA 9Y1tmOFA2LXyGof51z0saDtttAzZAB2r2XCPFd0orBNgWIPzTgknPeOkHHyWIYLu7DPn+S/LwHV+bhI0P7XTscYZeZoayjQ0jORJ
# DATA 0dACgeMYfPYpd0+w4cAd3NSiBuDrCjC2Cb62rjBiDDQv9OJ7hkFspjNCbS3qJegT78qEU/WKJOqVntAqmiocsa4oUlrtdfRxfh9x
# DATA o2zZzRAFCjMF9WbuImdF7eBxKmd54qaR0mClpg0dRGDOcwonbfhy2PzeFctE4YTCdPybS0VwpC08E4yv4mnZMCGdPzibHd4ocCpC
# DATA DnLYmdfj39PxjDT/jxH4rxoLMoedhWhiNl1YOGPexAQNLEocPoEETURohRrzJD6z03kHG3EtODuXg/h9dTRX+VLLuzrbrZ1fc0+W
# DATA uXs40ALx+ke3My8wUcSkL+G+7XRepRYBBOM4w3IvQu/xZSVKj9W50FY3oy7c5NYQLcitZZRdbRnuL6TB8s+Kjxh/+H3UTuHQEvzo
# DATA iWSGf/Y0lBmllR+ENb6+TDYrhpuqnFtmMRroFARpT7aMZqN/9rQM2iitu6OvIB+Qlc39SVQrF3YWBCGej/9YQB4llDSmfrnEzxI8
# DATA 07KOkNfT/ojTJoCIwSX/rKOqHKTkUMz9vXXheMI3mMeqb5htPIGBY4c+5SsE3kTMLPGFUEz0kkVc23w87Z0SEySU9vnP5S7EpnVU
# DATA G2o5xUqHxTKM8Iq49IKEaaQXUuUgTBPvWvTHHqEv6CH+XV0fHU6gqS18ozVBasfWm00lgzebmfUlXNGbLf6klA6GnZGESe0fDUAv
# DATA UmdMH8z1lGIoWY6GBk6ESym4EVYGZJwKi9v4jf23zqmLcQIpI/m0RoJ6h+m+4O9Dwr0j/pUiJnN+VKHdgmUxwY71wOFKgB4TPGTU
# DATA zeA59w/9USqToToZKa4ZEKe6YwH7od7kY1CcW48Eta/CmAY4Bb1W3/J7wAZZO+o9Fmcq20tixM44uiaaUWiowh2wJ6vgNXc+/lLG
# DATA QW+dycBkFHq5DIoD3oNQbygODFHSqVTYppZdLirAJrriAuI2NLMZcxG0adQTsIvbMKfLzFYEMWpGZymhb+F7Wuri90xKBJ4+sy+Y
# DATA MXlGTSN2SoLIzNFhXgdN+cyxKdqa1TFKfGtWo7CkpWDSqz+rYbNTOFawns7pKZKp+qwiaS5baCqrp0jGTUyRObtJxCMbfPU6AByp
# DATA ckzAB4bsitJNNKwhmjILtsIgy7oCzHxxeeZ3DMoUfEpZM2Y1S7zRXZLCtvzqEYR+NlOIMOcFF9/5lHbbYr10xdSgy6src7c+nlRm
# DATA lXWeeNSvMB61rpHezl/bM800YIYXv+UUcdwoe7dzWfwHSucGBgB+VfXhrnOA8KFupBI/tSPeJPBj5GaZwI7Fq+RTouZqcMTo5NdV
# DATA TqwnFKI7u3r/XKp5Ucly87Fr9MEy0VEpCGH2u7brwPpZmoBOv7XXQ5UJZCFdDGcE0UwMpIaiovXr1138EcesJHkB8IKCKjvn9dDA
# DATA qaDPs44CsJcagMhgyqi/Ju0M9z+KFuyEcDud0Ih0ZhQF6eXhszYAjGBSAxjdrFG2CSGG4/wXm00weMdyJRiFobX82sTpRiLoRXTm
# DATA jlWaJ4oiKB06lSLYxP4gnU2ctpBqppceNOFlh9zfqwZ5YWZ9viR5JmJnUIgicBE+2JvqoKLv+UFWTmJdXHBqrSLi7AcdmD3MmHRs
# DATA +U1FfPDPyDRmytnWdYyL2Y77Uswd9lkW0b1YWOli8hzykvILSfiZh2NzeCRzTfzBn5T1dp+Psm1qkuXW7IIfEK2X5syodzmyCRNe
# DATA NPmF1WnuZXwGiwY0uxP+fcxWqJNY53TjLJsucnHyN7SY3Yt2i73/KBEMIiVwdYstMz7h5rS3IAMtkcqw7KnqzaY2n5l4BvdTXvcw
# DATA E4LpCN46sgi34PtB03AN85F1I2g6+zNwCJ41tHIybwSeiyO5eXb7w8nYQQZBp4uasTeBkE7uhTXH1QtfTqO8jGJ+DCebwerQy91C
# DATA ly8is1kXeCflGpZaiIIW2rIzm+Pduxi5WpS60DYtVDeE+5Y64ODvYlGrG7gYZWsLcr/mmDRVdfN4m6tbstaCkjrT8zOxFK0tq82i
# DATA HilVmnc0W4jXUTbKXA/tT3PGGuivZveQSze59KyehjwEf/CXc7plVIq+yFMGCHpEmpEiMdI86wxyegO/z/psxJ9yMgrlB8jTM3mD
# DATA Lyk57uDWVrocB4SG24Ya+OW47xEI2tqAYjVrg2M2onKc5Vg+51jUit2ZJEI7VxUrzdqZWsgkTHP6QTix4dyCwmAOvYQKhpov0mt1
# DATA eogzHm/S6WJ2lg6IpnnBPkg6qK+7G3PXymlr7pJp5rnABX1u0yhhQ5PFXqYU4YZouxQHYJHJIn1ggHuzBvMEtu4xJsHKT0ystfq7
# DATA Sg40fRDWSysWGHQT+Wuzae0xjpbMgjo1srrjNDRcprwNM6y7VsDCIiiLEGj6GXqxYUatMA5Jd0RyZ+KP0rAsmT8cYtOfma5S2J+L
# DATA mnLZeq/De1591WeHqozjaOWkPQ/ZgYtGr1nxnNy6GgF4DomQASo8XYQtUxLmhY5bncbCPkpmsjfKuWCNxylYxAIi+csiL+xm3PST
# DATA ZdT+mEb7A/tdZHKjC2E/dLIA+EkevsoJ5VaxASBWWxDeSYki5lSzwCl8+cXOQDFWOgJzkNkgED4WFktEY6ftFBWEWnewKcTlTjus
# DATA opfaX3RWZPBRmwXpHOCTav4w76aS1gIVI6cQijGPoKydc8j5IJpsSL4C0qpRwkPD/cNStAVrbvpj+1UWU4/Wku5QzfAIEBy6Qy3V
# DATA anUKZ7q3o8KLJgmRJpd8z/9ApyxVO6CjViwAflhGBPkQNr4oBsAXLtT+uM95ueGWTXEBFlqLkzDE1GDFDxRf5dAeX5srxS4V5F8R
# DATA m0XNU/ikZNqpWTx0Gi4Z2zht5JNaLJcKl1sPJGirkvnS8NKSareJpNRs4vCbTSDSZpMnwAncIYeMJQsOJwRcAVwcxEupzRI6ZI//
# DATA 2/NfqM37B3J+L/DumesKjs0p/oIJ2kCcoWByC84GwWG2T/Jx53iD8iLagyj9EKgCe19O3umc8F+Qv4P/vLXNfyASx99u37p5DaF2
# DATA 8GlmB6VtomoGs0h0+/u9SVuQzjA1RF5L+hhZj+NPRp2fErAIZ52HuLxJr5dAA9VvePqqybN/NyF7zz8mWA6GSdCRA2UXqeOXFPJo
# DATA 8WUKInDzpzz/JSBKnWk1/up/zf+pXbbXg5NTbaPq8OQbaQOC4i9euID/qv/5/65cPH9e/43PV1dXVi/8VbLybUzABBzsVfN/9b/n
# DATA /15++WXYSIo7kilXQv8w1E7y0JDSrQuYgaNOr9PKAeWIIkxXq2vV769Vl5Z2jsCH1y74s4kS0ZPxkTonEE2OA0QQA7R7CGltjjq9
# DATA IcahHAH7AJxC9XYwOTxawkL6QpHsXN2qEIjqQacFIEVoRoUYWdNHTt+dHLXud1TvOuBZDlbLdlX1rTPC8Nu2OlL34CgFoK3+QJui
# DATA 9+1DAhFbH3b2JxT4D8BZIFESiOESAOnOO5IC/pHuzBvPkTqU7E6n3xLHceJz9n+a/yfs/9cuvrrq7/+1lfP/tf+/jf+lk7zDAnZ6
# DATA eWlJbYR8nJwmW6Nufty62uvihZt+JVMMaMBtXUr/ZogPl/exTJpd5m9/+mBsFwNx5EFnj0wMmW5h++qtLUwEcguTTiGQ6993SruU
# DATA xCPHnVMTOHDfWTSvAeabEk4lBzDn/gh84vl9XmNH1uICIOqrahrQw4NJn5A5Rp1JDqdjaTR4kHHKEsmvN3iQ/PVfwz9VzujixErb
# DATA DaHXe6pKGz0OfNZ5OFQTtD7GT/sgU733XuK8eB2z7V0DkT3Lgu/zfXUpyKuKrx4irEWd51SevPeeI5Mv9M0ryaqMiouyhJi7kSs4
# DATA n5nbKa4JZMeTEn6d1F+PVoW/MzXT06WlFkTXJ3rG1TXxfhfuIiWirjKm2pC0ZbIGoLV7afnvdlcq329VDhqnl6YV/feFaeWC/nFe
# DATA vbj0/dZew3kif6+uTb+7XIXE6JgZEuYf8lFYEwdpEgYHkjTtJdJyQd6JFArTY5m7HyTn1zKAD1WUAevG2I6bfby4yzlFB4z6rq02
# DATA TbcFGVQuC5ieohuipdmUZJcXJzi4VYHDWELTVm0Nu5j8Mq8C5NWdfvdnE3XvSx7AOVhT2xvHO02m3PjycnK7k09U25gUKGnhgV3B
# DATA O5lAbpXFMQOaQxo9wUMYICa6GBGoetjqAW7DYJ/P0YNk1D08GudVvWy6w4rMXtL7S55mssI4+f5UshNYgrwk2T9q9Q877ctirURp
# DATA QNHPmO4rdsA1ufXSUCmFSk8tJ9ReNzOoFrRgChFKGaYPk5lbPSTahDUrJ7Jra2bTwn+q/cGDEkQNrK4k55LzF19V/7108QKec4AZ
# DATA hFujluxWq1XaQByw46zNDohQg147ORy11HDofrY/GKmRDweQOAFy9gHI2kSJTWodEFZYg7FV1dqCSCG1DSjZYAuop7WvMdkQeNZZ
# DATA ZJDBukinY1pqHCOLQbEFlb8XYh7WPNJKFMy+KC2Idk9hzqdlXIlTnj1r8qZTZ5mZWasjqQoSZ+mUl0ydeSNYthoyXsA86UHQ0vrW
# DATA phW/0m2pxbwBZoeD3mAwQgZKpNBex2Q2ABCMCSVXcTH1h6o7BRz+jeQUAO1aoMauAQJ0Z5ooglIFg5bk47ChaZZMy5YzJTChstrT
# DATA rd7hQG3Yo2M1kre3wbECaWgGk31zMNokthRlt4AI2m+j0tHmvMFD2VD7vVb3OL9sYxurbtFTgAhVq0DGe1OFaepUdx+2Aw+goQag
# DATA tsI+4EupqpbPJetJu3twQNCpqFhHiEzFcu4pijdsFTK95IqNwV4UEq4m55aTqWP64b4p0qW/0MJMZznQArzgI4DfI9+s2+eAdQLi
# DATA /vo6TyWrUWe/GP4/c+fYrF84P9RVs0ejd4w9L47gk+k8PcHhbNWjz2hT2zTciXPOd6RW6gCKj1VKR4b5ptoTtTSKSQvWb2t0eJ9y
# DATA OdYBGlzmh+aFagecNbVvlBhy6hJlZCYHJFkCUDfm2i6RzPtGlar6IalI36iSuPtGNR/24F5XTQHeNnnjDcgW9Ho9eQ32eKAbVlLs
# DATA cAz5EIEeS1o2RuSe1nC4jLp3GmK+LII1f1QZHqZZlXqzdZiVTqPehWoQfYIu20bCrOl5Ugdh1c6BXIYEWrVkrTynnh1C+73R7SnZ
# DATA uKZYT3MFMFq77V7He3WeXgX1TYErUcJ4GrlqvVTUrayadwBGdKs1aimSomBpSjafwfSmGKW3DzzNbQk4KGQPUtSupIEIiAE2bd9n
# DATA SrzWNqkKj3EhoXwJ5Bp73iiBpwtspvv3JOiAiASiCLG3xEk5HW6IrMTPZjFie56MNX77zpXtq7c3t3Y2b91s7tx6Z+Nm886dzWtu
# DATA cciiTRb7coCmPqO62xt3VJexUqMJrYJEUSKJS+0jDwaelPb0lgMjrU9xSmUD4jZT3LXaoakswkt99ik8QnQ2MKbrCPd/sjAt0LL2
# DATA GWY9NDHjQfx7XH38m2e/Q+NcHPnNRyupYuCHzN3D7vgqWruTVXUsWSNlFDAeKzPi76InGW6nEt12aIfD0T6g/EWnhgTKMWooyz15
# DATA ennpW9D/NM3u/1pVwbP1P6uvXrzg63/Pr732X/qfb0v/u4VylFl7cXfFFBKgZlX7Fm8UgfrEuWV12uoGhnnG2BwEnPLiBfkFiiD5
# DATA e5AvIcgzOPX0untiPwJ3Aiky6shfYAfUf2usf3ky7hwP4X5HFU5G6kjao7grqRV8N+CwXtJVU2pZDuEm3yp0a0XXY9LgHrQXgRYU
# DATA JEHz++aV67euvpOZ1GmAINimvGltCPrlfDmUPM0yQBLUMuINAtAyvfeysFh4Y1Cout3c3L698VbJBut10HslRSHk3oglozBWxVK6
# DATA efOH69c3r/GpAjHwLr6NB3NJsEbSEIjFjJZ9uoJTpQ7wjnpayqZROOGV117L5vXI9KR5A06rKxvNrdubP1zf2XAwr/Fo4gk1uUZe
# DATA 9XONaM+5Jcejm1Ye/+ukusEnTCLRwk4OCct3AN+izwIuRU9/EC7EnEUQsHwi12rgJ8idFjImxxuC75S7v3Z2KeyuKSk9puA0BnLn
# DATA EchvGMTayoVLmBvv7l3Mm2KXhVC8wahd2s9AH3YeHvFPJaWvrr1GMWj2V9ki07G1fnPjOklTS5SKHV1E7Kw6GCbGHYEbQWsyHkQ8
# DATA JGQyCZfFB4fBG6WP7WSnueDZLJ2eO8deChK7iKEN6PbgxCtOg51rquO5foE8F/HZUpxn/brM1c31H65vXl+/4mxjnrecQi/tVjmb
# DATA /HZnPOYM8rp9fqVzPfu1aQRwZA82FJxuTvKeM4soYeJuhHcZddsYS5z2wW8wc+C9sQ1SiPq9bR13yBsVcOlhV0MKYX+mpX+x9Bjp
# DATA 7nrlJ63K3wNctfmzWa00FP9ShDpNSbF3pkm/ubHz7q3b7xRMviHPJIWQ3trysqRKNymvAO6PSRS9reSH7dmmJ4MXCOT9rVu30T+X
# DATA osC116XtYmS1r/+E9AjYD3sfU5glRh1zH+UV1qXOU1WFnKqGNcg2VG+qeHOz11tVhvghGOSs2QwUBVLAOVDP4Lfo5uS3oATK759N
# DATA OpTyBH4cjFqHKHzowurI1a0iOi61hi/h8Fe8YeVFWI47sJfqMhYdz8vUNqvut3d2tra55tsb/8edzdsb11Ln1NE625Eh67JUrTj9
# DATA 1u1bVzaAjSkxi/QWkhtWXSbWJ+OjwYjvpLUkvaIu1IrNICyUf/17d/2HG831rU06adT1Aj2ho6X0TDAU4bsARagpmBRT3Ivd9EcV
# DATA dXt50Bq1O234C/29UrWfqivq/1bTy/GSW6OB4taNRM8q3JY8rSWQOgpo0B6NvbWHK4o39HX4+yrBFvUgZrmsU7rlpEGFwHe6oOF3
# DATA VfwvlLsEWlV1IxfVEKvWULmed7R+7aADjGPOHDF0rGKfPFAAsiZX5VqKV19FlKCLbvVq1A36QVo4NGxJw9XBPbEnMf1Q8EdrHzpA
# DATA egVQu4KQV18BjIRJ/15e323AC2DD1O0SDQffokVGqt8btE/UZMLnr9TxNZuyLncPSvD09QvnMHUF/Cc7dSbtcqRfUrHq2ZT6Uh1C
# DATA rsErE1DYVkE+L+FzdRme6mlGv7I6upNRQlsurt7uKzmYKsqq4wHptVCaU8KcmS5y8nzvPdHU4u+X6vV0gJZltNRRoapeUq+0fmF9
# DATA Fp16a4hLes+6VagXU0EFT073e2oPCvEhPcLYp0slJO5SVn9dE7MYu+u0bMjZl1vD7jIZw5e1MTy7rAZe4v7LU/HhhBGwajqLDECD
# DATA VVyWZtkAHrZaZCq3vlXV5/X10ah1Uu3m+C/HtefZG2JY53+r/K/6VnX+JfcjqCeLddduUn0G5XZXGm+QRnzhHi+nr2AMYufO7c2r
# DATA EkUglbF2XTGcrJRplZVaF19fZemSyJnRQj3TOMWPAJZMa6eg1Bfks0jA05/Q06hmCg+HcqLKINQZ5FqgBC6kCzMNICKzjf2IeWI8
# DATA 3ZeaMl9tVV+9DFwG/ZfwyqAK7HVKHMJg7gF8geFDR/EVijEui4MVi0TFN6jwksFt2DcMfDTrsNxaf2ujuXkD/hvKU5SVnK/+1Z0O
# DATA XOxbo5NrEhNSIqgKyCspKdCQInDIFbqCHwx6ikE7WOkSm0SvMo55FpUYhFOZDrNgRipQhLJOI+dB3RafSEcaOX+xlKNGjYnsJV4J
# DATA J2PMiwjuQaoDtIVFKi++i9D135ey+U9L9KeCXLdJ+hdLo4LEZVIXNhDjp7OPmV8hlK3CkNLoT92/n2nK3IUqG4I3BsXhvygqeWgj
# DATA gcs9tgyOi30UI6yRqAuNWthRSQ/E3FayxTrPuNWVCkHyVSpDdfvAq06HIftsFC7qRTF0RNEc4HO1oEhgqZkE3nLRuRCncu0zbnuX
# DATA W+k0t/Wfvhd50ZYFql+/enVje7v5ptqxIN5SOje8pxPbAT2hwT/BrAtFzIdbVCzrNp216nvFjztt0LHfx8TyPCekfbyc5EetEXl/
# DATA JJR6QnGgEytdJnA/y2Odku/ADWLJJNWLAxNxsioXiIi94pXwHdv8ac0aWRrZ96oADni6JFkkoC7TKWA5mEEoL0noFHXDxmXFb3nc
# DATA BIYkwA7RigbjIwDaLqjHzaXDd/lygh+ZdB32xFShJsA5l0v+Szr/osyVgzaBvWCELsLmOE1xqdRknE6nSzrnOwyo5uU73E2tizBe
# DATA GE7PnRNWLAH39l2ZU9xJkhD9KWgazp2j5ZtGLsvW1IlvsFsxYVGcpugwpbouBJ3C2NVv+GdaTgKyKTPNmKPSvzeqZ3av+X2TklHN
# DATA 34LqvBQ9xA2I3b1zc/vOFqgH9F0z1ARBBhYbckreEuvXH2FgXEzZUzYQv/KpTRZhZBWlWYGjgaRnGilodVBTKNsfUTLNAQ6wko6W
# DATA Bzpk65n0oWS1KC93Id5LWjaHFT13OvBS3eM/C0731Vs337y+eXUnMs327GJI26k628ag6OgpWqH0utR8Tb6x5r01HreAewHeQkgZ
# DATA iJ+ccu1eYlNrHqQSngJ3ZPIy7Od0VsSa1TFwoC1BzXjRU9/mpd1zpk2Y5CwLdrMeAsaFcWnHYQSxXIg/NJz8ScjwS/imLD6AHCJY
# DATA W3K5lyZOSoXDlGnxFrUWkPkO7VXVvYsX2HKA3+2mFOkASZI8iwIhg5P3ISrN+APiCY0CWZH6BG2W5QPc242gOk61+K35/3P459ce
# DATA BjTb/ru2duG1C579d+3Cf/n/f2v23+2T/r66e/fBWAjBKeRp43oeUyZy2EMtO18FueAZUG2Ur1DgwywhD8eWdZefcL5DMcYe7PfH
# DATA PfkB4HzqC/mpw4K/VhsyXPhfxFr8zsaPQUG5fedKc+vOFcXom9du3VjfvJkurW9vb75188bGzR2MfEBBBJJOjNK/K71RI3eP3eTu
# DATA uPFK9kbwOb44V6+e+y5k4+5Ub4BFb7/XyvPkGm5HOmrMqaPhxtW8EEPsD0bH4IzEHKvQ1seHr30NJ9bIVj76Onk9eXV1jfwq2SkL
# DATA cnveze/e/d4b37n7cGWlcvfh6sHdh68dNFJmYYEVz+56SgNtsmqdj0fPjMA82rJH0JPQGGEFSBcq5Re0JTAqCJkL4IpSTi5cOB81
# DATA T5x9gPAljVBXUiU9VCnttvutVJ8nWbUHSSDZNO3czp3IeP6zBNU54cGGOCygFaCP8NhetPegEgCawLbA6vsqWnPTqs6ajeNTj+Bf
# DATA NbA25SgCl0jIN4bpVc1faPDzcgyBirrXK3lJZNWOWXko3rCvvAd/qX2TAqbRaJzxVWKke2A5Yga1I9BG2MIu2/1US/wnWv0urk7l
# DATA TfbGQu29ANVzpkCxVe3WKqsNIWNKGyUTiZYrpH55J+vSE1cVWJYLK7Qs1VQuV/CbroAmA5Ez/mUe+HrlJ2qw1eY/VBqvqEfL/rPs
# DATA HE07JIc6+0hZgEMqIaOI5XAjLjVDChpx5DY7mSI2bnOzSLJESS2uoUeAEcCTRfqsbkfrb8KVfeftNLL9vg43IN6jgMByczB+E6Ba
# DATA vK0K3jU8E7WYA6t2ctBj+Ub9i0pndzBaWbvAic7tt33AUoLVWA3To5pSZ/cdWluLXswWW1/M49Yat3yfIWsIrySrmb3ZoHjmDvPF
# DATA aIvXE+pTm+FvPIkINkcP9IfkmeJuB/FVqeqAZ2Cs99I53mrv3haivHp7Y31nHsWW7fTuMfpqvVJAXxG3tEJi06T01VYxUGOjLAkx
# DATA NPv3uM0yP4OxNTd+pIZr/b55JVCJXoFvu/3DzVveFi3o352ta+s7G80rd7Z/7Gg65ZOTbqfXZr7Hq22vrXglIWYHuCTlJSTGmY5J
# DATA mjSthPMmEQfBcpOuBAHLTaGCTFPF037z1k7zxvrN9be06kjrC2ekErbZtUlWHfBs88ph3KYFp0wcm+0sFAPyF2YijuE60mogQJRV
# DATA xsXOWrLZo61ggooZLEikjtXkB3VkHfgyg1+rF4vEE68uFtDh8I4ILnRAo6PSanl17ZJ2VHI9r7DZWINWYzzeoq7za+z8pRekF0n/
# DATA fGqWVbKI1UgQCF9YYgHi2k2XDDIc1jU1eaSxi5TvDTtri7/INu3qqYx/CGhxZAZj0Tjv1kbFQyEwqdiWlDv9bgyBZ/YcXr11Y+vW
# DATA tqe2jXCW8HYXzaSdRdV9Z2zeiEOwnLswWaCvw2PMnSLzkn4v+aYETZzRvAdRywuOCEnct1niiUPlYgZFL3lemJI8lkAc98FuI9aU
# DATA 4zXL9URBwvyWdvUPt16YFEIBQfe7IIO0XVeEnkv47S4hazc8dS++c/KZ45PQykNrKk00ZEfIA0cQoszXShI6v/Zi/EAEIIPdyNyT
# DATA J5OpSCyFqg9426fNptUauHO7uYc85gvLyDVx/lE3bZQ0GBiJxl30nPGUuplzgHElxa0IxhwX3FX3OfAq4VtiXXGz1Wx3teE4nwuI
# DATA 3G4NLn/gqfiyKvdy+rJFRz+bDFA0oIIrdt6TtjzGgZSwZFlEVtKud3v6UyivBNqa7gK7SkO04gqrV1KbrcC7HyR4rSxhTXKNhB92
# DATA OuL0O2m2MGNxL4f2zFE3V2uq3UZEYSHFQBmFk6rOQdSlfUeUTxjRiO/qqxlOvjXXtpMWk5WksijNI0Pj6YI9MORIeyY8uhru+oY0
# DATA KobQMtNwoUnCyiQtlyPxqAp2cNg/urBI5k2ndT7KTH1VskcGkLezGTbdKSGjs+VUHzPAzuDnll+Ja5oNWzpIQPuKCmhosxZ1k5B5
# DATA oDK76ouG8VSyU8w457t85StRl854rDMpSmOkTUS9BkvOhx3UB7KOu8rpDrKlOF1wAluHPKzWqDoBR9BJFUTBCIgTeynoakFjWvLa
# DATA RPKoUhXED4SjCp4j8YW99Lib5+jv42ym0xQHq0Q4HrS6qFDoonrEPTvqPJQGJE8ile+2p7IPjd2Bw1YI06OOIQCMpAU3Ib5r4MXJ
# DATA 3BbMHTW8NDt3lYLdzWEF+kpmEosQsln9DIzC5p80iHDvWxNILQQ6F1uYw0osc3XeGfNDvCbJEqCT1BAhT27LGkxj2hb6djcs3YDq
# DATA qEO7Zh0bi0uMb6/ffGsjxtjNjpLGqc+UY8p7FlKfI+4eD9qAK9c28v8Ls9NZrFQL+o44u1TkGDODOb6gVGt1Vr6OEtJcSfdMTNoX
# DATA hWfx4hg/lrtjgUhd3PXik7J4LNXhYFhSzfuhQoHUHPX2C+vDg0LkkMLyOq+a74BElQTfsU8BXhjbk+Nhrl3eOv0cnIla+X63S4rv
# DATA Mma97o/ra5JfeAG3RW4AmTnM/16aBg4KsYMU98BL7k2CpBct6FmiMtv/oLGCZSykPu6gXdlkD4NysLZg7WnXe8WBzNSU1LXhj79e
# DATA mkVJmo+80IC43/CPDsMBl1xeGvVP0KnYqoEbF1ShT+SX6MYcNiq8Td+dne/8G7+UXuRg0SmyRKEoic5ZP6jukLGcGRUYGJjJ0Tn+
# DATA QimD09zpCNXjau7o2VdT6XK9lN4AVMT1lcFrADtCKR1y0ggVONaYRFXHrX73AKQQTmFlPAx3ne5Fs1JJxiF8aLJ+c84rTEho60Gi
# DATA 55bnx2syXXmSmFVRZotMCzUyDQR27G1ZH3Od/uQYwU5LQjRm6hpeiq0xukBbio9Qu24aKJlDN4s3FBFZLfKJmQBxZYGOrHHHN+hZ
# DATA ZBGr0YL5LGgjTlmlOE0wsjfXHmgUlmbXbiZz/pe8VJJWzdVbihGjlXc28E+IAwzWUKhjBG7ouZKbuc6zLhWhMlmcq1YkK3gzP/ug
# DATA R1vupE+q/qWzH+yxuV14cYxx1WKq+hpwzrkv/K8BCe74/x13Dxnf72t1AZzt/3d+dfX8RR//ZXVt5b/8/76N/33npeVJPlre6/aX
# DATA IWhieDI+GvTPQ5TYrSHknU84MyqEjrb6Bi4zwCV1oCMBi9PzCmR3utboEP3tlrRX4PCEvPFAkwE7Vzzx5DcF8v493Aa/shtgAB8D
# DATA KQsESQa8/Ob7BdpehEsvnJkqCkXT7tCUqhPNxPgTp+u19hTbC5EQrjIAslGlXceSTsyXbbWlirTVuEoBS3IrlDwtVfDKVgvZVJ8S
# DATA 0IIAlsHbhauxPjV34TmfSqiE+TSwJds6aI7vt4ZYh6B/B4zkqDVCPJI1jUeCT2xIEvUAzkSTj0yutDJk94ZbbA/Q6A12Chwn+w0P
# DATA x7ftzsej4Laz4sbF4LTgItONlKxODKfBdouyO/XaJswGIPWLJlNM2PR8xqyI3WffUqbVLbUad6mus3jxYOv8bzkWc6eN83VWx2Ew
# DATA 1R21M+uwC+0bTCY4ORJO0+p1lZiUm43mB53lHFGJgZcvDJZCj3UsrYRTfKXtLFpYzDCEumrxH6VsQxLtYO4650oyGkYMocGLsRNi
# DATA obwS125uA8iKVSTEw5mFxVKeP7K32SmW0woaKNkz8Af6qqFv/6Jappxr5LTuOEU7t5qvwwW5EPTk1AM9mX67oCcLOBLSs5Lpetl1
# DATA VmaiKhtXaTAJXrhw3htw3fhd41RdWsmKrSc6ZVEBt6D1o4R24wGlIC7hfy2SAoXZfTUDwKjd3VrmMO7ZuDnl6HtshXrO4Q51l5Dc
# DATA LRIL+ESi1KxTgiYKLNXGOMQRF/Xk1GlPdQ6j02hfc7CbhNly8IFq8c3bt27uNDduXpNnbOK9j/2E/O1Tv0d9bjLok7aRgUjXtKIE
# DATA 0f7w4mxwyQs6zDs83y/AUQFtXklmGJRfcvpJzXwnuYYsQzDRcvb9au2PBnmeYIYCHeytQ9jGAwQ830ffSkzSyJX9FGD44ZV8wrG2
# DATA hEGgnlMQzF4HBF/y5WwTPnrreK97OBlMco7L5SjanD2Z4SvRUNqTAQHy+ALLW8/qTI8U8B6/HDMkf8mKxS9Z9Zx5zYr+h/1Datol
# DATA Jwb/YOU4YzlUyWZiOhVZt5iVRQcemw0vtKxnd8bGOoijEriu13oUzEP9kTD3iceEBupvs8vUcmnkK90IsC4AzbpfjN0VZd16Yzpj
# DATA ZM9SgVPPA06ZW6yyTjZpwvtvQhoAx+9e7ZZJb2yUgHmHgBVVN42R2qDXkRmNW7Ez6QEu6AKCzSamGnSkzr9BMG1d1eBBHw1+WGV1
# DATA xIVq5FKz0qCEj0f7o2p3sNwbjMGPetmECwdwMI6TizUJRMrQ1pyVHXWUANLle5TbqWXqVGVVe/7U3LGgJk1/rkWEsJNOyHP4ejqf
# DATA +qDyxc9PdBszP3w9s1niuXQ/7hyDg1rsDutFkJcC8AHBI5B7o36gA+cpkBzaCI3D8gYWElrg6QUC9t0MQXXabuOh6O0yIH5Rq0Jt
# DATA jscDe2NQKYxmrvcU/2m3sOGajGhG9zPtBU5QIRBsrMRuSHiJ0kjdwt1QP/09qR6Vds9ZHzXIEFan2PH91hCyiDUHk/FwIg/HhDtV
# DATA X720opkmj5OGBYpQM0FWjlGO8Sfx17lTQNOWrQ1oWHIwJekQb5GMkQl/TlD+ZSCUfDygnwiHImAoCPEyBbsLQ6dY3qaUeAZ9v7DX
# DATA lKYR450sIJ5OKyfg/pKb8CiF/G6T/aPEujFAZsjn7z97DDhJybMvn3/4/ANMJwnZJx8//wiSQybPHktqydSDmgcX+nt9xSqSg14L
# DATA R8wITh9gSl+WOvhjgX5CYKZPsNn/ePYU4JuoFS8jZdgWZAoB95sBwJ70u502NmjBQyXPPlXf/wXzXP4zgJiHdVxt9RliFECMRMbh
# DATA jrZbnWM0j6X8AOGsbPypJ7E6mUe02NXJUvXg959hDuT3MQPnh4B2pWYmnvhTvYhMdOatrKZGtMsCMVKGQqJ/MmQQBSiypFf6Otzt
# DATA CxHJIyA0huOywbdkAp4WdfVXiU06zx6lfrJQuVCE6WZLB+mzf6FU0Go6Pnn2SForneotN82YXD5FhC/o2C8wZfQjAMYvU68+SU6D
# DATA 7TutwUMY/7Sa2PmoJTX9Y/XPY/wYkMEg8+nzD11nXLO5FLMwXAqdRIDhlAijB1UstmtWEAsSQsp4zlqxoBAw9IYaPKzPlGv194/c
# DATA GyPPNqxuCab3EaaPhRTbf5yPjlZA6I4Kbdf3lxk6XZK4Z5c7kh4Mg9ZwLtwAkqxhz4IuKjo0CW2EF6XMMdUF6jV3+P/dyX/7J82B
# DATA vtJEMHVoSKtyIsNhNCva9xVW4UT1nt6p6LESqxJDNKRAN3pYddxBum6cDgR6kukgiMsRurLuppUD/hLeZY2GYIWw9YLilJpkDWRo
# DATA LFQW8iMy8DbJC1Gnw+Zcp7HzWTXW63SGdULmhj8NipW9SYzhIZZlASLpzK+lQqBq03veSCRrcZiSXfkNseCZeKUwRAt2WLBZUXri
# DATA snrFTEn9qOZIfD6NzwyewtQp9ZC5ZEtFQTautEQEwxBo6TkiSRE+KpX+oIKqgSGmK9DPACIM+RDmc6XHB+CaiGcWe4jACoPY5Rsr
# DATA PDFuyfPNc1yzvdAbvOsU7tnfqp36B96cdEi6uzWS0GQRgWXJxsRHLmrIPKtSrgM4TV00/HkQ845XLFjsqm1F8fAHe7Vlvso8AqDG
# DATA fzacoruccr4hVyrnLbr6pXuTbg+EH+PuZ74+IxyYq8HzAcHmQ7SZhklLLW16FfccpT3U3B1U9bVOVNgVyDam6o/cAqdLjvsWLqTF
# DATA o7LQcwvhLUE3LWZTzDwoltPqZLyPS34AT0rp9378vePvtXe+9/b3bnxv+yfk2xb1+tqtXWJF0xlcsxDxIRGPMHDIoihU3Gs0j+xS
# DATA QbNHAoYVxBqdk3LiQOvXZBNCVLIdzFlLNKlNl0KPEOxcWfcgW5rlSEb9JtIXZ7LFvhRzhfst/WJ+J1obZ6b0U2u23Das5Hn25nvQ
# DATA ypsjgudUFRoVmOB6WrkS9MW8iaEKHpOlW1yl0qILWqXys0kX0+fq+RZm6Qc12fUaxmc6EGHsDmKmuTnaNVnM2daouON1EEYLYUs5
# DATA IIOtE/37BCJmfMqtJBKm/9qNvV22Uh5YuLAi5Aa7lM39Nr4law2aNc952e6MDTkbYmXa3fHQMgv8IgsIxnWjMtUWWU8i+LAxE4gl
# DATA 6kuNtaUwvVzVQR+ODIqUlRp8mCfO0oDUinUp5iQnQwhNbW2u36g1Xm/j6koiICEBLc8RlQNdUYEgHNGSGTnXZOFszBWMZAPL1ATz
# DATA ACPojpvcaWGRFt3QFIWicRZbWRufz5s3tByoUvejcmDZlXqxG1lwi9IVfSfZHg+GQ4QhOxSo15weVZP1RLgDZqrq5qrPnL4VTTfq
# DATA spsgKqz4K6kZfIg21mtXqsHaUqe1SgsFy3ZHWKX6IUJKBOf3nKKMSpsidG2uhYrMXfocXVrghhRyWVvNaX0eOnY2URkCUTWliytZ
# DATA PCI6wvb10F6Q8TtNfK283j9TaMZOw/imo06rh+HRs4+Bt7GY/QSKTPK4v/BiRwpZ6rgDoA8lvpXSkxNfYV9Uf5F9BD2iyaYCgGzF
# DATA fDngyEaCxTqQq873muXbyb9q1SXcM1h5iej1oEX4ArRnpF76ki8xn6LubKGEjXN0EmncGLintu692DLJ2tfV3uzLrGPE28z1k5Un
# DATA HXZbXYxIG634ULto0bxJ+v3c+5oB/3/+C1DmJbbq8dlnzz9Knv0RLnX4iMH+ozOAGobS2iJw5hHd0Ieolv3zsy9BHQia2c9BJ/sl
# DATA 6qM/4QH8+kwrU3D1X4B9x8/gZq91AikySPvx9SstmHOcOyfCuzmi3+TIkNiQpq7EFIoOtloJ/3YcXwoc8aUKxnrVxy4dsosfqQb2
# DATA 1o2K8eT5/8QTi9zpSRMHd7eSxrQa5ZiaR7yBq+ujwwmwsy18UxIrohp7vdlUx0azmVlfgg2v2eJPSqlWoxOOPugb6kAm+f6AkfZz
# DATA Ja6ISQoVgiJHkFqx02uTGpHiokh8Yrsn/CKzGhmxWLVEYDJo7xJDNrLYVEcQVeAOAD8l6QqadlFsQgMYZjiZjHq2Si06vArezLGX
# DATA MyahUsG4FAivOxl26jojF1rs6vIN/gNf5ebaBr+qlvVPcVI9d0UyM32D01K2/Q8cDoCFyKtKneaedIcvLfOy65iAFC33lHgfeU0t
# DATA OZyW3udD+CktlyNL4XOcMx2ByNr4FXBwtV7/AH1fuXrfPSM4OH0LGB2UX6AFSLH9M/HZqDaYBmS4jS5YqAoGyYh6v2uG1Zi1tJzd
# DATA 0OZpzmkjenW7MFVNFzr8m29y+LejYccn+i6Bv7SuXWvRDfU01S4B+7latCYaFppNpIBmE5hKs5lGfDuJ3RS6IerUF+90TuYnvgA9
# DATA fceDVx39/+1963Mb15VnPvOvaMvjbUACwIcoOYGCcSgSljmRSA5I2fGCCAoEmiRiEMCgQUmMxK3YmezMVFKZmqn9tFUzqdnd2s+K
# DATA EyeyHTv/AvUf7T2P++zbjeZDniQrzsQCGrfv89xzzz2P3wE/nvDsV3iUf0and06Li2XmA8PtncBjk2Sdboksj5wECPNWw4n+9ct/
# DATA hkagMrJYwiH/OdQO7VcCQYnPuTeQeQib/hTf/RhNZSjDCZkARbpSIF77mDIZgTL6H4yk3NizF0C7aCzCNgHiFW6bNYh/IKu8QYon
# DATA lHOosPiXESH1l/1nqfzxHn3l8O/Z8V+LC8vLywn896Wbi6/jv/5z478aGuYdE3VEE0LgIO1+Iv4rviPOTsHL9/pTSMUlnRxYGI3z
# DATA xYAlUeNl9sQ2+yf4keIvHhGG2Rf/5OPDzmVGxj764zo1Fr9WvanEbiXDec8U6kqWFzyL830ArOhPT8iAW7Ugn+0Y90K4uxBWfjQC
# DATA B3qInoZ71kfSp5082k2tZ2g4FEm7a7GokY2sOPlmdWm5pXClu6MJIKhqGCAMQtcerZTWzYBDUPiqCWtTHErpmF7KBCA1M8IwrkGj
# DATA fm99e6fxYWjjO5nITlTvwWC0VwivS2xXyzNZeoR4Gj5P44bHgCVH2sHjsj1INolKJ88C50mbew/aX91srCUTMkNNmVC0as2Sjpjk
# DATA Lu9ZOgMad06NAx5pVxrpZK+eeybUK2kbESFJzF2TZrZIVycbmg26mxipN6M4uQI/7jyKyl57KMF1QEEA2uct5u3gQ8GeIE9QC+3c
# DATA sP07Q8LrgpvWaZ4x6vvEpQaafVPh3BDD/t8hhJSB9YoUDIEAUJlxEcGiZt4im3DJjGKhWNIrfhhLk6Z3NjcBvvJDJOpt2y2K6pBx
# DATA u3xbtjHI8Ajt9MroY65drEf7AfmQklniCE0XzL1lGIq4j0ZPOl1JsTJpHbFhBxA8ayMoom87zmXIjsznPt7GYYanRtvpu8QGCzVK
# DATA e6hDNz8TwjqtO9ZdT/IGtinAXjKqt3ZUolnTpaBkbLiweJrgX/iyNzrDsEn0e7FhXLFsHikGFhn/ULQDFIaCkmNKvXFbhjN78th3
# DATA yvsQNPx0cal0e/k09DsmQk15Wfjq5sbOyvpGvQGYnfWNnU37IFGEfB4bz3XoALnwi+khNaLWP4j5GD0mbDe9APMpHA+DQfuj+cyC
# DATA PvW9ihWZ0cR5QkpOk1GxKG8gs7K4lhFvkWKE0afjOYJlPGEx4KVPE2poeGQcgUGoWl1mLEWuGB8vPJBRZQVy2wliSMYlNVV1LTOG
# DATA 07FrePQ1Uk1TzAH0bM479yh5HpFrmQoYD31oct4xshNjisfznA/OBj1M2EkB/mExPz71AgvqTeuxSPgNU2bKFCc22YNjncyhko3G
# DATA w6nxxGGjstB4RynRSJtkD7mO7fBQU6IVvU7WNFMp40ikEk21ryaONgXpgHl2AMgkzhp6qniNMq4DXOa0PYorMhdqODR11EkIQszL
# DATA wpJ3Z1ooZmEl5k2ZUvDlTDFjTWlmyPceHifKLy4sLBSL2fCJ2RO0+YE4Qvy5kn3evzlyExdzgrwTs2vacmDLcjXkMF0hEKBD2Kkr
# DATA ZVAVczOTJefSHvtkmLm5+/V7K6skW1Ka8+1XfP7lPQIlhgKbYzBQF8VUC0iBh5KSXU5nds1xWiVnQgIEH4/HeFme0Ym0ntJWSO2h
# DATA DVg7s6fnDTctKiyKg8hQ1rQnkRD74K4gPTeq0h1R+nRke+AVk9K9xgtQ7mszIArSA/8d1zZlgsZoL7B245mZ1Zb2PDHgEDIy1eWI
# DATA cFYKrLZpayTMaClRcHizhpcxwzAMR6K0tGg5EHhcVKacgrT2idRBTipVsR3qVEwmyvEUUEdaHlWUe1xd9oLyii8nF7mYXPWlxA2F
# DATA 39fuRJYwb2wUcqkzXY7WewaGVRrwk2eKRFU5MAZsctbf3nB64Yfn0bJA0n9oVvfUHqCW+z0Tj0v/WswXqe7l8flc4y4QkW5yUEcx
# DATA iYeFvT9TZHyYY2dT5unKrBtH4rZxjptG/luG5efdTOajOeftI3nzgDk1vjr8jPIK0G3CD7h9kauEHpTWMk4KMy8Xzr0zx9XikteK
# DATA C10p8l4ncl4lru4akXk5uII7xvnvFyluiZo85nLeRPLfQjwoISaShL5yYP4LVzet/czEj4KVpgnu4JoX9eJVJY6hKnOGXHl6tRAW
# DATA JTW9sssa1YLks8gVyVSsbTKklgRX3X1TWtOaqVxyn4MzwvKJdNfC/KNZ4gVS04P1e42VnfXNjfb25sPGaj20Am2l8xSHH40J4kYz
# DATA dbG2ujw9ctfL5PZjSLNBsFCW0RJPN6hc69G5pG0W5IcJSn+jloNrp0wAbieV/u3B+vaDlZ3V95IWRNCtc/uCLyNx0wEjPcJodQgR
# DATA Nv/quw9KxtJDG7UEJAu0IO+J6AnI1hfZNupA29o0Y2EdJTO60UtmavQUQWgJpSBcpTxCK91q12x6mrHqpLyMdQ4DdyzVhIzjWKCy
# DATA 65y5GyBxGxmR6436WpiOW5rn0uQi4eSZte164/11tQvfRIEiDsT5j2avMiFDScsXneYxxMGJKQj2JqPHMSqvx8fTuDKXkGyansCq
# DATA 676N00qkk/RpWGdnpr6ACd8VCFLOKqmFEQ9kzjwGaG4LmRyIgLZEEmk1DcTDuGjqkeREttUZ95q8n7CnLFjJ7wTZYm4AzhUwl5RU
# DATA 0nBFjEmuOTljXc9/AM2jLy3zeOC+YlrnLIpceXB3/d7DzYfbtCQ7K4179Z3wfDkCjbHrRIELMhA+wbucXFsoOFAVIUYQVj0RhMoT
# DATA QFuR+BHe/U6Vj8wxCMJCFOD2hsdHe0qdgRZr5CMBA6MxBhu0fkfBikhE8HE0ARyFGDGFEHEMNyUG2YHGSJmtweMIs20rkRx7wG3n
# DATA 1kr8mSgjLEvgVWgjjG2VsCsajTGTzxWvBjNkgrJVhKwqAbWn3bFRClZtD/JlDg80bO+WWD5x/8a9BYsLPeJC0Cn+GDN0sGWYE42V
# DATA dAHw/tKdzgCnhBZNCFDOLtKSgJ/9/f0I1TPrW7r2I4gHBbDOoIP9rAQbeEIIcQ7ouDM03BUhR2gEcIVeJuHIkM7+1tqXxPaeiYpn
# DATA aCDSG5ilPpACqXW7YC7CZ6QjdBg/oodnTZVMig66mNlD49VUHsYVPFU+j6wTUA6PzubTtSYisTDpXTIuLu2aPxOQSukAZms9Tq9G
# DATA gH4z2BF8Ui0IbDBy8pF8VS4fnFePImS9k/iwPwbE2iHBHcmLVo/xJxOWJd9pYc6q98zQBXwnR06sr6TxwJPhHcI8OhBu3J6OkFoM
# DATA UshpJtCb4gJIo3MpOJ7K9sPGnopr/VHJ3/0p6dMS2tfIT8t4Mpo4tkrVlzfOaV9yq3LkbI0Ing4ymuJZWCxm8TqvIMoMU1J3EbIL
# DATA X8C7jijPA7k/CxifH9owO8nMZmZWCaJgemwGr9KjAv1D2VGpV2auZDtkKo8/MUD2IJ+GvFHk7Wv6Jl5C3NOjkGKedIQzXHfNM0pK
# DATA Ism1zEIBcO9xLvoLA01SKxnbNqcV5FKmNm70AiAEBDLDFnC6SplOna5lSHqYJw/X5KUncUlPpCmV0iw8T2yhZBQ8+dUarq/GpSul
# DATA D/SKr2EthknniBKaZD2+vLOOfOklajibJYwbGinCIlYbrpfr8WLPGBJu4iVUrRlOnunAD5haVxfkx+AhIjMf26PnM8fbo9knz0x/
# DATA klxeJHqUJdWh8HjYedTpDzp7hAETpumjr+Q6ma6mpn5h8kTqYMix4+LR3mg0MP3T1ZUkoz4Krq7SOJtVccFrOf7rWKvupv4pq1rt
# DATA /5NK9qcekFR1i+70ThixRoEsL0nIFcCS4Jy7eEQcjQS/Gw37XczKzeUJsusQAC0Thb6rqvCBaPm3y7m3iu3nb98OHc/+RoQGXv17
# DATA csMUtbQx0aWBkGxgjcT7GTsTanPAVLzQ+ClDsupJ9sPe9xndsIFFstixxgKVSB2Z6tWVtQ+VjxCfqpYCW0W7a521DoDXwh3CMJjw
# DATA 2pHxSHKzwUhcp/Prqze36mQNsdXW+fTsGozC6rHsbUqPKJ46SzIBUApbOHEkkpbdIGIEUHsSuAIbxQrEYY/izeLCggLE6I4Go4mn
# DATA WtNObJBcVl9VLxhLQ4FvePooF0zqfIpJUSs5m2/UeMVNQUtyJUlVKujCPKUNVd9U3FhI0wcaPLm6CtwUjbZTCEUBdMX+VJRjdSAg
# DATA ZYEJMRqDxgczl0pl3yz54E8WA9aGftUYpj5UV9Oo4rlyycIz7Sxs5gBtwfb6xj0J34qae6XvM0mR1V2bGMcIlqteZwBGIhY/wTSI
# DATA iJK4ThzWElcCqdWdHnamhl4Blp5rxJhRoAJSSRyAKgz1DNPHo7IkCJ3RUdpaOjIZDpJEhXEte70ThGpO1RXAXWlVFiNRRfSqTQhs
# DATA NQDBFL+FUl6lFbCGRKFs6lJuBxcaIgAdN5HKcB8jP3+asGxzi7arDLo3yV56wgmt37QqgLaNIzaZV2qxn2ij1dxLqLgaBk93h7Sb
# DATA MTsvz0niPlm9ubC4sDs8NbOOH43EpZSSK9FgmzysFnXlkSD/I2vucEOC4p4TFJm+siXM1seuvFQBAMvwiQg61jA1ARGXZ4wcfIMw
# DATA C3nC7FqR3Lne+Wjancdy85pASEUH5EBDLJopYhTV6M/gukLDspdQwx9jMLHgXTWZBhgal+ui2a2qUS75lRCZpgTe6VI45wIamAfs
# DATA GB2dUk4yBtke+S0TmUVQQ9ymdOenRSdLFr9pXWYwN1LnSHpDmYzLk707hYO9t7LdXqtv1TfW6hs7kp9JbU4OyOi0DPWUm96IGiz7
# DATA 0Y79WerPgVWs7qrngCF24YZbOkoVl0svVdXQ/tb5GIUcYcedAYN30XEO0JWCe4/EnVNc4O6wx5I8JQMxQ6a/+pt2Bo+AJYjgCDKV
# DATA kXIlhmuAYOSdYWBMIp7DWmms+AT0uoU3wH3lNNU08hCZ6wCzDtW0UquRAg3UEg5H4fkRljXqUPZr+cvPhmNOfdMGZLYR4ejcTQ3J
# DATA zacGvEBsLzn8dwZt6oAbkWt0q0gWHPVdeSg6eZRUjSrQPiXEV4f3ZlWn76tPgSqqZmwu7zMdlAslTou+/XPK/mAAatqzYK3/8xF4
# DATA U0kkNyKvZseYS9CBOikY4Ep+zDEHtjdld2SQsoT1xaShocrgHbXZUcsFFlTroGI1yPOr15lGCSL0dsfnT2byXY3HyLUmjHGJRfdq
# DATA sZPTz/fj64mj8Jz1UPoqvD5gyHiyQj65c1C8mW7NQ/3FXIbHRv3Bpri7o1ZhdXPj3fXGg7oDvmFv7qrjOk773T6j7TccJei+Xw7y
# DATA eYdjtsoEUkbL2spKfpW2TU5zmQlB4fZIvYzitzSEy6ecO/MgSukjGddzNmV0TrOGYjo+qVFespxiZmIVZ/oS/swpW8MbK6uyxlpC
# DATA C2BaOvepUMjFk456UEyNq+UaPaSU7DtkrwVZAgnbpHDjZzAIJYXclnfWQe+RRczJg1wfVex1mgblapyRJYMrmcAVBJaiAD5Ryy3P
# DATA AakvZvW+B/YVgnaIgfq5+Sw4WO9eNlnIeaZixv525YtztGLNo1OPi1+cIpp4mjBKHQ/pop2I3aDLjI1ewIFECYOXN5Iqc5Q8Us43
# DATA gVYHx0ad7nPlj8SYqdg6P3JvZkiGieqbjegLM+mi+JqhBJrqlUUEdIm9nE6n8ug3OGU1kfZLMcaqfNuGRkoD49AScU5p3PaacuVy
# DATA RaKXRAAzff6TonrRbocVTSbcvfR6l9UYcQA+hB0FeWWVMZUWWl43XUMpW5QZdZy2liXm1FqhvNWJY3YclQTBYIF44emK7zDT4jvq
# DATA cxBPsCuNA7FYBp1NW6mTM/yTEzG1CY+cXH4ZxfMurOuaLbNtsc3VCu7Itytk/HdgujKLbkP0d+iGgpDj2PCRphPriOFfrHmAZxQR
# DATA BvFXcf/HUfDXwe1bt27ePo83en3jfUMW0k6p4MnRB0X0oDAJf+gJA68VjNCAcuvGbiX7e/GvKOFKlr4OYkkqDxKIScphs2Y5bJrL
# DATA 5Dho2ocXZUwjupb5wFYfbu+0tx/e3V5trG9hiFCj/nC7zmMDdQhVLRjH7lBZ9C4XDkN2TycExoxn57gkS2a3ixe1VCwfJdM7/9ma
# DATA aXKoFmkZ/bnovHaVLBs7Q0xoIE3zApM50dbuREuFYaJ3A8aLMoaLLiQ61I69fV2fPwp+vVwUdb5bZkqAXMrcJBE5uDNN2ZFWkzvQ
# DATA ciAo7Z1ghUHlRNKYMRJxR96or/JG/tuH6zrCyZ8RLLVLkIo4x7InXJ8kyxHHZTSZtplTtJktxMm4WiL20iVS5bm2iHQ5MaHcdrfK
# DATA afLlJENr8oq0jEQ3yr7tukLJ+XhIE/E+1YZL5gFeT6Zc9rzHS722+cGGINu1evvu/c3V79fXxGwJPg2iJtYK3t9g+MQvjlXGn5lS
# DATA /56WmzKFYpJ0oZPCyaPJfc9TNDMBHTFxXZjZWDE9/dq5/NhQluDBk7ctPS65Q1HdNPK38fFwkYx3abX78h7SvYwHhda/fFmc8lij
# DATA /oQsUNm7O8cmfhU2mYvbWM5tzcmyybyilH9vwklC+TrjSKyi+DA4uYNXFiMYRsZyxBFEF9Ovo8EA2gvIHF6Z+7O3WPjsMVdnCbt6
# DATA 29YFbWtXYwmzjv8rt9wkj97r1wtPQ9eQI3GeZ51OyDKTQo2+MIBrwSx7UP5UkBe3HF1AK55p53nlSbK8Ln2zsjqaLn3ns76c36pz
# DATA GWNDbpV7MmVdhvI4GRCQVH9b1h77tyzzEVeuzEJYT/7X00xd55rwFAOZAYZ+CdPPxYwgMg0ft+LkC85MancV1o2LJrx7bRnJsIx8
# DATA 09kAUxmdmQyQ6Op4YuvHHEFfR66lYFBSqVT0GQ4ekL4Nro6t4DZX1NFzhtO0T/OdvJEglIHS8JFDZ41cKkZPTmqhhOUIZ+Nu5ATb
# DATA YFQFH6LC3FXdGXNNPQf0WWp4GwQlR8wsMGJ7HiqdYfdwNJntgri23qivAv4CekDUH2ztfKijAPsyuP0cmnjLpqCkOgmIYAxGiPwI
# DATA b1Y0IEWxnUv0GTX94HKqIjwU6SgP0nyBHI3NHxiVEkkawdky0tYf9mr3paZ9suVI3frSBrr5YGU9oWhDq2t+/FHSA/cHU7onDSDy
# DATA tyYqqDAasrx48iqiTl6uqIxSRXuQsUQMm5m8hZGXNHZnEF91LzJXTmIHiJX7G0Ed7foP1rd3tsPEViTVDbOadNULsT9L79Lft4af
# DATA pHLTX3VFR4RMIuaJQWfSPew/ivhmy3Wh02gwGnajOzK7u6FOezM4HmLYf6Rb7EPOk86QowgiMAVQ2pO9CWx77aLK7aWpZFTHzukg
# DATA bFSdS0eTYAvZIf7OE2B7JvCBp5qL4kK5OAt4TshJm5dX+GPLlUmXzx56icCk2qOPjJnQL3cPxYsFfK+YgWBtJSITRfjoEH0dDzrd
# DATA yAtSXTucTsfVeQ1TXr25QIFavsKwzHIbVCYa5NanQ0raV0tmvy04lad29KkRW1cFvyBB83EZvArHEYUWCjEV1SfVoGk5M6imio7i
# DATA PRwjqo0ovx8uLr1dWRD/t1h9Ck9PMcDD1dQT04E3njpQByRulSejQZpzhFvT6OCAwnKfhr1JH3P9komtLHVAo7HUHz4NjzpPymA4
# DATA hkKLC0ekg3xS5vGGN8NTtwGKmOweRt2PsIapmDsYarj6YA2lS0F1yFPxv/sR4ABc43XXkwGzMI+mQiErz1Od14oVwX2GhUntr2Ww
# DATA NOYbnVRGH72zUF0sFitdhBUoFJ0S4ieO+xcVCokGun4LmTyH5eoHgrcBlxIPFpcolHIybY+jSX8EfmDh0kIshpx2uMKMN+ViiWvc
# DATA TFgKuNrRR9u++lSGaCdcYGhZkutMsd26a3wcuH3jx9LVnwEEVF5qS21C1lPrjafqDdGLU/UWdAlyv8BiaW85HgJXoLvmyhZpylpr
# DATA I+moIClmXyxqqpgYoGEelnFTFhOgh9UlIZ2M+8MozMEPJFvBibm3uVa/+/AeFD4SM9eHK9u0O64thDiBkhWE316ofht53fLyzar4
# DATA n/Fx/rg3RgKWoVw+VqNnCJ2Zqr6QqupkpMTJMsRvVufhv/oZTUp1nlXAlts1TZfsAk2SrklShFkPPjudxY5JjipLOUrcE1zN/qvx
# DATA G3MYl+0YW0UUkEKSSBx0Add9PbkunuEVLawF+nB6CXyZVFc2U5mWqQdNVfnnUJ72ZisT5L3MVmt6dVC5zWGnbkgOQWLaWGgMU4xJ
# DATA wat8yE9iRMOR2WgrK5ODY9itW/hLQWK2ga6g3Rar124XjTcrgr7bHX6lEKrQbKBZgguuNUOlSi9r/GJCF0G/9JAwaKZ832Elhja9
# DATA HE8ixZLLx5MB/8IXgTIgauPhBRKVOraVIyDeUgS9MO4BXiLLHG2JzOs4jsrAd/Q3qonEIjdYX56CPrCBVsbMlMtAvqI0hI/WtlD7
# DATA JT03DMHS9A63PV9CFOYR8i41U6w1RfZ86BHLsfaP7PyZVNUTrJMNKjQ4sp2YKAX+AYIEqn1mIXE9WvOxLP4DpWMNlYSp7W0UAC+l
# DATA uPAI6G7VOz4axwUvMjbWS8oN/GgAceN3k09Gw1iQV7sTd/t9xkZmMX6Q1cMotHS+aG/HwqRfEyuAPkz6OXmUYtTvJd1zTLhU035V
# DATA C5welGxFFzgRotLK7U9RrYV61THe6amXCOezppivCvhZGefopVRvP8+gZqwFbusM6pDIVaq3F1lwl2dktOeiDruzZKjaaL5ZL3KB
# DATA XhlsK6NDBtCt2xd4ePGGNYc0kTf8rtM5Z4G/GYSZ2Q/J3d3RS7X1+Vo1Ng3qX92uGE64SotlTCQoO0K8qnron+VzKBLqxilA39CI
# DATA Zw9XHopGyl/W9ScWFr0Ne3k3Ynaz+gCuOqIvWC2ymz4/I5rVFevET6C/Ky/elG4V0/fJ04+iE3YgwmAsK2TMe9gWTy+wd/TxnET8
# DATA SZgkkqNQ0ymtE82FVnaDhgiQdq00yF06fF/Famnxyx2qhuNJWydZs2kkl9BQ2SSnwaKEqCs61kaLUbuNXWq3YR+229wjWOO4fzA8
# DATA RkTAAnzsDCrb6/d26o0HpUB/f+/hlpkhnZ7TPwWqoBRwDpHrbXETO9FqlqTrC8necxf2+yRxYfsE8tPXoRXtxQnKldGjaDyJ9vtP
# DATA Mlw/bYxZK7+sQuPLldHR0z1xFY4xlbcLU5wu1Ygenf1rcPbHlz85++zsd2dfif9+Hrz8+OUn4sFz8fXFy/9+9lkAz19+IoqdfX32
# DATA 27Mvzr58+cuX/yCKwu//HJx9Ab88x5e/PHtRCc7+tyjzXFT34uUn8Pbzs99C/S8/tsoF8P/Q8IuzT8+ei5Jfvfw5NP73osjnZ18G
# DATA K1vrZfH0a1EXtPT8DvTrpy//CSoSzz8Vn38pvj0XPXA6/Bw7LOo/+/3ZH/BlrKDi3rJJfbuyulrf3m6/u7J+nyfkV6Kur0WnPhP/
# DATA fgG15Ro3N/pHfPlzUZ4aDczqXv4CZ+S9nZ2t7bKel1Igin+No/ipqPIr/vwL8Zxe+1g0+Ev/7D2H2QvMiXKm4+XP5QD+KL5+LErB
# DATA Ev2bmDgqBp39QnXfmrOXP0/MGUactN8Vc9V+AEEpd8FWtP7+yk4dp+7/pCweDlD0+3fwVS77VzAD4iFQ3nMYLxlYcHDQCXxkDHLh
# DATA 9sKC6Pr/ktXKGcfvz0XHxYgTHZa2SN1x7KhDol+f/frlz8XaEg2ehywD7B5OGk7mH7hXv8bxfiY+Lt4Ovt+/m9oxnRbT06+0rfNr
# DATA 8eH30M+finIvSvgrNv8lEOYL+f05TyMSYDUA1XZcnWd3w+hJ52g8QEfAROeQQrlrFrP4H9SC6JUg1d8A8dg9w8Y+E7P5U2z4Y1EY
# DATA 6xLrxq9+ycv15ctfAKW7FSCN/hFH8ouz34tqPseZ6BxPR2YvT9OZsmSD6D2lObSQH87+XdQMy/RccIkXCcbh2Sm8mL9HCoSd+I8Z
# DATA 21p8/Jfg7HdiTX6CtP0lrsQXotRXgnxenP0Gf6G2fwnsTNT1BS6vpDLB1X4uqhRdgF/Fb4IoP6nAofGtv+C/6UCIEievto0F8Xd7
# DATA eRn/FX/Ov0tLy4u35TN+/vbi0u1vBQvfxAQcgwZLNPmt/z//rl27thpNphSKGwXs5gPCLOcV1eZjUtFFj4OGtGVJVykKNMCg3f4R
# DATA XgulUlV+p4pIJSafwTVEfh7FcxiJA0aRQX8v4Mcgo8siE1WZlszUkxP1UXCiMYjpc1QhC5myQrqSlizTUJsexqUALwasKxYS9TCO
# DATA B4XrIF+XEOSSwzL3O/0BXH+Y19VCcaB/BqxGsIyfIFuRLGWrLuRpYGCCdb14+ffMtIDjMcthsQbOXOS/X0NBccCQ5GOJQi+QZ4km
# DATA PoGqRKkv8IR8HrrI5IbcKgZfaIY8EvDkg7FAIj9IjVWDIYk7T2c8hdGMjqfwkGx2CtX4luE4gjjSpF7vjnpZWcScGfIgKVcI40i6
# DATA A2oKbI87/UnhcBRPGc5B/1Si5DHm0sW1UHnUkf+SfJPNFuJt8O7qP6IYG7zzGVUWWeshKjYQ0/FaZL1qx1iDG1gX8fLEATcm4Cr8
# DATA Hu4Odye7C+FMTSfJ/Sg/AJHwSSfFNHEyBygTgQwGUilLYeIIR7H7xcufATGAnPYpviKoJJlneGwgCcCokiHgiwtLy8F1/Gdmh/8j
# DATA SXt8wjIFq87DSS47L8ZWltIbCkQvTAlNHN3/CDJa8KB/V6V6a4iLN/oSBfHIZUew9NHfHYODCbhXgxPqccyYpRLFFkwIQEMVRQBt
# DATA InSxxvgJ/CDFU7rh752A3ryoFtp6SuEgzAfCJ7cWvoM2reEIPAXgE3o3REO0THz79jK6qCCjUM3KUW2KWra378t4jTjoYcYixLTs
# DATA xxiTDt42U8ZNvyO2CWhbxEIOfxxNRhLVnsIzuDztWJWwaC/sjaKY4tvNbRNKV8KZI4G9I77pzWePJRtdxPeX5JReMgLB67fAFoGK
# DATA HBH3N7AXgLboYvQ82/nxKupXfADmAXe556woWFxIzxmaFKzfZNirbTa5yrW6/DqdY63sqyRcJ0BQpusa3Bg/hVPKmFHBDcST53iT
# DATA eJ4Q8XNwym+kF5xQiGSJeEAkAOID2NUs+YG/0xH5Y2knejOAdZJh+HGwN5oeBo3tFdyw9dW17ZU74oDiFClH4GSHvx6NeseDPmKm
# DATA GOxqfLw36HcB0TZBBOInwcYsevDxG2ZmnprG8nXxk6SncQdSXZAVNY6rsk7JL7XLrtG5N2pOI5m78leJK70+N+A4EMvwtZB9PkFh
# DATA 5xOpYkK9l0/oeflT6ckIVk/vROndggbqHhnbnbmq9CIQZAqJVDairgoWg0VuT0ftWBQc9uICNiiTQ9UoOdRiC1IPSsKoDEePC5I2
# DATA KsfTbrEC30QvjsaFGbwL5b0vAlRffU6zwDdln+AHV95/gkvvV6QlfP7yH/BmL679dhYczxmowjDGJ7MFLsOAlCZ76WP1YmIcL2cE
# DATA FiGJIeGERcyHUEes8HCMwrkRfM7+J00diky/wU7FjuyFHEXJXoaQpTQmYoI/FjT8JSoXPg8TXfd41fr8aI0XEp60MGdA14UQciR1
# DATA D8WJUxlHR2SG6T+ChI3wlQWUQU/nIzK9KLAWwwhBeQhlq/PwswW9ca48tWf/F3VGn+Hh+pkl6IEAaMuzpkjozql4/Q94uVGzinKi
# DATA Ic+KAUqE7LEln1Gvk3G3HuuDjQ8HAqSYoB+LPY+TRJzBGXNnOjrqd7ktd+JUPZZJga0I+ZsVQ3MDN7NWyUCsw7rilLizsQwF4yxG
# DATA NumlB2Mmhj12xunGcdmF0bVHlpfJcGTiS0KVg6Q4fEEX+wTUhmPY4zWMXyPnc4Sh3e8/qYWV6SAuh57VRLjcUVzZ7wHnL5iNhI/3
# DATA QrTPCJYedY7crEnwjO1/iYEZJfYHx/GhE0gH7cUnw25BlhFjGI4KRjz0KFZe7bToGCZO+xJi/QbGEJC7ocSYulbMoxVsWlw4iqaH
# DATA o16JkQQcBDYzRTUVsOKzZCZq40YIT5KXwts3v73s+Rn4WfBfgoXRwttvZ/HYtY1ts89VwQvEUf47ZTMwrn7ATdc31hXjCFDVLk0O
# DATA yBZuizuVgzllqpIqhFXCHnsaUkpiaJmvEuuAk354UAibvWHc2h2GN3CYhpODXK9ogBmJIQmC8v4U7yhXt2hy1J9S8HrhKfzS7g5G
# DATA x739QQcs4+M+GY9DDLmndSNjvirECV/o3YPuiF7jt9TSpbwqUwBQPynhgNuJ6IiT3Hg6B2KgkYjAHI1RrZKHjJZA8lOljWTLj9Cr
# DATA Q8wosDj+MuEvKn8DVVKhhO0zwqHO/hWIQ9k/iYrEcfHyZyTAf4n2Ujx/fs12hK/4QidosKzUZ8/JIAhFQgcZzIR7k2NlgJvcIsW/
# DATA IUl/dvZ70RgYfj7Wdqyf4oFnbAarfWZ3FwnCsdgu1QZBrpUfjfrDwn749KNTMEM/Aj938ugoWdMvsztUEFYPc68yrwGfbUNqQwoq
# DATA BZLt5BAEfUo4m4rBmGT7EGIrRgilkRhyEhrQgJUbu+XWje/pJxUTPLD1dKkEiSOxttniS5rKljaN5umHgjOgm3DIIQbU2/AG/nsj
# DATA xGgCpHo5EDNNKK72INbokPaZqytPFJcf5x91JvOD/p5OBTsvHs9bcmFaIUNWlHliFBelpm/IlbqBIRThDfHajTAZSWEHYhl5Z1xt
# DATA hzE2UXNM6uj82hPH1Sq4UUOWcgO4GFE3VlvM293yzMQ5hi+Qedcww0ykdzntEbjNTWSqF7ERsHados1DwjqPRqd7FJWbRLytpkK8
# DATA BLAdrnA2r3GIVnAd9Bz4A9wTP0Fm9weL2XGfSCygziYjtLVGG0tkarTPsZkUD0Qj7m/xivoiWFl9UFfq3hhtx+IwG0ddcUGERPao
# DATA M3kSdbcxqcnfHY/ATTAAnUkPXQa7U9LNxIfRYCB/J/2JEAQ7YzrFcCA6ynB3F2hoV/yFRuzhNXp4zXz2Fjx76y3uoUEflJyIO8z/
# DATA hsV5SQs3QhmGZyfIDJsPh/2pkDXWjICCRmQb0nbub5t35N3hyr6QZWocM1UegYgYsaNawAHH3Nru8IMOnBbessibrM5wZIvozw74
# DATA 4wshKT4ciXIPH3Tij2oLQrrbHarZr10TjI7m9EZ4bReURHxQ3V5evsAE4ebJNT1yYoxJEftKTFpnAGNq7kBN4q3N4WpHyOG9zqR2
# DATA vSz+L1i4WVq8VV1YqAKfsobeEIQlzs0fR721aNA52Y66tZu3odQWKOVjuAzUpuKMxfrXybLZotmNendPatj5WE2sMxeeCJMLBZfk
# DATA iiuRaAwUEDJGlZ4pZyioAAxjAIQQUu9ND1W040RKsobLZ9OIiDC10uIr6w0tl1A61TEehDJ9WdEWMYPtqeAr+IiDNnMdjJPBFDeU
# DATA NS75o5RpOfywJjPrJktanP94gpPivgVKq7E/QsPx6lQTbngDu9quTkValzsVS9/VqaDGq2PHQkOfTFfShNfv+MTyPZaqutnNmB7f
# DATA 52vTICGjaeMG2qlIYVDUzLfQTsUUof0VOwGeJGiaI2FR06z/wsMg8q5aiVlh3tShLT7SSejzt2U4RgPamDyFKwRMmLwrppAM7ztb
# DATA En0z+H4UjdFSKRGAAnkU440bcjoPu4NjQLsOwDNjbzQN42AA8fx8IYkrySzZzXA6kLGYvC2rxmRau5liJnlQpjG8ooWCIm95qyzs
# DATA S7OMnS6RDgKeJgvG0a9sIkHXSMI7HcSefN4sv4CfEkGeGSNB2cX6FfrsQ0nyyixkXvj65c/o+vjyX8gxAy+YaJyHC6Y4mZ0UMOTN
# DATA LZpsWp1pFe+YP0FPWjm8sWc4Sfu9lOHoTjgsW4qRCzkxg/X9RwT5gQk8WUVGIpl4+VEfrisGP9Ap5ySGRxQMRgcVx/M9PPt3w7FF
# DATA zGhVXKAM90AEtdO5JyM3MTrrdkPTJYb9/tDFZn1jvaQdKsT/s7kdAl9hIDUjlVa67+LiX7anX4r72/7j9sFxZ9J7hV6A2f5/i0u3
# DATA bi/Z/n+LCzcXF177/31D/n87Edi2O5P+ACATYjC0QN5IRvJ5+O4HQorFbKp8HJVI/94fUtJRsERMKMHwSZYL4H53OB2cw98vPjye
# DATA 9tULFHZyPg9A/g7oP1LBhQ47FCg1w2+O3P783nHi8Hcc5ZZvZXtdRMNHtafXr4/iCgcIivP1/mp75T56nq8aCt+ZfnYN8mg0zjHw
# DATA EfstWTVffgy3bR1I8ELa3DCqQfz3n+GheEUs653Aw0/3hdD1GJCezj4FHxl0y//py1+GM334xJy1jeNQ5oOQIH6HfTRTGpO8hbYb
# DATA C5/Kxspl6zW8WXncEQxaTvat5YU8kJT05hSU1UPoUTEdkt/TyOJCAqje6PwOlao/Gdt4b7qyj/qDgQvFqFvJMqfZhjS6ZWoFk7Tj
# DATA pGqnk/SRrZ8GUyxaXz9BHTqQw5cqzkaQibZwX8KSJ44ZryUPjGpk/jbrxxHns/b9ZRn7JtHeaDRtS3ZaENNWYhVZdyquR2KTCYlm
# DATA BOnfa6xySah+yzDXsgaQgI6H/WktVUGTeBERVrUqS1MetXsltPeF5YeRkwK5/VzuFUedyUeoWaeXCDyFMCdC1jzuIN6cmO4yOnj9
# DATA aLQnNrgYNKDbjUePxUuDURzD9A36H0VSUSnuYtNJZxj34djDi6WreRSzeHm1I3MCWLpSmooMFwo3oXN6i26IWZM6ROiPUhVaOdsh
# DATA 00OvT1k5p4d19KOoyQQZNINFSmu0O0zVG9o1mppDgGXjWRGVXAs4Z6o4Czt7g8jQMm6N4mlt/jiezO/1h/OTo6C8HyS6YTWTpqJD
# DATA YKXyMVyADDWdoa1Ej3hjQ4WUQluQPVz1pUosUYq6HNJeqmCea2udqJeQeAGFJtmq9Ofho4xiZatMnDNYAQrlUU8ekKWAYn9F1zgM
# DATA IRLTJ+7h/O3xYb97WCOZqYJfSlIqMxNHidcJmw+zD5E0xEcp1iZ+lJ8AxtA+0wlpd/+xKIQtFELxxTYziAeJE5wrtI96dmiu0Vwj
# DATA n5OAM62kPx7+UEFXvhiOA0rlcRxDXmmacstCkdEu9zOjRk99Pt72Hz6Rih2fvuag3t+yj5TgaXek9GxEtf2RQmrPvuI5lLYQNb38
# DATA oCzmyCoiiNItJB7ZKyErYw2JKjVjWBwo6HBt6Sj9KQ6LREv1EBw33fhcmgvl+JEcSK8fdyZHbeC/4EHBpIpEZ5+BRd8hyKDPYjMG
# DATA qGnzHH1e9E9m/SuCx8j6ZSoxkC1A5wYqDCkEV4KVAOQ4wcEkzugEcEvRjxdUFYOgzw74BsvouaCx3dFgwDhF5TKextg34u3lsmA/
# DATA RHM1RFbUjE78hicMJOYYC+o5qa10u8eTThdtF4ugLaONo7NRS07VKnqTT8idZrwAC2G8MWv/JGQbQ6OJnRX3viMxX48PoyHDtXPw
# DATA WKc/MDSX/s7YvTdNqhlcIucuTiN5vW3RLZy9kH8iNu8LiCL91Kbts8/uBOSfhD7Nn0sLbKoIg/yAf5APv4YqwEwKTtHoAWnBuaqd
# DATA USja82UeSQzBhXsAgN6UTeeVQ53lBPTyvsu0FMIdQlywa6pHjToARa/VG7kwtLgaGlJc4a/NxWpLQTrJZ9XFFqhdAac+bJEe0fzd
# DATA ZJmyVmaZFCzG1Sy0HLP5LNFXO709P/s1OrgDFSUt418oLX8x4cYXzotldwR08CGoDEbdjxL3MnCERySQId8gxbfN9mqjvrITPKMv
# DATA jbUPGvLzxua7m/fvb35gSSqEfy/ExsnxGBBlJMzH/gRuL45jK6LNOxgi6xs7JoRINqRIElZEAunrN9rr9zZcpe33o5O9kRCP1mVP
# DATA C8VsZJNz9coPdGLMChu+Z19LYZmMOQMFmLhtiocF+E+JnwA+Sbv+gwzNdEIW1Lhel7cwJCYzA3MlVEIMCjjifxjOeied/32NoAIv
# DATA f4YRN8Qr/dqo0DZ7mNvJMHycz56RgRnjNzmYrSqjg2m7wGDef0K12s9TdWieAUqJIvxTszFQqpdy5wBcEV+RCSBT/7+4cOv28k1X
# DATA ///2wuv4/2/k78031MUbMlCPT6aHo+HNuWvXrt3n1N2QS4eoRDqpVWCfcKpvSuONOQIQVQ0yA0xGxweHKBEqqTm3YeCwE4NBQH09
# DATA 6nTJUgD4KajHgCOHfgS9LwCcNCAmOJ6+J1jj4CrgBYQIqT6Dq9WUmk03PgDPsKwN2NjxZCDaqkyod7JN7mwJfoaDY051gHiP0Yp2
# DATA eECIX+8vjBo+R9mp0aDO9vo2uvoLSc7IMjC3en8dbky45pibnVQuUsII51Y3N3aEIFZvAGTVTmPzPha3xRBQpk5Gg3Buu954f321
# DATA bt/BGOsNKUapEecebqzvtBubmztatvE5i81tPWxAEgxI5ZlSZ/nRomh5Z+VefRtDpFCLwflReqPHQ1TkYKQUpWlkNFfKGxFycswT
# DATA fgGcOfpDsZSM/drfl790BTkPxQvFuQcrP2jf37zXvvvhDjZphM0rtS0lYZqMDsRcx5xfZiJXWhAUQBEiHnwpiB7p8BixK7YgfDI+
# DATA DPbAxCb2kZiHMZWJS5wfQ8qlUoyO8ZrceRwwGcpIcNhjdH8jiquBUrPdh5yJ+ICVUXTltlNUWJlI0cMFto8CnuYVn2e1iZGQj7Uz
# DATA 7MIh2pNZrGUnpP5BF0pT2Bj1HUQyEJoXGrLYw5zotDichYpWneDY4YoZ9ZKam4dIN8n8OPca9e1tW+x2BkxZRuS6okpBjsvJWjkc
# DATA gVoMI0DhPwXP/VtWY82wthqw5AMA4huj6btADk40mVHB0xBnCf1zKDcF/ovq1Ki3AlDZokdwo0ZKAkByxBpnKJfYQGQX++RRf4S6
# DATA ONlAk2tvKfQCeEkwC7GlIkzkAjxIEGostSGAv0deTYJgwXyofaFg4z0W8mWskApoTStgQH5SwJYggtZ6KjtVTI6+aYyi1ZQFwfXp
# DATA qPOksFDCpSi7Y9Ez0yomqqwQZ6G+1HhG7ddqolZOBQ/bGNcQnNIgRGH3ycJCeffJ4v7uk7f3xYfv7Lc46RiWLYo76NJCa84eBC8M
# DATA 9LvgeXojaD4NO3odsSZAoycmQgXFd/z3tFVslpeWq24bnMcPBi2aERXN+XLfYVZAfsfn00q1uNyN/LuqDsNJ8gLbMR7LJTS1/mSp
# DATA 3v0ye4M6PM/YqPYNQ90pTA8r6U1VTO+jf6cj2YrnDhU7+0lpL8aDiKOt9ISNDxFtnL0/uUjIEwynPKW4Vh2xWW+Sqyas3ADaD77h
# DATA mSyeD1kxNNFc7OZeRR2B3H5wSHOV1qZ0/fcA8pSYuuDc+m28rcvHNG9NnLdqy5voUE8BuqMUeLvHx0cFVWkTK2xl1i2YQ2Emjygm
# DATA k3Wic4bqRC1YqHpdPty14lxaAzQpguVF+cz1+vF40DkJOhhR14EUB8G1hYDBBq5VXP+DbJI1vAITyWCFqGqQsj48EgQqD5J1mCvI
# DATA fIRkfSNYlD+siqkHvjOIhgWaV18iDCTd7SkmprDKcuo3Jn+8YGMTbmKkaNIl/ra4sOB5hwiAOncdy8ybrbhdio1j0dgy+jFlsZDM
# DATA supnoU6l0aAzjiFTCK6WeMmiyoLRzr4gh/iQGiJ56DEQobcneHwVEyOAiPAj6EhDUpfRrnxkHvfJI+VUsPPuQJCCJQ8ZTpZSWSyI
# DATA hRi/RPgYjA6Y6bOnA5+5kHUUkv14clpKroKZI5JZFfNGV64P0fFeIXiJ6nQtOdKZnS+BGcuAZtYWFX6/3/OrVz9obG7c/1DqVC1l
# DATA a/0Hq/czla0JhAIligGfTOaZrLqMVZWHoFzoPNwSrOgzd6n04lUIrkiGXarHVopO8vvVv1DwuAdwQJaxUtCmoSKIGekOIAnwfs/1
# DATA gzK4lFat7vc4rj9Jl22k7gJdgPhuBXEeUx0EypcjknYKYRNkBMpMN53s4wkevvVh+a2j8lu9nbfeq771oPrW9n8NybWvcnBEZzyK
# DATA ES30SqB7CCSdgm/UFHlJhCqiNjye7pe/DdGoMPK4FrKbh5RBuE/S8yg5LEZjYkqLjP1pE00uqlzZ2qpvrLmkmOpgpaYbNKrU06rr
# DATA AJ8y/yEjOZNtSMJzK+U0pKNSnh30YzFvzeIGDmGSgLgHV6ZsCjOYGGVuk+hWCVYmt0XqFOPkpHJCZoDf7EzxBoGfLD7L/Cp7akxx
# DATA lmZIKk2M0aG7m7b4XBFnt+7hoFF5uLHyvpiGlbv362EqC5Z9SS7NLNNXY83cBZLu9fcNhIbP52g4kbAiGPRkr/KR4AEMgYR+g4CZ
# DATA QeU8foOOE0plu72+3ajfK8hKJNZGahRLjlnUN4DjYbdDFw2zfob6sBRbtlGOeh9H0UdSoEm8X7bfd4YI6qmarAduGwW7tIdGUw04
# DATA 2SOmYGB8UWE4yHGbNUF/xH/BmDxFp7fCHvLs5hJdWFSJZhWKTYTU1uMiIABTIXD95noYPCyd1Wf0Jhr2+CYDkwz5WguTsAx/wKgB
# DATA 0SBoXWds9+D79Q/xp5A8z/U870UH/eEwpaK79XvrG7mrAvQC6hMc+QjooWsH5Rv+SJ4WQi74rv5VPnPolScqbDbqayurO/W1wOhD
# DATA C89gUaLJ9QK2U5HVF+L6I3hUrDGtrD3Pv0pAqOQ91jJo0e21SelA5PX7vAoAdX0ysxfXgqeyRcp9WVKckTObyq+ejHUs5lAyP4On
# DATA ykfy0g9aZWgKUxDKHysHg9FeIbwulRrN6u1l0BdhIVXK23IsJJTE2zeXNHQYNQniJzeeoU1AEBdblYDvJFidYWbFd+jKY4jxeKx7
# DATA +J0x3+BGQmYNrKJpvN4qFq/8orxv5aY3pPF+lDUl3gPJl3L4QsfTZY6otFMn9bzKOIYYn2PaHx5Hc55AFyMJdDr/z8k+zdsRoaUi
# DATA bVaAOcO9SHC7H+7G1wvvVKMnYBzbjW8U3ykwJEy7ZaDHtK4XRcEaFK5cL/6VnfcZjDWVB8WqX+ejOStxn2dAJ48FqT9DvvKMpbxn
# DATA OjDyGWAsvfNRdPIMjkxQkkHM8rO4M5g+68UIHQCDaS62sOX1lFmWW4wKL7UMjzdMcr17bTcMi95XRcdBIYI1FIO/rgXL1dQAJYen
# DATA 0jvunkoIkokNQ9UgisgItBmFp9R/RH/CT/ATc3cPXyA2gAeQ0/VTxIysDSC/PSO90I3e2It03sA/yqee2ioZh1BLxqDwMS5V+IV3
# DATA +kfFQud4eii2+I9RlSgIpVmttYi49gQBRJNnYiH73SLQ2O42YNJMwt1Fo27zUHVbCLkNUVnzmuBZ7+zuWcQpnm/XVxv1nWdbK9vb
# DATA H2w21p5h1pRnfGy23xHn5jNRYK2+sbO+cv/ZytY6PVt5uPPeZmP9v65AdqGiWyk3pgZTbP5wd7I7bN0Iw/MNYLZQ0dyNd7db198R
# DATA rc4SZZ79VTEspQoHWd3Y3YtO/sYYpAkBlfZ9L7RpIKv+AsDyiNdb/K+o40al3LpenZ+HqYvnv1dt3ajSp9aN7yXm8HvZvX+yuLfb
# DATA bC6U32ldbwblefHf75X/m7QWJd6TkF7dw86k04UAawTmUd/EfsKSoCA1H0J8xDQEuU0wKf02bqabSwH5OFo/vFELFpfezhJZlUC3
# DATA xtfFgFNfxhT13YmnhOReCXYOI6WwtVR3pKkEzxHCake3igrA8LE8aGup5c1PXIXlR0qAOyXdMLwBkCOys/BIfj7ly+0AEHunbeWI
# DATA 0mY/lYK2wDfICB4cHU/B+zi4j68gBn0J+jkU7GiKHQbvCXISEF87UwKeD6adA8P0Ph7Ffb4q62hPEnka9QcbK6uQualR39rcXt/Z
# DATA bHxI6XWn06POcF6h3pRVd137WSo2mqDzeec70KbqTj6jeKN+v76yXVfRntKsx04rBa14CmU+I3HSVQ6EVHK8By6189ji/FPd8Om8
# DATA 9Ayap7V4R7l1tNF1o/bU9dI/NZzgCacsrj0NV7pwDoFaBBw4ICAF8FEfDXvc/A2UaEuQAF3UW15lA2EVBPJyF56Fnhjd8KGgwvLK
# DATA AaeX1ktg3iPCU3rTcPxk752CcvIwUmaAEDaJ4vFoGEeJGyg/J5lo6dZt9iSBK6Zaazj+RHGwiusSF1pAnHkbzQQqNonKOIZVilpA
# DATA vbwIxYitgGPEahjVo3OASi1NyQWnVVGCj372FXHI/NFuT/B0+R/gk50DJ1pzYrfZm3T2wdbSj7E+zFCZKDQWJ7rM8GyVvMjAOa8D
# DATA jAW80K2wL37GDEmWJPGmmrISpkDknxVrUsSRi/8W3xHTY9Y8YxDv1xvbQmpQyrcJ3runx4J1F446Y0BU5fok6DkkxNIoScOTArwE
# DATA dLq4/Pbyt2/eXn6bLBnwVJxEWOVF+sJzR126ERQWSkWxDwrLQRl3B9Wrw2Ytd5pqpsXGf+3y+nSjJnySAijMGj8OEMbtDNi5t6xd
# DATA jLjSElU31zRs70A+P6Yqlv+N3Wsh8vuJJv/mNdviCcc6eFrZk+JclApKaeTnDx+ur/GrKF7gx5w7628f1rd30vsVi0dj0w2lLSPm
# DATA j8SpI79xrlgFBVyd4f3GDhAeJ7A5A3dbfLdNZGLMWbqn/ArxhxvbK+/W21srO++FVo/y2TVl4YRVM+nVp+dMUZKeLAOalZ6h9thF
# DATA w9Ll0wGxDCJRVZVQTeVaMo2G1OfmQstR+lGwKJrlzCzb6o0i8fWVra02XaVQrPZhfIGncy2gkTB8lqlPUooaa2xGCAXoIWyV6w91
# DATA qzW4QuwDwufT28unUtPAGobkkKQiAGFyKQ+QASDLbIRKg9715lImET1Y395e37gnJ4BPZdBSAObrUadbGUaPuToF/1sK2Ou2JN2v
# DATA K/FhR0geKI31+gcg+hU9vmPpdF8S4jspXavU/KmD4i0rApoqmBu3mMhjwCtkSH2xiSDILsYKGbwpAQfBPRBDtfXKgfMKoo6xI7vg
# DATA JIwJWAgfjQbHRxE4AjctF0HlHdnE10kVhZ8geRPV2N/3KlcKxhbAksycKY8TPJAyEoImoutXwgEbWEze2pUCJenGLTsrD/JqWBRS
# DATA yVKr2DI0PWobitU7GcPFK9zrD02IRwKEY2ZT1ICP1WST7F7dhjgB8TuwqtM5n/eC6WUAR0VTdqTli9606J2baj/YfLixAw2/e399
# DATA dceTDI2rdwx3uHpS7yVb9VG6fbRIRGCjATklqHc3vaRVfoq0POQpL8IOYp++Ksml4NOOLoJiVfo9hCNgJ8sqmnPPm/eJl47zbstK
# DATA ghA1sfz1NAn4CoC7Ua/NB6mRS17ao4upqBYcsF2YgfkKSgJxxQfChpS/QYH4C+oNpFunRLdwsXAdQIok4G3cB8WEiXGrAmA4+CUo
# DATA 30XTuzE0iq7wjQsdQSgiFl8yZwd+Qh1HolMA3gFNj4Zl9kzYHfIzhKW14XjzY134SFdHXswHHLBR4uBzd2kTqSM1tkASKqNE+BGG
# DATA CJL9usLQCMvl4eix+MC9OXdNE5qp1BrkpQABUoQECzr56QkLjIbkYmiAAAAXMM8GwLFOVN5TwQvxULsj6Q5iOju9YArYMXSsRh1x
# DATA ZON0Kx1QqoipEg+kH5wZaQgsUVPKppcSMCW2JrXlYVQ6LkNLjybYa6ZgJp/xjItzIDLlxixxjTt2cyn4bs0WgGrB8sJ3bivM8kNt
# DATA U2DdKOEY704QYgf1QeCeH7aKf0Jyk0zZkJSRlI8maqSqKia73e6LHdtuiy4M9sm2bEYsi4eVdLJTRfQVR79h3nNUcyhyYVtJR3jj
# DATA HmHW6Z57RmWdRxH3O6GasKYlqz5+14lP0CHrpC/tJfuMBu2a22vX4s5p2R1v974M7WLoWRACwEubIpzY8B8ouzmVEqxV9sYPP2ER
# DATA 3sbmTnt9Q1zE74M3mG5aqomo5mbI3z0wHYkSelrAoYsJRqopwQ3AvA/PjhdTuHPgTO/LOCUvmDixRDkJH4DMGLEr8HSS9oFALovU
# DATA 37ohW2JKwgxQ4qR+Y8zBQCmKuFBd9paWIf0IFM/nuuVXd7iTmrrbCiE0hePDpXHDXPyTz1PxqhfA6Vj2KjAdW26IapMavoiartGX
# DATA JbnVNZCnEzlbGWDiCKPaouV3DQlxyLEAqnAcmVwnD/gDsLh8awNVN4W4jiFd/hXiVRJ12nFAGOYo5uw4wguYDHikC54RfxSU9btm
# DATA IMECKB7fXlpIiVOBdzjuDVusyfhJ9sWoCQrdqTcaD7d2LM6kuowjE7UQ7LiQoKqqH4AUbiYWMAlPDMVMasDDVfcOtIcdgGomdADG
# DATA ZwdI+rumAqYs4+KYg1NozU+N4yoZXs1MtHvYGSa5J+qMkQAQ2YNMCKAw7nQJE8fLYeSPqDM1GGdaMFeWXLe1Bg4Cdx9uf5jw/zzx
# DATA BVKR93BymBVAvDwU4lv/x5G5A2ncRd9i+GpZw3/SXDrTB2K4OpNPJ/kom5u+Tc6GtBzEmRUtqUPuvCebDlVVwcXyfiFRlowrh5DZ
# DATA DyadXpTjbE/n8MhwvJxKDA2VEOb800CFRDF63O71Y8Qts6CWEgOBEELZT2QX0CCR1lFnKKrrkc0LiXXmOLZW7tXbD9bvNdDFBIez
# DATA 3rB4QuoegK8pO4B+eqX0z97kuU/O2ZvHUAf6YrhT4nOSZ28t4+z1vqxZJh7c6mu6V9e5RQ6HQcj2Zw/sAgeWXYFzan0349Q61/rn
# DATA PzGUI5srf9FBAQF1FGav16Fqsh5jcata2Nb6Oj0rZiyiMSeu3s3ek56IbSe/RirFpqhSCIsxE6mQdWplhHkDMEADwNCE5jiwpGy/
# DATA FlK8p0AMtWqLKlQ/MPrSg84TUIIBDUABVz2HL90F5Q8q5VLbY5A6OFW02Fdi6RQyZUUTbh8e9HuhZLTiEYgO6jyxtEuWo4eP2AoX
# DATA xKqyCG+GYCaui42dtoogYnmplgx1mvO7e6qTJaeo7ik4Cct88ym3nt68fbrLBX1RXecg4ZQtbg3YCTSRwVAAUGsLC7DIlqxwQQHh
# DATA ym+E52LNFz7EnEO5WJ1xwUweY3nujmT0T4AYgH6EmV6aCGo9BvdARy0lY9oKOam06FbY7k4ijn5CiWQ2s6ToPERC0QF/xn6B3Dbs
# DATA hphvQySp2+4XsBQ/C2iqa1CLUZ3E96JHIEmNMMRNI/duzZw+fXIpuG9jCQ1Ro+i/9l2x6KpmX8uvcg50X1o+OeRKJN5LSb5Xfo+4
# DATA lPjmOzyUGHYZnkyOUZ4IV5U2ngBbm6v31/XYkulX6cSVqkrEtQGf0LCVsZroD8EV01qm1Yt70lQuqM8t/0noyEbXKemLXyY4AYcC
# DATA mKBef1gz3lyrv7/x8P59/AXkArn/KN+U+uoTId5eXFjwy+AZ23p188HW/foOnvz21s5HDxpaRsoTOlP6OeOoLibh9PdNJugnJw6Q
# DATA J5iA2VMkw+XFZymCXEiwwv2+uVXn/e4VOJgzGaAeLQ8eUI49ZllbjhP6zEy1uh/7x3PRSgEZQd3g7QU3cQ3mA2iTdpPHSep6e/8k
# DATA gdcTOncWp+xK7KnpYFLD2gxjbz9mdHT7sgJdaOmddKtoZExCcB6v0g1aTBIc4PP0hBgU0K1AA/QMoo7oIcCZ7U1Gj2NITsxaC4Ce
# DATA AQqYRoOTip9bpqlDUi/86T/msrKkC24WeXgsMWK6jKWvZrqRWLuIYevZOyWHFhm0+XLb1AxCLWa3iUNGK6J9OiXzOB1PJhx5CO9o
# DATA s+A5Q0SLadV6dcnXr3POy7DzSAwe3Ryq6iV2LWfnGtUl7XbDBZMXWYVrJgq5IGyGjEWTcmqa/bry3gPJptxQOTIw309QG9mZMZFj
# DATA u13oD4eRLygXn2OcKMMdkKu0dLR2bbiMA4qA5aUkCLkFmOOC5MCE3vDILV7R3UXY1v10cLZFawXElIK5IeHC+H3jbjFTK+YV2GUe
# DATA MmhYiFrrmylaJnv+Mk83a5otqvN0Knm74bV8gj4DWFcpuN72B7jqps7dY27/Pt4vrQNNaemlr0Py7k2/tNGVv2TcxHUsBTqalFKv
# DATA 5hfXOqeoXWaxV78he5Yu19JQXEqfeUFLe1YHUzs3C13wQgNQjk206uDOI1fbZdj5mgL3iY36B/WG09CbweYwUpi6KGj8aCQG2hkA
# DATA P46P9/f73T46dkFcn4xRhBAt0DrArHTEBe6wHyOoTSIU3QTqMjkeoysoPEoJs1DNz8OY2C2Yria4QBkol8VqGZ9w7a3UEPDLI3tl
# DATA I3zlvDOk1JuhdFeer3Rh8inSpeur1ra7/qzMevxjupAiPlUS+WbU72mq7oRK3u8AU0pVw8/U2X8zqnlTK/+nooLPJeNepUJ+hvMS
# DATA BJxbhc6lhs8k4KtSvht694to3F29ddqJfmm/s1zY5Bk66/5wf+TTzHNYaRZcuI5EIgSg3HXEh+fUc8PvpgnBp12fQXLFK1GcYy9Y
# DATA ez6bhK9Ycd722+gNtSZR2UE1pzoONU1axc5TFvWI+bJaHXtjn0roBgakXzNm2n9+U5SamzXaABHY3NzheByLi+oSLIj9zeZd65w0
# DATA cQgwiLm9vvHuZvtdscG5PqDsYmo8iaeC+sZO40OzBiRsx4HLWSY602GRdA6HuXPd/+39aedgMIhPj9zMFXH2K524h3L7fPry55iX
# DATA 62P4ankwpNyLZErAWgbMRC7FMym3hQAA/SvLsHRHV64qb2FEYQ2iCvOE/MzUWCMts7oaP/vO2u+kqao1yIA2JSL9pJRGz/Sehglo
# DATA Ei9QG8SPhKTcoel1f+VgniNF6/6192ViGr1MT9XH0yontnkqKzxVIR7iFf7Nv4FPd4fXVAhAej98WaWNgykxoOC7+irkbbd4Llcf
# DATA uTHhgtSor6x9GJ6nK+e6ll3gemY52DMVqMXRrPKNml69Czo6mSANntaRTSWibEAoUL/MuhlduPk3g7ukVYb2KMUu4uIfdU7guoUZ
# DATA lzrBMALc+DFlidF5lipzM7Wzip55Qmt+upIqGllKkoESdrG6dDb4irjzv2pmbOVYg6xyVcjVCXnmPjv78uUvAjpJZa8pHUw+vqtv
# DATA MHsdIVmVjKPLsGJKgEc/NzaNg98UW06lZ3e7whbyL/u5CJqxOdoP1rcfrOysvhdeZpU5sRIs8r+f/TqZLfX3mCkV0un9I6UQDGcs
# DATA 6szrWh6T5yxRzzG7Zgt5/qpTdT7UrifbSdLpJzsVUXFm9W72HCf/g5FGx3XYnJ1OJ9u/wG8ZsBONQEicmaPI2+vTFHH5AoadTG3U
# DATA KzWCv4koaXz1IAwZCCIMUMPeC/ZOKMZ0POoPp5VgS0wCBBIHW6homR9GU7hke2plZQNEp45KeL8RbQTd0RjymilFZ6/fORiO4mm/
# DATA CyrM6YjOl65Mi34hk32KPb5tQtjnV4Ma22Gm6evCvChB/uTbzC0TDoc+lHKF16fwtK9SGZtMWjZ3lfScoGVUXNOiYAD+9ofbO/UH
# DATA 7a2V1e9DxhTp2SQuglsPd8KskXrzphp7YBVPni17Gwx7RACOkf7tW1kt4fzPythqHFMyYSvfer0Kqwup93ji3IA3JxH6xfxDcklQ
# DATA cJ2Sivejfiwm4cAG/0molFJLqxwww/6TbcRfLJg5Lis7h5QS8eBB/8n6sGQlwKzgS8ir6FWZHgCBAdpTfDU2lTOgDQRrD+8418VF
# DATA nAZDigYvBZ1ej/d7fDwWvcJIEPVi0fMOoLfw7bRwK2GT9NSt4KNE3wsYc899oSnh/KEFf1rRopl3gNjhkahTVMOqzoR51dqEhEgw
# DATA HpzIWDKxBUqIIea8tTfqndi4GlhI3Tg99oho2GtLXMEClEorRGCKhXCVIDTLAIghM2JKQEWPktJTgQWxWEKIRURbCPM2fT8aHkyl
# DATA xA3GLBi362+Kr+u3Y9/oH6NhmkQMrMOa8kNcvDT6MwPjs4nKhAPQ4hnhNuRBnveZohFWAETTziRqM1oA9oZHy/gIJigxQSSI/9xF
# DATA QGK8+WALxXTLLp57SHnLCzdBwJLmrfDdzcbd9bW1+kZ4mkPFK28XMhsp+Gjeq++Qty3+QmpmyBdLckSYbQ/XHVsCTDOaN/aF84fI
# DATA 5mif0hHEIPgUwnlQclNo/3yqn21Wb5QWG6omK6xTZ+tqe3oQpXZUojOm9IfebEl4p/lsXHDCT4Tb4dKriyBLn1NsHtHP6dPCxaeR
# DATA CI6jec/fGwolv2TrljsyRcFeiPY9kcc5e7a1uX3Zrg2QIysKM5hQGxI4Jjl3s5VJYlwfYUurME+Lt+1MOsN4P5qU63C4Uawgq9/4
# DATA bUEZlX4smGN/qlVzC8F34dZS0GVQZWmD5F4ZMTPOp4GASKuH5w7Cfjp9KWa6YxgiLNQsEeFwfqaMF/oGuEAg3gnGxTMuWSN61Ef1
# DATA wuk3vWV9hIk9vSRx4uab73QpnvIvkyqXbt3+CyJKWDEPhoMODXsVtKk5Ncf/Q4easi8tEqOtWCH5SPerlZ/sly50NqQSOYmFr8n7
# DATA z4G8bTXuN0TYJk0nbDNXQcfpMrV1OVi2Lgdgunt38+HGmns5eKVqUatD3yEPHqUAgu1k+paSvmdZnFNZaiQ9pgvoktx1NOaiN2oL
# DATA eRDg4aw7pvk78AR/AVKrSMccWqak1zyUUoiAxisKqg9J2HjuxwJ0XvZZO93f8WthdtgyYwpub65+v25SuVmf5TGKHjem8mkqFVDk
# DATA olOSahjCXMdCVW+1Euj6tumYwIoq/Ke9P8JkQZhgtQ/+8JxcE+io3QYppt0OZdbjSYyOHGL/4efKyuTgGGAMt/AXlWkLLKRtIQN1
# DATA 2+2i8SbkJ2t3+JWCdnFE580t1IAz0DB+E/ez0Xg6r1w2peXGW5l50nYPR4BsXCOQYxQPtdOkg2yAMOky6FRMRVkiYWJZGVrSyhyG
# DATA jIPMLETK8+KdtN8Hnb1okPE7mtmymwBv0PQKUG2a8Tuj92aUYFxK7gQHs3JZ/AdKS/0ThKriYRod99nGuuCiS26jm2/9CdzFG8eU
# DATA 74bcSmhvK9hqyBUCtKKTKoiGKnYorI4Dmkszb+BbZN7Aj2LC+BOuDn/GleDPOOsSHd3fLlGQiTMJwPtuUxz8hJ95pvkbz2p2Iwnq
# DATA tCDdbAhXt+lcDfCO0NUitqauq1hBh1U5bdmVmXsso0aNP4EP8Wu/p9fGh0pPemm3quLct17/vf57/ff67/Xf67/Xf6//Xv+9/nv9
# DATA 9/rv9d/rv9d/r/8u8/f/ACT0zaEAKA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
