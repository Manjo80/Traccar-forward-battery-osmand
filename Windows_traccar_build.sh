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

PATCH_FORWARDER="${PATCH_FORWARDER:-0}"
NODE_MAJOR="${NODE_MAJOR:-20}"

# ================================
# Helper
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
  # Prüfen ob openjdk-17 existiert
  if ! apt-cache show openjdk-17-jdk >/dev/null 2>&1; then
    warn "openjdk-17-jdk nicht im Repo gefunden – Adoptium-Repository hinzufügen."
    $SUDO apt install -y wget gnupg software-properties-common
    wget -O- https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor | $SUDO tee /usr/share/keyrings/adoptium.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | $SUDO tee /etc/apt/sources.list.d/adoptium.list
    $SUDO apt update -y
    $SUDO apt install -y temurin-17-jdk
    JAVA_HOME="/usr/lib/jvm/temurin-17-jdk-amd64"
  else
    $SUDO apt install -y gradle openjdk-17-jdk curl unzip build-essential net-tools git
    JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
  fi
else
  die "apt nicht gefunden – unterstütze derzeit nur Debian/Ubuntu."
fi

# ================================
# Java 17 als Standard setzen
# ================================
if [[ -d "$JAVA_HOME" ]]; then
  log "=== Java 17 als Standard setzen ==="
  update-alternatives --install /usr/bin/java java "$JAVA_HOME/bin/java" 1 || true
  update-alternatives --install /usr/bin/javac javac "$JAVA_HOME/bin/javac" 1 || true
  update-alternatives --set java "$JAVA_HOME/bin/java" || true
  update-alternatives --set javac "$JAVA_HOME/bin/javac" || true
else
  warn "JAVA_HOME nicht gefunden, überspringe update-alternatives."
fi

java -version || die "Java wurde nicht korrekt installiert."
javac -version || die "javac nicht verfügbar."

# ================================
# Node.js via nvm
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
# Quellcode klonen
# ================================
log "=== Alte Quellen entfernen ==="
rm -rf "${SRC_DIR}"
mkdir -p "${SRC_DIR}"

log "=== Repo klonen ==="
git clone --recursive "${REPO_URL}" "${SRC_DIR}"
cd "${SRC_DIR}"

# ================================
# Patch einfügen
# ================================
if [[ "${PATCH_FORWARDER}" == "1" ]]; then
  log "=== Patch PositionForwarderUrl.java einfügen ==="
  sed -i 's|\.replace("{statusCode}", calculateStatus(position));|.replace("{statusCode}", calculateStatus(position))\
      .replace("{batteryLevel}", String.valueOf(position.getAttributes().getOrDefault("batteryLevel", "")))\
      .replace("{charge}", String.valueOf(position.getAttributes().getOrDefault("charge", "")));|' \
      src/main/java/org/traccar/forward/PositionForwarderUrl.java || warn "Patch konnte nicht angewendet werden"
fi

# ================================
# Build starten
# ================================
log "=== Build starten ==="
chmod +x ./gradlew
./gradlew --no-daemon clean assemble -Dfile.encoding=UTF-8

JAR_PATH="$(find build/libs -maxdepth 1 -type f -name '*server*.jar' | sort | tail -n1)"
[[ -f "$JAR_PATH" ]] || die "Build fehlgeschlagen – keine JAR gefunden."

# ================================
# Web-UI bauen
# ================================
if [[ -d "modern" || -d "traccar-web" ]]; then
  WEB_DIR=$( [[ -d "modern" ]] && echo "modern" || echo "traccar-web" )
  log "=== Web-Interface (${WEB_DIR}) bauen ==="
  pushd "${WEB_DIR}" >/dev/null
  npm install --legacy-peer-deps
  npm run build
  popd >/dev/null
else
  warn "Kein Web-Verzeichnis gefunden, überspringe UI-Build."
fi

# ================================
# Windows-Bundle erstellen
# ================================
log "=== Windows-Bundle erstellen ==="
mkdir -p "${OUT_DIR}"/{conf,logs,web,schema,data}
cp -f "$JAR_PATH" "${OUT_DIR}/tracker-server.jar"
[[ -d "schema" ]] && cp -a schema/* "${OUT_DIR}/schema/" || warn "Kein schema/-Ordner."

# Web-Build übernehmen
if [[ -d "${WEB_DIR}/dist" ]]; then
  cp -a "${WEB_DIR}/dist/." "${OUT_DIR}/web/"
elif [[ -d "${WEB_DIR}/build" ]]; then
  cp -a "${WEB_DIR}/build/." "${OUT_DIR}/web/"
fi

# Konfiguration hinzufügen
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

# CMD-Starter für Windows
cat > "${OUT_DIR}/run-traccar.cmd" <<'BAT'
@echo off
cd /d "%~dp0"
java -Dfile.encoding=UTF-8 -jar tracker-server.jar conf\traccar.xml
BAT

# ================================
# ZIP erzeugen
# ================================
mkdir -p "${OUT_ROOT}"
log "=== ZIP erzeugen ==="
(
  cd "${OUT_DIR%/*}"
  zip -r "${ZIP_PATH}" "$(basename "${OUT_DIR}")" >/dev/null
)
log "✅ Build abgeschlossen!"
echo "→ Bundle: ${OUT_DIR}"
echo "→ ZIP: ${ZIP_PATH}"
