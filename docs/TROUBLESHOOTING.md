# Troubleshooting — грабли, на которые мы уже наступили

Реальные проблемы при развёртывании Hermes Agent на Ubuntu 26.04 VPS
(aeza, шаблон `openclaw`) и как они решались.

## Respawn storm: «Another gateway instance is already running»

**Симптом.** В `~/.hermes/logs/errors.log` каждые 10–20 секунд:
```
ERROR gateway.run: Another gateway instance is already running (PID NNNNN)
WARNING hermes_cli.gateway: Gateway (re)started 7 times in 120s — backing off 20s
```
При этом `systemctl status hermes-gateway` показывает `active (running)`, а
`ps -ef --forest` не находит второго процесса — потому что нарушитель живёт
миллисекунды и умирает до того, как вы успеете его снять.

**Причина — самодельный системный юнит.** У Hermes есть штатная команда
`hermes gateway install`, которая ставит **пользовательский** сервис
(`systemctl --user`, логи через `journalctl --user -u hermes-gateway`). Если
поверх завести свой **системный** юнит с тем же именем, получаются два юнита
в разных пространствах:

- пользовательский, штатный — `~/.config/systemd/user/`,
  «Hermes Agent Gateway - Messaging Platform Integration»
- системный, самодельный — `/etc/systemd/system/`,
  «Hermes Agent Telegram Gateway»

Один захватывает блокировку шлюза, второй бесконечно ломится за ней.

**Диагностика.** `grep -rl hermes /etc/systemd/system/` покажет только
системные юниты и создаст ложное ощущение, что всё чисто. Смотреть надо оба
пространства:
```bash
systemctl --user list-units --no-pager
grep -rl hermes /etc/systemd/system/
```

**Решение — не городить свой юнит.** Использовать штатный механизм:
```bash
hermes gateway install
hermes gateway start
hermes gateway status
```

Единственная причина, по которой хочется системный юнит — пользовательские
сервисы не стартуют, пока пользователь не вошёл в систему, то есть не
переживают перезагрузку. Это решается не своим юнитом, а lingering:
```bash
loginctl enable-linger root
```

Если самодельный юнит уже стоит — снести его и вернуться на штатный:
```bash
systemctl stop hermes-gateway
systemctl disable hermes-gateway
rm /etc/systemd/system/hermes-gateway.service
systemctl daemon-reload
hermes gateway install
loginctl enable-linger root
```

## Playwright: «does not support chromium on ubuntu26.04-x64»

Ubuntu 26.04 слишком новая для Playwright 1.58.2. Штатный обход — подсунуть
бинарники 24.04:
```bash
PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 \
  /usr/local/lib/hermes-agent/node_modules/.bin/playwright install --with-deps chromium
```
См. [microsoft/playwright#40117](https://github.com/microsoft/playwright/issues/40117).

## Playwright виснет на «extracting archive»

Известная несовместимость с Node 26. Hermes держит свой Node в
`~/.hermes/node`. Проверить: `~/.hermes/node/bin/node --version`. Если 26 —
заменить на 22 (скачивать с nodejs.org напрямую; GitHub raw может отдавать
429):
```bash
cd /tmp
curl -fsSLO https://nodejs.org/dist/v22.23.2/node-v22.23.2-linux-x64.tar.xz
tar -xf node-v22.23.2-linux-x64.tar.xz
mv /root/.hermes/node /root/.hermes/node.v26.bak
mv /tmp/node-v22.23.2-linux-x64 /root/.hermes/node
```

## systemd-юнит падает с exit-code 1 сразу после старта

Если шлюз уже запущен вручную, `gateway run` отказывается стартовать вторым
экземпляром и выходит с кодом 1 — systemd уходит в цикл перезапусков. Лечится
флагом `--replace` в `ExecStart` (см. `hermes-config/hermes-gateway.service`).

## `uv.lock needs to be updated, but --locked was provided`

Инсталлятор обрабатывает это сам: падает на hash-verified tier и откатывается
на PyPI resolve (`falling back to PyPI resolve...` → `Main package installed`).
Вмешательство не требуется.

## Агент отчитывается об успехе, ничего не сделав

Если провайдер модели не поддерживает tool-calling, агент физически не может
писать файлы и выполнять команды — но об этом не знает и рапортует об успехе.
Проверяется по логу:
```
openai.UnprocessableEntityError: Error code: 422
  'unsupported_parameters': ['tools']
  'missing_capability_profiles': ['tools_implicit']
```
Лечится только сменой провайдера на поддерживающего `tools`. Пополнение
баланса у провайдера без tool-calling не поможет.

## VNC-консоль калечит ввод

В веб-консоли VNC вставка эмулируется нажатиями клавиш. При русской раскладке
теряются `|`, `>` и другие символы с Shift — команды молча выполняются не так,
как выглядят. Не диагностируется по виду команды, только по странным ошибкам
вида `unexpected argument`, `process ID list syntax error`.

Работать по SSH (в Windows встроен: `ssh root@HOST`), файлы передавать через
`scp`, а не вставкой в терминал.
