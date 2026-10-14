# LDManager v2.0.3

Изменения с v2.0.2.

## Изменения

- Fix Invoke-Git: git stderr no longer fails the release script (97c9206)
- Add New-Release.ps1: one-command release flow (490c382)

## Обновление

Вариант 1 — в самом меню: [g] GitHub -> [3] Автообновление скрипта из GitHub.

Вариант 2 — вручную: скачайте ZIP релиза и замените LDManager.ps1, LDManager.core.ps1, LD.Sieve.ps1.

> После замены файлов, если включена строгая политика выполнения (AllSigned), подпишите скрипты заново через меню [s].

**Full Changelog:** https://github.com/genrihx2/ldplayer-Manager-CLI-Menu/compare/v2.0.2...v2.0.3