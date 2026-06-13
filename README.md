# Fellow Stagg EKG Pro — SmartThings Edge Driver

A local‑LAN [SmartThings Edge Driver](https://developer.smartthings.com/docs/edge-device-drivers/) for the **Fellow Stagg EKG Pro** Wi‑Fi kettle. Control power, monitor and set the target temperature, and get a push notification when your water reaches temperature — all **100% local**, no cloud, no Bluetooth.

> 🇪🇸 Versión en español más abajo · [Spanish version below](#-español)

---

## ✨ Features

- **On / Off** — reliable power control that stays in sync with the kettle's display
- **Current temperature** — live water temperature (sensor‑calibrated)
- **Target temperature** — set your desired temperature from the app (40–100 °C)
- **"Water ready" notification** — fires the moment the kettle reaches its target
- **Operating state** — heating / idle shown in the app
- **Fully local** — talks to the kettle over plain HTTP on your LAN; no internet required
- **Resilient** — tolerates the kettle's transient HTTP drop‑outs during state changes

## 📋 Requirements

- A SmartThings hub that supports Edge Drivers (e.g. a Samsung TV/Fridge with SmartThings hub, Aeotec/SmartThings hub, etc.)
- A Fellow Stagg EKG **Pro** kettle connected to your Wi‑Fi (the **Pro** model — it exposes a local HTTP API)
- The kettle's **static/reserved local IP** (set a DHCP reservation in your router so it doesn't change)
- The [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli)

## 🚀 Installation

```bash
# 1. Clone this repo
git clone https://github.com/<your-user>/fellow-stagg-ekg-pro.git
cd fellow-stagg-ekg-pro

# 2. Create a channel (once) and package the driver
smartthings edge:channels:create
smartthings edge:drivers:package .

# 3. Assign the driver to your channel and enroll your hub
smartthings edge:channels:assign <DRIVER_ID> --channel <CHANNEL_ID>
smartthings edge:channels:enroll <HUB_ID> --channel <CHANNEL_ID>
smartthings edge:drivers:install <DRIVER_ID> --hub <HUB_ID> --channel <CHANNEL_ID>
```

Then in the SmartThings app: **Add device → Scan nearby**. The kettle appears as *"Tetera Fellow Stagg"*. Open its settings and set the **IP Address** preference to your kettle's local IP.

## 🔔 "Water ready" notification

The driver emits a `temperatureAlarm = heat` event the instant the kettle reaches its target (when it enters the `S_Hold` keep‑warm state). Create a SmartThings **Routine**:

- **If** → *Tetera Fellow Stagg → Temperature alarm → Overheated* (this is how the app labels the `heat` value)
- **Then** → *Notify members* → your message, e.g. *"☕ Water is ready!"*

> Requires the kettle's **Hold** mode to be enabled (so it enters `S_Hold` on reaching target).

## ⚙️ Preferences

| Preference | Description | Default |
|---|---|---|
| IP Address | The kettle's local IP | `192.168.1.100` |
| Poll interval | Seconds between state reads (10–300) | `10` |
| Alert on reach | Emit the alarm when target is reached | `on` |

## 📡 Protocol

The full, **empirically‑verified** local HTTP protocol is documented in [`docs/PROTOCOL.md`](docs/PROTOCOL.md). This was the hardest part to get right — the kettle's API is undocumented and several "obvious" commands behave in surprising ways.

## 🙏 Credits

- Protocol details cross‑checked against [`rderewianko/fellow-ekg`](https://github.com/rderewianko/fellow-ekg) (Home Assistant integration) — thank you.
- Built and verified live against real hardware.

## ⚠️ Disclaimer

This is an unofficial, community‑built driver. It uses an **undocumented** local API that Fellow may change in any firmware update. Not affiliated with or endorsed by Fellow Products. Use at your own risk — never run a kettle without water.

## 📄 License

[MIT](LICENSE)

---

## 🇪🇸 Español

Un **SmartThings Edge Driver** local para la tetera Wi‑Fi **Fellow Stagg EKG Pro**. Controla el encendido, monitorea y ajusta la temperatura objetivo, y recibe una notificación cuando el agua llega a temperatura — todo **100% local**, sin nube ni Bluetooth.

### ✨ Funciones

- **Encender / Apagar** — control de potencia que se mantiene sincronizado con la pantalla de la tetera
- **Temperatura actual** — lectura en vivo (con el sensor calibrado)
- **Temperatura objetivo** — fíjala desde la app (40–100 °C)
- **Notificación "agua lista"** — se dispara justo cuando la tetera alcanza el objetivo
- **Estado** — calentando / inactivo visible en la app
- **Totalmente local** — habla con la tetera por HTTP en tu red; no requiere internet
- **Robusto** — tolera los cortes HTTP momentáneos de la tetera durante las transiciones

### 📋 Requisitos

- Un hub SmartThings con soporte de Edge Drivers (TV/refrigerador Samsung con hub, hub Aeotec/SmartThings, etc.)
- Una tetera Fellow Stagg EKG **Pro** conectada a tu Wi‑Fi (el modelo **Pro** expone una API HTTP local)
- La **IP local fija/reservada** de la tetera (haz una reserva DHCP en tu router)
- El [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli)

### 🚀 Instalación

```bash
# 1. Clona el repo
git clone https://github.com/<tu-usuario>/fellow-stagg-ekg-pro.git
cd fellow-stagg-ekg-pro

# 2. Crea un canal (una vez) y empaqueta el driver
smartthings edge:channels:create
smartthings edge:drivers:package .

# 3. Asigna el driver a tu canal e inscribe tu hub
smartthings edge:channels:assign <DRIVER_ID> --channel <CHANNEL_ID>
smartthings edge:channels:enroll <HUB_ID> --channel <CHANNEL_ID>
smartthings edge:drivers:install <DRIVER_ID> --hub <HUB_ID> --channel <CHANNEL_ID>
```

Luego en la app SmartThings: **Agregar dispositivo → Escanear cercanos**. La tetera aparece como *"Tetera Fellow Stagg"*. Abre sus ajustes y pon la **IP** de tu tetera.

### 🔔 Notificación "agua lista"

El driver emite `temperatureAlarm = heat` en el instante en que la tetera llega al objetivo (cuando entra en `S_Hold`). Crea una **Rutina** en SmartThings:

- **Si** → *Tetera Fellow Stagg → Alerta de temperatura → Sobrecalentado* (así etiqueta la app el valor `heat`)
- **Entonces** → *Notificar a los miembros* → tu mensaje, ej: *"☕ ¡El agua está lista!"*

> Requiere el modo **Hold** activado en la tetera (para que entre en `S_Hold` al llegar al objetivo).

### 📡 Protocolo

El protocolo HTTP local completo y **verificado empíricamente** está en [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

### ⚠️ Aviso

Driver no oficial hecho por la comunidad. Usa una API local **no documentada** que Fellow podría cambiar en cualquier actualización. No afiliado ni respaldado por Fellow Products. Úsalo bajo tu propio riesgo — nunca enciendas una tetera sin agua.

### 📄 Licencia

[MIT](LICENSE)
