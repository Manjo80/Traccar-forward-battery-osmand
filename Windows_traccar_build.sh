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
# Helfer
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

  # Java 17 bereitstellen (OpenJDK oder Adoptium)
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
  die "apt nicht gefunden – dieses Skript erwartet Debian/Ubuntu."
fi

# Java als Standard setzen (sofern möglich)
if [[ -d "$JAVA_HOME" ]]; then
  log "=== Java 17 als Standard setzen ==="
  update-alternatives --install /usr/bin/java  java  "$JAVA_HOME/bin/java"  1 || true
  update-alternatives --install /usr/bin/javac javac "$JAVA_HOME/bin/javac" 1 || true
  update-alternatives --set java  "$JAVA_HOME/bin/java"  || true
  update-alternatives --set javac "$JAVA_HOME/bin/javac" || true
fi
java -version || die "Java wurde nicht korrekt installiert."

# ================================
# Node.js via nvm (für Web-Build)
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
    log "Wende Patch auf ${TARGET_FILE} an"
    sed -i 's|\.replace("{statusCode}", calculateStatus(position));|.replace("{statusCode}", calculateStatus(position))\
        .replace("{batteryLevel}", String.valueOf(position.getAttributes().getOrDefault("batteryLevel", "")))\
        .replace("{charge}", String.valueOf(position.getAttributes().getOrDefault("charge", "")));|' \
      "${TARGET_FILE}" || warn "Patch fehlgeschlagen"
  else
    warn "Patch-Datei nicht gefunden: ${TARGET_FILE}"
  fi
fi

# ================================
# Server-Build (inkl. Distribution)
# ================================
log "=== Starte Gradle-Build (installDist) ==="
chmod +x ./gradlew
# installDist erzeugt build/install/traccar/{bin,lib}
./gradlew --no-daemon clean installDist -Dfile.encoding=UTF-8

# Pfade zu Artefakten
DIST_DIR="${SRC_DIR}/build/install/traccar"
LIB_DIR="${DIST_DIR}/lib"
[[ -d "${LIB_DIR}" ]] || die "Lib-Verzeichnis nicht gefunden: ${LIB_DIR}"

# tracker-server*.jar lokalisieren (liegt auch im lib/)
JAR_PATH="$(find "${LIB_DIR}" -maxdepth 1 -type f -name 'tracker-server*.jar' | sort | tail -n1)"
[[ -f "${JAR_PATH}" ]] || die "tracker-server.jar nicht gefunden in ${LIB_DIR}"

# ================================
# Web-UI bauen (modern bevorzugt)
# ================================
WEB_SRC=""
if [[ -d "modern" ]]; then
  WEB_SRC="modern"
elif [[ -d "traccar-web" ]]; then
  WEB_SRC="traccar-web"
fi

if [[ -n "${WEB_SRC}" ]]; then
  log "=== Baue Web-UI in ${WEB_SRC} ==="
  pushd "${WEB_SRC}" >/dev/null
  if [[ -f package-lock.json ]]; then npm ci; else npm install; fi
  npm run build
  popd >/dev/null
else
  warn "Keine moderne Web-UI gefunden."
fi

# ================================
# Windows-Bundle erstellen
# ================================
log "=== Erstelle Windows-Bundle ==="
mkdir -p "${OUT_DIR}"/{conf,logs,web,schema,data,lib}

# Alle Libs + tracker-server.jar kopieren
cp -a "${LIB_DIR}/." "${OUT_DIR}/lib/"

# Schema kopieren (falls vorhanden)
[[ -d "${SRC_DIR}/schema" ]] && cp -a "${SRC_DIR}/schema/." "${OUT_DIR}/schema/" || warn "Kein schema/-Ordner gefunden."

# Web-Output übernehmen
if [[ -n "${WEB_SRC}" ]]; then
  if   [[ -d "${SRC_DIR}/${WEB_SRC}/dist"  ]]; then cp -a "${SRC_DIR}/${WEB_SRC}/dist/."  "${OUT_DIR}/web/"
  elif [[ -d "${SRC_DIR}/${WEB_SRC}/build" ]]; then cp -a "${SRC_DIR}/${WEB_SRC}/build/." "${OUT_DIR}/web/"
  fi
fi

# Minimal-Konfig erstellen
cat > "${OUT_DIR}/conf/traccar.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE properties SYSTEM 'http://java.sun.com/dtd/properties.dtd'>
<properties>
  <entry key='database.driver'>org.h2.Driver</entry>
  <entry key='database.url'>jdbc:h2:./data/database</entry>
  <entry key='database.user'>sa</entry>
  <entry key='database.password'></entry>
  <entry key='web.port'>8082</entry>
</properties>
XML

# Windows-Startskript (nutzt Classpath lib/*)
cat > "${OUT_DIR}/run-traccar.cmd" <<'BAT'
@echo off
setlocal
cd /d "%~dp0"
REM Java 17+ erforderlich (im PATH)
java -cp "lib/*" org.traccar.Main conf\traccar.xml
endlocal
BAT

# README
cat > "${OUT_DIR}/README.txt" <<'TXT'
Traccar – Windows Portable Bundle (mit Dependencies)
====================================================
Inhalt:
- lib\ (ALLE benötigten JARs inkl. tracker-server.jar)
- conf\traccar.xml
- web\ (falls gebaut)
- schema\
- data\
- run-traccar.cmd

Windows-Start:
1) Java 17 (Adoptium Temurin) installieren und in PATH haben.
2) Ordner nach C:\traccar\ kopieren.
3) run-traccar.cmd doppelklicken.
Web-GUI: http://localhost:8082  (Login: admin / admin)
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
echo "Bundle-Verzeichnis:  ${OUT_DIR}"
echo "Windows-ZIP:         ${ZIP_PATH}"
