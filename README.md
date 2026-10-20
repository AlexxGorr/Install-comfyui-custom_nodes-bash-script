# ComfyUI Custom Nodes Manager (Docker / WSL)

Bash-скрипт для управления кастомными нодами ComfyUI **внутри изолированного Docker-контейнера**.

- Установка нод из списка `nodes_list.txt` (все или по одной)
- Определение уже установленных нод
- Удаление (uninstall) по имени
- Список и количество установленных нод
- Построчная визуализация `git clone` и `pip install -r requirements.txt`
- Интерактивный рестарт контейнера после изменений
- Защита от опасных `uninstall` (пустое имя, `.`, `..`, `/`)

---

## 1. Архитектура проекта

**Изоляция — приоритет.** Папка `custom_nodes` **не монтируется** на хост.
Персистентность обеспечивается **вручную** через `docker save` после изменений.

Всё работает как надо. ✅

- Warning теперь корректный: `custom_nodes изолирован ... сделай снапшот: docker save ...`
- Рестарт по `y` — **сработал** (`✔ Контейнер перезапущен`)
- Реальная установка `comfyui-OreX` с **живым построчным pip-выводом** (скачивание, установка 10 пакетов) — прошла
- Guard'ы `uninstall` — работают

Это финальное рабочее состояние. Теперь — **Шаг 6: README.md** и проверка целостности.

---

### 📝 Шаг 6: README.md

Собираю под фактическое поведение скрипта v0.5: изоляция + `docker save`, guard'ы, CRLF, `--live`, rollback, запуск из WSL/CMD, troubleshooting.

**Команда (WSL, из корня проекта):**

```bash
cd /mnt/c/Users/aiott/Downloads/comfy_docker_pack_app/comfyui-megapak-offline
cat > scripts/install_nodes/README.md << 'EOF'
# ComfyUI Custom Nodes Manager (Docker / WSL)

Bash-скрипт для управления кастомными нодами ComfyUI **внутри изолированного Docker-контейнера**.

- Установка нод из списка `nodes_list.txt` (все или по одной)
- Определение уже установленных нод
- Удаление (uninstall) по имени
- Список и количество установленных нод
- Построчная визуализация `git clone` и `pip install -r requirements.txt`
- Интерактивный рестарт контейнера после изменений
- Защита от опасных `uninstall` (пустое имя, `.`, `..`, `/`)

---

## 1. Архитектура проекта

**Изоляция — приоритет.** Папка `custom_nodes` **не монтируется** на хост.
Персистентность обеспечивается **вручную** через `docker save` после изменений.

```
comfyui-megapak-offline/
├── docker-compose.yml
├── nodes_list.txt
└── scripts/
    └── install_nodes/
        ├── install.sh
        └── README.md          ← этот файл
```

> ⚠️ **Важно:** всё, что установлено скриптом, живёт в слоях контейнера.
> При `docker compose down` / пересоздании контейнера установленные ноды **исчезнут**
> (вернётся только набор из образа). Поэтому после успешной установки:
>
> ```bash
> docker save comfyui-megapak -o comfyui-$(date +%Y%m%d).tar
> ```

---

## 2. Требования

- Windows 11 Home/Pro + WSL2 (Ubuntu)
- Docker Desktop с включённой **WSL Integration** для вашего дистрибутива
- Запущенный контейнер ComfyUI (по умолчанию `comfyui-megapak`)
- Bash 4+ (в WSL есть из коробки)

Проверка:

```bash
docker --version
docker ps --format '{{.Names}}'
```

---

## 3. Формат `nodes_list.txt`

Файл лежит **рядом с `docker-compose.yml`**. Формат — `алиас|URL.git`, по одному на строку.

```
ComfyUI-FlashVSR_Ultra_Fast|https://github.com/lihaoyun6/ComfyUI-FlashVSR_Ultra_Fast.git
comfyui-OreX|https://github.com/orex2121/comfyui-OreX.git
UC_MiniMaxH3Cache|https://github.com/silveroxides/ComfyUI-UtilsCollection.git
```

Правила:

| Поле | Описание |
|------|----------|
| `алиас` | Произвольное имя для отображения (может не совпадать с папкой) |
| `URL` | **Обязательно** оканчивается на `.git` |
| Разделитель | Ровно один `|` на строку |
| Комментарии | Строки, начинающиеся с `#` |
| Пустые строки | Игнорируются |
| CRLF | Автоматически очищается (`\r` удаляется) |

**Имя папки в контейнере** = `basename(URL) - ".git"`.
Пример: `UC_MiniMaxH3Cache|.../ComfyUI-UtilsCollection.git` → папка `ComfyUI-UtilsCollection`.

---

## 4. Запуск

### 4.1 Из WSL (рекомендуется)

```bash
cd /mnt/c/Users/aiott/Downloads/comfy_docker_pack_app/comfyui-megapak-offline

# Справка
bash scripts/install_nodes/install.sh --help

# Список установленных
bash scripts/install_nodes/install.sh --container comfyui-megapak list

# Диагностика: таблица алиас → папка → статус + список
bash scripts/install_nodes/install.sh --container comfyui-megapak self-test

# Установить все ноды из списка
bash scripts/install_nodes/install.sh --container comfyui-megapak install

# Установить одну ноду (интерактивное меню)
bash scripts/install_nodes/install.sh --container comfyui-megapak install-one

# Удалить ноду (алиас или папка)
bash scripts/install_nodes/install.sh --container comfyui-megapak uninstall comfyui-OreX

# Живой стриминг git/pip в реальном времени
bash scripts/install_nodes/install.sh --container comfyui-megapak --live install-one
```

### 4.2 Из CMD / PowerShell (Windows)

```cmd
wsl bash /mnt/c/Users/aiott/Downloads/comfy_docker_pack_app/comfyui-megapak-offline/scripts/install_nodes/install.sh --container comfyui-megapak list
```

> ⚠️ Команду `wsl` используйте **только снаружи WSL**. Внутри WSL вызывайте `bash` напрямую
> (иначе получите `Command 'wsl' not found`).

### 4.3 Без `--container` (интерактивный выбор)

Если контейнеров несколько — скрипт покажет меню.
Если один — спросит подтверждение `[Y/n]`.

---

## 5. Команды и опции

```
install.sh [опции] <действие> [аргументы]

Опции:
  --container, -c <имя>  Имя Docker-контейнера
  --live                 Стриминг git/pip в реальном времени (docker exec -it)
  --help, -h             Справка

Действия:
  install             Установить все ноды из nodes_list.txt
  install-one         Установить одну (интерактивно)
  uninstall [имя]     Удалить ноду (алиас или папка); без имени — интерактивно
  list                Показать установленные ноды
  self-test           Таблица алиас → папка → статус + список
```

---

## 6. Безопасность и guard'ы

Скрипт **отказывается** удалять, если:

- имя пустое,
- имя `.`, `..`, `/`,
- имя содержит `/`,
- путь после склейки выходит за пределы `custom_nodes`,
- нода не найдена в контейнере.

Пример:

```
$ bash install.sh --container comfyui-megapak uninstall ".."
✖ Недопустимое имя папки для удаления: '..'
exit=1
```

При провале `pip install` предлагается **rollback** — удалить только что клонированную папку.

---

## 7. Live-режим (`--live`)

По умолчанию `docker exec` буферизует вывод: `git clone`/`pip` показываются после завершения.
Для **живого построчного** отображения добавьте `--live` — скрипт использует `docker exec -it`.

| | Без `--live` | С `--live` |
|---|---|---|
| Вывод | по завершении команды | в реальном времени |
| Работа в `cron`/CI | ✅ | ❌ (нужен TTY) |
| Ctrl+C | прерывает | прерывает |

---

## 8. Персистентность: `docker save` / `docker load`

После успешной установки — сохраните снапшот:

```bash
# Сохранить контейнер в tar
docker save comfyui-megapak -o comfyui-$(date +%Y%m%d).tar

# Загрузить обратно (при необходимости)
docker load -i comfyui-20261019.tar
```

Храните такие tar-файлы рядом с `comfyui-megapak-offline-*.tar` (вне `custom_nodes`).

---

## 9. Troubleshooting

### `Command 'wsl' not found` внутри WSL
Вы уже **внутри** WSL. Используйте `bash scripts/install_nodes/install.sh ...`.
`wsl` — только снаружи (из CMD/PowerShell).

### `docker: command not found` / `docker ps` пуст
Docker Desktop не запущен или WSL Integration отключена.
**Docker Desktop → Settings → Resources → WSL Integration → включить для вашего дистрибутива.**

### `nodes_list.txt не найден`
Файл должен лежать **рядом с `docker-compose.yml`**, а не в `scripts/install_nodes/`.

### Имена нод с `\r` / «нода не находится»
Файл сохранён в Windows (CRLF). Скрипт очищает `\r` автоматически, но если вы
редактируете `nodes_list.txt` в Windows — сохраняйте в **UTF-8** и не добавляйте BOM.

### Нода клонировалась, но не загружается в ComfyUI
Проверьте `docker exec comfyui-megapak ls /root/ComfyUI/custom_nodes/<папка>`.
Если `requirements.txt` не установился — выполните `install-one` заново (rollback должен был удалить папку).

### `custom_nodes` не персистентен
Это **проектная архитектура**. После изменений делайте `docker save` (см. §8).

### `install.sh: Permission denied`
```bash
bash scripts/install_nodes/install.sh ...   # запускайте через bash, не ./install.sh
```
На `/mnt/c` (drvfs) бит `+x` может не сохраняться — это нормально для WSL.

---

## 10. Журнал изменений

| Версия | Что |
|--------|-----|
| v0.1 | Скелет, баннер, `--help`, проверка docker |
| v0.2b | Парсинг `nodes_list.txt` (CRLF, валидация), `basename URL` для папки, `self-test`, `list` |
| v0.3 | `install` / `install-one` / `uninstall`, `git clone` + `pip install`, интерактивный рестарт |
| v0.4 | `--live`, rollback при провале `pip`, `trap INT` |
| v0.5 | **Guard'ы `uninstall`** (пустое имя, `.`, `..`, `/`, склейка пути), warning про `docker save` (изоляция), фикс рестарта `y/n` |

---

## 11. Ограничения

- Windows-хосты: путь к проекту на `/mnt/c` — медленнее, чем ext4. Для больших `pip`-сборок
  рекомендуется держать проект на WSL-диске (`~/comfyui`).
- `--live` несовместим с неинтерактивным запуском (`cron`, CI).
- Скрипт **не** управляет `models/` — только `custom_nodes`.
- При `docker compose down` установленные ноды теряются без `docker save`.
