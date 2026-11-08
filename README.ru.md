# Hysteria VPS Kit (кратко по-русски)

[English](README.md) · **Русский**

Установщик сервера Hysteria2 (QUIC поверх UDP, обфускация Salamander) и команда `hy2-client` для управления
клиентами. Полная документация на английском: [README.md](README.md).

## Часть семейства VPS-китов

`quality-vps-kit` — один из нескольких независимых инструментов одного процесса: сначала оценить VPS, затем поднять на нём VPN/proxy-сервисы.

| Проект | Назначение |
|---|---|
| [quality-vps-kit](https://github.com/thejohnd0e/quality-vps-kit) | read-only оценка нового VPS |
| [xray-vps-kit](https://github.com/thejohnd0e/xray-vps-kit) | установщик сервера VLESS/Reality и управление клиентами |
| [awg-vps-kit](https://github.com/thejohnd0e/awg-vps-kit) | установщик сервера AmneziaWG и управление клиентами |
| **hysteria-vps-kit** (этот репозиторий) | установщик сервера Hysteria2 и управление клиентами |

Киты независимы: ни один не изменяет и не требует остальных.

## Требования

Debian 12/13 или Ubuntu 22.04/24.04, systemd и apt, root, публичный IPv4 и открытый **UDP**-порт (по умолчанию 443;
откройте его и в файрволе хостера), около 100 МБ свободной памяти, amd64 или arm64 (arm64 нативно не проверялся).

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/hysteria-vps-kit/master/install.sh | bash -s -- --first-client one_us
```

Скрипт скачивает зафиксированное ядро Hysteria2 и **проверяет его SHA-256**, создаёт системного пользователя,
самоподписанный сертификат, сервис `hysteria-vps-kit` и печатает URI и QR-код первого клиента. Все опции:
[README.md](README.md).

## Клиенты

```bash
hy2-client add phone          # новый клиент со своим паролем, печатает URI
hy2-client list
hy2-client show phone         # URI hysteria2://
hy2-client show phone --qr    # QR-код
hy2-client remove phone
hy2-client doctor             # диагностика без изменений
```

На машине, где работает клиент Hysteria2, задайте `net.core.rmem_max = 7500000` и
`net.core.wmem_max = 7500000`: при буфере по умолчанию ядро теряет QUIC-пакеты, это видно как зависания под нагрузкой.

## Обновление и удаление

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/hysteria-vps-kit/master/update.sh | bash
bash /opt/hysteria-vps-kit-src/uninstall.sh   # --keep-config сохраняет ключи и клиентов, --yes без вопросов
```
