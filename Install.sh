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
HELPER_BUNDLE_SHA256='66325f59d77031b1f337be51a2870720752c0039dddb903dde4a03d964e47df6'
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
# DATA H4sIAAAAAAAC/+y9a3MjyXUgqs/1K2oohQHMgCDeINmixhw2e4YWm6RJ9ozGHBpbqCqQpQZQMAogm2ozwrZ2770R3rj+BXsfcf+A
# DATA 7LWutV5L+gvd/2jPK1+FAskeWePYtdrWEEBlZZ48efK88+Thwd7+0dn+936f/+rwr9tu01/45/5t1JuNZlf9Jr93e5329/z6976D
# DATA f4tsHsxgyO/9+/z3+dErf/fFi/3TY//z/aP9091D/+TVZ4cHe/4hU4b3ZTzLknTit6r+lv8nwWQRzO78Zr3Z8by9dHo3S66u5355
# DATA r0K/+afxeBLcBjex/8Pr+XyabW9sXCXz68WgFqbjjZl6+iNv/yae3aWT2E8yfxrPxsl8Hkf+PPVD6NQPJpEfJdl8lgwW89iHtoNg
# DATA nozxYRJnXjr059fw4igJ40kW+1EaLsbxZF71obkfXgeTq2Ry5Sdz7H2Szv1gNEpv46jmeb78O5nFwXgwij3v/Dr2CQ3DYTxL/c/j
# DATA STwLRv7JYgDd+4cyBHQU+MNZHFcJwlE8nOvhh+nMy9Lh/DaYxQR6Or+OZ/7rZBJlPsB6m85eZ1U/m8ZhMkxCAObOj+IsuZrwlKGT
# DATA xSz2wjQFTMA8Adu3gDSYYwyDjceLSTK/85MJ/xDAiNDpJJ5jv34WzwA9vhq/xhMS0DKEzR+n2dwvAHA6C8I5wsMQ+vhUweUBXPPg
# DATA NTS/De78u3Qxo9lH6Rghzq5VT4TsmCCjTmq+/9kdQD2Zz4JsXvXwxWKU8njJZB5PIsbDFdBWAN/j/Hje0niAQ6QKpExCcQCTSa9m
# DATA wXh9HToaI+CIUyQBILoggVbYnVkmxAt2kswzfwE4zABxX13HgPkYFyp4jb3iKxpxVXyEr85iIJQZEhgMJUBWkcy86QymBhg4fmTS
# DATA 9uIbWOfXwRxn7l3j/kGMWhi3dgNvgiX4/LLgZ3bFJAk9jP1kiF0CPWXXlaoeAuYQxskNvryYhdhlBEQ1A+Ka+FfxnHYOvejdwoLA
# DATA V+tVbGOtuh4eXgdE+gBbyNBhJxOg01uP4JQFgo2AcOruXk/SW91vlGKfGfYM+MU1eR7fxCPcFxm/gkM8RFMwyjwO50xBxJwyjzfT
# DATA LZDtPAaW5JcbFT/IYNHntJeZhaUTZzoMZblZgZnAcnsIIfEcxRBur5Pw2r8CJGYE/ii+AnCIlWXEMIWXVa2l86DPDdqQUTK8c8aD
# DATA qe7CXoaNEyGDHcD0hoBAQGME5DaJkNyQXolWS5oyEkaLl4xh4jcxMsEMSCrCjQXt5/FsEjAD1VsFR5W1qOIqw/c7T9HDbQK0OQXe
# DATA GOFIwE8BojGQ/U2QjAJgl7RvmHtE1sqkXjIJ09k0BfaFG+BlMLmzGyzRKv7vOg5msPlhGwBavBg6WMyCK/g6YNTM4mwxmuPELc4I
# DATA nX8BrBwmVM1xRLO3AfII19NlkVmVF5C7BSTd+UOYFa8TznGQLuY1LQ5WyAGWVYjj17QkvJYJDCg4psmM4jkBTrjmDoIQtkWGmwLb
# DATA KLaNpAnD+jghgGwUBxlLrsyzt+Y8tbqqfYDM0pzGET6wXixziHgIkdkCqBkxSWiKzbRsMJgaMkMOngCmpRQszwGy3L9YJIBnesZL
# DATA h2SDbDontgASJNwkUszEYkdDFxCF39liMhHczhRmPNoW/AowCe4cYDnHNkCyQMmyDAuWnsvrVoV18QJpBjji9UqQ5rm7qmz25TUV
# DATA JDDw3kPA4y6f+OkogqmLiAZ9AtYEZQG0f3g9kbJo5Oyadwk3B8EUZI5MAbjS8RTb+VkyhqWa+VdpMMoII0AVSQYzBcjgbWAYBhJS
# DATA lTSiZQ4KppNDVq/k+3WQeUywuIGRza9+UZil2jvwGo2Iq7gA4Y+iymhzQt7AhMIEJQG8lLHoB96YzImNIRdC5go9WPxV7T7Gesia
# DATA 1DBF3Q873T99eebvHj33946Pnh+cHxwfnXleveY/B0474Y6h2dq5xeXXWNjTEqvZtdT8Ht2A2JvWkdeAHWcg7uMA4NdiZ32UgPgf
# DATA Bbci3oLplPZnToX0lAqJuxQWO4vHCaJjEeLGGgfZawE9BsWWWLsNOTJjPSJxcdqCgu+I14CYo6cg9/39AIaSJqz+RhFsaVrtzF8D
# DATA kbcGrdbkhThbI9Sv4aqBCgBiaI1Y7AAlUZTADl/A/FFJSGdXwST5WaAQfp76aywQoQuGjJGkjIHhDAQdqmtRMCVVHr9MQXaohcB3
# DATA PJR3wNCza+IRxIBYdCgBb0RzVbALGGcJIswc+cLEi9+AVkzvMQOx5BABB6iQHRsI4NYGXxOYPJBtowQZPL6CwPOntUHAwmmNBrZb
# DATA kQawFoIUn0EL/GVNEBEnAi6ItokeURba6pz69kSRkceCYGCy0+AKhPMyjiMiEFK42OwAEcViQYSTZ2PuNl2MIlZaUeuJgM2HcyBZ
# DATA gEJpLwl8HSVKW4CFGeJKkG4ipIZUDvsTW5j1gU1Q9eM3YQyLHL+Jw8VcbDjc1R4yNNCgkHxEfWLxCyr3TcBKMa7XicwTiQBUktEC
# DATA 2KLmFJ7DKco02dTIYJttgK6sJLxWfUTUMO9n/RAFJ+oOoLqAwUNaOS0V2lU3wFJQVmZgN4xGsg6AoZs4T+i4P3GnI+1MrQkQR4gn
# DATA OLh07CHZY6/KcEhnWpVnswCVr1jsKjLvlDEZkOoIfc7SxdU18H+NURHJvN4gA3ww3SbZMBaJzUqsGNIMP+CFJZke5Sbm7umHYQAy
# DATA HHA9HQV3wCp2pzipWYLLdEha8lEKZiewDKU+xG/mSBw0X7IaZOECHm+C/ITwDR2Nkwl8AxK7SUg6e8M4mGvzCVV7PTLs7sAa25Da
# DATA hMbXKr43hwViwS44CuaiXtC0Qb7O0DC9I7mjOI5fFmIVurAnIS8kYu+JihMpC0yx1YxYJOOU+qB+DTtWgoQhvQZDCeVQAqKWl8VX
# DATA jhDDtg+GaPdZ6wByNCOrIIBhM+KZNElU2QKSLrDOU2LGRr4EHuzWRZXNasY4LAyak8xcqKdxHM8zHj+cwdMZKziNmn/GatweaEIi
# DATA zdcszW6NjW+HDbHAR7saOBs8Hju8nZwYvB3tTUrbIJmjGDoe/DQmro3dm101SSfropapTgOL2Z7NA2RYkX+g0GVetlDI+5CZcELP
# DATA wCZMwiQYeZnqIUIlgrWyALdkegUyDtVnaZD5gzSCfZQu2y16oExp6YwDxD5u93CBCpyYbGNEwgis7wWYSqizxmIAZmS7wb4g6ycY
# DATA p9DOssBw0sRPha2oLtT6nN1luL6HyWAWICNbY2konNgoDbI3tcgQWeppWUqtkIRA6UtHsVB8Oagg6uTtSKFgAosC/EDWBrhb+Dq4
# DATA Ysb+MvgpoGAPmFQ60a491iOFFxkVAAag5p7VnPb2oMLKO1D5hPUqZqfKDNAAi78NELk0Lm55IDPQp1mEBf4y2dByMXCgQei2Ioey
# DATA JSGiDAiSH8bkQTwANe96azko1oRocKulMOgbgEsIFTYGNkXNDBgOIDNUL3nl12D+xyNk7JMImEdGa8yoAVUUpJzCgbIOxVjDFeDG
# DATA XjlBMriroBTmCTLDdqkCbLKsypoIDp+M4hnTIdt3oKcaFyG3gz1ktizvNWAAc/Me9ombW+hzLwXWkE1T9oQwg3EYSeL2SCQlKBqN
# DATA vLxxOYlj5XQk1X0eI4Zhs45GQjpDhtLMlJhzhcAis9YajBxaqe3W4YkyuRM2gUNO5+QpId9oOoJmKdp0WlNwPBtzUMtiJnO141S3
# DATA pczLb1ZCKU9ktD5dzKbY8zxNWeGWB2jTGjcOOkOVR05RrnKdWEomYBUoApHJJrcLMu5Jz7zsbkqGFmb1AsnzTYCbouoXraOnBb6l
# DATA PmijzB8mI9KjsjREOR7xZpXV5Ifi7hS0s38xzm8t9lpHILwEbRxmuJsEY/aLeKNk8hp59mKgUaN0Aa37r/Tii9Oj6ikhOkCf/TwZ
# DATA o+4RBfNAeUnEMCUTlklhCBYqWErz2zieMJI9GwbLYw/YzRz08vYowirRuENBWs1XntRZ5qHXdRarTeAHi3kKAMv02PJaHtkZzuPh
# DATA HoLE3aZ5jqedmFkw1rNq1vzPggw40ok2PtBY3AXrj726/hXFCqICdYmIUT1WKhv6EVDGLHl8T5QvFNFMIQmYwU3K5onS3Jie5kh+
# DATA nuWHwObjeK78Kmr8+A3aNwlqqQFoCujAIH/0YjJKxgn24fqJFU9Ztu7EBAXzBHR1Xg/l/0KbyNiKZJbKd/KfWuCQ7GNPr/TEvqwJ
# DATA +RlJoKCggw/ZPJmDTcCat+k8Pz8Q05P0FkzgK3Z+zzxZE/TzBgkHArSjGPfFTTBiqZwZlA7uXOsPlvdrMClRJUbbpkpoEa2fjVcH
# DATA qMzEEMCExfALK9LabrUdRiDuRqgRBbISKnRHEN6in0nCROhHAJKhMI6CRhT03ODio8k0hWUpEgxzXwxRXgc34qccs7Hm6q5gPYwW
# DATA GSzDiO0KgIv4uPKHUvQFOR3ww2TE/BbbGf8nMmNxDFl0qsI06AG8I1x4iv6zvMGA21GbdORaQW41S1gnE7nAGPbE/COGpdeNKIOk
# DATA zfVCO8UdIHOL5slU/fEiQyGHK2NjAjYELdAgvg5Gw6rsbvqJfQ0JumnZG4igVGkb09xo6oCI62RALgxAO20YZcizF4xDZx71qKcR
# DATA R2biQDmZ+KMT8snzel0nUxY88GYNY98Ka+LSgN6Z3MNkFi7GqPejRu+Et5FCUEMXn2fsUCgxF5g3eit9/4wURHGSulHsZ+hpIRHS
# DATA qHtIWBRVAIRj4C0LZncAXquGHAQjYfj+Kw4asfF9ylv1BaJmF+TT+h4BfIPqI/R5SBvxKHWWDUUnEMcA5TJotpEW86ghDYcxewBg
# DATA uOtJOkqvUHyABRlQiMHgx3L7wHb3h4sRSO8RUQxM9kr2hbRHwweUrkZDCZ2vDk6OLYYxn4HdD31GYLxyuKdZ958DCsYDeL2xtdXF
# DATA 3eQp/ze5WBVxKCKN0R3EKAodJMCQKMXVHHRwmDcWcQOXQ1Y5yhogGnCqEg2E5SLrAYh+kIDkyA/iYMxXo/muW4RDM/araO0x2pmN
# DATA gpI6CxMiFWHEBUKRiBdlM6qtoIfmtyYLQHbqZeEoSMY0EwrQz0VQkfjyTZoCINhxttsmFdmArIHDz/EEuSoZjMDKUdW2FVrSRaq8
# DATA zYmbJjOmMditJUGmzExjc2nJvGJswtq1a77Zr1+qZJI9dpgZqSMrm8s2UZMSiVzKHAWGBYqOnyYcTUPEwTZJFuNi1jzJpmDWp4ts
# DATA RLkunuWmgl8kxoM0HaMXXlJiHnRmPfNex/EUVwu917hZ+XdmLFrpc9UkVHgmdx56SZRCcqMjLpHY6RhMmimlWxhPzwQqmIyiBwAQ
# DATA /AUDsFBDjr4BepRP7RmBcUUbBww1Ez9Y4eOCVqnyVLt+br2MnAKBg1BCBlLUJJXPKH4MUu0lQdXBU1sA+6HAP+y+6TRFZjczbkBJ
# DATA MuDwEqq2wxj1345NZi+VJic6sORRFdCb7b1fUkpFt8i7vbRVnYhW6Lwk3hXl8rLpVTGG2NMKgVrUdhGtStAqlsDLUPIzjODa9ryg
# DATA Qkoq+/NQrIeAqDvLdVhIioRmQZKXiMcG6IDdPxhavMHckwgzCjxv8K3GoAwwE6YsMhV4D9iSmCmf2wpuvJ5SgcXKI0+QQJ9JtoJ5
# DATA gEaOQiou1tqKrbEGEwsrrGfinJRWSswf2NpMW7SWP205WicxPvQFQhufY/QwGtB8mmVxpoKygYlqWS/fggxmbzcGynljV+1dlhPd
# DATA mgd4gChCGTBbIqaq4gcEqS0MxLiSfCuyJauwLFfBLBphBB21ZfRuX+N2QIc5OQLjKG94cAR+kubsJxtvyso0CtltcMfeQ8urAmo+
# DATA mCQJEhfLV6tDSZmiLKwsBmCZKwuLj9gpFVX8A0vYXQfZA8EQwAzxHNZ5OTzhrQyLPENciB/IET35UWzPMZE720FqBH/lCCxpOdqg
# DATA vQRkopDWTFo5ecjZmadlu6vzMHUwjhWeJCoWxVPM6pvMVeDadRJxgg9o1xMO3ZCi4yQoOYoJcWW3BwBsQP52FbFUThdWD8YY7UAp
# DATA oP3mVTTs0CTFMPFNOlqMJQ8km6eYdYTPnPCgEt9WuHfirQVXV0i2GEdNFKQGRTT5eeZkLikxLZB7yr3JqhQJRs4iAQAcRSdd6r8k
# DATA qYreIIbNjigR35SJsItxyiYHhoMmZFoVLR9FzOH/1YyMxzEMFpyCZzYechhb4ptopJHvqiOgnK4tCY9AvRAh+AKWplACuq6MAleu
# DATA llvMajwjtzLgsYj4zkrxZQXYxrANgW7WMcONuFmhvyo3WF4FYVqaxEYcAosRQbinx8o5uEmUg3ECMoP0KgquXd9lpKuyNJ97ZeMx
# DATA tp4W0GWlKkk+wSTRGXNesfMtecN6ReBHixl7tVTP3JkXAl9Kxxy5J/okb6lKpyMuwxmfLIj/zeYYeLcztKQnrJtVfeLhrIOB9AQh
# DATA j/sBEw3v4mDGjlOrSeZZPiCl3k1Z3hAhg/FOmLDUPnbusGOBwAehjyEVjByIsafkrghblfZmYUZih5R36hml9iFvKctkexE4+YCh
# DATA EO1mpcuvWrzeHiPWf/J6V1UcknRnkLvjlCPt4qWBbZSlE0nk4OCyGgvtGDtykGSe8TRppZQoBrNsTSqdKOarqBmV3aU0wgD1P1H8
# DATA WacSGrU4o2vN2csj+RHWwrh0hlDZWYpFgCmtSuXckjGYKZcNu2DTMAwy0pfY7MPwNMYE0HjH30hL8pS31krTjopBZpmnN4O21Tx5
# DATA OlCqWnfAGsuKjTsQW4e2JK+DoJnjG+T1Bo0C0F++QsuftgpTBuO8wgoeY8v4e90EyeIFFVuFff/BnUpQMT/ywLTC3nAxYx8brzS7
# DATA aLUGIyq4b9mQj9JTzpq00ELJFBysJQgodDctYHvZEj1WV5KJJzlxvD11BqaQcZk9K7yfiUchio035K7icX4rM6fMRrUkOVneYkse
# DATA skmLBkgy8UJglJY3FWQ+6F9asFszywLq8VYl2g4TDqx5KzbAqaPQ35pMXFBoM0oVKX61KrSOECpXoH0yxrbl3Ex0YOWKpZuIboYU
# DATA ynHYzLHLUPOIV+6CBfnPpnE8W5+n6/iXE6F06pvCJp0FSCZsXXNwLKYUC8ZTQWy4KF7m+spmmFzNnHFIDF2WQ2K3OuGYdoE4OMRC
# DATA tbZ5JKcIUBcnvg9EYrnlLLBQI0e3ve0aSCQmgVPUPoXiTYMk7wShgXfpbTjQAd3IjS8sMTGdiIMOarRyULatESCWxKSsuWwxZmWe
# DATA miiDQmf6eHM880VzhqUgkxRtnxj2jJ00gtkmtsxTjUHOBWOQhlUvRWKF52DBRiqYkxkppSKoOvBLgnPEvZkzEOSjRQMcNjlm/2HC
# DATA HCrj8B5qlMlE9hUnC6ppMSvJT7bqReliMB8uRpyfb3zxsDDp6IaxPAxuOMWeNIKAmOOLXA6R1h60WKFsJSvJCM2Lqr/mIMrJJPbm
# DATA d1PS11LOIAPi0qk0QJzhKODNr2D3XSNfRVEXcoYvzg/u8yRoYwR05s0kneSaemAELxSUvETxG3Ruk3QiYp6yhxwAp8MscvIFAcMs
# DATA G63SFaI9B7laLKsPMsdx+80DyrzxjCxHYRwtUKNlVKGHVQ/A4C4m1DXJcPwFxpNUPfLMkxaANEZuP3Y2xZK8Z53iobl43toB566w
# DATA GXpAvIk+qxQZe4NZ+XFjmFQaZVWkjDCO0F1exRyA63QmGdr+6/iOkcusLjF9K9ZKCJbkGTLVOWdm+fRDVuBDUPloDoDIfbyCozV0
# DATA qCxbrX/FDnjobfGyBabqxXlhIsE3sNEXyAoWE+Kgopo6JzeYYXmKQ+KJtpRT92C5MPjATIBdMTwvTk+hUN8gJmPajZIg3Qww1QMP
# DATA asHqHQydwNJkiUnajkvF7MXawsE40GXnpQzlMB6bYDZuTXaMpY2H4QKtpczTYT0WfYEaytqFkjsxtH2L2KWhS89ZS0zukHxiS65p
# DATA FU0yjKbxfIGHXJVe6bHVSkkb5UJHoQthRiohfAMt9meSaLtC4+N5u95ghVRy0A1i2+705DTaqh2GB14Xc3W0zPiAtTeF/CZegid2
# DATA WajhWk9SDolauh28PaeDqhwsQSXuzt5ZOYqUQ1KsPTsYp9Q1nXBluyg9ojrpkOXG6fHLiqTu2NBbFs+qiS9nqAVergu1w+zulGGN
# DATA miElYauoCpHzYoouWc4SkLgI7VezZTQWZtZE9IlBoaqqEJK3hBxNy8ljnaKI0OZL4CkNXxT4KCanxO11PFkK0CCTikdDnVKggnwR
# DATA 8rGYk4JITpnjcZaWpgYCWG6SdITo4MktRpyyhsx6noaY3TcUMWyyyoJwlmaZ3RElKzywD5gjrFxlpfWS08uOBRZuHD6FQy9rH4U6
# DATA UuepY/qANzqrLNEFP5cvuzpZ1sunjondSaMr6w/YM/FCVAFBG7lFgAFNIMeIIhYTDC5QIBqdgJIKINYT4KpX83dNXOM8ZoflmvWb
# DATA CRXgoadZbKefIHVLnvCS+1BHXAZ3KieFTxDwkTbKtZvEfMBlFithZwJTNa8YCDk5JrEbidKoFAKOIqkAAqmOwAU4e4KPcmGuFNvb
# DATA oCrz0RE7Sdt2Kjl5CZ4SpByyYT/b0vkezOsiQzoohN1jr7LKzrazR3U0k91v+ET2HqnvJjLjKUaeqvO53DcHfQqwoCoCXKEiwkn7
# DATA 3lKqBCaQseBR0y6ewYrUEHYlFSWJ4CQCOaDOBy+AbY5TSRwpHkTFeIO5HMdB9kYuGgxyM9I8cviXV9CIoE75tUy+qkRi0lsBA95D
# DATA ow0sJ7TG2eK4VRPMZTjXKiZJjpwk3grwkUMIM6xKfFU8HGQjudEeN/OMwnCqNAF5XAuzIMxolL00xyWksxcq9UuVvEjx3JDitjZx
# DATA 8yETSQLDnA6AswA8vYaUGS+qshFBBqJrOuZLyWa0cKrvyoNMwk3XoUccWHguSTlkOapEBIwZYRyJDoUkSmnQfiWVwlsU7s/8RoeY
# DATA Z6ObH/sZ6pPo6D/VxyjJNJndaEFlDqpYLmAOX+m0D7DQCD1A7dq1n2mF3+TbzZQPcCle6Um8UkU0Gc0c4kLdImBDOpkzxGEFt7jO
# DATA 8AJ60DaVI2Fhxa6SiTZaDWVCJ+bkKD8rMmHIZtPwD/D86Ow18UvPwsYtHUHLLC+fdqowAIEuYcLgRxVYAFlMOYvGTgoSf7iwyh9B
# DATA 9V+CMX/g4Hc6szCubW0FJA8QVzBBbsRIwwAGElEuY2wGJglOhzP0xIwgd/0YaAif8shV05TNQ9HnCBcZjze0KQiDwuOJkypmIKfs
# DATA ABv0YO4ZBN+52Q3IYzNnen5ZnQrNLRXwxArvJK5IQx4DPEqwGIvYJTAsbTunRqLGQPl8po1IPU6CKexTH4oFxSal/GuPhVPhhCWr
# DATA nflTLhUrn2FBkhYdCaCRIUdaE4e4p1MZSSnBGcueQltfRVx01qhxbSuR6KaxRZTHJiaKkskJp4izjRLINi9Kt7HE6srMrYBNO6Ui
# DATA gs64PBHDakU+MupjOiOFGsVS/ScNn6c79K0OSR8oKkLARzGcfF5bYbPkdpFIMGToztwKVdunPq1qVW68mlK2CqBGO4uyr7MFbLEb
# DATA SVhZBb/xJxCwrJqmBW6XVbo8zdYjlZpkuk4n0ylZ9tGbKqVQAAII/+IAWCJbt7YBbwZ5nQw9ISaM1oVET95S0MFRbkUr311KQLL2
# DATA TprfTVWlBEmqtYRUzcFQK9lH6Um6NAZyuLlSmY3a/sxjax3J0440yGTF4gdRANBu1sicSCbsNzBZEHRuSp9xMPWBcmsmx41pfBRr
# DATA Gai+moKWU9vQfkWFEuYBjMk66cDGuB7Nk9G4WtpNmohFSHlh7nmguYAf2+WV7BIeaqfbMX5iIXOrzsjy0Z2Y/SDofgrg2fTaYVcN
# DATA dFB8YaVEkaqNGX1cBoyM5EKVbi5668zTpdo4rmm5kvMKm09+HPICsKFa8bTSyEFa8dyS0wsMi1Gh3uecAQKbfZhMXBS6B1HMeVWk
# DATA 14CPuFdNjpF07knnWLiItjVunKHECrmtQQcwISpOYOkk5PnFMmV8qLVb9yPSUoZzWQc6QSDk+RKs0JRw7hyZeRIKPQuF1oyWJqTe
# DATA oHkkcWbNxHt8JlLRKWFtYJjMMP8jGcfacDACTTgMdL2SXtSZT9YwK8bm8vLgmlT5cCEhP9Orxm7Lxq4n+RIAzlSbuAwUut8MX8Bn
# DATA S7vLdbZox5vZj4gvvb3QOSt1IlBjIgtKI0KlQegBaJo4l+V9zHLWhob6Ip+ZHjuSVIa5vdDW+letI1r+X4CuRBZkqutWYOUgp1yh
# DATA ivwbDdDJxUX9xfO2auSdm9IxG8xrFFVTAntf8NkrJ8Vf5Q7aYYsg5BIOuTNRIBg57UMBiZYBnkazk0SsM3q7kxC4ZcAJybp+x3LK
# DATA HXnaSR2W+ECgQk8Ak8qOfyQQ7VlgCTxYRIhYu6YMZdwHGkfW8WJUJiiK6ZTBsdNskT/zXnQTbYvkBmdP5w4LxnJOmC0+LgBj7Xph
# DATA 4nKqrGAR3Npd6DDTNV/4iBwjeekYJBOb6BEipgwOlnY8l7+hZFfUineVtJMGojg/T2+BlrFgKBCZSi2BV6hEkuY3K84FudEOR54q
# DATA 7pRZquyyjaiNhqocFa1q/YB9wbIiXHiExswWHCIgXctBqrsP0CUsRVQwZKCO6PDZwYQwNrhzT+NY+qKpcrU78dfQx4bmkYnKrLFm
# DATA b8dpdCSIR+HDhFx2yS4LxeqWiaziRhmRjRVzvikYg6oN5XexorHcxzieXTHN2DWniKut2qicFc0ZvCoPauIvz05Sujl0Q4gGQWHP
# DATA FVmvtcA24+CcD0xN1Q0wWwY3p+HiKpeeYyAc/r4r4SG2OKKTfuw4ocAjWAvAmiM2BBajyCNPmVGvMFSZpAtKvWcNC1Tl0QLhktN0
# DATA +bMCK8Nn9hQ0sa6ACRUYL/+cktjnuWqjcjhNi/d4OMQEp5ySLPY0cpwCQylT0TA5DqfjkbkD4yjk6VT2KrXZKVggpp9nj292K9YD
# DATA nqV3wUjiV6mVnsZnjQws3qMH141eoWeMNRBwd2NKF1Orm0BL4Z51Pq7Hq0/Zm/SdgjF48HGBbhAMal0pU92z1HJpbBh1ZCIUVZZG
# DATA wFI4i6VqMgWp6nEw4o2ImJlpz5VdmgzHMWlIdHai0aj5JzR2poqeTdhDmM7WVBJMTkHE3aS9rZQHX3QQxhXMVmk0p3qJegwj0aEr
# DATA Fjae7LRFZirjmeR/lTAgYMI+tKHW5d/k1ITTzpRmsREusSPka87PHgibOLKqQ4xs57LuuGrSh0YYx8KClaLWwLqg6GSlXv1aVfIB
# DATA y7dRoM5aa1KuQXWboGqrjyt7y0nFwzxZkOOPz/BKsCqPkqqHXhdR/1SkmKe6EiQKB1EZqpxqpHZ90aHTgrF5L3u225QmZIqLVGUZ
# DATA 09GaKTtm0hyUk9STJcrUqWw6YEXFdxBp7JLLqIlOJXXcARQEcGTmPh9CNDBbSldAngt9LB6r7s1GEdZ30txmnSu4OIa1xfBdElxB
# DATA gahQeFxqgfKjcCVlg3NGOO1u3tqmCAlXS3hADeHRZdqryALdVOqUIuZIM+ugOtFKRJFvac2dIrOHyZ1ygXjQNBbfE4fCkzn71uQM
# DATA FQbqUzFUuMApZQJRiQeyYimUWdaFzyaq5yXNl2qlm3d4vJt4EvDhQypTvhCPPbewKx9WkMmk/hqt8pqkbuccI5xowBqFLs8o9cE5
# DATA 03vFbJfmpQjDPmpN/S5nG+XUVSzsATDTebcR69uTJUD5RNbK9FBbRVClC9y0XXLne7pCNtWGxtxFdXI3evQIjs4TDzxTslcPkjse
# DATA oAUzRfzd4r7sSPDmOsSJjk8r/VQdhloxV5gDehRTk5hskkUxSHfFRkaMdSrZHqHUEEGRVeabTne45MDGcJLZvhZdQavc0iNUbV7k
# DATA PYEXLYf1KaQfCZ3QlhjZJpK2f0xqPVbd+3GeWFT5PO1/keiILhcjlUVRJChTP0davlTmsJKGvSXXtRTcZJ1LeVYYMD4kV3SO0HPf
# DATA ZLmjjVM79SLBo4sgYDiJmjUVFbj0pANzxkz8K6i7MjmMkvgmNkkRtOewAPUsWwScGMVqMkxyEjslOlGojtzUNgxA8TIzX7NOq9um
# DATA MFlqmMW5ULYVtBCbt7pkJNNRa4r+FfEgUgfs/Nw4E1O1qKSLVst0sRuVb6thU6LC04EKnKuqOWdbRku286SARigBn8FHaeC4qJmQ
# DATA xbmDxaLMWRB3CFb3yNFN8WR9/J5U1N08WmCgNayLMUtImKSzOzoBWlSojaNvXHIO5mZl8nBmdlXXIcny5grr0pkpMWUqArBGYAyb
# DATA XKqQ1llMOpCbErra6rAqHZkSr3mDWDw2pLIaoxdFkiFOHdqzkholwudJDGmAeqMkcpojf+QPU/cuMIAmAYQE4DS4G1POUWrCBTKC
# DATA UzdBSqYoH6qUqrvjxHhhKblKcfZ4+b5ZJ6uqItqaTRvnKnMR5Y9b2hvKuVql4z42+eSZPVXIXOYJ7qk1h53pRFZJpSlzHlsSyw0Q
# DATA Yp2nmaoNXGHBgUEGgIOO/3Gi5SQqGlpvUMkzz0TpUMeRM8UPKeZasH0lUIKwxeQRiLgqgRCoYWqePmTp4gTr2gvdVo1fvbnpvwxm
# DATA sFrNer3H2T7XurSp5dzT5ySosNlsoWN3YjxbyTNkDmMaYkL1AcWYNDddDLVLxqlmLekjwNe0YjyI3fxF7Vi345dqmlRqqdGs+Uep
# DATA f7YA7YIawlofU2Wxkv+Cr/lgrS1Xd46dEZFUzPLLyh6ksmoLqljCoQpLZzSAVlQ2GaYwREmoU+LVEEXBtDtVaQ2QiEIWx9U+oNXv
# DATA 6jACenxsFuMK9iyVA/zqAFeWjBejeTCJuVAOZ8wtVYpyHACqnIc6l4U+CZq6eU3EypLn3Xb0CIDA3QMq2JF3CiluiKglR52Jcqvz
# DATA axRFJw0XLHgs+6EsN1J89EFGredYuxXeAtYytkS9l0uIlPMhcjUT+/w02gYpaX2pc3mCgyVtclMoYTjD7cs5kipjzD20ZWrsNFo1
# DATA vOMrhfkdiY59YCqNP8Nca6N1rr5G5dvm6AneTRqip5FC1LF0YoTTGKyq4Wzd6pt0PF1Ow6p+P6MJjsxZ1OVi6ZT9R0PKSJ4+k0m2
# DATA mlV+vUInOughX+RlxW9WFdPUAkzNg5U75el2rh0pPGb6+DFpY0GRuqcLWetD8AHIKF2+S06VBrqohT7FLdcXSaGWQmCYEdt1bFef
# DATA e5foq32wXV+84VkXb6y4IkUlFFnXEUWO5s0ZH8rjoH0N35YgtaGTL0gzeS3SEsuULMXIlKbk3MMhecyF94ysuuGHzxiy2eCZoiim
# DATA DK5d/SJ3k4UcmSrOUafsD/v8hlP+g3LC9LnK5YItKvHazFUfuqCiBbp4C2nodO7Xzp1Se+oJKECe1EaeBCsEL3/pXHTlONxwrihP
# DATA gdyk0MELsOQiOSsWmLJrM+lLLuuybrYRP95T7l5ido6xQUQZ/KWajoACuzuPEID+A6lSiIWjpsks0cexJX3VXFKEmEVgOasUX4jw
# DATA 2BBeY+XJDS00BNAsaBpj0dlAvs0mOmSpKAzQw2VgSTdFuljA/JE8VIvJAqsp6nRBT58jkPRfZWzofHF+wT2yV4wwL4ewNdn9eODF
# DATA +NNZaxLVa272G0HD2fPEniwf4oorg8Slo5LxFKCeBnSmKtM5EPjOhUvzPA15hoaWkyq1ZcjourPuVuLhlUHxKDmZDMTwOlUhMNUX
# DATA uTk1mF4RmBapsy5pg7m0mEA7b+74Pj54Eqm77oYLLNbk5e+Se3wvYE9ybKOqi6m8uStl4rpzEwjdcL1BmZ1GZEWClJrFeKHe1RvK
# DATA w2TUl0NaWqXg65kgYq/EP2fn3FJNKMne9uwzH1apdhCo9huWeppT0vGUuiTEpwU5U6SPyt10SvrTpNRFk0TioDM75Insr1PThwOY
# DATA pL6S4wHI9L7YP933D878o2P/q93T092j86/9F8enPjzwT06PPz/dfVn1z4/p+/5PzvePzv2T/dOXB+fn+8/9z772dk9ODg/2dj87
# DATA 3PcPd7/Ce6F+srd/cu5/9cX+kX+M3X91cLbvn53v4gsHR/5XpwfnB0efU4d7xydfnx58/sW598Xx4fP9U7p+awNGpxf9k93T84P9
# DATA M4Tjy4Pn+zZM/truGYC95n91cP7F8atzDbx3/AI6+dr/8cHR86q/f0Ad7f/k5HT/7AwAgL4PXgLE+/Dw4Gjv8NVzgKXqfwY9HB2f
# DATA +4cHMDNodn5cRdSotqp3BAb6f7l/uvcFfN397ODwAPCFd4a9ODg/giEId7sM+d6rw91T7+TV6cnx2T4KU0QhdAIIPz04+7EPMxDE
# DATA /umrXd0RYBf6eLl7tLePY1lz9mCZcLr+18evUFrAvA+fO0hBRO37z/df7O+dH3y5X8WWMMzZq5f7gu+zc+jU2z089I/29wDe3dOv
# DATA /bP90y8P9ggPp/snuweniKW949NT7OX4CEmoW+OjBzqgdqjy3ZFdHCH17H+JtPHq6BCxcLr/p69gnkghvksh2Pfu56f7hGSLHryv
# DATA DgAoXDlNFD4TRZVegQeGKL4G8jr2Xx4/P3iBSyJEs3d89OX+12eejRHAsSHX3c+OESmfASAHBA9AgBjCNXu++3L38/0ziypwTE8u
# DATA Pa76Zyf7ewf4AZ4DLcLiHzKajs5grris8IN04u/C+mIPSJi8ht4r2ARIfEeKaGBs/M0GtmzGXiZI//D4DKnPe757vusTxPD3s31s
# DATA fbp/BIii/bW7t/fqFPYatsA3AJqzV7D7Do54NXC+tL0PTp97aoMRzb7YPTh8dZonOhz5GFCIXRLxWSvBLc4qVQ8X3z94AUPtfSHL
# DATA 5jvb+Gv/C1iKz/ah2e7zLw9oK8o4AOSB4ARmRz0IHpHyejU2IPHyD019Z0tHlIzUihxWp09CYbORQ8LmyIYu3MJ52uKEGMSi/YxS
# DATA LGjBh5e4qrLkxgvn5QNynGDuoXIY37IVtCBzj4wb1o6lp+BWHR7COqWjlM/84uGmN3QbROah33SQpSOskkBFo1n5QJU7uUlGFuwF
# DATA fjnH7FXJyM6ZMHMYxUWEOdae5QqR6ZQIrOoAYt4tbAvkR8tZeIPiF3wt1S5hgDP/ztWpg69Rih2BOir9Zzr8KFcTyc2RU/sOBq6k
# DATA TTdOSXhNgLyiQ6sZiOJUgneLLHdIuCphtWzOxaQww/OawjE6U1hCqsncc6+kZSUnVveS88UY1rXL1u3TOjiZmbMI55JKWMWM+0B8
# DATA yUYvVafitF6vUkcPyCTKgiFODOHVb4/1xaJzOYJDGWfW6Qu+dAbjlaoG++jOI2VKnOFW8Ue33jL1RF1k1+QMIqVaFdEjG2ctNFdX
# DATA jtiIxSsPpyn5NthJpQoeDRe6qC3OZojaJuDkh4hIeleVy7PmXsroJJl0O5gl8RADb4GuHSWxldqPchfN/xCL+/3I939Ir6fqFOaP
# DATA 0MRLMtU9wWEv8La+ZdpZ1mTuO7cye8m8OPj8FE03yJ6uiFeVSbJk8Jt8m5lXdo8KV5YtlNryvM309E1b1xiIUoe0lNkJ2wdWjs11
# DATA pWgh/1fK1jP7fmLuRznJDbsZenl9CXC5Sl3yjbp0FsdPM37kDnu6Nx1NXZUVaFOuTm93Ey0f7dtz6r8ZLLIxBxSNWTGx/8Pr+Xya
# DATA bW9s3N7e1q4mi1o6u9pQmUAbP6IjfBkZAk4FGqz1wtyRgiR8LTkV7EeX8CydYEkvvOAkmGJSE8xN52dY9RjDwFy0yJDybccPuCk9
# DATA fafjnUEUl/J2r5tP5ko6sgzRpWP4Vm/OzlQV74u94DOb8qCPeKBCHUzleMeMudeJXdWqQnHgr6mrvMhlxufk4iDKNAwcYwQmfhN7
# DATA OgoW6QRxvoKHC8rfZZY3XMp7SoE5uulJm3IkeUnBUDthEM/nkvVkzuuqC5ieEQ3o4wctZVjqAGu+yNzXOaQjGglTMSAuvcPMEvFk
# DATA m5sS1P1+8axCWXVo+8HW5OvXKAKJ1aC4GprihkYXWjPpFNbV7taNIC90boNLn0j0zvWSrMngD2Jx6n1EN0ADJrxHd8P3/vDvf5J/
# DATA YIMc7O3XxtHvcYw6/Ou22/QX/uX/Ntqthvosv/ea7d73/Pp3gYAFKlcw5L/T9f++vzt3Lk/XR7E87zQeTwKMBckJbT7qzEVE2R06
# DATA Sudz4L2YzT2JR3IOLEI5Tdlu5AOnXm5Ju5xEUuOKeMl6q1ZfxzDmM3PWRWnJfGkulZxgFUau7JCbLWsUuPjJjMXVa105C0XVYiqp
# DATA ai9hiGatrr19ckoN++f3YWxUTUEZnNNlQKaP9HYClvne/hEqKp+BwoY52OkoPD3fU+o3oUSVuQ/vTEk+BTQH0QBmk9Py1fmLk8Nn
# DATA EgShrEiQ/IC4jYm6A/NqJq7kc0xCWeckFD0Kmm10k4S6moru8kFMq0UD2fNKzZ8B3fYVs74CzWExqAESN2ZqTTYGQfgaOq8+3AoW
# DATA EhN6H2s2ocKiBU1+cn54toHLtY7okFgMnu+hWzHJuYsl+Jls5NDNgyPZ767Tu+XNWr1WryhUKwKrgX2VGfqiRd3bt8ovOCTHNBCj
# DATA 6fLvZP/jvZSYQFULf5r92/D/Zr3T67n8v1FvNjt/4P/fxb+Nj/3TBZUEVMXNwarkFApiTWDvUS3ZY76AUtf/uA7AxM2w6C/6rkI8
# DATA 3kUHDIC1frzhldAvw+eySs8oIXnuDzN/R+nJ5RKyiu1hVqqox+HsbgraZ74J/2yavfVPZkk2DvZGXJ+Fv/n39osbYCpvgBpL/KgP
# DATA Vj0Wztv44yk13QjpTdNjNIB3y+WKv/Mj/63nwz9M7uVP+I9byQ3p0PSIIndlHvjTGvcqYedPa9z7pzUwb5J5uVQrVS7ql/6nn/r1
# DATA iv+jHb/nf2p1jf+CKJiC5bFNbrDyE+cgL61Pr0qVGkNyclUpuz0L8OI6PJtj2to2pQiDTVCLJzc19DB/tnu23391eojFMd5s+83q
# DATA A32cg6WRLuYv8dK+bNtv1PuwXcHQAPGYe9TiR05f91VYPTBr4nHAs4VRy6vAqdSyGK2+kwANsBoYUOUSv1uqIDpL7O4r+fcVM8q9
# DATA v03sn25if6Z/FofmhNyQhnjKsqYVbnkPdvYclAyDRDSrb+m1/dksnZVLz4VZyqm8kSqRi9UY8FpG2jp3vj2Pkurdu6+UkeaoQPLe
# DATA dRy+pk4lXznjIfy3997GBisnSmRxADzyz/700FTmA+OeCkwEnEtKR0Eox5kr5ejaJtCZCrGy2gIvpTPQn46p4B45MMGcx1rGCV6E
# DATA Q6WdeW+TQDT15Z9hX3g6JsL7a325UssfJ6KycKYVp0GDXS5X2+hCKTXZbWaYl+pN3FSM9FKz3uzWtxqNZr0F5NOPZ0E/GKFd39c5
# DATA lX0qJV/attZJYCGkZovxtl9qbNVbUTDYbAbD1rDZ6DZbzXq7tdnp1XutTr252R32eo3GZrjZDQebg1a02YjrYXOrE2xFQVzvDUqG
# DATA ptTJWdU7EPeFQ9aldhj1msNoGPeiuFOH14NOtBV3wzBoNDeb4WazuzkMg+4g6G312pthfQAQdVr1eKvXCqNO1Cu526QUDoNOpxd2
# DATA B4OtYdyOhuHWVjMKWlFvs9FoDBu9oLEVdRvRsIWTaQ43W61Orwmz2Rw2g2YQdKz+LvnjfdW7V+wu41vbd/BowiJGpvcnZ8dHtYzY
# DATA A1BvmX6v+uV+1b8hpji/m8ZYNsPf2dnxSwMky3kJ+NhNbZ4yVwHmuQ2N1RBIP/YAzMNrIXnvv4CHsJWvg2anC8yL672WGSoeu1Kp
# DATA RclVnMGOv47f4AZS5ZnVvXtxdBiDFpgpWKfBHAe8uKyqADpQ1H1FSCQZ+tzQ/6M/0pNh2HBCXE23hA8/2p2BjlpLMvor0NAD6YBK
# DATA WkxC7AF4gTz7bIH+IniLP6hJOASKQF3kEI1QVy4B1GtCicBRMXwLPTplRikWL8W0YGpTw5LcephCnFxAE8DGRa1Ww2GqPn9nQDTD
# DATA i0dZ/CTgeCx+Tbgpv/bMu7dWZwSqgcKawb2D8o8Q5TxMyf/Lv/Q/op9rFOHIvgJVv1x6A9u+sV2CqclQ1IQHZ2wM7rB8zo4vmEdz
# DATA oSz9oCFU7oIZUEJG3W0rfBo07uTocRyEmh6rjnjcPTnpn+3vne6fazol4NahG5zA+k2jpGnVGSdMpujYzw31PObfk5tyKYizdRhx
# DATA /Socl2h1qjyrGlg2AVEfCNZGs6K6pRdBJs53wWo5D67KudaNZtVvblbcNRL8YPpXMC9fSCcylVwH+HJVjUPFisqVy4rZ4qXFfLiJ
# DATA 2Lz3guxuEuqa6X42CabZdTovK1apFp9xQTsbVwssN4zoDGo/+ItFPLs7DW5fTTDsVV472z/c3zvnln0K6rw4PX5peyr7LPtr0tlX
# DATA lNXC7fnJjlII1pyF4CKJOyTEz0CH4Pdr42BanhNvq5lBFfKsbTfFu8yBdi8uSkE0TiawVEQBff6GO6ykjdI+rA7m0GW6VcGjy0ub
# DATA MeD2IBBrsM3KOBpoi8RVcr82LisVSx8x+kO5BJAOR3KJMcawwztBuVE9DD7QYWDkLf4jNzvItFISIdywkLN5f7Hgb/gQIcHP81n6
# DATA 02DSVyWV8acbDD3rxvBRP7w0MohQhQMUdape6CObwR9m6Si238bZJVd92JZULg4UxwWeUV7GrDzhGdskYEkE++dkMsBIHGwlmz6W
# DATA SeAiDCYYp6E7QpJ4FGWXFieO8VwzMF3Cq8Pz+W1ZkB1f98JCh+kHhKhNTiBE+WvJ/8S88CzXpZLfhkJ0U9CMrYG2rSYMBz4XiBhd
# DATA zxxK/Ii6hknQtxzERCelVURIiXFYO5FbPdOZw8+E/Az85nTMAyyhJCwhxIsaJw/zBG5TyBR+0KBsBbPHd37Q9I9PMXvlMwxTRsjn
# DATA +tM0o/Q9IkjmIlV+p5JHvhprR+uFn9YMhVx+qoEB0cbUgp/0lInxhKQT1aypVYDh4rVh/Ogj2CrEoqN+MEeYWHrQt8uaKlJQDisV
# DATA d/lk6Bqm80tPZmD6McAfA3tkWlvo6bF11UqGYADtC4dKlzCVRLi+7vjLMxfaQs6AxMmfcB/An3yPGQVNY+wX9Rq1ZS+wXiF8l+lf
# DATA Vi7zL8LEHpQ//0GI7Qdv1RBmnUprpU/CT+C/ldpPU9BuStVS5Z5Jce0Hb4lI7tf+w9LsxYRCpqPYxmd3B5HFhXJsBpEPbAVBreQ8
# DATA BAWbMccVS/lX9I52FVrovcavfloT/gejoRZmnugHNbD6rkAJXEEZMjZV85mkip1mtv5aME1pJlPND1k0DT0VaQQC+wpBtvg3cTjr
# DATA 8aPUjEHeBUeoYw0SvFgEPI1vjRVEkTPW8hv33upvFipkI6F2USRbHWlasTY4pWiltxX8zwX/hHo6K9/WbznImCIvRJvDdkl0aTT8
# DATA Zcqnri4ruW4MLRd1JVIRFfJ9JRmXOr4IC3xMLn0XKE6oFDFI1ASlF/rS0OWTt4AEcmcQZyL3ecvMcHDcocJJqtrJyZPetiZ/77Le
# DATA QmFQcdQIUvHZVihSIFQP1vs1Hr5SxA9kNdGqI5OKOy7aP0JslLeG/Eevhy1yiredeD5H0QuWZEbo2VAyUmDmCAwi4PLZ6k2sO9PG
# DATA HZ7LLX5BGuQQZXpgmVK+YAOX7L9LclgYS9OiVg0d/AffuCzauQW/0cZj7D3OEUVGYlBFozwvKeFzaZt/km5FsPil/Ga7z1HsfbEB
# DATA nrPHMERbtg1wZdMGs6ubiybvH4A2BrPh6npeWtZax7Zr7lEdTbcmiQ42pHjKcN9MKBOujyU/uJJVHwOO8F1EaJ8d2n0z4lppWZga
# DATA 1yQ6eQrlZ4JXEWJ5Kt1R0bbBVjUXkIpRVb1l4mcdhXqvufN8ttT5Rxt/fhGs/2x3/c/q61v9y09+sFHDZFUy8FjKUjcWUlZREh5e
# DATA xAyrueVfzcsmM+IQhrt8223fqwFpGLUKldWD8I0txoMbGgcqUCeBXYQT8baZEIUEJQzqN9T7SOvm91r2F6NSUY/KnzPMavEbWOzs
# DATA DAiaXVDA4+FXLNvzArQN6/e8AWPZXEPoirr8dMl9AT1RTfPyxjezbyYbV7DpvllCrWKZ4vBVvQEoF/ShCkPg/6zOpKsZdnbJoo5L
# DATA YD3R/ymtc55PnOXFZcG6a9iMOZBf9FWSACvxTIyoBkFyfDspF7nlq0wCMO2ipxf48LJwGTSYPBZSfgHA9LCW893zPuFHS573D5ms
# DATA G7+x6X4xYbDsGyM0iRrS9z8p7JM89M98xAcaQ86OcaBC0n+mwyRuw7JGx0XjEmdcIlVa1NMlMbCsRpJCpxelNl0ATRXs1/sCjYfZ
# DATA ufbZ5WxIq1Ml7JT0yOZRupjXsDA+8P4vkXfQ4WqLOy+zkownbHVrhB1iyN18xUPpqJsWWXSvVxyZl8WVvVLYqek6sq5wNAlE5LGU
# DATA A/ax8TgQWCBZdR3WHQ67TINZFpfzHK6OXjLiVxZyciBpZ+tj6DvRagk5Z6pyoSe5nDBNHAOIfFU02ZKUGqO0bp0MsDR13ls5UaKv
# DATA smM/MSsiNQqrlmOKb6KuSahIR3GNfpIHVmTFCo5+6pvVJ5KSUCtTFb1ZG2OG61WMToMVbSUsqyOqxq9ftUiWafROHRvWPlVxGWOJ
# DATA FivNAavRYFmaGjq7dNDgTTLfw1SuHb/xDLTJmhT9l+wC1KEwY5fj6WVc3H/7/J8YE5IxdtwfBXdINtO77zb/p93sNDq5/J9mo976
# DATA Q/7Pd5L/+dHGIpttDJLJRjy58ad38+t00vLW1tZe8o10PpejNXTCJ/Ezy6AhhVAdFCGjBvfN8zR8jbWTYE/WoDtPlRGdXRHTU98x
# DATA mV19Hk7GyCvU159meIs2f04zLmmCY42SgSpKegJfVZOZ7jO7y9RHrLygPqNz0fPgIcVEQZsAfjhHZgtcsIw9lft95IH9PuqJdLU2
# DATA sC+AFjWzih4G7/wYS4UVOw/RGDG+ntt4HGDWJCWuZnEfmZPneVGMdXSn0zhSEWywajGX6rayray2JFMsUbUBKOWxZQUi6PgesEMO
# DATA /ILYLuOP0GOlsn2JXalgt69+p6tFrbgrrp1+iXR2EF3E5qnVapBGwDOXYbqQuaE+ZE2Nr0hHOy2RmO7l6p6xItVyz29Bdm37D3RP
# DATA XhZnjBp+y8oVx3bmafFCqLVBmsjK7JFcWhAdREJyrUVxPMUP0rqiY0bqDrREmeeSuMQ/Y2DwLUgFGh1AMtOTBhcl2INEgiV0RMk8
# DATA Cx7a0wb0mSdUQESAoAW8uHSs5Rt0bcVWKwaQf0b4Li4tsApWhxrK8pCo5F+4G4z0A+VwmsgkKm0vKa3c+qLE2Uj2LPNPrCk6MyDd
# DATA HOAvixOcoq1ZDKJ5npVysH/fPxNc0A32WOVLzhxyskXGBYExo4gYS/ZMMqujOBwFM6uMwyAepbe1JVeuygpxsMlekCVEPkzqhMuS
# DATA XkN6tF1ogfA2L+WpxPk5j7whlZdOF9OnYM6ZmEXG1MEqCv7XmN23nZkhanvTGZouhvgxwi5FMS4pA2wReYQ56rN+Op1L3+5EFB3b
# DATA zS4vVGcFBL+iYX6ijtdPWBfo3SCaQGlV80rISytipwydkQzGzkpTWu71ddBH+cNfLJIYDCLJVK0oVkwZfFG2zNQvbTBQNNdGaRAh
# DATA xywYDfCKRxNgpI+hMxCeDLDehlGZvbaST0x2CecKYlAL9+bOUTqJZVpDKYZPLeVEvLxm4BwFsEl5+vKQ12uPiF3IgH45pJYlEoNv
# DATA 722CcEHg4zDUmF+EqdZ4kjWRGjVpylzPfX0771QiL6Ox1pDhoEPzaSPU8KQg6FX9KJnhApYqy1EU/+Mn9iXxQw4eUmcqYbla3O/F
# DATA GIsec798YJNfk6O5Cyp2nsf8S/xdhMrlpY3nYCLZdUorYZ/eKrWEn4pe4rAnQmJuBwqJns8E2fL9BVhtSuajKd1XUrmMWllV32rK
# DATA icw7jc269BuBaU4HhXa4jtc4hT2Cqm8ZYZL21PL2ms7k5xv9UHdhcR9npzIEq/YobCICzt2rRFRUMxT1kg/dkMT+AIa8kgA/owYp
# DATA HRNV43cen4/NjEblUCgBKw3YO+t0MZmQB4ut6BWtvoiD0fza/gWbLHBHong6ost9StfU6k5WPCT6EqgK11se5snsWwBBKQkTNf5j
# DATA ww9mcfDa5Izj4mcjUBDLTWHcAZaF/RIpVtwle7tHx0cHe7uH/cPdr49fnfePjs/7p/u7z78uKUYpB577iwkWzSrP0nReNcffbL5p
# DATA sUiyw1AZAdtDXqpdjdJBWb+Ie2j941LFFYN8F1QNaziQ/VWGL3EWBtPYvImkPiutfxO9bbTv4c8nJU67rbGPWEavJVk/uxvjUe5y
# DATA hS/gnOsHwLj4xwekQOURpil4wdMeMDt/A9M8w9eLabYBVIDXnKyzF6MEjzR4+bfFpKuNXyNI4zSKd+ppD08y8INsB3kHCiQwb/rp
# DATA a/pacQhLOuJoRV4PMkCqdsjJKGpUVr+o6Mg6OrLQMK3hf9pgb17Hby62N63wNc0D4LJez5OJKHRCJ1QAxMaqLUvBFN8V+NgPLglh
# DATA qs403bxCN8eYQslUEwWMvRtLkSabnugbF4LXw1jNkminyG6HYdJyiX8m/TN/kK+kNRHzOp8qAMWVjiTha3gqZsXrluaytPMOjr7c
# DATA PTx43t87fnlyfLR/dC6jWd6NHfIplAle4KB0kzNoWKVLDZdpXEju7mMi+odAenV0tvtiv/98/+Tw+OuXK0Cy+syhGGuVRgGHzyiu
# DATA XcQJbJBgZQkmlAAF9kXZZQQl0Ry+qc3UYWDkAZv35/Df7v2fISf4pobCx+EHRYaLYhGS9uWX9oIoukMVpDaga/7W6f7O9ZvppFTU
# DATA gb5kconPcAUN/hX7K1cubW3W4GhJqcV94VnCgnrBpYd9CFs/S34W+z/yN/2P/Ua92VZ/bAybzh9c5cP9z3f3vga6O3px8Hn//PgY
# DATA WP/p5/sltVHUTsVYs1HqeRfoZ0lGALPMNr+LknOFd37MOD2OqPdSCwagYbzp2RBEWXFPfg3Iu1KbkagofcyrmRMR3IOD9pwQXkXY
# DATA p/ufH5ydn35tramBtYamEKgq4lMjBabMY1W4fcDnmzFvRSk+thvJdOXar+i0JEtBvEQUmmNfjMUxXprgOtsCuUk5qiZ1aXGwLH4h
# DATA 6nOhqc+AU7oY+xbpfZejwArwaQmzq3mK3/f3eAhzJ1UyEVToQM08TWv+LjPuiGs5YaWYbC4lTYKJ9KW8Q1UfvTKsrlcls5ov8EIf
# DATA AFc/ta54yuYpGqrat+GZfGxLdbVdm8w1K6S6CpjIpD+mJFZlhsGzSbpOBWGmeGVurH8DONcJEQuVjbu+ztm++JnJkoDQ1a7yiq/x
# DATA xlkOH2kTLcbTrKxfBfE+wTI4/SALk2SHrAN+lT1QfWWfvaXVk1MtsBWsr7gfVBm3snhMLb69YblPi3IijfcoJxwd0rpfAkolDThD
# DATA EVt1HWSawZLEvEomb8jwK1UqBSqj6d7Z+C5fXc2ElzxBT2Kly9tmmY+cHb863dtfxToNT9Hr/ckOhWpBrxLNKYj68/jNvAyPU9Rn
# DATA djC4ur4pPUzxgvQZpTpdzNPXsZSNpU/EYTCKF6HVMyuVShd//k22Vnp7/6x6+Ql8rVoDsyv2Y3IY8evQT+nT3PcL850ZNG1HGv0h
# DATA G3uF++PJ9jfCZvV/jp7aqrhpLY+tAxIg8sL2fGV5oCx3t95XD3q8vaJd8ASX9O/khb4UfUoQIFbHKocnz32JnJHoV7gtl4wUs1/x
# DATA ZPkyQ6jklDhrGPXaDu/MdKbLjbCvQ0yXrGDj5LweS56PJ6iL1mO1gzWkSglnKfSAfvaQdacbOSuxojOjLcrQZqs9MDyqcRJHrMnf
# DATA EEWTOSqKu72i5o1fBLnEBVYm/RSQSllDCFuitqE5Dv+iHVeVD1dHeZXFqrKY9UzsIDF6S5ZPwKJn/bZ82KA3Xa4+KzJfyvK7Mmst
# DATA dj+z7Zmn6n6f7e79+NVJ/2T3/ItSJQdegfW9wt6W9uE1tC1TU1ENtZmt51kusTW7zqpAoXHtvLwEhYjGhI8sXrwt0Um1bXthVfLe
# DATA tgoF1yhozL/ykuddqCUcQPVihCL+6v+RDwP3evcrdqK43WUkzulRMwcFHnSwBCuHKhvsraVgbhMNGv6Dihm7fLd5hvcVYfc3bDZc
# DATA qvIXLm/kbRzTpXcA28+SadnAV+WuVigAeQpbiTH/ox0e4UKh9/IpyoFoBVh98vP95/3nr04Pjj7v757ufXHwZV5FKPCj2F4itzHh
# DATA RJknhkuxh9//DDjKviptsIwsZlZYnhNYHPVUKRQoNHbBZntQtyIrvQh+NTeXpxLOmKlgxlK59O7/ff83737x/q/e/+27X/rv/vnd
# DATA b9799t2v3v2KP/76/X+EL//1/c/f/xW0+d/4wW/f/RK+/vLdr+HvX+Pf93/LCVhIXsoj5USpVL1GibCP4mCymPaNsZZ3aDrBnqW8
# DATA CvTrZL7O8kDrkPk06c2ZoVxX/XWdRQ5/pATmJRsYGYjyy9Usc2MVQX97C3hJsXa74nkVGscsUezZo5b29uOP2c61nGvbRd6x+5z1
# DATA TLik1TBK2uWDPgkeOo4nSzY51x1W5oxrRlgWzmJCehzm4LPZbbmnKfeQPW9mInjCpVDOFSpfmv35Oyavp8Cblze5lXNPv04KaTx5
# DATA mkP6MQ9sxUr1iCfkFdAjKWfuBE3dEdhJ+d1hkoIedYl+K+/nag+uOI5W7BUnrGBvGKaEHb/IreMtU4RZ6oqz1L4iqgLCeWieen4U
# DATA WDk4OjvfPTzcfy7AUVh9jjdgPeTsraopa2ge3xUwK+gclXfufvvbU8kHxH+WM8KgVwseMRkQszQl9I6NokLX9bcJAmFfJH7MbL/v
# DATA 77/B05XJnKobzSbBaEOqIRplhPNq6HKcZMSXurDM/fZIK0IADiDT1fEnXp0lDGAzo5tF8Y1CmfvrE5z5JsBnqb6Jk/5AVGhnPwgN
# DATA qnyCS2aNAqqjI1i98GMHGw+7oTne+PwAr/44Pv0aNkf/1dm+gbBoPLpbXKPs0YCGmfw5+ml4E+oRldNFMixAdoVWgNXydeOxu6cl
# DATA cFSelpyRRzCLucGdygNAV9/vPqR0BgzKtyYmg97bVKlQgLeQxpOyfCUOiN8NYDQmmrXLW7R0sbv+Z8H6z/AEmPnYr61fvq1XG83e
# DATA fakq+W4z7bRRCpI1wFOExsnp8Z/AEgLF4D0wZiUp337HL3AD82MK7RQnKEjWw+/NV+zkNKGuYuP0h6y+MHxFTqtHonas1eGlLBo1
# DATA fM+O2k0cRN3J5ZfyeFVbCnFzKflgpX0yo1vV8MJ1FV9y2GcmLAFlNVPmuqJMYHUl0e3yXeBZ7bsTvNeB+lkxwkVd26KY5IEDOk7n
# DATA KtO6QbJKvSXN5bGMkUvRHDjmkO/b7ZjW1HYMcSeyo8k3spwhUGL/AKUHkGPAzYpY7Srg9x/JFqgUmOkCiaU2SaRTGevWPln1plo9
# DATA 90X+9vCbWBzQeAXQqhKHACZ5Yz2fVL4LcWHxHVmMbYVRdHbwilBb+iROA3WahotceMUxjTwJLdtgAry9SVg2sqfUM9FjGe5C+dXw
# DATA 6GCAvsj+POVsd6Tdcs7nX6k+5HRR0bbn8TCge9fAZh/hNQK6mCH+MlOlUfEooTn2wA4Rug6lthRQURObxIv5LBj11QRVfxnP8oL0
# DATA z6m4I1fizQ4w/j4xsYqWyMWTo0ENR8UKQM/u+prjW1ShsPKEuPP278nklnRDf9ma1k0mgKa+aldwPsPmwkqymFc+2ikKEOTQUrxm
# DATA ZH/TopmAoXLKWc57KQMkVrtxe4iiDOusrBqLC8gxwXVj3Cw7+XICGTc6S1RJbsQvrTrmDloS1EZDTm10USAPXc+bAtba4aB+S5v8
# DATA I4ULJ7hhiwZNi9tLHj9fWWMSIy10UxYDrp2GiwlTn1EInH3yoMitsiJgU9ltv0hpEqlbWVoV9cKjqpJkdLt+F+LZeSfGUseLqdas
# DATA wETL9JfBIhlF/G264KxUqvisG1CmLlKGjOSMLlLkqaNHWo0LY1DumN4/GK6PZVTXn2syZd3cXwNF4WvLoVfuZ5lQpFJEWbe+UFbE
# DATA ZaEFcfGQ9XDpLWdPyeHVHUsP4jP4RadMJM9nJTD7kxuGBIOrwLmkvRrlweY2Si5KB1gfnH105m35sfgAS6EXny4wPO3TzYsH518r
# DATA j35BJhjwib4Eh30NeFmye44wWgOSTr4+j/FWY0nxkWR1m1+siJNbMXKOI/N4BcAg+fyuwDwWtX86NOzw0QB9tGPD99TFeH6892NY
# DATA iS+PD1+93H/Kgihl3NjYePD7TJFy8biWjSGzJ9PDJqyo5J5dUxKzap9OcqSrMjgKpYCoHqoXz13GD5P82p/DfdnnFbRqs3xHRbZR
# DATA KpAwj8Q7EjpxPr8rID2AWeZGUsokGat3ymZelaKgRrE40x1XLbwUL7sG4SOGoXitc4qLimvotwvTRVdIXgrCgUa0/cgkVsPvtmOY
# DATA qv6S9HWaydl4JaMdmf5wSJDSbm7yEtjRvvKCsVAr+HC1jOPYVH9g+6F6a/6D6kvRsuuXH9CbnEGKl9FW4qp+GY2UKpZkiSuOSle8
# DATA qR/RxLhPq8ull12tFK2mggR/paU+nOivW61QX38X5pWjVpeHLVnJTgqBu+u2fw+Kr9o8lh/jKXrnss6ptMgP1PQ+WOf87vTNohNm
# DATA Sw1NbN6op/mgUnEURDMidSbJe1LUyG4s0RLpyfPwpsE+yY9+n9SMfh/leL8vx7ipasOMDrVwBYfa7uxqgaGcE3pSjmItwnb6feAl
# DATA /X7FehODnv1AXikDIhE8LLQLis3OCbFruf0ksjxqK961z5CE1ykieefiKcdDLh/uljMV1k1+VUA19XZKVPCpj8UKlXt3RoWjpSP6
# DATA g12pJEeHwxNDucpqKhFCus/R6HKWBL3Eq8jv60Cct1oW6lIFJp78hH7sBJH/590v3v39u9+8/9/f/erdf8O8kF9gxsi7//7uN+/+
# DATA Kyd+SNnM5eMxIgzLRqGs+sdn8uHH8R19WvKsn93BhMf7b/AA6rv/791vYey/ev937/5RYPgHGPzX8PeX/vv/CB//G0HyDz7mo/jv
# DATA /gl++QdMUHn/f1CKym9q/rv/+/1fYQv69T8D7NDst/AT9QRff/3+b3Fe/z9lufwaZ/bMf/er93+NA7/77+//87t/ev9z6OtfKENG
# DATA Dfn+b2VATJ35T9TXr+DTz9//n+//5v1fv/+7GtDF/4T1X67j0ZRE/mSO18uShvgd3//YbTW7ufo/jV678Yf6P9/FPyxQtkaebEnH
# DATA W9v215rdXhhsNodRqzfcajdbrc1uMxq0m71WEAfRoLcVwffNsNsaBlHYbEdbre5Wu9GJoq1GFDcbW2uY/7hGTuM1dVHPmtynuGZu
# DATA 7lmjaorwAwzQ21Q5k2sGjnZvq9EbRkANwSAK6mE07LaiQVzf6gXdYbMBb22FnU5rqxMN6712b9CKe/W40Y0HQasLoHXW1O031K++
# DATA 6rQIhN5WqwCAbhw3glYQxOEg2hz0BptBtNmLo0G32dwKG93OoBFF7aDR6DYaDSxlFUTNditoD8N62N2MNiMXAPuuvSIYNju9TgEQ
# DATA cW/Qa7eDJoyy2RtsxcNO0O2GW0EzbrVDmHDUbnZag+FgGAXh5tZmPQq2ws3W1lbQHrTaja1BDoiCgl9FwDR6sAeLUBJtduqNuNsc
# DATA DGFRWr32oBt1426r0261h3jJUlQPhvUm4Ky11QBENIeAqzhqNFqtXjwMQxcaZj/9AV2xuQqSRqeQOrZaQBlb9VY7BnIMOp1Br96O
# DATA NhstQFOzGzTC5mZr2Gt2NwfdbhC1OjFgpt3sArX2eo2tMGq5kNA9d30RwisgaW91ilBS7zRaMPtmvbkZbG2GQStsBN243W10e7Ak
# DATA nWG8tdXuAn6agyaAGrbjQT0Ku/FWvQ3LBXRVAEi2AoKtbiGJRGFcDwfNrc4wHAZhazPohPXNLtBCb3NQr/e6g0YjHgzDDmzbej3Y
# DATA rG8CqYb1Xm8w6PW2OmFuo4CqDCDQcdFiKGCu3V4BGJ1m1AmHLaC84Vav044GwDdava12FDY2u53mMIw7W4PWJqxPD0g2aMQAbDes
# DATA R00g32anU8+DMfvZIJisoop2o90sgAFAGLYGg0HQ7UDX9S3A/rDZ7sHgjfqw3R5udsK4F/Tqva2t4XA42Aq2mlu9zfZmC1as3uw2
# DATA XRjo9r0haDm3YEevwka92agXQDKIGuEWLHNvsxNHnaCz1dva7G62Bpsw7GYIf4B8GyHQyGYw7MEGCuNWo94IIyBXkICdrQJIMrC6
# DATA VkHRKt6vA5j05mYASwb03wu7MOte3K0POq1mK96C31udzQGw0GZjAAgNNwNYtk6n3WmG7Qj2Vm8FFP0QmNkovVoBDVDaViGlNrqD
# DATA 4daw04nrQRQPAO+9zc0B8M2oFdaD7qC9FTc6HeAhg6gOpLoVb3Z77Xo36AwGjTCIGzkSIYW/L0mZyfxu1b5td4oYSLQVNYAxhA34
# DATA H+zPNmzNdtxpB8O42+nVOzEIswgoudGJe1EYRc3GZrzVrjc2W71mI96KcrAo07gYhM1ms1G0ZZrAGpqDrS3gVjFIkBjvfAO+HnQ3
# DATA 48bWVjTsDbpBO270otYQVqoOzH8rbPWA7W9t0pVwLgxcvbRP8nwVLhpFVAK7od0BNrYVhp1WDGQLrL1RjzcbQDytersdDjoh6ALN
# DATA bmdYj5v1zWFrMwa+3gp7eBNdnpfaZtcqYdeG1S1k6k0UsjEMHAbdVhg0W0Cz7SgAVtnrRvFWB/ZtF+R7u9sOtlog7LrA+eJmFMFL
# DATA YaOzGpC+ucdyBWqAKRSR7Fa9EdTjYHOzEQza7UZzE7htI+o04IetziBsAEaARAebwF8aoDeFw3o37IIK0gT+jlT8AEhRiib2Kl4P
# DATA W7RoB7W36h1ARzwIgX67EYjhZiMYtoCRhLCJu4C2rW69C9CBpO42gPEh1HG70WvWYR89sFSmgOEqntvc3GoXgRSA3GmCGj8Me23Y
# DATA Ju0ObI92F+86BNyBfAYeFGzBggEVgyrVa7aCYQAyBOYQ9Brdh0CaPiAMW51GvWhfbwJdtlutEFh90GnXYT3qnSFIuhbuZdAlohiV
# DATA gLgFOixoDK0WqEmDemczBC0F3mo2XHDmo5XCuL3ZLWIrja0eEAXIW5Ctg0azA2QThmEL0ABiqVcPh5ugQQKBDNtRMw5g80fQEvZ8
# DATA OOjWe60cvSyGt/2rRTCLVnFaIIciNW0I8hXV904ImyhoDGF+EWiy3UbYAEVpOIS12oyAl8RN0NxB7AAL6gDGGrCvOvW8TsJOonVY
# DATA i9U6QQc08CLlaCsMBq2oA2OFQCZRI+gAx2gOO82tAJhHqxsAVpoDIJw6KAYtoOAYVLVe1AAhCSulGJwnwKzxzU5IjPT1hi/eJSqs
# DATA NWtETPfe9/7w74Psf6OA/xvc/90F7Sxv/4Mq8gf7/9+2/u9nWCsimPjq0MVMEt6k/C+WDkrG4wVpHFU/HQ6pRhrTkx+meI/gQ3V/
# DATA +XpO9S2ezSap+nL1s2SqPuNFN6NkoL4m6e9eHPh6MU9Guj5wMEM/hf4aj6f2dy4ZjPkJp7t753jrRZHDrOS9OD4+3z/F5IzSN5Pv
# DATA +6f7L492916dnfe/2D882T8963/Z+Aaa7R89pzbf9+FTf1Wr3aO9L45P6UZzctXiCbHZYK386bjy59yy/9mro+eH+/2zL3aBze6U
# DATA 7FtASj9Yq3gvDg73zzAdpZTf4CXO8xRVFb/Zbom807zoN0dNsC8vLhmLDd/RhizdHjlSn3KyRLe0bG/lwrctL2egnJ67BOHUGnm1
# DATA Drj0VKtjhJYCRwn+7ljHNCFLQvOdlktGiZ6QGHDOd8uUwt/FT4YftceqVPFe7v6kf7r7FZaW77pFNOgRLjg8a+Ye5U6WRWVcbFXX
# DATA ECtzR3EIcJSdihgSGaLn6oqTAV9uUiUC12Xq5LYSq1N5V7ZtTY74UgPMqFaX5cr7Ir37r2N12/K2t7IoXYlqTan/lD/dXrdOP+D3
# DATA i9r6pf1T5ePKpyUVI33wjIPcXyDMS6DSxZkwX7+PNyTE6joPSdTEsM+cro4sl9bVIRrKvRgmfERsvpjC5sUa4xhawQivlF7EekRJ
# DATA BujAeo5cOabc4DpFFe+h6gPq7KaBRpXurJV01846Mgx4J03CR8dm9it46y/iepCmo7LpFH61ZqJLZQOp0KYTdLJE2LEJjB+rVeQd
# DATA GmJKU5l5ZMX/kd94aDGe65v5ZDmGaTqPZ+aMkvBaLDoyccJs9LUq7X05Ty5TlcHzZQ+5bS2eRJy9A2z50RzjA3M7UxGEaqFIHCYT
# DATA eXixvY6nerD/SwYJnxeVUEawyvjQzipCkfF893zXL0kFRXtj4MO93b0v9n1bDtAGUd9bzXvaC9hvpfKUk/WvJvGbKd8b4szSl6uK
# DATA zHrgvFhk6Uo5TASUWfjgWr+UCxmNjiFjBZMQFAiXH/FyzvDy8GmZ2ZD/CfMjoU8FsUOj8nYOQouUKxd1WZLyYK20VrloXGq2SMWh
# DATA NLvTCS0PDAACBbopFtNrBG+9BNy528bPMFzV3lWmTnKgqqeMgzfJeDHeUUzecMhHC27mj5Yv4/8LxjaddsCKYZiTshgFM6rpYM74
# DATA W4fOkRp5gHQK614C4qv4QYbN4mBsxqIr8HbkZzqFUJaZQJ8Nh3ZIOABXkOdPgJdqnc3T1B9hpo1LJXlZp69b4DoZ5VlgXbKAw+MP
# DATA MHqr2etuPgVX0tHS+DJj65wb9qyPO8ciJnFPvC2xFUt3aIuwqWIVfxOGK+laHfd0XSm8eqHeunx0X72aZIvplLJR1Y5ScJcq//oS
# DATA lqFTM7n89rK2GCpHu1WjOcj6oCFZaNGF4261F+6Yse6U7LFKT9FTVXlK9huuLSnc+lQhl0RRRzvlG9LYw2Dm5QpbUaWK56bKKRWA
# DATA T+UspY0VIxFXz5wQXb+ENYafpnd/CRp+5S9F6fxL1ji/AZWzIkdHnyAOHewiUFQzZ0nWWljkYhUaiYgyUltkc+gdQM4l3gGP0wX2
# DATA YKrHfCjcKmfWhRuTk8rcMcOCOdmZnDucK7jq/g99pxHSgWLYHwgHFsozuyFbjN3hHR2QCUDV7UAKEyvhCXyMaWsVF8WtYMkirhQv
# DATA CWXA1qpSlkzKJjpy8C2u/jaLMDo9r6sz8WkdXeSMzpbLAZ63xWaPXDYmaY/LVXrsM0AOh9fb+F5ZGnJfXVmURJqEXblI2LfTi674
# DATA y1YLSQqsU+SqGcSfuUVeQaDmRfzqYT7gOlwQTw5D8KOUi6jhPig5IkZYzUc7WuBoTDx8nnlZ2+OLxVewHqfnZRakL7+0xTG15iMr
# DATA laV683L/JULu0ruF3KU2xZWiVpO8uppxjPeVAu6si05XEL++bm+JbIB9mfMcMvUHiMwUj9YvFSTfLnWAm8h6BTaB8kVVWWOpVO0N
# DATA ajWl0Sv54hhSCtHAsKL+mTnSLSuJe/Tjj2XmCoZtHON+efn1OUQXdOf4naRMc3o9LXbZohW11pV8e1UFrougitY/HsRRlNP6LaU6
# DATA ZzfKmfGc7ZivwPeAEVkF/RVsBNuiE2MYB43IwVfiey7R3LrobV8WGISOEUjbYLXJ5yhHahhRLuQrMv/uquKqq4WOwl2B9PlZIifx
# DATA 2VNbG3TbYhXJkFVNrla+LtkH6MCtfQ7/wePLtO/TwU93krT2Ga7zwXGZ+64UWg5AUjnDQbm+8oaDaO5PkHn77jSzJbGnVEA5s0yz
# DATA ENcwGzoFk8Dh+XTBTmm2zWaQZGAbWMaIYXIFqYqDQMXyY3mJDcoD0hVbj3G1c5gDiKu7/CJmOUcEd0oikrsvdDnwMzAbpdKvfrEm
# DATA pXu1l9E8UaKXsYc1RjZKZpyarjzyzTf5n5/mgcBrxpdIVPBYyp90QeFijXBpoTx+Q756mhk3qTBlqRs6bvvarNsRrWqaTsuKz1VW
# DATA cXf9msPm1VVNy8+1SjWJ4lmRTAkDEFJ2NbzHREq6mE8XdG7AEGblERrmdxTp3q6g3EIZICccHxMFea/WZJjyQSMC5jyYHcAv5WV9
# DATA DhsSvVX5I0KoPmLEwt9xtIWqD4Kg3YY/RcdyMLuflhzfr9oIcqWLxbc1p+PfysTI0CqbxVlWZrzhBiaVGysqEFQ7dV1RW4QGCwpd
# DATA tQ0X9TH77FHXHfXyoVYNveTn7DEB8xOORLHnkAqiYOOaTF25vrSLLf+miDgjpvBGXkblRQL0/Wab/otcu16/VN2w/UIP8AhUMLmK
# DATA 0TtuS7IqvuDWk7SkOXSkoMAgmtLTuH45R7nETqH29l5a5a3Wjmpl2plbFnTBCu2h3NCfauhA4AIbrL9UNDuh2J3YP87bpQINTpFJ
# DATA zoDR7hTUd3VPX+6fnh0cH6mBubJHjX2iT3H1Sa9SSIyjGeq3ArNCy8WcUWdZcx9kwrmY4LuDnmLEPYUV2m5i+6kiEbxZmyptqPNM
# DATA ThXQFQvsEA6RoSmr4qz6d40pcjgJYmT9nkomtr2rXZGYUGO8kduq07xbcnulqevWPNaFhgUfb0tLHWgmLrbetsPb7x8UQI7rq3J/
# DATA b228snXbA06ySu9giFHd64TsZzLfaepL3RXPk3LISy4Atf5PdPFb7gLds/b2WzYJn9q2DCDr2cOso+K8RnCqGyGptdoi7C8Q2dFn
# DATA tshSTPlsDK8S38IK/qTI2zI2VecaTU8wf+lGNi5zNCsbqKw73ijO/M2bep0jXabNijpATxSB5qSaujhJ98sm8ANXf4mmBPZxpyOn
# DATA +5SBa7oBxFnr7j1WGGfpBLhpXBTSWVl/8clouIonsbrsxsvdurrsc9AHqR90N6jyk66nQZ0B1Of+7MOABWcAuQTXCahY8eyGC21F
# DATA AWaERBbQNV8qxfmUOJLBLr2Tq26oHmauN0lSwh32zJccBrqCAeAFXReWakhFNOcmh8mQSK2gfFF+rcu2T/Dh+nGi760mhRhzjQLi
# DATA MFQOTCUhIWXiZwzLD5M3O6WaGHjrGAVJZjvWBqqspqzf0Zmja44bOEUeOUxI8e2nvKedOO222143NdX+1ZZ7sHRCmumz96qH4qId
# DATA QptCmmj3xPih8KZmelKjzDTlNHpL32r7+z85OIMtId9AhO+/PDn/+v6BEitLT77v707oriUr+I3XN00Xg1GSXdM2yFDWmz2g7he9
# DATA TrKC7qazNAQrBQ/jU/mQOWyZeAFMga/081VwSSV2YPEHSdMrmv3vwoweZkhAKeq4ewFv4noohPuiC6L/dVlVYX0MnLymw9UFEpxm
# DATA eTSZJ3J7hblH5SObk1i/K+TqN5GencoyZvs/GefiQ1HePSANZKGSaVdQCYaTI2uz8XwWW5vJ9jW4qsdKT4YQCW1453XHg2unKdEL
# DATA OlwPpmXl91J4IJ0qWrNLB6B1QPXUMEZQqmq965GCAfkaBg82Jiw9ubUEf5/cHGnqw+DhBVlu/khpA1XNQCOSqkUQAg1ZkrWl6w6I
# DATA Gj0qfpVxbr3rGPNLndgFD7hkgdJ6qamkCVkGmq56wPoqf7E0YgaJ1eLK44UwmDb/FzljkE+9/e7z/xuNTrO3lP/f6P4h//+7+Le2
# DATA tnYaY4UqP1tM6cKaOLIqI3MOt9SyDtApgAmhETQOUdkYLkb23bQPpPtTuv4HJOkvBqLP6F/u9Ef0uXre6f7J8dnB+fHpAWW684Ek
# DATA KQGD/oar63BWS9KNUTqfg0m/YS6w1WViln7KX9u0uo/lyjJOfwWP832PUtDAiqDKPyi4xYU74zI3D89VVcJZ/iU/DP0OPd97fOMi
# DATA IdXC5/V8Ps22NzauQBdZDNArroc7zU3i3pmsAfNJXTAc997By93Psf5g7hyE+JG2L+rrW8H6kJN/Kt7z/d3nhwdHmANPMVwVaJmm
# DATA WULVlPStCSb7r/THJedauaVosLnsWvKl/7hEwV9VCD3faibNtnUzBQbssGDUx5LcZd5SmE6ezinjYvmmF13Cx7rXiF5DcPl9K5yg
# DATA 07QxCoQPuWDkQcQ3NebjDgqvVvTBdEFqqNUj313AcD5yE45z42rZAuQUFuE8uMpMBdFPlp4/J2vaNPGW71G03nji9Qzp7IoCX+Za
# DATA iRp3IhdZWrWHb9F7egFTkGJtQ/e+QS72aNMS1aizWdCFXsSlgqzoa5fLG5wuHOWetyPPwNz5KFvR6rxyaS8oAJ4vtnx1RUXfZKSE
# DATA ndJ54K1Z0kEu3gzmnsX7nD+FZASaDmiWktWEI9GVwdas/GCUpUztZIFm4hKD35Mgi7NartfdmxTswSB7jT0/p+KD6LnhDvDsGb0H
# DATA Hfk/xQxl/j3CjuPR0O2seAUL58YJ9C4+5GkB9i4LimupCpbWxsHUejwJk4TzGoo5dDfjlc+Viu0ZG+nYn6Ks7RU3gBaufdGtnyvh
# DATA uTBfLt1oGr+kjvAQ2ssfoxJcJTHdZ1U4l9uHWi/f+tCqI5ya4Tq3kutf10lK18YpTBfjBGXrEhzV1Q93/HrekXvOpS2Vy4CYnmin
# DATA oGkEESXRgHIP2ntk7pIhx8eOpTXUZotJ+UIKWmKRPpzeZZVTwMSpGwbTOV4ALdPlHzFSoj4yKDtjUPdb9aoBvOJkoagRs3kErSkP
# DATA p/30RByhelgSWGN4hg6qOMr0nEfJOJm7uZlWhnl+bADJWkFeEreNrPoA+T7YRpw7qm7e4/u2+JJRJzQrzTgya6Zzl8SjiI9C4W0E
# DATA 8OY2v88xXxkLaxH2WWopkz6h8vVCeiVVZzHgwoq6kLmTIqWWmmXR0uVzV7N0QfcnqJnBEPaVf+pFfXe2jA2mI+Y95i+Qefu2RrR3
# DATA j4nFH1PnLjjOiuje3QsPy1bpRa7xKWV1X8fxVIDDyw+Amap9Q79Zukx+EyFmm/UlXDgoVsRpDWnZ1pLQmLlHFcjvbL3gxA0fyuTW
# DATA /TEDfDQ/4UTuI7CqqqsukJMk7CO0b4vNrxynfqqy43Y6tIZl9SW+7j3Sdho6Cuki1QgP6rE+NRYtv1SxLlDXnBwBwHXdfhTyKAe2
# DATA JkU1gKFJ3bvLmSndrui4YYEMWup9VLzbVKXTOXDOMLf3XIZnDUmH+dBmf4jF6Tw1MSZx7oN0MSFL0/FESgNH7y3Y2GZ4Swvmw8Z4
# DATA 3xwIwgdQypt5JT6VjrEjOUVDRx+uOjrh5IMVe+U3zu/qH+3oTb9dVJLzVMtMQREwHtw80fZq4cie2B2wm5H1x7OZ6+0dQLvXD4Yj
# DATA XTOggIs/egn6930t3obwPqJsHSMSbMtE8ShGm/YZ8BSfivBWFTucAhFS6qDUrnd1vaXVnY2pDq9emkpOZ+Ml/WTHbzwtSGnpEWf6
# DATA Y1HYUpaH1RSzJjLrMF2M+Po8dMKP7pRim8xXLQ73Nyzt4aICyG8F9nvbO6NNZSGGZ7p6MN2arhhsjlJKlW/jWv/gIry2SfQhBX1Z
# DATA 9mBck69i2lGW64r2yGqt8rysAFuvKxvyEV+2ktRuWVxxCau72ugLyez/9ZzDukjD73GMR+q/NHuNluv/rfc6vT/Uf/2u/L9fSlRV
# DATA 5wMK55CLvNjpKrY/KixgoTODe8jfm6vb8qD7t+qfgB12Aib3mxXeYMv3K/Va7PoTfNCZ1FY5y8Veh518GQorMZrvXSNN9+GDzJSY
# DATA dL2YvCbf2xx44igYD6Jg2zmiYFl7FayRkY/QMkRKEaT+3CNH/LygQoYKeXOoah5cAT/KwPZRyo9c3kzzMVEyK53d0vKpwYYqzMKX
# DATA gSwr+iNY3ML3NH9cZyfF6i6sbFa5WpOTDLkiAJ0gcB4L5fFzmOND6uS7//Lul1zbWxXy/gf489v3P3//1+/+WShz/d1v3v09XmH/
# DATA 7p+wELiu5CHwZ9ZBv9wV1HL5p32mzjyT86lPKDN//+gMqNa4zIBKj2MB8t88MgNKnCbt9G1wUaK07sttPyAiDZBAmTR4TvzZXCQU
# DATA yFLQFZx8k9BiigsMyoG5qs8SgpITPbEQt5weNE3Q8YY0c8H4cO8px1H4Z3JGCO4cHyYHbAk2fRqcLpRJJnYWdDqzW+KNDsncaig/
# DATA PHoW8N3/pfDK9dwJ6795/zdEUljJHT5h+ff3f0M14d//J3j8j1R+/p/hpX/hI4MFBfSFWCwQ6RgCWgLA3NSdskxAwTjqtpFwgtkY
# DATA Ptw/CvN/wcLzv0Eif/f3QDUIy2+4LD6WpQdKsQrTY737d/8MU/k5fP/blfASyQCEVRNZINgvcnBfFmeEyXVnQyuw9FaPcr/+Fjbx
# DATA /TrYI4s362+xw/sacO7a1c9KuXSsqXJhDB8IYlk9b79lKHXhv0s1GA9TWrJiTNiALs6jJVAnk6yHbEw453ufkmVpcyNYCFiGX737
# DATA l/d/V7CLf1GqFJ27WnHn+hPR8ccSDSvx1ez5E/FmevrCTXZgfOjUmNH+4t0/wpdfvv9rH//gByAzmN2DPOvpx15ciE0VALwtrbgC
# DATA gIoFruyEPqpI2AfPGrbU3/m0135NE+XbIfhnmPvP3/0L/N8vnrDWxIrpchfi3wQbp2QqWWMsSkz1pP1QEC19yzz9Ys3EL2ADbIj4
# DATA zDai/8He23bHkVxngvqMX5Gk5jgr2VUFgG8tFVnUoEl0NywS4ACgulsgXJOoSgAlFqpKlVUEIQjnyJa9Hh9rx57Z/TC758zO+ux+
# DATA 3XPktmS3JbV0zv4C8i/ML9m4LxFxIzIyqwCyW561NJ4mKjMy3uPeG/fluaPTIVD0ZTwSy4XDgJ/TzBxMRqfqStTRn3RmkwGTU+rC
# DATA e+aUiK9IOqFyevaBwOA8lwVkL0aIkSP+ggnxT17/o/r7P73+MlIz/EtMP/ILzAICO/E3r7+IPupPP54d+AHc5XpKMQaKcUVErkQi
# DATA OGCRPXqNCA4aTO3GjVtXOi+8GWAAP6nYJCwCaoFEh6uoNe1Oi2Kfk9AHSF7S8iW+CplxSeS3Mk6tFfwoMMr/hgzxF7xIlFOFc6BE
# DATA aqHojKgzE2Gtih5GVKsbSqG7uydFr33fiEqsqV3CmfbgN6fA5QMGCd9qBXloT8tC+zh2LTmBcMIbF1nDvrMe5zdu4EsnKoY7YqQS
# DATA zMCKgod5pwURLx5G9l0VJtYbw6Fr6Z0XPJLQBG7JlrtBNbAFWrQ4O1SN/mEKyBtjgKZxyq2oXmrxqdqCbkIXxTfOCAiFgSbPebHP
# DATA +UHNZ6OcyQVKA3Hl3vrbogij6Ks8Mw6tINlMFQcpDvYjpfz5qcAmw1HNcQdwpE4ekyN3LlQL6N0K1RSl0sCo/zP2+k/VQP4GxAcl
# DATA 3xVFT/Xoc0VWfop86AtvSkB8VV+9+UtxFOGhczVCemNgF/uHZx2Ok2WgMbln+oGrtRjVIigmOx+vNVShEN0TgvfnaiWJtCsiH5cF
# DATA LlMH40lLyY/vOMwerRfoczE7qZ1QrLvJzCrKfauMF5Tv4tefBwevxg1r9R9QrvhNBJm2gGSqB799/c9CbgAalTt2zgUD+lk0d3Qq
# DATA NREZX2SV4GjezzvpQT4azKbsjB43m+gehW8B6DIvieXXPLRmIAQwLEDgBGhQgcUFMHWhQSFS7Q41Xyx+/g63/8+i4MT+Mg6OS48g
# DATA X6hp4G2fAxOD/GPqKP0VZECj43SpxrFF0Fl7Me5gnyMnihA0QWx0El6eVhZn9NejSXGXFz7WsA1BP4TymVdEw6lojnCryzrm5Bp3
# DATA tHjudOmiHigHEEbfXUwV2mOSQ9ez/f1LHD4kMEZOAWr4C2AOr/8BDpqgoIbmfgk3GjyWWoQpvdAQg0PqWIYzIQZm02kX1lRWFFzX
# DATA knquvrx8n/lzNep/IAb75n9Sf38xZ6UtpJPoskTR0E6V4lbgqV91iJhUcwquou9q89f4v8Cywp1MLeufk2aGDu0VuA2OTcpQQu9p
# DATA Q5SJObrsk23KNf4X7L2Sh34zejhQElu/a42goMHO0YWO2mIme886Q/ScUkamZ/UwibqDweiUdID+xNX1VJrb/r7xSWXX1dX9C8eW
# DATA r/tuT6R5hBsOvRX4osAtL+DOhFkZ/wFP2z/B6So7elpQA0+IttPyUmFdzn0Rmtwp1hzhU0kJo9y828pZQsdDo5/qM3QRXtY8fZn1
# DATA aqTcd1f0+vXrD6FHuDbqnM/SAVL6Ht9T2Et+qG0b0+MUNBYc3UaOi5a6gvHE5QkGfIpzvVo8oqIsgMdfOymUQ73oYTBK0Y8rsF6s
# DATA VFF4/QepwrhPwbS/15bQSJVSh0bpwh/o52EFTiLg33pLJYPNRypP3T9iLlTQSKojt4CCqkxguQxAVCkrKvUPATORWHGwFbhSTLEe
# DATA e1qsuFEB8+QnjndbtLjfMUtNEcdK09bca91EJUEtPhiMDigRAl19SjxgiEEuCDvlzcRlGWd7HuN0ZZUCOBZXuhQWMGHTajHOsAZ+
# DATA cGlR7fcipvkCC93f/SEwM7B2SxMjT27NlYMol0MucxTnCCiXEE6+3gze5HvjRNFqzSOeFFRgklaRENscP7wY+ey7DK+dpkfVPkPG
# DATA ILpYfVbHHv8+cpG76raqktoPbrFhoapz0cLaN/SqadB1wC99T9rmwCYRGmdaJNf/gKog03bQL1mrecWSEf4fhA6bZ4V87NwrOCqm
# DATA U60wOIqfQr2gVA8nYyeHPoFIxGr9iur8HO38W24H7ZDrtqeV5f7EafVkYN5Cbp/+zOjTW2QunhoRP4TdZShSgff6dRMNKK2ZRXFy
# DATA kuwPmwczQG0pqT7PSuvRNzV/ZswVVk9MoepQPnsNYVOXgIbkHVoCKMLsFdvEE1XsKW0UQEXC75M53rvEjHbOcnWjWX+l7nerV/Q5
# DATA dLIZ/T78/5S4+P4tz/9vdeX2H/K/f23+f7uTdJjToVQXWsqBpRgZxP/kHOMA2oRsom6wNthb0SmQnEezKZVFXBFVBHzG00G+eOq3
# DATA 7mh89vZJ3fpHqvPm1zSdLh5JrlO9TQYgchPyjPsM3JjBMov94Wc4osiWQzVLHf6aDfFvN4UcHGTKyzJUjHIKgVVw2PEW3UFdmpK1
# DATA LBoMw8YoUq2HSinbxKi8bGdAevAPM7YBT2A4d1tkpv9E0QAdq6C4N6yOkiW7oLyKnhjyQDKvpYNWJ7IW9frp0XCkBOsu6TyU7Iyw
# DATA M9NRlB+PTs1GQSKHGwWl2Rn3hALIcMew7Vt9TJYnfFWPRmPanU5MIgM44hRSji95l9FJcFz1A33Ttu6fTco0ZF5Wosz5s7GIVgG8
# DATA Rf6UvUf+GQx5bqoTPTLKhjA3eU+xB/+3uiz8M2jYCg2hCRDcVFy3tmBaH51OSMMd2Zhltz9mmuCIIaJkp6DHuPl2va60j1n7KLhV
# DATA kD77S9/tQl3HXv/Oda6APhuoWHUDm3ZSBLCQXsN8IExePrnJbPK+DmzOmnUfrkc2toFxjsUEkWuG+hghzdNpc6ez8WTr0XqNkI6n
# DATA HXhnfWah4B9FKyPFFsuh6cGpjb9WpAVu3iO822bq1yI75n/HW+rP1TyqKyndO3+FPja/BR3S78C+DMuirqG/VjNbuJP/5s1Pyf4O
# DATA t+9/Ij9ENNj/+s1/jF0gyA7PNV9VebYdJ4sYHsUtux8BDpRiQVoRwT/HqFfln9GPYXpWVzFB40t11wK1Ls+GeoBXTIKb0E/Vbz8J
# DATA SLhfLatLVROad9UR6HOnUK4bTiEe3APInoFORbjKZuoJantrXD4Mhc1ZBWCPHI5Ara6JTs4kriA/YkOuApH3087jze+6+8noTk2R
# DATA 7fWPikXM20cb2xVvd7YeevWXalwXJ5Cw7ZAq/Rw23a/kliQbudiUYUfCiv4R9ZKP6FS9/z4ZOEoPzyUG9ndqv5Ny5+9xSL+M3vw5
# DATA ETVwya0ekDpO6P39j+y/qycCPlKUDu3NoED6FXjwqkfk8lYTDdxdUQKE18oXEeTvME4e6Xg8OOu41I7+gbgsvMg77FRfUrBIqyRv
# DATA CMoRI9AhjXKyNFD5PTrH+3V4vtXZfrS1+fgzdVbxl9pe6w93t7bNg82tD7ceP976hMFU5SWUz4cqdoinw7bpWBlrzpkXRx01kaZT
# DATA TCL265F+QtRh39nhRYKsLV6mIiZJoiIiSuE0U5eluV+QlyC6+vya3Q1gVwABZl8nIL1UXMgQjlstrmhYe1Ggd6FZhSknbD771g5X
# DATA TwAhOGBb5NHvz8dSEFdRVd4dKOnSaZljeMyVgv0VheYDBNpOvydB3AvRBUW9mthNZFikdMCkesl63AzX7cykjfaGNtIhunN5K8wY
# DATA GgzPrC2ty6jvIytCXUvrZJ6oKppQSiUbTeGCkptPCoPMAQ66xmMAANqAz4gj0QVHQY5VTm+ZCXu9Uh0OdUuMZKlQtXpVqFs9k5U7
# DATA i6nPnKc6XUCi+c+KQv49SoDoOqjbhs+1wFjcJYmU7+yNwx8jzrPtpJ1ptsNCNA1MTWEOTQgRlKBNNRtqrNdebChQ5kUgkTHF/FxE
# DATA nlNCGVKJL8kaESnGBDaEX5MDtTWbIFdB1/1/QAdD9CVE0RtjSYoic516WAdnWP4rBpRmkrvwyV4M+oIdfmjcUhlzuXOsroX6Fmfi
# DATA aYFUuFxHeGpzYTX3SUEGxnf4UN2zAfeC7930EVrRWsuUg4aeUNCR9qSHi497U1QVNKGLaH9U005drGiXv5mpWdBWavg9Vpfl09Gk
# DATA Z36rm8T8lftbG0/xp1J54pq6kHF8CSuqxIE/Iw94YhA/QY7wmwgXUgkiHLcEovqbv0ST0z+XX0ANyJhVWdRq0HeM1dPLVOfhwV6A
# DATA v344ywDpFf48nKRHJzaNigMuVLYUjFekcdJUAfZK0VgxGCDZyYYva6CS5eTdEqDmRXbGT03Voai0dKo6D5Fpk/hPat9pZa9gRfai
# DATA 59P995LvwD6woTaqRo6egdc32s0b/yaWZBTSZWeg5K5xrYQSBFJU84lHV+EFAdZBkgBTnkJGo04Lug80pG22oq7scJAe5W2sssKe
# DATA wPXDPzoTsk6EjNlV3is2wK8cqF31OU/4eDJ6dUbqb+qHc0jr0Yv+sNeOu2mvdxZbvYuZ29p37l8TaUWbjf3EnVyqjua39p1CWbZw
# DATA gq4RPJpQHmVZ09CQmp/AfTgaIlqa/nDJRcMCCWI2tMswDK0DD4+XwEz+hnQK073Sf6FjO9T8QCQccjG1eMvArFHo41F/6Pi860PH
# DATA OwQm5ST5k9rz/Aai30/QfPs8fy+p7f3JPbVXa/eSAnSk8Iag8XAyQ/xHnSVcAJo6enQTMffo71v7tONCFiQliiE3XBEOq0MJyOLn
# DATA Nsd9KJBiACQBfCoI76EIGEj2eMp0RyTgmw6iojh13BfVGbzNxecxRaJSJfCI/9Y1neuaitlw3OAqwPc4pCAr2RP6PuBwMkT+zhNK
# DATA VeB5O0c9Glblxnpjz98zHhZN3DTQQBI1/IcX3uUW51HjuWG29uLekdkFc0ebyDt1Puf5O2AqcLsEDvELFCB+CbICCglf4jXzF/Tk
# DATA c5Amfoe+Cp8rieJv1NPfINOZZBAjkREFuScvMXiRgUsMhWqgQsm8efPXcTkYnUm3CYA69UioZQpyGrEkoxi2SjgggG2rTzJHUj1m
# DATA CRMqN7mFCinLC/l9ispRZGVGH4fdk1Xuqbb2ET3VaLIKmcUwF7hOM49NYPOFBFTwV/n559iiE9J4eYpZo/d4//33yxtAIPYLuSKq
# DATA 9zqzZq+vI0DMejD1aMm5DqzaUnhWzD2RmZhuaPgSYcfAPo6CZN1m47CJ8GbsA4klSGqGDzmsF4FDq2TKIkSZqXOP/nJgXffsXkNt
# DATA r+0Q3AjwA6318GDFmKkQrhhOMnEwgt30ZBct+WiTCAo//cloiDdimlF1b5hSNu48IBGVhDnwPIGApz43E7+nBXhYEvQFE7oXTez4
# DATA MqNNQrJH/vTrF7FwK8ClRC1nYVmpLyCvQVdsVp59N8RlMSlPHG0A56Dus+4T2w1kbcBC+oRaud67Nge+/Ga0e5wpjptPI73r4DSl
# DATA s+nxaNJXp67/MuPAw2F2Cp26x+IsZRMiu9cYAFmno1Ex58ahNk/1h2VdQE3KpH+E+Ktt93jhgggtugnso3WvC7rme4EExg+MFzux
# DATA 11jdJ8BULQSXCdQkeBopWrWouxqUlB3njSCdEXcBW9O5aqZF63bhAhPa5S/fopL8ud3hb/ac8vvolA7V6kMKNgHsFRB0xg80D908
# DATA 6AJ9NOaDRCB7imH+QO36BgahWg0JP0YBkKEC+ZE6HF4wqa3EnqA6u7eLMwXNHcZ1Trale6kpDvh6wXHkSafB4J2eBwJjjNqOYRg7
# DATA lggnddffiI3JNSiqx8r+ZvGN2Lria7DBvpKFJuPRgL3B8JlagAbawWfsXugAc0rdi/aKD6Ae7nGCcK2WqEc3hK4FVOP9LhqfGR/F
# DATA fY+OuzuaTGKBfa9NJJ1F8isdwGmskt7uG5URouEZ9/4KKq6h3bQSU7syQXQyLpjQx8CnAk5At7OnPX4PRqNBTWLF8d806J0prYIh
# DATA HJxwS882bBUUapB4tyLdPH7WQjcOJc9kY/ijRttI2vJ0aLKx5rkf0Gt/n0+4Cy0zGDvgnEecXwhZAzoJxJAFaPhpsTo1daW9wdv6
# DATA Q18M9KQZ5P2FkwUygJVzFv6ESUKD226enQziYv9qFRVg2sfm9BUcBjJC47jRUdYvkRRyzlZ4OATGUbDWwnQavUEGLipFlb3WprnK
# DATA +zq4o3ROMsUr9QOwpqOMKn8DU+Hf/SGChMpH5KymOMUkO00HA3nLNEo8K72QJ1NNv7E5+c7GGJ4nqzKcAc4I8JAaZUJ1CvGtU6uC
# DATA r7UX11D/H+q+9SuwkL/5S7bz/NK5V5k7k2kLbmWot1OlQJXnYiuAcZ5uWBAH/9fWp8ROsyPqo0E00HXMVWU/MSp40JgCudWSC9Lu
# DATA wWjWOxykCNMYH3XhXCcL+sj8gtCLUJkJADkG9eq3aAv7+2j38U7JoNT+H016RhPNJp0FrEZWA6932sJTYr8wMwKQ8/k0S9EwAYJ+
# DATA Lx2oL99uBn5CDhagwv1TuHTDrdwfv/YeMV1y7QbQ5x317ol2Mzf9TML2MhokjH7BAS42Prj+f87q6i+rRvd5USX98zd/4Y8aVfZ4
# DATA 9sWJhp81QyfM0tIP/2IbmKOnlFDr9u1bzNNeTdKzYCOS+JBwKX/PaWqDCnNr37LNzVsLNGfamccXEIhz7k4AmV3ScR9bAOHFzlbd
# DATA jukCDUm35i/ffyNTwpu/jtaebtSdxQLYCcah+Hn0qaq54LpgkSfYdYEXMD9OJ6Q9nWOtZWeNkOUVCbEjzwSMZVArWQyxJlFK5HzF
# DATA aCmfofrltbgtSlsJ3FITHFjBxmwFMjuAFvqGkXwyGsBk1IzFyjFK2dET02K8KmuaWsDqbTwIg1O55PnKW9OZmABZ6bMJAoXvxWrs
# DATA eyv7l+tLoTU5y7BWj2iYxbp4JcluB8eDSyau16SaTJcZV8xJ1QAFcaMFcqdlr/jFvjMZ1Z0yPGX+GfwvFu8lrJSttNw2o9d/h1T1
# DATA L9HH5OdgHvwlFqdgOTKLa6si4AV+iZ/Sc+ZKP+eHvzIAOjQlnjylHqK+El7SMsV6FqwQ1jaz4QokhvM6PDkUaFecov8HY+v+TE4N
# DATA eWAhWo51SSQrqCBFB2n3xWws/BfoAblQ8IlrODCJczL60vecOFrnhgaPLJlE2qpA8daEEjr5OSJMq9YKIBVrSfElVlOnnqj/gpMj
# DATA bf+WlatL0qxfYJIvEJXMT7oMtdT1Vf0YHwPAakv9QZI7YuLRQLhb9CO5EAiuFdKvy76CIpZMhUCg5B3Lr32uXs2tPUcKR+hJCnyT
# DATA FNvWXqju807LQrjQXrdzqugfhsZwre3V7QV/4dUMXn7Icxh7ZoFineKC7FZNy5IdHip2BJrGNrueOBT0WpgKcrKJIn/FUZ6bTjss
# DATA TO/MOJjqTjp9aGAFoW1xVSxqC3olBDqap21RZdncjGr1qrvwQyhG2n/PNrPHKBesswhqusxUJowZzZXrkIJimzrtyisog3uwQfbd
# DATA ashbGs08AZDqZWm8VGNvN5hBlahHHXGYDidZflzTQaem93VfnqlXWAX8tTIh3eRS1SGa1HYv1nq6w1Xi6GDzm24HXgtUIQQVXryH
# DATA 9kuwqhK8c3/YzLMp5wOoxZxJgrR5LvAF2vQBfQI/boWzv+NLOkH0LE48sw+WcMw+9I1JCgh+LuQYE5vmHBZaSL+Ne2T5ZTpZHvQP
# DATA LALssmKq8eKuyv+XuVwZhknQrT8jT9S/p/AQE6dufE59jYW6pCtJ47/K2xsJFr/E2HYps3yunZDUf/+jBIzCOdb6ufMYlDFAZA76
# DATA mL4h5tR8xJHsmVSnvZtNIEGgKsPz3yqdGmSFaa8Dmc+1EC6A1UCZPOj/KOt1zHbZ401QvaDVdlhvMMRacAOINH/LmuryhnTGXNgv
# DATA K/tyuIHtdFHdpcD2rhojILGIvbkvsjCC/7CYKKfi4oSaobvnpWQ3K9rlIoLDnZebtOAT/MAgN+BkW09ts4N4Xk0QhP+dTv6Il0v7
# DATA co8qRLwPXkB9oUJ2IEtyFeoe4ASYLegL/l99HwuMhfgLVAV+CS6b+grwq0qncT7S98jD4reMffkzkujJL7Bkrp3kWq/O7CmYR7/3
# DATA DBXdD1axd5OARRxLgJm3xNtOHe3TEZhZB1Y9vEa8zp6TUYm5BM1WAtrUchpMKmU29l68wz1wt7hjKXmCg7XA+mKrP8pAXUrp5Sv3
# DATA Oyt9zIfcbFLwgyLcPOwlnYVLxd4YV2BUJv/M2Stw+wMWwD6k4e3l4x85K8f9kt5bqsfiuHAuOSOcqSktvi23R7AAjYXXMM4ABWg3
# DATA pkXW5UsivV7WewobFL8DPuCVIOuV2liuEAql9+ZYBOuRkFr6h5cW4EpWbVu6VTE0jOeApcGW/2dSJXv3dwStxNjJolbgy0VY9xeM
# DATA puvC2pCu7xcY5wcY6L+1+uXAyEMD9t9oIQA/d0z5UJIttXYFvb1BtWkDoZAwvRdYT+F+4gXZFR1tL2N3xaY9HPfS7r29ERaleN7S
# DATA +Je9l+iDKQWnGjmhNsHCOuemIi5U864rtfAaucYToQso2iJLKkBtgvXyM6NysswAIdQ3HhydxkdCpUm1LuEKqgRvAPOCMQrgmuqw
# DATA bkIvfSfJn3ty8j04eRwIxqfzzX8yrv6gb3eKG4Xe50jdpQ5PK/Z8z01OmIO6xC9Q3pA4mNp7PTSz1q67qPYEZy3gZcytCM/zuetd
# DATA J22Y7UO8+MWbu+C7GJmGpDs0uRz1ikIMujOEzwRprAWZozr2HEU3nFVHZ+y4H57HH25vbe521jcfdR5tPVnb2IRbhDQQiJE/Xdtc
# DATA f2yL6TdWrgEVNuXCFiE46qE3ieSNCHE0kDq12gjgZR2HFjxqrAdd1JezUt2Xa7CX19qLaufdOVNi2rMPOk+fffB446GeCt0QeoAX
# DATA 40tcNLwqP8u9ITnkmHnZc7VZeIcfoq4NZbrT9GXWCKB7GVfNJYN/FNirgY0jzB7BfcMFdTYxScHaFDIvyV5bGgc982TbGAuTYjeK
# DATA IpEjM5UKRpfm5LrB0ekw6zkNhjy7pFjmflEPL1dSd5R1+4lYkDkBn1c+SqGDsL90hdPydW7X88CpalWcqQt3qXlXFo7yEw05U7rw
# DATA 4dLgH1xyCnDtyNphoUNFMGpr6e3bmL9QXwWFdVmlab+sk+z9xXaf/T00L+GvBLcSfR9yUuNSS4W7kCYr5Gmre4AO0+yZLaJ0Hxlz
# DATA tSBaHtghkXLhqM11XphUhWr/9TqCNhozcNkJJQZvvqB6yMjYjqQtibSBRpqmMtBBdHCqFh/S2XQU+17Sb29ukfWWOmzJzBY8LFvQ
# DATA GOg8py2sWI9tEectVIGVeqRww23d4yv7ARX8vD5384f98l4JKL2JIfLE5tjaVvVuRXmujf8VZo+2o0VWjIA9EOkflALBHNL2jSNF
# DATA cN9sAqmwFU3lTd6uOfROHoZkzrY15KGymR2xr/J2XOeYr1IqawlJYo23zqkq9ZOR1TylLHhslSj2UO3Ch7rKdqERdPPEO2ybO+q5
# DATA zWDT1WOQUbxI3comBamhPzEhUp14Feo+kjX2xg3+1CNbOBPSg0d6addiSEPXPQYr0ziD9ONq9/RfKgKHP5NSd+KASUP95finLuzo
# DATA 43sikfdBpwxDIgTWQJ8U8QtMRRz9Zn5XBcGZkmTQTK1ao0Qc4HKoX8HY9+kZt13KrxOKTEEHT09jQ7GPHTMk9wrHgHoVn1xRRphX
# DATA 0dXEhbLZC93IygQBuYz7No6Ze1nt+W2/9C9uC4z1WnuB/gfCc6lV61BHD1xdG7fqgU4EonZf4D3eM/2LJvSPZCkMmB6WualiV+rW
# DATA fbqa2D0nuNNaF0PC+fzFqBTdvxk9xkB6QpCc5ZzlmwBU4jwazw7UiKJn248jgimj5CUcD0+wMGqGJ1meNxfTjlCcA2TVm2QDSoox
# DATA ZBLAm5fco0qD/fizOSg9pSkHyvS6XK0HKjzsjRVvkfRR7ghdF5qVtL52/cnm2idr31vvkJ5GTR05c4b0H7gsupHEASJRlGHBEZVt
# DATA dR4RYreYvy/t2cNfVjv3FAvte+rwhY5UoBq4lIamtOUCzOg59Cmqn1wV+AZts0uCLIUQlgzLM5WWgC0FCaz5qEh/wrTcfrBf5Nde
# DATA bchIwPfJRLtzYJTt2DchlQEGBNoAxhwxHY6z/sSGmbJQTLgFr6aMD6I49xnTARvJauoBMwf5XIL5wTxuGOBRJ1YLk+JSqFYSmmc9
# DATA 1NOJogk2jtHzYJKZqigI0QvWlJHHMmhzbpwiYeBzMIrTFzPIGK8iDP4FfzthU6FiBiaJEPUZojjLeX/o6XcQ+hZYVeadcqzoq6tX
# DATA k1y/jVKO0lOqM7cxRSFWfpf4keThsEffqqfNOyZml0T+cmOP0d8IHV3iwo2wGQ0Fb5wQBl0tZigK99EMgDWSvnmQNOs01XAL57f7
# DATA odQ+eYgs84YrBMqCE+7YhLB2s4Y6pJNMRrv2snFufhzM+oMeBwmr6wWqVcAcXIEAc6O2Fzd6jMvH00QukFQl+h6hDvQG5SBy4Uu9
# DATA CSpw27LZCkpvxMTT3llVdKrObsyurdq7uIZK6FYRENLidzdVN2p7AKSdvcq6s2l6MMAg4404iKUN/lYUTI07y7TUHKudl2BWXb0O
# DATA qCFvjMlGiAQKOgNUAnKvoDd3HbHCR7Np+9bKCiuQKTeA6OCO+XPdTQJwGQ8NaaMnDw0ZChi9/lX08e7u052GDtN589OgC5ANJPxC
# DATA Y7AQUC87F/0jqlnADenX6iAiUDhe5pguKWkPyJZExmVX9nKkO6JJ5Gi+T7dkOBKDjOYZ6sx6DaiW7svsh54EwUa5Pp2y2/pQr4Hw
# DATA 4X4W2E0B12sLYrkwk1zQgiEZnwjKZe96dFZ+ezZ4NdY2OaEtrtiMJESxaxORVGHQwxxBOA6fU3xAI6LoJAePlb9bNlgHmGcmb9KU
# DATA 65ykAVxzyVU1N+QquNLE0b4IWBAX/6JwYTCuu9a8TBUEQIN4GIzqYsFO8wBUBNXbnA3RZemkn8O1qTN64VVX9ClxhQeqpi6ggRgN
# DATA yOuERQmq6/6dEIYtJeAJwPyKgyN9pxIL/Gu7OlcCcWNZ7Pluuyc6IB6RdZ3EISb7ahd2UEm7OGEptIojBnY0p0kRAOCcNO2uVsLe
# DATA uD1ysUmMsm0eHQgKAY48hWG1eArdJiReMw9AqDw59P1FdiZRcC9Jiy20qgj+MfO4SPw6B5Rptbz2I/8ndC4BrvMfHNX8V39a7UW+
# DATA gK3FB1RieLlQW1ygWpWpG7jW9snCom6+hXwMDs4zxvH9bB7SczOSSam1Xw97CQESv3Hcc8wiVz4wjux1GdriIg9jF9jahvpAsiF5
# DATA hNTPPsUGhiYobDvjtK9ZZMH6gmzOPqwTXhQVdvBv5lkQPH0PSXQ2yUlJPqfyZbcJnFimonQyvk8+h24Noz3fIqHkdO/63yQvkloS
# DATA SO/I9v4pa5jP9ZS3vBWoR3IOOLoCObx4nDSFK7v6Qs2pLAkwqbLEReEmsfhh1ykv6e5uIL4Cs+xsVtGIufcHmaLuFcpUdSPl2eQM
# DATA DkNISq49Gqrumr5QhwlAUWwKin8sFmnhD7sWAOGimgqxpcmcqbHyFxn2pNxVdw38l63q7eow0qhbT0Fr4zrOOuLmPuM5SnGwvGmf
# DATA ooVKUvWenFkYccUg6BXIwfT/FV9F/NbOJBtkivB6zCo0OK110UZIR4Z30YlaLqMPdjfxEY0ugghzrP00R7RIZlpluHCs4wxBK5Si
# DATA +qH4JD90MBbcz4z5vRwojmryR2oUXt7E+uWC1VJCLFSgy36WWCzL5sbUgp4T/OMKU+V++naTpet6Z9M1/5xVidtliHILaiMD8oVx
# DATA g29rX99W8LbMaHQQdoM3YH0ndtRvmJEHjQio/8Xq5B8yaynkfNX64eVs2l3GUsvWfR7LpL10PGX8P8+xPnw/XFDbUJqrylGGmoRV
# DATA nHIAf9QEe5KRzUZ2YukqeVfzSOoFV9kAxaaxg2scuIEW1ruoCYqTefH2WldUiP5ZnG0sqlsqMDQrFRlpzye5QbkoJPII//MFNVeF
# DATA mjqD9Gw0wwAWh5MXec2CB7LAb0pZe/BCAsuytNhSsFj+gfp+Hf9UpFhcWR1VpXuTNSlmDC1fKMfMW0KOmdxmZQAf9ui1gqCd3oKE
# DATA 8Ao9GBADE1JAEkoWcil6NyA9qBf0eqbuJk/0pWQRx0zyNawzssmTdCzvIPMwEROT6Y0S/6Jin8hJaxF9EF8XzbLtez6RIX2Ro0dt
# DATA Fbd0qgRNpMa2M/LCl1Qovy2Lu2ZYnA5rDnbFydPg1amT+ITHSEsqUqs44Scud1APavFyOu4vA/jxMkFzxmQLhzZoXyxrEKExQD6Q
# DATA X7tIptpEY1eH3ta8d8j3PlYzPlDvzjXQby9Le4xQjVN7MlITMRr2uzVQmK/eJLiW02NAZi4UuG8+b5Wnv6bkf9glym6GXlra8nMH
# DATA 8wAqdqVmLpRtWgS2+SvjCm/Gv6FE2BarVnA2UBMc/uhg1Dtz0Xh1T1ETVoPknJyjE2arHP/Zw06HegVAQOAt7T3dGhzeqtJ7tiTv
# DATA 2n7+eKSOzxo4GIFhp45BkhV40aR7sWoa1LaBkgwtWz83WXXIeVjnBv0p5Bv9LSFdQDzr7zBa7pegiQsI9t4aMA+SSYKbYIerUhMR
# DATA YjihIyjRd5IVs1Cha5VijKpUBDmF4jx69mzjUdOXCzkVK/pbKTpE7Xc59O72yu2kiiwsvvnCg65t7XDCc5kG3ZkKNQyZFdjahHMb
# DATA yoJHMh9k2bh2kxllWHWK9s2IIxl/68UnUxizVpbyav7k9T+qv//T6y/ZFAq4kwRZEkqLWwyX/LXJTKHB+Mls+Rbmz2tCzpmvX/9f
# DATA bfj1L9/8FQR9+rkzYHRxQEdb5HTlcpexxn5tglc/HwNGQC2dHOU24xf8AvrK+Z/bWkcde6pn/KxJ9ij809H54hPQStqQoEDFupdx
# DATA oOOm+uoqzLQ51h7aIAtWAYafBjFzYba21jBRDc0cQu2Z3CeTHDmoTqTeXJsczWD7PMU3NSHftjud3qjb6STiyyZ4Bqb8SS02PYvB
# DATA wWEEfh/tPW0ZMoYhDVsvrffadC9Ggwl3D0cGHSvUoLopAvhdHZGX208p56Di9EqM60nzYvhbK6k43XVyBNZDQm11l5QE1jBSp613
# DATA 0diZ6srhctg4oZ7ZussQdheoC31TkntlZRielotV1abu6voiG0N2T9wzMV3Ap2opPPudDvU6yhp9FM8tPins1tgzLLDVwEnEFuwG
# DATA CJU26AF2P3rkYln8B0rntcShGMORC0ZY8w4akFy9jYEfEsmoxOvmJjMiw870uAjciNMTQODm9iKxTyNqpILY6U5KgMQ++MMyqDp+
# DATA QndMdwz8mxaBf/DVk3/ZKDF+YNAY5G8KBsbfEtm4iLCOGYG9uU/KSR2FoWnyIUmGJCWCfEhYCFJpHXaH04HDwhybsEdvS9MSo8YI
# DATA XcAoQ1ctVhxbdSXhDMUPt9fXdnU+4u1Hn2z7uYnrlBnJNqMTgx/2sAGZJDc+jfFqAC24AhCOpnkIL2rwnzo/ebz18Lud9U9dsdPl
# DATA loFwUNolKOH3ZifjXBL+uZtGqyggWXkOnthp3u332+xPCeao4bR9MwEGpBa2g65znQ7u104H9lunE1s/1Lx/NJyd4ILDn+mgubPx
# DATA 0e769pN6ZH9//Oyp9NKi5/RPjSowKfludNQ1H137+tOavpw4gg5xRCmX1KQ4amTU72ZnJIoGpHISv3bOFBU+WX/Vnwp7rYeLllFl
# DATA NS0gPWQHdtzn3JInxiU6bO7131lR1VxGjNxacJkIuu/NcdlDlJ6fYF51kH4/14Agv8I0618g5N43FvnfSTr50YE6KuOzb3xl/4OE
# DATA 9Xdv38Z/1f+8f2/duv3+Xf2Mn7///t2734hWvvE1/G8GHrKqyW/86/zfN68tz/LJ8kF/uJwNX0bjM8U6hreWrl+/vp2lPbXFcXuo
# DATA a+na0w2CK0L/Zbys5tH0eDKaHR2HYoZU+aaqZYnJuhZd9W8wpcDBgkPam+qn6raKV0b+qW4ux+qOqX8C4dN/j/Il9K+Au4cqorkH
# DATA CJe6yMQ0pgiL/hPa1H/LG6z3zOmrq5wyT2f9HvWBaYTuA96lFGFTF0RFS7sDNaDImBDpwmduU0bCV4Pmq6dJA8y6f8UoT8aQWKXf
# DATA Uy9kzhPytkCex1E11j97SXo0VuczxlBSRXrzaa8/bPbzdDo9qxV9wtwRxE/I7zES8Tyq2kkfvLJJfBwNMb1TSnjFJ/r7VuQKf9wl
# DATA Xvom/1ujYSNZppETce0Px7Opfmmmd3O0nZFW2Nckgi5Bv2OFIg+Nwi/oTYeL10BEx8uJYtRj0PCD3HSSH6npV8dBbfk6JHdTbcyd
# DATA H2jY1K/++AHmnr8HBwePyyFF16BKByKa7GDWxn3bw06nP+xPOx3uGekjRy/URogdoBKrX6Ubogkvg746/syc31n7BJ6TotfgBlwY
# DATA TZKNRwNzk5vy2k14TVmh6U+dFTroJOfN0TP1LLVzgCLWaDaVqbDrkalb1xyHx9Nua1QH1NTb3puBrt58v7mi/t8qDBYzCEMZ+NFq
# DATA rcYXi/R4OzsZTZnW5foSSw75tLRpRKmJd3Y+jqazIYwMDgOUiGVEzeCwiWuJf+GC0gqarM7LIKriC/cr3ofo7fVp48PR5DSd9LJe
# DATA 4+lkBA52kV1O+Vb9Be/sDFzQ3NmkDgtMEMOFX7gdWki/Lw4oSJj2/MljZ1AZUEMAumJ2foX0b1pQZX9rJzAKE8aIeQGfxDFGOIpI
# DATA xWV23blxQ87jhYM0ahbD3Qtcdi9eo2SPP+LAcNCpfZCpG9sEaZr93M8p6/uWoq6+NBchf1TzDzS7t8LHSBdhWmhNxJUA3yZNLpuE
# DATA x/GQkhA3dhlO1Z2oV43T01PMudcwrRKesW2xOLOOdRoSbisKDdtqAkGCtVsCsARO6kfru2xAXE0W8ApVG6W4w7bF7oH5AUMVbh2Y
# DATA wDb8x5DttiHfDgJIUe2Ptzyxr+k2iQxBm4Fuz7MDudmuXSvMrZvaBiNMMWWWGMB+5YqS6EHkfzvPQOITLxDhdG8gB6m6e02OshKn
# DATA JmbLTnJH6knIZfZSdhHjM0USRNCgUWUYc4+TrNHbX17NQONu3/x2PbqzchP+cwv+c/sCi+kNez+6GW5aWi8UDdEfJKWrXwjUnrcw
# DATA uJmjw7Q/yHot5BiRdha1g0hkrFZgIWpBs0w92qXNGzLSVEze731W1CfDDJWUPDH3wFIGPgInqmg3erq1swu7Ar3r/CA26Jy63Z2M
# DATA KaTG2h+KuZprGDx+qDb61EnoplOu96ZNfWNBKDqv6joUgGc/Uq03Z9NuSHtTWlk/H1GCU6qsqXPNx98H1vveykprZcVzsKe6mtMf
# DATA gfI9HKZkmuOyulb6ph3ssJOTvZnmukTNL920fU5sf7mrqtPfF6a04ctsouTQHPxl8x/O0h7IdKNpSskfAR0j7Q9J1W7caOHm57B4
# DATA zu0ItZDRWIujAl2B7zITNauzwQDBqWuTeG+t8f208aOVxrc7jf3zW/Vbdy9iSqY9V4Z/pkXe3igjZn3Yn6L03rM43xHNg7cxJ5n6
# DATA EINrRM7Xzkk6RgGF7kQgoKw93N343jpq1tXNS92dwE8mfrSxs/bB4/VHKIf1T9R9Eh8/3niysUtPs1djMJ/A0/VPn25s09PRsHNM
# DATA 2YNsFSafj5079tgw4Pm2d3NnZPhiODodar1ApGtaIiSKEwAkVO30MHEyLTp7Iylu3MECBDu2ktS9EvBZZzpJDw/7XV1GLutKdL9N
# DATA TcAf315ZeX/129++eef2+7dXvv3tVX1rwVLYg0CheaPbGKKXZ8S9UHt3BjfY3Cwi+NMenaFsFhhZB3bvtKOL0SDi4Yiex0lzNh4r
# DATA WdhCYun6zA1lc6uzvb6jqK9ay0drn8E/n6yvfxf+fbK1ufsx/PHZ+tq2vKyULVSuWhtNwCcZm49st8hNJp3AocOA+f1Cj4ALYEPS
# DATA WmlGb/t5z9Sj0bzxs+gg644gGt8UlMeAcxfRjtuDmdzTW3J/X+5W+xg7ZHa31cn7jW9tdj7eevwI6j/LI30G7qGh6yUdV+BrPVbk
# DATA mhsc5GHKTi0dsQSKjMiGRlFORlhtCaXx/WwyUgw0HeYRhIXigWUsDUkqmtH6q+N0lqOjeLdLaRdO1O+IGoj4gDedCy5s5gdtv1Fz
# DATA 4NRsrvruIjzPuKcshdHk4yIcSIQLYwpV+ClTsw06Z879SW+Ra3KPeC5W/pJt67mlSY8wNbb++J5FjokOZ9MZLtUQzFB5hH6mVq8k
# DATA r9ehrWqNVtDtij30LAfHHEraogSa6Edqce8peXmqrvXUxZP0LFKtDokXpAMEPYjyMQj8mnakR+h9ueSw4nPLtlrsHKy3uE5xbWj7
# DATA GlxgrZxB54FexZR3wtIgfqwNEDcVsWus3mzcWt29eat159vq/75fwJCIuaePYTU/gDBJ1R6TcOfdjiYcLTOx4CSALGwD6OMwHewA
# DATA X0csIBBXMWse+DHVkN8nSQHlKhaWK3A5NiNRpJCBKeMQ5yLtc6+TTuOCmLan366hU2Nh7sS3IpdXHzFDbAv8LJbZQmaCmLbBI7zG
# DATA pZKoodb05QAiIHHWRj8go3h+nPZGpxAhmYth2GouQ77HoNnpjgYtcRZY5EKtKyPykPZZphPn75TUhclF6jrGFuIOa7bXZNjHn8/U
# DATA woHeqSaGojV9doBP9RMsKYfqFc9zW9RFVdB906yP59OP3/DuC1rhzaX3dC3k5kajTPw8A4HIwmqNtumbVUO6KkeRm8vOmtuC7ql7
# DATA GugaIkNAuI/fQtlG3fapBPy6dXORPj/VfTX6WEdUlWIqB7CoP1FUnWScis0lnXyUaIhwigqmgsJShXu2OYqKW1hqdmX+ECH1O8gv
# DATA 5VptK8sKv5+Oeq+JR9JEuEqhTtUweOrPvcbqvr9PKq8Nq3frd2/DvUE1lyyyMDLOmNS4Wt+XRvkxmIlgR5DOeJAdpd2zgHMoT2Bx
# DATA eWKsAvcdBkfODorXt7rhbMalDLP18E0MbDPDXtbj0XwzemiWJlJCkdosU1RRaketKHupxnB6nFH9J6i5QQ6cAggUeAGBBMMXcrw/
# DATA EiXqZ4MeSpnOlc0enCJZcSkHUlM9Wssv6yEGVsa59g1RZAhq6pVDkviNnheyIuhtBm6GINXot4iH7d+3cfLx0mrAnYPsG/gT1mZf
# DATA m3plkYLZztatJqd/NER2dJ6rmaWd4Ko2cicXYU5uGwjZZQ5PkIkjOueF3FDA8WwPgx/tI9HS3bJxN5r8dKDRWjruO1dvTSbVc63V
# DATA raH2CQLrIMAAzczLB2cNvXcwHMGhCSCSmTip9DADw5g1E0igE2v6lD7oxkpazOsudElqWdQe7BCPoXGI5JoHcLR0iEmOemaUF8G+
# DATA g5YdSMFLtgyYS8ujR4eHeSbU5Cv1aJW8INxKNcDW3Ln6DtXY1ppD+omAQn+Ewp15Q9W7jA1l3DDoDb4i1My9GH+5WdqcF7i58Yti
# DATA DAAUtCocRKWBNA+LUVWcfnY+0DCk6jKHhmhcoXukDdQP0wjR+yJ17+6PerEXQgdetQw/use92S+GZBZVTglhpvlmovJ+P5qRsSRj
# DATA UYyaxii+HHHMoA8mb5wXf5gNwX2yFupHco/mQt9d4EfiZ1LEEhhCjEvi9vlACcUvfFboTAh0U1TzIFRLmTpFe/3pYdMaWc4v6r1W
# DATA 6F640nWsgu+goPTOwDjFOg30Yncgttm/qUEt6/D9cx5cS59W3rgt6sOFQzGwiMZFmw09X3aMSyM3yNl0PJuW5bMrsyeTN4zpMmoD
# DATA YA0OwJas6jkYgTcN1BaXJCp2Gld0bTR4qQ1/pizjScj85PUIfZw1cFU98sEm+ofiezko9K0dntXEW8ULoP5kEZWqGpe6wUdgJziD
# DATA i4wzATpoLG92j1WHaoLIiq7xdmqDrwSNn550jLeDlHxFMYcjgf1duNsQ0OzDZzu7nbWnG53dre+ubwJx3daJG9EHiszDkUnIplXE
# DATA baeqJ2vb3/9gbbPzbGd9e3PtCapftM407SnhSdVgXHpEMjojxoere7q2s/PJ1vYjWZ3+BPokJsc4FfBPwzJAQjM8A/uyjEXNsWD1
# DATA hP5T3ulaprULtsojfwWZAEK3O1QR8QW8+ucYN2sVYEHG1WdRokGfAJSFZc97cd+TNORlBLahlX/abe3TTF90sEIr+FD9yXw1MH1O
# DATA 5e2NCs8L1NOTWT4t01djdcUEfe8Wmxj7h6y3k/d/JIDV6mSpzFlY2LMiq2ZT2EZF8OI4PQNDbV2qdl3rS2By+KHVd2pvYX0nU3cL
# DATA uJb5Vl+KjnBXl2Q88aCu+yRk//0CgLKpTMpfGnZNX1p0IVNlsjDvFZQAp5Jgv8jS3+sfHmYI80U3gnvY6EjNGfASJfF63Bjdyk3y
# DATA au4KHgue+1hPvnqo/5ThJK3gcAVOtbbjusNwQ++0i3M9AgeOUm9nrA43le2yd8B9gYIyZ2MKpWieb7TbQ6171DYUJtE0rfFFKYOW
# DATA yMmWLdOJiKn3MGn4h3qCGxVzNbb8nXuhlXpgVzpkQaEVnVsh4wKkw7R3ph6qGyzGVM72rusFuU4JjmYaVQGKa90upafoKvGEPp3z
# DATA GSjqFNue5tw8dT+5iGUXUXmDXoFMNigdhqqiZQz/NneN4clU1zwa9nSSqR4cHU+N3VxyRHVfJ+G5GW2j5SOyy+AGrvQmZx0l9Pgx
# DATA CPEjtXrquQmEI8M8kcHi0XFD201QyZkirDBmcuqMH0rXYjTmT4/VIYGufQd3eqQ+ADaH9oUzUFj73XoIG3RQPl6IoRKdYekDFPOs
# DATA HQYV9j4qRXnB9QOaRvxl08EgMgSvu7yoITEAGyjlFWIysX9Pm7EDZLGcrlukw2paa11qAyiGwUtdqbuVJ0GVCA90WC1FLlTDtMzd
# DATA m+HWvhmtWd8ksK8o+XcwUuyWdUyRwSIhD3R0JAacjmG3DzDQiJMdHSgBtTc4oztgM9iQE5L89lMcnmZ97dXci19XMa/yo/yQx0va
# DATA bAj37cP+nmRw/sbmnE9Hdj6C8eyw1Y0VxKZfLo4J1dKX6Lqu2p6ZyspDLnPzWbe+7Ss21M3ssJHsaH7twCuF9l4Jk9QD4DO+H2SX
# DATA LAsH2KPg3gEGx8pQZnHUVCk33Pl47eaduzvPnuygXwultuIwiGZ+nKqXtbGHbHqcver1j+B4oponQuYxpryI6vfzYUzmIJSAUR8v
# DATA bm5Hg9FBLb7BpD9JXB5KFLnHXIyn6Tpvoev7wOokZ5SFzHMqpt3anDL0EApYruOvxVxGl05QZ03mr3uRmG7UK+XY9Ew9Bus7i17M
# DATA p5TkR8d01MNDFQejr68UeF0M40V5CBxqYz/6+V6guCA7wW9KWnGvUgu1RJqDRRvAq0sDri46nhs959SkpWra26vqhh5qBKW0YkS0
# DATA 9P3SukNbmXhd1h0lnjQIjywUyhzqyRmaCUoDn4sf6JtQg29CVV/rQOZgDDPstFXUkrt3QHh0Z2VFyA86HtlOdita/e8/+V/ugB8g
# DATA 3TeNTTFwpzOpSjiQdG5A57w4y0veRUQwJroP//HO1uYjhF8uvaoQwbnajcM8NUQG0zaQVInyJehtyEuvKcxcggBg80oaBmRPVUWb
# DATA w6FUs0l57OjqgiGW/6L/56fG+PrjP9+/tbJy043/XF1dvXXrD/Gfv9/4z63TYTQaKmF6iiBGvSw6mqWTXoT2invRiywbY5QTHDDF
# DATA QxBFAP1SzqwP1Et1IKF4MBIUb3icVkqEcPITQiIwcZnqKA5H+kd/zEnn3j4y9HiQvbI/ZtP+wPyapibW0+Z4MXGk2ckYSMXS0i64
# DATA GEY6zR/oiQnuDWcrXtre2trVmnoCCzXlGogcZ+A4kqVH6x+uPXu829n6ZHN9u8Nfxsuj8dR+FC8929zwasyRKPX437IGmhr5KVl6
# DATA uLW5u731uPN0ewvA89zaZoenyzLDW7Pn1whLNBlBj3c2dtevWktOAvuTtU878Hnng89213fAm9FGuJiX8FzJvjj2zu76pzgxcbz3
# DATA bNif7i89EmKY1dbjnmU1FC7G0hrcJdvDbHo6mrwAxt5kV54eQNlP9AQtfYAeVe0TJYT00fLM5Zb2ODHe/hIwu7a66UFOt6X1V1l3
# DATA B/wF2+Yw8UGKqlZ8GXuliK6GQF0iX0jsJrCYthJWlvY2CMB1f+mTFJjUB2eBjqm50Gux/uHGpzA7e3YmNmEmMEhx/zlkWR1AVgn9
# DATA SHHBA1iK50MpzRK2QY8m0ZSArZ+3Y2EMuwEihpsoCaOvHDRNciJwEznRd8ijOVQLTj1X0U3H4OvZIdmUHlbkyaTW8b8yT5OW5nnB
# DATA nSgQ45JpaEmzP+44JTEVVL87lfYZG3oBN9D+q0GGiC4rEUJr44t+3sH16ab51H08w1yTeNPwbzUSy24t4mJdDo3deAr1qPkbZlPp
# DATA khM7ZkpK/Q5tJSa5nFpSMPqpStRg8mMEeVGzfjDp99SFsR5hrCg+ba+YUHSCidRTgb9ZNoav0aKEl0jwZDCVJtGPo/ObNy8c0y6/
# DATA eRDdva1thnBlqI0TrfzuU/pMIxqP4T9379y5dcfeWamWqhnTOmdgR1jatTDzcKEjqze/pXtS7fPVbIHXV331Djh9HVBq3gPoja5s
# DATA kf48QrLCn2jPzPSkP0DP5P74LgZVxq2YvBAsdmZ/HLt2zsP4nD68iHLYr9E5Fr8AN3IIdWUxnlzL21Et7vcPUQFwjtoAuF6RLkFG
# DATA iopRiSXVA6QsVJFpAmVyfqnzgxs/J1hVu5lCy4uBGbaIWedF5pHolHAdYIKEEzPtjqMeVnluqze9RvwA26rsN5+bQ0U7yQejD+fr
# DATA HPn5RXR+vgS+OqqeE4JuVU9wnFisw6ziXnQ4SNWdj4nOvejiYinCtOB8/YBq6DMlLYAm83g00lcTdesYTcDNrrG6oq6qYOg/437f
# DATA U1/pJbw+GF3nx+ppd2rwpGlyepPRWD0/p70CumkxI+fRuV37k3QMV6w6n6jkQvXWVmy/+rd2zObtOU/5hexChs4r/fw469V1Ot+u
# DATA NuZTeAWIg6aSk2yaRoPb6A2qCO/Lu41+90SdcfWfl3dpllSPh73GMOsfHR+MJo0cJgU80uXDtAc2TXw2UZOe6ScwHHWo1BSPyT3k
# DATA 5p07l23c0bsMJ1mqFhPzDI5TyHbTmI5GjYP+EbGZhvY/wVzSaq2gL6oB9cGJM7e0RnZvHFJgfsnu0G/n7I8FdsKVV+qcacmF7Lz6
# DATA P5AzDLRjF/SuRk3GzAGYwBJ7b+vQzQJESawodUcJoZvrD3c3tjYpho/9cx3SbStBB6bbBEFjHoIfr+Ksvf4RfCjUCdAZ9JoCtYJb
# DATA PoQtBXQQkYXBEU8JJzHKcTkIcorDUUrOXejhtKc2HHUUyocTVDs8BU/U8957MSY6DibOdDoLhfRM7JneFpBYy7NOOh6DbOvQZNvG
# DATA eqFnBg6VZF/KNYosH4MOGc2ftiWGJ076arXbzMvg5Q+9CbEr15eutdJOJsGJS9vmlNwA1aAq0m14E0dZwXK2sdGm2uKsTjJ0w/q5
# DATA 4QxozT5/bmDum3wD4G40qXiTvf28DE7e//QwVpDZkMlvE216qGvjGWPWczBB7EMqtdGL9/daqzf1KmtJjpgxUWkjrRmhjvJeI8tS
# DATA szgwsohwysDJHR5OKX6UIDzwA5rfDB4gn9OSuyvi6pqa1CEMnsdELmXV5rFbkfjQ5+/bBJakbVvpkOQEXPJI1U3V6TOaDvNU05Da
# DATA YdzL0JuwyK6fE0x9qOMonjPfB5EGp8xoSPVwGl387yH+N+ZLjGg/KX5RUZYz+gEbPe0Pe6PTGsBI8N/G434NmUjPjFr1kiJ6uoMR
# DATA BMGhx70a1UPF2w5GKEmBLgYwWSI+8VF3kiqinjfN7eRqKx9csKrqFlrxq626OAlqkjZH0egUPN1J+9QHRy68D4MNVN0YyVNLX6lz
# DATA xe/6AA8KGJSVk5LjVHhTEhvJJ15sftBbyC5tKCJAhIk+Gx9NUjxLEaVw4jGhAwE4imkAJDrk6CQ0zWnHRjptXFOCN5ftxpqLQgnZ
# DATA ZCJyNBci7qVF2+cC5YXqVWsBghf00K2bJNwKmVLWlRRPF510jHSnQzFnsWKUc7+F4AMXcZisBRdKNqpm6Wot8hzBn6t3TqgPmgpI
# DATA aG3WK7CnLcCLGj9ijFaqch2WF6Pt7HBG2CkRl9e3y14dVZOjSYoOwlpN2Tx5AarBMVh+29gUuQIj5MJh/1U7buJebIQgxj3k08Oe
# DATA RTyFuj3EU2iNxkz6FvPW+PSaDtJMOCUMSoUtY+HFETNtcOacwFFOgV6czNN858sLuU7Ya0vopLSAiMvZLe1VEYH30Bh0BaWmXdav
# DATA +2aseggaGtRkN0+P+0oGjdUzFyFDPSjNuU2DLvh76+e0bQqvOTDQK4Iu4YGvgY7VQLDrzNQYruH1QElimfo1pzxG5P9RtDJauXmz
# DATA an6eDSEUKHr24SeRWC9drww9pIZ0KlhhBlXXRQbi0oWoGz75h6fNnc7Gzvb6RzX9le4rjkY+LBmw/11xjG8xTjriX7VOGKVsCkW2
# DATA U4aeKqDYpcS7/nSTx6MzvTADxiq+etPLzVtWR00HQbv+V+5dTH2Td1PQP+KEoDAY7600vg2avjsXy4pbPQdXAqorqaTAMOPcE8zf
# DATA MRue8OyQo1IeIqSOLsqDRSAuQTVqqsxOoJJ8vBfF3M/Ez/VVU8ea0PuBAc3GOltdaM3Lv4YkLAt8hT5idtLDQHa2WpF23nL2Rdvi
# DATA UH1cdSbii+SncDpY7Fzl6f8KRlA6irBXnLcheE++ozWXOTrYmGfyO5O1gC0FV+KBxjwIPkUno5eZg+R0VQ7FSOEtSwwuZ6pgpWfB
# DATA G0cYKtSvm1+LoQIpKE+Tb7H4/x8HNgN1uJLhFWY91Z2oo9e0iuL/S2PS/jtkXw+Ae12CfYcnaR5TFV5bisUh2JujfXzuc/yH1Mxz
# DATA l+lz4y67f4pLwSaoGvDJtHG41viw2Vrefy/RjL9mGWjtO626/ZV8J/E5qr8q2Mu5c1ScnEqO6+8kTR2wMdCoujh6QJ9IhLAfXWsz
# DATA bYE7N1EQsJ2gpyNVc3Nfo0nUwWsWv/BO/+KjOcgGIwjXmo5UR0bTYwz3Qh2HDDFTNBdEuPB6xhZSV13FTeBZgPw6jONGbS/A2PbF
# DATA zKD4tQcZYi2zA/ea2KLKxNMR8sLhWWxYkfpvIlB+0btBHty5zBeHwbyIR+Gm1J7D3T1Oy3AAOtj1K2O8ZtzOOMzOCsuENL6CdDJP
# DATA uipWXzJVc6UPFzsEPVHkDducC3T1KpyS1tKle+TN8WG8d65m7uKyRImN4OYOgpbuEmNnUHJecCHtZlwoL5re7p64FZhllsAGWTqc
# DATA jTtjTM5MCMbaQd85u/BOe1k5qecoaJ8USOlBPhrM1PQSEE6zyd4FpPOZ5hVM+1AzJO4RftWCaZ4eXwhkqa7aCJgMG6Gkbkwg9ibP
# DATA KB0eSwxguICf+xUBq4hd2ra1NQce8+Z5hpS3m6Pph+BhGAghKsBEMQAe8vvHm9+tQTuG188h0IUpYCFLzYLp54WEg0IZywTk25nB
# DATA 0wF6s4ldTNlD0ysWNlZCVian60bc0LGxtWJrGE0nu0ThdU4lZm6+t/tpkoSb9atwZKhHG9vunIYrIdwPr6JaQRpzaoLp0g+QSsHI
# DATA VuVTFq5cr8EkufS6IueVixNaYT6uMLXeWUUwbzqrBKvidcg5sIUDHuAD4SxW2ADnqNrafPyZn6XK/t78AHJKOfSp4tz4QNpVya0m
# DATA ByFdLx9e+AZPLXIW+M9wVEuq5e/SFRdHIQru/EV3RwArc7Ed4RE7gcZvJO8a+ZY4uO3srQBFk4Wbfyh3ooFj93rAC4VXix7GUKjb
# DATA 8vSw8S0LsMybq3vcH/QmvGl4/1VyFsuSJQcpimPcBfYc0M1YXwK9d3I8PhNqH2M8FP92kOKAd8BDBNoqvJVuH9xIAsCnxge4LGzQ
# DATA mdVdNZHqYnDmLGseWFczGM1RsWdNN5lpYRLxCzmL9BVftQ9HICPri3nOzDvQ5iQzMAL421lsXcIXD5Qg4yOZo5aCQQNLLAuEbXUZ
# DATA o4Lh/tas4OQNcruFRslaaMOBA3t4w/GZcogpursvE75bpsMlV+/e+tZtC0cDnxXEfZ+WQefGaX+SY7r4PATnLpxDGBSurjHAhuib
# DATA UdyWDA9HVSywEwXmE1l5yREL8RB87SuB+gGknAO4WID0MxjKmZvom/ynRweQY6iDQ++AI1kb/3SOuISHm2IWXYSIW2RXiFH4jsfq
# DATA EW8KNNWT6F+DvycdyEho9yvay83zqmZJ0B+oYaidyB7PedRo4NeUUJahgk4p/Qxoyp3th4dadKJpJePCrrS4SYkzyd4mXxLipWNs
# DATA oE2L3kTY4jb2D5VI8LOwWV0XVK2iwFp0btv9xKDoTdPucYdxj8WIUD0La36V+d2m6rj2yhku7h1uFz3kk7CxJd4jT+r9PYuiuVK/
# DATA e/Mi9rtdve142Pobb9HfwYKTcqWLuAxU7TIZ+mP1B7dKewJFIogGhsIY2a261syP46I0Z3R2DomjGhyqxqLas2HfxEcWQC30UnEH
# DATA dEBqryV1YJScpRRzo0xXIkqhQ6PqMhWVTo4Q66VYVS4jg3UnSCe1eAd1h2rA57F6PCa3InbBzPdaNxE/cC/2YtMO0vz4+ZB9d6JG
# DATA Nns+RHQ6h5bCRqRqQEWHGN4gnwBEdtaNYrNZTRkYF5UAzUASSMlLYwlOLIBSwK2mberbu9PS2LLOhkBkLLRIQMQZKw/5c1u1ekW0
# DATA jArBf3UhUGTk/VccIDOeDbvTGcFUdI/TSd6O7/3Rj+8/qCWxVxuYWKZZPgafQWxVVQ91eKWglQyTHWBklXNTBZepGhZjmD4cCttJ
# DATA /FPP3dgHh1csOc990kWZVB84y/ZNxvP9N6jFIEwz+P3vnd+L1g8dHk1A5kohLyEM6D6kVUKlhn5mKqb4CAbv5We5f9Ms3SbeVuGD
# DATA bkncJXca+wASnzN0Sl0bBvkyv8STwn9b0k3dxlPVVqeK39eZfDkAC7Y54zKwF/shbehnthEj7a9pUjg7PO3oaDZEkTI530136Sm4
# DATA Zvk98HuKFjky0SMloL8vN18g/1AyOIzgb8BvBu3QfYZ/G3DdBRJOvVNHbFpaFL0ysawGx9WJC0LTSoMa9jKYRTEiujId99FhDt7e
# DATA x7e8uVouHCvOBxbbhx1IgyKVDnz6Htgi5ef4Tn4GRXDd8dM9p0Yf6pTKt6ObFcpxM2Z9e3FqTMIVruoFrmCGsM7EeKodhj1W42HA
# DATA kjDjoIHqZsLcxHASYg/gcIGkF1XIZrAJ46g4GJTMnLfQOXXidov6oZ5jJLLJKH86gVmb4CppvogLU7jM44nRIrqU+NJxnzxBWl+d
# DATA 8DudQKxLr2MrDwm35tQ6pYPWikKpolzso1yrBftoRkEwRpgwjQO6MzIckdTDVFwMog7jaENCFAJePwo2BADlLOgb4dgPxdZIabwo
# DATA 5kaAx9Cfl+Ct9cpdSYeAGofRUYhvgZd13aGYbSdP0bVAp3jKvAAZvbR7bvECMr4U/MktBAGbNTCwifI0vhOOxmKckAu+5yahvxau
# DATA GbB6tsJ5llSRrAnmOXLG4Kjm5PI4AJM1aopS3elCOiOF6SWqrAMFQVNZ0DvP2cJ6pSyoKBnug4MoG0Mo1xs2S7IhkyTaSrwUADup
# DATA hBt5hKDde7ZDI0JXi5eCddZClcaVxx+5R4lg5m5300cG/uGzLA4RdpNO/CXpzu9t3kq3gFxikwMT+QRdvPOukkm0omWp2Mvw1LmU
# DATA CYE77oGtlskGOEwMR9728tSLZI3NNdcRXoc6ZP5k9BJgc4zml7C6xAMOynX4vISIqINTjL74jgn7su0qOAWzwR5AX4HxJomjeHGB
# DATA +m1fjYamP81KN4VpG7YY9bkdSfgEzrrJxaTtuCAO4ZRoacgbbG2eg2CSVMpaHBnIeanY15udRsSOMsPRMgV8t6wz0Pb6Akk3Lqqw
# DATA ijOk/VO8hfRAQ8RaavGOvyv1WHC4jo69EzsSM094mMauE4+vIXPRJmkaOrb/tbjE/6nE0yCee5E8jC/hjTC3tqK3ghP7l5T7+4ID
# DATA jWFJZsDtwiSE0Bq9PVtY11rB1Yd9OUKePmUOSUmyEO6jt8cfeq5RYpdrVkCzvYzfVW5yozqn8Wrsxdyne4N0WErzNFGsC1q3AMFc
# DATA 0pEwfnpFoTYuiILcUKFJx7BirHwg2LIxZTIa91G3BOg4TdCbINZbDX9qGMhmT6YGA7u0EnIKtXJd0sUy7FgIQeRnDccrsAFegU2A
# DATA Po7J96Ppon9Kp7+IO2F8VOe5dIDvm/bgK/coYSgXH9aF/6z1xzZXbQNxEQjVQv1Aw8+YuEl/XHBBCaltynxPbG0oY+p+gI8MxGZc
# DATA gzB2MFmP4U/UMlAJkUi3ScF8ybxpwVVQo2Xb2SEvy3l/fNGEmLalYjpyh6Rj8Xp0e+Xbd+WQDWc+jA3i0fOhQTl6OsoZ6Qgj5FVD
# DATA UeOwGunI7ZcktEU8FH/CFFW76+GiaKcsIPGTiijE2ndaGIj4Y4ZUSCIfRsUGhahVv4iKDGAiEUZu377F4YsRK0yj65Nuo5uqKtRw
# DATA vdoaqvh1h3KDQU7R5pfppJ/iatTmhlCqbcJd5Xm5iNz+VPGsw9ggQGDyKrbvUlrbypGolSp2H3P/duxeglOk70u83fVL/6rlkI9Y
# DATA rUvModhAm5Lz1ToahnSKeb9JO2GBzUGgEEAh5h0np4fttrccTjIw2ax7CP1JcJTp/aCHEJ4vyZ2xI05FxSDKvAnRzYop7lEleISK
# DATA 2RMqehpgsOD0cpJOgI+CJzLRD+T2yBfMHmvBzvLVEPmxmuQuxW4fZAaKOr6EEHuoxAVoknhjlaGI+qO2oQ5sHPYL5AsYnO8jQOWI
# DATA FyJSnHA/wVnlnsD7ROSEhc+CgqsvogDkXOQLJ2WGuONsMHYMlY6rg9WY695z+bKLS43euxaSIILj8+FXAOEIxAAKF3bZ9WoQRNUZ
# DATA VF/T4IIVXAIm0aktCR0cXqqSaV7wtkWdXWCNg20KLxZHGi0V8paW/q2HfCmF1MGoa0LCGYHysDucDshwq1522NVQtw/P4qJLjilq
# DATA siQVnQ5NGfY8fLi9vrarHQ23H32yPc8JEdTkd7Wa3HV295wGbfu/b49B133zsq6DMGWAba5nTvqZ4To1D3EFpV8lPYf56qx/aouf
# DATA gYNQONodAujBBuVMW1iJ0yG3e+1in7seIvpp0PR3hfi8cogPjiLRB0dEzeYtbKkPgTyGyHhXlLqWikI9rozMvAEfSrlLXTVM2ANN
# DATA maL4FGRTC9lX2pStMQCQeCkvG+3jWeVec2W7zVKFfltoc6R2zZiPlgqv/OvrZVygLqFyZbPZ5kg6lBXVrEUx4551yX/RV8S26EXn
# DATA oK106tWXd7j1+2ucFCet7Dz5Pjr3NMjeXmFoo6Ja2QwBdir1bT8J2rHx47pNVLO4gdDfrD3fgC5TUfjeBtW6Eev2G+JP8zZP9Qaq
# DATA 2CNVE1m5F95yEssnsnwyA70oY/3+riyZbzdsLrdhGUVKvTAC09XIM/cE1Utl0XvDWkxo1N3pAClzP9coVA0l0KFycT5OtRDOBOhZ
# DATA HF/loEq9Fzi9NkG3+SI7y2uSQ4Y4RmnwYGCYqWp+2FD3Kkj45DZuA2FUD2rzdHV1r0PBPE02j8vkBNVoS4H0S4wZWJL7RmYVayLK
# DATA ur7R1/BXc31za31ztx6ZX7vrT57ufmYerH+6sbNbldConFTSAfAsb7SAitxTJKxxniAULJOyQSf0cikoA68B+peOHpUsvG7QDkhH
# DATA TwzAnnwJW12BLqDmC+TsQgw+Sv8OMEmlBYCKF0LxUZj1XkmZdg4wCUmmNJd+WlWslVLB2myvXiJY49/5sj+a5Z2Au3nwkiOj0lGp
# DATA Gi5lJgcVeucGKtQuCga6y8bLDEXC5MRfavcLrNt5ZZ1lcJ1L2rDeLQhIGmm3EvrGqR0UTQVZzfOjcdG2IbmYwUxd0hpMhOF0cLrL
# DATA MbrdlXlLmEcgcGidKNyS61EwFAMo1H7BgoDVuHHd5UBmC+xYgX0wwtCcc4pBxVp9NCEZr2SBgor90/56lK/HmgcLiCJ+ZLazh3x9
# DATA gV9bGEjFqcKPgA7MPW6qTgfmodNxT1XJx84qCXzvczaTtoz5Ls+P6fy09C4TNvZWJMHP3PPWcoehXtuj0hJn5KLQSVLRGWXcVXhn
# DATA sWQ21Jv8qiIE4aZKx9xAIHeB5XprLtht4a7uXmONVhyBH5sYYRSCG+ItV5mwcWHppNryKsLwZRd9CVZOmqY8jMhL0ig/KgNc9dXV
# DATA avh7SEnKB1gpPM5b8AClW3THlXwqsZKcvHCYAu5KyeHwvZdojKBjnexoKMbQoHHf8fgVB0GoAq2/iPk49hp03lEPAv6nDfZKpe+A
# DATA x8R14fZsfqBSCeMq+lPRiMFx2q/odoMbrSyChKUxJk+eYtK4lcqP1V3M/xQSu4UL94eoxC58UNVAQSFTNlAnAkmneqOyoXxvmJlN
# DATA oxe3zRIUr+HI/SnrNhHqvZs3MQU45+IWEkBZeI8DVQQyZKs8b1m8zdKMl0ck0GW5rSSsOEnGMtgPvxSykCsRFFBC2IXfitTFIfl9
# DATA 8fa0jJx34uO8nph85hRytkBjcPVxTxcfOtc7v7i8WIh8RN0+OH7B9F2ljmye9mS+BuWdaFECOgy985uOLF0iQhc9sZO3dAdz544x
# DATA l/ZW9r10gY6XMkJMYkvIk1ZMhVYBHN4yup3iKVxwx3pk1OJ2VN6Mwsisvs0H0MMP+68g9ED1uEGLKqA2Xo4A4h/Ucstoq5woNp5H
# DATA aXcyyi2C9sTihhfus1/DHVM3e+kb8JX7BvMhLF2OsWxRa5dj3fJwM6CiMnBkaQdi2KOwBSiwk0gSCDtT7lHgOgibJoS9FtrAzBs1
# DATA DvGhLm6NBhBNaS9D5tChNkXyJ+88mDtrKRNAE/uc4xEmgZdSO/gE0iSaF9SqMljb3Or9kYirPQY5OHSI9WWVZKy1CGXVXo9XTscn
# DATA K6u244lZgoISh7ccDdW74brOuPVwMEkFJlmwvHWYvNxtF58nc7YcCrjeRhPo36V0XrtfLEi4390mLtX82oPpr0LlIOajl5XNTblf
# DATA /gKa35LzT7ead33w56ndSjQCJIYX9rQHIIuhAVjEKFP2k0So68rnqWJvoshZdjHzNpbMKlLgE6aKBbI+c6Lnb/zhf/+K/4deWnDO
# DATA v6Lcz3PzP6+urL6/esfL/7xy8/07f8j//HX8z0/KrH/n08vlZ+6CqiUPZms+TnNIxGx+Tk8Gl8zbXI+ezibZU8C/KEnjnHWVOJUH
# DATA Uzefmcczdb1QZPHh2u7a462POk/Xdj/WopZVuFuTbGzORkeJXulgdEQ+hOAqpuvQOYtvcsJimbf4ydrmxofrO7s2sTE4quIrMKE+
# DATA XqOnd+kRRo7pVMd3bxfTIkMyBFE7ml03Nj8y36j37gv94d3bgc6ZUo/Wn+I0fGtpZ1f1qLO59gQdOZsmnQkx3KU/3nq2vbn2OFCg
# DATA IXJfcWG81ASqIrfE7fWH6xtPd00BW9NB2n0xG3MlW48fdXZ2n30AmDTx/Wu9EW4y3EAP7sN/o0E6PGpfz4bXH9zH9I4IhZJN29cR
# DATA Ik89xSCvBxzDcH+Zft4f6ydw+bEerveXxw/uL2P1EKGw8Wh9c3fjw431bQp/6Y5Oxn2QFBDaSOMaIazR7fcvnn9fbY2P1z8NlD1E
# DATA TOy7t6nM7tZ31zdLS926SaXWP91d39zZ2NrcQRCLJvQKI1a6eU4ZPemf/OUR/jt9NeXHKBjHzVdc/jQ7UEe1f6iErfhC7f7uIM3z
# DATA aEdNNl2Y7d3Z6LVzHSLVKcKo+RBqc+HTqqHTWDlpehM/evb08cZD2Ih/vLO12fnu+meODScMlOaCpHHfYSYIkbEVtO0JfRHhpx2c
# DATA TQtuIAxUF4Rf9MK3FsBj6whANp3RUSI/8YUGRv4oE0+3s+4Mwx1onQKeHIV53Nj83trjjUc4i+pui5QVv9HTgyTOQxP0gv1tFuzE
# DATA yX0AMfqMOah+rX4L1TXx8+cY9oQvKjr2bHNn7cP1ztrOzvoukuA4cbCNJaGXGaTg+hWGOIZLO2FOXtNohxqZwIAeAzzBHR8oaG4W
# DATA 6H2ZEBoP+rcxHzRUGYQ1ghcwCecUctJsxhcU6TaZCqCpZjilpNeN2ndaitX+eDwZ/jidvfrxcDb4saIXe6uqWz8ejKf4R6IKPW82
# DATA byTf4V7Bbbu5UbySHXIvXCjoxITh5bPDw/4rtX1P4ZqkNRqWCCVXWNEAZmSnN8Jbx6X3nbOsvPceRDfv3FrgCDzaerK2sRnKx2OI
# DATA GdbYnEC+9zGuj1otOuz93jBVP/XZT/Nuv69+80SVQbhd5oTq7skzKjHSOKc7DbcqeTnvWbUlJGu6u3qh3+AuUaxO2lzKQ8dgsqGs
# DATA Jd065UEzTpLkshMfpNGgqi3g0jo+WO8A8FxvcrgDm5qaaqcdO8lyy/Y1hfTbbf0/OgA6TMeREpamimzCC7D7Tkn8hWf9AzWVOWos
# DATA QN3+6vbKyhyWjRO089mTxxub33U9RMP45NVY4nMak4uytvlQiddb226jtVFOjpSg8kDMPLK8lDcZdNSrRF6vQlRfZLY+2d5Av6yS
# DATA Idh5a4t5E/6jOUYdvv1sYmc2t3Y76sP1h6ofn126I+gtcXVo94V7qOp79nhtG687pejsHbI7CQRspiCS0lhFdOEom4PMMZc35IHe
# DATA TwqpX+3JDSuBOyfpi8wi4FvAfkQSu3On/LQgobLVF6gV1o6DEnXakYWmxu0KDVBsEjRldWisFsObfnsOfpNSByWcL2H8c/N7Fj2R
# DATA 1Fm1S4bHlrOjwn+QKXQOe21qkeopriSPz0fkL98AwsGHUty2PYh9TR5H4OlmLX9EFAuvP9jYXFMHB16GbIIdgeSPzSUCU19JHFl6
# DATA EsCNNSFyVGJBZH0N3SqOnH3kxr/Z5/Mw8/3TiFqJxxtPNnaLKPnc2zKc/PRwmk3mji6Epo/u1bbP/eGo7g1B/j6BUIfOkKBla9iq
# DATA +cr8oo/MT/NNhUiA43/48drmR+uPigD9JTGczplqeZvY5OF1zOKahV0zLKzlBgi6VlphSgxvaPxlaLxv0V6qzD/BtEdv3qIUHbpb
# DATA QM44FL72VlsezqTG3LdtwLUFKzcHPhQXWhoB6dzX5SiwpZDAVRl/qtUDV+T/ZdDwlxEBaIlt5y4dDlqgOYGc0++E3ldkLRHtJvMj
# DATA WUro8+VslnO3R9EyKY+wO9/ijXMciEnROSu4hgTZFq8J6Ia0JrkWUkqN0zMoA9yKALeEotqJAy1ooKvTvixyGyXKxnU+2djZ2dj8
# DATA qHgndbrLsFdt3W9fQWbxN55PCLfbxUIxWYl1s6Crgt8FFocNSdADncCXtQNcwIXypuR9+AIBT/gp8L85XE7fX505eaT+ldjaqvgk
# DATA HWCKUWhjT0D8GgRwRtMBRA200IJZhVxFa/w9n8s4e5kO4qQCeNNW0zwY9c7qWNXDEb4mKE5MBeIVa7qpQRS3fQdDB/7GY+FRdKD7
# DATA fttensXxpAYfEsgnffYO+jJJTzHL/aup0dhI9WxYybpzNpymr4K6VcWH1TReXs0a6GNAn4PqnPQ0YbwB5wgvejal4MVCF6m6oeIS
# DATA hRrpozHTB56KbMrC1TWwLeTd4+wk1f7fOakscTdBoT39ft/PMOO+9Q7WQjOlRajRac5K9j3uw37JSKCogJ91VNLwDjXSjoXtil0K
# DATA mDlU/XhHVM24oCzFPnqTrZ7wXPd7GKMFZijy0zchAoi2B4GoOP8FrlVsYw8q23fVpNZkJVWDuiwWM7+sXi/UnlYyem2C6cXL+sFP
# DATA m6Q8Nbi++jls9pP0Vf9kdlIG1C9R+T1Afp5wrskYm3SFoH2rmelcVbINoBe6s3rr7kqynyRXIDYyfpex/HD2aJmqYJI5wNtsAnh9
# DATA S+9TCjfWG9XafS/TQ/zAiS8e9BCxDbabG3ZM8oqIQCK8mmAMElmFXNg+PUL1sNlV8hc0BfF3Q90oj08MnxuzGyV+/mplBdWyuh+8
# DATA S/inT7yTOYgsl58gjc13fk5a6YsLpztasMdRCksNml2TRWV6qrqjCM/D9Y+3Hj9a3+4AuOb6p7teT2jmIMKk5s2rq8qMEUOfeqGN
# DATA MrQVYVJvr9wOvwpSj/M4PRjNpsaSjL+WRQMXzT4mAMnQkM/bdCH93Pb6v3umLpePlKT60fqOFR8d/JWcd6cXlg+ecEPwYgQdEMrL
# DATA JmzTbF/3ib6PDD1jIW5brawjHbitE27SzXih0YC4rdbt8eMNMH0Vzc+Ggu4TQSg1b3iyvs6jd65IWMtQNU3UyAewgj8kF5ILebcJ
# DATA EvTUed636jD0ZyRmhFa3ggUfJqylj4CV1sURqaOzhcY0pGrq0Q9noyn78yaGNBQOjY3CzgS2XgVdYldLSWI1leKMG7xXjA1wPtlw
# DATA 3eLZjKXnivjz7KSqwurvryDHba9vAl2QYlxo79DyofeRmXc1F2qJplphS49B/mOrKi+zlKm8bWKw07kmTThcmSZgdPnu5tYnm0RZ
# DATA tWTldl7st3xPV79vtp4x+J0Nu1IRJnRd7YCuazEdRbX6ivbZZfRhQb1zUHOBiiQYUkjhEIwJrlLayHBcEtkLSptLaLM/2ZaDdcJa
# DATA 1j99+PgrV3Oz6gfCYUqU3az8pWHjhcR/dTiY5cdCnjHzXdAb8xTS+e05Dga8Q2siWIA9DLJhrjhIB436bQbsByrUAVgYzrSVZ2oX
# DATA pGqZ8nYtrgNRbsWJTgiTFG6d3A/1wUm/y9MhO1OycnBiRpMUc0jjrhVuiMLRDqeqAdCp4MvYhP/cVsT/OOO8QryFTG11f0YC6tsK
# DATA zdvix2+OmpDXTrMY0b9iutVwuHroaz7a4pTnk27HObvqIOXTTslxttSoKV8Vzi0TTGqzxNDHwfimnNkJ/CKo/Hcm/N3Z3wzQXaXd
# DATA TXSMZy+stlQnDe5+Josnx3zSKChcspBJGB6XZxI2totJ1lX3PoGRPh1NUadGQZoAqMnptbghdZMT+bP4fcu9BU0gsHyMZJILNMej
# DATA cS3xNrwu64YlOWzEsbHM4VSFFaT6Sw9MKc+i775SrsWZl6lRnbVZdAYy7YpffrINHllx6MGMzovlffbyP/PGMOmfPWdnUD7hEj+I
# DATA ir7MrVLfprBAtru9XjRn+mcKsNBx2NEyjQQXKDwEsjFRKUqNHswKHQ6bypTc1H+ZaTagf3emoxrjQUJYl9p7taRsAqsdXXAx38b/
# DATA p8xqEwYfsQPDFTVJJ2Ibmls3o07Kv9dHWX/PUhLuAjAxh78shz5ZwOZUYhAUgLGeq32D6Fer0rnuipvQUsf32k5XSkv3+kdZDpSa
# DATA 4y+a+XF6887dWnn9X4UzRBB25i0cJEL/u4TTRMnavkNHimvu8qDfgn7QH47wCDp+DPIL9TNpzfXNXMQtofwc2qSVbs8rPyOGaz6e
# DATA 38cDDrWXDiEn6o4KSejv1m1NyXxXVF4frLG1UKbXt5kge3SaszG4VdWw4fkf2ZltkJ53ge9ISWUmaPUrXvzF3G9KOvq1e9+8y9EX
# DATA 2A/izFnOUxwO7wF1taK/ajKAN3i1LxWbLuGowBKyR7LNJU6ryFg8ShLZP6NjQbQYV8li/KUlOKXjRR0C/vDEdcfcKP3titFuiasc
# DATA wrwjqlfcN7rrc3dD70y/a1e0ZL7oD0mTypooVKaiKsra2eC1utsU7W1Xs33ax9g4PvThyhB/IJSy3Bvinu34IhY+/5NCeInREGJB
# DATA noh9nDX3UcCYQwVYIWvnvjAEY99yPgjYuUrbwNXwxvvx+qfFgWK5hUIQyDd916orreaZ5aP+MHI6XDSMhYxiARs7VlfZeSxxKUOk
# DATA 7PkCjobAcBR5UFLxYHQGsGUhraF9q+4yJk7TkYAxQ8wEwy4DG7jxclUncHIVSVJ/SVUU/JLWkfx4MQzFuAjPnTeDBHlYH25Z+vuy
# DATA FkEYalwIrXiaTRBAkf0/SkCSw2zng2c7nxX9PJxbvZRtJaJQlVAd0NGFZkhqI4bTOAAmSVHPJ/nL7mRaeEuPMSBXySxOZgp+9Vjt
# DATA jA8eQzqP1UU0dAWIKudqsUgSDDUv4vfmB4XFqkayvswiXT3TRkf1BaGna4PsEOLt+kfHU5fR5md5EyixojUnTqoexWBnr+IknASa
# DATA AKr6B6wFpoD65sNHjx9znoJZnnUwsF5A6RzOhoz+YbYUV0GYj2qDpNObalthUJXupPmqMiu100AznRxhjzDZPfWt20EYR/MLHDY6
# DATA Y/FgzuuZer/vtgKYMBDj3XYqKepHYe7xfgh/dLSuV7+lNYHX+FcnoETVLdacClAwZpU+vKAMhnWnGrcUvtHFblKq69Icwwx23RPj
# DATA U6tGi2qNc1gAgkgN4vrOZzsGbh1pmvm19XRza3fn2dOnFxVrSAeDD0+tiy6qoPlTfNQ8sSYUhM8np0ZQsORTdThgphzttX5vd6Jm
# DATA Lqa8pxYWb0Ka4bA/xTqoV9Z2N7Y2SdeyI/LXLnzIAmdk7uEqPT1zT1BwNGu7W082Hna0AVjx286zzbXvrW08Bhdw6cfztRy3RY9c
# DATA 4djRspNiBv8sHD25YaCY+N0pMRyZo+hVKY8ZO/LyOStW6paWe40/WfVhUW3wZNVxLK7q3GNkAJ5KGTTaslCoDB2zpSKLvdp+IvMW
# DATA z5w0Cninke1J17Qrc9Nfp442cXufGJJBqB2IlCfES9fwadxOiFCI8P4gFCGZGmxlupfLUUyt5TH8bYRSuM459Ea31xaVoP8jPQex
# DATA 3688Z8OCLm09Pvj9gsHCH6w9/O6zpwh4WhX8TNlnCsJ6WAUwAvBFsNQpcgfeYugwJb4tWKKDqoFJeqqv2SV3BOd2YBFhPFePqpt/
# DATA EZlf5Pq16TIMXL91WOpmStJyNlA66R6DXaBVpn/gAqqvElOmQiPxDnQKtoNGhVBnbLqvW5fAeDkFlQJf6m1HsYbijitDxKgGY3Cv
# DATA tXyIHUepPXlRL6oj9ITglO0XcsXWgtoBLj1fPcAFk2RxDQGd2FhKMnZn2VPgXJIp9MDfhrJwyeEIlk4CiSzMhvVoAXj6y9ON5C49
# DATA LZJPFFuskocnZp7UxeTLVaoWmxD8wVPh2XiEkOaCQiIn4FaTOYddcJF6NB29yJQIORr06tEwO2VcxTqzKIkRodchRNqWbNaBkq5T
# DATA 9LFo2hHzBIuwSMS97CXMqfjGfbnQrZTmGPVhn+3srj8RMqDeHk4TarPUBE4WuADhFAm3Bi/Am6vBSPOVFTcap2wlhRonvKVNkEmw
# DATA pEuDjdbaENFWtKrpaKuSntULwpckZq0AJdOUuIVbpvg57f1W9DZHSWY3IZlI8ye9z8hZxuGh8enpKYWdwSZUZCu8U6GAenG52GNm
# DATA iN784r5Qf/MRYnmJc7WA2CB3O+SOGPR42pQ8lZ2qv+HAOVMIZXbewQx6tepF4bMd0+GGB/jHhYybMrsJebN2vfUw9m5EN+fNoPlC
# DATA Wtu1v56zchLwjhwygxBCJBMd9of9/LiMnjl6UL5BCC/X7AA2vy994c6RGRWPCkUc50AsEaIMImPUIhSl0HRQ++hSVOTbtPt5NImT
# DATA 9IBe6Y6gmkTVEAgD5uR9VK6up8bXPy7WgTYkbzsVb3CGKho3qj2uok6zngSilelG5DIaGXHIi1y3+6+QYDDPgzlm5m0lquYH6oQM
# DATA 0VeudM9KlSQXL5r/9IsrWwC5gnrJcXx7sZvImUvHmGoxwaoL+mQkcUtO3p1MvoDZDjvrCamI+Fi0YlHRJCy7i8Hua2R6uQtCknvx
# DATA Eh2SphcU6MMYcr6ED6uwX4/MD1qEgMgfnC1YvAUEeixWeomgRV74FsHFTavBWCkPWs1SSYnTGetx6zovc+PY3V7b3Fl7uGsjjDTw
# DATA ecggbi81KJWW3p7cqwNXRKrPRfiGuzGXLiOMBj4VbMeKiJazzOV62auxEmUxqlHsg0L+aWfRGZudLp5wbnQlb7kunUXUI/MuIt3Z
# DATA BHVY7beSodhO9FJzJ2jT4Xt1/m2XP9GGScj2BOWNPwkmTQhPZ+Eaqrtv7pP2vNvUNgPcLHbe8Q3OTFt3YK7an+bVFXUpGaQgOktV
# DATA gkiVLknuDkcMuISKgOvqmbk3ko1RsJYSJ6EHnvSPMIDLPVrup0uuUbw4Lqolqd70l7zt2zN2lDlynF5emHVKZsUTEbSDmBsRj1Te
# DATA hsJ9vEI/rdjotlKP/APgi9LhYwL3DW+U/IG3q8vHbrdl4HqNXbWNBmRclG8DwqjoqQ8EVyqOFkz11L6p0924l+ikoED14nmooEX1
# DATA 4JHBMeO8y+02Z+LFElVoeC4zlMAAJAnEDi7GVdg283Dre+vbn0EY+IePNx7uxkkV3TLDnX+8isMqrmRxccjWWUKyzGk3fcJMR/zx
# DATA XGpZOeCvkzdygWuG4bgpfcu52EI4pwHeND8dn44Cs7JE5RFlbYQtzerPpFT4kcY6nF+/Jd0Dvq5JC6G/FHzpO+c7CCuNNPsM7V2r
# DATA 34nio2yYTXBLqg/1OfH0PsZTsWUENuO7OEcYudC3ZHVJnvbTAUVI69PquOHww/I4NOOSEY76ukxsstE5XCY8WXfwHcV6OWoaHWNx
# DATA +fAuMn8YBsFh/uByFQrcOuxPMMhkCImYuITvL6Ht/Fi0PO2vtyj+lxYRUYJiwLWx2HS193XBQcYL3aLmFg3dCoWPvCXgchEq9wHZ
# DATA BJ3IkmvkbquzZCQLDrSgzXMWHKQnMb+FwCjWbxmyWFFVKCRssR45huayjjljR6We/lVQxpne1ovgeMnbjiAULrxIHECVjyEAqWWT
# DATA lyFfXheCT+sMfKbq2haXSiaDlZRJsUIRosvMAN7MIBN8bDoHOjaSUcGAwPHzIrCPGEfAGvLu2IHPcPiZ4VySZXDWU8bUEDcoH1+j
# DATA HU8U0RydYHwIxpxrcABxUZMmyEokDogeB4UjV2Vo08FoNAi4wutOWLWYeUReANQ1c+MOBgQYpJCF9VEA4bO+Y4Dl7Jo5DjuOwc2e
# DATA DavKCbiY82XMll5UdW3DvwvaazUrIcW1E4JO023jXLg2+O1LBqZQlVQhCVPwfGIpeZVvl3tGFWxDhJEIPRainHMTWRL2ar9VkkXK
# DATA 3P91ANTLjNU/ixirTKf0d/5lRUxykHovQDIIYaNAMczdKxjOJcmF6Z0bMOPSBFFIPN+XZEIU4Wf7F36sh9xQV95Ai22iS6kdA3wg
# DATA dM0IjCKsQi0XmxfvPGnrAvuXpCyaIngLyuFzp4Gy0Le9fdelrb7YVybSr0J4qPufmzdO+F9pByq3SuieD88YecmZjKtMdQXQE6Ft
# DATA j/pdciPu99SH/cN+NkFTjvjJCFC6+7X5m8TibYJkCk9Ede12kY8nVpGZZwOt168tyO89ekP8n5P+NWmINR4pQZIZltkWLBO/0m+c
# DATA m7vuURAO69KQWBIw0sHF0u0IXCwb2/8iAwnCx/Up2P8DHLbSC8CXYX03IVYSeekoLgscOU0n6oqD8d7QzeWoAI/BnIsKNn2MEgle
# DATA hCVMw75fqwXFun3b7S8DdFgkuXMe2w2J8cMQgoqsUsruo6w5ORqMDmrxjThJLuqAxdcepCcHvRSLtfxMYnWdJYQiBUKaWB8hZZix
# DATA 2qvorFPhDOXEr7bMJrWRrC0tuYbDnjmisaWB/jwiVwa96Sjb5u+Di7LW2R1Lel44hNJx6jEzVOLZs4hqLujZ45ghjJbmWsADZNHQ
# DATA cqnrvqwbY8exT4pHhWyCUnpiqteLhZQY5C1I4GK+5wSFrYBfXZnwVbb5HNkqMCYrVemZkkKVRjfE1N/FqxgVrBvFYce2Vnr7CoKl
# DATA F78u9zIIFF/43vTR+ub69powF3+lV6er3i6sFV/0iEolXtwEFxVRIbJRDfq8oH+ErgyDcC4VPREverEBz6LSe2TiXBmryoX9n6oA
# DATA e4yfQOfp+uYjF+/WWjNKZODLKG6KhovAhsXxLegTwTUtNE67vwOkkM3RJOaUW9xDjog0L55fiDNeU1gbBIFv62fgLUst6oG9la2b
# DATA 6VGv461L0FOfr8XU+HwvHBuPJJvwF8l9LVdLj9m/HHg9dtqbK03aaKxFWRhvGmtnrHt9ML75zqGv5mv0/VsqBVyFgDeNzsXCm7QS
# DATA t2Ss0+FydshSZYBg0AXWhvo/JcK+dPNYKnlxgo5QlGe9uTY5msFkP8U3NQH03I43iIFHB7NhT7HxSJG/dBABkdXsIkfCOJpNI5w3
# DATA 0GtBTgToc940CXWhZsAY76TcWC1uNCTuGugl20+NmqDsC5I2K8sInBU1CamaGaNErfyOZq8xIafOxfrDEhCwly5NGAkTU7VxqluD
# DATA ObrCZ7xtFu6gJs8NsYk0H0aANf4O/4Evc9wwSTBNNbxuQscL558OcPHKj64U+Bl3vOCUgy+dLI7W3K/ehNiLX0aLofo3q8Ar7W48
# DATA bIqWtfOqxvLDmepMHondiUQxOJV1s/fNVoBeePu0ME+OyOlOQN2ZrXrpJPCboKq0aMWfP892zhabL39y+PvUTmEvmg3V3QxmErYM
# DATA VD3LFVUtmRPHIhKcE20awR/WNCG3QNWsjCd9dSQE8DI1vQjyclJgHSvzzFgBXJBCB85jLMFMBf+GS3+xP0ouhntuG3AG8qm6zk8K
# DATA HVpVJN8cV5NwBlRtNsmKgOw3J3V/KWxFdaoAIH+4uCL6UKeDiqxOB1aj02EvBOiakm+nNeQ5asK+cfn/AVfB9de6w+b47Bvv+H8r
# DATA 6n93b9/Gf9X/nH9vrq7eun3rff2Mnq+uvv/+nW9EK9/4Gv43A+wI1fw3/nX+z8+9dn6d1FPXW6v16yhqXG/tnV/v9663rqNgN1X0
# DATA QR2V6/XrmKVCPX79t29+8uYvXn/x5s9e//L1r9782ZufvvnJ659Hr7+IXv9O/fXbN3+qnqknr7+Ev15//vq36mMh8EAV/6d6/U+v
# DATA /14V/knJV/VI/fsXqoXfvPlrVeT1r+GValQVVVX+ClpT//cr9fTXb36muvFT9e/fqA+pRlX8t2/+Sr38xesvmqp5VGFdb51f1zlU
# DATA VCfuX+uNEAYCk148eP58eB/+iAZKwmo/f349G6r/PLh/nKW9B/dPsmmKGYrybAovUXuG7/ENHFp4/LKfnQIskvpTa9Dg8Wm/Nz1u
# DATA 95RU2c0a+KOuLQGNXAl7WXvV1nU8nY4bQN9fwqcPqZbGDuQt60/PGk9Hg373zGuAhbBGPulGz+M8Gxw+j+9FNOX+w+nZIPOe9U+O
# DATA nCfoKte6F40OfqCWn18NFdOCwgdpnjVUX8QjAGVpkJhlnxZnR2wCr/9r0ct+PkOpd5odjEYvIkxXo6Tco2O4kxwrRnI8GvRyZIXT
# DATA YyUZp4otRvkJCM50mYCEyhFou9VzxZZOoizNwTwxHQFTbEY701nvDL8dTXr9IcAuMZKsEuhApD4BQEjsNW71B09BtQ3izSF4j0Q/
# DATA jv7drJ9No5ejgRL97i9TofvorzPJBjCMfpdGprp7CL+X01ztl3wZnjfzl0fwDmVKKHuiql9WD997dTLAVmVNuEr5cZZNQ/XBEjS7
# DATA eX7Jz9DOpz+jpQAI/UKRH0AJEOyzyYP7y1RQ/YEnAY4JpPvDLYJKIPhckgqsXR2WgaoS+/SiP5a9+SawLyi0o17A6vA+uL+c0mmD
# DATA VsX3B3CxcIZjTXtQjbsqqo5h+lLJKP20MUgPaFqegNykHvePUt580EJJfVsvswmcY6xLlMrV/ulnuSm3M07hAEf83C8OW9CU3Yb9
# DATA eDqavMC1waLLqj88qTBgEg178Kmen/ucmslOxRhsPfAFUabVB7vHqVrCMcjEJqBNbXH1t5LVhk1V/eqD+2NVLIvgW3U8zqLj9KX6
# DATA Y/QStLuQ+e8YDwCkcsTXsBooZsJOHTUj9a26NqM7nJLE1WmbwhE7G81g6eBjrajSR1e1On5wv9d/aftNpCH3d8bBbDr1Doy7FB8o
# DATA IVM3c5Cpey/g7fJEe7WAeXA07KlT7dS3yKItq77CPqfZDkw7P6BJv/lgaxKN+6pjs7GaJEVaDmdqUkajAUz3TZjuh+mgO0Nz5OFg
# DATA hNJ/lpJ/d4TUPupN0lOgOODXBzOs1stsjqg3ymgpe9kU0ArVDULJrjM4W6rjYPdF4BoEMuqOlIjeByU4zfpl9p8Z7zJsuAf3D5Uo
# DATA Dztx7J4otbvkVIDWl24JUK/NHaXqUwUf6LV3umITkcE3a0jZ/yg9Gd8Def1l2j2DDkX/7z9Fl+o/rZru9TIQJThPzMsV07fN/oHb
# DATA /4Hbz+P2tC2vwOTfMY+/Goufz+H/B2Lw75i/L8TeL8fdvxbmTjtSDt8w9H85JwgJ/nzeqSj9KM80B13TbJPUeapF5O6af8ohg1yT
# DATA 2mGODjkAUo1dbStUq/AS8RR0+xNkvqjA8yYCpwdFGs2Cc1SnDbJ0glD+J4ppq501qCMDVoPon2S96GDWH0xhBEAfcxqy6umzHD5B
# DATA aUv3T48AWrAcvavlgdwXCEgcGA0HZ81oY6pluC7k+QaODxOn2BZqmq1ZW4sCaQ84DKoXsYuwKA0UC+Cs5zniGEU7WfYi+qHaK+Cs
# DATA pY0Lx9lgjLoq6GSUHh7CKoFAkh5m0zMzws9Gs4nl0Tw0Jenk0WQ2NKLmATg7ZZNmtM6JhmBKYRyzMUgrIGfqXQh7PEcZRhWAFAoj
# DATA EJIUecihTDo4m/a7KN2osWWTKdj4j9QQUvC/0K5tUFf3OOu+QJUnmnZQ7el05r//5H/Leayg5UW/oLw7Gqt6UJ4Ua9aMHsL6R2iX
# DATA R8QLNbAzGDnXBV9AV1/+f+y9a5Mjx5nf+1XKodWyWwQwqMK9mzPy8CbRS1I0hxLDIepFASg0SgOgwCqge1qzE6HL7soObRw5fCLO
# DATA RjjCdjjinPeUVrRpSqIi7C/Q/RX2k5zn/zyZWVmFS6N7untuKZFsoFCVlfd88snM/w+viKZUUiMdKHtcqa2HMfVFk6jCdiAoJjCU
# DATA JW9necypTSy4sOkZusPkiMcHA1TFmt97OzmZiZmHjJSdZQOqMdixVoqa1FO5JYMRTlGlVo4ebhBJRR8nmRQt9hSmbOI/jKJ53qjD
# DATA wQC2/yRBYxgM+PoRAoqhkAjhJc5MGj0QTlbzPkz4viWXGt0epVxkyEvTohDoHBEeR7qToOrzAXqbeCFJoKDt5kI5tqTKzdVctVbd
# DATA KqNHZCwiiScUmMmKEU9eCgX5HsXYbFzKIO6B3XhD6WA8HC+hEkpjfa50GCKKNe9NdD6y9wBFkmJcjKhvUdWV3oPzW/ybVCll7V95
# DATA mrPbYLPTDGdHM/nWjP2r2PrXYOoXjSay97/zuJ88IvPlZ8DX9LmWVunKEzz0mCyeZDKp9iOaC8dJepBNKejxE4T7eBqmVBsO6odY
# DATA 4ThK4fo5OA7TvWp1Hs6jdP9wkEzoEblEdtn+IfqvA78zf3THr7VbnvyCsPYPscucuvyT6kkazg/6VAMfViltwyfhYwkmnlEDiReH
# DATA 0PavLrF1lGy9qJqMRpSgg1oQRNMn4cEY4Tzme4ZggXAjqVLlHzycUds9COaPnkglqcSz+XJRkf1bFTyBseYxR1G9S99Zk7+Ph3FG
# DATA w/Ap/cyvHk2iR4c0WhzNqrzl72AQARN9+FNqnfHotKral75M81MyWjCuHjSb80eHczEODignqM/0/JqPv4dSAgf+/JGX0ZRm6Fn5
# DATA t5LR6Dxmi2JOU3r1ZVWaaTiMl5n6Wb5UKAZSHtUTiVO7VT+kqVRG4cwT5l0flrLxABMYlSc108R07uRXHlvRpG5qlsmOqZXqoIL6
# DATA MVuo2MudRcO7WHT+yeOVhHLy7QCkiqkgDqhkMKoMHyfzcECzwYNaq6VTo+aAVDlGZCBkVbIHY4xA6tHiRa4UpWtSRUoXdYUp37uc
# DATA UrM4LV59TE0bNeagUSpUvovqvvys6zIVzROJB/XXez/mKRIP49Qqf7JvXURRJj/ZX6nDPJM+8Ov1bxcqXZsq3Ybahdfv796O86qL
# DATA mlvrWBVXV7aGTkQp/hXrosRfRTegpnmoosqfpRJXVzsRanbVbJzSl4P6k0JwZKv/5LGOXP2JyRArF/xuncKmyhb/LDpgy4mGqSc8
# DATA PzLt+yiNh4dH1A3VGpyyQjOp1+XuGifJPLOpM+BgOgil3P7tUJsU6gjUBSr/x1vLSKfOrwUtHapkIMUrOqJR/LEdcKdeN4/UvVqT
# DATA Hnky9ivjoDJuVOaqC68ukjk9Pval95PXYX4FM1kCqoC0jPFuOt8Lak28utKutY5PKq0avuxTj15vqpiqPNk/nJAlRFUCbldEQH6l
# DATA LoHJGpVqrd5o0aOH0/CRSoPfHowPVaT6CbXPKSW0wZEOdoucL91ppUFRCzjjETW/e0HUKC5BC9lZfDe/uSFvppd4KtcpxEY5wOKT
# DATA 3DKeIIN10tqdwfhJPD2qZMdHptYwCe3Qaq+qgoTLRfJE5sQV3mcgI7pqKsDF+UGdKnIFE6Y9POlVvTb6dBMRGaTskC6sq+WBi93l
# DATA NPYvTqJoxjXZr7VKVdmvt0y3YrJtXc19UmPvheRlR/KyKXkZrOalzrWgThVi7ThEc4ligrhfYOsB/5GGF6ihlf8+YXfIhblQbqeb
# DATA 3u6FMnIpr/5dmMA/KZseB8ZSOSw1yyc1eIMeQzyBbxzFj6Lh4c+q7IOhdB+iUVZ9lPIhiBuU08joDV206RaQTg5ZhqDHCAVPPqmR
# DATA SZPozrEqzMA2yq7Y69F/zJ419L3L6Sw78EepR/9u6t+4gXL4Xo0sB3oNp5W7WG3W5EXabFFDkLtH8dEyjYwhmV8dhOwNtcKpdYM0
# DATA b59IVa3Lr1VTiYvrQrf0vC9ttKYM/lLWtOp5tea719dp9TB3SMUo7NyY7Eyl7nul+2vZseQXedQZFu+irEPJPd6hLNNoTrPCvUaF
# DATA 6jkVyl69QiVL3UYeoye1QZgOH1sjizXqtHmoL9fCbJmOcIT7Avtiuzkq7/XmB5j9VwfjeDJcTSbfUoP7vFKbLmlS+tg2EPgKBYTf
# DATA 7crTkzw8wbZ82xrorW1T683nFnWyTfq3Qf+2YVqVyonrZ6EA2GdXbC4bDHUzwCCQUm8oaT6YLcaSJ3vBbN/TadlUEsGq1fakZvym
# DATA 5bpO3QAlC52EucVT1oBkoBn4MbRi1McHhAhfpTXIdbpo23zVswe/Th3XKT3xYpc6SpmpehzdvRRaCUNtntTgWzDWXnCT9RJv4sWc
# DATA VRNRjy01Md8u0QKDtS2Qw5LNgI8LnZWYe3Y/76k6t6UOqJTx+NFcN6O02kJDuqOTMR+WRG91QJMy7kV1jA4oKYtTk0YeCWuybb1g
# DATA Y9da2mpWzS+QbkX7ItdY2k07dfVD3FXlBRz1ltyPOYkf72BulOYo1HPQvCkeRI/tLCnPx3Rz1M1Dxt2aFApNL48sI8pEvb7DMCHP
# DATA eiGmGzQf3KGSFOqGZ74F+AabbrVB2GNKsb/26rsZaMVYenNrYFY/ZTS4z44el/wG1EDCo7J3REzbLXXTFFAgk8i0WGe67dVJ5Yam
# DATA 2Q9Ltq1uSStja8kuKHfhYhCoID2ZFOKRA9+aZ/lN7imlKeQZXXbeDMNsHBUz+MfjeDiMZj8pNKB/JXjAcLZ4Qs3tsfGDPWLT3Z4b
# DATA YX6Qv695QdO3s7K7qWGX3G7h7PQEbugnWBuRUh6F03hyevAWmVgJjcuVz157P+7rve8fJLPks9cqU/rD4RbbPOXlkMbheJJZ2RTs
# DATA Xh+VL+VxyStVdlqV7HX9Tq8wu+UmrCZRFzXXw+LoyDEO1MQnD7FhD/frjM4dDMByle/msbRan1UHWhhf1Q0FtwbPVHbzT1KPnXur
# DATA SzPRDdWhNo8nk2qanFxsZSubehHNTanrbrSZ/4RO3LT/puqgF3DhcXjlVvCEf9IFR13kJJxnZJWoD/YE2q6BPDAvxpXFUKZlnBcH
# DATA iE1hHN2pMi622VpPahSD6DH35NKBH/h3qj6PjZaPyDIaxGZIlov5csEnEsqZJXMq3qVfxbLNGmsWx9PCRZI+1sPuOltWarTu6EyF
# DATA fvKvp9EwDvcsE61N3dr+441OB9vT0Gij71VehWJrUTbJ6ujElUVOUWC6K9lk1xmen26cf5YaZQMzVzsri/NJ43RpcV/Nc6NLGWPa
# DATA WN0cH/vl66eQDSw2FGeIO2bLisGweVoejLSPsWVZKfrBe/Zcyq6eQcl81mbsar1oNrhecB5WtJW7MT7slhHXC4/qvbxwChOKQNx0
# DATA aqpZHB52T/3OyeVOZM38hztyqkom3XNe0syqaTRcDqJhdZpwschXah3r1sQ48O9UvnMgmz7oQzhCuwln8TR3GeXj/CEvisRrftHR
# DATA kNM5ui1KM6zoxaiyw0PsYy5NZX5YLl9ZqbN6BbYC1NywT/PTh2a2Ub7pyZPCiqHetYUdgvTHezSdzHjtE/vyDu7cOTk5qZ00akl6
# DATA dCeo1+t31AYvbCB6M3mEG+te3Ws36R9e9kWN92QDIH3ni550ZPn3lJ/zA3we0RDEe6Ya9caw2cPGx3tvsFwJ7xb6wG97fm/cCI67
# DATA 3w+ax359TP/tft9v/6zw8CgYNUYNeRhRLK6KZjRCRk+fyC5N5GkyzylIJmp/G9+Yb8aiits/xS+8by7fXac2P5mr9qLzQb6jx+wB
# DATA iIa8Fn5qNuBZWdKre81my2v0ml7Qqk8a9cDzu41qo97x/GajmDHD9rAf1VdztdPwGt3Gj/xOexIEfrXX8gKfHq93j+nv+wi6VQ+K
# DATA QUWjkc95zNOFh5z+bzVbrXoryi9WTdE3Vl6KULv+cTPwp/Vq4Dfxymqvx5FREfF8qRVXfEMQ1L2g6R/7QWPi+77X6v4o6HV/9kGz
# DATA 0fMaPlWfoDvx651qs/OjoN0tJq876EVhuBJkp0W50hv7QX1abdfpn2N8bNLlRrM79n263GrRP8f0sRTzfrtfb47Wxby5saaq7YtU
# DATA UQ9wsvCx8gQfqBp+yPP7A9VYDvXU9uBb7Va738AF432iR/h/h8agWb0SHHwr8qNW1DlUPraDb7V67U6ndSgWxsG3+qNBd4An2O1M
# DATA Pw/bjWB4KMv7B5+99iA6SiLvh+/RdOGTcEy2Z+U+bx/LqCusZlEa41ndpe10O7qnGnZbksmUd+kHYk16QdHp3BVDwNxuRiM1v/le
# DATA RG06DisSdGlp7rDsCINxVunUmscnlY44wjhgtVNul+n9Vv8WzVSLIZYd5baZpwpm9QHtQy+OE4W75gWrUkxOvgHjzyDGTqLHl1ge
# DATA yNcCxANYMovEaVW/nHHjwUVb3ohR9ArUNxqzhdRWVpJ2kXGnPHsrdYzNhpu0VJ6stvWfoql/9hp271EnEQ8WvJN8xhsgvb+Cvph3
# DATA 957ZAln7fBmlpw94X0CS7mX71r3m5vtpGp7WRmky3Vv/3P3JhB61nlV7+f4mOoX0on4GLbyG7YAUW55beq97n712YEdwGk1xOluw
# DATA Yx+E8z0O1LDCWc74YXRa8UbhZILKve89xoF/+q8EIDL5vKfsgUQCROr3KKv3rEi9Do2y/UNDFWa6Cr10OZl43/X2JBa1cZjhZft0
# DATA SV2hoOTKgRWBAw9HP0WLgMX2D70nOKo8GFOs1BsuEyIef2Knmg/VS7IVKvaxfjyTx/UPhyovCunPNqS/IvFGLZkdxaNTja0y2YIt
# DATA NmvSMsLh7tVIhqd7mDzvm6KIIFD7V3ufvfYt8fx+9hoFDbGhaAJEaw13q9MZdCO+HZaCHCcnG8MUY/TSYc6W0714uJ+n5sPltB+l
# DATA exzmZxD9o19rOjcLjw7VJtI9kXND4KJnQW/67DV8vUPNOZ4d6mMucsbltTz2yxTR/+HH79dkx+UP+HgIfYd6m/cmNPR+jHB+UvEe
# DATA I+AnKAx5NLQbkjz9ziRivYzPXgs5G8Iadv9Bsyad4JuOL1oTxRiXBpN48JDaFLaefhJPo2S52NvbRxtHpNLomIyKPFIUDrjvZL+q
# DATA rJCoYH1DlwJmE3i5nU/JDBua90YzJBxlgwdYCG8KoY93jinS7yutFQojW/anMRVkxYuOudju0WP8sQbVGPr7tmzM2lNFzQHRdJym
# DATA Qj8CvSNenO7tU/gz3PBERfWvEL0fy4GL8Dj6CUWyRg++Ew7Ge2rzJ79oQkZzFooYHfcuFCF8RXx+/BP1xn8lPWCc8d89voHeqJ/7
# DATA 8U90KVH+Y3c8dDn3JXy5fspKlnx/jUaVyXIYZSoaeYdIv9L7zCa5xX0tbY8Stra+IWoPuNHunUKt0zxTrPx453epYj6Q5FAHI59x
# DATA 3ujJoY7qXv74mrLh+oL36eRcR1bpzztkByVA7iKjmqa2e8eIBdjBd721tx94P67V+POwsu4OU1BkAWdIJseDu1crMRLpQhahd8uf
# DATA Mdlq9qEv50O9mbywgV/l+5tq2/v6Pe6H8oyExVvaM7WdHWdCyaA4jmrcwp/Iv8XqbRa8inU8eZRXcL4l08VGP5lMMQ9vLkJ5mMrQ
# DATA hIJCRCArNsBnr63byWdHi3+XiPFHiQAXgwSf1wf5XffE8m1dFeWTN3YdVSZIrpFr2S/bon2g4vIZJDynZHtIbTNR2FRzNuSnjoCq
# DATA Pfor2XezI5oMwvTx2Iz3zHvpYqmW6dayoV4dmgMV62sWqk1eb1Td0fkDc9WM0PxN9eRyA436NLdiY4xv0d/L3b00zfdEy9RkP2cy
# DATA 6xNzyN+VXPT+9m8p1qgQ1H9N9+hP8n5yEqVvUebtmSymhpCx+Jp+ZeFpspKQcK7XODFB99UPPatBIFOLlY4u2FWDRRch3kPX7U6z
# DATA GJu8JnJa9r2//mtvT0ft7l0dE0SKAzJVwOTb3bsqKai/uEWW9ejN/4qjIM2NP+5LWl5/XQpKGTtYOdTZz19ycwff9uWOPFjJD/SO
# DATA 9XxEUkpFUoa4wQQiv+2re0rDh4TFtZRjGGU8cFDJ6xJd0xi5HaEtWpUCyTHluLUBFx6iFyGOqppSJutA9os1Djcqi2Nv/+49thk/
# DATA e+1dcygMzeT1PZh9n70mTY/S/x35znNAbu6L5F1sq9sL9l9Hgv/372uf0f9mb+tZcpIs2NXqhQvPpxnL6xIAHzajAOih9e8h4+lO
# DATA 8db8XT6/6//8k/WgjtAOzw2m0rhlBpgfyHQHs93B7IsOZrsD2S/1gWyvsN1YnYN+rg9qG88Z/1w4ATixjm8/mLNaHka2eAjYiD69
# DATA nd/O24r5nNzzdZ77RTnVeJFwi+0o5fiLx/neG9TTlpuhXiRDNMxKRVfWu6wVPLkQTvhb8aB6efFKmvQgQebKm05nAx0N5ce+94OV
# DATA tS82U8keKB38t57hL5wOzoD5PS7aAyp36MFQecEeShen2FRsnp+LbkA2DvlErK5RntpwQdNCPo687NO45sGr62EOQmF+zvHgXUpx
# DATA kta8H8yjGZ/zHfHZfXpIHebnyupRWGPUOqqTnmxDYAwT7qY3g7FAAc2UbsCOyjteycetdQT4PDFHm6wFMrKPcC7NyPD8DY45o8Lh
# DATA dDcTHbyPlsbd681wmdWP5B0x/bScw2zIah5sKf4xY5MqGcHJQy1mCEtNNRsylxOWABgtU7IilqtqCC/nYVsTgrPenPV2kfVWrGFO
# DATA X8fp61zWbNtoIN6U7s4DbGGz5CDwGvg2IZxnFHiencbbtuESu/s8W66uYMnx+gfbH1gUUVty9DUubHRCYseyT0BnsvIC7k333xCf
# DATA qG6AM16PQiFJaOY5013lV9grxts/ai3eRKQ1rCn5vCEKF6ch7zdqqc0k0Zx3H9WkZ7/DcSxFVbwQpjrg2w4R1U+ZeJoLJpqNWvsa
# DATA oymeEfpZe2n4whviaFWR0veYSJmH3ki4w88jF+DN9/yDoP7GnURZheV7Wuqe1pZ7/Lq6iT7kd92RaOVJUba6zk21CkYP5s1gYUse
# DATA kdnAT7AhkU7pvbwnWKVTrYZi9NJVM78kPU98zC+a0zi9kBy4I0Fg/qRyS9Zp7VDyS3qHmrlyzzI4Q0zIrA7AlqZio1Ga/ZJSBeEX
# DATA Y1B+QIMh9c9iNGqvtdX+McZGM275bCiagTZOxY6sefeHQ4/PxCqzINPDZ25Deu9jDUWpemIiYEbaJWTTxdHLRqkY4tTj4I3YhUFv
# DATA my8nE/5xiWVYGtTjVBv/P8wiUd4RERvR/Yn7MWWxSMxrESld57Fgm3EUyCyBYcGmNHoizGviDNNCStJMOj+tcsX2+gTC91YvhzGw
# DATA H7FeJmcad/BSJFwaL7/VbA+AznB2hvNFhnPJQHKWs7Oct5vDz4Fi5Sf0Nm4cmWjmhUPVGnKzuaTZiMHF6LyxIuLDaEEFOjsSabui
# DATA 9KIwwZIRxq1ESUDmSomih1g2kkv+WWxXlFJQWxbfGDdYf04LOevGTjFuiMvMiFTCgsE+JegthhJdFsNORiNs/4JMH/cFmTdOTuhn
# DATA j0pIhkvO65qnjAtIWlLsjjHuop9JRtwxcJ5b8pXis+LkFAe9RcjezPsphquJGelMiuykvc9OuXBANg6ENE+ox8pThpG3ylMG2RDN
# DATA qNNwkvF2MVg6SOIR2WKZ7tWGVHhj6s24lDiZcsqHQpixqDjciGQ6HcncSYwY7S9LpmQ1LpS6YAir4KGnlUK2pPPt8JR74u0JRRmK
# DATA qxJlrNP4QPkfR1FEyRrGI5b2o9kdDDUIHGIPI/YhULVayBYMphvTL2iK+IVNQO8TxvB4zBdEgGxZMVMWjkGqijohxqLrL0+lUp8u
# DATA UJ+xSXRLIj+OsjUJFLOiUIVXBVVNVScrlf2WJ1CFRyWboAnyqJNG64xYFGlF25EgvIXDGGfvZKATO1WJSVLt/Rj6L0PKRLIL2fZD
# DATA 8mHnLcmY4CceisdVu5QZUobaPZV3ij2pp9Ja6nQUp1NeHFk3t+VEfUJ5I/NxMHrnOEZKZpJRW6cWZKznfPE7E/+13E/5wdWRTAE1
# DATA PQ8zsYW5d/I+0OKe1Lsy7IFNaQXiNj5kajwP2TzG1IAMXyrpcLmI0W2EKet0TZXyJKufSocCLpS4jclCwHU1pdiY2r+ZJSdSP9FK
# DATA qImgj4Rgq07w2wmHv8C+SuS2tEVK0ByuBO4aeWwTu8TyK6DxUyljS0M8MXCtlKcLKRU3ZR/ZSJRhkkIqchyQxo6McEVBttAN8xRh
# DATA dlpWkzXzCVtW1rLzxWZ+Ca39J08qhqGzOAKcNz21CTr/3/mvzv5w9s3Z/zj7UjFyvjz7M/3/i/Pfemf/DKYN/fBz+ve3q+ic/0o/
# DATA fEU3fYX7GX7z5/PfnH3p0ZffGYjO1xSoXOavAO388vw3Fe/87+g5ega3gZ7zDb3pj4zx+Qf6QZg6fzz76vzXOjJ/oVv+IKAewHYc
# DATA S+cFmM2gU8bxJepw+vRnURDNPooSCieNB9oEq3nvPJpPZHyecI8YSd+QjeM59RYTyxuhO0esIs6j3GeQz4WSyUSNT/RSLfO7FaqD
# DATA 5UQVnmopDq1TnN/oHuS2wTrrSubm8Dp51TG3wqTLL5cfmIjetLn7ffnOI/o1E3Z4XFPDeqI2t2IwdYCdHYvt+hE7WHuP2PpE4VRy
# DATA FyMbv8g9OGSyKCoYpmMaTzgfWW4/W2CmWtqtrJGaCMIcSokXK3ydi6vfZofmmpb1rDA7FyfDcXacJXATloAG7lzRAHhFnJu3Nvjf
# DATA yNi/09B/2ZH/dgZ+qZ6r+ZAzeJ6/1nUTMB4rBxjFU3z1mvSugjzoddO5WklUhUd5luKlCnwTSdZkKm8qnpLA9tLx6WI85VDkgAln
# DATA 0K4IHlVk+UIkdcQTxssssVILlfQFcnuh/LNyTG4UHicYFRRrRscYLxC4CQ+n9KC2GNS5usPcXhBiEXw/MCNOwtnCdosNkrlj7DjG
# DATA jmPs3CRjZ9dRZadpzq5W8i2b/Fex+K/D4He0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfb
# DATA cbQdR9txtB1H23G0HUfbcbQdR9t5nmg7QSu8Km2nM2qNBi8QbWd17Xkn5g7nrso97Mr0+F3tdkEhrdUs5Xqz3S1yc6KoO1JgIxxu
# DATA pOgNONBGm2VABhxqIMGwVIbfbBchPg3K8DVopE7TawZ1D3Qbv9Wb+N26F7RL1J6232p1+6uknGbDa/q9H/m95rjZPQ6C1tTv+F79
# DATA R369MW52jht+MQqDYNjs99ckotWt54nwg55JRKMYQNALhq1VYg9lrNfsBGOVixY9xzywQs9pX4GewzXWoudQ5S/Qc1rNbngVek5r
# DATA GI38nJ7TDtp+Z2joOYNufzTs5fScdrvld2+enqPqeJWrsRkXGkLQ0cNt4aZ1jqoGjyOV3vFJpcuWVGGNqTUYH+5M2im/TTm4bdeW
# DATA mBjqLhwtuB7cjh3iKm5HTTS7xlhFGR/yTo5xOExODuoevBt1T5dkAdDD7Xr1FdrtbkzzjqyfFHK9dFNhrUyG8xIM53DDfoDV0UpR
# DATA ktZ5amXddkvIqqtRQ5tuKHnNaJr4XexKVX3GZopPobQvsBELmWcXpkqMnrzACnGUHUfZcZQdR9lxlB1H2XGUHUfZcZQdR9lxlB1H
# DATA 2Xm1KDvxSOw3rHugxj+2v0nduatGTDVwyW8Vrov7h08sTM9jyTdkxl0OBqeOTDCv0xPA73z22uur71CV+lAPKOolqzfmt6gDGnQX
# DATA 27mHChL0IY5xSctnU35yyqdz9FvLUap5/06dgbcOpfHBM5Q1VSgThaq+gX747rYR/5qywtjMJqm8OFVbPFrkaabe8bPX3rdO3plk
# DATA UHepUiAT3dI5H3cE3R1B3/kIevFAmDuL7s6ir54a3Ki3+TycUS/V8UJrscVp2PPHArSozFmulqKEb+NhFGYFdAufiIayJchFPNJk
# DATA 1J3JOWGtpMJb6UqnZXc9g85JYH1GjOUszqckQelVcKHORY+vz7KLiN+aw6Bql9Wqfr2yXVEF+ZNSg1fC4frHXM/cXOHttpD/jDgc
# DATA E704s7J6s8q7MYhZGl0+FzXerTtM92k/taLQDosShzvRocl9LO66SdBddakc1vfU5813y/F6VrnjT5vv5D5XycwOos33Sb/N6edP
# DATA W0Tl5aCplnMXO9RWc8cQs0XLvVAT4D+3ZV3zX+Ct565OzwPkk87zcp6VxDbZrW96AbGquealS86Nf/mn/2jSUY64lf9zlihFnzMJ
# DATA 57n+qlpK5D1p6RISCbDREpZimEEJnrWooVYaUy1kKFM4n1OdZH1d6pjR+mgSO1vI8X/osS6gf6R1aFmrmhc/tMjsCVVudVhc+bzs
# DATA lpmffNZNIz9YbRxnuKySYnJGH72kC+wL5ppC91oggLJq66WKKK+oly2gv//vmwtIV3opnvdQDFSRM11An5wk1EZT6tg8fcovUyYI
# DATA 9UnLGTyRNCTNa957NMrDyJkmxyJIQWlgwQEIGxxF3K2igGT/sCqnSKtbqNJ6+lIxKbi1cjHdwmWL5R//6+ZiUV2MlIrIgQ6SlCYj
# DATA puXM1ERYLvM0p8+arqyrLJ+8eYiGNRTTQRR8R9SHJyeqiIp2JEuzs1lcGAety/ECRvTTl5KdolsrqLxfvnQP99vNJaX7eCmqT8N0
# DATA 6vHurryLO8E1geMMj6GFTSVzRAXD6xfo6yIZ7mdDkdKIWD0WOtPRDBAcKQE1G+hHTO6IF6LJgd2x9s9MnXj68smTcWul8zQj0P/z
# DATA z7uPQG9hkI1SGRIsHfAp29UUr/ShsrS5SYUTVi8PvemSxp9JmGKf3Bzyycho70diPKoBhkwkMAyk2aDEn74kCtF9EZrKf9q1qTxI
# DATA Rguvj2ofonTybg1jfJ+yaAotG2jGDGjkweSAFaHD4U9D7M9RNT5DYaVsj8fTeILzBsgpqFSQpf75Mha1GqggsrCKFKBWhL6GplJI
# DATA xpUKqGgEikfTNgLNFcnuex8m2veoNYV49qF8gkkqVEYM0Al34rpglfDP07CDXg1xFwfndq60K7jSnOfsFfGcXZbX/VyoOxb2X27H
# DATA dsucmwbSBbZqkkV5xE6tjeTu51QF8gUSTbtIG9re93gTFO/VVnLtLO+1MqKbiN6rKVe3GXVscb5gElTzfCOJzc6kiviORA3yJDGO
# DATA i9zJpKh9yiE8BZTbyPzlBV3xlpngSyELSMFgZ4QkIStrYa+pNUqfm+tkrqd5JS3wD+Hpmh0BGiiAcdHtMVLglrKgBt8ozawDIycK
# DATA szoXFbWVRD32mZDFupDSwrwH1reHjbjQ2zwu1AfZzCaZxdtVoYk6yxu8aBfq3EIO114l49EOwpmPznzc2Xy065pbh3XrsE9pNW40
# DATA Um9mHfYD4X7aStE58fDZkCpugxLOe39QvfjYYGGZU/2U47XVrSvrhflCUr48tmlt0V7esFdrNt1fcrSXlhI2PVVw/xZ82pueKLsp
# DATA y27WTc+VvWdlr+DGldNCKfAmK8QU1WkYD7k+yELTd9/Q8pWqWNS94JfLnlNhiatzppp0Xl4ExyFzzd+zLSpPc++pU7dtKnGZ6Vfv
# DATA QBHnTQXT00IDenER4lhoWjAJdY6ePlOWajKx3xLN9XgiM042wSM9kzIQSWo/ZrVqyaYChUbP4Lm3dUeCvsUenj0lEMITAGOyq6c+
# DATA hSUufY+sOw7Ftcz7yikmEO7GAo164k6yWnD5vHG90ziva/neQnA8dR9FJV0q4YsZ4C+PlWzBAVkKKZkW2ID/UUH8vjn7M/37p7Ov
# DATA gOH7ysM3xvJ9A9bfn8++BJRvlQ7438/+wsS/36u7vzr72mNQ4O/O/nj+f5394eyL81/Ss39UgX6tEIJfn/8K1+i3b85/7tEXEAkF
# DATA BAgyIeIgzwFYyNzAvzgY4Itg9Rf67lF0QrYDT6LnIaRrFQQAvfp0BPmIPiS7NAaEOj6syt5XWN2kz8wD1T33dael++zlnF+DJsTh
# DATA kZExEP9JtFjOtyIA70PqwhsuM2x2ofbsAIAFe1/3ErfN/1stlpuj/7GFxYSV/NZCfSvzzO9Ep9E8jsja0Pe/oy54UBkCQjtJrxkD
# DATA yOphjIReLnj8V2e0qIk5EuCuRXj9KEDqa7AITm1+Fo/Q6TAMniHO2C6XJo+goRPx2WUx5WGwohZS5zZYYAvDkqX/5cdMbT7Re090
# DATA RROXKlnizLjBNC4+mq1gAXevlpttnZWG96zggLsnxkECnYVwfRaCRgNeyTB4NZyAt2YU3IBNsJNJcGmL4HYNAqmi5ewwZsBz06pu
# DATA AglopVotf22IooaLsfvi4al3lIbDZaigf1m++gAZw+IaG6MGi4sSp7LpE0vzx+x6wlobyyJm82iAkd+YYjvBAc24zsrclOBM9tFR
# DATA Bo6AL+MKWE1GVVRO7mepDtU8qNji+GwolgN8dEzAU3FQbDUkf57SpYzXUlVpK/NNFgk5snyjyb6a92EEgJxckE17D5YwQ9JkeTT2
# DATA ljMqpoWcYecXZw4j6DCCDiN4gxjBnYehnSZJlzWob3WOcJUpwnXOEBxV0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEF
# DATA HVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQWfG6pg1ImGI/+KVEG/G0TN8AWiCpZXoHdiChbheb2mBc/r1A08r1PM
# DATA 1+Egag5Ha+h77cCm7zVz+l67tzFv84KZ+vWuF/gdz/ebXrfj9VpVvxV4ftOn8qKrQcfrdktYvk671+1312H5ClHmfZir8aUXWshD
# DATA v2Pi2yoCJutRe9BZ83wQBPnzjXqOTOzu9nxDXqnyqxXk+bXb882WFf+Gld87vr/VtZCPzUbnsu/323Z5+3n8GzvG364vUrb8eHO3
# DATA x9sdO/k27HHH7JdHVPLbvcu+v5h79R1efxlIpDQSDYmUvsyCRA464bDjFyGR5hEDiQzqjX6rV4BEBv1mp93KIZGD+rA+HBlIZHPQ
# DATA 7nabOSRy5A/b3dGNQyJn6M+r2cPTfJ1DjlAeR9ew7hBYrg5tc7H9YF6rLcKC6SMvo9kMpvVr9rCoDLeDqUG7qGjfW6HYd2orZzdi
# DATA ZSGietFDcRGlBPU9Kkse75prtbZFNfTsbFG3eXpXSzFv9KwV++QLjtYS0HHLDgW1H0HSUc3oh2l0ANHLzZRGkw+VUnK3mH7lQq5s
# DATA LS92ppgiE3twpZqI+RTsklMcgqNAOgqko0A6CqSjQDoKpKNAOgqko0A6CqSjQDoK5CtGgVyFOE7Do7sw9ahXxxkzSvId+apPsiAT
# DATA FHLxA1tRAK3qdXqa6sK72BC55++//tlr/+efakw8vL9WZ4Cf2ZPww7kcNsAbKZh9E06AcP73FxLOW2jxfHxpGs6Wo5B1+uVUl5xH
# DATA pOY8l6NvOFQVCnIhekQ38uFPMgcyGtoKhMTCGR13+t6dvr/g9P2aI1zuLL47i/80Z/E36nHe6Bl9UURM+CByftxbhpXvGn3OZy8f
# DATA cxtanTLaQUbVRGHEB2SV1bk3ne4rSqJuoTN2gOSCfjoI062ZC0bRstMqKklO45mse9WV6iSvAim9Sey34V838xTNoGxXlcvG2wrE
# DATA RN2+ZmIftNZFPrCi3i1EvF5rbY66Ge/tqOuLqh7tDaOjNKKp+gUpsMIyKbCvmRS012Z/w859P9iS+RsVOnUrQY2WDuJFVee0Rlzm
# DATA IdKdqbRmfcS9YPZh3rRY32ToVTGOrPdP80Zu38Ai+yKfL8UdZQvpSuRJwTOaKpGHwTf3TwXlWOiXtO4A61fo0KgfISNQGYiY783F
# DATA bBjGmPvxY9AQZkmNk/BUBh4pTh77My2scbQMacRZRBFLgythi8+pgyPzC0frlSjImhjtIOD58h1YL42KzrJ2lvUFlnXJaHJWtbOq
# DATA C1b1ZrbS86R8VWwFockvI371Q/D3jNoRVrFzrSPWk4FLvGL0mwRdHE3jbM4SNN4nhq7Cxjvr5kTwzJ1ETGateHrPBkalaI5l/JQe
# DATA Qf0pW9RFguOK2JW5j4b+d2MlfTRO0vhniZG8UQr+oZeFI/B1opSMIpZgMqWSzZNcIZ0lilg0Ss0iojA75ZF3nEwjiPLwbILsvopw
# DATA MkSKB/fSaE0DawwTgjurjHILqwhKDRxbFTZMGQq2zTDScX8fwjzFDhBbJ5RqD3iQeYdobKLlLGTDhupVzXszniWoQ/SMxuxqQ2AW
# DATA PVqwIclLKsgg1Y8mGdxWqodVJpBUgSm/zAKFrjMm1qbtb2wwwiQ50in8GCeapdykWhXmbDEWZKH+EediRYa7IBJek1Olls89fvZQ
# DATA alo+buhNkSL/mrH+6whS7ZwIrUjK0FPGhXl8Fgy4bWTvItuWqI9EzktaRXSqJLMwUs+n3IVJGkUVTORn+3l5sAMwN07DhREMy8cj
# DATA yguqsJRGmXAqPSXKMuxynWB/CVdlHKFJ7Qp9msE3zrF5RAEsyDiMh6DB1ry3E26SGP6MMhlE4JTBOELnl1qxWSEgsWV1oe6riUs/
# DATA VIW9tBT0zXqKYZKaKzJInMoFLbKvJmfF5/nH4tRLL04VplV1ngKp/izvy5hYIDU3h9ormf2nep9vyBOT8FShw4umSkY94fW+M+Ah
# DATA lHE9w3gq/c/1vgHbFO99qMcOpGkezQbx5Hrfwnu439EtSC+h2T3o9b6vJQCLUWT2DFHDY1tyRq2t+K47y8mNMWhfvvmVI9G6qdXu
# DATA ksFuIvXST6Qui559viSEzZ7em2CYljP72gmma5SOL+aXTgoEBdEAZjdkUVd4C173+dJRfhElRHfELXiFjeXaCM/lViVfzGSjtjI5
# DATA zqe9Fe8ICs35nAazMC/EBBhbrcw8dEBTYFs/VlRbMWnKFqVZae5NKHkStP0tArqFWkvWy3F0sZA06uQ0nGuQw05lsKZEP0oj9qgX
# DATA 1LCzKMs0q/AVMt1ywlU/fBilBbzVfzv7EtSp85+f/VkxqP7AmKsvzv8946r+l3f+98BMnf1uFW71n0GrYiAVOFY/P/9H7+z35785
# DATA +8vZl+e/pkC/qnhn/5Nu+RN9/yW+e2ffmNBAzdoMvPoluFb0X8e0ehFItlSH8TycDVTBWAI7ZNyzDBFkbcU8EgzhmoBcueqcMCcT
# DATA l8aMnRbcL40UmGcolxL0cbK/Vhh51HNk7OnairB6Exto0U4idBYOYGUboNIJ3Da9qlwiN8eugiT0sPTetcgqrmLmxre5wt0MrIpG
# DATA vbna9Itaik3CyTA85X2EVD8eRg5YdVG5XTun6k00Ay6BeZTirCgr1uM43ogB23L60iPbHVomahXE2oKn1/shln+URsM4gjcajALq
# DATA U6MU3q58OUX1i/GMzKGl5LA3XWbSn4kZdipU70E8j1YoVrvU1M32TKnpPSt61S6JcNwqZwVc2QrQmKorDP6vhOfplgb+ax/3dxr2
# DATA dx31b2vQl8pYTL0Z5J9VY7kJ+lQxid44msxhnZDhAQSziVye4HR8uhhPsSIrST+QoRZC7zjhsuAPQEsjW2R1lDpM0IzeIwM/PKZx
# DATA MtPZkYq0GW89wJpsumQtRYr/NDZcoO3sKbU7Ah6mCEvUEZ/pkoGYY79hMBcXh2UQMJ6Ix4JMTIgq2v+wYF7wPkC9iUKhgPglLKAA
# DATA 1BT9gz0VsPP0GvlykUAeasCkLgeYcoApB5i6OcDURePITnOZ3U3dW7Tar2K0X4/N7khSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVI
# DATA Uo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJPXckKTajWY76FyRJDUajVrDwQtEkiquPO/EkbIzJWh7
# DATA jU7382qz6ne7nt9qVoN6QH99z6d/mj2PvhZzaBB1+43WKg+q1/ECUJ8anl/vTqt+QP801dcSCIoyuT7orwNB+T0JmNIf08Ct0UcN
# DATA C73UaLWtolccJIESFcFVUTOMWtFKRJsd3wu6lOyW5zeCaaNb9Zst9W0lnlG/P1obz8Zq/aq3vGarNW7X/Q/8ZuA1u/64pfXiLAZW
# DATA qxlE64JcrbHtJsW04f+o15zWvaBVpX/87jSg11CxdPG5GnTpy+oPpZd2u+1GMNjy0sugjqSFaNSRNDYLddSvd/xgWEQdjfh/NuqI
# DATA voajegF1NPKHo76fo446fcqq0KCOhuGg1WvlqKNus1X3WzeOOuIdJlU2PWyWkIpscfbpYyT05L/UzO3JgM00kpnBNsgPj1z5m3eg
# DATA DxWccG3jhJOlt1VAkRX2qkOeR1jZNkcPRQ93hRNpSyMoB+BdYrze8tj2wXsjhMgqQdsX6IkJvTk9pcLtoFQ7qmiL+bM5OY4k5EhC
# DATA jiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQq88SWikOEJ89IoSXDm5O/qOXBqfDmX1ELAfMm4qmfkpC9mi5Kun5uppRD2yuqzpQ+8i
# DATA XCYIjV6nHDpiPtCnFEO5eFIEEanfH1Dw/HO29uf3ZhBFgrFA7+P7Ttfe90myCCdyvo/v+iBcjGvsN9gbvX7yevb6qbrZ5gzlJ1nc
# DATA UWl3VLp4VNo61+QOTLsD05ul/J6Dg9Q4kzrKq3l46oX4vSBvvmDlE6nPKAEjEY56U8HPkM2bTJKT7Wd9p/EjPn48T5NkpM8fQ2fc
# DATA NFQaf7EVZZlG2VNom9OImJ4iKQvKEqRPH7e872XLOTrVaKhadJwZ8hFZNgpslNKAh9oJOb1JvMAiTkKTh4yVsAVkMkiX0/4htGHi
# DATA GZ/Hzsyh6hGcvcd8fvdTuHALCiYpa7qLgnY2SBJ+YrCcQ2ZbzjVvU9B+CzZEeir76DweovKkjSCyDhVABMmlOouiYaa7M0lvtkjF
# DATA XKZyHCeTIZ91RcwpsTQHZjlwlMoIvx1RlCenLBRuss2UnSjrsEw6TqVrVXROAyZyk2SBpNOlfnIy8cJJlvDB4K0S4e9S9eamI8e2
# DATA 6a1RahUeCzb32drk7NI3x5k+RX+CuojumcV9Jjjfi3685rGiet6TD7AhJYI8ejzhk7k4G5/VvLdYrZnrrqcBNagOFHmEitSGQ2wE
# DATA 4rDMMUSl6h8uLhJ155zjOJ/QQGJ0BbEdFeffPRylwcuo6YRTfh0NdFw6ShJ+sFxI4WJbzVydBhadeHPeG1cmsaJwoVr8DDL1DMfJ
# DATA jKL5QwlP/CscIpmGEztLYnOeO0ynV9M1f1OEqJF11PgvLWyORnjdyuYfI/NReCM4p6V3ugFB85xtKYJHKAo2RL1cj+AGNM2NMiMb
# DATA NTPV9tDNYsy7AYnz+9ztG1tJqUncnhL4y3OQOw/EzSjcjKI4oyhXKTetcNOKnacPG6cfNzeteICsyHE4Eh09pXjutQFvA1EqjjS6
# DATA zJ4vb+/oIiymfsB0WOZCTueoXwVIWt+M9cxde3TL9/UXb+/bF0XWftBEuHAxp3h218W52bKi3NuVoMr+RiaUTBY7xFLdniNe1feC
# DATA SbUSNTszG0VC6paoidOTfi54JXeIpH7QxNJcyO3aWueiiAbbIroRhCrzV4xWVkt7cWmo0tTirCh2ZDRL36W+hVqHd2Tm4hWv3f22
# DATA Z+qtNyWTOvMaTXXPCfzTNMuniXR0lKKj5Kc0MgvTb+Fm8Y3cHfFXpcMmM1MDOY1ZrTYemK4Ob4weyZqJnjJgGQyTeoRVkjJjeS6r
# DATA L9MCtpmwyuRpWYXApD+flkjs1OmDSKug7UA5fXlsb0ffcbb3dm++M7RfSkP7spSdZyyEyjuA8w2yqwaoDaFh0cFQe7CNXqgkYTOF
# DATA 5pnKp74QsoL832tmGpWEXq+baLQilbuWZ7SDeK21jzqXsMW3CMKVSTiqGIIOW1nLbKwMrFI9xU5xKVm1W/yNcePeu2mMdRvsUmQv
# DATA Il0Coz5+BBuGvf9ynotph3HR3KEJJGaB0bplF6WqKUKmok+qDjLwFi5l8hQNGJqWWh5VY7WY6NrxfoA1K8Sc7LtSzEV21yyqUOx4
# DATA /cK0CdEY1csyikGK42TYnm2tFrF8Ki894Szilgij2e8YWz7WNkuY/svxfYCVILVAp6fPUVEcNSwu7PGSycSs+lEcFXwSKxBYBNsc
# DATA UXrZunx9ZbQ7LXIQGW4DcHgsdtB/Ovvy7I9n35z/4uwrQH/O/nD+G4b6gB70C2b4/Jx+A13ot6vwoJWHz/58/hvghn5x9pfzn599
# DATA cfZ7+vHXzCD6uuLRpy/Pvq7SE18haI/v+YbuoXcIWmgjTIhCx1u+oDfQjQ4o9Pxb1D+EfhmvE3NvomhhpxVZEMQl6WjV7tQ0OgJ/
# DATA Wcs5y8K/qq9mcE9ZtLlAmabeeCtD6K1xKKoGlmS44whZ1rXqEm6bJLSuXG6OJsQbAsbJ3Nz4qbqwnik0ivNu+t14YTzB10wTEqgx
# DATA 2wviK7KIPq86R2iXErt2mtB9T8DrAIFXF8t+ZEpePPgx9tBOPdkJXvM+SKgGzAwIkQrxGHrvkPTAGgFreMAsC9VmlxCfJ7LpI4X7
# DATA cMo8RnHWsfElsEaIxJbhQdur5GYjZk07e1booO1JcNAgN9JfZqTXnKArDvCvhuvstgb3GxnbdxraLzey3/zALtVyNQfyja6311pu
# DATA AhSUpwwiWhRAthrnBTxu2KypN//p+C5N2vmQE+NEdAGCABPz78w3wRIY01bUllB+yzScUeoyk25JrQleMEPTOXVhs8VO2CDYVwsc
# DATA 5Ec+UEijlHq7fNCPZblfL2whGBaTY4iRIQClkWSVQSKfClC5Yo30CTA/yUjQxXgRVUTvwQLJjtnjEY88alUPhYZyQh0F9gyiDfIG
# DATA gxR5px2ijh7k6EGOHnSD9KDdxpQdoeYX27y3bLxfxXZ/WtPdsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7
# DATA yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw76LlhB0X1UX0UXJEd5Hcbg1b9BWIHra4778QPOjJJ5l2ERdbMsBUNR/VNrJl7
# DATA bwziFPa/gH0CSYgC+3RYpIHlDXxfEYYKt7frzQtutzg/FLZH93j0W9Xv0d86/dtrfZ+uT/xena61vcBv0rV2tdOrBs1g3Ox9EABY
# DATA 1OmOO82p32hVm61xe11MmsGmiCuA0Z2jQgVqBj4iQ2+YVn2vfiyIni3ZGI36vfZ6RFJ9pXpSnFtBfdxu1j9Aqpu91nGzPm3Wm9Vm
# DATA nT6VEUS9sNNvrws6uDwNSOq8pgFJ87FoQJSMQadRpAH5nUa32bNpQEG92W0NCzSgoNtqtMOcBtQfDZvDoaEBtRqdfjfKaUCj0WDU
# DATA Hdw0DUgZJesdHzqtJVtLjUTYuFbdboV4dDOGnfzeMvjHTJTWTYq0Gw1z3Uqz1mT+T8D8n9X1qHYxUtq4sbppsV04IZTjYVo9wtQY
# DATA PIv6MDqqWGvv9mcv6M0fVb7VqLc67T67/fYrm0PqXTIoHeVsHg0uSyXSNi+8hysmlbUit3lxXC2Fi0+4mtEP0+hgGKYPN7OH8hyu
# DATA 2FHfbHOUzF6pQ2w7OZKQIwk5kpAjCTmSkCMJOZKQIwk5kpAjCTmSkCMJvbIkIUX6+cQ61pWf5y6e4ypjeIQbJKe8KY80XQg7AtCM
# DATA QOcZTGsM83krmbIA+sohbz7ehqUkUasKcVAlmanja1qQtnhQTNqoTOT0SQt3xtmdcS4ctXFHnd1R5ysedd4oPngzR6DfjVnrgs/S
# DATA sguyfHpWH4V+3uQ2bkOPWw0uqDpUX5VkOFK5N5heJNFsnjUdVn7FiDR312pzt2yRZt+vF2WaW1ukrnnwg6SL6r34whtiyxoVZbkn
# DATA F7jWD72RcGdqS0i3ebnnY+r7FF6I68kbdxIlErjmiTZnF40t3h1vkUYPWSvywsda/CLbDJjCoGH55OKzdyQ1OwhVv6PrJ6qshyr7
# DATA 4qpUfxCF2RKi0ThYOwjTXKD6wUIk+agnSZKF3CDHmiHrEx5B7Bn+qBMas2reD3lwm0THVGnQAaJTnaqwuRkrOE2SGuGhNCFzsuZ9
# DATA zAsAYhrJA6y3qIT9aDg5RUFTQcSLgnw1YFqFY/tyjtRLlzjjjSPXIQ7YQ8PRjOfQDySLjeosF35Gs7NlNo9E/5AVs8PZcoSBOMVc
# DATA SgIEF2kYj0a4suyznnqMcZoCY+zOOltPiRBQEhY7C1y/LOd8nby1M18t89XZq6+EvXpZbetnLNnD69r5Aux2bev7NBqx0cgGJNux
# DATA WS5FwRyFbIvG9W2L/bwQehc3IWu9Wq+vXdp6rabTVeWt80V/bY6JRaFsnwhkUa5zuag1mz+nZNIIUJOXguh1Ne9N0Q2iWZKI1UTh
# DATA DCbKpxARErmXDIMbY0aF4MjVDWYUWV2xFn4mGy4hm4eMuof0Bk0MuVzF+YEWYjGqTsYd/mopnhRyxhlDzhgq9anOm+e8ecW+c6MV
# DATA 9YwFDZkHDHBxMpmIzn4Z2K3aSZjlEn41713hdLOVtE6er6DlN0+TQTQEjVuk6JL082Ukvpyn4XPfjw3U2dB4FzSCaibgNF4IalpG
# DATA Uo+1XDgGS27kR+HyiEbNj2kY1rTACgcgZoks9yi8AzqMcDSCU4xdJbnL04zT780w3i+EX7tUtIho2o+GEEEbRv2URmShIvMQyiKA
# DATA 2KG0FWUto38uzyg44JCqAvygrCmoTINMWxdQjoO/JhVnqRKfJhtgOIn6YVrz3of9hGhSJaXMDRUIbBiigwESoT8R4bUxC+OtEzLk
# DATA j5mlWigu2QzU68+p4OMRdN6mEdb+4sFWGPmYVa258swW8OCwF9kk+VNAOZLRyDuiIUsnUfZJepMlZeoghGIj12Pg1cOT8FQcUzqe
# DATA qgwz7dbh7ONxgIJRMad8yUSBG/4lVuE+VLKGkMJM+WSBqrimOhfAGgvUH+aNeH2KQLTR66xSzSONjC2QCWc+eC5UDcEp07LIjEko
# DATA 8THIJCz/FE/o54r2Q3ECctjOIEzTU1ZuvE95FrLfTgUkhHmBx2mOz3HIknx5Jn0YxZwq8RMr9Uu45I6SZGi52+WtCTU0Gg1H0taK
# DATA RXg12Dfa8imrPlIf891Lw74Rt+uGfYtdHksDV/qF8Qzg+Gh4A9DvN8G8V3KhauvIDTC+Py2pkN7Imxju/T6ahvQxNK7JtpxMiDnX
# DATA +zY+BfSpoSRihWgexqn3EN7icDV1N0kUfzmmOhZcJgnT4RF86zZe5r8ojMw3DHUBHeZL7+yrs38+//n5b1Z5Mv+N7vvD2e8E+cJ3
# DATA MfkFVJhvzv5EH79glsxXFc/wZb46++PZF8DVfIWfqvqprzz6+oUOim6jF/7y/FcKLkPxOP97jxkzvwObBhQaB5V5ATCNM83sWvHF
# DATA zaMECGg1ci9EYPotPV8Tv8cRb9vGIKegYazdy/LCObnLDHwUPT0ULmfDrZSZ+3xL/mbHmCnM5kzPcNuUmdVyuTnGDCfQ3PU9CIlT
# DATA Xk9G5fuG0H42QC/s912k4el1omWoDWRkY6ciYE4zDVhjPBNDQTi4zPaiunaqjOmEhjGZ8XxiT0wdMl/xFETu40ce1wvvY94eIG7b
# DATA I+yPXLepXNiH0GjXSt8os1m0YE1z7P2gMTxbYchsq3mb7ZSVNvSs+DHbou/oMW5If6ohXeNkrjSSvxo+2dsbxW9gEN9pDN9xCL/p
# DATA EVzqYjnZ+bbJZ9hibgIpU05oTpYxmhN5zCk3o1AhZuB+Y7kBeLpmVKSZrNYiGYafIcMq0BPHccq4GBSWxspQysMMF3Fk3BCFsRoq
# DATA A+slIDKnsLbYtyshHsk2M0wT6GN/Ih63ozTi8wCS7Xqrm/Kt0+gPKQT+fiGP5BDjP2dJatkMRcxIlDpYjIPFOFjMDcJiLhgzdkPC
# DATA X2jZ3qp5fiVO9VMZ544P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P
# DATA 4/gwjg/j+DDPDR+m3Wn2m/Ur8mFGo1EwHL1AfJjymvNOdBg7Wxp1z291xo1O4zjoNb9P34s50u90Os3hana2As/v1ilDO8dBs/19
# DATA +l58jupmt6+4LFyWUlZScKfCYQkKuhLNXrGMm81SRPpRr1MOMAgaVw1wWO8FnfZKgN3gemPYaPrXG8OmVJ3ri6FdKFSW15CHVqFc
# DATA MsANpWwVyrXE0C6Ua4mhXSjXEkO7UBoS+PW1lEsGeHFLuZYY2oVyLTG0C+VaYlgolFbzelvKJQO8uKVcSwwLhXIdMSwUynXEsBVY
# DATA bblXLGW/UQpRXUhV7pcH/3bUKKG42r1m2FwLS1sHHWu1GhZ0TMJPDRLMMlJ0qCv8tKD1dAG0uj0rgFbv8gEUktBrP2USdgvgMjwz
# DATA sdE0z0zMPYtnFjbbzUZU5JmN+H82z4y+9qJRgWcWdYdhf5jzzDr9drvVNjyzYXvgh92cZ9YdNMPgxnlmyuuhNjSYmZA448mWZAeF
# DATA 5b3Qi9Rmftbllco1i/7FkMscs+9FZMTGYUViUtqLsiY42xHJizzF0NW678XRMNOX9bvk9O00OT6Kdlsqau2yOG2FWl51tn0muo4U
# DATA 3c6BTORXVg/9hrVIrO71g6IXRldX3mM5DofJCS/EYMWt7uk6Z+Vtjx0WPCs2s7kN++n0JFbldn0zA83O0ws8GlZuleokT5YDB0Jz
# DATA IDQHQnMgNAdCcyA0B0JzIDQHQnMgNAdCcyC0VxuE9ljV7pgK7q5CmeEzJbrCSVIXcXQPGSG3i+rmXerYqM7soWrFd+uH8Rv8xGH8
# DATA +uv7j3GRbzuMR3sn8YysK7LDTueL5Lsw4j8GFGP6Iw5n/7FuQfO7DFpjEMheM+g1e+1O0Gvf4Sjtf4f/qCj078IG/CHN3huBdLz+
# DATA /uEweSzvKL9ir79/+IRlM/f6P67/5N5detf+oUi+4cK3OejX/cMnERnrSgvOiovw3zjAPRWPfbpbqY/OlzTqqW7viUQPleOu+vmn
# DATA STzb496KchB8ODSG19WPskC7txdW+lQc4ev9ClmPuSWvUjuJ7260ZicxCmYS2xXyrjQPKjd6k6SNZo54Ldv4MiPAAXK0+zm2EsyG
# DATA e5N4/1DyqPg7r0rTxF11xff8+n7xBgzBKj5v4d6anJ6myvZEI+vM0U+nrOKUVVaVVcxhYKeu4tRVLqmuslEU+wZUVz6GHJdWAJkk
# DATA rPfBml1GeOXZCnndBp2OTQG6Kp4gLxlxYi7A0qmH8h5JfS+oya4Q6XwLSNe2cXT+Fhgdmy+o+viA+QeKogSjU/fkMDr90Aojri1B
# DATA PRITaTNLjsekd+Bdv+hOX9SAyQK96EZW2P3kJJpQJ3rBvUFd3TsjE7h07+7oOq7eaOVcoi8ste5vNKNBxqOMrIdoaKT2jLwOGVlG
# DATA FkfM97LUDpPkdpPtYREbL0uWKVi+I8GpQH9brEZoOOR8OvFakJE4UzI+lMRTTx26N2Ix9M4VtZhx456t/0NpalDBTHShsEVm56a1
# DATA UVeVwGQn2tzLoBiSjyXO6HRG56rRmVsXzup0Vmd2oT35zLT+HjBqiCPJLm4gR1H9jdFpgGTTeJAmlgTeki1UpX8XUuuaDUC3WNW+
# DATA M4Ni3qLUYKghJSwlN0im0ygdxHoMZMs1jbDSgo0LO2v/ccrm9x6It6p/Cp9ZhF0mGEYNQEnYvzSYYi/FGv0tdd5t1URV7lnURP6k
# DATA jFNlc+gfcwPIXOGDz0CnRRyOip8sN4jgoI78WtvT+HzBCVKfi5andYfpKO2nVgw7OE3RFsCakvvibXagNs7fZgNu012DBMQNai7H
# DATA fPNb+dfNz3Alwt0f4cMW61IGZm3hiQvVNkkwSGwx7woljD0f0qDV0c4c6UCdkmF3sMdaVndUXtp5UcIB8W4Y087FGcy1KV3y7cG/
# DATA /Pz/bptUlKOtclaZYkqqkipIujgVY4zsOx6ZwOTRliQPQjTtq8LuGvJ80bs/HEIaj54WFtAAjY1qP08UmZ8M9goeZPNPRkcmomhi
# DATA MmxTekvNezOc5VTA2VAmpfLTuyDC4CWNOg2yhhKkj51cKV9LtecK2dvcnL2Fuii5DHtZbHhKyCKc6Hy+zzwZGiTmFck1PbHmXAux
# DATA CWARTyMbyjafLHn2TPPLpVj0TEBSHn3vfjxFXo3IWsvGgFWx6Y1LfoCv8yRjE73mvQP4Il4zjLPBMkMBcUiyKHkduWza22Xzd3Pe
# DATA qparcxU9PnW9C3zQefo29vaEXuP//FMDrKQh5QkWD2bgmZ8AH0R1a0l5R2UhU/zM86lAe3BayPrLIKI5SM37iLpsmnrfl4ot1RcE
# DATA KOYk8XlFD+6NQ+9N+w6cIRR3Cc+k1Savmvd9+hpxRabyv7aKfOUs3t5DFLL5UxpoaZJBQaQ6j405O6KGXxU9p5wFBu1Aql+oTHPJ
# DATA Q1nxyaQvkLtRSeGnCRV6HBNCefBDaJfiZGDGuqWhCSScaShVRV5Gv2EJReLGmX4Ui+QpeGTHcUItRD0cSs/zfHQe7Ut1Hv92GfPK
# DATA px68dSFIBlP9pTEOFZsrINtA2jCS6RCy3csm8ZzykxsH9y0AnfH0ps/6ptojCAVVjOqixMpdk3cULaToOAuxkJgl0wgXjpYRdxx4
# DATA Op7JRIX6pcW1dB83P/i9xeMSmEixqdqmWxS3xuIkkQ5Zsha9cSYITRFKjuKURrcThKLrMcvYxkbhl6braPqpavlkC7KqM95JXRNO
# DATA K1JvfawmdxQ2npgmWMjluQN6CsZOSPcCm7WcuUVzRZaNbXPFXJHMukcNTC3waiFhGb/FVLTMV2puY254Uii1i1hPL4PLJZ9tOZeL
# DATA c7msISg4L8vL72XZ6EB5rogKhaMCqyPlxGYteJN4gSPOrITCSExQLNVowi6Y/EE+T8IZ+6wRDM+zVvlF/CTr4IesSvLRl3tvUEda
# DATA bm/66HvheF1XzvJZ5/LlQjiR7rCMk1g5ki7td5CgdsjbTmcDHRWl8pj73Wwxey6PNWAO6zn+wulRKzHj4N4DtslNFQEEOZydmlWr
# DATA 7ycnwCGfqrrzXY8vLOGdIqvqu95bdH9EnSmMIRghuSX8XUzC4ilXuFl2IrOHBTbaebx0zPr7sSK6ajYVYLQh2Wbg40K7jAyvfvIo
# DATA WuFFFWvLuzEDM9kBSdmxHCwokVLsr8KSk825TJjHbVMu/zNjKf8HkJPnv/VApDz7/dnXZ1+sEi5Ld/4lB17i/op3/gu69hX995uz
# DATA r73zX5//8uxLPIF7v8LtfxQEJt3+zdnvz/8D4JUeffg53fYnudVxLF8Ak83L2O+fqgOIpq9Honlyzj1BzZPd8l62lAmrbMhnbq08
# DATA yA0YYwYPJuwRmMk0aoQJKzc4+MmwtDDmzfNbKJZvigyYoDIcwrJowkmjv22AZalIbo5eCTvg2OruVcVjCrr8VH5CVUHzxMeqSqIK
# DATA zuARu1agJe+WGIcZ+2uA/lGOcmXBOKjlriV47XjL+7BLj8RWMezoCnebQzjYNCDI9FliaL8dj0bxABvysW1ZdtxEmgGub51FFAb9
# DATA nIq7f4VouVMd3GyWFFvXs+Ja7pQIB7h0Y/1TjPUab3n5If4V8dDc0vB+3aP7ToP7pcf2WxvapVoWsiHHXD6zdnMTkMtCGjElD4sJ
# DATA w7ZSSQCCnc4XMhTOU3Q94NSNw37MC3+LTJcaPXF0hAWWh1QNMpnHUz1Wy9yYbsvIbEbgSUwVEstfQvjLoPiX7oq4RDYaJiCmDRT/
# DATA CXX1OMOGNRCFdtSx522vK1hJVZOqBWNBFoQ4liyRglCQh8gArHxm1XmUVtmqoxJYTrmXPbTMBNyIKFfJYNtoNjgGpmNgOgbmjTAw
# DATA dx5gdprJXMIevj3T/iqW/TUZ9g6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgO
# DATA jungmA6O6eCYDo7p4JjPDRwzaDciZm5dEY7Zi3ovEByzsPK8ExnTQr35rZyy2ChSxTqlDG/I75LjRWRZs9uud9ZkOLCb7WDcbE6r
# DATA zabnd8eCOrPAY2UaWQ4ea6xA3+pWXEtItZW41tub4trvt7utcCWuQUBx7bavK649K66d7ta4Kpjd2rg2+13+tRjXhl/3Aqq/1xPX
# DATA Rvda6kBn0G2H/kpcm/XrrAPNzrXUgWEnHLZX62uzd511oNW+ljrQaXf7nf5KXFvdp68DVnAUWrPdGbcb9WO//f1uCY9LHeqgdTWI
# DATA HfWlGmIn3bIFsWu2qdvo7gCxG45aRYhdM2oO6znErtVptzotA7EbdAdRf5BD7Bq9VrcT3DjEDnuoqrK6oUfXpsWvs2h1XbY58/sv
# DATA x6UrO10b+VJrW5yuHDKfU9nNl9re5kvVc8I80NVVGeVr1tMMTBTUlKvXWqHDwaeGBSf5T4N/N1y4eEZ1yusKGU4qQ7NIp1O1Zh1l
# DATA 72rEOFkxUIu4a4vAuPbK/oKNsDmrBLbYpqs1xvHlHF/O8eUcX87x5RxfzvHlHF/O8eUcX87x5RxfzvHlDF+O1RsVSo59npTo78hX
# DATA PrxHX+/oXwU0x8bmZ6+9o47/Dc1JSBzWY5IZM9kGUTzZ49CZrCb6mVntM/rf7P4Ct0mw6gcFYFPfGA6jwx3ShNvjEzxrAr9TDoWD
# DATA sR7NeEQwuDOng+gO2m8+aO8O2L/EB+wvq3743By8zx1b29UQWeSNT7POaIQiywICy2P6vk0L8dme03/BTqxepL6TOypvQhuxpEJw
# DATA zcKIZR2HC1QR7ytAD4shUK5SG8o4MCMt9NES3hjeweAdLQEF60fMBgst1W/oHtBkHeO09y5dTSByr9UPRSaKEQ1KXYHqbaIFnOVE
# DATA OVd1Jd6A7Ocz5TiH3pcKgadR56JHc5lWKJXpsurhViWlUpOD99qGX7Dq9oOERrqxOq0um1+1+PaHIeQWjUx/Gp2EKQ7UK0HRk3Ai
# DATA R/NDVUG9CRLCnAR2oMdhKsIUEvnieehFyCKpP1gukCRzCLqsUb4aR53Lhtowk5Jgig13ENiE4eHLMAqNlHqYsUqDEtYKGU/Dp9Xj
# DATA xZbovQfqzSUih17ERMwS0tAVCQKYGRV+mCqAQTLJFI/R0HQ4mPShd4JeiOOL0/ZbIvmRvGZNJr5CJ9btUJyN7Gzkso1cqlVOlsrJ
# DATA Ul3FOt5ojd+YXNX3Ym4DbCSESuhJK9hQjj20tKtuWRPxNuDA4txhCA6sxzRCzkGlcjseWD9meidzISfcNusXIYIbdTFkd6AEi9cJ
# DATA yF7jYOJL7BLCyy+IsH7eRNhcyCPcWh9hiaOKsl+Ocn1znNk1ZlddVK09fvEd8UztX5jNRQqz/p7HOVgb59ZVo6wdZnTDB+t9bhfE
# DATA OA/ARNq6ZOX12mhbsVbVR0e6VYjzRiDym8t4MrRGNPQWLy4X+QMZhmV0D+d89IYXsPVcyoCTuffiUyJKHUqSP6aHIvC47nuj6IRd
# DATA 2uw4XhiPKnSw1gjJH6UsVGfG/1l0rJlXRgLsh6pf110hgGshsOjYP8sGec37d2QpDHneQz2j1c2S2T/EziBRXdOMTHFlS0fKjYVS
# DATA JG9m0wNTOppmCAcuXmyasr3ERrg9ujoj3BnhK47qFWvL2eHODt9mVj8/srFqsNPNgH1gaAu2CjxwOzRWmVZ4nA91SqK0kquY8lBj
# DATA BE6h14m9VRh1EPhcJDsxvConItrcSIAo2TIWzIwcBtmkuXplenL+Um7YkMDvo1LoWQSNzkPHT96FnzxjHyqeEG/q5jvFnSxTCHza
# DATA Qk7WbkXL+QeK7fNPUM5z45IYyU82IyR1vgpE8n7Bcw+XNlUZQGnTCMVUAqam0RHlmPHPsh9WkFj0nxHmzkp9lmpkxjfSbbNFTBNm
# DATA WYHguXLNeytM01OIsiazons8DZnZyFbrIj1VXmIWZcUeyFQiBp95MtN+cjV5sBtpvvqjm0i+umT2QMoovyX5Jn+1iiJd4M2+3DBD
# DATA ME7NTOSpWKF5Vb5kMb+zuZh1o1DFbJz++ZKM7LXgHkMX9PvoYmHkhMJkTcli16scmYWsFy0AUYrmpRcJPJskJ5NTkYROWdkYnSvG
# DATA IrPUQ2XOG/jQQY5Nr/hURbg9abdWiIVe5pLl+PEWmHHeX+kWK+gRJZGcRmCx0pAzGyoxcC5JTQLL2+kwDmkWOGUDdRQtTmk8XSKP
# DATA Y+W8CnVLVrgxM5nnRRcaXXM+WmaWcGjwfYQZKfvc2AOGBcJYgGtP3Ta3JfTWyvXKffCDnftgqrALukXoupE3Y/Z29vB0pf/VbBsp
# DATA Vlg1IjTNRsY4msbZnLWvvfe5xwzZSzAJ0yPISkOZcZZpTv1Jkkr/Km1FOtdRCEQy3ALX0i7Xp+r571a/v3O3qsYusq8gr4+khmqg
# DATA GoaaYG2apKx7o7tMtLEodii8LXw6DuI4KErFt46PZnD1yERUW5hwrLA0OIzOdJ6yXj31ulLMHI/raHs7JOyF6FrfvlTXqmXdYZgM
# DATA 0/AEDYR3J0zikbVQrZxr+g5lPUQhtoVS5kD2Xuwd257BjIYLS5s8g+Wi5rHLz6xlq+0BgzScI8/5SKjeT6E9ZE9XrltTeKUSvV2A
# DATA 91N5aF9+n2KOwBxENNrHg6yIwPzy/OdnX5z96eyr81/T51+AZwls5Z/ozy/AsTz/ub64Dov5zdkf6f9fnn19/g+Muzz/O4Zi/kmQ
# DATA mBz07+nKr5mf+TWTM73zX53/PQCa579iOiaFffbH83+kIH5Ff39L76QQcNMv6Ic/0M90zz/TS746+/P5bxwm84VwlGJbGror1S2q
# DATA msdBZwfii+IhrE/Tgwp/P8Jmd3hRB0DWKVDLccieq9BMEYzPNfTghRuMa947j+YTmC/UmaKwEGtl0OTqwFv5mW9NaPySloj4OYKm
# DATA 7UPVfcZtEzRXCuXmGJpcKc1d2FrIa+rKA7hC3KSqHSfm9gf81YNo13ICkbDrBGjGmUQF3kPZ2RjhzG8IftBptHD0zF3K7gbImbxK
# DATA yqvl8RRTXYRmKoDqnhYRH1EboB7zsX7vgyjMlmr5lnJsCSgU0xVQctRXGt9zxpwhbxFPIuWyTtlfTgbScDlZxWnuViU3Wzrltvas
# DATA iJq7pcMhNZ1dcBN2gWZtXsUceCWWU2/NFLh+S2AnQ+BSdsDtmQFSL0u5YOM2n7c2dRMczlLyOdFwUzO70ESmDN/UCsV55hzDiTFR
# DATA PE77IA3nFi89G+W/HMCn34bMEF+OxldmD6PFAH7vXXGc+YhvWQwUuSwf/qdiJwyxLw+qUVCoofh6EiKfrCnYA7zwTXFLhlXlx0c7
# DATA zzLeR+bxHi6xRbRTkUYlJFf8UYrWyRsl2G0VmmU0h9506E2H3rwR9OZOY81OU6DLGM23OQW4ygzguiYADr3p0JsOvenQmw696dCb
# DATA Dr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQm88NerPRag7bwVXRm+1RZ9R9gdCb
# DATA pcXnneCbFHpMw6I3EJmxHufl4FTohr08Y4Om6FDxL0G7yC/sDUdRdzWXwQQMGmM/aH1e7Xot3wt8z6/3+E+jVe02PbKPq71GtVXt
# DATA 9Kp+0PaCXrUTeH6HvjSKhdHudlu9SN5RjHPQDPI40/vyOLeDPMpCFrUqRqvRjlZRlp2e57c64253UvXrFL3O5z2KbLtRDeiHdrfq
# DATA +91qp9pqVf1mr1Rb/GgQ+SXmYb8djsJgHfOwuS4pTYn9QMW4Y0EYm1ZSinV82B0M+muIjH7XawTdz7vtapNS0uh5dUpT1/OD+udV
# DATA KotGk1LoeyW0Yhh1mu21cWt1O3ncKGArm3tWzagXaZF+c9BsX4HUyE1PkxqlFVukRorLoLcLqbFwBaTGIOpGQ4vUGLaHnWFOauwM
# DATA g2FokRr91qDbuHFSI/a2V7eZNDTgWj4usY3NQ9qSsaGESOXIL82Im91ve/iXTA2PzY08CD3eWkuM8iubkzt6/QMrfmvnEhwiBIVt
# DATA n38dd/McRJumh5YBXnCFqnK/HFhR3F85FLKUJy3KE/q3If8WVquaLYON7LS+vZbwKMYipVnmfPlyqbWAtR7huBHVeGFl0Pbk+log
# DATA mRLYxbdzOKWi4VlsaTLkOJCOA+k4kI4D6TiQjgPpOJCOA+k4kI4D6TiQjgPpOJCjEI37rl8VnqJsOgb8kawZjXx8oM+7n0TKn8m4
# DATA xz2Fi8QFPCFBoaq+i41+ez4jGQdTYT8WAlFzVSsUuXJxMCIiC/FkdZxejtp78zgaRPo0Is7IwX/YR3kUOZD5yRt3OtydDt/5dHj5
# DATA iJY7KO4Oim/X3X5uDpA/iB9JE6rQ+DQ7xZJ/LIcsbfCNOfJoiaaiyUzkUCeefbh66hlHQbnnVWenRwhFTmZm4SS6pHy2UbUU1yM3
# DATA cbo5mcI1ap/zdsrZuyhn844Sror4sPk+9Je47Uf0d4tmNg2KC8EffiQfXwS9bJMHlxSJfHOzSKTKTRGIfBOnOEc41o1BKdeDxGYZ
# DATA jyx3qio4D47T+eCy0pTnFAKek3gkJ5iTBVMgMh6a4IJCMN4oono0gUFEE5ZEDh5zSjQR5Wm0M6+aJW/tmCXvaE1QGpN1hrwZTqAr
# DATA wFq9HF1qTHzBnLmWJRyWFfVG8C7T08gpXiDheR2YczQ04w81QbL+YjmZj8Bm15Exuh1cMl9+tDlfpEWpmrIcsmWS15FZmNKc1JvR
# DATA nNZDP8NgUEi3YkECMgM5/AcWDVepaCaEMggSZMwRoc9z9PfHp9q4eYZ15N/sWEc+SpasYfHT5VGeH1pteq7Vp5PpCJtGgGmgTmCO
# DATA 6RUaBNOMFMZoSKYGDWYDyrjJOFnixFvN+wQTAtZWYKUEseuOJuHPjFDHU6rP5l3hJfPnoy3as7pTlRyi+bU315ckhz5Kk2PUAUoz
# DATA zW6OIoOO5U1yVGnC5QAqHPdn3nKG5OoeBgLBDEQFlmkC5X1IRfPi8jNsNx/v2G64UivlFgtZy4oM02QJ9fEllComYjykfEYW/n5Q
# DATA sYZD3bNAaTmWrpTNMluIN5TqQv11OT9uV8r2VVFoyM1sNwl3k/CdJ+Fuxv2Sz7g3Tqafa8k23sdidrQIlZV3tdx7gxp0uYT1/ksk
# DATA 12yr68pWSmtzqFwIJ/ytLH+2si9SKswgwc4hednpbKBjok4a3/vByrZKPclfVZezHuMvnJrC+D4pkL0An2DWCyuODal60gRe+xfy
# DATA h/joNA83z6lu3Ysk57SjsK1ntlRJ9S0YDmYD1RZD7V/+6T9pM4JfOQ5Eyk4sSG8RTSY8dVGgCVH0+h7sz8w7EisrXDAtYggVNpqx
# DATA jJfTvi6u0EvHp4vxVFmzbLDy3OAolp/F8mMxMkybIWpmaX55vOcRIl1KGrlCuZVGueCcUQPUK9CCGcrRFSdhuqKpWyxQhhoZw5GJ
# DATA Va+grJYVjLPanNW2s9W2Ut/c2olbO7mCxbbROLxJ8V0GNI2Ujj6LuSOveSG+oMH77AXhtxkCOOfn2WstK0snYiuybTksXCusachS
# DATA P11+l/pfPvvNV7y9wfQi0L1+1HRn5oJZYZADImVkvF8E3dvI+HrN37z+ojYU2JGVS7vE1jxsoptfMfHtXWd01cYL+v0Drf+7SBaF
# DATA KrH37YuibQIx0c6vXJDNdSveja3RVuarWTCTXam8yiVVPuItHqYpZBYiCjXs3htyJljFWW1Ptp1q+SXpf2JBVc1p7FZG7B0J4inh
# DATA T2JbMUor7wJsVeofZmZ/CRqfMW4/EGeqUWpm5PDJOJ5EeT8RQ612gb06KUvempUOas1RLt7M8sBqhRMmrmxcka1vZOqWqoDeaeUN
# DATA FarP9AZaOxhdqtX3UKqWU7of24PzcFhPehDOoB08pwTEOKcYpnNe6GXPMVDkcFeejCMx4POOCymD0DT3a7ywRUZHzVMwO6TQCE1n
# DATA yzl1PUo/uCgufYfz/VWxni0IF8/ReQ5hc7j+iRlcX57/UnhXIGd9c/bPCs0FOBdYXF+sErj+G932FQBdgtY6+59WOPSJAVt/pHs0
# DATA ZOvP5785+1+G0nX2Bd34Fb/r9+f/gQldOOngnf3u7Muz/0mVJpw44NYLYf+zcW9t3QAqME2Ad52in+D6ZuwYJrVmkCenLonV+6hn
# DATA nInq9wnrhsvShZbdrihu6BEa+zjso5+S2bqoYXOdgdh5P8IMYRts61O6y0TIobYKpn/eM9w2batUKjfH2hLat+E/8ZZs663WnT/N
# DATA qLj1jcUKdp2IrVDAVhquoBYIJTEOr3VBcV07WuujkIxO/EyxbtUr9XqdRw3KAOqiat5HNIAYq4cJFjzpGodzrAXrnf+LsH+ISAqO
# DATA OjMQChRX9IgGApwtKDO0Lqxum82UYuN5VvCsCxPguFlueL/u4V0zsy4/qr8azrxbHNGve0DfaTzfeTi/ldFcamMh6baP7nlqQzfB
# DATA yCoknBE/mWK228mkSXeYqUWzIRbN+rDMQ+wkrlBCYyB9qNHElIRJDJbUbKhfOwrjCfyVgxCsImYLFZOF0TY0GT2lAU4vMMezbI4k
# DATA wUVKLWRXWlYeMmsGZPI+ij9Tmngr+pjqHNwrdJHPlPNpc/ZvzLDCx3PYJROi5qE4YJMhI7PELMjMWXFK0YNTMt4ewVMWD0N1kj0S
# DATA wzDKsA8xzsZYxwzh1RgIdwXpikfYgDgYR9PQ453vTOGa81jkUFoOpeVQWjeI0rpwDNppqrOj+Xx7s4CrTAKuYQ7g0FkOneXQWQ6d
# DATA 5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d9dygs4Jms966MjqrOeqM
# DATA Oi8QOquw6rwTOIszluPS44wTNFPdL8hRtP1uMcMbvd7mHK83es1VkFMvYCSVCsqCS3Xq3V6vvw4u1ZBABnHKElTqZW2LLdXgePKB
# DATA uW6RJjXsNTrtdc+3Wjs93+v32v11z3ebuzzfjfqd0C9nwjRoNrwgaFepYrd6XL2DacNvVf3A9/haVa5Vfb9R9Zudaqfj+V3fDpo3
# DATA jJbwXN1hd9hbl4OMCyvV/E7PazZ8qvB4tVcf9+ql4EzerQTXuwICi5uQRmBJa7QQWI12u98JroLAqke9KLQQWAEF1MkRWMGwPmzm
# DATA CKyg2/bbvZtHYNFMqEq/7zRpDwIaK4t+q8JIIyOeDtHjA3KG+6RtOGV86gTrAFLtWlkXiLecPC65TKwxYOXusGT2G1O8q0zx/AE9
# DATA apfngevmfNpL2GUvoawOwk+4ZrGtXUxEcSFA5oiePfFRhlz+hBkG16zYlTFcaz0+uqIWPQyboF3GeayiA7+xNf3i7xfkU/FFbSSH
# DATA /YqFrSebnzfj9AWv2TCF24z1MhV8JxzXtsq7eVpfqszr6uRycuHkkqPgOF+O8+U4X47z5ThfjvPlOF+O8+U4X47z5ThfjvP1inG+
# DATA UBfUCfloeGhTvxZYMuWMQOruSl1PlukgQgXhWnUYj9jIVA3zXqsOg2cxBqzgnTRNEMe3leWF5kUmD/XR6ZH0yea1d0vGtDUnYBO2
# DATA gslFRehf2NbI5bAvzDETCH2nruKz19iuEfPcezc/+k929Gm2pi/YP3zCNvrjPDbYajmKZ5QdimrGMqJK9+HYCv4tdD7UXOFSreAc
# DATA 4zSUM1Rc6nhrH3uUaX7JL7LipwR1qavBSagPE2Ofeic4s6isT/qNI0jVmnMfp3aq+kf65bvb7A4uQyqfPF1385TtPy5ERsSoTBy0
# DATA SKN6E04DIh5i9R8+Mcb8Z6+ZwGuIG73VXHid+ipQ2Ogatfb8GOQduVHnBp89KqdXJddUtq3thdO5rvB2C4Ymc3g9BcT2suTZntjQ
# DATA g0U6oSnf3/6tfMVmQPq6/9d/Ld/pUcrTz157hxEPr+0/3mB5K6ObusJs8YAt9j0pVCdx79QUrqSm4FQUXm4Vhcuq2z9TdQXjgJUU
# DATA iVifpeS+CFHd7n2oZbg5pXyQdQlpy3hzQt7WZ/dz5QGJJR7a9uADbre8zQuLQhufKmSHGAtW28ufuoOYah1CPhq7UeDekJiUFAK1
# DATA 6u3i9s+d2MQLcLia/3vN5ISiKMZ1cxPKWiNrqQmXVcn6NI2V6RbPmNVIthuMGaOSZXRAWLksgwV8AiGz6VI0HE7ZT10xAvpSGVXl
# DATA 4YqCUTITRXtL0wMaByFb9MlowXClNGI3OhO4FHCLDX2PFwZZb3wWPWIfr1LWuJBj9HKckzchOOPOGXc7GXclpRynmeU0sy5h1W00
# DATA HW9KS+s9EWyiiq3m8sqJwNU8J/vctmLjbYjcK8+Czlyd9Df0TgytOK5vg2q6eMpwmZ1lBYF1ysjJhD3aDEDAWjGPbn8NF9Mh+jT5
# DATA dKAuKItavlXkD7vF1W0/9itBpfETGhR1jDZIyiunGr3rPf7EVbaIIDa3mL41f2iFABwwsuEk8XgryRbwcFMMb3APS3eugII3iskb
# DATA H1ZedV5cHXlMeUReStlI6yTOlkbgbC6tpqIkzP5NeBw+kC5WqZmBsKLdoGgmKh9Y7+1kVtRCE9WsEJAW2yWn9LFowITomSCSJqfK
# DATA EWqaOxSuRICLnj7B6S4eOllzynL/1TxTXBgRyUZeDhZLRWGaxFNc5I1GEKyCSBzTLqDdlemolCpCPhWxzeR8aiGlVXSdYm6pV/iN
# DATA 61DN+UzNuVh2/uWwUPNhxpmozkTdyUS1bRFnoDoDdavh+azFXj8sNJIZBrpFPM2hTA9kmZQFUCsWBVBS572jZRAhsIjjO5xd9Dua
# DATA yjDhsRq6nKwWGh5RvLDlbHZq9CB3VHDl6JrYCAmKagEEHcUgoMZK7T5ifUt0Hmu8derE8RpLVfYooILxJ0UHUpaM/jE3rswVlp4A
# DATA cj7icFTsZM+N6ZY2s4rMxgeG/sjnol1p3WG6RPupFZMROwcwOqJjlPvibRYmWqT2JW++y9KxFYyj+bol5CiLjzjtb/OnLbZrkQ0u
# DATA Owlsg0XRzDeZjYUyxu5qaaxXALDr3LgkgP3xk80EdslYIbBjEhdpRrpy2p9qEvsn2DJKKU+XmWz34ho4Y+1UJaSLORDInHoFOsYm
# DATA jBAbKLz+kgxdpZgaD2re2zELrC5ZaNebxhnPHmWvC7YrMUWUN4HINW6tvDIsJAYgiOh1qeKzPTXavlSDLpnB//IPf9ycw4XaKBnN
# DATA kq5pJMK/8KvGg3hhkPf8S05fYu1bMqpFSzWZ61P3C6ptKev44vDqIhb7/P6ID4XT3GDaj4+W4D4q129Fd3eCihL6Y0jGPkv4xkP+
# DATA TSbs15GjV6yr02y3uvphOJWqACnrPOuktmCKAwVb2ecrqrbQqZ5ECyCxZHeTedpjjAd6LwZ9nAItK7SuGZQB0SDI+qPoUO9JRaE2
# DATA KJgG8uyr37+9VOUT1hnHnlLx+TJaRjr/3scMDpM2mkDnSswnYczOHL6gjptHAEC/LQ2S1ySk4mR5ReWAkfUjHC3g/KQMnMGFxAEt
# DATA 5ClgeiNQFGmoRKFdS9UzXfslM/K9LXVPDRKSh+UVSm+Rhsc0bp5QGnRmfqyOEoyVQHYo1TIlGyYaZsoooF5utmBwHMKCXSLzE2rI
# DATA M9MzqF51Sr1GxnPJGBKP1rJqDpdbxErOPaL5r1bhhu33TPP1k13z9RMm8FnLVTjfmLdutRyWRkfYDy4HRCghmRoyMNrk6vVG8jxj
# DATA X0VuGUajEeew3Q+E/YzFq2mGxu4duUdVZ/SmYvXF6Gx/KrtZSxlaNBJkz6JtJJgrkj1k1+rdhXpix84WteuPOqLBOIF+Vgh/KZWk
# DATA LohXYuHNxuhRSUQ2Qe8/n31z/ndnX579r7M/n/8W3LvzXwCJR//95ux3578RNN7vz744//nZV/h79uezr85/u0rUs8NhVt4vmMaH
# DATA Z785/zWeOvuaLjJvT9B79PdPHt3y5fk/0HN/Of8lcHqIQT+NTqoGvff1+a/o72/xMxP3/uTQei+Ct0Zqms2blynnwxitdCbbgkFs
# DATA +KHxzYjyPcwxshiGUPphS0HWN/D7Q72dJI0G8VzZXNkS/RG39mnCYv1bSXpvSbysBuRgeraXBrlz2xy91TK5OZSeVJ18JfFjqUoi
# DATA eVK+GT2RteYYndwILZt3VM/VoQvKCpkw4m3TaLZ0PL0dyuzakXpi1nNfzl0PvMziN+uTAaF7N7HnuRv7JO+WqLomJwrqownnrLMm
# DATA 6F8+dIBCi6dTnNEBTIgK28CIL1X/tmCAy43qWSH2Lk6EY+y5cf4px3mN1LvS8P6KLMDcytB+AyP7TgP7Zcb12xnWpUqWc8BC6z3L
# DATA pnMTJL1yUvWiiLhUQ5abLI2ImT0kIv4rY2JFoFiyOCtrrKJkcRwtkjk/E2V8oD0hc2kxTobZLpi8j5GHsoxVjhFlLzwEvHGXkj+N
# DATA scEkIasMe7ZkoM+rC70zzJYpwGAhC4xSJrM/v6Ld9mmE9sMpOuWSER0cIQHCscKkOl0ZsnAiuK8BnNWaZ+ZoeI6G52h4N0jD22X0
# DATA 2Gmusquxe6t2+1XM9uuw2h0Vz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R
# DATA 8RwVz1HxHBXPUfGeGypeqx30G52rUvFGo140fIGoeOWV553AeAXqW6NnUeMa9YahvvmdTpEbNxp0eypvKIIxjawmiEYeRLNZz8sm
# DATA ENqeHJ4KeoXwOs1g0BisFFTQ8r0gCMZBp37sN5ufV9tez6/6jZbXC+hPvdrFl2ovWFNyq2i+VkChterjZvvzTsfr+NUm1QO/eQF1
# DATA zgS2gokLOmszoGuR+yjyVuVstPIMaBTe+63mIGg36itRbrTrnt/yP69SWptUW6odf9pqUtw/rwY9feXKCfCDK4DuuFVo0J00MAt0
# DATA 12k2Gs3mDqC74ahdBN2Fw96gmYPuOu1Wr90yoLthZ1DvW6C7jt/wm51bAN2hSVW32xseDy/WrWU+3Pci6gXisCIBlxbzVlBxDV4w
# DATA y5fLikEru2XFSaVzaMURWfL322Gt88BfalD12PdWZ8NJPaOWwNYm3bhVVyNpzPIiQk6FLei69VsFykS7Vcza2pwxA59e/apvo8Ht
# DATA UAtuyhRxaDeHdnNoN4d2c2g3h3ZzaDeHdnNoN4d2c2g3h3Z7xdBuNsxNks0Htu4KSG2IU26v7X9HvvGSI2O5FPIsWYQTuR8t6vUP
# DATA wsW4xjPJPb64/zrlAI6j0nuUE20OjZnlnG/fK7zjjnyjHzPuRRbJu9iOt+fboXwqh8msQMrvLAXDz64cOdMEMZkCmiMd7hC1O0S9
# DATA 7hB16ZiPO07tjlNf9jj1FuHbmzpmLa2A7WDotcsqqzlm/QyFPG6DujBUx7NVzcBXb+9oX0na6mY3YwdGLgCvnsr7JvU9ZxYUWQzT
# DATA mAXoWgrbwL5/WXTCFgtei6r5m4VvZTyFFLMZ1lAMOFQt+X9BdPXzJr7mgomw314X4a4V4WD3+PKgCkobx4OjSVcuiKR6KNftVd8L
# DATA HIiVGPpWDLt2BIvR28h7eEu1qMiIBr24uIe32MrjYYwBXpic6APJ742gsok+hI/hZzzQoe1lZJbMK+zTpFY6gdd/cupBSROVLAYv
# DATA T4wi8dYLnUtqHZ8bp2aoQhxSEBQgzJyxDnCQwOhRIenj4Myf4JocZQusu/OUiiWYpmwRWyIAOA3OCoy8jDrESTJP1m4ObTEAmGzo
# DATA /bJkGumO6H2avRxjhjRmAAa37wF2B6sEIdp5X3MxoOHlOVjsILHOkt1uyTq79SW3Wy8LhX3m8kC8YG4tBK8afZOCJCBTfzIW3Vb8
# DATA gz4fI4UpspWh+sxVhV4QBY6bwKauKCBdNzl1jZrUenjqbkqIpfqHrLZpCiwi/WaKtKphnVXbcwVp3tOjJ0LLTOBUmp/KtliEedbw
# DATA tCDpEnrYKLGcKvsMFYw+ZJEylBCY1KSigaLQye/yDcYoKUtwc5w/ZrFXiXJEWaxj/J6ZqMU8B6Soip7RIk4rrMzOsdGq7AULTSve
# DATA 2/gANkgRFFkBOIKxJdofYWFue6wfALqiYs3blKKhjvg7WuJqSLNbxIaSwLlX4SlfxTvFZllRdUKPsUiOIqhY1TzLqE5YWXTqMahA
# DATA UV82RVe/cDXGr5CAjd0nOUvTWZrrLM3COOU8ps5jepGB+uyFKSUGmVJWTJNkyip13CByecrJRJrKWpHEmqrnFXFWVGQwgu4cmhHW
# DATA p5kKxp4VT1bvVLviZcTLUcDeZStBqTtKm1TLjRwmer45YzfhAg4n2MAgAtkOCrYLFEwsLtu02nSn8XMz3UV/2Xy/VunkXFWfN9+t
# DATA ZTyL5sfzjxHL8++SHBf/wG9vRrnowhCUyw9mEXUmc3YtVnFkUVuGWN/wW96RvZIRNOt0QbkRP40UgYymINgqNzmtkN2Ovb99qhcj
# DATA fF1gvETI2EOSYc1DTnVk3EPA2DoJs7FoqWoLnS5NJtl1cHBuJf8+OUk4/4Y0Ts2LudeoF3Ov2bVy7wEv1CDZ3NeqTIJiKYDOC5aj
# DATA FGlMuUv8wpMI+CJs1vXUIVwRKr2G3Cq0wctnWGtzhlkNWvLse9SnUuzeTXkqO5cJTJ5vQanWNTotK98WMKV4mYwNp3i2XGDIgWjp
# DATA pDix4hGDYT1U82h2pSh4ZhJ2jB2Nk+cg79qXyLu3UAVSkZXI1wcL2Veqdo2gXsq+Ck+l2UQ9kqLIaJ4qSqkg9klrxH70YRqeYCuv
# DATA Xhpgvdl8aeBp8szuwy+ZZR9szq98NFAIv+RhqK1rnUnvMqdCuBFA9wm98JhsDmOmk4X7kBreRKGdhqw6PE2GTPLzxlgH9j4WoWBm
# DATA WuGKWT4xqzIZDfSU66zJixZ9HdlmD2aXrmnB5ozLB0bJOOMYKBpoOg8f4Kryusw8v0s1bKjzKvQabd4zRBUV2wLZhUDTJeWIEduN
# DATA MfJc1xLvaBkrvhdzY5X3hs1G3nL+vCK8XhaHRI7xGsULSMzaHK//9+yr81+e/fnsSzC2vvLO/nD2+7Ovzv7H2ZeM3vpyFdj1X+in
# DATA 3519A8bW+b/HLZ4guc7+cvZH+unr81+c/6aCcP5/9t6uyY3jzPeca32Ksicc3W0CIApA4YVUU0tR1MuMJPOQtLVnLa2iABQaJQIo
# DATA CAV0sy0rQrZmzszEOI4jdidiIybO7sTGudibvdDYo2NZtjQX+wW6v8J8kn3+z5OZlYW3Rr+ySaZskkChKivf88knM/8/CpPC+o5+
# DATA +6N3/Hf4qUh3fEO//5rf9M3Rd/Tmr4+/YDwYkF2KAPZr+vpHCpB+csyu58GlkkH90GUObR6Q9CFpDB8oNUmNC5zMOlNWv5cOhTIs
# DATA mgp8cR/Tv3goLkhpt3Ch9nD6HBwAKJTwU+Aw8kZU3u7ZURr5SThYi/G6j5XxbnhoYuo4XravRXUQVw3yWlIql0fyUrUwWzJ6pKrl
# DATA IKZ4Tg7n75faqG9+J1dJLxLmBZehiolo4cvO/EjHywG9Niu6C2d6PYoy0EHGgpgAkqq7LEPl4JLzUvQ22AskMsIMVTCniOH5OcTX
# DATA kvd23NWzY+rdZHotzimV0gWy18mVcbU9s9jKnhXa6+RUOLSXMwcu3hzQtK+zWQEvxWrLVVkAl2EAbDT+n3L4v5rRXyrmQi5Y0K9r
# DATA 1qgugwO2kHxATbE2lDLnfX3KClwDoXrFSZhP5ztTtTWCt0CwSEgcTsybdFCccllwQnEq18FGZLDH7OuFPwgbcFK43qJJOCgoS44G
# DATA tLg7Q/FFXS5GGGsTqiG8htzNME8cYW0KmB0jMA8oUHF5wDlFbRyumXhUpCxmELtH1sU0HkXaUcXLZwgdy9AwWwpis9CLxQ4xIChH
# DATA CXOUMEcJuzxK2IZDzkZzoE1N56udBpxlFnARkwBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBH
# DATA CnOkMEcKc6QwRwpzpDBHCnOkMEcKc6Swa0MKq7WrXf75TKSwRi/otZ8jUtjC0vNGqDA7X/zAq/rNflBvzdGm6tQ7NqNltKlqU3KI
# DATA y0jKoMaKlELK8v2cUs982VV8u/Dqufw378yFHrT8Swy9Vc8Cr7VygUuqssD9at2GgOUCb/Wa7XZvPvB60Lrw0HOgt5qw2ARS5tcz
# DATA 0FvQzAUQBWHYrC40C3rc8/3mfi0YVJqe3ziBQLa6TjTOACDjxqYBZNJucwCyIGzVNwCQ5a4AQBZ0O71yBiCrd4KoWTYAsk6vU+lG
# DATA FoAsqHVarUsHkOkGuhY+VfIDTSHL3W9GR71AEGxCG8sHoXljWT+uc2rBkWk92saizJJnNl0WKNWVBVKxHQ+V0pI1YZ8Notybcx4F
# DATA sQzwHM9fjDfJD8hOgEm1xCNZMR5JyZT5ZZYlC33Bwgsqt/Vci3pvP7NL5qLfZHtuGRet1WrlaWhYZV5NKcuVW2GuLNZYO/kb53wP
# DATA xn3oMGQOQ+YwZA5D5jBkDkPmMGQOQ+YwZA5D5jBkDkP2kmHIUBcolO4gKkS8TNTdLRfY6c6fxmR2R+nuzz8qwKG6H+2yBVtAR/sA
# DATA P+2iSt42FZpPl8E6mmzvfBb3tuWhnc900NRCYYKEo05UGpGFulNUr7ptB3+bVZ31wY1tid7ObXQFH249zo6xdQUn9rk1x8E+Qv1+
# DATA KUUc+1jzXqSfnqKkspIHTYwn26q3gj6xpJ8SMOre2B2r3fvpj2HY3ab0IfBX6bedz/jp3fFtPpNBcaIff8DXKB5LU5NLsMn62ybD
# DATA b0utw4SeG31WwyjP31T6zpT3CgmnT/4Y5WfvMQ5J5c9fTij6TPCg/IgTyT6x5W9/vvp1THrrRPFge5uSWkSad26yaQvIm8oSigkl
# DATA 2dQLakic+hK7cXc+yyqMdVnibt9HGWdz8bIapGKJXJUcUmPBzmdZhqHoUJwxZWP8qiLnsaQb0hnfuKFvLo1nZJp8pmJ+S+7EKTu6
# DATA r8ARoYn1Bzh19x9f/JM60whsXnzD36EuhiKxEHzR31kTNo5H2mE/xHFJXv5YDP3zrC58ruoITyZ1m1ysyuqB27naf1vq2S5msLrq
# DATA WTcUKkE536Ims5FICQuhj6sDtzK68No6Azdr8+qpCc6QnvQUl6/dXVg1P8uBuX5mXZN4CJXVrD2oRCEqOklmDrgkWnwGJR7QfMj0
# DATA qboGmsdkrNjJRZqCPYhHNF1cFihW0uihaC6THDPG6UycUWfC6Uu8+PoSpyXJXAfdCV5Zyfnr1+Nk3sMheBA5IL6qD06He3jVNBkm
# DATA E5qZrWXKXEfRiufnCPdlkGYWNTYuGjWzTMTkjKwZL7dEJFWaV9ju+GUtDSyYTSMnRi9Tt0DAU+pJJvJhC70/IausIK4n0bJH5I3l
# DATA Lat5yRizSMD1hPXQn02mLPUVq/eOaeQfiX5CoqQ+jIj9GqGPk5RHX6Aj+rmG40woZ0JtaELN9a9OtMuJdlnD70rj6zqIeb0+i8HU
# DATA ystWGSmvt0QXym5KGHnGUYKGdtBPciOUIAT0AFby7kLEBkXHmjqhzIUVfCx6Qs0xHMQ9KN5AdBvOB5GQGkVRV2PGTstPMRFVwAcl
# DATA pw1p9cISJS0HT9kEnjJMpOhY7159XgdEmbAbTSTw5fPqu7HbR7jZ9/jT6ju1uaP4Qvz5eUCn2Ll3SpX8JgzH1Tr5WVnkWBbs1dPi
# DATA +DwrykY2jF+TZLbXzxrDJwx7ZwkPjUuajch4ZC2qbMM02vN+ErO2VYfNQ0+foIfVOGOxuTHL98LYpDjsRdOLoAycI/+C0+XfG1H6
# DATA xGNnu4UWgDaugjuZ9LJknLjCU+YZ2qbDQTh4Qnml5QM5PNw2GwDTzahGLxpxGbB4G05BeN3ZRIvr0iB1MUyLrBmeFs5QWZ9vWauW
# DATA fHudxnjZ98dMnVlsap+yrajORdFKIUOsHo3AspC8ZGk6WUxIFb0rSqcl768ZiBF1+qP401lkFBSpktKEDqyEaR/Tjn7INRH5OlUV
# DATA 9wJyM+umTpuXJ9RB3etJTn5AdYdVELVUs8GQmkyiNHIVYgtVoUYNEp4s3M4TSEHOmbIq90KWXVTIv0GkJpmc7UpDzoh69/LD8LNq
# DATA wfXTteDXwwHbEWqqENksGhgHnCHpbIwJGCUwnLQP1dygIzqLstO55PFKDXKX5cgniu1GudaLIogoYqpFFkWUjqNOzERYUb+cHLKe
# DATA oZmEj6KDi8hBe+w7bQUsr8/CbChVsBVUrom5qCm4NO0acteGzl6Resw0rBOCykMZdUAGNkx17KDw+mQRon4hy1gFlIUPqVJDB3If
# DATA W8XUHptrC1V5gVwbWRDOr+H8Ghv6NfI1zbk1nFvjjGtCK10gl6ZRrqpsjv4KU5yqufFuPHNWxjrvBjMZV3LseaM3L3Ng97c6uaiv
# DATA mUkv72qwR05zRc96OZey85HYGULfkl5PTIOwK3ZBziHBu1roZ7aRTK+zrban7Ci/iG7hI97Qj1dIpNTTpmfU3808vyrHNzEMTMi4
# DATA J+OFz9zh4jB8KneU5ZxcNOajeat9J7xJhlNilenGUVVPm6jq7yaqlROj6jc3jqps+0Fk+dNJcdO3Z7EzV0z8asui51vRq6yJnVoV
# DATA NP4sORfA0z/w9m7yPsUhmdhyI5sfk+GdV0VaIctCHAux62B2KVfnxjS4T+U47k0JIqvIxjdjtQ9zaYUDR0wimgx2LVM7p/D/n8k2
# DATA 7egJKk3MexglDUhHpgwHIQ3vgO2M6VEy0DADU1SgbBargZSKTqgmW0JJNXt/LaQlhuRkUGSYJe/Yord0wcNMhCYKL0rB68a/+EWM
# DATA IYXdK6NZCkH+9JBs32SYZl5UO2b9aDA+YeF4rlSzxWPbr5otA0v+y54tevwBPmQlfqbAZCuXNMpoalUfsWG5xF4Oq9xiHc4mZBOT
# DATA SWfTDv8bwwu/Bm0wzyA8/g3+XqQd/vPRV8wj/NPR90e/947/5vjLo++Ovj3+L/Tk9/RJcQuZcQhioQTOIXsMRPwKGMXjL+iG3x3/
# DATA Az30LW77/ujfKBz95O+Pvgcu8RvGIFKQjnn4PMwwTPXKJhZc4UE8QY7SMwXlr+QORyMxWDjJ0J0lwmQRPaBSFBoBDCtD8KCeVBs9
# DATA 4zjq0Gx8Hdzwod7GQAMAo9Uc2tCaTOgCu2q44UKpXB7aUNURfRs4G5q4w78s3I/tK1aH+yjpqT0tF4425AjkwIZxypXdYQ03K7YL
# DATA xxrefzoeoJcJtTNkmHRngxDk9WTKmj0l7wP0/dx3Zfu8ePELG+PpWbP/ieIwG3JPmco2KLhQkmmo17LCkaBjFoCGJ1fB1VbLfMt6
# DATA VjjDk9PgcIZupD/HSK+5hWcZ4F8OT+GVDe4XP7ZvNLSfcmS/moFdquVcHljMwmfVci4DTjiXSqwAgASkOH9xx0qsPuc4n6BQXJoK
# DATA Kgfamt5EnaJ4ePO1bCvWEt2wkkbsFZ3Ptw2JhMbLmsUunSYdXnHk8Vij4pgfx7WkS3PtUWqiH80miRcOGf/GQ35EZkPcibE0nrMJ
# DATA chZA9BQHixF4N4I3Su2oVmuFZD1Qcb4XhSkixLZdZwpXjBiJ7NURSp2srauibs8OpX45WqGjFTpa4WXRCjccajaa2mxqGV+ljX8W
# DATA E/8iLHzHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKzC
# DATA a8MqDPxaLeickVUYdXt+1HiOWIVzC8+nJhUGvlf1y/vFVutTv1GsNrxGQH/3q0Hl01rLq3j1ildt7LdauVzq+O1qpzePsaOw6ksx
# DATA drUFsqGc9BOAXysP8Auq/hzBr9bMylqOrWUEv6gZhZ1FcKLFB2wGueAr1VY++FZ1ZegmmbnQa+VgTejBmUK3S6Tpe7VaY7/WGlLX
# DATA Wqy19mutjXPaX4QRNnwv8Bv9ehDMhdIJOu12ZymK8vTYQWk3GjsoTdDCDta7QbPRPRE7GPbavXoOO9ilv7sVCzvYrQeNwGAH251O
# DATA rV2zsIOVoNasXjp20GxTg/D/3kbz9TXcPrFvvQW7SJvjc28zA6Waer0VUXcThwWJ31KAYaBW4ioLtD4sLC68YM7tbhuNukDy824y
# DATA 9zwfdoBXlz92mGydbpxDgTadkCli5OaDuhPOGyoWNjAfWXtzgR7R1bJXeZm3VxZT8kmrwPfJf6k/9ox7PXFwLlsL83myxmxZm2S2
# DATA Jxxw0AEHHXDQAQcdcNABBx1w0AEHHXDQAQcdcNABB18y4KDNd5NkixdDSGl8VBzR3/lxs3yjUi7QzFL9dMBFuCNTNo35ui+HZPig
# DATA GxrZDf4VXLrOEAFH3v/3f3itMr51o2hc+pD+G4G2RuHe2S2/9uHWB6ylzufoeKEGgdCPEkSJpzwUYQnLHL5BXLz2Ie5lOl7YThHi
# DATA jnkKn/hd79hH2SR1XpRO4UeObnn/8ev/F5FZSPt2tVK+IVdZ3BNdA4LUKDOHEHNnu0862+3OdL/oZ7pPSwq7Dme951xs6zFh76Jp
# DATA mCdK3nuo9ra2y1I42DM9Hf78HI28DArY/GH2i2aALUoCnJUAlvfX6rP67zK1SyqCvKYXGV2bN+B6DL1uQj+kB3xG+wGckKhaLAXU
# DATA D+NJyXsUT9n9pAXfpQKKcPlsLMeTVeHmju+HmZTRGKKNSY/PImeiOXMKNwvl/CSCqRwauR3YRFevdPOMTsFaLcgZQ84YmjeGFnpU
# DATA J3rjRG9OMqOuhxjOA6mvTLToJgZ/8UnSNoo4D412AzXDeG+kyF9KQ03hIyc0LHQgbtHDzaIkkYbAr8I9qvE4vCGf5TtEhwZuyIGt
# DATA 3bJEM2Vj8NdjqM7AP5Yp2dg8GPZdiGqHw31thvuipECfRCV9yq1mNeyL3Y4iC80fV9/L23O5Z3nMn54HeJeVF6fkrjxaw0/SuSrE
# DATA lXtoFVS6YlsJcOXxQSJiTckMgjEh5FgEsjJES9ESiajhIXuhRJZJzEMa1/bhRf4F5Fkmw7x6kagUke2XZONdCEEYqh2haNT32FDW
# DATA Z06l0ajZwXJh50UBaLPwJjZJlkCTY1rKAWMDFpQ5Y+gBSxD6fPyrM5fcw41L7qEcMBcrXRfdu7BF0BGGzAag4thT6t8pk76iMavj
# DATA KJZQHh2G4mNJH1H7piKQSepdzWeEx1Dti+LedBBNFVhgouKSjpPp+Yssl7KrK7OsNzllmf1kHa1M9UtSZj+BABHysZ1QhGxAFEsT
# DATA 6XUULWi2J4wsyl3qxHEx6ZE1YnhavehANKf04DYVSXjcKYs7XNIHTH9j5oppdFz67Vl6eP7SyqfpOSiu9zcurvdDgNt5MYP6+oxH
# DATA lfZFS980Bur19uAPfxIdirXfDqGg5fWToTQsTA5GHBpr1I08KqgJaGFA5YBXxQ74XvxU8HEMTcgKc1747fyFlk/ZlRVaNgqfsswe
# DATA ry4zPZ6rXlGUA3EtKy/xR2AfPoYBakKpsAIH4ohheeSOGifYG+fd5fLtMb6LOiGIkGHcE8sTx6a88YwPz7F4wgholwvo97K4X/8S
# DATA qWxaIu9HSrkOw8dU/aQIl3I+KNIDjDQnsTZEqC/x+HgXWsChCBIKGFC1Gu7feGaNAGB281AWp9pIQemK/t0FtJnFhJypmK6WMHcu
# DATA jMnL4GezgnCONudom3e02VXK+dicj+2Mi40rfXKXJDgtU3KZ6WEEROWGjWlcbM8QanBJ5LmcJ0vvPYG9z5ussfzU5H0zPBNWv58A
# DATA OstCMd2VdSmjxp2EOqtvyGE70N4yA+7ieYHatbfdGZ4IuJMAMsCd+m4B7pZi43y5rMFx5Y0hd7KbB+5CfBDGmFCQoVLMeTXnQFQP
# DATA ZN5DHcKCz65RZuwXtrV7B1jI5P1FjfJqL5/v8yOPo6foibrWU/TLmsdq/NjbdPeh/UytvMZNuBJRp01T7KYlS236/ELqbNfdQZ9C
# DATA 8T4hy3MUHZZsyWel6yydABxCB4nnc0sLJwoWpzesjWmapEx3rDpTZ0FxwvSKB24K2rjjxaHBfYt47JW7X6tr84vVtjOPAZdUYNVK
# DATA meud1cKpj5pp+KXak9vJ11ToTSsZdgpFq7AXyMJ/Kl3fiOI4kKkiq2aPZxOA3mVhO0lZP9USyN4AIveCGM8ZQo56kagzCXtTCyH3
# DATA nr5WPP7bo++Pf3X8a0Dkjn6/iI77l6X4N/ryNT315fEXx7/CZY/++Zou/o7//grgOLry7dFXx39nkHDfHH2tFNKh8DWGdioN2Q4T
# DATA d+1NfbbMQ8/UGe+vwv3Qu9+N5SyWiN6rfSU8++1N4mjUpQ6Evx0kk0HXWP/wfM/G4juFK0FcZ4NDpusmcGkLRZSdBtkChep58FT0
# DATA lBpady1C7nUIaLDWhMd/C0/CceSyGYHpFK6aI7e8aC4PJten6DC5IINTc33V10+Cyd0LRRL8MoByvPmKbEf6l8YEcV1hNEeDcUC5
# DATA zYruwoFykmchmzkjdG4yrzLTKW3YqMnUUDooslx0ReEFPhre0O+ytb03C6lRTCPq296I0ycFWD/09L0HP/XScaRIGTj+TmlTqjAz
# DATA toHgWpxuQJtbXkdXmzhL2+B1wc4tT4xDzznr4ZKsB42lO7PR8FK4EK/OYLgke2Ejc+GU1sLVGQtSSZdlhjEUrmdDuwyKnZUNAM1h
# DATA kbgbjcGhIlPGDNQmh3g2vyJbOslwOEN3jQW8dzCD6LDDgiVFUsqXTmSP+JOIHRTi/UOGpWqzPY30VGR8vRdP+BRtmm5MuANIK1W+
# DATA WQ0TowzZJ4twIn4O9WuP5soxH3DgHUHvJZ/QiOZx8jqUgUlvWvIe6njLAQUFC5t3Ai/YLXJWQCPIjKYFk8yQH9DFgXRwnzI57oj3
# DATA mNM+EncN7+WMRszRwQl5tC6AyFSVoFx1zDvHvHPMu0tk3m04ep3pYNc6s/zKZxoX4VE96zzDAfAcAM8B8BwAzwHwHADPAfAcAM8B
# DATA 8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwA79oA8Cp+tVutnB2AV32uAHjLVqA3ouBZvLhK
# DATA hqOT02hZvjfmFEqDZi67akGrEURzZLVKhQqgtoasZr26deZXNyvtSr169ldX6md+dbXZaNe6Z391tXrmV9crrWqtcfZX18rPrKxr
# DATA jWdW1kHtmZV13X9mZZ1r163mVWZ4rl2f7tXnzfBcuz7dq8+b4bl2fbpXn7txlZ9ZWefa9dWWda5dX21Z59r11Za13a4rQf0qM9xu
# DATA 16d89Xkz3G7Xp3z1eTPcbtenfPW5G1f5mZW13a6vuKztdn3FZW236ysua7tdV/3alZoKrTO/+rwZbrfrU776vBlut+tTvvrcjav8
# DATA zMrabtdXXNZ2u77isrbb9ZWUte16qJS9aqPSD+rl/UbwNn3NOx0a7XpQ6yx9rFZr8GPV+uJjNTg6Gqcxx9QExILL+/VckH6zWq0s
# DATA xiQoB14lCPqV8rAaeOV+pTyXG+0gCtqNpUj25plo6tWMpi7+HIum3iyHUVDP09T9VtWvBDma+hxfHTT1dtTq9DKaelCp12ttQ1MP
# DATA W+1eWM5o6jU/6FTKl05TZ2dwsc2b9I2nUxbbNRY987Y2xWFtPzMPRDdLccuW3fRGjQZv0MT2TGaiL+52rMPPKq/hg2CbbcuoW9sy
# DATA VgLdrVDXs9aluJTTMjDLLrpG8LGEfthNDm616Ef8KXuqFD8v0auGcIGtWIKtLAS3Pg+zAD211VTvX5NlK/PreMnuA7XWq2uYWQZQ
# DATA e0EzT3dh7kRBfnm7vBq2bpfUGnf4srrGTm72qzuouoOqO6i6g6o7qLqDqjuouoOqO6i6g6o7qLqDqr9kUPXMYlTaDds7xr6jVHsP
# DATA RfsjE/64LcQq7rLZVh4cMq5cREWKw6Qb7Qq6gi7KNls06uyaiEwUYYPsVoKgHvBVzPJENi3d1Wx0nhorxLn6DY1SA9IRMbggphBm
# DATA 221K4PFQwUayX+rygmTaRchcmPiCas5to5TSUB1tlwv12g6MIxxU2b758w/Vf7d2//IH+HfCwXx0c69A5Wpx2rlsvUU4PVQFdj/b
# DATA D0fxYBDeqhTGgxlN+9Nb1QIk424Fn/+co8LTWBOXjzSe/tFsby9KZVxkATLv4d33bhlsfCeKB9t4w4357PlxyW8yTf6t+HWB1r/O
# DATA 8j+ZDu9cKBKACODQJB9BaH78OBaovF+q6CDROSuWCEYFEbyApp4IHfILVZ2BJt4U8nxTMpd1DRIlIUi2KCA9Z0KmIUtXX1tnTnEG
# DATA x70VluxnZqIBibQ5eVp6OqvkO7cxssBxNaeRA7EPlQAoudiSNxxjGQh+WMgLdDidOqdTdxqdujkxF6dY5xTrlmj+rGZZXBclO288
# DATA QTtlDa18nIyU3d28pNveDNK4EGZapd2mwBYj8GbjTqyCxvyO1Vi1WBXTaOcl6fJorQU5OnNfv3LnAYYm6lp0xMUbruWmfibjtlJM
# DATA y8hXsIETJtQDAwjUDZZxiqyiP2WBegkuhZavJ2O+nurehlgstKaU2hwQW571JOM8oWxFcY6gjU9JiWFcaw4hH/lLehyd6CkgaiLr
# DATA hZ7KPEwj1SqlPk73G8ouYrm9TOlWDY06/Y+MIeVpQwqKdcD7iFIxzYeFeqJyKGYdi5L3M4ycC490+jPoFmv9MWWulDyeNOQGWsED
# DATA CwBVPLWFHFU4syjIuIRCn/Tc6GMZsxIjwgwqpleZswTpuhy5q7p4yRHVq3NjMbkxTcaKbcB1JZmwmhzUz9LZGCM0thxDz5nqWifq
# DATA Wv3/NHwicAVYhWzPYPI1PlSFqgeX8CA8zCwqGYAk9vBVe48jdmTquDHYNbRMMQYR20MO1614ui7Z/H687ZOEMq2NwTDkOkfzBp3w
# DATA d+FB8SzbXqsCMg0qrxcoNFQW7aIoYWFrzCXHUnJhl7rw2JBtlKCcToDI0Gn4k55gZIJymnXDgM4wa2XGVGOqnTblVDZQnzNIDtnr
# DATA Ow9ZE2WwF1/gLBt1nIHqDNTTGKjOHH15zNGVZuY1F1a2F/gXEWaDnJ0qLYb+nvZ5QIKtoizU7BHW61EorOsqv/x8qYmeBHSwtnII
# DATA bo63yNx5lTro+Zaqj6PlNnk1y3ObvNRRs3DA35a1l8VjYtL6OwncUvLGw1FHR0epL935ycIpM/bgk82zQsjbepa/cLrmIGB6I43W
# DATA yn5d2Yx9rTzN+aONMTbYlos3K6tMywMzr2M2tmxJw+CkwR72qJ4uGMxX3sDMm6OWg28OXzFfF16fxaj5i3rbUikWiF0nEj5G6sUF
# DATA isgkItMlbJPVrQAfc+0dp1+lKWgCcL9659FQgN+Um4aGzM2NtXxDRUTez89aWAYc1PdxlIwH1EI/4HUP5EU2/2A1M0VcFJnknE54
# DATA 3nCchqi4GvRmrMV5pDRHWZWejq6a/BljH7MHXZ6KmSYzDOyEkBknY0kwS1FdlSrtNRF7MCEjsjNdH7F7vN7gpbD4D3X01EWZSbMF
# DATA 7oWoSpxHyMmDCatmJwcjmrLRT/EQcui6si6NzT2Z7C3G5iUUKXbcZGfFn9WKn69yzs/s/MznNuBXThcuz89seOLzPA6DVbuWmK+r
# DATA 4C/rlV/64f7Tsezb4VVwMmWiZJZqX+sJPOMsGNPvWZcMwLd5EoDZ3xhobIz+D7gbRMTyAGN9Q8ZYNtOEea6wWmXHb8pxv5pBrNbh
# DATA ZZrHH1ffi1Jns4399msYxYsp47V0kzp8Y8SEMsy334pfPxExbQWTzwN90cSzdlKxBKfgTPOqv4L+UVTlAvaEUHulTFgfafO4hZ3W
# DATA VzLe9EnRrW4aW97IkXVgQ+oYqO+YiyN259io8Wk3zxmX7yZ2d72ULCa9TGNHdQMm9X2NSuYOYhLxmoX2TD+/gGqzViAd8CCcjWg+
# DATA hAWBdJpnVJv0dwGnYbOL1wgsyhB69gnIzEBISy9T8u7i8n5M9o69SMaWUPS0o1YzPFmPUEcdeoqaiQ0eoQBsDlNsWONZB8/YxIji
# DATA tQplKE3CWNGbwJIOx9JTz5Vn5kBRvWO2iSSXsZZ7xCB5FrnIWbFLHs3hmJZwmHiFbR7ExEyrbhIJPkrN/Dxwog5QySgzGBnamSq8
# DATA jxmFTuZkv2izJguYPUvjDrw8cWIhs4/+2/GXR384/kdQrY/+dPybo++Ovjr+rQd2Nv3wb0ffHP92kZ79T0ffH/2Z7vv7o++Of0t3
# DATA H/2BHv53uvdXx78pePTpe3ry90ffH/8aFG0ELSTtX9Hf3xx9wxztL+iRf6VbQNL+o0d3gdf9Gwr2Gwr2Kzx99DuK1h/5SQrid/T3
# DATA d8ByH3/h6NrXf0JInVgyjIogywkiS3OnuK/qUDMFCG/Ay8C8Wv5AjRChtmkLggRj5xSZceNBpHhhinZFvd9EQ+2ZDZYZrWsp2g/x
# DATA EPVBkUNn5+Z7Wfdw1fBsq0Quj5italVqzfT4AlfMdP7udhRm3fXr9IUrYzuisf4iUdkULrOrYz2Sqa0VC5O6l5SVvUGhXTgp+14/
# DATA gU59CIg5jakjbb9SBrPbSREluTehclvYAy4+X7JYqJPajwa3Edc+b5Mi+y61vVRhKr2h3pxymvq32oLJWtOzYl+fGHmHvXbD+jmH
# DATA dY23Pt1o/nJ4bq9wJL/IgXyjcfxUw/iVjOJSE03Ss92+z7SpXAag2qRRtoeuSh533srjw+VckJ2UlIY9lsoIp31JQw8bIfuyZCur
# DATA zzQ9D4VMO+kfTvvDrMCsvZChzg2FLMZQvAmR+v3EM9EV8K5mLnNsRoknrWY5nLfk3eUfWaA7FTIxKzrLEpbqVRFQOk3GZG31FQV3
# DATA GraRYXLATqyHLFUGkE351YlT0afQWdqBM8LxpR1f2vGlL5EvvdGQstF8ZUPD92ps97OY7hdguTuQtANJO5C0A0k7kLQDSTuQtANJ
# DATA O5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0lfG5B0rVINg+CMIOletVfuBc8RSNqsOG9E
# DATA j7bzAy7WIOjXy5X9arX8Nn3/xXw+RkFrCd6q6fnNWj+o1febwFs18491/G6j688/NvRrgVehR6vlot/wKlX64FWbxVrNq9L/6bdG
# DATA senVqh7gWX6x2uRrFdweeNWWV/VxNy6XvZZXaxYrvv1W3gmZZ1tVu0FYLy9jWy2pGwHi09j3K/OAtna97bc7y0KpLcD4bEpaNY8M
# DATA lnAtgFc9q77VPMk8CoNGeyGGlUr9/DGs+NUshkH1gmPYal1ADJv1LIaN+sXGsNqonD+GVW4Sl1TKNWok545hrVq5vFIO/Ob5YxiU
# DATA g8sr5aDlX0AMG80LLuXTgPRkENIgPRnPLJBeqxb41VYepDePzeMr4TxIr9dtRUEG0quHQdRoGpBep9Hu0hzdgPRaZB1Xm5cO0uPt
# DATA n8V11n2pOsen+9x6aJFFl3MJ+c38rEdnAttYcNlS3mPT43ax0o32dnIhzxH63opoXI/DgsR93vldZde3LHkznG9+/V6FzJO1TdfU
# DATA Stp8Z39u1Uo6gvH0xqOc5W4cCzhioH3h2BhWPOUSUG2ZA5r9cFZ4ygu2iOdTtSlfGigMyyvRwPLK8u1QC68oIdZks1qzfDJRdWOw
# DATA S5is4qDTWg3dy0q4YJfJmlnEYm1TybWqkXJ2ry8cngqg1q+cRmUFdbr5qIMAOgiggwA6CKCDADoIoIMAOgiggwA6CKCDADoI4EsG
# DATA AURdUBPFXbZOCyEOfRYg4TspsAxb+bbkB58O25XaEnf/1138WERtuc2BiHjErhre1FeK28/LhUqhVqhTHxn35ntIddvOjn7c3H2b
# DATA X2cq4vaoEIP/NtLd3q56wur1dm6P1uYSAHJ6xMrip94jo+TT3TtP9RukJ6Mrys59qroz+g/0OnuOMcbRse2dz3I5eZsPAWtbkTN0
# DATA Zy5Vo907lCA+fgljlOftaH58Dg5JKMnJT4X5o6C5V1IQvB025/LT0A+31Hk/dBRZrdylUZclZOWUMdVHYeA9lEPHSMKYOljG3JmE
# DATA TdniBXLvB+rtO2L5Ly+bE1IyTfb2BrmUFGJq56hFkiQO9Of4/pEpAgVUTHa5VmrbP+1A5xHJ3Sns5X56iyYRVLETGrIiyphR51AK
# DATA jV9Dbyu/5jfLt6rV8u290h7dC2PxZ7jhLhv12zi1UFAByjZ0XN7Rd0dPx8kIgm3h4GE4HD9O8s+W/cVnb5TKdUSIEjKiItreQ2D6
# DATA i9wNJb14xCubuJM9UNvyKRlvLwuxQcUkBfhAMpMFEwF33MaHGz4zG5Oe1+Qi5cTrX37UvM11cdeayKCkC9UyVuAEAAk3SsJ17XM1
# DATA J2FlfI1g1NXhs6zu31ZV43PdBngKPMV2Iy7Cu/d2D+IRTaxKfKqc6+XT6S9/qS4eRO0n8dT+SXqLezvTPo3T3v3JhGu3HEm3xmmk
# DATA j7NI6sEvf4n54N17FKHwIIxp9sfZh356iHFySWU+ZStKxlYjkv5RGsrtz3m2b+eJlJHEOW9eLB5fF9EjUeCB9KGc4m5HXkTTNN02
# DATA qd8xU9klXR2fj4sHNK3LdXooMvOYDHk7ViwpUFUKS4LEGj89YoKynuOsfU1avQQjPjVzqNZp2Tgtm2VaNvmD1k7UxonabCpqs1KA
# DATA /LLEbu5j3YVHV6hNjCJbtkUL3zw7AbWrUBkXU4AuP8YHbxvFkd4cxqPZNDpJx1o/azonc8FILivV8HlJaNkbojShK+skrPUxX4o2
# DATA H9eFYvwhuizO74SFM6h0eAGtLytNXJwUgNyfzxiznmTlhPmRzVJespa84SlQme/MZ4T24GRZYW7Nks4P+nPq1uvf5W/+Lj+fzXiw
# DATA cqp3VTZ/VyX3Ln6weqp3VTd/VzX3Ln6wdqp31TZ/V21Bav1OcKp3BZu/K8i9ix+sn+pd9c3fVc+9ix9snOpdjc3f1VjQf7/TNO/S
# DATA +iqmDa9UV7enry+AmLoeKgTpopWIrNGG+r4nglbC0RmaykkHJiMkZg/AJvMkfQippUmuy5MQ/IJXLXgBD0cNULSiEQupethBwEEL
# DATA UHhoSGBWxGigWu4/9dC/MszAkv0y3vZMVYqGKcwbtCIYBkGEKVbj6fXANpAyf/7FhBy01U2d1k+d3EzpxZwpnRbE+sxlQXlzV7bP
# DATA 6zIQnpb85gVzO23x0qWwzpU4WdYQ5JOHpqUKFwUy42uwstdAHPU5EQvcUN7cy3YOauNKvJZ6viwndih3aDINFU2oJBlD665SaA0n
# DATA LHIFxygZQ3iazCqyr5h/ymsvItY6lmk8b+2CDiPm6byrqYAHVEFlyo08oadCigf0jn3sRBQq0B7YZCw/SS9nRg50+bQY+ulzEWYf
# DATA a0bOacdepWT6s7GUctXSGUvOWFpmLOW6KudmfundzCuNrGevqa5rPlXnkGWlD+EBGNF9vBkp01gfT9A0IQM818j2ZjQ/ZlfzJFIa
# DATA 2Avy3tRcjAK4pQyeqCk+16E5x3LOalgUUTf30biqmzGPSFS6Rl8Zw2bS63nhfhJ3efVzlMQpu8QnWlNbuoMMPJ4lTCu6lbxHNER7
# DATA PQpNRNRTXieVo8QYfAcSl5T3LyKQQ6MFTj3LrJ1So59NxXBjGTkwv7uaCIcYl7z3lM62N4w7k2TcZweMwsdFYYfd8niecgC61ei+
# DATA lnviM3dPyLbGSKnB60x5FE3FjEgz6edBgo0sU9B8ZQPeOGSoodXtaYBeybuLzKSg4/FYgbcRBLvkbntY2MZVRm+Hcpdd5h7OSKAv
# DATA HiF3NPpd0s2p8g7obbwyviZ574ewa4RbvJcY1XlcZXOLSgJmsRSwxs5TqUslnybDZDJJDpS+t1R/XiXXRcNV35NMHGFfZzLrQAOG
# DATA Mejiu8oO8WZpE4a7gaZTUWHgU5Tldel5k+X52TOGBZ4FQM6ALDqegkSwFsUCVYrwCQapKQ9hfTIZbMOS2iQmDWzqpWIa0u09nFBH
# DATA UzDjoFQH4BAFE4AXPYkYPo+aR9k4lEJi8jRZlnuoygOQ6CkysxEGZqwpJeN0PpFiT51ECnpd6jmvXCE+kqOSC7N5jzCizYNNbiOt
# DATA 1esWteMYw9xKr/I6J3J+ocSUwprMy/zK/MpzvtaX19Iv0qxM47vY1/ByiTSajIUlzAJuRBf7Nl4wecglayrrFJ2O1QmjpVzsW3np
# DATA BPu+VzfM/Atvzgbn9MW/uLOfDHFJb+smySS1+Zb/cvT98d8CSHn8j8yd/BUTLr84/u3R/wBR8uibo68XAZf/wgRL4Cm/8I6+xT8M
# DATA s/z26Jvjv/UYffnF8d/Tny+FcKkCphcx1vI7Cvzroz9reiWDMem2b0G5/Pr4H+i3PzqE5fWftz2SmdYkgZHEpjAWjZLZXn/KjByR
# DATA mVbD6yCeQl1DThGbidhspG0XMqUw6oUMb5UBny2YVGZuwKDALAz5DOpafuUj3nFBfWE88D4hi5GNKEeyzOZwuhe4aozl0oK5PKAl
# DATA 18vUmj/qairIo/zNqKzm1geq5mJ4u0iaJRmrLKSg1jBlrwk1ibEjWW5QWhcOsryrtlYNqHkcFg/CwZOM1ERmNXg7wP+oZMHW7YQ4
# DATA bkSj7ATybAqvE3YxQhho1CiKyMjHAjzVy0OeGygKEs7PjxdIlifUvNVmybLm9KyIlickwvEs3Rh/njFewyzPOrS/FK7ZKxvWL2dU
# DATA 32hQP82YfgVDutTLJTlgBvRn2H4ug3C5JKkezUPpE7PnQrVMKslFLAu8zhki2+MOxlmkmJO7LMq88Vk9PEkEFCh9Uxvr5hzfkOM2
# DATA yqH2NoFb5hzdiJJKhtH+ZHc3tvp5BzTHxhqwKB+kQgX0fppmJpSM/GS5YZd3j2IWwxAQNGE84rUlQ7uEtRPLC5RnGIXGC1l3LTSk
# DATA 8q12IxojhzGZDQf9iGMRemya8Aa7XuRol4526WiXl0i73GSI2WhKs5FNfNXm/Vms+3Mb9w556ZCXDnnpkJcOeemQlw556ZCXDnnp
# DATA kJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJfXBnlZqdXCoH5W5GUzarV7zxHycsnK82nhl7WK
# DATA V6vXPco3z6+WB3458PxG+d1ao+k1moNKs+JVm3NcS7q3vYjDHPqtqlehjA78YpP+bnmterEWFH2/WKHwg1+8V/Mp7GYwqFeLfrnh
# DATA NRueX2kUA7qlVqzS61vFSlCsNubKJIga7e4iH7BK0W586gflYlD2Kk3fK09r1aZX3m80365V82HUO81uo7IYRrPmBbXyp8VKuVFs
# DATA UqQqtaJPeUExChDTYrNxAlnTRG6Bo+c35XWdeILZUoeLv86R8DpctL7U3ImACnPx7QbNWq12Bloe119Ny5OmYNHy2vUgqvob0PLq
# DATA 3ShHy4sa3aDVzmh5Qa8O29rQ8qrtWrOS0fKajZrvR5dOy+NqX1xvGLB3f843TUWFs5efWwFo2yDHTpNEL+LcVL4u+v/wh1r47ZPW
# DATA EJYbO6vgb1YsT6bw2ZA9efB0kL3aImQvC+YUkD3tgFyZR3ZOqwxVGDtV/2yPUYXtNDYGzCC2YhuBHrvVAld5Nfsuy9eCnVVrzIkT
# DATA csIQ7Rx8zsHnHHzOweccfM7B5xx8zsHnHHzOweccfM7B514i+BynDacRitrmoTS+tm5AYwSR5BDLDS3tTz1DH0NvMNi9sz1Y4Dup
# DATA FO/ojuw1CubpRzKt+bmHDzs3BvlKxjV/p/RJEo8ogA/pP/Chbhvz8sMtfew8i0tp+hT5+uHWGwsn0lUAN/BZk6LumR0KOlQNftJs
# DATA JacQ7g5WrzlY7Q5UvyQHqk+rF/5sD1qzXzJzpS3iiAY5Lcy9JOnibLHHfkJzzJZJEghkjc72sz6f/TycUeS/L1irfdlB8otWbV9+
# DATA Ln+pfvsGx+QzP63RD49EoA6lrWUnVeUwGjOPI4pCmgwjCMHw0VqpanwCXrnfmMgiuoH58+XZyfECZJDJ1swaO88ZoWcKD3DS68Ex
# DATA rQ80i+4hApeqxq+YP3x+GhHxhWoiB3LDzDp5NmI1z+I0q3neGVTOoFqiRpdVKCdY4wRrzmpHrbTXLkfIhvt03QzIkhLtCtbA6CfT
# DATA ZG8SjvuWqPgz0027AIAljctvKBkaa/Q6pWaxGAMI5AIFi9XYrwfzYTjmzLHG/GXKtxeiWvwBy3tL30i1EQop6PkuQbj4Tdjq/KKR
# DATA Fz2lfPTS0YXLB7No8TujdDYIp6JefqiSd4CEjqkT73nU3w0GlyFbPGNNpanmzsxYA3yuNVzsewNRnobEd9cTEXo9ztHwd7HvYvrj
# DATA g2iSshQTVqqYby+yMMw2KoYxGfCzMTXI6ILVqBtZJzpnQVNxhuDBCgNEDO4LloieY01m0zIJMu+YpIe0VpA3PDTmh/Q2BkeZASBt
# DATA RXWzHJQpymNyYNcf1YQOM/UpGdDkxFG6QlqqA8Ci1pWydKmgCsTiUt4jCHxHI4/BK6MOFZSWn+op6gHlfcEoZCWqd9aSplh4OtRa
# DATA STwjmszabYjkc7kwkxjVJBkwvljGAdE4mswg5OXpTDM6Xsq9GckLzGJ3qHRTN0M9vjjTD8ugcBMQNwFZmIDkLUw3BXFTkPwUZOXE
# DATA 4llraSpeBzMt+uGYYcMhZhi2OHYaKd09LQU5JxbJqB2tDqnQR5FMZiydx6ktAImxcnAAftJMcCHzEo/SYmfUlKnvolLYj5YoPW6q
# DATA tsmpHd95k5c2s3i3D7PZEXOX27N40DVafCoy7GhcdBurw6MWgF6jt2W1n4FV+KQsLGUB6R8zeLa5wioCfWbFcM8mi7Oye4WGbisp
# DATA eQi4eq/ZQgCrVH1+VTZGqJdbd5ie1X7q1YR72Mzwwxo8xlhqNuo+ti0T5cidv50mqOoww1v8afWdnUE8bHNE8WH1fdQxJ9iURXfe
# DATA l4/ZvTclbXfmMOXa1pTVeNvUxIiyxtDMlS42A0uzV2ekM8s5nHTN9JQ3P8hEVeVjPh/mwFy8k9p0B7KzQCa2M7695j0ZmmTMx9tk
# DATA KpQjq3cexsxq6kYME6LWWhUvwTBJp4NDBb/ET7ASjRQ7r9UIryseTWUIjEQOE7sk036i9ERDgZ5r8VgGio+M1Cy1XJ4Wa/e2ksL0
# DATA YJkp61Ad1LraDKyfIgM/oDnxgH338aRD08UsCzFHpY4BKC67o1OzHHhKqFv4RG3RoZ7sHq8SsG3Meythtg+TNh6h3i+SOk1F8SSV
# DATA RTNFAeOyuIjsslrJKfOrtTa/TJOTDPsJJD+pXexFJqvgTeB78nlkEFySkSXvAxozCx6r5MVkhB0q/5OCiFF3LpQ42a0i7jDNmadh
# DATA gzFuUfcissp0PKfMqMbajFK9mGTT2/DjiDkfj6xaxa+mCnFAsUzZERNOBmr1VPtm4ETANrgQWrWy0sXTbPwM79/eYeYvjLAEiD35
# DATA Qs4FcIz7PG6HkNRldAXf9EzbZHCKNvkuQHTo06jdFSnRRYFcmdpmX6bmJtQ6lZHWylsUpodY3NNEOHqEbH6RHub8FFskBcbLmpE/
# DATA ywrmVzavYe8mVMQ0Rg6iQ3YTZHVsQL9kFo7y7orDj2a31ATZE5cZa8gQ6uHZYaUXUdWiqFhbUAfGiZxE1VGyVsQFBRrhJO4szbf8
# DATA QCx76+yB2FyRbLjzfqJ3wWnlaTbB1O40OEVUSSpKtM7v0kkMsRfFAZGxxMbRFGheGyX23wUk5h394egrj7FeoH/9+fi/HH119Oej
# DATA bxYxYv/P0ddH3xaP/gQA2PGvASD7d+DCjn9F1//t6Dv6+3f09/dHvz/63jv+UkJH0N8AOvbV0Z+Of3P07fGX9O9v8SawyOjNFMZX
# DATA FMJXGkz256OvHE3sOaBAj2TlB/t4OkqlPqNAj6NkzPxGBqzz0E5tTwzEbgLlc/Y2YqCxXNJKDJfvQh+dCavzG6gHiUVCnp3Ha6li
# DATA b8FcYnb76NDhxGwfiuoIrpomli+Qy8WIxSNrDfe+rqX6l0WW2GiKQ4Cmj8VXGemiyUXyxMKpIAr6YUrDKSxYsnSTXs/hxDYttQtn
# DATA it0LBx2sOkayAHaYAarDIe+05yWQAa+TeD1MJTzmwrHcn1nlAEl3OIx48ouxhNcR419ETN/wunE0XYIRO7HSrbZOcm3p2THETkyB
# DATA 44i50f0iRnfNEzv1oP5SLIpc1YB+weP5xoshpxrNr2gwlxpp50G23erZN53LQInZaRXHsNrB0U/oOSw+5BOKFJhY6sLCItGapL8D
# DATA BvtgnApViZM2DdMnaq8KIhCPcHIMx/hUlmyGEgPASIbqffC6FKypm5GdpNrIsN7RNgHgUwk22sEmwNpWTAbCErtgBt2FeLrMHlDW
# DATA AIOPYAdg9Sp9QoGZeMRwjnNtovo1wC5t7CGbTSexlFky6kSTUeo4Yo4j5jhil8wR22ik2fAExobG8ZUZ+WfzPV6Aie9oYo4m5mhi
# DATA jibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijiZ2fWhinaCySLralCbW
# DATA 69Wi5nNEE7OXnU+LEfODqldtNT4tVstFn/KnUS36QX1QrAGr5X/q+9Vi4Pm1iueXK16jUmx4uAt3+E1gwPJZ1+21Wo3eAmEMgK9a
# DATA ueVV6B21hldrFVt0oeI16wgy8AJgvDwfYbfwumorH2xQb3abvSVgrmrZAnNVWoEBc/nlfH1o1xq1aEkAQc0KoGqRvZqLVaK2jAxW
# DATA aZz2eStfqtWGV6V8qARes0h/+f6wUvMpjzxkbpmzeHVC7FKkO2tB0A8azTnSmXlggXRWPwOnjFuG4ZRxI7M4ZVSPGo1wA05Z2Kvm
# DATA OGW9SrfRqVucsla918g4Zd1mp9auZZyySrNerTcunVM2jqYnUsowvuj7NsB8WY6yKrvJSk1eHsOQtrNIAjMha8xZbqZbC37kBfSn
# DATA ErDTMYfmkhyVEFSEN3OqqVQZx1rFTHfn3l6psS+Q3Xhzto14ntYgvHS6Crn4rRnCc7dpF5hDdjlkl0N2OWSXQ3Y5ZJdDdjlkl0N2
# DATA OWSXQ3Y5ZNdLhuxSFofF4eqGh+nue+G0X+oNEprYwOz7cAuHsSj1P4ZJc1Nd4/NRuChfaZoFQ5VaDVufH27dHdME7ylclNHgkHLj
# DATA BoK+QbnSm4lcGB8P61k6V+qsFa8igZQFpJY+zBWqw1nQIEOQcuwm5EPaOKBizmCJ3p+jbLljx6c9duyOG7+ox43Pgte6BseQ2X2n
# DATA /V3rKVsiYGXivfSo8hK+1nU5vPxcneG7DOBW/rj1BZO25irDWRFbliM1O0SucjrDgkCeUQTkleoKZ1e/eudNnuCzrpzWoePqA6HQ
# DATA kdKbk4OwpvochPREOznAaedobzaAfJ+WnRtCTjTpQQ2/O5twBQ0nQy19r87E87t1BO6SbR2T8cvbZnUUNCWMsqeHRdI2a3FO4Sfy
# DATA eHOKWCZYah1w2qBnx20BJyrbEV7cJZtsNmkb4cmX5KinFYazq5xdtUasza5cTtfF6bqc1qBag9u6HL2Xvx4lB+j+RXGgHe6Jxhok
# DATA N9TA5l+9nNgF0LV4BULtANHXctrwPNGnqz8dQW8hUjIsxi3mbT/Z25kjAY14HSgD7aggTDelv+dwSJRo6pKhJzOMWd62XEKfTT2L
# DATA bMkR4wh7ObMfV8jZix8CQB9bsGWMLa402G+fGF/9fNav6gsZhKtZXhZnO8bYrmNHeU2E2VPClCa4qzMdG2TUCXFVj5qo6u85XNja
# DATA ePprYjlHUFLrS2ityukiauRc1S1KEirVnVdlr6mKp1pjtLV8s0vSu8T7kgIafxWz9aYEcT4KlMVsstq3LXyk9OkV4iVEszf6gPfh
# DATA erIbMDdo1kqJnsai4sLDHXoc7YL6dEa9ELTK09neXsQeaAAjeGVCdRDJBBgLQJVYVRqjMAc6AqBioGlcwkBj37hqdxBQIVN+xv54
# DATA KhrowUAhONwzjFgoUME4TWUk78Y9lk6Ziv4QKzt7aitvZOIjcvSQJuJoLFEnyiSJWFYZnkZExgvHVOcwwG3KdnpBjN3cCObMXWfu
# DATA rjR3F0wbZ/E6i3e1CXtNFA7vsfoeNIt7GGTiEcuYLec7ab5sJgU4iYYxIzoKq1T33hSm4MJww8Jme7O4C5xhNjBSaNReuzMACHl4
# DATA mzeB89CEBYFDcx+N64Zpqn1PPNT/lDkBGM8mCQ0d4VSPuWyHD6mBz2BCKTsg3JtEGl+5OGQq/UMKqUtDtUkOXFULAydLA0Jchj1H
# DATA EWvCeeEUFZoifNumtmsyZPSUt0fhHTGgBpTrK2YEIvGW7PP+JsXg1PzcsWZ4YSOngEKeRpNOjP2OOQiqZDgXDIv2WUKFyktW8t4C
# DATA Z4u7UfamMbSrD5uL72KACYiVcNe9G025n+VkwLQJp3P+NhxcM5H1+HAD2Cfr0nhXy1Ga/l4n8gPM2jR7R/X9UJksiOaeBhPhEaw/
# DATA UkEP0gLTMVJD7dRGl5hJ7yMw9JSHMMHURkseWSY8JLVhaUfduBNKCSp8JrJyoaZbmLPoKY15g8N1qXyfjxQb84vxJTqdd3mnpzok
# DATA MpsU4ElmhfGhLn6ePipSTgz4iTJfR1DiU+KfFiONk5RXqix5j6LoCVNC4JZlngfykm9V1UIrVub4Muw/FW4I1BbhINaO4jDlSW24
# DATA N0rSOF0gc7AhdpLO9+OEOibOz6wL4lZzalI0+7T1GHQhnGjLza0aA9zb7MS+BDL0e6i+eh8MNdcQVVf03/U05RIo0fdyznK0WSpv
# DATA octeAin63XjKs7IJdVsQghQopGLWcM8pApOXAIt+MJB3ooPk1GaNi6dZ3UsARd+lDki3ePRSXaOvy0UKb9Gke8Hs5Bd9/mZxceip
# DATA aWpjcf4ZEJyj746+Ov710XfH/3j0tXf8BRA19PVruvzN8W8XyTj/wqibf2WoTf7uoz8yJcejn3519Lujr4//QYXyX8HFoWvfH/8t
# DATA nqBX/ZZ++TO98I/e8d/lSDsWTMehcZ4DsjCD2Yx2rTCy4PkF0qMg21CFC9zjbusAUO4DZVHtRawY/AQOZ8EJTzUrkSGjPIiCIbg3
# DATA WE/AeTcKe/wWh7/JzTG5vV81/cYqjMtD30jSsm6R606P52Hzt2LkMDfyVG/SP5z2hxeJu+FNtjTt6aPGd3lGAOQeb8XE7Q57c2KJ
# DATA XTjvBpPcpI05Jtcz7bHGThE1Heb+ZRBOhmppKpt8xqm4ohf2UIt+Otu2Mpeg0qJeDNM6Ml3g4F7A36yvf6uNj6wdPSvszfqYO+KN
# DATA G7RPMWhrsM3pxuqXwxd8NeP0RQ7TG43Smw/Slz9GS/UziTYD8tW1hcsg1Zj0CCE5nU+I3n+RbWJge6KfDDUMxioTmenSgIbBLuxy
# DATA QpmCbogUqWIsd5LZRNgU2fiqEy5H2eklyCsOfjNujZri58bg0DjX9ehtxu2UbuzOBpHeEslLWPAqeuk46sRRWjDxz9jFytE6iMX1
# DATA GlFnG/ai6WHOFajSwThdxkQzCrgjiconyAFqHKDGAWouHlBz8sCx0ZxjE/v1auzvs5jf57W+HYzGwWgcjMbBaByMxsFoHIzGwWgc
# DATA jMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaK4PjKZai6rds8Jo/F7wXMFozHLzaUk01UrT
# DATA q9bKfcbPVGqeX6u+XQ0q+ezo9JrlYJF/UqMEVGuNn/mV6jz/pBZ0as1l/BMupXww1VbLq9Qq/8lvVbxKpUx/Gl7L/9QPml7T8xsV
# DATA zw98elfVq7Sqn1b8etGvUhmCmFMr+nW6pUjf6KYa3eTTA7X/VGnRoxWvSiFUm5/68CLXvBrdU63n0lWLmq16eREQIxEqkglf9P3m
# DATA 0K9RvuBF9TLwPHNp7bS6rbCzLK0KPUOlGJP5odg1tXKQsWtqrbJVgWvy5XBJbe52onqndwZ2DFdkw47hNmGxY2qVRhhUT2THtHvd
# DATA Xj3HjqH4NDttix1Trbc4IGHHUCfRCiOLHRME7Wrt0tkxA2oFJ8Jj4DT6PLvVUF4sjotK3aJjj517Ffq3+SPb3G6w+ZAFeTKSxubN
# DATA 8GY72Vu8LBbGdVVasn5KFpaHpUqvLn9yoXnKojFAGR5FTe+fI9dIEc+lmMKEZeQF8se4RiXZTRhXtj/Ht9Z4VBANyjCf/qh/tYXJ
# DATA 1isPiCtpNRuUZT7r8nPspRmxMiAHtXFQGwe1cVAbB7VxUBsHtXFQGwe1cVAbB7VxUJuXDGqjDUIt7bO189q60YzhN7rX51MX6rEC
# DATA +sClXaunUmZVqt07se69dtkk3rmNdv7h1r1MzQuHVSw5lxHlsNJ0wfQ1z6wxJx/cuWF3btg6+eJOD7vTwyedHl6pNXkpp4pfR82F
# DATA 0lwWuDlZ/Ez1Jy5ALx1ac3jzQRQ94ROO0mbPqDWXjS0XpzYXRQOlyt2WVRLKEK0+qBzdlyA7p88bK3DbmEq1O4H2nEdzpGhweAma
# DATA c++McKh5Kj1sqpSyYS/3MoHqSxCfe8yuL5VGMkFUb051gsaOItSvu5egO/dQjhLDB0imnEqygQtcSrmy9tz7OGsdGgE6tDwZ4WCy
# DATA kHmJvVCzSXTB6nPKA2Ok4zNNxpwyQHa4VSfEnJqlDEMXMM31IJZEfSYKLxLwkFCdO6zPvVEpU9fsTg51RmeohnBwAG7hMGIJedyC
# DATA hSoyNAaDkvdu3DPNoQDcw2CxLSoV1RGiMvH69OMkwoLV4FCe5O7lIEwlOpoopNRquQ6KyjsaG7y5ol1Nkwosse+rAKh1UDSlvvTh
# DATA G5yoE/HQyaRHezSkrJIM0Lmij/tTNznCyXfeZkDjCUsB0Eg9L/EzN1I9jHAcUJ3ilkmr3CHjzsmy8c/5yWOHnHT2e2a/O4v9hbPY
# DATA T4uUfIY6QLyYbxai13Mk34xZ/lzBUSB6PvJ4L+8aiOQVywddezmNy+BDZiJHFw2HtOWgzkqGtDYp6GnTQxyrMtVBJn4snKKEpypz
# DATA BYldDVKKancjiI2vT+Rh0ACwhU5DG+96g9kwHiUzmiIam2hElTyBiM04Ggwg7Y4xtK8U18n+GpW8n7RFbp8ME2y6hpZSn0xShTlg
# DATA no1+ux2Nt2Cg8V2cGB2L92EXURAUO6q8VGsss4tNPj4/EvE2hMMUWuphyhLq0kK0xvMQEtaTde9nN7SXe/db0oJSMi9TXoouee8l
# DATA 6VTbfyIuxOwfHevbyCBpX2AvQfmG+mvYBhC2p26EqjrLhszH5EUXibF6BmerOVvNHhmcs/XldbauZk4+SwnH93ixUtdnJcDGR68t
# DATA KCWk9RiOsA/tNmk/mfOmwG4EBkyyE007Dkveg0wMEKdwRKXNoH24DNlpEFr6gezTZN9BL+54KU33O8az0uatZJlmoGgubqgBySkW
# DATA x0fW+GWtDzEZhZOJ5gnx4RK8B16fJUaiOuO4SLtU69yopPxJ+cmUJ0v/mAERzRXOcWBHIg5Hnlbup2QwsFKwlABpFs+5msjnV2VL
# DATA gHq5dYfpKO2nXk24w8zcd1h9xog5GOil0Rj+0ERZc/O3k93ArSo5WH3PHps9jMziT6vvbLOdxhrZE7FS9J03JVVZPsh4rL2FsgJt
# DATA +/kwNKxxFa61GS3PZzjpGic8L/iLO17loJUDcyAp3hlsWr8spXMVmsw4J+6aBMzHWPJyzAbbPYg4xhMImaLeZ2Yr7LWi0uQsiMRo
# DATA ETMzrUFKw9gw6Ubsx5/CnoXhpy04QSnZzkQ4II1UZ8RCQ9rInnq/oAG3ZPtXN/SlemabHFsa+aSYrNESZgC8YrmbGxE9Yzld523Z
# DATA UxVPVvlOWUKPVpeQrsZSSI/G7IPNlxA1Y+5IxOMO7Au0Mvtk/4gbNPSkriur32IHmjUQPC+rICK1mkB9FFMOlC52MCor5fxlY6fg
# DATA +hfMg00L5kE4GbCobDgY6oJ5lPQYxjqiUY01Uw8wyaMRdC8/Nyt5d/eTGDNjynvj1i/Yrm8ulTH1L5icddUsEdPDc5eHHfErK4+s
# DATA 7z1lefzV6vLQvbiUx1+RwbLQkc06ndmA1WSxCKhOEqrGoSeriqVHvRSvJOA8Ng0ZJe9tal2HBSpCMkOSeCAqx0PuxZLhUOSfybgY
# DATA CkuMfoqRg2a9+PwFlaXo+hfTw02L6eGs3Z7vz15nEWvVm0WjT5LDrAfTYlwl74OYprvdGXX0e7IUZeST9apQZuGBqU151QlnQsc7
# DATA d1nY0b7+ndibm3Zir8eTLu8YGMEBRI1jZDWevihe92fDuFvEQiFLjKvy4FEnZcMe0kJTWOYfhJpLna3z27w9lLDp7SgkMp7Utglo
# DATA IcM9dO5yWkzQmUorb//JNkbb/jNXJO/vvJ/oDYdag1tMfrG4eemfoZYhzViQHbqU1cLp5TDRnmuPV8ZCS/tJlEOh/V9H/3r85dHv
# DATA jn8DVhkwZvT5V0dfH/3b0Xf09+8Yj/ZHj2Fn3xz96fg3i2C0f2aM2ldHf6Jnf+/RXxzg0TcFCvHoD/SN0Wf0v++PvjYvsUlqdNOf
# DATA j77GJ8VR+zdQ0fB+ee/3R/9+/I+OivYcQLnNNgfe8ppMDzR21ZC5IV4s5NUCz4x4m1UEE0+zAAANhTuBZWSoAxA4AzrQMegGiuhK
# DATA 9Xgy5T1jeK4nS1jGKQBPx1pyGpTl0RTEznf4NNvXx13EVdPT5gvk8hBqNFqEg2QvQ3zxDkN++TyH+2YvzrrpN+Ophe+4OIYaTGl1
# DATA bgM1NJERnLPB4dNOLq0L56e9Jxhwr03GBXZ00by/T+OOmV4WtJGVJjgMhYyEIYtkortTe1oxv1Gk8adQSYmyzol1vgpkU8ly5CRi
# DATA zyITZvUxgSEVkeA1MFhNF9hq6+vlaiNmrpU9K8Da+ug7wJob/y94/NcQtjMM+y/F8t7VDPkXPuJvNOCfYry//OFeKmI+6WaUv17N
# DATA 5zK4bfmE8yDJGWKgYybV7UOEVJAzjJOZvEriOhWgUzoMsfBllt486ZfaUQqXVjTB0iQnmgbq7NiCil437hm2GyX70FMkkw2ZbRNl
# DATA rvG2GhxZIYOC/RJR5wnGJoUm4zom3Cs+Ncw7gYQ2F6e8hyqdCo2Ll2ajdCqmAvIlsxxuK4oZ6FnTGYUwDEezHj5PbCNBeV7hJ2Cb
# DATA ZnJYTEYO2eaQbQ7ZdonItg1Gl40mOpuYxFdo15/FrD+vVe/AbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzm
# DATA wG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtx2bcBtflDtVMtnBbcFvXrUe47Abfk159PS28hW9aq15qf1oFite81q0a9WBvRP
# DATA peI1A88v0y9Vz6/Qp3qxUh3UW15Q91plr9L4tFqjq1418GqVt32/9WmxWaw2vIpfDOayNGr1Kt32HPTMb9Tq1doy6FlrseQqZa9W
# DATA DvpBo7Jfrb9NX/MvMGHlKWwVSkGlHngNv+g3h8Vaw6s1vUa56DfoS82r1b16k75sHDG/uhCzwAckrvFpsUqFWkRe1N+jABDbQZUu
# DATA 5GhxvJMz/7Ko16ivwNypCtyJJ3zC7qlU+kqGfvMbDJJjVYN6vgWYYCkAGDaePF1G1nrycLOZr/a9Hn/X/S/LobL4a7VJ9YbCOCU2
# DATA jpuRxsZJi7SwcVHQrAVBHhtHN9Uq9Rw2bg4kJ9i4VreVYeNqnXoQNDJsXLfTafcybFyrW22Vo0vHxqH9nYyNq2qjQEwC/cwKfhyS
# DATA OedfDH7k1ehPlf7Ugx/ZQczx4t4Z0lRiWsBWYMTXe58VO+irHXN7mhSUy7fnnXni7ik09w8KvEq2YkVMRQPwqvFnmy4VlGpWXnjV
# DATA ST4YT++nyBkkZr6EXdXaxae9nHmmncqkCv3xA23ys68onpKF1cmB7LQPm/rlygJ+rryaL2dyv2DnwBpT5IQEspXgOHKOI+c4co4j
# DATA 5zhyjiPnOHKOI+c4co4j5zhyjiP3knHklMWR7wDiEYW/C3vvwy1pc5TwG/IdijCcDWxifrj1OJxAhZYf8eRmNK8bfIGqxZvYTLft
# DATA 79yg3OgMSx/Sf6O71inx+z/NH8Pjh98Lp/0Sz9C3OZwf+6UAIWTH+5YcGs+UbyHFZbp9jZrLjq24Q9TuEPUmh6jto03uLLU7S71G
# DATA L/nZnrGWo8EFfdZ3yUnrh+ZcoNSRQl5ZzRzqlQOrSpCFzxLDjj5QOsxykjdilf3s8OQ4PMRkWg5PQmtlZJ2c3FgD+U1RPW4LI6oL
# DATA AhVeHZoOHR2B0z3eRPe4E6azUMmm4dPqO9GlUtbi1g/k4+p7qYPtJgln9E/k4/OggJzlxSlFEO+tFkHUuSoiiGSUTQ670CEKR/th
# DATA mikg4uQkNS8oiHcSdpvMxmOce8ZGAxxG8yYiC5kCzyGH2dkLRk0tKnnUqmMcHZ7T0eHxsDs5LHhRmB5yQzm/7uFcGq5MotKqfxen
# DATA GGpqstKphu0wmcGMzMqmM0v7VHMjFsnFGXQ5Qh2KXDWbOZkRAasSdolgGFBQfXDv0EVkytRKz4GPh89QP+AvbWvmybnUqbMEPAcF
# DATA 88HGBfOQqnoRbpVDaIBbyqF8sLlAJTKOuPVws9ENhEEyKDjqj9BwtG4ozhFCsQqK4dGYbUNkuKWmIYIDWNuS8S0e9JMZS4+eX981
# DATA l5QrK6Uzd27vbtq5vRdj5ww0PGYTSxmZJig058OuwGky1k2nF0+GECedjT1VMMmEJdj4V1EvOaBETZK2dHeTCF9ZN2w26pNRBXUD
# DATA W8bjPEWSi/mVlYg1SJ6ySB6vLhIz3EqZPJ6E8UD0UkIya0yh0PcpjBPYb4nkcJemPTDyUDUNDXMSquagNKsBE9ZKM5mSRCb2JiIs
# DATA g0NRezt3weSjf/3byqNN28oHMielCWo8pipsCga1G5YzTd1lixAMax7GeToKVY9xyuM9pvng0WJjrkJmpaIZrkTCpyxqjdKF5/Tc
# DATA RTEX45dX6/hFkBPRjzvvlvNubeLdsquY824579bGXqyVTrDL8W6x8JYB4IXeXpKIKJ72bV1b/dp1vi8cafBsD9iCU0voptgwovYh
# DATA 62s5b5NanmE00wj773miqhZKtzvDHeX20g1TJqUoRQnVPG+6suyKcf1UeHftBD03erFhzAZShbdVD0Pe8qo38kZj3npd8lc7yHgF
# DATA CbU8UeU6NqpleT+ZutHETD+44JryFaEXdk/3lud7neFqP5ZfCtiBQIHF0YTuLgW5+xd8WcrCMo5C2XRDQdzX8oVzvaxlJqH8KAp8
# DATA uEinSnZf2aZLdkmaeCzm2ZjGw6lsSL8pQZzTABIjBYOR1d5sNcvHE3G/CjEW/cCCSvSA9RpH2ktbkBkD23DsFQn3wlh2XWFLvGCk
# DATA aPZQ8gzkLqunJY8LrcCDnwVkYfHKLEjoVabaOsbrYE2N45FgrBAmWcRGghALiqyghkNjkHRsH0rzFGG+EAqU9ipiOtsDv5Z3CmRr
# DATA mGraOtISlKxXmclOzthCPfTMdgG9J27MNozGyyKrX3jDMxtqnOnpTM9NTE9na764tuZK6/AaqlXziQ5zumDRDBtYZuhbMDs5VqCQ
# DATA TyJZJky1FZo9xLJL3PleP3Xr6y/5yn/LOZ07r1IPOt+w9LFAhGuOcDXlhJ91ZlEuhAP+Ni/CPX9cT5ppJ8FkQd51OOqI+W30r+78
# DATA ZOG0H+/go0JcEDe3nuIvnJYNhMWzYyvaHpuDgx+Ehzx9gZ6zMczu8ZKdTI5GZlEQ/sQ9Cml8KMuLMncCjXAc7vPcpeQ95OWsqbag
# DATA 1D3KPkOthMtYnHFs8MyvdYVYDycrTdM6NqoE85Xp/tPxAKGm8VNsXZdlSKneVw73uHLjKcOUUYXajwZ7M+oubFjZvxx/efxrxpKB
# DATA IPYNf/4T0GWMDfs9iGL45fjLRUrZ/25+/NXRt0ffAEX273zh98dfHv0Jlwre0R+OvmIU2a/xHTfw647/nv4ARPY7eh1AZt/Qz18x
# DATA yuxbCuA7/Hb8BQXzLWBlx194FMZXdOHvcRFoNMcuey6sQ6SNp17wh7Bcua69t0AkDSdPsMoXjqIC3B40K53w3HEcyvQHgwzNUHFU
# DATA mteQoJfhzUYcGGuTz+IBs1GpRYe8m5MmluFUIKkRtupTZ7aWWiYw6UgGSgcts21Fq8O4anTZXKlcHrmsG8s5zNTc+Ya6whV1gV6G
# DATA cc/cSZVOauLkguFlPM+PU96AgObAO8N0VB3BbLNSu3CKme5sejE/Fw7EqZR2+lF3JttEBsKOh+QHg5y5F/NY7dXzg+IwHsHWDgdU
# DATA ubGP5Lb29DI6Q6ywSUQBC0ghHqELFjNQWUbSJgcG37xp1Vxt4uSb2rPCl62NvKOXOQvgwiwAzS07/cD/UjiIrnLQv+gxf6Mh/5Qj
# DATA /qUP+FIfc4m36WXXovlcBrcsl2Ivkjl6Kh4ppnB7SS+/b4+zYdqnWO7xugkaXYx9msYyYsTRMBxzwuW16KPk3ADVTlCXsNSikUmy
# DATA X5NHXKn3nhFnSzfElnHOqUrhUXbM8DoZ8AEEEXfZgTYMqAhSxNLr4sAPXv5klBzI6Yiu2lwKbNQ44qLuJ7MJ2F/MoIrb8QBZBeuO
# DATA QSs0HjFuCsaCaCAwnsucIVAgp1GyHD7lOGaOY+Y4ZpfIMdtwpNloyrOBfXx1Jv5ZLPxzGvgOZOZAZg5k5kBmDmTmQGYOZOZAZg5k
# DATA 5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBm1wZkVmnWgkblrCCzXi/slZ8jkFluxfm0HLM6
# DATA 5Um51q/Xm/vVVu3t+jyCrBLVO73FnCz7lJW1ftBs8OcqIGPqc40ylj83m55POVytlYd+s1ykf9VnX3+eg3pRznd7lWVQr0pzIQqV
# DATA gKJQrnzqN8qe7wPB5lX88tSH27h5Ej6sEYSNztI3BfUFHJrfCMAl86qVYqvm+fUaIGh+QBnnV5n8Vmud8LpOtd5eTiuzIGpFTAdC
# DATA CPRLjfZaS0BmFJcMZEaRMiAzwbFlLaBW7TUqG+dvfcmrKuVG9qqq71/iq6pCZJNXVeqNS3xVULFT1Sxf4qvqjKLTqapecAaeCirH
# DATA XZqGyknvaEHlapV6tdnNQ+XmEXJLoXKRHzW6QQaVC7r1qFk1ULlOvRN1LKhcld7brF86VE52FxZlmUEPc1WeQXh6dcrYLk0x/+xn
# DATA 5qFwb0XUmcdhYZH+VltGf4P/s7F/UKiL/1OFPAw3g7yVGuvcmnp6lgU6v0Bim/e6fBY8m6pkcuGwuMUK19dftpvUgXXzTq/T2WEe
# DATA u2uxVLUaDGdl1Rp7biHO+WnRJVqHjjHnGHOOMecYc44x5xhzjjHnGHOOMecYc44x5xhzLxljDnUhntIMfxJCi50q2G2Dndu985mZ
# DATA k4zTXa4n0kvx+WVc/chq+dLwd++YZh/3tn/Aj6qGu/OZ4tJp5SKIocqZL0YcjbmrFuPy9ufy6u5M1p537YB+LLg7XMoQeMylkyUd
# DATA +96iv/NjP7jhB4iODu2OBNCe0XwRhWpixnKzrEA7iqJuCt6dfgaQPJEhSI32Ui86kA5kLKfyROyLLvEJxlxykNE4xbirzfoJXixZ
# DATA JYtP2zyh2ynJ4sP2dljYL8RUCOENZWjv7/x4O6amUX6tXr7l7xTK2PTFrR7rT7vD3Tvbwzu7fq1Wfu3DrfepSvIRSw4VGaQMH86n
# DATA 3iChOevwZr2886NKbYdmYF3Ws9quFD7cKuNufkw/M/wR3bh40+2s5kiWowZspxxrVXXgPNrl+G0j9Ywa/I8v/gkZm97GlRu7ywpz
# DATA O341X4iv+cGtss5NDvX25zulT5J4RM8yuFAirT7eWPLKXjyK074SRfUDXZg4LSsOFwEg/nQElQnBAeB5hh5uz1WYoq4VO3a1oMbD
# DATA 9chkyw5F8jYXOJVEUc8q6PnX1pmM3PLQeLJwPsM4SMaQOnSslTO0uIUOWbMVdaUz8y4KXJ+HLk2fop+x4ihhP9Jh6odowEVYBtOo
# DATA D6I5pQinFLFeKcI6puj0IpxexKn1IlbqlF6KjsSD2TRrALxrS2t6yshuRCWuo4zRVejYi7EiMu4TsWLmlOtxKdOt1/ebzstcMELv
# DATA 5dYttWCuhOtX6NGrAZcV6ac4Wc48JCPsva1G3pOU9E0wJkrZlUxJv1ZeJqVftaX0G5WyraXvB6ul9C2DBtHniNPEhGZVXK3ycvq5
# DATA m618s4NYUMvnmN2plrX9sVpXv8bxrAUn31nnMOtLwlzQ3tcHGCndfBDxjjKKhRmElkO3yi8qZzImFCYNnKZ8uWnHx3wm5MrpvWw8
# DATA 46FQJiB3rMtzBXIxr32IcZNbvP3W7OrlvFQOPno00E6om8i9Of9ThvfMymUlHUF6MoUJeH6RCO/CvydSN8pY0Za8rZxhNGa6NKGz
# DATA 7P5cJ89mEIQ/crcoAV6qwqw9A8kZ1tNguAGLOWgGwSoNmrzojE0FW+R/LeeESQbm5g8YCfUKBfu29BBkQ8BO5Bs8/+IWeQvDzUvc
# DATA vOSEeUnO/nRTEzc1OXnG8Uwl7jDGo4LrSCBzBpnK3ZtmIiLAA9Z8Mm2NSi9MWeQKglOsOWZEqAqinDYMxXFphNC0WMP85GIOvYBt
# DATA Njb2W3i0tgEmfM0PRHguEsIsXKVo35QYqtCpmdIwo4uyJ/10hmju8W+z9JDG3BEzvSiB0lkUFIRIpkd6oGUgPXcX6RMd6LifTJO9
# DATA STjmoXocwZBW8r7xhKXHJIn5YW8aMlb5vWQiyrpqrJuHmwoi2bL8JLVijlg4NO7I0LcdKAwytgmqjk1891idOgCKHPpwd4WfJliJ
# DATA fmjjReEhB2GApdbg21sX+7jLVt3ayM8bj5ICgxQQiHBqCMJQ8Z8a0HOHBeEU/kJrEmfKesKyzWvvqWJpo8sWPoHVa4dSf9ek6S52
# DATA 2I8SkFvnkyVmQp4bu6CqaCoymYUP4N5Xb0a+ktnWB8FXIRskC/gHAHsReawld1i2DUZNAZVoJEkB8w7e22SWqvxQAceUD3f3k7jL
# DATA ktSs0gaAgmQpDVAJE2OHkFob80k33p2yfErPsf5roYkoB7hMynScsaCeE65OejILgw7dcJh0pXGj8PiyKStPH55Lej341HXZaQ1r
# DATA KcOCN561yUKxnmP9OW6EYRcWkDfhOiyVlcYuhhfzKz2Q2GnQIUs7pTa5LomPgAZXcK8pBhEriSCUyQupZ4ih7UXdHaV1TM/3ZoPB
# DATA oeKtqJiyGyfliirpHuZIhawsKH3CQT9R6ojUQWInKBXxpI92KAWGPn4eUSuG6YtnTztamLOlN1aDdqbzC206n5YV9ozVoe09/+th
# DATA YY8xEmjYJRtVUt/X08Kuj5r0cyGpehJBItv3r1leFwkVyytkXzRTbF5xfClSTLnfWM0bhcq70MgIkhqRilmTDGx3aDTWndid91m7
# DATA RLhiNFVhfWKZNNH76Hfc82acWc7oPSCZPYJdLjQyqjfZvTIzgU0ru9MTWHgxpMgO1U03k8Gq5in2MuxcVF+eWoTLHIxrMSFwxRqS
# DATA 84L+OCwwliEeT1Cj08g0M1FwDs10VbbZkGE/xF1k5+a8rWRzQ7TY1kJnS5unkJJTMxYl1wbuwjrbgq33oll5GdbsIGor8Wubava/
# DATA HX199K/F4789+p4pY98cfXf0e6aL0afjvzn+4ugrmzB2/CWuLALO/m9cPvodPfw1I8q+9ujLV3TxG7r8HchkR7/z+J4/MOPsH+S+
# DATA 498qkNlXIKnRC76kf3+rQGYcn68Qp+O/AwONeWe/P/qefqD7/+jYZs+LLSuNHA1Pi6/zkpUhb2IdiOZwoi7Ok7eEgpui1SOO1Mp/
# DATA CpVFZsiL9yjZZy9POMm8ShYJEc1jLcrs7floOJyZbdNmHcVV08yWFMzlEc3Ep5IuvFxdn79ddhCYux9GKY1AHRmwuZAuGG0m7iXR
# DATA 84drRRb+mFrgwGYbFd6Fc83uepbeeTYzMDWAF40hpDMbMIWjfYi/cZpCuedAPZEIip1z78FP6X7RNC9oToXe72IgJmz/7ANe7NHF
# DATA wQLPbMOaudrGWWx2z4putmFSHOfMWQNntQY01uxsRsBL4dS6QgPgMsb/jYb/043+Vzj4S/1cyAkLdfZMWtBlkM0WEsl0M8qqdDFa
# DATA YJzJsrJH1RM19ZaAngre248fP3hUUAdL1cowlwzvGZ2Q/cArO5wMjNBwSmQ0pYkqS+150Hmqx9xN8WamKniU11AGyxsASFncAeYs
# DATA MwLygLPxJOrCN5I3CmxjoMDNFJ2FBwNj1FHmAVsF4FCJeSjIKY5/Sq/J6GbsVEkPUz5Kqe5pO76Z45s5vtml8s02G2s2mvicykC+
# DATA Wov/LAb/hdn7DnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcO
# DATA e+awZ9cHe9aqter1s2LPqr1Gr/0cYc8W1p83Qp9x5qrMY0qY0LZqldxhMb9eyed6VVhOku3NXMZ1m1EQ9ebwTdVmEAiqax7fVJMs
# DATA tuIh75Z4CPsqi0d1/tBaJYtGbR5bt4wXVrd4YX6raRhUOULaX9a6Tb9RXaw5zRpVnWZf6pyVvLDebnXCpfy0dcmrCCntkpJXsWhe
# DATA GyePHrqw5FWF8XVJyauqp0+VPHroXMmrVirXopFUq83LayTVun+ORlJtls/dSOzkXXgjySXv1I0EyTtvI7GTd+GNJJe8UzcSJO+8
# DATA jSTwm9eikQTV2uU1EorFORpJ0Kifu5HYybvwRpJL3qkbCZJ33kZiJ+/CG0kueaduJEje2RqJDWwtN71aEOzX6v1qq7ZfrNWHRb9V
# DATA 92r1/epJANXVjeAsNEy2dA0Nk41mi4ZZbdcrzeAsNMxyFPZ8i4ZZrUfNmqFhtjudbrdj0TD9QH6+XBqm2swrszvL2aOW3Qwfkyfs
# DATA ZKLbTrUWr7Ev2TaRCxXz18V75rcqLC6ZNXnJrNTEVhlZNMuFqhbM14Zc59Wz/GN6Frh8s2F2N80m9ybhMLdGd1Jy1TNLlucXb9Ar
# DATA 9Qt5vnh35kVctUNSXuRLEYkrYCEQLDUsoj5VtcsvF7RaLXhgTgfvZI/RklSx23DB97y4XWgl99PROh2t09E6Ha3T0TodrdPROh2t
# DATA 09E6Ha3T0TodrdPROi+A1rmI5tyL2wqgiNU5mJ4KjqkZVHTlpl+uNYNG/XZuzqIe48PDeEwjDskwn41x5YaPJyu124qNeV8dY4d+
# DATA wGjaHxwazhUjEikmVK/exP7+7QpjEd+KXxek4rs4Zy6nlMeDWepBsNlTL+JnVZRWPX/XqwQ/Mm/LhHZkXkp5sB8xqnOb4vBjrPHv
# DATA LAvJZhla50ydIIwThMkJwiweOnbqME4d5uzqMCuVlC9TNUZ31pCDkPaC4mIlB2y04Z03loTM9dExuwqgoQyVDPqQgYxVOPjqCSBB
# DATA /WSum09zyDa4EZaCBH2LI8g3lfWdBie4miZohnOwBNVnhM2CJWMMijoJ3vZfx6+fBES0gjNJsa+Z1AQnp6VyimSItYEeAF5RMQm2
# DATA 3zs5vvo5E1lzwYrpZpm+YUy1HcTtFEKJkBzJ7BbqusZxdFJ1yQLJwJPZJRP1xkkxr6+J9UrIn+kC9JSJx0NVyM899G8Z6c9YiJHp
# DATA /dAzUR0Tlgc3j66R14FtwEUaDnkOwMszLAij5podmlSxWjRDTbA3kqY3Be+gT5WPjMPJXmSFpnK316O+tj2bwLeB52hyNYmg0BRP
# DATA tcCP8lfLzCNlWW5WYqIqdSgGMutg2vWs5N1LhuwWo66voMR6Rl2j/5SJLqnJXFeeCCdKFymzZTLI7JDiNZuwb1WJD21ADXzRlGIc
# DATA 88RNBFZMBJzN/1LY/KclnVwXpUh7p8R65MlbMY+YopbI69EQiRuxag+1rWG0ln3y7OQlny91tZPUpef2eFwG+GRRQPOi4SfLdEiX
# DATA AlByZae3xEhFXgb4exP2vDYRlt7Bqp5r73hdTGtjaJxS7luR/xhXGbPgIEAiovEZTqXMlbm5CQ7zUTbt1njFtx+/927Bu/foUUGN
# DATA w9JeeFhQWu6AWMq8SIQWx1AJDbWSKis1UikY2c84zeYNGmzHDTyeYtheQ1R8JJ2BbHhbD4u8a0VCVWKdortQAh0peVSOHSeIEtaN
# DATA QPOLRh0ogo4iip/SYy1Q7aXq2tfLbCLPmldlXYvmzHcgJ0RdC86KNa2jrWCKbHCrA4aR+DMERgqzX7Tv2YCeHCpJTBXLkvdAc2oQ
# DATA c14d0x1Z6PXCeDCbrKNZPpRgsHC1imf5Elngdn/tbHBngy+1wVUlcZ5454nPWXcrjffro9/OdRojdYZzDj3xFBoPvPhq4hQb9xIe
# DATA JPPi49qFPk8/m42BEyx5P8Me8UODaKE7urMORGSGGIuNtLHxtzPRmO2djYXcM90CaZ74eudVbfg9wjFvbtjQr0gVAFtmHKovePWm
# DATA sRKn0ntPJ/gowtx4VUec9WRvTBIag6lh95fe8FMZ03ugNq+45QOYbEilaHGz2DRuvYl33tTvl8FoPhrKUFUGnLF4+E3dO2+ozYlc
# DATA gwsehpUe9f0JlRljP6mqTbt8pxojCp4MxgUttQ3OHTDFaV/C7aporYjHe+GI6lTXtgVNZO5mEvhzv0sUbNPN2F9UopMI4t28eKAt
# DATA r5Mj8rN4Mp1BUZ2lxK04qAJmM49rK0vKc58ySQYmMj8Zs6KKuYEqeTRllfQxD56UQYOBruqpFZ+bqqBuqkq3gku/Hvv9SNt5Wd6L
# DATA yRd2hzTo61lOxvbRSuKK1J72k9mgy+1SzNkRLD9sPMfUStTVpYBLHtuXZAEPksMhB0H2OXjWIcThLRl6sOg/Sdo8cCqJ+dmIWYgq
# DATA pHVA8FFyoPTKtekcTvs6+h9MWM6e6r3H4ibi7Ob1Fu03ZqczWeMUTKi9zeilqLPje/ADM1IzGxdIKEAW9e08MQKpfgQHOw3n0Ujf
# DATA 21Wsx2xtcF1i3hNXtEpPKOL58Ksb977yrCNiej0j4yr0o8FY9Wey4Gn1RSyDTwNlkoMqjKPwCUpYekzUPaxZdqMhXmDPsBRYgUKR
# DATA +SBj4dEK7KmZsmNs8LlZ/0T9jIcbMsRfLNv+888/+vzD0dYrf/Gi/0dZHw0+RocRj2aAqo4PL/wdWLus12p/odaN5/71y0FQ+Yty
# DATA 9t9flH2/Ua7/hVe+igyYoc3R6//i5fzvhz/84cOZECI61IHEXR5nUCm2Ut6LXGTsR1ZBvHvvvkO9Bi9zUvtOBl1ewqcHShTWKyKV
# DATA QrbtHh+20d8/IftQf07SV3j0Qqc/iNueuvyAvupbJubBdNZW/hl9BUeyMBzo7zMyXV555YOHdx88uP8QG6i3trZe4TM2r6gNlj3Z
# DATA V83Opm2aTHajW710a4d3M+JkyBYYfDepV7wJqu/NziCmGczW7Vdkq3UvLSEf4OZ7dDjqbOOhgrdF8/XmlrUDdYudQkWEXsxya2tn
# DATA R/uXStHTeLrt79x+ZX7fZz5qfI7sY/UQvYF6x4MRvzkLKOogtwrez1Vklr/7o8Irnud9NpVTJLd83u5QGIZPX5/1sPfRr1ebtcIT
# DATA sjIfxXujcHBr69E7b/31O+++u1VIp904ufXzLbpOw8NWYWscj/GP+v7R5zsqe9TG1GgyoaHnl7/UG1VTDtC+wIvlsvF1dZbIHuLd
# DATA 3Gkt/XwXY8E0UccqVP7raPCDr3FBHfJLcDAKr/+BHB4qxemjsBe9Q3bRHg4p4PYS8useVrJ3cOfcNe9Vr7zs8h0+bbM0DfqKiusB
# DATA DJltFd/5N9L92amt+aC8z19BJX7lFZpCw035MdONtuNROqZR+GMpdJ7879xCESMLeAUdl2AD8IcSWxMpplDbW8WtHfwwiEbb8iAl
# DATA JPAruIYnJ1EJ+wl4G/H2ZOvnd4v/S1j8RbnY+rh089b/VPzoxlb+hfhvEmIq9zMk7D6Kf3vrndE+TvtYPQk/s7XDz6iBeJdbei4x
# DATA OzoRcgtXlm2q+dOPcVKXYlrzfuxhQ6/6Z30cOFwvetohWzeViaSKAezNSRe9AfqjEu9+2FbvRNX5GPurt3d2cnmaUkyn4aiDqsiP
# DATA FzycHjDZqa7uULXz/I1yR011FcY0mqjY6eu7Op4/L38kP+gbsedbbuJDiVvvdKlYttTj0Wg/niSjodobbt9H07levEf3fvb5jly5
# DATA P9qXI0F2UucrQVjsUQ346LN67XO62cRiR1caK2usl89lj/XLjmo858kknIaWAy78FZN16TTikZ0D2SsWi5HvL+DoLUdyi+w8PC3B
# DATA 8IXJ/IWn5fLcpd0ttWdFrmXvW56sn47S2RjDFc0urGiqROE/Pu35MaVMegreMbhNryl4/s58Ypa31o8/sprtRz+mJ3Fq9aSY6Qy3
# DATA qw89Z8WMs7xEw2M06qoDqKa9zobbKGTcUqLJBnVvfM4PZY91CMoefholXwnqGzTf+1Y0ljXhv8TaEhwb3lBxvN5IOk9wugb/UOWj
# DATA ByeHPH0qyHy5w/URJxlQcOiUBaZHpn9JBYkdWNT3KloebBnMaZnepxaJbgv9DC4pPfOHD5olQzFdTPsh9l9JczW93y5FdhTxRXFk
# DATA KdOl9DiC7RJODt9gYcFkcsjCdvHT3S168SjszHCg3Izk6LxpqtrVN2cZSKX2sbJiuFc1t+x4N70tu6aZR7TPPEF3kqQlEMK2dTgF
# DATA XPnJxx88/Mn77/5n75fy7d7D+3cf6y/3/+d77xa8cgKkhwmTU0c/97ocWvYK6p4OJPLU3KJwmK+Nck0NlGiHpU+o4LZVlbnBTTN7
# DATA ydROOGe04qntWlZiiQps++e52/DfVpdrCbpLeQqfiuLexUeT66Us13dx2AvWZQl/1WhA6kdPC4tBF4uqSnDour+6hafNN36bMafl
# DATA 5TTNLnYnyXj3LiyuZeGmeomG7NPdUULvOShi5hsDJJNKKFRyRZTcFvdopiB3lgaIWFIVwZPa5tWh6FaD7zBT9ICPn/FFGdj5YD8q
# DATA wFkwnU2ij2UL5e7jyUwdvNYfxfrcrZYLsm7K13fyBWm1GFWo2oiCn2q8nb99s+FKhznXA65soZt1k2yJeTH7xKZ2Lyn2hbLo5+uj
# DATA Vf3YKJNMD6fTsNO34/rRYqkt+2/TPPfXZro6mZc3sDfP7w+7n/mFQCwDtqFhd46m2+qbspNvnSJvrUmmRGohe1kOIHuJ+bWHLR+D
# DATA ue6Bom0ydjEaa4poMpTyoWGsE+WLx5Ns2rWefuP+z97/6bvvnlhy9CTNkpY9mZVXoIvrTQg47KgZAEaibVWNeVKEnlvPsEt3J3vs
# DATA 1X/Av6iik9twlu/jUP1Oc4CiMropTXrvhVUxVj3DJvzSJ+g22GLqQf4Hj6YqErkOm89tbGeTGdxXUvEpePKNJxjKmn0KDKd3n/+B
# DATA EKsJ6C/ViH/zjdc9nnamjAZVXa3tsC55P8GgHXqM7vGwe2kEL2XHo/EpHJNRM2eIPGLn/n3MwrbeT7CPO6uRHeNDb/P1XjwZRt0t
# DATA lBFVtI8/hjnwMdlvu97Wxx+jxD7+eEsiLcV3TV2JE5xiH0aX4fbbzP9XqZVrgT/n/4NX0Pn/ruK/v/zBzVk6udmORzfJdPDGh9N+
# DATA Mqq+8sMf/pCFO4RXi8UXWRjDGgNWfLFckYwjDb3VG7geajPK49nWYEDdwhqvIJYp6jX9DXua9Od+mMI3qL/G0AebWE7As/sTZQXR
# DATA fO3PpvHAfOM5hPmWDtZ4IcOJ7YScd0pO+xMh4JkL1MhyHkuO8mwyoBhLz6njTdd48kcdCy+eeDJ7n0ley5CZjZ5qWKBMvmt3cDCp
# DATA ac7jtQ+5XExpsKWOZZRJ9Emk1v+QITLrTLmw9Ht/Ot6bhN3oZ1A70C9ejIsZlyhvZLjCLrJtmhulmbtIutclCdG3qUdZuwflqJ+T
# DATA Ed/y1vAsh++wPDY888Su0C3eRbW1o8OTmcWYfaVq2o9dPrsyfZF3THEaZqonUBy0nt7KT6U4/Tg9HGKTzLZlTHIyt47+z6OvvaM/
# DATA HH119O9H3xz/6vgfj35Hn78++rN3/Df04Y9Hf/KO/+7o6+Mv6NofvONfHX1z9Ge65fujP9Ht+OFXR98ef3n8X+knfvpP+HrLw+QB
# DATA 5rzEQI2JKjpy2LE0hCW/LV9SZfjxJPbjxDb3eL10VztJeqscIRHZG5LP3dlwnOrfohEWNz8O004ci1GCfWYYYHcreoYmjphugWfE
# DATA LOmkZrnDJ+gzxmZqW8rmtmRPUOx3cylaYjRgStnpU5FtI3wU3co5J26guSainK8MWKs/wJRyl6eTG81FkWk7y37uDWZQm8n9hDhg
# DATA K/K2vofSPkq0G1HdMYkYNqaFqaRYbb8O3cP59wMyIGgWlo+cmdZ/3Otas/Zc9qmp+8M37Kn7G+88vH/v8U8e/ud8lBem0rl02G/L
# DATA P7fUzlbPMgp+ybMLz0hi0dBKXF9TzpS5aRrdMRtxk+MfVXuW9WPlhDKub3iglOoa3EzVFU7t7dduZQ6yj3Lfih99Vi7U/c+t33de
# DATA +7C0c0Nd+OizSqFexVzHfrXVC/z3o2+ptf8PatO/Rn/wb9TA//z/s/fuzW1dV55o/81PcewkfQAKAB+iZQUy7KYk2mZbonhFyk5C
# DATA oVEgAZKIQADBASSxaXT5MelO37iSm1Tq1lRXdfek7v0AimK1Fcd2voL0Fe4nuXu99vsAoPzoqZlOz1jEOfvs59prr70ev6V2/JfJ
# DATA sz/gxn/2F8UBvlIvv1IFYfM/Kqln6skH6tmj5NlTKPGx+vupVlUj5yNlYBcgTwoyCeow0l6PDTgtZLOCWsyaSr62efpJrngvBa/Q
# DATA rLq0BKyG51VXADt7qTnoLKm20np8npdfWQ6m4f969ilwOsXUHgGvU/yPhqdGquYEOaQa/1N4B/zvFzgZX8B8qZ/Pvnz2peKAT7Q+
# DATA GxLeZ75GtJQ6OuuV5LUa65mxeBF+r85aH+jNU1idp9AwtP8Yuvlo3u4bjk6s//mvn38EXFwvHusBLC01alhIS40dtXV4I8ThwX+D
# DATA C7gaJ71gInCsOnoNvd3jVLl3uVq3q5PZOqVLuq2PjS3lCy/kn6zru+D5+Fty7++W6heKBbUZl8zeqzT+oayeLhaX3khZoRuowKlC
# DATA cNXrAXDTESqM1eyepRW4vFcq6YS8fM0r/GRvtS6UpGatOGPo/nirztYm4sHojrKhnQS/g838/DfPvigZDiC7HXf+I1X4EVSkiinO
# DATA 8Owx8ADmD6pymes/P/9EUdhXQJ5Auer3r61ZJbDC2E6msa7UYSfLuO0phC87PSbU6ZMwYy/ghPxZbS215AkO6jOWbVSPn3+ihBq7
# DATA x6xsYmMCoBfa3I7extgcDet8nO5cW18v6/Th8lCA65KabwYnxtLwC21WqghsRiRMXgH4SjNYoGVFlvAcTRyqGP5bq4Uc+lBecuEs
# DATA PJR+T8N4/nFk1b58/rGaEyRjOJY+Rdr6hPZt/PzC0+mK806RsZqwJzSRUHVAss8/SagEPNSUwMuN3Y6ttrqJFkb9e+2eu775RmrF
# DATA Lu5Wpv9WXMGu0pfgqecfA2dXI1vf3iybzTgHQfCICun69nZj+9bt3drF5ZXlu73bGze31t9bf3ejsb2+tXGjcef2jRqnqkFh+EHz
# DATA frt6EbAdeqmzC1PzpepMY/fWOxtbaJDAQZDkvbm1u3F7a/1G42/f223sbFy7vbGLRfiOW8GijeP2w8JFENbd+u/2dm/f2dltbN++
# DATA 9aMf11bu9m6u3/7J1fWtxo2Nt9av/bhxY3PrncbG1vrVGxvXa4gni8YYWi24qPpSWGyFUB/PWmK4zjB8rQhoeHiDWpClCvXr0iuv
# DATA XHwlWKJ/J95pmA2R5vNfEoUpClZ1wUv63l0U04D0npx+UWU3zyhYItzTxATC4uoUaVBRFByIqssgJHyuCOdL1e8nwHO+eP5rFgb5
# DATA zSPRp0QEP+6vZcYrGCt81RU1ziahQVwXnuYGgKuxV3fkczBvx03baKY+0BB004zVpnt76qs6Atbhd7ksX1xXG2xQK1j2s0G7PczU
# DATA Hed+ezjsqCt8mhrVByFFoqZDrLN98B7uHFDwAGJUaL9Y4aHJfhuchEnpgUIKqHxr/qyBY2s4c1vUzk2wlGmBlCqAE1l9k7o3Hu43
# DATA atD0j5fCssHJ9RkyWXUuKcpRPOcJkfxvnv0OOSs8Al4LrPhT0DyoraAEEKi0LKWf/8ph1c5xjItAfcCnPH9ZOA884p32CMzkWWQy
# DATA MqIlpkTeTFJheC4nKDR+iXLNn6BzID14h8qXPCD4R/1mWz+ImbCP1IZX8oU64OAjVR2cVjBhT8ySxOedXTfy+zbPzPNR8Lnqy6/o
# DATA 3OBOBMOiE9hfABbFpRNFoJyV4KLWAwVXB5B1dUHFx4JLvCbqmlYgFuJ8Yy+9vr67fnV9ZwNOo7RerMi3tuGl8E77FFV0pSRQNnrt
# DATA aQsqr7i8ih60aq2ATP+MKwesG5nhExJAQEaDh0aWpgVVkqVinZ8lTseNbMX9kD/1dVlfPPAWaTFI4CWw/shTnG0KT7RvFa6Itwvw
# DATA MVdBTyDYpm3vhtvkMqLKdTKcEFDGeZ4LZFcyhmcxKIM1rZ3f1pYanrV9YSykUFLSNFrvYVQFq/z8e7ZY6RBaZ2BExenN3TG5Q0ID
# DATA YbeDED9q9vFPWRoKsoIn2GHpPfVsnT6Sg6noaS3xM9JaTmKNgQETVHEFf9rQbystVrp0xYb7n/THPbTY1kD9JqcKq3+YCkCqsoaj
# DATA nuNg0s3tdaoALqJvdfv7ze7m9v1L8tDrtRqcpmH1ucwYS/f6sXQpnHimcIAj56BdVjJC4oFiEadDyMvWI+MFBopUxj0ldBcWpSIy
# DATA BYAfFxxpvH9QP4zFbd7FNaEiIV8ZZHZx/LBCJvkhKcbUPeFz1JE/jR4P+IJOgSsiRz1GFvsJXu9sDpGQfuKJpVWzDgRn28uMxA4J
# DATA noEXP6Ghg2oqfgPya97pkMPdrHNAumVzWu72CzNat7OqHBXQ0/YE7oLWwVVJnv2OTt7H2PVf4Is/8Vg/41X9E64E3l+uwQ1Dj2tr
# DATA Y/e9W7ff8eSl2BRLSo4+j5d/Z+hAWeDiRfCPJcHxgETohn3ieYI9C8UZHldBS0ZmCe0jEHVVDL4gAT33I/SBrS4EnkFnE4d7a61g
# DATA RNQOPVexNLG+kA/w2v82wXs4XU+faGOt7d7pqGz0LQolqQ/wzvs0eWfjx7V312/c2RA9iXrgeePgTUDnuLYvBaSvhDh5zKELF4Oo
# DATA Q5GqYcowoj3/Em1qn6Kw9RVpJT7Ei7p1uWLdLGlz4OL1p3SOSwm6s8poiN05rmHufcX0dOoEe9dU9ef/ydc+1JbS1FrrhU+9Aaiv
# DATA f64v3uI1r3pm20klbsLYTxem+j47Htp8+Xbd162bLAi5MI2fIYv7J9ERBXyM+DGM6SsauhrUryO3WrNtwVLWyI6bq69cskfT6hxB
# DATA xGJNvAAqXKRoPGktMzBawtLhfty0B5vs4HjcuwebDMXobvNkv9WsikUP8y1YsQXFUrKf+vp06lGF4pALWJ8zLn5/3H5If2lbDUWb
# DATA NmAg6kg13rl8ee/3R6HnLlvNupSQhFjegORW1NmC4zKMBMy/eEYPwEINH6ifcIINjCVx5+11NXM7d27uGK4LWsaBY9SeIwqENGhU
# DATA c9F0Brs5lwIEicbYxNF6goT+mPYoEZTaCPqwJlMsDHfJHgdEPJCfsEM+xQtpkqQXqIcX0Knf66WsyX1EHGjQ0ph5L9Ep0gPbdkoR
# DATA cLOXCZ3ARZDS94th/wGKgkHfbaeFIqlN0NnZlrpzTSVqHZrlQ/RvLSZJwVudIrjo9R/kG0rEDIBiPHQ7KtHkrpwwqa8sGQaPC1Yb
# DATA P/85nCAfK671hcVuMfFiDWdwKWaHQCtwjBTlBZO1ehowCyBwsXNEx/Ivfi9ZQqNegqJ/GhXmqVes0eE0ooAtYxOuwMBW6rw3HuEV
# DATA irWugJcFewKP2v5DcefO9BOWbZyCWlrRJItqJ6JaW+qgfmAXU1GAoYeHGFm7TiXofAAqLX9H3+nd60FEvoZ25S9SL4CIx/1azScx
# DATA i7xQ1S6L4a4APJIVoLPcV5rgpMlJR/srnMdifHpwZByHD5/g3dAaSv7wtxDSBF5xB2geUne55XxIJQF8GfJDDAsdYpgd5N6AyIAx
# DATA M1jRniwvosil9WIxXqU1XI9Ciua+Fv0SjwJRFEAP9uywEJ42oLPDjurZEN10ueo6RXhCq8j2xV3DBMhxl3gM3C1nJfQ3eVQ55VuL
# DATA JfY6hyQSWBMxz5f+bICOY48zhaRkiMPUM3gJoUb2KLEIjZ7K4xjarbTucFf5gOgIiANVQbf7lCPQlyHcYWOsLpJAecgfeLQ734b6
# DATA f/lAZZb83xTn+qMSitVV+fk/Gi5GqkrFzPGurKQzdR0F0TTg48gDNYck0dm9Yg2cU9A1gTC3x4PSDRSzWXpzP+t3IWeaNUH8pa53
# DATA CR4szHVIKIm8372P2YCyxrDdbY4699uNUd+OhQJBwCmLJtUwnMoR6ctaWpkiz/+SBWLj70dC/GOwsOLMoiIDrPd4GX/2Rzh36Nby
# DATA COf7sWVGlMHKpkFmFR6HszuMR9evVd3qto53/A+BneZ32BXT3blaYArotcejYRPAIogSRCOh5FqNFwNIQTD/xjYDiIFHPQjjpVxJ
# DATA 3eZpe5glkK01aR6OAKu838MksegWeoUBWSjQnBBVdEPaUhNzsDH8TU5M+a5y2jzp2kepeUHPKfSjnPtd7nv1uh4SsUHPWUq0Xt3f
# DATA CLlLHHE1jepXuTV3X1oLYa6BFmWhLhFXaEbtgYcgrz6Ge6iOeiHaij9ddmO0cVzmPgob7iwVhKS0mpxNjCZEbA63dqaZHNxeoDOq
# DATA P7P8OleyfYQS7VPcnSDVald20fmhtAHb5OfsKPIFqBkeayMPGyge5/BbsrTR9f1T1LmR2hJ58RNHEeF6wpjFitlFGZhIdl5wj2Sp
# DATA LH5FsQ5PKjft5Fxwbg58vsWOcOxk8r2EkWsJe4nBhDq9Mjq76ull/C51n79PQEn9bksjMyE5Lfhn6iyf6+glBYR6VDv8N1AoP/9I
# DATA OlAO7pYUYS/yhLTKHtNm//KMYiGZvIi4uZfqOQd7muGcPCpqzSkFsibIhqYx1yvCIAtoeQT9Iy5enH82nGMnfy5E1WDxUpGJvB6Y
# DATA prXTfC77IckJHttik1ESOsq1UNKqzhGBKGSsxW30N0GoCkfMy1eWznDUyJ0y7aUsaNN6b7kt+4OQ8lFpxn4Zv/ZKCbypUEv0xp+v
# DATA 81yCw0HOcfN111L3HLUbmGNJnQ2I1d0uSEyGFazZNXgCbELS6mNZO1D9w3XItjad4Ql2yMJcKWkAYIKodyY4KVAsRyf1OzXiP6Dp
# DATA g4xGj8RNNQnFp8ehNkqSfrrEqzf3HJcAjOwkK62QCwTp594E7N1hvo2Sjvs6TjymDM6UbO2wy1FlyrYZvnUNlg5TQKSE9uAnbQLT
# DATA Jqjs8YmtE7JnElmr1TXXGC8FZ7HO+XvMPj8AYthUM3esRE1Tj93JYeekiT7U+QKW1T0u7t0QpRK2JE6n3xeYdcAvbPaSMStn5LhF
# DATA put6CQhDt/tM+Xn85XbDoWgz0jN7cPkBUkB2bqAS/2PuXi85MnJc93zXChaydogO8r+I/nduQ6SbNu2LFnzr1vWNxs7u+u6GjofZ
# DATA 3NjBHctMFCGA4ITlzphxoZI9j7nOWB7KzeSm+02NljjgfGIORXpw7NPaRuWbL62wMA6XOelkAEjtBoGRqi+LGxj5e30h8fgGxyrB
# DATA RHr2GO6VAL/o4DvbDhJOHan1o4Ov4Qz8dbLcf/XVV82NWM+yHQR+u01IEYwO3L7f6Y+zZPPm+lsbpWScUfID8Ad80LZSQvdGrPtT
# DATA m2UAiJdWjYRml/xs3B81k58qkoCDHRfyAcZ+D9tqasdtjDDvIDIRZOhq8S0WwzLGAxNSzrGHxAJK3s5Dd8K6u0flfuaWtLWD7mTi
# DATA TXr+G6AcpPiVWkzuWd4CYblScGfTPrTdZq9B4JGgV26wNF+goZVoliGu/+C4g6neLVdOxhVhhtCqAUmL4oB/WCrKBlWJL2y1At0e
# DATA TD4J8aDSEa5qGwIVWKzmQQew2HBNHzSHLaNPANtvvkqY1OoYbMLDmVYuEDx+iy4YtsLnz2QdpUixR2LkTVBKe6Iunx+TZ4ynJUI/
# DATA EaMe/1WOT6Fn8eXJFrQrByYuhgan+DAldAYmnL0P0Ffv3/1+BP7N9p53nEtItQj9evrsM7JigxJKSdRoSPo4MhV8YYGLN0aQxIZ2
# DATA n+KQMae7Xip+mDt6fu+OP+alfqHwRvVuhf4snq2UKNiPvp5n0OL+Sc5IH6L5Ij5UMjOF4xPaapiBuuQWjDX4gv0N3SMinBT/uxec
# DATA Hb+a4rwGRTLz2DPlOv1GpG/GJ0GnNTLgs8dMoniuknYL4NGg7vGDAgJ/OW7pFXUkQRzU3nI9WUzWinvVNU9Mg4qDWYE9QW+mju/3
# DATA 7BUB1+xHSMK83BxvpEcGeqNPSZvEAwffj2kWyCuktwdO8R+aYyiS+jltJscL+VNW7D+l+HPS+AplGbznzN0+9hsurI7AhveBS4aR
# DATA bySTjl+Un6/bX5SCFow1yadTq5Dls4L5BeweMidz6mT8IfXOde3snfqtsLPklB1ggoJdmztA7Bl/CO2q6XTDax8Nf2pqnEL65up/
# DATA 6m9cf+bMpJxjkHZfg6Xwq/IRMGlBrcWYvy3+VrsdwTTIMz0DVqFwSJYfckClsZbO4ZfieDdQrPY/og7xQ4rN9PhTYMB5ouMJfc5F
# DATA +ROgv5iEw9l+8GSHxCuAI3Y3j/OSbN8siZHTmpKJqKAW0NC722hSOz2ZLX+32O90peq57mXOLAfz+W9qfmgKtPfrnzGw8A9BJMdX
# DATA yJI+xv9+9OwxyzjnncvBAL0q9iihCfum12qm5+i4F9i8mSKcSHagP6rQkB//1oRtUVwutfE3wdz8DzWkP2Bw5aPnv3r+z8y8ZX4k
# DATA pCGqdfsLxbWoClhqANfpj5BiP1Y1PQnFqM91zAvjudRyosbYxX57mwMGLQBZFhQuror+mapCtfPa8g8vyawcHBPdYDvkX0d2t7uI
# DATA nnYXvVYQMrUezspvnRHnEEVUm/0UTz50RsQH1hjy9PbsYjFFOa9137mXKPaOdOLqoq4b9SgsASkjUXO/anM+dkmbobP8VytK1xex
# DATA ZV6+ZDr7INBjBqxLVJlatyXo/zx2eu4MHztWCm5HWXsDnHy3ETGyWNTWf5TPQBQDp+kKYBzda59mhb1FroebqNufVNoPR6AKns++
# DATA LL58tvrds17oizTUXg3czeY2rs9xcISq43igne6p6L3PyDSCbqhk/QOPMFLmVyO+bkHntYeysHxI544T4dif04riA6mZG0nHRGE3
# DATA /iUbKJT+KsbOFu1q5PrXmn1BpelTQSIlnGl3VsVfmeR0LE5Kyyke+DRi43Y/F8DzeSw/uKAaUDfXxotYLdFFnuICozuLq2RbfW0H
# DATA F+MZQ4N1VtJoc2xPrTjlu7uPGi1+uzvB7AAlQ0FQi/EBz5svx+Ps29oXin+wKybgy1Va7fYA/mBFleUpaAQqONnTknB5jhYH7fBL
# DATA teBhnitOjn/Ar8VJ/ks0q8HhjsgUCcRKqTn7IzjjYLioCRF//rEc7TZGgiUMRpxg4lKbbP6azMqe2eB1HLsBrYhvLS4eBMW4ASi2
# DATA qPKFNkvknfaOuJ1HK+3DwzYqCFXnC6I5nMWu5hmRrnjamPL1PfDjTzIelPO0D2vu6pu7xaO84SIwNayt7h4NkJ47cdZhCBIVCmKQ
# DATA nHphrIVI9L7L0Lm4hwjgTCcVod51+sZqU+G1AKNmm0JpU5uAy5BuMI0Hm9ZqeEXJZd7nuHagiuQLikgBYjPRThypxiE3MVAPCyo4
# DATA 3HfCsFz6ivpSDduK/jsggALxeivKGTIkopQX429wMfaW65WhRivCJ+UVjV9UlTL2clhtIRqS+jU6GhJYuPz9M4Y8b3XwsVpTAPwH
# DATA 3G8lozxER7lmq4VPlEDWPuzcS6PWyWf/nrtzYbP/QlE/CKb/hLFaan0+pyhQ0VAltIOewkbBLYIBaFAOwbQ+QA/KX9l3po+theF1
# DATA 2OMJhEgu/MsvUBn0B4V0f9zpQrIMNCJYNp/d407GLARwQsCE0Ee4OnBxwgQA2sUDXg8H/S6ZuOHEFFnBqm8IOU/bPaAPAh9mGxTk
# DATA DuipHgHiZheCd1SFPUxuoOPHAJJYHYiVcIQ2jD+M82xxMRbw6EtfJskEnKHWdanKlzcNSpiCfj/9/vclNlmTqH3KxLiufX5obQd0
# DATA yjJL2V0MK8abfD3WZ073ocoSzJVdDzuZ0mdu3CwqxumksNThJBZI72LfLbgB9ZacHHY6DJUXzpV79EYZQ/5ETVnL8IxwCv9PdkLo
# DATA tcudc21yHCJ3lJKbWzu761vXNhq7P97egGUFbqZ2CDIywuLtE6D+wXG7Ne62h+nE1xrS/wr7/X53BukxFyZJ2JlP4c+1WpJXheZB
# DATA xZwOWDOv5oN1o9CS+mVtQtqF1JYQftE5bHmeQI/wDR67WsgxsbWPyID3GeLUPVFi6VMOD3a8p6YfvoRii9viQpJeCW0jodbVCR4l
# DATA M5l2pn2cb0bV/uvaGuy6aIX8oGplt0GZMsJdPBru6iPbIWKjP7PkS/jC0ZbBg7lVZbMFz69igueTOCYNmpk/5xj9GcL1FNY9i/3P
# DATA YOR0FTvoNuku5rQ4lTWoGdXf2Qwdc8Hyi9geegmBcOJiy/Q5euzcWATM0IqiCG3zxrT7R1ibCHDFFSHwL/hWjMbBL0XqAcsfAfOd
# DATA k+I9qj9zp7GaIL+JHf4TN5DCvRzjLdfGMtXxU8DoauLAEZr3aqQNLyW2brS2h5d5Uv0V6/qlUSHW7AJWdqmI3G35ICO8HYCpB4ZH
# DATA +8tdKHZHlWLZILfgNjF6Qjox+s6cuvwtn/PFtpbuvXun6f1M8ztG/V6elPXfa5Pymv5xUb24/MPmft15In+vkJ+cbizOZgjVYyrM
# DATA ZxgY8Sg53/nwBNn/I3KM+CfAQxFXAAOf/kkQIbGXswAgCJth2aETZ9pTopqsQPSOVv9Xfb9RlCXIc5M1TkyDbjYXHdAJTlD6b/Ux
# DATA adZQMWVUWZQFChy8qqJnkWhf9YRGBd3iXQul+M+Se1bvGM+r6FaYiC/WTC0+asIFSldDouDPIKgj1xJiAfHiRTPmi2+7bRL64+XJ
# DATA Lv1xafITdtC/K7HN2C245HoA4DrhTqjPjoSzSliWHzDtR33Fg71ynsK3FP8aNG9iWgNYZdNxDxLJPdIdsKOv4ETR+gx0BIsZcqrq
# DATA PFB35z/g8SDHB+4r1r8aTOpy2Q7wCaGEclfYdB98Zez8SVlEIe1OfBBAmBmcj/ucSiTmMAiOhIYk4Zfn7YTAJBjBqd9lPuTanJ54
# DATA uZEyfwHnHbCy5R65cS12aHKETs4KBypYJWko9bxPAl9p19igZ+QgAKhkJbbXiqvMzn0ZAWCdZ4K+ogAadOpiYelzW7M9xWxtO6nv
# DATA LVLHDNdVMsOiGSxzXbQrheGXlt96EH2kM6zmGxJM/ESIAQQ7gquYEYDjYgOJP4NnGSFPB3aRZDM/2f5hUuUM/iPnDXhM5/CUBWB/
# DATA scdQ3DAJJwgRIep1QPdJZ5S3Jdn80XBBhqbv4hfdEvPEWmAdXpSFGJwjgWsBAVXnjpuNkw5ZqoNozTDIgzplWfrxgbH008/5WdMs
# DATA 8/5jzb0Iai6XOhxUHeOWjhPlOqTPtqHn+o/bCXdC13FTwhCXx6J0tLnEvBKxOfIPin1MpTamN7qFU+RpX3SvJ82eksBbCag9rNxw
# DATA 7LRPjYDrIiQsh3/Fjdx2DY9J7nN6DJ4LmVyohn8pAQIStJ/Hic0StOnReTDMv8Odyxp3ASxjodu1xZoDSqgzx9ZqMVFyPX+MXraE
# DATA oUaexlNY5vRZo12l7ydQQeiMZwkmMek9yLNtu9z5bmbekew429YdwVdqOYd3OgAlo4M940LAJc7X4M2mk1gnYjZmWjZHRwSf1b8l
# DATA A0cEMF/xHdxLkxjnEwcAwYRvQ/XtBgRyNYg9SSBXgYNdgFmdK/TeRRqjfxyYsZ6BD4c29IaQ9lz8FN4MftQeydzUGwrA52pMjGke
# DATA RFK45anMLAlWShm5u27Ak0RWnz9oM4im0yF0OCuRmE0fgMpHCDJDn4USZIEOfJsdDoJM52CdASKRulG5konLR4NBR4Y7dXvKstqu
# DATA x/U84SokxPlCR/93DRvNpxkKG2XldhPpodsGS3H/QQ8yNPaag+y4PwqN3zbmc3q/3x2fyHFj3KlGpwNQMaX7nV4LzWXU6aqdXhAM
# DATA /bRO1cQdGgttLxS6TvzWfAoS4Qvp4hLX07bqsh/tgIvlkCarHonaGjn6Y+KyjWgYvHdN9IPUaXjzMBqzk4sWl9Zool9XU+53JIYr
# DATA SL+K1pElmKT0S47BxpiSfkoQlPhSDtvddjNrc17q6sJMx0sPXPb1ZG050DTqu3VPEe6wc6AdQtUe7t9vU9pIRdikuOcu+G6g0zPP
# DATA /HBiItfwp45e4zaL+b2SeDOKMNOxZfyhE13m6r7gswtJYblUTBaTwlpS5oufel4MJhptKQU7uHJmDKcfthkMIWVPl5IZjHZMET+Z
# DATA wNNowXVVcrCdR80jRCTlOipDC9y5mnrCrWAog0cTJbNSn1dDIGWuLOiqoYbZ67iQi5iaFtD6zHVdUHUVVRXlwv3gcfENfPFGtXnS
# DATA urT2fnN4cmlNPcRz4sgDZTKzI8ijGiTf6ItKFtZq8NJf//GAgIgLpnI3+a15bqf+K6RHxwfDSqdv8kgtkVeX/hXSGh8bDQZQN96c
# DATA WpzSTZuBIkpFzSfYmI+EgcTFxdDdDl3YFjyfmTPjcaZ90PCP8mDYf3jq/SzTpX5oO6hZ7m2hq5vxcCOnt0lAjQZNbG6vGnCwwGjU
# DATA +Rwx4g44lme7gymDdUddN9Dw7SK2TvPvCMZHUCFgKTaSEqvLRW8uZKSlKHiF/7pmMbtYpA+xjpWivY2W9JqCc0pJNE4vnb5N7E1j
# DATA X6lpxJChA/6gOyhlduFJ5G3SzMBBzz8BMx/SgCQlEzvNv/l4soAOslqh6OSYblhwtOFJ69ZrZ+pomPTd+d/p9uWoNugfWuK2OsBI
# DATA IkbstRoJUEbOE8o93QFeKxF0T/Q8G0Wu7knknT2FccgGPhKG9xgcw/j1PywbeuVZ8jNWWVuUqgi8wh1UYdiLVC60Q9kU5vsB+mMX
# DATA cd2uSxvArKtTMDGxD3WpVAsmhpsPOr0e2KOjJMWs3Uyrw9j5gJ/j5MoZJMd57cXwG6Rn9XlGq9/MFxdrr7EfC68K5sbDw2cCdmy/
# DATA yYVWLuTH9truIfK0KEcgD0NdVwgzPKjY6XVn9omemdAHGrt9xE9CLR62XI04rM9FMLmtFiNUdH5Kmr5lqH9+lNWclHNIvmzEr52M
# DATA iZZGswWe4N1IRjzOCui72hoPWvqQCt+I++WytGRLEWqsFXJHqIgeJ3PiwONeR2K9LfruoZH6TNlISFMilCER4h51xBOYeUvqE+YZ
# DATA U0HVnZVNIg11lrOEVeWuT0KhdI74irnINdYBZ2LPRZdeX7D3XdzG9hr0h0eYqMTQV4VuYS6oy3RS13V3Ihd1eVkM3d79LXKu7UEh
# DATA nyWDVnasCKhXYjd5uZQD83MmphAOoxRIIaEwlTroKJQRh0FQnqBL5SMl95ESwhUQC+GgSoFkEwprbnuudwLG7H+OLaIslRf1SjPk
# DATA 0YX2NJilUeF/A5wuqcH3eZXnr/NYwiCpYbOjVuQONfsutYpYyuz66uLJ2D7aks0esrb9MzkaV+Ouro/wO5oC9WGJnZPQuCRviVI8
# DATA dwOBMLYNwNrLyLexaAQmPV0lY6iJqaSmWmNixpGlb9w0AotlvtW6YGCqdpXSRVNSCZ3HDt71+eB9czHlmxI2GdeaRlEL2AOeYAu+
# DATA BVSC1HPgOBf6AnUuwPKI+llovKBut+C59wReDjNh9cE9J4hhff4riGSTZPIGY5beWChMxuDDxJaHpuA5llTPhUlqm9Ixucu36aeJ
# DATA KIwA00Cg3hIpR0ntyFwwztR5tX+atJvDbgdlLObFGZ3R7WbLqq6PaI8DdYdvjhjBsaMq75y01VcnIB1nx81W/4GLN1sJYRZcv9Gl
# DATA /0yv0aUZPqO6z/9TuozOQXN6AOw0ahbB8xldinmMurCkNjQJu5C6u6EiAcJuXdUI7K4LbxBz06oG0A3mWmFvJPZJ7vfUHazrZ3iI
# DATA kYajLZAP3f6Y+vJ7RMsf1p8QA0YUbzioPUglclqxch1IXIpmyhCPwgG5/6H9BK2g6q+cXG2/pmfnowo9vhdGemGGHjF0uwJDJDGU
# DATA 5bs4BeBBDkTXKTZ4CmdIiCRkF7Ufm8Kmglit3yVwBB/vcAgKA8wHEHM1AzQU1w0piupEpPOVhYmTD58yBQjCjQB84g7Al/2qUXgI
# DATA R7yLekIgh55awsMTsS7s5gYXNhVL9OY3Fi3jNVcwOy1PKW3BVlBNMVnZ9NVP/BzDaNKeUYu48wSj6YXyh0zJHeJ5lIsT3xSWdgXB
# DATA vyhvnDr/PlNP/yTxc1+RDOYBaeIjg5TrJP3wPYZ7rfbDkpYE22gabGqE6pmwObFsOK8nlxchBw7+Z4pjuIGNQpfvp89/ITlg/0Bj
# DATA VQ/c9LXoggPGmwhKjuTOqLq9LCWSjqKahCkzOEMdTAKUPCGLynL/0vLyJHfgHmqH6pOoRBHF25sSG9S7lJA3RS1wwC9G/IijOTVK
# DATA kp4qP9WEHfGCS671G6om22lCyHS2a8ohu55whZNprhS2JNqQc8kA0tG5ZGUCRfx0Je7WnFQZM3meOHDFzBroRWlZAqqGKVhGimrM
# DATA kQ/spTp+jv8iUnCixXK8KY0sv6FZsrqdgTSfJcBrEkjvdSq3UkIjbw5B2Yg5UwnNHSu16oLZryQbmEAMhAX1WYag7+gJ1m0xpPUA
# DATA ADuwEZYo0KN7VInDrIfy1izvdnsvxOVQRtD+Rm5c/m3Ll1UF8b8YlAih/uf3z9ey1DfmnxT3+rdCjDn91wb+o6jNSZvuJL6yd1i8
# DATA WnffWYwAlGJyD++NPBAhS2yxYQpQo0EwBu6wSKXV6mR4+y1Y2PaWblMzFMa0F2kXiNlGs9f2grh5wYrpitgQWJ6cbULQKn/PDfRc
# DATA lgfNk6hRVq5wmeCI/5cwQzhCnHpe6BwqxvOPHvkOpLYXBqVOxY9MYvs8eflXWuuCXW3AXirwDz4B+sN7BFrtKgvnN59UuArQ8BkE
# DATA p6hGkEs66kDdAe5BupTm+PJbWe8TnDmCVXqam+QrV2Iql80xl4OACg/q2szND1gunXNe6DBo0JnpQ1uV/IZhaxVkMpaSgTWFfqZx
# DATA 5L6OypIeW0DUFLhS9BV905OVO1OM0LwO2OyTxFIBzp7iiCqFcDXikLzz5XLm8ebAZchW1K9tdNy4TkkUQeFg7aoh5YSp60ogn9vQ
# DATA xnDp/AD38y+twBlOAOFpQ1E36fSYWmi8s/HjyDb4f+INPyFVM+S2pSbVNdKux9EMnCFU0EmTYQFsMcji2oEcyJRJ/snEQ6vCVjyY
# DATA AM9NmTFvHVeAaqKd7sxlkNyS6e+9dLOlhDC3Yuf+XVVbhuqoo9Q/GjYtpIC9+mRK9uuqe8bDzb6z3R9S2M1A/WEAmND9ffvWbYSI
# DATA XlX/S10/V6yAT0LVhV6m9tmJdpaKH4nsyOq4SJVccANCGElT7YkYBSixxc2vdX4yKPu5TkHL34TRUfL9TTwk9jBeai5Iw1zwdGZG
# DATA qXfpIHFY+zDGoK5i3jB8LQbvQ/h5VjiYbyaLsyeu6jK/YhzkC/0xXD+MST4w21Q4tkKMnRK8V0Bu8DgQlwtTHECLLwq85fHiCIhh
# DATA 2LvYF9NQDQN3pRdFqozioH1LOJX/Wf6/Lwo7qjO1uAJumHOb9LGfg4eBNhP+5tnvSgljrEXVng6807cAHci+y7jRXaetPPw9c+Xq
# DATA a8/KnP1VwNrnxOuzXMC163rZKW8eW19ad1X1veZ3iPTncsHpkH5u2YUcihBpnaD3TIvVF9hzM3FLz7HL42c8oXlPJWjjnjJFJHX0
# DATA DcP+SMk75J6o9lJVqthTPyguWf1BllVLAMN7BL/gDyb5de9ZMgeyQrhzg0zCn+bLJcWYmiaErY7siSgG5swA5T00cVesKJhaChwO
# DATA fGFqoC4wY8opWY82aAMzRWoHrZVeCLyRkan9EDfuiHhpvNP1cwxQzHSwcDIg8r7gdS4ZZwzdHzmEZcVZ4FEVx/RTaKXlL88592eL
# DATA i+pRKVlc1DVMwszpJWc7OkBZ6uuC6uugi+78x+qkIMkC/moAvbkSaWaEUSkLJuA+7KyCPBEjZ5Y9oLziBLKXVQii7Lj9sHBxtbig
# DATA cx+geBWD5fO+UCS+fWtn963bGzuN7fWdnfdu3b6OCn5qyAuSsArf2dm4jbES1qGoX16/6r7ya/EwBA+t47S6tCQ/qmfSjcnfGCbd
# DATA 2q++snZxdSm/9jdv39rabWxsXW9cv3VzfROi9NPj0WiQqbqB1MyKpNvrWxs3TDH9xq9y587Vxvadqzc2r5nCjiA1HnazgrOqZuVh
# DATA a+1drsJl6u33Nq+rnq1fvbGherfx5vqdG7A0SsoYt8OB3NzYvb15zcx1s3XSQV8SeQErFl3Z1bViUNt7G1ffvnXrHSaIxtsb69ex
# DATA 2ihdsEJebVQIUGRi1pKyu0WJ4EIhedAcjdrDHsbZ/R1M/LBdQRTqNuz8IgbH1SqL309duU3SQ/LnJewFGB0rNz02yt2DT8b7pjzn
# DATA 72tUk4DBSGWH3eZRVsMqp+Svxfov1BBHVdUQsqsL+MpmDvAJMwMEegBeQBOMgZ37bXHAox9yKeZXbpwj5j8SlFc/JRL8fjm9O7zb
# DATA A3jXl8/l1oe4pFqvcQW8eDgbFOs+zQnLSaRs5HXAY4c/yJTIkptjuhk0T8FwrQYH1oYK/A3Gq6x9aa2yf2mNjWkyLQL7RAFFjqN0
# DATA JPkb140n7b2ii5LD7/buscDAjljNa+3haLt9Ajvnpw9G2+N9xbffYUR61RPrNfxUb+CXD5hLXq/vwrqTs6tjWyiYF6Vk93RAfwar
# DATA Yk/sp6DZYz9HxCiWFIuPMIEAaf4MgNwjQIwBZNgP0aH4o2dPUSdN6llEanoaz2vKlHn4shZsamdEb5O7PdOhWnrGwK2Kpl9mGn7Q
# DATA 7IwIsQQZaEFC1Don7f54VFtdNiHFVqQAxrordnAT0UcohFCtXqvZVZJkGgUWCU8+1h9BXdfxiWA8uDvHKgZNkq6JfXrUunYO4Yhu
# DATA T0nYhaH1qmS2BEa1g2PVUmWg1l8ruUwtAaAEEN1y8ppTxjPVv1ZLVi6uLL+6Gt2gf0CnAvAieAR3PzfRTXSlHyVv7+5u75QNjI4O
# DATA eOtxynu7N8YIzLqsdvOQWaYk4S3D/65uvLW5lVzbuL27+ebmtfXdDXxaWXwD/1VnafAutXJrq+p2HOYFzQQD/n04nGAwfGW1tOWi
# DATA z304kPuBlyU8y7qV7Y2bDRh2Y9RXx+pt/LsAnVBHb7FYkWThZqLw4IAvKcl3g1EuGvyycNBEKxrcEKzpLDo1VBh+Bw+T5H2q792N
# DATA 25tv/rjxo1eWf6iOZzVl6zca195WEoPzpTrHOyfjEysVL3y7e2OH3enhz/srjVX2FG+2FM0BEcPGq5z01RSD71sBzlDei2RyOgZT
# DATA SlDoNV2FhaUSIKt1RsdJBtq1kUyK6m0PTOzqhlBIV1ZfrSyr/1tJ9UlmGIEaT2EVwtIfFiorJd1c2e8KJMptZoqXPoikBYcOyAQ9
# DATA GDYHDepNQZUmtVx72BA+UdPCFdSnGNd4mCfoK5L0KYaKA7MatNtDJJZ9dUsfqrXsD0/4INJUAwxMyK+ae60yIPeEsfgB+Mc5aFdg
# DATA X4RokH+S9CQ2cKVa8DJteISv/zAt5txaqOtZG9hpt3CYvrWxq1gY7KOllcoKCARvq6mpJmcyQxN4dk0vpbpZd8FdACQH9f8hfxse
# DATA x8Vi3uytLi8DG+ug7oeaV+zzfuGVlVXR0xX3VupAZ2vLy/kzZLF7++S8tcPHpn2EboLDkH+GyhXIEDGQV9ZttweFCt9+aBlctmIn
# DATA MuY1+AAxpv+cWOiXX1JSzOefXBGlGoXufCJ5lnFNS1G2jInT/4OSyoCtFIW/MqkaxZqPvzgPXsHcQbIO+BaoY8s22c+8CKIMo96m
# DATA KZ69UocOu8bL+2FKCQgADihZxt27rC5VeGzKF8UJsJ4rd3tW0b1qtZ5bzhF3D9M0pZ2ZnJ0tWFWMe52H1aX7zeGS2ndLWom9NBz3
# DATA lnAiKrC5ocoEVa4NuGv3D/rdKwtnNLiJXNLVrsepMAR9hawkWbdhH/GR1kZd71SPftkAwT7n68Gwc1+9dr+VvmYJsunKKv97kYqA
# DATA qLSa9HtXFqwh4O0qS/qHh1fYBqKOyaVxNlxSTGnYpklZOh6ddOl9czzqo9ec+aQN26GBQJNry2vJkvpPxfqg1VKXt2ZLLcWPytfo
# DATA ZC6DJFq+RRdSRZNZr3OopOrug+ZpFnx1GwBThu1hebuvpv8UJOvOwYg9+coPjtu98sGwn2X8xKmm2ydFSPJ3/5AsPYQJAG+ZJSEK
# DATA PPq6HQjWU0dEY7/fOiXpaPmKfn80HBw0SFyhQyW5uLycee+B7U17D9wB/1JX/WkkiF1EEqQKJhN3GGoUd+9WCm+89KDd7ZYR12Gp
# DATA qEajTrbeKfg5Xwk+gcHCqUpeCcn3x8MO/mcpqamFwvLq/6n9wuzgcNjOjgsxd56Stv6KPVOfeqk+fGupGv5yWqLtU9P2DRTWiWdg
# DATA aV/TlGMN9R4jP1ItrGALqNXqtUcNVEBQQBy3ZJ7CockPkWmgp6ZiDt1DCMLppvY7qn5t7aI87fT2+2O1tPTiMryxwYrsOkXxV3Dq
# DATA ti8Y8bswYHg+ZvM+C9ofkJP7sy8SVwDFa3FaXJilAnf7VXOvOTrnpbUiQccoLwIeQRTh9okOpohIxiYs7lOMW2UA0W+ku6ZrWn+4
# DATA hydALEKO9RX+kkYWMwxHglA6aoJi6S7mpVBBCeqXyfr2ZslZH8CoZneSR8mPhs1Tc5X+kiPoJKcKnOaWT0jn0KflCNhNDrT7bzHQ
# DATA CeINt9R9ef36TXVdchPSfcryw8eAhw13+o/seKpPaaVNFEMM7V27iAUBpgEubp7XWb5eqds/OiJ/tLO0pY41dAtJQUNT5jS6aX8g
# DATA HiBnqWLUZeDRUOjiMmpH4BEWVY9eSZkBQtxtXwB/EEAKXo97iglm5WzUh3Qt8DE3DwH49FegoNQR+meu4Vt7GbNdtmU71EyCasbd
# DATA zklnRPX0+tzfszTrH0LPVpbXLr/y6iXVIXXstsyDyWQyn59UczCQ5GU0dObSkrRGkvaRK6tZUkmVXKyXYhIyLFdW2zs096yqaGmq
# DATA yOnjnzEoY22PbdBlujPRuQcnnTFNk29rVl1Sq7ykRrHED3JqbrXBwJg1+r2abTpt7eNsKjG2hbYjBFdiLAYlSHRHx6fpxLGqkkl8
# DATA 9keTaDfoNWIjqn6MFIWBD1J67eb18s7bGzcwP9YBZL8qH2Y7KHqpox8O5S4cmjB1K0tUB3qeY5JFNSfQg5VltFqwOIFEnZFBWEk+
# DATA 6Ot0iQ6W4agxUFf9fov2Qmabh0OeEhhtQQU5UO8op8xeqhlIWo+lWIqQlraPVFcuV9bSFyYyukIen6DwVUvVBe5kn2oTC5ia492f
# DATA wDDv7F6DdTT0JT00IpXlAzGluXkWcHDU6GQg+50m5TvJ979/5piZJkm55Ty8fnUSLObFWWu5ujyxwzYUTebMNe0Y3jjVH5ab3UGn
# DATA B+xx3r2WNxnQjjpvrO/xagDdLJcztVUw1xv+Ius+gMyTVpqeKv570j5R61weoIhO79pqG+GmwjIg9VK/4LfXNf4HBV+/uKJwZPKv
# DATA vvoqvQKOBH8t5w4of2mNU0xZyf1YXzZHfyA/6ddcWct3zmJbqpSaUoctISOzEiOFDAv/dYKUQtG5mp/Il0S+fKtg/pd4kxf9tv8i
# DATA 8NCIfFoTMQC8SYLX4AxzebmUKCl7kuuLxALY9JxdtgkjJndRLjtRnZCVwpGZnpKYm0ZdWLI92zcncHWrx/dvuEYh9ZKkUSMYePXt
# DATA nsgeSHu5TndRHMHIsTWFO9vfC6cGae6Qol+c97F9FxMTghUGiWElum3jh/qLHc7Tdz/BOap9H9q1WU47bEP80st8ZJvxQN+XkAH0
# DATA ml0+u18uVkbH6vIwrL3OvlsQKzgqDCv9e28sV1eKxcoBhkMVil4J9SqPfzlc5pVZXGZlNSIMrLrCAJ8QArEGUU8eKoROymYYpOHW
# DATA WiBzIyPhgk+RYHjHr+bsFXqbsyvobXXVnGbuof/WresbV++8BWM6GXdHHVDfjA4GtWUQApjo0svL1cugEICbe5Vu7/Ln0rg1mCYF
# DATA xIXWYHtcg15SWAMY16tLikaWsOtL+lV12NcpxMswn9Ul+K95RirW6pKbdMZrXKLPzqyKMEzNq8YPXdP+4mcU5W9c9RM73E3+hGVm
# DATA 3PSqND2xVOCjYROv2nr1IgtOytw9IyyyT7m1gSNIF04h3I1zX2GUKAveiKzCgQPrxUVOFn1rjtirtTrmIs5jLE0hDiU3CFlEtXpp
# DATA KQm+UXfNzPmof7SUjQewOuj+GetyyLTBarwE8yCCV6wbzPFyvj7oD9varzj2OWIqO6XqcakGFUmwhjE6qrvxPBHNEx4DZFOw3hfD
# DATA S4vQbV18TYORodk8f0lG3Qz2at7ZbplI8pgWvq2uVFYvG74VI86F83EZMkDA/rbZDGng4WmltcT2YCyEDGc6Z3vBqTlvrbN3wDkr
# DATA fPDggVQYM0VAHz32abEsewFflD9OvokIKqMmmx1DFQRRheQRwdsBKc0Ls4JfftV+GBVGxURiqGgSWUpi75aqvV39ilHFoAtq62CO
# DATA soqYacqe8Q9PaS4enobdpdisaiL63BQzglg9RRwPnQlqThUZe9nYcumdIUjXfvjJVK/Jc1287IDyszBBcjUh84T7hsYeiM/TNlFO
# DATA smCiQ0gUXIH/rBWKxUkx7KEPdCOcdeo9JwZj5YzXdrequVp+0siLY1SNdMKOzr5IRTZJZ++VcjT5xZgTtB2kB0Sh+IcTLCLYMZgO
# DATA rwSWs/4D35TE9pp+twXc/YEXNMCZRRyBtYDVFW1/VBCvVQ1OiBaqFuyUBuAPDbvib9/bbTgOyynm97q+SX+hl67tZwt/i/sswCqb
# DATA Jr186KocpfKRX4EvcinmTAwPTVCD+uXEILiRMmFskRo2RUm8VIP5I9fI9mkx927/33VO0KfP/sxRRJhoG4NpIc12JGjo+a8JqABq
# DATA pshGRRqE9UP+tgdqEyg6abcKe4UTcgQE8zOEQPDPHUr6Yx5cV5fGTg93g/X09nspB2ZjNiiOEbyJzXFS1qJQTIN6gYTT0D2iPwzp
# DATA 8G+LasDPSN3pIQpNMhfBDkarSz+rMK1xfyDx27U7O7uN27du4YqgCl2fvKq3VhapJYq7VZUj7DBquwwyh7wSkFkLPQz7w8ZNMzK2
# DATA UNFbiPPU4zTLa55xZpsCf0DVfy+5JdkqR8fDdttgJJYhjRGmgMIDmFs8aZ4m+21wDWi3KskGwqlIHBNXiCUBg23Q3O90O6NTuiSW
# DATA xEUZ7Y0kqClWgXow4LMI6jDqM6foZAKtaKASaI2+blRoFD9Bploagz5GGM3UYHGgSRg6rAQejWbqi8G+1CWt1ZQKINoGrI1Ie+bp
# DATA xbrg8cJ5FYmr8sP07KYgHwzTTzy12Jz1UW4usUFS1SueGDhsd5sMh0bFzQ6oyLvGqE8bSiLcbdwFONT9DztZY65vw8TJOniAewVr
# DATA C8ZmeVCh5EggraziyxdK6+bWBq6lXJfzeAWTf8RXYE8Wqh6uRbiL8ZemW4uKiNEHfCDG3hF84RMyRn+BStyQsUfybqrrOm3fm6zH
# DATA A8ngqiJWwFmC39eag/VWi/+6PuwPsNCwc1+J1WCirTsnsXfumwhCdOQI6/JR0JsD+6CRMMJqcoYOus1BUclC6lKPxGen9rq2rg58
# DATA DvtuIkZHwQviB2fJgNHoaFV11rjxhLAI0Bs6cLhf8I85bPCXddREYj5lxMwnpaKarj55X0kWRmEymZ8T2E3gVOa3UT53Gzoz58y5
# DATA UxRqcfL8glHnj1A+MRVUNaA4+FXGdxncJLHeNOeaXMWrNCh7+cacRlQ5EDVmqXyiBUOlDWLgWb9LCxMJDoSkqyb7awzJwk/+Or9D
# DATA iACDy3sXF9xU49czDRXcxQWKxirMxAj3/ZNYK1k4J5RGcX78KBsNIx+EdOZ4KVOxBZGhUWDIkwcidp7/nPHomY/SQ5iBr57/2mGt
# DATA 6O1ZS2w1QyGNnzlA3vZFsnLcfuhk8D2biusyQzsCHeHn8GfRzmkpyC6HOmdTSTPpnFylQcwf4pWRKEdnnSszectuy/QmixSGlcOb
# DATA yCXBSqNq3exySoM5HbVbS6nrhya9DGEa1DJBEIMUKMF1p8bnDrZSRbmCjnGnMYgzkesLJ3TIvYD9i7trAqqxqI1srhyzh+nHY35l
# DATA 6tVH7jWNM69OB3nQkh55I+NqB/CPVv5eQnn5uklh6YeTFJb+sFQmbn5VU7GuSAjU1GFVPXETZqq6FA8+6IJz8JbkYd1tDjd7h32A
# DATA YUX0R/4tnBfSGqLyo62krvaoCfahAniclhKIm4LsBVYwTX+EuN2qI82R6gaXUL1r6D2uayFQUTUry0CbUGUF3HEcdZc8BMR2wHld
# DATA XEXCx2bUo0vJojyPHaAwRr7ScU8SaRyjLtqtDG+DWfOwnaC3nKWk5y8quT2HMCToyIKZKLC4NgZq3+RNEA4onE8p6GcTRAuNYn2m
# DATA Yl3Sa/SoN4ZU2N9Ow1J5XuOZEvgh1UhO2xzyiYUYR46ASEfQzgB1JXilN8t10jkaMqdjqQFVxQcjO208t1Sg3EEmcw6sTgOXs7aq
# DATA CeRiiZAb+MXKsvof9/Hll1++ChOTUAAAqRq6/SMEjUdi4YwmgIKJSKc9dXcHwkHfdQC6vA+dVt1oV1RlC2GObpsLySY5wMOgliwv
# DATA 6Kgv2YOQwagAf/X3f1qT4ZGhZ/g+5dXuqD1a8zcxBoHxtHi39Tb6wcCVw39NPA76cqGWrHhBRpSZly7AWAWBpdIVL8RIGWPCHGui
# DATA YbuGXyuhrLmvxLbxqE2SWVqppIQVOxxlecfFnR5u1F64qxFMVmNzYDfSYvRMo150MpIJxTVdP2YkQz1h6hETd3FKrzQR92IMB+oJ
# DATA e8P1U2xssmw1yfzOULG6oCDN5PXAYnMBV9MbKUEfZrcbLXNsAzMjceKn/U4Pkwwskq4gNo3Wh76ygil9jr7KDBEUguIAitRatoyT
# DATA M2W8eFHEYGsK4/F3smY6jNaIohKt73Ii7mUkDNGehJN70Cfcocv9V5eXIVgEkHQyDgdBQO9G/56VLHTmJZb4hNqT1qDylq9CzX2d
# DATA fsBxezwedbqVVie71xhnkMKNV7NyCOrS1xwKvZBcWss7fs1Mb6rdcXjYOYCYJ8DxvYdMVolZJ8iW/A1t8/2oKk5OZT4OcL9Sr8LR
# DATA 0DdBktWZBCkR5OrLE7X/wRfTrfx7AKHcHWdYGEKEYQMxSrai4TGZtmTvW0jZcoCQ2SoWdgxdLjkri2dB+nA/RebeH48G40guMvuL
# DATA g2NFAAVcf2tPaHT4lZUV0hwi+HxIjKSnprtLHumZIGtdOr7f9rsQ3mgpR5utAgRJ689KyaVXXrl4KT/qFvgN1jIr5Diykg/UjI2G
# DATA 4x6sRisnkphmtMJA+NBQvJyZljIlvsopy/UdKvo4jkCG97PKYXbaOyhIOTWJvX7BtSriCaatiYPTmNRjqUuEbBzeq/4m9wRSFKBb
# DATA 2CC11Czo7oCQ27RR4H5YQVdFdmNg/0EyVosz4TbSI1QOlqIWBL3bbze3N/B5ezj0n7P00znBsBywwDRBi1rZhSeFFfDEleL3Ot2u
# DATA VbzSarYptgbYlvUcr74CQAJRoaqI1oc7kf1BmP8UeVJ6QcMrBVdIH0Yd9iWQ4HjocRnpEr9c8MDY9FALdsIfu+0Khqhbr1ud5lGv
# DATA r7b6ASyLVVg1RZtr5dLFy2t+ooYSdSVT4mNb3QIP3MRTTiV+i9qPRcoBFErBAj4xjnbEK8HX7lp/3G0xbLQSsVBUBmaBMp49BoQM
# DATA ZD7tvLFvgTSNfn5GlNuoyRhAzTU7cRlnZbzW7OGlQx063VPcWNbZc8XkVTNbRJJCtEB5jkkVoKbwtqQJHXBiu23FbbbpAe8UcRMA
# DATA XxRrlALQrRrt2sSKxH0AOD82bZBLJDYz6APVxM+2HMqyXwVrSKwm6zUH2XHf3hQFUBqo/o979nZWP0vEmLBQLYdH2aGrI0+VEUW/
# DATA +V6ynnConJDFSfOeui/SgQkxemBa7ZLohlAVnTZR0c/GSlyCrCHtzgCsxVzfQf+4jQiMMrZKclvNHXgYJ/fa7UHmZtQzK08JMxQb
# DATA 7o8BDbMiCdM1+oqag4LNXPkdxAnzQEU5WYf8DegeTkKYEnfViNsNOgH4IaB9yJ/e5jKdcoCkdGeYWRStJG6efnGzRfBDQc8SOy8z
# DATA W3xhqm0N9O1xr4cyUCS1EKW1+xTUc/Qngkdgap2YNu8rRy3O+dBsVHRMJ0Q6v4/zgkFpEFOSg7KS2SqM2t66Vo3DzwDDCB+yGG28
# DATA GF6yldWMdPRiNlOo3jP1nC/xqDfHj6bpSy11e+ROoG8Blu8FpmiCpEedXu5OdeUMAFTFhEGsi1RUjlNOD1kdWXfd12hPTzXOG802
# DATA TD4rZHOsyFRfPS+XY3xW/4L43p/MMX1GjxNMop1GWk1Ti4HTLabp7LNARnO18FBDhfggHNtV77ZxnZhMZq7MvRZl/VQ3KrhQjDuQ
# DATA F0nxwaS5nwG367aPmghdIWiFpjJDznigkWi1BFFvcJiqP/GWxiJLVkm2II9Qkj1A0zVyyy4CDFb8+9aUU1+boXCgJGlgTJZDD87r
# DATA XJvBv1Jmk09pX5BR37ZBPY0uriQxI5y/vzDkwZeS2iOaPwWhEiirwm80/la+Bs/Pe7Qn+shFpqHhUbe/X0gX06JHsaDL40yclS7h
# DATA psXSJUVh13S2XW3ldNPvFqdNJFtVBHAPclg+AlBsgoWApJZ/0TBsYPt7HM7r09immaJS1FoNGLRGh7NGyCo4uqHmaRhRfWubAixF
# DATA b+6Af59LEkIRj5//8vkvBJUqikkHNIZEgb6BLkP2JgAH5N3Fg8WSWZh6Oz+gdNo9AGQrxHjsFO6NAM0Om0aviFnm+6INg40TPySx
# DATA u4B/STiHn1bR88zVeUQj3zh7hmQ6uEvBxmF0RQtJEZQrnf44S4vO4yFlRT4NdhShmBG2vtRsG9DpfVxHTO/m9DRhuDTc8zX+xV2G
# DATA xIFoeXWVdgim5pUlPLZIae6SJ3Fo0eLS2gQvFFDl9I3unYSY+kL4HmJ8EeQKZcRQ7PULcpKyk80LIIvaPZ/Co7CrzmQAkUEsBWIQ
# DATA LKlXSw+HzVPODCGLQsM/IXxM+GR/3Gt1Adlibkcfu9GXZlM2Ih/TjOVO2G+9UT+RMVNqX5ZWn0rmAcoDbB9CkJdATSBnA3bEOMwI
# DATA 7CXe8pNH+4m7sKonOqsBotRy9lm/g3H6kQ3IlGKxWbUp7AyRbjmSfqdOVeQ0tkHj7NNY5sZKXv8HyrMLaHEe5KehsQXt95dRLkBY
# DATA ZAiFsdIWrieoblNiGAoc6lrcsfXO4HiXDPoP4FrXzzJImYw55ZpDsjr02g+syugOYLkQJYiUmx2jRPPgGJIuyG1SLIPN3mnCqhXw
# DATA oa1YChuqpUNIQha2FUi2SjbA89uRG1BoN7JCcGxYLhz2Z+xzbjXoOG0g1BA5beCf7AkKqgkA32TU4apvYMAQDFRiqelH1R+n/8sq
# DATA txq3r9/auvHj5H36JYK5frB1681bN27ces8lyVGMt2qtqGnS/SrQkVhfksrK/pJBe0Gl21AXeXU5FsRezmdUDS6KX8vZne3hOll5
# DATA Psqu981Jk5N8pLel4uT/++B3KGdI0jM7X0lip50XDEKJSEVNbVuERzpWdQ6ffBewCqFQFTz/bhEn/JQODQZJ2vOBoQkViy6F1hFY
# DATA 9FJEwOsSRjmykAcPfKZF1LoQy8Ypk0t4XLmYA1ml2aJQTdogZhNZlmds30kyb6XIhdxGbgJ6iu813LO6kN9q7EvGn1JXQmQGtPiK
# DATA sjCB4xe42uhD9/wjyYWJ9OPmjH32P6bkJTQ5NO2sul64G0bn4JVS0lpB5qDFvTTBrwOGZHdD4gXr9VitgPqqD6c/kd8j5OT5QBDb
# DATA 0C9remPExvSEFutOGkL93Mw9zecFMHUkdiADXFdQMDephL5I/ITQz55c8WDn8CCC9ZJLoJd8kBMOVdhIYrUOM4Af4g7+EMf9S8Bu
# DATA s062SiJYd3hKqlJfYNKxD0ifI5gij3KSHioGniXlbjPMkUCOm39RBf9AoPQ6T2IFs3jo9N8fOhkEMdQJAUjYIf4xkhPlJxR3u2dP
# DATA K2GDKdGinQycv8Fk4FwpTC1SqKFMVulolIcwQ8Oz/9sgyKrLmetNi2kQVZVhhRTjHtYGnXxCZOl75iriDOsZto/UbQauB/FB026F
# DATA KtTVsZoctKKbTj1MSDss2aOSAUYMoCmReT1srXEmqSwxkDS+8euRyAQDElGKAKpoHI2yZA+pjB6OdIYvCvsuSYR2iYKqSzyLJb6r
# DATA wR8QG+1GMbjMjVx64inLcXfYOZrQ6BiZL6mnqF3LBiR0sbzBNvlZSeILuXoSk8s8ngrccaNFxuyrTiSf8e8hcTHlByQBHDf4m5s3
# DATA NnZghgNh18prHOZf97Cg7bTRMmQDdKxmwz1WdKOwToBhDc47BZz0Iifl4LMMEXSnnznPf1kCrvNzk6D5qZ2ONc7I09RQpqFhJE+K
# DATA hhYIHMfgc0C5e4INB+7gphY1AF9XgLFN8LV1hRFjoHmhF98zDGIz7SFqa1EvQZ94VyacqguSqFd6QqtoqnDEurxIabXX0cf5A8SN
# DATA smU3QxQozOTUW3QXuZjXDh6ncpYnbhopDVZq2tBBBOY8p3DSui+Hze5dvkwUTihMx7+5VARH2twzwfgqnpYNE9L5g7PZ4c0cpyLk
# DATA IEftWT3+PR3PSPP/GIH/qrIgc9Seiyam04WFM+ZNTNDAvMThE0jQRIRWqDFP4jM7nXewEdeCs3MpiN9XR3OFL7W8q4t71Yur7sky
# DATA cw8HWiBe/+h25gUmihj3JNy3lc6q1CKAYBznWO556D2+rETpsTrn2upm1Lmb3BqiBbm1hLKrLcP9hTRY/lnxMeMPf4DaKRxagh89
# DATA kczwz56GMqO08lpY4+tLZLNiuKny4hKL0UCnIEh7smU0G/2zpyXQRmndHX0F+YCsbO5Polq5sLMgCPF8/Mcc8iihpDH1yyV+muCZ
# DATA lnSEvJ72R5w2AUQMLvlnHVXlICWHYu7vrQvHE77BPFZ9w2zjCQwcO/QZXyHwJmJmiS+EYqKXLOLa5uNp75SYIKG0z38udyE2raPa
# DATA UMspVjoslmGEV8SlFyRMI72QKgdhmnjXoj/2EH1Bj/DvyvrwaAxNbeMbrQlSO7bWaCgZvNEoWl/CFb3R5E8KaX/QHkqY1MFxH/Qi
# DATA Ncb0wVxPKYaSZWho4ES4lIIbYWVAximzuI3f2H/rnLoYJ5Aykk9zKKh3mO4L/j4i3DviXyliMmfHZdotWBYT7FgPHK4E6DHBQ0bd
# DATA DJ5z/9AfpTweqJOR4poBcaozErAf6k02AsW59UhQ+8qMaYBT0G32LL8HbJC1o95jcaayvSSG7Iyja6IZhYbK3AF7snJec+fjL2Uc
# DATA 9NaZDExGoZfLoDjgPQj1huLAECWdcpltasUreQXYRJdfQNyGpjZjLoI2jXoCdn4b5nSZ2oogRk3pLCX0zX1PS53/nkmJwNOn9gUz
# DATA Jk+pachOSRCZOTzKaqApnzo2RVvTOkaJb81q5Ja0FEx69ac1bHYKxwrW0hk9RTJVn5UlzWUTTWW1FMm4gSkypzeJeGT9r18HgCOV
# DATA Twj4wJBdXrqJujVEU2bOVhhkWVeAmS+uTP2OQZmCTylrxrRmiTe6S5Lbll89gtBPZwoR5jzn4juf0m6br5eumBp0eWV55tbHk8qs
# DATA ss4Tj/oVxqPWNdLb2Wt7rpkGzPD8t5wijhtl73Yui/9A6czAAMCvij7cdQ4QPtSNVOKndsSbBH6M3KwosGPxKvmUqLoaHDE6+XWV
# DATA EusJhehOr94/l6peVLLcfOwafbBMdFQKQpj9ru05sH6WJqDda+53UWUCWUjnwxlBNBMDqaGoaP3GDRd/xDErSV4AvKCgys55PTBw
# DATA KujzrKMA7KUGIDKYMuqvSTvD/Y+iBTsh3E4nNCKdGUVOenn4rAUAI5jUAEY3bZQtQojhOP/5ZhMM3rFcCUZhaC2/NnG6kQh6EZ25
# DATA Y5XmqaIISodOpQg2sddPpxOnLaSa6aUHDXjZJvf3ikFemFqfL0mei9gZFCIPXIQP9oY6qOh7flAsJbEuzjm1VhFx9oMOTB9mTDq2
# DATA /KYiPvjnZBpT5WzrOsbFbMd9KeYO+zyL6F4srHQxWQZ5SfmFJPzMwrE5PJK5Jv7gT0p6u89G2TY1yXJrdsEPiNYLM2bUuxzZhAkv
# DATA GvzC6jT3Mj6DeQOa3gn/PmYr1Emsc7pxnk0XuTj5G1rM7nm7xd5/lAgGkRK4uvmWGZ9wc9pbkIGWSGVY8lT1ZlObz0w8g/spr3uY
# DATA CcF0BG8dxQi34PtBw3AN85F1I2g4+zNwCJ42tFIyawSeiyO5eXZ6g/HIQQZBp4uqsTeBkE7uhVXH1QtfTqK8jGJ+DCebwurQy91C
# DATA l88js2kXeCflGpaai4Lm2rJTm+PdOx+5WpQ61zbNVTeE+5Y64ODvYlGrG7gYJWsLcr9mmDRVdbN4m6tbstaCkjrT83OxFK0tq06j
# DATA HilVmHU0W4jXUTbKXA/tTzPGGuivpveQSze49LSehjwEf/CXM7plVIq+yFMCCHpEmpEiMdI87wxyegO/z/psxJ9yMgrlB8jTU3mD
# DATA Lyk57uDWVroSB4SG24Ya+JW47xEI2tqAYjVrg2PWo3Kc5Vg+41jUit2pJEI7VxUrTNuZWsgkTHP6QTix4dyCwmAGvYQKhqov0mt1
# DATA eogzHm/S6WLxPB0QTfOcfZB0UN90N2auldPWzCXTzHOOC/rMplHChibzvUwpwg3RdikOwCKTefrAAPdmDWYJbJ0TTIKVnZpYa/V3
# DATA hRxoeiCsF5YtMOgG8tdGw9pjHC1ZDOrUyOqO09BgifI2TLHuWgEL86AsQqDp5+jFhhm1wjgk3RHJnYk/CoOSZP5wiE1/ZrpKYX8u
# DATA asoV670O73nlFZ8dqjKOo5WT9jxkBy4avWbFM3LragTgGSRCBqjwdBG2TEmY5zpudRoL+yiZyt4o54I1HqdgHguI5C+LvLCbcdNP
# DATA llD7Yxrt9e13kcmNLoT90MkC4Cd5+DonlFvFBoBYbUN4JyWKmFHNHKfwlRc7A8VY6QjMQWaDQPiYWywRjZ22U5QRat3BphCXO+2w
# DATA il5qf9FZkcFHbRqkc4BPqvnDrJtKWg1UjJxCKMY8grJ2ziHng2iyIfkKSKtKCQ8N9w9L0RasuumP7VfFmHq0mnQGaoaHgODQGWip
# DATA VqtTONO9HRWeN0mINLnge/4HOmWp2gEdtWIB8MMSIsiHsPF5MQC+cKH2x33Oyw23bIoLsNBanIQhpgYrfiD/Kof2+OpMKXYhJ/+K
# DATA 2CyqnsInJdNO1eKhk3DJ2MZpI59UY7lUuNx6IEFblcyWhhcWVLsNJKVGA4ffaACRNho8AU7gDjlkLFhwOCHgCuDiIF5KdZrQIXv8
# DATA 357/Qm3eP5Dze453z0xXcGxO8RdM0AbiDAWTW3A2CA6zc5qN2icblBfRHkThXaAK7H0pead9yn9B/g7+89YO/4FIHH+7c2vrOkLt
# DATA 4NOiHZS2iaoZzCLR6R10xy1BOsPUEFk16WFkPY4/GbZ/SsAinHUe4vLG3W4CDVS+5emrJM/+3YTsPf+EYDkYJkFHDpRcpI5fUsij
# DATA xZcpiMDNn/L8l4Aoda7V+Kv/Nf+ndtl+F05OtY0qg9NvpQ0Iir+0tob/qv/5/y5funhR/43PV1aWV9b+Kln+LiZgDA72qvm/+t/z
# DATA fy+//DJsJMUdyZQroX8Yaid5aEjp1gHMwGG7225mgHJEEaYrldXKD1crCwu7x+DDaxf82ViJ6MnoWJ0TiCbHASKIAdo5grQ2x+3u
# DATA AONQjoF9AE6hetsfHx0vYCF9oUh2r22XCUT1sN0EkCI0o0KMrOkjp+9Ojpv326p3bfAsB6tlq6L61h5i+G1LHan7cJQC0Favr03R
# DATA B/YhgYitD9sHYwr8B+AskCgJxHABgHRnHUkB/0h3Z43nWB1KdqfT74jjOPE5Bz/N/hP2/6uXXlnx9//q8sX/2v/fxf/ScdZmATu9
# DATA srCgNkI2Ss6S7WEnO2le63bwwk2/kgkGNOC2LqR/M8CHSwdYJi1e4W9/+mBkFwNx5EF7n0wMRd3CzrVb25gI5BYmnUIg179vF/Yo
# DATA iUeGO6cqcOC+s2hWBcw3JZxKDmDO/RH4xPP7rMqOrPkFQNRX1dShh4fjHiFzDNvjDE7HwrD/oMgpSyS/Xv9B8td/Df9UOKOLEytt
# DATA N4Re76kqbfQ48Fn74UBN0PoIP+2BTPX++4nz4nXMtncdRPZiMfg+O1CXgqyi+OoRwlrUeE7lyfvvOzL5XN9cSFZkVFyUJcTMjVzB
# DATA +Sy6neKaQHY8LeDXSe31aFX4u6hmerKw0ITo+kTPuLom3u/AXaRA1FXCVBuStkzWALR2Ly393d5y+YfN8mH97PKkrP9em5TX9I+L
# DATA 6sXlHzb3684T+XtldfL9pQokRsfMkDD/kI/CmjhIk9A/lKRpL5GWC/JOpFCYHsvcvZZcXC0CfKiiDFg3xnbc7OHFXc4pOmDUdy21
# DATA aTpNyKByRcD0FN0QLU2nJLu8OMHBrQocxhKatkpz0MHkl1kFIK/u9Do/G6t7X/IAzsGq2t443kky4caXlpLb7Wys2sakQEkTD+wy
# DATA 3skEcqskjhnQHNLoKR7CADHRwYhA1cNmF3Ab+gd8jh4mw87R8Sir6GXTHVZk9pLeX/K0KCuMk+9PJTuBJchLkoPjZu+o3boi1kqU
# DATA BhT9jOi+Ygdck1svDZVSqHTVckLtNTODakFzphChlGH6MJm51UOiTVizUiK7tmo2Lfyn0us/KEDUwMpysphcvPSK+u/lS2t4zgFm
# DATA EG6NarJXqVRoA3HAjrM2uyBC9but5GjYVMOh+9lBf6hGPuhD4gTI2Qcga2MlNql1QFhhDcZWUWsLIoXU1qdkg02gnuaBxmRD4Fln
# DATA kUEG6yCdjmipcYwsBsUWVP6ei3lY80grkTP7orQg2j2DOZ+UcCXOePasyZtMnGVmZq2OpApInIUzXjJ15g1h2arIeAHzpAtBS+vb
# DATA m1b8SqepFvMmmB0Ou/3+EBkokUJrHZPZAEAwJpRcwcXUH6ru5HD4N5IzALRrghq7CgjQ7UmiCEoVDFqSj8OGJsVkUrKcKYEJldSe
# DATA bnaP+mrDHp+okby9A44VSENTmOyb/eEmsaUouwVE0F4LlY425w0eyoY66DY7J9kVG9tYdYueAkSoWgUy3psqTFNnuvuwHXgAdTUA
# DATA tRUOAF9KVbW0mKwnrc7hIUGnomIdITIVy7mnKN6wVcj0kik2BntRSLiSLC4lE8f0w31TpEt/oYWZznKgBXjBRwC/R75Zs88B6wTE
# DATA /fVNnkpWo85+Mfx/6s6xWb9wfqirao9G7xh7XhzBp6jz9ASHs1WPPqNNbZNwJ84435FaqQMoPlYoHRnmm2qN1dIoJi1Yv83h0X3K
# DATA 5VgDaHCZH5oXqh1w1tS+UWLImUuUkZnsk2QJQN2Ya7tAMu8bFarqXVKRvlEhcfeNSjbowr2ukgK8bfLGG5At6PVa8irs8UA3rKTY
# DATA wQjyIQI9FrRsjMg9zcFgCXXvNMRsSQRr/qg8OEqLFerN9lGxcBb1LlSD6BF02Q4SZlXPkzoIK3YO5BIk0Komq6UZ9ewS2u/NTlfJ
# DATA xlXFehrLgNHaaXXb3quL9CqobwJciRLG08hV64W8bhUrWRtgRLebw6YiKQqWpmTzRZjeFKP0DoCnuS0BB4XsQYralTQQATHApu37
# DATA TIHX2iZV4TEuJJQvgVxnzxsl8HSAzXT+ngQdEJFAFCH2ljgpp8MNUSzws2mM2J4nY43fuXN159rtze3dzVtbjd1b72xsNe7c2bzu
# DATA Focs2mSxLwVo6lOqu71xR3UZKzWa0ApIFAWSuNQ+8mDgSWlPbzkw0voUp1Q2IG4zxV0rbZrKPLzUZ5/BI0RnA2O6jnD/JwvTAi1r
# DATA n2PWQxMzHsS/x9XHv3n2OzTOxZHffLSSCgZ+yNw97IyuobU7WVHHkjVSRgHjsTIj/j56kuF2KtBth3Y4HO19yl90ZkigFKOGktyT
# DATA J1cWvgP9T8Ps/m9UFTxd/7PyyqU1X/97cfXV/9L/fFf6322Uo8zai7srppAANavat3ijCNQnzi2r3VI3MMwzxuYg4JSX1uQXKILk
# DATA 7362gCDP4NTT7eyL/QjcCaTIsC1/gR1Q/62x/uXJqH0ygPsdVTgeqiNpn+KupFbw3YDDekFXTallOYSbfKvQrRVdj0mDe9iaB1pQ
# DATA kATN762rN25de6doUqcBgmCL8qa1IOiX8+VQ8jTLAElQy4g3CEDL9N7LwmLhjUGhyk5jc+f2xlsFG6zXQe+VFIWQeyOWjMJYFQvp
# DATA 5ta76zc2r/OpAjHwLr6NB3NJsEbSEIjFjJZ9toxTpQ7wtnpaKE6icMLLr75anNUj05PGTTitrm40tm9vvru+u+FgXuPRxBNqco28
# DATA 4uca0Z5zC45HN608/tdJdYNPmESihZ0cEpbvAL5FnwVciq7+IFyIGYsgYPlErpXAT5A7LWRMjjcE3yl3f+3skttdU1J6TMFpDOTO
# DATA I5DfMIjV5bXLmBvv7l3Mm2KXhVC8/rBVOCiCPuwiPOKfSkpfWX2VYtDsr4rzTMf2+tbGDZKmFigVO7qI2Fl1MEyMOwI3guZ41I94
# DATA SMhkEi6LDw6DN0of28lOc8GzWThbXGQvBYldxNAGdHtw4hUnwc411fFcv0Cei/hsKc6zfkPmamv93fXNG+tXnW3M85ZR6KXdKmeT
# DATA 32mPRpxBXrfPr3SuZ782jQCO7MGGgtPNSd5zZhEFTNyN8C7DTgtjidMe+A0WHXhvbIMUon5vmydt8kYFXHrY1ZBC2J9p6V8sPUa6
# DATA t17+SbP89wBXbf5sVMp1xb8UoU5SUuyda9K3Nnbfu3X7nZzJN+SZpBDSW11aklTpJuUVwP0xiaK3lfywPdv0ZPACgby/fes2+udS
# DATA FLj2urRdjKz29Z+QHgH7Ye9jCrPEqGPuo7zCutR5qqqQU9WwBtmG6k0Fb272eqvKED8Eg5w1m4GiQAo4B+oZ/BbdnPwWlED5/bNx
# DATA m1KewI/DYfMIhQ9dWB25ulVEx6XW8CUc/oo3LL8Iy3EH9lJNxqLjeZnaptX99u7u9g7XfHvj/7izeXvjeuqcOlpnOzRkXZKqFaff
# DATA vn3r6gawMSVmkd5CcsOqy8T6eHTcH/KdtJqkV9WFWrEZhIXyr3/vrb+70Vjf3qSTRl0v0BM6WkrPBEMRvgdQhJqCSTHFvdhLf1RW
# DATA t5cHzWGr3YK/0N8rVfupsqz+byW9Ei+5Pewrbl1P9KzCbcnTWgKpo4AG7dHYm/u4onhDX4e/rxFsURdilks6pVtGGlQIfKcLGn5X
# DATA wf9CucugVVU3clENsWoNletZW+vXDtvAOGbMEUPHKvbJAwUga3JVrqZ49VVECbroZrdK3aAfpIVDw5Y0XOnfE3sS0w8FfzQPoAOk
# DATA VwC1Kwh5tWXASBj37mW1vTq8ADZM3S7QcPAtWmSk+v1+61RNJnx+oYav2ZR1pXNYgKevry1i6gr4T/HMmbQrkX5JxapnE+pLZQC5
# DATA Bq+OQWFbAfm8gM/VZXiipxn9ymroTkYJbbm4enug5GCqqFgZ9UmvhdKcEubMdJGT5/vvi6YWf79Uq6V9tCyjpY4KVfSSeqX1C+uz
# DATA 6NRbQ1zQe9atQr2YCCp4cnbQVXtQiA/pEcY+WSggcReKtdc1MYuxu0bLhpx9qTnoLJExfEkbw4tX1MAL3H95Kj6cMAJWTRcjA9Bg
# DATA FVekWTaAh63mmcqtb1X1WW19OGyeVjoZ/stx7VnxDTGs878V/ld9qzr/kvsR1FOMddduUn0G5faW62+QRnzuHi+lFzAGsX3n9uY1
# DATA iSKQyli7rhhOsVDUKiu1Lr6+ytIlkTOjhXqmcYofASyZ1k5BqS/JZ5GApz+lp1HNFB4OpUSVQagzyLVACVxIF2YaQERmG/sR88R4
# DATA ui81Zb7aqrZyBbgM+i/hlUEV2G8XOITB3AP4AsOHjuIrFGNcEgcrFonyb1DhJYPbsG8Y+GjaYbm9/tZGY/Mm/DeUpygrOV/9K7tt
# DATA uNg3h6fXJSakQFAVkFdSUqAhReCQy3QFP+x3FYN2sNIlNoleFTnmWVRiEE5lOsyCGalAEco6jZwHNVt8Ih1p5PzFUo4aNSayF3gl
# DATA nIwxLyK4B6kO0BYWqTz/LkLXf1/K5j8t0Z8Kct0m6V8sjQoSl0ldWEeMn/YBZn6FULYyQ0qjP3XvflFT5h5UWRe8MSgO/0VRyUMb
# DATA CVzusWVwXOyhGGGNRF1o1MIOC3og5rZSnK/zjFtdLhMkX7k8ULcPvOq0GbLPRuGiXuRDR+TNAT5XC4oElppJ4C0XnQtxKtc+47Z3
# DATA uZVOc0f/6XuR521ZoPr1a9c2dnYab6odC+ItpXPDezqxHdATGvwTzLqQx3y4RcWybtNZq75X/LjdAh37fUwsz3NC2scrSXbcHJL3
# DATA R0KpJxQHOrXSZQL3szzWKfkO3CAWTFK9ODARJ6tygYjYK14J37HNn1atkaWRfa8K4IAnC5JFAuoynQKWgxmEsoKETlE3bFxW/JbH
# DATA TWBIAuwQrag/Ogag7Zx63Fw6fJcvJfiRSddhT0wFagKcc7nkv6TzL8pcOWgT2AtG6CJsjrMUl0pNxtlksqBzvsOAql6+w73Uugjj
# DATA heFscVFYsQTc23dlTnEnSUL0p6BpWFyk5ZtELsvW1IlvsFsxYVGcpegwpbouBJ3C2NVv+GdSSgKyKTHNmKPSvzeqZ3av+X2DklHN
# DATA 3oLqvBQ9xE2I3b2ztXNnG9QD+q4ZaoIgA4sNOSVvifXrjzAwLqbsKRmIX/nUJoswsorSrMDRQNIzjRS0OqgplO2PKJnmAAdYSUfL
# DATA Ax2y9Uz6ULJalJd7EO8lLZvDip47HXip5vGfOaf72q2tN29sXtuNTLM9uxjSdqbOthEoOrqKVii9LjVflW+seW+ORk3gXoC3EFIG
# DATA 4ienXLuX2NSaB6mEp8AdmbwM+zmZFrFmdQwcaAtQM1701LdZYW/RtAmTXCwGu1kPAePCuLTjMIJYLsQf6k7+JGT4BXxTEh9ADhGs
# DATA LrjcSxMnpcJhyrR4i1oLyHyH9qrK/qU1thzgd3spRTpAkiTPokDI4OR9iEoz/oB4Qj1HVqQ+QZsl+QD3dj2ojlMtfmf+/xz++Y2H
# DATA AU23/66urr265tl/V9f+y///O7P/7pz2DtTduwfGQghOIU8b1/OYMpHDHmra+SrIBc+AaqN8hQIfZgl5OLKsu/yE8x2KMfbwoDfq
# DATA yg8A51NfyE8dFvyN2pDhwv8i1uJ3Nn4MCsqdO1cb23euKkbfuH7r5vrmVrqwvrOz+dbWzY2tXYx8QEEEkk4M078rvFEld4+95O6o
# DATA fqH4RvA5vlisVRa/D9m425WbYNE76DazLLmO25GOGnPqaLhxNS/EEHv94Qk4IzHHyrX18eFrX8OJNbKVj75OXk9eWVklv0p2yoLc
# DATA nnezu3d/8Mb37j5cXi7ffbhyePfhq4f1lFlYYMWzu57SQBusWufj0TMjMI+27BH0JDRGWAHSuUr5OW0JjApC5gK4opSStbWLUfPE
# DATA +QcIX9IIdSUV0kMV0k6r10z1eVKsdCEJJJumndu5ExnPfxagOic82BCHBbQC9BEe2/P2HlQCQBPYFlh9X0FrblrRWbNxfOoR/KsG
# DATA 1qIcReASCfnGML2q+QsNfl6OIVBRd7sFL4ms2jHLD8Ub9sL78JfaNylgGg1HRb5KDHUPLEfMoHYE2ghb2GO7n2qJ/0Sr36WVibwp
# DATA vjFXey9A9ZwpUGxVe9XySl3ImNJGyUSi5QqpX97JunTFVQWWZW2ZlqWSyuUKftMV0GQgcsa/xANfL/9EDbbS+Idy/YJ6tOQ/Ky7S
# DATA tENyqPOPlAU4pBIyilgON+JSM6CgEUdus5MpYuM2N4skS5TU4hp6BBgBPJmnz+p2tP4mXNl3304j2++bcAPiPQoILFv90ZsA1eJt
# DATA VfCu4ZmoxhxYtZODHsu36l9UOL+D0fLqGic6t9/2AEsJVmMlTI9qSp3fd2h1NXoxm299MY9bc9T0fYasIVxIVor2ZoPiRXeYL0Zb
# DATA vJ5Qn9oMf+NJRLA5uqA/JM8UdzuIr0pFBzwDY72XzvBWe++2EOW12xvru7MotmSnd4/RV/NCDn1F3NJyiU2T0tdbxUCNjbIkxNAc
# DATA 3OM2S/wMxtbY+JEarvV762qgEr0K33Z6R5u3vC2a078729fXdzcaV+/s/NjRdMonp512t8V8j1fbXlvxSkLMDnBJygpIjFMdkzRp
# DATA WgnnTSIOguUmXQkClptCOZmm8qd969Zu4+b61vpbWnWk9YVTUgnb7Nokqw54tnnlMG7TglMmjs12HooB+QszEcdwHWk1ECDKKuNi
# DATA Zy3Y7NFWMEHFDBYkUsdK8loNWQe+LMKvlUt54olXFwvocHhHBBc6oNFRaaW0snpZOyq5nlfYbKxBqzEeb17X+TV2/vIL0oukfz4z
# DATA yypZxKokCIQvLLEAce0mCwYZDuuamDzS2EXK94adtcVfZJt29VTGPwS0ODKFsWicd2uj4qEQmFRsS8qdXieGwDN9Dq/durl9a8dT
# DATA 20Y4S3i7i2bSLkbVfeds3ohDsJx7MFmgr8NjzJ0i85J+L/imBE2c0bwHUcsLjghJ3LdZ4olD5WIGRS95XpiSPJZAHPfBXj3WlOM1
# DATA y/VEQcL8lvb0D7demBRCAUH3uyCDtF1XhJ4L+O0eIWvXPXUvvnPymeOT0MpDaypN1GVHyANHEKLM10oSurj6YvxABCCD3cjckyeT
# DATA qUgshaoPeNunzabVGrhzO5mHPOYLy8g1cf5RN22UNBgYicZd9JzxlLpF5wDjSvJbEYw5Lrin7nPgVcK3xJriZivFvZW643wuIHJ7
# DATA Vbj8gafiy6rcy+nLFh39bNxH0YAKLtt5T1ryGAdSwJIlEVlJu97p6k+hvBJoq7oL7CoN0YrLrF5JbbYC715L8FpZwJrkGgk/7HTE
# DATA 6ffS4tyMxb0c2jNH3VypqnbrEYWFFANlFE6qOgdRl/Y9UT5hRCO+q60UcfKtubadtJisJJVFYRYZGk8X7IEhR9oz4dFVd9c3pFEx
# DATA hJaYhnNNElYmabkciUdVsIPD/tGFRTJvOq3zUWbqq5A9MoC8nc6w6U4JGZ0tp/qYAXYKP7f8SlzTbNjSYQLaV1RAQ5vVqJuEzAOV
# DATA 2VNf1I2nkp1ixjnf5StfibpwzmOdSVEaI20i6jVYcj5qoz6QddwVTndQXIjTBSewdcjDao2qE3AEnVRBFIyAOLGfgq4WNKYFr00k
# DATA jwpVQfxAOKrgORJf2E9POlmG/j7OZjpLcbBKhONBq4sKhS6qR9yz4/ZDaUDyJFL5Tmsi+9DYHThshTA9ahgCwEhacBPiuwZenMxt
# DATA wdxRw0uzc1fJ2d0cVqCvZCaxCCGb1c7BKGz+SYMI9741gdRCoHOxhTmsxDJXZ+0RP8RrkiwBOkkNEPLktqzBJKZtoW/3wtJ1qI46
# DATA tGfWsT6/xPj2+tZbGzHGbnaUNE59phxT3rOQ+hxx96TfAly5lpH/X5idTmOlWtB3xNmFPMeYKczxBaVaq7PydZSQZkq652LSvig8
# DATA jRfH+LHcHXNE6vyu55+U+WOpDPqDgmreDxUKpOaot19YHx4UIofkltd51XwHJKok+I59CvDC2BqfDDLt8tbuZeBM1MwOOh1SfJcw
# DATA 63VvVFuV/MJzuC1yA8jMYf730zRwUIgdpLgHXnJvEiS9aEHPEpXZ/geN5SxjLvVxB+3KxvsYlIO1BWtPu94rDmSmpqSmDX/89cI0
# DATA StJ85IUGxP2Gf3QYDrjk8tKof4JOxVYN3LigCn0iv0Q35rBR4W367ux859/4pfQ8B4tOkSUKRUl0zvpBdYeM5cwow8DATI7O8WuF
# DATA IpzmTkeoHldzR8++nkqX66X0BqAiri33XwXYEUrpkJFGKMexxiSqOmn2OocghXAKK+NhuOd0L5qVSjIO4UOT9ZtzXmFCQlsPEj23
# DATA PD9ek+nKk8Ssioq2yDRXI5NAYMfelvQx1+6NTxDstCBEY6au7qXYGqELtKX4CLXrpoGCOXSL8YYiIqtFPjETIK4s0JE17vgGPY8s
# DATA YjWaM585bcQpqxCnCUb25toDjcLC9NrNZM7+kpdK0qq5eksxYjSz9gb+CXGAwRoKdQzBDT1TcjPXed6lIlQmi3NV82QFb+anH/Ro
# DATA yx33SNW/cP6DPTa3cy+OMa5aTFVfAxad+8L/GpDgjv/fSeeI8f2+URfA6f5/F1dWLl7y8V9WVpf/y//vu/jf915aGmfDpf1ObwmC
# DATA Jgano+N+7yJEid0aQN75hDOjQuhos2fgMgNcUgc6ErA4Pa9AdqdrDo/Q325BewUOTskbDzQZsHPFE09+UyDv38Nt8Gu7AQbwMZCy
# DATA QJBkwMtvtl+g7UW48MKZqaJQNK02Tak60UyMP3G6bnNfsb0QCeEaAyAbVdoNLOnEfNlWW6pIW40rFLAkt0LJ01IBr2y1kA31KQEt
# DATA CGAZvJ27GutTcxee8amESphPA1uyrYPm+H5riDUI+nfASI6bQ8QjWdV4JPjEhiRRD+BMNPnI5EorQ3ZvuPn2AI3eYKfAcbLf8HB8
# DATA 2+5sPApuu5jfuBic5lxkupGS1YnhNNhuUXKnXtuE2QCkftFkigmbnk+ZFbH7HFjKtJqlVuMu1XQWLx5sjf8txWLutHG+xuo4DKa6
# DATA o3ZmDXahfYMpCk6OhNM0ux0lJmVmo/lBZxlHVGLg5QuDpdBjHUsr4RRfazuLFhYzDKGuWvxHKduQRDuYu85iQUbDiCE0eDF2QiyU
# DATA V+L61g6ArFhFQjycaVgspdkje5udYjmtoIGSPQd/oK/q+vYvqmXKuUZO645TtHOr+SZckHNBT8480JPJdwt6MocjIT0rmK6XXGdl
# DATA JqqScZUGk+Da2kVvwDXjd41TdXm5mG890SmLcrgFrR8ltBv1KQVxAf9rkRQozO6rGQBG7e7WEodxT8fNKUXfYyvUcw53qLmE5G6R
# DATA WMAnEqVmnRI0kWOpNsYhjrioJWdOe6pzGJ1G+5qD3STMloMPVItv3r61tdvY2Louz9jEex/7CfnbJ36Petxk0CdtIwORrmFFCaL9
# DATA 4cXZ4IIXdJi1eb5fgKMC2rySzDAov+D0k5r5XnIdWYZgomXs+9U8GPazLMEMBTrYW4ewjfoIeH6AvpWYpJEr+ynA8MMr+YRjbQmD
# DATA QD2nIJj9Ngi+5MvZInz05sl+52jcH2ccl8tRtBl7MsNXoqG0JwMC5PEFlree1ZgeKeA9fjlmSP6CFYtfsOo595rl/Q/7h9S0R04M
# DATA /sHKccZyqJLNxHQqsm4xK4sOPDYbXmhZz+6UjXUYRyVwXa/1KJiH+iNh7hOPCQ3U32aXqeXSyFe6EWBdAJp1Px+7K8q69cZ0xsie
# DATA pQKnngWcMrNYZY1s0oT334A0AI7fvdot4+7IKAGzNgErqm4aI7VBryMzGrdiZ9IDXNA5BJtNTDXoSJ1/g2Dauqr+gx4a/LDKypAL
# DATA VcmlZrlOCR+PD4aVTn+p2x+BH/WSCRcO4GAcJxdrEoiUoa0ZKztsKwGkw/cot1NL1Knyivb8qbpjQU2a/lyLCGEnnZDn8PVkNvVB
# DATA 5fOfn+g2Zn74emazxDPpftQ+AQe12B3WiyAvBOADgkcg90b9QAfOUyA5tBEah+UNLCS0wNMLBOy7GYLqtNXCQ9HbZUD8olaF2hyP
# DATA B/bGoFIYzVzrKv7TamLDVRnRlO4XtRc4QYVAsLESuyHhJUojNQt3Q/3096R6VNhbtD6qkyGsRrHjB80BZBFr9MejwVgejgh3qrZy
# DATA eVkzTR4nDQsUoWaCrByjHONP4q9zp4CmLVsb0LDkYErSAd4iGSMT/hyj/MtAKNmoTz8RDkXAUBDiZQJ2F4ZOsbxNKfEM+n5hrylN
# DATA I8Y7WUA87WZGwP0FN+FRCvndxgfHiXVjgMyQzz949hhwkpJnXz3/6PmHmE4Ssk8+fv4xJIdMnj2W1JKpBzUPLvT3eopVJIfdJo6Y
# DATA EZw+xJS+LHXwxwL9hMBMn2Kz//HsKcA3USteRsqwLcgUAu43fYA96XXaLWzQgodKnn2mvv8L5rn8ZwAxD+u41uwxxCiAGImMwx1t
# DATA NdsnaB5L+QHCWdn4U09idTKPaLKrk6Xqwe8/xxzIH2AGzo8A7UrNTDzxp3oRmeiit7KaGtEuC8RIGQqJ/smQQRSgyJJe6etwpydE
# DATA JI+A0BiOywbfkgl4mtfVXyU26Tx7lPrJQuVCEaabLRymz/6FUkGr6fj02SNprXCmt9ykyOTyGSJ8Qcd+gSmjHwEwfol69WlyFmzf
# DATA SRUewvgnlcTORy2p6R+rfx7jx4AMBplPn3/kOuOazaWYheFS6CQCDKdAGD2oYrFds4JYkBBSxnPWigWFgKE31OBhfaZcs3dw7N4Y
# DATA ebZhdQswvY8wfSyk2P7jbHS0HEJ3VGh7vr/MwOmSxD273JH0YBi0hnPhBpAU6/Ys6KKiQ5PQRnhRKDqmukC95g7/vzv5b/+kOdDX
# DATA mgimDg1pVUpkOIxmRfu+zCqcqN7TOxU9VmJVYoiGFOhGD6uOO0jXjdOBQE8yHQRxOURX1r20fMhfwrtivS5YIWy9oDilBlkDGRoL
# DATA lYX8iAy8DfJC1OmwOddp7HxWjXXb7UGNkLnhT4NiZW8SY3iIZVmASDrzayEXqNr0njcSyVocpmRXflMseCZeKQzRgh0WbFaUnris
# DATA XjFTUj+qOhKfT+NTg6cwdUotZC7FhbwgG1daIoJhCLR0kUhShI9yudcvo2pggOkK9DOACEM+hPlc6fEhuCbimcUeIrDCIHb5xgpP
# DATA jFvwfPMc12wv9AbvOrl79rdqp/6BNycdku5ujSQ0mUdgWbAx8ZGLGjIvVijXAZymLhr+LIh5xysWLHaVlqJ4+IO92oq+yjwCoMZ/
# DATA 1p2ie5xyvi5XKuctuvql++NOF4Qf4+5nvj4nHJirwfMBwWZDtJmGSUstbXoVdx2lPdTc6Vf0tU5U2GXINqbqj9wCJwuO+xYupMWj
# DATA iqHnFsJbgm5azKaYeVAsp5Xx6ACX/BCeFNIf/PgHJz9o7f7g7R/c/MHOT8i3Ler1tVe9zIqmc7hmIeJDIh5h4JBFUai412ge2aWC
# DATA Zo8EDCuINTonpcSB1q/KJoSoZDuYs5poUpsshB4h2LmS7kFxYZojGfWbSF+cyeb7UswV7rf0i/mdaG2cmdJPrdly27CS59mb70Ez
# DATA awwJnlNVaFRggutp5UrQF/MGhip4TJZuceVyky5o5fLPxh1Mn6vnW5ilH9Rk12sYn+lAhLE7iJnm5mjXZDFnW6PijtdBGM2FLeWA
# DATA DLZO9O4TiJjxKbeSSJj+azf2VslKeWDhwoqQG+xSNvfb+JasNWhUPedluzM25GyIlWl3x0PLzPGLzCEY143KVJtnPYngw8ZMIJao
# DATA LzVWF8L0chUHfTgyKFJWavBhnjhLA1LN16WYk5wMITS11Zl+o9Z4vY2rK4mAhAS0PENUDnRFOYJwREtm5FyThbM+UzCSDSxTE8wD
# DATA jKAzanCnhUVadENTFIrGxdjK2vh83ryh5UCVuh+VA0uu1IvdKAa3KF3R95KdUX8wQBiyI4F6zehRJVlPhDtgpqpOpvrM6VvRdKMu
# DATA uwmiwoq/kprBh2hjvX61EqwtdVqrtFCwbLWFVaofIqREcH4XFWWUWxSha3MtVGTu0efo0gI3pJDL2mpO6/PQsbOByhCIqilcWi7G
# DATA I6IjbF8P7QUZv9PEN8rr/TOFZuwsjG86bje7GB49/Rh4G4vZT6DIOIv7C893pJCljjsA+lDiWyk9OfUV9nn159lH0COabCoAyJbP
# DATA lwOObCRYrAO56myvWb6d/KtWXcI9g5WXiF4PWoQvQXtG6qWv+BLzGerO5krYOEMnkcaNgftq696LLZOsfU3tzZ7MOka8TV0/WXnS
# DATA YbfUxYi00YoPtfIWzZuk38+8rxnw/+e/AGVeYqsen33+/OPk2R/hUoePGOw/OgOoYSiszgNnHtENfYRq2T8/+wrUgaCZ/QJ0sl+h
# DATA PvpTHsCvz7UyOVf/Odh3/AxudJunkCKDtB/fvNKCOcfiogjv5oh+kyNDYkOauBJTKDrYaiX823F8yXHElyoY61Ufu3TIzn+kGthb
# DATA NyrGk+f/E08scqcnTRzc3Qoa02qYYWoe8QaurA+PxsDOtvFNQayIauy1RkMdG41G0foSbHiNJn9SSLUanXD0Qd9QAzLJDvqMtJ8p
# DATA cUVMUqgQFDmC1IrtbovUiBQXReIT2z3hF5nVyIjFqiUCk0F7lxiykcWmOoKoDHcA+ClJV9C0i2ITGsAww8l42LVVatHhlfFmjr2c
# DATA MgnlMsalQHjd6aBd0xm50GJXk2/wH/gqM9c2+FWxrH+Kk+q5y5OZ6RuclpLtf+BwACxEXlXqNPekO3xpmZddxwSkaLmnxPvIa2rJ
# DATA 4bT0Ph/CT2m5HFkKn+Oc6QhE1sYvg4Or9fo19H3l6n33jODg9C1gdFB+iRYgxfbPxWej2mAakOE2umCuKhgkI+r9nhlWfdrScnZD
# DATA m6c5p43o1e3CVDVd6PBvvsnh346GHZ/ouwT+0rp2rUU31NNQuwTs52rRGmhYaDSQAhoNYCqNRhrx7SR2k+uGqFNfvNM+nZ34AvT0
# DATA bQ9edQh+POmzf8ej/P9v71uf27que/OZf8WxXN8DSAD4ECUnUFCHImGZjUSyJGXHBREMCBySiEEAxQElMRLvxE5z204y6bRzP92Z
# DATA ttN779zPihMnsh07/wL1H3Wvx36efQ4OSMpNcsU2FnCwz36uvfba6/Fbn9HpndPiYpn5wHB7J/DYJFmnWyLLIycBwrzVcKJ//fKf
# DATA oBGojCyWcMh/DrVD+5VAUOJz7g1kHsKmP8V3P0ZTGcpwQiZAka4UiNc+pkxGoIz+eyMpN/bsBdAuGouwTYB4hdtmDeIfyCpvkOIp
# DATA 5RwqLP55REj9ef9ZKn+8R185/Ht2/NfiwvLycgL/fenm4uv4r//a+K9tDfOOiTqiMSFwkHY/Ef8V3xFnp+Dl+70JpOKSTg4sjMb5
# DATA YsCSqPEye2KL/RP8SPEXjwjD7It/9PFhM5mRsY/+uE6Nxa9VbyqxW8lw3jOFupLlBc/ifA8AK3qTUzLgVi3IZzvGvRDuLYSVHw3B
# DATA gR6ip+Ge9ZH0aSePdlPrGRoORdLuWixqZCMrTr5RXVpuKlzpznAMCKoaBgiD0LVHK6V1M+AQFL5qwtoUh1I6ppcyAUjNjDCMa7Bd
# DATA v7e+s7v9YWjjO5nITlTvYX+4XwivS2xXyzNZeoR4Gp6lccNjwJIj7eBx2R4km0Slk2eB86TNvQftr25uryUTMkNNmVC0as2Sjpjk
# DATA Lu9ZOgMad06NAx5pVxrpZK+eeybUK2kbESFJzF2TZrZIVycbmg66mxipN6M4uQI/bj+Kyl57KMF1QEEA2uct5u3gQ8GeIE9QE+3c
# DATA sP3bA8LrgpvWWZ4x6vvEpQaafVPh3BCD3t8ihJSB9YoUDIEAUJlxEcGiZt4im3DJjGKhWNIrfhhLk6Z3NzcBvvJDJOod2y2K6pBx
# DATA u3xbtjHI8Ahtd8voY65drIcHAfmQklniGE0XzL1lGIq4j0ZP2h1JsTJpHbFhBxA8ayMoom85zmXIjsznPt7GYYZnRtvpu8QGCzVK
# DATA e6hDNz8VwjqtO9ZdT/IGtinAXjKqt3ZUolnTpaBkbLiweJbgX/iyNzrDsEn0urFhXLFsHikGFhn/ULQDFAaCkmNKvXFbhjN78ti3
# DATA ywcQNPx0cal0e/ks9DsmQk15Wfjq5sbuyvpGfRswO+sbu5v2QaIIeRYbz3XoALnwi+khNaLWP4j5GD4mbDe9APMpHA+DQXvD+cyC
# DATA PvW9ihWZ0sQsISVnyahYlDeQWVlcy4i3SDHC6NNxhmAZT1gMeOnThBoaHhlHYBCqVpcZS5ErxscLD2RUWYHcdoIYknFJDVVd04zh
# DATA dOwaHn2NVNMUcwA9m/POPUqeR+RapgLGQx+anHeM7MSY4vE854OzQQ8TdlKAf1jMj8+8wIJ603osEn7DlJkyxYlN9uBYJ3OoZKPx
# DATA cGo8cdioLDTeUUo00gbZQ65jOzzUlGhFr5M1zVTKOBKpRFPtq4mjTUE6YJ4dADKJs4aeKl6jjOsAlzltD+OKzIUaDkwddRKCEPOy
# DATA sOTdnhSKWViJeVOmFHw5U8xYU5oZ8r2Hx4nyiwsLC8ViNnxi9gRtfiCOEH+uZJ/3b47cxMWcIO/E7Bq2HNi0XA05TFcIBOgQduZK
# DATA GVTF3NRkybm0xz4ZZm7ufv3eyirJlpTmfOcVn395j0CJocDmGAzURTHVAlLgoaRkl9OZXXOcVsmZkADBJ6MRXpandCKtp7QVUnto
# DATA A9ZO7ems4aZFhUVxGBnKmtY4EmIf3BWk50ZVuiNKn45sD7xiUrrXeAHKfW0KREF64L/j2qZM0BjtBdZuPDOz2tKeJwYcQkamuhwR
# DATA zkqB1TJtjYQZLSUKDm/W8DJmGIbhSJSWFi0HAo+LypRTkNY+kTrISaUqtkOdislEOZ4C6kjLo4pyj6vLXlBe8eXkIheTq76UuKHw
# DATA B9qdyBLmjY1CLnWmy9F618CwSgN+8kyRqCoHxoBNzvrbG04v/PA8WhZI+g9N657aA9Ryr2vicelfi/ki1b08Pp9r3AUi0k0O6igm
# DATA 8bCw92eKjA9z7GzKPF2ZduNI3DZmuGnkv2VYft6NZD6aGW8fyZsHzKnx1eFnlFeAbhN+wO2LXCX0oLSWcVyYerlw7p05rhaXvFZc
# DATA 6EqR9zqR8ypxddeIzMvBFdwxZr9fpLglavKYy3kTyX8L8aCEmEgS+sqB+S9c3bT2MxM/ClaaJriDa17UjVeVOIaqzCly5dnVQliU
# DATA 1PTKLmtUC5LPIlckU7G2yZBaElx1901pTWumcsl9Ds4IyyfSXQvzj2aJF0hND9bvba/srm9utHY2H26v1kMr0FY6T3H40YggbjRT
# DATA F2ury9Mjd71Mbj+CNBsEC2UZLfF0g8q1Hp1L2mZBfpig9DdqObh2ygTgdlLp3x6s7zxY2V19L2lBBN06ty/4MhI3HTDSI4xWhxBh
# DATA 86+++6BkLD20UUtAskAL8p6InoBsfZFtow60pU0zFtZRMqMbvWSmRk8RhJZQCsJVyiO00q12zaanKatOystY5zBwx1JNyDiOBSq7
# DATA zqm7ARK3kRG5vl1fC9NxS/NcmlwknDyztlPffn9d7cI3UaCIA3H+o9mrTMhQ0vJFp3kMcXBiCoL98fBxjMrr0ckkrswlJJuGJ7Dq
# DATA um/jNBPpJH0a1umZqS9gwncFgpSzSmphxAOZM48BmltCJgcioC2RRFpNA/EwLpp6JDmRbXXGvQbvJ+wpC1byO0G2mBuAcwXMJSWV
# DATA NFwRY5JrTs5Y1/MfQPPoS9M8HrivmNY5iyJXHtxdv/dw8+EOLcnuyva9+m44W45AY+w6UeCCDIRP8C4n1xYKDlRFiBGEVU8EofIE
# DATA 0FYkfoR3vzPlI3MCgrAQBbi9wcnxvlJnoMUa+UjAwGiMwQat31GwIhIRfBSNAUchRkwhRBzDTYlBdqAxUmZr8DjCbNtKJMcecNu5
# DATA tRJ/IsoIyxJ4FdoIY1sl7IpGY8zkc8WrwQyZoGwVIatKQO1JZ2SUglXbh3yZg0MN27sllk/cv3FvweJCj7gQdIo/xgwdbBnmRGMl
# DATA XQC8v3SnM8ApoUUTApSzizQl4Gfv4CBC9cz6lq79GOJBAawzaGM/K8EGnhBCnAM6bg8Md0XIERoBXKGXSTgypLO/tfYlsb2nouIZ
# DATA Goj0BqapD6RAat0umIvwGekIHcaP6OFZUyWTooMuZvbQeDWVh3EFT5XPI+sElMOjs/l0rYlILEx6l4yLS7vmTwWkUjqA6VqPs6sR
# DATA oN8MdgWfVAsCG4ycfCRflcsH59WjCFnvOD7qjQCxdkBwR/Ki1WX8yYRlyXdamLPqPTN0Ad/JkRPrK2k88GR4hzCPNoQbtyZDpBaD
# DATA FHKaCfSmuADS6FwKjqey/bCxp+Jaf1Tyd39K+rSE9jXy0zKeDMeOrVL15Y0Z7UtuVY6crRHB00FGUzwLi8UsXucVRJlhSuouQnbh
# DATA C3jXEeV5IPenAePzQxtmJ5nZzMwqQRRMj83gVXpUoH8oOyr1ysyVbIdM5fEnBsge5NOQN4q8fU3fxEuIe3oUUsyTjnCG6655RklJ
# DATA JLmWWSgA7j3ORX9hoElqJWPb5rSCXMrUxo1eAISAQGbYAk5XKdOp07UMSQ/z5OGavPQkLumJNKVSmoXniS2UjIInv1rD9dW4dKX0
# DATA gV7xNazFMOkcUUKTrMeXd9qRL71EDWezhHFDI0VYxGrD9XI9XuwZQ8JNvISqNcPJMx34AVPr6oL8GDxEZOZje/R85nh7NP3kmepP
# DATA ksuLRI+ypDoUngzaj9q9fnufMGDCNH30lVwn09XU1C9MnkgdDDl2XDzaHw77pn+6upJk1EfB1VUaZ6MqLnhNx38da9Xd1D9lVav9
# DATA f1LJ/swDkqpu0e3uKSPWKJDlJQm5AlgSnHMXj4jjoeB3w0Gvg1m5uTxBdh0BoGWi0HdVFT4QLf92mXmr2H7+9u3Q8ezfjtDAq39P
# DATA bpiiljbGujQQkg2skXg/Y2dCbQ6YihcaP2VIVj3Jftj7PqMbNrBIFjvWWKASqSNTvbqy9qHyEeJT1VJgq2h3rbPWAfBauEMYBhNe
# DATA OzIeSW7WH4rrdH599eZWnawhtto6n55dg1FYPZa9TekRxVNnSSYASmELJ45E0rQbRIwAak8CV2CjWIE47FG8WVxYUIAYnWF/OPZU
# DATA a9qJDZLL6qvqBWNpKPANTx/lgkmdTzEpaiVn840ar7gpaEmuJKlKBV2Yp7Sh6puIGwtp+kCDJ1dXgZui0XYCoSiArtibiHKsDgSk
# DATA LDAhRiPQ+GDmUqnsmyYf/NFiwNrQrxrD1IfqahpVPFcuWXiqnYXNHKAt2FnfuCfhW1Fzr/R9JimyumsT4xjBctVt98FIxOInmAYR
# DATA URLXicNa4kogtbqTo/bE0CvA0nONGDMKVEAqiUNQhaGeYfJ4WJYEoTM6SltLWybDQZKoMK5lt3uKUM2pugK4K63KYiSqiF61CIGt
# DATA BiCY4rdQyqu0AtaQKJRNXcrt4EJDBKDjJlIZ7mPk508Tlm1u0XaVQfcm2UtPOKH1m1YF0LZxxCbzSi32E220mnsJFVfD4OnegHYz
# DATA ZuflOUncJ6s3FxYX9gZnZtbx46G4lFJyJRpsg4fVpK48EuR/bM0dbkhQ3HOCItNXtoTZ+tiVlyoAYBk+EUHHGqYmIOLyjJGDbxBm
# DATA IU+YXSuSO9c7H00681huXhMIqeiAHGiIRTNFjKIa/RlcV2hY9hJq+GMMJha8qybTAEPjcl00u1U1yiW/EiLTlMA7XQrnXEAD84Ad
# DATA o61TyknGINsjv2UiswhqiFuU7vys6GTJ4jetywzmRmofS28ok3F5snencLD3VnZaa/Wt+sZafWNX8jOpzckBGZ2WoZ5y0xtRg2U/
# DATA 2rE/S/0MWMXqrjoDDLELN9zUUaq4XHqpqob2t87HKOQIO2n3GbyLjnOArhTceyjunOICd4c9luQpGYgZMv3V37QzeAQsQQTHkKmM
# DATA lCsxXAMEI28PAmMS8RzWSmPFJ6DXTbwBHiinqYaRh8hcB5h1qKaZWo0UaKCWcDAMZ0dY1qhD2a/lLz8djjn1TRuQ2UaEo3M3NSQ3
# DATA nxrwArG95PDf7reoA25ErtGtIllw1HfloejkUVI1qkD7lBBfHd6bVZ2+rz4Fqqiasbm8z3RQLpQ4K/r2zxn7gwGoadeCtf6vR+BN
# DATA JZHciLyaHWMuQQfqpGCAK/kxxxzY3pTdkUHKEtYXk4aGKoN31GJHLRdYUK2DitUgz69uexIliNDbHZ8/mcl3NR4j15owxiUW3avF
# DATA Tk4/34+vJ47CGeuh9FV4fcCQ8WSFfHLnoHgz3ZqH+ou5DI/b9Qeb4u6OWoXVzY1317cf1B3wDXtzVx3Xcdrv9hltv+EoQQ/8cpDP
# DATA OxyzVSaQMprWVlbyq7RtcprLTAgKt0fqZRS/pSFcPuXcmYdRSh/JuJ6zKaNzmjUU0/FJjfKS5RQzE6s405fwZ07ZGt5YWZU11hJa
# DATA ANPSuU+FQi4et9WDYmpcLdfoIaVk3yF7LcgSSNgmhRs/g0EoKeQ2vbMOeo8sYk4e5PqoYq/TNChX44wsGVzJBK4gsBQF8IlabnkO
# DATA SH0xq/c9sK8QtEMM1M/Np8HBeveyyUJmmYop+9uVL2ZoxZpHpx4XvzhFNPE0YZQ6GdBFOxG7QZcZG72AA4kSBi9vJFXmKHmknG8C
# DATA rQ6OjTrd58ofiTFVsTU7cm9mSIaJ6puN6Asz6aL4mqEEmuqVRQR0id2cTqfy6Dc4ZTWR9ksxxqp824ZGSgPj0BJxTmnc9ppy5XJF
# DATA opdEADN9/pOietFuhxVNJty99HqX1RhxAD6EHQV5ZZUxlRZaXjddQylblBl1nLaWJebUWqG81Y5jdhyVBMFggXjh6YjvMNPiO+pz
# DATA EE+wI40DsVgGnU1bqZMz/JMTMbUJj5xcfhnFWRfWdc2W2bbY5moFd+TbFTL+OzBdmUW3Ifo7dENByHFs8EjTiXXE8C/WPMAzigiD
# DATA +Ku49+Mo+Mvg9q1bN2/P4o1e33jfkIW0Uyp4cvRAEd0vjMMfesLAawUjNKDcvLFXyf5e/AtKuJKlr4NYksqDBGKSctisWQ6b5jI5
# DATA Dpr24UUZ04iuZT6w1Yc7u62dh3d3VrfXtzBEaLv+cKfOYwN1CFUtGMfeQFn0LhcOQ3ZPJwTGjGfnuCRLZreLF7VULB8l0zv/yZpp
# DATA cqgWaRn9uei8dpUsGztDTGggTfMCkznR1u5ES4VhoncDxosyhosuJDrUjr19XZ8/Cn69XBR1vltmSoBcytwkETm4Mw3ZkWaDO9B0
# DATA ICjtnWCFQeVE0pgyEnFH3qiv8kb+64frOsLJnxEstUuQijjHsidcnyTLEcdlNJ60mFO0mC3EybhaIvbSJVLlubaIdDkxodx2t8pZ
# DATA 8uUkQ2vwijSNRDfKvu26Qsn5eEgT8T7VhkvmAV5Pplz2vMdLvbb5wYYg27V66+79zdXv19fEbAk+DaIm1gre32D4xC+OVcafmVL/
# DATA npabMoViknShk8LJo8l9z1M0MwEdMXFdmNlYMT392kx+bChL8ODJ25Yel9yhqG4a+dv4eLhIxru02n15D+lexoNC61++LE55rFF/
# DATA RBao7N2dYxO/CpvMxW0sM1tzsmwyryjl35twklC+zjgSqyg+9E/v4JXFCIaRsRxxBNHF9Ouw34f2AjKHV+b+5C0WPnvM1VnCrt62
# DATA dUHb2tVYwqzj/8otN8mj9/r1wtPQNeRInOdppxOyzKRQoy8M4FowzR6UPxXkxS1HF9CKZ9p5XnmSLK9L37SsjqZL32zWl9mtOpcx
# DATA NuRWuSdT1mUoj5MBAUn1t2XtsX/LMh9x5coshPXkfz3N1DXThKcYyAww9EuYfi5mBJFp+LgVJ19wZlK7q7BuXDTh3WvLSIZl5JvO
# DATA BpjK6MxkgERXJ2NbP+YI+jpyLQWDkkqlos9w8ID0bXB1bAW3uaKOnjOcpn2a7+SNBKEMlIaPHDpr5FIxfHJaCyUsRzgddyMn2Aaj
# DATA KvgQFeau6s6Ya+o5oM9Sw9sgKDliZoER2/NQaQ86R8PxdBfEtfXt+irgL6AHRP3B1u6HOgqwJ4PbZ9DEWzYFJdVJQARjMELkR3iz
# DATA ogEpiu1cos+o6QeXUxXhoUhHeZDmC+TY3vyBUSmRpBGcLSNt/WGvdl9q2idbjtStL22gmw9W1hOKNrS65scfJT1wrz+he1IfIn9r
# DATA ooIKoyHLiyevIurk5YrKKFW0BxlLxLCZyVsYeUljd/rxVfcic+UkdoBYub8S1NGq/2B9Z3cnTGxFUt0wq0lXvRD7s/QuvQNr+Ekq
# DATA N/1VV3REyDhinhi0x52j3qOIb7ZcFzqNBsNBJ7ojs7sb6rQ3g5MBhv1HusUe5DxpDziKIAJTAKU92R/DttcuqtxemkpGdWxGB2Gj
# DATA 6lw6mgRbyA7xd54A2zOBDzzVXBQXysVZwHNCTtq8vMKfWK5Munz20EsEJtUafmTMhH65cyReLOB7xQwEaysRmSjCR4fo66jf7kRe
# DATA kOra0WQyqs5rmPLqzQUK1PIVhmWW26Ay1iC3Ph1S0r5aMvttwak8taNPjdi6KvgFCZqPy+BVOIootFCIqag+qQYNy5lBNVV0FO/h
# DATA CFFtRPmDcHHp7cqC+L/F6lN4eoYBHq6mnpgOvPHUgTogcas8HvbTnCPcmoaHhxSW+zTsjnuY65dMbGWpAxqOpP7waXjcflIGwzEU
# DATA Wlw4Jh3kkzKPN7wZnrkNUMRk5yjqfIQ1TMTcwVDD1QdrKF0KqkOeiv89iAAH4Bqvu54MmIV5NBUKWXme6rxWrAjuMyiMa38pg6Ux
# DATA 3+i4MvzonYXqYrFY6SCsQKHolBA/cdy/qFBINND1W8jkOSxXPxC8DbiUeLC4RKGU40lrFI17Q/ADC5cWYjHktMMVZrwhF0tc46bC
# DATA UsDVjj7a9tWnMkQ74QJDy5JcZ4rt1l3j48DtGz+Wrv4MIKDyUltqE7KeWm88VW+IXpypt6BLkPsFFkt7y/EQuALdNVe2SFPWWhtJ
# DATA RwVJMftiUVPFxAAN87CMm7KYAD2sLgnpZNQbRGEOfiDZCk7Mvc21+t2H96DwsZi5HlzZJp1RbSHECZSsIPz2QvXbyOuWl29Wxf+M
# DATA j/Mn3RESsAzl8rEaPUPozFT1hVRVx0MlTpYhfrM6D//Vz2hSqvOsArbcrmm6ZBdoknRNkiLMevDZ2TR2THJUWcpR4p7gavZfjd+Y
# DATA w7hsx9gqooAUkkTioAu47uvJdfEMr2hhLdCHs0vgy6S6spnKtEw9aKrKP4fytDtdmSDvZbZa06uDym0OO3NDcggS08ZCY5hiTApe
# DATA 5UN+HCMajsxGW1kZH57Abt3CXwoSsw10Ba2WWL1Wq2i8WRH03WrzK4VQhWYDzRJccK0RKlV6WeMXE7oI+qWHhEEz4fsOKzG06eVk
# DATA HCmWXD4Z9/kXvgiUAVEbDy+QqNSxrRwB8ZYi6IVxD/ASWeZoS2ReJ3FUBr6jv1FNJBa5wfryFPSBDTQzZqZcBvIVpSF8tLaF2i/p
# DATA uWEIlqZ3uO35EqIwj5B3qZlirSmy50OPWI61d2znz6SqnmCdbFChwZHtxEQp8A8QJFDtMwuJ69Gaj2XxHygda6gkTG1vowB4KcWF
# DATA R0B3q+7J8SgueJGxsV5SbuBHA4gbv5t8MhrEgrxa7bjT6zE2Movx/aweRqGl80V7OxYm/ZpYAfRh0s/JoxSjfi/pnmPCpZr2q1rg
# DATA 9KBkK7rAiRCVVm5/imot1KuO8U5PvUQ4nzbFfFXAz8o4Ry+levt5BjVlLXBbZ1CHRK5Svb3Igrs8I6M9F3XYnSVD1UbzzXqRC/TK
# DATA YFsZHTKAbt2+wMOLN6w5pIm84XedzjkL/M0gzMx+SO7ujl6qrWdr1dg0qH91u2I44SotljGRoOwI8arqoX+Wz6FIqBunAH1DI549
# DATA XHkoGil/WdefWFj0Nuzm3YjZzeoDuOqIvmC1yG56dkY0rSvWiZ9Af1devCndKqbvk6cfRafsQITBWFbImPewLZ5dYO/o4zmJ+JMw
# DATA SSRHoaZTWicaC83sBg0RIO1aaZC7dPi+itXS4pc7VA3Hk7ZOsmbTSC6hobJJToNFCVFXdKyFFqNWC7vUasE+bLW4R7DGce9wcIKI
# DATA gAX42O5Xdtbv7da3H5QC/f29h1tmhnR6Tv8UqIJSwDlErrfETexUq1mSri8ke89d2O+TxIWdU8hPX4dWtBcnKFeGj6LRODroPclw
# DATA /bQxZq38sgqNL1dGR0/3xFU4xlTeLkxxulQjenT+L8H5H17+5Pyz89+efyX++3nw8uOXn4gHz8XXFy//x/lnATx/+Ykodv71+W/O
# DATA vzj/8uUvX/69KAq//1Nw/gX88hxf/vL8RSU4/z+izHNR3YuXn8Dbz89/A/W//NgqF8D/Q8Mvzj89fy5KfvXy59D434kin59/Gaxs
# DATA rZfF069FXdDS8zvQr5++/EeoSDz/VHz+pfj2XPTA6fBz7LCo//x357/Hl7GCinvLJvXtyupqfWen9e7K+n2ekH8XdX0tOvWZ+PcL
# DATA qC3XuLnRP+DLn4vy1GhgVvfyFzgj7+3ubu2U9byUAlH8axzFT0WVX/HnX4jn9NrHosFf+mfvOcxeYE6UMx0vfy4H8Afx9WNRCpbo
# DATA X8XEUTHo7Beq+9acvfx5Ys4w4qT1rpir1gMISrkLtqL191d26zh1/zdl8XCAot+/ha9y2b+CGRAPgfKew3jJwIKDg07gI2OQC7cX
# DATA FkTX/7esVs44fn8uOi5GnOiwtEXqjmNHHRL9+vxXL38u1pZocBayDLB7OGk4mb/nXv0Kx/uZ+Lh4O/h+725qx3RaTE+/0rbOr8SH
# DATA 30E/fyrKvSjhr9j8l0CYL+T35zyNSIDVAFTbcXWe3Q2jJ+3jUR8dAROdQwrlrlnM4n9SC6JXglR/DcRj9wwb+0zM5k+x4Y9FYaxL
# DATA rBu/+iUv15cvfwGU7laANPoHHMkvzn8nqvkcZ6J9MhmavTxLZ8qSDaL3lObQQn44/zdRMyzTc8ElXiQYh2en8GL+DikQduI/ZGxr
# DATA 8fGfg/PfijX5CdL2l7gSX4hSXwnyeXH+a/yF2v4lsDNR1xe4vJLKBFf7uahSdAF+Fb8JovykAofGt/6M/yZ9IUqcvto2FsTf7eVl
# DATA /Ff8Of8uLS0v3pbP+Pnbi0u3vxUsfBMTcAIaLNHkt/7//Lt27dpqNJ5QKG4UsJsPCLOcV1Sbj0lFFz0OtqUtS7pKUaABBu32jvFa
# DATA KJWq8jtVRCox+QyuIfLzMJ7DSBwwivR7+wE/BhldFhmryrRkpp6cqo+CE41ATJ+jClnIlBXSlbRkmYZa9DAuBXgxYF2xkKgHcdwv
# DATA XAf5uoQglxyWedDu9eH6w7yuFooD/TNgNYJl/ATZimQpW3UhTwMDE6zrxcu/Y6YFHI9ZDos1cOYi//0aCooDhiQfSxR6gTxLNPEJ
# DATA VCVKfYEn5PPQRSY35FYx+EIj5JGAJx+MBRL5QWqsGgxJ3HnaowmMZngygYdks1OoxrcMxxHEkSb1emfYzcoi5syQB0m5QhhH0h1Q
# DATA U2Br1O6NC0fDeMJwDvqnEiWPMZcuroXKo478l+SbbLYQb4N3V+8Rxdjgnc+osshaD1GxgZiO1yLrVTvGGtzAOoiXJw64EQFX4fdw
# DATA b7A33lsIp2o6Se5H+QGIhE86KaaJkzlAmQhkMJBKWQoTRziK3S9e/gyIAeS0T/EVQSXJPMMjA0kARpUMAV9cWFoOruM/Uzv8H0na
# DATA 4xOWKVh1Hk5y2XkxtrKU3lAgemFKaOLo/geQ0YIHvbsq1du2uHijL1EQD112BEsf/e0JOJiAezU4oZ7EjFkqUWzBhAA0VFEE0CJC
# DATA F2uMn8APUjylG/7+KejNi2qhracUDsJ8IHxya+E7aNMaDMFTAD6hd0M0QMvEt28vo4sKMgrVrBzVpqhlZ+e+jNeIgy5mLEJMy16M
# DATA MengbTNh3PQ7YpuAtkUs5ODH0XgoUe0pPIPL045VCYv2w+4wiim+3dw2oXQlnDoS2Dvim9589liy0UV8f0lO6SUjELx+A2wRqMgR
# DATA cX8NewFoiy5Gz7OdH6+ifsUHYB5wl3vOioLFhfScoUnB+k2Gvdpmk6tcq8uv0wxrZV8l4ToBgjJd1+DG+CmcUsaMCm4gnjzHm8Tz
# DATA hIifg1N+I73ghEIkS8R9IgEQH8CuZskP/J2OyB9LO9GbAayTDMOPg/3h5CjY3lnBDVtfXdtZuSMOKE6RcgxOdvjr8bB70u8hZorB
# DATA rkYn+/1eBxBtE0QgfhJszKIHH79hZuapaSRfFz9Jehq1IdUFWVHjuCrrlPxSu+wanXuj5jSSuSv/PXGl1+cGHAdiGb4Wss8nKOx8
# DATA IlVMqPfyCT0vfyo9GcHq6Z0ovVvQQN0lY7szV5VuBIJMIZHKRtRVwWKwyK3JsBWLgoNuXMAGZXKoGiWHWmxC6kFJGJXB8HFB0kbl
# DATA ZNIpVuCb6MXxqDCFd6G890WA6qvPaRb4puwT/ODK+49w6f2KtITPX/493uzFtd/OguM5A1UYxuh0usBlGJDSZC99rF5MjOPljMAi
# DATA JDEknLCI+RDqiBUejlE4N4LP+f+iqUOR6dfYqdiRvZCjKNnLELKUxkRM8MeChr9E5cLnYaLrHq9anx+t8ULCkxbmDOi6EEKOpM6R
# DATA OHEqo+iYzDC9R5CwEb6ygNLv6nxEphcF1mIYISgPoWx1Hn62oDdmylN7/v9QZ/QZHq6fWYIeCIC2PGuKhO6citd/j5cbNasoJxry
# DATA rBigRMgeWfIZ9ToZd+uxPtj4cCBAign6sdjzOEnEGZwxtyfD416H23InTtVjmRTYipC/WTE0N3Aza5UMxDqsK06JOxvJUDDOYmST
# DATA XnowZmLYI2ecbhyXXRhde2R5mQxHJr4kVDlIisMXdLFPQG04gj1ew/g1cj5HGNqD3pNaWJn043LoWU2Eyx3GlYMucP6C2Uj4eD9E
# DATA +4xg6VH72M2aBM/Y/pcYmFHioH8SHzmBdNBefDroFGQZMYbBsGDEQw9j5dVOi45h4rQvIdavbwwBuRtKjKlrxTxawabFheNocjTs
# DATA lhhJwEFgM1NUUwErPktmojZuhPAkeSm8ffPby56fgZ8F/y1YGC68/XYWj13b2DH7XBW8QBzlv1U2A+PqB9x0fWNdMY4AVe3S5IBs
# DATA 4ba4UzmYU6YqqUJYJeyxpyGlJIaW+SqxDjjpB4eFsNEdxM29QXgDh2k4Ocj1ivqYkRiSICjvT/GOcnWLxse9CQWvF57CL61Of3jS
# DATA Pei3wTI+6pHxOMSQe1o3MuarQpzwhd497AzpNX5LLV3KqzIFAPWTEg64nYiOOcmNp3MgBhqJCMzRGNUqechoCSQ/VdpItvwIvTrE
# DATA jAKL4y9j/qLyN1AlFUrYPiUc6vxfgDiU/ZOoSBwXL39GAvyXaC/F8+dXbEf4ii90ggbLSn32nAyCUCR0kMFMuDc5Vga4yS1S/CuS
# DATA 9GfnvxONgeHnY23H+ikeeMZmsNpndneRIByL7VJtEORa+dGwNygchE8/OgMz9CPwcyePjpI1/TK7QwVh9TD3KvMa8Nk2pDakoFIg
# DATA 2U4OQdCnhLOpGIxJtg8htmKEUBqJIcehAQ1YubFXbt74nn5SMcEDm0+XSpA4EmubLr6kqWxp02iefiQ4A7oJhxxiQL0Nb+C/N0KM
# DATA JkCqlwMx04TiavdjjQ5pn7m68kRx+XH+UXs83+/t61Sw8+LxvCUXphUyZEWZJ0ZxUWr6hlypGxhCEd4Qr90Ik5EUdiCWkXfG1XYY
# DATA YxM1x6SOzq89cVytghs1ZCk3gIsRdWO1xbzdLU9NnGP4Apl3DTPMRHqX0x6B29xYpnoRGwFr1ynaPCSs82i0O8dRuUHE22woxEsA
# DATA 2+EKp/Mah2gF10HPgd/DPfETZHa/t5gd94nEAupsMkJba7SxRKZGe4bNpHggGnF/g1fUF8HK6oO6UvfGaDsWh9ko6ogLIiSyR53J
# DATA k6izg0lN/vZkCG6CAehMuugy2JmQbiY+ivp9+TvpT4Qg2B7RKYYD0VGGe3tAQ3viLzRiD6/Rw2vms7fg2VtvcQ8N+qDkRNxh/jcs
# DATA zktauBHKMDw7QWbYeDjoTYSssWYEFGxHtiFt9/6OeUfeG6wcCFmmxjFT5SGIiBE7qgUccMyt7Q0+aMNp4S2LvMnqDEe2iP7sgj++
# DATA EJLio6Eo9/BBO/6otiCku72Bmv3aNcHoaE5vhNf2QEnEB9Xt5eULTBBunlzTIyfGmBSxr8SktfswpsYu1CTe2hystoUc3m2Pa9fL
# DATA 4v+ChZulxVvVhYUq8Clr6NuCsMS5+eOouxb126c7Uad28zaU2gKlfAyXgdpEnLFY/zpZNps0u1H37mkNOx+riXXmwhNhcqHgklxx
# DATA JRKNgQJCRqjSM+UMBRWAYQyAEELqvcmRinYcS0nWcPlsGBERplZafGW9oeUSSqc6xoNQpi8r2iJmsD0VfAUfcdBmroNRMpjihrLG
# DATA JX+UMi2HH9ZkZt1kSYvzn4xxUty3QGk18kdoOF6dasINb2BX29WuSOtyu2Lpu9oV1Hi17Vho6JPpSprw+h2dWr7HUlU3vRnT43u2
# DATA Ng0SMpo2bqDtihQGRc18C21XTBHaX7ET4EmCpjkSFjXN+i88DCLvqpWYFeZNHdriI52EPn9bhmM0oI3JU7hCwITJu2IKyfC+syXR
# DATA N4PvR9EILZUSASiQRzHeuCGn86DTPwG06wA8M/aHkzAO+hDPzxeSuJLMkt0IJ30Zi8nbsmpMprWbKWaSB2UawytaKCjylrfKwr40
# DATA y9jpEukg4GmyYBz9yiYSdI0kvJN+7MnnzfIL+CkR5JkxEpRdrF+hzz6UJK/MQuaFr1/+jK6PL/+ZHDPwgonGebhgipPZSQFD3tyi
# DATA yYbVmWbxjvkT9KSZwxt7ipO030sZju6Ew7KlGLmQEzNY339EkB+YwJNVZCSSiZcf9eC6YvADnXJOYnhEQX94WHE838PzfzMcW8SM
# DATA VsUFynAPRFA7nXsychOjs243NF1i2O8PXWzWN9ZL2qFC/D+b2yHwFQZSM1JppfsuLv55e/qluL8dPG4dnrTH3VfoBZjt/7e4dOv2
# DATA ku3/t7hwc3Hhtf/fN+T/txuBbbs97vUBMiEGQwvkjWQkn4fvfiCkWMymysdRifTvvQElHQVLxJgSDJ9muQAedAaT/gz+fvHRyaSn
# DATA XqCwk9k8APk7oP9IBRc67FCg1BS/OXL783vHicPfcZRbvpXtdRENHtWeXr8+jCscICjO1/urrZX76Hm+aih8p/rZbZNHo3GOgY/Y
# DATA b8iq+fJjuG3rQIIX0uaGUQ3iv/8ED8UrYlnvBB5+eiCErseA9HT+KfjIoFv+T1/+MpzqwyfmrGUchzIfhATxO+qhmdKY5C203Vj4
# DATA VDZWLluv4c3K47Zg0HKyby0v5IGkpDcnoKweQI+K6ZD8nkYWFxJA9Ubnd6lU/cnIxnvTlX3U6/ddKEbdSpY5zTak0S1TK5ikHSdV
# DATA O52kj2z9NJhi0fr6CerQgRy+VHE2gky0hfsSljxxzHgteWBUI/O3WT+OOJ+178/L2DeO9ofDSUuy04KYthKryDoTcT0Sm0xINENI
# DATA /15jlUtC9VuGuZY1gAR0MuhNaqkKmsSLiLCqVVma8qjdK6G9Lyw/jJwUyO3ncq84bo8/Qs06vUTgKYQ5EbLmcRfx5sR0l9HB60fD
# DATA fbHBxaAB3W40fCxe6g/jGKav3/sokopKcRebjNuDuAfHHl4sXc2jmMXLqx2ZE8DSldJUZLhQuAmd01t0Q8ya1CFCf5Sq0MrZDpke
# DATA uj3Kyjk5qqMfRU0myKAZLFJao71Bqt7QrtHUHAIsG8+KqORawDlTxVnY3u9HhpZxaxhPavMn8Xh+vzeYHx8H5YMg0Q2rmTQVHQIr
# DATA lU/gAmSo6QxtJXrEGxsqpBTaguzhqi9VYolS1OWQ9lIF81xb60S9hMQLKDTJVqU/Dx9lFCtbZeKcwgpQKI+68oAsBRT7K7rGYQiR
# DATA mD5xD+dvj496naMayUwV/FKSUpmZOEq8Tth8mH2IpCE+SrE28aP8BDCG9plOSLsHj0UhbKEQii+2mUE8SJzgXKF91LNDc43mGvmc
# DATA BJxpJv3x8IcKuvLFcBxQKo+TGPJK05RbFoqMdrmfGTV66vPxtv/wiVTs+PQ1B/X+hn2kBE+7I6VnI6rtDxRSe/4Vz6G0hajp5Qdl
# DATA MUdWEUGUbiHxyF4JWRlrSFSpKcPiQEGHa0tH6U9xWCRaqofguOnG59JcKMeP5EC6vbg9Pm4B/wUPCiZVJDr7DCz6DkEGfRabMUBN
# DATA m+fo86J/MutfETxG1i9TiYFsATo3UGFIIbgSrAQgxwkOJnFGx4Bbin68oKroBz12wDdYRtcFje0M+33GKSqX8TTGvhFvL5cF+yGa
# DATA qyGyomZ04jc8YSAxx0hQz2ltpdM5Gbc7aLtYBG0ZbRydjVpyqmbRm3xC7jTjBVgI441p+ych2xgaTeysuPcdi/l6fBQNGK6dg8fa
# DATA vb6hufR3xu69aVLN4BI5d3Eayetti27h7IX8E7F5X0AU6ac2bZ9/dicg/yT0af5cWmBTRRjkB/yDfPg1VAFmUnCKRg9IC85V7YxC
# DATA 0Z4v80hiCC7cAwD0pmw6rxzqLCegl/ddpqUQ7hDigl1TPdquA1D0Wn07F4YWV0NDiiv8tbFYbSpIJ/msutgEtSvg1IdN0iOav5ss
# DATA U9bKLJOCxbiahaZjNp8m+mqnt+fnv0IHd6CipGX8C6XlLybc+MJ5seyOgA4+BJX+sPNR4l4GjvCIBDLgG6T4ttla3a6v7AbP6Mv2
# DATA 2gfb8vPG5rub9+9vfmBJKoR/L8TG8ckIEGUkzMfBGG4vjmMros07GCLrG7smhEg2pEgSVkQC6es3Wuv3Nlyl7fej0/2hEI/WZU8L
# DATA xWxkk5l65Qc6MWaFDd/Tr6WwTMacgQJM3DbFwwL8p8RPAJ+kVf9BhmY6IQtqXK/LWxgSk5mBuRIqIQYFHPE/DGe9k87/vkZQgZc/
# DATA w4gb4pV+bVRomz3M7WQYPmazZ2RgxvhNDmaryuhg2i4wmPcfUa3281QdmmeAUqII/9hsDJTqpdw+BFfEV2QCyNT/Ly7cur1809X/
# DATA v73wOv7/G/l78w118YYM1KPTydFwcHPu2rVr9zl1N+TSISqRTmoV2Cec6pvSeGOOAERVg8wA4+HJ4RFKhEpqzm0YOGrHYBBQX4/b
# DATA HbIUAH4K6jHgyKEfQe8LACfbEBMcT94TrLF/FfACQoRUn8HVakLNphsfgGdY1gZs7GTcF21VxtQ72SZ3tgQ/w8ExpzpAvMdoRTs8
# DATA IMSv9xdGDZ+j7NRoUGd7fQtd/YUkZ2QZmFu9vw43JlxzzM1OKhcpYYRzq5sbu0IQq28DZNXu9uZ9LG6LIaBMHQ/74dxOffv99dW6
# DATA fQdjrDekGKVGnHu4sb7b2t7c3NWyjc9ZbG7r4TYkwYBUnil1lh8tipZ3V+7VdzBECrUYnB+lO3w8QEUORkpRmkZGc6W8ESEnxzzl
# DATA F8CZozcQS8nYr70D+UtHkPNAvFCce7Dyg9b9zXutux/uYpNG2LxS21ISpvHwUMx1zPllxnKlBUEBFCHiwZeC6JEOjxG7YgvCJ+Oj
# DATA YB9MbGIfiXkYUZm4xPkxpFwqxegYr8ntxwGToYwEhz1G9zeiuBooNVs9yJmID1gZRVduO0WFlYkUPVxg+yjgaV7xeVabGAn5WDvD
# DATA LhyiPZnFWnZC6h90oTSFjVHfYSQDoXmhIYs9zIlOi8NZqGjVCY4drphRN6m5eYh0k8yPc2+7vrNji93OgCnLiFxXVCnIcTlZKwdD
# DATA UIthBCj8p+C5f8tqrBnWVgOWfABAfGM4eRfIwYkmMyp4GuIsoX8O5abAf1GdGnVXACpb9Ahu1EhJAEiOWOMM5RIbiOxinzzqDVEX
# DATA JxtocO1NhV4ALwlmIbZUhIlcgAcJQo2lNgTw98irSRAsmA+1LxRsvMdCvowVUgGtaQUMyE8K2BJE0FpPZaeKydE3jFE0G7IguD4d
# DATA t58UFkq4FGV3LHpmmsVElRXiLNSXGs+o/VpN1Mqp4GEb4xqCUxqEKOw9WVgo7z1ZPNh78vaB+PCdgyYnHcOyRXEHXVpoztmD4IWB
# DATA fhc8T28EjadhW68j1gRo9MREqKD4jv+eNYuN8tJy1W2D8/jBoEUzoqI5X+47zArI7/h8WqkWl7uRf1fVYThJXmA7xmO5hKbWnyzV
# DATA u1+mb1CH5xkb1b5hqDuF6WElvamK6X3073QkW/HcoWJnPyntxagfcbSVnrDREaKNs/cnFwl5guGUpxTXqiM2601y1YSVG0D7wTc8
# DATA k8XzISuGJpqL3dyrqCOQ2w8Oaa7S2pSu/x5AnhJTF5xbv423dfmY5q2B81ZtehMd6ilAd5QCb/f45LigKm1ghc3MugVzKEzlEcVk
# DATA sk50zlCdqAULVa/Lh7tWnEurjyZFsLwon7luLx7126dBGyPq2pDiILi2EDDYwLWK63+QTbKGV2AiGawQVQ1S1odHgkDlQbIOcwWZ
# DATA j5CsbwSL8odVMfXAd/rRoEDz6kuEgaS7M8HEFFZZTv3G5I8XbGzCTYwUjTvE3xYXFjzvEAFQ565jmXmzFbdLsXEsGltGP6YsFpJZ
# DATA Vv0s1Kk06rdHMWQKwdUSL1lUWTDaORDkEB9RQyQPPQYi9PYEj69iYgQQEX4MHdmW1GW0Kx+Zx33ySDkT7LzTF6RgyUOGk6VUFgti
# DATA IcYvET76w0Nm+uzpwGcuZB2FZD+enJaSq2DmiGRWxbzRlesDdLxXCF6iOl1LjnRmsyUwYxnQzNqiwu8Pun716gfbmxv3P5Q6VUvZ
# DATA Wv/B6v1MZWsCoUCJYsAnk3kmqy5jVeUhKBc6D7cEK/rMXSq9eBWCK5Jhl+qxlaKT/H71LxQ87gEckGWsFLRpqAhiRjp9SAJ80HX9
# DATA oAwupVWrB12O60/SZQupu0AXIL5bQZzHRAeB8uWIpJ1C2AAZgTLTTcYHeIKHb31Yfuu4/FZ39633qm89qL618zchufZVDo/pjEcx
# DATA ooleCXQPgaRT8I2aIi+JUEXUhieTg/K3IRoVRh7XQnbzkDII90l6HiWHxWhMTGmRsT9toslFlStbW/WNNZcUUx2s1HSDRpV6WnUd
# DATA 4FPmP2QkZ7INSXhupZyGdFTKs4N+LOatWdzAIUwSEPfgypRNYQYTo8xtEt0qwcrktkidYpycVE7IDPCbnSneIPCTxWeZX2VPjSnO
# DATA 0gxJpYkxOnR30xafK+Ls1j0cNCoPN1beF9Owcvd+PUxlwbIvyaWZZvraXjN3gaR7/X0DoeHzORqOJawIBj3Zq3wseABDIKHfIGBm
# DATA UDmP36DjhFLZaa3vbNfvFWQlEmsjNYolxyzqG8DJoNOmi4ZZP0N9WIot2yhHvY+j6CMp0CTeL9vvO0ME9VRN1gO3jYJd2kOjqQac
# DATA 7BFTMDC+qDAc5LjNmqA/4r9gTJ6g01thH3l2Y4kuLKpEowrFxkJq63IREICpELh+cz0MHpbO6jN6Ew26fJOBSYZ8rYVxWIY/YNSA
# DATA aBA0rzO2e/D9+of4U0ie53qe96PD3mCQUtHd+r31jdxVAXoB9QmOfAT00LWD8g1/JE8LIRd8V/8qnzn0yhMVNrbrayuru/W1wOhD
# DATA E89gUaLB9QK2U5HVF+L6I3hUrDGtrD3Pv0pAqOQ91jJo0e21QelA5PV7VgWAuj6Z2YtrwVPZIuW+LCnOyJlN5VdPxjoWcyiZn8FT
# DATA 5SN56QetMjSFKQjlj5XD/nC/EF6XSo1G9fYy6IuwkCrlbTkWEkri7ZtLGjqMmgTxkxvP0CYgiIutSsB3EqzOMLPiO3TlMcR4PNY9
# DATA /M6Yb3AjIbMGVtEwXm8Wi1d+UT6wctMb0ngvypoS74HkSzl8oePpMkdU2qmTel5lHEOMzzHpDU6iOU+gi5EEOp3/52Sf5u2I0FKR
# DATA NivAnOFeJLjdD/fi64V3qtETMI7txTeK7xQYEqbVNNBjmteLomANCleuF//CzvsMxprKg2LVr/PRnJW4zzOgk8eC1J8hX3nGUt4z
# DATA HRj5DDCW3vkoOn0GRyYoySBm+Vnc7k+edWOEDoDBNBab2PJ6yizLLUaFl5qGxxsmud67theGRe+rouOgEMEaisFf1oLlamqAksNT
# DATA 6R13TyUEycSGoWoQRWQI2ozCU+o/oj/hJ/iJubuHLxAbwAPI6foZYkbW+pDfnpFe6EZv7EU6b+Af5VNPbZWMQ6gpY1D4GJcq/MI7
# DATA veNioX0yORJb/MeoShSE0qjWmkRc+4IAovEzsZC9ThFobG8HMGnG4d6iUbd5qLothNyGqKxxTfCsd/b2LeIUz3fqq9v13WdbKzs7
# DATA H2xurz3DrCnP+NhsvSPOzWeiwFp9Y3d95f6zla11erbycPe9ze31v1mB7EJFt1JuTA2m2Pjh3nhv0LwRhrMNYLpQ0diL93aa198R
# DATA rU4TZZ79RTEspQoHWd3Y249O/8oYpAkBlfZ9P7RpIKv+AsDyiNeb/K+o40al3LxenZ+HqYvnv1dt3qjSp+aN7yXm8HvZvX+yuL/X
# DATA aCyU32lebwTlefHf75X/u7QWJd6TkF6do/a43YEAawTmUd/EfsKSoCA1H0J8xCQEuU0wKf02bqabSwH5OFo/vFELFpfezhJZlUC3
# DATA xtfFgFNfxhT13Y4nhOReCXaPIqWwtVR3pKkEzxHCake3igrA8LE8aGup5c1PXIXlR0qAOyHdMLwBkCOys/BIfj7jy20fEHsnLeWI
# DATA 0mI/lYK2wG+TETw4PpmA93FwH19BDPoS9HMg2NEEOwzeE+QkIL62JwQ8H0zah4bpfTSMe3xV1tGeJPJs1x9srKxC5qbt+tbmzvru
# DATA 5vaHlF53MjluD+YV6k1Zdde1n6Viowk6n3e+A22q7uQzim/X79dXduoq2lOa9dhppaAVT6HMZyROusqhkEpO9sGldh5bnH+qGz6b
# DATA l55B87QW7yi3jha6btSeul76Z4YTPOGUxbWn4UoHziFQi4ADBwSkAD7qo0GXm7+BEm0JEqCLesurbCCsgkBe7sCz0BOjGz4UVFhe
# DATA OeT00noJzHtEeEZvGo6f7L1TUE4eRsoMEMLGUTwaDuIocQPl5yQTLd26zZ4kcMVUaw3HnygOVnFd4kILiDNvo5lAxSZRGcewSlEL
# DATA qJcXoRixFXCMWA2jerQPUamlKbngtCpK8NHPviIOmT/a6wqeLv8DfLJ96ERrju02u+P2AdhaejHWhxkqE4VG4kSXGZ6tkhcZOOd1
# DATA gLGAF7oV9sXPmCHJkiTeVFNWwhSI/LNiTYo4cvHf4jtiesyapwzi/fr2jpAalPJtjPfuyYlg3YXj9ggQVbk+CXoOCbE0StLgtAAv
# DATA AZ0uLr+9/O2bt5ffJksGPBUnEVZ5kb7w3FGXbgSFhVJR7IPCclDG3UH16rBZy52mmmmx8V+7vD7dqAkfpwAKs8aPA4RxOwN27i1r
# DATA FyOutETVzTUNO7uQz4+piuV/Y/daiPx+osm/ec22eMKxDp5W9qSYiVJBKY38/OHD9TV+FcUL/JhzZ/31w/rObnq/YvFoZLqhtGTE
# DATA /LE4deQ3zhWroICrU7zf2AHC4wQ2Z+Bui++2iUyMOUv3lF8h/nBjZ+XdemtrZfe90OpRPrumLJywaia9+vScKUrSk2VAs9Iz1B67
# DATA aFi6fDoglkEkqqoSqqlcS6bRkPrcWGg6Sj8KFkWznJllW71RJL6+srXVoqsUitU+jC/wdK4FNBKGzzL1SUpRY43NCKEAPYStcv2h
# DATA brUGV4gDQPh8env5TGoaWMOQHJJUBCBMLuUBMgBkmY1QadC73lzKJKIH6zs76xv35ATwqQxaCsB8PW53KoPoMVen4H9LAXvdlqT7
# DATA dSU+agvJA6Wxbu8QRL+ix3csne5LQnwnpWuVmj9zULxlRUBTBXPjFhN5DHiFDKkvNhEE2cVYIYM3JOAguAdiqLZeOXBeQdQxdmQX
# DATA nIQxAQvho2H/5DgCR+CG5SKovCMb+DqpovATJG+iGnsHXuVKwdgCWJKZM+VxggdSRkLQRHT9SjhgA4vJW7tSoCTduGVn5UFeDYtC
# DATA KllqFpuGpkdtQ7F6pyO4eIX7vYEJ8UiAcMxsihrwsZpskt2rWxAnIH4HVnU25/NeML0M4KhoyI40fdGbFr1zU60Hmw83dqHhd++v
# DATA r+56kqFx9Y7hDldP6r1kqz5Kt48WiQhsNCCnBPXuppe0yk+Rloc85UXYQezTVyW5FHza0UVQrEqvi3AE7GRZRXPurHmfeOk477as
# DATA JAhRE8tfz5KArwC4G3VbfJAaueSlPbqYimrBAduFKZivoCQQV3wgbEj5GxSIv6DeQLp1SnQLFwvXAaRIAt7GPVBMmBi3KgCGg1+C
# DATA 8l00vRtDo+gK37jQEYQiYvElc3bgJ9RxJDoF4B3Q9HBQZs+EvQE/Q1haG443P9aFj3R15MV8wAEbJQ4+d5c2kTpSYwskoTJKhB9h
# DATA iCDZrysMjbBcHgwfiw/cm5lrGtNMpdYgLwUIkCIkWNDJT05ZYDQkF0MDBAC4gHnWB451qvKeCl6Ih9odSXcQ09nuBhPAjqFjNWqL
# DATA IxunW+mAUkVMlXgg/eDMSENgiZpSNr2UgCmxNaktD6PScRlaejTBXjMFM/mMZ1ycA5EpN2aJa9yxm0vBd2u2AFQLlhe+c1thlh9p
# DATA mwLrRgnHeG+MEDuoDwL3/LBZ/COSm2TKhqSMpHw0USNVVTHZrVZP7NhWS3Shf0C2ZTNiWTyspJOdKqKvOPoN856jmkORC9tKOsIb
# DATA 9wizTvfcMyprP4q43wnVhDUtWfXxu058gg5ZJ31pN9lnNGjX3F67FndOy+54u/dkaBdDz4IQAF7aFOHEhv9A2c2plGCtsjd++AmL
# DATA 8DY2d1vrG+Iifh+8wXTTUk1ENTdC/u6B6UiU0NMCDl1MMFJNCW4A5n14eryYwp0DZ3pfxil5wcSJJcpJ+ABkxohdgaeTtA8Eclmk
# DATA /tYN2RJTEmaAEif1GyMOBkpRxIXqsre0DOlHoHg+1y2/usOd1NTdVgihKRwfLo0b5uKffJ6KV70ATseyV4Hp2HJDVJvU8EXUdI2+
# DATA LMmtroE8ncjZSh8TRxjVFi2/a0iIQ44FUIXjyOQ6ecAfgMXlWxuouiHEdQzp8q8Qr5Ko044DwjBHMWcnEV7AZMAjXfCM+KOgrN81
# DATA AwkWQPH49tJCSpwKvMNxb9hiTcZPsi9GTVDobn17++HWrsWZVJdxZKIWgh0XElRV9QOQws3EAibhiaGYSQ14uOregfawQ1DNhA7A
# DATA +PQASX/XVMCUZVwccXAKrfmZcVwlw6uZiXaO2oMk90SdMRIAInuQCQEUxu0OYeJ4OYz8EXWmBuNMC+bKkuu21sBB4O7DnQ8T/p+n
# DATA vkAq8h5ODrMCiJdHQnzr/TgydyCNu+hbDF8ta/hPmktn+kAMV2fy6SQfZXPTt8jZkJaDOLOiJXXIzXqy6VBVFVws7xcSZcm4cgiZ
# DATA /XDc7kY5zvZ0Do8Mx8upxNBQCWHOPw1USBTDx61uL0bcMgtqKTEQCCGU/UR2AQ0SaR23B6K6Ltm8kFinjmNr5V699WD93ja6mOBw
# DATA 1rctnpC6B+Bryg6gn14p/bM3ee6Tc/rmMdSBvhjulPic5Nlbyzh7vS9rlokHt/qa7tU1s8jhMAjZ/vSBXeDAsitwTq3vZpxaM61/
# DATA /hNDObK58hcdFBBQR2H2eh2qJusxFreqhW2tr9OzYsYiGnPi6t3sPemJ2Hbya6RSbIoqhbAYM5EKWadWRpg3AAM0AAxNaI5DS8r2
# DATA ayHFewrEUKu2qEL1A6MvPWg/ASUY0AAUcNVz+NJdUP6gUi61PQapg1NFi30llk4hU1Y05vbhQa8bSkYrHoHooM4TS7tkOXr4iK1w
# DATA Qawqi/CmCGbiuri921IRRCwv1ZKhTnN+d091suQU1T0Fx2GZbz7l5tObt8/2uKAvqmsGEk7Z4taAnUATGQwFALW2sACLbMkKFxQQ
# DATA rvxGOBNrvvAh5hzKxeqUC2byGMtzdySjfwLEAPQjzPTSRFDrMbgHOmopGdNWyEmlRbfCVmcccfQTSiTTmSVF5yESig74M/YL5LZh
# DATA N8R8GyJJ3Xa/gKX4WUBDXYOajOokvhc9AklqhCFuGrl3a+b06ZNLwX0bS2iIGkX/te+KRVc1+1p+lXOg+9L0ySFXIvFeSvK98nvE
# DATA pcQ33+GhxLDL8GRyjPJEuKq08QTY2li9v67Hlky/SieuVFUirg34hIbNjNVEfwiumNYyrV7ck6ZyQX1u+k9CRza6Tklf/DLBKTgU
# DATA wAR1e4Oa8eZa/f2Nh/fv4y8gF8j9R/mm1FefCPH24sKCXwbP2Narmw+27td38eS3t3Y+etDQMlKe0JnSZ4yjupiE0zswmaCfnDhA
# DATA nmACpk+RDJcXn6UIciHBCvf75lad97tX4GDOZIB6ND14QDn2mGVtOUnoMzPV6n7sH89FKwVkBHWDtxfcxDWYD6BF2k0eJ6nr7f2T
# DATA BF5P6NxZnLIrsaemjUkNa1OMvb2Y0dHtywp0oal30q2ikTEJwXm8SjdoMUlwgM/TFWJQQLcCDdDTj9qihwBntj8ePo4hOTFrLQB6
# DATA BihgEvVPK35umaYOSb3wp/+Yy8qSLrhZ5OGxxIjpMpa+mulGYu0ihq1n75QcWmTQ5sttUzMItZjdJg4ZrYj26ZTM43QyHnPkIbyj
# DATA zYIzhogW06r16pKvX+ecl2H7kRg8ujlU1UvsWs7ONapL2u2GCyYvsgrXTBRyQdgMGYsm5cw0+3XkvQeSTbmhcmRgvp+gNrIzYyLH
# DATA VqvQGwwiX1AuPsc4UYY7IFdp6Wjt2nAZBxQBy0tJEHILMMcFyYEJveGRW7yiu4uwrfvp4GyL1gqIKQVzQ8KF8fvG3WKmVswrsMs8
# DATA ZNCwELXWN1O0TPb8ZZ5u1jRbVOfpVPJ2w2v5BH0GsK5ScL3lD3DVTc3cY27/Pt4vrQNNaemlr0Py7k2/tNCVv2TcxHUsBTqalFKv
# DATA 5hfXOqeoXaaxV78he5ou19JQXEqfeUFLe1YHUzs3DV3wQgNQjk206uDOI1fbZdj5mgL3iY36B/Vtp6E3g81BpDB1UdD40VAMtN0H
# DATA fhyfHBz0Oj107IK4PhmjCCFaoHWAWWmLC9xRL0ZQm0QougnUZXI8RldQeJQSZqGan4cxsVswXQ1wgTJQLovVMj7h2pupIeCXR/bK
# DATA RvjKeWdIqTdD6a48X+nC5FOkS9dXrW13/VmZ9fjHdCFFfKok8s2o39NU3QmVvN8BppSqhp+qs/9mVPOmVv6PRQWfS8a9SoX8FOcl
# DATA CDi3Cs2khs8k4KtSvht694to3F29ddqJfmm/s1zY5Bk6697gYOjTzHNYaRZcuI5EIgSg3HXERzPqueF304Tg065PIbnilSjOsRes
# DATA PZ9OwlesOG/5bfSGWpOo7LCaUx2HmiatYucpi7rEfFmtjr2xTyV0AwPSrxkz7T+/KUrNzRptgAhsbu5yPI7FRXUJFsT+avOudU6a
# DATA OAQYxNxa33h3s/Wu2OBcH1B2MTWexFNBfWN3+0OzBiRsx4HLWSY602GRdA6HuZnu//b+tHMwGMSnR27mijj/d524h3L7fPry55iX
# DATA 62P4ankwpNyLZErAWgbMRC7FMym3hQAA/SvLsHRHV64qb2JEYQ2iCvOE/EzVWCMts7oaP/vO2u+kqao1yIA2JSL9pJRGz/Suhglo
# DATA EC9QG8SPhKTcoel1f+VgniNF68G192ViGr1MT9XHsyontnkqKzxTIR7iFf7Nv4HP9gbXVAhAej98WaWNgykxoOC7+irkbbc4k6uP
# DATA 3JhwQdqur6x9GM7SlZmuZRe4nlkO9kwFanE0q3yjplfvgo5OJkiDp3VkU4koGxAK1C/TbkYXbv7N4C5plaE9SrGLuPjH7VO4bmHG
# DATA pXYwiAA3fkRZYnSepcrcVO2somee0JqfrqSKRpaSZKCEXawunQ2+Iu78L5oZWznWIKtcFXJ1Qp65z86/fPmLgE5S2WtKB5OP7+ob
# DATA zH5bSFYl4+gyrJgS4NHPjU3j4DfFllPp2d2usIX8yz4TQTM2R+vB+s6Dld3V98LLrDInVoJF/rfzXyWzpf4OM6VCOr1/oBSC4ZRF
# DATA nXpdy2PynCbqOWbXbCHPX3Wqzofa9WQ7STr9ZKciKk6t3s2e4+R/MNLouA6b09PpZPsX+C0DdqIRCIkzcxR5e32WIi5fwLCTqY16
# DATA pUbwNxElja8ehCEDQYQBati7wf4pxZiOhr3BpBJsiUmAQOJgCxUt84NoApdsT62sbIDo1GEJ7zeijaAzHEFeM6Xo7Pbah4NhPOl1
# DATA QIU5GdL50pFp0S9ksk+xx7dMCPv8alBjO0w1fV2YFyXIn3ybuWXC4dCHUq7w+hSe9lUqY5NJy+aukp4TtIyKa1oUDMDf+XBnt/6g
# DATA tbWy+n3ImCI9m8RFcOvhbpg1Um/eVGMPrOLJs2Vvg0GXCMAx0r99K6slnP9pGVuNY0ombOVbr1dhdSH1Hk+cG/DmJEK/mH9ILgkK
# DATA rlNS8X7ci8UkHNrgPwmVUmpplQNm0Huyg/iLBTPHZWX3iFIiHj7oPVkflKwEmBV8CXkVvSrTAyAwQGuCr8amcga0gWDt4R3nuriI
# DATA 02BA0eCloN3t8n6PT0aiVxgJol4set4B9Ba+nRZuJWySnroVfJToewFj7rkvNCWcP7TgTytaNPMOEDs8FnWKaljVmTCvWpuQEAlG
# DATA /VMZSya2QAkxxJy39ofdUxtXAwupG6fHHhENui2JK1iAUmmFCEyxEK4ShGYZADFkRkwJqOhRUnoqsCAWSwixiGgLYd6m70eDw4mU
# DATA uMGYBeN2/U3xdf127Bv9YzRMk4iBdVhTfoSLl0Z/ZmB8NlGZcABaPCPchjzI8z5TNMIKgGjaHkctRgvA3vBoGR/BBCUmiATxn7sI
# DATA SIw3H2yhmG7ZxXMPKW954SYIWNK8Fb67uX13fW2tvhGe5VDxytuFzEYKPpr36rvkbYu/kJoZ8sWSHBFm28N1x5YA04zmjX3h/CGy
# DATA OdqndAQxCD6FcB6U3BTaP5/qZ5vVG6XFhqrJCuvU2bzanh5GqR2V6Iwp/aE3mxLeaT4bF5zwE+F2uPTqIsjS5xSbR/Rz+rRw8Wkk
# DATA guNo3tl7Q6Hkl2zdckemKNgL0b4n8jhnz7Y2dy7btT5yZEVhBhNqQQLHJOduNDNJjOsjbGkV5mnxtt1xexAfRONyHQ43ihVk9Ru/
# DATA LSij0osFc+xNtGpuIfgu3FoKugyqLG2Q3CsjZsb5NBAQafXw3EHYT6cvxUx3DEOEhZolIhzOz4TxQt8AFwjEO8G4eMYl244e9VC9
# DATA cPZNb1kfYWJPL0mcuPnm2x2Kp/zzpMqlW7f/jIgSVsyD4aBDw14FbWpOzfH/0KGG7EuTxGgrVkg+0v1q5if7pQudDalETmLha/L+
# DATA UyBvW437DRG2SdMJ28xV0HG6TG1dDpatywGY7t7dfLix5l4OXqla1OrQd8iDRymAYDuZvqWk71kW51SWGkmP6QK6JHcdjbnoDltC
# DATA HgR4OOuOaf4OPMFfgNQq0jGHlinpNQ+lFCKg8YqC6kMSNp77sQCdl33WTvd3/FqYHrbMmII7m6vfr5tUbtZneYyix42pfJpIBRS5
# DATA 6JSkGoYw17FQ1VutBLq+bTomsKIK/2kdDDFZECZY7YE/PCfXBDpqtUCKabVCmfV4HKMjh9h/+LmyMj48ARjDLfxFZdoCC2lLyECd
# DATA VqtovAn5yVptfqWgXRzReXMLNeAMNIzfxP1sOJrMK5dNabnxVmaetJ2jISAb1wjkGMVD7TTpIBsgTLoMOhVTUZZImFhWhpY0M4ch
# DATA 4yAzC5HyvHgn7fd+ez/qZ/yOZrbsJsAbNL0CVJtm/M7ovRklGJeSO8HBrFwW/4HSUv8Eoap4mEYnPbaxLrjokjvo5lt/Anfx7RPK
# DATA d0NuJbS3FWw15AoBWtFJFURDFTsUVscBzaWZN/AtMm/gRzFh/AlXhz/jSvBnnHWJju5vlyjIxJkE4H23KQ5+ws880/yNZzW7kQR1
# DATA WpBuNoSr23SuBnhH6GoRW1PXVaygw6qctuzKzD2WUaPGn8CH+LXX1WvjQ6UnvbRbVXHuW6//Xv+9/nv99/rv9d/rv9d/r/9e/73+
# DATA e/33+u/13+u/13+X+ftPm4WbtwAoDwA=
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
