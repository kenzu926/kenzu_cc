import { useEffect, useMemo, useRef, useState } from "react";

const initialState = {
  matrix: { online: false, data: null },
  reactor: { online: false, data: null },
  turbines: [],
  storage: { online: false, connected: false, items: [], metrics: {} },
  computers: {},
  terminals: {},
  consoleHistory: [],
  lastCommand: null,
};

const icons = {
  overview: "M4 4h7v7H4zm9 0h7v4h-7zM4 13h7v7H4zm9-3h7v10h-7z",
  reactor:
    "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 3 2.3 4H9.7L12 5zm-6 9 2.3-4 2.3 4H6zm6 5-2.3-4h4.6L12 19zm3.4-5 2.3-4L20 14h-4.6z",
  matrix: "M5 3h14v18H5zm3 3v12h8V6zm2 2h4v5h-4z",
  turbine:
    "M12 2a3 3 0 0 1 2.5 4.65l3.92-1.13 1.5 2.6-3 2.9A3 3 0 0 1 14 15.8L13 20h-3l-1-4.2A3 3 0 0 1 7.08 11l-3-2.88 1.5-2.6L9.5 6.65A3 3 0 0 1 12 2zm0 8a2 2 0 1 0 0 4 2 2 0 0 0 0-4z",
  storage:
    "M3 5l9-3 9 3v14l-9 3-9-3zm3 2v10l6 2 6-2V7l-6 2-6-2zm1-1 5 1.7L17 6l-5-1.7z",
  terminal:
    "M3 4h18v16H3zm2 2v12h14V6H5zm2 3 3 3-3 3-1.4-1.4L7.2 12l-1.6-1.6L7 9zm4 5h5v2h-5z",
  search:
    "M10 3a7 7 0 1 0 4.9 12l4.05 4.05 1.4-1.4-4.05-4.05A7 7 0 0 0 10 3zm0 2a5 5 0 1 1 0 10 5 5 0 0 1 0-10z",
  shield:
    "M12 2 4 5v6c0 5 3.4 9.7 8 11 4.6-1.3 8-6 8-11V5zm0 3.1 5 1.8V11c0 3.5-2.1 6.8-5 7.9C9.1 17.8 7 14.5 7 11V6.9z",
};

function Icon({ name, size = 19 }) {
  return (
    <svg
      className="icon"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path d={icons[name]} />
    </svg>
  );
}

const clamp = (value, min = 0, max = 100) =>
  Math.max(min, Math.min(max, Number(value || 0)));

function formatCompact(value, suffix = "") {
  const number = Number(value || 0);
  const units = ["", " тыс.", " млн", " млрд", " трлн"];
  let scaled = Math.abs(number);
  let index = 0;
  while (scaled >= 1000 && index < units.length - 1) {
    scaled /= 1000;
    index += 1;
  }
  return `${number < 0 ? "−" : ""}${scaled.toLocaleString("ru-RU", { maximumFractionDigits: 2 })}${units[index]}${suffix}`;
}

function formatEnergy(value) {
  const number = Number(value || 0);
  const units = ["FE", "kFE", "MFE", "GFE", "TFE", "PFE", "EFE"];
  let scaled = Math.abs(number);
  let index = 0;
  while (scaled >= 1000 && index < units.length - 1) {
    scaled /= 1000;
    index += 1;
  }
  return `${number < 0 ? "−" : ""}${scaled.toLocaleString("ru-RU", { maximumFractionDigits: 2 })} ${units[index]}`;
}

const formatRate = (value) => `${formatEnergy(value)}/t`;
function formatFluid(value) {
  const amount = Number(value || 0);
  if (amount >= 1_000_000)
    return `${(amount / 1_000_000).toLocaleString("ru-RU", { maximumFractionDigits: 2 })}M mB`;
  if (amount >= 1_000)
    return `${(amount / 1_000).toLocaleString("ru-RU", { maximumFractionDigits: 2 })}k mB`;
  return `${amount.toLocaleString("ru-RU", { maximumFractionDigits: 0 })} mB`;
}

function Status({ online, children }) {
  return (
    <span className={`status ${online ? "online" : "offline"}`}>
      <i />
      {children}
    </span>
  );
}
function PageTitle({ eyebrow, title, description, status }) {
  return (
    <div className="page-title">
      <div>
        <p className="eyebrow">{eyebrow}</p>
        <h1>{title}</h1>
        {description && <p>{description}</p>}
      </div>
      {status}
    </div>
  );
}
function Card({ className = "", children }) {
  return <section className={`card ${className}`}>{children}</section>;
}
function CardHeader({ title, subtitle, action }) {
  return (
    <div className="card-header">
      <div>
        <h2>{title}</h2>
        {subtitle && <p>{subtitle}</p>}
      </div>
      {action}
    </div>
  );
}
function Metric({ label, value, hint, tone = "" }) {
  return (
    <div className={`metric ${tone}`}>
      <span>{label}</span>
      <strong>{value}</strong>
      {hint && <small>{hint}</small>}
    </div>
  );
}
function Progress({ value, tone = "cyan" }) {
  return (
    <div className={`progress ${tone}`}>
      <span style={{ width: `${clamp(value)}%` }} />
    </div>
  );
}

function Sparkline({ points, field, color = "#49c7f2", height = 112 }) {
  const values = points.map((point) => Number(point[field] || 0));
  const min = Math.min(0, ...values);
  const max = Math.max(1, ...values);
  const range = max - min || 1;
  const line = values
    .map(
      (value, index) =>
        `${values.length < 2 ? 0 : (index / (values.length - 1)) * 100},${58 - ((value - min) / range) * 52}`,
    )
    .join(" ");
  const area = line ? `0,60 ${line} 100,60` : "";
  return (
    <svg
      className="sparkline"
      viewBox="0 0 100 60"
      preserveAspectRatio="none"
      style={{ height }}
    >
      <path d="M0 58H100M0 32H100M0 6H100" />
      <polygon points={area} style={{ fill: `${color}18` }} />
      <polyline points={line} style={{ stroke: color }} />
    </svg>
  );
}

function Ring({ value, label, color = "#49c7f2", children }) {
  const percent = clamp(value);
  return (
    <div className="ring-wrap">
      <div
        className="ring"
        style={{ "--value": `${percent * 3.6}deg`, "--ring": color }}
      >
        <div>
          <strong>{percent.toFixed(1)}%</strong>
          <span>{label}</span>
        </div>
      </div>
      {children}
    </div>
  );
}

function Overview({ state, matrixHistory, reactorHistory, setTab }) {
  const matrix = state.matrix.data || {};
  const reactor = state.reactor.data || {};
  const turbines = state.turbines || [];
  const onlineTurbines = turbines.filter((unit) => unit.online);
  const generation = onlineTurbines.reduce(
    (sum, unit) => sum + Number(unit.data?.production || 0),
    0,
  );
  const totalItems = (state.storage.items || []).reduce(
    (sum, item) => sum + Number(item.count || 0),
    0,
  );
  const services = Object.values(state.computers || {});
  const onlineServices = services.filter((service) => service.online).length;
  return (
    <>
      <PageTitle
        eyebrow="ЦЕНТР УПРАВЛЕНИЯ"
        title="Обзор системы"
        description="Энергия, генерация и инфраструктура базы в реальном времени"
        status={
          <Status online={state.matrix.online && state.reactor.online}>
            Система{" "}
            {state.matrix.online && state.reactor.online
              ? "в сети"
              : "частично недоступна"}
          </Status>
        }
      />
      <div className="summary-grid">
        <button
          className="summary-card energy"
          onClick={() => setTab("matrix")}
        >
          <span>Энергия матрицы</span>
          <strong>{formatEnergy(matrix.storedEnergy)}</strong>
          <small>
            {clamp(matrix.energyPercent).toFixed(1)}% из{" "}
            {formatEnergy(matrix.capacity)}
          </small>
          <Progress value={matrix.energyPercent} />
        </button>
        <button
          className="summary-card reactor"
          onClick={() => setTab("reactor")}
        >
          <span>Реактор</span>
          <strong>{reactor.running ? "РАБОТАЕТ" : "ОСТАНОВЛЕН"}</strong>
          <small>
            {Number(reactor.temperature || 0).toFixed(0)} K ·{" "}
            {Number(reactor.actualBurnRate || 0).toFixed(2)} mB/t
          </small>
          <Status online={state.reactor.online}>
            {state.reactor.online ? "Контроллер в сети" : "Нет связи"}
          </Status>
        </button>
        <button
          className="summary-card turbine"
          onClick={() => setTab("turbines")}
        >
          <span>Генерация турбин</span>
          <strong>{formatRate(generation)}</strong>
          <small>
            {onlineTurbines.length} из {turbines.length} подключено
          </small>
        </button>
        <button
          className="summary-card storage"
          onClick={() => setTab("storage")}
        >
          <span>ME-склад</span>
          <strong>{formatCompact(totalItems)}</strong>
          <small>{(state.storage.items || []).length} типов предметов</small>
          <Status online={state.storage.online && state.storage.connected}>
            ME {state.storage.connected ? "в сети" : "отключена"}
          </Status>
        </button>
      </div>
      <div className="overview-grid">
        <Card className="chart-panel">
          <CardHeader
            title="Баланс энергии"
            subtitle="Последние показатели матрицы"
            action={
              <b
                className={
                  Number(matrix.net || 0) >= 0 ? "positive" : "negative"
                }
              >
                {formatRate(matrix.net)}
              </b>
            }
          />
          <Sparkline points={matrixHistory} field="storedEnergy" />
          <div className="inline-metrics">
            <Metric label="Вход" value={formatRate(matrix.input)} tone="good" />
            <Metric
              label="Выход"
              value={formatRate(matrix.output)}
              tone="warn"
            />
          </div>
        </Card>
        <Card className="chart-panel">
          <CardHeader
            title="Температура реактора"
            subtitle="История нагрева"
            action={<b>{Number(reactor.temperature || 0).toFixed(0)} K</b>}
          />
          <Sparkline
            points={reactorHistory}
            field="temperature"
            color="#ff8a65"
          />
          <div className="inline-metrics">
            <Metric
              label="Нагрев"
              value={`${Number(reactor.heatingRate || 0).toFixed(1)} mB/t`}
            />
            <Metric
              label="Повреждение"
              value={`${Number(reactor.damage || 0).toFixed(2)}%`}
              tone={Number(reactor.damage) > 0 ? "danger" : "good"}
            />
          </div>
        </Card>
        <Card className="health-panel">
          <CardHeader
            title="Состояние служб"
            subtitle={`${onlineServices} из ${services.length} в сети`}
          />
          {services.length ? (
            services.map((service, index) => (
              <div
                className="service-row"
                key={`${service.role}-${service.computerId}-${index}`}
              >
                <span>
                  <i className={service.online ? "online" : ""} />
                  {service.role}
                </span>
                <b>CC #{service.computerId}</b>
              </div>
            ))
          ) : (
            <p className="empty-copy">Службы ещё не зарегистрированы</p>
          )}
        </Card>
      </div>
    </>
  );
}

function Tank({ label, percent, amount, capacity, tone }) {
  return (
    <div className="tank">
      <div className="tank-top">
        <span>{label}</span>
        <strong>{clamp(percent).toFixed(1)}%</strong>
      </div>
      <Progress value={percent} tone={tone} />
      <small>
        {formatFluid(amount)} / {formatFluid(capacity)}
      </small>
    </div>
  );
}

function Toggle({ checked, onChange }) {
  return (
    <button
      type="button"
      className={`toggle ${checked ? "on" : ""}`}
      onClick={() => onChange(!checked)}
    >
      <span />
    </button>
  );
}
function SafetyRule({
  label,
  description,
  enabled,
  setEnabled,
  value,
  setValue,
  suffix = "%",
  min = 0,
  max = 100,
}) {
  return (
    <div className={`safety-rule ${enabled ? "enabled" : ""}`}>
      <Toggle checked={enabled} onChange={setEnabled} />
      <div>
        <strong>{label}</strong>
        <small>{description}</small>
      </div>
      <label>
        <input
          type="number"
          min={min}
          max={max}
          value={value}
          onChange={(event) => setValue(Number(event.target.value))}
        />
        <span>{suffix}</span>
      </label>
    </div>
  );
}

function ReactorPanel({ reactor, history, sendCommand, commandResult }) {
  const data = reactor.data || {};
  const [burnRate, setBurnRate] = useState(0);
  const [start, setStart] = useState(80);
  const [stop, setStop] = useState(98);
  const [safety, setSafety] = useState({
    energyEnabled: true,
    steamEnabled: true,
    waterEnabled: true,
    fuelEnabled: true,
    steamStopPercent: 95,
    waterStopPercent: 10,
    fuelStopPercent: 5,
  });
  useEffect(() => {
    if (data.burnRate != null) setBurnRate(data.burnRate);
    if (data.startPercent != null) setStart(data.startPercent);
    if (data.stopPercent != null) setStop(data.stopPercent);
  }, [data.burnRate, data.startPercent, data.stopPercent]);
  useEffect(() => {
    if (data.safety) setSafety((current) => ({ ...current, ...data.safety }));
  }, [data.safety]);
  const setSafetyField = (field) => (value) =>
    setSafety((current) => ({ ...current, [field]: value }));
  const saveSafety = () => {
    sendCommand("set_thresholds", { startPercent: start, stopPercent: stop });
    sendCommand("set_safety", safety);
  };
  return (
    <>
      <PageTitle
        eyebrow="ЭНЕРГОБЛОК"
        title="Ядерный реактор"
        description="Телеметрия, управление и автономная безопасность"
        status={
          <Status online={reactor.online}>
            {reactor.online ? "Контроллер в сети" : "Контроллер недоступен"}
          </Status>
        }
      />
      <div className="reactor-layout">
        <div className="reactor-main">
          <Card
            className={`reactor-hero ${data.running ? "running" : "stopped"}`}
          >
            <div className="reactor-core">
              <span />
              <i />
              <i />
            </div>
            <div>
              <p>СОСТОЯНИЕ РЕАКТОРА</p>
              <h2>{data.running ? "РАБОТАЕТ" : "ОСТАНОВЛЕН"}</h2>
              <small>
                {data.safety?.stopped
                  ? `Автостоп: ${data.safety.reason}`
                  : "Локальная автоматика активна"}
              </small>
            </div>
            <div className="hero-actions">
              <button
                className="btn success"
                disabled={!reactor.online || data.running}
                onClick={() => sendCommand("reactor_start")}
              >
                Включить
              </button>
              <button
                className="btn danger"
                disabled={!reactor.online || !data.running}
                onClick={() => sendCommand("reactor_scram")}
              >
                Остановить
              </button>
            </div>
          </Card>
          <div className="metric-grid four">
            <Metric
              label="Температура"
              value={`${Number(data.temperature || 0).toFixed(0)} K`}
            />
            <Metric
              label="Степень нагрева"
              value={`${Number(data.heatingRate || 0).toFixed(1)} mB/t`}
            />
            <Metric
              label="Сгорание"
              value={`${Number(data.actualBurnRate || 0).toFixed(2)} mB/t`}
              hint={`Макс. ${Number(data.maxBurnRate || 0).toFixed(1)}`}
            />
            <Metric
              label="Повреждение"
              value={`${Number(data.damage || 0).toFixed(2)}%`}
              tone={Number(data.damage) > 0 ? "danger" : "good"}
            />
          </div>
          <Card>
            <CardHeader
              title="Баки реактора"
              subtitle="Текущий объём и заполненность"
            />
            <div className="tank-grid">
              <Tank
                label="Вода / охлаждение"
                percent={data.coolantPercent}
                amount={data.coolant}
                capacity={data.coolantCapacity}
                tone="cyan"
              />
              <Tank
                label="Топливо"
                percent={data.fuelPercent}
                amount={data.fuel}
                capacity={data.fuelCapacity}
                tone="green"
              />
              <Tank
                label="Нагретая жидкость"
                percent={data.heatedCoolantPercent}
                amount={data.heatedCoolant}
                capacity={data.heatedCoolantCapacity}
                tone="orange"
              />
              <Tank
                label="Ядерные отходы"
                percent={data.wastePercent}
                amount={data.waste}
                capacity={data.wasteCapacity}
                tone="yellow"
              />
            </div>
          </Card>
          <Card className="chart-panel">
            <CardHeader
              title="График нагрева"
              subtitle="Температура и скорость нагрева за последние 3 минуты"
              action={<b>{history.length} точек</b>}
            />
            <Sparkline
              points={history}
              field="temperature"
              color="#ff765f"
              height={180}
            />
            <div className="chart-legend">
              <span>
                <i style={{ background: "#ff765f" }} />
                Температура: {Number(data.temperature || 0).toFixed(0)} K
              </span>
              <span>
                Скорость нагрева: {Number(data.heatingRate || 0).toFixed(1)}{" "}
                mB/t
              </span>
            </div>
          </Card>
        </div>
        <aside className="reactor-controls">
          <Card>
            <CardHeader
              title="Управление мощностью"
              subtitle="Лимит скорости сгорания"
            />
            <div className="range-value">
              <strong>{Number(burnRate).toFixed(1)}</strong>
              <span>mB/t</span>
            </div>
            <input
              className="range"
              type="range"
              min="0"
              max={Math.max(0.1, Number(data.maxBurnRate || 0))}
              step="0.1"
              value={Math.min(
                burnRate,
                Math.max(0.1, Number(data.maxBurnRate || 0)),
              )}
              onChange={(event) => setBurnRate(Number(event.target.value))}
            />
            <button
              className="btn primary full"
              disabled={!reactor.online}
              onClick={() => sendCommand("set_burn_rate", { burnRate })}
            >
              Применить лимит
            </button>
          </Card>
          <Card>
            <CardHeader
              title="Контуры безопасности"
              subtitle="Правила выполняются локально на CC"
              action={<Icon name="shield" />}
            />
            <SafetyRule
              label="Аккумулятор"
              description="Остановить при заполнении"
              enabled={safety.energyEnabled}
              setEnabled={setSafetyField("energyEnabled")}
              value={stop}
              setValue={setStop}
            />
            <SafetyRule
              label="Нагретая жидкость"
              description="Остановить при переполнении"
              enabled={safety.steamEnabled}
              setEnabled={setSafetyField("steamEnabled")}
              value={safety.steamStopPercent}
              setValue={setSafetyField("steamStopPercent")}
              min={1}
            />
            <SafetyRule
              label="Вода"
              description="Остановить при падении ниже"
              enabled={safety.waterEnabled}
              setEnabled={setSafetyField("waterEnabled")}
              value={safety.waterStopPercent}
              setValue={setSafetyField("waterStopPercent")}
              max={99}
            />
            <SafetyRule
              label="Топливо"
              description="Остановить при падении ниже"
              enabled={safety.fuelEnabled}
              setEnabled={setSafetyField("fuelEnabled")}
              value={safety.fuelStopPercent}
              setValue={setSafetyField("fuelStopPercent")}
              max={99}
            />
            <div className="resume-field">
              <span>Возобновить при заряде ниже</span>
              <label>
                <input
                  type="number"
                  min="0"
                  max="99"
                  value={start}
                  onChange={(event) => setStart(Number(event.target.value))}
                />
                <span>%</span>
              </label>
            </div>
            <button
              className="btn primary full"
              disabled={!reactor.online}
              onClick={saveSafety}
            >
              Сохранить безопасность
            </button>
            {commandResult && (
              <p className={`notice ${commandResult.ok ? "ok" : "error"}`}>
                {commandResult.message}
              </p>
            )}
          </Card>
        </aside>
      </div>
    </>
  );
}

function MatrixPanel({ matrix, history }) {
  const data = matrix.data || {};
  const energy = clamp(data.energyPercent);
  const net = Number(data.net || 0);
  return (
    <>
      <PageTitle
        eyebrow="ЭНЕРГОХРАНИЛИЩЕ"
        title="Индукционная матрица"
        description={data.name || "inductionPort_0"}
        status={
          <Status online={matrix.online}>
            {matrix.online ? "Матрица в сети" : "Матрица недоступна"}
          </Status>
        }
      />
      <div className="matrix-layout">
        <Card className="matrix-gauge">
          <Ring value={energy} label="заполнено" color="#52d7ff" />
          <div className="matrix-total">
            <span>Накоплено энергии</span>
            <strong>{formatEnergy(data.storedEnergy)}</strong>
            <small>из {formatEnergy(data.capacity)}</small>
          </div>
        </Card>
        <div className="metric-grid two">
          <Metric
            label="Входящий поток"
            value={formatRate(data.input)}
            tone="good"
          />
          <Metric
            label="Исходящий поток"
            value={formatRate(data.output)}
            tone="warn"
          />
          <Metric
            label="Баланс"
            value={formatRate(net)}
            hint={net >= 0 ? "Матрица заряжается" : "Матрица разряжается"}
            tone={net >= 0 ? "good" : "danger"}
          />
          <Metric
            label="Свободная ёмкость"
            value={formatEnergy(data.energyNeeded)}
          />
        </div>
      </div>
      <Card className="chart-panel matrix-history">
        <CardHeader
          title="История накопления"
          subtitle="Изменение запаса энергии"
          action={
            <b className={net >= 0 ? "positive" : "negative"}>
              {net >= 0 ? "+" : ""}
              {formatRate(net)}
            </b>
          }
        />
        <Sparkline points={history} field="storedEnergy" height={220} />
      </Card>
    </>
  );
}

function TurbinesPanel({ turbines }) {
  const online = turbines.filter((unit) => unit.online);
  const total = online.reduce(
    (sum, unit) => sum + Number(unit.data?.production || 0),
    0,
  );
  return (
    <>
      <PageTitle
        eyebrow="ГЕНЕРАЦИЯ"
        title="Турбины"
        description="Автоматически обнаруженные turbineValue"
        status={
          <Status online={online.length > 0}>
            {online.length} из {turbines.length} в сети
          </Status>
        }
      />
      <div className="metric-grid three page-metrics">
        <Metric label="Общая генерация" value={formatRate(total)} tone="good" />
        <Metric label="Активные турбины" value={online.length} />
        <Metric
          label="Средняя генерация"
          value={formatRate(online.length ? total / online.length : 0)}
        />
      </div>
      {turbines.length ? (
        <div className="turbine-grid">
          {turbines.map((unit, index) => {
            const data = unit.data || {};
            return (
              <Card
                className="turbine-card"
                key={`${unit.computerId}-${data.peripheral || index}`}
              >
                <CardHeader
                  title={data.peripheral || `Турбина ${index + 1}`}
                  subtitle={`Computer #${unit.computerId}`}
                  action={
                    <Status online={unit.online}>
                      {unit.online ? "В сети" : "Нет связи"}
                    </Status>
                  }
                />
                <div className="turbine-output">
                  <span>Генерация</span>
                  <strong>{formatRate(data.production)}</strong>
                </div>
                <div className="metric-grid two">
                  <Metric
                    label="Скорость потока"
                    value={`${Number(data.flowRate || 0).toFixed(1)} mB/t`}
                  />
                  <Metric
                    label="Макс. поток"
                    value={`${Number(data.maxFlowRate || 0).toFixed(1)} mB/t`}
                  />
                  <Metric
                    label="Пар"
                    value={
                      data.steamCapacity
                        ? formatFluid(data.steam)
                        : `${Number(data.steamPercent || 0).toFixed(1)}%`
                    }
                    hint={
                      data.steamCapacity
                        ? `из ${formatFluid(data.steamCapacity)}`
                        : "Заполнение бака"
                    }
                  />
                  <Metric
                    label="Энергобуфер"
                    value={`${Number(data.energyPercent || 0).toFixed(1)}%`}
                  />
                </div>
                <Progress value={data.steamPercent} tone="cyan" />
              </Card>
            );
          })}
        </div>
      ) : (
        <Card className="empty-panel">
          <Icon name="turbine" size={40} />
          <h2>Турбины не найдены</h2>
          <p>Подключите turbineValue к проводной сети CC.</p>
        </Card>
      )}
    </>
  );
}

function ItemIcon({ item }) {
  const [source, setSource] = useState(0);
  const [namespace = "?", path = "item"] = String(item.name || "").split(":");
  const urls =
    namespace === "minecraft"
      ? [
          `https://mcasset.cloud/1.20.1/assets/minecraft/textures/item/${path}.png`,
          `https://mcasset.cloud/1.20.1/assets/minecraft/textures/block/${path}.png`,
        ]
      : [];
  const hue =
    [...namespace].reduce((sum, char) => sum + char.charCodeAt(0), 0) % 360;
  return (
    <div className="item-icon" style={{ "--hue": hue }}>
      {source < urls.length ? (
        <img
          src={urls[source]}
          alt=""
          onError={() => setSource((value) => value + 1)}
        />
      ) : (
        <span>{namespace.slice(0, 2).toUpperCase()}</span>
      )}
    </div>
  );
}

function StoragePanel({ storage }) {
  const [view, setView] = useState("summary");
  const [query, setQuery] = useState("");
  const items = storage.items || [];
  const metrics = storage.metrics || {};
  const cells = metrics.cells || [];
  const totalItems = useMemo(
    () => items.reduce((sum, item) => sum + Number(item.count || 0), 0),
    [items],
  );
  const fullness =
    Number(metrics.total) > 0
      ? (Number(metrics.used) / Number(metrics.total)) * 100
      : 0;
  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return items
      .filter(
        (item) =>
          !needle ||
          `${item.displayName} ${item.name}`.toLowerCase().includes(needle),
      )
      .slice(0, 600);
  }, [items, query]);
  return (
    <>
      <PageTitle
        eyebrow="APPLIED ENERGISTICS 2"
        title="ME-склад"
        description={storage.details || "Состояние сети хранения"}
        status={
          <Status online={storage.online && storage.connected}>
            {storage.connected ? "Сеть подключена" : "Сеть недоступна"}
          </Status>
        }
      />
      <div className="subtabs">
        <button
          className={view === "summary" ? "active" : ""}
          onClick={() => setView("summary")}
        >
          Обзор
        </button>
        <button
          className={view === "items" ? "active" : ""}
          onClick={() => setView("items")}
        >
          Все предметы <span>{items.length}</span>
        </button>
      </div>
      {view === "summary" ? (
        <>
          <div className="storage-overview">
            <Card className="storage-capacity">
              <Ring value={fullness} label="занято" color="#9b7cff" />
              <div>
                <span>Использовано хранилища</span>
                <strong>{formatCompact(metrics.used, " B")}</strong>
                <small>из {formatCompact(metrics.total, " B")}</small>
              </div>
            </Card>
            <div className="metric-grid two">
              <Metric
                label="Всего предметов"
                value={formatCompact(totalItems)}
              />
              <Metric
                label="Типов предметов"
                value={items.length.toLocaleString("ru-RU")}
              />
              <Metric label="Ячеек хранения" value={cells.length} />
              <Metric
                label="Свободно"
                value={formatCompact(metrics.available, " B")}
                tone="good"
              />
            </div>
          </div>
          <Card>
            <CardHeader
              title="Ячейки хранения"
              subtitle={`${cells.length} установлено`}
            />
            {cells.length ? (
              <div className="cell-grid">
                {cells.map((cell, index) => {
                  const used = Number(cell.usedBytes || 0);
                  const percent =
                    used && cell.totalBytes
                      ? (used / cell.totalBytes) * 100
                      : null;
                  return (
                    <div className="cell" key={`${cell.item}-${index}`}>
                      <Icon name="storage" />
                      <div>
                        <strong>{String(cell.item).split(":").pop()}</strong>
                        <span>
                          {cell.cellType === "fluid" ? "Жидкости" : "Предметы"}{" "}
                          · {formatCompact(cell.totalBytes, " B")}
                        </span>
                      </div>
                      <b>
                        {percent == null
                          ? "Установлена"
                          : `${percent.toFixed(1)}%`}
                      </b>
                    </div>
                  );
                })}
              </div>
            ) : (
              <p className="empty-copy">ME Bridge не вернул список ячеек.</p>
            )}
          </Card>
        </>
      ) : (
        <Card>
          <div className="items-toolbar">
            <div>
              <h2>Содержимое склада</h2>
              <p>
                {filtered.length} результатов · {formatCompact(totalItems)}{" "}
                предметов
              </p>
            </div>
            <label className="search">
              <Icon name="search" />
              <input
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Поиск предмета..."
              />
            </label>
          </div>
          <div className="item-grid">
            {filtered.map((item, index) => (
              <div
                className="item"
                key={`${item.name}-${item.fingerprint || index}`}
              >
                <ItemIcon item={item} />
                <div>
                  <strong>{item.displayName || item.name}</strong>
                  <code>{item.name}</code>
                </div>
                <b>{Number(item.count || 0).toLocaleString("ru-RU")}</b>
              </div>
            ))}
          </div>
          {!filtered.length && (
            <p className="empty-copy">Предметы не найдены</p>
          )}
        </Card>
      )}
    </>
  );
}

const defaultPalette = [
  "#f0f0f0",
  "#f2b233",
  "#e57fd8",
  "#99b2f2",
  "#dede6c",
  "#7fcc19",
  "#f2b2cc",
  "#4c4c4c",
  "#999999",
  "#4c99b2",
  "#b266e5",
  "#3366cc",
  "#7f664c",
  "#57a64e",
  "#cc4c4c",
  "#111111",
];
const keyNames = {
  Enter: "enter",
  Backspace: "backspace",
  Tab: "tab",
  Escape: "escape",
  Delete: "delete",
  Insert: "insert",
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
  Home: "home",
  End: "end",
  PageUp: "pageUp",
  PageDown: "pageDown",
  " ": "space",
  "-": "minus",
  "=": "equals",
  "[": "leftBracket",
  "]": "rightBracket",
  ";": "semicolon",
  "'": "apostrophe",
  "`": "grave",
  "\\": "backslash",
  ",": "comma",
  ".": "period",
  "/": "slash",
};
const digitKeys = [
  "zero",
  "one",
  "two",
  "three",
  "four",
  "five",
  "six",
  "seven",
  "eight",
  "nine",
];
function browserKey(event) {
  if (keyNames[event.key]) return keyNames[event.key];
  if (/^[a-z]$/i.test(event.key)) return event.key.toLowerCase();
  if (/^[0-9]$/.test(event.key)) return digitKeys[Number(event.key)];
  if (/^F([1-9]|1[0-2])$/.test(event.key)) return event.key.toLowerCase();
  if (event.key === "Control")
    return event.location === 2 ? "rightCtrl" : "leftCtrl";
  if (event.key === "Shift")
    return event.location === 2 ? "rightShift" : "leftShift";
  if (event.key === "Alt") return event.location === 2 ? "rightAlt" : "leftAlt";
  return null;
}
function paletteColor(palette, code) {
  const index = Number.parseInt(code || "f", 16);
  const rgb = palette?.[index];
  return Array.isArray(rgb)
    ? `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`
    : defaultPalette[index] || "#111";
}

function TerminalScreen({ terminal, sendInput }) {
  const pressed = useRef(new Set());
  const screen = useRef(null);
  const send = (event, values = {}) =>
    terminal?.online && sendInput(terminal.computerId, event, values);
  const position = (event) => {
    const box = screen.current.getBoundingClientRect();
    return {
      x: clamp(
        Math.floor(((event.clientX - box.left) / box.width) * terminal.width) +
          1,
        1,
        terminal.width,
      ),
      y: clamp(
        Math.floor(((event.clientY - box.top) / box.height) * terminal.height) +
          1,
        1,
        terminal.height,
      ),
    };
  };
  const onKeyDown = (event) => {
    if (
      !terminal?.online ||
      ((event.ctrlKey || event.metaKey) && event.code === "KeyV")
    )
      return;
    const key = browserKey(event);
    const printable =
      event.key.length === 1 &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.altKey;
    if (key && !printable && !pressed.current.has(event.code)) {
      pressed.current.add(event.code);
      send("key", { key, held: event.repeat });
    }
    if (printable) send("char", { value: event.key });
    if (key || printable) event.preventDefault();
  };
  const onKeyUp = (event) => {
    if ((event.ctrlKey || event.metaKey) && event.code === "KeyV") return;
    const key = browserKey(event);
    pressed.current.delete(event.code);
    if (key && event.key.length !== 1) {
      send("key_up", { key });
      event.preventDefault();
    }
  };
  return (
    <div
      ref={screen}
      className="craftos-screen"
      style={{
        "--cols": terminal?.width || 51,
        "--rows": terminal?.height || 19,
      }}
      tabIndex="0"
      onKeyDown={onKeyDown}
      onKeyUp={onKeyUp}
      onPaste={(event) => {
        send("paste", { value: event.clipboardData.getData("text") });
        event.preventDefault();
      }}
      onMouseDown={(event) => {
        screen.current.focus();
        send("mouse_click", {
          button: event.button === 2 ? 2 : event.button === 1 ? 3 : 1,
          ...position(event),
        });
        event.preventDefault();
      }}
      onMouseUp={(event) =>
        send("mouse_up", {
          button: event.button === 2 ? 2 : 1,
          ...position(event),
        })
      }
      onMouseMove={(event) =>
        event.buttons &&
        send("mouse_drag", {
          button: event.buttons & 2 ? 2 : 1,
          ...position(event),
        })
      }
      onWheel={(event) => {
        send("mouse_scroll", {
          button: event.deltaY > 0 ? 1 : -1,
          ...position(event),
        });
        event.preventDefault();
      }}
      onContextMenu={(event) => event.preventDefault()}
    >
      {terminal ? (
        (terminal.lines || []).map((line, y) => (
          <div className="craftos-row" key={y}>
            {[...(line.text || "")].map((character, x) => (
              <span
                key={x}
                className={
                  terminal.cursorBlink &&
                  terminal.cursorX === x + 1 &&
                  terminal.cursorY === y + 1
                    ? "cursor"
                    : ""
                }
                style={{
                  color: paletteColor(terminal.palette, line.fg?.[x]),
                  background: paletteColor(terminal.palette, line.bg?.[x]),
                }}
              >
                {character}
              </span>
            ))}
          </div>
        ))
      ) : (
        <div className="terminal-empty">Выберите подключённый компьютер</div>
      )}
    </div>
  );
}

function ConsolePanel({ terminals, sendInput }) {
  const list = useMemo(
    () =>
      Object.values(terminals || {}).sort(
        (a, b) => Number(a.computerId) - Number(b.computerId),
      ),
    [terminals],
  );
  const [target, setTarget] = useState(null);
  useEffect(() => {
    if (!list.length) setTarget(null);
    else if (!list.some((entry) => String(entry.computerId) === String(target)))
      setTarget(String(list[0].computerId));
  }, [list, target]);
  const terminal = list.find(
    (entry) => String(entry.computerId) === String(target),
  );
  return (
    <>
      <PageTitle
        eyebrow="УДАЛЁННЫЙ ДОСТУП"
        title="Консоль CraftOS"
        description="Полная эмуляция экрана, клавиатуры, вставки и мыши"
        status={
          <Status online={Boolean(terminal?.online)}>
            {terminal?.online
              ? `Computer #${terminal.computerId}`
              : "Нет активного терминала"}
          </Status>
        }
      />
      <div className="console-layout">
        <Card className="terminal-list">
          <CardHeader
            title="Компьютеры"
            subtitle={`${list.filter((entry) => entry.online).length} в сети`}
          />
          {list.map((entry) => (
            <button
              className={
                String(target) === String(entry.computerId) ? "active" : ""
              }
              key={entry.computerId}
              onClick={() => setTarget(String(entry.computerId))}
            >
              <Icon name="terminal" />
              <span>
                <strong>{entry.label || `Computer ${entry.computerId}`}</strong>
                <small>ID {entry.computerId}</small>
              </span>
              <i className={entry.online ? "online" : ""} />
            </button>
          ))}
        </Card>
        <Card className="terminal-card">
          <div className="terminal-bar">
            <span>
              CRAFTOS-PC ·{" "}
              {terminal ? `COMPUTER ${terminal.computerId}` : "OFFLINE"}
            </span>
            <button
              disabled={!terminal?.online}
              onClick={() => sendInput(terminal.computerId, "terminate")}
            >
              CTRL+T
            </button>
          </div>
          <div className="terminal-stage">
            <TerminalScreen terminal={terminal} sendInput={sendInput} />
          </div>
          <p className="terminal-help">
            Кликните по экрану для ввода. Поддерживаются клавиатура, Ctrl+V и
            мышь.
          </p>
        </Card>
      </div>
    </>
  );
}

const navigation = [
  ["overview", "Обзор"],
  ["reactor", "Реактор"],
  ["matrix", "Матрица"],
  ["turbines", "Турбины"],
  ["storage", "Склад"],
  ["terminal", "Консоль"],
];

export default function App() {
  const [token, setToken] = useState(
    () => localStorage.getItem("kenzu_cc_token") || "",
  );
  const [draft, setDraft] = useState(token);
  const [authError, setAuthError] = useState("");
  const [tab, setTab] = useState("overview");
  const [state, setState] = useState(initialState);
  const [online, setOnline] = useState(false);
  const [commandResult, setCommandResult] = useState(null);
  const [reactorHistory, setReactorHistory] = useState([]);
  const [matrixHistory, setMatrixHistory] = useState([]);
  const socketRef = useRef(null);
  useEffect(() => {
    if (!token) return undefined;
    let reconnect;
    let disposed = false;
    const connect = () => {
      const protocol = location.protocol === "https:" ? "wss:" : "ws:";
      const socket = new WebSocket(`${protocol}//${location.host}/ws`);
      socketRef.current = socket;
      socket.onopen = () =>
        socket.send(JSON.stringify({ type: "hello", role: "browser", token }));
      socket.onmessage = (event) => {
        const message = JSON.parse(event.data);
        if (message.type === "auth_error") {
          localStorage.removeItem("kenzu_cc_token");
          setAuthError(message.message);
          setToken("");
          socket.close();
          return;
        }
        if (message.type === "state") {
          setOnline(true);
          setState(message.state);
        }
        if (message.type === "matrix_state") {
          setState((current) => ({ ...current, matrix: message.matrix }));
          if (message.matrix?.data)
            setMatrixHistory((current) =>
              [...current, { at: Date.now(), ...message.matrix.data }].slice(
                -180,
              ),
            );
        }
        if (message.type === "reactor_state") {
          setState((current) => ({ ...current, reactor: message.reactor }));
          if (message.reactor?.data)
            setReactorHistory((current) =>
              [...current, { at: Date.now(), ...message.reactor.data }].slice(
                -180,
              ),
            );
        }
        if (message.type === "turbines_state")
          setState((current) => ({ ...current, turbines: message.turbines }));
        if (message.type === "storage_state")
          setState((current) => ({ ...current, storage: message.storage }));
        if (message.type === "storage_status")
          setState((current) => ({
            ...current,
            storage: { ...current.storage, ...message.storage },
          }));
        if (message.type === "computers_state")
          setState((current) => ({ ...current, computers: message.computers }));
        if (message.type === "terminal_frame")
          setState((current) => ({
            ...current,
            terminals: {
              ...current.terminals,
              [String(message.terminal.computerId)]: message.terminal,
            },
          }));
        if (message.type === "system_status")
          setState((current) => ({
            ...current,
            ...message,
            storage: { ...current.storage, ...message.storage },
          }));
        if (message.type === "command_result") setCommandResult(message);
      };
      socket.onclose = () => {
        setOnline(false);
        if (!disposed) reconnect = setTimeout(connect, 2000);
      };
    };
    connect();
    return () => {
      disposed = true;
      clearTimeout(reconnect);
      socketRef.current?.close();
    };
  }, [token]);
  const send = (payload) => {
    if (socketRef.current?.readyState !== WebSocket.OPEN) return false;
    socketRef.current.send(JSON.stringify(payload));
    return true;
  };
  const sendCommand = (action, values = {}) => {
    setCommandResult(null);
    if (
      !send({
        type: "command",
        requestId: `${Date.now()}-${action}`,
        action,
        ...values,
      })
    )
      setCommandResult({ ok: false, message: "Сервер недоступен" });
  };
  const sendInput = (target, event, values = {}) =>
    send({ type: "terminal_input", target: String(target), event, ...values });
  if (!token)
    return (
      <main className="auth">
        <form
          onSubmit={(event) => {
            event.preventDefault();
            const value = draft.trim();
            if (value) {
              localStorage.setItem("kenzu_cc_token", value);
              setAuthError("");
              setToken(value);
            }
          }}
        >
          <div className="logo">K</div>
          <p className="eyebrow">ATM9 CONTROL NETWORK</p>
          <h1>Kenzu Control</h1>
          <p>Введите токен доступа к панели управления.</p>
          <input
            type="password"
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            placeholder="Токен доступа"
            autoFocus
          />
          <button className="btn primary full">Подключиться</button>
          {authError && <p className="notice error">{authError}</p>}
        </form>
      </main>
    );
  let content = (
    <Overview
      state={state}
      matrixHistory={matrixHistory}
      reactorHistory={reactorHistory}
      setTab={setTab}
    />
  );
  if (tab === "reactor")
    content = (
      <ReactorPanel
        reactor={state.reactor}
        history={reactorHistory}
        sendCommand={sendCommand}
        commandResult={commandResult}
      />
    );
  if (tab === "matrix")
    content = <MatrixPanel matrix={state.matrix} history={matrixHistory} />;
  if (tab === "turbines")
    content = <TurbinesPanel turbines={state.turbines || []} />;
  if (tab === "storage")
    content = <StoragePanel storage={state.storage || {}} />;
  if (tab === "terminal")
    content = (
      <ConsolePanel terminals={state.terminals || {}} sendInput={sendInput} />
    );
  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <div className="logo">K</div>
          <div>
            <strong>Kenzu</strong>
            <span>Control System</span>
          </div>
        </div>
        <nav>
          {navigation.map(([id, label]) => (
            <button
              className={tab === id ? "active" : ""}
              key={id}
              onClick={() => setTab(id)}
            >
              <Icon name={id} />
              <span>{label}</span>
              {id === "reactor" && state.reactor.data?.running && (
                <i className="nav-live" />
              )}
            </button>
          ))}
        </nav>
        <div className="sidebar-footer">
          <Status online={online}>
            {online ? "Сервер подключён" : "Нет связи"}
          </Status>
          <button
            onClick={() => {
              socketRef.current?.close();
              localStorage.removeItem("kenzu_cc_token");
              setToken("");
            }}
          >
            Сменить токен
          </button>
        </div>
      </aside>
      <main className="workspace">
        <div className="mobile-bar">
          <div className="brand">
            <div className="logo">K</div>
            <strong>Kenzu Control</strong>
          </div>
          <Status online={online}>{online ? "Online" : "Offline"}</Status>
        </div>
        <div className="content">{content}</div>
      </main>
    </div>
  );
}
