# Traccar Forwarding Script with Battery & Charge Support

Dieses Skript installiert eine selbst kompilierte Version von [Traccar](https://www.traccar.org/) inklusive erweiterten Attributen für das Forwarding:  
`batteryLevel` und `charge` werden zusätzlich zur Position übertragen.

## 📦 Funktionen

- Automatischer Download und Build des aktuellen [traccar](https://github.com/traccar/traccar) Quellcodes
- Automatischer Patch von `PositionForwarderUrl.java` zum Hinzufügen von `{batteryLevel}` und `{charge}`
- Erstellung einer minimalen `traccar.xml` mit Forwarding-URL
- Einrichtung eines systemd-Dienstes für automatischen Start
- Funktioniert vollständig offline nach dem ersten Build (keine fremden ZIPs nötig)

---

## 🔧 Voraussetzungen

### Erforderliche Pakete

| Paket              | Beschreibung                                     |
|-------------------|--------------------------------------------------|
| `git`             | Klonen des Quellcodes                            |
| `curl`, `wget`    | Optional, z. B. für Tests oder Datenabruf        |
| `unzip`           | Nur nötig bei manuellen ZIP-Installationen       |
| `build-essential` | Enthält Compiler, `make` etc.                    |
| `openjdk-17-jdk`  | Java Development Kit 17 (für Traccar notwendig)  |

### Optional empfohlen

| Paket        | Beschreibung                          |
|--------------|---------------------------------------|
| `vim`/`nano` | Bearbeitung von Konfigurationsdateien |
| `htop`       | Prozessüberwachung                    |
| `net-tools`  | Diagnose (`ifconfig`, etc.)           |

#### Installation auf Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y git unzip build-essential openjdk-17-jdk
