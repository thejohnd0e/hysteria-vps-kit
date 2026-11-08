# Выравнивание серии kit-проектов (hysteria / xray / awg)

> **Статус:** черновик плана, код не менялся. Основание: сравнение локальных копий `D:\MyProjects\{hysteria,xray,awg}-vps-kit` от 2026-11-08 (xray на 5 коммитов впереди `origin`, в awg изменён `.gitattributes`).

**Цель:** чтобы три проекта (`hysteria-vps-kit` 0.2.2, `xray-vps-kit` 0.1.1, `awg-vps-kit` 1.2.0) выглядели и вели себя одинаково там, где это не продиктовано протоколом.

## Что уже общее

- Файлы: `install.sh`, `update.sh`, `uninstall.sh`, `<имя>-client`, `VERSION`, `README.md`, `tests/run.sh`, `tests/lint.sh`, CI.
- Команды клиента: `add`, `remove`, `list`, `show`, `version`, `help`.
- Bootstrap `curl | bash` с клоном в `/opt/<имя>-src`; `uninstall --keep-config`; `flock`; песочница `--no-service --root`.
- Служебные `AGENTS.md`, `CLAUDE.md`, `STATUS.md`, `DECISIONS.md`, `TODO.md` не публикуются.

## Расхождения

| Область | hysteria | xray | awg |
|---|---|---|---|
| Код | `lib/common.sh` | `lib/` ~30 модулей | монолитные скрипты |
| Откат/транзакции | откат при сбое | журнал, снимки, `recover` | только `peer.*` |
| `doctor` | есть | есть | нет (есть `awg-watchdog`) |
| Восстановление | `install.sh --repair` | `recover`, `--restore` | нет |
| Учёт ресурсов | `created_resources` | `ownership` | нет |
| Версия ядра | SHA-256 в `common.sh` | `releases/xray.lock.json` + workflow | сборка из git |
| Версия кита | всегда `master` | `XVK_REF` | всегда `master` |
| `uninstall --yes` | есть | есть | нет |
| `CHANGELOG`/`SECURITY` | нет | есть | нет |
| CI | lint + Ubuntu 22.04/24.04 | + job `debian` | lint + install-test, только 24.04 |
| Имя клиента | `A-Za-z0-9_.@-` ≤32 | похоже | `A-Za-z0-9_-` ≤32 |

Оправданные различия (не выравнивать): AWG добавляет клиентов без рестарта, Hysteria2 перезапускается; у Xray нет паролей, у Hysteria2 нет ключей REALITY; `block-ping` живёт в xray/awg, в hysteria сознательно вне проекта.

## Общий контракт (предлагается)

1. **Файлы:** `lib/common.sh` (или `lib/`), `CHANGELOG.md`, `SECURITY.md`, `releases/*.lock.json` для внешних бинарников.
2. **Команды клиента:** общие `add/remove/list/show/version/help/doctor`; специфичные команды проекта сверх этого.
3. **`update.sh`:** общие `--check` (код 10 = есть обновление) и `--no-restart`; специфичные флаги остаются.
4. **`uninstall.sh`:** `--keep-config`, `--yes`; после `--keep-config` состояние восстанавливается через `install.sh --repair`.
5. **Состояние:** JSON с полями `version`, `status` (`ready|installing|updating|uninstalled`), `created_resources`; секреты 0600.
6. **Версии:** git-теги на каждый релиз; `<X>VK_REF` для bootstrap (по умолчанию последний тег); `update.sh --check` сравнивает теги.
7. **CI:** lint + матрица Ubuntu 22.04/24.04 + (по возможности) проверка конфига настоящим ядром.
8. **Гигиена:** `__pycache__/` и черновики в `.gitignore`; нет закоммиченных артефактов.

## Задачи по проектам

### hysteria-vps-kit
- [x] `CHANGELOG.md`, `SECURITY.md`.
- [x] Теги релизов и `HVK_REF` (v0.2.3).
- [x] `releases/hysteria.lock.json` + `tools/update-lock.sh` (константы в `common.sh` остаются, тест сверяет их с lock-файлом, чтобы не требовать jq при bootstrap).
- [ ] `update.sh --no-restart`.
- [x] CI: `tests/core-config.sh` (настоящее ядро).

### xray-vps-kit
- [ ] Убрать из git `tests/helpers/__pycache__/*.pyc`, добавить `__pycache__/` в `.gitignore`; убрать `аудит.txt` из корня.
- [ ] Исправить шапку `block-ping` (ссылка на неверный репозиторий).
- [ ] Теги релизов (при `VERSION` 0.1.1 тегов нет).
- [ ] Остальное — по `IMPROVEMENTS.md` проекта.

### awg-vps-kit
- [ ] `uninstall.sh --yes`.
- [ ] `awg-client doctor` (поверх логики `awg-watchdog`), без вывода ключей.
- [ ] Учёт созданных ресурсов (пользователь/правила/файлы) для чистого удаления.
- [ ] Вынести общие функции в `lib/common.sh`.
- [ ] Теги и `AVK_REF`; `CHANGELOG.md`, `SECURITY.md`.
- [ ] CI: матрица Ubuntu 22.04/24.04.

## Порядок

1. Завершить hysteria (эталон: самый свежий по надёжности, меньше xray по размеру).
2. Гигиена xray (мелкие правки).
3. awg: `--yes`, `doctor`, ресурсы, `lib/`.
4. Теги и `*_REF` во всех трёх одним проходом.

## Ограничения

- Каждый репозиторий меняется отдельным коммитом; не трогать действующие серверы.
- Не копировать учётные данные лабораторных ВМ в репозитории.
- Перед правками в xray учесть 5 неопубликованных коммитов и `IMPROVEMENTS.md`.
