# Политика безопасности (Security Policy)

## Поддерживаемые версии

| Версия | Поддержка |
| ------ | --------- |
| 2.0.x  | ✅ Поддерживается |
| < 2.0  | ❌ Не поддерживается — обновитесь до последнего релиза |

## Как сообщить об уязвимости

Пожалуйста, **не публикуйте** уязвимости в открытых Issues.

1. Лучший способ — Private vulnerability reporting: вкладка **Security → Report a vulnerability** (владелец должен включить «Private vulnerability reporting» в Settings → Code security and analysis).
2. Если кнопка недоступна — создайте Security Advisory через вкладку Security либо свяжитесь с владельцем репозитория напрямую.

В отчёте укажите: версию LDManager (меню `[v] Информация о версиях`), версию Windows, шаги воспроизведения и ожидаемый vs фактический результат.

## Что считать уязвимостью в этом проекте

- Утечка или расшифровка GitHub-токена / `SIEVE_API_KEY`, хранящихся DPAPI-шифрованными в `LDManager.config.json`.
- Запуск произвольных команд в контексте пользователя, минуя явные действия пользователя в меню.
- Подмена загружаемых при автообновлении файлов (MITM): скрипт качает только с `raw.githubusercontent.com` / `github.com` по HTTPS.
- Любые скрытые сетевые соединения: их быть не должно — трафик только к `api.github.com`, `raw.githubusercontent.com`, `github.com` и `scrape.usesieve.com` и только по явным действиям пользователя.

## Не входит в скоуп

- Поведение самого эмулятора LDPlayer (сообщайте разработчикам LDPlayer).
- Социальная инженерия против пользователя (убедить что-то нажать).
- Автоматизированные отчёты сканеров без описания реального сценария эксплуатации.

## Сроки реакции

Первый ответ — в течение 7 дней. Обновление статуса — по мере работы над исправлением. После выпуска исправления публикуется релиз и, при необходимости, Security Advisory с указанием затронутых версий.

---

# Security Policy (English)

## Supported Versions

| Version | Supported |
| ------- | --------- |
| 2.0.x   | ✅ Supported |
| < 2.0   | ❌ Not supported — please update to the latest release |

## Reporting a Vulnerability

Please do **not** report vulnerabilities in public Issues.

1. Preferred: **Private vulnerability reporting** — Security → Report a vulnerability in this repository.
2. If unavailable, contact the repository owner directly.

When reporting, please include: LDManager version (menu `[v]` / Version info), Windows version, reproduction steps, and expected vs actual behavior.

## What counts as a vulnerability in this project

- Leakage or decryption of the GitHub token / `SIEVE_API_KEY` stored DPAPI-encrypted in `LDManager.config.json`.
- Arbitrary command execution in the user's context without explicit user actions in the menu.
- MITM substitution of files downloaded by self-update: the script only fetches from `raw.githubusercontent.com` / `github.com` over HTTPS.
- Any covert network connections: there should be none — traffic goes only to `api.github.com`, `raw.githubusercontent.com`, `github.com`, and `scrape.usesieve.com`, and only on explicit user actions.

## Out of scope

- Behavior of the LDPlayer emulator itself (report to LDPlayer developers).
- Social engineering against the user (convincing them to click something).
- Automated scanner reports without a real exploitation scenario.

## Response timeline

First response within 7 days. Status updates as the fix progresses. Once a fix ships, a release is published and, if warranted, a Security Advisory listing affected versions.
