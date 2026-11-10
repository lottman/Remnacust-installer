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
HELPER_BUNDLE_SHA256='1b5be38c0fe8846610dbd49d7100f7fd4bc46862347172761333e302c910f26d'
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
# DATA wlqzBqrihnfnfe8P/z7I/jcK+L/B/d9d0M7y9j+oIn+w//9t6/9+hrUigqmvDl3MJeFNyv9i6aBkMlmSxlH109GIaqQxPflhivcI
# DATA 3lf3l6/nVN/i+Xyaqi+XP0tm6jNedDNOhuprkv7uxYGvlotkrOsDB3P0U+iv8WRmf+eSwZifcLK3f4a3XhQ5zEres+Pjs4MTTM4o
# DATA fTP9vn9y8OJob//V6dngi4PnLw9OTgdfNr6BZgdHT6nN9334NFjXau9o/4vjE7rRnFy1eEJsPtwofzqp/Dm3HHz26ujp84PB6Rd7
# DATA wGZ3S/YtIKUfbFS8Z4fPD04xHaWU3+AlzvMUVRW/2W6JvNO86DdHTbAvLy4Ziw3f0YYs3R45Vp9yskS3tGxv5cK3LS9noJyeuwLh
# DATA zBp5vQ648lSrY4SWAkcJ/u5YxzQhS0LznZYrRomekBhwznfLlMLfxU+GH7XHqlTxXuz9ZHCy9xWWlu+6RTToES44PGvmHuVOlkVl
# DATA XGxV1xArc0dxCHCUnYoYEhmi5+qKkyFfblIlAtdl6uS2EqtTeVe2bU2O+FIDzKhWl+XK+yK9B69jddvyjre2KF2Jak2p/5Q/3dm0
# DATA Tj/g9/Pa5oX9U+XjyqclFSO994yD3F8gzEug0sWZMF9/gDckxOo6D0nUxLDPgq6OLJc21SEayr0YJXxEbLGcwebFGuMYWsEIr5Re
# DATA xHpESQbowHqOXDmm3OA6RRXvvuoD6uymgUaV7qyVdNfOOjIMeCdNwkfH5vYreOsv4nqYpuOy6RR+tWaiS2UDqdCmE3SyRNi1CYwf
# DATA q1XkHRpiSlOZeWTF/5HfuG8xnuqb+WQ5Rmm6iOfmjJLwWiw6MnXCbPS1Ku19OU8uU5XB82UPuW0tnkacvQNs+cEc40NzO1MRhGqh
# DATA SBwmU3l4vrOJp3qw/wsGCZ8XlVBGsMr40M4qQpHxdO9szy9JBUV7Y+DD/b39Lw58Ww7QBlHfW8072gvYb6XymJP1r6bxmxnfG+LM
# DATA 0perisx64LxYZOlKOUwElFl471q/kAsZjY4hYwXTEBQIlx/xcs7x8vBZmdmQ/wnzI6FPBbFDo/J2DkKLlCvndVmS8nCjtFE5b1xo
# DATA tkjFoTS70wkt9wwAAgW6KRbTGwRvvQTcudvGzzBc1d5Vpk5yoKqnTII3yWQ52VVM3nDIBwtu5o+Wr+L/C8Y2nXbAimGYk7IcB3Oq
# DATA 6WDO+FuHzpEaeYB0ButeAuKr+EGGzeJgYsaiK/B25Wc6hVCWmUCfDYd2SDgAV5Dnj4CXap0t0tQfY6aNSyV5WaevW+A6GeV5YF2y
# DATA gMPjDzB6q9nrbj8GV9LRyvgyY+ucG/asjzvHIiZxT7wtsRVLd2iLsKliFX8ThivpWh13dF0pvHqu3rp4cF+9mmbL2YyyUdWOUnCX
# DATA Kv/6EpahUzO5+PaythgqR7tVoznI+qAhWWjRheNutRfumLHulOyxSk/RU1V5SvYbri0p3PpUIZdEUUc75RvS2P1g5uUKW1Gliuem
# DATA yikVgE/lrKSNFSMRV8+cEN28gDWGn2a3fwkafuUvRen8S9Y4vwGVsyJHRx8hDh3sIlBUM2dF1lpY5GIVGomIMlJbZHPoHUDOJd4B
# DATA D9MF9mCqx3wo3Cpn1oUbk5PK3DHDgjnZmZw7XCi46v4PfacR0oFi2B8IBxbKM7shW07c4R0dkAlA1e1AChMr4RF8jGlrHRfFrWDJ
# DATA Iq4ULwllwNaqUpZMyiY6cvAtrv4OizA6Pa+rM/FpHV3kjM6WywGet8Vmj1w2JmmPq1V67DNADofX2/hOWRpyX11ZlESahF25SNi3
# DATA 04uu+MtWC0kKrFPkqhnEn7lFXkGg5kX86n4+4DpcEE8OQ/CjlIuo4T4oOSJGWM1Hu1rgaEzcf555Vdvji8XXsB6n51UWpC+/tMUx
# DATA teYjK5WVevNy/yVC7tK7hdyVNsWVotaTvLqacYL3lQLurItO1xC/vm5vhWyAfZnzHDL1e4jMFI/WLxUk3650gJvIegU2gfJFVVlj
# DATA qVTtDWo1pdEr+eIYUgrRwLCm/pk50i0riXv0449l5gqGHRzjbnX59TlEF3Tn+J2kTHN6PS122aIVtdaVfHtVBa6LoIrWPxnGUZTT
# DATA +i2lOmc3ypnxnO2Yr8B3jxFZBf0VbATbohNjGAeNyMFX4nsu0dw67+1cFBiEjhFI22C9yecoR2oYUS7kKzL/7rriquuFjsJdgfT5
# DATA WSIn8dlTWxt222IVyZBVTa5Wvi7ZB+jArX0O/8Hjy7Tv0+FPd5O09hmu8+FxmfuuFFoOQFI5w0G5vvKGg2juj5B5B+40sxWxp1RA
# DATA ObNMsxDXMBs6BZPA4fl0wW5pvsNmkGRgG1gmiGFyBamKg0DF8mN5hQ3KA9IVWw9xtTOYA4ir2/wiZjlHBHdKIpK7L3Q58DMwG6XS
# DATA r36xJqV7tZfRPFGil7GHNUa2Smacmq488s03+Z8f54HAa8ZXSFTwWMqfdEHhYo1wYaE8fkO+epoZN6kwZakbOm4G2qzbFa1qls7K
# DATA is9V1nF3/ZrD5tVVTavPtUo1jeJ5kUwJAxBSdjW8h0RKulzMlnRuwBBm5QEa5ncU6d6sodxCGSAnHB8SBXmv1nSU8kEjAuYsmB/C
# DATA L+VVfQ4bEr1V+SNCqD5ixMLfdbSFqg+CoN2GP0XHcjC7n5Yc36/aCHKli8W3Nafj38rEyNAqm8dZVma84QYmlRsrKhBUu3VdUVuE
# DATA BgsKXbUNF/Uh++xB1x318qFWDb3k5+wxAfMTjkSx55AKomDjmkxdub60iy3/pog4I6bwRl5G5XkC9P1mh/6LXLtev1DdsP1CD/AI
# DATA VDC9jNE7bkuyKr7g1pO0pDl0pKDAIJrS07h+OUe5xE6h9vZeWuet1o5qZdqZWxZ0wQrtodzSn2roQOACG6y/VDQ7odid2D/O26UC
# DATA DU6RSc6A0e4U1Hd1T18enJweHh+pgbmyR419oo9x9UmvUkiMoxnqtwKzQsvFnFFnWXMfZMK5mOC7gx5jxD2GFdpuYvupIhG8WZsq
# DATA bajzTE4V0DUL7BAOkaEpq+Ks+neNKXI4CWJk/R5LJra9q12RmFBjvJE7qtO8W3Jnranr1jzWhYYFH29LKx1oJi623o7D2+/uFUCO
# DATA 66tyd2dtvLJ12wNOskrvYIhR3euE7Ge62G3qS90Vz5NyyCsuALX+j3TxW+4C3bP29ls2CZ/atgwg69n9rKPivEZwqhshqbXaIuwv
# DATA ENkxYLbIUkz5bAyvEt/CGv6kyNsyNlXnGk2PMH/pRjYuczQvG6isO94ozvzNm3qdI12mzZo6QI8Ugeakmro4SffLJvA9V3+JpgT2
# DATA cacjp/uUgWu6AcRZ6+49VBhn5QS4aVwU0llbf/HRaLiMp7G67MbL3bq66nPQB6nvdTeo8pOup0GdAdTn/uzDgAVnALkE10tQseL5
# DATA NRfaigLMCIksoGu+VIrzKXEkg116K1fdUD3MXG+SpIQ77IkvOQx0BQPAC7ouLNWIimguTA6TIZFaQfmi/FqXbZ/g/fXjRN9bTwox
# DATA 5hoFxGGoHJhKQkLKxM8Ylh8lb3ZLNTHwNjEKksx3rQ1UWU9Zv6MzR9ccN3CKPHKYkOLbj3lPO3Habbe9bmqq/astd2/phDTTZ+9V
# DATA D8VFO4Q2hTTR7onxQ+FNzfSkRplpymn0lr7VDg5+cngKW0K+gQg/ePHy7Ou7e0qsrDz5vr83pbuWrOA3Xt80Ww7HSXZF2yBDWW/2
# DATA gLpf9CrJCrqbzdMQrBQ8jE/lQxawZeIlMAW+0s9XwSWV2IHFHyRNr2j2vwszup8hAaWo4+4FvInroRDuiy6I/tdlVYX1MXDymg7X
# DATA F0hwmuXRZJ7I7RXmHpWPbE5i/a6Qq99EenYqy5jt/2iciw9FefeANJCFSqZdQSUYTo6szSeLeWxtJtvX4Koeaz0ZQiS04Z3XHQ+u
# DATA naZEL+hwPZiWld9L4YF0pmjNLh2A1gHVU8MYQamq9a4HCgbkaxjc25iw9OjWEvx9dHOkqQ+DhxdktfkDpQ1UNQONSKoWQQg0ZEnW
# DATA lq47IGr0uPhVxrn1rmPMr3RiFzzgkgVK66WmkiZkGWi66gHrq/zF0ogZJFaLKw8XwmDa/P/JGYN86u13n//faDRbjZX8/3r3D/n/
# DATA 38W/jY2NkxgrVPnZckYX1sSRVRmZc7illnWATgFMCI2gcYjKxmg5tu+mvSfdn9L1PyBJfzkUfUb/cqs/os/V804OXh6fHp4dnxxS
# DATA pjsfSJISMOhvuLwK57Uk3RqniwWY9FvmAltdJmblp/y1Tev7WK0s4/RXcPMKd86lae6HT1Wvyf0CPdx5fBsiTdia69ViMct2trYu
# DATA QU9YDtFjrbs9yc3xzpmkAedRXTAcd97hi73PsTZg7oyC+Hh2zuub/WBzxIk5Fe/pwd7T54dHmJ9O8VUVBJmlWUKVjvSNBiYzr/TH
# DATA JefKt5VIrbmIWnKZ/7hEgVlVpDzfai7NdnQzBQZQfzAeYLnsMpM7pnqnC8qGWL2FRZfXse4cotcQXH7fcvXrFGqM0OBDLuZ4GPEt
# DATA ivmYgMKrFRkwXZCKaPXI9wownA/cUuPchlq2ADmBRTgLLjNT3fOTledPydI1TUzF3hv0OZ5D51LibOTe0sclEu1Vpspu9sY91+i9
# DATA uLCRAV3niwhfXlIxM+kuYWdrvnsLDjqgxIRk7g+8y/kJiPehSozmFlkDOBJdhWuB7gfjLGVKIcsqE1cP/J4EWZzVcr3uXadg5wTZ
# DATA a+z5KRXVQ48Ed4Bnqug96Mj/KWbe8u8RdhyPR25nxTgunBsnhrv4kKcF2LsoKBqlKjNaRIcp43jCIwkXNWTf6EbFq4wrFdvjM9Yx
# DATA LbX2O2tuw7Ro65GXbKTzSwpfmstBatyJXEe67g5NmLYwS4vIiu7NXDvzc/Plwo1H8UvqEAwtcPljVCOrJOgGrEzmsuNQb+R7E1p1
# DATA hFOzRedeb/3rJsm52iQFxKKnvWxdI6O6+uGuX8+7Qs+4OKQyuok1iX4HsjqIKA0F1GPQfyNzGwu5DnYtuVubL6flcykJiWXucHoX
# DATA VU6iErdoGMwWeIWyTJd/xFiD+sig7E5AYW7VqwbwipPHoUbMFhG0pkyW9uNTWWR/wZLAGsMzdPHEUabnPE4mycLNbrRytPNjA0jW
# DATA CvKSuG1k1YfIncG64OxLdXcd31jF13Q6wU1pxrFNM53bJB5HfJgI6/nDmzv8PkdNZSys5jdg2aKM4oQKwAvplVSlwoBLE+pS4E6S
# DATA kVpqlhgr17ddztMl3UCgZgZD2JfmqRf17dMyNhhfmDmYv4Ll7dsa0d4dpuZ+TJ274Dgront3rwwsW8ULuUqmFKZ9HcczAQ6vDwC2
# DATA rfYN/WZpHPlNhJht1ldw4aBYEac1pGWdSkpg5ib7k+fWesGJvN2XC637Y1b7YIT/pVT0t+qSqy6QkyTsZbPvW82vHCdPqsLddkKx
# DATA hmX9NbjuTcx2IjeGlIsUGDzqxlrPRPTkUsW6glzLDAQA13XnQcijHNiaFNUAhiZ17y5npoS1ogN7BdJupfdx8W5TtUIXwDnD3N5z
# DATA GZ41JB2HQ6v3PhanM73EHMO5D9PllGw1x5cnDRzttGBjm+EtXZWP6+KNbSAI70Epb+a1+FTazK5k5YwcrbXq6IfTD1a/lec1v6t/
# DATA tKs3/U5RUcsTLTMFRcB4cPNEO+uFI/syd8HyRNYfz+euqjGEdq/vDei5ynoBF3/wGvHv+1q8jeB9RNkm+vTZ4ojicYwW5hPgKT6V
# DATA sa0qdjgDIqTkO6n+7mqVK6s7n1AlW3OXfU475CX9ZNdvPC7MZ+kRp/pjUeBPlofVFLMmMuswXY75Ajp0Y49vlQqdLNYtDvc3Ku3j
# DATA ogLIbwX2O9u/oQ1aIYYnuv4u3TuuGGyOUkqVb+Oc/uAytrZ59CElcVn2YGSQLzPaVfblmvbIaq0Ct6wAW68rS+8Bb7CS1G5hWXGq
# DATA qtvO6AvJ7P9g7tV/H/7f7Pfk+H1c/Zdmr9Fy/b/1Xqf3h/qv35X/90uJqup8QOF7cpEXO13FR4Lq1iIV9nyfvzdXt+Ve92/VfwlW
# DATA 5Ms0S96s8QZbvl+p12LXn+CDzqR0y1ku9s7s5stQWInRfO8a6en3H2SmxKSr5fQ1+fcWwNHHwWQYBTvOEQXLVq1gjYx8hJYhUmos
# DATA 9eceOeLnBRUyVMibQ1WL4BK4aQaWm1Ld5PJmmo+Jklnp7JaNQg22VGEWvgxk1UwZw+IWvqe5+ya7WNZ3YWWzytWanGTIFQHoBIHz
# DATA WCiPn8Mc71OG3/23d7/k2t6qkPc/wJ/fvv/5+79+989CmZvvfvPu7/EK+3f/hIXAdSUPgT+zDvrlrqCWyz/tM3XmmZxPfUSZ+bsH
# DATA Z0C1xmUGVHocC5D/5oEZUOI06dZvg/MSpXVf7PgBEWmABMqkwXPiz+YioUCWgq7g5JuEljNcYFBtzFV9lgiXnOiphbjV9KBZgg5K
# DATA pJlzxod7TzmOwj+TK0Vw5/h6OWBLsOnT4HShTDK1s6DTud0Sb3RIFlZD+eHBs4Dv/g+FV67nTlj/zfu/IZLCSu7wCcu/v/8bqgn/
# DATA /r/A43+k8vP/DC/9Cx8ZLCigL8RigUjHENCOAeam7pRlAgomUbeNhBPMJ/Dh7kGY/xsWnv8NEvm7vweqQVh+w2XxsSw9UIpVmB7r
# DATA 3b/7Z5jKz+H7366Fl0gGIKya6AXBfp6D+6I4I0yuOxtZQaq3epS7zbewie82wZpavtl8ix3e1YBz1y5/VsqlY82UA2Z0T0DM6nnn
# DATA LUOpC/9dqMF4mNKKDWYcznRxHi2BOplkPWRTyDnf+5gsS5sbwULAMvzq3b+8/7uCXfyLVU/1PXeuPxIdfywRtxJfzZ4/EW+mpy/c
# DATA ZPfLh06NGe0v3v0jfPnl+7/28Q9+ADKD2d3Lsx5/7MWF2FQBwNvSiisAqHjj2k7oo4q2ffCsYUv9nU977dc0Ub4dgn+Guf/83b/A
# DATA //3iEWtNrJgudyH+TbBxSqaSNcYexlRP2g8FEdm3zNPPN0ycBzbAlojPbCtKb6bI0bf+P/bevTmO7LoT1N/4FElqwlnJLhQAvloq
# DATA sqhBk+huWCTAAUB1t0C4plCVIEosVJUqq0hCECJky16Pw9qxZ3b/mN2I2VnH7r8bIbcluy2ppYj9BORXmE+y9zzuvec+MqsAslue
# DATA tTSeJirz5n3fc849j9/BI7ESHAb8nGbmcDJ6qS50bf1JezYZMDmlLrxnTon4iqQTKqdnHwgMznNZQPZihBg54i+YEP/k9T+qv//T
# DATA 6y8TNcO/xPQjv8AsILATf/P6i+Sj/vTj2aEfwF2uZRVjoBhXROTKJIIDFtmn14jgoMHUrl27canzwpsBBvCTik3CIqAWSHS4ilrT
# DATA 7jQU+5yEPkDysqYv8VXIjEsiv5Vxaq3gR5FR/jdkiL/gRaKcKpwDJVELRWdEnZkEa1X0MKFa3VAK3d19KXodCEudVWfqIOyAM+3D
# DATA b06BywcMEr7VAnloX8tCBzh2LTmBcMIbF1nDgbMeZ9eu4UsnKoY7YqQSzMCKgod5pwURLx5G9l0VJtabwqFr6p0XPZLQBG7JprtB
# DATA NbAF2uM4O1SN/mEKyBtjgEZVyq2oXmrxqdr2akIXxTfOCAiFgSbPeXHA+UHNZ6OCyQVKA2nl3vrbUIRR9FWeGYdWkGymioMUB/uR
# DATA Uv78VGCT4ajmGJIdqZPH5MidC9UCWsOgmlAqjYz6P2Ov/1QN5G9AfFDyXSh6qkefK7LyU+RDX3hTAuKr+urNX4qjCA+dqxHSGwO7
# DATA 2D86bXOcLAONyT3Tj1ytxagWQTHZ/Xh9WRWK0T0heH+uVpJIuyLyaVngMnUwnTSV/PiOw+zR9oIYRLOT2gnFupvMrKLct8p4Qfku
# DATA fv15dPBq3LBW/wHlit8kkGkLSKZ68NvX/yzkBqBRhWOlXTCgn0VzR6dSE5HxIasER/N+0e4cFqPBbMrO6GmjgS5Y+BaALouSWH7N
# DATA Q2sGQgDDAgROgAYVWFwAUxcaFCLV7lDzxeLn73D7/yyJTuwv0+i49AiKhZoG3vY5MDHIP6aO0l9BBjQ6ThdqHFsEjbsX4w7WRXIB
# DATA iUETpEYn4eVpZXFGfz2ahLs8+FjDNkS9KMpnXhENp6I5wq0u6xjDa9zR8Nzp0qEeqAAQRt8lTRXaZ5JD17ODgwscPiQwRk4BavgL
# DATA YA6v/wEOmqCghuZ+CTcaPJZahCm90BCDQ+pYhjMhBmbTaQdrKiuKrmtJPZdfXr7P/Lka9T8Qg33zP6m/v5iz0hbSSXRZomhox01x
# DATA K/DUrzpETKo5BVfRd7X5a/xfYFnhTqaW9c9JM0OH9hLcBscmZSih97QhysQcXfbJFvEa/wvWaslDv5ncHyiJrd+1JlzQYBfoakht
# DATA MZO9Y105ek4pI9OzephE3cFg9JJ0gP7E1fVUmtv+gfF7ZffYtYNzxxNB992eSPMINxz6WvBFgVtewBkLszL+A562f4LTVXb0tKAG
# DATA fhwtp+WlYF3OfBGanEHWHeFTSQmjwrzbLlhCx0Ojn+ozdB5f1qLzIu/VSLnvrujVq1fvQ49wbdQ5n3UGSOl7fE9hL/mhtm1Mjzug
# DATA seDoNnLwtNQVjCcuTzDgU5zr1eIRhbIAHn/tYlEO9aKHwShFP67AerFSRfD6D1KFcf6CaX+vJaGRKqUOjdKFP9BLxQqcRMC/9ZZK
# DATA BpuPVJ66f8RcqKCRVEduAQVVmcByEYCoUlZU6t0CZiKx4mArcKWYsB57Wqy4UQHz5CeOd1u0uN8pS00Jx0rT1txvXkclQS09HIwO
# DATA KRECXX1K/HeIQS4IO+XNxEUZZ2se43RllQAciytdiguYsGm1GGdYAz+4sKj2exHTfIGF7u/+EJgZWLuliZEnp+zKQZTLIRc5inME
# DATA lAsIJ19vBm/yHHKiaLXmEU8KKjBJq0iIbY4XYYp89l2G1047z6o9noxBdLH6rI49/X3kInfVbVUltRffYsNCVeeihbVn62XToOuA
# DATA X/qetM2RTSI0zrRIrv8BVUGm7ahXtVbziiUj/D8IHTbPgnzs3Cs4KqZTzTg4ip9CPVCqx5OxkzuiQCRitX5FdX6Odv4tt4N2J3bb
# DATA 08pyf+K0ejIybzGnVX9m9OkNmYunRsQPYXcZihTwXr9uogGlNbMoTi6e/WHjcAaoLSXVF3lpPfqm5s+MucLqiQmqjuWz1xA2dQlo
# DATA SL6tJYAizF6xTTxRYU9powAqEn6fzfE9Jma0e1qoG83GK3W/W7ukx6STzej34f+nxMX3b3j+f2urN/+Q//1r8//bm3SGBR1KdaGl
# DATA HFiKkUH0UsERGqBNyCfqBmuDvRWdAsl5NJtSWcQVUUXA470zKBZP/dYdjU/fPqlb/5nqvPk17UwXjyTXqd4mAxC5CXnGfQZO2GCZ
# DATA xf7wMxxRYsuhmqUOf82G+LebQg4OMuVlGSpGOYWwMDjseItuoy5NyVoWDYZhYxSp1kOllG1iVF62MyA9+IcZ24AnMJ67LTHTf6Jo
# DATA gI60UNwbVkfJkl1QXiWPDHkgmdfSQasTWU96/c6z4UgJ1l3SeSjZGWFnpqOkOB69NBsFiRxuFJRmZ9wTCn/DHcO2b/UxWZ7wVT0Z
# DATA jWl3OhGVDOCIU0g5vuRdRifBcdUP9E3Lun82KNOQeVmJMufPxiJaBfAW+VP2HvlnMOS5qU70yCgbwtzkPWEP/m91Wfhn0LAFDaEJ
# DATA ENxUXLe2aFofnU5Iwx1hd2phf8w0wRFDRMl2oMe4/na9rrSPWfsouFWQPvtL3+1CXcde/851roA+G6hYdQObtjsIYCG9hvlAmLx8
# DATA cpPZ5H1t2Jw16z5cT2xkBuMciwki1wz1MUKad6aN3fbmo+0HGzVCOp624Z31mYWCf5SsjhRbLIemB6c2/lqRFrh5j/Bum6tfi+yY
# DATA /x1vqT9X86iupHTv/BX62PwWdEi/A/syLIu6hv5azWxwJ//Nm5+S/R1u3/9EfohosP/1m/+YukCQbZ5rvqrybDtOFik8Spt2PwIc
# DATA KEWyNBOCf05Rr8o/kx/D9KytYYLGF+quBWpdng31AK+YBGmhn6rffhKQeL+aVpeqJrToqiPQ506hXDecQty8B5A9A52KcJXN1RPU
# DATA 9ta4fBwKm7MKwB45GoFaXROdgklcID9iQ64CkffT7sOt77r7yehOTZGdjY/CIubtg82dire72/e9+ks1rosTSNh2SJV+DpvuV3JL
# DATA ko1cbMq4I2FF/4h6yUd0qt5/nwwcpYfnAgP7O7XfSbnz9zikXyZv/pyIGrjkVg9IHSf0/v5H9t/VEwEfKUqH9mZQIP0KPHjVI3J5
# DATA q4kGbq8qAcJr5YsE8ncYJ4/OeDw4bbvUjv6BqDK8yDvsVF9SsEizJG8IyhEj0CGNCrI0UPl9OscHdXi+3d55sL318DN1VvGX2l4b
# DATA 9/e2d8yDre0Ptx8+3P6EwVTlJZTPhyp2hKfDtulYGWvOmRdHHTWRplNMIg7qiX5C1OHA2eEhQdYWL1MRkyRRERGleJqpi9LcL8hL
# DATA EF19fs3uBrArgACzrxOQXiouZAjHrRZXNK69COhdbFZhygmbz761w9UTQPgT2BZ59PvzsRTFVVSVdwdKunRa5hgec6Vgf0Wh+QCB
# DATA tt3vSRD3ILog1KuJ3USGRUoHTKqXvMfNcN3OTNpYdWijM0R3Lm+FGQGE4Zm1pXUF9X1kRahraZ3ME1VFM0qpZKMpXFBy80kwyALg
# DATA oGs8BgCgjfiMOBJddBTkWOX0lpmw1yvV4Vi3xEiWgqrVq6Bu9UxW7iymPnOe6nQBieY/Kwr59ygBouugbhs+1wJjuEsyKd/ZG4c/
# DATA Rpxn20k702yHhWgamJpgDk0IEZSgTTUbaqzXXmooUO5FIJExxfxcRJ5TQhlSiS/JGpEoxgQ2hF+TA7U1myBXQdf9f0AHQ/QlRNEb
# DATA Y0lCkblOPayDMyz/lQJKM8ld+GQ/BX3BLj80bqmMudw+VtdCfYsz0cBAKlyuIzy1ubCa+yyQgfEdPlT3bEDt4Hs3fYRWtOYK5aCh
# DATA JxR0pD3p4eLj3hRVBQ3oItof1bRTFyva5W9maha0lRp+j9Vl+eVo0jO/1U1i/sr9rY2n+FOpPHFNXcg4voQVVeLAn5EHPDGInyBH
# DATA +E2CC6kEEY5bAlH9zV+iyemfyy+gBsjMqixqNeg7xurpZarz8GAvwF8/nOWA9Ap/Hk06z05sGhUHGqlsKRhtSWOxqQLslaKRbjBA
# DATA sp0PX9RAJcvJuyW8zvP8lJ+aqmNRaZ2p6jxEpk3SP6l9p5m/ghXZT55OD97LvgP7wIbaqBo5egZeX2s1rv2bVJJRSJedg5K7xrUS
# DATA xhFIUY1HHl2FFwSKB0kCTHkKGU3aTeg+0JCW2Yq6sqNB51nRwior7AlcP/yjMyHrRMiYXeW9sAF+5UDtqs95wseT0atTUn9TP5xD
# DATA Wk+e94e9Vtrt9HqnqdW7mLmtfefuFZFWtLF8kLmTS9XR/Na+E5RlCyfoGsGjCeVRljUNDan5CdyHo+FghPDV9OGSi+UFEsRsaJdh
# DATA GFsHHh4vgZn8TekUpnul/0LHdqj5nkg45CKC8ZaBWaPQx2f9oePzrg8d7xCYlJPsT2pPi2uIfj9B8+3T4r2stv8nd9Rerd3JAlhK
# DATA 4Q1B4+FkhviPOku4ADR19Og64vrR3zcOaMfFLEhKFENuuCocVocSTsbPbY77UODcAMQD+FQQWkUISkj2eMp0RyTgmw5qozh13BfV
# DATA GbzNpWcpRaJSJfCI/9Y1nemawmw4bnAVoJMcUZCV7Al9H3E4GSJ/5wmlKvC8naEeDatyY72x5+8ZD4sGbhpoIEuW/Yfn3uUW51Gj
# DATA 0WG29nDvyOyChaNN5J06n/P8HTAVuF0Ch/gFChC/BFkBhYQv8Zr5C3ryOUgTv0Nfhc+VRPE36ulvkOlMcoiRyImC3JGXGLzIwCWG
# DATA QjVQoWTevPnrtBxKz6TbBDigeiLUMoGcRizJKIatEg4IYMvqk8yRVI9ZwoTKTW6hIGV5kN8nVI4iKzP6OOyerHJftXWACK1GkxVk
# DATA FsNc4DrNPDaBzQcJqOCv8vPPsUUnpPHyFLNG7/H++++XN4BA7OdyRVTvdWbNXl9HgJj1YOrRlHMdWbWl+KyYeyIzMd3Q8AWCpoF9
# DATA HAXJus3GYRPhzdgHEkuQ1AwfclgvgpNWyZQhwJqpc5/+cqBj9+1eQ22v7RDcCPADrfXwQNGYqRAqGk4ycTCCJ/VkFy35aJMICj/9
# DATA yWiIN2KaUXVvmFI27iIiEZWEOfA8gYCnPjcTv68FeFgS9AUTuhdN7Pgyo01Cskf+9OsXqXArwKVELWewrNQXkNegKzYrz4Eb4rKY
# DATA lCeONoBzUPdZ94ntRrI2YCF9Qq1c712bI19+M9k7zhXHLaaJ3nVwmjqz6fFo0lenrv8i58DDYf4SOnWHxVnKJkR2rzEA105HozDn
# DATA xpE2T/WHZV1ATcqk/wxxalvu8cIFEVp0E9hH614XdM33AomMHxgvdmJ/ee2AgGW1EFwmUJPgaaRo1aLualRSdpw3onRG3AVsTWeq
# DATA mSat27kLq2iXv3yLSvLnIdTSN/tO+QN0Sodq9SEFmwD2Cgg6ox+ah24edIGdmvJBIohAxTB/oHb9MgahWg0JP0YBkIEO+ZE6HF4w
# DATA qa3EnqA6u7eLMwXNHaV1Trale6kpDvh6wXHkSafB4J2eBwJjTFqOYRg7lgknddffiI3JNSiqx8r+Zum11Lria6jEvpKFJuPRgL3B
# DATA 8JlagGW0g8/YvdCBFZW6F+0VH8Fs3OcE4VotUU+uCV0LqMb7XTQ+Mz6K+x4dd3c1mcQCB16bSDpD8isdwGmskt4eGJURYvkZ9/4K
# DATA Kq6B6bQSU7syQXQyLpjQx8CnAk5At7OvPX4PR6NBTSLd8d806N0prYIhHJxwS882bBUUapB4NxPdPH7WRDcOJc/kY/ijRttI2vJ0
# DATA aLKx5rkf0Gt/n0+4C00zGDvggkdcnAtZAzoJxJAFaPhpkUY1daW9wdv6Q18M9KQZ5P3ByQIZwMo5C3/CJGGZ226cngzSsH+1igow
# DATA 7WNj+goOAxmhcdzoKOuXyIKcsxUeDpFxBNZamE6jN8jBRSVU2Wttmqu8r4M7SvskV7xSPwBrOsqo8jcwFf7dHyLEqXxEzmqKU0zy
# DATA l53BQN4yjRLPSi/kyVTTb2xOvtMxhufJqgxngDMCPKRGmVCdQnzr1KrgK63FNdT/h7pv/Qos5G/+ku08v3TuVebOZNqCWxnq7VQp
# DATA UOW52ApgnKcbFsTB/7X1KbHT7Ij6aBCNdB1zVdlPjAoeNKZAbrXkgrR7MJr1jgYdBJlMn3XhXGcL+sj8gtCLUJkJADkG9eq3aAv7
# DATA +2Tv4W7JoNT+H016RhPNJp0FrEZWA6932sJTYr8wMwLQ/MU076BhAgT9Xmegvny7GfgJOViACvdP4dINt3J//Np7xHTJtRtAn3fV
# DATA u0fazdz0M4vby2iQMPoFB7jY+OD6/zmrq7+sGt3noUr652/+wh81quzx7IsTDT9rhk6YpaUf/sU2MkePKaHWzZs3mKe9mnROo41I
# DATA 4kPCpfw9p6lNKsytfcs2N28t0JxpZx5fQCDOmTsBZHbpjPvYAggvdrbqdkznaEi6MX/5/huZEt78dbL+eLPuLBbATjAOxc+TT1XN
# DATA geuCRZ5g1wVewOK4MyHt6RxrLTtrxCyvSIgdeSZiLINayWKINYlSIucrRkv5DNUvr8VtUdpK4Jaa4MACG7MVyOwAmugbRvLJaACT
# DATA UTMWK8coZUdPTIvxqqxpagGrt/EgjE7lkucrb01nYgJkpU8mCHO+n6qx768eXKwvQWtylmGtHtAww7p4JcluB8eDS2au16SaTJcZ
# DATA V8xJ1QAFcaMFcqdlP/ziwJmM6k4ZnjL/DP4Xi/cSV8pWWm4byeu/Q6r6l+hj8nMwD/4Si1OwHJnFtVUR8AK/xE/pOXOln/PDXxkA
# DATA HZoST55SD1FfCS9pmVI9C1YIa5nZcAUSw3kdnhwLtAun6P/B2Lo/k1NDHliIlmNdEskKKkjRYaf7fDYW/gv0gFwo+MQtOzCJczL6
# DATA 0vecOFrnhgaPLJlE2qpA8daEEjr5OSJMq9YKIBVrSvElVVOnnqj/gpMjbf+mlatL0qyfY8IwEJXMT7oMNdX1Vf0YHwPAalP9QZI7
# DATA YuLRQLhb9CM7FwiuFdKvy76iIpZM5ECQ6m3Lr32uXs2tPUcKR+jJAr5Jim1rL1T3eadlIVxor9s5VfSPYmO40vLq9oK/8GoGLz/k
# DATA OUw9s0BYp7ggu1XTsuRHR4odgaaxxa4nDgW9EqeCnCoj5K84yjPTaYeF6Z2ZRlPdSacPDawgtC2uikVtQa+EQEfztC2qLJubUa1e
# DATA dRe+D8VI++/ZZvYZ5YJ1FlFNl5nKjDGjuXIdUhC2qZPGvIIyuAeXyb5bDXlLo5knAFK9LI2XauztBjOoEvWkLQ7T0SQvjms66NT0
# DATA vu7LM/UKq4C/Viakm1yq2kSTWu7FWk93vEocHWx+0+3Ia4EqhKDCi/fQfglWVYJ37g8bRT7lbAa1lPNgkDbPBb5Amz6gT+DHzXj2
# DATA d3xJJ4iepZln9sESjtmHvjGJB8HPhRxjUtOcw0KD9Nu4R1ZedCYrg/6hRYBdUUw1XdxV+f8ylyvDMAm69Wfkifr3FB5i4tSNz6mv
# DATA sVCXdCVp/Fd5eyPB4pcY2y5lls+1E5L673+UgFE4x1o/d5aCMgaIzGEfk0+knNSNOJI9k+q0d/MJJCFUZXj+m6VTg6yw02tD5nMt
# DATA hAtgNVAmD/o/yntts132eRNUL2i1HdYbDLEW3AAih/eKprq8IZ0xB/tl9UAON7Kdzqu7FNneVWMEJBaxNw9ERmbwHxYT5VQcTqgZ
# DATA unteSnazol0uIjjceblJCz7BDwxyA0629dQ2O4jn1QRB+N/ptIF4ubQv96lCxPvgBdQXKmQHsiRXoe4BToDZgr7g/9X3scBYiL9A
# DATA VeCX4LKprwC/qnQa5yN9hzwsfsvYlz8jiZ78Akvm2kkN9urUnoJ59HvfUNGDaBX71wlYxLEEmHnLvO3U1j4dkZl1YNXja8Tr7DkZ
# DATA lZhL0GwloE0tp8GUWGZj76e73AN3izuWkkc4WAusL7b6gxzUpZRevnK/s9LHfMjNZoEfFOHmYS/pLFwo9sa4AqMy+WfOXoHbH7AA
# DATA 9iGNby8f/8hZOe6X9N5SPRbHhTPhGeFMTWn4ttwewQI0Fl7HOAMUoN2YFlmXL4n0ennvMWxQ/A74gFeCrFdqY7lCKJTen2MRrCdC
# DATA aukfXViAK1m1HelWxdAwngOWBlv+n0mV7N3fEbQSYydDrcCXi7DuLxhN14W1IV3fLzDODzDQf2v1y5GRxwbsv9FCAH7umPKhJFtq
# DATA 7Qp6e4Nq0wZCIWF6L7Ce4H7iBdmFjrYXsbti0x6Oe2n33t4Ii1I8b2n8y95L9MGUglONnFAbYGGdc1MRF6p515VafI1c44nQBYS2
# DATA yJIKUJtgvfzMqJwsM0AI9Y0HR6fxkVBpUq1LuIQqwRvAvGCMAFxTHdYt6KXvJPlzT06+AyePA8H4dL75T8bVH/TtTnGj0PscqbvU
# DATA 4WnFnu+5yQlzUJf4BcobEgdTe6/HZtbadRfVnuCsRbyMuRXheT53veukDbN9SBe/eHMXfBcj05B0hyaXo14oxKA7Q/xMkMZakDmq
# DATA Y99RdMNZdXTGjvvhWfrhzvbWXntj60H7wfaj9c0tuEVIA4EY+eP1rY2Htph+Y+UaUGFTznARgqMeepNI3ogQRwOJX6uNAAeZw+Gh
# DATA BY8a60GH+nJWqvtyDfbySmtR7bw7Z0pMe/JB+/GTDx5u3tdToRtCD/AwvsRFw6vys9wfkkOOmZd9V5uFd/gh6tpQpnvZeZEvR9C9
# DATA jKvmksE/iuzVyMYRZo/ovuGCOpuYpGAtCpmXZK8ljYOeebJljIVZ2I1QJHJkplLB6MKcXDc4ejnMe06DMc8uKZa5X9Tjy5XVHWXd
# DATA QSYWZE7A56WPUuwgHCxd4rR8ndv1LHKqmhVn6txdat6VwVF+pCFnShc+Xhr8g0tOAa4dWTssdKgIRm0uvX0b8xfqq6CwLqs07Zd1
# DATA kr2/2O5zsI/mJfyV4Vai72NOalxqKbgLabJCnra6B+gwzZ7ZIkr3gTFXC6LlgR0SKReO2lznuUlVqPZfry1oozEDl51QYvDmC6qH
# DATA jIytRNqSSBtopGkqAx1EB6dq8aEzm45S30v67c0tst5Shy2Z2YKHZQsaA53ntIUV67Et4ryFKrBSjxRuuKV7fGk/oMDP63M3f9gv
# DATA 75SA0psYIk9sTq1tVe9WlOda+F9h9mg5WmTFCNgDkf5BKRDMIS3fOBKC++YTSOStaCpv8lbNoXfyMGRztq0hD5XN7Ip9VbTSOsd8
# DATA lVJZS0gya7x1TlWpn4ys5jFlwWOrRNhDtQvv6ypbQSPo5ol32BZ31HObwaarxyCjeJG6lU0KUkN/YmKkOvMq1H0ka+y1a/ypR7Zw
# DATA JqQHj/TSrqWQhq57DFamcQ7J09Xu6b9QBA5/ZqXuxBGThvrL8U9d2NHH90Qi74N2GYZEDKyBPgnxC0xFHP1mflcFwZmSZNDsWLVG
# DATA iTjA5VC/grHv01Nuu5RfZxSZgg6ensaGYh/bZkjuFY4B9So+uaSMMK+iy4kLZbMXu5GVCQJyGQ9sHDP3strz237pX9wWGOuV1gL9
# DATA j4TnUqvWoY4euLo2btUDnYhE7T7He7xn+hdN6B/ZUhwwPS5zU8Wu1K37dDmxe05wp7UuxoTz+YtRKbp/M3mIgfSEIDkrOMs3Aaik
# DATA RTKeHaoRJU92HiYEU0bJSzgenmBh1AxP8qJoLKYdoTgHyKo3yQeUFGPIJIA3L7lHlQb78WdzUHpKUw6U6XW5Wg9UeNgbK94i6aPc
# DATA EbouNCtpfe3Go631T9a/t9EmPY2aOnLmjOk/cFl0I5kDRKIow4IjKtvqPCLEbjF/X9izh7+sdu4JCx146vCFjlSkGriUxqa06QLM
# DATA 6Dn0KaqfXBX4Bm2zC4IsxRCWDMszlZaALUUJrPkopD9xWm4/OAj5tVcbMhLwfTLR7hwYZTv2TUhlgAGBNoCxQEyH47w/sWGmLBQT
# DATA bsGrKeODKM59ynTARrKaesDMQT6XYH4wj5cN8KgTq4VJcSlUK4vNsx7qy4miCTaO0fNgkpmqKAjRC9aUkccyaHNunCJh4HMwitMX
# DATA M8gUryIM/gV/O2FTsWIGJokQ9RmiOC94f+jpdxD6FlhV5p1yrOirq1eTXL+NUo7SU6oztzlFIVZ+l/mR5PGwR9+qp807JmaXRP5y
# DATA Y4/R3wgdXebCjbAZDQVvnBAGXQ0zFMX7aAbAGknfPEiadZpquIXz24NYap8iRpZ5wwWBsuCEOzYhrN18WR3SSS6jXXv5uDA/Dmf9
# DATA QY+DhNX1AtUqYA6uQIC5VttPl3uMy8fTRC6QVCX6HqEO9BrlIHLhS70JCrht2WxFpTdi4p3eaVV0qs5uzK6t2ru4hkroZggIafG7
# DATA G6obtX0A0s5f5d3ZtHM4wCDjzTSKpQ3+VhRMjTvLtNQYq52XYVZdvQ6oIV8ek40QCRR0BqgE5F5Bb+46YoWPZtPWjdVVViBTbgDR
# DATA wV3z54abBOAiHhrSRk8eGjIUMHn9q+Tjvb3Hu8s6TOfNT6MuQDaQ8AuNwUJAvexc9I+oZgE3pF+rg4hA4XiZY7qkpD0gWxIZl13Z
# DATA y5HuiCaRo/kB3ZLhSAxymmeoM+8tQ7V0X2Y/9CwKNsr16ZTd1od6HYQP97PIboq4XlsQy4WZ5IIWDMn4RFAue9ejs/Lbs8HLsbbJ
# DATA CW1xxWYkIUpdm4ikCoMe5gjCcfic4gMaEUUnOXis/N2KwTrAPDNFg6Zc5ySN4JpLrqq5IVfBlWaO9kXAgrj4F8GFwbjuWvMyVRAB
# DATA DeJhMKqLBTstIlARVG9jNkSXpZN+Adem9ui5V13oU+IKD1RNXUADMRqQ1wmLElTX/TshDFtKwBOB+RUHR/pOZRb413Z1rgTixrLY
# DATA 891yT3REPCLrOolDTPbVLmyjknZxwhK0iiMGdjSnSREA4Jw07a5Wwt64PXKxyYyybR4diAoBjjyFYbV4Ct0mJF4zD0CoPDn0/Xl+
# DATA KlFwL0iLLbSqCP4x87hI/DoHlGm1vPYj/yd0LgGu8x8c1fxXf1rtRT7A1uIDKjG8XKgtLlCtytQNXGn5ZGFRN98gH4OD84xxfD+b
# DATA h/TcSGRSau3Xw15CgMRvHPccs8ilD4wje12EtrjIw9gFtrahPpBsSB4h9bNPsYGhAQrb9rjT1ywysL4gm7MP64QXRYUd/Jt5FgRP
# DATA 30MSnU1yUpLPqXzZbQInlqkonYzvk8+hW8Nk37dIKDndu/43yIuklkXSO7K9f8oa5jM95U1vBeqJnAOOrkAOLx5nDeHKrr5QcypL
# DATA AkyqLHEe3CQWP+w65SXd3Q3EV2SWnc0qGjH3/ihT1L1CmapupDybnMFhCFnJtUdD1V3RF+o4AQjFpqj4x2KRFv6waxEQLqopiC3N
# DATA 5kyNlb/IsCflrrpr4L9oVW9Xh5FG3XoCrY3rOOuImweM5yjFwfKmfYoWK0nVe3JmMOKKQdArkIPp/yu+ivit7Uk+yBXh9ZhVbHBa
# DATA 66KNkI4M76ITNV1GH+1u5iManUcR5lj7aY5oSGaaZbhwrOOMQSuUovqh+CQ/dDAW3M+M+b0cKI5q8kdqFF7exPrlotVSQixUoMt+
# DATA llgsy+bG1IKeE/zjElPlfvp2k6XremfTNf+cVYnbZYhyC2ojI/KFcYNvaV/fZvS2zGh0EHaDN2B9J3bUb5iRB40IqP/F6uQfMmsp
# DATA 5HzV+uGVfNpdwVIr1n0ey3R6nfGU8f88x/r4/XBBbUNpripHGWoSVnHKAfxRE+xJRjYb2Ymlq+xdzSOpF1xlAxSbpg6uceQGGqx3
# DATA qAlKs3nx9lpXFET/LM42FtUtBQzNSkVG2vNJblQuiok8wv98Qc1VUFN70DkdzTCAxeHkIa9Z8EAG/KaUtUcvJLAsS4stBYvlH6jv
# DATA N/BPRYrFldVRVbo3WZNixtDyhXLMvCXkmMltVgbwYY9eMwra6S1IDK/QgwExMCEBklC2kEvRuwHpQb2g1zN1N3mkLyWLOGaSr2Gd
# DATA kU0edcbyDjIPEzEzmd4o8S8q9omcNBfRB/F10SzbgecTGdMXOXrUZrilO0rQRGpsOyMvfFmF8tuyuCuGxemw5mhXnDwNXp06iU98
# DATA jLSkIrWKE37icgf1oJaudMb9FQA/XiFozpRs4dAG7YsVDSI0BsgH8msXyVQbaOxq09ua9w753sdqxgfq3ZkG+u3lnR4jVOPUnozU
# DATA RIyG/W4NFOZr1wmu5eUxIDMHBe6az5vl6a8p+R92ibKboZeWtvzcwjyAil2pmYtlmxaBbf7KuMKb8W8oEbbFqgXOBmqC4x8djnqn
# DATA Lhqv7ilqwmqQnJNzdMJsleM/e9jpUK8ACIi8pb2nW4PDW1V635bkXdsvHo7U8VkHByMw7NQxSLICL5p0L1ZNg9o2UJKhZevnJqsO
# DATA OQ/r3KA/hXyjvyWkC4hn/R1Gy/0SNHERwd5bA+ZBMklwA+xwVWoiQgwndAQl+k7yMAsVulYpxqhKJZBTKC2SJ082HzR8uZBTsaK/
# DATA laJD1H6XQ+9urt7MqsjC4psvPuja9i4nPJdp0J2pUMOQWYGtTbiwoSx4JItBno9r15lRxlWnaN9MOJLxt158MoUxa2Upr+ZPXv+j
# DATA +vs/vf6STaGAO0mQJbG0uGG45K9NZgoNxk9my7cwf14Rcs58/fr/asOvf/nmryDo08+dAaNLIzrakNOVy13GGvu1CV79YgwYAbXO
# DATA 5FlhM37BL6CvnP+5pXXUqad6xs8aZI/CPx2dLz4BraQNCYpUrHuZRjpuqq+uwkybY+2hDbJgFWD4WSZmLszW1homqqGZQ6g9k/tk
# DATA UiAH1YnUG+uTZzPYPo/xTU3It612uzfqttuZ+LIBnoEd/qSWmp6l4OAwAr+P1r62DBnDkIatl9Z7bboXo8GEu0cjg44Va1DdFAH8
# DATA ro7Iy63HlHNQcXolxvWkeTH+rZVUnO46OQLrMaG2uktKAls2Uqetd9HYmerK4XK4fEI9s3WXIewuUBf6pmR3ysowPC0Xq6pN3dX1
# DATA RTaF7J64Z1K6gE/VUnj2Ox3q9Sxf7qN4bvFJYbemnmGBrQZOIrZoN0CotEEPsPvRIxfL4j9QuqhlDsUYjlwwwpp30IDk6m0M/JBI
# DATA RiVeNzeZExl2psdF4EacnggCN7eXiH2aUCMVxE53UgIk9sEflkHV8RO6Y7pj4N+0CPyDr578y0aJ8QODxiB/UzAw/pbIxiHCOmYE
# DATA 9uY+Kyd1FIamyYckGZKUCPIhYSFIpXXUHU4HDgtzbMIevS1NS4waI3QBowxdtVRxbNWVjDMU39/ZWN/T+Yh3Hnyy4+cmrlNmJNuM
# DATA Tgx+1MMGZJLc9GWKVwNowRWAcDSNI3hRg//U+cnD7fvfbW986oqdLreMhIPSLkEJvzc7GReS8M/dNFpFAcnKC/DE7hTdfr/F/pRg
# DATA jhpOW9czYEBqYdvoOtdu435tt2G/tdup9UMt+s+GsxNccPizM2jsbn60t7HzqJ7Y3x8/eSy9tOg5/VOjCkxKvmttdc1H177+tKYv
# DATA J46gQxxRyiU1KY4aGfW7+SmJohGpnMSv3VNFhU82XvWnwl7r4aLlVFlNC0j32YEd9zm35IlxmQ6be/13VlQ1lxEjtwYuE1H3vTku
# DATA e4jS8xPMqw7S7+caEORXmGb9C4Tc+8Yi/zvpTH50qI7K+PQbX9n/IGH97Zs38V/1P+/fGzduvn9bP+Pn779/+/Y3ktVvfA3/m4GH
# DATA rGryG/86//fNKyuzYrJy2B+u5MMXyfhUsY7hjaWrV6/u5J2e2uK4PdS1dP3xJsEVof8yXlaLZHo8Gc2eHcdihlT5hqplicm6Fl31
# DATA bzClwMGCQ9qb6qfqtopXRv6pbi7H6o6pfwLh03+PiiX0r4C7hyqiuQcIl7rIxDSmCIv+E9rUf8sbrPfM6aurnDJPZ/0e9YFphO4D
# DATA 3qUUYVMXREVLuwM1oMSYEOnCZ25TRsJXg+arp0kDzLp/xShPxpBYpd9TL2TOE/K2QJ7HUTXWP3tJejRW5zPGUFJFeotprz9s9IvO
# DATA dHpaC33C3BGkj8jvMRHxPKraSR+8skl8HA0xvVOH8IpP9PfNxBX+uEu89A3+t0bDRrJMIyfi2h+OZ1P90kzv1mgnJ62wr0kEXYJ+
# DATA xwpFHhqFX9CbNhevgYiOlxPFqMeg4Qe56aR4pqZfHQe15euQ3E21MXd+oGFTv/rjB5h7/g4cHDwuRxRdgyodiGiyg1kf920P2+3+
# DATA sD9tt7lnpI8cPVcbIXWASqx+lW6IJrwM+ur4M3N+Z+0TeEaKXoMbcG40STYeDcxNbsprN+E1ZYWmP3VW6KiTnDdHT9Szjp0DFLFG
# DATA s6lMhV1PTN265jQ+nlZLozqgpt723gx07fr7jVX1/9ZgsJhBGMrAj2ZzLT1fpMc7+cloyrSu0JdYcsinpe0klJp4d/fjZDobwsjg
# DATA MECJVEbUDI4auJb4Fy4oraDJ6rwCoiq+cL/ifYjeXp8ufziavOxMenlv+fFkBA52iV1O+Vb9Be/sDJzT3NmkDgtMEMOFn7sdWki/
# DATA Lw4oSJj2/MljZ1AZUEMAumJ2foX0b1pQZX9rJzAKE8aIeQGfxDFGOIpIxRV23bl2Tc7juYM0ahbD3Qtcdj9dp2SPP+LAcNCpfZCr
# DATA G9sEaZr93M8p6/uWoq6+NBchf1TzDzS7t8LHSBdhWmhNxJUA32YNLpvFx3GfkhAv7zGcqjtRr5ZfvnyJOfeWTauEZ2xbDGfWsU5D
# DATA wm1FoWFbTSBIsHZDAJbASf1oY48NiGvZAl6haqOEO2xH7B6YHzBU4daBCWzBfwzZbhny7SCAhGp/vOWJfU23SWQI2gx0c54dyM12
# DATA 7VphblzXNhhhiimzxAD2K1eUJfcS/9t5BhKfeIEIp3sDOUjV3WvyLC9xamK27CR3pJ7EXGYvZBcxPlMkQUQNGlWGMfc4yRq9/eXV
# DATA DDTu5vVv15Nbq9fhPzfgPzfPsZjesHeT6/GmpfVC0RD9QVa6+kGg9ryFwc2cHHX6g7zXRI6RaGdRO4hMxmpFFqIWNcvUkz3avDEj
# DATA TcXk/d5nRX0yzFFJyRNzByxl4CNwoop2k8fbu3uwK9C7zg9ig86p293JmEJqrP0hzNVcw+DxI7XRp05CN51yvTdt6BsLQtF5Vdeh
# DATA ADz7kWq9MZt2Y9qb0sr6xYgSnFJlDZ1rPv0+sN73Vlebq6uegz3V1Zj+CJTv8TAl0xyX1bXSN61oh52c7I1OoUvU/NIN2+fM9pe7
# DATA qjr9fWFKG77IJ0oOLcBftvjhrNMDmW407VDyR0DH6PSHpGo3brRw83NYPOd2hFrIaKzFUYGuwHeZiZrV2WCA4NS1Sbq/vvz9zvKP
# DATA Vpe/3V4+OLtRv3H7PKVk2nNl+Cda5O2NcmLWR/0pSu89i/Od0Dx4G3OSqw8xuEbkfG2fdMYooNCdCASU9ft7m9/bQM26unmpuxP4
# DATA yaQPNnfXP3i48QDlsP6Juk/i44ebjzb36Gn+agzmE3i68enjzR16Ohq2jyl7kK3C5POxc8ceGwY83/Zu7owMnw9HL4daL5DompYI
# DATA ieIEAAlVOz1MnEyLzt5Iihu3sQDBjq1mda8EfNaeTjpHR/2uLiOXdTW526Im4I9vr66+v/btb1+/dfP9m6vf/vaavrVgKexBpNC8
# DATA 0W0O0csz4V6ovTuDG2xhFhH8aZ+domwWGVkbdu+0rYvRINLhiJ6nWWM2HitZ2EJi6frMDWVru72zsauor1rLB+ufwT+fbGx8F/59
# DATA tL219zH88dnG+o68rJQtVKFaG03AJxmbT2y3yE2mM4FDhwHzB0GPgAtgQ9JaaUZv+3nH1KPRvPGz5DDvjiAa3xSUx4BzF9GO24eZ
# DATA 3Ndb8uBA7lb7GDtkdrfVyfuNb2+1P95++ADqPy0SfQbuoKHrBR1X4Gs9VuSaGxzkYcpfWjpiCRQZkQ2NopyMsNoSSuP7+WSkGGhn
# DATA WCQQFooHlrE0JKloJBuvjjuzAh3Fu11Ku3CififUQMIHvOFccGEz32v5jZoDp2ZzzXcX4XnGPWUpjCYf5/FAIlwYU6jCT5maXaZz
# DATA 5tyf9Ba5IveI52LlL9mOnlua9ARTY+uP71jkmORoNp3hUg3BDFUk6Gdq9Uryeh3bqtZoBd2u2ENPCnDMoaQtSqBJfqQW946Sl6fq
# DATA Wk9dPOmcJqrVIfGCzgBBD5JiDAK/ph2dZ+h9ueSw4jPLtprsHKy3uE5xbWj7OlxgrZxB54FepZR3wtIgfqwNENcVsVteu758Y23v
# DATA +o3mrW+r//t+gCGRck8fwmp+AGGSqj0m4c67XU04mmZiwUkAWdgm0MdhZ7ALfB2xgEBcxax54MdUQ36fZQHKVSosV+BybEaiSCED
# DATA U6YxzkXa5167M00DMW1fv11Hp8Zg7sS3IpdXHzFDbAv8LJXZQmaCmLbAI7zGpbJkWa3piwFEQOKsjX5ARvHiuNMbvYQIyUIMw1Zz
# DATA EfI9Bs1OdzRoirPAIhdqXRmRh7TPMp04f6ekLkwuUtcxthB3WLO9JsM+/nyiFg70TjUxFK3pswN8rJ9gSTlUr3hR2KIuqoLum2Z9
# DATA PJ9+/IZ3X9AKby69r2shNzcaZebnGYhEFlZrtE3frBrSVTmK3Fx21twWdE/d00DXEBkCwn38Fso26rZPJeDXjeuL9Pmx7qvRxzqi
# DATA qhRTOYBF/Ymi6iTnVGwu6eSjREOEUxSYCoKlivdsa5SEW1hqdmX+ECH1O8gv5VptK8sKv5+2eq+JR9ZAuEqhTtUweOrP/eW1A3+f
# DATA VF4b1m7Xb9+Ee4NqLltkYWScMalxtb6vkxTHYCaCHUE640H+rNM9jTiH8gSGy5NiFbjvMDhydhhe3+qGsxmXMszWwzcxsM0Me3mP
# DATA R/PN5L5ZmkQJRWqzTFFFqR21kvyFGsPL45zqP0HNDXLgDoBAgRcQSDB8Icf7I1Gifj7ooZTpXNnswQnJiks5kJrq0Vp+WY8xsDLO
# DATA dWCIIkNQU68cksRv9LyQFUFvM3AzBKlGv0U8bP++jZOPl1YD7hxl38CfsDb72tQriwRmO1u3mpz+syGyo7NCzSztBFe1UTi5CAty
# DATA 20DILnN4okwc0TnP5YYCjmd7GP3oAImW7paNu9Hkpw2N1jrjvnP11mRSPdda3RpqnyCwDgIM0My8cni6rPcOhiM4NAFEMhMn1TnK
# DATA wTBmzQQS6MSaPqUPurGShnndhS5JLYvag23iMTQOkVzzEI6WDjEpUM+M8iLYd9CyAyl4yZYBc2l59OjoqMiFmny1nqyRF4RbqQbY
# DATA mjtX36EaW1pzSD8RUOiPULgzb6h6l7GhjBsHvcFXhJq5n+IvN0ub8wI3N34RxgBAQavCQVQaSPOwGFXF6WfnAw1Dqi5zaIjGFbpD
# DATA 2kD9sJMgel+i7t39US/1QujAq5bhR/e5NwdhSGaocsoIM803E5X3+8GMjCU5i2LUNEbxFYhjBn0weeO8+MN8CO6TtVg/sjs0F/ru
# DATA Aj8yP5MilsAQYlwSt8+HSih+7rNCZ0Kgm6Kae7FaytQp2utPD5vWyHJ+Ue+VoHvxSjewCr6DgtI7B+MU6zTQi92B2Gb/pmVqWYfv
# DATA n/Hgmvq08sZtUh/OHYqBRTQu2mzo+bJjXBq5Qc6m49m0LJ9dmT2ZvGFMl1EbAGtwCLZkVc/hCLxpoLa0JFGx07iia6PBC234M2UZ
# DATA T0LmJ68n6OOsgavqiQ820T8S38tBoW/t8LQm3ipeAPVni6hU1bjUDT4BO8EpXGScCdBBY0Wje6w6VBNEVnSNt1MLfCVo/PSkbbwd
# DATA pOQrijkcCezvwt2GgGbvP9nda68/3mzvbX93YwuI645O3Ig+UGQeTkxCNq0ibjlVPVrf+f4H61vtJ7sbO1vrj1D9onWmnZ4SnlQN
# DATA xqVHJKMzYny8usfru7ufbO88kNXpT6BPYnKMUwH/NCwDJDTDM7AvK1jUHAtWT+g/5Z2uaVo7Z6s88leQCSB0u00VEV/Aq3+BcbNW
# DATA ARZlXH0WJZbpE4CysOx5P+17koa8jMA2tPJPq6V9mumLNlZoBR+qP5uvBqbPqby9UeF5gXp6MsunZfpqrK6YoO/dYhNj/5D1tov+
# DATA jwSwWp0slQULC/tWZNVsCtuoCF4cd07BUFuXql3X+hKZHH5o9Z3aW1jfydTdAq5lvtWXoiPc1SUZTzyo6z4J2f8gAFA2lUn5S8Ou
# DATA 6UuLLmSqzBbmvYIS4FQS7BdZ+nv9o6McYb7oRnAHGx2pOQNeoiRejxujW7lJXs1dwWPBc5/qyVcP9Z8ynKQZHa7AqdZ2XHcYbuid
# DATA dnGuJ+DAUertjNXhprJd9g64L1BQ5mxMoZTM8412e6h1j9qGwiSapjU9L2XQEjnZsmU6ESn1HiYN/1BPcKNirsamv3PPtVIP7EpH
# DATA LCg0kzMrZJyDdNjpnaqH6gaLMZWz/at6Qa5SgqOZRlWA4lq3S+kpuko8oU/nfAaKOsW2pwU3T93PzlPZRVTeoFcgkw1Kh6GqaBrD
# DATA v81dY3gy1TWPhj2e5KoHz46nxm4uOaK6r5Pw3Eh20PKR2GVwA1d6k9O2Enr8GIT0gVo99dwEwpFhnshgeHTc0HYTVHKqCCuMmZw6
# DATA 0/vStRiN+dNjdUiga9/BnZ6oD4DNoX3hFBTWfrfuwwYdlI8XYqhEZ1j6AMU8a4dBhX2ASlFecP2AphF/2XQwiAzB6y4vakgMwAZK
# DATA eYWYTBzc0WbsCFksp+sW6bCa1lqX2giKYfRSV+pu5UlQJcIDHVZLkYNqmJa5ezPe2jeTdeubBPYVJf8ORordso4pMVgk5IGOjsSA
# DATA 0zHs9gEGGnGyk0MloPYGp3QHbEQbckKS336K49Osr72ae/HrKuZVfpTv83hJmw3hvn3Y35Mczt/YnPPpyM5HNJ4dtrqxgtj0y+GY
# DATA UC19ga7rqu2Zqaw85jI3n3Xr275iQ93cDhvJjubXDrxSbO+VMEk9AD7jB1F2ybJwhD0K7h1hcKwMZRZHTZVyw92P16/fur375NEu
# DATA +rVQaisOg2gUxx31sjb2kE2P81e9/jM4nqjmSZB5jCkvovr9dJiSOQglYNTHi5vbs8HosJZeY9KfZS4PJYrcYy7G03SVt9DVA2B1
# DATA kjPKQuY5FdNubU4ZeggFLNfx12Iuo+tMUGdN5q87iZhu1CsV2PRMPQbrO4tezKeU5EfHdNTDQ5VGo68vFXgdhvGiPAQOtakf/Xwn
# DATA UlyQneg3Ja24V6mFWiLNwaIN4NVlGa4uOp4bPefUpHXUtLfW1A091ghKaWFEtPT90rpDW5l4XdYdJZ4sEx5ZLJQ51pNTNBOUBj6H
# DATA H+ib0DLfhKq+1oHM0Rhm2GlrqCV374Dw6NbqqpAfdDyynexmsvbff/K/3AI/QLpvGpti5E5nUpVwIOncgM55cZYXvIuIYEx0H/7j
# DATA 3e2tBwi/XHpVIYJzuRuHeWqIDKZtIKkS5UvQ25CXXkOYuQQBwOaVNAzInqqKFodDqWaz8tjRtQVDLP9F/89PjfH1x3++f2N19bob
# DATA /7m2tnbjxh/iP3+/8Z/bL4fJaKiE6SmCGPXy5NmsM+klaK+4kzzP8zFGOcEBUzwEUQTQL+XU+kC9UAcSikcjQfGGx2mlRAgnPyEk
# DATA AhOXqY7icKR/9MecdO7tI0OPB/kr+2M27Q/Mr2nHxHraHC8mjjQ/GQOpWFraAxfDRKf5Az0xwb3hbKVLO9vbe1pTT2ChptwyIscZ
# DATA OI5s6cHGh+tPHu61tz/Z2thp85fpymg8tR+lS0+2Nr0aCyRKPf63rIGGRn7Klu5vb+3tbD9sP97ZBvA8t7bZ0csVmeGt0fNrhCWa
# DATA jKDHu5t7G5etpSCB/dH6p234vP3BZ3sbu+DNaCNczEt4rmRfHHt7b+NTnJg03X8y7E8Plh4IMcxq63HPshoKF2NpHe6SrWE+fTma
# DATA PAfG3mBXnh5A2U/0BC19gB5VrRMlhPTR8szllvY5Md7BEjC7lrrpQU63pY1XeXcX/AVb5jDxQUqqVnwFe6WIroZAXSJfSOwmsJiW
# DATA ElaW9jcJwPVg6ZMOMKkPTiMdU3Oh12Ljw81PYXb27UxswUxgkOLBU8iyOoCsEvqR4oKHsBRPh1KaJWyDHk2iKQFbv2ilwhh2DUQM
# DATA N1ESRl85aJrkROAmcqLvkEdzqBaceq6i2xmDr2ebZFN6WJEnk1rH/8o8TVqa5wV3okCMS6ahJY3+uO2UxFRQ/e5U2mds6AXcQPuv
# DATA BjkiuqwmCK2NL/pFG9en2ymm7uMZ5prEm4Z/q5FYdusJF+tyaOzmY6hHzd8wn0qXnNQxU1Lqd2grM8nl1JKC0U9VogZTHCPIi5r1
# DATA w0m/py6M9QRjRfFpa9WEohNMpJ4K/M2yMXyNFiW8RIIng6k0S36cnF2/fu6YdvnNveT2TW0zhCtDbZxp5Xef0mca0XgM/7l969aN
# DATA W/bOSrVUzZjWOQM7wtKuhZmHCx1Zu/4t3ZNqn69GE7y+6mu3wOnrkFLzHkJvdGWL9OcBkhX+RHtmdk76A/RM7o9vY1Bl2kzJC8Fi
# DATA Z/bHqWvnPErP6MPzpID9mpxh8XNwI4dQVxbjybW8ldTSfv8IFQBnqA2A6xXpEmSkqBiVWFI9QMpClZgmUCbnlzo/uPFzglW1mym2
# DATA vBiYYYuYdV5kHolOCdcBJkg4MdPuOOlhlWe2etNrxA+wrcp+87k5UrSTfDD6cL7OkJ+fJ2dnS+Cro+o5IehW9QTHicXazCruJEeD
# DATA jrrzMdG5k5yfLyWYFpyvH1ANfaakBdBkHo9G+mqibh2jCbjZLa+tqqsqGPpPud931Fd6Ca8ORlf5sXranRo8aZqc3mQ0Vs/PaK+A
# DATA blrMyFlyZtf+pDOGK1adT1R2rnprK7Zf/Vs7ZvP2jKf8XHYhR+eVfnGc9+o6nW9XG/MpvALEQVPJST7tJIOb6A2qCO+L28v97ok6
# DATA 4+o/L27TLKkeD3vLw7z/7PhwNFkuYFLAI10+7PTAponPJmrSc/0EhqMOlZriMbmHXL9166KNO3qX4STvqMXEPIPjDmS7WZ6ORsuH
# DATA /WfEZpa1/wnmklZrBX1RDagPTpy5pTWye+OIAvNLdod+O2d/LLATLr1SZ0xLzmXn1f+BnGGgHbugdzVqMmYOwASW2Htbh24GECWp
# DATA otRtJYRubdzf29zeohg+9s91SLetBB2YbhIEjXkIfryKs/b6z+BDoU6AzqDXFKgV3PIxbCmgg4gsDI54SjhJUY4rQJBTHI5Scu5B
# DATA D6c9teGoo1A+nqDa4Sl4op723ksx0XE0cabTWSikZ2Lf9DZAYi3POul4DLKtQ5NtG+uFnhk4VJJ9KdcosnwMOmQ0f9qWGJ446avV
# DATA bjEvg5c/9CbErlxfutZKO5kEJy5tm1NyA1SDqki34U0cZQUr2MZGm2qbszrJ0A3r54YzoDX7/LmBuW/wDYC70aDiDfb28zI4ef/T
# DATA w1hFZkMmvy206aGujWeMWc/hBLEPqdRmLz3Yb65d16usJTlixkSljbRmhDrKe40sS83iwMgiwikDJ3d4NKX4UYLwwA9ofnN4gHxO
# DATA S+6uiKtralCHMHgeE7mUVVukbkXiQ5+/7xBYkrZtdYYkJ+CSJ6puqk6f0c6w6GgaUjtKezl6E4bs+inB1Mc6juI5830QaXDKjIZU
# DATA D2e5i/89wv+mfIkR7WfhFxVlOaMfsNGX/WFv9LIGMBL8t/G4X0cm0jOjVr2kiJ7uYARBcOhxr0Z1X/G2wxFKUqCLAUyWhE980p10
# DATA FFEvGuZ2crmVjy5YVXULrfjlVl2cBDVJW6Nk9BI83Un71AdHLrwPgw1U3RjJU0tfqQvF7/oADwoYlJWTUuBUeFOSGsknXWx+0FvI
# DATA Lm0sIkCEiT4ZP5t08CwllMKJx4QOBOAopgGQ6JCjk9C0oB2b6LRxDQneXLYbay4KJWSTScjRXIi4FxZtnwqUF6pXrQUIXtBDt26S
# DATA cCtkSllXFp4uOukY6U6HYs5ipSjnfgvBB87TOFmLLpRsVM3S5VrkOYI/126dUB80FZDQ2qxXYE9bgBc1fsQYrVTlOiwvRjv50Yyw
# DATA UxIur2+XvTqqJkeTDjoIazVl4+Q5qAbHYPltYVPkCoyQC0f9V620gXtxOQYx7iGfHvUs4inU7SGeQms0ZtK3mLfGp9d0kGbCKWFQ
# DATA KmwZCy+OmGmDU+cEjgoK9OJknuY7X14odMJeW0InpQVEXM5uaa+KCLyHxqBLKDXtsn7dN2PVQ9DQoCa78fK4r2TQVD1zETLUg9Kc
# DATA 2zTowN9bP6dtE7zmwECvCLqER74GOlYDwa49U2O4gtcDJYnl6tec8hiR/0fJ6mj1+vWq+XkyhFCg5MmHnyRivXS9MvSQGtKpYIUZ
# DATA VF0XGYhLF6Ju+OQfnjZ225u7Oxsf1fRXuq84GvmwZMD+d+EY32KcdMS/ap0wStkUimynDD1VQLFLiXf96SaPR2d6YQaMVXztupeb
# DATA t6yOmg6Cdv2v3LuY+qbodkD/iBOCwmC6v7r8bdD03TpfUdzqKbgSUF1ZJQWGGeeeYP6O2fCEZ4cclYoYIXV0UR4sAnEJqlFTZXYC
# DATA leTjvSTlfmZ+rq+aOtaE3g8MaDbW2epia17+NSRhWeAr9BGzkx4HsrPVirTzlrMv2haH6uOqMxFfJD+F08Gwc5Wn/ysYQeko4l5x
# DATA 3obgPfmO1lzm6GBjnsnvTNYCthRcigca8yD4FJ2MXuQOktNlORQjhTctMbiYqYKVnoE3jjBUqF/XvxZDBVJQnibfYvH/Pw5sBupw
# DATA JcMrzHqqO1Fbr2kVxf+XxqT9d8i+7gH3ugD7jk/SPKYqvLYUi0OwN0f7+NTn+Pepmacu0+fGXXb/GJeCTVA14JOd5aP15Q8bzZWD
# DATA 9zLN+GuWgda+06zbX9l3Mp+j+quCvZw7R+HkVHJcfydp6oCNgUbVxdED+kQihP3oSotpC9y5iYKA7QQ9Hama6wcaTaIOXrP4hXf6
# DATA Fx/NYT4YQbjWdKQ6MpoeY7gX6jhkiJmiuSDCxdcztZC66ipuAs8i5NdhHNdq+xHGdiBmBsWvfcgQa5kduNekFlUmnY6QFw5PU8OK
# DATA 1H8zgfKL3g3y4M5lvjgM5kU8Cjel9hzu7nFahgPQwa5fGeM143bGYXZWXCak8QXSyTzpKqy+ZKrmSh8udgh6osgbtjkX6OoVnJLm
# DATA 0oV75M3xUbp/pmbu/KJEiY3g5g6Clu4SY2dUcl5wIe1mXCgvmt7unrgVmWWWwAZ5Zzgbt8eYnJkQjLWDvnN24Z32snJSz1HQPimQ
# DATA OofFaDBT00tAOI0GexeQzmdaVDDtI82QuEf4VROmeXp8LpClumojYDJshJK6NoHYmyKndHgsMYDhAn4eVASsInZpy9bWGHjMm+cZ
# DATA Ut5ujaYfgodhJIQogIliADzk9w+3vluDdgyvn0OggylgIUvNgunnuYSDQhnLBOTbmcHTAXqziV1M2UPTKxY2VmNWJqfrRtzQsbG1
# DATA sDWMppNdovA6pxIzN9/b+zTL4s36VTgy1IPNHXdO45UQ7odXUS2QxpyaYLr0A6RSMLI1+ZSFK9drMMsuvK7IeeXixFaYjytMrXdW
# DATA EcybzirBqngdcg5scMAjfCCexQob4BxV21sPP/OzVNnfWx9ATimHPlWcGx9Iuyq51eQwpuvlwwvf4KlFzgL/GY5qWbX8Xbri4igk
# DATA 0Z2/6O6IYGUutiM8YifQ+I3kXSPfEge3nb0VoGi2cPP35U40cOxeD3ih8GrRwxgKdVueHi1/ywIs8+bqHvcHvQlvGt5/lZzFsmTJ
# DATA QUJxjLvAngO6GetLoPdOgcdnQu1jjIfi3w5SHPAOeIhAW8Fb6fbBjWQAfGp8gMvCBp1Z3VMTqS4Gp86yFpF1NYPRHBV71nCTmQaT
# DATA iF/IWaSv+Kp9NAIZWV/MC2bekTYnuYERwN/OYusSvnigBBkfyRy1FAwaWGJZIGyrixgVDPe3ZgUnb5DbLTRK1mIbDhzY4xuOz5RD
# DATA TNHdfYXw3XIdLrl2+8a3blo4GvgsEPd9WgadG3f6kwLTxRcxOHfhHMKgcHWNATZE34xwWzI8HFWxwE4UmE9k5SVHLMRD8LWvBOoH
# DATA kHIO4GIA6WcwlHM30Tf5T48OIcdQG4feBkeyFv7pHHEJDzfFLLoIEbfIrhCj8B2P1SPeFGiqJ9G/Bn9P2pCR0O5XtJeb51XNkqA/
# DATA UMNQO5E9notkeRm/poSyDBX0ktLPgKbc2X54qEUnGlYyDnalxU3KnEn2NvmSEC8dYwNtWvQmwhZ3sH+oRIKfwWZ1XVC1igJr0blt
# DATA DzKDojftdI/bjHssRoTqWVjzy8zvDlXHtVfOcLh3uF30kM/ixpZ0nzypD/YtiuZq/fb189TvdvW242Hrb7xFfwcLTsqVLuIyULUr
# DATA ZOhP1R/cKu0JFIkgGhgKY2S36lqjOE5Dac7o7BwSRzU4VI1FtSfDvomPDEAt9FJxB3RAaq8pdWCUnKUUc6NMVyJKoUOj6jIVlU6O
# DATA EOulWFUhI4N1J0gntXgHdYdqwOexejwmNxJ2wSz2m9cRP3A/9WLTDjvF8dMh++4ky/ns6RDR6RxaChuRqgEVHWJ4g3wCENl5N0nN
# DATA ZjVlYFxUAjQDWSQlL40lOrEASgG3mpapb/9WU2PLOhsCkbHQIgERZ6w85M9t1eoV0TIqBP/VhUCRUfRfcYDMeDbsTmcEU9E97kyK
# DATA Vnrnj358914tS73awMQyzYsx+Axiq6p6qMMrBa3kmOwAI6ucmyq4TNWwGMP04VDYTuKfeu7GATi8Ysl57pMuyqT6wFm2bzKe779B
# DATA LQZhmsHvf+/8XrR+6PBoAjJXB/ISwoDuQlolVGroZ6Ziio9g8F5+Vvg3zdJt4m0VPuiWxF1wp7EPIPE5Q6fUtWFQrPBLPCn8tyXd
# DATA 1G08VS11qvh9ncmXA7BgmzMuA/upH9KGfmabKdL+miaFs6OXbR3NhihSJue76S49Bdcsvwd+T9EiRyZ6pAT098XmC+QfSgaHEfzL
# DATA 8JtBO3Sf4d9luO4CCafeqSM2LS2KXplYVoPj6sQFsWmlQQ17OcyiGBFdmY776DAHb+/iW95cTReOFecDix3ADqRBkUoHPn0PbJHy
# DATA c3wnP4MiuO746b5Tow91SuVbyfUK5bgZs769ODVm8QrX9AJXMENYZ2I81Q7DHqvxMGBJmHHQQHUzcW5iOAmxB3C4QNKLKmQz2Ixx
# DATA VBwMSmbO2+icOnG7Rf1QzzES2WSUfzmBWZvgKmm+iAsTXObxxGgRXUp8nXGfPEGaX53wO51ArEuvbSuPCbfm1Dqlo9aKoFQoF/so
# DATA 12rBPppREIwRJkzjgO6MDEck9TAVh0HUcRxtSIhCwOvPog0BQDkL+kY49kOxNVIaL4q5EeAx9Oclemu9dFc6Q0CNw+goxLfAy7ru
# DATA UMq2k8foWqBTPOVegIxe2n23eICMLwV/cgtBwGYNDGyiPI3vhKOxGGfkgu+5SeivhWsGrJ6tcJ4lVSRrgnlOnDE4qjm5PA7AZI2a
# DATA olR3upDOSGF6iSrrSEHQVAZ65zlbWK+UBRUlw310EGVjiOV6w2ZJNmSSRFuJlwJgJ5VwI48QtHvHdmhE6GrpUrTOWqzStPL4I/co
# DATA Eczc7W76yMA/fJbFIcJu0om/IN35vc1b6RaQS2xyYCKfoIt30VUyiVa0LIW9jE+dS5kQuOMO2GqZbIDDxHDkbS9PvUjW2EJzHeF1
# DATA qEPmT0YvADbHaH4Jq0s84KBch89LiIg6OMXoi++YsC9broJTMBvsAfQVGG+WOYoXF6jf9tVoaPrTvHRTmLZhi1GfW4mET+Csm1xM
# DATA 2o4DcQinREtD3mBr8xwEs6xS1uLIQM5Lxb7e7DQidpQZjpYp4LsVnYG21xdIummowgpnSPuneAvpgYaItdTiHX9X6rHgcB0deyd2
# DATA JGae8DCNXSceX0Pmok3SNLRt/2tpif9TiadBOvcieZRewBthbm2ht4IT+5eV+/uCA41hSWbArWASYmiN3p4N1rUWuPqwL0fM06fM
# DATA ISnLFsJ99Pb4fc81SuxyzQpotlfwu8pNblTnNF6NvVj4dG/QGZbSPE0U64LWLUAwl3QkjJ9eUaiNA1GQGwqadAwrxsoHgi0bUyaj
# DATA cR91S4CO0wC9CWK91fCnhoFs9GRqMLBLKyEnqJXrki6WccdCCCI/XXa8ApfBK7AB0Mcp+X40XPRP6fSXcCeMj+o8lw7wfdMefOUe
# DATA JQzl4sO68J+1/tjmql1GXARCtVA/0PAzJm7SHwcuKDG1TZnvia0NZUzdD/CRgdiMKxDGDibrMfyJWgYqIRLpNiiYL5s3LbgKarRs
# DATA OzviZTnrj88bENO2FKYjd0g6Fq8nN1e/fVsO2XDmo9QgHj0dGpSjx6OCkY4wQl41lCwfVSMduf2ShDbEQ/EnTFG12x4uinbKAhI/
# DATA qYhCrH2niYGIP2ZIhSzxYVRsUIha9fMkZAATiTBy8+YNDl9MWGGaXJ10l7sdVYUarlfbsip+1aHcYJBTtPlFZ9Lv4GrU5oZQqm3C
# DATA XeV5OU/c/lTxrKPUIEBg8iq271Ja28qRqJUKu4+5f9t2L8Ep0vcl3u76pX/VcshHqtYl5VBsoE3Z2VodDUM6xbzfpJ2wyOYgUAig
# DATA EPOOk9PDVstbDicZmGzWPYT+JDjK9H7UQwjPl+TO2BGnojCIsmhAdLNiivtUCR6hMHtCRU8jDBacXk46E+Cj4IlM9AO5PfIFs8ea
# DATA sLN8NURxrCa5S7Hbh7mBok4vIMQeKXEBmiTeWGUoov6obagDG4f9gHwBg/N9BKgc8UJEihPuJzir3BN4n4mcsPBZVHD1RRSAnEt8
# DATA 4aTMEHecD8aOodJxdbAac917Ll92canRe9dCEkVwfDr8CiAcgRhA4WCXXa0GQVSdQfU1DS5awQVgEp3astjB4aUqmeYFb1vU2QXW
# DATA ONqm8GJxpNFSIW9p6d96yJdSSB2MuiYknBEoj7rD6YAMt+plm10NdfvwLA1dckxRkyUpdDo0Zdjz8P7OxvqedjTcefDJzjwnRFCT
# DATA 39ZqctfZ3XMatO3/vj0GXffNi7oOwpQBtrmeOelnhuvUOMIVlH6V9Bzmq73xqS1+Cg5C8Wh3CKAHG5QzbXElTpvc7rWLfeF6iOin
# DATA UdPfJeLzyiE+OIpEHxwRNVs0saU+BPIYIuNdUepaKor1uDIy8xp8KOUuddUwYQ80ZYriU5BNLWZfaVG2xghA4oW8bLSPZ5V7zaXt
# DATA NksV+m2hzZHaNWM+Wgpe+dfXi7hAXUDlymazrZF0KAvVrKGYcce65D/vK2IbetE5aCvtevXlHW79/hpn4aSVnSffR+eOBtnbD4Y2
# DATA CtXKZgiwU6lvB1nUjo0f122imsUNhP5m7fkGdJmKwvc2qNaNWLffGH+at3mqN1DFHqmayMq98JaTWD6R5ZMZ6UUZ6/d3Zcl8u2Fz
# DATA hQ3LCCn1wghMlyPP3BNUL5VF7w1rKaFRd6cDpMz9QqNQLSuBDpWL83GqhXAmQM/S9DIHVeq9wOm1AbrN5/lpUZMcMsYxSoMHI8Ps
# DATA qOaHy+peBQmf3MZtIIzqQW2erq7udSiap8nmcZmcoBptKZJ+iTEDS3LfyKxiDURZ1zf6Gv5qbGxtb2zt1RPza2/j0eO9z8yDjU83
# DATA d/eqEhqVk0o6AJ7ljRZQkXuKhDXOE4SCZVI26IReLgVl4DVA/9LRo5KF1w3aAenoiQHYky9hqyvQBdR8gZwdxOCj9O8Ak1RaAKh4
# DATA EIqPwqz3Ssq0c4BJSDKlufTTqmKtlArWZnv1EsEa/84X/dGsaEfczaOXHBmVjkrVeCkzOajQOzNQoXZRMNBdNl5mKBImJ/5Su19g
# DATA 3c4r6yyD61zShvVuQUDSRLuV0DdO7aBoCmQ1z4/GRduG5GIGM3VJazARhtPB6S7H6HZX5i1hHoHAoXUiuCXXk2goBlCog8CCgNW4
# DATA cd3lQGYL7FiBfTDC0JwzikHFWn00IRmvZIGCwv5pfz3K12PNgwGiiB+Z7ewhX1/g1xYHUnGq8COgI3OPm6rdhnlot91TVfKxs0oC
# DATA 3/uMzaRNY74rimM6P029y4SNvZlI8DP3vDXdYajX9qg0xRk5DzpJKjqjjLsM7wxL5kO9yS8rQhBuqnTMjQRyByzXW3PBboO7unuN
# DATA NVpxBH5sYIRRDG6It1xlwsaFpZNqy6sIw5dd9CVYOWma8jAiL0mj/KgMcNVXV6vh7yMlKR9gpfA4b8EjlG7RHVfyqcRKcvLCYQq4
# DATA SyWHw/deojGCjnWyo6EYQ4PGfcfjVxwEoQq0/iLl49hbpvOOehDwP11mr1T6DnhMWhduz+YHKpUwrqI/FY0YHKeDim4vc6OVRZCw
# DATA LI/JkydMGrda+bG6i/mfQmK3eOH+EJXYwQdVDQQKmbKBOhFIOtUblY3le8PMbBq9uGWWILyGI/enrNtEqPevX8cU4JyLW0gAZeE9
# DATA DlQRyJDN8rxl6Q5LM14ekUiX5baSsOIkGctgP/xSyEKuRBCghLALvxWpwyH5ffH2tIycd+LjvJ6YfOYUcrZAY3D1cU8XHzrXOz9c
# DATA XixEPqJuHxy/YPquUkc2T3syX4PyTrQoER2G3vkNR5YuEaFDT+zsLd3B3LljzKX91QMvXaDjpYwQk9gS8qRVU6FVAMe3jG4nPIUL
# DATA 7liPjFrcjsqbURyZ1bf5AHr4Uf8VhB6oHi/TogqojRcjgPgHtdwK2ionio0XSac7GRUWQXticcOD++zXcMfUzV74BnzpvsF8CEuX
# DATA Yyxb1NrlWLc83AyoqAwcWdqBGPYobgGK7CSSBOLOlPsUuA7Cpglhr8U2MPNGjUN8pItbowFEU9rLkDl0qE2R/Mk7D+bOWsoE0MQ+
# DATA 53jESeCF1A4+gTSJ5gW1qgzWNrd6fyTiao9BDg4dYn1ZJRlrLkJZtdfjpdPxycqq7XhilqCgxOEtR0P1briuM249HkxSgUkWLW8d
# DATA Ji9228Xn2ZwthwKut9EE+ncpndfuFwsS7ne3iUs1v/Zg+qtQOYj56GVlc1Pul7+A5rfk/NOt5l0f/HlqtxKNAInhwZ72AGQxNACL
# DATA GGXKQZYJdV35PFXsTRQ5yy5m3saSWUUCPmGqWCDrMyd6/sYf/vev+H/opQXn/CvK/Tw3//Pa6tr7a7e8/M+r19+/9Yf8z1/H//yk
# DATA zPp3Mb1YfuYuqFqKaLbm404BiZjNz+nJ4IJ5m+vJ49kkfwz4FyVpnPOuEqeKaOrmU/N4pq4XiizeX99bf7j9Ufvx+t7HWtSyCndr
# DATA kk3N2Wgr0aszGD0jH0JwFdN16JzF1zlhscxb/Gh9a/PDjd09m9gYHFXxFZhQH67T09v0CCPHdKrj2zfDtMiQDEHUjmbXza2PzDfq
# DATA vftCf3j7ZqRzptSDjcc4Dd9a2t1TPWpvrT9CR86GSWdCDHfpj7ef7GytP4wUWBa5r7gwXmoiVZFb4s7G/Y3Nx3umgK3psNN9Phtz
# DATA JdsPH7R39558AJg06d0rvRFuMtxA9+7Cf5NBZ/isdTUfXr13F9M7IhRKPm1dRYg89RSDvO5xDMPdFfp5d6yfwOXHerjeXRnfu7uC
# DATA 1UOEwuaDja29zQ83N3Yo/KU7Ohn3QVJAaCONa4SwRjffP3/6fbU1Pt74NFL2CDGxb9+kMnvb393YKi114zqV2vh0b2Nrd3N7axdB
# DATA LBrQK4xY6RYFZfSkf4oXz/Df6aspP0bBOG284vIv80N1VPtHSthKz9Xu7w46RZHsqsmmC7O9Oxu9dqFDpNohjJoPoTYXPq0aOo2V
# DATA k6Y36YMnjx9u3oeN+Me721vt72585thw4kBpLkga9x1mghAZm1HbntAXEX7a4ek0cANhoLoo/KIXvrUAHltbALLpjI4S+YkvNDDy
# DATA B7l4upN3ZxjuQOsU8eQI5nFz63vrDzcf4Cyquy1SVvxGTw+SOA9N0Av2t1mwMyf3AcToM+ag+rX2LVTXpE+fYtgTvqjo2JOt3fUP
# DATA N9rru7sbe0iC08zBNpaEXmaQgutXHOIYLu2EOXlFox1qZAIDegzwBLd8oKC5WaAPZEJoPOjfxnzQUGUU1ghewCScUchJo5GeU6Tb
# DATA ZCqAphrxlJJeN2rfaSpW++PxZPjjzuzVj4ezwY8VvdhfU9368WA8xT8yVehpo3Et+w73Cm7bjc3wSnbEvXChoDMThlfMjo76r9T2
# DATA fQnXJK3RsEQou8SKRjAj270R3jouvO+cZeW9dy+5fuvGAkfgwfaj9c2tWD4eQ8ywxsYE8r2PcX3UatFh7/eGHfVTn/1O0e331W+e
# DATA qDIIt4ucUN09eUYlRhrndKfhViUv5z2rtoRkTbfXzvUb3CWK1UmbS3noGEw2lLWkW6c8aKRZll104qM0GlS1AS6t44P1DgDP9SaH
# DATA O7CpqaF22rGTLLdsX1NIv93W/6MDoMN0PFPC0lSRTXgBdt8pib/wrH+oprJAjQWo21/dXF2dw7JxgnY/e/Rwc+u7rodoHJ+8Gkt8
# DATA TmNyUda37ivxenvHbbQ2KsiRElQeiJlHlpfyJqOOepXI61WI6ovM1ic7m+iXVTIEO28tMW/Cf7TAqMO3n03szNb2Xlt9uHFf9eOz
# DATA C3cEvSUuD+2+cA9VfU8eru/gdacUnb1NdieBgM0URFIaq4gOjrI5yBxzeU0e6IMsSP1qT25cCdw+6TzPLQK+BexHJLFbt8pPCxIq
# DATA W31ArbB2HJSo044sNjVuV2iAYpOgKatNY7UY3vTbc/CblDoo4XwJ45+b3zP0RFJn1S4ZHlvOjgr/QabQPuq1qEWqJ1xJHp+PyF++
# DATA AYSDD6W4bXkQ+5o8jsDTzVr+iCgGrz/Y3FpXBwdexmyCbYHkj81lAlNfSRx55ySCG2tC5KjEgsj6GrpVHDn7yI1/s8/nYeb7pxG1
# DATA Eg83H23uhSj53NsynPzO0TSfzB1dDE0f3attn/vDUd0bgvx9AqEO7SFBy9awVfOV+UUfmZ/mmwqRAMd//+P1rY82HoQA/SUxnM6Z
# DATA anqb2OThdczimoVdMSys6QYIulZaYUqMb2j8ZWi8b9Feqsw/wbRHb95Qio7dLSBnHApf+2tND2dSY+7bNuDagpWbAx+LCy2NgHTu
# DATA 63IU2FJM4KqMP9XqgUvy/zJo+IuIALTEtnMXDgcNaE4k5/Q7ofcVWUtEu9n8SJYS+nwxm+Xc7RFaJuURdudbvHGOAzEpOmeBa0iU
# DATA bfGagG5Ia5JrMaXUuHMKZYBbEeCWUFQ7caCBBro67csit1GibFzno83d3c2tj8I7qdNdhr1q6X77CjKLv/F0QrjdLhaKyUqsmwVd
# DATA FfwOWBw2JEEPdAJf1g5wARfKm5L34QsEPOGnwP/mcDl9f3Xm5IH6V2Jrq+KTzgBTjEIb+wLi1yCAM5oOIGqghRbMKuQqWuPv+Vym
# DATA +YvOIM0qgDdtNY3DUe+0jlXdH+FrguLEVCBesYabGkRx23cwdOBvPBYeRRu677ft5VkcT2rwIYF80mfvoC+TzkvMcv9qajQ2Uj0b
# DATA V7Lung6nnVdR3ariw2oaL65mjfQxos9BdU7nZcZ4A84RXvRsSsGLhS5SdUPFJQo10kdjpg88FfmUhasrYFsousf5SUf7fxekssTd
# DATA BIX29fsDP8OM+9Y7WAvNlBahRi8LVrLvcx8OSkYCRQX8rKOShneokXYsbJfsUsTMoerHO6JqxgVlCfvoTbZ6wnPd72GMFpihyE/f
# DATA hAgg2h4EouL8B1wrbGMfKjtw1aTWZCVVg7osFjO/rF4v1p5WMnptgunFy/rBTxukPDW4vvo5bPaTzqv+yeykDKhfovJ7gPw84VyT
# DATA MTbpCkH7VjPTuaZkG0AvdGf1xu3V7CDLLkFsZPwuY/nh7NEyVcEkc4C32QTw+obepxRurDeqtftepIf4gRNfPOghYhtsNzfsmOQV
# DATA EYFEeDXRGCSyCrmwfXqE6mGjq+QvaAri74a6UR6fGD43ZjdK+vTV6iqqZXU/eJfwT594Z3MQWS4+QRqb7+yMtNLn5053tGCPoxSW
# DATA GjS7ZovK9FR1WxGe+xsfbz98sLHTBnDNjU/3vJ7QzEGESc2bV1eVmSKGPvVCG2VoK8Kk3ly9GX8VpR5naedwNJsaSzL+WhENnDf6
# DATA mAAkR0M+b9OF9HM7G//uibpcPlCS6kcbu1Z8dPBXCt6dXlg+eMINwYsRdEAoL5uwTbN93Sf6PjL0jIW4bbWyjnTgtk64STfShUYD
# DATA 4rZat4cPN8H0FZqfDQU9IIJQat7wZH2dR+9MkbCmoWqaqJEPYAV/yM4lF/JuEyToqfN8YNVh6M9IzAitboEFHyasqY+AldbFEamj
# DATA s4XGNKRq6skPZ6Mp+/NmhjQEh8ZGYecCW6+CLrGrpSSxmkpxxg3eK8YGOJ9suG7xbMbSc0X8eXZSVWH195eQ43Y2toAuSDEutndo
# DATA +dD7yMy7mgu1RFOtsKXHIP+xVZWXWcpU3jYx2OlckyYcrkwTMbp8d2v7ky2irFqycjsv9luxr6s/MFvPGPxOh12pCBO6rlZE17WY
# DATA jqJafUX77CL6sKjeOaq5QEUSDCmmcIjGBFcpbWQ4LonsgdLmAtrsT3bkYJ2wlo1P7z/8ytXcrPqBcJgSZTcrf2nYeCHxXx0NZsWx
# DATA kGfMfAd6Y55COr89x8GAd2hNBAuwh0E+LBQHaaNRv8WA/UCF2gALw5m2ilztgo5apqJVS+tAlJtpphPCZMGtk/uhPjjpd3k6ZGdK
# DATA Vg5OzGjSwRzSuGuFG6JwtMOpWgboVPBlbMB/birif5xzXiHeQqa2uj8jEfVtheZt8eM3R03Ia6dZjOhfmG41Hq4e+5qPtjjlxaTb
# DATA ds6uOkjFtF1ynC01ashXwbllgkltlhj6OBjflDM7gV9Elf/OhL87+5sBuqu0u4mO8ezF1ZbqpMHdz2Tx5JhPGgWFSwaZhOFxeSZh
# DATA Y7uY5F117xMY6dPRFHVqFKQJgJqcXosbUjc5kT+L3zfdW9AEAsvHSCa5QGM8Gtcyb8Prsm5YksNGHBvLHE4VrCDVX3pgSnkWffeV
# DATA ci3OvEyN6qzNojOQaVf88pNt8MjCoUczOi+W99nL/8wbw6R/9pydQfmES3wvCX2Zm6W+TXGBbG9nIzRn+mcKsNBx2MkKjQQXKD4E
# DATA sjFRKUqNHs0KHQ+bypXc1H+Razagf7enoxrjQUJYl9p7taxsAqsdXXAx38b/p8xqEwcfsQPDFTVJJ1Ibmls3o87Kv9dHWX/PUhLu
# DATA AjAxx78shz5ZwOZUYhAUgLGeq/0y0a9mpXPdJTehpY7vtZyulJbu9Z/lBVBqjr9oFMed67du18rr/yqcIaKwM2/hIBH73wWcJkrW
# DATA 9h06Ulxxlwf9FvSD/nCER9DxY5BfqJ9Zc65v5iJuCeXn0CatdHte+RkxXPPx/D4ecqi9dAg5UXdUSEJ/u25ryua7ovL6YI3NhTK9
# DATA vs0E2aPTmI3BraqGDc//yM7sMul5F/iOlFRmgta+4sVfzP2mpKNfu/fNuxx9wH4QZ85ynnA4vAfU1Yr+qskA3ujVvlRsuoCjAkvI
# DATA Hsk2lzitImPxKMtk/4yOBdFiXCWL8ZeW4JSOF3UM+MMT1x1zo/S3C6PdMlc5hHlHVK+4b3TX5+7G3pl+1y5pyXzeH5ImlTVRqExF
# DATA VZS1s8FrdbcJ7W2Xs33ax9g4PvThyhB/IJay3Bvivu34IhY+/5MgvMRoCLEgT8QBzpr7KGLMoQKskLVzHwzB2LecDyJ2rtI2cDW8
# DATA 8X688Wk4UCy3UAgC+abvWXWl1TyzfNQfJk6HQ8NYzCgWsbFjdZWdxxIXMkTKni/gaAgMR5EHJRUPRqcAWxbTGtq36i5j4jQdCRgz
# DATA xEww7DKygZdfrOkETq4iSeovqYrAL2kDyY8XwxDGRXjuvDkkyMP6cMvS3xe1CMJQ0yC04nE+QQBF9v8oAUmOs50Pnux+Fvp5OLd6
# DATA KdtKRKEqoTqio4vNkNRGDKdpBEySop5PihfdyTR4S48xIFfJLE5mCn71UO2MDx5COo+1RTR0AUSVc7VYJAmGmhfxe+uDYLGqkawv
# DATA skiXz7TRVn1B6OnaID+CeLv+s+Opy2iL06IBlFjRmhMnVY9isLNXaRZPAk0AVf1D1gJTQH3j/oOHDzlPwazI2xhYL6B0jmZDRv8w
# DATA W4qrIMxHtUE60+tqW2FQle6k+aoyK7XTQKMzeYY9wmT31LduG2EczS9w2GiPxYM5r2fq/YHbCmDCQIx3y6kk1I/C3OP9EP5oa12v
# DATA fktrAq/xr3ZEiapbrDkVoGDMKn14QRkM6041bil8o4tdp1TXpTmGGey6J8anVo0W1RrnsAAEkRrE9d3Pdg3cOtI082v78db23u6T
# DATA x4/PK9aQDgYfnloXXVRB86f4qHliTSgIn09OjaBgKabqcMBMOdpr/d7uRM1cTHlPLSzexDTDcX+KDVCvrO9tbm+RrmVX5K9d+JBF
# DATA zsjcw1V6euaeoOho1ve2H23eb2sDsOK37Sdb699b33wILuDSj+drOW6LHrng2NGyk2IG/wyOntwwUEz8bpcYjsxR9KqUx4wdefmc
# DATA hZW6peVe40/WfFhUGzxZdRzDVZ17jAzAUymDRlsWCpWxY7YUstjL7Scyb/HMSaOAdxrZnnRFuzI3/HVqaxO394khGYTagUh5Qrx0
# DATA DZ/G7YQIhQjvj0IRkqnBVqZ7uZKk1FqRwt9GKIXrnENvdHstUQn6P9JzEPv9ygs2LOjS1uOD3y8YLPzB+v3vPnmMgKdVwc+UfSYQ
# DATA 1uMqgBGAL4KlTpE78BZDhynxbWCJjqoGJp2X+ppdckdwbgcWEcZz9ai6+YfI/CLXr02XYeD6rcNSN1eSlrOBOpPuMdgFmmX6By6g
# DATA +ioxZSo0Eu9Ap2A7aFQIdcam+7p1CYyXE6gU+FJvO4o1hDuuDBGjGozBvdbyIXYcpfblRT1UR+gJwSk7CHLF1qLaAS49Xz3ABbNs
# DATA cQ0BndhUSjJ2Z9lT4FySKfTA34aycMnhiJbOIokszIb1aAF4+svTjeSu8zIknyi2WCUPT8w8qYvJl6tUDZsQ/MFT4dl4hJjmgkIi
# DATA J+BWkzuHXXCRejIdPc+VCDka9OrJMH/JuIp1ZlESI0KvQ4y0LdmsAyVdp+hj0bQj5gkWYZGIe/kLmFPxjftyoVspzTHqwz7b3dt4
# DATA JGRAvT2cJtRmqQmcLHABwikSbg1egDdXg5Hmq6tuNE7ZSgo1TnxLmyCTaEmXBhuttSGizWRN09FmJT2rB8KXJGbNCCXTlLiJWyb8
# DATA nPZ+M3mboySzm5BMpPmT3mfkLOPw0PTly5cUdgabUJGt+E6FAurFxWKPmSF684v7Qv3NR4jlJc7VAmKD3O2QO2LQ42lT8lT+Uv0N
# DATA B86ZQiiz+w5m0KtVLwqf7ZQONzzAP85l3JTZTcibteuth7F3Lbk+bwbNF9Larv31nJWTgHfkkBmFECKZ6Kg/7BfHZfTM0YPyDUJ4
# DATA ueaHsPl96Qt3jsyo+Cwo4jgHYokYZRAZoxahKEHTUe2jS1GRb9Pu59FkTtIDeqU7gmoSVUMkDJiT91G5up4aX/+4WAdakLztpXiD
# DATA M1TRuFHtcRV1mvUsEq1MNyKX0ciIQ17kut1/QYLBoojmmJm3laiaH6gTMkRfudI9K1WSXDw0/+kXl7YAcgX1kuP49mI3kTOXjjHV
# DATA YoJVF/TJSOKWnLw7mXwBsx121hNSEfExtGJR0Swuu4vBHmhkerkLYpJ7eImOSdMLCvRxDDlfwodVOKgn5gctQkTkj84WLN4CAj0W
# DATA K71E0CIvfIvg4qbVaKyUB61mqaTE6Uz1uHWdF7lx7O2sb+2u39+zEUYa+DxmELeXGpRKS29P7tWBKyLV5yJ8w92YSxcRRiOfCrZj
# DATA RUTLWeZyvfzVWImyGNUo9kGQf9pZdMZmp4snnBtdyVuuS3sR9ci8i0h3NkEdVuutZCi2E73Q3AnadPhenX/b5c+0YRKyPUF540+C
# DATA SRPi0xlcQ3X3zX3Snneb2maAm8XOO77BmWnpDsxV+9O8uqIuJYMURGepShCp0iXJ3eGIARdQEXBdPTP3RrIxCtZS4iT0wJP+Mwzg
# DATA co+W++mSaxQPx0W1ZNWb/oK3fXvGnuWOHKeXF2adklnxRETtIOZGxCOVt6F4Hy/RTys2uq3UE/8A+KJ0/JjAfcMbJX/g7erysdtt
# DATA GbleY1dtoxEZF+XbiDAqeuoDwZWKo4Gpnto3dbob9wKdFBSoHp6HClpUjx4ZHDPOu9xucyZeLFGFhuciQ4kMQJJA7OBiXIVtM/e3
# DATA v7ex8xmEgX/4cPP+XppV0S0z3PnHKxxWuJLh4pCts4RkmdNu+oSZjvjjudSycsBfJ2/kAlcMw3FT+pZzsYVwTiO8aX46Ph0FZmWJ
# DATA yiPK2ghbmtWfWanwI411OL9+S7oHfF2TFkJ/KfjSd8Z3EFYaafYZ27tWv5Okz/JhPsEtqT7U58TT+xhPxaYR2Izv4hxh5FzfktUl
# DATA edrvDChCWp9Wxw2HH5bHoRmXjHjU10Vik43O4SLhybqD7yjWy1HT6BiLi4d3kfnDMAgO8weXq1jg1lF/gkEmQ0jExCV8fwlt58ei
# DATA 5Wl/vUXxv7SIiBIUA66NYdPV3teBg4wXukXNLRq6FQsfeUvA5RAq9x7ZBJ3IkivkbquzZGQLDjTQ5jkLDtKTmN8gMIr1W4YsVlQV
# DATA CwlbrEeOobmsY87YUamnfwXKONPbegiOl73tCGLhwovEAVT5GAKQWj55EfPldSH4tM7AZ6qubXGpZDJYSZmFFYoQXWYG8GYGmeBT
# DATA 0znQsZGMCgYEjp8XgX3EOCLWkHfHDnyGw88M55Isg7OeMqaGuEH5+BqtdKKI5ugE40Mw5lyDA4iLmjRBViJxQPQ4KBy5KkObDkej
# DATA QcQVXnfCqsXMI/ICoK6ZG3c0IMAghSysjwIIn41dAyxn18xx2HEMbvZsWFVOxMWcL2O29KKqaxv+HWiv1azEFNdOCDpNt41z4drg
# DATA ty8ZmEJVUoUkTNHziaXkVb5V7hkV2IYIIxF6LEQ55yayJOzVfqski5S5/+sAqBc5q38WMVaZTunv/MuKmOQo9V6AZBDCRkAxzN0r
# DATA Gs4lyYXpnRsw49IEUUg8P5BkQhThZwfnfqyH3FCX3kCLbaILqR0jfCB2zYiMIq5CLRebF+88aesi+5ekLJoieAvK4TOngbLQt/0D
# DATA 16WtvthXJtKvQnio+5+bN074X2kHKrdK7J4Pzxh5yZmMy0x1BdAToW2P+l1yI+731If9o34+QVOO+MkIULr7tfmbxOJtgmQKT0R1
# DATA rVbIxzOryCzygdbr1xbk9x69If7PSf8aNMQaj5QgyQzLbAmWiV/pN87NXfcoCod1YUgsCRjp4GLpdgQulo3tf56DBOHj+gT2/wiH
# DATA rfQC8GVY302IlUReOoqLAkdOOxN1xcF4b+jmShLAYzDnooINH6NEghdhCdOw79dqQbFu3nT7ywAdFknujMd2TWL8MISgIquUsvtZ
# DATA 3pg8G4wOa+m1NMvO64DF1xp0Tg57HSzW9DOJ1XWWEIoUiGlifYSUYc5qr9BZp8IZyolfbZpNaiNZm1pyjYc9c0RjUwP9eUSuDHrT
# DATA UbbN3wfnZa2zO5b0vHAIpePUY2aoxLNnEdVc1LPHMUMYLc2ViAfIoqHlUtd9UTfGtmOfFI+CbIJSemKq10uFlBjlLUjgUr7nRIWt
# DATA iF9dmfBVtvkc2SoyJitV6ZmSQpVGN8TU3+FVjArWjeKwbVsrvX1FwdLDr8u9DCLFF743fbSxtbGzLszFX+nV6bK3C2vFFz2iUpkX
# DATA N8FFRVSIbFSDPi/oH6ErwyCcC0VPpItebMCzqPQemTlXxqpycf+nKsAe4yfQfryx9cDFu7XWjBIZ+CKKm9BwEdmwOL4FfSK4poXG
# DATA afd3hBSyOZrEnHKLe8wRkebF8wtxxmsKa4Mg8G39DLxlqUU9sLeydTM96rW9dYl66vO1mBqf74Vj45FkE/4iua/laukx+5cDr8dO
# DATA e3OlSRuNtSgL401j7Yx1rw/GN9859NV8jb5/S6WAqxDwptG5WHiTVuKWjHU6XM4OWaoMEAw6YG2o/1Mi7As3j6WSFyfoCEV51hvr
# DATA k2czmOzH+KYmgJ5b6SYx8ORwNuwpNp4o8tcZJEBkNbsokDCOZtME5w30WpATAfpcNExCXagZMMbbHW6sli4vS9w10Eu2Hhs1QdkX
# DATA JG1WlhE4K2oSOmpmjBK18juaveUJOXUu1h+WgIC9dGnCSJiYqo1T3RrM0SU+422zcAc1eV4Wm0jzYQRY4+/wH/iywA2TRdNUw+sG
# DATA dDw4/3SAwys/ulLgZ9zxwCkHXzpZHK25X72JsRe/jBZD9W9WgVfa3XjYFC1r51WN5Ycz1ZkiEbsTiWJ0Kutm75utAL3w9mkwT47I
# DATA 6U5A3Zmteukk8JuoqjS04s+fZztni82XPzn8fcdOYS+ZDdXdDGYStgxUPSsUVS2ZE8ciEp0TbRrBH9Y0IbdA1ayMJ311JATwMjW9
# DATA CPJyFrCO1XlmrAguSNCBsxRLMFPBv+HSH/ZHycVwz20BzkAxVdf5SdChNUXyzXE1CWdA1WaTrAjIfnNSD5biVlSnCgDyh4srog+1
# DATA 26jIardhNdpt9kKArin5dlpDnqMm7BsX/x9wFVx/rTtsjE+/8Y7/t6r+d/vmTfxX/c/59/ra2o2bN97Xz+j52tr779/6RrL6ja/h
# DATA fzPAjlDNf+Nf5//83GtnV0k9dbW5Vr+KosbV5v7Z1X7vavMqCnZTRR/UUblav4pZKtTj13/75idv/uL1F2/+7PUvX//qzZ+9+emb
# DATA n7z+efL6i+T179Rfv33zp+qZevL6S/jr9eevf6s+FgIPVPF/qtf/9PrvVeGflHxVT9S/f6Fa+M2bv1ZFXv8aXqlGVVFV5a+gNfV/
# DATA v1JPf/3mZ6obP1X//o36kGpUxX/75q/Uy1+8/qKhmkcV1tXm2VWdQ0V14u6V3ghhIDDpxb2nT4d34Y9koCSs1tOnV/Oh+s+9u8d5
# DATA p3fv7kk+7WCGoiKfwkvUnuF7fAOHFh6/6OcvARZJ/ak1aPD4Zb83PW71lFTZzZfxR11bApYLJezlrTVb1/F0Ol4G+v4CPr1PtSzv
# DATA Qt6y/vR0+fFo0O+eeg2wELZcTLrJ07TIB0dP0zsJTbn/cHo6yL1n/ZNnzhN0lWveSUaHP1DLz6+GimlB4cNOkS+rvohHAMqyTGKW
# DATA fRrOjtgEXv/Xkxf9YoZS7zQ/HI2eJ5iuRkm5z47hTnKsGMnxaNArkBVOj5Vk3FFsMSlOQHCmywQkVE5A262eK7Z0kuSdAswT0xEw
# DATA xUayO531TvHb0aTXHwLsEiPJKoEOROoTAITEXuNWv/cYVNsg3hyB90jy4+Tfzfr5NHkxGijR7+4KFbqL/jqTfADD6HdpZKq7R/B7
# DATA pVOo/VKswPNG8eIZvEOZEsqeqOpX1MP3Xp0MsFVZE65ScZzn01h9sASNblFc8DO08+nPaCkAQj8o8gMoAYJ9Prl3d4UKqj/wJMAx
# DATA gXR/uEVQCQSfS1KBtavDMlBVYp+e98eyN98E9gWFdtULWB3eB3dXOnTaoFXx/SFcLJzhWNMeVOOuiqpj2HmhZJR+Z3nQOaRpeQRy
# DATA k3rcf9bhzQctlNS3/SKfwDnGukSpQu2ffl6YcrvjDhzghJ/7xWELmrI7sB9fjibPcW2w6IrqD08qDJhEwx58qufnLqdmslMxBlsP
# DATA fEGUae3e3nFHLeEYZGIT0Ka2uPpbyWrDhqp+7d7dsSqWJ/CtOh6nyXHnhfpj9AK0u5D57xgPAKRyxNewGihmwk4dNRL1rbo2ozuc
# DATA ksTVaZvCETsdzWDp4GOtqNJHV7U6vne3139h+02kofB3xuFsOvUOjLsUHyghUzdzmKt7L+Dt8kR7tYB5cDTsqVPt1LfIoq2ovsI+
# DATA p9mOTDs/oEm/fm97koz7qmOzsZokRVqOZmpSRqMBTPd1mO77nUF3hubIo8EIpf+8Q/7dCVL7pDfpvASKA359MMNqvczmSHqjnJay
# DATA l08BrVDdIJTsOoOzpToOdl8ErkEgo+5Iieh9UILTrF9k/5nxrsCGu3f3SInysBPH7olSu0tOBWh96ZYA9drcUao+VfCeXnunKzYR
# DATA GXyzjpT9jzon4zsgr7/odE+hQ8n/+0/JhfpPq6Z7vQJECc4T83LF9G2zf+D2f+D287g9bctLMPl3zOMvx+Lnc/j/gRj8O+bvC7H3
# DATA i3H3r4W5046UwzcM/V/OCUKCP593Kko/KnLNQdc12yR1nmoRubvmn3LIINd07DBHRxwAqcauthWqVXiJeAq6/QkyX1TgeROB04Mi
# DATA jWbBBarTBnlnglD+J4ppq501qCMDVoPon+S95HDWH0xhBEAfCxqy6umTAj5BaUv3T48AWrAcvavlgcIXCEgcGA0Hp41kc6pluC7k
# DATA +QaODxOn2BZqmq1ZW4sCnR5wGFQvYhdhUZZRLICzXhSIY5Ts5vnz5Idqr4CzljYuHOeDMeqqoJNJ5+gIVgkEks5RPj01I/xsNJtY
# DATA Hs1DU5JOkUxmQyNqHoKzUz5pJBucaAimFMYxG4O0AnKm3oWwxwuUYVQBSKEwAiFJkYcCynQGp9N+F6UbNbZ8MgUb/zM1hA74X2jX
# DATA Nqire5x3n6PKE007qPZ0OvPff/K/FTxW0PKiX1DRHY1VPShPijVrJPdh/RO0yyPihRrYKYyc64IvoKsv/j/23rXJkePM7/0q5dBq
# DATA 2S0CGFTh3s0ZeXiT6CUpmkOJ4RD1ogAUGqUBUGAV0D2t2YnQZXdlhzaOHD4RZyMcYTsccc57SivaNCVREfYX6P4K+0nO83+ezKys
# DATA wqXRPd09t5RINlCoysp7Pvlk5v+HV0RTKqmRDpQ9rtTWw5j6oklUYTsQFBMYypK3szzm1CYWXNj0DN1hcsTjgwGqYs3vvZ2czMTM
# DATA Q0bKzrIB1RjsWCtFTeqp3JLBCKeoUitHDzeIpKKPk0yKFnsKUzbxH0bRPG/U4WAA23+SoDEMBnz9CAHFUEiE8BJnJo0eCCereR8m
# DATA fN+SS41uj1IuMuSlaVEIdI4IjyPdSVD1+QC9TbyQJFDQdnOhHFtS5eZqrlqrbpXRIzIWkcQTCsxkxYgnL4WCfI9ibDYuZRD3wG68
# DATA oXQwHo6XUAmlsT5XOgwRxZr3Jjof2XuAIkkxLkbUt6jqSu/B+S3+TaqUsvavPM3ZbbDZaYazo5l8a8b+VWz9azD1i0YT2fvfedxP
# DATA HpH58jPga/pcS6t05QkeekwWTzKZVPsRzYXjJD3IphT0+AnCfTwNU6oNB/VDrHAcpXD9HByH6V61Og/nUbp/OEgm9IhcIrts/xD9
# DATA 14HfmT+649faLU9+QVj7h9hlTl3+SfUkDecHfaqBD6uUtuGT8LEEE8+ogcSLQ2j7V5fYOkq2XlRNRiNK0EEtCKLpk/BgjHAe8z1D
# DATA sEC4kVSp8g8ezqjtHgTzR0+kklTi2Xy5qMj+rQqewFjzmKOo3qXvrMnfx8M4o2H4lH7mV48m0aNDGi2OZlXe8ncwiICJPvwptc54
# DATA dFpV7UtfpvkpGS0YVw+azfmjw7kYBweUE9Rnen7Nx99DKYEDf/7Iy2hKM/Ss/FvJaHQes0Uxpym9+rIqzTQcxstM/SxfKhQDKY/q
# DATA icSp3aof0lQqo3DmCfOuD0vZeIAJjMqTmmliOnfyK4+taFI3Nctkx9RKdVBB/ZgtVOzlzqLhXSw6/+TxSkI5+XYAUsVUEAdUMhhV
# DATA ho+TeTig2eBBrdXSqVFzQKocIzIQsirZgzFGIPVo8SJXitI1qSKli7rClO9dTqlZnBavPqamjRpz0CgVKt9FdV9+1nWZiuaJxIP6
# DATA 670f8xSJh3FqlT/Zty6iKJOf7K/UYZ5JH/j1+rcLla5NlW5D7cLr93dvx3nVRc2tdayKqytbQyeiFP+KdVHir6IbUNM8VFHlz1KJ
# DATA q6udCDW7ajZO6ctB/UkhOLLVf/JYR67+xGSIlQt+t05hU2WLfxYdsOVEw9QTnh+Z9n2UxsPDI+qGag1OWaGZ1Otyd42TZJ7Z1Blw
# DATA MB2EUm7/dqhNCnUE6gKV/+OtZaRT59eClg5VMpDiFR3RKP7YDrhTr5tH6l6tSY88GfuVcVAZNypz1YVXF8mcHh/70vvJ6zC/gpks
# DATA AVVAWsZ4N53vBbUmXl1p11rHJ5VWDV/2qUevN1VMVZ7sH07IEqIqAbcrIiC/UpfAZI1KtVZvtOjRw2n4SKXBbw/GhypS/YTa55QS
# DATA 2uBIB7tFzpfutNKgqAWc8Yia370gahSXoIXsLL6b39yQN9NLPJXrFGKjHGDxSW4ZT5DBOmntzmD8JJ4eVbLjI1NrmIR2aLVXVUHC
# DATA 5SJ5InPiCu8zkBFdNRXg4vygThW5ggnTHp70ql4bfbqJiAxSdkgX1tXywMXuchr7FydRNOOa7Ndapars11umWzHZtq7mPqmx90Ly
# DATA siN52ZS8DFbzUudaUKcKsXYcorlEMUHcL7D1gP9IwwvU0Mp/n7A75MJcKLfTTW/3Qhm5lFf/Lkzgn5RNjwNjqRyWmuWTGrxBjyGe
# DATA wDeO4kfR8PBnVfbBULoP0SirPkr5EMQNymlk9IYu2nQLSCeHLEPQY4SCJ5/UyKRJdOdYFWZgG2VX7PXoP2bPGvre5XSWHfij1KN/
# DATA N/Vv3EA5fK9GlgO9htPKXaw2a/IibbaoIcjdo/homUbGkMyvDkL2hlrh1LpBmrdPpKrW5deqqcTFdaFbet6XNlpTBn8pa1r1vFrz
# DATA 3evrtHqYO6RiFHZuTHamUve90v217FjyizzqDIt3Udah5B7vUJZpNKdZ4V6jQvWcCmWvXqGSpW4jj9GT2iBMh4+tkcUaddo81Jdr
# DATA YbZMRzjCfYF9sd0clfd68wPM/quDcTwZriaTb6nBfV6pTZc0KX1sGwh8hQLC73bl6UkenmBbvm0N9Na2qfXmc4s62Sb926B/2zCt
# DATA SuXE9bNQAOyzKzaXDYa6GWAQSKk3lDQfzBZjyZO9YLbv6bRsKolg1Wp7UjN+03Jdp26AkoVOwtziKWtAMtAM/BhaMerjA0KEr9Ia
# DATA 5DpdtG2+6tmDX6eO65SeeLFLHaXMVD2O7l4KrYShNk9q8C0Yay+4yXqJN/FizqqJqMeWmphvl2iBwdoWyGHJZsDHhc5KzD27n/dU
# DATA ndtSB1TKePxorptRWm2hId3RyZgPS6K3OqBJGfeiOkYHlJTFqUkjj4Q12bZesLFrLW01q+YXSLeifZFrLO2mnbr6Ie6q8gKOekvu
# DATA x5zEj3cwN0pzFOo5aN4UD6LHdpaU52O6OermIeNuTQqFppdHlhFlol7fYZiQZ70Q0w2aD+5QSQp1wzPfAnyDTbfaIOwxpdhfe/Xd
# DATA DLRiLL25NTCrnzIa3GdHj0t+A2og4VHZOyKm7Za6aQookElkWqwz3fbqpHJD0+yHJdtWt6SVsbVkF5S7cDEIVJCeTArxyIFvzbP8
# DATA JveU0hTyjC47b4ZhNo6KGfzjcTwcRrOfFBrQvxI8YDhbPKHm9tj4wR6x6W7PjTA/yN/XvKDp21nZ3dSwS263cHZ6Ajf0E6yNSCmP
# DATA wmk8OT14i0yshMblymevvR/39d73D5JZ8tlrlSn94XCLbZ7yckjjcDzJrGwKdq+PypfyuOSVKjutSva6fqdXmN1yE1aTqIua62Fx
# DATA dOQYB2rik4fYsIf7dUbnDgZgucp381harc+qAy2Mr+qGgluDZyq7+Sepx8691aWZ6IbqUJvHk0k1TU4utrKVTb2I5qbUdTfazH9C
# DATA J27af1N10Au48Di8cit4wj/pgqMuchLOM7JK1Ad7Am3XQB6YF+PKYijTMs6LA8SmMI7uVBkX22ytJzWKQfSYe3LpwA/8O1Wfx0bL
# DATA R2QZDWIzJMvFfLngEwnlzJI5Fe/Sr2LZZo01i+Np4SJJH+thd50tKzVad3SmQj/519NoGId7lonWpm5t//FGp4PtaWi00fcqr0Kx
# DATA tSibZHV04soipygw3ZVssusMz083zj9LjbKBmaudlcX5pHG6tLiv5rnRpYwxbaxujo/98vVTyAYWG4ozxB2zZcVg2DwtD0bax9iy
# DATA rBT94D17LmVXz6BkPmszdrVeNBtcLzgPK9rK3RgfdsuI64VH9V5eOIUJRSBuOjXVLA4Pu6d+5+RyJ7Jm/sMdOVUlk+45L2lm1TQa
# DATA LgfRsDpNuFjkK7WOdWtiHPh3Kt85kE0f9CEcod2Es3iau4zycf6QF0XiNb/oaMjpHN0WpRlW9GJU2eEh9jGXpjI/LJevrNRZvQJb
# DATA AWpu2Kf56UMz2yjf9ORJYcVQ79rCDkH64z2aTma89ol9eQd37pycnNROGrUkPboT1Ov1O2qDFzYQvZk8wo11r+61m/QPL/uixnuy
# DATA AZC+80VPOrL8e8rP+QE+j2gI4j1TjXpj2Oxh4+O9N1iuhHcLfeC3Pb83bgTH3e8HzWO/Pqb/dr/vt39WeHgUjBqjhjyMKBZXRTMa
# DATA IaOnT2SXJvI0mecUJBO1v41vzDdjUcXtn+IX3jeX765Tm5/MVXvR+SDf0WP2AERDXgs/NRvwrCzp1b1ms+U1ek0vaNUnjXrg+d1G
# DATA tVHveH6zUcyYYXvYj+qrudppeI1u40d+pz0JAr/aa3mBT4/Xu8f0930E3aoHxaCi0cjnPObpwkNO/7earVa9FeUXq6boGysvRahd
# DATA /7gZ+NN6NfCbeGW11+PIqIh4vtSKK74hCOpe0PSP/aAx8X3fa3V/FPS6P/ug2eh5DZ+qT9Cd+PVOtdn5UdDuFpPXHfSiMFwJstOi
# DATA XOmN/aA+rbbr9M8xPjbpcqPZHfs+XW616J9j+liKeb/drzdH62Le3FhT1fZFqqgHOFn4WHmCD1QNP+T5/YFqLId6anvwrXar3W/g
# DATA gvE+0SP8v0Nj0KxeCQ6+FflRK+ocKh/bwbdavXan0zoUC+PgW/3RoDvAE+x2pp+H7UYwPJTl/YPPXnsQHSWR98P3aLrwSTgm27Ny
# DATA n7ePZdQVVrMojfGs7tJ2uh3dUw27Lclkyrv0A7EmvaDodO6KIWBuN6ORmt98L6I2HYcVCbq0NHdYdoTBOKt0as3jk0pHHGEcsNop
# DATA t8v0fqt/i2aqxRDLjnLbzFMFs/qA9qEXx4nCXfOCVSkmJ9+A8WcQYyfR40ssD+RrAeIBLJlF4rSqX8648eCiLW/EKHoF6huN2UJq
# DATA KytJu8i4U569lTrGZsNNWipPVtv6T9HUP3sNu/eok4gHC95JPuMNkN5fQV/Mu3vPbIGsfb6M0tMHvC8gSfeyfetec/P9NA1Pa6M0
# DATA me6tf+7+ZEKPWs+qvXx/E51CelE/gxZew3ZAii3PLb3Xvc9eO7AjOI2mOJ0t2LEPwvkeB2pY4Sxn/DA6rXijcDJB5d73HuPAP/1X
# DATA AhCZfN5T9kAiASL1e5TVe1akXodG2f6hoQozXYVeupxMvO96exKL2jjM8LJ9uqSuUFBy5cCKwIGHo5+iRcBi+4feExxVHowpVuoN
# DATA lwkRjz+xU82H6iXZChX7WD+eyeP6h0OVF4X0ZxvSX5F4o5bMjuLRqcZWmWzBFps1aRnhcPdqJMPTPUye901RRBCo/au9z177lnh+
# DATA P3uNgobYUDQBorWGu9XpDLoR3w5LQY6Tk41hijF66TBny+lePNzPU/PhctqP0j0O8zOI/tGvNZ2bhUeHahPpnsi5IXDRs6A3ffYa
# DATA vt6h5hzPDvUxFznj8loe+2WK6P/w4/drsuPyB3w8hL5Dvc17Exp6P0Y4P6l4jxHwExSGPBraDUmefmcSsV7GZ6+FnA1hDbv/oFmT
# DATA TvBNxxetiWKMS4NJPHhIbQpbTz+Jp1GyXOzt7aONI1JpdExGRR4pCgfcd7JfVVZIVLC+oUsBswm83M6nZIYNzXujGRKOssEDLIQ3
# DATA hdDHO8cU6feV1gqFkS3705gKsuJFx1xs9+gx/liDagz9fVs2Zu2pouaAaDpOU6Efgd4RL0739in8GW54oqL6V4jej+XARXgc/YQi
# DATA WaMH3wkH4z21+ZNfNCGjOQtFjI57F4oQviI+P/6JeuO/kh4wzvjvHt9Ab9TP/fgnupQo/7E7Hrqc+xK+XD9lJUu+v0ajymQ5jDIV
# DATA jbxDpF/pfWaT3OK+lrZHCVtb3xC1B9xo906h1mmeKVZ+vPO7VDEfSHKog5HPOG/05FBHdS9/fE3ZcH3B+3RyriOr9OcdsoMSIHeR
# DATA UU1T271jxALs4Lve2tsPvB/Xavx5WFl3hykosoAzJJPjwd2rlRiJdCGL0Lvlz5hsNfvQl/Oh3kxe2MCv8v1Nte19/R73Q3lGwuIt
# DATA 7Znazo4zoWRQHEc1buFP5N9i9TYLXsU6njzKKzjfkulio59MppiHNxehPExlaEJBISKQFRvgs9fW7eSzo8W/S8T4o0SAi0GCz+uD
# DATA /K57Yvm2roryyRu7jioTJNfIteyXbdE+UHH5DBKeU7I9pLaZKGyqORvyU0dA1R79ley72RFNBmH6eGzGe+a9dLFUy3Rr2VCvDs2B
# DATA ivU1C9Umrzeq7uj8gblqRmj+pnpyuYFGfZpbsTHGt+jv5e5emuZ7omVqsp8zmfWJOeTvSi56f/u3FGtUCOq/pnv0J3k/OYnStyjz
# DATA 9kwWU0PIWHxNv7LwNFlJSDjXa5yYoPvqh57VIJCpxUpHF+yqwaKLEO+h63anWYxNXhM5LfveX/+1t6ejdveujgkixQGZKmDy7e5d
# DATA lRTUX9wiy3r05n/FUZDmxh/3JS2vvy4FpYwdrBzq7OcvubmDb/tyRx6s5Ad6x3o+IimlIilD3GACkd/21T2l4UPC4lrKMYwyHjio
# DATA 5HWJrmmM3I7QFq1KgeSYctzagAsP0YsQR1VNKZN1IPvFGocblcWxt3/3HtuMn732rjkUhmby+h7Mvs9ek6ZH6f+OfOc5IDf3RfIu
# DATA ttXtBfuvI8H/+/e1z+h/s7f1LDlJFuxq9cKF59OM5XUJgA+bUQD00Pr3kPF0p3hr/i6f3/V//sl6UEdoh+cGU2ncMgPMD2S6g9nu
# DATA YPZFB7PdgeyX+kC2V9hurM5BP9cHtY3njH8unACcWMe3H8xZLQ8jWzwEbESf3s5v523FfE7u+TrP/aKcarxIuMV2lHL8xeN87w3q
# DATA acvNUC+SIRpmpaIr613WCp5cCCf8rXhQvbx4JU16kCBz5U2ns4GOhvJj3/vBytoXm6lkD5QO/lvP8BdOB2fA/B4X7QGVO/RgqLxg
# DATA D6WLU2wqNs/PRTcgG4d8IlbXKE9tuKBpIR9HXvZpXPPg1fUwB6EwP+d48C6lOElr3g/m0YzP+Y747D49pA7zc2X1KKwxah3VSU+2
# DATA ITCGCXfTm8FYoIBmSjdgR+Udr+Tj1joCfJ6Yo03WAhnZRziXZmR4/gbHnFHhcLqbiQ7eR0vj7vVmuMzqR/KOmH5azmE2ZDUPthT/
# DATA mLFJlYzg5KEWM4SlppoNmcsJSwCMlilZEctVNYSX87CtCcFZb856u8h6K9Ywp6/j9HUua7ZtNBBvSnfnAbawWXIQeA18mxDOMwo8
# DATA z07jbdtwid19ni1XV7DkeP2D7Q8siqgtOfoaFzY6IbFj2SegM1l5Afem+2+IT1Q3wBmvR6GQJDTznOmu8ivsFePtH7UWbyLSGtaU
# DATA fN4QhYvTkPcbtdRmkmjOu49q0rPf4TiWoipeCFMd8G2HiOqnTDzNBRPNRq19jdEUzwj9rL00fOENcbSqSOl7TKTMQ28k3OHnkQvw
# DATA 5nv+QVB/406irMLyPS11T2vLPX5d3UQf8rvuSLTypChbXeemWgWjB/NmsLAlj8hs4CfYkEin9F7eE6zSqVZDMXrpqplfkp4nPuYX
# DATA zWmcXkgO3JEgMH9SuSXrtHYo+SW9Q81cuWcZnCEmZFYHYEtTsdEozX5JqYLwizEoP6DBkPpnMRq119pq/xhjoxm3fDYUzUAbp2JH
# DATA 1rz7w6HHZ2KVWZDp4TO3Ib33sYaiVD0xETAj7RKy6eLoZaNUDHHqcfBG7MKgt82Xkwn/uMQyLA3qcaqN/x9mkSjviIiN6P7E/Ziy
# DATA WCTmtYiUrvNYsM04CmSWwLBgUxo9EeY1cYZpISVpJp2fVrlie30C4Xurl8MY2I9YL5MzjTt4KRIujZffarYHQGc4O8P5IsO5ZCA5
# DATA y9lZztvN4edAsfITehs3jkw088Khag252VzSbMTgYnTeWBHxYbSgAp0dibRdUXpRmGDJCONWoiQgc6VE0UMsG8kl/yy2K0opqC2L
# DATA b4wbrD+nhZx1Y6cYN8RlZkQqYcFgnxL0FkOJLothJ6MRtn9Bpo/7gswbJyf0s0clJMMl53XNU8YFJC0pdscYd9HPJCPuGDjPLflK
# DATA 8VlxcoqD3iJkb+b9FMPVxIx0JkV20t5np1w4IBsHQpon1GPlKcPIW+Upg2yIZtRpOMl4uxgsHSTxiGyxTPdqQyq8MfVmXEqcTDnl
# DATA QyHMWFQcbkQynY5k7iRGjPaXJVOyGhdKXTCEVfDQ00ohW9L5dnjKPfH2hKIMxVWJMtZpfKD8j6MoomQN4xFL+9HsDoYaBA6xhxH7
# DATA EKhaLWQLBtON6Rc0RfzCJqD3CWN4POYLIkC2rJgpC8cgVUWdEGPR9ZenUqlPF6jP2CS6JZEfR9maBIpZUajCq4KqpqqTlcp+yxOo
# DATA wqOSTdAEedRJo3VGLIq0ou1IEN7CYYyzdzLQiZ2qxCSp9n4M/ZchZSLZhWz7Ifmw85ZkTPATD8Xjql3KDClD7Z7KO8We1FNpLXU6
# DATA itMpL46sm9tyoj6hvJH5OBi9cxwjJTPJqK1TCzLWc774nYn/Wu6n/ODqSKaAmp6HmdjC3Dt5H2hxT+pdGfbAprQCcRsfMjWeh2we
# DATA Y2pAhi+VdLhcxOg2wpR1uqZKeZLVT6VDARdK3MZkIeC6mlJsTO3fzJITqZ9oJdRE0EdCsFUn+O2Ew19gXyVyW9oiJWgOVwJ3jTy2
# DATA iV1i+RXQ+KmUsaUhnhi4VsrThZSKm7KPbCTKMEkhFTkOSGNHRriiIFvohnmKMDstq8ma+YQtK2vZ+WIzv4TW/pMnFcPQWRwBzpue
# DATA 2gSd/+/8V2d/OPvm7H+cfakYOV+e/Zn+/8X5b72zfwbThn74Of3721V0zn+lH76im77C/Qy/+fP5b86+9OjL7wxE52sKVC7zV4B2
# DATA fnn+m4p3/nf0HD2D20DP+Ybe9EfG+PwD/SBMnT+efXX+ax2Zv9AtfxBQD2A7jqXzAsxm0Cnj+BJ1OH36syiIZh9FCYWTxgNtgtW8
# DATA dx7NJzI+T7hHjKRvyMbxnHqLieWN0J0jVhHnUe4zyOdCyWSixid6qZb53QrVwXKiCk+1FIfWKc5vdA9y22CddSVzc3idvOqYW2HS
# DATA 5ZfLD0xEb9rc/b585xH9mgk7PK6pYT1Rm1sxmDrAzo7Fdv2IHay9R2x9onAquYuRjV/kHhwyWRQVDNMxjSecjyy3ny0wUy3tVtZI
# DATA TQRhDqXEixW+zsXVb7NDc03LelaYnYuT4Tg7zhK4CUtAA3euaAC8Is7NWxv8b2Ts32nov+zIfzsDv1TP1XzIGTzPX+u6CRiPlQOM
# DATA 4im+ek16V0Ee9LrpXK0kqsKjPEvxUgW+iSRrMpU3FU9JYHvp+HQxnnIocsCEM2hXBI8qsnwhkjriCeNllliphUr6Arm9UP5ZOSY3
# DATA Co8TjAqKNaNjjBcI3ISHU3pQWwzqXN1hbi8IsQi+H5gRJ+FsYbvFBsncMXYcY8cxdm6SsbPrqLLTNGdXK/mWTf6rWPzXYfA72o6j
# DATA 7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtONqOo+042o6j7TjajqPtPE+0naAVXpW2
# DATA 0xm1RoMXiLazuva8E3OHc1flHnZlevyudrugkNZqlnK92e4WuTlR1B0psBEON1L0Bhxoo80yIAMONZBgWCrDb7aLEJ8GZfgaNFKn
# DATA 6TWDuge6jd/qTfxu3QvaJWpP22+1uv1VUk6z4TX93o/8XnPc7B4HQWvqd3yv/iO/3hg3O8cNvxiFQTBs9vtrEtHq1vNE+EHPJKJR
# DATA DCDoBcPWKrGHMtZrdoKxykWLnmMeWKHntK9Az+Eaa9FzqPIX6DmtZje8Cj2nNYxGfk7PaQdtvzM09JxBtz8a9nJ6Trvd8rs3T89R
# DATA dbzK1diMCw0h6OjhtnDTOkdVg8eRSu/4pNJlS6qwxtQajA93Ju2U36Yc3LZrS0wMdReOFlwPbscOcRW3oyaaXWOsoowPeSfHOBwm
# DATA Jwd1D96NuqdLsgDo4Xa9+grtdjemeUfWTwq5XrqpsFYmw3kJhnO4YT/A6milKEnrPLWybrslZNXVqKFNN5S8ZjRN/C52pao+YzPF
# DATA p1DaF9iIhcyzC1MlRk9eYIU4yo6j7DjKjqPsOMqOo+w4yo6j7DjKjqPsOMqOo+y8WpSdeCT2G9Y9UOMf29+k7txVI6YauOS3CtfF
# DATA /cMnFqbnseQbMuMuB4NTRyaY1+kJ4Hc+e+311XeoSn2oBxT1ktUb81vUAQ26i+3cQwUJ+hDHuKTlsyk/OeXTOfqt5SjVvH+nzsBb
# DATA h9L44BnKmiqUiUJV30A/fHfbiH9NWWFsZpNUXpyqLR4t8jRT7/jZa+9bJ+9MMqi7VCmQiW7pnI87gu6OoO98BL14IMydRXdn0VdP
# DATA DW7U23wezqiX6nihtdjiNOz5YwFaVOYsV0tRwrfxMAqzArqFT0RD2RLkIh5pMurO5JywVlLhrXSl07K7nkHnJLA+I8ZyFudTkqD0
# DATA KrhQ56LH12fZRcRvzWFQtctqVb9e2a6ogvxJqcEr4XD9Y65nbq7wdlvIf0YcjolenFlZvVnl3RjELI0un4sa79Ydpvu0n1pRaIdF
# DATA icOd6NDkPhZ33STorrpUDut76vPmu+V4Pavc8afNd3Kfq2RmB9Hm+6Tf5vTzpy2i8nLQVMu5ix1qq7ljiNmi5V6oCfCf27Ku+S/w
# DATA 1nNXp+cB8knneTnPSmKb7NY3vYBY1Vzz0iXnxr/803806ShH3Mr/OUuUos+ZhPNcf1UtJfKetHQJiQTYaAlLMcygBM9a1FArjakW
# DATA MpQpnM+pTrK+LnXMaH00iZ0t5Pg/9FgX0D/SOrSsVc2LH1pk9oQqtzosrnxedsvMTz7rppEfrDaOM1xWSTE5o49e0gX2BXNNoXst
# DATA EEBZtfVSRZRX1MsW0N//980FpCu9FM97KAaqyJkuoE9OEmqjKXVsnj7llykThPqk5QyeSBqS5jXvPRrlYeRMk2MRpKA0sOAAhA2O
# DATA Iu5WUUCyf1iVU6TVLVRpPX2pmBTcWrmYbuGyxfKP/3VzsaguRkpF5EAHSUqTEdNyZmoiLJd5mtNnTVfWVZZP3jxEwxqK6SAKviPq
# DATA w5MTVURFO5Kl2dksLoyD1uV4ASP66UvJTtGtFVTeL1+6h/vt5pLSfbwU1adhOvV4d1fexZ3gmsBxhsfQwqaSOaKC4fUL9HWRDPez
# DATA oUhpRKweC53paAYIjpSAmg30IyZ3xAvR5MDuWPtnpk48ffnkybi10nmaEej/+efdR6C3MMhGqQwJlg74lO1qilf6UFna3KTCCauX
# DATA h950SePPJEyxT24O+WRktPcjMR7VAEMmEhgG0mxQ4k9fEoXovghN5T/t2lQeJKOF10e1D1E6ebeGMb5PWTSFlg00YwY08mBywIrQ
# DATA 4fCnIfbnqBqfobBStsfjaTzBeQPkFFQqyFL/fBmLWg1UEFlYRQpQK0JfQ1MpJONKBVQ0AsWjaRuB5opk970PE+171JpCPPtQPsEk
# DATA FSojBuiEO3FdsEr452nYQa+GuIuDcztX2hVcac5z9op4zi7L634u1B0L+y+3Y7tlzk0D6QJbNcmiPGKn1kZy93OqAvkCiaZdpA1t
# DATA 73u8CYr3aiu5dpb3WhnRTUTv1ZSr24w6tjhfMAmqeb6RxGZnUkV8R6IGeZIYx0XuZFLUPuUQngLKbWT+8oKueMtM8KWQBaRgsDNC
# DATA kpCVtbDX1Bqlz811MtfTvJIW+IfwdM2OAA0UwLjo9hgpcEtZUINvlGbWgZEThVmdi4raSqIe+0zIYl1IaWHeA+vbw0Zc6G0eF+qD
# DATA bGaTzOLtqtBEneUNXrQLdW4hh2uvkvFoB+HMR2c+7mw+2nXNrcO6ddintBo3Gqk3sw77gXA/baXonHj4bEgVt0EJ570/qF58bLCw
# DATA zKl+yvHa6taV9cJ8ISlfHtu0tmgvb9irNZvuLznaS0sJm54quH8LPu1NT5TdlGU366bnyt6zsldw48ppoRR4kxViiuo0jIdcH2Sh
# DATA 6btvaPlKVSzqXvDLZc+psMTVOVNNOi8vguOQuebv2RaVp7n31KnbNpW4zPSrd6CI86aC6WmhAb24CHEsNC2YhDpHT58pSzWZ2G+J
# DATA 5no8kRknm+CRnkkZiCS1H7NatWRTgUKjZ/Dc27ojQd9iD8+eEgjhCYAx2dVTn8ISl75H1h2H4lrmfeUUEwh3Y4FGPXEnWS24fN64
# DATA 3mmc17V8byE4nrqPopIulfDFDPCXx0q24IAshZRMC2zA/6ggft+c/Zn+/dPZV8DwfeXhG2P5vgHr789nXwLKt0oH/O9nf2Hi3+/V
# DATA 3V+dfe0xKPB3Z388/7/O/nD2xfkv6dk/qkC/VgjBr89/hWv02zfnP/foC4iEAgIEmRBxkOcALGRu4F8cDPBFsPoLffcoOiHbgSfR
# DATA 8xDStQoCgF59OoJ8RB+SXRoDQh0fVmXvK6xu0mfmgeqe+7rT0n32cs6vQRPi8MjIGIj/JFos51sRgPchdeENlxk2u1B7dgDAgr2v
# DATA e4nb5v+tFsvN0f/YwmLCSn5rob6VeeZ3otNoHkdkbej731EXPKgMAaGdpNeMAWT1MEZCLxc8/qszWtTEHAlw1yK8fhQg9TVYBKc2
# DATA P4tH6HQYBs8QZ2yXS5NH0NCJ+OyymPIwWFELqXMbLLCFYcnS//Jjpjaf6L0nuqKJS5UscWbcYBoXH81WsIC7V8vNts5Kw3tWcMDd
# DATA E+Mggc5CuD4LQaMBr2QYvBpOwFszCm7AJtjJJLi0RXC7BoFU0XJ2GDPguWlVN4EEtFKtlr82RFHDxdh98fDUO0rD4TJU0L8sX32A
# DATA jGFxjY1Rg8VFiVPZ9Iml+WN2PWGtjWURs3k0wMhvTLGd4IBmXGdlbkpwJvvoKANHwJdxBawmoyoqJ/ezVIdqHlRscXw2FMsBPjom
# DATA 4Kk4KLYakj9P6VLGa6mqtJX5JouEHFm+0WRfzfswAkBOLsimvQdLmCFpsjwae8sZFdNCzrDzizOHEXQYQYcRvEGM4M7D0E6TpMsa
# DATA 1Lc6R7jKFOE6ZwiOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuio
# DATA go4q6KiCzw1VMOpEw5F/Raqg3w2iZvgCUQXLK9A7MQWL8Lxe04LndeoGntcp5utwEDWHozX0vXZg0/eaOX2v3duYt3nBTP161wv8
# DATA juf7Ta/b8Xqtqt8KPL/pU3nR1aDjdbslLF+n3ev2u+uwfIUo8z7M1fjSCy3kod8x8W0VAZP1qD3orHk+CIL8+UY9RyZ2d3u+Ia9U
# DATA +dUK8vza7flmy4p/w8rvHd/f6lrIx2ajc9n3+227vP08/o0d42/XFylbfry52+Ptjp18G/a4Y/bLIyr57d5l31/MvfoOr78MJFIa
# DATA iYZESl9mQSIHnXDY8YuQSPOIgUQG9Ua/1StAIoN+s9Nu5ZDIQX1YH44MJLI5aHe7zRwSOfKH7e7oxiGRM/Tn1ezhab7OIUcoj6Nr
# DATA WHcILFeHtrnYfjCv1RZhwfSRl9FsBtP6NXtYVIbbwdSgXVS0761Q7Du1lbMbsbIQUb3oobiIUoL6HpUlj3fNtVrbohp6drao2zy9
# DATA q6WYN3rWin3yBUdrCei4ZYeC2o8g6ahm9MM0OoDo5WZKo8mHSim5W0y/ciFXtpYXO1NMkYk9uFJNxHwKdskpDsFRIB0F0lEgHQXS
# DATA USAdBdJRIB0F0lEgHQXSUSAdBfIVo0CuQhyn4dFdmHrUq+OMGSX5jnzVJ1mQCQq5+IGtKIBW9To9TXXhXWyI3PP3X//stf/zTzUm
# DATA Ht5fqzPAz+xJ+OFcDhvgjRTMvgknQDj/+wsJ5y20eD6+NA1ny1HIOv1yqkvOI1JznsvRNxyqCgW5ED2iG/nwJ5kDGQ1tBUJi4YyO
# DATA O33vTt9fcPp+zREudxbfncV/mrP4G/U4b/SMvigiJnwQOT/uLcPKd40+57OXj7kNrU4Z7SCjaqIw4gOyyurcm073FSVRt9AZO0By
# DATA QT8dhOnWzAWjaNlpFZUkp/FM1r3qSnWSV4GU3iT22/Cvm3mKZlC2q8pl420FYqJuXzOxD1rrIh9YUe8WIl6vtTZH3Yz3dtT1RVWP
# DATA 9obRURrRVP2CFFhhmRTY10wK2muzv2Hnvh9syfyNCp26laBGSwfxoqpzWiMu8xDpzlRasz7iXjD7MG9arG8y9KoYR9b7p3kjt29g
# DATA kX2Rz5fijrKFdCXypOAZTZXIw+Cb+6eCciz0S1p3gPUrdGjUj5ARqAxEzPfmYjYMY8z9+DFoCLOkxkl4KgOPFCeP/ZkW1jhahjTi
# DATA LKKIpcGVsMXn1MGR+YWj9UoUZE2MdhDwfPkOrJdGRWdZO8v6Asu6ZDQ5q9pZ1QWrejNb6XlSviq2gtDklxG/+iH4e0btCKvYudYR
# DATA 68nAJV4x+k2CLo6mcTZnCRrvE0NXYeOddXMieOZOIiazVjy9ZwOjUjTHMn5Kj6D+lC3qIsFxRezK3EdD/7uxkj4aJ2n8s8RI3igF
# DATA /9DLwhH4OlFKRhFLMJlSyeZJrpDOEkUsGqVmEVGYnfLIO06mEUR5eDZBdl9FOBkixYN7abSmgTWGCcGdVUa5hVUEpQaOrQobpgwF
# DATA 22YY6bi/D2GeYgeIrRNKtQc8yLxDNDbRchayYUP1qua9Gc8S1CF6RmN2tSEwix4t2JDkJRVkkOpHkwxuK9XDKhNIqsCUX2aBQtcZ
# DATA E2vT9jc2GGGSHOkUfowTzVJuUq0Kc7YYC7JQ/4hzsSLDXRAJr8mpUsvnHj97KDUtHzf0pkiRf81Y/3UEqXZOhFYkZegp48I8PgsG
# DATA 3Dayd5FtS9RHIuclrSI6VZJZGKnnU+7CJI2iCibys/28PNgBmBun4cIIhuXjEeUFVVhKo0w4lZ4SZRl2uU6wv4SrMo7QpHaFPs3g
# DATA G+fYPKIAFmQcxkPQYGve2wk3SQx/RpkMInDKYByh80ut2KwQkNiyulD31cSlH6rCXloK+mY9xTBJzRUZJE7lghbZV5Oz4vP8Y3Hq
# DATA pRenCtOqOk+BVH+W92VMLJCam0Ptlcz+U73PN+SJSXiq0OFFUyWjnvB63xnwEMq4nmE8lf7net+AbYr3PtRjB9I0j2aDeHK9b+E9
# DATA 3O/oFqSX0Owe9Hrf1xKAxSgye4ao4bEtOaPWVnzXneXkxhi0L9/8ypFo3dRqd8lgN5F66SdSl0XPPl8SwmZP700wTMuZfe0E0zVK
# DATA xxfzSycFgoJoALMbsqgrvAWv+3zpKL+IEqI74ha8wsZybYTncquSL2ayUVuZHOfT3op3BIXmfE6DWZgXYgKMrVZmHjqgKbCtHyuq
# DATA rZg0ZYvSrDT3JpQ8Cdr+FgHdQq0l6+U4ulhIGnVyGs41yGGnMlhToh+lEXvUC2rYWZRlmlX4CpluOeGqHz6M0gLe6r+dfQnq1PnP
# DATA z/6sGFR/YMzVF+f/nnFV/8s7/3tgps5+twq3+s+gVTGQChyrn5//o3f2+/PfnP3l7MvzX1OgX1W8s/9Jt/yJvv8S372zb0xooGZt
# DATA Bl79Elwr+q9jWr0IJFuqw3gezgaqYCyBHTLuWYYIsrZiHgmGcE1Arlx1TpiTiUtjxk4L7pdGCswzlEsJ+jjZXyuMPOo5MvZ0bUVY
# DATA vYkNtGgnEToLB7CyDVDpBG6bXlUukZtjV0ESelh671pkFVcxc+PbXOFuBlZFo95cbfpFLcUm4WQYnvI+QqofDyMHrLqo3K6dU/Um
# DATA mgGXwDxKcVaUFetxHG/EgG05femR7Q4tE7UKYm3B0+v9EMs/SqNhHMEbDUYB9alRCm9Xvpyi+sV4RubQUnLYmy4z6c/EDDsVqvcg
# DATA nkcrFKtdaupme6bU9J4VvWqXRDhulbMCrmwFaEzVFQb/V8LzdEsD/7WP+zsN+7uO+rc16EtlLKbeDPLPqrHcBH2qmERvHE3msE7I
# DATA 8ACC2UQuT3A6Pl2Mp1iRlaQfyFALoXeccFnwB6ClkS2yOkodJmhG75GBHx7TOJnp7EhF2oy3HmBNNl2yliLFfxobLtB29pTaHQEP
# DATA U4Ql6ojPdMlAzLHfMJiLi8MyCBhPxGNBJiZEFe1/WDAveB+g3kShUED8EhZQAGqK/sGeCth5eo18uUggDzVgUpcDTDnAlANM3Rxg
# DATA 6qJxZKe5zO6m7i1a7Vcx2q/HZnckKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5Jy
# DATA JClHknIkKUeSciQpR5J6bkhS7UazHXSuSJIajUat4eAFIkkVV5534kjZmRK0vUan+3m1WfW7Xc9vNatBPaC/vufTP82eR1+LOTSI
# DATA uv1Ga5UH1et4AahPDc+vd6dVP6B/muprCQRFmVwf9NeBoPyeBEzpj2ng1uijhoVearTaVtErDpJAiYrgqqgZRq1oJaLNju8FXUp2
# DATA y/MbwbTRrfrNlvq2Es+o3x+tjWdjtX7VW16z1Rq36/4HfjPwml1/3NJ6cRYDq9UMonVBrtbYdpNi2vB/1GtO617QqtI/fnca0Guo
# DATA WLr4XA269GX1h9JLu912IxhseellUEfSQjTqSBqbhTrq1zt+MCyijkb8Pxt1RF/DUb2AOhr5w1Hfz1FHnT5lVWhQR8Nw0Oq1ctRR
# DATA t9mq+60bRx3xDpMqmx42S0hFtjj79DESevJfaub2ZMBmGsnMYBvkh0eu/M070IcKTri2ccLJ0tsqoMgKe9UhzyOsbJujh6KHu8KJ
# DATA tKURlAPwLjFeb3ls++C9EUJklaDtC/TEhN6cnlLhdlCqHVW0xfzZnBxHEnIkIUcSciQhRxJyJCFHEnIkIUcSciQhRxJyJKFXniQ0
# DATA UhwhPnpFCa6c3B19Ry6NT4eyegjYDxk3lcz8lIVsUfLVU3P1NKIeWV3W9KF3ES4ThEavUw4dMR/oU4qhXDwpgojU7w8oeP45W/vz
# DATA ezOIIsFYoPfxfadr7/skWYQTOd/Hd30QLsY19hvsjV4/eT17/VTdbHOG8pMs7qi0OypdPCptnWtyB6bdgenNUn7PwUFqnEkd5dU8
# DATA PPVC/F6QN1+w8onUZ5SAkQhHvangZ8jmTSbJyfazvtP4ER8/nqdJMtLnj6Ezbhoqjb/YirJMo+wptM1pRExPkZQFZQnSp49b3vey
# DATA 5RydajRULTrODPmILBsFNkppwEPthJzeJF5gESehyUPGStgCMhmky2n/ENow8YzPY2fmUPUIzt5jPr/7KVy4BQWTlDXdRUE7GyQJ
# DATA PzFYziGzLeeatylovwUbIj2VfXQeD1F50kYQWYcKIILkUp1F0TDT3ZmkN1ukYi5TOY6TyZDPuiLmlFiaA7McOEplhN+OKMqTUxYK
# DATA N9lmyk6UdVgmHafStSo6pwETuUmyQNLpUj85mXjhJEv4YPBWifB3qXpz05Fj2/TWKLUKjwWb+2xtcnbpm+NMn6I/QV1E98ziPhOc
# DATA 70U/XvNYUT3vyQfYkBJBHj2e8MlcnI3Pat5brNbMddfTgBpUB4o8QkVqwyE2AnFY5hiiUvUPFxeJunPOcZxPaCAxuoLYjorz7x6O
# DATA 0uBl1HTCKb+OBjouHSUJP1gupHCxrWauTgOLTrw5740rk1hRuFAtfgaZeobjZEbR/KGEJ/4VDpFMw4mdJbE5zx2m06vpmr8pQtTI
# DATA Omr8lxY2RyO8bmXzj5H5KLwRnNPSO92AoHnOthTBIxQFG6JerkdwA5rmRpmRjZqZanvoZjHm3YDE+X3u9o2tpNQkbk8J/OU5yJ0H
# DATA 4mYUbkZRnFGUq5SbVrhpxc7Th43Tj5ubVjxAVuQ4HImOnlI899qAt4EoFUcaXWbPl7d3dBEWUz9gOixzIadz1K8CJK1vxnrmrj26
# DATA 5fv6i7f37Ysiaz9oIly4mFM8u+vi3GxZUe7tSlBlfyMTSiaLHWKpbs8Rr+p7waRaiZqdmY0iIXVL1MTpST8XvJI7RFI/aGJpLuR2
# DATA ba1zUUSDbRHdCEKV+StGK6ulvbg0VGlqcVYUOzKape9S30Ktwzsyc/GK1+5+2zP11puSSZ15jaa65wT+aZrl00Q6OkrRUfJTGpmF
# DATA 6bdws/hG7o74q9Jhk5mpgZzGrFYbD0xXhzdGj2TNRE8ZsAyGST3CKkmZsTyX1ZdpAdtMWGXytKxCYNKfT0skdur0QaRV0HagnL48
# DATA trej7zjbe7s33xnaL6WhfVnKzjMWQuUdwPkG2VUD1IbQsOhgqD3YRi9UkrCZQvNM5VNfCFlB/u81M41KQq/XTTRakcpdyzPaQbzW
# DATA 2kedS9jiWwThyiQcVQxBh62sZTZWBlapnmKnuJSs2i3+xrhx7900xroNdimyF5EugVEfP4INw95/Oc/FtMO4aO7QBBKzwGjdsotS
# DATA 1RQhU9EnVQcZeAuXMnmKBgxNSy2PqrFaTHTteD/AmhViTvZdKeYiu2sWVSh2vH5h2oRojOplGcUgxXEybM+2VotYPpWXnnAWcUuE
# DATA 0ex3jC0fa5slTP/l+D7ASpBaoNPT56gojhoWF/Z4yWRiVv0ojgo+iRUILIJtjii9bF2+vjLanRY5iAy3ATg8FjvoP519efbHs2/O
# DATA f3H2FaA/Z384/w1DfUAP+gUzfH5Ov4Eu9NtVeNDKw2d/Pv8NcEO/OPvL+c/Pvjj7Pf34a2YQfV3x6NOXZ19X6YmvELTH93xD99A7
# DATA BC20ESZEoeMtX9Ab6EYHFHr+LeofQr+M14m5N1G0sNOKLAjiknS0andqGh2Bv6zlnGXhX9VXM7inLNpcoExTb7yVIfTWOBRVA0sy
# DATA 3HGELOtadQm3TRJaVy43RxPiDQHjZG5u/FRdWM8UGsV5N/1uvDCe4GumCQnUmO0F8RVZRJ9XnSO0S4ldO03ovifgdYDAq4tlPzIl
# DATA Lx78GHtop57sBK95HyRUA2YGhEiFeAy9d0h6YI2ANTxgloVqs0uIzxPZ9JHCfThlHqM469j4ElgjRGLL8KDtVXKzEbOmnT0rdND2
# DATA JDhokBvpLzPSa07QFQf4V8N1dluD+42M7TsN7Zcb2W9+YJdquZoD+UbX22stNwEKylMGES0KIFuN8wIeN2zW1Jv/dHyXJu18yIlx
# DATA IroAQYCJ+Xfmm2AJjGkraksov2Uazih1mUm3pNYEL5ih6Zy6sNliJ2wQ7KsFDvIjHyikUUq9XT7ox7Lcrxe2EAyLyTHEyBCA0kiy
# DATA yiCRTwWoXLFG+gSYn2Qk6GK8iCqi92CBZMfs8YhHHrWqh0JDOaGOAnsG0QZ5g0GKvNMOUUcPcvQgRw+6QXrQbmPKjlDzi23eWzbe
# DATA r2K7P63p7thBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGOHeTYQY4d5NhBjh3k2EGO
# DATA HfTcsIOi+qg+Cq7IDvK7jUGr/gKxg1bXnXfiBx2ZJPMuwiJrZtiKhqP6JtbMvTcGcQr7X8A+gSREgX06LNLA8ga+rwhDhdvb9eYF
# DATA t1ucHwrbo3s8+q3q9+hvnf7ttb5P1yd+r07X2l7gN+lau9rpVYNmMG72PggALOp0x53m1G+0qs3WuL0uJs1gU8QVwOjOUaECNQMf
# DATA kaE3TKu+Vz8WRM+WbIxG/V57PSKpvlI9Kc6toD5uN+sfINXNXuu4WZ82681qs06fygiiXtjpt9cFHVyeBiR1XtOApPlYNCBKxqDT
# DATA KNKA/E6j2+zZNKCg3uy2hgUaUNBtNdphTgPqj4bN4dDQgFqNTr8b5TSg0Wgw6g5umgakjJL1jg+d1pKtpUYibFyrbrdCPLoZw05+
# DATA bxn8YyZK6yZF2o2GuW6lWWsy/ydg/s/qelS7GClt3FjdtNgunBDK8TCtHmFqDJ5FfRgdVay1d/uzF/TmjyrfatRbnXaf3X77lc0h
# DATA 9S4ZlI5yNo8Gl6USaZsX3sMVk8pakdu8OK6WwsUnXM3oh2l0MAzTh5vZQ3kOV+yob7Y5Smav1CG2nRxJyJGEHEnIkYQcSciRhBxJ
# DATA yJGEHEnIkYQcSciRhF5ZkpAi/XxiHevKz3MXz3GVMTzCDZJT3pRHmi6EHQFoRqDzDKY1hvm8lUxZAH3lkDcfb8NSkqhVhTiokszU
# DATA 8TUtSFs8KCZtVCZy+qSFO+PszjgXjtq4o87uqPMVjzpvFB+8mSPQ78asdcFnadkFWT49q49CP29yG7ehx60GF1Qdqq9KMhyp3BtM
# DATA L5JoNs+aDiu/YkSau2u1uVu2SLPv14syza0tUtc8+EHSRfVefOENsWWNirLckwtc64feSLgztSWk27zc8zH1fQovxPXkjTuJEglc
# DATA 80Sbs4vGFu+Ot0ijh6wVeeFjLX6RbQZMYdCwfHLx2TuSmh2Eqt/R9RNV1kOVfXFVqj+IwmwJ0WgcrB2EaS5Q/WAhknzUkyTJQm6Q
# DATA Y82Q9QmPIPYMf9QJjVk174c8uE2iY6o06ADRqU5V2NyMFZwmSY3wUJqQOVnzPuYFADGN5AHWW1TCfjScnKKgqSDiRUG+GjCtwrF9
# DATA OUfqpUuc8caR6xAH7KHhaMZz6AeSxUZ1lgs/o9nZMptHon/IitnhbDnCQJxiLiUBgos0jEcjXFn2WU89xjhNgTF2Z52tp0QIKAmL
# DATA nQWuX5Zzvk7e2pmvlvnq7NVXwl69rLb1M5bs4XXtfAF2u7b1fRqN2GhkA5Lt2CyXomCOQrZF4/q2xX5eCL2Lm5C1Xq3X1y5tvVbT
# DATA 6ary1vmivzbHxKJQtk8EsijXuVzUms2fUzJpBKjJS0H0upr3pugG0SxJxGqicAYT5VOICIncS4bBjTGjQnDk6gYziqyuWAs/kw2X
# DATA kM1DRt1DeoMmhlyu4vxAC7EYVSfjDn+1FE8KOeOMIWcMlfpU581z3rxi37nRinrGgobMAwa4OJlMRGe/DOxW7STMcgm/mveucLrZ
# DATA Slonz1fQ8punySAagsYtUnRJ+vkyEl/O0/C578cG6mxovAsaQTUTcBovBDUtI6nHWi4cgyU38qNweUSj5sc0DGtaYIUDELNElnsU
# DATA 3gEdRjgawSnGrpLc5WnG6fdmGO8Xwq9dKlpENO1HQ4igDaN+SiOyUJF5CGURQOxQ2oqyltE/l2cUHHBIVQF+UNYUVKZBpq0LKMfB
# DATA X5OKs1SJT5MNMJxE/TCtee/DfkI0qZJS5oYKBDYM0cEAidCfiPDamIXx1gkZ8sfMUi0Ul2wG6vXnVPDxCDpv0whrf/FgK4x8zKrW
# DATA XHlmC3hw2ItskvwpoBzJaOQd0ZClkyj7JL3JkjJ1EEKxkesx8OrhSXgqjikdT1WGmXbrcPbxOEDBqJhTvmSiwA3/EqtwHypZQ0hh
# DATA pnyyQFVcU50LYI0F6g/zRrw+RSDa6HVWqeaRRsYWyIQzHzwXqobglGlZZMYklPgYZBKWf4on9HNF+6E4ATlsZxCm6SkrN96nPAvZ
# DATA b6cCEsK8wOM0x+c4ZEm+PJM+jGJOlfiJlfolXHJHSTK03O3y1oQaGo2GI2lrxSK8GuwbbfmUVR+pj/nupWHfiNt1w77FLo+lgSv9
# DATA wngGcHw0vAHo95tg3iu5ULV15AYY35+WVEhv5E0M934fTUP6GBrXZFtOJsSc630bnwL61FASsUI0D+PUewhvcbiaupskir8cUx0L
# DATA LpOE6fAIvnUbL/NfFEbmG4a6gA7zpXf21dk/n//8/DerPJn/Rvf94ex3gnzhu5j8AirMN2d/oo9fMEvmq4pn+DJfnf3x7Avgar7C
# DATA T1X91Fceff1CB0W30Qt/ef4rBZeheJz/vceMmd+BTQMKjYPKvACYxplmdq344uZRAgS0GrkXIjD9lp6vid/jiLdtY5BT0DDW7mV5
# DATA 4ZzcZQY+ip4eCpez4VbKzH2+JX+zY8wUZnOmZ7htysxqudwcY4YTaO76HoTEKa8no/J9Q2g/G6AX9vsu0vD0OtEy1AYysrFTETCn
# DATA mQasMZ6JoSAcXGZ7UV07VcZ0QsOYzHg+sSemDpmveAoi9/Ejj+uF9zFvDxC37RH2R67bVC7sQ2i0a6VvlNksWrCmOfZ+0BierTBk
# DATA ttW8zXbKSht6VvyYbdF39Bg3pD/VkK5xMlcayV8Nn+ztjeI3MIjvNIbvOITf9AgudbGc7Hzb5DNsMTeBlCknNCfLGM2JPOaUm1Go
# DATA EDNwv7HcADxdMyrSTFZrkQzDz5BhFeiJ4zhlXAwKS2NlKOVhhos4Mm6IwlgNlYH1EhCZU1hb7NuVEI9kmxmmCfSxPxGP21Ea8XkA
# DATA yXa91U351mn0hxQCf7+QR3KI8Z+zJLVshiJmJEodLMbBYhws5gZhMReMGbsh4S+0bG/VPL8Sp/qpjHPHh3F8GMeHcXwYx4dxfBjH
# DATA h3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXwYx4dxfBjHh3F8GMeHcXyY54YP0+40+836Ffkwo9EoGI5eID5M
# DATA ec15JzqMnS2Nuue3OuNGp3Ec9Jrfp+/FHOl3Op3mcDU7W4Hnd+uUoZ3joNn+Pn0vPkd1s9tXXBYuSykrKbhT4bAEBV2JZq9Yxs1m
# DATA KSL9qNcpBxgEjasGOKz3gk57JcBucL0xbDT9641hU6rO9cXQLhQqy2vIQ6tQLhnghlK2CuVaYmgXyrXE0C6Ua4mhXSgNCfz6Wsol
# DATA A7y4pVxLDO1CuZYY2oVyLTEsFEqreb0t5ZIBXtxSriWGhUK5jhgWCuU6YtgKrLbcK5ay3yiFqC6kKvfLg387apRQXO1eM2yuhaWt
# DATA g461Wg0LOibhpwYJZhkpOtQVflrQeroAWt2eFUCrd/kACknotZ8yCbsFcBmemdhommcm5p7FMwub7WYjKvLMRvw/m2dGX3vRqMAz
# DATA i7rDsD/MeWadfrvdahue2bA98MNuzjPrDpphcOM8M+X1UBsazExInPFkS7KDwvJe6EVqMz/r8krlmkX/Yshljtn3IjJi47AiMSnt
# DATA RVkTnO2I5EWeYuhq3ffiaJjpy/pdcvp2mhwfRbstFbV2WZy2Qi2vOts+E11Him7nQCbyK6uHfsNaJFb3+kHRC6OrK++xHIfD5IQX
# DATA YrDiVvd0nbPytscOC54Vm9nchv10ehKrcru+mYFm5+kFHg0rt0p1kifLgQOhORCaA6E5EJoDoTkQmgOhORCaA6E5EJoDoTkQ2qsN
# DATA QnusandMBXdXoczwmRJd4SSpizi6h4yQ20V18y51bFRn9lC14rv1w/gNfuIwfv31/ce4yLcdxqO9k3hG1hXZYafzRfJdGPEfA4ox
# DATA /RGHs/9Yt6D5XQatMQhkrxn0mr12J+i173CU9r/Df1QU+ndhA/6QZu+NQDpef/9wmDyWd5RfsdffP3zCspl7/R/Xf3LvLr1r/1Ak
# DATA 33Dh2xz06/7hk4iMdaUFZ8VF+G8c4J6Kxz7drdRH50sa9VS390Sih8pxV/380ySe7XFvRTkIPhwaw+vqR1mg3dsLK30qjvD1foWs
# DATA x9ySV6mdxHc3WrOTGAUzie0KeVeaB5UbvUnSRjNHvJZtfJkR4AA52v0cWwlmw71JvH8oeVT8nVelaeKuuuJ7fn2/eAOGYBWft3Bv
# DATA TU5PU2V7opF15uinU1ZxyiqryirmMLBTV3HqKpdUV9koin0DqisfQ45LK4BMEtb7YM0uI7zybIW8boNOx6YAXRVPkJeMODEXYOnU
# DATA Q3mPpL4X1GRXiHS+BaRr2zg6fwuMjs0XVH18wPwDRVGC0al7chidfmiFEdeWoB6JibSZJcdj0jvwrl90py9qwGSBXnQjK+x+chJN
# DATA qBO94N6gru6dkQlcund3dB1Xb7RyLtEXllr3N5rRIONRRtZDNDRSe0Zeh4wsI4sj5ntZaodJcrvJ9rCIjZclyxQs35HgVKC/LVYj
# DATA NBxyPp14LchInCkZH0riqacO3RuxGHrnilrMuHHP1v+hNDWoYCa6UNgis3PT2qirSmCyE23uZVAMyccSZ3Q6o3PV6MytC2d1Oqsz
# DATA u9CefGZafw8YNcSRZBc3kKOo/sboNECyaTxIE0sCb8kWqtK/C6l1zQagW6xq35lBMW9RajDUkBKWkhsk02mUDmI9BrLlmkZYacHG
# DATA hZ21/zhl83sPxFvVP4XPLMIuEwyjBqAk7F8aTLGXYo3+ljrvtmqiKvcsaiJ/Usapsjn0j7kBZK7wwWeg0yIOR8VPlhtEcFBHfq3t
# DATA aXy+4ASpz0XL07rDdJT2UyuGHZymaAtgTcl98TY7UBvnb7MBt+muQQLiBjWXY775rfzr5me4EuHuj/Bhi3UpA7O28MSFapskGCS2
# DATA mHeFEsaeD2nQ6mhnjnSgTsmwO9hjLas7Ki/tvCjhgHg3jGnn4gzm2pQu+fbgX37+f7dNKsrRVjmrTDElVUkVJF2cijFG9h2PTGDy
# DATA aEuSByGa9lVhdw15vujdHw4hjUdPCwtogMZGtZ8nisxPBnsFD7L5J6MjE1E0MRm2Kb2l5r0ZznIq4Gwok1L56V0QYfCSRp0GWUMJ
# DATA 0sdOrpSvpdpzhextbs7eQl2UXIa9LDY8JWQRTnQ+32eeDA0S84rkmp5Yc66F2ASwiKeRDWWbT5Y8e6b55VIseiYgKY++dz+eIq9G
# DATA ZK1lY8Cq2PTGJT/A13mSsYle894BfBGvGcbZYJmhgDgkWZS8jlw27e2y+bs5b1XL1bmKHp+63gU+6Dx9G3t7Qq/xf/6pAVbSkPIE
# DATA iwcz8MxPgA+iurWkvKOykCl+5vlUoD04LWT9ZRDRHKTmfURdNk2970vFluoLAhRzkvi8ogf3xqH3pn0HzhCKu4Rn0mqTV837Pn2N
# DATA uCJT+V9bRb5yFm/vIQrZ/CkNtDTJoCBSncfGnB1Rw6+KnlPOAoN2INUvVKa55KGs+GTSF8jdqKTw04QKPY4JoTz4IbRLcTIwY93S
# DATA 0AQSzjSUqiIvo9+whCJx40w/ikXyFDyy4zihFqIeDqXneT46j/alOo9/u4x55VMP3roQJIOp/tIYh4rNFZBtIG0YyXQI2e5lk3hO
# DATA +cmNg/sWgM54etNnfVPtEYSCKkZ1UWLlrsk7ihZSdJyFWEjMkmmEC0fLiDsOPB3PZKJC/dLiWrqPmx/83uJxCUyk2FRt0y2KW2Nx
# DATA kkiHLFmL3jgThKYIJUdxSqPbCULR9ZhlbGOj8EvTdTT9VLV8sgVZ1RnvpK4JpxWptz5WkzsKG09MEyzk8twBPQVjJ6R7gc1aztyi
# DATA uSLLxra5Yq5IZt2jBqYWeLWQsIzfYipa5is1tzE3PCmU2kWsp5fB5ZLPtpzLxblc1hAUnJfl5feybHSgPFdEhcJRgdWRcmKzFrxJ
# DATA vMARZ1ZCYSQmKJZqNGEXTP4gnyfhjH3WCIbnWav8In6SdfBDViX56Mu9N6gjLbc3ffS9cLyuK2f5rHP5ciGcSHdYxkmsHEmX9jtI
# DATA UDvkbaezgY6KUnnM/W62mD2Xxxowh/Ucf+H0qJWYcXDvAdvkpooAghzOTs2q1feTE+CQT1Xd+a7HF5bwTpFV9V3vLbo/os4UxhCM
# DATA kNwS/i4mYfGUK9wsO5HZwwIb7TxeOmb9/VgRXTWbCjDakGwz8HGhXUaGVz95FK3wooq15d2YgZnsgKTsWA4WlEgp9ldhycnmXCbM
# DATA 47Ypl/+ZsZT/A8jJ8996IFKe/f7s67MvVgmXpTv/kgMvcX/FO/8FXfuK/vvN2dfe+a/Pf3n2JZ7AvV/h9j8KApNu/+bs9+f/AfBK
# DATA jz78nG77k9zqOJYvgMnmZez3T9UBRNPXI9E8OeeeoObJbnkvW8qEVTbkM7dWHuQGjDGDBxP2CMxkGjXChJUbHPxkWFoY8+b5LRTL
# DATA N0UGTFAZDmFZNOGk0d82wLJUJDdHr4QdcGx196riMQVdfio/oaqgeeJjVSVRBWfwiF0r0JJ3S4zDjP01QP8oR7myYBzUctcSvHa8
# DATA 5X3YpUdiqxh2dIW7zSEcbBoQZPosMbTfjkejeIAN+di2LDtuIs0A17fOIgqDfk7F3b9CtNypDm42S4qt61lxLXdKhANcurH+KcZ6
# DATA jbe8/BD/inhobml4v+7RfafB/dJj+60N7VItC9mQYy6fWbu5CchlIY2YkofFhGFbqSQAwU7nCxkK5ym6HnDqxmE/5oW/RaZLjZ44
# DATA OsICy0OqBpnM46keq2VuTLdlZDYj8CSmConlLyH8ZVD8S3dFXCIbDRMQ0waK/4S6epxhwxqIQjvq2PO21xWspKpJ1YKxIAtCHEuW
# DATA SEEoyENkAFY+s+o8Sqts1VEJLKfcyx5aZgJuRJSrZLBtNBscA9MxMB0D80YYmDsPMDvNZC5hD9+eaX8Vy/6aDHsHx3RwTAfHdHBM
# DATA B8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHDM5waOGbQbETO3rgjH7EW9
# DATA FwiOWVh53omMaaHe/FZOWWwUqWKdUoY35HfJ8SKyrNlt1ztrMhzYzXYwbjan1WbT87tjQZ1Z4LEyjSwHjzVWoG91K64lpNpKXOvt
# DATA TXHt99vdVrgS1yCguHbb1xXXnhXXTndrXBXMbm1cm/0u/1qMa8OvewHV3+uJa6N7LXWgM+i2Q38lrs36ddaBZuda6sCwEw7bq/W1
# DATA 2bvOOtBqX0sd6LS7/U5/Ja6t7tPXASs4Cq3Z7ozbjfqx3/5+t4THpQ510LoaxI76Ug2xk27Zgtg129RtdHeA2A1HrSLErhk1h/Uc
# DATA YtfqtFudloHYDbqDqD/IIXaNXqvbCW4cYoc9VFVZ3dCja9Pi11m0ui7bnPn9l+PSlZ2ujXyptS1OVw6Zz6ns5kttb/Ol6jlhHujq
# DATA qozyNetpBiYKasrVa63Q4eBTw4KT/KfBvxsuXDyjOuV1hQwnlaFZpNOpWrOOsnc1YpysGKhF3LVFYFx7ZX/BRticVQJbbNPVGuP4
# DATA co4v5/hyji/n+HKOL+f4co4v5/hyji/n+HKOL+f4coYvx+qNCiXHPk9K9HfkKx/eo6939K8CmmNj87PX3lHH/4bmJCQO6zHJjJls
# DATA gyie7HHoTFYT/cys9hn9b3Z/gdskWPWDArCpbwyH0eEOacLt8QmeNYHfKYfCwViPZjwiGNyZ00F0B+03H7R3B+xf4gP2l1U/fG4O
# DATA 3ueOre1qiCzyxqdZZzRCkWUBgeUxfd+mhfhsz+m/YCdWL1LfyR2VN6GNWFIhuGZhxLKOwwWqiPcVoIfFEChXqQ1lHJiRFvpoCW8M
# DATA 72DwjpaAgvUjZoOFluo3dA9oso5x2nuXriYQudfqhyITxYgGpa5A9TbRAs5yopyruhJvQPbzmXKcQ+9LhcDTqHPRo7lMK5TKdFn1
# DATA cKuSUqnJwXttwy9YdftBQiPdWJ1Wl82vWnz7wxByi0amP41OwhQH6pWg6Ek4kaP5oaqg3gQJYU4CO9DjMBVhCol88Tz0ImSR1B8s
# DATA F0iSOQRd1ihfjaPOZUNtmElJMMWGOwhswvDwZRiFRko9zFilQQlrhYyn4dPq8WJL9N4D9eYSkUMvYiJmCWnoigQBzIwKP0wVwCCZ
# DATA ZIrHaGg6HEz60DtBL8TxxWn7LZH8SF6zJhNfoRPrdijORnY2ctlGLtUqJ0vlZKmuYh1vtMZvTK7qezG3ATYSQiX0pBVsKMceWtpV
# DATA t6yJeBtwYHHuMAQH1mMaIeegUrkdD6wfM72TuZATbpv1ixDBjboYsjtQgsXrBGSvcTDxJXYJ4eUXRFg/byJsLuQRbq2PsMRRRdkv
# DATA R7m+Oc7sGrOrLqrWHr/4jnim9i/M5iKFWX/P4xysjXPrqlHWDjO64YP1PrcLYpwHYCJtXbLyem20rVir6qMj3SrEeSMQ+c1lPBla
# DATA Ixp6ixeXi/yBDMMyuodzPnrDC9h6LmXAydx78SkRpQ4lyR/TQxF4XPe9UXTCLm12HC+MRxU6WGuE5I9SFqoz4/8sOtbMKyMB9kPV
# DATA r+uuEMC1EFh07J9lg7zm/TuyFIY876Ge0epmyewfYmeQqK5pRqa4sqUj5cZCKZI3s+mBKR1NM4QDFy82TdleYiPcHl2dEe6M8BVH
# DATA 9Yq15exwZ4dvM6ufH9lYNdjpZsA+MLQFWwUeuB0aq0wrPM6HOiVRWslVTHmoMQKn0OvE3iqMOgh8LpKdGF6VExFtbiRAlGwZC2ZG
# DATA DoNs0ly9Mj05fyk3bEjg91Ep9CyCRueh4yfvwk+esQ8VT4g3dfOd4k6WKQQ+bSEna7ei5fwDxfb5JyjnuXFJjOQnmxGSOl8FInm/
# DATA 4LmHS5uqDKC0aYRiKgFT0+iIcsz4Z9kPK0gs+s8Ic2elPks1MuMb6bbZIqYJs6xA8Fy55r0VpukpRFmTWdE9nobMbGSrdZGeKi8x
# DATA i7JiD2QqEYPPPJlpP7maPNiNNF/90U0kX10yeyBllN+SfJO/WkWRLvBmX26YIRinZibyVKzQvCpfspjf2VzMulGoYjZO/3xJRvZa
# DATA cI+hC/p9dLEwckJhsqZksetVjsxC1osWgChF89KLBJ5NkpPJqUhCp6xsjM4VY5FZ6qEy5w186CDHpld8qiLcnrRbK8RCL3PJcvx4
# DATA C8w47690ixX0iJJITiOwWGnImQ2VGDiXpCaB5e10GIc0C5yygTqKFqc0ni6Rx7FyXoW6JSvcmJnM86ILja45Hy0zSzg0+D7CjJR9
# DATA buwBwwJhLMC1p26b2xJ6a+V65T74wc59MFXYBd0idN3ImzF7O3t4utL/araNFCusGhGaZiNjHE3jbM7a19773GOG7CWYhOkRZKWh
# DATA zDjLNKf+JEmlf5W2Ip3rKAQiGW6Ba2mX61P1/Her39+5W1VjF9lXkNdHUkM1UA1DTbA2TVLWvdFdJtpYFDsU3hY+HQdxHBSl4lvH
# DATA RzO4emQiqi1MOFZYGhxGZzpPWa+eel0pZo7HdbS9HRL2QnStb1+qa9Wy7jBMhml4ggbCuxMm8chaqFbONX2Hsh6iENtCKXMgey/2
# DATA jm3PYEbDhaVNnsFyUfPY5WfWstX2gEEazpHnfCRU76fQHrKnK9etKbxSid4uwPupPLQvv08xR2AOIhrt40FWRGB+ef7zsy/O/nT2
# DATA 1fmv6fMvwLMEtvJP9OcX4Fie/1xfXIfF/Obsj/T/L8++Pv8Hxl2e/x1DMf8kSEwO+vd05dfMz/yayZne+a/O/x4AzfNfMR2Twj77
# DATA 4/k/UhC/or+/pXdSCLjpF/TDH+hnuuef6SVfnf35/DcOk/lCOEqxLQ3dleoWVc3joLMD8UXxENan6UGFvx9hszu8qAMg6xSo5Thk
# DATA z1VopgjG5xp68MINxjXvnUfzCcwX6kxRWIi1MmhydeCt/My3JjR+SUtE/BxB0/ah6j7jtgmaK4VycwxNrpTmLmwt5DV15QFcIW5S
# DATA 1Y4Tc/sD/upBtGs5gUjYdQI040yiAu+h7GyMcOY3BD/oNFo4euYuZXcD5ExeJeXV8niKqS5CMxVAdU+LiI+oDVCP+Vi/90EUZku1
# DATA fEs5tgQUiukKKDnqK43vOWPOkLeIJ5FyWafsLycDabicrOI0d6uSmy2dclt7VkTN3dLhkJrOLrgJu0CzNq9iDrwSy6m3ZgpcvyWw
# DATA kyFwKTvg9swAqZelXLBxm89bm7oJDmcp+ZxouKmZXWgiU4ZvaoXiPHOO4cSYKB6nfZCGc4uXno3yXw7g029DZogvR+Mrs4fRYgC/
# DATA 9644znzEtywGilyWD/9TsROG2JcH1Sgo1FB8PQmRT9YU7AFe+Ka4JcOq8uOjnWcZ7yPzeA+X2CLaqUijEpIr/ihF6+SNEuy2Cs0y
# DATA mkNvOvSmQ2/eCHpzp7FmpynQZYzm25wCXGUGcF0TAIfedOhNh9506E2H3nToTYfedOhNh9506E2H3nToTYfedOhNh9506E2H3nTo
# DATA TYfedOhNh9506E2H3nToTYfedOhNh9506M3nBr3ZaDWH7eCq6M32qDPqvkDozdLi807wTQo9pmHRG4jMWI/zcnAqdMNenrFBU3So
# DATA +JegXeQX9oajqLuay2ACBo2xH7Q+r3a9lu8FvufXe/yn0ap2mx7Zx9Veo9qqdnpVP2h7Qa/aCTy/Q18axcJod7utXiTvKMY5aAZ5
# DATA nOl9eZzbQR5lIYtaFaPVaEerKMtOz/NbnXG3O6n6dYpe5/MeRbbdqAb0Q7tb9f1utVNttap+s1eqLX40iPwS87DfDkdhsI552FyX
# DATA lKbEfqBi3LEgjE0rKcU6PuwOBv01REa/6zWC7ufddrVJKWn0vDqlqev5Qf3zKpVFo0kp9L0SWjGMOs322ri1up08bhSwlc09q2bU
# DATA i7RIvzlotq9AauSmp0mN0ootUiPFZdDbhdRYuAJSYxB1o6FFagzbw84wJzV2hsEwtEiNfmvQbdw4qRF726vbTBoacC0fl9jG5iFt
# DATA ydhQQqRy5JdmxM3utz38S6aGx+ZGHoQeb60lRvmVzckdvf6BFb+1cwkOEYLCts+/jrt5DqJN00PLAC+4QlW5Xw6sKO6vHApZypMW
# DATA 5Qn925B/C6tVzZbBRnZa315LeBRjkdIsc758udRawFqPcNyIarywMmh7cn0tkEwJ7OLbOZxS0fAstjQZchxIx4F0HEjHgXQcSMeB
# DATA dBxIx4F0HEjHgXQcSMeBdBzIUYjGfdevCk9RNh0D/kjWjEY+PtDn3U8i5c9k3OOewkXiAp6QoFBV38VGvz2fkYyDqbAfC4GouaoV
# DATA ily5OBgRkYV4sjpOL0ftvXkcDSJ9GhFn5OA/7KM8ihzI/OSNOx3uTofvfDq8fETLHRR3B8W3624/NwfIH8SPpAlVaHyanWLJP5ZD
# DATA ljb4xhx5tERT0WQmcqgTzz5cPfWMo6Dc86qz0yOEIiczs3ASXVI+26haiuuRmzjdnEzhGrXPeTvl7F2Us3lHCVdFfNh8H/pL3PYj
# DATA +rtFM5sGxYXgDz+Sjy+CXrbJg0uKRL65WSRS5aYIRL6JU5wjHOvGoJTrQWKzjEeWO1UVnAfH6XxwWWnKcwoBz0k8khPMyYIpEBkP
# DATA TXBBIRhvFFE9msAgoglLIgePOSWaiPI02plXzZK3dsySd7QmKI3JOkPeDCfQFWCtXo4uNSa+YM5cyxIOy4p6I3iX6WnkFC+Q8LwO
# DATA zDkamvGHmiBZf7GczEdgs+vIGN0OLpkvP9qcL9KiVE1ZDtkyyevILExpTurNaE7roZ9hMCikW7EgAZmBHP4Di4arVDQTQhkECTLm
# DATA iNDnOfr741Nt3DzDOvJvdqwjHyVL1rD46fIozw+tNj3X6tPJdIRNI8A0UCcwx/QKDYJpRgpjNCRTgwazAWXcZJwsceKt5n2CCQFr
# DATA K7BSgth1R5PwZ0ao4ynVZ/Ou8JL589EW7VndqUoO0fzam+tLkkMfpckx6gClmWY3R5FBx/ImOao04XIAFY77M285Q3J1DwOBYAai
# DATA Ass0gfI+pKJ5cfkZtpuPd2w3XKmVcouFrGVFhmmyhPr4EkoVEzEeUj4jC38/qFjDoe5ZoLQcS1fKZpktxBtKdaH+upwftytl+6oo
# DATA NORmtpuEu0n4zpNwN+N+yWfcGyfTz7VkG+9jMTtahMrKu1ruvUENulzCev8lkmu21XVlK6W1OVQuhBP+VpY/W9kXKRVmkGDnkLzs
# DATA dDbQMVEnje/9YGVbpZ7kr6rLWY/xF05NYXyfFMhegE8w64UVx4ZUPWkCr/0L+UN8dJqHm+dUt+5FknPaUdjWM1uqpPoWDAezgWqL
# DATA ofYv//SftBnBrxwHImUnFqS3iCYTnroo0IQoen0P9mfmHYmVFS6YFjGEChvNWMbLaV8XV+il49PFeKqsWTZYeW5wFMvPYvmxGBmm
# DATA zRA1szS/PN7zCJEuJY1codxKo1xwzqgB6hVowQzl6IqTMF3R1C0WKEONjOHIxKpXUFbLCsZZbc5q29lqW6lvbu3ErZ1cwWLbaBze
# DATA pPguA5pGSkefxdyR17wQX9DgffaC8NsMAZzz8+y1lpWlE7EV2bYcFq4V1jRkqZ8uv0v9L5/95ive3mB6EeheP2q6M3PBrDDIAZEy
# DATA Mt4vgu5tZHy95m9ef1EbCuzIyqVdYmseNtHNr5j49q4zumrjBf3+gdb/XSSLQpXY+/ZF0TaBmGjnVy7I5roV78bWaCvz1SyYya5U
# DATA XuWSKh/xFg/TFDILEYUadu8NOROs4qy2J9tOtfyS9D+xoKrmNHYrI/aOBPGU8CexrRillXcBtir1DzOzvwSNzxi3H4gz1Sg1M3L4
# DATA ZBxPoryfiKFWu8BenZQlb81KB7XmKBdvZnlgtcIJE1c2rsjWNzJ1S1VA77TyhgrVZ3oDrR2MLtXqeyhVyyndj+3BeTisJz0IZ9AO
# DATA nlMCYpxTDNM5L/Sy5xgocrgrT8aRGPB5x4WUQWia+zVe2CKjo+YpmB1SaISms+Wcuh6lH1wUl77D+f6qWM8WhIvn6DyHsDlc/8QM
# DATA ri/Pfym8K5Czvjn7Z4XmApwLLK4vVglc/41u+wqALkFrnf1PKxz6xICtP9I9GrL15/PfnP0vQ+k6+4Ju/Irf9fvz/8CELpx08M5+
# DATA d/bl2f+kShNOHHDrhbD/2bi3tm4AFZgmwLtO0U9wfTN2DJNaM8iTU5fE6n3UM85E9fuEdcNl6ULLblcUN/QIjX0c9tFPyWxd1LC5
# DATA zkDsvB9hhrANtvUp3WUi5FBbBdM/7xlum7ZVKpWbY20J7dvwn3hLtvVW686fZlTc+sZiBbtOxFYoYCsNV1ALhJIYh9e6oLiuHa31
# DATA UUhGJ36mWLfqlXq9zqMGZQB1UTXvIxpAjNXDBAuedI3DOdaC9c7/Rdg/RCQFR50ZCAWKK3pEAwHOFpQZWhdWt81mSrHxPCt41oUJ
# DATA cNwsN7xf9/CumVmXH9VfDWfeLY7o1z2g7zSe7zyc38poLrWxkHTbR/c8taGbYGQVEs6In0wx2+1k0qQ7zNSi2RCLZn1Y5iF2Elco
# DATA oTGQPtRoYkrCJAZLajbUrx2F8QT+ykEIVhGzhYrJwmgbmoye0gCnF5jjWTZHkuAipRayKy0rD5k1AzJ5H8WfKU28FX1MdQ7uFbrI
# DATA Z8r5tDn7N2ZY4eM57JIJUfNQHLDJkJFZYhZk5qw4pejBKRlvj+Api4ehOskeiWEYZdiHGGdjrGOG8GoMhLuCdMUjbEAcjKNp6PHO
# DATA d6ZwzXkscigth9JyKK0bRGldOAbtNNXZ0Xy+vVnAVSYB1zAHcOgsh85y6CyHznLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyH
# DATA znLoLIfOcugsh85y6CyHznLoLIfOcugsh85y6CyHznpu0FlBs1lvXRmd1Rx1Rp0XCJ1VWHXeCZzFGctx6XHGCZqp7hfkKNp+t5jh
# DATA jV5vc47XG73mKsipFzCSSgVlwaU69W6v118Hl2pIIIM4ZQkq9bK2xZZqcDz5wFy3SJMa9hqd9rrnW62dnu/1e+3+uue7zV2e70b9
# DATA TuiXM2EaNBteELSrVLFbPa7ewbTht6p+4Ht8rSrXqr7fqPrNTrXT8fyubwfNG0ZLeK7usDvsrctBxoWVan6n5zUbPlV4vNqrj3v1
# DATA UnAm71aC610BgcVNSCOwpDVaCKxGu93vBFdBYNWjXhRaCKyAAurkCKxgWB82cwRW0G377d7NI7BoJlSl33eatAcBjZVFv1VhpJER
# DATA T4fo8QE5w33SNpwyPnWCdQCpdq2sC8RbTh6XXCbWGLByd1gy+40p3lWmeP6AHrXL88B1cz7tJeyyl1BWB+EnXLPY1i4morgQIHNE
# DATA z574KEMuf8IMg2tW7MoYrrUeH11Rix6GTdAu4zxW0YHf2Jp+8fcL8qn4ojaSw37FwtaTzc+bcfqC12yYwm3GepkKvhOOa1vl3Tyt
# DATA L1XmdXVyOblwcslRcJwvx/lynC/H+XKcL8f5cpwvx/lynC/H+XKcL8f5esU4X6gL6oR8NDy0qV8LLJlyRiB1d6WuJ8t0EKGCcK06
# DATA jEdsZKqGea9Vh8GzGANW8E6aJojj28ryQvMik4f66PRI+mTz2rslY9qaE7AJW8HkoiL0L2xr5HLYF+aYCYS+U1fx2Wts14h57r2b
# DATA H/0nO/o0W9MX7B8+YRv9cR4bbLUcxTPKDkU1YxlRpftwbAX/Fjofaq5wqVZwjnEayhkqLnW8tY89yjS/5BdZ8VOCutTV4CTUh4mx
# DATA T70TnFlU1if9xhGkas25j1M7Vf0j/fLdbXYHlyGVT56uu3nK9h8XIiNiVCYOWqRRvQmnAREPsfoPnxhj/rPXTOA1xI3eai68Tn0V
# DATA KGx0jVp7fgzyjtyoc4PPHpXTq5JrKtvW9sLpXFd4uwVDkzm8ngJie1nybE9s6MEindCU72//Vr5iMyB93f/rv5bv9Cjl6WevvcOI
# DATA h9f2H2+wvJXRTV1htnjAFvueFKqTuHdqCldSU3AqCi+3isJl1e2fqbqCccBKikSsz1JyX4Sobvc+1DLcnFI+yLqEtGW8OSFv67P7
# DATA ufKAxBIPbXvwAbdb3uaFRaGNTxWyQ4wFq+3lT91BTLUOIR+N3Shwb0hMSgqBWvV2cfvnTmziBThczf+9ZnJCURTjurkJZa2RtdSE
# DATA y6pkfZrGynSLZ8xqJNsNxoxRyTI6IKxclsECPoGQ2XQpGg6n7KeuGAF9qYyq8nBFwSiZiaK9pekBjYOQLfpktGC4UhqxG50JXAq4
# DATA xYa+xwuDrDc+ix6xj1cpa1zIMXo5zsmbEJxx54y7nYy7klKO08xymlmXsOo2mo43paX1ngg2UcVWc3nlROBqnpN9blux8TZE7pVn
# DATA QWeuTvobeieGVhzXt0E1XTxluMzOsoLAOmXkZMIebQYgYK2YR7e/hovpEH2afDpQF5RFLd8q8ofd4uq2H/uVoNL4CQ2KOkYbJOWV
# DATA U43e9R5/4ipbRBCbW0zfmj+0QgAOGNlwkni8lWQLeLgphje4h6U7V0DBG8XkjQ8rrzovro48pjwiL6VspHUSZ0sjcDaXVlNREmb/
# DATA JjwOH0gXq9TMQFjRblA0E5UPrPd2MitqoYlqVghIi+2SU/pYNGBC9EwQSZNT5Qg1zR0KVyLARU+f4HQXD52sOWW5/2qeKS6MiGQj
# DATA LweLpaIwTeIpLvJGIwhWQSSOaRfQ7sp0VEoVIZ+K2GZyPrWQ0iq6TjG31Cv8xnWo5nym5lwsO/9yWKj5MONMVGei7mSi2raIM1Cd
# DATA gbrV8HzWYq8fFhrJDAPdIp7mUKYHskzKAqgViwIoqfPe0TKIEFjE8R3OLvodTWWY8FgNXU5WCw2PKF7YcjY7NXqQOyq4cnRNbIQE
# DATA RbUAgo5iEFBjpXYfsb4lOo813jp14niNpSp7FFDB+JOiAylLRv+YG1fmCktPADkfcTgqdrLnxnRLm1lFZuMDQ3/kc9GutO4wXaL9
# DATA 1IrJiJ0DGB3RMcp98TYLEy1S+5I332Xp2ArG0XzdEnKUxUec9rf50xbbtcgGl50EtsGiaOabzMZCGWN3tTTWKwDYdW5cEsD++Mlm
# DATA ArtkrBDYMYmLNCNdOe1PNYn9E2wZpZSny0y2e3ENnLF2qhLSxRwIZE69Ah1jE0aIDRRef0mGrlJMjQc17+2YBVaXLLTrTeOMZ4+y
# DATA 1wXblZgiyptA5Bq3Vl4ZFhIDEET0ulTx2Z4abV+qQZfM4H/5hz9uzuFCbZSMZknXNBLhX/hV40G8MMh7/iWnL7H2LRnVoqWazPWp
# DATA +wXVtpR1fHF4dRGLfX5/xIfCaW4w7cdHS3Afleu3ors7QUUJ/TEkY58lfOMh/yYT9uvI0SvW1Wm2W139MJxKVYCUdZ51UlswxYGC
# DATA rezzFVVb6FRPogWQWLK7yTztMcYDvReDPk6BlhVa1wzKgGgQZP1RdKj3pKJQGxRMA3n21e/fXqryCeuMY0+p+HwZLSOdf+9jBodJ
# DATA G02gcyXmkzBmZw5fUMfNIwCg35YGyWsSUnGyvKJywMj6EY4WcH5SBs7gQuKAFvIUML0RKIo0VKLQrqXqma79khn53pa6pwYJycPy
# DATA CqW3SMNjGjdPKA06Mz9WRwnGSiA7lGqZkg0TDTNlFFAvN1swOA5hwS6R+Qk15JnpGVSvOqVeI+O5ZAyJR2tZNYfLLWIl5x7R/Fer
# DATA cMP2e6b5+smu+foJE/is5Sqcb8xbt1oOS6Mj7AeXAyKUkEwNGRhtcvV6I3mesa8itwyj0Yhz2O4Hwn7G4tU0Q2P3jtyjqjN6U7H6
# DATA YnS2P5XdrKUMLRoJsmfRNhLMFckesmv17kI9sWNni9r1Rx3RYJxAPyuEv5RKUhfEK7HwZmP0qCQim6D3n8++Of+7sy/P/tfZn89/
# DATA C+7d+S+AxKP/fnP2u/PfCBrv92dfnP/87Cv8Pfvz2Vfnv10l6tnhMCvvF0zjw7PfnP8aT519TReZtyfoPfr7J49u+fL8H+i5v5z/
# DATA Ejg9xKCfRidVg977+vxX9Pe3+JmJe39yaL0XwVsjNc3mzcuU82GMVjqTbcEgNvzQ+GZE+R7mGFkMQyj9sKUg6xv4/aHeTpJGg3iu
# DATA bK5sif6IW/s0YbH+rSS9tyReVgNyMD3bS4PcuW2O3mqZ3BxKT6pOvpL4sVQlkTwp34yeyFpzjE5uhJbNO6rn6tAFZYVMGPG2aTRb
# DATA Op7eDmV27Ug9Meu5L+euB15m8Zv1yYDQvZvY89yNfZJ3S1RdkxMF9dGEc9ZZE/QvHzpAocXTKc7oACZEhW1gxJeqf1swwOVG9awQ
# DATA excnwjH23Dj/lOO8RupdaXh/RRZgbmVov4GRfaeB/TLj+u0M61IlyzlgofWeZdO5CZJeOal6UURcqiHLTZZGxMweEhH/lTGxIlAs
# DATA WZyVNVZRsjiOFsmcn4kyPtCekLm0GCfDbBdM3sfIQ1nGKseIshceAt64S8mfxthgkpBVhj1bMtDn1YXeGWbLFGCwkAVGKZPZn1/R
# DATA bvs0QvvhFJ1yyYgOjpAA4VhhUp2uDFk4EdzXAM5qzTNzNDxHw3M0vBuk4e0yeuw0V9nV2L1Vu/0qZvt1WO2OiueoeI6K56h4jorn
# DATA qHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4jornqHiOiueoeI6K56h4zw0Vr9UO+o3OVal4o1EvGr5A
# DATA VLzyyvNOYLwC9a3Rs6hxjXrDUN/8TqfIjRsNuj2VNxTBmEZWE0QjD6LZrOdlEwhtTw5PBb1CeJ1mMGgMVgoqaPleEATjoFM/9pvN
# DATA z6ttr+dX/UbL6wX0p17t4ku1F6wpuVU0Xyug0Fr1cbP9eafjdfxqk+qB37yAOmcCW8HEBZ21GdC1yH0UeatyNlp5BjQK7/1WcxC0
# DATA G/WVKDfadc9v+Z9XKa1Nqi3Vjj9tNSnun1eDnr5y5QT4wRVAd9wqNOhOGpgFuus0G41mcwfQ3XDULoLuwmFv0MxBd512q9duGdDd
# DATA sDOo9y3QXcdv+M3OLYDu0KSq2+0Nj4cX69YyH+57EfUCcViRgEuLeSuouAYvmOXLZcWgld2y4qTSObTiiCz5++2w1nngLzWoeux7
# DATA q7PhpJ5RS2Brk27cqquRNGZ5ESGnwhZ03fqtAmWi3SpmbW3OmIFPr37Vt9HgdqgFN2WKOLSbQ7s5tJtDuzm0m0O7ObSbQ7s5tJtD
# DATA uzm0m0O7vWJoNxvmJsnmA1t3BaQ2xCm31/a/I994yZGxXAp5lizCidyPFvX6B+FiXOOZ5B5f3H+dcgDHUek9yok2h8bMcs637xXe
# DATA cUe+0Y8Z9yKL5F1sx9vz7VA+lcNkViDld5aC4WdXjpxpgphMAc2RDneI2h2iXneIunTMxx2ndsepL3uceovw7U0ds5ZWwHYw9Npl
# DATA ldUcs36GQh63QV0YquPZqmbgq7d3tK8kbXWzm7EDIxeAV0/lfZP6njMLiiyGacwCdC2FbWDfvyw6YYsFr0XV/M3CtzKeQorZDGso
# DATA Bhyqlvy/ILr6eRNfc8FE2G+vi3DXinCwe3x5UAWljePB0aQrF0RSPZTr9qrvBQ7ESgx9K4ZdO4LF6G3kPbylWlRkRINeXNzDW2zl
# DATA 8TDGAC9MTvSB5PdGUNlEH8LH8DMe6ND2MjJL5hX2aVIrncDrPzn1oKSJShaDlydGkXjrhc4ltY7PjVMzVCEOKQgKEGbOWAc4SGD0
# DATA qJD0cXDmT3BNjrIF1t15SsUSTFO2iC0RAJwGZwVGXkYd4iSZJ2s3h7YYAEw29H5ZMo10R/Q+zV6OMUMaMwCD2/cAu4NVghDtvK+5
# DATA GNDw8hwsdpBYZ8lut2Sd3fqS262XhcI+c3kgXjC3FoJXjb5JQRKQqT8Zi24r/kGfj5HCFNnKUH3mqkIviALHTWBTVxSQrpucukZN
# DATA aj08dTclxFL9Q1bbNAUWkX4zRVrVsM6q7bmCNO/p0ROhZSZwKs1PZVsswjxreFqQdAk9bJRYTpV9hgpGH7JIGUoITGpS0UBR6OR3
# DATA +QZjlJQluDnOH7PYq0Q5oizWMX7PTNRingNSVEXPaBGnFVZm59hoVfaChaYV7218ABukCIqsABzB2BLtj7Awtz3WDwBdUbHmbUrR
# DATA UEf8HS1xNaTZLWJDSeDcq/CUr+KdYrOsqDqhx1gkRxFUrGqeZVQnrCw69RhUoKgvm6KrX7ga41dIwMbuk5yl6SzNdZZmYZxyHlPn
# DATA Mb3IQH32wpQSg0wpK6ZJMmWVOm4QuTzlZCJNZa1IYk3V84o4KyoyGEF3Ds0I69NMBWPPiierd6pd8TLi5Shg77KVoNQdpU2q5UYO
# DATA Ez3fnLGbcAGHE2xgEIFsBwXbBQomFpdtWm260/i5me6iv2y+X6t0cq6qz5vv1jKeRfPj+ceI5fl3SY6Lf+C3N6NcdGEIyuUHs4g6
# DATA kzm7Fqs4sqgtQ6xv+C3vyF7JCJp1uqDciJ9GikBGUxBslZucVshux97fPtWLEb4uMF4iZOwhybDmIac6Mu4hYGydhNlYtFS1hU6X
# DATA JpPsOjg4t5J/n5wknH9DGqfmxdxr1Iu51+xaufeAF2qQbO5rVSZBsRRA5wXLUYo0ptwlfuFJBHwRNut66hCuCJVeQ24V2uDlM6y1
# DATA OcOsBi159j3qUyl276Y8lZ3LBCbPt6BU6xqdlpVvC5hSvEzGhlM8Wy4w5EC0dFKcWPGIwbAeqnk0u1IUPDMJO8aOxslzkHftS+Td
# DATA W6gCqchK5OuDhewrVbtGUC9lX4Wn0myiHklRZDRPFaVUEPukNWI/+jANT7CVVy8NsN5svjTwNHlm9+GXzLIPNudXPhoohF/yMNTW
# DATA tc6kd5lTIdwIoPuEXnhMNocx08nCfUgNb6LQTkNWHZ4mQyb5eWOsA3sfi1AwM61wxSyfmFWZjAZ6ynXW5EWLvo5sswezS9e0YHPG
# DATA 5QOjZJxxDBQNNJ2HD3BVeV1mnt+lGjbUeRV6jTbvGaKKim2B7EKg6ZJyxIjtxhh5rmuJd7SMFd+LubHKe8NmI285f14RXi+LQyLH
# DATA eI3iBSRmbY7X/3v21fkvz/589iUYW195Z384+/3ZV2f/4+xLRm99uQrs+i/00+/OvgFj6/zf4xZPkFxnfzn7I/309fkvzn9TQTj/
# DATA P3tv1+TGceZ7zrU+RdkTju42ARAFoPBCqqmlKOplRpJ5SNras5ZWUQAKjRIBFIQCutmWFSFbM2dmYhzHEbsTsRETZ3di41zszV5o
# DATA 7NGxLFuai/0C3V9hPsk+/+fJzMrCW6Nf2SRTNkmgUJWV7/nkk5n/H4VJYX1Hv/3RO/47/FSkO76h33/Nb/rm6Dt689fHXzAeDMgu
# DATA RQD7NX39IwVIPzlm1/PgUsmgfugyhzYPSPqQNIYPlJqkxgVOZp0pq99Lh0IZFk0FvriP6V88FBektFu4UHs4fQ4OABRK+ClwGHkj
# DATA Km/37CiN/CQcrMV43cfKeDc8NDF1HC/b16I6iKsGeS0plcsjealamC0ZPVLVchBTPCeH8/dLbdQ3v5OrpBcJ84LLUMVEtPBlZ36k
# DATA 4+WAXpsV3YUzvR5FGeggY0FMAEnVXZahcnDJeSl6G+wFEhlhhiqYU8Tw/Bzia8l7O+7q2TH1bjK9FueUSukC2evkyrjanllsZc8K
# DATA 7XVyKhzay5kDF28OaNrX2ayAl2K15aosgMswADYa/085/F/N6C8VcyEXLOjXNWtUl8EBW0g+oKZYG0qZ874+ZQWugVC94iTMp/Od
# DATA qdoawVsgWCQkDifmTTooTrksOKE4letgIzLYY/b1wh+EDTgpXG/RJBwUlCVHA1rcnaH4oi4XI4y1CdUQXkPuZpgnjrA2BcyOEZgH
# DATA FKi4POCcojYO10w8KlIWM4jdI+tiGo8i7aji5TOEjmVomC0FsVnoxWKHGBCUo4Q5SpijhF0eJWzDIWejOdCmpvPVTgPOMgu4iEmA
# DATA I4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlS2LUhhdXa
# DATA 1S7/fCZSWKMX9NrPESlsYel5I1SYnS9+4FX9Zj+ot+ZoU3XqHZvRMtpUtSk5xGUkZVBjRUohZfl+Tqlnvuwqvl149Vz+m3fmQg9a
# DATA /iWG3qpngddaucAlVVngfrVuQ8Bygbd6zXa7Nx94PWhdeOg50FtNWGwCKfPrGegtaOYCiIIwbFYXmgU97vl+c78WDCpNz2+cQCBb
# DATA XScaZwCQcWPTADJptzkAWRC26hsAyHJXACALup1eOQOQ1TtB1CwbAFmn16l0IwtAFtQ6rdalA8h0A10Lnyr5gaaQ5e43o6NeIAg2
# DATA oY3lg9C8sawf1zm14Mi0Hm1jUWbJM5suC5TqygKp2I6HSmnJmrDPBlHuzTmPglgGeI7nL8ab5AdkJ8CkWuKRrBiPpGTK/DLLkoW+
# DATA YOEFldt6rkW9t5/ZJXPRb7I9t4yL1mq18jQ0rDKvppTlyq0wVxZrrJ38jXO+B+M+dBgyhyFzGDKHIXMYMochcxgyhyFzGDKHIXMY
# DATA Moche8kwZKgLFEp3EBUiXibq7pYL7HTnT2Myu6N09+cfFeBQ3Y922YItoKN9gJ92USVvmwrNp8tgHU22dz6Le9vy0M5nOmhqoTBB
# DATA wlEnKo3IQt0pqlfdtoO/zarO+uDGtkRv5za6gg+3HmfH2LqCE/vcmuNgH6F+v5Qijn2seS/ST09RUlnJgybGk23VW0GfWNJPCRh1
# DATA b+yO1e799Mcw7G5T+hD4q/Tbzmf89O74Np/JoDjRjz/gaxSPpanJJdhk/W2T4bel1mFCz40+q2GU528qfWfKe4WE0yd/jPKz9xiH
# DATA pPLnLycUfSZ4UH7EiWSf2PK3P1/9Oia9daJ4sL1NSS0izTs32bQF5E1lCcWEkmzqBTUkTn2J3bg7n2UVxroscbfvo4yzuXhZDVKx
# DATA RK5KDqmxYOezLMNQdCjOmLIxflWR81jSDemMb9zQN5fGMzJNPlMxvyV34pQd3VfgiNDE+gOcuvuPL/5JnWkENi++4e9QF0ORWAi+
# DATA 6O+sCRvHI+2wH+K4JC9/LIb+eVYXPld1hCeTuk0uVmX1wO1c7b8t9WwXM1hd9awbCpWgnG9Rk9lIpISF0MfVgVsZXXhtnYGbtXn1
# DATA 1ARnSE96isvX7i6smp/lwFw/s65JPITKatYeVKIQFZ0kMwdcEi0+gxIPaD5k+lRdA81jMlbs5CJNwR7EI5ouLgsUK2n0UDSXSY4Z
# DATA 43Qmzqgz4fQlXnx9idOSZK6D7gSvrOT89etxMu/hEDyIHBBf1Qenwz28apoMkwnNzNYyZa6jaMXzc4T7MkgzixobF42aWSZickbW
# DATA jJdbIpIqzStsd/yylgYWzKaRE6OXqVsg4Cn1JBP5sIXen5BVVhDXk2jZI/LG8pbVvGSMWSTgesJ66M8mU5b6itV7xzTyj0Q/IVFS
# DATA H0bEfo3Qx0nKoy/QEf1cw3EmlDOhNjSh5vpXJ9rlRLus4Xel8XUdxLxen8VgauVlq4yU11uiC2U3JYw84yhBQzvoJ7kRShACegAr
# DATA eXchYoOiY02dUObCCj4WPaHmGA7iHhRvILoN54NISI2iqKsxY6flp5iIKuCDktOGtHphiZKWg6dsAk8ZJlJ0rHevPq8DokzYjSYS
# DATA +PJ59d3Y7SPc7Hv8afWd2txRfCH+/DygU+zcO6VKfhOG42qd/KwsciwL9uppcXyeFWUjG8avSTLb62eN4ROGvbOEh8YlzUZkPLIW
# DATA VbZhGu15P4lZ26rD5qGnT9DDapyx2NyY5XthbFIc9qLpRVAGzpF/weny740ofeKxs91CC0AbV8GdTHpZMk5c4SnzDG3T4SAcPKG8
# DATA 0vKBHB5umw2A6WZUoxeNuAxYvA2nILzubKLFdWmQuhimRdYMTwtnqKzPt6xVS769TmO87Ptjps4sNrVP2VZU56JopZAhVo9GYFlI
# DATA XrI0nSwmpIreFaXTkvfXDMSIOv1R/OksMgqKVElpQgdWwrSPaUc/5JqIfJ2qinsBuZl1U6fNyxPqoO71JCc/oLrDKohaqtlgSE0m
# DATA URq5CrGFqlCjBglPFm7nCaQg50xZlXshyy4q5N8gUpNMznalIWdEvXv5YfhZteD66Vrw6+GA7Qg1VYhsFg2MA86QdDbGBIwSGE7a
# DATA h2pu0BGdRdnpXPJ4pQa5y3LkE8V2o1zrRRFEFDHVIosiSsdRJ2YirKhfTg5Zz9BMwkfRwUXkoD32nbYCltdnYTaUKtgKKtfEXNQU
# DATA XJp2DblrQ2evSD1mGtYJQeWhjDogAxumOnZQeH2yCFG/kGWsAsrCh1SpoQO5j61iao/NtYWqvECujSwI59dwfo0N/Rr5mubcGs6t
# DATA ccY1oZUukEvTKFdVNkd/hSlO1dx4N545K2Odd4OZjCs59rzRm5c5sPtbnVzU18ykl3c12COnuaJnvZxL2flI7Ayhb0mvJ6ZB2BW7
# DATA IOeQ4F0t9DPbSKbX2VbbU3aUX0S38BFv6McrJFLqadMz6u9mnl+V45sYBiZk3JPxwmfucHEYPpU7ynJOLhrz0bzVvhPeJMMpscp0
# DATA 46iqp01U9XcT1cqJUfWbG0dVtv0gsvzppLjp27PYmSsmfrVl0fOt6FXWxE6tChp/lpwL4OkfeHs3eZ/ikExsuZHNj8nwzqsirZBl
# DATA IY6F2HUwu5Src2Ma3KdyHPemBJFVZOObsdqHubTCgSMmEU0Gu5apnVP4/89km3b0BJUm5j2MkgakI1OGg5CGd8B2xvQoGWiYgSkq
# DATA UDaL1UBKRSdUky2hpJq9vxbSEkNyMigyzJJ3bNFbuuBhJkIThRel4HXjX/wixpDC7pXRLIUgf3pItm8yTDMvqh2zfjQYn7BwPFeq
# DATA 2eKx7VfNloEl/2XPFj3+AB+yEj9TYLKVSxplNLWqj9iwXGIvh1VusQ5nE7KJyaSzaYf/jeGFX4M2mGcQHv8Gfy/SDv/56CvmEf7p
# DATA 6Puj33vHf3P85dF3R98e/xd68nv6pLiFzDgEsVAC55A9BiJ+BYzi8Rd0w++O/4Ee+ha3fX/0bxSOfvL3R98Dl/gNYxApSMc8fB5m
# DATA GKZ6ZRMLrvAgniBH6ZmC8ldyh6ORGCycZOjOEmGyiB5QKQqNAIaVIXhQT6qNnnEcdWg2vg5u+FBvY6ABgNFqDm1oTSZ0gV013HCh
# DATA VC4PbajqiL4NnA1N3OFfFu7H9hWrw32U9NSelgtHG3IEcmDDOOXK7rCGmxXbhWMN7z8dD9DLhNoZMky6s0EI8noyZc2ekvcB+n7u
# DATA u7J9Xrz4hY3x9KzZ/0RxmA25p0xlGxRcKMk01GtZ4UjQMQtAw5Or4GqrZb5lPSuc4clpcDhDN9KfY6TX3MKzDPAvh6fwygb3ix/b
# DATA NxraTzmyX83ALtVyLg8sZuGzajmXASecSyVWAEACUpy/uGMlVp9znE9QKC5NBZUDbU1vok5RPLz5WrYVa4luWEkj9orO59uGRELj
# DATA Zc1il06TDq848nisUXHMj+Na0qW59ig10Y9mk8QLh4x/4yE/IrMh7sRYGs/ZBDkLIHqKg8UIvBvBG6V2VKu1QrIeqDjfi8IUEWLb
# DATA rjOFK0aMRPbqCKVO1tZVUbdnh1K/HK3Q0QodrfCyaIUbDjUbTW02tYyv0sY/i4l/ERa+YxU6VqFjFTpWoWMVOlahYxU6VqFjFTpW
# DATA oWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpWoWMVOlahYxU6VqFjFTpW4bVhFQZ+rRZ0zsgqjLo9P2o8R6zCuYXnU5MKA9+r
# DATA +uX9Yqv1qd8oVhteI6C/+9Wg8mmt5VW8esWrNvZbrVwudfx2tdObx9hRWPWlGLvaAtlQTvoJwK+VB/gFVX+O4FdrZmUtx9Yygl/U
# DATA jMLOIjjR4gM2g1zwlWorH3yrujJ0k8xc6LVysCb04Eyh2yXS9L1arbFfaw2pay3WWvu11sY57S/CCBu+F/iNfj0I5kLpBJ12u7MU
# DATA RXl67KC0G40dlCZoYQfr3aDZ6J6IHQx77V49hx3s0t/dioUd7NaDRmCwg+1Op9auWdjBSlBrVi8dO2i2qUH4f2+j+foabp/Yt96C
# DATA XaTN8bm3mYFSTb3eiqi7icOCxG8pwDBQK3GVBVofFhYXXjDndreNRl0g+Xk3mXueDzvAq8sfO0y2TjfOoUCbTsgUMXLzQd0J5w0V
# DATA CxuYj6y9uUCP6GrZq7zM2yuLKfmkVeD75L/UH3vGvZ44OJethfk8WWO2rE0y2xMOOOiAgw446ICDDjjogIMOOOiAgw446ICDDjjo
# DATA gIMvGXDQ5rtJssWLIaQ0PiqO6O/8uFm+USkXaGapfjrgItyRKZvGfN2XQzJ80A2N7Ab/Ci5dZ4iAI+//+z+8VhnfulE0Ln1I/41A
# DATA W6Nw7+yWX/tw6wPWUudzdLxQg0DoRwmixFMeirCEZQ7fIC5e+xD3Mh0vbKcIccc8hU/8rnfso2ySOi9Kp/AjR7e8//j1/4vILKR9
# DATA u1op35CrLO6JrgFBapSZQ4i5s90nne12Z7pf9DPdpyWFXYez3nMutvWYsHfRNMwTJe89VHtb22UpHOyZng5/fo5GXgYFbP4w+0Uz
# DATA wBYlAc5KAMv7a/VZ/XeZ2iUVQV7Ti4yuzRtwPYZeN6Ef0gM+o/0ATkhULZYC6ofxpOQ9iqfsftKC71IBRbh8Npbjyapwc8f3w0zK
# DATA aAzRxqTHZ5Ez0Zw5hZuFcn4SwVQOjdwObKKrV7p5RqdgrRbkjCFnDM0bQws9qhO9caI3J5lR10MM54HUVyZadBODv/gkaRtFnIdG
# DATA u4GaYbw3UuQvpaGm8JETGhY6ELfo4WZRkkhD4FfhHtV4HN6Qz/IdokMDN+TA1m5ZopmyMfjrMVRn4B/LlGxsHgz7LkS1w+G+NsN9
# DATA UVKgT6KSPuVWsxr2xW5HkYXmj6vv5e253LM85k/PA7zLyotTclcereEn6VwV4so9tAoqXbGtBLjy+CARsaZkBsGYEHIsAlkZoqVo
# DATA iUTU8JC9UCLLJOYhjWv78CL/AvIsk2FevUhUisj2S7LxLoQgDNWOUDTqe2wo6zOn0mjU7GC5sPOiALRZeBObJEugyTEt5YCxAQvK
# DATA nDH0gCUIfT7+1ZlL7uHGJfdQDpiLla6L7l3YIugIQ2YDUHHsKfXvlElf0ZjVcRRLKI8OQ/GxpI+ofVMRyCT1ruYzwmOo9kVxbzqI
# DATA pgosMFFxScfJ9PxFlkvZ1ZVZ1pucssx+so5WpvolKbOfQIAI+dhOKEI2IIqlifQ6ihY02xNGFuUudeK4mPTIGjE8rV50IJpTenCb
# DATA iiQ87pTFHS7pA6a/MXPFNDou/fYsPTx/aeXT9BwU1/sbF9f7IcDtvJhBfX3Go0r7oqVvGgP1envwhz+JDsXab4dQ0PL6yVAaFiYH
# DATA Iw6NNepGHhXUBLQwoHLAq2IHfC9+Kvg4hiZkhTkv/Hb+Qsun7MoKLRuFT1lmj1eXmR7PVa8oyoG4lpWX+COwDx/DADWhVFiBA3HE
# DATA sDxyR40T7I3z7nL59hjfRZ0QRMgw7onliWNT3njGh+dYPGEEtMsF9HtZ3K9/iVQ2LZH3I6Vch+Fjqn5ShEs5HxTpAUaak1gbItSX
# DATA eHy8Cy3gUAQJBQyoWg33bzyzRgAwu3koi1NtpKB0Rf/uAtrMYkLOVExXS5g7F8bkZfCzWUE4R5tztM072uwq5Xxszsd2xsXGlT65
# DATA SxKclim5zPQwAqJyw8Y0LrZnCDW4JPJczpOl957A3udN1lh+avK+GZ4Jq99PAJ1loZjuyrqUUeNOQp3VN+SwHWhvmQF38bxA7drb
# DATA 7gxPBNxJABngTn23AHdLsXG+XNbguPLGkDvZzQN3IT4IY0woyFAp5ryacyCqBzLvoQ5hwWfXKDP2C9vavQMsZPL+okZ5tZfP9/mR
# DATA x9FT9ERd6yn6Zc1jNX7sbbr70H6mVl7jJlyJqNOmKXbTkqU2fX4hdbbr7qBPoXifkOU5ig5LtuSz0nWWTgAOoYPE87mlhRMFi9Mb
# DATA 1sY0TVKmO1adqbOgOGF6xQM3BW3c8eLQ4L5FPPbK3a/VtfnFatuZx4BLKrBqpcz1zmrh1EfNNPxS7cnt5Gsq9KaVDDuFolXYC2Th
# DATA P5Wub0RxHMhUkVWzx7MJQO+ysJ2krJ9qCWRvAJF7QYznDCFHvUjUmYS9qYWQe09fKx7/7dH3x786/jUgcke/X0TH/ctS/Bt9+Zqe
# DATA +vL4i+Nf4bJH/3xNF3/Hf38FcBxd+fboq+O/M0i4b46+VgrpUPgaQzuVhmyHibv2pj5b5qFn6oz3V+F+6N3vxnIWS0Tv1b4Snv32
# DATA JnE06lIHwt8Oksmga6x/eL5nY/GdwpUgrrPBIdN1E7i0hSLKToNsgUL1PHgqekoNrbsWIfc6BDRYa8Ljv4Un4Thy2YzAdApXzZFb
# DATA XjSXB5PrU3SYXJDBqbm+6usnweTuhSIJfhlAOd58RbYj/UtjgriuMJqjwTig3GZFd+FAOcmzkM2cETo3mVeZ6ZQ2bNRkaigdFFku
# DATA uqLwAh8Nb+h32drem4XUKKYR9W1vxOmTAqwfevreg5966ThSpAwcf6e0KVWYGdtAcC1ON6DNLa+jq02cpW3wumDnlifGoeec9XBJ
# DATA 1oPG0p3ZaHgpXIhXZzBckr2wkblwSmvh6owFqaTLMsMYCtezoV0Gxc7KBoDmsEjcjcbgUJEpYwZqk0M8m1+RLZ1kOJyhu8YC3juY
# DATA QXTYYcGSIinlSyeyR/xJxA4K8f4hw1K12Z5Geioyvt6LJ3yKNk03JtwBpJUq36yGiVGG7JNFOBE/h/q1R3PlmA848I6g95JPaETz
# DATA OHkdysCkNy15D3W85YCCgoXNO4EX7BY5K6ARZEbTgklmyA/o4kA6uE+ZHHfEe8xpH4m7hvdyRiPm6OCEPFoXQGSqSlCuOuadY945
# DATA 5t0lMu82HL3OdLBrnVl+5TONi/ConnWe4QB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDn
# DATA AHgOgOcAeA6A5wB4DoDnAHgOgHdtAHgVv9qtVs4OwKs+VwC8ZSvQG1HwLF5cJcPRyWm0LN8bcwqlQTOXXbWg1QiiObJapUIFUFtD
# DATA VrNe3Trzq5uVdqVePfurK/Uzv7rabLRr3bO/ulo986vrlVa11jj7q2vlZ1bWtcYzK+ug9szKuu4/s7LOtetW8yozPNeuT/fq82Z4
# DATA rl2f7tXnzfBcuz7dq8/duMrPrKxz7fpqyzrXrq+2rHPt+mrL2m7XlaB+lRlut+tTvvq8GW6361O++rwZbrfrU7763I2r/MzK2m7X
# DATA V1zWdru+4rK22/UVl7Xdrqt+7UpNhdaZX33eDLfb9Slffd4Mt9v1KV997sZVfmZlbbfrKy5ru11fcVnb7fpKytp2PVTKXrVR6Qf1
# DATA 8n4jeJu+5p0OjXY9qHWWPlarNfixan3xsRocHY3TmGNqAmLB5f16Lki/Wa1WFmMSlAOvEgT9SnlYDbxyv1Key412EAXtxlIke/NM
# DATA NPVqRlMXf45FU2+Wwyio52nqfqvqV4IcTX2Orw6aejtqdXoZTT2o1Ou1tqGph612LyxnNPWaH3Qq5UunqbMzuNjmTfrG0ymL7RqL
# DATA nnlbm+Kwtp+ZB6Kbpbhly256o0aDN2hieyYz0Rd3O9bhZ5XX8EGwzbZl1K1tGSuB7lao61nrUlzKaRmYZRddI/hYQj/sJge3WvQj
# DATA /pQ9VYqfl+hVQ7jAVizBVhaCW5+HWYCe2mqq96/JspX5dbxk94Fa69U1zCwDqL2gmae7MHeiIL+8XV4NW7dLao07fFldYyc3+9Ud
# DATA VN1B1R1U3UHVHVTdQdUdVN1B1R1U3UHVHVTdQdVfMqh6ZjEq7YbtHWPfUaq9h6L9kQl/3BZiFXfZbCsPDhlXLqIixWHSjXYFXUEX
# DATA ZZstGnV2TUQmirBBditBUA/4KmZ5IpuW7mo2Ok+NFeJc/YZGqQHpiBhcEFMIs+02JfB4qGAj2S91eUEy7SJkLkx8QTXntlFKaaiO
# DATA tsuFem0HxhEOqmzf/PmH6r9bu3/5A/w74WA+urlXoHK1OO1ctt4inB6qAruf7YejeDAIb1UK48GMpv3prWoBknG3gs9/zlHhaayJ
# DATA y0caT/9otrcXpTIusgCZ9/Due7cMNr4TxYNtvOHGfPb8uOQ3mSb/Vvy6QOtfZ/mfTId3LhQJQARwaJKPIDQ/fhwLVN4vVXSQ6JwV
# DATA SwSjggheQFNPhA75harOQBNvCnm+KZnLugaJkhAkWxSQnjMh05Clq6+tM6c4g+PeCkv2MzPRgETanDwtPZ1V8p3bGFnguJrTyIHY
# DATA h0oAlFxsyRuOsQwEPyzkBTqcTp3TqTuNTt2cmItTrHOKdUs0f1azLK6Lkp03nqCdsoZWPk5Gyu5uXtJtbwZpXAgzrdJuU2CLEXiz
# DATA cSdWQWN+x2qsWqyKabTzknR5tNaCHJ25r1+58wBDE3UtOuLiDddyUz+TcVsppmXkK9jACRPqgQEE6gbLOEVW0Z+yQL0El0LL15Mx
# DATA X091b0MsFlpTSm0OiC3PepJxnlC2ojhH0ManpMQwrjWHkI/8JT2OTvQUEDWR9UJPZR6mkWqVUh+n+w1lF7HcXqZ0q4ZGnf5HxpDy
# DATA tCEFxTrgfUSpmObDQj1RORSzjkXJ+xlGzoVHOv0ZdIu1/pgyV0oeTxpyA63ggQWAKp7aQo4qnFkUZFxCoU96bvSxjFmJEWEGFdOr
# DATA zFmCdF2O3FVdvOSI6tW5sZjcmCZjxTbgupJMWE0O6mfpbIwRGluOoedMda0Tda3+fxo+EbgCrEK2ZzD5Gh+qQtWDS3gQHmYWlQxA
# DATA Env4qr3HETsyddwY7BpaphiDiO0hh+tWPF2XbH4/3vZJQpnWxmAYcp2jeYNO+LvwoHiWba9VAZkGldcLFBoqi3ZRlLCwNeaSYym5
# DATA sEtdeGzINkpQTidAZOg0/ElPMDJBOc26YUBnmLUyY6ox1U6bciobqM8ZJIfs9Z2HrIky2IsvcJaNOs5AdQbqaQxUZ46+POboSjPz
# DATA mgsr2wv8iwizQc5OlRZDf0/7PCDBVlEWavYI6/UoFNZ1lV9+vtRETwI6WFs5BDfHW2TuvEod9HxL1cfRcpu8muW5TV7qqFk44G/L
# DATA 2sviMTFp/Z0Ebil54+Goo6Oj1Jfu/GThlBl78MnmWSHkbT3LXzhdcxAwvZFGa2W/rmzGvlae5vzRxhgbbMvFm5VVpuWBmdcxG1u2
# DATA pGFw0mAPe1RPFwzmK29g5s1Ry8E3h6+Yrwuvz2LU/EW9bakUC8SuEwkfI/XiAkVkEpHpErbJ6laAj7n2jtOv0hQ0AbhfvfNoKMBv
# DATA yk1DQ+bmxlq+oSIi7+dnLSwDDur7OErGA2qhH/C6B/Iim3+wmpkiLopMck4nPG84TkNUXA16M9biPFKao6xKT0dXTf6MsY/Zgy5P
# DATA xUyTGQZ2QsiMk7EkmKWorkqV9pqIPZiQEdmZro/YPV5v8FJY/Ic6euqizKTZAvdCVCXOI+TkwYRVs5ODEU3Z6Kd4CDl0XVmXxuae
# DATA TPYWY/MSihQ7brKz4s9qxc9XOedndn7mcxvwK6cLl+dnNjzxeR6HwapdS8zXVfCX9cov/XD/6Vj27fAqOJkyUTJLta/1BJ5xFozp
# DATA 96xLBuDbPAnA7G8MNDZG/wfcDSJieYCxviFjLJtpwjxXWK2y4zfluF/NIFbr8DLN44+r70Wps9nGfvs1jOLFlPFaukkdvjFiQhnm
# DATA 22/Fr5+ImLaCyeeBvmjiWTupWIJTcKZ51V9B/yiqcgF7Qqi9Uiasj7R53MJO6ysZb/qk6FY3jS1v5Mg6sCF1DNR3zMURu3Ns1Pi0
# DATA m+eMy3cTu7teShaTXqaxo7oBk/q+RiVzBzGJeM1Ce6afX0C1WSuQDngQzkY0H8KCQDrNM6pN+ruA07DZxWsEFmUIPfsEZGYgpKWX
# DATA KXl3cXk/JnvHXiRjSyh62lGrGZ6sR6ijDj1FzcQGj1AANocpNqzxrINnbGJE8VqFMpQmYazoTWBJh2PpqefKM3OgqN4x20SSy1jL
# DATA PWKQPItc5KzYJY/mcExLOEy8wjYPYmKmVTeJBB+lZn4eOFEHqGSUGYwM7UwV3seMQidzsl+0WZMFzJ6lcQdenjixkNlH/+34y6M/
# DATA HP8jqNZHfzr+zdF3R18d/9YDO5t++Lejb45/u0jP/qej74/+TPf9/dF3x7+lu4/+QA//O937q+PfFDz69D09+fuj749/DYo2ghaS
# DATA 9q/o72+OvmGO9hf0yL/SLSBp/9Gju8Dr/g0F+w0F+xWePvodReuP/CQF8Tv6+ztguY+/cHTt6z8hpE4sGUZFkOUEkaW5U9xXdaiZ
# DATA AoQ34GVgXi1/oEaIUNu0BUGCsXOKzLjxIFK8MEW7ot5voqH2zAbLjNa1FO2HeIj6oMihs3Pzvax7uGp4tlUil0fMVrUqtWZ6fIEr
# DATA Zjp/dzsKs+76dfrClbEd0Vh/kahsCpfZ1bEeydTWioVJ3UvKyt6g0C6clH2vn0CnPgTEnMbUkbZfKYPZ7aSIktybULkt7AEXny9Z
# DATA LNRJ7UeD24hrn7dJkX2X2l6qMJXeUG9OOU39W23BZK3pWbGvT4y8w167Yf2cw7rGW59uNH85PLdXOJJf5EC+0Th+qmH8SkZxqYkm
# DATA 6dlu32faVC4DUG3SKNtDVyWPO2/l8eFyLshOSkrDHktlhNO+pKGHjZB9WbKV1WeanodCpp30D6f9YVZg1l7IUOeGQhZjKN6ESP1+
# DATA 4pnoCnhXM5c5NqPEk1azHM5b8u7yjyzQnQqZmBWdZQlL9aoIKJ0mY7K2+oqCOw3byDA5YCfWQ5YqA8im/OrEqehT6CztwBnh+NKO
# DATA L+340pfIl95oSNlovrKh4Xs1tvtZTPcLsNwdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqBpB1I2oGkHUjagaQdSNqB
# DATA pB1I2oGkHUjagaQdSNqBpB1I2oGkrw1IulaphkFwRpB0r9or94LnCCRtVpw3okfb+QEXaxD06+XKfrVafpu+/2I+H6OgtQRv1fT8
# DATA Zq0f1Or7TeCtmvnHOn630fXnHxv6tcCr0KPVctFveJUqffCqzWKt5lXp//Rbo9j0alUP8Cy/WG3ytQpuD7xqy6v6uBuXy17LqzWL
# DATA Fd9+K++EzLOtqt0grJeXsa2W1I0A8Wns+5V5QFu73vbbnWWh1BZgfDYlrZpHBku4FsCrnlXfap5kHoVBo70Qw0qlfv4YVvxqFsOg
# DATA esExbLUuIIbNehbDRv1iY1htVM4fwyo3iUsq5Ro1knPHsFatXF4pB37z/DEMysHllXLQ8i8gho3mBZfyaUB6MghpkJ6MZxZIr1UL
# DATA /GorD9Kbx+bxlXAepNfrtqIgA+nVwyBqNA1Ir9Nod2mObkB6LbKOq81LB+nx9s/iOuu+VJ3j031uPbTIosu5hPxmftajM4FtLLhs
# DATA Ke+x6XG7WOlGezu5kOcIfW9FNK7HYUHiPu/8rrLrW5a8Gc43v36vQubJ2qZraiVtvrM/t2olHcF4euNRznI3jgUcMdC+cGwMK55y
# DATA Cai2zAHNfjgrPOUFW8TzqdqULw0UhuWVaGB5Zfl2qIVXlBBrslmtWT6ZqLox2CVMVnHQaa2G7mUlXLDLZM0sYrG2qeRa1Ug5u9cX
# DATA Dk8FUOtXTqOygjrdfNRBAB0E0EEAHQTQQQAdBNBBAB0E0EEAHQTQQQAdBPAlgwCiLqiJ4i5bp4UQhz4LkPCdFFiGrXxb8oNPh+1K
# DATA bYm7/+sufiyittzmQEQ8YlcNb+orxe3n5UKlUCvUqY+Me/M9pLptZ0c/bu6+za8zFXF7VIjBfxvpbm9XPWH1eju3R2tzCQA5PWJl
# DATA 8VPvkVHy6e6dp/oN0pPRFWXnPlXdGf0Hep09xxjj6Nj2zme5nLzNh4C1rcgZujOXqtHuHUoQH7+EMcrzdjQ/PgeHJJTk5KfC/FHQ
# DATA 3CspCN4Om3P5aeiHW+q8HzqKrFbu0qjLErJyypjqozDwHsqhYyRhTB0sY+5MwqZs8QK59wP19h2x/JeXzQkpmSZ7e4NcSgoxtXPU
# DATA IkkSB/pzfP/IFIECKia7XCu17Z92oPOI5O4U9nI/vUWTCKrYCQ1ZEWXMqHMohcavobeVX/Ob5VvVavn2XmmP7oWx+DPccJeN+m2c
# DATA WiioAGUbOi7v6Lujp+NkBMG2cPAwHI4fJ/lny/7iszdK5ToiRAkZURFt7yEw/UXuhpJePOKVTdzJHqht+ZSMt5eF2KBikgJ8IJnJ
# DATA gomAO27jww2fmY1Jz2tykXLi9S8/at7murhrTWRQ0oVqGStwAoCEGyXhuva5mpOwMr5GMOrq8FlW92+rqvG5bgM8BZ5iuxEX4d17
# DATA uwfxiCZWJT5VzvXy6fSXv1QXD6L2k3hq/yS9xb2daZ/Gae/+ZMK1W46kW+M00sdZJPXgl7/EfPDuPYpQeBDGNPvj7EM/PcQ4uaQy
# DATA n7IVJWOrEUn/KA3l9uc827fzRMpI4pw3LxaPr4vokSjwQPpQTnG3Iy+iaZpum9TvmKnskq6Oz8fFA5rW5To9FJl5TIa8HSuWFKgq
# DATA hSVBYo2fHjFBWc9x1r4mrV6CEZ+aOVTrtGycls0yLZv8QWsnauNEbTYVtVkpQH5ZYjf3se7CoyvUJkaRLduihW+enYDaVaiMiylA
# DATA lx/jg7eN4khvDuPRbBqdpGOtnzWdk7lgJJeVavi8JLTsDVGa0JV1Etb6mC9Fm4/rQjH+EF0W53fCwhlUOryA1peVJi5OCkDuz2eM
# DATA WU+ycsL8yGYpL1lL3vAUqMx35jNCe3CyrDC3ZknnB/05dev17/I3f5efz2Y8WDnVuyqbv6uSexc/WD3Vu6qbv6uaexc/WDvVu2qb
# DATA v6u2ILV+JzjVu4LN3xXk3sUP1k/1rvrm76rn3sUPNk71rsbm72os6L/faZp3aX0V04ZXqqvb09cXQExdDxWCdNFKRNZoQ33fE0Er
# DATA 4egMTeWkA5MRErMHYJN5kj6E1NIk1+VJCH7Bqxa8gIejBiha0YiFVD3sIOCgBSg8NCQwK2I0UC33n3roXxlmYMl+GW97pipFwxTm
# DATA DVoRDIMgwhSr8fR6YBtImT//YkIO2uqmTuunTm6m9GLOlE4LYn3msqC8uSvb53UZCE9LfvOCuZ22eOlSWOdKnCxrCPLJQ9NShYsC
# DATA mfE1WNlrII76nIgFbihv7mU7B7VxJV5LPV+WEzuUOzSZhoomVJKMoXVXKbSGExa5gmOUjCE8TWYV2VfMP+W1FxFrHcs0nrd2QYcR
# DATA 83Te1VTAA6qgMuVGntBTIcUDesc+diIKFWgPbDKWn6SXMyMHunxaDP30uQizjzUj57Rjr1Iy/dlYSrlq6YwlZywtM5ZyXZVzM7/0
# DATA buaVRtaz11TXNZ+qc8iy0ofwAIzoPt6MlGmsjydompABnmtkezOaH7OreRIpDewFeW9qLkYB3FIGT9QUn+vQnGM5ZzUsiqib+2hc
# DATA 1c2YRyQqXaOvjGEz6fW8cD+Ju7z6OUrilF3iE62pLd1BBh7PEqYV3UreIxqivR6FJiLqKa+TylFiDL4DiUvK+xcRyKHRAqeeZdZO
# DATA qdHPpmK4sYwcmN9dTYRDjEvee0pn2xvGnUky7rMDRuHjorDDbnk8TzkA3Wp0X8s98Zm7J2RbY6TU4HWmPIqmYkakmfTzIMFGlilo
# DATA vrIBbxwy1NDq9jRAr+TdRWZS0PF4rMDbCIJdcrc9LGzjKqO3Q7nLLnMPZyTQF4+QOxr9LunmVHkH9DZeGV+TvPdD2DXCLd5LjOo8
# DATA rrK5RSUBs1gKWGPnqdSlkk+TYTKZJAdK31uqP6+S66Lhqu9JJo6wrzOZdaABwxh08V1lh3iztAnD3UDTqagw8CnK8rr0vMny/OwZ
# DATA wwLPAiBnQBYdT0EiWItigSpF+ASD1JSHsD6ZDLZhSW0SkwY29VIxDen2Hk6ooymYcVCqA3CIggnAi55EDJ9HzaNsHEohMXmaLMs9
# DATA VOUBSPQUmdkIAzPWlJJxOp9IsadOIgW9LvWcV64QH8lRyYXZvEcY0ebBJreR1up1i9pxjGFupVd5nRM5v1BiSmFN5mV+ZX7lOV/r
# DATA y2vpF2lWpvFd7Gt4uUQaTcbCEmYBN6KLfRsvmDzkkjWVdYpOx+qE0VIu9q28dIJ936sbZv6FN2eDc/riX9zZT4a4pLd1k2SS2nzL
# DATA fzn6/vhvAaQ8/kfmTv6KCZdfHP/26H+AKHn0zdHXi4DLf2GCJfCUX3hH3+Ifhll+e/TN8d96jL784vjv6c+XQrhUAdOLGGv5HQX+
# DATA 9dGfNb2SwZh027egXH59/A/02x8dwvL6z9seyUxrksBIYlMYi0bJbK8/ZUaOyEyr4XUQT6GuIaeIzURsNtK2C5lSGPVChrfKgM8W
# DATA TCozN2BQYBaGfAZ1Lb/yEe+4oL4wHnifkMXIRpQjWWZzON0LXDXGcmnBXB7Qkutlas0fdTUV5FH+ZlRWc+sDVXMxvF0kzZKMVRZS
# DATA UGuYsteEmsTYkSw3KK0LB1neVVurBtQ8DosH4eBJRmoisxq8HeB/VLJg63ZCHDeiUXYCeTaF1wm7GCEMNGoURWTkYwGe6uUhzw0U
# DATA BQnn58cLJMsTat5qs2RZc3pWRMsTEuF4lm6MP88Yr2GWZx3aXwrX7JUN65czqm80qJ9mTL+CIV3q5ZIcMAP6M2w/l0G4XJJUj+ah
# DATA 9InZc6FaJpXkIpYFXucMke1xB+MsUszJXRZl3visHp4kAgqUvqmNdXOOb8hxG+VQe5vALXOObkRJJcNof7K7G1v9vAOaY2MNWJQP
# DATA UqECej9NMxNKRn6y3LDLu0cxi2EICJowHvHakqFdwtqJ5QXKM4xC44WsuxYaUvlWuxGNkcOYzIaDfsSxCD02TXiDXS9ytEtHu3S0
# DATA y0ukXW4yxGw0pdnIJr5q8/4s1v25jXuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8
# DATA dMhLh7x0yEuHvHTIS4e8dMjLa4O8rNRqYVA/K/KyGbXavecIeblk5fm08MtaxavV6x7lm+dXywO/HHh+o/xurdH0Gs1BpVnxqs05
# DATA riXd217EYQ79VtWrUEYHfrFJf7e8Vr1YC4q+X6xQ+MEv3qv5FHYzGNSrRb/c8JoNz680igHdUitW6fWtYiUoVhtzZRJEjXZ3kQ9Y
# DATA pWg3PvWDcjEoe5Wm75WntWrTK+83mm/Xqvkw6p1mt1FZDKNZ84Ja+dNipdwoNilSlVrRp7ygGAWIabHZOIGsaSK3wNHzm/K6TjzB
# DATA bKnDxV/nSHgdLlpfau5EQIW5+HaDZq1WOwMtj+uvpuVJU7Boee16EFX9DWh59W6Uo+VFjW7Qame0vKBXh21taHnVdq1ZyWh5zUbN
# DATA 96NLp+VxtS+uNwzYuz/nm6aiwtnLz60AtG2QY6dJohdxbipfF/1/+EMt/PZJawjLjZ1V8DcrlidT+GzInjx4OshebRGylwVzCsie
# DATA dkCuzCM7p1WGKoydqn+2x6jCdhobA2YQW7GNQI/daoGrvJp9l+Vrwc6qNebECTlhiHYOPufgcw4+5+BzDj7n4HMOPufgcw4+5+Bz
# DATA Dj7n4HMvEXyO04bTCEVt81AaX1s3oDGCSHKI5YaW9qeeoY+hNxjs3tkeLPCdVIp3dEf2GgXz9COZ1vzcw4edG4N8JeOav1P6JIlH
# DATA FMCH9B/4ULeNefnhlj52nsWlNH2KfP1w642FE+kqgBv4rElR98wOBR2qBj9ptpJTCHcHq9ccrHYHql+SA9Wn1Qt/tget2S+ZudIW
# DATA cUSDnBbmXpJ0cbbYYz+hOWbLJAkEskZn+1mfz34ezijy3xes1b7sIPlFq7YvP5e/VL99g2PymZ/W6IdHIlCH0tayk6pyGI2ZxxFF
# DATA IU2GEYRg+GitVDU+Aa/cb0xkEd3A/Pny7OR4ATLIZGtmjZ3njNAzhQc46fXgmNYHmkX3EIFLVeNXzB8+P42I+EI1kQO5YWadPBux
# DATA mmdxmtU87wwqZ1AtUaPLKpQTrHGCNWe1o1baa5cjZMN9um4GZEmJdgVrYPSTabI3Ccd9S1T8memmXQDAksblN5QMjTV6nVKzWIwB
# DATA BHKBgsVq7NeD+TAcc+ZYY/4y5dsLUS3+gOW9pW+k2giFFPR8lyBc/CZsdX7RyIueUj566ejC5YNZtPidUTobhFNRLz9UyTtAQsfU
# DATA ifc86u8Gg8uQLZ6xptJUc2dmrAE+1xou9r2BKE9D4rvriQi9Hudo+LvYdzH98UE0SVmKCStVzLcXWRhmGxXDmAz42ZgaZHTBatSN
# DATA rBOds6CpOEPwYIUBIgb3BUtEz7Ems2mZBJl3TNJDWivIGx4a80N6G4OjzACQtqK6WQ7KFOUxObDrj2pCh5n6lAxocuIoXSEt1QFg
# DATA UetKWbpUUAVicSnvEQS+o5HH4JVRhwpKy0/1FPWA8r5gFLIS1TtrSVMsPB1qrSSeEU1m7TZE8rlcmEmMapIMGF8s44BoHE1mEPLy
# DATA dKYZHS/l3ozkBWaxO1S6qZuhHl+c6YdlULgJiJuALExA8hamm4K4KUh+CrJyYvGstTQVr4OZFv1wzLDhEDMMWxw7jZTunpaCnBOL
# DATA ZNSOVodU6KNIJjOWzuPUFoDEWDk4AD9pJriQeYlHabEzasrUd1Ep7EdLlB43Vdvk1I7vvMlLm1m824fZ7Ii5y+1ZPOgaLT4VGXY0
# DATA LrqN1eFRC0Cv0duy2s/AKnxSFpaygPSPGTzbXGEVgT6zYrhnk8VZ2b1CQ7eVlDwEXL3XbCGAVao+vyobI9TLrTtMz2o/9WrCPWxm
# DATA +GENHmMsNRt1H9uWiXLkzt9OE1R1mOEt/rT6zs4gHrY5oviw+j7qmBNsyqI778vH7N6bkrY7c5hybWvKarxtamJEWWNo5koXm4Gl
# DATA 2asz0pnlHE66ZnrKmx9koqryMZ8Pc2Au3kltugPZWSAT2xnfXvOeDE0y5uNtMhXKkdU7D2NmNXUjhglRa62Kl2CYpNPBoYJf4idY
# DATA iUaKnddqhNcVj6YyBEYih4ldkmk/UXqioUDPtXgsA8VHRmqWWi5Pi7V7W0lherDMlHWoDmpdbQbWT5GBH9CceMC++3jSoeliloWY
# DATA o1LHABSX3dGpWQ48JdQtfKK26FBPdo9XCdg25r2VMNuHSRuPUO8XSZ2moniSyqKZooBxWVxEdlmt5JT51VqbX6bJSYb9BJKf1C72
# DATA IpNV8CbwPfk8MgguyciS9wGNmQWPVfJiMsIOlf9JQcSoOxdKnOxWEXeY5szTsMEYt6h7EVllOp5TZlRjbUapXkyy6W34ccScj0dW
# DATA reJXU4U4oFim7IgJJwO1eqp9M3AiYBtcCK1aWeniaTZ+hvdv7zDzF0ZYAsSefCHnAjjGfR63Q0jqMrqCb3qmbTI4RZt8FyA69GnU
# DATA 7oqU6KJArkxtsy9TcxNqncpIa+UtCtNDLO5pIhw9Qja/SA9zfootkgLjZc3In2UF8yub17B3EypiGiMH0SG7CbI6NqBfMgtHeXfF
# DATA 4UezW2qC7InLjDVkCPXw7LDSi6hqUVSsLagD40ROouooWSviggKNcBJ3luZbfiCWvXX2QGyuSDbceT/Ru+C08jSbYGp3GpwiqiQV
# DATA JVrnd+kkhtiL4oDIWGLjaAo0r40S++8CEvOO/nD0lcdYL9C//nz8X46+Ovrz0TeLGLH/5+jro2+LR38CAOz41wCQ/TtwYce/ouv/
# DATA dvQd/f07+vv7o98ffe8dfymhI+hvAB376uhPx785+vb4S/r3t3gTWGT0ZgrjKwrhKw0m+/PRV44m9hxQoEey8oN9PB2lUp9RoMdR
# DATA MmZ+IwPWeWinticGYjeB8jl7GzHQWC5pJYbLd6GPzoTV+Q3Ug8QiIc/O47VUsbdgLjG7fXTocGK2D0V1BFdNE8sXyOVixOKRtYZ7
# DATA X9dS/csiS2w0xSFA08fiq4x00eQieWLhVBAF/TCl4RQWLFm6Sa/ncGKbltqFM8XuhYMOVh0jWQA7zADV4ZB32vMSyIDXSbwephIe
# DATA c+FY7s+scoCkOxxGPPnFWMLriPEvIqZveN04mi7BiJ1Y6VZbJ7m29OwYYiemwHHE3Oh+EaO75omdelB/KRZFrmpAv+DxfOPFkFON
# DATA 5lc0mEuNtPMg22717JvOZaDE7LSKY1jt4Ogn9BwWH/IJRQpMLHVhYZFoTdLfAYN9ME6FqsRJm4bpE7VXBRGIRzg5hmN8Kks2Q4kB
# DATA YCRD9T54XQrW1M3ITlJtZFjvaJsA8KkEG+1gE2BtKyYDYYldMIPuQjxdZg8oa4DBR7ADsHqVPqHATDxiOMe5NlH9GmCXNvaQzaaT
# DATA WMosGXWiySh1HDHHEXMcsUvmiG000mx4AmND4/jKjPyz+R4vwMR3NDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0
# DATA MUcTczQxRxNzNDFHE3M0MUcTczQxRxNzNDFHE3M0MUcTuz40sU5QWSRdbUoT6/VqUfM5oonZy86nxYj5QdWrthqfFqvlok/506gW
# DATA /aA+KNaA1fI/9f1qMfD8WsXzyxWvUSk2PNyFO/wmMGD5rOv2Wq1Gb4EwBsBXrdzyKvSOWsOrtYotulDxmnUEGXgBMF6ej7BbeF21
# DATA lQ82qDe7zd4SMFe1bIG5Kq3AgLn8cr4+tGuNWrQkgKBmBVC1yF7NxSpRW0YGqzRO+7yVL9Vqw6tSPlQCr1mkv3x/WKn5lEceMrfM
# DATA Wbw6IXYp0p21IOgHjeYc6cw8sEA6q5+BU8Ytw3DKuJFZnDKqR41GuAGnLOxVc5yyXqXb6NQtTlmr3mtknLJus1Nr1zJOWaVZr9Yb
# DATA l84pG0fTEyllGF/0fRtgvixHWZXdZKUmL49hSNtZJIGZkDXmLDfTrQU/8gL6UwnY6ZhDc0mOSggqwps51VSqjGOtYqa7c2+v1NgX
# DATA yG68OdtGPE9rEF46XYVc/NYM4bnbtAvMIbscssshuxyyyyG7HLLLIbscssshuxyyyyG7HLLrJUN2KYvD4nB1w8N0971w2i/1BglN
# DATA bGD2fbiFw1iU+h/DpLmprvH5KFyUrzTNgqFKrYatzw+37o5pgvcULspocEi5cQNB36Bc6c1ELoyPh/UsnSt11opXkUDKAlJLH+YK
# DATA 1eEsaJAhSDl2E/IhbRxQMWewRO/PUbbcsePTHjt2x41f1OPGZ8FrXYNjyOy+0/6u9ZQtEbAy8V56VHkJX+u6HF5+rs7wXQZwK3/c
# DATA +oJJW3OV4ayILcuRmh0iVzmdYUEgzygC8kp1hbOrX73zJk/wWVdO69Bx9YFQ6EjpzclBWFN9DkJ6op0c4LRztDcbQL5Py84NISea
# DATA 9KCG351NuIKGk6GWvldn4vndOgJ3ybaOyfjlbbM6CpoSRtnTwyJpm7U4p/ATebw5RSwTLLUOOG3Qs+O2gBOV7Qgv7pJNNpu0jfDk
# DATA S3LU0wrD2VXOrloj1mZXLqfr4nRdTmtQrcFtXY7ey1+PkgN0/6I40A73RGMNkhtqYPOvXk7sAuhavAKhdoDoazlteJ7o09WfjqC3
# DATA ECkZFuMW87af7O3MkYBGvA6UgXZUEKab0t9zOCRKNHXJ0JMZxixvWy6hz6aeRbbkiHGEvZzZjyvk7MUPAaCPLdgyxhZXGuy3T4yv
# DATA fj7rV/WFDMLVLC+Lsx1jbNexo7wmwuwpYUoT3NWZjg0y6oS4qkdNVPX3HC5sbTz9NbGcIyip9SW0VuV0ETVyruoWJQmV6s6rstdU
# DATA xVOtMdpavtkl6V3ifUkBjb+K2XpTgjgfBcpiNlnt2xY+Uvr0CvESotkbfcD7cD3ZDZgbNGulRE9jUXHh4Q49jnZBfTqjXgha5els
# DATA by9iDzSAEbwyoTqIZAKMBaBKrCqNUZgDHQFQMdA0LmGgsW9ctTsIqJApP2N/PBUN9GCgEBzuGUYsFKhgnKYyknfjHkunTEV/iJWd
# DATA PbWVNzLxETl6SBNxNJaoE2WSRCyrDE8jIuOFY6pzGOA2ZTu9IMZubgRz5q4zd1eauwumjbN4ncW72oS9JgqH91h9D5rFPQwy8Yhl
# DATA zJbznTRfNpMCnETDmBEdhVWqe28KU3BhuGFhs71Z3AXOMBsYKTRqr90ZAIQ8vM2bwHlowoLAobmPxnXDNNW+Jx7qf8qcAIxnk4SG
# DATA jnCqx1y2w4fUwGcwoZQdEO5NIo2vXBwylf4hhdSlodokB66qhYGTpQEhLsOeo4g14bxwigpNEb5tU9s1GTJ6ytuj8I4YUAPK9RUz
# DATA ApF4S/Z5f5NicGp+7lgzvLCRU0AhT6NJJ8Z+xxwEVTKcC4ZF+yyhQuUlK3lvgbPF3Sh70xja1YfNxXcxwATESrjr3o2m3M9yMmDa
# DATA hNM5fxsOrpnIeny4AeyTdWm8q+UoTX+vE/kBZm2avaP6fqhMFkRzT4OJ8AjWH6mgB2mB6RipoXZqo0vMpPcRGHrKQ5hgaqMljywT
# DATA HpLasLSjbtwJpQQVPhNZuVDTLcxZ9JTGvMHhulS+z0eKjfnF+BKdzru801MdEplNCvAks8L4UBc/Tx8VKScG/ESZryMo8SnxT4uR
# DATA xknKK1WWvEdR9IQpIXDLMs8Decm3qmqhFStzfBn2nwo3BGqLcBBrR3GY8qQ23BslaZwukDnYEDtJ5/txQh0T52fWBXGrOTUpmn3a
# DATA egy6EE605eZWjQHubXZiXwIZ+j1UX70PhppriKor+u96mnIJlOh7OWc52iyVt9BlL4EU/W485VnZhLotCEEKFFIxa7jnFIHJS4BF
# DATA PxjIO9FBcmqzxsXTrO4lgKLvUgekWzx6qa7R1+Uihbdo0r1gdvKLPn+zuDj01DS1sTj/DAjO0XdHXx3/+ui74388+to7/gKIGvr6
# DATA NV3+5vi3i2Scf2HUzb8y1CZ/99EfmZLj0U+/Ovrd0dfH/6BC+a/g4tC174//Fk/Qq35Lv/yZXvhH7/jvcqQdC6bj0DjPAVmYwWxG
# DATA u1YYWfD8AulRkG2owgXucbd1ACj3gbKo9iJWDH4Ch7PghKealciQUR5EwRDcG6wn4LwbhT1+i8Pf5OaY3N6vmn5jFcbloW8kaVm3
# DATA yHWnx/Ow+Vsxcpgbeao36R9O+8OLxN3wJlua9vRR47s8IwByj7di4naHvTmxxC6cd4NJbtLGHJPrmfZYY6eImg5z/zIIJ0O1NJVN
# DATA PuNUXNELe6hFP51tW5lLUGlRL4ZpHZkucHAv4G/W17/VxkfWjp4V9mZ9zB3xxg3apxi0NdjmdGP1y+ELvppx+iKH6Y1G6c0H6csf
# DATA o6X6mUSbAfnq2sJlkGpMeoSQnM4nRO+/yDYxsD3RT4YaBmOVicx0aUDDYBd2OaFMQTdEilQxljvJbCJsimx81QmXo+z0EuQVB78Z
# DATA t0ZN8XNjcGic63r0NuN2Sjd2Z4NIb4nkJSx4Fb10HHXiKC2Y+GfsYuVoHcTieo2osw170fQw5wpU6WCcLmOiGQXckUTlE+QANQ5Q
# DATA 4wA1Fw+oOXng2GjOsYn9ejX291nM7/Na3w5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0
# DATA DkbjYDQORuNgNA5G42A0DkbjYDTXB0ZTrUXV7llhNH4veK5gNGa5+bQkmmql6VVr5T7jZyo1z69V364GlXx2dHrNcrDIP6lRAqq1
# DATA xs/8SnWef1ILOrXmMv4Jl1I+mGqr5VVqlf/ktypepVKmPw2v5X/qB02v6fmNiucHPr2r6lVa1U8rfr3oV6kMQcypFf063VKkb3RT
# DATA jW7y6YHaf6q06NGKV6UQqs1PfXiRa16N7qnWc+mqRc1WvbwIiJEIFcmEL/p+c+jXKF/wonoZeJ65tHZa3VbYWZZWhZ6hUozJ/FDs
# DATA mlo5yNg1tVbZqsA1+XK4pDZ3O1G90zsDO4YrsmHHcJuw2DG1SiMMqieyY9q9bq+eY8dQfJqdtsWOqdZbHJCwY6iTaIWRxY4Jgna1
# DATA dunsmAG1ghPhMXAafZ7daigvFsdFpW7RscfOvQr92/yRbW432HzIgjwZSWPzZniznewtXhYL47oqLVk/JQvLw1KlV5c/udA8ZdEY
# DATA oAyPoqb3z5FrpIjnUkxhwjLyAvljXKOS7CaMK9uf41trPCqIBmWYT3/Uv9rCZOuVB8SVtJoNyjKfdfk59tKMWBmQg9o4qI2D2jio
# DATA jYPaOKiNg9o4qI2D2jiojYPaOKjNSwa10QahlvbZ2nlt3WjG8Bvd6/OpC/VYAX3g0q7VUymzKtXunVj3XrtsEu/cRjv/cOtepuaF
# DATA wyqWnMuIclhpumD6mmfWmJMP7tywOzdsnXxxp4fd6eGTTg+v1Jq8lFPFr6PmQmkuC9ycLH6m+hMXoJcOrTm8+SCKnvAJR2mzZ9Sa
# DATA y8aWi1Obi6KBUuVuyyoJZYhWH1SO7kuQndPnjRW4bUyl2p1Ae86jOVI0OLwEzbl3RjjUPJUeNlVK2bCXe5lA9SWIzz1m15dKI5kg
# DATA qjenOkFjRxHq191L0J17KEeJ4QMkU04l2cAFLqVcWXvufZy1Do0AHVqejHAwWci8xF6o2SS6YPU55YEx0vGZJmNOGSA73KoTYk7N
# DATA UoahC5jmehBLoj4ThRcJeEiozh3W596olKlrdieHOqMzVEM4OAC3cBixhDxuwUIVGRqDQcl7N+6Z5lAA7mGw2BaViuoIUZl4ffpx
# DATA EmHBanAoT3L3chCmEh1NFFJqtVwHReUdjQ3eXNGupkkFltj3VQDUOiiaUl/68A1O1Il46GTSoz0aUlZJBuhc0cf9qZsc4eQ7bzOg
# DATA 8YSlAGiknpf4mRupHkY4DqhOccukVe6Qcedk2fjn/OSxQ046+z2z353F/sJZ7KdFSj5DHSBezDcL0es5km/GLH+u4CgQPR95vJd3
# DATA DUTyiuWDrr2cxmXwITORo4uGQ9pyUGclQ1qbFPS06SGOVZnqIBM/Fk5RwlOVuYLErgYpRbW7EcTG1yfyMGgA2EKnoY13vcFsGI+S
# DATA GU0RjU00okqeQMRmHA0GkHbHGNpXiutkf41K3k/aIrdPhgk2XUNLqU8mqcIcMM9Gv92Oxlsw0PguToyOxfuwiygIih1VXqo1ltnF
# DATA Jh+fH4l4G8JhCi31MGUJdWkhWuN5CAnrybr3sxvay737LWlBKZmXKS9Fl7z3knSq7T8RF2L2j471bWSQtC+wl6B8Q/01bAMI21M3
# DATA QlWdZUPmY/Kii8RYPYOz1ZytZo8Mztn68jpbVzMnn6WE43u8WKnrsxJg46PXFpQS0noMR9iHdpu0n8x5U2A3AgMm2YmmHYcl70Em
# DATA BohTOKLSZtA+XIbsNAgt/UD2abLvoBd3vJSm+x3jWWnzVrJMM1A0FzfUgOQUi+Mja/yy1oeYjMLJRPOE+HAJ3gOvzxIjUZ1xXKRd
# DATA qnVuVFL+pPxkypOlf8yAiOYK5ziwIxGHI08r91MyGFgpWEqANIvnXE3k86uyJUC93LrDdJT2U68m3GFm7jusPmPEHAz00mgMf2ii
# DATA rLn528lu4FaVHKy+Z4/NHkZm8afVd7bZTmON7IlYKfrOm5KqLB9kPNbeQlmBtv18GBrWuArX2oyW5zOcdI0Tnhf8xR2vctDKgTmQ
# DATA FO8MNq1fltK5Ck1mnBN3TQLmYyx5OWaD7R5EHOMJhExR7zOzFfZaUWlyFkRitIiZmdYgpWFsmHQj9uNPYc/C8NMWnKCUbGciHJBG
# DATA qjNioSFtZE+9X9CAW7L9qxv6Uj2zTY4tjXxSTNZoCTMAXrHczY2InrGcrvO27KmKJ6t8pyyhR6tLSFdjKaRHY/bB5kuImjF3JOJx
# DATA B/YFWpl9sn/EDRp6UteV1W+xA80aCJ6XVRCRWk2gPoopB0oXOxiVlXL+srFTcP0L5sGmBfMgnAxYVDYcDHXBPEp6DGMd0ajGmqkH
# DATA mOTRCLqXn5uVvLv7SYyZMeW9cesXbNc3l8qY+hdMzrpqlojp4bnLw474lZVH1veesjz+anV56F5cyuOvyGBZ6Mhmnc5swGqyWARU
# DATA JwlV49CTVcXSo16KVxJwHpuGjJL3NrWuwwIVIZkhSTwQleMh92LJcCjyz2RcDIUlRj/FyEGzXnz+gspSdP2L6eGmxfRw1m7P92ev
# DATA s4i16s2i0SfJYdaDaTGukvdBTNPd7ow6+j1ZijLyyXpVKLPwwNSmvOqEM6Hjnbss7Ghf/07szU07sdfjSZd3DIzgAKLGMbIaT18U
# DATA r/uzYdwtYqGQJcZVefCok7JhD2mhKSzzD0LNpc7W+W3eHkrY9HYUEhlPatsEtJDhHjp3OS0m6Eyllbf/ZBujbf+ZK5L3d95P9IZD
# DATA rcEtJr9Y3Lz0z1DLkGYsyA5dymrh9HKYaM+1xytjoaX9JMqh0P6vo389/vLod8e/AasMGDP6/Kujr4/+7eg7+vt3jEf7o8ews2+O
# DATA /nT8m0Uw2j8zRu2roz/Rs7/36C8O8OibAoV49Af6xugz+t/3R1+bl9gkNbrpz0df45PiqP0bqGh4v7z3+6N/P/5HR0V7DqDcZpsD
# DATA b3lNpgcau2rI3BAvFvJqgWdGvM0qgomnWQCAhsKdwDIy1AEInAEd6Bh0A0V0pXo8mfKeMTzXkyUs4xSAp2MtOQ3K8mgKYuc7fJrt
# DATA 6+Mu4qrpafMFcnkINRotwkGylyG+eIchv3yew32zF2fd9Jvx1MJ3XBxDDaa0OreBGprICM7Z4PBpJ5fWhfPT3hMMuNcm4wI7umje
# DATA 36dxx0wvC9rIShMchkJGwpBFMtHdqT2tmN8o0vhTqKREWefEOl8FsqlkOXISsWeRCbP6mMCQikjwGhispgtstfX1crURM9fKnhVg
# DATA bX30HWDNjf8XPP5rCNsZhv2XYnnvaob8Cx/xNxrwTzHeX/5wLxUxn3Qzyl+v5nMZ3LZ8wnmQ5Awx0DGT6vYhQirIGcbJTF4lcZ0K
# DATA 0Ckdhlj4MktvnvRL7SiFSyuaYGmSE00DdXZsQUWvG/cM242SfegpksmGzLaJMtd4Ww2OrJBBwX6JqPMEY5NCk3EdE+4VnxrmnUBC
# DATA m4tT3kOVToXGxUuzUToVUwH5klkOtxXFDPSs6YxCGIajWQ+fJ7aRoDyv8BOwTTM5LCYjh2xzyDaHbLtEZNsGo8tGE51NTOIrtOvP
# DATA Ytaf16p34DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgdu
# DATA uzbgNj+odqrls4Lbgl496j1H4Lb8mvNp6W1kq3rVWvPTelCs1r1mtehXKwP6p1LxmoHnl+mXqudX6FO9WKkO6i0vqHutsldpfFqt
# DATA 0VWvGni1ytu+3/q02CxWG17FLwZzWRq1epVuew565jdq9WptGfSstVhylbJXKwf9oFHZr9bfpq/5F5iw8hS2CqWgUg+8hl/0m8Ni
# DATA reHVml6jXPQb9KXm1epevUlfNo6YX12IWeADEtf4tFilQi0iL+rvUQCI7aBKF3K0ON7JmX9Z1GvUV2DuVAXuxBM+YfdUKn0lQ7/5
# DATA DQbJsapBPd8CTLAUAAwbT54uI2s9ebjZzFf7Xo+/6/6X5VBZ/LXapHpDYZwSG8fNSGPjpEVa2LgoaNaCII+No5tqlXoOGzcHkhNs
# DATA XKvbyrBxtU49CBoZNq7b6bR7GTau1a22ytGlY+PQ/k7GxlW1USAmgX5mBT8OyZzzLwY/8mr0p0p/6sGP7CDmeHHvDGkqMS1gKzDi
# DATA 673Pih301Y65PU0KyuXb8848cfcUmvsHBV4lW7EipqIBeNX4s02XCko1Ky+86iQfjKf3U+QMEjNfwq5q7eLTXs48005lUoX++IE2
# DATA +dlXFE/JwurkQHbah039cmUBP1dezZczuV+wc2CNKXJCAtlKcBw5x5FzHDnHkXMcOceRcxw5x5FzHDnHkXMcOceRe8k4csriyHcA
# DATA 8YjC34W99+GWtDlK+A35DkUYzgY2MT/cehxOoELLj3hyM5rXDb5A1eJNbKbb9nduUG50hqUP6b/RXeuU+P2f5o/h8cPvhdN+iWfo
# DATA 2xzOj/1SgBCy431LDo1nyreQ4jLdvkbNZcdW3CFqd4h6k0PU9tEmd5banaVeo5f8bM9Yy9Hggj7ru+Sk9UNzLlDqSCGvrGYO9cqB
# DATA VSXIwmeJYUcfKB1mOckbscp+dnhyHB5iMi2HJ6G1MrJOTm6sgfymqB63hRHVBYEKrw5Nh46OwOkeb6J73AnTWahk0/Bp9Z3oUilr
# DATA cesH8nH1vdTBdpOEM/on8vF5UEDO8uKUIoj3Vosg6lwVEUQyyiaHXegQhaP9MM0UEHFykpoXFMQ7CbtNZuMxzj1jowEOo3kTkYVM
# DATA geeQw+zsBaOmFpU8atUxjg7P6ejweNidHBa8KEwPuaGcX/dwLg1XJlFp1b+LUww1NVnpVMN2mMxgRmZl05mlfaq5EYvk4gy6HKEO
# DATA Ra6azZzMiIBVCbtEMAwoqD64d+giMmVqpefAx8NnqB/wl7Y18+Rc6tRZAp6Dgvlg44J5SFW9CLfKITTALeVQPthcoBIZR9x6uNno
# DATA BsIgGRQc9UdoOFo3FOcIoVgFxfBozLYhMtxS0xDBAaxtyfgWD/rJjKVHz6/vmkvKlZXSmTu3dzft3N6LsXMGGh6ziaWMTBMUmvNh
# DATA V+A0Geum04snQ4iTzsaeKphkwhJs/KuolxxQoiZJW7q7SYSvrBs2G/XJqIK6gS3jcZ4iycX8ykrEGiRPWSSPVxeJGW6lTB5Pwngg
# DATA eikhmTWmUOj7FMYJ7LdEcrhL0x4YeaiahoY5CVVzUJrVgAlrpZlMSSITexMRlsGhqL2du2Dy0b/+beXRpm3lA5mT0gQ1HlMVNgWD
# DATA 2g3LmabuskUIhjUP4zwdharHOOXxHtN88GixMVchs1LRDFci4VMWtUbpwnN67qKYi/HLq3X8IsiJ6Medd8t5tzbxbtlVzHm3nHdr
# DATA Yy/WSifY5Xi3WHjLAPBCby9JRBRP+7aurX7tOt8XjjR4tgdswakldFNsGFH7kPW1nLdJLc8wmmmE/fc8UVULpdud4Y5ye+mGKZNS
# DATA lKKEap43XVl2xbh+Kry7doKeG73YMGYDqcLbqochb3nVG3mjMW+9LvmrHWS8goRanqhyHRvVsryfTN1oYqYfXHBN+YrQC7une8vz
# DATA vc5wtR/LLwXsQKDA4mhCd5eC3P0LvixlYRlHoWy6oSDua/nCuV7WMpNQfhQFPlykUyW7r2zTJbskTTwW82xM4+FUNqTflCDOaQCJ
# DATA kYLByGpvtprl44m4X4UYi35gQSV6wHqNI+2lLciMgW049oqEe2Esu66wJV4wUjR7KHkGcpfV05LHhVbgwc8CsrB4ZRYk9CpTbR3j
# DATA dbCmxvFIMFYIkyxiI0GIBUVWUMOhMUg6tg+leYowXwgFSnsVMZ3tgV/LOwWyNUw1bR1pCUrWq8xkJ2dsoR56ZruA3hM3ZhtG42WR
# DATA 1S+84ZkNNc70dKbnJqanszVfXFtzpXV4DdWq+USHOV2waIYNLDP0LZidHCtQyCeRLBOm2grNHmLZJe58r5+69fWXfOW/5ZzOnVep
# DATA B51vWPpYIMI1R7iacsLPOrMoF8IBf5sX4Z4/rifNtJNgsiDvOhx1xPw2+ld3frJw2o938FEhLoibW0/xF07LBsLi2bEVbY/NwcEP
# DATA wkOevkDP2Rhm93jJTiZHI7MoCH/iHoU0PpTlRZk7gUY4Dvd57lLyHvJy1lRbUOoeZZ+hVsJlLM44Nnjm17pCrIeTlaZpHRtVgvnK
# DATA dP/peIBQ0/gptq7LMqRU7yuHe1y58ZRhyqhC7UeDvRl1Fzas7F+Ovzz+NWPJQBD7hj//Cegyxob9HkQx/HL85SKl7H83P/7q6Nuj
# DATA b4Ai+3e+8PvjL4/+hEsF7+gPR18xiuzX+I4b+HXHf09/ACL7Hb0OILNv6OevGGX2LQXwHX47/oKC+RawsuMvPArjK7rw97gINJpj
# DATA lz0X1iHSxlMv+ENYrlzX3lsgkoaTJ1jlC0dRAW4PmpVOeO44DmX6g0GGZqg4Ks1rSNDL8GYjDoy1yWfxgNmo1KJD3s1JE8twKpDU
# DATA CFv1qTNbSy0TmHQkA6WDltm2otVhXDW6bK5ULo9c1o3lHGZq7nxDXeGKukAvw7hn7qRKJzVxcsHwMp7nxylvQEBz4J1hOqqOYLZZ
# DATA qV04xUx3Nr2YnwsH4lRKO/2oO5NtIgNhx0Pyg0HO3It5rPbq+UFxGI9ga4cDqtzYR3Jbe3oZnSFW2CSigAWkEI/QBYsZqCwjaZMD
# DATA g2/etGquNnHyTe1Z4cvWRt7Ry5wFcGEWgOaWnX7gfykcRFc56F/0mL/RkH/KEf/SB3ypj7nE2/Sya9F8LoNblkuxF8kcPRWPFFO4
# DATA vaSX37fH2TDtUyz3eN0EjS7GPk1jGTHiaBiOOeHyWvRRcm6AaieoS1hq0cgk2a/JI67Ue8+Is6UbYss451Sl8Cg7ZnidDPgAgoi7
# DATA 7EAbBlQEKWLpdXHgBy9/MkoO5HREV20uBTZqHHFR95PZBOwvZlDF7XiArIJ1x6AVGo8YNwVjQTQQGM9lzhAokNMoWQ6fchwzxzFz
# DATA HLNL5JhtONJsNOXZwD6+OhP/LBb+OQ18BzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMH
# DATA MnMgMwcycyAzBzJzIDMHMnMgs2sDMqs0a0GjclaQWa8X9srPEcgst+J8Wo5ZnfKkXOvX6839aqv2dn0eQVaJ6p3eYk6WfcrKWj9o
# DATA NvhzFZAx9blGGcufm03Ppxyu1spDv1ku0r/qs68/z0G9KOe7vcoyqFeluRCFSkBRKFc+9Rtlz/eBYPMqfnnqw23cPAkf1gjCRmfp
# DATA m4L6Ag7NbwTgknnVSrFV8/x6DRA0P6CM86tMfqu1Tnhdp1pvL6eVWRC1IqYDIQT6pUZ7rSUgM4pLBjKjSBmQmeDYshZQq/YalY3z
# DATA t77kVZVyI3tV1fcv8VVVIbLJqyr1xiW+KqjYqWqWL/FVdUbR6VRVLzgDTwWV4y5NQ+Wkd7SgcrVKvdrs5qFy8wi5pVC5yI8a3SCD
# DATA ygXdetSsGqhcp96JOhZUrkrvbdYvHSonuwuLssygh7kqzyA8vTplbJemmH/2M/NQuLci6szjsLBIf6sto7/B/9nYPyjUxf+pQh6G
# DATA m0HeSo11bk09PcsCnV8gsc17XT4Lnk1VMrlwWNxihevrL9tN6sC6eafX6ewwj921WKpaDYazsmqNPbcQ5/y06BKtQ8eYc4w5x5hz
# DATA jDnHmHOMOceYc4w5x5hzjDnHmHOMuZeMMYe6EE9phj8JocVOFey2wc7t3vnMzEnG6S7XE+ml+Pwyrn5ktXxp+Lt3TLOPe9s/4EdV
# DATA w935THHptHIRxFDlzBcjjsbcVYtxeftzeXV3JmvPu3ZAPxbcHS5lCDzm0smSjn1v0d/5sR/c8ANER4d2RwJoz2i+iEI1MWO5WVag
# DATA HUVRNwXvTj8DSJ7IEKRGe6kXHUgHMpZTeSL2RZf4BGMuOchonGLc1Wb9BC+WrJLFp22e0O2UZPFhezss7BdiKoTwhjK093d+vB1T
# DATA 0yi/Vi/f8ncKZWz64laP9afd4e6d7eGdXb9WK7/24db7VCX5iCWHigxShg/nU2+Q0Jx1eLNe3vlRpbZDM7Au61ltVwofbpVxNz+m
# DATA nxn+iG5cvOl2VnMky1EDtlOOtao6cB7tcvy2kXpGDf7HF/+EjE1v48qN3WWFuR2/mi/E1/zgVlnnJod6+/Od0idJPKJnGVwokVYf
# DATA byx5ZS8exWlfiaL6gS5MnJYVh4sAEH86gsqE4ADwPEMPt+cqTFHXih27WlDj4XpksmWHInmbC5xKoqhnFfT8a+tMRm55aDxZOJ9h
# DATA HCRjSB061soZWtxCh6zZirrSmXkXBa7PQ5emT9HPWHGUsB/pMPVDNOAiLINp1AfRnFKEU4pYrxRhHVN0ehFOL+LUehErdUovRUfi
# DATA wWyaNQDetaU1PWVkN6IS11HG6Cp07MVYERn3iVgxc8r1uJTp1uv7TedlLhih93LrllowV8L1K/To1YDLivRTnCxnHpIR9t5WI+9J
# DATA SvomGBOl7EqmpF8rL5PSr9pS+o1K2dbS94PVUvqWQYPoc8RpYkKzKq5WeTn93M1WvtlBLKjlc8zuVMva/litq1/jeNaCk++sc5j1
# DATA JWEuaO/rA4yUbj6IeEcZxcIMQsuhW+UXlTMZEwqTBk5Tvty042M+E3Ll9F42nvFQKBOQO9bluQK5mNc+xLjJLd5+a3b1cl4qBx89
# DATA Gmgn1E3k3pz/KcN7ZuWyko4gPZnCBDy/SIR34d8TqRtlrGhL3lbOMBozXZrQWXZ/rpNnMwjCH7lblAAvVWHWnoHkDOtpMNyAxRw0
# DATA g2CVBk1edMamgi3yv5ZzwiQDc/MHjIR6hYJ9W3oIsiFgJ/INnn9xi7yF4eYlbl5ywrwkZ3+6qYmbmpw843imEncY41HBdSSQOYNM
# DATA 5e5NMxER4AFrPpm2RqUXpixyBcEp1hwzIlQFUU4bhuK4NEJoWqxhfnIxh17ANhsb+y08WtsAE77mByI8FwlhFq5StG9KDFXo1Exp
# DATA mNFF2ZN+OkM09/i3WXpIY+6ImV6UQOksCgpCJNMjPdAykJ67i/SJDnTcT6bJ3iQc81A9jmBIK3nfeMLSY5LE/LA3DRmr/F4yEWVd
# DATA NdbNw00FkWxZfpJaMUcsHBp3ZOjbDhQGGdsEVccmvnusTh0ARQ59uLvCTxOsRD+08aLwkIMwwFJr8O2ti33cZatubeTnjUdJgUEK
# DATA CEQ4NQRhqPhPDei5w4JwCn+hNYkzZT1h2ea191SxtNFlC5/A6rVDqb9r0nQXO+xHCcit88kSMyHPjV1QVTQVmczCB3DvqzcjX8ls
# DATA 64Pgq5ANkgX8A4C9iDzWkjss2wajpoBKNJKkgHkH720yS1V+qIBjyoe7+0ncZUlqVmkDQEGylAaohImxQ0itjfmkG+9OWT6l51j/
# DATA tdBElANcJmU6zlhQzwlXJz2ZhUGHbjhMutK4UXh82ZSVpw/PJb0efOq67LSGtZRhwRvP2mShWM+x/hw3wrALC8ibcB2WykpjF8OL
# DATA +ZUeSOw06JClnVKbXJfER0CDK7jXFIOIlUQQyuSF1DPE0Pai7o7SOqbne7PB4FDxVlRM2Y2TckWVdA9zpEJWFpQ+4aCfKHVE6iCx
# DATA E5SKeNJHO5QCQx8/j6gVw/TFs6cdLczZ0hurQTvT+YU2nU/LCnvG6tD2nv/1sLDHGAk07JKNKqnv62lh10dN+rmQVD2JIJHt+9cs
# DATA r4uEiuUVsi+aKTavOL4UKabcb6zmjULlXWhkBEmNSMWsSQa2OzQa607szvusXSJcMZqqsD6xTJroffQ77nkzzixn9B6QzB7BLhca
# DATA GdWb7F6ZmcCmld3pCSy8GFJkh+qmm8lgVfMUexl2LqovTy3CZQ7GtZgQuGINyXlBfxwWGMsQjyeo0WlkmpkoOIdmuirbbMiwH+Iu
# DATA snNz3layuSFabGuhs6XNU0jJqRmLkmsDd2GdbcHWe9GsvAxrdhC1lfi1TTX7346+PvrX4vHfHn3PlLFvjr47+j3TxejT8d8cf3H0
# DATA lU0YO/4SVxYBZ/83Lh/9jh7+mhFlX3v05Su6+A1d/g5ksqPfeXzPH5hx9g9y3/FvFcjsK5DU6AVf0r+/VSAzjs9XiNPx34GBxryz
# DATA 3x99Tz/Q/X90bLPnxZaVRo6Gp8XXecnKkDexDkRzOFEX58lbQsFN0eoRR2rlP4XKIjPkxXuU7LOXJ5xkXiWLhIjmsRZl9vZ8NBzO
# DATA zLZps47iqmlmSwrm8ohm4lNJF16urs/fLjsIzN0Po5RGoI4M2FxIF4w2E/eS6PnDtSILf0wtcGCzjQrvwrlmdz1L7zybGZgawIvG
# DATA ENKZDZjC0T7E3zhNodxzoJ5IBMXOuffgp3S/aJoXNKdC73cxEBO2f/YBL/bo4mCBZ7ZhzVxt4yw2u2dFN9swKY5z5qyBs1oDGmt2
# DATA NiPgpXBqXaEBcBnj/0bD/+lG/ysc/KV+LuSEhTp7Ji3oMshmC4lkuhllVboYLTDOZFnZo+qJmnpLQE8F7+3Hjx88KqiDpWplmEuG
# DATA 94xOyH7glR1OBkZoOCUymtJElaX2POg81WPupngzUxU8ymsog+UNAKQs7gBzlhkBecDZeBJ14RvJGwW2MVDgZorOwoOBMeoo84Ct
# DATA AnCoxDwU5BTHP6XXZHQzdqqkhykfpVT3tB3fzPHNHN/sUvlmm401G018TmUgX63FfxaD/8LsfYc9c9gzhz1z2DOHPXPYM4c9c9gz
# DATA hz1z2DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z2DOHPXPYM4c9c9gzhz1z2LPrgz1r1Vr1+lmxZ9Veo9d+jrBnC+vPG6HP
# DATA OHNV5jElTGhbtUrusJhfr+RzvSosJ8n2Zi7jus0oiHpz+KZqMwgE1TWPb6pJFlvxkHdLPIR9lcWjOn9orZJFozaPrVvGC6tbvDC/
# DATA 1TQMqhwh7S9r3abfqC7WnGaNqk6zL3XOSl5Yb7c64VJ+2rrkVYSUdknJq1g0r42TRw9dWPKqwvi6pORV1dOnSh49dK7kVSuVa9FI
# DATA qtXm5TWSat0/RyOpNsvnbiR28i68keSSd+pGguSdt5HYybvwRpJL3qkbCZJ33kYS+M1r0UiCau3yGgnF4hyNJGjUz91I7ORdeCPJ
# DATA Je/UjQTJO28jsZN34Y0kl7xTNxIk72yNxAa2lpteLQj2a/V+tVXbL9bqw6Lfqnu1+n71JIDq6kZwFhomW7qGhslGs0XDrLbrlWZw
# DATA FhpmOQp7vkXDrNajZs3QMNudTrfbsWiYfiA/Xy4NU23mldmd5exRy26Gj8kTdjLRbadai9fYl2ybyIWK+eviPfNbFRaXzJq8ZFZq
# DATA YquMLJrlQlUL5mtDrvPqWf4xPQtcvtkwu5tmk3uTcJhbozspueqZJcvzizfolfqFPF+8O/MirtohKS/ypYjEFbAQCJYaFlGfqtrl
# DATA lwtarRY8MKeDd7LHaEmq2G244Hte3C60kvvpaJ2O1ulonY7W6WidjtbpaJ2O1ulonY7W6WidjtbpaJ0XQOtcRHPuxW0FUMTqHExP
# DATA BcfUDCq6ctMv15pBo347N2dRj/HhYTymEYdkmM/GuHLDx5OV2m3FxryvjrFDP2A07Q8ODeeKEYkUE6pXb2J//3aFsYhvxa8LUvFd
# DATA nDOXU8rjwSz1INjsqRfxsypKq56/61WCH5m3ZUI7Mi+lPNiPGNW5TXH4Mdb4d5aFZLMMrXOmThDGCcLkBGEWDx07dRinDnN2dZiV
# DATA SsqXqRqjO2vIQUh7QXGxkgM22vDOG0tC5vromF0F0FCGSgZ9yEDGKhx89QSQoH4y182nOWQb3AhLQYK+xRHkm8r6ToMTXE0TNMM5
# DATA WILqM8JmwZIxBkWdBG/7r+PXTwIiWsGZpNjXTGqCk9NSOUUyxNpADwCvqJgE2++dHF/9nImsuWDFdLNM3zCm2g7idgqhREiOZHYL
# DATA dV3jODqpumSBZODJ7JKJeuOkmNfXxHol5M90AXrKxOOhKuTnHvq3jPRnLMTI9H7omaiOCcuDm0fXyOvANuAiDYc8B+DlGRaEUXPN
# DATA Dk2qWC2aoSbYG0nTm4J30KfKR8bhZC+yQlO52+tRX9ueTeDbwHM0uZpEUGiKp1rgR/mrZeaRsiw3KzFRlToUA5l1MO16VvLuJUN2
# DATA i1HXV1BiPaOu0X/KRJfUZK4rT4QTpYuU2TIZZHZI8ZpN2LeqxIc2oAa+aEoxjnniJgIrJgLO5n8pbP7Tkk6ui1KkvVNiPfLkrZhH
# DATA TFFL5PVoiMSNWLWH2tYwWss+eXbyks+XutpJ6tJzezwuA3yyKKB50fCTZTqkSwEoubLTW2KkIi8D/L0Je16bCEvvYFXPtXe8Lqa1
# DATA MTROKfetyH+Mq4xZcBAgEdH4DKdS5src3ASH+Sibdmu84tuP33u34N179KigxmFpLzwsKC13QCxlXiRCi2OohIZaSZWVGqkUjOxn
# DATA nGbzBg224wYeTzFsryEqPpLOQDa8rYdF3rUioSqxTtFdKIGOlDwqx44TRAnrRqD5RaMOFEFHEcVP6bEWqPZSde3rZTaRZ82rsq5F
# DATA c+Y7kBOirgVnxZrW0VYwRTa41QHDSPwZAiOF2S/a92xATw6VJKaKZcl7oDk1iDmvjumOLPR6YTyYTdbRLB9KMFi4WsWzfIkscLu/
# DATA dja4s8GX2uCqkjhPvPPE56y7lcb79dFv5zqNkTrDOYeeeAqNB158NXGKjXsJD5J58XHtQp+nn83GwAmWvJ9hj/ihQbTQHd1ZByIy
# DATA Q4zFRtrY+NuZaMz2zsZC7plugTRPfL3zqjb8HuGYNzds6FekCoAtMw7VF7x601iJU+m9pxN8FGFuvKojznqyNyYJjcHUsPtLb/ip
# DATA jOk9UJtX3PIBTDakUrS4WWwat97EO2/q98tgNB8NZagqA85YPPym7p031OZErsEFD8NKj/r+hMqMsZ9U1aZdvlONEQVPBuOCltoG
# DATA 5w6Y4rQv4XZVtFbE471wRHWqa9uCJjJ3Mwn8ud8lCrbpZuwvKtFJBPFuXjzQltfJEflZPJnOoKjOUuJWHFQBs5nHtZUl5blPmSQD
# DATA E5mfjFlRxdxAlTyaskr6mAdPyqDBQFf11IrPTVVQN1WlW8GlX4/9fqTtvCzvxeQLu0Ma9PUsJ2P7aCVxRWpP+8ls0OV2KebsCJYf
# DATA Np5jaiXq6lLAJY/tS7KAB8nhkIMg+xw86xDi8JYMPVj0nyRtHjiVxPxsxCxEFdI6IPgoOVB65dp0Dqd9Hf0PJixnT/XeY3ETcXbz
# DATA eov2G7PTmaxxCibU3mb0UtTZ8T34gRmpmY0LJBQgi/p2nhiBVD+Cg52G82ik7+0q1mO2NrguMe+JK1qlJxTxfPjVjXtfedYRMb2e
# DATA kXEV+tFgrPozWfC0+iKWwaeBMslBFcZR+AQlLD0m6h7WLLvREC+wZ1gKrEChyHyQsfBoBfbUTNkxNvjcrH+ifsbDDRniL5Zt//nn
# DATA H33+4Wjrlb940f+jrI8GH6PDiEczQFXHhxf+Dqxd1mu1v1DrxnP/+uUgqPxFOfvvL8q+3yjX/8IrX0UGzNDm6PV/8XL+98Mf/vDh
# DATA TAgRHepA4i6PM6gUWynvRS4y9iOrIN69d9+hXoOXOal9J4MuL+HTAyUK6xWRSiHbdo8P2+jvn5B9qD8n6Ss8eqHTH8RtT11+QF/1
# DATA LRPzYDprK/+MvoIjWRgO9PcZmS6vvPLBw7sPHtx/iA3UW1tbr/AZm1fUBsue7KtmZ9M2TSa70a1eurXDuxlxMmQLDL6b1CveBNX3
# DATA ZmcQ0wxm6/YrstW6l5aQD3DzPTocdbbxUMHbovl6c8vagbrFTqEiQi9mubW1s6P9S6XoaTzd9nduvzK/7zMfNT5H9rF6iN5AvePB
# DATA iN+cBRR1kFsF7+cqMsvf/VHhFc/zPpvKKZJbPm93KAzDp6/Petj76NerzVrhCVmZj+K9UTi4tfXonbf++p13390qpNNunNz6+RZd
# DATA p+Fhq7A1jsf4R33/6PMdlT1qY2o0mdDQ88tf6o2qKQdoX+DFctn4ujpLZA/xbu60ln6+i7FgmqhjFSr/dTT4wde4oA75JTgYhdf/
# DATA QA4PleL0UdiL3iG7aA+HFHB7Cfl1DyvZO7hz7pr3qldedvkOn7ZZmgZ9RcX1AIbMtorv/Bvp/uzU1nxQ3uevoBK/8gpNoeGm/Jjp
# DATA RtvxKB3TKPyxFDpP/nduoYiRBbyCjkuwAfhDia2JFFOo7a3i1g5+GESjbXmQEhL4FVzDk5OohP0EvI14e7L187vF/yUs/qJcbH1c
# DATA unnrfyp+dGMr/0L8NwkxlfsZEnYfxb+99c5oH6d9rJ6En9na4WfUQLzLLT2XmB2dCLmFK8s21fzpxzipSzGteT/2sKFX/bM+Dhyu
# DATA Fz3tkK2bykRSxQD25qSL3gD9UYl3P2yrd6LqfIz91ds7O7k8TSmm03DUQVXkxwseTg+Y7FRXd6jaef5GuaOmugpjGk1U7PT1XR3P
# DATA n5c/kh/0jdjzLTfxocStd7pULFvq8Wi0H0+S0VDtDbfvo+lcL96jez/7fEeu3B/ty5EgO6nzlSAs9qgGfPRZvfY53WxisaMrjZU1
# DATA 1svnssf6ZUc1nvNkEk5DywEX/orJunQa8cjOgewVi8XI9xdw9JYjuUV2Hp6WYPjCZP7C03J57tLultqzItey9y1P1k9H6WyM4Ypm
# DATA F1Y0VaLwH5/2/JhSJj0F7xjcptcUPH9nPjHLW+vHH1nN9qMf05M4tXpSzHSG29WHnrNixlleouExGnXVAVTTXmfDbRQybinRZIO6
# DATA Nz7nh7LHOgRlDz+Nkq8E9Q2a730rGsua8F9ibQmODW+oOF5vJJ0nOF2Df6jy0YOTQ54+FWS+3OH6iJMMKDh0ygLTI9O/pILEDizq
# DATA exUtD7YM5rRM71OLRLeFfgaXlJ75wwfNkqGYLqb9EPuvpLma3m+XIjuK+KI4spTpUnocwXYJJ4dvsLBgMjlkYbv46e4WvXgUdmY4
# DATA UG5GcnTeNFXt6puzDKRS+1hZMdyrmlt2vJvell3TzCPaZ56gO0nSEghh2zqcAq785OMPHv7k/Xf/s/dL+Xbv4f27j/WX+//zvXcL
# DATA XjkB0sOEyamjn3tdDi17BXVPBxJ5am5ROMzXRrmmBkq0w9InVHDbqsrc4KaZvWRqJ5wzWvHUdi0rsUQFtv3z3G34b6vLtQTdpTyF
# DATA T0Vx7+KjyfVSluu7OOwF67KEv2o0IPWjp4XFoItFVSU4dN1f3cLT5hu/zZjT8nKaZhe7k2S8excW17JwU71EQ/bp7iih9xwUMfON
# DATA AZJJJRQquSJKbot7NFOQO0sDRCypiuBJbfPqUHSrwXeYKXrAx8/4ogzsfLAfFeAsmM4m0ceyhXL38WSmDl7rj2J97lbLBVk35es7
# DATA +YK0WowqVG1EwU813s7fvtlwpcOc6wFXttDNukm2xLyYfWJTu5cU+0JZ9PP10ap+bJRJpofTadjp23H9aLHUlv23aZ77azNdnczL
# DATA G9ib5/eH3c/8QiCWAdvQsDtH0231TdnJt06Rt9YkUyK1kL0sB5C9xPzaw5aPwVz3QNE2GbsYjTVFNBlK+dAw1onyxeNJNu1aT79x
# DATA /2fv//Tdd08sOXqSZknLnszKK9DF9SYEHHbUDAAj0baqxjwpQs+tZ9ilu5M99uo/4F9U0cltOMv3cah+pzlAURndlCa998KqGKue
# DATA YRN+6RN0G2wx9SD/g0dTFYlch83nNrazyQzuK6n4FDz5xhMMZc0+BYbTu8//QIjVBPSXasS/+cbrHk87U0aDqq7WdliXvJ9g0A49
# DATA Rvd42L00gpey49H4FI7JqJkzRB6xc/8+ZmFb7yfYx53VyI7xobf5ei+eDKPuFsqIKtrHH8Mc+Jjst11v6+OPUWIff7wlkZbiu6au
# DATA xAlOsQ+jy3D7beb/q9TKtcCf8//BK+j8f1fx31/+4OYsndxsx6ObZDp448NpPxlVX/nhD3/Iwh3Cq8XiiyyMYY0BK75YrkjGkYbe
# DATA 6g1cD7UZ5fFsazCgbmGNVxDLFPWa/oY9TfpzP0zhG9RfY+iDTSwn4Nn9ibKCaL72Z9N4YL7xHMJ8SwdrvJDhxHZCzjslp/2JEPDM
# DATA BWpkOY8lR3k2GVCMpefU8aZrPPmjjoUXTzyZvc8kr2XIzEZPNSxQJt+1OziY1DTn8dqHXC6mNNhSxzLKJPokUut/yBCZdaZcWPq9
# DATA Px3vTcJu9DOoHegXL8bFjEuUNzJcYRfZNs2N0sxdJN3rkoTo29SjrN2DctTPyYhveWt4lsN3WB4bnnliV+gW76La2tHhycxizL5S
# DATA Ne3HLp9dmb7IO6Y4DTPVEygOWk9v5adSnH6cHg6xSWbbMiY5mVtH/+fR197RH46+Ovr3o2+Of3X8j0e/o89fH/3ZO/4b+vDHoz95
# DATA x3939PXxF3TtD97xr46+Ofoz3fL90Z/odvzwq6Nvj788/q/0Ez/9J3y95WHyAHNeYqDGRBUdOexYGsKS35YvqTL8eBL7cWKbe7xe
# DATA uqudJL1VjpCI7A3J5+5sOE71b9EIi5sfh2knjsUowT4zDLC7FT1DE0dMt8AzYpZ0UrPc4RP0GWMztS1lc1uyJyj2u7kULTEaMKXs
# DATA 9KnIthE+im7lnBM30FwTUc5XBqzVH2BKucvTyY3mosi0nWU/9wYzqM3kfkIcsBV5W99DaR8l2o2o7phEDBvTwlRSrLZfh+7h/PsB
# DATA GRA0C8tHzkzrP+51rVl7LvvU1P3hG/bU/Y13Ht6/9/gnD/9zPsoLU+lcOuy35Z9bamerZxkFv+TZhWcksWhoJa6vKWfK3DSN7piN
# DATA uMnxj6o9y/qxckIZ1zc8UEp1DW6m6gqn9vZrtzIH2Ue5b8WPPisX6v7n1u87r31Y2rmhLnz0WaVQr2KuY7/a6gX++9G31Nr/B7Xp
# DATA X6M/+Ddq4H/+/9l79+a2ritPtP/mpzh2kj4ABYAP0bICGXZTEm2zLVG8ImUnodAokABJRCCA4ACS2DS6/Jh0p29cyU0qdWuqq7p7
# DATA Uvd+AEWx2opjO19B+gr3k9y9Xvt9AFB+9NRMp2cs4px99nPttddej99SO/7L5NkfcOM/+4viAF+pl1+pgrD5H5XUM/XkA/XsUfLs
# DATA KZT4WP39VKuqkfORMrALkCcFmQR1GGmvxwacFrJZQS1mTSVf2zz9JFe8l4JXaFZdWgJWw/OqK4CdvdQcdJZUW2k9Ps/LrywH0/B/
# DATA PfsUOJ1iao+A1yn+R8NTI1VzghxSjf8pvAP+9wucjC9gvtTPZ18++1JxwCdanw0J7zNfI1pKHZ31SvJajfXMWLwIv1dnrQ/05ims
# DATA zlNoGNp/DN18NG/3DUcn1v/8188/Ai6uF4/1AJaWGjUspKXGjto6vBHi8OC/wQVcjZNeMBE4Vh29ht7ucarcu1yt29XJbJ3SJd3W
# DATA x8aW8oUX8k/W9V3wfPwtufd3S/ULxYLajEtm71Ua/1BWTxeLS2+krNANVOBUIbjq9QC46QgVxmp2z9IKXN4rlXRCXr7mFX6yt1oX
# DATA SlKzVpwxdH+8VWdrE/FgdEfZ0E6C38Fmfv6bZ1+UDAeQ3Y47/5Eq/AgqUsUUZ3j2GHgA8wdVucz1n59/oijsKyBPoFz1+9fWrBJY
# DATA YWwn01hX6rCTZdz2FMKXnR4T6vRJmLEXcEL+rLaWWvIEB/UZyzaqx88/UUKN3WNWNrExAdALbW5Hb2NsjoZ1Pk53rq2vl3X6cHko
# DATA wHVJzTeDE2Np+IU2K1UENiMSJq8AfKUZLNCyIkt4jiYOVQz/rdVCDn0oL7lwFh5Kv6dhPP84smpfPv9YzQmSMRxLnyJtfUL7Nn5+
# DATA 4el0xXmnyFhN2BOaSKg6INnnnyRUAh5qSuDlxm7HVlvdRAuj/r12z13ffCO1Yhd3K9N/K65gV+lL8NTzj4Gzq5Gtb2+WzWacgyB4
# DATA RIV0fXu7sX3r9m7t4vLK8t3e7Y2bW+vvrb+70dhe39q40bhz+0aNU9WgMPygeb9dvQjYDr3U2YWp+VJ1prF7652NLTRI4CBI8t7c
# DATA 2t24vbV+o/G37+02djau3d7YxSJ8x61g0cZx+2HhIgjrbv13e7u37+zsNrZv3/rRj2srd3s312//5Or6VuPGxlvr137cuLG59U5j
# DATA Y2v96o2N6zXEk0VjDK0WXFR9KSy2QqiPZy0xXGcYvlYENDy8QS3IUoX6demVVy6+EizRvxPvNMyGSPP5L4nCFAWruuAlfe8uimlA
# DATA ek9Ov6iym2cULBHuaWICYXF1ijSoKAoORNVlEBI+V4Tzper3E+A5Xzz/NQuD/OaR6FMigh/31zLjFYwVvuqKGmeT0CCuC09zA8DV
# DATA 2Ks78jmYt+OmbTRTH2gIumnGatO9PfVVHQHr8Ltcli+uqw02qBUs+9mg3R5m6o5zvz0cdtQVPk2N6oOQIlHTIdbZPngPdw4oeAAx
# DATA KrRfrPDQZL8NTsKk9EAhBVS+NX/WwLE1nLktaucmWMq0QEoVwImsvkndGw/3GzVo+sdLYdng5PoMmaw6lxTlKJ7zhEj+N89+h5wV
# DATA HgGvBVb8KWge1FZQAghUWpbSz3/lsGrnOMZFoD7gU56/LJwHHvFOewRm8iwyGRnRElMibyapMDyXExQav0S55k/QOZAevEPlSx4Q
# DATA /KN+s60fxEzYR2rDK/lCHXDwkaoOTiuYsCdmSeLzzq4b+X2bZ+b5KPhc9eVXdG5wJ4Jh0QnsLwCL4tKJIlDOSnBR64GCqwPIurqg
# DATA 4mPBJV4TdU0rEAtxvrGXXl/fXb+6vrMBp1FaL1bkW9vwUninfYoqulISKBu99rQFlVdcXkUPWrVWQKZ/xpUD1o3M8AkJICCjwUMj
# DATA S9OCKslSsc7PEqfjRrbifsif+rqsLx54i7QYJPASWH/kKc42hSfatwpXxNsF+JiroCcQbNO2d8NtchlR5ToZTggo4zzPBbIrGcOz
# DATA GJTBmtbOb2tLDc/avjAWUigpaRqt9zCqglV+/j1brHQIrTMwouL05u6Y3CGhgbDbQYgfNfv4pywNBVnBE+yw9J56tk4fycFU9LSW
# DATA +BlpLSexxsCACaq4gj9t6LeVFitdumLD/U/64x5abGugfpNThdU/TAUgVVnDUc9xMOnm9jpVABfRt7r9/WZ3c/v+JXno9VoNTtOw
# DATA +lxmjKV7/Vi6FE48UzjAkXPQLisZIfFAsYjTIeRl65HxAgNFKuOeEroLi1IRmQLAjwuONN4/qB/G4jbv4ppQkZCvDDK7OH5YIZP8
# DATA kBRj6p7wOerIn0aPB3xBp8AVkaMeI4v9BK93NodISD/xxNKqWQeCs+1lRmKHBM/Ai5/Q0EE1Fb8B+TXvdMjhbtY5IN2yOS13+4UZ
# DATA rdtZVY4K6Gl7AndB6+CqJM9+RyfvY+z6L/DFn3isn/Gq/glXAu8v1+CGoce1tbH73q3b73jyUmyKJSVHn8fLvzN0oCxw8SL4x5Lg
# DATA eEAidMM+8TzBnoXiDI+roCUjs4T2EYi6KgZfkICe+xH6wFYXAs+gs4nDvbVWMCJqh56rWJpYX8gHeO1/m+A9nK6nT7Sx1nbvdFQ2
# DATA +haFktQHeOd9mryz8ePau+s37myInkQ98Lxx8Cagc1zblwLSV0KcPObQhYtB1KFI1TBlGNGef4k2tU9R2PqKtBIf4kXdulyxbpa0
# DATA OXDx+lM6x6UE3VllNMTuHNcw975iejp1gr1rqvrz/+RrH2pLaWqt9cKn3gDU1z/XF2/xmlc9s+2kEjdh7KcLU32fHQ9tvny77uvW
# DATA TRaEXJjGz5DF/ZPoiAI+RvwYxvQVDV0N6teRW63ZtmApa2THzdVXLtmjaXWOIGKxJl4AFS5SNJ60lhkYLWHpcD9u2oNNdnA87t2D
# DATA TYZidLd5st9qVsWih/kWrNiCYinZT319OvWoQnHIBazPGRe/P24/pL+0rYaiTRswEHWkGu9cvrz3+6PQc5etZl1KSEIsb0ByK+ps
# DATA wXEZRgLmXzyjB2Chhg/UTzjBBsaSuPP2upq5nTs3dwzXBS3jwDFqzxEFQho0qrloOoPdnEsBgkRjbOJoPUFCf0x7lAhKbQR9WJMp
# DATA Foa7ZI8DIh7IT9ghn+KFNEnSC9TDC+jU7/VS1uQ+Ig40aGnMvJfoFOmBbTulCLjZy4RO4CJI6fvFsP8ARcGg77bTQpHUJujsbEvd
# DATA uaYStQ7N8iH6txaTpOCtThFc9PoP8g0lYgZAMR66HZVocldOmNRXlgyDxwWrjZ//HE6QjxXX+sJit5h4sYYzuBSzQ6AVOEaK8oLJ
# DATA Wj0NmAUQuNg5omP5F7+XLKFRL0HRP40K89Qr1uhwGlHAlrEJV2BgK3XeG4/wCsVaV8DLgj2BR23/obhzZ/oJyzZOQS2taJJFtRNR
# DATA rS11UD+wi6kowNDDQ4ysXacSdD4AlZa/o+/07vUgIl9Du/IXqRdAxON+reaTmEVeqGqXxXBXAB7JCtBZ7itNcNLkpKP9Fc5jMT49
# DATA ODKOw4dP8G5oDSV/+FsIaQKvuAM0D6m73HI+pJIAvgz5IYaFDjHMDnJvQGTAmBmsaE+WF1Hk0nqxGK/SGq5HIUVzX4t+iUeBKAqg
# DATA B3t2WAhPG9DZYUf1bIhuulx1nSI8oVVk++KuYQLkuEs8Bu6WsxL6mzyqnPKtxRJ7nUMSCayJmOdLfzZAx7HHmUJSMsRh6hm8hFAj
# DATA e5RYhEZP5XEM7VZad7irfEB0BMSBqqDbfcoR6MsQ7rAxVhdJoDzkDzzanW9D/b98oDJL/m+Kc/1RCcXqqvz8Hw0XI1WlYuZ4V1bS
# DATA mbqOgmga8HHkgZpDkujsXrEGzinomkCY2+NB6QaK2Sy9uZ/1u5AzzZog/lLXuwQPFuY6JJRE3u/ex2xAWWPY7jZHnfvtxqhvx0KB
# DATA IOCURZNqGE7liPRlLa1Mked/yQKx8fcjIf4xWFhxZlGRAdZ7vIw/+yOcO3RreYTz/dgyI8pgZdMgswqPw9kdxqPr16pudVvHO/6H
# DATA wE7zO+yK6e5cLTAF9Nrj0bAJYBFECaKRUHKtxosBpCCYf2ObAcTAox6E8VKupG7ztD3MEsjWmjQPR4BV3u9hklh0C73CgCwUaE6I
# DATA KrohbamJOdgY/iYnpnxXOW2edO2j1Lyg5xT6Uc79Lve9el0Pidig5ywlWq/ub4TcJY64mkb1q9yauy+thTDXQIuyUJeIKzSj9sBD
# DATA kFcfwz1UR70QbcWfLrsx2jgucx+FDXeWCkJSWk3OJkYTIjaHWzvTTA5uL9AZ1Z9Zfp0r2T5CifYp7k6QarUru+j8UNqAbfJzdhT5
# DATA AtQMj7WRhw0Uj3P4LVna6Pr+KercSG2JvPiJo4hwPWHMYsXsogxMJDsvuEeyVBa/oliHJ5WbdnIuODcHPt9iRzh2Mvlewsi1hL3E
# DATA YEKdXhmdXfX0Mn6Xus/fJ6CkfrelkZmQnBb8M3WWz3X0kgJCPaod/hsolJ9/JB0oB3dLirAXeUJaZY9ps395RrGQTF5E3NxL9ZyD
# DATA Pc1wTh4VteaUAlkTZEPTmOsVYZAFtDyC/hEXL84/G86xkz8XomqweKnIRF4PTNPaaT6X/ZDkBI9tsckoCR3lWihpVeeIQBQy1uI2
# DATA +psgVIUj5uUrS2c4auROmfZSFrRpvbfclv1BSPmoNGO/jF97pQTeVKgleuPP13kuweEg57j5umupe47aDcyxpM4GxOpuFyQmwwrW
# DATA 7Bo8ATYhafWxrB2o/uE6ZFubzvAEO2RhrpQ0ADBB1DsTnBQolqOT+p0a8R/Q9EFGo0fippqE4tPjUBslST9d4tWbe45LAEZ2kpVW
# DATA yAWC9HNvAvbuMN9GScd9HSceUwZnSrZ22OWoMmXbDN+6BkuHKSBSQnvwkzaBaRNU9vjE1gnZM4ms1eqaa4yXgrNY5/w9Zp8fADFs
# DATA qpk7VqKmqcfu5LBz0kQf6nwBy+oeF/duiFIJWxKn0+8LzDrgFzZ7yZiVM3LcItN1vQSEodt9pvw8/nK74VC0GemZPbj8ACkgOzdQ
# DATA if8xd6+XHBk5rnu+awULWTtEB/lfRP87tyHSTZv2RQu+dev6RmNnd313Q8fDbG7s4I5lJooQQHDCcmfMuFDJnsdcZywP5WZy0/2m
# DATA RksccD4xhyI9OPZpbaPyzZdWWBiHy5x0MgCkdoPASNWXxQ2M/L2+kHh8g2OVYCI9ewz3SoBfdPCdbQcJp47U+tHB13AG/jpZ7r/6
# DATA 6qvmRqxn2Q4Cv90mpAhGB27f7/THWbJ5c/2tjVIyzij5AfgDPmhbKaF7I9b9qc0yAMRLq0ZCs0t+Nu6PmslPFUnAwY4L+QBjv4dt
# DATA NbXjNkaYdxCZCDJ0tfgWi2EZ44EJKefYQ2IBJW/noTth3d2jcj9zS9raQXcy8SY9/w1QDlL8Si0m9yxvgbBcKbizaR/abrPXIPBI
# DATA 0Cs3WJov0NBKNMsQ139w3MFU75YrJ+OKMENo1YCkRXHAPywVZYOqxBe2WoFuDyafhHhQ6QhXtQ2BCixW86ADWGy4pg+aw5bRJ4Dt
# DATA N18lTGp1DDbh4UwrFwgev0UXDFvh82eyjlKk2CMx8iYopT1Rl8+PyTPG0xKhn4hRj/8qx6fQs/jyZAvalQMTF0ODU3yYEjoDE87e
# DATA B+ir9+9+PwL/ZnvPO84lpFqEfj199hlZsUEJpSRqNCR9HJkKvrDAxRsjSGJDu09xyJjTXS8VP8wdPb93xx/zUr9QeKN6t0J/Fs9W
# DATA ShTsR1/PM2hx/yRnpA/RfBEfKpmZwvEJbTXMQF1yC8YafMH+hu4REU6K/90Lzo5fTXFegyKZeeyZcp1+I9I345Og0xoZ8NljJlE8
# DATA V0m7BfBoUPf4QQGBvxy39Io6kiAOam+5niwma8W96ponpkHFwazAnqA3U8f3e/aKgGv2IyRhXm6ON9IjA73Rp6RN4oGD78c0C+QV
# DATA 0tsDp/gPzTEUSf2cNpPjhfwpK/afUvw5aXyFsgzec+ZuH/sNF1ZHYMP7wCXDyDeSSccvys/X7S9KQQvGmuTTqVXI8lnB/AJ2D5mT
# DATA OXUy/pB657p29k79VthZcsoOMEHBrs0dIPaMP4R21XS64bWPhj81NU4hfXP1P/U3rj9zZlLOMUi7r8FS+FX5CJi0oNZizN8Wf6vd
# DATA jmAa5JmeAatQOCTLDzmg0lhL5/BLcbwbKFb7H1GH+CHFZnr8KTDgPNHxhD7novwJ0F9MwuFsP3iyQ+IVwBG7m8d5SbZvlsTIaU3J
# DATA RFRQC2jo3W00qZ2ezJa/W+x3ulL1XPcyZ5aD+fw3NT80Bdr79c8YWPiHIJLjK2RJH+N/P3r2mGWc887lYIBeFXuU0IR902s103N0
# DATA 3Ats3kwRTiQ70B9VaMiPf2vCtigul9r4m2Bu/oca0h8wuPLR8189/2dm3jI/EtIQ1br9heJaVAUsNYDr9EdIsR+rmp6EYtTnOuaF
# DATA 8VxqOVFj7GK/vc0BgxaALAsKF1dF/0xVodp5bfmHl2RWDo6JbrAd8q8ju9tdRE+7i14rCJlaD2flt86Ic4giqs1+iicfOiPiA2sM
# DATA eXp7drGYopzXuu/cSxR7RzpxdVHXjXoUloCUkai5X7U5H7ukzdBZ/qsVpeuL2DIvXzKdfRDoMQPWJapMrdsS9H8eOz13ho8dKwW3
# DATA o6y9AU6+24gYWSxq6z/KZyCKgdN0BTCO7rVPs8LeItfDTdTtTyrthyNQBc9nXxZfPlv97lkv9EUaaq8G7mZzG9fnODhC1XE80E73
# DATA VPTeZ2QaQTdUsv6BRxgp86sRX7eg89pDWVg+pHPHiXDsz2lF8YHUzI2kY6KwG/+SDRRKfxVjZ4t2NXL9a82+oNL0qSCREs60O6vi
# DATA r0xyOhYnpeUUD3wasXG7nwvg+TyWH1xQDaiba+NFrJboIk9xgdGdxVWyrb62g4vxjKHBOitptDm2p1ac8t3dR40Wv92dYHaAkqEg
# DATA qMX4gOfNl+Nx9m3tC8U/2BUT8OUqrXZ7AH+wosryFDQCFZzsaUm4PEeLg3b4pVrwMM8VJ8c/4NfiJP8lmtXgcEdkigRipdSc/RGc
# DATA cTBc1ISIP/9YjnYbI8ESBiNOMHGpTTZ/TWZlz2zwOo7dgFbEtxYXD4Ji3AAUW1T5Qpsl8k57R9zOo5X24WEbFYSq8wXRHM5iV/OM
# DATA SFc8bUz5+h748ScZD8p52oc1d/XN3eJR3nARmBrWVnePBkjPnTjrMASJCgUxSE69MNZCJHrfZehc3EMEcKaTilDvOn1jtanwWoBR
# DATA s02htKlNwGVIN5jGg01rNbyi5DLvc1w7UEXyBUWkALGZaCeOVOOQmxiohwUVHO47YVgufUV9qYZtRf8dEECBeL0V5QwZElHKi/E3
# DATA uBh7y/XKUKMV4ZPyisYvqkoZezmsthANSf0aHQ0JLFz+/hlDnrc6+FitKQD+A+63klEeoqNcs9XCJ0ogax927qVR6+Szf8/dubDZ
# DATA f6GoHwTTf8JYLbU+n1MUqGioEtpBT2Gj4BbBADQoh2BaH6AH5a/sO9PH1sLwOuzxBEIkF/7lF6gM+oNCuj/udCFZBhoRLJvP7nEn
# DATA YxYCOCFgQugjXB24OGECAO3iAa+Hg36XTNxwYoqsYNU3hJyn7R7QB4EPsw0Kcgf0VI8AcbMLwTuqwh4mN9DxYwBJrA7ESjhCG8Yf
# DATA xnm2uBgLePSlL5NkAs5Q67pU5cubBiVMQb+ffv/7EpusSdQ+ZWJc1z4/tLYDOmWZpewuhhXjTb4e6zOn+1BlCebKroedTOkzN24W
# DATA FeN0UljqcBILpHex7xbcgHpLTg47HYbKC+fKPXqjjCF/oqasZXhGOIX/Jzsh9Nrlzrk2OQ6RO0rJza2d3fWtaxuN3R9vb8CyAjdT
# DATA OwQZGWHx9glQ/+C43Rp328N04msN6X+F/X6/O4P0mAuTJOzMp/DnWi3Jq0LzoGJOB6yZV/PBulFoSf2yNiHtQmpLCL/oHLY8T6BH
# DATA +AaPXS3kmNjaR2TA+wxx6p4osfQphwc73lPTD19CscVtcSFJr4S2kVDr6gSPkplMO9M+zjejav91bQ12XbRCflC1stugTBnhLh4N
# DATA d/WR7RCx0Z9Z8iV84WjL4MHcqrLZgudXMcHzSRyTBs3Mn3OM/gzhegrrnsX+ZzByuooddJt0F3NanMoa1Izq72yGjrlg+UVsD72E
# DATA QDhxsWX6HD12biwCZmhFUYS2eWPa/SOsTQS44ooQ+Bd8K0bj4Jci9YDlj4D5zknxHtWfudNYTZDfxA7/iRtI4V6O8ZZrY5nq+Clg
# DATA dDVx4AjNezXShpcSWzda28PLPKn+inX90qgQa3YBK7tURO62fJAR3g7A1APDo/3lLhS7o0qxbJBbcJsYPSGdGH1nTl3+ls/5YltL
# DATA 99690/R+pvkdo34vT8r677VJeU3/uKheXP5hc7/uPJG/V8hPTjcWZzOE6jEV5jMMjHiUnO98eILs/xE5RvwT4KGIK4CBT/8kiJDY
# DATA y1kAEITNsOzQiTPtKVFNViB6R6v/q77fKMoS5LnJGiemQTebiw7oBCco/bf6mDRrqJgyqizKAgUOXlXRs0i0r3pCo4Ju8a6FUvxn
# DATA yT2rd4znVXQrTMQXa6YWHzXhAqWrIVHwZxDUkWsJsYB48aIZ88W33TYJ/fHyZJf+uDT5CTvo35XYZuwWXHI9AHCdcCfUZ0fCWSUs
# DATA yw+Y9qO+4sFeOU/hW4p/DZo3Ma0BrLLpuAeJ5B7pDtjRV3CiaH0GOoLFDDlVdR6ou/Mf8HiQ4wP3FetfDSZ1uWwH+IRQQrkrbLoP
# DATA vjJ2/qQsopB2Jz4IIMwMzsd9TiUScxgER0JDkvDL83ZCYBKM4NTvMh9ybU5PvNxImb+A8w5Y2XKP3LgWOzQ5QidnhQMVrJI0lHre
# DATA J4GvtGts0DNyEABUshLba8VVZue+jACwzjNBX1EADTp1sbD0ua3ZnmK2tp3U9xapY4brKplh0QyWuS7alcLwS8tvPYg+0hlW8w0J
# DATA Jn4ixACCHcFVzAjAcbGBxJ/Bs4yQpwO7SLKZn2z/MKlyBv+R8wY8pnN4ygKwv9hjKG6YhBOEiBD1OqD7pDPK25Js/mi4IEPTd/GL
# DATA bol5Yi2wDi/KQgzOkcC1gICqc8fNxkmHLNVBtGYY5EGdsiz9+MBY+unn/Kxplnn/seZeBDWXSx0Oqo5xS8eJch3SZ9vQc/3H7YQ7
# DATA oeu4KWGIy2NROtpcYl6J2Bz5B8U+plIb0xvdwinytC+615NmT0ngrQTUHlZuOHbap0bAdRESlsO/4kZuu4bHJPc5PQbPhUwuVMO/
# DATA lAABCdrP48RmCdr06DwY5t/hzmWNuwCWsdDt2mLNASXUmWNrtZgouZ4/Ri9bwlAjT+MpLHP6rNGu0vcTqCB0xrMEk5j0HuTZtl3u
# DATA fDcz70h2nG3rjuArtZzDOx2AktHBnnEh4BLna/Bm00msEzEbMy2boyOCz+rfkoEjApiv+A7upUmM84kDgGDCt6H6dgMCuRrEniSQ
# DATA q8DBLsCszhV67yKN0T8OzFjPwIdDG3pDSHsufgpvBj9qj2Ru6g0F4HM1JsY0DyIp3PJUZpYEK6WM3F034Ekiq88ftBlE0+kQOpyV
# DATA SMymD0DlIwSZoc9CCbJAB77NDgdBpnOwzgCRSN2oXMnE5aPBoCPDnbo9ZVlt1+N6nnAVEuJ8oaP/u4aN5tMMhY2ycruJ9NBtg6W4
# DATA /6AHGRp7zUF23B+Fxm8b8zm93++OT+S4Me5Uo9MBqJjS/U6vheYy6nTVTi8Ihn5ap2riDo2FthcKXSd+az4FifCFdHGJ62lbddmP
# DATA dsDFckiTVY9EbY0c/TFx2UY0DN67JvpB6jS8eRiN2clFi0trNNGvqyn3OxLDFaRfRevIEkxS+iXHYGNMST8lCEp8KYftbruZtTkv
# DATA dXVhpuOlBy77erK2HGga9d26pwh32DnQDqFqD/fvtyltpCJsUtxzF3w30OmZZ344MZFr+FNHr3GbxfxeSbwZRZjp2DL+0Ikuc3Vf
# DATA 8NmFpLBcKiaLSWEtKfPFTz0vBhONtpSCHVw5M4bTD9sMhpCyp0vJDEY7poifTOBptOC6KjnYzqPmESKSch2VoQXuXE094VYwlMGj
# DATA iZJZqc+rIZAyVxZ01VDD7HVcyEVMTQtofea6Lqi6iqqKcuF+8Lj4Br54o9o8aV1ae785PLm0ph7iOXHkgTKZ2RHkUQ2Sb/RFJQtr
# DATA NXjpr/94QEDEBVO5m/zWPLdT/xXSo+ODYaXTN3mklsirS/8KaY2PjQYDqBtvTi1O6abNQBGlouYTbMxHwkDi4mLobocubAuez8yZ
# DATA 8TjTPmj4R3kw7D889X6W6VI/tB3ULPe20NXNeLiR09skoEaDJja3Vw04WGA06nyOGHEHHMuz3cGUwbqjrhto+HYRW6f5dwTjI6gQ
# DATA sBQbSYnV5aI3FzLSUhS8wn9ds5hdLNKHWMdK0d5GS3pNwTmlJBqnl07fJvamsa/UNGLI0AF/0B2UMrvwJPI2aWbgoOefgJkPaUCS
# DATA komd5t98PFlAB1mtUHRyTDcsONrwpHXrtTN1NEz67vzvdPtyVBv0Dy1xWx1gJBEj9lqNBCgj5wnlnu4Ar5UIuid6no0iV/ck8s6e
# DATA wjhkAx8Jw3sMjmH8+h+WDb3yLPkZq6wtSlUEXuEOqjDsRSoX2qFsCvP9AP2xi7hu16UNYNbVKZiY2Ie6VKoFE8PNB51eD+zRUZJi
# DATA 1m6m1WHsfMDPcXLlDJLjvPZi+A3Ss/o8o9Vv5ouLtdfYj4VXBXPj4eEzATu23+RCKxfyY3tt9xB5WpQjkIehriuEGR5U7PS6M/tE
# DATA z0zoA43dPuInoRYPW65GHNbnIpjcVosRKjo/JU3fMtQ/P8pqTso5JF824tdOxkRLo9kCT/BuJCMeZwX0XW2NBy19SIVvxP1yWVqy
# DATA pQg11gq5I1REj5M5ceBxryOx3hZ999BIfaZsJKQpEcqQCHGPOuIJzLwl9QnzjKmg6s7KJpGGOstZwqpy1yehUDpHfMVc5BrrgDOx
# DATA 56JLry/Y+y5uY3sN+sMjTFRi6KtCtzAX1GU6qeu6O5GLurwshm7v/hY51/agkM+SQSs7VgTUK7GbvFzKgfk5E1MIh1EKpJBQmEod
# DATA dBTKiMMgKE/QpfKRkvtICeEKiIVwUKVAsgmFNbc91zsBY/Y/xxZRlsqLeqUZ8uhCexrM0qjwvwFOl9Tg+7zK89d5LGGQ1LDZUSty
# DATA h5p9l1pFLGV2fXXxZGwfbclmD1nb/pkcjatxV9dH+B1NgfqwxM5JaFySt0QpnruBQBjbBmDtZeTbWDQCk56ukjHUxFRSU60xMePI
# DATA 0jduGoHFMt9qXTAwVbtK6aIpqYTOYwfv+nzwvrmY8k0Jm4xrTaOoBewBT7AF3wIqQeo5cJwLfYE6F2B5RP0sNF5Qt1vw3HsCL4eZ
# DATA sPrgnhPEsD7/FUSySTJ5gzFLbywUJmPwYWLLQ1PwHEuq58IktU3pmNzl2/TTRBRGgGkgUG+JlKOkdmQuGGfqvNo/TdrNYbeDMhbz
# DATA 4ozO6HazZVXXR7THgbrDN0eM4NhRlXdO2uqrE5COs+Nmq//AxZuthDALrt/o0n+m1+jSDJ9R3ef/KV1G56A5PQB2GjWL4PmMLsU8
# DATA Rl1YUhuahF1I3d1QkQBht65qBHbXhTeIuWlVA+gGc62wNxL7JPd76g7W9TM8xEjD0RbIh25/TH35PaLlD+tPiAEjijcc1B6kEjmt
# DATA WLkOJC5FM2WIR+GA3P/QfoJWUPVXTq62X9Oz81GFHt8LI70wQ48Yul2BIZIYyvJdnALwIAei6xQbPIUzJEQSsovaj01hU0Gs1u8S
# DATA OIKPdzgEhQHmA4i5mgEaiuuGFEV1ItL5ysLEyYdPmQIE4UYAPnEH4Mt+1Sg8hCPeRT0hkENPLeHhiVgXdnODC5uKJXrzG4uW8Zor
# DATA mJ2Wp5S2YCuoppisbPrqJ36OYTRpz6hF3HmC0fRC+UOm5A7xPMrFiW8KS7uC4F+UN06df5+pp3+S+LmvSAbzgDTxkUHKdZJ++B7D
# DATA vVb7YUlLgm00DTY1QvVM2JxYNpzXk8uLkAMH/zPFMdzARqHL99Pnv5AcsH+gsaoHbvpadMEB400EJUdyZ1TdXpYSSUdRTcKUGZyh
# DATA DiYBSp6QRWW5f2l5eZI7cA+1Q/VJVKKI4u1NiQ3qXUrIm6IWOOAXI37E0ZwaJUlPlZ9qwo54wSXX+g1Vk+00IWQ62zXlkF1PuMLJ
# DATA NFcKWxJtyLlkAOnoXLIygSJ+uhJ3a06qjJk8Txy4YmYN9KK0LAFVwxQsI0U15sgH9lIdP8d/ESk40WI53pRGlt/QLFndzkCazxLg
# DATA NQmk9zqVWymhkTeHoGzEnKmE5o6VWnXB7FeSDUwgBsKC+ixD0Hf0BOu2GNJ6AIAd2AhLFOjRParEYdZDeWuWd7u9F+JyKCNofyM3
# DATA Lv+25cuqgvhfDEqEUP/z++drWeob80+Ke/1bIcac/msD/1HU5qRNdxJf2TssXq277yxGAEoxuYf3Rh6IkCW22DAFqNEgGAN3WKTS
# DATA anUyvP0WLGx7S7epGQpj2ou0C8Rso9lre0HcvGDFdEVsCCxPzjYhaJW/5wZ6LsuD5knUKCtXuExwxP9LmCEcIU49L3QOFeP5R498
# DATA B1LbC4NSp+JHJrF9nrz8K611wa42YC8V+AefAP3hPQKtdpWF85tPKlwFaPgMglNUI8glHXWg7gD3IF1Kc3z5raz3Cc4cwSo9zU3y
# DATA lSsxlcvmmMtBQIUHdW3m5gcsl845L3QYNOjM9KGtSn7DsLUKMhlLycCaQj/TOHJfR2VJjy0gagpcKfqKvunJyp0pRmheB2z2SWKp
# DATA AGdPcUSVQrgacUje+XI583hz4DJkK+rXNjpuXKckiqBwsHbVkHLC1HUlkM9taGO4dH6A+/mXVuAMJ4DwtKGom3R6TC003tn4cWQb
# DATA /D/xhp+Qqhly21KT6hpp1+NoBs4QKuikybAAthhkce1ADmTKJP9k4qFVYSseTIDnpsyYt44rQDXRTnfmMkhuyfT3XrrZUkKYW7Fz
# DATA /66qLUN11FHqHw2bFlLAXn0yJft11T3j4Wbf2e4PKexmoP4wAEzo/r596zZCRK+q/6WunytWwCeh6kIvU/vsRDtLxY9EdmR1XKRK
# DATA LrgBIYykqfZEjAKU2OLm1zo/GZT9XKeg5W/C6Cj5/iYeEnsYLzUXpGEueDozo9S7dJA4rH0YY1BXMW8YvhaD9yH8PCsczDeTxdkT
# DATA V3WZXzEO8oX+GK4fxiQfmG0qHFshxk4J3isgN3gciMuFKQ6gxRcF3vJ4cQTEMOxd7ItpqIaBu9KLIlVGcdC+JZzK/yz/3xeFHdWZ
# DATA WlwBN8y5TfrYz8HDQJsJf/Psd6WEMdaiak8H3ulbgA5k32Xc6K7TVh7+nrly9bVnZc7+KmDtc+L1WS7g2nW97JQ3j60vrbuq+l7z
# DATA O0T6c7ngdEg/t+xCDkWItE7Qe6bF6gvsuZm4pefY5fEzntC8pxK0cU+ZIpI6+oZhf6TkHXJPVHupKlXsqR8Ul6z+IMuqJYDhPYJf
# DATA 8AeT/Lr3LJkDWSHcuUEm4U/z5ZJiTE0TwlZH9kQUA3NmgPIemrgrVhRMLQUOB74wNVAXmDHllKxHG7SBmSK1g9ZKLwTeyMjUfogb
# DATA d0S8NN7p+jkGKGY6WDgZEHlf8DqXjDOG7o8cwrLiLPCoimP6KbTS8pfnnPuzxUX1qJQsLuoaJmHm9JKzHR2gLPV1QfV10EV3/mN1
# DATA UpBkAX81gN5ciTQzwqiUBRNwH3ZWQZ6IkTPLHlBecQLZyyoEUXbcfli4uFpc0LkPULyKwfJ5XygS3761s/vW7Y2dxvb6zs57t25f
# DATA RwU/NeQFSViF7+xs3MZYCetQ1C+vX3Vf+bV4GIKH1nFaXVqSH9Uz6cbkbwyTbu1XX1m7uLqUX/ubt29t7TY2tq43rt+6ub4JUfrp
# DATA 8Wg0yFTdQGpmRdLt9a2NG6aYfuNXuXPnamP7ztUbm9dMYUeQGg+7WcFZVbPysLX2LlfhMvX2e5vXVc/Wr97YUL3beHP9zg1YGiVl
# DATA jNvhQG5u7N7evGbmutk66aAvibyAFYuu7OpaMajtvY2rb9+69Q4TROPtjfXrWG2ULlghrzYqBCgyMWtJ2d2iRHChkDxojkbtYQ/j
# DATA 7P4OJn7YriAKdRt2fhGD42qVxe+nrtwm6SH58xL2AoyOlZseG+XuwSfjfVOe8/c1qknAYKSyw27zKKthlVPy12L9F2qIo6pqCNnV
# DATA BXxlMwf4hJkBAj0AL6AJxsDO/bY44NEPuRTzKzfOEfMfCcqrnxIJfr+c3h3e7QG868vncutDXFKt17gCXjycDYp1n+aE5SRSNvI6
# DATA 4LHDH2RKZMnNMd0MmqdguFaDA2tDBf4G41XWvrRW2b+0xsY0mRaBfaKAIsdROpL8jevGk/Ze0UXJ4Xd791hgYEes5rX2cLTdPoGd
# DATA 89MHo+3xvuLb7zAiveqJ9Rp+qjfwywfMJa/Xd2HdydnVsS0UzItSsns6oD+DVbEn9lPQ7LGfI2IUS4rFR5hAgDR/BkDuESDGADLs
# DATA h+hQ/NGzp6iTJvUsIjU9jec1Zco8fFkLNrUzorfJ3Z7pUC09Y+BWRdMvMw0/aHZGhFiCDLQgIWqdk3Z/PKqtLpuQYitSAGPdFTu4
# DATA iegjFEKoVq/V7CpJMo0Ci4QnH+uPoK7r+EQwHtydYxWDJknXxD49al07h3BEt6ck7MLQelUyWwKj2sGxaqkyUOuvlVymlgBQAohu
# DATA OXnNKeOZ6l+rJSsXV5ZfXY1u0D+gUwF4ETyCu5+b6Ca60o+St3d3t3fKBkZHB7z1OOW93RtjBGZdVrt5yCxTkvCW4X9XN97a3Equ
# DATA bdze3Xxz89r67gY+rSy+gf+qszR4l1q5tVV1Ow7zgmaCAf8+HE4wGL6yWtpy0ec+HMj9wMsSnmXdyvbGzQYMuzHqq2P1Nv5dgE6o
# DATA o7dYrEiycDNReHDAl5Tku8EoFw1+WThoohUNbgjWdBadGioMv4OHSfI+1ffuxu3NN3/c+NEryz9Ux7OasvUbjWtvK4nB+VKd452T
# DATA 8YmVihe+3b2xw+708Of9lcYqe4o3W4rmgIhh41VO+mqKwfetAGco70UyOR2DKSUo9JquwsJSCZDVOqPjJAPt2kgmRfW2ByZ2dUMo
# DATA pCurr1aW1f+tpPokM4xAjaewCmHpDwuVlZJurux3BRLlNjPFSx9E0oJDB2SCHgybgwb1pqBKk1quPWwIn6hp4QrqU4xrPMwT9BVJ
# DATA +hRDxYFZDdrtIRLLvrqlD9Va9ocnfBBpqgEGJuRXzb1WGZB7wlj8APzjHLQrsC9CNMg/SXoSG7hSLXiZNjzC13+YFnNuLdT1rA3s
# DATA tFs4TN/a2FUsDPbR0kplBQSCt9XUVJMzmaEJPLuml1LdrLvgLgCSg/r/kL8Nj+NiMW/2VpeXgY11UPdDzSv2eb/wysqq6OmKeyt1
# DATA oLO15eX8GbLYvX1y3trhY9M+QjfBYcg/Q+UKZIgYyCvrttuDQoVvP7QMLluxExnzGnyAGNN/Tiz0yy8pKebzT66IUo1Cdz6RPMu4
# DATA pqUoW8bE6f9BSWXAVorCX5lUjWLNx1+cB69g7iBZB3wL1LFlm+xnXgRRhlFv0xTPXqlDh13j5f0wpQQEAAeULOPuXVaXKjw25Yvi
# DATA BFjPlbs9q+hetVrPLeeIu4dpmtLOTM7OFqwqxr3Ow+rS/eZwSe27Ja3EXhqOe0s4ERXY3FBlgirXBty1+wf97pWFMxrcRC7patfj
# DATA VBiCvkJWkqzbsI/4SGujrneqR79sgGCf8/Vg2LmvXrvfSl+zBNl0ZZX/vUhFQFRaTfq9KwvWEPB2lSX9w8MrbANRx+TSOBsuKaY0
# DATA bNOkLB2PTrr0vjke9dFrznzShu3QQKDJteW1ZEn9p2J90Gqpy1uzpZbiR+VrdDKXQRIt36ILqaLJrNc5VFJ190HzNAu+ug2AKcP2
# DATA sLzdV9N/CpJ152DEnnzlB8ftXvlg2M8yfuJU0+2TIiT5u39Ilh7CBIC3zJIQBR593Q4E66kjorHfb52SdLR8Rb8/Gg4OGiSu0KGS
# DATA XFxezrz3wPamvQfugH+pq/40EsQuIglSBZOJOww1irt3K4U3XnrQ7nbLiOuwVFSjUSdb7xT8nK8En8Bg4VQlr4Tk++NhB/+zlNTU
# DATA QmF59f/UfmF2cDhsZ8eFmDtPSVt/xZ6pT71UH761VA1/OS3R9qlp+wYK68QzsLSvacqxhnqPkR+pFlawBdRq9dqjBiogKCCOWzJP
# DATA 4dDkh8g00FNTMYfuIQThdFP7HVW/tnZRnnZ6+/2xWlp6cRne2GBFdp2i+Cs4ddsXjPhdGDA8H7N5nwXtD8jJ/dkXiSuA4rU4LS7M
# DATA UoG7/aq51xyd89JakaBjlBcBjyCKcPtEB1NEJGMTFvcpxq0ygOg30l3TNa0/3MMTIBYhx/oKf0kjixmGI0EoHTVBsXQX81KooAT1
# DATA y2R9e7PkrA9gVLM7yaPkR8PmqblKf8kRdJJTBU5zyyekc+jTcgTsJgfa/bcY6ATxhlvqvrx+/aa6LrkJ6T5l+eFjwMOGO/1HdjzV
# DATA p7TSJoohhvauXcSCANMAFzfP6yxfr9TtHx2RP9pZ2lLHGrqFpKChKXMa3bQ/EA+Qs1Qx6jLwaCh0cRm1I/AIi6pHr6TMACHuti+A
# DATA PwggBa/HPcUEs3I26kO6FviYm4cAfPorUFDqCP0z1/CtvYzZLtuyHWomQTXjbuekM6J6en3u71ma9Q+hZyvLa5dfefWS6pA6dlvm
# DATA wWQymc9PqjkYSPIyGjpzaUlaI0n7yJXVLKmkSi7WSzEJGZYrq+0dmntWVbQ0VeT08c8YlLG2xzboMt2Z6NyDk86Ypsm3NasuqVVe
# DATA UqNY4gc5NbfaYGDMGv1ezTadtvZxNpUY20LbEYIrMRaDEiS6o+PTdOJYVckkPvujSbQb9BqxEVU/RorCwAcpvXbzennn7Y0bmB/r
# DATA ALJflQ+zHRS91NEPh3IXDk2YupUlqgM9zzHJopoT6MHKMlotWJxAos7IIKwkH/R1ukQHy3DUGKirfr9FeyGzzcMhTwmMtqCCHKh3
# DATA lFNmL9UMJK3HUixFSEvbR6orlytr6QsTGV0hj09Q+Kql6gJ3sk+1iQVMzfHuT2CYd3avwToa+pIeGpHK8oGY0tw8Czg4anQykP1O
# DATA k/Kd5PvfP3PMTJOk3HIeXr86CRbz4qy1XF2e2GEbiiZz5pp2DG+c6g/Lze6g0wP2OO9ey5sMaEedN9b3eDWAbpbLmdoqmOsNf5F1
# DATA H0DmSStNTxX/PWmfqHUuD1BEp3dttY1wU2EZkHqpX/Db6xr/g4KvX1xRODL5V199lV4BR4K/lnMHlL+0ximmrOR+rC+boz+Qn/Rr
# DATA rqzlO2exLVVKTanDlpCRWYmRQoaF/zpBSqHoXM1P5EsiX75VMP9LvMmLftt/EXhoRD6tiRgA3iTBa3CGubxcSpSUPcn1RWIBbHrO
# DATA LtuEEZO7KJedqE7ISuHITE9JzE2jLizZnu2bE7i61eP7N1yjkHpJ0qgRDLz6dk9kD6S9XKe7KI5g5Niawp3t74VTgzR3SNEvzvvY
# DATA vouJCcEKg8SwEt228UP9xQ7n6buf4BzVvg/t2iynHbYhfullPrLNeKDvS8gAes0un90vFyujY3V5GNZeZ98tiBUcFYaV/r03lqsr
# DATA xWLlAMOhCkWvhHqVx78cLvPKLC6zshoRBlZdYYBPCIFYg6gnDxVCJ2UzDNJway2QuZGRcMGnSDC841dz9gq9zdkV9La6ak4z99B/
# DATA 69b1jat33oIxnYy7ow6ob0YHg9oyCAFMdOnl5eplUAjAzb1Kt3f5c2ncGkyTAuJCa7A9rkEvKawBjOvVJUUjS9j1Jf2qOuzrFOJl
# DATA mM/qEvzXPCMVa3XJTTrjNS7RZ2dWRRim5lXjh65pf/EzivI3rvqJHe4mf8IyM256VZqeWCrw0bCJV229epEFJ2XunhEW2afc2sAR
# DATA pAunEO7Gua8wSpQFb0RW4cCB9eIiJ4u+NUfs1VodcxHnMZamEIeSG4Qsolq9tJQE36i7ZuZ81D9aysYDWB10/4x1OWTaYDVegnkQ
# DATA wSvWDeZ4OV8f9Idt7Vcc+xwxlZ1S9bhUg4okWMMYHdXdeJ6I5gmPAbIpWO+L4aVF6LYuvqbByNBsnr8ko24GezXvbLdMJHlMC99W
# DATA Vyqrlw3fihHnwvm4DBkgYH/bbIY08PC00lpiezAWQoYznbO94NSct9bZO+CcFT548EAqjJkioI8e+7RYlr2AL8ofJ99EBJVRk82O
# DATA oQqCqELyiODtgJTmhVnBL79qP4wKo2IiMVQ0iSwlsXdL1d6ufsWoYtAFtXUwR1lFzDRlz/iHpzQXD0/D7lJsVjURfW6KGUGsniKO
# DATA h84ENaeKjL1sbLn0zhCkaz/8ZKrX5LkuXnZA+VmYILmakHnCfUNjD8TnaZsoJ1kw0SEkCq7Af9YKxeKkGPbQB7oRzjr1nhODsXLG
# DATA a7tb1VwtP2nkxTGqRjphR2dfpCKbpLP3Sjma/GLMCdoO0gOiUPzDCRYR7BhMh1cCy1n/gW9KYntNv9sC7v7ACxrgzCKOwFrA6oq2
# DATA PyqI16oGJ0QLVQt2SgPwh4Zd8bfv7TYch+UU83td36S/0EvX9rOFv8V9FmCVTZNePnRVjlL5yK/AF7kUcyaGhyaoQf1yYhDcSJkw
# DATA tkgNm6IkXqrB/JFrZPu0mHu3/+86J+jTZ3/mKCJMtI3BtJBmOxI09PzXBFQANVNkoyINwvohf9sDtQkUnbRbhb3CCTkCgvkZQiD4
# DATA 5w4l/TEPrqtLY6eHu8F6evu9lAOzMRsUxwjexOY4KWtRKKZBvUDCaege0R+GdPi3RTXgZ6Tu9BCFJpmLYAej1aWfVZjWuD+Q+O3a
# DATA nZ3dxu1bt3BFUIWuT17VWyuL1BLF3arKEXYYtV0GmUNeCcishR6G/WHjphkZW6joLcR56nGa5TXPOLNNgT+g6r+X3JJslaPjYbtt
# DATA MBLLkMYIU0DhAcwtnjRPk/02uAa0W5VkA+FUJI6JK8SSgME2aO53up3RKV0SS+KijPZGEtQUq0A9GPBZBHUY9ZlTdDKBVjRQCbRG
# DATA XzcqNIqfIFMtjUEfI4xmarA40CQMHVYCj0Yz9cVgX+qS1mpKBRBtA9ZGpD3z9GJd8HjhvIrEVflhenZTkA+G6SeeWmzO+ig3l9gg
# DATA qeoVTwwctrtNhkOj4mYHVORdY9SnDSUR7jbuAhzq/oedrDHXt2HiZB08wL2CtQVjszyoUHIkkFZW8eULpXVzawPXUq7LebyCyT/i
# DATA K7AnC1UP1yLcxfhL061FRcToAz4QY+8IvvAJGaO/QCVuyNgjeTfVdZ22703W44FkcFURK+Aswe9rzcF6q8V/XR/2B1ho2LmvxGow
# DATA 0dadk9g7900EITpyhHX5KOjNgX3QSBhhNTlDB93moKhkIXWpR+KzU3tdW1cHPod9NxGjo+AF8YOzZMBodLSqOmvceEJYBOgNHTjc
# DATA L/jHHDb4yzpqIjGfMmLmk1JRTVefvK8kC6MwmczPCewmcCrz2yifuw2dmXPm3CkKtTh5fsGo80con5gKqhpQHPwq47sMbpJYb5pz
# DATA Ta7iVRqUvXxjTiOqHIgas1Q+0YKh0gYx8KzfpYWJBAdC0lWT/TWGZOEnf53fIUSAweW9iwtuqvHrmYYK7uICRWMVZmKE+/5JrJUs
# DATA nBNKozg/fpSNhpEPQjpzvJSp2ILI0Cgw5MkDETvPf8549MxH6SHMwFfPf+2wVvT2rCW2mqGQxs8cIG/7Ilk5bj90MvieTcV1maEd
# DATA gY7wc/izaOe0FGSXQ52zqaSZdE6u0iDmD/HKSJSjs86Vmbxlt2V6k0UKw8rhTeSSYKVRtW52OaXBnI7araXU9UOTXoYwDWqZIIhB
# DATA CpTgulPjcwdbqaJcQce40xjEmcj1hRM65F7A/sXdNQHVWNRGNleO2cP04zG/MvXqI/eaxplXp4M8aEmPvJFxtQP4Ryt/L6G8fN2k
# DATA sPTDSQpLf1gqEze/qqlYVyQEauqwqp64CTNVXYoHH3TBOXhL8rDuNoebvcM+wLAi+iP/Fs4LaQ1R+dFWUld71AT7UAE8TksJxE1B
# DATA 9gIrmKY/Qtxu1ZHmSHWDS6jeNfQe17UQqKialWWgTaiyAu44jrpLHgJiO+C8Lq4i4WMz6tGlZFGexw5QGCNf6bgniTSOURftVoa3
# DATA wax52E7QW85S0vMXldyeQxgSdGTBTBRYXBsDtW/yJggHFM6nFPSzCaKFRrE+U7Eu6TV61BtDKuxvp2GpPK/xTAn8kGokp20O+cRC
# DATA jCNHQKQjaGeAuhK80pvlOukcDZnTsdSAquKDkZ02nlsqUO4gkzkHVqeBy1lb1QRysUTIDfxiZVn9j/v48ssvX4WJSSgAgFQN3f4R
# DATA gsYjsXBGE0DBRKTTnrq7A+Gg7zoAXd6HTqtutCuqsoUwR7fNhWSTHOBhUEuWF3TUl+xByGBUgL/6+z+tyfDI0DN8n/Jqd9Qerfmb
# DATA GIPAeFq823ob/WDgyuG/Jh4HfblQS1a8ICPKzEsXYKyCwFLpihdipIwxYY410bBdw6+VUNbcV2LbeNQmySytVFLCih2Osrzj4k4P
# DATA N2ov3NUIJquxObAbaTF6plEvOhnJhOKarh8zkqGeMPWIibs4pVeaiHsxhgP1hL3h+ik2Nlm2mmR+Z6hYXVCQZvJ6YLG5gKvpjZSg
# DATA D7PbjZY5toGZkTjx036nh0kGFklXEJtG60NfWcGUPkdfZYYICkFxAEVqLVvGyZkyXrwoYrA1hfH4O1kzHUZrRFGJ1nc5EfcyEoZo
# DATA T8LJPegT7tDl/qvLyxAsAkg6GYeDIKB3o3/PShY68xJLfELtSWtQectXoea+Tj/guD0ejzrdSquT3WuMM0jhxqtZOQR16WsOhV5I
# DATA Lq3lHb9mpjfV7jg87BxAzBPg+N5DJqvErBNkS/6Gtvl+VBUnpzIfB7hfqVfhaOibIMnqTIKUCHL15Yna/+CL6Vb+PYBQ7o4zLAwh
# DATA wrCBGCVb0fCYTFuy9y2kbDlAyGwVCzuGLpeclcWzIH24nyJz749Hg3EkF5n9xcGxIoACrr+1JzQ6/MrKCmkOEXw+JEbSU9PdJY/0
# DATA TJC1Lh3fb/tdCG+0lKPNVgGCpPVnpeTSK69cvJQfdQv8BmuZFXIcWckHasZGw3EPVqOVE0lMM1phIHxoKF7OTEuZEl/llOX6DhV9
# DATA HEcgw/tZ5TA77R0UpJyaxF6/4FoV8QTT1sTBaUzqsdQlQjYO71V/k3sCKQrQLWyQWmoWdHdAyG3aKHA/rKCrIrsxsP8gGavFmXAb
# DATA 6REqB0tRC4Le7beb2xv4vD0c+s9Z+umcYFgOWGCaoEWt7MKTwgp44krxe51u1ypeaTXbFFsDbMt6jldfASCBqFBVROvDncj+IMx/
# DATA ijwpvaDhlYIrpA+jDvsSSHA89LiMdIlfLnhgbHqoBTvhj912BUPUrdetTvOo11db/QCWxSqsmqLNtXLp4uU1P1FDibqSKfGxrW6B
# DATA B27iKacSv0XtxyLlAAqlYAGfGEc74pXga3etP+62GDZaiVgoKgOzQBnPHgNCBjKfdt7Yt0CaRj8/I8pt1GQMoOaanbiMszJea/bw
# DATA 0qEOne4pbizr7Lli8qqZLSJJIVqgPMekClBTeFvShA44sd224jbb9IB3irgJgC+KNUoB6FaNdm1iReI+AJwfmzbIJRKbGfSBauJn
# DATA Ww5l2a+CNSRWk/Wag+y4b2+KAigNVP/HPXs7q58lYkxYqJbDo+zQ1ZGnyoii33wvWU84VE7I4qR5T90X6cCEGD0wrXZJdEOoik6b
# DATA qOhnYyUuQdaQdmcA1mKu76B/3EYERhlbJbmt5g48jJN77fYgczPqmZWnhBmKDffHgIZZkYTpGn1FzUHBZq78DuKEeaCinKxD/gZ0
# DATA DychTIm7asTtBp0A/BDQPuRPb3OZTjlAUrozzCyKVhI3T7+42SL4oaBniZ2XmS2+MNW2Bvr2uNdDGSiSWojS2n0K6jn6E8EjMLVO
# DATA TJv3laMW53xoNio6phMind/HecGgNIgpyUFZyWwVRm1vXavG4WeAYYQPWYw2Xgwv2cpqRjp6MZspVO+Zes6XeNSb40fT9KWWuj1y
# DATA J9C3AMv3AlM0QdKjTi93p7pyBgCqYsIg1kUqKscpp4esjqy77mu0p6ca541mGyafFbI5VmSqr56XyzE+q39BfO9P5pg+o8cJJtFO
# DATA I62mqcXA6RbTdPZZIKO5WniooUJ8EI7tqnfbuE5MJjNX5l6Lsn6qGxVcKMYdyIuk+GDS3M+A23XbR02ErhC0QlOZIWc80Ei0WoKo
# DATA NzhM1Z94S2ORJaskW5BHKMkeoOkauWUXAQYr/n1ryqmvzVA4UJI0MCbLoQfnda7N4F8ps8mntC/IqG/boJ5GF1eSmBHO318Y8uBL
# DATA Se0RzZ+CUAmUVeE3Gn8rX4Pn5z3aE33kItPQ8Kjb3y+ki2nRo1jQ5XEmzkqXcNNi6ZKisGs62662crrpd4vTJpKtKgK4BzksHwEo
# DATA NsFCQFLLv2gYNrD9PQ7n9Wls00xRKWqtBgxao8NZI2QVHN1Q8zSMqL61TQGWojd3wL/PJQmhiMfPf/n8F4JKFcWkAxpDokDfQJch
# DATA exOAA/Lu4sFiySxMvZ0fUDrtHgCyFWI8dgr3RoBmh02jV8Qs833RhsHGiR+S2F3AvyScw0+r6Hnm6jyikW+cPUMyHdylYOMwuqKF
# DATA pAjKlU5/nKVF5/GQsiKfBjuKUMwIW19qtg3o9D6uI6Z3c3qaMFwa7vka/+IuQ+JAtLy6SjsEU/PKEh5bpDR3yZM4tGhxaW2CFwqo
# DATA cvpG905CTH0hfA8xvghyhTJiKPb6BTlJ2cnmBZBF7Z5P4VHYVWcygMgglgIxCJbUq6WHw+YpZ4aQRaHhnxA+JnyyP+61uoBsMbej
# DATA j93oS7MpG5GPacZyJ+y33qifyJgptS9Lq08l8wDlAbYPIchLoCaQswE7YhxmBPYSb/nJo/3EXVjVE53VAFFqOfus38E4/cgGZEqx
# DATA 2KzaFHaGSLccSb9TpypyGtugcfZpLHNjJa//A+XZBbQ4D/LT0NiC9vvLKBcgLDKEwlhpC9cTVLcpMQwFDnUt7th6Z3C8Swb9B3Ct
# DATA 62cZpEzGnHLNIVkdeu0HVmV0B7BciBJEys2OUaJ5cAxJF+Q2KZbBZu80YdUK+NBWLIUN1dIhJCEL2wokWyUb4PntyA0otBtZITg2
# DATA LBcO+zP2ObcadJw2EGqInDbwT/YEBdUEgG8y6nDVNzBgCAYqsdT0o+qP0/9llVuN29dvbd34cfI+/RLBXD/YuvXmrRs3br3nkuQo
# DATA xlu1VtQ06X4V6EisL0llZX/JoL2g0m2oi7y6HAtiL+czqgYXxa/l7M72cJ2sPB9l1/vmpMlJPtLbUnHy/33wO5QzJOmZna8ksdPO
# DATA CwahRKSiprYtwiMdqzqHT74LWIVQqAqef7eIE35KhwaDJO35wNCEikWXQusILHopIuB1CaMcWciDBz7TImpdiGXjlMklPK5czIGs
# DATA 0mxRqCZtELOJLMsztu8kmbdS5EJuIzcBPcX3Gu5ZXchvNfYl40+pKyEyA1p8RVmYwPELXG30oXv+keTCRPpxc8Y++x9T8hKaHJp2
# DATA Vl0v3A2jc/BKKWmtIHPQ4l6a4NcBQ7K7IfGC9XqsVkB91YfTn8jvEXLyfCCIbeiXNb0xYmN6Qot1Jw2hfm7mnubzApg6EjuQAa4r
# DATA KJibVEJfJH5C6GdPrniwc3gQwXrJJdBLPsgJhypsJLFahxnAD3EHf4jj/iVgt1knWyURrDs8JVWpLzDp2AekzxFMkUc5SQ8VA8+S
# DATA crcZ5kggx82/qIJ/IFB6nSexglk8dPrvD50MghjqhAAk7BD/GMmJ8hOKu92zp5WwwZRo0U4Gzt9gMnCuFKYWKdRQJqt0NMpDmKHh
# DATA 2f9tEGTV5cz1psU0iKrKsEKKcQ9rg04+IbL0PXMVcYb1DNtH6jYD14P4oGm3QhXq6lhNDlrRTaceJqQdluxRyQAjBtCUyLwettY4
# DATA k1SWGEga3/j1SGSCAYkoRQBVNI5GWbKHVEYPRzrDF4V9lyRCu0RB1SWexRLf1eAPiI12oxhc5kYuPfGU5bg77BxNaHSMzJfUU9Su
# DATA ZQMSuljeYJv8rCTxhVw9icllHk8F7rjRImP2VSeSz/j3kLiY8gOSAI4b/M3NGxs7MMOBsGvlNQ7zr3tY0HbaaBmyATpWs+EeK7pR
# DATA WCfAsAbnnQJOepGTcvBZhgi608+c578sAdf5uUnQ/NROxxpn5GlqKNPQMJInRUMLBI5j8Dmg3D3BhgN3cFOLGoCvK8DYJvjausKI
# DATA MdC80IvvGQaxmfYQtbWol6BPvCsTTtUFSdQrPaFVNFU4Yl1epLTa6+jj/AHiRtmymyEKFGZy6i26i1zMawePUznLEzeNlAYrNW3o
# DATA IAJznlM4ad2Xw2b3Ll8mCicUpuPfXCqCI23umWB8FU/Lhgnp/MHZ7PBmjlMRcpCj9qwe/56OZ6T5f4zAf1VZkDlqz0UT0+nCwhnz
# DATA JiZoYF7i8AkkaCJCK9SYJ/GZnc472Ihrwdm5FMTvq6O5wpda3tXFverFVfdkmbmHAy0Qr390O/MCE0WMexLu20pnVWoRQDCOcyz3
# DATA PPQeX1ai9Fidc211M+rcTW4N0YLcWkLZ1Zbh/kIaLP+s+Jjxhz9A7RQOLcGPnkhm+GdPQ5lRWnktrPH1JbJZMdxUeXGJxWigUxCk
# DATA Pdkymo3+2dMSaKO07o6+gnxAVjb3J1GtXNhZEIR4Pv5jDnmUUNKY+uUSP03wTEs6Ql5P+yNOmwAiBpf8s46qcpCSQzH399aF4wnf
# DATA YB6rvmG28QQGjh36jK8QeBMxs8QXQjHRSxZxbfPxtHdKTJBQ2uc/l7sQm9ZRbajlFCsdFsswwivi0gsSppFeSJWDME28a9Efe4i+
# DATA oEf4d2V9eDSGprbxjdYEqR1bazSUDN5oFK0v4YreaPInhbQ/aA8lTOrguA96kRpj+mCupxRDyTI0NHAiXErBjbAyIOOUWdzGb+y/
# DATA dU5djBNIGcmnORTUO0z3BX8fEe4d8a8UMZmz4zLtFiyLCXasBw5XAvSY4CGjbgbPuX/oj1IeD9TJSHHNgDjVGQnYD/UmG4Hi3Hok
# DATA qH1lxjTAKeg2e5bfAzbI2lHvsThT2V4SQ3bG0TXRjEJDZe6APVk5r7nz8ZcyDnrrTAYmo9DLZVAc8B6EekNxYIiSTrnMNrXilbwC
# DATA bKLLLyBuQ1ObMRdBm0Y9ATu/DXO6TG1FEKOmdJYS+ua+p6XOf8+kRODpU/uCGZOn1DRkpySIzBweZTXQlE8dm6KtaR2jxLdmNXJL
# DATA WgomvfrTGjY7hWMFa+mMniKZqs/KkuayiaayWopk3MAUmdObRDyy/tevA8CRyicEfGDILi/dRN0aoikzZysMsqwrwMwXV6Z+x6BM
# DATA waeUNWNas8Qb3SXJbcuvHkHopzOFCHOec/GdT2m3zddLV0wNuryyPHPr40llVlnniUf9CuNR6xrp7ey1PddMA2Z4/ltOEceNsnc7
# DATA l8V/oHRmYADgV0Uf7joHCB/qRirxUzviTQI/Rm5WFNixeJV8SlRdDY4Ynfy6Son1hEJ0p1fvn0tVLypZbj52jT5YJjoqBSHMftf2
# DATA HFg/SxPQ7jX3u6gygSyk8+GMIJqJgdRQVLR+44aLP+KYlSQvAF5QUGXnvB4YOBX0edZRAPZSAxAZTBn116Sd4f5H0YKdEG6nExqR
# DATA zowiJ708fNYCgBFMagCjmzbKFiHEcJz/fLMJBu9YrgSjMLSWX5s43UgEvYjO3LFK81RRBKVDp1IEm9jrp9OJ0xZSzfTSgwa8bJP7
# DATA e8UgL0ytz5ckz0XsDAqRBy7CB3tDHVT0PT8olpJYF+ecWquIOPtBB6YPMyYdW35TER/8czKNqXK2dR3jYrbjvhRzh32eRXQvFla6
# DATA mCyDvKT8QhJ+ZuHYHB7JXBN/8Cclvd1no2ybmmS5NbvgB0TrhRkz6l2ObMKEFw1+YXWaexmfwbwBTe+Efx+zFeok1jndOM+mi1yc
# DATA /A0tZve83WLvP0oEg0gJXN18y4xPuDntLchAS6QyLHmqerOpzWcmnsH9lNc9zIRgOoK3jmKEW/D9oGG4hvnIuhE0nP0ZOARPG1op
# DATA mTUCz8WR3Dw7vcF45CCDoNNF1dibQEgn98Kq4+qFLydRXkYxP4aTTWF16OVuocvnkdm0C7yTcg1LzUVBc23Zqc3x7p2PXC1KnWub
# DATA 5qobwn1LHXDwd7Go1Q1cjJK1BblfM0yaqrpZvM3VLVlrQUmd6fm5WIrWllWnUY+UKsw6mi3E6ygbZa6H9qcZYw30V9N7yKUbXHpa
# DATA T0Megj/4yxndMipFX+QpAQQ9Is1IkRhpnncGOb2B32d9NuJPORmF8gPk6am8wZeUHHdwaytdiQNCw21DDfxK3PcIBG1tQLGatcEx
# DATA 61E5znIsn3EsasXuVBKhnauKFabtTC1kEqY5/SCc2HBuQWEwg15CBUPVF+m1Oj3EGY836XSxeJ4OiKZ5zj5IOqhvuhsz18ppa+aS
# DATA aeY5xwV9ZtMoYUOT+V6mFOGGaLsUB2CRyTx9YIB7swazBLbOCSbByk5NrLX6u0IOND0Q1gvLFhh0A/lro2HtMY6WLAZ1amR1x2lo
# DATA sER5G6ZYd62AhXlQFiHQ9HP0YsOMWmEcku6I5M7EH4VBSTJ/OMSmPzNdpbA/FzXlivVeh/e88orPDlUZx9HKSXsesgMXjV6z4hm5
# DATA dTUC8AwSIQNUeLoIW6YkzHMdtzqNhX2UTGVvlHPBGo9TMI8FRPKXRV7YzbjpJ0uo/TGN9vr2u8jkRhfCfuhkAfCTPHydE8qtYgNA
# DATA rLYhvJMSRcyoZo5T+MqLnYFirHQE5iCzQSB8zC2WiMZO2ynKCLXuYFOIy512WEUvtb/orMjgozYN0jnAJ9X8YdZNJa0GKkZOIRRj
# DATA HkFZO+eQ80E02ZB8BaRVpYSHhvuHpWgLVt30x/arYkw9Wk06AzXDQ0Bw6Ay0VKvVKZzp3o4Kz5skRJpc8D3/A52yVO2AjlqxAPhh
# DATA CRHkQ9j4vBgAX7hQ++M+5+WGWzbFBVhoLU7CEFODFT+Qf5VDe3x1phS7kJN/RWwWVU/hk5Jpp2rx0Em4ZGzjtJFPqrFcKlxuPZCg
# DATA rUpmS8MLC6rdBpJSo4HDbzSASBsNngAncIccMhYsOJwQcAVwcRAvpTpN6JA9/m/Pf6E27x/I+T3Hu2emKzg2p/gLJmgDcYaCyS04
# DATA GwSH2TnNRu2TDcqLaA+i8C5QBfa+lLzTPuW/IH8H/3lrh/9AJI6/3bm1dR2hdvBp0Q5K20TVDGaR6PQOuuOWIJ1haoismvQwsh7H
# DATA nwzbPyVgEc46D3F54243gQYq3/L0VZJn/25C9p5/QrAcDJOgIwdKLlLHLynk0eLLFETg5k95/ktAlDrXavzV/5r/U7tsvwsnp9pG
# DATA lcHpt9IGBMVfWlvDf9X//H+XL128qP/G5ysryytrf5UsfxcTMAYHe9X8X/3v+b+XX34ZNpLijmTKldA/DLWTPDSkdOsAZuCw3W03
# DATA M0A5ogjTlcpq5YerlYWF3WPw4bUL/mysRPRkdKzOCUST4wARxADtHEFam+N2d4BxKMfAPgCnUL3tj4+OF7CQvlAku9e2ywSiethu
# DATA AkgRmlEhRtb0kdN3J8fN+23VuzZ4loPVslVRfWsPMfy2pY7UfThKAWir19em6AP7kEDE1oftgzEF/gNwFkiUBGK4AEC6s46kgH+k
# DATA u7PGc6wOJbvT6XfEcZz4nIOfZv8J+//VS6+s+Pt/dfnif+3/7+J/6Thrs4CdXllYUBshGyVnyfawk500r3U7eOGmX8kEAxpwWxfS
# DATA vxngw6UDLJMWr/C3P30wsouBOPKgvU8mhqJuYefarW1MBHILk04hkOvftwt7lMQjw51TFThw31k0qwLmmxJOJQcw5/4IfOL5fVZl
# DATA R9b8AiDqq2rq0MPDcY+QOYbtcQanY2HYf1DklCWSX6//IPnrv4Z/KpzRxYmVthtCr/dUlTZ6HPis/XCgJmh9hJ/2QKZ6//3EefE6
# DATA Ztu7DiJ7sRh8nx2oS0FWUXz1CGEtajyn8uT99x2ZfK5vLiQrMiouyhJi5kau4HwW3U5xTSA7nhbw66T2erQq/F1UMz1ZWGhCdH2i
# DATA Z1xdE+934C5SIOoqYaoNSVsmawBau5eW/m5vufzDZvmwfnZ5UtZ/r03Ka/rHRfXi8g+b+3Xnify9sjr5/lIFEqNjZkiYf8hHYU0c
# DATA pEnoH0rStJdIywV5J1IoTI9l7l5LLq4WAT5UUQasG2M7bvbw4i7nFB0w6ruW2jSdJmRQuSJgeopuiJamU5JdXpzg4FYFDmMJTVul
# DATA Oehg8susApBXd3qdn43VvS95AOdgVW1vHO8kmXDjS0vJ7XY2Vm1jUqCkiQd2Ge9kArlVEscMaA5p9BQPYYCY6GBEoOphswu4Df0D
# DATA PkcPk2Hn6HiUVfSy6Q4rMntJ7y95WpQVxsn3p5KdwBLkJcnBcbN31G5dEWslSgOKfkZ0X7EDrsmtl4ZKKVS6ajmh9pqZQbWgOVOI
# DATA UMowfZjM3Ooh0SasWSmRXVs1mxb+U+n1HxQgamBlOVlMLl56Rf338qU1POcAMwi3RjXZq1QqtIE4YMdZm10QofrdVnI0bKrh0P3s
# DATA oD9UIx/0IXEC5OwDkLWxEpvUOiCssAZjq6i1BZFCautTssEmUE/zQGOyIfCss8ggg3WQTke01DhGFoNiCyp/z8U8rHmklciZfVFa
# DATA EO2ewZxPSrgSZzx71uRNJs4yM7NWR1IFJM7CGS+ZOvOGsGxVZLyAedKFoKX17U0rfqXTVIt5E8wOh91+f4gMlEihtY7JbAAgGBNK
# DATA ruBi6g9Vd3I4/BvJGQDaNUGNXQUE6PYkUQSlCgYtycdhQ5NiMilZzpTAhEpqTze7R321YY9P1Eje3gHHCqShKUz2zf5wk9hSlN0C
# DATA ImivhUpHm/MGD2VDHXSbnZPsio1trLpFTwEiVK0CGe9NFaapM9192A48gLoagNoKB4AvpapaWkzWk1bn8JCgU1GxjhCZiuXcUxRv
# DATA 2CpkeskUG4O9KCRcSRaXkolj+uG+KdKlv9DCTGc50AK84COA3yPfrNnngHUC4v76Jk8lq1Fnvxj+P3Xn2KxfOD/UVbVHo3eMPS+O
# DATA 4FPUeXqCw9mqR5/RprZJuBNnnO9IrdQBFB8rlI4M8021xmppFJMWrN/m8Og+5XKsATS4zA/NC9UOOGtq3ygx5MwlyshM9kmyBKBu
# DATA zLVdIJn3jQpV9S6pSN+okLj7RiUbdOFeV0kB3jZ54w3IFvR6LXkV9nigG1ZS7GAE+RCBHgtaNkbknuZgsIS6dxpitiSCNX9UHhyl
# DATA xQr1ZvuoWDiLeheqQfQIumwHCbOq50kdhBU7B3IJEmhVk9XSjHp2Ce33ZqerZOOqYj2NZcBo7bS6be/VRXoV1DcBrkQJ42nkqvVC
# DATA XreKlawNMKLbzWFTkRQFS1Oy+SJMb4pRegfA09yWgINC9iBF7UoaiIAYYNP2fabAa22TqvAYFxLKl0Cus+eNEng6wGY6f0+CDohI
# DATA IIoQe0uclNPhhigW+Nk0RmzPk7HG79y5unPt9ub27uatrcburXc2thp37mxed4tDFm2y2JcCNPUp1d3euKO6jJUaTWgFJIoCSVxq
# DATA H3kw8KS0p7ccGGl9ilMqGxC3meKulTZNZR5e6rPP4BGis4ExXUe4/5OFaYGWtc8x66GJGQ/i3+Pq4988+x0a5+LIbz5aSQUDP2Tu
# DATA HnZG19DanayoY8kaKaOA8ViZEX8fPclwOxXotkM7HI72PuUvOjMkUIpRQ0nuyZMrC9+B/qdhdv83qgqerv9ZeeXSmq//vbj66n/p
# DATA f74r/e82ylFm7cXdFVNIgJpV7Vu8UQTqE+eW1W6pGxjmGWNzEHDKS2vyCxRB8nc/W0CQZ3Dq6Xb2xX4E7gRSZNiWv8AOqP/WWP/y
# DATA ZNQ+GcD9jiocD9WRtE9xV1Ir+G7AYb2gq6bUshzCTb5V6NaKrsekwT1szQMtKEiC5vfW1Ru3rr1TNKnTAEGwRXnTWhD0y/lyKHma
# DATA ZYAkqGXEGwSgZXrvZWGx8MagUGWnsblze+Otgg3W66D3SopCyL0RS0ZhrIqFdHPr3fUbm9f5VIEYeBffxoO5JFgjaQjEYkbLPlvG
# DATA qVIHeFs9LRQnUTjh5VdfLc7qkelJ4yacVlc3Gtu3N99d391wMK/xaOIJNblGXvFzjWjPuQXHo5tWHv/rpLrBJ0wi0cJODgnLdwDf
# DATA os8CLkVXfxAuxIxFELB8ItdK4CfInRYyJscbgu+Uu792dsntrikpPabgNAZy5xHIbxjE6vLaZcyNd/cu5k2xy0IoXn/YKhwUQR92
# DATA ER7xTyWlr6y+SjFo9lfFeaZje31r4wZJUwuUih1dROysOhgmxh2BG0FzPOpHPCRkMgmXxQeHwRulj+1kp7ng2SycLS6yl4LELmJo
# DATA A7o9OPGKk2Dnmup4rl8gz0V8thTnWb8hc7W1/u765o31q8425nnLKPTSbpWzye+0RyPOIK/b51c617Nfm0YAR/ZgQ8Hp5iTvObOI
# DATA AibuRniXYaeFscRpD/wGiw68N7ZBClG/t82TNnmjAi497GpIIezPtPQvlh4j3Vsv/6RZ/nuAqzZ/NirluuJfilAnKSn2zjXpWxu7
# DATA 7926/U7O5BvyTFII6a0uLUmqdJPyCuD+mETR20p+2J5tejJ4gUDe3751G/1zKQpce13aLkZW+/pPSI+A/bD3MYVZYtQx91FeYV3q
# DATA PFVVyKlqWINsQ/Wmgjc3e71VZYgfgkHOms1AUSAFnAP1DH6Lbk5+C0qg/P7ZuE0pT+DH4bB5hMKHLqyOXN0qouNSa/gSDn/FG5Zf
# DATA hOW4A3upJmPR8bxMbdPqfnt3d3uHa7698X/c2by9cT11Th2tsx0asi5J1YrTb9++dXUD2JgSs0hvIblh1WVifTw67g/5TlpN0qvq
# DATA Qq3YDMJC+de/99bf3Wisb2/SSaOuF+gJHS2lZ4KhCN8DKEJNwaSY4l7spT8qq9vLg+aw1W7BX+jvlar9VFlW/7eSXomX3B72Fbeu
# DATA J3pW4bbkaS2B1FFAg/Zo7M19XFG8oa/D39cItqgLMcslndItIw0qBL7TBQ2/q+B/odxl0KqqG7mohli1hsr1rK31a4dtYBwz5oih
# DATA YxX75IECkDW5KldTvPoqogRddLNbpW7QD9LCoWFLGq7074k9iemHgj+aB9AB0iuA2hWEvNoyYCSMe/ey2l4dXgAbpm4XaDj4Fi0y
# DATA Uv1+v3WqJhM+v1DD12zKutI5LMDT19cWMXUF/Kd45kzalUi/pGLVswn1pTKAXINXx6CwrYB8XsDn6jI80dOMfmU1dCejhLZcXL09
# DATA UHIwVVSsjPqk10JpTglzZrrIyfP990VTi79fqtXSPlqW0VJHhSp6Sb3S+oX1WXTqrSEu6D3rVqFeTAQVPDk76Ko9KMSH9AhjnywU
# DATA kLgLxdrrmpjF2F2jZUPOvtQcdJbIGL6kjeHFK2rgBe6/PBUfThgBq6aLkQFosIor0iwbwMNW80zl1req+qy2Phw2TyudDP/luPas
# DATA +IYY1vnfCv+rvlWdf8n9COopxrprN6k+g3J7y/U3SCM+d4+X0gsYg9i+c3vzmkQRSGWsXVcMp1goapWVWhdfX2XpksiZ0UI90zjF
# DATA jwCWTGunoNSX5LNIwNOf0tOoZgoPh1KiyiDUGeRaoAQupAszDSAis439iHliPN2XmjJfbVVbuQJcBv2X8MqgCuy3CxzCYO4BfIHh
# DATA Q0fxFYoxLomDFYtE+Teo8JLBbdg3DHw07bDcXn9ro7F5E/4bylOUlZyv/pXdNlzsm8PT6xITUiCoCsgrKSnQkCJwyGW6gh/2u4pB
# DATA O1jpEptEr4oc8ywqMQinMh1mwYxUoAhlnUbOg5otPpGONHL+YilHjRoT2Qu8Ek7GmBcR3INUB2gLi1Sefxeh678vZfOfluhPBblu
# DATA k/QvlkYFicukLqwjxk/7ADO/QihbmSGl0Z+6d7+oKXMPqqwL3hgUh/+iqOShjQQu99gyOC72UIywRqIuNGphhwU9EHNbKc7Xecat
# DATA LpcJkq9cHqjbB1512gzZZ6NwUS/yoSPy5gCfqwVFAkvNJPCWi86FOJVrn3Hbu9xKp7mj//S9yPO2LFD9+rVrGzs7jTfVjgXxltK5
# DATA 4T2d2A7oCQ3+CWZdyGM+3KJiWbfprFXfK37cboGO/T4mluc5Ie3jlSQ7bg7J+yOh1BOKA51a6TKB+1ke65R8B24QCyapXhyYiJNV
# DATA uUBE7BWvhO/Y5k+r1sjSyL5XBXDAkwXJIgF1mU4By8EMQllBQqeoGzYuK37L4yYwJAF2iFbUHx0D0HZOPW4uHb7LlxL8yKTrsCem
# DATA AjUBzrlc8l/S+Rdlrhy0CewFI3QRNsdZikulJuNsMlnQOd9hQFUv3+Feal2E8cJwtrgorFgC7u27Mqe4kyQh+lPQNCwu0vJNIpdl
# DATA a+rEN9itmLAozlJ0mFJdF4JOYezqN/wzKSUB2ZSYZsxR6d8b1TO71/y+QcmoZm9BdV6KHuImxO7e2dq5sw3qAX3XDDVBkIHFhpyS
# DATA t8T69UcYGBdT9pQMxK98apNFGFlFaVbgaCDpmUYKWh3UFMr2R5RMc4ADrKSj5YEO2XomfShZLcrLPYj3kpbNYUXPnQ68VPP4z5zT
# DATA fe3W1ps3Nq/tRqbZnl0MaTtTZ9sIFB1dRSuUXpear8o31rw3R6MmcC/AWwgpA/GTU67dS2xqzYNUwlPgjkxehv2cTItYszoGDrQF
# DATA qBkveurbrLC3aNqESS4Wg92sh4BxYVzacRhBLBfiD3UnfxIy/AK+KYkPIIcIVhdc7qWJk1LhMGVavEWtBWS+Q3tVZf/SGlsO8Lu9
# DATA lCIdIEmSZ1EgZHDyPkSlGX9APKGeIytSn6DNknyAe7seVMepFr8z/38O//zGw4Cm239XV9deXfPsv6tr/+X//53Zf3dOewfq7t0D
# DATA YyEEp5Cnjet5TJnIYQ817XwV5IJnQLVRvkKBD7OEPBxZ1l1+wvkOxRh7eNAbdeUHgPOpL+SnDgv+Rm3IcOF/EWvxOxs/BgXlzp2r
# DATA je07VxWjb1y/dXN9cytdWN/Z2Xxr6+bG1i5GPqAgAkknhunfFd6okrvHXnJ3VL9QfCP4HF8s1iqL34ds3O3KTbDoHXSbWZZcx+1I
# DATA R405dTTcuJoXYoi9/vAEnJGYY+Xa+vjwta/hxBrZykdfJ68nr6yskl8lO2VBbs+72d27P3jje3cfLi+X7z5cObz78NXDesosLLDi
# DATA 2V1PaaANVq3z8eiZEZhHW/YIehIaI6wA6Vyl/Jy2BEYFIXMBXFFKydraxah54vwDhC9phLqSCumhCmmn1Wum+jwpVrqQBJJN087t
# DATA 3ImM5z8LUJ0THmyIwwJaAfoIj+15ew8qAaAJbAusvq+gNTet6KzZOD71CP5VA2tRjiJwiYR8Y5he1fyFBj8vxxCoqLvdgpdEVu2Y
# DATA 5YfiDXvhffhL7ZsUMI2GoyJfJYa6B5YjZlA7Am2ELeyx3U+1xH+i1e/SykTeFN+Yq70XoHrOFCi2qr1qeaUuZExpo2Qi0XKF1C/v
# DATA ZF264qoCy7K2TMtSSeVyBb/pCmgyEDnjX+KBr5d/ogZbafxDuX5BPVrynxUXadohOdT5R8oCHFIJGUUshxtxqRlQ0Igjt9nJFLFx
# DATA m5tFkiVKanENPQKMAJ7M02d1O1p/E67su2+nke33TbgB8R4FBJat/uhNgGrxtip41/BMVGMOrNrJQY/lW/UvKpzfwWh5dY0Tndtv
# DATA e4ClBKuxEqZHNaXO7zu0uhq9mM23vpjHrTlq+j5D1hAuJCtFe7NB8aI7zBejLV5PqE9thr/xJCLYHF3QH5JnirsdxFelogOegbHe
# DATA S2d4q713W4jy2u2N9d1ZFFuy07vH6Kt5IYe+Im5pucSmSenrrWKgxkZZEmJoDu5xmyV+BmNrbPxIDdf6vXU1UIlehW87vaPNW94W
# DATA zenfne3r67sbjat3dn7saDrlk9NOu9tivserba+teCUhZge4JGUFJMapjkmaNK2E8yYRB8Fyk64EActNoZxMU/nTvnVrt3FzfWv9
# DATA La060vrCKamEbXZtklUHPNu8chi3acEpE8dmOw/FgPyFmYhjuI60GggQZZVxsbMWbPZoK5igYgYLEqljJXmthqwDXxbh18qlPPHE
# DATA q4sFdDi8I4ILHdDoqLRSWlm9rB2VXM8rbDbWoNUYjzev6/waO3/5BelF0j+fmWWVLGJVEgTCF5ZYgLh2kwWDDId1TUweaewi5XvD
# DATA ztriL7JNu3oq4x8CWhyZwlg0zru1UfFQCEwqtiXlTq8TQ+CZPofXbt3cvrXjqW0jnCW83UUzaRej6r5zNm/EIVjOPZgs0NfhMeZO
# DATA kXlJvxd8U4Imzmjeg6jlBUeEJO7bLPHEoXIxg6KXPC9MSR5LII77YK8ea8rxmuV6oiBhfkt7+odbL0wKoYCg+12QQdquK0LPBfx2
# DATA j5C16566F985+czxSWjloTWVJuqyI+SBIwhR5mslCV1cfTF+IAKQwW5k7smTyVQklkLVB7zt02bTag3cuZ3MQx7zhWXkmjj/qJs2
# DATA ShoMjETjLnrOeErdonOAcSX5rQjGHBfcU/c58CrhW2JNcbOV4t5K3XE+FxC5vSpc/sBT8WVV7uX0ZYuOfjbuo2hABZftvCcteYwD
# DATA KWDJkoispF3vdPWnUF4JtFXdBXaVhmjFZVavpDZbgXevJXitLGBNco2EH3Y64vR7aXFuxuJeDu2Zo26uVFW79YjCQoqBMgonVZ2D
# DATA qEv7niifMKIR39VWijj51lzbTlpMVpLKojCLDI2nC/bAkCPtmfDoqrvrG9KoGEJLTMO5Jgkrk7RcjsSjKtjBYf/owiKZN53W+Sgz
# DATA 9VXIHhlA3k5n2HSnhIzOllN9zAA7hZ9bfiWuaTZs6TAB7SsqoKHNatRNQuaByuypL+rGU8lOMeOc7/KVr0RdOOexzqQojZE2EfUa
# DATA LDkftVEfyDruCqc7KC7E6YIT2DrkYbVG1Qk4gk6qIApGQJzYT0FXCxrTgtcmkkeFqiB+IBxV8ByJL+ynJ50sQ38fZzOdpThYJcLx
# DATA oNVFhUIX1SPu2XH7oTQgeRKpfKc1kX1o7A4ctkKYHjUMAWAkLbgJ8V0DL07mtmDuqOGl2bmr5OxuDivQVzKTWISQzWrnYBQ2/6RB
# DATA hHvfmkBqIdC52MIcVmKZq7P2iB/iNUmWAJ2kBgh5clvWYBLTttC3e2HpOlRHHdoz61ifX2J8e33rrY0YYzc7ShqnPlOOKe9ZSH2O
# DATA uHvSbwGuXMvI/y/MTqexUi3oO+LsQp5jzBTm+IJSrdVZ+TpKSDMl3XMxaV8UnsaLY/xY7o45InV+1/NPyvyxVAb9QUE174cKBVJz
# DATA 1NsvrA8PCpFDcsvrvGq+AxJVEnzHPgV4YWyNTwaZdnlr9zJwJmpmB50OKb5LmPW6N6qtSn7hOdwWuQFk5jD/+2kaOCjEDlLcAy+5
# DATA NwmSXrSgZ4nKbP+DxnKWMZf6uIN2ZeN9DMrB2oK1p13vFQcyU1NS04Y//nphGiVpPvJCA+J+wz86DAdccnlp1D9Bp2KrBm5cUIU+
# DATA kV+iG3PYqPA2fXd2vvNv/FJ6noNFp8gShaIkOmf9oLpDxnJmlGFgYCZH5/i1QhFOc6cjVI+ruaNnX0+ly/VSegNQEdeW+68C7Ail
# DATA dMhII5TjWGMSVZ00e51DkEI4hZXxMNxzuhfNSiUZh/ChyfrNOa8wIaGtB4meW54fr8l05UliVkVFW2Saq5FJILBjb0v6mGv3xicI
# DATA dloQojFTV/dSbI3QBdpSfITaddNAwRy6xXhDEZHVIp+YCRBXFujIGnd8g55HFrEazZnPnDbilFWI0wQje3PtgUZhYXrtZjJnf8lL
# DATA JWnVXL2lGDGaWXsD/4Q4wGANhTqG4IaeKbmZ6zzvUhEqk8W5qnmygjfz0w96tOWOe6TqXzj/wR6b27kXxxhXLaaqrwGLzn3hfw1I
# DATA cMf/76RzxPh+36gL4HT/v4srKxcv+fgvK6vL/+X/913873svLY2z4dJ+p7cEQROD09Fxv3cRosRuDSDvfMKZUSF0tNkzcJkBLqkD
# DATA HQlYnJ5XILvTNYdH6G+3oL0CB6fkjQeaDNi54oknvymQ9+/hNvi13QAD+BhIWSBIMuDlN9sv0PYiXHjhzFRRKJpWm6ZUnWgmxp84
# DATA Xbe5r9heiIRwjQGQjSrtBpZ0Yr5sqy1VpK3GFQpYkluh5GmpgFe2WsiG+pSAFgSwDN7OXY31qbkLz/hUQiXMp4Et2dZBc3y/NcQa
# DATA BP07YCTHzSHikaxqPBJ8YkOSqAdwJpp8ZHKllSG7N9x8e4BGb7BT4DjZb3g4vm13Nh4Ft13Mb1wMTnMuMt1IyerEcBpstyi5U69t
# DATA wmwAUr9oMsWETc+nzIrYfQ4sZVrNUqtxl2o6ixcPtsb/lmIxd9o4X2N1HAZT3VE7swa70L7BFAUnR8Jpmt2OEpMys9H8oLOMIyox
# DATA 8PKFwVLosY6llXCKr7WdRQuLGYZQVy3+o5RtSKIdzF1nsSCjYcQQGrwYOyEWyitxfWsHQFasIiEezjQsltLskb3NTrGcVtBAyZ6D
# DATA P9BXdX37F9Uy5Vwjp3XHKdq51XwTLsi5oCdnHujJ5LsFPZnDkZCeFUzXS66zMhNVybhKg0lwbe2iN+Ca8bvGqbq8XMy3nuiURTnc
# DATA gtaPEtqN+pSCuID/tUgKFGb31QwAo3Z3a4nDuKfj5pSi77EV6jmHO9RcQnK3SCzgE4lSs04JmsixVBvjEEdc1JIzpz3VOYxOo33N
# DATA wW4SZsvBB6rFN2/f2tptbGxdl2ds4r2P/YT87RO/Rz1uMuiTtpGBSNewogTR/vDibHDBCzrM2jzfL8BRAW1eSWYYlF9w+knNfC+5
# DATA jixDMNEy9v1qHgz7WZZghgId7K1D2EZ9BDw/QN9KTNLIlf0UYPjhlXzCsbaEQaCeUxDMfhsEX/LlbBE+evNkv3M07o8zjsvlKNqM
# DATA PZnhK9FQ2pMBAfL4Astbz2pMjxTwHr8cMyR/wYrFL1j1nHvN8v6H/UNq2iMnBv9g5ThjOVTJZmI6FVm3mJVFBx6bDS+0rGd3ysY6
# DATA jKMSuK7XehTMQ/2RMPeJx4QG6m+zy9RyaeQr3QiwLgDNup+P3RVl3XpjOmNkz1KBU88CTplZrLJGNmnC+29AGgDH717tlnF3ZJSA
# DATA WZuAFVU3jZHaoNeRGY1bsTPpAS7oHILNJqYadKTOv0EwbV1V/0EPDX5YZWXIharkUrNcp4SPxwfDSqe/1O2PwI96yYQLB3AwjpOL
# DATA NQlEytDWjJUdtpUA0uF7lNupJepUeUV7/lTdsaAmTX+uRYSwk07Ic/h6Mpv6oPL5z090GzM/fD2zWeKZdD9qn4CDWuwO60WQFwLw
# DATA AcEjkHujfqAD5ymQHNoIjcPyBhYSWuDpBQL23QxBddpq4aHo7TIgflGrQm2OxwN7Y1ApjGaudRX/aTWx4aqMaEr3i9oLnKBCINhY
# DATA id2Q8BKlkZqFu6F++ntSPSrsLVof1ckQVqPY8YPmALKINfrj0WAsD0eEO1VbubysmSaPk4YFilAzQVaOUY7xJ/HXuVNA05atDWhY
# DATA cjAl6QBvkYyRCX+OUf5lIJRs1KefCIciYCgI8TIBuwtDp1jeppR4Bn2/sNeUphHjnSwgnnYzI+D+gpvwKIX8buOD48S6MUBmyOcf
# DATA PHsMOEnJs6+ef/T8Q0wnCdknHz//GJJDJs8eS2rJ1IOaBxf6ez3FKpLDbhNHzAhOH2JKX5Y6+GOBfkJgpk+x2f949hTgm6gVLyNl
# DATA 2BZkCgH3mz7AnvQ67RY2aMFDJc8+U9//BfNc/jOAmId1XGv2GGIUQIxExuGOtprtEzSPpfwA4axs/KknsTqZRzTZ1clS9eD3n2MO
# DATA 5A8wA+dHgHalZiae+FO9iEx00VtZTY1olwVipAyFRP9kyCAKUGRJr/R1uNMTIpJHQGgMx2WDb8kEPM3r6q8Sm3SePUr9ZKFyoQjT
# DATA zRYO02f/Qqmg1XR8+uyRtFY401tuUmRy+QwRvqBjv8CU0Y8AGL9Evfo0OQu276QKD2H8k0pi56OW1PSP1T+P8WNABoPMp88/cp1x
# DATA zeZSzMJwKXQSAYZTIIweVLHYrllBLEgIKeM5a8WCQsDQG2rwsD5Trtk7OHZvjDzbsLoFmN5HmD4WUmz/cTY6Wg6hOyq0Pd9fZuB0
# DATA SeKeXe5IejAMWsO5cANIinV7FnRR0aFJaCO8KBQdU12gXnOH/9+d/Ld/0hzoa00EU4eGtColMhxGs6J9X2YVTlTv6Z2KHiuxKjFE
# DATA Qwp0o4dVxx2k68bpQKAnmQ6CuByiK+teWj7kL+FdsV4XrBC2XlCcUoOsgQyNhcpCfkQG3gZ5Iep02JzrNHY+q8a67fagRsjc8KdB
# DATA sbI3iTE8xLIsQCSd+bWQC1Rtes8biWQtDlOyK78pFjwTrxSGaMEOCzYrSk9cVq+YKakfVR2Jz6fxqcFTmDqlFjKX4kJekI0rLRHB
# DATA MARaukgkKcJHudzrl1E1MMB0BfoZQIQhH8J8rvT4EFwT8cxiDxFYYRC7fGOFJ8YteL55jmu2F3qDd53cPftbtVP/wJuTDkl3t0YS
# DATA mswjsCzYmPjIRQ2ZFyuU6wBOUxcNfxbEvOMVCxa7SktRPPzBXm1FX2UeAVDjP+tO0T1OOV+XK5XzFl390v1xpwvCj3H3M1+fEw7M
# DATA 1eD5gGCzIdpMw6Sllja9iruO0h5q7vQr+lonKuwyZBtT9UdugZMFx30LF9LiUcXQcwvhLUE3LWZTzDwoltPKeHSAS34ITwrpD378
# DATA g5MftHZ/8PYPbv5g5yfk2xb1+tqrXmZF0zlcsxDxIRGPMHDIoihU3Gs0j+xSQbNHAoYVxBqdk1LiQOtXZRNCVLIdzFlNNKlNFkKP
# DATA EOxcSfeguDDNkYz6TaQvzmTzfSnmCvdb+sX8TrQ2zkzpp9ZsuW1YyfPszfegmTWGBM+pKjQqMMH1tHIl6It5A0MVPCZLt7hyuUkX
# DATA tHL5Z+MOps/V8y3M0g9qsus1jM90IMLYHcRMc3O0a7KYs61RccfrIIzmwpZyQAZbJ3r3CUTM+JRbSSRM/7Ube6tkpTywcGFFyA12
# DATA KZv7bXxL1ho0qp7zst0ZG3I2xMq0u+OhZeb4ReYQjOtGZarNs55E8GFjJhBL1JcaqwthermKgz4cGRQpKzX4ME+cpQGp5utSzElO
# DATA hhCa2upMv1FrvN7G1ZVEQEICWp4hKge6ohxBOKIlM3KuycJZnykYyQaWqQnmAUbQGTW408IiLbqhKQpF42JsZW18Pm/e0HKgSt2P
# DATA yoElV+rFbhSDW5Su6HvJzqg/GCAM2ZFAvWb0qJKsJ8IdMFNVJ1N95vStaLpRl90EUWHFX0nN4EO0sV6/WgnWljqtVVooWLbawirV
# DATA DxFSIji/i4oyyi2K0LW5Fioy9+hzdGmBG1LIZW01p/V56NjZQGUIRNUULi0X4xHREbavh/aCjN9p4hvl9f6ZQjN2FsY3HbebXQyP
# DATA nn4MvI3F7CdQZJzF/YXnO1LIUscdAH0o8a2Unpz6Cvu8+vPsI+gRTTYVAGTL58sBRzYSLNaBXHW21yzfTv5Vqy7hnsHKS0SvBy3C
# DATA l6A9I/XSV3yJ+Qx1Z3MlbJyhk0jjxsB9tXXvxZZJ1r6m9mZPZh0j3qaun6w86bBb6mJE2mjFh1p5i+ZN0u9n3tcM+P/zX4AyL7FV
# DATA j88+f/5x8uyPcKnDRwz2H50B1DAUVueBM4/ohj5Cteyfn30F6kDQzH4BOtmvUB/9KQ/g1+damZyr/xzsO34GN7rNU0iRQdqPb15p
# DATA wZxjcVGEd3NEv8mRIbEhTVyJKRQdbLUS/u04vuQ44ksVjPWqj106ZOc/Ug3srRsV48nz/4knFrnTkyYO7m4FjWk1zDA1j3gDV9aH
# DATA R2NgZ9v4piBWRDX2WqOhjo1Go2h9CTa8RpM/KaRajU44+qBvqAGZZAd9RtrPlLgiJilUCIocQWrFdrdFakSKiyLxie2e8IvMamTE
# DATA YtUSgcmgvUsM2chiUx1BVIY7APyUpCto2kWxCQ1gmOFkPOzaKrXo8Mp4M8deTpmEchnjUiC87nTQrumMXGixq8k3+A98lZlrG/yq
# DATA WNY/xUn13OXJzPQNTkvJ9j9wOAAWIq8qdZp70h2+tMzLrmMCUrTcU+J95DW15HBaep8P4ae0XI4shc9xznQEImvjl8HB1Xr9Gvq+
# DATA cvW+e0ZwcPoWMDoov0QLkGL75+KzUW0wDchwG10wVxUMkhH1fs8Mqz5taTm7oc3TnNNG9Op2YaqaLnT4N9/k8G9Hw45P9F0Cf2ld
# DATA u9aiG+ppqF0C9nO1aA00LDQaSAGNBjCVRiON+HYSu8l1Q9SpL95pn85OfAF6+rYHrzoEP5702b/jUf7/t/etz21d1735zL/iWK7v
# DATA ASQAfIiSEyioQ5GwzEYiWZKy44IIBgQOScQggOKAkhiJd2KnuW0nmXTauZ/uTNvpvXfuZ8WJE9mOnX+B+o+612M/zz4HByTlJrli
# DATA Gws42Gc/11577fX4rc/o9M5pcbHMfGC4vRN4bJKs0y2R5ZGTAGHeajjRv375T9AIVEYWSzjkP4faof1KICjxOfcGMg9h05/iux+j
# DATA qQxlOCEToEhXCsRrH1MmI1BG/72RlBt79gJoF41F2CZAvMJtswbxD2SVN0jxlHIOFRb/PCKk/rz/LJU/3qOvHP49O/5rcWF5eTmB
# DATA /750c/F1/Nd/bfzXtoZ5x0Qd0ZgQOEi7n4j/iu+Is1Pw8v3eBFJxSScHFkbjfDFgSdR4mT2xxf4JfqT4i0eEYfbFP/r4sJnMyNhH
# DATA f1ynxuLXqjeV2K1kOO+ZQl3J8oJncb4HgBW9ySkZcKsW5LMd414I9xbCyo+G4EAP0dNwz/pI+rSTR7up9QwNhyJpdy0WNbKRFSff
# DATA qC4tNxWudGc4BgRVDQOEQejao5XSuhlwCApfNWFtikMpHdNLmQCkZkYYxjXYrt9b39nd/jC08Z1MZCeq97A/3C+E1yW2q+WZLD1C
# DATA PA3P0rjhMWDJkXbwuGwPkk2i0smzwHnS5t6D9lc3t9eSCZmhpkwoWrVmSUdMcpf3LJ0BjTunxgGPtCuNdLJXzz0T6pW0jYiQJOau
# DATA STNbpKuTDU0H3U2M1JtRnFyBH7cfRWWvPZTgOqAgAO3zFvN28KFgT5AnqIl2btj+7QHhdcFN6yzPGPV94lIDzb6pcG6IQe9vEULK
# DATA wHpFCoZAAKjMuIhgUTNvkU24ZEaxUCzpFT+MpUnTu5ubAF/5IRL1ju0WRXXIuF2+LdsYZHiEtrtl9DHXLtbDg4B8SMkscYymC+be
# DATA MgxF3EejJ+2OpFiZtI7YsAMInrURFNG3HOcyZEfmcx9v4zDDM6Pt9F1ig4UapT3UoZufCmGd1h3rrid5A9sUYC8Z1Vs7KtGs6VJQ
# DATA MjZcWDxL8C982RudYdgket3YMK5YNo8UA4uMfyjaAQoDQckxpd64LcOZPXns2+UDCBp+urhUur18FvodE6GmvCx8dXNjd2V9o74N
# DATA mJ31jd1N+yBRhDyLjec6dIBc+MX0kBpR6x/EfAwfE7abXoD5FI6HwaC94XxmQZ/6XsWKTGlilpCSs2RULMobyKwsrmXEW6QYYfTp
# DATA OEOwjCcsBrz0aUINDY+MIzAIVavLjKXIFePjhQcyqqxAbjtBDMm4pIaqrmnGcDp2DY++RqppijmAns155x4lzyNyLVMB46EPTc47
# DATA RnZiTPF4nvPB2aCHCTspwD8s5sdnXmBBvWk9Fgm/YcpMmeLEJntwrJM5VLLReDg1njhsVBYa7yglGmmD7CHXsR0eakq0otfJmmYq
# DATA ZRyJVKKp9tXE0aYgHTDPDgCZxFlDTxWvUcZ1gMuctodxReZCDQemjjoJQYh5WVjybk8KxSysxLwpUwq+nClmrCnNDPnew+NE+cWF
# DATA hYViMRs+MXuCNj8QR4g/V7LP+zdHbuJiTpB3YnYNWw5sWq6GHKYrBAJ0CDtzpQyqYm5qsuRc2mOfDDM3d79+b2WVZEtKc77zis+/
# DATA vEegxFBgcwwG6qKYagEp8FBSssvpzK45TqvkTEiA4JPRCC/LUzqR1lPaCqk9tAFrp/Z01nDTosKiOIwMZU1rHAmxD+4K0nOjKt0R
# DATA pU9HtgdeMSnda7wA5b42BaIgPfDfcW1TJmiM9gJrN56ZWW1pzxMDDiEjU12OCGelwGqZtkbCjJYSBYc3a3gZMwzDcCRKS4uWA4HH
# DATA RWXKKUhrn0gd5KRSFduhTsVkohxPAXWk5VFFucfVZS8or/hycpGLyVVfStxQ+APtTmQJ88ZGIZc60+VovWtgWKUBP3mmSFSVA2PA
# DATA Jmf97Q2nF354Hi0LJP2HpnVP7QFqudc18bj0r8V8kepeHp/PNe4CEekmB3UUk3hY2PszRcaHOXY2ZZ6uTLtxJG4bM9w08t8yLD/v
# DATA RjIfzYy3j+TNA+bU+OrwM8orQLcJP+D2Ra4SelBayzguTL1cOPfOHFeLS14rLnSlyHudyHmVuLprRObl4AruGLPfL1LcEjV5zOW8
# DATA ieS/hXhQQkwkCX3lwPwXrm5a+5mJHwUrTRPcwTUv6sarShxDVeYUufLsaiEsSmp6ZZc1qgXJZ5ErkqlY22RILQmuuvumtKY1U7nk
# DATA PgdnhOUT6a6F+UezxAukpgfr97ZXdtc3N1o7mw+3V+uhFWgrnac4/GhEEDeaqYu11eXpkbteJrcfQZoNgoWyjJZ4ukHlWo/OJW2z
# DATA ID9MUPobtRxcO2UCcDup9G8P1ncerOyuvpe0IIJundsXfBmJmw4Y6RFGq0OIsPlX331QMpYe2qglIFmgBXlPRE9Atr7ItlEH2tKm
# DATA GQvrKJnRjV4yU6OnCEJLKAXhKuURWulWu2bT05RVJ+VlrHMYuGOpJmQcxwKVXefU3QCJ28iIXN+ur4XpuKV5Lk0uEk6eWdupb7+/
# DATA rnbhmyhQxIE4/9HsVSZkKGn5otM8hjg4MQXB/nj4OEbl9ehkElfmEpJNwxNYdd23cZqJdJI+Dev0zNQXMOG7AkHKWSW1MOKBzJnH
# DATA AM0tIZMDEdCWSCKtpoF4GBdNPZKcyLY6416D9xP2lAUr+Z0gW8wNwLkC5pKSShquiDHJNSdnrOv5D6B59KVpHg/cV0zrnEWRKw/u
# DATA rt97uPlwh5Zkd2X7Xn03nC1HoDF2nShwQQbCJ3iXk2sLBQeqIsQIwqonglB5AmgrEj/Cu9+Z8pE5AUFYiALc3uDkeF+pM9BijXwk
# DATA YGA0xmCD1u8oWBGJCD6KxoCjECOmECKO4abEIDvQGCmzNXgcYbZtJZJjD7jt3FqJPxFlhGUJvApthLGtEnZFozFm8rni1WCGTFC2
# DATA ipBVJaD2pDMySsGq7UO+zMGhhu3dEssn7t+4t2BxoUdcCDrFH2OGDrYMc6Kxki4A3l+60xnglNCiCQHK2UWaEvCzd3AQoXpmfUvX
# DATA fgzxoADWGbSxn5VgA08IIc4BHbcHhrsi5AiNAK7QyyQcGdLZ31r7ktjeU1HxDA1EegPT1AdSILVuF8xF+Ix0hA7jR/TwrKmSSdFB
# DATA FzN7aLyaysO4gqfK55F1Asrh0dl8utZEJBYmvUvGxaVd86cCUikdwHStx9nVCNBvBruCT6oFgQ1GTj6Sr8rlg/PqUYSsdxwf9UaA
# DATA WDsguCN50eoy/mTCsuQ7LcxZ9Z4ZuoDv5MiJ9ZU0HngyvEOYRxvCjVuTIVKLQQo5zQR6U1wAaXQuBcdT2X7Y2FNxrT8q+bs/JX1a
# DATA Qvsa+WkZT4Zjx1ap+vLGjPYltypHztaI4OkgoymehcViFq/zCqLMMCV1FyG78AW864jyPJD704Dx+aENs5PMbGZmlSAKpsdm8Co9
# DATA KtA/lB2VemXmSrZDpvL4EwNkD/JpyBtF3r6mb+IlxD09CinmSUc4w3XXPKOkJJJcyywUAPce56K/MNAktZKxbXNaQS5lauNGLwBC
# DATA QCAzbAGnq5Tp1OlahqSHefJwTV56Epf0RJpSKc3C88QWSkbBk1+t4fpqXLpS+kCv+BrWYph0jiihSdbjyzvtyJdeooazWcK4oZEi
# DATA LGK14Xq5Hi/2jCHhJl5C1Zrh5JkO/ICpdXVBfgweIjLzsT16PnO8PZp+8kz1J8nlRaJHWVIdCk8G7UftXr+9TxgwYZo++kquk+lq
# DATA auoXJk+kDoYcOy4e7Q+HfdM/XV1JMuqj4OoqjbNRFRe8puO/jrXqbuqfsqrV/j+pZH/mAUlVt+h295QRaxTI8pKEXAEsCc65i0fE
# DATA 8VDwu+Gg18Gs3FyeILuOANAyUei7qgofiJZ/u8y8VWw/f/t26Hj2b0do4NW/JzdMUUsbY10aCMkG1ki8n7EzoTYHTMULjZ8yJKue
# DATA ZD/sfZ/RDRtYJIsdayxQidSRqV5dWftQ+QjxqWopsFW0u9ZZ6wB4LdwhDIMJrx0ZjyQ36w/FdTq/vnpzq07WEFttnU/PrsEorB7L
# DATA 3qb0iOKpsyQTAKWwhRNHImnaDSJGALUngSuwUaxAHPYo3iwuLChAjM6wPxx7qjXtxAbJZfVV9YKxNBT4hqePcsGkzqeYFLWSs/lG
# DATA jVfcFLQkV5JUpYIuzFPaUPVNxI2FNH2gwZOrq8BN0Wg7gVAUQFfsTUQ5VgcCUhaYEKMRaHwwc6lU9k2TD/5oMWBt6FeNYepDdTWN
# DATA Kp4rlyw81c7CZg7QFuysb9yT8K2ouVf6PpMUWd21iXGMYLnqtvtgJGLxE0yDiCiJ68RhLXElkFrdyVF7YugVYOm5RowZBSoglcQh
# DATA qMJQzzB5PCxLgtAZHaWtpS2T4SBJVBjXsts9RajmVF0B3JVWZTESVUSvWoTAVgMQTPFbKOVVWgFrSBTKpi7ldnChIQLQcROpDPcx
# DATA 8vOnCcs2t2i7yqB7k+ylJ5zQ+k2rAmjbOGKTeaUW+4k2Ws29hIqrYfB0b0C7GbPz8pwk7pPVmwuLC3uDMzPr+PFQXEopuRINtsHD
# DATA alJXHgnyP7bmDjckKO45QZHpK1vCbH3syksVALAMn4igYw1TExBxecbIwTcIs5AnzK4VyZ3rnY8mnXksN68JhFR0QA40xKKZIkZR
# DATA jf4Mris0LHsJNfwxBhML3lWTaYChcbkumt2qGuWSXwmRaUrgnS6Fcy6ggXnAjtHWKeUkY5Dtkd8ykVkENcQtSnd+VnSyZPGb1mUG
# DATA cyO1j6U3lMm4PNm7UzjYeys7rbX6Vn1jrb6xK/mZ1ObkgIxOy1BPuemNqMGyH+3Yn6V+BqxidVedAYbYhRtu6ihVXC69VFVD+1vn
# DATA YxRyhJ20+wzeRcc5QFcK7j0Ud05xgbvDHkvylAzEDJn+6m/aGTwCliCCY8hURsqVGK4BgpG3B4ExiXgOa6Wx4hPQ6ybeAA+U01TD
# DATA yENkrgPMOlTTTK1GCjRQSzgYhrMjLGvUoezX8pefDsec+qYNyGwjwtG5mxqSm08NeIHYXnL4b/db1AE3ItfoVpEsOOq78lB08iip
# DATA GlWgfUqIrw7vzapO31efAlVUzdhc3mc6KBdKnBV9++eM/cEA1LRrwVr/1yPwppJIbkRezY4xl6ADdVIwwJX8mGMObG/K7sggZQnr
# DATA i0lDQ5XBO2qxo5YLLKjWQcVqkOdXtz2JEkTo7Y7Pn8zkuxqPkWtNGOMSi+7VYienn+/H1xNH4Yz1UPoqvD5gyHiyQj65c1C8mW7N
# DATA Q/3FXIbH7fqDTXF3R63C6ubGu+vbD+oO+Ia9uauO6zjtd/uMtt9wlKAHfjnI5x2O2SoTSBlNaysr+VXaNjnNZSYEhdsj9TKK39IQ
# DATA Lp9y7szDKKWPZFzP2ZTROc0aiun4pEZ5yXKKmYlVnOlL+DOnbA1vrKzKGmsJLYBp6dynQiEXj9vqQTE1rpZr9JBSsu+QvRZkCSRs
# DATA k8KNn8EglBRym95ZB71HFjEnD3J9VLHXaRqUq3FGlgyuZAJXEFiKAvhELbc8B6S+mNX7HthXCNohBurn5tPgYL172WQhs0zFlP3t
# DATA yhcztGLNo1OPi1+cIpp4mjBKnQzoop2I3aDLjI1ewIFECYOXN5Iqc5Q8Us43gVYHx0ad7nPlj8SYqtiaHbk3MyTDRPXNRvSFmXRR
# DATA fM1QAk31yiICusRuTqdTefQbnLKaSPulGGNVvm1DI6WBcWiJOKc0bntNuXK5ItFLIoCZPv9JUb1ot8OKJhPuXnq9y2qMOAAfwo6C
# DATA vLLKmEoLLa+brqGULcqMOk5byxJzaq1Q3mrHMTuOSoJgsEC88HTEd5hp8R31OYgn2JHGgVgsg86mrdTJGf7JiZjahEdOLr+M4qwL
# DATA 67pmy2xbbHO1gjvy7QoZ/x2Yrsyi2xD9HbqhIOQ4Nnik6cQ6YvgXax7gGUWEQfxV3PtxFPxlcPvWrZu3Z/FGr2+8b8hC2ikVPDl6
# DATA oIjuF8bhDz1h4LWCERpQbt7Yq2R/L/4FJVzJ0tdBLEnlQQIxSTls1iyHTXOZHAdN+/CijGlE1zIf2OrDnd3WzsO7O6vb61sYIrRd
# DATA f7hT57GBOoSqFoxjb6AsepcLhyG7pxMCY8azc1ySJbPbxYtaKpaPkumd/2TNNDlUi7SM/lx0XrtKlo2dISY0kKZ5gcmcaGt3oqXC
# DATA MNG7AeNFGcNFFxIdasfevq7PHwW/Xi6KOt8tMyVALmVukogc3JmG7EizwR1oOhCU9k6wwqByImlMGYm4I2/UV3kj//XDdR3h5M8I
# DATA ltolSEWcY9kTrk+S5YjjMhpPWswpWswW4mRcLRF76RKp8lxbRLqcmFBuu1vlLPlykqE1eEWaRqIbZd92XaHkfDykiXifasMl8wCv
# DATA J1Mue97jpV7b/GBDkO1avXX3/ubq9+trYrYEnwZRE2sF728wfOIXxyrjz0ypf0/LTZlCMUm60Enh5NHkvucpmpmAjpi4LsxsrJie
# DATA fm0mPzaUJXjw5G1Lj0vuUFQ3jfxtfDxcJONdWu2+vId0L+NBofUvXxanPNaoPyILVPbuzrGJX4VN5uI2lpmtOVk2mVeU8u9NOEko
# DATA X2cciVUUH/qnd/DKYgTDyFiOOILoYvp12O9DewGZwytzf/IWC5895uosYVdv27qgbe1qLGHW8X/llpvk0Xv9euFp6BpyJM7ztNMJ
# DATA WWZSqNEXBnAtmGYPyp8K8uKWowtoxTPtPK88SZbXpW9aVkfTpW8268vsVp3LGBtyq9yTKesylMfJgICk+tuy9ti/ZZmPuHJlFsJ6
# DATA 8r+eZuqaacJTDGQGGPolTD8XM4LINHzcipMvODOp3VVYNy6a8O61ZSTDMvJNZwNMZXRmMkCiq5OxrR9zBH0duZaCQUmlUtFnOHhA
# DATA +ja4OraC21xRR88ZTtM+zXfyRoJQBkrDRw6dNXKpGD45rYUSliOcjruRE2yDURV8iApzV3VnzDX1HNBnqeFtEJQcMbPAiO15qLQH
# DATA naPheLoL4tr6dn0V8BfQA6L+YGv3Qx0F2JPB7TNo4i2bgpLqJCCCMRgh8iO8WdGAFMV2LtFn1PSDy6mK8FCkozxI8wVybG/+wKiU
# DATA SNIIzpaRtv6wV7svNe2TLUfq1pc20M0HK+sJRRtaXfPjj5IeuNef0D2pD5G/NVFBhdGQ5cWTVxF18nJFZZQq2oOMJWLYzOQtjLyk
# DATA sTv9+Kp7kblyEjtArNxfCepo1X+wvrO7Eya2IqlumNWkq16I/Vl6l96BNfwklZv+qis6ImQcMU8M2uPOUe9RxDdbrgudRoPhoBPd
# DATA kdndDXXam8HJAMP+I91iD3KetAccRRCBKYDSnuyPYdtrF1VuL00lozo2o4OwUXUuHU2CLWSH+DtPgO2ZwAeeai6KC+XiLOA5ISdt
# DATA Xl7hTyxXJl0+e+glApNqDT8yZkK/3DkSLxbwvWIGgrWViEwU4aND9HXUb3ciL0h17WgyGVXnNUx59eYCBWr5CsMyy21QGWuQW58O
# DATA KWlfLZn9tuBUntrRp0ZsXRX8ggTNx2XwKhxFFFooxFRUn1SDhuXMoJoqOor3cISoNqL8Qbi49HZlQfzfYvUpPD3DAA9XU09MB954
# DATA 6kAdkLhVHg/7ac4Rbk3Dw0MKy30adsc9zPVLJray1AENR1J/+DQ8bj8pg+EYCi0uHJMO8kmZxxveDM/cBihisnMUdT7CGiZi7mCo
# DATA 4eqDNZQuBdUhT8X/HkSAA3CN111PBszCPJoKhaw8T3VeK1YE9xkUxrW/lMHSmG90XBl+9M5CdbFYrHQQVqBQdEqInzjuX1QoJBro
# DATA +i1k8hyWqx8I3gZcSjxYXKJQyvGkNYrGvSH4gYVLC7EYctrhCjPekIslrnFTYSngakcfbfvqUxminXCBoWVJrjPFduuu8XHg9o0f
# DATA S1d/BhBQeakttQlZT603nqo3RC/O1FvQJcj9AoulveV4CFyB7porW6Qpa62NpKOCpJh9saipYmKAhnlYxk1ZTIAeVpeEdDLqDaIw
# DATA Bz+QbAUn5t7mWv3uw3tQ+FjMXA+ubJPOqLYQ4gRKVhB+e6H6beR1y8s3q+J/xsf5k+4ICViGcvlYjZ4hdGaq+kKqquOhEifLEL9Z
# DATA nYf/6mc0KdV5VgFbbtc0XbILNEm6JkkRZj347GwaOyY5qizlKHFPcDX7r8ZvzGFctmNsFVFACkkicdAFXPf15Lp4hle0sBbow9kl
# DATA 8GVSXdlMZVqmHjRV5Z9DedqdrkyQ9zJbrenVQeU2h525ITkEiWljoTFMMSYFr/IhP44RDUdmo62sjA9PYLdu4S8FidkGuoJWS6xe
# DATA q1U03qwI+m61+ZVCqEKzgWYJLrjWCJUqvazxiwldBP3SQ8KgmfB9h5UY2vRyMo4USy6fjPv8C18EyoCojYcXSFTq2FaOgHhLEfTC
# DATA uAd4iSxztCUyr5M4KgPf0d+oJhKL3GB9eQr6wAaaGTNTLgP5itIQPlrbQu2X9NwwBEvTO9z2fAlRmEfIu9RMsdYU2fOhRyzH2ju2
# DATA 82dSVU+wTjao0ODIdmKiFPgHCBKo9pmFxPVozcey+A+UjjVUEqa2t1EAvJTiwiOgu1X35HgUF7zI2FgvKTfwowHEjd9NPhkNYkFe
# DATA rXbc6fUYG5nF+H5WD6PQ0vmivR0Lk35NrAD6MOnn5FGKUb+XdM8x4VJN+1UtcHpQshVd4ESISiu3P0W1FupVx3inp14inE+bYr4q
# DATA 4GdlnKOXUr39PIOasha4rTOoQyJXqd5eZMFdnpHRnos67M6SoWqj+Wa9yAV6ZbCtjA4ZQLduX+DhxRvWHNJE3vC7TuecBf5mEGZm
# DATA PyR3d0cv1daztWpsGtS/ul0xnHCVFsuYSFB2hHhV9dA/y+dQJNSNU4C+oRHPHq48FI2Uv6zrTywseht2827E7Gb1AVx1RF+wWmQ3
# DATA PTsjmtYV68RPoL8rL96UbhXT98nTj6JTdiDCYCwrZMx72BbPLrB39PGcRPxJmCSSo1DTKa0TjYVmdoOGCJB2rTTIXTp8X8VqafHL
# DATA HaqG40lbJ1mzaSSX0FDZJKfBooSoKzrWQotRq4VdarVgH7Za3CNY47h3ODhBRMACfGz3Kzvr93br2w9Kgf7+3sMtM0M6Pad/ClRB
# DATA KeAcItdb4iZ2qtUsSdcXkr3nLuz3SeLCzinkp69DK9qLE5Qrw0fRaBwd9J5kuH7aGLNWflmFxpcro6One+IqHGMqbxemOF2qET06
# DATA /5fg/A8vf3L+2flvz78S//08ePnxy0/Eg+fi64uX/+P8swCev/xEFDv/+vw351+cf/nyly//XhSF3/8pOP8CfnmOL395/qISnP8f
# DATA Uea5qO7Fy0/g7efnv4H6X35slQvg/6HhF+efnj8XJb96+XNo/O9Ekc/PvwxWttbL4unXoi5o6fkd6NdPX/4jVCSefyo+/1J8ey56
# DATA 4HT4OXZY1H/+u/Pf48tYQcW9ZZP6dmV1tb6z03p3Zf0+T8i/i7q+Fp36TPz7BdSWa9zc6B/w5c9FeWo0MKt7+Quckfd2d7d2ynpe
# DATA SoEo/jWO4qeiyq/48y/Ec3rtY9HgL/2z9xxmLzAnypmOlz+XA/iD+PqxKAVL9K9i4qgYdPYL1X1rzl7+PDFnGHHSelfMVesBBKXc
# DATA BVvR+vsru3Wcuv+bsng4QNHv38JXuexfwQyIh0B5z2G8ZGDBwUEn8JExyIXbCwui6/9bVitnHL8/Fx0XI050WNoidcexow6Jfn3+
# DATA q5c/F2tLNDgLWQbYPZw0nMzfc69+heP9THxcvB18v3c3tWM6LaanX2lb51fiw++gnz8V5V6U8Fds/ksgzBfy+3OeRiTAagCq7bg6
# DATA z+6G0ZP28aiPjoCJziGFctcsZvE/qQXRK0GqvwbisXuGjX0mZvOn2PDHojDWJdaNX/2Sl+vLl78ASncrQBr9A47kF+e/E9V8jjPR
# DATA PpkMzV6epTNlyQbRe0pzaCE/nP+bqBmW6bngEi8SjMOzU3gxf4cUCDvxHzK2tfj4z8H5b8Wa/ARp+0tciS9Eqa8E+bw4/zX+Qm3/
# DATA EtiZqOsLXF5JZYKr/VxUKboAv4rfBFF+UoFD41t/xn+TvhAlTl9tGwvi7/byMv4r/px/l5aWF2/LZ/z87cWl298KFr6JCTgBDZZo
# DATA 8lv/f/5du3ZtNRpPKBQ3CtjNB4RZziuqzcekooseB9vSliVdpSjQAIN2e8d4LZRKVfmdKiKVmHwG1xD5eRjPYSQOGEX6vf2AH4OM
# DATA LouMVWVaMlNPTtVHwYlGIKbPUYUsZMoK6UpaskxDLXoYlwK8GLCuWEjUgzjuF66DfF1CkEsOyzxo9/pw/WFeVwvFgf4ZsBrBMn6C
# DATA bEWylK26kKeBgQnW9eLl3zHTAo7HLIfFGjhzkf9+DQXFAUOSjyUKvUCeJZr4BKoSpb7AE/J56CKTG3KrGHyhEfJIwJMPxgKJ/CA1
# DATA Vg2GJO487dEERjM8mcBDstkpVONbhuMI4kiTer0z7GZlEXNmyIOkXCGMI+kOqCmwNWr3xoWjYTxhOAf9U4mSx5hLF9dC5VFH/kvy
# DATA TTZbiLfBu6v3iGJs8M5nVFlkrYeo2EBMx2uR9aodYw1uYB3EyxMH3IiAq/B7uDfYG+8thFM1nST3o/wARMInnRTTxMkcoEwEMhhI
# DATA pSyFiSMcxe4XL38GxABy2qf4iqCSZJ7hkYEkAKNKhoAvLiwtB9fxn6kd/o8k7fEJyxSsOg8nuey8GFtZSm8oEL0wJTRxdP8DyGjB
# DATA g95dleptW1y80ZcoiIcuO4Klj/72BBxMwL0anFBPYsYslSi2YEIAGqooAmgRoYs1xk/gByme0g1//xT05kW10NZTCgdhPhA+ubXw
# DATA HbRpDYbgKQCf0LshGqBl4tu3l9FFBRmFalaOalPUsrNzX8ZrxEEXMxYhpmUvxph08LaZMG76HbFNQNsiFnLw42g8lKj2FJ7B5WnH
# DATA qoRF+2F3GMUU325um1C6Ek4dCewd8U1vPnss2egivr8kp/SSEQhevwG2CFTkiLi/hr0AtEUXo+fZzo9XUb/iAzAPuMs9Z0XB4kJ6
# DATA ztCkYP0mw15ts8lVrtXl12mGtbKvknCdAEGZrmtwY/wUTiljRgU3EE+e403ieULEz8Epv5FecEIhkiXiPpEAiA9gV7PkB/5OR+SP
# DATA pZ3ozQDWSYbhx8H+cHIUbO+s4Iatr67trNwRBxSnSDkGJzv89XjYPen3EDPFYFejk/1+rwOItgkiED8JNmbRg4/fMDPz1DSSr4uf
# DATA JD2N2pDqgqyocVyVdUp+qV12jc69UXMaydyV/5640utzA44DsQxfC9nnExR2PpEqJtR7+YSelz+Vnoxg9fROlN4taKDukrHdmatK
# DATA NwJBppBIZSPqqmAxWOTWZNiKRcFBNy5ggzI5VI2SQy02IfWgJIzKYPi4IGmjcjLpFCvwTfTieFSYwrtQ3vsiQPXV5zQLfFP2CX5w
# DATA 5f1HuPR+RVrC5y//Hm/24tpvZ8HxnIEqDGN0Ol3gMgxIabKXPlYvJsbxckZgEZIYEk5YxHwIdcQKD8conBvB5/x/0dShyPRr7FTs
# DATA yF7IUZTsZQhZSmMiJvhjQcNfonLh8zDRdY9Xrc+P1ngh4UkLcwZ0XQghR1LnSJw4lVF0TGaY3iNI2AhfWUDpd3U+ItOLAmsxjBCU
# DATA h1C2Og8/W9AbM+WpPf9/qDP6DA/XzyxBDwRAW541RUJ3TsXrv8fLjZpVlBMNeVYMUCJkjyz5jHqdjLv1WB9sfDgQIMUE/VjseZwk
# DATA 4gzOmNuT4XGvw225E6fqsUwKbEXI36wYmhu4mbVKBmId1hWnxJ2NZCgYZzGySS89GDMx7JEzTjeOyy6Mrj2yvEyGIxNfEqocJMXh
# DATA C7rYJ6A2HMEer2H8GjmfIwztQe9JLaxM+nE59KwmwuUO48pBFzh/wWwkfLwfon1GsPSofexmTYJnbP9LDMwocdA/iY+cQDpoLz4d
# DATA dAqyjBjDYFgw4qGHsfJqp0XHMHHalxDr1zeGgNwNJcbUtWIerWDT4sJxNDkadkuMJOAgsJkpqqmAFZ8lM1EbN0J4krwU3r757WXP
# DATA z8DPgv8WLAwX3n47i8eubeyYfa4KXiCO8t8qm4Fx9QNuur6xrhhHgKp2aXJAtnBb3KkczClTlVQhrBL22NOQUhJDy3yVWAec9IPD
# DATA QtjoDuLm3iC8gcM0nBzkekV9zEgMSRCU96d4R7m6RePj3oSC1wtP4ZdWpz886R7022AZH/XIeBxiyD2tGxnzVSFO+ELvHnaG9Bq/
# DATA pZYu5VWZAoD6SQkH3E5Ex5zkxtM5EAONRATmaIxqlTxktASSnyptJFt+hF4dYkaBxfGXMX9R+RuokgolbJ8SDnX+L0Acyv5JVCSO
# DATA i5c/IwH+S7SX4vnzK7YjfMUXOkGDZaU+e04GQSgSOshgJtybHCsD3OQWKf4VSfqz89+JxsDw87G2Y/0UDzxjM1jtM7u7SBCOxXap
# DATA Nghyrfxo2BsUDsKnH52BGfoR+LmTR0fJmn6Z3aGCsHqYe5V5DfhsG1IbUlApkGwnhyDoU8LZVAzGJNuHEFsxQiiNxJDj0IAGrNzY
# DATA KzdvfE8/qZjggc2nSyVIHIm1TRdf0lS2tGk0Tz8SnAHdhEMOMaDehjfw3xshRhMg1cuBmGlCcbX7sUaHtM9cXXmiuPw4/6g9nu/3
# DATA 9nUq2HnxeN6SC9MKGbKizBOjuCg1fUOu1A0MoQhviNduhMlICjsQy8g742o7jLGJmmNSR+fXnjiuVsGNGrKUG8DFiLqx2mLe7pan
# DATA Js4xfIHMu4YZZiK9y2mPwG1uLFO9iI2AtesUbR4S1nk02p3jqNwg4m02FOIlgO1whdN5jUO0guug58Dv4Z74CTK731vMjvtEYgF1
# DATA NhmhrTXaWCJToz3DZlI8EI24v8Er6otgZfVBXal7Y7Qdi8NsFHXEBRES2aPO5EnU2cGkJn97MgQ3wQB0Jl10GexMSDcTH0X9vvyd
# DATA 9CdCEGyP6BTDgegow709oKE98RcasYfX6OE189lb8Oytt7iHBn1QciLuMP8bFuclLdwIZRienSAzbDwc9CZC1lgzAgq2I9uQtnt/
# DATA x7wj7w1WDoQsU+OYqfIQRMSIHdUCDjjm1vYGH7ThtPCWRd5kdYYjW0R/dsEfXwhJ8dFQlHv4oB1/VFsQ0t3eQM1+7ZpgdDSnN8Jr
# DATA e6Ak4oPq9vLyBSYIN0+u6ZETY0yK2Fdi0tp9GFNjF2oSb20OVttCDu+2x7XrZfF/wcLN0uKt6sJCFfiUNfRtQVji3Pxx1F2L+u3T
# DATA nahTu3kbSm2BUj6Gy0BtIs5YrH+dLJtNmt2oe/e0hp2P1cQ6c+GJMLlQcEmuuBKJxkABISNU6ZlyhoIKwDAGQAgh9d7kSEU7jqUk
# DATA a7h8NoyICFMrLb6y3tByCaVTHeNBKNOXFW0RM9ieCr6CjzhoM9fBKBlMcUNZ45I/SpmWww9rMrNusqTF+U/GOCnuW6C0GvkjNByv
# DATA TjXhhjewq+1qV6R1uV2x9F3tCmq82nYsNPTJdCVNeP2OTi3fY6mqm96M6fE9W5sGCRlNGzfQdkUKg6JmvoW2K6YI7a/YCfAkQdMc
# DATA CYuaZv0XHgaRd9VKzArzpg5t8ZFOQp+/LcMxGtDG5ClcIWDC5F0xhWR439mS6JvB96NohJZKiQAUyKMYb9yQ03nQ6Z8A2nUAnhn7
# DATA w0kYB32I5+cLSVxJZsluhJO+jMXkbVk1JtPazRQzyYMyjeEVLRQUectbZWFfmmXsdIl0EPA0WTCOfmUTCbpGEt5JP/bk82b5BfyU
# DATA CPLMGAnKLtav0GcfSpJXZiHzwtcvf0bXx5f/TI4ZeMFE4zxcMMXJ7KSAIW9u0WTD6kyzeMf8CXrSzOGNPcVJ2u+lDEd3wmHZUoxc
# DATA yIkZrO8/IsgPTODJKjISycTLj3pwXTH4gU45JzE8oqA/PKw4nu/h+b8Zji1iRqviAmW4ByKonc49GbmJ0Vm3G5ouMez3hy426xvr
# DATA Je1QIf6fze0Q+AoDqRmptNJ9Fxf/vD39UtzfDh63Dk/a4+4r9ALM9v9bXLp1e8n2/1tcuLm48Nr/7xvy/9uNwLbdHvf6AJkQg6EF
# DATA 8kYyks/Ddz8QUixmU+XjqET6996Ako6CJWJMCYZPs1wADzqDSX8Gf7/46GTSUy9Q2MlsHoD8HdB/pIILHXYoUGqK3xy5/fm948Th
# DATA 7zjKLd/K9rqIBo9qT69fH8YVDhAU5+v91dbKffQ8XzUUvlP97LbJo9E4x8BH7Ddk1Xz5Mdy2dSDBC2lzw6gG8d9/gofiFbGsdwIP
# DATA Pz0QQtdjQHo6/xR8ZNAt/6cvfxlO9eETc9YyjkOZD0KC+B310ExpTPIW2m4sfCobK5et1/Bm5XFbMGg52beWF/JAUtKbE1BWD6BH
# DATA xXRIfk8jiwsJoHqj87tUqv5kZOO96co+6vX7LhSjbiXLnGYb0uiWqRVM0o6Tqp1O0ke2fhpMsWh9/QR16EAOX6o4G0Em2sJ9CUue
# DATA OGa8ljwwqpH526wfR5zP2vfnZewbR/vD4aQl2WlBTFuJVWSdibgeiU0mJJohpH+vscolofotw1zLGkACOhn0JrVUBU3iRURY1aos
# DATA TXnU7pXQ3heWH0ZOCuT2c7lXHLfHH6FmnV4i8BTCnAhZ87iLeHNiusvo4PWj4b7Y4GLQgG43Gj4WL/WHcQzT1+99FElFpbiLTcbt
# DATA QdyDYw8vlq7mUczi5dWOzAlg6UppKjJcKNyEzuktuiFmTeoQoT9KVWjlbIdMD90eZeWcHNXRj6ImE2TQDBYprdHeIFVvaNdoag4B
# DATA lo1nRVRyLeCcqeIsbO/3I0PLuDWMJ7X5k3g8v98bzI+Pg/JBkOiG1Uyaig6BlconcAEy1HSGthI94o0NFVIKbUH2cNWXKrFEKepy
# DATA SHupgnmurXWiXkLiBRSaZKvSn4ePMoqVrTJxTmEFKJRHXXlAlgKK/RVd4zCESEyfuIfzt8dHvc5RjWSmCn4pSanMTBwlXidsPsw+
# DATA RNIQH6VYm/hRfgIYQ/tMJ6Tdg8eiELZQCMUX28wgHiROcK7QPurZoblGc418TgLONJP+ePhDBV35YjgOKJXHSQx5pWnKLQtFRrvc
# DATA z4waPfX5eNt/+EQqdnz6moN6f8M+UoKn3ZHSsxHV9gcKqT3/iudQ2kLU9PKDspgjq4ggSreQeGSvhKyMNSSq1JRhcaCgw7Wlo/Sn
# DATA OCwSLdVDcNx043NpLpTjR3Ig3V7cHh+3gP+CBwWTKhKdfQYWfYcggz6LzRigps1z9HnRP5n1rwgeI+uXqcRAtgCdG6gwpBBcCVYC
# DATA kOMEB5M4o2PALUU/XlBV9IMeO+AbLKPrgsZ2hv0+4xSVy3gaY9+It5fLgv0QzdUQWVEzOvEbnjCQmGMkqOe0ttLpnIzbHbRdLIK2
# DATA jDaOzkYtOVWz6E0+IXea8QIshPHGtP2TkG0MjSZ2Vtz7jsV8PT6KBgzXzsFj7V7f0Fz6O2P33jSpZnCJnLs4jeT1tkW3cPZC/onY
# DATA vC8givRTm7bPP7sTkH8S+jR/Li2wqSIM8gP+QT78GqoAMyk4RaMHpAXnqnZGoWjPl3kkMQQX7gEAelM2nVcOdZYT0Mv7LtNSCHcI
# DATA ccGuqR5t1wEoeq2+nQtDi6uhIcUV/tpYrDYVpJN8Vl1sgtoVcOrDJukRzd9NlilrZZZJwWJczULTMZtPE32109vz81+hgztQUdIy
# DATA /oXS8hcTbnzhvFh2R0AHH4JKf9j5KHEvA0d4RAIZ8A1SfNtsrW7XV3aDZ/Rle+2Dbfl5Y/Pdzfv3Nz+wJBXCvxdi4/hkBIgyEubj
# DATA YAy3F8exFdHmHQyR9Y1dE0IkG1IkCSsigfT1G631exuu0vb70en+UIhH67KnhWI2sslMvfIDnRizwobv6ddSWCZjzkABJm6b4mEB
# DATA /lPiJ4BP0qr/IEMznZAFNa7X5S0MicnMwFwJlRCDAo74H4az3knnf18jqMDLn2HEDfFKvzYqtM0e5nYyDB+z2TMyMGP8JgezVWV0
# DATA MG0XGMz7j6hW+3mqDs0zQClRhH9sNgZK9VJuH4Ir4isyAWTq/xcXbt1evunq/99eeB3//438vfmGunhDBurR6eRoOLg5d+3atfuc
# DATA uhty6RCVSCe1CuwTTvVNabwxRwCiqkFmgPHw5PAIJUIlNec2DBy1YzAIqK/H7Q5ZCgA/BfUYcOTQj6D3BYCTbYgJjifvCdbYvwp4
# DATA ASFCqs/gajWhZtOND8AzLGsDNnYy7ou2KmPqnWyTO1uCn+HgmFMdIN5jtKIdHhDi1/sLo4bPUXZqNKizvb6Frv5CkjOyDMyt3l+H
# DATA GxOuOeZmJ5WLlDDCudXNjV0hiNW3AbJqd3vzPha3xRBQpo6H/XBup779/vpq3b6DMdYbUoxSI8493FjfbW1vbu5q2cbnLDa39XAb
# DATA kmBAKs+UOsuPFkXLuyv36jsYIoVaDM6P0h0+HqAiByOlKE0jo7lS3oiQk2Oe8gvgzNEbiKVk7NfegfylI8h5IF4ozj1Y+UHr/ua9
# DATA 1t0Pd7FJI2xeqW0pCdN4eCjmOub8MmO50oKgAIoQ8eBLQfRIh8eIXbEF4ZPxUbAPJjaxj8Q8jKhMXOL8GFIulWJ0jNfk9uOAyVBG
# DATA gsMeo/sbUVwNlJqtHuRMxAesjKIrt52iwspEih4usH0U8DSv+DyrTYyEfKydYRcO0Z7MYi07IfUPulCawsao7zCSgdC80JDFHuZE
# DATA p8XhLFS06gTHDlfMqJvU3DxEuknmx7m3Xd/ZscVuZ8CUZUSuK6oU5LicrJWDIajFMAIU/lPw3L9lNdYMa6sBSz4AIL4xnLwL5OBE
# DATA kxkVPA1xltA/h3JT4L+oTo26KwCVLXoEN2qkJAAkR6xxhnKJDUR2sU8e9Yaoi5MNNLj2pkIvgJcEsxBbKsJELsCDBKHGUhsC+Hvk
# DATA 1SQIFsyH2hcKNt5jIV/GCqmA1rQCBuQnBWwJImitp7JTxeToG8Yomg1ZEFyfjttPCgslXIqyOxY9M81iosoKcRbqS41n1H6tJmrl
# DATA VPCwjXENwSkNQhT2niwslPeeLB7sPXn7QHz4zkGTk45h2aK4gy4tNOfsQfDCQL8Lnqc3gsbTsK3XEWsCNHpiIlRQfMd/z5rFRnlp
# DATA ueq2wXn8YNCiGVHRnC/3HWYF5Hd8Pq1Ui8vdyL+r6jCcJC+wHeOxXEJT60+W6t0v0zeow/OMjWrfMNSdwvSwkt5UxfQ++nc6kq14
# DATA 7lCxs5+U9mLUjzjaSk/Y6AjRxtn7k4uEPMFwylOKa9URm/UmuWrCyg2g/eAbnsni+ZAVQxPNxW7uVdQRyO0HhzRXaW1K138PIE+J
# DATA qQvOrd/G27p8TPPWwHmrNr2JDvUUoDtKgbd7fHJcUJU2sMJmZt2CORSm8ohiMlknOmeoTtSCharX5cNdK86l1UeTIlhelM9ctxeP
# DATA +u3ToI0RdW1IcRBcWwgYbOBaxfU/yCZZwyswkQxWiKoGKevDI0Gg8iBZh7mCzEdI1jeCRfnDqph64Dv9aFCgefUlwkDS3ZlgYgqr
# DATA LKd+Y/LHCzY24SZGisYd4m+LCwued4gAqHPXscy82Yrbpdg4Fo0tox9TFgvJLKt+FupUGvXboxgyheBqiZcsqiwY7RwIcoiPqCGS
# DATA hx4DEXp7gsdXMTECiAg/ho5sS+oy2pWPzOM+eaScCXbe6QtSsOQhw8lSKosFsRDjlwgf/eEhM332dOAzF7KOQrIfT05LyVUwc0Qy
# DATA q2Le6Mr1ATreKwQvUZ2uJUc6s9kSmLEMaGZtUeH3B12/evWD7c2N+x9KnaqlbK3/YPV+prI1gVCgRDHgk8k8k1WXsaryEJQLnYdb
# DATA ghV95i6VXrwKwRXJsEv12ErRSX6/+hcKHvcADsgyVgraNFQEMSOdPiQBPui6flAGl9Kq1YMux/Un6bKF1F2gCxDfrSDOY6KDQPly
# DATA RNJOIWyAjECZ6SbjAzzBw7c+LL91XH6ru/vWe9W3HlTf2vmbkFz7KofHdMajGNFErwS6h0DSKfhGTZGXRKgiasOTyUH52xCNCiOP
# DATA ayG7eUgZhPskPY+Sw2I0Jqa0yNifNtHkosqVra36xppLiqkOVmq6QaNKPa26DvAp8x8ykjPZhiQ8t1JOQzoq5dlBPxbz1ixu4BAm
# DATA CYh7cGXKpjCDiVHmNolulWBlclukTjFOTionZAb4zc4UbxD4yeKzzK+yp8YUZ2mGpNLEGB26u2mLzxVxduseDhqVhxsr74tpWLl7
# DATA vx6msmDZl+TSTDN9ba+Zu0DSvf6+gdDw+RwNxxJWBIOe7FU+FjyAIZDQbxAwM6icx2/QcUKp7LTWd7br9wqyEom1kRrFkmMW9Q3g
# DATA ZNBp00XDrJ+hPizFlm2Uo97HUfSRFGgS75ft950hgnqqJuuB20bBLu2h0VQDTvaIKRgYX1QYDnLcZk3QH/FfMCZP0OmtsI88u7FE
# DATA FxZVolGFYmMhtXW5CAjAVAhcv7keBg9LZ/UZvYkGXb7JwCRDvtbCOCzDHzBqQDQImtcZ2z34fv1D/Ckkz3M9z/vRYW8wSKnobv3e
# DATA +kbuqgC9gPoERz4CeujaQfmGP5KnhZALvqt/lc8ceuWJChvb9bWV1d36WmD0oYlnsCjR4HoB26nI6gtx/RE8KtaYVtae518lIFTy
# DATA HmsZtOj22qB0IPL6PasCQF2fzOzFteCpbJFyX5YUZ+TMpvKrJ2MdizmUzM/gqfKRvPSDVhmawhSE8sfKYX+4XwivS6VGo3p7GfRF
# DATA WEiV8rYcCwkl8fbNJQ0dRk2C+MmNZ2gTEMTFViXgOwlWZ5hZ8R268hhiPB7rHn5nzDe4kZBZA6toGK83i8UrvygfWLnpDWm8F2VN
# DATA ifdA8qUcvtDxdJkjKu3UST2vMo4hxueY9AYn0Zwn0MVIAp3O/3OyT/N2RGipSJsVYM5wLxLc7od78fXCO9XoCRjH9uIbxXcKDAnT
# DATA ahroMc3rRVGwBoUr14t/Yed9BmNN5UGx6tf5aM5K3OcZ0MljQerPkK88YynvmQ6MfAYYS+98FJ0+gyMTlGQQs/wsbvcnz7oxQgfA
# DATA YBqLTWx5PWWW5RajwktNw+MNk1zvXdsLw6L3VdFxUIhgDcXgL2vBcjU1QMnhqfSOu6cSgmRiw1A1iCIyBG1G4Sn1H9Gf8BP8xNzd
# DATA wxeIDeAB5HT9DDEja33Ib89IL3SjN/YinTfwj/Kpp7ZKxiHUlDEofIxLFX7hnd5xsdA+mRyJLf5jVCUKQmlUa00irn1BANH4mVjI
# DATA XqcINLa3A5g043Bv0ajbPFTdFkJuQ1TWuCZ41jt7+xZxiuc79dXt+u6zrZWdnQ82t9eeYdaUZ3xstt4R5+YzUWCtvrG7vnL/2crW
# DATA Oj1bebj73ub2+t+sQHaholspN6YGU2z8cG+8N2jeCMPZBjBdqGjsxXs7zevviFaniTLP/qIYllKFg6xu7O1Hp39lDNKEgEr7vh/a
# DATA NJBVfwFgecTrTf5X1HGjUm5er87Pw9TF89+rNm9U6VPzxvcSc/i97N4/WdzfazQWyu80rzeC8rz47/fK/11aixLvSUivzlF73O5A
# DATA gDUC86hvYj9hSVCQmg8hPmISgtwmmJR+GzfTzaWAfBytH96oBYtLb2eJrEqgW+PrYsCpL2OK+m7HE0JyrwS7R5FS2FqqO9JUgucI
# DATA YbWjW0UFYPhYHrS11PLmJ67C8iMlwJ2QbhjeAMgR2Vl4JD+f8eW2D4i9k5ZyRGmxn0pBW+C3yQgeHJ9MwPs4uI+vIAZ9Cfo5EOxo
# DATA gh0G7wlyEhBf2xMCng8m7UPD9D4axj2+KutoTxJ5tusPNlZWIXPTdn1rc2d9d3P7Q0qvO5kctwfzCvWmrLrr2s9SsdEEnc8734E2
# DATA VXfyGcW36/frKzt1Fe0pzXrstFLQiqdQ5jMSJ13lUEglJ/vgUjuPLc4/1Q2fzUvPoHlai3eUW0cLXTdqT10v/TPDCZ5wyuLa03Cl
# DATA A+cQqEXAgQMCUgAf9dGgy83fQIm2BAnQRb3lVTYQVkEgL3fgWeiJ0Q0fCiosrxxyemm9BOY9IjyjNw3HT/beKSgnDyNlBghh4yge
# DATA DQdxlLiB8nOSiZZu3WZPErhiqrWG408UB6u4LnGhBcSZt9FMoGKTqIxjWKWoBdTLi1CM2Ao4RqyGUT3ah6jU0pRccFoVJfjoZ18R
# DATA h8wf7XUFT5f/AT7ZPnSiNcd2m91x+wBsLb0Y68MMlYlCI3GiywzPVsmLDJzzOsBYwAvdCvviZ8yQZEkSb6opK2EKRP5ZsSZFHLn4
# DATA b/EdMT1mzVMG8X59e0dIDUr5NsZ79+REsO7CcXsEiKpcnwQ9h4RYGiVpcFqAl4BOF5ffXv72zdvLb5MlA56KkwirvEhfeO6oSzeC
# DATA wkKpKPZBYTko4+6genXYrOVOU8202PivXV6fbtSEj1MAhVnjxwHCuJ0BO/eWtYsRV1qi6uaahp1dyOfHVMXyv7F7LUR+P9Hk37xm
# DATA WzzhWAdPK3tSzESpoJRGfv7w4foav4riBX7MubP++mF9Zze9X7F4NDLdUFoyYv5YnDryG+eKVVDA1Sneb+wA4XECmzNwt8V320Qm
# DATA xpyle8qvEH+4sbPybr21tbL7Xmj1KJ9dUxZOWDWTXn16zhQl6ckyoFnpGWqPXTQsXT4dEMsgElVVCdVUriXTaEh9biw0HaUfBYui
# DATA Wc7Msq3eKBJfX9naatFVCsVqH8YXeDrXAhoJw2eZ+iSlqLHGZoRQgB7CVrn+ULdagyvEASB8Pr29fCY1DaxhSA5JKgIQJpfyABkA
# DATA ssxGqDToXW8uZRLRg/WdnfWNe3IC+FQGLQVgvh63O5VB9JirU/C/pYC9bkvS/boSH7WF5IHSWLd3CKJf0eM7lk73JSG+k9K1Ss2f
# DATA OSjesiKgqYK5cYuJPAa8QobUF5sIguxirJDBGxJwENwDMVRbrxw4ryDqGDuyC07CmICF8NGwf3IcgSNww3IRVN6RDXydVFH4CZI3
# DATA UY29A69ypWBsASzJzJnyOMEDKSMhaCK6fiUcsIHF5K1dKVCSbtyys/Igr4ZFIZUsNYtNQ9OjtqFYvdMRXLzC/d7AhHgkQDhmNkUN
# DATA +FhNNsnu1S2IExC/A6s6m/N5L5heBnBUNGRHmr7oTYveuanWg82HG7vQ8Lv311d3PcnQuHrHcIerJ/VeslUfpdtHi0QENhqQU4J6
# DATA d9NLWuWnSMtDnvIi7CD26auSXAo+7egiKFal10U4AnayrKI5d9a8T7x0nHdbVhKEqInlr2dJwFcA3I26LT5IjVzy0h5dTEW14IDt
# DATA whTMV1ASiCs+EDak/A0KxF9QbyDdOiW6hYuF6wBSJAFv4x4oJkyMWxUAw8EvQfkumt6NoVF0hW9c6AhCEbH4kjk78BPqOBKdAvAO
# DATA aHo4KLNnwt6AnyEsrQ3Hmx/rwke6OvJiPuCAjRIHn7tLm0gdqbEFklAZJcKPMESQ7NcVhkZYLg+Gj8UH7s3MNY1pplJrkJcCBEgR
# DATA Eizo5CenLDAakouhAQIAXMA86wPHOlV5TwUvxEPtjqQ7iOlsd4MJYMfQsRq1xZGN0610QKkipko8kH5wZqQhsERNKZteSsCU2JrU
# DATA lodR6bgMLT2aYK+Zgpl8xjMuzoHIlBuzxDXu2M2l4Ls1WwCqBcsL37mtMMuPtE2BdaOEY7w3Rogd1AeBe37YLP4RyU0yZUNSRlI+
# DATA mqiRqqqY7FarJ3ZsqyW60D8g27IZsSweVtLJThXRVxz9hnnPUc2hyIVtJR3hjXuEWad77hmVtR9F3O+EasKalqz6+F0nPkGHrJO+
# DATA tJvsMxq0a26vXYs7p2V3vN17MrSLoWdBCAAvbYpwYsN/oOzmVEqwVtkbP/yERXgbm7ut9Q1xEb8P3mC6aakmopobIX/3wHQkSuhp
# DATA AYcuJhippgQ3APM+PD1eTOHOgTO9L+OUvGDixBLlJHwAMmPErsDTSdoHArksUn/rhmyJKQkzQImT+o0RBwOlKOJCddlbWob0I1A8
# DATA n+uWX93hTmrqbiuE0BSOD5fGDXPxTz5PxateAKdj2avAdGy5IapNavgiarpGX5bkVtdAnk7kbKWPiSOMaouW3zUkxCHHAqjCcWRy
# DATA nTzgD8Di8q0NVN0Q4jqGdPlXiFdJ1GnHAWGYo5izkwgvYDLgkS54RvxRUNbvmoEEC6B4fHtpISVOBd7huDdssSbjJ9kXoyYodLe+
# DATA vf1wa9fiTKrLODJRC8GOCwmqqvoBSOFmYgGT8MRQzKQGPFx170B72CGoZkIHYHx6gKS/aypgyjIujjg4hdb8zDiukuHVzEQ7R+1B
# DATA knuizhgJAJE9yIQACuN2hzBxvBxG/og6U4NxpgVzZcl1W2vgIHD34c6HCf/PU18gFXkPJ4dZAcTLIyG+9X4cmTuQxl30LYavljX8
# DATA J82lM30ghqsz+XSSj7K56VvkbEjLQZxZ0ZI65GY92XSoqgoulvcLibJkXDmEzH44bnejHGd7OodHhuPlVGJoqIQw558GKiSK4eNW
# DATA txcjbpkFtZQYCIQQyn4iu4AGibSO2wNRXZdsXkisU8extXKv3nqwfm8bXUxwOOvbFk9I3QPwNWUH0E+vlP7Zmzz3yTl98xjqQF8M
# DATA d0p8TvLsrWWcvd6XNcvEg1t9TffqmlnkcBiEbH/6wC5wYNkVOKfWdzNOrZnWP/+JoRzZXPmLDgoIqKMwe70OVZP1GItb1cK21tfp
# DATA WTFjEY05cfVu9p70RGw7+TVSKTZFlUJYjJlIhaxTKyPMG4ABGgCGJjTHoSVl+7WQ4j0FYqhVW1Sh+oHRlx60n4ASDGgACrjqOXzp
# DATA Lih/UCmX2h6D1MGposW+EkunkCkrGnP78KDXDSWjFY9AdFDniaVdshw9fMRWuCBWlUV4UwQzcV3c3m2pCCKWl2rJUKc5v7unOlly
# DATA iuqeguOwzDefcvPpzdtne1zQF9U1AwmnbHFrwE6giQyGAoBaW1iARbZkhQsKCFd+I5yJNV/4EHMO5WJ1ygUzeYzluTuS0T8BYgD6
# DATA EWZ6aSKo9RjcAx21lIxpK+Sk0qJbYaszjjj6CSWS6cySovMQCUUH/Bn7BXLbsBtivg2RpG67X8BS/Cygoa5BTUZ1Et+LHoEkNcIQ
# DATA N43cuzVz+vTJpeC+jSU0RI2i/9p3xaKrmn0tv8o50H1p+uSQK5F4LyX5Xvk94lLim+/wUGLYZXgyOUZ5IlxV2ngCbG2s3l/XY0um
# DATA X6UTV6oqEdcGfELDZsZqoj8EV0xrmVYv7klTuaA+N/0noSMbXaekL36Z4BQcCmCCur1BzXhzrf7+xsP79/EXkAvk/qN8U+qrT4R4
# DATA e3FhwS+DZ2zr1c0HW/fru3jy21s7Hz1oaBkpT+hM6TPGUV1MwukdmEzQT04cIE8wAdOnSIbLi89SBLmQYIX7fXOrzvvdK3AwZzJA
# DATA PZoePKAce8yytpwk9JmZanU/9o/nopUCMoK6wdsLbuIazAfQIu0mj5PU9fb+SQKvJ3TuLE7ZldhT08akhrUpxt5ezOjo9mUFutDU
# DATA O+lW0ciYhOA8XqUbtJgkOMDn6QoxKKBbgQbo6Udt0UOAM9sfDx/HkJyYtRYAPQMUMIn6pxU/t0xTh6Re+NN/zGVlSRfcLPLwWGLE
# DATA dBlLX810I7F2EcPWs3dKDi0yaPPltqkZhFrMbhOHjFZE+3RK5nE6GY858hDe0WbBGUNEi2nVenXJ169zzsuw/UgMHt0cquoldi1n
# DATA 5xrVJe12wwWTF1mFayYKuSBshoxFk3Jmmv068t4DyabcUDkyMN9PUBvZmTGRY6tV6A0GkS8oF59jnCjDHZCrtHS0dm24jAOKgOWl
# DATA JAi5BZjjguTAhN7wyC1e0d1F2Nb9dHC2RWsFxJSCuSHhwvh9424xUyvmFdhlHjJoWIha65spWiZ7/jJPN2uaLarzdCp5u+G1fII+
# DATA A1hXKbje8ge46qZm7jG3fx/vl9aBprT00tchefemX1royl8ybuI6lgIdTUqpV/OLa51T1C7T2KvfkD1Nl2tpKC6lz7ygpT2rg6md
# DATA m4YueKEBKMcmWnVw55Gr7TLsfE2B+8RG/YP6ttPQm8HmIFKYuiho/GgoBtruAz+OTw4Oep0eOnZBXJ+MUYQQLdA6wKy0xQXuqBcj
# DATA qE0iFN0E6jI5HqMrKDxKCbNQzc/DmNgtmK4GuEAZKJfFahmfcO3N1BDwyyN7ZSN85bwzpNSboXRXnq90YfIp0qXrq9a2u/6szHr8
# DATA Y7qQIj5VEvlm1O9pqu6ESt7vAFNKVcNP1dl/M6p5Uyv/x6KCzyXjXqVCforzEgScW4VmUsNnEvBVKd8NvftFNO6u3jrtRL+031ku
# DATA bPIMnXVvcDD0aeY5rDQLLlxHIhECUO464qMZ9dzwu2lC8GnXp5Bc8UoU59gL1p5PJ+ErVpy3/DZ6Q61JVHZYzamOQ02TVrHzlEVd
# DATA Yr6sVsfe2KcSuoEB6deMmfaf3xSl5maNNkAENjd3OR7H4qK6BAtif7V51zonTRwCDGJurW+8u9l6V2xwrg8ou5gaT+KpoL6xu/2h
# DATA WQMStuPA5SwTnemwSDqHw9xM9397f9o5GAzi0yM3c0Wc/7tO3EO5fT59+XPMy/UxfLU8GFLuRTIlYC0DZiKX4pmU20IAgP6VZVi6
# DATA oytXlTcxorAGUYV5Qn6maqyRllldjZ99Z+130lTVGmRAmxKRflJKo2d6V8MENIgXqA3iR0JS7tD0ur9yMM+RovXg2vsyMY1epqfq
# DATA 41mVE9s8lRWeqRAP8Qr/5t/AZ3uDayoEIL0fvqzSxsGUGFDwXX0V8rZbnMnVR25MuCBt11fWPgxn6cpM17ILXM8sB3umArU4mlW+
# DATA UdOrd0FHJxOkwdM6sqlElA0IBeqXaTejCzf/ZnCXtMrQHqXYRVz84/YpXLcw41I7GESAGz+iLDE6z1Jlbqp2VtEzT2jNT1dSRSNL
# DATA STJQwi5Wl84GXxF3/hfNjK0ca5BVrgq5OiHP3GfnX778RUAnqew1pYPJx3f1DWa/LSSrknF0GVZMCfDo58amcfCbYsup9OxuV9hC
# DATA /mWfiaAZm6P1YH3nwcru6nvhZVaZEyvBIv/b+a+S2VJ/h5lSIZ3eP1AKwXDKok69ruUxeU4T9Ryza7aQ5686VedD7XqynSSdfrJT
# DATA ERWnVu9mz3HyPxhpdFyHzenpdLL9C/yWATvRCITEmTmKvL0+SxGXL2DYydRGvVIj+JuIksZXD8KQgSDCADXs3WD/lGJMR8PeYFIJ
# DATA tsQkQCBxsIWKlvlBNIFLtqdWVjZAdOqwhPcb0UbQGY4gr5lSdHZ77cPBMJ70OqDCnAzpfOnItOgXMtmn2ONbJoR9fjWosR2mmr4u
# DATA zIsS5E++zdwy4XDoQylXeH0KT/sqlbHJpGVzV0nPCVpGxTUtCgbg73y4s1t/0NpaWf0+ZEyRnk3iIrj1cDfMGqk3b6qxB1bx5Nmy
# DATA t8GgSwTgGOnfvpXVEs7/tIytxjElE7byrdersLqQeo8nzg14cxKhX8w/JJcEBdcpqXg/7sViEg5t8J+ESim1tMoBM+g92UH8xYKZ
# DATA 47Kye0QpEQ8f9J6sD0pWAswKvoS8il6V6QEQGKA1wVdjUzkD2kCw9vCOc11cxGkwoGjwUtDudnm/xycj0SuMBFEvFj3vAHoL304L
# DATA txI2SU/dCj5K9L2AMffcF5oSzh9a8KcVLZp5B4gdHos6RTWs6kyYV61NSIgEo/6pjCUTW6CEGGLOW/vD7qmNq4GF1I3TY4+IBt2W
# DATA xBUsQKm0QgSmWAhXCUKzDIAYMiOmBFT0KCk9FVgQiyWEWES0hTBv0/ejweFEStxgzIJxu/6m+Lp+O/aN/jEapknEwDqsKT/CxUuj
# DATA PzMwPpuoTDgALZ4RbkMe5HmfKRphBUA0bY+jFqMFYG94tIyPYIISE0SC+M9dBCTGmw+2UEy37OK5h5S3vHATBCxp3grf3dy+u762
# DATA Vt8Iz3KoeOXtQmYjBR/Ne/Vd8rbFX0jNDPliSY4Is+3humNLgGlG88a+cP4Q2RztUzqCGASfQjgPSm4K7Z9P9bPN6o3SYkPVZIV1
# DATA 6mxebU8Po9SOSnTGlP7Qm00J7zSfjQtO+IlwO1x6dRFk6XOKzSP6OX1auPg0EsFxNO/svaFQ8ku2brkjUxTshWjfE3mcs2dbmzuX
# DATA 7VofObKiMIMJtSCBY5JzN5qZJMb1Eba0CvO0eNvuuD2ID6JxuQ6HG8UKsvqN3xaUUenFgjn2Jlo1txB8F24tBV0GVZY2SO6VETPj
# DATA fBoIiLR6eO4g7KfTl2KmO4YhwkLNEhEO52fCeKFvgAsE4p1gXDzjkm1Hj3qoXjj7presjzCxp5ckTtx88+0OxVP+eVLl0q3bf0ZE
# DATA CSvmwXDQoWGvgjY1p+b4f+hQQ/alSWK0FSskH+l+NfOT/dKFzoZUIiex8DV5/ymQt63G/YYI26TphG3mKug4Xaa2LgfL1uUATHfv
# DATA bj7cWHMvB69ULWp16DvkwaMUQLCdTN9S0vcsi3MqS42kx3QBXZK7jsZcdIctIQ8CPJx1xzR/B57gL0BqFemYQ8uU9JqHUgoR0HhF
# DATA QfUhCRvP/ViAzss+a6f7O34tTA9bZkzBnc3V79dNKjfrszxG0ePGVD5NpAKKXHRKUg1DmOtYqOqtVgJd3zYdE1hRhf+0DoaYLAgT
# DATA rPbAH56TawIdtVogxbRaocx6PI7RkUPsP/xcWRkfngCM4Rb+ojJtgYW0JWSgTqtVNN6E/GStNr9S0C6O6Ly5hRpwBhrGb+J+NhxN
# DATA 5pXLprTceCszT9rO0RCQjWsEcozioXaadJANECZdBp2KqShLJEwsK0NLmpnDkHGQmYVIeV68k/Z7v70f9TN+RzNbdhPgDZpeAapN
# DATA M35n9N6MEoxLyZ3gYFYui/9Aaal/glBVPEyjkx7bWBdcdMkddPOtP4G7+PYJ5bshtxLa2wq2GnKFAK3opAqioYodCqvjgObSzBv4
# DATA Fpk38KOYMP6Eq8OfcSX4M866REf3t0sUZOJMAvC+2xQHP+Fnnmn+xrOa3UiCOi1INxvC1W06VwO8I3S1iK2p6ypW0GFVTlt2ZeYe
# DATA y6hR40/gQ/za6+q18aHSk17arao4963Xf6//Xv+9/nv99/rv9d/rv9d/r/9e/73+e/33+u/13+u/y/z9J1RCEXMAKA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
