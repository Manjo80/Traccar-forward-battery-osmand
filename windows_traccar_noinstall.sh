#!/usr/bin/env bash
set -euo pipefail

# ================================
# Konfiguration
# ================================
REPO_URL="${REPO_URL:-https://github.com/traccar/traccar.git}"
WORKDIR_ROOT="${WORKDIR_ROOT:-/opt}"
OUT_ROOT="${WORKDIR_ROOT}/traccar-builds"

PATCH_FORWARDER="${PATCH_FORWARDER:-1}"
NODE_MAJOR="${NODE_MAJOR:-20}"

# Packr / EXE
EXE_NAME="${EXE_NAME:-traccar-server}"
MAINCLASS="${MAINCLASS:-org.traccar.Main}"

PACKR_VER="${PACKR_VER:-4.0.0}"
PACKR_URL="https://github.com/libgdx/packr/releases/download/${PACKR_VER}/packr-all-${PACKR_VER}.jar"

# Windows JRE 17 x64 HotSpot (Adoptium)
JRE_API_URL="${JRE_API_URL:-https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jre/hotspot/normal/eclipse}"

# Final output:
FINAL_DIR="${OUT_ROOT}/traccar"        # Ordner der im ZIP drin ist
ZIP_PATH="${OUT_ROOT}/traccar.zip"

# ================================
# Helferfunktionen
# ================================
log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[?] $*\033[0m" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Fehlt: $1"; }

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
else
  die "apt nicht gefunden – unterstütze nur Debian/Ubuntu."
fi

# Java 17 prüfen/Installieren
if ! command -v java >/dev/null 2>&1; then
  if apt-cache show openjdk-17-jdk >/dev/null 2>&1; then
    $SUDO apt install -y --no-install-recommends openjdk-17-jdk
    JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
  else
    warn "openjdk-17-jdk nicht im Repo – installiere Temurin 17"
    wget -O- https://packages.adoptium.net/artifactory/api/gpg/key/public \
      | gpg --dearmor \
      | $SUDO tee /usr/share/keyrings/adoptium.gpg >/dev/null
    DISTRO_CODENAME="$(lsb_release -cs 2>/dev/null || echo bookworm)"
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${DISTRO_CODENAME} main" \
      | $SUDO tee /etc/apt/sources.list.d/adoptium.list >/dev/null
    $SUDO apt update -y
    $SUDO apt install -y --no-install-recommends temurin-17-jdk
    JAVA_HOME="/usr/lib/jvm/temurin-17-jdk-amd64"
  fi
fi

# Java als Standard setzen
if [[ -d "${JAVA_HOME:-}" ]]; then
  log "=== Java 17 als Standard setzen ==="
  $SUDO update-alternatives --install /usr/bin/java java "$JAVA_HOME/bin/java" 1 || true
  $SUDO update-alternatives --install /usr/bin/javac javac "$JAVA_HOME/bin/javac" 1 || true
  $SUDO update-alternatives --set java "$JAVA_HOME/bin/java" || true
  $SUDO update-alternatives --set javac "$JAVA_HOME/bin/javac" || true
fi
java -version >/dev/null 2>&1 || die "Java wurde nicht korrekt installiert."

# Tools
need git; need wget; need unzip; need zip; need java; need curl

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
# Repo klonen
# ================================
BUILD_BASE="$(mktemp -d /tmp/traccar-build-XXXXXX)"
SRC_DIR="${BUILD_BASE}/src"
log "=== Repo klonen nach ${SRC_DIR} ==="
git clone --recursive "${REPO_URL}" "${SRC_DIR}"
cd "${SRC_DIR}"

PACKR_WORK="${BUILD_BASE}/packr-work"
PACKR_OUT="${BUILD_BASE}/packr-out"

# ================================
# Optionaler Patch (Forwarder)
# ================================
if [[ "${PATCH_FORWARDER}" == "1" ]]; then
  TARGET_FILE="src/main/java/org/traccar/forward/PositionForwarderUrl.java"
  if [[ -f "${TARGET_FILE}" ]]; then
    log "Patch anwenden an ${TARGET_FILE}"
    sed -i 's|\.replace("{statusCode}", calculateStatus(position));|.replace("{statusCode}", calculateStatus(position))\
        .replace("{batteryLevel}", String.valueOf(position.getAttributes().getOrDefault("batteryLevel", "")))\
        .replace("{charge}", String.valueOf(position.getAttributes().getOrDefault("charge", "")));|' \
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
# Server-Build
# ================================
log "=== Gradle: clean assemble ==="
chmod +x ./gradlew
./gradlew --no-daemon clean assemble -Dfile.encoding=UTF-8

# Ergebnis-JAR suchen
log "=== Suche nach tracker-server.jar ==="
JAR_PATH="$(find "${SRC_DIR}" -type f -name "tracker-server*.jar" 2>/dev/null | grep -E "(target|build/libs)" | sort | tail -n1)"
[[ -f "$JAR_PATH" ]] || die "Konnte tracker-server.jar nicht finden."
log "? Gefundene JAR: $JAR_PATH"

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
# Ziel-Ordner sauber neu anlegen
# ================================
log "=== Zielordner vorbereiten: ${FINAL_DIR} ==="
rm -rf "${FINAL_DIR}" "${ZIP_PATH}"
mkdir -p "${FINAL_DIR}"/{conf,logs,web,schema,data,lib}

# ================================
# Runtime-Dependencies nach lib/ kopieren (Gradle init-script)
# ================================
log "=== Kopiere runtimeClasspath nach lib/ (Guice/SLF4J/etc) ==="
INIT_SCRIPT="${BUILD_BASE}/copyRuntimeDeps.gradle"
cat > "${INIT_SCRIPT}" <<'GRADLE'
def outDir = System.getenv("OUT_LIB_DIR")
if (outDir == null || outDir.trim().isEmpty()) {
  throw new GradleException("OUT_LIB_DIR env not set")
}

allprojects { p ->
  p.afterEvaluate {
    def cpConf = null
    if (p.configurations.findByName('runtimeClasspath')) cpConf = p.configurations.runtimeClasspath
    else if (p.configurations.findByName('runtime')) cpConf = p.configurations.runtime

    if (cpConf != null) {
      p.tasks.register("copyRuntimeDeps", Copy) {
        from cpConf
        include "*.jar"
        into outDir
      }
    }
  }
}
GRADLE

export OUT_LIB_DIR="${FINAL_DIR}/lib"

# alle copyRuntimeDeps Tasks sammeln und ausführen
TASKS="$(./gradlew -q -I "${INIT_SCRIPT}" tasks --all | awk '/copyRuntimeDeps/ {print $1}' | tr '\n' ' ')"
[[ -n "${TASKS// /}" ]] || die "Keine copyRuntimeDeps Tasks gefunden."
./gradlew --no-daemon -I "${INIT_SCRIPT}" ${TASKS} -q

# tracker-server.jar IMMER zusätzlich sicher in lib/
cp -f "$JAR_PATH" "${FINAL_DIR}/lib/"

# Hard fail wenn libs fehlen
JAR_COUNT="$(find "${FINAL_DIR}/lib" -maxdepth 1 -type f -name '*.jar' | wc -l)"
(( JAR_COUNT >= 10 )) || die "Zu wenige JARs in ${FINAL_DIR}/lib (${JAR_COUNT})."

# ================================
# Schema kopieren
# ================================
[[ -d "${SRC_DIR}/schema" ]] && cp -a "${SRC_DIR}/schema/." "${FINAL_DIR}/schema/" || warn "kein schema-Ordner gefunden."

# ================================
# Web-UI Output übernehmen
# ================================
if [[ -n "${WEB_SRC}" ]]; then
  if [[ -d "${SRC_DIR}/${WEB_SRC}/build" ]]; then
    log "Kopiere Web-UI aus build/"
    cp -a "${SRC_DIR}/${WEB_SRC}/build/." "${FINAL_DIR}/web/"
  elif [[ -d "${SRC_DIR}/${WEB_SRC}/dist" ]]; then
    log "Kopiere Web-UI aus dist/"
    cp -a "${SRC_DIR}/${WEB_SRC}/dist/." "${FINAL_DIR}/web/"
  else
    warn "Kein Web-UI-Output (build/ oder dist/)."
  fi
fi

# ================================
# traccar.xml
# ================================
cat > "${FINAL_DIR}/conf/traccar.xml" <<EOF
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

# ================================
# Packr: EXE + embedded Windows JRE bauen
# ================================
log "=== Packr: EXE + Windows JRE bauen ==="
mkdir -p "${PACKR_WORK}" "${PACKR_OUT}"
rm -rf "${PACKR_OUT:?}/"*  # MUSS leer sein

log "Lade Packr ${PACKR_VER}"
wget -q -O "${PACKR_WORK}/packr.jar" "${PACKR_URL}"

log "Lade Windows JRE 17 (Adoptium)"
wget -q -O "${PACKR_WORK}/windows-jre.zip" "${JRE_API_URL}"
rm -rf "${PACKR_WORK}/windows-jre-raw"
unzip -q "${PACKR_WORK}/windows-jre.zip" -d "${PACKR_WORK}/windows-jre-raw"
JRE_DIR="$(find "${PACKR_WORK}/windows-jre-raw" -maxdepth 2 -type d \( -name 'jre-*' -o -name 'jdk-*' \) | head -n1)"
[[ -n "${JRE_DIR}" ]] || die "Konnte Windows-JRE-Verzeichnis nicht finden."

# classpath: alle jars im FINAL_DIR/lib (einzeln an packr, keine Globs)
mapfile -t CP_JARS < <(find "${FINAL_DIR}/lib" -maxdepth 1 -type f -name '*.jar' | sort)
(( ${#CP_JARS[@]} >= 10 )) || die "Zu wenig JARs für Packr (${#CP_JARS[@]})."

PACKR_ARGS=(
  --platform windows64
  --jdk "${JRE_DIR}"
  --executable "${EXE_NAME}"
  --mainclass "${MAINCLASS}"
  --vmargs Xms256m Xmx1024m
  --output "${PACKR_OUT}"
)
for j in "${CP_JARS[@]}"; do
  PACKR_ARGS+=( --classpath "$j" )
done

java -jar "${PACKR_WORK}/packr.jar" "${PACKR_ARGS[@]}"

# EXE + JRE nach FINAL_DIR übernehmen
cp -f "${PACKR_OUT}/${EXE_NAME}.exe" "${FINAL_DIR}/${EXE_NAME}.exe"
rm -rf "${FINAL_DIR}/jre"
cp -a "${PACKR_OUT}/jre" "${FINAL_DIR}/jre"

# ================================
# JSON: WICHTIG -> KEIN "lib/*", sondern jede JAR explizit
# ================================
log "=== Schreibe ${EXE_NAME}.json mit expliziter JAR-Liste ==="
JSON_FILE="${FINAL_DIR}/${EXE_NAME}.json"

# relative Pfade für Windows
REL_JARS=()
while IFS= read -r f; do
  REL_JARS+=( "lib/$(basename "$f")" )
done < <(printf '%s\n' "${CP_JARS[@]}")

# JSON bauen
{
  echo '{'
  echo "  \"mainClass\": \"${MAINCLASS}\","
  echo '  "vmArgs": ["Xms256m", "Xmx1024m"],'
  echo '  "classPath": ['
  for ((i=0; i<${#REL_JARS[@]}; i++)); do
    if (( i < ${#REL_JARS[@]}-1 )); then
      echo "    \"${REL_JARS[$i]}\","
    else
      echo "    \"${REL_JARS[$i]}\""
    fi
  done
  echo '  ]'
  echo '}'
} > "${JSON_FILE}"

# ================================
# Windows Runner / README
# ================================
cat > "${FINAL_DIR}/run-traccar.cmd" <<'BAT'
@echo off
setlocal
cd /d "%~dp0"
REM Start: embedded JRE + classPath aus traccar-server.json
.\traccar-server.exe conf\traccar.xml
endlocal
BAT

cat > "${FINAL_DIR}/README.txt" <<'TXT'
Traccar – Portable Windows (EXE mit eingebettetem JRE)
=====================================================
Start:
  run-traccar.cmd
oder:
  traccar-server.exe conf\traccar.xml

Hinweis:
- Alle JARs liegen in lib\
- traccar-server.json enthält classPath mit JARs (explizit)
TXT

# ================================
# ZIP erzeugen: traccar.zip enthält Ordner "traccar\"
# ================================
log "=== Erzeuge ZIP: ${ZIP_PATH} (Ordner: traccar/) ==="
mkdir -p "${OUT_ROOT}"
(
  cd "${OUT_ROOT}"
  rm -f "${ZIP_PATH}"
  zip -qr "${ZIP_PATH}" "traccar"
)

log "? Fertig."
echo "ZIP:    ${ZIP_PATH}"
echo "Ordner: ${FINAL_DIR}"
echo
log "Windows-Test (schnell):"
echo "  In C:\\traccar\\ ausführen:"
echo "    .\\jre\\bin\\java.exe -cp \"lib\\*\" org.traccar.Main conf\\traccar.xml"
