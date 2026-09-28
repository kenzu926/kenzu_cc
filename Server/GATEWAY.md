# Подключение ComputerCraft

Панель работает в демонстрационном режиме до указания URL шлюза в настройках. Сам браузер не может вызвать `peripheral` или `term` внутри Minecraft: нужен ваш HTTP-шлюз между CC:Tweaked и сайтом. Шлюз должен обслуживать `GET /snapshot`, `POST /command`, `POST /terminal` и разрешать CORS для адреса сайта. Используйте HTTPS для страницы, опубликованной через Sites.

## Периферия и измерения

| Поле снимка | Метод CC:Tweaked / Mekanism / Advanced Peripherals | Единица в JSON |
| --- | --- | --- |
| `reactor.active` | `fissionReactorLogicAdapter.getStatus()` | boolean |
| `reactor.water` | `getCoolantFilledPercentage()` | проценты 0–100 |
| `reactor.fuel` | `getFuelFilledPercentage()` | проценты 0–100 |
| `reactor.heated` | `getHeatedCoolantFilledPercentage()` | проценты 0–100 |
| `reactor.waste` | `getWasteFilledPercentage()` | проценты 0–100 |
| `reactor.heating` | `getHeatingRate()` | мБ/т |
| `reactor.temperature` | `getTemperature()` | K |
| `reactor.damage` | `getDamagePercent()` | проценты 0–100 |
| `reactor.burnRate`, `maxBurnRate` | `getBurnRate()`, `getMaxBurnRate()` | мБ/т |
| `matrix.energy`, `capacity` | `getEnergy()`, `getMaxEnergy()` | TFE (делить FE на 10¹²) |
| `matrix.input`, `output` | `getLastInput()`, `getLastOutput()` | FE/т |
| `turbines.generation` | `getProductionRate()` | MFE/т (делить FE/т на 10⁶) |
| `turbines.flow`, `maxFlow` | `getFlowRate()`, `getMaxFlowRate()` | мБ/т |
| `turbines.steam`, `steamCapacity` | `getSteam()`, `getSteamCapacity()` | одинаковые единицы объёма |
| `storage.items` | `meBridge.listItems()` | `name` (displayName), `id` (name), `count` (amount) |
| `storage.cells` | `meBridge.listCells()` | `name`, `used`, `capacity` |

Для `storage.used` и `storage.capacity` предпочтительны методы `getUsedItemStorage()` и `getTotalItemStorage()` ME Bridge. Ячейки `listCells()` в разных версиях Advanced Peripherals возвращают разные поля: шлюз должен вычислить заполненность для каждой ячейки и привести к одной шкале. Если эти сведения недоступны, показывайте пустой массив вместо выдуманной заполненности. История — массив `{time, temperature, generation}`; её хранит шлюз, CC API отдаёт текущие значения.

Все поля уровня в UI выражены процентами от 0 до 100. Если метод конкретной версии возвращает долю от 0 до 1, умножьте её на 100 в шлюзе. Для порога пара используйте заполненность парового резервуара турбины (`getSteamFilledPercentage()`) или бойлера, если в вашей схеме пар проходит через него; сам реактор не предоставляет отдельный `getSteamFilledPercentage()`.

`GET /snapshot` возвращает JSON с корневыми объектами `reactor`, `matrix`, `turbines`, `storage`, `history` в формате полей таблицы. `POST /command` принимает `{ "type": "reactor.scram" }`, `{ "type": "reactor.activate" }`, `{ "type": "reactor.setBurnRate", "value": 4.2 }`, `{ "type": "safety.set", "value": { "key": "water", "enabled": true, "threshold": 20 } }`. Соответствующие методы реактора: `scram()`, `activate()`, `setBurnRate(number)`. Перед включением шлюз должен проверять все активные пороги. Проверки безопасности выполняются непрерывно **в программе CC**, даже если веб-страница закрыта; `safety.set` должен сохранять их на стороне шлюза. Порог энергии и пара срабатывает при значении выше порога, воды и топлива — ниже.

`POST /terminal` получает `{ "input": "..." }` и возвращает `{ "output": "..." }`. Нужна отдельная программа на CC, которая принимает ввод и возвращает вывод. Веб-панель не имеет доступа к живому CraftOS без этого канала. Ограничьте доступ к шлюзу: конечные точки управления реактором и консоли нельзя открывать публично без аутентификации.

Методы и имена периферии зависят от установленной версии Mekanism и Advanced Peripherals в ATM9. Проверьте их через `peripheral.getNames()`, `peripheral.getMethods(name)` и тесты на своей сборке.
