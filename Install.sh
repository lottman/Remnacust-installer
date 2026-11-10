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
HELPER_BUNDLE_SHA256='7bcd1aa3af111763e127ca8b10ea048b7cfc7b232eb5606ff54f2376db610e97'
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
# DATA H4sIAAAAAAAC/+y9a3cjyXUgqM/5K7IpHQPoBkG8QbBEtdksVjetKrJMsrrVZtOYRGaCTBWAhJEAWVSZ59jWzO6e4znrXzD7OPsH
# DATA ZI+11ngs6S9U/aO9r3glEiSrZbWP1ypbTQAZGXHjxo37jhvPD/cPjk4Pvvf7/FeHf912m/7CP/dvo95sNLvqN/m92+u0v+fXv/cd
# DATA /Ftmi2AOQ37vP+a/z49e+XvPnh2cHPufHxwdnOw991+++uz54b7/nCnD+zKeZ0k69VtVv+//STBdBvNbv1lvdjxvP53dzpPLq4Vf
# DATA 3q/Qb/5JPJkGN8F17P/warGYZTtbW5fJ4mo5rIXpZGuunv7IO7iO57fpNPaTzJ/F80myWMSRv0j9EDr1g2nkR0m2mCfD5SL2oe0w
# DATA WCQTfJjEmZeO/MUVvDhOwniaxX6UhstJPF1UfWjuh1fB9DKZXvrJAnufpgs/GI/TmziqeZ4v/17O42AyHMeed3YV+4SG0Siep/7n
# DATA 8TSeB2P/5XII3fvPZQjoKPBH8ziuEoTjeLTQw4/SuZelo8VNMI8J9HRxFc/918k0ynyA9Sadv86qfjaLw2SUhADMrR/FWXI55SlD
# DATA J8t57IVpCpiAeQK2bwBpMMcYBptMltNkcesnU/4hgBGh02m8wH79LJ4Denw1fo0nJKBlCJs/SbOFXwDgbB6EC4SHIfTxqYLLA7gW
# DATA wWtofhPc+rfpck6zj9IJQpxdqZ4I2TFBRp3UfP+zW4B6upgH2aLq4YvFKOXxkukinkaMh0ugrQC+x/nxvJXxAIdIFUiZhOIAJpNe
# DATA zoPJ5iZ0NEHAEadIAkB0QQKtsDuzTIgX7CRZZP4ScJgB4r66igHzMS5U8Bp7xVc04qr4CF+dx0AocyQwGEqArCKZebM5TA0wcPzA
# DATA pO3FN7AuroIFzty7wv2DGLUwbu0G3gQr8Pllwc/8kkkSepj4yQi7BHrKripVPQTMIYyTa3x5OQ+xywiIag7ENfUv4wXtHHrRu4EF
# DATA ga/Wq9jGWnU9PLwOiPQBtpChw06mQKc3HsEpCwQbAeHU3b2epje63yjFPjPsGfCLa/I0vo7HuC8yfgWHuI+mYJRFHC6Ygog5ZR5v
# DATA phsg20UMLMkvNyp+kMGiL2gvMwtLp850GMpyswIzgeX2EELiOYoh3Fwl4ZV/CUjMCPxxfAngECvLiGEKL6taS+dBn1u0IaNkdOuM
# DATA B1Pdg70MGydCBjuE6Y0AgYDGCMhtGiG5Ib0SrZY0ZSSMFi+ZwMSvY2SCGZBUhBsL2i/i+TRgBqq3Co4qa1HFVYbvt56ih5sEaHMG
# DATA vDHCkYCfAkQTIPvrIBkHwC5p3zD3iKyVSb1kGqbzWQrsCzfAi2B6azdYoVX831UczGHzwzYAtHgxdLCcB5fwdciomcfZcrzAiVuc
# DATA ETr/Alg5TKia44hmbwPkEa6nyyKzKi8gdwtIuvVHMCteJ5zjMF0ualocrJEDLKsQx69pSXgtExhQcEyTGccLApxwzR0EIWyLDDcF
# DATA tlFsG0kThvVxQgDZOA4yllyZZ2/NRWp1VfsAmaU5jSN8YL1Y5hDxECKzJVAzYpLQFJtp2WAwNWSGHDwBTEspWJ5DZLl/sUwAz/SM
# DATA lw7JBtl0TmwBJEi4SaSYicWORi4gCr/z5XQquJ0rzHi0LfgVYBLcOcByhm2AZIGSZRmWLD1X160K6+IF0gxwxOuVIM1zd1XZ7Ktr
# DATA Kkhg4L37gMddPvXTcQRTFxEN+gSsCcoCaH//eiJl0cjZFe8Sbg6CKcgcmQJwpZMZtvOzZAJLNfcv02CcEUaAKpIMZgqQwdvAMAwk
# DATA pCppRMscFEwvn7N6Jd+vgsxjgsUNjGx+/YvCLNXegddoRFzFJQh/FFVGmxPyBiYUJigJ4KWMRT/wxmRBbAy5EDJX6MHir2r3MdZD
# DATA 1qRGKep+2OnByYtTf+/oqb9/fPT08Ozw+OjU8+o1/ylw2il3DM02ziwuv8HCnpZYza6l5vfgBsTetI68Aew4A3EfBwC/Fjub4wTE
# DATA /zi4EfEWzGa0P3MqpKdUSNylsNhZPEkQHcsQN9YkyF4L6DEotsTabciRGesRiYvTFhR8R7wGxBw9BbnvHwQwlDRh9TeKYEvTamf+
# DATA Boi8DWi1IS/E2QahfgNXDVQAEEMbxGKHKImiBHb4EuaPSkI6vwymyc8ChfCz1N9ggQhdMGSMJGUMjOYg6FBdi4IZqfL4ZQayQy0E
# DATA vuOhvAOGnl0RjyAGxKJDCXgjmquCXcA4SxBh5sgXpl78BrRieo8ZiCWHCDhAhezYQAC3NviGwOSBbBsnyODxFQSeP20MAxZOGzSw
# DATA 3Yo0gI0QpPgcWuAvG4KIOBFwQbRN9Yiy0Fbn1Lcniow8FgQDk50FlyCcV3EcEYGQwsVmB4goFgsinDwbczfpchyx0opaTwRsPlwA
# DATA yQIUSntJ4Os4UdoCLMwIV4J0EyE1pHLYn9jCrA9sgqofvwljWOT4TRwuF2LD4a72kKGBBoXkI+oTi19Qua8DVopxvV7KPJEIQCUZ
# DATA L4Etak7hOZyiTJNNjQy22QboykrCa9VHRA3zftYPUXCi7gCqCxg8pJXTUqFddQ0sBWVlBnbDeCzrABi6jvOEjvsTdzrSzsyaAHGE
# DATA eIqDS8cekj32qgyHdK5VeTYLUPmKxa4i804ZkwGpjtDnPF1eXgH/1xgVkczrDTLAB9Ntmo1ikdisxIohzfADXliS6VGuY+6efhgF
# DATA IMMB17NxcAusYm+Gk5onuEzPSUs+SsHsBJah1If4zQKJg+ZLVoMsXMDjTZGfEL6ho0kyhW9AYtcJSWdvFAcLbT6haq9Hht0dWGMb
# DATA UpvS+FrF9xawQCzYBUfBQtQLmjbI1zkaprckdxTH8ctCrEIX9iTkhUTsPVFxImWBKbaaEYtknFIf1K9hx0qQMKRXYCihHEpA1PKy
# DATA +MoRYtj24QjtPmsdQI5mZBUEMGxGPJMmiSpbQNIF1nlGzNjIl8CD3bqsslnNGIeFQXOSmQv1NInjRcbjh3N4OmcFp1HzT1mN2wdN
# DATA SKT5hqXZbbDx7bAhFvhoVwNng8cTh7eTE4O3o71JaRskCxRDx8OfxsS1sXuzq6bpdFPUMtVpYDHb00WADCvyDxW6zMsWCnkfMhNO
# DATA 6BnYhEmYBGMvUz1EqESwVhbglkwvQcah+iwNMn+YRrCP0lW7RQ+UKS2dcYDYx+0eLlGBE5NtgkgYg/W9BFMJddZYDMCMbDfYF2T9
# DATA BJMU2lkWGE6a+KmwFdWFWp/T2wzX93kynAfIyDZYGgonNkqD7E0tMkSWelqWUiskIVD60nEsFF8OKog6eTtSKJjCogA/kLUB7ha+
# DATA Di6Zsb8Ifgoo2AcmlU61a4/1SOFFRgWAAai5ZzWnvT2ssPIOVD5lvYrZqTIDNMDibwNEroyLWx7IDPRpFmGBv0o2tFwMHGgQuq3I
# DATA oWxFiCgDguSHMXkQD0DNe95GDooNIRrcaikM+gbgEkKFjYFNUTMDhgPIDNVLXvk1mP/xGBn7NALmkdEaM2pAFQUpp3CgrEMx1nAF
# DATA uLFXTpAMbisohXmCzLBdqgCbLKuyJoLDJ+N4znTI9h3oqcZFyO1gD5kty3sNGMDCvId94uYW+txPgTVks5Q9IcxgHEaSuD0SSQmK
# DATA xmMvb1xO41g5HUl1X8SIYdis47GQzoihNDMl5lwhsMistQYjh1Zqu3V4okzuhE3gkLMFeUrIN5qOoVmKNp3WFBzPxgLUspjJXO04
# DATA 1W0p8/KblVDKExlvzpbzGfa8SFNWuOUB2rTGjYPOUOWRU5SrXCeWkglYBYpAZLLJ7YKMe9IzL7ubkqGFWT1D8nwT4Kao+kXr6GmB
# DATA b6kP2ijzR8mY9KgsDVGOR7xZZTX5obg7Be3sX4zzW4u91hEIL0Ebhxlup8GE/SLeOJm+Rp69HGrUKF1A6/5rvfji9Kh6SogO0We/
# DATA SCaoe0TBIlBeEjFMyYRlUhiBhQqW0uImjqeMZM+GwfLYA3YzB728PYqwSjTuUJBW85UndZ556HWdx2oT+MFykQLAMj22vFZHdobz
# DATA eLj7IHG3aZ7jaSdmFkz0rJo1/7MgA470UhsfaCzugfXHXl3/kmIFUYG6RMSoHiuVDf0IKGNWPL4vlS8U0UwhCZjBdcrmidLcmJ4W
# DATA SH6e5YfA5pN4ofwqavz4Ddo3CWqpAWgK6MAgf/RyOk4mCfbh+okVT1m17sQEBfMEdHVeD+X/QpvI2Ipklsp38p9a4JDsY0+v9MS+
# DATA rCn5GUmgoKCDD9kiWYBNwJq36Tw/PxDT0/QGTOBLdn7PPVkT9PMGCQcCtKMY98V1MGapnBmUDm9d6w+W92swKVElRtumSmgRrZ+N
# DATA VweozMQQwITF8Asr0tputR1GIO7GqBEFshIqdEcQ3qCfScJE6EcAkqEwjoJGFPTc4OKjyTSFZSkSDHNfDFFeBdfip5ywsebqrmA9
# DATA jJcZLMOY7QqAi/i48odS9AU5HfDDZMz8FtsZ/ycyY3EMWXSqwjToAbwlXHiK/rO8wYDbUZt05FpBbjVPWCcTucAY9sT8I4al140o
# DATA g6TN1VI7xR0gc4vmyVT9yTJDIYcrY2MCNgQt0DC+Csajquxu+ol9DQm6adkbiKBUaRvT3GjqgIirZEguDEA7bRhlyLMXjENnHvWo
# DATA pxFHZuJAOZn4oxPyyfN6XSUzFjzwZg1j3wpr4tKA3pncw2QeLieo96NG74S3kUJQQxefZ+xQKDEXmDd6K33/lBREcZK6Uewn6Gkh
# DATA EdKoe0hYFFUAhGPgLQvmtwBeq4YcBCNh+P4rDhqx8X3CW/UZomYP5NPmPgF8jeoj9PmcNuJR6iwbik4gjiHKZdBsIy3mUUMajWL2
# DATA AMBwV9N0nF6i+AALMqAQg8GP5faB7e6PlmOQ3mOiGJjspewLaY+GDyhdjYYSOl8dvjy2GMZiDnY/9BmB8crhnmbdfwoomAzh9Ua/
# DATA 38Xd5Cn/N7lYFXEoIo3RHcQoCh0kwJAoxdUcdHCYNxZxA5dDVjnKGiAacKoSDYTlIusBiH6YgOTID+JgzFej+a5bhEMz9qto7THa
# DATA mY2CkjoPEyIVYcQFQpGIF2Uzqq2gh+a3JgtAdupl4ThIJjQTCtAvRFCR+PJNmgIg2HG22yYV2YCsgcPP8RS5KhmMwMpR1bYVWtJF
# DATA qrzNiZsmc6Yx2K0lQabMTGNzZcm8YmzC2rVrvtmvX6pkkn12mBmpIyubyzZRkxKJXMocBYYFio6fJhxNQ8TBNkmWk2LWPM1mYNan
# DATA y2xMuS6e5aaCXyTGgzQdoxdeUmLudWY98V7H8QxXC73XuFn5d2YsWulz1SRUeKa3HnpJlEJyrSMukdjpGEyaK6VbGE/PBCqYjKJ7
# DATA ABD8BUOwUEOOvgF6lE/tCYFxSRsHDDUTP1jj44JWqfJUu35uvYycAoGDUEIGUtQ0lc8ofgxS7SVB1cFTWwD7ocA/7L7ZLEVmNzdu
# DATA QEky4PASqrajGPXfjk1mL5QmJzqw5FEV0JvtvV9RSkW3yLu9tFWdiFbovCTeFeXysulVMYbY0wqBWtR2Ea1K0CqWwMtI8jOM4Nrx
# DATA vKBCSir781Csh4CoW8t1WEiKhGZBkpeIxwbogN0/GFq8xtyTCDMKPG/4rcagDDATpiwyFXgP2JKYKZ/bCm68nlKBxcojT5BAn0m2
# DATA gnmARo5CKi7WxpqtsQETCyusZ+KclFZKzB/Y2lxbtJY/bTVaJzE+9AVCG59j9DAa0HyaZXGmgrKBiWpZL9+ADGZvNwbKeWNX7V2W
# DATA E92aB3iAKEIZMFsipqriBwSpLQzEuJJ8K7Ilq7Asl8E8GmMEHbVl9G5f4XZAhzk5AuMob3hwBH6a5uwnG2/KyjQK2U1wy95Dy6sC
# DATA aj6YJAkSF8tXq0NJmaIsrCwGYJkrC4uP2CkVVfxDS9hdBdk9wRDADPEc1nk5POGtDYs8QVyIH8gRPflRbM8xkTvbQWoEf+0ILGk5
# DATA 2qC9BGSikNZMWjl5yNmZp2W7q/MwdTCOFZ4kKhbFM8zqmy5U4Np1EnGCD2jXUw7dkKLjJCg5iglxZbcHAGxI/nYVsVROF1YPJhjt
# DATA QCmg/eZVNOzQJMUw8XU6Xk4kDyRbpJh1hM+c8KAS31a4d+ptBJeXSLYYR00UpAZFNPlF5mQuKTEtkHvKvcmqFAlGziIBABxFJ13p
# DATA vySpit4whs2OKBHflImwi3HKJgeGg6ZkWhUtH0XM4f/VjIzHMQyWnIJnNh5yGFvim2ikke+qI6Ccri0Jj0C9ECH4DJamUAK6rowC
# DATA V66WW8xqPCO3MuCxiPjOWvFlBdgmsA2BbjYxw424WaG/KjdYXgVhWprGRhwCixFBuK/Hyjm4SZSDcQIyg/QqCq5d3Wakq7I0X3hl
# DATA 4zG2nhbQZaUqST7BNNEZc16x8y15w3pF4EfLOXu1VM/cmRcCX0onHLkn+iRvqUqnIy7DGZ8siP/N5hh4N3O0pKesm1V94uGsg4H0
# DATA BCGP+wETDW/jYM6OU6tJ5lk+IKXezVjeECGD8U6YsNQ+du6wY4HAB6GPIRWMHIixp+SuCFuV9mZhRmKHlHfqGaX2Pm8py2R7ETj5
# DATA gKEQ7Waty69avN4eI9Z/9HpXVRySdGeQu5OUI+3ipYFtlKVTSeTg4LIaC+0YO3KQZJ7xNGmllCgGs2xNKp0o5uuoGZXdlTTCAPU/
# DATA UfxZpxIatTija83ZyyP5EdbCuHSGUNlZikWAKa1K5dySMZgplw27YNMwDDLSl9jsw/A0xgTQeMffSEvylLfWStOOikFmmac3g7bV
# DATA PHk6VKpad8gay5qNOxRbh7Ykr4OgmeMb5PUGjQLQX75Ey5+2ClMG47zCCh5jy/h73QTJ4gUVW4V9/8GtSlAxP/LAtMLeaDlnHxuv
# DATA NLtotQYjKrhv2ZAP0lPOmrTQQskUHKwlCCh0Nytge9kKPVbXkoknOXG8PXUGppBxmT0rvJ+JRyGKjTfktuJxfiszp8xGtSQ5Wd5i
# DATA Sx6ySYsGSDL1QmCUljcVZD7oX1qwWzPLAurxRiXajhIOrHlrNsCJo9DfmExcUGgzShUpfrUqtI4QKlegfTLGtuXcTHRg5Yqlm4hu
# DATA hhTKcdjMsctQ84jX7oIl+c9mcTzfXKSb+JcToXTqm8ImnQVIpmxdc3AsphQLxlNBbLgoXub6yuaYXM2ccUQMXZZDYrc64Zh2gTg4
# DATA xEK1tnkkpwhQFye+D0RiueUssFAjR7e97RpIJCaBU9Q+heJNgyTvBKGBd+ltONQB3ciNL6wwMZ2Igw5qtHJQtm0QIJbEpKy5bDlh
# DATA ZZ6aKINCZ/p4CzzzRXOGpSCTFG2fGPaMnTSC2Sa2zFONQc4FE5CGVS9FYoXnYMFGKpiTGSmlIqg68EuCc8y9mTMQ5KNFAxw2OWb/
# DATA YcIcKuPwHmqUyVT2FScLqmkxK8lPtupF6XK4GC3HnJ9vfPGwMOn4mrE8Cq45xZ40goCY47NcDpHWHrRYoWwlK8kIzYuqv+Egyskk
# DATA 9ha3M9LXUs4gA+LSqTRAnOE44M2vYPddI19FUZdyhi/OD+7zJGhjBHTmzSSd5Jp6YAQvFZS8RPEbdG6TdCJinrGHHACnwyxy8gUB
# DATA wywbrdIVoj0HuVosqw8yx3H7LQLKvPGMLEdhHC1Ro2VUoYdVD8DgLqfUNclw/AXGk1Q98syTFoA0Rm4/djbFkrxnneKhuXjexiHn
# DATA rrAZeki8iT6rFBl7g1n5cROYVBplVaSMMI7QXV7FHICrdC4Z2v7r+JaRy6wuMX0r1koIluQZMtU5Z2b19ENW4ENQ+WgOgMh9vIKj
# DATA NXSoLFuvf8UOeOht8bIlpurFeWEiwTew0ZfICpZT4qCimjonN5hheYpD4om2lFP3YLkw+MBMgF0xPC9OT6FQ3zAmY9qNkiDdDDHV
# DATA Aw9qweodjpzA0nSFSdqOS8XsxdrCwTjQZeeljOQwHptgNm5NdoyljYfhEq2lzNNhPRZ9gRrK2oWSOzGyfYvYpaFLz1lLTO6QfGJL
# DATA rmkVTTKMZvFiiYdclV7psdVKSRvlQkehC2FGKiF8Ay32Z5Jou0bj43m73mCFVHLQDWPb7vTkNNq6HYYHXpcLdbTM+IC1N4X8Jl6C
# DATA J3ZZqOFaT1MOiVq6Hby9oIOqHCxBJe7W3lk5ipRDUqw9Oxin1DWdcGW7KD2iOumQ5cbJ8YuKpO7Y0FsWz7qJr2aoBV6uC7XD7O6U
# DATA YY2aISVhq6gKkfNyhi5ZzhKQuAjtV7NlNBbm1kT0iUGhqqoQkreCHE3LyUOdoojQ5kvgKQ1fFPgoJqfEzVU8XQnQIJOKxyOdUqCC
# DATA fBHysZiTgkhOmeNxlpamBgJYrpN0jOjgyS3HnLKGzHqRhpjdNxIxbLLKgnCeZpndESUr3LMPmCOsXWWl9ZLTy44FFm4cPoVDL2sf
# DATA hTpS56lj+oA3Oqss0QU/ly+7PlnWy6eOid1JoyvrD9gz8UJUAUEbuUGAAU0gx4gillMMLlAgGp2Akgog1hPgqlfz90xc4yxmh+WG
# DATA 9ZsJFeChp3lsp58gdUue8Ir7UEdchrcqJ4VPEPCRNsq1m8Z8wGUeK2FnAlM1rxgIOTkmsRuJ0qgUAo4iqQACqY7ABTh7go9yYa4U
# DATA 29ugKvPRETtJ23YqOXkJnhKkHLJhP9vK+R7M6yJDOiiE3WOvssrOtrNHdTST3W/4RPYeqe8mMuMpRp6q87ncNwd9CrCgKgJcoiLC
# DATA SfveSqoEJpCx4FHTLp7BmtQQdiUVJYngJAI5oM4HL4BtTlJJHCkeRMV4g4Ucx0H2Ri4aDHIz0jxy+JfX0IigTvm1TL6qRGLSGwED
# DATA 3kOjDSwntMbZ4rhRE8xlONcqJkmOnCTeGvCRQwgzrEp8VTwcZCO50R4384zCcKo0AXlcC7MgzGiUvbTAJaSzFyr1S5W8SPHckOK2
# DATA NnHzIRNJAsOcDoCzADy9hpQZL6qyEUEGois65kvJZrRwqu/KvUzCTdehRxxYeCpJOWQ5qkQEjBlhHIkOhSRKadB+JZXCWxTuz/xG
# DATA h5hno5sf+wnqk+joP9HHKMk0mV9rQWUOqlguYA5f6bQPsNAIPUDt2rWfaYXf5NvNlQ9wJV7pSbxSRTQZzRziQt0iYEM6WTDEYQW3
# DATA uM7wAnrQNpUjYWHFLpOpNloNZUIn5uQoPysyYchm0/AP8fzo/DXxS8/Cxg0dQcssL592qjAAgS5hwuBHFVgAWUw5i8ZOChJ/uLDK
# DATA H0H1X4IJf+Dgdzq3MK5tbQUkDxBXMEFuzEjDAAYSUS5jbA4mCU6HM/TEjCB3/QRoCJ/yyFXTlM1D0ecIFxmPN7IpCIPCk6mTKmYg
# DATA p+wAG/Rg4RkE37rZDchjM2d6flmdCs0tFfDECu8krkhDHgM8SrCciNglMCxtO6dGosZA+XymjUg9ToIp7FMfigXFJqX8a4+FU+GE
# DATA Jaud+VMuFSufYUGSFh0JoJEhR9oQh7inUxlJKcEZy55CW19FXHTWqHFtK5HoprFFlMcmJoqSyQmniLONEsg2L0q3scTq2sytgE07
# DATA pSKCzrg6EcNqRT4y6mM6I4UaxUr9Jw2fpzv0rQ5JHygqQsBHMZx8Xlths+R2kUgwZOjO3ApV26c+rWpVbryaUrYKoEY7i7KvsyVs
# DATA sWtJWFkHv/EnELCsmqYFbpd1ujzN1iOVmmS6TifTKVn20ZsqpVAAAgj/4gBYIVu3tgFvBnmdDD0hJozWhURP3krQwVFuRSvfW0lA
# DATA svZOmt9NVaUESaq1hFTNwVAr2UfpSbo0BnK4hVKZjdr+xGNrHcnTjjTIZMXiB1EA0G7XyJxIpuw3MFkQdG5Kn3Ew9YFyaybHjWl8
# DATA FGsZqL6aglZT29B+RYUS5gGMyTrpwMa4Hs2T0bha2nWaiEVIeWHueaCFgB/b5ZXsEh5qp9sxfmIhC6vOyOrRnZj9IOh+CuDZ7Mph
# DATA Vw10UHxhpUSRqo0ZfVwGjIzkQpVuIXrr3NOl2jiuabmS8wqbT34c8gKwoVrxtNLIQVrx3JLTCwyLcaHe55wBApt9lExdFLoHUcx5
# DATA VaTXgI+4V02OkXTuSedYuIi2NW6ckcQKua1BBzAhKk5g6STk+cUyZXyotVv3I9JSRgtZBzpBIOT5AqzQlHDuHJl5FAo9C4XWjFYm
# DATA pN6geSRxZs3Ee3gmUtEpYW1glMwx/yOZxNpwMAJNOAx0vZZe1JlP1jArxuby8uCaVPlwKSE/06vGbsvGrif5EgDOTJu4DBS63wxf
# DATA wGcru8t1tmjHm9mPiC+9vdA5K3UiUGMiC0ojQqVB6AFomjiX1X3MctaGhvoin5keO5JUhoW90Nb6V60jWv5fgK5EFmSq61Zg5SCn
# DATA XKGK/BsN0MnFRf3F8/o18s7N6JgN5jWKqimBvS/47JWT4q9yB+2wRRByCYfcmSgQjJz2oYBEywBPo9lJItYZvb1pCNwy4IRkXb9j
# DATA NeWOPO2kDkt8IFChJ4BJZcc/EIj2LLAEHiwiRKxdU4Yy7gONI+t4MSoTFMV0yuDYabbIn3kvuom2RXKDs6dzhwVjOSfMFh8XgLF2
# DATA vTBxOVVWsAhu7S50mOmaL3xEjpG8cgySiU30CBFTBgcrO57L31CyK2rFe0raSQNRnJ+mN0DLWDAUiEyllsArVCJJ85s154LcaIcj
# DATA TxV3yixVdtVG1EZDVY6KVrV+wL5gWREuPEJjZksOEZCu5SDV3QfoEpYiKhgyUEd0+OxgQhgb3rqncSx90VS52pv6G+hjQ/PIRGU2
# DATA WLO34zQ6EsSj8GFCLrtkl4VidctEVnGjjMnGijnfFIxB1Ybyu1jRWO1jEs8vmWbsmlPE1dZtVM6K5gxelQc19VdnJyndHLohRIOg
# DATA sOeKrNdaYJtxcM4HpqbqBpgtg5vTcHGVS88xEA5/35bwEFsc0Uk/dpxQ4BGsBWDNERsCy3HkkafMqFcYqkzSJaXes4YFqvJ4iXDJ
# DATA abr8WYG14TN7CppY18CECoyXf05J7ItctVE5nKbFezwaYYJTTkkWexo5ToGhlKlomByH0/HI3IFxFPJ0Knud2uwULBDTz7PHN7sV
# DATA 6wHP09tgLPGr1EpP47NGBhbvwYPrRq/QM8YaCLi7MaWLqdVNoKVwzyYf1+PVp+xN+k7BGDz4uEQ3CAa1LpWp7llquTQ2jDoyEYoq
# DATA SyNgKZzFUjWZglT1OBjzRkTMzLXnyi5NhuOYNCQ6O9Fo1PyXNHamip5N2UOYzjdUEkxOQcTdpL2tlAdfdBDGFcxWaTSneol6DCPR
# DATA oSsWNp7stGVmKuOZ5H+VMCBgwj60odbl3+TUhNPOlGaxES6xI+Rrzs8eCJs4sqpDjG3nsu64atKHxhjHwoKVotbAuqDoZKVe/VpV
# DATA 8gHLt1GgzlprUq5BdZuiaquPK3urScWjPFmQ44/P8EqwKo+SqodeF1H/VKSYp7oWJAoHURmqnGqkdn3RodOCsXkve7bblCZkiotU
# DATA ZRnT8YYpO2bSHJST1JMlytSpbDpgRcV3EGnsksuoiU4lddwBFARwZOYBH0I0MFtKV0CeC30sHqvuzccR1nfS3GaTK7g4hrXF8F0S
# DATA XEOBqFB4XGqB8qNwJWWDc0Y47W7e2qYICVdLuEcN4dFl2uvIAt1U6pQi5kgz66A60UpEkW9pw50is4fprXKBeNA0Ft8Th8KTBfvW
# DATA 5AwVBupTMVS4wCllAlGJB7JiKZRZ1oXPpqrnFc2XaqWbd3i863ga8OFDKlO+FI89t7ArH1aQyaT+Bq3yhqRu5xwjnGjAGoUuzyj1
# DATA wTnTe81sV+alCMM+ak39rmYb5dRVLOwBMNN5tzHr29MVQPlE1tr0UFtFUKUL3LRdcud7ukI21YbG3EV1cjd68AiOzhMPPFOyVw+S
# DATA Ox6gBTNF/N3ivuxI8BY6xImOTyv9VB2GWjNXmAN6FFOTmGySRTFId8lGRox1KtkeodQQQZFV5ptOd7jkwMZwktm+Fl1Bq9zSI1Rt
# DATA XuQ9ghethvUppB8JndCWGNsmkrZ/TGo9Vt37cZ5YVPk87X+R6IguFyOVRVEkKFM/R1q+VOawkoa9Fde1FNxknUt5VhgwPiRXdI7Q
# DATA c99kuaONUzv1IsGjiyBgOImaNRUVuPSkA3PGTPwrqLsyOYyT+Do2SRG057AA9TxbBpwYxWoyTHIaOyU6UaiO3dQ2DEDxMjNfs06r
# DATA 26YwWWqYxblUthW0EJu3umIk01Friv4V8SBSB+z83DgTU7WopItWy3SxG5Vvq2FTosLTgQqcq6o5Z1tGK7bztIBGKAGfwUdp4Lio
# DATA mZDFuYPFosxZEHcIVvfI0U3xZH38nlTUvTxaYKANrIsxT0iYpPNbOgFaVKiNo29ccg7mZmXycGZ2VdchyfLmCuvSmSkxZSoCsEZg
# DATA DJtcqpDWWUw6kJsSut7qsCodmRKveYNYPDakshqjF0WSIU4d2rOSGiXC50kMaYh6oyRymiN/5A9T9y4wgCYBhATgLLidUM5RasIF
# DATA MoJTN0FKpigfqpSqu+XEeGEpuUpx9nj5vlknq6oi2ppNG+cqcxHlj1vZG8q5WqXjPjb55Jk9Vchc5QnuqTWHnelEVkmlKXMeWxLL
# DATA DRBinaeZqg1cYcGBQQaAg47/caLlNCoaWm9QyTPPROlQx5EzxQ8p5lqwfSVQgrDF5BGIuCqBEKhhap4+ZOniBOvaC91WjV+9ue2/
# DATA COawWs16vcfZPle6tKnl3NPnJKiw2XypY3diPFvJM2QOYxpiQvUBxZg0N12MtEvGqWYt6SPA17RiPIzd/EXtWLfjl2qaVGqp0az5
# DATA R6l/ugTtghrCWh9TZbGS/4yv+WCtLVd3jp0RkVTM8svKHqSyakuqWMKhCktnNIBWVDYZpjBESahT4tUQRcG0W1VpDZCIQhbH1T6g
# DATA 9e/qMAJ6fGwW4wr2LJUD/OoAV5ZMluNFMI25UA5nzK1UinIcAKqchzqXhT4Jmrp5TcTKiufddvQIgMDdAyrYkXcKKW6IqCVHnYly
# DATA q/NrFEUnDRcseCz7oSw3Unz0QUat51i7Fd4C1jKxRL2XS4iU8yFyNRP7/DTahilpfalzeYKDJW1yUyhhNMftyzmSKmPMPbRlauw0
# DATA WjW84yuF+R2Jjn1oKo0/wVxro3Wuv0bl2+boCd5NGqKnkULUsXJihNMYrKrhbN3qm3Q8XU7Dqn4/pwmOzVnU1WLplP1HQ8pInj6T
# DATA SbaaVX69Qic66CFf5GXFb9YV09QCTM2DlTvl6XauHSk8ZvrwMWljQZG6pwtZ60PwAcgoXb5LTpUGuqiFPsUt1xdJoZZCYJgR23Vs
# DATA 1597l+irfbBdX7zhWRdvrLkiRSUUWdcRRY7mzRkfyuOgfQ3fliC1oZMvSDN9LdISy5SsxMiUpuTcwyF5zIX3jKy74YfPGLLZ4Jmi
# DATA KKYMrl39IneThRyZKs5Rp+wP+/yGU/6DcsL0ucrVgi0q8drMVR+6oKIFungLaeh07tfOnVJ76hEoQJ7URp4EKwQvf+lcdOU43HCu
# DATA KE+B3KTQwTOw5CI5KxaYsmtz6Usu67JuthE/3mPuXmJ2jrFBRBn8pZqOgAK7O48QgP4DqVKIhaNmyTzRx7ElfdVcUoSYRWA5qxRf
# DATA iPDYEF5j5ckNLTQE0CxoGhPR2UC+zac6ZKkoDNDDZWBJN0W6WML8kTxUi+kSqynqdEFPnyOQ9F9lbOh8cX7BPbJXjDAvh7AN2f14
# DATA 4MX401lrEtVrYfYbQcPZ88SeLB/imiuDxKWjkvEUoJ4GdK4q0zkQ+M6FS4s8DXmGhlaTKrVlyOi6te5W4uGVQfEgOZkMxPAqVSEw
# DATA 1Re5OTWYXhGYFqmzLmmDubKYQDtvbvk+PngSqbvuRkss1uTl75J7eC9gT3Jso6qLqby5LWXiunMTCN1wvUGZnUZkRYKUmsV4od7V
# DATA G8rDZNSX57S0SsHXM0HEXop/zs65pZpQkr3t2Wc+rFLtIFDtNyz1NKek4yl1SYhPC3KmSB+Vu+mU9KdJqYsmicRBZ3bIE9lfp6YP
# DATA BzBJfSXHA5DpfXFwcuAfnvpHx/5Xeycne0dnX/vPjk98eOC/PDn+/GTvRdU/O6bvBz85Ozg6818enLw4PDs7eOp/9rW39/Ll88P9
# DATA vc+eH/jP977Ce6F+sn/w8sz/6ouDI/8Yu//q8PTAPz3bwxcOj/yvTg7PDo8+pw73j19+fXL4+Rdn3hfHz58enND1W1swOr3ov9w7
# DATA OTs8OEU4vjx8emDD5G/snQLYG/5Xh2dfHL8608B7x8+gk6/9Hx8ePa36B4fU0cFPXp4cnJ4CAND34QuA+AAeHh7tP3/1FGCp+p9B
# DATA D0fHZ/7zQ5gZNDs7riJqVFvVOwID/b84ONn/Ar7ufXb4/BDwhXeGPTs8O4IhCHd7DPn+q+d7J97LVycvj08PUJgiCqETQPjJ4emP
# DATA fZiBIPZPX+3pjgC70MeLvaP9AxzLmrMHy4TT9b8+foXSAub9/KmDFETUgf/04NnB/tnhlwdVbAnDnL56cSD4Pj2DTr2958/9o4N9
# DATA gHfv5Gv/9ODky8N9wsPJwcu9wxPE0v7xyQn2cnyEJNSt8dEDHVB7rvLdkV0cIfUcfIm08eroOWLh5OBPX8E8kUJ8l0Kw773PTw4I
# DATA yRY9eF8dAlC4cpoofCaKKr0CDwxRfA3kdey/OH56+AyXRIhm//joy4OvTz0bI4BjQ657nx0jUj4DQA4JHoAAMYRr9nTvxd7nB6cW
# DATA VeCYnlx6XPVPXx7sH+IHeA60CIv/nNF0dApzxWWFH6QTfw/WF3tAwuQ19F7BJkDiO1JEA2PjbzawZTP2KkH6z49Pkfq8p3tnez5B
# DATA DH8/O8DWJwdHgCjaX3v7+69OYK9hC3wDoDl9Bbvv8IhXA+dL2/vw5KmnNhjR7LO9w+evTvJEhyMfAwqxSyI+ayW4xWml6uHi+4fP
# DATA YKj9L2TZfGcbf+1/AUvx2QE023v65SFtRRkHgDwUnMDsqAfBI1Jer8YGJF7+oanvdOWIkpFakcPq9EkobDZ2SNgc2dCFWzhPW5wQ
# DATA w1i0n3GKBS348BJXVZbceOG8fECOE8w9VA7jG7aClmTukXHD2rH0FNyow0NYp3Sc8plfPNz0hm6DyDz0mw6zdIxVEqhoNCsfqHIn
# DATA 18nYgr3AL+eYvSoZ2TkTZg6juIgwx9qzXCEynRKBVR1AzLuFbYH8aDkLb1D8gq+l2iMMcObfmTp18DVKsSNQR6X/TIcf5WoiuTly
# DATA Zt/BwJW06cYpCa8JkJd0aDUDUZxK8G6Z5Q4JVyWsli24mBRmeF5ROEZnCktINVl47pW0rOTE6l5yvhjDunbZun1aByczcxbhTFIJ
# DATA q5hxH4gv2eil6lSc1utV6ughmURZMMKJIbz67Ym+WHQhR3Ao48w6fcGXzmC8UtVgH996pEyJM9wq/ujWW6aeqIvsipxBpFSrInpk
# DATA 42yE5urKMRuxeOXhLCXfBjupVMGj0VIXtcXZjFDbBJz8EBFJ76pyedbcSxmdJJNuh/MkHmHgLdC1oyS2UvtR7qL5H2Jxvx/5/g/p
# DATA 9VSdwvwRmnhJpronOOwF3tG3TDvLmix851ZmL1kUB58fo+kG2eMV8aoySVYMfpNvM/fK7lHhyqqFUludt5mevmnrCgNR6pCWMjth
# DATA +8DKsbmuFC3k/0rZemLfT8z9KCe5YTcjL68vAS7XqUu+UZdO4/hxxo/cYU/3pqOpq7ICbcrV6e1uouWDfXtO/TeDRTbmgKIxKyb2
# DATA f3i1WMyyna2tm5ub2uV0WUvnl1sqE2jrR3SELyNDwKlAg7VemDtSkISvJaeC/egSnqdTLOmFF5wEM0xqgrnp/AyrHmMYmIsWGVK+
# DATA 7fgeN6Wn73S8NYjiUt7udfPJQklHliG6dAzf6s3ZmarifbEXfG5THvQRD1Wog6kc75gx9zqxq1pVKA78DXWVF7nM+JxcHESZhoFj
# DATA jMDEr2NPR8EinSDOV/BwQfnbzPKGS3lPKTBHNz1pU44kLykYaicM48VCsp7MeV11AdMTogF9/KClDEsdYM0Xmfs6h3REI2EqBsSl
# DATA t5hZIp5sc1OCut8vnlcoqw5tP9iafP0aRSCxGhRXQ1Pc0OhCGyadwrra3boR5JnObXDpE4neuV6SNRn8QSxOvY/oBmjAhPfgbvje
# DATA H/79O/kHNsjh/kFtEv0ex6jDv267TX/hX/5vo91qqM/ye6/Z7n3Pr38XCFiicgVD/gdd/+/7ewvn8nR9FMvzTuLJNMBYkJzQ5qPO
# DATA XESU3aHjdLEA3ovZ3NN4LOfAIpTTlO1GPnDq5Ya0y2kkNa6Il2y2avVNDGM+MWddlJbMl+ZSyQlWYeTKDrnZskaBi5/MWVy91pWz
# DATA UFQtZ5Kq9gKGaNbq2tsnp9Swf34fxkbVFJTBBV0GZPpIb6Zgme8fHKGi8hkobJiDnY7Dk7N9pX4TSlSZ+/DWlORTQHMQDWA2OS1f
# DATA nT17+fyJBEEoKxIkPyBua6ruwLyciyv5DJNQNjkJRY+CZhvdJKGupqK7fBDTatFA9rxS82dAd3zFrC9Bc1gOa4DErblak61hEL6G
# DATA zqv3t4KFxITeh5pNqbBoQZOfnD0/3cLl2kR0SCwGz/fQrZjk3MUS/Ew2cujm3pHsdzfp3fJ2rV6rVxSqFYHVwL7KDH3Rou4fWOUX
# DATA HJJjGojRdPkPsv/xXkpMoKqFP83+bfh/s97p9Vz+36g3m50/8P/v4t/Wx/7JkkoCquLmYFVyCgWxJrD3qJbsMV9Aqet/XAVg4mZY
# DATA 9Bd9VyEe76IDBsBaP97ySuiX4XNZpSeUkLzwR5m/q/TkcglZxc4oK1XU43B+OwPtM9+EfzbN3vov50k2CfbHXJ+Fv/l39otbYCpv
# DATA gRpL/GgAVj0Wztv64xk13QrpTdNjNIR3y+WKv/sj/63nwz9M7uVP+I9byQ3p0PSIIndlHvjTGvcqYedPa9z7pzUwb5JFuVQrVc7r
# DATA F/6nn/r1iv+jXb/nf2p1jf+CKJiB5bFDbrDyI+cgL23OLkuVGkPy8rJSdnsW4MV1eLrAtLUdShEGm6AWT69r6GH+bO/0YPDq5DkW
# DATA x3iz4zer9/RxBpZGuly8wEv7sh2/UR/AdgVDA8Rj7lGLHzl93VVh9cCsiScBzxZGLa8Dp1LLYrT6XgZogNXAgCqX+N1SBdFZYndf
# DATA yb+rmFHu/B1i/3QT+xP9szg0p+SGNMRTljWtcMs7sLMXoGQYJKJZfUOvHczn6bxceirMUk7ljVWJXKzGgNcy0ta59e15lFTv3l2l
# DATA jDRHBZL3r+LwNXUq+coZD+G/vfO2tlg5USKLA+CRf/qnz01lPjDuqcBEwLmkdBSEcpy5Uo6ubQKdqRArqy3wUjoH/emYCu6RAxPM
# DATA eaxlnOBFOFTamfc2CURTX/4J9oWnYyK8v9aXK7X8SSIqC2dacRo02OVytY0ulFKT3WaGeaHexE3FSC81681uvd9oNOstIJ9BPA8G
# DATA wRjt+oHOqRxQKfnSjrVOAgshNVtOdvxSo19vRcFwuxmMWqNmo9tsNevt1nanV++1OvXmdnfU6zUa2+F2NxxuD1vRdiOuh81+J+hH
# DATA QVzvDUuGptTJWdU7EPe5Q9aldhj1mqNoFPeiuFOH14NO1I+7YRg0mtvNcLvZ3R6FQXcY9Pq99nZYHwJEnVY97vdaYdSJeiV3m5TC
# DATA UdDp9MLucNgfxe1oFPb7zShoRb3tRqMxavSCRj/qNqJRCyfTHG23Wp1eE2azPWoGzSDoWP1d8Me7qnen2F3Gt7bv4tGEZYxM709O
# DATA j49qGbEHoN4y/V71y4Oqf01McXE7i7Fshr+7u+uXhkiWixLwsevaImWuAsxzBxqrIZB+7AGYh9dC8t5/AQ9hK18FzU4XmBfXey0z
# DATA VDx2pVKLkss4gx1/Fb/BDaTKM6t79+LoeQxaYKZgnQULHPD8oqoC6EBRdxUhkWTkc0P/j/5IT4ZhwwlxNd0SPvxobw46ai3J6K9A
# DATA Qw+kAyppMQ2xB+AF8uyzJfqL4C3+oCbhECgCdZ5DNEJduQBQrwglAkfF8C306JQZpVi8FNOCqU0NS3LrYQpxcg5NABvntVoNh6n6
# DATA /J0B0QwvHmfxo4Djsfg14ab82hPvzlqdMagGCmsG9w7KP0KU8zAl/y//0v+Ifq5RhCP7ClT9cukNbPvGTgmmJkNREx6csTG8xfI5
# DATA u75gHs2FsvSDhlC5C2ZACRl1t63wadC4m6PHSRBqeqw64nHv5cvB6cH+ycGZplMCbhO6wQlsXjdKmladccJkho793FBPY/49uS6X
# DATA gjjbhBE3L8NJiVanyrOqgWUTEPWBYG00K6pbehFk4mIPrJaz4LKca91oVv3mdsVdI8EPpn8Fi/K5dCJTyXWAL1fVOFSsqFy5qJgt
# DATA XlouRtuIzTsvyG6noa6Z7mfTYJZdpYuyYpVq8RkXtLNxtcByw4jOsPaDv1jG89uT4ObVFMNe5Y3Tg+cH+2fcckBBnWcnxy9sT+WA
# DATA ZX9NOvuKslq4PT/ZVQrBhrMQXCRxl4T4KegQ/H5tEszKC+JtNTOoQp617WZ4lznQ7vl5KYgmyRSWiihgwN9wh5W0UTqA1cEcuky3
# DATA Knh0cWEzBtweBGINtlkZRwNtkbhK7tfGRaVi6SNGfyiXANLRWC4xxhh2eCsoN6qHwQc6DIy8xX/kZgeZVkoihBsWcr4YLJf8DR8i
# DATA JPh5MU9/GkwHqqQy/nSNoWfdGD7qhxdGBhGqcICiTtULA2Qz+MM8Hcf22zi75HIA25LKxYHiuMQzyquYlSc8Y5sELIlg/5xMhxiJ
# DATA g61k08cqCZyHwRTjNHRHSBKPo+zC4sQxnmsGpkt4dXg+vy0LsuvrXljoMP2AELXJCYQofy35n5gXnuS6VPLbUIhuCpqxNdCO1YTh
# DATA wOcCEaPriUOJH1HXMAn6loOY6KS0jggpMQ5rJ3KrJzpz+ImQn4HfnI65hyWUhCWEeFHj9H6ewG0KmcIPGpStYPb47g+a/vEJZq98
# DATA hmHKCPncYJZmlL5HBMlcpMrvVPLIV2Ptar3w05qhkItPNTAg2pha8JOeMjGekHSimjW1CjBcvDaMH30EW4VYdDQIFggTSw/6dlFT
# DATA RQrKYaXiLp8MXcN0funJDEw/BvhjYI9Maws9PbSuWskQDKB94VDpCqaSCNfXHX915kJbyBmQOPkT7gP4k+8xo6BpjP2iXqO27DnW
# DATA K4TvMv2LykX+RZjYvfLnPwmx/eCtGsKsU2mj9En4Cfy3UvtpCtpNqVqq3DEpbvzgLRHJ3cZ/Wpm9mFDIdBTb+Oz2MLK4UI7NIPKB
# DATA rSColZyHoGAz5rhiKf+K3tGuQgu91/jVT2vC/2A01MLME/2gBlbfJSiBayhDxqZqPtNUsdPM1l8LpinNZKr5IYumoacijUBgXyLI
# DATA Fv8mDmc9fpCaMci75Ah1rEGCF4uAp/GtsYIocsZafePOW//NQoVsJNQuimSrI00r1ganFK30poL/OeefUE9n5dv6LQcZU+S5aHPY
# DATA LokujIa/SvnU1UUl142h5aKuRCqiQn6gJONKx+dhgY/Jpe8CxQmVIgaJmqD0Ql8aunzyFpBA7gziTOQub5kZDo47VDhJVTs5edI7
# DATA 1uTvXNZbKAwqjhpBKj7bCkUKhOrBer/Gw1eK+IGsJlp1ZFJxx0X7R4iN8taQ/+j1sEVO8bYTz+c4esaSzAg9G0pGCswcgUEEXDxZ
# DATA v4l1Z9q4w3O5xS9IgxyiTA8sU8rnbOCS/XdBDgtjaVrUqqGD/+AbF0U7t+A32niMvYc5oshIDKpolOclJXwu7fBP0q0IFr+U32x3
# DATA OYq9KzbAc/YYhmjLtgGubNpgfnl93uT9A9DGYDZcXi1Kq1rrxHbNPaij6dYk0cGGFE8Z7pspZcINsOQHV7IaYMARvosIHbBDe2BG
# DATA 3CitClPjmkQnT6H8TPAqQixPpTsq2jbYquYCUjGqqrdK/KyjUO81d55PVjr/aOvPz4PNn+1t/ll9sz+4+OQHWzVMViUDj6UsdWMh
# DATA ZR0l4eFFzLBaWP7VvGwyI45guIu33fadGpCGUatQWT8I39hiPLihcaACdRLYRTgRb5sJUUhQwqB+S72PtG5+r2V/MS4V9aj8OaOs
# DATA Fr+Bxc5OgaDZBQU8Hn7Fsj3PQNuwfs8bMJbNNYKuqMtPV9wX0BPVNC9vfTP/Zrp1CZvumxXUKpYpDl/VG4ByTh+qMAT+z+pMuppj
# DATA Zxcs6rgE1iP9n9I65/nEWZ5fFKy7hs2YA/lFXycJsBLP1IhqECTHN9NykVu+yiQA0y56eo4PLwqXQYPJYyHlFwBMD2s53z3vE360
# DATA 4nn/kMm68Rub7pdTBsu+MUKTqCF9/5PCPslD/8RHfKAx5OwYByok/Sc6TOI2LGt0nDcucMYlUqVFPV0RA6tqJCl0elFqsyXQVMF+
# DATA vSvQeJida59dzoa0OlXCTkmPbBGly0UNC+MD7/8SeQcdrra48yoryXjCVrdG2CGG3M1XPJSOummRRfd6xZF5WVzZa4Wdmq4j6wpH
# DATA k0BEHks5YB8ajwOBBZJV12Hd5bDLLJhncTnP4eroJSN+ZSEnB5J2tj6EvpdaLSHnTFUu9CSXE6aJYwCRr4omW5JSY5TWrZMBVqbO
# DATA eysnSvRVduwnZkWkRmHVckzxTdQ1CRXpOK7RT/LAiqxYwdFPfbP6RFISamWqojdrE8xwvYzRabCmrYRldUTV+PWrFskyjd6qY8Pa
# DATA pyouYyzRYqU5YDUaLEtTQ2eXDhq8SRb7mMq16zeegDZZk6L/kl2AOhRm7HI8vYyL+2+f/xNjQjLGjgfj4BbJZnb73eb/tJudRieX
# DATA /9Ns1Ft/yP/5TvI/P9paZvOtYTLdiqfX/ux2cZVOW97GxsYLvpHO53K0hk74JH5mGTSkEKqDImTU4L55moavsXYS7MkadOepMqLz
# DATA S2J66jsms6vPo+kEeYX6+tMMb9Hmz2nGJU1wrHEyVEVJX8JX1WSu+8xuM/URKy+oz+hc9Dx4SDFR0CaAHy6Q2QIXLGNP5cEAeeBg
# DATA gHoiXa0N7AugRc2soofBOz8mUmHFzkM0Royv5zaZBJg1SYmrWTxA5uR5XhRjHd3ZLI5UBBusWsyluqnsKKstyRRLVG0ASnlsWYEI
# DATA Or4H7JADvyC2y/gj9Fip7FxgVyrY7avf6WpRK+6Ka6dfIp0dRBexeWq1HqQx8MxVmM5lbqgPWVPjK9LRTkskpnuxvmesSLXa81uQ
# DATA XTv+Pd2Tl8UZo4bfsnLFsZ15WrwQam2QJrIyeyRXFkQHkZBca1Ecz/CDtK7omJG6Ay1R5rkkLvHPGBh8C1KBRgeQzPSkwXkJ9iCR
# DATA YAkdUTLPgof2tAF95gkVEBEgaAHPLxxr+RpdW7HVigHknxG+8wsLrILVoYayPCQq+RfuBiP9QDmcJjKNSjsrSiu3Pi9xNpI9y/wT
# DATA a4rODEg3B/jL4gSnaGsWg2heZKUc7N/3TwUXdIM9VvmSM4ecbJFxQWDMKCLGkj2RzOooDsfB3CrjMIzH6U1txZWrskIcbLIXZAWR
# DATA 95M64bKk15Ae7RRaILzNS3kqcX7OI29E5aXT5ewxmHMmZpExdbCOgv81ZvdtZ2aI2t50hqaLIX6IsEtRjEvKAFtEHmGO+nyQzhbS
# DATA tzsRRcd2s4tz1VkBwa9pmJ+o4/UT1gV6N4gmUFrVvBLy0orYKUNnJIOxs9KMlntzE/RR/vAXyyQGg0gyVSuKFVMGX5StMvULGwwU
# DATA zbVxGkTIMQtGA7zi0QQY6WPoDIQnA6y3YVRmr63kE5NdwrmCGNTCvbl7lE5jmdZIiuFTSzkRL68ZOMcBbFKevjzk9donYhcyoF+e
# DATA U8sSicG3dzZBuCDwcRhqzC/CVGs8yZpIjZo0Za7nvr6TdyqRl9FYa8hw0KH5uBFqeFIQ9KpBlMxxAUuV1SiK//Ej+5L4IQcPqTOV
# DATA sFwt7vd8gkWPuV8+sMmvydHcJRU7z2P+Bf4uQuXiwsZzMJXsOqWVsE9vnVrCT0UvcdgTITG3A4VEz+aCbPn+DKw2JfPRlB4oqVxG
# DATA rayqbzXlRObdxnZd+o3ANKeDQrtcx2uSwh5B1beMMEl7anlzRWfy841+qLuwuI+zUxmCdXsUNhEB5+5VIiqqGYp6yYduSGJ/AENe
# DATA SYCfUYOUjomq8TuPz8dmxuNyKJSAlQbsnXWynE7Jg8VW9JpWX8TBeHFl/4JNlrgjUTwd0eU+pStqdSsrHhJ9CVSF6y0P82T2LYCg
# DATA lISpGv+h4YfzOHhtcsZx8bMxKIjlpjDuAMvCfokUK+6S/b2j46PD/b3ng+d7Xx+/OhscHZ8NTg72nn5dUoxSDjwPllMsmlWep+mi
# DATA ao6/2XzTYpFkh6EyAraHvFS7HKfDsn4R99Dmx6WKKwb5Lqga1nAg+6sMX+IsDGaxeRNJfV7a/CZ622jfwZ9PSpx2W2MfsYxeS7JB
# DATA djvBo9zlCl/AudAPgHHxj/dIgcoDTFPwgqc9YHb+FqZ5hq+Xs2wLqACvOdlkL0YJHmnw8m+LSVebvEaQJmkU79bTHp5k4AfZLvIO
# DATA FEhg3gzS1/S14hCWdMTRirweZIBU7ZCTUdSorH5R0ZFNdGShYVrD/7TB3ryK35zvbFvha5oHwGW9nicTUeiETqgAiI1VW5aCKb4n
# DATA 8LEfXBLCVJ1punmFbo4xhZKpJgoYe9eWIk02PdE3LgSvh7GaJdFOkd0uw6TlEv9M+mf+IF9JayLmdT5VAIorHUnC1/BUzJrXLc1l
# DATA ZecdHn259/zw6WD/+MXL46ODozMZzfJu7JJPoUzwAgelm5xBwypdaLhM40Jydx8T0d8H0quj071nB4OnBy+fH3/9Yg1IVp85FGOt
# DATA 0ijg8BnFtYs4gQ0SrCzBhBKgwL4ou4ygJJrDN7W5OgyMPGD77gz+2737M+QE39RQ+Dj8oMhwUSxC0r780n4QRbeogtSGdM3fJt3f
# DATA uXk9m5aKOtCXTK7wGa6gwb9if+XKha3NGhytKLW4LzxLWFAvuPSwD2HrZ8nPYv9H/rb/sd+oN9vqj41h0/m9q/z84PO9/a+B7o6e
# DATA HX4+ODs+BtZ/8vlBSW0UtVMx1myUet4F+lmSEcAss83vouRc4p0fc06PI+q90IIBaBhvejYEUVbck18D8q7U5iQqSh/zauZEBPfg
# DATA oD0nhNcR9snB54enZydfW2tqYK2hKQSqivjUSIEp81gVbh/w+WbMW1GKj+1GMl259is6LclSEC8RhebYF2NxjBcmuM62QG5SjqpJ
# DATA XVocLIufifpcaOoz4JQuxr5Fet/lKLACfFrC7Gqe4vf9fR7C3EmVTAUVOlCzSNOav8eMO+JaTlgpJltISZNgKn0p71DVR68Mq+tV
# DATA yazmC7zQB8DVT60rnrJFioaq9m14Jh/bUl1t1yZzzQqprgImMumPKYlVmWHwbJpuUkGYGV6ZG+vfAM5NQsRSZeNubnK2L35msiQg
# DATA dLWrvOJrvHGWw0faRMvJLCvrV0G8T7EMziDIwiTZJeuAX2UP1EDZZ29p9eRUC2wF6yvuB1XGrSweU4tvb1nu06KcSOM9yglHh7Tu
# DATA VoBSSQPOUMRWXQeZZrAkMS+T6Rsy/EqVSoHKaLp3Nr7LV9cz4RVP0KNY6eq2WeUjp8evTvYP1rFOw1P0en+yS6Fa0KtEcwqiwSJ+
# DATA syjD4xT1mV0Mrm5uSw8zvCB9TqlO54v0dSxlY+kTcRiM4kVo9cxLpdL5n3+TbZTe3j2pXnwCX6vWwOyK/ZgcRvw69FP6NPf93Hxn
# DATA Bk3bkUa/z8Ze4/54tP2NsFn9n6GntipuWstj64AEiDy3PV9ZHijL3a331b0eb69oFzzCJf07eaEvRJ8SBIjVsc7hyXNfIWck+jVu
# DATA yxUjxexXPFm+yhAqOSXOGka9tss7M53rciPs6xDTJSvYODmvx4rn4xHqovVY7WANqVLCWQrdo5/dZ93pRs5KrOnMaIsytNlq9wyP
# DATA apzEEWvyN0TRZI6K4m6vqHnjF0EucYG1ST8FpFLWEMKWqG1pjsO/aMdV5cPVUV5lsaosZj0XO0iM3pLlE7DoWb8tH7boTZerz4vM
# DATA l7L8rsxai93PbXvmsbrfZ3v7P371cvBy7+yLUiUHXoH1vcbelvbhFbQtU1NRDbWZredZLrE1u8mqQKFx7by8AoWIxoSPLJ6/LdFJ
# DATA tR17YVXy3o4KBdcoaMy/8pLnXaglHED1YoQi/ur/kQ8D93p3a3aiuN1lJM7pUTMHBR50sAQrhyob7K2lYO4QDRr+g4oZu3x3eIZ3
# DATA FWH312w2XKjyFy5v5G0c06V3ANvPklnZwFflrtYoAHkKW4sx/6NdHuFcoffiMcqBaAVYffLzg6eDp69ODo8+H+yd7H9x+GVeRSjw
# DATA o9heIrcx4USZJ4ZLsYff/ww4yoEqbbCKLGZWWJ4TWBz1VCkUKDR2wWa7V7ciK70IfjU3l6cSzpipYMZSufTu/37/N+9+8f6v3v/t
# DATA u1/67/753W/e/fbdr979ij/++v1/hi///f3P3/8VtPlf+MFv3/0Svv7y3a/h71/j3/d/ywlYSF7KI+VEqVS9Romwj+NgupwNjLGW
# DATA d2g6wZ6VvAr062S+zvJA65D5NOnNmaFcV/11nUUOf6QE5hUbGBmI8svVLHNjHUF/ewt4RbF2u+J5FRrHLFHs2aOW9vbjj9nOtZxr
# DATA O0Xesbuc9Uy4pNUwStrFvT4JHjqOpys2OdcdVuaMa0ZYFs5ySnoc5uCz2W25pyn3kD1vZiJ4wqVQzhUqX5r9+bsmr6fAm5c3uZVz
# DATA T79OCmk8fZxD+iEPbMVK9Yin5BXQIyln7hRN3THYSfndYZKCHnSJfivv53oPrjiO1uwVJ6xgbximhF2/yK3jrVKEWeqKs9S+IqoC
# DATA wrlvnnp+FFg5PDo923v+/OCpAEdh9QXegHWfs7eqpqyheXhXwKygc1Teufudb08lHxD/Wc0Ig14teMRkQMzSlNA7No4KXdffJgiE
# DATA fZH4MbP9vn/wBk9XJguqbjSfBuMtqYZolBHOq6HLcZIxX+rCMvfbI60IATiATFfHn3h1VjCAzYxuFsXXCmXur49w5psAn6X6Jk76
# DATA A1Ghnf0gNKjyCS6YNQqojo5g9cKPHWzc74bmeOPTQ7z64/jka9gcg1enBwbCovHobnGNsgcDGmbyZ+in4U2oR1ROF8mwANkVWgFW
# DATA y9eNx+4el8BReVxyRh7BLOaGtyoPAF19v/uQ0hkwKN+amAx6Z1OlQgHeQhpPy/KVOCB+N4DRmGjWrm7R0vne5p8Fmz/DE2Dm46C2
# DATA efG2Xm00e3elquS7zbXTRilI1gCPERovT47/BJYQKAbvgTErSfn2u36BG5gfU2inOEFBsh5+b75iJ6cJdRUbpz9k9YXhK3JaPRC1
# DATA Y60OL2XRqOF7dtRu4iDqbi6/lMer2lKIm0vJByvtkxnduobnrqv4gsM+c2EJKKuZMjcVZQKrK4lul+8Cz2rfvsR7HaifNSOc17Ut
# DATA ikkeOKDjdK4yrRskq9Rb0lweyhi5EM2BYw75vt2OaU1txxB3IjuafCOrGQIl9g9QegA5BtysiPWuAn7/gWyBSoGZLpBYapNEOpWx
# DATA bu2TdW+q1XNf5G/3v4nFAY1XAK0qcQhgkjfW80nluxAXFt+RxdhRGEVnB68ItaVP4jRQp2m4yIVXHNPIk9CqDSbA25uEZSN7Sj0T
# DATA PZbhzpVfDY8OBuiLHCxSznZH2i3nfP6V6n1OFxVtexqPArp3DWz2MV4joIsZ4i9zVRoVjxKaYw/sEKHrUGorARU1sWm8XMyD8UBN
# DATA UPWX8SzPSf+ciTtyLd7sAOPvExPraIlcPDka1HBUrAD0/HagOb5FFQorj4g77/yeTG5JN/RXrWndZApoGqh2BeczbC6sJIt55aPd
# DATA ogBBDi3Fa0b2Ny2aCRgqp5zlvJcyQGK1G7eHKMqwzsqqsbiAHBPcNMbNqpMvJ5Bxo7NEleRG/NKqY+6gJUFtNOTURhcF8tD1vClg
# DATA rR0O6re0yT9SuHCCG7Zo0LS4s+Lx85U1JjHSQjdlMeDaabicMvUZhcDZJ/eK3CorAjaV3QyKlCaRupWVVVEvPKgqSUa363chnp13
# DATA Yqx0vJxpzQpMtEx/GS6TccTfZkvOSqWKz7oBZeoiZchIzugiRR47eqTVuDAG5Y7p/YPh+lhGdf25JlPWzf01UBS+thp65X5WCUUq
# DATA RZR163NlRVwUWhDn91kPF95q9pQcXt219CA+g190ykTyfNYCczC9ZkgwuAqcS9qrUe5tbqPkvHSI9cHZR2felh+LD7AUevHpAsOT
# DATA Ad28eHj2tfLoF2SCAZ8YSHDY14CXJbvnCKM1IOnk69MYbzWWFB9JVrf5xZo4uRUj5zgyj1cADJLP7wrMQ1H7x0PDDh8N0Ee7NnyP
# DATA XYynx/s/hpX48vj5qxcHj1kQpYwbGxsPfp8qUi4e17IxZPZketiEFZXcs2tKYlbt00mOdFUGR6EUENVD9eK5y/hhkl/7c7gv+7yC
# DATA Vm1W76jItkoFEuaBeEdCJ84XtwWkBzDL3EhKmSRj9U7ZzKtSFNQoFme646qFl+Jl1yB8xDAUr3VOcVFxDf12YbroGslLQTjQiHYe
# DATA mMR6+N12DFPVX5G+TjM5G69ktCPT7w8JUtrNdV4CO9pXXjAWagUfrpZxHJvqD+zcV2/Nv1d9KVp2/fI9epMzSPEy2kpc1S+jkVLF
# DATA kixxxVHpijf1A5oY92l1ufKyq5Wi1VSQ4K+01PsT/XWrNerr78K8ctTq8rAVK9lJIXB33c7vQfFVm8fyYzxG71zVOZUW+YGa3gfr
# DATA nN+dvll0wmyloYnNG/U0H1QqjoJoRqTOJHmPihrZjSVaIj15Ht40OCD5MRiQmjEYoBwfDOQYN1VtmNOhFq7gUNubXy4xlPOSnpSj
# DATA WIuw3cEAeMlgULHexKDnIJBXyoBIBA8L7YJis/uS2LXcfhJZHrU179pnSMKrFJG8e/6Y4yEX93fLmQqbJr8qoJp6uyUq+DTAYoXK
# DATA vTunwtHSEf3BrlSSo8PhiaFcZjWVCCHd52h0NUuCXuJV5Pd1IM5bLwt1qQITT35EP3aCyP/17hfv/v7db97/r+9+9e5/YF7ILzBj
# DATA 5N3/fPebd/+dEz+kbObq8RgRhmWjUFb941P58OP4lj6teNZPb2HCk4M3eAD13f/z7rcw9l+9/7t3/ygw/AMM/mv4+0v//X+Gj/+D
# DATA IPkHH/NR/Hf/BL/8AyaovP/fKEXlNzX/3f/5/q+wBf36XwF2aPZb+Il6gq+/fv+3OK//l7Jcfo0ze+K/+9X7v8aB3/3P9//13T+9
# DATA /zn09S+UIaOGfP+3MiCmzvwX6utX8Onn7//393/z/q/f/10N6OLfYf2Xq3g8I5E/XeD1sqQhfsf3P3ZbzW6u/k+j1278of7Pd/EP
# DATA C5RtkCdb0vE2dvyNZrcXBtvNUdTqjfrtZqu13W1Gw3az1wriIBr2+hF83w67rVEQhc121G91++1GJ4r6jShuNvobmP+4QU7jDXVR
# DATA z4bcp7hhbu7ZoGqK8AMM0NtWOZMbBo52r9/ojSKghmAYBfUwGnVb0TCu93tBd9RswFv9sNNp9TvRqN5r94atuFePG914GLS6AFpn
# DATA Q91+Q/3qq06LQOj1WwUAdOO4EbSCIA6H0fawN9wOou1eHA27zWY/bHQ7w0YUtYNGo9toNLCUVRA1262gPQrrYXc72o5cAOy79opg
# DATA 2O70OgVAxL1hr90OmjDKdm/Yj0edoNsN+0EzbrVDmHDUbnZaw9FwFAXhdn+7HgX9cLvV7wftYavd6A9zQBQU/CoCptGDPViEkmi7
# DATA U2/E3eZwBIvS6rWH3agbd1uddqs9wkuWonowqjcBZ61+AxDRHAGu4qjRaLV68SgMXWiY/QyGdMXmOkganULq6LeAMvr1VjsGcgw6
# DATA nWGv3o62Gy1AU7MbNMLmdmvUa3a3h91uELU6MWCm3ewCtfZ6jX4YtVxI6J67gQjhNZC0e91ClGwP+41mhBdLhZ142Iz6ANJwO+r2
# DATA O73WsBPV681e0BuG9W6/Cau43emE/WYAjeJWJ+xFYQEg2RoI+t1CEonCuB4Om/3OKBwFYWs76IT17S7QQm97WK/3usNGIx6Owg5s
# DATA 23o92K5vA6mG9V5vOOz1+p0wt1FAVQYQ6LhoMRQtwGOvAIwOICEctYDyRv1epw046DZbvX47Chvb3U5zFMad/rC1DevTA5INGjEA
# DATA 2w3rURPIt9np1PNgzH82DKbrqKLdaDcLYAAQRq3hcBh0O9B1vT+K+6NmuweDN+qjdnu03QljWI16r98fjUbDftBv9nvb7e1WN27X
# DATA m92mCwPdvjcCLecG7Oh12Kg3G/UCSIZRI+x3Y+i9E0edoNPv9be7263hNgy7HcIfIN9G2O1F28GoBxsojFuNeiOMgFxBAnb6BZBk
# DATA YHWtg6JVvF+HMOnt7QCWDOi/F3Zh1r24Wx92Ws1W3IffW53tIbDQZmMICA23A1i2TqfdaYbtCPZWbw0UgxCY2Ti9XAMNUFq/kFIb
# DATA 3eGoP+p04noQxUPAe297ewh8M2qF9aA7bPfjRqcDPGQY1YFU+/F2t9eud4POcNgIg7iRIxFS+AeSlJksbtft23aniIFE/agBjCFs
# DATA wP+6nXa7G7bbcacdjOJup1fvxCDMIqDkRieGTRpFzcZ23G/XG9utXrMR96McLMo0LgZhG3Z+0ZZp9tvASvt94FYxSJAY73wDvh50
# DATA t+NGvx+NesNu0I4bvag1gpWqA/Pvh60esP3+Nl0J58LA1UsHJM/X4aJRRCWwG9qdTqPVD8NOKwayBdbeqMfbDSCeVr3dDofAqUb9
# DATA ZrczqsfN+vaotR0DX2+FPbyJLs9LbbNrnbBrw+oWMvUmCtkYBg6DbisMmi2g2XYUgGTrdaO434F92wX53u62g34LhF0XOF/cjCJ4
# DATA KWx01gMyMPdYrkENMIUiku3XG0E9Dra3G8Gw3W40t4HbNqJOA37od4ZhAzACJDrcBv7SAL0pHNW7YRdUkGa9vY1UfA9IUYom9jpe
# DATA D1u0aAe1+/UOoCMehkC/3QjEcLMRjFrASELYxF1AW79b7wJ0IKm7DWB8CHXcbvSaddhH9yyVKWC4juc2t/vtIpACkDtNUONHYa8N
# DATA 26Tdge3R7uJdh4A7EIbAg4I+LBhQMahSvWYrGAUgQ2AOQa/RvQ+k2T3CsNVp1Iv29TbQZbvVCoHVB512Hdaj3hmBpGvhXgZdIopR
# DATA CYhboMOCxtBqgZo0rHe2Q9BS4K1mwwVnMV4rjNvb3SK20uj3gChA3oJsHTaaHSCbMAxbgAYQS716ONoGDRIIZNSOmnEAmz+ClrDn
# DATA w2G33mvl6GU5uhlcLoN5tI7TAjkU6SQjkK+ovndC2ERBYwTzi0CT7TbCBihKoxGs1XYEvCRuguYOYgdYUAcw1oB91alv55RGdhJt
# DATA wlqs1wk6oIEXAFLvh8GwFXVgrBDIJGoEHeAYzVGn2Q+AebS6AWClOQTCqYNi0AIKjkFV60UNEJKwUorBeQLMBt/shMRIX6/54l2i
# DATA wlqz1ugC+u687/3h3wfZ/0YB/ze4/7sL2lne/gdV5A/2/79t/d/PsFZEMPXVoYu5JLxJ+V8sHZRMJkvSOKp+OhpRjTSmJz9M8R7B
# DATA ++r+8vWc6ls8n09T9eXyZ8lMfcaLbsbJUH1N0t+9OPDVcpGMdX3gYI5+Cv01nszs71wyGPMTTvb2z/DWiyKHWcl7dnx8dnCCyRml
# DATA b6bf908OXhzt7b86PRt8cfD85cHJ6eDLxjfQ7ODoKbX5vg+fButa7R3tf3F8Qjeak6sWT4jNhxvlTyeVP+eWg89eHT19fjA4/WIP
# DATA 2Oxuyb4FpPSDjYr37PD5wSmmo5TyG7zEeZ6iquI32y2Rd5oX/eaoCfblxSVjseE72pCl2yPH6lNOluiWlu2tXPi25eUMlNNzVyCc
# DATA WSOv1wFXnmp1jNBS4CjB3x3rmCZkSWi+03LFKNETEgPO+W6ZUvi7+Mnwo/ZYlSrei72fDE72vsLS8l23iAY9wgWHZ83co9zJsqiM
# DATA i63qGmJl7igOAY6yUxFDIkP0XF1xMuTLTapE4LpMndxWYnUq78q2rckRX2qAGdXqslx5X6T34HWsblve8dYWpStRrSn1n/KnO5vW
# DATA 6Qf8fl7bvLB/qnxc+bSkYqT3nnGQ+wuEeQlUujgT5usP8IaEWF3nIYmaGPZZ0NWR5dKmOkRDuRejhI+ILZYz2LxYYxxDKxjhldKL
# DATA WI8oyQAdWM+RK8eUG1ynqOLdV31And000KjSnbWS7tpZR4YB76RJ+OjY3H4Fb/1FXA/TdFw2ncKv1kx0qWwgFdp0gk6WCLs2gfFj
# DATA tYq8Q0NMaSozj6z4P/Ib9y3GU30znyzHKE0X8dycURJei0VHpk6Yjb5Wpb0v58llqjJ4vuwht63F04izd4AtP5hjfGhuZyqCUC0U
# DATA icNkKg/PdzbxVA/2f8Eg4fOiEsoIVhkf2llFKDKe7p3t+SWpoGhvDHy4v7f/xYFvywHaIOp7q3lHewH7rVQec7L+1TR+M+N7Q5xZ
# DATA +nJVkVkPnBeLLF0ph4mAMgvvXesXciGj0TFkrGAaggLh8iNezjleHj4rMxvyP2F+JPSpIHZoVN7OQWiRcuW8LktSHm6UNirnjQvN
# DATA Fqk4lGZ3OqHlngFAoEA3xWJ6g+Ctl4A7d9v4GYar2rvK1EkOVPWUSfAmmSwnu4rJGw75YMHN/NHyVfx/wdim0w5YMQxzUpbjYE41
# DATA HcwZf+vQOVIjD5DOYN1LQHwVP8iwWRxMzFh0Bd6u/EynEMoyE+iz4dAOCQfgCvL8EfBSrbNFmvpjzLRxqSQv6/R1C1wnozwPrEsW
# DATA cHj8AUZvNXvd7cfgSjpaGV9mbJ1zw571cedYxCTuibcltmLpDm0RNlWs4m/CcCVdq+OOriuFV8/VWxcP7qtX02w5m1E2qtpRCu5S
# DATA 5V9fwjJ0aiYX317WFkPlaLdqNAdZHzQkCy26cNyt9sIdM9adkj1W6Sl6qipPyX7DtSWFW58q5JIo6minfEMaux/MvFxhK6pU8dxU
# DATA OaUC8KmclbSxYiTi6pkTopsXsMbw0+z2L0HDr/ylKJ1/yRrnN6ByVuTo6CPEoYNdBIpq5qzIWguLXKxCIxFRRmqLbA69A8i5xDvg
# DATA YbrAHkz1mA+FW+XMunBjclKZO2ZYMCc7k3OHCwVX3f+h7zRCOlAM+wPhwEJ5Zjdky4k7vKMDMgGouh1IYWIlPIKPMW2t46K4FSxZ
# DATA xJXiJaEM2FpVypJJ2URHDr7F1d9hEUan53V1Jj6to4uc0dlyOcDzttjskcvGJO1xtUqPfQbI4fB6G98pS0PuqyuLkkiTsCsXCft2
# DATA etEVf9lqIUmBdYpcNYP4M7fIKwjUvIhf3c8HXIcL4slhCH6UchE13AclR8QIq/loVwscjYn7zzOvant8sfga1uP0vMqC9OWXtjim
# DATA 1nxkpbJSb17uv0TIXXq3kLvSprhS1HqSV1czTvC+UsCdddHpGuLX1+2tkA2wL3OeQ6Z+D5GZ4tH6pYLk25UOcBNZr8AmUL6oKmss
# DATA laq9Qa2mNHolXxxDSiEaGNbUPzNHumUlcY9+/LHMXMGwg2PcrS6/Pofogu4cv5OUaU6vp8UuW7Si1rqSb6+qwHURVNH6J8M4inJa
# DATA v6VU5+xGOTOesx3zFfjuMSKroL+CjWBbdGIM46AROfhKfM8lmlvnvZ2LAoPQMQJpG6w3+RzlSA0jyoV8RebfXVdcdb3QUbgrkD4/
# DATA S+QkPntqa8NuW6wiGbKqydXK1yX7AB24tc/hP3h8mfZ9OvzpbpLWPsN1Pjwuc9+VQssBSCpnOCjXV95wEM39ETLvwJ1mtiL2lAoo
# DATA Z5ZpFuIaZkOnYBI4PJ8u2C3Nd9gMkgxsA8sEMUyuIFVxEKhYfiyvsEF5QLpi6yGudgZzAHF1m1/ELOeI4E5JRHL3hS4HfgZmo1T6
# DATA 1S/WpHSv9jKaJ0r0MvawxshWyYxT05VHvvkm//PjPBB4zfgKiQoeS/mTLihcrBEuLJTHb8hXTzPjJhWmLHVDx81Am3W7olXN0llZ
# DATA 8bnKOu6uX3PYvLqqafW5VqmmUTwvkilhAELKrob3kEhJl4vZks4NGMKsPEDD/I4i3Zs1lFsoA+SE40OiIO/Vmo5SPmhEwJwF80P4
# DATA pbyqz2FDorcqf0QI1UeMWPi7jrZQ9UEQtNvwp+hYDmb305Lj+1UbQa50sfi25nT8W5kYGVpl8zjLyow33MCkcmNFBYJqt64raovQ
# DATA YEGhq7bhoj5knz3ouqNePtSqoZf8nD0mYH7CkSj2HFJBFGxck6kr15d2seXfFBFnxBTeyMuoPE+Avt/s0H+Ra9frF6obtl/oAR6B
# DATA CqaXMXrHbUlWxRfcepKWNIeOFBQYRFN6Gtcv5yiX2CnU3t5L67zV2lGtTDtzy4IuWKE9lFv6Uw0dCFxgg/WXimYnFLsT+8d5u1Sg
# DATA wSkyyRkw2p2C+q7u6cuDk9PD4yM1MFf2qLFP9DGuPulVColxNEP9VmBWaLmYM+osa+6DTDgXE3x30GOMuMewQttNbD9VJII3a1Ol
# DATA DXWeyakCumaBHcIhMjRlVZxV/64xRQ4nQYys32PJxLZ3tSsSE2qMN3JHdZp3S+6sNXXdmse60LDg421ppQPNxMXW23F4+929Ashx
# DATA fVXu7qyNV7Zue8BJVukdDDGqe52Q/UwXu019qbvieVIOecUFoNb/kS5+y12ge9befssm4VPblgFkPbufdVSc1whOdSMktVZbhP0F
# DATA IjsGzBZZiimfjeFV4ltYw58UeVvGpupco+kR5i/dyMZljuZlA5V1xxvFmb95U69zpMu0WVMH6JEi0JxUUxcn6X7ZBL7n6i/RlMA+
# DATA 7nTkdJ8ycE03gDhr3b2HCuOsnAA3jYtCOmvrLz4aDZfxNFaX3Xi5W1dXfQ76IPW97gZVftL1NKgzgPrcn30YsOAMIJfgegkqVjy/
# DATA 5kJbUYAZIZEFdM2XSnE+JY5ksEtv5aobqoeZ602SlHCHPfElh4GuYAB4QdeFpRpREc2FyWEyJFIrKF+UX+uy7RO8v36c6HvrSSHG
# DATA XKOAOAyVA1NJSEiZ+BnD8qPkzW6pJgbeJkZBkvmutYEq6ynrd3Tm6JrjBk6RRw4TUnz7Me9pJ0677bbXTU21f7Xl7i2dkGb67L3q
# DATA obhoh9CmkCbaPTF+KLypmZ7UKDNNOY3e0rfawcFPDk9hS8g3EOEHL16efX13T4mVlSff9/emdNeSFfzG65tmy+E4ya5oG2Qo680e
# DATA UPeLXiVZQXezeRqClYKH8al8yAK2TLwEpsBX+vkquKQSO7D4g6TpFc3+d2FG9zMkoBR13L2AN3E9FMJ90QXR/7qsqrA+Bk5e0+H6
# DATA AglOszyazBO5vcLco/KRzUms3xVy9ZtIz05lGbP9H41z8aEo7x6QBrJQybQrqATDyZG1+WQxj63NZPsaXNVjrSdDiIQ2vPO648G1
# DATA 05ToBR2uB9Oy8nspPJDOFK3ZpQPQOqB6ahgjKFW13vVAwYB8DYN7GxOWHt1agr+Pbo409WHw8IKsNn+gtIGqZqARSdUiCIGGLMna
# DATA 0nUHRI0eF7/KOLfedYz5lU7sggdcskBpvdRU0oQsA01XPWB9lb9YGjGDxGpx5eFCGEyb/z85Y5BPvf3u8/8bjWarsZL/X+/+If//
# DATA u/i3sbFxEmOFKj9bzujCmjiyKiNzDrfUsg7QKYAJoRE0DlHZGC3H9t2096T7U7r+ByTpL4eiz+hfbvVH9Ll63snBy+PTw7Pjk0PK
# DATA dOcDSVICBv0Nl1fhvJakW+N0sQCTfstcYKvLxKz8lL+2aX0fq5VlnP4Kbl7hzrk0zf3wqeo1uV+ghzuPb0OkCVtzvVosZtnO1tYl
# DATA 6AnLIXqsdbcnuTneOZM04DyqC4bjzjt8sfc51gbMnVEQH8/OeX2zH2yOODGn4j092Hv6/PAI89MpvqqCILM0S6jSkb7RwGTmlf64
# DATA 5Fz5thKpNRdRSy7zH5coMKuKlOdbzaXZjm6mwADqD8YDLJddZnLHVO90QdkQq7ew6PI61p1D9BqCy+9brn6dQo0RGnzIxRwPI75F
# DATA MR8TUHi1IgOmC1IRrR75XgGG84FbapzbUMsWICewCGfBZWaqe36y8vwpWbqmianYe4M+x3PoXEqcjdxb+rhEor3KVNnN3rjnGr0X
# DATA FzYyoOt8EeHLSypmJt0l7GzNd2/BQQeUmJDM/YF3OT8B8T5UidHcImsAR6KrcC3Q/WCcpUwpZFll4uqB35Mgi7Narte96xTsnCB7
# DATA jT0/paJ66JHgDvBMFb0HHfk/xcxb/j3CjuPxyO2sGMeFc+PEcBcf8rQAexcFRaNUZUaL6DBlHE94JOGihuwb3ah4lXGlYnt8xjqm
# DATA pdZ+Z81tmBZtPfKSjXR+SeFLczlIjTuR60jX3aEJ0xZmaRFZ0b2Za2d+br5cuPEofkkdgqEFLn+MamSVBN2AlclcdhzqjXxvQquO
# DATA cGq26NzrrX/dJDlXm6SAWPS0l61rZFRXP9z163lX6BkXh1RGN7Em0e9AVgcRpaGAegz6b2RuYyHXwa4ld2vz5bR8LiUhscwdTu+i
# DATA yklU4hYNg9kCr1CW6fKPGGtQHxmU3QkozK161QBecfI41IjZIoLWlMnSfnwqi+wvWBJYY3iGLp44yvScx8kkWbjZjVaOdn5sAMla
# DATA QV4St42s+hC5M1gXnH2p7q7jG6v4mk4nuCnNOLZppnObxOOIDxNhPX94c4ff56ipjIXV/AYsW5RRnFABeCG9kqpUGHBpQl0K3Eky
# DATA UkvNEmPl+rbLebqkGwjUzGAI+9I89aK+fVrGBuMLMwfzV7C8fVsj2rvD1NyPqXMXHGdFdO/ulYFlq3ghV8mUwrSv43gmwOH1AcC2
# DATA 1b6h3yyNI7+JELPN+gouHBQr4rSGtKxTSQnM3GR/8txaLziRt/tyoXV/zGofjPC/lIr+Vl1y1QVykoS9bPZ9q/mV4+RJVbjbTijW
# DATA sKy/Bte9idlO5MaQcpECg0fdWOuZiJ5cqlhXkGuZgQDguu48CHmUA1uTohrA0KTu3eXMlLBWdGCvQNqt9D4u3m2qVugCOGeY23su
# DATA w7OGpONwaPXex+J0ppeYYzj3Ybqckq3m+PKkgaOdFmxsM7ylq/JxXbyxDQThPSjlzbwWn0qb2ZWsnJGjtVYd/XD6weq38rzmd/WP
# DATA dvWm3ykqanmiZaagCBgPbp5oZ71wZF/mLlieyPrj+dxVNYbQ7vW9AT1XWS/g4g9eI/59X4u3EbyPKNtEnz5bHFE8jtHCfAI8xacy
# DATA tlXFDmdAhJR8J9XfXa1yZXXnE6pka+6yz2mHvKSf7PqNx4X5LD3iVH8sCvzJ8rCaYtZEZh2myzFfQIdu7PGtUqGTxbrF4f5GpX1c
# DATA VAD5rcB+Z/s3tEErxPBE19+le8cVg81RSqnybZzTH1zG1jaPPqQkLssejAzyZUa7yr5c0x5ZrVXglhVg63Vl6T3gDVaS2i0sK05V
# DATA ddsZfSGZ/R/Mvfrvw/+b/Z4cv4+r/9LsNVqu/7fe6/T+UP/1u/L/filRVZ0PKHxPLvJip6v4SFDdWqTCnu/z9+bqttzr/q36L8GK
# DATA fJlmyZs13mDL9yv1Wuz6E3zQmZRuOcvF3pndfBkKKzGa710jPf3+g8yUmHS1nL4m/94COPo4mAyjYMc5omDZqhWskZGP0DJESo2l
# DATA /twjR/y8oEKGCnlzqGoRXAI3zcByU6qbXN5M8zFRMiud3bJRqMGWKszCl4GsmiljWNzC9zR332QXy/ourGxWuVqTkwy5IgCdIHAe
# DATA C+Xxc5jjfcrwu//27pdc21sV8v4H+PPb9z9//9fv/lkoc/Pdb979PV5h/+6fsBC4ruQh8GfWQb/cFdRy+ad9ps48k/Opjygzf/fg
# DATA DKjWuMyASo9jAfLfPDADSpwm3fptcF6itO6LHT8gIg2QQJk0eE782VwkFMhS0BWcfJPQcoYLDKqNuarPEuGSEz21ELeaHjRL0EGJ
# DATA NHPO+HDvKcdR+GdypQjuHF8vB2wJNn0anC6USaZ2FnQ6t1vijQ7JwmooPzx4FvDd/6HwyvXcCeu/ef83RFJYyR0+Yfn3939DNeHf
# DATA /xd4/I9Ufv6f4aV/4SODBQX0hVgsEOkYAtoxwNzUnbJMQMEk6raRcIL5BD7cPQjzf8PC879BIn/390A1CMtvuCw+lqUHSrEK02O9
# DATA +3f/DFP5OXz/27XwEskAhFUTvSDYz3NwXxRnhMl1ZyMrSPVWj3K3+RY28d0mWFPLN5tvscO7GnDu2uXPSrl0rJlywIzuCYhZPe+8
# DATA ZSh14b8LNRgPU1qxwYzDmS7OoyVQJ5Osh2wKOed7H5NlaXMjWAhYhl+9+5f3f1ewi3+x6qm+5871R6LjjyXiVuKr2fMn4s309IWb
# DATA 7H750Kkxo/3Fu3+EL798/9c+/sEPQGYwu3t51uOPvbgQmyoAeFtacQUAFW9c2wl9VNG2D541bKm/82mv/ZomyrdD8M8w95+/+xf4
# DATA v188Yq2JFdPlLsS/CTZOyVSyxtjDmOpJ+6EgIvuWefr5honzwAbYEvGZbUXpzRQ5+tb/x967N8eRXXeC+hufIklNOCvZhQLAV0tF
# DATA FjVoEt0NiwQ4AKjuFgjXFKoSRImFqlJlFUkIQoRs2etxWDv2zO4fsxsxO+vY/Xcj5LZktyW1FLGfgPwK80n2nse999xHZhVAdsuz
# DATA lsbTRGXevO97zrnn8Tt4JFaCw4Cf08wcTkYv1YWurT9pzyYDJqfUhffMKRFfkXRC5fTsA4HBeS4LyF6MECNH/AUT4p+8/kf19396
# DATA /WWiZviXmH7kF5gFBHbib15/kXzUn348O/QDuMu1rGIMFOOKiFyZRHDAIvv0GhEcNJjatWs3LnVeeDPAAH5SsUlYBNQCiQ5XUWva
# DATA nYZin5PQB0he1vQlvgqZcUnktzJOrRX8KDLK/4YM8Re8SJRThXOgJGqh6IyoM5NgrYoeJlSrG0qhu7svRa8DYamz6kwdhB1wpn34
# DATA zSlw+YBBwrdaIA/ta1noAMeuJScQTnjjIms4cNbj7No1fOlExXBHjFSCGVhR8DDvtCDixcPIvqvCxHpTOHRNvfOiRxKawC3ZdDeo
# DATA BrZAexxnh6rRP0wBeWMM0KhKuRXVSy0+VdteTeii+MYZAaEw0OQ5Lw44P6j5bFQwuUBpIK3cW38bijCKvsoz49AKks1UcZDiYD9S
# DATA yp+fCmwyHNUcQ7IjdfKYHLlzoVpAaxhUE0qlkVH/Z+z1n6qB/A2ID0q+C0VP9ehzRVZ+inzoC29KQHxVX735S3EU4aFzNUJ6Y2AX
# DATA +0enbY6TZaAxuWf6kau1GNUiKCa7H68vq0IxuicE78/VShJpV0Q+LQtcpg6mk6aSH99xmD3aXhCDaHZSO6FYd5OZVZT7VhkvKN/F
# DATA rz+PDl6NG9bqP6Bc8ZsEMm0ByVQPfvv6n4XcADSqcKy0Cwb0s2ju6FRqIjI+ZJXgaN4v2p3DYjSYTdkZPW000AUL3wLQZVESy695
# DATA aM1ACGBYgMAJ0KACiwtg6kKDQqTaHWq+WPz8HW7/nyXRif1lGh2XHkGxUNPA2z4HJgb5x9RR+ivIgEbH6UKNY4ugcfdi3MG6SC4g
# DATA MWiC1OgkvDytLM7or0eTcJcHH2vYhqgXRfnMK6LhVDRHuNVlHWN4jTsanjtdOtQDFQDC6LukqUL7THLoenZwcIHDhwTGyClADX8B
# DATA zOH1P8BBExTU0Nwv4UaDx1KLMKUXGmJwSB3LcCbEwGw67WBNZUXRdS2p5/LLy/eZP1ej/gdisG/+J/X3F3NW2kI6iS5LFA3tuClu
# DATA BZ76VYeISTWn4Cr6rjZ/jf8LLCvcydSy/jlpZujQXoLb4NikDCX0njZEmZijyz7ZIl7jf8FaLXnoN5P7AyWx9bvWhAsa7AJdDakt
# DATA ZrJ3rCtHzyllZHpWD5OoOxiMXpIO0J+4up5Kc9s/MH6v7B67dnDueCLovtsTaR7hhkNfC74ocMsLOGNhVsZ/wNP2T3C6yo6eFtTA
# DATA j6PltLwUrMuZL0KTM8i6I3wqKWFUmHfbBUvoeGj0U32GzuPLWnRe5L0aKffdFb169ep96BGujTrns84AKX2P7ynsJT/Uto3pcQc0
# DATA FhzdRg6elrqC8cTlCQZ8inO9WjyiUBbA469dLMqhXvQwGKXoxxVYL1aqCF7/Qaowzl8w7e+1JDRSpdShUbrwB3qpWIGTCPi33lLJ
# DATA YPORylP3j5gLFTSS6sgtoKAqE1guAhBVyopKvVvATCRWHGwFrhQT1mNPixU3KmCe/MTxbosW9ztlqSnhWGnamvvN66gkqKWHg9Eh
# DATA JUKgq0+J/w4xyAVhp7yZuCjjbM1jnK6sEoBjcaVLcQETNq0W4wxr4AcXFtV+L2KaL7DQ/d0fAjMDa7c0MfLklF05iHI55CJHcY6A
# DATA cgHh5OvN4E2eQ04UrdY84klBBSZpFQmxzfEiTJHPvsvw2mnnWbXHkzGILlaf1bGnv49c5K66raqk9uJbbFio6ly0sPZsvWwadB3w
# DATA S9+TtjmySYTGmRbJ9T+gKsi0HfWq1mpesWSE/wehw+ZZkI+dewVHxXSqGQdH8VOoB0r1eDJ2ckcUiESs1q+ozs/Rzr/ldtDuxG57
# DATA WlnuT5xWT0bmLea06s+MPr0hc/HUiPgh7C5DkQLe69dNNKC0ZhbFycWzP2wczgC1paT6Ii+tR9/U/JkxV1g9MUHVsXz2GsKmLgEN
# DATA ybe1BFCE2Su2iScq7CltFEBFwu+zOb7HxIx2Twt1o9l4pe53a5f0mHSyGf0+/P+UuPj+Dc//b2315h/yv39t/n97k86woEOpLrSU
# DATA A0sxMoheKjhCA7QJ+UTdYG2wt6JTIDmPZlMqi7giqgh4vHcGxeKp37qj8enbJ3XrP1OdN7+mnenikeQ61dtkACI3Ic+4z8AJGyyz
# DATA 2B9+hiNKbDlUs9Thr9kQ/3ZTyMFBprwsQ8UopxAWBocdb9Ft1KUpWcuiwTBsjCLVeqiUsk2Myst2BqQH/zBjG/AExnO3JWb6TxQN
# DATA 0JEWinvD6ihZsgvKq+SRIQ8k81o6aHUi60mv33k2HCnBuks6DyU7I+zMdJQUx6OXZqMgkcONgtLsjHtC4W+4Y9j2rT4myxO+qiej
# DATA Me1OJ6KSARxxCinHl7zL6CQ4rvqBvmlZ988GZRoyLytR5vzZWESrAN4if8reI/8Mhjw31YkeGWVDmJu8J+zB/60uC/8MGragITQB
# DATA gpuK69YWTeuj0wlpuCPsTi3sj5kmOGKIKNkO9BjX367XlfYxax8FtwrSZ3/pu12o69jr37nOFdBnAxWrbmDTdgcBLKTXMB8Ik5dP
# DATA bjKbvK8Nm7Nm3YfriY3MYJxjMUHkmqE+RkjzzrSx2958tP1go0ZIx9M2vLM+s1Dwj5LVkWKL5dD04NTGXyvSAjfvEd5tc/VrkR3z
# DATA v+Mt9edqHtWVlO6dv0Ifm9+CDul3YF+GZVHX0F+rmQ3u5L9581Oyv8Pt+5/IDxEN9r9+8x9TFwiyzXPNV1WebcfJIoVHadPuR4AD
# DATA pUiWZkLwzynqVfln8mOYnrU1TND4Qt21QK3Ls6Ee4BWTIC30U/XbTwIS71fT6lLVhBZddQT63CmU64ZTiJv3ALJnoFMRrrK5eoLa
# DATA 3hqXj0Nhc1YB2CNHI1Cra6JTMIkL5EdsyFUg8n7afbj1XXc/Gd2pKbKz8VFYxLx9sLlT8XZ3+75Xf6nGdXECCdsOqdLPYdP9Sm5J
# DATA spGLTRl3JKzoH1Ev+YhO1fvvk4Gj9PBcYGB/p/Y7KXf+Hof0y+TNnxNRA5fc6gGp44Te3//I/rt6IuAjRenQ3gwKpF+BB696RC5v
# DATA NdHA7VUlQHitfJFA/g7j5NEZjwenbZfa0T8QVYYXeYed6ksKFmmW5A1BOWIEOqRRQZYGKr9P5/igDs+32zsPtrcefqbOKv5S22vj
# DATA /t72jnmwtf3h9sOH258wmKq8hPL5UMWO8HTYNh0rY8058+KooybSdIpJxEE90U+IOhw4OzwkyNriZSpikiQqIqIUTzN1UZr7BXkJ
# DATA oqvPr9ndAHYFEGD2dQLSS8WFDOG41eKKxrUXAb2LzSpMOWHz2bd2uHoCCH8C2yKPfn8+lqK4iqry7kBJl07LHMNjrhTsryg0HyDQ
# DATA tvs9CeIeRBeEejWxm8iwSOmASfWS97gZrtuZSRurDm10hujO5a0wI4AwPLO2tK6gvo+sCHUtrZN5oqpoRimVbDSFC0puPgkGWQAc
# DATA dI3HAAC0EZ8RR6KLjoIcq5zeMhP2eqU6HOuWGMlSULV6FdStnsnKncXUZ85TnS4g0fxnRSH/HiVAdB3UbcPnWmAMd0km5Tt74/DH
# DATA iPNsO2lnmu2wEE0DUxPMoQkhghK0qWZDjfXaSw0Fyr0IJDKmmJ+LyHNKKEMq8SVZIxLFmMCG8GtyoLZmE+Qq6Lr/D+hgiL6EKHpj
# DATA LEkoMteph3VwhuW/UkBpJrkLn+ynoC/Y5YfGLZUxl9vH6lqob3EmGhhIhct1hKc2F1ZznwUyML7Dh+qeDagdfO+mj9CK1lyhHDT0
# DATA hIKOtCc9XHzcm6KqoAFdRPujmnbqYkW7/M1MzYK2UsPvsbosvxxNeua3uknMX7m/tfEUfyqVJ66pCxnHl7CiShz4M/KAJwbxE+QI
# DATA v0lwIZUgwnFLIKq/+Us0Of1z+QXUAJlZlUWtBn3HWD29THUeHuwF+OuHsxyQXuHPo0nn2YlNo+JAI5UtBaMtaSw2VYC9UjTSDQZI
# DATA tvPhixqoZDl5t4TXeZ6f8lNTdSwqrTNVnYfItEn6J7XvNPNXsCL7ydPpwXvZd2Af2FAbVSNHz8Dra63GtX+TSjIK6bJzUHLXuFbC
# DATA OAIpqvHIo6vwgkDxIEmAKU8ho0m7Cd0HGtIyW1FXdjToPCtaWGWFPYHrh390JmSdCBmzq7wXNsCvHKhd9TlP+HgyenVK6m/qh3NI
# DATA 68nz/rDXSrudXu80tXoXM7e179y9ItKKNpYPMndyqTqa39p3grJs4QRdI3g0oTzKsqahITU/gftwNByMEL6aPlxysbxAgpgN7TIM
# DATA Y+vAw+MlMJO/KZ3CdK/0X+jYDjXfEwmHXEQw3jIwaxT6+Kw/dHze9aHjHQKTcpL9Se1pcQ3R7ydovn1avJfV9v/kjtqrtTtZAEsp
# DATA vCFoPJzMEP9RZwkXgKaOHl1HXD/6+8YB7biYBUmJYsgNV4XD6lDCyfi5zXEfCpwbgHgAnwpCqwhBCckeT5nuiAR800FtFKeO+6I6
# DATA g7e59CylSFSqBB7x37qmM11TmA3HDa4CdJIjCrKSPaHvIw4nQ+TvPKFUBZ63M9SjYVVurDf2/D3jYdHATQMNZMmy//Dcu9ziPGo0
# DATA OszWHu4dmV2wcLSJvFPnc56/A6YCt0vgEL9AAeKXICugkPAlXjN/QU8+B2nid+ir8LmSKP5GPf0NMp1JDjESOVGQO/ISgxcZuMRQ
# DATA qAYqlMybN3+dlkPpmXSbAAdUT4RaJpDTiCUZxbBVwgEBbFl9kjmS6jFLmFC5yS0UpCwP8vuEylFkZUYfh92TVe6rtg4QodVosoLM
# DATA YpgLXKeZxyaw+SABFfxVfv45tuiENF6eYtboPd5///3yBhCI/VyuiOq9zqzZ6+sIELMeTD2acq4jq7YUnxVzT2QmphsavkDQNLCP
# DATA oyBZt9k4bCK8GftAYgmSmuFDDutFcNIqmTIEWDN17tNfDnTsvt1rqO21HYIbAX6gtR4eKBozFUJFw0kmDkbwpJ7soiUfbRJB4ac/
# DATA GQ3xRkwzqu4NU8rGXUQkopIwB54nEPDU52bi97UAD0uCvmBC96KJHV9mtElI9siffv0iFW4FuJSo5QyWlfoC8hp0xWblOXBDXBaT
# DATA 8sTRBnAO6j7rPrHdSNYGLKRPqJXrvWtz5MtvJnvHueK4xTTRuw5OU2c2PR5N+urU9V/kHHg4zF9Cp+6wOEvZhMjuNQbg2uloFObc
# DATA ONLmqf6wrAuoSZn0nyFObcs9XrggQotuAvto3euCrvleIJHxA+PFTuwvrx0QsKwWgssEahI8jRStWtRdjUrKjvNGlM6Iu4Ct6Uw1
# DATA 06R1O3dhFe3yl29RSf48hFr6Zt8pf4BO6VCtPqRgE8BeAUFn9EPz0M2DLrBTUz5IBBGoGOYP1K5fxiBUqyHhxygAMtAhP1KHwwsm
# DATA tZXYE1Rn93ZxpqC5o7TOybZ0LzXFAV8vOI486TQYvNPzQGCMScsxDGPHMuGk7vobsTG5BkX1WNnfLL2WWld8DZXYV7LQZDwasDcY
# DATA PlMLsIx28Bm7FzqwolL3or3iI5iN+5wgXKsl6sk1oWsB1Xi/i8Znxkdx36Pj7q4mk1jgwGsTSWdIfqUDOI1V0tsDozJCLD/j3l9B
# DATA xTUwnVZialcmiE7GBRP6GPhUwAnodva1x+/haDSoSaQ7/psGvTulVTCEgxNu6dmGrYJCDRLvZqKbx8+a6Mah5Jl8DH/UaBtJW54O
# DATA TTbWPPcDeu3v8wl3oWkGYwdc8IiLcyFrQCeBGLIADT8t0qimrrQ3eFt/6IuBnjSDvD84WSADWDln4U+YJCxz243Tk0Ea9q9WUQGm
# DATA fWxMX8FhICM0jhsdZf0SWZBztsLDITKOwFoL02n0Bjm4qIQqe61Nc5X3dXBHaZ/kilfqB2BNRxlV/gamwr/7Q4Q4lY/IWU1xikn+
# DATA sjMYyFumUeJZ6YU8mWr6jc3JdzrG8DxZleEMcEaAh9QoE6pTiG+dWhV8pbW4hvr/UPetX4GF/M1fsp3nl869ytyZTFtwK0O9nSoF
# DATA qjwXWwGM83TDgjj4v7Y+JXaaHVEfDaKRrmOuKvuJUcGDxhTIrZZckHYPRrPe0aCDIJPpsy6c62xBH5lfEHoRKjMBIMegXv0WbWF/
# DATA n+w93C0ZlNr/o0nPaKLZpLOA1chq4PVOW3hK7BdmRgCav5jmHTRMgKDf6wzUl283Az8hBwtQ4f4pXLrhVu6PX3uPmC65dgPo8656
# DATA 90i7mZt+ZnF7GQ0SRr/gABcbH1z/P2d19ZdVo/s8VEn//M1f+KNGlT2efXGi4WfN0AmztPTDv9hG5ugxJdS6efMG87RXk85ptBFJ
# DATA fEi4lL/nNLVJhbm1b9nm5q0FmjPtzOMLCMQ5cyeAzC6dcR9bAOHFzlbdjukcDUk35i/ffyNTwpu/TtYfb9adxQLYCcah+Hnyqao5
# DATA cF2wyBPsusALWBx3JqQ9nWOtZWeNmOUVCbEjz0SMZVArWQyxJlFK5HzFaCmfofrltbgtSlsJ3FITHFhgY7YCmR1AE33DSD4ZDWAy
# DATA asZi5Ril7OiJaTFelTVNLWD1Nh6E0alc8nzlrelMTICs9MkEYc73UzX2/dWDi/UlaE3OMqzVAxpmWBevJNnt4Hhwycz1mlST6TLj
# DATA ijmpGqAgbrRA7rTsh18cOJNR3SnDU+afwf9i8V7iStlKy20jef13SFX/En1Mfg7mwV9icQqWI7O4tioCXuCX+Ck9Z670c374KwOg
# DATA Q1PiyVPqIeor4SUtU6pnwQphLTMbrkBiOK/Dk2OBduEU/T8YW/dncmrIAwvRcqxLIllBBSk67HSfz8bCf4EekAsFn7hlByZxTkZf
# DATA +p4TR+vc0OCRJZNIWxUo3ppQQic/R4Rp1VoBpGJNKb6kaurUE/VfcHKk7d+0cnVJmvVzTBgGopL5SZehprq+qh/jYwBYbao/SHJH
# DATA TDwaCHeLfmTnAsG1Qvp12VdUxJKJHAhSvW35tc/Vq7m150jhCD1ZwDdJsW3theo+77QshAvtdTuniv5RbAxXWl7dXvAXXs3g5Yc8
# DATA h6lnFgjrFBdkt2palvzoSLEj0DS22PXEoaBX4lSQU2WE/BVHeWY67bAwvTPTaKo76fShgRWEtsVVsagt6JUQ6GietkWVZXMzqtWr
# DATA 7sL3oRhp/z3bzD6jXLDOIqrpMlOZMWY0V65DCsI2ddKYV1AG9+Ay2XerIW9pNPMEQKqXpfFSjb3dYAZVop60xWE6muTFcU0HnZre
# DATA 1315pl5hFfDXyoR0k0tVm2hSy71Y6+mOV4mjg81vuh15LVCFEFR48R7aL8GqSvDO/WGjyKeczaCWch4M0ua5wBdo0wf0Cfy4Gc/+
# DATA ji/pBNGzNPPMPljCMfvQNybxIPi5kGNMappzWGiQfhv3yMqLzmRl0D+0CLAriqmmi7sq/1/mcmUYJkG3/ow8Uf+ewkNMnLrxOfU1
# DATA FuqSriSN/ypvbyRY/BJj26XM8rl2QlL//Y8SMArnWOvnzlJQxgCROexj8omUk7oRR7JnUp32bj6BJISqDM9/s3RqkBV2em3IfK6F
# DATA cAGsBsrkQf9Hea9ttss+b4LqBa22w3qDIdaCG0Dk8F7RVJc3pDPmYL+sHsjhRrbTeXWXItu7aoyAxCL25oHIyAz+w2KinIrDCTVD
# DATA d89LyW5WtMtFBIc7LzdpwSf4gUFuwMm2ntpmB/G8miAI/zudNhAvl/blPlWIeB+8gPpChexAluQq1D3ACTBb0Bf8v/o+FhgL8Reo
# DATA CvwSXDb1FeBXlU7jfKTvkIfFbxn78mck0ZNfYMlcO6nBXp3aUzCPfu8bKnoQrWL/OgGLOJYAM2+Zt53a2qcjMrMOrHp8jXidPSej
# DATA EnMJmq0EtKnlNJgSy2zs/XSXe+BuccdS8ggHa4H1xVZ/kIO6lNLLV+53VvqYD7nZLPCDItw87CWdhQvF3hhXYFQm/8zZK3D7AxbA
# DATA PqTx7eXjHzkrx/2S3luqx+K4cCY8I5ypKQ3fltsjWIDGwusYZ4ACtBvTIuvyJZFeL+89hg2K3wEf8EqQ9UptLFcIhdL7cyyC9URI
# DATA Lf2jCwtwJau2I92qGBrGc8DSYMv/M6mSvfs7glZi7GSoFfhyEdb9BaPpurA2pOv7Bcb5AQb6b61+OTLy2ID9N1oIwM8dUz6UZEut
# DATA XUFvb1Bt2kAoJEzvBdYT3E+8ILvQ0fYidlds2sNxL+3e2xthUYrnLY1/2XuJPphScKqRE2oDLKxzbiriQjXvulKLr5FrPBG6gNAW
# DATA WVIBahOsl58ZlZNlBgihvvHg6DQ+EipNqnUJl1AleAOYF4wRgGuqw7oFvfSdJH/uycl34ORxIBifzjf/ybj6g77dKW4Uep8jdZc6
# DATA PK3Y8z03OWEO6hK/QHlD4mBq7/XYzFq77qLaE5y1iJcxtyI8z+eud520YbYP6eIXb+6C72JkGpLu0ORy1AuFGHRniJ8J0lgLMkd1
# DATA 7DuKbjirjs7YcT88Sz/c2d7aa29sPWg/2H60vrkFtwhpIBAjf7y+tfHQFtNvrFwDKmzKGS5CcNRDbxLJGxHiaCDxa7UR4CBzODy0
# DATA 4FFjPehQX85KdV+uwV5eaS2qnXfnTIlpTz5oP37ywcPN+3oqdEPoAR7Gl7hoeFV+lvtDcsgx87LvarPwDj9EXRvKdC87L/LlCLqX
# DATA cdVcMvhHkb0a2TjC7BHdN1xQZxOTFKxFIfOS7LWkcdAzT7aMsTALuxGKRI7MVCoYXZiT6wZHL4d5z2kw5tklxTL3i3p8ubK6o6w7
# DATA yMSCzAn4vPRRih2Eg6VLnJavc7ueRU5Vs+JMnbtLzbsyOMqPNORM6cLHS4N/cMkpwLUja4eFDhXBqM2lt29j/kJ9FRTWZZWm/bJO
# DATA svcX230O9tG8hL8y3Er0fcxJjUstBXchTVbI01b3AB2m2TNbROk+MOZqQbQ8sEMi5cJRm+s8N6kK1f7rtQVtNGbgshNKDN58QfWQ
# DATA kbGVSFsSaQONNE1loIPo4FQtPnRm01Hqe0m/vblF1lvqsCUzW/CwbEFjoPOctrBiPbZFnLdQBVbqkcINt3SPL+0HFPh5fe7mD/vl
# DATA nRJQehND5InNqbWt6t2K8lwL/yvMHi1Hi6wYAXsg0j8oBYI5pOUbR0Jw33wCibwVTeVN3qo59E4ehmzOtjXkobKZXbGvilZa55iv
# DATA UiprCUlmjbfOqSr1k5HVPKYseGyVCHuoduF9XWUraATdPPEO2+KOem4z2HT1GGQUL1K3sklBauhPTIxUZ16Fuo9kjb12jT/1yBbO
# DATA hPTgkV7atRTS0HWPwco0ziF5uto9/ReKwOHPrNSdOGLSUH85/qkLO/r4nkjkfdAuw5CIgTXQJyF+gamIo9/M76ogOFOSDJodq9Yo
# DATA EQe4HOpXMPZ9esptl/LrjCJT0MHT09hQ7GPbDMm9wjGgXsUnl5QR5lV0OXGhbPZiN7IyQUAu44GNY+ZeVnt+2y/9i9sCY73SWqD/
# DATA kfBcatU61NEDV9fGrXqgE5Go3ed4j/dM/6IJ/SNbigOmx2VuqtiVunWfLid2zwnutNbFmHA+fzEqRfdvJg8xkJ4QJGcFZ/kmAJW0
# DATA SMazQzWi5MnOw4Rgyih5CcfDEyyMmuFJXhSNxbQjFOcAWfUm+YCSYgyZBPDmJfeo0mA//mwOSk9pyoEyvS5X64EKD3tjxVskfZQ7
# DATA QteFZiWtr914tLX+yfr3Ntqkp1FTR86cMf0HLotuJHOASBRlWHBEZVudR4TYLebvC3v28JfVzj1hoQNPHb7QkYpUA5fS2JQ2XYAZ
# DATA PYc+RfWTqwLfoG12QZClGMKSYXmm0hKwpSiBNR+F9CdOy+0HByG/9mpDRgK+TybanQOjbMe+CakMMCDQBjAWiOlwnPcnNsyUhWLC
# DATA LXg1ZXwQxblPmQ7YSFZTD5g5yOcSzA/m8bIBHnVitTApLoVqZbF51kN9OVE0wcYxeh5MMlMVBSF6wZoy8lgGbc6NUyQMfA5Gcfpi
# DATA BpniVYTBv+BvJ2wqVszAJBGiPkMU5wXvDz39DkLfAqvKvFOOFX119WqS67dRylF6SnXmNqcoxMrvMj+SPB726Fv1tHnHxOySyF9u
# DATA 7DH6G6Gjy1y4ETajoeCNE8Kgq2GGongfzQBYI+mbB0mzTlMNt3B+exBL7VPEyDJvuCBQFpxwxyaEtZsvq0M6yWW0ay8fF+bH4aw/
# DATA 6HGQsLpeoFoFzMEVCDDXavvpco9x+XiayAWSqkTfI9SBXqMcRC58qTdBAbctm62o9EZMvNM7rYpO1dmN2bVVexfXUAndDAEhLX53
# DATA Q3Wjtg9A2vmrvDubdg4HGGS8mUaxtMHfioKpcWeZlhpjtfMyzKqr1wE15MtjshEigYLOAJWA3CvozV1HrPDRbNq6sbrKCmTKDSA6
# DATA uGv+3HCTAFzEQ0Pa6MlDQ4YCJq9/lXy8t/d4d1mH6bz5adQFyAYSfqExWAiol52L/hHVLOCG9Gt1EBEoHC9zTJeUtAdkSyLjsit7
# DATA OdId0SRyND+gWzIciUFO8wx15r1lqJbuy+yHnkXBRrk+nbLb+lCvg/DhfhbZTRHXawtiuTCTXNCCIRmfCMpl73p0Vn57Nng51jY5
# DATA oS2u2IwkRKlrE5FUYdDDHEE4Dp9TfEAjougkB4+Vv1sxWAeYZ6Zo0JTrnKQRXHPJVTU35Cq40szRvghYEBf/IrgwGNdda16mCiKg
# DATA QTwMRnWxYKdFBCqC6m3MhuiydNIv4NrUHj33qgt9SlzhgaqpC2ggRgPyOmFRguq6fyeEYUsJeCIwv+LgSN+pzAL/2q7OlUDcWBZ7
# DATA vlvuiY6IR2RdJ3GIyb7ahW1U0i5OWIJWccTAjuY0KQIAnJOm3dVK2Bu3Ry42mVG2zaMDUSHAkacwrBZPoduExGvmAQiVJ4e+P89P
# DATA JQruBWmxhVYVwT9mHheJX+eAMq2W137k/4TOJcB1/oOjmv/qT6u9yAfYWnxAJYaXC7XFBapVmbqBKy2fLCzq5hvkY3BwnjGO72fz
# DATA kJ4biUxKrf162EsIkPiN455jFrn0gXFkr4vQFhd5GLvA1jbUB5INySOkfvYpNjA0QGHbHnf6mkUG1hdkc/ZhnfCiqLCDfzPPguDp
# DATA e0iis0lOSvI5lS+7TeDEMhWlk/F98jl0a5js+xYJJad71/8GeZHUskh6R7b3T1nDfKanvOmtQD2Rc8DRFcjhxeOsIVzZ1RdqTmVJ
# DATA gEmVJc6Dm8Tih12nvKS7u4H4isyys1lFI+beH2WKulcoU9WNlGeTMzgMISu59miouiv6Qh0nAKHYFBX/WCzSwh92LQLCRTUFsaXZ
# DATA nKmx8hcZ9qTcVXcN/Bet6u3qMNKoW0+gtXEdZx1x84DxHKU4WN60T9FiJal6T84MRlwxCHoFcjD9f8VXEb+1PckHuSK8HrOKDU5r
# DATA XbQR0pHhXXSipsvoo93NfESj8yjCHGs/zRENyUyzDBeOdZwxaIVSVD8Un+SHDsaC+5kxv5cDxVFN/kiNwsubWL9ctFpKiIUKdNnP
# DATA Eotl2dyYWtBzgn9cYqrcT99usnRd72y65p+zKnG7DFFuQW1kRL4wbvAt7evbjN6WGY0Owm7wBqzvxI76DTPyoBEB9b9YnfxDZi2F
# DATA nK9aP7yST7srWGrFus9jmU6vM54y/p/nWB+/Hy6obSjNVeUoQ03CKk45gD9qgj3JyGYjO7F0lb2reST1gqtsgGLT1ME1jtxAg/UO
# DATA NUFpNi/eXuuKguifxdnGorqlgKFZqchIez7JjcpFMZFH+J8vqLkKamoPOqejGQawOJw85DULHsiA35Sy9uiFBJZlabGlYLH8A/X9
# DATA Bv6pSLG4sjqqSvcma1LMGFq+UI6Zt4QcM7nNygA+7NFrRkE7vQWJ4RV6MCAGJiRAEsoWcil6NyA9qBf0eqbuJo/0pWQRx0zyNawz
# DATA ssmjzljeQeZhImYm0xsl/kXFPpGT5iL6IL4ummU78HwiY/oiR4/aDLd0RwmaSI1tZ+SFL6tQflsWd8WwOB3WHO2Kk6fBq1Mn8YmP
# DATA kZZUpFZxwk9c7qAe1NKVzri/AuDHKwTNmZItHNqgfbGiQYTGAPlAfu0imWoDjV1telvz3iHf+1jN+EC9O9NAv72802OEapzak5Ga
# DATA iNGw362BwnztOsG1vDwGZOagwF3zebM8/TUl/8MuUXYz9NLSlp9bmAdQsSs1c7Fs0yKwzV8ZV3gz/g0lwrZYtcDZQE1w/KPDUe/U
# DATA RePVPUVNWA2Sc3KOTpitcvxnDzsd6hUAAZG3tPd0a3B4q0rv25K8a/vFw5E6PuvgYASGnToGSVbgRZPuxappUNsGSjK0bP3cZNUh
# DATA 52GdG/SnkG/0t4R0AfGsv8NouV+CJi4i2HtrwDxIJglugB2uSk1EiOGEjqBE30keZqFC1yrFGFWpBHIKpUXy5Mnmg4YvF3IqVvS3
# DATA UnSI2u9y6N3N1ZtZFVlYfPPFB13b3uWE5zINujMVahgyK7C1CRc2lAWPZDHI83HtOjPKuOoU7ZsJRzL+1otPpjBmrSzl1fzJ639U
# DATA f/+n11+yKRRwJwmyJJYWNwyX/LXJTKHB+Mls+RbmzytCzpmvX/9fbfj1L9/8FQR9+rkzYHRpREcbcrpyuctYY782watfjAEjoNaZ
# DATA PCtsxi/4BfSV8z+3tI469VTP+FmD7FH4p6PzxSeglbQhQZGKdS/TSMdN9dVVmGlzrD20QRasAgw/y8TMhdnaWsNENTRzCLVncp9M
# DATA CuSgOpF6Y33ybAbb5zG+qQn5ttVu90bddjsTXzbAM7DDn9RS07MUHBxG4PfR2teWIWMY0rD10nqvTfdiNJhw92hk0LFiDaqbIoDf
# DATA 1RF5ufWYcg4qTq/EuJ40L8a/tZKK010nR2A9JtRWd0lJYMtG6rT1Lho7U105XA6XT6hntu4yhN0F6kLflOxOWRmGp+ViVbWpu7q+
# DATA yKaQ3RP3TEoX8KlaCs9+p0O9nuXLfRTPLT4p7NbUMyyw1cBJxBbtBgiVNugBdj965GJZ/AdKF7XMoRjDkQtGWPMOGpBcvY2BHxLJ
# DATA qMTr5iZzIsPO9LgI3IjTE0Hg5vYSsU8TaqSC2OlOSoDEPvjDMqg6fkJ3THcM/JsWgX/w1ZN/2SgxfmDQGORvCgbG3xLZOERYx4zA
# DATA 3txn5aSOwtA0+ZAkQ5ISQT4kLASptI66w+nAYWGOTdijt6VpiVFjhC5glKGrliqOrbqScYbi+zsb63s6H/HOg092/NzEdcqMZJvR
# DATA icGPetiATJKbvkzxagAtuAIQjqZxBC9q8J86P3m4ff+77Y1PXbHT5ZaRcFDaJSjh92Yn40IS/rmbRqsoIFl5AZ7YnaLb77fYnxLM
# DATA UcNp63oGDEgtbBtd59pt3K/tNuy3dju1fqhF/9lwdoILDn92Bo3dzY/2NnYe1RP7++Mnj6WXFj2nf2pUgUnJd62trvno2tef1vTl
# DATA xBF0iCNKuaQmxVEjo343PyVRNCKVk/i1e6qo8MnGq/5U2Gs9XLScKqtpAek+O7DjPueWPDEu02Fzr//OiqrmMmLk1sBlIuq+N8dl
# DATA D1F6foJ51UH6/VwDgvwK06x/gZB731jkfyedyY8O1VEZn37jK/sfJKy/ffMm/qv+5/1748bN92/rZ/z8/fdv3/5GsvqNr+F/M/CQ
# DATA VU1+41/n/755ZWVWTFYO+8OVfPgiGZ8q1jG8sXT16tWdvNNTWxy3h7qWrj/eJLgi9F/Gy2qRTI8no9mz41jMkCrfULUsMVnXoqv+
# DATA DaYUOFhwSHtT/VTdVvHKyD/VzeVY3TH1TyB8+u9RsYT+FXD3UEU09wDhUheZmMYUYdF/Qpv6b3mD9Z45fXWVU+bprN+jPjCN0H3A
# DATA u5QibOqCqGhpd6AGlBgTIl34zG3KSPhq0Hz1NGmAWfevGOXJGBKr9Hvqhcx5Qt4WyPM4qsb6Zy9Jj8bqfMYYSqpIbzHt9YeNftGZ
# DATA Tk9roU+YO4L0Efk9JiKeR1U76YNXNomPoyGmd+oQXvGJ/r6ZuMIfd4mXvsH/1mjYSJZp5ERc+8PxbKpfmundGu3kpBX2NYmgS9Dv
# DATA WKHIQ6PwC3rT5uI1ENHxcqIY9Rg0/CA3nRTP1PSr46C2fB2Su6k25s4PNGzqV3/8AHPP34GDg8fliKJrUKUDEU12MOvjvu1hu90f
# DATA 9qftNveM9JGj52ojpA5QidWv0g3RhJdBXx1/Zs7vrH0Cz0jRa3ADzo0mycajgbnJTXntJrymrND0p84KHXWS8+boiXrWsXOAItZo
# DATA NpWpsOuJqVvXnMbH02ppVAfU1Nvem4GuXX+/sar+3xoMFjMIQxn40WyupeeL9HgnPxlNmdYV+hJLDvm0tJ2EUhPv7n6cTGdDGBkc
# DATA BiiRyoiawVED1xL/wgWlFTRZnVdAVMUX7le8D9Hb69PlD0eTl51JL+8tP56MwMEuscsp36q/4J2dgXOaO5vUYYEJYrjwc7dDC+n3
# DATA xQEFCdOeP3nsDCoDaghAV8zOr5D+TQuq7G/tBEZhwhgxL+CTOMYIRxGpuMKuO9euyXk8d5BGzWK4e4HL7qfrlOzxRxwYDjq1D3J1
# DATA Y5sgTbOf+zllfd9S1NWX5iLkj2r+gWb3VvgY6SJMC62JuBLg26zBZbP4OO5TEuLlPYZTdSfq1fLLly8x596yaZXwjG2L4cw61mlI
# DATA uK0oNGyrCQQJ1m4IwBI4qR9t7LEBcS1bwCtUbZRwh+2I3QPzA4Yq3DowgS34jyHbLUO+HQSQUO2Ptzyxr+k2iQxBm4FuzrMDudmu
# DATA XSvMjevaBiNMMWWWGMB+5Yqy5F7ifzvPQOITLxDhdG8gB6m6e02e5SVOTcyWneSO1JOYy+yF7CLGZ4okiKhBo8ow5h4nWaO3v7ya
# DATA gcbdvP7tenJr9Tr85wb85+Y5FtMb9m5yPd60tF4oGqI/yEpXPwjUnrcwuJmTo05/kPeayDES7SxqB5HJWK3IQtSiZpl6skebN2ak
# DATA qZi83/usqE+GOSopeWLugKUMfAROVNFu8nh7dw92BXrX+UFs0Dl1uzsZU0iNtT+EuZprGDx+pDb61EnoplOu96YNfWNBKDqv6joU
# DATA gGc/Uq03ZtNuTHtTWlm/GFGCU6qsoXPNp98H1vve6mpzddVzsKe6GtMfgfI9HqZkmuOyulb6phXtsJOTvdEpdImaX7ph+5zZ/nJX
# DATA Vae/L0xpwxf5RMmhBfjLFj+cdXog042mHUr+COgYnf6QVO3GjRZufg6L59yOUAsZjbU4KtAV+C4zUbM6GwwQnLo2SffXl7/fWf7R
# DATA 6vK328sHZzfqN26fp5RMe64M/0SLvL1RTsz6qD9F6b1ncb4TmgdvY05y9SEG14icr+2TzhgFFLoTgYCyfn9v83sbqFlXNy91dwI/
# DATA mfTB5u76Bw83HqAc1j9R90l8/HDz0eYePc1fjcF8Ak83Pn28uUNPR8P2MWUPslWYfD527thjw4Dn297NnZHh8+Ho5VDrBRJd0xIh
# DATA UZwAIKFqp4eJk2nR2RtJceM2FiDYsdWs7pWAz9rTSefoqN/VZeSyriZ3W9QE/PHt1dX317797eu3br5/c/Xb317TtxYshT2IFJo3
# DATA us0henkm3Au1d2dwgy3MIoI/7bNTlM0iI2vD7p22dTEaRDoc0fM0a8zGYyULW0gsXZ+5oWxtt3c2dhX1VWv5YP0z+OeTjY3vwr+P
# DATA trf2PoY/PttY35GXlbKFKlRrown4JGPzie0Wucl0JnDoMGD+IOgRcAFsSForzehtP++YejSaN36WHObdEUTjm4LyGHDuItpx+zCT
# DATA +3pLHhzI3WofY4fM7rY6eb/x7a32x9sPH0D9p0Wiz8AdNHS9oOMKfK3Hilxzg4M8TPlLS0csgSIjsqFRlJMRVltCaXw/n4wUA+0M
# DATA iwTCQvHAMpaGJBWNZOPVcWdWoKN4t0tpF07U74QaSPiAN5wLLmzmey2/UXPg1Gyu+e4iPM+4pyyF0eTjPB5IhAtjClX4KVOzy3TO
# DATA nPuT3iJX5B7xXKz8JdvRc0uTnmBqbP3xHYsckxzNpjNcqiGYoYoE/UytXkler2Nb1RqtoNsVe+hJAY45lLRFCTTJj9Ti3lHy8lRd
# DATA 66mLJ53TRLU6JF7QGSDoQVKMQeDXtKPzDL0vlxxWfGbZVpOdg/UW1ymuDW1fhwuslTPoPNCrlPJOWBrEj7UB4roidstr15dvrO1d
# DATA v9G89W31f98PMCRS7ulDWM0PIExStcck3Hm3qwlH00wsOAkgC9sE+jjsDHaBryMWEIirmDUP/JhqyO+zLEC5SoXlClyOzUgUKWRg
# DATA yjTGuUj73Gt3pmkgpu3rt+vo1BjMnfhW5PLqI2aIbYGfpTJbyEwQ0xZ4hNe4VJYsqzV9MYAISJy10Q/IKF4cd3qjlxAhWYhh2Gou
# DATA Qr7HoNnpjgZNcRZY5EKtKyPykPZZphPn75TUhclF6jrGFuIOa7bXZNjHn0/UwoHeqSaGojV9doCP9RMsKYfqFS8KW9RFVdB906yP
# DATA 59OP3/DuC1rhzaX3dS3k5kajzPw8A5HIwmqNtumbVUO6KkeRm8vOmtuC7ql7GugaIkNAuI/fQtlG3fapBPy6cX2RPj/WfTX6WEdU
# DATA lWIqB7CoP1FUneScis0lnXyUaIhwigJTQbBU8Z5tjZJwC0vNrswfIqR+B/mlXKttZVnh99NW7zXxyBoIVynUqRoGT/25v7x24O+T
# DATA ymvD2u367Ztwb1DNZYssjIwzJjWu1vd1kuIYzESwI0hnPMifdbqnEedQnsBweVKsAvcdBkfODsPrW91wNuNShtl6+CYGtplhL+/x
# DATA aL6Z3DdLkyihSG2WKaootaNWkr9QY3h5nFP9J6i5QQ7cARAo8AICCYYv5Hh/JErUzwc9lDKdK5s9OCFZcSkHUlM9Wssv6zEGVsa5
# DATA DgxRZAhq6pVDkviNnheyIuhtBm6GINXot4iH7d+3cfLx0mrAnaPsG/gT1mZfm3plkcBsZ+tWk9N/NkR2dFaomaWd4Ko2CicXYUFu
# DATA GwjZZQ5PlIkjOue53FDA8WwPox8dINHS3bJxN5r8tKHRWmfcd67emkyq51qrW0PtEwTWQYABmplXDk+X9d7BcASHJoBIZuKkOkc5
# DATA GMasmUACnVjTp/RBN1bSMK+70CWpZVF7sE08hsYhkmsewtHSISYF6plRXgT7Dlp2IAUv2TJgLi2PHh0dFblQk6/WkzXygnAr1QBb
# DATA c+fqO1RjS2sO6ScCCv0RCnfmDVXvMjaUceOgN/iKUDP3U/zlZmlzXuDmxi/CGAAoaFU4iEoDaR4Wo6o4/ex8oGFI1WUODdG4QndI
# DATA G6gfdhJE70vUvbs/6qVeCB141TL86D735iAMyQxVThlhpvlmovJ+P5iRsSRnUYyaxii+AnHMoA8mb5wXf5gPwX2yFutHdofmQt9d
# DATA 4EfmZ1LEEhhCjEvi9vlQCcXPfVboTAh0U1RzL1ZLmTpFe/3pYdMaWc4v6r0SdC9e6QZWwXdQUHrnYJxinQZ6sTsQ2+zftEwt6/D9
# DATA Mx5cU59W3rhN6sO5QzGwiMZFmw09X3aMSyM3yNl0PJuW5bMrsyeTN4zpMmoDYA0OwZas6jkcgTcN1JaWJCp2Gld0bTR4oQ1/pizj
# DATA Scj85PUEfZw1cFU98cEm+kfiezko9K0dntbEW8ULoP5sEZWqGpe6wSdgJziFi4wzATporGh0j1WHaoLIiq7xdmqBrwSNn560jbeD
# DATA lHxFMYcjgf1duNsQ0Oz9J7t77fXHm+297e9ubAFx3dGJG9EHiszDiUnIplXELaeqR+s73/9gfav9ZHdjZ2v9EapftM6001PCk6rB
# DATA uPSIZHRGjI9X93h9d/eT7Z0Hsjr9CfRJTI5xKuCfhmWAhGZ4BvZlBYuaY8HqCf2nvNM1TWvnbJVH/goyAYRut6ki4gt49S8wbtYq
# DATA wKKMq8+ixDJ9AlAWlj3vp31P0pCXEdiGVv5ptbRPM33Rxgqt4EP1Z/PVwPQ5lbc3KjwvUE9PZvm0TF+N1RUT9L1bbGLsH7LedtH/
# DATA kQBWq5OlsmBhYd+KrJpNYRsVwYvjzikYautStetaXyKTww+tvlN7C+s7mbpbwLXMt/pSdIS7uiTjiQd13Sch+x8EAMqmMil/adg1
# DATA fWnRhUyV2cK8V1ACnEqC/SJLf69/dJQjzBfdCO5goyM1Z8BLlMTrcWN0KzfJq7kreCx47lM9+eqh/lOGkzSjwxU41dqO6w7DDb3T
# DATA Ls71BBw4Sr2dsTrcVLbL3gH3BQrKnI0plJJ5vtFuD7XuUdtQmETTtKbnpQxaIidbtkwnIqXew6ThH+oJblTM1dj0d+65VuqBXemI
# DATA BYVmcmaFjHOQDju9U/VQ3WAxpnK2f1UvyFVKcDTTqApQXOt2KT1FV4kn9Omcz0BRp9j2tODmqfvZeSq7iMob9ApkskHpMFQVTWP4
# DATA t7lrDE+muubRsMeTXPXg2fHU2M0lR1T3dRKeG8kOWj4Suwxu4EpvctpWQo8fg5A+UKunnptAODLMExkMj44b2m6CSk4VYYUxk1Nn
# DATA el+6FqMxf3qsDgl07Tu40xP1AbA5tC+cgsLa79Z92KCD8vFCDJXoDEsfoJhn7TCosA9QKcoLrh/QNOIvmw4GkSF43eVFDYkB2EAp
# DATA rxCTiYM72owdIYvldN0iHVbTWutSG0ExjF7qSt2tPAmqRHigw2opclAN0zJ3b8Zb+2aybn2TwL6i5N/BSLFb1jElBouEPNDRkRhw
# DATA OobdPsBAI052cqgE1N7glO6AjWhDTkjy209xfJr1tVdzL35dxbzKj/J9Hi9psyHctw/7e5LD+Rubcz4d2fmIxrPDVjdWEJt+ORwT
# DATA qqUv0HVdtT0zlZXHXObms25921dsqJvbYSPZ0fzagVeK7b0SJqkHwGf8IMouWRaOsEfBvSMMjpWhzOKoqVJuuPvx+vVbt3efPNpF
# DATA vxZKbcVhEI3iuKNe1sYesulx/qrXfwbHE9U8CTKPMeVFVL+fDlMyB6EEjPp4cXN7Nhgd1tJrTPqzzOWhRJF7zMV4mq7yFrp6AKxO
# DATA ckZZyDynYtqtzSlDD6GA5Tr+WsxldJ0J6qzJ/HUnEdONeqUCm56px2B9Z9GL+ZSS/OiYjnp4qNJo9PWlAq/DMF6Uh8ChNvWjn+9E
# DATA iguyE/2mpBX3KrVQS6Q5WLQBvLosw9VFx3Oj55yatI6a9taauqHHGkEpLYyIlr5fWndoKxOvy7qjxJNlwiOLhTLHenKKZoLSwOfw
# DATA A30TWuabUNXXOpA5GsMMO20NteTuHRAe3VpdFfKDjke2k91M1v77T/6XW+AHSPdNY1OM3OlMqhIOJJ0b0DkvzvKCdxERjInuw3+8
# DATA u731AOGXS68qRHAud+MwTw2RwbQNJFWifAl6G/LSawgzlyAA2LyShgHZU1XR4nAo1WxWHju6tmCI5b/o//mpMb7++M/3b6yuXnfj
# DATA P9fW1m7c+EP85+83/nP75TAZDZUwPUUQo16ePJt1Jr0E7RV3kud5PsYoJzhgiocgigD6pZxaH6gX6kBC8WgkKN7wOK2UCOHkJ4RE
# DATA YOIy1VEcjvSP/piTzr19ZOjxIH9lf8ym/YH5Ne2YWE+b48XEkeYnYyAVS0t74GKY6DR/oCcmuDecrXRpZ3t7T2vqCSzUlFtG5DgD
# DATA x5EtPdj4cP3Jw7329idbGztt/jJdGY2n9qN06cnWpldjgUSpx/+WNdDQyE/Z0v3trb2d7YftxzvbAJ7n1jY7erkiM7w1en6NsEST
# DATA EfR4d3Nv47K1FCSwP1r/tA2ftz/4bG9jF7wZbYSLeQnPleyLY2/vbXyKE5Om+0+G/enB0gMhhlltPe5ZVkPhYiytw12yNcynL0eT
# DATA 58DYG+zK0wMo+4meoKUP0KOqdaKEkD5anrnc0j4nxjtYAmbXUjc9yOm2tPEq7+6Cv2DLHCY+SEnViq9grxTR1RCoS+QLid0EFtNS
# DATA wsrS/iYBuB4sfdIBJvXBaaRjai70Wmx8uPkpzM6+nYktmAkMUjx4CllWB5BVQj9SXPAQluLpUEqzhG3Qo0k0JWDrF61UGMOugYjh
# DATA JkrC6CsHTZOcCNxETvQd8mgO1YJTz1V0O2Pw9WyTbEoPK/JkUuv4X5mnSUvzvOBOFIhxyTS0pNEft52SmAqq351K+4wNvYAbaP/V
# DATA IEdEl9UEobXxRb9o4/p0O8XUfTzDXJN40/BvNRLLbj3hYl0Ojd18DPWo+RvmU+mSkzpmSkr9Dm1lJrmcWlIw+qlK1GCKYwR5UbN+
# DATA OOn31IWxnmCsKD5trZpQdIKJ1FOBv1k2hq/RooSXSPBkMJVmyY+Ts+vXzx3TLr+5l9y+qW2GcGWojTOt/O5T+kwjGo/hP7dv3bpx
# DATA y95ZqZaqGdM6Z2BHWNq1MPNwoSNr17+le1Lt89VogtdXfe0WOH0dUmreQ+iNrmyR/jxAssKfaM/Mzkl/gJ7J/fFtDKpMmyl5IVjs
# DATA zP44de2cR+kZfXieFLBfkzMsfg5u5BDqymI8uZa3klra7x+hAuAMtQFwvSJdgowUFaMSS6oHSFmoEtMEyuT8UucHN35OsKp2M8WW
# DATA FwMzbBGzzovMI9Ep4TrABAknZtodJz2s8sxWb3qN+AG2VdlvPjdHinaSD0YfztcZ8vPz5OxsCXx1VD0nBN2qnuA4sVibWcWd5GjQ
# DATA UXc+Jjp3kvPzpQTTgvP1A6qhz5S0AJrM49FIX03UrWM0ATe75bVVdVUFQ/8p9/uO+kov4dXB6Co/Vk+7U4MnTZPTm4zG6vkZ7RXQ
# DATA TYsZOUvO7NqfdMZwxarzicrOVW9txfarf2vHbN6e8ZSfyy7k6LzSL47zXl2n8+1qYz6FV4A4aCo5yaedZHATvUEV4X1xe7nfPVFn
# DATA XP3nxW2aJdXjYW95mPefHR+OJssFTAp4pMuHnR7YNPHZRE16rp/AcNShUlM8JveQ67duXbRxR+8ynOQdtZiYZ3DcgWw3y9PRaPmw
# DATA /4zYzLL2P8Fc0mqtoC+qAfXBiTO3tEZ2bxxRYH7J7tBv5+yPBXbCpVfqjGnJuey8+j+QMwy0Yxf0rkZNxswBmMASe2/r0M0AoiRV
# DATA lLqthNCtjft7m9tbFMPH/rkO6baVoAPTTYKgMQ/Bj1dx1l7/GXwo1AnQGfSaArWCWz6GLQV0EJGFwRFPCScpynEFCHKKw1FKzj3o
# DATA 4bSnNhx1FMrHE1Q7PAVP1NPeeykmOo4mznQ6C4X0TOyb3gZIrOVZJx2PQbZ1aLJtY73QMwOHSrIv5RpFlo9Bh4zmT9sSwxMnfbXa
# DATA LeZl8PKH3oTYletL11ppJ5PgxKVtc0pugGpQFek2vImjrGAF29hoU21zVicZumH93HAGtGafPzcw9w2+AXA3GlS8wd5+XgYn7396
# DATA GKvIbMjkt4U2PdS18Ywx6zmcIPYhldrspQf7zbXrepW1JEfMmKi0kdaMUEd5r5FlqVkcGFlEOGXg5A6PphQ/ShAe+AHNbw4PkM9p
# DATA yd0VcXVNDeoQBs9jIpeyaovUrUh86PP3HQJL0ratzpDkBFzyRNVN1ekz2hkWHU1DakdpL0dvwpBdPyWY+ljHUTxnvg8iDU6Z0ZDq
# DATA 4Sx38b9H+N+ULzGi/Sz8oqIsZ/QDNvqyP+yNXtYARoL/Nh7368hEembUqpcU0dMdjCAIDj3u1ajuK952OEJJCnQxgMmS8IlPupOO
# DATA IupFw9xOLrfy0QWrqm6hFb/cqouToCZpa5SMXoKnO2mf+uDIhfdhsIGqGyN5aukrdaH4XR/gQQGDsnJSCpwKb0pSI/mki80PegvZ
# DATA pY1FBIgw0SfjZ5MOnqWEUjjxmNCBABzFNAASHXJ0EpoWtGMTnTauIcGby3ZjzUWhhGwyCTmaCxH3wqLtU4HyQvWqtQDBC3ro1k0S
# DATA boVMKevKwtNFJx0j3elQzFmsFOXcbyH4wHkaJ2vRhZKNqlm6XIs8R/Dn2q0T6oOmAhJam/UK7GkL8KLGjxijlapch+XFaCc/mhF2
# DATA SsLl9e2yV0fV5GjSQQdhraZsnDwH1eAYLL8tbIpcgRFy4aj/qpU2cC8uxyDGPeTTo55FPIW6PcRTaI3GTPoW89b49JoO0kw4JQxK
# DATA hS1j4cURM21w6pzAUUGBXpzM03znywuFTthrS+iktICIy9kt7VURgffQGHQJpaZd1q/7Zqx6CBoa1GQ3Xh73lQyaqmcuQoZ6UJpz
# DATA mwYd+Hvr57RtgtccGOgVQZfwyNdAx2og2LVnagxX8HqgJLFc/ZpTHiPy/yhZHa1ev141P0+GEAqUPPnwk0Ssl65Xhh5SQzoVrDCD
# DATA qusiA3HpQtQNn/zD08Zue3N3Z+Ojmv5K9xVHIx+WDNj/LhzjW4yTjvhXrRNGKZtCke2UoacKKHYp8a4/3eTx6EwvzICxiq9d93Lz
# DATA ltVR00HQrv+VexdT3xTdDugfcUJQGEz3V5e/DZq+W+crils9BVcCqiurpMAw49wTzN8xG57w7JCjUhEjpI4uyoNFIC5BNWqqzE6g
# DATA kny8l6Tcz8zP9VVTx5rQ+4EBzcY6W11szcu/hiQsC3yFPmJ20uNAdrZakXbecvZF2+JQfVx1JuKL5KdwOhh2rvL0fwUjKB1F3CvO
# DATA 2xC8J9/RmsscHWzMM/mdyVrAloJL8UBjHgSfopPRi9xBcrosh2Kk8KYlBhczVbDSM/DGEYYK9ev612KoQArK0+RbLP7/x4HNQB2u
# DATA ZHiFWU91J2rrNa2i+P/SmLT/DtnXPeBeF2Df8Umax1SF15ZicQj25mgfn/oc/z4189Rl+ty4y+4f41KwCaoGfLKzfLS+/GGjuXLw
# DATA XqYZf80y0Np3mnX7K/tO5nNUf1Wwl3PnKJycSo7r7yRNHbAx0Ki6OHpAn0iEsB9daTFtgTs3URCwnaCnI1Vz/UCjSdTBaxa/8E7/
# DATA 4qM5zAcjCNeajlRHRtNjDPdCHYcMMVM0F0S4+HqmFlJXXcVN4FmE/DqM41ptP8LYDsTMoPi1DxliLbMD95rUosqk0xHywuFpaliR
# DATA +m8mUH7Ru0Ee3LnMF4fBvIhH4abUnsPdPU7LcAA62PUrY7xm3M44zM6Ky4Q0vkA6mSddhdWXTNVc6cPFDkFPFHnDNucCXb2CU9Jc
# DATA unCPvDk+SvfP1MydX5QosRHc3EHQ0l1i7IxKzgsupN2MC+VF09vdE7cis8wS2CDvDGfj9hiTMxOCsXbQd84uvNNeVk7qOQraJwVS
# DATA 57AYDWZqegkIp9Fg7wLS+UyLCqZ9pBkS9wi/asI0T4/PBbJUV20ETIaNUFLXJhB7U+SUDo8lBjBcwM+DioBVxC5t2doaA4958zxD
# DATA ytut0fRD8DCMhBAFMFEMgIf8/uHWd2vQjuH1cwh0MAUsZKlZMP08l3BQKGOZgHw7M3g6QG82sYspe2h6xcLGaszK5HTdiBs6NrYW
# DATA tobRdLJLFF7nVGLm5nt7n2ZZvFm/CkeGerC5485pvBLC/fAqqgXSmFMTTJd+gFQKRrYmn7Jw5XoNZtmF1xU5r1yc2ArzcYWp9c4q
# DATA gnnTWSVYFa9DzoENDniED8SzWGEDnKNqe+vhZ36WKvt76wPIKeXQp4pz4wNpVyW3mhzGdL18eOEbPLXIWeA/w1Etq5a/S1dcHIUk
# DATA uvMX3R0RrMzFdoRH7AQav5G8a+Rb4uC2s7cCFM0Wbv6+3IkGjt3rAS8UXi16GEOhbsvTo+VvWYBl3lzd4/6gN+FNw/uvkrNYliw5
# DATA SCiOcRfYc0A3Y30J9N4p8PhMqH2M8VD820GKA94BDxFoK3gr3T64kQyAT40PcFnYoDOre2oi1cXg1FnWIrKuZjCao2LPGm4y02AS
# DATA 8Qs5i/QVX7WPRiAj64t5wcw70uYkNzAC+NtZbF3CFw+UIOMjmaOWgkEDSywLhG11EaOC4f7WrODkDXK7hUbJWmzDgQN7fMPxmXKI
# DATA Kbq7rxC+W67DJddu3/jWTQtHA58F4r5Py6Bz405/UmC6+CIG5y6cQxgUrq4xwIbomxFuS4aHoyoW2IkC84msvOSIhXgIvvaVQP0A
# DATA Us4BXAwg/QyGcu4m+ib/6dEh5Bhq49Db4EjWwj+dIy7h4aaYRRch4hbZFWIUvuOxesSbAk31JPrX4O9JGzIS2v2K9nLzvKpZEvQH
# DATA ahhqJ7LHc5EsL+PXlFCWoYJeUvoZ0JQ72w8PtehEw0rGwa60uEmZM8neJl8S4qVjbKBNi95E2OIO9g+VSPAz2KyuC6pWUWAtOrft
# DATA QWZQ9Kad7nGbcY/FiFA9C2t+mfndoeq49soZDvcOt4se8lnc2JLukyf1wb5F0Vyt375+nvrdrt52PGz9jbfo72DBSbnSRVwGqnaF
# DATA DP2p+oNbpT2BIhFEA0NhjOxWXWsUx2kozRmdnUPiqAaHqrGo9mTYN/GRAaiFXirugA5I7TWlDoySs5RibpTpSkQpdGhUXaai0skR
# DATA Yr0UqypkZLDuBOmkFu+g7lAN+DxWj8fkRsIumMV+8zriB+6nXmzaYac4fjpk351kOZ89HSI6nUNLYSNSNaCiQwxvkE8AIjvvJqnZ
# DATA rKYMjItKgGYgi6TkpbFEJxZAKeBW0zL17d9qamxZZ0MgMhZaJCDijJWH/LmtWr0iWkaF4L+6ECgyiv4rDpAZz4bd6YxgKrrHnUnR
# DATA Su/80Y/v3qtlqVcbmFimeTEGn0FsVVUPdXiloJUckx1gZJVzUwWXqRoWY5g+HArbSfxTz904AIdXLDnPfdJFmVQfOMv2Tcbz/Teo
# DATA xSBMM/j9753fi9YPHR5NQObqQF5CGNBdSKuESg39zFRM8REM3svPCv+mWbpNvK3CB92SuAvuNPYBJD5n6JS6NgyKFX6JJ4X/tqSb
# DATA uo2nqqVOFb+vM/lyABZsc8ZlYD/1Q9rQz2wzRdpf06RwdvSyraPZEEXK5Hw33aWn4Jrl98DvKVrkyESPlID+vth8gfxDyeAwgn8Z
# DATA fjNoh+4z/LsM110g4dQ7dcSmpUXRKxPLanBcnbggNq00qGEvh1kUI6Ir03EfHebg7V18y5ur6cKx4nxgsQPYgTQoUunAp++BLVJ+
# DATA ju/kZ1AE1x0/3Xdq9KFOqXwruV6hHDdj1rcXp8YsXuGaXuAKZgjrTIyn2mHYYzUeBiwJMw4aqG4mzk0MJyH2AA4XSHpRhWwGmzGO
# DATA ioNBycx5G51TJ263qB/qOUYim4zyLycwaxNcJc0XcWGCyzyeGC2iS4mvM+6TJ0jzqxN+pxOIdem1beUx4dacWqd01FoRlArlYh/l
# DATA Wi3YRzMKgjHChGkc0J2R4YikHqbiMIg6jqMNCVEIeP1ZtCEAKGdB3wjHfii2RkrjRTE3AjyG/rxEb62X7kpnCKhxGB2F+BZ4Wdcd
# DATA Stl28hhdC3SKp9wLkNFLu+8WD5DxpeBPbiEI2KyBgU2Up/GdcDQW44xc8D03Cf21cM2A1bMVzrOkimRNMM+JMwZHNSeXxwGYrFFT
# DATA lOpOF9IZKUwvUWUdKQiaykDvPGcL65WyoKJkuI8OomwMsVxv2CzJhkySaCvxUgDspBJu5BGCdu/YDo0IXS1ditZZi1WaVh5/5B4l
# DATA gpm73U0fGfiHz7I4RNhNOvEXpDu/t3kr3QJyiU0OTOQTdPEuukom0YqWpbCX8alzKRMCd9wBWy2TDXCYGI687eWpF8kaW2iuI7wO
# DATA dcj8yegFwOYYzS9hdYkHHJTr8HkJEVEHpxh98R0T9mXLVXAKZoM9gL4C480yR/HiAvXbvhoNTX+al24K0zZsMepzK5HwCZx1k4tJ
# DATA 23EgDuGUaGnIG2xtnoNgllXKWhwZyHmp2NebnUbEjjLD0TIFfLeiM9D2+gJJNw1VWOEMaf8UbyE90BCxllq84+9KPRYcrqNj78SO
# DATA xMwTHqax68Tja8hctEmahrbtfy0t8X8q8TRI514kj9ILeCPMrS30VnBi/7Jyf19woDEsyQy4FUxCDK3R27PButYCVx/25Yh5+pQ5
# DATA JGXZQriP3h6/77lGiV2uWQHN9gp+V7nJjeqcxquxFwuf7g06w1Kap4liXdC6BQjmko6E8dMrCrVxIApyQ0GTjmHFWPlAsGVjymQ0
# DATA 7qNuCdBxGqA3Qay3Gv7UMJCNnkwNBnZpJeQEtXJd0sUy7lgIQeSny45X4DJ4BTYA+jgl34+Gi/4pnf4S7oTxUZ3n0gG+b9qDr9yj
# DATA hKFcfFgX/rPWH9tctcuIi0CoFuoHGn7GxE3648AFJaa2KfM9sbWhjKn7AT4yEJtxBcLYwWQ9hj9Ry0AlRCLdBgXzZfOmBVdBjZZt
# DATA Z0e8LGf98XkDYtqWwnTkDknH4vXk5uq3b8shG858lBrEo6dDg3L0eFQw0hFGyKuGkuWjaqQjt1+S0IZ4KP6EKap228NF0U5ZQOIn
# DATA FVGIte80MRDxxwypkCU+jIoNClGrfp6EDGAiEUZu3rzB4YsJK0yTq5PucrejqlDD9WpbVsWvOpQbDHKKNr/oTPodXI3a3BBKtU24
# DATA qzwv54nbnyqedZQaBAhMXsX2XUprWzkStVJh9zH3b9vuJThF+r7E212/9K9aDvlI1bqkHIoNtCk7W6ujYUinmPebtBMW2RwECgEU
# DATA Yt5xcnrYannL4SQDk826h9CfBEeZ3o96COH5ktwZO+JUFAZRFg2IblZMcZ8qwSMUZk+o6GmEwYLTy0lnAnwUPJGJfiC3R75g9lgT
# DATA dpavhiiO1SR3KXb7MDdQ1OkFhNgjJS5Ak8QbqwxF1B+1DXVg47AfkC9gcL6PAJUjXohIccL9BGeVewLvM5ETFj6LCq6+iAKQc4kv
# DATA nJQZ4o7zwdgxVDquDlZjrnvP5csuLjV671pIogiOT4dfAYQjEAMoHOyyq9UgiKozqL6mwUUruABMolNbFjs4vFQl07zgbYs6u8Aa
# DATA R9sUXiyONFoq5C0t/VsP+VIKqYNR14SEMwLlUXc4HZDhVr1ss6uhbh+epaFLjilqsiSFToemDHse3t/ZWN/TjoY7Dz7ZmeeECGry
# DATA 21pN7jq7e06Dtv3ft8eg6755UddBmDLANtczJ/3McJ0aR7iC0q+SnsN8tTc+tcVPwUEoHu0OAfRgg3KmLa7EaZPbvXaxL1wPEf00
# DATA avq7RHxeOcQHR5HogyOiZosmttSHQB5DZLwrSl1LRbEeV0ZmXoMPpdylrhom7IGmTFF8CrKpxewrLcrWGAFIvJCXjfbxrHKvubTd
# DATA ZqlCvy20OVK7ZsxHS8Er//p6EReoC6hc2Wy2NZIOZaGaNRQz7liX/Od9RWxDLzoHbaVdr768w63fX+MsnLSy8+T76NzRIHv7wdBG
# DATA oVrZDAF2KvXtIIvasfHjuk1Us7iB0N+sPd+ALlNR+N4G1boR6/Yb40/zNk/1BqrYI1UTWbkX3nISyyeyfDIjvShj/f6uLJlvN2yu
# DATA sGEZIaVeGIHpcuSZe4LqpbLovWEtJTTq7nSAlLlfaBSqZSXQoXJxPk61EM4E6FmaXuagSr0XOL02QLf5PD8tapJDxjhGafBgZJgd
# DATA 1fxwWd2rIOGT27gNhFE9qM3T1dW9DkXzNNk8LpMTVKMtRdIvMWZgSe4bmVWsgSjr+kZfw1+Nja3tja29emJ+7W08erz3mXmw8enm
# DATA 7l5VQqNyUkkHwLO80QIqck+RsMZ5glCwTMoGndDLpaAMvAboXzp6VLLwukE7IB09MQB78iVsdQW6gJovkLODGHyU/h1gkkoLABUP
# DATA QvFRmPVeSZl2DjAJSaY0l35aVayVUsHabK9eIljj3/miP5oV7Yi7efSSI6PSUakaL2UmBxV6ZwYq1C4KBrrLxssMRcLkxF9q9wus
# DATA 23llnWVwnUvasN4tCEiaaLcS+sapHRRNgazm+dG4aNuQXMxgpi5pDSbCcDo43eUY3e7KvCXMIxA4tE4Et+R6Eg3FAAp1EFgQsBo3
# DATA rrscyGyBHSuwD0YYmnNGMahYq48mJOOVLFBQ2D/tr0f5eqx5MEAU8SOznT3k6wv82uJAKk4VfgR0ZO5xU7XbMA/ttnuqSj52Vkng
# DATA e5+xmbRpzHdFcUznp6l3mbCxNxMJfuaet6Y7DPXaHpWmOCPnQSdJRWeUcZfhnWHJfKg3+WVFCMJNlY65kUDugOV6ay7YbXBXd6+x
# DATA RiuOwI8NjDCKwQ3xlqtM2LiwdFJteRVh+LKLvgQrJ01THkbkJWmUH5UBrvrqajX8faQk5QOsFB7nLXiE0i2640o+lVhJTl44TAF3
# DATA qeRw+N5LNEbQsU52NBRjaNC473j8ioMgVIHWX6R8HHvLdN5RDwL+p8vslUrfAY9J68Lt2fxApRLGVfSnohGD43RQ0e1lbrSyCBKW
# DATA 5TF58oRJ41YrP1Z3Mf9TSOwWL9wfohI7+KCqgUAhUzZQJwJJp3qjsrF8b5iZTaMXt8wShNdw5P6UdZsI9f7165gCnHNxCwmgLLzH
# DATA gSoCGbJZnrcs3WFpxssjEumy3FYSVpwkYxnsh18KWciVCAKUEHbhtyJ1OCS/L96elpHzTnyc1xOTz5xCzhZoDK4+7uniQ+d654fL
# DATA i4XIR9Ttg+MXTN9V6sjmaU/ma1DeiRYlosPQO7/hyNIlInToiZ29pTuYO3eMubS/euClC3S8lBFiEltCnrRqKrQK4PiW0e2Ep3DB
# DATA HeuRUYvbUXkziiOz+jYfQA8/6r+C0APV42VaVAG18WIEEP+glltBW+VEsfEi6XQno8IiaE8sbnhwn/0a7pi62QvfgC/dN5gPYely
# DATA jGWLWrsc65aHmwEVlYEjSzsQwx7FLUCRnUSSQNyZcp8C10HYNCHstdgGZt6ocYiPdHFrNIBoSnsZMocOtSmSP3nnwdxZS5kAmtjn
# DATA HI84CbyQ2sEnkCbRvKBWlcHa5lbvj0Rc7THIwaFDrC+rJGPNRSir9nq8dDo+WVm1HU/MEhSUOLzlaKjeDdd1xq3Hg0kqMMmi5a3D
# DATA 5MVuu/g8m7PlUMD1NppA/y6l89r9YkHC/e42canm1x5MfxUqBzEfvaxsbsr98hfQ/Jacf7rVvOuDP0/tVqIRIDE82NMegCyGBmAR
# DATA o0w5yDKhriufp4q9iSJn2cXM21gyq0jAJ0wVC2R95kTP3/jD//4V/w+9tOCcf0W5n+fmf15bXXt/7ZaX/3n1+vu3/pD/+ev4n5+U
# DATA Wf8uphfLz9wFVUsRzdZ83CkgEbP5OT0ZXDBvcz15PJvkjwH/oiSNc95V4lQRTd18ah7P1PVCkcX763vrD7c/aj9e3/tYi1pW4W5N
# DATA sqk5G20lenUGo2fkQwiuYroOnbP4OicslnmLH61vbX64sbtnExuDoyq+AhPqw3V6epseYeSYTnV8+2aYFhmSIYja0ey6ufWR+Ua9
# DATA d1/oD2/fjHTOlHqw8Rin4VtLu3uqR+2t9UfoyNkw6UyI4S798faTna31h5ECyyL3FRfGS02kKnJL3Nm4v7H5eM8UsDUddrrPZ2Ou
# DATA ZPvhg/bu3pMPAJMmvXulN8JNhhvo3l34bzLoDJ+1rubDq/fuYnpHhELJp62rCJGnnmKQ1z2OYbi7Qj/vjvUTuPxYD9e7K+N7d1ew
# DATA eohQ2HywsbW3+eHmxg6Fv3RHJ+M+SAoIbaRxjRDW6Ob750+/r7bGxxufRsoeISb27ZtUZm/7uxtbpaVuXKdSG5/ubWztbm5v7SKI
# DATA RQN6hREr3aKgjJ70T/HiGf47fTXlxygYp41XXP5lfqiOav9ICVvpudr93UGnKJJdNdl0YbZ3Z6PXLnSIVDuEUfMh1ObCp1VDp7Fy
# DATA 0vQmffDk8cPN+7AR/3h3e6v93Y3PHBtOHCjNBUnjvsNMECJjM2rbE/oiwk87PJ0GbiAMVBeFX/TCtxbAY2sLQDad0VEiP/GFBkb+
# DATA IBdPd/LuDMMdaJ0inhzBPG5ufW/94eYDnEV1t0XKit/o6UES56EJesH+Ngt25uQ+gBh9xhxUv9a+heqa9OlTDHvCFxUde7K1u/7h
# DATA Rnt9d3djD0lwmjnYxpLQywxScP2KQxzDpZ0wJ69otEONTGBAjwGe4JYPFDQ3C/SBTAiNB/3bmA8aqozCGsELmIQzCjlpNNJzinSb
# DATA TAXQVCOeUtLrRu07TcVqfzyeDH/cmb368XA2+LGiF/trqls/Hoyn+EemCj1tNK5l3+FewW27sRleyY64Fy4UdGbC8IrZ0VH/ldq+
# DATA L+GapDUalghll1jRCGZkuzfCW8eF952zrLz37iXXb91Y4Ag82H60vrkVy8djiBnW2JhAvvcxro9aLTrs/d6wo37qs98puv2++s0T
# DATA VQbhdpETqrsnz6jESOOc7jTcquTlvGfVlpCs6fbauX6Du0SxOmlzKQ8dg8mGspZ065QHjTTLsotOfJRGg6o2wKV1fLDeAeC53uRw
# DATA BzY1NdROO3aS5Zbtawrpt9v6f3QAdJiOZ0pYmiqyCS/A7jsl8Ree9Q/VVBaosQB1+6ubq6tzWDZO0O5njx5ubn3X9RCN45NXY4nP
# DATA aUwuyvrWfSVeb++4jdZGBTlSgsoDMfPI8lLeZNRRrxJ5vQpRfZHZ+mRnE/2ySoZg560l5k34jxYYdfj2s4md2drea6sPN+6rfnx2
# DATA 4Y6gt8Tlod0X7qGq78nD9R287pSis7fJ7iQQsJmCSEpjFdHBUTYHmWMur8kDfZAFqV/tyY0rgdsnnee5RcC3gP2IJHbrVvlpQUJl
# DATA qw+oFdaOgxJ12pHFpsbtCg1QbBI0ZbVprBbDm357Dn6TUgclnC9h/HPze4aeSOqs2iXDY8vZUeE/yBTaR70WtUj1hCvJ4/MR+cs3
# DATA gHDwoRS3LQ9iX5PHEXi6WcsfEcXg9QebW+vq4MDLmE2wLZD8sblMYOoriSPvnERwY02IHJVYEFlfQ7eKI2cfufFv9vk8zHz/NKJW
# DATA 4uHmo829ECWfe1uGk985muaTuaOLoemje7Xtc384qntDkL9PINShPSRo2Rq2ar4yv+gj89N8UyES4Pjvf7y+9dHGgxCgvySG0zlT
# DATA TW8Tmzy8jllcs7ArhoU13QBB10orTInxDY2/DI33LdpLlfknmPbozRtK0bG7BeSMQ+Frf63p4UxqzH3bBlxbsHJz4GNxoaURkM59
# DATA XY4CW4oJXJXxp1o9cEn+XwYNfxERgJbYdu7C4aABzYnknH4n9L4ia4loN5sfyVJCny9ms5y7PULLpDzC7nyLN85xICZF5yxwDYmy
# DATA LV4T0A1pTXItppQad06hDHArAtwSimonDjTQQFenfVnkNkqUjet8tLm7u7n1UXgndbrLsFct3W9fQWbxN55OCLfbxUIxWYl1s6Cr
# DATA gt8Bi8OGJOiBTuDL2gEu4EJ5U/I+fIGAJ/wU+N8cLqfvr86cPFD/SmxtVXzSGWCKUWhjX0D8GgRwRtMBRA200IJZhVxFa/w9n8s0
# DATA f9EZpFkF8KatpnE46p3Wsar7I3xNUJyYCsQr1nBTgyhu+w6GDvyNx8KjaEP3/ba9PIvjSQ0+JJBP+uwd9GXSeYlZ7l9NjcZGqmfj
# DATA Stbd0+G08yqqW1V8WE3jxdWskT5G9Dmozum8zBhvwDnCi55NKXix0EWqbqi4RKFG+mjM9IGnIp+ycHUFbAtF9zg/6Wj/74JUlrib
# DATA oNC+fn/gZ5hx33oHa6GZ0iLU6GXBSvZ97sNByUigqICfdVTS8A410o6F7ZJdipg5VP14R1TNuKAsYR+9yVZPeK77PYzRAjMU+emb
# DATA EAFE24NAVJz/gGuFbexDZQeumtSarKRqUJfFYuaX1evF2tNKRq9NML14WT/4aYOUpwbXVz+HzX7SedU/mZ2UAfVLVH4PkJ8nnGsy
# DATA xiZdIWjfamY615RsA+iF7qzeuL2aHWTZJYiNjN9lLD+cPVqmKphkDvA2mwBe39D7lMKN9Ua1dt+L9BA/cOKLBz1EbIPt5oYdk7wi
# DATA IpAIryYag0RWIRe2T49QPWx0lfwFTUH83VA3yuMTw+fG7EZJn75aXUW1rO4H7xL+6RPvbA4iy8UnSGPznZ2RVvr83OmOFuxxlMJS
# DATA g2bXbFGZnqpuK8Jzf+Pj7YcPNnbaAK658eme1xOaOYgwqXnz6qoyU8TQp15oowxtRZjUm6s346+i1OMs7RyOZlNjScZfK6KB80Yf
# DATA E4DkaMjnbbqQfm5n4989UZfLB0pS/Whj14qPDv5KwbvTC8sHT7gheDGCDgjlZRO2abav+0TfR4aesRC3rVbWkQ7c1gk36Ua60GhA
# DATA 3Fbr9vDhJpi+QvOzoaAHRBBKzRuerK/z6J0pEtY0VE0TNfIBrOAP2bnkQt5tggQ9dZ4PrDoM/RmJGaHVLbDgw4Q19RGw0ro4InV0
# DATA ttCYhlRNPfnhbDRlf97MkIbg0Ngo7Fxg61XQJXa1lCRWUynOuMF7xdgA55MN1y2ezVh6rog/z06qKqz+/hJy3M7GFtAFKcbF9g4t
# DATA H3ofmXlXc6GWaKoVtvQY5D+2qvIyS5nK2yYGO51r0oTDlWkiRpfvbm1/skWUVUtWbufFfiv2dfUHZusZg9/psCsVYULX1YrouhbT
# DATA UVSrr2ifXUQfFtU7RzUXqEiCIcUUDtGY4CqljQzHJZE9UNpcQJv9yY4crBPWsvHp/YdfuZqbVT8QDlOi7GblLw0bLyT+q6PBrDgW
# DATA 8oyZ70BvzFNI57fnOBjwDq2JYAH2MMiHheIgbTTqtxiwH6hQG2BhONNWkatd0FHLVLRqaR2IcjPNdEKYLLh1cj/UByf9Lk+H7EzJ
# DATA ysGJGU06mEMad61wQxSOdjhVywCdCr6MDfjPTUX8j3POK8RbyNRW92ckor6t0LwtfvzmqAl57TSLEf0L063Gw9VjX/PRFqe8mHTb
# DATA ztlVB6mYtkuOs6VGDfkqOLdMMKnNEkMfB+ObcmYn8Iuo8t+Z8HdnfzNAd5V2N9Exnr242lKdNLj7mSyeHPNJo6BwySCTMDwuzyRs
# DATA bBeTvKvufQIjfTqaok6NgjQBUJPTa3FD6iYn8mfx+6Z7C5pAYPkYySQXaIxH41rmbXhd1g1LctiIY2OZw6mCFaT6Sw9MKc+i775S
# DATA rsWZl6lRnbVZdAYy7YpffrINHlk49GhG58XyPnv5n3ljmPTPnrMzKJ9wie8loS9zs9S3KS6Q7e1shOZM/0wBFjoOO1mhkeACxYdA
# DATA NiYqRanRo1mh42FTuZKb+i9yzQb07/Z0VGM8SAjrUnuvlpVNYLWjCy7m2/j/lFlt4uAjdmC4oibpRGpDc+tm1Fn59/oo6+9ZSsJd
# DATA ACbm+Jfl0CcL2JxKDIICMNZztV8m+tWsdK675Ca01PG9ltOV0tK9/rO8AErN8ReN4rhz/dbtWnn9X4UzRBR25i0cJGL/u4DTRMna
# DATA vkNHiivu8qDfgn7QH47wCDp+DPIL9TNrzvXNXMQtofwc2qSVbs8rPyOGaz6e38dDDrWXDiEn6o4KSehv121N2XxXVF4frLG5UKbX
# DATA t5kge3QaszG4VdWw4fkf2ZldJj3vAt+RkspM0NpXvPiLud+UdPRr9755l6MP2A/izFnOEw6H94C6WtFfNRnAG73al4pNF3BUYAnZ
# DATA I9nmEqdVZCweZZnsn9GxIFqMq2Qx/tISnNLxoo4Bf3jiumNulP52YbRb5iqHMO+I6hX3je763N3YO9Pv2iUtmc/7Q9KksiYKlamo
# DATA irJ2Nnit7jahve1ytk/7GBvHhz5cGeIPxFKWe0Pctx1fxMLnfxKElxgNIRbkiTjAWXMfRYw5VIAVsnbugyEY+5bzQcTOVdoGroY3
# DATA 3o83Pg0HiuUWCkEg3/Q9q660mmeWj/rDxOlwaBiLGcUiNnasrrLzWOJChkjZ8wUcDYHhKPKgpOLB6BRgy2JaQ/tW3WVMnKYjAWOG
# DATA mAmGXUY28PKLNZ3AyVUkSf0lVRH4JW0g+fFiGMK4CM+dN4cEeVgfbln6+6IWQRhqGoRWPM4nCKDI/h8lIMlxtvPBk93PQj8P51Yv
# DATA ZVuJKFQlVEd0dLEZktqI4TSNgElS1PNJ8aI7mQZv6TEG5CqZxclMwa8eqp3xwUNI57G2iIYugKhyrhaLJMFQ8yJ+b30QLFY1kvVF
# DATA FunymTbaqi8IPV0b5EcQb9d/djx1GW1xWjSAEitac+Kk6lEMdvYqzeJJoAmgqn/IWmAKqG/cf/DwIecpmBV5GwPrBZTO0WzI6B9m
# DATA S3EVhPmoNkhnel1tKwyq0p00X1VmpXYaaHQmz7BHmOye+tZtI4yj+QUOG+2xeDDn9Uy9P3BbAUwYiPFuOZWE+lGYe7wfwh9trevV
# DATA b2lN4DX+1Y4oUXWLNacCFIxZpQ8vKINh3anGLYVvdLHrlOq6NMcwg133xPjUqtGiWuMcFoAgUoO4vvvZroFbR5pmfm0/3tre233y
# DATA +PF5xRrSweDDU+uiiypo/hQfNU+sCQXh88mpERQsxVQdDpgpR3ut39udqJmLKe+phcWbmGY47k+xAeqV9b3N7S3SteyK/LULH7LI
# DATA GZl7uEpPz9wTFB3N+t72o837bW0AVvy2/WRr/Xvrmw/BBVz68Xwtx23RIxccO1p2Uszgn8HRkxsGionf7RLDkTmKXpXymLEjL5+z
# DATA sFK3tNxr/MmaD4tqgyerjmO4qnOPkQF4KmXQaMtCoTJ2zJZCFnu5/UTmLZ45aRTwTiPbk65oV+aGv05tbeL2PjEkg1A7EClPiJeu
# DATA 4dO4nRChEOH9UShCMjXYynQvV5KUWitS+NsIpXCdc+iNbq8lKkH/R3oOYr9fecGGBV3aenzw+wWDhT9Yv//dJ48R8LQq+JmyzwTC
# DATA elwFMALwRbDUKXIH3mLoMCW+DSzRUdXApPNSX7NL7gjO7cAiwniuHlU3/xCZX+T6tekyDFy/dVjq5krScjZQZ9I9BrtAs0z/wAVU
# DATA XyWmTIVG4h3oFGwHjQqhzth0X7cugfFyApUCX+ptR7GGcMeVIWJUgzG411o+xI6j1L68qIfqCD0hOGUHQa7YWlQ7wKXnqwe4YJYt
# DATA riGgE5tKScbuLHsKnEsyhR7421AWLjkc0dJZJJGF2bAeLQBPf3m6kdx1XobkE8UWq+ThiZkndTH5cpWqYROCP3gqPBuPENNcUEjk
# DATA BNxqcuewCy5ST6aj57kSIUeDXj0Z5i8ZV7HOLEpiROh1iJG2JZt1oKTrFH0smnbEPMEiLBJxL38Bcyq+cV8udCulOUZ92Ge7exuP
# DATA hAyot4fThNosNYGTBS5AOEXCrcEL8OZqMNJ8ddWNxilbSaHGiW9pE2QSLenSYKO1NkS0maxpOtqspGf1QPiSxKwZoWSaEjdxy4Sf
# DATA 095vJm9zlGR2E5KJNH/S+4ycZRwemr58+ZLCzmATKrIV36lQQL24WOwxM0RvfnFfqL/5CLG8xLlaQGyQux1yRwx6PG1Knspfqr/h
# DATA wDlTCGV238EMerXqReGzndLhhgf4x7mMmzK7CXmzdr31MPauJdfnzaD5Qlrbtb+es3IS8I4cMqMQQiQTHfWH/eK4jJ45elC+QQgv
# DATA 1/wQNr8vfeHOkRkVnwVFHOdALBGjDCJj1CIUJWg6qn10KSrybdr9PJrMSXpAr3RHUE2iaoiEAXPyPipX11Pj6x8X60ALkre9FG9w
# DATA hioaN6o9rqJOs55FopXpRuQyGhlxyItct/svSDBYFNEcM/O2ElXzA3VChugrV7pnpUqSi4fmP/3i0hZArqBechzfXuwmcubSMaZa
# DATA TLDqgj4ZSdySk3cnky9gtsPOekIqIj6GViwqmsVldzHYA41ML3dBTHIPL9ExaXpBgT6OIedL+LAKB/XE/KBFiIj80dmCxVtAoMdi
# DATA pZcIWuSFbxFc3LQajZXyoNUslZQ4naket67zIjeOvZ31rd31+3s2wkgDn8cM4vZSg1Jp6e3JvTpwRaT6XIRvuBtz6SLCaORTwXas
# DATA iGg5y1yul78aK1EWoxrFPgjyTzuLztjsdPGEc6Mrect1aS+iHpl3EenOJqjDar2VDMV2oheaO0GbDt+r82+7/Jk2TEK2Jyhv/Ekw
# DATA aUJ8OoNrqO6+uU/a825T2wxws9h5xzc4My3dgblqf5pXV9SlZJCC6CxVCSJVuiS5Oxwx4AIqAq6rZ+beSDZGwVpKnIQeeNJ/hgFc
# DATA 7tFyP11yjeLhuKiWrHrTX/C2b8/Ys9yR4/TywqxTMiueiKgdxNyIeKTyNhTv4yX6acVGt5V64h8AX5SOHxO4b3ij5A+8XV0+drst
# DATA I9dr7KptNCLjonwbEUZFT30guFJxNDDVU/umTnfjXqCTggLVw/NQQYvq0SODY8Z5l9ttzsSLJarQ8FxkKJEBSBKIHVyMq7Bt5v72
# DATA 9zZ2PoMw8A8fbt7fS7MqumWGO/94hcMKVzJcHLJ1lpAsc9pNnzDTEX88l1pWDvjr5I1c4IphOG5K33IuthDOaYQ3zU/Hp6PArCxR
# DATA eURZG2FLs/ozKxV+pLEO59dvSfeAr2vSQugvBV/6zvgOwkojzT5je9fqd5L0WT7MJ7gl1Yf6nHh6H+Op2DQCm/FdnCOMnOtbsrok
# DATA T/udAUVI69PquOHww/I4NOOSEY/6ukhsstE5XCQ8WXfwHcV6OWoaHWNx8fAuMn8YBsFh/uByFQvcOupPMMhkCImYuITvL6Ht/Fi0
# DATA PO2vtyj+lxYRUYJiwLUxbLra+zpwkPFCt6i5RUO3YuEjbwm4HELl3iOboBNZcoXcbXWWjGzBgQbaPGfBQXoS8xsERrF+y5DFiqpi
# DATA IWGL9cgxNJd1zBk7KvX0r0AZZ3pbD8HxsrcdQSxceJE4gCofQwBSyycvYr68LgSf1hn4TNW1LS6VTAYrKbOwQhGiy8wA3swgE3xq
# DATA Ogc6NpJRwYDA8fMisI8YR8Qa8u7Ygc9w+JnhXJJlcNZTxtQQNygfX6OVThTRHJ1gfAjGnGtwAHFRkybISiQOiB4HhSNXZWjT4Wg0
# DATA iLjC605YtZh5RF4A1DVz444GBBikkIX1UQDhs7FrgOXsmjkOO47BzZ4Nq8qJuJjzZcyWXlR1bcO/A+21mpWY4toJQafptnEuXBv8
# DATA 9iUDU6hKqpCEKXo+sZS8yrfKPaMC2xBhJEKPhSjn3ESWhL3ab5VkkTL3fx0A9SJn9c8ixirTKf2df1kRkxyl3guQDELYCCiGuXtF
# DATA w7kkuTC9cwNmXJogConnB5JMiCL87ODcj/WQG+rSG2ixTXQhtWOED8SuGZFRxFWo5WLz4p0nbV1k/5KURVMEb0E5fOY0UBb6tn/g
# DATA urTVF/vKRPpVCA91/3Pzxgn/K+1A5VaJ3fPhGSMvOZNxmamuAHoitO1Rv0tuxP2e+rB/1M8naMoRPxkBSne/Nn+TWLxNkEzhiaiu
# DATA 1Qr5eGYVmUU+0Hr92oL83qM3xP856V+DhljjkRIkmWGZLcEy8Sv9xrm56x5F4bAuDIklASMdXCzdjsDFsrH9z3OQIHxcn8D+H+Gw
# DATA lV4AvgzruwmxkshLR3FR4MhpZ6KuOBjvDd1cSQJ4DOZcVLDhY5RI8CIsYRr2/VotKNbNm25/GaDDIsmd8diuSYwfhhBUZJVSdj/L
# DATA G5Nng9FhLb2WZtl5HbD4WoPOyWGvg8Wafiaxus4SQpECMU2sj5AyzFntFTrrVDhDOfGrTbNJbSRrU0uu8bBnjmhsaqA/j8iVQW86
# DATA yrb5++C8rHV2x5KeFw6hdJx6zAyVePYsopqLevY4ZgijpbkS8QBZNLRc6rov6sbYduyT4lGQTVBKT0z1eqmQEqO8BQlcyvecqLAV
# DATA 8asrE77KNp8jW0XGZKUqPVNSqNLohpj6O7yKUcG6URy2bWult68oWHr4dbmXQaT4wvemjza2NnbWhbn4K706XfZ2Ya34okdUKvPi
# DATA JrioiAqRjWrQ5wX9I3RlGIRzoeiJdNGLDXgWld4jM+fKWFUu7v9UBdhj/ATajze2Hrh4t9aaUSIDX0RxExouIhsWx7egTwTXtNA4
# DATA 7f6OkEI2R5OYU25xjzki0rx4fiHOeE1hbRAEvq2fgbcstagH9la2bqZHvba3LlFPfb4WU+PzvXBsPJJswl8k97VcLT1m/3Lg9dhp
# DATA b640aaOxFmVhvGmsnbHu9cH45juHvpqv0fdvqRRwFQLeNDoXC2/SStySsU6Hy9khS5UBgkEHrA31f0qEfeHmsVTy4gQdoSjPemN9
# DATA 8mwGk/0Y39QE0HMr3SQGnhzOhj3FxhNF/jqDBIisZhcFEsbRbJrgvIFeC3IiQJ+LhkmoCzUDxni7w43V0uVlibsGesnWY6MmKPuC
# DATA pM3KMgJnRU1CR82MUaJWfkeztzwhp87F+sMSELCXLk0YCRNTtXGqW4M5usRnvG0W7qAmz8tiE2k+jABr/B3+A18WuGGyaJpqeN2A
# DATA jgfnnw5weOVHVwr8jDseOOXgSyeLozX3qzcx9uKX0WKo/s0q8Eq7Gw+bomXtvKqx/HCmOlMkYnciUYxOZd3sfbMVoBfePg3myRE5
# DATA 3QmoO7NVL50EfhNVlYZW/PnzbOdssfnyJ4e/79gp7CWzobqbwUzCloGqZ4WiqiVz4lhEonOiTSP4w5om5BaompXxpK+OhABepqYX
# DATA QV7OAtaxOs+MFcEFCTpwlmIJZir4N1z6w/4ouRjuuS3AGSim6jo/CTq0pki+Oa4m4Qyo2mySFQHZb07qwVLciupUAUD+cHFF9KF2
# DATA GxVZ7TasRrvNXgjQNSXfTmvIc9SEfePi/wOuguuvdYeN8ek33vH/VtX/bt+8if+q/zn/Xl9bu3Hzxvv6GT1fW3v//VvfSFa/8TX8
# DATA bwbYEar5b/zr/J+fe+3sKqmnrjbX6ldR1Lja3D+72u9dbV5FwW6q6IM6KlfrVzFLhXr8+m/f/OTNX7z+4s2fvf7l61+9+bM3P33z
# DATA k9c/T15/kbz+nfrrt2/+VD1TT15/CX+9/vz1b9XHQuCBKv5P9fqfXv+9KvyTkq/qifr3L1QLv3nz16rI61/DK9WoKqqq/BW0pv7v
# DATA V+rpr9/8THXjp+rfv1EfUo2q+G/f/JV6+YvXXzRU86jCuto8u6pzqKhO3L3SGyEMBCa9uPf06fAu/JEMlITVevr0aj5U/7l39zjv
# DATA 9O7dPcmnHcxQVORTeInaM3yPb+DQwuMX/fwlwCKpP7UGDR6/7Pemx62ekiq7+TL+qGtLwHKhhL28tWbrOp5Ox8tA31/Ap/epluVd
# DATA yFvWn54uPx4N+t1TrwEWwpaLSTd5mhb54OhpeiehKfcfTk8Hufesf/LMeYKucs07yejwB2r5+dVQMS0ofNgp8mXVF/EIQFmWScyy
# DATA T8PZEZvA6/968qJfzFDqneaHo9HzBNPVKCn32THcSY4VIzkeDXoFssLpsZKMO4otJsUJCM50mYCEyglou9VzxZZOkrxTgHliOgKm
# DATA 2Eh2p7PeKX47mvT6Q4BdYiRZJdCBSH0CgJDYa9zq9x6DahvEmyPwHkl+nPy7WT+fJi9GAyX63V2hQnfRX2eSD2AY/S6NTHX3CH6v
# DATA dAq1X4oVeN4oXjyDdyhTQtkTVf2Kevjeq5MBtiprwlUqjvN8GqsPlqDRLYoLfoZ2Pv0ZLQVA6AdFfgAlQLDPJ/furlBB9QeeBDgm
# DATA kO4PtwgqgeBzSSqwdnVYBqpK7NPz/lj25pvAvqDQrnoBq8P74O5Kh04btCq+P4SLhTMca9qDatxVUXUMOy+UjNLvLA86hzQtj0Bu
# DATA Uo/7zzq8+aCFkvq2X+QTOMdYlyhVqP3TzwtTbnfcgQOc8HO/OGxBU3YH9uPL0eQ5rg0WXVH94UmFAZNo2INP9fzc5dRMdirGYOuB
# DATA L4gyrd3bO+6oJRyDTGwC2tQWV38rWW3YUNWv3bs7VsXyBL5Vx+M0Oe68UH+MXoB2FzL/HeMBgFSO+BpWA8VM2KmjRqK+VddmdIdT
# DATA krg6bVM4YqejGSwdfKwVVfroqlbH9+72+i9sv4k0FP7OOJxNp96BcZfiAyVk6mYOc3XvBbxdnmivFjAPjoY9daqd+hZZtBXVV9jn
# DATA NNuRaecHNOnX721PknFfdWw2VpOkSMvRTE3KaDSA6b4O032/M+jO0Bx5NBih9J93yL87QWqf9Cadl0BxwK8PZlitl9kcSW+U01L2
# DATA 8imgFaobhJJdZ3C2VMfB7ovANQhk1B0pEb0PSnCa9YvsPzPeFdhw9+4eKVEeduLYPVFqd8mpAK0v3RKgXps7StWnCt7Ta+90xSYi
# DATA g2/WkbL/UedkfAfk9Red7il0KPl//ym5UP9p1XSvV4AowXliXq6Yvm32D9z+D9x+HrenbXkJJv+OefzlWPx8Dv8/EIN/x/x9IfZ+
# DATA Me7+tTB32pFy+Iah/8s5QUjw5/NORelHRa456Lpmm6TOUy0id9f8Uw4Z5JqOHeboiAMg1djVtkK1Ci8RT0G3P0Hmiwo8byJwelCk
# DATA 0Sy4QHXaIO9MEMr/RDFttbMGdWTAahD9k7yXHM76gymMAOhjQUNWPX1SwCcoben+6RFAC5ajd7U8UPgCAYkDo+HgtJFsTrUM14U8
# DATA 38DxYeIU20JNszVra1Gg0wMOg+pF7CIsyjKKBXDWiwJxjJLdPH+e/FDtFXDW0saF43wwRl0VdDLpHB3BKoFA0jnKp6dmhJ+NZhPL
# DATA o3loStIpkslsaETNQ3B2yieNZIMTDcGUwjhmY5BWQM7UuxD2eIEyjCoAKRRGICQp8lBAmc7gdNrvonSjxpZPpmDjf6aG0AH/C+3a
# DATA BnV1j/Puc1R5omkH1Z5OZ/77T/63gscKWl70Cyq6o7GqB+VJsWaN5D6sf4J2eUS8UAM7hZFzXfAFdPXF/8feuzY5cpz5vV+lHFot
# DATA u0UAgyrcuzkjD28SvSRFcygxHKJeFIBCozQACqwCuqc1OxG67K7s0MaRwyfibIQjbIcjznlPaUWbpiQqwv4C3V9hP8l5/s+TmZVV
# DATA uDS6p7vnlhLJBgpVWXnPJ5/M/P/wimhKJTXSgbLHldp6GFNfNIkqbAeCYgJDWfJ2lsec2sSCC5ueoTtMjnh8MEBVrPm9t5OTmZh5
# DATA yEjZWTagGoMda6WoST2VWzIY4RRVauXo4QaRVPRxkknRYk9hyib+wyia5406HAxg+08SNIbBgK8fIaAYCokQXuLMpNED4WQ178OE
# DATA 71tyqdHtUcpFhrw0LQqBzhHhcaQ7Cao+H6C3iReSBArabi6UY0uq3FzNVWvVrTJ6RMYiknhCgZmsGPHkpVCQ71GMzcalDOIe2I03
# DATA lA7Gw/ESKqE01udKhyGiWPPeROcjew9QJCnGxYj6FlVd6T04v8W/SZVS1v6Vpzm7DTY7zXB2NJNvzdi/iq1/DaZ+0Wgie/87j/vJ
# DATA IzJffgZ8TZ9raZWuPMFDj8niSSaTaj+iuXCcpAfZlIIeP0G4j6dhSrXhoH6IFY6jFK6fg+Mw3atW5+E8SvcPB8mEHpFLZJftH6L/
# DATA OvA780d3/Fq75ckvCGv/ELvMqcs/qZ6k4fygTzXwYZXSNnwSPpZg4hk1kHhxCG3/6hJbR8nWi6rJaEQJOqgFQTR9Eh6MEc5jvmcI
# DATA Fgg3kipV/sHDGbXdg2D+6IlUkko8my8XFdm/VcETGGsecxTVu/SdNfn7eBhnNAyf0s/86tEkenRIo8XRrMpb/g4GETDRhz+l1hmP
# DATA TquqfenLND8lowXj6kGzOX90OBfj4IBygvpMz6/5+HsoJXDgzx95GU1php6VfysZjc5jtijmNKVXX1almYbDeJmpn+VLhWIg5VE9
# DATA kTi1W/VDmkplFM48Yd71YSkbDzCBUXlSM01M505+5bEVTeqmZpnsmFqpDiqoH7OFir3cWTS8i0XnnzxeSSgn3w5AqpgK4oBKBqPK
# DATA 8HEyDwc0GzyotVo6NWoOSJVjRAZCViV7MMYIpB4tXuRKUbomVaR0UVeY8r3LKTWL0+LVx9S0UWMOGqVC5buo7svPui5T0TyReFB/
# DATA vfdjniLxME6t8if71kUUZfKT/ZU6zDPpA79e/3ah0rWp0m2oXXj9/u7tOK+6qLm1jlVxdWVr6ESU4l+xLkr8VXQDapqHKqr8WSpx
# DATA dbUToWZXzcYpfTmoPykER7b6Tx7ryNWfmAyxcsHv1ilsqmzxz6IDtpxomHrC8yPTvo/SeHh4RN1QrcEpKzSTel3urnGSzDObOgMO
# DATA poNQyu3fDrVJoY5AXaDyf7y1jHTq/FrQ0qFKBlK8oiMaxR/bAXfqdfNI3as16ZEnY78yDirjRmWuuvDqIpnT42Nfej95HeZXMJMl
# DATA oApIyxjvpvO9oNbEqyvtWuv4pNKq4cs+9ej1poqpypP9wwlZQlQl4HZFBORX6hKYrFGp1uqNFj16OA0fqTT47cH4UEWqn1D7nFJC
# DATA GxzpYLfI+dKdVhoUtYAzHlHzuxdEjeIStJCdxXfzmxvyZnqJp3KdQmyUAyw+yS3jCTJYJ63dGYyfxNOjSnZ8ZGoNk9AOrfaqKki4
# DATA XCRPZE5c4X0GMqKrpgJcnB/UqSJXMGHaw5Ne1WujTzcRkUHKDunCuloeuNhdTmP/4iSKZlyT/VqrVJX9est0Kybb1tXcJzX2Xkhe
# DATA diQvm5KXwWpe6lwL6lQh1o5DNJcoJoj7BbYe8B9peIEaWvnvE3aHXJgL5Xa66e1eKCOX8urfhQn8k7LpcWAslcNSs3xSgzfoMcQT
# DATA +MZR/CgaHv6syj4YSvchGmXVRykfgrhBOY2M3tBFm24B6eSQZQh6jFDw5JMamTSJ7hyrwgxso+yKvR79x+xZQ9+7nM6yA3+UevTv
# DATA pv6NGyiH79XIcqDXcFq5i9VmTV6kzRY1BLl7FB8t08gYkvnVQcjeUCucWjdI8/aJVNW6/Fo1lbi4LnRLz/vSRmvK4C9lTaueV2u+
# DATA e32dVg9zh1SMws6Nyc5U6r5Xur+WHUt+kUedYfEuyjqU3OMdyjKN5jQr3GtUqJ5ToezVK1Sy1G3kMXpSG4Tp8LE1slijTpuH+nIt
# DATA zJbpCEe4L7Avtpuj8l5vfoDZf3UwjifD1WTyLTW4zyu16ZImpY9tA4GvUED43a48PcnDE2zLt62B3to2td58blEn26R/G/RvG6ZV
# DATA qZy4fhYKgH12xeaywVA3AwwCKfWGkuaD2WIsebIXzPY9nZZNJRGsWm1PasZvWq7r1A1QstBJmFs8ZQ1IBpqBH0MrRn18QIjwVVqD
# DATA XKeLts1XPXvw69RxndITL3apo5SZqsfR3UuhlTDU5kkNvgVj7QU3WS/xJl7MWTUR9dhSE/PtEi0wWNsCOSzZDPi40FmJuWf3856q
# DATA c1vqgEoZjx/NdTNKqy00pDs6GfNhSfRWBzQp415Ux+iAkrI4NWnkkbAm29YLNnatpa1m1fwC6Va0L3KNpd20U1c/xF1VXsBRb8n9
# DATA mJP48Q7mRmmOQj0HzZviQfTYzpLyfEw3R908ZNytSaHQ9PLIMqJM1Os7DBPyrBdiukHzwR0qSaFueOZbgG+w6VYbhD2mFPtrr76b
# DATA gVaMpTe3Bmb1U0aD++zocclvQA0kPCp7R8S03VI3TQEFMolMi3Wm216dVG5omv2wZNvqlrQytpbsgnIXLgaBCtKTSSEeOfCteZbf
# DATA 5J5SmkKe0WXnzTDMxlExg388jofDaPaTQgP6V4IHDGeLJ9TcHhs/2CM23e25EeYH+fuaFzR9Oyu7mxp2ye0Wzk5P4IZ+grURKeVR
# DATA OI0npwdvkYmV0Lhc+ey19+O+3vv+QTJLPnutMqU/HG6xzVNeDmkcjieZlU3B7vVR+VIel7xSZadVyV7X7/QKs1tuwmoSdVFzPSyO
# DATA jhzjQE188hAb9nC/zujcwQAsV/luHkur9Vl1oIXxVd1QcGvwTGU3/yT12Lm3ujQT3VAdavN4MqmmycnFVrayqRfR3JS67kab+U/o
# DATA xE37b6oOegEXHodXbgVP+CddcNRFTsJ5RlaJ+mBPoO0ayAPzYlxZDGVaxnlxgNgUxtGdKuNim631pEYxiB5zTy4d+IF/p+rz2Gj5
# DATA iCyjQWyGZLmYLxd8IqGcWTKn4l36VSzbrLFmcTwtXCTpYz3srrNlpUbrjs5U6Cf/ehoN43DPMtHa1K3tP97odLA9DY02+l7lVSi2
# DATA FmWTrI5OXFnkFAWmu5JNdp3h+enG+WepUTYwc7WzsjifNE6XFvfVPDe6lDGmjdXN8bFfvn4K2cBiQ3GGuGO2rBgMm6flwUj7GFuW
# DATA laIfvGfPpezqGZTMZ23GrtaLZoPrBedhRVu5G+PDbhlxvfCo3ssLpzChCMRNp6aaxeFh99TvnFzuRNbMf7gjp6pk0j3nJc2smkbD
# DATA 5SAaVqcJF4t8pdaxbk2MA/9O5TsHsumDPoQjtJtwFk9zl1E+zh/yoki85hcdDTmdo9uiNMOKXowqOzzEPubSVOaH5fKVlTqrV2Ar
# DATA QM0N+zQ/fWhmG+WbnjwprBjqXVvYIUh/vEfTyYzXPrEv7+DOnZOTk9pJo5akR3eCer1+R23wwgaiN5NHuLHu1b12k/7hZV/UeE82
# DATA ANJ3vuhJR5Z/T/k5P8DnEQ1BvGeqUW8Mmz1sfLz3BsuV8G6hD/y25/fGjeC4+/2geezXx/Tf7vf99s8KD4+CUWPUkIcRxeKqaEYj
# DATA ZPT0iezSRJ4m85yCZKL2t/GN+WYsqrj9U/zC++by3XVq85O5ai86H+Q7eswegGjIa+GnZgOelSW9utdstrxGr+kFrfqkUQ88v9uo
# DATA Nuodz282ihkzbA/7UX01VzsNr9Ft/MjvtCdB4Fd7LS/w6fF695j+vo+gW/WgGFQ0GvmcxzxdeMjp/1az1aq3ovxi1RR9Y+WlCLXr
# DATA HzcDf1qvBn4Tr6z2ehwZFRHPl1pxxTcEQd0Lmv6xHzQmvu97re6Pgl73Zx80Gz2v4VP1CboTv96pNjs/CtrdYvK6g14UhitBdlqU
# DATA K72xH9Sn1Xad/jnGxyZdbjS7Y9+ny60W/XNMH0sx77f79eZoXcybG2uq2r5IFfUAJwsfK0/wgarhhzy/P1CN5VBPbQ++1W61+w1c
# DATA MN4neoT/d2gMmtUrwcG3Ij9qRZ1D5WM7+Far1+50WodiYRx8qz8adAd4gt3O9POw3QiGh7K8f/DZaw+ioyTyfvgeTRc+Ccdke1bu
# DATA 8/axjLrCahalMZ7VXdpOt6N7qmG3JZlMeZd+INakFxSdzl0xBMztZjRS85vvRdSm47AiQZeW5g7LjjAYZ5VOrXl8UumII4wDVjvl
# DATA dpneb/Vv0Uy1GGLZUW6beapgVh/QPvTiOFG4a16wKsXk5Bsw/gxi7CR6fInlgXwtQDyAJbNInFb1yxk3Hly05Y0YRa9AfaMxW0ht
# DATA ZSVpFxl3yrO3UsfYbLhJS+XJalv/KZr6Z69h9x51EvFgwTvJZ7wB0vsr6It5d++ZLZC1z5dRevqA9wUk6V62b91rbr6fpuFpbZQm
# DATA 0731z92fTOhR61m1l+9volNIL+pn0MJr2A5IseW5pfe699lrB3YEp9EUp7MFO/ZBON/jQA0rnOWMH0anFW8UTiao3PveYxz4p/9K
# DATA ACKTz3vKHkgkQKR+j7J6z4rU69Ao2z80VGGmq9BLl5OJ911vT2JRG4cZXrZPl9QVCkquHFgROPBw9FO0CFhs/9B7gqPKgzHFSr3h
# DATA MiHi8Sd2qvlQvSRboWIf68czeVz/cKjyopD+bEP6KxJv1JLZUTw61dgqky3YYrMmLSMc7l6NZHi6h8nzvimKCAK1f7X32WvfEs/v
# DATA Z69R0BAbiiZAtNZwtzqdQTfi22EpyHFysjFMMUYvHeZsOd2Lh/t5aj5cTvtRusdhfgbRP/q1pnOz8OhQbSLdEzk3BC56FvSmz17D
# DATA 1zvUnOPZoT7mImdcXstjv0wR/R9+/H5Ndlz+gI+H0Heot3lvQkPvxwjnJxXvMQJ+gsKQR0O7IcnT70wi1sv47LWQsyGsYfcfNGvS
# DATA Cb7p+KI1UYxxaTCJBw+pTWHr6SfxNEqWi729fbRxRCqNjsmoyCNF4YD7TvarygqJCtY3dClgNoGX2/mUzLCheW80Q8JRNniAhfCm
# DATA EPp455gi/b7SWqEwsmV/GlNBVrzomIvtHj3GH2tQjaG/b8vGrD1V1BwQTcdpKvQj0DvixenePoU/ww1PVFT/CtH7sRy4CI+jn1Ak
# DATA a/TgO+FgvKc2f/KLJmQ0Z6GI0XHvQhHCV8Tnxz9Rb/xX0gPGGf/d4xvojfq5H/9ElxLlP3bHQ5dzX8KX66esZMn312hUmSyHUaai
# DATA kXeI9Cu9z2ySW9zX0vYoYWvrG6L2gBvt3inUOs0zxcqPd36XKuYDSQ51MPIZ542eHOqo7uWPrykbri94n07OdWSV/rxDdlAC5C4y
# DATA qmlqu3eMWIAdfNdbe/uB9+NajT8PK+vuMAVFFnCGZHI8uHu1EiORLmQRerf8GZOtZh/6cj7Um8kLG/hVvr+ptr2v3+N+KM9IWLyl
# DATA PVPb2XEmlAyK46jGLfyJ/Fus3mbBq1jHk0d5BedbMl1s9JPJFPPw5iKUh6kMTSgoRASyYgN89tq6nXx2tPh3iRh/lAhwMUjweX2Q
# DATA 33VPLN/WVVE+eWPXUWWC5Bq5lv2yLdoHKi6fQcJzSraH1DYThU01Z0N+6gio2qO/kn03O6LJIEwfj814z7yXLpZqmW4tG+rVoTlQ
# DATA sb5modrk9UbVHZ0/MFfNCM3fVE8uN9CoT3MrNsb4Fv293N1L03xPtExN9nMmsz4xh/xdyUXvb/+WYo0KQf3XdI/+JO8nJ1H6FmXe
# DATA nsliaggZi6/pVxaeJisJCed6jRMTdF/90LMaBDK1WOnogl01WHQR4j103e40i7HJayKnZd/767/29nTU7t7VMUGkOCBTBUy+3b2r
# DATA koL6i1tkWY/e/K84CtLc+OO+pOX116WglLGDlUOd/fwlN3fwbV/uyIOV/EDvWM9HJKVUJGWIG0wg8tu+uqc0fEhYXEs5hlHGAweV
# DATA vC7RNY2R2xHaolUpkBxTjlsbcOEhehHiqKopZbIOZL9Y43Cjsjj29u/eY5vxs9feNYfC0Exe34PZ99lr0vQo/d+R7zwH5Oa+SN7F
# DATA trq9YP91JPh//772Gf1v9raeJSfJgl2tXrjwfJqxvC4B8GEzCoAeWv8eMp7uFG/N3+Xzu/7PP1kP6gjt8NxgKo1bZoD5gUx3MNsd
# DATA zL7oYLY7kP1SH8j2CtuN1Tno5/qgtvGc8c+FE4AT6/j2gzmr5WFki4eAjejT2/ntvK2Yz8k9X+e5X5RTjRcJt9iOUo6/eJzvvUE9
# DATA bbkZ6kUyRMOsVHRlvctawZML4YS/FQ+qlxevpEkPEmSuvOl0NtDRUH7sez9YWftiM5XsgdLBf+sZ/sLp4AyY3+OiPaByhx4MlRfs
# DATA oXRxik3F5vm56AZk45BPxOoa5akNFzQt5OPIyz6Nax68uh7mIBTm5xwP3qUUJ2nN+8E8mvE53xGf3aeH1GF+rqwehTVGraM66ck2
# DATA BMYw4W56MxgLFNBM6QbsqLzjlXzcWkeAzxNztMlaICP7COfSjAzP3+CYMyocTncz0cH7aGncvd4Ml1n9SN4R00/LOcyGrObBluIf
# DATA MzapkhGcPNRihrDUVLMhczlhCYDRMiUrYrmqhvByHrY1ITjrzVlvF1lvxRrm9HWcvs5lzbaNBuJN6e48wBY2Sw4Cr4FvE8J5RoHn
# DATA 2Wm8bRsusbvPs+XqCpYcr3+w/YFFEbUlR1/jwkYnJHYs+wR0Jisv4N50/w3xieoGOOP1KBSShGaeM91VfoW9Yrz9o9biTURaw5qS
# DATA zxuicHEa8n6jltpMEs1591FNevY7HMdSVMULYaoDvu0QUf2Uiae5YKLZqLWvMZriGaGftZeGL7whjlYVKX2PiZR56I2EO/w8cgHe
# DATA fM8/COpv3EmUVVi+p6XuaW25x6+rm+hDftcdiVaeFGWr69xUq2D0YN4MFrbkEZkN/AQbEumU3st7glU61WooRi9dNfNL0vPEx/yi
# DATA OY3TC8mBOxIE5k8qt2Sd1g4lv6R3qJkr9yyDM8SEzOoAbGkqNhql2S8pVRB+MQblBzQYUv8sRqP2WlvtH2NsNOOWz4aiGWjjVOzI
# DATA mnd/OPT4TKwyCzI9fOY2pPc+1lCUqicmAmakXUI2XRy9bJSKIU49Dt6IXRj0tvlyMuEfl1iGpUE9TrXx/8MsEuUdEbER3Z+4H1MW
# DATA i8S8FpHSdR4LthlHgcwSGBZsSqMnwrwmzjAtpCTNpPPTKldsr08gfG/1chgD+xHrZXKmcQcvRcKl8fJbzfYA6AxnZzhfZDiXDCRn
# DATA OTvLebs5/BwoVn5Cb+PGkYlmXjhUrSE3m0uajRhcjM4bKyI+jBZUoLMjkbYrSi8KEywZYdxKlARkrpQoeohlI7nkn8V2RSkFtWXx
# DATA jXGD9ee0kLNu7BTjhrjMjEglLBjsU4LeYijRZTHsZDTC9i/I9HFfkHnj5IR+9qiEZLjkvK55yriApCXF7hjjLvqZZMQdA+e5JV8p
# DATA PitOTnHQW4TszbyfYriamJHOpMhO2vvslAsHZONASPOEeqw8ZRh5qzxlkA3RjDoNJxlvF4OlgyQekS2W6V5tSIU3pt6MS4mTKad8
# DATA KIQZi4rDjUim05HMncSI0f6yZEpW40KpC4awCh56WilkSzrfDk+5J96eUJShuCpRxjqND5T/cRRFlKxhPGJpP5rdwVCDwCH2MGIf
# DATA AlWrhWzBYLox/YKmiF/YBPQ+YQyPx3xBBMiWFTNl4RikqqgTYiy6/vJUKvXpAvUZm0S3JPLjKFuTQDErClV4VVDVVHWyUtlveQJV
# DATA eFSyCZogjzpptM6IRZFWtB0Jwls4jHH2TgY6sVOVmCTV3o+h/zKkTCS7kG0/JB923pKMCX7ioXhctUuZIWWo3VN5p9iTeiqtpU5H
# DATA cTrlxZF1c1tO1CeUNzIfB6N3jmOkZCYZtXVqQcZ6zhe/M/Ffy/2UH1wdyRRQ0/MwE1uYeyfvAy3uSb0rwx7YlFYgbuNDpsbzkM1j
# DATA TA3I8KWSDpeLGN1GmLJO11QpT7L6qXQo4EKJ25gsBFxXU4qNqf2bWXIi9ROthJoI+kgItuoEv51w+Avsq0RuS1ukBM3hSuCukcc2
# DATA sUssvwIaP5UytjTEEwPXSnm6kFJxU/aRjUQZJimkIscBaezICFcUZAvdME8RZqdlNVkzn7BlZS07X2zml9Daf/KkYhg6iyPAedNT
# DATA m6Dz/53/6uwPZ9+c/Y+zLxUj58uzP9P/vzj/rXf2z2Da0A8/p39/u4rO+a/0w1d001e4n+E3fz7/zdmXHn35nYHofE2BymX+CtDO
# DATA L89/U/HO/46eo2dwG+g539Cb/sgYn3+gH4Sp88ezr85/rSPzF7rlDwLqAWzHsXRegNkMOmUcX6IOp09/FgXR7KMooXDSeKBNsJr3
# DATA zqP5RMbnCfeIkfQN2TieU28xsbwRunPEKuI8yn0G+VwomUzU+EQv1TK/W6E6WE5U4amW4tA6xfmN7kFuG6yzrmRuDq+TVx1zK0y6
# DATA /HL5gYnoTZu735fvPKJfM2GHxzU1rCdqcysGUwfY2bHYrh+xg7X3iK1PFE4ldzGy8Yvcg0Mmi6KCYTqm8YTzkeX2swVmqqXdyhqp
# DATA iSDMoZR4scLXubj6bXZormlZzwqzc3EyHGfHWQI3YQlo4M4VDYBXxLl5a4P/jYz9Ow39lx35b2fgl+q5mg85g+f5a103AeOxcoBR
# DATA PMVXr0nvKsiDXjedq5VEVXiUZyleqsA3kWRNpvKm4ikJbC8dny7GUw5FDphwBu2K4FFFli9EUkc8YbzMEiu1UElfILcXyj8rx+RG
# DATA 4XGCUUGxZnSM8QKBm/BwSg9qi0GdqzvM7QUhFsH3AzPiJJwtbLfYIJk7xo5j7DjGzk0ydnYdVXaa5uxqJd+yyX8Vi/86DH5H23G0
# DATA HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbSd54m2E7TCq9J2
# DATA OqPWaPAC0XZW1553Yu5w7qrcw65Mj9/VbhcU0lrNUq43290iNyeKuiMFNsLhRoregANttFkGZMChBhIMS2X4zXYR4tOgDF+DRuo0
# DATA vWZQ90C38Vu9id+te0G7RO1p+61Wt79Kymk2vKbf+5Hfa46b3eMgaE39ju/Vf+TXG+Nm57jhF6MwCIbNfn9NIlrdep4IP+iZRDSK
# DATA AQS9YNhaJfZQxnrNTjBWuWjRc8wDK/Sc9hXoOVxjLXoOVf4CPafV7IZXoee0htHIz+k57aDtd4aGnjPo9kfDXk7Pabdbfvfm6Tmq
# DATA jle5GptxoSEEHT3cFm5a56hq8DhS6R2fVLpsSRXWmFqD8eHOpJ3y25SD23ZtiYmh7sLRguvB7dghruJ21ESza4xVlPEh7+QYh8Pk
# DATA 5KDuwbtR93RJFgA93K5XX6Hd7sY078j6SSHXSzcV1spkOC/BcA437AdYHa0UJWmdp1bWbbeErLoaNbTphpLXjKaJ38WuVNVnbKb4
# DATA FEr7AhuxkHl2YarE6MkLrBBH2XGUHUfZcZQdR9lxlB1H2XGUHUfZcZQdR9lxlJ1Xi7ITj8R+w7oHavxj+5vUnbtqxFQDl/xW4bq4
# DATA f/jEwvQ8lnxDZtzlYHDqyATzOj0B/M5nr72++g5VqQ/1gKJesnpjfos6oEF3sZ17qCBBH+IYl7R8NuUnp3w6R7+1HKWa9+/UGXjr
# DATA UBofPENZU4UyUajqG+iH724b8a8pK4zNbJLKi1O1xaNFnmbqHT977X3r5J1JBnWXKgUy0S2d83FH0N0R9J2PoBcPhLmz6O4s+uqp
# DATA wY16m8/DGfVSHS+0Fluchj1/LECLypzlailK+DYeRmFWQLfwiWgoW4JcxCNNRt2ZnBPWSiq8la50WnbXM+icBNZnxFjO4nxKEpRe
# DATA BRfqXPT4+iy7iPitOQyqdlmt6tcr2xVVkD8pNXglHK5/zPXMzRXebgv5z4jDMdGLMyurN6u8G4OYpdHlc1Hj3brDdJ/2UysK7bAo
# DATA cbgTHZrcx+KumwTdVZfKYX1Pfd58txyvZ5U7/rT5Tu5zlczsINp8n/TbnH7+tEVUXg6aajl3sUNtNXcMMVu03As1Af5zW9Y1/wXe
# DATA eu7q9DxAPuk8L+dZSWyT3fqmFxCrmmteuuTc+Jd/+o8mHeWIW/k/Z4lS9DmTcJ7rr6qlRN6Tli4hkQAbLWEphhmU4FmLGmqlMdVC
# DATA hjKF8znVSdbXpY4ZrY8msbOFHP+HHusC+kdah5a1qnnxQ4vMnlDlVofFlc/Lbpn5yWfdNPKD1cZxhssqKSZn9NFLusC+YK4pdK8F
# DATA Aiirtl6qiPKKetkC+vv/vrmAdKWX4nkPxUAVOdMF9MlJQm00pY7N06f8MmWCUJ+0nMETSUPSvOa9R6M8jJxpciyCFJQGFhyAsMFR
# DATA xN0qCkj2D6tyirS6hSqtpy8Vk4JbKxfTLVy2WP7xv24uFtXFSKmIHOggSWkyYlrOTE2E5TJPc/qs6cq6yvLJm4doWEMxHUTBd0R9
# DATA eHKiiqhoR7I0O5vFhXHQuhwvYEQ/fSnZKbq1gsr75Uv3cL/dXFK6j5ei+jRMpx7v7sq7uBNcEzjO8Bha2FQyR1QwvH6Bvi6S4X42
# DATA FCmNiNVjoTMdzQDBkRJQs4F+xOSOeCGaHNgda//M1ImnL588GbdWOk8zAv0//7z7CPQWBtkolSHB0gGfsl1N8UofKkubm1Q4YfXy
# DATA 0JsuafyZhCn2yc0hn4yM9n4kxqMaYMhEAsNAmg1K/OlLohDdF6Gp/Kddm8qDZLTw+qj2IUon79Ywxvcpi6bQsoFmzIBGHkwOWBE6
# DATA HP40xP4cVeMzFFbK9ng8jSc4b4CcgkoFWeqfL2NRq4EKIgurSAFqRehraCqFZFypgIpGoHg0bSPQXJHsvvdhon2PWlOIZx/KJ5ik
# DATA QmXEAJ1wJ64LVgn/PA076NUQd3FwbudKu4IrzXnOXhHP2WV53c+FumNh/+V2bLfMuWkgXWCrJlmUR+zU2kjufk5VIF8g0bSLtKHt
# DATA fY83QfFebSXXzvJeKyO6iei9mnJ1m1HHFucLJkE1zzeS2OxMqojvSNQgTxLjuMidTIrapxzCU0C5jcxfXtAVb5kJvhSygBQMdkZI
# DATA ErKyFvaaWqP0ublO5nqaV9IC/xCertkRoIECGBfdHiMFbikLavCN0sw6MHKiMKtzUVFbSdRjnwlZrAspLcx7YH172IgLvc3jQn2Q
# DATA zWySWbxdFZqos7zBi3ahzi3kcO1VMh7tIJz56MzHnc1Hu665dVi3DvuUVuNGI/Vm1mE/EO6nrRSdEw+fDaniNijhvPcH1YuPDRaW
# DATA OdVPOV5b3bqyXpgvJOXLY5vWFu3lDXu1ZtP9JUd7aSlh01MF92/Bp73pibKbsuxm3fRc2XtW9gpuXDktlAJvskJMUZ2G8ZDrgyw0
# DATA ffcNLV+pikXdC3657DkVlrg6Z6pJ5+VFcBwy1/w926LyNPeeOnXbphKXmX71DhRx3lQwPS00oBcXIY6FpgWTUOfo6TNlqSYT+y3R
# DATA XI8nMuNkEzzSMykDkaT2Y1arlmwqUGj0DJ57W3ck6Fvs4dlTAiE8ATAmu3rqU1ji0vfIuuNQXMu8r5xiAuFuLNCoJ+4kqwWXzxvX
# DATA O43zupbvLQTHU/dRVNKlEr6YAf7yWMkWHJClkJJpgQ34HxXE75uzP9O/fzr7Chi+rzx8YyzfN2D9/fnsS0D5VumA//3sL0z8+726
# DATA +6uzrz0GBf7u7I/n/9fZH86+OP8lPftHFejXCiH49fmvcI1+++b85x59AZFQQIAgEyIO8hyAhcwN/IuDAb4IVn+h7x5FJ2Q78CR6
# DATA HkK6VkEA0KtPR5CP6EOyS2NAqOPDqux9hdVN+sw8UN1zX3daus9ezvk1aEIcHhkZA/GfRIvlfCsC8D6kLrzhMsNmF2rPDgBYsPd1
# DATA L3Hb/L/VYrk5+h9bWExYyW8t1Lcyz/xOdBrN44isDX3/O+qCB5UhILST9JoxgKwexkjo5YLHf3VGi5qYIwHuWoTXjwKkvgaL4NTm
# DATA Z/EInQ7D4BnijO1yafIIGjoRn10WUx4GK2ohdW6DBbYwLFn6X37M1OYTvfdEVzRxqZIlzowbTOPio9kKFnD3arnZ1llpeM8KDrh7
# DATA Yhwk0FkI12chaDTglQyDV8MJeGtGwQ3YBDuZBJe2CG7XIJAqWs4OYwY8N63qJpCAVqrV8teGKGq4GLsvHp56R2k4XIYK+pflqw+Q
# DATA MSyusTFqsLgocSqbPrE0f8yuJ6y1sSxiNo8GGPmNKbYTHNCM66zMTQnOZB8dZeAI+DKugNVkVEXl5H6W6lDNg4otjs+GYjnAR8cE
# DATA PBUHxVZD8ucpXcp4LVWVtjLfZJGQI8s3muyreR9GAMjJBdm092AJMyRNlkdjbzmjYlrIGXZ+ceYwgg4j6DCCN4gR3HkY2mmSdFmD
# DATA +lbnCFeZIlznDMFRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V
# DATA 0FEFHVXwuaEKRp1oOPKvSBX0u0HUDF8gqmB5BXonpmARntdrWvC8Tt3A8zrFfB0OouZwtIa+1w5s+l4zp++1exvzNi+YqV/veoHf
# DATA 8Xy/6XU7Xq9V9VuB5zd9Ki+6GnS8breE5eu0e91+dx2WrxBl3oe5Gl96oYU89Dsmvq0iYLIetQedNc8HQZA/36jnyMTubs835JUq
# DATA v1pBnl+7Pd9sWfFvWPm94/tbXQv52Gx0Lvt+v22Xt5/Hv7Fj/O36ImXLjzd3e7zdsZNvwx53zH55RCW/3bvs+4u5V9/h9ZeBREoj
# DATA 0ZBI6cssSOSgEw47fhESaR4xkMig3ui3egVIZNBvdtqtHBI5qA/rw5GBRDYH7W63mUMiR/6w3R3dOCRyhv68mj08zdc55AjlcXQN
# DATA 6w6B5erQNhfbD+a12iIsmD7yMprNYFq/Zg+LynA7mBq0i4r2vRWKfae2cnYjVhYiqhc9FBdRSlDfo7Lk8a65VmtbVEPPzhZ1m6d3
# DATA tRTzRs9asU++4GgtAR237FBQ+xEkHdWMfphGBxC93ExpNPlQKSV3i+lXLuTK1vJiZ4opMrEHV6qJmE/BLjnFITgKpKNAOgqko0A6
# DATA CqSjQDoKpKNAOgqko0A6CqSjQL5iFMhViOM0PLoLU496dZwxoyTfka/6JAsyQSEXP7AVBdCqXqenqS68iw2Re/7+65+99n/+qcbE
# DATA w/trdQb4mT0JP5zLYQO8kYLZN+EECOd/fyHhvIUWz8eXpuFsOQpZp19Odcl5RGrOczn6hkNVoSAXokd0Ix/+JHMgo6GtQEgsnNFx
# DATA p+/d6fsLTt+vOcLlzuK7s/hPcxZ/ox7njZ7RF0XEhA8i58e9ZVj5rtHnfPbyMbeh1SmjHWRUTRRGfEBWWZ170+m+oiTqFjpjB0gu
# DATA 6KeDMN2auWAULTutopLkNJ7JulddqU7yKpDSm8R+G/51M0/RDMp2VblsvK1ATNTtayb2QWtd5AMr6t1CxOu11uaom/Hejrq+qOrR
# DATA 3jA6SiOaql+QAisskwL7mklBe232N+zc94Mtmb9RoVO3EtRo6SBeVHVOa8RlHiLdmUpr1kfcC2Yf5k2L9U2GXhXjyHr/NG/k9g0s
# DATA si/y+VLcUbaQrkSeFDyjqRJ5GHxz/1RQjoV+SesOsH6FDo36ETIClYGI+d5czIZhjLkfPwYNYZbUOAlPZeCR4uSxP9PCGkfLkEac
# DATA RRSxNLgStvicOjgyv3C0XomCrInRDgKeL9+B9dKo6CxrZ1lfYFmXjCZnVTurumBVb2YrPU/KV8VWEJr8MuJXPwR/z6gdYRU71zpi
# DATA PRm4xCtGv0nQxdE0zuYsQeN9YugqbLyzbk4Ez9xJxGTWiqf3bGBUiuZYxk/pEdSfskVdJDiuiF2Z+2jofzdW0kfjJI1/lhjJG6Xg
# DATA H3pZOAJfJ0rJKGIJJlMq2TzJFdJZoohFo9QsIgqzUx55x8k0gigPzybI7qsIJ0OkeHAvjdY0sMYwIbizyii3sIqg1MCxVWHDlKFg
# DATA 2wwjHff3IcxT7ACxdUKp9oAHmXeIxiZazkI2bKhe1bw341mCOkTPaMyuNgRm0aMFG5K8pIIMUv1oksFtpXpYZQJJFZjyyyxQ6Dpj
# DATA Ym3a/sYGI0ySI53Cj3GiWcpNqlVhzhZjQRbqH3EuVmS4CyLhNTlVavnc42cPpabl44beFCnyrxnrv44g1c6J0IqkDD1lXJjHZ8GA
# DATA 20b2LrJtifpI5LykVUSnSjILI/V8yl2YpFFUwUR+tp+XBzsAc+M0XBjBsHw8orygCktplAmn0lOiLMMu1wn2l3BVxhGa1K7Qpxl8
# DATA 4xybRxTAgozDeAgabM17O+EmieHPKJNBBE4ZjCN0fqkVmxUCEltWF+q+mrj0Q1XYS0tB36ynGCapuSKDxKlc0CL7anJWfJ5/LE69
# DATA 9OJUYVpV5ymQ6s/yvoyJBVJzc6i9ktl/qvf5hjwxCU8VOrxoqmTUE17vOwMeQhnXM4yn0v9c7xuwTfHeh3rsQJrm0WwQT673LbyH
# DATA +x3dgvQSmt2DXu/7WgKwGEVmzxA1PLYlZ9Taiu+6s5zcGIP25ZtfORKtm1rtLhnsJlIv/UTqsujZ50tC2OzpvQmGaTmzr51gukbp
# DATA +GJ+6aRAUBANYHZDFnWFt+B1ny8d5RdRQnRH3IJX2FiujfBcblXyxUw2aiuT43zaW/GOoNCcz2kwC/NCTICx1crMQwc0Bbb1Y0W1
# DATA FZOmbFGalebehJInQdvfIqBbqLVkvRxHFwtJo05Ow7kGOexUBmtK9KM0Yo96QQ07i7JMswpfIdMtJ1z1w4dRWsBb/bezL0GdOv/5
# DATA 2Z8Vg+oPjLn64vzfM67qf3nnfw/M1NnvVuFW/xm0KgZSgWP18/N/9M5+f/6bs7+cfXn+awr0q4p39j/plj/R91/iu3f2jQkN1KzN
# DATA wKtfgmtF/3VMqxeBZEt1GM/D2UAVjCWwQ8Y9yxBB1lbMI8EQrgnIlavOCXMycWnM2GnB/dJIgXmGcilBHyf7a4WRRz1Hxp6urQir
# DATA N7GBFu0kQmfhAFa2ASqdwG3Tq8olcnPsKkhCD0vvXYus4ipmbnybK9zNwKpo1JurTb+opdgknAzDU95HSPXjYeSAVReV27Vzqt5E
# DATA M+ASmEcpzoqyYj2O440YsC2nLz2y3aFlolZBrC14er0fYvlHaTSMI3ijwSigPjVK4e3Kl1NUvxjPyBxaSg5702Um/ZmYYadC9R7E
# DATA 82iFYrVLTd1sz5Sa3rOiV+2SCMetclbAla0Ajam6wuD/Sniebmngv/Zxf6dhf9dR/7YGfamMxdSbQf5ZNZaboE8Vk+iNo8kc1gkZ
# DATA HkAwm8jlCU7Hp4vxFCuykvQDGWoh9I4TLgv+ALQ0skVWR6nDBM3oPTLww2MaJzOdHalIm/HWA6zJpkvWUqT4T2PDBdrOnlK7I+Bh
# DATA irBEHfGZLhmIOfYbBnNxcVgGAeOJeCzIxISoov0PC+YF7wPUmygUCohfwgIKQE3RP9hTATtPr5EvFwnkoQZM6nKAKQeYcoCpmwNM
# DATA XTSO7DSX2d3UvUWr/SpG+/XY7I4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKO
# DATA JOVIUo4k5UhSjiTlSFLPDUmq3Wi2g84VSVKj0ag1HLxAJKniyvNOHCk7U4K21+h0P682q3636/mtZjWoB/TX93z6p9nz6GsxhwZR
# DATA t99orfKgeh0vAPWp4fn17rTqB/RPU30tgaAok+uD/joQlN+TgCn9MQ3cGn3UsNBLjVbbKnrFQRIoURFcFTXDqBWtRLTZ8b2gS8lu
# DATA eX4jmDa6Vb/ZUt9W4hn1+6O18Wys1q96y2u2WuN23f/AbwZes+uPW1ovzmJgtZpBtC7I1RrbblJMG/6Pes1p3QtaVfrH704Deg0V
# DATA Sxefq0GXvqz+UHppt9tuBIMtL70M6khaiEYdSWOzUEf9escPhkXU0Yj/Z6OO6Gs4qhdQRyN/OOr7Oeqo06esCg3qaBgOWr1Wjjrq
# DATA Nlt1v3XjqCPeYVJl08NmCanIFmefPkZCT/5LzdyeDNhMI5kZbIP88MiVv3kH+lDBCdc2TjhZelsFFFlhrzrkeYSVbXP0UPRwVziR
# DATA tjSCcgDeJcbrLY9tH7w3QoisErR9gZ6Y0JvTUyrcDkq1o4q2mD+bk+NIQo4k5EhCjiTkSEKOJORIQo4k5EhCjiTkSEKOJPTKk4RG
# DATA iiPER68owZWTu6PvyKXx6VBWDwH7IeOmkpmfspAtSr56aq6eRtQjq8uaPvQuwmWC0Oh1yqEj5gN9SjGUiydFEJH6/QEFzz9na39+
# DATA bwZRJBgL9D6+73TtfZ8ki3Ai5/v4rg/CxbjGfoO90esnr2evn6qbbc5QfpLFHZV2R6WLR6Wtc03uwLQ7ML1Zyu85OEiNM6mjvJqH
# DATA p16I3wvy5gtWPpH6jBIwEuGoNxX8DNm8ySQ52X7Wdxo/4uPH8zRJRvr8MXTGTUOl8RdbUZZplD2FtjmNiOkpkrKgLEH69HHL+162
# DATA nKNTjYaqRceZIR+RZaPARikNeKidkNObxAss4iQ0echYCVtAJoN0Oe0fQhsmnvF57Mwcqh7B2XvM53c/hQu3oGCSsqa7KGhngyTh
# DATA JwbLOWS25VzzNgXtt2BDpKeyj87jISpP2ggi61ABRJBcqrMoGma6O5P0ZotUzGUqx3EyGfJZV8ScEktzYJYDR6mM8NsRRXlyykLh
# DATA JttM2YmyDsuk41S6VkXnNGAiN0kWSDpd6icnEy+cZAkfDN4qEf4uVW9uOnJsm94apVbhsWBzn61Nzi59c5zpU/QnqIvonlncZ4Lz
# DATA vejHax4rquc9+QAbUiLIo8cTPpmLs/FZzXuL1Zq57noaUIPqQJFHqEhtOMRGIA7LHENUqv7h4iJRd845jvMJDSRGVxDbUXH+3cNR
# DATA GryMmk445dfRQMeloyThB8uFFC621czVaWDRiTfnvXFlEisKF6rFzyBTz3CczCiaP5TwxL/CIZJpOLGzJDbnucN0ejVd8zdFiBpZ
# DATA R43/0sLmaITXrWz+MTIfhTeCc1p6pxsQNM/ZliJ4hKJgQ9TL9QhuQNPcKDOyUTNTbQ/dLMa8G5A4v8/dvrGVlJrE7SmBvzwHufNA
# DATA 3IzCzSiKM4pylXLTCjet2Hn6sHH6cXPTigfIihyHI9HRU4rnXhvwNhCl4kijy+z58vaOLsJi6gdMh2Uu5HSO+lWApPXNWM/ctUe3
# DATA fF9/8fa+fVFk7QdNhAsXc4pnd12cmy0ryr1dCarsb2RCyWSxQyzV7TniVX0vmFQrUbMzs1EkpG6Jmjg96eeCV3KHSOoHTSzNhdyu
# DATA rXUuimiwLaIbQagyf8VoZbW0F5eGKk0tzopiR0az9F3qW6h1eEdmLl7x2t1ve6beelMyqTOv0VT3nMA/TbN8mkhHRyk6Sn5KI7Mw
# DATA /RZuFt/I3RF/VTpsMjM1kNOY1Wrjgenq8MbokayZ6CkDlsEwqUdYJSkzluey+jItYJsJq0yellUITPrzaYnETp0+iLQK2g6U05fH
# DATA 9nb0HWd7b/fmO0P7pTS0L0vZecZCqLwDON8gu2qA2hAaFh0MtQfb6IVKEjZTaJ6pfOoLISvI/71mplFJ6PW6iUYrUrlreUY7iNda
# DATA +6hzCVt8iyBcmYSjiiHosJW1zMbKwCrVU+wUl5JVu8XfGDfuvZvGWLfBLkX2ItIlMOrjR7Bh2Psv57mYdhgXzR2aQGIWGK1bdlGq
# DATA miJkKvqk6iADb+FSJk/RgKFpqeVRNVaLia4d7wdYs0LMyb4rxVxkd82iCsWO1y9MmxCNUb0soxikOE6G7dnWahHLp/LSE84ibokw
# DATA mv2OseVjbbOE6b8c3wdYCVILdHr6HBXFUcPiwh4vmUzMqh/FUcEnsQKBRbDNEaWXrcvXV0a70yIHkeE2AIfHYgf9p7Mvz/549s35
# DATA L86+AvTn7A/nv2GoD+hBv2CGz8/pN9CFfrsKD1p5+OzP578BbugXZ385//nZF2e/px9/zQyiryseffry7OsqPfEVgvb4nm/oHnqH
# DATA oIU2woQodLzlC3oD3eiAQs+/Rf1D6JfxOjH3JooWdlqRBUFcko5W7U5NoyPwl7Wcsyz8q/pqBveURZsLlGnqjbcyhN4ah6JqYEmG
# DATA O46QZV2rLuG2SULryuXmaEK8IWCczM2Nn6oL65lCozjvpt+NF8YTfM00IYEas70gviKL6POqc4R2KbFrpwnd9wS8DhB4dbHsR6bk
# DATA xYMfYw/t1JOd4DXvg4RqwMyAEKkQj6H3DkkPrBGwhgfMslBtdgnxeSKbPlK4D6fMYxRnHRtfAmuESGwZHrS9Sm42Yta0s2eFDtqe
# DATA BAcNciP9ZUZ6zQm64gD/arjObmtwv5Gxfaeh/XIj+80P7FItV3Mg3+h6e63lJkBBecogokUBZKtxXsDjhs2aevOfju/SpJ0POTFO
# DATA RBcgCDAx/858EyyBMW1FbQnlt0zDGaUuM+mW1JrgBTM0nVMXNlvshA2CfbXAQX7kA4U0Sqm3ywf9WJb79cIWgmExOYYYGQJQGklW
# DATA GSTyqQCVK9ZInwDzk4wEXYwXUUX0HiyQ7Jg9HvHIo1b1UGgoJ9RRYM8g2iBvMEiRd9oh6uhBjh7k6EE3SA/abUzZEWp+sc17y8b7
# DATA VWz3pzXdHTvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ix
# DATA g54bdlBUH9VHwRXZQX63MWjVXyB20Oq68078oCOTZN5FWGTNDFvRcFTfxJq598YgTmH/C9gnkIQosE+HRRpY3sD3FWGocHu73rzg
# DATA dovzQ2F7dI9Hv1X9Hv2t07+91vfp+sTv1ela2wv8Jl1rVzu9atAMxs3eBwGARZ3uuNOc+o1Wtdkat9fFpBlsirgCGN05KlSgZuAj
# DATA MvSGadX36seC6NmSjdGo32uvRyTVV6onxbkV1MftZv0DpLrZax0369NmvVlt1ulTGUHUCzv99rqgg8vTgKTOaxqQNB+LBkTJGHQa
# DATA RRqQ32l0mz2bBhTUm93WsEADCrqtRjvMaUD90bA5HBoaUKvR6XejnAY0Gg1G3cFN04CUUbLe8aHTWrK11EiEjWvV7VaIRzdj2Mnv
# DATA LYN/zERp3aRIu9Ew1600a03m/wTM/1ldj2oXI6WNG6ubFtuFE0I5HqbVI0yNwbOoD6OjirX2bn/2gt78UeVbjXqr0+6z22+/sjmk
# DATA 3iWD0lHO5tHgslQibfPCe7hiUlkrcpsXx9VSuPiEqxn9MI0OhmH6cDN7KM/hih31zTZHyeyVOsS2kyMJOZKQIwk5kpAjCTmSkCMJ
# DATA OZKQIwk5kpAjCTmS0CtLElKkn0+sY135ee7iOa4yhke4QXLKm/JI04WwIwDNCHSewbTGMJ+3kikLoK8c8ubjbVhKErWqEAdVkpk6
# DATA vqYFaYsHxaSNykROn7RwZ5zdGefCURt31Nkddb7iUeeN4oM3cwT63Zi1LvgsLbsgy6dn9VHo501u4zb0uNXggqpD9VVJhiOVe4Pp
# DATA RRLN5lnTYeVXjEhzd602d8sWafb9elGmubVF6poHP0i6qN6LL7whtqxRUZZ7coFr/dAbCXemtoR0m5d7Pqa+T+GFuJ68cSdRIoFr
# DATA nmhzdtHY4t3xFmn0kLUiL3ysxS+yzYApDBqWTy4+e0dSs4NQ9Tu6fqLKeqiyL65K9QdRmC0hGo2DtYMwzQWqHyxEko96kiRZyA1y
# DATA rBmyPuERxJ7hjzqhMavm/ZAHt0l0TJUGHSA61akKm5uxgtMkqREeShMyJ2vex7wAIKaRPMB6i0rYj4aTUxQ0FUS8KMhXA6ZVOLYv
# DATA 50i9dIkz3jhyHeKAPTQczXgO/UCy2KjOcuFnNDtbZvNI9A9ZMTucLUcYiFPMpSRAcJGG8WiEK8s+66nHGKcpMMburLP1lAgBJWGx
# DATA s8D1y3LO18lbO/PVMl+dvfpK2KuX1bZ+xpI9vK6dL8Bu17a+T6MRG41sQLIdm+VSFMxRyLZoXN+22M8LoXdxE7LWq/X62qWt12o6
# DATA XVXeOl/01+aYWBTK9olAFuU6l4tas/lzSiaNADV5KYheV/PeFN0gmiWJWE0UzmCifAoRIZF7yTC4MWZUCI5c3WBGkdUVa+FnsuES
# DATA snnIqHtIb9DEkMtVnB9oIRaj6mTc4a+W4kkhZ5wx5IyhUp/qvHnOm1fsOzdaUc9Y0JB5wAAXJ5OJ6OyXgd2qnYRZLuFX894VTjdb
# DATA Sevk+QpafvM0GURD0LhFii5JP19G4st5Gj73/dhAnQ2Nd0EjqGYCTuOFoKZlJPVYy4VjsORGfhQuj2jU/JiGYU0LrHAAYpbIco/C
# DATA O6DDCEcjOMXYVZK7PM04/d4M4/1C+LVLRYuIpv1oCBG0YdRPaUQWKjIPoSwCiB1KW1HWMvrn8oyCAw6pKsAPypqCyjTItHUB5Tj4
# DATA a1JxlirxabIBhpOoH6Y1733YT4gmVVLK3FCBwIYhOhggEfoTEV4bszDeOiFD/phZqoXiks1Avf6cCj4eQedtGmHtLx5shZGPWdWa
# DATA K89sAQ8Oe5FNkj8FlCMZjbwjGrJ0EmWfpDdZUqYOQig2cj0GXj08CU/FMaXjqcow024dzj4eBygYFXPKl0wUuOFfYhXuQyVrCCnM
# DATA lE8WqIprqnMBrLFA/WHeiNenCEQbvc4q1TzSyNgCmXDmg+dC1RCcMi2LzJiEEh+DTMLyT/GEfq5oPxQnIIftDMI0PWXlxvuUZyH7
# DATA 7VRAQpgXeJzm+ByHLMmXZ9KHUcypEj+xUr+ES+4oSYaWu13emlBDo9FwJG2tWIRXg32jLZ+y6iP1Md+9NOwbcbtu2LfY5bE0cKVf
# DATA GM8Ajo+GNwD9fhPMeyUXqraO3ADj+9OSCumNvInh3u+jaUgfQ+OabMvJhJhzvW/jU0CfGkoiVojmYZx6D+EtDldTd5NE8ZdjqmPB
# DATA ZZIwHR7Bt27jZf6Lwsh8w1AX0GG+9M6+Ovvn85+f/2aVJ/Pf6L4/nP1OkC98F5NfQIX55uxP9PELZsl8VfEMX+arsz+efQFczVf4
# DATA qaqf+sqjr1/ooOg2euEvz3+l4DIUj/O/95gx8zuwaUChcVCZFwDTONPMrhVf3DxKgIBWI/dCBKbf0vM18Xsc8bZtDHIKGsbavSwv
# DATA nJO7zMBH0dND4XI23EqZuc+35G92jJnCbM70DLdNmVktl5tjzHACzV3fg5A45fVkVL5vCO1nA/TCft9FGp5eJ1qG2kBGNnYqAuY0
# DATA 04A1xjMxFISDy2wvqmunyphOaBiTGc8n9sTUIfMVT0HkPn7kcb3wPubtAeK2PcL+yHWbyoV9CI12rfSNMptFC9Y0x94PGsOzFYbM
# DATA tpq32U5ZaUPPih+zLfqOHuOG9Kca0jVO5koj+avhk729UfwGBvGdxvAdh/CbHsGlLpaTnW+bfIYt5iaQMuWE5mQZozmRx5xyMwoV
# DATA YgbuN5YbgKdrRkWayWotkmH4GTKsAj1xHKeMi0FhaawMpTzMcBFHxg1RGKuhMrBeAiJzCmuLfbsS4pFsM8M0gT72J+JxO0ojPg8g
# DATA 2a63uinfOo3+kELg7xfySA4x/nOWpJbNUMSMRKmDxThYjIPF3CAs5oIxYzck/IWW7a2a51fiVD+Vce74MI4P4/gwjg/j+DCOD+P4
# DATA MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/z3PBh2p1mv1m/Ih9mNBoFw9ELxIcp
# DATA rznvRIexs6VR9/xWZ9zoNI6DXvP79L2YI/1Op9McrmZnK/D8bp0ytHMcNNvfp+/F56hudvuKy8JlKWUlBXcqHJagoCvR7BXLuNks
# DATA RaQf9TrlAIOgcdUAh/Ve0GmvBNgNrjeGjaZ/vTFsStW5vhjahUJleQ15aBXKJQPcUMpWoVxLDO1CuZYY2oVyLTG0C6UhgV9fS7lk
# DATA gBe3lGuJoV0o1xJDu1CuJYaFQmk1r7elXDLAi1vKtcSwUCjXEcNCoVxHDFuB1ZZ7xVL2G6UQ1YVU5X558G9HjRKKq91rhs21sLR1
# DATA 0LFWq2FBxyT81CDBLCNFh7rCTwtaTxdAq9uzAmj1Lh9AIQm99lMmYbcALsMzExtN88zE3LN4ZmGz3WxERZ7ZiP9n88zoay8aFXhm
# DATA UXcY9oc5z6zTb7dbbcMzG7YHftjNeWbdQTMMbpxnprweakODmQmJM55sSXZQWN4LvUht5mddXqlcs+hfDLnMMfteREZsHFYkJqW9
# DATA KGuCsx2RvMhTDF2t+14cDTN9Wb9LTt9Ok+OjaLelotYui9NWqOVVZ9tnoutI0e0cyER+ZfXQb1iLxOpePyh6YXR15T2W43CYnPBC
# DATA DFbc6p6uc1be9thhwbNiM5vbsJ9OT2JVbtc3M9DsPL3Ao2HlVqlO8mQ5cCA0B0JzIDQHQnMgNAdCcyA0B0JzIDQHQnMgNAdCe7VB
# DATA aI9V7Y6p4O4qlBk+U6IrnCR1EUf3kBFyu6hu3qWOjerMHqpWfLd+GL/BTxzGr7++/xgX+bbDeLR3Es/IuiI77HS+SL4LI/5jQDGm
# DATA P+Jw9h/rFjS/y6A1BoHsNYNes9fuBL32HY7S/nf4j4pC/y5swB/S7L0RSMfr7x8Ok8fyjvIr9vr7h09YNnOv/+P6T+7dpXftH4rk
# DATA Gy58m4N+3T98EpGxrrTgrLgI/40D3FPx2Ke7lfrofEmjnur2nkj0UDnuqp9/msSzPe6tKAfBh0NjeF39KAu0e3thpU/FEb7er5D1
# DATA mFvyKrWT+O5Ga3YSo2AmsV0h70rzoHKjN0naaOaI17KNLzMCHCBHu59jK8FsuDeJ9w8lj4q/86o0TdxVV3zPr+8Xb8AQrOLzFu6t
# DATA yelpqmxPNLLOHP10yipOWWVVWcUcBnbqKk5d5ZLqKhtFsW9AdeVjyHFpBZBJwnofrNllhFeerZDXbdDp2BSgq+IJ8pIRJ+YCLJ16
# DATA KO+R1PeCmuwKkc63gHRtG0fnb4HRsfmCqo8PmH+gKEowOnVPDqPTD60w4toS1CMxkTaz5HhMegfe9Yvu9EUNmCzQi25khd1PTqIJ
# DATA daIX3BvU1b0zMoFL9+6OruPqjVbOJfrCUuv+RjMaZDzKyHqIhkZqz8jrkJFlZHHEfC9L7TBJbjfZHhax8bJkmYLlOxKcCvS3xWqE
# DATA hkPOpxOvBRmJMyXjQ0k89dSheyMWQ+9cUYsZN+7Z+j+UpgYVzEQXCltkdm5aG3VVCUx2os29DIoh+VjijE5ndK4anbl14axOZ3Vm
# DATA F9qTz0zr7wGjhjiS7OIGchTV3xidBkg2jQdpYkngLdlCVfp3IbWu2QB0i1XtOzMo5i1KDYYaUsJScoNkOo3SQazHQLZc0wgrLdi4
# DATA sLP2H6dsfu+BeKv6p/CZRdhlgmHUAJSE/UuDKfZSrNHfUufdVk1U5Z5FTeRPyjhVNof+MTeAzBU++Ax0WsThqPjJcoMIDurIr7U9
# DATA jc8XnCD1uWh5WneYjtJ+asWwg9MUbQGsKbkv3mYHauP8bTbgNt01SEDcoOZyzDe/lX/d/AxXItz9ET5ssS5lYNYWnrhQbZMEg8QW
# DATA 865QwtjzIQ1aHe3MkQ7UKRl2B3usZXVH5aWdFyUcEO+GMe1cnMFcm9Il3x78y8//77ZJRTnaKmeVKaakKqmCpItTMcbIvuORCUwe
# DATA bUnyIETTvirsriHPF737wyGk8ehpYQEN0Nio9vNEkfnJYK/gQTb/ZHRkIoomJsM2pbfUvDfDWU4FnA1lUio/vQsiDF7SqNMgayhB
# DATA +tjJlfK1VHuukL3NzdlbqIuSy7CXxYanhCzCic7n+8yToUFiXpFc0xNrzrUQmwAW8TSyoWzzyZJnzzS/XIpFzwQk5dH37sdT5NWI
# DATA rLVsDFgVm9645Af4Ok8yNtFr3juAL+I1wzgbLDMUEIcki5LXkcumvV02fzfnrWq5OlfR41PXu8AHnadvY29P6DX+zz81wEoaUp5g
# DATA 8WAGnvkJ8EFUt5aUd1QWMsXPPJ8KtAenhay/DCKag9S8j6jLpqn3fanYUn1BgGJOEp9X9ODeOPTetO/AGUJxl/BMWm3yqnnfp68R
# DATA V2Qq/2uryFfO4u09RCGbP6WBliYZFESq89iYsyNq+FXRc8pZYNAOpPqFyjSXPJQVn0z6ArkblRR+mlChxzEhlAc/hHYpTgZmrFsa
# DATA mkDCmYZSVeRl9BuWUCRunOlHsUiegkd2HCfUQtTDofQ8z0fn0b5U5/FvlzGvfOrBWxeCZDDVXxrjULG5ArINpA0jmQ4h271sEs8p
# DATA P7lxcN8C0BlPb/qsb6o9glBQxaguSqzcNXlH0UKKjrMQC4lZMo1w4WgZcceBp+OZTFSoX1pcS/dx84PfWzwugYkUm6ptukVxayxO
# DATA EumQJWvRG2eC0BSh5ChOaXQ7QSi6HrOMbWwUfmm6jqafqpZPtiCrOuOd1DXhtCL11sdqckdh44lpgoVcnjugp2DshHQvsFnLmVs0
# DATA V2TZ2DZXzBXJrHvUwNQCrxYSlvFbTEXLfKXmNuaGJ4VSu4j19DK4XPLZlnO5OJfLGoKC87K8/F6WjQ6U54qoUDgqsDpSTmzWgjeJ
# DATA FzjizEoojMQExVKNJuyCyR/k8yScsc8awfA8a5VfxE+yDn7IqiQffbn3BnWk5famj74Xjtd15SyfdS5fLoQT6Q7LOImVI+nSfgcJ
# DATA aoe87XQ20FFRKo+5380Ws+fyWAPmsJ7jL5wetRIzDu49YJvcVBFAkMPZqVm1+n5yAhzyqao73/X4whLeKbKqvuu9RfdH1JnCGIIR
# DATA klvC38UkLJ5yhZtlJzJ7WGCjncdLx6y/Hyuiq2ZTAUYbkm0GPi60y8jw6iePohVeVLG2vBszMJMdkJQdy8GCEinF/iosOdmcy4R5
# DATA 3Dbl8j8zlvJ/ADl5/lsPRMqz3599ffbFKuGydOdfcuAl7q9457+ga1/Rf785+9o7//X5L8++xBO49yvc/kdBYNLt35z9/vw/AF7p
# DATA 0Yef021/klsdx/IFMNm8jP3+qTqAaPp6JJon59wT1DzZLe9lS5mwyoZ85tbKg9yAMWbwYMIegZlMo0aYsHKDg58MSwtj3jy/hWL5
# DATA psiACSrDISyLJpw0+tsGWJaK5ObolbADjq3uXlU8pqDLT+UnVBU0T3ysqiSq4AwesWsFWvJuiXGYsb8G6B/lKFcWjINa7lqC1463
# DATA vA+79EhsFcOOrnC3OYSDTQOCTJ8lhvbb8WgUD7AhH9uWZcdNpBng+tZZRGHQz6m4+1eIljvVwc1mSbF1PSuu5U6JcIBLN9Y/xViv
# DATA 8ZaXH+JfEQ/NLQ3v1z267zS4X3psv7WhXaplIRtyzOUzazc3AbkspBFT8rCYMGwrlQQg2Ol8IUPhPEXXA07dOOzHvPC3yHSp0RNH
# DATA R1hgeUjVIJN5PNVjtcyN6baMzGYEnsRUIbH8JYS/DIp/6a6IS2SjYQJi2kDxn1BXjzNsWANRaEcde972uoKVVDWpWjAWZEGIY8kS
# DATA KQgFeYgMwMpnVp1HaZWtOiqB5ZR72UPLTMCNiHKVDLaNZoNjYDoGpmNg3ggDc+cBZqeZzCXs4dsz7a9i2V+TYe/gmA6O6eCYDo7p
# DATA 4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo753MAxg3YjYubWFeGYvaj3
# DATA AsExCyvPO5ExLdSb38opi40iVaxTyvCG/C45XkSWNbvtemdNhgO72Q7Gzea02mx6fncsqDMLPFamkeXgscYK9K1uxbWEVFuJa729
# DATA Ka79frvbClfiGgQU1277uuLas+La6W6Nq4LZrY1rs9/lX4txbfh1L6D6ez1xbXSvpQ50Bt126K/EtVm/zjrQ7FxLHRh2wmF7tb42
# DATA e9dZB1rta6kDnXa33+mvxLXVffo6YAVHoTXbnXG7UT/229/vlvC41KEOWleD2FFfqiF20i1bELtmm7qN7g4Qu+GoVYTYNaPmsJ5D
# DATA 7FqddqvTMhC7QXcQ9Qc5xK7Ra3U7wY1D7LCHqiqrG3p0bVr8OotW12WbM7//cly6stO1kS+1tsXpyiHzOZXdfKntbb5UPSfMA11d
# DATA lVG+Zj3NwERBTbl6rRU6HHxqWHCS/zT4d8OFi2dUp7yukOGkMjSLdDpVa9ZR9q5GjJMVA7WIu7YIjGuv7C/YCJuzSmCLbbpaYxxf
# DATA zvHlHF/O8eUcX87x5RxfzvHlHF/O8eUcX87x5RxfzvDlWL1RoeTY50mJ/o585cN79PWO/lVAc2xsfvbaO+r439CchMRhPSaZMZNt
# DATA EMWTPQ6dyWqin5nVPqP/ze4vcJsEq35QADb1jeEwOtwhTbg9PsGzJvA75VA4GOvRjEcEgztzOojuoP3mg/bugP1LfMD+suqHz83B
# DATA +9yxtV0NkUXe+DTrjEYosiwgsDym79u0EJ/tOf0X7MTqReo7uaPyJrQRSyoE1yyMWNZxuEAV8b4C9LAYAuUqtaGMAzPSQh8t4Y3h
# DATA HQze0RJQsH7EbLDQUv2G7gFN1jFOe+/S1QQi91r9UGSiGNGg1BWo3iZawFlOlHNVV+INyH4+U45z6H2pEHgadS56NJdphVKZLqse
# DATA blVSKjU5eK9t+AWrbj9IaKQbq9PqsvlVi29/GEJu0cj0p9FJmOJAvRIUPQkncjQ/VBXUmyAhzElgB3ocpiJMIZEvnodehCyS+oPl
# DATA Akkyh6DLGuWrcdS5bKgNMykJpthwB4FNGB6+DKPQSKmHGas0KGGtkPE0fFo9XmyJ3nug3lwicuhFTMQsIQ1dkSCAmVHhh6kCGCST
# DATA TPEYDU2Hg0kfeifohTi+OG2/JZIfyWvWZOIrdGLdDsXZyM5GLtvIpVrlZKmcLNVVrOON1viNyVV9L+Y2wEZCqISetIIN5dhDS7vq
# DATA ljURbwMOLM4dhuDAekwj5BxUKrfjgfVjpncyF3LCbbN+ESK4URdDdgdKsHidgOw1Dia+xC4hvPyCCOvnTYTNhTzCrfURljiqKPvl
# DATA KNc3x5ldY3bVRdXa4xffEc/U/oXZXKQw6+95nIO1cW5dNcraYUY3fLDe53ZBjPMATKStS1Zer422FWtVfXSkW4U4bwQiv7mMJ0Nr
# DATA RENv8eJykT+QYVhG93DOR294AVvPpQw4mXsvPiWi1KEk+WN6KAKP6743ik7Ypc2O44XxqEIHa42Q/FHKQnVm/J9Fx5p5ZSTAfqj6
# DATA dd0VArgWAouO/bNskNe8f0eWwpDnPdQzWt0smf1D7AwS1TXNyBRXtnSk3FgoRfJmNj0wpaNphnDg4sWmKdtLbITbo6szwp0RvuKo
# DATA XrG2nB3u7PBtZvXzIxurBjvdDNgHhrZgq8ADt0NjlWmFx/lQpyRKK7mKKQ81RuAUep3YW4VRB4HPRbITw6tyIqLNjQSIki1jwczI
# DATA YZBNmqtXpifnL+WGDQn8PiqFnkXQ6Dx0/ORd+Mkz9qHiCfGmbr5T3MkyhcCnLeRk7Va0nH+g2D7/BOU8Ny6JkfxkM0JS56tAJO8X
# DATA PPdwaVOVAZQ2jVBMJWBqGh1Rjhn/LPthBYlF/xlh7qzUZ6lGZnwj3TZbxDRhlhUInivXvLfCND2FKGsyK7rH05CZjWy1LtJT5SVm
# DATA UVbsgUwlYvCZJzPtJ1eTB7uR5qs/uonkq0tmD6SM8luSb/JXqyjSBd7syw0zBOPUzESeihWaV+VLFvM7m4tZNwpVzMbpny/JyF4L
# DATA 7jF0Qb+PLhZGTihM1pQsdr3KkVnIetECEKVoXnqRwLNJcjI5FUnolJWN0bliLDJLPVTmvIEPHeTY9IpPVYTbk3ZrhVjoZS5Zjh9v
# DATA gRnn/ZVusYIeURLJaQQWKw05s6ESA+eS1CSwvJ0O45BmgVM2UEfR4pTG0yXyOFbOq1C3ZIUbM5N5XnSh0TXno2VmCYcG30eYkbLP
# DATA jT1gWCCMBbj21G1zW0JvrVyv3Ac/2LkPpgq7oFuErht5M2ZvZw9PV/pfzbaRYoVVI0LTbGSMo2mczVn72nufe8yQvQSTMD2CrDSU
# DATA GWeZ5tSfJKn0r9JWpHMdhUAkwy1wLe1yfaqe/271+zt3q2rsIvsK8vpIaqgGqmGoCdamScq6N7rLRBuLYofC28Kn4yCOg6JUfOv4
# DATA aAZXj0xEtYUJxwpLg8PoTOcp69VTryvFzPG4jra3Q8JeiK717Ut1rVrWHYbJMA1P0EB4d8IkHlkL1cq5pu9Q1kMUYlsoZQ5k78Xe
# DATA se0ZzGi4sLTJM1guah67/MxattoeMEjDOfKcj4Tq/RTaQ/Z05bo1hVcq0dsFeD+Vh/bl9ynmCMxBRKN9PMiKCMwvz39+9sXZn86+
# DATA Ov81ff4FeJbAVv6J/vwCHMvzn+uL67CY35z9kf7/5dnX5//AuMvzv2Mo5p8EiclB/56u/Jr5mV8zOdM7/9X53wOgef4rpmNS2Gd/
# DATA PP9HCuJX9Pe39E4KATf9gn74A/1M9/wzveSrsz+f/8ZhMl8IRym2paG7Ut2iqnkcdHYgvigewvo0Pajw9yNsdocXdQBknQK1HIfs
# DATA uQrNFMH4XEMPXrjBuOa982g+gflCnSkKC7FWBk2uDryVn/nWhMYvaYmInyNo2j5U3WfcNkFzpVBujqHJldLcha2FvKauPIArxE2q
# DATA 2nFibn/AXz2Idi0nEAm7ToBmnElU4D2UnY0RzvyG4AedRgtHz9yl7G6AnMmrpLxaHk8x1UVopgKo7mkR8RG1AeoxH+v3PojCbKmW
# DATA bynHloBCMV0BJUd9pfE9Z8wZ8hbxJFIu65T95WQgDZeTVZzmblVys6VTbmvPiqi5WzocUtPZBTdhF2jW5lXMgVdiOfXWTIHrtwR2
# DATA MgQuZQfcnhkg9bKUCzZu83lrUzfB4SwlnxMNNzWzC01kyvBNrVCcZ84xnBgTxeO0D9JwbvHSs1H+ywF8+m3IDPHlaHxl9jBaDOD3
# DATA 3hXHmY/4lsVAkcvy4X8qdsIQ+/KgGgWFGoqvJyHyyZqCPcAL3xS3ZFhVfny08yzjfWQe7+ESW0Q7FWlUQnLFH6VonbxRgt1WoVlG
# DATA c+hNh9506M0bQW/uNNbsNAW6jNF8m1OAq8wArmsC4NCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw69
# DATA 6dCbDr3p0JsOvenQmw696dCbDr3p0JsOvfncoDcbreawHVwVvdkedUbdFwi9WVp83gm+SaHHNCx6A5EZ63FeDk6FbtjLMzZoig4V
# DATA /xK0i/zC3nAUdVdzGUzAoDH2g9bn1a7X8r3A9/x6j/80WtVu0yP7uNprVFvVTq/qB20v6FU7ged36EujWBjtbrfVi+QdxTgHzSCP
# DATA M70vj3M7yKMsZFGrYrQa7WgVZdnpeX6rM+52J1W/TtHrfN6jyLYb1YB+aHervt+tdqqtVtVv9kq1xY8GkV9iHvbb4SgM1jEPm+uS
# DATA 0pTYD1SMOxaEsWklpVjHh93BoL+GyOh3vUbQ/bzbrjYpJY2eV6c0dT0/qH9epbJoNCmFvldCK4ZRp9leG7dWt5PHjQK2srln1Yx6
# DATA kRbpNwfN9hVIjdz0NKlRWrFFaqS4DHq7kBoLV0BqDKJuNLRIjWF72BnmpMbOMBiGFqnRbw26jRsnNWJve3WbSUMDruXjEtvYPKQt
# DATA GRtKiFSO/NKMuNn9tod/ydTw2NzIg9DjrbXEKL+yObmj1z+w4rd2LsEhQlDY9vnXcTfPQbRpemgZ4AVXqCr3y4EVxf2VQyFLedKi
# DATA PKF/G/JvYbWq2TLYyE7r22sJj2IsUpplzpcvl1oLWOsRjhtRjRdWBm1Prq8FkimBXXw7h1MqGp7FliZDjgPpOJCOA+k4kI4D6TiQ
# DATA jgPpOJCOA+k4kI4D6TiQjgM5CtG47/pV4SnKpmPAH8ma0cjHB/q8+0mk/JmMe9xTuEhcwBMSFKrqu9jot+czknEwFfZjIRA1V7VC
# DATA kSsXByMishBPVsfp5ai9N4+jQaRPI+KMHPyHfZRHkQOZn7xxp8Pd6fCdT4eXj2i5g+LuoPh23e3n5gD5g/iRNKEKjU+zUyz5x3LI
# DATA 0gbfmCOPlmgqmsxEDnXi2Yerp55xFJR7XnV2eoRQ5GRmFk6iS8pnG1VLcT1yE6ebkylco/Y5b6ecvYtyNu8o4aqID5vvQ3+J235E
# DATA f7doZtOguBD84Ufy8UXQyzZ5cEmRyDc3i0Sq3BSByDdxinOEY90YlHI9SGyW8chyp6qC8+A4nQ8uK015TiHgOYlHcoI5WTAFIuOh
# DATA CS4oBOONIqpHExhENGFJ5OAxp0QTUZ5GO/OqWfLWjlnyjtYEpTFZZ8ib4QS6AqzVy9GlxsQXzJlrWcJhWVFvBO8yPY2c4gUSnteB
# DATA OUdDM/5QEyTrL5aT+Qhsdh0Zo9vBJfPlR5vzRVqUqinLIVsmeR2ZhSnNSb0ZzWk99DMMBoV0KxYkIDOQw39g0XCVimZCKIMgQcYc
# DATA Efo8R39/fKqNm2dYR/7NjnXko2TJGhY/XR7l+aHVpudafTqZjrBpBJgG6gTmmF6hQTDNSGGMhmRq0GA2oIybjJMlTrzVvE8wIWBt
# DATA BVZKELvuaBL+zAh1PKX6bN4VXjJ/PtqiPas7Vckhml97c31JcuijNDlGHaA00+zmKDLoWN4kR5UmXA6gwnF/5i1nSK7uYSAQzEBU
# DATA YJkmUN6HVDQvLj/DdvPxju2GK7VSbrGQtazIME2WUB9fQqliIsZDymdk4e8HFWs41D0LlJZj6UrZLLOFeEOpLtRfl/PjdqVsXxWF
# DATA htzMdpNwNwnfeRLuZtwv+Yx742T6uZZs430sZkeLUFl5V8u9N6hBl0tY779Ecs22uq5spbQ2h8qFcMLfyvJnK/sipcIMEuwckped
# DATA zgY6Juqk8b0frGyr1JP8VXU56zH+wqkpjO+TAtkL8AlmvbDi2JCqJ03gtX8hf4iPTvNw85zq1r1Ick47Ctt6ZkuVVN+C4WA2UG0x
# DATA 1P7ln/6TNiP4leNApOzEgvQW0WTCUxcFmhBFr+/B/sy8I7GywgXTIoZQYaMZy3g57eviCr10fLoYT5U1ywYrzw2OYvlZLD8WI8O0
# DATA GaJmluaXx3seIdKlpJErlFtplAvOGTVAvQItmKEcXXESpiuausUCZaiRMRyZWPUKympZwTirzVltO1ttK/XNrZ24tZMrWGwbjcOb
# DATA FN9lQNNI6eizmDvymhfiCxq8z14QfpshgHN+nr3WsrJ0IrYi25bDwrXCmoYs9dPld6n/5bPffMXbG0wvAt3rR013Zi6YFQY5IFJG
# DATA xvtF0L2NjK/X/M3rL2pDgR1ZubRLbM3DJrr5FRPf3nVGV228oN8/0Pq/i2RRqBJ7374o2iYQE+38ygXZXLfi3dgabWW+mgUz2ZXK
# DATA q1xS5SPe4mGaQmYholDD7r0hZ4JVnNX2ZNupll+S/icWVNWcxm5lxN6RIJ4S/iS2FaO08i7AVqX+YWb2l6DxGeP2A3GmGqVmRg6f
# DATA jONJlPcTMdRqF9irk7LkrVnpoNYc5eLNLA+sVjhh4srGFdn6RqZuqQronVbeUKH6TG+gtYPRpVp9D6VqOaX7sT04D4f1pAfhDNrB
# DATA c0pAjHOKYTrnhV72HANFDnflyTgSAz7vuJAyCE1zv8YLW2R01DwFs0MKjdB0tpxT16P0g4vi0nc4318V69mCcPEcnecQNofrn5jB
# DATA 9eX5L4V3BXLWN2f/rNBcgHOBxfXFKoHrv9FtXwHQJWits/9phUOfGLD1R7pHQ7b+fP6bs/9lKF1nX9CNX/G7fn/+H5jQhZMO3tnv
# DATA zr48+59UacKJA269EPY/G/fW1g2gAtMEeNcp+gmub8aOYVJrBnly6pJYvY96xpmofp+wbrgsXWjZ7Yrihh6hsY/DPvopma2LGjbX
# DATA GYid9yPMELbBtj6lu0yEHGqrYPrnPcNt07ZKpXJzrC2hfRv+E2/Jtt5q3fnTjIpb31isYNeJ2AoFbKXhCmqBUBLj8FoXFNe1o7U+
# DATA CsnoxM8U61a9Uq/XedSgDKAuquZ9RAOIsXqYYMGTrnE4x1qw3vm/CPuHiKTgqDMDoUBxRY9oIMDZgjJD68LqttlMKTaeZwXPujAB
# DATA jpvlhvfrHt41M+vyo/qr4cy7xRH9ugf0ncbznYfzWxnNpTYWkm776J6nNnQTjKxCwhnxkylmu51MmnSHmVo0G2LRrA/LPMRO4gol
# DATA NAbShxpNTEmYxGBJzYb6taMwnsBfOQjBKmK2UDFZGG1Dk9FTGuD0AnM8y+ZIElyk1EJ2pWXlIbNmQCbvo/gzpYm3oo+pzsG9Qhf5
# DATA TDmfNmf/xgwrfDyHXTIhah6KAzYZMjJLzILMnBWnFD04JePtETxl8TBUJ9kjMQyjDPsQ42yMdcwQXo2BcFeQrniEDYiDcTQNPd75
# DATA zhSuOY9FDqXlUFoOpXWDKK0Lx6Cdpjo7ms+3Nwu4yiTgGuYADp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQ
# DATA WQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWc8NOitoNuutK6OzmqPOqPMCobMKq847gbM4YzkuPc44QTPV/YIcRdvvFjO8
# DATA 0ettzvF6o9dcBTn1AkZSqaAsuFSn3u31+uvgUg0JZBCnLEGlXta22FINjicfmOsWaVLDXqPTXvd8q7XT871+r91f93y3ucvz3ajf
# DATA Cf1yJkyDZsMLgnaVKnarx9U7mDb8VtUPfI+vVeVa1fcbVb/ZqXY6nt/17aB5w2gJz9Uddoe9dTnIuLBSze/0vGbDpwqPV3v1ca9e
# DATA Cs7k3UpwvSsgsLgJaQSWtEYLgdVot/ud4CoIrHrUi0ILgRVQQJ0cgRUM68NmjsAKum2/3bt5BBbNhKr0+06T9iCgsbLotyqMNDLi
# DATA 6RA9PiBnuE/ahlPGp06wDiDVrpV1gXjLyeOSy8QaA1buDktmvzHFu8oUzx/Qo3Z5Hrhuzqe9hF32EsrqIPyEaxbb2sVEFBcCZI7o
# DATA 2RMfZcjlT5hhcM2KXRnDtdbjoytq0cOwCdplnMcqOvAbW9Mv/n5BPhVf1EZy2K9Y2Hqy+XkzTl/wmg1TuM1YL1PBd8Jxbau8m6f1
# DATA pcq8rk4uJxdOLjkKjvPlOF+O8+U4X47z5ThfjvPlOF+O8+U4X47z5ThfrxjnC3VBnZCPhoc29WuBJVPOCKTurtT1ZJkOIlQQrlWH
# DATA 8YiNTNUw77XqMHgWY8AK3knTBHF8W1leaF5k8lAfnR5Jn2xee7dkTFtzAjZhK5hcVIT+hW2NXA77whwzgdB36io+e43tGjHPvXfz
# DATA o/9kR59ma/qC/cMnbKM/zmODrZajeEbZoahmLCOqdB+OreDfQudDzRUu1QrOMU5DOUPFpY639rFHmeaX/CIrfkpQl7oanIT6MDH2
# DATA qXeCM4vK+qTfOIJUrTn3cWqnqn+kX767ze7gMqTyydN1N0/Z/uNCZESMysRBizSqN+E0IOIhVv/hE2PMf/aaCbyGuNFbzYXXqa8C
# DATA hY2uUWvPj0HekRt1bvDZo3J6VXJNZdvaXjid6wpvt2BoMofXU0BsL0ue7YkNPVikE5ry/e3fyldsBqSv+3/91/KdHqU8/ey1dxjx
# DATA 8Nr+4w2WtzK6qSvMFg/YYt+TQnUS905N4UpqCk5F4eVWUbisuv0zVVcwDlhJkYj1WUruixDV7d6HWoabU8oHWZeQtow3J+RtfXY/
# DATA Vx6QWOKhbQ8+4HbL27ywKLTxqUJ2iLFgtb38qTuIqdYh5KOxGwXuDYlJSSFQq94ubv/ciU28AIer+b/XTE4oimJcNzehrDWylppw
# DATA WZWsT9NYmW7xjFmNZLvBmDEqWUYHhJXLMljAJxAymy5Fw+GU/dQVI6AvlVFVHq4oGCUzUbS3ND2gcRCyRZ+MFgxXSiN2ozOBSwG3
# DATA 2ND3eGGQ9cZn0SP28SpljQs5Ri/HOXkTgjPunHG3k3FXUspxmllOM+sSVt1G0/GmtLTeE8EmqthqLq+cCFzNc7LPbSs23obIvfIs
# DATA 6MzVSX9D78TQiuP6Nqimi6cMl9lZVhBYp4ycTNijzQAErBXz6PbXcDEdok+TTwfqgrKo5VtF/rBbXN32Y78SVBo/oUFRx2iDpLxy
# DATA qtG73uNPXGWLCGJzi+lb84dWCMABIxtOEo+3kmwBDzfF8Ab3sHTnCih4o5i88WHlVefF1ZHHlEfkpZSNtE7ibGkEzubSaipKwuzf
# DATA hMfhA+lilZoZCCvaDYpmovKB9d5OZkUtNFHNCgFpsV1ySh+LBkyIngkiaXKqHKGmuUPhSgS46OkTnO7ioZM1pyz3X80zxYURkWzk
# DATA 5WCxVBSmSTzFRd5oBMEqiMQx7QLaXZmOSqki5FMR20zOpxZSWkXXKeaWeoXfuA7VnM/UnItl518OCzUfZpyJ6kzUnUxU2xZxBqoz
# DATA ULcans9a7PXDQiOZYaBbxNMcyvRAlklZALViUQAldd47WgYRAos4vsPZRb+jqQwTHquhy8lqoeERxQtbzmanRg9yRwVXjq6JjZCg
# DATA qBZA0FEMAmqs1O4j1rdE57HGW6dOHK+xVGWPAioYf1J0IGXJ6B9z48pcYekJIOcjDkfFTvbcmG5pM6vIbHxg6I98LtqV1h2mS7Sf
# DATA WjEZsXMAoyM6Rrkv3mZhokVqX/LmuywdW8E4mq9bQo6y+IjT/jZ/2mK7FtngspPANlgUzXyT2VgoY+yulsZ6BQC7zo1LAtgfP9lM
# DATA YJeMFQI7JnGRZqQrp/2pJrF/gi2jlPJ0mcl2L66BM9ZOVUK6mAOBzKlXoGNswgixgcLrL8nQVYqp8aDmvR2zwOqShXa9aZzx7FH2
# DATA umC7ElNEeROIXOPWyivDQmIAgohelyo+21Oj7Us16JIZ/C//8MfNOVyojZLRLOmaRiL8C79qPIgXBnnPv+T0Jda+JaNatFSTuT51
# DATA v6DalrKOLw6vLmKxz++P+FA4zQ2m/fhoCe6jcv1WdHcnqCihP4Zk7LOEbzzk32TCfh05esW6Os12q6sfhlOpCpCyzrNOagumOFCw
# DATA lX2+omoLnepJtAASS3Y3mac9xnig92LQxynQskLrmkEZEA2CrD+KDvWeVBRqg4JpIM+++v3bS1U+YZ1x7CkVny+jZaTz733M4DBp
# DATA owl0rsR8EsbszOEL6rh5BAD029IgeU1CKk6WV1QOGFk/wtECzk/KwBlcSBzQQp4CpjcCRZGGShTatVQ907VfMiPf21L31CAheVhe
# DATA ofQWaXhM4+YJpUFn5sfqKMFYCWSHUi1TsmGiYaaMAurlZgsGxyEs2CUyP6GGPDM9g+pVp9RrZDyXjCHxaC2r5nC5Razk3COa/2oV
# DATA bth+zzRfP9k1Xz9hAp+1XIXzjXnrVsthaXSE/eByQIQSkqkhA6NNrl5vJM8z9lXklmE0GnEO2/1A2M9YvJpmaOzekXtUdUZvKlZf
# DATA jM72p7KbtZShRSNB9izaRoK5ItlDdq3eXagnduxsUbv+qCMajBPoZ4Xwl1JJ6oJ4JRbebIwelURkE/T+89k353939uXZ/zr78/lv
# DATA wb07/wWQePTfb85+d/4bQeP9/uyL85+ffYW/Z38+++r8t6tEPTscZuX9gml8ePab81/jqbOv6SLz9gS9R3//5NEtX57/Az33l/Nf
# DATA AqeHGPTT6KRq0Htfn/+K/v4WPzNx708OrfcieGukptm8eZlyPozRSmeyLRjEhh8a34wo38McI4thCKUfthRkfQO/P9TbSdJoEM+V
# DATA zZUt0R9xa58mLNa/laT3lsTLakAOpmd7aZA7t83RWy2Tm0PpSdXJVxI/lqokkiflm9ETWWuO0cmN0LJ5R/VcHbqgrJAJI942jWZL
# DATA x9PbocyuHaknZj335dz1wMssfrM+GRC6dxN7nruxT/JuiaprcqKgPppwzjprgv7lQwcotHg6xRkdwISosA2M+FL1bwsGuNyonhVi
# DATA 7+JEOMaeG+efcpzXSL0rDe+vyALMrQztNzCy7zSwX2Zcv51hXapkOQcstN6zbDo3QdIrJ1UviohLNWS5ydKImNlDIuK/MiZWBIol
# DATA i7OyxipKFsfRIpnzM1HGB9oTMpcW42SY7YLJ+xh5KMtY5RhR9sJDwBt3KfnTGBtMErLKsGdLBvq8utA7w2yZAgwWssAoZTL78yva
# DATA bZ9GaD+colMuGdHBERIgHCtMqtOVIQsngvsawFmteWaOhudoeI6Gd4M0vF1Gj53mKrsau7dqt1/FbL8Oq91R8RwVz1HxHBXPUfEc
# DATA Fc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXvuaHitdpBv9G5KhVvNOpFwxeI
# DATA ildeed4JjFegvjV6FjWuUW8Y6pvf6RS5caNBt6fyhiIY08hqgmjkQTSb9bxsAqHtyeGpoFcIr9MMBo3BSkEFLd8LgmAcdOrHfrP5
# DATA ebXt9fyq32h5vYD+1KtdfKn2gjUlt4rmawUUWqs+brY/73S8jl9tUj3wmxdQ50xgK5i4oLM2A7oWuY8ib1XORivPgEbhvd9qDoJ2
# DATA o74S5Ua77vkt//MqpbVJtaXa8aetJsX982rQ01eunAA/uALojluFBt1JA7NAd51mo9Fs7gC6G47aRdBdOOwNmjnortNu9dotA7ob
# DATA dgb1vgW66/gNv9m5BdAdmlR1u73h8fBi3Vrmw30vol4gDisScGkxbwUV1+AFs3y5rBi0sltWnFQ6h1YckSV/vx3WOg/8pQZVj31v
# DATA dTac1DNqCWxt0o1bdTWSxiwvIuRU2IKuW79VoEy0W8Wsrc0ZM/Dp1a/6NhrcDrXgpkwRh3ZzaDeHdnNoN4d2c2g3h3ZzaDeHdnNo
# DATA N4d2c2i3VwztZsPcJNl8YOuugNSGOOX22v535BsvOTKWSyHPkkU4kfvRol7/IFyMazyT3OOL+69TDuA4Kr1HOdHm0JhZzvn2vcI7
# DATA 7sg3+jHjXmSRvIvteHu+HcqncpjMCqT8zlIw/OzKkTNNEJMpoDnS4Q5Ru0PU6w5Rl475uOPU7jj1ZY9TbxG+valj1tIK2A6GXrus
# DATA sppj1s9QyOM2qAtDdTxb1Qx89faO9pWkrW52M3Zg5ALw6qm8b1Lfc2ZBkcUwjVmArqWwDez7l0UnbLHgtaiav1n4VsZTSDGbYQ3F
# DATA gEPVkv8XRFc/b+JrLpgI++11Ee5aEQ52jy8PqqC0cTw4mnTlgkiqh3LdXvW9wIFYiaFvxbBrR7AYvY28h7dUi4qMaNCLi3t4i608
# DATA HsYY4IXJiT6Q/N4IKpvoQ/gYfsYDHdpeRmbJvMI+TWqlE3j9J6celDRRyWLw8sQoEm+90Lmk1vG5cWqGKsQhBUEBwswZ6wAHCYwe
# DATA FZI+Ds78Ca7JUbbAujtPqViCacoWsSUCgNPgrMDIy6hDnCTzZO3m0BYDgMmG3i9LppHuiN6n2csxZkhjBmBw+x5gd7BKEKKd9zUX
# DATA AxpenoPFDhLrLNntlqyzW19yu/WyUNhnLg/EC+bWQvCq0TcpSAIy9Sdj0W3FP+jzMVKYIlsZqs9cVegFUeC4CWzqigLSdZNT16hJ
# DATA rYen7qaEWKp/yGqbpsAi0m+mSKsa1lm1PVeQ5j09eiK0zAROpfmpbItFmGcNTwuSLqGHjRLLqbLPUMHoQxYpQwmBSU0qGigKnfwu
# DATA 32CMkrIEN8f5YxZ7lShHlMU6xu+ZiVrMc0CKqugZLeK0wsrsHButyl6w0LTivY0PYIMUQZEVgCMYW6L9ERbmtsf6AaArKta8TSka
# DATA 6oi/oyWuhjS7RWwoCZx7FZ7yVbxTbJYVVSf0GIvkKIKKVc2zjOqElUWnHoMKFPVlU3T1C1dj/AoJ2Nh9krM0naW5ztIsjFPOY+o8
# DATA phcZqM9emFJikCllxTRJpqxSxw0il6ecTKSprBVJrKl6XhFnRUUGI+jOoRlhfZqpYOxZ8WT1TrUrXka8HAXsXbYSlLqjtEm13Mhh
# DATA ouebM3YTLuBwgg0MIpDtoGC7QMHE4rJNq013Gj830130l833a5VOzlX1efPdWsazaH48/xixPP8uyXHxD/z2ZpSLLgxBufxgFlFn
# DATA MmfXYhVHFrVliPUNv+Ud2SsZQbNOF5Qb8dNIEchoCoKtcpPTCtnt2Pvbp3oxwtcFxkuEjD0kGdY85FRHxj0EjK2TMBuLlqq20OnS
# DATA ZJJdBwfnVvLvk5OE829I49S8mHuNejH3ml0r9x7wQg2SzX2tyiQolgLovGA5SpHGlLvELzyJgC/CZl1PHcIVodJryK1CG7x8hrU2
# DATA Z5jVoCXPvkd9KsXu3ZSnsnOZwOT5FpRqXaPTsvJtAVOKl8nYcIpnywWGHIiWTooTKx4xGNZDNY9mV4qCZyZhx9jROHkO8q59ibx7
# DATA C1UgFVmJfH2wkH2latcI6qXsq/BUmk3UIymKjOapopQKYp+0RuxHH6bhCbby6qUB1pvNlwaeJs/sPvySWfbB5vzKRwOF8Esehtq6
# DATA 1pn0LnMqhBsBdJ/QC4/J5jBmOlm4D6nhTRTaaciqw9NkyCQ/b4x1YO9jEQpmphWumOUTsyqT0UBPuc6avGjR15Ft9mB26ZoWbM64
# DATA fGCUjDOOgaKBpvPwAa4qr8vM87tUw4Y6r0Kv0eY9Q1RRsS2QXQg0XVKOGLHdGCPPdS3xjpax4nsxN1Z5b9hs5C3nzyvC62VxSOQY
# DATA r1G8gMSszfH6f8++Ov/l2Z/PvgRj6yvv7A9nvz/76ux/nH3J6K0vV4Fd/4V++t3ZN2Bsnf973OIJkuvsL2d/pJ++Pv/F+W8qCOf/
# DATA Z+/tmtw4znzPudanKHvC0d0mAKIAFF5INbUURb3MSDIPSVt71tIqCkChUSKAglBAN9uyImRr5sxMjOM4YnciNmLi7E5snIu92QuN
# DATA PTqWZUtzsV+g+yvMJ9nn/zyZWVl4a/Qrm2TKJgkUqrLyPZ98MvP/ozAprO/otz96x3+Hn4p0xzf0+6/5Td8cfUdv/vr4C8aDAdml
# DATA CGC/pq9/pADpJ8fseh5cKhnUD13m0OYBSR+SxvCBUpPUuMDJrDNl9XvpUCjDoqnAF/cx/YuH4oKUdgsXag+nz8EBgEIJPwUOI29E
# DATA 5e2eHaWRn4SDtRiv+1gZ74aHJqaO42X7WlQHcdUgryWlcnkkL1ULsyWjR6paDmKK5+Rw/n6pjfrmd3KV9CJhXnAZqpiIFr7szI90
# DATA vBzQa7Oiu3Cm16MoAx1kLIgJIKm6yzJUDi45L0Vvg71AIiPMUAVzihien0N8LXlvx109O6beTabX4pxSKV0ge51cGVfbM4ut7Fmh
# DATA vU5OhUN7OXPg4s0BTfs6mxXwUqy2XJUFcBkGwEbj/ymH/6sZ/aViLuSCBf26Zo3qMjhgC8kH1BRrQylz3tenrMA1EKpXnIT5dL4z
# DATA VVsjeAsEi4TE4cS8SQfFKZcFJxSnch1sRAZ7zL5e+IOwASeF6y2ahIOCsuRoQIu7MxRf1OVihLE2oRrCa8jdDPPEEdamgNkxAvOA
# DATA AhWXB5xT1MbhmolHRcpiBrF7ZF1M41GkHVW8fIbQsQwNs6UgNgu9WOwQA4JylDBHCXOUsMujhG045Gw0B9rUdL7aacBZZgEXMQlw
# DATA pDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKuzaksFq7
# DATA 2uWfz0QKa/SCXvs5IoUtLD1vhAqz88UPvKrf7Af11hxtqk69YzNaRpuqNiWHuIykDGqsSCmkLN/PKfXMl13Ftwuvnst/885c6EHL
# DATA v8TQW/Us8ForF7ikKgvcr9ZtCFgu8Fav2W735gOvB60LDz0HeqsJi00gZX49A70FzVwAURCGzepCs6DHPd9v7teCQaXp+Y0TCGSr
# DATA 60TjDAAybmwaQCbtNgcgC8JWfQMAWe4KAGRBt9MrZwCyeieImmUDIOv0OpVuZAHIglqn1bp0AJluoGvhUyU/0BSy3P1mdNQLBMEm
# DATA tLF8EJo3lvXjOqcWHJnWo20syix5ZtNlgVJdWSAV2/FQKS1ZE/bZIMq9OedREMsAz/H8xXiT/IDsBJhUSzySFeORlEyZX2ZZstAX
# DATA LLygclvPtaj39jO7ZC76TbbnlnHRWq1WnoaGVebVlLJcuRXmymKNtZO/cc73YNyHDkPmMGQOQ+YwZA5D5jBkDkPmMGQOQ+YwZA5D
# DATA 5jBkLxmGDHWBQukOokLEy0Td3XKBne78aUxmd5Tu/vyjAhyq+9EuW7AFdLQP8NMuquRtU6H5dBmso8n2zmdxb1se2vlMB00tFCZI
# DATA OOpEpRFZqDtF9arbdvC3WdVZH9zYlujt3EZX8OHW4+wYW1dwYp9bcxzsI9Tvl1LEsY8170X66SlKKit50MR4sq16K+gTS/opAaPu
# DATA jd2x2r2f/hiG3W1KHwJ/lX7b+Yyf3h3f5jMZFCf68Qd8jeKxNDW5BJusv20y/LbUOkzoudFnNYzy/E2l70x5r5Bw+uSPUX72HuOQ
# DATA VP785YSizwQPyo84kewTW/7256tfx6S3ThQPtrcpqUWkeecmm7aAvKksoZhQkk29oIbEqS+xG3fns6zCWJcl7vZ9lHE2Fy+rQSqW
# DATA yFXJITUW7HyWZRiKDsUZUzbGrypyHku6IZ3xjRv65tJ4RqbJZyrmt+ROnLKj+wocEZpYf4BTd//xxT+pM43A5sU3/B3qYigSC8EX
# DATA /Z01YeN4pB32QxyX5OWPxdA/z+rC56qO8GRSt8nFqqweuJ2r/belnu1iBqurnnVDoRKU8y1qMhuJlLAQ+rg6cCujC6+tM3CzNq+e
# DATA muAM6UlPcfna3YVV87McmOtn1jWJh1BZzdqDShSiopNk5oBLosVnUOIBzYdMn6proHlMxoqdXKQp2IN4RNPFZYFiJY0eiuYyyTFj
# DATA nM7EGXUmnL7Ei68vcVqSzHXQneCVlZy/fj1O5j0cggeRA+Kr+uB0uIdXTZNhMqGZ2VqmzHUUrXh+jnBfBmlmUWPjolEzy0RMzsia
# DATA 8XJLRFKleYXtjl/W0sCC2TRyYvQydQsEPKWeZCIfttD7E7LKCuJ6Ei17RN5Y3rKal4wxiwRcT1gP/dlkylJfsXrvmEb+kegnJErq
# DATA w4jYrxH6OEl59AU6op9rOM6EcibUhibUXP/qRLucaJc1/K40vq6DmNfrsxhMrbxslZHyekt0oeymhJFnHCVoaAf9JDdCCUJAD2Al
# DATA 7y5EbFB0rKkTylxYwceiJ9Qcw0Hcg+INRLfhfBAJqVEUdTVm7LT8FBNRBXxQctqQVi8sUdJy8JRN4CnDRIqO9e7V53VAlAm70UQC
# DATA Xz6vvhu7fYSbfY8/rb5TmzuKL8Sfnwd0ip17p1TJb8JwXK2Tn5VFjmXBXj0tjs+zomxkw/g1SWZ7/awxfMKwd5bw0Lik2YiMR9ai
# DATA yjZMoz3vJzFrW3XYPPT0CXpYjTMWmxuzfC+MTYrDXjS9CMrAOfIvOF3+vRGlTzx2tltoAWjjKriTSS9LxokrPGWeoW06HISDJ5RX
# DATA Wj6Qw8NtswEw3Yxq9KIRlwGLt+EUhNedTbS4Lg1SF8O0yJrhaeEMlfX5lrVqybfXaYyXfX/M1JnFpvYp24rqXBStFDLE6tEILAvJ
# DATA S5amk8WEVNG7onRa8v6agRhRpz+KP51FRkGRKilN6MBKmPYx7eiHXBORr1NVcS8gN7Nu6rR5eUId1L2e5OQHVHdYBVFLNRsMqckk
# DATA SiNXIbZQFWrUIOHJwu08gRTknCmrci9k2UWF/BtEapLJ2a405Iyody8/DD+rFlw/XQt+PRywHaGmCpHNooFxwBmSzsaYgFECw0n7
# DATA UM0NOqKzKDudSx6v1CB3WY58othulGu9KIKIIqZaZFFE6TjqxEyEFfXLySHrGZpJ+Cg6uIgctMe+01bA8voszIZSBVtB5ZqYi5qC
# DATA S9OuIXdt6OwVqcdMwzohqDyUUQdkYMNUxw4Kr08WIeoXsoxVQFn4kCo1dCD3sVVM7bG5tlCVF8i1kQXh/BrOr7GhXyNf05xbw7k1
# DATA zrgmtNIFcmka5arK5uivMMWpmhvvxjNnZazzbjCTcSXHnjd68zIHdn+rk4v6mpn08q4Ge+Q0V/Ssl3MpOx+JnSH0Len1xDQIu2IX
# DATA 5BwSvKuFfmYbyfQ622p7yo7yi+gWPuIN/XiFREo9bXpG/d3M86tyfBPDwISMezJe+MwdLg7Dp3JHWc7JRWM+mrfad8KbZDglVplu
# DATA HFX1tImq/m6iWjkxqn5z46jKth9Elj+dFDd9exY7c8XEr7Yser4Vvcqa2KlVQePPknMBPP0Db+8m71MckoktN7L5MRneeVWkFbIs
# DATA xLEQuw5ml3J1bkyD+1SO496UILKKbHwzVvswl1Y4cMQkoslg1zK1cwr//5ls046eoNLEvIdR0oB0ZMpwENLwDtjOmB4lAw0zMEUF
# DATA ymaxGkip6IRqsiWUVLP310JaYkhOBkWGWfKOLXpLFzzMRGii8KIUvG78i1/EGFLYvTKapRDkTw/J9k2GaeZFtWPWjwbjExaO50o1
# DATA Wzy2/arZMrDkv+zZoscf4ENW4mcKTLZySaOMplb1ERuWS+zlsMot1uFsQjYxmXQ27fC/Mbzwa9AG8wzC49/g70Xa4T8ffcU8wj8d
# DATA fX/0e+/4b46/PPru6Nvj/0JPfk+fFLeQGYcgFkrgHLLHQMSvgFE8/oJu+N3xP9BD3+K274/+jcLRT/7+6HvgEr9hDCIF6ZiHz8MM
# DATA w1SvbGLBFR7EE+QoPVNQ/krucDQSg4WTDN1ZIkwW0QMqRaERwLAyBA/qSbXRM46jDs3G18ENH+ptDDQAMFrNoQ2tyYQusKuGGy6U
# DATA yuWhDVUd0beBs6GJO/zLwv3YvmJ1uI+SntrTcuFoQ45ADmwYp1zZHdZws2K7cKzh/afjAXqZUDtDhkl3NghBXk+mrNlT8j5A3899
# DATA V7bPixe/sDGenjX7nygOsyH3lKlsg4ILJZmGei0rHAk6ZgFoeHIVXG21zLesZ4UzPDkNDmfoRvpzjPSaW3iWAf7l8BRe2eB+8WP7
# DATA RkP7KUf2qxnYpVrO5YHFLHxWLecy4IRzqcQKAEhAivMXd6zE6nOO8wkKxaWpoHKgrelN1CmKhzdfy7ZiLdENK2nEXtH5fNuQSGi8
# DATA rFns0mnS4RVHHo81Ko75cVxLujTXHqUm+tFsknjhkPFvPORHZDbEnRhL4zmbIGcBRE9xsBiBdyN4o9SOarVWSNYDFed7UZgiQmzb
# DATA daZwxYiRyF4dodTJ2roq6vbsUOqXoxU6WqGjFV4WrXDDoWajqc2mlvFV2vhnMfEvwsJ3rELHKnSsQscqdKxCxyp0rELHKnSsQscq
# DATA dKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqvDaswsCv1YLOGVmFUbfnR43niFU4t/B8alJh4HtV
# DATA v7xfbLU+9RvFasNrBPR3vxpUPq21vIpXr3jVxn6rlculjt+udnrzGDsKq74UY1dbIBvKST8B+LXyAL+g6s8R/GrNrKzl2FpG8Iua
# DATA UdhZBCdafMBmkAu+Um3lg29VV4ZukpkLvVYO1oQenCl0u0SavlerNfZrrSF1rcVaa7/W2jin/UUYYcP3Ar/RrwfBXCidoNNud5ai
# DATA KE+PHZR2o7GD0gQt7GC9GzQb3ROxg2Gv3avnsINd+rtbsbCD3XrQCAx2sN3p1No1CztYCWrN6qVjB802NQj/7200X1/D7RP71luw
# DATA i7Q5Pvc2M1CqqddbEXU3cViQ+C0FGAZqJa6yQOvDwuLCC+bc7rbRqAskP+8mc8/zYQd4dfljh8nW6cY5FGjTCZkiRm4+qDvhvKFi
# DATA YQPzkbU3F+gRXS17lZd5e2UxJZ+0Cnyf/Jf6Y8+41xMH57K1MJ8na8yWtUlme8IBBx1w0AEHHXDQAQcdcNABBx1w0AEHHXDQAQcd
# DATA cPAlAw7afDdJtngxhJTGR8UR/Z0fN8s3KuUCzSzVTwdchDsyZdOYr/tySIYPuqGR3eBfwaXrDBFw5P1//4fXKuNbN4rGpQ/pvxFo
# DATA axTund3yax9ufcBa6nyOjhdqEAj9KEGUeMpDEZawzOEbxMVrH+JepuOF7RQh7pin8Inf9Y59lE1S50XpFH7k6Jb3H7/+fxGZhbRv
# DATA VyvlG3KVxT3RNSBIjTJzCDF3tvuks93uTPeLfqb7tKSw63DWe87Fth4T9i6ahnmi5L2Ham9ruyyFgz3T0+HPz9HIy6CAzR9mv2gG
# DATA 2KIkwFkJYHl/rT6r/y5Tu6QiyGt6kdG1eQOux9DrJvRDesBntB/ACYmqxVJA/TCelLxH8ZTdT1rwXSqgCJfPxnI8WRVu7vh+mEkZ
# DATA jSHamPT4LHImmjOncLNQzk8imMqhkduBTXT1SjfP6BSs1YKcMeSMoXljaKFHdaI3TvTmJDPqeojhPJD6ykSLbmLwF58kbaOI89Bo
# DATA N1AzjPdGivylNNQUPnJCw0IH4hY93CxKEmkI/CrcoxqPwxvyWb5DdGjghhzY2i1LNFM2Bn89huoM/GOZko3Ng2Hfhah2ONzXZrgv
# DATA Sgr0SVTSp9xqVsO+2O0ostD8cfW9vD2Xe5bH/Ol5gHdZeXFK7sqjNfwknatCXLmHVkGlK7aVAFceHyQi1pTMIBgTQo5FICtDtBQt
# DATA kYgaHrIXSmSZxDykcW0fXuRfQJ5lMsyrF4lKEdl+STbehRCEodoRikZ9jw1lfeZUGo2aHSwXdl4UgDYLb2KTZAk0OaalHDA2YEGZ
# DATA M4YesAShz8e/OnPJPdy45B7KAXOx0nXRvQtbBB1hyGwAKo49pf6dMukrGrM6jmIJ5dFhKD6W9BG1byoCmaTe1XxGeAzVvijuTQfR
# DATA VIEFJiou6TiZnr/Icim7ujLLepNTltlP1tHKVL8kZfYTCBAhH9sJRcgGRLE0kV5H0YJme8LIotylThwXkx5ZI4an1YsORHNKD25T
# DATA kYTHnbK4wyV9wPQ3Zq6YRsel356lh+cvrXyanoPien/j4no/BLidFzOor894VGlftPRNY6Bebw/+8CfRoVj77RAKWl4/GUrDwuRg
# DATA xKGxRt3Io4KagBYGVA54VeyA78VPBR/H0ISsMOeF385faPmUXVmhZaPwKcvs8eoy0+O56hVFORDXsvISfwT24WMYoCaUCitwII4Y
# DATA lkfuqHGCvXHeXS7fHuO7qBOCCBnGPbE8cWzKG8/48ByLJ4yAdrmAfi+L+/UvkcqmJfJ+pJTrMHxM1U+KcCnngyI9wEhzEmtDhPoS
# DATA j493oQUciiChgAFVq+H+jWfWCABmNw9lcaqNFJSu6N9dQJtZTMiZiulqCXPnwpi8DH42KwjnaHOOtnlHm12lnI/N+djOuNi40id3
# DATA SYLTMiWXmR5GQFRu2JjGxfYMoQaXRJ7LebL03hPY+7zJGstPTd43wzNh9fsJoLMsFNNdWZcyatxJqLP6hhy2A+0tM+AunheoXXvb
# DATA neGJgDsJIAPcqe8W4G4pNs6XyxocV94Ycie7eeAuxAdhjAkFGSrFnFdzDkT1QOY91CEs+OwaZcZ+YVu7d4CFTN5f1Civ9vL5Pj/y
# DATA OHqKnqhrPUW/rHmsxo+9TXcf2s/UymvchCsRddo0xW5astSmzy+kznbdHfQpFO8TsjxH0WHJlnxWus7SCcAhdJB4Pre0cKJgcXrD
# DATA 2pimScp0x6ozdRYUJ0yveOCmoI07Xhwa3LeIx165+7W6Nr9YbTvzGHBJBVatlLneWS2c+qiZhl+qPbmdfE2F3rSSYadQtAp7gSz8
# DATA p9L1jSiOA5kqsmr2eDYB6F0WtpOU9VMtgewNIHIviPGcIeSoF4k6k7A3tRBy7+lrxeO/Pfr++FfHvwZE7uj3i+i4f1mKf6MvX9NT
# DATA Xx5/cfwrXPbon6/p4u/4768AjqMr3x59dfx3Bgn3zdHXSiEdCl9jaKfSkO0wcdfe1GfLPPRMnfH+KtwPvfvdWM5iiei92lfCs9/e
# DATA JI5GXepA+NtBMhl0jfUPz/dsLL5TuBLEdTY4ZLpuApe2UETZaZAtUKieB09FT6mhddci5F6HgAZrTXj8t/AkHEcumxGYTuGqOXLL
# DATA i+byYHJ9ig6TCzI4NddXff0kmNy9UCTBLwMox5uvyHakf2lMENcVRnM0GAeU26zoLhwoJ3kWspkzQucm8yozndKGjZpMDaWDIstF
# DATA VxRe4KPhDf0uW9t7s5AaxTSivu2NOH1SgPVDT9978FMvHUeKlIHj75Q2pQozYxsIrsXpBrS55XV0tYmztA1eF+zc8sQ49JyzHi7J
# DATA etBYujMbDS+FC/HqDIZLshc2MhdOaS1cnbEglXRZZhhD4Xo2tMug2FnZANAcFom70RgcKjJlzEBtcohn8yuypZMMhzN011jAewcz
# DATA iA47LFhSJKV86UT2iD+J2EEh3j9kWKo229NIT0XG13vxhE/RpunGhDuAtFLlm9UwMcqQfbIIJ+LnUL/2aK4c8wEH3hH0XvIJjWge
# DATA J69DGZj0piXvoY63HFBQsLB5J/CC3SJnBTSCzGhaMMkM+QFdHEgH9ymT4454jzntI3HX8F7OaMQcHZyQR+sCiExVCcpVx7xzzDvH
# DATA vLtE5t2Go9eZDnatM8uvfKZxER7Vs84zHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAc
# DATA AM8B8BwAzwHwHADPAfAcAM8B8K4NAK/iV7vVytkBeNXnCoC3bAV6IwqexYurZDg6OY2W5XtjTqE0aOayqxa0GkE0R1arVKgAamvI
# DATA atarW2d+dbPSrtSrZ391pX7mV1ebjXate/ZXV6tnfnW90qrWGmd/da38zMq61nhmZR3UnllZ1/1nVta5dt1qXmWG59r16V593gzP
# DATA tevTvfq8GZ5r16d79bkbV/mZlXWuXV9tWefa9dWWda5dX21Z2+26EtSvMsPtdn3KV583w+12fcpXnzfD7XZ9ylefu3GVn1lZ2+36
# DATA isvabtdXXNZ2u77isrbbddWvXamp0Drzq8+b4Xa7PuWrz5vhdrs+5avP3bjKz6ys7XZ9xWVtt+srLmu7XV9JWduuh0rZqzYq/aBe
# DATA 3m8Eb9PXvNOh0a4Htc7Sx2q1Bj9WrS8+VoOjo3Eac0xNQCy4vF/PBek3q9XKYkyCcuBVgqBfKQ+rgVfuV8pzudEOoqDdWIpkb56J
# DATA pl7NaOriz7Fo6s1yGAX1PE3db1X9SpCjqc/x1UFTb0etTi+jqQeVer3WNjT1sNXuheWMpl7zg06lfOk0dXYGF9u8Sd94OmWxXWPR
# DATA M29rUxzW9jPzQHSzFLds2U1v1GjwBk1sz2Qm+uJuxzr8rPIaPgi22baMurUtYyXQ3Qp1PWtdiks5LQOz7KJrBB9L6Ifd5OBWi37E
# DATA n7KnSvHzEr1qCBfYiiXYykJw6/MwC9BTW031/jVZtjK/jpfsPlBrvbqGmWUAtRc083QX5k4U5Je3y6th63ZJrXGHL6tr7ORmv7qD
# DATA qjuouoOqO6i6g6o7qLqDqjuouoOqO6i6g6o7qPpLBlXPLEal3bC9Y+w7SrX3ULQ/MuGP20Ks4i6bbeXBIePKRVSkOEy60a6gK+ii
# DATA bLNFo86uichEETbIbiUI6gFfxSxPZNPSXc1G56mxQpyr39AoNSAdEYMLYgphtt2mBB4PFWwk+6UuL0imXYTMhYkvqObcNkopDdXR
# DATA drlQr+3AOMJBle2bP/9Q/Xdr9y9/gH8nHMxHN/cKVK4Wp53L1luE00NVYPez/XAUDwbhrUphPJjRtD+9VS1AMu5W8PnPOSo8jTVx
# DATA +Ujj6R/N9vaiVMZFFiDzHt5975bBxneieLCNN9yYz54fl/wm0+Tfil8XaP3rLP+T6fDOhSIBiAAOTfIRhObHj2OByvulig4SnbNi
# DATA iWBUEMELaOqJ0CG/UNUZaOJNIc83JXNZ1yBREoJkiwLScyZkGrJ09bV15hRncNxbYcl+ZiYakEibk6elp7NKvnMbIwscV3MaORD7
# DATA UAmAkostecMxloHgh4W8QIfTqXM6dafRqZsTc3GKdU6xbonmz2qWxXVRsvPGE7RT1tDKx8lI2d3NS7rtzSCNC2GmVdptCmwxAm82
# DATA 7sQqaMzvWI1Vi1UxjXZeki6P1lqQozP39St3HmBooq5FR1y84Vpu6mcybivFtIx8BRs4YUI9MIBA3WAZp8gq+lMWqJfgUmj5ejLm
# DATA 66nubYjFQmtKqc0BseVZTzLOE8pWFOcI2viUlBjGteYQ8pG/pMfRiZ4CoiayXuipzMM0Uq1S6uN0v6HsIpbby5Ru1dCo0//IGFKe
# DATA NqSgWAe8jygV03xYqCcqh2LWsSh5P8PIufBIpz+DbrHWH1PmSsnjSUNuoBU8sABQxVNbyFGFM4uCjEso9EnPjT6WMSsxIsygYnqV
# DATA OUuQrsuRu6qLlxxRvTo3FpMb02Ss2AZcV5IJq8lB/SydjTFCY8sx9JyprnWirtX/T8MnAleAVcj2DCZf40NVqHpwCQ/Cw8yikgFI
# DATA Yg9ftfc4YkemjhuDXUPLFGMQsT3kcN2Kp+uSze/H2z5JKNPaGAxDrnM0b9AJfxceFM+y7bUqINOg8nqBQkNl0S6KEha2xlxyLCUX
# DATA dqkLjw3ZRgnK6QSIDJ2GP+kJRiYop1k3DOgMs1ZmTDWm2mlTTmUD9TmD5JC9vvOQNVEGe/EFzrJRxxmozkA9jYHqzNGXxxxdaWZe
# DATA c2Fle4F/EWE2yNmp0mLo72mfByTYKspCzR5hvR6Fwrqu8svPl5roSUAHayuH4OZ4i8ydV6mDnm+p+jhabpNXszy3yUsdNQsH/G1Z
# DATA e1k8Jiatv5PALSVvPBx1dHSU+tKdnyycMmMPPtk8K4S8rWf5C6drDgKmN9JorezXlc3Y18rTnD/aGGODbbl4s7LKtDww8zpmY8uW
# DATA NAxOGuxhj+rpgsF85Q3MvDlqOfjm8BXzdeH1WYyav6i3LZVigdh1IuFjpF5coIhMIjJdwjZZ3QrwMdfecfpVmoImAPerdx4NBfhN
# DATA uWloyNzcWMs3VETk/fyshWXAQX0fR8l4QC30A173QF5k8w9WM1PERZFJzumE5w3HaYiKq0FvxlqcR0pzlFXp6eiqyZ8x9jF70OWp
# DATA mGkyw8BOCJlxMpYEsxTVVanSXhOxBxMyIjvT9RG7x+sNXgqL/1BHT12UmTRb4F6IqsR5hJw8mLBqdnIwoikb/RQPIYeuK+vS2NyT
# DATA yd5ibF5CkWLHTXZW/Fmt+Pkq5/zMzs98bgN+5XTh8vzMhic+z+MwWLVrifm6Cv6yXvmlH+4/Hcu+HV4FJ1MmSmap9rWewDPOgjH9
# DATA nnXJAHybJwGY/Y2Bxsbo/4C7QUQsDzDWN2SMZTNNmOcKq1V2/KYc96sZxGodXqZ5/HH1vSh1NtvYb7+GUbyYMl5LN6nDN0ZMKMN8
# DATA +6349RMR01Yw+TzQF008aycVS3AKzjSv+ivoH0VVLmBPCLVXyoT1kTaPW9hpfSXjTZ8U3eqmseWNHFkHNqSOgfqOuThid46NGp92
# DATA 85xx+W5id9dLyWLSyzR2VDdgUt/XqGTuICYRr1loz/TzC6g2awXSAQ/C2YjmQ1gQSKd5RrVJfxdwGja7eI3AogyhZ5+AzAyEtPQy
# DATA Je8uLu/HZO/Yi2RsCUVPO2o1w5P1CHXUoaeomdjgEQrA5jDFhjWedfCMTYwoXqtQhtIkjBW9CSzpcCw99Vx5Zg4U1Ttmm0hyGWu5
# DATA RwySZ5GLnBW75NEcjmkJh4lX2OZBTMy06iaR4KPUzM8DJ+oAlYwyg5GhnanC+5hR6GRO9os2a7KA2bM07sDLEycWMvvovx1/efSH
# DATA 438E1froT8e/Ofru6Kvj33pgZ9MP/3b0zfFvF+nZ/3T0/dGf6b6/P/ru+Ld099Ef6OF/p3t/dfybgkefvqcnf3/0/fGvQdFG0ELS
# DATA /hX9/c3RN8zR/oIe+Ve6BSTtP3p0F3jdv6Fgv6Fgv8LTR7+jaP2Rn6Qgfkd/fwcs9/EXjq59/SeE1Iklw6gIspwgsjR3ivuqDjVT
# DATA gPAGvAzMq+UP1AgRapu2IEgwdk6RGTceRIoXpmhX1PtNNNSe2WCZ0bqWov0QD1EfFDl0dm6+l3UPVw3Ptkrk8ojZqlal1kyPL3DF
# DATA TOfvbkdh1l2/Tl+4MrYjGusvEpVN4TK7OtYjmdpasTCpe0lZ2RsU2oWTsu/1E+jUh4CY05g60vYrZTC7nRRRknsTKreFPeDi8yWL
# DATA hTqp/WhwG3Ht8zYpsu9S20sVptIb6s0pp6l/qy2YrDU9K/b1iZF32Gs3rJ9zWNd469ON5i+H5/YKR/KLHMg3GsdPNYxfySguNdEk
# DATA Pdvt+0ybymUAqk0aZXvoquRx5608PlzOBdlJSWnYY6mMcNqXNPSwEbIvS7ay+kzT81DItJP+4bQ/zArM2gsZ6txQyGIMxZsQqd9P
# DATA PBNdAe9q5jLHZpR40mqWw3lL3l3+kQW6UyETs6KzLGGpXhUBpdNkTNZWX1Fwp2EbGSYH7MR6yFJlANmUX504FX0KnaUdOCMcX9rx
# DATA pR1f+hL50hsNKRvNVzY0fK/Gdj+L6X4BlrsDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQ
# DATA tANJO5C0A0k7kLQDSTuQtANJO5D0tQFJ1yrVMAjOCJLuVXvlXvAcgaTNivNG9Gg7P+BiDYJ+vVzZr1bLb9P3X8znYxS0luCtmp7f
# DATA rPWDWn2/CbxVM/9Yx+82uv78Y0O/FngVerRaLvoNr1KlD161WazVvCr9n35rFJtereoBnuUXq02+VsHtgVdteVUfd+Ny2Wt5tWax
# DATA 4ttv5Z2QebZVtRuE9fIyttWSuhEgPo19vzIPaGvX2367syyU2gKMz6akVfPIYAnXAnjVs+pbzZPMozBotBdiWKnUzx/Dil/NYhhU
# DATA LziGrdYFxLBZz2LYqF9sDKuNyvljWOUmcUmlXKNGcu4Y1qqVyyvlwG+eP4ZBObi8Ug5a/gXEsNG84FI+DUhPBiEN0pPxzALptWqB
# DATA X23lQXrz2Dy+Es6D9HrdVhRkIL16GESNpgHpdRrtLs3RDUivRdZxtXnpID3e/llcZ92XqnN8us+thxZZdDmXkN/Mz3p0JrCNBZct
# DATA 5T02PW4XK91obycX8hyh762IxvU4LEjc553fVXZ9y5I3w/nm1+9VyDxZ23RNraTNd/bnVq2kIxhPbzzKWe7GsYAjBtoXjo1hxVMu
# DATA AdWWOaDZD2eFp7xgi3g+VZvypYHCsLwSDSyvLN8OtfCKEmJNNqs1yycTVTcGu4TJKg46rdXQvayEC3aZrJlFLNY2lVyrGiln9/rC
# DATA 4akAav3KaVRWUKebjzoIoIMAOgiggwA6CKCDADoIoIMAOgiggwA6CKCDAL5kEEDUBTVR3GXrtBDi0GcBEr6TAsuwlW9LfvDpsF2p
# DATA LXH3f93Fj0XUltsciIhH7KrhTX2luP28XKgUaoU69ZFxb76HVLft7OjHzd23+XWmIm6PCjH4byPd7e2qJ6xeb+f2aG0uASCnR6ws
# DATA fuo9Mko+3b3zVL9BejK6ouzcp6o7o/9Ar7PnGGMcHdve+SyXk7f5ELC2FTlDd+ZSNdq9Qwni45cwRnnejubH5+CQhJKc/FSYPwqa
# DATA eyUFwdthcy4/Df1wS533Q0eR1cpdGnVZQlZOGVN9FAbeQzl0jCSMqYNlzJ1J2JQtXiD3fqDeviOW//KyOSEl02Rvb5BLSSGmdo5a
# DATA JEniQH+O7x+ZIlBAxWSXa6W2/dMOdB6R3J3CXu6nt2gSQRU7oSEroowZdQ6l0Pg19Lbya36zfKtaLd/eK+3RvTAWf4Yb7rJRv41T
# DATA CwUVoGxDx+UdfXf0dJyMINgWDh6Gw/HjJP9s2V989kapXEeEKCEjKqLtPQSmv8jdUNKLR7yyiTvZA7Utn5Lx9rIQG1RMUoAPJDNZ
# DATA MBFwx218uOEzszHpeU0uUk68/uVHzdtcF3etiQxKulAtYwVOAJBwoyRc1z5XcxJWxtcIRl0dPsvq/m1VNT7XbYCnwFNsN+IivHtv
# DATA 9yAe0cSqxKfKuV4+nf7yl+riQdR+Ek/tn6S3uLcz7dM47d2fTLh2y5F0a5xG+jiLpB788peYD969RxEKD8KYZn+cfeinhxgnl1Tm
# DATA U7aiZGw1IukfpaHc/pxn+3aeSBlJnPPmxeLxdRE9EgUeSB/KKe525EU0TdNtk/odM5Vd0tXx+bh4QNO6XKeHIjOPyZC3Y8WSAlWl
# DATA sCRIrPHTIyYo6znO2tek1Usw4lMzh2qdlo3TslmmZZM/aO1EbZyozaaiNisFyC9L7OY+1l14dIXaxCiyZVu08M2zE1C7CpVxMQXo
# DATA 8mN88LZRHOnNYTyaTaOTdKz1s6ZzMheM5LJSDZ+XhJa9IUoTurJOwlof86Vo83FdKMYfosvi/E5YOINKhxfQ+rLSxMVJAcj9+Ywx
# DATA 60lWTpgf2SzlJWvJG54ClfnOfEZoD06WFebWLOn8oD+nbr3+Xf7m7/Lz2YwHK6d6V2Xzd1Vy7+IHq6d6V3Xzd1Vz7+IHa6d6V23z
# DATA d9UWpNbvBKd6V7D5u4Lcu/jB+qneVd/8XfXcu/jBxqne1dj8XY0F/fc7TfMura9i2vBKdXV7+voCiKnroUKQLlqJyBptqO97Imgl
# DATA HJ2hqZx0YDJCYvYAbDJP0oeQWprkujwJwS941YIX8HDUAEUrGrGQqocdBBy0AIWHhgRmRYwGquX+Uw/9K8MMLNkv423PVKVomMK8
# DATA QSuCYRBEmGI1nl4PbAMp8+dfTMhBW93Uaf3Uyc2UXsyZ0mlBrM9cFpQ3d2X7vC4D4WnJb14wt9MWL10K61yJk2UNQT55aFqqcFEg
# DATA M74GK3sNxFGfE7HADeXNvWznoDauxGup58tyYodyhybTUNGESpIxtO4qhdZwwiJXcIySMYSnyawi+4r5p7z2ImKtY5nG89Yu6DBi
# DATA ns67mgp4QBVUptzIE3oqpHhA79jHTkShAu2BTcbyk/RyZuRAl0+LoZ8+F2H2sWbknHbsVUqmPxtLKVctnbHkjKVlxlKuq3Ju5pfe
# DATA zbzSyHr2muq65lN1DllW+hAegBHdx5uRMo318QRNEzLAc41sb0bzY3Y1TyKlgb0g703NxSiAW8rgiZricx2acyznrIZFEXVzH42r
# DATA uhnziESla/SVMWwmvZ4X7idxl1c/R0mcskt8ojW1pTvIwONZwrSiW8l7REO016PQREQ95XVSOUqMwXcgcUl5/yICOTRa4NSzzNop
# DATA NfrZVAw3lpED87uriXCIccl7T+lse8O4M0nGfXbAKHxcFHbYLY/nKQegW43ua7knPnP3hGxrjJQavM6UR9FUzIg0k34eJNjIMgXN
# DATA VzbgjUOGGlrdngbolby7yEwKOh6PFXgbQbBL7raHhW1cZfR2KHfZZe7hjAT64hFyR6PfJd2cKu+A3sYr42uS934Iu0a4xXuJUZ3H
# DATA VTa3qCRgFksBa+w8lbpU8mkyTCaT5EDpe0v151VyXTRc9T3JxBH2dSazDjRgGIMuvqvsEG+WNmG4G2g6FRUGPkVZXpeeN1menz1j
# DATA WOBZAOQMyKLjKUgEa1EsUKUIn2CQmvIQ1ieTwTYsqU1i0sCmXiqmId3ewwl1NAUzDkp1AA5RMAF40ZOI4fOoeZSNQykkJk+TZbmH
# DATA qjwAiZ4iMxthYMaaUjJO5xMp9tRJpKDXpZ7zyhXiIzkquTCb9wgj2jzY5DbSWr1uUTuOMcyt9CqvcyLnF0pMKazJvMyvzK8852t9
# DATA eS39Is3KNL6LfQ0vl0ijyVhYwizgRnSxb+MFk4dcsqayTtHpWJ0wWsrFvpWXTrDve3XDzL/w5mxwTl/8izv7yRCX9LZukkxSm2/5
# DATA L0ffH/8tgJTH/8jcyV8x4fKL498e/Q8QJY++Ofp6EXD5L0ywBJ7yC+/oW/zDMMtvj745/luP0ZdfHP89/flSCJcqYHoRYy2/o8C/
# DATA PvqzplcyGJNu+xaUy6+P/4F++6NDWF7/edsjmWlNEhhJbApj0SiZ7fWnzMgRmWk1vA7iKdQ15BSxmYjNRtp2IVMKo17I8FYZ8NmC
# DATA SWXmBgwKzMKQz6Cu5Vc+4h0X1BfGA+8TshjZiHIky2wOp3uBq8ZYLi2YywNacr1MrfmjrqaCPMrfjMpqbn2gai6Gt4ukWZKxykIK
# DATA ag1T9ppQkxg7kuUGpXXhIMu7amvVgJrHYfEgHDzJSE1kVoO3A/yPShZs3U6I40Y0yk4gz6bwOmEXI4SBRo2iiIx8LMBTvTzkuYGi
# DATA IOH8/HiBZHlCzVttlixrTs+KaHlCIhzP0o3x5xnjNczyrEP7S+GavbJh/XJG9Y0G9dOM6VcwpEu9XJIDZkB/hu3nMgiXS5Lq0TyU
# DATA PjF7LlTLpJJcxLLA65whsj3uYJxFijm5y6LMG5/Vw5NEQIHSN7Wxbs7xDTluoxxqbxO4Zc7RjSipZBjtT3Z3Y6ufd0BzbKwBi/JB
# DATA KlRA76dpZkLJyE+WG3Z59yhmMQwBQRPGI15bMrRLWDuxvEB5hlFovJB110JDKt9qN6IxchiT2XDQjzgWocemCW+w60WOdulol452
# DATA eYm0y02GmI2mNBvZxFdt3p/Fuj+3ce+Qlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCX
# DATA DnnpkJcOeemQlw556ZCXDnl5bZCXlVotDOpnRV42o1a79xwhL5esPJ8WflmreLV63aN88/xqeeCXA89vlN+tNZpeozmoNCtetTnH
# DATA taR724s4zKHfqnoVyujALzbp75bXqhdrQdH3ixUKP/jFezWfwm4Gg3q16JcbXrPh+ZVGMaBbasUqvb5VrATFamOuTIKo0e4u8gGr
# DATA FO3Gp35QLgZlr9L0vfK0Vm165f1G8+1aNR9GvdPsNiqLYTRrXlArf1qslBvFJkWqUiv6lBcUowAxLTYbJ5A1TeQWOHp+U17XiSeY
# DATA LXW4+OscCa/DRetLzZ0IqDAX327QrNVqZ6Dlcf3VtDxpChYtr10Poqq/AS2v3o1ytLyo0Q1a7YyWF/TqsK0NLa/arjUrGS2v2aj5
# DATA fnTptDyu9sX1hgF79+d801RUOHv5uRWAtg1y7DRJ9CLOTeXrov8Pf6iF3z5pDWG5sbMK/mbF8mQKnw3ZkwdPB9mrLUL2smBOAdnT
# DATA DsiVeWTntMpQhbFT9c/2GFXYTmNjwAxiK7YR6LFbLXCVV7Pvsnwt2Fm1xpw4IScM0c7B5xx8zsHnHHzOweccfM7B5xx8zsHnHHzO
# DATA weccfO4lgs9x2nAaoahtHkrja+sGNEYQSQ6x3NDS/tQz9DH0BoPdO9uDBb6TSvGO7sheo2CefiTTmp97+LBzY5CvZFzzd0qfJPGI
# DATA AviQ/gMf6rYxLz/c0sfOs7iUpk+Rrx9uvbFwIl0FcAOfNSnqntmhoEPV4CfNVnIK4e5g9ZqD1e5A9UtyoPq0euHP9qA1+yUzV9oi
# DATA jmiQ08LcS5IuzhZ77Cc0x2yZJIFA1uhsP+vz2c/DGUX++4K12pcdJL9o1fbl5/KX6rdvcEw+89Ma/fBIBOpQ2lp2UlUOozHzOKIo
# DATA pMkwghAMH62VqsYn4JX7jYksohuYP1+enRwvQAaZbM2ssfOcEXqm8AAnvR4c0/pAs+geInCpavyK+cPnpxERX6gmciA3zKyTZyNW
# DATA 8yxOs5rnnUHlDKolanRZhXKCNU6w5qx21Ep77XKEbLhP182ALCnRrmANjH4yTfYm4bhviYo/M920CwBY0rj8hpKhsUavU2oWizGA
# DATA QC5QsFiN/XowH4ZjzhxrzF+mfHshqsUfsLy39I1UG6GQgp7vEoSL34Stzi8aedFTykcvHV24fDCLFr8zSmeDcCrq5YcqeQdI6Jg6
# DATA 8Z5H/d1gcBmyxTPWVJpq7syMNcDnWsPFvjcQ5WlIfHc9EaHX4xwNfxf7LqY/PogmKUsxYaWK+fYiC8Nso2IYkwE/G1ODjC5YjbqR
# DATA daJzFjQVZwgerDBAxOC+YInoOdZkNi2TIPOOSXpIawV5w0NjfkhvY3CUGQDSVlQ3y0GZojwmB3b9UU3oMFOfkgFNThylK6SlOgAs
# DATA al0pS5cKqkAsLuU9gsB3NPIYvDLqUEFp+ameoh5Q3heMQlaiemctaYqFp0OtlcQzosms3YZIPpcLM4lRTZIB44tlHBCNo8kMQl6e
# DATA zjSj46Xcm5G8wCx2h0o3dTPU44sz/bAMCjcBcROQhQlI3sJ0UxA3BclPQVZOLJ61lqbidTDToh+OGTYcYoZhi2OnkdLd01KQc2KR
# DATA jNrR6pAKfRTJZMbSeZzaApAYKwcH4CfNBBcyL/EoLXZGTZn6LiqF/WiJ0uOmapuc2vGdN3lpM4t3+zCbHTF3uT2LB12jxaciw47G
# DATA RbexOjxqAeg1eltW+xlYhU/KwlIWkP4xg2ebK6wi0GdWDPdssjgru1do6LaSkoeAq/eaLQSwStXnV2VjhHq5dYfpWe2nXk24h80M
# DATA P6zBY4ylZqPuY9syUY7c+dtpgqoOM7zFn1bf2RnEwzZHFB9W30cdc4JNWXTnffmY3XtT0nZnDlOubU1ZjbdNTYwoawzNXOliM7A0
# DATA e3VGOrOcw0nXTE9584NMVFU+5vNhDszFO6lNdyA7C2RiO+Pba96ToUnGfLxNpkI5snrnYcyspm7EMCFqrVXxEgyTdDo4VPBL/AQr
# DATA 0Uix81qN8Lri0VSGwEjkMLFLMu0nSk80FOi5Fo9loPjISM1Sy+VpsXZvKylMD5aZsg7VQa2rzcD6KTLwA5oTD9h3H086NF3MshBz
# DATA VOoYgOKyOzo1y4GnhLqFT9QWHerJ7vEqAdvGvLcSZvswaeMR6v0iqdNUFE9SWTRTFDAui4vILquVnDK/WmvzyzQ5ybCfQPKT2sVe
# DATA ZLIK3gS+J59HBsElGVnyPqAxs+CxSl5MRtih8j8piBh150KJk90q4g7TnHkaNhjjFnUvIqtMx3PKjGqszSjVi0k2vQ0/jpjz8ciq
# DATA VfxqqhAHFMuUHTHhZKBWT7VvBk4EbIMLoVUrK108zcbP8P7tHWb+wghLgNiTL+RcAMe4z+N2CEldRlfwTc+0TQanaJPvAkSHPo3a
# DATA XZESXRTIlalt9mVqbkKtUxlprbxFYXqIxT1NhKNHyOYX6WHOT7FFUmC8rBn5s6xgfmXzGvZuQkVMY+QgOmQ3QVbHBvRLZuEo7644
# DATA /Gh2S02QPXGZsYYMoR6eHVZ6EVUtioq1BXVgnMhJVB0la0VcUKARTuLO0nzLD8Syt84eiM0VyYY77yd6F5xWnmYTTO1Og1NElaSi
# DATA ROv8Lp3EEHtRHBAZS2wcTYHmtVFi/11AYt7RH46+8hjrBfrXn4//y9FXR38++mYRI/b/HH199G3x6E8AgB3/GgCyfwcu7PhXdP3f
# DATA jr6jv39Hf39/9Puj773jLyV0BP0NoGNfHf3p+DdH3x5/Sf/+Fm8Ci4zeTGF8RSF8pcFkfz76ytHEngMK9EhWfrCPp6NU6jMK9DhK
# DATA xsxvZMA6D+3U9sRA7CZQPmdvIwYayyWtxHD5LvTRmbA6v4F6kFgk5Nl5vJYq9hbMJWa3jw4dTsz2oaiO4KppYvkCuVyMWDyy1nDv
# DATA 61qqf1lkiY2mOARo+lh8lZEumlwkTyycCqKgH6Y0nMKCJUs36fUcTmzTUrtwpti9cNDBqmMkC2CHGaA6HPJOe14CGfA6idfDVMJj
# DATA LhzL/ZlVDpB0h8OIJ78YS3gdMf5FxPQNrxtH0yUYsRMr3WrrJNeWnh1D7MQUOI6YG90vYnTXPLFTD+ovxaLIVQ3oFzyeb7wYcqrR
# DATA /IoGc6mRdh5k262efdO5DJSYnVZxDKsdHP2EnsPiQz6hSIGJpS4sLBKtSfo7YLAPxqlQlThp0zB9ovaqIALxCCfHcIxPZclmKDEA
# DATA jGSo3gevS8GauhnZSaqNDOsdbRMAPpVgox1sAqxtxWQgLLELZtBdiKfL7AFlDTD4CHYAVq/SJxSYiUcM5zjXJqpfA+zSxh6y2XQS
# DATA S5klo040GaWOI+Y4Yo4jdskcsY1Gmg1PYGxoHF+ZkX823+MFmPiOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m
# DATA 5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhi14cm1gkqi6SrTWlivV4taj5HNDF72fm0GDE/qHrVVuPTYrVc9Cl/GtWi
# DATA H9QHxRqwWv6nvl8tBp5fq3h+ueI1KsWGh7twh98EBiyfdd1eq9XoLRDGAPiqlVtehd5Ra3i1VrFFFypes44gAy8AxsvzEXYLr6u2
# DATA 8sEG9Wa32VsC5qqWLTBXpRUYMJdfzteHdq1Ri5YEENSsAKoW2au5WCVqy8hglcZpn7fypVpteFXKh0rgNYv0l+8PKzWf8shD5pY5
# DATA i1cnxC5FurMWBP2g0ZwjnZkHFkhn9TNwyrhlGE4ZNzKLU0b1qNEIN+CUhb1qjlPWq3QbnbrFKWvVe42MU9ZtdmrtWsYpqzTr1Xrj
# DATA 0jll42h6IqUM44u+bwPMl+Uoq7KbrNTk5TEMaTuLJDATssac5Wa6teBHXkB/KgE7HXNoLslRCUFFeDOnmkqVcaxVzHR37u2VGvsC
# DATA 2Y03Z9uI52kNwkunq5CL35ohPHebdoE5ZJdDdjlkl0N2OWSXQ3Y5ZJdDdjlkl0N2OWSXQ3a9ZMguZXFYHK5ueJjuvhdO+6XeIKGJ
# DATA Dcy+D7dwGItS/2OYNDfVNT4fhYvylaZZMFSp1bD1+eHW3TFN8J7CRRkNDik3biDoG5QrvZnIhfHxsJ6lc6XOWvEqEkhZQGrpw1yh
# DATA OpwFDTIEKcduQj6kjQMq5gyW6P05ypY7dnzaY8fuuPGLetz4LHita3AMmd132t+1nrIlAlYm3kuPKi/ha12Xw8vP1Rm+ywBu5Y9b
# DATA XzBpa64ynBWxZTlSs0PkKqczLAjkGUVAXqmucHb1q3fe5Ak+68ppHTquPhAKHSm9OTkIa6rPQUhPtJMDnHaO9mYDyPdp2bkh5EST
# DATA HtTwu7MJV9BwMtTS9+pMPL9bR+Au2dYxGb+8bVZHQVPCKHt6WCRtsxbnFH4ijzeniGWCpdYBpw16dtwWcKKyHeHFXbLJZpO2EZ58
# DATA SY56WmE4u8rZVWvE2uzK5XRdnK7LaQ2qNbity9F7+etRcoDuXxQH2uGeaKxBckMNbP7Vy4ldAF2LVyDUDhB9LacNzxN9uvrTEfQW
# DATA IiXDYtxi3vaTvZ05EtCI14Ey0I4KwnRT+nsOh0SJpi4ZejLDmOVtyyX02dSzyJYcMY6wlzP7cYWcvfghAPSxBVvG2OJKg/32ifHV
# DATA z2f9qr6QQbia5WVxtmOM7Tp2lNdEmD0lTGmCuzrTsUFGnRBX9aiJqv6ew4Wtjae/JpZzBCW1voTWqpwuokbOVd2iJKFS3XlV9pqq
# DATA eKo1RlvLN7skvUu8Lymg8VcxW29KEOejQFnMJqt928JHSp9eIV5CNHujD3gfrie7AXODZq2U6GksKi483KHH0S6oT2fUC0GrPJ3t
# DATA 7UXsgQYwglcmVAeRTICxAFSJVaUxCnOgIwAqBprGJQw09o2rdgcBFTLlZ+yPp6KBHgwUgsM9w4iFAhWM01RG8m7cY+mUqegPsbKz
# DATA p7byRiY+IkcPaSKOxhJ1okySiGWV4WlEZLxwTHUOA9ymbKcXxNjNjWDO3HXm7kpzd8G0cRavs3hXm7DXROHwHqvvQbO4h0EmHrGM
# DATA 2XK+k+bLZlKAk2gYM6KjsEp1701hCi4MNyxstjeLu8AZZgMjhUbttTsDgJCHt3kTOA9NWBA4NPfRuG6Yptr3xEP9T5kTgPFsktDQ
# DATA EU71mMt2+JAa+AwmlLIDwr1JpPGVi0Om0j+kkLo0VJvkwFW1MHCyNCDEZdhzFLEmnBdOUaEpwrdtarsmQ0ZPeXsU3hEDakC5vmJG
# DATA IBJvyT7vb1IMTs3PHWuGFzZyCijkaTTpxNjvmIOgSoZzwbBonyVUqLxkJe8tcLa4G2VvGkO7+rC5+C4GmIBYCXfdu9GU+1lOBkyb
# DATA cDrnb8PBNRNZjw83gH2yLo13tRyl6e91Ij/ArE2zd1TfD5XJgmjuaTARHsH6IxX0IC0wHSM11E5tdImZ9D4CQ095CBNMbbTkkWXC
# DATA Q1IblnbUjTuhlKDCZyIrF2q6hTmLntKYNzhcl8r3+UixMb8YX6LTeZd3eqpDIrNJAZ5kVhgf6uLn6aMi5cSAnyjzdQQlPiX+aTHS
# DATA OEl5pcqS9yiKnjAlBG5Z5nkgL/lWVS20YmWOL8P+U+GGQG0RDmLtKA5TntSGe6MkjdMFMgcbYifpfD9OqGPi/My6IG41pyZFs09b
# DATA j0EXwom23NyqMcC9zU7sSyBDv4fqq/fBUHMNUXVF/11PUy6BEn0v5yxHm6XyFrrsJZCi342nPCubULcFIUiBQipmDfecIjB5CbDo
# DATA BwN5JzpITm3WuHia1b0EUPRd6oB0i0cv1TX6ulyk8BZNuhfMTn7R528WF4eemqY2FuefAcE5+u7oq+NfH313/I9HX3vHXwBRQ1+/
# DATA psvfHP92kYzzL4y6+VeG2uTvPvojU3I8+ulXR787+vr4H1Qo/xVcHLr2/fHf4gl61W/plz/TC//oHf9djrRjwXQcGuc5IAszmM1o
# DATA 1wojC55fID0Ksg1VuMA97rYOAOU+UBbVXsSKwU/gcBac8FSzEhkyyoMoGIJ7g/UEnHejsMdvcfib3ByT2/tV02+swrg89I0kLesW
# DATA ue70eB42fytGDnMjT/Um/cNpf3iRuBveZEvTnj5qfJdnBEDu8VZM3O6wNyeW2IXzbjDJTdqYY3I90x5r7BRR02HuXwbhZKiWprLJ
# DATA Z5yKK3phD7Xop7NtK3MJKi3qxTCtI9MFDu4F/M36+rfa+Mja0bPC3qyPuSPeuEH7FIO2Btucbqx+OXzBVzNOX+QwvdEovfkgfflj
# DATA tFQ/k2gzIF9dW7gMUo1JjxCS0/mE6P0X2SYGtif6yVDDYKwykZkuDWgY7MIuJ5Qp6IZIkSrGcieZTYRNkY2vOuFylJ1egrzi4Dfj
# DATA 1qgpfm4MDo1zXY/eZtxO6cbubBDpLZG8hAWvopeOo04cpQUT/4xdrBytg1hcrxF1tmEvmh7mXIEqHYzTZUw0o4A7kqh8ghygxgFq
# DATA HKDm4gE1Jw8cG805NrFfr8b+Pov5fV7r28FoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzG
# DATA wWgcjMbBaByMxsFoHIzGwWgcjOb6wGiqtajaPSuMxu8FzxWMxiw3n5ZEU600vWqt3Gf8TKXm+bXq29Wgks+OTq9ZDhb5JzVKQLXW
# DATA +Jlfqc7zT2pBp9Zcxj/hUsoHU221vEqt8p/8VsWrVMr0p+G1/E/9oOk1Pb9R8fzAp3dVvUqr+mnFrxf9KpUhiDm1ol+nW4r0jW6q
# DATA 0U0+PVD7T5UWPVrxqhRCtfmpDy9yzavRPdV6Ll21qNmqlxcBMRKhIpnwRd9vDv0a5QteVC8DzzOX1k6r2wo7y9Kq0DNUijGZH4pd
# DATA UysHGbum1ipbFbgmXw6X1OZuJ6p3emdgx3BFNuwYbhMWO6ZWaYRB9UR2TLvX7dVz7BiKT7PTttgx1XqLAxJ2DHUSrTCy2DFB0K7W
# DATA Lp0dM6BWcCI8Bk6jz7NbDeXF4rio1C069ti5V6F/mz+yze0Gmw9ZkCcjaWzeDG+2k73Fy2JhXFelJeunZGF5WKr06vInF5qnLBoD
# DATA lOFR1PT+OXKNFPFciilMWEZeIH+Ma1SS3YRxZftzfGuNRwXRoAzz6Y/6V1uYbL3ygLiSVrNBWeazLj/HXpoRKwNyUBsHtXFQGwe1
# DATA cVAbB7VxUBsHtXFQGwe1cVAbB7V5yaA22iDU0j5bO6+tG80YfqN7fT51oR4roA9c2rV6KmVWpdq9E+vea5dN4p3baOcfbt3L1Lxw
# DATA WMWScxlRDitNF0xf88wac/LBnRt254atky/u9LA7PXzS6eGVWpOXcqr4ddRcKM1lgZuTxc9Uf+IC9NKhNYc3H0TREz7hKG32jFpz
# DATA 2dhycWpzUTRQqtxtWSWhDNHqg8rRfQmyc/q8sQK3jalUuxNoz3k0R4oGh5egOffOCIeap9LDpkopG/ZyLxOovgTxucfs+lJpJBNE
# DATA 9eZUJ2jsKEL9unsJunMP5SgxfIBkyqkkG7jApZQra8+9j7PWoRGgQ8uTEQ4mC5mX2As1m0QXrD6nPDBGOj7TZMwpA2SHW3VCzKlZ
# DATA yjB0AdNcD2JJ1Gei8CIBDwnVucP63BuVMnXN7uRQZ3SGaggHB+AWDiOWkMctWKgiQ2MwKHnvxj3THArAPQwW26JSUR0hKhOvTz9O
# DATA IixYDQ7lSe5eDsJUoqOJQkqtluugqLyjscGbK9rVNKnAEvu+CoBaB0VT6ksfvsGJOhEPnUx6tEdDyirJAJ0r+rg/dZMjnHznbQY0
# DATA nrAUAI3U8xI/cyPVwwjHAdUpbpm0yh0y7pwsG/+cnzx2yElnv2f2u7PYXziL/bRIyWeoA8SL+WYhej1H8s2Y5c8VHAWi5yOP9/Ku
# DATA gUhesXzQtZfTuAw+ZCZydNFwSFsO6qxkSGuTgp42PcSxKlMdZOLHwilKeKoyV5DY1SClqHY3gtj4+kQeBg0AW+g0tPGuN5gN41Ey
# DATA oymisYlGVMkTiNiMo8EA0u4YQ/tKcZ3sr1HJ+0lb5PbJMMGma2gp9ckkVZgD5tnot9vReAsGGt/FidGxeB92EQVBsaPKS7XGMrvY
# DATA 5OPzIxFvQzhMoaUepiyhLi1EazwPIWE9Wfd+dkN7uXe/JS0oJfMy5aXokvdekk61/SfiQsz+0bG+jQyS9gX2EpRvqL+GbQBhe+pG
# DATA qKqzbMh8TF50kRirZ3C2mrPV7JHBOVtfXmfraubks5RwfI8XK3V9VgJsfPTaglJCWo/hCPvQbpP2kzlvCuxGYMAkO9G047DkPcjE
# DATA AHEKR1TaDNqHy5CdBqGlH8g+TfYd9OKOl9J0v2M8K23eSpZpBorm4oYakJxicXxkjV/W+hCTUTiZaJ4QHy7Be+D1WWIkqjOOi7RL
# DATA tc6NSsqflJ9MebL0jxkQ0VzhHAd2JOJw5GnlfkoGAysFSwmQZvGcq4l8flW2BKiXW3eYjtJ+6tWEO8zMfYfVZ4yYg4FeGo3hD02U
# DATA NTd/O9kN3KqSg9X37LHZw8gs/rT6zjbbaayRPRErRd95U1KV5YOMx9pbKCvQtp8PQ8MaV+Fam9HyfIaTrnHC84K/uONVDlo5MAeS
# DATA 4p3BpvXLUjpXocmMc+KuScB8jCUvx2yw3YOIYzyBkCnqfWa2wl4rKk3OgkiMFjEz0xqkNIwNk27Efvwp7FkYftqCE5SS7UyEA9JI
# DATA dUYsNKSN7Kn3CxpwS7Z/dUNfqme2ybGlkU+KyRotYQbAK5a7uRHRM5bTdd6WPVXxZJXvlCX0aHUJ6WoshfRozD7YfAlRM+aORDzu
# DATA wL5AK7NP9o+4QUNP6rqy+i12oFkDwfOyCiJSqwnURzHlQOliB6OyUs5fNnYKrn/BPNi0YB6EkwGLyoaDoS6YR0mPYawjGtVYM/UA
# DATA kzwaQffyc7OSd3c/iTEzprw3bv2C7frmUhlT/4LJWVfNEjE9PHd52BG/svLI+t5TlsdfrS4P3YtLefwVGSwLHdms05kNWE0Wi4Dq
# DATA JKFqHHqyqlh61EvxSgLOY9OQUfLeptZ1WKAiJDMkiQeicjzkXiwZDkX+mYyLobDE6KcYOWjWi89fUFmKrn8xPdy0mB7O2u35/ux1
# DATA FrFWvVk0+iQ5zHowLcZV8j6IabrbnVFHvydLUUY+Wa8KZRYemNqUV51wJnS8c5eFHe3r34m9uWkn9no86fKOgREcQNQ4Rlbj6Yvi
# DATA dX82jLtFLBSyxLgqDx51UjbsIS00hWX+Qai51Nk6v83bQwmb3o5CIuNJbZuAFjLcQ+cup8UEnam08vafbGO07T9zRfL+zvuJ3nCo
# DATA NbjF5BeLm5f+GWoZ0owF2aFLWS2cXg4T7bn2eGUstLSfRDkU2v919K/HXx797vg3YJUBY0aff3X09dG/HX1Hf/+O8Wh/9Bh29s3R
# DATA n45/swhG+2fGqH119Cd69vce/cUBHn1ToBCP/kDfGH1G//v+6GvzEpukRjf9+ehrfFIctX8DFQ3vl/d+f/Tvx//oqGjPAZTbbHPg
# DATA La/J9EBjVw2ZG+LFQl4t8MyIt1lFMPE0CwDQULgTWEaGOgCBM6ADHYNuoIiuVI8nU94zhud6soRlnALwdKwlp0FZHk1B7HyHT7N9
# DATA fdxFXDU9bb5ALg+hRqNFOEj2MsQX7zDkl89zuG/24qybfjOeWviOi2OowZRW5zZQQxMZwTkbHD7t5NK6cH7ae4IB99pkXGBHF837
# DATA +zTumOllQRtZaYLDUMhIGLJIJro7tacV8xtFGn8KlZQo65xY56tANpUsR04i9iwyYVYfExhSEQleA4PVdIGttr5erjZi5lrZswKs
# DATA rY++A6y58f+Cx38NYTvDsP9SLO9dzZB/4SP+RgP+Kcb7yx/upSLmk25G+evVfC6D25ZPOA+SnCEGOmZS3T5ESAU5wziZyaskrlMB
# DATA OqXDEAtfZunNk36pHaVwaUUTLE1yommgzo4tqOh1455hu1GyDz1FMtmQ2TZR5hpvq8GRFTIo2C8RdZ5gbFJoMq5jwr3iU8O8E0ho
# DATA c3HKe6jSqdC4eGk2SqdiKiBfMsvhtqKYgZ41nVEIw3A06+HzxDYSlOcVfgK2aSaHxWTkkG0O2eaQbZeIbNtgdNloorOJSXyFdv1Z
# DATA zPrzWvUO3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBt
# DATA 1wbc5gfVTrV8VnBb0KtHvecI3JZfcz4tvY1sVa9aa35aD4rVutesFv1qZUD/VCpeM/D8Mv1S9fwKfaoXK9VBveUFda9V9iqNT6s1
# DATA uupVA69Wedv3W58Wm8Vqw6v4xWAuS6NWr9Jtz0HP/EatXq0tg561FkuuUvZq5aAfNCr71frb9DX/AhNWnsJWoRRU6oHX8It+c1is
# DATA Nbxa02uUi36DvtS8Wt2rN+nLxhHzqwsxC3xA4hqfFqtUqEXkRf09CgCxHVTpQo4Wxzs58y+Leo36CsydqsCdeMIn7J5Kpa9k6De/
# DATA wSA5VjWo51uACZYCgGHjydNlZK0nDzeb+Wrf6/F33f+yHCqLv1abVG8ojFNi47gZaWyctEgLGxcFzVoQ5LFxdFOtUs9h4+ZAcoKN
# DATA a3VbGTau1qkHQSPDxnU7nXYvw8a1utVWObp0bBza38nYuKo2CsQk0M+s4MchmXP+xeBHXo3+VOlPPfiRHcQcL+6dIU0lpgVsBUZ8
# DATA vfdZsYO+2jG3p0lBuXx73pkn7p5Cc/+gwKtkK1bEVDQArxp/tulSQalm5YVXneSD8fR+ipxBYuZL2FWtXXzay5ln2qlMqtAfP9Am
# DATA P/uK4ilZWJ0cyE77sKlfrizg58qr+XIm9wt2DqwxRU5IIFsJjiPnOHKOI+c4co4j5zhyjiPnOHKOI+c4co4j5zhyLxlHTlkc+Q4g
# DATA HlH4u7D3PtySNkcJvyHfoQjD2cAm5odbj8MJVGj5EU9uRvO6wReoWryJzXTb/s4Nyo3OsPQh/Te6a50Sv//T/DE8fvi9cNov8Qx9
# DATA m8P5sV8KEEJ2vG/JofFM+RZSXKbb16i57NiKO0TtDlFvcojaPtrkzlK7s9Rr9JKf7RlrORpc0Gd9l5y0fmjOBUodKeSV1cyhXjmw
# DATA qgRZ+Cwx7OgDpcMsJ3kjVtnPDk+Ow0NMpuXwJLRWRtbJyY01kN8U1eO2MKK6IFDh1aHp0NERON3jTXSPO2E6C5VsGj6tvhNdKmUt
# DATA bv1APq6+lzrYbpJwRv9EPj4PCshZXpxSBPHeahFEnasigkhG2eSwCx2icLQfppkCIk5OUvOCgngnYbfJbDzGuWdsNMBhNG8ispAp
# DATA 8BxymJ29YNTUopJHrTrG0eE5HR0eD7uTw4IXhekhN5Tz6x7OpeHKJCqt+ndxiqGmJiudatgOkxnMyKxsOrO0TzU3YpFcnEGXI9Sh
# DATA yFWzmZMZEbAqYZcIhgEF1Qf3Dl1Epkyt9Bz4ePgM9QP+0rZmnpxLnTpLwHNQMB9sXDAPqaoX4VY5hAa4pRzKB5sLVCLjiFsPNxvd
# DATA QBgkg4Kj/ggNR+uG4hwhFKugGB6N2TZEhltqGiI4gLUtGd/iQT+ZsfTo+fVdc0m5slI6c+f27qad23sxds5Aw2M2sZSRaYJCcz7s
# DATA CpwmY910evFkCHHS2dhTBZNMWIKNfxX1kgNK1CRpS3c3ifCVdcNmoz4ZVVA3sGU8zlMkuZhfWYlYg+Qpi+Tx6iIxw62UyeNJGA9E
# DATA LyUks8YUCn2fwjiB/ZZIDndp2gMjD1XT0DAnoWoOSrMaMGGtNJMpSWRibyLCMjgUtbdzF0w++te/rTzatK18IHNSmqDGY6rCpmBQ
# DATA u2E509RdtgjBsOZhnKejUPUYpzzeY5oPHi025ipkViqa4UokfMqi1ihdeE7PXRRzMX55tY5fBDkR/bjzbjnv1ibeLbuKOe+W825t
# DATA 7MVa6QS7HO8WC28ZAF7o7SWJiOJp39a11a9d5/vCkQbP9oAtOLWEbooNI2ofsr6W8zap5RlGM42w/54nqmqhdLsz3FFuL90wZVKK
# DATA UpRQzfOmK8uuGNdPhXfXTtBzoxcbxmwgVXhb9TDkLa96I2805q3XJX+1g4xXkFDLE1WuY6NalveTqRtNzPSDC64pXxF6Yfd0b3m+
# DATA 1xmu9mP5pYAdCBRYHE3o7lKQu3/Bl6UsLOMolE03FMR9LV8418taZhLKj6LAh4t0qmT3lW26ZJekicdino1pPJzKhvSbEsQ5DSAx
# DATA UjAYWe3NVrN8PBH3qxBj0Q8sqEQPWK9xpL20BZkxsA3HXpFwL4xl1xW2xAtGimYPJc9A7rJ6WvK40Ao8+FlAFhavzIKEXmWqrWO8
# DATA DtbUOB4JxgphkkVsJAixoMgKajg0BknH9qE0TxHmC6FAaa8iprM98Gt5p0C2hqmmrSMtQcl6lZns5Iwt1EPPbBfQe+LGbMNovCyy
# DATA +oU3PLOhxpmezvTcxPR0tuaLa2uutA6voVo1n+gwpwsWzbCBZYa+BbOTYwUK+SSSZcJUW6HZQyy7xJ3v9VO3vv6Sr/y3nNO58yr1
# DATA oPMNSx8LRLjmCFdTTvhZZxblQjjgb/Mi3PPH9aSZdhJMFuRdh6OOmN9G/+rOTxZO+/EOPirEBXFz6yn+wmnZQFg8O7ai7bE5OPhB
# DATA eMjTF+g5G8PsHi/ZyeRoZBYF4U/co5DGh7K8KHMn0AjH4T7PXUreQ17OmmoLSt2j7DPUSriMxRnHBs/8WleI9XCy0jStY6NKMF+Z
# DATA 7j8dDxBqGj/F1nVZhpTqfeVwjys3njJMGVWo/WiwN6PuwoaV/cvxl8e/ZiwZCGLf8Oc/AV3G2LDfgyiGX46/XKSU/e/mx18dfXv0
# DATA DVBk/84Xfn/85dGfcKngHf3h6CtGkf0a33EDv+747+kPQGS/o9cBZPYN/fwVo8y+pQC+w2/HX1Aw3wJWdvyFR2F8RRf+HheBRnPs
# DATA sufCOkTaeOoFfwjLlevaewtE0nDyBKt84SgqwO1Bs9IJzx3HoUx/MMjQDBVHpXkNCXoZ3mzEgbE2+SweMBuVWnTIuzlpYhlOBZIa
# DATA Yas+dWZrqWUCk45koHTQMttWtDqMq0aXzZXK5ZHLurGcw0zNnW+oK1xRF+hlGPfMnVTppCZOLhhexvP8OOUNCGgOvDNMR9URzDYr
# DATA tQunmOnOphfzc+FAnEpppx91Z7JNZCDseEh+MMiZezGP1V49PygO4xFs7XBAlRv7SG5rTy+jM8QKm0QUsIAU4hG6YDEDlWUkbXJg
# DATA 8M2bVs3VJk6+qT0rfNnayDt6mbMALswC0Nyy0w/8L4WD6CoH/Yse8zca8k854l/6gC/1MZd4m152LZrPZXDLcin2Ipmjp+KRYgq3
# DATA l/Ty+/Y4G6Z9iuUer5ug0cXYp2ksI0YcDcMxJ1xeiz5Kzg1Q7QR1CUstGpkk+zV5xJV67xlxtnRDbBnnnKoUHmXHDK+TAR9AEHGX
# DATA HWjDgIogRSy9Lg784OVPRsmBnI7oqs2lwEaNIy7qfjKbgP3FDKq4HQ+QVbDuGLRC4xHjpmAsiAYC47nMGQIFcholy+FTjmPmOGaO
# DATA Y3aJHLMNR5qNpjwb2MdXZ+KfxcI/p4HvQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZA
# DATA Zg5k5kBmDmTmQGYOZOZAZg5kdm1AZpVmLWhUzgoy6/XCXvk5ApnlVpxPyzGrU56Ua/16vblfbdXers8jyCpRvdNbzMmyT1lZ6wfN
# DATA Bn+uAjKmPtcoY/lzs+n5lMPVWnnoN8tF+ld99vXnOagX5Xy3V1kG9ao0F6JQCSgK5cqnfqPs+T4QbF7FL099uI2bJ+HDGkHY6Cx9
# DATA U1BfwKH5jQBcMq9aKbZqnl+vAYLmB5RxfpXJb7XWCa/rVOvt5bQyC6JWxHQghEC/1GivtQRkRnHJQGYUKQMyExxb1gJq1V6jsnH+
# DATA 1pe8qlJuZK+q+v4lvqoqRDZ5VaXeuMRXBRU7Vc3yJb6qzig6narqBWfgqaBy3KVpqJz0jhZUrlapV5vdPFRuHiG3FCoX+VGjG2RQ
# DATA uaBbj5pVA5Xr1DtRx4LKVem9zfqlQ+Vkd2FRlhn0MFflGYSnV6eM7dIU889+Zh4K91ZEnXkcFhbpb7Vl9Df4Pxv7B4W6+D9VyMNw
# DATA M8hbqbHOramnZ1mg8wsktnmvy2fBs6lKJhcOi1uscH39ZbtJHVg37/Q6nR3msbsWS1WrwXBWVq2x5xbinJ8WXaJ16BhzjjHnGHOO
# DATA MecYc44x5xhzjjHnGHOOMecYc44x95Ix5lAX4inN8CchtNipgt022LndO5+ZOck43eV6Ir0Un1/G1Y+sli8Nf/eOafZxb/sH/Khq
# DATA uDufKS6dVi6CGKqc+WLE0Zi7ajEub38ur+7OZO151w7ox4K7w6UMgcdcOlnSse8t+js/9oMbfoDo6NDuSADtGc0XUagmZiw3ywq0
# DATA oyjqpuDd6WcAyRMZgtRoL/WiA+lAxnIqT8S+6BKfYMwlBxmNU4y72qyf4MWSVbL4tM0Tup2SLD5sb4eF/UJMhRDeUIb2/s6Pt2Nq
# DATA GuXX6uVb/k6hjE1f3Oqx/rQ73L2zPbyz69dq5dc+3HqfqiQfseRQkUHK8OF86g0SmrMOb9bLOz+q1HZoBtZlPavtSuHDrTLu5sf0
# DATA M8Mf0Y2LN93Oao5kOWrAdsqxVlUHzqNdjt82Us+owf/44p+QseltXLmxu6wwt+NX84X4mh/cKuvc5FBvf75T+iSJR/Qsgwsl0urj
# DATA jSWv7MWjOO0rUVQ/0IWJ07LicBEA4k9HUJkQHACeZ+jh9lyFKepasWNXC2o8XI9MtuxQJG9zgVNJFPWsgp5/bZ3JyC0PjScL5zOM
# DATA g2QMqUPHWjlDi1vokDVbUVc6M++iwPV56NL0KfoZK44S9iMdpn6IBlyEZTCN+iCaU4pwShHrlSKsY4pOL8LpRZxaL2KlTuml6Eg8
# DATA mE2zBsC7trSmp4zsRlTiOsoYXYWOvRgrIuM+EStmTrkelzLden2/6bzMBSP0Xm7dUgvmSrh+hR69GnBZkX6Kk+XMQzLC3ttq5D1J
# DATA Sd8EY6KUXcmU9GvlZVL6VVtKv1Ep21r6frBaSt8yaBB9jjhNTGhWxdUqL6efu9nKNzuIBbV8jtmdalnbH6t19Wscz1pw8p11DrO+
# DATA JMwF7X19gJHSzQcR7yijWJhBaDl0q/yiciZjQmHSwGnKl5t2fMxnQq6c3svGMx4KZQJyx7o8VyAX89qHGDe5xdtvza5ezkvl4KNH
# DATA A+2Euoncm/M/ZXjPrFxW0hGkJ1OYgOcXifAu/HsidaOMFW3J28oZRmOmSxM6y+7PdfJsBkH4I3eLEuClKszaM5CcYT0NhhuwmINm
# DATA EKzSoMmLzthUsEX+13JOmGRgbv6AkVCvULBvSw9BNgTsRL7B8y9ukbcw3LzEzUtOmJfk7E83NXFTk5NnHM9U4g5jPCq4jgQyZ5Cp
# DATA 3L1pJiICPGDNJ9PWqPTClEWuIDjFmmNGhKogymnDUByXRghNizXMTy7m0AvYZmNjv4VHaxtgwtf8QITnIiHMwlWK9k2JoQqdmikN
# DATA M7ooe9JPZ4jmHv82Sw9pzB0x04sSKJ1FQUGIZHqkB1oG0nN3kT7RgY77yTTZm4RjHqrHEQxpJe8bT1h6TJKYH/amIWOV30smoqyr
# DATA xrp5uKkgki3LT1Ir5oiFQ+OODH3bgcIgY5ug6tjEd4/VqQOgyKEPd1f4aYKV6Ic2XhQechAGWGoNvr11sY+7bNWtjfy88SgpMEgB
# DATA gQinhiAMFf+pAT13WBBO4S+0JnGmrCcs27z2niqWNrps4RNYvXYo9XdNmu5ih/0oAbl1PlliJuS5sQuqiqYik1n4AO599WbkK5lt
# DATA fRB8FbJBsoB/ALAXkcdacodl22DUFFCJRpIUMO/gvU1mqcoPFXBM+XB3P4m7LEnNKm0AKEiW0gCVMDF2CKm1MZ90490py6f0HOu/
# DATA FpqIcoDLpEzHGQvqOeHqpCezMOjQDYdJVxo3Co8vm7Ly9OG5pNeDT12XndawljIseONZmywU6znWn+NGGHZhAXkTrsNSWWnsYngx
# DATA v9IDiZ0GHbK0U2qT65L4CGhwBfeaYhCxkghCmbyQeoYY2l7U3VFax/R8bzYYHCreioopu3FSrqiS7mGOVMjKgtInHPQTpY5IHSR2
# DATA glIRT/poh1Jg6OPnEbVimL549rSjhTlbemM1aGc6v9Cm82lZYc9YHdre878eFvYYI4GGXbJRJfV9PS3s+qhJPxeSqicRJLJ9/5rl
# DATA dZFQsbxC9kUzxeYVx5cixZT7jdW8Uai8C42MIKkRqZg1ycB2h0Zj3YndeZ+1S4QrRlMV1ieWSRO9j37HPW/GmeWM3gOS2SPY5UIj
# DATA o3qT3SszE9i0sjs9gYUXQ4rsUN10Mxmsap5iL8PORfXlqUW4zMG4FhMCV6whOS/oj8MCYxni8QQ1Oo1MMxMF59BMV2WbDRn2Q9xF
# DATA dm7O20o2N0SLbS10trR5Cik5NWNRcm3gLqyzLdh6L5qVl2HNDqK2Er+2qWb/29HXR/9aPP7bo++ZMvbN0XdHv2e6GH06/pvjL46+
# DATA sgljx1/iyiLg7P/G5aPf0cNfM6Lsa4++fEUXv6HL34FMdvQ7j+/5AzPO/kHuO/6tApl9BZIaveBL+ve3CmTG8fkKcTr+OzDQmHf2
# DATA +6Pv6Qe6/4+Obfa82LLSyNHwtPg6L1kZ8ibWgWgOJ+riPHlLKLgpWj3iSK38p1BZZIa8eI+SffbyhJPMq2SRENE81qLM3p6PhsOZ
# DATA 2TZt1lFcNc1sScFcHtFMfCrpwsvV9fnbZQeBufthlNII1JEBmwvpgtFm4l4SPX+4VmThj6kFDmy2UeFdONfsrmfpnWczA1MDeNEY
# DATA QjqzAVM42of4G6cplHsO1BOJoNg59x78lO4XTfOC5lTo/S4GYsL2zz7gxR5dHCzwzDasmattnMVm96zoZhsmxXHOnDVwVmtAY83O
# DATA ZgS8FE6tKzQALmP832j4P93of4WDv9TPhZywUGfPpAVdBtlsIZFMN6OsShejBcaZLCt7VD1RU28J6Kngvf348YNHBXWwVK0Mc8nw
# DATA ntEJ2Q+8ssPJwAgNp0RGU5qostSeB52neszdFG9mqoJHeQ1lsLwBgJTFHWDOMiMgDzgbT6IufCN5o8A2BgrcTNFZeDAwRh1lHrBV
# DATA AA6VmIeCnOL4p/SajG7GTpX0MOWjlOqetuObOb6Z45tdKt9ss7Fmo4nPqQzkq7X4z2LwX5i977BnDnvmsGcOe+awZw575rBnDnvm
# DATA sGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe3Z9sGetWqtePyv2rNpr9NrPEfZsYf15I/QZ
# DATA Z67KPKaECW2rVskdFvPrlXyuV4XlJNnezGVctxkFUW8O31RtBoGguubxTTXJYise8m6Jh7CvsnhU5w+tVbJo1Oaxdct4YXWLF+a3
# DATA moZBlSOk/WWt2/Qb1cWa06xR1Wn2pc5ZyQvr7VYnXMpPW5e8ipDSLil5FYvmtXHy6KELS15VGF+XlLyqevpUyaOHzpW8aqVyLRpJ
# DATA tdq8vEZSrfvnaCTVZvncjcRO3oU3klzyTt1IkLzzNhI7eRfeSHLJO3UjQfLO20gCv3ktGklQrV1eI6FYnKORBI36uRuJnbwLbyS5
# DATA 5J26kSB5520kdvIuvJHkknfqRoLkna2R2MDWctOrBcF+rd6vtmr7xVp9WPRbda9W36+eBFBd3QjOQsNkS9fQMNlotmiY1Xa90gzO
# DATA QsMsR2HPt2iY1XrUrBkaZrvT6XY7Fg3TD+Tny6Vhqs28MruznD1q2c3wMXnCTia67VRr8Rr7km0TuVAxf128Z36rwuKSWZOXzEpN
# DATA bJWRRbNcqGrBfG3IdV49yz+mZ4HLNxtmd9Nscm8SDnNrdCclVz2zZHl+8Qa9Ur+Q54t3Z17EVTsk5UW+FJG4AhYCwVLDIupTVbv8
# DATA ckGr1YIH5nTwTvYYLUkVuw0XfM+L24VWcj8drdPROh2t09E6Ha3T0TodrdPROh2t09E6Ha3T0TodrfMCaJ2LaM69uK0Ailidg+mp
# DATA 4JiaQUVXbvrlWjNo1G/n5izqMT48jMc04pAM89kYV274eLJSu63YmPfVMXboB4ym/cGh4VwxIpFiQvXqTezv364wFvGt+HVBKr6L
# DATA c+ZySnk8mKUeBJs99SJ+VkVp1fN3vUrwI/O2TGhH5qWUB/sRozq3KQ4/xhr/zrKQbJahdc7UCcI4QZicIMzioWOnDuPUYc6uDrNS
# DATA SfkyVWN0Zw05CGkvKC5WcsBGG955Y0nIXB8ds6sAGspQyaAPGchYhYOvngAS1E/muvk0h2yDG2EpSNC3OIJ8U1nfaXCCq2mCZjgH
# DATA S1B9RtgsWDLGoKiT4G3/dfz6SUBEKziTFPuaSU1wcloqp0iGWBvoAeAVFZNg+72T46ufM5E1F6yYbpbpG8ZU20HcTiGUCMmRzG6h
# DATA rmscRydVlyyQDDyZXTJRb5wU8/qaWK+E/JkuQE+ZeDxUhfzcQ/+Wkf6MhRiZ3g89E9UxYXlw8+gaeR3YBlyk4ZDnALw8w4Iwaq7Z
# DATA oUkVq0Uz1AR7I2l6U/AO+lT5yDic7EVWaCp3ez3qa9uzCXwbeI4mV5MICk3xVAv8KH+1zDxSluVmJSaqUodiILMOpl3PSt69ZMhu
# DATA Mer6CkqsZ9Q1+k+Z6JKazHXliXCidJEyWyaDzA4pXrMJ+1aV+NAG1MAXTSnGMU/cRGDFRMDZ/C+FzX9a0sl1UYq0d0qsR568FfOI
# DATA KWqJvB4NkbgRq/ZQ2xpGa9knz05e8vlSVztJXXpuj8dlgE8WBTQvGn6yTId0KQAlV3Z6S4xU5GWAvzdhz2sTYekdrOq59o7XxbQ2
# DATA hsYp5b4V+Y9xlTELDgIkIhqf4VTKXJmbm+AwH2XTbo1XfPvxe+8WvHuPHhXUOCzthYcFpeUOiKXMi0RocQyV0FArqbJSI5WCkf2M
# DATA 02zeoMF23MDjKYbtNUTFR9IZyIa39bDIu1YkVCXWKboLJdCRkkfl2HGCKGHdCDS/aNSBIugoovgpPdYC1V6qrn29zCbyrHlV1rVo
# DATA znwHckLUteCsWNM62gqmyAa3OmAYiT9DYKQw+0X7ng3oyaGSxFSxLHkPNKcGMefVMd2RhV4vjAezyTqa5UMJBgtXq3iWL5EFbvfX
# DATA zgZ3NvhSG1xVEueJd574nHW30ni/PvrtXKcxUmc459ATT6HxwIuvJk6xcS/hQTIvPq5d6PP0s9kYOMGS9zPsET80iBa6ozvrQERm
# DATA iLHYSBsbfzsTjdne2VjIPdMtkOaJr3de1YbfIxzz5oYN/YpUAbBlxqH6gldvGitxKr33dIKPIsyNV3XEWU/2xiShMZgadn/pDT+V
# DATA Mb0HavOKWz6AyYZUihY3i03j1pt45039fhmM5qOhDFVlwBmLh9/UvfOG2pzINbjgYVjpUd+fUJkx9pOq2rTLd6oxouDJYFzQUtvg
# DATA 3AFTnPYl3K6K1op4vBeOqE51bVvQROZuJoE/97tEwTbdjP1FJTqJIN7Niwfa8jo5Ij+LJ9MZFNVZStyKgypgNvO4trKkPPcpk2Rg
# DATA IvOTMSuqmBuokkdTVkkf8+BJGTQY6KqeWvG5qQrqpqp0K7j067Hfj7Sdl+W9mHxhd0iDvp7lZGwfrSSuSO1pP5kNutwuxZwdwfLD
# DATA xnNMrURdXQq45LF9SRbwIDkcchBkn4NnHUIc3pKhB4v+k6TNA6eSmJ+NmIWoQloHBB8lB0qvXJvO4bSvo//BhOXsqd57LG4izm5e
# DATA b9F+Y3Y6kzVOwYTa24xeijo7vgc/MCM1s3GBhAJkUd/OEyOQ6kdwsNNwHo30vV3FeszWBtcl5j1xRav0hCKeD7+6ce8rzzoiptcz
# DATA Mq5CPxqMVX8mC55WX8Qy+DRQJjmowjgKn6CEpcdE3cOaZTca4gX2DEuBFSgUmQ8yFh6twJ6aKTvGBp+b9U/Uz3i4IUP8xbLtP//8
# DATA o88/HG298hcv+n+U9dHgY3QY8WgGqOr48MLfgbXLeq32F2rdeO5fvxwElb8oZ//9Rdn3G+X6X3jlq8iAGdocvf4vXs7/fvjDHz6c
# DATA CSGiQx1I3OVxBpViK+W9yEXGfmQVxLv37jvUa/AyJ7XvZNDlJXx6oERhvSJSKWTb7vFhG/39E7IP9eckfYVHL3T6g7jtqcsP6Ku+
# DATA ZWIeTGdt5Z/RV3AkC8OB/j4j0+WVVz54ePfBg/sPsYF6a2vrFT5j84raYNmTfdXsbNqmyWQ3utVLt3Z4NyNOhmyBwXeTesWboPre
# DATA 7AximsFs3X5Ftlr30hLyAW6+R4ejzjYeKnhbNF9vblk7ULfYKVRE6MUst7Z2drR/qRQ9jafb/s7tV+b3feajxufIPlYP0RuodzwY
# DATA 8ZuzgKIOcqvg/VxFZvm7Pyq84nneZ1M5RXLL5+0OhWH49PVZD3sf/Xq1WSs8ISvzUbw3Cge3th6989Zfv/Puu1uFdNqNk1s/36Lr
# DATA NDxsFbbG8Rj/qO8ffb6jskdtTI0mExp6fvlLvVE15QDtC7xYLhtfV2eJ7CHezZ3W0s93MRZME3WsQuW/jgY/+BoX1CG/BAej8Pof
# DATA yOGhUpw+CnvRO2QX7eGQAm4vIb/uYSV7B3fOXfNe9crLLt/h0zZL06CvqLgewJDZVvGdfyPdn53amg/K+/wVVOJXXqEpNNyUHzPd
# DATA aDsepWMahT+WQufJ/84tFDGygFfQcQk2AH8osTWRYgq1vVXc2sEPg2i0LQ9SQgK/gmt4chKVsJ+AtxFvT7Z+frf4v4TFX5SLrY9L
# DATA N2/9T8WPbmzlX4j/JiGmcj9Dwu6j+Le33hnt47SP1ZPwM1s7/IwaiHe5pecSs6MTIbdwZdmmmj/9GCd1KaY178ceNvSqf9bHgcP1
# DATA oqcdsnVTmUiqGMDenHTRG6A/KvHuh231TlSdj7G/entnJ5enKcV0Go46qIr8eMHD6QGTnerqDlU7z98od9RUV2FMo4mKnb6+q+P5
# DATA 8/JH8oO+EXu+5SY+lLj1TpeKZUs9Ho3240kyGqq94fZ9NJ3rxXt072ef78iV+6N9ORJkJ3W+EoTFHtWAjz6r1z6nm00sdnSlsbLG
# DATA evlc9li/7KjGc55MwmloOeDCXzFZl04jHtk5kL1isRj5/gKO3nIkt8jOw9MSDF+YzF94Wi7PXdrdUntW5Fr2vuXJ+ukonY0xXNHs
# DATA woqmShT+49OeH1PKpKfgHYPb9JqC5+/MJ2Z5a/34I6vZfvRjehKnVk+Kmc5wu/rQc1bMOMtLNDxGo646gGra62y4jULGLSWabFD3
# DATA xuf8UPZYh6Ds4adR8pWgvkHzvW9FY1kT/kusLcGx4Q0Vx+uNpPMEp2vwD1U+enByyNOngsyXO1wfcZIBBYdOWWB6ZPqXVJDYgUV9
# DATA r6LlwZbBnJbpfWqR6LbQz+CS0jN/+KBZMhTTxbQfYv+VNFfT++1SZEcRXxRHljJdSo8j2C7h5PANFhZMJocsbBc/3d2iF4/CzgwH
# DATA ys1Ijs6bpqpdfXOWgVRqHysrhntVc8uOd9PbsmuaeUT7zBN0J0laAiFsW4dTwJWffPzBw5+8/+5/9n4p3+49vH/3sf5y/3++927B
# DATA KydAepgwOXX0c6/LoWWvoO7pQCJPzS0Kh/naKNfUQIl2WPqECm5bVZkb3DSzl0zthHNGK57armUllqjAtn+euw3/bXW5lqC7lKfw
# DATA qSjuXXw0uV7Kcn0Xh71gXZbwV40GpH70tLAYdLGoqgSHrvurW3jafOO3GXNaXk7T7GJ3kox378LiWhZuqpdoyD7dHSX0noMiZr4x
# DATA QDKphEIlV0TJbXGPZgpyZ2mAiCVVETypbV4dim41+A4zRQ/4+BlflIGdD/ajApwF09kk+li2UO4+nszUwWv9UazP3Wq5IOumfH0n
# DATA X5BWi1GFqo0o+KnG2/nbNxuudJhzPeDKFrpZN8mWmBezT2xq95JiXyiLfr4+WtWPjTLJ9HA6DTt9O64fLZbasv82zXN/baark3l5
# DATA A3vz/P6w+5lfCMQyYBsadudouq2+KTv51iny1ppkSqQWspflALKXmF972PIxmOseKNomYxejsaaIJkMpHxrGOlG+eDzJpl3r6Tfu
# DATA /+z9n7777oklR0/SLGnZk1l5Bbq43oSAw46aAWAk2lbVmCdF6Ln1DLt0d7LHXv0H/IsqOrkNZ/k+DtXvNAcoKqOb0qT3XlgVY9Uz
# DATA bMIvfYJugy2mHuR/8GiqIpHrsPncxnY2mcF9JRWfgiffeIKhrNmnwHB69/kfCLGagP5Sjfg333jd42lnymhQ1dXaDuuS9xMM2qHH
# DATA 6B4Pu5dG8FJ2PBqfwjEZNXOGyCN27t/HLGzr/QT7uLMa2TE+9DZf78WTYdTdQhlRRfv4Y5gDH5P9tuttffwxSuzjj7ck0lJ819SV
# DATA OMEp9mF0GW6/zfx/lVq5Fvhz/j94BZ3/7yr++8sf3Jylk5vteHSTTAdvfDjtJ6PqKz/84Q9ZuEN4tVh8kYUxrDFgxRfLFck40tBb
# DATA vYHroTajPJ5tDQbULazxCmKZol7T37CnSX/uhyl8g/prDH2wieUEPLs/UVYQzdf+bBoPzDeeQ5hv6WCNFzKc2E7IeafktD8RAp65
# DATA QI0s57HkKM8mA4qx9Jw63nSNJ3/UsfDiiSez95nktQyZ2eiphgXK5Lt2BweTmuY8XvuQy8WUBlvqWEaZRJ9Eav0PGSKzzpQLS7/3
# DATA p+O9SdiNfga1A/3ixbiYcYnyRoYr7CLbprlRmrmLpHtdkhB9m3qUtXtQjvo5GfEtbw3PcvgOy2PDM0/sCt3iXVRbOzo8mVmM2Veq
# DATA pv3Y5bMr0xd5xxSnYaZ6AsVB6+mt/FSK04/TwyE2yWxbxiQnc+vo/zz62jv6w9FXR/9+9M3xr47/8eh39Pnroz97x39DH/549Cfv
# DATA +O+Ovj7+gq79wTv+1dE3R3+mW74/+hPdjh9+dfTt8ZfH/5V+4qf/hK+3PEweYM5LDNSYqKIjhx1LQ1jy2/IlVYYfT2I/Tmxzj9dL
# DATA d7WTpLfKERKRvSH53J0Nx6n+LRphcfPjMO3EsRgl2GeGAXa3omdo4ojpFnhGzJJOapY7fII+Y2ymtqVsbkv2BMV+N5eiJUYDppSd
# DATA PhXZNsJH0a2cc+IGmmsiyvnKgLX6A0wpd3k6udFcFJm2s+zn3mAGtZncT4gDtiJv63so7aNEuxHVHZOIYWNamEqK1fbr0D2cfz8g
# DATA A4JmYfnImWn9x72uNWvPZZ+auj98w566v/HOw/v3Hv/k4X/OR3lhKp1Lh/22/HNL7Wz1LKPglzy78IwkFg2txPU15UyZm6bRHbMR
# DATA Nzn+UbVnWT9WTijj+oYHSqmuwc1UXeHU3n7tVuYg+yj3rfjRZ+VC3f/c+n3ntQ9LOzfUhY8+qxTqVcx17FdbvcB/P/qWWvv/oDb9
# DATA a/QH/0YN/M//P3vv3tzWdeWJ9t/8FMdO0gegAPAhWlYgw25Kom22JYpXpOwkFBoFEiCJCAQQHEASm0aXH5Pu9I0ruUmlbk11VXdP
# DATA 6t4PoChWW3Fs5ytIX+F+krvXa78PAMqPnprp9IxFnLPPfq699trr8Vtqx3+ZPPsDbvxnf1Ec4Cv18itVEDb/o5J6pp58oJ49Sp49
# DATA hRIfq7+falU1cj5SBnYB8qQgk6AOI+312IDTQjYrqMWsqeRrm6ef5Ir3UvAKzapLS8BqeF51BbCzl5qDzpJqK63H53n5leVgGv6v
# DATA Z58Cp1NM7RHwOsX/aHhqpGpOkEOq8T+Fd8D/foGT8QXMl/r57MtnXyoO+ETrsyHhfeZrREupo7NeSV6rsZ4Zixfh9+qs9YHePIXV
# DATA eQoNQ/uPoZuP5u2+4ejE+p//+vlHwMX14rEewNJSo4aFtNTYUVuHN0IcHvw3uICrcdILJgLHqqPX0Ns9TpV7l6t1uzqZrVO6pNv6
# DATA 2NhSvvBC/sm6vguej78l9/5uqX6hWFCbccnsvUrjH8rq6WJx6Y2UFbqBCpwqBFe9HgA3HaHCWM3uWVqBy3ulkk7Iy9e8wk/2VutC
# DATA SWrWijOG7o+36mxtIh6M7igb2knwO9jMz3/z7IuS4QCy23HnP1KFH0FFqpjiDM8eAw9g/qAql7n+8/NPFIV9BeQJlKt+/9qaVQIr
# DATA jO1kGutKHXayjNueQviy02NCnT4JM/YCTsif1dZSS57goD5j2Ub1+PknSqixe8zKJjYmAHqhze3obYzN0bDOx+nOtfX1sk4fLg8F
# DATA uC6p+WZwYiwNv9BmpYrAZkTC5BWArzSDBVpWZAnP0cShiuG/tVrIoQ/lJRfOwkPp9zSM5x9HVu3L5x+rOUEyhmPpU6StT2jfxs8v
# DATA PJ2uOO8UGasJe0ITCVUHJPv8k4RKwENNCbzc2O3YaqubaGHUv9fuueubb6RW7OJuZfpvxRXsKn0Jnnr+MXB2NbL17c2y2YxzEASP
# DATA qJCub283tm/d3q1dXF5Zvtu7vXFza/299Xc3GtvrWxs3Gndu36hxqhoUhh8077erFwHboZc6uzA1X6rONHZvvbOxhQYJHARJ3ptb
# DATA uxu3t9ZvNP72vd3Gzsa12xu7WITvuBUs2jhuPyxcBGHdrf9ub/f2nZ3dxvbtWz/6cW3lbu/m+u2fXF3fatzYeGv92o8bNza33mls
# DATA bK1fvbFxvYZ4smiModWCi6ovhcVWCPXxrCWG6wzD14qAhoc3qAVZqlC/Lr3yysVXgiX6d+KdhtkQaT7/JVGYomBVF7yk791FMQ1I
# DATA 78npF1V284yCJcI9TUwgLK5OkQYVRcGBqLoMQsLninC+VP1+Ajzni+e/ZmGQ3zwSfUpE8OP+Wma8grHCV11R42wSGsR14WluALga
# DATA e3VHPgfzdty0jWbqAw1BN81Ybbq3p76qI2AdfpfL8sV1tcEGtYJlPxu028NM3XHut4fDjrrCp6lRfRBSJGo6xDrbB+/hzgEFDyBG
# DATA hfaLFR6a7LfBSZiUHiikgMq35s8aOLaGM7dF7dwES5kWSKkCOJHVN6l74+F+owZN/3gpLBucXJ8hk1XnkqIcxXOeEMn/5tnvkLPC
# DATA I+C1wIo/Bc2D2gpKAIFKy1L6+a8cVu0cx7gI1Ad8yvOXhfPAI95pj8BMnkUmIyNaYkrkzSQVhudygkLjlyjX/Ak6B9KDd6h8yQOC
# DATA f9RvtvWDmAn7SG14JV+oAw4+UtXBaQUT9sQsSXze2XUjv2/zzDwfBZ+rvvyKzg3uRDAsOoH9BWBRXDpRBMpZCS5qPVBwdQBZVxdU
# DATA fCy4xGuirmkFYiHON/bS6+u761fXdzbgNErrxYp8axteCu+0T1FFV0oCZaPXnrag8orLq+hBq9YKyPTPuHLAupEZPiEBBGQ0eGhk
# DATA aVpQJVkq1vlZ4nTcyFbcD/lTX5f1xQNvkRaDBF4C6488xdmm8ET7VuGKeLsAH3MV9ASCbdr2brhNLiOqXCfDCQFlnOe5QHYlY3gW
# DATA gzJY09r5bW2p4VnbF8ZCCiUlTaP1HkZVsMrPv2eLlQ6hdQZGVJze3B2TOyQ0EHY7CPGjZh//lKWhICt4gh2W3lPP1ukjOZiKntYS
# DATA PyOt5STWGBgwQRVX8KcN/bbSYqVLV2y4/0l/3EOLbQ3Ub3KqsPqHqQCkKms46jkOJt3cXqcK4CL6Vre/3+xubt+/JA+9XqvBaRpW
# DATA n8uMsXSvH0uXwolnCgc4cg7aZSUjJB4oFnE6hLxsPTJeYKBIZdxTQndhUSoiUwD4ccGRxvsH9cNY3OZdXBMqEvKVQWYXxw8rZJIf
# DATA kmJM3RM+Rx350+jxgC/oFLgictRjZLGf4PXO5hAJ6SeeWFo160Bwtr3MSOyQ4Bl48RMaOqim4jcgv+adDjnczToHpFs2p+VuvzCj
# DATA dTurylEBPW1P4C5oHVyV5Nnv6OR9jF3/Bb74E4/1M17VP+FK4P3lGtww9Li2Nnbfu3X7HU9eik2xpOTo83j5d4YOlAUuXgT/WBIc
# DATA D0iEbtgnnifYs1Cc4XEVtGRkltA+AlFXxeALEtBzP0If2OpC4Bl0NnG4t9YKRkTt0HMVSxPrC/kAr/1vE7yH0/X0iTbW2u6djspG
# DATA 36JQkvoA77xPk3c2flx7d/3GnQ3Rk6gHnjcO3gR0jmv7UkD6SoiTxxy6cDGIOhSpGqYMI9rzL9Gm9ikKW1+RVuJDvKhblyvWzZI2
# DATA By5ef0rnuJSgO6uMhtid4xrm3ldMT6dOsHdNVX/+n3ztQ20pTa21XvjUG4D6+uf64i1e86pntp1U4iaM/XRhqu+z46HNl2/Xfd26
# DATA yYKQC9P4GbK4fxIdUcDHiB/DmL6ioatB/TpyqzXbFixljey4ufrKJXs0rc4RRCzWxAugwkWKxpPWMgOjJSwd7sdNe7DJDo7HvXuw
# DATA yVCM7jZP9lvNqlj0MN+CFVtQLCX7qa9Ppx5VKA65gPU54+L3x+2H9Je21VC0aQMGoo5U453Ll/d+fxR67rLVrEsJSYjlDUhuRZ0t
# DATA OC7DSMD8i2f0ACzU8IH6CSfYwFgSd95eVzO3c+fmjuG6oGUcOEbtOaJASINGNRdNZ7CbcylAkGiMTRytJ0joj2mPEkGpjaAPazLF
# DATA wnCX7HFAxAP5CTvkU7yQJkl6gXp4AZ36vV7KmtxHxIEGLY2Z9xKdIj2wbacUATd7mdAJXAQpfb8Y9h+gKBj03XZaKJLaBJ2dbak7
# DATA 11Si1qFZPkT/1mKSFLzVKYKLXv9BvqFEzAAoxkO3oxJN7soJk/rKkmHwuGC18fOfwwnyseJaX1jsFhMv1nAGl2J2CLQCx0hRXjBZ
# DATA q6cBswACFztHdCz/4veSJTTqJSj6p1FhnnrFGh1OIwrYMjbhCgxspc574xFeoVjrCnhZsCfwqO0/FHfuTD9h2cYpqKUVTbKodiKq
# DATA taUO6gd2MRUFGHp4iJG161SCzgeg0vJ39J3evR5E5GtoV/4i9QKIeNyv1XwSs8gLVe2yGO4KwCNZATrLfaUJTpqcdLS/wnksxqcH
# DATA R8Zx+PAJ3g2toeQPfwshTeAVd4DmIXWXW86HVBLAlyE/xLDQIYbZQe4NiAwYM4MV7cnyIopcWi8W41Vaw/UopGjua9Ev8SgQRQH0
# DATA YM8OC+FpAzo77KieDdFNl6uuU4QntIpsX9w1TIAcd4nHwN1yVkJ/k0eVU761WGKvc0gigTUR83zpzwboOPY4U0hKhjhMPYOXEGpk
# DATA jxKL0OipPI6h3UrrDneVD4iOgDhQFXS7TzkCfRnCHTbG6iIJlIf8gUe7822o/5cPVGbJ/01xrj8qoVhdlZ//o+FipKpUzBzvyko6
# DATA U9dREE0DPo48UHNIEp3dK9bAOQVdEwhzezwo3UAxm6U397N+F3KmWRPEX+p6l+DBwlyHhJLI+937mA0oawzb3eaoc7/dGPXtWCgQ
# DATA BJyyaFINw6kckb6spZUp8vwvWSA2/n4kxD8GCyvOLCoywHqPl/Fnf4Rzh24tj3C+H1tmRBmsbBpkVuFxOLvDeHT9WtWtbut4x/8Q
# DATA 2Gl+h10x3Z2rBaaAXns8GjYBLIIoQTQSSq7VeDGAFATzb2wzgBh41IMwXsqV1G2etodZAtlak+bhCLDK+z1MEotuoVcYkIUCzQlR
# DATA RTekLTUxBxvD3+TElO8qp82Trn2Umhf0nEI/yrnf5b5Xr+shERv0nKVE69X9jZC7xBFX06h+lVtz96W1EOYaaFEW6hJxhWbUHngI
# DATA 8upjuIfqqBeirfjTZTdGG8dl7qOw4c5SQUhKq8nZxGhCxOZwa2eaycHtBTqj+jPLr3Ml20co0T7F3QlSrXZlF50fShuwTX7OjiJf
# DATA gJrhsTbysIHicQ6/JUsbXd8/RZ0bqS2RFz9xFBGuJ4xZrJhdlIGJZOcF90iWyuJXFOvwpHLTTs4F5+bA51vsCMdOJt9LGLmWsJcY
# DATA TKjTK6Ozq55exu9S9/n7BJTU77Y0MhOS04J/ps7yuY5eUkCoR7XDfwOF8vOPpAPl4G5JEfYiT0ir7DFt9i/PKBaSyYuIm3upnnOw
# DATA pxnOyaOi1pxSIGuCbGgac70iDLKAlkfQP+Lixflnwzl28udCVA0WLxWZyOuBaVo7zeeyH5Kc4LEtNhkloaNcCyWt6hwRiELGWtxG
# DATA fxOEqnDEvHxl6QxHjdwp017Kgjat95bbsj8IKR+VZuyX8WuvlMCbCrVEb/z5Os8lOBzkHDdfdy11z1G7gTmW1NmAWN3tgsRkWMGa
# DATA XYMnwCYkrT6WtQPVP1yHbGvTGZ5ghyzMlZIGACaIemeCkwLFcnRSv1Mj/gOaPsho9EjcVJNQfHocaqMk6adLvHpzz3EJwMhOstIK
# DATA uUCQfu5NwN4d5tso6biv48RjyuBMydYOuxxVpmyb4VvXYOkwBURKaA9+0iYwbYLKHp/YOiF7JpG1Wl1zjfFScBbrnL/H7PMDIIZN
# DATA NXPHStQ09didHHZOmuhDnS9gWd3j4t4NUSphS+J0+n2BWQf8wmYvGbNyRo5bZLqul4AwdLvPlJ/HX243HIo2Iz2zB5cfIAVk5wYq
# DATA 8T/m7vWSIyPHdc93rWAha4foIP+L6H/nNkS6adO+aMG3bl3faOzsru9u6HiYzY0d3LHMRBECCE5Y7owZFyrZ85jrjOWh3Exuut/U
# DATA aIkDzifmUKQHxz6tbVS++dIKC+NwmZNOBoDUbhAYqfqyuIGRv9cXEo9vcKwSTKRnj+FeCfCLDr6z7SDh1JFaPzr4Gs7AXyfL/Vdf
# DATA fdXciPUs20Hgt9uEFMHowO37nf44SzZvrr+1UUrGGSU/AH/AB20rJXRvxLo/tVkGgHhp1UhodsnPxv1RM/mpIgk42HEhH2Ds97Ct
# DATA pnbcxgjzDiITQYauFt9iMSxjPDAh5Rx7SCyg5O08dCesu3tU7mduSVs76E4m3qTnvwHKQYpfqcXknuUtEJYrBXc27UPbbfYaBB4J
# DATA euUGS/MFGlqJZhni+g+OO5jq3XLlZFwRZgitGpC0KA74h6WibFCV+MJWK9DtweSTEA8qHeGqtiFQgcVqHnQAiw3X9EFz2DL6BLD9
# DATA 5quESa2OwSY8nGnlAsHjt+iCYSt8/kzWUYoUeyRG3gSltCfq8vkxecZ4WiL0EzHq8V/l+BR6Fl+ebEG7cmDiYmhwig9TQmdgwtn7
# DATA AH31/t3vR+DfbO95x7mEVIvQr6fPPiMrNiihlESNhqSPI1PBFxa4eGMESWxo9ykOGXO666Xih7mj5/fu+GNe6hcKb1TvVujP4tlK
# DATA iYL96Ot5Bi3un+SM9CGaL+JDJTNTOD6hrYYZqEtuwViDL9jf0D0iwknxv3vB2fGrKc5rUCQzjz1TrtNvRPpmfBJ0WiMDPnvMJIrn
# DATA Kmm3AB4N6h4/KCDwl+OWXlFHEsRB7S3Xk8VkrbhXXfPENKg4mBXYE/Rm6vh+z14RcM1+hCTMy83xRnpkoDf6lLRJPHDw/ZhmgbxC
# DATA envgFP+hOYYiqZ/TZnK8kD9lxf5Tij8nja9QlsF7ztztY7/hwuoIbHgfuGQY+UYy6fhF+fm6/UUpaMFYk3w6tQpZPiuYX8DuIXMy
# DATA p07GH1LvXNfO3qnfCjtLTtkBJijYtbkDxJ7xh9Cumk43vPbR8Kemximkb67+p/7G9WfOTMo5Bmn3NVgKvyofAZMW1FqM+dvib7Xb
# DATA EUyDPNMzYBUKh2T5IQdUGmvpHH4pjncDxWr/I+oQP6TYTI8/BQacJzqe0OdclD8B+otJOJztB092SLwCOGJ38zgvyfbNkhg5rSmZ
# DATA iApqAQ29u40mtdOT2fJ3i/1OV6qe617mzHIwn/+m5oemQHu//hkDC/8QRHJ8hSzpY/zvR88es4xz3rkcDNCrYo8SmrBveq1meo6O
# DATA e4HNmynCiWQH+qMKDfnxb03YFsXlUht/E8zN/1BD+gMGVz56/qvn/8zMW+ZHQhqiWre/UFyLqoClBnCd/ggp9mNV05NQjPpcx7ww
# DATA nkstJ2qMXey3tzlg0AKQZUHh4qron6kqVDuvLf/wkszKwTHRDbZD/nVkd7uL6Gl30WsFIVPr4az81hlxDlFEtdlP8eRDZ0R8YI0h
# DATA T2/PLhZTlPNa9517iWLvSCeuLuq6UY/CEpAyEjX3qzbnY5e0GTrLf7WidH0RW+blS6azDwI9ZsC6RJWpdVuC/s9jp+fO8LFjpeB2
# DATA lLU3wMl3GxEji0Vt/Uf5DEQxcJquAMbRvfZpVthb5Hq4ibr9SaX9cASq4Pnsy+LLZ6vfPeuFvkhD7dXA3Wxu4/ocB0eoOo4H2ume
# DATA it77jEwj6IZK1j/wCCNlfjXi6xZ0XnsoC8uHdO44EY79Oa0oPpCauZF0TBR241+ygULpr2LsbNGuRq5/rdkXVJo+FSRSwpl2Z1X8
# DATA lUlOx+KktJzigU8jNm73cwE8n8fygwuqAXVzbbyI1RJd5CkuMLqzuEq21dd2cDGeMTRYZyWNNsf21IpTvrv7qNHit7sTzA5QMhQE
# DATA tRgf8Lz5cjzOvq19ofgHu2ICvlyl1W4P4A9WVFmegkaggpM9LQmX52hx0A6/VAse5rni5PgH/Fqc5L9Esxoc7ohMkUCslJqzP4Iz
# DATA DoaLmhDx5x/L0W5jJFjCYMQJJi61yeavyazsmQ1ex7Eb0Ir41uLiQVCMG4BiiypfaLNE3mnviNt5tNI+PGyjglB1viCaw1nsap4R
# DATA 6YqnjSlf3wM//iTjQTlP+7Dmrr65WzzKGy4CU8Pa6u7RAOm5E2cdhiBRoSAGyakXxlqIRO+7DJ2Le4gAznRSEepdp2+sNhVeCzBq
# DATA timUNrUJuAzpBtN4sGmthleUXOZ9jmsHqki+oIgUIDYT7cSRahxyEwP1sKCCw30nDMulr6gv1bCt6L8DAigQr7einCFDIkp5Mf4G
# DATA F2NvuV4ZarQifFJe0fhFVSljL4fVFqIhqV+joyGBhcvfP2PI81YHH6s1BcB/wP1WMspDdJRrtlr4RAlk7cPOvTRqnXz277k7Fzb7
# DATA LxT1g2D6Txirpdbnc4oCFQ1VQjvoKWwU3CIYgAblEEzrA/Sg/JV9Z/rYWhhehz2eQIjkwr/8ApVBf1BI98edLiTLQCOCZfPZPe5k
# DATA zEIAJwRMCH2EqwMXJ0wAoF084PVw0O+SiRtOTJEVrPqGkPO03QP6IPBhtkFB7oCe6hEgbnYheEdV2MPkBjp+DCCJ1YFYCUdow/jD
# DATA OM8WF2MBj770ZZJMwBlqXZeqfHnToIQp6PfT739fYpM1idqnTIzr2ueH1nZApyyzlN3FsGK8yddjfeZ0H6oswVzZ9bCTKX3mxs2i
# DATA YpxOCksdTmKB9C723YIbUG/JyWGnw1B54Vy5R2+UMeRP1JS1DM8Ip/D/ZCeEXrvcOdcmxyFyRym5ubWzu751baOx++PtDVhW4GZq
# DATA hyAjIyzePgHqHxy3W+Nue5hOfK0h/a+w3+93Z5Aec2GShJ35FP5cqyV5VWgeVMzpgDXzaj5YNwotqV/WJqRdSG0J4Redw5bnCfQI
# DATA 3+Cxq4UcE1v7iAx4nyFO3RMllj7l8GDHe2r64UsotrgtLiTpldA2EmpdneBRMpNpZ9rH+WZU7b+urcGui1bID6pWdhuUKSPcxaPh
# DATA rj6yHSI2+jNLvoQvHG0ZPJhbVTZb8PwqJng+iWPSoJn5c47RnyFcT2Hds9j/DEZOV7GDbpPuYk6LU1mDmlH9nc3QMRcsv4jtoZcQ
# DATA CCcutkyfo8fOjUXADK0oitA2b0y7f4S1iQBXXBEC/4JvxWgc/FKkHrD8ETDfOSneo/ozdxqrCfKb2OE/cQMp3Msx3nJtLFMdPwWM
# DATA riYOHKF5r0ba8FJi60Zre3iZJ9Vfsa5fGhVizS5gZZeKyN2WDzLC2wGYemB4tL/chWJ3VCmWDXILbhOjJ6QTo+/Mqcvf8jlfbGvp
# DATA 3rt3mt7PNL9j1O/lSVn/vTYpr+kfF9WLyz9s7tedJ/L3CvnJ6cbibIZQPabCfIaBEY+S850PT5D9PyLHiH8CPBRxBTDw6Z8EERJ7
# DATA OQsAgrAZlh06caY9JarJCkTvaPV/1fcbRVmCPDdZ48Q06GZz0QGd4ASl/1Yfk2YNFVNGlUVZoMDBqyp6Fon2VU9oVNAt3rVQiv8s
# DATA uWf1jvG8im6FifhizdTioyZcoHQ1JAr+DII6ci0hFhAvXjRjvvi22yahP16e7NIflyY/YQf9uxLbjN2CS64HAK4T7oT67Eg4q4Rl
# DATA +QHTftRXPNgr5yl8S/GvQfMmpjWAVTYd9yCR3CPdATv6Ck4Urc9AR7CYIaeqzgN1d/4DHg9yfOC+Yv2rwaQul+0AnxBKKHeFTffB
# DATA V8bOn5RFFNLuxAcBhJnB+bjPqURiDoPgSGhIEn553k4ITIIRnPpd5kOuzemJlxsp8xdw3gErW+6RG9dihyZH6OSscKCCVZKGUs/7
# DATA JPCVdo0NekYOAoBKVmJ7rbjK7NyXEQDWeSboKwqgQacuFpY+tzXbU8zWtpP63iJ1zHBdJTMsmsEy10W7Uhh+afmtB9FHOsNqviHB
# DATA xE+EGECwI7iKGQE4LjaQ+DN4lhHydGAXSTbzk+0fJlXO4D9y3oDHdA5PWQD2F3sMxQ2TcIIQEaJeB3SfdEZ5W5LNHw0XZGj6Ln7R
# DATA LTFPrAXW4UVZiME5ErgWEFB17rjZOOmQpTqI1gyDPKhTlqUfHxhLP/2cnzXNMu8/1tyLoOZyqcNB1TFu6ThRrkP6bBt6rv+4nXAn
# DATA dB03JQxxeSxKR5tLzCsRmyP/oNjHVGpjeqNbOEWe9kX3etLsKQm8lYDaw8oNx0771Ai4LkLCcvhX3Mht1/CY5D6nx+C5kMmFaviX
# DATA EiAgQft5nNgsQZsenQfD/DvcuaxxF8AyFrpdW6w5oIQ6c2ytFhMl1/PH6GVLGGrkaTyFZU6fNdpV+n4CFYTOeJZgEpPegzzbtsud
# DATA 72bmHcmOs23dEXyllnN4pwNQMjrYMy4EXOJ8Dd5sOol1ImZjpmVzdETwWf1bMnBEAPMV38G9NIlxPnEAEEz4NlTfbkAgV4PYkwRy
# DATA FTjYBZjVuULvXaQx+seBGesZ+HBoQ28Iac/FT+HN4EftkcxNvaEAfK7GxJjmQSSFW57KzJJgpZSRu+sGPElk9fmDNoNoOh1Ch7MS
# DATA idn0Aah8hCAz9FkoQRbowLfZ4SDIdA7WGSASqRuVK5m4fDQYdGS4U7enLKvtelzPE65CQpwvdPR/17DRfJqhsFFWbjeRHrptsBT3
# DATA H/QgQ2OvOciO+6PQ+G1jPqf3+93xiRw3xp1qdDoAFVO63+m10FxGna7a6QXB0E/rVE3cobHQ9kKh68RvzacgEb6QLi5xPW2rLvvR
# DATA DrhYDmmy6pGorZGjPyYu24iGwXvXRD9InYY3D6MxO7locWmNJvp1NeV+R2K4gvSraB1ZgklKv+QYbIwp6acEQYkv5bDdbTezNuel
# DATA ri7MdLz0wGVfT9aWA02jvlv3FOEOOwfaIVTt4f79NqWNVIRNinvugu8GOj3zzA8nJnINf+roNW6zmN8riTejCDMdW8YfOtFlru4L
# DATA PruQFJZLxWQxKawlZb74qefFYKLRllKwgytnxnD6YZvBEFL2dCmZwWjHFPGTCTyNFlxXJQfbedQ8QkRSrqMytMCdq6kn3AqGMng0
# DATA UTIr9Xk1BFLmyoKuGmqYvY4LuYipaQGtz1zXBVVXUVVRLtwPHhffwBdvVJsnrUtr7zeHJ5fW1EM8J448UCYzO4I8qkHyjb6oZGGt
# DATA Bi/99R8PCIi4YCp3k9+a53bqv0J6dHwwrHT6Jo/UEnl16V8hrfGx0WAAdePNqcUp3bQZKKJU1HyCjflIGEhcXAzd7dCFbcHzmTkz
# DATA HmfaBw3/KA+G/Yen3s8yXeqHtoOa5d4WuroZDzdyepsE1GjQxOb2qgEHC4xGnc8RI+6AY3m2O5gyWHfUdQMN3y5i6zT/jmB8BBUC
# DATA lmIjKbG6XPTmQkZaioJX+K9rFrOLRfoQ61gp2ttoSa8pOKeUROP00unbxN409pWaRgwZOuAPuoNSZheeRN4mzQwc9PwTMPMhDUhS
# DATA MrHT/JuPJwvoIKsVik6O6YYFRxuetG69dqaOhknfnf+dbl+OaoP+oSVuqwOMJGLEXquRAGXkPKHc0x3gtRJB90TPs1Hk6p5E3tlT
# DATA GIds4CNheI/BMYxf/8OyoVeeJT9jlbVFqYrAK9xBFYa9SOVCO5RNYb4foD92EdfturQBzLo6BRMT+1CXSrVgYrj5oNPrgT06SlLM
# DATA 2s20OoydD/g5Tq6cQXKc114Mv0F6Vp9ntPrNfHGx9hr7sfCqYG48PHwmYMf2m1xo5UJ+bK/tHiJPi3IE8jDUdYUww4OKnV53Zp/o
# DATA mQl9oLHbR/wk1OJhy9WIw/pcBJPbajFCReenpOlbhvrnR1nNSTmH5MtG/NrJmGhpNFvgCd6NZMTjrIC+q63xoKUPqfCNuF8uS0u2
# DATA FKHGWiF3hIrocTInDjzudSTW26LvHhqpz5SNhDQlQhkSIe5RRzyBmbekPmGeMRVU3VnZJNJQZzlLWFXu+iQUSueIr5iLXGMdcCb2
# DATA XHTp9QV738VtbK9Bf3iEiUoMfVXoFuaCukwndV13J3JRl5fF0O3d3yLn2h4U8lkyaGXHioB6JXaTl0s5MD9nYgrhMEqBFBIKU6mD
# DATA jkIZcRgE5Qm6VD5Sch8pIVwBsRAOqhRINqGw5rbneidgzP7n2CLKUnlRrzRDHl1oT4NZGhX+N8Dpkhp8n1d5/jqPJQySGjY7akXu
# DATA ULPvUquIpcyury6ejO2jLdnsIWvbP5OjcTXu6voIv6MpUB+W2DkJjUvylijFczcQCGPbAKy9jHwbi0Zg0tNVMoaamEpqqjUmZhxZ
# DATA +sZNI7BY5lutCwamalcpXTQlldB57OBdnw/eNxdTvilhk3GtaRS1gD3gCbbgW0AlSD0HjnOhL1DnAiyPqJ+Fxgvqdguee0/g5TAT
# DATA Vh/cc4IY1ue/gkg2SSZvMGbpjYXCZAw+TGx5aAqeY0n1XJiktikdk7t8m36aiMIIMA0E6i2RcpTUjswF40ydV/unSbs57HZQxmJe
# DATA nNEZ3W62rOr6iPY4UHf45ogRHDuq8s5JW311AtJxdtxs9R+4eLOVEGbB9Rtd+s/0Gl2a4TOq+/w/pcvoHDSnB8BOo2YRPJ/RpZjH
# DATA qAtLakOTsAupuxsqEiDs1lWNwO668AYxN61qAN1grhX2RmKf5H5P3cG6foaHGGk42gL50O2PqS+/R7T8Yf0JMWBE8YaD2oNUIqcV
# DATA K9eBxKVopgzxKByQ+x/aT9AKqv7KydX2a3p2PqrQ43thpBdm6BFDtyswRBJDWb6LUwAe5EB0nWKDp3CGhEhCdlH7sSlsKojV+l0C
# DATA R/DxDoegMMB8ADFXM0BDcd2QoqhORDpfWZg4+fApU4Ag3AjAJ+4AfNmvGoWHcMS7qCcEcuipJTw8EevCbm5wYVOxRG9+Y9EyXnMF
# DATA s9PylNIWbAXVFJOVTV/9xM8xjCbtGbWIO08wml4of8iU3CGeR7k48U1haVcQ/Ivyxqnz7zP19E8SP/cVyWAekCY+Mki5TtIP32O4
# DATA 12o/LGlJsI2mwaZGqJ4JmxPLhvN6cnkRcuDgf6Y4hhvYKHT5fvr8F5ID9g80VvXATV+LLjhgvImg5EjujKrby1Ii6SiqSZgygzPU
# DATA wSRAyROyqCz3Ly0vT3IH7qF2qD6JShRRvL0psUG9Swl5U9QCB/xixI84mlOjJOmp8lNN2BEvuORav6Fqsp0mhExnu6YcsusJVziZ
# DATA 5kphS6INOZcMIB2dS1YmUMRPV+JuzUmVMZPniQNXzKyBXpSWJaBqmIJlpKjGHPnAXqrj5/gvIgUnWizHm9LI8huaJavbGUjzWQK8
# DATA JoH0XqdyKyU08uYQlI2YM5XQ3LFSqy6Y/UqygQnEQFhQn2UI+o6eYN0WQ1oPALADG2GJAj26R5U4zHoob83ybrf3QlwOZQTtb+TG
# DATA 5d+2fFlVEP+LQYkQ6n9+/3wtS31j/klxr38rxJjTf23gP4ranLTpTuIre4fFq3X3ncUIQCkm9/DeyAMRssQWG6YANRoEY+AOi1Ra
# DATA rU6Gt9+ChW1v6TY1Q2FMe5F2gZhtNHttL4ibF6yYrogNgeXJ2SYErfL33EDPZXnQPIkaZeUKlwmO+H8JM4QjxKnnhc6hYjz/6JHv
# DATA QGp7YVDqVPzIJLbPk5d/pbUu2NUG7KUC/+AToD+8R6DVrrJwfvNJhasADZ9BcIpqBLmkow7UHeAepEtpji+/lfU+wZkjWKWnuUm+
# DATA ciWmctkcczkIqPCgrs3c/IDl0jnnhQ6DBp2ZPrRVyW8YtlZBJmMpGVhT6GcaR+7rqCzpsQVETYErRV/RNz1ZuTPFCM3rgM0+SSwV
# DATA 4OwpjqhSCFcjDsk7Xy5nHm8OXIZsRf3aRseN65REERQO1q4aUk6Yuq4E8rkNbQyXzg9wP//SCpzhBBCeNhR1k06PqYXGOxs/jmyD
# DATA /yfe8BNSNUNuW2pSXSPtehzNwBlCBZ00GRbAFoMsrh3IgUyZ5J9MPLQqbMWDCfDclBnz1nEFqCba6c5cBsktmf7eSzdbSghzK3bu
# DATA 31W1ZaiOOkr9o2HTQgrYq0+mZL+uumc83Ow72/0hhd0M1B8GgAnd37dv3UaI6FX1v9T1c8UK+CRUXehlap+daGep+JHIjqyOi1TJ
# DATA BTcghJE01Z6IUYASW9z8Wucng7Kf6xS0/E0YHSXf38RDYg/jpeaCNMwFT2dmlHqXDhKHtQ9jDOoq5g3D12LwPoSfZ4WD+WayOHvi
# DATA qi7zK8ZBvtAfw/XDmOQDs02FYyvE2CnBewXkBo8DcbkwxQG0+KLAWx4vjoAYhr2LfTEN1TBwV3pRpMooDtq3hFP5n+X/+6KwozpT
# DATA iyvghjm3SR/7OXgYaDPhb579rpQwxlpU7enAO30L0IHsu4wb3XXaysPfM1euvvaszNlfBax9Trw+ywVcu66XnfLmsfWldVdV32t+
# DATA h0h/LhecDunnll3IoQiR1gl6z7RYfYE9NxO39By7PH7GE5r3VII27ilTRFJH3zDsj5S8Q+6Jai9VpYo99YPiktUfZFm1BDC8R/AL
# DATA /mCSX/eeJXMgK4Q7N8gk/Gm+XFKMqWlC2OrInohiYM4MUN5DE3fFioKppcDhwBemBuoCM6ackvVogzYwU6R20FrphcAbGZnaD3Hj
# DATA joiXxjtdP8cAxUwHCycDIu8LXueSccbQ/ZFDWFacBR5VcUw/hVZa/vKcc3+2uKgelZLFRV3DJMycXnK2owOUpb4uqL4OuujOf6xO
# DATA CpIs4K8G0JsrkWZGGJWyYALuw84qyBMxcmbZA8orTiB7WYUgyo7bDwsXV4sLOvcBilcxWD7vC0Xi27d2dt+6vbHT2F7f2Xnv1u3r
# DATA qOCnhrwgCavwnZ2N2xgrYR2K+uX1q+4rvxYPQ/DQOk6rS0vyo3om3Zj8jWHSrf3qK2sXV5fya3/z9q2t3cbG1vXG9Vs31zchSj89
# DATA Ho0GmaobSM2sSLq9vrVxwxTTb/wqd+5cbWzfuXpj85op7AhS42E3KziralYettbe5Spcpt5+b/O66tn61Rsbqncbb67fuQFLo6SM
# DATA cTscyM2N3dub18xcN1snHfQlkRewYtGVXV0rBrW9t3H17Vu33mGCaLy9sX4dq43SBSvk1UaFAEUmZi0pu1uUCC4UkgfN0ag97GGc
# DATA 3d/BxA/bFUShbsPOL2JwXK2y+P3UldskPSR/XsJegNGxctNjo9w9+GS8b8pz/r5GNQkYjFR22G0eZTWsckr+Wqz/Qg1xVFUNIbu6
# DATA gK9s5gCfMDNAoAfgBTTBGNi53xYHPPohl2J+5cY5Yv4jQXn1UyLB75fTu8O7PYB3fflcbn2IS6r1GlfAi4ezQbHu05ywnETKRl4H
# DATA PHb4g0yJLLk5pptB8xQM12pwYG2owN9gvMral9Yq+5fW2Jgm0yKwTxRQ5DhKR5K/cd140t4ruig5/G7vHgsM7IjVvNYejrbbJ7Bz
# DATA fvpgtD3eV3z7HUakVz2xXsNP9QZ++YC55PX6Lqw7Obs6toWCeVFKdk8H9GewKvbEfgqaPfZzRIxiSbH4CBMIkObPAMg9AsQYQIb9
# DATA EB2KP3r2FHXSpJ5FpKan8bymTJmHL2vBpnZG9Da52zMdqqVnDNyqaPplpuEHzc6IEEuQgRYkRK1z0u6PR7XVZRNSbEUKYKy7Ygc3
# DATA EX2EQgjV6rWaXSVJplFgkfDkY/0R1HUdnwjGg7tzrGLQJOma2KdHrWvnEI7o9pSEXRhar0pmS2BUOzhWLVUGav21ksvUEgBKANEt
# DATA J685ZTxT/Wu1ZOXiyvKrq9EN+gd0KgAvgkdw93MT3URX+lHy9u7u9k7ZwOjogLcep7y3e2OMwKzLajcPmWVKEt4y/O/qxlubW8m1
# DATA jdu7m29uXlvf3cCnlcU38F91lgbvUiu3tqpux2Fe0Eww4N+HwwkGw1dWS1su+tyHA7kfeFnCs6xb2d642YBhN0Z9dazexr8L0Al1
# DATA 9BaLFUkWbiYKDw74kpJ8NxjlosEvCwdNtKLBDcGazqJTQ4Xhd/AwSd6n+t7duL355o8bP3pl+YfqeFZTtn6jce1tJTE4X6pzvHMy
# DATA PrFS8cK3uzd22J0e/ry/0lhlT/FmS9EcEDFsvMpJX00x+L4V4AzlvUgmp2MwpQSFXtNVWFgqAbJaZ3ScZKBdG8mkqN72wMSubgiF
# DATA dGX11cqy+r+VVJ9khhGo8RRWISz9YaGyUtLNlf2uQKLcZqZ46YNIWnDogEzQg2Fz0KDeFFRpUsu1hw3hEzUtXEF9inGNh3mCviJJ
# DATA n2KoODCrQbs9RGLZV7f0oVrL/vCEDyJNNcDAhPyqudcqA3JPGIsfgH+cg3YF9kWIBvknSU9iA1eqBS/Thkf4+g/TYs6thbqetYGd
# DATA dguH6Vsbu4qFwT5aWqmsgEDwtpqaanImMzSBZ9f0UqqbdRfcBUByUP8f8rfhcVws5s3e6vIysLEO6n6oecU+7xdeWVkVPV1xb6UO
# DATA dLa2vJw/Qxa7t0/OWzt8bNpH6CY4DPlnqFyBDBEDeWXddntQqPDth5bBZSt2ImNegw8QY/rPiYV++SUlxXz+yRVRqlHozieSZxnX
# DATA tBRly5g4/T8oqQzYSlH4K5OqUaz5+Ivz4BXMHSTrgG+BOrZsk/3MiyDKMOptmuLZK3XosGu8vB+mlIAA4ICSZdy9y+pShcemfFGc
# DATA AOu5crdnFd2rVuu55Rxx9zBNU9qZydnZglXFuNd5WF263xwuqX23pJXYS8NxbwknogKbG6pMUOXagLt2/6DfvbJwRoObyCVd7Xqc
# DATA CkPQV8hKknUb9hEfaW3U9U716JcNEOxzvh4MO/fVa/db6WuWIJuurPK/F6kIiEqrSb93ZcEaAt6usqR/eHiFbSDqmFwaZ8MlxZSG
# DATA bZqUpePRSZfeN8ejPnrNmU/asB0aCDS5tryWLKn/VKwPWi11eWu21FL8qHyNTuYySKLlW3QhVTSZ9TqHSqruPmieZsFXtwEwZdge
# DATA lrf7avpPQbLuHIzYk6/84LjdKx8M+1nGT5xqun1ShCR/9w/J0kOYAPCWWRKiwKOv24FgPXVENPb7rVOSjpav6PdHw8FBg8QVOlSS
# DATA i8vLmfce2N6098Ad8C911Z9GgthFJEGqYDJxh6FGcfdupfDGSw/a3W4ZcR2Wimo06mTrnYKf85XgExgsnKrklZB8fzzs4H+Wkppa
# DATA KCyv/p/aL8wODoft7LgQc+cpaeuv2DP1qZfqw7eWquEvpyXaPjVt30BhnXgGlvY1TTnWUO8x8iPVwgq2gFqtXnvUQAUEBcRxS+Yp
# DATA HJr8EJkGemoq5tA9hCCcbmq/o+rX1i7K005vvz9WS0svLsMbG6zIrlMUfwWnbvuCEb8LA4bnYzbvs6D9ATm5P/sicQVQvBanxYVZ
# DATA KnC3XzX3mqNzXlorEnSM8iLgEUQRbp/oYIqIZGzC4j7FuFUGEP1Gumu6pvWHe3gCxCLkWF/hL2lkMcNwJAiloyYolu5iXgoVlKB+
# DATA maxvb5ac9QGManYneZT8aNg8NVfpLzmCTnKqwGlu+YR0Dn1ajoDd5EC7/xYDnSDecEvdl9ev31TXJTch3acsP3wMeNhwp//Ijqf6
# DATA lFbaRDHE0N61i1gQYBrg4uZ5neXrlbr9oyPyRztLW+pYQ7eQFDQ0ZU6jm/YH4gFylipGXQYeDYUuLqN2BB5hUfXolZQZIMTd9gXw
# DATA BwGk4PW4p5hgVs5GfUjXAh9z8xCAT38FCkodoX/mGr61lzHbZVu2Q80kqGbc7Zx0RlRPr8/9PUuz/iH0bGV57fIrr15SHVLHbss8
# DATA mEwm8/lJNQcDSV5GQ2cuLUlrJGkfubKaJZVUycV6KSYhw3Jltb1Dc8+qipamipw+/hmDMtb22AZdpjsTnXtw0hnTNPm2ZtUltcpL
# DATA ahRL/CCn5lYbDIxZo9+r2abT1j7OphJjW2g7QnAlxmJQgkR3dHyaThyrKpnEZ380iXaDXiM2ourHSFEY+CCl125eL++8vXED82Md
# DATA QPar8mG2g6KXOvrhUO7CoQlTt7JEdaDnOSZZVHMCPVhZRqsFixNI1BkZhJXkg75Ol+hgGY4aA3XV77doL2S2eTjkKYHRFlSQA/WO
# DATA csrspZqBpPVYiqUIaWn7SHXlcmUtfWEioyvk8QkKX7VUXeBO9qk2sYCpOd79CQzzzu41WEdDX9JDI1JZPhBTmptnAQdHjU4Gst9p
# DATA Ur6TfP/7Z46ZaZKUW87D61cnwWJenLWWq8sTO2xD0WTOXNOO4Y1T/WG52R10esAe591reZMB7ajzxvoerwbQzXI5U1sFc73hL7Lu
# DATA A8g8aaXpqeK/J+0Ttc7lAYro9K6tthFuKiwDUi/1C357XeN/UPD1iysKRyb/6quv0ivgSPDXcu6A8pfWOMWUldyP9WVz9Afyk37N
# DATA lbV85yy2pUqpKXXYEjIyKzFSyLDwXydIKRSdq/mJfEnky7cK5n+JN3nRb/svAg+NyKc1EQPAmyR4Dc4wl5dLiZKyJ7m+SCyATc/Z
# DATA ZZswYnIX5bIT1QlZKRyZ6SmJuWnUhSXbs31zAle3enz/hmsUUi9JGjWCgVff7onsgbSX63QXxRGMHFtTuLP9vXBqkOYOKfrFeR/b
# DATA dzExIVhhkBhWots2fqi/2OE8ffcTnKPa96Fdm+W0wzbEL73MR7YZD/R9CRlAr9nls/vlYmV0rC4Pw9rr7LsFsYKjwrDSv/fGcnWl
# DATA WKwcYDhUoeiVUK/y+JfDZV6ZxWVWViPCwKorDPAJIRBrEPXkoULopGyGQRpurQUyNzISLvgUCYZ3/GrOXqG3ObuC3lZXzWnmHvpv
# DATA 3bq+cfXOWzCmk3F31AH1zehgUFsGIYCJLr28XL0MCgG4uVfp9i5/Lo1bg2lSQFxoDbbHNeglhTWAcb26pGhkCbu+pF9Vh32dQrwM
# DATA 81ldgv+aZ6RirS65SWe8xiX67MyqCMPUvGr80DXtL35GUf7GVT+xw93kT1hmxk2vStMTSwU+Gjbxqq1XL7LgpMzdM8Ii+5RbGziC
# DATA dOEUwt049xVGibLgjcgqHDiwXlzkZNG35oi9WqtjLuI8xtIU4lByg5BFVKuXlpLgG3XXzJyP+kdL2XgAq4Pun7Euh0wbrMZLMA8i
# DATA eMW6wRwv5+uD/rCt/YpjnyOmslOqHpdqUJEEaxijo7obzxPRPOExQDYF630xvLQI3dbF1zQYGZrN85dk1M1gr+ad7ZaJJI9p4dvq
# DATA SmX1suFbMeJcOB+XIQME7G+bzZAGHp5WWktsD8ZCyHCmc7YXnJrz1jp7B5yzwgcPHkiFMVME9NFjnxbLshfwRfnj5JuIoDJqstkx
# DATA VEEQVUgeEbwdkNK8MCv45Vfth1FhVEwkhoomkaUk9m6p2tvVrxhVDLqgtg7mKKuImabsGf/wlObi4WnYXYrNqiaiz00xI4jVU8Tx
# DATA 0Jmg5lSRsZeNLZfeGYJ07YefTPWaPNfFyw4oPwsTJFcTMk+4b2jsgfg8bRPlJAsmOoREwRX4z1qhWJwUwx76QDfCWafec2IwVs54
# DATA bXermqvlJ428OEbVSCfs6OyLVGSTdPZeKUeTX4w5QdtBekAUin84wSKCHYPp8EpgOes/8E1JbK/pd1vA3R94QQOcWcQRWAtYXdH2
# DATA RwXxWtXghGihasFOaQD+0LAr/va93YbjsJxifq/rm/QXeunafrbwt7jPAqyyadLLh67KUSof+RX4IpdizsTw0AQ1qF9ODIIbKRPG
# DATA FqlhU5TESzWYP3KNbJ8Wc+/2/13nBH367M8cRYSJtjGYFtJsR4KGnv+agAqgZopsVKRBWD/kb3ugNoGik3arsFc4IUdAMD9DCAT/
# DATA 3KGkP+bBdXVp7PRwN1hPb7+XcmA2ZoPiGMGb2BwnZS0KxTSoF0g4Dd0j+sOQDv+2qAb8jNSdHqLQJHMR7GC0uvSzCtMa9wcSv127
# DATA s7PbuH3rFq4IqtD1yat6a2WRWqK4W1U5wg6jtssgc8grAZm10MOwP2zcNCNjCxW9hThPPU6zvOYZZ7Yp8AdU/feSW5KtcnQ8bLcN
# DATA RmIZ0hhhCig8gLnFk+Zpst8G14B2q5JsIJyKxDFxhVgSMNgGzf1OtzM6pUtiSVyU0d5IgppiFagHAz6LoA6jPnOKTibQigYqgdbo
# DATA 60aFRvETZKqlMehjhNFMDRYHmoShw0rg0WimvhjsS13SWk2pAKJtwNqItGeeXqwLHi+cV5G4Kj9Mz24K8sEw/cRTi81ZH+XmEhsk
# DATA Vb3iiYHDdrfJcGhU3OyAirxrjPq0oSTC3cZdgEPd/7CTNeb6NkycrIMHuFewtmBslgcVSo4E0soqvnyhtG5ubeBaynU5j1cw+Ud8
# DATA BfZkoerhWoS7GH9purWoiBh9wAdi7B3BFz4hY/QXqMQNGXsk76a6rtP2vcl6PJAMripiBZwl+H2tOVhvtfiv68P+AAsNO/eVWA0m
# DATA 2rpzEnvnvokgREeOsC4fBb05sA8aCSOsJmfooNscFJUspC71SHx2aq9r6+rA57DvJmJ0FLwgfnCWDBiNjlZVZ40bTwiLAL2hA4f7
# DATA Bf+YwwZ/WUdNJOZTRsx8Uiqq6eqT95VkYRQmk/k5gd0ETmV+G+Vzt6Ezc86cO0WhFifPLxh1/gjlE1NBVQOKg19lfJfBTRLrTXOu
# DATA yVW8SoOyl2/MaUSVA1FjlsonWjBU2iAGnvW7tDCR4EBIumqyv8aQLPzkr/M7hAgwuLx3ccFNNX4901DBXVygaKzCTIxw3z+JtZKF
# DATA c0JpFOfHj7LRMPJBSGeOlzIVWxAZGgWGPHkgYuf5zxmPnvkoPYQZ+Or5rx3Wit6etcRWMxTS+JkD5G1fJCvH7YdOBt+zqbguM7Qj
# DATA 0BF+Dn8W7ZyWguxyqHM2lTSTzslVGsT8IV4ZiXJ01rkyk7fstkxvskhhWDm8iVwSrDSq1s0upzSY01G7tZS6fmjSyxCmQS0TBDFI
# DATA gRJcd2p87mArVZQr6Bh3GoM4E7m+cEKH3AvYv7i7JqAai9rI5soxe5h+POZXpl595F7TOPPqdJAHLemRNzKudgD/aOXvJZSXr5sU
# DATA ln44SWHpD0tl4uZXNRXrioRATR1W1RM3YaaqS/Hggy44B29JHtbd5nCzd9gHGFZEf+TfwnkhrSEqP9pK6mqPmmAfKoDHaSmBuCnI
# DATA XmAF0/RHiNutOtIcqW5wCdW7ht7juhYCFVWzsgy0CVVWwB3HUXfJQ0BsB5zXxVUkfGxGPbqULMrz2AEKY+QrHfckkcYx6qLdyvA2
# DATA mDUP2wl6y1lKev6ikttzCEOCjiyYiQKLa2Og9k3eBOGAwvmUgn42QbTQKNZnKtYlvUaPemNIhf3tNCyV5zWeKYEfUo3ktM0hn1iI
# DATA ceQIiHQE7QxQV4JXerNcJ52jIXM6lhpQVXwwstPGc0sFyh1kMufA6jRwOWurmkAulgi5gV+sLKv/cR9ffvnlqzAxCQUAkKqh2z9C
# DATA 0HgkFs5oAiiYiHTaU3d3IBz0XQegy/vQadWNdkVVthDm6La5kGySAzwMasnygo76kj0IGYwK8Fd//6c1GR4ZeobvU17tjtqjNX8T
# DATA YxAYT4t3W2+jHwxcOfzXxOOgLxdqyYoXZESZeekCjFUQWCpd8UKMlDEmzLEmGrZr+LUSypr7Smwbj9okmaWVSkpYscNRlndc3Onh
# DATA Ru2FuxrBZDU2B3YjLUbPNOpFJyOZUFzT9WNGMtQTph4xcRen9EoTcS/GcKCesDdcP8XGJstWk8zvDBWrCwrSTF4PLDYXcDW9kRL0
# DATA YXa70TLHNjAzEid+2u/0MMnAIukKYtNofegrK5jS5+irzBBBISgOoEitZcs4OVPGixdFDLamMB5/J2umw2iNKCrR+i4n4l5GwhDt
# DATA STi5B33CHbrcf3V5GYJFAEkn43AQBPRu9O9ZyUJnXmKJT6g9aQ0qb/kq1NzX6Qcct8fjUadbaXWye41xBinceDUrh6Aufc2h0AvJ
# DATA pbW849fM9KbaHYeHnQOIeQIc33vIZJWYdYJsyd/QNt+PquLkVObjAPcr9SocDX0TJFmdSZASQa6+PFH7H3wx3cq/BxDK3XGGhSFE
# DATA GDYQo2QrGh6TaUv2voWULQcIma1iYcfQ5ZKzsngWpA/3U2Tu/fFoMI7kIrO/ODhWBFDA9bf2hEaHX1lZIc0hgs+HxEh6arq75JGe
# DATA CbLWpeP7bb8L4Y2WcrTZKkCQtP6slFx65ZWLl/KjboHfYC2zQo4jK/lAzdhoOO7BarRyIolpRisMhA8NxcuZaSlT4qucslzfoaKP
# DATA 4whkeD+rHGanvYOClFOT2OsXXKsinmDamjg4jUk9lrpEyMbhvepvck8gRQG6hQ1SS82C7g4IuU0bBe6HFXRVZDcG9h8kY7U4E24j
# DATA PULlYClqQdC7/XZzewOft4dD/zlLP50TDMsBC0wTtKiVXXhSWAFPXCl+r9PtWsUrrWabYmuAbVnP8eorACQQFaqKaH24E9kfhPlP
# DATA kSelFzS8UnCF9GHUYV8CCY6HHpeRLvHLBQ+MTQ+1YCf8sduuYIi69brVaR71+mqrH8CyWIVVU7S5Vi5dvLzmJ2ooUVcyJT621S3w
# DATA wE085VTit6j9WKQcQKEULOAT42hHvBJ87a71x90Ww0YrEQtFZWAWKOPZY0DIQObTzhv7FkjT6OdnRLmNmowB1FyzE5dxVsZrzR5e
# DATA OtSh0z3FjWWdPVdMXjWzRSQpRAuU55hUAWoKb0ua0AEntttW3GabHvBOETcB8EWxRikA3arRrk2sSNwHgPNj0wa5RGIzgz5QTfxs
# DATA y6Es+1WwhsRqsl5zkB337U1RAKWB6v+4Z29n9bNEjAkL1XJ4lB26OvJUGVH0m+8l6wmHyglZnDTvqfsiHZgQowem1S6JbghV0WkT
# DATA Ff1srMQlyBrS7gzAWsz1HfSP24jAKGOrJLfV3IGHcXKv3R5kbkY9s/KUMEOx4f4Y0DArkjBdo6+oOSjYzJXfQZwwD1SUk3XI34Du
# DATA 4SSEKXFXjbjdoBOAHwLah/zpbS7TKQdISneGmUXRSuLm6Rc3WwQ/FPQssfMys8UXptrWQN8e93ooA0VSC1Fau09BPUd/IngEptaJ
# DATA afO+ctTinA/NRkXHdEKk8/s4LxiUBjElOSgrma3CqO2ta9U4/AwwjPAhi9HGi+ElW1nNSEcvZjOF6j1Tz/kSj3pz/GiavtRSt0fu
# DATA BPoWYPleYIomSHrU6eXuVFfOAEBVTBjEukhF5Tjl9JDVkXXXfY329FTjvNFsw+SzQjbHikz11fNyOcZn9S+I7/3JHNNn9DjBJNpp
# DATA pNU0tRg43WKazj4LZDRXCw81VIgPwrFd9W4b14nJZObK3GtR1k91o4ILxbgDeZEUH0ya+xlwu277qInQFYJWaCoz5IwHGolWSxD1
# DATA Boep+hNvaSyyZJVkC/IIJdkDNF0jt+wiwGDFv29NOfW1GQoHSpIGxmQ59OC8zrUZ/CtlNvmU9gUZ9W0b1NPo4koSM8L5+wtDHnwp
# DATA qT2i+VMQKoGyKvxG42/la/D8vEd7oo9cZBoaHnX7+4V0MS16FAu6PM7EWekSblosXVIUdk1n29VWTjf9bnHaRLJVRQD3IIflIwDF
# DATA JlgISGr5Fw3DBra/x+G8Po1tmikqRa3VgEFrdDhrhKyCoxtqnoYR1be2KcBS9OYO+Pe5JCEU8fj5L5//QlCpoph0QGNIFOgb6DJk
# DATA bwJwQN5dPFgsmYWpt/MDSqfdA0C2QozHTuHeCNDssGn0iphlvi/aMNg48UMSuwv4l4Rz+GkVPc9cnUc08o2zZ0img7sUbBxGV7SQ
# DATA FEG50umPs7ToPB5SVuTTYEcRihlh60vNtgGd3sd1xPRuTk8ThkvDPV/jX9xlSByIlldXaYdgal5ZwmOLlOYueRKHFi0urU3wQgFV
# DATA Tt/o3kmIqS+E7yHGF0GuUEYMxV6/ICcpO9m8ALKo3fMpPAq76kwGEBnEUiAGwZJ6tfRw2DzlzBCyKDT8E8LHhE/2x71WF5At5nb0
# DATA sRt9aTZlI/IxzVjuhP3WG/UTGTOl9mVp9alkHqA8wPYhBHkJ1ARyNmBHjMOMwF7iLT95tJ+4C6t6orMaIEotZ5/1OxinH9mATCkW
# DATA m1Wbws4Q6ZYj6XfqVEVOYxs0zj6NZW6s5PV/oDy7gBbnQX4aGlvQfn8Z5QKERYZQGCtt4XqC6jYlhqHAoa7FHVvvDI53yaD/AK51
# DATA /SyDlMmYU645JKtDr/3AqozuAJYLUYJIudkxSjQPjiHpgtwmxTLY7J0mrFoBH9qKpbChWjqEJGRhW4Fkq2QDPL8duQGFdiMrBMeG
# DATA 5cJhf8Y+51aDjtMGQg2R0wb+yZ6goJoA8E1GHa76BgYMwUAllpp+VP1x+r+scqtx+/qtrRs/Tt6nXyKY6wdbt968dePGrfdckhzF
# DATA eKvWipom3a8CHYn1Jams7C8ZtBdUug11kVeXY0Hs5XxG1eCi+LWc3dkerpOV56Pset+cNDnJR3pbKk7+vw9+h3KGJD2z85Ukdtp5
# DATA wSCUiFTU1LZFeKRjVefwyXcBqxAKVcHz7xZxwk/p0GCQpD0fGJpQsehSaB2BRS9FBLwuYZQjC3nwwGdaRK0LsWycMrmEx5WLOZBV
# DATA mi0K1aQNYjaRZXnG9p0k81aKXMht5Cagp/hewz2rC/mtxr5k/Cl1JURmQIuvKAsTOH6Bq40+dM8/klyYSD9uzthn/2NKXkKTQ9PO
# DATA quuFu2F0Dl4pJa0VZA5a3EsT/DpgSHY3JF6wXo/VCqiv+nD6E/k9Qk6eDwSxDf2ypjdGbExPaLHupCHUz83c03xeAFNHYgcywHUF
# DATA BXOTSuiLxE8I/ezJFQ92Dg8iWC+5BHrJBznhUIWNJFbrMAP4Ie7gD3HcvwTsNutkqySCdYenpCr1BSYd+4D0OYIp8ign6aFi4FlS
# DATA 7jbDHAnkuPkXVfAPBEqv8yRWMIuHTv/9oZNBEEOdEICEHeIfIzlRfkJxt3v2tBI2mBIt2snA+RtMBs6VwtQihRrKZJWORnkIMzQ8
# DATA +78Ngqy6nLnetJgGUVUZVkgx7mFt0MknRJa+Z64izrCeYftI3WbgehAfNO1WqEJdHavJQSu66dTDhLTDkj0qGWDEAJoSmdfD1hpn
# DATA ksoSA0njG78eiUwwIBGlCKCKxtEoS/aQyujhSGf4orDvkkRolyiousSzWOK7GvwBsdFuFIPL3MilJ56yHHeHnaMJjY6R+ZJ6itq1
# DATA bEBCF8sbbJOflSS+kKsnMbnM46nAHTdaZMy+6kTyGf8eEhdTfkASwHGDv7l5Y2MHZjgQdq28xmH+dQ8L2k4bLUM2QMdqNtxjRTcK
# DATA 6wQY1uC8U8BJL3JSDj7LEEF3+pnz/Jcl4Do/Nwman9rpWOOMPE0NZRoaRvKkaGiBwHEMPgeUuyfYcOAObmpRA/B1BRjbBF9bVxgx
# DATA BpoXevE9wyA20x6ithb1EvSJd2XCqbogiXqlJ7SKpgpHrMuLlFZ7HX2cP0DcKFt2M0SBwkxOvUV3kYt57eBxKmd54qaR0mClpg0d
# DATA RGDOcwonrfty2Oze5ctE4YTCdPybS0VwpM09E4yv4mnZMCGdPzibHd7McSpCDnLUntXj39PxjDT/jxH4ryoLMkftuWhiOl1YOGPe
# DATA xAQNzEscPoEETURohRrzJD6z03kHG3EtODuXgvh9dTRX+FLLu7q4V7246p4sM/dwoAXi9Y9uZ15goohxT8J9W+msSi0CCMZxjuWe
# DATA h97jy0qUHqtzrq1uRp27ya0hWpBbSyi72jLcX0iD5Z8VHzP+8AeoncKhJfjRE8kM/+xpKDNKK6+FNb6+RDYrhpsqLy6xGA10CoK0
# DATA J1tGs9E/e1oCbZTW3dFXkA/Iyub+JKqVCzsLghDPx3/MIY8SShpTv1zipwmeaUlHyOtpf8RpE0DE4JJ/1lFVDlJyKOb+3rpwPOEb
# DATA zGPVN8w2nsDAsUOf8RUCbyJmlvhCKCZ6ySKubT6e9k6JCRJK+/znchdi0zqqDbWcYqXDYhlGeEVcekHCNNILqXIQpol3LfpjD9EX
# DATA 9Aj/rqwPj8bQ1Da+0ZogtWNrjYaSwRuNovUlXNEbTf6kkPYH7aGESR0c90EvUmNMH8z1lGIoWYaGBk6ESym4EVYGZJwyi9v4jf23
# DATA zqmLcQIpI/k0h4J6h+m+4O8jwr0j/pUiJnN2XKbdgmUxwY71wOFKgB4TPGTUzeA59w/9UcrjgToZKa4ZEKc6IwH7od5kI1CcW48E
# DATA ta/MmAY4Bd1mz/J7wAZZO+o9Fmcq20tiyM44uiaaUWiozB2wJyvnNXc+/lLGQW+dycBkFHq5DIoD3oNQbygODFHSKZfZpla8kleA
# DATA TXT5BcRtaGoz5iJo06gnYOe3YU6Xqa0IYtSUzlJC39z3tNT575mUCDx9al8wY/KUmobslASRmcOjrAaa8qljU7Q1rWOU+NasRm5J
# DATA S8GkV39aw2ancKxgLZ3RUyRT9VlZ0lw20VRWS5GMG5gic3qTiEfW//p1ADhS+YSADwzZ5aWbqFtDNGXmbIVBlnUFmPniytTvGJQp
# DATA +JSyZkxrlnijuyS5bfnVIwj9dKYQYc5zLr7zKe22+XrpiqlBl1eWZ259PKnMKus88ahfYTxqXSO9nb2255ppwAzPf8sp4rhR9m7n
# DATA svgPlM4MDAD8qujDXecA4UPdSCV+ake8SeDHyM2KAjsWr5JPiaqrwRGjk19XKbGeUIju9Or9c6nqRSXLzceu0QfLREelIITZ79qe
# DATA A+tnaQLaveZ+F1UmkIV0PpwRRDMxkBqKitZv3HDxRxyzkuQFwAsKquyc1wMDp4I+zzoKwF5qACKDKaP+mrQz3P8oWrATwu10QiPS
# DATA mVHkpJeHz1oAMIJJDWB000bZIoQYjvOfbzbB4B3LlWAUhtbyaxOnG4mgF9GZO1ZpniqKoHToVIpgE3v9dDpx2kKqmV560ICXbXJ/
# DATA rxjkhan1+ZLkuYidQSHywEX4YG+og4q+5wfFUhLr4pxTaxURZz/owPRhxqRjy28q4oN/TqYxVc62rmNczHbcl2LusM+ziO7FwkoX
# DATA k2WQl5RfSMLPLBybwyOZa+IP/qSkt/tslG1Tkyy3Zhf8gGi9MGNGvcuRTZjwosEvrE5zL+MzmDeg6Z3w72O2Qp3EOqcb59l0kYuT
# DATA v6HF7J63W+z9R4lgECmBq5tvmfEJN6e9BRloiVSGJU9Vbza1+czEM7if8rqHmRBMR/DWUYxwC74fNAzXMB9ZN4KGsz8Dh+BpQysl
# DATA s0bguTiSm2enNxiPHGQQdLqoGnsTCOnkXlh1XL3w5STKyyjmx3CyKawOvdwtdPk8Mpt2gXdSrmGpuShori07tTnevfORq0Wpc23T
# DATA XHVDuG+pAw7+Lha1uoGLUbK2IPdrhklTVTeLt7m6JWstKKkzPT8XS9Hasuo06pFShVlHs4V4HWWjzPXQ/jRjrIH+anoPuXSDS0/r
# DATA achD8Ad/OaNbRqXoizwlgKBHpBkpEiPN884gpzfw+6zPRvwpJ6NQfoA8PZU3+JKS4w5ubaUrcUBouG2ogV+J+x6BoK0NKFazNjhm
# DATA PSrHWY7lM45FrdidSiK0c1WxwrSdqYVMwjSnH4QTG84tKAxm0EuoYKj6Ir1Wp4c44/EmnS4Wz9MB0TTP2QdJB/VNd2PmWjltzVwy
# DATA zTznuKDPbBolbGgy38uUItwQbZfiACwymacPDHBv1mCWwNY5wSRY2amJtVZ/V8iBpgfCemHZAoNuIH9tNKw9xtGSxaBOjazuOA0N
# DATA lihvwxTrrhWwMA/KIgSafo5ebJhRK4xD0h2R3Jn4ozAoSeYPh9j0Z6arFPbnoqZcsd7r8J5XXvHZoSrjOFo5ac9DduCi0WtWPCO3
# DATA rkYAnkEiZIAKTxdhy5SEea7jVqexsI+SqeyNci5Y43EK5rGASP6yyAu7GTf9ZAm1P6bRXt9+F5nc6ELYD50sAH6Sh69zQrlVbACI
# DATA 1TaEd1KiiBnVzHEKX3mxM1CMlY7AHGQ2CISPucUS0dhpO0UZodYdbApxudMOq+il9hedFRl81KZBOgf4pJo/zLqppNVAxcgphGLM
# DATA Iyhr5xxyPogmG5KvgLSqlPDQcP+wFG3Bqpv+2H5VjKlHq0lnoGZ4CAgOnYGWarU6hTPd21HheZOESJMLvud/oFOWqh3QUSsWAD8s
# DATA IYJ8CBufFwPgCxdqf9znvNxwy6a4AAutxUkYYmqw4gfyr3Joj6/OlGIXcvKviM2i6il8UjLtVC0eOgmXjG2cNvJJNZZLhcutBxK0
# DATA VclsaXhhQbXbQFJqNHD4jQYQaaPBE+AE7pBDxoIFhxMCrgAuDuKlVKcJHbLH/+35L9Tm/QM5v+d498x0BcfmFH/BBG0gzlAwuQVn
# DATA g+AwO6fZqH2yQXkR7UEU3gWqwN6Xknfap/wX5O/gP2/t8B+IxPG3O7e2riPUDj4t2kFpm6iawSwSnd5Bd9wSpDNMDZFVkx5G1uP4
# DATA k2H7pwQswlnnIS5v3O0m0EDlW56+SvLs303I3vNPCJaDYRJ05EDJRer4JYU8WnyZggjc/CnPfwmIUudajb/6X/N/apftd+HkVNuo
# DATA Mjj9VtqAoPhLa2v4r/qf/+/ypYsX9d/4fGVleWXtr5Ll72ICxuBgr5r/q/89//fyyy/DRlLckUy5EvqHoXaSh4aUbh3ADBy2u+1m
# DATA BihHFGG6Ulmt/HC1srCweww+vHbBn42ViJ6MjtU5gWhyHCCCGKCdI0hrc9zuDjAO5RjYB+AUqrf98dHxAhbSF4pk99p2mUBUD9tN
# DATA AClCMyrEyJo+cvru5Lh5v6161wbPcrBatiqqb+0hht+21JG6D0cpAG31+toUfWAfEojY+rB9MKbAfwDOAomSQAwXAEh31pEU8I90
# DATA d9Z4jtWhZHc6/Y44jhOfc/DT7D9h/7966ZUVf/+vLl/8r/3/XfwvHWdtFrDTKwsLaiNko+Qs2R52spPmtW4HL9z0K5lgQANu60L6
# DATA NwN8uHSAZdLiFf72pw9GdjEQRx6098nEUNQt7Fy7tY2JQG5h0ikEcv37dmGPknhkuHOqAgfuO4tmVcB8U8Kp5ADm3B+BTzy/z6rs
# DATA yJpfAER9VU0deng47hEyx7A9zuB0LAz7D4qcskTy6/UfJH/91/BPhTO6OLHSdkPo9Z6q0kaPA5+1Hw7UBK2P8NMeyFTvv584L17H
# DATA bHvXQWQvFoPvswN1Kcgqiq8eIaxFjedUnrz/viOTz/XNhWRFRsVFWULM3MgVnM+i2ymuCWTH0wJ+ndRej1aFv4tqpicLC02Irk/0
# DATA jKtr4v0O3EUKRF0lTLUhactkDUBr99LS3+0tl3/YLB/Wzy5PyvrvtUl5Tf+4qF5c/mFzv+48kb9XViffX6pAYnTMDAnzD/korImD
# DATA NAn9Q0ma9hJpuSDvRAqF6bHM3WvJxdUiwIcqyoB1Y2zHzR5e3OWcogNGfddSm6bThAwqVwRMT9EN0dJ0SrLLixMc3KrAYSyhaas0
# DATA Bx1MfplVAPLqTq/zs7G69yUP4Bysqu2N450kE258aSm53c7Gqm1MCpQ08cAu451MILdK4pgBzSGNnuIhDBATHYwIVD1sdgG3oX/A
# DATA 5+hhMuwcHY+yil423WFFZi/p/SVPi7LCOPn+VLITWIK8JDk4bvaO2q0rYq1EaUDRz4juK3bANbn10lAphUpXLSfUXjMzqBY0ZwoR
# DATA ShmmD5OZWz0k2oQ1KyWya6tm08J/Kr3+gwJEDawsJ4vJxUuvqP9evrSG5xxgBuHWqCZ7lUqFNhAH7DhrswsiVL/bSo6GTTUcup8d
# DATA 9Idq5IM+JE6AnH0AsjZWYpNaB4QV1mBsFbW2IFJIbX1KNtgE6mkeaEw2BJ51FhlksA7S6YiWGsfIYlBsQeXvuZiHNY+0EjmzL0oL
# DATA ot0zmPNJCVfijGfPmrzJxFlmZtbqSKqAxFk44yVTZ94Qlq2KjBcwT7oQtLS+vWnFr3SaajFvgtnhsNvvD5GBEim01jGZDQAEY0LJ
# DATA FVxM/aHqTg6HfyM5A0C7Jqixq4AA3Z4kiqBUwaAl+ThsaFJMJiXLmRKYUEnt6Wb3qK827PGJGsnbO+BYgTQ0hcm+2R9uEluKsltA
# DATA BO21UOloc97goWyog26zc5JdsbGNVbfoKUCEqlUg472pwjR1prsP24EHUFcDUFvhAPClVFVLi8l60uocHhJ0KirWESJTsZx7iuIN
# DATA W4VML5liY7AXhYQryeJSMnFMP9w3Rbr0F1qY6SwHWoAXfATwe+SbNfscsE5A3F/f5KlkNersF8P/p+4cm/UL54e6qvZo9I6x58UR
# DATA fIo6T09wOFv16DPa1DYJd+KM8x2plTqA4mOF0pFhvqnWWC2NYtKC9dscHt2nXI41gAaX+aF5odoBZ03tGyWGnLlEGZnJPkmWANSN
# DATA ubYLJPO+UaGq3iUV6RsVEnffqGSDLtzrKinA2yZvvAHZgl6vJa/CHg90w0qKHYwgHyLQY0HLxojc0xwMllD3TkPMlkSw5o/Kg6O0
# DATA WKHebB8VC2dR70I1iB5Bl+0gYVb1PKmDsGLnQC5BAq1qslqaUc8uof3e7HSVbFxVrKexDBitnVa37b26SK+C+ibAlShhPI1ctV7I
# DATA 61axkrUBRnS7OWwqkqJgaUo2X4TpTTFK7wB4mtsScFDIHqSoXUkDERADbNq+zxR4rW1SFR7jQkL5Esh19rxRAk8H2Ezn70nQAREJ
# DATA RBFib4mTcjrcEMUCP5vGiO15Mtb4nTtXd67d3tze3by11di99c7GVuPOnc3rbnHIok0W+1KApj6lutsbd1SXsVKjCa2ARFEgiUvt
# DATA Iw8GnpT29JYDI61PcUplA+I2U9y10qapzMNLffYZPEJ0NjCm6wj3f7IwLdCy9jlmPTQx40H8e1x9/Jtnv0PjXBz5zUcrqWDgh8zd
# DATA w87oGlq7kxV1LFkjZRQwHisz4u+jJxlupwLddmiHw9Hep/xFZ4YESjFqKMk9eXJl4TvQ/zTM7v9GVcHT9T8rr1xa8/W/F1df/S/9
# DATA z3el/91GOcqsvbi7YgoJULOqfYs3ikB94tyy2i11A8M8Y2wOAk55aU1+gSJI/u5nCwjyDE493c6+2I/AnUCKDNvyF9gB9d8a61+e
# DATA jNonA7jfUYXjoTqS9inuSmoF3w04rBd01ZRalkO4ybcK3VrR9Zg0uIeteaAFBUnQ/N66euPWtXeKJnUaIAi2KG9aC4J+OV8OJU+z
# DATA DJAEtYx4gwC0TO+9LCwW3hgUquw0Nndub7xVsMF6HfReSVEIuTdiySiMVbGQbm69u35j8zqfKhAD7+LbeDCXBGskDYFYzGjZZ8s4
# DATA VeoAb6unheIkCie8/OqrxVk9Mj1p3ITT6upGY/v25rvruxsO5jUeTTyhJtfIK36uEe05t+B4dNPK43+dVDf4hEkkWtjJIWH5DuBb
# DATA 9FnApejqD8KFmLEIApZP5FoJ/AS500LG5HhD8J1y99fOLrndNSWlxxScxkDuPAL5DYNYXV67jLnx7t7FvCl2WQjF6w9bhYMi6MMu
# DATA wiP+qaT0ldVXKQbN/qo4z3Rsr29t3CBpaoFSsaOLiJ1VB8PEuCNwI2iOR/2Ih4RMJuGy+OAweKP0sZ3sNBc8m4WzxUX2UpDYRQxt
# DATA QLcHJ15xEuxcUx3P9QvkuYjPluI86zdkrrbW313fvLF+1dnGPG8ZhV7arXI2+Z32aMQZ5HX7/ErnevZr0wjgyB5sKDjdnOQ9ZxZR
# DATA wMTdCO8y7LQwljjtgd9g0YH3xjZIIer3tnnSJm9UwKWHXQ0phP2Zlv7F0mOke+vlnzTLfw9w1ebPRqVcV/xLEeokJcXeuSZ9a2P3
# DATA vVu338mZfEOeSQohvdWlJUmVblJeAdwfkyh6W8kP27NNTwYvEMj727duo38uRYFrr0vbxchqX/8J6RGwH/Y+pjBLjDrmPsorrEud
# DATA p6oKOVUNa5BtqN5U8OZmr7eqDPFDMMhZsxkoCqSAc6CewW/RzclvQQmU3z8btynlCfw4HDaPUPjQhdWRq1tFdFxqDV/C4a94w/KL
# DATA sBx3YC/VZCw6npepbVrdb+/ubu9wzbc3/o87m7c3rqfOqaN1tkND1iWpWnH67du3rm4AG1NiFuktJDesukysj0fH/SHfSatJelVd
# DATA qBWbQVgo//r33vq7G4317U06adT1Aj2ho6X0TDAU4XsARagpmBRT3Iu99EdldXt50By22i34C/29UrWfKsvq/1bSK/GS28O+4tb1
# DATA RM8q3JY8rSWQOgpo0B6NvbmPK4o39HX4+xrBFnUhZrmkU7plpEGFwHe6oOF3FfwvlLsMWlV1IxfVEKvWULmetbV+7bANjGPGHDF0
# DATA rGKfPFAAsiZX5WqKV19FlKCLbnar1A36QVo4NGxJw5X+PbEnMf1Q8EfzADpAegVQu4KQV1sGjIRx715W26vDC2DD1O0CDQffokVG
# DATA qt/vt07VZMLnF2r4mk1ZVzqHBXj6+toipq6A/xTPnEm7EumXVKx6NqG+VAaQa/DqGBS2FZDPC/hcXYYneprRr6yG7mSU0JaLq7cH
# DATA Sg6mioqVUZ/0WijNKWHOTBc5eb7/vmhq8fdLtVraR8syWuqoUEUvqVdav7A+i069NcQFvWfdKtSLiaCCJ2cHXbUHhfiQHmHsk4UC
# DATA EnehWHtdE7MYu2u0bMjZl5qDzhIZw5e0Mbx4RQ28wP2Xp+LDCSNg1XQxMgANVnFFmmUDeNhqnqnc+lZVn9XWh8PmaaWT4b8c154V
# DATA 3xDDOv9b4X/Vt6rzL7kfQT3FWHftJtVnUG5vuf4GacTn7vFSegFjENt3bm9ekygCqYy164rhFAtFrbJS6+LrqyxdEjkzWqhnGqf4
# DATA EcCSae0UlPqSfBYJePpTehrVTOHhUEpUGYQ6g1wLlMCFdGGmAURktrEfMU+Mp/tSU+arrWorV4DLoP8SXhlUgf12gUMYzD2ALzB8
# DATA 6Ci+QjHGJXGwYpEo/wYVXjK4DfuGgY+mHZbb629tNDZvwn9DeYqykvPVv7Lbhot9c3h6XWJCCgRVAXklJQUaUgQOuUxX8MN+VzFo
# DATA BytdYpPoVZFjnkUlBuFUpsMsmJEKFKGs08h5ULPFJ9KRRs5fLOWoUWMie4FXwskY8yKCe5DqAG1hkcrz7yJ0/felbP7TEv2pINdt
# DATA kv7F0qggcZnUhXXE+GkfYOZXCGUrM6Q0+lP37hc1Ze5BlXXBG4Pi8F8UlTy0kcDlHlsGx8UeihHWSNSFRi3ssKAHYm4rxfk6z7jV
# DATA 5TJB8pXLA3X7wKtOmyH7bBQu6kU+dETeHOBztaBIYKmZBN5y0bkQp3LtM257l1vpNHf0n74Xed6WBapfv3ZtY2en8abasSDeUjo3
# DATA vKcT2wE9ocE/wawLecyHW1Qs6zadtep7xY/bLdCx38fE8jwnpH28kmTHzSF5fySUekJxoFMrXSZwP8tjnZLvwA1iwSTViwMTcbIq
# DATA F4iIveKV8B3b/GnVGlka2feqAA54siBZJKAu0ylgOZhBKCtI6BR1w8ZlxW953ASGJMAO0Yr6o2MA2s6px82lw3f5UoIfmXQd9sRU
# DATA oCbAOZdL/ks6/6LMlYM2gb1ghC7C5jhLcanUZJxNJgs65zsMqOrlO9xLrYswXhjOFheFFUvAvX1X5hR3kiREfwqahsVFWr5J5LJs
# DATA TZ34BrsVExbFWYoOU6rrQtApjF39hn8mpSQgmxLTjDkq/Xujemb3mt83KBnV7C2ozkvRQ9yE2N07Wzt3tkE9oO+aoSYIMrDYkFPy
# DATA lli//ggD42LKnpKB+JVPbbIII6sozQocDSQ900hBq4OaQtn+iJJpDnCAlXS0PNAhW8+kDyWrRXm5B/Fe0rI5rOi504GXah7/mXO6
# DATA r93aevPG5rXdyDTbs4shbWfqbBuBoqOraIXS61LzVfnGmvfmaNQE7gV4CyFlIH5yyrV7iU2teZBKeArckcnLsJ+TaRFrVsfAgbYA
# DATA NeNFT32bFfYWTZswycVisJv1EDAujEs7DiOI5UL8oe7kT0KGX8A3JfEB5BDB6oLLvTRxUiocpkyLt6i1gMx3aK+q7F9aY8sBfreX
# DATA UqQDJEnyLAqEDE7eh6g04w+IJ9RzZEXqE7RZkg9wb9eD6jjV4nfm/8/hn994GNB0++/q6tqra579d3Xtv/z/vzP7785p70DdvXtg
# DATA LITgFPK0cT2PKRM57KGmna+CXPAMqDbKVyjwYZaQhyPLustPON+hGGMPD3qjrvwAcD71hfzUYcHfqA0ZLvwvYi1+Z+PHoKDcuXO1
# DATA sX3nqmL0jeu3bq5vbqUL6zs7m29t3dzY2sXIBxREIOnEMP27whtVcvfYS+6O6heKbwSf44vFWmXx+5CNu125CRa9g24zy5LruB3p
# DATA qDGnjoYbV/NCDLHXH56AMxJzrFxbHx++9jWcWCNb+ejr5PXklZVV8qtkpyzI7Xk3u3v3B2987+7D5eXy3Ycrh3cfvnpYT5mFBVY8
# DATA u+spDbTBqnU+Hj0zAvNoyx5BT0JjhBUgnauUn9OWwKggZC6AK0opWVu7GDVPnH+A8CWNUFdSIT1UIe20es1UnyfFSheSQLJp2rmd
# DATA O5Hx/GcBqnPCgw1xWEArQB/hsT1v70ElADSBbYHV9xW05qYVnTUbx6cewb9qYC3KUQQukZBvDNOrmr/Q4OflGAIVdbdb8JLIqh2z
# DATA /FC8YS+8D3+pfZMCptFwVOSrxFD3wHLEDGpHoI2whT22+6mW+E+0+l1amcib4htztfcCVM+ZAsVWtVctr9SFjCltlEwkWq6Q+uWd
# DATA rEtXXFVgWdaWaVkqqVyu4DddAU0GImf8Szzw9fJP1GArjX8o1y+oR0v+s+IiTTskhzr/SFmAQyoho4jlcCMuNQMKGnHkNjuZIjZu
# DATA c7NIskRJLa6hR4ARwJN5+qxuR+tvwpV99+00sv2+CTcg3qOAwLLVH70JUC3eVgXvGp6JasyBVTs56LF8q/5FhfM7GC2vrnGic/tt
# DATA D7CUYDVWwvSoptT5fYdWV6MXs/nWF/O4NUdN32fIGsKFZKVobzYoXnSH+WK0xesJ9anN8DeeRASbowv6Q/JMcbeD+KpUdMAzMNZ7
# DATA 6QxvtfduC1Feu72xvjuLYkt2evcYfTUv5NBXxC0tl9g0KX29VQzU2ChLQgzNwT1us8TPYGyNjR+p4Vq/t64GKtGr8G2nd7R5y9ui
# DATA Of27s319fXejcfXOzo8dTad8ctppd1vM93i17bUVryTE7ACXpKyAxDjVMUmTppVw3iTiIFhu0pUgYLkplJNpKn/at27tNm6ub62/
# DATA pVVHWl84JZWwza5NsuqAZ5tXDuM2LThl4ths56EYkL8wE3EM15FWAwGirDIudtaCzR5tBRNUzGBBInWsJK/VkHXgyyL8WrmUJ554
# DATA dbGADod3RHChAxodlVZKK6uXtaOS63mFzcYatBrj8eZ1nV9j5y+/IL1I+uczs6ySRaxKgkD4whILENdusmCQ4bCuickjjV2kfG/Y
# DATA WVv8RbZpV09l/ENAiyNTGIvGebc2Kh4KgUnFtqTc6XViCDzT5/DarZvbt3Y8tW2Es4S3u2gm7WJU3XfO5o04BMu5B5MF+jo8xtwp
# DATA Mi/p94JvStDEGc17ELW84IiQxH2bJZ44VC5mUPSS54UpyWMJxHEf7NVjTTles1xPFCTMb2lP/3DrhUkhFBB0vwsySNt1Rei5gN/u
# DATA EbJ23VP34jsnnzk+Ca08tKbSRF12hDxwBCHKfK0koYurL8YPRAAy2I3MPXkymYrEUqj6gLd92mxarYE7t5N5yGO+sIxcE+cfddNG
# DATA SYOBkWjcRc8ZT6lbdA4wriS/FcGY44J76j4HXiV8S6wpbrZS3FupO87nAiK3V4XLH3gqvqzKvZy+bNHRz8Z9FA2o4LKd96Qlj3Eg
# DATA BSxZEpGVtOudrv4UyiuBtqq7wK7SEK24zOqV1GYr8O61BK+VBaxJrpHww05HnH4vLc7NWNzLoT1z1M2Vqmq3HlFYSDFQRuGkqnMQ
# DATA dWnfE+UTRjTiu9pKESffmmvbSYvJSlJZFGaRofF0wR4YcqQ9Ex5ddXd9QxoVQ2iJaTjXJGFlkpbLkXhUBTs47B9dWCTzptM6H2Wm
# DATA vgrZIwPI2+kMm+6UkNHZcqqPGWCn8HPLr8Q1zYYtHSagfUUFNLRZjbpJyDxQmT31Rd14KtkpZpzzXb7ylagL5zzWmRSlMdImol6D
# DATA JeejNuoDWcdd4XQHxYU4XXACW4c8rNaoOgFH0EkVRMEIiBP7KehqQWNa8NpE8qhQFcQPhKMKniPxhf30pJNl6O/jbKazFAerRDge
# DATA tLqoUOiiesQ9O24/lAYkTyKV77Qmsg+N3YHDVgjTo4YhAIykBTchvmvgxcncFswdNbw0O3eVnN3NYQX6SmYSixCyWe0cjMLmnzSI
# DATA cO9bE0gtBDoXW5jDSixzddYe8UO8JskSoJPUACFPbssaTGLaFvp2Lyxdh+qoQ3tmHevzS4xvr2+9tRFj7GZHSePUZ8ox5T0Lqc8R
# DATA d0/6LcCVaxn5/4XZ6TRWqgV9R5xdyHOMmcIcX1CqtTorX0cJaaakey4m7YvC03hxjB/L3TFHpM7vev5JmT+WyqA/KKjm/VChQGqO
# DATA evuF9eFBIXJIbnmdV813QKJKgu/YpwAvjK3xySDTLm/tXgbORM3soNMhxXcJs173RrVVyS88h9siN4DMHOZ/P00DB4XYQYp74CX3
# DATA JkHSixb0LFGZ7X/QWM4y5lIfd9CubLyPQTlYW7D2tOu94kBmakpq2vDHXy9MoyTNR15oQNxv+EeH4YBLLi+N+ifoVGzVwI0LqtAn
# DATA 8kt0Yw4bFd6m787Od/6NX0rPc7DoFFmiUJRE56wfVHfIWM6MMgwMzOToHL9WKMJp7nSE6nE1d/Ts66l0uV5KbwAq4tpy/1WAHaGU
# DATA DhlphHIca0yiqpNmr3MIUginsDIehntO96JZqSTjED40Wb855xUmJLT1INFzy/PjNZmuPEnMqqhoi0xzNTIJBHbsbUkfc+3e+ATB
# DATA TgtCNGbq6l6KrRG6QFuKj1C7bhoomEO3GG8oIrJa5BMzAeLKAh1Z445v0PPIIlajOfOZ00acsgpxmmBkb6490CgsTK/dTObsL3mp
# DATA JK2aq7cUI0Yza2/gnxAHGKyhUMcQ3NAzJTdzneddKkJlsjhXNU9W8GZ++kGPttxxj1T9C+c/2GNzO/fiGOOqxVT1NWDRuS/8rwEJ
# DATA 7vj/nXSOGN/vG3UBnO7/d3Fl5eIlH/9lZXX5v/z/vov/fe+lpXE2XNrv9JYgaGJwOjru9y5ClNitAeSdTzgzKoSONnsGLjPAJXWg
# DATA IwGL0/MKZHe65vAI/e0WtFfg4JS88UCTATtXPPHkNwXy/j3cBr+2G2AAHwMpCwRJBrz8ZvsF2l6ECy+cmSoKRdNq05SqE83E+BOn
# DATA 6zb3FdsLkRCuMQCyUaXdwJJOzJdttaWKtNW4QgFLciuUPC0V8MpWC9lQnxLQggCWwdu5q7E+NXfhGZ9KqIT5NLAl2zpoju+3hliD
# DATA oH8HjOS4OUQ8klWNR4JPbEgS9QDORJOPTK60MmT3hptvD9DoDXYKHCf7DQ/Ht+3OxqPgtov5jYvBac5FphspWZ0YToPtFiV36rVN
# DATA mA1A6hdNppiw6fmUWRG7z4GlTKtZajXuUk1n8eLB1vjfUizmThvna6yOw2CqO2pn1mAX2jeYouDkSDhNs9tRYlJmNpofdJZxRCUG
# DATA Xr4wWAo91rG0Ek7xtbazaGExwxDqqsV/lLINSbSDuessFmQ0jBhCgxdjJ8RCeSWub+0AyIpVJMTDmYbFUpo9srfZKZbTChoo2XPw
# DATA B/qqrm//olqmnGvktO44RTu3mm/CBTkX9OTMAz2ZfLegJ3M4EtKzgul6yXVWZqIqGVdpMAmurV30Blwzftc4VZeXi/nWE52yKIdb
# DATA 0PpRQrtRn1IQF/C/FkmBwuy+mgFg1O5uLXEY93TcnFL0PbZCPedwh5pLSO4WiQV8IlFq1ilBEzmWamMc4oiLWnLmtKc6h9FptK85
# DATA 2E3CbDn4QLX45u1bW7uNja3r8oxNvPexn5C/feL3qMdNBn3SNjIQ6RpWlCDaH16cDS54QYdZm+f7BTgqoM0ryQyD8gtOP6mZ7yXX
# DATA kWUIJlrGvl/Ng2E/yxLMUKCDvXUI26iPgOcH6FuJSRq5sp8CDD+8kk841pYwCNRzCoLZb4PgS76cLcJHb57sd47G/XHGcbkcRZux
# DATA JzN8JRpKezIgQB5fYHnrWY3pkQLe45djhuQvWLH4Bauec69Z3v+wf0hNe+TE4B+sHGcshyrZTEynIusWs7LowGOz4YWW9exO2ViH
# DATA cVQC1/Vaj4J5qD8S5j7xmNBA/W12mVoujXylGwHWBaBZ9/Oxu6KsW29MZ4zsWSpw6lnAKTOLVdbIJk14/w1IA+D43avdMu6OjBIw
# DATA axOwouqmMVIb9Doyo3ErdiY9wAWdQ7DZxFSDjtT5NwimravqP+ihwQ+rrAy5UJVcapbrlPDx+GBY6fSXuv0R+FEvmXDhAA7GcXKx
# DATA JoFIGdqasbLDthJAOnyPcju1RJ0qr2jPn6o7FtSk6c+1iBB20gl5Dl9PZlMfVD7/+YluY+aHr2c2SzyT7kftE3BQi91hvQjyQgA+
# DATA IHgEcm/UD3TgPAWSQxuhcVjewEJCCzy9QMC+myGoTlstPBS9XQbEL2pVqM3xeGBvDCqF0cy1ruI/rSY2XJURTel+UXuBE1QIBBsr
# DATA sRsSXqI0UrNwN9RPf0+qR4W9ReujOhnCahQ7ftAcQBaxRn88Gozl4Yhwp2orl5c10+Rx0rBAEWomyMoxyjH+JP46dwpo2rK1AQ1L
# DATA DqYkHeAtkjEy4c8xyr8MhJKN+vQT4VAEDAUhXiZgd2HoFMvblBLPoO8X9prSNGK8kwXE025mBNxfcBMepZDfbXxwnFg3BsgM+fyD
# DATA Z48BJyl59tXzj55/iOkkIfvk4+cfQ3LI5NljSS2ZelDz4EJ/r6dYRXLYbeKIGcHpQ0zpy1IHfyzQTwjM9Ck2+x/PngJ8E7XiZaQM
# DATA 24JMIeB+0wfYk16n3cIGLXio5Nln6vu/YJ7LfwYQ87COa80eQ4wCiJHIONzRVrN9guaxlB8gnJWNP/UkVifziCa7OlmqHvz+c8yB
# DATA /AFm4PwI0K7UzMQTf6oXkYkueiurqRHtskCMlKGQ6J8MGUQBiizplb4Od3pCRPIICI3huGzwLZmAp3ld/VVik86zR6mfLFQuFGG6
# DATA 2cJh+uxfKBW0mo5Pnz2S1gpnestNikwunyHCF3TsF5gy+hEA45eoV58mZ8H2nVThIYx/UknsfNSSmv6x+ucxfgzIYJD59PlHrjOu
# DATA 2VyKWRguhU4iwHAKhNGDKhbbNSuIBQkhZTxnrVhQCBh6Qw0e1mfKNXsHx+6NkWcbVrcA0/sI08dCiu0/zkZHyyF0R4W25/vLDJwu
# DATA Sdyzyx1JD4ZBazgXbgBJsW7Pgi4qOjQJbYQXhaJjqgvUa+7w/7uT//ZPmgN9rYlg6tCQVqVEhsNoVrTvy6zCieo9vVPRYyVWJYZo
# DATA SIFu9LDquIN03TgdCPQk00EQl0N0Zd1Ly4f8Jbwr1uuCFcLWC4pTapA1kKGxUFnIj8jA2yAvRJ0Om3Odxs5n1Vi33R7UCJkb/jQo
# DATA VvYmMYaHWJYFiKQzvxZygapN73kjkazFYUp25TfFgmfilcIQLdhhwWZF6YnL6hUzJfWjqiPx+TQ+NXgKU6fUQuZSXMgLsnGlJSIY
# DATA hkBLF4kkRfgol3v9MqoGBpiuQD8DiDDkQ5jPlR4fgmsinlnsIQIrDGKXb6zwxLgFzzfPcc32Qm/wrpO7Z3+rduofeHPSIenu1khC
# DATA k3kElgUbEx+5qCHzYoVyHcBp6qLhz4KYd7xiwWJXaSmKhz/Yq63oq8wjAGr8Z90puscp5+typXLeoqtfuj/udEH4Me5+5utzwoG5
# DATA GjwfEGw2RJtpmLTU0qZXcddR2kPNnX5FX+tEhV2GbGOq/sgtcLLguG/hQlo8qhh6biG8JeimxWyKmQfFcloZjw5wyQ/hSSH9wY9/
# DATA cPKD1u4P3v7BzR/s/IR826JeX3vVy6xoOodrFiI+JOIRBg5ZFIWKe43mkV0qaPZIwLCCWKNzUkocaP2qbEKISraDOauJJrXJQugR
# DATA gp0r6R4UF6Y5klG/ifTFmWy+L8Vc4X5Lv5jfidbGmSn91Jottw0reZ69+R40s8aQ4DlVhUYFJrieVq4EfTFvYKiCx2TpFlcuN+mC
# DATA Vi7/bNzB9Ll6voVZ+kFNdr2G8ZkORBi7g5hpbo52TRZztjUq7ngdhNFc2FIOyGDrRO8+gYgZn3IriYTpv3Zjb5WslAcWLqwIucEu
# DATA ZXO/jW/JWoNG1XNetjtjQ86GWJl2dzy0zBy/yByCcd2oTLV51pMIPmzMBGKJ+lJjdSFML1dx0IcjgyJlpQYf5omzNCDVfF2KOcnJ
# DATA EEJTW53pN2qN19u4upIISEhAyzNE5UBXlCMIR7RkRs41WTjrMwUj2cAyNcE8wAg6owZ3WlikRTc0RaFoXIytrI3P580bWg5UqftR
# DATA ObDkSr3YjWJwi9IVfS/ZGfUHA4QhOxKo14weVZL1RLgDZqrqZKrPnL4VTTfqspsgKqz4K6kZfIg21utXK8HaUqe1SgsFy1ZbWKX6
# DATA IUJKBOd3UVFGuUURujbXQkXmHn2OLi1wQwq5rK3mtD4PHTsbqAyBqJrCpeViPCI6wvb10F6Q8TtNfKO83j9TaMbOwvim43azi+HR
# DATA 04+Bt7GY/QSKjLO4v/B8RwpZ6rgDoA8lvpXSk1NfYZ9Xf559BD2iyaYCgGz5fDngyEaCxTqQq872muXbyb9q1SXcM1h5iej1oEX4
# DATA ErRnpF76ii8xn6HubK6EjTN0EmncGLivtu692DLJ2tfU3uzJrGPE29T1k5UnHXZLXYxIG634UCtv0bxJ+v3M+5oB/3/+C1DmJbbq
# DATA 8dnnzz9Onv0RLnX4iMH+ozOAGobC6jxw5hHd0Eeolv3zs69AHQia2S9AJ/sV6qM/5QH8+lwrk3P1n4N9x8/gRrd5CikySPvxzSst
# DATA mHMsLorwbo7oNzkyJDakiSsxhaKDrVbCvx3HlxxHfKmCsV71sUuH7PxHqoG9daNiPHn+P/HEInd60sTB3a2gMa2GGabmEW/gyvrw
# DATA aAzsbBvfFMSKqMZeazTUsdFoFK0vwYbXaPInhVSr0QlHH/QNNSCT7KDPSPuZElfEJIUKQZEjSK3Y7rZIjUhxUSQ+sd0TfpFZjYxY
# DATA rFoiMBm0d4khG1lsqiOIynAHgJ+SdAVNuyg2oQEMM5yMh11bpRYdXhlv5tjLKZNQLmNcCoTXnQ7aNZ2RCy12NfkG/4GvMnNtg18V
# DATA y/qnOKmeuzyZmb7BaSnZ/gcOB8BC5FWlTnNPusOXlnnZdUxAipZ7SryPvKaWHE5L7/Mh/JSWy5Gl8DnOmY5AZG38Mji4Wq9fQ99X
# DATA rt53zwgOTt8CRgfll2gBUmz/XHw2qg2mARluowvmqoJBMqLe75lh1actLWc3tHmac9qIXt0uTFXThQ7/5psc/u1o2PGJvkvgL61r
# DATA 11p0Qz0NtUvAfq4WrYGGhUYDKaDRAKbSaKQR305iN7luiDr1xTvt09mJL0BP3/bgVYfgx5M++3c8yv//9r71ua3rujef+Vccy/U9
# DATA gASAD1FyAgV1KBKW2UgkS1J2XBDBgMAhiRgEUBxQEiPxTuw0t+0kk04799OdaTu99879rDhxItux8y9Q/1H3euzn2efggKTcJFds
# DATA YwEH++zn2muvvR6/9Rmd3jktLpaZDwy3dwKPTZJ1uiWyPHISIMxbDSf61y//CRqByshiCYf851A7tF8JBCU+595A5iFs+lN892M0
# DATA laEMJ2QCFOlKgXjtY8pkBMrovzeScmPPXgDtorEI2wSIV7ht1iD+gazyBimeUs6hwuKfR4TUn/efpfLHe/SVw79nx38tLiwvLyfw
# DATA 35duLr6O//qvjf/a1jDvmKgjGhMCB2n3E/Ff8R1xdgpevt+bQCou6eTAwmicLwYsiRovsye22D/BjxR/8YgwzL74Rx8fNpMZGfvo
# DATA j+vUWPxa9aYSu5UM5z1TqCtZXvAszvcAsKI3OSUDbtWCfLZj3Avh3kJY+dEQHOghehruWR9Jn3byaDe1nqHhUCTtrsWiRjay4uQb
# DATA 1aXlpsKV7gzHgKCqYYAwCF17tFJaNwMOQeGrJqxNcSilY3opE4DUzAjDuAbb9XvrO7vbH4Y2vpOJ7ET1HvaH+4XwusR2tTyTpUeI
# DATA p+FZGjc8Biw50g4el+1BsklUOnkWOE/a3HvQ/urm9loyITPUlAlFq9Ys6YhJ7vKepTOgcefUOOCRdqWRTvbquWdCvZK2ERGSxNw1
# DATA aWaLdHWyoemgu4mRejOKkyvw4/ajqOy1hxJcBxQEoH3eYt4OPhTsCfIENdHODdu/PSC8LrhpneUZo75PXGqg2TcVzg0x6P0tQkgZ
# DATA WK9IwRAIAJUZFxEsauYtsgmXzCgWiiW94oexNGl6d3MT4Cs/RKLesd2iqA4Zt8u3ZRuDDI/QdreMPubaxXp4EJAPKZkljtF0wdxb
# DATA hqGI+2j0pN2RFCuT1hEbdgDBszaCIvqW41yG7Mh87uNtHGZ4ZrSdvktssFCjtIc6dPNTIazTumPd9SRvYJsC7CWjemtHJZo1XQpK
# DATA xoYLi2cJ/oUve6MzDJtErxsbxhXL5pFiYJHxD0U7QGEgKDmm1Bu3ZTizJ499u3wAQcNPF5dKt5fPQr9jItSUl4Wvbm7srqxv1LcB
# DATA s7O+sbtpHySKkGex8VyHDpALv5geUiNq/YOYj+FjwnbTCzCfwvEwGLQ3nM8s6FPfq1iRKU3MElJyloyKRXkDmZXFtYx4ixQjjD4d
# DATA ZwiW8YTFgJc+Taih4ZFxBAahanWZsRS5Yny88EBGlRXIbSeIIRmX1FDVNc0YTseu4dHXSDVNMQfQsznv3KPkeUSuZSpgPPShyXnH
# DATA yE6MKR7Pcz44G/QwYScF+IfF/PjMCyyoN63HIuE3TJkpU5zYZA+OdTKHSjYaD6fGE4eNykLjHaVEI22QPeQ6tsNDTYlW9DpZ00yl
# DATA jCORSjTVvpo42hSkA+bZASCTOGvoqeI1yrgOcJnT9jCuyFyo4cDUUSchCDEvC0ve7UmhmIWVmDdlSsGXM8WMNaWZId97eJwov7iw
# DATA sFAsZsMnZk/Q5gfiCPHnSvZ5/+bITVzMCfJOzK5hy4FNy9WQw3SFQIAOYWeulEFVzE1NlpxLe+yTYebm7tfvraySbElpznde8fmX
# DATA 9wiUGApsjsFAXRRTLSAFHkpKdjmd2TXHaZWcCQkQfDIa4WV5SifSekpbIbWHNmDt1J7OGm5aVFgUh5GhrGmNIyH2wV1Bem5UpTui
# DATA 9OnI9sArJqV7jReg3NemQBSkB/47rm3KBI3RXmDtxjMzqy3teWLAIWRkqssR4awUWC3T1kiY0VKi4PBmDS9jhmEYjkRpadFyIPC4
# DATA qEw5BWntE6mDnFSqYjvUqZhMlOMpoI60PKoo97i67AXlFV9OLnIxuepLiRsKf6DdiSxh3tgo5FJnuhytdw0MqzTgJ88UiapyYAzY
# DATA 5Ky/veH0wg/Po2WBpP/QtO6pPUAt97omHpf+tZgvUt3L4/O5xl0gIt3koI5iEg8Le3+myPgwx86mzNOVaTeOxG1jhptG/luG5efd
# DATA SOajmfH2kbx5wJwaXx1+RnkF6DbhB9y+yFVCD0prGceFqZcL596Z42pxyWvFha4Uea8TOa8SV3eNyLwcXMEdY/b7RYpboiaPuZw3
# DATA kfy3EA9KiIkkoa8cmP/C1U1rPzPxo2ClaYI7uOZF3XhViWOoypwiV55dLYRFSU2v7LJGtSD5LHJFMhVrmwypJcFVd9+U1rRmKpfc
# DATA 5+CMsHwi3bUw/2iWeIHU9GD93vbK7vrmRmtn8+H2aj20Am2l8xSHH40I4kYzdbG2ujw9ctfL5PYjSLNBsFCW0RJPN6hc69G5pG0W
# DATA 5IcJSn+jloNrp0wAbieV/u3B+s6Dld3V95IWRNCtc/uCLyNx0wEjPcJodQgRNv/quw9KxtJDG7UEJAu0IO+J6AnI1hfZNupAW9o0
# DATA Y2EdJTO60UtmavQUQWgJpSBcpTxCK91q12x6mrLqpLyMdQ4DdyzVhIzjWKCy65y6GyBxGxmR69v1tTAdtzTPpclFwskzazv17ffX
# DATA 1S58EwWKOBDnP5q9yoQMJS1fdJrHEAcnpiDYHw8fx6i8Hp1M4spcQrJpeAKrrvs2TjORTtKnYZ2emfoCJnxXIEg5q6QWRjyQOfMY
# DATA oLklZHIgAtoSSaTVNBAP46KpR5IT2VZn3GvwfsKesmAlvxNki7kBOFfAXFJSScMVMSa55uSMdT3/ATSPvjTN44H7immdsyhy5cHd
# DATA 9XsPNx/u0JLsrmzfq++Gs+UINMauEwUuyED4BO9ycm2h4EBVhBhBWPVEECpPAG1F4kd49ztTPjInIAgLUYDbG5wc7yt1BlqskY8E
# DATA DIzGGGzQ+h0FKyIRwUfRGHAUYsQUQsQx3JQYZAcaI2W2Bo8jzLatRHLsAbedWyvxJ6KMsCyBV6GNMLZVwq5oNMZMPle8GsyQCcpW
# DATA EbKqBNSedEZGKVi1fciXOTjUsL1bYvnE/Rv3Fiwu9IgLQaf4Y8zQwZZhTjRW0gXA+0t3OgOcElo0IUA5u0hTAn72Dg4iVM+sb+na
# DATA jyEeFMA6gzb2sxJs4AkhxDmg4/bAcFeEHKERwBV6mYQjQzr7W2tfEtt7KiqeoYFIb2Ca+kAKpNbtgrkIn5GO0GH8iB6eNVUyKTro
# DATA YmYPjVdTeRhX8FT5PLJOQDk8OptP15qIxMKkd8m4uLRr/lRAKqUDmK71OLsaAfrNYFfwSbUgsMHIyUfyVbl8cF49ipD1juOj3ggQ
# DATA awcEdyQvWl3Gn0xYlnynhTmr3jNDF/CdHDmxvpLGA0+GdwjzaEO4cWsyRGoxSCGnmUBvigsgjc6l4Hgq2w8beyqu9Uclf/enpE9L
# DATA aF8jPy3jyXDs2CpVX96Y0b7kVuXI2RoRPB1kNMWzsFjM4nVeQZQZpqTuImQXvoB3HVGeB3J/GjA+P7RhdpKZzcysEkTB9NgMXqVH
# DATA BfqHsqNSr8xcyXbIVB5/YoDsQT4NeaPI29f0TbyEuKdHIcU86QhnuO6aZ5SURJJrmYUC4N7jXPQXBpqkVjK2bU4ryKVMbdzoBUAI
# DATA CGSGLeB0lTKdOl3LkPQwTx6uyUtP4pKeSFMqpVl4nthCySh48qs1XF+NS1dKH+gVX8NaDJPOESU0yXp8eacd+dJL1HA2Sxg3NFKE
# DATA Raw2XC/X48WeMSTcxEuoWjOcPNOBHzC1ri7Ij8FDRGY+tkfPZ463R9NPnqn+JLm8SPQoS6pD4cmg/ajd67f3CQMmTNNHX8l1Ml1N
# DATA Tf3C5InUwZBjx8Wj/eGwb/qnqytJRn0UXF2lcTaq4oLXdPzXsVbdTf1TVrXa/yeV7M88IKnqFt3unjJijQJZXpKQK4AlwTl38Yg4
# DATA Hgp+Nxz0OpiVm8sTZNcRAFomCn1XVeED0fJvl5m3iu3nb98OHc/+7QgNvPr35IYpamljrEsDIdnAGon3M3Ym1OaAqXih8VOGZNWT
# DATA 7Ie97zO6YQOLZLFjjQUqkToy1asrax8qHyE+VS0Ftop21zprHQCvhTuEYTDhtSPjkeRm/aG4TufXV29u1ckaYqut8+nZNRiF1WPZ
# DATA 25QeUTx1lmQCoBS2cOJIJE27QcQIoPYkcAU2ihWIwx7Fm8WFBQWI0Rn2h2NPtaad2CC5rL6qXjCWhgLf8PRRLpjU+RSTolZyNt+o
# DATA 8YqbgpbkSpKqVNCFeUobqr6JuLGQpg80eHJ1FbgpGm0nEIoC6Iq9iSjH6kBAygITYjQCjQ9mLpXKvmnywR8tBqwN/aoxTH2orqZR
# DATA xXPlkoWn2lnYzAHagp31jXsSvhU190rfZ5Iiq7s2MY4RLFfddh+MRCx+gmkQESVxnTisJa4EUqs7OWpPDL0CLD3XiDGjQAWkkjgE
# DATA VRjqGSaPh2VJEDqjo7S1tGUyHCSJCuNadrunCNWcqiuAu9KqLEaiiuhVixDYagCCKX4LpbxKK2ANiULZ1KXcDi40RAA6biKV4T5G
# DATA fv40YdnmFm1XGXRvkr30hBNav2lVAG0bR2wyr9RiP9FGq7mXUHE1DJ7uDWg3Y3ZenpPEfbJ6c2FxYW9wZmYdPx6KSyklV6LBNnhY
# DATA TerKI0H+x9bc4YYExT0nKDJ9ZUuYrY9deakCAJbhExF0rGFqAiIuzxg5+AZhFvKE2bUiuXO989GkM4/l5jWBkIoOyIGGWDRTxCiq
# DATA 0Z/BdYWGZS+hhj/GYGLBu2oyDTA0LtdFs1tVo1zyKyEyTQm806VwzgU0MA/YMdo6pZxkDLI98lsmMoughrhF6c7Pik6WLH7Tusxg
# DATA bqT2sfSGMhmXJ3t3Cgd7b2WntVbfqm+s1Td2JT+T2pwckNFpGeopN70RNVj2ox37s9TPgFWs7qozwBC7cMNNHaWKy6WXqmpof+t8
# DATA jEKOsJN2n8G76DgH6ErBvYfizikucHfYY0mekoGYIdNf/U07g0fAEkRwDJnKSLkSwzVAMPL2IDAmEc9hrTRWfAJ63cQb4IFymmoY
# DATA eYjMdYBZh2qaqdVIgQZqCQfDcHaEZY06lP1a/vLT4ZhT37QBmW1EODp3U0Ny86kBLxDbSw7/7X6LOuBG5BrdKpIFR31XHopOHiVV
# DATA owq0Twnx1eG9WdXp++pToIqqGZvL+0wH5UKJs6Jv/5yxPxiAmnYtWOv/egTeVBLJjcir2THmEnSgTgoGuJIfc8yB7U3ZHRmkLGF9
# DATA MWloqDJ4Ry121HKBBdU6qFgN8vzqtidRggi93fH5k5l8V+Mxcq0JY1xi0b1a7OT08/34euIonLEeSl+F1wcMGU9WyCd3Doo30615
# DATA qL+Yy/C4XX+wKe7uqFVY3dx4d337Qd0B37A3d9VxHaf9bp/R9huOEvTALwf5vMMxW2UCKaNpbWUlv0rbJqe5zISgcHukXkbxWxrC
# DATA 5VPOnXkYpfSRjOs5mzI6p1lDMR2f1CgvWU4xM7GKM30Jf+aUreGNlVVZYy2hBTAtnftUKOTicVs9KKbG1XKNHlJK9h2y14IsgYRt
# DATA UrjxMxiEkkJu0zvroPfIIubkQa6PKvY6TYNyNc7IksGVTOAKAktRAJ+o5ZbngNQXs3rfA/sKQTvEQP3cfBocrHcvmyxklqmYsr9d
# DATA +WKGVqx5dOpx8YtTRBNPE0apkwFdtBOxG3SZsdELOJAoYfDyRlJljpJHyvkm0Org2KjTfa78kRhTFVuzI/dmhmSYqL7ZiL4wky6K
# DATA rxlKoKleWURAl9jN6XQqj36DU1YTab8UY6zKt21opDQwDi0R55TGba8pVy5XJHpJBDDT5z8pqhftdljRZMLdS693WY0RB+BD2FGQ
# DATA V1YZU2mh5XXTNZSyRZlRx2lrWWJOrRXKW+04ZsdRSRAMFogXno74DjMtvqM+B/EEO9I4EItl0Nm0lTo5wz85EVOb8MjJ5ZdRnHVh
# DATA XddsmW2Lba5WcEe+XSHjvwPTlVl0G6K/QzcUhBzHBo80nVhHDP9izQM8o4gwiL+Kez+Ogr8Mbt+6dfP2LN7o9Y33DVlIO6WCJ0cP
# DATA FNH9wjj8oScMvFYwQgPKzRt7lezvxb+ghCtZ+jqIJak8SCAmKYfNmuWwaS6T46BpH16UMY3oWuYDW324s9vaeXh3Z3V7fQtDhLbr
# DATA D3fqPDZQh1DVgnHsDZRF73LhMGT3dEJgzHh2jkuyZHa7eFFLxfJRMr3zn6yZJodqkZbRn4vOa1fJsrEzxIQG0jQvMJkTbe1OtFQY
# DATA Jno3YLwoY7joQqJD7djb1/X5o+DXy0VR57tlpgTIpcxNEpGDO9OQHWk2uANNB4LS3glWGFROJI0pIxF35I36Km/kv364riOc/BnB
# DATA UrsEqYhzLHvC9UmyHHFcRuNJizlFi9lCnIyrJWIvXSJVnmuLSJcTE8ptd6ucJV9OMrQGr0jTSHSj7NuuK5Scj4c0Ee9TbbhkHuD1
# DATA ZMplz3u81GubH2wIsl2rt+7e31z9fn1NzJbg0yBqYq3g/Q2GT/ziWGX8mSn172m5KVMoJkkXOimcPJrc9zxFMxPQERPXhZmNFdPT
# DATA r83kx4ayBA+evG3pcckdiuqmkb+Nj4eLZLxLq92X95DuZTwotP7ly+KUxxr1R2SByt7dOTbxq7DJXNzGMrM1J8sm84pS/r0JJwnl
# DATA 64wjsYriQ//0Dl5ZjGAYGcsRRxBdTL8O+31oLyBzeGXuT95i4bPHXJ0l7OptWxe0rV2NJcw6/q/ccpM8eq9fLzwNXUOOxHmedjoh
# DATA y0wKNfrCAK4F0+xB+VNBXtxydAGteKad55UnyfK69E3L6mi69M1mfZndqnMZY0NulXsyZV2G8jgZEJBUf1vWHvu3LPMRV67MQlhP
# DATA /tfTTF0zTXiKgcwAQ7+E6ediRhCZho9bcfIFZya1uwrrxkUT3r22jGRYRr7pbICpjM5MBkh0dTK29WOOoK8j11IwKKlUKvoMBw9I
# DATA 3wZXx1Zwmyvq6DnDadqn+U7eSBDKQGn4yKGzRi4VwyentVDCcoTTcTdygm0wqoIPUWHuqu6MuaaeA/osNbwNgpIjZhYYsT0Plfag
# DATA czQcT3dBXFvfrq8C/gJ6QNQfbO1+qKMAezK4fQZNvGVTUFKdBEQwBiNEfoQ3KxqQotjOJfqMmn5wOVURHop0lAdpvkCO7c0fGJUS
# DATA SRrB2TLS1h/2avelpn2y5Ujd+tIGuvlgZT2haEOra378UdID9/oTuif1IfK3JiqoMBqyvHjyKqJOXq6ojFJFe5CxRAybmbyFkZc0
# DATA dqcfX3UvMldOYgeIlfsrQR2t+g/Wd3Z3wsRWJNUNs5p01QuxP0vv0juwhp+kctNfdUVHhIwj5olBe9w56j2K+GbLdaHTaDAcdKI7
# DATA Mru7oU57MzgZYNh/pFvsQc6T9oCjCCIwBVDak/0xbHvtosrtpalkVMdmdBA2qs6lo0mwhewQf+cJsD0T+MBTzUVxoVycBTwn5KTN
# DATA yyv8ieXKpMtnD71EYFKt4UfGTOiXO0fixQK+V8xAsLYSkYkifHSIvo767U7kBamuHU0mo+q8himv3lygQC1fYVhmuQ0qYw1y69Mh
# DATA Je2rJbPfFpzKUzv61Iitq4JfkKD5uAxehaOIQguFmIrqk2rQsJwZVFNFR/EejhDVRpQ/CBeX3q4siP9brD6Fp2cY4OFq6onpwBtP
# DATA HagDErfK42E/zTnCrWl4eEhhuU/D7riHuX7JxFaWOqDhSOoPn4bH7SdlMBxDocWFY9JBPinzeMOb4ZnbAEVMdo6izkdYw0TMHQw1
# DATA XH2whtKloDrkqfjfgwhwAK7xuuvJgFmYR1OhkJXnqc5rxYrgPoPCuPaXMlga842OK8OP3lmoLhaLlQ7CChSKTgnxE8f9iwqFRANd
# DATA v4VMnsNy9QPB24BLiQeLSxRKOZ60RtG4NwQ/sHBpIRZDTjtcYcYbcrHENW4qLAVc7eijbV99KkO0Ey4wtCzJdabYbt01Pg7cvvFj
# DATA 6erPAAIqL7WlNiHrqfXGU/WG6MWZegu6BLlfYLG0txwPgSvQXXNlizRlrbWRdFSQFLMvFjVVTAzQMA/LuCmLCdDD6pKQTka9QRTm
# DATA 4AeSreDE3Ntcq999eA8KH4uZ68GVbdIZ1RZCnEDJCsJvL1S/jbxueflmVfzP+Dh/0h0hActQLh+r0TOEzkxVX0hVdTxU4mQZ4jer
# DATA 8/Bf/YwmpTrPKmDL7ZqmS3aBJknXJCnCrAefnU1jxyRHlaUcJe4Jrmb/1fiNOYzLdoytIgpIIUkkDrqA676eXBfP8IoW1gJ9OLsE
# DATA vkyqK5upTMvUg6aq/HMoT7vTlQnyXmarNb06qNzmsDM3JIcgMW0sNIYpxqTgVT7kxzGi4chstJWV8eEJ7NYt/KUgMdtAV9BqidVr
# DATA tYrGmxVB3602v1IIVWg20CzBBdcaoVKllzV+MaGLoF96SBg0E77vsBJDm15OxpFiyeWTcZ9/4YtAGRC18fACiUod28oREG8pgl4Y
# DATA 9wAvkWWOtkTmdRJHZeA7+hvVRGKRG6wvT0Ef2EAzY2bKZSBfURrCR2tbqP2SnhuGYGl6h9ueLyEK8wh5l5op1poiez70iOVYe8d2
# DATA /kyq6gnWyQYVGhzZTkyUAv8AQQLVPrOQuB6t+VgW/4HSsYZKwtT2NgqAl1JceAR0t+qeHI/ighcZG+sl5QZ+NIC48bvJJ6NBLMir
# DATA 1Y47vR5jI7MY38/qYRRaOl+0t2Nh0q+JFUAfJv2cPEox6veS7jkmXKppv6oFTg9KtqILnAhRaeX2p6jWQr3qGO/01EuE82lTzFcF
# DATA /KyMc/RSqrefZ1BT1gK3dQZ1SOQq1duLLLjLMzLac1GH3VkyVG0036wXuUCvDLaV0SED6NbtCzy8eMOaQ5rIG37X6ZyzwN8Mwszs
# DATA h+Tu7uil2nq2Vo1Ng/pXtyuGE67SYhkTCcqOEK+qHvpn+RyKhLpxCtA3NOLZw5WHopHyl3X9iYVFb8Nu3o2Y3aw+gKuO6AtWi+ym
# DATA Z2dE07pinfgJ9HflxZvSrWL6Pnn6UXTKDkQYjGWFjHkP2+LZBfaOPp6TiD8Jk0RyFGo6pXWisdDMbtAQAdKulQa5S4fvq1gtLX65
# DATA Q9VwPGnrJGs2jeQSGiqb5DRYlBB1RcdaaDFqtbBLrRbsw1aLewRrHPcOByeICFiAj+1+ZWf93m59+0Ep0N/fe7hlZkin5/RPgSoo
# DATA BZxD5HpL3MROtZol6fpCsvfchf0+SVzYOYX89HVoRXtxgnJl+CgajaOD3pMM108bY9bKL6vQ+HJldPR0T1yFY0zl7cIUp0s1okfn
# DATA /xKc/+HlT84/O//t+Vfiv58HLz9++Yl48Fx8ffHyf5x/FsDzl5+IYudfn//m/IvzL1/+8uXfi6Lw+z8F51/AL8/x5S/PX1SC8/8j
# DATA yjwX1b14+Qm8/fz8N1D/y4+tcgH8PzT84vzT8+ei5Fcvfw6N/50o8vn5l8HK1npZPP1a1AUtPb8D/frpy3+EisTzT8XnX4pvz0UP
# DATA nA4/xw6L+s9/d/57fBkrqLi3bFLfrqyu1nd2Wu+urN/nCfl3UdfXolOfiX+/gNpyjZsb/QO+/LkoT40GZnUvf4Ez8t7u7tZOWc9L
# DATA KRDFv8ZR/FRU+RV//oV4Tq99LBr8pX/2nsPsBeZEOdPx8udyAH8QXz8WpWCJ/lVMHBWDzn6hum/N2cufJ+YMI05a74q5aj2AoJS7
# DATA YCtaf39lt45T939TFg8HKPr9W/gql/0rmAHxECjvOYyXDCw4OOgEPjIGuXB7YUF0/X/LauWM4/fnouNixIkOS1uk7jh21CHRr89/
# DATA 9fLnYm2JBmchywC7h5OGk/l77tWvcLyfiY+Lt4Pv9+6mdkynxfT0K23r/Ep8+B3086ei3IsS/orNfwmE+UJ+f87TiARYDUC1HVfn
# DATA 2d0wetI+HvXRETDROaRQ7prFLP4ntSB6JUj110A8ds+wsc/EbP4UG/5YFMa6xLrxq1/ycn358hdA6W4FSKN/wJH84vx3oprPcSba
# DATA J5Oh2cuzdKYs2SB6T2kOLeSH838TNcMyPRdc4kWCcXh2Ci/m75ACYSf+Q8a2Fh//OTj/rViTnyBtf4kr8YUo9ZUgnxfnv8ZfqO1f
# DATA AjsTdX2ByyupTHC1n4sqRRfgV/GbIMpPKnBofOvP+G/SF6LE6attY0H83V5exn/Fn/Pv0tLy4m35jJ+/vbh0+1vBwjcxASegwRJN
# DATA fuv/z79r166tRuMJheJGAbv5gDDLeUW1+ZhUdNHjYFvasqSrFAUaYNBu7xivhVKpKr9TRaQSk8/gGiI/D+M5jMQBo0i/tx/wY5DR
# DATA ZZGxqkxLZurJqfooONEIxPQ5qpCFTFkhXUlLlmmoRQ/jUoAXA9YVC4l6EMf9wnWQr0sIcslhmQftXh+uP8zraqE40D8DViNYxk+Q
# DATA rUiWslUX8jQwMMG6Xrz8O2ZawPGY5bBYA2cu8t+voaA4YEjysUShF8izRBOfQFWi1Bd4Qj4PXWRyQ24Vgy80Qh4JePLBWCCRH6TG
# DATA qsGQxJ2nPZrAaIYnE3hINjuFanzLcBxBHGlSr3eG3awsYs4MeZCUK4RxJN0BNQW2Ru3euHA0jCcM56B/KlHyGHPp4lqoPOrIf0m+
# DATA yWYL8TZ4d/UeUYwN3vmMKous9RAVG4jpeC2yXrVjrMENrIN4eeKAGxFwFX4P9wZ7472FcKqmk+R+lB+ASPikk2KaOJkDlIlABgOp
# DATA lKUwcYSj2P3i5c+AGEBO+xRfEVSSzDM8MpAEYFTJEPDFhaXl4Dr+M7XD/5GkPT5hmYJV5+Ekl50XYytL6Q0FohemhCaO7n8AGS14
# DATA 0LurUr1ti4s3+hIF8dBlR7D00d+egIMJuFeDE+pJzJilEsUWTAhAQxVFAC0idLHG+An8IMVTuuHvn4LevKgW2npK4SDMB8Intxa+
# DATA gzatwRA8BeATejdEA7RMfPv2MrqoIKNQzcpRbYpadnbuy3iNOOhixiLEtOzFGJMO3jYTxk2/I7YJaFvEQg5+HI2HEtWewjO4PO1Y
# DATA lbBoP+wOo5ji281tE0pXwqkjgb0jvunNZ48lG13E95fklF4yAsHrN8AWgYocEffXsBeAtuhi9Dzb+fEq6ld8AOYBd7nnrChYXEjP
# DATA GZoUrN9k2KttNrnKtbr8Os2wVvZVEq4TICjTdQ1ujJ/CKWXMqOAG4slzvEk8T4j4OTjlN9ILTihEskTcJxIA8QHsapb8wN/piPyx
# DATA tBO9GcA6yTD8ONgfTo6C7Z0V3LD11bWdlTvigOIUKcfgZIe/Hg+7J/0eYqYY7Gp0st/vdQDRNkEE4ifBxix68PEbZmaemkbydfGT
# DATA pKdRG1JdkBU1jquyTskvtcuu0bk3ak4jmbvy3xNXen1uwHEgluFrIft8gsLOJ1LFhHovn9Dz8qfSkxGsnt6J0rsFDdRdMrY7c1Xp
# DATA RiDIFBKpbERdFSwGi9yaDFuxKDjoxgVsUCaHqlFyqMUmpB6UhFEZDB8XJG1UTiadYgW+iV4cjwpTeBfKe18EqL76nGaBb8o+wQ+u
# DATA vP8Il96vSEv4/OXf481eXPvtLDieM1CFYYxOpwtchgEpTfbSx+rFxDhezggsQhJDwgmLmA+hjljh4RiFcyP4nP8vmjoUmX6NnYod
# DATA 2Qs5ipK9DCFLaUzEBH8saPhLVC58Hia67vGq9fnRGi8kPGlhzoCuCyHkSOociROnMoqOyQzTewQJG+ErCyj9rs5HZHpRYC2GEYLy
# DATA EMpW5+FnC3pjpjy15/8PdUaf4eH6mSXogQBoy7OmSOjOqXj993i5UbOKcqIhz4oBSoTskSWfUa+Tcbce64ONDwcCpJigH4s9j5NE
# DATA nMEZc3syPO51uC134lQ9lkmBrQj5mxVDcwM3s1bJQKzDuuKUuLORDAXjLEY26aUHYyaGPXLG6cZx2YXRtUeWl8lwZOJLQpWDpDh8
# DATA QRf7BNSGI9jjNYxfI+dzhKE96D2phZVJPy6HntVEuNxhXDnoAucvmI2Ej/dDtM8Ilh61j92sSfCM7X+JgRklDvon8ZETSAftxaeD
# DATA TkGWEWMYDAtGPPQwVl7ttOgYJk77EmL9+sYQkLuhxJi6VsyjFWxaXDiOJkfDbomRBBwENjNFNRWw4rNkJmrjRghPkpfC2ze/vez5
# DATA GfhZ8N+CheHC229n8di1jR2zz1XBC8RR/ltlMzCufsBN1zfWFeMIUNUuTQ7IFm6LO5WDOWWqkiqEVcIeexpSSmJoma8S64CTfnBY
# DATA CBvdQdzcG4Q3cJiGk4Ncr6iPGYkhCYLy/hTvKFe3aHzcm1DweuEp/NLq9Icn3YN+Gyzjox4Zj0MMuad1I2O+KsQJX+jdw86QXuO3
# DATA 1NKlvCpTAFA/KeGA24nomJPceDoHYqCRiMAcjVGtkoeMlkDyU6WNZMuP0KtDzCiwOP4y5i8qfwNVUqGE7VPCoc7/BYhD2T+JisRx
# DATA 8fJnJMB/ifZSPH9+xXaEr/hCJ2iwrNRnz8kgCEVCBxnMhHuTY2WAm9wixb8iSX92/jvRGBh+PtZ2rJ/igWdsBqt9ZncXCcKx2C7V
# DATA BkGulR8Ne4PCQfj0ozMwQz8CP3fy6ChZ0y+zO1QQVg9zrzKvAZ9tQ2pDCioFku3kEAR9SjibisGYZPsQYitGCKWRGHIcGtCAlRt7
# DATA 5eaN7+knFRM8sPl0qQSJI7G26eJLmsqWNo3m6UeCM6CbcMghBtTb8Ab+eyPEaAKkejkQM00ornY/1uiQ9pmrK08Ulx/nH7XH8/3e
# DATA vk4FOy8ez1tyYVohQ1aUeWIUF6Wmb8iVuoEhFOEN8dqNMBlJYQdiGXlnXG2HMTZRc0zq6PzaE8fVKrhRQ5ZyA7gYUTdWW8zb3fLU
# DATA xDmGL5B51zDDTKR3Oe0RuM2NZaoXsRGwdp2izUPCOo9Gu3MclRtEvM2GQrwEsB2ucDqvcYhWcB30HPg93BM/QWb3e4vZcZ9ILKDO
# DATA JiO0tUYbS2RqtGfYTIoHohH3N3hFfRGsrD6oK3VvjLZjcZiNoo64IEIie9SZPIk6O5jU5G9PhuAmGIDOpIsug50J6Wbio6jfl7+T
# DATA /kQIgu0RnWI4EB1luLcHNLQn/kIj9vAaPbxmPnsLnr31FvfQoA9KTsQd5n/D4rykhRuhDMOzE2SGjYeD3kTIGmtGQMF2ZBvSdu/v
# DATA mHfkvcHKgZBlahwzVR6CiBixo1rAAcfc2t7ggzacFt6yyJusznBki+jPLvjjCyEpPhqKcg8ftOOPagtCutsbqNmvXROMjub0Rnht
# DATA D5REfFDdXl6+wATh5sk1PXJijEkR+0pMWrsPY2rsQk3irc3BalvI4d32uHa9LP4vWLhZWrxVXVioAp+yhr4tCEucmz+OumtRv326
# DATA E3VqN29DqS1QysdwGahNxBmL9a+TZbNJsxt1757WsPOxmlhnLjwRJhcKLskVVyLRGCggZIQqPVPOUFABGMYACCGk3pscqWjHsZRk
# DATA DZfPhhERYWqlxVfWG1ouoXSqYzwIZfqyoi1iBttTwVfwEQdt5joYJYMpbihrXPJHKdNy+GFNZtZNlrQ4/8kYJ8V9C5RWI3+EhuPV
# DATA qSbc8AZ2tV3tirQutyuWvqtdQY1X246Fhj6ZrqQJr9/RqeV7LFV105sxPb5na9MgIaNp4wbarkhhUNTMt9B2xRSh/RU7AZ4kaJoj
# DATA YVHTrP/CwyDyrlqJWWHe1KEtPtJJ6PO3ZThGA9qYPIUrBEyYvCumkAzvO1sSfTP4fhSN0FIpEYACeRTjjRtyOg86/RNAuw7AM2N/
# DATA OAnjoA/x/HwhiSvJLNmNcNKXsZi8LavGZFq7mWImeVCmMbyihYIib3mrLOxLs4ydLpEOAp4mC8bRr2wiQddIwjvpx5583iy/gJ8S
# DATA QZ4ZI0HZxfoV+uxDSfLKLGRe+Prlz+j6+PKfyTEDL5honIcLpjiZnRQw5M0tmmxYnWkW75g/QU+aObyxpzhJ+72U4ehOOCxbipEL
# DATA OTGD9f1HBPmBCTxZRUYimXj5UQ+uKwY/0CnnJIZHFPSHhxXH8z08/zfDsUXMaFVcoAz3QAS107knIzcxOut2Q9Mlhv3+0MVmfWO9
# DATA pB0qxP+zuR0CX2EgNSOVVrrv4uKft6dfivvbwePW4Ul73H2FXoDZ/n+LS7duL9n+f4sLNxcXXvv/fUP+f7sR2Lbb414fIBNiMLRA
# DATA 3khG8nn47gdCisVsqnwclUj/3htQ0lGwRIwpwfBplgvgQWcw6c/g7xcfnUx66gUKO5nNA5C/A/qPVHChww4FSk3xmyO3P793nDj8
# DATA HUe55VvZXhfR4FHt6fXrw7jCAYLifL2/2lq5j57nq4bCd6qf3TZ5NBrnGPiI/Yasmi8/htu2DiR4IW1uGNUg/vtP8FC8Ipb1TuDh
# DATA pwdC6HoMSE/nn4KPDLrl//TlL8OpPnxizlrGcSjzQUgQv6MemimNSd5C242FT2Vj5bL1Gt6sPG4LBi0n+9byQh5ISnpzAsrqAfSo
# DATA mA7J72lkcSEBVG90fpdK1Z+MbLw3XdlHvX7fhWLUrWSZ02xDGt0ytYJJ2nFStdNJ+sjWT4MpFq2vn6AOHcjhSxVnI8hEW7gvYckT
# DATA x4zXkgdGNTJ/m/XjiPNZ+/68jH3jaH84nLQkOy2IaSuxiqwzEdcjscmERDOE9O81VrkkVL9lmGtZA0hAJ4PepJaqoEm8iAirWpWl
# DATA KY/avRLa+8Lyw8hJgdx+LveK4/b4I9Ss00sEnkKYEyFrHncRb05MdxkdvH403BcbXAwa0O1Gw8fipf4wjmH6+r2PIqmoFHexybg9
# DATA iHtw7OHF0tU8ilm8vNqROQEsXSlNRYYLhZvQOb1FN8SsSR0i9EepCq2c7ZDpodujrJyTozr6UdRkggyawSKlNdobpOoN7RpNzSHA
# DATA svGsiEquBZwzVZyF7f1+ZGgZt4bxpDZ/Eo/n93uD+fFxUD4IEt2wmklT0SGwUvkELkCGms7QVqJHvLGhQkqhLcgervpSJZYoRV0O
# DATA aS9VMM+1tU7US0i8gEKTbFX68/BRRrGyVSbOKawAhfKoKw/IUkCxv6JrHIYQiekT93D+9vio1zmqkcxUwS8lKZWZiaPE64TNh9mH
# DATA SBrioxRrEz/KTwBjaJ/phLR78FgUwhYKofhimxnEg8QJzhXaRz07NNdorpHPScCZZtIfD3+ooCtfDMcBpfI4iSGvNE25ZaHIaJf7
# DATA mVGjpz4fb/sPn0jFjk9fc1Dvb9hHSvC0O1J6NqLa/kAhtedf8RxKW4iaXn5QFnNkFRFE6RYSj+yVkJWxhkSVmjIsDhR0uLZ0lP4U
# DATA h0WipXoIjptufC7NhXL8SA6k24vb4+MW8F/woGBSRaKzz8Ci7xBk0GexGQPUtHmOPi/6J7P+FcFjZP0ylRjIFqBzAxWGFIIrwUoA
# DATA cpzgYBJndAy4pejHC6qKftBjB3yDZXRd0NjOsN9nnKJyGU9j7Bvx9nJZsB+iuRoiK2pGJ37DEwYSc4wE9ZzWVjqdk3G7g7aLRdCW
# DATA 0cbR2aglp2oWvckn5E4zXoCFMN6Ytn8Sso2h0cTOinvfsZivx0fRgOHaOXis3esbmkt/Z+zemybVDC6RcxenkbzetugWzl7IPxGb
# DATA 9wVEkX5q0/b5Z3cC8k9Cn+bPpQU2VYRBfsA/yIdfQxVgJgWnaPSAtOBc1c4oFO35Mo8khuDCPQBAb8qm88qhznICennfZVoK4Q4h
# DATA Ltg11aPtOgBFr9W3c2FocTU0pLjCXxuL1aaCdJLPqotNULsCTn3YJD2i+bvJMmWtzDIpWIyrWWg6ZvNpoq92ent+/it0cAcqSlrG
# DATA v1Ba/mLCjS+cF8vuCOjgQ1DpDzsfJe5l4AiPSCADvkGKb5ut1e36ym7wjL5sr32wLT9vbL67ef/+5geWpEL490JsHJ+MAFFGwnwc
# DATA jOH24ji2Itq8gyGyvrFrQohkQ4okYUUkkL5+o7V+b8NV2n4/Ot0fCvFoXfa0UMxGNpmpV36gE2NW2PA9/VoKy2TMGSjAxG1TPCzA
# DATA f0r8BPBJWvUfZGimE7KgxvW6vIUhMZkZmCuhEmJQwBH/w3DWO+n872sEFXj5M4y4IV7p10aFttnD3E6G4WM2e0YGZozf5GC2qowO
# DATA pu0Cg3n/EdVqP0/VoXkGKCWK8I/NxkCpXsrtQ3BFfEUmgEz9/+LCrdvLN139/9sLr+P/v5G/N99QF2/IQD06nRwNBzfnrl27dp9T
# DATA d0MuHaIS6aRWgX3Cqb4pjTfmCEBUNcgMMB6eHB6hRKik5tyGgaN2DAYB9fW43SFLAeCnoB4Djhz6EfS+AHCyDTHB8eQ9wRr7VwEv
# DATA IERI9RlcrSbUbLrxAXiGZW3Axk7GfdFWZUy9k21yZ0vwMxwcc6oDxHuMVrTDA0L8en9h1PA5yk6NBnW217fQ1V9IckaWgbnV++tw
# DATA Y8I1x9zspHKREkY4t7q5sSsEsfo2QFbtbm/ex+K2GALK1PGwH87t1LffX1+t23cwxnpDilFqxLmHG+u7re3NzV0t2/icxea2Hm5D
# DATA EgxI5ZlSZ/nRomh5d+VefQdDpFCLwflRusPHA1TkYKQUpWlkNFfKGxFycsxTfgGcOXoDsZSM/do7kL90BDkPxAvFuQcrP2jd37zX
# DATA uvvhLjZphM0rtS0lYRoPD8Vcx5xfZixXWhAUQBEiHnwpiB7p8BixK7YgfDI+CvbBxCb2kZiHEZWJS5wfQ8qlUoyO8ZrcfhwwGcpI
# DATA cNhjdH8jiquBUrPVg5yJ+ICVUXTltlNUWJlI0cMFto8CnuYVn2e1iZGQj7Uz7MIh2pNZrGUnpP5BF0pT2Bj1HUYyEJoXGrLYw5zo
# DATA tDichYpWneDY4YoZdZOam4dIN8n8OPe26zs7ttjtDJiyjMh1RZWCHJeTtXIwBLUYRoDCfwqe+7esxpphbTVgyQcAxDeGk3eBHJxo
# DATA MqOCpyHOEvrnUG4K/BfVqVF3BaCyRY/gRo2UBIDkiDXOUC6xgcgu9smj3hB1cbKBBtfeVOgF8JJgFmJLRZjIBXiQINRYakMAf4+8
# DATA mgTBgvlQ+0LBxnss5MtYIRXQmlbAgPykgC1BBK31VHaqmBx9wxhFsyELguvTcftJYaGES1F2x6JnpllMVFkhzkJ9qfGM2q/VRK2c
# DATA Ch62Ma4hOKVBiMLek4WF8t6TxYO9J28fiA/fOWhy0jEsWxR30KWF5pw9CF4Y6HfB8/RG0HgatvU6Yk2ARk9MhAqK7/jvWbPYKC8t
# DATA V902OI8fDFo0Iyqa8+W+w6yA/I7Pp5Vqcbkb+XdVHYaT5AW2YzyWS2hq/clSvftl+gZ1eJ6xUe0bhrpTmB5W0puqmN5H/05HshXP
# DATA HSp29pPSXoz6EUdb6QkbHSHaOHt/cpGQJxhOeUpxrTpis94kV01YuQG0H3zDM1k8H7JiaKK52M29ijoCuf3gkOYqrU3p+u8B5Ckx
# DATA dcG59dt4W5ePad4aOG/VpjfRoZ4CdEcp8HaPT44LqtIGVtjMrFswh8JUHlFMJutE5wzViVqwUPW6fLhrxbm0+mhSBMuL8pnr9uJR
# DATA v30atDGirg0pDoJrCwGDDVyruP4H2SRreAUmksEKUdUgZX14JAhUHiTrMFeQ+QjJ+kawKH9YFVMPfKcfDQo0r75EGEi6OxNMTGGV
# DATA 5dRvTP54wcYm3MRI0bhD/G1xYcHzDhEAde46lpk3W3G7FBvHorFl9GPKYiGZZdXPQp1Ko357FEOmEFwt8ZJFlQWjnQNBDvERNUTy
# DATA 0GMgQm9P8PgqJkYAEeHH0JFtSV1Gu/KRedwnj5Qzwc47fUEKljxkOFlKZbEgFmL8EuGjPzxkps+eDnzmQtZRSPbjyWkpuQpmjkhm
# DATA VcwbXbk+QMd7heAlqtO15EhnNlsCM5YBzawtKvz+oOtXr36wvblx/0OpU7WUrfUfrN7PVLYmEAqUKAZ8MplnsuoyVlUegnKh83BL
# DATA sKLP3KXSi1chuCIZdqkeWyk6ye9X/0LB4x7AAVnGSkGbhoogZqTThyTAB13XD8rgUlq1etDluP4kXbaQugt0AeK7FcR5THQQKF+O
# DATA SNophA2QESgz3WR8gCd4+NaH5beOy291d996r/rWg+pbO38Tkmtf5fCYzngUI5rolUD3EEg6Bd+oKfKSCFVEbXgyOSh/G6JRYeRx
# DATA LWQ3DymDcJ+k51FyWIzGxJQWGfvTJppcVLmytVXfWHNJMdXBSk03aFSpp1XXAT5l/kNGcibbkITnVsppSEelPDvox2LemsUNHMIk
# DATA AXEPrkzZFGYwMcrcJtGtEqxMbovUKcbJSeWEzAC/2ZniDQI/WXyW+VX21JjiLM2QVJoYo0N3N23xuSLObt3DQaPycGPlfTENK3fv
# DATA 18NUFiz7klyaaaav7TVzF0i61983EBo+n6PhWMKKYNCTvcrHggcwBBL6DQJmBpXz+A06TiiVndb6znb9XkFWIrE2UqNYcsyivgGc
# DATA DDptumiY9TPUh6XYso1y1Ps4ij6SAk3i/bL9vjNEUE/VZD1w2yjYpT00mmrAyR4xBQPjiwrDQY7brAn6I/4LxuQJOr0V9pFnN5bo
# DATA wqJKNKpQbCykti4XAQGYCoHrN9fD4GHprD6jN9GgyzcZmGTI11oYh2X4A0YNiAZB8zpjuwffr3+IP4Xkea7neT867A0GKRXdrd9b
# DATA 38hdFaAXUJ/gyEdAD107KN/wR/K0EHLBd/Wv8plDrzxRYWO7vrayultfC4w+NPEMFiUaXC9gOxVZfSGuP4JHxRrTytrz/KsEhEre
# DATA Yy2DFt1eG5QORF6/Z1UAqOuTmb24FjyVLVLuy5LijJzZVH71ZKxjMYeS+Rk8VT6Sl37QKkNTmIJQ/lg57A/3C+F1qdRoVG8vg74I
# DATA C6lS3pZjIaEk3r65pKHDqEkQP7nxDG0CgrjYqgR8J8HqDDMrvkNXHkOMx2Pdw++M+QY3EjJrYBUN4/VmsXjlF+UDKze9IY33oqwp
# DATA 8R5IvpTDFzqeLnNEpZ06qedVxjHE+ByT3uAkmvMEuhhJoNP5f072ad6OCC0VabMCzBnuRYLb/XAvvl54pxo9AePYXnyj+E6BIWFa
# DATA TQM9pnm9KArWoHDlevEv7LzPYKypPChW/TofzVmJ+zwDOnksSP0Z8pVnLOU904GRzwBj6Z2PotNncGSCkgxilp/F7f7kWTdG6AAY
# DATA TGOxiS2vp8yy3GJUeKlpeLxhkuu9a3thWPS+KjoOChGsoRj8ZS1YrqYGKDk8ld5x91RCkExsGKoGUUSGoM0oPKX+I/oTfoKfmLt7
# DATA +AKxATyAnK6fIWZkrQ/57RnphW70xl6k8wb+UT711FbJOISaMgaFj3Gpwi+80zsuFtonkyOxxX+MqkRBKI1qrUnEtS8IIBo/EwvZ
# DATA 6xSBxvZ2AJNmHO4tGnWbh6rbQshtiMoa1wTPemdv3yJO8Xynvrpd3322tbKz88Hm9tozzJryjI/N1jvi3HwmCqzVN3bXV+4/W9la
# DATA p2crD3ff29xe/5sVyC5UdCvlxtRgio0f7o33Bs0bYTjbAKYLFY29eG+nef0d0eo0UebZXxTDUqpwkNWNvf3o9K+MQZoQUGnf90Ob
# DATA BrLqLwAsj3i9yf+KOm5Uys3r1fl5mLp4/nvV5o0qfWre+F5iDr+X3fsni/t7jcZC+Z3m9UZQnhf//V75v0trUeI9CenVOWqP2x0I
# DATA sEZgHvVN7CcsCQpS8yHER0xCkNsEk9Jv42a6uRSQj6P1wxu1YHHp7SyRVQl0a3xdDDj1ZUxR3+14QkjulWD3KFIKW0t1R5pK8Bwh
# DATA rHZ0q6gADB/Lg7aWWt78xFVYfqQEuBPSDcMbADkiOwuP5Oczvtz2AbF30lKOKC32UyloC/w2GcGD45MJeB8H9/EVxKAvQT8Hgh1N
# DATA sMPgPUFOAuJre0LA88GkfWiY3kfDuMdXZR3tSSLPdv3BxsoqZG7arm9t7qzvbm5/SOl1J5Pj9mBeod6UVXdd+1kqNpqg83nnO9Cm
# DATA 6k4+o/h2/X59Zaeuoj2lWY+dVgpa8RTKfEbipKscCqnkZB9cauexxfmnuuGzeekZNE9r8Y5y62ih60btqeulf2Y4wRNOWVx7Gq50
# DATA 4BwCtQg4cEBACuCjPhp0ufkbKNGWIAG6qLe8ygbCKgjk5Q48Cz0xuuFDQYXllUNOL62XwLxHhGf0puH4yd47BeXkYaTMACFsHMWj
# DATA 4SCOEjdQfk4y0dKt2+xJAldMtdZw/IniYBXXJS60gDjzNpoJVGwSlXEMqxS1gHp5EYoRWwHHiNUwqkf7EJVampILTquiBB/97Cvi
# DATA kPmjva7g6fI/wCfbh0605thusztuH4CtpRdjfZihMlFoJE50meHZKnmRgXNeBxgLeKFbYV/8jBmSLEniTTVlJUyByD8r1qSIIxf/
# DATA Lb4jpsesecog3q9v7wipQSnfxnjvnpwI1l04bo8AUZXrk6DnkBBLoyQNTgvwEtDp4vLby9++eXv5bbJkwFNxEmGVF+kLzx116UZQ
# DATA WCgVxT4oLAdl3B1Urw6btdxpqpkWG/+1y+vTjZrwcQqgMGv8OEAYtzNg596ydjHiSktU3VzTsLML+fyYqlj+N3avhcjvJ5r8m9ds
# DATA iycc6+BpZU+KmSgVlNLIzx8+XF/jV1G8wI85d9ZfP6zv7Kb3KxaPRqYbSktGzB+LU0d+41yxCgq4OsX7jR0gPE5gcwbutvhum8jE
# DATA mLN0T/kV4g83dlberbe2VnbfC60e5bNrysIJq2bSq0/PmaIkPVkGNCs9Q+2xi4aly6cDYhlEoqoqoZrKtWQaDanPjYWmo/SjYFE0
# DATA y5lZttUbReLrK1tbLbpKoVjtw/gCT+daQCNh+CxTn6QUNdbYjBAK0EPYKtcf6lZrcIU4AITPp7eXz6SmgTUMySFJRQDC5FIeIANA
# DATA ltkIlQa9682lTCJ6sL6zs75xT04An8qgpQDM1+N2pzKIHnN1Cv63FLDXbUm6X1fio7aQPFAa6/YOQfQrenzH0um+JMR3UrpWqfkz
# DATA B8VbVgQ0VTA3bjGRx4BXyJD6YhNBkF2MFTJ4QwIOgnsghmrrlQPnFUQdY0d2wUkYE7AQPhr2T44jcARuWC6Cyjuyga+TKgo/QfIm
# DATA qrF34FWuFIwtgCWZOVMeJ3ggZSQETUTXr4QDNrCYvLUrBUrSjVt2Vh7k1bAopJKlZrFpaHrUNhSrdzqCi1e43xuYEI8ECMfMpqgB
# DATA H6vJJtm9ugVxAuJ3YFVncz7vBdPLAI6KhuxI0xe9adE7N9V6sPlwYxcafvf++uquJxkaV+8Y7nD1pN5LtuqjdPtokYjARgNySlDv
# DATA bnpJq/wUaXnIU16EHcQ+fVWSS8GnHV0Exar0ughHwE6WVTTnzpr3iZeO827LSoIQNbH89SwJ+AqAu1G3xQepkUte2qOLqagWHLBd
# DATA mIL5CkoCccUHwoaUv0GB+AvqDaRbp0S3cLFwHUCKJOBt3APFhIlxqwJgOPglKN9F07sxNIqu8I0LHUEoIhZfMmcHfkIdR6JTAN4B
# DATA TQ8HZfZM2BvwM4SlteF482Nd+EhXR17MBxywUeLgc3dpE6kjNbZAEiqjRPgRhgiS/brC0AjL5cHwsfjAvZm5pjHNVGoN8lKAAClC
# DATA ggWd/OSUBUZDcjE0QACAC5hnfeBYpyrvqeCFeKjdkXQHMZ3tbjAB7Bg6VqO2OLJxupUOKFXEVIkH0g/OjDQElqgpZdNLCZgSW5Pa
# DATA 8jAqHZehpUcT7DVTMJPPeMbFORCZcmOWuMYdu7kUfLdmC0C1YHnhO7cVZvmRtimwbpRwjPfGCLGD+iBwzw+bxT8iuUmmbEjKSMpH
# DATA EzVSVRWT3Wr1xI5ttUQX+gdkWzYjlsXDSjrZqSL6iqPfMO85qjkUubCtpCO8cY8w63TPPaOy9qOI+51QTVjTklUfv+vEJ+iQddKX
# DATA dpN9RoN2ze21a3HntOyOt3tPhnYx9CwIAeClTRFObPgPlN2cSgnWKnvjh5+wCG9jc7e1viEu4vfBG0w3LdVEVHMj5O8emI5ECT0t
# DATA 4NDFBCPVlOAGYN6Hp8eLKdw5cKb3ZZySF0ycWKKchA9AZozYFXg6SftAIJdF6m/dkC0xJWEGKHFSvzHiYKAURVyoLntLy5B+BIrn
# DATA c93yqzvcSU3dbYUQmsLx4dK4YS7+yeepeNUL4HQsexWYji03RLVJDV9ETdfoy5Lc6hrI04mcrfQxcYRRbdHyu4aEOORYAFU4jkyu
# DATA kwf8AVhcvrWBqhtCXMeQLv8K8SqJOu04IAxzFHN2EuEFTAY80gXPiD8KyvpdM5BgARSPby8tpMSpwDsc94Yt1mT8JPti1ASF7ta3
# DATA tx9u7VqcSXUZRyZqIdhxIUFVVT8AKdxMLGASnhiKmdSAh6vuHWgPOwTVTOgAjE8PkPR3TQVMWcbFEQen0JqfGcdVMryamWjnqD1I
# DATA ck/UGSMBILIHmRBAYdzuECaOl8PIH1FnajDOtGCuLLluaw0cBO4+3Pkw4f956gukIu/h5DArgHh5JMS33o8jcwfSuIu+xfDVsob/
# DATA pLl0pg/EcHUmn07yUTY3fYucDWk5iDMrWlKH3Kwnmw5VVcHF8n4hUZaMK4eQ2Q/H7W6U42xP5/DIcLycSgwNlRDm/NNAhUQxfNzq
# DATA 9mLELbOglhIDgRBC2U9kF9AgkdZxeyCq65LNC4l16ji2Vu7VWw/W722jiwkOZ33b4gmpewC+puwA+umV0j97k+c+OadvHkMd6Ivh
# DATA TonPSZ69tYyz1/uyZpl4cKuv6V5dM4scDoOQ7U8f2AUOLLsC59T6bsapNdP65z8xlCObK3/RQQEBdRRmr9eharIeY3GrWtjW+jo9
# DATA K2YsojEnrt7N3pOeiG0nv0YqxaaoUgiLMROpkHVqZYR5AzBAA8DQhOY4tKRsvxZSvKdADLVqiypUPzD60oP2E1CCAQ1AAVc9hy/d
# DATA BeUPKuVS22OQOjhVtNhXYukUMmVFY24fHvS6oWS04hGIDuo8sbRLlqOHj9gKF8SqsghvimAmrovbuy0VQcTyUi0Z6jTnd/dUJ0tO
# DATA Ud1TcByW+eZTbj69eftsjwv6orpmIOGULW4N2Ak0kcFQAFBrCwuwyJascEEB4cpvhDOx5gsfYs6hXKxOuWAmj7E8d0cy+idADEA/
# DATA wkwvTQS1HoN7oKOWkjFthZxUWnQrbHXGEUc/oUQynVlSdB4ioeiAP2O/QG4bdkPMtyGS1G33C1iKnwU01DWoyahO4nvRI5CkRhji
# DATA ppF7t2ZOnz65FNy3sYSGqFH0X/uuWHRVs6/lVzkHui9NnxxyJRLvpSTfK79HXEp88x0eSgy7DE8mxyhPhKtKG0+ArY3V++t6bMn0
# DATA q3TiSlUl4tqAT2jYzFhN9Ifgimkt0+rFPWkqF9Tnpv8kdGSj65T0xS8TnIJDAUxQtzeoGW+u1d/feHj/Pv4CcoHcf5RvSn31iRBv
# DATA Ly4s+GXwjG29uvlg6359F09+e2vnowcNLSPlCZ0pfcY4qotJOL0Dkwn6yYkD5AkmYPoUyXB58VmKIBcSrHC/b27Veb97BQ7mTAao
# DATA R9ODB5Rjj1nWlpOEPjNTre7H/vFctFJARlA3eHvBTVyD+QBapN3kcZK63t4/SeD1hM6dxSm7Entq2pjUsDbF2NuLGR3dvqxAF5p6
# DATA J90qGhmTEJzHq3SDFpMEB/g8XSEGBXQr0AA9/agteghwZvvj4eMYkhOz1gKgZ4ACJlH/tOLnlmnqkNQLf/qPuaws6YKbRR4eS4yY
# DATA LmPpq5luJNYuYth69k7JoUUGbb7cNjWDUIvZbeKQ0Ypon07JPE4n4zFHHsI72iw4Y4hoMa1ary75+nXOeRm2H4nBo5tDVb3EruXs
# DATA XKO6pN1uuGDyIqtwzUQhF4TNkLFoUs5Ms19H3nsg2ZQbKkcG5vsJaiM7MyZybLUKvcEg8gXl4nOME2W4A3KVlo7Wrg2XcUARsLyU
# DATA BCG3AHNckByY0BseucUrursI27qfDs62aK2AmFIwNyRcGL9v3C1masW8ArvMQwYNC1FrfTNFy2TPX+bpZk2zRXWeTiVvN7yWT9Bn
# DATA AOsqBddb/gBX3dTMPeb27+P90jrQlJZe+jok7970Swtd+UvGTVzHUqCjSSn1an5xrXOK2mUae/Ubsqfpci0NxaX0mRe0tGd1MLVz
# DATA 09AFLzQA5dhEqw7uPHK1XYadrylwn9iof1Dfdhp6M9gcRApTFwWNHw3FQNt94MfxycFBr9NDxy6I65MxihCiBVoHmJW2uMAd9WIE
# DATA tUmEoptAXSbHY3QFhUcpYRaq+XkYE7sF09UAFygD5bJYLeMTrr2ZGgJ+eWSvbISvnHeGlHozlO7K85UuTD5FunR91dp215+VWY9/
# DATA TBdSxKdKIt+M+j1N1Z1QyfsdYEqpavipOvtvRjVvauX/WFTwuWTcq1TIT3FegoBzq9BMavhMAr4q5buhd7+Ixt3VW6ed6Jf2O8uF
# DATA TZ6hs+4NDoY+zTyHlWbBhetIJEIAyl1HfDSjnht+N00IPu36FJIrXoniHHvB2vPpJHzFivOW30ZvqDWJyg6rOdVxqGnSKnaesqhL
# DATA zJfV6tgb+1RCNzAg/Zox0/7zm6LU3KzRBojA5uYux+NYXFSXYEHsrzbvWuekiUOAQcyt9Y13N1vvig3O9QFlF1PjSTwV1Dd2tz80
# DATA a0DCdhy4nGWiMx0WSedwmJvp/m/vTzsHg0F8euRmrojzf9eJeyi3z6cvf455uT6Gr5YHQ8q9SKYErGXATORSPJNyWwgA0L+yDEt3
# DATA dOWq8iZGFNYgqjBPyM9UjTXSMqur8bPvrP1OmqpagwxoUyLST0pp9EzvapiABvECtUH8SEjKHZpe91cO5jlStB5ce18mptHL9FR9
# DATA PKtyYpunssIzFeIhXuHf/Bv4bG9wTYUApPfDl1XaOJgSAwq+q69C3naLM7n6yI0JF6Tt+srah+EsXZnpWnaB65nlYM9UoBZHs8o3
# DATA anr1LujoZII0eFpHNpWIsgGhQP0y7WZ04ebfDO6SVhnaoxS7iIt/3D6F6xZmXGoHgwhw40eUJUbnWarMTdXOKnrmCa356UqqaGQp
# DATA SQZK2MXq0tngK+LO/6KZsZVjDbLKVSFXJ+SZ++z8y5e/COgklb2mdDD5+K6+wey3hWRVMo4uw4opAR793Ng0Dn5TbDmVnt3tClvI
# DATA v+wzETRjc7QerO88WNldfS+8zCpzYiVY5H87/1UyW+rvMFMqpNP7B0ohGE5Z1KnXtTwmz2minmN2zRby/FWn6nyoXU+2k6TTT3Yq
# DATA ouLU6t3sOU7+ByONjuuwOT2dTrZ/gd8yYCcagZA4M0eRt9dnKeLyBQw7mdqoV2oEfxNR0vjqQRgyEEQYoIa9G+yfUozpaNgbTCrB
# DATA lpgECCQOtlDRMj+IJnDJ9tTKygaITh2W8H4j2gg6wxHkNVOKzm6vfTgYxpNeB1SYkyGdLx2ZFv1CJvsUe3zLhLDPrwY1tsNU09eF
# DATA eVGC/Mm3mVsmHA59KOUKr0/haV+lMjaZtGzuKuk5QcuouKZFwQD8nQ93dusPWlsrq9+HjCnSs0lcBLce7oZZI/XmTTX2wCqePFv2
# DATA Nhh0iQAcI/3bt7JawvmflrHVOKZkwla+9XoVVhdS7/HEuQFvTiL0i/mH5JKg4DolFe/HvVhMwqEN/pNQKaWWVjlgBr0nO4i/WDBz
# DATA XFZ2jygl4uGD3pP1QclKgFnBl5BX0asyPQACA7Qm+GpsKmdAGwjWHt5xrouLOA0GFA1eCtrdLu/3+GQkeoWRIOrFoucdQG/h22nh
# DATA VsIm6albwUeJvhcw5p77QlPC+UML/rSiRTPvALHDY1GnqIZVnQnzqrUJCZFg1D+VsWRiC5QQQ8x5a3/YPbVxNbCQunF67BHRoNuS
# DATA uIIFKJVWiMAUC+EqQWiWARBDZsSUgIoeJaWnAgtisYQQi4i2EOZt+n40OJxIiRuMWTBu198UX9dvx77RP0bDNIkYWIc15Ue4eGn0
# DATA ZwbGZxOVCQegxTPCbciDPO8zRSOsAIim7XHUYrQA7A2PlvERTFBigkgQ/7mLgMR488EWiumWXTz3kPKWF26CgCXNW+G7m9t319fW
# DATA 6hvhWQ4Vr7xdyGyk4KN5r75L3rb4C6mZIV8syRFhtj1cd2wJMM1o3tgXzh8im6N9SkcQg+BTCOdByU2h/fOpfrZZvVFabKiarLBO
# DATA nc2r7elhlNpRic6Y0h96synhneazccEJPxFuh0uvLoIsfU6xeUQ/p08LF59GIjiO5p29NxRKfsnWLXdkioK9EO17Io9z9mxrc+ey
# DATA XesjR1YUZjChFiRwTHLuRjOTxLg+wpZWYZ4Wb9sdtwfxQTQu1+Fwo1hBVr/x24IyKr1YMMfeRKvmFoLvwq2loMugytIGyb0yYmac
# DATA TwMBkVYPzx2E/XT6Usx0xzBEWKhZIsLh/EwYL/QNcIFAvBOMi2dcsu3oUQ/VC2ff9Jb1ESb29JLEiZtvvt2heMo/T6pcunX7z4go
# DATA YcU8GA46NOxV0Kbm1Bz/Dx1qyL40SYy2YoXkI92vZn6yX7rQ2ZBK5CQWvibvPwXyttW43xBhmzSdsM1cBR2ny9TW5WDZuhyA6e7d
# DATA zYcba+7l4JWqRa0OfYc8eJQCCLaT6VtK+p5lcU5lqZH0mC6gS3LX0ZiL7rAl5EGAh7PumObvwBP8BUitIh1zaJmSXvNQSiECGq8o
# DATA qD4kYeO5HwvQedln7XR/x6+F6WHLjCm4s7n6/bpJ5WZ9lscoetyYyqeJVECRi05JqmEIcx0LVb3VSqDr26ZjAiuq8J/WwRCTBWGC
# DATA 1R74w3NyTaCjVgukmFYrlFmPxzE6coj9h58rK+PDE4Ax3MJfVKYtsJC2hAzUabWKxpuQn6zV5lcK2sURnTe3UAPOQMP4TdzPhqPJ
# DATA vHLZlJYbb2XmSds5GgKycY1AjlE81E6TDrIBwqTLoFMxFWWJhIllZWhJM3MYMg4ysxApz4t30n7vt/ejfsbvaGbLbgK8QdMrQLVp
# DATA xu+M3ptRgnEpuRMczMpl8R8oLfVPEKqKh2l00mMb64KLLrmDbr71J3AX3z6hfDfkVkJ7W8FWQ64QoBWdVEE0VLFDYXUc0FyaeQPf
# DATA IvMGfhQTxp9wdfgzrgR/xlmX6Oj+domCTJxJAN53m+LgJ/zMM83feFazG0lQpwXpZkO4uk3naoB3hK4WsTV1XcUKOqzKacuuzNxj
# DATA GTVq/Al8iF97Xb02PlR60ku7VRXnvvX67/Xf67/Xf6//Xv+9/nv99/rv9d/rv9d/r/9e/73+e/13mb//BIDKMxoAKA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
