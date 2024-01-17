# udm-firewall
Regelwerk zur Trennung der Corporate LANS und Guest-Netzwerke, sowie Deaktivierung von NAT bei der UDM Pro.

Werden auf der UDM/UDM Pro mit unifiOS Version 3.x unterschiedliche VLANs verwendet, so kann innerhalb der Sicherheitszonen LAN und Guest zwischen den jeweiligen VLANs ungefiltert kommuniziert werden. Das Firewallregelwerk im Default keine strikte Trennung umsetzt (siehe auch https://nerdig.es/udm-pro-netzwerktrennung-1/). Damit zwischen den VLANS der Datenverkehr eingeschränkt wird, müssen die Filterregeln entsprechend manuell konfiguriert werden. Dazu können Filterregeln in der GUI genutzt werden (siehe z.B. https://ubiquiti-networks-forum.de/wiki/entry/99-firewall-regeln-2-0-by-defcon/). Während das für IPv4 über die RFC1918 Netzwerke über eine Regel für alle Interface realisiert werden kann, ist das bei IPv6 so einfach nicht möglich. Hier müsste für jede Interface kombinsation eine separate Regel angelegt werden. Zusätzlich muss das IPv6-Regelwerk angepasst werden, wenn z.B. ein neues NEtzwerk angelegt wird. Außerdem gibt es in der GUI noch immer keine Option zur Deaktivierung des vorkonfigurierten NAT für IPv4.

Mit diesem Script wird das Standard-Regelwerk der UDM-Pro entsprechend automatisch angepasst.

## Voraussetzungen
Unifi Dream Machine Pro mit UnifiOS Version 3.x. Erfolgreich getestet mit UnifiOS 3.2.7.

## Funktionsweise
Das Script `udm-wireguard.sh` wird bei jedem Systemstart und anschließend alle 90 Sekunden per systemd ausgeführt. Da die von Script erzeugten Firewall-Regeln bei Änderungen an der Netzwerkkonfiguration über die GUI wieder gelöscht werden, wird regelmäßig überprüft, ob die Firewall-Regeln noch passen. Neben dem systemd-Service wird daher auch ein systemd-Timer eingerichtet der das Script alle 90 Sekunden neu startet und die Regeln bei Bedarf wiederherstellt.

## Features
- Generiert Regeln zur Trennung auf der unterschiedlichen LAN- und Guest-VLANs (IPv4 und IPv6)
- Deaktivierung der vordefinierten NAT-Regeln
- Einfügen von Related/Established-Regeln um das Firewall-MAnagement zu vereinfachen
- Ausführen von weiteren Scripten vor und/oder nachdem das Firewall-Regelwerk angepasst wurde 


## Installation
Nachdem eine Verbindung per SSH zur UDM/UDM Pro hergestellt wurde wird udm-wireguard folgendermaßen installiert:

**1. Download der Dateien**
```
mkdir -p /data/custom
dpkg -l git || apt install git
git clone https://github.com/nerdiges/udm-firewall.git /data/custom/firewall
chmod +x /data/custom/wireguard/udm-firewall.sh
```

**2. Parameter im Script anpassen (optional)**

Siehe Absatz **Konfiguration**.

**3. Einrichten der systemd-Services**
```
# Install udm-firewall.service und timer definition file in /etc/systemd/system via:
ln -s /data/custom/firewall/udm-firewall.service /etc/systemd/system/udm-firewall.service
ln -s /data/custom/firewall/udm-firewall.timer /etc/systemd/system/udm-firewall.timer

# Reload systemd, enable and start the service and timer:
systemctl daemon-reload
systemctl enable udm-firewall.service
systemctl start udm-firewall.service
systemctl enable udm-firewall.timer
systemctl start udm-firewall.timer

# check status of service and timer
systemctl status udm-firewall.timer udm-firewall.service
```

## Konfiguration
**Default-Einstellungen:** 

Wurden in der *Unifi Network* Oberfläche zwei Corporate-Network VLANs mit den VLAN-IDs 20 und 21 konfiguriert, so werden in UnifiOS die Interfaces *br20* und *br21* angelegt. Der Traffic *br20* -> *br21* wird dabei grundsätzlich zugelassen (siehe `$exclude`). 

Es werden außerdem Firewall-Regeln erstellt, die das Connection-Tracking aktiviert und Pakete mit dem Status `established`und `related` zulässt (siehe  `$allow_related_lan`und `$allow_related_guest`).

Ist das Script [udm-wireguard](https://github.com/nerdiges/udm-wireguard) installiert, so wird das Script vor der ANpassung der Firewall-REgeln ausgeführt, damit auch die Wireguard-Interfaces entsprechend geschützt werden (siehe `$commands_before`). Nach der Anpassung


Die Konfiguration kann im Script über folgende Variablen angepasst werden:
```
######################################################################################
#
# Configuration
#

# interfaces listed in exclude will not be separted and can still access
# the other VLANs. Multiple interfaces are to be separated by spaces.
exclude="br20"

# Add rule to allow established and related network traffic coming in to LAN interface
allow_related_lan=true

# Add rule to allow established and related network traffic coming in to guest interface
allow_related_guest=true

# Remove predefined NAT rules 
disable_nat=true


# List of commands that should be executed before firewall rules are adopted (e.g. setup 
# wireguard interfaces, before adopting ruleset to ensure wireguard interfaces are 
# considerd when  separating VLANs).
# It is recommended to use absolute paths for the commands.
commands_before=(
    "[ -x /data/custom/wireguard/udm-wireguard.sh ] && /data/custom/wireguard/udm-wireguard.sh"
    ""
)


# List of commands that should be executed after firewall rules are adopted.
# It is recommended to use absolute paths for the commands.
commands_after=(
    ""
)

#
######################################################################################
```



Siehe auch: https://nerdig.es/udm-pro-netzwerktrennung-2/ und https://nerdig.es/udm-pro-3-upgrade/ 

