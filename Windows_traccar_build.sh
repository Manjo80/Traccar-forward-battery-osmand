#!/usr/bin/env bash
set -euo pipefail

# ================================
# Konfiguration
# ================================
REPO_URL="${REPO_URL:-https://github.com/traccar/traccar.git}"
WORKDIR_ROOT="${WORKDIR_ROOT:-/opt}"
OUT_ROOT="${WORKDIR_ROOT}/traccar-builds"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_ROOT}/win-bundle-${TS}"
ZIP_PATH="${OUT_ROOT}/traccar-windows-bundle-${TS}.zip"
PATCH_FORWARDER="${PATCH_FORWARDER:-0}"
NODE_MAJOR="${NODE_MAJOR:-20}"

# ================================
# Helferfunktionen
# ================================
log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[✗] $*\033[0m" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Fehlt: $1"; }

[[ $EUID -eq 0 ]] && SUDO="" || SUDO="sudo"

# ================================
# Pakete installieren (Debian/Ubuntu)
# ================================
if command -v apt >/dev/null 2>&1; then
  log "=== Pakete installieren ==="
  $SUDO apt update -y
  $SUDO apt install -y --no-install-recommends \
    ca-certificates wget curl gnupg lsb-release apt-transport-https \
    zip unzip git build-essential net-tools

  # Java 17 prüfen/Installieren
  if ! apt-cache show openjdk-17-jdk >/dev/null 2>&1; then
    warn "openjdk-17-jdk nicht im Repo – installiere Temurin 17"
    wget -O- https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor | $SUDO tee /usr/share/keyrings/adoptium.gpg >/dev/null
    DISTRO_CODENAME="$(lsb_release -cs 2>/dev/null || echo bookworm)"
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${DISTRO_CODENAME} main" | $SUDO tee /etc/apt/sources.list.d/adoptium.list
    $SUDO apt update -y
    $SUDO apt install -y --no-install-recommends temurin-17-jdk
    JAVA_HOME="/usr/lib/jvm/temurin-17-jdk-amd64"
  else
    $SUDO apt install -y --no-install-recommends openjdk-17-jdk
    JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
  fi
else
  die "apt nicht gefunden – unterstütze nur Debian/Ubuntu."
fi

# Java als Standard setzen
if [[ -d "$JAVA_HOME" ]]; then
  log "=== Java 17 als Standard setzen ==="
  update-alternatives --install /usr/bin/java java "$JAVA_HOME/bin/java" 1 || true
  update-alternatives --install /usr/bin/javac javac "$JAVA_HOME/bin/javac" 1 || true
  update-alternatives --set java "$JAVA_HOME/bin/java" || true
  update-alternatives --set javac "$JAVA_HOME/bin/javac" || true
fi
java -version || die "Java wurde nicht korrekt installiert."

# ================================
# Node.js via nvm (für Web-UI)
# ================================
if ! command -v npm >/dev/null 2>&1; then
  log "=== Node.js ${NODE_MAJOR} via nvm installieren ==="
  export NVM_DIR="${HOME}/.nvm"
  if [[ ! -d "${NVM_DIR}" ]]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  # shellcheck disable=SC1090
  source "${NVM_DIR}/nvm.sh"
  nvm install "${NODE_MAJOR}"
  nvm use "${NODE_MAJOR}"
else
  log "Node vorhanden: $(node -v)"
fi

# ================================
# Repo klonen (absoluter Pfad)
# ================================
BUILD_BASE="$(mktemp -d /tmp/traccar-build-XXXXXX)"
SRC_DIR="${BUILD_BASE}/src"
log "=== Repo klonen nach ${SRC_DIR} ==="
git clone --recursive "${REPO_URL}" "${SRC_DIR}"
cd "${SRC_DIR}"

# ================================
# Optionaler Patch (Forwarder)
# ================================
if [[ "${PATCH_FORWARDER}" == "1" ]]; then
  TARGET_FILE="src/main/java/org/traccar/forward/PositionForwarderUrl.java"
  if [[ -f "${TARGET_FILE}" ]]; then
    log "Patch anwenden an ${TARGET_FILE}"
    sed -i 's|\.replace("{statusCode}", calculateStatus(position));|.replace("{statusCode}", calculateStatus(position))\
        .replace("{batteryLevel}", String.valueOf(position.getAttributes().getOrDefault("batteryLevel", \"\")))\
        .replace("{charge}", String.valueOf(position.getAttributes().getOrDefault("charge", \"\")));|' \
      "${TARGET_FILE}" || warn "Patch fehlgeschlagen"
  else
    warn "Patch-Datei nicht gefunden: ${TARGET_FILE}"
  fi
fi

# ================================
# Abfrage Forward IP & Port
# ================================
read -p "Ziel-IP oder Domain für Forwarding (z.B. 192.168.1.100): " FORWARD_IP
read -p "Ziel-Port für Forwarding (z.B. 8080): " FORWARD_PORT

# ================================
# Server-Build: assemble
# ================================
log "=== Starte Gradle-Build: assemble ==="
chmod +x ./gradlew
./gradlew --no-daemon clean assemble -Dfile.encoding=UTF-8

# Ergebnis-JAR suchen
log "=== Suche nach tracker-server.jar ==="
JAR_PATH="$(find "${SRC_DIR}" -type f -name "tracker-server*.jar" 2>/dev/null | grep -E "(target|build/libs)" | sort | tail -n1)"
[[ -f "$JAR_PATH" ]] || die "Konnte tracker-server.jar nicht finden."
echo "→ Gefundene JAR: $JAR_PATH"

# ================================
# Web-UI bauen
# ================================
WEB_SRC=""
if [[ -d "${SRC_DIR}/modern" ]]; then
  WEB_SRC="modern"
elif [[ -d "${SRC_DIR}/traccar-web" ]]; then
  WEB_SRC="traccar-web"
fi

if [[ -n "${WEB_SRC}" ]]; then
  log "=== Baue Web-UI (${WEB_SRC}) ==="
  pushd "${SRC_DIR}/${WEB_SRC}" >/dev/null
  if [[ -f package-lock.json ]]; then npm ci; else npm install; fi
  npm run build
  popd >/dev/null
else
  warn "Keine moderne Web-UI gefunden."
fi

# ================================
# Windows-Bundle erstellen
# ================================
log "=== Erstelle Windows-Bundle unter ${OUT_DIR} ==="
mkdir -p "${OUT_DIR}"/{conf,logs,web,schema,data,lib}

# JAR in lib kopieren
cp -f "$JAR_PATH" "${OUT_DIR}/lib/"

# Alle möglichen Libs kopieren
if [[ -d "${SRC_DIR}/build/libs" ]]; then
  cp -a "${SRC_DIR}/build/libs/." "${OUT_DIR}/lib/"
elif [[ -d "${SRC_DIR}/target" ]]; then
  cp -a "${SRC_DIR}/target/." "${OUT_DIR}/lib/"
fi

# Schema kopieren (falls vorhanden)
[[ -d "${SRC_DIR}/schema" ]] && cp -a "${SRC_DIR}/schema/." "${OUT_DIR}/schema/" || warn "kein schema-Ordner gefunden."

# Web-UI Output übernehmen
if [[ -n "${WEB_SRC}" ]]; then
  if [[ -d "${SRC_DIR}/${WEB_SRC}/build" ]]; then
    log "Kopiere Web-UI aus build/"
    cp -r "${SRC_DIR}/${WEB_SRC}/build/." "${OUT_DIR}/web/"
  elif [[ -d "${SRC_DIR}/${WEB_SRC}/dist" ]]; then
    log "Kopiere Web-UI aus dist/"
    cp -r "${SRC_DIR}/${WEB_SRC}/dist/." "${OUT_DIR}/web/"
  else
    warn "Kein Web-UI-Output-Ordner gefunden (build/ oder dist/). Web-UI wird nicht übernommen."
  fi
fi

# Minimal-Konfiguration mit forward.url
cat > "${OUT_DIR}/conf/traccar.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE properties SYSTEM 'http://java.sun.com/dtd/properties.dtd'>
<properties>
  <entry key='database.driver'>org.h2.Driver</entry>
  <entry key='database.url'>jdbc:h2:./data/database</entry>
  <entry key='database.user'>sa</entry>
  <entry key='database.password'></entry>

  <entry key='forward.enable'>true</entry>
  <entry key='forward.url'>http://${FORWARD_IP}:${FORWARD_PORT}/?id={uniqueId}&amp;timestamp={fixTime}&amp;lat={latitude}&amp;lon={longitude}&amp;speed={speed}&amp;bearing={course}&amp;altitude={altitude}&amp;accuracy={accuracy}&amp;status={statusCode}&amp;batt={batteryLevel}</entry>

  <entry key='web.port'>8082</entry>
</properties>
EOF

# Windows-Startskript mit Classpath
cat > "${OUT_DIR}/run-traccar.cmd" <<'BAT'
@echo off
setlocal
cd /d "%~dp0"
REM Java 17+ im PATH erforderlich
java -cp "lib/*" org.traccar.Main conf\traccar.xml
endlocal
BAT

# README
cat > "${OUT_DIR}/README.txt" <<'TXT'
Traccar – Windows Portable Bundle
===============================
Inhalt:
- lib\ (JARs inkl. tracker-server.jar)
- conf\traccar.xml
- web\ (falls gebaut)
- schema\
- data\
- run-traccar.cmd

Start unter Windows:
1) Java 17 (Adoptium Temurin) installieren und in PATH.
2) Ordner z. B. nach C:\traccar\ kopieren.
3) run-traccar.cmd doppelklicken.
Web-GUI: http://localhost:8082 (Login: admin / admin)
TXT

# ================================
# ZIP erzeugen
# ================================
mkdir -p "${OUT_ROOT}"
log "=== Erzeuge ZIP ==="
(
  cd "${OUT_DIR%/*}"
  zip -r "${ZIP_PATH}" "$(basename "${OUT_DIR}")" >/dev/null
)
log "✅ Build abgeschlossen!"
echo "Bundle-Verzeichnis:   ${OUT_DIR}"
echo "ZIP-Datei:             ${ZIP_PATH}"
