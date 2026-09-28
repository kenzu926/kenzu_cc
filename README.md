# Kenzu CC

Панель управления базой ATM9. CC:Tweaked-компьютеры собирают телеметрию
Mekanism и Applied Energistics 2, а домашний Node.js-сервер отображает её в
React-интерфейсе.

## Возможности

- `Matrix` — `inductionPort_0`: заряд, запас, ёмкость, вход, выход и чистый поток энергии.
- `Reactor` — состояние реактора, температура, повреждения, топливо, охлаждение,
  отходы, burn rate и управление порогами.
- `Turbines` — готовая вкладка и служба для будущих Mekanism Turbine Valve.
- `Storage` — поиск, счётчики и карточки предметов с Minecraft-иконками.
- `Consoles` — безопасные удалённые диагностические консоли для CC-компьютеров.
- Rednet-реле для ME-ноды, если она не может подключиться к сайту напрямую.

## Структура

- `Program/` — Lua-программы CC:Tweaked.
- `Server/` — Node.js WebSocket-сервер и React-панель.

Основные Lua-службы:

- `startup.lua` определяет подключённые периферийные устройства и запускает службы;
- `reactor.lua` управляет реактором и Induction Matrix;
- `me_node.lua` читает ME Bridge и отправляет склад;
- `turbine.lua` автоматически запускается при обнаружении Turbine Valve;
- `console.lua` содержит только безопасные диагностические команды;
- `ws_client.lua` поддерживает необязательное соединение с сайтом.

## Запуск сайта на домашнем ПК

Сервер слушает все сетевые интерфейсы на `0.0.0.0:3000`.

```powershell
cd D:\CC\Server
npm ci
npm run build
$env:CC_AUTH_TOKEN="replace-with-a-long-random-secret"
npm start
```

Токен должен содержать не менее 24 символов. Используйте одно и то же значение
для Node.js-сервера, сайта и установщика CC.

Адреса:

- локально: `http://localhost:3000`;
- через интернет: `http://93.170.246.220:3000`;
- проверка: `http://93.170.246.220:3000/health`.

Для внешнего доступа пробросьте TCP-порт `3000` на домашний ПК. Команда для
Windows Firewall запускается в PowerShell от имени администратора:

```powershell
New-NetFirewallRule -DisplayName "Kenzu CC Web" -Direction Inbound -Protocol TCP -LocalPort 3000 -Action Allow
```

Дополнительный порт в панели minecraft-hosting.net не требуется: CC создаёт
исходящее подключение к домашнему ПК. Настройка `[http.proxy] port = 8080` к
этому сайту не относится.

## Установка и обновление CC

Сначала сделайте commit и push папки `Program/`. Затем выполните на каждом
CC-компьютере:

```text
wget run https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/Program/installer.lua ws://93.170.246.220:3000/ws replace-with-the-same-secret
reboot
```

Замените `replace-with-the-same-secret` на значение `CC_AUTH_TOKEN`.
Установщик скачивает весь проект и сохраняет адрес с токеном в
`server.settings`.

Роли определяются автоматически:

- Induction Port + Fission Reactor Logic Adapter + Monitor → Reactor;
- ME Bridge или AE2 Controller → ME Node;
- Mekanism Turbine Valve → Turbine.

На одном Advanced Computer могут одновременно запускаться несколько подходящих
служб во вкладках multishell.

## ME Storage и Rednet-реле

ME-нода отправляет склад напрямую через WebSocket и одновременно через Rednet.
Если прямой интернет недоступен, компьютер реактора пересылает данные на сайт.

```text
Web uplink: REDNET RELAY
Storage: Sent 123 item types
```

Такое состояние является нормальным. Поддерживаются оба API Advanced
Peripherals: `listItems()` из 0.7 и `getItems({})` из 0.8.

## Удалённые консоли

Консоли специально не выполняют произвольный Lua или shell-код, чтобы команда с
сайта не могла остановить локальную защиту реактора. Доступны команды:

```text
help
status
peripherals
methods <peripheral_name>
id
uptime
clear
```

Команды для ME-ноды также работают через Rednet-реле.

## Работа без сайта

Node.js-сервер не участвует в принятии решений о запуске и остановке реактора.
При недоступном сайте продолжают работать:

- включение и SCRAM по локальным порогам;
- монитор и его кнопки;
- сохранённые настройки;
- Rednet-связь с ME-нодой.

После восстановления сайта WebSocket-клиенты переподключаются автоматически.

## Безопасность

Токен обязателен для сайта, API и CC-клиентов. Обычные `http://` и `ws://` не
шифруют трафик, поэтому для постоянного публичного доступа рекомендуется домен,
HTTPS reverse proxy и `wss://`.
