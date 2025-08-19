#!/bin/bash
set -e

echo "=== Alte Installation entfernen ==="
systemctl stop traccar 2>/dev/null || true
rm -rf /opt/traccar
rm -rf /opt/traccar-src

echo "=== Quellcode klonen ==="
git clone --recursive https://github.com/traccar/traccar.git /opt/traccar-src
cd /opt/traccar-src

echo "=== Patch PositionForwarderUrl.java einfügen ==="
sed -i 's|\.replace("{statusCode}", calculateStatus(position));|.replace("{statusCode}", calculateStatus(position))\
        .replace("{batteryLevel}", String.valueOf(position.getAttributes().getOrDefault("batteryLevel", "")))\
        .replace("{charge}", String.valueOf(position.getAttributes().getOrDefault("charge", "")));|' \
    src/main/java/org/traccar/forward/PositionForwarderUrl.java

echo "=== Build starten ==="
./gradlew clean build

echo "=== Installation anlegen ==="
mkdir -p /opt/traccar
cp /opt/traccar-src/target/tracker-server.jar /opt/traccar/
cp -r /opt/traccar-src/target/lib /opt/traccar/
cp -r /opt/traccar-src/schema /opt/traccar/schema

echo "=== Konfigurationsdatei erstellen ==="
mkdir -p /opt/traccar/conf
cat <<EOF > /opt/traccar/conf/traccar.xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE properties SYSTEM 'http://java.sun.com/dtd/properties.dtd'>
<properties>

    <!-- Documentation: https://www.traccar.org/configuration-file/ -->

    <entry key='database.driver'>org.h2.Driver</entry>
    <entry key='database.url'>jdbc:h2:./data/database</entry>
    <entry key='database.user'>sa</entry>
    <entry key='database.password'></entry>
    <entry key='forward.enable'>true</entry>
    <entry key='forward.url'>http://tracker.oteg.lu:5055/?id={uniqueId}&amp;timestamp={fixTime}&amp;lat={latitude}&amp;lon={longitude}&amp;speed={speed}&amp;bearing={course}&amp;altitude={altitude}&amp;accuracy={accuracy}&amp;status={statusCode}&amp;batt={batteryLevel}</entry>
</properties>
EOF

echo "=== Logs-Verzeichnis und Datei erstellen ==="
mkdir -p /opt/traccar/logs
touch /opt/traccar/logs/tracker-server.log
chown -R root:root /opt/traccar/logs /opt/traccar/logs/tracker-server.log
chmod 666 /opt/traccar/logs/tracker-server.log

echo "=== systemd Dienst einrichten ==="
cat <<EOF > /etc/systemd/system/traccar.service
[Unit]
Description=Traccar GPS Tracking Server
After=network.target

[Service]
WorkingDirectory=/opt/traccar
ExecStart=/usr/lib/jvm/java-17-openjdk-amd64/bin/java -jar tracker-server.jar conf/traccar.xml
SuccessExitStatus=143
TimeoutStopSec=10
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "=== systemd neu laden & aktivieren ==="
systemctl daemon-reload
systemctl enable traccar

echo "=== Dienst starten ==="
systemctl start traccar

echo "=== Status anzeigen ==="
sleep 2
systemctl status traccar --no-pager
 
