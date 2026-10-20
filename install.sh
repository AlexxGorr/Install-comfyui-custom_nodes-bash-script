#!/usr/bin/env bash

# =============================================================================
# ComfyUI Custom Nodes Manager (Docker/WSL)  v0.4
# =============================================================================

set -euo pipefail

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''; BOLD=''
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODES_LIST="$PROJECT_ROOT/nodes_list.txt"
CONTAINER_NAME=""
ACTION=""
USE_LIVE=0
CONTAINER_CUSTOM_NODES_PATH="/root/ComfyUI/custom_nodes"

declare -a NODE_NAMES=()
declare -a NODE_URLS=()
declare -a NODE_FOLDERS=()

trap 'echo; warn "Прервано пользователем. Проверь папки: docker exec $CONTAINER_NAME ls $CONTAINER_CUSTOM_NODES_PATH"; exit 130' INT

# -----------------------------------------------------------------------------
# UI
# -----------------------------------------------------------------------------
show_banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
╔══════════════════════════════════════════════════════════╗
║     ComfyUI Custom Nodes Manager (Docker)                ║
║     Install / Uninstall / List                           ║
╚══════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}
section()  { echo -e "\n${BLUE}▶ $1${NC}"; echo -e "${BLUE}──────────────────────────────────────────────────${NC}"; }
success()  { echo -e "${GREEN}✔ $1${NC}"; }
error()    { echo -e "${RED}✖ $1${NC}" >&2; }
warn()     { echo -e "${YELLOW}⚠ $1${NC}"; }
step()     { echo -e "${CYAN}  → $1${NC}"; }

# -----------------------------------------------------------------------------
# Проверки
# -----------------------------------------------------------------------------
check_deps() {
    command -v docker &>/dev/null || { error "docker не найден в PATH."; exit 1; }
    [[ -f "$NODES_LIST" ]] || { error "nodes_list.txt не найден: $NODES_LIST"; exit 1; }
    [[ -d "$SCRIPT_DIR" ]] || { error "Папка scripts/install_nodes не найдена."; exit 1; }
}

# -----------------------------------------------------------------------------
# Контейнер
# -----------------------------------------------------------------------------
select_container_interactive() {
    local -a containers=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && containers+=("$line")
    done < <(docker ps --format '{{.Names}}')

    if [[ ${#containers[@]} -eq 0 ]]; then
        error "Нет запущенных контейнеров. Запусти docker-compose up -d."; exit 1
    fi
    if [[ ${#containers[@]} -eq 1 ]]; then
        CONTAINER_NAME="${containers[0]}"
        success "Найден единственный контейнер: $CONTAINER_NAME"
        read -r -p "Использовать его? [Y/n]: " ans || ans="Y"
        [[ "${ans:-Y}" =~ ^[YyДд]?$ ]] || { error "Отменено."; exit 1; }
        return
    fi
    section "Доступные контейнеры"
    local i=1 c
    for c in "${containers[@]}"; do echo "  $i) $c"; ((i++)) || true; done
    local choice
    while true; do
        read -r -p "Номер контейнера [1-${#containers[@]}]: " choice || exit 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#containers[@]} )); then
            CONTAINER_NAME="${containers[$((choice-1))]}"
            success "Выбран: $CONTAINER_NAME"; return
        fi
        warn "Некорректный ввод."
    done
}

resolve_container() {
    if [[ -n "$CONTAINER_NAME" ]]; then
        docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" \
            || { error "Контейнер '$CONTAINER_NAME' не запущен."; exit 1; }
        success "Используется контейнер: $CONTAINER_NAME"
    else
        select_container_interactive
    fi
}

# Информация о персистентности custom_nodes.
# Архитектура проекта: custom_nodes НЕ монтируется на хост (изоляция).
# Персистентность — вручную через `docker save` после изменений.
check_persistence() {
    local mounted
    mounted=$(docker inspect "$CONTAINER_NAME" \
        --format '{{range .Mounts}}{{.Destination}}{{"
"}}{{end}}' 2>/dev/null \
        | grep -x "$CONTAINER_CUSTOM_NODES_PATH" || true)
    if [[ -z "$mounted" ]]; then
        warn "custom_nodes изолирован внутри контейнера (проектная архитектура)."
        warn "После изменений сделай снапшот:  docker save $CONTAINER_NAME -o comfyui-$(date +%Y%m%d).tar"
    else
        warn "custom_nodes примонтирован на хост — это нарушает изоляцию по архитектуре проекта."
    fi
}

# -----------------------------------------------------------------------------
# Парсинг
# -----------------------------------------------------------------------------
folder_name_from_url() {
    local url="$1"; url="${url%/}"; url="${url##*/}"; url="${url%.git}"; echo "$url"
}

parse_nodes_list() {
    NODE_NAMES=(); NODE_URLS=(); NODE_FOLDERS=()
    local line name url folder lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno++)) || true
        line="${line//$'\r'/}"
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *"|"* ]] && { warn "Строка $lineno: нет '|' — пропущено"; continue; }
        name="${line%%|*}"; url="${line#*|}"
        name="$(echo -e "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        url="$(echo -e "$url"  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$name" || -z "$url" ]] && { warn "Строка $lineno: пусто — пропущено"; continue; }
        [[ "$url" =~ \.git$ ]] || { warn "Строка $lineno: URL без .git — пропущено"; continue; }
        folder="$(folder_name_from_url "$url")"
        [[ -z "$folder" ]] && { warn "Строка $lineno: folder пустой"; continue; }
        NODE_NAMES+=("$name"); NODE_URLS+=("$url"); NODE_FOLDERS+=("$folder")
    done < "$NODES_LIST"
    success "Распознано нод: ${#NODE_NAMES[@]}"
}

# -----------------------------------------------------------------------------
# Проверка установки (fallback: папка из URL ИЛИ алиас)
# -----------------------------------------------------------------------------
is_installed_by_folder() {
    local sub="$1"
    [[ -z "$sub" ]] && return 1
    [[ "$sub" == "." || "$sub" == ".." || "$sub" == "/" ]] && return 1
    [[ "$sub" == *"/"* ]] && return 1
    docker exec "$CONTAINER_NAME" test -d "$CONTAINER_CUSTOM_NODES_PATH/$sub" 2>/dev/null
}
is_installed_any() {
    local folder="$1" alias="$2"
    is_installed_by_folder "$folder" && return 0
    [[ "$alias" != "$folder" ]] && is_installed_by_folder "$alias" && return 0
    return 1
}

list_installed() {
    section "Установленные ноды в контейнере: $CONTAINER_NAME"
    local -a entries=()
    while IFS= read -r line; do [[ -n "$line" ]] && entries+=("$line"); done < <(docker exec "$CONTAINER_NAME" sh -c "ls -1 '$CONTAINER_CUSTOM_NODES_PATH' 2>/dev/null || true")
    if [[ ${#entries[@]} -eq 0 ]]; then warn "Папка пуста или недоступна."; return; fi
    local i=1 e
    for e in "${entries[@]}"; do printf "  %2d. %s\n" "$i" "$e"; ((i++)) || true; done
    echo; success "Всего установлено: ${#entries[@]}"
}

# -----------------------------------------------------------------------------
# docker exec с опциональным --live
# -----------------------------------------------------------------------------
dexec() {
    if [[ "$USE_LIVE" -eq 1 ]]; then
        docker exec -it "$CONTAINER_NAME" "$@"
    else
        docker exec "$CONTAINER_NAME" "$@"
    fi
}

# -----------------------------------------------------------------------------
# Установка одной ноды с rollback при провале pip
# -----------------------------------------------------------------------------
install_node_at_index() {
    local idx="$1"
    local name="${NODE_NAMES[$idx]}"
    local url="${NODE_URLS[$idx]}"
    local folder="${NODE_FOLDERS[$idx]}"
    local target="$CONTAINER_CUSTOM_NODES_PATH/$folder"

    if is_installed_any "$folder" "$name"; then
        warn "[${idx+1}] '$name' уже установлена — пропуск"; return 0
    fi

    section "Установка: $name"
    step "URL:    $url"
    step "Папка:  $folder"

    step "git clone ..."
    if dexec git clone --progress "$url" "$target"; then
        success "git clone OK"
    else
        error "git clone FAILED: $name"; return 1
    fi

    if dexec test -f "$target/requirements.txt"; then
        step "requirements.txt найден → pip install -r"
        if dexec sh -c "cd '$target' && pip install --no-cache-dir -r requirements.txt"; then
            success "pip install OK"
        else
            error "pip install FAILED: $name"
            local ans
            read -r -p "$(echo -e "${YELLOW}Удалить клонированную папку '$folder' (rollback)? [Y/n]: ${NC}")" ans || ans="Y"
            if [[ "${ans:-Y}" =~ ^[YyДд]?$ ]]; then
                dexec rm -rf "$target" && warn "Rollback выполнен: $folder удалена"
            else
                warn "Rollback отклонён. Нода останется в контейнере, но может быть нерабочей."
            fi
            return 1
        fi
    else
        step "requirements.txt отсутствует — пропуск pip"
    fi

    success "Нода '$name' установлена"; return 0
}

install_all() {
    section "Режим: установить ВСЕ из nodes_list.txt"
    local total=${#NODE_NAMES[@]} i=0 installed=0 skipped=0 failed=0
    while [[ $i -lt $total ]]; do
        printf "\n${BOLD}[%d/%d]${NC} %s\n" "$((i+1))" "$total" "${NODE_NAMES[$i]//%/%%}"
        if is_installed_any "${NODE_FOLDERS[$i]}" "${NODE_NAMES[$i]}"; then
            warn "уже установлена — пропуск"; ((skipped++)) || true
        elif install_node_at_index "$i"; then ((installed++)) || true
        else ((failed++)) || true; fi
        ((i++)) || true
    done
    echo; section "ИТОГО"
    printf "  Установлено: %d\n  Пропущено:   %d\n  Ошибок:      %d\n" "$installed" "$skipped" "$failed"
    [[ $installed -gt 0 ]] && ask_restart_container
}

install_one() {
    section "Режим: установить ОДНУ"
    local -a not_installed=()
    local i=0
    while [[ $i -lt ${#NODE_NAMES[@]} ]]; do
        is_installed_any "${NODE_FOLDERS[$i]}" "${NODE_NAMES[$i]}" || not_installed+=("$i")
        ((i++)) || true
    done
    if [[ ${#not_installed[@]} -eq 0 ]]; then success "Все ноды уже установлены."; return; fi

    echo "Неустановленные ноды:"
    local k=1 idx
    for idx in "${not_installed[@]}"; do
        printf "  %2d) %-40s  (%s)\n" "$k" "${NODE_NAMES[$idx]}" "${NODE_FOLDERS[$idx]}"
        ((k++)) || true
    done
    echo "   0) Отмена"
    local choice
    read -r -p "Выбери номер для установки: " choice || return 0
    [[ "$choice" == "0" ]] && { warn "Отменено"; return 0; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#not_installed[@]} )); then
        error "Некорректный выбор"; return 1
    fi
    local chosen="${not_installed[$((choice-1))]}"
    install_node_at_index "$chosen" && ask_restart_container
}

# -----------------------------------------------------------------------------
# Uninstall
# -----------------------------------------------------------------------------
uninstall_node() {
    local query="${1:-}"
    if [[ -z "$query" ]]; then
        read -r -p "Имя ноды (алиас или папка) для удаления: " query || return 0
    fi
    [[ -z "$query" ]] && { error "Пустое имя"; return 1; }

    local i=0 folder="" alias="" found=0
    while [[ $i -lt ${#NODE_NAMES[@]} ]]; do
        if [[ "${NODE_NAMES[$i]}" == "$query" || "${NODE_FOLDERS[$i]}" == "$query" ]]; then
            folder="${NODE_FOLDERS[$i]}"; alias="${NODE_NAMES[$i]}"; found=1; break
        fi
        ((i++)) || true
    done
    [[ $found -eq 0 ]] && folder="$query"

    # Guard: имя папки должно быть непустым и безопасным
    if [[ -z "$folder" || "$folder" == "." || "$folder" == ".." || "$folder" == "/" || "$folder" == *"/"* ]]; then
        error "Недопустимое имя папки для удаления: '$folder'"; return 1
    fi

    local target_folder=""
    if is_installed_by_folder "$folder"; then
        target_folder="$folder"
    elif [[ -n "$alias" ]] && is_installed_by_folder "$alias"; then
        target_folder="$alias"
    else
        error "Нода '$query' не найдена в контейнере"; return 1
    fi

    # Финальная защита пути
    local full_path="$CONTAINER_CUSTOM_NODES_PATH/$target_folder"
    if [[ "$full_path" != "$CONTAINER_CUSTOM_NODES_PATH/"* || "$full_path" == */ || ${#full_path} -le ${#CONTAINER_CUSTOM_NODES_PATH} ]]; then
        error "Отказ: небезопасный путь для удаления: '$full_path'"; return 1
    fi

    section "Удаление: $query  (папка: $target_folder)"
    step "Будет удалён путь: $full_path"
    read -r -p "Подтвердить удаление? [y/N]: " ok || return 0
    [[ "$ok" =~ ^[YyДд]$ ]] || { warn "Отменено"; return 0; }

    if dexec rm -rf "$full_path"; then
        success "Удалено: $target_folder"; ask_restart_container
    else
        error "Не удалось удалить '$target_folder'"; return 1
    fi
}

# -----------------------------------------------------------------------------
# Рестарт
# -----------------------------------------------------------------------------
ask_restart_container() {
    local ans=""
    printf "%b" "${YELLOW}Перезапустить контейнер '$CONTAINER_NAME' сейчас? [y/N]: ${NC}"
    IFS= read -r ans || ans=""
    if [[ "$ans" =~ ^[YyДд]$ ]]; then
        step "docker restart $CONTAINER_NAME ..."
        if docker restart "$CONTAINER_NAME" >/dev/null 2>&1; then
            success "Контейнер перезапущен"
        else
            error "Не удалось перезапустить"
        fi
    else
        warn "Перезапуск отложен. Не забудь: docker restart $CONTAINER_NAME"
    fi
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    local positional=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --container|-c) CONTAINER_NAME="$2"; shift 2 ;;
            --live) USE_LIVE=1; shift ;;
            --help|-h)
                show_banner
                cat << 'USAGE'
Использование: install.sh [опции] <действие> [аргументы]

Опции:
  --container, -c <имя>  Имя Docker-контейнера
  --live                 Стриминг git/pip в реальном времени (docker exec -it)

Действия:
  install             Установить все ноды
  install-one         Установить одну (интерактивно)
  uninstall [имя]     Удалить ноду (алиас или папка)
  list                Список установленных
  self-test           Диагностика
USAGE
                exit 0
                ;;
            install|install-one|list|self-test) ACTION="$1"; shift ;;
            uninstall) ACTION="uninstall"; shift; [[ $# -gt 0 ]] && positional="$1" && shift ;;
            *) error "Неизвестный аргумент: $1"; exit 1 ;;
        esac
    done

    show_banner
    check_deps
    resolve_container
    check_persistence
    parse_nodes_list

    case "$ACTION" in
        list)        list_installed ;;
        install)     install_all ;;
        install-one) install_one ;;
        uninstall)   uninstall_node "$positional" ;;
        self-test)
            section "SELF-TEST"
            printf "  %-3s %-40s %-40s %s\n" "№" "Алиас" "Папка (URL)" "Статус"
            local i=0
            while [[ $i -lt ${#NODE_NAMES[@]} ]]; do
                local st
                if is_installed_any "${NODE_FOLDERS[$i]}" "${NODE_NAMES[$i]}"; then st="${GREEN}[✔]${NC}"; else st="${YELLOW}[✖]${NC}"; fi
                printf "  %-3d %-40s %-40s %b\n" "$((i+1))" "${NODE_NAMES[$i]}" "${NODE_FOLDERS[$i]}" "$st"
                ((i++)) || true
            done
            echo; list_installed ;;
        "")
            warn "Действие не указано. --help."
            list_installed ;;
    esac
}
main "$@"
