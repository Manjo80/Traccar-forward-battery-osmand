# 🛰️ Traccar GPS-Server mit Battery-Forwarding & Webinterface

Dieses Skript installiert **Traccar 6.9.0** aus dem Quellcode, inklusive:
- Webinterface (modernes UI mit Vite gebaut)
- Battery-Forwarding über HTTP-URL
- systemd-Integration für Autostart
- Unterstützung für spätere Anpassungen und Erweiterungen

---

## ✅ Was macht das Skript?

1. **System vorbereiten**
   - Installiert benötigte Pakete: Java 17, Git, curl, npm, build tools
   - Installiert Node.js 22 mit `nvm` (modernes Webinterface benötigt Node ≥ 20.19)

2. **Quellcode herunterladen**
   - Klont das Traccar-Repo (mit Submodulen)

3. **Patch anwenden**
   - Fügt in `PositionForwarderUrl.java` Felder für `batteryLevel` und `charge` ein

4. **Build-Prozess**
   - Kompiliert den Server mit `./gradlew build`
   - Baut das Webinterface mit `npm run build`

5. **Installation**
   - Kopiert alle nötigen Dateien nach `/opt/traccar`
   - Erstellt `traccar.xml` mit benutzerdefinierter `forward.url`

6. **systemd-Dienst erstellen**
   - Traccar wird als Dienst eingerichtet und gestartet
   - Aktiviert für Autostart bei Systemstart

7. **Ausgabe von IP & Port**
   - Zeigt am Ende erreichbare Web-URLs (Port `8082`)

---

## 🌐 Webinterface

Zugriff nach der Installation:
http://"IP-Adresse":8082

Die IP-Adressen aller Interfaces werden automatisch angezeigt.

---

## ⚙️ Konfiguration

### `forward.url`
Du wirst beim Installieren nach Ziel-IP und Port gefragt, z. B.:

http://"IP-Adresse":8080/?id={uniqueId}&timestamp={fixTime}&lat={latitude}&lon={longitude}&speed={speed}&status={statusCode}&batt={batteryLevel}


### Datenbank
Standard ist die interne H2-Datenbank. Optional kannst du später auf MySQL oder PostgreSQL umstellen.

---

## 🧰 Optionen zur Erweiterung (manuell)

Diese Optionen sind **nicht im Standard-Skript aktiviert**, können aber einfach nachgerüstet werden:

- **MySQL oder PostgreSQL verwenden**  
  → `traccar.xml` anpassen: `database.driver`, `database.url`, `database.user`, `database.password`

- **HTTPS aktivieren**  
  → Zertifikat generieren und `conf/traccar.xml` erweitern mit SSL-Einträgen

- **Benachrichtigungen (z. B. E-Mail, Webhook, Telegram)**  
  → https://www.traccar.org/notifications/

- **Webinterface-Design anpassen**  
  → `/opt/traccar-src/traccar-web` bearbeiten, erneut `npm run build` ausführen

---

## 📁 Verzeichnisse

| Pfad                     | Beschreibung                          |
|--------------------------|----------------------------------------|
| `/opt/traccar`           | Zielverzeichnis der fertigen Installation |
| `/opt/traccar-src`       | Klon des Traccar-Source-Repos         |
| `/opt/traccar/web`       | Kompiliertes Webinterface              |
| `/opt/traccar/conf`      | Konfiguration (`traccar.xml`)         |
| `/opt/traccar/logs`      | Logdateien                             |

---

## 📌 Bekannte Einschränkungen

- Traccar ist nach der Installation **nicht über HTTPS erreichbar**
- Datenbank ist **standardmäßig lokal und nicht gesichert**
- Webinterface ist groß – Build-Warnung bzgl. Dateigröße kann ignoriert werden
- Port-Konflikte möglich (wenn 8082 belegt ist)

---

## 🛠️ Probleme beheben

- **Build schlägt fehl wegen Node-Version**  
  → Stelle sicher, dass `node -v` mindestens `v20.19.0` oder `v22.x` ist

- **Webinterface fehlt**  
  → Prüfe ob `/opt/traccar/web/index.html` existiert  
  → Sonst `cd /opt/traccar-src/traccar-web && npm run build` erneut ausführen

- **Fehlermeldung beim Start**  
  → Logs prüfen: `/opt/traccar/logs/tracker-server.log`

---

## 📜 Lizenz

Dieses Setup basiert auf dem offiziellen Open-Source-Projekt [Traccar](https://github.com/traccar/traccar) unter der Apache 2.0 Lizenz.  
Anpassungen und Installationsskript © 2025 DeinName

---

## 💡 Hinweis

Dies ist kein offizielles Traccar-Installationsskript. Verwende es auf eigene Verantwortung und prüfe vor Produktiveinsatz, ob die Einstellungen deinen Anforderungen genügen.
