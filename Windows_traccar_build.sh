#!/usr/bin/env bash
set -euo pipefail

# ================================
# Konfiguration
# ================================
REPO_URL="${REPO_URL:-https://github.com/traccar/traccar.git}"
WORKDIR_ROOT="${WORKDIR_ROOT:-/opt}"
SRC_DIR="${WORKDIR_ROOT}/traccar-src"
OUT_ROOT="${WORKDIR_ROOT}/traccar-builds"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_ROOT}/win-bundle-${TS}"
ZIP_PATH="${OUT_ROOT}/traccar-windows-bundle-${TS}.zip"

# Optional: Patch setzen (1 = aktiv)
PATCH_FORWARDER="${PATCH_FORWARDER:-0}"

# Node LTS Version (stabile Wahl für Builds). Bei Bedarf: NODE_MAJOR=22 setzen.
NODE_MAJOR="${NODE_MAJOR:-20}"

# ================================
# Helfer
# ================================
log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[✗] $*\033[0m" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Fehlt: $1"; }

# Root-/sudo-Handling (LXC-freundlich)
if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

# ================================
# Pakete installieren (Debian/Ubuntu)
# ================================
if command -v apt >/dev/null 2>&1; then
  log "Pakete installieren (apt)"
  $SUDO apt update
  $SUDO apt install -y git curl unzip ca-certificates build-essential openjdk-17-jdk
else
  warn "Kein apt gefunden – setze voraus, dass Git + Java 17 vorhanden sind."
fi

need_cmd git
need_cmd curl
need_cmd javac
need_cmd java

# Java-Version checken (mind. 17)
JAVA_VER="$(java -version 2>&1 | head -n1)"
echo "Java: ${JAVA_VER}"
echo "${JAVA_VER}" | grep -Eq '\"(1[7-9]|2[0-9])' || warn "Stelle sicher, dass Java 17+ installiert ist."

# ================================
# Node über nvm (für Web-UI Build)
# ================================
if ! command -v npm >/dev/null 2>&1; then
  log "nvm + Node ${NODE_MAJOR} installieren"
  export NVM_DIR="${HOME}/.nvm"
  if [[ ! -d "${NVM_DIR}" ]]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  # shellcheck disable=SC1090
  source "${NVM_DIR}/nvm.sh"
  nvm install "${NODE_MAJOR}"
  nvm use "${NODE_MAJOR}"
else
  log "Node/NPM vorhanden: $(node -v) / $(npm -v)"
fi

# ================================
# Quellcode holen (clean)
# ================================
log "Alte Quellen entfernen"
$SUDO rm -rf "${SRC_DIR}"
$SUDO mkdir -p "${SRC_DIR}"
$SUDO chown -R "$(id -u)":"$(id -g)" "${SRC_DIR}"

log "Repo klonen (mit Submodules)"
git clone --recursive "${REPO_URL}" "${SRC_DIR}"
cd "${SRC_DIR}"

# ================================
# Optionaler Patch (URL-Forwarder Felder)
# ================================
if [[ "${PATCH_FORWARDER}" == "1" ]]; then
  TARGET_FILE="src/main/java/org/traccar/forward/PositionForwarderUrl.java"
  if [[ -f "${TARGET_FILE}" ]]; then
    log "Patch auf ${TARGET_FILE} (batteryLevel/charge Platzhalter)"
    sed -i 's|\.replace("{statusCode}", calculateStatus(position));|.replace("{statusCode}", calculateStatus(position))\
        .replace("{batteryLevel}", String.valueOf(position.getAttributes().getOrDefault("batteryLevel", "")))\
        .replace("{charge}", String.valueOf(position.getAttributes().getOrDefault("charge", "")));|' \
      "${TARGET_FILE}" || warn "Patch fehlgeschlagen (prüfe Quelltext-Version)"
  else
    warn "Patch-Datei nicht gefunden: ${TARGET_FILE} (andere Branch/Version?)"
  fi
fi

# ================================
# Build (Server, Gradle Wrapper)
# ================================
log "Baue Traccar Server (Gradle Wrapper)"
chmod +x ./gradlew
./gradlew --no-daemon clean assemble -Dfile.encoding=UTF-8

# Ergebnis-JAR finden (robust)
log "Suche Server-JAR in build/libs"
JAR_PATH="$(find build/libs -maxdepth 1 -type f \( -name '*server*.jar' -o -name 'tracker-server*.jar' \) | sort | tail -n1)"
[[ -n "${JAR_PATH}" && -f "${JAR_PATH}" ]] || die "Konnte Server-JAR nicht finden (build/libs/*server*.jar)."
echo "Gefundene JAR: ${JAR_PATH}"

# ================================
# Web-UI bauen (modern bevorzugt)
# ================================
WEB_SRC=""
if [[ -d "modern" ]]; then
  WEB_SRC="modern"
elif [[ -d "traccar-web" ]]; then
  WEB_SRC="traccar-web"
else
  warn "Keine moderne Web-UI gefunden (weder modern/ noch traccar-web/). Überspringe UI-Build."
fi

if [[ -n "${WEB_SRC}" ]]; then
  log "Baue Web-UI in ${WEB_SRC}"
  pushd "${WEB_SRC}" >/dev/null
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
  npm run build
  popd >/dev/null
fi

# ================================
# Windows-Bundle strukturieren
# ================================
log "Erzeuge Windows-Bundle unter ${OUT_DIR}"
mkdir -p "${OUT_DIR}"/{conf,logs,web,schema,data}

# JAR kopieren
cp -f "${JAR_PATH}" "${OUT_DIR}/tracker-server.jar"

# Schema kopieren (empfohlen)
if [[ -d "schema" ]]; then
  cp -a schema/* "${OUT_DIR}/schema/" || warn "Schema-Kopieren fehlgeschlagen"
else
  warn "Kein schema/-Ordner gefunden."
fi

# Web-UI Output kopieren
if [[ -n "${WEB_SRC}" ]]; then
  if   [[ -d "${WEB_SRC}/dist"  ]]; then cp -a "${WEB_SRC}/dist/."  "${OUT_DIR}/web/"
  elif [[ -d "${WEB_SRC}/build" ]]; then cp -a "${WEB_SRC}/build/." "${OUT_DIR}/web/"
  else warn "Web-UI Build-Output (dist/ oder build/) nicht gefunden."
  fi
fi

# Minimale Beispiel-Konfiguration (H2 lokal)
cat > "${OUT_DIR}/conf/traccar.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE properties SYSTEM 'http://java.sun.com/dtd/properties.dtd'>
<properties>
  <entry key='database.driver'>org.h2.Driver</entry>
  <entry key='database.url'>jdbc:h2:./data/database</entry>
  <entry key='database.user'>sa</entry>
  <entry key='database.password'></entry>
  <entry key='web.port'>8082</entry>
  <!-- Optional:
  <entry key='forward.enable'>true</entry>
  <entry key='forward.url'>http://127.0.0.1:8080/?id={uniqueId}&amp;lat={latitude}&amp;lon={longitude}</entry>
  -->
</properties>
XML

# Windows-Startskript
cat > "${OUT_DIR}/run-traccar.cmd" <<'BAT'
@echo off
setlocal
REM Startet Traccar portabel (Java 17+ im PATH erforderlich)
cd /d "%~dp0"
java -Dfile.encoding=UTF-8 -jar tracker-server.jar conf\traccar.xml
endlocal
BAT

# README
cat > "${OUT_DIR}/README.txt" <<'TXT'
Traccar – Windows Portable Bundle
=================================
Inhalt:
- tracker-server.jar
- conf\traccar.xml
- web\ (moderne Web-UI, falls gebaut)
- schema\
- logs\ (leer)
- data\ (H2-Datenbank)
- run-traccar.cmd

Schnellstart (Windows):
1) Java 17 oder 21 installieren (z. B. Adoptium Temurin).
2) Ordner z. B. nach C:\traccar\ kopieren.
3) run-traccar.cmd doppelklicken.
4) Web-GUI: http://localhost:8082  (Login: admin / admin)

Alternativ:
- Offiziellen Windows-Installer nutzen, Dienst stoppen,
  JAR und ggf. web\ in "C:\Program Files\Traccar\" ersetzen,
  Dienst starten.
TXT

# ================================
# ZIP erzeugen
# ================================
mkdir -p "${OUT_ROOT}"
log "Erzeuge ZIP: ${ZIP_PATH}"
(
  cd "${OUT_DIR%/*}"
  zip -r "${ZIP_PATH}" "$(basename "${OUT_DIR}")" >/dev/null
)

log "Fertig!"
echo "Bundle-Verzeichnis:  ${OUT_DIR}"
echo "Windows-ZIP:         ${ZIP_PATH}"

echo
echo "Deployment:"
echo "  A) Portable: ZIP auf Windows entpacken, run-traccar.cmd doppelklicken."
echo "  B) Installer: Offiziellen Windows-Installer, dann JAR/Web ersetzen."
