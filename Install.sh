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
HELPER_BUNDLE_SHA256='ca546425213f905bf73778bc2a061154928409f66612d25763faa8d67cbd50d1'
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
# DATA wlqz1oBBvTvve3/490H2v1HA/w3u/+6Cdpa3/0EV+YP9/29b//czrBURTH116GIuCW9S/hdLByWTyZI0jqqfjkZUI43pyQ9TvEfw
# DATA vrq/fD2n+hbP59NUfbn8WTJTn/Gim3EyVF+T9HcvDny1XCRjXR84mKOfQn+NJzP7O5cMxvyEk739M7z1oshhVvKeHR+fHZxgckbp
# DATA m+n3/ZODF0d7+69OzwZfHDx/eXByOviy8Q00Ozh6Sm2+78OnwbpWe0f7Xxyf0I3m5KrFE2Lz4Ub500nlz7nl4LNXR0+fHwxOv9gD
# DATA Nrtbsm8BKf1go+I9O3x+cIrpKKX8Bi9xnqeoqvjNdkvkneZFvzlqgn15cclYbPiONmTp9six+pSTJbqlZXsrF75teTkD5fTcFQhn
# DATA 1sjrdcCVp1odI7QUOErwd8c6pglZEprvtFwxSvSExIBzvlumFP4ufjL8qD1WpYr3Yu8ng5O9r7C0fNctokGPcMHhWTP3KHeyLCrj
# DATA Yqu6hliZO4pDgKPsVMSQyBA9V1ecDPlykyoRuC5TJ7eVWJ3Ku7Jta3LElxpgRrW6LFfeF+k9eB2r25Z3vLVF6UpUa0r9p/zpzqZ1
# DATA +gG/n9c2L+yfKh9XPi2pGOm9Zxzk/gJhXgKVLs6E+foDvCEhVtd5SKImhn0WdHVkubSpDtFQ7sUo4SNii+UMNi/WGMfQCkZ4pfQi
# DATA 1iNKMkAH1nPkyjHlBtcpqnj3VR9QZzcNNKp0Z62ku3bWkWHAO2kSPjo2t1/BW38R18M0HZdNp/CrNRNdKhtIhTadoJMlwq5NYPxY
# DATA rSLv0BBTmsrMIyv+j/zGfYvxVN/MJ8sxStNFPDdnlITXYtGRqRNmo69Vae/LeXKZqgyeL3vIbWvxNOLsHWDLD+YYH5rbmYogVAtF
# DATA 4jCZysPznU081YP9XzBI+LyohDKCVcaHdlYRioyne2d7fkkqKNobAx/u7+1/ceDbcoA2iPreat7RXsB+K5XHnKx/NY3fzPjeEGeW
# DATA vlxVZNYD58UiS1fKYSKgzMJ71/qFXMhodAwZK5iGoEC4/IiXc46Xh8/KzIb8T5gfCX0qiB0albdzEFqkXDmvy5KUhxuljcp540Kz
# DATA RSoOpdmdTmi5ZwAQKNBNsZjeIHjrJeDO3TZ+huGq9q4ydZIDVT1lErxJJsvJrmLyhkM+WHAzf7R8Ff9fMLbptANWDMOclOU4mFNN
# DATA B3PG3zp0jtTIA6QzWPcSEF/FDzJsFgcTMxZdgbcrP9MphLLMBPpsOLRDwgG4gjx/BLxU62yRpv4YM21cKsnLOn3dAtfJKM8D65IF
# DATA HB5/gNFbzV53+zG4ko5WxpcZW+fcsGd93DkWMYl74m2JrVi6Q1uETRWr+JswXEnX6rij60rh1XP11sWD++rVNFvOZpSNqnaUgrtU
# DATA +deXsAydmsnFt5e1xVA52q0azUHWBw3JQosuHHervXDHjHWnZI9VeoqeqspTst9wbUnh1qcKuSSKOtop35DG7gczL1fYiipVPDdV
# DATA TqkAfCpnJW2sGIm4euaE6OYFrDH8NLv9S9DwK38pSudfssb5DaicFTk6+ghx6GAXgaKaOSuy1sIiF6vQSESUkdoim0PvAHIu8Q54
# DATA mC6wB1M95kPhVjmzLtyYnFTmjhkWzMnO5NzhQsFV93/oO42QDhTD/kA4sFCe2Q3ZcuIO7+iATACqbgdSmFgJj+BjTFvruChuBUsW
# DATA caV4SSgDtlaVsmRSNtGRg29x9XdYhNHpeV2diU/r6CJndLZcDvC8LTZ75LIxSXtcrdJjnwFyOLzexnfK0pD76sqiJNIk7MpFwr6d
# DATA XnTFX7ZaSFJgnSJXzSD+zC3yCgI1L+JX9/MB1+GCeHIYgh+lXEQN90HJETHCaj7a1QJHY+L+88yr2h5fLL6G9Tg9r7IgffmlLY6p
# DATA NR9ZqazUm5f7LxFyl94t5K60Ka4UtZ7k1dWME7yvFHBnXXS6hvj1dXsrZAPsy5znkKnfQ2SmeLR+qSD5dqUD3ETWK7AJlC+qyhpL
# DATA pWpvUKspjV7JF8eQUogGhjX1z8yRbllJ3KMffywzVzDs4Bh3q8uvzyG6oDvH7yRlmtPrabHLFq2ota7k26sqcF0EVbT+yTCOopzW
# DATA bynVObtRzoznbMd8Bb57jMgq6K9gI9gWnRjDOGhEDr4S33OJ5tZ5b+eiwCB0jEDaButNPkc5UsOIciFfkfl31xVXXS90FO4KpM/P
# DATA EjmJz57a2rDbFqtIhqxqcrXydck+QAdu7XP4Dx5fpn2fDn+6m6S1z3CdD4/L3Hel0HIAksoZDsr1lTccRHN/hMw7cKeZrYg9pQLK
# DATA mWWahbiG2dApmAQOz6cLdkvzHTaDJAPbwDJBDJMrSFUcBCqWH8srbFAekK7YeoirncEcQFzd5hcxyzkiuFMSkdx9ocuBn4HZKJV+
# DATA 9Ys1Kd2rvYzmiRK9jD2sMbJVMuPUdOWRb77J//w4DwReM75CooLHUv6kCwoXa4QLC+XxG/LV08y4SYUpS93QcTPQZt2uaFWzdFZW
# DATA fK6yjrvr1xw2r65qWn2uVappFM+LZEoYgJCyq+E9JFLS5WK2pHMDhjArD9Awv6NI92YN5RbKADnh+JAoyHu1pqOUDxoRMGfB/BB+
# DATA Ka/qc9iQ6K3KHxFC9REjFv6uoy1UfRAE7Tb8KTqWg9n9tOT4ftVGkCtdLL6tOR3/ViZGhlbZPM6yMuMNNzCp3FhRgaDareuK2iI0
# DATA WFDoqm24qA/ZZw+67qiXD7Vq6CU/Z48JmJ9wJIo9h1QQBRvXZOrK9aVdbPk3RcQZMYU38jIqzxOg7zc79F/k2vX6heqG7Rd6gEeg
# DATA gulljN5xW5JV8QW3nqQlzaEjBQUG0ZSexvXLOcoldgq1t/fSOm+1dlQr087csqALVmgP5Zb+VEMHAhfYYP2lotkJxe7E/nHeLhVo
# DATA cIpMcgaMdqegvqt7+vLg5PTw+EgNzJU9auwTfYyrT3qVQmIczVC/FZgVWi7mjDrLmvsgE87FBN8d9Bgj7jGs0HYT208VieDN2lRp
# DATA Q51ncqqArllgh3CIDE1ZFWfVv2tMkcNJECPr91gyse1d7YrEhBrjjdxRnebdkjtrTV235rEuNCz4eFta6UAzcbH1dhzefnevAHJc
# DATA X5W7O2vjla3bHnCSVXoHQ4zqXidkP9PFblNf6q54npRDXnEBqPV/pIvfchfonrW337JJ+NS2ZQBZz+5nHRXnNYJT3QhJrdUWYX+B
# DATA yI4Bs0WWYspnY3iV+BbW8CdF3paxqTrXaHqE+Us3snGZo3nZQGXd8UZx5m/e1Osc6TJt1tQBeqQINCfV1MVJul82ge+5+ks0JbCP
# DATA Ox053acMXNMNIM5ad++hwjgrJ8BN46KQztr6i49Gw2U8jdVlN17u1tVVn4M+SH2vu0GVn3Q9DeoMoD73Zx8GLDgDyCW4XoKKFc+v
# DATA udBWFGBGSGQBXfOlUpxPiSMZ7NJbueqG6mHmepMkJdxhT3zJYaArGABe0HVhqUZURHNhcpgMidQKyhfl17ps+wTvrx8n+t56Uogx
# DATA 1yggDkPlwFQSElImfsaw/Ch5s1uqiYG3iVGQZL5rbaDKesr6HZ05uua4gVPkkcOEFN9+zHvaidNuu+11U1PtX225e0snpJk+e696
# DATA KC7aIbQppIl2T4wfCm9qpic1ykxTTqO39K12cPCTw1PYEvINRPjBi5dnX9/dU2Jl5cn3/b0p3bVkBb/x+qbZcjhOsivaBhnKerMH
# DATA 1P2iV0lW0N1snoZgpeBhfCofsoAtEy+BKfCVfr4KLqnEDiz+IGl6RbP/XZjR/QwJKEUddy/gTVwPhXBfdEH0vy6rKqyPgZPXdLi+
# DATA QILTLI8m80RurzD3qHxkcxLrd4Vc/SbSs1NZxmz/R+NcfCjKuwekgSxUMu0KKsFwcmRtPlnMY2sz2b4GV/VY68kQIqEN77zueHDt
# DATA NCV6QYfrwbSs/F4KD6QzRWt26QC0DqieGsYISlWtdz1QMCBfw+DexoSlR7eW4O+jmyNNfRg8vCCrzR8obaCqGWhEUrUIQqAhS7K2
# DATA dN0BUaPHxa8yzq13HWN+pRO74AGXLFBaLzWVNCHLQNNVD1hf5S+WRswgsVpcebgQBtPm/0/OGORTb7/7/P9Go9lqrOT/17t/yP//
# DATA Lv5tbGycxFihys+WM7qwJo6sysicwy21rAN0CmBCaASNQ1Q2RsuxfTftPen+lK7/AUn6y6HoM/qXW/0Rfa6ed3Lw8vj08Oz45JAy
# DATA 3flAkpSAQX/D5VU4ryXp1jhdLMCk3zIX2OoyMSs/5a9tWt/HamUZp7+Cm1e4cy5Ncz98qnpN7hfo4c7j2xBpwtZcrxaLWbaztXUJ
# DATA esJyiB5r3e1Jbo53ziQNOI/qguG48w5f7H2OtQFzZxTEx7NzXt/sB5sjTsypeE8P9p4+PzzC/HSKr6ogyCzNEqp0pG80MJl5pT8u
# DATA OVe+rURqzUXUksv8xyUKzKoi5flWc2m2o5spMID6g/EAy2WXmdwx1TtdUDbE6i0suryOdecQvYbg8vuWq1+nUGOEBh9yMcfDiG9R
# DATA zMcEFF6tyIDpglREq0e+V4DhfOCWGuc21LIFyAkswllwmZnqnp+sPH9Klq5pYir23qDP8Rw6lxJnI/eWPi6RaK8yVXazN+65Ru/F
# DATA hY0M6DpfRPjykoqZSXcJO1vz3Vtw0AElJiRzf+Bdzk9AvA9VYjS3yBrAkegqXAt0PxhnKVMKWVaZuHrg9yTI4qyW63XvOgU7J8he
# DATA Y89PqageeiS4AzxTRe9BR/5PMfOWf4+w43g8cjsrxnHh3Dgx3MWHPC3A3kVB0ShVmdEiOkwZxxMeSbioIftGNypeZVyp2B6fsY5p
# DATA qbXfWXMbpkVbj7xkI51fUvjSXA5S407kOtJ1d2jCtIVZWkRWdG/m2pmfmy8XbjyKX1KHYGiByx+jGlklQTdgZTKXHYd6I9+b0Koj
# DATA nJotOvd66183Sc7VJikgFj3tZesaGdXVD3f9et4VesbFIZXRTaxJ9DuQ1UFEaSigHoP+G5nbWMh1sGvJ3dp8OS2fS0lILHOH07uo
# DATA chKVuEXDYLbAK5RluvwjxhrURwZldwIKc6teNYBXnDwONWK2iKA1ZbK0H5/KIvsLlgTWGJ6hiyeOMj3ncTJJFm52o5WjnR8bQLJW
# DATA kJfEbSOrPkTuDNYFZ1+qu+v4xiq+ptMJbkozjm2a6dwm8Tjiw0RYzx/e3OH3OWoqY2E1vwHLFmUUJ1QAXkivpCoVBlyaUJcCd5KM
# DATA 1FKzxFi5vu1yni7pBgI1MxjCvjRPvahvn5axwfjCzMH8FSxv39aI9u4wNfdj6twFx1kR3bt7ZWDZKl7IVTKlMO3rOJ4JcHh9ALBt
# DATA tW/oN0vjyG8ixGyzvoILB8WKOK0hLetUUgIzN9mfPLfWC07k7b5caN0fs9oHI/wvpaK/VZdcdYGcJGEvm33fan7lOHlSFe62E4o1
# DATA LOuvwXVvYrYTuTGkXKTA4FE31nomoieXKtYV5FpmIAC4rjsPQh7lwNakqAYwNKl7dzkzJawVHdgrkHYrvY+Ld5uqFboAzhnm9p7L
# DATA 8Kwh6TgcWr33sTid6SXmGM59mC6nZKs5vjxp4GinBRvbDG/pqnxcF29sA0F4D0p5M6/Fp9JmdiUrZ+RorVVHP5x+sPqtPK/5Xf2j
# DATA Xb3pd4qKWp5omSkoAsaDmyfaWS8c2Ze5C5Ynsv54PndVjSG0e31vQM9V1gu4+IPXiH/f1+JtBO8jyjbRp88WRxSPY7QwnwBP8amM
# DATA bVWxwxkQISXfSfV3V6tcWd35hCrZmrvsc9ohL+knu37jcWE+S4841R+LAn+yPKymmDWRWYfpcswX0KEbe3yrVOhksW5xuL9RaR8X
# DATA FUB+K7Df2f4NbdAKMTzR9Xfp3nHFYHOUUqp8G+f0B5extc2jDymJy7IHI4N8mdGusi/XtEdWaxW4ZQXYel1Zeg94g5WkdgvLilNV
# DATA 3XZGX0hm/wdzr/778P9mvyfH7+PqvzR7jZbr/633Or0/1H/9rvy/X0pUVecDCt+Ti7zY6So+ElS3Fqmw5/v8vbm6Lfe6f6v+S7Ai
# DATA X6ZZ8maNN9jy/Uq9Frv+BB90JqVbznKxd2Y3X4bCSozme9dIT7//IDMlJl0tp6/Jv7cAjj4OJsMo2HGOKFi2agVrZOQjtAyRUmOp
# DATA P/fIET8vqJChQt4cqloEl8BNM7DclOomlzfTfEyUzEpnt2wUarClCrPwZSCrZsoYFrfwPc3dN9nFsr4LK5tVrtbkJEOuCEAnCJzH
# DATA Qnn8HOZ4nzL87r+9+yXX9laFvP8B/vz2/c/f//W7fxbK3Hz3m3d/j1fYv/snLASuK3kI/Jl10C93BbVc/mmfqTPP5HzqI8rM3z04
# DATA A6o1LjOg0uNYgPw3D8yAEqdJt34bnJcorftixw+ISAMkUCYNnhN/NhcJBbIUdAUn3yS0nOECg2pjruqzRLjkRE8txK2mB80SdFAi
# DATA zZwzPtx7ynEU/plcKYI7x9fLAVuCTZ8GpwtlkqmdBZ3O7ZZ4o0OysBrKDw+eBXz3fyi8cj13wvpv3v8NkRRWcodPWP79/d9QTfj3
# DATA /wUe/yOVn/9neOlf+MhgQQF9IRYLRDqGgHYMMDd1pywTUDCJum0knGA+gQ93D8L837Dw/G+QyN/9PVANwvIbLouPZemBUqzC9Fjv
# DATA /t0/w1R+Dt//di28RDIAYdVELwj28xzcF8UZYXLd2cgKUr3Vo9xtvoVNfLcJ1tTyzeZb7PCuBpy7dvmzUi4da6YcMKN7AmJWzztv
# DATA GUpd+O9CDcbDlFZsMONwpovzaAnUySTrIZtCzvnex2RZ2twIFgKW4Vfv/uX93xXs4l+seqrvuXP9kej4Y4m4lfhq9vyJeDM9feEm
# DATA u18+dGrMaH/x7h/hyy/f/7WPf/ADkBnM7l6e9fhjLy7EpgoA3pZWXAFAxRvXdkIfVbTtg2cNW+rvfNprv6aJ8u0Q/DPM/efv/gX+
# DATA 7xePWGtixXS5C/Fvgo1TMpWsMfYwpnrSfiiIyL5lnn6+YeI8sAG2RHxmW1F6M0WOvvX/sffuzXFk152g/sanSFITzkp2oQDw1VKR
# DATA RQ2aRHfDIgEOAKq7BcI1haoEUWKhqlRZRRKCECFb9noc1o49s/vH7EbMzjp2/90IuS3ZbUktRewnIL/CfJK953HvPfeRWQWQ3fKs
# DATA pfE0UZk37/uec+55/A4eiZXgMODnNDOHk9FLdaFr60/as8mAySl14T1zSsRXJJ1QOT37QGBwnssCshcjxMgRf8GE+Cev/1H9/Z9e
# DATA f5moGf4lph/5BWYBgZ34m9dfJB/1px/PDv0A7nItqxgDxbgiIlcmERywyD69RgQHDaZ27dqNS50X3gwwgJ9UbBIWAbVAosNV1Jp2
# DATA p6HY5yT0AZKXNX2Jr0JmXBL5rYxTawU/iozyvyFD/AUvEuVU4RwoiVooOiPqzCRYq6KHCdXqhlLo7u5L0etAWOqsOlMHYQecaR9+
# DATA cwpcPmCQ8K0WyEP7WhY6wLFryQmEE964yBoOnPU4u3YNXzpRMdwRI5VgBlYUPMw7LYh48TCy76owsd4UDl1T77zokYQmcEs23Q2q
# DATA gS3QHsfZoWr0D1NA3hgDNKpSbkX1UotP1bZXE7oovnFGQCgMNHnOiwPOD2o+GxVMLlAaSCv31t+GIoyir/LMOLSCZDNVHKQ42I+U
# DATA 8uenApsMRzXHkOxInTwmR+5cqBbQGgbVhFJpZNT/GXv9p2ogfwPig5LvQtFTPfpckZWfIh/6wpsSEF/VV2/+UhxFeOhcjZDeGNjF
# DATA /tFpm+NkGWhM7pl+5GotRrUIisnux+vLqlCM7gnB+3O1kkTaFZFPywKXqYPppKnkx3ccZo+2F8Qgmp3UTijW3WRmFeW+VcYLynfx
# DATA 68+jg1fjhrX6DyhX/CaBTFtAMtWD377+ZyE3AI0qHCvtggH9LJo7OpWaiIwPWSU4mveLduewGA1mU3ZGTxsNdMHCtwB0WZTE8mse
# DATA WjMQAhgWIHACNKjA4gKYutCgEKl2h5ovFj9/h9v/Z0l0Yn+ZRselR1As1DTwts+BiUH+MXWU/goyoNFxulDj2CJo3L0Yd7AukgtI
# DATA DJogNToJL08rizP669Ek3OXBxxq2IepFUT7zimg4Fc0RbnVZxxhe446G506XDvVABYAw+i5pqtA+kxy6nh0cXODwIYExcgpQw18A
# DATA c3j9D3DQBAU1NPdLuNHgsdQiTOmFhhgcUscynAkxMJtOO1hTWVF0XUvqufzy8n3mz9Wo/4EY7Jv/Sf39xZyVtpBOossSRUM7bopb
# DATA gad+1SFiUs0puIq+q81f4/8Cywp3MrWsf06aGTq0l+A2ODYpQwm9pw1RJubosk+2iNf4X7BWSx76zeT+QEls/a414YIGu0BXQ2qL
# DATA mewd68rRc0oZmZ7VwyTqDgajl6QD9CeurqfS3PYPjN8ru8euHZw7ngi67/ZEmke44dDXgi8K3PICzliYlfEf8LT9E5yusqOnBTXw
# DATA 42g5LS8F63Lmi9DkDLLuCJ9KShgV5t12wRI6Hhr9VJ+h8/iyFp0Xea9Gyn13Ra9evXofeoRro875rDNASt/jewp7yQ+1bWN63AGN
# DATA BUe3kYOnpa5gPHF5ggGf4lyvFo8olAXw+GsXi3KoFz0MRin6cQXWi5Uqgtd/kCqM8xdM+3stCY1UKXVolC78gV4qVuAkAv6tt1Qy
# DATA 2Hyk8tT9I+ZCBY2kOnILKKjKBJaLAESVsqJS7xYwE4kVB1uBK8WE9djTYsWNCpgnP3G826LF/U5Zako4Vpq25n7zOioJaunhYHRI
# DATA iRDo6lPiv0MMckHYKW8mLso4W/MYpyurBOBYXOlSXMCETavFOMMa+MGFRbXfi5jmCyx0f/eHwMzA2i1NjDw5ZVcOolwOuchRnCOg
# DATA XEA4+XozeJPnkBNFqzWPeFJQgUlaRUJsc7wIU+Sz7zK8dtp5Vu3xZAyii9Vndezp7yMXuatuqyqpvfgWGxaqOhctrD1bL5sGXQf8
# DATA 0vekbY5sEqFxpkVy/Q+oCjJtR72qtZpXLBnh/0HosHkW5GPnXsFRMZ1qxsFR/BTqgVI9noyd3BEFIhGr9Suq83O082+5HbQ7sdue
# DATA Vpb7E6fVk5F5izmt+jOjT2/IXDw1In4Iu8tQpID3+nUTDSitmUVxcvHsDxuHM0BtKam+yEvr0Tc1f2bMFVZPTFB1LJ+9hrCpS0BD
# DATA 8m0tARRh9opt4okKe0obBVCR8Ptsju8xMaPd00LdaDZeqfvd2iU9Jp1sRr8P/z8lLr5/w/P/W1u9+Yf871+b/9/epDMs6FCqCy3l
# DATA wFKMDKKXCo7QAG1CPlE3WBvsregUSM6j2ZTKIq6IKgIe751BsXjqt+5ofPr2Sd36z1Tnza9pZ7p4JLlO9TYZgMhNyDPuM3DCBsss
# DATA 9oef4YgSWw7VLHX4azbEv90UcnCQKS/LUDHKKYSFwWHHW3QbdWlK1rJoMAwbo0i1HiqlbBOj8rKdAenBP8zYBjyB8dxtiZn+E0UD
# DATA dKSF4t6wOkqW7ILyKnlkyAPJvJYOWp3IetLrd54NR0qw7pLOQ8nOCDszHSXF8eil2ShI5HCjoDQ7455Q+BvuGLZ9q4/J8oSv6slo
# DATA TLvTiahkAEecQsrxJe8yOgmOq36gb1rW/bNBmYbMy0qUOX82FtEqgLfIn7L3yD+DIc9NdaJHRtkQ5ibvCXvwf6vLwj+Dhi1oCE2A
# DATA 4KbiurVF0/rodEIa7gi7Uwv7Y6YJjhgiSrYDPcb1t+t1pX3M2kfBrYL02V/6bhfqOvb6d65zBfTZQMWqG9i03UEAC+k1zAfC5OWT
# DATA m8wm72vD5qxZ9+F6YiMzGOdYTBC5ZqiPEdK8M23stjcfbT/YqBHS8bQN76zPLBT8o2R1pNhiOTQ9OLXx14q0wM17hHfbXP1aZMf8
# DATA 73hL/bmaR3UlpXvnr9DH5regQ/od2JdhWdQ19NdqZoM7+W/e/JTs73D7/ifyQ0SD/a/f/MfUBYJs81zzVZVn23GySOFR2rT7EeBA
# DATA KZKlmRD8c4p6Vf6Z/BimZ20NEzS+UHctUOvybKgHeMUkSAv9VP32k4DE+9W0ulQ1oUVXHYE+dwrluuEU4uY9gOwZ6FSEq2yunqC2
# DATA t8bl41DYnFUA9sjRCNTqmugUTOIC+REbchWIvJ92H259191PRndqiuxsfBQWMW8fbO5UvN3dvu/VX6pxXZxAwrZDqvRz2HS/kluS
# DATA bORiU8YdCSv6R9RLPqJT9f77ZOAoPTwXGNjfqf1Oyp2/xyH9Mnnz50TUwCW3ekDqOKH39z+y/66eCPhIUTq0N4MC6Vfgwasekctb
# DATA TTRwe1UJEF4rXySQv8M4eXTG48Fp26V29A9EleFF3mGn+pKCRZoleUNQjhiBDmlUkKWByu/TOT6ow/Pt9s6D7a2Hn6mzir/U9tq4
# DATA v7e9Yx5sbX+4/fDh9icMpiovoXw+VLEjPB22TcfKWHPOvDjqqIk0nWIScVBP9BOiDgfODg8JsrZ4mYqYJImKiCjF00xdlOZ+QV6C
# DATA 6Orza3Y3gF0BBJh9nYD0UnEhQzhutbiice1FQO9iswpTTth89q0drp4Awp/Atsij35+PpSiuoqq8O1DSpdMyx/CYKwX7KwrNBwi0
# DATA 7X5PgrgH0QWhXk3sJjIsUjpgUr3kPW6G63Zm0saqQxudIbpzeSvMCCAMz6wtrSuo7yMrQl1L62SeqCqaUUolG03hgpKbT4JBFgAH
# DATA XeMxAABtxGfEkeiioyDHKqe3zIS9XqkOx7olRrIUVK1eBXWrZ7JyZzH1mfNUpwtINP9ZUci/RwkQXQd12/C5FhjDXZJJ+c7eOPwx
# DATA 4jzbTtqZZjssRNPA1ARzaEKIoARtqtlQY732UkOBci8CiYwp5uci8pwSypBKfEnWiEQxJrAh/JocqK3ZBLkKuu7/AzoYoi8hit4Y
# DATA SxKKzHXqYR2cYfmvFFCaSe7CJ/sp6At2+aFxS2XM5faxuhbqW5yJBgZS4XId4anNhdXcZ4EMjO/wobpnA2oH37vpI7SiNVcoBw09
# DATA oaAj7UkPFx/3pqgqaEAX0f6opp26WNEufzNTs6Ct1PB7rC7LL0eTnvmtbhLzV+5vbTzFn0rliWvqQsbxJayoEgf+jDzgiUH8BDnC
# DATA bxJcSCWIcNwSiOpv/hJNTv9cfgE1QGZWZVGrQd8xVk8vU52HB3sB/vrhLAekV/jzaNJ5dmLTqDjQSGVLwWhLGotNFWCvFI10gwGS
# DATA 7Xz4ogYqWU7eLeF1nuen/NRUHYtK60xV5yEybZL+Se07zfwVrMh+8nR68F72HdgHNtRG1cjRM/D6Wqtx7d+kkoxCuuwclNw1rpUw
# DATA jkCKajzy6Cq8IFA8SBJgylPIaNJuQveBhrTMVtSVHQ06z4oWVllhT+D64R+dCVknQsbsKu+FDfArB2pXfc4TPp6MXp2S+pv64RzS
# DATA evK8P+y10m6n1ztNrd7FzG3tO3eviLSijeWDzJ1cqo7mt/adoCxbOEHXCB5NKI+yrGloSM1P4D4cDQcjhK+mD5dcLC+QIGZDuwzD
# DATA 2Drw8HgJzORvSqcw3Sv9Fzq2Q833RMIhFxGMtwzMGoU+PusPHZ93feh4h8CknGR/UntaXEP0+wmab58W72W1/T+5o/Zq7U4WwFIK
# DATA bwgaDyczxH/UWcIFoKmjR9cR14/+vnFAOy5mQVKiGHLDVeGwOpRwMn5uc9yHAucGIB7Ap4LQKkJQQrLHU6Y7IgHfdFAbxanjvqjO
# DATA 4G0uPUspEpUqgUf8t67pTNcUZsNxg6sAneSIgqxkT+j7iMPJEPk7TyhVgeftDPVoWJUb6409f894WDRw00ADWbLsPzz3Lrc4jxqN
# DATA DrO1h3tHZhcsHG0i79T5nOfvgKnA7RI4xC9QgPglyAooJHyJ18xf0JPPQZr4HfoqfK4kir9RT3+DTGeSQ4xEThTkjrzE4EUGLjEU
# DATA qoEKJfPmzV+n5VB6Jt0mwAHVE6GWCeQ0YklGMWyVcEAAW1afZI6keswSJlRucgsFKcuD/D6hchRZmdHHYfdklfuqrQNEaDWarCCz
# DATA GOYC12nmsQlsPkhABX+Vn3+OLTohjZenmDV6j/fff7+8AQRiP5cronqvM2v2+joCxKwHU4+mnOvIqi3FZ8XcE5mJ6YaGLxA0Dezj
# DATA KEjWbTYOmwhvxj6QWIKkZviQw3oRnLRKpgwB1kyd+/SXAx27b/caantth+BGgB9orYcHisZMhVDRcJKJgxE8qSe7aMlHm0RQ+OlP
# DATA RkO8EdOMqnvDlLJxFxGJqCTMgecJBDz1uZn4fS3Aw5KgL5jQvWhix5cZbRKSPfKnX79IhVsBLiVqOYNlpb6AvAZdsVl5DtwQl8Wk
# DATA PHG0AZyDus+6T2w3krUBC+kTauV679oc+fKbyd5xrjhuMU30roPT1JlNj0eTvjp1/Rc5Bx4O85fQqTsszlI2IbJ7jQG4djoahTk3
# DATA jrR5qj8s6wJqUib9Z4hT23KPFy6I0KKbwD5a97qga74XSGT8wHixE/vLawcELKuF4DKBmgRPI0WrFnVXo5Ky47wRpTPiLmBrOlPN
# DATA NGndzl1YRbv85VtUkj8PoZa+2XfKH6BTOlSrDynYBLBXQNAZ/dA8dPOgC+zUlA8SQQQqhvkDteuXMQjVakj4MQqADHTIj9Th8IJJ
# DATA bSX2BNXZvV2cKWjuKK1zsi3dS01xwNcLjiNPOg0G7/Q8EBhj0nIMw9ixTDipu/5GbEyuQVE9VvY3S6+l1hVfQyX2lSw0GY8G7A2G
# DATA z9QCLKMdfMbuhQ6sqNS9aK/4CGbjPicI12qJenJN6FpANd7vovGZ8VHc9+i4u6vJJBY48NpE0hmSX+kATmOV9PbAqIwQy8+491dQ
# DATA cQ1Mp5WY2pUJopNxwYQ+Bj4VcAK6nX3t8Xs4Gg1qEumO/6ZB705pFQzh4IRberZhq6BQg8S7mejm8bMmunEoeSYfwx812kbSlqdD
# DATA k401z/2AXvv7fMJdaJrB2AEXPOLiXMga0EkghixAw0+LNKqpK+0N3tYf+mKgJ80g7w9OFsgAVs5Z+BMmCcvcduP0ZJCG/atVVIBp
# DATA HxvTV3AYyAiN40ZHWb9EFuScrfBwiIwjsNbCdBq9QQ4uKqHKXmvTXOV9HdxR2ie54pX6AVjTUUaVv4Gp8O/+ECFO5SNyVlOcYpK/
# DATA 7AwG8pZplHhWeiFPppp+Y3PynY4xPE9WZTgDnBHgITXKhOoU4lunVgVfaS2uof4/1H3rV2Ahf/OXbOf5pXOvMncm0xbcylBvp0qB
# DATA Ks/FVgDjPN2wIA7+r61PiZ1mR9RHg2ik65iryn5iVPCgMQVyqyUXpN2D0ax3NOggyGT6rAvnOlvQR+YXhF6EykwAyDGoV79FW9jf
# DATA J3sPd0sGpfb/aNIzmmg26SxgNbIaeL3TFp4S+4WZEYDmL6Z5Bw0TIOj3OgP15dvNwE/IwQJUuH8Kl264lfvj194jpkuu3QD6vKve
# DATA PdJu5qafWdxeRoOE0S84wMXGB9f/z1ld/WXV6D4PVdI/f/MX/qhRZY9nX5xo+FkzdMIsLf3wL7aROXpMCbVu3rzBPO3VpHMabUQS
# DATA HxIu5e85TW1SYW7tW7a5eWuB5kw78/gCAnHO3Akgs0tn3McWQHixs1W3YzpHQ9KN+cv338iU8Oavk/XHm3VnsQB2gnEofp58qmoO
# DATA XBcs8gS7LvACFsedCWlP51hr2VkjZnlFQuzIMxFjGdRKFkOsSZQSOV8xWspnqH55LW6L0lYCt9QEBxbYmK1AZgfQRN8wkk9GA5iM
# DATA mrFYOUYpO3piWoxXZU1TC1i9jQdhdCqXPF95azoTEyArfTJBmPP9VI19f/XgYn0JWpOzDGv1gIYZ1sUrSXY7OB5cMnO9JtVkusy4
# DATA Yk6qBiiIGy2QOy374RcHzmRUd8rwlPln8L9YvJe4UrbScttIXv8dUtW/RB+Tn4N58JdYnILlyCyurYqAF/glfkrPmSv9nB/+ygDo
# DATA 0JR48pR6iPpKeEnLlOpZsEJYy8yGK5AYzuvw5FigXThF/w/G1v2ZnBrywEK0HOuSSFZQQYoOO93ns7HwX6AH5ELBJ27ZgUmck9GX
# DATA vufE0To3NHhkySTSVgWKtyaU0MnPEWFatVYAqVhTii+pmjr1RP0XnBxp+zetXF2SZv0cE4aBqGR+0mWoqa6v6sf4GABWm+oPktwR
# DATA E48Gwt2iH9m5QHCtkH5d9hUVsWQiB4JUb1t+7XP1am7tOVI4Qk8W8E1SbFt7obrPOy0L4UJ73c6pon8UG8OVlle3F/yFVzN4+SHP
# DATA YeqZBcI6xQXZrZqWJT86UuwINI0tdj1xKOiVOBXkVBkhf8VRnplOOyxM78w0mupOOn1oYAWhbXFVLGoLeiUEOpqnbVFl2dyMavWq
# DATA u/B9KEbaf882s88oF6yziGq6zFRmjBnNleuQgrBNnTTmFZTBPbhM9t1qyFsazTwBkOplabxUY283mEGVqCdtcZiOJnlxXNNBp6b3
# DATA dV+eqVdYBfy1MiHd5FLVJprUci/WerrjVeLoYPObbkdeC1QhBBVevIf2S7CqErxzf9go8ilnM6ilnAeDtHku8AXa9AF9Aj9uxrO/
# DATA 40s6QfQszTyzD5ZwzD70jUk8CH4u5BiTmuYcFhqk38Y9svKiM1kZ9A8tAuyKYqrp4q7K/5e5XBmGSdCtPyNP1L+n8BATp258Tn2N
# DATA hbqkK0njv8rbGwkWv8TYdimzfK6dkNR//6MEjMI51vq5sxSUMUBkDvuYfCLlpG7EkeyZVKe9m08gCaEqw/PfLJ0aZIWdXhsyn2sh
# DATA XACrgTJ50P9R3mub7bLPm6B6QavtsN5giLXgBhA5vFc01eUN6Yw52C+rB3K4ke10Xt2lyPauGiMgsYi9eSAyMoP/sJgop+JwQs3Q
# DATA 3fNSspsV7XIRweHOy01a8Al+YJAbcLKtp7bZQTyvJgjC/06nDcTLpX25TxUi3gcvoL5QITuQJbkKdQ9wAswW9AX/r76PBcZC/AWq
# DATA Ar8El019BfhVpdM4H+k75GHxW8a+/BlJ9OQXWDLXTmqwV6f2FMyj3/uGih5Eq9i/TsAijiXAzFvmbae29umIzKwDqx5fI15nz8mo
# DATA xFyCZisBbWo5DabEMht7P93lHrhb3LGUPMLBWmB9sdUf5KAupfTylfudlT7mQ242C/ygCDcPe0ln4UKxN8YVGJXJP3P2Ctz+gAWw
# DATA D2l8e/n4R87Kcb+k95bqsTgunAnPCGdqSsO35fYIFqCx8DrGGaAA7ca0yLp8SaTXy3uPYYPid8AHvBJkvVIbyxVCofT+HItgPRFS
# DATA S//owgJcyartSLcqhobxHLA02PL/TKpk7/6OoJUYOxlqBb5chHV/wWi6LqwN6fp+gXF+gIH+W6tfjow8NmD/jRYC8HPHlA8l2VJr
# DATA V9DbG1SbNhAKCdN7gfUE9xMvyC50tL2I3RWb9nDcS7v39kZYlOJ5S+Nf9l6iD6YUnGrkhNoAC+ucm4q4UM27rtTia+QaT4QuILRF
# DATA llSA2gTr5WdG5WSZAUKobzw4Oo2PhEqTal3CJVQJ3gDmBWME4JrqsG5BL30nyZ97cvIdOHkcCMan881/Mq7+oG93ihuF3udI3aUO
# DATA Tyv2fM9NTpiDusQvUN6QOJjaez02s9auu6j2BGct4mXMrQjP87nrXSdtmO1DuvjFm7vguxiZhqQ7NLkc9UIhBt0Z4meCNNaCzFEd
# DATA +46iG86qozN23A/P0g93trf22htbD9oPth+tb27BLUIaCMTIH69vbTy0xfQbK9eACptyhosQHPXQm0TyRoQ4Gkj8Wm0EOMgcDg8t
# DATA eNRYDzrUl7NS3ZdrsJdXWotq5905U2Lakw/aj5988HDzvp4K3RB6gIfxJS4aXpWf5f6QHHLMvOy72iy8ww9R14Yy3cvOi3w5gu5l
# DATA XDWXDP5RZK9GNo4we0T3DRfU2cQkBWtRyLwkey1pHPTMky1jLMzCboQikSMzlQpGF+bkusHRy2HecxqMeXZJscz9oh5frqzuKOsO
# DATA MrEgcwI+L32UYgfhYOkSp+Xr3K5nkVPVrDhT5+5S864MjvIjDTlTuvDx0uAfXHIKcO3I2mGhQ0UwanPp7duYv1BfBYV1WaVpv6yT
# DATA 7P3Fdp+DfTQv4a8MtxJ9H3NS41JLwV1IkxXytNU9QIdp9swWUboPjLlaEC0P7JBIuXDU5jrPTapCtf96bUEbjRm47IQSgzdfUD1k
# DATA ZGwl0pZE2kAjTVMZ6CA6OFWLD53ZdJT6XtJvb26R9ZY6bMnMFjwsW9AY6DynLaxYj20R5y1UgZV6pHDDLd3jS/sBBX5en7v5w355
# DATA pwSU3sQQeWJzam2rereiPNfC/wqzR8vRIitGwB6I9A9KgWAOafnGkRDcN59AIm9FU3mTt2oOvZOHIZuzbQ15qGxmV+yropXWOear
# DATA lMpaQpJZ461zqkr9ZGQ1jykLHlslwh6qXXhfV9kKGkE3T7zDtrijntsMNl09BhnFi9StbFKQGvoTEyPVmVeh7iNZY69d4089soUz
# DATA IT14pJd2LYU0dN1jsDKNc0iernZP/4UicPgzK3Unjpg01F+Of+rCjj6+JxJ5H7TLMCRiYA30SYhfYCri6DfzuyoIzpQkg2bHqjVK
# DATA xAEuh/oVjH2fnnLbpfw6o8gUdPD0NDYU+9g2Q3KvcAyoV/HJJWWEeRVdTlwom73YjaxMEJDLeGDjmLmX1Z7f9kv/4rbAWK+0Fuh/
# DATA JDyXWrUOdfTA1bVxqx7oRCRq9zne4z3Tv2hC/8iW4oDpcZmbKnalbt2ny4ndc4I7rXUxJpzPX4xK0f2byUMMpCcEyVnBWb4JQCUt
# DATA kvHsUI0oebLzMCGYMkpewvHwBAujZniSF0VjMe0IxTlAVr1JPqCkGEMmAbx5yT2qNNiPP5uD0lOacqBMr8vVeqDCw95Y8RZJH+WO
# DATA 0HWhWUnrazceba1/sv69jTbpadTUkTNnTP+By6IbyRwgEkUZFhxR2VbnESF2i/n7wp49/GW1c09Y6MBThy90pCLVwKU0NqVNF2BG
# DATA z6FPUf3kqsA3aJtdEGQphrBkWJ6ptARsKUpgzUch/YnTcvvBQcivvdqQkYDvk4l258Ao27FvQioDDAi0AYwFYjoc5/2JDTNloZhw
# DATA C15NGR9Ece5TpgM2ktXUA2YO8rkE84N5vGyAR51YLUyKS6FaWWye9VBfThRNsHGMngeTzFRFQYhesKaMPJZBm3PjFAkDn4NRnL6Y
# DATA QaZ4FWHwL/jbCZuKFTMwSYSozxDFecH7Q0+/g9C3wKoy75RjRV9dvZrk+m2UcpSeUp25zSkKsfK7zI8kj4c9+lY9bd4xMbsk8pcb
# DATA e4z+RujoMhduhM1oKHjjhDDoapihKN5HMwDWSPrmQdKs01TDLZzfHsRS+xQxsswbLgiUBSfcsQlh7ebL6pBOchnt2svHhflxOOsP
# DATA ehwkrK4XqFYBc3AFAsy12n663GNcPp4mcoGkKtH3CHWg1ygHkQtf6k1QwG3LZisqvRET7/ROq6JTdXZjdm3V3sU1VEI3Q0BIi9/d
# DATA UN2o7QOQdv4q786mncMBBhlvplEsbfC3omBq3FmmpcZY7bwMs+rqdUAN+fKYbIRIoKAzQCUg9wp6c9cRK3w0m7ZurK6yAplyA4gO
# DATA 7po/N9wkABfx0JA2evLQkKGAyetfJR/v7T3eXdZhOm9+GnUBsoGEX2gMFgLqZeeif0Q1C7gh/VodRAQKx8sc0yUl7QHZksi47Mpe
# DATA jnRHNIkczQ/olgxHYpDTPEOdeW8ZqqX7MvuhZ1GwUa5Pp+y2PtTrIHy4n0V2U8T12oJYLswkF7RgSMYngnLZux6dld+eDV6OtU1O
# DATA aIsrNiMJUeraRCRVGPQwRxCOw+cUH9CIKDrJwWPl71YM1gHmmSkaNOU6J2kE11xyVc0NuQquNHO0LwIWxMW/CC4MxnXXmpepggho
# DATA EA+DUV0s2GkRgYqgehuzIbosnfQLuDa1R8+96kKfEld4oGrqAhqI0YC8TliUoLru3wlh2FICngjMrzg40ncqs8C/tqtzJRA3lsWe
# DATA 75Z7oiPiEVnXSRxisq92YRuVtIsTlqBVHDGwozlNigAA56Rpd7US9sbtkYtNZpRt8+hAVAhw5CkMq8VT6DYh8Zp5AELlyaHvz/NT
# DATA iYJ7QVpsoVVF8I+Zx0Xi1zmgTKvltR/5P6FzCXCd/+Co5r/602ov8gG2Fh9QieHlQm1xgWpVpm7gSssnC4u6+Qb5GBycZ4zj+9k8
# DATA pOdGIpNSa78e9hICJH7juOeYRS59YBzZ6yK0xUUexi6wtQ31gWRD8gipn32KDQwNUNi2x52+ZpGB9QXZnH1YJ7woKuzg38yzIHj6
# DATA HpLobJKTknxO5ctuEzixTEXpZHyffA7dGib7vkVCyene9b9BXiS1LJLeke39U9Ywn+kpb3orUE/kHHB0BXJ48ThrCFd29YWaU1kS
# DATA YFJlifPgJrH4YdcpL+nubiC+IrPsbFbRiLn3R5mi7hXKVHUj5dnkDA5DyEquPRqq7oq+UMcJQCg2RcU/Fou08Iddi4BwUU1BbGk2
# DATA Z2qs/EWGPSl31V0D/0Wrers6jDTq1hNobVzHWUfcPGA8RykOljftU7RYSarekzODEVcMgl6BHEz/X/FVxG9tT/JBrgivx6xig9Na
# DATA F22EdGR4F52o6TL6aHczH9HoPIowx9pPc0RDMtMsw4VjHWcMWqEU1Q/FJ/mhg7HgfmbM7+VAcVSTP1Kj8PIm1i8XrZYSYqECXfaz
# DATA xGJZNjemFvSc4B+XmCr307ebLF3XO5uu+eesStwuQ5RbUBsZkS+MG3xL+/o2o7dlRqODsBu8Aes7saN+w4w8aERA/S9WJ/+QWUsh
# DATA 56vWD6/k0+4Kllqx7vNYptPrjKeM/+c51sfvhwtqG0pzVTnKUJOwilMO4I+aYE8ystnITixdZe9qHkm94CoboNg0dXCNIzfQYL1D
# DATA TVCazYu317qiIPpncbaxqG4pYGhWKjLSnk9yo3JRTOQR/ucLaq6CmtqDzulohgEsDicPec2CBzLgN6WsPXohgWVZWmwpWCz/QH2/
# DATA gX8qUiyurI6q0r3JmhQzhpYvlGPmLSHHTG6zMoAPe/SaUdBOb0FieIUeDIiBCQmQhLKFXIreDUgP6gW9nqm7ySN9KVnEMZN8DeuM
# DATA bPKoM5Z3kHmYiJnJ9EaJf1GxT+SkuYg+iK+LZtkOPJ/ImL7I0aM2wy3dUYImUmPbGXnhyyqU35bFXTEsToc1R7vi5Gnw6tRJfOJj
# DATA pCUVqVWc8BOXO6gHtXSlM+6vAPjxCkFzpmQLhzZoX6xoEKExQD6QX7tIptpAY1eb3ta8d8j3PlYzPlDvzjTQby/v9BihGqf2ZKQm
# DATA YjTsd2ugMF+7TnAtL48BmTkocNd83ixPf03J/7BLlN0MvbS05ecW5gFU7ErNXCzbtAhs81fGFd6Mf0OJsC1WLXA2UBMc/+hw1Dt1
# DATA 0Xh1T1ETVoPknJyjE2arHP/Zw06HegVAQOQt7T3dGhzeqtL7tiTv2n7xcKSOzzo4GIFhp45BkhV40aR7sWoa1LaBkgwtWz83WXXI
# DATA eVjnBv0p5Bv9LSFdQDzr7zBa7pegiYsI9t4aMA+SSYIbYIerUhMRYjihIyjRd5KHWajQtUoxRlUqgZxCaZE8ebL5oOHLhZyKFf2t
# DATA FB2i9rscendz9WZWRRYW33zxQde2dznhuUyD7kyFGobMCmxtwoUNZcEjWQzyfFy7zowyrjpF+2bCkYy/9eKTKYxZK0t5NX/y+h/V
# DATA 3//p9ZdsCgXcSYIsiaXFDcMlf20yU2gwfjJbvoX584qQc+br1/9XG379yzd/BUGffu4MGF0a0dGGnK5c7jLW2K9N8OoXY8AIqHUm
# DATA zwqb8Qt+AX3l/M8traNOPdUzftYgexT+6eh88QloJW1IUKRi3cs00nFTfXUVZtocaw9tkAWrAMPPMjFzYba21jBRDc0cQu2Z3CeT
# DATA AjmoTqTeWJ88m8H2eYxvakK+bbXbvVG33c7Elw3wDOzwJ7XU9CwFB4cR+H209rVlyBiGNGy9tN5r070YDSbcPRoZdKxYg+qmCOB3
# DATA dURebj2mnIOK0ysxrifNi/FvraTidNfJEViPCbXVXVIS2LKROm29i8bOVFcOl8PlE+qZrbsMYXeButA3JbtTVobhablYVW3qrq4v
# DATA silk98Q9k9IFfKqWwrPf6VCvZ/lyH8Vzi08KuzX1DAtsNXASsUW7AUKlDXqA3Y8euVgW/4HSRS1zKMZw5IIR1ryDBiRXb2Pgh0Qy
# DATA KvG6ucmcyLAzPS4CN+L0RBC4ub1E7NOEGqkgdrqTEiCxD/6wDKqOn9Ad0x0D/6ZF4B989eRfNkqMHxg0BvmbgoHxt0Q2DhHWMSOw
# DATA N/dZOamjMDRNPiTJkKREkA8JC0EqraPucDpwWJhjE/bobWlaYtQYoQsYZeiqpYpjq65knKH4/s7G+p7OR7zz4JMdPzdxnTIj2WZ0
# DATA YvCjHjYgk+SmL1O8GkALrgCEo2kcwYsa/KfOTx5u3/9ue+NTV+x0uWUkHJR2CUr4vdnJuJCEf+6m0SoKSFZegCd2p+j2+y32pwRz
# DATA 1HDaup4BA1IL20bXuXYb92u7Dfut3U6tH2rRfzacneCCw5+dQWN386O9jZ1H9cT+/vjJY+mlRc/pnxpVYFLyXWuraz669vWnNX05
# DATA cQQd4ohSLqlJcdTIqN/NT0kUjUjlJH7tnioqfLLxqj8V9loPFy2nympaQLrPDuy4z7klT4zLdNjc67+zoqq5jBi5NXCZiLrvzXHZ
# DATA Q5Sen2BedZB+P9eAIL/CNOtfIOTeNxb530ln8qNDdVTGp9/4yv4HCetv37yJ/6r/ef/euHHz/dv6GT9///3bt7+RrH7ja/jfDDxk
# DATA VZPf+Nf5v29eWZkVk5XD/nAlH75IxqeKdQxvLF29enUn7/TUFsftoa6l6483Ca4I/Zfxslok0+PJaPbsOBYzpMo3VC1LTNa16Kp/
# DATA gykFDhYc0t5UP1W3Vbwy8k91czlWd0z9Ewif/ntULKF/Bdw9VBHNPUC41EUmpjFFWPSf0Kb+W95gvWdOX13llHk66/eoD0wjdB/w
# DATA LqUIm7ogKlraHagBJcaESBc+c5syEr4aNF89TRpg1v0rRnkyhsQq/Z56IXOekLcF8jyOqrH+2UvSo7E6nzGGkirSW0x7/WGjX3Sm
# DATA 09Na6BPmjiB9RH6PiYjnUdVO+uCVTeLjaIjpnTqEV3yiv28mrvDHXeKlb/C/NRo2kmUaORHX/nA8m+qXZnq3Rjs5aYV9TSLoEvQ7
# DATA Vijy0Cj8gt60uXgNRHS8nChGPQYNP8hNJ8UzNf3qOKgtX4fkbqqNufMDDZv61R8/wNzzd+Dg4HE5ougaVOlARJMdzPq4b3vYbveH
# DATA /Wm7zT0jfeToudoIqQNUYvWrdEM04WXQV8efmfM7a5/AM1L0GtyAc6NJsvFoYG5yU167Ca8pKzT9qbNCR53kvDl6op517BygiDWa
# DATA TWUq7Hpi6tY1p/HxtFoa1QE19bb3ZqBr199vrKr/twaDxQzCUAZ+NJtr6fkiPd7JT0ZTpnWFvsSSQz4tbSeh1MS7ux8n09kQRgaH
# DATA AUqkMqJmcNTAtcS/cEFpBU1W5xUQVfGF+xXvQ/T2+nT5w9HkZWfSy3vLjycjcLBL7HLKt+oveGdn4JzmziZ1WGCCGC783O3QQvp9
# DATA cUBBwrTnTx47g8qAGgLQFbPzK6R/04Iq+1s7gVGYMEbMC/gkjjHCUUQqrrDrzrVrch7PHaRRsxjuXuCy++k6JXv8EQeGg07tg1zd
# DATA 2CZI0+znfk5Z37cUdfWluQj5o5p/oNm9FT5GugjTQmsirgT4Nmtw2Sw+jvuUhHh5j+FU3Yl6tfzy5UvMubdsWiU8Y9tiOLOOdRoS
# DATA bisKDdtqAkGCtRsCsARO6kcbe2xAXMsW8ApVGyXcYTti98D8gKEKtw5MYAv+Y8h2y5BvBwEkVPvjLU/sa7pNIkPQZqCb8+xAbrZr
# DATA 1wpz47q2wQhTTJklBrBfuaIsuZf4384zkPjEC0Q43RvIQaruXpNneYlTE7NlJ7kj9STmMnshu4jxmSIJImrQqDKMucdJ1ujtL69m
# DATA oHE3r3+7ntxavQ7/uQH/uXmOxfSGvZtcjzctrReKhugPstLVDwK15y0MbubkqNMf5L0mcoxEO4vaQWQyViuyELWoWaae7NHmjRlp
# DATA Kibv9z4r6pNhjkpKnpg7YCkDH4ETVbSbPN7e3YNdgd51fhAbdE7d7k7GFFJj7Q9hruYaBo8fqY0+dRK66ZTrvWlD31gQis6rug4F
# DATA 4NmPVOuN2bQb096UVtYvRpTglCpr6Fzz6feB9b63utpcXfUc7KmuxvRHoHyPhymZ5risrpW+aUU77ORkb3QKXaLml27YPme2v9xV
# DATA 1envC1Pa8EU+UXJoAf6yxQ9nnR7IdKNph5I/AjpGpz8kVbtxo4Wbn8PiObcj1EJGYy2OCnQFvstM1KzOBgMEp65N0v315e93ln+0
# DATA uvzt9vLB2Y36jdvnKSXTnivDP9Eib2+UE7M+6k9Reu9ZnO+E5sHbmJNcfYjBNSLna/ukM0YBhe5EIKCs39/b/N4GatbVzUvdncBP
# DATA Jn2wubv+wcONByiH9U/UfRIfP9x8tLlHT/NXYzCfwNONTx9v7tDT0bB9TNmDbBUmn4+dO/bYMOD5tndzZ2T4fDh6OdR6gUTXtERI
# DATA FCcASKja6WHiZFp09kZS3LiNBQh2bDWreyXgs/Z00jk66nd1Gbmsq8ndFjUBf3x7dfX9tW9/+/qtm+/fXP32t9f0rQVLYQ8iheaN
# DATA bnOIXp4J90Lt3RncYAuziOBP++wUZbPIyNqwe6dtXYwGkQ5H9DzNGrPxWMnCFhJL12duKFvb7Z2NXUV91Vo+WP8M/vlkY+O78O+j
# DATA 7a29j+GPzzbWd+RlpWyhCtXaaAI+ydh8YrtFbjKdCRw6DJg/CHoEXAAbktZKM3rbzzumHo3mjZ8lh3l3BNH4pqA8Bpy7iHbcPszk
# DATA vt6SBwdyt9rH2CGzu61O3m98e6v98fbDB1D/aZHoM3AHDV0v6LgCX+uxItfc4CAPU/7S0hFLoMiIbGgU5WSE1ZZQGt/PJyPFQDvD
# DATA IoGwUDywjKUhSUUj2Xh13JkV6Cje7VLahRP1O6EGEj7gDeeCC5v5Xstv1Bw4NZtrvrsIzzPuKUthNPk4jwcS4cKYQhV+ytTsMp0z
# DATA 5/6kt8gVuUc8Fyt/yXb03NKkJ5gaW398xyLHJEez6QyXaghmqCJBP1OrV5LX69hWtUYr6HbFHnpSgGMOJW1RAk3yI7W4d5S8PFXX
# DATA euriSec0Ua0OiRd0Bgh6kBRjEPg17eg8Q+/LJYcVn1m21WTnYL3FdYprQ9vX4QJr5Qw6D/QqpbwTlgbxY22AuK6I3fLa9eUba3vX
# DATA bzRvfVv93/cDDImUe/oQVvMDCJNU7TEJd97tasLRNBMLTgLIwjaBPg47g13g64gFBOIqZs0DP6Ya8vssC1CuUmG5ApdjMxJFChmY
# DATA Mo1xLtI+99qdaRqIafv67To6NQZzJ74Vubz6iBliW+BnqcwWMhPEtAUe4TUulSXLak1fDCACEmdt9AMyihfHnd7oJURIFmIYtpqL
# DATA kO8xaHa6o0FTnAUWuVDryog8pH2W6cT5OyV1YXKRuo6xhbjDmu01Gfbx5xO1cKB3qomhaE2fHeBj/QRLyqF6xYvCFnVRFXTfNOvj
# DATA +fTjN7z7glZ4c+l9XQu5udEoMz/PQCSysFqjbfpm1ZCuylHk5rKz5rage+qeBrqGyBAQ7uO3ULZRt30qAb9uXF+kz491X40+1hFV
# DATA pZjKASzqTxRVJzmnYnNJJx8lGiKcosBUECxVvGdboyTcwlKzK/OHCKnfQX4p12pbWVb4/bTVe008sgbCVQp1qobBU3/uL68d+Puk
# DATA 8tqwdrt++ybcG1Rz2SILI+OMSY2r9X2dpDgGMxHsCNIZD/Jnne5pxDmUJzBcnhSrwH2HwZGzw/D6VjeczbiUYbYevomBbWbYy3s8
# DATA mm8m983SJEooUptliipK7aiV5C/UGF4e51T/CWpukAN3AAQKvIBAguELOd4fiRL180EPpUznymYPTkhWXMqB1FSP1vLLeoyBlXGu
# DATA A0MUGYKaeuWQJH6j54WsCHqbgZshSDX6LeJh+/dtnHy8tBpw5yj7Bv6EtdnXpl5ZJDDb2brV5PSfDZEdnRVqZmknuKqNwslFWJDb
# DATA BkJ2mcMTZeKIznkuNxRwPNvD6EcHSLR0t2zcjSY/bWi01hn3nau3JpPqudbq1lD7BIF1EGCAZuaVw9NlvXcwHMGhCSCSmTipzlEO
# DATA hjFrJpBAJ9b0KX3QjZU0zOsudElqWdQebBOPoXGI5JqHcLR0iEmBemaUF8G+g5YdSMFLtgyYS8ujR0dHRS7U5Kv1ZI28INxKNcDW
# DATA 3Ln6DtXY0ppD+omAQn+Ewp15Q9W7jA1l3DjoDb4i1Mz9FH+5WdqcF7i58YswBgAKWhUOotJAmofFqCpOPzsfaBhSdZlDQzSu0B3S
# DATA BuqHnQTR+xJ17+6PeqkXQgdetQw/us+9OQhDMkOVU0aYab6ZqLzfD2ZkLMlZFKOmMYqvQBwz6IPJG+fFH+ZDcJ+sxfqR3aG50HcX
# DATA +JH5mRSxBIYQ45K4fT5UQvFznxU6EwLdFNXci9VSpk7RXn962LRGlvOLeq8E3YtXuoFV8B0UlN45GKdYp4Fe7A7ENvs3LVPLOnz/
# DATA jAfX1KeVN26T+nDuUAwsonHRZkPPlx3j0sgNcjYdz6Zl+ezK7MnkDWO6jNoAWINDsCWreg5H4E0DtaUliYqdxhVdGw1eaMOfKct4
# DATA EjI/eT1BH2cNXFVPfLCJ/pH4Xg4KfWuHpzXxVvECqD9bRKWqxqVu8AnYCU7hIuNMgA4aKxrdY9WhmiCyomu8nVrgK0Hjpydt4+0g
# DATA JV9RzOFIYH8X7jYENHv/ye5ee/3xZntv+7sbW0Bcd3TiRvSBIvNwYhKyaRVxy6nq0frO9z9Y32o/2d3Y2Vp/hOoXrTPt9JTwpGow
# DATA Lj0iGZ0R4+PVPV7f3f1ke+eBrE5/An0Sk2OcCvinYRkgoRmegX1ZwaLmWLB6Qv8p73RN09o5W+WRv4JMAKHbbaqI+AJe/QuMm7UK
# DATA sCjj6rMosUyfAJSFZc/7ad+TNORlBLahlX9aLe3TTF+0sUIr+FD92Xw1MH1O5e2NCs8L1NOTWT4t01djdcUEfe8Wmxj7h6y3XfR/
# DATA JIDV6mSpLFhY2Lciq2ZT2EZF8OK4cwqG2rpU7brWl8jk8EOr79TewvpOpu4WcC3zrb4UHeGuLsl44kFd90nI/gcBgLKpTMpfGnZN
# DATA X1p0IVNltjDvFZQAp5Jgv8jS3+sfHeUI80U3gjvY6EjNGfASJfF63Bjdyk3yau4KHgue+1RPvnqo/5ThJM3ocAVOtbbjusNwQ++0
# DATA i3M9AQeOUm9nrA43le2yd8B9gYIyZ2MKpWSeb7TbQ6171DYUJtE0rel5KYOWyMmWLdOJSKn3MGn4h3qCGxVzNTb9nXuulXpgVzpi
# DATA QaGZnFkh4xykw07vVD1UN1iMqZztX9ULcpUSHM00qgIU17pdSk/RVeIJfTrnM1DUKbY9Lbh56n52nsouovIGvQKZbFA6DFVF0xj+
# DATA be4aw5Oprnk07PEkVz14djw1dnPJEdV9nYTnRrKDlo/ELoMbuNKbnLaV0OPHIKQP1Oqp5yYQjgzzRAbDo+OGtpugklNFWGHM5NSZ
# DATA 3peuxWjMnx6rQwJd+w7u9ER9AGwO7QunoLD2u3UfNuigfLwQQyU6w9IHKOZZOwwq7ANUivKC6wc0jfjLpoNBZAhed3lRQ2IANlDK
# DATA K8Rk4uCONmNHyGI5XbdIh9W01rrURlAMo5e6UncrT4IqER7osFqKHFTDtMzdm/HWvpmsW98ksK8o+XcwUuyWdUyJwSIhD3R0JAac
# DATA jmG3DzDQiJOdHCoBtTc4pTtgI9qQE5L89lMcn2Z97dXci19XMa/yo3yfx0vabAj37cP+nuRw/sbmnE9Hdj6i8eyw1Y0VxKZfDseE
# DATA aukLdF1Xbc9MZeUxl7n5rFvf9hUb6uZ22Eh2NL924JVie6+ESeoB8Bk/iLJLloUj7FFw7wiDY2UoszhqqpQb7n68fv3W7d0nj3bR
# DATA r4VSW3EYRKM47qiXtbGHbHqcv+r1n8HxRDVPgsxjTHkR1e+nw5TMQSgBoz5e3NyeDUaHtfQak/4sc3koUeQeczGepqu8ha4eAKuT
# DATA nFEWMs+pmHZrc8rQQyhguY6/FnMZXWeCOmsyf91JxHSjXqnApmfqMVjfWfRiPqUkPzqmox4eqjQafX2pwOswjBflIXCoTf3o5zuR
# DATA 4oLsRL8pacW9Si3UEmkOFm0Ary7LcHXR8dzoOacmraOmvbWmbuixRlBKCyOipe+X1h3aysTrsu4o8WSZ8MhiocyxnpyimaA08Dn8
# DATA QN+ElvkmVPW1DmSOxjDDTltDLbl7B4RHt1ZXhfyg45HtZDeTtf/+k//lFvgB0n3T2BQjdzqTqoQDSecGdM6Ls7zgXUQEY6L78B/v
# DATA bm89QPjl0qsKEZzL3TjMU0NkMG0DSZUoX4Lehrz0GsLMJQgANq+kYUD2VFW0OBxKNZuVx46uLRhi+S/6f35qjK8//vP9G6ur1934
# DATA z7W1tRs3/hD/+fuN/9x+OUxGQyVMTxHEqJcnz2adSS9Be8Wd5HmejzHKCQ6Y4iGIIoB+KafWB+qFOpBQPBoJijc8TislQjj5CSER
# DATA mLhMdRSHI/2jP+akc28fGXo8yF/ZH7Npf2B+TTsm1tPmeDFxpPnJGEjF0tIeuBgmOs0f6IkJ7g1nK13a2d7e05p6Ags15ZYROc7A
# DATA cWRLDzY+XH/ycK+9/cnWxk6bv0xXRuOp/ShderK16dVYIFHq8b9lDTQ08lO2dH97a29n+2H78c42gOe5tc2OXq7IDG+Nnl8jLNFk
# DATA BD3e3dzbuGwtBQnsj9Y/bcPn7Q8+29vYBW9GG+FiXsJzJfvi2Nt7G5/ixKTp/pNhf3qw9ECIYVZbj3uW1VC4GEvrcJdsDfPpy9Hk
# DATA OTD2Brvy9ADKfqInaOkD9KhqnSghpI+WZy63tM+J8Q6WgNm11E0PcrotbbzKu7vgL9gyh4kPUlK14ivYK0V0NQTqEvlCYjeBxbSU
# DATA sLK0v0kArgdLn3SASX1wGumYmgu9Fhsfbn4Ks7NvZ2ILZgKDFA+eQpbVAWSV0I8UFzyEpXg6lNIsYRv0aBJNCdj6RSsVxrBrIGK4
# DATA iZIw+spB0yQnAjeRE32HPJpDteDUcxXdzhh8Pdskm9LDijyZ1Dr+V+Zp0tI8L7gTBWJcMg0tafTHbackpoLqd6fSPmNDL+AG2n81
# DATA yBHRZTVBaG180S/auD7dTjF1H88w1yTeNPxbjcSyW0+4WJdDYzcfQz1q/ob5VLrkpI6ZklK/Q1uZSS6nlhSMfqoSNZjiGEFe1Kwf
# DATA Tvo9dWGsJxgrik9bqyYUnWAi9VTgb5aN4Wu0KOElEjwZTKVZ8uPk7Pr1c8e0y2/uJbdvapshXBlq40wrv/uUPtOIxmP4z+1bt27c
# DATA sndWqqVqxrTOGdgRlnYtzDxc6Mja9W/pnlT7fDWa4PVVX7sFTl+HlJr3EHqjK1ukPw+QrPAn2jOzc9IfoGdyf3wbgyrTZkpeCBY7
# DATA sz9OXTvnUXpGH54nBezX5AyLn4MbOYS6shhPruWtpJb2+0eoADhDbQBcr0iXICNFxajEkuoBUhaqxDSBMjm/1PnBjZ8TrKrdTLHl
# DATA xcAMW8Ss8yLzSHRKuA4wQcKJmXbHSQ+rPLPVm14jfoBtVfabz82Rop3kg9GH83WG/Pw8OTtbAl8dVc8JQbeqJzhOLNZmVnEnORp0
# DATA 1J2Pic6d5Px8KcG04Hz9gGroMyUtgCbzeDTSVxN16xhNwM1ueW1VXVXB0H/K/b6jvtJLeHUwusqP1dPu1OBJ0+T0JqOxen5GewV0
# DATA 02JGzpIzu/YnnTFcsep8orJz1Vtbsf3q39oxm7dnPOXnsgs5Oq/0i+O8V9fpfLvamE/hFSAOmkpO8mknGdxEb1BFeF/cXu53T9QZ
# DATA V/95cZtmSfV42Fse5v1nx4ejyXIBkwIe6fJhpwc2TXw2UZOe6ycwHHWo1BSPyT3k+q1bF23c0bsMJ3lHLSbmGRx3INvN8nQ0Wj7s
# DATA PyM2s6z9TzCXtFor6ItqQH1w4swtrZHdG0cUmF+yO/TbOftjgZ1w6ZU6Y1pyLjuv/g/kDAPt2AW9q1GTMXMAJrDE3ts6dDOAKEkV
# DATA pW4rIXRr4/7e5vYWxfCxf65Dum0l6MB0kyBozEPw41Wctdd/Bh8KdQJ0Br2mQK3glo9hSwEdRGRhcMRTwkmKclwBgpzicJSScw96
# DATA OO2pDUcdhfLxBNUOT8ET9bT3XoqJjqOJM53OQiE9E/umtwESa3nWScdjkG0dmmzbWC/0zMChkuxLuUaR5WPQIaP507bE8MRJX612
# DATA i3kZvPyhNyF25frStVbaySQ4cWnbnJIboBpURboNb+IoK1jBNjbaVNuc1UmGblg/N5wBrdnnzw3MfYNvANyNBhVvsLefl8HJ+58e
# DATA xioyGzL5baFND3VtPGPMeg4niH1IpTZ76cF+c+26XmUtyREzJiptpDUj1FHea2RZahYHRhYRThk4ucOjKcWPEoQHfkDzm8MD5HNa
# DATA cndFXF1TgzqEwfOYyKWs2iJ1KxIf+vx9h8CStG2rMyQ5AZc8UXVTdfqMdoZFR9OQ2lHay9GbMGTXTwmmPtZxFM+Z74NIg1NmNKR6
# DATA OMtd/O8R/jflS4xoPwu/qCjLGf2Ajb7sD3ujlzWAkeC/jcf9OjKRnhm16iVF9HQHIwiCQ497Nar7ircdjlCSAl0MYLIkfOKT7qSj
# DATA iHrRMLeTy618dMGqqltoxS+36uIkqEnaGiWjl+DpTtqnPjhy4X0YbKDqxkieWvpKXSh+1wd4UMCgrJyUAqfCm5LUSD7pYvOD3kJ2
# DATA aWMRASJM9Mn42aSDZymhFE48JnQgAEcxDYBEhxydhKYF7dhEp41rSPDmst1Yc1EoIZtMQo7mQsS9sGj7VKC8UL1qLUDwgh66dZOE
# DATA WyFTyrqy8HTRScdIdzoUcxYrRTn3Wwg+cJ7GyVp0oWSjapYu1yLPEfy5duuE+qCpgITWZr0Ce9oCvKjxI8ZopSrXYXkx2smPZoSd
# DATA knB5fbvs1VE1OZp00EFYqykbJ89BNTgGy28LmyJXYIRcOOq/aqUN3IvLMYhxD/n0qGcRT6FuD/EUWqMxk77FvDU+vaaDNBNOCYNS
# DATA YctYeHHETBucOidwVFCgFyfzNN/58kKhE/baEjopLSDicnZLe1VE4D00Bl1CqWmX9eu+GasegoYGNdmNl8d9JYOm6pmLkKEelObc
# DATA pkEH/t76OW2b4DUHBnpF0CU88jXQsRoIdu2ZGsMVvB4oSSxXv+aUx4j8P0pWR6vXr1fNz5MhhAIlTz78JBHrpeuVoYfUkE4FK8yg
# DATA 6rrIQFy6EHXDJ//wtLHb3tzd2fiopr/SfcXRyIclA/a/C8f4FuOkI/5V64RRyqZQZDtl6KkCil1KvOtPN3k8OtMLM2Cs4mvXvdy8
# DATA ZXXUdBC063/l3sXUN0W3A/pHnBAUBtP91eVvg6bv1vmK4lZPwZWA6soqKTDMOPcE83fMhic8O+SoVMQIqaOL8mARiEtQjZoqsxOo
# DATA JB/vJSn3M/NzfdXUsSb0fmBAs7HOVhdb8/KvIQnLAl+hj5id9DiQna1WpJ23nH3RtjhUH1edifgi+SmcDoadqzz9X8EISkcR94rz
# DATA NgTvyXe05jJHBxvzTH5nshawpeBSPNCYB8Gn6GT0IneQnC7LoRgpvGmJwcVMFaz0DLxxhKFC/br+tRgqkILyNPkWi///cWAzUIcr
# DATA GV5h1lPdidp6Taso/r80Ju2/Q/Z1D7jXBdh3fJLmMVXhtaVYHIK9OdrHpz7Hv0/NPHWZPjfusvvHuBRsgqoBn+wsH60vf9horhy8
# DATA l2nGX7MMtPadZt3+yr6T+RzVXxXs5dw5CienkuP6O0lTB2wMNKoujh7QJxIh7EdXWkxb4M5NFARsJ+jpSNVcP9BoEnXwmsUvvNO/
# DATA +GgO88EIwrWmI9WR0fQYw71QxyFDzBTNBREuvp6phdRVV3ETeBYhvw7juFbbjzC2AzEzKH7tQ4ZYy+zAvSa1qDLpdIS8cHiaGlak
# DATA /psJlF/0bpAHdy7zxWEwL+JRuCm153B3j9MyHIAOdv3KGK8ZtzMOs7PiMiGNL5BO5klXYfUlUzVX+nCxQ9ATRd6wzblAV6/glDSX
# DATA Ltwjb46P0v0zNXPnFyVKbAQ3dxC0dJcYO6OS84ILaTfjQnnR9Hb3xK3ILLMENsg7w9m4PcbkzIRgrB30nbML77SXlZN6joL2SYHU
# DATA OSxGg5maXgLCaTTYu4B0PtOigmkfaYbEPcKvmjDN0+NzgSzVVRsBk2EjlNS1CcTeFDmlw2OJAQwX8POgImAVsUtbtrbGwGPePM+Q
# DATA 8nZrNP0QPAwjIUQBTBQD4CG/f7j13Rq0Y3j9HAIdTAELWWoWTD/PJRwUylgmIN/ODJ4O0JtN7GLKHppesbCxGrMyOV034oaOja2F
# DATA rWE0newShdc5lZi5+d7ep1kWb9avwpGhHmzuuHMar4RwP7yKaoE05tQE06UfIJWCka3JpyxcuV6DWXbhdUXOKxcntsJ8XGFqvbOK
# DATA YN50VglWxeuQc2CDAx7hA/EsVtgA56ja3nr4mZ+lyv7e+gBySjn0qeLc+EDaVcmtJocxXS8fXvgGTy1yFvjPcFTLquXv0hUXRyGJ
# DATA 7vxFd0cEK3OxHeERO4HGbyTvGvmWOLjt7K0ARbOFm78vd6KBY/d6wAuFV4sexlCo2/L0aPlbFmCZN1f3uD/oTXjT8P6r5CyWJUsO
# DATA Eopj3AX2HNDNWF8CvXcKPD4Tah9jPBT/dpDigHfAQwTaCt5Ktw9uJAPgU+MDXBY26MzqnppIdTE4dZa1iKyrGYzmqNizhpvMNJhE
# DATA /ELOIn3FV+2jEcjI+mJeMPOOtDnJDYwA/nYWW5fwxQMlyPhI5qilYNDAEssCYVtdxKhguL81Kzh5g9xuoVGyFttw4MAe33B8phxi
# DATA iu7uK4TvlutwybXbN75108LRwGeBuO/TMujcuNOfFJguvojBuQvnEAaFq2sMsCH6ZoTbkuHhqIoFdqLAfCIrLzliIR6Cr30lUD+A
# DATA lHMAFwNIP4OhnLuJvsl/enQIOYbaOPQ2OJK18E/niEt4uClm0UWIuEV2hRiF73isHvGmQFM9if41+HvShoyEdr+ivdw8r2qWBP2B
# DATA GobaiezxXCTLy/g1JZRlqKCXlH4GNOXO9sNDLTrRsJJxsCstblLmTLK3yZeEeOkYG2jTojcRtriD/UMlEvwMNqvrgqpVFFiLzm17
# DATA kBkUvWmne9xm3GMxIlTPwppfZn53qDquvXKGw73D7aKHfBY3tqT75El9sG9RNFfrt6+fp363q7cdD1t/4y36O1hwUq50EZeBql0h
# DATA Q3+q/uBWaU+gSATRwFAYI7tV1xrFcRpKc0Zn55A4qsGhaiyqPRn2TXxkAGqhl4o7oANSe02pA6PkLKWYG2W6ElEKHRpVl6modHKE
# DATA WC/FqgoZGaw7QTqpxTuoO1QDPo/V4zG5kbALZrHfvI74gfupF5t22CmOnw7ZdydZzmdPh4hO59BS2IhUDajoEMMb5BOAyM67SWo2
# DATA qykD46ISoBnIIil5aSzRiQVQCrjVtEx9+7eaGlvW2RCIjIUWCYg4Y+Uhf26rVq+IllEh+K8uBIqMov+KA2TGs2F3OiOYiu5xZ1K0
# DATA 0jt/9OO792pZ6tUGJpZpXozBZxBbVdVDHV4paCXHZAcYWeXcVMFlqobFGKYPh8J2Ev/UczcOwOEVS85zn3RRJtUHzrJ9k/F8/w1q
# DATA MQjTDH7/e+f3ovVDh0cTkLk6kJcQBnQX0iqhUkM/MxVTfASD9/Kzwr9plm4Tb6vwQbck7oI7jX0Aic8ZOqWuDYNihV/iSeG/Lemm
# DATA buOpaqlTxe/rTL4cgAXbnHEZ2E/9kDb0M9tMkfbXNCmcHb1s62g2RJEyOd9Nd+kpuGb5PfB7ihY5MtEjJaC/LzZfIP9QMjiM4F+G
# DATA 3wzaofsM/y7DdRdIOPVOHbFpaVH0ysSyGhxXJy6ITSsNatjLYRbFiOjKdNxHhzl4exff8uZqunCsOB9Y7AB2IA2KVDrw6Xtgi5Sf
# DATA 4zv5GRTBdcdP950afahTKt9Krlcox82Y9e3FqTGLV7imF7iCGcI6E+Opdhj2WI2HAUvCjIMGqpuJcxPDSYg9gMMFkl5UIZvBZoyj
# DATA 4mBQMnPeRufUidst6od6jpHIJqP8ywnM2gRXSfNFXJjgMo8nRovoUuLrjPvkCdL86oTf6QRiXXptW3lMuDWn1ikdtVYEpUK52Ee5
# DATA Vgv20YyCYIwwYRoHdGdkOCKph6k4DKKO42hDQhQCXn8WbQgAylnQN8KxH4qtkdJ4UcyNAI+hPy/RW+ulu9IZAmocRkchvgVe1nWH
# DATA UradPEbXAp3iKfcCZPTS7rvFA2R8KfiTWwgCNmtgYBPlaXwnHI3FOCMXfM9NQn8tXDNg9WyF8yypIlkTzHPijMFRzcnlcQAma9QU
# DATA pbrThXRGCtNLVFlHCoKmMtA7z9nCeqUsqCgZ7qODKBtDLNcbNkuyIZMk2kq8FAA7qYQbeYSg3Tu2QyNCV0uXonXWYpWmlccfuUeJ
# DATA YOZud9NHBv7hsywOEXaTTvwF6c7vbd5Kt4BcYpMDE/kEXbyLrpJJtKJlKexlfOpcyoTAHXfAVstkAxwmhiNve3nqRbLGFprrCK9D
# DATA HTJ/MnoBsDlG80tYXeIBB+U6fF5CRNTBKUZffMeEfdlyFZyC2WAPoK/AeLPMUby4QP22r0ZD05/mpZvCtA1bjPrcSiR8Amfd5GLS
# DATA dhyIQzglWhryBlub5yCYZZWyFkcGcl4q9vVmpxGxo8xwtEwB363oDLS9vkDSTUMVVjhD2j/FW0gPNESspRbv+LtSjwWH6+jYO7Ej
# DATA MfOEh2nsOvH4GjIXbZKmoW37X0tL/J9KPA3SuRfJo/QC3ghzawu9FZzYv6zc3xccaAxLMgNuBZMQQ2v09mywrrXA1Yd9OWKePmUO
# DATA SVm2EO6jt8fve65RYpdrVkCzvYLfVW5yozqn8WrsxcKne4POsJTmaaJYF7RuAYK5pCNh/PSKQm0ciILcUNCkY1gxVj4QbNmYMhmN
# DATA +6hbAnScBuhNEOuthj81DGSjJ1ODgV1aCTlBrVyXdLGMOxZCEPnpsuMVuAxegQ2APk7J96Phon9Kp7+EO2F8VOe5dIDvm/bgK/co
# DATA YSgXH9aF/6z1xzZX7TLiIhCqhfqBhp8xcZP+OHBBialtynxPbG0oY+p+gI8MxGZcgTB2MFmP4U/UMlAJkUi3QcF82bxpwVVQo2Xb
# DATA 2REvy1l/fN6AmLalMB25Q9KxeD25ufrt23LIhjMfpQbx6OnQoBw9HhWMdIQR8qqhZPmoGunI7ZcktCEeij9hiqrd9nBRtFMWkPhJ
# DATA RRRi7TtNDET8MUMqZIkPo2KDQtSqnychA5hIhJGbN29w+GLCCtPk6qS73O2oKtRwvdqWVfGrDuUGg5yizS86k34HV6M2N4RSbRPu
# DATA Ks/LeeL2p4pnHaUGAQKTV7F9l9LaVo5ErVTYfcz927Z7CU6Rvi/xdtcv/auWQz5StS4ph2IDbcrO1upoGNIp5v0m7YRFNgeBQgCF
# DATA mHecnB62Wt5yOMnAZLPuIfQnwVGm96MeQni+JHfGjjgVhUGURQOimxVT3KdK8AiF2RMqehphsOD0ctKZAB8FT2SiH8jtkS+YPdaE
# DATA neWrIYpjNcldit0+zA0UdXoBIfZIiQvQJPHGKkMR9UdtQx3YOOwH5AsYnO8jQOWIFyJSnHA/wVnlnsD7TOSEhc+igqsvogDkXOIL
# DATA J2WGuON8MHYMlY6rg9WY695z+bKLS43euxaSKILj0+FXAOEIxAAKB7vsajUIouoMqq9pcNEKLgCT6NSWxQ4OL1XJNC9426LOLrDG
# DATA 0TaFF4sjjZYKeUtL/9ZDvpRC6mDUNSHhjEB51B1OB2S4VS/b7Gqo24dnaeiSY4qaLEmh06Epw56H93c21ve0o+HOg0925jkhgpr8
# DATA tlaTu87untOgbf/37THoum9e1HUQpgywzfXMST8zXKfGEa6g9Kuk5zBf7Y1PbfFTcBCKR7tDAD3YoJxpiytx2uR2r13sC9dDRD+N
# DATA mv4uEZ9XDvHBUST64Iio2aKJLfUhkMcQGe+KUtdSUazHlZGZ1+BDKXepq4YJe6ApUxSfgmxqMftKi7I1RgASL+Rlo308q9xrLm23
# DATA WarQbwttjtSuGfPRUvDKv75exAXqAipXNpttjaRDWahmDcWMO9Yl/3lfEdvQi85BW2nXqy/vcOv31zgLJ63sPPk+Onc0yN5+MLRR
# DATA qFY2Q4CdSn07yKJ2bPy4bhPVLG4g9Ddrzzegy1QUvrdBtW7Euv3G+NO8zVO9gSr2SNVEVu6Ft5zE8oksn8xIL8pYv78rS+bbDZsr
# DATA bFhGSKkXRmC6HHnmnqB6qSx6b1hLCY26Ox0gZe4XGoVqWQl0qFycj1MthDMBepamlzmoUu8FTq8N0G0+z0+LmuSQMY5RGjwYGWZH
# DATA NT9cVvcqSPjkNm4DYVQPavN0dXWvQ9E8TTaPy+QE1WhLkfRLjBlYkvtGZhVrIMq6vtHX8FdjY2t7Y2uvnphfexuPHu99Zh5sfLq5
# DATA u1eV0KicVNIB8CxvtICK3FMkrHGeIBQsk7JBJ/RyKSgDrwH6l44elSy8btAOSEdPDMCefAlbXYEuoOYL5OwgBh+lfweYpNICQMWD
# DATA UHwUZr1XUqadA0xCkinNpZ9WFWulVLA226uXCNb4d77oj2ZFO+JuHr3kyKh0VKrGS5nJQYXemYEKtYuCge6y8TJDkTA58Zfa/QLr
# DATA dl5ZZxlc55I2rHcLApIm2q2EvnFqB0VTIKt5fjQu2jYkFzOYqUtag4kwnA5OdzlGt7sybwnzCAQOrRPBLbmeREMxgEIdBBYErMaN
# DATA 6y4HMltgxwrsgxGG5pxRDCrW6qMJyXglCxQU9k/761G+HmseDBBF/MhsZw/5+gK/tjiQilOFHwEdmXvcVO02zEO77Z6qko+dVRL4
# DATA 3mdsJm0a811RHNP5aepdJmzszUSCn7nnrekOQ722R6Upzsh50ElS0Rll3GV4Z1gyH+pNflkRgnBTpWNuJJA7YLnemgt2G9zV3Wus
# DATA 0Yoj8GMDI4xicEO85SoTNi4snVRbXkUYvuyiL8HKSdOUhxF5SRrlR2WAq766Wg1/HylJ+QArhcd5Cx6hdIvuuJJPJVaSkxcOU8Bd
# DATA KjkcvvcSjRF0rJMdDcUYGjTuOx6/4iAIVaD1Fykfx94ynXfUg4D/6TJ7pdJ3wGPSunB7Nj9QqYRxFf2paMTgOB1UdHuZG60sgoRl
# DATA eUyePGHSuNXKj9VdzP8UErvFC/eHqMQOPqhqIFDIlA3UiUDSqd6obCzfG2Zm0+jFLbME4TUcuT9l3SZCvX/9OqYA51zcQgIoC+9x
# DATA oIpAhmyW5y1Ld1ia8fKIRLost5WEFSfJWAb74ZdCFnIlggAlhF34rUgdDsnvi7enZeS8Ex/n9cTkM6eQswUag6uPe7r40Lne+eHy
# DATA YiHyEXX74PgF03eVOrJ52pP5GpR3okWJ6DD0zm84snSJCB16Ymdv6Q7mzh1jLu2vHnjpAh0vZYSYxJaQJ62aCq0COL5ldDvhKVxw
# DATA x3pk1OJ2VN6M4sisvs0H0MOP+q8g9ED1eJkWVUBtvBgBxD+o5VbQVjlRbLxIOt3JqLAI2hOLGx7cZ7+GO6Zu9sI34Ev3DeZDWLoc
# DATA Y9mi1i7HuuXhZkBFZeDI0g7EsEdxC1BkJ5EkEHem3KfAdRA2TQh7LbaBmTdqHOIjXdwaDSCa0l6GzKFDbYrkT955MHfWUiaAJvY5
# DATA xyNOAi+kdvAJpEk0L6hVZbC2udX7IxFXewxycOgQ68sqyVhzEcqqvR4vnY5PVlZtxxOzBAUlDm85Gqp3w3WdcevxYJIKTLJoeesw
# DATA ebHbLj7P5mw5FHC9jSbQv0vpvHa/WJBwv7tNXKr5tQfTX4XKQcxHLyubm3K//AU0vyXnn2417/rgz1O7lWgESAwP9rQHIIuhAVjE
# DATA KFMOskyo68rnqWJvoshZdjHzNpbMKhLwCVPFAlmfOdHzN/7wv3/F/0MvLTjnX1Hu57n5n9dW195fu+Xlf169/v6tP+R//jr+5ydl
# DATA 1r+L6cXyM3dB1VJEszUfdwpIxGx+Tk8GF8zbXE8ezyb5Y8C/KEnjnHeVOFVEUzefmsczdb1QZPH++t76w+2P2o/X9z7WopZVuFuT
# DATA bGrORluJXp3B6Bn5EIKrmK5D5yy+zgmLZd7iR+tbmx9u7O7ZxMbgqIqvwIT6cJ2e3qZHGDmmUx3fvhmmRYZkCKJ2NLtubn1kvlHv
# DATA 3Rf6w9s3I50zpR5sPMZp+NbS7p7qUXtr/RE6cjZMOhNiuEt/vP1kZ2v9YaTAssh9xYXxUhOpitwSdzbub2w+3jMFbE2Hne7z2Zgr
# DATA 2X74oL279+QDwKRJ717pjXCT4Qa6dxf+mww6w2etq/nw6r27mN4RoVDyaesqQuSppxjkdY9jGO6u0M+7Y/0ELj/Ww/Xuyvje3RWs
# DATA HiIUNh9sbO1tfri5sUPhL93RybgPkgJCG2lcI4Q1uvn++dPvq63x8cankbJHiIl9+yaV2dv+7sZWaakb16nUxqd7G1u7m9tbuwhi
# DATA 0YBeYcRKtygooyf9U7x4hv9OX035MQrGaeMVl3+ZH6qj2j9SwlZ6rnZ/d9ApimRXTTZdmO3d2ei1Cx0i1Q5h1HwItbnwadXQaayc
# DATA NL1JHzx5/HDzPmzEP97d3mp/d+Mzx4YTB0pzQdK47zAThMjYjNr2hL6I8NMOT6eBGwgD1UXhF73wrQXw2NoCkE1ndJTIT3yhgZE/
# DATA yMXTnbw7w3AHWqeIJ0cwj5tb31t/uPkAZ1HdbZGy4jd6epDEeWiCXrC/zYKdObkPIEafMQfVr7VvobomffoUw57wRUXHnmztrn+4
# DATA 0V7f3d3YQxKcZg62sST0MoMUXL/iEMdwaSfMySsa7VAjExjQY4AnuOUDBc3NAn0gE0LjQf825oOGKqOwRvACJuGMQk4ajfScIt0m
# DATA UwE01YinlPS6UftOU7HaH48nwx93Zq9+PJwNfqzoxf6a6taPB+Mp/pGpQk8bjWvZd7hXcNtubIZXsiPuhQsFnZkwvGJ2dNR/pbbv
# DATA S7gmaY2GJULZJVY0ghnZ7o3w1nHhfecsK++9e8n1WzcWOAIPth+tb27F8vEYYoY1NiaQ732M66NWiw57vzfsqJ/67HeKbr+vfvNE
# DATA lUG4XeSE6u7JMyox0jinOw23Knk571m1JSRrur12rt/gLlGsTtpcykPHYLKhrCXdOuVBI82y7KITH6XRoKoNcGkdH6x3AHiuNznc
# DATA gU1NDbXTjp1kuWX7mkL67bb+Hx0AHabjmRKWpopswguw+05J/IVn/UM1lQVqLEDd/urm6uoclo0TtPvZo4ebW991PUTj+OTVWOJz
# DATA GpOLsr51X4nX2ztuo7VRQY6UoPJAzDyyvJQ3GXXUq0Rer0JUX2S2PtnZRL+skiHYeWuJeRP+owVGHb79bGJntrb32urDjfuqH59d
# DATA uCPoLXF5aPeFe6jqe/JwfQevO6Xo7G2yOwkEbKYgktJYRXRwlM1B5pjLa/JAH2RB6ld7cuNK4PZJ53luEfAtYD8iid26VX5akFDZ
# DATA 6gNqhbXjoESddmSxqXG7QgMUmwRNWW0aq8Xwpt+eg9+k1EEJ50sY/9z8nqEnkjqrdsnw2HJ2VPgPMoX2Ua9FLVI94Ury+HxE/vIN
# DATA IBx8KMVty4PY1+RxBJ5u1vJHRDF4/cHm1ro6OPAyZhNsCyR/bC4TmPpK4sg7JxHcWBMiRyUWRNbX0K3iyNlHbvybfT4PM98/jaiV
# DATA eLj5aHMvRMnn3pbh5HeOpvlk7uhiaProXm373B+O6t4Q5O8TCHVoDwlatoatmq/ML/rI/DTfVIgEOP77H69vfbTxIAToL4nhdM5U
# DATA 09vEJg+vYxbXLOyKYWFNN0DQtdIKU2J8Q+MvQ+N9i/ZSZf4Jpj1684ZSdOxuATnjUPjaX2t6OJMac9+2AdcWrNwc+FhcaGkEpHNf
# DATA l6PAlmICV2X8qVYPXJL/l0HDX0QEoCW2nbtwOGhAcyI5p98Jva/IWiLazeZHspTQ54vZLOduj9AyKY+wO9/ijXMciEnROQtcQ6Js
# DATA i9cEdENak1yLKaXGnVMoA9yKALeEotqJAw000NVpXxa5jRJl4zofbe7ubm59FN5Jne4y7FVL99tXkFn8jacTwu12sVBMVmLdLOiq
# DATA 4HfA4rAhCXqgE/iydoALuFDelLwPXyDgCT8F/jeHy+n7qzMnD9S/EltbFZ90BphiFNrYFxC/BgGc0XQAUQMttGBWIVfRGn/P5zLN
# DATA X3QGaVYBvGmraRyOeqd1rOr+CF8TFCemAvGKNdzUIIrbvoOhA3/jsfAo2tB9v20vz+J4UoMPCeSTPnsHfZl0XmKW+1dTo7GR6tm4
# DATA knX3dDjtvIrqVhUfVtN4cTVrpI8RfQ6qczovM8YbcI7womdTCl4sdJGqGyouUaiRPhozfeCpyKcsXF0B20LRPc5POtr/uyCVJe4m
# DATA KLSv3x/4GWbct97BWmimtAg1elmwkn2f+3BQMhIoKuBnHZU0vEONtGNhu2SXImYOVT/eEVUzLihL2EdvstUTnut+D2O0wAxFfvom
# DATA RADR9iAQFec/4FphG/tQ2YGrJrUmK6ka1GWxmPll9Xqx9rSS0WsTTC9e1g9+2iDlqcH11c9hs590XvVPZidlQP0Sld8D5OcJ55qM
# DATA sUlXCNq3mpnONSXbAHqhO6s3bq9mB1l2CWIj43cZyw9nj5apCiaZA7zNJoDXN/Q+pXBjvVGt3fciPcQPnPjiQQ8R22C7uWHHJK+I
# DATA CCTCq4nGIJFVyIXt0yNUDxtdJX9BUxB/N9SN8vjE8Lkxu1HSp69WV1Etq/vBu4R/+sQ7m4PIcvEJ0th8Z2eklT4/d7qjBXscpbDU
# DATA oNk1W1Smp6rbivDc3/h4++GDjZ02gGtufLrn9YRmDiJMat68uqrMFDH0qRfaKENbESb15urN+Kso9ThLO4ej2dRYkvHXimjgvNHH
# DATA BCA5GvJ5my6kn9vZ+HdP1OXygZJUP9rYteKjg79S8O70wvLBE24IXoygA0J52YRtmu3rPtH3kaFnLMRtq5V1pAO3dcJNupEuNBoQ
# DATA t9W6PXy4Caav0PxsKOgBEYRS84Yn6+s8emeKhDUNVdNEjXwAK/hDdi65kHebIEFPnecDqw5Df0ZiRmh1Cyz4MGFNfQSstC6OSB2d
# DATA LTSmIVVTT344G03ZnzczpCE4NDYKOxfYehV0iV0tJYnVVIozbvBeMTbA+WTDdYtnM5aeK+LPs5OqCqu/v4Qct7OxBXRBinGxvUPL
# DATA h95HZt7VXKglmmqFLT0G+Y+tqrzMUqbytonBTueaNOFwZZqI0eW7W9ufbBFl1ZKV23mx34p9Xf2B2XrG4Hc67EpFmNB1tSK6rsV0
# DATA FNXqK9pnF9GHRfXOUc0FKpJgSDGFQzQmuEppI8NxSWQPlDYX0GZ/siMH64S1bHx6/+FXruZm1Q+Ew5Qou1n5S8PGC4n/6mgwK46F
# DATA PGPmO9Ab8xTS+e05Dga8Q2siWIA9DPJhoThIG436LQbsByrUBlgYzrRV5GoXdNQyFa1aWgei3EwznRAmC26d3A/1wUm/y9MhO1Oy
# DATA cnBiRpMO5pDGXSvcEIWjHU7VMkCngi9jA/5zUxH/45zzCvEWMrXV/RmJqG8rNG+LH785akJeO81iRP/CdKvxcPXY13y0xSkvJt22
# DATA c3bVQSqm7ZLjbKlRQ74Kzi0TTGqzxNDHwfimnNkJ/CKq/Hcm/N3Z3wzQXaXdTXSMZy+utlQnDe5+Josnx3zSKChcMsgkDI/LMwkb
# DATA 28Uk76p7n8BIn46mqFOjIE0A1OT0WtyQusmJ/Fn8vunegiYQWD5GMskFGuPRuJZ5G16XdcOSHDbi2FjmcKpgBan+0gNTyrPou6+U
# DATA a3HmZWpUZ20WnYFMu+KXn2yDRxYOPZrRebG8z17+Z94YJv2z5+wMyidc4ntJ6MvcLPVtigtkezsboTnTP1OAhY7DTlZoJLhA8SGQ
# DATA jYlKUWr0aFboeNhUruSm/otcswH9uz0d1RgPEsK61N6rZWUTWO3ogov5Nv4/ZVabOPiIHRiuqEk6kdrQ3LoZdVb+vT7K+nuWknAX
# DATA gIk5/mU59MkCNqcSg6AAjPVc7ZeJfjUrnesuuQktdXyv5XSltHSv/ywvgFJz/EWjOO5cv3W7Vl7/V+EMEYWdeQsHidj/LuA0UbK2
# DATA 79CR4oq7POi3oB/0hyM8go4fg/xC/cyac30zF3FLKD+HNmml2/PKz4jhmo/n9/GQQ+2lQ8iJuqNCEvrbdVtTNt8VldcHa2wulOn1
# DATA bSbIHp3GbAxuVTVseP5HdmaXSc+7wHekpDITtPYVL/5i7jclHf3avW/e5egD9oM4c5bzhMPhPaCuVvRXTQbwRq/2pWLTBRwVWEL2
# DATA SLa5xGkVGYtHWSb7Z3QsiBbjKlmMv7QEp3S8qGPAH5647pgbpb9dGO2WucohzDuiesV9o7s+dzf2zvS7dklL5vP+kDSprIlCZSqq
# DATA oqydDV6ru01ob7uc7dM+xsbxoQ9XhvgDsZTl3hD3bccXsfD5nwThJUZDiAV5Ig5w1txHEWMOFWCFrJ37YAjGvuV8ELFzlbaBq+GN
# DATA 9+ONT8OBYrmFQhDIN33Pqiut5pnlo/4wcTocGsZiRrGIjR2rq+w8lriQIVL2fAFHQ2A4ijwoqXgwOgXYspjW0L5VdxkTp+lIwJgh
# DATA ZoJhl5ENvPxiTSdwchVJUn9JVQR+SRtIfrwYhjAuwnPnzSFBHtaHW5b+vqhFEIaaBqEVj/MJAiiy/0cJSHKc7XzwZPez0M/DudVL
# DATA 2VYiClUJ1REdXWyGpDZiOE0jYJIU9XxSvOhOpsFbeowBuUpmcTJT8KuHamd88BDSeawtoqELIKqcq8UiSTDUvIjfWx8Ei1WNZH2R
# DATA Rbp8po226gtCT9cG+RHE2/WfHU9dRlucFg2gxIrWnDipehSDnb1Ks3gSaAKo6h+yFpgC6hv3Hzx8yHkKZkXexsB6AaVzNBsy+ofZ
# DATA UlwFYT6qDdKZXlfbCoOqdCfNV5VZqZ0GGp3JM+wRJrunvnXbCONofoHDRnssHsx5PVPvD9xWABMGYrxbTiWhfhTmHu+H8Edb63r1
# DATA W1oTeI1/tSNKVN1izakABWNW6cMLymBYd6pxS+EbXew6pbouzTHMYNc9MT61arSo1jiHBSCI1CCu7362a+DWkaaZX9uPt7b3dp88
# DATA fnxesYZ0MPjw1LroogqaP8VHzRNrQkH4fHJqBAVLMVWHA2bK0V7r93YnauZiyntqYfEmphmO+1NsgHplfW9ze4t0Lbsif+3Chyxy
# DATA RuYertLTM/cERUezvrf9aPN+WxuAFb9tP9la/9765kNwAZd+PF/LcVv0yAXHjpadFDP4Z3D05IaBYuJ3u8RwZI6iV6U8ZuzIy+cs
# DATA rNQtLfcaf7Lmw6La4Mmq4xiu6txjZACeShk02rJQqIwds6WQxV5uP5F5i2dOGgW808j2pCvalbnhr1Nbm7i9TwzJINQORMoT4qVr
# DATA +DRuJ0QoRHh/FIqQTA22Mt3LlSSl1ooU/jZCKVznHHqj22uJStD/kZ6D2O9XXrBhQZe2Hh/8fsFg4Q/W73/3yWMEPK0KfqbsM4Gw
# DATA HlcBjAB8ESx1ityBtxg6TIlvA0t0VDUw6bzU1+ySO4JzO7CIMJ6rR9XNP0TmF7l+bboMA9dvHZa6uZK0nA3UmXSPwS7QLNM/cAHV
# DATA V4kpU6GReAc6BdtBo0KoMzbd161LYLycQKXAl3rbUawh3HFliBjVYAzutZYPseMotS8v6qE6Qk8ITtlBkCu2FtUOcOn56gEumGWL
# DATA awjoxKZSkrE7y54C55JMoQf+NpSFSw5HtHQWSWRhNqxHC8DTX55uJHedlyH5RLHFKnl4YuZJXUy+XKVq2ITgD54Kz8YjxDQXFBI5
# DATA Abea3DnsgovUk+noea5EyNGgV0+G+UvGVawzi5IYEXodYqRtyWYdKOk6RR+Lph0xT7AIi0Tcy1/AnIpv3JcL3UppjlEf9tnu3sYj
# DATA IQPq7eE0oTZLTeBkgQsQTpFwa/ACvLkajDRfXXWjccpWUqhx4lvaBJlES7o02GitDRFtJmuajjYr6Vk9EL4kMWtGKJmmxE3cMuHn
# DATA tPebydscJZndhGQizZ/0PiNnGYeHpi9fvqSwM9iEimzFdyoUUC8uFnvMDNGbX9wX6m8+Qiwvca4WEBvkbofcEYMeT5uSp/KX6m84
# DATA cM4UQpnddzCDXq16Ufhsp3S44QH+cS7jpsxuQt6sXW89jL1ryfV5M2i+kNZ27a/nrJwEvCOHzCiEEMlER/1hvzguo2eOHpRvEMLL
# DATA NT+Eze9LX7hzZEbFZ0ERxzkQS8Qog8gYtQhFCZqOah9diop8m3Y/jyZzkh7QK90RVJOoGiJhwJy8j8rV9dT4+sfFOtCC5G0vxRuc
# DATA oYrGjWqPq6jTrGeRaGW6EbmMRkYc8iLX7f4LEgwWRTTHzLytRNX8QJ2QIfrKle5ZqZLk4qH5T7+4tAWQK6iXHMe3F7uJnLl0jKkW
# DATA E6y6oE9GErfk5N3J5AuY7bCznpCKiI+hFYuKZnHZXQz2QCPTy10Qk9zDS3RMml5QoI9jyPkSPqzCQT0xP2gRIiJ/dLZg8RYQ6LFY
# DATA 6SWCFnnhWwQXN61GY6U8aDVLJSVOZ6rHreu8yI1jb2d9a3f9/p6NMNLA5zGDuL3UoFRaentyrw5cEak+F+Eb7sZcuogwGvlUsB0r
# DATA IlrOMpfr5a/GSpTFqEaxD4L8086iMzY7XTzh3OhK3nJd2ouoR+ZdRLqzCeqwWm8lQ7Gd6IXmTtCmw/fq/Nsuf6YNk5DtCcobfxJM
# DATA mhCfzuAaqrtv7pP2vNvUNgPcLHbe8Q3OTEt3YK7an+bVFXUpGaQgOktVgkiVLknuDkcMuICKgOvqmbk3ko1RsJYSJ6EHnvSfYQCX
# DATA e7TcT5dco3g4Lqolq970F7zt2zP2LHfkOL28MOuUzIonImoHMTciHqm8DcX7eIl+WrHRbaWe+AfAF6XjxwTuG94o+QNvV5eP3W7L
# DATA yPUau2objci4KN9GhFHRUx8IrlQcDUz11L6p0924F+ikoED18DxU0KJ69MjgmHHe5XabM/FiiSo0PBcZSmQAkgRiBxfjKmybub/9
# DATA vY2dzyAM/MOHm/f30qyKbpnhzj9e4bDClQwXh2ydJSTLnHbTJ8x0xB/PpZaVA/46eSMXuGIYjpvSt5yLLYRzGuFN89Px6SgwK0tU
# DATA HlHWRtjSrP7MSoUfaazD+fVb0j3g65q0EPpLwZe+M76DsNJIs8/Y3rX6nSR9lg/zCW5J9aE+J57ex3gqNo3AZnwX5wgj5/qWrC7J
# DATA 035nQBHS+rQ6bjj8sDwOzbhkxKO+LhKbbHQOFwlP1h18R7FejppGx1hcPLyLzB+GQXCYP7hcxQK3jvoTDDIZQiImLuH7S2g7PxYt
# DATA T/vrLYr/pUVElKAYcG0Mm672vg4cZLzQLWpu0dCtWPjIWwIuh1C598gm6ESWXCF3W50lI1twoIE2z1lwkJ7E/AaBUazfMmSxoqpY
# DATA SNhiPXIMzWUdc8aOSj39K1DGmd7WQ3C87G1HEAsXXiQOoMrHEIDU8smLmC+vC8GndQY+U3Vti0slk8FKyiysUIToMjOANzPIBJ+a
# DATA zoGOjWRUMCBw/LwI7CPGEbGGvDt24DMcfmY4l2QZnPWUMTXEDcrH12ilE0U0RycYH4Ix5xocQFzUpAmyEokDosdB4chVGdp0OBoN
# DATA Iq7wuhNWLWYekRcAdc3cuKMBAQYpZGF9FED4bOwaYDm7Zo7DjmNws2fDqnIiLuZ8GbOlF1Vd2/DvQHutZiWmuHZC0Gm6bZwL1wa/
# DATA fcnAFKqSKiRhip5PLCWv8q1yz6jANkQYidBjIco5N5ElYa/2WyVZpMz9XwdAvchZ/bOIscp0Sn/nX1bEJEep9wIkgxA2Aoph7l7R
# DATA cC5JLkzv3IAZlyaIQuL5gSQTogg/Ozj3Yz3khrr0BlpsE11I7RjhA7FrRmQUcRVqudi8eOdJWxfZvyRl0RTBW1AOnzkNlIW+7R+4
# DATA Lm31xb4ykX4VwkPd/9y8ccL/SjtQuVVi93x4xshLzmRcZqorgJ4IbXvU75Ibcb+nPuwf9fMJmnLET0aA0t2vzd8kFm8TJFN4Iqpr
# DATA tUI+nllFZpEPtF6/tiC/9+gN8X9O+tegIdZ4pARJZlhmS7BM/Eq/cW7uukdROKwLQ2JJwEgHF0u3I3CxbGz/8xwkCB/XJ7D/Rzhs
# DATA pReAL8P6bkKsJPLSUVwUOHLamagrDsZ7QzdXkgAegzkXFWz4GCUSvAhLmIZ9v1YLinXzpttfBuiwSHJnPLZrEuOHIQQVWaWU3c/y
# DATA xuTZYHRYS6+lWXZeByy+1qBzctjrYLGmn0msrrOEUKRATBPrI6QMc1Z7hc46Fc5QTvxq02xSG8na1JJrPOyZIxqbGujPI3Jl0JuO
# DATA sm3+Pjgva53dsaTnhUMoHaceM0Mlnj2LqOainj2OGcJoaa5EPEAWDS2Xuu6LujG2HfukeBRkE5TSE1O9XiqkxChvQQKX8j0nKmxF
# DATA /OrKhK+yzefIVpExWalKz5QUqjS6Iab+Dq9iVLBuFIdt21rp7SsKlh5+Xe5lECm+8L3po42tjZ11YS7+Sq9Ol71dWCu+6BGVyry4
# DATA CS4qokJkoxr0eUH/CF0ZBuFcKHoiXfRiA55FpffIzLkyVpWL+z9VAfYYP4H2442tBy7erbVmlMjAF1HchIaLyIbF8S3oE8E1LTRO
# DATA u78jpJDN0STmlFvcY46INC+eX4gzXlNYGwSBb+tn4C1LLeqBvZWtm+lRr+2tS9RTn6/F1Ph8LxwbjySb8BfJfS1XS4/Zvxx4PXba
# DATA mytN2misRVkYbxprZ6x7fTC++c6hr+Zr9P1bKgVchYA3jc7Fwpu0ErdkrNPhcnbIUmWAYNABa0P9nxJhX7h5LJW8OEFHKMqz3lif
# DATA PJvBZD/GNzUB9NxKN4mBJ4ezYU+x8USRv84gASKr2UWBhHE0myY4b6DXgpwI0OeiYRLqQs2AMd7ucGO1dHlZ4q6BXrL12KgJyr4g
# DATA abOyjMBZUZPQUTNjlKiV39HsLU/IqXOx/rAEBOylSxNGwsRUbZzq1mCOLvEZb5uFO6jJ87LYRJoPI8Aaf4f/wJcFbpgsmqYaXjeg
# DATA 48H5pwMcXvnRlQI/444HTjn40sniaM396k2MvfhltBiqf7MKvNLuxsOmaFk7r2osP5ypzhSJ2J1IFKNTWTd732wF6IW3T4N5ckRO
# DATA dwLqzmzVSyeB30RVpaEVf/482zlbbL78yeHvO3YKe8lsqO5mMJOwZaDqWaGoasmcOBaR6Jxo0wj+sKYJuQWqZmU86asjIYCXqelF
# DATA kJezgHWszjNjRXBBgg6cpViCmQr+DZf+sD9KLoZ7bgtwBoqpus5Pgg6tKZJvjqtJOAOqNptkRUD2m5N6sBS3ojpVAJA/XFwRfajd
# DATA RkVWuw2r0W6zFwJ0Tcm30xryHDVh37j4/4Cr4Ppr3WFjfPqNd/y/VfW/2zdv4r/qf86/19fWbty88b5+Rs/X1t5//9Y3ktVvfA3/
# DATA mwF2hGr+G/86/+fnXju7Suqpq821+lUUNa4298+u9ntXm1dRsJsq+qCOytX6VcxSoR6//ts3P3nzF6+/ePNnr3/5+ldv/uzNT9/8
# DATA 5PXPk9dfJK9/p/767Zs/Vc/Uk9dfwl+vP3/9W/WxEHigiv9Tvf6n13+vCv+k5Kt6ov79C9XCb978tSry+tfwSjWqiqoqfwWtqf/7
# DATA lXr66zc/U934qfr3b9SHVKMq/ts3f6Ve/uL1Fw3VPKqwrjbPruocKqoTd6/0RggDgUkv7j19OrwLfyQDJWG1nj69mg/Vf+7dPc47
# DATA vXt3T/JpBzMUFfkUXqL2DN/jGzi08PhFP38JsEjqT61Bg8cv+73pcaunpMpuvow/6toSsFwoYS9vrdm6jqfT8TLQ9xfw6X2qZXkX
# DATA 8pb1p6fLj0eDfvfUa4CFsOVi0k2epkU+OHqa3kloyv2H09NB7j3rnzxznqCrXPNOMjr8gVp+fjVUTAsKH3aKfFn1RTwCUJZlErPs
# DATA 03B2xCbw+r+evOgXM5R6p/nhaPQ8wXQ1Ssp9dgx3kmPFSI5Hg16BrHB6rCTjjmKLSXECgjNdJiChcgLabvVcsaWTJO8UYJ6YjoAp
# DATA NpLd6ax3it+OJr3+EGCXGElWCXQgUp8AICT2Grf6vceg2gbx5gi8R5IfJ/9u1s+nyYvRQIl+d1eo0F3015nkAxhGv0sjU909gt8r
# DATA nULtl2IFnjeKF8/gHcqUUPZEVb+iHr736mSArcqacJWK4zyfxuqDJWh0i+KCn6GdT39GSwEQ+kGRH0AJEOzzyb27K1RQ/YEnAY4J
# DATA pPvDLYJKIPhckgqsXR2WgaoS+/S8P5a9+SawLyi0q17A6vA+uLvSodMGrYrvD+Fi4QzHmvagGndVVB3Dzgslo/Q7y4POIU3LI5Cb
# DATA 1OP+sw5vPmihpL7tF/kEzjHWJUoVav/088KU2x134AAn/NwvDlvQlN2B/fhyNHmOa4NFV1R/eFJhwCQa9uBTPT93OTWTnYox2Hrg
# DATA C6JMa/f2jjtqCccgE5uANrXF1d9KVhs2VPVr9+6OVbE8gW/V8ThNjjsv1B+jF6Ddhcx/x3gAIJUjvobVQDETduqokahv1bUZ3eGU
# DATA JK5O2xSO2OloBksHH2tFlT66qtXxvbu9/gvbbyINhb8zDmfTqXdg3KX4QAmZupnDXN17AW+XJ9qrBcyDo2FPnWqnvkUWbUX1FfY5
# DATA zXZk2vkBTfr1e9uTZNxXHZuN1SQp0nI0U5MyGg1guq/DdN/vDLozNEceDUYo/ecd8u9OkNonvUnnJVAc8OuDGVbrZTZH0hvltJS9
# DATA fApoheoGoWTXGZwt1XGw+yJwDQIZdUdKRO+DEpxm/SL7z4x3BTbcvbtHSpSHnTh2T5TaXXIqQOtLtwSo1+aOUvWpgvf02jtdsYnI
# DATA 4Jt1pOx/1DkZ3wF5/UWnewodSv7ff0ou1H9aNd3rFSBKcJ6Ylyumb5v9A7f/A7efx+1pW16Cyb9jHn85Fj+fw/8PxODfMX9fiL1f
# DATA jLt/LcyddqQcvmHo/3JOEBL8+bxTUfpRkWsOuq7ZJqnzVIvI3TX/lEMGuaZjhzk64gBINXa1rVCtwkvEU9DtT5D5ogLPmwicHhRp
# DATA NAsuUJ02yDsThPI/UUxb7axBHRmwGkT/JO8lh7P+YAojAPpY0JBVT58U8AlKW7p/egTQguXoXS0PFL5AQOLAaDg4bSSbUy3DdSHP
# DATA N3B8mDjFtlDTbM3aWhTo9IDDoHoRuwiLsoxiAZz1okAco2Q3z58nP1R7BZy1tHHhOB+MUVcFnUw6R0ewSiCQdI7y6akZ4Wej2cTy
# DATA aB6aknSKZDIbGlHzEJyd8kkj2eBEQzClMI7ZGKQVkDP1LoQ9XqAMowpACoURCEmKPBRQpjM4nfa7KN2oseWTKdj4n6khdMD/Qru2
# DATA QV3d47z7HFWeaNpBtafTmf/+k/+t4LGClhf9goruaKzqQXlSrFkjuQ/rn6BdHhEv1MBOYeRcF3wBXX3x/7H3rk2OHGd+71cph1bL
# DATA bhHAoAr3bs7Iw5tEL0nRHEoMh6gXBaDQKA2AAquA7mnNToQuuys7tHHk8Ik4G+EI2+GIc95TWtGmKYmKsL9A91fYT3Ke//NkZmUV
# DATA Lo3u6e65pUSygUJVVt7zyScz/z+8IppSSY10oOxxpbYextQXTaIK24GgmMBQlryd5TGnNrHgwqZn6A6TIx4fDFAVa37v7eRkJmYe
# DATA MlJ2lg2oxmDHWilqUk/llgxGOEWVWjl6uEEkFX2cZFK02FOYson/MIrmeaMOBwPY/pMEjWEw4OtHCCiGQiKElzgzafRAOFnN+zDh
# DATA +5ZcanR7lHKRIS9Ni0Kgc0R4HOlOgqrPB+ht4oUkgYK2mwvl2JIqN1dz1Vp1q4wekbGIJJ5QYCYrRjx5KRTkexRjs3Epg7gHduMN
# DATA pYPxcLyESiiN9bnSYYgo1rw30fnI3gMUSYpxMaK+RVVXeg/Ob/FvUqWUtX/lac5ug81OM5wdzeRbM/avYutfg6lfNJrI3v/O437y
# DATA iMyXnwFf0+daWqUrT/DQY7J4ksmk2o9oLhwn6UE2paDHTxDu42mYUm04qB9iheMohevn4DhM96rVeTiP0v3DQTKhR+QS2WX7h+i/
# DATA DvzO/NEdv9ZuefILwto/xC5z6vJPqidpOD/oUw18WKW0DZ+EjyWYeEYNJF4cQtu/usTWUbL1omoyGlGCDmpBEE2fhAdjhPOY7xmC
# DATA BcKNpEqVf/BwRm33IJg/eiKVpBLP5stFRfZvVfAExprHHEX1Ln1nTf4+HsYZDcOn9DO/ejSJHh3SaHE0q/KWv4NBBEz04U+pdcaj
# DATA 06pqX/oyzU/JaMG4etBszh8dzsU4OKCcoD7T82s+/h5KCRz480deRlOaoWfl30pGo/OYLYo5TenVl1VppuEwXmbqZ/lSoRhIeVRP
# DATA JE7tVv2QplIZhTNPmHd9WMrGA0xgVJ7UTBPTuZNfeWxFk7qpWSY7plaqgwrqx2yhYi93Fg3vYtH5J49XEsrJtwOQKqaCOKCSwagy
# DATA fJzMwwHNBg9qrZZOjZoDUuUYkYGQVckejDECqUeLF7lSlK5JFSld1BWmfO9ySs3itHj1MTVt1JiDRqlQ+S6q+/KzrstUNE8kHtRf
# DATA 7/2Yp0g8jFOr/Mm+dRFFmfxkf6UO80z6wK/Xv12odG2qdBtqF16/v3s7zqsuam6tY1VcXdkaOhGl+FesixJ/Fd2Amuahiip/lkpc
# DATA Xe1EqNlVs3FKXw7qTwrBka3+k8c6cvUnJkOsXPC7dQqbKlv8s+iALScapp7w/Mi076M0Hh4eUTdUa3DKCs2kXpe7a5wk88ymzoCD
# DATA 6SCUcvu3Q21SqCNQF6j8H28tI506vxa0dKiSgRSv6IhG8cd2wJ163TxS92pNeuTJ2K+Mg8q4UZmrLry6SOb0+NiX3k9eh/kVzGQJ
# DATA qALSMsa76XwvqDXx6kq71jo+qbRq+LJPPXq9qWKq8mT/cEKWEFUJuF0RAfmVugQma1SqtXqjRY8eTsNHKg1+ezA+VJHqJ9Q+p5TQ
# DATA Bkc62C1yvnSnlQZFLeCMR9T87gVRo7gELWRn8d385oa8mV7iqVynEBvlAItPcst4ggzWSWt3BuMn8fSokh0fmVrDJLRDq72qChIu
# DATA F8kTmRNXeJ+BjOiqqQAX5wd1qsgVTJj28KRX9dro001EZJCyQ7qwrpYHLnaX09i/OImiGddkv9YqVWW/3jLdism2dTX3SY29F5KX
# DATA HcnLpuRlsJqXOteCOlWIteMQzSWKCeJ+ga0H/EcaXqCGVv77hN0hF+ZCuZ1uersXysilvPp3YQL/pGx6HBhL5bDULJ/U4A16DPEE
# DATA vnEUP4qGhz+rsg+G0n2IRln1UcqHIG5QTiOjN3TRpltAOjlkGYIeIxQ8+aRGJk2iO8eqMAPbKLtir0f/MXvW0Pcup7PswB+lHv27
# DATA qX/jBsrhezWyHOg1nFbuYrVZkxdps0UNQe4exUfLNDKGZH51ELI31Aqn1g3SvH0iVbUuv1ZNJS6uC93S87600Zoy+EtZ06rn1Zrv
# DATA Xl+n1cPcIRWjsHNjsjOVuu+V7q9lx5Jf5FFnWLyLsg4l93iHskyjOc0K9xoVqudUKHv1CpUsdRt5jJ7UBmE6fGyNLNao0+ahvlwL
# DATA s2U6whHuC+yL7eaovNebH2D2Xx2M48lwNZl8Sw3u80ptuqRJ6WPbQOArFBB+tytPT/LwBNvybWugt7ZNrTefW9TJNunfBv3bhmlV
# DATA Kieun4UCYJ9dsblsMNTNAINASr2hpPlgthhLnuwFs31Pp2VTSQSrVtuTmvGblus6dQOULHQS5hZPWQOSgWbgx9CKUR8fECJ8ldYg
# DATA 1+mibfNVzx78OnVcp/TEi13qKGWm6nF091JoJQy1eVKDb8FYe8FN1ku8iRdzVk1EPbbUxHy7RAsM1rZADks2Az4udFZi7tn9vKfq
# DATA 3JY6oFLG40dz3YzSagsN6Y5OxnxYEr3VAU3KuBfVMTqgpCxOTRp5JKzJtvWCjV1raatZNb9AuhXti1xjaTft1NUPcVeVF3DUW3I/
# DATA 5iR+vIO5UZqjUM9B86Z4ED22s6Q8H9PNUTcPGXdrUig0vTyyjCgT9foOw4Q864WYbtB8cIdKUqgbnvkW4BtsutUGYY8pxf7aq+9m
# DATA oBVj6c2tgVn9lNHgPjt6XPIbUAMJj8reETFtt9RNU0CBTCLTYp3ptlcnlRuaZj8s2ba6Ja2MrSW7oNyFi0GggvRkUohHDnxrnuU3
# DATA uaeUppBndNl5MwyzcVTM4B+P4+Ewmv2k0ID+leABw9niCTW3x8YP9ohNd3tuhPlB/r7mBU3fzsrupoZdcruFs9MTuKGfYG1ESnkU
# DATA TuPJ6cFbZGIlNC5XPnvt/biv975/kMySz16rTOkPh1ts85SXQxqH40lmZVOwe31UvpTHJa9U2WlVstf1O73C7JabsJpEXdRcD4uj
# DATA I8c4UBOfPMSGPdyvMzp3MADLVb6bx9JqfVYdaGF8VTcU3Bo8U9nNP0k9du6tLs1EN1SH2jyeTKppcnKxla1s6kU0N6Wuu9Fm/hM6
# DATA cdP+m6qDXsCFx+GVW8ET/kkXHHWRk3CekVWiPtgTaLsG8sC8GFcWQ5mWcV4cIDaFcXSnyrjYZms9qVEMosfck0sHfuDfqfo8Nlo+
# DATA IstoEJshWS7mywWfSChnlsypeJd+Fcs2a6xZHE8LF0n6WA+762xZqdG6ozMV+sm/nkbDONyzTLQ2dWv7jzc6HWxPQ6ONvld5FYqt
# DATA Rdkkq6MTVxY5RYHprmSTXWd4frpx/llqlA3MXO2sLM4njdOlxX01z40uZYxpY3VzfOyXr59CNrDYUJwh7pgtKwbD5ml5MNI+xpZl
# DATA pegH79lzKbt6BiXzWZuxq/Wi2eB6wXlY0VbuxviwW0ZcLzyq9/LCKUwoAnHTqalmcXjYPfU7J5c7kTXzH+7IqSqZdM95STOrptFw
# DATA OYiG1WnCxSJfqXWsWxPjwL9T+c6BbPqgD+EI7SacxdPcZZSP84e8KBKv+UVHQ07n6LYozbCiF6PKDg+xj7k0lflhuXxlpc7qFdgK
# DATA UHPDPs1PH5rZRvmmJ08KK4Z61xZ2CNIf79F0MuO1T+zLO7hz5+TkpHbSqCXp0Z2gXq/fURu8sIHozeQRbqx7da/dpH942Rc13pMN
# DATA gPSdL3rSkeXfU37OD/B5REMQ75lq1BvDZg8bH++9wXIlvFvoA7/t+b1xIzjufj9oHvv1Mf23+32//bPCw6Ng1Bg15GFEsbgqmtEI
# DATA GT19Irs0kafJPKcgmaj9bXxjvhmLKm7/FL/wvrl8d53a/GSu2ovOB/mOHrMHIBryWvip2YBnZUmv7jWbLa/Ra3pBqz5p1APP7zaq
# DATA jXrH85uNYsYM28N+VF/N1U7Da3QbP/I77UkQ+NVeywt8erzePaa/7yPoVj0oBhWNRj7nMU8XHnL6v9VsteqtKL9YNUXfWHkpQu36
# DATA x83An9argd/EK6u9HkdGRcTzpVZc8Q1BUPeCpn/sB42J7/teq/ujoNf92QfNRs9r+FR9gu7Er3eqzc6Pgna3mLzuoBeF4UqQnRbl
# DATA Sm/sB/VptV2nf47xsUmXG83u2PfpcqtF/xzTx1LM++1+vTlaF/Pmxpqqti9SRT3AycLHyhN8oGr4Ic/vD1RjOdRT24NvtVvtfgMX
# DATA jPeJHuH/HRqDZvVKcPCtyI9aUedQ+dgOvtXqtTud1qFYGAff6o8G3QGeYLcz/TxsN4LhoSzvH3z22oPoKIm8H75H04VPwjHZnpX7
# DATA vH0so66wmkVpjGd1l7bT7eieathtSSZT3qUfiDXpBUWnc1cMAXO7GY3U/OZ7EbXpOKxI0KWlucOyIwzGWaVTax6fVDriCOOA1U65
# DATA Xab3W/1bNFMthlh2lNtmniqY1Qe0D704ThTumhesSjE5+QaMP4MYO4keX2J5IF8LEA9gySwSp1X9csaNBxdteSNG0StQ32jMFlJb
# DATA WUnaRcad8uyt1DE2G27SUnmy2tZ/iqb+2WvYvUedRDxY8E7yGW+A9P4K+mLe3XtmC2Tt82WUnj7gfQFJupftW/eam++naXhaG6XJ
# DATA dG/9c/cnE3rUelbt5fub6BTSi/oZtPAatgNSbHlu6b3uffbagR3BaTTF6WzBjn0Qzvc4UMMKZznjh9FpxRuFkwkq9773GAf+6b8S
# DATA gMjk856yBxIJEKnfo6zesyL1OjTK9g8NVZjpKvTS5WTifdfbk1jUxmGGl+3TJXWFgpIrB1YEDjwc/RQtAhbbP/Se4KjyYEyxUm+4
# DATA TIh4/Imdaj5UL8lWqNjH+vFMHtc/HKq8KKQ/25D+isQbtWR2FI9ONbbKZAu22KxJywiHu1cjGZ7uYfK8b4oigkDtX+199tq3xPP7
# DATA 2WsUNMSGogkQrTXcrU5n0I34dlgKcpycbAxTjNFLhzlbTvfi4X6emg+X036U7nGYn0H0j36t6dwsPDpUm0j3RM4NgYueBb3ps9fw
# DATA 9Q4153h2qI+5yBmX1/LYL1NE/4cfv1+THZc/4OMh9B3qbd6b0ND7McL5ScV7jICfoDDk0dBuSPL0O5OI9TI+ey3kbAhr2P0HzZp0
# DATA gm86vmhNFGNcGkziwUNqU9h6+kk8jZLlYm9vH20ckUqjYzIq8khROOC+k/2qskKigvUNXQqYTeDldj4lM2xo3hvNkHCUDR5gIbwp
# DATA hD7eOaZIv6+0ViiMbNmfxlSQFS865mK7R4/xxxpUY+jv27Ixa08VNQdE03GaCv0I9I54cbq3T+HPcMMTFdW/QvR+LAcuwuPoJxTJ
# DATA Gj34TjgY76nNn/yiCRnNWShidNy7UITwFfH58U/UG/+V9IBxxn/3+AZ6o37uxz/RpUT5j93x0OXcl/Dl+ikrWfL9NRpVJsthlKlo
# DATA 5B0i/UrvM5vkFve1tD1K2Nr6hqg94Ea7dwq1TvNMsfLjnd+livlAkkMdjHzGeaMnhzqqe/nja8qG6wvep5NzHVmlP++QHZQAuYuM
# DATA apra7h0jFmAH3/XW3n7g/bhW48/Dyro7TEGRBZwhmRwP7l6txEikC1mE3i1/xmSr2Ye+nA/1ZvLCBn6V72+qbe/r97gfyjMSFm9p
# DATA z9R2dpwJJYPiOKpxC38i/xart1nwKtbx5FFewfmWTBcb/WQyxTy8uQjlYSpDEwoKEYGs2ACfvbZuJ58dLf5dIsYfJQJcDBJ8Xh/k
# DATA d90Ty7d1VZRP3th1VJkguUauZb9si/aBistnkPCcku0htc1EYVPN2ZCfOgKq9uivZN/NjmgyCNPHYzPeM++li6VaplvLhnp1aA5U
# DATA rK9ZqDZ5vVF1R+cPzFUzQvM31ZPLDTTq09yKjTG+RX8vd/fSNN8TLVOT/ZzJrE/MIX9XctH727+lWKNCUP813aM/yfvJSZS+RZm3
# DATA Z7KYGkLG4mv6lYWnyUpCwrle48QE3Vc/9KwGgUwtVjq6YFcNFl2EeA9dtzvNYmzymshp2ff++q+9PR21u3d1TBApDshUAZNvd++q
# DATA pKD+4hZZ1qM3/yuOgjQ3/rgvaXn9dSkoZexg5VBnP3/JzR1825c78mAlP9A71vMRSSkVSRniBhOI/Lav7ikNHxIW11KOYZTxwEEl
# DATA r0t0TWPkdoS2aFUKJMeU49YGXHiIXoQ4qmpKmawD2S/WONyoLI69/bv32Gb87LV3zaEwNJPX92D2ffaaND1K/3fkO88Bubkvknex
# DATA rW4v2H8dCf7fv699Rv+bva1nyUmyYFerFy48n2Ysr0sAfNiMAqCH1r+HjKc7xVvzd/n8rv/zT9aDOkI7PDeYSuOWGWB+INMdzHYH
# DATA sy86mO0OZL/UB7K9wnZjdQ76uT6obTxn/HPhBODEOr79YM5qeRjZ4iFgI/r0dn47byvmc3LP13nuF+VU40XCLbajlOMvHud7b1BP
# DATA W26GepEM0TArFV1Z77JW8ORCOOFvxYPq5cUradKDBJkrbzqdDXQ0lB/73g9W1r7YTCV7oHTw33qGv3A6OAPm97hoD6jcoQdD5QV7
# DATA KF2cYlOxeX4uugHZOOQTsbpGeWrDBU0L+Tjysk/jmgevroc5CIX5OceDdynFSVrzfjCPZnzOd8Rn9+khdZifK6tHYY1R66hOerIN
# DATA gTFMuJveDMYCBTRTugE7Ku94JR+31hHg88QcbbIWyMg+wrk0I8PzNzjmjAqH091MdPA+Whp3rzfDZVY/knfE9NNyDrMhq3mwpfjH
# DATA jE2qZAQnD7WYISw11WzIXE5YAmC0TMmKWK6qIbych21NCM56c9bbRdZbsYY5fR2nr3NZs22jgXhTujsPsIXNkoPAa+DbhHCeUeB5
# DATA dhpv24ZL7O7zbLm6giXH6x9sf2BRRG3J0de4sNEJiR3LPgGdycoLuDfdf0N8oroBzng9CoUkoZnnTHeVX2GvGG//qLV4E5HWsKbk
# DATA 84YoXJyGvN+opTaTRHPefVSTnv0Ox7EUVfFCmOqAbztEVD9l4mkumGg2au1rjKZ4Ruhn7aXhC2+Io1VFSt9jImUeeiPhDj+PXIA3
# DATA 3/MPgvobdxJlFZbvaal7Wlvu8evqJvqQ33VHopUnRdnqOjfVKhg9mDeDhS15RGYDP8GGRDql9/KeYJVOtRqK0UtXzfyS9DzxMb9o
# DATA TuP0QnLgjgSB+ZPKLVmntUPJL+kdaubKPcvgDDEhszoAW5qKjUZp9ktKFYRfjEH5AQ2G1D+L0ai91lb7xxgbzbjls6FoBto4FTuy
# DATA 5t0fDj0+E6vMgkwPn7kN6b2PNRSl6omJgBlpl5BNF0cvG6ViiFOPgzdiFwa9bb6cTPjHJZZhaVCPU238/zCLRHlHRGxE9yfux5TF
# DATA IjGvRaR0nceCbcZRILMEhgWb0uiJMK+JM0wLKUkz6fy0yhXb6xMI31u9HMbAfsR6mZxp3MFLkXBpvPxWsz0AOsPZGc4XGc4lA8lZ
# DATA zs5y3m4OPweKlZ/Q27hxZKKZFw5Va8jN5pJmIwYXo/PGiogPowUV6OxIpO2K0ovCBEtGGLcSJQGZKyWKHmLZSC75Z7FdUUpBbVl8
# DATA Y9xg/Tkt5KwbO8W4IS4zI1IJCwb7lKC3GEp0WQw7GY2w/QsyfdwXZN44OaGfPSohGS45r2ueMi4gaUmxO8a4i34mGXHHwHluyVeK
# DATA z4qTUxz0FiF7M++nGK4mZqQzKbKT9j475cIB2TgQ0jyhHitPGUbeKk8ZZEM0o07DScbbxWDpIIlHZItlulcbUuGNqTfjUuJkyikf
# DATA CmHGouJwI5LpdCRzJzFitL8smZLVuFDqgiGsgoeeVgrZks63w1PuibcnFGUorkqUsU7jA+V/HEURJWsYj1jaj2Z3MNQgcIg9jNiH
# DATA QNVqIVswmG5Mv6Ap4hc2Ab1PGMPjMV8QAbJlxUxZOAapKuqEGIuuvzyVSn26QH3GJtEtifw4ytYkUMyKQhVeFVQ1VZ2sVPZbnkAV
# DATA HpVsgibIo04arTNiUaQVbUeC8BYOY5y9k4FO7FQlJkm192PovwwpE8kuZNsPyYedtyRjgp94KB5X7VJmSBlq91TeKfaknkprqdNR
# DATA nE55cWTd3JYT9QnljczHweid4xgpmUlGbZ1akLGe88XvTPzXcj/lB1dHMgXU9DzMxBbm3sn7QIt7Uu/KsAc2pRWI2/iQqfE8ZPMY
# DATA UwMyfKmkw+UiRrcRpqzTNVXKk6x+Kh0KuFDiNiYLAdfVlGJjav9mlpxI/UQroSaCPhKCrTrBbycc/gL7KpHb0hYpQXO4Erhr5LFN
# DATA 7BLLr4DGT6WMLQ3xxMC1Up4upFTclH1kI1GGSQqpyHFAGjsywhUF2UI3zFOE2WlZTdbMJ2xZWcvOF5v5JbT2nzypGIbO4ghw3vTU
# DATA Juj8f+e/OvvD2Tdn/+PsS8XI+fLsz/T/L85/6539M5g29MPP6d/frqJz/iv98BXd9BXuZ/jNn89/c/alR19+ZyA6X1Ogcpm/ArTz
# DATA y/PfVLzzv6Pn6BncBnrON/SmPzLG5x/oB2Hq/PHsq/Nf68j8hW75g4B6ANtxLJ0XYDaDThnHl6jD6dOfRUE0+yhKKJw0HmgTrOa9
# DATA 82g+kfF5wj1iJH1DNo7n1FtMLG+E7hyxijiPcp9BPhdKJhM1PtFLtczvVqgOlhNVeKqlOLROcX6je5DbBuusK5mbw+vkVcfcCpMu
# DATA v1x+YCJ60+bu9+U7j+jXTNjhcU0N64na3IrB1AF2diy260fsYO09YusThVPJXYxs/CL34JDJoqhgmI5pPOF8ZLn9bIGZamm3skZq
# DATA IghzKCVerPB1Lq5+mx2aa1rWs8LsXJwMx9lxlsBNWAIauHNFA+AVcW7e2uB/I2P/TkP/ZUf+2xn4pXqu5kPO4Hn+WtdNwHisHGAU
# DATA T/HVa9K7CvKg103naiVRFR7lWYqXKvBNJFmTqbypeEoC20vHp4vxlEORAyacQbsieFSR5QuR1BFPGC+zxEotVNIXyO2F8s/KMblR
# DATA eJxgVFCsGR1jvEDgJjyc0oPaYlDn6g5ze0GIRfD9wIw4CWcL2y02SOaOseMYO46xc5OMnV1HlZ2mObtaybds8l/F4r8Og9/Rdhxt
# DATA x9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3H0XYcbcfRdhxtx9F2HG3neaLtBK3wqrSd
# DATA zqg1GrxAtJ3VteedmDucuyr3sCvT43e12wWFtFazlOvNdrfIzYmi7kiBjXC4kaI34EAbbZYBGXCogQTDUhl+s12E+DQow9egkTpN
# DATA rxnUPdBt/FZv4nfrXtAuUXvafqvV7a+ScpoNr+n3fuT3muNm9zgIWlO/43v1H/n1xrjZOW74xSgMgmGz31+TiFa3nifCD3omEY1i
# DATA AEEvGLZWiT2UsV6zE4xVLlr0HPPACj2nfQV6DtdYi55Dlb9Az2k1u+FV6DmtYTTyc3pOO2j7naGh5wy6/dGwl9Nz2u2W3715eo6q
# DATA 41WuxmZcaAhBRw+3hZvWOaoaPI5UescnlS5bUoU1ptZgfLgzaaf8NuXgtl1bYmKou3C04HpwO3aIq7gdNdHsGmMVZXzIOznG4TA5
# DATA Oah78G7UPV2SBUAPt+vVV2i3uzHNO7J+Usj10k2FtTIZzkswnMMN+wFWRytFSVrnqZV12y0hq65GDW26oeQ1o2nid7ErVfUZmyk+
# DATA hdK+wEYsZJ5dmCoxevICK8RRdhxlx1F2HGXHUXYcZcdRdhxlx1F2HGXHUXYcZefVouzEI7HfsO6BGv/Y/iZ1564aMdXAJb9VuC7u
# DATA Hz6xMD2PJd+QGXc5GJw6MsG8Tk8Av/PZa6+vvkNV6kM9oKiXrN6Y36IOaNBdbOceKkjQhzjGJS2fTfnJKZ/O0W8tR6nm/Tt1Bt46
# DATA lMYHz1DWVKFMFKr6Bvrhu9tG/GvKCmMzm6Ty4lRt8WiRp5l6x89ee986eWeSQd2lSoFMdEvnfNwRdHcEfecj6MUDYe4sujuLvnpq
# DATA cKPe5vNwRr1UxwutxRanYc8fC9CiMme5WooSvo2HUZgV0C18IhrKliAX8UiTUXcm54S1kgpvpSudlt31DDongfUZMZazOJ+SBKVX
# DATA wYU6Fz2+PssuIn5rDoOqXVar+vXKdkUV5E9KDV4Jh+sfcz1zc4W320L+M+JwTPTizMrqzSrvxiBmaXT5XNR4t+4w3af91IpCOyxK
# DATA HO5Ehyb3sbjrJkF31aVyWN9TnzffLcfrWeWOP22+k/tcJTM7iDbfJ/02p58/bRGVl4OmWs5d7FBbzR1DzBYt90JNgP/clnXNf4G3
# DATA nrs6PQ+QTzrPy3lWEttkt77pBcSq5pqXLjk3/uWf/qNJRzniVv7PWaIUfc4knOf6q2opkfekpUtIJMBGS1iKYQYleNaihlppTLWQ
# DATA oUzhfE51kvV1qWNG66NJ7Gwhx/+hx7qA/pHWoWWtal780CKzJ1S51WFx5fOyW2Z+8lk3jfxgtXGc4bJKiskZffSSLrAvmGsK3WuB
# DATA AMqqrZcqoryiXraA/v6/by4gXemleN5DMVBFznQBfXKSUBtNqWPz9Cm/TJkg1CctZ/BE0pA0r3nv0SgPI2eaHIsgBaWBBQcgbHAU
# DATA cbeKApL9w6qcIq1uoUrr6UvFpODWysV0C5ctln/8r5uLRXUxUioiBzpIUpqMmJYzUxNhuczTnD5rurKusnzy5iEa1lBMB1HwHVEf
# DATA npyoIirakSzNzmZxYRy0LscLGNFPX0p2im6toPJ++dI93G83l5Tu46WoPg3Tqce7u/Iu7gTXBI4zPIYWNpXMERUMr1+gr4tkuJ8N
# DATA RUojYvVY6ExHM0BwpATUbKAfMbkjXogmB3bH2j8zdeLpyydPxq2VztOMQP/PP+8+Ar2FQTZKZUiwdMCnbFdTvNKHytLmJhVOWL08
# DATA 9KZLGn8mYYp9cnPIJyOjvR+J8agGGDKRwDCQZoMSf/qSKET3RWgq/2nXpvIgGS28Pqp9iNLJuzWM8X3Koim0bKAZM6CRB5MDVoQO
# DATA hz8NsT9H1fgMhZWyPR5P4wnOGyCnoFJBlvrny1jUaqCCyMIqUoBaEfoamkohGVcqoKIRKB5N2wg0VyS7732YaN+j1hTi2YfyCSap
# DATA UBkxQCfcieuCVcI/T8MOejXEXRyc27nSruBKc56zV8Rzdlle93Oh7ljYf7kd2y1zbhpIF9iqSRblETu1NpK7n1MVyBdINO0ibWh7
# DATA 3+NNULxXW8m1s7zXyohuInqvplzdZtSxxfmCSVDN840kNjuTKuI7EjXIk8Q4LnInk6L2KYfwFFBuI/OXF3TFW2aCL4UsIAWDnRGS
# DATA hKyshb2m1ih9bq6TuZ7mlbTAP4Sna3YEaKAAxkW3x0iBW8qCGnyjNLMOjJwozOpcVNRWEvXYZ0IW60JKC/MeWN8eNuJCb/O4UB9k
# DATA M5tkFm9XhSbqLG/wol2ocws5XHuVjEc7CGc+OvNxZ/PRrmtuHdatwz6l1bjRSL2ZddgPhPtpK0XnxMNnQ6q4DUo47/1B9eJjg4Vl
# DATA TvVTjtdWt66sF+YLSfny2Ka1RXt5w16t2XR/ydFeWkrY9FTB/VvwaW96ouymLLtZNz1X9p6VvYIbV04LpcCbrBBTVKdhPOT6IAtN
# DATA 331Dy1eqYlH3gl8ue06FJa7OmWrSeXkRHIfMNX/Ptqg8zb2nTt22qcRlpl+9A0WcNxVMTwsN6MVFiGOhacEk1Dl6+kxZqsnEfks0
# DATA 1+OJzDjZBI/0TMpAJKn9mNWqJZsKFBo9g+fe1h0J+hZ7ePaUQAhPAIzJrp76FJa49D2y7jgU1zLvK6eYQLgbCzTqiTvJasHl88b1
# DATA TuO8ruV7C8Hx1H0UlXSphC9mgL88VrIFB2QppGRaYAP+RwXx++bsz/Tvn86+AobvKw/fGMv3DVh/fz77ElC+VTrgfz/7CxP/fq/u
# DATA /ursa49Bgb87++P5/3X2h7Mvzn9Jz/5RBfq1Qgh+ff4rXKPfvjn/uUdfQCQUECDIhIiDPAdgIXMD/+JggC+C1V/ou0fRCdkOPIme
# DATA h5CuVRAA9OrTEeQj+pDs0hgQ6viwKntfYXWTPjMPVPfc152W7rOXc34NmhCHR0bGQPwn0WI534oAvA+pC2+4zLDZhdqzAwAW7H3d
# DATA S9w2/2+1WG6O/scWFhNW8lsL9a3MM78TnUbzOCJrQ9//jrrgQWUICO0kvWYMIKuHMRJ6ueDxX53RoibmSIC7FuH1owCpr8EiOLX5
# DATA WTxCp8MweIY4Y7tcmjyChk7EZ5fFlIfBilpIndtggS0MS5b+lx8ztflE7z3RFU1cqmSJM+MG07j4aLaCBdy9Wm62dVYa3rOCA+6e
# DATA GAcJdBbC9VkIGg14JcPg1XAC3ppRcAM2wU4mwaUtgts1CKSKlrPDmAHPTau6CSSglWq1/LUhihouxu6Lh6feURoOl6GC/mX56gNk
# DATA DItrbIwaLC5KnMqmTyzNH7PrCWttLIuYzaMBRn5jiu0EBzTjOitzU4Iz2UdHGTgCvowrYDUZVVE5uZ+lOlTzoGKL47OhWA7w0TEB
# DATA T8VBsdWQ/HlKlzJeS1Wlrcw3WSTkyPKNJvtq3ocRAHJyQTbtPVjCDEmT5dHYW86omBZyhp1fnDmMoMMIOozgDWIEdx6GdpokXdag
# DATA vtU5wlWmCNc5Q3BUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcVdFRBRxV0VEFHFXRUQUcV
# DATA dFRBRxV8bqiCUScajvwrUgX9bhA1wxeIKlhegd6JKViE5/WaFjyvUzfwvE4xX4eDqDkcraHvtQObvtfM6Xvt3sa8zQtm6te7XuB3
# DATA PN9vet2O12tV/Vbg+U2fyouuBh2v2y1h+TrtXrffXYflK0SZ92GuxpdeaCEP/Y6Jb6sImKxH7UFnzfNBEOTPN+o5MrG72/MNeaXK
# DATA r1aQ59duzzdbVvwbVn7v+P5W10I+Nhudy77fb9vl7efxb+wYf7u+SNny483dHm937OTbsMcds18eUclv9y77/mLu1Xd4/WUgkdJI
# DATA NCRS+jILEjnohMOOX4REmkcMJDKoN/qtXgESGfSbnXYrh0QO6sP6cGQgkc1Bu9tt5pDIkT9sd0c3DomcoT+vZg9P83UOOUJ5HF3D
# DATA ukNguTq0zcX2g3mttggLpo+8jGYzmNav2cOiMtwOpgbtoqJ9b4Vi36mtnN2IlYWI6kUPxUWUEtT3qCx5vGuu1doW1dCzs0Xd5uld
# DATA LcW80bNW7JMvOFpLQMctOxTUfgRJRzWjH6bRAUQvN1MaTT5USsndYvqVC7mytbzYmWKKTOzBlWoi5lOwS05xCI4C6SiQjgLpKJCO
# DATA AukokI4C6SiQjgLpKJCOAukokK8YBXIV4jgNj+7C1KNeHWfMKMl35Ks+yYJMUMjFD2xFAbSq1+lpqgvvYkPknr//+mev/Z9/qjHx
# DATA 8P5anQF+Zk/CD+dy2ABvpGD2TTgBwvnfX0g4b6HF8/GlaThbjkLW6ZdTXXIekZrzXI6+4VBVKMiF6BHdyIc/yRzIaGgrEBILZ3Tc
# DATA 6Xt3+v6C0/drjnC5s/juLP7TnMXfqMd5o2f0RREx4YPI+XFvGVa+a/Q5n718zG1odcpoBxlVE4URH5BVVufedLqvKIm6hc7YAZIL
# DATA +ukgTLdmLhhFy06rqCQ5jWey7lVXqpO8CqT0JrHfhn/dzFM0g7JdVS4bbysQE3X7mol90FoX+cCKercQ8XqttTnqZry3o64vqnq0
# DATA N4yO0oim6hekwArLpMC+ZlLQXpv9DTv3/WBL5m9U6NStBDVaOogXVZ3TGnGZh0h3ptKa9RH3gtmHedNifZOhV8U4st4/zRu5fQOL
# DATA 7It8vhR3lC2kK5EnBc9oqkQeBt/cPxWUY6Ff0roDrF+hQ6N+hIxAZSBivjcXs2EYY+7Hj0FDmCU1TsJTGXikOHnsz7SwxtEypBFn
# DATA EUUsDa6ELT6nDo7MLxytV6Iga2K0g4Dny3dgvTQqOsvaWdYXWNYlo8lZ1c6qLljVm9lKz5PyVbEVhCa/jPjVD8HfM2pHWMXOtY5Y
# DATA TwYu8YrRbxJ0cTSNszlL0HifGLoKG++smxPBM3cSMZm14uk9GxiVojmW8VN6BPWnbFEXCY4rYlfmPhr6342V9NE4SeOfJUbyRin4
# DATA h14WjsDXiVIyiliCyZRKNk9yhXSWKGLRKDWLiMLslEfecTKNIMrDswmy+yrCyRApHtxLozUNrDFMCO6sMsotrCIoNXBsVdgwZSjY
# DATA NsNIx/19CPMUO0BsnVCqPeBB5h2isYmWs5ANG6pXNe/NeJagDtEzGrOrDYFZ9GjBhiQvqSCDVD+aZHBbqR5WmUBSBab8MgsUus6Y
# DATA WJu2v7HBCJPkSKfwY5xolnKTalWYs8VYkIX6R5yLFRnugkh4TU6VWj73+NlDqWn5uKE3RYr8a8b6ryNItXMitCIpQ08ZF+bxWTDg
# DATA tpG9i2xboj4SOS9pFdGpkszCSD2fchcmaRRVMJGf7eflwQ7A3DgNF0YwLB+PKC+owlIaZcKp9JQoy7DLdYL9JVyVcYQmtSv0aQbf
# DATA OMfmEQWwIOMwHoIGW/PeTrhJYvgzymQQgVMG4widX2rFZoWAxJbVhbqvJi79UBX20lLQN+sphklqrsggcSoXtMi+mpwVn+cfi1Mv
# DATA vThVmFbVeQqk+rO8L2NigdTcHGqvZPaf6n2+IU9MwlOFDi+aKhn1hNf7zoCHUMb1DOOp9D/X+wZsU7z3oR47kKZ5NBvEk+t9C+/h
# DATA fke3IL2EZveg1/u+lgAsRpHZM0QNj23JGbW24rvuLCc3xqB9+eZXjkTrpla7Swa7idRLP5G6LHr2+ZIQNnt6b4JhWs7sayeYrlE6
# DATA vphfOikQFEQDmN2QRV3hLXjd50tH+UWUEN0Rt+AVNpZrIzyXW5V8MZON2srkOJ/2VrwjKDTncxrMwrwQE2BstTLz0AFNgW39WFFt
# DATA xaQpW5Rmpbk3oeRJ0Pa3COgWai1ZL8fRxULSqJPTcK5BDjuVwZoS/SiN2KNeUMPOoizTrMJXyHTLCVf98GGUFvBW/+3sS1Cnzn9+
# DATA 9mfFoPoDY66+OP/3jKv6X9753wMzdfa7VbjVfwatioFU4Fj9/PwfvbPfn//m7C9nX57/mgL9quKd/U+65U/0/Zf47p19Y0IDNWsz
# DATA 8OqX4FrRfx3T6kUg2VIdxvNwNlAFYwnskHHPMkSQtRXzSDCEawJy5apzwpxMXBozdlpwvzRSYJ6hXErQx8n+WmHkUc+RsadrK8Lq
# DATA TWygRTuJ0Fk4gJVtgEoncNv0qnKJ3By7CpLQw9J71yKruIqZG9/mCnczsCoa9eZq0y9qKTYJJ8PwlPcRUv14GDlg1UXldu2cqjfR
# DATA DLgE5lGKs6KsWI/jeCMGbMvpS49sd2iZqFUQawueXu+HWP5RGg3jCN5oMAqoT41SeLvy5RTVL8YzMoeWksPedJlJfyZm2KlQvQfx
# DATA PFqhWO1SUzfbM6Wm96zoVbskwnGrnBVwZStAY6quMPi/Ep6nWxr4r33c32nY33XUv61BXypjMfVmkH9WjeUm6FPFJHrjaDKHdUKG
# DATA BxDMJnJ5gtPx6WI8xYqsJP1AhloIveOEy4I/AC2NbJHVUeowQTN6jwz88JjGyUxnRyrSZrz1AGuy6ZK1FCn+09hwgbazp9TuCHiY
# DATA IixRR3ymSwZijv2GwVxcHJZBwHgiHgsyMSGqaP/DgnnB+wD1JgqFAuKXsIACUFP0D/ZUwM7Ta+TLRQJ5qAGTuhxgygGmHGDq5gBT
# DATA F40jO81ldjd1b9Fqv4rRfj02uyNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQjSTmSlCNJOZKUI0k5kpQj
# DATA STmSlCNJOZKUI0k5ktRzQ5JqN5rtoHNFktRoNGoNBy8QSaq48rwTR8rOlKDtNTrdz6vNqt/ten6rWQ3qAf31PZ/+afY8+lrMoUHU
# DATA 7TdaqzyoXscLQH1qeH69O636Af3TVF9LICjK5Pqgvw4E5fckYEp/TAO3Rh81LPRSo9W2il5xkARKVARXRc0wakUrEW12fC/oUrJb
# DATA nt8Ipo1u1W+21LeVeEb9/mhtPBur9ave8pqt1rhd9z/wm4HX7PrjltaLsxhYrWYQrQtytca2mxTThv+jXnNa94JWlf7xu9OAXkPF
# DATA 0sXnatClL6s/lF7a7bYbwWDLSy+DOpIWolFH0tgs1FG/3vGDYRF1NOL/2agj+hqO6gXU0cgfjvp+jjrq9CmrQoM6GoaDVq+Vo466
# DATA zVbdb9046oh3mFTZ9LBZQiqyxdmnj5HQk/9SM7cnAzbTSGYG2yA/PHLlb96BPlRwwrWNE06W3lYBRVbYqw55HmFl2xw9FD3cFU6k
# DATA LY2gHIB3ifF6y2PbB++NECKrBG1foCcm9Ob0lAq3g1LtqKIt5s/m5DiSkCMJOZKQIwk5kpAjCTmSkCMJOZKQIwk5kpAjCb3yJKGR
# DATA 4gjx0StKcOXk7ug7cml8OpTVQ8B+yLipZOanLGSLkq+emqunEfXI6rKmD72LcJkgNHqdcuiI+UCfUgzl4kkRRKR+f0DB88/Z2p/f
# DATA m0EUCcYCvY/vO1173yfJIpzI+T6+64NwMa6x32Bv9PrJ69nrp+pmmzOUn2RxR6XdUeniUWnrXJM7MO0OTG+W8nsODlLjTOoor+bh
# DATA qRfi94K8+YKVT6Q+owSMRDjqTQU/QzZvMklOtp/1ncaP+PjxPE2SkT5/DJ1x01Bp/MVWlGUaZU+hbU4jYnqKpCwoS5A+fdzyvpct
# DATA 5+hUo6Fq0XFmyEdk2SiwUUoDHmon5PQm8QKLOAlNHjJWwhaQySBdTvuH0IaJZ3weOzOHqkdw9h7z+d1P4cItKJikrOkuCtrZIEn4
# DATA icFyDpltOde8TUH7LdgQ6anso/N4iMqTNoLIOlQAESSX6iyKhpnuziS92SIVc5nKcZxMhnzWFTGnxNIcmOXAUSoj/HZEUZ6cslC4
# DATA yTZTdqKswzLpOJWuVdE5DZjITZIFkk6X+snJxAsnWcIHg7dKhL9L1ZubjhzbprdGqVV4LNjcZ2uTs0vfHGf6FP0J6iK6Zxb3meB8
# DATA L/rxmseK6nlPPsCGlAjy6PGET+bibHxW895itWauu54G1KA6UOQRKlIbDrERiMMyxxCVqn+4uEjUnXOO43xCA4nRFcR2VJx/93CU
# DATA Bi+jphNO+XU00HHpKEn4wXIhhYttNXN1Glh04s15b1yZxIrChWrxM8jUMxwnM4rmDyU88a9wiGQaTuwsic157jCdXk3X/E0RokbW
# DATA UeO/tLA5GuF1K5t/jMxH4Y3gnJbe6QYEzXO2pQgeoSjYEPVyPYIb0DQ3yoxs1MxU20M3izHvBiTO73O3b2wlpSZxe0rgL89B7jwQ
# DATA N6NwM4rijKJcpdy0wk0rdp4+bJx+3Ny04gGyIsfhSHT0lOK51wa8DUSpONLoMnu+vL2ji7CY+gHTYZkLOZ2jfhUgaX0z1jN37dEt
# DATA 39dfvL1vXxRZ+0ET4cLFnOLZXRfnZsuKcm9Xgir7G5lQMlnsEEt1e454Vd8LJtVK1OzMbBQJqVuiJk5P+rngldwhkvpBE0tzIbdr
# DATA a52LIhpsi+hGEKrMXzFaWS3txaWhSlOLs6LYkdEsfZf6Fmod3pGZi1e8dvfbnqm33pRM6sxrNNU9J/BP0yyfJtLRUYqOkp/SyCxM
# DATA v4WbxTdyd8RflQ6bzEwN5DRmtdp4YLo6vDF6JGsmesqAZTBM6hFWScqM5bmsvkwL2GbCKpOnZRUCk/58WiKxU6cPIq2CtgPl9OWx
# DATA vR19x9ne2735ztB+KQ3ty1J2nrEQKu8AzjfIrhqgNoSGRQdD7cE2eqGShM0Ummcqn/pCyAryf6+ZaVQSer1uotGKVO5antEO4rXW
# DATA PupcwhbfIghXJuGoYgg6bGUts7EysEr1FDvFpWTVbvE3xo1776Yx1m2wS5G9iHQJjPr4EWwY9v7LeS6mHcZFc4cmkJgFRuuWXZSq
# DATA pgiZij6pOsjAW7iUyVM0YGhaanlUjdViomvH+wHWrBBzsu9KMRfZXbOoQrHj9QvTJkRjVC/LKAYpjpNhe7a1WsTyqbz0hLOIWyKM
# DATA Zr9jbPlY2yxh+i/H9wFWgtQCnZ4+R0Vx1LC4sMdLJhOz6kdxVPBJrEBgEWxzROll6/L1ldHutMhBZLgNwOGx2EH/6ezLsz+efXP+
# DATA i7OvAP05+8P5bxjqA3rQL5jh83P6DXSh367Cg1YePvvz+W+AG/rF2V/Of372xdnv6cdfM4Po64pHn748+7pKT3yFoD2+5xu6h94h
# DATA aKGNMCEKHW/5gt5ANzqg0PNvUf8Q+mW8Tsy9iaKFnVZkQRCXpKNVu1PT6Aj8ZS3nLAv/qr6awT1l0eYCZZp6460MobfGoagaWJLh
# DATA jiNkWdeqS7htktC6crk5mhBvCBgnc3Pjp+rCeqbQKM676XfjhfEEXzNNSKDGbC+Ir8gi+rzqHKFdSuzaaUL3PQGvAwReXSz7kSl5
# DATA 8eDH2EM79WQneM37IKEaMDMgRCrEY+i9Q9IDawSs4QGzLFSbXUJ8nsimjxTuwynzGMVZx8aXwBohEluGB22vkpuNmDXt7Fmhg7Yn
# DATA wUGD3Eh/mZFec4KuOMC/Gq6z2xrcb2Rs32lov9zIfvMDu1TL1RzIN7reXmu5CVBQnjKIaFEA2WqcF/C4YbOm3vyn47s0aedDTowT
# DATA 0QUIAkzMvzPfBEtgTFtRW0L5LdNwRqnLTLoltSZ4wQxN59SFzRY7YYNgXy1wkB/5QCGNUurt8kE/luV+vbCFYFhMjiFGhgCURpJV
# DATA Bol8KkDlijXSJ8D8JCNBF+NFVBG9BwskO2aPRzzyqFU9FBrKCXUU2DOINsgbDFLknXaIOnqQowc5etAN0oN2G1N2hJpfbPPesvF+
# DATA Fdv9aU13xw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLsIMcOcuwgxw5y7CDHDnLs
# DATA oOeGHRTVR/VRcEV2kN9tDFr1F4gdtLruvBM/6MgkmXcRFlkzw1Y0HNU3sWbuvTGIU9j/AvYJJCEK7NNhkQaWN/B9RRgq3N6uNy+4
# DATA 3eL8UNge3ePRb1W/R3/r9G+v9X26PvF7dbrW9gK/Sdfa1U6vGjSDcbP3QQBgUac77jSnfqNVbbbG7XUxaQabIq4ARneOChWoGfiI
# DATA DL1hWvW9+rEgerZkYzTq99rrEUn1lepJcW4F9XG7Wf8AqW72WsfN+rRZb1abdfpURhD1wk6/vS7o4PI0IKnzmgYkzceiAVEyBp1G
# DATA kQbkdxrdZs+mAQX1Zrc1LNCAgm6r0Q5zGlB/NGwOh4YG1Gp0+t0opwGNRoNRd3DTNCBllKx3fOi0lmwtNRJh41p1uxXi0c0YdvJ7
# DATA y+AfM1FaNynSbjTMdSvNWpP5PwHzf1bXo9rFSGnjxuqmxXbhhFCOh2n1CFNj8Czqw+ioYq2925+9oDd/VPlWo97qtPvs9tuvbA6p
# DATA d8mgdJSzeTS4LJVI27zwHq6YVNaK3ObFcbUULj7hakY/TKODYZg+3MweynO4Ykd9s81RMnulDrHt5EhCjiTkSEKOJORIQo4k5EhC
# DATA jiTkSEKOJORIQo4k9MqShBTp5xPrWFd+nrt4jquM4RFukJzypjzSdCHsCEAzAp1nMK0xzOetZMoC6CuHvPl4G5aSRK0qxEGVZKaO
# DATA r2lB2uJBMWmjMpHTJy3cGWd3xrlw1MYddXZHna941Hmj+ODNHIF+N2atCz5Lyy7I8ulZfRT6eZPbuA09bjW4oOpQfVWS4Ujl3mB6
# DATA kUSzedZ0WPkVI9LcXavN3bJFmn2/XpRpbm2RuubBD5IuqvfiC2+ILWtUlOWeXOBaP/RGwp2pLSHd5uWej6nvU3ghridv3EmUSOCa
# DATA J9qcXTS2eHe8RRo9ZK3ICx9r8YtsM2AKg4blk4vP3pHU7CBU/Y6un6iyHqrsi6tS/UEUZkuIRuNg7SBMc4HqBwuR5KOeJEkWcoMc
# DATA a4asT3gEsWf4o05ozKp5P+TBbRIdU6VBB4hOdarC5mas4DRJaoSH0oTMyZr3MS8AiGkkD7DeohL2o+HkFAVNBREvCvLVgGkVju3L
# DATA OVIvXeKMN45chzhgDw1HM55DP5AsNqqzXPgZzc6W2TwS/UNWzA5nyxEG4hRzKQkQXKRhPBrhyrLPeuoxxmkKjLE762w9JUJASVjs
# DATA LHD9spzzdfLWzny1zFdnr74S9uplta2fsWQPr2vnC7Dbta3v02jERiMbkGzHZrkUBXMUsi0a17ct9vNC6F3chKz1ar2+dmnrtZpO
# DATA V5W3zhf9tTkmFoWyfSKQRbnO5aLWbP6ckkkjQE1eCqLX1bw3RTeIZkkiVhOFM5gon0JESOReMgxujBkVgiNXN5hRZHXFWviZbLiE
# DATA bB4y6h7SGzQx5HIV5wdaiMWoOhl3+KuleFLIGWcMOWOo1Kc6b57z5hX7zo1W1DMWNGQeMMDFyWQiOvtlYLdqJ2GWS/jVvHeF081W
# DATA 0jp5voKW3zxNBtEQNG6RokvSz5eR+HKehs99PzZQZ0PjXdAIqpmA03ghqGkZST3WcuEYLLmRH4XLIxo1P6ZhWNMCKxyAmCWy3KPw
# DATA DugwwtEITjF2leQuTzNOvzfDeL8Qfu1S0SKiaT8aQgRtGPVTGpGFisxDKIsAYofSVpS1jP65PKPggEOqCvCDsqagMg0ybV1AOQ7+
# DATA mlScpUp8mmyA4STqh2nNex/2E6JJlZQyN1QgsGGIDgZIhP5EhNfGLIy3TsiQP2aWaqG4ZDNQrz+ngo9H0HmbRlj7iwdbYeRjVrXm
# DATA yjNbwIPDXmST5E8B5UhGI++IhiydRNkn6U2WlKmDEIqNXI+BVw9PwlNxTOl4qjLMtFuHs4/HAQpGxZzyJRMFbviXWIX7UMkaQgoz
# DATA 5ZMFquKa6lwAayxQf5g34vUpAtFGr7NKNY80MrZAJpz54LlQNQSnTMsiMyahxMcgk7D8UzyhnyvaD8UJyGE7gzBNT1m58T7lWch+
# DATA OxWQEOYFHqc5PschS/LlmfRhFHOqxE+s1C/hkjtKkqHlbpe3JtTQaDQcSVsrFuHVYN9oy6es+kh9zHcvDftG3K4b9i12eSwNXOkX
# DATA xjOA46PhDUC/3wTzXsmFqq0jN8D4/rSkQnojb2K49/toGtLH0Lgm23IyIeZc79v4FNCnhpKIFaJ5GKfeQ3iLw9XU3SRR/OWY6lhw
# DATA mSRMh0fwrdt4mf+iMDLfMNQFdJgvvbOvzv75/Ofnv1nlyfw3uu8PZ78T5AvfxeQXUGG+OfsTffyCWTJfVTzDl/nq7I9nXwBX8xV+
# DATA quqnvvLo6xc6KLqNXvjL818puAzF4/zvPWbM/A5sGlBoHFTmBcA0zjSza8UXN48SIKDVyL0Qgem39HxN/B5HvG0bg5yChrF2L8sL
# DATA 5+QuM/BR9PRQuJwNt1Jm7vMt+ZsdY6YwmzM9w21TZlbL5eYYM5xAc9f3ICROeT0Zle8bQvvZAL2w33eRhqfXiZahNpCRjZ2KgDnN
# DATA NGCN8UwMBeHgMtuL6tqpMqYTGsZkxvOJPTF1yHzFUxC5jx95XC+8j3l7gLhtj7A/ct2mcmEfQqNdK32jzGbRgjXNsfeDxvBshSGz
# DATA reZttlNW2tCz4sdsi76jx7gh/amGdI2TudJI/mr4ZG9vFL+BQXynMXzHIfymR3Cpi+Vk59smn2GLuQmkTDmhOVnGaE7kMafcjEKF
# DATA mIH7jeUG4OmaUZFmslqLZBh+hgyrQE8cxynjYlBYGitDKQ8zXMSRcUMUxmqoDKyXgMicwtpi366EeCTbzDBNoI/9iXjcjtKIzwNI
# DATA tuutbsq3TqM/pBD4+4U8kkOM/5wlqWUzFDEjUepgMQ4W42AxNwiLuWDM2A0Jf6Fle6vm+ZU41U9lnDs+jOPDOD6M48M4Pozjwzg+
# DATA jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M4Pozjwzg+jOPDOD6M48M8N3yYdqfZb9avyIcZjUbBcPQC8WHK
# DATA a8470WHsbGnUPb/VGTc6jeOg1/w+fS/mSL/T6TSHq9nZCjy/W6cM7RwHzfb36XvxOaqb3b7isnBZSllJwZ0KhyUo6Eo0e8UybjZL
# DATA EelHvU45wCBoXDXAYb0XdNorAXaD641ho+lfbwybUnWuL4Z2oVBZXkMeWoVyyQA3lLJVKNcSQ7tQriWGdqFcSwztQmlI4NfXUi4Z
# DATA 4MUt5VpiaBfKtcTQLpRriWGhUFrN620plwzw4pZyLTEsFMp1xLBQKNcRw1ZgteVesZT9RilEdSFVuV8e/NtRo4TiaveaYXMtLG0d
# DATA dKzValjQMQk/NUgwy0jRoa7w04LW0wXQ6vasAFq9ywdQSEKv/ZRJ2C2Ay/DMxEbTPDMx9yyeWdhsNxtRkWc24v/ZPDP62otGBZ5Z
# DATA 1B2G/WHOM+v02+1W2/DMhu2BH3Zznll30AyDG+eZKa+H2tBgZkLijCdbkh0UlvdCL1Kb+VmXVyrXLPoXQy5zzL4XkREbhxWJSWkv
# DATA yprgbEckL/IUQ1frvhdHw0xf1u+S07fT5Pgo2m2pqLXL4rQVannV2faZ6DpSdDsHMpFfWT30G9YisbrXD4peGF1deY/lOBwmJ7wQ
# DATA gxW3uqfrnJW3PXZY8KzYzOY27KfTk1iV2/XNDDQ7Ty/waFi5VaqTPFkOHAjNgdAcCM2B0BwIzYHQHAjNgdAcCM2B0BwIzYHQXm0Q
# DATA 2mNVu2MquLsKZYbPlOgKJ0ldxNE9ZITcLqqbd6ljozqzh6oV360fxm/wE4fx66/vP8ZFvu0wHu2dxDOyrsgOO50vku/CiP8YUIzp
# DATA jzic/ce6Bc3vMmiNQSB7zaDX7LU7Qa99h6O0/x3+o6LQvwsb8Ic0e28E0vH6+4fD5LG8o/yKvf7+4ROWzdzr/7j+k3t36V37hyL5
# DATA hgvf5qBf9w+fRGSsKy04Ky7Cf+MA91Q89ulupT46X9Kop7q9JxI9VI676uefJvFsj3srykHw4dAYXlc/ygLt3l5Y6VNxhK/3K2Q9
# DATA 5pa8Su0kvrvRmp3EKJhJbFfIu9I8qNzoTZI2mjnitWzjy4wAB8jR7ufYSjAb7k3i/UPJo+LvvCpNE3fVFd/z6/vFGzAEq/i8hXtr
# DATA cnqaKtsTjawzRz+dsopTVllVVjGHgZ26ilNXuaS6ykZR7BtQXfkYclxaAWSSsN4Ha3YZ4ZVnK+R1G3Q6NgXoqniCvGTEibkAS6ce
# DATA ynsk9b2gJrtCpPMtIF3bxtH5W2B0bL6g6uMD5h8oihKMTt2Tw+j0QyuMuLYE9UhMpM0sOR6T3oF3/aI7fVEDJgv0ohtZYfeTk2hC
# DATA negF9wZ1de+MTODSvbuj67h6o5Vzib6w1Lq/0YwGGY8ysh6ioZHaM/I6ZGQZWRwx38tSO0yS2022h0VsvCxZpmD5jgSnAv1tsRqh
# DATA 4ZDz6cRrQUbiTMn4UBJPPXXo3ojF0DtX1GLGjXu2/g+lqUEFM9GFwhaZnZvWRl1VApOdaHMvg2JIPpY4o9MZnatGZ25dOKvTWZ3Z
# DATA hfbkM9P6e8CoIY4ku7iBHEX1N0anAZJN40GaWBJ4S7ZQlf5dSK1rNgDdYlX7zgyKeYtSg6GGlLCU3CCZTqN0EOsxkC3XNMJKCzYu
# DATA 7Kz9xymb33sg3qr+KXxmEXaZYBg1ACVh/9Jgir0Ua/S31Hm3VRNVuWdRE/mTMk6VzaF/zA0gc4UPPgOdFnE4Kn6y3CCCgzrya21P
# DATA 4/MFJ0h9Llqe1h2mo7SfWjHs4DRFWwBrSu6Lt9mB2jh/mw24TXcNEhA3qLkc881v5V83P8OVCHd/hA9brEsZmLWFJy5U2yTBILHF
# DATA vCuUMPZ8SINWRztzpAN1SobdwR5rWd1ReWnnRQkHxLthTDsXZzDXpnTJtwf/8vP/u21SUY62yllliimpSqog6eJUjDGy73hkApNH
# DATA W5I8CNG0rwq7a8jzRe/+cAhpPHpaWEADNDaq/TxRZH4y2Ct4kM0/GR2ZiKKJybBN6S01781wllMBZ0OZlMpP74IIg5c06jTIGkqQ
# DATA PnZypXwt1Z4rZG9zc/YW6qLkMuxlseEpIYtwovP5PvNkaJCYVyTX9MSacy3EJoBFPI1sKNt8suTZM80vl2LRMwFJefS9+/EUeTUi
# DATA ay0bA1bFpjcu+QG+zpOMTfSa9w7gi3jNMM4GywwFxCHJouR15LJpb5fN3815q1quzlX0+NT1LvBB5+nb2NsTeo3/808NsJKGlCdY
# DATA PJiBZ34CfBDVrSXlHZWFTPEzz6cC7cFpIesvg4jmIDXvI+qyaep9Xyq2VF8QoJiTxOcVPbg3Dr037TtwhlDcJTyTVpu8at736WvE
# DATA FZnK/9oq8pWzeHsPUcjmT2mgpUkGBZHqPDbm7IgaflX0nHIWGLQDqX6hMs0lD2XFJ5O+QO5GJYWfJlTocUwI5cEPoV2Kk4EZ65aG
# DATA JpBwpqFUFXkZ/YYlFIkbZ/pRLJKn4JEdxwm1EPVwKD3P89F5tC/VefzbZcwrn3rw1oUgGUz1l8Y4VGyugGwDacNIpkPIdi+bxHPK
# DATA T24c3LcAdMbTmz7rm2qPIBRUMaqLEit3Td5RtJCi4yzEQmKWTCNcOFpG3HHg6XgmExXqlxbX0n3c/OD3Fo9LYCLFpmqbblHcGouT
# DATA RDpkyVr0xpkgNEUoOYpTGt1OEIquxyxjGxuFX5quo+mnquWTLciqzngndU04rUi99bGa3FHYeGKaYCGX5w7oKRg7Id0LbNZy5hbN
# DATA FVk2ts0Vc0Uy6x41MLXAq4WEZfwWU9EyX6m5jbnhSaHULmI9vQwul3y25VwuzuWyhqDgvCwvv5dlowPluSIqFI4KrI6UE5u14E3i
# DATA BY44sxIKIzFBsVSjCbtg8gf5PAln7LNGMDzPWuUX8ZOsgx+yKslHX+69QR1pub3po++F43VdOctnncuXC+FEusMyTmLlSLq030GC
# DATA 2iFvO50NdFSUymPud7PF7Lk81oA5rOf4C6dHrcSMg3sP2CY3VQQQ5HB2alatvp+cAId8qurOdz2+sIR3iqyq73pv0f0RdaYwhmCE
# DATA 5JbwdzEJi6dc4WbZicweFtho5/HSMevvx4roqtlUgNGGZJuBjwvtMjK8+smjaIUXVawt78YMzGQHJGXHcrCgREqxvwpLTjbnMmEe
# DATA t025/M+MpfwfQE6e/9YDkfLs92dfn32xSrgs3fmXHHiJ+yve+S/o2lf032/OvvbOf33+y7Mv8QTu/Qq3/1EQmHT7N2e/P/8PgFd6
# DATA 9OHndNuf5FbHsXwBTDYvY79/qg4gmr4eiebJOfcENU92y3vZUiassiGfubXyIDdgjBk8mLBHYCbTqBEmrNzg4CfD0sKYN89voVi+
# DATA KTJggspwCMuiCSeN/rYBlqUiuTl6JeyAY6u7VxWPKejyU/kJVQXNEx+rKokqOINH7FqBlrxbYhxm7K8B+kc5ypUF46CWu5bgteMt
# DATA 78MuPRJbxbCjK9xtDuFg04Ag02eJof12PBrFA2zIx7Zl2XETaQa4vnUWURj0cyru/hWi5U51cLNZUmxdz4pruVMiHODSjfVPMdZr
# DATA vOXlh/hXxENzS8P7dY/uOw3ulx7bb21ol2pZyIYcc/nM2s1NQC4LacSUPCwmDNtKJQEIdjpfyFA4T9H1gFM3DvsxL/wtMl1q9MTR
# DATA ERZYHlI1yGQeT/VYLXNjui0jsxmBJzFVSCx/CeEvg+JfuiviEtlomICYNlD8J9TV4wwb1kAU2lHHnre9rmAlVU2qFowFWRDiWLJE
# DATA CkJBHiIDsPKZVedRWmWrjkpgOeVe9tAyE3Ajolwlg22j2eAYmI6B6RiYN8LA3HmA2Wkmcwl7+PZM+6tY9tdk2Ds4poNjOjimg2M6
# DATA OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M+N3DMoN2ImLl1RThmL+q9
# DATA QHDMwsrzTmRMC/Xmt3LKYqNIFeuUMrwhv0uOF5FlzW673lmT4cButoNxszmtNpue3x0L6swCj5VpZDl4rLECfatbcS0h1VbiWm9v
# DATA imu/3+62wpW4BgHFtdu+rrj2rLh2ulvjqmB2a+Pa7Hf512JcG37dC6j+Xk9cG91rqQOdQbcd+itxbdavsw40O9dSB4adcNhera/N
# DATA 3nXWgVb7WupAp93td/orcW11n74OWMFRaM12Z9xu1I/99ve7JTwudaiD1tUgdtSXaoiddMsWxK7Zpm6juwPEbjhqFSF2zag5rOcQ
# DATA u1an3eq0DMRu0B1E/UEOsWv0Wt1OcOMQO+yhqsrqhh5dmxa/zqLVddnmzO+/HJeu7HRt5EutbXG6csh8TmU3X2p7my9VzwnzQFdX
# DATA ZZSvWU8zMFFQU65ea4UOB58aFpzkPw3+3XDh4hnVKa8rZDipDM0inU7VmnWUvasR42TFQC3iri0C49or+ws2wuasEthim67WGMeX
# DATA c3w5x5dzfDnHl3N8OceXc3w5x5dzfDnHl3N8OceXM3w5Vm9UKDn2eVKivyNf+fAefb2jfxXQHBubn732jjr+NzQnIXFYj0lmzGQb
# DATA RPFkj0NnsproZ2a1z+h/s/sL3CbBqh8UgE19YziMDndIE26PT/CsCfxOORQOxno04xHB4M6cDqI7aL/5oL07YP8SH7C/rPrhc3Pw
# DATA PndsbVdDZJE3Ps06oxGKLAsILI/p+zYtxGd7Tv8FO7F6kfpO7qi8CW3EkgrBNQsjlnUcLlBFvK8APSyGQLlKbSjjwIy00EdLeGN4
# DATA B4N3tAQUrB8xGyy0VL+he0CTdYzT3rt0NYHIvVY/FJkoRjQodQWqt4kWcJYT5VzVlXgDsp/PlOMcel8qBJ5GnYsezWVaoVSmy6qH
# DATA W5WUSk0O3msbfsGq2w8SGunG6rS6bH7V4tsfhpBbNDL9aXQSpjhQrwRFT8KJHM0PVQX1JkgIcxLYgR6HqQhTSOSL56EXIYuk/mC5
# DATA QJLMIeiyRvlqHHUuG2rDTEqCKTbcQWAThocvwyg0UuphxioNSlgrZDwNn1aPF1ui9x6oN5eIHHoREzFLSENXJAhgZlT4YaoABskk
# DATA UzxGQ9PhYNKH3gl6IY4vTttvieRH8po1mfgKnVi3Q3E2srORyzZyqVY5WSonS3UV63ijNX5jclXfi7kNsJEQKqEnrWBDOfbQ0q66
# DATA ZU3E24ADi3OHITiwHtMIOQeVyu14YP2Y6Z3MhZxw26xfhAhu1MWQ3YESLF4nIHuNg4kvsUsIL78gwvp5E2FzIY9wa32EJY4qyn45
# DATA yvXNcWbXmF11UbX2+MV3xDO1f2E2FynM+nse52BtnFtXjbJ2mNENH6z3uV0Q4zwAE2nrkpXXa6NtxVpVHx3pViHOG4HIby7jydAa
# DATA 0dBbvLhc5A9kGJbRPZzz0RtewNZzKQNO5t6LT4kodShJ/pgeisDjuu+NohN2abPjeGE8qtDBWiMkf5SyUJ0Z/2fRsWZeGQmwH6p+
# DATA XXeFAK6FwKJj/ywb5DXv35GlMOR5D/WMVjdLZv8QO4NEdU0zMsWVLR0pNxZKkbyZTQ9M6WiaIRy4eLFpyvYSG+H26OqMcGeErziq
# DATA V6wtZ4c7O3ybWf38yMaqwU43A/aBoS3YKvDA7dBYZVrhcT7UKYnSSq5iykONETiFXif2VmHUQeBzkezE8KqciGhzIwGiZMtYMDNy
# DATA GGST5uqV6cn5S7lhQwK/j0qhZxE0Og8dP3kXfvKMfah4Qrypm+8Ud7JMIfBpCzlZuxUt5x8ots8/QTnPjUtiJD/ZjJDU+SoQyfsF
# DATA zz1c2lRlAKVNIxRTCZiaRkeUY8Y/y35YQWLRf0aYOyv1WaqRGd9It80WMU2YZQWC58o1760wTU8hyprMiu7xNGRmI1uti/RUeYlZ
# DATA lBV7IFOJGHzmyUz7ydXkwW6k+eqPbiL56pLZAymj/Jbkm/zVKop0gTf7csMMwTg1M5GnYoXmVfmSxfzO5mLWjUIVs3H650systeC
# DATA ewxd0O+ji4WREwqTNSWLXa9yZBayXrQARCmal14k8GySnExORRI6ZWVjdK4Yi8xSD5U5b+BDBzk2veJTFeH2pN1aIRZ6mUuW48db
# DATA YMZ5f6VbrKBHlERyGoHFSkPObKjEwLkkNQksb6fDOKRZ4JQN1FG0OKXxdIk8jpXzKtQtWeHGzGSeF11odM35aJlZwqHB9xFmpOxz
# DATA Yw8YFghjAa49ddvcltBbK9cr98EPdu6DqcIu6Bah60bejNnb2cPTlf5Xs22kWGHViNA0GxnjaBpnc9a+9t7nHjNkL8EkTI8gKw1l
# DATA xlmmOfUnSSr9q7QV6VxHIRDJcAtcS7tcn6rnv1v9/s7dqhq7yL6CvD6SGqqBahhqgrVpkrLuje4y0cai2KHwtvDpOIjjoCgV3zo+
# DATA msHVIxNRbWHCscLS4DA603nKevXU60oxczyuo+3tkLAXomt9+1Jdq5Z1h2EyTMMTNBDenTCJR9ZCtXKu6TuU9RCF2BZKmQPZe7F3
# DATA bHsGMxouLG3yDJaLmscuP7OWrbYHDNJwjjznI6F6P4X2kD1duW5N4ZVK9HYB3k/loX35fYo5AnMQ0WgfD7IiAvPL85+ffXH2p7Ov
# DATA zn9Nn38BniWwlX+iP78Ax/L85/riOizmN2d/pP9/efb1+T8w7vL87xiK+SdBYnLQv6crv2Z+5tdMzvTOf3X+9wBonv+K6ZgU9tkf
# DATA z/+RgvgV/f0tvZNCwE2/oB/+QD/TPf9ML/nq7M/nv3GYzBfCUYptaeiuVLeoah4HnR2IL4qHsD5NDyr8/Qib3eFFHQBZp0AtxyF7
# DATA rkIzRTA+19CDF24wrnnvPJpPYL5QZ4rCQqyVQZOrA2/lZ741ofFLWiLi5wiatg9V9xm3TdBcKZSbY2hypTR3YWshr6krD+AKcZOq
# DATA dpyY2x/wVw+iXcsJRMKuE6AZZxIVeA9lZ2OEM78h+EGn0cLRM3cpuxsgZ/IqKa+Wx1NMdRGaqQCqe1pEfERtgHrMx/q9D6IwW6rl
# DATA W8qxJaBQTFdAyVFfaXzPGXOGvEU8iZTLOmV/ORlIw+VkFae5W5XcbOmU29qzImrulg6H1HR2wU3YBZq1eRVz4JVYTr01U+D6LYGd
# DATA DIFL2QG3ZwZIvSzlgo3bfN7a1E1wOEvJ50TDTc3sQhOZMnxTKxTnmXMMJ8ZE8TjtgzScW7z0bJT/cgCffhsyQ3w5Gl+ZPYwWA/i9
# DATA d8Vx5iO+ZTFQ5LJ8+J+KnTDEvjyoRkGhhuLrSYh8sqZgD/DCN8UtGVaVHx/tPMt4H5nHe7jEFtFORRqVkFzxRylaJ2+UYLdVaJbR
# DATA HHrToTcdevNG0Js7jTU7TYEuYzTf5hTgKjOA65oAOPSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbzr0pkNv
# DATA OvSmQ2869KZDbzr0pkNvOvSmQ2869KZDbz436M1GqzlsB1dFb7ZHnVH3BUJvlhafd4JvUugxDYveQGTGepyXg1OhG/byjA2aokPF
# DATA vwTtIr+wNxxF3dVcBhMwaIz9oPV5teu1fC/wPb/e4z+NVrXb9Mg+rvYa1Va106v6QdsLetVO4Pkd+tIoFka72231InlHMc5BM8jj
# DATA TO/L49wO8igLWdSqGK1GO1pFWXZ6nt/qjLvdSdWvU/Q6n/cosu1GNaAf2t2q73ernWqrVfWbvVJt8aNB5JeYh/12OAqDdczD5rqk
# DATA NCX2AxXjjgVhbFpJKdbxYXcw6K8hMvpdrxF0P++2q01KSaPn1SlNXc8P6p9XqSwaTUqh75XQimHUabbXxq3V7eRxo4CtbO5ZNaNe
# DATA pEX6zUGzfQVSIzc9TWqUVmyRGikug94upMbCFZAag6gbDS1SY9gedoY5qbEzDIahRWr0W4Nu48ZJjdjbXt1m0tCAa/m4xDY2D2lL
# DATA xoYSIpUjvzQjbna/7eFfMjU8NjfyIPR4ay0xyq9sTu7o9Q+s+K2dS3CIEBS2ff513M1zEG2aHloGeMEVqsr9cmBFcX/lUMhSnrQo
# DATA T+jfhvxbWK1qtgw2stP69lrCoxiLlGaZ8+XLpdYC1nqE40ZU44WVQduT62uBZEpgF9/O4ZSKhmexpcmQ40A6DqTjQDoOpONAOg6k
# DATA 40A6DqTjQDoOpONAOg6k40COQjTuu35VeIqy6RjwR7JmNPLxgT7vfhIpfybjHvcULhIX8IQEhar6Ljb67fmMZBxMhf1YCETNVa1Q
# DATA 5MrFwYiILMST1XF6OWrvzeNoEOnTiDgjB/9hH+VR5EDmJ2/c6XB3Onzn0+HlI1ruoLg7KL5dd/u5OUD+IH4kTahC49PsFEv+sRyy
# DATA tME35sijJZqKJjORQ5149uHqqWccBeWeV52dHiEUOZmZhZPokvLZRtVSXI/cxOnmZArXqH3O2yln76KczTtKuCriw+b70F/ith/R
# DATA 3y2a2TQoLgR/+JF8fBH0sk0eXFIk8s3NIpEqN0Ug8k2c4hzhWDcGpVwPEptlPLLcqargPDhO54PLSlOeUwh4TuKRnGBOFkyByHho
# DATA ggsKwXijiOrRBAYRTVgSOXjMKdFElKfRzrxqlry1Y5a8ozVBaUzWGfJmOIGuAGv1cnSpMfEFc+ZalnBYVtQbwbtMTyOneIGE53Vg
# DATA ztHQjD/UBMn6i+VkPgKbXUfG6HZwyXz50eZ8kRalaspyyJZJXkdmYUpzUm9Gc1oP/QyDQSHdigUJyAzk8B9YNFylopkQyiBIkDFH
# DATA hD7P0d8fn2rj5hnWkX+zYx35KFmyhsVPl0d5fmi16blWn06mI2waAaaBOoE5pldoEEwzUhijIZkaNJgNKOMm42SJE2817xNMCFhb
# DATA gZUSxK47moQ/M0IdT6k+m3eFl8yfj7Zoz+pOVXKI5tfeXF+SHPooTY5RByjNNLs5igw6ljfJUaUJlwOocNyfecsZkqt7GAgEMxAV
# DATA WKYJlPchFc2Ly8+w3Xy8Y7vhSq2UWyxkLSsyTJMl1MeXUKqYiPGQ8hlZ+PtBxRoOdc8CpeVYulI2y2wh3lCqC/XX5fy4XSnbV0Wh
# DATA ITez3STcTcJ3noS7GfdLPuPeOJl+riXbeB+L2dEiVFbe1XLvDWrQ5RLW+y+RXLOtritbKa3NoXIhnPC3svzZyr5IqTCDBDuH5GWn
# DATA s4GOiTppfO8HK9sq9SR/VV3Oeoy/cGoK4/ukQPYCfIJZL6w4NqTqSRN47V/IH+Kj0zzcPKe6dS+SnNOOwrae2VIl1bdgOJgNVFsM
# DATA tX/5p/+kzQh+5TgQKTuxIL1FNJnw1EWBJkTR63uwPzPvSKyscMG0iCFU2GjGMl5O+7q4Qi8dny7GU2XNssHKc4OjWH4Wy4/FyDBt
# DATA hqiZpfnl8Z5HiHQpaeQK5VYa5YJzRg1Qr0ALZihHV5yE6YqmbrFAGWpkDEcmVr2CslpWMM5qc1bbzlbbSn1zaydu7eQKFttG4/Am
# DATA xXcZ0DRSOvos5o685oX4ggbvsxeE32YI4JyfZ6+1rCydiK3ItuWwcK2wpiFL/XT5Xep/+ew3X/H2BtOLQPf6UdOdmQtmhUEOiJSR
# DATA 8X4RdG8j4+s1f/P6i9pQYEdWLu0SW/OwiW5+xcS3d53RVRsv6PcPtP7vIlkUqsTety+KtgnERDu/ckE21614N7ZGW5mvZsFMdqXy
# DATA KpdU+Yi3eJimkFmIKNSwe2/ImWAVZ7U92Xaq5Zek/4kFVTWnsVsZsXckiKeEP4ltxSitvAuwVal/mJn9JWh8xrj9QJypRqmZkcMn
# DATA 43gS5f1EDLXaBfbqpCx5a1Y6qDVHuXgzywOrFU6YuLJxRba+kalbqgJ6p5U3VKg+0xto7WB0qVbfQ6laTul+bA/Ow2E96UE4g3bw
# DATA nBIQ45ximM55oZc9x0CRw115Mo7EgM87LqQMQtPcr/HCFhkdNU/B7JBCIzSdLefU9Sj94KK49B3O91fFerYgXDxH5zmEzeH6J2Zw
# DATA fXn+S+FdgZz1zdk/KzQX4FxgcX2xSuD6b3TbVwB0CVrr7H9a4dAnBmz9ke7RkK0/n//m7H8ZStfZF3TjV/yu35//ByZ04aSDd/a7
# DATA sy/P/idVmnDigFsvhP3Pxr21dQOowDQB3nWKfoLrm7FjmNSaQZ6cuiRW76OecSaq3yesGy5LF1p2u6K4oUdo7OOwj35KZuuihs11
# DATA BmLn/QgzhG2wrU/pLhMhh9oqmP55z3DbtK1Sqdwca0to34b/xFuyrbdad/40o+LWNxYr2HUitkIBW2m4gloglMQ4vNYFxXXtaK2P
# DATA QjI68TPFulWv1Ot1HjUoA6iLqnkf0QBirB4mWPCkaxzOsRasd/4vwv4hIik46sxAKFBc0SMaCHC2oMzQurC6bTZTio3nWcGzLkyA
# DATA 42a54f26h3fNzLr8qP5qOPNucUS/7gF9p/F85+H8VkZzqY2FpNs+uuepDd0EI6uQcEb8ZIrZbieTJt1hphbNhlg068MyD7GTuEIJ
# DATA jYH0oUYTUxImMVhSs6F+7SiMJ/BXDkKwipgtVEwWRtvQZPSUBji9wBzPsjmSBBcptZBdaVl5yKwZkMn7KP5MaeKt6GOqc3Cv0EU+
# DATA U86nzdm/McMKH89hl0yImofigE2GjMwSsyAzZ8UpRQ9OyXh7BE9ZPAzVSfZIDMMowz7EOBtjHTOEV2Mg3BWkKx5hA+JgHE1Dj3e+
# DATA M4VrzmORQ2k5lJZDad0gSuvCMWinqc6O5vPtzQKuMgm4hjmAQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl0
# DATA lkNnOXSWQ2c5dJZDZzl0lkNnOXSWQ2c5dJZDZzl01nODzgqazXrryuis5qgz6rxA6KzCqvNO4CzOWI5LjzNO0Ex1vyBH0fa7xQxv
# DATA 9Hqbc7ze6DVXQU69gJFUKigLLtWpd3u9/jq4VEMCGcQpS1Cpl7UttlSD48kH5rpFmtSw1+i01z3fau30fK/fa/fXPd9t7vJ8N+p3
# DATA Qr+cCdOg2fCCoF2lit3qcfUOpg2/VfUD3+NrVblW9f1G1W92qp2O53d9O2jeMFrCc3WH3WFvXQ4yLqxU8zs9r9nwqcLj1V593KuX
# DATA gjN5txJc7woILG5CGoElrdFCYDXa7X4nuAoCqx71otBCYAUUUCdHYAXD+rCZI7CCbttv924egUUzoSr9vtOkPQhorCz6rQojjYx4
# DATA OkSPD8gZ7pO24ZTxqROsA0i1a2VdIN5y8rjkMrHGgJW7w5LZb0zxrjLF8wf0qF2eB66b82kvYZe9hLI6CD/hmsW2djERxYUAmSN6
# DATA 9sRHGXL5E2YYXLNiV8ZwrfX46Ipa9DBsgnYZ57GKDvzG1vSLv1+QT8UXtZEc9isWtp5sft6M0xe8ZsMUbjPWy1TwnXBc2yrv5ml9
# DATA qTKvq5PLyYWTS46C43w5zpfjfDnOl+N8Oc6X43w5zpfjfDnOl+N8Oc7XK8b5Ql1QJ+Sj4aFN/VpgyZQzAqm7K3U9WaaDCBWEa9Vh
# DATA PGIjUzXMe606DJ7FGLCCd9I0QRzfVpYXmheZPNRHp0fSJ5vX3i0Z09acgE3YCiYXFaF/YVsjl8O+MMdMIPSduorPXmO7Rsxz7938
# DATA 6D/Z0afZmr5g//AJ2+iP89hgq+UonlF2KKoZy4gq3YdjK/i30PlQc4VLtYJzjNNQzlBxqeOtfexRpvklv8iKnxLUpa4GJ6E+TIx9
# DATA 6p3gzKKyPuk3jiBVa859nNqp6h/pl+9uszu4DKl88nTdzVO2/7gQGRGjMnHQIo3qTTgNiHiI1X/4xBjzn71mAq8hbvRWc+F16qtA
# DATA YaNr1NrzY5B35EadG3z2qJxelVxT2ba2F07nusLbLRiazOH1FBDby5Jne2JDDxbphKZ8f/u38hWbAenr/l//tXynRylPP3vtHUY8
# DATA vLb/eIPlrYxu6gqzxQO22PekUJ3EvVNTuJKaglNReLlVFC6rbv9M1RWMA1ZSJGJ9lpL7IkR1u/ehluHmlPJB1iWkLePNCXlbn93P
# DATA lQcklnho24MPuN3yNi8sCm18qpAdYixYbS9/6g5iqnUI+WjsRoF7Q2JSUgjUqreL2z93YhMvwOFq/u81kxOKohjXzU0oa42spSZc
# DATA ViXr0zRWpls8Y1Yj2W4wZoxKltEBYeWyDBbwCYTMpkvRcDhlP3XFCOhLZVSVhysKRslMFO0tTQ9oHIRs0SejBcOV0ojd6EzgUsAt
# DATA NvQ9XhhkvfFZ9Ih9vEpZ40KO0ctxTt6E4Iw7Z9ztZNyVlHKcZpbTzLqEVbfRdLwpLa33RLCJKraayysnAlfznOxz24qNtyFyrzwL
# DATA OnN10t/QOzG04ri+Darp4inDZXaWFQTWKSMnE/ZoMwABa8U8uv01XEyH6NPk04G6oCxq+VaRP+wWV7f92K8ElcZPaFDUMdogKa+c
# DATA avSu9/gTV9kigtjcYvrW/KEVAnDAyIaTxOOtJFvAw00xvME9LN25AgreKCZvfFh51XlxdeQx5RF5KWUjrZM4WxqBs7m0moqSMPs3
# DATA 4XH4QLpYpWYGwop2g6KZqHxgvbeTWVELTVSzQkBabJec0seiAROiZ4JImpwqR6hp7lC4EgEuevoEp7t46GTNKcv9V/NMcWFEJBt5
# DATA OVgsFYVpEk9xkTcaQbAKInFMu4B2V6ajUqoI+VTENpPzqYWUVtF1irmlXuE3rkM15zM152LZ+ZfDQs2HGWeiOhN1JxPVtkWcgeoM
# DATA 1K2G57MWe/2w0EhmGOgW8TSHMj2QZVIWQK1YFEBJnfeOlkGEwCKO73B20e9oKsOEx2rocrJaaHhE8cKWs9mp0YPcUcGVo2tiIyQo
# DATA qgUQdBSDgBortfuI9S3Reazx1qkTx2ssVdmjgArGnxQdSFky+sfcuDJXWHoCyPmIw1Gxkz03plvazCoyGx8Y+iOfi3aldYfpEu2n
# DATA VkxG7BzA6IiOUe6Lt1mYaJHal7z5LkvHVjCO5uuWkKMsPuK0v82fttiuRTa47CSwDRZFM99kNhbKGLurpbFeAcCuc+OSAPbHTzYT
# DATA 2CVjhcCOSVykGenKaX+qSeyfYMsopTxdZrLdi2vgjLVTlZAu5kAgc+oV6BibMEJsoPD6SzJ0lWJqPKh5b8cssLpkoV1vGmc8e5S9
# DATA LtiuxBRR3gQi17i18sqwkBiAIKLXpYrP9tRo+1INumQG/8s//HFzDhdqo2Q0S7qmkQj/wq8aD+KFQd7zLzl9ibVvyagWLdVkrk/d
# DATA L6i2pazji8Ori1js8/sjPhROc4NpPz5agvuoXL8V3d0JKkrojyEZ+yzhGw/5N5mwX0eOXrGuTrPd6uqH4VSqAqSs86yT2oIpDhRs
# DATA ZZ+vqNpCp3oSLYDEkt1N5mmPMR7ovRj0cQq0rNC6ZlAGRIMg64+iQ70nFYXaoGAayLOvfv/2UpVPWGcce0rF58toGen8ex8zOEza
# DATA aAKdKzGfhDE7c/iCOm4eAQD9tjRIXpOQipPlFZUDRtaPcLSA85MycAYXEge0kKeA6Y1AUaShEoV2LVXPdO2XzMj3ttQ9NUhIHpZX
# DATA KL1FGh7TuHlCadCZ+bE6SjBWAtmhVMuUbJhomCmjgHq52YLBcQgLdonMT6ghz0zPoHrVKfUaGc8lY0g8WsuqOVxuESs594jmv1qF
# DATA G7bfM83XT3bN10+YwGctV+F8Y9661XJYGh1hP7gcEKGEZGrIwGiTq9cbyfOMfRW5ZRiNRpzDdj8Q9jMWr6YZGrt35B5VndGbitUX
# DATA o7P9qexmLWVo0UiQPYu2kWCuSPaQXat3F+qJHTtb1K4/6ogG4wT6WSH8pVSSuiBeiYU3G6NHJRHZBL3/fPbN+d+dfXn2v87+fP5b
# DATA cO/OfwEkHv33m7Pfnf9G0Hi/P/vi/OdnX+Hv2Z/Pvjr/7SpRzw6HWXm/YBofnv3m/Nd46uxrusi8PUHv0d8/eXTLl+f/QM/95fyX
# DATA wOkhBv00Oqka9N7X57+iv7/Fz0zc+5ND670I3hqpaTZvXqacD2O00plsCwax4YfGNyPK9zDHyGIYQumHLQVZ38DvD/V2kjQaxHNl
# DATA c2VL9Efc2qcJi/VvJem9JfGyGpCD6dleGuTObXP0Vsvk5lB6UnXylcSPpSqJ5En5ZvRE1ppjdHIjtGzeUT1Xhy4oK2TCiLdNo9nS
# DATA 8fR2KLNrR+qJWc99OXc98DKL36xPBoTu3cSe527sk7xbouqanCiojyacs86aoH/50AEKLZ5OcUYHMCEqbAMjvlT924IBLjeqZ4XY
# DATA uzgRjrHnxvmnHOc1Uu9Kw/srsgBzK0P7DYzsOw3slxnXb2dYlypZzgELrfcsm85NkPTKSdWLIuJSDVlusjQiZvaQiPivjIkVgWLJ
# DATA 4qyssYqSxXG0SOb8TJTxgfaEzKXFOBlmu2DyPkYeyjJWOUaUvfAQ8MZdSv40xgaThKwy7NmSgT6vLvTOMFumAIOFLDBKmcz+/Ip2
# DATA 26cR2g+n6JRLRnRwhAQIxwqT6nRlyMKJ4L4GcFZrnpmj4TkanqPh3SANb5fRY6e5yq7G7q3a7Vcx26/DandUPEfFc1Q8R8VzVDxH
# DATA xXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8V7bqh4rXbQb3SuSsUbjXrR8AWi
# DATA 4pVXnncC4xWob42eRY1r1BuG+uZ3OkVu3GjQ7am8oQjGNLKaIBp5EM1mPS+bQGh7cngq6BXC6zSDQWOwUlBBy/eCIBgHnfqx32x+
# DATA Xm17Pb/qN1peL6A/9WoXX6q9YE3JraL5WgGF1qqPm+3POx2v41ebVA/85gXUORPYCiYu6KzNgK5F7qPIW5Wz0cozoFF477eag6Dd
# DATA qK9EudGue37L/7xKaW1Sbal2/GmrSXH/vBr09JUrJ8APrgC641ahQXfSwCzQXafZaDSbO4DuhqN2EXQXDnuDZg6667RbvXbLgO6G
# DATA nUG9b4HuOn7Db3ZuAXSHJlXdbm94PLxYt5b5cN+LqBeIw4oEXFrMW0HFNXjBLF8uKwat7JYVJ5XOoRVHZMnfb4e1zgN/qUHVY99b
# DATA nQ0n9YxaAlubdONWXY2kMcuLCDkVtqDr1m8VKBPtVjFra3PGDHx69au+jQa3Qy24KVPEod0c2s2h3RzazaHdHNrNod0c2s2h3Rza
# DATA zaHdHNrtFUO72TA3STYf2LorILUhTrm9tv8d+cZLjozlUsizZBFO5H60qNc/CBfjGs8k9/ji/uuUAziOSu9RTrQ5NGaWc759r/CO
# DATA O/KNfsy4F1kk72I73p5vh/KpHCazAim/sxQMP7ty5EwTxGQKaI50uEPU7hD1ukPUpWM+7ji1O0592ePUW4Rvb+qYtbQCtoOh1y6r
# DATA rOaY9TMU8rgN6sJQHc9WNQNfvb2jfSVpq5vdjB0YuQC8eirvm9T3nFlQZDFMYxagaylsA/v+ZdEJWyx4Larmbxa+lfEUUsxmWEMx
# DATA 4FC15P8F0dXPm/iaCybCfntdhLtWhIPd48uDKihtHA+OJl25IJLqoVy3V30vcCBWYuhbMezaESxGbyPv4S3VoiIjGvTi4h7eYiuP
# DATA hzEGeGFyog8kvzeCyib6ED6Gn/FAh7aXkVkyr7BPk1rpBF7/yakHJU1Ushi8PDGKxFsvdC6pdXxunJqhCnFIQVCAMHPGOsBBAqNH
# DATA haSPgzN/gmtylC2w7s5TKpZgmrJFbIkA4DQ4KzDyMuoQJ8k8Wbs5tMUAYLKh98uSaaQ7ovdp9nKMGdKYARjcvgfYHawShGjnfc3F
# DATA gIaX52Cxg8Q6S3a7Jevs1pfcbr0sFPaZywPxgrm1ELxq9E0KkoBM/clYdFvxD/p8jBSmyFaG6jNXFXpBFDhuApu6ooB03eTUNWpS
# DATA 6+GpuykhluofstqmKbCI9Jsp0qqGdVZtzxWkeU+PnggtM4FTaX4q22IR5lnD04KkS+hho8RyquwzVDD6kEXKUEJgUpOKBopCJ7/L
# DATA NxijpCzBzXH+mMVeJcoRZbGO8XtmohbzHJCiKnpGizitsDI7x0arshcsNK14b+MD2CBFUGQF4AjGlmh/hIW57bF+AOiKijVvU4qG
# DATA OuLvaImrIc1uERtKAudehad8Fe8Um2VF1Qk9xiI5iqBiVfMsozphZdGpx6ACRX3ZFF39wtUYv0ICNnaf5CxNZ2muszQL45TzmDqP
# DATA 6UUG6rMXppQYZEpZMU2SKavUcYPI5SknE2kqa0USa6qeV8RZUZHBCLpzaEZYn2YqGHtWPFm9U+2KlxEvRwF7l60Epe4obVItN3KY
# DATA 6PnmjN2ECzicYAODCGQ7KNguUDCxuGzTatOdxs/NdBf9ZfP9WqWTc1V93ny3lvEsmh/PP0Ysz79Lclz8A7+9GeWiC0NQLj+YRdSZ
# DATA zNm1WMWRRW0ZYn3Db3lH9kpG0KzTBeVG/DRSBDKagmCr3OS0QnY79v72qV6M8HWB8RIhYw9JhjUPOdWRcQ8BY+skzMaipaotdLo0
# DATA mWTXwcG5lfz75CTh/BvSODUv5l6jXsy9ZtfKvQe8UINkc1+rMgmKpQA6L1iOUqQx5S7xC08i4IuwWddTh3BFqPQacqvQBi+fYa3N
# DATA GWY1aMmz71GfSrF7N+Wp7FwmMHm+BaVa1+i0rHxbwJTiZTI2nOLZcoEhB6Klk+LEikcMhvVQzaPZlaLgmUnYMXY0Tp6DvGtfIu/e
# DATA QhVIRVYiXx8sZF+p2jWCein7KjyVZhP1SIoio3mqKKWC2CetEfvRh2l4gq28emmA9WbzpYGnyTO7D79kln2wOb/y0UAh/JKHobau
# DATA dSa9y5wK4UYA3Sf0wmOyOYyZThbuQ2p4E4V2GrLq8DQZMsnPG2Md2PtYhIKZaYUrZvnErMpkNNBTrrMmL1r0dWSbPZhduqYFmzMu
# DATA Hxgl44xjoGig6Tx8gKvK6zLz/C7VsKHOq9BrtHnPEFVUbAtkFwJNl5QjRmw3xshzXUu8o2Ws+F7MjVXeGzYbecv584rwelkcEjnG
# DATA axQvIDFrc7z+37Ovzn959uezL8HY+so7+8PZ78++OvsfZ18yeuvLVWDXf6Gffnf2DRhb5/8et3iC5Dr7y9kf6aevz39x/psKwvn/
# DATA 2Xu7JjeOM99zrvUpyp5wdLcJgCgAhRdSTS1FUS8zksxD0taetbSKAlBolAigIBTQzbasCNmaOTMT4ziO2J2IjZg4uxMb52Jv9kJj
# DATA j45l2dJc7Bfo/grzSfb5P09mVhbeGv3KJpmySQKFqqx8zyefzPz/KEwK6zv67Y/e8d/hpyLd8Q39/mt+0zdH39Gbvz7+gvFgQHYp
# DATA Ativ6esfKUD6yTG7ngeXSgb1Q5c5tHlA0oekMXyg1CQ1LnAy60xZ/V46FMqwaCrwxX1M/+KhuCCl3cKF2sPpc3AAoFDCT4HDyBtR
# DATA ebtnR2nkJ+FgLcbrPlbGu+GhianjeNm+FtVBXDXIa0mpXB7JS9XCbMnokaqWg5jiOTmcv19qo775nVwlvUiYF1yGKiaihS878yMd
# DATA Lwf02qzoLpzp9SjKQAcZC2ICSKrusgyVg0vOS9HbYC+QyAgzVMGcIobn5xBfS97bcVfPjql3k+m1OKdUShfIXidXxtX2zGIre1Zo
# DATA r5NT4dBezhy4eHNA077OZgW8FKstV2UBXIYBsNH4f8rh/2pGf6mYC7lgQb+uWaO6DA7YQvIBNcXaUMqc9/UpK3ANhOoVJ2E+ne9M
# DATA 1dYI3gLBIiFxODFv0kFxymXBCcWpXAcbkcEes68X/iBswEnheosm4aCgLDka0OLuDMUXdbkYYaxNqIbwGnI3wzxxhLUpYHaMwDyg
# DATA QMXlAecUtXG4ZuJRkbKYQeweWRfTeBRpRxUvnyF0LEPDbCmIzUIvFjvEgKAcJcxRwhwl7PIoYRsOORvNgTY1na92GnCWWcBFTAIc
# DATA KcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCrg0prNau
# DATA dvnnM5HCGr2g136OSGELS88bocLsfPEDr+o3+0G9NUebqlPv2IyW0aaqTckhLiMpgxorUgopy/dzSj3zZVfx7cKr5/LfvDMXetDy
# DATA LzH0Vj0LvNbKBS6pygL3q3UbApYLvNVrttu9+cDrQevCQ8+B3mrCYhNImV/PQG9BMxdAFIRhs7rQLOhxz/eb+7VgUGl6fuMEAtnq
# DATA OtE4A4CMG5sGkEm7zQHIgrBV3wBAlrsCAFnQ7fTKGYCs3gmiZtkAyDq9TqUbWQCyoNZptS4dQKYb6Fr4VMkPNIUsd78ZHfUCQbAJ
# DATA bSwfhOaNZf24zqkFR6b1aBuLMkue2XRZoFRXFkjFdjxUSkvWhH02iHJvznkUxDLAczx/Md4kPyA7ASbVEo9kxXgkJVPml1mWLPQF
# DATA Cy+o3NZzLeq9/cwumYt+k+25ZVy0VquVp6FhlXk1pSxXboW5slhj7eRvnPM9GPehw5A5DJnDkDkMmcOQOQyZw5A5DJnDkDkMmcOQ
# DATA OQzZS4YhQ12gULqDqBDxMlF3t1xgpzt/GpPZHaW7P/+oAIfqfrTLFmwBHe0D/LSLKnnbVGg+XQbraLK981nc25aHdj7TQVMLhQkS
# DATA jjpRaUQW6k5Rveq2HfxtVnXWBze2JXo7t9EVfLj1ODvG1hWc2OfWHAf7CPX7pRRx7GPNe5F+eoqSykoeNDGebKveCvrEkn5KwKh7
# DATA Y3esdu+nP4Zhd5vSh8Bfpd92PuOnd8e3+UwGxYl+/AFfo3gsTU0uwSbrb5sMvy21DhN6bvRZDaM8f1PpO1PeKyScPvljlJ+9xzgk
# DATA lT9/OaHoM8GD8iNOJPvElr/9+erXMemtE8WD7W1KahFp3rnJpi0gbypLKCaUZFMvqCFx6kvsxt35LKsw1mWJu30fZZzNxctqkIol
# DATA clVySI0FO59lGYaiQ3HGlI3xq4qcx5JuSGd844a+uTSekWnymYr5LbkTp+zovgJHhCbWH+DU3X988U/qTCOwefENf4e6GIrEQvBF
# DATA f2dN2DgeaYf9EMclefljMfTPs7rwuaojPJnUbXKxKqsHbudq/22pZ7uYweqqZ91QqATlfIuazEYiJSyEPq4O3MrowmvrDNyszaun
# DATA JjhDetJTXL52d2HV/CwH5vqZdU3iIVRWs/agEoWo6CSZOeCSaPEZlHhA8yHTp+oaaB6TsWInF2kK9iAe0XRxWaBYSaOHorlMcswY
# DATA pzNxRp0Jpy/x4utLnJYkcx10J3hlJeevX4+TeQ+H4EHkgPiqPjgd7uFV02SYTGhmtpYpcx1FK56fI9yXQZpZ1Ni4aNTMMhGTM7Jm
# DATA vNwSkVRpXmG745e1NLBgNo2cGL1M3QIBT6knmciHLfT+hKyygrieRMsekTeWt6zmJWPMIgHXE9ZDfzaZstRXrN47ppF/JPoJiZL6
# DATA MCL2a4Q+TlIefYGO6OcajjOhnAm1oQk117860S4n2mUNvyuNr+sg5vX6LAZTKy9bZaS83hJdKLspYeQZRwka2kE/yY1QghDQA1jJ
# DATA uwsRGxQda+qEMhdW8LHoCTXHcBD3oHgD0W04H0RCahRFXY0ZOy0/xURUAR+UnDak1QtLlLQcPGUTeMowkaJjvXv1eR0QZcJuNJHA
# DATA l8+r78ZuH+Fm3+NPq+/U5o7iC/Hn5wGdYufeKVXymzAcV+vkZ2WRY1mwV0+L4/OsKBvZMH5NktleP2sMnzDsnSU8NC5pNiLjkbWo
# DATA sg3TaM/7SczaVh02Dz19gh5W44zF5sYs3wtjk+KwF00vgjJwjvwLTpd/b0TpE4+d7RZaANq4Cu5k0suSceIKT5lnaJsOB+HgCeWV
# DATA lg/k8HDbbABMN6MavWjEZcDibTgF4XVnEy2uS4PUxTAtsmZ4WjhDZX2+Za1a8u11GuNl3x8zdWaxqX3KtqI6F0UrhQyxejQCy0Ly
# DATA kqXpZDEhVfSuKJ2WvL9mIEbU6Y/iT2eRUVCkSkoTOrASpn1MO/oh10Tk61RV3AvIzaybOm1enlAHda8nOfkB1R1WQdRSzQZDajKJ
# DATA 0shViC1UhRo1SHiycDtPIAU5Z8qq3AtZdlEh/waRmmRytisNOSPq3csPw8+qBddP14JfDwdsR6ipQmSzaGAccIakszEmYJTAcNI+
# DATA VHODjugsyk7nkscrNchdliOfKLYb5VoviiCiiKkWWRRROo46MRNhRf1ycsh6hmYSPooOLiIH7bHvtBWwvD4Ls6FUwVZQuSbmoqbg
# DATA 0rRryF0bOntF6jHTsE4IKg9l1AEZ2DDVsYPC65NFiPqFLGMVUBY+pEoNHch9bBVTe2yuLVTlBXJtZEE4v4bza2zo18jXNOfWcG6N
# DATA M64JrXSBXJpGuaqyOforTHGq5sa78cxZGeu8G8xkXMmx543evMyB3d/q5KK+Zia9vKvBHjnNFT3r5VzKzkdiZwh9S3o9MQ3CrtgF
# DATA OYcE72qhn9lGMr3OttqesqP8IrqFj3hDP14hkVJPm55Rfzfz/Koc38QwMCHjnowXPnOHi8PwqdxRlnNy0ZiP5q32nfAmGU6JVaYb
# DATA R1U9baKqv5uoVk6Mqt/cOKqy7QeR5U8nxU3fnsXOXDHxqy2Lnm9Fr7ImdmpV0Piz5FwAT//A27vJ+xSHZGLLjWx+TIZ3XhVphSwL
# DATA cSzEroPZpVydG9PgPpXjuDcliKwiG9+M1T7MpRUOHDGJaDLYtUztnML/fybbtKMnqDQx72GUNCAdmTIchDS8A7YzpkfJQMMMTFGB
# DATA slmsBlIqOqGabAkl1ez9tZCWGJKTQZFhlrxji97SBQ8zEZoovCgFrxv/4hcxhhR2r4xmKQT500OyfZNhmnlR7Zj1o8H4hIXjuVLN
# DATA Fo9tv2q2DCz5L3u26PEH+JCV+JkCk61c0iijqVV9xIblEns5rHKLdTibkE1MJp1NO/xvDC/8GrTBPIPw+Df4e5F2+M9HXzGP8E9H
# DATA 3x/93jv+m+Mvj747+vb4v9CT39MnxS1kxiGIhRI4h+wxEPErYBSPv6Abfnf8D/TQt7jt+6N/o3D0k78/+h64xG8Yg0hBOubh8zDD
# DATA MNUrm1hwhQfxBDlKzxSUv5I7HI3EYOEkQ3eWCJNF9IBKUWgEMKwMwYN6Um30jOOoQ7PxdXDDh3obAw0AjFZzaENrMqEL7Krhhgul
# DATA cnloQ1VH9G3gbGjiDv+ycD+2r1gd7qOkp/a0XDjakCOQAxvGKVd2hzXcrNguHGt4/+l4gF4m1M6QYdKdDUKQ15Mpa/aUvA/Q93Pf
# DATA le3z4sUvbIynZ83+J4rDbMg9ZSrboOBCSaahXssKR4KOWQAanlwFV1st8y3rWeEMT06Dwxm6kf4cI73mFp5lgH85PIVXNrhf/Ni+
# DATA 0dB+ypH9agZ2qZZzeWAxC59Vy7kMOOFcKrECABKQ4vzFHSux+pzjfIJCcWkqqBxoa3oTdYri4c3Xsq1YS3TDShqxV3Q+3zYkEhov
# DATA axa7dJp0eMWRx2ONimN+HNeSLs21R6mJfjSbJF44ZPwbD/kRmQ1xJ8bSeM4myFkA0VMcLEbg3QjeKLWjWq0VkvVAxfleFKaIENt2
# DATA nSlcMWIksldHKHWytq6Kuj07lPrlaIWOVuhohZdFK9xwqNloarOpZXyVNv5ZTPyLsPAdq9CxCh2r0LEKHavQsQodq9CxCh2r0LEK
# DATA HavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKrw2rMPBrtaBzRlZh1O35UeM5YhXOLTyfmlQY+F7V
# DATA L+8XW61P/Uax2vAaAf3drwaVT2str+LVK161sd9q5XKp47ernd48xo7Cqi/F2NUWyIZy0k8Afq08wC+o+nMEv1ozK2s5tpYR/KJm
# DATA FHYWwYkWH7AZ5IKvVFv54FvVlaGbZOZCr5WDNaEHZwrdLpGm79Vqjf1aa0hda7HW2q+1Ns5pfxFG2PC9wG/060EwF0on6LTbnaUo
# DATA ytNjB6XdaOygNEELO1jvBs1G90TsYNhr9+o57GCX/u5WLOxgtx40AoMdbHc6tXbNwg5WglqzeunYQbNNDcL/exvN19dw+8S+9Rbs
# DATA Im2Oz73NDJRq6vVWRN1NHBYkfksBhoFaiass0PqwsLjwgjm3u2006gLJz7vJ3PN82AFeXf7YYbJ1unEOBdp0QqaIkZsP6k44b6hY
# DATA 2MB8ZO3NBXpEV8te5WXeXllMySetAt8n/6X+2DPu9cTBuWwtzOfJGrNlbZLZnnDAQQccdMBBBxx0wEEHHHTAQQccdMBBBxx0wEEH
# DATA HHzJgIM2302SLV4MIaXxUXFEf+fHzfKNSrlAM0v10wEX4Y5M2TTm674ckuGDbmhkN/hXcOk6QwQcef/f/+G1yvjWjaJx6UP6bwTa
# DATA GoV7Z7f82odbH7CWOp+j44UaBEI/ShAlnvJQhCUsc/gGcfHah7iX6XhhO0WIO+YpfOJ3vWMfZZPUeVE6hR85uuX9x6//X0RmIe3b
# DATA 1Ur5hlxlcU90DQhSo8wcQsyd7T7pbLc70/2in+k+LSnsOpz1nnOxrceEvYumYZ4oee+h2tvaLkvhYM/0dPjzczTyMihg84fZL5oB
# DATA tigJcFYCWN5fq8/qv8vULqkI8ppeZHRt3oDrMfS6Cf2QHvAZ7QdwQqJqsRRQP4wnJe9RPGX3kxZ8lwoowuWzsRxPVoWbO74fZlJG
# DATA Y4g2Jj0+i5yJ5swp3CyU85MIpnJo5HZgE1290s0zOgVrtSBnDDljaN4YWuhRneiNE705yYy6HmI4D6S+MtGimxj8xSdJ2yjiPDTa
# DATA DdQM472RIn8pDTWFj5zQsNCBuEUPN4uSRBoCvwr3qMbj8IZ8lu8QHRq4IQe2dssSzZSNwV+PoToD/1imZGPzYNh3IaodDve1Ge6L
# DATA kgJ9EpX0Kbea1bAvdjuKLDR/XH0vb8/lnuUxf3oe4F1WXpySu/JoDT9J56oQV+6hVVDpim0lwJXHB4mINSUzCMaEkGMRyMoQLUVL
# DATA JKKGh+yFElkmMQ9pXNuHF/kXkGeZDPPqRaJSRLZfko13IQRhqHaEolHfY0NZnzmVRqNmB8uFnRcFoM3Cm9gkWQJNjmkpB4wNWFDm
# DATA jKEHLEHo8/GvzlxyDzcuuYdywFysdF1078IWQUcYMhuAimNPqX+nTPqKxqyOo1hCeXQYio8lfUTtm4pAJql3NZ8RHkO1L4p700E0
# DATA VWCBiYpLOk6m5y+yXMqursyy3uSUZfaTdbQy1S9Jmf0EAkTIx3ZCEbIBUSxNpNdRtKDZnjCyKHepE8fFpEfWiOFp9aID0ZzSg9tU
# DATA JOFxpyzucEkfMP2NmSum0XHpt2fp4flLK5+m56C43t+4uN4PAW7nxQzq6zMeVdoXLX3TGKjX24M//El0KNZ+O4SCltdPhtKwMDkY
# DATA cWisUTfyqKAmoIUBlQNeFTvge/FTwccxNCErzHnht/MXWj5lV1Zo2Sh8yjJ7vLrM9HiuekVRDsS1rLzEH4F9+BgGqAmlwgociCOG
# DATA 5ZE7apxgb5x3l8u3x/gu6oQgQoZxTyxPHJvyxjM+PMfiCSOgXS6g38vifv1LpLJpibwfKeU6DB9T9ZMiXMr5oEgPMNKcxNoQob7E
# DATA 4+NdaAGHIkgoYEDVarh/45k1AoDZzUNZnGojBaUr+ncX0GYWE3KmYrpawty5MCYvg5/NCsI52pyjbd7RZlcp52NzPrYzLjau9Mld
# DATA kuC0TMllpocREJUbNqZxsT1DqMElkedyniy99wT2Pm+yxvJTk/fN8ExY/X4C6CwLxXRX1qWMGncS6qy+IYftQHvLDLiL5wVq1952
# DATA Z3gi4E4CyAB36rsFuFuKjfPlsgbHlTeG3MluHrgL8UEYY0JBhkox59WcA1E9kHkPdQgLPrtGmbFf2NbuHWAhk/cXNcqrvXy+z488
# DATA jp6iJ+paT9Evax6r8WNv092H9jO18ho34UpEnTZNsZuWLLXp8wups113B30KxfuELM9RdFiyJZ+VrrN0AnAIHSSezy0tnChYnN6w
# DATA NqZpkjLdsepMnQXFCdMrHrgpaOOOF4cG9y3isVfufq2uzS9W2848BlxSgVUrZa53VgunPmqm4ZdqT24nX1OhN61k2CkUrcJeIAv/
# DATA qXR9I4rjQKaKrJo9nk0AepeF7SRl/VRLIHsDiNwLYjxnCDnqRaLOJOxNLYTce/pa8fhvj74//tXxrwGRO/r9IjruX5bi3+jL1/TU
# DATA l8dfHP8Klz3652u6+Dv++yuA4+jKt0dfHf+dQcJ9c/S1UkiHwtcY2qk0ZDtM3LU39dkyDz1TZ7y/CvdD7343lrNYInqv9pXw7Lc3
# DATA iaNRlzoQ/naQTAZdY/3D8z0bi+8UrgRxnQ0Oma6bwKUtFFF2GmQLFKrnwVPRU2po3bUIudchoMFaEx7/LTwJx5HLZgSmU7hqjtzy
# DATA ork8mFyfosPkggxOzfVVXz8JJncvFEnwywDK8eYrsh3pXxoTxHWF0RwNxgHlNiu6CwfKSZ6FbOaM0LnJvMpMp7RhoyZTQ+mgyHLR
# DATA FYUX+Gh4Q7/L1vbeLKRGMY2ob3sjTp8UYP3Q0/ce/NRLx5EiZeD4O6VNqcLM2AaCa3G6AW1ueR1dbeIsbYPXBTu3PDEOPeesh0uy
# DATA HjSW7sxGw0vhQrw6g+GS7IWNzIVTWgtXZyxIJV2WGcZQuJ4N7TIodlY2ADSHReJuNAaHikwZM1CbHOLZ/Ips6STD4QzdNRbw3sEM
# DATA osMOC5YUSSlfOpE94k8idlCI9w8ZlqrN9jTSU5Hx9V484VO0abox4Q4grVT5ZjVMjDJknyzCifg51K89mivHfMCBdwS9l3xCI5rH
# DATA yetQBia9acl7qOMtBxQULGzeCbxgt8hZAY0gM5oWTDJDfkAXB9LBfcrkuCPeY077SNw1vJczGjFHByfk0boAIlNVgnLVMe8c884x
# DATA 7y6Rebfh6HWmg13rzPIrn2lchEf1rPMMB8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwH
# DATA wHMAPAfAcwA8B8BzADwHwHMAvGsDwKv41W61cnYAXvW5AuAtW4HeiIJn8eIqGY5OTqNl+d6YUygNmrnsqgWtRhDNkdUqFSqA2hqy
# DATA mvXq1plf3ay0K/Xq2V9dqZ/51dVmo13rnv3V1eqZX12vtKq1xtlfXSs/s7KuNZ5ZWQe1Z1bWdf+ZlXWuXbeaV5nhuXZ9ulefN8Nz
# DATA 7fp0rz5vhufa9elefe7GVX5mZZ1r11db1rl2fbVlnWvXV1vWdruuBPWrzHC7XZ/y1efNcLtdn/LV581wu12f8tXnblzlZ1bWdru+
# DATA 4rK22/UVl7Xdrq+4rO12XfVrV2oqtM786vNmuN2uT/nq82a43a5P+epzN67yMytru11fcVnb7fqKy9pu11dS1rbroVL2qo1KP6iX
# DATA 9xvB2/Q173RotOtBrbP0sVqtwY9V64uP1eDoaJzGHFMTEAsu79dzQfrNarWyGJOgHHiVIOhXysNq4JX7lfJcbrSDKGg3liLZm2ei
# DATA qVczmrr4cyyaerMcRkE9T1P3W1W/EuRo6nN8ddDU21Gr08to6kGlXq+1DU09bLV7YTmjqdf8oFMpXzpNnZ3BxTZv0jeeTlls11j0
# DATA zNvaFIe1/cw8EN0sxS1bdtMbNRq8QRPbM5mJvrjbsQ4/q7yGD4Jtti2jbm3LWAl0t0Jdz1qX4lJOy8Asu+gawccS+mE3ObjVoh/x
# DATA p+ypUvy8RK8awgW2Ygm2shDc+jzMAvTUVlO9f02Wrcyv4yW7D9Rar65hZhlA7QXNPN2FuRMF+eXt8mrYul1Sa9zhy+oaO7nZr+6g
# DATA 6g6q7qDqDqruoOoOqu6g6g6q7qDqDqruoOoOqv6SQdUzi1FpN2zvGPuOUu09FO2PTPjjthCruMtmW3lwyLhyERUpDpNutCvoCroo
# DATA 22zRqLNrIjJRhA2yWwmCesBXMcsT2bR0V7PReWqsEOfqNzRKDUhHxOCCmEKYbbcpgcdDBRvJfqnLC5JpFyFzYeILqjm3jVJKQ3W0
# DATA XS7UazswjnBQZfvmzz9U/93a/csf4N8JB/PRzb0ClavFaeey9Rbh9FAV2P1sPxzFg0F4q1IYD2Y07U9vVQuQjLsVfP5zjgpPY01c
# DATA PtJ4+kezvb0olXGRBci8h3ffu2Ww8Z0oHmzjDTfms+fHJb/JNPm34tcFWv86y/9kOrxzoUgAIoBDk3wEofnx41ig8n6pooNE56xY
# DATA IhgVRPACmnoidMgvVHUGmnhTyPNNyVzWNUiUhCDZooD0nAmZhixdfW2dOcUZHPdWWLKfmYkGJNLm5Gnp6ayS79zGyALH1ZxGDsQ+
# DATA VAKg5GJL3nCMZSD4YSEv0OF06pxO3Wl06ubEXJxinVOsW6L5s5plcV2U7LzxBO2UNbTycTJSdnfzkm57M0jjQphplXabAluMwJuN
# DATA O7EKGvM7VmPVYlVMo52XpMujtRbk6Mx9/cqdBxiaqGvRERdvuJab+pmM20oxLSNfwQZOmFAPDCBQN1jGKbKK/pQF6iW4FFq+noz5
# DATA eqp7G2Kx0JpSanNAbHnWk4zzhLIVxTmCNj4lJYZxrTmEfOQv6XF0oqeAqImsF3oq8zCNVKuU+jjdbyi7iOX2MqVbNTTq9D8yhpSn
# DATA DSko1gHvI0rFNB8W6onKoZh1LErezzByLjzS6c+gW6z1x5S5UvJ40pAbaAUPLABU8dQWclThzKIg4xIKfdJzo49lzEqMCDOomF5l
# DATA zhKk63LkruriJUdUr86NxeTGNBkrtgHXlWTCanJQP0tnY4zQ2HIMPWeqa52oa/X/0/CJwBVgFbI9g8nX+FAVqh5cwoPwMLOoZACS
# DATA 2MNX7T2O2JGp48Zg19AyxRhEbA85XLfi6bpk8/vxtk8SyrQ2BsOQ6xzNG3TC34UHxbNse60KyDSovF6g0FBZtIuihIWtMZccS8mF
# DATA XerCY0O2UYJyOgEiQ6fhT3qCkQnKadYNAzrDrJUZU42pdtqUU9lAfc4gOWSv7zxkTZTBXnyBs2zUcQaqM1BPY6A6c/TlMUdXmpnX
# DATA XFjZXuBfRJgNcnaqtBj6e9rnAQm2irJQs0dYr0ehsK6r/PLzpSZ6EtDB2sohuDneInPnVeqg51uqPo6W2+TVLM9t8lJHzcIBf1vW
# DATA XhaPiUnr7yRwS8kbD0cdHR2lvnTnJwunzNiDTzbPCiFv61n+wumag4DpjTRaK/t1ZTP2tfI05482xthgWy7erKwyLQ/MvI7Z2LIl
# DATA DYOTBnvYo3q6YDBfeQMzb45aDr45fMV8XXh9FqPmL+ptS6VYIHadSPgYqRcXKCKTiEyXsE1WtwJ8zLV3nH6VpqAJwP3qnUdDAX5T
# DATA bhoaMjc31vINFRF5Pz9rYRlwUN/HUTIeUAv9gNc9kBfZ/IPVzBRxUWSSczrhecNxGqLiatCbsRbnkdIcZVV6Orpq8meMfcwedHkq
# DATA ZprMMLATQmacjCXBLEV1Vaq010TswYSMyM50fcTu8XqDl8LiP9TRUxdlJs0WuBeiKnEeIScPJqyanRyMaMpGP8VDyKHryro0Nvdk
# DATA srcYm5dQpNhxk50Vf1Yrfr7KOT+z8zOf24BfOV24PD+z4YnP8zgMVu1aYr6ugr+sV37ph/tPx7Jvh1fByZSJklmqfa0n8IyzYEy/
# DATA Z10yAN/mSQBmf2OgsTH6P+BuEBHLA4z1DRlj2UwT5rnCapUdvynH/WoGsVqHl2kef1x9L0qdzTb2269hFC+mjNfSTerwjRETyjDf
# DATA fit+/UTEtBVMPg/0RRPP2knFEpyCM82r/gr6R1GVC9gTQu2VMmF9pM3jFnZaX8l40ydFt7ppbHkjR9aBDaljoL5jLo7YnWOjxqfd
# DATA PGdcvpvY3fVSspj0Mo0d1Q2Y1Pc1Kpk7iEnEaxbaM/38AqrNWoF0wINwNqL5EBYE0mmeUW3S3wWchs0uXiOwKEPo2ScgMwMhLb1M
# DATA ybuLy/sx2Tv2IhlbQtHTjlrN8GQ9Qh116ClqJjZ4hAKwOUyxYY1nHTxjEyOK1yqUoTQJY0VvAks6HEtPPVeemQNF9Y7ZJpJcxlru
# DATA EYPkWeQiZ8UueTSHY1rCYeIVtnkQEzOtukkk+Cg18/PAiTpAJaPMYGRoZ6rwPmYUOpmT/aLNmixg9iyNO/DyxImFzD76b8dfHv3h
# DATA +B9BtT760/Fvjr47+ur4tx7Y2fTDvx19c/zbRXr2Px19f/Rnuu/vj747/i3dffQHevjf6d5fHf+m4NGn7+nJ3x99f/xrULQRtJC0
# DATA f0V/f3P0DXO0v6BH/pVuAUn7jx7dBV73byjYbyjYr/D00e8oWn/kJymI39Hf3wHLffyFo2tf/wkhdWLJMCqCLCeILM2d4r6qQ80U
# DATA ILwBLwPzavkDNUKE2qYtCBKMnVNkxo0HkeKFKdoV9X4TDbVnNlhmtK6laD/EQ9QHRQ6dnZvvZd3DVcOzrRK5PGK2qlWpNdPjC1wx
# DATA 0/m721GYddev0xeujO2IxvqLRGVTuMyujvVIprZWLEzqXlJW9gaFduGk7Hv9BDr1ISDmNKaOtP1KGcxuJ0WU5N6Eym1hD7j4fMli
# DATA oU5qPxrcRlz7vE2K7LvU9lKFqfSGenPKaerfagsma03Pin19YuQd9toN6+cc1jXe+nSj+cvhub3CkfwiB/KNxvFTDeNXMopLTTRJ
# DATA z3b7PtOmchmAapNG2R66KnnceSuPD5dzQXZSUhr2WCojnPYlDT1shOzLkq2sPtP0PBQy7aR/OO0PswKz9kKGOjcUshhD8SZE6vcT
# DATA z0RXwLuaucyxGSWetJrlcN6Sd5d/ZIHuVMjErOgsS1iqV0VA6TQZk7XVVxTcadhGhskBO7EeslQZQDblVydORZ9CZ2kHzgjHl3Z8
# DATA aceXvkS+9EZDykbzlQ0N36ux3c9iul+A5e5A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k7UDSDiTtQNIOJO1A0g4k
# DATA 7UDSDiTtQNIOJO1A0g4k7UDSDiR9bUDStUo1DIIzgqR71V65FzxHIGmz4rwRPdrOD7hYg6BfL1f2q9Xy2/T9F/P5GAWtJXirpuc3
# DATA a/2gVt9vAm/VzD/W8buNrj//2NCvBV6FHq2Wi37Dq1Tpg1dtFms1r0r/p98axaZXq3qAZ/nFapOvVXB74FVbXtXH3bhc9lperVms
# DATA +PZbeSdknm1V7QZhvbyMbbWkbgSIT2Pfr8wD2tr1tt/uLAultgDjsylp1TwyWMK1AF71rPpW8yTzKAwa7YUYVir188ew4lezGAbV
# DATA C45hq3UBMWzWsxg26hcbw2qjcv4YVrlJXFIp16iRnDuGtWrl8ko58Jvnj2FQDi6vlIOWfwExbDQvuJRPA9KTQUiD9GQ8s0B6rVrg
# DATA V1t5kN48No+vhPMgvV63FQUZSK8eBlGjaUB6nUa7S3N0A9JrkXVcbV46SI+3fxbXWfel6hyf7nProUUWXc4l5Dfzsx6dCWxjwWVL
# DATA eY9Nj9vFSjfa28mFPEfoeyuicT0OCxL3eed3lV3fsuTNcL759XsVMk/WNl1TK2nznf25VSvpCMbTG49ylrtxLOCIgfaFY2NY8ZRL
# DATA QLVlDmj2w1nhKS/YIp5P1aZ8aaAwLK9EA8sry7dDLbyihFiTzWrN8slE1Y3BLmGyioNOazV0Lyvhgl0ma2YRi7VNJdeqRsrZvb5w
# DATA eCqAWr9yGpUV1Onmow4C6CCADgLoIIAOAugggA4C6CCADgLoIIAOAugggC8ZBBB1QU0Ud9k6LYQ49FmAhO+kwDJs5duSH3w6bFdq
# DATA S9z9X3fxYxG15TYHIuIRu2p4U18pbj8vFyqFWqFOfWTcm+8h1W07O/pxc/dtfp2piNujQgz+20h3e7vqCavX27k9WptLAMjpESuL
# DATA n3qPjJJPd+881W+QnoyuKDv3qerO6D/Q6+w5xhhHx7Z3Psvl5G0+BKxtRc7QnblUjXbvUIL4+CWMUZ63o/nxOTgkoSQnPxXmj4Lm
# DATA XklB8HbYnMtPQz/cUuf90FFktXKXRl2WkJVTxlQfhYH3UA4dIwlj6mAZc2cSNmWLF8i9H6i374jlv7xsTkjJNNnbG+RSUoipnaMW
# DATA SZI40J/j+0emCBRQMdnlWqlt/7QDnUckd6ewl/vpLZpEUMVOaMiKKGNGnUMpNH4Nva38mt8s36pWy7f3Snt0L4zFn+GGu2zUb+PU
# DATA QkEFKNvQcXlH3x09HScjCLaFg4fhcPw4yT9b9hefvVEq1xEhSsiIimh7D4HpL3I3lPTiEa9s4k72QG3Lp2S8vSzEBhWTFOADyUwW
# DATA TATccRsfbvjMbEx6XpOLlBOvf/lR8zbXxV1rIoOSLlTLWIETACTcKAnXtc/VnISV8TWCUVeHz7K6f1tVjc91G+Ap8BTbjbgI797b
# DATA PYhHNLEq8alyrpdPp7/8pbp4ELWfxFP7J+kt7u1M+zROe/cnE67dciTdGqeRPs4iqQe//CXmg3fvUYTCgzCm2R9nH/rpIcbJJZX5
# DATA lK0oGVuNSPpHaSi3P+fZvp0nUkYS57x5sXh8XUSPRIEH0odyirsdeRFN03TbpH7HTGWXdHV8Pi4e0LQu1+mhyMxjMuTtWLGkQFUp
# DATA LAkSa/z0iAnKeo6z9jVp9RKM+NTMoVqnZeO0bJZp2eQPWjtRGydqs6mozUoB8ssSu7mPdRceXaE2MYps2RYtfPPsBNSuQmVcTAG6
# DATA /BgfvG0UR3pzGI9m0+gkHWv9rOmczAUjuaxUw+cloWVviNKErqyTsNbHfCnafFwXivGH6LI4vxMWzqDS4QW0vqw0cXFSAHJ/PmPM
# DATA epKVE+ZHNkt5yVryhqdAZb4znxHag5Nlhbk1Szo/6M+pW69/l7/5u/x8NuPByqneVdn8XZXcu/jB6qneVd38XdXcu/jB2qneVdv8
# DATA XbUFqfU7waneFWz+riD3Ln6wfqp31Td/Vz33Ln6wcap3NTZ/V2NB//1O07xL66uYNrxSXd2evr4AYup6qBCki1YiskYb6vueCFoJ
# DATA R2doKicdmIyQmD0Am8yT9CGklia5Lk9C8AteteAFPBw1QNGKRiyk6mEHAQctQOGhIYFZEaOBarn/1EP/yjADS/bLeNszVSkapjBv
# DATA 0IpgGAQRpliNp9cD20DK/PkXE3LQVjd1Wj91cjOlF3OmdFoQ6zOXBeXNXdk+r8tAeFrymxfM7bTFS5fCOlfiZFlDkE8empYqXBTI
# DATA jK/Byl4DcdTnRCxwQ3lzL9s5qI0r8Vrq+bKc2KHcock0VDShkmQMrbtKoTWcsMgVHKNkDOFpMqvIvmL+Ka+9iFjrWKbxvLULOoyY
# DATA p/OupgIeUAWVKTfyhJ4KKR7QO/axE1GoQHtgk7H8JL2cGTnQ5dNi6KfPRZh9rBk5px17lZLpz8ZSylVLZyw5Y2mZsZTrqpyb+aV3
# DATA M680sp69prqu+VSdQ5aVPoQHYET38WakTGN9PEHThAzwXCPbm9H8mF3Nk0hpYC/Ie1NzMQrgljJ4oqb4XIfmHMs5q2FRRN3cR+Oq
# DATA bsY8IlHpGn1lDJtJr+eF+0nc5dXPURKn7BKfaE1t6Q4y8HiWMK3oVvIe0RDt9Sg0EVFPeZ1UjhJj8B1IXFLev4hADo0WOPUss3ZK
# DATA jX42FcONZeTA/O5qIhxiXPLeUzrb3jDuTJJxnx0wCh8XhR12y+N5ygHoVqP7Wu6Jz9w9IdsaI6UGrzPlUTQVMyLNpJ8HCTayTEHz
# DATA lQ1445Chhla3pwF6Je8uMpOCjsdjBd5GEOySu+1hYRtXGb0dyl12mXs4I4G+eITc0eh3STenyjugt/HK+JrkvR/CrhFu8V5iVOdx
# DATA lc0tKgmYxVLAGjtPpS6VfJoMk8kkOVD63lL9eZVcFw1XfU8ycYR9ncmsAw0YxqCL7yo7xJulTRjuBppORYWBT1GW16XnTZbnZ88Y
# DATA FngWADkDsuh4ChLBWhQLVCnCJxikpjyE9clksA1LapOYNLCpl4ppSLf3cEIdTcGMg1IdgEMUTABe9CRi+DxqHmXjUAqJydNkWe6h
# DATA Kg9AoqfIzEYYmLGmlIzT+USKPXUSKeh1qee8coX4SI5KLszmPcKINg82uY20Vq9b1I5jDHMrvcrrnMj5hRJTCmsyL/Mr8yvP+Vpf
# DATA Xku/SLMyje9iX8PLJdJoMhaWMAu4EV3s23jB5CGXrKmsU3Q6VieMlnKxb+WlE+z7Xt0w8y+8ORuc0xf/4s5+MsQlva2bJJPU5lv+
# DATA y9H3x38LIOXxPzJ38ldMuPzi+LdH/wNEyaNvjr5eBFz+CxMsgaf8wjv6Fv8wzPLbo2+O/9Zj9OUXx39Pf74UwqUKmF7EWMvvKPCv
# DATA j/6s6ZUMxqTbvgXl8uvjf6Df/ugQltd/3vZIZlqTBEYSm8JYNEpme/0pM3JEZloNr4N4CnUNOUVsJmKzkbZdyJTCqBcyvFUGfLZg
# DATA Upm5AYMCszDkM6hr+ZWPeMcF9YXxwPuELEY2ohzJMpvD6V7gqjGWSwvm8oCWXC9Ta/6oq6kgj/I3o7KaWx+omovh7SJplmSsspCC
# DATA WsOUvSbUJMaOZLlBaV04yPKu2lo1oOZxWDwIB08yUhOZ1eDtAP+jkgVbtxPiuBGNshPIsym8TtjFCGGgUaMoIiMfC/BULw95bqAo
# DATA SDg/P14gWZ5Q81abJcua07MiWp6QCMezdGP8ecZ4DbM869D+Urhmr2xYv5xRfaNB/TRj+hUM6VIvl+SAGdCfYfu5DMLlkqR6NA+l
# DATA T8yeC9UyqSQXsSzwOmeIbI87GGeRYk7usijzxmf18CQRUKD0TW2sm3N8Q47bKIfa2wRumXN0I0oqGUb7k93d2OrnHdAcG2vAonyQ
# DATA ChXQ+2mamVAy8pPlhl3ePYpZDENA0ITxiNeWDO0S1k4sL1CeYRQaL2TdtdCQyrfajWiMHMZkNhz0I45F6LFpwhvsepGjXTrapaNd
# DATA XiLtcpMhZqMpzUY28VWb92ex7s9t3DvkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSlQ1465KVDXjrkpUNeOuSl
# DATA Q1465KVDXjrkpUNeOuSlQ15eG+RlpVYLg/pZkZfNqNXuPUfIyyUrz6eFX9YqXq1e9yjfPL9aHvjlwPMb5XdrjabXaA4qzYpXbc5x
# DATA Lene9iIOc+i3ql6FMjrwi036u+W16sVaUPT9YoXCD37xXs2nsJvBoF4t+uWG12x4fqVRDOiWWrFKr28VK0Gx2pgrkyBqtLuLfMAq
# DATA RbvxqR+Ui0HZqzR9rzytVZteeb/RfLtWzYdR7zS7jcpiGM2aF9TKnxYr5UaxSZGq1Io+5QXFKEBMi83GCWRNE7kFjp7flNd14glm
# DATA Sx0u/jpHwutw0fpScycCKszFtxs0a7XaGWh5XH81LU+agkXLa9eDqOpvQMurd6McLS9qdINWO6PlBb06bGtDy6u2a81KRstrNmq+
# DATA H106LY+rfXG9YcDe/TnfNBUVzl5+bgWgbYMcO00SvYhzU/m66P/DH2rht09aQ1hu7KyCv1mxPJnCZ0P25MHTQfZqi5C9LJhTQPa0
# DATA A3JlHtk5rTJUYexU/bM9RhW209gYMIPYim0EeuxWC1zl1ey7LF8LdlatMSdOyAlDtHPwOQefc/A5B59z8DkHn3PwOQefc/A5B59z
# DATA 8DkHn3uJ4HOcNpxGKGqbh9L42roBjRFEkkMsN7S0P/UMfQy9wWD3zvZgge+kUryjO7LXKJinH8m05ucePuzcGOQrGdf8ndInSTyi
# DATA AD6k/8CHum3Myw+39LHzLC6l6VPk64dbbyycSFcB3MBnTYq6Z3Yo6FA1+EmzlZxCuDtYveZgtTtQ/ZIcqD6tXvizPWjNfsnMlbaI
# DATA IxrktDD3kqSLs8Ue+wnNMVsmSSCQNTrbz/p89vNwRpH/vmCt9mUHyS9atX35ufyl+u0bHJPP/LRGPzwSgTqUtpadVJXDaMw8jigK
# DATA aTKMIATDR2ulqvEJeOV+YyKL6Abmz5dnJ8cLkEEmWzNr7DxnhJ4pPMBJrwfHtD7QLLqHCFyqGr9i/vD5aUTEF6qJHMgNM+vk2YjV
# DATA PIvTrOZ5Z1A5g2qJGl1WoZxgjROsOasdtdJeuxwhG+7TdTMgS0q0K1gDo59Mk71JOO5bouLPTDftAgCWNC6/oWRorNHrlJrFYgwg
# DATA kAsULFZjvx7Mh+GYM8ca85cp316IavEHLO8tfSPVRiikoOe7BOHiN2Gr84tGXvSU8tFLRxcuH8yixe+M0tkgnIp6+aFK3gESOqZO
# DATA vOdRfzcYXIZs8Yw1laaaOzNjDfC51nCx7w1EeRoS311PROj1OEfD38W+i+mPD6JJylJMWKlivr3IwjDbqBjGZMDPxtQgowtWo25k
# DATA neicBU3FGYIHKwwQMbgvWCJ6jjWZTcskyLxjkh7SWkHe8NCYH9LbGBxlBoC0FdXNclCmKI/JgV1/VBM6zNSnZECTE0fpCmmpDgCL
# DATA WlfK0qWCKhCLS3mPIPAdjTwGr4w6VFBafqqnqAeU9wWjkJWo3llLmmLh6VBrJfGMaDJrtyGSz+XCTGJUk2TA+GIZB0TjaDKDkJen
# DATA M83oeCn3ZiQvMIvdodJN3Qz1+OJMPyyDwk1A3ARkYQKStzDdFMRNQfJTkJUTi2etpal4Hcy06Idjhg2HmGHY4thppHT3tBTknFgk
# DATA o3a0OqRCH0UymbF0Hqe2ACTGysEB+EkzwYXMSzxKi51RU6a+i0phP1qi9Lip2iandnznTV7azOLdPsxmR8xdbs/iQddo8anIsKNx
# DATA 0W2sDo9aAHqN3pbVfgZW4ZOysJQFpH/M4NnmCqsI9JkVwz2bLM7K7hUauq2k5CHg6r1mCwGsUvX5VdkYoV5u3WF6VvupVxPuYTPD
# DATA D2vwGGOp2aj72LZMlCN3/naaoKrDDG/xp9V3dgbxsM0RxYfV91HHnGBTFt15Xz5m996UtN2Zw5RrW1NW421TEyPKGkMzV7rYDCzN
# DATA Xp2RzizncNI101Pe/CATVZWP+XyYA3PxTmrTHcjOApnYzvj2mvdkaJIxH2+TqVCOrN55GDOrqRsxTIhaa1W8BMMknQ4OFfwSP8FK
# DATA NFLsvFYjvK54NJUhMBI5TOySTPuJ0hMNBXquxWMZKD4yUrPUcnlarN3bSgrTg2WmrEN1UOtqM7B+igz8gObEA/bdx5MOTRezLMQc
# DATA lToGoLjsjk7NcuApoW7hE7VFh3qye7xKwLYx762E2T5M2niEer9I6jQVxZNUFs0UBYzL4iKyy2olp8yv1tr8Mk1OMuwnkPykdrEX
# DATA mayCN4HvyeeRQXBJRpa8D2jMLHiskheTEXao/E8KIkbduVDiZLeKuMM0Z56GDca4Rd2LyCrT8ZwyoxprM0r1YpJNb8OPI+Z8PLJq
# DATA Fb+aKsQBxTJlR0w4GajVU+2bgRMB2+BCaNXKShdPs/EzvH97h5m/MMISIPbkCzkXwDHu87gdQlKX0RV80zNtk8Ep2uS7ANGhT6N2
# DATA V6REFwVyZWqbfZmam1DrVEZaK29RmB5icU8T4egRsvlFepjzU2yRFBgva0b+LCuYX9m8hr2bUBHTGDmIDtlNkNWxAf2SWTjKuysO
# DATA P5rdUhNkT1xmrCFDqIdnh5VeRFWLomJtQR0YJ3ISVUfJWhEXFGiEk7izNN/yA7HsrbMHYnNFsuHO+4neBaeVp9kEU7vT4BRRJako
# DATA 0Tq/SycxxF4UB0TGEhtHU6B5bZTYfxeQmHf0h6OvPMZ6gf715+P/cvTV0Z+PvlnEiP0/R18ffVs8+hMAYMe/BoDs34ELO/4VXf+3
# DATA o+/o79/R398f/f7oe+/4SwkdQX8D6NhXR386/s3Rt8df0r+/xZvAIqM3UxhfUQhfaTDZn4++cjSx54ACPZKVH+zj6SiV+owCPY6S
# DATA MfMbGbDOQzu1PTEQuwmUz9nbiIHGckkrMVy+C310JqzOb6AeJBYJeXYer6WKvQVzidnto0OHE7N9KKojuGqaWL5ALhcjFo+sNdz7
# DATA upbqXxZZYqMpDgGaPhZfZaSLJhfJEwungijohykNp7BgydJNej2HE9u01C6cKXYvHHSw6hjJAthhBqgOh7zTnpdABrxO4vUwlfCY
# DATA C8dyf2aVAyTd4TDiyS/GEl5HjH8RMX3D68bRdAlG7MRKt9o6ybWlZ8cQOzEFjiPmRveLGN01T+zUg/pLsShyVQP6BY/nGy+GnGo0
# DATA v6LBXGqknQfZdqtn33QuAyVmp1Ucw2oHRz+h57D4kE8oUmBiqQsLi0Rrkv4OGOyDcSpUJU7aNEyfqL0qiEA8wskxHONTWbIZSgwA
# DATA Ixmq98HrUrCmbkZ2kmojw3pH2wSATyXYaAebAGtbMRkIS+yCGXQX4ukye0BZAww+gh2A1av0CQVm4hHDOc61ierXALu0sYdsNp3E
# DATA UmbJqBNNRqnjiDmOmOOIXTJHbKORZsMTGBsax1dm5J/N93gBJr6jiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJ
# DATA OZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZrY9aGJdYLKIulqU5pYr1eLms8RTcxedj4tRswPql611fi0WC0XfcqfRrXo
# DATA B/VBsQaslv+p71eLgefXKp5frniNSrHh4S7c4TeBActnXbfXajV6C4QxAL5q5ZZXoXfUGl6tVWzRhYrXrCPIwAuA8fJ8hN3C66qt
# DATA fLBBvdlt9paAuaplC8xVaQUGzOWX8/WhXWvUoiUBBDUrgKpF9mouVonaMjJYpXHa5618qVYbXpXyoRJ4zSL95fvDSs2nPPKQuWXO
# DATA 4tUJsUuR7qwFQT9oNOdIZ+aBBdJZ/QycMm4ZhlPGjczilFE9ajTCDThlYa+a45T1Kt1Gp25xylr1XiPjlHWbnVq7lnHKKs16td64
# DATA dE7ZOJqeSCnD+KLv2wDzZTnKquwmKzV5eQxD2s4iCcyErDFnuZluLfiRF9CfSsBOxxyaS3JUQlAR3sypplJlHGsVM92de3ulxr5A
# DATA duPN2TbieVqD8NLpKuTit2YIz92mXWAO2eWQXQ7Z5ZBdDtnlkF0O2eWQXQ7Z5ZBdDtnlkF0vGbJLWRwWh6sbHqa774XTfqk3SGhi
# DATA A7Pvwy0cxqLU/xgmzU11jc9H4aJ8pWkWDFVqNWx9frh1d0wTvKdwUUaDQ8qNGwj6BuVKbyZyYXw8rGfpXKmzVryKBFIWkFr6MFeo
# DATA DmdBgwxByrGbkA9p44CKOYMlen+OsuWOHZ/22LE7bvyiHjc+C17rGhxDZved9netp2yJgJWJ99Kjykv4Wtfl8PJzdYbvMoBb+ePW
# DATA F0zamqsMZ0VsWY7U7BC5yukMCwJ5RhGQV6ornF396p03eYLPunJah46rD4RCR0pvTg7CmupzENIT7eQAp52jvdkA8n1adm4IOdGk
# DATA BzX87mzCFTScDLX0vToTz+/WEbhLtnVMxi9vm9VR0JQwyp4eFknbrMU5hZ/I480pYplgqXXAaYOeHbcFnKhsR3hxl2yy2aRthCdf
# DATA kqOeVhjOrnJ21RqxNrtyOV0Xp+tyWoNqDW7rcvRe/nqUHKD7F8WBdrgnGmuQ3FADm3/1cmIXQNfiFQi1A0Rfy2nD80Sfrv50BL2F
# DATA SMmwGLeYt/1kb2eOBDTidaAMtKOCMN2U/p7DIVGiqUuGnswwZnnbcgl9NvUssiVHjCPs5cx+XCFnL34IAH1swZYxtrjSYL99Ynz1
# DATA 81m/qi9kEK5meVmc7Rhju44d5TURZk8JU5rgrs50bJBRJ8RVPWqiqr/ncGFr4+mvieUcQUmtL6G1KqeLqJFzVbcoSahUd16VvaYq
# DATA nmqN0dbyzS5J7xLvSwpo/FXM1psSxPkoUBazyWrftvCR0qdXiJcQzd7oA96H68luwNygWSslehqLigsPd+hxtAvq0xn1QtAqT2d7
# DATA exF7oAGM4JUJ1UEkE2AsAFViVWmMwhzoCICKgaZxCQONfeOq3UFAhUz5GfvjqWigBwOF4HDPMGKhQAXjNJWRvBv3WDplKvpDrOzs
# DATA qa28kYmPyNFDmoijsUSdKJMkYllleBoRGS8cU53DALcp2+kFMXZzI5gzd525u9LcXTBtnMXrLN7VJuw1UTi8x+p70CzuYZCJRyxj
# DATA tpzvpPmymRTgJBrGjOgorFLde1OYggvDDQub7c3iLnCG2cBIoVF77c4AIOThbd4EzkMTFgQOzX00rhumqfY98VD/U+YEYDybJDR0
# DATA hFM95rIdPqQGPoMJpeyAcG8SaXzl4pCp9A8ppC4N1SY5cFUtDJwsDQhxGfYcRawJ54VTVGiK8G2b2q7JkNFT3h6Fd8SAGlCur5gR
# DATA iMRbss/7mxSDU/Nzx5rhhY2cAgp5Gk06MfY75iCokuFcMCzaZwkVKi9ZyXsLnC3uRtmbxtCuPmwuvosBJiBWwl33bjTlfpaTAdMm
# DATA nM7523BwzUTW48MNYJ+sS+NdLUdp+nudyA8wa9PsHdX3Q2WyIJp7GkyER7D+SAU9SAtMx0gNtVMbXWImvY/A0FMewgRTGy15ZJnw
# DATA kNSGpR11404oJajwmcjKhZpuYc6ipzTmDQ7XpfJ9PlJszC/Gl+h03uWdnuqQyGxSgCeZFcaHuvh5+qhIOTHgJ8p8HUGJT4l/Wow0
# DATA TlJeqbLkPYqiJ0wJgVuWeR7IS75VVQutWJnjy7D/VLghUFuEg1g7isOUJ7Xh3ihJ43SBzMGG2Ek6348T6pg4P7MuiFvNqUnR7NPW
# DATA Y9CFcKItN7dqDHBvsxP7EsjQ76H66n0w1FxDVF3Rf9fTlEugRN/LOcvRZqm8hS57CaTod+Mpz8om1G1BCFKgkIpZwz2nCExeAiz6
# DATA wUDeiQ6SU5s1Lp5mdS8BFH2XOiDd4tFLdY2+LhcpvEWT7gWzk1/0+ZvFxaGnpqmNxflnQHCOvjv66vjXR98d/+PR197xF0DU0Nev
# DATA 6fI3x79dJOP8C6Nu/pWhNvm7j/7IlByPfvrV0e+Ovj7+BxXKfwUXh659f/y3eIJe9Vv65c/0wj96x3+XI+1YMB2HxnkOyMIMZjPa
# DATA tcLIgucXSI+CbEMVLnCPu60DQLkPlEW1F7Fi8BM4nAUnPNWsRIaM8iAKhuDeYD0B590o7PFbHP4mN8fk9n7V9BurMC4PfSNJy7pF
# DATA rjs9nofN34qRw9zIU71J/3DaH14k7oY32dK0p48a3+UZAZB7vBUTtzvszYklduG8G0xykzbmmFzPtMcaO0XUdJj7l0E4GaqlqWzy
# DATA Gafiil7YQy366WzbylyCSot6MUzryHSBg3sBf7O+/q02PrJ29KywN+tj7og3btA+xaCtwTanG6tfDl/w1YzTFzlMbzRKbz5IX/4Y
# DATA LdXPJNoMyFfXFi6DVGPSI4TkdD4hev9FtomB7Yl+MtQwGKtMZKZLAxoGu7DLCWUKuiFSpIqx3ElmE2FTZOOrTrgcZaeXIK84+M24
# DATA NWqKnxuDQ+Nc16O3GbdTurE7G0R6SyQvYcGr6KXjqBNHacHEP2MXK0frIBbXa0SdbdiLpoc5V6BKB+N0GRPNKOCOJCqfIAeocYAa
# DATA B6i5eEDNyQPHRnOOTezXq7G/z2J+n9f6djAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6Nx
# DATA MBoHo3EwGgejcTAaB6NxMBoHo7k+MJpqLap2zwqj8XvBcwWjMcvNpyXRVCtNr1or9xk/U6l5fq36djWo5LOj02uWg0X+SY0SUK01
# DATA fuZXqvP8k1rQqTWX8U+4lPLBVFstr1Kr/Ce/VfEqlTL9aXgt/1M/aHpNz29UPD/w6V1Vr9Kqflrx60W/SmUIYk6t6NfpliJ9o5tq
# DATA dJNPD9T+U6VFj1a8KoVQbX7qw4tc82p0T7WeS1ctarbq5UVAjESoSCZ80febQ79G+YIX1cvA88yltdPqtsLOsrQq9AyVYkzmh2LX
# DATA 1MpBxq6ptcpWBa7Jl8Mltbnbieqd3hnYMVyRDTuG24TFjqlVGmFQPZEd0+51e/UcO4bi0+y0LXZMtd7igIQdQ51EK4wsdkwQtKu1
# DATA S2fHDKgVnAiPgdPo8+xWQ3mxOC4qdYuOPXbuVejf5o9sc7vB5kMW5MlIGps3w5vtZG/xslgY11VpyfopWVgeliq9uvzJheYpi8YA
# DATA ZXgUNb1/jlwjRTyXYgoTlpEXyB/jGpVkN2Fc2f4c31rjUUE0KMN8+qP+1RYmW688IK6k1WxQlvmsy8+xl2bEyoAc1MZBbRzUxkFt
# DATA HNTGQW0c1MZBbRzUxkFtHNTGQW1eMqiNNgi1tM/WzmvrRjOG3+hen09dqMcK6AOXdq2eSplVqXbvxLr32mWTeOc22vmHW/cyNS8c
# DATA VrHkXEaUw0rTBdPXPLPGnHxw54bduWHr5Is7PexOD590enil1uSlnCp+HTUXSnNZ4OZk8TPVn7gAvXRozeHNB1H0hE84Sps9o9Zc
# DATA NrZcnNpcFA2UKndbVkkoQ7T6oHJ0X4LsnD5vrMBtYyrV7gTacx7NkaLB4SVozr0zwqHmqfSwqVLKhr3cywSqL0F87jG7vlQayQRR
# DATA vTnVCRo7ilC/7l6C7txDOUoMHyCZcirJBi5wKeXK2nPv46x1aATo0PJkhIPJQuYl9kLNJtEFq88pD4yRjs80GXPKANnhVp0Qc2qW
# DATA MgxdwDTXg1gS9ZkovEjAQ0J17rA+90alTF2zOznUGZ2hGsLBAbiFw4gl5HELFqrI0BgMSt67cc80hwJwD4PFtqhUVEeIysTr04+T
# DATA CAtWg0N5kruXgzCV6GiikFKr5TooKu9obPDminY1TSqwxL6vAqDWQdGU+tKHb3CiTsRDJ5Me7dGQskoyQOeKPu5P3eQIJ995mwGN
# DATA JywFQCP1vMTP3Ej1MMJxQHWKWyatcoeMOyfLxj/nJ48dctLZ75n97iz2F85iPy1S8hnqAPFivlmIXs+RfDNm+XMFR4Ho+cjjvbxr
# DATA IJJXLB907eU0LoMPmYkcXTQc0paDOisZ0tqkoKdND3GsylQHmfixcIoSnqrMFSR2NUgpqt2NIDa+PpGHQQPAFjoNbbzrDWbDeJTM
# DATA aIpobKIRVfIEIjbjaDCAtDvG0L5SXCf7a1TyftIWuX0yTLDpGlpKfTJJFeaAeTb67XY03oKBxndxYnQs3oddREFQ7KjyUq2xzC42
# DATA +fj8SMTbEA5TaKmHKUuoSwvRGs9DSFhP1r2f3dBe7t1vSQtKybxMeSm65L2XpFNt/4m4ELN/dKxvI4OkfYG9BOUb6q9hG0DYnroR
# DATA quosGzIfkxddJMbqGZyt5mw1e2RwztaX19m6mjn5LCUc3+PFSl2flQAbH722oJSQ1mM4wj6026T9ZM6bArsRGDDJTjTtOCx5DzIx
# DATA QJzCEZU2g/bhMmSnQWjpB7JPk30HvbjjpTTd7xjPSpu3kmWagaK5uKEGJKdYHB9Z45e1PsRkFE4mmifEh0vwHnh9lhiJ6ozjIu1S
# DATA rXOjkvIn5SdTniz9YwZENFc4x4EdiTgceVq5n5LBwErBUgKkWTznaiKfX5UtAerl1h2mo7SfejXhDjNz32H1GSPmYKCXRmP4QxNl
# DATA zc3fTnYDt6rkYPU9e2z2MDKLP62+s812GmtkT8RK0XfelFRl+SDjsfYWygq07efD0LDGVbjWZrQ8n+Gka5zwvOAv7niVg1YOzIGk
# DATA eGewaf2ylM5VaDLjnLhrEjAfY8nLMRts9yDiGE8gZIp6n5mtsNeKSpOzIBKjRczMtAYpDWPDpBuxH38KexaGn7bgBKVkOxPhgDRS
# DATA nRELDWkje+r9ggbcku1f3dCX6pltcmxp5JNiskZLmAHwiuVubkT0jOV0nbdlT1U8WeU7ZQk9Wl1CuhpLIT0asw82X0LUjLkjEY87
# DATA sC/QyuyT/SNu0NCTuq6sfosdaNZA8LysgojUagL1UUw5ULrYwaislPOXjZ2C618wDzYtmAfhZMCisuFgqAvmUdJjGOuIRjXWTD3A
# DATA JI9G0L383Kzk3d1PYsyMKe+NW79gu765VMbUv2By1lWzREwPz10edsSvrDyyvveU5fFXq8tD9+JSHn9FBstCRzbrdGYDVpPFIqA6
# DATA Sagah56sKpYe9VK8koDz2DRklLy3qXUdFqgIyQxJ4oGoHA+5F0uGQ5F/JuNiKCwx+ilGDpr14vMXVJai619MDzctpoezdnu+P3ud
# DATA RaxVbxaNPkkOsx5Mi3GVvA9imu52Z9TR78lSlJFP1qtCmYUHpjblVSecCR3v3GVhR/v6d2JvbtqJvR5PurxjYAQHEDWOkdV4+qJ4
# DATA 3Z8N424RC4UsMa7Kg0edlA17SAtNYZl/EGoudbbOb/P2UMKmt6OQyHhS2yaghQz30LnLaTFBZyqtvP0n2xht+89ckby/836iNxxq
# DATA DW4x+cXi5qV/hlqGNGNBduhSVgunl8NEe649XhkLLe0nUQ6F9n8d/evxl0e/O/4NWGXAmNHnXx19ffRvR9/R379jPNofPYadfXP0
# DATA p+PfLILR/pkxal8d/Yme/b1Hf3GAR98UKMSjP9A3Rp/R/74/+tq8xCap0U1/PvoanxRH7d9ARcP75b3fH/378T86KtpzAOU22xx4
# DATA y2syPdDYVUPmhnixkFcLPDPibVYRTDzNAgA0FO4ElpGhDkDgDOhAx6AbKKIr1ePJlPeM4bmeLGEZpwA8HWvJaVCWR1MQO9/h02xf
# DATA H3cRV01Pmy+Qy0Oo0WgRDpK9DPHFOwz55fMc7pu9OOum34ynFr7j4hhqMKXVuQ3U0ERGcM4Gh087ubQunJ/2nmDAvTYZF9jRRfP+
# DATA Po07ZnpZ0EZWmuAwFDIShiySie5O7WnF/EaRxp9CJSXKOifW+SqQTSXLkZOIPYtMmNXHBIZURILXwGA1XWCrra+Xq42YuVb2rABr
# DATA 66PvAGtu/L/g8V9D2M4w7L8Uy3tXM+Rf+Ii/0YB/ivH+8od7qYj5pJtR/no1n8vgtuUTzoMkZ4iBjplUtw8RUkHOME5m8iqJ61SA
# DATA TukwxMKXWXrzpF9qRylcWtEES5OcaBqos2MLKnrduGfYbpTsQ0+RTDZktk2UucbbanBkhQwK9ktEnScYmxSajOuYcK/41DDvBBLa
# DATA XJzyHqp0KjQuXpqN0qmYCsiXzHK4rShmoGdNZxTCMBzNevg8sY0E5XmFn4BtmslhMRk5ZJtDtjlk2yUi2zYYXTaa6GxiEl+hXX8W
# DATA s/68Vr0DtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXDb
# DATA tQG3+UG1Uy2fFdwW9OpR7zkCt+XXnE9LbyNb1avWmp/Wg2K17jWrRb9aGdA/lYrXDDy/TL9UPb9Cn+rFSnVQb3lB3WuVvUrj02qN
# DATA rnrVwKtV3vb91qfFZrHa8Cp+MZjL0qjVq3Tbc9Azv1GrV2vLoGetxZKrlL1aOegHjcp+tf42fc2/wISVp7BVKAWVeuA1/KLfHBZr
# DATA Da/W9Brlot+gLzWvVvfqTfqyccT86kLMAh+QuManxSoVahF5UX+PAkBsB1W6kKPF8U7O/MuiXqO+AnOnKnAnnvAJu6dS6SsZ+s1v
# DATA MEiOVQ3q+RZggqUAYNh48nQZWevJw81mvtr3evxd978sh8rir9Um1RsK45TYOG5GGhsnLdLCxkVBsxYEeWwc3VSr1HPYuDmQnGDj
# DATA Wt1Who2rdepB0Miwcd1Op93LsHGtbrVVji4dG4f2dzI2rqqNAjEJ9DMr+HFI5px/MfiRV6M/VfpTD35kBzHHi3tnSFOJaQFbgRFf
# DATA 731W7KCvdsztaVJQLt+ed+aJu6fQ3D8o8CrZihUxFQ3Aq8afbbpUUKpZeeFVJ/lgPL2fImeQmPkSdlVrF5/2cuaZdiqTKvTHD7TJ
# DATA z76ieEoWVicHstM+bOqXKwv4ufJqvpzJ/YKdA2tMkRMSyFaC48g5jpzjyDmOnOPIOY6c48g5jpzjyDmOnOPIOY7cS8aRUxZHvgOI
# DATA RxT+Luy9D7ekzVHCb8h3KMJwNrCJ+eHW43ACFVp+xJOb0bxu8AWqFm9iM922v3ODcqMzLH1I/43uWqfE7/80fwyPH34vnPZLPEPf
# DATA 5nB+7JcChJAd71tyaDxTvoUUl+n2NWouO7biDlG7Q9SbHKK2jza5s9TuLPUaveRne8ZajgYX9FnfJSetH5pzgVJHCnllNXOoVw6s
# DATA KkEWPksMO/pA6TDLSd6IVfazw5Pj8BCTaTk8Ca2VkXVycmMN5DdF9bgtjKguCFR4dWg6dHQETvd4E93jTpjOQiWbhk+r70SXSlmL
# DATA Wz+Qj6vvpQ62mySc0T+Rj8+DAnKWF6cUQby3WgRR56qIIJJRNjnsQocoHO2HaaaAiJOT1LygIN5J2G0yG49x7hkbDXAYzZuILGQK
# DATA PIccZmcvGDW1qORRq45xdHhOR4fHw+7ksOBFYXrIDeX8uodzabgyiUqr/l2cYqipyUqnGrbDZAYzMiubziztU82NWCQXZ9DlCHUo
# DATA ctVs5mRGBKxK2CWCYUBB9cG9QxeRKVMrPQc+Hj5D/YC/tK2ZJ+dSp84S8BwUzAcbF8xDqupFuFUOoQFuKYfyweYClcg44tbDzUY3
# DATA EAbJoOCoP0LD0bqhOEcIxSoohkdjtg2R4ZaahggOYG1Lxrd40E9mLD16fn3XXFKurJTO3Lm9u2nn9l6MnTPQ8JhNLGVkmqDQnA+7
# DATA AqfJWDedXjwZQpx0NvZUwSQTlmDjX0W95IASNUna0t1NInxl3bDZqE9GFdQNbBmP8xRJLuZXViLWIHnKInm8ukjMcCtl8ngSxgPR
# DATA SwnJrDGFQt+nME5gvyWSw12a9sDIQ9U0NMxJqJqD0qwGTFgrzWRKEpnYm4iwDA5F7e3cBZOP/vVvK482bSsfyJyUJqjxmKqwKRjU
# DATA bljONHWXLUIwrHkY5+koVD3GKY/3mOaDR4uNuQqZlYpmuBIJn7KoNUoXntNzF8VcjF9ereMXQU5EP+68W867tYl3y65izrvlvFsb
# DATA e7FWOsEux7vFwlsGgBd6e0kionjat3Vt9WvX+b5wpMGzPWALTi2hm2LDiNqHrK/lvE1qeYbRTCPsv+eJqloo3e4Md5TbSzdMmZSi
# DATA FCVU87zpyrIrxvVT4d21E/Tc6MWGMRtIFd5WPQx5y6veyBuNeet1yV/tIOMVJNTyRJXr2KiW5f1k6kYTM/3ggmvKV4Re2D3dW57v
# DATA dYar/Vh+KWAHAgUWRxO6uxTk7l/wZSkLyzgKZdMNBXFfyxfO9bKWmYTyoyjw4SKdKtl9ZZsu2SVp4rGYZ2MaD6eyIf2mBHFOA0iM
# DATA FAxGVnuz1SwfT8T9KsRY9AMLKtED1mscaS9tQWYMbMOxVyTcC2PZdYUt8YKRotlDyTOQu6yeljwutAIPfhaQhcUrsyChV5lq6xiv
# DATA gzU1jkeCsUKYZBEbCUIsKLKCGg6NQdKxfSjNU4T5QihQ2quI6WwP/FreKZCtYapp60hLULJeZSY7OWML9dAz2wX0nrgx2zAaL4us
# DATA fuENz2yocaanMz03MT2drfni2porrcNrqFbNJzrM6YJFM2xgmaFvwezkWIFCPolkmTDVVmj2EMsuced7/dStr7/kK/8t53TuvEo9
# DATA 6HzD0scCEa45wtWUE37WmUW5EA7427wI9/xxPWmmnQSTBXnX4agj5rfRv7rzk4XTfryDjwpxQdzceoq/cFo2EBbPjq1oe2wODn4Q
# DATA HvL0BXrOxjC7x0t2MjkamUVB+BP3KKTxoSwvytwJNMJxuM9zl5L3kJezptqCUvco+wy1Ei5jccaxwTO/1hViPZysNE3r2KgSzFem
# DATA +0/HA4Saxk+xdV2WIaV6Xznc48qNpwxTRhVqPxrszai7sGFl/3L85fGvGUsGgtg3/PlPQJcxNuz3IIrhl+MvFyll/7v58VdH3x59
# DATA AxTZv/OF3x9/efQnXCp4R384+opRZL/Gd9zArzv+e/oDENnv6HUAmX1DP3/FKLNvKYDv8NvxFxTMt4CVHX/hURhf0YW/x0Wg0Ry7
# DATA 7LmwDpE2nnrBH8Jy5br23gKRNJw8wSpfOIoKcHvQrHTCc8dxKNMfDDI0Q8VRaV5Dgl6GNxtxYKxNPosHzEalFh3ybk6aWIZTgaRG
# DATA 2KpPndlaapnApCMZKB20zLYVrQ7jqtFlc6VyeeSybiznMFNz5xvqClfUBXoZxj1zJ1U6qYmTC4aX8Tw/TnkDApoD7wzTUXUEs81K
# DATA 7cIpZrqz6cX8XDgQp1La6UfdmWwTGQg7HpIfDHLmXsxjtVfPD4rDeARbOxxQ5cY+ktva08voDLHCJhEFLCCFeIQuWMxAZRlJmxwY
# DATA fPOmVXO1iZNvas8KX7Y28o5e5iyAC7MANLfs9AP/S+EguspB/6LH/I2G/FOO+Jc+4Et9zCXeppddi+ZzGdyyXIq9SOboqXikmMLt
# DATA Jb38vj3OhmmfYrnH6yZodDH2aRrLiBFHw3DMCZfXoo+ScwNUO0FdwlKLRibJfk0ecaXee0acLd0QW8Y5pyqFR9kxw+tkwAcQRNxl
# DATA B9owoCJIEUuviwM/ePmTUXIgpyO6anMpsFHjiIu6n8wmYH8xgypuxwNkFaw7Bq3QeMS4KRgLooHAeC5zhkCBnEbJcviU45g5jpnj
# DATA mF0ix2zDkWajKc8G9vHVmfhnsfDPaeA7kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQmQOZOZCZA5k5kJkDmTmQ
# DATA mQOZOZCZA5k5kJkDmTmQmQOZXRuQWaVZCxqVs4LMer2wV36OQGa5FefTcszqlCflWr9eb+5XW7W36/MIskpU7/QWc7LsU1bW+kGz
# DATA wZ+rgIypzzXKWP7cbHo+5XC1Vh76zXKR/lWfff15DupFOd/tVZZBvSrNhShUAopCufKp3yh7vg8Em1fxy1MfbuPmSfiwRhA2Okvf
# DATA FNQXcGh+IwCXzKtWiq2a59drgKD5AWWcX2XyW611wus61Xp7Oa3MgqgVMR0IIdAvNdprLQGZUVwykBlFyoDMBMeWtYBatdeobJy/
# DATA 9SWvqpQb2auqvn+Jr6oKkU1eVak3LvFVQcVOVbN8ia+qM4pOp6p6wRl4Kqgcd2kaKie9owWVq1Xq1WY3D5WbR8gthcpFftToBhlU
# DATA LujWo2bVQOU69U7UsaByVXpvs37pUDnZXViUZQY9zFV5BuHp1SljuzTF/LOfmYfCvRVRZx6HhUX6W20Z/Q3+z8b+QaEu/k8V8jDc
# DATA DPJWaqxza+rpWRbo/AKJbd7r8lnwbKqSyYXD4hYrXF9/2W5SB9bNO71OZ4d57K7FUtVqMJyVVWvsuYU456dFl2gdOsacY8w5xpxj
# DATA zDnGnGPMOcacY8w5xpxjzDnGnGPMvWSMOdSFeEoz/EkILXaqYLcNdm73zmdmTjJOd7meSC/F55dx9SOr5UvD371jmn3c2/4BP6oa
# DATA 7s5nikunlYsghipnvhhxNOauWozL25/Lq7szWXvetQP6seDucClD4DGXTpZ07HuL/s6P/eCGHyA6OrQ7EkB7RvNFFKqJGcvNsgLt
# DATA KIq6KXh3+hlA8kSGIDXaS73oQDqQsZzKE7EvusQnGHPJQUbjFOOuNusneLFklSw+bfOEbqckiw/b22FhvxBTIYQ3lKG9v/Pj7Zia
# DATA Rvm1evmWv1MoY9MXt3qsP+0Od+9sD+/s+rVa+bUPt96nKslHLDlUZJAyfDifeoOE5qzDm/Xyzo8qtR2agXVZz2q7Uvhwq4y7+TH9
# DATA zPBHdOPiTbezmiNZjhqwnXKsVdWB82iX47eN1DNq8D+++CdkbHobV27sLivM7fjVfCG+5ge3yjo3OdTbn++UPkniET3L4EKJtPp4
# DATA Y8kre/EoTvtKFNUPdGHitKw4XASA+NMRVCYEB4DnGXq4PVdhirpW7NjVghoP1yOTLTsUydtc4FQSRT2roOdfW2cycstD48nC+Qzj
# DATA IBlD6tCxVs7Q4hY6ZM1W1JXOzLsocH0eujR9in7GiqOE/UiHqR+iARdhGUyjPojmlCKcUsR6pQjrmKLTi3B6EafWi1ipU3opOhIP
# DATA ZtOsAfCuLa3pKSO7EZW4jjJGV6FjL8aKyLhPxIqZU67HpUy3Xt9vOi9zwQi9l1u31IK5Eq5foUevBlxWpJ/iZDnzkIyw97YaeU9S
# DATA 0jfBmChlVzIl/Vp5mZR+1ZbSb1TKtpa+H6yW0rcMGkSfI04TE5pVcbXKy+nnbrbyzQ5iQS2fY3anWtb2x2pd/RrHsxacfGedw6wv
# DATA CXNBe18fYKR080HEO8ooFmYQWg7dKr+onMmYUJg0cJry5aYdH/OZkCun97LxjIdCmYDcsS7PFcjFvPYhxk1u8fZbs6uX81I5+OjR
# DATA QDuhbiL35vxPGd4zK5eVdATpyRQm4PlFIrwL/55I3ShjRVvytnKG0Zjp0oTOsvtznTybQRD+yN2iBHipCrP2DCRnWE+D4QYs5qAZ
# DATA BKs0aPKiMzYVbJH/tZwTJhmYmz9gJNQrFOzb0kOQDQE7kW/w/Itb5C0MNy9x85IT5iU5+9NNTdzU5OQZxzOVuMMYjwquI4HMGWQq
# DATA d2+aiYgAD1jzybQ1Kr0wZZErCE6x5pgRoSqIctowFMelEULTYg3zk4s59AK22djYb+HR2gaY8DU/EOG5SAizcJWifVNiqEKnZkrD
# DATA jC7KnvTTGaK5x7/N0kMac0fM9KIESmdRUBAimR7pgZaB9NxdpE90oON+Mk32JuGYh+pxBENayfvGE5YekyTmh71pyFjl95KJKOuq
# DATA sW4ebiqIZMvyk9SKOWLh0LgjQ992oDDI2CaoOjbx3WN16gAocujD3RV+mmAl+qGNF4WHHIQBllqDb29d7OMuW3VrIz9vPEoKDFJA
# DATA IMKpIQhDxX9qQM8dFoRT+AutSZwp6wnLNq+9p4qljS5b+ARWrx1K/V2TprvYYT9KQG6dT5aYCXlu7IKqoqnIZBY+gHtfvRn5SmZb
# DATA HwRfhWyQLOAfAOxF5LGW3GHZNhg1BVSikSQFzDt4b5NZqvJDBRxTPtzdT+IuS1KzShsACpKlNEAlTIwdQmptzCfdeHfK8ik9x/qv
# DATA hSaiHOAyKdNxxoJ6Trg66cksDDp0w2HSlcaNwuPLpqw8fXgu6fXgU9dlpzWspQwL3njWJgvFeo7157gRhl1YQN6E67BUVhq7GF7M
# DATA r/RAYqdBhyztlNrkuiQ+Ahpcwb2mGESsJIJQJi+kniGGthd1d5TWMT3fmw0Gh4q3omLKbpyUK6qke5gjFbKyoPQJB/1EqSNSB4md
# DATA oFTEkz7aoRQY+vh5RK0Ypi+ePe1oYc6W3lgN2pnOL7TpfFpW2DNWh7b3/K+HhT3GSKBhl2xUSX1fTwu7PmrSz4Wk6kkEiWzfv2Z5
# DATA XSRULK+QfdFMsXnF8aVIMeV+YzVvFCrvQiMjSGpEKmZNMrDdodFYd2J33mftEuGK0VSF9Yll0kTvo99xz5txZjmj94Bk9gh2udDI
# DATA qN5k98rMBDat7E5PYOHFkCI7VDfdTAarmqfYy7BzUX15ahEuczCuxYTAFWtIzgv647DAWIZ4PEGNTiPTzETBOTTTVdlmQ4b9EHeR
# DATA nZvztpLNDdFiWwudLW2eQkpOzViUXBu4C+tsC7bei2blZVizg6itxK9tqtn/dvT10b8Wj//26HumjH1z9N3R75kuRp+O/+b4i6Ov
# DATA bMLY8Ze4sgg4+79x+eh39PDXjCj72qMvX9HFb+jydyCTHf3O43v+wIyzf5D7jn+rQGZfgaRGL/iS/v2tAplxfL5CnI7/Dgw05p39
# DATA /uh7+oHu/6Njmz0vtqw0cjQ8Lb7OS1aGvIl1IJrDibo4T94SCm6KVo84Uiv/KVQWmSEv3qNkn7084STzKlkkRDSPtSizt+ej4XBm
# DATA tk2bdRRXTTNbUjCXRzQTn0q68HJ1ff522UFg7n4YpTQCdWTA5kK6YLSZuJdEzx+uFVn4Y2qBA5ttVHgXzjW761l659nMwNQAXjSG
# DATA kM5swBSO9iH+xmkK5Z4D9UQiKHbOvQc/pftF07ygORV6v4uBmLD9sw94sUcXBws8sw1r5mobZ7HZPSu62YZJcZwzZw2c1RrQWLOz
# DATA GQEvhVPrCg2Ayxj/Nxr+Tzf6X+HgL/VzIScs1NkzaUGXQTZbSCTTzSir0sVogXEmy8oeVU/U1FsCeip4bz9+/OBRQR0sVSvDXDK8
# DATA Z3RC9gOv7HAyMELDKZHRlCaqLLXnQeepHnM3xZuZquBRXkMZLG8AIGVxB5izzAjIA87Gk6gL30jeKLCNgQI3U3QWHgyMUUeZB2wV
# DATA gEMl5qEgpzj+Kb0mo5uxUyU9TPkopbqn7fhmjm/m+GaXyjfbbKzZaOJzKgP5ai3+sxj8F2bvO+yZw5457JnDnjnsmcOeOeyZw545
# DATA 7JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnjnsmcOeOeyZw5457JnDnl0f7Fmr1qrXz4o9q/YavfZzhD1bWH/eCH3G
# DATA masyjylhQtuqVXKHxfx6JZ/rVWE5SbY3cxnXbUZB1JvDN1WbQSCornl8U02y2IqHvFviIeyrLB7V+UNrlSwatXls3TJeWN3ihfmt
# DATA pmFQ5Qhpf1nrNv1GdbHmNGtUdZp9qXNW8sJ6u9UJl/LT1iWvIqS0S0pexaJ5bZw8eujCklcVxtclJa+qnj5V8uihcyWvWqlci0ZS
# DATA rTYvr5FU6/45Gkm1WT53I7GTd+GNJJe8UzcSJO+8jcRO3oU3klzyTt1IkLzzNpLAb16LRhJUa5fXSCgW52gkQaN+7kZiJ+/CG0ku
# DATA eaduJEjeeRuJnbwLbyS55J26kSB5Z2skNrC13PRqQbBfq/errdp+sVYfFv1W3avV96snAVRXN4Kz0DDZ0jU0TDaaLRpmtV2vNIOz
# DATA 0DDLUdjzLRpmtR41a4aG2e50ut2ORcP0A/n5cmmYajOvzO4sZ49adjN8TJ6wk4luO9VavMa+ZNtELlTMXxfvmd+qsLhk1uQls1IT
# DATA W2Vk0SwXqlowXxtynVfP8o/pWeDyzYbZ3TSb3JuEw9wa3UnJVc8sWZ5fvEGv1C/k+eLdmRdx1Q5JeZEvRSSugIVAsNSwiPpU1S6/
# DATA XNBqteCBOR28kz1GS1LFbsMF3/PidqGV3E9H63S0TkfrdLROR+t0tE5H63S0TkfrdLROR+t0tE5H67wAWucimnMvbiuAIlbnYHoq
# DATA OKZmUNGVm3651gwa9du5OYt6jA8P4zGNOCTDfDbGlRs+nqzUbis25n11jB36AaNpf3BoOFeMSKSYUL16E/v7tyuMRXwrfl2Qiu/i
# DATA nLmcUh4PZqkHwWZPvYifVVFa9fxdrxL8yLwtE9qReSnlwX7EqM5tisOPsca/sywkm2VonTN1gjBOECYnCLN46Nipwzh1mLOrw6xU
# DATA Ur5M1RjdWUMOQtoLiouVHLDRhnfeWBIy10fH7CqAhjJUMuhDBjJW4eCrJ4AE9ZO5bj7NIdvgRlgKEvQtjiDfVNZ3GpzgapqgGc7B
# DATA ElSfETYLlowxKOokeNt/Hb9+EhDRCs4kxb5mUhOcnJbKKZIh1gZ6AHhFxSTYfu/k+OrnTGTNBSumm2X6hjHVdhC3UwglQnIks1uo
# DATA 6xrH0UnVJQskA09ml0zUGyfFvL4m1ishf6YL0FMmHg9VIT/30L9lpD9jIUam90PPRHVMWB7cPLpGXge2ARdpOOQ5AC/PsCCMmmt2
# DATA aFLFatEMNcHeSJreFLyDPlU+Mg4ne5EVmsrdXo/62vZsAt8GnqPJ1SSCQlM81QI/yl8tM4+UZblZiYmq1KEYyKyDadezkncvGbJb
# DATA jLq+ghLrGXWN/lMmuqQmc115IpwoXaTMlskgs0OK12zCvlUlPrQBNfBFU4pxzBM3EVgxEXA2/0th85+WdHJdlCLtnRLrkSdvxTxi
# DATA iloir0dDJG7Eqj3UtobRWvbJs5OXfL7U1U5Sl57b43EZ4JNFAc2Lhp8s0yFdCkDJlZ3eEiMVeRng703Y89pEWHoHq3quveN1Ma2N
# DATA oXFKuW9F/mNcZcyCgwCJiMZnOJUyV+bmJjjMR9m0W+MV33783rsF796jRwU1Dkt74WFBabkDYinzIhFaHEMlNNRKqqzUSKVgZD/j
# DATA NJs3aLAdN/B4imF7DVHxkXQGsuFtPSzyrhUJVYl1iu5CCXSk5FE5dpwgSlg3As0vGnWgCDqKKH5Kj7VAtZeqa18vs4k8a16VdS2a
# DATA M9+BnBB1LTgr1rSOtoIpssGtDhhG4s8QGCnMftG+ZwN6cqgkMVUsS94DzalBzHl1THdkodcL48Fsso5m+VCCwcLVKp7lS2SB2/21
# DATA s8GdDb7UBleVxHninSc+Z92tNN6vj34712mM1BnOOfTEU2g88OKriVNs3Et4kMyLj2sX+jz9bDYGTrDk/Qx7xA8NooXu6M46EJEZ
# DATA Yiw20sbG385EY7Z3NhZyz3QLpHni651XteH3CMe8uWFDvyJVAGyZcai+4NWbxkqcSu89neCjCHPjVR1x1pO9MUloDKaG3V96w09l
# DATA TO+B2rzilg9gsiGVosXNYtO49SbeeVO/Xwaj+WgoQ1UZcMbi4Td177yhNidyDS54GFZ61PcnVGaM/aSqNu3ynWqMKHgyGBe01DY4
# DATA d8AUp30Jt6uitSIe74UjqlNd2xY0kbmbSeDP/S5RsE03Y39RiU4iiHfz4oG2vE6OyM/iyXQGRXWWErfioAqYzTyurSwpz33KJBmY
# DATA yPxkzIoq5gaq5NGUVdLHPHhSBg0GuqqnVnxuqoK6qSrdCi79euz3I23nZXkvJl/YHdKgr2c5GdtHK4krUnvaT2aDLrdLMWdHsPyw
# DATA 8RxTK1FXlwIueWxfkgU8SA6HHATZ5+BZhxCHt2TowaL/JGnzwKkk5mcjZiGqkNYBwUfJgdIr16ZzOO3r6H8wYTl7qvcei5uIs5vX
# DATA W7TfmJ3OZI1TMKH2NqOXos6O78EPzEjNbFwgoQBZ1LfzxAik+hEc7DScRyN9b1exHrO1wXWJeU9c0So9oYjnw69u3PvKs46I6fWM
# DATA jKvQjwZj1Z/JgqfVF7EMPg2USQ6qMI7CJyhh6TFR97Bm2Y2GeIE9w1JgBQpF5oOMhUcrsKdmyo6xwedm/RP1Mx5uyBB/sWz7zz//
# DATA 6PMPR1uv/MWL/h9lfTT4GB1GPJoBqjo+vPB3YO2yXqv9hVo3nvvXLwdB5S/K2X9/Ufb9Rrn+F175KjJghjZHr/+Ll/O/H/7whw9n
# DATA QojoUAcSd3mcQaXYSnkvcpGxH1kF8e69+w71GrzMSe07GXR5CZ8eKFFYr4hUCtm2e3zYRn//hOxD/TlJX+HRC53+IG576vID+qpv
# DATA mZgH01lb+Wf0FRzJwnCgv8/IdHnllQ8e3n3w4P5DbKDe2tp6hc/YvKI2WPZkXzU7m7ZpMtmNbvXSrR3ezYiTIVtg8N2kXvEmqL43
# DATA O4OYZjBbt1+Rrda9tIR8gJvv0eGos42HCt4WzdebW9YO1C12ChURejHLra2dHe1fKkVP4+m2v3P7lfl9n/mo8Tmyj9VD9AbqHQ9G
# DATA /OYsoKiD3Cp4P1eRWf7ujwqveJ732VROkdzyebtDYRg+fX3Ww95Hv15t1gpPyMp8FO+NwsGtrUfvvPXX77z77lYhnXbj5NbPt+g6
# DATA DQ9bha1xPMY/6vtHn++o7FEbU6PJhIaeX/5Sb1RNOUD7Ai+Wy8bX1Vkie4h3c6e19PNdjAXTRB2rUPmvo8EPvsYFdcgvwcEovP4H
# DATA cnioFKePwl70DtlFezikgNtLyK97WMnewZ1z17xXvfKyy3f4tM3SNOgrKq4HMGS2VXzn30j3Z6e25oPyPn8FlfiVV2gKDTflx0w3
# DATA 2o5H6ZhG4Y+l0Hnyv3MLRYws4BV0XIINwB9KbE2kmEJtbxW3dvDDIBpty4OUkMCv4BqenEQl7CfgbcTbk62f3y3+L2HxF+Vi6+PS
# DATA zVv/U/GjG1v5F+K/SYip3M+QsPso/u2td0b7OO1j9ST8zNYOP6MG4l1u6bnE7OhEyC1cWbap5k8/xkldimnN+7GHDb3qn/Vx4HC9
# DATA 6GmHbN1UJpIqBrA3J130BuiPSrz7YVu9E1XnY+yv3t7ZyeVpSjGdhqMOqiI/XvBwesBkp7q6Q9XO8zfKHTXVVRjTaKJip6/v6nj+
# DATA vPyR/KBvxJ5vuYkPJW6906Vi2VKPR6P9eJKMhmpvuH0fTed68R7d+9nnO3Ll/mhfjgTZSZ2vBGGxRzXgo8/qtc/pZhOLHV1prKyx
# DATA Xj6XPdYvO6rxnCeTcBpaDrjwV0zWpdOIR3YOZK9YLEa+v4CjtxzJLbLz8LQEwxcm8xeelstzl3a31J4VuZa9b3myfjpKZ2MMVzS7
# DATA sKKpEoX/+LTnx5Qy6Sl4x+A2vabg+TvziVneWj/+yGq2H/2YnsSp1ZNipjPcrj70nBUzzvISDY/RqKsOoJr2Ohtuo5BxS4kmG9S9
# DATA 8Tk/lD3WISh7+GmUfCWob9B871vRWNaE/xJrS3BseEPF8Xoj6TzB6Rr8Q5WPHpwc8vSpIPPlDtdHnGRAwaFTFpgemf4lFSR2YFHf
# DATA q2h5sGUwp2V6n1okui30M7ik9MwfPmiWDMV0Me2H2H8lzdX0frsU2VHEF8WRpUyX0uMItks4OXyDhQWTySEL28VPd7foxaOwM8OB
# DATA cjOSo/OmqWpX35xlIJXax8qK4V7V3LLj3fS27JpmHtE+8wTdSZKWQAjb1uEUcOUnH3/w8Cfvv/ufvV/Kt3sP7999rL/c/5/vvVvw
# DATA ygmQHiZMTh393OtyaNkrqHs6kMhTc4vCYb42yjU1UKIdlj6hgttWVeYGN83sJVM74ZzRiqe2a1mJJSqw7Z/nbsN/W12uJegu5Sl8
# DATA Kop7Fx9NrpeyXN/FYS9YlyX8VaMBqR89LSwGXSyqKsGh6/7qFp423/htxpyWl9M0u9idJOPdu7C4loWb6iUask93Rwm956CImW8M
# DATA kEwqoVDJFVFyW9yjmYLcWRogYklVBE9qm1eHolsNvsNM0QM+fsYXZWDng/2oAGfBdDaJPpYtlLuPJzN18Fp/FOtzt1ouyLopX9/J
# DATA F6TVYlShaiMKfqrxdv72zYYrHeZcD7iyhW7WTbIl5sXsE5vavaTYF8qin6+PVvVjo0wyPZxOw07fjutHi6W27L9N89xfm+nqZF7e
# DATA wN48vz/sfuYXArEM2IaG3Tmabqtvyk6+dYq8tSaZEqmF7GU5gOwl5tcetnwM5roHirbJ2MVorCmiyVDKh4axTpQvHk+yadd6+o37
# DATA P3v/p+++e2LJ0ZM0S1r2ZFZegS6uNyHgsKNmABiJtlU15kkRem49wy7dneyxV/8B/6KKTm7DWb6PQ/U7zQGKyuimNOm9F1bFWPUM
# DATA m/BLn6DbYIupB/kfPJqqSOQ6bD63sZ1NZnBfScWn4Mk3nmAoa/YpMJzeff4HQqwmoL9UI/7NN173eNqZMhpUdbW2w7rk/QSDdugx
# DATA usfD7qURvJQdj8ancExGzZwh8oid+/cxC9t6P8E+7qxGdowPvc3Xe/FkGHW3UEZU0T7+GObAx2S/7XpbH3+MEvv44y2JtBTfNXUl
# DATA TnCKfRhdhttvM/9fpVauBf6c/w9eQef/u4r//vIHN2fp5GY7Ht0k08EbH077yaj6yg9/+EMW7hBeLRZfZGEMawxY8cVyRTKONPRW
# DATA b+B6qM0oj2dbgwF1C2u8glimqNf0N+xp0p/7YQrfoP4aQx9sYjkBz+5PlBVE87U/m8YD843nEOZbOljjhQwnthNy3ik57U+EgGcu
# DATA UCPLeSw5yrPJgGIsPaeON13jyR91LLx44snsfSZ5LUNmNnqqYYEy+a7dwcGkpjmP1z7kcjGlwZY6llEm0SeRWv9DhsisM+XC0u/9
# DATA 6XhvEnajn0HtQL94MS5mXKK8keEKu8i2aW6UZu4i6V6XJETfph5l7R6Uo35ORnzLW8OzHL7D8tjwzBO7Qrd4F9XWjg5PZhZj9pWq
# DATA aT92+ezK9EXeMcVpmKmeQHHQenorP5Xi9OP0cIhNMtuWMcnJ3Dr6P4++9o7+cPTV0b8ffXP8q+N/PPodff766M/e8d/Qhz8e/ck7
# DATA /rujr4+/oGt/8I5/dfTN0Z/plu+P/kS344dfHX17/OXxf6Wf+Ok/4estD5MHmPMSAzUmqujIYcfSEJb8tnxJleHHk9iPE9vc4/XS
# DATA Xe0k6a1yhERkb0g+d2fDcap/i0ZY3Pw4TDtxLEYJ9plhgN2t6BmaOGK6BZ4Rs6STmuUOn6DPGJupbSmb25I9QbHfzaVoidGAKWWn
# DATA T0W2jfBRdCvnnLiB5pqIcr4yYK3+AFPKXZ5ObjQXRabtLPu5N5hBbSb3E+KArcjb+h5K+yjRbkR1xyRi2JgWppJitf06dA/n3w/I
# DATA gKBZWD5yZlr/ca9rzdpz2aem7g/fsKfub7zz8P69xz95+J/zUV6YSufSYb8t/9xSO1s9yyj4Jc8uPCOJRUMrcX1NOVPmpml0x2zE
# DATA TY5/VO1Z1o+VE8q4vuGBUqprcDNVVzi1t1+7lTnIPsp9K370WblQ9z+3ft957cPSzg114aPPKoV6FXMd+9VWL/Dfj76l1v4/qE3/
# DATA Gv3Bv1ED//P/z967N7d1XXmi/Tc/xbGT9AEoAHyIlhXIsJuSaJttieIVKTsJhUaBBEgiAgEEB5DEptHlx6Q7feNKblKpW1Nd1d2T
# DATA uvcDKIrVVhzb+QrSV7if5O712u8DgPKjp2Y6PWMR5+yzn2uvvfZ6/Jba8V8mz/6AG//ZXxQH+Eq9/EoVhM3/qKSeqScfqGePkmdP
# DATA ocTH6u+nWlWNnI+UgV2APCnIJKjDSHs9NuC0kM0KajFrKvna5uknueK9FLxCs+rSErAanlddAezspeags6TaSuvxeV5+ZTmYhv/r
# DATA 2afA6RRTewS8TvE/Gp4aqZoT5JBq/E/hHfC/X+BkfAHzpX4++/LZl4oDPtH6bEh4n/ka0VLq6KxXktdqrGfG4kX4vTprfaA3T2F1
# DATA nkLD0P5j6OajebtvODqx/ue/fv4RcHG9eKwHsLTUqGEhLTV21NbhjRCHB/8NLuBqnPSCicCx6ug19HaPU+Xe5Wrdrk5m65Qu6bY+
# DATA NraUL7yQf7Ku74Ln42/Jvb9bql8oFtRmXDJ7r9L4h7J6ulhceiNlhW6gAqcKwVWvB8BNR6gwVrN7llbg8l6ppBPy8jWv8JO91bpQ
# DATA kpq14oyh++OtOlubiAejO8qGdhL8Djbz8988+6JkOIDsdtz5j1ThR1CRKqY4w7PHwAOYP6jKZa7//PwTRWFfAXkC5arfv7ZmlcAK
# DATA YzuZxrpSh50s47anEL7s9JhQp0/CjL2AE/JntbXUkic4qM9YtlE9fv6JEmrsHrOyiY0JgF5oczt6G2NzNKzzcbpzbX29rNOHy0MB
# DATA rktqvhmcGEvDL7RZqSKwGZEweQXgK81ggZYVWcJzNHGoYvhvrRZy6EN5yYWz8FD6PQ3j+ceRVfvy+cdqTpCM4Vj6FGnrE9q38fML
# DATA T6crzjtFxmrCntBEQtUByT7/JKES8FBTAi83dju22uomWhj177V77vrmG6kVu7hbmf5bcQW7Sl+Cp55/DJxdjWx9e7NsNuMcBMEj
# DATA KqTr29uN7Vu3d2sXl1eW7/Zub9zcWn9v/d2Nxvb61saNxp3bN2qcqgaF4QfN++3qRcB26KXOLkzNl6ozjd1b72xsoUECB0GS9+bW
# DATA 7sbtrfUbjb99b7exs3Ht9sYuFuE7bgWLNo7bDwsXQVh367/b2719Z2e3sX371o9+XFu527u5fvsnV9e3Gjc23lq/9uPGjc2tdxob
# DATA W+tXb2xcryGeLBpjaLXgoupLYbEVQn08a4nhOsPwtSKg4eENakGWKtSvS6+8cvGVYIn+nXinYTZEms9/SRSmKFjVBS/pe3dRTAPS
# DATA e3L6RZXdPKNgiXBPExMIi6tTpEFFUXAgqi6DkPC5IpwvVb+fAM/54vmvWRjkN49EnxIR/Li/lhmvYKzwVVfUOJuEBnFdeJobAK7G
# DATA Xt2Rz8G8HTdto5n6QEPQTTNWm+7tqa/qCFiH3+WyfHFdbbBBrWDZzwbt9jBTd5z77eGwo67waWpUH4QUiZoOsc72wXu4c0DBA4hR
# DATA of1ihYcm+21wEialBwopoPKt+bMGjq3hzG1ROzfBUqYFUqoATmT1TereeLjfqEHTP14KywYn12fIZNW5pChH8ZwnRPK/efY75Kzw
# DATA CHgtsOJPQfOgtoISQKDSspR+/iuHVTvHMS4C9QGf8vxl4TzwiHfaIzCTZ5HJyIiWmBJ5M0mF4bmcoND4Jco1f4LOgfTgHSpf8oDg
# DATA H/Wbbf0gZsI+UhteyRfqgIOPVHVwWsGEPTFLEp93dt3I79s8M89HweeqL7+ic4M7EQyLTmB/AVgUl04UgXJWgotaDxRcHUDW1QUV
# DATA Hwsu8Zqoa1qBWIjzjb30+vru+tX1nQ04jdJ6sSLf2oaXwjvtU1TRlZJA2ei1py2ovOLyKnrQqrUCMv0zrhywbmSGT0gAARkNHhpZ
# DATA mhZUSZaKdX6WOB03shX3Q/7U12V98cBbpMUggZfA+iNPcbYpPNG+Vbgi3i7Ax1wFPYFgm7a9G26Ty4gq18lwQkAZ53kukF3JGJ7F
# DATA oAzWtHZ+W1tqeNb2hbGQQklJ02i9h1EVrPLz79lipUNonYERFac3d8fkDgkNhN0OQvyo2cc/ZWkoyAqeYIel99SzdfpIDqaip7XE
# DATA z0hrOYk1BgZMUMUV/GlDv620WOnSFRvuf9If99BiWwP1m5wqrP5hKgCpyhqOeo6DSTe316kCuIi+1e3vN7ub2/cvyUOv12pwmobV
# DATA 5zJjLN3rx9KlcOKZwgGOnIN2WckIiQeKRZwOIS9bj4wXGChSGfeU0F1YlIrIFAB+XHCk8f5B/TAWt3kX14SKhHxlkNnF8cMKmeSH
# DATA pBhT94TPUUf+NHo84As6Ba6IHPUYWewneL2zOURC+oknllbNOhCcbS8zEjskeAZe/ISGDqqp+A3Ir3mnQw53s84B6ZbNabnbL8xo
# DATA 3c6qclRAT9sTuAtaB1clefY7OnkfY9d/gS/+xGP9jFf1T7gSeH+5BjcMPa6tjd33bt1+x5OXYlMsKTn6PF7+naEDZYGLF8E/lgTH
# DATA AxKhG/aJ5wn2LBRneFwFLRmZJbSPQNRVMfiCBPTcj9AHtroQeAadTRzurbWCEVE79FzF0sT6Qj7Aa//bBO/hdD19oo21tnuno7LR
# DATA tyiUpD7AO+/T5J2NH9feXb9xZ0P0JOqB542DNwGd49q+FJC+EuLkMYcuXAyiDkWqhinDiPb8S7SpfYrC1leklfgQL+rW5Yp1s6TN
# DATA gYvXn9I5LiXoziqjIXbnuIa59xXT06kT7F1T1Z//J1/7UFtKU2utFz71BqC+/rm+eIvXvOqZbSeVuAljP12Y6vvseGjz5dt1X7du
# DATA siDkwjR+hizun0RHFPAx4scwpq9o6GpQv47cas22BUtZIzturr5yyR5Nq3MEEYs18QKocJGi8aS1zMBoCUuH+3HTHmyyg+Nx7x5s
# DATA MhSju82T/VazKhY9zLdgxRYUS8l+6uvTqUcVikMuYH3OuPj9cfsh/aVtNRRt2oCBqCPVeOfy5b3fH4Weu2w161JCEmJ5A5JbUWcL
# DATA jsswEjD/4hk9AAs1fKB+wgk2MJbEnbfX1czt3Lm5Y7guaBkHjlF7jigQ0qBRzUXTGezmXAoQJBpjE0frCRL6Y9qjRFBqI+jDmkyx
# DATA MNwlexwQ8UB+wg75FC+kSZJeoB5eQKd+r5eyJvcRcaBBS2PmvUSnSA9s2ylFwM1eJnQCF0FK3y+G/QcoCgZ9t50WiqQ2QWdnW+rO
# DATA NZWodWiWD9G/tZgkBW91iuCi13+QbygRMwCK8dDtqESTu3LCpL6yZBg8Llht/PzncIJ8rLjWFxa7xcSLNZzBpZgdAq3AMVKUF0zW
# DATA 6mnALIDAxc4RHcu/+L1kCY16CYr+aVSYp16xRofTiAK2jE24AgNbqfPeeIRXKNa6Al4W7Ak8avsPxZ07009YtnEKamlFkyyqnYhq
# DATA bamD+oFdTEUBhh4eYmTtOpWg8wGotPwdfad3rwcR+Rralb9IvQAiHvdrNZ/ELPJCVbsshrsC8EhWgM5yX2mCkyYnHe2vcB6L8enB
# DATA kXEcPnyCd0NrKPnD30JIE3jFHaB5SN3llvMhlQTwZcgPMSx0iGF2kHsDIgPGzGBFe7K8iCKX1ovFeJXWcD0KKZr7WvRLPApEUQA9
# DATA 2LPDQnjagM4OO6pnQ3TT5arrFOEJrSLbF3cNEyDHXeIxcLecldDf5FHllG8tltjrHJJIYE3EPF/6swE6jj3OFJKSIQ5Tz+AlhBrZ
# DATA o8QiNHoqj2Not9K6w13lA6IjIA5UBd3uU45AX4Zwh42xukgC5SF/4NHufBvq/+UDlVnyf1Oc649KKFZX5ef/aLgYqSoVM8e7spLO
# DATA 1HUURNOAjyMP1BySRGf3ijVwTkHXBMLcHg9KN1DMZunN/azfhZxp1gTxl7reJXiwMNchoSTyfvc+ZgPKGsN2tznq3G83Rn07FgoE
# DATA AacsmlTDcCpHpC9raWWKPP9LFoiNvx8J8Y/Bwoozi4oMsN7jZfzZH+HcoVvLI5zvx5YZUQYrmwaZVXgczu4wHl2/VnWr2zre8T8E
# DATA dprfYVdMd+dqgSmg1x6Phk0AiyBKEI2Ekms1XgwgBcH8G9sMIAYe9SCMl3IldZun7WGWQLbWpHk4Aqzyfg+TxKJb6BUGZKFAc0JU
# DATA 0Q1pS03MwcbwNzkx5bvKafOkax+l5gU9p9CPcu53ue/V63pIxAY9ZynRenV/I+QuccTVNKpf5dbcfWkthLkGWpSFukRcoRm1Bx6C
# DATA vPoY7qE66oVoK/502Y3RxnGZ+yhsuLNUEJLSanI2MZoQsTnc2plmcnB7gc6o/szy61zJ9hFKtE9xd4JUq13ZReeH0gZsk5+zo8gX
# DATA oGZ4rI08bKB4nMNvydJG1/dPUedGakvkxU8cRYTrCWMWK2YXZWAi2XnBPZKlsvgVxTo8qdy0k3PBuTnw+RY7wrGTyfcSRq4l7CUG
# DATA E+r0yujsqqeX8bvUff4+ASX1uy2NzITktOCfqbN8rqOXFBDqUe3w30Ch/Pwj6UA5uFtShL3IE9Iqe0yb/cszioVk8iLi5l6q5xzs
# DATA aYZz8qioNacUyJogG5rGXK8Igyyg5RH0j7h4cf7ZcI6d/LkQVYPFS0Um8npgmtZO87nshyQneGyLTUZJ6CjXQkmrOkcEopCxFrfR
# DATA 3wShKhwxL19ZOsNRI3fKtJeyoE3rveW27A9CykelGftl/NorJfCmQi3RG3++znMJDgc5x83XXUvdc9RuYI4ldTYgVne7IDEZVrBm
# DATA 1+AJsAlJq49l7UD1D9ch29p0hifYIQtzpaQBgAmi3pngpECxHJ3U79SI/4CmDzIaPRI31SQUnx6H2ihJ+ukSr97cc1wCMLKTrLRC
# DATA LhCkn3sTsHeH+TZKOu7rOPGYMjhTsrXDLkeVKdtm+NY1WDpMAZES2oOftAlMm6Cyxye2TsieSWStVtdcY7wUnMU65+8x+/wAiGFT
# DATA zdyxEjVNPXYnh52TJvpQ5wtYVve4uHdDlErYkjidfl9g1gG/sNlLxqyckeMWma7rJSAM3e4z5efxl9sNh6LNSM/sweUHSAHZuYFK
# DATA /I+5e73kyMhx3fNdK1jI2iE6yP8i+t+5DZFu2rQvWvCtW9c3Gju767sbOh5mc2MHdywzUYQAghOWO2PGhUr2POY6Y3koN5Ob7jc1
# DATA WuKA84k5FOnBsU9rG5VvvrTCwjhc5qSTASC1GwRGqr4sbmDk7/WFxOMbHKsEE+nZY7hXAvyig+9sO0g4daTWjw6+hjPw18ly/9VX
# DATA XzU3Yj3LdhD47TYhRTA6cPt+pz/Oks2b629tlJJxRskPwB/wQdtKCd0bse5PbZYBIF5aNRKaXfKzcX/UTH6qSAIOdlzIBxj7PWyr
# DATA qR23McK8g8hEkKGrxbdYDMsYD0xIOcceEgsoeTsP3Qnr7h6V+5lb0tYOupOJN+n5b4BykOJXajG5Z3kLhOVKwZ1N+9B2m70GgUeC
# DATA XrnB0nyBhlaiWYa4/oPjDqZ6t1w5GVeEGUKrBiQtigP+YakoG1QlvrDVCnR7MPkkxINKR7iqbQhUYLGaBx3AYsM1fdActow+AWy/
# DATA +SphUqtjsAkPZ1q5QPD4Lbpg2AqfP5N1lCLFHomRN0Ep7Ym6fH5MnjGelgj9RIx6/Fc5PoWexZcnW9CuHJi4GBqc4sOU0BmYcPY+
# DATA QF+9f/f7Efg323vecS4h1SL06+mzz8iKDUooJVGjIenjyFTwhQUu3hhBEhvafYpDxpzueqn4Ye7o+b07/piX+oXCG9W7FfqzeLZS
# DATA omA/+nqeQYv7JzkjfYjmi/hQycwUjk9oq2EG6pJbMNbgC/Y3dI+IcFL8715wdvxqivMaFMnMY8+U6/Qbkb4ZnwSd1siAzx4zieK5
# DATA StotgEeDuscPCgj85bilV9SRBHFQe8v1ZDFZK+5V1zwxDSoOZgX2BL2ZOr7fs1cEXLMfIQnzcnO8kR4Z6I0+JW0SDxx8P6ZZIK+Q
# DATA 3h44xX9ojqFI6ue0mRwv5E9Zsf+U4s9J4yuUZfCeM3f72G+4sDoCG94HLhlGvpFMOn5Rfr5uf1EKWjDWJJ9OrUKWzwrmF7B7yJzM
# DATA qZPxh9Q717Wzd+q3ws6SU3aACQp2be4AsWf8IbSrptMNr300/KmpcQrpm6v/qb9x/Zkzk3KOQdp9DZbCr8pHwKQFtRZj/rb4W+12
# DATA BNMgz/QMWIXCIVl+yAGVxlo6h1+K491Asdr/iDrEDyk20+NPgQHniY4n9DkX5U+A/mISDmf7wZMdEq8AjtjdPM5Lsn2zJEZOa0om
# DATA ooJaQEPvbqNJ7fRktvzdYr/Tlarnupc5sxzM57+p+aEp0N6vf8bAwj8EkRxfIUv6GP/70bPHLOOcdy4HA/Sq2KOEJuybXquZnqPj
# DATA XmDzZopwItmB/qhCQ378WxO2RXG51MbfBHPzP9SQ/oDBlY+e/+r5PzPzlvmRkIao1u0vFNeiKmCpAVynP0KK/VjV9CQUoz7XMS+M
# DATA 51LLiRpjF/vtbQ4YtABkWVC4uCr6Z6oK1c5ryz+8JLNycEx0g+2Qfx3Z3e4ietpd9FpByNR6OCu/dUacQxRRbfZTPPnQGREfWGPI
# DATA 09uzi8UU5bzWfedeotg70omri7pu1KOwBKSMRM39qs352CVths7yX60oXV/Elnn5kunsg0CPGbAuUWVq3Zag//PY6bkzfOxYKbgd
# DATA Ze0NcPLdRsTIYlFb/1E+A1EMnKYrgHF0r32aFfYWuR5uom5/Umk/HIEqeD77svjy2ep3z3qhL9JQezVwN5vbuD7HwRGqjuOBdrqn
# DATA ovc+I9MIuqGS9Q88wkiZX434ugWd1x7KwvIhnTtOhGN/TiuKD6RmbiQdE4Xd+JdsoFD6qxg7W7Srketfa/YFlaZPBYmUcKbdWRV/
# DATA ZZLTsTgpLad44NOIjdv9XADP57H84IJqQN1cGy9itUQXeYoLjO4srpJt9bUdXIxnDA3WWUmjzbE9teKU7+4+arT47e4EswOUDAVB
# DATA LcYHPG++HI+zb2tfKP7BrpiAL1dptdsD+IMVVZanoBGo4GRPS8LlOVoctMMv1YKHea44Of4BvxYn+S/RrAaHOyJTJBArpebsj+CM
# DATA g+GiJkT8+cdytNsYCZYwGHGCiUttsvlrMit7ZoPXcewGtCK+tbh4EBTjBqDYosoX2iyRd9o74nYerbQPD9uoIFSdL4jmcBa7mmdE
# DATA uuJpY8rX98CPP8l4UM7TPqy5q2/uFo/yhovA1LC2uns0QHruxFmHIUhUKIhBcuqFsRYi0fsuQ+fiHiKAM51UhHrX6RurTYXXAoya
# DATA bQqlTW0CLkO6wTQebFqr4RUll3mf49qBKpIvKCIFiM1EO3GkGofcxEA9LKjgcN8Jw3LpK+pLNWwr+u+AAArE660oZ8iQiFJejL/B
# DATA xdhbrleGGq0In5RXNH5RVcrYy2G1hWhI6tfoaEhg4fL3zxjyvNXBx2pNAfAfcL+VjPIQHeWarRY+UQJZ+7BzL41aJ5/9e+7Ohc3+
# DATA C0X9IJj+E8ZqqfX5nKJARUOV0A56ChsFtwgGoEE5BNP6AD0of2XfmT62FobXYY8nECK58C+/QGXQHxTS/XGnC8ky0Ihg2Xx2jzsZ
# DATA sxDACQETQh/h6sDFCRMAaBcPeD0c9Ltk4oYTU2QFq74h5Dxt94A+CHyYbVCQO6CnegSIm10I3lEV9jC5gY4fA0hidSBWwhHaMP4w
# DATA zrPFxVjAoy99mSQTcIZa16UqX940KGEK+v30+9+X2GRNovYpE+O69vmhtR3QKcssZXcxrBhv8vVYnzndhypLMFd2PexkSp+5cbOo
# DATA GKeTwlKHk1ggvYt9t+AG1FtyctjpMFReOFfu0RtlDPkTNWUtwzPCKfw/2Qmh1y53zrXJcYjcUUpubu3srm9d22js/nh7A5YVuJna
# DATA IcjICIu3T4D6B8ft1rjbHqYTX2tI/yvs9/vdGaTHXJgkYWc+hT/XakleFZoHFXM6YM28mg/WjUJL6pe1CWkXUltC+EXnsOV5Aj3C
# DATA N3jsaiHHxNY+IgPeZ4hT90SJpU85PNjxnpp++BKKLW6LC0l6JbSNhFpXJ3iUzGTamfZxvhlV+69ra7DrohXyg6qV3QZlygh38Wi4
# DATA q49sh4iN/sySL+ELR1sGD+ZWlc0WPL+KCZ5P4pg0aGb+nGP0ZwjXU1j3LPY/g5HTVeyg26S7mNPiVNagZlR/ZzN0zAXLL2J76CUE
# DATA womLLdPn6LFzYxEwQyuKIrTNG9PuH2FtIsAVV4TAv+BbMRoHvxSpByx/BMx3Tor3qP7MncZqgvwmdvhP3EAK93KMt1wby1THTwGj
# DATA q4kDR2jeq5E2vJTYutHaHl7mSfVXrOuXRoVYswtY2aUicrflg4zwdgCmHhge7S93odgdVYplg9yC28ToCenE6Dtz6vK3fM4X21q6
# DATA 9+6dpvczze8Y9Xt5UtZ/r03Ka/rHRfXi8g+b+3Xnify9Qn5yurE4myFUj6kwn2FgxKPkfOfDE2T/j8gx4p8AD0VcAQx8+idBhMRe
# DATA zgKAIGyGZYdOnGlPiWqyAtE7Wv1f9f1GUZYgz03WODENutlcdEAnOEHpv9XHpFlDxZRRZVEWKHDwqoqeRaJ91RMaFXSLdy2U4j9L
# DATA 7lm9YzyvolthIr5YM7X4qAkXKF0NiYI/g6COXEuIBcSLF82YL77ttknoj5cnu/THpclP2EH/rsQ2Y7fgkusBgOuEO6E+OxLOKmFZ
# DATA fsC0H/UVD/bKeQrfUvxr0LyJaQ1glU3HPUgk90h3wI6+ghNF6zPQESxmyKmq80Ddnf+Ax4McH7ivWP9qMKnLZTvAJ4QSyl1h033w
# DATA lbHzJ2URhbQ78UEAYWZwPu5zKpGYwyA4EhqShF+etxMCk2AEp36X+ZBrc3ri5UbK/AWcd8DKlnvkxrXYockROjkrHKhglaSh1PM+
# DATA CXylXWODnpGDAKCSldheK64yO/dlBIB1ngn6igJo0KmLhaXPbc32FLO17aS+t0gdM1xXyQyLZrDMddGuFIZfWn7rQfSRzrCab0gw
# DATA 8RMhBhDsCK5iRgCOiw0k/gyeZYQ8HdhFks38ZPuHSZUz+I+cN+AxncNTFoD9xR5DccMknCBEhKjXAd0nnVHelmTzR8MFGZq+i190
# DATA S8wTa4F1eFEWYnCOBK4FBFSdO242TjpkqQ6iNcMgD+qUZenHB8bSTz/nZ02zzPuPNfciqLlc6nBQdYxbOk6U65A+24ae6z9uJ9wJ
# DATA XcdNCUNcHovS0eYS80rE5sg/KPYxldqY3ugWTpGnfdG9njR7SgJvJaD2sHLDsdM+NQKui5CwHP4VN3LbNTwmuc/pMXguZHKhGv6l
# DATA BAhI0H4eJzZL0KZH58Ew/w53LmvcBbCMhW7XFmsOKKHOHFurxUTJ9fwxetkShhp5Gk9hmdNnjXaVvp9ABaEzniWYxKT3IM+27XLn
# DATA u5l5R7LjbFt3BF+p5Rze6QCUjA72jAsBlzhfgzebTmKdiNmYadkcHRF8Vv+WDBwRwHzFd3AvTWKcTxwABBO+DdW3GxDI1SD2JIFc
# DATA BQ52AWZ1rtB7F2mM/nFgxnoGPhza0BtC2nPxU3gz+FF7JHNTbygAn6sxMaZ5EEnhlqcysyRYKWXk7roBTxJZff6gzSCaTofQ4axE
# DATA YjZ9ACofIcgMfRZKkAU68G12OAgynYN1BohE6kblSiYuHw0GHRnu1O0py2q7HtfzhKuQEOcLHf3fNWw0n2YobJSV202kh24bLMX9
# DATA Bz3I0NhrDrLj/ig0ftuYz+n9fnd8IseNcacanQ5AxZTud3otNJdRp6t2ekEw9NM6VRN3aCy0vVDoOvFb8ylIhC+ki0tcT9uqy360
# DATA Ay6WQ5qseiRqa+Toj4nLNqJh8N410Q9Sp+HNw2jMTi5aXFqjiX5dTbnfkRiuIP0qWkeWYJLSLzkGG2NK+ilBUOJLOWx3282szXmp
# DATA qwszHS89cNnXk7XlQNOo79Y9RbjDzoF2CFV7uH+/TWkjFWGT4p674LuBTs8888OJiVzDnzp6jdss5vdK4s0owkzHlvGHTnSZq/uC
# DATA zy4kheVSMVlMCmtJmS9+6nkxmGi0pRTs4MqZMZx+2GYwhJQ9XUpmMNoxRfxkAk+jBddVycF2HjWPEJGU66gMLXDnauoJt4KhDB5N
# DATA lMxKfV4NgZS5sqCrhhpmr+NCLmJqWkDrM9d1QdVVVFWUC/eDx8U38MUb1eZJ69La+83hyaU19RDPiSMPlMnMjiCPapB8oy8qWVir
# DATA wUt//ccDAiIumMrd5LfmuZ36r5AeHR8MK52+ySO1RF5d+ldIa3xsNBhA3XhzanFKN20GiigVNZ9gYz4SBhIXF0N3O3RhW/B8Zs6M
# DATA x5n2QcM/yoNh/+Gp97NMl/qh7aBmubeFrm7Gw42c3iYBNRo0sbm9asDBAqNR53PEiDvgWJ7tDqYM1h113UDDt4vYOs2/IxgfQYWA
# DATA pdhISqwuF725kJGWouAV/uuaxexikT7EOlaK9jZa0msKzikl0Ti9dPo2sTeNfaWmEUOGDviD7qCU2YUnkbdJMwMHPf8EzHxIA5KU
# DATA TOw0/+bjyQI6yGqFopNjumHB0YYnrVuvnamjYdJ353+n25ej2qB/aInb6gAjiRix12okQBk5Tyj3dAd4rUTQPdHzbBS5uieRd/YU
# DATA xiEb+EgY3mNwDOPX/7Bs6JVnyc9YZW1RqiLwCndQhWEvUrnQDmVTmO8H6I9dxHW7Lm0As65OwcTEPtSlUi2YGG4+6PR6YI+OkhSz
# DATA djOtDmPnA36OkytnkBzntRfDb5Ce1ecZrX4zX1ysvcZ+LLwqmBsPD58J2LH9JhdauZAf22u7h8jTohyBPAx1XSHM8KBip9ed2Sd6
# DATA ZkIfaOz2ET8JtXjYcjXisD4XweS2WoxQ0fkpafqWof75UVZzUs4h+bIRv3YyJloazRZ4gncjGfE4K6Dvams8aOlDKnwj7pfL0pIt
# DATA RaixVsgdoSJ6nMyJA497HYn1tui7h0bqM2UjIU2JUIZEiHvUEU9g5i2pT5hnTAVVd1Y2iTTUWc4SVpW7PgmF0jniK+Yi11gHnIk9
# DATA F116fcHed3Eb22vQHx5hohJDXxW6hbmgLtNJXdfdiVzU5WUxdHv3t8i5tgeFfJYMWtmxIqBeid3k5VIOzM+ZmEI4jFIghYTCVOqg
# DATA o1BGHAZBeYIulY+U3EdKCFdALISDKgWSTSisue253gkYs/85toiyVF7UK82QRxfa02CWRoX/DXC6pAbf51Wev85jCYOkhs2OWpE7
# DATA 1Oy71CpiKbPrq4snY/toSzZ7yNr2z+RoXI27uj7C72gK1Icldk5C45K8JUrx3A0Ewtg2AGsvI9/GohGY9HSVjKEmppKaao2JGUeW
# DATA vnHTCCyW+VbrgoGp2lVKF01JJXQeO3jX54P3zcWUb0rYZFxrGkUtYA94gi34FlAJUs+B41zoC9S5AMsj6meh8YK63YLn3hN4OcyE
# DATA 1Qf3nCCG9fmvIJJNkskbjFl6Y6EwGYMPE1semoLnWFI9FyapbUrH5C7fpp8mojACTAOBekukHCW1I3PBOFPn1f5p0m4Oux2UsZgX
# DATA Z3RGt5stq7o+oj0O1B2+OWIEx46qvHPSVl+dgHScHTdb/Qcu3mwlhFlw/UaX/jO9Rpdm+IzqPv9P6TI6B83pAbDTqFkEz2d0KeYx
# DATA 6sKS2tAk7ELq7oaKBAi7dVUjsLsuvEHMTasaQDeYa4W9kdgnud9Td7Cun+EhRhqOtkA+dPtj6svvES1/WH9CDBhRvOGg9iCVyGnF
# DATA ynUgcSmaKUM8Cgfk/of2E7SCqr9ycrX9mp6djyr0+F4Y6YUZesTQ7QoMkcRQlu/iFIAHORBdp9jgKZwhIZKQXdR+bAqbCmK1fpfA
# DATA EXy8wyEoDDAfQMzVDNBQXDekKKoTkc5XFiZOPnzKFCAINwLwiTsAX/arRuEhHPEu6gmBHHpqCQ9PxLqwmxtc2FQs0ZvfWLSM11zB
# DATA 7LQ8pbQFW0E1xWRl01c/8XMMo0l7Ri3izhOMphfKHzIld4jnUS5OfFNY2hUE/6K8cer8+0w9/ZPEz31FMpgHpImPDFKuk/TD9xju
# DATA tdoPS1oSbKNpsKkRqmfC5sSy4byeXF6EHDj4nymO4QY2Cl2+nz7/heSA/QONVT1w09eiCw4YbyIoOZI7o+r2spRIOopqEqbM4Ax1
# DATA MAlQ8oQsKsv9S8vLk9yBe6gdqk+iEkUUb29KbFDvUkLeFLXAAb8Y8SOO5tQoSXqq/FQTdsQLLrnWb6iabKcJIdPZrimH7HrCFU6m
# DATA uVLYkmhDziUDSEfnkpUJFPHTlbhbc1JlzOR54sAVM2ugF6VlCagapmAZKaoxRz6wl+r4Of6LSMGJFsvxpjSy/IZmyep2BtJ8lgCv
# DATA SSC916ncSgmNvDkEZSPmTCU0d6zUqgtmv5JsYAIxEBbUZxmCvqMnWLfFkNYDAOzARliiQI/uUSUOsx7KW7O82+29EJdDGUH7G7lx
# DATA +bctX1YVxP9iUCKE+p/fP1/LUt+Yf1Lc698KMeb0Xxv4j6I2J226k/jK3mHxat19ZzECUIrJPbw38kCELLHFhilAjQbBGLjDIpVW
# DATA q5Ph7bdgYdtbuk3NUBjTXqRdIGYbzV7bC+LmBSumK2JDYHlytglBq/w9N9BzWR40T6JGWbnCZYIj/l/CDOEIcep5oXOoGM8/euQ7
# DATA kNpeGJQ6FT8yie3z5OVfaa0LdrUBe6nAP/gE6A/vEWi1qyyc33xS4SpAw2cQnKIaQS7pqAN1B7gH6VKa48tvZb1PcOYIVulpbpKv
# DATA XImpXDbHXA4CKjyoazM3P2C5dM55ocOgQWemD21V8huGrVWQyVhKBtYU+pnGkfs6Kkt6bAFRU+BK0Vf0TU9W7kwxQvM6YLNPEksF
# DATA OHuKI6oUwtWIQ/LOl8uZx5sDlyFbUb+20XHjOiVRBIWDtauGlBOmriuBfG5DG8Ol8wPcz7+0Amc4AYSnDUXdpNNjaqHxzsaPI9vg
# DATA /4k3/IRUzZDblppU10i7HkczcIZQQSdNhgWwxSCLawdyIFMm+ScTD60KW/FgAjw3Zca8dVwBqol2ujOXQXJLpr/30s2WEsLcip37
# DATA d1VtGaqjjlL/aNi0kAL26pMp2a+r7hkPN/vOdn9IYTcD9YcBYEL39+1btxEielX9L3X9XLECPglVF3qZ2mcn2lkqfiSyI6vjIlVy
# DATA wQ0IYSRNtSdiFKDEFje/1vnJoOznOgUtfxNGR8n3N/GQ2MN4qbkgDXPB05kZpd6lg8Rh7cMYg7qKecPwtRi8D+HnWeFgvpkszp64
# DATA qsv8inGQL/THcP0wJvnAbFPh2AoxdkrwXgG5weNAXC5McQAtvijwlseLIyCGYe9iX0xDNQzclV4UqTKKg/Yt4VT+Z/n/vijsqM7U
# DATA 4gq4Yc5t0sd+Dh4G2kz4m2e/KyWMsRZVezrwTt8CdCD7LuNGd5228vD3zJWrrz0rc/ZXAWufE6/PcgHXrutlp7x5bH1p3VXV95rf
# DATA IdKfywWnQ/q5ZRdyKEKkdYLeMy1WX2DPzcQtPccuj5/xhOY9laCNe8oUkdTRNwz7IyXvkHui2ktVqWJP/aC4ZPUHWVYtAQzvEfyC
# DATA P5jk171nyRzICuHODTIJf5ovlxRjapoQtjqyJ6IYmDMDlPfQxF2xomBqKXA48IWpgbrAjCmnZD3aoA3MFKkdtFZ6IfBGRqb2Q9y4
# DATA I+Kl8U7XzzFAMdPBwsmAyPuC17lknDF0f+QQlhVngUdVHNNPoZWWvzzn3J8tLqpHpWRxUdcwCTOnl5zt6ABlqa8Lqq+DLrrzH6uT
# DATA giQL+KsB9OZKpJkRRqUsmID7sLMK8kSMnFn2gPKKE8heViGIsuP2w8LF1eKCzn2A4lUMls/7QpH49q2d3bdub+w0ttd3dt67dfs6
# DATA KvipIS9Iwip8Z2fjNsZKWIeifnn9qvvKr8XDEDy0jtPq0pL8qJ5JNyZ/Y5h0a7/6ytrF1aX82t+8fWtrt7Gxdb1x/dbN9U2I0k+P
# DATA R6NBpuoGUjMrkm6vb23cMMX0G7/KnTtXG9t3rt7YvGYKO4LUeNjNCs6qmpWHrbV3uQqXqbff27yuerZ+9caG6t3Gm+t3bsDSKClj
# DATA 3A4HcnNj9/bmNTPXzdZJB31J5AWsWHRlV9eKQW3vbVx9+9atd5ggGm9vrF/HaqN0wQp5tVEhQJGJWUvK7hYlgguF5EFzNGoPexhn
# DATA 93cw8cN2BVGo27DzixgcV6ssfj915TZJD8mfl7AXYHSs3PTYKHcPPhnvm/Kcv69RTQIGI5UddptHWQ2rnJK/Fuu/UEMcVVVDyK4u
# DATA 4CubOcAnzAwQ6AF4AU0wBnbut8UBj37IpZhfuXGOmP9IUF79lEjw++X07vBuD+BdXz6XWx/ikmq9xhXw4uFsUKz7NCcsJ5GykdcB
# DATA jx3+IFMiS26O6WbQPAXDtRocWBsq8DcYr7L2pbXK/qU1NqbJtAjsEwUUOY7SkeRvXDeetPeKLkoOv9u7xwIDO2I1r7WHo+32Ceyc
# DATA nz4YbY/3Fd9+hxHpVU+s1/BTvYFfPmAueb2+C+tOzq6ObaFgXpSS3dMB/Rmsij2xn4Jmj/0cEaNYUiw+wgQCpPkzAHKPADEGkGE/
# DATA RIfij549RZ00qWcRqelpPK8pU+bhy1qwqZ0RvU3u9kyHaukZA7cqmn6ZafhBszMixBJkoAUJUeuctPvjUW112YQUW5ECGOuu2MFN
# DATA RB+hEEK1eq1mV0mSaRRYJDz5WH8EdV3HJ4Lx4O4cqxg0Sbom9ulR69o5hCO6PSVhF4bWq5LZEhjVDo5VS5WBWn+t5DK1BIASQHTL
# DATA yWtOGc9U/1otWbm4svzqanSD/gGdCsCL4BHc/dxEN9GVfpS8vbu7vVM2MDo64K3HKe/t3hgjMOuy2s1DZpmShLcM/7u68dbmVnJt
# DATA 4/bu5pub19Z3N/BpZfEN/FedpcG71MqtrarbcZgXNBMM+PfhcILB8JXV0paLPvfhQO4HXpbwLOtWtjduNmDYjVFfHau38e8CdEId
# DATA vcViRZKFm4nCgwO+pCTfDUa5aPDLwkETrWhwQ7Cms+jUUGH4HTxMkvepvnc3bm+++ePGj15Z/qE6ntWUrd9oXHtbSQzOl+oc75yM
# DATA T6xUvPDt7o0ddqeHP++vNFbZU7zZUjQHRAwbr3LSV1MMvm8FOEN5L5LJ6RhMKUGh13QVFpZKgKzWGR0nGWjXRjIpqrc9MLGrG0Ih
# DATA XVl9tbKs/m8l1SeZYQRqPIVVCEt/WKislHRzZb8rkCi3mSle+iCSFhw6IBP0YNgcNKg3BVWa1HLtYUP4RE0LV1CfYlzjYZ6gr0jS
# DATA pxgqDsxq0G4PkVj21S19qNayPzzhg0hTDTAwIb9q7rXKgNwTxuIH4B/noF2BfRGiQf5J0pPYwJVqwcu04RG+/sO0mHNroa5nbWCn
# DATA 3cJh+tbGrmJhsI+WViorIBC8raammpzJDE3g2TW9lOpm3QV3AZAc1P+H/G14HBeLebO3urwMbKyDuh9qXrHP+4VXVlZFT1fcW6kD
# DATA na0tL+fPkMXu7ZPz1g4fm/YRugkOQ/4ZKlcgQ8RAXlm33R4UKnz7oWVw2YqdyJjX4APEmP5zYqFffklJMZ9/ckWUahS684nkWcY1
# DATA LUXZMiZO/w9KKgO2UhT+yqRqFGs+/uI8eAVzB8k64Fugji3bZD/zIogyjHqbpnj2Sh067Bov74cpJSAAOKBkGXfvsrpU4bEpXxQn
# DATA wHqu3O1ZRfeq1XpuOUfcPUzTlHZmcna2YFUx7nUeVpfuN4dLat8taSX20nDcW8KJqMDmhioTVLk24K7dP+h3ryyc0eAmcklXux6n
# DATA whD0FbKSZN2GfcRHWht1vVM9+mUDBPucrwfDzn312v1W+polyKYrq/zvRSoCotJq0u9dWbCGgLerLOkfHl5hG4g6JpfG2XBJMaVh
# DATA myZl6Xh00qX3zfGoj15z5pM2bIcGAk2uLa8lS+o/FeuDVktd3pottRQ/Kl+jk7kMkmj5Fl1IFU1mvc6hkqq7D5qnWfDVbQBMGbaH
# DATA 5e2+mv5TkKw7ByP25Cs/OG73ygfDfpbxE6eabp8UIcnf/UOy9BAmALxlloQo8OjrdiBYTx0Rjf1+65Sko+Ur+v3RcHDQIHGFDpXk
# DATA 4vJy5r0HtjftPXAH/Etd9aeRIHYRSZAqmEzcYahR3L1bKbzx0oN2t1tGXIelohqNOtl6p+DnfCX4BAYLpyp5JSTfHw87+J+lpKYW
# DATA Csur/6f2C7ODw2E7Oy7E3HlK2vor9kx96qX68K2lavjLaYm2T03bN1BYJ56BpX1NU4411HuM/Ei1sIItoFar1x41UAFBAXHcknkK
# DATA hyY/RKaBnpqKOXQPIQinm9rvqPq1tYvytNPb74/V0tKLy/DGBiuy6xTFX8Gp275gxO/CgOH5mM37LGh/QE7uz75IXAEUr8VpcWGW
# DATA CtztV8295uicl9aKBB2jvAh4BFGE2yc6mCIiGZuwuE8xbpUBRL+R7pquaf3hHp4AsQg51lf4SxpZzDAcCULpqAmKpbuYl0IFJahf
# DATA JuvbmyVnfQCjmt1JHiU/GjZPzVX6S46gk5wqcJpbPiGdQ5+WI2A3OdDuv8VAJ4g33FL35fXrN9V1yU1I9ynLDx8DHjbc6T+y46k+
# DATA pZU2UQwxtHftIhYEmAa4uHleZ/l6pW7/6Ij80c7SljrW0C0kBQ1NmdPopv2BeICcpYpRl4FHQ6GLy6gdgUdYVD16JWUGCHG3fQH8
# DATA QQApeD3uKSaYlbNRH9K1wMfcPATg01+BglJH6J+5hm/tZcx22ZbtUDMJqhl3OyedEdXT63N/z9Ksfwg9W1leu/zKq5dUh9Sx2zIP
# DATA JpPJfH5SzcFAkpfR0JlLS9IaSdpHrqxmSSVVcrFeiknIsFxZbe/Q3LOqoqWpIqePf8agjLU9tkGX6c5E5x6cdMY0Tb6tWXVJrfKS
# DATA GsUSP8ipudUGA2PW6Pdqtum0tY+zqcTYFtqOEFyJsRiUINEdHZ+mE8eqSibx2R9Not2g14iNqPoxUhQGPkjptZvXyztvb9zA/FgH
# DATA kP2qfJjtoOiljn44lLtwaMLUrSxRHeh5jkkW1ZxAD1aW0WrB4gQSdUYGYSX5oK/TJTpYhqPGQF31+y3aC5ltHg55SmC0BRXkQL2j
# DATA nDJ7qWYgaT2WYilCWto+Ul25XFlLX5jI6Ap5fILCVy1VF7iTfapNLGBqjnd/AsO8s3sN1tHQl/TQiFSWD8SU5uZZwMFRo5OB7Hea
# DATA lO8k3//+mWNmmiTllvPw+tVJsJgXZ63l6vLEDttQNJkz17RjeONUf1hudgedHrDHefda3mRAO+q8sb7HqwF0s1zO1FbBXG/4i6z7
# DATA ADJPWml6qvjvSftErXN5gCI6vWurbYSbCsuA1Ev9gt9e1/gfFHz94orCkcm/+uqr9Ao4Evy1nDug/KU1TjFlJfdjfdkc/YH8pF9z
# DATA ZS3fOYttqVJqSh22hIzMSowUMiz81wlSCkXnan4iXxL58q2C+V/iTV702/6LwEMj8mlNxADwJglegzPM5eVSoqTsSa4vEgtg03N2
# DATA 2SaMmNxFuexEdUJWCkdmekpibhp1Ycn2bN+cwNWtHt+/4RqF1EuSRo1g4NW3eyJ7IO3lOt1FcQQjx9YU7mx/L5wapLlDin5x3sf2
# DATA XUxMCFYYJIaV6LaNH+ovdjhP3/0E56j2fWjXZjntsA3xSy/zkW3GA31fQgbQa3b57H65WBkdq8vDsPY6+25BrOCoMKz0772xXF0p
# DATA FisHGA5VKHol1Ks8/uVwmVdmcZmV1YgwsOoKA3xCCMQaRD15qBA6KZthkIZba4HMjYyECz5FguEdv5qzV+htzq6gt9VVc5q5h/5b
# DATA t65vXL3zFozpZNwddUB9MzoY1JZBCGCiSy8vVy+DQgBu7lW6vcufS+PWYJoUEBdag+1xDXpJYQ1gXK8uKRpZwq4v6VfVYV+nEC/D
# DATA fFaX4L/mGalYq0tu0hmvcYk+O7MqwjA1rxo/dE37i59RlL9x1U/scDf5E5aZcdOr0vTEUoGPhk28auvViyw4KXP3jLDIPuXWBo4g
# DATA XTiFcDfOfYVRoix4I7IKBw6sFxc5WfStOWKv1uqYiziPsTSFOJTcIGQR1eqlpST4Rt01M+ej/tFSNh7A6qD7Z6zLIdMGq/ESzIMI
# DATA XrFuMMfL+fqgP2xrv+LY54ip7JSqx6UaVCTBGsboqO7G80Q0T3gMkE3Bel8MLy1Ct3XxNQ1Ghmbz/CUZdTPYq3lnu2UiyWNa+La6
# DATA Ulm9bPhWjDgXzsdlyAAB+9tmM6SBh6eV1hLbg7EQMpzpnO0Fp+a8tc7eAees8MGDB1JhzBQBffTYp8Wy7AV8Uf44+SYiqIyabHYM
# DATA VRBEFZJHBG8HpDQvzAp++VX7YVQYFROJoaJJZCmJvVuq9nb1K0YVgy6orYM5yipipil7xj88pbl4eBp2l2Kzqonoc1PMCGL1FHE8
# DATA dCaoOVVk7GVjy6V3hiBd++EnU70mz3XxsgPKz8IEydWEzBPuGxp7ID5P20Q5yYKJDiFRcAX+s1YoFifFsIc+0I1w1qn3nBiMlTNe
# DATA 292q5mr5SSMvjlE10gk7OvsiFdkknb1XytHkF2NO0HaQHhCF4h9OsIhgx2A6vBJYzvoPfFMS22v63RZw9wde0ABnFnEE1gJWV7T9
# DATA UUG8VjU4IVqoWrBTGoA/NOyKv31vt+E4LKeY3+v6Jv2FXrq2ny38Le6zAKtsmvTyoatylMpHfgW+yKWYMzE8NEEN6pcTg+BGyoSx
# DATA RWrYFCXxUg3mj1wj26fF3Lv9f9c5QZ8++zNHEWGibQymhTTbkaCh578moAKomSIbFWkQ1g/52x6oTaDopN0q7BVOyBEQzM8QAsE/
# DATA dyjpj3lwXV0aOz3cDdbT2++lHJiN2aA4RvAmNsdJWYtCMQ3qBRJOQ/eI/jCkw78tqgE/I3Wnhyg0yVwEOxitLv2swrTG/YHEb9fu
# DATA 7Ow2bt+6hSuCKnR98qreWlmklijuVlWOsMOo7TLIHPJKQGYt9DDsDxs3zcjYQkVvIc5Tj9Msr3nGmW0K/AFV/73klmSrHB0P222D
# DATA kViGNEaYAgoPYG7xpHma7LfBNaDdqiQbCKcicUxcIZYEDLZBc7/T7YxO6ZJYEhdltDeSoKZYBerBgM8iqMOoz5yikwm0ooFKoDX6
# DATA ulGhUfwEmWppDPoYYTRTg8WBJmHosBJ4NJqpLwb7Upe0VlMqgGgbsDYi7ZmnF+uCxwvnVSSuyg/Ts5uCfDBMP/HUYnPWR7m5xAZJ
# DATA Va94YuCw3W0yHBoVNzugIu8aoz5tKIlwt3EX4FD3P+xkjbm+DRMn6+AB7hWsLRib5UGFkiOBtLKKL18orZtbG7iWcl3O4xVM/hFf
# DATA gT1ZqHq4FuEuxl+abi0qIkYf8IEYe0fwhU/IGP0FKnFDxh7Ju6mu67R9b7IeDySDq4pYAWcJfl9rDtZbLf7r+rA/wELDzn0lVoOJ
# DATA tu6cxN65byII0ZEjrMtHQW8O7INGwgiryRk66DYHRSULqUs9Ep+d2uvaujrwOey7iRgdBS+IH5wlA0ajo1XVWePGE8IiQG/owOF+
# DATA wT/msMFf1lETifmUETOflIpquvrkfSVZGIXJZH5OYDeBU5nfRvncbejMnDPnTlGoxcnzC0adP0L5xFRQ1YDi4FcZ32Vwk8R605xr
# DATA chWv0qDs5RtzGlHlQNSYpfKJFgyVNoiBZ/0uLUwkOBCSrprsrzEkCz/56/wOIQIMLu9dXHBTjV/PNFRwFxcoGqswEyPc909irWTh
# DATA nFAaxfnxo2w0jHwQ0pnjpUzFFkSGRoEhTx6I2Hn+c8ajZz5KD2EGvnr+a4e1ordnLbHVDIU0fuYAedsXycpx+6GTwfdsKq7LDO0I
# DATA dISfw59FO6elILsc6pxNJc2kc3KVBjF/iFdGohydda7M5C27LdObLFIYVg5vIpcEK42qdbPLKQ3mdNRuLaWuH5r0MoRpUMsEQQxS
# DATA oATXnRqfO9hKFeUKOsadxiDORK4vnNAh9wL2L+6uCajGojayuXLMHqYfj/mVqVcfudc0zrw6HeRBS3rkjYyrHcA/Wvl7CeXl6yaF
# DATA pR9OUlj6w1KZuPlVTcW6IiFQU4dV9cRNmKnqUjz4oAvOwVuSh3W3OdzsHfYBhhXRH/m3cF5Ia4jKj7aSutqjJtiHCuBxWkogbgqy
# DATA F1jBNP0R4narjjRHqhtcQvWuofe4roVARdWsLANtQpUVcMdx1F3yEBDbAed1cRUJH5tRjy4li/I8doDCGPlKxz1JpHGMumi3MrwN
# DATA Zs3DdoLecpaSnr+o5PYcwpCgIwtmosDi2hiofZM3QTigcD6loJ9NEC00ivWZinVJr9Gj3hhSYX87DUvleY1nSuCHVCM5bXPIJxZi
# DATA HDkCIh1BOwPUleCV3izXSedoyJyOpQZUFR+M7LTx3FKBcgeZzDmwOg1cztqqJpCLJUJu4Bcry+p/3MeXX375KkxMQgEApGro9o8Q
# DATA NB6JhTOaAAomIp321N0dCAd91wHo8j50WnWjXVGVLYQ5um0uJJvkAA+DWrK8oKO+ZA9CBqMC/NXf/2lNhkeGnuH7lFe7o/Zozd/E
# DATA GATG0+Ld1tvoBwNXDv818Tjoy4VasuIFGVFmXroAYxUElkpXvBAjZYwJc6yJhu0afq2Esua+EtvGozZJZmmlkhJW7HCU5R0Xd3q4
# DATA UXvhrkYwWY3Ngd1Ii9EzjXrRyUgmFNd0/ZiRDPWEqUdM3MUpvdJE3IsxHKgn7A3XT7GxybLVJPM7Q8XqgoI0k9cDi80FXE1vpAR9
# DATA mN1utMyxDcyMxImf9js9TDKwSLqC2DRaH/rKCqb0OfoqM0RQCIoDKFJr2TJOzpTx4kURg60pjMffyZrpMFojikq0vsuJuJeRMER7
# DATA Ek7uQZ9why73X11ehmARQNLJOBwEAb0b/XtWstCZl1jiE2pPWoPKW74KNfd1+gHH7fF41OlWWp3sXmOcQQo3Xs3KIahLX3Mo9EJy
# DATA aS3v+DUzval2x+Fh5wBingDH9x4yWSVmnSBb8je0zfejqjg5lfk4wP1KvQpHQ98ESVZnEqREkKsvT9T+B19Mt/LvAYRyd5xhYQgR
# DATA hg3EKNmKhsdk2pK9byFlywFCZqtY2DF0ueSsLJ4F6cP9FJl7fzwajCO5yOwvDo4VARRw/a09odHhV1ZWSHOI4PMhMZKemu4ueaRn
# DATA gqx16fh+2+9CeKOlHG22ChAkrT8rJZdeeeXipfyoW+A3WMuskOPISj5QMzYajnuwGq2cSGKa0QoD4UND8XJmWsqU+CqnLNd3qOjj
# DATA OAIZ3s8qh9lp76Ag5dQk9voF16qIJ5i2Jg5OY1KPpS4RsnF4r/qb3BNIUYBuYYPUUrOguwNCbtNGgfthBV0V2Y2B/QfJWC3OhNtI
# DATA j1A5WIpaEPRuv93c3sDn7eHQf87ST+cEw3LAAtMELWplF54UVsATV4rf63S7VvFKq9mm2BpgW9ZzvPoKAAlEhaoiWh/uRPYHYf5T
# DATA 5EnpBQ2vFFwhfRh12JdAguOhx2WkS/xywQNj00Mt2Al/7LYrGKJuvW51mke9vtrqB7AsVmHVFG2ulUsXL6/5iRpK1JVMiY9tdQs8
# DATA cBNPOZX4LWo/FikHUCgFC/jEONoRrwRfu2v9cbfFsNFKxEJRGZgFynj2GBAykPm088a+BdI0+vkZUW6jJmMANdfsxGWclfFas4eX
# DATA DnXodE9xY1lnzxWTV81sEUkK0QLlOSZVgJrC25ImdMCJ7bYVt9mmB7xTxE0AfFGsUQpAt2q0axMrEvcB4PzYtEEukdjMoA9UEz/b
# DATA cijLfhWsIbGarNccZMd9e1MUQGmg+j/u2dtZ/SwRY8JCtRweZYeujjxVRhT95nvJesKhckIWJ8176r5IBybE6IFptUuiG0JVdNpE
# DATA RT8bK3EJsoa0OwOwFnN9B/3jNiIwytgqyW01d+BhnNxrtweZm1HPrDwlzFBsuD8GNMyKJEzX6CtqDgo2c+V3ECfMAxXlZB3yN6B7
# DATA OAlhStxVI2436ATgh4D2IX96m8t0ygGS0p1hZlG0krh5+sXNFsEPBT1L7LzMbPGFqbY10LfHvR7KQJHUQpTW7lNQz9GfCB6BqXVi
# DATA 2ryvHLU450OzUdExnRDp/D7OCwalQUxJDspKZqswanvrWjUOPwMMI3zIYrTxYnjJVlYz0tGL2Uyhes/Uc77Eo94cP5qmL7XU7ZE7
# DATA gb4FWL4XmKIJkh51erk71ZUzAFAVEwaxLlJROU45PWR1ZN11X6M9PdU4bzTbMPmskM2xIlN99bxcjvFZ/Qvie38yx/QZPU4wiXYa
# DATA aTVNLQZOt5ims88CGc3VwkMNFeKDcGxXvdvGdWIymbky91qU9VPdqOBCMe5AXiTFB5Pmfgbcrts+aiJ0haAVmsoMOeOBRqLVEkS9
# DATA wWGq/sRbGossWSXZgjxCSfYATdfILbsIMFjx71tTTn1thsKBkqSBMVkOPTivc20G/0qZTT6lfUFGfdsG9TS6uJLEjHD+/sKQB19K
# DATA ao9o/hSESqCsCr/R+Fv5Gjw/79Ge6CMXmYaGR93+fiFdTIsexYIujzNxVrqEmxZLlxSFXdPZdrWV002/W5w2kWxVEcA9yGH5CECx
# DATA CRYCklr+RcOwge3vcTivT2ObZopKUWs1YNAaHc4aIavg6Iaap2FE9a1tCrAUvbkD/n0uSQhFPH7+y+e/EFSqKCYd0BgSBfoGugzZ
# DATA mwAckHcXDxZLZmHq7fyA0mn3AJCtEOOxU7g3AjQ7bBq9ImaZ74s2DDZO/JDE7gL+JeEcflpFzzNX5xGNfOPsGZLp4C4FG4fRFS0k
# DATA RVCudPrjLC06j4eUFfk02FGEYkbY+lKzbUCn93EdMb2b09OE4dJwz9f4F3cZEgei5dVV2iGYmleW8NgipblLnsShRYtLaxO8UECV
# DATA 0ze6dxJi6gvhe4jxRZArlBFDsdcvyEnKTjYvgCxq93wKj8KuOpMBRAaxFIhBsKReLT0cNk85M4QsCg3/hPAx4ZP9ca/VBWSLuR19
# DATA 7EZfmk3ZiHxMM5Y7Yb/1Rv1ExkypfVlafSqZBygPsH0IQV4CNYGcDdgR4zAjsJd4y08e7Sfuwqqe6KwGiFLL2Wf9DsbpRzYgU4rF
# DATA ZtWmsDNEuuVI+p06VZHT2AaNs09jmRsref0fKM8uoMV5kJ+Gxha0319GuQBhkSEUxkpbuJ6guk2JYShwqGtxx9Y7g+NdMug/gGtd
# DATA P8sgZTLmlGsOyerQaz+wKqM7gOVClCBSbnaMEs2DY0i6ILdJsQw2e6cJq1bAh7ZiKWyolg4hCVnYViDZKtkAz29HbkCh3cgKwbFh
# DATA uXDYn7HPudWg47SBUEPktIF/sicoqCYAfJNRh6u+gQFDMFCJpaYfVX+c/i+r3Grcvn5r68aPk/fplwjm+sHWrTdv3bhx6z2XJEcx
# DATA 3qq1oqZJ96tAR2J9SSor+0sG7QWVbkNd5NXlWBB7OZ9RNbgofi1nd7aH62Tl+Si73jcnTU7ykd6WipP/74PfoZwhSc/sfCWJnXZe
# DATA MAglIhU1tW0RHulY1Tl88l3AKoRCVfD8u0Wc8FM6NBgkac8HhiZULLoUWkdg0UsRAa9LGOXIQh488JkWUetCLBunTC7hceViDmSV
# DATA ZotCNWmDmE1kWZ6xfSfJvJUiF3IbuQnoKb7XcM/qQn6rsS8Zf0pdCZEZ0OIrysIEjl/gaqMP3fOPJBcm0o+bM/bZ/5iSl9Dk0LSz
# DATA 6nrhbhidg1dKSWsFmYMW99IEvw4Ykt0NiRes12O1AuqrPpz+RH6PkJPnA0FsQ7+s6Y0RG9MTWqw7aQj1czP3NJ8XwNSR2IEMcF1B
# DATA wdykEvoi8RNCP3tyxYOdw4MI1ksugV7yQU44VGEjidU6zAB+iDv4Qxz3LwG7zTrZKolg3eEpqUp9gUnHPiB9jmCKPMpJeqgYeJaU
# DATA u80wRwI5bv5FFfwDgdLrPIkVzOKh039/6GQQxFAnBCBhh/jHSE6Un1Dc7Z49rYQNpkSLdjJw/gaTgXOlMLVIoYYyWaWjUR7CDA3P
# DATA /m+DIKsuZ643LaZBVFWGFVKMe1gbdPIJkaXvmauIM6xn2D5Stxm4HsQHTbsVqlBXx2py0IpuOvUwIe2wZI9KBhgxgKZE5vWwtcaZ
# DATA pLLEQNL4xq9HIhMMSEQpAqiicTTKkj2kMno40hm+KOy7JBHaJQqqLvEslviuBn9AbLQbxeAyN3Lpiacsx91h52hCo2NkvqSeonYt
# DATA G5DQxfIG2+RnJYkv5OpJTC7zeCpwx40WGbOvOpF8xr+HxMWUH5AEcNzgb27e2NiBGQ6EXSuvcZh/3cOCttNGy5AN0LGaDfdY0Y3C
# DATA OgGGNTjvFHDSi5yUg88yRNCdfuY8/2UJuM7PTYLmp3Y61jgjT1NDmYaGkTwpGlogcByDzwHl7gk2HLiDm1rUAHxdAcY2wdfWFUaM
# DATA geaFXnzPMIjNtIeorUW9BH3iXZlwqi5Iol7pCa2iqcIR6/IipdVeRx/nDxA3ypbdDFGgMJNTb9Fd5GJeO3icylmeuGmkNFipaUMH
# DATA EZjznMJJ674cNrt3+TJROKEwHf/mUhEcaXPPBOOreFo2TEjnD85mhzdznIqQgxy1Z/X493Q8I83/YwT+q8qCzFF7LpqYThcWzpg3
# DATA MUED8xKHTyBBExFaocY8ic/sdN7BRlwLzs6lIH5fHc0VvtTyri7uVS+uuifLzD0caIF4/aPbmReYKGLck3DfVjqrUosAgnGcY7nn
# DATA off4shKlx+qca6ubUeducmuIFuTWEsqutgz3F9Jg+WfFx4w//AFqp3BoCX70RDLDP3sayozSymthja8vkc2K4abKi0ssRgOdgiDt
# DATA yZbRbPTPnpZAG6V1d/QV5AOysrk/iWrlws6CIMTz8R9zyKOEksbUL5f4aYJnWtIR8nraH3HaBBAxuOSfdVSVg5Qcirm/ty4cT/gG
# DATA 81j1DbONJzBw7NBnfIXAm4iZJb4Qiolesohrm4+nvVNigoTSPv+53IXYtI5qQy2nWOmwWIYRXhGXXpAwjfRCqhyEaeJdi/7YQ/QF
# DATA PcK/K+vDozE0tY1vtCZI7dhao6Fk8EajaH0JV/RGkz8ppP1BeyhhUgfHfdCL1BjTB3M9pRhKlqGhgRPhUgpuhJUBGafM4jZ+Y/+t
# DATA c+pinEDKSD7NoaDeYbov+PuIcO+If6WIyZwdl2m3YFlMsGM9cLgSoMcEDxl1M3jO/UN/lPJ4oE5GimsGxKnOSMB+qDfZCBTn1iNB
# DATA 7SszpgFOQbfZs/wesEHWjnqPxZnK9pIYsjOOrolmFBoqcwfsycp5zZ2Pv5Rx0FtnMjAZhV4ug+KA9yDUG4oDQ5R0ymW2qRWv5BVg
# DATA E11+AXEbmtqMuQjaNOoJ2PltmNNlaiuCGDWls5TQN/c9LXX+eyYlAk+f2hfMmDylpiE7JUFk5vAoq4GmfOrYFG1N6xglvjWrkVvS
# DATA UjDp1Z/WsNkpHCtYS2f0FMlUfVaWNJdNNJXVUiTjBqbInN4k4pH1v34dAI5UPiHgA0N2eekm6tYQTZk5W2GQZV0BZr64MvU7BmUK
# DATA PqWsGdOaJd7oLkluW371CEI/nSlEmPOci+98Srttvl66YmrQ5ZXlmVsfTyqzyjpPPOpXGI9a10hvZ6/tuWYaMMPz33KKOG6Uvdu5
# DATA LP4DpTMDAwC/Kvpw1zlA+FA3Uomf2hFvEvgxcrOiwI7Fq+RToupqcMTo5NdVSqwnFKI7vXr/XKp6Ucly87Fr9MEy0VEpCGH2u7bn
# DATA wPpZmoB2r7nfRZUJZCGdD2cE0UwMpIaiovUbN1z8EcesJHkB8IKCKjvn9cDAqaDPs44CsJcagMhgyqi/Ju0M9z+KFuyEcDud0Ih0
# DATA ZhQ56eXhsxYAjGBSAxjdtFG2CCGG4/znm00weMdyJRiFobX82sTpRiLoRXTmjlWap4oiKB06lSLYxF4/nU6ctpBqppceNOBlm9zf
# DATA KwZ5YWp9viR5LmJnUIg8cBE+2BvqoKLv+UGxlMS6OOfUWkXE2Q86MH2YMenY8puK+OCfk2lMlbOt6xgXsx33pZg77PMsonuxsNLF
# DATA ZBnkJeUXkvAzC8fm8EjmmviDPynp7T4bZdvUJMut2QU/IFovzJhR73JkEya8aPALq9Pcy/gM5g1oeif8+5itUCexzunGeTZd5OLk
# DATA b2gxu+ftFnv/USIYRErg6uZbZnzCzWlvQQZaIpVhyVPVm01tPjPxDO6nvO5hJgTTEbx1FCPcgu8HDcM1zEfWjaDh7M/AIXja0ErJ
# DATA rBF4Lo7k5tnpDcYjBxkEnS6qxt4EQjq5F1YdVy98OYnyMor5MZxsCqtDL3cLXT6PzKZd4J2Ua1hqLgqaa8tObY5373zkalHqXNs0
# DATA V90Q7lvqgIO/i0WtbuBilKwtyP2aYdJU1c3iba5uyVoLSupMz8/FUrS2rDqNeqRUYdbRbCFeR9kocz20P80Ya6C/mt5DLt3g0tN6
# DATA GvIQ/MFfzuiWUSn6Ik8JIOgRaUaKxEjzvDPI6Q38PuuzEX/KySiUHyBPT+UNvqTkuINbW+lKHBAabhtq4FfivkcgaGsDitWsDY5Z
# DATA j8pxlmP5jGNRK3ankgjtXFWsMG1naiGTMM3pB+HEhnMLCoMZ9BIqGKq+SK/V6SHOeLxJp4vF83RANM1z9kHSQX3T3Zi5Vk5bM5dM
# DATA M885Lugzm0YJG5rM9zKlCDdE26U4AItM5ukDA9ybNZglsHVOMAlWdmpirdXfFXKg6YGwXli2wKAbyF8bDWuPcbRkMahTI6s7TkOD
# DATA JcrbMMW6awUszIOyCIGmn6MXG2bUCuOQdEckdyb+KAxKkvnDITb9mekqhf25qClXrPc6vOeVV3x2qMo4jlZO2vOQHbho9JoVz8it
# DATA qxGAZ5AIGaDC00XYMiVhnuu41Wks7KNkKnujnAvWeJyCeSwgkr8s8sJuxk0/WULtj2m017ffRSY3uhD2QycLgJ/k4eucUG4VGwBi
# DATA tQ3hnZQoYkY1c5zCV17sDBRjpSMwB5kNAuFjbrFENHbaTlFGqHUHm0Jc7rTDKnqp/UVnRQYftWmQzgE+qeYPs24qaTVQMXIKoRjz
# DATA CMraOYecD6LJhuQrIK0qJTw03D8sRVuw6qY/tl8VY+rRatIZqBkeAoJDZ6ClWq1O4Uz3dlR43iQh0uSC7/kf6JSlagd01IoFwA9L
# DATA iCAfwsbnxQD4woXaH/c5LzfcsikuwEJrcRKGmBqs+IH8qxza46szpdiFnPwrYrOoegqflEw7VYuHTsIlYxunjXxSjeVS4XLrgQRt
# DATA VTJbGl5YUO02kJQaDRx+owFE2mjwBDiBO+SQsWDB4YSAK4CLg3gp1WlCh+zxf3v+C7V5/0DO7znePTNdwbE5xV8wQRuIMxRMbsHZ
# DATA IDjMzmk2ap9sUF5EexCFd4EqsPel5J32Kf8F+Tv4z1s7/Acicfztzq2t6wi1g0+LdlDaJqpmMItEp3fQHbcE6QxTQ2TVpIeR9Tj+
# DATA ZNj+KQGLcNZ5iMsbd7sJNFD5lqevkjz7dxOy9/wTguVgmAQdOVBykTp+SSGPFl+mIAI3f8rzXwKi1LlW46/+1/yf2mX7XTg51Taq
# DATA DE6/lTYgKP7S2hr+q/7n/7t86eJF/Tc+X1lZXln7q2T5u5iAMTjYq+b/6n/P/7388suwkRR3JFOuhP5hqJ3koSGlWwcwA4ftbruZ
# DATA AcoRRZiuVFYrP1ytLCzsHoMPr13wZ2MloiejY3VOIJocB4ggBmjnCNLaHLe7A4xDOQb2ATiF6m1/fHS8gIX0hSLZvbZdJhDVw3YT
# DATA QIrQjAoxsqaPnL47OW7eb6vetcGzHKyWrYrqW3uI4bctdaTuw1EKQFu9vjZFH9iHBCK2PmwfjCnwH4CzQKIkEMMFANKddSQF/CPd
# DATA nTWeY3Uo2Z1OvyOO48TnHPw0+0/Y/69eemXF3/+ryxf/a/9/F/9Lx1mbBez0ysKC2gjZKDlLtoed7KR5rdvBCzf9SiYY0IDbupD+
# DATA zQAfLh1gmbR4hb/96YORXQzEkQftfTIxFHULO9dubWMikFuYdAqBXP++XdijJB4Z7pyqwIH7zqJZFTDflHAqOYA590fgE8/vsyo7
# DATA suYXAFFfVVOHHh6Oe4TMMWyPMzgdC8P+gyKnLJH8ev0HyV//NfxT4YwuTqy03RB6vaeqtNHjwGfthwM1Qesj/LQHMtX77yfOi9cx
# DATA 2951ENmLxeD77EBdCrKK4qtHCGtR4zmVJ++/78jkc31zIVmRUXFRlhAzN3IF57PodoprAtnxtIBfJ7XXo1Xh76Ka6cnCQhOi6xM9
# DATA 4+qaeL8Dd5ECUVcJU21I2jJZA9DavbT0d3vL5R82y4f1s8uTsv57bVJe0z8uqheXf9jcrztP5O+V1cn3lyqQGB0zQ8L8Qz4Ka+Ig
# DATA TUL/UJKmvURaLsg7kUJheixz91pycbUI8KGKMmDdGNtxs4cXdzmn6IBR37XUpuk0IYPKFQHTU3RDtDSdkuzy4gQHtypwGEto2irN
# DATA QQeTX2YVgLy60+v8bKzufckDOAeranvjeCfJhBtfWkput7OxahuTAiVNPLDLeCcTyK2SOGZAc0ijp3gIA8REByMCVQ+bXcBt6B/w
# DATA OXqYDDtHx6OsopdNd1iR2Ut6f8nToqwwTr4/lewEliAvSQ6Om72jduuKWCtRGlD0M6L7ih1wTW69NFRKodJVywm118wMqgXNmUKE
# DATA Uobpw2TmVg+JNmHNSons2qrZtPCfSq//oABRAyvLyWJy8dIr6r+XL63hOQeYQbg1qslepVKhDcQBO87a7III1e+2kqNhUw2H7mcH
# DATA /aEa+aAPiRMgZx+ArI2V2KTWAWGFNRhbRa0tiBRSW5+SDTaBepoHGpMNgWedRQYZrIN0OqKlxjGyGBRbUPl7LuZhzSOtRM7si9KC
# DATA aPcM5nxSwpU449mzJm8ycZaZmbU6kiogcRbOeMnUmTeEZasi4wXMky4ELa1vb1rxK52mWsybYHY47Pb7Q2SgRAqtdUxmAwDBmFBy
# DATA BRdTf6i6k8Ph30jOANCuCWrsKiBAtyeJIihVMGhJPg4bmhSTSclypgQmVFJ7utk96qsNe3yiRvL2DjhWIA1NYbJv9oebxJai7BYQ
# DATA QXstVDranDd4KBvqoNvsnGRXbGxj1S16ChChahXIeG+qME2d6e7DduAB1NUA1FY4AHwpVdXSYrKetDqHhwSdiop1hMhULOeeonjD
# DATA ViHTS6bYGOxFIeFKsriUTBzTD/dNkS79hRZmOsuBFuAFHwH8HvlmzT4HrBMQ99c3eSpZjTr7xfD/qTvHZv3C+aGuqj0avWPseXEE
# DATA n6LO0xMczlY9+ow2tU3CnTjjfEdqpQ6g+FihdGSYb6o1VkujmLRg/TaHR/cpl2MNoMFlfmheqHbAWVP7RokhZy5RRmayT5IlAHVj
# DATA ru0CybxvVKiqd0lF+kaFxN03KtmgC/e6Sgrwtskbb0C2oNdryauwxwPdsJJiByPIhwj0WNCyMSL3NAeDJdS90xCzJRGs+aPy4Cgt
# DATA Vqg320fFwlnUu1ANokfQZTtImFU9T+ogrNg5kEuQQKuarJZm1LNLaL83O10lG1cV62ksA0Zrp9Vte68u0qugvglwJUoYTyNXrRfy
# DATA ulWsZG2AEd1uDpuKpChYmpLNF2F6U4zSOwCe5rYEHBSyBylqV9JABMQAm7bvMwVea5tUhce4kFC+BHKdPW+UwNMBNtP5exJ0QEQC
# DATA UYTYW+KknA43RLHAz6YxYnuejDV+587VnWu3N7d3N29tNXZvvbOx1bhzZ/O6WxyyaJPFvhSgqU+p7vbGHdVlrNRoQisgURRI4lL7
# DATA yIOBJ6U9veXASOtTnFLZgLjNFHettGkq8/BSn30GjxCdDYzpOsL9nyxMC7SsfY5ZD03MeBD/Hlcf/+bZ79A4F0d+89FKKhj4IXP3
# DATA sDO6htbuZEUdS9ZIGQWMx8qM+PvoSYbbqUC3HdrhcLT3KX/RmSGBUowaSnJPnlxZ+A70Pw2z+79RVfB0/c/KK5fWfP3vxdVX/0v/
# DATA 813pf7dRjjJrL+6umEIC1Kxq3+KNIlCfOLesdkvdwDDPGJuDgFNeWpNfoAiSv/vZAoI8g1NPt7Mv9iNwJ5Aiw7b8BXZA/bfG+pcn
# DATA o/bJAO53VOF4qI6kfYq7klrBdwMO6wVdNaWW5RBu8q1Ct1Z0PSYN7mFrHmhBQRI0v7eu3rh17Z2iSZ0GCIItypvWgqBfzpdDydMs
# DATA AyRBLSPeIAAt03svC4uFNwaFKjuNzZ3bG28VbLBeB71XUhRC7o1YMgpjVSykm1vvrt/YvM6nCsTAu/g2HswlwRpJQyAWM1r22TJO
# DATA lTrA2+ppoTiJwgkvv/pqcVaPTE8aN+G0urrR2L69+e767oaDeY1HE0+oyTXyip9rRHvOLTge3bTy+F8n1Q0+YRKJFnZySFi+A/gW
# DATA fRZwKbr6g3AhZiyCgOUTuVYCP0HutJAxOd4QfKfc/bWzS253TUnpMQWnMZA7j0B+wyBWl9cuY268u3cxb4pdFkLx+sNW4aAI+rCL
# DATA 8Ih/Kil9ZfVVikGzvyrOMx3b61sbN0iaWqBU7OgiYmfVwTAx7gjcCJrjUT/iISGTSbgsPjgM3ih9bCc7zQXPZuFscZG9FCR2EUMb
# DATA 0O3BiVecBDvXVMdz/QJ5LuKzpTjP+g2Zq631d9c3b6xfdbYxz1tGoZd2q5xNfqc9GnEGed0+v9K5nv3aNAI4sgcbCk43J3nPmUUU
# DATA MHE3wrsMOy2MJU574DdYdOC9sQ1SiPq9bZ60yRsVcOlhV0MKYX+mpX+x9Bjp3nr5J83y3wNctfmzUSnXFf9ShDpJSbF3rknf2th9
# DATA 79btd3Im35BnkkJIb3VpSVKlm5RXAPfHJIreVvLD9mzTk8ELBPL+9q3b6J9LUeDa69J2MbLa139CegTsh72PKcwSo465j/IK61Ln
# DATA qapCTlXDGmQbqjcVvLnZ660qQ/wQDHLWbAaKAingHKhn8Ft0c/JbUALl98/GbUp5Aj8Oh80jFD50YXXk6lYRHZdaw5dw+CvesPwi
# DATA LMcd2Es1GYuO52Vqm1b327u72ztc8+2N/+PO5u2N66lz6mid7dCQdUmqVpx++/atqxvAxpSYRXoLyQ2rLhPr49Fxf8h30mqSXlUX
# DATA asVmEBbKv/69t/7uRmN9e5NOGnW9QE/oaCk9EwxF+B5AEWoKJsUU92Iv/VFZ3V4eNIetdgv+Qn+vVO2nyrL6v5X0Srzk9rCvuHU9
# DATA 0bMKtyVPawmkjgIatEdjb+7jiuINfR3+vkawRV2IWS7plG4ZaVAh8J0uaPhdBf8L5S6DVlXdyEU1xKo1VK5nba1fO2wD45gxRwwd
# DATA q9gnDxSArMlVuZri1VcRJeiim90qdYN+kBYODVvScKV/T+xJTD8U/NE8gA6QXgHUriDk1ZYBI2Hcu5fV9urwAtgwdbtAw8G3aJGR
# DATA 6vf7rVM1mfD5hRq+ZlPWlc5hAZ6+vraIqSvgP8UzZ9KuRPolFaueTagvlQHkGrw6BoVtBeTzAj5Xl+GJnmb0K6uhOxkltOXi6u2B
# DATA koOpomJl1Ce9FkpzSpgz00VOnu+/L5pa/P1SrZb20bKMljoqVNFL6pXWL6zPolNvDXFB71m3CvViIqjgydlBV+1BIT6kRxj7ZKGA
# DATA xF0o1l7XxCzG7hotG3L2peags0TG8CVtDC9eUQMvcP/lqfhwwghYNV2MDECDVVyRZtkAHraaZyq3vlXVZ7X14bB5Wulk+C/HtWfF
# DATA N8Swzv9W+F/1rer8S+5HUE8x1l27SfUZlNtbrr9BGvG5e7yUXsAYxPad25vXJIpAKmPtumI4xUJRq6zUuvj6KkuXRM6MFuqZxil+
# DATA BLBkWjsFpb4kn0UCnv6UnkY1U3g4lBJVBqHOINcCJXAhXZhpABGZbexHzBPj6b7UlPlqq9rKFeAy6L+EVwZVYL9d4BAGcw/gCwwf
# DATA OoqvUIxxSRysWCTKv0GFlwxuw75h4KNph+X2+lsbjc2b8N9QnqKs5Hz1r+y24WLfHJ5el5iQAkFVQF5JSYGGFIFDLtMV/LDfVQza
# DATA wUqX2CR6VeSYZ1GJQTiV6TALZqQCRSjrNHIe1GzxiXSkkfMXSzlq1JjIXuCVcDLGvIjgHqQ6QFtYpPL8uwhd/30pm/+0RH8qyHWb
# DATA pH+xNCpIXCZ1YR0xftoHmPkVQtnKDCmN/tS9+0VNmXtQZV3wxqA4/BdFJQ9tJHC5x5bBcbGHYoQ1EnWhUQs7LOiBmNtKcb7OM251
# DATA uUyQfOXyQN0+8KrTZsg+G4WLepEPHZE3B/hcLSgSWGomgbdcdC7EqVz7jNve5VY6zR39p+9FnrdlgerXr13b2NlpvKl2LIi3lM4N
# DATA 7+nEdkBPaPBPMOtCHvPhFhXLuk1nrfpe8eN2C3Ts9zGxPM8JaR+vJNlxc0jeHwmlnlAc6NRKlwncz/JYp+Q7cINYMEn14sBEnKzK
# DATA BSJir3glfMc2f1q1RpZG9r0qgAOeLEgWCajLdApYDmYQygoSOkXdsHFZ8VseN4EhCbBDtKL+6BiAtnPqcXPp8F2+lOBHJl2HPTEV
# DATA qAlwzuWS/5LOvyhz5aBNYC8YoYuwOc5SXCo1GWeTyYLO+Q4Dqnr5DvdS6yKMF4azxUVhxRJwb9+VOcWdJAnRn4KmYXGRlm8SuSxb
# DATA Uye+wW7FhEVxlqLDlOq6EHQKY1e/4Z9JKQnIpsQ0Y45K/96ontm95vcNSkY1ewuq81L0EDchdvfO1s6dbVAP6LtmqAmCDCw25JS8
# DATA JdavP8LAuJiyp2QgfuVTmyzCyCpKswJHA0nPNFLQ6qCmULY/omSaAxxgJR0tD3TI1jPpQ8lqUV7uQbyXtGwOK3rudOClmsd/5pzu
# DATA a7e23ryxeW03Ms327GJI25k620ag6OgqWqH0utR8Vb6x5r05GjWBewHeQkgZiJ+ccu1eYlNrHqQSngJ3ZPIy7OdkWsSa1TFwoC1A
# DATA zXjRU99mhb1F0yZMcrEY7GY9BIwL49KOwwhiuRB/qDv5k5DhF/BNSXwAOUSwuuByL02clAqHKdPiLWotIPMd2qsq+5fW2HKA3+2l
# DATA FOkASZI8iwIhg5P3ISrN+APiCfUcWZH6BG2W5APc2/WgOk61+J35/3P45zceBjTd/ru6uvbqmmf/XV37L///78z+u3PaO1B37x4Y
# DATA CyE4hTxtXM9jykQOe6hp56sgFzwDqo3yFQp8mCXk4ciy7vITzncoxtjDg96oKz8AnE99IT91WPA3akOGC/+LWIvf2fgxKCh37lxt
# DATA bN+5qhh94/qtm+ubW+nC+s7O5ltbNze2djHyAQURSDoxTP+u8EaV3D32kruj+oXiG8Hn+GKxVln8PmTjbldugkXvoNvMsuQ6bkc6
# DATA asypo+HG1bwQQ+z1hyfgjMQcK9fWx4evfQ0n1shWPvo6eT15ZWWV/CrZKQtye97N7t79wRvfu/twebl89+HK4d2Hrx7WU2ZhgRXP
# DATA 7npKA22wap2PR8+MwDzaskfQk9AYYQVI5yrl57QlMCoImQvgilJK1tYuRs0T5x8gfEkj1JVUSA9VSDutXjPV50mx0oUkkGyadm7n
# DATA TmQ8/1mA6pzwYEMcFtAK0Ed4bM/be1AJAE1gW2D1fQWtuWlFZ83G8alH8K8aWItyFIFLJOQbw/Sq5i80+Hk5hkBF3e0WvCSyascs
# DATA PxRv2Avvw19q36SAaTQcFfkqMdQ9sBwxg9oRaCNsYY/tfqol/hOtfpdWJvKm+MZc7b0A1XOmQLFV7VXLK3UhY0obJROJliukfnkn
# DATA 69IVVxVYlrVlWpZKKpcr+E1XQJOByBn/Eg98vfwTNdhK4x/K9Qvq0ZL/rLhI0w7Joc4/UhbgkErIKGI53IhLzYCCRhy5zU6miI3b
# DATA 3CySLFFSi2voEWAE8GSePqvb0fqbcGXffTuNbL9vwg2I9yggsGz1R28CVIu3VcG7hmeiGnNg1U4Oeizfqn9R4fwORsura5zo3H7b
# DATA AywlWI2VMD2qKXV+36HV1ejFbL71xTxuzVHT9xmyhnAhWSnamw2KF91hvhht8XpCfWoz/I0nEcHm6IL+kDxT3O0gvioVHfAMjPVe
# DATA OsNb7b3bQpTXbm+s786i2JKd3j1GX80LOfQVcUvLJTZNSl9vFQM1NsqSEENzcI/bLPEzGFtj40dquNbvrauBSvQqfNvpHW3e8rZo
# DATA Tv/ubF9f391oXL2z82NH0ymfnHba3RbzPV5te23FKwkxO8AlKSsgMU51TNKkaSWcN4k4CJabdCUIWG4K5WSayp/2rVu7jZvrW+tv
# DATA adWR1hdOSSVss2uTrDrg2eaVw7hNC06ZODbbeSgG5C/MRBzDdaTVQIAoq4yLnbVgs0dbwQQVM1iQSB0ryWs1ZB34sgi/Vi7liSde
# DATA XSygw+EdEVzogEZHpZXSyupl7ajkel5hs7EGrcZ4vHld59fY+csvSC+S/vnMLKtkEauSIBC+sMQCxLWbLBhkOKxrYvJIYxcp3xt2
# DATA 1hZ/kW3a1VMZ/xDQ4sgUxqJx3q2NiodCYFKxLSl3ep0YAs/0Obx26+b2rR1PbRvhLOHtLppJuxhV952zeSMOwXLuwWSBvg6PMXeK
# DATA zEv6veCbEjRxRvMeRC0vOCIkcd9miScOlYsZFL3keWFK8lgCcdwHe/VYU47XLNcTBQnzW9rTP9x6YVIIBQTd74IM0nZdEXou4Ld7
# DATA hKxd99S9+M7JZ45PQisPrak0UZcdIQ8cQYgyXytJ6OLqi/EDEYAMdiNzT55MpiKxFKo+4G2fNptWa+DO7WQe8pgvLCPXxPlH3bRR
# DATA 0mBgJBp30XPGU+oWnQOMK8lvRTDmuOCeus+BVwnfEmuKm60U91bqjvO5gMjtVeHyB56KL6tyL6cvW3T0s3EfRQMquGznPWnJYxxI
# DATA AUuWRGQl7Xqnqz+F8kqgreousKs0RCsus3oltdkKvHstwWtlAWuSayT8sNMRp99Li3MzFvdyaM8cdXOlqtqtRxQWUgyUUTip6hxE
# DATA Xdr3RPmEEY34rrZSxMm35tp20mKyklQWhVlkaDxdsAeGHGnPhEdX3V3fkEbFEFpiGs41SViZpOVyJB5VwQ4O+0cXFsm86bTOR5mp
# DATA r0L2yADydjrDpjslZHS2nOpjBtgp/NzyK3FNs2FLhwloX1EBDW1Wo24SMg9UZk99UTeeSnaKGed8l698JerCOY91JkVpjLSJqNdg
# DATA yfmojfpA1nFXON1BcSFOF5zA1iEPqzWqTsARdFIFUTAC4sR+Crpa0JgWvDaRPCpUBfED4aiC50h8YT896WQZ+vs4m+ksxcEqEY4H
# DATA rS4qFLqoHnHPjtsPpQHJk0jlO62J7ENjd+CwFcL0qGEIACNpwU2I7xp4cTK3BXNHDS/Nzl0lZ3dzWIG+kpnEIoRsVjsHo7D5Jw0i
# DATA 3PvWBFILgc7FFuawEstcnbVH/BCvSbIE6CQ1QMiT27IGk5i2hb7dC0vXoTrq0J5Zx/r8EuPb61tvbcQYu9lR0jj1mXJMec9C6nPE
# DATA 3ZN+C3DlWkb+f2F2Oo2VakHfEWcX8hxjpjDHF5Rqrc7K11FCminpnotJ+6LwNF4c48dyd8wRqfO7nn9S5o+lMugPCqp5P1QokJqj
# DATA 3n5hfXhQiBySW17nVfMdkKiS4Dv2KcALY2t8Msi0y1u7l4EzUTM76HRI8V3CrNe9UW1V8gvP4bbIDSAzh/nfT9PAQSF2kOIeeMm9
# DATA SZD0ogU9S1Rm+x80lrOMudTHHbQrG+9jUA7WFqw97XqvOJCZmpKaNvzx1wvTKEnzkRcaEPcb/tFhOOCSy0uj/gk6FVs1cOOCKvSJ
# DATA /BLdmMNGhbfpu7PznX/jl9LzHCw6RZYoFCXROesH1R0yljOjDAMDMzk6x68VinCaOx2helzNHT37eipdrpfSG4CKuLbcfxVgRyil
# DATA Q0YaoRzHGpOo6qTZ6xyCFMIprIyH4Z7TvWhWKsk4hA9N1m/OeYUJCW09SPTc8vx4TaYrTxKzKiraItNcjUwCgR17W9LHXLs3PkGw
# DATA 04IQjZm6updia4Qu0JbiI9SumwYK5tAtxhuKiKwW+cRMgLiyQEfWuOMb9DyyiNVoznzmtBGnrEKcJhjZm2sPNAoL02s3kzn7S14q
# DATA Savm6i3FiNHM2hv4J8QBBmso1DEEN/RMyc1c53mXilCZLM5VzZMVvJmfftCjLXfcI1X/wvkP9tjczr04xrhqMVV9DVh07gv/a0CC
# DATA O/5/J50jxvf7Rl0Ap/v/XVxZuXjJx39ZWV3+L/+/7+J/33tpaZwNl/Y7vSUImhicjo77vYsQJXZrAHnnE86MCqGjzZ6BywxwSR3o
# DATA SMDi9LwC2Z2uOTxCf7sF7RU4OCVvPNBkwM4VTzz5TYG8fw+3wa/tBhjAx0DKAkGSAS+/2X6BthfhwgtnpopC0bTaNKXqRDMx/sTp
# DATA us19xfZCJIRrDIBsVGk3sKQT82VbbakibTWuUMCS3AolT0sFvLLVQjbUpwS0IIBl8HbuaqxPzV14xqcSKmE+DWzJtg6a4/utIdYg
# DATA 6N8BIzluDhGPZFXjkeATG5JEPYAz0eQjkyutDNm94ebbAzR6g50Cx8l+w8Pxbbuz8Si47WJ+42JwmnOR6UZKVieG02C7Rcmdem0T
# DATA ZgOQ+kWTKSZsej5lVsTuc2Ap02qWWo27VNNZvHiwNf63FIu508b5GqvjMJjqjtqZNdiF9g2mKDg5Ek7T7HaUmJSZjeYHnWUcUYmB
# DATA ly8MlkKPdSythFN8re0sWljMMIS6avEfpWxDEu1g7jqLBRkNI4bQ4MXYCbFQXonrWzsAsmIVCfFwpmGxlGaP7G12iuW0ggZK9hz8
# DATA gb6q69u/qJYp5xo5rTtO0c6t5ptwQc4FPTnzQE8m3y3oyRyOhPSsYLpecp2VmahKxlUaTIJraxe9AdeM3zVO1eXlYr71RKcsyuEW
# DATA tH6U0G7UpxTEBfyvRVKgMLuvZgAYtbtbSxzGPR03pxR9j61QzzncoeYSkrtFYgGfSJSadUrQRI6l2hiHOOKilpw57anOYXQa7WsO
# DATA dpMwWw4+UC2+efvW1m5jY+u6PGMT733sJ+Rvn/g96nGTQZ+0jQxEuoYVJYj2hxdngwte0GHW5vl+AY4KaPNKMsOg/ILTT2rme8l1
# DATA ZBmCiZax71fzYNjPsgQzFOhgbx3CNuoj4PkB+lZikkau7KcAww+v5BOOtSUMAvWcgmD22yD4ki9ni/DRmyf7naNxf5xxXC5H0Wbs
# DATA yQxfiYbSngwIkMcXWN56VmN6pID3+OWYIfkLVix+warn3GuW9z/sH1LTHjkx+AcrxxnLoUo2E9OpyLrFrCw68NhseKFlPbtTNtZh
# DATA HJXAdb3Wo2Ae6o+EuU88JjRQf5tdppZLI1/pRoB1AWjW/Xzsrijr1hvTGSN7lgqcehZwysxilTWySRPefwPSADh+92q3jLsjowTM
# DATA 2gSsqLppjNQGvY7MaNyKnUkPcEHnEGw2MdWgI3X+DYJp66r6D3po8MMqK0MuVCWXmuU6JXw8PhhWOv2lbn8EftRLJlw4gINxnFys
# DATA SSBShrZmrOywrQSQDt+j3E4tUafKK9rzp+qOBTVp+nMtIoSddEKew9eT2dQHlc9/fqLbmPnh65nNEs+k+1H7BBzUYndYL4K8EIAP
# DATA CB6B3Bv1Ax04T4Hk0EZoHJY3sJDQAk8vELDvZgiq01YLD0VvlwHxi1oVanM8Htgbg0phNHOtq/hPq4kNV2VEU7pf1F7gBBUCwcZK
# DATA 7IaElyiN1CzcDfXT35PqUWFv0fqoToawGsWOHzQHkEWs0R+PBmN5OCLcqdrK5WXNNHmcNCxQhJoJsnKMcow/ib/OnQKatmxtQMOS
# DATA gylJB3iLZIxM+HOM8i8DoWSjPv1EOBQBQ0GIlwnYXRg6xfI2pcQz6PuFvaY0jRjvZAHxtJsZAfcX3IRHKeR3Gx8cJ9aNATJDPv/g
# DATA 2WPASUqeffX8o+cfYjpJyD75+PnHkBwyefZYUkumHtQ8uNDf6ylWkRx2mzhiRnD6EFP6stTBHwv0EwIzfYrN/sezpwDfRK14GSnD
# DATA tiBTCLjf9AH2pNdpt7BBCx4qefaZ+v4vmOfynwHEPKzjWrPHEKMAYiQyDne01WyfoHks5QcIZ2XjTz2J1ck8osmuTpaqB7//HHMg
# DATA f4AZOD8CtCs1M/HEn+pFZKKL3spqakS7LBAjZSgk+idDBlGAIkt6pa/DnZ4QkTwCQmM4Lht8SybgaV5Xf5XYpPPsUeonC5ULRZhu
# DATA tnCYPvsXSgWtpuPTZ4+ktcKZ3nKTIpPLZ4jwBR37BaaMfgTA+CXq1afJWbB9J1V4COOfVBI7H7Wkpn+s/nmMHwMyGGQ+ff6R64xr
# DATA NpdiFoZLoZMIMJwCYfSgisV2zQpiQUJIGc9ZKxYUAobeUIOH9Zlyzd7BsXtj5NmG1S3A9D7C9LGQYvuPs9HRcgjdUaHt+f4yA6dL
# DATA EvfsckfSg2HQGs6FG0BSrNuzoIuKDk1CG+FFoeiY6gL1mjv8/+7kv/2T5kBfayKYOjSkVSmR4TCaFe37MqtwonpP71T0WIlViSEa
# DATA UqAbPaw67iBdN04HAj3JdBDE5RBdWffS8iF/Ce+K9bpghbD1guKUGmQNZGgsVBbyIzLwNsgLUafD5lynsfNZNdZttwc1QuaGPw2K
# DATA lb1JjOEhlmUBIunMr4VcoGrTe95IJGtxmJJd+U2x4Jl4pTBEC3ZYsFlReuKyesVMSf2o6kh8Po1PDZ7C1Cm1kLkUF/KCbFxpiQiG
# DATA IdDSRSJJET7K5V6/jKqBAaYr0M8AIgz5EOZzpceH4JqIZxZ7iMAKg9jlGys8MW7B881zXLO90Bu86+Tu2d+qnfoH3px0SLq7NZLQ
# DATA ZB6BZcHGxEcuasi8WKFcB3Caumj4syDmHa9YsNhVWori4Q/2aiv6KvMIgBr/WXeK7nHK+bpcqZy36OqX7o87XRB+jLuf+fqccGCu
# DATA Bs8HBJsN0WYaJi21tOlV3HWU9lBzp1/R1zpRYZch25iqP3ILnCw47lu4kBaPKoaeWwhvCbppMZti5kGxnFbGowNc8kN4Ukh/8OMf
# DATA nPygtfuDt39w8wc7PyHftqjX1171MiuazuGahYgPiXiEgUMWRaHiXqN5ZJcKmj0SMKwg1uiclBIHWr8qmxCiku1gzmqiSW2yEHqE
# DATA YOdKugfFhWmOZNRvIn1xJpvvSzFXuN/SL+Z3orVxZko/tWbLbcNKnmdvvgfNrDEkeE5VoVGBCa6nlStBX8wbGKrgMVm6xZXLTbqg
# DATA lcs/G3cwfa6eb2GWflCTXa9hfKYDEcbuIGaam6Ndk8WcbY2KO14HYTQXtpQDMtg60btPIGLGp9xKImH6r93YWyUr5YGFCytCbrBL
# DATA 2dxv41uy1qBR9ZyX7c7YkLMhVqbdHQ8tM8cvModgXDcqU22e9SSCDxszgViivtRYXQjTy1Uc9OHIoEhZqcGHeeIsDUg1X5diTnIy
# DATA hNDUVmf6jVrj9TauriQCEhLQ8gxROdAV5QjCES2ZkXNNFs76TMFINrBMTTAPMILOqMGdFhZp0Q1NUSgaF2Mra+PzefOGlgNV6n5U
# DATA Diy5Ui92oxjconRF30t2Rv3BAGHIjgTqNaNHlWQ9Ee6Amao6meozp29F04267CaICiv+SmoGH6KN9frVSrC21Gmt0kLBstUWVql+
# DATA iJASwfldVJRRblGErs21UJG5R5+jSwvckEIua6s5rc9Dx84GKkMgqqZwabkYj4iOsH09tBdk/E4T3yiv988UmrGzML7puN3sYnj0
# DATA 9GPgbSxmP4Ei4yzuLzzfkUKWOu4A6EOJb6X05NRX2OfVn2cfQY9osqkAIFs+Xw44spFgsQ7kqrO9Zvl28q9adQn3DFZeIno9aBG+
# DATA BO0ZqZe+4kvMZ6g7myth4wydRBo3Bu6rrXsvtkyy9jW1N3sy6xjxNnX9ZOVJh91SFyPSRis+1MpbNG+Sfj/zvmbA/5//ApR5ia16
# DATA fPb584+TZ3+ESx0+YrD/6AyghqGwOg+ceUQ39BGqZf/87CtQB4Jm9gvQyX6F+uhPeQC/PtfK5Fz952Df8TO40W2eQooM0n5880oL
# DATA 5hyLiyK8myP6TY4MiQ1p4kpMoehgq5Xwb8fxJccRX6pgrFd97NIhO/+RamBv3agYT57/TzyxyJ2eNHFwdytoTKthhql5xBu4sj48
# DATA GgM728Y3BbEiqrHXGg11bDQaRetLsOE1mvxJIdVqdMLRB31DDcgkO+gz0n6mxBUxSaFCUOQIUiu2uy1SI1JcFIlPbPeEX2RWIyMW
# DATA q5YITAbtXWLIRhab6giiMtwB4KckXUHTLopNaADDDCfjYddWqUWHV8abOfZyyiSUyxiXAuF1p4N2TWfkQotdTb7Bf+CrzFzb4FfF
# DATA sv4pTqrnLk9mpm9wWkq2/4HDAbAQeVWp09yT7vClZV52HROQouWeEu8jr6klh9PS+3wIP6XlcmQpfI5zpiMQWRu/DA6u1uvX0PeV
# DATA q/fdM4KD07eA0UH5JVqAFNs/F5+NaoNpQIbb6IK5qmCQjKj3e2ZY9WlLy9kNbZ7mnDaiV7cLU9V0ocO/+SaHfzsadnyi7xL4S+va
# DATA tRbdUE9D7RKwn6tFa6BhodFACmg0gKk0GmnEt5PYTa4bok598U77dHbiC9DTtz141SH48aTP/h2P8v+/vW99buu67s1n/hXHcn0P
# DATA IAHgQ5ScQEEdioRlNhLJkpQdF0QwIHBIIgYBFAeUxEi8EzvNbTvJpNPO/XRn2k7vvXM/K06cyHbs/AvUf9S9Hvt59jk4ICk3yRXb
# DATA WMDBPvu59tprr8dvfUand06Li2XmA8PtncBjk2Sdboksj5wECPNWw4n+9ct/gkagMrJYwiH/OdQO7VcCQYnPuTeQeQib/hTf/RhN
# DATA ZSjDCZkARbpSIF77mDIZgTL6742k3NizF0C7aCzCNgHiFW6bNYh/IKu8QYqnlHOosPjnESH15/1nqfzxHn3l8O/Z8V+LC8vLywn8
# DATA 96Wbi6/jv/5r47+2Ncw7JuqIxoTAQdr9RPxXfEecnYKX7/cmkIpLOjmwMBrniwFLosbL7Ikt9k/wI8VfPCIMsy/+0ceHzWRGxj76
# DATA 4zo1Fr9WvanEbiXDec8U6kqWFzyL8z0ArOhNTsmAW7Ugn+0Y90K4txBWfjQEB3qInoZ71kfSp5082k2tZ2g4FEm7a7GokY2sOPlG
# DATA dWm5qXClO8MxIKhqGCAMQtcerZTWzYBDUPiqCWtTHErpmF7KBCA1M8IwrsF2/d76zu72h6GN72QiO1G9h/3hfiG8LrFdLc9k6RHi
# DATA aXiWxg2PAUuOtIPHZXuQbBKVTp4FzpM29x60v7q5vZZMyAw1ZULRqjVLOmKSu7xn6Qxo3Dk1DnikXWmkk7167plQr6RtRIQkMXdN
# DATA mtkiXZ1saDrobmKk3ozi5Ar8uP0oKnvtoQTXAQUBaJ+3mLeDDwV7gjxBTbRzw/ZvDwivC25aZ3nGqO8Tlxpo9k2Fc0MMen+LEFIG
# DATA 1itSMAQCQGXGRQSLmnmLbMIlM4qFYkmv+GEsTZre3dwE+MoPkah3bLcoqkPG7fJt2cYgwyO03S2jj7l2sR4eBORDSmaJYzRdMPeW
# DATA YSjiPho9aXckxcqkdcSGHUDwrI2giL7lOJchOzKf+3gbhxmeGW2n7xIbLNQo7aEO3fxUCOu07lh3Pckb2KYAe8mo3tpRiWZNl4KS
# DATA seHC4lmCf+HL3ugMwybR68aGccWyeaQYWGT8Q9EOUBgISo4p9cZtGc7syWPfLh9A0PDTxaXS7eWz0O+YCDXlZeGrmxu7K+sb9W3A
# DATA 7Kxv7G7aB4ki5FlsPNehA+TCL6aH1Iha/yDmY/iYsN30AsyncDwMBu0N5zML+tT3KlZkShOzhJScJaNiUd5AZmVxLSPeIsUIo0/H
# DATA GYJlPGEx4KVPE2poeGQcgUGoWl1mLEWuGB8vPJBRZQVy2wliSMYlNVR1TTOG07FrePQ1Uk1TzAH0bM479yh5HpFrmQoYD31oct4x
# DATA shNjisfznA/OBj1M2EkB/mExPz7zAgvqTeuxSPgNU2bKFCc22YNjncyhko3Gw6nxxGGjstB4RynRSBtkD7mO7fBQU6IVvU7WNFMp
# DATA 40ikEk21ryaONgXpgHl2AMgkzhp6qniNMq4DXOa0PYwrMhdqODB11EkIQszLwpJ3e1IoZmEl5k2ZUvDlTDFjTWlmyPceHifKLy4s
# DATA LBSL2fCJ2RO0+YE4Qvy5kn3evzlyExdzgrwTs2vYcmDTcjXkMF0hEKBD2JkrZVAVc1OTJefSHvtkmLm5+/V7K6skW1Ka851XfP7l
# DATA PQIlhgKbYzBQF8VUC0iBh5KSXU5nds1xWiVnQgIEn4xGeFme0om0ntJWSO2hDVg7taezhpsWFRbFYWQoa1rjSIh9cFeQnhtV6Y4o
# DATA fTqyPfCKSele4wUo97UpEAXpgf+Oa5syQWO0F1i78czMakt7nhhwCBmZ6nJEOCsFVsu0NRJmtJQoOLxZw8uYYRiGI1FaWrQcCDwu
# DATA KlNOQVr7ROogJ5Wq2A51KiYT5XgKqCMtjyrKPa4ue0F5xZeTi1xMrvpS4obCH2h3IkuYNzYKudSZLkfrXQPDKg34yTNFoqocGAM2
# DATA Oetvbzi98MPzaFkg6T80rXtqD1DLva6Jx6V/LeaLVPfy+HyucReISDc5qKOYxMPC3p8pMj7MsbMp83Rl2o0jcduY4aaR/5Zh+Xk3
# DATA kvloZrx9JG8eMKfGV4efUV4Buk34AbcvcpXQg9JaxnFh6uXCuXfmuFpc8lpxoStF3utEzqvE1V0jMi8HV3DHmP1+keKWqMljLudN
# DATA JP8txIMSYiJJ6CsH5r9wddPaz0z8KFhpmuAOrnlRN15V4hiqMqfIlWdXC2FRUtMru6xRLUg+i1yRTMXaJkNqSXDV3TelNa2ZyiX3
# DATA OTgjLJ9Idy3MP5olXiA1PVi/t72yu7650drZfLi9Wg+tQFvpPMXhRyOCuNFMXaytLk+P3PUyuf0I0mwQLJRltMTTDSrXenQuaZsF
# DATA +WGC0t+o5eDaKROA20mlf3uwvvNgZXf1vaQFEXTr3L7gy0jcdMBIjzBaHUKEzb/67oOSsfTQRi0ByQItyHsiegKy9UW2jTrQljbN
# DATA WFhHyYxu9JKZGj1FEFpCKQhXKY/QSrfaNZuepqw6KS9jncPAHUs1IeM4FqjsOqfuBkjcRkbk+nZ9LUzHLc1zaXKRcPLM2k59+/11
# DATA tQvfRIEiDsT5j2avMiFDScsXneYxxMGJKQj2x8PHMSqvRyeTuDKXkGwansCq676N00ykk/RpWKdnpr6ACd8VCFLOKqmFEQ9kzjwG
# DATA aG4JmRyIgLZEEmk1DcTDuGjqkeREttUZ9xq8n7CnLFjJ7wTZYm4AzhUwl5RU0nBFjEmuOTljXc9/AM2jL03zeOC+YlrnLIpceXB3
# DATA /d7DzYc7tCS7K9v36rvhbDkCjbHrRIELMhA+wbucXFsoOFAVIUYQVj0RhMoTQFuR+BHe/c6Uj8wJCMJCFOD2BifH+0qdgRZr5CMB
# DATA A6MxBhu0fkfBikhE8FE0BhyFGDGFEHEMNyUG2YHGSJmtweMIs20rkRx7wG3n1kr8iSgjLEvgVWgjjG2VsCsajTGTzxWvBjNkgrJV
# DATA hKwqAbUnnZFRClZtH/JlDg41bO+WWD5x/8a9BYsLPeJC0Cn+GDN0sGWYE42VdAHw/tKdzgCnhBZNCFDOLtKUgJ+9g4MI1TPrW7r2
# DATA Y4gHBbDOoI39rAQbeEIIcQ7ouD0w3BUhR2gEcIVeJuHIkM7+1tqXxPaeiopnaCDSG5imPpACqXW7YC7CZ6QjdBg/oodnTZVMig66
# DATA mNlD49VUHsYVPFU+j6wTUA6PzubTtSYisTDpXTIuLu2aPxWQSukApms9zq5GgH4z2BV8Ui0IbDBy8pF8VS4fnFePImS94/ioNwLE
# DATA 2gHBHcmLVpfxJxOWJd9pYc6q98zQBXwnR06sr6TxwJPhHcI82hBu3JoMkVoMUshpJtCb4gJIo3MpOJ7K9sPGnopr/VHJ3/0p6dMS
# DATA 2tfIT8t4Mhw7tkrVlzdmtC+5VTlytkYETwcZTfEsLBazeJ1XEGWGKam7CNmFL+BdR5TngdyfBozPD22YnWRmMzOrBFEwPTaDV+lR
# DATA gf6h7KjUKzNXsh0ylcefGCB7kE9D3ijy9jV9Ey8h7ulRSDFPOsIZrrvmGSUlkeRaZqEAuPc4F/2FgSaplYxtm9MKcilTGzd6ARAC
# DATA AplhCzhdpUynTtcyJD3Mk4dr8tKTuKQn0pRKaRaeJ7ZQMgqe/GoN11fj0pXSB3rF17AWw6RzRAlNsh5f3mlHvvQSNZzNEsYNjRRh
# DATA EasN18v1eLFnDAk38RKq1gwnz3TgB0ytqwvyY/AQkZmP7dHzmePt0fSTZ6o/SS4vEj3KkupQeDJoP2r3+u19woAJ0/TRV3KdTFdT
# DATA U78weSJ1MOTYcfFofzjsm/7p6kqSUR8FV1dpnI2quOA1Hf91rFV3U/+UVa32/0kl+zMPSKq6Rbe7p4xYo0CWlyTkCmBJcM5dPCKO
# DATA h4LfDQe9Dmbl5vIE2XUEgJaJQt9VVfhAtPzbZeatYvv527dDx7N/O0IDr/49uWGKWtoY69JASDawRuL9jJ0JtTlgKl5o/JQhWfUk
# DATA +2Hv+4xu2MAiWexYY4FKpI5M9erK2ofKR4hPVUuBraLdtc5aB8Br4Q5hGEx47ch4JLlZfyiu0/n11ZtbdbKG2GrrfHp2DUZh9Vj2
# DATA NqVHFE+dJZkAKIUtnDgSSdNuEDECqD0JXIGNYgXisEfxZnFhQQFidIb94dhTrWknNkguq6+qF4ylocA3PH2UCyZ1PsWkqJWczTdq
# DATA vOKmoCW5kqQqFXRhntKGqm8ibiyk6QMNnlxdBW6KRtsJhKIAumJvIsqxOhCQssCEGI1A44OZS6Wyb5p88EeLAWtDv2oMUx+qq2lU
# DATA 8Vy5ZOGpdhY2c4C2YGd9456Eb0XNvdL3maTI6q5NjGMEy1W33QcjEYufYBpERElcJw5riSuB1OpOjtoTQ68AS881YswoUAGpJA5B
# DATA FYZ6hsnjYVkShM7oKG0tbZkMB0miwriW3e4pQjWn6grgrrQqi5GoInrVIgS2GoBgit9CKa/SClhDolA2dSm3gwsNEYCOm0hluI+R
# DATA nz9NWLa5RdtVBt2bZC894YTWb1oVQNvGEZvMK7XYT7TRau4lVFwNg6d7A9rNmJ2X5yRxn6zeXFhc2BucmVnHj4fiUkrJlWiwDR5W
# DATA k7rySJD/sTV3uCFBcc8Jikxf2RJm62NXXqoAgGX4RAQda5iagIjLM0YOvkGYhTxhdq1I7lzvfDTpzGO5eU0gpKIDcqAhFs0UMYpq
# DATA 9GdwXaFh2Uuo4Y8xmFjwrppMAwyNy3XR7FbVKJf8SohMUwLvdCmccwENzAN2jLZOKScZg2yP/JaJzCKoIW5RuvOzopMli9+0LjOY
# DATA G6l9LL2hTMblyd6dwsHeW9lprdW36htr9Y1dyc+kNicHZHRahnrKTW9EDZb9aMf+LPUzYBWru+oMMMQu3HBTR6nicumlqhra3zof
# DATA o5Aj7KTdZ/AuOs4BulJw76G4c4oL3B32WJKnZCBmyPRXf9PO4BGwBBEcQ6YyUq7EcA0QjLw9CIxJxHNYK40Vn4BeN/EGeKCcphpG
# DATA HiJzHWDWoZpmajVSoIFawsEwnB1hWaMOZb+Wv/x0OObUN21AZhsRjs7d1JDcfGrAC8T2ksN/u9+iDrgRuUa3imTBUd+Vh6KTR0nV
# DATA qALtU0J8dXhvVnX6vvoUqKJqxubyPtNBuVDirOjbP2fsDwagpl0L1vq/HoE3lURyI/Jqdoy5BB2ok4IBruTHHHNge1N2RwYpS1hf
# DATA TBoaqgzeUYsdtVxgQbUOKlaDPL+67UmUIEJvd3z+ZCbf1XiMXGvCGJdYdK8WOzn9fD++njgKZ6yH0lfh9QFDxpMV8smdg+LNdGse
# DATA 6i/mMjxu1x9sirs7ahVWNzfeXd9+UHfAN+zNXXVcx2m/22e0/YajBD3wy0E+73DMVplAymhaW1nJr9K2yWkuMyEo3B6pl1H8loZw
# DATA +ZRzZx5GKX0k43rOpozOadZQTMcnNcpLllPMTKziTF/Cnzlla3hjZVXWWEtoAUxL5z4VCrl43FYPiqlxtVyjh5SSfYfstSBLIGGb
# DATA FG78DAahpJDb9M466D2yiDl5kOujir1O06BcjTOyZHAlE7iCwFIUwCdqueU5IPXFrN73wL5C0A4xUD83nwYH693LJguZZSqm7G9X
# DATA vpihFWsenXpc/OIU0cTThFHqZEAX7UTsBl1mbPQCDiRKGLy8kVSZo+SRcr4JtDo4Nup0nyt/JMZUxdbsyL2ZIRkmqm82oi/MpIvi
# DATA a4YSaKpXFhHQJXZzOp3Ko9/glNVE2i/FGKvybRsaKQ2MQ0vEOaVx22vKlcsViV4SAcz0+U+K6kW7HVY0mXD30utdVmPEAfgQdhTk
# DATA lVXGVFpoed10DaVsUWbUcdpalphTa4XyVjuO2XFUEgSDBeKFpyO+w0yL76jPQTzBjjQOxGIZdDZtpU7O8E9OxNQmPHJy+WUUZ11Y
# DATA 1zVbZttim6sV3JFvV8j478B0ZRbdhujv0A0FIcexwSNNJ9YRw79Y8wDPKCIM4q/i3o+j4C+D27du3bw9izd6feN9QxbSTqngydED
# DATA RXS/MA5/6AkDrxWM0IBy88ZeJft78S8o4UqWvg5iSSoPEohJymGzZjlsmsvkOGjahxdlTCO6lvnAVh/u7LZ2Ht7dWd1e38IQoe36
# DATA w506jw3UIVS1YBx7A2XRu1w4DNk9nRAYM56d45Ismd0uXtRSsXyUTO/8J2umyaFapGX056Lz2lWybOwMMaGBNM0LTOZEW7sTLRWG
# DATA id4NGC/KGC66kOhQO/b2dX3+KPj1clHU+W6ZKQFyKXOTROTgzjRkR5oN7kDTgaC0d4IVBpUTSWPKSMQdeaO+yhv5rx+u6wgnf0aw
# DATA 1C5BKuIcy55wfZIsRxyX0XjSYk7RYrYQJ+NqidhLl0iV59oi0uXEhHLb3SpnyZeTDK3BK9I0Et0o+7brCiXn4yFNxPtUGy6ZB3g9
# DATA mXLZ8x4v9drmBxuCbNfqrbv3N1e/X18TsyX4NIiaWCt4f4PhE784Vhl/Zkr9e1puyhSKSdKFTgonjyb3PU/RzAR0xMR1YWZjxfT0
# DATA azP5saEswYMnb1t6XHKHorpp5G/j4+EiGe/SavflPaR7GQ8KrX/5sjjlsUb9EVmgsnd3jk38KmwyF7exzGzNybLJvKKUf2/CSUL5
# DATA OuNIrKL40D+9g1cWIxhGxnLEEUQX06/Dfh/aC8gcXpn7k7dY+OwxV2cJu3rb1gVta1djCbOO/yu33CSP3uvXC09D15AjcZ6nnU7I
# DATA MpNCjb4wgGvBNHtQ/lSQF7ccXUArnmnneeVJsrwufdOyOpoufbNZX2a36lzG2JBb5Z5MWZehPE4GBCTV35a1x/4ty3zElSuzENaT
# DATA //U0U9dME55iIDPA0C9h+rmYEUSm4eNWnHzBmUntrsK6cdGEd68tIxmWkW86G2AqozOTARJdnYxt/Zgj6OvItRQMSiqVij7DwQPS
# DATA t8HVsRXc5oo6es5wmvZpvpM3EoQyUBo+cuiskUvF8MlpLZSwHOF03I2cYBuMquBDVJi7qjtjrqnngD5LDW+DoOSImQVGbM9DpT3o
# DATA HA3H010Q19a366uAv4AeEPUHW7sf6ijAngxun0ETb9kUlFQnARGMwQiRH+HNigakKLZziT6jph9cTlWEhyId5UGaL5Bje/MHRqVE
# DATA kkZwtoy09Ye92n2paZ9sOVK3vrSBbj5YWU8o2tDqmh9/lPTAvf6E7kl9iPytiQoqjIYsL568iqiTlysqo1TRHmQsEcNmJm9h5CWN
# DATA 3enHV92LzJWT2AFi5f5KUEer/oP1nd2dMLEVSXXDrCZd9ULsz9K79A6s4Sep3PRXXdERIeOIeWLQHneOeo8ivtlyXeg0GgwHneiO
# DATA zO5uqNPeDE4GGPYf6RZ7kPOkPeAogghMAZT2ZH8M2167qHJ7aSoZ1bEZHYSNqnPpaBJsITvE33kCbM8EPvBUc1FcKBdnAc8JOWnz
# DATA 8gp/Yrky6fLZQy8RmFRr+JExE/rlzpF4sYDvFTMQrK1EZKIIHx2ir6N+uxN5QaprR5PJqDqvYcqrNxcoUMtXGJZZboPKWIPc+nRI
# DATA Sftqyey3Bafy1I4+NWLrquAXJGg+LoNX4Sii0EIhpqL6pBo0LGcG1VTRUbyHI0S1EeUPwsWltysL4v8Wq0/h6RkGeLiaemI68MZT
# DATA B+qAxK3yeNhPc45waxoeHlJY7tOwO+5hrl8ysZWlDmg4kvrDp+Fx+0kZDMdQaHHhmHSQT8o83vBmeOY2QBGTnaOo8xHWMBFzB0MN
# DATA Vx+soXQpqA55Kv73IAIcgGu87noyYBbm0VQoZOV5qvNasSK4z6Awrv2lDJbGfKPjyvCjdxaqi8VipYOwAoWiU0L8xHH/okIh0UDX
# DATA byGT57Bc/UDwNuBS4sHiEoVSjietUTTuDcEPLFxaiMWQ0w5XmPGGXCxxjZsKSwFXO/po21efyhDthAsMLUtynSm2W3eNjwO3b/xY
# DATA uvozgIDKS22pTch6ar3xVL0henGm3oIuQe4XWCztLcdD4Ap011zZIk1Za20kHRUkxeyLRU0VEwM0zMMybspiAvSwuiSkk1FvEIU5
# DATA +IFkKzgx9zbX6ncf3oPCx2LmenBlm3RGtYUQJ1CygvDbC9VvI69bXr5ZFf8zPs6fdEdIwDKUy8dq9AyhM1PVF1JVHQ+VOFmG+M3q
# DATA PPxXP6NJqc6zCthyu6bpkl2gSdI1SYow68FnZ9PYMclRZSlHiXuCq9l/NX5jDuOyHWOriAJSSBKJgy7guq8n18UzvKKFtUAfzi6B
# DATA L5PqymYq0zL1oKkq/xzK0+50ZYK8l9lqTa8OKrc57MwNySFITBsLjWGKMSl4lQ/5cYxoODIbbWVlfHgCu3ULfylIzDbQFbRaYvVa
# DATA raLxZkXQd6vNrxRCFZoNNEtwwbVGqFTpZY1fTOgi6JceEgbNhO87rMTQppeTcaRYcvlk3Odf+CJQBkRtPLxAolLHtnIExFuKoBfG
# DATA PcBLZJmjLZF5ncRRGfiO/kY1kVjkBuvLU9AHNtDMmJlyGchXlIbw0doWar+k54YhWJre4bbnS4jCPELepWaKtabIng89YjnW3rGd
# DATA P5OqeoJ1skGFBke2ExOlwD9AkEC1zywkrkdrPpbFf6B0rKGSMLW9jQLgpRQXHgHdrbonx6O44EXGxnpJuYEfDSBu/G7yyWgQC/Jq
# DATA teNOr8fYyCzG97N6GIWWzhft7ViY9GtiBdCHST8nj1KM+r2ke44Jl2rar2qB04OSregCJ0JUWrn9Kaq1UK86xjs99RLhfNoU81UB
# DATA PyvjHL2U6u3nGdSUtcBtnUEdErlK9fYiC+7yjIz2XNRhd5YMVRvNN+tFLtArg21ldMgAunX7Ag8v3rDmkCbyht91Oucs8DeDMDP7
# DATA Ibm7O3qptp6tVWPToP7V7YrhhKu0WMZEgrIjxKuqh/5ZPocioW6cAvQNjXj2cOWhaKT8ZV1/YmHR27CbdyNmN6sP4Koj+oLVIrvp
# DATA 2RnRtK5YJ34C/V158aZ0q5i+T55+FJ2yAxEGY1khY97Dtnh2gb2jj+ck4k/CJJEchZpOaZ1oLDSzGzREgLRrpUHu0uH7KlZLi1/u
# DATA UDUcT9o6yZpNI7mEhsomOQ0WJURd0bEWWoxaLexSqwX7sNXiHsEax73DwQkiAhbgY7tf2Vm/t1vfflAK9Pf3Hm6ZGdLpOf1ToApK
# DATA AecQud4SN7FTrWZJur6Q7D13Yb9PEhd2TiE/fR1a0V6coFwZPopG4+ig9yTD9dPGmLXyyyo0vlwZHT3dE1fhGFN5uzDF6VKN6NH5
# DATA vwTnf3j5k/PPzn97/pX47+fBy49ffiIePBdfX7z8H+efBfD85Sei2PnX5785/+L8y5e/fPn3oij8/k/B+Rfwy3N8+cvzF5Xg/P+I
# DATA Ms9FdS9efgJvPz//DdT/8mOrXAD/Dw2/OP/0/Lko+dXLn0PjfyeKfH7+ZbCytV4WT78WdUFLz+9Av3768h+hIvH8U/H5l+Lbc9ED
# DATA p8PPscOi/vPfnf8eX8YKKu4tm9S3K6ur9Z2d1rsr6/d5Qv5d1PW16NRn4t8voLZc4+ZG/4Avfy7KU6OBWd3LX+CMvLe7u7VT1vNS
# DATA CkTxr3EUPxVVfsWffyGe02sfiwZ/6Z+95zB7gTlRznS8/LkcwB/E149FKViifxUTR8Wgs1+o7ltz9vLniTnDiJPWu2KuWg8gKOUu
# DATA 2IrW31/ZrePU/d+UxcMBin7/Fr7KZf8KZkA8BMp7DuMlAwsODjqBj4xBLtxeWBBd/9+yWjnj+P256LgYcaLD0hapO44ddUj06/Nf
# DATA vfy5WFuiwVnIMsDu4aThZP6ee/UrHO9n4uPi7eD7vbupHdNpMT39Sts6vxIffgf9/Kko96KEv2LzXwJhvpDfn/M0IgFWA1Btx9V5
# DATA djeMnrSPR310BEx0DimUu2Yxi/9JLYheCVL9NRCP3TNs7DMxmz/Fhj8WhbEusW786pe8XF++/AVQulsB0ugfcCS/OP+dqOZznIn2
# DATA yWRo9vIsnSlLNojeU5pDC/nh/N9EzbBMzwWXeJFgHJ6dwov5O6RA2In/kLGtxcd/Ds5/K9bkJ0jbX+JKfCFKfSXI58X5r/EXavuX
# DATA wM5EXV/g8koqE1zt56JK0QX4VfwmiPKTChwa3/oz/pv0hShx+mrbWBB/t5eX8V/x5/y7tLS8eFs+4+dvLy7d/law8E1MwAlosEST
# DATA 3/r/8+/atWur0XhCobhRwG4+IMxyXlFtPiYVXfQ42Ja2LOkqRYEGGLTbO8ZroVSqyu9UEanE5DO4hsjPw3gOI3HAKNLv7Qf8GGR0
# DATA WWSsKtOSmXpyqj4KTjQCMX2OKmQhU1ZIV9KSZRpq0cO4FODFgHXFQqIexHG/cB3k6xKCXHJY5kG714frD/O6WigO9M+A1QiW8RNk
# DATA K5KlbNWFPA0MTLCuFy//jpkWcDxmOSzWwJmL/PdrKCgOGJJ8LFHoBfIs0cQnUJUo9QWekM9DF5nckFvF4AuNkEcCnnwwFkjkB6mx
# DATA ajAkcedpjyYwmuHJBB6SzU6hGt8yHEcQR5rU651hNyuLmDNDHiTlCmEcSXdATYGtUbs3LhwN4wnDOeifSpQ8xly6uBYqjzryX5Jv
# DATA stlCvA3eXb1HFGODdz6jyiJrPUTFBmI6XousV+0Ya3AD6yBenjjgRgRchd/DvcHeeG8hnKrpJLkf5QcgEj7ppJgmTuYAZSKQwUAq
# DATA ZSlMHOEodr94+TMgBpDTPsVXBJUk8wyPDCQBGFUyBHxxYWk5uI7/TO3wfyRpj09YpmDVeTjJZefF2MpSekOB6IUpoYmj+x9ARgse
# DATA 9O6qVG/b4uKNvkRBPHTZESx99Lcn4GAC7tXghHoSM2apRLEFEwLQUEURQIsIXawxfgI/SPGUbvj7p6A3L6qFtp5SOAjzgfDJrYXv
# DATA oE1rMARPAfiE3g3RAC0T3769jC4qyChUs3JUm6KWnZ37Ml4jDrqYsQgxLXsxxqSDt82EcdPviG0C2haxkIMfR+OhRLWn8AwuTztW
# DATA JSzaD7vDKKb4dnPbhNKVcOpIYO+Ib3rz2WPJRhfx/SU5pZeMQPD6DbBFoCJHxP017AWgLboYPc92fryK+hUfgHnAXe45KwoWF9Jz
# DATA hiYF6zcZ9mqbTa5yrS6/TjOslX2VhOsECMp0XYMb46dwShkzKriBePIcbxLPEyJ+Dk75jfSCEwqRLBH3iQRAfAC7miU/8Hc6In8s
# DATA 7URvBrBOMgw/DvaHk6Nge2cFN2x9dW1n5Y44oDhFyjE42eGvx8PuSb+HmCkGuxqd7Pd7HUC0TRCB+EmwMYsefPyGmZmnppF8Xfwk
# DATA 6WnUhlQXZEWN46qsU/JL7bJrdO6NmtNI5q7898SVXp8bcByIZfhayD6foLDziVQxod7LJ/S8/Kn0ZASrp3ei9G5BA3WXjO3OXFW6
# DATA EQgyhUQqG1FXBYvBIrcmw1YsCg66cQEblMmhapQcarEJqQclYVQGw8cFSRuVk0mnWIFvohfHo8IU3oXy3hcBqq8+p1ngm7JP8IMr
# DATA 7z/Cpfcr0hI+f/n3eLMX1347C47nDFRhGKPT6QKXYUBKk730sXoxMY6XMwKLkMSQcMIi5kOoI1Z4OEbh3Ag+5/+Lpg5Fpl9jp2JH
# DATA 9kKOomQvQ8hSGhMxwR8LGv4SlQufh4mue7xqfX60xgsJT1qYM6DrQgg5kjpH4sSpjKJjMsP0HkHCRvjKAkq/q/MRmV4UWIthhKA8
# DATA hLLVefjZgt6YKU/t+f9DndFneLh+Zgl6IADa8qwpErpzKl7/PV5u1KyinGjIs2KAEiF7ZMln1Otk3K3H+mDjw4EAKSbox2LP4yQR
# DATA Z3DG3J4Mj3sdbsudOFWPZVJgK0L+ZsXQ3MDNrFUyEOuwrjgl7mwkQ8E4i5FNeunBmIlhj5xxunFcdmF07ZHlZTIcmfiSUOUgKQ5f
# DATA 0MU+AbXhCPZ4DePXyPkcYWgPek9qYWXSj8uhZzURLncYVw66wPkLZiPh4/0Q7TOCpUftYzdrEjxj+19iYEaJg/5JfOQE0kF78emg
# DATA U5BlxBgGw4IRDz2MlVc7LTqGidO+hFi/vjEE5G4oMaauFfNoBZsWF46jydGwW2IkAQeBzUxRTQWs+CyZidq4EcKT5KXw9s1vL3t+
# DATA Bn4W/LdgYbjw9ttZPHZtY8fsc1XwAnGU/1bZDIyrH3DT9Y11xTgCVLVLkwOyhdviTuVgTpmqpAphlbDHnoaUkhha5qvEOuCkHxwW
# DATA wkZ3EDf3BuENHKbh5CDXK+pjRmJIgqC8P8U7ytUtGh/3JhS8XngKv7Q6/eFJ96DfBsv4qEfG4xBD7mndyJivCnHCF3r3sDOk1/gt
# DATA tXQpr8oUANRPSjjgdiI65iQ3ns6BGGgkIjBHY1Sr5CGjJZD8VGkj2fIj9OoQMwosjr+M+YvK30CVVChh+5RwqPN/AeJQ9k+iInFc
# DATA vPwZCfBfor0Uz59fsR3hK77QCRosK/XZczIIQpHQQQYz4d7kWBngJrdI8a9I0p+d/040Boafj7Ud66d44BmbwWqf2d1FgnAstku1
# DATA QZBr5UfD3qBwED796AzM0I/Az508OkrW9MvsDhWE1cPcq8xrwGfbkNqQgkqBZDs5BEGfEs6mYjAm2T6E2IoRQmkkhhyHBjRg5cZe
# DATA uXnje/pJxQQPbD5dKkHiSKxtuviSprKlTaN5+pHgDOgmHHKIAfU2vIH/3ggxmgCpXg7ETBOKq92PNTqkfebqyhPF5cf5R+3xfL+3
# DATA r1PBzovH85ZcmFbIkBVlnhjFRanpG3KlbmAIRXhDvHYjTEZS2IFYRt4ZV9thjE3UHJM6Or/2xHG1Cm7UkKXcAC5G1I3VFvN2tzw1
# DATA cY7hC2TeNcwwE+ldTnsEbnNjmepFbASsXado85CwzqPR7hxH5QYRb7OhEC8BbIcrnM5rHKIVXAc9B34P98RPkNn93mJ23CcSC6iz
# DATA yQhtrdHGEpka7Rk2k+KBaMT9DV5RXwQrqw/qSt0bo+1YHGajqCMuiJDIHnUmT6LODiY1+duTIbgJBqAz6aLLYGdCupn4KOr35e+k
# DATA PxGCYHtEpxgOREcZ7u0BDe2Jv9CIPbxGD6+Zz96CZ2+9xT006IOSE3GH+d+wOC9p4UYow/DsBJlh4+GgNxGyxpoRULAd2Ya03fs7
# DATA 5h15b7ByIGSZGsdMlYcgIkbsqBZwwDG3tjf4oA2nhbcs8iarMxzZIvqzC/74QkiKj4ai3MMH7fij2oKQ7vYGavZr1wSjozm9EV7b
# DATA AyURH1S3l5cvMEG4eXJNj5wYY1LEvhKT1u7DmBq7UJN4a3Ow2hZyeLc9rl0vi/8LFm6WFm9VFxaqwKesoW8LwhLn5o+j7lrUb5/u
# DATA RJ3azdtQaguU8jFcBmoTccZi/etk2WzS7Ebdu6c17HysJtaZC0+EyYWCS3LFlUg0BgoIGaFKz5QzFFQAhjEAQgip9yZHKtpxLCVZ
# DATA w+WzYUREmFpp8ZX1hpZLKJ3qGA9Cmb6saIuYwfZU8BV8xEGbuQ5GyWCKG8oal/xRyrQcfliTmXWTJS3OfzLGSXHfAqXVyB+h4Xh1
# DATA qgk3vIFdbVe7Iq3L7Yql72pXUOPVtmOhoU+mK2nC63d0avkeS1Xd9GZMj+/Z2jRIyGjauIG2K1IYFDXzLbRdMUVof8VOgCcJmuZI
# DATA WNQ067/wMIi8q1ZiVpg3dWiLj3QS+vxtGY7RgDYmT+EKARMm74opJMP7zpZE3wy+H0UjtFRKBKBAHsV444aczoNO/wTQrgPwzNgf
# DATA TsI46EM8P19I4koyS3YjnPRlLCZvy6oxmdZupphJHpRpDK9ooaDIW94qC/vSLGOnS6SDgKfJgnH0K5tI0DWS8E76sSefN8sv4KdE
# DATA kGfGSFB2sX6FPvtQkrwyC5kXvn75M7o+vvxncszACyYa5+GCKU5mJwUMeXOLJhtWZ5rFO+ZP0JNmDm/sKU7Sfi9lOLoTDsuWYuRC
# DATA Tsxgff8RQX5gAk9WkZFIJl5+1IPrisEPdMo5ieERBf3hYcXxfA/P/81wbBEzWhUXKMM9EEHtdO7JyE2Mzrrd0HSJYb8/dLFZ31gv
# DATA aYcK8f9sbofAVxhIzUille67uPjn7emX4v528Lh1eNIed1+hF2C2/9/i0q3bS7b/3+LCzcWF1/5/35D/324Etu32uNcHyIQYDC2Q
# DATA N5KRfB6++4GQYjGbKh9HJdK/9waUdBQsEWNKMHya5QJ40BlM+jP4+8VHJ5OeeoHCTmbzAOTvgP4jFVzosEOBUlP85sjtz+8dJw5/
# DATA x1Fu+Va210U0eFR7ev36MK5wgKA4X++vtlbuo+f5qqHwnepnt00ejcY5Bj5ivyGr5suP4batAwleSJsbRjWI//4TPBSviGW9E3j4
# DATA 6YEQuh4D0tP5p+Ajg275P335y3CqD5+Ys5ZxHMp8EBLE76iHZkpjkrfQdmPhU9lYuWy9hjcrj9uCQcvJvrW8kAeSkt6cgLJ6AD0q
# DATA pkPyexpZXEgA1Rud36VS9ScjG+9NV/ZRr993oRh1K1nmNNuQRrdMrWCSdpxU7XSSPrL102CKRevrJ6hDB3L4UsXZCDLRFu5LWPLE
# DATA MeO15IFRjczfZv044nzWvj8vY9842h8OJy3JTgti2kqsIutMxPVIbDIh0Qwh/XuNVS4J1W8Z5lrWABLQyaA3qaUqaBIvIsKqVmVp
# DATA yqN2r4T2vrD8MHJSILefy73iuD3+CDXr9BKBpxDmRMiax13EmxPTXUYHrx8N98UGF4MGdLvR8LF4qT+MY5i+fu+jSCoqxV1sMm4P
# DATA 4h4ce3ixdDWPYhYvr3ZkTgBLV0pTkeFC4SZ0Tm/RDTFrUocI/VGqQitnO2R66PYoK+fkqI5+FDWZIINmsEhpjfYGqXpDu0ZTcwiw
# DATA bDwropJrAedMFWdhe78fGVrGrWE8qc2fxOP5/d5gfnwclA+CRDesZtJUdAisVD6BC5ChpjO0legRb2yokFJoC7KHq75UiSVKUZdD
# DATA 2ksVzHNtrRP1EhIvoNAkW5X+PHyUUaxslYlzCitAoTzqygOyFFDsr+gahyFEYvrEPZy/PT7qdY5qJDNV8EtJSmVm4ijxOmHzYfYh
# DATA kob4KMXaxI/yE8AY2mc6Ie0ePBaFsIVCKL7YZgbxIHGCc4X2Uc8OzTWaa+RzEnCmmfTHwx8q6MoXw3FAqTxOYsgrTVNuWSgy2uV+
# DATA ZtToqc/H2/7DJ1Kx49PXHNT7G/aREjztjpSejai2P1BI7flXPIfSFqKmlx+UxRxZRQRRuoXEI3slZGWsIVGlpgyLAwUdri0dpT/F
# DATA YZFoqR6C46Ybn0tzoRw/kgPp9uL2+LgF/Bc8KJhUkejsM7DoOwQZ9FlsxgA1bZ6jz4v+yax/RfAYWb9MJQayBejcQIUhheBKsBKA
# DATA HCc4mMQZHQNuKfrxgqqiH/TYAd9gGV0XNLYz7PcZp6hcxtMY+0a8vVwW7IdorobIiprRid/whIHEHCNBPae1lU7nZNzuoO1iEbRl
# DATA tHF0NmrJqZpFb/IJudOMF2AhjDem7Z+EbGNoNLGz4t53LObr8VE0YLh2Dh5r9/qG5tLfGbv3pkk1g0vk3MVpJK+3LbqFsxfyT8Tm
# DATA fQFRpJ/atH3+2Z2A/JPQp/lzaYFNFWGQH/AP8uHXUAWYScEpGj0gLThXtTMKRXu+zCOJIbhwDwDQm7LpvHKos5yAXt53mZZCuEOI
# DATA C3ZN9Wi7DkDRa/XtXBhaXA0NKa7w18ZitakgneSz6mIT1K6AUx82SY9o/m6yTFkrs0wKFuNqFpqO2Xya6Kud3p6f/wod3IGKkpbx
# DATA L5SWv5hw4wvnxbI7Ajr4EFT6w85HiXsZOMIjEsiAb5Di22Zrdbu+shs8oy/bax9sy88bm+9u3r+/+YElqRD+vRAbxycjQJSRMB8H
# DATA Y7i9OI6tiDbvYIisb+yaECLZkCJJWBEJpK/faK3f23CVtt+PTveHQjxalz0tFLORTWbqlR/oxJgVNnxPv5bCMhlzBgowcdsUDwvw
# DATA nxI/AXySVv0HGZrphCyocb0ub2FITGYG5kqohBgUcMT/MJz1Tjr/+xpBBV7+DCNuiFf6tVGhbfYwt5Nh+JjNnpGBGeM3OZitKqOD
# DATA abvAYN5/RLXaz1N1aJ4BSoki/GOzMVCql3L7EFwRX5EJIFP/v7hw6/byTVf///bC6/j/b+TvzTfUxRsyUI9OJ0fDwc25a9eu3efU
# DATA 3ZBLh6hEOqlVYJ9wqm9K4405AhBVDTIDjIcnh0coESqpObdh4Kgdg0FAfT1ud8hSAPgpqMeAI4d+BL0vAJxsQ0xwPHlPsMb+VcAL
# DATA CBFSfQZXqwk1m258AJ5hWRuwsZNxX7RVGVPvZJvc2RL8DAfHnOoA8R6jFe3wgBC/3l8YNXyOslOjQZ3t9S109ReSnJFlYG71/jrc
# DATA mHDNMTc7qVykhBHOrW5u7ApBrL4NkFW725v3sbgthoAydTzsh3M79e3311fr9h2Msd6QYpQace7hxvpua3tzc1fLNj5nsbmth9uQ
# DATA BANSeabUWX60KFreXblX38EQKdRicH6U7vDxABU5GClFaRoZzZXyRoScHPOUXwBnjt5ALCVjv/YO5C8dQc4D8UJx7sHKD1r3N++1
# DATA 7n64i00aYfNKbUtJmMbDQzHXMeeXGcuVFgQFUISIB18Kokc6PEbsii0In4yPgn0wsYl9JOZhRGXiEufHkHKpFKNjvCa3HwdMhjIS
# DATA HPYY3d+I4mqg1Gz1IGciPmBlFF257RQVViZS9HCB7aOAp3nF51ltYiTkY+0Mu3CI9mQWa9kJqX/QhdIUNkZ9h5EMhOaFhiz2MCc6
# DATA LQ5noaJVJzh2uGJG3aTm5iHSTTI/zr3t+s6OLXY7A6YsI3JdUaUgx+VkrRwMQS2GEaDwn4Ln/i2rsWZYWw1Y8gEA8Y3h5F0gByea
# DATA zKjgaYizhP45lJsC/0V1atRdAahs0SO4USMlASA5Yo0zlEtsILKLffKoN0RdnGygwbU3FXoBvCSYhdhSESZyAR4kCDWW2hDA3yOv
# DATA JkGwYD7UvlCw8R4L+TJWSAW0phUwID8pYEsQQWs9lZ0qJkffMEbRbMiC4Pp03H5SWCjhUpTdseiZaRYTVVaIs1Bfajyj9ms1USun
# DATA godtjGsITmkQorD3ZGGhvPdk8WDvydsH4sN3DpqcdAzLFsUddGmhOWcPghcG+l3wPL0RNJ6Gbb2OWBOg0RMToYLiO/571iw2ykvL
# DATA VbcNzuMHgxbNiIrmfLnvMCsgv+PzaaVaXO5G/l1Vh+EkeYHtGI/lEppaf7JU736ZvkEdnmdsVPuGoe4UpoeV9KYqpvfRv9ORbMVz
# DATA h4qd/aS0F6N+xNFWesJGR4g2zt6fXCTkCYZTnlJcq47YrDfJVRNWbgDtB9/wTBbPh6wYmmgudnOvoo5Abj84pLlKa1O6/nsAeUpM
# DATA XXBu/Tbe1uVjmrcGzlu16U10qKcA3VEKvN3jk+OCqrSBFTYz6xbMoTCVRxSTyTrROUN1ohYsVL0uH+5acS6tPpoUwfKifOa6vXjU
# DATA b58GbYyoa0OKg+DaQsBgA9cqrv9BNskaXoGJZLBCVDVIWR8eCQKVB8k6zBVkPkKyvhEsyh9WxdQD3+lHgwLNqy8RBpLuzgQTU1hl
# DATA OfUbkz9esLEJNzFSNO4Qf1tcWPC8QwRAnbuOZebNVtwuxcaxaGwZ/ZiyWEhmWfWzUKfSqN8exZApBFdLvGRRZcFo50CQQ3xEDZE8
# DATA 9BiI0NsTPL6KiRFARPgxdGRbUpfRrnxkHvfJI+VMsPNOX5CCJQ8ZTpZSWSyIhRi/RPjoDw+Z6bOnA5+5kHUUkv14clpKroKZI5JZ
# DATA FfNGV64P0PFeIXiJ6nQtOdKZzZbAjGVAM2uLCr8/6PrVqx9sb27c/1DqVC1la/0Hq/czla0JhAIligGfTOaZrLqMVZWHoFzoPNwS
# DATA rOgzd6n04lUIrkiGXarHVopO8vvVv1DwuAdwQJaxUtCmoSKIGen0IQnwQdf1gzK4lFatHnQ5rj9Jly2k7gJdgPhuBXEeEx0Eypcj
# DATA knYKYQNkBMpMNxkf4AkevvVh+a3j8lvd3bfeq771oPrWzt+E5NpXOTymMx7FiCZ6JdA9BJJOwTdqirwkQhVRG55MDsrfhmhUGHlc
# DATA C9nNQ8og3CfpeZQcFqMxMaVFxv60iSYXVa5sbdU31lxSTHWwUtMNGlXqadV1gE+Z/5CRnMk2JOG5lXIa0lEpzw76sZi3ZnEDhzBJ
# DATA QNyDK1M2hRlMjDK3SXSrBCuT2yJ1inFyUjkhM8BvdqZ4g8BPFp9lfpU9NaY4SzMklSbG6NDdTVt8roizW/dw0Kg83Fh5X0zDyt37
# DATA 9TCVBcu+JJdmmulre83cBZLu9fcNhIbP52g4lrAiGPRkr/Kx4AEMgYR+g4CZQeU8foOOE0plp7W+s12/V5CVSKyN1CiWHLOobwAn
# DATA g06bLhpm/Qz1YSm2bKMc9T6Ooo+kQJN4v2y/7wwR1FM1WQ/cNgp2aQ+NphpwskdMwcD4osJwkOM2a4L+iP+CMXmCTm+FfeTZjSW6
# DATA sKgSjSoUGwuprctFQACmQuD6zfUweFg6q8/oTTTo8k0GJhnytRbGYRn+gFEDokHQvM7Y7sH36x/iTyF5nut53o8Oe4NBSkV36/fW
# DATA N3JXBegF1Cc48hHQQ9cOyjf8kTwthFzwXf2rfObQK09U2Niur62s7tbXAqMPTTyDRYkG1wvYTkVWX4jrj+BRsca0svY8/yoBoZL3
# DATA WMugRbfXBqUDkdfvWRUA6vpkZi+uBU9li5T7sqQ4I2c2lV89GetYzKFkfgZPlY/kpR+0ytAUpiCUP1YO+8P9QnhdKjUa1dvLoC/C
# DATA QqqUt+VYSCiJt28uaegwahLET248Q5uAIC62KgHfSbA6w8yK79CVxxDj8Vj38DtjvsGNhMwaWEXDeL1ZLF75RfnAyk1vSOO9KGtK
# DATA vAeSL+XwhY6nyxxRaadO6nmVcQwxPsekNziJ5jyBLkYS6HT+n5N9mrcjQktF2qwAc4Z7keB2P9yLrxfeqUZPwDi2F98ovlNgSJhW
# DATA 00CPaV4vioI1KFy5XvwLO+8zGGsqD4pVv85Hc1biPs+ATh4LUn+GfOUZS3nPdGDkM8BYeuej6PQZHJmgJIOY5Wdxuz951o0ROgAG
# DATA 01hsYsvrKbMstxgVXmoaHm+Y5Hrv2l4YFr2vio6DQgRrKAZ/WQuWq6kBSg5PpXfcPZUQJBMbhqpBFJEhaDMKT6n/iP6En+An5u4e
# DATA vkBsAA8gp+tniBlZ60N+e0Z6oRu9sRfpvIF/lE89tVUyDqGmjEHhY1yq8Avv9I6LhfbJ5Ehs8R+jKlEQSqNaaxJx7QsCiMbPxEL2
# DATA OkWgsb0dwKQZh3uLRt3moeq2EHIborLGNcGz3tnbt4hTPN+pr27Xd59trezsfLC5vfYMs6Y842Oz9Y44N5+JAmv1jd31lfvPVrbW
# DATA 6dnKw933NrfX/2YFsgsV3Uq5MTWYYuOHe+O9QfNGGM42gOlCRWMv3ttpXn9HtDpNlHn2F8WwlCocZHVjbz86/StjkCYEVNr3/dCm
# DATA gaz6CwDLI15v8r+ijhuVcvN6dX4epi6e/161eaNKn5o3vpeYw+9l9/7J4v5eo7FQfqd5vRGU58V/v1f+79JalHhPQnp1jtrjdgcC
# DATA rBGYR30T+wlLgoLUfAjxEZMQ5DbBpPTbuJluLgXk42j98EYtWFx6O0tkVQLdGl8XA059GVPUdzueEJJ7Jdg9ipTC1lLdkaYSPEcI
# DATA qx3dKioAw8fyoK2lljc/cRWWHykB7oR0w/AGQI7IzsIj+fmML7d9QOydtJQjSov9VAraAr9NRvDg+GQC3sfBfXwFMehL0M+BYEcT
# DATA 7DB4T5CTgPjanhDwfDBpHxqm99Ew7vFVWUd7ksizXX+wsbIKmZu261ubO+u7m9sfUnrdyeS4PZhXqDdl1V3XfpaKjSbofN75DrSp
# DATA upPPKL5dv19f2amraE9p1mOnlYJWPIUyn5E46SqHQio52QeX2nlscf6pbvhsXnoGzdNavKPcOlroulF76nrpnxlO8IRTFteehisd
# DATA OIdALQIOHBCQAviojwZdbv4GSrQlSIAu6i2vsoGwCgJ5uQPPQk+MbvhQUGF55ZDTS+slMO8R4Rm9aTh+svdOQTl5GCkzQAgbR/Fo
# DATA OIijxA2Un5NMtHTrNnuSwBVTrTUcf6I4WMV1iQstIM68jWYCFZtEZRzDKkUtoF5ehGLEVsAxYjWM6tE+RKWWpuSC06oowUc/+4o4
# DATA ZP5oryt4uvwP8Mn2oROtObbb7I7bB2Br6cVYH2aoTBQaiRNdZni2Sl5k4JzXAcYCXuhW2Bc/Y4YkS5J4U01ZCVMg8s+KNSniyMV/
# DATA i++I6TFrnjKI9+vbO0JqUMq3Md67JyeCdReO2yNAVOX6JOg5JMTSKEmD0wK8BHS6uPz28rdv3l5+mywZ8FScRFjlRfrCc0dduhEU
# DATA FkpFsQ8Ky0EZdwfVq8NmLXeaaqbFxn/t8vp0oyZ8nAIozBo/DhDG7QzYubesXYy40hJVN9c07OxCPj+mKpb/jd1rIfL7iSb/5jXb
# DATA 4gnHOnha2ZNiJkoFpTTy84cP19f4VRQv8GPOnfXXD+s7u+n9isWjkemG0pIR88fi1JHfOFesggKuTvF+YwcIjxPYnIG7Lb7bJjIx
# DATA 5izdU36F+MONnZV3662tld33QqtH+eyasnDCqpn06tNzpihJT5YBzUrPUHvsomHp8umAWAaRqKpKqKZyLZlGQ+pzY6HpKP0oWBTN
# DATA cmaWbfVGkfj6ytZWi65SKFb7ML7A07kW0EgYPsvUJylFjTU2I4QC9BC2yvWHutUaXCEOAOHz6e3lM6lpYA1DckhSEYAwuZQHyACQ
# DATA ZTZCpUHvenMpk4gerO/srG/ckxPApzJoKQDz9bjdqQyix1ydgv8tBex1W5Lu15X4qC0kD5TGur1DEP2KHt+xdLovCfGdlK5Vav7M
# DATA QfGWFQFNFcyNW0zkMeAVMqS+2EQQZBdjhQzekICD4B6Iodp65cB5BVHH2JFdcBLGBCyEj4b9k+MIHIEbloug8o5s4OukisJPkLyJ
# DATA auwdeJUrBWMLYElmzpTHCR5IGQlBE9H1K+GADSwmb+1KgZJ045adlQd5NSwKqWSpWWwamh61DcXqnY7g4hXu9wYmxCMBwjGzKWrA
# DATA x2qySXavbkGcgPgdWNXZnM97wfQygKOiITvS9EVvWvTOTbUebD7c2IWG372/vrrrSYbG1TuGO1w9qfeSrfoo3T5aJCKw0YCcEtS7
# DATA m17SKj9FWh7ylBdhB7FPX5XkUvBpRxdBsSq9LsIRsJNlFc25s+Z94qXjvNuykiBETSx/PUsCvgLgbtRt8UFq5JKX9uhiKqoFB2wX
# DATA pmC+gpJAXPGBsCHlb1Ag/oJ6A+nWKdEtXCxcB5AiCXgb90AxYWLcqgAYDn4JynfR9G4MjaIrfONCRxCKiMWXzNmBn1DHkegUgHdA
# DATA 08NBmT0T9gb8DGFpbTje/FgXPtLVkRfzAQdslDj43F3aROpIjS2QhMooEX6EIYJkv64wNMJyeTB8LD5wb2auaUwzlVqDvBQgQIqQ
# DATA YEEnPzllgdGQXAwNEADgAuZZHzjWqcp7KnghHmp3JN1BTGe7G0wAO4aO1agtjmycbqUDShUxVeKB9IMzIw2BJWpK2fRSAqbE1qS2
# DATA PIxKx2Vo6dEEe80UzOQznnFxDkSm3JglrnHHbi4F363ZAlAtWF74zm2FWX6kbQqsGyUc470xQuygPgjc88Nm8Y9IbpIpG5IykvLR
# DATA RI1UVcVkt1o9sWNbLdGF/gHZls2IZfGwkk52qoi+4ug3zHuOag5FLmwr6Qhv3CPMOt1zz6is/SjifidUE9a0ZNXH7zrxCTpknfSl
# DATA 3WSf0aBdc3vtWtw5Lbvj7d6ToV0MPQtCAHhpU4QTG/4DZTenUoK1yt744ScswtvY3G2tb4iL+H3wBtNNSzUR1dwI+bsHpiNRQk8L
# DATA OHQxwUg1JbgBmPfh6fFiCncOnOl9GafkBRMnlign4QOQGSN2BZ5O0j4QyGWR+ls3ZEtMSZgBSpzUb4w4GChFEReqy97SMqQfgeL5
# DATA XLf86g53UlN3WyGEpnB8uDRumIt/8nkqXvUCOB3LXgWmY8sNUW1SwxdR0zX6siS3ugbydCJnK31MHGFUW7T8riEhDjkWQBWOI5Pr
# DATA 5AF/ABaXb22g6oYQ1zGky79CvEqiTjsOCMMcxZydRHgBkwGPdMEz4o+Csn7XDCRYAMXj20sLKXEq8A7HvWGLNRk/yb4YNUGhu/Xt
# DATA 7YdbuxZnUl3GkYlaCHZcSFBV1Q9ACjcTC5iEJ4ZiJjXg4ap7B9rDDkE1EzoA49MDJP1dUwFTlnFxxMEptOZnxnGVDK9mJto5ag+S
# DATA 3BN1xkgAiOxBJgRQGLc7hInj5TDyR9SZGowzLZgrS67bWgMHgbsPdz5M+H+e+gKpyHs4OcwKIF4eCfGt9+PI3IE07qJvMXy1rOE/
# DATA aS6d6QMxXJ3Jp5N8lM1N3yJnQ1oO4syKltQhN+vJpkNVVXCxvF9IlCXjyiFk9sNxuxvlONvTOTwyHC+nEkNDJYQ5/zRQIVEMH7e6
# DATA vRhxyyyopcRAIIRQ9hPZBTRIpHXcHojqumTzQmKdOo6tlXv11oP1e9voYoLDWd+2eELqHoCvKTuAfnql9M/e5LlPzumbx1AH+mK4
# DATA U+JzkmdvLePs9b6sWSYe3OprulfXzCKHwyBk+9MHdoEDy67AObW+m3FqzbT++U8M5cjmyl90UEBAHYXZ63WomqzHWNyqFra1vk7P
# DATA ihmLaMyJq3ez96QnYtvJr5FKsSmqFMJizEQqZJ1aGWHeAAzQADA0oTkOLSnbr4UU7ykQQ63aogrVD4y+9KD9BJRgQANQwFXP4Ut3
# DATA QfmDSrnU9hikDk4VLfaVWDqFTFnRmNuHB71uKBmteASigzpPLO2S5ejhI7bCBbGqLMKbIpiJ6+L2bktFELG8VEuGOs353T3VyZJT
# DATA VPcUHIdlvvmUm09v3j7b44K+qK4ZSDhli1sDdgJNZDAUANTawgIssiUrXFBAuPIb4Uys+cKHmHMoF6tTLpjJYyzP3ZGM/gkQA9CP
# DATA MNNLE0Gtx+Ae6KilZExbISeVFt0KW51xxNFPKJFMZ5YUnYdIKDrgz9gvkNuG3RDzbYgkddv9ApbiZwENdQ1qMqqT+F70CCSpEYa4
# DATA aeTerZnTp08uBfdtLKEhahT9174rFl3V7Gv5Vc6B7kvTJ4dcicR7Kcn3yu8RlxLffIeHEsMuw5PJMcoT4arSxhNga2P1/roeWzL9
# DATA Kp24UlWJuDbgExo2M1YT/SG4YlrLtHpxT5rKBfW56T8JHdnoOiV98csEp+BQABPU7Q1qxptr9fc3Ht6/j7+AXCD3H+WbUl99IsTb
# DATA iwsLfhk8Y1uvbj7Yul/fxZPf3tr56EFDy0h5QmdKnzGO6mISTu/AZIJ+cuIAeYIJmD5FMlxefJYiyIUEK9zvm1t13u9egYM5kwHq
# DATA 0fTgAeXYY5a15SShz8xUq/uxfzwXrRSQEdQN3l5wE9dgPoAWaTd5nKSut/dPEng9oXNnccquxJ6aNiY1rE0x9vZiRke3LyvQhabe
# DATA SbeKRsYkBOfxKt2gxSTBAT5PV4hBAd0KNEBPP2qLHgKc2f54+DiG5MSstQDoGaCASdQ/rfi5ZZo6JPXCn/5jLitLuuBmkYfHEiOm
# DATA y1j6aqYbibWLGLaevVNyaJFBmy+3Tc0g1GJ2mzhktCLap1Myj9PJeMyRh/CONgvOGCJaTKvWq0u+fp1zXobtR2Lw6OZQVS+xazk7
# DATA 16guabcbLpi8yCpcM1HIBWEzZCyalDPT7NeR9x5INuWGypGB+X6C2sjOjIkcW61CbzCIfEG5+BzjRBnugFylpaO1a8NlHFAELC8l
# DATA QcgtwBwXJAcm9IZHbvGK7i7Ctu6ng7MtWisgphTMDQkXxu8bd4uZWjGvwC7zkEHDQtRa30zRMtnzl3m6WdNsUZ2nU8nbDa/lE/QZ
# DATA wLpKwfWWP8BVNzVzj7n9+3i/tA40paWXvg7Juzf90kJX/pJxE9exFOhoUkq9ml9c65yidpnGXv2G7Gm6XEtDcSl95gUt7VkdTO3c
# DATA NHTBCw1AOTbRqoM7j1xtl2HnawrcJzbqH9S3nYbeDDYHkcLURUHjR0Mx0HYf+HF8cnDQ6/TQsQvi+mSMIoRogdYBZqUtLnBHvRhB
# DATA bRKh6CZQl8nxGF1B4VFKmIVqfh7GxG7BdDXABcpAuSxWy/iEa2+mhoBfHtkrG+Er550hpd4MpbvyfKULk0+RLl1ftbbd9Wdl1uMf
# DATA 04UU8amSyDejfk9TdSdU8n4HmFKqGn6qzv6bUc2bWvk/FhV8Lhn3KhXyU5yXIODcKjSTGj6TgK9K+W7o3S+icXf11mkn+qX9znJh
# DATA k2forHuDg6FPM89hpVlw4ToSiRCActcRH82o54bfTROCT7s+heSKV6I4x16w9nw6CV+x4rzlt9Ebak2issNqTnUcapq0ip2nLOoS
# DATA 82W1OvbGPpXQDQxIv2bMtP/8pig1N2u0ASKwubnL8TgWF9UlWBD7q8271jlp4hBgEHNrfePdzda7YoNzfUDZxdR4Ek8F9Y3d7Q/N
# DATA GpCwHQcuZ5noTIdF0jkc5ma6/9v7087BYBCfHrmZK+L833XiHsrt8+nLn2Nero/hq+XBkHIvkikBaxkwE7kUz6TcFgIA9K8sw9Id
# DATA XbmqvIkRhTWIKswT8jNVY420zOpq/Ow7a7+TpqrWIAPalIj0k1IaPdO7GiagQbxAbRA/EpJyh6bX/ZWDeY4UrQfX3peJafQyPVUf
# DATA z6qc2OaprPBMhXiIV/g3/wY+2xtcUyEA6f3wZZU2DqbEgILv6quQt93iTK4+cmPCBWm7vrL2YThLV2a6ll3gemY52DMVqMXRrPKN
# DATA ml69Czo6mSANntaRTSWibEAoUL9MuxlduPk3g7ukVYb2KMUu4uIft0/huoUZl9rBIALc+BFlidF5lipzU7Wzip55Qmt+upIqGllK
# DATA koESdrG6dDb4irjzv2hmbOVYg6xyVcjVCXnmPjv/8uUvAjpJZa8pHUw+vqtvMPttIVmVjKPLsGJKgEc/NzaNg98UW06lZ3e7whby
# DATA L/tMBM3YHK0H6zsPVnZX3wsvs8qcWAkW+d/Of5XMlvo7zJQK6fT+gVIIhlMWdep1LY/Jc5qo55hds4U8f9WpOh9q15PtJOn0k52K
# DATA qDi1ejd7jpP/wUij4zpsTk+nk+1f4LcM2IlGICTOzFHk7fVZirh8AcNOpjbqlRrB30SUNL56EIYMBBEGqGHvBvunFGM6GvYGk0qw
# DATA JSYBAomDLVS0zA+iCVyyPbWysgGiU4clvN+INoLOcAR5zZSis9trHw6G8aTXARXmZEjnS0emRb+QyT7FHt8yIezzq0GN7TDV9HVh
# DATA XpQgf/Jt5pYJh0MfSrnC61N42lepjE0mLZu7SnpO0DIqrmlRMAB/58Od3fqD1tbK6vchY4r0bBIXwa2Hu2HWSL15U409sIonz5a9
# DATA DQZdIgDHSP/2rayWcP6nZWw1jimZsJVvvV6F1YXUezxxbsCbkwj9Yv4huSQouE5JxftxLxaTcGiD/yRUSqmlVQ6YQe/JDuIvFswc
# DATA l5XdI0qJePig92R9ULISYFbwJeRV9KpMD4DAAK0JvhqbyhnQBoK1h3ec6+IiToMBRYOXgna3y/s9PhmJXmEkiHqx6HkH0Fv4dlq4
# DATA lbBJeupW8FGi7wWMuee+0JRw/tCCP61o0cw7QOzwWNQpqmFVZ8K8am1CQiQY9U9lLJnYAiXEEHPe2h92T21cDSykbpwee0Q06LYk
# DATA rmABSqUVIjDFQrhKEJplAMSQGTEloKJHSempwIJYLCHEIqIthHmbvh8NDidS4gZjFozb9TfF1/XbsW/0j9EwTSIG1mFN+REuXhr9
# DATA mYHx2URlwgFo8YxwG/Igz/tM0QgrAKJpexy1GC0Ae8OjZXwEE5SYIBLEf+4iIDHefLCFYrplF889pLzlhZsgYEnzVvju5vbd9bW1
# DATA +kZ4lkPFK28XMhsp+Gjeq++Sty3+QmpmyBdLckSYbQ/XHVsCTDOaN/aF84fI5mif0hHEIPgUwnlQclNo/3yqn21Wb5QWG6omK6xT
# DATA Z/Nqe3oYpXZUojOm9IfebEp4p/lsXHDCT4Tb4dKriyBLn1NsHtHP6dPCxaeRCI6jeWfvDYWSX7J1yx2ZomAvRPueyOOcPdva3Lls
# DATA 1/rIkRWFGUyoBQkck5y70cwkMa6PsKVVmKfF23bH7UF8EI3LdTjcKFaQ1W/8tqCMSi8WzLE30aq5heC7cGsp6DKosrRBcq+MmBnn
# DATA 00BApNXDcwdhP52+FDPdMQwRFmqWiHA4PxPGC30DXCAQ7wTj4hmXbDt61EP1wtk3vWV9hIk9vSRx4uabb3convLPkyqXbt3+MyJK
# DATA WDEPhoMODXsVtKk5Ncf/Q4casi9NEqOtWCH5SPermZ/sly50NqQSOYmFr8n7T4G8bTXuN0TYJk0nbDNXQcfpMrV1OVi2Lgdgunt3
# DATA 8+HGmns5eKVqUatD3yEPHqUAgu1k+paSvmdZnFNZaiQ9pgvoktx1NOaiO2wJeRDg4aw7pvk78AR/AVKrSMccWqak1zyUUoiAxisK
# DATA qg9J2HjuxwJ0XvZZO93f8WthetgyYwrubK5+v25SuVmf5TGKHjem8mkiFVDkolOSahjCXMdCVW+1Euj6tumYwIoq/Kd1MMRkQZhg
# DATA tQf+8JxcE+io1QIpptUKZdbjcYyOHGL/4efKyvjwBGAMt/AXlWkLLKQtIQN1Wq2i8SbkJ2u1+ZWCdnFE580t1IAz0DB+E/ez4Wgy
# DATA r1w2peXGW5l50naOhoBsXCOQYxQPtdOkg2yAMOky6FRMRVkiYWJZGVrSzByGjIPMLETK8+KdtN/77f2on/E7mtmymwBv0PQKUG2a
# DATA 8Tuj92aUYFxK7gQHs3JZ/AdKS/0ThKriYRqd9NjGuuCiS+6gm2/9CdzFt08o3w25ldDeVrDVkCsEaEUnVRANVexQWB0HNJdm3sC3
# DATA yLyBH8WE8SdcHf6MK8GfcdYlOrq/XaIgE2cSgPfdpjj4CT/zTPM3ntXsRhLUaUG62RCubtO5GuAdoatFbE1dV7GCDqty2rIrM/dY
# DATA Ro0afwIf4tdeV6+ND5We9NJuVcW5b73+e/33+u/13+u/13+v/17/vf57/ff67/Xf67/Xf6//Xv9d5u8/AaEkgBcAKA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
