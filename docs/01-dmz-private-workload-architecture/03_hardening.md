# 03 – Hardening: SSH, fail2ban, UFW

> **Voraussetzung:** `01_vnet_and_nsg.md` und `02_compute_edge_web_vm.md` sind vollständig umgesetzt (VNet, Subnetze, NSGs, Edge-VM, Web-VM).
>
> **Beispielkonfiguration**
>
> * Subscription: `<subscription>`
> * Region: `<azure-region>`
> * Resource Group: `rg-<project>-<environment>-<region>`
> * Betriebssystem beider VMs: **Debian 12 „Bookworm“** (Befehle in diesem Kapitel sind auf Debian/Ubuntu-Derivate mit `apt` und `systemd` ausgelegt)

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

## 4. SSH-Hardening

### 4.1 Konfiguration anpassen

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

### 4.2 Konfiguration testen und Dienst neu laden

```bash
sudo sshd -t
```

Meldet der Test keinen Fehler, den Dienst neu laden:

```bash
sudo systemctl reload ssh
```

> **Wichtig:** Vor dem Schließen der aktuellen SSH-Sitzung in einer **zweiten, separaten** Sitzung verifizieren, dass der Login weiterhin funktioniert (§3.1 bzw. §3.2). So wird ein Aussperren durch einen Konfigurationsfehler vermieden.

### 4.3 Verifikation

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

Verstehe das Missverständnis: Du wolltest keine "Variante A vs. B" für zwei verschiedene Installationswege, sondern innerhalb der einen (Offline-)Installation bei jedem Kopierschritt einfach die Befehle für Linux **und** Windows nebeneinander. Hier die korrigierte Fassung ohne die künstliche A/B-Aufteilung:

---

## 5. fail2ban

### 5.1 Installation

**Hinweis:** Die Web-VM hat keine öffentliche IP und ohne NAT Gateway keinen ausgehenden Internetzugriff. Installation daher offline über die Edge-VM als Zwischenstation.

**Schritt 1 — Paket auf der Edge-VM herunterladen** (dort per SSH eingeloggt):
```bash
mkdir -p ~/fail2ban-deb
cd ~/fail2ban-deb
apt-get install --reinstall --download-only -y fail2ban
cp /var/cache/apt/archives/*.deb ~/fail2ban-deb/
```
Falls das Paket bereits installiert ist und keine .deb erzeugt wird, alternativ:
```bash
apt-get download fail2ban
```

**Schritt 2 — Datei von der Edge-VM zum lokalen Rechner holen** (nur Edge-Key nötig):

Linux:
```bash
scp -i <pfad-zur-edge-vm>.pem <admin-username-edge>@<edge-public-ip>:~/fail2ban-deb/fail2ban*.deb .
```

Windows (PowerShell):
```powershell
scp -i '<pfad-zur-edge-vm>.pem' <admin-username-edge>@<edge-public-ip>:~/fail2ban-deb/fail2ban*.deb .
```

**Schritt 3 — Datei vom lokalen Rechner über die Edge-VM zur Web-VM weiterreichen** (nur Web-Key nötig, Edge-Key dient nur als Proxy):

Linux:
```bash
scp -i <pfad-zur-web-vm>.pem \
  -o "ProxyCommand=ssh -i <pfad-zur-edge-vm>.pem -W %h:%p <admin-username-edge>@<edge-public-ip>" \
  fail2ban*.deb <admin-username-web>@<web-private-ip>:/tmp/
```

Windows (PowerShell):
```powershell
scp -i '<pfad-zur-web-vm>.pem' -o "ProxyCommand=ssh -i <pfad-zur-edge-vm>.pem -W %h:%p <admin-username-edge>@<edge-public-ip>" .\fail2ban*.deb <admin-username-web>@<web-private-ip>:/tmp/
```

So bleibt der Web-Key ausschließlich auf dem lokalen Rechner.

**Schritt 4 — Installation auf der Web-VM:**
```bash
cd /tmp
sudo dpkg -i fail2ban*.deb
sudo apt install -f -y
```


## 5.2 Konfiguration

Auf beiden VMs:

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

## 5.3 Dienst aktivieren

**Auf beiden VMs:**
```bash
sudo systemctl enable --now fail2ban
```

## 5.4 Verifikation

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
