# 03 – Hardening: SSH, fail2ban, UFW

> **Voraussetzung:** `01_vnet_and_nsg.md` und `02_compute_edge_web_vm.md` sind vollständig umgesetzt (VNet, Subnetze, NSGs, Edge-VM, Web-VM).
>
> **Beispielkonfiguration**
>
> * Subscription: `<subscription>`
> * Region: `<azure-region>`
> * Resource Group: `rg-<project>-<environment>-<region>`
> * Betriebssystem beider VMs: **Ubuntu Server 24.04 LTS oder Debian 12 „Bookworm“**
>   Die folgenden Befehle sind auf Debian-/Ubuntu-Derivate mit `apt` und `systemd` ausgelegt.

## 1. Lernziele

* SSH auf beiden VMs absichern: nur Key-Authentifizierung, kein Root-Login, kein Passwort-Login
* `fail2ban` als Schutz gegen wiederholte fehlgeschlagene SSH-Anmeldeversuche einsetzen
* `UFW` als hostbasierte Firewall zusätzlich zur NSG konfigurieren
* Den Unterschied zwischen Azure-Netzwerkregeln und lokaler Betriebssystem-Firewall verstehen
* Eine saubere Zugriffskette für Edge-VM und Web-VM aufbauen
* Sichere Hardening-Schritte nachvollziehbar dokumentieren und verifizieren

## 2. Voraussetzungsprüfung: Zugriff aus Kapitel 02

Bevor mit dem Hardening begonnen wird, sollten die folgenden Punkte geprüft sein:

| Prüfpunkt                    | Erwartung                                                                                                         |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Edge-VM erreichbar           | `ssh -i <pfad-zur-edge-vm>.pem <admin-username>@<edge-public-ip>` funktioniert                                    |
| Web-VM erreichbar            | nur über die Edge-VM als Jump-Host, siehe Abschnitt 3                                                             |
| NSG-Regeln aktiv             | `Allow-SSH-Admin` in `nsg-<project>-dmz` ist weiterhin auf `<admin-ip>/32` beschränkt (Kapitel 01, §4.1)          |
| Aktuelle Admin-IP korrekt    | die in `Allow-SSH-Admin` hinterlegte IP entspricht der aktuellen öffentlichen IP des Admin-Rechners               |
| Private Keys lokal vorhanden | `.pem`-Dateien aus Kapitel 02 liegen lokal vor, Dateinamen geprüft und Rechte gesetzt (`chmod 400` bzw. `icacls`) |

### 2.1 Aktuelle öffentliche IP mit NSG-Regel abgleichen

Da sich die öffentliche IP des Verwaltungszugangs seit Kapitel 01 geändert haben kann, sollte vor Beginn des Hardenings geprüft werden, ob die hinterlegte Regel noch stimmt. Andernfalls ist SSH-Zugriff auf beide VMs nicht mehr möglich.

**Aktuelle öffentliche IP ermitteln:**

* `https://ifconfig.me`
* `https://api.ipify.org`

**Mit der NSG-Regel abgleichen (Azure CLI):**

```bash
az network nsg rule show \
  -g rg-<project>-<environment>-<region> \
  --nsg-name nsg-<project>-dmz \
  -n Allow-SSH-Admin \
  --query "sourceAddressPrefix" -o tsv
```

Stimmen beide Werte nicht überein, muss die Regel zuerst aktualisiert werden:

```bash
az network nsg rule update \
  -g rg-<project>-<environment>-<region> \
  --nsg-name nsg-<project>-dmz \
  -n Allow-SSH-Admin \
  --source-address-prefixes <admin-ip>/32
```

> **Hinweis:** Dieser Abgleich sollte grundsätzlich vor jeder administrativen SSH-Session wiederholt werden, insbesondere bei wechselnden Netzwerken, VPN-Nutzung oder dynamischer IP-Vergabe.

### 2.2 Private IP der Web-VM ermitteln

```bash
az vm list-ip-addresses \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-web-01
```

Der Wert unter `privateIpAddresses` ist `<web-private-ip>` für die folgenden Abschnitte.

> **Wichtig:** Dieses Kapitel verändert ausschließlich die Betriebssystem-Konfiguration innerhalb der VMs. Es werden keine neuen Azure-Ressourcen angelegt und keine NSG-Regeln geändert, außer im Fall von Abschnitt 2.1, falls die Admin-IP aktualisiert werden muss. UFW ergänzt die NSG, ersetzt sie aber nicht.

---

## 3. Zielbild

* **SSH-Hardening** auf beiden VMs: nur Key-Authentifizierung, kein Root-Login, kein Passwort-Login
* **fail2ban** auf beiden VMs: automatische temporäre Sperrung nach wiederholten fehlgeschlagenen SSH-Versuchen
* **UFW** auf beiden VMs: zusätzliche hostbasierte Firewall als zweite Verteidigungslinie neben der NSG

### Zielzustand der VMs

* **Edge-VM:** SSH nur von `<admin-ip>`, HTTP/HTTPS offen für spätere Nutzung durch den Reverse Proxy
* **Web-VM:** SSH und HTTP/HTTPS nur von der privaten IP der Edge-VM (`<edge-private-ip>`)

```text
Admin-Rechner (<admin-ip>)
        |
   SSH (Key-only)
        v
    [Edge-VM] --- UFW: SSH nur von <admin-ip>, HTTP/HTTPS offen
        |
   SSH / HTTP (Key-only, nur von <edge-private-ip>)
        v
    [Web-VM] --- UFW: SSH/HTTP/HTTPS nur von <edge-private-ip>
```

---

## 4. Zugriff auf die VMs

Voraussetzung für alle folgenden Varianten: Abschnitt 2.1 und 2.2 sind abgeschlossen, `<web-private-ip>` ist bekannt, und die Key-Dateien liegen lokal mit korrekten Rechten vor.

### 4.1 Edge-VM direkt verbinden

**Linux:**

```bash
ssh -i <pfad-zur-edge-vm>.pem <admin-username-edge>@<edge-public-ip>
```

**Windows (PowerShell):**

```powershell
ssh -i '<pfad-zur-edge-vm>.pem' <admin-username-edge>@<edge-public-ip>
```

### 4.2 Web-VM über die Edge-VM als Jump-Host

Die Web-VM hat keine öffentliche IP und ist ausschließlich über die Edge-VM erreichbar. Für Linux und Windows werden zwei Varianten gezeigt: ohne Config-Datei mit explizitem `ProxyCommand` und mit SSH-Config.

#### 4.2.1 Linux — ohne Config-Datei

```bash
ssh -i <pfad-zur-web-vm>.pem \
  -o "ProxyCommand=ssh -i <pfad-zur-edge-vm>.pem -W %h:%p <admin-username-edge>@<edge-public-ip>" \
  <admin-username-web>@<web-private-ip>
```

#### 4.2.2 Linux — mit Config-Datei

Datei `~/.ssh/config` anlegen oder ergänzen:

```text
Host edge-vm
    HostName <edge-public-ip>
    User <admin-username-edge>
    IdentityFile <pfad-zur-edge-vm>.pem

Host web-vm
    HostName <web-private-ip>
    User <admin-username-web>
    IdentityFile <pfad-zur-web-vm>.pem
    ProxyJump edge-vm
```

Danach genügt:

```bash
ssh web-vm
```

#### 4.2.3 Windows (PowerShell) — ohne Config-Datei

```powershell
ssh -i '<pfad-zur-web-vm>.pem' -o "ProxyCommand=ssh -i <pfad-zur-edge-vm>.pem -W %h:%p <admin-username-edge>@<edge-public-ip>" <admin-username-web>@<web-private-ip>
```

#### 4.2.4 Windows (PowerShell) — mit Config-Datei

Datei `C:\Users\<username>\.ssh\config` anlegen oder ergänzen:

```text
Host edge-vm
    HostName <edge-public-ip>
    User <admin-username-edge>
    IdentityFile C:/Users/<username>/<pfad>/<edge-vm-key>.pem

Host web-vm
    HostName <web-private-ip>
    User <admin-username-web>
    IdentityFile C:/Users/<username>/<pfad>/<web-vm-key>.pem
    ProxyJump edge-vm
```

> Unter Windows sollten im `IdentityFile`-Pfad entweder Schrägstriche verwendet oder Backslashes korrekt escaped werden.

Danach genügt:

```powershell
ssh web-vm
```

> **Hinweis:** Mehrere `-i`-Flags zusammen mit `-J` können dazu führen, dass der Jump-Host den falschen oder keinen passenden Key anbietet. Die hier gezeigten Varianten mit explizitem `ProxyCommand` oder SSH-Config sind robuster.

---

Alle folgenden Schritte werden auf jeder VM separat ausgeführt, sofern nicht anders vermerkt.

## 5. Pakete beschaffen (`fail2ban`, `python3-systemd`, `ufw`)

Da die Web-VM keinen ausgehenden Internetzugriff hat, werden alle in diesem Kapitel benötigten Pakete einmalig gemeinsam über die Edge-VM heruntergeladen und dann in einem einzigen Transfer zur Web-VM übertragen. Auf der Edge-VM selbst reicht die normale Online-Installation.

### 5.1 Edge-VM: Online installieren

```bash
sudo apt update
sudo apt install -y fail2ban python3-systemd ufw
```

### 5.2 Edge-VM: Pakete zusätzlich als `.deb` sammeln

```bash
mkdir -p ~/offline-pkgs
cd ~/offline-pkgs
sudo apt-get install --reinstall --download-only -y fail2ban python3-systemd ufw
sudo cp /var/cache/apt/archives/*.deb ~/offline-pkgs/
ls ~/offline-pkgs/*.deb
```

### 5.3 Vom lokalen Rechner: Pakete von der Edge-VM abholen

**Linux (lokal):**

```bash
scp -i <pfad-zur-edge-vm>.pem <admin-username-edge>@<edge-public-ip>:~/offline-pkgs/*.deb .
```

**Windows (PowerShell, lokal):**

```powershell
scp -i '<pfad-zur-edge-vm>.pem' <admin-username-edge>@<edge-public-ip>:~/offline-pkgs/*.deb .
```

### 5.4 Vom lokalen Rechner: Pakete zur Web-VM weiterreichen

**Linux (lokal):**

```bash
scp -i <pfad-zur-web-vm>.pem \
  -o "ProxyCommand=ssh -i <pfad-zur-edge-vm>.pem -W %h:%p <admin-username-edge>@<edge-public-ip>" \
  *.deb <admin-username-web>@<web-private-ip>:/tmp/
```

**Windows (PowerShell, lokal):**

```powershell
scp -i '<pfad-zur-web-vm>.pem' -o "ProxyCommand=ssh -i <pfad-zur-edge-vm>.pem -W %h:%p <admin-username-edge>@<edge-public-ip>" *.deb <admin-username-web>@<web-private-ip>:/tmp/
```

> So bleibt der Web-Key ausschließlich auf dem lokalen Rechner; er wird weder auf der Edge-VM abgelegt noch verlässt der Edge-Key den lokalen Rechner in Richtung Web-VM.

### 5.5 Web-VM: Pakete installieren

```bash
cd /tmp
sudo dpkg -i *.deb
sudo apt install -f -y
```

---

## 6. SSH-Hardening

### 6.1 Konfiguration anpassen

Auf **beiden VMs**:

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sudo nano /etc/ssh/sshd_config
```

Folgende Werte setzen bzw. sicherstellen:

```text
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowUsers <admin-username>
```

> **Hinweis zu `AllowUsers`:** Schränkt SSH-Logins auf den angegebenen Benutzer ein. Das ist optional, aber empfohlen, da so auch bei einem versehentlich angelegten Zusatzkonto kein SSH-Zugriff möglich ist.

### 6.2 Konfiguration testen und Dienst neu laden

```bash
sudo sshd -t
```

Wenn der Test keine Fehler meldet:

```bash
sudo systemctl reload ssh
```

> **Wichtig:** Vor dem Schließen der aktuellen SSH-Sitzung in einer zweiten, separaten Sitzung verifizieren, dass der Login weiterhin funktioniert. So wird ein Aussperren durch einen Konfigurationsfehler vermieden.

### 6.3 Verifikation

```bash
sudo sshd -T | grep -Ei "permitrootlogin|passwordauthentication|pubkeyauthentication|challengeresponseauthentication|kbdinteractiveauthentication|x11forwarding|allowusers"
```

Erwartete Ausgabe (Auszug):

```text
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
x11forwarding no
allowusers <admin-user>
```

---

## 7. fail2ban

### 7.1 Konfiguration

Auf **beiden VMs**:

```bash
sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
```

### 7.2 Werte und Zweck

| Parameter  | Wert  | Bedeutung                                                                   |
| ---------- | ----- | --------------------------------------------------------------------------- |
| `maxretry` | `5`   | Toleriert Tippfehler, blockt aber automatisierte Brute-Force-Versuche zügig |
| `findtime` | `10m` | Zeitfenster, in dem die fehlgeschlagenen Versuche gezählt werden            |
| `bantime`  | `1h`  | Moderate Sperrzeit; bei Bedarf auf permanent erweiterbar                    |

### 7.3 Dienst aktivieren

Auf **beiden VMs**:

```bash
sudo systemctl enable --now fail2ban
```

### 7.4 Verifikation

Auf **beiden VMs**:

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

Erwartetes Ergebnis:

```text
Status
|- Number of jail:      1
`- Jail list:   sshd
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:
```

---

## 8. UFW (hostbasierte Firewall)

> **Warnung:** UFW wird über eine bestehende SSH-Sitzung konfiguriert. Die SSH-Regel muss vor dem Aktivieren von UFW gesetzt werden, sonst sperrt man sich selbst aus.

### 8.1 Regeln für die Edge-VM

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow from <admin-ip> to any port 22 proto tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

### 8.2 Regeln für die Web-VM

Für die UFW-Regeln der Web-VM wird die private IP der Edge-VM benötigt:

```bash
az vm list-ip-addresses \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-edge-01
```

Der Wert unter `privateIpAddresses` ist `<edge-private-ip>`.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow from <edge-private-ip> to any port 22 proto tcp
sudo ufw allow from <edge-private-ip> to any port 80 proto tcp
sudo ufw allow from <edge-private-ip> to any port 443 proto tcp
```

### 8.3 Aktivieren

Auf **beiden VMs** erst nach dem Setzen der SSH-Regel:

```bash
sudo ufw enable
```

Die Sicherheitsabfrage mit `y` bestätigen.

### 8.4 Verifikation

```bash
sudo ufw status verbose
```

Erwartetes Ergebnis auf der Edge-VM:

```text
Status: active
To                         Action      From
22/tcp                     ALLOW       <admin-ip>
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere
```

Erwartetes Ergebnis auf der Web-VM:

```text
Status: active
To                         Action      From
22/tcp                     ALLOW       <edge-private-ip>
80/tcp                     ALLOW       <edge-private-ip>
443/tcp                    ALLOW       <edge-private-ip>
```

---

## 9. Umgang mit Lockout-Situationen

### 9.1 Edge-VM: Admin-IP hat sich geändert

Wenn sich die öffentliche IP des Admin-Rechners ändert, greift die UFW-Regel auf der Edge-VM nicht mehr, weil dort noch die alte IP hinterlegt ist. Da UFW den SSH-Zugriff blockiert, muss die Regel dann über Azure Run Command korrigiert werden.

```bash
az vm run-command invoke \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-edge-01 \
  --command-id RunShellScript \
  --scripts "ufw delete allow from <alte-admin-ip> to any port 22 proto tcp; ufw allow from <neue-admin-ip> to any port 22 proto tcp"
```

Falls das nicht ausreicht, kann UFW vorübergehend deaktiviert werden:

```bash
az vm run-command invoke \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-edge-01 \
  --command-id RunShellScript \
  --scripts "ufw disable"
```

### 9.2 Web-VM: Fehlkonfiguration der UFW-Regeln

Die Web-VM-Regel referenziert `<edge-private-ip>`, also eine statische private IP. Ein Lockout entsteht hier typischerweise durch eine Fehlkonfiguration, etwa eine falsche IP oder das Aktivieren von UFW vor dem Setzen der SSH-Regel.

```bash
az vm run-command invoke \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-web-01 \
  --command-id RunShellScript \
  --scripts "ufw allow from <edge-private-ip> to any port 22 proto tcp"
```

Falls das nicht greift, UFW vorübergehend deaktivieren:

```bash
az vm run-command invoke \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-web-01 \
  --command-id RunShellScript \
  --scripts "ufw disable"
```

### 9.3 Danach auf OS-Ebene korrigieren

Sobald der Zugriff wieder möglich ist:

```bash
sudo ufw status numbered
```

Regeln korrigieren:

```bash
sudo ufw allow from <korrekte-ip> to any port 22 proto tcp
sudo ufw delete <zeilennummer-alte-regel>
```

Anschließend wieder aktivieren:

```bash
sudo ufw enable
```

Verifikation:

```bash
sudo ufw status verbose
```

---

## 10. Gesamtverifikation

Das folgende Skript fasst die Prüfungen für die wichtigsten Hardening-Maßnahmen zusammen und meldet je Prüfpunkt `OK` oder `FEHLER`. Es wird auf der jeweiligen VM separat ausgeführt, mit angepasster `EXPECTED_SSH_SOURCE`.

```bash
#!/usr/bin/env bash
set -uo pipefail

EXPECTED_USER="<admin-username>"
EXPECTED_SSH_SOURCE="<admin-ip-oder-edge-private-ip>"

PASS=0
FAIL=0

ok() { echo "OK: $1"; PASS=$((PASS + 1)); }
fail() { echo "FEHLER: $1"; FAIL=$((FAIL + 1)); }

check() {
    if eval "$2"; then
        ok "$1"
    else
        fail "$1"
    fi
}

SSHD="$(sudo sshd -T 2>/dev/null)"
UFW="$(sudo ufw status verbose)"

check "sshd-Konfiguration gültig" "sudo sshd -t >/dev/null 2>&1"

for ENTRY in "permitrootlogin no" "passwordauthentication no" "pubkeyauthentication yes" "challengeresponseauthentication no" "kbdinteractiveauthentication no" "x11forwarding no"; do
    check "$ENTRY" "echo \"$SSHD\" | grep -qi '^${ENTRY}$'"
done

check "AllowUsers = ${EXPECTED_USER}" "echo \"$SSHD\" | grep -qi '^allowusers .*${EXPECTED_USER}'"
check "SSH-Dienst aktiv" "systemctl is-active --quiet ssh"

check "fail2ban aktiv" "systemctl is-active --quiet fail2ban"
check "fail2ban aktiviert" "systemctl is-enabled --quiet fail2ban"
check "sshd-Jail vorhanden" "sudo fail2ban-client status sshd >/dev/null 2>&1"

[[ "$(sudo fail2ban-client get sshd maxretry 2>/dev/null)" == "5" ]] && ok "maxretry = 5" || fail "maxretry = 5"
[[ "$(sudo fail2ban-client get sshd findtime 2>/dev/null)" == "600" ]] && ok "findtime = 10m" || fail "findtime = 10m"
[[ "$(sudo fail2ban-client get sshd bantime 2>/dev/null)" == "3600" ]] && ok "bantime = 1h" || fail "bantime = 1h"

check "UFW aktiv" "echo \"$UFW\" | grep -q '^Status: active'"
check "Default Incoming = deny" "echo \"$UFW\" | grep -qi 'Default: deny (incoming)'"
check "Default Outgoing = allow" "echo \"$UFW\" | grep -qi 'allow (outgoing)'"
check "SSH-Regel vorhanden" "echo \"$UFW\" | grep -Eq '22/tcp.*ALLOW.*${EXPECTED_SSH_SOURCE}'"

echo "$PASS OK, $FAIL FEHLER"

[ "$FAIL" -eq 0 ]
```

---

## 11. Ergebnis

Nach Abschluss dieses Kapitels gilt:

* SSH ist auf beiden VMs auf Key-Authentifizierung reduziert.
* `fail2ban` schützt vor wiederholten fehlgeschlagenen SSH-Anmeldungen.
* UFW ergänzt die NSG durch eine lokale Host-Firewall.
* Die Edge-VM bleibt kontrolliert aus dem Internet erreichbar.
* Die Web-VM ist nur über die Edge-VM zugänglich und bleibt privat.

> **Wichtig:** Dieses Kapitel stärkt die bestehende DMZ-/Private-Workload-Architektur um Hardening auf Betriebssystemebene. Damit wird die Azure-Netzwerksegmentierung nicht ersetzt, sondern sinnvoll ergänzt.
