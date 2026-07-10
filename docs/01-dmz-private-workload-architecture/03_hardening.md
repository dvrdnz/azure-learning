# 03 – Hardening: SSH, fail2ban, UFW

> **Voraussetzung:** `01_vnet_and_nsg.md` und `02_compute_edge_web_vm.md` sind vollständig umgesetzt (VNet, Subnetze, NSGs, Edge-VM, Web-VM).
>
> **Beispielkonfiguration**
>
> * Subscription: `<subscription>`
> * Region: `<azure-region>`
> * Resource Group: `rg-<project>-<environment>-<region>`
> * Betriebssystem beider VMs: **Ubuntu Server 24.04 LTS oder Debian 12 „Bookworm“** (Befehle in diesem Kapitel sind auf Debian/Ubuntu-Derivate mit `apt` und `systemd` ausgelegt)

## 1. Voraussetzungsprüfung: Zugriff aus Kapitel 02

Bevor mit dem Hardening begonnen wird, sicherstellen:

| Prüfpunkt | Erwartung |
|---|---|
| Edge-VM erreichbar | `ssh -i <pfad-zur-edge-vm>.pem <admin-username>@<edge-public-ip>` funktioniert |
| Web-VM erreichbar | nur über Edge-VM als Jump-Host, siehe Abschnitt 3 |
| NSG-Regeln aktiv | `Allow-SSH-Admin` in `nsg-<project>-dmz` weiterhin auf `<admin-ip>/32` beschränkt (Kapitel 01, §4.1) |
| **Aktuelle Admin-IP noch korrekt** | die in `Allow-SSH-Admin` hinterlegte IP entspricht **noch der aktuellen** öffentlichen IP des Admin-Rechners |
| **Private Keys lokal vorhanden** | `.pem`-Dateien aus Kapitel 02 (§4.6 / §5.5) liegen lokal vor, korrekte Dateinamen geprüft und mit korrekten Rechten versehen (Linux: `chmod 400`, Windows: `icacls`) |

### 1.1 Aktuelle öffentliche IP mit NSG-Regel abgleichen

Da sich die öffentliche IP des Verwaltungszugangs seit Kapitel 01 geändert haben kann (z. B. dynamische IP durch den Internetanbieter), vor Beginn des Hardenings prüfen, ob die hinterlegte Regel noch stimmt — sonst ist SSH-Zugriff auf beide VMs nicht mehr möglich.

**Aktuelle öffentliche IP ermitteln:**

1. Vor dem Anlegen der SSH-Regel die öffentliche IPv4-Adresse ermitteln, zum Beispiel über:

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

Stimmen beide Werte (abzüglich `/32`) **nicht** überein, muss die Regel zuerst aktualisiert werden, bevor fortgefahren wird:

```bash
az network nsg rule update \
  -g rg-<project>-<environment>-<region> \
  --nsg-name nsg-<project>-dmz \
  -n Allow-SSH-Admin \
  --source-address-prefixes <admin-ip>/32
```

> **Hinweis:** Dieser Abgleich sollte grundsätzlich vor jeder Session mit administrativem SSH-Zugriff wiederholt werden, nicht nur einmalig vor Kapitel 03 — insbesondere bei wechselnden Netzwerken (Heimnetz, mobiles Netz, VPN).

### 1.2 Private IP der Web-VM ermitteln

```bash
az vm list-ip-addresses \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-web-01
```

Der Wert unter `privateIpAddresses` ist `<web-private-ip>` in den folgenden Abschnitten.

> **Wichtig:** Dieses Kapitel verändert **ausschließlich Betriebssystem-Konfiguration innerhalb der VMs** (SSH-Daemon, fail2ban, UFW). Es werden keine neuen Azure-Ressourcen angelegt und keine NSG-Regeln aus Kapitel 01 verändert (außer im Fall von Abschnitt 1.1, falls die Admin-IP korrigiert werden muss). UFW auf OS-Ebene ergänzt die NSG zusätzliche, ersetzt sie aber nicht.

---

## 2. Zielbild

* **SSH-Hardening** auf beiden VMs: nur Key-Auth, kein Root-Login, kein Passwort-Login.
* **fail2ban** auf beiden VMs: automatische temporäre Sperrung von IPs nach wiederholten fehlgeschlagenen SSH-Versuchen.
* **UFW** auf beiden VMs: host-basierte Firewall als zweite Verteidigungslinie zusätzlich zur NSG.

  * Edge-VM: SSH nur von `<admin-ip>`, HTTP/HTTPS offen (für späteren Reverse-Proxy aus Kapitel 04).
  * Web-VM: SSH und HTTP/HTTPS nur von der **privaten IP der Edge-VM** (`<edge-private-ip>`), da die Web-VM ausschließlich über die Edge-VM erreichbar ist.

```
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

## 3. Zugriff auf die VMs

Voraussetzung für alle folgenden Varianten: Schritte 1.1 und 1.2 sind abgeschlossen, `<web-private-ip>` ist bekannt, Key-Dateien liegen lokal mit korrekten Rechten vor.

### 3.1 Edge-VM (direkt)

**Linux:**

```bash
ssh -i <pfad-zur-edge-vm>.pem <admin-username-edge>@<edge-public-ip>
```

**Windows (PowerShell):**

```powershell
ssh -i '<pfad-zur-edge-vm>.pem' <admin-username-edge>@<edge-public-ip>
```

### 3.2 Web-VM (über Edge-VM als Jump-Host)

Die Web-VM hat keine öffentliche IP und ist ausschließlich über die Edge-VM erreichbar. Für Linux und Windows jeweils zwei gleichwertige Varianten: **ohne Config-Datei** (explizites `ProxyCommand`) und **mit Config-Datei**.

#### 3.2.1 Linux — ohne Config-Datei

```bash
ssh -i <pfad-zur-web-vm>.pem \
  -o "ProxyCommand=ssh -i <pfad-zur-edge-vm>.pem -W %h:%p <admin-username-edge>@<edge-public-ip>" \
  <admin-username-web>@<web-private-ip>
```

#### 3.2.2 Linux — mit Config-Datei

Config-Datei anlegen/ergänzen: `~/.ssh/config`

```
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

#### 3.2.3 Windows (PowerShell) — ohne Config-Datei

```powershell
ssh -i '<pfad-zur-web-vm>.pem' -o "ProxyCommand=ssh -i <pfad-zur-edge-vm>.pem -W %h:%p <admin-username-edge>@<edge-public-ip>" <admin-username-web>@<web-private-ip>
```

#### 3.2.4 Windows (PowerShell) — mit Config-Datei

Config-Datei anlegen/ergänzen: `C:\Users\<username>\.ssh\config`

```
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

> Unter Windows im `IdentityFile`-Pfad Schrägstriche (`C:/Users/...`) statt Backslashes verwenden, oder Backslashes escapen.

Danach genügt:

```powershell
ssh web-vm
```

> **Hinweis:** Beide `-i`-Flags direkt zusammen mit `-J` in einer Zeile (`ssh -i <edge>.pem -J <user>@<edge-ip> -i <web>.pem <user>@<web-ip>`) kann dazu führen, dass der Jump-Host den falschen bzw. keinen passenden Key angeboten bekommt (`Permission denied (publickey)`). Die oben gezeigten Varianten (explizites `ProxyCommand` bzw. Config-Datei) ordnen jeden Key eindeutig seiner Verbindung zu und sind daher robuster.

---

Alle folgenden Schritte werden **auf jeder VM separat** ausgeführt, sofern nicht anders vermerkt.

## 4. Pakete beschaffen (fail2ban, python3-systemd, ufw)

Da die Web-VM keinen ausgehenden Internetzugriff hat, werden **alle** in diesem Kapitel benötigten Pakete (`fail2ban`, `python3-systemd`, `ufw`) **einmalig gemeinsam** über die Edge-VM heruntergeladen und dann in **einem** Transfer zur Web-VM übertragen. Auf der Edge-VM selbst reicht die normale Online-Installation.

### 4.1 Edge-VM: Online installieren

```bash
sudo apt update
sudo apt install -y fail2ban python3-systemd ufw
```

### 4.2 Edge-VM: Pakete zusätzlich als .deb sammeln (für die Web-VM)

```bash
mkdir -p ~/offline-pkgs
cd ~/offline-pkgs
sudo apt-get install --reinstall --download-only -y fail2ban python3-systemd ufw
sudo cp /var/cache/apt/archives/*.deb ~/offline-pkgs/
ls ~/offline-pkgs/*.deb
```

### 4.3 Vom lokalen Rechner: einmal von Edge-VM abholen

**Linux (lokal):**

```bash
scp -i <pfad-zur-edge-vm>.pem <admin-username-edge>@<edge-public-ip>:~/offline-pkgs/*.deb .
```

**Windows (PowerShell, lokal):**

```powershell
scp -i '<pfad-zur-edge-vm>.pem' <admin-username-edge>@<edge-public-ip>:~/offline-pkgs/*.deb .
```

### 4.4 Vom lokalen Rechner: einmal zur Web-VM weiterreichen

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

### 4.5 Web-VM: alle Pakete gemeinsam installieren

```bash
cd /tmp
sudo dpkg -i *.deb
sudo apt install -f -y
```

---

## 5. SSH-Hardening

### 5.1 Konfiguration anpassen


Auf **beiden VMs**:

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sudo nano /etc/ssh/sshd_config
```

Folgende Werte setzen bzw. sicherstellen (auskommentierte Zeilen aktivieren, vorhandene Werte anpassen):

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowUsers <admin-username>
```

> **Hinweis zu `AllowUsers`:** Schränkt SSH-Logins auf den angegebenen Benutzer ein. Optional, aber empfohlen, da so auch bei einem versehentlich angelegten Zusatzkonto kein SSH-Zugriff möglich ist.

### 5.2 Konfiguration testen und Dienst neu laden

```bash
sudo sshd -t
```

Meldet der Test keinen Fehler, den Dienst neu laden:

```bash
sudo systemctl reload ssh
```

> **Wichtig:** Vor dem Schließen der aktuellen SSH-Sitzung in einer **zweiten, separaten** Sitzung verifizieren, dass der Login weiterhin funktioniert (§3.1 bzw. §3.2). So wird ein Aussperren durch einen Konfigurationsfehler vermieden.

### 5.3 Verifikation

```bash
sudo sshd -T | grep -Ei "permitrootlogin|passwordauthentication|pubkeyauthentication|challengeresponseauthentication|kbdinteractiveauthentication|x11forwarding|allowusers"
```

Erwartete Ausgabe (Auszug):

```
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
x11forwarding no
allowusers <admin-user>
```

---


## 6. fail2ban

### 6.1 Konfiguration

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

**Werte:**

| Parameter | Wert | Warum |
|---|---|---|
| `maxretry` | `5` | Toleriert Tippfehler, blockt aber automatisierte Brute-Force-Versuche schnell |
| `findtime` | `10m` | Zeitfenster, in dem die 5 Versuche gezählt werden |
| `bantime` | `1h` | Moderate Sperrzeit; bei Bedarf auf `bantime = -1` (permanent) erhöhen |

## 6.2 Dienst aktivieren

**Auf beiden VMs:**

```bash
sudo systemctl enable --now fail2ban
```

## 6.3 Verifikation

**Auf beiden VMs:**
```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```
Erwartetes Ergebnis:
```
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

## 7. UFW (host-basierte Firewall)

> **Warnung:** UFW wird **über eine bestehende SSH-Sitzung** konfiguriert. Die SSH-Regel muss **vor** dem Aktivieren von UFW gesetzt werden, sonst sperrt man sich selbst aus.

### 7.1 Regeln – Edge-VM

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow from <admin-ip> to any port 22 proto tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

### 7.2 Regeln – Web-VM

Für die UFW-Regeln der Web-VM wird die private IP der Edge-VM benötigt:

```bash
az vm list-ip-addresses \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-edge-01
```

Der Wert unter `privateIpAddresses` ist `<edge-private-ip>` in den folgenden Abschnitten.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow from <edge-private-ip> to any port 22 proto tcp
sudo ufw allow from <edge-private-ip> to any port 80 proto tcp
sudo ufw allow from <edge-private-ip> to any port 443 proto tcp
```

### 7.3 Aktivieren

Auf **beiden VMs**, jeweils erst nachdem die SSH-Regel gesetzt ist:

```bash
sudo ufw enable
```

Sicherheitsabfrage mit `y` bestätigen.

### 7.4 Verifikation

```bash
sudo ufw status verbose
```

Erwartetes Ergebnis Edge-VM (Auszug):

```
Status: active
To                         Action      From
22/tcp                     ALLOW       <admin-ip>
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere
```

Erwartetes Ergebnis Web-VM (Auszug):

```
Status: active
To                         Action      From
22/tcp                     ALLOW       <edge-private-ip>
80/tcp                     ALLOW       <edge-private-ip>
443/tcp                    ALLOW       <edge-private-ip>
```

---

## 7.5 Edge-VM — Lockout durch geänderte Admin-IP

Ändert sich die öffentliche IP des Admin-Rechners (z. B. durch dynamische IP-Vergabe, Netzwerkwechsel, VPN), greift die UFW-Regel auf der Edge-VM nicht mehr, da dort noch die alte IP hinterlegt ist. Da UFW den SSH-Zugriff blockiert, ist eine Korrektur per normalem SSH nicht mehr möglich — die Regel muss über Azure Run-Command (unabhängig von Netzwerk/UFW) korrigiert werden.

```bash
az vm run-command invoke \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-edge-01 \
  --command-id RunShellScript \
  --scripts "ufw delete allow from <alte-admin-ip> to any port 22 proto tcp; ufw allow from <neue-admin-ip> to any port 22 proto tcp"
```

Falls das nicht greift, ersatzweise UFW komplett deaktivieren:

```bash
az vm run-command invoke \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-edge-01 \
  --command-id RunShellScript \
  --scripts "ufw disable"
```

---

## 7.6 Web-VM — Lockout durch Fehlkonfiguration

Die Web-VM-Regel referenziert `<edge-private-ip>` — eine statische private IP, die sich nicht routinemäßig ändert. Ein Lockout hier entsteht typischerweise durch Fehlkonfiguration (falsche IP, gelöschte Regel, `ufw enable` ohne vorherige SSH-Regel).

```bash
az vm run-command invoke \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-web-01 \
  --command-id RunShellScript \
  --scripts "ufw allow from <edge-private-ip> to any port 22 proto tcp"
```

Falls das nicht greift, ersatzweise UFW komplett deaktivieren:

```bash
az vm run-command invoke \
  -g rg-<project>-<environment>-<region> \
  -n vm-<project>-web-01 \
  --command-id RunShellScript \
  --scripts "ufw disable"
```

---

## 7.7 Danach auf OS-Ebene (per SSH, sobald Zugriff wieder funktioniert)

Gilt für beide VMs:

```bash
sudo ufw status numbered
```

Regeln korrigieren:

```bash
sudo ufw allow from <korrekte-ip> to any port 22 proto tcp
sudo ufw delete <zeilennummer-alte-regel>
```

Erst danach wieder aktivieren:

```bash
sudo ufw enable
```

Verifizieren:

```bash
sudo ufw status verbose
```


---

## 8. Gesamtverifikation (Skript)

Das folgende Skript fasst die die Prüfungen für die notwendigen Konfigurationen zusammen und meldet je Prüfpunkt `OK` oder `FEHLER`. Auf der jeweiligen VM ausführen (Edge-VM und Web-VM separat, mit angepasster `EXPECTED_SSH_SOURCE`):

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
