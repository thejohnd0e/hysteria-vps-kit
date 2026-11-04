# Этап 2, первая итерация: мелочи после 0.2.0 + `hy2-client doctor`

> **Для исполнителя:** работать по задачам последовательно. Каждая задача заканчивается проверкой и коммитом. Реализацию начинать только после подтверждения плана.

**Цель:** закрыть мелкие дефекты, найденные при проверке 0.2.0, и добавить `hy2-client doctor` — диагностику без изменения состояния и без вывода секретов.

**Архитектура:** диагностика живёт в `hy2-client` и использует существующие помощники `lib/common.sh`; для сверки конфига добавляется чистая функция рендера в произвольный файл. Серверные проверки (systemd, порт, sysctl, ufw) выполняются только на реальной установке, в sandbox-режиме (`HVK_ROOT`) помечаются `SKIP`.

**Технологии:** Bash, jq, OpenSSL, systemd, `ss`, `sysctl`, `ufw` при наличии; sandbox-тесты `tests/run.sh`.

**Основание:** `docs/superpowers/plans/2026-11-04-reliability-and-roadmap.md`, этап 2 (первый пункт — `doctor`), плюс остаток замечаний из проверки 0.2.0 (`STATUS.md`, запись от 2026-11-04).

## Общие ограничения

- Основная ветка `master`; перед работой прочитать `AGENTS.md`, `STATUS.md`, `DECISIONS.md`, `TODO.md`.
- Никаких изменений на действующих серверах в рамках этой итерации.
- `doctor` ничего не создаёт, не перезапускает и не переписывает. Единственный временный файл — конфиг для сверки, удаляется в любом исходе.
- Не печатать пароли клиентов, пароль обфускации, приватный ключ и URI. Pin сертификата не печатать, только результат сравнения.
- Сохранять стиль: сообщения `[hysteria-vps-kit]`, ошибки через `hvk_die`.
- ShellCheck-чистота, тесты на Linux.

## Файлы

| Файл | Изменение |
|---|---|
| `hy2-client` | подкоманда `doctor`, текст usage |
| `lib/common.sh` | `hvk_render_config_to`, вспомогательные проверки |
| `install.sh` | запрет `--force-secrets` без `--repair` |
| `update.sh` | удаление старых `.backup-update.*` после успеха |
| `tests/run.sh` | новые проверки |
| `README.md` | `doctor`, актуальный список suite'ов |

## Решения, принятые за исполнителя

- Формат вывода: `[ OK ]`, `[WARN]`, `[FAIL]`, `[SKIP]`, по строке на проверку, итоговая строка `doctor: N ok, M warnings, K failures`.
- Код возврата: `0` — нет `FAIL`; `1` — есть хотя бы один `FAIL`; `2` — ошибка использования.
- `WARN` не делает код возврата ненулевым. Флага `--strict` не добавляем (YAGNI).
- В режиме `HVK_ROOT` (sandbox) проверки systemd, реального UDP-порта, эффективных sysctl и ufw печатаются как `SKIP`.
- `doctor` требует root: state.json доступен только root, иначе проверки бессмысленны.
- Старые `.backup-update.*` удаляются после успешного обновления, если им больше 7 дней.
- Пункт «`remove` при сбое записи state» из проверки 0.2.0 перепроверен и **снят**: `hvk_state_update` при ошибке вызывает `hvk_die` и завершает процесс, поэтому обработчик `fail_closed_remove` в этой ветке не выполняется и служба не останавливается. Менять поведение не нужно.

---

### Task 1: `--force-secrets` только вместе с `--repair`

**Files:** `install.sh`, `tests/run.sh`

**Interfaces:**
- Produces: поведение CLI — `install.sh --force-secrets` без `--repair` завершается кодом 2 и сообщением об ошибке.

- [x] **Step 1: Тест**

В `suite_validation`:
```bash
refuse 'force-secrets requires repair' bash "$project/install.sh" --no-service --root "$sandbox" --non-interactive --force-secrets
```

- [x] **Step 2: Убедиться, что тест падает**

Run: `bash tests/run.sh --suite validation`
Expected: FAIL — установка проходит, хотя флаг бессмысленен.

- [x] **Step 3: Реализация**

После разбора аргументов, рядом с проверками `--root`/`--no-service`:
```bash
if (( force_secrets && ! repair )); then
    printf 'error: --force-secrets requires --repair\n' >&2; exit 2
fi
```

- [x] **Step 4: Проверка**

Run: `bash tests/run.sh --suite validation`
Expected: PASS, остальные проверки suite без изменений.

- [x] **Step 5: Коммит**

```bash
git add install.sh tests/run.sh
git commit -m "install.sh: reject --force-secrets without --repair"
```

---

### Task 2: не копить резервные копии неудачных обновлений

**Files:** `update.sh`, `tests/run.sh`

**Interfaces:**
- Consumes: каталог `$HVK_ETC/.backup-update.*`, создаваемый в `update.sh`.
- Produces: после успешного обновления каталоги старше 7 дней удаляются; свежая копия текущего запуска удаляется как сейчас.

- [x] **Step 1: Тест**

В `suite_update` после успешного обновления создать поддельный старый каталог и проверить, что он исчез:
```bash
mkdir -p "$E/.backup-update.old"
touch -d '10 days ago' "$E/.backup-update.old"
# затем выполнить успешное обновление (version = 0.0.9 -> 0.2.0)
refuse 'old backup directory pruned after successful update' test -d "$E/.backup-update.old"
```
Свежий каталог, созданный неудачным обновлением, не удалять: отдельная проверка — после сбоя `find "$E" -name '.backup-update.*' | wc -l` ≥ 1 (уже есть).

- [x] **Step 2: Убедиться, что тест падает**

Run: `bash tests/run.sh --suite update`
Expected: FAIL — старый каталог на месте.

- [x] **Step 3: Реализация**

В конце успешного пути, рядом с `rm -rf "$backup_dir"`:
```bash
find "$HVK_ETC" -maxdepth 1 -type d -name '.backup-update.*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true
```

- [x] **Step 4: Проверка**

Run: `bash tests/run.sh --suite update`
Expected: PASS.

- [x] **Step 5: Коммит**

```bash
git add update.sh tests/run.sh
git commit -m "update.sh: prune stale update backups after success"
```

---

### Task 3: `hy2-client doctor`

**Files:** `lib/common.sh`, `hy2-client`, `tests/run.sh`

**Interfaces:**
- Produces в `lib/common.sh`:
  - `hvk_render_config_to PATH` — пишет конфиг в `PATH`, не меняя рабочий `config.yaml`; возвращает 0/1.
  - `hvk_render_config()` — обёртка: `hvk_render_config_to "$HVK_CONFIG.new"`, права 640, `mv`, `chown` (поведение не меняется).
- Produces в `hy2-client`: `doctor` с описанным ниже набором проверок и кодами возврата.

**Проверки `doctor`** (в этом порядке):

| # | Проверка | FAIL | WARN | SKIP |
|---|---|---|---|---|
| 1 | `state.json` читается и проходит `hvk_validate_state` | ошибка | | |
| 2 | ядро: файл исполняемый, `version` запускается, версия содержит `state.core` | да | | |
| 3 | unit существует, `ExecStart` содержит `$HVK_CORE_BIN` и `$HVK_CONFIG` | да | | |
| 4 | служба `is-active` и `is-enabled` | да | | `HVK_ROOT` |
| 5 | `config.yaml` существует; рендер из state совпадает с файлом | расхождение | права не 640 | |
| 6 | сертификат и ключ существуют; ключ соответствует сертификату; pin в state совпадает | да | | |
| 7 | обфускация: если `enabled`, пароль непустой и блок есть в конфиге | да | | |
| 8 | клиенты: `state.clients` непустой; имена валидны (покрыто п.1) | | 0 клиентов | |
| 9 | порт: `hvk_valid_port`, UDP слушает `state.port` | не слушает | | `HVK_ROOT` |
| 10 | sysctl: файл совпадает с ожидаемым; эффективные `rmem_max`/`wmem_max` ≥ 7500000 | | ниже нормы / файла нет | `HVK_ROOT` |
| 11 | endpoint: валиден; не `YOUR_SERVER_IP`; не приватный | | да | |
| 12 | firewall: `ufw` активен и правило для порта есть; при `state.firewall == ufw` правило обязательно | | нет правила | `HVK_ROOT` |
| 13 | версия kit: `VERSION` совпадает с `state.version` | | расхождение | |

- [x] **Step 1: Тест «здоровый sandbox»**

```bash
new_root; install_sandbox --first-client main-user >/dev/null
check 'doctor succeeds on a healthy sandbox' hy doctor
check 'doctor reports no failures' bash -c "HVK_ROOT=$sandbox bash '$project/hy2-client' doctor | grep -c '^\\[FAIL\\]' | grep -qx 0"
check 'doctor skips system checks in sandbox' bash -c "HVK_ROOT=$sandbox bash '$project/hy2-client' doctor | grep -q '^\\[SKIP\\] service'"
refuse 'doctor does not print secrets' bash -c "HVK_ROOT=$sandbox bash '$project/hy2-client' doctor | grep -q \"$(jq -r '.clients[\"main-user\"]' "$sandbox/etc/hysteria-vps-kit/state.json")\""
```

- [x] **Step 2: Тесты на дефекты**

```bash
rm -f "$sandbox/etc/hysteria-vps-kit/server.key"
refuse 'doctor fails without the key' hy doctor
check 'doctor names the key problem' bash -c "HVK_ROOT=$sandbox bash '$project/hy2-client' doctor | grep -q 'certificate/key'"
```

Плюс: подменить pin в state → `refuse`; изменить `config.yaml` (добавить строку) → `refuse`; удалить клиента из state → `WARN` и код 0.

- [x] **Step 3: Убедиться, что тесты падают**

Run: `bash tests/run.sh --suite doctor`
Expected: команда `doctor` не существует, suite падает.

- [x] **Step 4: Реализация `hvk_render_config_to`**

Вынести текущий блок рендера в функцию с параметром пути; `hvk_render_config` вызывает её с `$HVK_CONFIG.new` и делает `chmod`/`mv`/`chown`. Никаких изменений в содержимом конфига.

- [x] **Step 5: Реализация `doctor`**

Добавить в `hy2-client` ветку `doctor)` и функцию `doctor()`; вывод строго по формату; временный файл сверки создавать через `mktemp` и удалять `trap`-ом. В `HVK_ROOT`-режиме печатать `[SKIP]` для проверок 4, 9, 10, 12.

- [x] **Step 6: Проверка**

Run: `bash tests/run.sh --suite doctor`
Expected: PASS.

Run: `bash tests/run.sh`
Expected: все suite зелёные (было 120 проверок).

- [x] **Step 7: Коммит**

```bash
git add lib/common.sh hy2-client tests/run.sh
git commit -m "hy2-client: add doctor diagnostics"
```

---

### Task 4: README, usage и проверка на VM

**Files:** `README.md`, `hy2-client` (usage), `STATUS.md`, `TODO.md`

- [x] **Step 1: README**

Добавить в раздел Clients:
```bash
hy2-client doctor          # read-only diagnostics; exit 1 if a check failed
```
Обновить список suite'ов: `validation, install, render, clients, locking, repair, update, uninstall, doctor`.

- [x] **Step 2: Usage**

В `hy2-client help` добавить строку про `doctor` и пояснение, что команда ничего не меняет.

- [x] **Step 3: Реальная проверка на Debian 13 VM**

Установить kit, выполнить `hy2-client doctor` (ожидается код 0), затем по одному сломать и восстановить: остановить службу, удалить ключ, изменить pin, испортить `config.yaml`, снизить `rmem_max`. Для каждого случая зафиксировать `FAIL`/`WARN` и код возврата. В конце удалить установку.

- [x] **Step 4: Документы**

Записать в `STATUS.md` результат проверки, в `TODO.md` — что закрыто. Если `doctor` меняет представление о состоянии проекта — строку в `DECISIONS.md`.

- [x] **Step 5: Коммит**

```bash
git add README.md hy2-client STATUS.md TODO.md
git commit -m "docs: document doctor and refresh test suite list"
```

---

## Критерии готовности

- `bash tests/lint.sh` — чисто.
- `bash tests/run.sh` — все suite зелёные, включая новый `doctor`.
- `doctor` на здоровой установке даёт код 0 и не печатает секретов; на каждом из перечисленных дефектов — ожидаемые `FAIL`/`WARN`.
- Реальная проверка на Debian 13 VM выполнена.
- Документация описывает `doctor` и актуальный список suite'ов.
- Действующие серверы не изменялись.

## Вне рамок

`backup`/`restore`, `rotate`, `port`, `logs`, IPv6, статистика, port hopping, ECH, разделение `common.sh` на модули.
