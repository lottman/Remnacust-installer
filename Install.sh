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
HELPER_BUNDLE_SHA256='84bd027331e1a1f9925c0daccd3eaa06e7819cdaba68c227910e0004ccd5ceaa'
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
# DATA osJGuwEq15p3533vD/8+yP43Cvi/wf3ffdDO8vY/qCJ/sP//bev/foa1IoKprw5dzCXhTcr/YumgZDJZksZR99PRiGqkMT35YYr3
# DATA CN5X95ev51Tf4vl8mqovlz9LZuozXnQzTobqa5L+7sWBr5aLZKzrAwdz9FPor/FkZn/nksGYn3C8s3uKt16UOcwq3vOjo9O9Y0zO
# DATA qHwz/b5/vPficGf31cnpxRd7By/3jk8uvmx9A832Dp9Rm+/78OliVaudw90vjo7pRnNy1eIJsflwrfrppPbn3PLis1eHzw72Lk6+
# DATA 2AE2u12xbwGp/GCt5j3fP9g7wXSUSn6DVzjPU1RV/Ga7JfJO87LfHDXBvry4Yiw2fEcbsnR75Fh9yskS3dKyvZUL37a8nIFyem4B
# DATA wpk18modsPBUq2OElhJHCf7uWMc0IUtC852WBaNET0gMOOe7ZUrh7+Inw4/aY1WpeS92fnJxvPMVlpbvu0U06BEuODxr5x7lTpZF
# DATA VVxsVdcQK3NHcQhwVJ2KGBIZoufqipMhX25SJwLXZerkthKrU3lXtm1DjvhSA8yoVpflyvsivS9ex+q25S1vZVG6CtWaUv+pfrq1
# DATA bp1+wO9njfVz+6fax7VPKypGeu8ZB7m/QJiXQKWLM2G+/gXekBCr6zwkURPDPgu6OrJaWVeHaCj3YpTwEbHFcgabF2uMY2gFI7xS
# DATA ehHrESUZoAPrOXLlmGqL6xTVvPuqD6izmwYaVbqzUdFdO+vIMOCdNAkfHZvbr+Ctv4jrYZqOq6ZT+NWaiS6VDaRCm07QyRJh2yYw
# DATA fqxWkXdoiClNVeaRNf9Hfuu+xXimb+aT5Ril6SKemzNKwmux6MjUCbPR17q09+U8uUxVBs+XPeS2jXgacfYOsOUHc4z3ze1MZRCq
# DATA hSJxmEzl4dnWOp7qwf7PGSR8XlZCGcGq4kM7qwhFxrOd0x2/IhUU7Y2BD3d3dr/Y8205QBtEfe+072gvYL+12mNO1r+axm9mfG+I
# DATA M0tfrioy64HzYpGlK+UwEVBm4b1r/UIuZDQ6howVTENQIFx+xMs5x8vDZ1VmQ/4nzI+EPhXEDo3K2zkILVKunTVlSarDtcpa7ax1
# DATA rtkiFYfS7E4ntNwzAAgU6KZcTK8RvM0KcOd+Fz/DcHV7V5k6yYGqnjIJ3iST5WRbMXnDIR8suJk/Wl7E/xeMbTrtgBXDMCdlOQ7m
# DATA VNPBnPG3Dp0jNfIA6QzWvQLEV/ODDJvFwcSMRVfgbcvPdAqhKjOBPlsO7ZBwAK4gzx8BL9U6W6SpP8ZMG5dK8rJOX7fAdTKq88C6
# DATA ZAGHxx9g9E570N94DK6ko8L4MmPrnBv2rI87xyImcU+8rbAVS3doi7CpYxV/E4ar6Fodd3RdKbx6pt46f3BfvZpmy9mMslHVjlJw
# DATA V2r/+hKWoVMzOf/2srYcKke7VaM5yPqgIVlo0YXjbrUX7pix7pTssUpP0VNVeUr2G64tKdz6VCGXRFFHO+Ub0tj9YOblCltRlZrn
# DATA psopFYBP5RTSxsqRiKtnToiun8Maw0+z278EDb/2l6J0/iVrnN+AylmTo6OPEIcOdhEoqplTkLUWFrlYhUYioozUFtkcegeQc4l3
# DATA wMN0gT2Y6jEfCrfKmXXhxuSkKnfMsGBOdibnDhcKrqb/Q99phHSgGPYHwoGF8sxuyJYTd3hHB2QCUHU7kMLESngEH2PaWsVFcStY
# DATA sogrxUtCGbC1upQlk7KJjhx8i6u/xSKMTs/r6kx8WkcXOaOz5XKA52252SOXjUnaY7FKj30GyOHwehvfKUtD7quripJIk7ArFwn7
# DATA dnrRFX/ZaiFJgXWKXDWD+DO3yCsI1LyMX93PB1yHC+LJYQh+lHIRNdwHFUfECKv5aFsLHI2J+88zF7U9vlh8Betxei6yIH35pS2O
# DATA qTUfWakV6s3L/ZcIuUvvFnILbcorRa0meXU14wTvKwXcWRedriB+fd1egWyAfZnzHDL1e4jMFI/WL5Uk3xY6wE1kvQKbQPmi6qyx
# DATA 1Or2BrWa0ui1fHEMKYVoYFhR/8wc6ZaVxD368ccycwXDFo5xV1x+fQ7RBd05ficp05xeT4tdtWhFrXUt315VgesjqKL1T4ZxFOW0
# DATA fkupztmNcmY8ZzvmK/DdY0TWQX8FG8G26MQYxkEjcvBV+J5LNLfOBlvnJQahYwTSNlht8jnKkRpGlAv5isy/v6q46mqho3BXIn1+
# DATA lshJfPbUNob9rlhFMmRdk6uVr0v2ATpwG5/Df/D4Mu37dPjT7SRtfIbrvH9U5b5rpZYDkFTOcFCur7zhIJr7I2TenjvNrCD2lAoo
# DATA Z5ZpFuIaZkOnZBI4PJ8u2K7Mt9gMkgxsA8sEMUyuIFVxEKhYfqwW2KA8IF2x8xBXO4U5gLi6zS9ilnNEcKckIrn7UpcDPwOzUSr9
# DATA 6hcbUrpXexnNEyV6GXtYY+RJxYzT0JVHvvkm//PjPBB4zXiBRAWPlfxJFxQu1gjnFsrjN+Srp5lxkxpTlrqh4+ZCm3XbolXN0llV
# DATA 8bnaKu6uX3PYvLqqqfhcq1TTKJ6XyZQwACFlV8N7SKSky8VsSecGDGHWHqBhfkeR7s0Kyi2VAXLC8SFRkPdqTUcpHzQiYE6D+T78
# DATA Ui3qc9iQ6K3OHxFC9REjFv62oy3UfRAE3S78KTuWg9n9tOT4ft1GkCtdLL6tOR3/ViVGhlbZPM6yKuMNNzCp3FhRgaDabuqK2iI0
# DATA WFDoqm24qA/ZZw+67qiXD7Vq6CU/Z48JmJ9wJIo9h1QQBRs3ZOrK9aVdbPk3RcQZMYU38jIqzxKg7zdb9F/k2s3mueqG7Rd6gEeg
# DATA gulljN5xW5LV8QW3nqQlzaEjBQUG0ZSexvXLOcoldgq1t/fSKm+1dlQr087csqALVmgP5RP9qYEOBC6wwfpLTbMTit2J/eO8XSnR
# DATA 4BSZ5AwY7U5BfVf39OXe8cn+0aEamCt7NNgn+hhXn/QqhcQ4mqF+KzErtFzMGXWWNfdBJpyLCb476DFG3GNYoe0mtp8qEsGbtanS
# DATA hjrP5FQBXbHADuEQGZqyKs6qf9eYIoeTIEbW77FkYtu72hWJCTXGG7mlOs27JbdWmrpuzWNdaFjw8bZS6EAzcbH1thzefnevAHJc
# DATA X7W7O2vjVa3bHnCSdXoHQ4zqXidkP9PFdltf6q54npRDLrgA1Po/0sVvuQt0z9rbb9kkfGrbMoCsZ/ezjprzGsGpboSk1mqLsL9A
# DATA ZMcFs0WWYspnY3iV+BZW8CdF3paxqTrXaHqE+Us3snGZo3nVQGXd8UZx5m/eNJsc6TJtVtQBeqQINCfV1MVJul82ge+5+ks0JbCP
# DATA ez053acMXNMNIM5ad++hwjiFE+CmcVlIZ2X9xUej4TKexuqyGy9362rR56APUt/rblDlJ11PgzoDqM/92YcBS84Acgmul6BixfNr
# DATA LrQVBZgREllAN3ypFOdT4kgGu/RWrrqhepi53iRJCXfYU19yGOgKBoAXdF1YqhEV0VyYHCZDIo2S8kX5ta7aPsH768eJvreaFGLM
# DATA NQqIw1A5MJWEhJSJnzEsP0rebFcaYuCtYxQkmW9bG6i2mrJ+R2eOrjlu4BR55DAhxbcf85524nS7bnvd1FT7V1vu3tIJaabP3qse
# DATA yot2CG0KaaLdE+OH0pua6UmDMtOU0+gtfWvs7f1k/wS2hHwDEb734uXp13f3lFgpPPm+vzOlu5as4Dde3zRbDsdJdkXbIENZb/aA
# DATA ul/0KslKupvN0xCsFDyMT+VDFrBl4iUwBb7Sz1fBJZXYgcUfJE2vbPa/CzO6nyEBpajj7iW8ieuhEO7LLoj+12VVpfUxcPKaDlcX
# DATA SHCa5dFknsjtFeYelY9sTmL9rpCr30R6dirLmO3/aJyLD0V594A0kIVKpl1JJRhOjmzMJ4t5bG0m29fgqh4rPRlCJLThndcdD66d
# DATA pkQv6HA9mJa130vhgXSmaM0uHYDWAdVTwxhBpa71rgcKBuRrGNzbmLD06NYS/H10c6SpD4OHF6TY/IHSBqqagUYkVYsgBBqyJGtL
# DATA 1x0QNXpc/irj3HrXMeYLndgFD7hkgdJ6qamkCVkGmq56wPoqf7E0YgaJ1eLaw4UwmDb/FzljkE+9/e7z/1utXntQyP9v9f+Q//9d
# DATA /FtbWzuOsUKVny1ndGFNHFmVkTmHW2pZB+gUwITQCBqHqGyMlmP7btp70v0pXf8DkvSXQ9Fn9C+3+iP6XD3veO/l0cn+6dHxPmW6
# DATA 84EkKQGD/obLq3DeSNIn43SxAJP+ibnAVpeJKfyUv7ZpdR/FyjJOfyWP832PU9DAyqDKPyi5xYU74zI3989VVcIp/pIfhn6Hnu88
# DATA vnGRkGrh82qxmGVbT55cgi6yHKJXXA93nJvEnTNZA+ajumA47rz9FzufY/3B3DkI8SNtnTXXN4P1ESf/1LxnezvPDvYPMQeeYrgq
# DATA 0DJLs4SqKelbE0z2X+WPK861coVosLnsWvKl/7hCwV9VCD3fai7NtnQzBQbssGB8gSW5q7ylMJ08XVDGRfGmF13Cx7rXiF5DcPl9
# DATA K5yg07QxCoQPuWDkfsQ3NebjDgqvVvTBdEFqqNUj313AcD5wE45z42rVAuQYFuE0uMxMBdFPCs+fkTVtmnjFexStNx55PUM6v6TA
# DATA l7lWosGdyEWWVu3hG/SensEUpFjbyL1vkIs92rRENepsFnSmF7FQkBV97XJ5g9OFo9zzduQZmDsfZStandfO7QUFwPPFli8vqeib
# DATA jJSwUzoPvDVLOsjFm8Hcs3iX86eQjEDTAc1SsppwJLoy2JqVH4yzlKmdLNBMXGLwexJkcdbI9bpznYI9GGSvsednVHwQPTfcAZ49
# DATA o/egI/+nmKHMv0fYcTweuZ2Vr2Dp3DiB3sWHPC3B3nlJcS1VwdLaOJhajydhknDRQDGH7ma88rlWsz1jYx37U5S1teIG0NK1L7v1
# DATA cyU8Z+bLuRtN45fUER5Ce/VjVILrJKYvWBXO5fah1su3PnSaCKdmuM6t5PrXdZLSjUkK08U4QdW6BEd19cNtv5l35J5yaUvlMiCm
# DATA J9opaBpBREk0oNyD9h6Zu2TI8bFtaQ2N+XJaPZOCllikD6d3XucUMHHqhsFsgRdAy3T5R4yUqI8MyvYE1P1Os24ArzlZKGrEbBFB
# DATA a8rD6T4+EUeoHpYE1hieoYMqjjI953EySRZubqaVYZ4fG0CyVpCXxG0jqz5Evg+2EeeOqpv3+L4tvmTUCc1KM47MmuncJvE44qNQ
# DATA eBsBvLnF73PMV8bCWoQXLLWUSZ9Q+XohvYqqsxhwYUVdyNxJkVJLzbKocPnc5Txd0v0JamYwhH3ln3pR350tY4PpiHmP+Qtk3r5t
# DATA EO3dYWLxx9S5C46zIrp398LDqlV6kWt8Slnd13E8E+Dw8gNgpmrf0G+WLpPfRIjZdrOACwfFijitIS3bWhIaM/eoAvmdrRecuOF9
# DATA mdy6P2aAD+YnvJT7CKyq6qoL5CQJ+wjt22LzK8epn6rsuJ0OrWFZfYmve4+0nYaOQrpMNcKDeqxPTUTLr9SsC9Q1J0cAcF23HoQ8
# DATA yoGtSVENYGhS9+5yZkq3KztuWCKDCr2Py3ebqnS6AM4Z5vaey/CsIekwH9rs97E4nacmxiTOfZgup2RpOp5IaeDovSUb2wxvacF8
# DATA 2BjvmwNBeA9KeTOvxKfSMbYlp2jk6MN1RyecfrBir/zG+V39o2296bfKSnIea5kpKALGg5sn2lotHNkTuw12M7L+eD53vb1DaPf6
# DATA 3nCkawaUcPEHL0H/vq/F2wjeR5StY0SCbZkoHsdo0z4FnuJTEd66YoczIEJKHZTa9a6uV1jd+YTq8OqlqeV0Nl7ST7b91uOClJYe
# DATA caI/loUtZXlYTTFrIrMO0+WYr89DJ/z4Vim2yWLV4nB/o8ouLiqA/FZgv7O9M9pUFmJ4qqsH063pisHmKKVS+zau9Q8uwmubRB9S
# DATA 0JdlD8Y1+SqmbWW5rmiPrNYqz8sKsPW6siEf8GUrSe2WxRWXsLqrjb6QzP5fzzmsizT8Hsd4oP5Le9DquP7f5qA3+EP91+/K//ul
# DATA RFV1PqBwDrnIi52uYvujwgIWOjO4+/y9ubot97p/6/5LsMNegsn9ZoU32PL9Sr0Wu/4EH3QmtVXOcrHXYTtfhsJKjOZ710jTvf8g
# DATA MyUmXS2nr8n3tgCeOA4mwyjYco4oWNZeDWtk5CO0DJFSBKk/98gRPy+pkKFC3hyqWgSXwI8ysH2U8iOXN9N8TJTMSme3tHxq8EQV
# DATA ZuHLQIqK/hgWt/Q9zR/X2Umxugsrm1Wu1uQkQ64IQCcInMdCefwc5nifOvnuv7z7Jdf2VoW8/wH+/Pb9z9//9bt/Fspcf/ebd3+P
# DATA V9i/+ycsBK4reQj8mXXQL3cFtVz+aZ+pM8/kfOojyszfPTgDqjUuM6DS41iA/DcPzIASp0k7fRucVSit+3zLD4hIAyRQJg2eE382
# DATA FwkFshR0BSffJLSc4QKDcmCu6rOEoORETy3EFdODZgk63pBmzhgf7j3lOAr/TM4IwZ3jw+SALcGmT4PThTLJ1M6CTud2S7zRIVlY
# DATA DeWHB88Cvvu/FF65njth/Tfv/4ZICiu5wycs//7+b6gm/Pv/BI//kcrP/zO89C98ZLCkgL4QiwUiHUNASwCYm7pTlgkomET9LhJO
# DATA MJ/Ah7sHYf4vWHj+N0jk7/4eqAZh+Q2Xxcey9EApVmF6rHf/7p9hKj+H73+7El4iGYCwbiILBPtZDu7z8owwue5sZAWW3upR7tbf
# DATA wia+Wwd7ZPlm/S12eNcAzt24/Fkll441Uy6M0T1BLKvnrbcMpS78d64G42EqBSvGhA3o4jxaAnUyyXrIxoRzvvcxWZY2N4KFgGX4
# DATA 1bt/ef93Jbv4F5Va2bmrFXeuPxIdfyzRsApfzZ4/EW+mpy/cZAfGh06NGe0v3v0jfPnl+7/28Q9+ADKD2d3Lsx5/7MWF2FQBwNvS
# DATA yisAqFjgyk7oo4qEffCsYUv9nU977dc0Ub4dgn+Guf/83b/A//3iEWtNrJgudyH+TbBxSqaSNcaixFRP2g8l0dK3zNPP1kz8AjbA
# DATA /2DvbbvjSK4zQX3Gr0hSc5yV7KoCwLeWiixq0CS6GxYJcABQ3S0QrklUJYASC1WlyiqCEIRzZMtej4+1Y8/sfpjdc2ZnfXa/7jly
# DATA W7Lbklo6Z38B+Rfml2zcl4i4ERmZVQDZLc9aGk8TlRkZ73Hvjfvy3GVmn/lyb3Q6BIq+jEdiuXAY8HOamYPJ6FRdiTr6k85sMmBy
# DATA Sl14z5wS8RVJJ1ROzz4QGJznsoDsxQgxcsRfMCH+yet/VH//p9dfRmqGf4npR36BWUBgJ/7m9RfRR/3px7MDP4C7XE8pxkAxrojI
# DATA lUgEByyyR68RwUGDqd24cetK54U3AwzgJxWbhEVALZDocBW1pt1pUexzEvoAyUtavsRXITMuifxWxqm1gh8FRvnfkCH+gheJcqpw
# DATA DpRILRSdEXVmIqxV0cOIanVDKXR396Tote8bUYk1tUs40x785hS4fMAg4VutIA/taVloH8euJScQTnjjImvYd9bj/MYNfOlExXBH
# DATA jFSCGVhR8DDvtCDixcPIvqvCxHpjOHQtvfOCRxKawC3ZcjeoBrZAixZnh6rRP0wBeWMM0DROuRXVSy0+VVvQTeii+MYZAaEw0OQ5
# DATA L/Y5P6j5bJQzuUBpIK7cW39bFGEUfZVnxqEVJJup4iDFwX6klD8/FdhkOKo57gCO1MljcuTOhWoBvVuhmqJUGhj1f8Ze/6kayN+A
# DATA +KDku6LoqR59rsjKT5EPfeFNCYiv6qs3fymOIjx0rkZIbwzsYv/wrMNxsgw0JvdMP3C1FqNaBMVk5+O1hioUontC8P5crSSRdkXk
# DATA 47LAZepgPGkp+fEdh9mj9QJ9LmYntROKdTeZWUW5b5XxgvJd/Prz4ODVuGGt/gPKFb+JINMWkEz14Lev/1nIDUCjcsfOuWBAP4vm
# DATA jk6lJiLji6wSHM37eSc9yEeD2ZSd0eNmE92j8C0AXeYlsfyah9YMhACGBQicAA0qsLgApi40KESq3aHmi8XP3+H2/1kUnNhfxsFx
# DATA 6RHkCzUNvO1zYGKQf0wdpb+CDGh0nC7VOLYIOmsvxh3sc+REEYImiI1OwsvTyuKM/no0Ke7ywscatiHoh1A+84poOBXNEW51Wcec
# DATA XOOOFs+dLl3UA+UAwui7i6lCe0xy6Hq2v3+Jw4cExsgpQA1/Aczh9T/AQRMU1NDcL+FGg8dSizClFxpicEgdy3AmxMBsOu3CmsqK
# DATA gutaUs/Vl5fvM3+uRv0PxGDf/E/q7y/mrLSFdBJdliga2qlS3Ao89asOEZNqTsFV9F1t/hr/F1hWuJOpZf1z0szQob0Ct8GxSRlK
# DATA 6D1tiDIxR5d9sk25xv+CvVfy0G9GDwdKYut3rREUNNg5utBRW8xk71lniJ5Tysj0rB4mUXcwGJ2SDtCfuLqeSnPb3zc+qey6urp/
# DATA 4djydd/tiTSPcMOhtwJfFLjlBdyZMCvjP+Bp+yc4XWVHTwtq4AnRdlpeKqzLuS9CkzvFmiN8KilhlJt3WzlL6Hho9FN9hi7Cy5qn
# DATA L7NejZT77opev379IfQI10ad81k6QErf43sKe8kPtW1jepyCxoKj28hx0VJXMJ64PMGAT3GuV4tHVJQF8PhrJ4VyqBc9DEYp+nEF
# DATA 1ouVKgqv/yBVGPcpmPb32hIaqVLq0Chd+AP9PKzASQT8W2+pZLD5SOWp+0fMhQoaSXXkFlBQlQkslwGIKmVFpf4hYCYSKw62AleK
# DATA KdZjT4sVNypgnvzE8W6LFvc7Zqkp4lhp2pp7rZuoJKjFB4PRASVCoKtPiQcMMcgFYae8mbgs42zPY5yurFIAx+JKl8ICJmxaLcYZ
# DATA 1sAPLi2q/V7ENF9gofu7PwRmBtZuaWLkya25chDlcshljuIcAeUSwsnXm8GbfG+cKFqtecSTggpM0ioSYpvjhxcjn32X4bXT9Kja
# DATA Z8gYRBerz+rY499HLnJX3VZVUvvBLTYsVHUuWlj7hl41DboO+KXvSdsc2CRC40yL5PofUBVk2g76JWs1r1gywv+D0GHzrJCPnXsF
# DATA R8V0qhUGR/FTqBeU6uFk7OTQJxCJWK1fUZ2fo51/y+2gHXLd9rSy3J84rZ4MzFvI7dOfGX16i8zFUyPih7C7DEUq8F6/bqIBpTWz
# DATA KE5Okv1h82AGqC0l1edZaT36pubPjLnC6okpVB3KZ68hbOoS0JC8Q0sARZi9Ypt4ooo9pY0CqEj4fTLHe5eY0c5Zrm4066/U/W71
# DATA ij6HTjaj34f/nxIX37/l+f+trtz+Q/73r83/b3eSDnM6lOpCSzmwFCOD+J+cYxxAm5BN1A3WBnsrOgWS82g2pbKIK6KKgM94OsgX
# DATA T/3WHY3P3j6pW/9Idd78mqbTxSPJdaq3yQBEbkKecZ+BGzNYZrE//AxHFNlyqGapw1+zIf7tppCDg0x5WYaKUU4hsAoOO96iO6hL
# DATA U7KWRYNh2BhFqvVQKWWbGJWX7QxID/5hxjbgCQznbovM9J8oGqBjFRT3htVRsmQXlFfRE0MeSOa1dNDqRNaiXj89Go6UYN0lnYeS
# DATA nRF2ZjqK8uPRqdkoSORwo6A0O+OeUAAZ7hi2fauPyfKEr+rRaEy704lJZABHnELK8SXvMjoJjqt+oG/a1v2zSZmGzMtKlDl/NhbR
# DATA KoC3yJ+y98g/gyHPTXWiR0bZEOYm7yn24P9Wl4V/Bg1boSE0AYKbiuvWFkzro9MJabgjG7Ps9sdMExwxRJTsFPQYN9+u15X2MWsf
# DATA BbcK0md/6btdqOvY69+5zhXQZwMVq25g006KABbSa5gPhMnLJzeZTd7Xgc1Zs+7D9cjGNjDOsZggcs1QHyOkeTpt7nQ2nmw9Wq8R
# DATA 0vG0A++szywU/KNoZaTYYjk0PTi18deKtMDNe4R320z9WmTH/O94S/25mkd1JaV756/Qx+a3oEP6HdiXYVnUNfTXamYLd/LfvPkp
# DATA 2d/h9v1P5IeIBvtfv/mPsQsE2eG55qsqz7bjZBHDo7hl9yPAgVIsSCsi+OcY9ar8M/oxTM/qKiZofKnuWqDW5dlQD/CKSXAT+qn6
# DATA 7ScBCferZXWpakLzrjoCfe4UynXDKcSDewDZM9CpCFfZTD1BbW+Ny4ehsDmrAOyRwxGo1TXRyZnEFeRHbMhVIPJ+2nm8+V13Pxnd
# DATA qSmyvf5RsYh5+2hju+LtztZDr/5SjeviBBK2HVKln8Om+5XckmQjF5sy7EhY0T+iXvIRnar33ycDR+nhucTA/k7td1Lu/D0O6ZfR
# DATA mz8nogYuudUDUscJvb//kf139UTAR4rSob0ZFEi/Ag9e9Yhc3mqigbsrSoDwWvkigvwdxskjHY8HZx2X2tE/EJeFF3mHnepLChZp
# DATA leQNQTliBDqkUU6WBiq/R+d4vw7Ptzrbj7Y2H3+mzir+Uttr/eHu1rZ5sLn14dbjx1ufMJiqvITy+VDFDvF02DYdK2PNOfPiqKMm
# DATA 0nSKScR+PdJPiDrsOzu8SJC1xctUxCRJVEREKZxm6rI09wvyEkRXn1+zuwHsCiDA7OsEpJeKCxnCcavFFQ1rLwr0LjSrMOWEzWff
# DATA 2uHqCSAEB2yLPPr9+VgK4iqqyrsDJV06LXMMj7lSsL+i0HyAQNvp9ySIeyG6oKhXE7uJDIuUDphUL1mPm+G6nZm00d7QRjpEdy5v
# DATA hRlDg+GZtaV1GfV9ZEWoa2mdzBNVRRNKqWSjKVxQcvNJYZA5wEHXeAwAQBvwGXEkuuAoyLHK6S0zYa9XqsOhbomRLBWqVq8Kdatn
# DATA snJnMfWZ81SnC0g0/1lRyL9HCRBdB3Xb8LkWGIu7JJHynb1x+GPEebadtDPNdliIpoGpKcyhCSGCErSpZkON9dqLDQXKvAgkMqaY
# DATA n4vIc0ooQyrxJVkjIsWYwIbwa3KgtmYT5Crouv8P6GCIvoQoemMsSVFkrlMP6+AMy3/FgNJMchc+2YtBX7DDD41bKmMud47VtVDf
# DATA 4kw8LZAKl+sIT20urOY+KcjA+A4fqns24F7wvZs+Qitaa5ly0NATCjrSnvRw8XFviqqCJnQR7Y9q2qmLFe3yNzM1C9pKDb/H6rJ8
# DATA Opr0zG91k5i/cn9r4yn+VCpPXFMXMo4vYUWVOPBn5AFPDOInyBF+E+FCKkGE45ZAVH/zl2hy+ufyC6gBGbMqi1oN+o6xenqZ6jw8
# DATA 2Avw1w9nGSC9wp+Hk/ToxKZRccCFypaC8Yo0TpoqwF4pGisGAyQ72fBlDVSynLxbAtS8yM74qak6FJWWTlXnITJtEv9J7Tut7BWs
# DATA yF70fLr/XvId2Ac21EbVyNEz8PpGu3nj38SSjEK67AyU3DWulVCCQIpqPvHoKrwgwDpIEmDKU8ho1GlB94GGtM1W1JUdDtKjvI1V
# DATA VtgTuH74R2dC1omQMbvKe8UG+JUDtas+5wkfT0avzkj9Tf1wDmk9etEf9tpxN+31zmKrdzFzW/vO/WsirWizsZ+4k0vV0fzWvlMo
# DATA yxZO0DWCRxPKoyxrGhpS8xO4D0dDREvTHy65aFggQcyGdhmGoXXg4fESmMnfkE5hulf6L3Rsh5ofiIRDLqYWbxmYNQp9POoPHZ93
# DATA feh4h8CknCR/Unue30D0+wmab5/n7yW1vT+5p/Zq7V5SgI4U3hA0Hk5miP+os4QLQFNHj24i5h79fWufdlzIgqREMeSGK8JhdSgB
# DATA Wfzc5rgPBVIMgCSATwXhPRQBA8keT5nuiAR800FUFKeO+6I6g7e5+DymSFSqBB7x37qmc11TMRuOG1wF+B6HFGQle0LfBxxOhsjf
# DATA eUKpCjxv56hHw6rcWG/s+XvGw6KJmwYaSKKG//DCu9ziPGo8N8zWXtw7Mrtg7mgTeafO5zx/B0wFbpfAIX6BAsQvQVZAIeFLvGb+
# DATA gp58DtLE79BX4XMlUfyNevobZDqTDGIkMqIg9+QlBi8ycImhUA1UKJk3b/46LgejM+k2AVCnHgm1TEFOI5ZkFMNWCQcEsG31SeZI
# DATA qscsYULlJrdQIWV5Ib9PUTmKrMzo47B7sso91dY+oqcaTVYhsxjmAtdp5rEJbL6QgAr+Kj//HFt0QhovTzFr9B7vv/9+eQMIxH4h
# DATA V0T1XmfW7PV1BIhZD6YeLTnXgVVbCs+KuScyE9MNDV8i7BjYx1GQrNtsHDYR3ox9ILEESc3wIYf1InBolUxZhCgzde7RXw6s657d
# DATA a6jttR2CGwF+oLUeHqwYMxXCFcNJJg5GsJue7KIlH20SQeGnPxkN8UZMM6ruDVPKxp0HJKKSMAeeJxDw1Odm4ve0AA9Lgr5gQvei
# DATA iR1fZrRJSPbIn379IhZuBbiUqOUsLCv1BeQ16IrNyrPvhrgsJuWJow3gHNR91n1iu4GsDVhIn1Ar13vX5sCX34x2jzPFcfNppHcd
# DATA nKZ0Nj0eTfrq1PVfZhx4OMxOoVP3WJylbEJk9xoDIOt0NCrm3DjU5qn+sKwLqEmZ9I8Qf7XtHi9cEKFFN4F9tO51Qdd8L5DA+IHx
# DATA Yif2Gqv7BJiqheAygZoETyNFqxZ1V4OSsuO8EaQz4i5gazpXzbRo3S5cYEK7/OVbVJI/tzv8zZ5Tfh+d0qFafUjBJoC9AoLO+IHm
# DATA oZsHXaCPxnyQCGRPMcwfqF3fwCBUqyHhxygAMlQgP1KHwwsmtZXYE1Rn93ZxpqC5w7jOybZ0LzXFAV8vOI486TQYvNPzQGCMUdsx
# DATA DGPHEuGk7vobsTG5BkX1WNnfLL4RW1d8DTbYV7LQZDwasDcYPlML0EA7+IzdCx1gTql70V7xAdTDPU4QrtUS9eiG0LWAarzfReMz
# DATA 46O479Fxd0eTSSyw77WJpLNIfqUDOI1V0tt9ozJCNDzj3l9BxTW0m1ZialcmiE7GBRP6GPhUwAnodva0x+/BaDSoSaw4/psGvTOl
# DATA VTCEgxNu6dmGrYJCDRLvVqSbx89a6Mah5JlsDH/UaBtJW54OTTbWPPcDeu3v8wl3oWUGYwec84jzCyFrQCeBGLIADT8tVqemrrQ3
# DATA eFt/6IuBnjSDvL9wskAGsHLOwp8wSWhw282zk0Fc7F+togJM+9icvoLDQEZoHDc6yvolkkLO2QoPh8A4CtZamE6jN8jARaWostfa
# DATA NFd5Xwd3lM5JpnilfgDWdJRR5W9gKvy7P0SQUPmInNUUp5hkp+lgIG+ZRolnpRfyZKrpNzYn39kYw/NkVYYzwBkBHlKjTKhOIb51
# DATA alXwtfbiGur/Q923fgUW8jd/yXaeXzr3KnNnMm3BrQz1dqoUqPJcbAUwztMNC+Lg/9r6lNhpdkR9NIgGuo65quwnRgUPGlMgt1py
# DATA Qdo9GM16h4MUYRrjoy6c62RBH5lfEHoRKjMBIMegXv0WbWF/H+0+3ikZlNr/o0nPaKLZpLOA1chq4PVOW3hK7BdmRgByPp9mKRom
# DATA QNDvpQP15dvNwE/IwQJUuH8Kl264lfvj194jpkuu3QD6vKPePdFu5qafSdheRoOE0S84wMXGB9f/z1ld/WXV6D4vqqR//uYv/FGj
# DATA yh7PvjjR8LNm6IRZWvrhX2wDc/SUEmrdvn2LedqrSXoWbEQSHxIu5e85TW1QYW7tW7a5eWuB5kw78/gCAnHO3Qkgs0s67mMLILzY
# DATA 2arbMV2gIenW/OX7b2RKePPX0drTjbqzWAA7wTgUP48+VTUXXBcs8gS7LvAC5sfphLSnc6y17KwRsrwiIXbkmYCxDGoliyHWJEqJ
# DATA nK8YLeUzVL+8FrdFaSuBW2qCAyvYmK1AZgfQQt8wkk9GA5iMmrFYOUYpO3piWoxXZU1TC1i9jQdhcCqXPF95azoTEyArfTZBoPC9
# DATA WI19b2X/cn0ptCZnGdbqEQ2zWBevJNnt4HhwycT1mlST6TLjijmpGqAgbrRA7rTsFb/YdyajulOGp8w/g//F4r2ElbKVlttm9Prv
# DATA kKr+JfqY/BzMg7/E4hQsR2ZxbVUEvMAv8VN6zlzp5/zwVwZAh6bEk6fUQ9RXwktapljPghXC2mY2XIHEcF6HJ4cC7YpT9P9gbN2f
# DATA yakhDyxEy7EuiWQFFaToIO2+mI2F/wI9IBcKPnENByZxTkZf+p4TR+vc0OCRJZNIWxUo3ppQQic/R4Rp1VoBpGItKb7EaurUE/Vf
# DATA cHKk7d+ycnVJmvULTPIFopL5SZehlrq+qh/jYwBYbak/SHJHTDwaCHeLfiQXAsG1Qvp12VdQxJKpEAiUvGP5tc/Vq7m150jhCD1J
# DATA gW+SYtvaC9V93mlZCBfa63ZOFf3D0Biutb26veAvvJrByw95DmPPLFCsU1yQ3appWbLDQ8WOQNPYZtcTh4JeC1NBTjZR5K84ynPT
# DATA aYeF6Z0ZB1PdSacPDawgtC2uikVtQa+EQEfztC2qLJubUa1edRd+CMVI++/ZZvYY5YJ1FkFNl5nKhDGjuXIdUlBsU6ddeQVlcA82
# DATA yL5bDXlLo5knAFK9LI2XauztBjOoEvWoIw7T4STLj2s66NT0vu7LM/UKq4C/Viakm1yqOkST2u7FWk93uEocHWx+0+3Aa4EqhKDC
# DATA i/fQfglWVYJ37g+beTblfAC1mDNJkDbPBb5Amz6gT+DHrXD2d3xJJ4iexYln9sESjtmHvjFJAcHPhRxjYtOcw0IL6bdxjyy/TCfL
# DATA g/6BRYBdVkw1XtxV+f8ylyvDMAm69Wfkifr3FB5i4tSNz6mvsVCXdCVp/Fd5eyPB4pcY2y5lls+1E5L673+UgFE4x1o/dx6DMgaI
# DATA zEEf0zfEnJqPOJI9k+q0d7MJJAhUZXj+W6VTg6ww7XUg87kWwgWwGiiTB/0fZb2O2S57vAmqF7TaDusNhlgLbgCR5m9ZU13ekM6Y
# DATA C/tlZV8ON7CdLqq7FNjeVWMEJBaxN/dFFkbwHxYT5VRcnFAzdPe8lOxmRbtcRHC483KTFnyCHxjkBpxs66ltdhDPqwmC8L/TyR/x
# DATA cmlf7lGFiPfBC6gvVMgOZEmuQt0DnACzBX3B/6vvY4GxEH+BqsAvwWVTXwF+Vek0zkf6HnlY/JaxL39GEj35BZbMtZNc69WZPQXz
# DATA 6PeeoaL7wSr2bhKwiGMJMPOWeNupo306AjPrwKqH14jX2XMyKjGXoNlKQJtaToNJpczG3ot3uAfuFncsJU9wsBZYX2z1RxmoSym9
# DATA fOV+Z6WP+ZCbTQp+UISbh72ks3Cp2BvjCozK5J85ewVuf8AC2Ic0vL18/CNn5bhf0ntL9VgcF84lZ4QzNaXFt+X2CBagsfAaxhmg
# DATA AO3GtMi6fEmk18t6T2GD4nfAB7wSZL1SG8sVQqH03hyLYD0SUkv/8NICXMmqbUu3KoaG8RywNNjy/0yqZO/+jqCVGDtZ1Ap8uQjr
# DATA /oLRdF1YG9L1/QLj/AAD/bdWvxwYeWjA/hstBODnjikfSrKl1q6gtzeoNm0gFBKm9wLrKdxPvCC7oqPtZeyu2LSH417avbc3wqIU
# DATA z1sa/7L3En0wpeBUIyfUJlhY59xUxIVq3nWlFl4j13gidAFFW2RJBahNsF5+ZlROlhkghPrGg6PT+EioNKnWJVxBleANYF4wRgFc
# DATA Ux3WTeil7yT5c09OvgcnjwPB+HS++U/G1R/07U5xo9D7HKm71OFpxZ7vuckJc1CX+AXKGxIHU3uvh2bW2nUX1Z7grAW8jLkV4Xk+
# DATA d73rpA2zfYgXv3hzF3wXI9OQdIcml6NeUYhBd4bwmSCNtSBzVMeeo+iGs+rojB33w/P4w+2tzd3O+uajzqOtJ2sbm3CLkAYCMfKn
# DATA a5vrj20x/cbKNaDCplzYIgRHPfQmkbwRIY4GUqdWGwG8rOPQgkeN9aCL+nJWqvtyDfbyWntR7bw7Z0pMe/ZB5+mzDx5vPNRToRtC
# DATA D/BifImLhlflZ7k3JIccMy97rjYL7/BD1LWhTHeavswaAXQv46q5ZPCPAns1sHGE2SO4b7igziYmKVibQuYl2WtL46BnnmwbY2FS
# DATA 7EZRJHJkplLB6NKcXDc4Oh1mPafBkGeXFMvcL+rh5UrqjrJuPxELMifg88pHKXQQ9peucFq+zu16HjhVrYozdeEuNe/KwlF+oiFn
# DATA Shc+XBr8g0tOAa4dWTssdKgIRm0tvX0b8xfqq6CwLqs07Zd1kr2/2O6zv4fmJfyV4Fai70NOalxqqXAX0mSFPG11D9Bhmj2zRZTu
# DATA I2OuFkTLAzskUi4ctbnOC5OqUO2/XkfQRmMGLjuhxODNF1QPGRnbkbQlkTbQSNNUBjqIDk7V4kM6m45i30v67c0tst5Shy2Z2YKH
# DATA ZQsaA53ntIUV67Et4ryFKrBSjxRuuK17fGU/oIKf1+du/rBf3isBpTcxRJ7YHFvbqt6tKM+18b/C7NF2tMiKEbAHIv2DUiCYQ9q+
# DATA caQI7ptNIBW2oqm8yds1h97Jw5DM2baGPFQ2syP2Vd6O6xzzVUplLSFJrPHWOVWlfjKymqeUBY+tEsUeql34UFfZLjSCbp54h21z
# DATA Rz23GWy6egwyihepW9mkIDX0JyZEqhOvQt1HssbeuMGfemQLZ0J68Egv7VoMaei6x2BlGmeQflztnv5LReDwZ1LqThwwaai/HP/U
# DATA hR19fE8k8j7olGFIhMAa6JMifoGpiKPfzO+qIDhTkgyaqVVrlIgDXA71Kxj7Pj3jtkv5dUKRKejg6WlsKPaxY4bkXuEYUK/ikyvK
# DATA CPMqupq4UDZ7oRtZmSAgl3HfxjFzL6s9v+2X/sVtgbFeay/Q/0B4LrVqHerogatr41Y90IlA1O4LvMd7pn/RhP6RLIUB08MyN1Xs
# DATA St26T1cTu+cEd1rrYkg4n78YlaL7N6PHGEhPCJKznLN8E4BKnEfj2YEaUfRs+3FEMGWUvITj4QkWRs3wJMvz5mLaEYpzgKx6k2xA
# DATA STGGTAJ485J7VGmwH382B6WnNOVAmV6Xq/VAhYe9seItkj7KHaHrQrOS1teuP9lc+2Tte+sd0tOoqSNnzpD+A5dFN5I4QCSKMiw4
# DATA orKtziNC7Bbz96U9e/jLaueeYqF9Tx2+0JEKVAOX0tCUtlyAGT2HPkX1k6sC36BtdkmQpRDCkmF5ptISsKUggTUfFelPmJbbD/aL
# DATA /NqrDRkJ+D6ZaHcOjLId+yakMsCAQBvAmCOmw3HWn9gwUxaKCbfg1ZTxQRTnPmM6YCNZTT1g5iCfSzA/mMcNAzzqxGphUlwK1UpC
# DATA 86yHejpRNMHGMXoeTDJTFQUhesGaMvJYBm3OjVMkDHwORnH6YgYZ41WEwb/gbydsKlTMwCQRoj5DFGc57w89/Q5C3wKryrxTjhV9
# DATA dfVqkuu3UcpRekp15jamKMTK7xI/kjwc9uhb9bR5x8Tskshfbuwx+huho0tcuBE2o6HgjRPCoKvFDEXhPpoBsEbSNw+SZp2mGm7h
# DATA /HY/lNonD5Fl3nCFQFlwwh2bENZu1lCHdJLJaNdeNs7Nj4NZf9DjIGF1vUC1CpiDKxBgbtT24kaPcfl4msgFkqpE3yPUgd6gHEQu
# DATA fKk3QQVuWzZbQemNmHjaO6uKTtXZjdm1VXsX11AJ3SoCQlr87qbqRm0PgLSzV1l3Nk0PBhhkvBEHsbTB34qCqXFnmZaaY7XzEsyq
# DATA q9cBNeSNMdkIkUBBZ4BKQO4V9OauI1b4aDZt31pZYQUy5QYQHdwxf667SQAu46EhbfTkoSFDAaPXv4o+3t19utPQYTpvfhp0AbKB
# DATA hF9oDBYC6mXnon9ENQu4If1aHUQECsfLHNMlJe0B2ZLIuOzKXo50RzSJHM336ZYMR2KQ0TxDnVmvAdXSfZn90JMg2CjXp1N2Wx/q
# DATA NRA+3M8Cuyngem1BLBdmkgtaMCTjE0G57F2PzspvzwavxtomJ7TFFZuRhCh2bSKSKgx6mCMIx+Fzig9oRBSd5OCx8nfLBusA88zk
# DATA TZpynZM0gGsuuarmhlwFV5o42hcBC+LiXxQuDMZ115qXqYIAaBAPg1FdLNhpHoCKoHqbsyG6LJ30c7g2dUYvvOqKPiWu8EDV1AU0
# DATA EKMBeZ2wKEF13b8TwrClBDwBmF9xcKTvVGKBf21X50ogbiyLPd9t90QHxCOyrpM4xGRf7cIOKmkXJyyFVnHEwI7mNCkCAJyTpt3V
# DATA Stgbt0cuNolRts2jA0EhwJGnMKwWT6HbhMRr5gEIlSeHvr/IziQK7iVpsYVWFcE/Zh4XiV/ngDKtltd+5P+EziXAdf6Do5r/6k+r
# DATA vcgXsLX4gEoMLxdqiwtUqzJ1A9faPllY1M23kI/BwXnGOL6fzUN6bkYyKbX262EvIUDiN457jlnkygfGkb0uQ1tc5GHsAlvbUB9I
# DATA NiSPkPrZp9jA0ASFbWec9jWLLFhfkM3Zh3XCi6LCDv7NPAuCp+8hic4mOSnJ51S+7DaBE8tUlE7G98nn0K1htOdbJJSc7l3/m+RF
# DATA UksC6R3Z3j9lDfO5nvKWtwL1SM4BR1cghxePk6ZwZVdfqDmVJQEmVZa4KNwkFj/sOuUl3d0NxFdglp3NKhox9/4gU9S9QpmqbqQ8
# DATA m5zBYQhJybVHQ9Vd0xfqMAEoik1B8Y/FIi38YdcCIFxUUyG2NJkzNVb+IsOelLvqroH/slW9XR1GGnXrKWhtXMdZR9zcZzxHKQ6W
# DATA N+1TtFBJqt6TMwsjrhgEvQI5mP6/4quI39qZZINMEV6PWYUGp7Uu2gjpyPAuOlHLZfTB7iY+otFFEGGOtZ/miBbJTKsMF451nCFo
# DATA hVJUPxSf5IcOxoL7mTG/lwPFUU3+SI3Cy5tYv1ywWkqIhQp02c8Si2XZ3Jha0HOCf1xhqtxP326ydF3vbLrmn7MqcbsMUW5BbWRA
# DATA vjBu8G3t69sK3pYZjQ7CbvAGrO/EjvoNM/KgEQH1v1id/ENmLYWcr1o/vJxNu8tYatm6z2OZtJeOp4z/5znWh++HC2obSnNVOcpQ
# DATA k7CKUw7gj5pgTzKy2chOLF0l72oeSb3gKhug2DR2cI0DN9DCehc1QXEyL95e64oK0T+Ls41FdUsFhmalIiPt+SQ3KBeFRB7hf76g
# DATA 5qpQU2eQno1mGMDicPIir1nwQBb4TSlrD15IYFmWFlsKFss/UN+v45+KFIsrq6OqdG+yJsWMoeUL5Zh5S8gxk9usDODDHr1WELTT
# DATA W5AQXqEHA2JgQgpIQslCLkXvBqQH9YJez9Td5Im+lCzimEm+hnVGNnmSjuUdZB4mYmIyvVHiX1TsEzlpLaIP4uuiWbZ9zycypC9y
# DATA 9Kit4pZOlaCJ1Nh2Rl74kgrlt2Vx1wyL02HNwa44eRq8OnUSn/AYaUlFahUn/MTlDupBLV5Ox/1lAD9eJmjOmGzh0Abti2UNIjQG
# DATA yAfyaxfJVJto7OrQ25r3Dvnex2rGB+rduQb67WVpjxGqcWpPRmoiRsN+twYK89WbBNdyegzIzIUC983nrfL015T8D7tE2c3QS0tb
# DATA fu5gHkDFrtTMhbJNi8A2f2Vc4c34N5QI22LVCs4GaoLDHx2MemcuGq/uKWrCapCck3N0wmyV4z972OlQrwAICLylvadbg8NbVXrP
# DATA luRd288fj9TxWQMHIzDs1DFIsgIvmnQvVk2D2jZQkqFl6+cmqw45D+vcoD+FfKO/JaQLiGf9HUbL/RI0cQHB3lsD5kEySXAT7HBV
# DATA aiJCDCd0BCX6TrJiFip0rVKMUZWKIKdQnEfPnm08avpyIadiRX8rRYeo/S6H3t1euZ1UkYXFN1940LWtHU54LtOgO1OhhiGzAlub
# DATA cG5DWfBI5oMsG9duMqMMq07RvhlxJONvvfhkCmPWylJezZ+8/kf19396/SWbQgF3kiBLQmlxi+GSvzaZKTQYP5kt38L8eU3IOfP1
# DATA 6/+rDb/+5Zu/gqBPP3cGjC4O6GiLnK5c7jLW2K9N8OrnY8AIqKWTo9xm/IJfQF85/3Nb66hjT/WMnzXJHoV/OjpffAJaSRsSFKhY
# DATA 9zIOdNxUX12FmTbH2kMbZMEqwPDTIGYuzNbWGiaqoZlDqD2T+2SSIwfVidSba5OjGWyfp/imJuTbdqfTG3U7nUR82QTPwJQ/qcWm
# DATA ZzE4OIzA76O9py1DxjCkYeul9V6b7sVoMOHu4cigY4UaVDdFAL+rI/Jy+ynlHFScXolxPWleDH9rJRWnu06OwHpIqK3ukpLAGkbq
# DATA tPUuGjtTXTlcDhsn1DNbdxnC7gJ1oW9Kcq+sDMPTcrGq2tRdXV9kY8juiXsmpgv4VC2FZ7/ToV5HWaOP4rnFJ4XdGnuGBbYaOInY
# DATA gt0AodIGPcDuR49cLIv/QOm8ljgUYzhywQhr3kEDkqu3MfBDIhmVeN3cZEZk2JkeF4EbcXoCCNzcXiT2aUSNVBA73UkJkNgHf1gG
# DATA VcdP6I7pjoF/0yLwD7568i8bJcYPDBqD/E3BwPhbIhsXEdYxI7A390k5qaMwNE0+JMmQpESQDwkLQSqtw+5wOnBYmGMT9uhtaVpi
# DATA 1BihCxhl6KrFimOrriScofjh9vrars5HvP3ok20/N3GdMiPZZnRi8MMeNiCT5ManMV4NoAVXAMLRNA/hRQ3+U+cnj7cefrez/qkr
# DATA drrcMhAOSrsEJfze7GScS8I/d9NoFQUkK8/BEzvNu/1+m/0pwRw1nLZvJsCA1MJ20HWu08H92unAfut0YuuHmvePhrMTXHD4Mx00
# DATA dzY+2l3fflKP7O+Pnz2VXlr0nP6pUQUmJd+Njrrmo2tff1rTlxNH0CGOKOWSmhRHjYz63eyMRNGAVE7i186ZosIn66/6U2Gv9XDR
# DATA MqqspgWkh+zAjvucW/LEuESHzb3+OyuqmsuIkVsLLhNB9705LnuI0vMTzKsO0u/nGhDkV5hm/QuE3PvGIv87SSc/OlBHZXz2ja/s
# DATA f5Cw/u7t2/iv+p/3761bt9+/q5/x8/ffv3v3G9HKN76G/83AQ1Y1+Y1/nf/75rXlWT5ZPugPl7Phy2h8pljH8NbS9evXt7O0p7Y4
# DATA bg91LV17ukFwRei/jJfVPJoeT0azo+NQzJAq31S1LDFZ16Kr/g2mFDhYcEh7U/1U3Vbxysg/1c3lWN0x9U8gfPrvUb6E/hVw91BF
# DATA NPcA4VIXmZjGFGHRf0Kb+m95g/WeOX11lVPm6azfoz4wjdB9wLuUImzqgqhoaXegBhQZEyJd+Mxtykj4atB89TRpgFn3rxjlyRgS
# DATA q/R76oXMeULeFsjzOKrG+mcvSY/G6nzGGEqqSG8+7fWHzX6eTqdntaJPmDuC+An5PUYinkdVO+mDVzaJj6MhpndKCa/4RH/filzh
# DATA j7vES9/kf2s0bCTLNHIirv3heDbVL830bo62M9IK+5pE0CXod6xQ5KFR+AW96XDxGojoeDlRjHoMGn6Qm07yIzX96jioLV+H5G6q
# DATA jbnzAw2b+tUfP8Dc8/fg4OBxOaToGlTpQESTHczauG972On0h/1pp8M9I33k6IXaCLEDVGL1q3RDNOFl0FfHn5nzO2ufwHNS9Brc
# DATA gAujSbLxaGBuclNeuwmvKSs0/amzQged5Lw5eqaepXYOUMQazaYyFXY9MnXrmuPweNptjeqAmnrbezPQ1ZvvN1fU/1uFwWIGYSgD
# DATA P1qt1fhikR5vZyejKdO6XF9iySGfljaNKDXxzs7H0XQ2hJHBYYASsYyoGRw2cS3xL1xQWkGT1XkZRFV84X7F+xC9vT5tfDianKaT
# DATA XtZrPJ2MwMEusssp36q/4J2dgQuaO5vUYYEJYrjwC7dDC+n3xQEFCdOeP3nsDCoDaghAV8zOr5D+TQuq7G/tBEZhwhgxL+CTOMYI
# DATA RxGpuMyuOzduyHm8cJBGzWK4e4HL7sVrlOzxRxwYDjq1DzJ1Y5sgTbOf+zllfd9S1NWX5iLkj2r+gWb3VvgY6SJMC62JuBLg26TJ
# DATA ZZPwOB5SEuLGLsOpuhP1qnF6eoo59xqmVcIzti0WZ9axTkPCbUWhYVtNIEiwdksAlsBJ/Wh9lw2Iq8kCXqFqoxR32LbYPTA/YKjC
# DATA rQMT2Ib/GLLdNuTbQQApqv3xlif2Nd0mkSFoM9DteXYgN9u1a4W5dVPbYIQppswSA9ivXFESPYj8b+cZSHziBSKc7g3kIFV3r8lR
# DATA VuLUxGzZSe5IPQm5zF7KLmJ8pkiCCBo0qgxj7nGSNXr7y6sZaNztm9+uR3dWbsJ/bsF/bl9gMb1h70c3w01L64WiIfqDpHT1C4Ha
# DATA 8xYGN3N0mPYHWa+FHCPSzqJ2EImM1QosRC1olqlHu7R5Q0aaisn7vc+K+mSYoZKSJ+YeWMrAR+BEFe1GT7d2dmFXoHedH8QGnVO3
# DATA u5MxhdRY+0MxV3MNg8cP1UafOgnddMr13rSpbywIRedVXYcC8OxHqvXmbNoNaW9KK+vnI0pwSpU1da75+PvAet9bWWmtrHgO9lRX
# DATA c/ojUL6Hw5RMc1xW10rftIMddnKyN9Ncl6j5pZu2z4ntL3dVdfr7wpQ2fJlNlByag79s/sNZ2gOZbjRNKfkjoGOk/SGp2o0bLdz8
# DATA HBbPuR2hFjIaa3FUoCvwXWaiZnU2GCA4dW0S7601vp82frTS+HansX9+q37r7kVMybTnyvDPtMjbG2XErA/7U5TeexbnO6J58Dbm
# DATA JFMfYnCNyPnaOUnHKKDQnQgElLWHuxvfW0fNurp5qbsT+MnEjzZ21j54vP4I5bD+ibpP4uPHG082dulp9moM5hN4uv7p041tejoa
# DATA do4pe5CtwuTzsXPHHhsGPN/2bu6MDF8MR6dDrReIdE1LhERxAoCEqp0eJk6mRWdvJMWNO1iAYMdWkrpXAj7rTCfp4WG/q8vIZV2J
# DATA 7repCfjj2ysr769++9s379x+//bKt7+9qm8tWAp7ECg0b3QbQ/TyjLgXau/O4Aabm0UEf9qjM5TNAiPrwO6ddnQxGkQ8HNHzOGnO
# DATA xmMlC1tILF2fuaFsbnW213cU9VVr+WjtM/jnk/X178K/T7Y2dz+GPz5bX9uWl5WyhcpVa6MJ+CRj85HtFrnJpBM4dBgwv1/oEXAB
# DATA bEhaK83obT/vmXo0mjd+Fh1k3RFE45uC8hhw7iLacXswk3t6S+7vy91qH2OHzO62Onm/8a3Nzsdbjx9B/Wd5pM/APTR0vaTjCnyt
# DATA x4pcc4ODPEzZqaUjlkCREdnQKMrJCKstoTS+n01GioGmwzyCsFA8sIylIUlFM1p/dZzOcnQU73Yp7cKJ+h1RAxEf8KZzwYXN/KDt
# DATA N2oOnJrNVd9dhOcZ95SlMJp8XIQDiXBhTKEKP2VqtkHnzLk/6S1yTe4Rz8XKX7JtPbc06RGmxtYf37PIMdHhbDrDpRqCGSqP0M/U
# DATA 6pXk9Tq0Va3RCrpdsYee5eCYQ0lblEAT/Ugt7j0lL0/VtZ66eJKeRarVIfGCdICgB1E+BoFf0470CL0vlxxWfG7ZVoudg/UW1ymu
# DATA DW1fgwuslTPoPNCrmPJOWBrEj7UB4qYido3Vm41bq7s3b7XufFv93/cLGBIx9/QxrOYHECap2mMS7rzb0YSjZSYWnASQhW0AfRym
# DATA gx3g64gFBOIqZs0DP6Ya8vskKaBcxcJyBS7HZiSKFDIwZRziXKR97nXSaVwQ0/b02zV0aizMnfhW5PLqI2aIbYGfxTJbyEwQ0zZ4
# DATA hNe4VBI11Jq+HEAEJM7a6AdkFM+P097oFCIkczEMW81lyPcYNDvd0aAlzgKLXKh1ZUQe0j7LdOL8nZK6MLlIXcfYQtxhzfaaDPv4
# DATA 85laONA71cRQtKbPDvCpfoIl5VC94nlui7qoCrpvmvXxfPrxG959QSu8ufSeroXc3GiUiZ9nIBBZWK3RNn2zakhX5Shyc9lZc1vQ
# DATA PXVPA11DZAgI9/FbKNuo2z6VgF+3bi7S56e6r0Yf64iqUkzlABb1J4qqk4xTsbmkk48SDRFOUcFUUFiqcM82R1FxC0vNrswfIqR+
# DATA B/mlXKttZVnh99NR7zXxSJoIVynUqRoGT/2511jd9/dJ5bVh9W797m24N6jmkkUWRsYZkxpX6/vSKD8GMxHsCNIZD7KjtHsWcA7l
# DATA CSwuT4xV4L7D4MjZQfH6VjeczbiUYbYevomBbWbYy3o8mm9GD83SREooUptliipK7agVZS/VGE6PM6r/BDU3yIFTAIECLyCQYPhC
# DATA jvdHokT9bNBDKdO5stmDUyQrLuVAaqpHa/llPcTAyjjXviGKDEFNvXJIEr/R80JWBL3NwM0QpBr9FvGw/fs2Tj5eWg24c5B9A3/C
# DATA 2uxrU68sUjDb2brV5PSPhsiOznM1s7QTXNVG7uQizMltAyG7zOEJMnFE57yQGwo4nu1h8KN9JFq6WzbuRpOfDjRaS8d95+qtyaR6
# DATA rrW6NdQ+QWAdBBigmXn54Kyh9w6GIzg0AUQyEyeVHmZgGLNmAgl0Yk2f0gfdWEmLed2FLkkti9qDHeIxNA6RXPMAjpYOMclRz4zy
# DATA Ith30LIDKXjJlgFzaXn06PAwz4SafKUerZIXhFupBtiaO1ffoRrbWnNIPxFQ6I9QuDNvqHqXsaGMGwa9wVeEmrkX4y83S5vzAjc3
# DATA flGMAYCCVoWDqDSQ5mExqorTz84HGoZUXebQEI0rdI+0gfphGiF6X6Tu3f1RL/ZC6MCrluFH97g3+8WQzKLKKSHMNN9MVN7vRzMy
# DATA lmQsilHTGMWXI44Z9MHkjfPiD7MhuE/WQv1I7tFc6LsL/Ej8TIpYAkOIcUncPh8oofiFzwqdCYFuimoehGopU6dorz89bFojy/lF
# DATA vdcK3QtXuo5V8B0UlN4ZGKdYp4Fe7A7ENvs3NahlHb5/zoNr6dPKG7dFfbhwKAYW0bhos6Hny45xaeQGOZuOZ9OyfHZl9mTyhjFd
# DATA Rm0ArMEB2JJVPQcj8KaB2uKSRMVO44qujQYvteHPlGU8CZmfvB6hj7MGrqpHPthE/1B8LweFvrXDs5p4q3gB1J8solJV41I3+Ajs
# DATA BGdwkXEmQAeN5c3usepQTRBZ0TXeTm3wlaDx05OO8XaQkq8o5nAksL8LdxsCmn34bGe3s/Z0o7O79d31TSCu2zpxI/pAkXk4MgnZ
# DATA tIq47VT1ZG37+x+sbXae7axvb649QfWL1pmmPSU8qRqMS49IRmfE+HB1T9d2dj7Z2n4kq9OfQJ/E5BinAv5pWAZIaIZnYF+Wsag5
# DATA Fqye0H/KO13LtHbBVnnkryATQOh2hyoivoBX/xzjZq0CLMi4+ixKNOgTgLKw7Hkv7nuShryMwDa08k+7rX2a6YsOVmgFH6o/ma8G
# DATA ps+pvL1R4XmBenoyy6dl+mqsrpig791iE2P/kPV28v6PBLBanSyVOQsLe1Zk1WwK26gIXhynZ2CorUvVrmt9CUwOP7T6Tu0trO9k
# DATA 6m4B1zLf6kvREe7qkownHtR1n4Tsv18AUDaVSflLw67pS4suZKpMFua9ghLgVBLsF1n6e/3DwwxhvuhGcA8bHak5A16iJF6PG6Nb
# DATA uUlezV3BY8FzH+vJVw/1nzKcpBUcrsCp1nZcdxhu6J12ca5H4MBR6u2M1eGmsl32DrgvUFDmbEyhFM3zjXZ7qHWP2obCJJqmNb4o
# DATA ZdASOdmyZToRMfUeJg3/UE9wo2Kuxpa/cy+0Ug/sSocsKLSicytkXIB0mPbO1EN1g8WYytnedb0g1ynB0UyjKkBxrdul9BRdJZ7Q
# DATA p3M+A0WdYtvTnJun7icXsewiKm/QK5DJBqXDUFW0jOHf5q4xPJnqmkfDnk4y1YOj46mxm0uOqO7rJDw3o220fER2GdzAld7krKOE
# DATA Hj8GIX6kVk89N4FwZJgnMlg8Om5ouwkqOVOEFcZMTp3xQ+lajMb86bE6JNC17+BOj9QHwObQvnAGCmu/Ww9hgw7KxwsxVKIzLH2A
# DATA Yp61w6DC3kelKC+4fkDTiL9sOhhEhuB1lxc1JAZgA6W8Qkwm9u9pM3aALJbTdYt0WE1rrUttAMUweKkrdbfyJKgS4YEOq6XIhWqY
# DATA lrl7M9zaN6M165sE9hUl/w5Git2yjikyWCTkgY6OxIDTMez2AQYacbKjAyWg9gZndAdsBhtyQpLfforD06yvvZp78esq5lV+lB/y
# DATA eEmbDeG+fdjfkwzO39ic8+nIzkcwnh22urGC2PTLxTGhWvoSXddV2zNTWXnIZW4+69a3fcWGupkdNpIdza8deKXQ3ithknoAfMb3
# DATA g+ySZeEAexTcO8DgWBnKLI6aKuWGOx+v3bxzd+fZkx30a6HUVhwG0cyPU/WyNvaQTY+zV73+ERxPVPNEyDzGlBdR/X4+jMkchBIw
# DATA 6uPFze1oMDqoxTeY9CeJy0OJIveYi/E0XectdH0fWJ3kjLKQeU7FtFubU4YeQgHLdfy1mMvo0gnqrMn8dS8S0416pRybnqnHYH1n
# DATA 0Yv5lJL86JiOenio4mD09ZUCr4thvCgPgUNt7Ec/3wsUF2Qn+E1JK+5VaqGWSHOwaAN4dWnA1UXHc6PnnJq0VE17e1Xd0EONoJRW
# DATA jIiWvl9ad2grE6/LuqPEkwbhkYVCmUM9OUMzQWngc/EDfRNq8E2o6msdyByMYYadtopacvcOCI/urKwI+UHHI9vJbkWr//0n/8sd
# DATA 8AOk+6axKQbudCZVCQeSzg3onBdnecm7iAjGRPfhP97Z2nyE8MulVxUiOFe7cZinhshg2gaSKlG+BL0Neek1hZlLEABsXknDgOyp
# DATA qmhzOJRqNimPHV1dMMTyX/T//NQYX3/85/u3VlZuuvGfq6urt279If7z9xv/uXU6jEZDJUxPEcSol0VHs3TSi9BecS96kWVjjHKC
# DATA A6Z4CKIIoF/KmfWBeqkOJBQPRoLiDY/TSokQTn5CSAQmLlMdxeFI/+iPOenc20eGHg+yV/bHbNofmF/T1MR62hwvJo40OxkDqVha
# DATA 2gUXw0in+QM9McG94WzFS9tbW7taU09goaZcA5HjDBxHsvRo/cO1Z493O1ufbK5vd/jLeHk0ntqP4qVnmxtejTkSpR7/W9ZAUyM/
# DATA JUsPtzZ3t7ced55ubwF4nlvb7PB0WWZ4a/b8GmGJJiPo8c7G7vpVa8lJYH+y9mkHPu988Nnu+g54M9oIF/MSnivZF8fe2V3/FCcm
# DATA jveeDfvT/aVHQgyz2nrcs6yGwsVYWoO7ZHuYTU9HkxfA2JvsytMDKPuJnqClD9Cjqn2ihJA+Wp653NIeJ8bbXwJm11Y3PcjptrT+
# DATA KuvugL9g2xwmPkhR1YovY68U0dUQqEvkC4ndBBbTVsLK0t4GAbjuL32SApP64CzQMTUXei3WP9z4FGZnz87EJswEBinuP4csqwPI
# DATA KqEfKS54AEvxfCilWcI26NEkmhKw9fN2LIxhN0DEcBMlYfSVg6ZJTgRuIif6Dnk0h2rBqecquukYfD07JJvSw4o8mdQ6/lfmadLS
# DATA PC+4EwViXDINLWn2xx2nJKaC6nen0j5jQy/gBtp/NcgQ0WUlQmhtfNHPO7g+3TSfuo9nmGsSbxr+rUZi2a1FXKzLobEbT6EeNX/D
# DATA bCpdcmLHTEmp36GtxCSXU0sKRj9ViRpMfowgL2rWDyb9nrow1iOMFcWn7RUTik4wkXoq8DfLxvA1WpTwEgmeDKbSJPpxdH7z5oVj
# DATA 2uU3D6K7t7XNEK4MtXGild99Sp9pROMx/OfunTu37tg7K9VSNWNa5wzsCEu7FmYeLnRk9ea3dE+qfb6aLfD6qq/eAaevA0rNewC9
# DATA 0ZUt0p9HSFb4E+2ZmZ70B+iZ3B/fxaDKuBWTF4LFzuyPY9fOeRif04cXUQ77NTrH4hfgRg6hrizGk2t5O6rF/f4hKgDOURsA1yvS
# DATA JchIUTEqsaR6gJSFKjJNoEzOL3V+cOPnBKtqN1NoeTEwwxYx67zIPBKdEq4DTJBwYqbdcdTDKs9t9abXiB9gW5X95nNzqGgn+WD0
# DATA 4XydIz+/iM7Pl8BXR9VzQtCt6gmOE4t1mFXciw4HqbrzMdG5F11cLEWYFpyvH1ANfaakBdBkHo9G+mqibh2jCbjZNVZX1FUVDP1n
# DATA 3O976iu9hNcHo+v8WD3tTg2eNE1ObzIaq+fntFdANy1m5Dw6t2t/ko7hilXnE5VcqN7aiu1X/9aO2bw95ym/kF3I0Hmlnx9nvbpO
# DATA 59vVxnwKrwBx0FRykk3TaHAbvUEV4X15t9Hvnqgzrv7z8i7NkurxsNcYZv2j44PRpJHDpIBHunyY9sCmic8matIz/QSGow6VmuIx
# DATA uYfcvHPnso07epfhJEvVYmKewXEK2W4a09GocdA/IjbT0P4nmEtarRX0RTWgPjhx5pbWyO6NQwrML9kd+u2c/bHATrjySp0zLbmQ
# DATA nVf/B3KGgXbsgt7VqMmYOQATWGLvbR26WYAoiRWl7ighdHP94e7G1ibF8LF/rkO6bSXowHSbIGjMQ/DjVZy11z+CD4U6ATqDXlOg
# DATA VnDLh7ClgA4isjA44inhJEY5LgdBTnE4Ssm5Cz2c9tSGo45C+XCCaoen4Il63nsvxkTHwcSZTmehkJ6JPdPbAhJredZJx2OQbR2a
# DATA bNtYL/TMwKGS7Eu5RpHlY9Aho/nTtsTwxElfrXabeRm8/KE3IXbl+tK1VtrJJDhxaduckhugGlRFug1v4igrWM42NtpUW5zVSYZu
# DATA WD83nAGt2efPDcx9k28A3I0mFW+yt5+Xwcn7nx7GCjIbMvltok0PdW08Y8x6DiaIfUilNnrx/l5r9aZeZS3JETMmKm2kNSPUUd5r
# DATA ZFlqFgdGFhFOGTi5w8MpxY8ShAd+QPObwQPkc1pyd0VcXVOTOoTB85jIpazaPHYrEh/6/H2bwJK0bSsdkpyASx6puqk6fUbTYZ5q
# DATA GlI7jHsZehMW2fVzgqkPdRzFc+b7INLglBkNqR5Oo4v/PcT/xnyJEe0nxS8qynJGP2Cjp/1hb3RaAxgJ/tt43K8hE+mZUateUkRP
# DATA dzCCIDj0uFejeqh428EIJSnQxQAmS8QnPupOUkXU86a5nVxt5YMLVlXdQit+tVUXJ0FN0uYoGp2Cpztpn/rgyIX3YbCBqhsjeWrp
# DATA K3Wu+F0f4EEBg7JyUnKcCm9KYiP5xIvND3oL2aUNRQSIMNFn46NJimcpohROPCZ0IABHMQ2ARIccnYSmOe3YSKeNa0rw5rLdWHNR
# DATA KCGbTESO5kLEvbRo+1ygvFC9ai1A8IIeunWThFshU8q6kuLpopOOke50KOYsVoxy7rcQfOAiDpO14ELJRtUsXa1FniP4c/XOCfVB
# DATA UwEJrc16Bfa0BXhR40eM0UpVrsPyYrSdHc4IOyXi8vp22aujanI0SdFBWKspmycvQDU4BstvG5siV2CEXDjsv2rHTdyLjRDEuId8
# DATA etiziKdQt4d4Cq3RmEnfYt4an17TQZoJp4RBqbBlLLw4YqYNzpwTOMop0IuTeZrvfHkh1wl7bQmdlBYQcTm7pb0qIvAeGoOuoNS0
# DATA y/p134xVD0FDg5rs5ulxX8mgsXrmImSoB6U5t2nQBX9v/Zy2TeE1BwZ6RdAlPPA10LEaCHadmRrDNbweKEksU7/mlMeI/D+KVkYr
# DATA N29Wzc+zIYQCRc8+/CQS66XrlaGH1JBOBSvMoOq6yEBcuhB1wyf/8LS509nY2V7/qKa/0n3F0ciHJQP2vyuO8S3GSUf8q9YJo5RN
# DATA och2ytBTBRS7lHjXn27yeHSmF2bAWMVXb3q5ecvqqOkgaNf/yr2LqW/ybgr6R5wQFAbjvZXGt0HTd+diWXGr5+BKQHUllRQYZpx7
# DATA gvk7ZsMTnh1yVMpDhNTRRXmwCMQlqEZNldkJVJKP96KY+5n4ub5q6lgTej8woNlYZ6sLrXn515CEZYGv0EfMTnoYyM5WK9LOW86+
# DATA aFscqo+rzkR8kfwUTgeLnas8/V/BCEpHEfaK8zYE78l3tOYyRwcb80x+Z7IWsKXgSjzQmAfBp+hk9DJzkJyuyqEYKbxlicHlTBWs
# DATA 9Cx44whDhfp182sxVCAF5WnyLRb//+PAZqAOVzK8wqynuhN19JpWUfx/aUzaf4fs6wFwr0uw7/AkzWOqwmtLsTgEe3O0j899jv+Q
# DATA mnnuMn1u3GX3T3Ep2ARVAz6ZNg7XGh82W8v77yWa8dcsA619p1W3v5LvJD5H9VcFezl3joqTU8lx/Z2kqQM2BhpVF0cP6BOJEPaj
# DATA a22mLXDnJgoCthP0dKRqbu5rNIk6eM3iF97pX3w0B9lgBOFa05HqyGh6jOFeqOOQIWaK5oIIF17P2ELqqqu4CTwLkF+Hcdyo7QUY
# DATA 276YGRS/9iBDrGV24F4TW1SZeDpCXjg8iw0rUv9NBMovejfIgzuX+eIwmBfxKNyU2nO4u8dpGQ5AB7t+ZYzXjNsZh9lZYZmQxleQ
# DATA TuZJV8XqS6ZqrvThYoegJ4q8YZtzga5ehVPSWrp0j7w5Poz3ztXMXVyWKLER3NxB0NJdYuwMSs4LLqTdjAvlRdPb3RO3ArPMEtgg
# DATA S4ezcWeMyZkJwVg76DtnF95pLysn9RwF7ZMCKT3IR4OZml4Cwmk22buAdD7TvIJpH2qGxD3Cr1owzdPjC4Es1VUbAZNhI5TUjQnE
# DATA 3uQZpcNjiQEMF/BzvyJgFbFL27a25sBj3jzPkPJ2czT9EDwMAyFEBZgoBsBDfv9487s1aMfw+jkEujAFLGSpWTD9vJBwUChjmYB8
# DATA OzN4OkBvNrGLKXtoesXCxkrIyuR03YgbOja2VmwNo+lklyi8zqnEzM33dj9NknCzfhWODPVoY9ud03AlhPvhVVQrSGNOTTBd+gFS
# DATA KRjZqnzKwpXrNZgkl15X5LxycUIrzMcVptY7qwjmTWeVYFW8DjkHtnDAA3wgnMUKG+AcVVubjz/zs1TZ35sfQE4phz5VnBsfSLsq
# DATA udXkIKTr5cML3+CpRc4C/xmOakm1/F264uIoRMGdv+juCGBlLrYjPGIn0PiN5F0j3xIHt529FaBosnDzD+VONHDsXg94ofBq0cMY
# DATA CnVbnh42vmUBlnlzdY/7g96ENw3vv0rOYlmy5CBFcYy7wJ4DuhnrS6D3To7HZ0LtY4yH4t8OUhzwDniIQFuFt9LtgxtJAPjU+ACX
# DATA hQ06s7qrJlJdDM6cZc0D62oGozkq9qzpJjMtTCJ+IWeRvuKr9uEIZGR9Mc+ZeQfanGQGRgB/O4utS/jigRJkfCRz1FIwaGCJZYGw
# DATA rS5jVDDc35oVnLxBbrfQKFkLbThwYA9vOD5TDjFFd/dlwnfLdLjk6t1b37pt4Wjgs4K479My6Nw47U9yTBefh+DchXMIg8LVNQbY
# DATA EH0zituS4eGoigV2osB8IisvOWIhHoKvfSVQP4CUcwAXC5B+BkM5cxN9k//06AByDHVw6B1wJGvjn84Rl/BwU8yiixBxi+wKMQrf
# DATA 8Vg94k2BpnoS/Wvw96QDGQntfkV7uXle1SwJ+gM1DLUT2eM5jxoN/JoSyjJU0CmlnwFNubP98FCLTjStZFzYlRY3KXEm2dvkS0K8
# DATA dIwNtGnRmwhb3Mb+oRIJfhY2q+uCqlUUWIvObbufGBS9ado97jDusRgRqmdhza8yv9tUHddeOcPFvcPtood8Eja2xHvkSb2/Z1E0
# DATA V+p3b17Efrertx0PW3/jLfo7WHBSrnQRl4GqXSZDf6z+4FZpT6BIBNHAUBgju1XXmvlxXJTmjM7OIXFUg0PVWFR7Nuyb+MgCqIVe
# DATA Ku6ADkjttaQOjJKzlGJulOlKRCl0aFRdpqLSyRFivRSrymVksO4E6aQW76DuUA34PFaPx+RWxC6Y+V7rJuIH7sVebNpBmh8/H7Lv
# DATA TtTIZs+HiE7n0FLYiFQNqOgQwxvkE4DIzrpRbDarKQPjohKgGUgCKXlpLMGJBVAKuNW0TX17d1oaW9bZEIiMhRYJiDhj5SF/bqtW
# DATA r4iWUSH4ry4Eioy8/4oDZMazYXc6I5iK7nE6ydvxvT/68f0HtST2agMTyzTLx+AziK2q6qEOrxS0kmGyA4yscm6q4DJVw2IM04dD
# DATA YTuJf+q5G/vg8Iol57lPuiiT6gNn2b7JeL7/BrUYhGkGv/+983vR+qHDownIXCnkJYQB3Ye0SqjU0M9MxRQfweC9/Cz3b5ql28Tb
# DATA KnzQLYm75E5jH0Dic4ZOqWvDIF/ml3hS+G9LuqnbeKra6lTx+zqTLwdgwTZnXAb2Yj+kDf3MNmKk/TVNCmeHpx0dzYYoUibnu+ku
# DATA PQXXLL8Hfk/RIkcmeqQE9Pfl5gvkH0oGhxH8DfjNoB26z/BvA667QMKpd+qITUuLolcmltXguDpxQWhaaVDDXgazKEZEV6bjPjrM
# DATA wdv7+JY3V8uFY8X5wGL7sANpUKTSgU/fA1uk/Bzfyc+gCK47frrn1OhDnVL5dnSzQjluxqxvL06NSbjCVb3AFcwQ1pkYT7XDsMdq
# DATA PAxYEmYcNFDdTJibGE5C7AEcLpD0ogrZDDZhHBUHg5KZ8xY6p07cblE/1HOMRDYZ5U8nMGsTXCXNF3FhCpd5PDFaRJcSXzrukydI
# DATA 66sTfqcTiHXpdWzlIeHWnFqndNBaUShVlIt9lGu1YB/NKAjGCBOmcUB3RoYjknqYiotB1GEcbUiIQsDrR8GGAKCcBX0jHPuh2Bop
# DATA jRfF3AjwGPrzEry1Xrkr6RBQ4zA6CvEt8LKuOxSz7eQpuhboFE+ZFyCjl3bPLV5AxpeCP7mFIGCzBgY2UZ7Gd8LRWIwTcsH33CT0
# DATA 18I1A1bPVjjPkiqSNcE8R84YHNWcXB4HYLJGTVGqO11IZ6QwvUSVdaAgaCoLeuc5W1ivlAUVJcN9cBBlYwjlesNmSTZkkkRbiZcC
# DATA YCeVcCOPELR7z3ZoROhq8VKwzlqo0rjy+CP3KBHM3O1u+sjAP3yWxSHCbtKJvyTd+b3NW+kWkEtscmAin6CLd95VMolWtCwVexme
# DATA OpcyIXDHPbDVMtkAh4nhyNtennqRrLG55jrC61CHzJ+MXgJsjtH8ElaXeMBBuQ6flxARdXCK0RffMWFftl0Fp2A22APoKzDeJHEU
# DATA Ly5Qv+2r0dD0p1nppjBtwxajPrcjCZ/AWTe5mLQdF8QhnBItDXmDrc1zEEySSlmLIwM5LxX7erPTiNhRZjhapoDvlnUG2l5fIOnG
# DATA RRVWcYa0f4q3kB5oiFhLLd7xd6UeCw7X0bF3Ykdi5gkP09h14vE1ZC7aJE1Dx/a/Fpf4P5V4GsRzL5KH8SW8EebWVvRWcGL/knJ/
# DATA X3CgMSzJDLhdmIQQWqO3ZwvrWiu4+rAvR8jTp8whKUkWwn309vhDzzVK7HLNCmi2l/G7yk1uVOc0Xo29mPt0b5AOS2meJop1QesW
# DATA IJhLOhLGT68o1MYFUZAbKjTpGFaMlQ8EWzamTEbjPuqWAB2nCXoTxHqr4U8NA9nsydRgYJdWQk6hVq5LuliGHQshiPys4XgFNsAr
# DATA sAnQxzH5fjRd9E/p9BdxJ4yP6jyXDvB90x585R4lDOXiw7rwn7X+2OaqbSAuAqFaqB9o+BkTN+mPCy4oIbVNme+JrQ1lTN0P8JGB
# DATA 2IxrEMYOJusx/IlaBiohEuk2KZgvmTctuApqtGw7O+RlOe+PL5oQ07ZUTEfukHQsXo9ur3z7rhyy4cyHsUE8ej40KEdPRzkjHWGE
# DATA vGooahxWIx25/ZKEtoiH4k+Yomp3PVwU7ZQFJH5SEYVY+04LAxF/zJAKSeTDqNigELXqF1GRAUwkwsjt27c4fDFihWl0fdJtdFNV
# DATA hRquV1tDFb/uUG4wyCna/DKd9FNcjdrcEEq1TbirPC8XkdufKp51GBsECExexfZdSmtbORK1UsXuY+7fjt1LcIr0fYm3u37pX7Uc
# DATA 8hGrdYk5FBtoU3K+WkfDkE4x7zdpJyywOQgUAijEvOPk9LDd9pbDSQYmm3UPoT8JjjK9H/QQwvMluTN2xKmoGESZNyG6WTHFPaoE
# DATA j1Axe0JFTwMMFpxeTtIJ8FHwRCb6gdwe+YLZYy3YWb4aIj9Wk9yl2O2DzEBRx5cQYg+VuABNEm+sMhRRf9Q21IGNw36BfAGD830E
# DATA qBzxQkSKE+4nOKvcE3ifiJyw8FlQcPVFFICci3zhpMwQd5wNxo6h0nF1sBpz3XsuX3ZxqdF710ISRHB8PvwKIByBGEDhwi67Xg2C
# DATA qDqD6msaXLCCS8AkOrUloYPDS1UyzQvetqizC6xxsE3hxeJIo6VC3tLSv/WQL6WQOhh1TUg4I1AedofTARlu1csOuxrq9uFZXHTJ
# DATA MUVNlqSi06Epw56HD7fX13a1o+H2o0+25zkhgpr8rlaTu87untOgbf/37THoum9e1nUQpgywzfXMST8zXKfmIa6g9Kuk5zBfnfVP
# DATA bfEzcBAKR7tDAD3YoJxpCytxOuR2r13sc9dDRD8Nmv6uEJ9XDvHBUST64Iio2byFLfUhkMcQGe+KUtdSUajHlZGZN+BDKXepq4YJ
# DATA e6ApUxSfgmxqIftKm7I1BgASL+Vlo308q9xrrmy3WarQbwttjtSuGfPRUuGVf329jAvUJVSubDbbHEmHsqKatShm3LMu+S/6itgW
# DATA vegctJVOvfryDrd+f42T4qSVnSffR+eeBtnbKwxtVFQrmyHATqW+7SdBOzZ+XLeJahY3EPqbtecb0GUqCt/boFo3Yt1+Q/xp3uap
# DATA 3kAVe6RqIiv3wltOYvlElk9moBdlrN/flSXz7YbN5TYso0ipF0Zguhp55p6geqksem9YiwmNujsdIGXu5xqFqqEEOlQuzsepFsKZ
# DATA AD2L46scVKn3AqfXJug2X2RneU1yyBDHKA0eDAwzVc0PG+peBQmf3MZtIIzqQW2erq7udSiYp8nmcZmcoBptKZB+iTEDS3LfyKxi
# DATA TURZ1zf6Gv5qrm9urW/u1iPza3f9ydPdz8yD9U83dnarEhqVk0o6AJ7ljRZQkXuKhDXOE4SCZVI26IReLgVl4DVA/9LRo5KF1w3a
# DATA AenoiQHYky9hqyvQBdR8gZxdiMFH6d8BJqm0AFDxQig+CrPeKynTzgEmIcmU5tJPq4q1UipYm+3VSwRr/Dtf9kezvBNwNw9ecmRU
# DATA OipVw6XM5KBC79xAhdpFwUB32XiZoUiYnPhL7X6BdTuvrLMMrnNJG9a7BQFJI+1WQt84tYOiqSCreX40Lto2JBczmKlLWoOJMJwO
# DATA Tnc5Rre7Mm8J8wgEDq0ThVtyPQqGYgCF2i9YELAaN667HMhsgR0rsA9GGJpzTjGoWKuPJiTjlSxQULF/2l+P8vVY82ABUcSPzHb2
# DATA kK8v8GsLA6k4VfgR0IG5x03V6cA8dDruqSr52Fklge99zmbSljHf5fkxnZ+W3mXCxt6KJPiZe95a7jDUa3tUWuKMXBQ6SSo6o4y7
# DATA Cu8slsyGepNfVYQg3FTpmBsI5C6wXG/NBbst3NXda6zRiiPwYxMjjEJwQ7zlKhM2LiydVFteRRi+7KIvwcpJ05SHEXlJGuVHZYCr
# DATA vrpaDX8PKUn5ACuFx3kLHqB0i+64kk8lVpKTFw5TwF0pORy+9xKNEXSskx0NxRgaNO47Hr/iIAhVoPUXMR/HXoPOO+pBwP+0wV6p
# DATA 9B3wmLgu3J7ND1QqYVxFfyoaMThO+xXdbnCjlUWQsDTG5MlTTBq3Uvmxuov5n0Jit3Dh/hCV2IUPqhooKGTKBupEIOlUb1Q2lO8N
# DATA M7Np9OK2WYLiNRy5P2XdJkK9d/MmpgDnXNxCAigL73GgikCGbJXnLYu3WZrx8ogEuiy3lYQVJ8lYBvvhl0IWciWCAkoIu/Bbkbo4
# DATA JL8v3p6WkfNOfJzXE5PPnELOFmgMrj7u6eJD53rnF5cXC5GPqNsHxy+YvqvUkc3TnszXoLwTLUpAh6F3ftORpUtE6KIndvKW7mDu
# DATA 3DHm0t7Kvpcu0PFSRohJbAl50oqp0CqAw1tGt1M8hQvuWI+MWtyOyptRGJnVt/kAevhh/xWEHqgeN2hRBdTGyxFA/INabhltlRPF
# DATA xvMo7U5GuUXQnljc8MJ99mu4Y+pmL30DvnLfYD6Epcsxli1q7XKsWx5uBlRUBo4s7UAMexS2AAV2EkkCYWfKPQpcB2HThLDXQhuY
# DATA eaPGIT7Uxa3RAKIp7WXIHDrUpkj+5J0Hc2ctZQJoYp9zPMIk8FJqB59AmkTzglpVBmubW70/EnG1xyAHhw6xvqySjLUWoaza6/HK
# DATA 6fhkZdV2PDFLUFDi8JajoXo3XNcZtx4OJqnAJAuWtw6Tl7vt4vNkzpZDAdfbaAL9u5TOa/eLBQn3u9vEpZpfezD9VagcxHz0srK5
# DATA KffLX0DzW3L+6Vbzrg/+PLVbiUaAxPDCnvYAZDE0AIsYZcp+kgh1Xfk8VexNFDnLLmbexpJZRQp8wlSxQNZnTvT8jT/871/x/9BL
# DATA C875V5T7eW7+59WV1fdX73j5n1duvn/nD/mfv47/+UmZ9e98ern8zF1QteTBbM3HaQ6JmM3P6cngknmb69HT2SR7CvgXJWmcs64S
# DATA p/Jg6uYz83imrheKLD5c2117vPVR5+na7sda1LIKd2uSjc3Z6CjRKx2MjsiHEFzFdB06Z/FNTlgs8xY/Wdvc+HB9Z9cmNgZHVXwF
# DATA JtTHa/T0Lj3CyDGd6vju7WJaZEiGIGpHs+vG5kfmG/XefaE/vHs70DlT6tH6U5yGby3t7KoedTbXnqAjZ9OkMyGGu/THW8+2N9ce
# DATA Bwo0RO4rLoyXmkBV5Ja4vf5wfePprilgazpIuy9mY65k6/Gjzs7usw8Akya+f603wk2GG+jBffhvNEiHR+3r2fD6g/uY3hGhULJp
# DATA +zpC5KmnGOT1gGMY7i/Tz/tj/QQuP9bD9f7y+MH9ZaweIhQ2Hq1v7m58uLG+TeEv3dHJuA+SAkIbaVwjhDW6/f7F8++rrfHx+qeB
# DATA soeIiX33NpXZ3fru+mZpqVs3qdT6p7vrmzsbW5s7CGLRhF5hxEo3zymjJ/2TvzzCf6evpvwYBeO4+YrLn2YH6qj2D5WwFV+o3d8d
# DATA pHke7ajJpguzvTsbvXauQ6Q6RRg1H0JtLnxaNXQaKydNb+JHz54+3ngIG/GPd7Y2O99d/8yx4YSB0lyQNO47zAQhMraCtj2hLyL8
# DATA tIOzacENhIHqgvCLXvjWAnhsHQHIpjM6SuQnvtDAyB9l4ul21p1huAOtU8CTozCPG5vfW3u88QhnUd1tkbLiN3p6kMR5aIJesL/N
# DATA gp04uQ8gRp8xB9Wv1W+huiZ+/hzDnvBFRceebe6sfbjeWdvZWd9FEhwnDraxJPQygxRcv8IQx3BpJ8zJaxrtUCMTGNBjgCe44wMF
# DATA zc0CvS8TQuNB/zbmg4Yqg7BG8AIm4ZxCTprN+IIi3SZTATTVDKeU9LpR+05LsdofjyfDH6ezVz8ezgY/VvRib1V168eD8RT/SFSh
# DATA 583mjeQ73Cu4bTc3ileyQ+6FCwWdmDC8fHZ42H+ltu8pXJO0RsMSoeQKKxrAjOz0RnjruPS+c5aV996D6OadWwscgUdbT9Y2NkP5
# DATA eAwxwxqbE8j3Psb1UatFh73fG6bqpz77ad7t99VvnqgyCLfLnFDdPXlGJUYa53Sn4VYlL+c9q7aEZE13Vy/0G9wlitVJm0t56BhM
# DATA NpS1pFunPGjGSZJcduKDNBpUtQVcWscH6x0AnutNDndgU1NT7bRjJ1lu2b6mkH67rf9HB0CH6ThSwtJUkU14AXbfKYm/8Kx/oKYy
# DATA R40FqNtf3V5ZmcOycYJ2PnvyeGPzu66HaBifvBpLfE5jclHWNh8q8Xpr2220NsrJkRJUHoiZR5aX8iaDjnqVyOtViOqLzNYn2xvo
# DATA l1UyBDtvbTFvwn80x6jDt59N7Mzm1m5Hfbj+UPXjs0t3BL0lrg7tvnAPVX3PHq9t43WnFJ29Q3YngYDNFERSGquILhxlc5A55vKG
# DATA PND7SSH1qz25YSVw5yR9kVkEfAvYj0hid+6UnxYkVLb6ArXC2nFQok47stDUuF2hAYpNgqasDo3VYnjTb8/Bb1LqoITzJYx/bn7P
# DATA oieSOqt2yfDYcnZU+A8yhc5hr00tUj3FleTx+Yj85RtAOPhQitu2B7GvyeMIPN2s5Y+IYuH1Bxuba+rgwMuQTbAjkPyxuURg6iuJ
# DATA I0tPArixJkSOSiyIrK+hW8WRs4/c+Df7fB5mvn8aUSvxeOPJxm4RJZ97W4aTnx5Os8nc0YXQ9NG92va5PxzVvSHI3ycQ6tAZErRs
# DATA DVs1X5lf9JH5ab6pEAlw/A8/Xtv8aP1REaC/JIbTOVMtbxObPLyOWVyzsGuGhbXcAEHXSitMieENjb8Mjfct2kuV+SeY9ujNW5Si
# DATA Q3cLyBmHwtfeasvDmdSY+7YNuLZg5ebAh+JCSyMgnfu6HAW2FBK4KuNPtXrgivy/DBr+MiIALbHt3KXDQQs0J5Bz+p3Q+4qsJaLd
# DATA ZH4kSwl9vpzNcu72KFom5RF251u8cY4DMSk6ZwXXkCDb4jUB3ZDWJNdCSqlxegZlgFsR4JZQVDtxoAUNdHXal0Vuo0TZuM4nGzs7
# DATA G5sfFe+kTncZ9qqt++0ryCz+xvMJ4Xa7WCgmK7FuFnRV8LvA4rAhCXqgE/iydoALuFDelLwPXyDgCT8F/jeHy+n7qzMnj9S/Eltb
# DATA FZ+kA0wxCm3sCYhfgwDOaDqAqIEWWjCrkKtojb/ncxlnL9NBnFQAb9pqmgej3lkdq3o4wtcExYmpQLxiTTc1iOK272DowN94LDyK
# DATA DnTfb9vLszie1OBDAvmkz95BXybpKWa5fzU1Ghupng0rWXfOhtP0VVC3qviwmsbLq1kDfQzoc1Cdk54mjDfgHOFFz6YUvFjoIlU3
# DATA VFyiUCN9NGb6wFORTVm4uga2hbx7nJ2k2v87J5Ul7iYotKff7/sZZty33sFaaKa0CDU6zVnJvsd92C8ZCRQV8LOOShreoUbasbBd
# DATA sUsBM4eqH++IqhkXlKXYR2+y1ROe634PY7TADEV++iZEANH2IBAV57/AtYpt7EFl+66a1JqspGpQl8Vi5pfV64Xa00pGr00wvXhZ
# DATA P/hpk5SnBtdXP4fNfpK+6p/MTsqA+iUqvwfIzxPONRljk64QtG81M52rSrYB9EJ3Vm/dXUn2k+QKxEbG7zKWH84eLVMVTDIHeJtN
# DATA AK9v6X1K4cZ6o1q772V6iB848cWDHiK2wXZzw45JXhERSIRXE4xBIquQC9unR6geNrtK/oKmIP5uqBvl8Ynhc2N2o8TPX62soFpW
# DATA 94N3Cf/0iXcyB5Hl8hOksfnOz0krfXHhdEcL9jhKYalBs2uyqExPVXcU4Xm4/vHW40fr2x0A11z/dNfrCc0cRJjUvHl1VZkxYuhT
# DATA L7RRhrYiTOrtldvhV0HqcR6nB6PZ1FiS8deyaOCi2ccEIBka8nmbLqSf217/d8/U5fKRklQ/Wt+x4qODv5Lz7vTC8sETbghejKAD
# DATA QnnZhG2a7es+0feRoWcsxG2rlXWkA7d1wk26GS80GhC31bo9frwBpq+i+dlQ0H0iCKXmDU/W13n0zhUJaxmqpoka+QBW8IfkQnIh
# DATA 7zZBgp46z/tWHYb+jMSM0OpWsODDhLX0EbDSujgidXS20JiGVE09+uFsNGV/3sSQhsKhsVHYmcDWq6BL7GopSaymUpxxg/eKsQHO
# DATA JxuuWzybsfRcEX+enVRVWP39FeS47fVNoAtSjAvtHVo+9D4y867mQi3RVCts6THIf2xV5WWWMpW3TQx2OtekCYcr0wSMLt/d3Ppk
# DATA kyirlqzczov9lu/p6vfN1jMGv7NhVyrChK6rHdB1LaajqFZf0T67jD4sqHcOai5QkQRDCikcgjHBVUobGY5LIntBaXMJbfYn23Kw
# DATA TljL+qcPH3/lam5W/UA4TImym5W/NGy8kPivDgez/FjIM2a+C3pjnkI6vz3HwYB3aE0EC7CHQTbMFQfpoFG/zYD9QIU6AAvDmbby
# DATA TO2CVC1T3q7FdSDKrTjRCWGSwq2T+6E+OOl3eTpkZ0pWDk7MaJJiDmnctcINUTja4VQ1ADoVfBmb8J/bivgfZ5xXiLeQqa3uz0hA
# DATA fVuheVv8+M1RE/LaaRYj+ldMtxoOVw99zUdbnPJ80u04Z1cdpHzaKTnOlho15avCuWWCSW2WGPo4GN+UMzuBXwSV/86Evzv7mwG6
# DATA q7S7iY7x7IXVluqkwd3PZPHkmE8aBYVLFjIJw+PyTMLGdjHJuureJzDSp6Mp6tQoSBMANTm9FjekbnIifxa/b7m3oAkElo+RTHKB
# DATA 5ng0riXehtdl3bAkh404NpY5nKqwglR/6YEp5Vn03VfKtTjzMjWqszaLzkCmXfHLT7bBIysOPZjRebG8z17+Z94YJv2z5+wMyidc
# DATA 4gdR0Ze5VerbFBbIdrfXi+ZM/0wBFjoOO1qmkeAChYdANiYqRanRg1mhw2FTmZKb+i8zzQb07850VGM8SAjrUnuvlpRNYLWjCy7m
# DATA 2/j/lFltwuAjdmC4oibpRGxDc+tm1En59/oo6+9ZSsJdACbm8Jfl0CcL2JxKDIICMNZztW8Q/WpVOtddcRNa6vhe2+lKaele/yjL
# DATA gVJz/EUzP05v3rlbK6//q3CGCMLOvIWDROh/l3CaKFnbd+hIcc1dHvRb0A/6wxEeQcePQX6hfiatub6Zi7gllJ9Dm7TS7XnlZ8Rw
# DATA zcfz+3jAofbSIeRE3VEhCf3duq0pme+KyuuDNbYWyvT6NhNkj05zNga3qho2PP8jO7MN0vMu8B0pqcwErX7Fi7+Y+01JR79275t3
# DATA OfoC+0GcOct5isPhPaCuVvRXTQbwBq/2pWLTJRwVWEL2SLa5xGkVGYtHSSL7Z3QsiBbjKlmMv7QEp3S8qEPAH5647pgbpb9dMdot
# DATA cZVDmHdE9Yr7Rnd97m7onel37YqWzBf9IWlSWROFylRURVk7G7xWd5uive1qtk/7GBvHhz5cGeIPhFKWe0Pcsx1fxMLnf1IILzEa
# DATA QizIE7GPs+Y+ChhzqAArZO3cF4Zg7FvOBwE7V2kbuBreeD9e/7Q4UCy3UAgC+abvWnWl1TyzfNQfRk6Hi4axkFEsYGPH6io7jyUu
# DATA ZYiUPV/A0RAYjiIPSioejM4AtiykNbRv1V3GxGk6EjBmiJlg2GVgAzderuoETq4iSeovqYqCX9I6kh8vhqEYF+G582aQIA/rwy1L
# DATA f1/WIghDjQuhFU+zCQIosv9HCUhymO188Gzns6Kfh3Orl7KtRBSqEqoDOrrQDEltxHAaB8AkKer5JH/ZnUwLb+kxBuQqmcXJTMGv
# DATA Hqud8cFjSOexuoiGrgBR5VwtFkmCoeZF/N78oLBY1UjWl1mkq2fa6Ki+IPR0bZAdQrxd/+h46jLa/CxvAiVWtObESdWjGOzsVZyE
# DATA k0ATQFX/gLXAFFDffPjo8WPOUzDLsw4G1gsoncPZkNE/zJbiKgjzUW2QdHpTbSsMqtKdNF9VZqV2GmimkyPsESa7p751OwjjaH6B
# DATA w0ZnLB7MeT1T7/fdVgATBmK8204lRf0ozD3eD+GPjtb16re0JvAa/+oElKi6xZpTAQrGrNKHF5TBsO5U45bCN7rYTUp1XZpjmMGu
# DATA e2J8atVoUa1xDgtAEKlBXN/5bMfArSNNM7+2nm5u7e48e/r0omIN6WDw4al10UUVNH+Kj5on1oSC8Pnk1AgKlnyqDgfMlKO91u/t
# DATA TtTMxZT31MLiTUgzHPanWAf1ytruxtYm6Vp2RP7ahQ9Z4IzMPVylp2fuCQqOZm1368nGw442ACt+23m2ufa9tY3H4AIu/Xi+luO2
# DATA 6JErHDtadlLM4J+Foyc3DBQTvzslhiNzFL0q5TFjR14+Z8VK3dJyr/Enqz4sqg2erDqOxVWde4wMwFMpg0ZbFgqVoWO2VGSxV9tP
# DATA ZN7imZNGAe80sj3pmnZlbvrr1NEmbu8TQzIItQOR8oR46Ro+jdsJEQoR3h+EIiRTg61M93I5iqm1PIa/jVAK1zmH3uj22qIS9H+k
# DATA 5yD2+5XnbFjQpa3HB79fMFj4g7WH3332FAFPq4KfKftMQVgPqwBGAL4IljpF7sBbDB2mxLcFS3RQNTBJT/U1u+SO4NwOLCKM5+pR
# DATA dfMvIvOLXL82XYaB67cOS91MSVrOBkon3WOwC7TK9A9cQPVVYspUaCTegU7BdtCoEOqMTfd16xIYL6egUuBLve0o1lDccWWIGNVg
# DATA DO61lg+x4yi1Jy/qRXWEnhCcsv1CrthaUDvApeerB7hgkiyuIaATG0tJxu4sewqcSzKFHvjbUBYuORzB0kkgkYXZsB4tAE9/ebqR
# DATA 3KWnRfKJYotV8vDEzJO6mHy5StViE4I/eCo8G48Q0lxQSOQE3Goy57ALLlKPpqMXmRIhR4NePRpmp4yrWGcWJTEi9DqESNuSzTpQ
# DATA 0nWKPhZNO2KeYBEWibiXvYQ5Fd+4Lxe6ldIcoz7ss53d9SdCBtTbw2lCbZaawMkCFyCcIuHW4AV4czUYab6y4kbjlK2kUOOEt7QJ
# DATA MgmWdGmw0VobItqKVjUdbVXSs3pB+JLErBWgZJoSt3DLFD+nvd+K3uYoyewmJBNp/qT3GTnLODw0Pj09pbAz2ISKbIV3KhRQLy4X
# DATA e8wM0Ztf3Bfqbz5CLC9xrhYQG+Ruh9wRgx5Pm5KnslP1Nxw4ZwqhzM47mEGvVr0ofLZjOtzwAP+4kHFTZjchb9autx7G3o3o5rwZ
# DATA NF9Ia7v213NWTgLekUNmEEKIZKLD/rCfH5fRM0cPyjcI4eWaHcDm96Uv3Dkyo+JRoYjjHIglQpRBZIxahKIUmg5qH12Kinybdj+P
# DATA JnGSHtAr3RFUk6gaAmHAnLyPytX11Pj6x8U60IbkbafiDc5QReNGtcdV1GnWk0C0Mt2IXEYjIw55ket2/xUSDOZ5MMfMvK1E1fxA
# DATA nZAh+sqV7lmpkuTiRfOffnFlCyBXUC85jm8vdhM5c+kYUy0mWHVBn4wkbsnJu5PJFzDbYWc9IRURH4tWLCqahGV3Mdh9jUwvd0FI
# DATA ci9eokPS9IICfRhDzpfwYRX265H5QYsQEPmDswWLt4BAj8VKLxG0yAvfIri4aTUYK+VBq1kqKXE6Yz1uXedlbhy722ubO2sPd22E
# DATA kQY+DxnE7aUGpdLS25N7deCKSPW5CN9wN+bSZYTRwKeC7VgR0XKWuVwvezVWoixGNYp9UMg/7Sw6Y7PTxRPOja7kLdels4h6ZN5F
# DATA pDuboA6r/VYyFNuJXmruBG06fK/Ov+3yJ9owCdmeoLzxJ8GkCeHpLFxDdffNfdKed5vaZoCbxc47vsGZaesOzFX707y6oi4lgxRE
# DATA Z6lKEKnSJcnd4YgBl1ARcF09M/dGsjEK1lLiJPTAk/4RBnC5R8v9dMk1ihfHRbUk1Zv+krd9e8aOMkeO08sLs07JrHgignYQcyPi
# DATA kcrbULiPV+inFRvdVuqRfwB8UTp8TOC+4Y2SP/B2dfnY7bYMXK+xq7bRgIyL8m1AGBU99YHgSsXRgqme2jd1uhv3Ep0UFKhePA8V
# DATA tKgePDI4Zpx3ud3mTLxYogoNz2WGEhiAJIHYwcW4CttmHm59b337MwgD//DxxsPdOKmiW2a4849XcVjFlSwuDtk6S0iWOe2mT5jp
# DATA iD+eSy0rB/x18kYucM0wHDelbzkXWwjnNMCb5qfj01FgVpaoPKKsjbClWf2ZlAo/0liH8+u3pHvA1zVpIfSXgi9953wHYaWRZp+h
# DATA vWv1O1F8lA2zCW5J9aE+J57ex3gqtozAZnwX5wgjF/qWrC7J0346oAhpfVodNxx+WB6HZlwywlFfl4lNNjqHy4Qn6w6+o1gvR02j
# DATA YywuH95F5g/DIDjMH1yuQoFbh/0JBpkMIRETl/D9JbSdH4uWp/31FsX/0iIiSlAMuDYWm672vi44yHihW9TcoqFbofCRtwRcLkLl
# DATA PiCboBNZco3cbXWWjGTBgRa0ec6Cg/Qk5rcQGMX6LUMWK6oKhYQt1iPH0FzWMWfsqNTTvwrKONPbehEcL3nbEYTChReJA6jyMQQg
# DATA tWzyMuTL60LwaZ2Bz1Rd2+JSyWSwkjIpVihCdJkZwJsZZIKPTedAx0YyKhgQOH5eBPYR4whYQ94dO/AZDj8znEuyDM56ypga4gbl
# DATA 42u044kimqMTjA/BmHMNDiAuatIEWYnEAdHjoHDkqgxtOhiNBgFXeN0JqxYzj8gLgLpmbtzBgACDFLKwPgogfNZ3DLCcXTPHYccx
# DATA uNmzYVU5ARdzvozZ0ouqrm34d0F7rWYlpLh2QtBpum2cC9cGv33JwBSqkiokYQqeTywlr/Ltcs+ogm2IMBKhx0KUc24iS8Je7bdK
# DATA skiZ+78OgHqZsfpnEWOV6ZT+zr+siEkOUu8FSAYhbBQohrl7BcO5JLkwvXMDZlyaIAqJ5/uSTIgi/Gz/wo/1kBvqyhtosU10KbVj
# DATA gA+ErhmBUYRVqOVi8+KdJ21dYP+SlEVTBG9BOXzuNFAW+ra377q01Rf7ykT6VQgPdf9z88YJ/yvtQOVWCd3z4RkjLzmTcZWprgB6
# DATA IrTtUb9LbsT9nvqwf9jPJmjKET8ZAUp3vzZ/k1i8TZBM4Ymort0u8vHEKjLzbKD1+rUF+b1Hb4j/c9K/Jg2xxiMlSDLDMtuCZeJX
# DATA +o1zc9c9CsJhXRoSSwJGOrhYuh2Bi2Vj+19kIEH4uD4F+3+Aw1Z6AfgyrO8mxEoiLx3FZYEjp+lEXXEw3hu6uRwV4DGYc1HBpo9R
# DATA IsGLsIRp2PdrtaBYt2+7/WWADoskd85juyExfhhCUJFVStl9lDUnR4PRQS2+ESfJRR2w+NqD9OSgl2Kxlp9JrK6zhFCkQEgT6yOk
# DATA DDNWexWddSqcoZz41ZbZpDaStaUl13DYM0c0tjTQn0fkyqA3HWXb/H1wUdY6u2NJzwuHUDpOPWaGSjx7FlHNBT17HDOE0dJcC3iA
# DATA LBpaLnXdl3Vj7Dj2SfGokE1QSk9M9XqxkBKDvAUJXMz3nKCwFfCrKxO+yjafI1sFxmSlKj1TUqjS6IaY+rt4FaOCdaM47NjWSm9f
# DATA QbD04tflXgaB4gvfmz5a31zfXhPm4q/06nTV24W14oseUanEi5vgoiIqRDaqQZ8X9I/QlWEQzqWiJ+JFLzbgWVR6j0ycK2NVubD/
# DATA UxVgj/ET6Dxd33zk4t1aa0aJDHwZxU3RcBHYsDi+BX0iuKaFxmn3d4AUsjmaxJxyi3vIEZHmxfMLccZrCmuDIPBt/Qy8ZalFPbC3
# DATA snUzPep1vHUJeurztZgan++FY+ORZBP+Irmv5WrpMfuXA6/HTntzpUkbjbUoC+NNY+2Mda8PxjffOfTVfI2+f0ulgKsQ8KbRuVh4
# DATA k1bilox1OlzODlmqDBAMusDaUP+nRNiXbh5LJS9O0BGK8qw31yZHM5jsp/imJoCe2/EGMfDoYDbsKTYeKfKXDiIgsppd5EgYR7Np
# DATA hPMGei3IiQB9zpsmoS7UDBjjnZQbq8WNhsRdA71k+6lRE5R9QdJmZRmBs6ImIVUzY5Sold/R7DUm5NS5WH9YAgL20qUJI2FiqjZO
# DATA dWswR1f4jLfNwh3U5LkhNpHmwwiwxt/hP/BljhsmCaaphtdN6Hjh/NMBLl750ZUCP+OOF5xy8KWTxdGa+9WbEHvxy2gxVP9mFXil
# DATA 3Y2HTdGydl7VWH44U53JI7E7kSgGp7Ju9r7ZCtALb58W5skROd0JqDuzVS+dBH4TVJUWrfjz59nO2WLz5U8Of5/aKexFs6G6m8FM
# DATA wpaBqme5oqolc+JYRIJzok0j+MOaJuQWqJqV8aSvjoQAXqamF0FeTgqsY2WeGSuAC1LowHmMJZip4N9w6S/2R8nFcM9tA85APlXX
# DATA +UmhQ6uK5JvjahLOgKrNJlkRkP3mpO4vha2oThUA5A8XV0Qf6nRQkdXpwGp0OuyFAF1T8u20hjxHTdg3Lv8/4Cq4/lp32ByffeMd
# DATA /29F/e/u7dv4r/qf8+/N1dVbt2+9r5/R89XV99+/841o5Rtfw/9mgB2hmv/Gv87/+bnXzq+Teup6a7V+HUWN66298+v93vXWdRTs
# DATA poo+qKNyvX4ds1Sox6//9s1P3vzF6y/e/NnrX77+1Zs/e/PTNz95/fPo9RfR69+pv3775k/VM/Xk9Zfw1+vPX/9WfSwEHqji/1Sv
# DATA /+n136vCPyn5qh6pf/9CtfCbN3+tirz+NbxSjaqiqspfQWvq/36lnv76zc9UN36q/v0b9SHVqIr/9s1fqZe/eP1FUzWPKqzrrfPr
# DATA OoeK6sT9a70RwkBg0osHz58P78Mf0UBJWO3nz69nQ/WfB/ePs7T34P5JNk0xQ1GeTeElas/wPb6BQwuPX/azU4BFUn9qDRo8Pu33
# DATA psftnpIqu1kDf9S1JaCRK2Eva6/auo6n03ED6PtL+PQh1dLYgbxl/elZ4+lo0O+eeQ2wENbIJ93oeZxng8Pn8b2Iptx/OD0bZN6z
# DATA /smR8wRd5Vr3otHBD9Ty86uhYlpQ+CDNs4bqi3gEoCwNErPs0+LsiE3g9X8tetnPZyj1TrOD0ehFhOlqlJR7dAx3kmPFSI5Hg16O
# DATA rHB6rCTjVLHFKD8BwZkuE5BQOQJtt3qu2NJJlKU5mCemI2CKzWhnOuud4bejSa8/BNglRpJVAh2I1CcACIm9xq3+4CmotkG8OQTv
# DATA kejH0b+b9bNp9HI0UKLf/WUqdB/9dSbZAIbR79LIVHcP4fdymqv9ki/D82b+8gjeoUwJZU9U9cvq4XuvTgbYqqwJVyk/zrJpqD5Y
# DATA gmY3zy/5Gdr59Ge0FAChXyjyAygBgn02eXB/mQqqP/AkwDGBdH+4RVAJBJ9LUoG1q8MyUFVin170x7I33wT2BYV21AtYHd4H95dT
# DATA Om3Qqvj+AC4WznCsaQ+qcVdF1TFMXyoZpZ82BukBTcsTkJvU4/5RypsPWiipb+tlNoFzjHWJUrnaP/0sN+V2xikc4Iif+8VhC5qy
# DATA 27AfT0eTF7g2WHRZ9YcnFQZMomEPPtXzc59TM9mpGIOtB74gyrT6YPc4VUs4BpnYBLSpLa7+VrLasKmqX31wf6yKZRF8q47HWXSc
# DATA vlR/jF6Cdhcy/x3jAYBUjvgaVgPFTNipo2akvlXXZnSHU5K4Om1TOGJnoxksHXysFVX66KpWxw/u9/ovbb+JNOT+zjiYTafegXGX
# DATA 4gMlZOpmDjJ17wW8XZ5orxYwD46GPXWqnfoWWbRl1VfY5zTbgWnnBzTpNx9sTaJxX3VsNlaTpEjL4UxNymg0gOm+CdP9MB10Z2iO
# DATA PByMUPrPUvLvjpDaR71JegoUB/z6YIbVepnNEfVGGS1lL5sCWqG6QSjZdQZnS3Uc7L4IXINARt2REtH7oASnWb/M/jPjXYYN9+D+
# DATA oRLlYSeO3ROldpecCtD60i0B6rW5o1R9quADvfZOV2wiMvhmDSn7H6Un43sgr79Mu2fQoej//afoUv2nVdO9XgaiBOeJebli+rbZ
# DATA P3D7P3D7edyetuUVmPw75vFXY/HzOfz/QAz+HfP3hdj75bj718LcaUfK4RuG/i/nBCHBn887FaUf5ZnmoGuabZI6T7WI3F3zTzlk
# DATA kGtSO8zRIQdAqrGrbYVqFV4inoJuf4LMFxV43kTg9KBIo1lwjuq0QZZOEMr/RDFttbMGdWTAahD9k6wXHcz6gymMAOhjTkNWPX2W
# DATA wycoben+6RFAC5ajd7U8kPsCAYkDo+HgrBltTLUM14U838DxYeIU20JNszVra1Eg7QGHQfUidhEWpYFiAZz1PEcco2gny15EP1R7
# DATA BZy1tHHhOBuMUVcFnYzSw0NYJRBI0sNsemZG+NloNrE8moemJJ08msyGRtQ8AGenbNKM1jnREEwpjGM2BmkF5Ey9C2GP5yjDqAKQ
# DATA QmEEQpIiDzmUSQdn034XpRs1tmwyBRv/kRpCCv4X2rUN6uoeZ90XqPJE0w6qPZ3O/Pef/G85jxW0vOgXlHdHY1UPypNizZrRQ1j/
# DATA CO3yiHihBnb2/7H3rk2OHGd+71cph1bLbhHAoAr3bs7Iw5tEL0nRHEoMh6gXBaDQKA2AAquA7mnNToQuuys7tHHk8Ik4G+EI2+GI
# DATA c95TWtGmKYmKsL9A91fYT3Ke//NkZmUVLo3u6e65pUSygUJVVt7zyScz/z+kXIWFJxDVY7wimlJJjXSg7HGlth7G1BdNogrbgaCY
# DATA wFCWvJ3lMac2seDCpmfoDpMjHh8MUBVrfu/t5GQmZh4yUnaWDajGYMdaKWpST+WWDEY4RZVaOXq4QSQVfZxkUrTYU5iyif8wiuZ5
# DATA ow4HA9j+kwSNYTDg60cIKIZCIoSXODNp9EA4Wc37MOH7llxqdHuUcpEhL02LQqBzRHgc6U6Cqs8H6G3ihSSBgrabC+XYkio3V3PV
# DATA WnWrjB6RsYgknlBgJitGPHkpFOR7FGOzcSmDuAd24w2lg/FwvIRKKI31udJhiCjWvDfR+cjeAxRJinExor5FVVd6D85v8W9SpZS1
# DATA f+Vpzm6DzU4znB3N5Fsz9q9i61+DqV80msje/87jfvKIzJefAV/T51papStP8NBjsniSyaTaj2guHCfpQTaloMdPEO7jaZhSbTio
# DATA H2KF4yiF6+fgOEz3qtV5OI/S/cNBMqFH5BLZZfuH6L8O/M780R2/1m558gvC2j/ELnPq8k+qJ2k4P+hTDXxYpbQNn4SPJZh4Rg0k
# DATA XhxC27+6xNZRsvWiajIaUYIOakEQTZ+EB2OE85jvGYIFwo2kSpV/8HBGbfcgmD96IpWkEs/my0VF9m9V8ATGmsccRfUufWdN/j4e
# DATA xhkNw6f0M796NIkeHdJocTSr8pa/g0EETPThT6l1xqPTqmpf+jLNT8lowbh60GzOHx3OxTg4oJygPtPzaz7+HkoJHPjzR15GU5qh
# DATA Z+XfSkaj85gtijlN6dWXVWmm4TBeZupn+VKhGEh5VE8kTu1W/ZCmUhmFM0+Yd31YysYDTGBUntRME9O5k195bEWTuqlZJjumVqqD
# DATA CurHbKFiL3cWDe9i0fknj1cSysm3A5AqpoI4oJLBqDJ8nMzDAc0GD2qtlk6NmgNS5RiRgZBVyR6MMQKpR4sXuVKUrkkVKV3UFaZ8
# DATA 73JKzeK0ePUxNW3UmINGqVD5Lqr78rOuy1Q0TyQe1F/v/ZinSDyMU6v8yb51EUWZ/GR/pQ7zTPrAr9e/Xah0bap0G2oXXr+/ezvO
# DATA qy5qbq1jVVxd2Ro6EaX4V6yLEn8V3YCa5qGKKn+WSlxd7USo2VWzcUpfDupPCsGRrf6Txzpy9ScmQ6xc8Lt1CpsqW/yz6IAtJxqm
# DATA nvD8yLTvozQeHh5RN1RrcMoKzaRel7trnCTzzKbOgIPpIJRy+7dDbVKoI1AXqPwfby0jnTq/FrR0qJKBFK/oiEbxx3bAnXrdPFL3
# DATA ak165MnYr4yDyrhRmasuvLpI5vT42JfeT16H+RXMZAmoAtIyxrvpfC+oNfHqSrvWOj6ptGr4sk89er2pYqryZP9wQpYQVQm4XREB
# DATA +ZW6BCZrVKq1eqNFjx5Ow0cqDX57MD5Ukeon1D6nlNAGRzrYLXK+dKeVBkUt4IxH1PzuBVGjuAQtZGfx3fzmhryZXuKpXKcQG+UA
# DATA i09yy3iCDNZJa3cG4yfx9KiSHR+ZWsMktEOrvaoKEi4XyROZE1d4n4GM6KqpABfnB3WqyBVMmPbwpFf12ujTTURkkLJDurCulgcu
# DATA dpfT2L84iaIZ12S/1ipVZb/eMt2KybZ1NfdJjb0Xkpcdycum5GWwmpc614I6VYi14xDNJYoJ4n6BrQf8RxpeoIZW/vuE3SEX5kK5
# DATA nW56uxfKyKW8+ndhAv+kbHocGEvlsNQsn9TgDXoM8QS+cRQ/ioaHP6uyD4bSfYhGWfVRyocgblBOI6M3dNGmW0A6OWQZgh4jFDz5
# DATA pEYmTaI7x6owA9sou2KvR/8xe9bQ9y6ns+zAH6Ue/bupf+MGyuF7NbIc6DWcVu5itVmTF2mzRQ1B7h7FR8s0MoZkfnUQsjfUCqfW
# DATA DdK8fSJVtS6/Vk0lLq4L3dLzvrTRmjL4S1nTqufVmu9eX6fVw9whFaOwc2OyM5W675Xur2XHkl/kUWdYvIuyDiX3eIeyTKM5zQr3
# DATA GhWq51Qoe/UKlSx1G3mMntQGYTp8bI0s1qjT5qG+XAuzZTrCEe4L7Ivt5qi815sfYPZfHYzjyXA1mXxLDe7zSm26pEnpY9tA4CsU
# DATA EH63K09P8vAE2/Jta6C3tk2tN59b1Mk26d8G/duGaVUqJ66fhQJgn12xuWww1M0Ag0BKvaGk+WC2GEue7AWzfU+nZVNJBKtW25Oa
# DATA 8ZuW6zp1A5QsdBLmFk9ZA5KBZuDH0IpRHx8QInyV1iDX6aJt81XPHvw6dVyn9MSLXeooZabqcXT3UmglDLV5UoNvwVh7wU3WS7yJ
# DATA F3NWTUQ9ttTEfLtECwzWtkAOSzYDPi50VmLu2f28p+rcljqgUsbjR3PdjNJqCw3pjk7GfFgSvdUBTcq4F9UxOqCkLE5NGnkkrMm2
# DATA 9YKNXWtpq1k1v0C6Fe2LXGNpN+3U1Q9xV5UXcNRbcj/mJH68g7lRmqNQz0HzpngQPbazpDwf081RNw8Zd2tSKDS9PLKMKBP1+g7D
# DATA hDzrhZhu0Hxwh0pSqBue+RbgG2y61QZhjynF/tqr72agFWPpza2BWf2U0eA+O3pc8htQAwmPyt4RMW231E1TQIFMItNinem2VyeV
# DATA G5pmPyzZtrolrYytJbug3IWLQaCC9GRSiEcOfGue5Te5p5SmkGd02XkzDLNxVMzgH4/j4TCa/aTQgP6V4AHD2eIJNbfHxg/2iE13
# DATA e26E+UH+vuYFTd/Oyu6mhl1yu4Wz0xO4oZ9gbURKeRRO48npwVtkYiU0Llc+e+39uK/3vn+QzJLPXqtM6Q+HW2zzlJdDGofjSWZl
# DATA U7B7fVS+lMclr1TZaVWy1/U7vcLslpuwmkRd1FwPi6MjxzhQE588xIY93K8zOncwAMtVvpvH0mp9Vh1oYXxVNxTcGjxT2c0/ST12
# DATA 7q0uzUQ3VIfaPJ5MqmlycrGVrWzqRTQ3pa670Wb+Ezpx0/6bqoNewIXH4ZVbwRP+SRccdZGTcJ6RVaI+2BNouwbywLwYVxZDmZZx
# DATA XhwgNoVxdKfKuNhmaz2pUQyix9yTSwd+4N+p+jw2Wj4iy2gQmyFZLubLBZ9IKGeWzKl4l34VyzZrrFkcTwsXSfpYD7vrbFmp0bqj
# DATA MxX6yb+eRsM43LNMtDZ1a/uPNzodbE9Do42+V3kViq1F2SSroxNXFjlFgemuZJNdZ3h+unH+WWqUDcxc7awszieN06XFfTXPjS5l
# DATA jGljdXN87Jevn0I2sNhQnCHumC0rBsPmaXkw0j7GlmWl6Afv2XMpu3oGJfNZm7Gr9aLZ4HrBeVjRVu7G+LBbRlwvPKr38sIpTCgC
# DATA cdOpqWZxeNg99TsnlzuRNfMf7sipKpl0z3lJM6um0XA5iIbVacLFIl+pdaxbE+PAv1P5zoFs+qAP4QjtJpzF09xllI/zh7woEq/5
# DATA RUdDTufotijNsKIXo8oOD7GPuTSV+WG5fGWlzuoV2ApQc8M+zU8fmtlG+aYnTworhnrXFnYI0h/v0XQy47VP7Ms7uHPn5OSkdtKo
# DATA JenRnaBer99RG7ywgejN5BFurHt1r92kf3jZFzXekw2A9J0vetKR5d9Tfs4P8HlEQxDvmWrUG8NmDxsf773BciW8W+gDv+35vXEj
# DATA OO5+P2ge+/Ux/bf7fb/9s8LDo2DUGDXkYUSxuCqa0QgZPX0iuzSRp8k8pyCZqP1tfGO+GYsqbv8Uv/C+uXx3ndr8ZK7ai84H+Y4e
# DATA swcgGvJa+KnZgGdlSa/uNZstr9FrekGrPmnUA8/vNqqNesfzm41ixgzbw35UX83VTsNrdBs/8jvtSRD41V7LC3x6vN49pr/vI+hW
# DATA PSgGFY1GPucxTxcecvq/1Wy16q0ov1g1Rd9YeSlC7frHzcCf1quB38Qrq70eR0ZFxPOlVlzxDUFQ94Kmf+wHjYnv+16r+6Og1/3Z
# DATA B81Gz2v4VH2C7sSvd6rNzo+CdreYvO6gF4XhSpCdFuVKb+wH9Wm1Xad/jvGxSZcbze7Y9+lyq0X/HNPHUsz77X69OVoX8+bGmqq2
# DATA L1JFPcDJwsfKE3ygavghz+8PVGM51FPbg2+1W+1+AxeM94ke4f8dGoNm9Upw8K3Ij1pR51D52A6+1eq1O53WoVgYB9/qjwbdAZ5g
# DATA tzP9PGw3guGhLO8ffPbag+goibwfvkfThU/CMdmelfu8fSyjrrCaRWmMZ3WXttPt6J5q2G1JJlPepR+INekFRadzVwwBc7sZjdT8
# DATA 5nsRtek4rEjQpaW5w7IjDMZZpVNrHp9UOuII44DVTrldpvdb/Vs0Uy2GWHaU22aeKpjVB7QPvThOFO6aF6xKMTn5Bow/gxg7iR5f
# DATA YnkgXwsQD2DJLBKnVf1yxo0HF215I0bRK1DfaMwWUltZSdpFxp3y7K3UMTYbbtJSebLa1n+Kpv7Za9i9R51EPFjwTvIZb4D0/gr6
# DATA Yt7de2YLZO3zZZSePuB9AUm6l+1b95qb76dpeFobpcl0b/1z9ycTetR6Vu3l+5voFNKL+hm08Bq2A1JseW7pve599tqBHcFpNMXp
# DATA bMGOfRDO9zhQwwpnOeOH0WnFG4WTCSr3vvcYB/7pvxKAyOTznrIHEgkQqd+jrN6zIvU6NMr2Dw1VmOkq9NLlZOJ919uTWNTGYYaX
# DATA 7dMldYWCkisHVgQOPBz9FC0CFts/9J7gqPJgTLFSb7hMiHj8iZ1qPlQvyVao2Mf68Uwe1z8cqrwopD/bkP6KxBu1ZHYUj041tspk
# DATA C7bYrEnLCIe7VyMZnu5h8rxviiKCQO1f7X322rfE8/vZaxQ0xIaiCRCtNdytTmfQjfh2WApynJxsDFOM0UuHOVtO9+Lhfp6aD5fT
# DATA fpTucZifQfSPfq3p3Cw8OlSbSPdEzg2Bi54Fvemz1/D1DjXneHaoj7nIGZfX8tgvU0T/hx+/X5Mdlz/g4yH0Hept3pvQ0PsxwvlJ
# DATA xXuMgJ+gMOTR0G5I8vQ7k4j1Mj57LeRsCGvY/QfNmnSCbzq+aE0UY1waTOLBQ2pT2Hr6STyNkuVib28fbRyRSqNjMirySFE44L6T
# DATA /aqyQqKC9Q1dCphN4OV2PiUzbGjeG82QcJQNHmAhvCmEPt45pki/r7RWKIxs2Z/GVJAVLzrmYrtHj/HHGlRj6O/bsjFrTxU1B0TT
# DATA cZoK/Qj0jnhxurdP4c9wwxMV1b9C9H4sBy7C4+gnFMkaPfhOOBjvqc2f/KIJGc1ZKGJ03LtQhPAV8fnxT9Qb/5X0gHHGf/f4Bnqj
# DATA fu7HP9GlRPmP3fHQ5dyX8OX6KStZ8v01GlUmy2GUqWjkHSL9Su8zm+QW97W0PUrY2vqGqD3gRrt3CrVO80yx8uOd36WK+UCSQx2M
# DATA fMZ5oyeHOqp7+eNryobrC96nk3MdWaU/75AdlAC5i4xqmtruHSMWYAff9dbefuD9uFbjz8PKujtMQZEFnCGZHA/uXq3ESKQLWYTe
# DATA LX/GZKvZh76cD/Vm8sIGfpXvb6pt7+v3uB/KMxIWb2nP1HZ2nAklg+I4qnELfyL/Fqu3WfAq1vHkUV7B+ZZMFxv9ZDLFPLy5COVh
# DATA KkMTCgoRgazYAJ+9tm4nnx0t/l0ixh8lAlwMEnxeH+R33RPLt3VVlE/e2HVUmSC5Rq5lv2yL9oGKy2eQ8JyS7SG1zURhU83ZkJ86
# DATA Aqr26K9k382OaDII08djM94z76WLpVqmW8uGenVoDlSsr1moNnm9UXVH5w/MVTNC8zfVk8sNNOrT3IqNMb5Ffy9399I03xMtU5P9
# DATA nMmsT8whf1dy0fvbv6VYo0JQ/zXdoz/J+8lJlL5FmbdnspgaQsbia/qVhafJSkLCuV7jxATdVz/0rAaBTC1WOrpgVw0WXYR4D123
# DATA O81ibPKayGnZ9/76r709HbW7d3VMECkOyFQBk29376qkoP7iFlnWozf/K46CNDf+uC9pef11KShl7GDlUGc/f8nNHXzblzvyYCU/
# DATA 0DvW8xFJKRVJGeIGE4j8tq/uKQ0fEhbXUo5hlPHAQSWvS3RNY+R2hLZoVQokx5Tj1gZceIhehDiqakqZrAPZL9Y43Kgsjr39u/fY
# DATA ZvzstXfNoTA0k9f3YPZ99po0PUr/d+Q7zwG5uS+Sd7Gtbi/Yfx0J/t+/r31G/5u9rWfJSbJgV6sXLjyfZiyvSwB82IwCoIfWv4eM
# DATA pzvFW/N3+fyu//NP1oM6Qjs8N5hK45YZYH4g0x3MdgezLzqY7Q5kv9QHsr3CdmN1Dvq5PqhtPGf8c+EE4MQ6vv1gzmp5GNniIWAj
# DATA +vR2fjtvK+Zzcs/Xee4X5VTjRcIttqOU4y8e53tvUE9bboZ6kQzRMCsVXVnvslbw5EI44W/Fg+rlxStp0oMEmStvOp0NdDSUH/ve
# DATA D1bWvthMJXugdPDfeoa/cDo4A+b3uGgPqNyhB0PlBXsoXZxiU7F5fi66Adk45BOxukZ5asMFTQv5OPKyT+OaB6+uhzkIhfk5x4N3
# DATA KcVJWvN+MI9mfM53xGf36SF1mJ8rq0dhjVHrqE56sg2BMUy4m94MxgIFNFO6ATsq73glH7fWEeDzxBxtshbIyD7CuTQjw/M3OOaM
# DATA CofT3Ux08D5aGnevN8NlVj+Sd8T003IOsyGrebCl+MeMTapkBCcPtZghLDXVbMhcTlgCYLRMyYpYrqohvJyHbU0Iznpz1ttF1lux
# DATA hjl9Haevc1mzbaOBeFO6Ow+whc2Sg8Br4NuEcJ5R4Hl2Gm/bhkvs7vNsubqCJcfrH2x/YFFEbcnR17iw0QmJHcs+AZ3Jygu4N91/
# DATA Q3yiugHOeD0KhSShmedMd5VfYa8Yb/+otXgTkdawpuTzhihcnIa836ilNpNEc959VJOe/Q7HsRRV8UKY6oBvO0RUP2XiaS6YaDZq
# DATA 7WuMpnhG6GftpeELb4ijVUVK32MiZR56I+EOP49cgDff8w+C+ht3EmUVlu9pqXtaW+7x6+om+pDfdUeilSdF2eo6N9UqGD2YN4OF
# DATA LXlEZgM/wYZEOqX38p5glU61GorRS1fN/JL0PPExv2hO4/RCcuCOBIH5k8otWae1Q8kv6R1q5so9y+AMMSGzOgBbmoqNRmn2S0oV
# DATA hF+MQfkBDYbUP4vRqL3WVvvHGBvNuOWzoWgG2jgVO7Lm3R8OPT4Tq8yCTA+fuQ3pvY81FKXqiYmAGWmXkE0XRy8bpWKIU4+DN2IX
# DATA Br1tvpxM+McllmFpUI9Tbfz/MItEeUdEbET3J+7HlMUiMa9FpHSdx4JtxlEgswSGBZvS6Ikwr4kzTAspSTPp/LTKFdvrEwjfW70c
# DATA xsB+xHqZnGncwUuRcGm8/FazPQA6w9kZzhcZziUDyVnOznLebg4/B4qVn9DbuHFkopkXDlVryM3mkmYjBhej88aKiA+jBRXo7Eik
# DATA 7YrSi8IES0YYtxIlAZkrJYoeYtlILvlnsV1RSkFtWXxj3GD9OS3krBs7xbghLjMjUgkLBvuUoLcYSnRZDDsZjbD9CzJ93Bdk3jg5
# DATA oZ89KiEZLjmva54yLiBpSbE7xriLfiYZccfAeW7JV4rPipNTHPQWIXsz76cYriZmpDMpspP2PjvlwgHZOBDSPKEeK08ZRt4qTxlk
# DATA QzSjTsNJxtvFYOkgiUdki2W6VxtS4Y2pN+NS4mTKKR8KYcai4nAjkul0JHMnMWK0vyyZktW4UOqCIayCh55WCtmSzrfDU+6JtycU
# DATA ZSiuSpSxTuMD5X8cRRElaxiPWNqPZncw1CBwiD2M2IdA1WohWzCYbky/oCniFzYBvU8Yw+MxXxABsmXFTFk4Bqkq6oQYi66/PJVK
# DATA fbpAfcYm0S2J/DjK1iRQzIpCFV4VVDVVnaxU9lueQBUelWyCJsijThqtM2JRpBVtR4LwFg5jnL2TgU7sVCUmSbX3Y+i/DCkTyS5k
# DATA 2w/Jh523JGOCn3goHlftUmZIGWr3VN4p9qSeSmup01GcTnlxZN3clhP1CeWNzMfB6J3jGCmZSUZtnVqQsZ7zxe9M/NdyP+UHV0cy
# DATA BdT0PMzEFubeyftAi3tS78qwBzalFYjb+JCp8Txk8xhTAzJ8qaTD5SJGtxGmrNM1VcqTrH4qHQq4UOI2JgsB19WUYmNq/2aWnEj9
# DATA RCuhJoI+EoKtOsFvJxz+AvsqkdvSFilBc7gSuGvksU3sEsuvgMZPpYwtDfHEwLVSni6kVNyUfWQjUYZJCqnIcUAaOzLCFQXZQjfM
# DATA U4TZaVlN1swnbFlZy84Xm/kltPafPKkYhs7iCHDe9NQm6Px/5786+8PZN2f/4+xLxcj58uzP9P8vzn/rnf0zmDb0w8/p39+uonP+
# DATA K/3wFd30Fe5n+M2fz39z9qVHX35nIDpfU6Bymb8CtPPL899UvPO/o+foGdwGes439KY/MsbnH+gHYer88eyr81/ryPyFbvmDgHoA
# DATA 23EsnRdgNoNOGceXqMPp059FQTT7KEoonDQeaBOs5r3zaD6R8XnCPWIkfUM2jufUW0wsb4TuHLGKOI9yn0E+F0omEzU+0Uu1zO9W
# DATA qA6WE1V4qqU4tE5xfqN7kNsG66wrmZvD6+RVx9wKky6/XH5gInrT5u735TuP6NdM2OFxTQ3ridrcisHUAXZ2LLbrR+xg7T1i6xOF
# DATA U8ldjGz8IvfgkMmiqGCYjmk84Xxkuf1sgZlqabeyRmoiCHMoJV6s8HUurn6bHZprWtazwuxcnAzH2XGWwE1YAhq4c0UD4BVxbt7a
# DATA 4H8jY/9OQ/9lR/7bGfileq7mQ87gef5a103AeKwcYBRP8dVr0rsK8qDXTedqJVEVHuVZipcq8E0kWZOpvKl4SgLbS8eni/GUQ5ED
# DATA JpxBuyJ4VJHlC5HUEU8YL7PESi1U0hfI7YXyz8oxuVF4nGBUUKwZHWO8QOAmPJzSg9piUOfqDnN7QYhF8P3AjDgJZwvbLTZI5o6x
# DATA 4xg7jrFzk4ydXUeVnaY5u1rJt2zyX8Xivw6D39F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2
# DATA HG3H0XYcbcfRdhxtx9F2HG3H0XYcbed5ou0ErfCqtJ3OqDUavEC0ndW1552YO5y7KvewK9Pjd7XbBYW0VrOU6812t8jNiaLuSIGN
# DATA cLiRojfgQBttlgEZcKiBBMNSGX6zXYT4NCjD16CROk2vGdQ90G38Vm/id+te0C5Re9p+q9Xtr5Jymg2v6fd+5Pea42b3OAhaU7/j
# DATA e/Uf+fXGuNk5bvjFKAyCYbPfX5OIVreeJ8IPeiYRjWIAQS8YtlaJPZSxXrMTjFUuWvQc88AKPad9BXoO11iLnkOVv0DPaTW74VXo
# DATA Oa1hNPJzek47aPudoaHnDLr90bCX03Pa7ZbfvXl6jqrjVa7GZlxoCEFHD7eFm9Y5qho8jlR6xyeVLltShTWm1mB8uDNpp/w25eC2
# DATA XVtiYqi7cLTgenA7doiruB010ewaYxVlfMg7OcbhMDk5qHvwbtQ9XZIFQA+369VXaLe7Mc07sn5SyPXSTYW1MhnOSzCcww37AVZH
# DATA K0VJWueplXXbLSGrrkYNbbqh5DWjaeJ3sStV9RmbKT6F0r7ARixknl2YKjF68gIrxFF2HGXHUXYcZcdRdhxlx1F2HGXHUXYcZcdR
# DATA dhxl59Wi7MQjsd+w7oEa/9j+JnXnrhox1cAlv1W4Lu4fPrEwPY8l35AZdzkYnDoywbxOTwC/89lrr6++Q1XqQz2gqJes3pjfog5o
# DATA 0F1s5x4qSNCHOMYlLZ9N+ckpn87Rby1Hqeb9O3UG3jqUxgfPUNZUoUwUqvoG+uG720b8a8oKYzObpPLiVG3xaJGnmXrHz1573zp5
# DATA Z5JB3aVKgUx0S+d83BF0dwR95yPoxQNh7iy6O4u+empwo97m83BGvVTHC63FFqdhzx8L0KIyZ7laihK+jYdRmBXQLXwiGsqWIBfx
# DATA SJNRdybnhLWSCm+lK52W3fUMOieB9RkxlrM4n5IEpVfBhToXPb4+yy4ifmsOg6pdVqv69cp2RRXkT0oNXgmH6x9zPXNzhbfbQv4z
# DATA 4nBM9OLMyurNKu/GIGZpdPlc1Hi37jDdp/3UikI7LEoc7kSHJvexuOsmQXfVpXJY31OfN98tx+tZ5Y4/bb6T+1wlMzuINt8n/Tan
# DATA nz9tEZWXg6Zazl3sUFvNHUPMFi33Qk2A/9yWdc1/gbeeuzo9D5BPOs/LeVYS22S3vukFxKrmmpcuOTf+5Z/+o0lHOeJW/s9ZohR9
# DATA ziSc5/qraimR96SlS0gkwEZLWIphBiV41qKGWmlMtZChTOF8TnWS9XWpY0bro0nsbCHH/6HHuoD+kdahZa1qXvzQIrMnVLnVYXHl
# DATA 87JbZn7yWTeN/GC1cZzhskqKyRl99JIusC+Yawrda4EAyqqtlyqivKJetoD+/r9vLiBd6aV43kMxUEXOdAF9cpJQG02pY/P0Kb9M
# DATA mSDUJy1n8ETSkDSvee/RKA8jZ5ociyAFpYEFByBscBRxt4oCkv3DqpwirW6hSuvpS8Wk4NbKxXQLly2Wf/yvm4tFdTFSKiIHOkhS
# DATA moyYljNTE2G5zNOcPmu6sq6yfPLmIRrWUEwHUfAdUR+enKgiKtqRLM3OZnFhHLQuxwsY0U9fSnaKbq2g8n750j3cbzeXlO7jpag+
# DATA DdOpx7u78i7uBNcEjjM8hhY2lcwRFQyvX6Cvi2S4nw1FSiNi9VjoTEczQHCkBNRsoB8xuSNeiCYHdsfaPzN14unLJ0/GrZXO04xA
# DATA /88/7z4CvYVBNkplSLB0wKdsV1O80ofK0uYmFU5YvTz0pksafyZhin1yc8gnI6O9H4nxqAYYMpHAMJBmgxJ/+pIoRPdFaCr/adem
# DATA 8iAZLbw+qn2I0sm7NYzxfcqiKbRsoBkzoJEHkwNWhA6HPw2xP0fV+AyFlbI9Hk/jCc4bIKegUkGW+ufLWNRqoILIwipSgFoR+hqa
# DATA SiEZVyqgohEoHk3bCDRXJLvvfZho36PWFOLZh/IJJqlQGTFAJ9yJ64JVwj9Pww56NcRdHJzbudKu4EpznrNXxHN2WV73c6HuWNh/
# DATA uR3bLXNuGkgX2KpJFuURO7U2krufUxXIF0g07SJtaHvf401QvFdbybWzvNfKiG4ieq+mXN1m1LHF+YJJUM3zjSQ2O5Mq4jsSNciT
# DATA xDgucieTovYph/AUUG4j85cXdMVbZoIvhSwgBYOdEZKErKyFvabWKH1urpO5nuaVtMA/hKdrdgRooADGRbfHSIFbyoIafKM0sw6M
# DATA nCjM6lxU1FYS9dhnQhbrQkoL8x5Y3x424kJv87hQH2Qzm2QWb1eFJuosb/CiXahzCzlce5WMRzsIZz4683Fn89Gua24d1q3DPqXV
# DATA uNFIvZl12A+E+2krRefEw2dDqrgNSjjv/UH14mODhWVO9VOO11a3rqwX5gtJ+fLYprVFe3nDXq3ZdH/J0V5aStj0VMH9W/Bpb3qi
# DATA 7KYsu1k3PVf2npW9ghtXTgulwJusEFNUp2E85PogC03ffUPLV6piUfeCXy57ToUlrs6ZatJ5eREch8w1f8+2qDzNvadO3bapxGWm
# DATA X70DRZw3FUxPCw3oxUWIY6FpwSTUOXr6TFmqycR+SzTX44nMONkEj/RMykAkqf2Y1aolmwoUGj2D597WHQn6Fnt49pRACE8AjMmu
# DATA nvoUlrj0PbLuOBTXMu8rp5hAuBsLNOqJO8lqweXzxvVO47yu5XsLwfHUfRSVdKmEL2aAvzxWsgUHZCmkZFpgA/5HBfH75uzP9O+f
# DATA zr4Chu8rD98Yy/cNWH9/PvsSUL5VOuB/P/sLE/9+r+7+6uxrj0GBvzv74/n/dfaHsy/Of0nP/lEF+rVCCH59/itco9++Of+5R19A
# DATA JBQQIMiEiIM8B2AhcwP/4mCAL4LVX+i7R9EJ2Q48iZ6HkK5VEAD06tMR5CP6kOzSGBDq+LAqe19hdZM+Mw9U99zXnZbus5dzfg2a
# DATA EIdHRsZA/CfRYjnfigC8D6kLb7jMsNmF2rMDABbsfd1L3Db/b7VYbo7+xxYWE1byWwv1rcwzvxOdRvM4ImtD3/+OuuBBZQgI7SS9
# DATA Zgwgq4cxEnq54PFfndGiJuZIgLsW4fWjAKmvwSI4tflZPEKnwzB4hjhju1yaPIKGTsRnl8WUh8GKWkid22CBLQxLlv6XHzO1+UTv
# DATA PdEVTVyqZIkz4wbTuPhotoIF3L1abrZ1Vhres4ID7p4YBwl0FsL1WQgaDXglw+DVcALemlFwAzbBTibBpS2C2zUIpIqWs8OYAc9N
# DATA q7oJJKCVarX8tSGKGi7G7ouHp95RGg6XoYL+ZfnqA2QMi2tsjBosLkqcyqZPLM0fs+sJa20si5jNowFGfmOK7QQHNOM6K3NTgjPZ
# DATA R0cZOAK+jCtgNRlVUTm5n6U6VPOgYovjs6FYDvDRMQFPxUGx1ZD8eUqXMl5LVaWtzDdZJOTI8o0m+2rehxEAcnJBNu09WMIMSZPl
# DATA 0dhbzqiYFnKGnV+cOYygwwg6jOANYgR3HoZ2miRd1qC+1TnCVaYI1zlDcFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRB
# DATA RxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXxuqIJRJxqO/CtSBf1uEDXDF4gqWF6B3okpWITn9ZoWPK9TN/C8
# DATA TjFfh4OoORytoe+1A5u+18zpe+3exrzNC2bq17te4Hc832963Y7Xa1X9VuD5TZ/Ki64GHa/bLWH5Ou1et99dh+UrRJn3Ya7Gl15o
# DATA IQ/9jolvqwiYrEftQWfN80EQ5M836jkysbvb8w15pcqvVpDn127PN1tW/BtWfu/4/lbXQj42G53Lvt9v2+Xt5/Fv7Bh/u75I2fLj
# DATA zd0eb3fs5Nuwxx2zXx5RyW/3Lvv+Yu7Vd3j9ZSCR0kg0JFL6MgsSOeiEw45fhESaRwwkMqg3+q1eARIZ9JuddiuHRA7qw/pwZCCR
# DATA zUG7223mkMiRP2x3RzcOiZyhP69mD0/zdQ45QnkcXcO6Q2C5OrTNxfaDea22CAumj7yMZjOY1q/Zw6Iy3A6mBu2ion1vhWLfqa2c
# DATA 3YiVhYjqRQ/FRZQS1PeoLHm8a67V2hbV0LOzRd3m6V0txbzRs1bsky84WktAxy07FNR+BElHNaMfptEBRC83UxpNPlRKyd1i+pUL
# DATA ubK1vNiZYopM7MGVaiLmU7BLTnEIjgLpKJCOAukokI4C6SiQjgLpKJCOAukokI4C6SiQrxgFchXiOA2P7sLUo14dZ8woyXfkqz7J
# DATA gkxQyMUPbEUBtKrX6WmqC+9iQ+Sev//6Z6/9n3+qMfHw/lqdAX5mT8IP53LYAG+kYPZNOAHC+d9fSDhvocXz8aVpOFuOQtbpl1Nd
# DATA ch6RmvNcjr7hUFUoyIXoEd3Ihz/JHMhoaCsQEgtndNzpe3f6/oLT92uOcLmz+O4s/tOcxd+ox3mjZ/RFETHhg8j5cW8ZVr5r9Dmf
# DATA vXzMbWh1ymgHGVUThREfkFVW5950uq8oibqFztgBkgv66SBMt2YuGEXLTquoJDmNZ7LuVVeqk7wKpPQmsd+Gf93MUzSDsl1VLhtv
# DATA KxATdfuaiX3QWhf5wIp6txDxeq21OepmvLejri+qerQ3jI7SiKbqF6TACsukwL5mUtBem/0NO/f9YEvmb1To1K0ENVo6iBdVndMa
# DATA cZmHSHem0pr1EfeC2Yd502J9k6FXxTiy3j/NG7l9A4vsi3y+FHeULaQrkScFz2iqRB4G39w/FZRjoV/SugOsX6FDo36EjEBlIGK+
# DATA NxezYRhj7sePQUOYJTVOwlMZeKQ4eezPtLDG0TKkEWcRRSwNroQtPqcOjswvHK1XoiBrYrSDgOfLd2C9NCo6y9pZ1hdY1iWjyVnV
# DATA zqouWNWb2UrPk/JVsRWEJr+M+NUPwd8zakdYxc61jlhPBi7xitFvEnRxNI2zOUvQeJ8Yugob76ybE8EzdxIxmbXi6T0bGJWiOZbx
# DATA U3oE9adsURcJjitiV+Y+GvrfjZX00ThJ458lRvJGKfiHXhaOwNeJUjKKWILJlEo2T3KFdJYoYtEoNYuIwuyUR95xMo0gysOzCbL7
# DATA KsLJECke3EujNQ2sMUwI7qwyyi2sIig1cGxV2DBlKNg2w0jH/X0I8xQ7QGydUKo94EHmHaKxiZazkA0bqlc17814lqAO0TMas6sN
# DATA gVn0aMGGJC+pIINUP5pkcFupHlaZQFIFpvwyCxS6zphYm7a/scEIk+RIp/BjnGiWcpNqVZizxViQhfpHnIsVGe6CSHhNTpVaPvf4
# DATA 2UOpafm4oTdFivxrxvqvI0i1cyK0IilDTxkX5vFZMOC2kb2LbFuiPhI5L2kV0amSzMJIPZ9yFyZpFFUwkZ/t5+XBDsDcOA0XRjAs
# DATA H48oL6jCUhplwqn0lCjLsMt1gv0lXJVxhCa1K/RpBt84x+YRBbAg4zAeggZb895OuEli+DPKZBCBUwbjCJ1fasVmhYDEltWFuq8m
# DATA Lv1QFfbSUtA36ymGSWquyCBxKhe0yL6anBWf5x+LUy+9OFWYVtV5CqT6s7wvY2KB1Nwcaq9k9p/qfb4hT0zCU4UOL5oqGfWE1/vO
# DATA gIdQxvUM46n0P9f7BmxTvPehHjuQpnk0G8ST630L7+F+R7cgvYRm96DX+76WACxGkdkzRA2PbckZtbbiu+4sJzfGoH355leOROum
# DATA VrtLBruJ1Es/kbosevb5khA2e3pvgmFazuxrJ5iuUTq+mF86KRAURAOY3ZBFXeEteN3nS0f5RZQQ3RG34BU2lmsjPJdblXwxk43a
# DATA yuQ4n/ZWvCMoNOdzGszCvBATYGy1MvPQAU2Bbf1YUW3FpClblGaluTeh5EnQ9rcI6BZqLVkvx9HFQtKok9NwrkEOO5XBmhL9KI3Y
# DATA o15Qw86iLNOswlfIdMsJV/3wYZQW8Fb/7exLUKfOf372Z8Wg+gNjrr44//eMq/pf3vnfAzN19rtVuNV/Bq2KgVTgWP38/B+9s9+f
# DATA /+bsL2dfnv+aAv2q4p39T7rlT/T9l/junX1jQgM1azPw6pfgWtF/HdPqRSDZUh3G83A2UAVjCeyQcc8yRJC1FfNIMIRrAnLlqnPC
# DATA nExcGjN2WnC/NFJgnqFcStDHyf5aYeRRz5Gxp2srwupNbKBFO4nQWTiAlW2ASidw2/SqconcHLsKktDD0nvXIqu4ipkb3+YKdzOw
# DATA Khr15mrTL2opNgknw/CU9xFS/XgYOWDVReV27ZyqN9EMuATmUYqzoqxYj+N4IwZsy+lLj2x3aJmoVRBrC55e74dY/lEaDeMI3mgw
# DATA CqhPjVJ4u/LlFNUvxjMyh5aSw950mUl/JmbYqVC9B/E8WqFY7VJTN9szpab3rOhVuyTCcaucFXBlK0Bjqq4w+L8SnqdbGvivfdzf
# DATA adjfddS/rUFfKmMx9WaQf1aN5SboU8UkeuNoMod1QoYHEMwmcnmC0/HpYjzFiqwk/UCGWgi944TLgj8ALY1skdVR6jBBM3qPDPzw
# DATA mMbJTGdHKtJmvPUAa7LpkrUUKf7T2HCBtrOn1O4IeJgiLFFHfKZLBmKO/YbBXFwclkHAeCIeCzIxIapo/8OCecH7APUmCoUC4pew
# DATA gAJQU/QP9lTAztNr5MtFAnmoAZO6HGDKAaYcYOrmAFMXjSM7zWV2N3Vv0Wq/itF+PTa7I0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmS
# DATA lCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmS1HNDkmo3mu2gc0WS1Gg0ag0HLxBJqrjyvBNHys6U
# DATA oO01Ot3Pq82q3+16fqtZDeoB/fU9n/5p9jz6WsyhQdTtN1qrPKhexwtAfWp4fr07rfoB/dNUX0sgKMrk+qC/DgTl9yRgSn9MA7dG
# DATA HzUs9FKj1baKXnGQBEpUBFdFzTBqRSsRbXZ8L+hSslue3wimjW7Vb7bUt5V4Rv3+aG08G6v1q97ymq3WuF33P/Cbgdfs+uOW1ouz
# DATA GFitZhCtC3K1xrabFNOG/6Nec1r3glaV/vG704BeQ8XSxedq0KUvqz+UXtrtthvBYMtLL4M6khaiUUfS2CzUUb/e8YNhEXU04v/Z
# DATA qCP6Go7qBdTRyB+O+n6OOur0KatCgzoahoNWr5WjjrrNVt1v3TjqiHeYVNn0sFlCKrLF2aePkdCT/1IztycDNtNIZgbbID88cuVv
# DATA 3oE+VHDCtY0TTpbeVgFFVtirDnkeYWXbHD0UPdwVTqQtjaAcgHeJ8XrLY9sH740QIqsEbV+gJyb05vSUCreDUu2ooi3mz+bkOJKQ
# DATA Iwk5kpAjCTmSkCMJOZKQIwk5kpAjCTmSkCMJvfIkoZHiCPHRK0pw5eTu6DtyaXw6lNVDwH7IuKlk5qcsZIuSr56aq6cR9cjqsqYP
# DATA vYtwmSA0ep1y6Ij5QJ9SDOXiSRFEpH5/QMHzz9nan9+bQRQJxgK9j+87XXvfJ8kinMj5Pr7rg3AxrrHfYG/0+snr2eun6mabM5Sf
# DATA ZHFHpd1R6eJRaetckzsw7Q5Mb5byew4OUuNM6iiv5uGpF+L3grz5gpVPpD6jBIxEOOpNBT9DNm8ySU62n/Wdxo/4+PE8TZKRPn8M
# DATA nXHTUGn8xVaUZRplT6FtTiNieoqkLChLkD593PK+ly3n6FSjoWrRcWbIR2TZKLBRSgMeaifk9CbxAos4CU0eMlbCFpDJIF1O+4fQ
# DATA holnfB47M4eqR3D2HvP53U/hwi0omKSs6S4K2tkgSfiJwXIOmW0517xNQfst2BDpqeyj83iIypM2gsg6VAARJJfqLIqGme7OJL3Z
# DATA IhVzmcpxnEyGfNYVMafE0hyY5cBRKiP8dkRRnpyyULjJNlN2oqzDMuk4la5V0TkNmMhNkgWSTpf6ycnECydZwgeDt0qEv0vVm5uO
# DATA HNumt0apVXgs2Nxna5OzS98cZ/oU/QnqIrpnFveZ4Hwv+vGax4rqeU8+wIaUCPLo8YRP5uJsfFbz3mK1Zq67ngbUoDpQ5BEqUhsO
# DATA sRGIwzLHEJWqf7i4SNSdc47jfEIDidEVxHZUnH/3cJQGL6OmE075dTTQcekoSfjBciGFi201c3UaWHTizXlvXJnEisKFavEzyNQz
# DATA HCcziuYPJTzxr3CIZBpO7CyJzXnuMJ1eTdf8TRGiRtZR47+0sDka4XUrm3+MzEfhjeCclt7pBgTNc7alCB6hKNgQ9XI9ghvQNDfK
# DATA jGzUzFTbQzeLMe8GJM7vc7dvbCWlJnF7SuAvz0HuPBA3o3AziuKMolyl3LTCTSt2nj5snH7c3LTiAbIix+FIdPSU4rnXBrwNRKk4
# DATA 0ugye768vaOLsJj6AdNhmQs5naN+FSBpfTPWM3ft0S3f11+8vW9fFFn7QRPhwsWc4tldF+dmy4pyb1eCKvsbmVAyWewQS3V7jnhV
# DATA 3wsm1UrU7MxsFAmpW6ImTk/6ueCV3CGS+kETS3Mht2trnYsiGmyL6EYQqsxfMVpZLe3FpaFKU4uzotiR0Sx9l/oWah3ekZmLV7x2
# DATA 99ueqbfelEzqzGs01T0n8E/TLJ8m0tFRio6Sn9LILEy/hZvFN3J3xF+VDpvMTA3kNGa12nhgujq8MXokayZ6yoBlMEzqEVZJyozl
# DATA uay+TAvYZsIqk6dlFQKT/nxaIrFTpw8irYK2A+X05bG9HX3H2d7bvfnO0H4pDe3LUnaesRAq7wDON8iuGqA2hIZFB0PtwTZ6oZKE
# DATA zRSaZyqf+kLICvJ/r5lpVBJ6vW6i0YpU7lqe0Q7itdY+6lzCFt8iCFcm4ahiCDpsZS2zsTKwSvUUO8WlZNVu8TfGjXvvpjHWbbBL
# DATA kb2IdAmM+vgRbBj2/st5LqYdxkVzhyaQmAVG65ZdlKqmCJmKPqk6yMBbuJTJUzRgaFpqeVSN1WKia8f7AdasEHOy70oxF9lds6hC
# DATA seP1C9MmRGNUL8soBimOk2F7trVaxPKpvPSEs4hbIoxmv2Ns+VjbLGH6L8f3AVaC1AKdnj5HRXHUsLiwx0smE7PqR3FU8EmsQGAR
# DATA bHNE6WXr8vWV0e60yEFkuA3A4bHYQf/p7MuzP559c/6Ls68A/Tn7w/lvGOoDetAvmOHzc/oNdKHfrsKDVh4++/P5b4Ab+sXZX85/
# DATA fvbF2e/px18zg+jrikefvjz7ukpPfIWgPb7nG7qH3iFooY0wIQodb/mC3kA3OqDQ829R/xD6ZbxOzL2JooWdVmRBEJeko1W7U9Po
# DATA CPxlLecsC/+qvprBPWXR5gJlmnrjrQyht8ahqBpYkuGOI2RZ16pLuG2S0LpyuTmaEG8IGCdzc+On6sJ6ptAozrvpd+OF8QRfM01I
# DATA oMZsL4ivyCL6vOocoV1K7NppQvc9Aa8DBF5dLPuRKXnx4MfYQzv1ZCd4zfsgoRowMyBEKsRj6L1D0gNrBKzhAbMsVJtdQnyeyKaP
# DATA FO7DKfMYxVnHxpfAGiESW4YHba+Sm42YNe3sWaGDtifBQYPcSH+ZkV5zgq44wL8arrPbGtxvZGzfaWi/3Mh+8wO7VMvVHMg3ut5e
# DATA a7kJUFCeMohoUQDZapwX8Lhhs6be/KfjuzRp50NOjBPRBQgCTMy/M98ES2BMW1FbQvkt03BGqctMuiW1JnjBDE3n1IXNFjthg2Bf
# DATA LXCQH/lAIY1S6u3yQT+W5X69sIVgWEyOIUaGAJRGklUGiXwqQOWKNdInwPwkI0EX40VUEb0HCyQ7Zo9HPPKoVT0UGsoJdRTYM4g2
# DATA yBsMUuSddog6epCjBzl60A3Sg3YbU3aEml9s896y8X4V2/1pTXfHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcO
# DATA cuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuyg54YdFNVH9VFwRXaQ320MWvUXiB20uu68Ez/oyCSZdxEWWTPDVjQc1Tex
# DATA Zu69MYhT2P8C9gkkIQrs02GRBpY38H1FGCrc3q43L7jd4vxQ2B7d49FvVb9Hf+v0b6/1fbo+8Xt1utb2Ar9J19rVTq8aNINxs/dB
# DATA AGBRpzvuNKd+o1VttsbtdTFpBpsirgBGd44KFagZ+IgMvWFa9b36sSB6tmRjNOr32usRSfWV6klxbgX1cbtZ/wCpbvZax836tFlv
# DATA Vpt1+lRGEPXCTr+9Lujg8jQgqfOaBiTNx6IBUTIGnUaRBuR3Gt1mz6YBBfVmtzUs0ICCbqvRDnMaUH80bA6HhgbUanT63SinAY1G
# DATA g1F3cNM0IGWUrHd86LSWbC01EmHjWnW7FeLRzRh28nvL4B8zUVo3KdJuNMx1K81ak/k/AfN/Vtej2sVIaePG6qbFduGEUI6HafUI
# DATA U2PwLOrD6Khirb3bn72gN39U+Vaj3uq0++z2269sDql3yaB0lLN5NLgslUjbvPAerphU1orc5sVxtRQuPuFqRj9Mo4NhmD7czB7K
# DATA c7hiR32zzVEye6UOse3kSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCjiT0ypKEFOnnE+tYV36eu3iOq4zhEW6QnPKmPNJ0IewI
# DATA QDMCnWcwrTHM561kygLoK4e8+XgblpJErSrEQZVkpo6vaUHa4kExaaMykdMnLdwZZ3fGuXDUxh11dkedr3jUeaP44M0cgX43Zq0L
# DATA PkvLLsjy6Vl9FPp5k9u4DT1uNbig6lB9VZLhSOXeYHqRRLN51nRY+RUj0txdq83dskWafb9elGlubZG65sEPki6q9+ILb4gta1SU
# DATA 5Z5c4Fo/9EbCnaktId3m5Z6Pqe9TeCGuJ2/cSZRI4Jon2pxdNLZ4d7xFGj1krcgLH2vxi2wzYAqDhuWTi8/ekdTsIFT9jq6fqLIe
# DATA quyLq1L9QRRmS4hG42DtIExzgeoHC5Hko54kSRZygxxrhqxPeASxZ/ijTmjMqnk/5MFtEh1TpUEHiE51qsLmZqzgNElqhIfShMzJ
# DATA mvcxLwCIaSQPsN6iEvaj4eQUBU0FES8K8tWAaRWO7cs5Ui9d4ow3jlyHOGAPDUcznkM/kCw2qrNc+BnNzpbZPBL9Q1bMDmfLEQbi
# DATA FHMpCRBcpGE8GuHKss966jHGaQqMsTvrbD0lQkBJWOwscP2ynPN18tbOfLXMV2evvhL26mW1rZ+xZA+va+cLsNu1re/TaMRGIxuQ
# DATA bMdmuRQFcxSyLRrXty3280LoXdyErPVqvb52aeu1mk5XlbfOF/21OSYWhbJ9IpBFuc7lotZs/pySSSNATV4KotfVvDdFN4hmSSJW
# DATA E4UzmCifQkRI5F4yDG6MGRWCI1c3mFFkdcVa+JlsuIRsHjLqHtIbNDHkchXnB1qIxag6GXf4q6V4UsgZZww5Y6jUpzpvnvPmFfvO
# DATA jVbUMxY0ZB4wwMXJZCI6+2Vgt2onYZZL+NW8d4XTzVbSOnm+gpbfPE0G0RA0bpGiS9LPl5H4cp6Gz30/NlBnQ+Nd0AiqmYDTeCGo
# DATA aRlJPdZy4RgsuZEfhcsjGjU/pmFY0wIrHICYJbLco/AO6DDC0QhOMXaV5C5PM06/N8N4vxB+7VLRIqJpPxpCBG0Y9VMakYWKzEMo
# DATA iwBih9JWlLWM/rk8o+CAQ6oK8IOypqAyDTJtXUA5Dv6aVJylSnyabIDhJOqHac17H/YTokmVlDI3VCCwYYgOBkiE/kSE18YsjLdO
# DATA yJA/ZpZqobhkM1CvP6eCj0fQeZtGWPuLB1th5GNWtebKM1vAg8NeZJPkTwHlSEYj74iGLJ1E2SfpTZaUqYMQio1cj4FXD0/CU3FM
# DATA 6XiqMsy0W4ezj8cBCkbFnPIlEwVu+JdYhftQyRpCCjPlkwWq4prqXABrLFB/mDfi9SkC0Uavs0o1jzQytkAmnPnguVA1BKdMyyIz
# DATA JqHExyCTsPxTPKGfK9oPxQnIYTuDME1PWbnxPuVZyH47FZAQ5gUepzk+xyFL8uWZ9GEUc6rET6zUL+GSO0qSoeVul7cm1NBoNBxJ
# DATA WysW4dVg32jLp6z6SH3Mdy8N+0bcrhv2LXZ5LA1c6RfGM4Djo+ENQL/fBPNeyYWqrSM3wPj+tKRCeiNvYrj3+2ga0sfQuCbbcjIh
# DATA 5lzv2/gU0KeGkogVonkYp95DeIvD1dTdJFH85ZjqWHCZJEyHR/Ct23iZ/6IwMt8w1AV0mC+9s6/O/vn85+e/WeXJ/De67w9nvxPk
# DATA C9/F5BdQYb45+xN9/IJZMl9VPMOX+ersj2dfAFfzFX6q6qe+8ujrFzoouo1e+MvzXym4DMXj/O89Zsz8DmwaUGgcVOYFwDTONLNr
# DATA xRc3jxIgoNXIvRCB6bf0fE38Hke8bRuDnIKGsXYvywvn5C4z8FH09FC4nA23Umbu8y35mx1jpjCbMz3DbVNmVsvl5hgznEBz1/cg
# DATA JE55PRmV7xtC+9kAvbDfd5GGp9eJlqE2kJGNnYqAOc00YI3xTAwF4eAy24vq2qkyphMaxmTG84k9MXXIfMVTELmPH3lcL7yPeXuA
# DATA uG2PsD9y3aZyYR9Co10rfaPMZtGCNc2x94PG8GyFIbOt5m22U1ba0LPix2yLvqPHuCH9qYZ0jZO50kj+avhkb28Uv4FBfKcxfMch
# DATA /KZHcKmL5WTn2yafYYu5CaRMOaE5WcZoTuQxp9yMQoWYgfuN5Qbg6ZpRkWayWotkGH6GDKtATxzHKeNiUFgaK0MpDzNcxJFxQxTG
# DATA aqgMrJeAyJzC2mLfroR4JNvMME2gj/2JeNyO0ojPA0i2661uyrdOoz+kEPj7hTySQ4z/nCWpZTMUMSNR6mAxDhbjYDE3CIu5YMzY
# DATA DQl/oWV7q+b5lTjVT2WcOz6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPD
# DATA OD6M48M4Pozjwzw3fJh2p9lv1q/IhxmNRsFw9ALxYcprzjvRYexsadQ9v9UZNzqN46DX/D59L+ZIv9PpNIer2dkKPL9bpwztHAfN
# DATA 9vfpe/E5qpvdvuKycFlKWUnBnQqHJSjoSjR7xTJuNksR6Ue9TjnAIGhcNcBhvRd02isBdoPrjWGj6V9vDJtSda4vhnahUFleQx5a
# DATA hXLJADeUslUo1xJDu1CuJYZ2oVxLDO1CaUjg19dSLhngxS3lWmJoF8q1xNAulGuJYaFQWs3rbSmXDPDilnItMSwUynXEsFAo1xHD
# DATA VmC15V6xlP1GKUR1IVW5Xx7821GjhOJq95phcy0sbR10rNVqWNAxCT81SDDLSNGhrvDTgtbTBdDq9qwAWr3LB1BIQq/9lEnYLYDL
# DATA 8MzERtM8MzH3LJ5Z2Gw3G1GRZzbi/9k8M/rai0YFnlnUHYb9Yc4z6/Tb7Vbb8MyG7YEfdnOeWXfQDIMb55kpr4fa0GBmQuKMJ1uS
# DATA HRSW90IvUpv5WZdXKtcs+hdDLnPMvheRERuHFYlJaS/KmuBsRyQv8hRDV+u+F0fDTF/W75LTt9Pk+CjabamotcvitBVqedXZ9pno
# DATA OlJ0OwcykV9ZPfQb1iKxutcPil4YXV15j+U4HCYnvBCDFbe6p+uclbc9dljwrNjM5jbsp9OTWJXb9c0MNDtPL/BoWLlVqpM8WQ4c
# DATA CM2B0BwIzYHQHAjNgdAcCM2B0BwIzYHQHAjNgdBebRDaY1W7Yyq4uwplhs+U6AonSV3E0T1khNwuqpt3qWOjOrOHqhXfrR/Gb/AT
# DATA h/Hrr+8/xkW+7TAe7Z3EM7KuyA47nS+S78KI/xhQjOmPOJz9x7oFze8yaI1BIHvNoNfstTtBr32Ho7T/Hf6jotC/CxvwhzR7bwTS
# DATA 8fr7h8Pksbyj/Iq9/v7hE5bN3Ov/uP6Te3fpXfuHIvmGC9/moF/3D59EZKwrLTgrLsJ/4wD3VDz26W6lPjpf0qinur0nEj1Ujrvq
# DATA 558m8WyPeyvKQfDh0BheVz/KAu3eXljpU3GEr/crZD3mlrxK7SS+u9GancQomElsV8i70jyo3OhNkjaaOeK1bOPLjAAHyNHu59hK
# DATA MBvuTeL9Q8mj4u+8Kk0Td9UV3/Pr+8UbMASr+LyFe2tyepoq2xONrDNHP52yilNWWVVWMYeBnbqKU1e5pLrKRlHsG1Bd+RhyXFoB
# DATA ZJKw3gdrdhnhlWcr5HUbdDo2BeiqeIK8ZMSJuQBLpx7KeyT1vaAmu0Kk8y0gXdvG0flbYHRsvqDq4wPmHyiKEoxO3ZPD6PRDK4y4
# DATA tgT1SEykzSw5HpPegXf9ojt9UQMmC/SiG1lh95OTaEKd6AX3BnV174xM4NK9u6PruHqjlXOJvrDUur/RjAYZjzKyHqKhkdoz8jpk
# DATA ZBlZHDHfy1I7TJLbTbaHRWy8LFmmYPmOBKcC/W2xGqHhkPPpxGtBRuJMyfhQEk89dejeiMXQO1fUYsaNe7b+D6WpQQUz0YXCFpmd
# DATA m9ZGXVUCk51ocy+DYkg+ljij0xmdq0Znbl04q9NZndmF9uQz0/p7wKghjiS7uIEcRfU3RqcBkk3jQZpYEnhLtlCV/l1IrWs2AN1i
# DATA VfvODIp5i1KDoYaUsJTcIJlOo3QQ6zGQLdc0wkoLNi7srP3HKZvfeyDeqv4pfGYRdplgGDUAJWH/0mCKvRRr9LfUebdVE1W5Z1ET
# DATA +ZMyTpXNoX/MDSBzhQ8+A50WcTgqfrLcIIKDOvJrbU/j8wUnSH0uWp7WHaajtJ9aMezgNEVbAGtK7ou32YHaOH+bDbhNdw0SEDeo
# DATA uRzzzW/lXzc/w5UId3+ED1usSxmYtYUnLlTbJMEgscW8K5Qw9nxIg1ZHO3OkA3VKht3BHmtZ3VF5aedFCQfEu2FMOxdnMNemdMm3
# DATA B//y8/+7bVJRjrbKWWWKKalKqiDp4lSMMbLveGQCk0dbkjwI0bSvCrtryPNF7/5wCGk8elpYQAM0Nqr9PFFkfjLYK3iQzT8ZHZmI
# DATA oonJsE3pLTXvzXCWUwFnQ5mUyk/vggiDlzTqNMgaSpA+dnKlfC3Vnitkb3Nz9hbqouQy7GWx4Skhi3Ci8/k+82RokJhXJNf0xJpz
# DATA LcQmgEU8jWwo23yy5NkzzS+XYtEzAUl59L378RR5NSJrLRsDVsWmNy75Ab7Ok4xN9Jr3DuCLeM0wzgbLDAXEIcmi5HXksmlvl83f
# DATA zXmrWq7OVfT41PUu8EHn6dvY2xN6jf/zTw2wkoaUJ1g8mIFnfgJ8ENWtJeUdlYVM8TPPpwLtwWkh6y+DiOYgNe8j6rJp6n1fKrZU
# DATA XxCgmJPE5xU9uDcOvTftO3CGUNwlPJNWm7xq3vfpa8QVmcr/2irylbN4ew9RyOZPaaClSQYFkeo8NubsiBp+VfScchYYtAOpfqEy
# DATA zSUPZcUnk75A7kYlhZ8mVOhxTAjlwQ+hXYqTgRnrloYmkHCmoVQVeRn9hiUUiRtn+lEskqfgkR3HCbUQ9XAoPc/z0Xm0L9V5/Ntl
# DATA zCufevDWhSAZTPWXxjhUbK6AbANpw0imQ8h2L5vEc8pPbhzctwB0xtObPuubao8gFFQxqosSK3dN3lG0kKLjLMRCYpZMI1w4Wkbc
# DATA ceDpeCYTFeqXFtfSfdz84PcWj0tgIsWmaptuUdwai5NEOmTJWvTGmSA0RSg5ilMa3U4Qiq7HLGMbG4Vfmq6j6aeq5ZMtyKrOeCd1
# DATA TTitSL31sZrcUdh4YppgIZfnDugpGDsh3Qts1nLmFs0VWTa2zRVzRTLrHjUwtcCrhYRl/BZT0TJfqbmNueFJodQuYj29DC6XfLbl
# DATA XC7O5bKGoOC8LC+/l2WjA+W5IioUjgqsjpQTm7XgTeIFjjizEgojMUGxVKMJu2DyB/k8CWfss0YwPM9a5Rfxk6yDH7IqyUdf7r1B
# DATA HWm5vemj74XjdV05y2edy5cL4US6wzJOYuVIurTfQYLaIW87nQ10VJTKY+53s8XsuTzWgDms5/gLp0etxIyDew/YJjdVBBDkcHZq
# DATA Vq2+n5wAh3yq6s53Pb6whHeKrKrvem/R/RF1pjCGYITklvB3MQmLp1zhZtmJzB4W2Gjn8dIx6+/Hiuiq2VSA0YZkm4GPC+0yMrz6
# DATA yaNohRdVrC3vxgzMZAckZcdysKBESrG/CktONucyYR63Tbn8z4yl/B9ATp7/1gOR8uz3Z1+ffbFKuCzd+ZcceIn7K975L+jaV/Tf
# DATA b86+9s5/ff7Lsy/xBO79Crf/URCYdPs3Z78//w+AV3r04ed025/kVsexfAFMNi9jv3+qDiCavh6J5sk59wQ1T3bLe9lSJqyyIZ+5
# DATA tfIgN2CMGTyYsEdgJtOoESas3ODgJ8PSwpg3z2+hWL4pMmCCynAIy6IJJ43+tgGWpSK5OXol7IBjq7tXFY8p6PJT+QlVBc0TH6sq
# DATA iSo4g0fsWoGWvFtiHGbsrwH6RznKlQXjoJa7luC14y3vwy49ElvFsKMr3G0O4WDTgCDTZ4mh/XY8GsUDbMjHtmXZcRNpBri+dRZR
# DATA GPRzKu7+FaLlTnVws1lSbF3Pimu5UyIc4NKN9U8x1mu85eWH+FfEQ3NLw/t1j+47De6XHttvbWiXalnIhhxz+czazU1ALgtpxJQ8
# DATA LCYM20olAQh2Ol/IUDhP0fWAUzcO+zEv/C0yXWr0xNERFlgeUjXIZB5P9Vgtc2O6LSOzGYEnMVVILH8J4S+D4l+6K+IS2WiYgJg2
# DATA UPwn1NXjDBvWQBTaUceet72uYCVVTaoWjAVZEOJYskQKQkEeIgOw8plV51FaZauOSmA55V720DITcCOiXCWDbaPZ4BiYjoHpGJg3
# DATA wsDceYDZaSZzCXv49kz7q1j212TYOzimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaD
# DATA Yzo4poNjOjimg2M6OKaDYz43cMyg3YiYuXVFOGYv6r1AcMzCyvNOZEwL9ea3cspio0gV65QyvCG/S44XkWXNbrveWZPhwG62g3Gz
# DATA Oa02m57fHQvqzAKPlWlkOXissQJ9q1txLSHVVuJab2+Ka7/f7rbClbgGAcW1276uuPasuHa6W+OqYHZr49rsd/nXYlwbft0LqP5e
# DATA T1wb3WupA51Btx36K3Ft1q+zDjQ711IHhp1w2F6tr83eddaBVvta6kCn3e13+itxbXWfvg5YwVFozXZn3G7Uj/3297slPC51qIPW
# DATA 1SB21JdqiJ10yxbErtmmbqO7A8RuOGoVIXbNqDms5xC7Vqfd6rQMxG7QHUT9QQ6xa/Ra3U5w4xA77KGqyuqGHl2bFr/OotV12ebM
# DATA 778cl67sdG3kS61tcbpyyHxOZTdfanubL1XPCfNAV1dllK9ZTzMwUVBTrl5rhQ4HnxoWnOQ/Df7dcOHiGdUprytkOKkMzSKdTtWa
# DATA dZS9qxHjZMVALeKuLQLj2iv7CzbC5qwS2GKbrtYYx5dzfDnHl3N8OceXc3w5x5dzfDnHl3N8OceXc3w5x5czfDlWb1QoOfZ5UqK/
# DATA I1/58B59vaN/FdAcG5ufvfaOOv43NCchcViPSWbMZBtE8WSPQ2eymuhnZrXP6H+z+wvcJsGqHxSATX1jOIwOd0gTbo9P8KwJ/E45
# DATA FA7GejTjEcHgzpwOojtov/mgvTtg/xIfsL+s+uFzc/A+d2xtV0NkkTc+zTqjEYosCwgsj+n7Ni3EZ3tO/wU7sXqR+k7uqLwJbcSS
# DATA CsE1CyOWdRwuUEW8rwA9LIZAuUptKOPAjLTQR0t4Y3gHg3e0BBSsHzEbLLRUv6F7QJN1jNPeu3Q1gci9Vj8UmShGNCh1Baq3iRZw
# DATA lhPlXNWVeAOyn8+U4xx6XyoEnkadix7NZVqhVKbLqodblZRKTQ7eaxt+warbDxIa6cbqtLpsftXi2x+GkFs0Mv1pdBKmOFCvBEVP
# DATA wokczQ9VBfUmSAhzEtiBHoepCFNI5IvnoRchi6T+YLlAkswh6LJG+WocdS4basNMSoIpNtxBYBOGhy/DKDRS6mHGKg1KWCtkPA2f
# DATA Vo8XW6L3Hqg3l4gcehETMUtIQ1ckCGBmVPhhqgAGySRTPEZD0+Fg0ofeCXohji9O22+J5EfymjWZ+AqdWLdDcTays5HLNnKpVjlZ
# DATA KidLdRXreKM1fmNyVd+LuQ2wkRAqoSetYEM59tDSrrplTcTbgAOLc4chOLAe0wg5B5XK7Xhg/ZjpncyFnHDbrF+ECG7UxZDdgRIs
# DATA Xicge42DiS+xSwgvvyDC+nkTYXMhj3BrfYQljirKfjnK9c1xZteYXXVRtfb4xXfEM7V/YTYXKcz6ex7nYG2cW1eNsnaY0Q0frPe5
# DATA XRDjPAATaeuSlddro23FWlUfHelWIc4bgchvLuPJ0BrR0Fu8uFzkD2QYltE9nPPRG17A1nMpA07m3otPiSh1KEn+mB6KwOO6742i
# DATA E3Zps+N4YTyq0MFaIyR/lLJQnRn/Z9GxZl4ZCbAfqn5dd4UAroXAomP/LBvkNe/fkaUw5HkP9YxWN0tm/xA7g0R1TTMyxZUtHSk3
# DATA FkqRvJlND0zpaJohHLh4sWnK9hIb4fbo6oxwZ4SvOKpXrC1nhzs7fJtZ/fzIxqrBTjcD9oGhLdgq8MDt0FhlWuFxPtQpidJKrmLK
# DATA Q40ROIVeJ/ZWYdRB4HOR7MTwqpyIaHMjAaJky1gwM3IYZJPm6pXpyflLuWFDAr+PSqFnETQ6Dx0/eRd+8ox9qHhCvKmb7xR3skwh
# DATA 8GkLOVm7FS3nHyi2zz9BOc+NS2IkP9mMkNT5KhDJ+wXPPVzaVGUApU0jFFMJmJpGR5Rjxj/LflhBYtF/Rpg7K/VZqpEZ30i3zRYx
# DATA TZhlBYLnyjXvrTBNTyHKmsyK7vE0ZGYjW62L9FR5iVmUFXsgU4kYfObJTPvJ1eTBbqT56o9uIvnqktkDKaP8luSb/NUqinSBN/ty
# DATA wwzBODUzkadiheZV+ZLF/M7mYtaNQhWzcfrnSzKy14J7DF3Q76OLhZETCpM1JYtdr3JkFrJetABEKZqXXiTwbJKcTE5FEjplZWN0
# DATA rhiLzFIPlTlv4EMHOTa94lMV4fak3VohFnqZS5bjx1tgxnl/pVusoEeURHIagcVKQ85sqMTAuSQ1CSxvp8M4pFnglA3UUbQ4pfF0
# DATA iTyOlfMq1C1Z4cbMZJ4XXWh0zflomVnCocH3EWak7HNjDxgWCGMBrj1129yW0Fsr1yv3wQ927oOpwi7oFqHrRt6M2dvZw9OV/lez
# DATA baRYYdWI0DQbGeNoGmdz1r723uceM2QvwSRMjyArDWXGWaY59SdJKv2rtBXpXEchEMlwC1xLu1yfque/W/3+zt2qGrvIvoK8PpIa
# DATA qoFqGGqCtWmSsu6N7jLRxqLYofC28Ok4iOOgKBXfOj6awdUjE1FtYcKxwtLgMDrTecp69dTrSjFzPK6j7e2QsBeia337Ul2rlnWH
# DATA YTJMwxM0EN6dMIlH1kK1cq7pO5T1EIXYFkqZA9l7sXdsewYzGi4sbfIMlouaxy4/s5attgcM0nCOPOcjoXo/hfaQPV25bk3hlUr0
# DATA dgHeT+Whffl9ijkCcxDRaB8PsiIC88vzn599cfans6/Of02ffwGeJbCVf6I/vwDH8vzn+uI6LOY3Z3+k/3959vX5PzDu8vzvGIr5
# DATA J0FictC/pyu/Zn7m10zO9M5/df73AGie/4rpmBT22R/P/5GC+BX9/S29k0LATb+gH/5AP9M9/0wv+ersz+e/cZjMF8JRim1p6K5U
# DATA t6hqHgedHYgvioewPk0PKvz9CJvd4UUdAFmnQC3HIXuuQjNFMD7X0IMXbjCuee88mk9gvlBnisJCrJVBk6sDb+VnvjWh8UtaIuLn
# DATA CJq2D1X3GbdN0FwplJtjaHKlNHdhayGvqSsP4Apxk6p2nJjbH/BXD6JdywlEwq4ToBlnEhV4D2VnY4QzvyH4QafRwtEzdym7GyBn
# DATA 8iopr5bHU0x1EZqpAKp7WkR8RG2AeszH+r0PojBbquVbyrEloFBMV0DJUV9pfM8Zc4a8RTyJlMs6ZX85GUjD5WQVp7lbldxs6ZTb
# DATA 2rMiau6WDofUdHbBTdgFmrV5FXPglVhOvTVT4PotgZ0MgUvZAbdnBki9LOWCjdt83trUTXA4S8nnRMNNzexCE5kyfFMrFOeZcwwn
# DATA xkTxOO2DNJxbvPRslP9yAJ9+GzJDfDkaX5k9jBYD+L13xXHmI75lMVDksnz4n4qdMMS+PKhGQaGG4utJiHyypmAP8MI3xS0ZVpUf
# DATA H+08y3gfmcd7uMQW0U5FGpWQXPFHKVonb5Rgt1VoltEcetOhNx1680bQmzuNNTtNgS5jNN/mFOAqM4DrmgA49KZDbzr0pkNvOvSm
# DATA Q2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvPjfozUarOWwHV0VvtkedUfcF
# DATA Qm+WFp93gm9S6DENi95AZMZ6nJeDU6Eb9vKMDZqiQ8W/BO0iv7A3HEXd1VwGEzBojP2g9Xm167V8L/A9v97jP41Wtdv0yD6u9hrV
# DATA VrXTq/pB2wt61U7g+R360igWRrvbbfUieUcxzkEzyONM78vj3A7yKAtZ1KoYrUY7WkVZdnqe3+qMu91J1a9T9Dqf9yiy7UY1oB/a
# DATA 3arvd6udaqtV9Zu9Um3xo0Hkl5iH/XY4CoN1zMPmuqQ0JfYDFeOOBWFsWkkp1vFhdzDoryEy+l2vEXQ/77arTUpJo+fVKU1dzw/q
# DATA n1epLBpNSqHvldCKYdRpttfGrdXt5HGjgK1s7lk1o16kRfrNQbN9BVIjNz1NapRWbJEaKS6D3i6kxsIVkBqDqBsNLVJj2B52hjmp
# DATA sTMMhqFFavRbg27jxkmN2Nte3WbS0IBr+bjENjYPaUvGhhIilSO/NCNudr/t4V8yNTw2N/Ig9HhrLTHKr2xO7uj1D6z4rZ1LcIgQ
# DATA FLZ9/nXczXMQbZoeWgZ4wRWqyv1yYEVxf+VQyFKetChP6N+G/FtYrWq2DDay0/r2WsKjGIuUZpnz5cul1gLWeoTjRlTjhZVB25Pr
# DATA a4FkSmAX387hlIqGZ7GlyZDjQDoOpONAOg6k40A6DqTjQDoOpONAOg6k40A6DqTjQI5CNO67flV4irLpGPBHsmY08vGBPu9+Eil/
# DATA JuMe9xQuEhfwhASFqvouNvrt+YxkHEyF/VgIRM1VrVDkysXBiIgsxJPVcXo5au/N42gQ6dOIOCMH/2Ef5VHkQOYnb9zpcHc6fOfT
# DATA 4eUjWu6guDsovl13+7k5QP4gfiRNqELj0+wUS/6xHLK0wTfmyKMlmoomM5FDnXj24eqpZxwF5Z5XnZ0eIRQ5mZmFk+iS8tlG1VJc
# DATA j9zE6eZkCteofc7bKWfvopzNO0q4KuLD5vvQX+K2H9HfLZrZNCguBH/4kXx8EfSyTR5cUiTyzc0ikSo3RSDyTZziHOFYNwalXA8S
# DATA m2U8stypquA8OE7ng8tKU55TCHhO4pGcYE4WTIHIeGiCCwrBeKOI6tEEBhFNWBI5eMwp0USUp9HOvGqWvLVjlryjNUFpTNYZ8mY4
# DATA ga4Aa/VydKkx8QVz5lqWcFhW1BvBu0xPI6d4gYTndWDO0dCMP9QEyfqL5WQ+AptdR8bodnDJfPnR5nyRFqVqynLIlkleR2ZhSnNS
# DATA b0ZzWg/9DINBId2KBQnIDOTwH1g0XKWimRDKIEiQMUeEPs/R3x+fauPmGdaRf7NjHfkoWbKGxU+XR3l+aLXpuVafTqYjbBoBpoE6
# DATA gTmmV2gQTDNSGKMhmRo0mA0o4ybjZIkTbzXvE0wIWFuBlRLErjuahD8zQh1PqT6bd4WXzJ+PtmjP6k5Vcojm195cX5Ic+ihNjlEH
# DATA KM00uzmKDDqWN8lRpQmXA6hw3J95yxmSq3sYCAQzEBVYpgmU9yEVzYvLz7DdfLxju+FKrZRbLGQtKzJMkyXUx5dQqpiI8ZDyGVn4
# DATA +0HFGg51zwKl5Vi6UjbLbCHeUKoL9dfl/LhdKdtXRaEhN7PdJNxNwneehLsZ90s+4944mX6uJdt4H4vZ0SJUVt7Vcu8NatDlEtb7
# DATA L5Fcs62uK1sprc2hciGc8Ley/NnKvkipMIMEO4fkZaezgY6JOml87wcr2yr1JH9VXc56jL9wagrj+6RA9gJ8glkvrDg2pOpJE3jt
# DATA X8gf4qPTPNw8p7p1L5Kc047Ctp7ZUiXVt2A4mA1UWwy1f/mn/6TNCH7lOBApO7EgvUU0mfDURYEmRNHre7A/M+9IrKxwwbSIIVTY
# DATA aMYyXk77urhCLx2fLsZTZc2ywcpzg6NYfhbLj8XIMG2GqJml+eXxnkeIdClp5ArlVhrlgnNGDVCvQAtmKEdXnITpiqZusUAZamQM
# DATA RyZWvYKyWlYwzmpzVtvOVttKfXNrJ27t5AoW20bj8CbFdxnQNFI6+izmjrzmhfiCBu+zF4TfZgjgnJ9nr7WsLJ2Irci25bBwrbCm
# DATA IUv9dPld6n/57Ddf8fYG04tA9/pR052ZC2aFQQ6IlJHxfhF0byPj6zV/8/qL2lBgR1Yu7RJb87CJbn7FxLd3ndFVGy/o9w+0/u8i
# DATA WRSqxN63L4q2CcREO79yQTbXrXg3tkZbma9mwUx2pfIql1T5iLd4mKaQWYgo1LB7b8iZYBVntT3Zdqrll6T/iQVVNaexWxmxdySI
# DATA p4Q/iW3FKK28C7BVqX+Ymf0laHzGuP1AnKlGqZmRwyfjeBLl/UQMtdoF9uqkLHlrVjqoNUe5eDPLA6sVTpi4snFFtr6RqVuqAnqn
# DATA lTdUqD7TG2jtYHSpVt9DqVpO6X5sD87DYT3pQTiDdvCcEhDjnGKYznmhlz3HQJHDXXkyjsSAzzsupAxC09yv8cIWGR01T8HskEIj
# DATA NJ0t59T1KP3gorj0Hc73V8V6tiBcPEfnOYTN4fonZnB9ef5L4V2BnPXN2T8rNBfgXGBxfbFK4PpvdNtXAHQJWuvsf1rh0CcGbP2R
# DATA 7tGQrT+f/+bsfxlK19kXdONX/K7fn/8HJnThpIN39ruzL8/+J1WacOKAWy+E/c/GvbV1A6jANAHedYp+guubsWOY1JpBnpy6JFbv
# DATA o55xJqrfJ6wbLksXWna7orihR2js47CPfkpm66KGzXUGYuf9CDOEbbCtT+kuEyGH2iqY/nnPcNu0rVKp3BxrS2jfhv/EW7Ktt1p3
# DATA /jSj4tY3FivYdSK2QgFbabiCWiCUxDi81gXFde1orY9CMjrxM8W6Va/U63UeNSgDqIuqeR/RAGKsHiZY8KRrHM6xFqx3/i/C/iEi
# DATA KTjqzEAoUFzRIxoIcLagzNC6sLptNlOKjedZwbMuTIDjZrnh/bqHd83Muvyo/mo4825xRL/uAX2n8Xzn4fxWRnOpjYWk2z6656kN
# DATA 3QQjq5BwRvxkitluJ5Mm3WGmFs2GWDTrwzIPsZO4QgmNgfShRhNTEiYxWFKzoX7tKIwn8FcOQrCKmC1UTBZG29Bk9JQGOL3AHM+y
# DATA OZIEFym1kF1pWXnIrBmQyfso/kxp4q3oY6pzcK/QRT5TzqfN2b8xwwofz2GXTIiah+KATYaMzBKzIDNnxSlFD07JeHsET1k8DNVJ
# DATA 9kgMwyjDPsQ4G2MdM4RXYyDcFaQrHmED4mAcTUOPd74zhWvOY5FDaTmUlkNp3SBK68IxaKepzo7m8+3NAq4yCbiGOYBDZzl0lkNn
# DATA OXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXTWc4POCprNeuvK6Kzm
# DATA qDPqvEDorMKq807gLM5YjkuPM07QTHW/IEfR9rvFDG/0eptzvN7oNVdBTr2AkVQqKAsu1al3e73+OrhUQwIZxClLUKmXtS22VIPj
# DATA yQfmukWa1LDX6LTXPd9q7fR8r99r99c9323u8nw36ndCv5wJ06DZ8IKgXaWK3epx9Q6mDb9V9QPf42tVuVb1/UbVb3aqnY7nd307
# DATA aN4wWsJzdYfdYW9dDjIurFTzOz2v2fCpwuPVXn3cq5eCM3m3ElzvCggsbkIagSWt0UJgNdrtfie4CgKrHvWi0EJgBRRQJ0dgBcP6
# DATA sJkjsIJu22/3bh6BRTOhKv2+06Q9CGisLPqtCiONjHg6RI8PyBnuk7bhlPGpE6wDSLVrZV0g3nLyuOQyscaAlbvDktlvTPGuMsXz
# DATA B/SoXZ4HrpvzaS9hl72EsjoIP+GaxbZ2MRHFhQCZI3r2xEcZcvkTZhhcs2JXxnCt9fjoilr0MGyCdhnnsYoO/MbW9Iu/X5BPxRe1
# DATA kRz2Kxa2nmx+3ozTF7xmwxRuM9bLVPCdcFzbKu/maX2pMq+rk8vJhZNLjoLjfDnOl+N8Oc6X43w5zpfjfDnOl+N8Oc6X43w5ztcr
# DATA xvlCXVAn5KPhoU39WmDJlDMCqbsrdT1ZpoMIFYRr1WE8YiNTNcx7rToMnsUYsIJ30jRBHN9WlheaF5k81EenR9Inm9feLRnT1pyA
# DATA TdgKJhcVoX9hWyOXw74wx0wg9J26is9eY7tGzHPv3fzoP9nRp9mavmD/8Anb6I/z2GCr5SieUXYoqhnLiCrdh2Mr+LfQ+VBzhUu1
# DATA gnOM01DOUHGp46197FGm+SW/yIqfEtSlrgYnoT5MjH3qneDMorI+6TeOIFVrzn2c2qnqH+mX726zO7gMqXzydN3NU7b/uBAZEaMy
# DATA cdAijepNOA2IeIjVf/jEGPOfvWYCryFu9FZz4XXqq0Bho2vU2vNjkHfkRp0bfPaonF6VXFPZtrYXTue6wtstGJrM4fUUENvLkmd7
# DATA YkMPFumEpnx/+7fyFZsB6ev+X/+1fKdHKU8/e+0dRjy8tv94g+WtjG7qCrPFA7bY96RQncS9U1O4kpqCU1F4uVUULqtu/0zVFYwD
# DATA VlIkYn2WkvsiRHW796GW4eaU8kHWJaQt480JeVuf3c+VBySWeGjbgw+43fI2LywKbXyqkB1iLFhtL3/qDmKqdQj5aOxGgXtDYlJS
# DATA CNSqt4vbP3diEy/A4Wr+7zWTE4qiGNfNTShrjaylJlxWJevTNFamWzxjViPZbjBmjEqW0QFh5bIMFvAJhMymS9FwOGU/dcUI6Etl
# DATA VJWHKwpGyUwU7S1ND2gchGzRJ6MFw5XSiN3oTOBSwC029D1eGGS98Vn0iH28SlnjQo7Ry3FO3oTgjDtn3O1k3JWUcpxmltPMuoRV
# DATA t9F0vCktrfdEsIkqtprLKycCV/Oc7HPbio23IXKvPAs6c3XS39A7MbTiuL4NquniKcNldpYVBNYpIycT9mgzAAFrxTy6/TVcTIfo
# DATA 0+TTgbqgLGr5VpE/7BZXt/3YrwSVxk9oUNQx2iApr5xq9K73+BNX2SKC2Nxi+tb8oRUCcMDIhpPE460kW8DDTTG8wT0s3bkCCt4o
# DATA Jm98WHnVeXF15DHlEXkpZSOtkzhbGoGzubSaipIw+zfhcfhAulilZgbCinaDopmofGC9t5NZUQtNVLNCQFpsl5zSx6IBE6Jngkia
# DATA nCpHqGnuULgSAS56+gSnu3joZM0py/1X80xxYUQkG3k5WCwVhWkST3GRNxpBsAoicUy7gHZXpqNSqgj5VMQ2k/OphZRW0XWKuaVe
# DATA 4TeuQzXnMzXnYtn5l8NCzYcZZ6I6E3UnE9W2RZyB6gzUrYbnsxZ7/bDQSGYY6BbxNIcyPZBlUhZArVgUQEmd946WQYTAIo7vcHbR
# DATA 72gqw4THauhyslpoeETxwpaz2anRg9xRwZWja2IjJCiqBRB0FIOAGiu1+4j1LdF5rPHWqRPHayxV2aOACsafFB1IWTL6x9y4MldY
# DATA egLI+YjDUbGTPTemW9rMKjIbHxj6I5+LdqV1h+kS7adWTEbsHMDoiI5R7ou3WZhokdqXvPkuS8dWMI7m65aQoyw+4rS/zZ+22K5F
# DATA NrjsJLANFkUz32Q2FsoYu6ulsV4BwK5z45IA9sdPNhPYJWOFwI5JXKQZ6cppf6pJ7J9gyyilPF1mst2La+CMtVOVkC7mQCBz6hXo
# DATA GJswQmyg8PpLMnSVYmo8qHlvxyywumShXW8aZzx7lL0u2K7EFFHeBCLXuLXyyrCQGIAgotelis/21Gj7Ug26ZAb/yz/8cXMOF2qj
# DATA ZDRLuqaRCP/CrxoP4oVB3vMvOX2JtW/JqBYt1WSuT90vqLalrOOLw6uLWOzz+yM+FE5zg2k/PlqC+6hcvxXd3QkqSuiPIRn7LOEb
# DATA D/k3mbBfR45esa5Os93q6ofhVKoCpKzzrJPagikOFGxln6+o2kKnehItgMSS3U3maY8xHui9GPRxCrSs0LpmUAZEgyDrj6JDvScV
# DATA hdqgYBrIs69+//ZSlU9YZxx7SsXny2gZ6fx7HzM4TNpoAp0rMZ+EMTtz+II6bh4BAP22NEhek5CKk+UVlQNG1o9wtIDzkzJwBhcS
# DATA B7SQp4DpjUBRpKEShXYtVc907ZfMyPe21D01SEgellcovUUaHtO4eUJp0Jn5sTpKMFYC2aFUy5RsmGiYKaOAernZgsFxCAt2icxP
# DATA qCHPTM+getUp9RoZzyVjSDxay6o5XG4RKzn3iOa/WoUbtt8zzddPds3XT5jAZy1X4Xxj3rrVclgaHWE/uBwQoYRkasjAaJOr1xvJ
# DATA 84x9FbllGI1GnMN2PxD2Mxavphkau3fkHlWd0ZuK1Rejs/2p7GYtZWjRSJA9i7aRYK5I9pBdq3cX6okdO1vUrj/qiAbjBPpZIfyl
# DATA VJK6IF6JhTcbo0clEdkEvf989s353519efa/zv58/ltw785/ASQe/febs9+d/0bQeL8/++L852df4e/Zn8++Ov/tKlHPDodZeb9g
# DATA Gh+e/eb813jq7Gu6yLw9Qe/R3z95dMuX5/9Az/3l/JfA6SEG/TQ6qRr03tfnv6K/v8XPTNz7k0PrvQjeGqlpNm9eppwPY7TSmWwL
# DATA BrHhh8Y3I8r3MMfIYhhC6YctBVnfwO8P9XaSNBrEc2VzZUv0R9zapwmL9W8l6b0l8bIakIPp2V4a5M5tc/RWy+TmUHpSdfKVxI+l
# DATA KonkSflm9ETWmmN0ciO0bN5RPVeHLigrZMKIt02j2dLx9HYos2tH6olZz305dz3wMovfrE8GhO7dxJ7nbuyTvFui6pqcKKiPJpyz
# DATA zpqgf/nQAQotnk5xRgcwISpsAyO+VP3bggEuN6pnhdi7OBGOsefG+acc5zVS70rD+yuyAHMrQ/sNjOw7DeyXGddvZ1iXKlnOAQut
# DATA 9yybzk2Q9MpJ1Ysi4lINWW6yNCJm9pCI+K+MiRWBYsnirKyxipLFcbRI5vxMlPGB9oTMpcU4GWa7YPI+Rh7KMlY5RpS98BDwxl1K
# DATA /jTGBpOErDLs2ZKBPq8u9M4wW6YAg4UsMEqZzP78inbbpxHaD6folEtGdHCEBAjHCpPqdGXIwongvgZwVmuemaPhORqeo+HdIA1v
# DATA l9Fjp7nKrsburdrtVzHbr8Nqd1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNU
# DATA PEfFc1Q8R8VzVDxHxXtuqHitdtBvdK5KxRuNetHwBaLilVeedwLjFahvjZ5FjWvUG4b65nc6RW7caNDtqbyhCMY0spogGnkQzWY9
# DATA L5tAaHtyeCroFcLrNINBY7BSUEHL94IgGAed+rHfbH5ebXs9v+o3Wl4voD/1ahdfqr1gTcmtovlaAYXWqo+b7c87Ha/jV5tUD/zm
# DATA BdQ5E9gKJi7orM2ArkXuo8hblbPRyjOgUXjvt5qDoN2or0S50a57fsv/vEppbVJtqXb8aatJcf+8GvT0lSsnwA+uALrjVqFBd9LA
# DATA LNBdp9loNJs7gO6Go3YRdBcOe4NmDrrrtFu9dsuA7oadQb1vge46fsNvdm4BdIcmVd1ub3g8vFi3lvlw34uoF4jDigRcWsxbQcU1
# DATA eMEsXy4rBq3slhUnlc6hFUdkyd9vh7XOA3+pQdVj31udDSf1jFoCW5t041ZdjaQxy4sIORW2oOvWbxUoE+1WMWtrc8YMfHr1q76N
# DATA BrdDLbgpU8Sh3RzazaHdHNrNod0c2s2h3RzazaHdHNrNod0c2u0VQ7vZMDdJNh/YuisgtSFOub22/x35xkuOjOVSyLNkEU7kfrSo
# DATA 1z8IF+MazyT3+OL+65QDOI5K71FOtDk0ZpZzvn2v8I478o1+zLgXWSTvYjvenm+H8qkcJrMCKb+zFAw/u3LkTBPEZApojnS4Q9Tu
# DATA EPW6Q9SlYz7uOLU7Tn3Z49RbhG9v6pi1tAK2g6HXLqus5pj1MxTyuA3qwlAdz1Y1A1+9vaN9JWmrm92MHRi5ALx6Ku+b1PecWVBk
# DATA MUxjFqBrKWwD+/5l0QlbLHgtquZvFr6V8RRSzGZYQzHgULXk/wXR1c+b+JoLJsJ+e12Eu1aEg93jy4MqKG0cD44mXbkgkuqhXLdX
# DATA fS9wIFZi6Fsx7NoRLEZvI+/hLdWiIiMa9OLiHt5iK4+HMQZ4YXKiDyS/N4LKJvoQPoaf8UCHtpeRWTKvsE+TWukEXv/JqQclTVSy
# DATA GLw8MYrEWy90Lql1fG6cmqEKcUhBUIAwc8Y6wEECo0eFpI+DM3+Ca3KULbDuzlMqlmCaskVsiQDgNDgrMPIy6hAnyTxZuzm0xQBg
# DATA sqH3y5JppDui92n2cowZ0pgBGNy+B9gdrBKEaOd9zcWAhpfnYLGDxDpLdrsl6+zWl9xuvSwU9pnLA/GCubUQvGr0TQqSgEz9yVh0
# DATA W/EP+nyMFKbIVobqM1cVekEUOG4Cm7qigHTd5NQ1alLr4am7KSGW6h+y2qYpsIj0mynSqoZ1Vm3PFaR5T4+eCC0zgVNpfirbYhHm
# DATA WcPTgqRL6GGjxHKq7DNUMPqQRcpQQmBSk4oGikInv8s3GKOkLMHNcf6YxV4lyhFlsY7xe2aiFvMckKIqekaLOK2wMjvHRquyFyw0
# DATA rXhv4wPYIEVQZAXgCMaWaH+EhbntsX4A6IqKNW9TioY64u9oiashzW4RG0oC516Fp3wV7xSbZUXVCT3GIjmKoGJV8yyjOmFl0anH
# DATA oAJFfdkUXf3C1Ri/QgI2dp/kLE1naa6zNAvjlPOYOo/pRQbqsxemlBhkSlkxTZIpq9Rxg8jlKScTaSprRRJrqp5XxFlRkcEIunNo
# DATA RlifZioYe1Y8Wb1T7YqXES9HAXuXrQSl7ihtUi03cpjo+eaM3YQLOJxgA4MIZDso2C5QMLG4bNNq053Gz810F/1l8/1apZNzVX3e
# DATA fLeW8SyaH88/RizPv0tyXPwDv70Z5aILQ1AuP5hF1JnM2bVYxZFFbRlifcNveUf2SkbQrNMF5Ub8NFIEMpqCYKvc5LRCdjv2/vap
# DATA XozwdYHxEiFjD0mGNQ851ZFxDwFj6yTMxqKlqi10ujSZZNfBwbmV/PvkJOH8G9I4NS/mXqNezL1m18q9B7xQg2RzX6syCYqlADov
# DATA WI5SpDHlLvELTyLgi7BZ11OHcEWo9Bpyq9AGL59hrc0ZZjVoybPvUZ9KsXs35ansXCYweb4FpVrX6LSsfFvAlOJlMjac4tlygSEH
# DATA oqWT4sSKRwyG9VDNo9mVouCZSdgxdjROnoO8a18i795CFUhFViJfHyxkX6naNYJ6KfsqPJVmE/VIiiKjeaoopYLYJ60R+9GHaXiC
# DATA rbx6aYD1ZvOlgafJM7sPv2SWfbA5v/LRQCH8koehtq51Jr3LnArhRgDdJ/TCY7I5jJlOFu5DangThXYasurwNBkyyc8bYx3Y+1iE
# DATA gplphStm+cSsymQ00FOusyYvWvR1ZJs9mF26pgWbMy4fGCXjjGOgaKDpPHyAq8rrMvP8LtWwoc6r0Gu0ec8QVVRsC2QXAk2XlCNG
# DATA bDfGyHNdS7yjZaz4XsyNVd4bNht5y/nzivB6WRwSOcZrFC8gMWtzvP7fs6/Of3n257Mvwdj6yjv7w9nvz746+x9nXzJ668tVYNd/
# DATA oZ9+d/YNGFvn/x63eILkOvvL2R/pp6/P/3/23q3JjSPL8+xnfYqoaivLzCIAInAHqaSWoqjLtKTikKzSzpa0sgAQSIQIIKAIIJNZ
# DATA KplJpenpbuuyKbPdMVuzsdltW5uHfdkHdVVrSqUqqR/2C2R+hf4ke/7nuHt44JbIK5Okq4okEIjw8LsfP+7+/315/I8FhENhUljf
# DATA 029/8o7/Dj8V6Y5v6fff8Ju+Pfqe3vzN8ReMBwOySxHAfkNf/0QB0k+O2fU8uFQyqB+6zJHNA5I+JI3gA6UmqXGByaw7ZfV76VAo
# DATA w8KpwBf3Mf2LRuKClHYLF2ofp8/BAYBCCT8FDiNvROXtnl2lkR8Hw7UYr/tYGe8FhyamjuNl+1pUB3HVIK8lpXJ5JC9VC7Mlo0eq
# DATA Wg4jimdyOH+/1EZ98zu5SnqRMC+4DFVMRAtfduaHOl4O6LVZ0V040+tRmIEOMhZEAkiq7rIMlYNLzkvR22AvkMgIM1TBnCKG5+cQ
# DATA X0ve21FPz46pd5PptTinVEoXyF4nV8bV9sxiK3tWaK+TU+HQXs4cuHhzQNO+zmYFvBSrLVdlAVyGAbDR+H/K4f9qRn+pmAu5YEG/
# DATA rlmjugwO2ELyATXF2lDKnPf1KStwDYTqFSdhPp3vTNXWCN4CwSIhUZCYN+mgOOWy4ITiVK6Djchgj9nXC38QNuCkcL2FSTAsKEuO
# DATA BrSoN0PxhT0uRhhrCdUQXkPuZZgnjrA2BcyOEZgHFKi4POCcojYO10w0LlIWM4jdI+tiGo1D7aji5TOEjmVomC0FsVnoxWKHGBCU
# DATA o4Q5SpijhF0eJWzDIWejOdCmpvPVTgPOMgu4iEmAI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlSmCOFOVKY
# DATA I4U5UpgjhTlSmCOFOVKYI4U5UpgjhTlS2LUhhdU61R7/fCZSWLNf73eeI1LYwtLzRqgwO1/8ulf1W4N6oz1Hm2pQ79gKl9Gmqi3J
# DATA IS4jKYMaK1IKKcv3c0o982VX8e3Ca+Ty37wzF3q97V9i6O1GFnitnQtcUpUF7lcbNgQsF3i73+p0+vOBN+rtCw89B3qrCYtNIGV+
# DATA IwO91Vu5AMJ6ELSqC82CHvd8v7Vfqw8rLc9vnkAgW10nmmcAkHFj0wAyabc5AFk9aDc2AJDlrgBAVu91++UMQNbo1sNW2QDIuv1u
# DATA pRdaALJ6rdtuXzqATDfQtfCpkl/XFLLc/WZ01AsE9U1oY/kgNG8s68d1Ti04Mq1HO1iUWfLMpssCpYayQCq246FSWrIm7LNBlHtz
# DATA zqMglgGe4/mL8Sb5dbITYFIt8UhWjEdSMmV+mWXJQl994QWV23quRb23n9klc9FvsT23jIvWbrfzNDSsMq+mlOXKrTBXFmusnfyN
# DATA c74H4z50GDKHIXMYMochcxgyhyFzGDKHIXMYMochcxgyhyF7yTBkqAsUSm8YFkJeJurtlgvsdOdPEzK7w3T3lx8V4FDdD3fZgi2g
# DATA o32An3ZRJW+bCs2ny2AdJds7n0X9bXlo5zMdNLVQmCDBuBuWxmSh7hTVq27bwd9mVWd9cGNbordzG13Bh1uPs2NsPcGJfW7NcbCP
# DATA UL9fShHHPta8F+mnpyiprORBE+NkW/VW0CeW9FMCxr0buxO1ez/9KQy725Q+BP4q/bbzGT+9O7nNZzIoTvTjj/gaxWNpanIJNll/
# DATA 22T4bal1mNBzo89qGOX5m0rfmfJeIeH0yR+j/Ow9xiGp/PnLhKLPBA/KjyiW7BNb/vbnq1/HpLduGA23tympRaR55yabtoC8qSyh
# DATA mFCSTb2ghsSpL7Ebd+ezrMJYlyXu9n2UcTYXL6tBKpbIVckhNRbsfJZlGIoOxRlRNkavKnIeS7ohndGNG/rm0mRGpslnKua35E6c
# DATA sqP7ChwRmlh/gFN3//bFf1FnGoHNi274O9TFUCQWgi/6O2vCxvFIO+yHOC7Jyx+LoX+e1YXPVR3hyaRuk4tVWT1wO1f7b0s928UM
# DATA Vlc964ZCpV7Ot6hkNhYpYSH0cXXgVkYXXltn4GZtXj2V4AzpSU9x+drdhVXzsxyY62fWNYmHUFnN2oNKFKKik2TmgEuixWdQoiHN
# DATA h0yfqmugeUzGip1cpCnYg2hM08VlgWIljR4K5zLJMWOczsQZdSacvsSLry9xWpLMddCd4JWVnL9+PU7mPRyCB5ED4qv64HSwh1dN
# DATA 41Gc0MxsLVPmOopWPD9HuC+DNLOosXHRqJllIiZnZM14uSUiqdK8wnbHL2tpYMFsGjkxepm6BQKeUk8ykQ9b6P0JWWUFcT2Jlj0i
# DATA byxvWc2LJ5hFAq4nrIfBLJmy1Fek3juhkX8s+gmxkvowIvZrhD5OUh59gY7o5xqOM6GcCbWhCTXXvzrRLifaZQ2/K42v6yDm9fos
# DATA AlMrL1tlpLzeEl0ouylh5JmEMRrawSDOjVCCENADWMm7CxEbFB1r6gQyF1bwsfAJNcdgGPWheAPRbTgfREJqHIY9jRk7LT/FRFQB
# DATA H5ScNqTVC0uUtBw8ZRN4yiiWomO9e/V5HRAlYTeaSODL59V3Y7ePcLPv8afVd2pzR/GF+PPzgE6xc++UKvktGI6rdfKzssixLNir
# DATA p8XxeVaUjWwYv5J4tjfIGsMnDHtnCQ+NS5qNyXhkLapswzTa834csbZVl81DT5+gh9U4Y7G5Ccv3wtikOOyF04ugDJwj/+qny783
# DATA wvSJx852Cy0AbVwFdzLpZck4cYWnzDO0TYeDYPiE8krLB3J4uG02BKabUY1eOOYyYPE2nILwerNEi+vSIHUxTIusGZ4WzlBZn29Z
# DATA q5Z8e53GeNn3x0ydWWRqn7KtqM6F4UohQ6wejcGykLxkaTpZTEgVvStMpyXvbxiIEXYH4+jTWWgUFKmS0oQOrITpANOOQcA1Efk6
# DATA VRX3AnIz66ZOm5cn1EHd60lOfkB1h1UQtVSzwZCaTKI0chViC1WhRg0Snizc7hNIQc6Zsir3ApZdVMi/YagmmZztSkPOiHr388Pw
# DATA s2rBjdO14NeDIdsRaqoQ2iwaGAecIelsggkYJTBIOodqbtAVnUXZ6VzyeKUGucty5Iliu1Gu9cMQIoqYapFFEaaTsBsxEVbUL5ND
# DATA 1jM0k/BxeHAROWiPfaetgOX1WZgNpQq2gsqVmIuagkvTrhF3bejsFanHTMO6Aag8lFEHZGDDVMcOCm9AFiHqF7KMVUBZ+JAqNXQg
# DATA 97FVTO2xubZQlRfItZEF4fwazq+xoV8jX9OcW8O5Nc64JrTSBXJpGuWqyuborzDFqZob78YzZ2Ws824wk3Elx543evMyB3Z/q5OL
# DATA +pqZ9PKuBnvkNFf0rJdzKTsfiZ0h9C3u98U0CHpiF+QcEryrhX5mG8n0Ottqe8qO8ovoFj7mDf14hURKPW16Rv3dzPOrcnwTw0BC
# DATA xj0ZL3zmDhdHwVO5oyzn5MIJH81b7TvhTTKcEqtMN46qetpEVX83Ua2cGFW/tXFUZdsPIsufToqbvj2Lnbli4ldbFj3fil5lTezU
# DATA qqDxZ8m5AJ7+gbd3k/cpjsjElhvZ/EhGd14VaYUsC3EsxK6D2aVcnZvQ4D6V47g3JYisIhvfjNU+zKUVDhwxiWgy2LNM7ZzC/38g
# DATA 27SrJ6g0Me9jlDQgHZkyHAQ0vAO2M6FHyUDDDExRgbJZrAZSKjqhmmwJJdXs/bWQlhiS42GRYZa8Y4ve0gMPMxaaKLwoBa8X/epX
# DATA EYYUdq+MZykE+dNDsn3jUZp5Ue2YDcLh5ISF47lSzRaPbb9qtgws+S97tujxB/iQlfiZApOtXNIow6lVfcSG5RJ7Oaxyi3U4S8gm
# DATA JpPOph3+N4YXfgPaYJ5BePxb/L1IO/yvR18zj/DPRz8c/cE7/o/HXx19f/Td8X+iJ3+gT4pbyIxDEAslcA7ZYyDi18AoHn9BN/z+
# DATA +B/ooe9w2w9H/0Lh6Cf/cPQDcInfMgaRgnTMw+dhhmGqVzax4AoP4glylJ4pKH8ldzgaicHCSYbuLBEmi+gBlaLQCGBYGYIH9aTa
# DATA 6JlEYZdm4+vghg/1NgYaABit5tCG1mRCF9hVww0XSuXy0IaqjujbwNnQxB3+ZeF+bF+xOtxHcV/tablwtCFHIAc2jFKu7A5ruFmx
# DATA XTjW8P7TyRC9TKCdIaO4NxsGIK/HU9bsKXkfoO/nvivb58WLX9gYT8+a/U8Uh9mIe8pUtkHBhRJPA72WFYwFHbMANDy5Cq62WuZb
# DATA 1rPCGZ6cBoczdCP9OUZ6zS08ywD/cngKr2xwv/ixfaOh/ZQj+9UM7FIt5/LAYhY+q5ZzGXDCuVRiBQAkIMX5i7pWYvU5x/kEBeLS
# DATA VFA50Nb0JuoUxcObr2VbsZbohpU0Zq/ofL5tSCQ0XtYsduk07vKKI4/HGhXH/DiuJT2aa49TE/1wlsReMGL8Gw/5IZkNUTfC0njO
# DATA JshZAOFTHCxG4L0Q3ii1o1qtFZL1QMX5XhikiBDbdt0pXDFiJLJXRyh1srauirozO5T65WiFjlboaIWXRSvccKjZaGqzqWV8lTb+
# DATA WUz8i7DwHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9Cx
# DATA Cq8Nq7Du12r17hlZhWGv74fN54hVOLfwfGpSYd33qn55v9huf+o3i9Wm16zT34NqvfJpre1VvEbFqzb32+1cLnX9TrXbn8fYUViN
# DATA pRi72gLZUE76CcCvnQf41av+HMGv1srKWo6tZQS/sBUG3UVwosUHbNVzwVeq7Xzw7erK0E0yc6HXyvU1odfPFLpdIi3fq9Wa+7X2
# DATA iLrWYq29X2tvnNP+Ioyw6Xt1vzlo1OtzoXTr3U6nuxRFeXrsoLQbjR2UJmhhBxu9eqvZOxE7GPQ7/UYOO9ijv3sVCzvYa9SbdYMd
# DATA 7HS7tU7Nwg5W6rVW9dKxg2abGoT/9zaar6/h9ol96y3YRdocn3ubGSjV1OutkLqbKChI/JYCDOtqJa6yQOvDwuLCC+bc7rbRqAsk
# DATA P+8mc8/zYQd4Dfljh8nW6cY5VNemEzJFjNx8UHeCeUPFwgbmI2tvLtAjulr2Ki/z9spiSj5pFfg++S/1x55xrycOzmVrYT5P1pgt
# DATA a5PM9oQDDjrgoAMOOuCgAw464KADDjrgoAMOOuCgAw464OBLBhy0+W6SbPFiCCmNj4oj+js/bZVvVMoFmlmqnw64CHdkyqYxX/fl
# DATA kAwfdEMju8G/gkvXHSHg0Pv//g+vXca3XhhOSh/Sf2PQ1ijcO7vl1z7c+oC11PkcHS/UIBD6UYIo8ZSHIixhmcM3iIvXOcS9TMcL
# DATA OilC3DFP4RO/6x37KJukzgvTKfzI4S3v337z/yIyC2nfrlbKN+Qqi3uia0CQGmXmEGLubPdJZ7vdme4X/Uz3aUlh1+Gs95yLbT0m
# DATA 7F00DfNEyXsP1d7WdlkKB3ump8Ofn6ORl0EBmz/MftEMsEVJgLMSwPL+Wn1W/12mdklFkNf0Q6Nr8wZcj4HXi+mH9IDPaD+AExJV
# DATA i6WABkGUlLxH0ZTdT1rwXSqgCJfPJnI8WRVu7vh+kEkZTSDaGPf5LHImmjOncLNQzk9CmMqBkduBTXT1SjfP6BSs1YKcMeSMoXlj
# DATA aKFHdaI3TvTmJDPqeojhPJD6ykSLXmzwF5/EHaOI89BoN1AzjPbGivylNNQUPjKhYaELcYs+bhYliTQAfhXuUY3H4Q35LN8hOjRw
# DATA Qw5t7ZYlmikbg78eQ3UG/rFMycbmwbDvQlQ7HO5rM9wXJQX6JCrpU241q2Ff7HYUWWj+uPpe3p7LPctj/vQ8wLusvDgld+XRGn6S
# DATA zlUhrtxDq6DSFdtKgCuPD2IRa4pnEIwJIMcikJURWoqWSEQND9gLJbJMYh7SuLYPL/KvIM+SjPLqRaJSRLZfnI13AQRhqHYEolHf
# DATA Z0NZnzmVRqNmB8uFnRcFoM3Cm9gkWQJNjmkpB4wNWFDmjKEHLEHo8/GvzlxyDzcuuYdywFysdF1078IWQUcYMBuAimNPqX+nTPoK
# DATA J6yOo1hCeXQYio8lfUTtm4pAJql3NZ8RHkO1L4p702E4VWCBRMUlncTT8xdZLmVXV2ZZb3LKMvvZOlqZ6pekzH4GASLkYyemCNmA
# DATA KJYm0usoWtBsTxhZlLvUieNi3CdrxPC0+uGBaE7pwW0qkvC4UxZ3uKQPmP7GzBXT6Lj0O7P08PyllU/Tc1Bc729cXO8HALfzYgb1
# DATA 9RmPKh2Ilr5pDNTr7cEf/iQ8FGu/E0BByxvEI2lYmByMOTTWqBt7VFAJaGFA5YBXxQ74fvRU8HEMTcgKc1747fyFlk/ZlRVaNgqf
# DATA sswery4zPZ6rXlGUA3EtKy/xR2AfPoYBakKpsAKH4ohheeSuGifYG+fd5fLtM76LOiGIkGHcE8sTx6a8yYwPz7F4whholwvo97K4
# DATA X/8SqWxaIu+HSrkOw8dU/aQIl3I+KNQDjDQnsTZEqC/2+HgXWsChCBIKGFC1Gu7feGaNAGB281AWpdpIQemK/t0FtJnFhJypmK6W
# DATA MHcujMnL4GezgnCONudom3e02VXK+dicj+2Mi40rfXKXJDgtU3KZ6WEEROWGjWlcbM8QanBJ5LmcJ0vvPYG9z5ussfzU4n0zPBNW
# DATA v58AOstCMd2VdSmjxp2EOmtsyGE70N4yA+7ieYHatbfdHZ0IuJMAMsCd+m4B7pZi43y5rMFx5Y0hd7KbB+5CfBDGmFCQoVLMeTXn
# DATA QFQPZN5DHcKCz65ZZuwXtrV7B1jI5P1FzfJqL5/v8yOPw6foiXrWU/TLmsdq/NjbdPeh/UytvMZNuBJRp01T7KYlS236/ELqbNfd
# DATA wYBC8T4hy3McHpZsyWel6yydABxCB7Hnc0sLEgWL0xvWJjRNUqY7Vp2ps6A4YXrFAzcFbdzx4tDgvkU89srdr9W1+cVq25nHgEsq
# DATA sGqlzPXOauHUR800/FLtye3mayr0ppUMO4WiVdgLZOE/la5vTHEcylSRVbMnswSgd1nYjlPWT7UEsjeAyL0gxnOGkKNeJOwmQX9q
# DATA IeTe09eKx3979MPxl8e/AUTu6A+L6Lh/Wop/oy/f0FNfHX9x/CUue/TPN3Tx9/z31wDH0ZXvjr4+/juDhPv26BulkA6Frwm0U2nI
# DATA dpi4a2/qs2UeeKbOeP8u2A+8+71IzmKJ6L3aV8Kz334SheMedSD87SBOhj1j/cPzPZuI7xSuBHGdDQ+ZrhvDpS0UUXYaZAsUqufB
# DATA U+FTami9tQi51yGgwVoTHv8tPAnHkctmBKZTuGqO3PKiuTyY3ICiw+SCDE7N9VVfPwkmdy8QSfDLAMrx5iuyHelfGhPEdYXRHA3G
# DATA AeU2K7oLB8pJngVs5ozRucm8ykyntGGjJlMj6aDIctEVhRf4aHhDv8vW9t4soEYxDalveyNKnxRg/dDT9x783EsnoSJl4Pg7pU2p
# DATA wszYBoJrcboBbW55HV1t4ixtg9cFO7c8MQ4956yHS7IeNJbuzEbDS+FCvDqD4ZLshY3MhVNaC1dnLEglXZYZxlC4ng3tMih2VjYA
# DATA NIdF4l44AYeKTBkzUJsc4tn8imzpxqPRDN01FvDewQyiyw4LlhRJKV+6oT3iJyE7KMT7hwxL1WZ7GumpyPh6P0r4FG2abky4A0gr
# DATA Vb5ZDROjDNknizARP4f6tU9z5YgPOPCOoPfiT2hE8zh5XcrAuD8teQ91vOWAgoKFzTuBF+wWOSugEWRG04JJZsgP6OJAOnhAmRx1
# DATA xXvMaR+Lu4b3coZj5ujghDxaF0BkqkpQrjrmnWPeOebdJTLvNhy9znSwa51ZfuUzjYvwqJ51nuEAeA6A5wB4DoDnAHgOgOcAeA6A
# DATA 5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoB3bQB4Fb/aq1bODsCrPlcAvGUr0BtR8Cxe
# DATA XCXD0clptCzfm3MKpfVWLrtq9XazHs6R1SoVKoDaGrKa9er2mV/dqnQqjerZX11pnPnV1VazU+ud/dXV6plf3ai0q7Xm2V9dKz+z
# DATA sq41n1lZ12vPrKwb/jMr61y7breuMsNz7fp0rz5vhufa9elefd4Mz7Xr07363I2r/MzKOteur7asc+36ass6166vtqztdl2pN64y
# DATA w+12fcpXnzfD7XZ9ylefN8Ptdn3KV5+7cZWfWVnb7fqKy9pu11dc1na7vuKyttt11a9dqanQPvOrz5vhdrs+5avPm+F2uz7lq8/d
# DATA uMrPrKztdn3FZW236ysua7tdX0lZ266HStmrNiuDeqO836y/TV/zTodmp1GvdZc+Vqs1+bFqY/GxGhwdzdOYY2oCYsHl/UYuSL9V
# DATA rVYWY1Iv171KvT6olEfVulceVMpzudGph/VOcymSvXUmmno1o6mLP8eiqbfKQVhv5GnqfrvqV+o5mvocXx009U7Y7vYzmnq90mjU
# DATA OoamHrQ7/aCc0dRrfr1bKV86TZ2dwcUOb9I3nk5ZbNdY9Mzb2hKHtf3MPBDdLMUtW3bTGzWavEET2zOZib6427EBP6u8hg+CbbYt
# DATA o2Fty1gJdLdCXc9al+JSTsu6WXbRNYKPJQyCXnxwq00/4k/ZU6X4eYleNYILbMUSbGUhuPV5mAXoqa2mev+aLFuZXydLdh+otV5d
# DATA w8wygNoLmnm6C3MnCvLL2+XVsHW7pNa4w5fVNXZys1/dQdUdVN1B1R1U3UHVHVTdQdUdVN1B1R1U3UHVHVT9JYOqZxaj0m7Y3jH2
# DATA HaXaeyjaH5nwx20hVnGXzbby8JBx5SIqUhzFvXBX0BV0UbbZolFn10RkoggbZLdSrzfqfBWzPJFNS3c1G52nxgpxrn5Do9SAdEQM
# DATA LogphNl2WxJ4NFKwkeyXhrwgnvYQMhcmvqCac9sopTRUh9vlQqO2A+MIB1W2b/7yQ/Xfrd2//hH+TTiYj27uFahcLU47l623CKeH
# DATA qsDuZ/vBOBoOg1uVwmQ4o2l/eqtagGTcrfrnv+So8DTWxOUjjad/NNvbC1MZF1mAzHt4971bBhvfDaPhNt5wYz57flryW0yTfyt6
# DATA XaD1r7P8T6bDOxeKBCACODTJRxCaHz+JBCrvlyo6SHTOiiWCUUEEL6CpJ0KH/EJVZ6CJN4U835TMZV2DREkIki0KSM+ZkGnI0tXX
# DATA 1plTnMFRf4Ul+5mZaEAibU6elp7OKvnObYwscFzNaeRA7EMlAEoutuQNx1gGgh8X8gIdTqfO6dSdRqduTszFKdY5xbolmj+rWRbX
# DATA RcnOmyRop6yhlY+TkbK7m5d025tBGhfCTKu02xTYYgzebNSNVNCY37EaqxarYhrtvCRdHq21IEdn7htU7jzA0ERdi464eMO13NQv
# DATA ZNxWimkZ+Qo2cMyEemAAgbrBMk6RVfSnLFAvwaXQ8vVkzNdT3dsQi4XWlFKbA2LLs55knCeUrSjOIbTxKSkRjGvNIeQjf3GfoxM+
# DATA BURNZL3QU5mHaaRapdTH6X5D2UUst5cp3aqhUaf/kTGkPG1IQbEOeB9RKqb5sFBPVA5FrGNR8n6BkXPhke5gBt1irT+mzJWSx5OG
# DATA 3EAreGABoIqntpCjCmcWBRmXUOiTnht9LGNWIkSYQcX0KnOWIF2XI3dVFy85onp1biwmN6bxRLENuK7ECavJQf0snU0wQmPLMfSc
# DATA qa51w57V/0+DJwJXgFXI9gwmX5NDVah6cAkOgsPMopIBSGIPX7X3OGRHpo4bg10DyxRjELE95HDdiqbrks3vx9s+iSnTOhgMA65z
# DATA NG/QCX8XHhTPsu21KiDToPJ6gUJDZdEuihIWtiZcciwlF/SoC48M2UYJyukEiAydhj/pCUYmKKdZNwzoDLJWZkw1ptppU05lA/U5
# DATA w/iQvb7zkDVRBnvxBc6yUccZqM5APY2B6szRl8ccXWlmXnNhZXuBfxFhNszZqdJi6O/pgAck2CrKQs0eYb0ehcK6rvLLz5ea6ElA
# DATA B2srh+DmeIvMnVepg55vqfo4Wm6TV6s8t8lLHTULhvxtWXtZPCYmrb8bwy0lbzwcd3V0lPrSnZ8tnDJjDz7ZPCuEvK1n+Qunaw4C
# DATA pjfSaK3s15XNONDK05w/2hhjg225eLOyyrQ8MPM6ZhPLljQMThrsYY/q6YLBfOUNzLw5ajn45vAV83Xh9VmEmr+oty2VYoHYdSLh
# DATA Y6xeXKCIJCGZLkGHrG4F+Jhr7zj9Kk1BE4AH1TuPRgL8ptw0NGRubqzlGygi8n5+1sIy4KC+T8J4MqQW+gGveyAvsvkHq5kp4qLI
# DATA JOd0wvOG4zRAxdWgN2MtziOlOcqq9HR01eTPGPuYPejyVMw0mWFgJ4TMOBlLglmK6qpUaa+J2IOEjMjudH3E7vF6g5fC4j/U0VMX
# DATA ZSbNFrgXoCpxHiEnDxJWzY4PxjRlo5+iEeTQdWVdGpt7MtlbjM1LKFLsuMnOij+rFT9f5Zyf2fmZz23Ar5wuXJ6f2fDE53kcBqt2
# DATA LTFfV8Ff1iu/9MP9pxPZt8Or4GTKhPEs1b7WE3jGWTCm37MuGYBv6yQAs78x0NgY/R9wN4iI5QHG+oaMsWymCfNcYbXKjt+U4341
# DATA g1itw8s0jz+uvhelzmYb++3XMIoXU8Zr6SZ1+MaICWWYb78VvX4iYtoKJp8H+qKJZ+2kYqmfgjPNq/4K+kdRlQvYE0LtlTJhfaTN
# DATA 4xZ2Wl/JeNMnRbe6aWx5I0fWgY2oY6C+Yy6O2J1jo8anvTxnXL6b2N31UrKY9DKNHdUNmNT3NSqZO4gk5DUL7Zl+fgHVZq1AOuBh
# DATA MBvTfAgLAuk0z6g26e8BTsNmF68RWJQh9OwJyMxASEsvU/Lu4vJ+RPaOvUjGllD4tKtWMzxZj1BHHfqKmokNHoEAbA5TbFjjWQfP
# DATA 2MSI4rUKZSglQaToTWBJBxPpqefKM3OgqN4x20SSy1jLPWKQPItc5KzYJY/mcExLOEy8wjYPYmKmVS8OBR+lZn4eOFEHqGSUGYwM
# DATA 7U4V3seMQidzsl+0WZMFzJ6lURdenii2kNlH/+34q6M/Hv8jqNZHfz7+7dH3R18f/84DO5t++Jejb49/t0jP/i9HPxz9he77+6Pv
# DATA j39Hdx/9kR7+V7r3y+PfFjz69AM9+YejH45/A4o2ghaS9pf097dH3zJH+wt65J/pFpC0/+TRXeB1/5aC/ZaC/RpPH/2eovUnfpKC
# DATA +D39/T2w3MdfOLr29Z8QUicWj8IiyHKCyNLcKe6rutRMAcIb8jIwr5Y/UCNEoG3agiDB2DlFZtxkGCpemKJdUe+XaKg9s8Eyo3Ut
# DATA RfshHqI+KHTo7Nx8L+serhqebZXI5RGzVa1KrZkeX+CKmc7f3QmDrLt+nb5wZeyENNZfJCqbwmV2daRHMrW1YmFS95KysjcotAsn
# DATA Zd8bxNCpDwAxpzF1rO1XymB2OymiJPcmVG4Le8DF50sWC3VS++HwNuI64G1SZN+ltpcqSKU31JtTTlP/VlswWWt6VuzrEyPvsNdu
# DATA WD/nsK7x1qcbzV8Oz+0VjuQXOZBvNI6fahi/klFcaqJJerbb95k2lcsAVJs0yvbQVcnjzlt5fLicC7KTktKwx1IZwXQgaehjI+RA
# DATA lmxl9Zmm54GQaZPB4XQwygrM2gsZ6NxQyGIMxZsQqd+PPRNdAe9q5jLHZhx70mqWw3lL3l3+kQW6UyETs6KzLGGpXhUBpdN4QtbW
# DATA QFFwp0EHGSYH7MR6yFJlANmUX90oFX0KnaVdOCMcX9rxpR1f+hL50hsNKRvNVzY0fK/Gdj+L6X4BlrsDSTuQtANJO5C0A0k7kLQD
# DATA STuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5D0tQFJ1yrVoF4/I0i6X+2X+/XnCCRt
# DATA Vpw3okfb+QEXa70+aJQr+9Vq+W36/qv5fAzr7SV4q5bnt2qDeq2x3wLeqpV/rOv3mj1//rGRX6t7FXq0Wi76Ta9SpQ9etVWs1bwq
# DATA /Z9+axZbXq3qAZ7lF6stvlbB7XWv2vaqPu7G5bLX9mqtYsW338o7IfNsq2qvHjTKy9hWS+pGHfFp7vuVeUBbp9HxO91lodQWYHw2
# DATA Ja2aRwZLuBbAq5FV32qeZB4G9WZnIYaVSuP8Maz41SyG9eoFx7DdvoAYthpZDJuNi41htVk5fwyr3CQuqZRr1EjOHcNatXJ5pVz3
# DATA W+ePYb1cv7xSrrf9C4hhs3XBpXwakJ4MQhqkJ+OZBdJr1+p+tZ0H6c1j8/hKMA/S6/faYT0D6TWCethsGZBet9np0RzdgPTaZB1X
# DATA W5cO0uPtn8V11n2pOsen+9x6aJFFl3MJ+a38rEdnAttYcNlS3mPT43ax0gv3dnIhzxH63gppXI+CgsR93vldZde3LHkznG9+/V6F
# DATA zJO1TdfUStp8Z39u1Uo6gvH0xqOc5W4cCzhioH3h2BhWPOUSUG2ZA5r9cFZ4ygu2iOdTtSlfGigMyyvRxPLK8u1QC68oIdZks1qz
# DATA fDJRdWOwS5is4nq3vRq6l5VwwS6TNbOIxdqmkmtVI+XsXl84PBVArV85jcoK6nTzUQcBdBBABwF0EEAHAXQQQAcBdBBABwF0EEAH
# DATA AXQQwJcMAoi6oCaKu2ydFgIc+ixAwjcpsAxb+bbkB58O25XaEvX+1138WERtuc2BiHjErhre1FeK2y/LhUqhVmhQHxn153tIddvO
# DATA jn7c3H2bX2cq4va4EIH/Ntbd3q56wur1dm6P1+YSAHJ6xMrip94jo+TT3TtP9RukJ6Mrys59qroz+g/0OnuOMcHRse2dz3I5eZsP
# DATA AWtbkTN0Zy5V4907lCA+fgljlOftaH58Dg5JKMnJT4X5o6C5V1IQvB025/LT0A+31Hk/dBRZrdylUZclZOWUMdVHYeA9lEPHSMKE
# DATA OljG3JmETdniBXLvR+rtO2L5Ly+bE1Iyjff2hrmUFCJq56hFkiQO9Jf4/pEpAgVUjHe5VmrbP+1C5xHJ3Sns5X56iyYRVLFjGrJC
# DATA yphx91AKjV9Dbyu/5rfKt6rV8u290h7dC2PxF7jhLhv12zi1UFAByjZ0XN7Rd4dPJ/EYgm3B8GEwmjyO88+W/cVnb5TKDUSIEjKm
# DATA ItreQ2D6i9wNJb1ozCubuJM9UNvyKZ5sLwuxScUkBfhAMpMFEwF33MaHGz4zG+O+1+Ii5cTrX37Sus11cdeayKCkC9UyVuAEAAk3
# DATA Ssx17XM1J2FlfI1g1NXhs6zu31ZV43PdBngKPMV2Iy7Cu/d2D6IxTaxKfKqc6+XT6a9/rS4ehJ0n0dT+SXqLezvTAY3T3v0k4dot
# DATA R9KtcRrp4yySevDrX2M+ePceRSg4CCKa/XH2oZ8eYZxcUplP2YriidWIpH+UhnL7c57t23kiZSRxzpsXi8fXRfRIFHggfSinuDuh
# DATA F9I0TbdN6nfMVHZJV8fn46IhTetynR6KzDwmQ96OFUsKVJXCkiCxxk+PmKCs5zhrX5NWL8GIT80cqnVaNk7LZpmWTf6gtRO1caI2
# DATA m4rarBQgvyyxm/tYd+HRFWoT49CWbdHCN89OQO0qVMbFFKDLj/HB20ZxpDdH0Xg2DU/SsdbPms7JXDCSy0o1fF4SWvaGKE3oyjoJ
# DATA a33Ml6LNx3WhGH+ILovzO2bhDCodXkAbyEoTFycFIPfnM8asJ1k5YX5ks5SXrCVveApU5jvzGaE9OFlWmFuzpPOD/py69fp3+Zu/
# DATA y89nMx6snOpdlc3fVcm9ix+snupd1c3fVc29ix+snepdtc3fVVuQWr9TP9W76pu/q557Fz/YONW7Gpu/q5F7Fz/YPNW7mpu/q7mg
# DATA /36nZd6l9VVMG16prm5PX18AMXU9VAjSRSsRWaMN9X1PBK2EozM0lZMOTEZIzB6ATeZJ+ghSS0muy5MQ/IJXLXh1Ho6aoGiFYxZS
# DATA 9bCDgIMWoPDIkMCsiNFAtdx/6qF/ZZiBJftlvO2ZqhQNU5g3aEUwDIIIU6zG0+uBbSBl/vyLCTloq5s6rZ86uZnSizlTOi2I9ZnL
# DATA gvLmrmyf12UgPC35zQvmdtripUthnStxsqwhyCcPTUsVLgpkxtdgZa+BOOpzIha4oby5l+0c1MaVeC31fFlO7FDu0GQaKppQSTKG
# DATA 1l2l0BokLHIFxygZQ3iazCqyr5h/ymsvItY6kWk8b+2CDiPm6byrqYAHVEFlyo08oadCiob0jn3sRBQq0B7YZCw/SS9nRg50+bQY
# DATA +ulzEWYfa0bOacdepWT6s7GUctXSGUvOWFpmLOW6KudmfundzCuNrGevqa5rPlXngGWlD+EBGNN9vBkp01ifJGiakAGea2R7M5of
# DATA s6s5CZUG9oK8NzUXowBuKYPHaorPdWjOsZyzGhZF1M19NK7qZswjEpWu0VfGsBn3+16wH0c9Xv0cx1HKLvFEa2pLd5CBx7OEaUW3
# DATA kveIhmivT6GJiHrK66RylBiD71DikvL+RQRyaLTAqWeZdVJq9LOpGG4sIwfmd08T4RDjkvee0tn2RlE3iScDdsAofFwYdNktj+cp
# DATA B6Bbje5ruSc+c/cEbGuMlRq8zpRH4VTMiDSTfh7G2MgyBc1XNuBNAoYaWt2eBuiVvLvITAo6mkwUeBtBsEvutoeFbVxl9HYgd9ll
# DATA 7uGMBPriMXJHo98l3Zwq74Dexivja5L3fgC7RrjFe7FRncdVNreoJGAWSwFr7DyVulTyaTyKkyQ+UPreUv15lVwXDVd9TzJxjH2d
# DATA 8awLDRjGoIvvKjvEm6VNGO4Gmk5FhYFPUZbXpedNludnzxgWeBYAOUOy6HgKEsJaFAtUKcLHGKSmPIQNyGSwDUtqk5g0sKmXimlI
# DATA t/dxQh1NwYyDUh2AQxRMAF70JGT4PGoeZeNIConJ02RZ7qEqD0Gip8jMxhiYsaYUT9L5RIo9dRIp6HWp57xyhfhIjkouzOY9wog2
# DATA Dza5jbRWr1vUjmMMcyu9yuucyPmFElMKazIv8yvzK8/5Wl9eS79IszKN72Jfw8sl0mgyFpYwC7gRXezbeMHkIZesqaxTdDpWJ4yW
# DATA crFv5aUT7Pte3TDzL7w5G57TF//izn4yxCW9rRfHSWrzLf/p6IfjvwWQ8vgfmTv5JRMuvzj+3dH/AFHy6NujbxYBl//EBEvgKb/w
# DATA jr7DPwyz/O7o2+O/9Rh9+cXx39Ofr4RwqQKmFzHW8nsK/Jujv2h6JYMx6bbvQLn85vgf6Lc/OYTl9Z+3PZKZVhLDSGJTGItG8Wxv
# DATA MGVGjshMq+F1GE2hriGniM1EbDbWtguZUhj1Aoa3yoDPFkwqMzdgUGAWBnwGdS2/8hHvuKC+MBp6n5DFyEaUI1lmczjdC1w1xnJp
# DATA wVwe0JLrZWrNH3U1FeRR/mZUVnPrA1VzMbxdJM2SjFUWUlBrmLLXhJrExJEsNyitCwdZ3lVbq4bUPA6LB8HwSUZqIrMavB3gf1Sy
# DATA YOt2Axw3olE2gTybwusEPYwQBho1DkMy8rEAT/XykOcGioKE8/OTBZLlCTVvtVmyrDk9K6LlCYlwPEs3xp9njNcwy7MO7S+Fa/bK
# DATA hvXLGdU3GtRPM6ZfwZAu9XJJDpgB/Rm2n8sgXC5JqkfzUPrE7LlALZNKchHLAq9zBsj2qItxFinm5C6LMm98Vg8nsYACpW/qYN2c
# DATA 4xtw3MY51N4mcMucoxtRUskw2p/s7sZWP++A5thYAxblg1SogN7P08yEkpGfLDfs8u5TzCIYAoImjMa8tmRol7B2InmB8gyj0Hgh
# DATA 666FhlS+1V5IY+QoIrPhYBByLAKPTRPeYNcPHe3S0S4d7fISaZebDDEbTWk2somv2rw/i3V/buPeIS8d8tIhLx3y0iEvHfLSIS8d
# DATA 8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y8togLyu1WlBvnBV52Qrbnf5zhLxcsvJ8
# DATA WvhlreLVGg2P8s3zq+WhX657frP8bq3Z8pqtYaVV8aqtOa4l3dtZxGGO/HbVq1BG1/1ii/5ue+1GsVYv+n6xQuHXf/VezaewW/Vh
# DATA o1r0y02v1fT8SrNYp1tqxSq9vl2s1IvV5lyZ1MNmp7fIB6xStJuf+vVysV72Ki3fK09r1ZZX3m+23q5V82E0uq1es7IYRqvm1Wvl
# DATA T4uVcrPYokhVakWf8oJiVEdMi63mCWRNE7kFjp7fktd1owSzpS4Xf4Mj4XW5aH2puYmACnPx7dVbtVrtDLQ8rr+alidNwaLldRr1
# DATA sOpvQMtr9MIcLS9s9urtTkbLq/cbsK0NLa/aqbUqGS2v1az5fnjptDyu9sX1hgF79+d801RUOHv5uRWAtg1y7DRJ9CLOTeXrov8P
# DATA f6iF3z5pDWG5sbMK/mbF8mQKnw3ZkwdPB9mrLUL2smBOAdnTDsiVeWTntMpQhbFT9c/2GFXYTmNjwAxiK7YR6LFbLXCVV7Pvsnwt
# DATA 2Fm1xpw4IScM0c7B5xx8zsHnHHzOweccfM7B5xx8zsHnHHzOweccfO4lgs9x2nAaoahtHkrja+sGNEYQSQ6x3NDS/tQz9DH0BsPd
# DATA O9vDBb6TSvGO7sheo2CefiTTml96+LBzY5ivZFzzd0qfxNGYAviQ/gMf6rYxLz/c0sfOs7iUpk+Rrx9uvbFwIl0FcAOfNSnqntmh
# DATA oEPV4CfNVnIK4e5g9ZqD1e5A9UtyoPq0euHP9qA1+yUzV9oijmiY08Lci+MezhZ77Cc0x2yZJIFA1uhsP+vz2c/DGUX++4K12pcd
# DATA JL9o1fbl5/KX6rdvcEw+89Ma/fBQBOpQ2lp2UlUOozHzOKQopPEohBAMH62VqsYn4JX7jYksohuYP1+enRwvQAaZbM2ssfOcEXqm
# DATA 8ADH/T4c0/pAs+geInCpavyK+cPnpxERX6gmciA3yKyTZyNW8yxOs5rnnUHlDKolanRZhXKCNU6w5qx21Ep77XKEbLhP182ALCnR
# DATA rmANjEE8jfeSYDKwRMWfmW7aBQAsaVx+Q8nQWKPXKTWLxRhAIBcoWKzGfj2Yj4IJZ4415i9Tvr0Q1eIPWN5b+kaqjVBIQc93CcLF
# DATA b8JW5xeNvfAp5aOXji9cPphFi98Zp7NhMBX18kOVvAMkdEKdeN+j/m44vAzZ4hlrKk01d2bGGuBzreFi31sX5WlIfPc8EaHX4xwN
# DATA fxf7LqY/PgiTlKWYsFLFfHuRhWG2UTGIyICfTahBhhesRt3MOtE5C5qKMwAPVhggYnBfsET0HGsym5ZJkHnHJD2ktYK80aExP6S3
# DATA MTjKDABpK6qb5aBMUR6TA7v+qCZ0mKlPyYAmJ47SFdJSXQAWta6UpUsFVSAWl/IeQeA7HHsMXhl3qaC0/FRfUQ8o7wtGIStWvbOW
# DATA NMXC06HWSuIZUTLrdCCSz+XCTGJUk3jI+GIZB0TjKJlByMvTmWZ0vJR7M5QXmMXuQOmmboZ6fHGmH5ZB4SYgbgKyMAHJW5huCuKm
# DATA IPkpyMqJxbPW0lS8DmZaDIIJw4YDzDBscew0VLp7WgpyTiySUTtaHVKhj0KZzFg6j1NbABJj5fAA/KSZ4ELmJR6lxc6oKVPfRaWw
# DATA Hy5RetxUbZNTO7nzJi9tZvHuHGazI+Yud2bRsGe0+FRk2NG46DZWh0ctAL1Gb8tqPwOr8ElZWMoC0j9m8GxzhVUEBsyK4Z5NFmdl
# DATA 9woN3VZS8hBw9V6zhQBWqfr8qmyMUC+37jA9q/3UqzH3sJnhhzV4jLHUbNR9bFvGypE7fztNUNVhhrf40+o7u8No1OGI4sPq+6hj
# DATA jrEpi+68Lx+ze29K2u7MYcq1rSmr8bapiRFljaGZK11sBpZmr85IZ5ZzkPTM9JQ3P8hEVeVjPh/mwFy8k9p0B7KzQCa2M7695j0Z
# DATA mWTMx9tkKpQjq3ceRsxq6oUME6LWWhUvwShOp8NDBb/ET7ASjRQ7r9UIrysaT2UIDEUOE7sk00Gs9EQDgZ5r8VgGio+N1Cy1XJ4W
# DATA a/e2ksL0YJkp61Ad1LraDGycIgM/oDnxkH33UdKl6WKWhZijUscAFJfd0alZDjwl1C18orboUE92j1cJ2DbmvZUw20dxB49Q7xdK
# DATA naaieJLKopmigHFZXER2Wa3klPnVXptfpslJhv0Mkp/ULvZCk1XwJvA9+TwyCC7JyJL3AY2ZBY9V8iIywg6V/0lBxKg7F0qc7FYR
# DATA d5jmzNOwwRi3sHcRWWU6nlNmVHNtRqleTLLpbfhxxJyPxlat4ldThTigWKbsiAmSoVo91b4ZOBGwDS6AVq2sdPE0Gz/D+7d3mPkL
# DATA QywBYk++kHMBHOM+j9shJHUZXcE3PdM2WT9Fm3wXIDr0adTuipTookCuTG2zL1NzE2qdykhr5S0M0kMs7mkiHD1CNr9ID3N+ii2S
# DATA AuNlzcifZQXzK5vXsHdjKmIaI4fhIbsJsjo2pF8yC0d5d8XhR7NbaoLsicuMNWQI9fDssNKLqGpRVKwtqAPjRE6s6ihZK+KCAo0w
# DATA ibpL8y0/EMveOnsgNlckG+68H+tdcFp5mk0wtTsNThFVkooSrfO7dBJD7EVxQGQssUk4BZrXRon9dwGJeUd/PPraY6wX6F9/Of5P
# DATA R18f/eXo20WM2P9z9M3Rd8WjPwMAdvwbAMj+Fbiw4y/p+r8cfU9//57+/uHoD0c/eMdfSegI+ltAx74++vPxb4++O/6K/v0d3gQW
# DATA Gb2ZwviaQvhag8n+cvS1o4k9BxTosaz8YB9PV6nUZxToSRhPmN/IgHUe2qntiYHYi6F8zt5GDDSWS1qJ4fJd6KMzYXV+A/UgkUjI
# DATA s/N4LVXsLZhLzG4fHzqcmO1DUR3BVdPE8gVyuRixaGyt4d7XtVT/ssgSG09xCND0sfgqI12YXCRPLJgKomAQpDScwoIlSzfu9x1O
# DATA bNNSu3Cm2L1g2MWqYygLYIcZoDoY8U57XgIZ8jqJ18dUwmMuHMv9mVUOkHRHo5AnvxhLeB0x+lXI9A2vF4XTJRixEyvdausk15ae
# DATA HUPsxBQ4jpgb3S9idNc8sVMP6i/FoshVDegXPJ5vvBhyqtH8igZzqZF2HmTbrZ5907kMlJidVnEMqx0cg5iew+JDPqFIgYmlLiws
# DATA Eq1J+jtgsA8nqVCVOGnTIH2i9qogAtEYJ8dwjE9lyWYoMQCMZKjeB69LwZp6GdlJqo0M611tEwA+FWOjHWwCrG1FZCAssQtm0F2I
# DATA psvsAWUNMPgIdgBWr9InFJiJRwTnONcmql9D7NLGHrLZNImkzOJxN0zGqeOIOY6Y44hdMkdso5FmwxMYGxrHV2bkn833eAEmvqOJ
# DATA OZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mtj1oYl165VF
# DATA 0tWmNLF+vxa2niOamL3sfFqMmF+vetV289NitVz0KX+a1aJfbwyLNWC1/E99v1qse36t4vnlitesFJse7sIdfgsYsHzW9frtdrO/
# DATA QBgD4KtWbnsVeket6dXaxTZdqHitBoKse3VgvDwfYbfxumo7H2y90eq1+kvAXNWyBeaqtOsGzOWX8/WhU2vWwiUB1GtWAFWL7NVa
# DATA rBK1ZWSwSvO0z1v5Uq02vSrlQ6XutYr0l++PKjWf8shD5pY5i1cnxC5FurNWrw/qzdYc6cw8sEA6a5yBU8Ytw3DKuJFZnDKqR81m
# DATA sAGnLOhXc5yyfqXX7DYsTlm70W9mnLJeq1vr1DJOWaXVqDaal84pm4TTEyllGF/0fRtgvixHWZXdZKUWL49hSNtZJIGZkDXmLDfT
# DATA rdV/4tXpT6XOTsccmktyVEJQEd7MqaZSZRxrFTPdnXt7pca+QHbjzdk24nlag/DS6Srk4rdmCM/dpl1gDtnlkF0O2eWQXQ7Z5ZBd
# DATA DtnlkF0O2eWQXQ7Z5ZBdLxmyS1kcFoerFxymu+8F00GpP4xpYgOz78MtHMai1P8UJs1NdY3PR+GifKVpFgxVajVsfX64dXdCE7yn
# DATA cFGGw0PKjRsI+gblSn8mcmF8PKxv6Vyps1a8igRSFpBa+jBXoA5nQYMMQcqxm4APaeOAijmDJXp/jrLljh2f9tixO278oh43Pgte
# DATA 6xocQ2b3nfZ3radsiYCViffSo8pL+FrX5fDyc3WG7zKAW/nj1hdM2pqrDGdFbFmO1OwQucrpDAsCeUYRkFeqK5xdg+qdN3mCz7py
# DATA WoeOqw+EQsdKb04OwprqcxDQE534AKedw73ZEPJ9WnZuBDnRuA81/N4s4QoaJCMtfa/OxPO7dQTukm0dkfHL22Z1FDQljLKnj0XS
# DATA DmtxTuEn8nhzilgmWGodctqgZ8dtAScqOyFe3CObbJZ0jPDkS3LU0wrD2VXOrloj1mZXLqfr4nRdTmtQrcFtXY7ey9+M4wN0/6I4
# DATA 0An2RGMNkhtqYPOvXk7sAuhavAKhdoDoazlteJ7o09Wfj6G3ECoZFuMW87af7O3MkYDGvA6UgXZUEKab0t9zOCRKNHXJ0JMZRSxv
# DATA Wy6hz6aeRbbkiHGEvZzZjyvk7MUPAaCPLdgywRZXGuy3T4yvfj7rV/WFDMLVKi+Lsx1jbNexo7wmwuwpYUoT3NWZjg0y6oS4qkdN
# DATA VPX3HC5sbTz9NbGcIyip9SW0VuV0ETVyruoWJQmV6s6rstdUxVOtMdpavtkl6V2ifUkBjb+K2XpTgjgfBcpiNlnt2xY+Uvr0CvES
# DATA oNkbfcD7cD3ZDZgbNGulhE8jUXHh4Q49jnZBfTqjXgha5elsby9kDzSAEbwyoTqIOAHGAlAlVpXGKMyBjgGoGGoalzDQ2Deu2h0E
# DATA VMiUn7E/nooGejBQCA72DCMWClQwTlMZyXtRn6VTpqI/xMrOntrKG5r4iBw9pIk4GkvUiTJJIpZVhqcRkfGCCdU5DHCbsp1eEGM3
# DATA N4I5c9eZuyvN3QXTxlm8zuJdbcJeE4XDe6y+B83iPgaZaMwyZsv5Tpovm0kBJuEoYkRHYZXq3pvCFFwYbljYbG8W9YAzzAZGCo3a
# DATA a28GACEPb/MmcB6asCBwaO6jcd0wTbXviYf6nzMnAONZEtPQEUz1mMt2+Iga+AwmlLIDgr0k1PjKxSFT6R9SSD0aqk1y4KpaGDhZ
# DATA GhDiMuw5ClkTzgumqNAU4ds2tV2TIcOnvD0K74gANaBcXzEjEIm3eJ/3NykGp+bnTjTDCxs5BRTyNEy6EfY75iCokuFcMCzaZwkV
# DATA Ki9ZyXsLnC3uRtmbxtCuAWwuvosBJiBWwl33bjjlfpaTAdMmmM7523BwzUTW48MNYJ+sS+NdLUdp+nudyA8wa9PsHdX3Q2WyIJp7
# DATA GkyER7D+SAU9TAtMx0gNtVMbXWImvY/A0FMewgRTGy15ZEl4SOrA0g57UTeQElT4TGTlQk23MGfhUxrzhofrUvk+Hyk25hfjS3Q6
# DATA 7/JOT3VIZJYU4ElmhfGRLn6ePipSTgT4iTJfx1DiU+KfFiONk5RXqix5j8LwCVNC4JZlngfykm9V1UIrVub4Muw/FW4I1BbhINaO
# DATA 4iDlSW2wN47TKF0gc7AhdpLO9+OYOibOz6wL4lZzalI0+7T1GHQhnGjLza0aA9zb7MS+BDL0e6i+eh8MNdcAVVf03/U05RIo0fdy
# DATA znK0WSpvocteAin63WjKs7KEui0IQQoUUjFruOcUgclLgEU/GMo70UFyarPGxdOs3iWAou9SB6RbPHqpntHX5SKFtyjpXTA7+UWf
# DATA v1lcHHpqmtpYnP8KCM7R90dfH//m6Pvjfzz6xjv+Aoga+voNXf72+HeLZJx/YtTNPzPUJn/30Z+YkuPRT18e/f7om+N/UKH8Z3Bx
# DATA 6NoPx3+LJ+hVv6Nf/kIv/JN3/Hc50o4F03FonOeALMxgNqNdK4wseH6B9CjINlThAve52zoAlPtAWVR7ISsGP4HDWXDCU81KZMgo
# DATA D6JgCO4N1xNw3g2DPr/F4W9yc0xu71dNv7EK4/LQN5K0rFvkutPnedj8rRg5zI081UsGh9PB6CJxN7zJlqY9A9T4Hs8IgNzjrZi4
# DATA 3WFvTiyxC+fdYJIbdzDH5HqmPdbYKaKmw9y/DINkpJamsslnlIoremEPteins20rcwkqLerFMK0j0wUO7gX8zfr6t9r4yNrRs8Le
# DATA rI+5I964QfsUg7YG25xurH45fMFXM05f5DC90Si9+SB9+WO0VD+TaDMgX11buAxSjUmPEJLT+YTo/RfZJga2JwbxSMNgrDKRmS4N
# DATA aBjsgh4nlCnohkiRKsZyN54lwqbIxledcDnKTi9BXnHwm3Fr1BQ/NwYHxrmuR28zbqd0Y282DPWWSF7CglfRSydhNwrTgol/xi5W
# DATA jtZhJK7XkDrboB9OD3OuQJUOxukyJppRwF1JVD5BDlDjADUOUHPxgJqTB46N5hyb2K9XY3+fxfw+r/XtYDQORuNgNA5G42A0Dkbj
# DATA YDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5Gc31gNNVaWO2dFUbj9+vPFYzGLDef
# DATA lkRTrbS8aq08YPxMpeb5terb1Xolnx3dfqtcX+Sf1CgB1VrzF36lOs8/qdW7tdYy/gmXUj6YarvtVWqVf++3K16lUqY/Ta/tf+rX
# DATA W17L85sVz6/79K6qV2lXP634jaJfpTIEMadW9Bt0S5G+0U01usmnB2r/vtKmRytelUKotj714UWueTW6p9rIpasWttqN8iIgRiJU
# DATA JBO+6PutkV+jfMGLGmXgeebS2m332kF3WVoVeoZKMSLzQ7FrauV6xq6ptctWBa7Jl8MltbnXDRvd/hnYMVyRDTuG24TFjqlVmkG9
# DATA eiI7ptPv9Rs5dgzFp9XtWOyYaqPNAQk7hjqJdhBa7Jh6vVOtXTo7Zkit4ER4DJxGn2e3GsqLxXFRqVt07LFzr0L/tn5im9tNNh+y
# DATA IE9G0ti8Gd5sJ3uLl8XCuK5KS9ZPycLysFTpNeRPLjRPWTQGKMOjqOn9c+QaKeK5FFOYsIy8uvwxrlFJdgvGle3P8a01HhVEkzLM
# DATA pz/qX21hsvXKA+JKWs0GZZnPuvwce2lGrAzIQW0c1MZBbRzUxkFtHNTGQW0c1MZBbRzUxkFtHNTmJYPaaINQS/ts7by2bjRj+I3u
# DATA 9fnUhXqsgD5wadfqqZRZlWr3TqR7r102iXduo51/uHUvU/PCYRVLzmVMOaw0XTB9zTNrzMkHd27YnRu2Tr6408Pu9PBJp4dXak1e
# DATA yqni11FzoTSXBW5OFj9T/YkL0EuH1hzefBCGT/iEo7TZM2rNZWPLxanNheFQqXJ3ZJWEMkSrDypH9yXIzunzxgrcNqFS7SXQnvNo
# DATA jhQODy9Bc+6dMQ41T6WHTZVSNuzlfiZQfQnic4/Z9aXSSCaI6s2pTtDYUYT6de8SdOceylFi+ADJlFNJNnCBSylX1p57H2etAyNA
# DATA h5YnIxxMFjIvsRdqloQXrD6nPDBGOj7TZMwpA2SHW3VCzKlZyjB0AdNcD2JJ1Gei8CIBDwnVucP63BuVMnXNXnKoMzpDNQTDA3AL
# DATA RyFLyOMWLFSRoTEclrx3o75pDgXgHoaLbVGpqI4RlcQb0I9JiAWr4aE8yd3LQZBKdDRRSKnVch0UlXc0NnhzRbuaJhVYYt9XAVDr
# DATA oGhKfRnAN5ioE/HQyaRH+zSkrJIM0Lmij/tTNznGyXfeZkDjCUsB0Eg9L/EzN1I9DHEcUJ3ilkmr3CHjzsmy8c/5yWOHnHT2e2a/
# DATA O4v9hbPYT4uUfIY6QLyYbxai13Mk34xY/lzBUSB6PvZ4L+8aiOQVywddezmNy+BDZiJHFw2HtOWgzkqGtDYp6GnTQxyrMtVBJn4s
# DATA nKKEpypzBYldDVKKancjiI2vJ/IwaADYQqehjXe94WwUjeMZTRGNTTSmSh5DxGYSDoeQdscYOlCK62R/jUvezzoit0+GCTZdQ0tp
# DATA QCapwhwwz0a/3Y7GWzDQ+C5OjI7F+7CLKAiKHVVeqjWW2cUmH58fCXkbwmEKLfUgZQl1aSFa43kECetk3fvZDe3l3v2WtKCUzMuU
# DATA l6JL3ntxOtX2n4gLMftHx/o2MkjaF9hLUL6h/hq2AYTtqRuhqs6yIfMxedFFYqyewdlqzlazRwbnbH15na2rmZPPUsLxPV6s1PVZ
# DATA CbDx0WsLSglpPYYj7EO7TdpP5rwpsBuBAZPsRNOOw5L3IBMDxCkcUWkzaB8uQ3YaBJZ+IPs02XfQj7peStP9rvGsdHgrWaYZKJqL
# DATA G2pAcorF8ZE1flnrQ0zGQZJonhAfLsF74PVZYiSqM46LtEu1zo1Kyp+Un0x5svSPGRDRXOEcB3Yk5HDkaeV+iodDKwVLCZBm8Zyr
# DATA iXx+VbYEqJdbd5iO0n7q1Zg7zMx9h9VnjJjDoV4ajeAPjZU1N3872Q3cquKD1ffssdnDyCz+tPrODttprJGdiJWi77wpqcryQcZj
# DATA 7S2UFWjbz4ehYY2rcK3NaHk+g6RnnPC84C/ueJWDVg7MgaR4Z7Bp/bKUzlUomXFO3DUJmI+x5OWEDbZ7EHGMEgiZot5nZivstaLS
# DATA 5CyIxGgRMzOtQUrD2CjuhezHn8KeheGnLThBKdnORDggjVRnyEJD2sieer+iAbdk+1c39KV6ZpscWxr5pJis0RJmALxiuZsbET1j
# DATA OV3nbdlTFU9W+U5ZQo9Wl5CuxlJIjybsg82XEDVj7kjE4w7sC7QyB2T/iBs08KSuK6vfYgeaNRA8L6sgIrUaQ30UUw6ULnYwKivl
# DATA /GVjp+D6F8yDTQvmQZAMWVQ2GI50wTyK+wxjHdOoxpqpB5jk0Qi6l5+blby7+3GEmTHlvXHrF2zXN5fKhPoXTM56apaI6eG5y8OO
# DATA +JWVR9b3nrI8/t3q8tC9uJTHvyODZaEjm3W7syGryWIRUJ0kVI1DT1YVS496KV5JwHlsGjJK3tvUug4LVIRkhsTRUFSOR9yLxaOR
# DATA yD+TcTESlhj9FCEHzXrx+QsqS9H1L6aHmxbTw1mnM9+fvc4i1qo3C8efxIdZD6bFuEreBxFNd3sz6uj3ZCnKyCfrVaHMwgNTm/Kq
# DATA G8yEjnfusrCjff07sTc37cRej5Ie7xgYwwFEjWNsNZ6BKF4PZqOoV8RCIUuMq/LgUSdlwx7SQlNY5h8EmkudrfPbvD2UsOntKCQy
# DATA ntS2CWghwz107nJaTNCZSitv/8k2Rtv+M1ck7++8H+sNh1qDW0x+sbh56Z+hlgHNWJAdupTVwunlMNGea49XxkJLB3GYQ6H9X0f/
# DATA fPzV0e+PfwtWGTBm9PnLo2+O/uXoe/r794xH+5PHsLNvj/58/NtFMNp/ZYza10d/pmf/4NFfHODRtwUK8eiP9I3RZ/S/H46+MS+x
# DATA SWp001+OvsEnxVH7F1DR8H557w9H/3r8j46K9hxAuc02B97yGk8PNHbVkLkhXizk1QLPjHibVQgTT7MAAA2FO4FlZKgDEDgDOtAJ
# DATA 6AaK6Er1OJnynjE815clLOMUgKdjLTkNyvJoCmLnO3ya7evjLuKq6WnzBXJ5CDUaLYJhvJchvniHIb98nsN9sx9l3fSb0dTCd1wc
# DATA Qw2mtDq3gRoaywjO2eDwaSeX1oXz094TDLjXIeMCO7po3j+gccdMLwvayEpjHIZCRsKQRTLR3ak9rZjfKNL4U6ikhFnnxDpfBbKp
# DATA ZDkyCdmzyIRZfUxgREUkeA0MVtMFttr6ernaiJlrZc8KsLY++g6w5sb/Cx7/NYTtDMP+S7G8dzVD/oWP+BsN+KcY7y9/uJeKmE+6
# DATA GeWvV/O5DG5bPuE8SHKGGOiYSXXnECEV5AxjMpNXSVynAnRKRwEWvszSmyf9UidM4dIKEyxNcqJpoM6OLajo9aK+YbtRsg89RTLZ
# DATA kNmWKHONt9XgyAoZFOyXCLtPMDYpNBnXMeFe8alh3gkktLko5T1U6VRoXLw0G6ZTMRWQL5nlcFtRzEDPms4ohFEwnvXxObGNBOV5
# DATA hZ+AbZrksBiPHbLNIdscsu0SkW0bjC4bTXQ2MYmv0K4/i1l/XqvegdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B
# DATA 2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy47dqA2/x6tVstnxXcVu83wv5zBG7Lrzmflt5GtqpXrbU+bdSL1YbXqhb9
# DATA amVI/1QqXqvu+WX6per5FfrUKFaqw0bbqze8dtmrND+t1uiqV617tcrbvt/+tNgqVptexS/W57I0bPcrvc4c9Mxv1hrV2jLoWXux
# DATA 5Cplr1auD+rNyn618TZ9zb/AhJWnsFUoBZVG3Wv6Rb81KtaaXq3lNctFv0lfal6t4TVa9GXjiPnVhZjVfUDimp8Wq1SoReRF4z0K
# DATA ALEdVulCjhbHOznzLwv7zcYKzJ2qwN0o4RN2T6XSVzL0m99kkByrGjTyLcAESwHAsPHk6TKy1pOHW618te/3+bvuf1kOlcVfqy2q
# DATA NxTGKbFx3Iw0Nk5apIWNC+utWr2ex8bRTbVKI4eNmwPJCTau3Wtn2Lhat1GvNzNsXK/b7fQzbFy7V22Xw0vHxqH9nYyNq2qjQEwC
# DATA /cwKfhySOedfrP/Eq9GfKv1p1H9iBzHHi3tnRFOJaQFbgRFf731W7KCvdsztaVK9XL4978wTd0+htX9Q4FWyFStiKhqAV00+23Sp
# DATA oFSz8sKrJvlgPL2fImeQmPkSdlVrF5/2cuaZdiqTKvTHr2uTn31F0ZQsrG4OZKd92NQvVxbwc+XVfDmT+wU7B9aYIickkK0Ex5Fz
# DATA HDnHkXMcOceRcxw5x5FzHDnHkXMcOceRcxy5l4wjpyyOfAcQjSn8Xdh7H25Jm6OE35DvUIThbGAT88Otx0ECFVp+xJOb0bxu8AWq
# DATA Fm9iM922v3ODcqM7Kn1I/43vWqfE7/88fwyPH34vmA5KPEPf5nB+6pfqCCE73rfk0HimfAspLtPta9RcdmzFHaJ2h6g3OURtH21y
# DATA Z6ndWeo1esnP9oy1HA0u6LO+S05aPzTnAqWOFPLKauZQrxxYVYIsfJYYdvSB0mGWk7whq+xnhycnwSEm03J4ElorY+vk5MYayG+K
# DATA 6nFHGFE9EKjw6sB06OgInO7xJrrH3SCdBUo2DZ9W34kulbIWt34gH1ffSx1sL445o38mH58HBeQsL04pgnhvtQiizlURQSSjLDns
# DATA QYcoGO8HaaaAiJOT1LygIN6N2W0ym0xw7hkbDXAYzUtEFjIFnkMOs7MXjJpaWPKoVUc4Ojyno8PjYS85LHhhkB5yQzm/7uFcGq5M
# DATA otKqfxenGGpqstKphu2QzGBGZmXTnaUDqrkhi+TiDLocoQ5ErprNnMyIgFUJu0QwDCioAbh36CIyZWql58DHw2eoH/CXdjTz5Fzq
# DATA 1FkCnoOC+WDjgnlIVb0It8ohNMAt5VA+2FygEpmE3Hq42egGwiAZFBz1R2g4WjcU5wihWAXF8HDCtiEy3FLTEMEBrG3J+BYNB/GM
# DATA pUfPr++aS8qVldKZO7d3N+3c3ouwcwYaHrPEUkamCQrN+bArcBpPdNPpR8kI4qSziacKJk5Ygo1/FfWSA0pUEneku0tCfGXdsNl4
# DATA QEYV1A1sGY/zFEku5ldWItYgecoieby6SMxwK2XyOAmioeilBGTWmEKh71MYJ7DfYsnhHk17YOShahoaZhKo5qA0qwET1kozmZJE
# DATA JvYmIizDQ1F7O3fB5KN//dvKo03bygcyJ6UJajShKmwKBrUbljNN3WWLEAxrHsZ5OgpVj0nK4z2m+eDRYmOuQmalohmuRMKnLGqN
# DATA 0oXn9NxFMRfjl1fr+EWQE9GPO++W825t4t2yq5jzbjnv1sZerJVOsMvxbrHwlgHgBd5eHIsonvZtXVv92nW+Lxxp8GwP2IJTS+im
# DATA 2DCi9iHrazlvk1qeYTTTGPvveaKqFkq3u6Md5fbSDVMmpShFCdU8b7qy7Ipx/VR4d22Cnhu92ChiA6nC26pHAW951Rt5wwlvvS75
# DATA qx1kvIKEWh6rcp0Y1bK8n0zdaGKmH1xwTfmK0Au7p3fL873uaLUfyy/V2YFAgUVhQneX6rn7F3xZysIyjkLZdENB3NfyhXO9rGUm
# DATA ofwoCny4SKdKdl/Zpkt2SZp4JObZhMbDqWxIvylBnNMAEiMFg5HV3mw1y8eJuF+FGIt+YEElesh6jWPtpS3IjIFtOPaKBHtBJLuu
# DATA sCVeMFI0eyh5BnKX1dOSx4VW4MHPArKweGUWJPQqU20d43WwpibRWDBWCJMsYiNBiAVFVlDDoTFIOnYOpXmKMF8ABUp7FTGd7YFf
# DATA yzsFsjVMNW0dawlK1qvMZCdnbKEeema7gN4TN2EbRuNlkdUvvOGZDTXO9HSm5yamp7M1X1xbc6V1eA3VqvlEhzldsGiGDS0z9C2Y
# DATA nRwrUMiTUJYJU22FZg+x7BJ3vtdP3fr6S77y33JO586r1IPONyx9LBDhmiNcLTnhZ51ZlAvBkL/Ni3DPH9eTZtqNMVmQdx2Ou2J+
# DATA G/2rOz9bOO3HO/ioEBfEza2n+AunZQNh8ezYirbH5uDgB8EhT1+g52wMs3u8ZCeTo7FZFIQ/cY9CmhzK8qLMnUAjnAT7PHcpeQ95
# DATA OWuqLSh1j7LPUCvhMhZnHBs882tdAdbDyUrTtI6NKsF8Zbr/dDJEqGn0FFvXZRlSqveVwz2u3HjKMGVUofbD4d6MugsbVvZPx18d
# DATA /4axZCCIfcuf/wx0GWPD/gCiGH45/mqRUva/mx+/PPru6FugyP6VL/zh+KujP+NSwTv649HXjCL7Db7jBn7d8d/TH4DIfk+vA8js
# DATA W/r5a0aZfUcBfI/fjr+gYL4DrOz4C4/C+Jou/D0uAo3m2GXPhXWItPHUC/4QlivXtfcWiKRB8gSrfME4LMDtQbPShOeOk0CmPxhk
# DATA aIaKo9K8hgS9DG825sBYm3wWDZmNSi064N2cNLEMpgJJDbFVnzqztdQygUmHMlA6aJltK1odxlWjy+ZK5fLIZb1IzmGm5s431BWu
# DATA qAv0Mox75k6qdFITkwuGl/E8P0p5AwKaA+8M01F1BLPNSu3CKWa6s+lH/FwwFKdS2h2EvZlsExkKOx6SHwxy5l7MY7VXz68XR9EY
# DATA tnYwpMqNfSS3taeX0RlihSUhBSwghWiMLljMQGUZSZscGnzzplVztYmTb2rPCl+2NvKOXuYsgAuzADS37PQD/0vhILrKQf+ix/yN
# DATA hvxTjviXPuBLfcwl3qaXXYvmcxncslyKvVDm6Kl4pJjC7cX9/L49zobpgGK5x+smaHQR9mkay4gRR6NgwgmX16KPknMDVDtBXcJS
# DATA i0YmyX5NHnGl3ntGnC3dEFvGOacqhUfZMcPrZMAHEETcZQfaMKAiSBFLr4cDP3j5k3F8IKcjempzKbBRk5CLehDPErC/mEEVdaIh
# DATA sgrWHYNWaDxi3BSMBdFAYDyXOUOgQE7jeDl8ynHMHMfMccwukWO24Uiz0ZRnA/v46kz8s1j45zTwHcjMgcwcyMyBzBzIzIHMHMjM
# DATA gcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzK4NyKzSqtWblbOCzPr9oF9+jkBmuRXn
# DATA 03LMGpQn5dqg0WjtV9u1txvzCLJK2Oj2F3Oy7FNW1gb1VpM/VwEZU59rlLH8udXyfMrhaq088lvlIv2rPvv68xzUi3K+168sg3pV
# DATA WgtRqNQpCuXKp36z7Pk+EGxexS9PfbiNWyfhw5r1oNld+qZ6YwGH5jfr4JJ51UqxXfP8Rg0QNL9OGedXmfxWa5/wum610VlOK7Mg
# DATA akVMBwII9EuN9tpLQGYUlwxkRpEyIDPBsWUtoFbtNysb529jyasq5Wb2qqrvX+KrqkJkk1dVGs1LfFW9YqeqVb7EVzUYRadTVb3g
# DATA DDwVVI67NA2Vk97RgsrVKo1qq5eHys0j5JZC5UI/bPbqGVSu3muEraqBynUb3bBrQeWq9N5W49KhcrK7sCjLDHqYq/IMwtOrU8Z2
# DATA aYn5Zz8zD4V7K6TOPAoKi/S32jL6G/yfzf2DQkP8nyrkUbAZ5K3UXOfW1NOzLND5BRLbvNfls+DZVCWTC4fFLVa4vv6606IOrJd3
# DATA ep3ODvPYXYulqtVgOCur1thzC3HOT4su0Tp0jDnHmHOMOceYc4w5x5hzjDnHmHOMOceYc4w5x5h7yRhzqAvRlGb4SQAtdqpgtw12
# DATA bvfOZ2ZOMkl3uZ5IL8Xnl3H1I6vlS8PfvWOafdTf/hE/qhruzmeKS6eViyCGKme+GHE04a5ajMvbn8urezNZe961A/qp4O5wKUPg
# DATA MZdOlnTse4v+zk/9+g2/jujo0O5IAJ0ZzRdRqCZmLDfLCrTjMOyl4N3pZwDJExmC1Ggv9cMD6UAmcipPxL7oEp9gzCUHGY1TjLva
# DATA rE/wYskqWXza5gndTkkWH7a3g8J+IaJCCG4oQ3t/56fbETWN8muN8i1/p1DGpi9u9Vh/2h3t3tke3dn1a7Xyax9uvU9Vko9YcqjI
# DATA IGX4cD71hzHNWUc3G+Wdn1RqOzQD67Ge1Xal8OFWGXfzY/qZ0U/oxsWbbmc1R7IcNWA75VirqgPn0S7HbxupZ9Tgv33xX5Cx6W1c
# DATA ubG7rDC3o1fzhfiaX79V1rnJod7+fKf0SRyN6VkGF0qk1ccbS17Zj8ZROlCiqH5dFyZOy4rDRQCIPx9DZUJwAHieoYfbcxWmqGvF
# DATA jl0tqPFwPTLZskORvM0FTiVR1LMKev61dSYjtzw0niyczzAOkjGkDh1r5QwtbqFD1mxFXenMvIsC1+ehS9On6GesOErYj3SY+iEa
# DATA cBGWwTTqg2hOKcIpRaxXirCOKTq9CKcXcWq9iJU6pZeiI/FgNs0aAO/a0pqeMrIbUYnrKGN0FTr2YqyIjHsiVsyccj0uZbr1+n7T
# DATA eZkLRui93L6lFsyVcP0KPXo14LIi/RQny5mHZIS9t9XIe5KSvgnGRCm7kinp18rLpPSrtpR+s1K2tfT9+mopfcugQfQ54jQxoVkV
# DATA V6u8nH7uZivf7CAW1PI5ZneqZW1/rNbVr3E8a/WT72xwmI0lYS5o7+sDjJRuPoh4RxnFwgxCy6Fb5ReVMxkTCpMGTlO+3LTjYz4T
# DATA cuX0Xjae8VAoE5A71uW5ArmY1z7EuMkt3n5rdvVyXioHHz0aaBPqJnJvzv+U4T2zcllJR5CeTGECnl8kwrvw74nUjTJWtCVvK2cY
# DATA jZkeTegsuz/XybMZBOGP3C1KgJeqMGvPQHKG9TQYbsBiDppBsEqDJi86Y1PBFvlfyzlhkoG5+QNGQr1Cwb4tPQTZELAT+QbPv7hF
# DATA 3sJw8xI3LzlhXpKzP93UxE1NTp5xPFOJO4zxqOA6EsicYaZy96aZiAjwgDWfTFuj0gtSFrmC4BRrjhkRqoIop40CcVwaITQt1jA/
# DATA uZhDL2CbjY39Fh6tbYAJX/MDEZ4LhTALVynaNyWGKnRqpjTM6KLsST+dIZp7/NssPaQxd8xML0qgdBYFBSGS6ZEeaBlIz91F+kQH
# DATA OhnE03gvCSY8VE9CGNJK3jdKWHpMkpgf9qYBY5XfixNR1lVj3TzcVBDJluUnqRVzxMKhcUeGvu1AYZCxTVB1bOK7x+rUAVDk0Ie7
# DATA K/w0wUoMAhsvCg85CAMstQbf3rrYRz226tZGft54lBQYpIBAhFNDEIaK/9SAnrssCKfwF1qTOFPWE5ZtXntPFUsHXbbwCaxeO5D6
# DATA uyZNd7HDfhyD3DqfLDET8tzYBVVFU5HJLHwA9756M/KVzLYBCL4K2SBZwD8A2IvIYy25y7JtMGoKqERjSQqYd/DexrNU5YcKOKJ8
# DATA uLsfRz2WpGaVNgAUJEtpgIqZGDuC1NqET7rx7pTlU3qO9d8ITUQ5wGVSpuOMBfWccHXcl1kYdOhGo7gnjRuFx5dNWXn68Fzc78On
# DATA rstOa1hLGRa8yaxDFor1HOvPcSMMerCAvITrsFRWGrsYXsyv9EBip0GHLO2U2uS6JD4CGlzBvaYYRKwkglAmL6SeIYK2F3V3lNYJ
# DATA Pd+fDYeHireiYspunJQrqqR7lCMVsrKg9AkHg1ipI1IHiZ2gVMTJAO1QCgx9/DyiVgzTF8+edrQwZ0tvrAbtTOcX2nQ+LSvsGatD
# DATA 23v+18PCHmMk0LBLNqqkvq+nhV0fNennQlL1JIJEtu9fs7wuEiqWV8i+aKbYvOL4UqSYcr+xmjcKlXehkREkNSIVsyYe2u7QcKI7
# DATA sTvvs3aJcMVoqsL6xDJpovfR77jnzSiznNF7QDJ7DLtcaGRUb7J7ZWYCm1Z2p8ew8CJIkR2qm27Gw1XNU+xl2Lmovjy1CJY5GNdi
# DATA QuCKNSTnBf1xWGAsQzxJUKPT0DQzUXAOzHRVttmQYT/CXWTn5rytZHNDtNjWQmdLm6eQklMzFiXXBu7COtuCrfeiWXkZ1uwg7Cjx
# DATA a5tq9r8dfXP0z8Xjvz36gSlj3x59f/QHpovRp+P/ePzF0dc2Yez4K1xZBJz937h89Ht6+BtGlH3j0Zev6eK3dPl7kMmOfu/xPX9k
# DATA xtk/yH3Hv1Mgs69BUqMXfEX//k6BzDg+XyNOx38HBhrzzv5w9AP9QPf/ybHNnhdbVho5Gp4WX+clK0PexDoQzeFEXZwnbzEFN0Wr
# DATA Rxyplf8cKovMkBfvUbzPXp4gybxKFgkRzWMtyuzt+Wg4nJlt02YdxVXTzJYUzOURzcSnki68XF2fv112EJi7H4YpjUBdGbC5kC4Y
# DATA bSbuJdHzh2tFFv6YWuDAZhsV3oVzze56lt55NjMwNYAXjSGkMxsyhaNziL9xmkK550A9kQiKnXPvwc/pftE0L2hOhd7vYiAmbP/s
# DATA A17s0cXhAs9sw5q52sZZbHbPim62YVIc58xZA2e1BjTW7GxGwEvh1LpCA+Ayxv+Nhv/Tjf5XOPhL/VzICQt19kxa0GWQzRYSyXQz
# DATA yqp0MVpgnMmyskfVEzX1loCeCt7bjx8/eFRQB0vVyjCXDO8ZTch+4JUdTgZGaDglMppSospSex50nuoxd1O8makKHuU1lMHyBgBS
# DATA FnWBOcuMgDzgbJKEPfhG8kaBbQwUuJmis/BgYIy7yjxgqwAcKjEPBTnF8U/pNRndjJ0q6WHKRynVPR3HN3N8M8c3u1S+2WZjzUYT
# DATA n1MZyFdr8Z/F4L8we99hzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxh
# DATA zxz2zGHPHPbs+mDP2rV2o3FW7Fm13+x3niPs2cL680boM85clXlMCRPaVq2SOyzmNyr5XK8Ky0myvZXLuF4rrIf9OXxTtVWvC6pr
# DATA Ht9Ukyy24iHvlngI+yqLR3X+0Foli0ZtHlu3jBfWsHhhfrtlGFQ5Qtpf13otv1ldrDmtGlWd1kDqnJW8oNFpd4Ol/LR1yasIKe2S
# DATA klexaF4bJ48eurDkVYXxdUnJq6qnT5U8euhcyatWKteikVSrrctrJNWGf45GUm2Vz91I7ORdeCPJJe/UjQTJO28jsZN34Y0kl7xT
# DATA NxIk77yNpO63rkUjqVdrl9dIKBbnaCT1ZuPcjcRO3oU3klzyTt1IkLzzNhI7eRfeSHLJO3UjQfLO1khsYGu55dXq9f1aY1Bt1/aL
# DATA tcao6LcbXq2xXz0JoLq6EZyFhsmWrqFhstFs0TCrnUalVT8LDbMcBn3fomFWG2GrZmiYnW631+taNEy/Lj9fLg1TbeaV2Z3l7FHL
# DATA boaPyRN2MtFtp1qb19iXbJvIhYr56+I981sVFpfMWrxkVmphq4wsmuVCVQvma0Nu8OpZ/jE9C1y+2TC7m2aTe0kwyq3RnZRc9cyS
# DATA 5fnFG/RK/UKeL96deRFX7ZCUF/lSROIKWAgESw2LqE9V7fLLBe12Gx6Y08E72WO0JFXsNlzwPS9uF1rJ/XS0TkfrdLROR+t0tE5H
# DATA 63S0TkfrdLROR+t0tE5H63S0zgugdS6iOfeijgIoYnUOpqeCY2oGFV256ZdrrXqzcTs3Z1GP8eFhPKYRh2SYzya4csPHk5XabcXG
# DATA vK+OsUM/YDwdDA8N54oRiRQTqldvYn//doWxiG9FrwtS8V2cM5dTypPhLPUg2OypF/GzKkqrnr/rVeo/MW/LhHZkXkp5sB8yqnOb
# DATA 4vBTrPHvLAvJZhla50ydIIwThMkJwiweOnbqME4d5uzqMCuVlC9TNUZ31pCDkPaC4mIlB2y04Z03loTM9dExuwqgoQyVDPqQgYxV
# DATA OPjqCSBB/WSum09zyDa4EZaCBH2LI8g3lfWdBie4miZohnOwBNVnhM2CJRMMijoJ3vbfRK+fBES0gjNJsa+Z1NRPTkvlFMkQawM9
# DATA ALyiYhJsv3dyfPVzJrLmghXTzTJ9w5hqO4jbKYQSITmS2S3UdU2i8KTqkgWSgSezSybqzZNi3lgT65WQP9MF6CkTj4eqkJ976N8y
# DATA 0p+xEEPT+6FnojomLA9uHj0jrwPbgIs0GPEcgJdnWBBGzTW7NKlitWiGmmBvJE1vCt7BgCofGYfJXmiFpnK336e+tjNL4NvAczS5
# DATA SkIoNEVTLfCj/NUy80hZlpuVmKhKHYqBzDqYdj0reffiEbvFqOsrKLGecc/oP2WiS2oy15MngkTpImW2TAaZHVG8Zgn7VpX40AbU
# DATA wBdNKcYxT9xEYMVEwNn8L4XNf1rSyXVRirR3SqxHnrwV8Ygpaom8Hg2RuDGr9lDbGoVr2SfPTl7y+VJXO0ldem6Px2WATxYFNC8a
# DATA frJMh3QpACVXdnpLjFTkZYC/N2HPaxNh6R2s6rn2jtfFtDaGxinlvhX5j3GVEQsOAiQiGp/BVMpcmZub4DAfZdNujVd8+/F77xa8
# DATA e48eFdQ4LO2FhwWl5Q6IpcyLRGhxApXQQCupslIjlYKR/YzSbN6gwXbcwKMphu01RMVH0hnIhrf1sMi7ViRUJdYpugsl0LGSR+XY
# DATA cYIoYb0QNL9w3IUi6Dik+Ck91gLVXqquA73MJvKseVXWtWjOfAdyQtS14KxY0zraCqbIBrc6YBiKP0NgpDD7RfueDejkUEliqliW
# DATA vAeaU4OY8+qY7sgCrx9Ew1myjmb5UILBwtUqnuVLZIHb/bWzwZ0NvtQGV5XEeeKdJz5n3a003q+PfjvXaYzUGc458MRTaDzw4quJ
# DATA Umzci3mQzIuPaxf6PP1sNgFOsOT9AnvEDw2ihe7ozboQkRlhLDbSxsbfzkRjtnc2FnLPdAukeeLrnVe14fcIx7y5YUO/IlUAbJlx
# DATA qL7g1ZvGSpxK7z1N8FGEufGqrjjryd5IYhqDqWEPlt7wcxnT+6A2r7jlA5hsSKVocbPYNG69iXfe1O+XwWg+GspQVQacsXj4Tb07
# DATA b6jNiVyDCx6GlT71/TGVGWM/qapNe3ynGiMKngzGBS21Dc4dMMXpQMLtqWitiMd7wZjqVM+2BU1k7mYS+HO/SxRs083YX1SiSQjx
# DATA bl480JbXyRH5RZRMZ1BUZylxKw6qgNnM49rKkvLcpyTx0ETmZxNWVDE3UCUPp6ySPuHBkzJoONRVPbXic1MV1E1V6VZw6ddjvx9p
# DATA Oy/LezH5gt6IBn09y8nYPlpJXJHa00E8G/a4XYo5O4blh43nmFqJuroUcMlj+5Is4GF8OOIgyD4HzzqAOLwlQw8W/SdxhwdOJTE/
# DATA GzMLUYW0Dgg+jg+UXrk2nYPpQEf/g4Tl7KneeyxuIs5uXm/RfmN2OpM1TsEE2tuMXoo6O74HPzAjNbNxgYQCZFHfzhMjkOrHcLDT
# DATA cB6O9b09xXrM1gbXJeY9cUWr9AQing+/unHvK886IqbXMzKuwiAcTlR/JgueVl/EMvg0UMY5qMIkDJ6ghKXHRN3DmmUvHOEF9gxL
# DATA gRUoFJkPMhYercCemik7xgafm/VP1M9otCFD/MWy7T///KPPPxxvvfJXL/p/lPXh8GN0GNF4Bqjq5PDC34G1y0at9ldq3XjuX79c
# DATA r1f+qpz991dl32+WG3/lla8iA2Zoc/T6v3o5//vxj3/8cCaEiC51IFGPxxlUiq2U9yIXGfuRVRDv3rvvUK/By5zUvuNhj5fw6YES
# DATA hfWKSKWQbbvHh23090/IPtSf4/QVHr3Q6Q+jjqcuP6Cv+pbEPJjOOso/o6/gSBaGA/19RqbLK6988PDugwf3H2ID9dbW1it8xuYV
# DATA tcGyL/uq2dm0TZPJXnirn27t8G5GnAzZAoPvJvWKN0H1vdkdRjSD2br9imy17qcl5APcfI8Ox91tPFTwtmi+3tqydqBusVOoiNCL
# DATA WW5t7exo/1IpfBpNt/2d26/M7/vMR43PkX2sHqI3UO94MOY3ZwGFXeRWwfuliszyd39UeMXzvM+mcorkls/bHQqj4Onrsz72PvqN
# DATA aqtWeEJW5qNobxwMb209euetv3nn3Xe3Cum0F8W3frlF12l42CpsTaIJ/lHfP/p8R2WP2pgaJgkNPb/+td6omnKA9gVeLJeNr6uz
# DATA RPYQ7+ZOa+nnexgLprE6VqHyX0eDH3yNC+qQX4KDUXj9j+TwUClKHwX98B2yi/ZwSAG3l5Bf97CSvYM75655r3rlZZfv8GmbpWnQ
# DATA V1RcD2DIbKv4zr+R7s9Obc0H5X3+CirxK6/QFBpuyo+ZbrQdjdMJjcIfS6Hz5H/nFooYWcAr6LgEG4A/lNiaSDGF2t4qbu3gh2E4
# DATA 3pYHKSF1v4JreDIJS9hPwNuIt5OtX94t/i9B8VflYvvj0s1b/1Pxoxtb+RfivyTAVO4XSNh9FP/21jvjfZz2sXoSfmZrh59RA/Eu
# DATA t/RcYnZ0IuQWrizbVPOnH+OkLsW05v3Uw4Ze9c/6OHC4Xvi0S7ZuKhNJFQPYm0kPvQH6oxLvfthW70TV+Rj7q7d3dnJ5mlJMp8G4
# DATA i6rIjxc8nB4w2amu7lC18/yNckdNdRXGNExU7PT1XR3PX5Y/kh/0jdjzLTfxocStd3pULFvq8XC8HyXxeKT2htv30XSuH+3RvZ99
# DATA viNX7o/35UiQndT5ShAU+1QDPvqsUfucbjax2NGVxsoa6+Vz2WP9sqMaz3kyCaeh5YALf8VkXTqNaGznQPaKxWLk+ws4esuR3CI7
# DATA D09LMHwhmb/wtFyeu7S7pfasyLXsfcuT9fNxOptguKLZhRVNlSj8x6c9P6aUSU/BOwa36TUFz9+ZT8zy1vrxR1az/ein9CROrZ4U
# DATA M53hdvWh56yYcZaXaHgMxz11ANW019loG4WMW0o02aDujc/5oeyxDkHZw0+j5Cv1xgbN974VjWVN+K+xtgTHhjdSHK834u4TnK7B
# DATA P1T56MHkkKdPBZkvd7k+4iQDCg6dssD0yPQvqSCxA4v6XkXLgy2DOS3T+9Qi0W2hn8ElpWf+8EGzZCimi+kgwP4raa6m99ulyI5D
# DATA viiOLGW6lB6HsF2C5PANFhaMk0MWtoue7m7Ri8dBd4YD5WYkR+dNU9WevjnLQCq1j5UVw72quWXHu+lt2TXNPKJ95jG6kzgtgRC2
# DATA rcMp4MrPPv7g4c/ef/c/eL+Wb/ce3r/7WH+5/z/fe7fglWMgPUyYnDr6ud/j0LJXUPd0IJGn5hYGo3xtlGtqoEQ7LH1CBbetqswN
# DATA bprZS6Z2wjmjFU9t17ISS1Rg27/M3Yb/tnpcS9BdylP4VBT3Lj6aXC9lub6Lw16wLkv4q0YD0iB8WlgMulhUVYJD1/3VLTxtvvHb
# DATA jDktL6dpdrGXxJPdu7C4loWb6iUask93xzG956CImW8EkEwqoVDJFVFyW9yjmYLcWRogYklVBE9qm1eHolsNvsNM0QM+fsYXZWDn
# DATA g/2oAGfBdJaEH8sWyt3HyUwdvNYfxfrcrZYLsm7K13fyBWm1GFWo2oiCn2qynb99s+FKhznXA65soZt1k2yJeRH7xKZ2Lyn2hbLo
# DATA 5+ujVf3YKJNMD6bToDuw4/rRYqkt+2/TPPfXZro6mZc3sDfP7w97n/mFulgGbEPD7hxPt9U3ZSffOkXeWpNMidRC9rIcQPYS82sf
# DATA Wz6Gc90DRdtk7GI01hRRMpLyoWGsG+aLx5Ns2rWefuP+L97/+bvvnlhy9CTNkpY9mZVXXRfXmxBw2FEzAIxE26oa86QIPbeeYZfu
# DATA Jnvs1X/Av6iik9twlu/jQP1Oc4CiMropTXrvhVUxVj3DJvzSJ+g22GLqQf4Hj6YqErkOm89tbGeTGdxXUvEpePKNJxjKmn0KDKd3
# DATA n/+BEKsJ6K/ViH/zjdc9nnamjAZVXa3tsC55P8OgHXiM7vGwe2kML2XXo/EpmJBRM2eIPGLn/n3Mwrbej7GPO6uRXeND7/D1fpSM
# DATA wt4Wyogq2scfwxz4mOy3XW/r449RYh9/vCWRluK7pq7EBKfYR+FluP028/9VauVa3Z/z/8Er6Px/V/HfX//o5ixNbnai8U0yHbzJ
# DATA 4XQQj6uv/PjHP2bhDuHVYvFFFsawxoAVXyxXxJNQQ2/1Bq6H2ozyeLY1HFK3sMYriGWKRk1/w54m/XkQpPAN6q8R9MESywl4dn+i
# DATA rCCar4PZNBqabzyHMN/S4RovZJDYTsh5p+R0kAgBz1ygRpbzWHKUZ8mQYiw9p443XePJH3UsvHjiyex9JnktQ2Y2eqphgTL5rt3B
# DATA waSmOY/XOeRyMaXBljqWUZLwk1Ct/yFDZNaZcmHp9/58spcEvfAXUDvQL16MixmXKG9kuMIusm2aG6WZu0i61yUJ0bepR1m7B+Wo
# DATA n5MR3/LW8CyH77A8NjzzxK7QLd5FtbWjw5OZxYR9pWraj10+uzJ9kXdMcRpmqidQHLSe3spPpSj9OD0cYZPMtmVMcjK3jv7Po2+8
# DATA oz8efX30r0ffHn95/I9Hv6fP3xz9xTv+j/ThT0d/9o7/7uib4y/o2h+94y+Pvj36C93yw9Gf6Xb88OXRd8dfHf9n+omf/jO+3vIw
# DATA eYA5LzFQY6KKjhx2LI1gyW/Ll1QZfjyJ/Ti2zT1eL93VTpL+KkdISPaG5HNvNpqk+rdwjMXNj4O0G0VilGCfGQbY3YqeoYkjplfg
# DATA GTFLOqlZ7ugJ+oyJmdqWsrkt2RMU+91cipYYDZhSdgdUZNsIH0W3cs6JG2iuiSjnKwPW6g8wpdzl6eRGc1Fk2s6yn/vDGdRmcj8h
# DATA DtiKvK3vobSPY+1GVHckIcPGtDCVFKvt16F7OP9+RAYEzcLykTPT+o/7PWvWnss+NXV/+IY9dX/jnYf37z3+2cP/kI/ywlQ6lw77
# DATA bfnnltrZ6llGwS95duEZSSwaWonra8qZMjdNoztmY25y/KNqz7J+rJxQxvUND5RSXYObqbrCqb392q3MQfZR7lvxo8/KhYb/ufX7
# DATA zmsflnZuqAsffVYpNKqY69ivtnqB/370HbX2/0Ft+v9n792b27iufNH5m5+i7STTaBkAH5JlBQrsoSTa5lgPXpGKk1AYFEiAJCIQ
# DATA QNCAJA6NKT9OZjI3ruQmlbp1aqpm5qTu/QCKYo0Vx3a+gvQV7ie5e732uwFQfsypcyZzjkV0797Ptddeez1+60PgB5+oDf652vFf
# DATA JM/+gBv/2V8UB/hSvfxSFYTN/6isnqkn76tnj5JnT6HER+rvp1pVjZyPlIE9gDwpySSow0h7PTbhtJDNCmoxayr52ubpJ7ni3RS8
# DATA QvPa8jKwGp5XXQHs7OXWsLus2kob8XleeXUlmIb/69knwOkUU3sEvE7xPxqeGqmaE+SQavxP4R3wv1/gZHwO86V+Pvvi2ReKAz7R
# DATA +mxIeJ/7GtFy6uisV5Mf1FnPjMUz+L02b32gN09hdZ5Cw9D+Y+jmo0W7bzg6sf7nv37+IXBxvXisB7C01KhhIS01dtTW4Y0Rhwf/
# DATA DS7gapz0gonAseroNfR2j1Pl7qVaw65OZuuELum2Pja2lC+8kH+yru+C5+Nvyd2/W268kpXUZlw2e6/a/IeKenouW34jZYVuoAKn
# DATA CsFVrw/ATYeoMFaze5pW4fJeraZT8vI1r/CT3bWGUJKatWzO0P3x1pytTcSD0R0VQzsJfgeb+flvnn1eNhxAdjvu/Eeq8COoSBVT
# DATA nOHZY+ABzB9U5TLXf37+saKwL4E8gXLV719bs0pghbGdTGNdbcBOlnHbUwhfdvtMqLMnYc5ewAn5s9paaskTHNSnLNuoHj//WAk1
# DATA do9Z2cTGBEAvtLkdvY2xORrW2Tjdmba+XtbZw+WhANclNd8cToyl4RfarFQR2IxImLwC8JVmsEDLiizhOZo4VDH8t14POfSBvOTC
# DATA eXgo/Z6G8fyjyKp98fwjNSdIxnAsfYK09THt2/j5hafTZeedImM1YU9oIqHqgGSff5xQCXioKYGXG7sdW211Ey2NB/c6fXd9i43U
# DATA il3crc7+rbiCXaUvwVPPPwLOrka2vrVZMZtxAYLgEZXS9a2t5tat2zv18yurK3f7tzdu3Fx/d/2HG82t9Zsb15t3bl+vc6oaFIYf
# DATA tO53aucB26GfOrswNV+qzjR3br2zcRMNEjgIkrw3b+5s3L65fr35t+/uNLc3rt7e2MEifMetYtHmUedh6TwI6279d/s7t+9s7zS3
# DATA bt/60Y/rq3f7N9Zv/+TK+s3m9Y231q/+uHl98+Y7zY2b61eub1yrI54sGmNoteCi6kthsRVCfTxrieE6w/C1IqDh4Q1qQZYq1K+L
# DATA r756/tVgif6deKdhNkSaz39JFKYoWNUFL+l7d1FMA9J7cvpFld0io2CJcFcTEwiLazOkQUVRcCCqLoOQ8JkinC9Uv58Az/n8+a9Z
# DATA GOQ3j0SfEhH8uL+WGa9krPA1V9Q4nYYGcV14lhsArsZuw5HPwbwdN22jmXpfQ9DNMlab7u2qrxoIWIffFbJ8cV1tskGtZNnPhp3O
# DATA KFd3nPud0airrvBpalQfhBSJmg6xzg7Ae7i7T8EDiFGh/WKFhyZ7HXASJqUHCimg8q37swaOreHM3aR2boClTAukVAGcyOqb1L3x
# DATA cL9Rg6Z/vBSWDU6uT5HJqnNJUY7iOU+I5H/z7HfIWeER8FpgxZ+A5kFtBSWAQKUVKf38Vw6rdo5jXATqAz7l+cvDeeARb3fGYCbP
# DATA I5OREy0xJfJmkgrDczlBofELlGv+BJ0D6cE7VL7gAcE/6jfb+kHMhH2kNrySL9QBBx+p6uC0ggl7YpYkPu/sulHct0Vmno+Cz1Rf
# DATA fkXnBnciGBadwP4CsCgunciAclaDi1ofFFxdQNbVBRUfCy7xmqjrWoFYivON3fTa+s76lfXtDTiN0kZWlW9tw0vpnc4JqujKSaBs
# DATA 9NrTFlRecXkVPWjVWgGZ/hlXDlg3MsMnJICAjAYPjSxNC6okS8U6P02cjhvZivshf+rrsr544C3SYpDAS2D9kac42xSeaN8qXBFv
# DATA F+BjroKeQLBNx94Nt8llRJXr5jghoIzzPBfIrmQMz2JQBmtap7itm2p41vaFsZBCSUnTaL2HUZWs8ovv2azaJbTOwIiK01u4YwqH
# DATA hAbCXhchftTs45+yNBRkBU+ww9J76tk6fSQHU+ZpLfEz0lpOY42BARNUcSV/2tBvK82qPbpiw/1P+uMeWmxroH6TU4XVP0wFIFVZ
# DATA w1HPcTDp5tY6VQAX0bd6g71Wb3Pr/kV56PVaDU7TsPpcZoyle/1YuhROPFM4wJFz0C4rGSHxQJbhdAh52XpkvMBAkeqkr4Tu0jmp
# DATA iEwB4McFRxrvH9QPY3Gbd3FNqEgoVgaZXRw/rJBJfkCKMXVP+Ax15E+jxwO+oFPgsshRj5HFfozXO5tDJKSfeGJp1awDwdn2MiOx
# DATA Q4Jn4MVPaOigmorfgPxadDoUcDfrHJBu2ZyWu/3CjNbtrCpHBfS0PYG7oHVwVZNnv6OT9zF2/Rf44k881k95Vf+EK4H3l6tww9Dj
# DATA urmx8+6t2+948lJsiiUlx4DHy79zdKAscfEM/GNJcNwnEbppn3ieYM9CcY7HVdCSkVlC+whEXWXBFySgF36EPrC1pcAz6HTqcG+t
# DATA FYyI2qHnKpYm1hfyAV773yZ4D6fr6RNtrLXdOx2Vjb5FoST1Pt55nybvbPy4/sP163c2RE+iHnjeOHgT0Dmu7UsB6SshTh5z6MLF
# DATA IOpQpGqYMYxoz79Am9onKGx9SVqJD/Cibl2uWDdL2hy4eP0pXeBSgu6sMhpid45rmHtfMT2dOcHeNVX9+X/ytQ+1pTS11nrhU28A
# DATA 6uuf64u3eM2rntl2UombMPbTpZm+z46HNl++Xfd16yYLQi5M46fI4v5JdEQBHyN+DGP6koauBvXryK3WbFuwlDXzo9baqxft0bS7
# DATA hxCxWBcvgCoXyYwnrWUGRktYOtqLm/Zgk+0fTfr3YJOhGN1rHe+1WzWx6GG+BSu2ICsne6mvT6ceVSkOuYT1OePi90edh/SXttVQ
# DATA tGkTBqKOVOOdy5f3wWAceu6y1axHCUmI5Q1JbkWdLTguw0jA/Itn9BAs1PCB+gkn2NBYErffXlczt33nxrbhuqBlHDpG7QWiQEiD
# DATA RjVnpjPYzYUUIEg0xiaO1hMk9Me0R4mg1EbQhzWZYmG4y/Y4IOKB/IQd8sleSZMkfYV6+Ao69Xu9lDW5j4gDTVoaM+9lOkX6YNtO
# DATA KQJu/jKhE7gIUvp+MRo8QFEw6LvttJCR2gSdnW2pu9BUotahVTlA/9YsSUre6mTgojd4UGwoETMAivHQ7ahEU7hywqS+tGQYPC5Y
# DATA bfz853CCfKS41ucWu8XEi3WcweWYHQKtwDFSlBdM1uppwCyAwMXOER3Lv/i9ZAmNegmK/llUWKResUaH04gCtoxNuAIDW6nz3niE
# DATA VynWugpeFuwJPO74D8WdO9dPWLZxCmppRZMsqp2Iam2pg/qBXUxFAYYeHmJk7TmVoPMBqLT8HX2nf68PEfka2pW/SL0AIh73D+o+
# DATA iVnkhap2WQx3BeCRrACd5b7SBCdNTjraX+E8ZvHpwZFxHD58gndDayjFw7+JkCbwijtA85C6yy3nQyoJ4CuQH2JU6hLD7CL3BkQG
# DATA jJnBinZleRFFLm1kWbxKa7gehWTmvhb9Eo8CURRAD3btsBCeNqCzg67q2QjddLnqBkV4QqvI9sVdwwTIcZd4DNwtZyX0N0VUOeNb
# DATA iyX2uwckElgTsciX/myAjmOXM4WkZIjD1DN4CaFGdimxCI2eyuMYOu204XBX+YDoCIgDVUG3B5Qj0Jch3GFjrC6SQGXEH3i0u9iG
# DATA +n/5QGWW/N8U5/qjEorVVfn5PxouRqpKxczxrqykM3UdBdE04OPIAzWHJNHZvWINnVPQNYEwt8eD0g0Us1l6ay8f9CBnmjVB/KWu
# DATA dxkeLC10SCiJfNC7j9mA8uao02uNu/c7zfHAjoUCQcApiybVMJzKEekrWlqZIc//kgVi4+9HQvxjsLDizKIiA6z3eBl/9kc4d+jW
# DATA 8gjn+7FlRpTByqZBZhUeh/M7jEfXr1Xd6raOd/wPgJ0Wd9gV0925WmIK6Hcm41ELwCKIEkQjoeRajRcDSEEw/8Y2A4iBh30I46Vc
# DATA Sb3WSWeUJ5CtNWkdjAGrfNDHJLHoFnqZAVko0JwQVXRD2lITc7Ax/E1OTPmuetI67tlHqXlBzyn0o1L4XeF79boRErFBz1lOtF7d
# DATA 3wiFSxxxNY3qV7k1d19aC2GugRZloS4RV2hO7YGHIK8+hnuojnoh2oo/XXJjtHFc5j4KG+40FYSktJacTo0mRGwOt7ZnmRzcXqAz
# DATA qj+z/LpQsn2EEu1T3J0g1WpXdtH5obQB2+Tn7CjyOagZHmsjDxsoHhfwW7K00fX9E9S5kdoSefETRxHhesKYxYrZRRmYSHZecI9k
# DATA qSx+RbEOTyo36+Rccm4OfL7FjnDsZPKdhJFrCXuJwYS6/Qo6u+rpZfwudZ+/T0BJg15bIzMhOS35Z+o8n+voJQWEelQ7/DdQKD//
# DATA UDpQCe6WFGEv8oS0yh7TZv/yjGIhmbyIuLmb6jkHe5rhnDwqas0pBbImyIamMdcrwiALaHkE/SPOn198Npxjp3guRNVg8VKRibwe
# DATA mKa103wh+yHJCR7bYpNREjrKtVDSqi0QgShkrMVt9DdBqApHzCtWls5x1CicMu2lLGjTem+5LfuDkPJRacZ+Gb/2Sgm8qVBL9Maf
# DATA r7NcgsNBLnDzdddS9xy1G5hjSZ0NiNXdKUlMhhWs2TN4AmxC0upjWTtQ/cN1yLY2neIJdsDCXDlpAmCCqHemOClQrEAn9Ts14j+g
# DATA 6YOMRo/ETTUJxafHoTZKkn66xKs39wKXAIzsJCutkAsE6RfeBOzdYb6Nko77Ok48pgzOlGztsMtRZcqWGb51DZYOU0CkhPbgJx0C
# DATA 0yao7MmxrROyZxJZq9U11xgvBeexzsV7zD4/AGLYUjN3pERNU4/dyVH3uIU+1MUCltU9Lu7dEKUStiTOpt8XmHXAL2z1kwkrZ+S4
# DATA RabregkIQ7f7TPl5/OV2w6FoM9Ize3DFAVJAdm6gEv9j7l4vOTJyXPd81woWsnaIDvI/j/53bkOkmzbtixb85q1rG83tnfWdDR0P
# DATA s7mxjTuWmShCAMEJy50x40IlexFznbM8lJvJTfebGi1xwPnEHIr04NintY3KN19aYWEcLnPczQGQ2g0CI1VfHjcw8vf6QuLxDY5V
# DATA gon07DHcKwF+0cF3th0knDpS60cHX8cZ+OtkZfDaa6+ZG7GeZTsI/HaHkCIYHbhzvzuY5MnmjfW3NsrJJKfkB+AP+KBjpYTuj1n3
# DATA pzbLEBAvrRoJzS752WQwbiU/VSQBBzsu5AOM/R511NROOhhh3kVkIsjQ1eZbLIZlTIYmpJxjD4kFlL2dh+6EDXePyv3MLWlrB93J
# DATA xJv04jdAOUjxK7WY3LOiBcJy5eDOpn1oe61+k8AjQa/cZGm+REMr0yxDXP/+URdTvVuunIwrwgyhXQeSFsUB/7BUlE2qEl/YagW6
# DATA PZh8EuJBpSNc1TYEKrBYzYMuYLHhmj5ojdpGnwC232KVMKnVMdiEhzOrXCB4/BZdMGyFz5/JOkqRYo/EyJuglPZEXT4/Is8YT0uE
# DATA fiJGPf6rAp9Cz+LLky1oVw5MXAwNTvFhSugMTDh/D6Cv3rv73Qj8m+097ziXkGoR+vX02adkxQYllJKo0ZD0UWQq+MICF2+MIIkN
# DATA 7T7FIWNOd71U/LBw9PzeHX/MS/2V0hu1u1X6MztdLVOwH329yKDF/ZOckT5A80V8qGRmCscntNU0A3XJLRhr8AX7G7pHRDgp/ncv
# DATA ODt+NdmiBkUy89gz5Tr9RqRvxidBpzUy4LPHTKJ4rpJ2S+DRoO7xwxICfzlu6VV1JEEc1O5KIzmXXMh2axc8MQ0qDmYF9gS9mTm+
# DATA 37NXBFyzHyEJ83JzvJEeGeiNPiFtEg8cfD9mWSAvk94eOMV/aI6hSOrntJkcL+RPWLH/lOLPSeMrlGXwnnN3+9hvuLA6ApveBy4Z
# DATA Rr6RTDp+UX6+bn9RDlow1iSfTq1Cls8K5hewe8iczKmT8YfUO9e1s3/it8LOkjN2gAkKdm3uALFn/CG0q6bTDa99NPypqXEK6Zur
# DATA /6m/cf2ZM5NyhkHafQ2Wwq/KR8CkBbUWY/G2+FvtdgTTIM/0DFiFwiFZfsgBlcZaOoNfiuPdQLHa/4g6xA8oNtPjT4EB54mOJ/Q5
# DATA F+VPgP5iEg5n+8GTbRKvAI7Y3TzOS7J9syRGTmtKJqKCWkBD726jSe32Zbb83WK/05Wq57qXBbMczOe/qfmhKdDer3/GwMI/BJEc
# DATA XyJL+gj/++GzxyzjnHUuh0P0qtilhCbsm16vm56j415g82aKcCLZgf6oQkN+/FsTtkVxhdTG3wRz8z/UkP6AwZWPnv/q+T8z85b5
# DATA kZCGqNbtLxTXoipgqQFcpz9Eiv1I1fQkFKM+0zEvjOdSL4gaYxf7rS0OGLQAZFlQOL8m+meqCtXOF1a+f1FmZf+I6AbbIf86srvd
# DATA RfS0u+i1gpCpjXBWfuuMuIAootrsp3jyoTMiPrDGUKS3ZxeLGcp5rfsuvESxd6QTVxd13WhEYQlIGYma+zWb87FL2hyd5b9aUbq+
# DATA iC3z8gXT2fuBHjNgXaLK1LotQf/nsdNzZ/jYsXJwO8o7G+Dku4WIkVmmrf8on4EoBk7TVcA4utc5yUu757gebqJhf1LtPByDKngx
# DATA +7L48tnqd896oS/SUHstcDdb2Li+wMERqo7jgXa6p6L3PiXTCLqhkvUPPMJImV+L+LoFndceysLyIZ07ToRjf06rig+kZm4kHROF
# DATA 3fiXbKBQ+iuLnS3a1cj1rzX7gkrTp4JESjjT7qyKvzLJ6ViclJYzPPBpxMbtfiGA57NYfnBBNaBuoY0XsVqiizzDBUZ3FlfJtvra
# DATA Di7GM4YG66yk0ebYnlpxynd3HzWafbM7wewAJUNBUIvxAS+aL8fj7JvaF4p/sCsm4MtV253OEP5gRZXlKWgEKjjZ07JweY4WB+3w
# DATA S/XgYZErToF/wK/FSf4LNKvB4Y7IFAnESqk5+yM442C4qAkRf/6RHO02RoIlDEacYOJSm2z+uszKrtngDRy7Aa2Iby0uHgTFuAEo
# DATA tqjyuTZLFJ32jrhdRCudg4MOKghV50uiOZzHrhYZka541piK9T3w408yHpTztA9r4eqbu8WjouEiMDWsre4eDZCeO3HWYQgSFQpi
# DATA kJx6YaylSPS+y9C5uIcI4EwnFaHedQfGalPltQCjZodCaVObgCuQbjCNB5vW63hFKWTeZ7h2oIrkc4pIAWIz0U4cqcYhNzFQDwsq
# DATA ONx3wrBc+or6Uo06iv67IIAC8XoryhkyJKKUF+NvcDF2VxrVkUYrwieVVY1fVJMy9nJYbSEakvo1PhwRWLj8/TOGPG938bFaUwD8
# DATA B9xvJaM8REe5VruNT5RA1jno3kuj1sln/164c2Gz/0JRPwim/4SxWmp9PqMoUNFQJbSDnsJGwS2CAWhQDsG03kcPyl/Zd6aPrIXh
# DATA ddjlCYRILvzLL1AdDoaldG/S7UGyDDQiWDafnaNuziwEcELAhDBAuDpwccIEANrFA16PhoMembjhxBRZwapvBDlPO32gDwIfZhsU
# DATA 5A7oqx4B4mYPgndUhX1MbqDjxwCSWB2I1XCENow/jPP03LlYwKMvfZkkE3CGWtelGl/eNChhCvr99LvfldhkTaL2KRPjuvb5obUd
# DATA 0CnLLGV3MawYb/KNWJ853YcqSzBXdj3sZEqfuXGzqBink8JSh5NYIL2LfbfkBtRbcnLY6TBUXjhX4dEbZQzFEzVjLcMzwin8P9kJ
# DATA odeucM61yXGE3FFKbt7c3lm/eXWjufPjrQ1YVuBmaocgIyMs3gEB6u8fddqTXmeUTn2tIf2vtDcY9OaQHnNhkoSd+RT+XK8nRVVo
# DATA HpQVdMCaeTUfrBuFltQvaxPSLqS2hPAz57DleQI9wtd47Gohx8TWPiID3qeIU/dEiaVPOTzY8Z6affgSii1ui1eS9HJoGwm1rk7w
# DATA KJnJtDPt42IzqvZf19Zg10Ur5Ac1K7sNypQR7uLRcE8f2Q4RG/2ZJV/CF462DB4srCqbL3h+GRM8n8QxadDM/BnH6M8Rrmew7nns
# DATA fw4jp6vYfq9FdzGnxZmsQc2o/s5m6JgLll/E9tBLCIQTF1tmz9Fj58YiYIZWFEVomzem3T/C2kSAKy4LgX/Ot2I0Dn4hUg9Y/giY
# DATA 74wU71H9qTuNtQT5Tezwn7qBFO7lGG+5Npapjp8CRlcXB47QvFcnbXg5sXWj9V28zJPqL2vol0aFWLcLWNmlInK35YOM8HYAph4Y
# DATA Hu0vd6DYHVWKZYPCglvE6AnpxOg7C+ryt3zBF1tauvfunab3c83vGPV7aVrRf1+YVi7oH+fVi0vfb+01nCfy9yr5yenG4myGUD1m
# DATA wnyGgRGPkrOdD0+Q/T8ix4h/AjwUcQUw8OkfBxESuwULAIKwGZYdOnGqPSVqySpE72j1f833G0VZgjw3WePENOhmc9EBneAEpf9W
# DATA H5NmDRVTRpVFWaDAwasmehaJ9lVPaFTQLd61UIr/LLtn9bbxvIpuhan4Ys3V4qMmXKB0NSQK/gyCOgotIRYQL140Y774ttsmoT9e
# DATA mu7QHxenP2EH/bsS24zdgkuuBwCuE+6E+uxIOKuEZfkB037UVzzYq+ApfEvxr0HzJqY1gFU2Hfcgkdwj3QE7+hJOFK3PQEewmCGn
# DATA ps4DdXf+Ax4PcnzgvmL9q8GkrlTsAJ8QSqhwhU33wVfGzp+URxTS7sQHAYS5wfm4z6lEYg6D4EhoSBJ+ed5OCEyCEZz6Xe5Dri3o
# DATA iVcYKfMXcN4BK1vhkRvXYocmR+jkvHCgklWShtIo+iTwlXaNDXpG9gOASlZie624yuzClxEA1kUm6EsKoEGnLhaWPrM12zPM1raT
# DATA +u456pjhukpmOGcGy1wX7Uph+KXltx5EH+kMq8WGBBM/EWIAwY7gKuYE4LjYQOLP4FlGyNOBXSTZzE+2f5hUOYP/yHkDHtM5PGMB
# DATA 2F/sMRQ3TMIJQkSIeh3QfdwdF21JNn80XZCh2bv4RbfEIrEWWIcXZSEG50jgWkBAtYXjZuOkQ5bqIFozDPKgTlmWfnxgLP30c3HW
# DATA NM+8/1hzL4KaK6QOB1XHuKXjRLkO6fNt6IX+43bCndB13JQwxOWxKB1tLjGvRGyO/INiH1OpjemNbuEUeToQ3etxq68k8HYCag8r
# DATA Nxw77VMj4LoICcvhX3Ejt13DY5L7gh6DZ0ImF6rhX0qAgATtZ3FiswRtenQWDPNvceeyxl0Ay1jodm2x5oAS6iywtVpMlFzPH6OX
# DATA LWGokafxDJY5e9ZoV+n7CVQQOuNZgklMeg/ybNsud76bmXckO862DUfwlVrO4J0OQMnoYM+4EHCJ8zV48+kk1omYjZmWzdERwWeN
# DATA b8jAEQHMV3wH99I0xvnEAUAw4TtQfacJgVxNYk8SyFXiYBdgVmcKvXeRxugfB2asb+DDoQ29IaQ9Fz+FN4MftUcyN/WGAvC5GhNj
# DATA WgSRFG55KjNPgpVSRu5uGPAkkdUXD9oMoul0CB3OSiRm0weg8hGCzNDnoQRZoAPfZIeDINMFWGeASKRuVK5k4vLRYNCR4c7cnrKs
# DATA tutxo0i4CglxsdDR/13DRotphsJGWbndQnrodcBSPHjQhwyN/dYwPxqMQ+O3jfmc3h/0Jsdy3Bh3qvHJEFRM6V6330ZzGXW6ZqcX
# DATA BEM/rVMtcYfGQtsLha4TvzWfgkT4Qrq4xPW0rbnsRzvgYjmkyZpHorZGjv6YumwjGgbvXRP9IHUa3iKMxuzkzOLSGk30q2rK/Y7E
# DATA cAXpV2YdWYJJSr/kGGxOKOmnBEGJL+Wo0+u08g7npa4tzXW89MBlX08urASaRn237ivCHXX3tUOo2sOD+x1KG6kImxT33AXfDXR2
# DATA 5pnvT03kGv7U0WvcZlbcK4k3owgzHVvGHzrRZa7uCz57JSmtlLPkXFK6kFT44qeeZ8FEoy2lZAdXzo3h9MM2gyGk7OlSNoPRjini
# DATA JxN4Gi25rkoOtvO4dYiIpFxHdWSBO9dST7gVDGXwaKJkVurzWgikzJUFXTXUMH8dlwoRU9MSWp+5rldUXZmqolK6HzzO3sAXb9Ra
# DATA x+2LF95rjY4vXlAP8Zw49ECZzOwI8qgGyTf6orKFtRq89Nd/MiQg4pKp3E1+a57bqf9K6eHR/qjaHZg8Usvk1aV/hbTGx0aTAdSN
# DATA N6cWp3TTZqCIUlH3CTbmI2EgcXExdLdDF7Ylz2fm1HicaR80/KMyHA0enng/K3SpH9kOapZ7W+jqZjzcyOltGlCjQRNb2KsGHCww
# DATA GnUxR4y4A47l2e5gymDdUdcNNHy7iK2z/DuC8RFUCFiKjaTE6nLRmwsZaSkKXuG/rlnMLhbpQ6xj5WhvoyW9puCcUhKN00unb1N7
# DATA 09hXahoxZOiAP+gOSpldeBJ5m7RycNDzT8DchzQgScnETvNvPp4soIO8XsqcHNNNC442PGndeu1MHU2Tvrv4O92+HNUG/UNL3FYH
# DATA GEnEiL1WIwHKyFlCuWc7wGslgu6JnmejyNU9ibyzpzAO2cBHwugeg2MYv/6HFUOvPEt+xipri1IVgVe4gyoMe5HKhXYom8J8P0B/
# DATA 7CKu23VpA5h1dQomJvahLpVqwcRw82G33wd7dJSkmLWbaXUYOx/wC5xcBYPkOK/dGH6D9KyxyGj1m8XiYu019mPhVcHCeHj4TMCO
# DATA 7TeF0Mql4the2z1EnmZyBPIw1HWFMMODip1ed+ef6LkJfaCx20f8NNTiYcu1iMP6QgRT2GoWoaKzU9LsLUP986OsFqScA/JlI37t
# DATA ZEy0NJpt8ATvRTLicVZA39XWeNDSh1T4etwvl6UlW4pQY62SO0JV9Di5Ewce9zoS623mu4dG6jNlIyFNiVCGRIh71BFPYOYtqU+Y
# DATA p0wFNXdWNok01FnOElaNuz4NhdIF4isWItdYB5yJPRNden3B3vdwG9trMBgdYqISQ19VuoW5oC6zSV3X3Y1c1OVlFrq9+1vkTNuD
# DATA Qj7LBq3sSBFQv8xu8nIpB+bnTEwpHEY5kEJCYSp10FEoIw6DoDxBl8pHSu4jJYQrIJbCQZUDySYU1tz2XO8EjNn/DFtEWaoo6pVm
# DATA yKML7WkwT6PC/wY4XVKD7/Mqz1/nsYRBUqNWV63IHWr2h9QqYimz66uLJ2P7aEs2e8ja9s/kaFyLu7o+wu9oCtSHZXZOQuOSvCVK
# DATA 8dwNBMLYNgBrLyPfxqIRmPR0lY2hJqaSmmmNiRlHlr920wgslvlW64KBqdpVShdNSSV0Hjl412eD9y3ElG9J2GRcaxpFLWAPeIIt
# DATA +AZQCVLPgeNM6AvUuQDLI+pnofGCer2S594TeDnMhdUH95wghvX5ryCSTZLJG4xZemOhMBmDDxNbEZqC51hSOxMmqW1Kx+Qu36Sf
# DATA JqIwAkwDgXpLpBwltSNzwSRX59XeSdJpjXpdlLGYF+d0Rndabau6AaI9DtUdvjVmBMeuqrx73FFfHYN0nB+12oMHLt5sNYRZcP1G
# DATA l/8zvUaX5/iM6j7/T+kyugDN6QGw06hZBM9ndDnmMerCktrQJOxC6u6GqgQIu3XVIrC7LrxBzE2rFkA3mGuFvZHYJ3nQV3ewnp/h
# DATA IUYajrZAPnT7Y+or7hEtf1h/QgwYUbzhoPYglchpxcp1IHEpmilDPAoH5P6H9hO0gqq/dHK1/ZqenY0q9PheGOmFGXrE0O0KDJHE
# DATA UJbv4gyABzkQXafY4CmcISGSkF3UfmwKmwpitX6bwBF8vMMhKAywGEDM1QzQUFw3pCiqE5HOlxYmTjF8ygwgCDcC8Ik7AF/2q0Xh
# DATA IRzxLuoJgRx6ZgkPT8S6sJsbXNhULNGb31i0jNdcyey0IqW0BVtBNcVkZdNXP/FzDKNJe0adw50nGE0vlD9kRu4Qz6NcnPhmsLTL
# DATA CP5FeePU+fepevoniZ/7kmQwD0gTHxmkXCfph+8x3G93Hpa1JNhB02BLI1TPhc2JZcN5Pbl0DnLg4H9mOIYb2Ch0+X76/BeSA/YP
# DATA NFb1wE1fiy44YLyJoORI7oya28tyIukoakmYMoMz1MEkQMljsqisDC6urEwLB+6hdqg+iUoUUby9KbFBvcsJeVPUAwf8LOJHHM2p
# DATA UZb0VMWpJuyIF1xyrd9QNdlOE0Km811TDtj1hCucznKlsCXRppxLBpCOziUrEyjipytxt+6kypjL88SBK2bWQC9KyxJQM0zBMlLU
# DATA Yo58YC/V8XP8F5GCEy1W4E1pZPkNzZLV7Qyk+TwBXpNAeq8TuZUSGnlrBMpGzJlKaO5YqVUXzH412cAEYiAsqM9yBH1HT7BemyGt
# DATA hwDYgY2wRIEe3eNqHGY9lLfmebfbeyEuhzKC9tdy4/JvW76sKoj/WVAihPpf3D9fy1Jfm39S3OvfCjHm9F8b+I+iNidtupP4yt5h
# DATA 8WrdfWcxAlCKyT28P/ZAhCyxxYYpQI0GwRi4wyKVVrub4+23ZGHbW7pNzVAY016kXSBmG81e2wvi5gUrpitiQ2B5cr4JQav8PTfQ
# DATA M1keNE+iRlm5wmWCI/5fwgzhCHHqeaFzqBjPP3rkO5DaXhiUOhU/NInti+TlX2mtC3a1CXupxD/4BBiM7hFotassXNx8UuUqQMNn
# DATA EJyiGkEu6agDdQe4B+lyWuDLb2W9T3DmCFbpaWGSr0KJqVIxx1wBAio8aGgzNz9guXTBeaHDoElnpg9tVfYbhq1VkslYTobWFPqZ
# DATA xpH7OipLemwBUVPgSuYr+mYnK3emGKF5HbDZJ4mlApw/xRFVCuFqxCF5F8vlzOMtgMuQrahf2+i4cZ2SKILCwdpVQ8oJU9flQD63
# DATA oY3h0vk+7udfWoEznADC04aibtLpMbXQfGfjx5Ft8P/EG35CqmbIbUtNqmukXY+jGThFqKDjFsMC2GKQxbUDOZApk/yTiYfWhK14
# DATA MAGemzJj3jquALVEO92ZyyC5JdPfu+lmWwlhbsXO/bumtgzV0UCpfzxqWUgBu43pjOzXNfeMh5t9d2sworCbofrDADCh+/vWrdsI
# DATA Eb2m/pe6fq5YAZ+Eqgv9XO2zY+0sFT8S2ZHVcZEqu+AGhDCSptoTMQpQYoubX+n8ZFD2M52Clr8Jo6MU+5t4SOxhvNRCkIaF4OnM
# DATA jFLv0kHisPZhjEFdxbxh+FoM3ofw87S0v9hMZvMnruYyvywO8oX+GK4fxrQYmG0mHFspxk4J3isgN3gciMulGQ6g2YsCb3m8OAJi
# DATA GPYu9sUsVMPAXelFkSqjOGjfEE7lf5b/74vCjupMLa6AG+bcJn3sZ+BhoM2Ev3n2u3LCGGtRtacD7/QNQAey7zJudNdpqwh/z1y5
# DATA BtqzsmB/lbD2BfH6LBdw7bpeccqbx9aX1l1Vfa/5HSL9uVxwNqSfW3apgCJEWifoPdNi7QX23Fzc0jPs8vgZT2jeMwnauKfMEEkd
# DATA fcNoMFbyDrknqr1Ukyp21Q+KS1Z/kGXVEsDwHsEv+INpcd27lsyBrBDu3CCT8KfFckkWU9OEsNWRPRHFwJwboLyLJu6qFQVTT4HD
# DATA gS9MHdQFZkwFJRvRBm1gpkjtoLXSC4E3MjK1H+DGHRMvjXe6cYYBipkOFk4GRN4XvM5l44yh+yOHsKw4Czyq4ph+Cq20/OUZ5/70
# DATA 3Dn1qJycO6drmIaZ08vOdnSAstTXJdXXYQ/d+Y/USUGSBfzVBHpzJdLcCKNSFkzAA9hZJXkiRs48f0B5xQlkL68SRNlR52Hp/Fq2
# DATA pHMfoHgVg+XzvlAkvnVre+et2xvbza317e13b92+hgp+asgLkrAK39neuI2xEtahqF9eu+K+8mvxMAQPrOO0trwsP2qn0o3p3xgm
# DATA 3d6rvXrh/Npyce1v3r51c6e5cfNa89qtG+ubEKWfHo3Hw1zVDaRmViTdWr+5cd0U02/8KrfvXGlu3blyffOqKewIUpNRLy85q2pW
# DATA HrbW7qUaXKbefnfzmurZ+pXrG6p3G2+u37kOS6OkjEknHMiNjZ3bm1fNXLfax130JZEXsGLRlV27kAW1vbtx5e1bt95hgmi+vbF+
# DATA DauN0gUr5NVGhQBFJmYtKbtblAguFJKHrfG4M+pjnN3fwcSPOlVEoe7Azs8wOK5ePffd1JXbJD0kf17GXoDRsXrDY6PcPfhksmfK
# DATA c/6+Zi0JGIxUdtBrHeZ1rHJG/lqs/5U64qiqGkJ29Qq+spkDfMLMAIEegBfQBGNg515HHPDoh1yK+ZUb54j5jwTl1U+JBL9fTu+O
# DATA 7vYB3vXlM7n1IS6p1mtcBi8ezgbFuk9zwnISKRt5HfDY4Q8yJbLk5phuhq0TMFyrwYG1oQp/g/Eq71y8UN27eIGNaTItAvtEAUWO
# DATA o3Qk+RvXjSftvcxFyeF3u/dYYGBHrNbVzmi81TmGnfPTB+OtyZ7i2+8wIr3qifUafqo38MsHzCWv1x/CupOzq2NbKJkX5WTnZEh/
# DATA BqtiT+wnoNljP0fEKJYUi48wgQBp/gyA3CNAjAFk2A/QofjDZ09RJ03qWURqehrPa8qUefCyFmzqp0Rv07t906F6esrArYqmX2Ya
# DATA ftDqjgmxBBloSULUusedwWRcX1sxIcVWpADGuit2cAPRRyiEUK1eu9VTkmQaBRYJTz7WH0Fd1/CJYDy4O8cqBk2Srol9etS6dg/g
# DATA iO7MSNiFofWqZL4MRrX9I9VSdajWXyu5TC0BoAQQ3UryA6eMZ6r/QT1ZPb+68tpadIP+AZ0KwIvgEdz93EQ30ZV+lLy9s7O1XTEw
# DATA Ojrgrc8p7+3eGCMw67I6rQNmmZKEtwL/u7Lx1ubN5OrG7Z3NNzevru9s4NPquTfwX3WWBu9SK7e2qm7bYV7QTDDg34fDCQbDV1ZL
# DATA Wy763IdDuR94WcLzvFfd2rjRhGE3xwN1rN7Gv0vQCXX0ZllVkoWbicKDA76kJN9NRrlo8svSfgutaHBDsKYzc2qoMvwOHibJe1Tf
# DATA Dzdub7754+aPXl35vjqe1ZStX29efVtJDM6X6hzvHk+OrVS88O3O9W12p4c/768219hTvNVWNAdEDBuvejxQUwy+byU4Q3kvksnp
# DATA CEwpQaEf6CosLJUAWa07Pkpy0K6NZVJUb/tgYlc3hFK6uvZadUX932qqTzLDCNR4SmsQlv6wVF0t6+YqflcgUW4rV7z0QSQtOHRA
# DATA JujBqDVsUm9KqjSp5TqjpvCJuhauoD7FuCajIkFfkaRPMVQcmNWw0xkhseypW/pIreVgdMwHkaYaYGBCfrXCa5UBuSeMxffBP85B
# DATA uwL7IkSD/JOkJ7GBK9WCV2jDI3z9B2lWcGuhrucdYKe90kH61saOYmGwj5ZXq6sgELytpqaWnMoMTeHZVb2U6mbdA3cBkBzU/4f8
# DATA bXgcZ1nR7K2trAAb66Luh5pX7PN+6dXVNdHTZburDaCzCysrxTNksXv75Ly1zcemfYRugsOQf4bKFcgQMZBX3ut0hqUq335oGVy2
# DATA Yicy5jV4HzGm/5xY6JdfUFLM5x9fFqUahe58LHmWcU3LUbaMidP/g5LKgK0Uhb8KqRrFmo+/OA9eydxB8i74FqhjyzbZz70Iogyj
# DATA 3qYpnr1Shw67xsv7QUoJCAAOKFnB3buiLlV4bMoX2RRYz+W7favobq3WKCzniLsHaZrSzkxOT5esKib97sPa8v3WaFntu2WtxF4e
# DATA TfrLOBFV2NxQZYIq1ybctQf7g97lpVMa3FQu6WrX41QYgr5MVpK817SP+Ehr4553qke/bIJgX/D1cNS9r16730pf8wTZdHWN/z1P
# DATA RUBUWksG/ctL1hDwdpUng4ODy2wDUcfk8iQfLSumNOrQpCwfjY979L41GQ/Qa8580oHt0ESgyQsrF5Jl9Z+q9UG7rS5vrbZaih9V
# DATA rtLJXAFJtHKLLqSKJvN+90BJ1b0HrZM8+Oo2AKaMOqPK1kBN/wlI1t39MXvyVR4cdfqV/dEgz/mJU01vQIqQ5O/+IVl+CBMA3jLL
# DATA QhR49PW6EKynjojm3qB9QtLRymX9/nA03G+SuEKHSnJ+ZSX33gPbm/UeuAP+pa76s0gQu4gkSBVMp+4w1Cju3q2W3njpQafXqyCu
# DATA w3KmRqNOtv4J+DlfDj6BwcKpSl4JyXcnoy7+Zzmpq4XC8ur/qf3C7OBg1MmPSjF3nrK2/oo9U596qT5866ka/kpapu1T1/YNFNaJ
# DATA Z2BpX9NUYA31HiM/Ui2sYguo1ep3xk1UQFBAHLdknsKhyQ+RaaCnpmIOvQMIwuml9juq/sKF8/K0298bTNTS0otL8MYGK7LrFMVf
# DATA yanbvmDE78KA4fmYzfssaL9PTu7PPk9cARSvxWm2NE8F7var7l5zdM5La0WCjlFeBDyCKMLtYx1MEZGMTVjcJxi3ygCiX0t3Tde0
# DATA /nAXT4BYhBzrK/wljSxmGI4EoXTUBMXSnS9KoYIS1C+T9a3NsrM+gFHN7iSPkh+NWifmKv0FR9BJThU4zS2fkO6BT8sRsJsCaPff
# DATA YqATxBveVPfl9Ws31HXJTUj3CcsPHwEeNtzpP7TjqT6hlTZRDDG0d+0iFgSYBri4RV5nxXql3uDwkPzRTtO2OtbQLSQFDU2F0+im
# DATA g6F4gJymilFXgEdDofMrqB2BR1hUPXo1ZQYIcbcDAfxBACl4PekrJphX8vEA0rXAx9w8BODTX4GCUkfon7qGb+1lzHbZtu1QMw2q
# DATA mfS6x90x1dMfcH9P03xwAD1bXblw6dXXLqoOqWO3bR5Mp9PF/KRaw6EkL6OhM5eWpDWStI9cWc2SSqrkrFGOSciwXHl998Dcs2qi
# DATA pakhp49/xqCM9V22QVfozkTnHpx0xjRNvq15bVmt8rIaxTI/KKi53QEDY94c9Ou26bS9h7OpxNg22o4QXImxGJQg0RsfnaRTx6pK
# DATA JvH5H02j3aDXiI2o+jFWFAY+SOnVG9cq229vXMf8WPuQ/apykG+j6KWOfjiUe3BowtStLlMd6HmOSRbVnEAPVlfQasHiBBJ1TgZh
# DATA Jfmgr9NFOlhG4+ZQXfUHbdoLuW0eDnlKYLQFFeRQvaOcMrupZiBpI5ZiKUJa2j5SW71UvZi+MJHRFfLoGIWveqoucMd7VJtYwNQc
# DATA 7/wEhnln5yqso6Ev6aERqSwfiBnNLbKAw8NmNwfZ7ySp3Em++91Tx8w0TSpt5+G1K9NgMc/PW8u1lakdtqFosmCuacfwxql9v9Lq
# DATA Dbt9YI+L7rWiyYB21HljfY9XA+hmpZKrrYK53vAXWfcBZJ600vRU8d/jzrFa58oQRXR611HbCDcVlgGpl/oFv72u8T8o+PrFFYUj
# DATA k3/ttdfoFXAk+GulcEDFS2ucYipK7sf68gX6A/lJv+LKWr5zFttSpdSUOmwJGZmVGClkWPivE6QUis614kS+JPIVWwWLv8SbvOi3
# DATA /ReBh0bk07qIAeBNErwGZ5hLK+VESdnTQl8kFsBm5+yyTRgxuYty2YnqhKwUjsz0lMTcNOrCku/avjmBq1sjvn/DNQqplySNOsHA
# DATA q293RfZA2it0uoviCEaOrRnc2f5eODVIcwcU/eK8j+27mJgQrDBIDKvRbRs/1F/scJ69+wnOUe370K7NctpBB+KXXuYj24wH+r6M
# DATA DKDf6vHZ/XJWHR+py8Oo/jr7bkGs4Lg0qg7uvbFSW82y6j6GQ5Uyr4R6VcS/HC7z6jwus7oWEQbWXGGATwiBWIOoJw8VQidlMwzS
# DATA cGstkLmRkXDBp0gwvOPXCvYKvS3YFfS2tmZOM/fQf+vWtY0rd96CMR1PeuMuqG/G+8P6CggBTHTppZXaJVAIwM29Rrd3+XN50h7O
# DATA kgLiQmuwPa5CLymsAYzrtWVFI8vY9WX9qjYa6BTiFZjP2jL81zwjFWtt2U064zUu0WenVkUYpuZV44euaX/xU4ryN676iR3uJn/C
# DATA MjNuek2anloq8PGohVdtvXqRBSdl7q4RFtmn3NrAEaQLpxDuxoWvMEqUBW9EVuHAgfXiIieLvnVH7NVaHXMR5zGWZxCHkhuELKJa
# DATA vbScBN+ou2bufDQ4XM4nQ1gddP+MdTlk2mA1XoZ5EMEr1g3meAVf7w9GHe1XHPscMZWdUo24VIOKJFjDGB013HieiOYJjwGyKVjv
# DATA s/DSInTbEF/TYGRoNi9eknEvh71adLZbJpIipoVva6vVtUuGb8WIc+lsXIYMELC/bTZDGnh4Wm0vsz0YCyHDmc3ZXnBqzlrr/B1w
# DATA xgofPHggFcZMEdBHj31aLMtewBflj9OvI4LKqMnmx1AFQVQheUTwdkBK88Ks4JdftR9GhVExkRgqmkSWkti7pWZvV79iVDHogto6
# DATA WKCsImaasmf8wxOai4cnYXcpNquWiD43xYwgVk8Rx0NnglpQRcZeNrZcemcE0rUffjLTa/JMFy87oPw0TJBcS8g84b6hsQfi86xN
# DATA VJAsmOgQEgVX4T8XSlk2zcIe+kA3wlln3nNiMFbOeG13q7qr5SeNvDhG1Ukn7OjsMyqySTp7r5Sjyc9iTtB2kB4QheIfTrCIYMdg
# DATA OrwyWM4GD3xTEttrBr02cPcHXtAAZxZxBNYSVpfZ/qggXqsanBAtVC3YKQ3AHxp2xd++u9N0HJZTzO91bZP+Qi9d288W/hb3WYBV
# DATA Nk16+dBVOUrlI78CX+RyzJkYHpqgBvXLiUFwI2XC2CI1bIqSeKkO80eukZ2TrPBu/991TtCnz/7MUUSYaBuDaSHNdiRo6PmvCagA
# DATA aqbIRkUahPVD/rb7ahMoOum0S7ulY3IEBPMzhEDwz21K+mMeXFOXxm4fd4P19Pa7KQdmYzYojhG8gc1xUtZMKKZJvUDCaeoe0R+G
# DATA dPi3RTXgZ6Tu9BCFJpmLYAej1WWQV5nWuD+Q+O3qne2d5u1bt3BFUIWuT17VWyuL1DLF3arKEXYYtV0GmUNeCcishR6G/WHjphkZ
# DATA W6joLcR56nGa5TXPOLNNiT+g6r+T3JJsleOjUadjMBIrkMYIU0DhAcwtHrdOkr0OuAZ02tVkA+FUJI6JK8SSgME2bO11e93xCV0S
# DATA y+KijPZGEtQUq0A9GPBZBHUYD5hTdHOBVjRQCbRGXzUqNIqfIFMtjUEfI4xmZrA40CQMHVYCj0Yz9VmwL3VJazWlAoi2AWsj0p55
# DATA er4heLxwXkXiqvwwPbspyAfD9BNPLbZgfZSbS2yQVPWqJwaOOr0Ww6FRcbMDqvKuOR7QhpIIdxt3AQ51/8Nu3lzo2zBxsg4e4F7B
# DATA 2oKxWR5UKTkSSCtr+PKF0rq5tYFrKdflPF7F5B/xFdiVhWqEaxHuYvyl6daiImL0AR+IsXcEX/iYjNGfoxI3ZOyRvJvquk7b9wbr
# DATA 8UAyuKKIFXCW4PfV1nC93ea/ro0GQyw06t5XYjWYaBvOSeyd+yaCEB05wrp8FPTW0D5oJIywlpyig25rmClZSF3qkfjs1F5X19WB
# DATA z2HfLcToKHlB/OAsGTAaHa2qzho3nhAWAXpDBw73C/4xhw3+so6aSMynjJj5pFRU19Un7ynJwihMpotzArsJnMriNipnbkNn5pw7
# DATA d4pCLU5eXDDq/BHKJ6aCmgYUB7/K+C6DmyTWmxZck2t4lQZlL9+Y04gqB6LGLJVPtGCotEEMPOt3eWkqwYGQdNVkf40hWfjJXxd3
# DATA CBFgcHnv4oKbavx6ZqGCu7hA0ViFuRjhvn8SayVLZ4TSyBbHj7LRMIpBSOeOlzIVWxAZGgWGPHkgYuf5zxmPnvkoPYQZ+PL5rx3W
# DATA it6e9cRWM5TS+JkD5G1fJKtHnYdOBt/Tmbguc7Qj0BF+Dn9mdk5LQXY50DmbyppJF+QqDWL+EK+MRDk661yZyVt2W6Y3WaQwrBze
# DATA RC4JVhpV62ZXUBrM6ajdWk5dPzTpZQjToJYJghikQBmuO3U+d7CVGsoVdIw7jUGciVxfOKFD4QXsX9xdE1CNRW1kc+WYPUw/HvMr
# DATA U68+dK9pnHl1NsiDlvTIGxlXO4B/tPL3EsrLV00KSz+cpLD0h6UycfOrmop1RUKgpg6r6qmbMFPVpXjwfg+cg29KHtad1mizfzAA
# DATA GFZEf+TfwnkhrSEqPzpK6uqMW2AfKoHHaTmBuCnIXmAF0wzGiNutOtIaq25wCdW7pt7juhYCFVWzsgK0CVVWwR3HUXfJQ0BsB5zX
# DATA c2tI+NiMenQxOSfPYwcojJGvdNyTRBrHqItOO8fbYN466CToLWcp6fmLamHPIQwJOrJkJgosrs2h2jdFE4QDCudTCvrZBNFCo1if
# DATA qViX9Bo97E8gFfY307BUXtR4rgR+SDVS0DaHfGIhxpEjINIxtDNEXQle6c1yHXcPR8zpWGpAVfH+2E4bzy2VKHeQyZwDq9PE5ayv
# DATA aQI5XybkBn6xuqL+x318+eWXr8DEJBQAQKqG3uAQQeORWDijCaBgItJpX93dgXDQdx2ALu9Dp1U3OlVV2VKYo9vmQrJJ9vEwqCcr
# DATA SzrqS/YgZDAqwV+DvZ/WZXhk6Bm9R3m1u2qP1v1NjEFgPC3ebb2DfjBw5fBfE4+DvrxST1a9ICPKzEsXYKyCwFLpihdipEwwYY41
# DATA 0bBdw6+VUNbaU2LbZNwhySytVlPCih2N86Lj4k4fN2o/3NUIJquxObAbaRY906gX3ZxkQnFN148ZyVBPmHrExJ3N6JUm4n6M4UA9
# DATA YW+4foqNTVasJpnfGSpWFxSkmaIeWGwu4Gp6IyXow+x2o22ObWBmJE78dNDtY5KBc6QriE2j9aGvrGBKX6CvMkMEhaA4gCK1ti3j
# DATA FEwZL14UMdiawnj8nayZDqM1oqhE67uciHsZCUO0J+H4HvQJd+jK4LWVFQgWASSdnMNBENC7ObhnJQude4klPqH2pDWoouWrUnNf
# DATA pR9w3B5Nxt1etd3N7zUnOaRw49WsHoC69AcOhb6SXLxQdPyamd5Uu+PgoLsPMU+A43sPmawSs46RLfkb2ub7UVWcnMp8HOB+pV6F
# DATA o6FvgiSrcwlSIsjVl8dq/4Mvplv5dwBCuTfJsTCECMMGYpRsRcMTMm3J3reQsuUAIbNVLOwYulx2VhbPgvThXorMfTAZDyeRXGT2
# DATA F/tHigBKuP7WntDo8Kurq6Q5RPD5kBhJT013lyLSM0HWunR8v+31ILzRUo622iUIktaflZOLr756/mJx1C3wG6xlXshxZCUfqBkb
# DATA jyZ9WI12QSQxzWiVgfChoXg5My0VSnxVUJbrO1D0cRSBDB/k1YP8pL9fknJqEvuDkmtVxBNMWxOHJzGpx1KXCNk4vFf9Te4JpChA
# DATA t7BhaqlZ0N0BIbdpo8D9sIquiuzGwP6DZKwWZ8ItpEeoHCxFbQh6t99ubm3g885o5D9n6ad7jGE5YIFpgRa1ugNPSqvgiSvF73V7
# DATA Pat4td3qUGwNsC3rOV59BYAEokJVEa0PdyL7gzD/GfKk9IKGVw6ukD6MOuxLIMHJyOMy0iV+ueSBsemhluyEP3bbVQxRt163u63D
# DATA /kBt9X1YFquwaoo21+rF85cu+IkaytSVXImPHXUL3HcTTzmV+C1qPxYpB1AoJQv4xDjaEa8EX7urg0mvzbDRSsRCURmYBcp49hgQ
# DATA MpD5tPPGvgXSNPr5GVFuoyZjADVX7cRlnJXxaquPlw516PROcGNZZ89lk1fNbBFJCtEG5TkmVYCawtuSJnTAie11FLfZoge8U8RN
# DATA AHxRrFEKQLdqtGcTKxL3PuD82LRBLpHYzHAAVBM/2wooy34VrCGxmrzfGuZHA3tTlEBpoPo/6dvbWf0sE2PCQvUCHmWHro49VUYU
# DATA /eY7yXrCoXJCFsete+q+SAcmxOiBabVHohtCVXQ7REU/myhxCbKGdLpDsBZzffuDow4iMMrYqsltNXfgYZzc63SGuZtRz6w8JcxQ
# DATA bHgwATTMqiRM1+grag5KNnPldxAnzAMV5WQD8jegezgJYUrcVSPuNOkE4IeA9iF/epvLdMoBktKdYWaRWUncPP3iZpvgh4KeJXZe
# DATA Zrb4wlTbGujbk34fZaBIaiFKa/cJqOfoTwSPwNQ6MW3el45anPOh2ajomE6IdH4fFQWD0iBmJAdlJbNVGLW9Da0ah58BhhE+ZDHa
# DATA eDG8ZCurGenoxWymUL1n6jlb4lFvjh/N0pda6vbInUDfAizfC0zRBEmPuv3CnerKGQCoigmDWBepqBynnB6yOrLhuq/Rnp5pnDea
# DATA bZh8VsgWWJGpvkZRLsf4rP4F8b0/XmD6jB4nmEQ7jbSapjYDp1tM09lngYzmauGhhirxQTi2a95t4xoxmdxcmfttyvqpblRwoZh0
# DATA IS+S4oNJay8HbtfrHLYQukLQCk1lhpzxQCPRahmi3uAwVX/iLY1Flrya3IQ8Qkn+AE3XyC17CDBY9e9bM059bYbCgZKkgTFZDj04
# DATA rwttBv9KmU0+oX1BRn3bBvU0uriSxIxw/v7CkAdfSGqPaP4UhEqgrAq/0fhbxRo8P+/RrugjzzENjQ57g71Sei7NPIoFXR5n4qz2
# DATA CDctli4pCrums+1qK6ebfjebNZFsVRHAPchh+QhAsQkWApJa/kXDsIHt73E4r09jm2aGSlFrNWDQGh3OGiGr4OiGWqRhRPWtbQqw
# DATA FL2FA/59IUkIRTx+/svnvxBUqigmHdAYEgX6BroM2ZsAHJB3Fw8WS2Zh5u18n9Jp9wGQrRTjsTO4NwI0O2wavSLmme8zGwYbJ35E
# DATA YncJ/5JwDj+toueZq/OIRr5x9gzJdHCXgo3D6IoWkiIoV7qDSZ5mzuMRZUU+CXYUoZgRtr7UbBvQ6X1cR0zvFvQ0Ybg03PN1/sVd
# DATA hsSBaHl1lXYIpuaVJTy2SGnukidxaNHi4oUpXiigytkb3TsJMfWF8D3E+CLIFcqIodjr5+QkZSebF0AWtXs+gUdhV53JACKDWArE
# DATA IFhWr5YfjlonnBlCFoWGf0z4mPDJ3qTf7gGyxcKOPnajL82nbEQ+phkrnLDfeqN+ImOm1L4srT6VzAOUB9g+hCAvgZpAzgbsiHGY
# DATA EdhLvOUnj/YTd2FVT3RWA0Sp5eyzfgfj9CMbkCnFYrNqU9gZIt1yJP3OnKrIaWyDxtmnscyNlbz+D5RnF9DiPMhPQ2NL2u8vp1yA
# DATA sMgQCmOlLVxPUN2mxDAUONS1uGvrncHxLhkOHsC1bpDnkDIZc8q1RmR16HceWJXRHcByIUoQKTc/QonmwREkXZDbpFgGW/2ThFUr
# DATA 4ENbtRQ2VEuXkIQsbCuQbJVsgOe3Izeg0G5kheDYsFw47M/Y59xq0HHaQKghctrAP9kTFFQTAL7JqMM138CAIRioxFLTj6o/Tv+X
# DATA V281b1+7dfP6j5P36JcI5vrBzVtv3rp+/da7LkmOY7xVa0VNk+5XgY7E+pJUVvaXDNoLKt2musiry7Eg9nI+o1pwUfxKzu5sD9fJ
# DATA yotRdr1vjluc5CO9LRUn/9/7v0M5Q5Ke2flKEjvtvGAQSkQqamo7IjzSsapz+BS7gFUJhark+XeLOOGndGgySNKuDwxNqFh0KbSO
# DATA wMxLEQGvyxjlyEIePPCZFlHrUiwbp0wu4XEVYg7k1VabQjVpg5hNZFmesX0nybyVIhdyG7kJ6Cm+13DP2lJxq7EvGX9KXQmRGdDi
# DATA K8rCBI6f42qjD93zDyUXJtKPmzP22f+YkZfQ5NC0s+p64W4YnYNXSklrBZmDzu2mCX4dMCS7GxIv2GjEagXUV304/Yn8HiEnz/uC
# DATA 2IZ+WbMbIzamJzRrOGkI9XMz9zSfr4CpI7EDGeC6goK5SSX0eeInhH725LIHO4cHEayXXAK95IOccKjKRhKrdZgB/BB38Ac47l8C
# DATA dpt1slUTwbrDU1KV+hyTjr1P+hzBFHlUkPRQMfA8qfRaYY4Ectz8iyr4BwKl13kSq5jFQ6f//sDJIIihTghAwg7xj5GcKD+huNs9
# DATA e1oNG0yJFu1k4PwNJgPnSmFqkUINZbJKR6M8hBkanv3fBkFWXc5cb1pMg6iqDCukGPewNujkEyJL3zNXEWdYz6hzqG4zcD2ID5p2
# DATA K1Shro61ZL8d3XTqYULaYckelQwxYgBNiczrYWtNcklliYGk8Y3fiEQmGJCIcgRQReNoVCR7SHX8cKwzfFHYd1kitMsUVF3mWSzz
# DATA XQ3+gNhoN4rBZW7k0hNPWY67w87RhEbHyHxJPZl2LRuS0MXyBtvk5yWJLxXqSUwu83gqcMeNFhmzrzqRfMa/h8TFlB+QBHDc4G9u
# DATA Xt/YhhkOhF0rr3GYf93DgrbTRsuQDdCxmg33WNGNwjoBhjU475Rw0jNOysFnGSLozj5znv+yDFzn5yZB81M7HWuckaepoUxDw0ie
# DATA FA0tEDiOwWefcvcEGw7cwU0tagC+rgBjm+Br6wojxkDzQi++ZxjEZjoj1NaiXoI+8a5MOFWvSKJe6QmtoqnCEeuKIqXVXkcf5/cR
# DATA N8qW3QxRoDBTUG/mLnJW1A4ep3KWJ24aKQ1WatrQQQTmPKdw0oYvh83vXbFMFE4oTMe/uVQER9rCM8H4Kp6WDRPS+YOz2eGNAqci
# DATA 5CCHnXk9/j0dz0jz/xiB/6qxIHPYWYgmZtOFhTPmTUzQwKLE4RNI0ESEVqgxT+IzO513sBHXgrNzOYjfV0dzlS+1vKuz3dr5Nfdk
# DATA mbuHAy0Qr390O/MCE0VM+hLu207nVWoRQDCOMyz3IvQeX1ai9FidC211M+rCTW4N0YLcWkbZ1Zbh/kIaLP+s+Ijxh99H7RQOLcGP
# DATA nkhm+GdPQ5lRWvlBWOPry2SzYripyrllFqOBTkGQ9mTLaDb6Z0/LoI3Sujv6CvIBWdncn0S1cmFnQRDi+fiPBeRRQklj6pdL/CzB
# DATA My3rCHk97Y84bQKIGFzyzzqqykFKDsXc31sXjid8g3ms+obZxhMYOHboU75C4E3EzBJfCMVEL1nEtc3H094pMUFCaZ//XO5CbFpH
# DATA taGWU6x0WCzDCK+ISy9ImEZ6IVUOwjTxrkV/7BH6gh7i39X10eEEmtrCN1oTpHZsvdlUMnizmVlfwhW92eJPSulg2BlJmNT+0QD0
# DATA InXG9MFcTymGkuVoaOBEuJSCG2FlQMapsLiN39h/65y6GCeQMpJPaySod5juC/4+JNw74l8pYjLnRxXaLVgWE+xYDxyuBOgxwUNG
# DATA 3Qyec//QH6UyGaqTkeKaAXGqOxawH+pNPgbFufVIUPsqjGmAU9Br9S2/B2yQtaPeY3Gmsr0kRuyMo2uiGYWGKtwBe7IKXnPn4y9l
# DATA HPTWmQxMRqGXy6A44D0I9YbiwBAlnUqFbWrZ5aICbKIrLiBuQzObMRdBm0Y9Abu4DXO6zGxFEKNmdJYS+ha+p6Uufs+kRODpM/uC
# DATA GZNn1DRipySIzBwd5nXQlM8cm6KtWR2jxLdmNQpLWgomvfqzGjY7hWMF6+mcniKZqs8qkuayhaayeopk3MQUmbObRDyywVevA8CR
# DATA KscEfGDIrijdRMMaoimzYCsMsqwrwMwXl2d+x6BMwaeUNWNWs8Qb3SUpbMuvHkHoZzOFCHNecPGdT2m3LdZLV0wNury6Mnfr40ll
# DATA VlnniUf9CuNR6xrp7fy1PdNMA2Z48VtOEceNsnc7l8V/oHRuYADgV1Uf7joHCB/qRirxUzviTQI/Rm6WCexYvEo+JWquBkeMTn5d
# DATA 5cR6QiG6s6v3z6WaF5UsNx+7Rh8sEx2VghBmv2u7DqyfpQno9Ft7PVSZQBbSxXBGEM3EQGooKlq/ft3FH3HMSpIXAC8oqLJzXg8N
# DATA nAr6POsoAHupAYgMpoz6a9LOcP+jaMFOCLfTCY1IZ0ZRkF4ePmsDwAgmNYDRzRplmxBiOM5/sdkEg3csV4JRGFrLr02cbiSCXkRn
# DATA 7lileaIogtKhUymCTewP0tnEaQupZnrpQRNedsj9vWqQF2bW50uSZyJ2BoUoAhfhg72pDir6nh9k5STWxQWn1ioizn7QgdnDjEnH
# DATA lt9UxAf/jExjppxtXce4mO24L8XcYZ9lEd2LhZUuJs8hLym/kISfeTg2h0cy18Qf/ElZb/f5KNumJlluzS74AdF6ac6MepcjmzDh
# DATA RZNfWJ3mXsZnsGhAszvh38dshTqJdU43zrLpIhcnf0OL2b1ot9j7jxLBIFICV7fYMuMTbk57CzLQEqkMy56q3mxq85mJZ3A/5XUP
# DATA MyGYjuCtI4twC74fNA3XMB9ZN4Kmsz8Dh+BZQysn80bguTiSm2e3P5yMHWQQdLqoGXsTCOnkXlhzXL3w5TTKyyjmx3CyGawOvdwt
# DATA dPkiMpt1gXdSrmGphShooS07sznevYuRq0WpC23TQnVDuG+pAw7+Lha1uoGLUba2IPdrjklTVTePt7m6JWstKKkzPT8TS9Hastos
# DATA 6pFSpXlHs4V4HWWjzPXQ/jRnrIH+anYPuXSTS8/qachD8Ad/OadbRqXoizxlgKBHpBkpEiPNs84gpzfw+6zPRvwpJ6NQfoA8PZM3
# DATA +JKS4w5ubaXLcUBouG2ogV+O+x6BoK0NKFazNjhmIyrHWY7lc45FrdidSSK0c1Wx0qydqYVMwjSnH4QTG84tKAzm0EuoYKj5Ir1W
# DATA p4c44/EmnS5mZ+mAaJoX7IOkg/q6uzF3rZy25i6ZZp4LXNDnNo0SNjRZ7GVKEW6ItktxABaZLNIHBrg3azBPYOseYxKs/MTEWqu/
# DATA q+RA0wdhvbRigUE3kb82m9Ye42jJLKhTI6s7TkPDZcrbMMO6awUsLIKyCIGmn6EXG2bUCuOQdEckdyb+KA3LkvnDITb9mekqhf25
# DATA qCmXrfc6vOfVV312qMo4jlZO2vOQHbho9JoVz8mtqxGA55AIGaDC00XYMiVhXui41Wks7KNkJnujnAvWeJyCRSwgkr8s8sJuxk0/
# DATA WUbtj2m0P7DfRSY3uhD2QycLgJ/k4aucUG4VGwBitQXhnZQoYk41C5zCl1/sDBRjpSMwB5kNAuFjYbFENHbaTlFBqHUHm0Jc7rTD
# DATA Knqp/UVnRQYftVmQzgE+qeYP824qaS1QMXIKoRjzCMraOYecD6LJhuQrIK0aJTw03D8sRVuw5qY/tl9lMfVoLekO1QyPAMGhO9RS
# DATA rVancKZ7Oyq8aJIQaXLJ9/wPdMpStQM6asUC4IdlRJAPYeOLYgB84ULtj/uclxtu2RQXYKG1OAlDTA1W/EDxVQ7t8bW5UuxSQf4V
# DATA sVnUPIVPSqadmsVDp+GSsY3TRj6pxXKpcLn1QIK2KpkvDS8tqXabSErNJg6/2QQibTZ5ApzAHXLIWLLgcELAFcDFQbyU2iyhQ/b4
# DATA vz3/hdq8fyDn9wLvnrmu4Nic4i+YoA3EGQomt+BsEBxm+yQfd443KC+iPYjSD4EqsPfl5J3OCf8F+Tv4z1vb/Acicfzt9q2b1xBq
# DATA B59mdlDaJqpmMItEt7/fm7QF6QxTQ+S1pI+R9Tj+ZNT5KQGLcNZ5iMub9HoJNFD9hqevmjz7dxOy9/xjguVgmAQdOVB2kTp+SSGP
# DATA Fl+mIAI3f8rzXwKi1JlW46/+1/yf2mV7PTg51TaqDk++kTYgKP7ihQv4r/qf/+/KxfPn9d/4fHV1ZfXCXyUr38YETMDBXjX/V/97
# DATA /u/ll1+GjaS4I5lyJfQPQ+0kDw0p3bqAGTjq9DqtHFCOKMJ0tbpW/f5adWlp5wh8eO2CP5soET0ZH6lzAtHkOEAEMUC7h5DW5qjT
# DATA G2IcyhGwD8ApVG8Hk8OjJSykLxTJztWtCoGoHnRaAFKEZlSIkTV95PTdyVHrfkf1rgOe5WC1bFdV3zojDL9tqyN1D45SANrqD7Qp
# DATA et8+JBCx9WFnf0KB/wCcBRIlgRguAZDuvCMp4B/pzrzxHKlDye50+i1xHCc+Z/+n+X/C/n/t4qur/v5fWzn/X/v/2/hfOsk7LGCn
# DATA l5eW1EbIx8lpsjXq5setq70uXrjpVzLFgAbc1qX0b4b4cHkfy6TZZf72pw/GdjEQRx509sjEkOkWtq/e2sJEILcw6RQCuf59p7RL
# DATA STxy3Dk1gQP3nUXzGmC+KeFUcgBz7o/AJ57f5zV2ZC0uAKK+qqYBPTyY9AmZY9SZ5HA6lkaDBxmnLJH8eoMHyV//NfxT5YwuTqy0
# DATA 3RB6vaeqtNHjwGedh0M1Qetj/LQPMtV77yXOi9cx2941ENmzLPg+31eXgryq+OohwlrUeU7lyXvvOTL5Qt+8kqzKqLgoS4i5G7mC
# DATA 85m5neKaQHY8KeHXSf31aFX4O1MzPV1aakF0faJnXF0T73fhLlIi6ipjqg1JWyZrAFq7l5b/bnel8v1W5aBxemla0X9fmFYu6B/n
# DATA 1YtL32/tNZwn8vfq2vS7y1VIjI6ZIWH+IR+FNXGQJmFwIEnTXiItF+SdSKEwPZa5+0Fyfi0D+FBFGbBujO242ceLu5xTdMCo79pq
# DATA 03RbkEHlsoDpKbohWppNSXZ5cYKDWxU4jCU0bdXWsIvJL/MqQF7d6Xd/NlH3vuQBnIM1tb1xvNNkyo0vLye3O/lEtY1JgZIWHtgV
# DATA vJMJ5FZZHDOgOaTREzyEAWKiixGBqoetHuA2DPb5HD1IRt3Do3Fe1cumO6zI7CW9v+RpJiuMk+9PJTuBJchLkv2jVv+w074s1kqU
# DATA BhT9jOm+Ygdck1svDZVSqPTUckLtdTODakELphChlGH6MJm51UOiTVizciK7tmY2Lfyn2h88KEHUwOpKci45f/FV9d9LFy/gOQeY
# DATA Qbg1aslutVqlDcQBO87a7IAINei1k8NRSw2H7mf7g5Ea+XAAiRMgZx+ArE2U2KTWAWGFNRhbVa0tiBRS24CSDbaAelr7GpMNgWed
# DATA RQYZrIt0OqalxjGyGBRbUPl7IeZhzSOtRMHsi9KCaPcU5nxaxpU45dmzJm86dZaZmbU6kqogcZZOecnUmTeCZash4wXMkx4ELa1v
# DATA bVrxK92WWswbYHY46A0GI2SgRArtdUxmAwDBmFByFRdTf6i6U8Dh30hOAdCuBWrsGiBAd6aJIihVMGhJPg4bmmbJtGw5UwITKqs9
# DATA 3eodDtSGPTpWI3l7GxwrkIZmMNk3B6NNYktRdguIoP02Kh1tzhs8lA2132t1j/PLNrax6hY9BYhQtQpkvDdVmKZOdfdhO/AAGmoA
# DATA aivsA76Uqmr5XLKetLsHBwSdiop1hMhULOeeonjDViHTS67YGOxFIeFqcm45mTqmH+6bIl36Cy3MdJYDLcALPgL4PfLNun0OWCcg
# DATA 7q+v81SyGnX2i+H/M3eOzfqF80NdNXs0esfY8+IIPpnO0xMczlY9+ow2tU3DnTjnfEdqpQ6g+FildGSYb6o9UUujmLRg/bZGh/cp
# DATA l2MdoMFlfmheqHbAWVP7Rokhpy5RRmZyQJIlAHVjru0SybxvVKmqH5KK9I0qibtvVPNhD+511RTgbZM33oBsQa/Xk9dgjwe6YSXF
# DATA DseQDxHosaRlY0TuaQ2Hy6h7pyHmyyJY80eV4WGaVak3W4dZ6TTqXagG0Sfosm0kzJqeJ3UQVu0cyGVIoFVL1spz6tkhtN8b3Z6S
# DATA jWuK9TRXAKO12+51vFfn6VVQ3xS4EiWMp5Gr1ktF3cqqeQdgRLdao5YiKQqWpmTzGUxvilF6+8DT3JaAg0L2IEXtShqIgBhg0/Z9
# DATA psRrbZOq8BgXEsqXQK6x540SeLrAZrp/T4IOiEggihB7S5yU0+GGyEr8bBYjtufJWOO371zZvnp7c2tn89bN5s6tdzZuNu/c2bzm
# DATA Focs2mSxLwdo6jOqu71xR3UZKzWa0CpIFCWSuNQ+8mDgSWlPbzkw0voUp1Q2IG4zxV2rHZrKIrzUZ5/CI0RnA2O6jnD/JwvTAi1r
# DATA n2HWQxMzHsS/x9XHv3n2OzTOxZHffLSSKgZ+yNw97I6vorU7WVXHkjVSRgHjsTIj/i56kuF2KtFth3Y4HO0Dyl90akigHKOGstyT
# DATA p5eXvgX9T9Ps/q9VFTxb/7P66sULvv73/Npr/6X/+bb0v1soR5m1F3dXTCEBala1b/FGEahPnFtWp61uYJhnjM1BwCkvXpBfoAiS
# DATA vwf5EoI8g1NPr7sn9iNwJ5Aio478BXZA/bfG+pcn487xEO53VOFkpI6kPYq7klrBdwMO6yVdNaWW5RBu8q1Ct1Z0PSYN7kF7EWhB
# DATA QRI0v29euX7r6juZSZ0GCIJtypvWhqBfzpdDydMsAyRBLSPeIAAt03svC4uFNwaFqtvNze3bG2+VbLBeB71XUhRC7o1YMgpjVSyl
# DATA mzd/uH598xqfKhAD7+LbeDCXBGskDYFYzGjZpys4VeoA76inpWwahRNeee21bF6PTE+aN+C0urLR3Lq9+cP1nQ0H8xqPJp5Qk2vk
# DATA VT/XiPacW3I8umnl8b9Oqht8wiQSLezkkLB8B/At+izgUvT0B+FCzFkEAcsncq0GfoLcaSFjcrwh+E65+2tnl8LumpLSYwpOYyB3
# DATA HoH8hkGsrVy4hLnx7t7FvCl2WQjFG4zapf0M9GHn4RH/VFL66tprFINmf5UtMh1b6zc3rpM0tUSp2NFFxM6qg2Fi3BG4EbQm40HE
# DATA Q0Imk3BZfHAYvFH62E52mguezdLpuXPspSCxixjagG4PTrziNNi5pjqe6xfIcxGfLcV51q/LXN1c/+H65vX1K8425nnLKfTSbpWz
# DATA yW93xmPOIK/b51c617Nfm0YAR/ZgQ8Hp5iTvObOIEibuRniXUbeNscRpH/wGMwfeG9sghajf29Zxh7xRAZcedjWkEPZnWvoXS4+R
# DATA 7q5XftKq/D3AVZs/m9VKQ/EvRajTlBR7Z5r0mxs77966/U7B5BvyTFII6a0tL0uqdJPyCuD+mETR20p+2J5tejJ4gUDe37p1G/1z
# DATA KQpce13aLkZW+/pPSI+A/bD3MYVZYtQx91FeYV3qPFVVyKlqWINsQ/Wmijc3e71VZYgfgkHOms1AUSAFnAP1DH6Lbk5+C0qg/P7Z
# DATA pEMpT+DHwah1iMKHLqyOXN0qouNSa/gSDn/FG1ZehOW4A3upLmPR8bxMbbPqfntnZ2uba7698X/c2by9cS11Th2tsx0Zsi5L1YrT
# DATA b92+dWUD2JgSs0hvIblh1WVifTI+Goz4TlpL0ivqQq3YDMJC+de/d9d/uNFc39qkk0ZdL9ATOlpKzwRDEb4LUISagkkxxb3YTX9U
# DATA UbeXB61Ru9OGv9DfK1X7qbqi/m81vRwvuTUaKG7dSPSswm3J01oCqaOABu3R2Ft7uKJ4Q1+Hv68SbFEPYpbLOqVbThpUCHynCxp+
# DATA V8X/QrlLoFVVN3JRDbFqDZXreUfr1w46wDjmzBFDxyr2yQMFIGtyVa6lePVVRAm66FavRt2gH6SFQ8OWNFwd3BN7EtMPBX+09qED
# DATA pFcAtSsIefUVwEiY9O/l9d0GvAA2TN0u0XDwLVpkpPq9QftETSZ8/kodX7Mp63L3oARPX79wDlNXwH+yU2fSLkf6JRWrnk2pL9Uh
# DATA 5Bq8MgGFbRXk8xI+V5fhqZ5m9CurozsZJbTl4urtvpKDqaKsOh6QXgulOSXMmekiJ8/33hNNLf5+qV5PB2hZRksdFarqJfVK6xfW
# DATA Z9Gpt4a4pPesW4V6MRVU8OR0v6f2oBAf0iOMfbpUQuIuZfXXNTGLsbtOy4acfbk17C6TMXxZG8Ozy2rgJe6/PBUfThgBq6azyAA0
# DATA WMVlaZYN4GGrRaZy61tVfV5fH41aJ9Vujv9yXHuevSGGdf63yv+qb1XnX3I/gnqyWHftJtVnUG53pfEGacQX7vFy+grGIHbu3N68
# DATA KlEEUhlr1xXDyUqZVlmpdfH1VZYuiZwZLdQzjVP8CGDJtHYKSn1BPosEPP0JPY1qpvBwKCeqDEKdQa4FSuBCujDTACIy29iPmCfG
# DATA 032pKfPVVvXVy8Bl0H8JrwyqwF6nxCEM5h7AFxg+dBRfoRjjsjhYsUhUfIMKLxnchn3DwEezDsut9bc2mps34L+hPEVZyfnqX93p
# DATA wMW+NTq5JjEhJYKqgLySkgINKQKHXKEr+MGgpxi0g5UusUn0KuOYZ1GJQTiV6TALZqQCRSjrNHIe1G3xiXSkkfMXSzlq1JjIXuKV
# DATA cDLGvIjgHqQ6QFtYpPLiuwhd/30pm/+0RH8qyHWbpH+xNCpIXCZ1YQMxfjr7mPkVQtkqDCmN/tT9+5mmzF2osiF4Y1Ac/ouikoc2
# DATA ErjcY8vguNhHMcIaibrQqIUdlfRAzG0lW6zzjFtdqRAkX6UyVLcPvOp0GLLPRuGiXhRDRxTNAT5XC4oElppJ4C0XnQtxKtc+47Z3
# DATA uZVOc1v/6XuRF21ZoPr1q1c3trebb6odC+ItpXPDezqxHdATGvwTzLpQxHy4RcWybtNZq75X/LjTBh37fUwsz3NC2sfLSX7UGpH3
# DATA R0KpJxQHOrHSZQL3szzWKfkO3CCWTFK9ODARJ6tygYjYK14J37HNn9askaWRfa8K4ICnS5JFAuoynQKWgxmE8pKETlE3bFxW/JbH
# DATA TWBIAuwQrWgwPgKg7YJ63Fw6fJcvJ/iRSddhT0wVagKcc7nkv6TzL8pcOWgT2AtG6CJsjtMUl0pNxul0uqRzvsOAal6+w93Uugjj
# DATA heH03DlhxRJwb9+VOcWdJAnRn4Km4dw5Wr5p5LJsTZ34BrsVExbFaYoOU6rrQtApjF39hn+m5SQgmzLTjDkq/Xujemb3mt83KRnV
# DATA /C2ozkvRQ9yA2N07N7fvbIF6QN81Q00QZGCxIafkLbF+/REGxsWUPWUD8Suf2mQRRlZRmhU4Gkh6ppGCVgc1hbL9ESXTHOAAK+lo
# DATA eaBDtp5JH0pWi/JyF+K9pGVzWNFzpwMv1T3+s+B0X711883rm1d3ItNszy6GtJ2qs20Mio6eohVKr0vN1+Qba95b43ELuBfgLYSU
# DATA gfjJKdfuJTa15kEq4SlwRyYvw35OZ0WsWR0DB9oS1IwXPfVtXto9Z9qESc6yYDfrIWBcGJd2HEYQy4X4Q8PJn4QMv4RvyuIDyCGC
# DATA tSWXe2nipFQ4TJkWb1FrAZnv0F5V3bt4gS0H+N1uSpEOkCTJsygQMjh5H6LSjD8gntAokBWpT9BmWT7Avd0IquNUi9+a/z+Hf37t
# DATA YUCz7b9raxdeu+DZf9cu/Jf//7dm/90+6e+ru3cfjIUQnEKeNq7nMWUihz3UsvNVkAueAdVG+QoFPswS8nBsWXf5Cec7FGPswX5/
# DATA 3JMfAM6nvpCfOiz4a7Uhw4X/RazF72z8GBSU23euNLfuXFGMvnnt1o31zZvp0vr29uZbN29s3NzByAcURCDpxCj9u9IbNXL32E3u
# DATA jhuvZG8En+OLc/Xque9CNu5O9QZY9PZ7rTxPruF2pKPGnDoablzNCzHE/mB0DM5IzLEKbX18+NrXcGKNbOWjr5PXk1dX18ivkp2y
# DATA ILfn3fzu3e+98Z27D1dWKncfrh7cffjaQSNlFhZY8eyupzTQJqvW+Xj0zAjMoy17BD0JjRFWgHShUn5BWwKjgpC5AK4o5eTChfNR
# DATA 88TZBwhf0gh1JVXSQ5XSbrvfSvV5klV7kASSTdPO7dyJjOc/S1CdEx5siMMCWgH6CI/tRXsPKgGgCWwLrL6vojU3reqs2Tg+9Qj+
# DATA VQNrU44icImEfGOYXtX8hQY/L8cQqKh7vZKXRFbtmJWH4g37ynvwl9o3KWAajcYZXyVGugeWI2ZQOwJthC3sst1PtcR/otXv4upU
# DATA 3mRvLNTeC1A9ZwoUW9VurbLaEDKmtFEykWi5QuqXd7IuPXFVgWW5sELLUk3lcgW/6QpoMhA541/mga9XfqIGW23+Q6Xxinq07D/L
# DATA ztG0Q3Kos4+UBTikEjKKWA434lIzpKARR26zkyli4zY3iyRLlNTiGnoEGAE8WaTP6na0/iZc2XfeTiPb7+twA+I9CggsNwfjNwGq
# DATA xduq4F3DM1GLObBqJwc9lm/Uv6h0dgejlbULnOjcftsHLCVYjdUwPaopdXbfobW16MVssfXFPG6tccv3GbKG8EqymtmbDYpn7jBf
# DATA jLZ4PaE+tRn+xpOIYHP0QH9IninudhBflaoOeAbGei+d46327m0hyqu3N9Z35lFs2U7vHqOv1isF9BVxSyskNk1KX20VAzU2ypIQ
# DATA Q7N/j9ss8zMYW3PjR2q41u+bVwKV6BX4tts/3LzlbdGC/t3Zura+s9G8cmf7x46mUz456XZ6beZ7vNr22opXEmJ2gEtSXkJinOmY
# DATA pEnTSjhvEnEQLDfpShCw3BQqyDRVPO03b+00b6zfXH9Lq460vnBGKmGbXZtk1QHPNq8cxm1acMrEsdnOQjEgf2Em4hiuI60GAkRZ
# DATA ZVzsrCWbPdoKJqiYwYJE6lhNflBH1oEvM/i1erFIPPHqYgEdDu+I4EIHNDoqrZZX1y5pRyXX8wqbjTVoNcbjLeo6v8bOX3pBepH0
# DATA z6dmWSWLWI0EgfCFJRYgrt10ySDDYV1Tk0cau0j53rCztviLbNOunsr4h4AWR2YwFo3zbm1UPBQCk4ptSbnT78YQeGbP4dVbN7Zu
# DATA bXtq2whnCW930UzaWVTdd8bmjTgEy7kLkwX6OjzG3CkyL+n3km9K0MQZzXsQtbzgiJDEfZslnjhULmZQ9JLnhSnJYwnEcR/sNmJN
# DATA OV6zXE8UJMxvaVf/cOuFSSEUEHS/CzJI23VF6LmE3+4SsnbDU/fiOyefOT4JrTy0ptJEQ3aEPHAEIcp8rSSh82svxg9EADLYjcw9
# DATA eTKZisRSqPqAt33abFqtgTu3m3vIY76wjFwT5x9100ZJg4GRaNxFzxlPqZs5BxhXUtyKYMxxwV11nwOvEr4l1hU3W812VxuO87mA
# DATA yO3W4PIHnoovq3Ivpy9bdPSzyQBFAyq4Yuc9actjHEgJS5ZFZCXterenP4XySqCt6S6wqzREK66weiW12Qq8+0GC18oS1iTXSPhh
# DATA pyNOv5NmCzMW93Jozxx1c7Wm2m1EFBZSDJRROKnqHERd2ndE+YQRjfiuvprh5FtzbTtpMVlJKovSPDI0ni7YA0OOtGfCo6vhrm9I
# DATA o2IILTMNF5okrEzScjkSj6pgB4f9owuLZN50WuejzNRXJXtkAHk7m2HTnRIyOltO9TED7Ax+bvmVuKbZsKWDBLSvqICGNmtRNwmZ
# DATA Byqzq75oGE8lO8WMc77LV74SdemMxzqTojRG2kTUa7DkfNhBfSDruKuc7iBbitMFJ7B1yMNqjaoTcASdVEEUjIA4sZeCrhY0piWv
# DATA TSSPKlVB/EA4quA5El/YS4+7eY7+Ps5mOk1xsEqE40GriwqFLqpH3LOjzkNpQPIkUvlueyr70NgdOGyFMD3qGALASFpwE+K7Bl6c
# DATA zG3B3FHDS7NzVynY3RxWoK9kJrEIIZvVz8AobP5Jgwj3vjWB1EKgc7GFOazEMlfnnTE/xGuSLAE6SQ0R8uS2rME0pm2hb3fD0g2o
# DATA jjq0a9axsbjE+Pb6zbc2Yozd7ChpnPpMOaa8ZyH1OeLu8aANuHJtI/+/MDudxUq1oO+Is0tFjjEzmOMLSrVWZ+XrKCHNlXTPxKR9
# DATA UXgWL47xY7k7FojUxV0vPimLx1IdDoYl1bwfKhRIzVFvv7A+PChEDiksr/Oq+Q5IVEnwHfsU4IWxPTke5trlrdPPwZmole93u6T4
# DATA LmPW6/64vib5hRdwW+QGkJnD/O+laeCgEDtIcQ+85N4kSHrRgp4lKrP9DxorWMZC6uMO2pVN9jAoB2sL1p52vVccyExNSV0b/vjr
# DATA pVmUpPnICw2I+w3/6DAccMnlpVH/BJ2KrRq4cUEV+kR+iW7MYaPC2/Td2fnOv/FL6UUOFp0iSxSKkuic9YPqDhnLmVGBgYGZHJ3j
# DATA L5QyOM2djlA9ruaOnn01lS7XS+kNQEVcXxm8BrAjlNIhJ41QgWONSVR13Op3D0AK4RRWxsNw1+leNCuVZBzChybrN+e8woSEth4k
# DATA em55frwm05UniVkVZbbItFAj00Bgx96W9THX6U+OEey0JERjpq7hpdgaowu0pfgIteumgZI5dLN4QxGR1SKfmAkQVxboyBp3fIOe
# DATA RRaxGi2Yz4I24pRVitMEI3tz7YFGYWl27WYy53/JSyVp1Vy9pRgxWnlnA/+EOMBgDYU6RuCGniu5mes861IRKpPFuWpFsoI387MP
# DATA erTlTvqk6l86+8Eem9uFF8cYVy2mqq8B55z7wv8akOCO/99x95Dx/b5WF8DZ/n/nV1fPX/TxX1bXVv7L/+/b+N93Xlqe5KPlvW5/
# DATA GYImhifjo0H/PESJ3RpC3vmEM6NC6Girb+AyA1xSBzoSsDg9r0B2p2uNDtHfbkl7BQ5PyBsPNBmwc8UTT35TIO/fw23wK7sBBvAx
# DATA kLJAkGTAy2++X6DtRbj0wpmpolA07Q5NqTrRTIw/cbpea0+xvRAJ4SoDIBtV2nUs6cR82VZbqkhbjasUsCS3QsnTUgWvbLWQTfUp
# DATA AS0IYBm8Xbga61NzF57zqYRKmE8DW7Ktg+b4fmuIdQj6d8BIjlojxCNZ03gk+MSGJFEP4Ew0+cjkSitDdm+4xfYAjd5gp8Bxst/w
# DATA cHzb7nw8Cm47K25cDE4LLjLdSMnqxHAabLcou1OvbcJsAFK/aDLFhE3PZ8yK2H32LWVa3VKrcZfqOosXD7bO/5ZjMXfaOF9ndRwG
# DATA U91RO7MOu9C+wWSCkyPhNK1eV4lJudloftBZzhGVGHj5wmAp9FjH0ko4xVfazqKFxQxDqKsW/1HKNiTRDuauc64ko2HEEBq8GDsh
# DATA Fsorce3mNoCsWEVCPJxZWCzl+SN7m51iOa2ggZI9A3+grxr69i+qZcq5Rk7rjlO0c6v5OlyQC0FPTj3Qk+m3C3qygCMhPSuZrpdd
# DATA Z2UmqrJxlQaT4IUL570B143fNU7VpZWs2HqiUxYVcAtaP0poNx5QCuIS/tciKVCY3VczAIza3a1lDuOejZtTjr7HVqjnHO5QdwnJ
# DATA 3SKxgE8kSs06JWiiwFJtjEMccVFPTp32VOcwOo32NQe7SZgtBx+oFt+8fevmTnPj5jV5xibe+9hPyN8+9XvU5yaDPmkbGYh0TStK
# DATA EO0PL84Gl7ygw7zD8/0CHBXQ5pVkhkH5Jaef1Mx3kmvIMgQTLWffr9b+aJDnCWYo0MHeOoRtPEDA8330rcQkjVzZTwGGH17JJxxr
# DATA SxgE6jkFwex1QPAlX8424aO3jve6h5PBJOe4XI6izdmTGb4SDaU9GRAgjy+wvPWszvRIAe/xyzFD8pesWPySVc+Z16zof9g/pKZd
# DATA cmLwD1aOM5ZDlWwmplORdYtZWXTgsdnwQst6dmdsrIM4KoHreq1HwTzUHwlzn3hMaKD+NrtMLZdGvtKNAOsC0Kz7xdhdUdatN6Yz
# DATA RvYsFTj1POCUucUq62STJrz/JqQBcPzu1W6Z9MZGCZh3CFhRddMYqQ16HZnRuBU7kx7ggi4g2GxiqkFH6vwbBNPWVQ0e9NHgh1VW
# DATA R1yoRi41Kw1K+Hi0P6p2B8u9wRj8qJdNuHAAB+M4uViTQKQMbc1Z2VFHCSBdvke5nVqmTlVWtedPzR0LatL051pECDvphDyHr6fz
# DATA qQ8qX/z8RLcx88PXM5slnkv3484xOKjF7rBeBHkpAB8QPAK5N+oHOnCeAsmhjdA4LG9gIaEFnl4gYN/NEFSn7TYeit4uA+IXtSrU
# DATA 5ng8sDcGlcJo5npP8Z92CxuuyYhmdD/TXuAEFQLBxkrshoSXKI3ULdwN9dPfk+pRafec9VGDDGF1ih3fbw0hi1hzMBkPJ/JwTLhT
# DATA 9dVLK5pp8jhpWKAINRNk5RjlGH8Sf507BTRt2dqAhiUHU5IO8RbJGJnw5wTlXwZCyccD+olwKAKGghAvU7C7MHSK5W1KiWfQ9wt7
# DATA TWkaMd7JAuLptHIC7i+5CY9SyO822T9KrBsDZIZ8/v6zx4CTlDz78vmHzz/AdJKQffLx848gOWTy7LGklkw9qHlwob/XV6wiOei1
# DATA cMSM4PQBpvRlqYM/FugnBGb6BJv9j2dPAb6JWvEyUoZtQaYQcL8ZAOxJv9tpY4MWPFTy7FP1/V8wz+U/A4h5WMfVVp8hRgHESGQc
# DATA 7mi71TlG81jKDxDOysafehKrk3lEi12dLFUPfv8Z5kB+HzNwfghoV2pm4ok/1YvIRGfeympqRLssECNlKCT6J0MGUYAiS3qlr8Pd
# DATA vhCRPAJCYzguG3xLJuBpUVd/ldik8+xR6icLlQtFmG62dJA++xdKBa2m45Nnj6S10qnectOMyeVTRPiCjv0CU0Y/AmD8MvXqk+Q0
# DATA 2L7TGjyE8U+riZ2PWlLTP1b/PMaPARkMMp8+/9B1xjWbSzELw6XQSQQYTokwelDFYrtmBbEgIaSM56wVCwoBQ2+owcP6TLlWf//I
# DATA vTHybMPqlmB6H2H6WEix/cf56GgFhO6o0HZ9f5mh0yWJe3a5I+nBMGgN58INIMka9izooqJDk9BGeFHKHFNdoF5zh//fnfy3f9Ic
# DATA 6CtNBFOHhrQqJzIcRrOifV9hFU5U7+mdih4rsSoxREMKdKOHVccdpOvG6UCgJ5kOgrgcoSvrblo54C/hXdZoCFYIWy8oTqlJ1kCG
# DATA xkJlIT8iA2+TvBB1OmzOdRo7n1VjvU5nWCdkbvjToFjZm8QYHmJZFiCSzvxaKgSqNr3njUSyFocp2ZXfEAueiVcKQ7RghwWbFaUn
# DATA LqtXzJTUj2qOxOfT+MzgKUydUg+ZS7ZUFGTjSktEMAyBlp4jkhTho1LpDyqoGhhiugL9DCDCkA9hPld6fACuiXhmsYcIrDCIXb6x
# DATA whPjljzfPMc12wu9wbtO4Z79rdqpf+DNSYeku1sjCU0WEViWbEx85KKGzLMq5TqA09RFw58HMe94xYLFrtpWFA9/sFdb5qvMIwBq
# DATA /GfDKbrLKecbcqVy3qKrX7o36fZA+DHufubrM8KBuRo8HxBsPkSbaZi01NKmV3HPUdpDzd1BVV/rRIVdgWxjqv7ILXC65Lhv4UJa
# DATA PCoLPbcQ3hJ002I2xcyDYjmtTsb7uOQH8KSUfu/H3zv+Xnvne29/78b3tn9Cvm1Rr6/d2iVWNJ3BNQsRHxLxCAOHLIpCxb1G88gu
# DATA FTR7JGBYQazROSknDrR+TTYhRCXbwZy1RJPadCn0CMHOlXUPsqVZjmTUbyJ9cSZb7EsxV7jf0i/md6K1cWZKP7Vmy23DSp5nb74H
# DATA rbw5InhOVaFRgQmup5UrQV/Mmxiq4DFZusVVKi26oFUqP5t0MX2unm9hln5Qk12vYXymAxHG7iBmmpujXZPFnG2NijteB2G0ELaU
# DATA AzLYOtG/TyBixqfcSiJh+q/d2NtlK+WBhQsrQm6wS9ncb+NbstagWfOcl+3O2JCzIVam3R0PLbPAL7KAYFw3KlNtkfUkgg8bM4FY
# DATA or7UWFsK08tVHfThyKBIWanBh3niLA1IrViXYk5yMoTQ1Nbm+o1a4/U2rq4kAhIS0PIcUTnQFRUIwhEtmZFzTRbOxlzBSDawTE0w
# DATA DzCC7rjJnRYWadENTVEoGmexlbXx+bx5Q8uBKnU/KgeWXakXu5EFtyhd0XeS7fFgOEQYskOBes3pUTVZT4Q7YKaqbq76zOlb0XSj
# DATA LrsJosKKv5KawYdoY712pRqsLXVaq7RQsGx3hFWqHyKkRHB+zynKqLQpQtfmWqjI3KXP0aUFbkghl7XVnNbnoWNnE5UhEFVTuriS
# DATA xSOiI2xfD+0FGb/TxNfK6/0zhWbsNIxvOuq0ehgePfsYeBuL2U+gyCSP+wsvdqSQpY47APpQ4lspPTnxFfZF9RfZR9AjmmwqAMhW
# DATA zJcDjmwkWKwDuep8r1m+nfyrVl3CPYOVl4heD1qEL0B7RuqlL/kS8ynqzhZK2DhHJ5HGjYF7auveiy2TrH1d7c2+zDpGvM1cP1l5
# DATA 0mG31cWItNGKD7WLFs2bpN/Pva8Z8P/nvwBlXmKrHp999vyj5Nkf4VKHjxjsPzoDqGEorS0CZx7RDX2Iatk/P/sS1IGgmf0cdLJf
# DATA oj76Ex7Ar8+0MgVX/wXYd/wMbvZaJ5Aig7QfX7/SgjnHuXMivJsj+k2ODIkNaepKTKHoYKuV8G/H8aXAEV+qYKxXfezSIbv4kWpg
# DATA b92oGE+e/088scidnjRxcHcraUyrUY6pecQbuLo+OpwAO9vCNyWxIqqx15tNdWw0m5n1Jdjwmi3+pJRqNTrh6IO+oQ5kku8PGGk/
# DATA V+KKmKRQIShyBKkVO702qREpLorEJ7Z7wi8yq5ERi1VLBCaD9i4xZCOLTXUEUQXuAPBTkq6gaRfFJjSAYYaTyahnq9Siw6vgzRx7
# DATA OWMSKhWMS4HwupNhp64zcqHFri7f4D/wVW6ubfCraln/FCfVc1ckM9M3OC1l2//A4QBYiLyq1GnuSXf40jIvu44JSNFyT4n3kdfU
# DATA ksNp6X0+hJ/ScjmyFD7HOdMRiKyNXwEHV+v1D9D3lav33TOCg9O3gNFB+QVagBTbPxOfjWqDaUCG2+iChapgkIyo97tmWI1ZS8vZ
# DATA DW2e5pw2ole3C1PVdKHDv/kmh387GnZ8ou8S+Evr2rUW3VBPU+0SsJ+rRWuiYaHZRApoNoGpNJtpxLeT2E2hG6JOffFO52R+4gvQ
# DATA 03c8eNXR/9/etz63cV155jP/irY83gYkAHyIkhMoGIciYZkTieSAlB0viKBAoEkiBgEMGpTESNyKncnOTCWVqZnaT1s1k5rdrf2s
# DATA OHEi27HzL1D/0d7zuM++3Wg+5Emy4kwsoHH7Ps8999zz+B3w4wnPfoVH+Wd0eue0uFhmPjDc3gk8NknW6ZbI8shJgDBvNZzoX7/8
# DATA Z2gEKiOLJRzyn0Pt0H4lEJT4nHsDmYew6U/x3Y/RVIYynJAJUKQrBeK1jymTESij/8FIyo09ewG0i8YibBMgXuG2WYP4B7LKG6R4
# DATA QjmHCot/GRFSf9l/lsof79FXDv+eHf+1uLC8vJzAf1+6ufg6/us/N/6roWHeMVFHNCEEDtLuJ+K/4jvi7BS8fK8/hVRc0smBhdE4
# DATA XwxYEjVeZk9ss3+CHyn+4hFhmH3xTz4+7FxmZOyjP65TY/Fr1ZtK7FYynPdMoa5kecGzON8HwIr+9IQMuFUL8tmOcS+Euwth5Ucj
# DATA cKCH6Gm4Z30kfdrJo93UeoaGQ5G0uxaLGtnIipNvVpeWWwpXujuaAIKqhgHCIHTt0Upp3Qw4BIWvmrA2xaGUjumlTABSMyMM4xo0
# DATA 6vfWt3caH4Y2vpOJ7ET1HgxGe4XwusR2tTyTpUeIp+HzNG54DFhypB08LtuDZJOodPIscJ60ufeg/dXNxloyITPUlAlFq9Ys6YhJ
# DATA 7vKepTOgcefUOOCRdqWRTvbquWdCvZK2ERGSxNw1aWaLdHWyodmgu4mRejOKkyvw486jqOy1hxJcBxQEoH3eYt4OPhTsCfIEtdDO
# DATA Ddu/MyS8LrhpneYZo75PXGqg2TcVzg0x7P8dQkgZWK9IwRAIAJUZFxEsauYtsgmXzCgWiiW94oexNGl6Z3MT4Cs/RKLett2iqA4Z
# DATA t8u3ZRuDDI/QTq+MPubaxXq0H5APKZkljtB0wdxbhqGI+2j0pNOVFCuT1hEbdgDBszaCIvq241yG7Mh87uNtHGZ4arSdvktssFCj
# DATA tIc6dPMzIazTumPd9SRvYJsC7CWjemtHJZo1XQpKxoYLi6cJ/oUve6MzDJtEvxcbxhXL5pFiYJHxD0U7QGEoKDmm1Bu3ZTizJ499
# DATA p7wPQcNPF5dKt5dPQ79jItSUl4Wvbm7srKxv1BuA2Vnf2Nm0DxJFyOex8VyHDpALv5geUiNq/YOYj9FjwnbTCzCfwvEwGLQ/ms8s
# DATA 6FPfq1iRGU2cJ6TkNBkVi/IGMiuLaxnxFilGGH06niNYxhMWA176NKGGhkfGERiEqtVlxlLkivHxwgMZVVYgt50ghmRcUlNV1zJj
# DATA OB27hkdfI9U0xRxAz+a8c4+S5xG5lqmA8dCHJucdIzsxpng8z/ngbNDDhJ0U4B8W8+NTL7Cg3rQei4TfMGWmTHFikz041skcKtlo
# DATA PJwaTxw2KguNd5QSjbRJ9pDr2A4PNSVa0etkTTOVMo5EKtFU+2riaFOQDphnB4BM4qyhp4rXKOM6wGVO26O4InOhhkNTR52EIMS8
# DATA LCx5d6aFYhZWYt6UKQVfzhQz1pRmhnzv4XGi/OLCwkKxmA2fmD1Bmx+II8SfK9nn/ZsjN3ExJ8g7MbumLQe2LFdDDtMVAgE6hJ26
# DATA UgZVMTczWXIu7bFPhpmbu1+/t7JKsiWlOd9+xedf3iNQYiiwOQYDdVFMtYAUeCgp2eV0Ztccp1VyJiRA8PF4jJflGZ1I6ylthdQe
# DATA 2oC1M3t63nDTosKiOIgMZU17EgmxD+4K0nOjKt0RpU9HtgdeMSnda7wA5b42A6IgPfDfcW1TJmiM9gJrN56ZWW1pzxMDDiEjU12O
# DATA CGelwGqbtkbCjJYSBYc3a3gZMwzDcCRKS4uWA4HHRWXKKUhrn0gd5KRSFduhTsVkohxPAXWk5VFFucfVZS8or/hycpGLyVVfStxQ
# DATA +H3tTmQJ88ZGIZc60+VovWdgWKUBP3mmSFSVA2PAJmf97Q2nF354Hi0LJP2HZnVP7QFqud8z8bj0r8V8kepeHp/PNe4CEekmB3UU
# DATA k3hY2PszRcaHOXY2ZZ6uzLpxJG4b57hp5L9lWH7ezWQ+mnPePpI3D5hT46vDzyivAN0m/IDbF7lK6EFpLeOkMPNy4dw7c1wtLnmt
# DATA uNCVIu91IudV4uquEZmXgyu4Y5z/fpHilqjJYy7nTST/LcSDEmIiSegrB+a/cHXT2s9M/ChYaZrgDq55US9eVeIYqjJnyJWnVwth
# DATA UVLTK7usUS1IPotckUzF2iZDaklw1d03pTWtmcol9zk4IyyfSHctzD+aJV4gNT1Yv9dY2Vnf3Ghvbz5srNZDK9BWOk9x+NGYIG40
# DATA Uxdrq8vTI3e9TG4/hjQbBAtlGS3xdIPKtR6dS9pmQX6YoPQ3ajm4dsoE4HZS6d8erG8/WNlZfS9pQQTdOrcv+DISNx0w0iOMVocQ
# DATA YfOvvvugZCw9tFFLQLJAC/KeiJ6AbH2RbaMOtK1NMxbWUTKjG71kpkZPEYSWUArCVcojtNKtds2mpxmrTsrLWOcwcMdSTcg4jgUq
# DATA u86ZuwESt5ERud6or4XpuKV5Lk0uEk6eWduuN95fV7vwTRQo4kCc/2j2KhMylLR80WkeQxycmIJgbzJ6HKPyenw8jStzCcmm6Qms
# DATA uu7bOK1EOkmfhnV2ZuoLmPBdgSDlrJJaGPFA5sxjgOa2kMmBCGhLJJFW00A8jIumHklOZFudca/J+wl7yoKV/E6QLeYG4FwBc0lJ
# DATA JQ1XxJjkmpMz1vX8B9A8+tIyjwfuK6Z1zqLIlQd31+893Hy4TUuys9K4V98Jz5cj0Bi7ThS4IAPhE7zLybWFggNVEWIEYdUTQag8
# DATA AbQViR/h3e9U+cgcgyAsRAFub3h8tKfUGWixRj4SMDAaY7BB63cUrIhEBB9HE8BRiBFTCBHHcFNikB1ojJTZGjyOMNu2EsmxB9x2
# DATA bq3En4kywrIEXoU2wthWCbui0Rgz+VzxajBDJihbRciqElB72h0bpWDV9iBf5vBAw/ZuieUT92/cW7C40CMuBJ3ijzFDB1uGOdFY
# DATA SRcA7y/d6QxwSmjRhADl7CItCfjZ39+PUD2zvqVrP4J4UADrDDrYz0qwgSeEEOeAjjtDw10RcoRGAFfoZRKODOnsb619SWzvmah4
# DATA hgYivYFZ6gMpkFq3C+YifEY6QofxI3p41lTJpOigi5k9NF5N5WFcwVPl88g6AeXw6Gw+XWsiEguT3iXj4tKu+TMBqZQOYLbW4/Rq
# DATA BOg3gx3BJ9WCwAYjJx/JV+XywXn1KELWO4kP+2NArB0S3JG8aPUYfzJhWfKdFuases8MXcB3cuTE+koaDzwZ3iHMowPhxu3pCKnF
# DATA IIWcZgK9KS6ANDqXguOpbD9s7Km41h+V/N2fkj4toX2N/LSMJ6OJY6tUfXnjnPYltypHztaI4OkgoymehcViFq/zCqLMMCV1FyG7
# DATA 8AW864jyPJD7s4Dx+aENs5PMbGZmlSAKpsdm8Co9KtA/lB2VemXmSrZDpvL4EwNkD/JpyBtF3r6mb+IlxD09CinmSUc4w3XXPKOk
# DATA JJJcyywUAPce56K/MNAktZKxbXNaQS5lauNGLwBCQCAzbAGnq5Tp1OlahqSHefJwTV56Epf0RJpSKc3C88QWSkbBk1+t4fpqXLpS
# DATA +kCv+BrWYph0jiihSdbjyzvryJdeooazWcK4oZEiLGK14Xq5Hi/2jCHhJl5C1Zrh5JkO/ICpdXVBfgweIjLzsT16PnO8PZp98sz0
# DATA J8nlRaJHWVIdCo+HnUed/qCzRxgwYZo++kquk+lqauoXJk+kDoYcOy4e7Y1GA9M/XV1JMuqj4OoqjbNZFRe8luO/jrXqbuqfsqrV
# DATA /j+pZH/qAUlVt+hO74QRaxTI8pKEXAEsCc65i0fE0Ujwu9Gw38Ws3FyeILsOAdAyUei7qgofiJZ/u5x7q9h+/vbt0PHsb0Ro4NW/
# DATA JzdMUUsbE10aCMkG1ki8n7EzoTYHTMULjZ8yJKueZD/sfZ/RDRtYJIsdayxQidSRqV5dWftQ+QjxqWopsFW0u9ZZ6wB4LdwhDIMJ
# DATA rx0ZjyQ3G4zEdTq/vnpzq07WEFttnU/PrsEorB7L3qb0iOKpsyQTAKWwhRNHImnZDSJGALUngSuwUaxAHPYo3iwuLChAjO5oMJp4
# DATA qjXtxAbJZfVV9YKxNBT4hqePcsGkzqeYFLWSs/lGjVfcFLQkV5JUpYIuzFPaUPVNxY2FNH2gwZOrq8BN0Wg7hVAUQFfsT0U5VgcC
# DATA UhaYEKMxaHwwc6lU9s2SD/5kMWBt6FeNYepDdTWNKp4rlyw8087CZg7QFmyvb9yT8K2ouVf6PpMUWd21iXGMYLnqdQZgJGLxE0yD
# DATA iCiJ68RhLXElkFrd6WFnaugVYOm5RowZBSoglcQBqMJQzzB9PCpLgtAZHaWtpSOT4SBJVBjXstc7QajmVF0B3JVWZTESVUSv2oTA
# DATA VgMQTPFbKOVVWgFrSBTKpi7ldnChIQLQcROpDPcx8vOnCcs2t2i7yqB7k+ylJ5zQ+k2rAmjbOGKTeaUW+4k2Ws29hIqrYfB0d0i7
# DATA GbPz8pwk7pPVmwuLC7vDUzPr+NFIXEopuRINtsnDalFXHgnyP7LmDjckKO45QZHpK1vCbH3syksVALAMn4igYw1TExBxecbIwTcI
# DATA s5AnzK4VyZ3rnY+m3XksN68JhFR0QA40xKKZIkZRjf4Mris0LHsJNfwxBhML3lWTaYChcbkumt2qGuWSXwmRaUrgnS6Fcy6ggXnA
# DATA jtHRKeUkY5Dtkd8ykVkENcRtSnd+WnSyZPGb1mUGcyN1jqQ3lMm4PNm7UzjYeyvb7bX6Vn1jrb6xI/mZ1ObkgIxOy1BPuemNqMGy
# DATA H+3Yn6X+HFjF6q56DhhiF264paNUcbn0UlUN7W+dj1HIEXbcGTB4Fx3nAF0puPdI3DnFBe4OeyzJUzIQM2T6q79pZ/AIWIIIjiBT
# DATA GSlXYrgGCEbeGQbGJOI5rJXGik9Ar1t4A9xXTlNNIw+RuQ4w61BNK7UaKdBALeFwFJ4fYVmjDmW/lr/8bDjm1DdtQGYbEY7O3dSQ
# DATA 3HxqwAvE9pLDf2fQpg64EblGt4pkwVHflYeik0dJ1agC7VNCfHV4b1Z1+r76FKiiasbm8j7TQblQ4rTo2z+n7A8GoKY9C9b6Px+B
# DATA N5VEciPyanaMuQQdqJOCAa7kxxxzYHtTdkcGKUtYX0waGqoM3lGbHbVcYEG1DipWgzy/ep1plCBCb3d8/mQm39V4jFxrwhiXWHSv
# DATA Fjs5/Xw/vp44Cs9ZD6WvwusDhownK+STOwfFm+nWPNRfzGV4bNQfbIq7O2oVVjc33l1vPKg74Bv25q46ruO03+0z2n7DUYLu++Ug
# DATA n3c4ZqtMIGW0rK2s5Fdp2+Q0l5kQFG6P1MsofktDuHzKuTMPopQ+knE9Z1NG5zRrKKbjkxrlJcspZiZWcaYv4c+csjW8sbIqa6wl
# DATA tACmpXOfCoVcPOmoB8XUuFqu0UNKyb5D9lqQJZCwTQo3fgaDUFLIbXlnHfQeWcScPMj1UcVep2lQrsYZWTK4kglcQWApCuATtdzy
# DATA HJD6Ylbve2BfIWiHGKifm8+Cg/XuZZOFnGcqZuxvV744RyvWPDr1uPjFKaKJpwmj1PGQLtqJ2A26zNjoBRxIlDB4eSOpMkfJI+V8
# DATA E2h1cGzU6T5X/kiMmYqt8yP3ZoZkmKi+2Yi+MJMuiq8ZSqCpXllEQJfYy+l0Ko9+g1NWE2m/FGOsyrdtaKQ0MA4tEeeUxm2vKVcu
# DATA VyR6SQQw0+c/KaoX7XZY0WTC3Uuvd1mNEQfgQ9hRkFdWGVNpoeV10zWUskWZUcdpa1liTq0VyludOGbHUUkQDBaIF56u+A4zLb6j
# DATA PgfxBLvSOBCLZdDZtJU6OcM/ORFTm/DIyeWXUTzvwrqu2TLbFttcreCOfLtCxn8Hpiuz6DZEf4duKAg5jg0faTqxjhj+xZoHeEYR
# DATA YRB/Ffd/HAV/Hdy+devm7fN4o9c33jdkIe2UCp4cfVBEDwqT8IeeMPBawQgNKLdu7Fayvxf/ihKuZOnrIJak8iCBmKQcNmuWw6a5
# DATA TI6Dpn14UcY0omuZD2z14fZOe/vh3e3VxvoWhgg16g+36zw2UIdQ1YJx7A6VRe9y4TBk93RCYMx4do5LsmR2u3hRS8XyUTK985+t
# DATA mSaHapGW0Z+LzmtXybKxM8SEBtI0LzCZE23tTrRUGCZ6N2C8KGO46EKiQ+3Y29f1+aPg18tFUee7ZaYEyKXMTRKRgzvTlB1pNbkD
# DATA LQeC0t4JVhhUTiSNGSMRd+SN+ipv5L99uK4jnPwZwVK7BKmIcyx7wvVJshxxXEaTaZs5RZvZQpyMqyViL10iVZ5ri0iXExPKbXer
# DATA nCZfTjK0Jq9Iy0h0o+zbriuUnI+HNBHvU224ZB7g9WTKZc97vNRrmx9sCLJdq7fv3t9c/X59TcyW4NMgamKt4P0Nhk/84lhl/Jkp
# DATA 9e9puSlTKCZJFzopnDya3Pc8RTMT0BET14WZjRXT06+dy48NZQkePHnb0uOSOxTVTSN/Gx8PF8l4l1a7L+8h3ct4UGj9y5fFKY81
# DATA 6k/IApW9u3Ns4ldhk7m4jeXc1pwsm8wrSvn3JpwklK8zjsQqig+Dkzt4ZTGCYWQsRxxBdDH9OhoMoL2AzOGVuT97i4XPHnN1lrCr
# DATA t21d0LZ2NZYw6/i/cstN8ui9fr3wNHQNORLnedbphCwzKdToCwO4FsyyB+VPBXlxy9EFtOKZdp5XniTL69I3K6uj6dJ3PuvL+a06
# DATA lzE25Fa5J1PWZSiPkwEBSfW3Ze2xf8syH3HlyiyE9eR/Pc3Uda4JTzGQGWDolzD9XMwIItPwcStOvuDMpHZXYd24aMK715aRDMvI
# DATA N50NMJXRmckAia6OJ7Z+zBH0deRaCgYllUpFn+HgAenb4OrYCm5zRR09ZzhN+zTfyRsJQhkoDR85dNbIpWL05KQWSliOcDbuRk6w
# DATA DUZV8CEqzF3VnTHX1HNAn6WGt0FQcsTMAiO256HSGXYPR5PZLohr6436KuAvoAdE/cHWzoc6CrAvg9vPoYm3bApKqpOACMZghMiP
# DATA 8GZFA1IU27lEn1HTDy6nKsJDkY7yIM0XyNHY/IFRKZGkEZwtI239Ya92X2raJ1uO1K0vbaCbD1bWE4o2tLrmxx8lPXB/MKV70gAi
# DATA f2uiggqjIcuLJ68i6uTlisooVbQHGUvEsJnJWxh5SWN3BvFV9yJz5SR2gFi5vxHU0a7/YH17ZztMbEVS3TCrSVe9EPuz9C79fWv4
# DATA SSo3/VVXdETIJGKeGHQm3cP+o4hvtlwXOo0Go2E3uiOzuxvqtDeD4yGG/Ue6xT7kPOkMOYogAlMApT3Zm8C21y6q3F6aSkZ17JwO
# DATA wkbVuXQ0CbaQHeLvPAG2ZwIfeKq5KC6Ui7OA54SctHl5hT+2XJl0+eyhlwhMqj36yJgJ/XL3ULxYwPeKGQjWViIyUYSPDtHX8aDT
# DATA jbwg1bXD6XRcndcw5dWbCxSo5SsMyyy3QWWiQW59OqSkfbVk9tuCU3lqR58asXVV8AsSNB+XwatwHFFooRBTUX1SDZqWM4Nqqugo
# DATA 3sMxotqI8vvh4tLblQXxf4vVp/D0FAM8XE09MR1446kDdUDiVnkyGqQ5R7g1jQ4OKCz3adib9DHXL5nYylIHNBpL/eHT8KjzpAyG
# DATA Yyi0uHBEOsgnZR5veDM8dRugiMnuYdT9CGuYirmDoYarD9ZQuhRUhzwV/7sfAQ7ANV53PRkwC/NoKhSy8jzVea1YEdxnWJjU/loG
# DATA S2O+0Ull9NE7C9XFYrHSRViBQtEpIX7iuH9RoZBooOu3kMlzWK5+IHgbcCnxYHGJQikn0/Y4mvRH4AcWLi3EYshphyvMeFMulrjG
# DATA zYSlgKsdfbTtq09liHbCBYaWJbnOFNutu8bHgds3fixd/RlAQOWlttQmZD213niq3hC9OFVvQZcg9wsslvaW4yFwBbprrmyRpqy1
# DATA NpKOCpJi9sWipoqJARrmYRk3ZTEBelhdEtLJuD+Mwhz8QLIVnJh7m2v1uw/vQeEjMXN9uLJNu+PaQogTKFlB+O2F6reR1y0v36yK
# DATA /xkf5497YyRgGcrlYzV6htCZqeoLqapORkqcLEP8ZnUe/quf0aRU51kFbLld03TJLtAk6ZokRZj14LPTWeyY5KiylKPEPcHV7L8a
# DATA vzGHcdmOsVVEASkkicRBF3Dd15Pr4hle0cJaoA+nl8CXSXVlM5VpmXrQVJV/DuVpb7YyQd7LbLWmVweV2xx26obkECSmjYXGMMWY
# DATA FLzKh/wkRjQcmY22sjI5OIbduoW/FCRmG+gK2m2xeu120XizIui73eFXCqEKzQaaJbjgWjNUqvSyxi8mdBH0Sw8Jg2bK9x1WYmjT
# DATA y/EkUiy5fDwZ8C98ESgDojYeXiBRqWNbOQLiLUXQC+Me4CWyzNGWyLyO46gMfEd/o5pILHKD9eUp6AMbaGXMTLkM5CtKQ/hobQu1
# DATA X9JzwxAsTe9w2/MlRGEeIe9SM8VaU2TPhx6xHGv/yM6fSVU9wTrZoEKDI9uJiVLgHyBIoNpnFhLXozUfy+I/UDrWUEmY2t5GAfBS
# DATA iguPgO5WveOjcVzwImNjvaTcwI8GEDd+N/lkNIwFebU7cbffZ2xkFuMHWT2MQkvni/Z2LEz6NbEC6MOkn5NHKUb9XtI9x4RLNe1X
# DATA tcDpQclWdIETISqt3P4U1VqoVx3jnZ56iXA+a4r5qoCflXGOXkr19vMMasZa4LbOoA6JXKV6e5EFd3lGRnsu6rA7S4aqjeab9SIX
# DATA 6JXBtjI6ZADdun2BhxdvWHNIE3nD7zqdcxb4m0GYmf2Q3N0dvVRbn69VY9Og/tXtiuGEq7RYxkSCsiPEq6qH/lk+hyKhbpwC9A2N
# DATA ePZw5aFopPxlXX9iYdHbsJd3I2Y3qw/gqiP6gtUiu+nzM6JZXbFO/AT6u/LiTelWMX2fPP0oOmEHIgzGskLGvIdt8fQCe0cfz0nE
# DATA n4RJIjkKNZ3SOtFcaGU3aIgAaddKg9ylw/dVrJYWv9yhajietHWSNZtGcgkNlU1yGixKiLqiY220GLXb2KV2G/Zhu809gjWO+wfD
# DATA Y0QELMDHzqCyvX5vp954UAr09/cebpkZ0uk5/VOgCkoB5xC53hY3sROtZkm6vpDsPXdhv08SF7ZPID99HVrRXpygXBk9isaTaL//
# DATA JMP108aYtfLLKjS+XBkdPd0TV+EYU3m7MMXpUo3o0dm/Bmd/fPmTs8/Ofnf2lfjv58HLj19+Ih48F19fvPzvZ58F8PzlJ6LY2ddn
# DATA vz374uzLl798+Q+iKPz+z8HZF/DLc3z5y7MXleDsf4syz0V1L15+Am8/P/st1P/yY6tcAP8PDb84+/TsuSj51cufQ+N/L4p8fvZl
# DATA sLK1XhZPvxZ1QUvP70C/fvryn6Ai8fxT8fmX4ttz0QOnw8+xw6L+s9+f/QFfxgoq7i2b1Lcrq6v17e32uyvr93lCfiXq+lp06jPx
# DATA 7xdQW65xc6N/xJc/F+Wp0cCs7uUvcEbe29nZ2i7reSkFovjXOIqfiiq/4s+/EM/ptY9Fg7/0z95zmL3AnChnOl7+XA7gj+Lrx6IU
# DATA LNG/iYmjYtDZL1T3rTl7+fPEnGHESftdMVftBxCUchdsRevvr+zUcer+T8ri4QBFv38HX+WyfwUzIB4C5T2H8ZKBBQcHncBHxiAX
# DATA bi8siK7/L1mtnHH8/lx0XIw40WFpi9Qdx446JPr12a9f/lysLdHgecgywO7hpOFk/oF79Wsc72fi4+Lt4Pv9u6kd02kxPf1K2zq/
# DATA Fh9+D/38qSj3ooS/YvNfAmG+kN+f8zQiAVYDUG3H1Xl2N4yedI7GA3QETHQOKZS7ZjGL/0EtiF4JUv0NEI/dM2zsMzGbP8WGPxaF
# DATA sS6xbvzql7xcX778BVC6WwHS6B9xJL84+72o5nOcic7xdGT28jSdKUs2iN5TmkML+eHs30XNsEzPBZd4kWAcnp3Ci/l7pEDYif+Y
# DATA sa3Fx38Jzn4n1uQnSNtf4kp8IUp9Jcjnxdlv8Bdq+5fAzkRdX+DySioTXO3nokrRBfhV/CaI8pMKHBrf+gv+mw6EKHHyattYEH+3
# DATA l5fxX/Hn/Lu0tLx4Wz7j528vLt3+VrDwTUzAMWiwRJPf+v/z79q1a6vRZEqhuFHAbj4gzHJeUW0+JhVd9DhoSFuWdJWiQAMM2u0f
# DATA 4bVQKlXld6qIVGLyGVxD5OdRPIeROGAUGfT3An4MMrosMlGVaclMPTlRHwUnGoOYPkcVspApK6QrackyDbXpYVwK8GLAumIhUQ/j
# DATA eFC4DvJ1CUEuOSxzv9MfwPWHeV0tFAf6Z8BqBMv4CbIVyVK26kKeBgYmWNeLl3/PTAs4HrMcFmvgzEX++zUUFAcMST6WKPQCeZZo
# DATA 4hOoSpT6Ak/I56GLTG7IrWLwhWbIIwFPPhgLJPKD1Fg1GJK483TGUxjN6HgKD8lmp1CNbxmOI4gjTer17qiXlUXMmSEPknKFMI6k
# DATA O6CmwPa4058UDkfxlOEc9E8lSh5jLl1cC5VHHfkvyTfZbCHeBu+u/iOKscE7n1FlkbUeomIDMR2vRdardow1uIF1ES9PHHBjAq7C
# DATA 7+HucHeyuxDO1HSS3I/yAxAJn3RSTBMnc4AyEchgIJWyFCaOcBS7X7z8GRADyGmf4iuCSpJ5hscGkgCMKhkCvriwtBxcx39mdvg/
# DATA krTHJyxTsOo8nOSy82JsZSm9oUD0wpTQxNH9jyCjBQ/6d1Wqt4a4eKMvURCPXHYESx/93TE4mIB7NTihHseMWSpRbMGEADRUUQTQ
# DATA JkIXa4yfwA9SPKUb/t4J6M2LaqGtpxQOwnwgfHJr4Tto0xqOwFMAPqF3QzREy8S3by+jiwoyCtWsHNWmqGV7+76M14iDHmYsQkzL
# DATA fowx6eBtM2Xc9Dtim4C2RSzk8MfRZCRR7Sk8g8vTjlUJi/bC3iiKKb7d3DahdCWcORLYO+Kb3nz2WLLRRXx/SU7pJSMQvH4LbBGo
# DATA yBFxfwN7AWiLLkbPs50fr6J+xQdgHnCXe86KgsWF9JyhScH6TYa92maTq1yry6/TOdbKvkrCdQIEZbquwY3xUziljBkV3EA8eY43
# DATA iecJET8Hp/xGesEJhUiWiAdEAiA+gF3Nkh/4Ox2RP5Z2ojcDWCcZhh8He6PpYdDYXsENW19d2165Iw4oTpFyBE52+OvRqHc86CNm
# DATA isGuxsd7g34XEG0TRCB+EmzMogcfv2Fm5qlpLF8XP0l6Gncg1QVZUeO4KuuU/FK77Bqde6PmNJK5K3+VuNLrcwOOA7EMXwvZ5xMU
# DATA dj6RKibUe/mEnpc/lZ6MYPX0TpTeLWig7pGx3ZmrSi8CQaaQSGUj6qpgMVjk9nTUjkXBYS8uYIMyOVSNkkMttiD1oCSMynD0uCBp
# DATA o3I87RYr8E304mhcmMG7UN77IkD11ec0C3xT9gl+cOX9J7j0fkVawucv/wFv9uLab2fB8ZyBKgxjfDJb4DIMSGmylz5WLybG8XJG
# DATA YBGSGBJOWMR8CHXECg/HKJwbwefsf9LUocj0G+xU7MheyFGU7GUIWUpjIib4Y0HDX6Jy4fMw0XWPV63Pj9Z4IeFJC3MGdF0IIUdS
# DATA 91CcOJVxdERmmP4jSNgIX1lAGfR0PiLTiwJrMYwQlIdQtjoPP1vQG+fKU3v2f1Fn9Bkerp9Zgh4IgLY8a4qE7pyK1/+Alxs1qygn
# DATA GvKsGKBEyB5b8hn1Ohl367E+2PhwIECKCfqx2PM4ScQZnDF3pqOjfpfbcidO1WOZFNiKkL9ZMTQ3cDNrlQzEOqwrTok7G8tQMM5i
# DATA ZJNeejBmYthjZ5xuHJddGF17ZHmZDEcmviRUOUiKwxd0sU9AbTiGPV7D+DVyPkcY2v3+k1pYmQ7icuhZTYTLHcWV/R5w/oLZSPh4
# DATA L0T7jGDpUefIzZoEz9j+lxiYUWJ/cBwfOoF00F58MuwWZBkxhuGoYMRDj2Ll1U6LjmHitC8h1m9gDAG5G0qMqWvFPFrBpsWFo2h6
# DATA OOqVGEnAQWAzU1RTASs+S2aiNm6E8CR5Kbx989vLnp+BnwX/JVgYLbz9dhaPXdvYNvtcFbxAHOW/UzYD4+oH3HR9Y10xjgBV7dLk
# DATA gGzhtrhTOZhTpiqpQlgl7LGnIaUkhpb5KrEOOOmHB4Ww2RvGrd1heAOHaTg5yPWKBpiRGJIgKO9P8Y5ydYsmR/0pBa8XnsIv7e5g
# DATA dNzbH3TAMj7uk/E4xJB7Wjcy5qtCnPCF3j3ojug1fkstXcqrMgUA9ZMSDridiI44yY2ncyAGGokIzNEY1Sp5yGgJJD9V2ki2/Ai9
# DATA OsSMAovjLxP+ovI3UCUVStg+Ixzq7F+BOJT9k6hIHBcvf0YC/JdoL8Xz59dsR/iKL3SCBstKffacDIJQJHSQwUy4NzlWBrjJLVL8
# DATA G5L0Z2e/F42B4edjbcf6KR54xmaw2md2d5EgHIvtUm0Q5Fr50ag/LOyHTz86BTP0I/BzJ4+OkjX9MrtDBWH1MPcq8xrw2TakNqSg
# DATA UiDZTg5B0KeEs6kYjEm2DyG2YoRQGokhJ6EBDVi5sVtu3fieflIxwQNbT5dKkDgSa5stvqSpbGnTaJ5+KDgDugmHHGJAvQ1v4L83
# DATA QowmQKqXAzHThOJqD2KNDmmfubryRHH5cf5RZzI/6O/pVLDz4vG8JRemFTJkRZknRnFRavqGXKkbGEIR3hCv3QiTkRR2IJaRd8bV
# DATA dhhjEzXHpI7Orz1xXK2CGzVkKTeAixF1Y7XFvN0tz0ycY/gCmXcNM8xEepfTHoHb3ESmehEbAWvXKdo8JKzzaHS6R1G5ScTbairE
# DATA SwDb4Qpn8xqHaAXXQc+BP8A98RNkdn+wmB33icQC6mwyQltrtLFEpkb7HJtJ8UA04v4Wr6gvgpXVB3Wl7o3RdiwOs3HUFRdESGSP
# DATA OpMnUXcbk5r83fEI3AQD0Jn00GWwOyXdTHwYDQbyd9KfCEGwM6ZTDAeiowx3d4GGdsVfaMQeXqOH18xnb8Gzt97iHhr0QcmJuMP8
# DATA b1icl7RwI5RheHaCzLD5cNifClljzQgoaES2IW3n/rZ5R94druwLWabGMVPlEYiIETuqBRxwzK3tDj/owGnhLYu8yeoMR7aI/uyA
# DATA P74QkuLDkSj38EEn/qi2IKS73aGa/do1wehoTm+E13ZBScQH1e3l5QtMEG6eXNMjJ8aYFLGvxKR1BjCm5g7UJN7aHK52hBze60xq
# DATA 18vi/4KFm6XFW9WFhSrwKWvoDUFY4tz8cdRbiwadk+2oW7t5G0ptgVI+hstAbSrOWKx/nSybLZrdqHf3pIadj9XEOnPhiTC5UHBJ
# DATA rrgSicZAASFjVOmZcoaCCsAwBkAIIfXe9FBFO06kJGu4fDaNiAhTKy2+st7QcgmlUx3jQSjTlxVtETPYngq+go84aDPXwTgZTHFD
# DATA WeOSP0qZlsMPazKzbrKkxfmPJzgp7lugtBr7IzQcr0414YY3sKvt6lSkdblTsfRdnQpqvDp2LDT0yXQlTXj9jk8s32OpqpvdjOnx
# DATA fb42DRIymjZuoJ2KFAZFzXwL7VRMEdpfsRPgSYKmORIWNc36LzwMIu+qlZgV5k0d2uIjnYQ+f1uGYzSgjclTuELAhMm7YgrJ8L6z
# DATA JdE3g+9H0RgtlRIBKJBHMd64IafzsDs4BrTrADwz9kbTMA4GEM/PF5K4ksyS3QynAxmLyduyakymtZspZpIHZRrDK1ooKPKWt8rC
# DATA vjTL2OkS6SDgabJgHP3KJhJ0jSS800HsyefN8gv4KRHkmTESlF2sX6HPPpQkr8xC5oWvX/6Mro8v/4UcM/CCicZ5uGCKk9lJAUPe
# DATA 3KLJptWZVvGO+RP0pJXDG3uGk7TfSxmO7oTDsqUYuZATM1jff0SQH5jAk1VkJJKJlx/14bpi8AOdck5ieETBYHRQcTzfw7N/Nxxb
# DATA xIxWxQXKcA9EUDudezJyE6Ozbjc0XWLY7w9dbNY31kvaoUL8P5vbIfAVBlIzUmml+y4u/mV7+qW4v+0/bh8cdya9V+gFmO3/t7h0
# DATA 6/aS7f+3uHBzceG1/9835P+3E4FtuzPpDwAyIQZDC+SNZCSfh+9+IKRYzKbKx1GJ9O/9ISUdBUvEhBIMn2S5AO53h9PBOfz94sPj
# DATA aV+9QGEn5/MA5O+A/iMVXOiwQ4FSM/zmyO3P7x0nDn/HUW75VrbXRTR8VHt6/foornCAoDhf76+2V+6j5/mqofCd6WfXII9G4xwD
# DATA H7HfklXz5cdw29aBBC+kzQ2jGsR//xkeilfEst4JPPx0XwhdjwHp6exT8JFBt/yfvvxlONOHT8xZ2zgOZT4ICeJ32EczpTHJW2i7
# DATA sfCpbKxctl7Dm5XHHcGg5WTfWl7IA0lJb05BWT2EHhXTIfk9jSwuJIDqjc7vUKn6k7GN96Yr+6g/GLhQjLqVLHOabUijW6ZWMEk7
# DATA Tqp2Okkf2fppMMWi9fUT1KEDOXyp4mwEmWgL9yUseeKY8VrywKhG5m+zfhxxPmvfX5axbxLtjUbTtmSnBTFtJVaRdafieiQ2mZBo
# DATA RpD+vcYql4TqtwxzLWsACeh42J/WUhU0iRcRYVWrsjTlUbtXQntfWH4YOSmQ28/lXnHUmXyEmnV6icBTCHMiZM3jDuLNiekuo4PX
# DATA j0Z7YoOLQQO63Xj0WLw0GMUxTN+g/1EkFZXiLjaddIZxH449vFi6mkcxi5dXOzIngKUrpanIcKFwEzqnt+iGmDWpQ4T+KFWhlbMd
# DATA Mj30+pSVc3pYRz+KmkyQQTNYpLRGu8NUvaFdo6k5BFg2nhVRybWAc6aKs7CzN4gMLePWKJ7W5o/jyfxefzg/OQrK+0GiG1YzaSo6
# DATA BFYqH8MFyFDTGdpK9Ig3NlRIKbQF2cNVX6rEEqWoyyHtpQrmubbWiXoJiRdQaJKtSn8ePsooVrbKxDmDFaBQHvXkAVkKKPZXdI3D
# DATA ECIxfeIezt8eH/a7hzWSmSr4pSSlMjNxlHidsPkw+xBJQ3yUYm3iR/kJYAztM52Qdvcfi0LYQiEUX2wzg3iQOMG5QvuoZ4fmGs01
# DATA 8jkJONNK+uPhDxV05YvhOKBUHscx5JWmKbcsFBntcj8zavTU5+Nt/+ETqdjx6WsO6v0t+0gJnnZHSs9GVNsfKaT27CueQ2kLUdPL
# DATA D8pijqwigijdQuKRvRKyMtaQqFIzhsWBgg7Xlo7Sn+KwSLRUD8Fx043PpblQjh/JgfT6cWdy1Ab+Cx4UTKpIdPYZWPQdggz6LDZj
# DATA gJo2z9HnRf9k1r8ieIysX6YSA9kCdG6gwpBCcCVYCUCOExxM4oxOALcU/XhBVTEI+uyAb7CMngsa2x0NBoxTVC7jaYx9I95eLgv2
# DATA QzRXQ2RFzejEb3jCQGKOsaCek9pKt3s86XTRdrEI2jLaODobteRUraI3+YTcacYLsBDGG7P2T0K2MTSa2Flx7zsS8/X4MBoyXDsH
# DATA j3X6A0Nz6e+M3XvTpJrBJXLu4jSS19sW3cLZC/knYvO+gCjST23aPvvsTkD+SejT/Lm0wKaKMMgP+Af58GuoAsyk4BSNHpAWnKva
# DATA GYWiPV/mkcQQXLgHAOhN2XReOdRZTkAv77tMSyHcIcQFu6Z61KgDUPRavZELQ4uroSHFFf7aXKy2FKSTfFZdbIHaFXDqwxbpEc3f
# DATA TZYpa2WWScFiXM1CyzGbzxJ9tdPb87Nfo4M7UFHSMv6F0vIXE2584bxYdkdABx+CymDU/ShxLwNHeEQCGfINUnzbbK826is7wTP6
# DATA 0lj7oCE/b2y+u3n//uYHlqRC+PdCbJwcjwFRRsJ87E/g9uI4tiLavIMhsr6xY0KIZEOKJGFFJJC+fqO9fm/DVdp+PzrZGwnxaF32
# DATA tFDMRjY5V6/8QCfGrLDhe/a1FJbJmDNQgInbpnhYgP+U+Angk7TrP8jQTCdkQY3rdXkLQ2IyMzBXQiXEoIAj/ofhrHfS+d/XCCrw
# DATA 8mcYcUO80q+NCm2zh7mdDMPH+ewZGZgxfpOD2aoyOpi2Cwzm/SdUq/08VYfmGaCUKMI/NRsDpXopdw7AFfEVmQAy9f+LC7duL990
# DATA 9f9vL7yO//9G/t58Q128IQP1+GR6OBrenLt27dp9Tt0NuXSISqSTWgX2Caf6pjTemCMAUdUgM8BkdHxwiBKhkppzGwYOOzEYBNTX
# DATA o06XLAWAn4J6DDhy6EfQ+wLASQNiguPpe4I1Dq4CXkCIkOozuFpNqdl04wPwDMvagI0dTwaircqEeifb5M6W4Gc4OOZUB4j3GK1o
# DATA hweE+PX+wqjhc5SdGg3qbK9vo6u/kOSMLANzq/fX4caEa4652UnlIiWMcG51c2NHCGL1BkBW7TQ272NxWwwBZepkNAjntuuN99dX
# DATA 6/YdjLHekGKUGnHu4cb6TruxubmjZRufs9jc1sMGJMGAVJ4pdZYfLYqWd1bu1bcxRAq1GJwfpTd6PERFDkZKUZpGRnOlvBEhJ8c8
# DATA 4RfAmaM/FEvJ2K/9fflLV5DzULxQnHuw8oP2/c177bsf7mCTRti8UttSEqbJ6EDMdcz5ZSZypQVBARQh4sGXguiRDo8Ru2ILwifj
# DATA w2APTGxiH4l5GFOZuMT5MaRcKsXoGK/JnccBk6GMBIc9Rvc3orgaKDXbfciZiA9YGUVXbjtFhZWJFD1cYPso4Gle8XlWmxgJ+Vg7
# DATA wy4coj2ZxVp2QuofdKE0hY1R30EkA6F5oSGLPcyJTovDWaho1QmOHa6YUS+puXmIdJPMj3OvUd/etsVuZ8CUZUSuK6oU5LicrJXD
# DATA EajFMAIU/lPw3L9lNdYMa6sBSz4AIL4xmr4L5OBEkxkVPA1xltA/h3JT4L+oTo16KwCVLXoEN2qkJAAkR6xxhnKJDUR2sU8e9Ueo
# DATA i5MNNLn2lkIvgJcEsxBbKsJELsCDBKHGUhsC+Hvk1SQIFsyH2hcKNt5jIV/GCqmA1rQCBuQnBWwJImitp7JTxeTom8YoWk1ZEFyf
# DATA jjpPCgslXIqyOxY9M61iosoKcRbqS41n1H6tJmrlVPCwjXENwSkNQhR2nywslHefLO7vPnl7X3z4zn6Lk45h2aK4gy4ttObsQfDC
# DATA QL8Lnqc3gubTsKPXEWsCNHpiIlRQfMd/T1vFZnlpueq2wXn8YNCiGVHRnC/3HWYF5Hd8Pq1Ui8vdyL+r6jCcJC+wHeOxXEJT60+W
# DATA 6t0vszeow/OMjWrfMNSdwvSwkt5UxfQ++nc6kq147lCxs5+U9mI8iDjaSk/Y+BDRxtn7k4uEPMFwylOKa9URm/UmuWrCyg2g/eAb
# DATA nsni+ZAVQxPNxW7uVdQRyO0HhzRXaW1K138PIE+JqQvOrd/G27p8TPPWxHmrtryJDvUUoDtKgbd7fHxUUJU2scJWZt2CORRm8ohi
# DATA MlknOmeoTtSCharX5cNdK86lNUCTIlhelM9crx+PB52ToIMRdR1IcRBcWwgYbOBaxfU/yCZZwyswkQxWiKoGKevDI0Gg8iBZh7mC
# DATA zEdI1jeCRfnDqph64DuDaFigefUlwkDS3Z5iYgqrLKd+Y/LHCzY24SZGiiZd4m+LCwued4gAqHPXscy82Yrbpdg4Fo0tox9TFgvJ
# DATA LKt+FupUGg064xgyheBqiZcsqiwY7ewLcogPqSGShx4DEXp7gsdXMTECiAg/go40JHUZ7cpH5nGfPFJOBTvvDgQpWPKQ4WQplcWC
# DATA WIjxS4SPweiAmT57OvCZC1lHIdmPJ6el5CqYOSKZVTFvdOX6EB3vFYKXqE7XkiOd2fkSmLEMaGZtUeH3+z2/evWDxubG/Q+lTtVS
# DATA ttZ/sHo/U9maQChQohjwyWSeyarLWFV5CMqFzsMtwYo+c5dKL16F4Ipk2KV6bKXoJL9f/QsFj3sAB2QZKwVtGiqCmJHuAJIA7/dc
# DATA PyiDS2nV6n6P4/qTdNlG6i7QBYjvVhDnMdVBoHw5ImmnEDZBRqDMdNPJPp7g4Vsflt86Kr/V23nrvepbD6pvbf/XkFz7KgdHdMaj
# DATA GNFCrwS6h0DSKfhGTZGXRKgiasPj6X752xCNCiOPayG7eUgZhPskPY+Sw2I0Jqa0yNifNtHkosqVra36xppLiqkOVmq6QaNKPa26
# DATA DvAp8x8ykjPZhiQ8t1JOQzoq5dlBPxbz1ixu4BAmCYh7cGXKpjCDiVHmNolulWBlclukTjFOTionZAb4zc4UbxD4yeKzzK+yp8YU
# DATA Z2mGpNLEGB26u2mLzxVxduseDhqVhxsr74tpWLl7vx6msmDZl+TSzDJ9NdbMXSDpXn/fQGj4fI6GEwkrgkFP9iofCR7AEEjoNwiY
# DATA GVTO4zfoOKFUttvr2436vYKsRGJtpEax5JhFfQM4HnY7dNEw62eoD0uxZRvlqPdxFH0kBZrE+2X7fWeIoJ6qyXrgtlGwS3toNNWA
# DATA kz1iCgbGFxWGgxy3WRP0R/wXjMlTdHor7CHPbi7RhUWVaFah2ERIbT0uAgIwFQLXb66HwcPSWX1Gb6Jhj28yMMmQr7UwCcvwB4wa
# DATA EA2C1nXGdg++X/8QfwrJ81zP81500B8OUyq6W7+3vpG7KkAvoD7BkY+AHrp2UL7hj+RpIeSC7+pf5TOHXnmiwmajvrayulNfC4w+
# DATA tPAMFiWaXC9gOxVZfSGuP4JHxRrTytrz/KsEhEreYy2DFt1em5QORF6/z6sAUNcnM3txLXgqW6TclyXFGTmzqfzqyVjHYg4l8zN4
# DATA qnwkL/2gVYamMAWh/LFyMBjtFcLrUqnRrN5eBn0RFlKlvC3HQkJJvH1zSUOHUZMgfnLjGdoEBHGxVQn4ToLVGWZWfIeuPIYYj8e6
# DATA h98Z8w1uJGTWwCqaxuutYvHKL8r7Vm56QxrvR1lT4j2QfCmHL3Q8XeaISjt1Us+rjGOI8Tmm/eFxNOcJdDGSQKfz/5zs07wdEVoq
# DATA 0mYFmDPciwS3++FufL3wTjV6Asax3fhG8Z0CQ8K0WwZ6TOt6URSsQeHK9eJf2XmfwVhTeVCs+nU+mrMS93kGdPJYkPoz5CvPWMp7
# DATA pgMjnwHG0jsfRSfP4MgEJRnELD+LO4Pps16M0AEwmOZiC1teT5llucWo8FLL8HjDJNe713bDsOh9VXQcFCJYQzH461qwXE0NUHJ4
# DATA Kr3j7qmEIJnYMFQNooiMQJtReEr9R/Qn/AQ/MXf38AViA3gAOV0/RczI2gDy2zPSC93ojb1I5w38o3zqqa2ScQi1ZAwKH+NShV94
# DATA p39ULHSOp4dii/8YVYmCUJrVWouIa08QQDR5Jhay3y0Cje1uAybNJNxdNOo2D1W3hZDbEJU1rwme9c7unkWc4vl2fbVR33m2tbK9
# DATA /cFmY+0ZZk15xsdm+x1xbj4TBdbqGzvrK/efrWyt07OVhzvvbTbW/+sKZBcqupVyY2owxeYPdye7w9aNMDzfAGYLFc3deHe7df0d
# DATA 0eosUebZXxXDUqpwkNWN3b3o5G+MQZoQUGnf90KbBrLqLwAsj3i9xf+KOm5Uyq3r1fl5mLp4/nvV1o0qfWrd+F5iDr+X3fsni3u7
# DATA zeZC+Z3W9WZQnhf//V75v0lrUeI9CenVPexMOl0IsEZgHvVN7CcsCQpS8yHER0xDkNsEk9Jv42a6uRSQj6P1wxu1YHHp7SyRVQl0
# DATA a3xdDDj1ZUxR3514SkjulWDnMFIKW0t1R5pK8BwhrHZ0q6gADB/Lg7aWWt78xFVYfqQEuFPSDcMbADkiOwuP5OdTvtwOALF32laO
# DATA KG32UyloC3yDjODB0fEUvI+D+/gKYtCXoJ9DwY6m2GHwniAnAfG1MyXg+WDaOTBM7+NR3Oerso72JJGnUX+wsbIKmZsa9a3N7fWd
# DATA zcaHlF53Oj3qDOcV6k1Zdde1n6Viowk6n3e+A22q7uQzijfq9+sr23UV7SnNeuy0UtCKp1DmMxInXeVASCXHe+BSO48tzj/VDZ/O
# DATA S8+geVqLd5RbRxtdN2pPXS/9U8MJnnDK4trTcKUL5xCoRcCBAwJSAB/10bDHzd9AibYECdBFveVVNhBWQSAvd+FZ6InRDR8KKiyv
# DATA HHB6ab0E5j0iPKU3DcdP9t4pKCcPI2UGCGGTKB6PhnGUuIHyc5KJlm7dZk8SuGKqtYbjTxQHq7gucaEFxJm30UygYpOojGNYpagF
# DATA 1MuLUIzYCjhGrIZRPToHqNTSlFxwWhUl+OhnXxGHzB/t9gRPl/8BPtk5cKI1J3abvUlnH2wt/RjrwwyViUJjcaLLDM9WyYsMnPM6
# DATA wFjAC90K++JnzJBkSRJvqikrYQpE/lmxJkUcufhv8R0xPWbNMwbxfr2xLaQGpXyb4L17eixYd+GoMwZEVa5Pgp5DQiyNkjQ8KcBL
# DATA QKeLy28vf/vm7eW3yZIBT8VJhFVepC88d9SlG0FhoVQU+6CwHJRxd1C9OmzWcqepZlps/Ncur083asInKYDCrPHjAGHczoCde8va
# DATA xYgrLVF1c03D9g7k82OqYvnf2L0WIr+faPJvXrMtnnCsg6eVPSnORamglEZ+/vDh+hq/iuIFfsy5s/72YX17J71fsXg0Nt1Q2jJi
# DATA /kicOvIb54pVUMDVGd5v7ADhcQKbM3C3xXfbRCbGnKV7yq8Qf7ixvfJuvb21svNeaPUon11TFk5YNZNefXrOFCXpyTKgWekZao9d
# DATA NCxdPh0QyyASVVUJ1VSuJdNoSH1uLrQcpR8Fi6JZzsyyrd4oEl9f2dpq01UKxWofxhd4OtcCGgnDZ5n6JKWoscZmhFCAHsJWuf5Q
# DATA t1qDK8Q+IHw+vb18KjUNrGFIDkkqAhAml/IAGQCyzEaoNOhdby5lEtGD9e3t9Y17cgL4VAYtBWC+HnW6lWH0mKtT8L+lgL1uS9L9
# DATA uhIfdoTkgdJYr38Aol/R4zuWTvclIb6T0rVKzZ86KN6yIqCpgrlxi4k8BrxChtQXmwiC7GKskMGbEnAQ3AMxVFuvHDivIOoYO7IL
# DATA TsKYgIXw0WhwfBSBI3DTchFU3pFNfJ1UUfgJkjdRjf19r3KlYGwBLMnMmfI4wQMpIyFoIrp+JRywgcXkrV0pUJJu3LKz8iCvhkUh
# DATA lSy1ii1D06O2oVi9kzFcvMK9/tCEeCRAOGY2RQ34WE02ye7VbYgTEL8Dqzqd83kvmF4GcFQ0ZUdavuhNi965qfaDzYcbO9Dwu/fX
# DATA V3c8ydC4esdwh6sn9V6yVR+l20eLRAQ2GpBTgnp300ta5adIy0Oe8iLsIPbpq5JcCj7t6CIoVqXfQzgCdrKsojn3vHmfeOk477as
# DATA JAhRE8tfT5OArwC4G/XafJAaueSlPbqYimrBAduFGZivoCQQV3wgbEj5GxSIv6DeQLp1SnQLFwvXAaRIAt7GfVBMmBi3KgCGg1+C
# DATA 8l00vRtDo+gK37jQEYQiYvElc3bgJ9RxJDoF4B3Q9GhYZs+E3SE/Q1haG443P9aFj3R15MV8wAEbJQ4+d5c2kTpSYwskoTJKhB9h
# DATA iCDZrysMjbBcHo4eiw/cm3PXNKGZSq1BXgoQIEVIsKCTn56wwGhILoYGCABwAfNsABzrROU9FbwQD7U7ku4gprPTC6aAHUPHatQR
# DATA RzZOt9IBpYqYKvFA+sGZkYbAEjWlbHopAVNia1JbHkal4zK09GiCvWYKZvIZz7g4ByJTbswS17hjN5eC79ZsAagWLC9857bCLD/U
# DATA NgXWjRKO8e4EIXZQHwTu+WGr+CckN8mUDUkZSflookaqqmKy2+2+2LHttujCYJ9sy2bEsnhYSSc7VURfcfQb5j1HNYciF7aVdIQ3
# DATA 7hFmne65Z1TWeRRxvxOqCWtasurjd534BB2yTvrSXrLPaNCuub12Le6clt3xdu/L0C6GngUhALy0KcKJDf+BsptTKcFaZW/88BMW
# DATA 4W1s7rTXN8RF/D54g+mmpZqIam6G/N0D05EooacFHLqYYKSaEtwAzPvw7HgxhTsHzvS+jFPygokTS5ST8AHIjBG7Ak8naR8I5LJI
# DATA /a0bsiWmJMwAJU7qN8YcDJSiiAvVZW9pGdKPQPF8rlt+dYc7qam7rRBCUzg+XBo3zMU/+TwVr3oBnI5lrwLTseWGqDap4Yuo6Rp9
# DATA WZJbXQN5OpGzlQEmjjCqLVp+15AQhxwLoArHkcl18oA/AIvLtzZQdVOI6xjS5V8hXiVRpx0HhGGOYs6OI7yAyYBHuuAZ8UdBWb9r
# DATA BhIsgOLx7aWFlDgVeIfj3rDFmoyfZF+MmqDQnXqj8XBrx+JMqss4MlELwY4LCaqq+gFI4WZiAZPwxFDMpAY8XHXvQHvYAahmQgdg
# DATA fHaApL9rKmDKMi6OOTiF1vzUOK6S4dXMRLuHnWGSe6LOGAkAkT3IhAAK406XMHG8HEb+iDpTg3GmBXNlyXVba+AgcPfh9ocJ/88T
# DATA XyAVeQ8nh1kBxMtDIb71fxyZO5DGXfQthq+WNfwnzaUzfSCGqzP5dJKPsrnp2+RsSMtBnFnRkjrkznuy6VBVFVws7xcSZcm4cgiZ
# DATA /WDS6UU5zvZ0Do8Mx8upxNBQCWHOPw1USBSjx+1eP0bcMgtqKTEQCCGU/UR2AQ0SaR11hqK6Htm8kFhnjmNr5V69/WD9XgNdTHA4
# DATA 6w2LJ6TuAfiasgPop1dK/+xNnvvknL15DHWgL4Y7JT4nefbWMs5e78uaZeLBrb6me3WdW+RwGIRsf/bALnBg2RU4p9Z3M06tc61/
# DATA /hNDObK58hcdFBBQR2H2eh2qJusxFreqhW2tr9OzYsYiGnPi6t3sPemJ2Hbya6RSbIoqhbAYM5EKWadWRpg3AAM0AAxNaI4DS8r2
# DATA ayHFewrEUKu2qEL1A6MvPeg8ASUY0AAUcNVz+NJdUP6gUi61PQapg1NFi30llk4hU1Y04fbhQb8XSkYrHoHooM4TS7tkOXr4iK1w
# DATA Qawqi/BmCGbiutjYaasIIpaXaslQpzm/u6c6WXKK6p6Ck7DMN59y6+nN26e7XNAX1XUOEk7Z4taAnUATGQwFALW2sACLbMkKFxQQ
# DATA rvxGeC7WfOFDzDmUi9UZF8zkMZbn7khG/wSIAehHmOmliaDWY3APdNRSMqatkJNKi26F7e4k4ugnlEhmM0uKzkMkFB3wZ+wXyG3D
# DATA boj5NkSSuu1+AUvxs4Cmuga1GNVJfC96BJLUCEPcNHLv1szp0yeXgvs2ltAQNYr+a98Vi65q9rX8KudA96Xlk0OuROK9lOR75feI
# DATA S4lvvsNDiWGX4cnkGOWJcFVp4wmwtbl6f12PLZl+lU5cqapEXBvwCQ1bGauJ/hBcMa1lWr24J03lgvrc8p+Ejmx0nZK++GWCE3Ao
# DATA gAnq9Yc14821+vsbD+/fx19ALpD7j/JNqa8+EeLtxYUFvwyesa1XNx9s3a/v4Mlvb+189KChZaQ8oTOlnzOO6mISTn/fZIJ+cuIA
# DATA eYIJmD1FMlxefJYiyIUEK9zvm1t13u9egYM5kwHq0fLgAeXYY5a15Tihz8xUq/uxfzwXrRSQEdQN3l5wE9dgPoA2aTd5nKSut/dP
# DATA Eng9oXNnccquxJ6aDiY1rM0w9vZjRke3LyvQhZbeSbeKRsYkBOfxKt2gxSTBAT5PT4hBAd0KNEDPIOqIHgKc2d5k9DiG5MSstQDo
# DATA GaCAaTQ4qfi5ZZo6JPXCn/5jLitLuuBmkYfHEiOmy1j6aqYbibWLGLaevVNyaJFBmy+3Tc0g1GJ2mzhktCLap1Myj9PxZMKRh/CO
# DATA NgueM0S0mFatV5d8/TrnvAw7j8Tg0c2hql5i13J2rlFd0m43XDB5kVW4ZqKQC8JmyFg0Kaem2a8r7z2QbMoNlSMD8/0EtZGdGRM5
# DATA ttuF/nAY+YJy8TnGiTLcAblKS0dr14bLOKAIWF5KgpBbgDkuSA5M6A2P3OIV3V2Ebd1PB2dbtFZATCmYGxIujN837hYztWJegV3m
# DATA IYOGhai1vpmiZbLnL/N0s6bZojpPp5K3G17LJ+gzgHWVguttf4CrburcPeb27+P90jrQlJZe+jok7970Sxtd+UvGTVzHUqCjSSn1
# DATA an5xrXOK2mUWe/Ubsmfpci0NxaX0mRe0tGd1MLVzs9AFLzQA5dhEqw7uPHK1XYadrylwn9iof1BvOA29GWwOI4Wpi4LGj0ZioJ0B
# DATA 8OP4eH+/3+2jYxfE9ckYRQjRAq0DzEpHXOAO+zGC2iRC0U2gLpPjMbqCwqOUMAvV/DyMid2C6WqCC5SBclmslvEJ195KDQG/PLJX
# DATA NsJXzjtDSr0ZSnfl+UoXJp8iXbq+am2768/KrMc/pgsp4lMlkW9G/Z6m6k6o5P0OMKVUNfxMnf03o5o3tfJ/Kir4XDLuVSrkZzgv
# DATA QcC5VehcavhMAr4q5buhd7+Ixt3VW6ed6Jf2O8uFTZ6hs+4P90c+zTyHlWbBhetIJEIAyl1HfHhOPTf8bpoQfNr1GSRXvBLFOfaC
# DATA teezSfiKFedtv43eUGsSlR1Uc6rjUNOkVew8ZVGPmC+r1bE39qmEbmBA+jVjpv3nN0WpuVmjDRCBzc0djsexuKguwYLY32zetc5J
# DATA E4cAg5jb6xvvbrbfFRuc6wPKLqbGk3gqqG/sND40a0DCdhy4nGWiMx0WSedwmDvX/d/en3YOBoP49MjNXBFnv9KJeyi3z6cvf455
# DATA uT6Gr5YHQ8q9SKYErGXATORSPJNyWwgA0L+yDEt3dOWq8hZGFNYgqjBPyM9MjTXSMqur8bPvrP1OmqpagwxoUyLST0pp9EzvaZiA
# DATA JvECtUH8SEjKHZpe91cO5jlStO5fe18mptHL9FR9PK1yYpunssJTFeIhXuHf/Bv4dHd4TYUApPfDl1XaOJgSAwq+q69C3naL53L1
# DATA kRsTLkiN+srah+F5unKua9kFrmeWgz1TgVoczSrfqOnVu6CjkwnS4Gkd2VQiygaEAvXLrJvRhZt/M7hLWmVoj1LsIi7+UecErluY
# DATA cakTDCPAjR9TlhidZ6kyN1M7q+iZJ7TmpyupopGlJBkoYRerS2eDr4g7/6tmxlaONcgqV4VcnZBn7rOzL1/+IqCTVPaa0sHk47v6
# DATA BrPXEZJVyTi6DCumBHj0c2PTOPhNseVUena3K2wh/7Kfi6AZm6P9YH37wcrO6nvhZVaZEyvBIv/72a+T2VJ/j5lSIZ3eP1IKwXDG
# DATA os68ruUxec4S9Ryza7aQ5686VedD7XqynSSdfrJTERVnVu9mz3HyPxhpdFyHzdnpdLL9C/yWATvRCITEmTmKvL0+TRGXL2DYydRG
# DATA vVIj+JuIksZXD8KQgSDCADXsvWDvhGJMx6P+cFoJtsQkQCBxsIWKlvlhNIVLtqdWVjZAdOqohPcb0UbQHY0hr5lSdPb6nYPhKJ72
# DATA u6DCnI7ofOnKtOgXMtmn2OPbJoR9fjWosR1mmr4uzIsS5E++zdwy4XDoQylXeH0KT/sqlbHJpGVzV0nPCVpGxTUtCgbgb3+4vVN/
# DATA 0N5aWf0+ZEyRnk3iIrj1cCfMGqk3b6qxB1bx5Nmyt8GwRwTgGOnfvpXVEs7/rIytxjElE7byrdersLqQeo8nzg14cxKhX8w/JJcE
# DATA BdcpqXg/6sdiEg5s8J+ESim1tMoBM+w/2Ub8xYKZ47Kyc0gpEQ8e9J+sD0tWAswKvoS8il6V6QEQGKA9xVdjUzkD2kCw9vCOc11c
# DATA xGkwpGjwUtDp9Xi/x8dj0SuMBFEvFj3vAHoL304LtxI2SU/dCj5K9L2AMffcF5oSzh9a8KcVLZp5B4gdHok6RTWs6kyYV61NSIgE
# DATA 48GJjCUTW6CEGGLOW3uj3omNq4GF1I3TY4+Ihr22xBUsQKm0QgSmWAhXCUKzDIAYMiOmBFT0KCk9FVgQiyWEWES0hTBv0/ej4cFU
# DATA StxgzIJxu/6m+Lp+O/aN/jEapknEwDqsKT/ExUujPzMwPpuoTDgALZ4RbkMe5HmfKRphBUA07UyiNqMFYG94tIyPYIISE0SC+M9d
# DATA BCTGmw+2UEy37OK5h5S3vHATBCxp3grf3WzcXV9bq2+EpzlUvPJ2IbORgo/mvfoOedviL6RmhnyxJEeE2fZw3bElwDSjeWNfOH+I
# DATA bI72KR1BDIJPIZwHJTeF9s+n+tlm9UZpsaFqssI6dbautqcHUWpHJTpjSn/ozZaEd5rPxgUn/ES4HS69ugiy9DnF5hH9nD4tXHwa
# DATA ieA4mvf8vaFQ8ku2brkjUxTshWjfE3mcs2dbm9uX7doAObKiMIMJtSGBY5JzN1uZJMb1Eba0CvO0eNvOpDOM96NJuQ6HG8UKsvqN
# DATA 3xaUUenHgjn2p1o1txB8F24tBV0GVZY2SO6VETPjfBoIiLR6eO4g7KfTl2KmO4YhwkLNEhEO52fKeKFvgAsE4p1gXDzjkjWiR31U
# DATA L5x+01vWR5jY00sSJ26++U6X4in/Mqly6dbtvyCihBXzYDjo0LBXQZuaU3P8P3SoKfvSIjHaihWSj3S/WvnJfulCZ0MqkZNY+Jq8
# DATA /xzI21bjfkOEbdJ0wjZzFXScLlNbl4Nl63IAprt3Nx9urLmXg1eqFrU69B3y4FEKINhOpm8p6XuWxTmVpUbSY7qALsldR2MueqO2
# DATA kAcBHs66Y5q/A0/wFyC1inTMoWVKes1DKYUIaLyioPqQhI3nfixA52WftdP9Hb8WZoctM6bg9ubq9+smlZv1WR6j6HFjKp+mUgFF
# DATA LjolqYYhzHUsVPVWK4Gub5uOCayown/a+yNMFoQJVvvgD8/JNYGO2m2QYtrtUGY9nsToyCH2H36urEwOjgHGcAt/UZm2wELaFjJQ
# DATA t90uGm9CfrJ2h18paBdHdN7cQg04Aw3jN3E/G42n88plU1puvJWZJ233cATIxjUCOUbxUDtNOsgGCJMug07FVJQlEiaWlaElrcxh
# DATA yDjIzEKkPC/eSft90NmLBhm/o5ktuwnwBk2vANWmGb8zem9GCcal5E5wMCuXxX+gtNQ/QagqHqbRcZ9trAsuuuQ2uvnWn8BdvHFM
# DATA +W7IrYT2toKthlwhQCs6qYJoqGKHwuo4oLk08wa+ReYN/CgmjD/h6vBnXAn+jLMu0dH97RIFmTiTALzvNsXBT/iZZ5q/8axmN5Kg
# DATA TgvSzYZwdZvO1QDvCF0tYmvquooVdFiV05ZdmbnHMmrU+BP4EL/2e3ptfKj0pJd2qyrOfev13+u/13+v/17/vf57/ff67/Xf67/X
# DATA f6//Xv+9/nv99/rvMn//D4T5I9cAKA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
