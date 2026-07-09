# 02 – Compute-Deployment: Edge-VM und Web-VM

> **Voraussetzung:** `01_vnet_and_nsg.md` ist vollständig umgesetzt (VNet, Subnetze, NSGs, NSG-Regeln).
>
> **Beispielkonfiguration**
>
> * Subscription: `<subscription>`
> * Region: `<azure-region>`
> * Resource Group: `rg-<project>-<environment>-<region>`

## 1. Voraussetzungsprüfung: Ressourcen aus Kapitel 01

Bevor mit dem Compute-Deployment begonnen wird, ist sicherzustellen, dass **ausschließlich die in Kapitel 01 erstellten Ressourcen verwendet werden** und keine neuen/abweichenden Ressourcen (VNet, Subnetze, NSGs) angelegt werden. Namenskonventionen müssen exakt übereinstimmen.

Im Azure Portal unter **Virtual networks** bzw. **Resource groups** prüfen:

| Ressource aus Kapitel 01 | Erwarteter Name | Prüfung |
| --- | --- | --- |
| Resource Group | `rg-<project>-<environment>-<region>` | vorhanden, wird in Kapitel 02 **wiederverwendet** (nicht neu anlegen) |
| Virtual Network | `vnet-<project>` | vorhanden, Adressraum `10.100.0.0/16` |
| Subnetz DMZ | `snet-dmz` | vorhanden, `10.100.1.0/24`, Private Subnet Enabled |
| Subnetz Web | `snet-web` | vorhanden, `10.100.2.0/24`, Private Subnet Enabled |
| NSG DMZ | `nsg-<project>-dmz` | vorhanden, mit `snet-dmz` verknüpft, Regeln aus Kapitel 01 §4.1 aktiv |
| NSG Web | `nsg-<project>-web` | vorhanden, mit `snet-web` verknüpft, Regeln aus Kapitel 01 §4.2 aktiv |

> **Wichtig:** In den folgenden Schritten wird beim VM-Erstellungsassistenten in Azure Portal für Resource Group, Virtual Network und Subnetz jeweils die **vorhandene Ressource ausgewählt** (Dropdown zeigt bereits existierende Objekte) — es wird an keiner Stelle „Create new“ für Resource Group, VNet oder Subnetz verwendet. Weichen Namen oder Adressräume von der Tabelle oben ab, ist zunächst Kapitel 01 zu korrigieren, bevor mit Kapitel 02 fortgefahren wird.

---

## 2. Zielbild

Aufbauend auf dem Netzwerk aus Kapitel 01 werden zwei virtuelle Maschinen bereitgestellt:

* **Edge-VM** (`vm-<project>-edge-01`) im Subnetz `snet-dmz` — erhält eine öffentliche IP und fungiert später als Reverse-Proxy (Nginx) für eingehenden HTTP/HTTPS-Verkehr.
* **Web-VM** (`vm-<project>-web-01`) im Subnetz `snet-web` — erhält **keine** öffentliche IP und verarbeitet die Anwendungslogik. Sie ist ausschließlich über die Edge-VM erreichbar.

Beide VMs nutzen die Größe `Standard_B2ats_v2` (Burstable, 2 vCPU), um innerhalb typischer Freikontingente bzw. Kostenrahmen zu bleiben.

```
Internet
   |
   |  HTTP/HTTPS (80/443)
   v
[Edge-VM] --- snet-dmz (10.100.1.0/24), öffentliche IP
   |
   |  Private (nur innerhalb vnet-<project>)
   v
[Web-VM]  --- snet-web (10.100.2.0/24), keine öffentliche IP
```

---

## 3. Ressourcenübersicht

| Ressource | Name | Subnetz | Öffentliche IP | Größe |
| --- | --- | --- | --- | --- |
| Public IP | `pip-<project>-edge-01` | – | Standard, statisch | – |
| NIC (Edge) | `nic-<project>-edge-01` (automatisch bei VM-Erstellung) | `snet-dmz` | ja (verknüpft) | – |
| NIC (Web) | `nic-<project>-web-01` (automatisch bei VM-Erstellung) | `snet-web` | nein | – |
| VM (Edge) | `vm-<project>-edge-01` | `snet-dmz` | ja | `Standard_B2ats_v2` |
| VM (Web) | `vm-<project>-web-01` | `snet-web` | nein | `Standard_B2ats_v2` |
| OS-Disk (je VM) | automatisch benannt | – | – |  `Premium_LRS` |

> **Hinweis zu Kosten:** Für die VM-Größe, die statische Public IP und den OS-Disk-Speicher fallen je nach Region und Konto (z. B. Freikontingente, Studierenden-Guthaben) unterschiedliche Kosten an. Die exakten Sätze für die gewählte Region sind im Azure-Preisrechner zu prüfen.

---

## 4. Edge-VM im Azure Portal erstellen

Die VM wird über den Azure-Portal-Assistenten **Create a virtual machine** angelegt.

### 4.1 Basics

* **Subscription:** identisch zu Kapitel 01 auswählen.
* **Resource Group:** **vorhandene** `rg-<project>-<environment>-<region>` aus der Dropdown-Liste auswählen (nicht neu anlegen).
* **Virtual machine name:** `vm-<project>-edge-01`
* **Region:** `<azure-region>` (muss identisch zur Region des VNet aus Kapitel 01 sein)
* **Availability options:** No infrastructure redundancy required
* **Security type:** Standard
* **Image:** aktuelle LTS-/Stable-Distribution nach Wahl (z. B. Ubuntu Server 24.04 LTS oder Debian 12 „Bookworm“)
* **VM architecture:** x64
* **Size:** `Standard_B2ats_v2` (über „See all sizes“ auswählen, falls nicht vorgeschlagen)
* **Run with Azure Spot discount:** nicht aktivieren 
* **Authentication type:** SSH public key
* **Username:** `<admin-username>`
* **SSH key format:** RSA (Standard) oder Ed25519, je nach Präferenz
* **SSH public key source:** Generate new key pair / Use existing key stored in Azure / Use existing public key — je nach Vorgehen auswählen
* **Key pair name:** Portal-Vorschlag (`<vm-name>_key`) übernehmen oder projektspezifisch anpassen
* **Public inbound ports:** None, falls die Option angeboten wird.

  > **Hinweis:** Das Feld kann auch ganz verschwinden, sobald im Networking-Tab das vorhandene VNet/Subnet ausgewählt wird (das Portal erkennt dann, dass es kein Ziel für eine Regel gibt) — das ist erwartetes Verhalten. Ist es stattdessen sichtbar und lässt sich nicht auf „None" setzen, kann es ebenfalls unverändert bleiben.
### 4.2 Disks

* **OS disk type:** Premium SSD (LRS)
* **Delete OS disk with VM:** Enabled
* **Use managed disks:** Yes
* **Ephemeral OS disk:** None
* Keine zusätzlichen Datenträger erforderlich.

### 4.3 Networking

* **Virtual network:** **vorhandenes** `vnet-<project>` aus Kapitel 01 auswählen (nicht neu anlegen).
* **Subnet:** **vorhandenes** `snet-dmz` auswählen (nicht neu anlegen, keine abweichende Adressierung).
* **Public IP:** New → `pip-<project>-edge-01`

  * **SKU:** Standard
  * **Assignment:** Static
* **NIC network security group:** **None**

  > Wichtig: An dieser Stelle **keine** NIC-eigene NSG anlegen. Die Absicherung erfolgt bereits über die Subnetz-NSG `nsg-<project>-dmz` aus Kapitel 01, die mit dem Subnetz verknüpft ist. Eine zusätzliche NIC-NSG würde die Regeln redundant verwalten und das Regelwerk unübersichtlich machen.
* **Delete public IP and NIC when VM is deleted:** Enabled

### 4.4 Management

* **Boot diagnostics:** Disables

### 4.5 Monitoring, Advanced, Tags

* Standardwerte

### 4.6 Review + create

* Konfiguration prüfen — insbesondere Resource Group, Virtual Network und Subnet gegen die Tabelle in Abschnitt 1 abgleichen — und **Create** wählen.
* Beim Klick auf Create generiert Azure automatisch ein Schlüsselpaar und öffnet zwingend einen Dialog mit der Schaltfläche **Download private key and create resource**. Erst dieser Klick startet das eigentliche Deployment – die `.pem-` Datei muss in diesem Moment lokal gespeichert werden, da sie danach nicht erneut bereitgestellt wird.
  
---

## 5. Web-VM im Azure Portal erstellen

Analog zur Edge-VM, jedoch **ohne** öffentliche IP.

### 5.1 Basics

* **Subscription:** identisch zu Kapitel 01 und zur Edge-VM.
* **Resource Group:** **vorhandene** `rg-<project>-<environment>-<region>` auswählen (dieselbe wie bei der Edge-VM).
* **Virtual machine name:** `vm-<project>-web-01`
* **Region:** `<azure-region>` (identisch zur Edge-VM und zum VNet aus Kapitel 01)
* **Availability options:** No infrastructure redundancy required
* **Security type:** Standard
* **Image:** identisch zur Edge-VM (gleiche Distribution und Version)
* **VM architecture:** x64
* **Size:** `Standard_B2ats_v2`
* **Run with Azure Spot discount:** nicht aktivieren
* **Authentication type:** SSH public key
* **Username:** `<admin-username>` (kann identisch zur Edge-VM sein oder abweichen)
* **SSH key format:** RSA (Standard) oder Ed25519, konsistent zur Edge-VM
* **SSH public key source:** Generate new key pair / Use existing key stored in Azure / Use existing public key — je nach Vorgehen; eigener Key empfohlen, unabhängig vom Edge-VM-Key
* **Key pair name:** Portal-Vorschlag (`<vm-name>_key`) übernehmen oder projektspezifisch anpassen
* **Public inbound ports:** None, falls angeboten — siehe Hinweis zur Edge-VM in Abschnitt 4.1.

### 5.2 Disks

* **OS disk type:** analog zur Edge-VM (siehe Abschnitt 4.2) —  Premium SSD (LRS).
* **Delete OS disk with VM:** Enabled
* **Use managed disks:** Yes
* **Ephemeral OS disk:** None

### 5.3 Networking

* **Virtual network:** **vorhandenes** `vnet-<project>` aus Kapitel 01 auswählen (dasselbe VNet wie bei der Edge-VM).
* **Subnet:** **vorhandenes** `snet-web` auswählen (nicht neu anlegen, keine abweichende Adressierung).
* **Public IP:** **None**

  > Die Web-VM darf keine öffentliche IP erhalten. Der Zugriff erfolgt ausschließlich aus dem privaten Netzwerk heraus.
* **NIC network security group:** **None**

  > Auch hier gilt: keine NIC-eigene NSG. Die Subnetz-NSG `nsg-<project>-web` aus Kapitel 01, die bereits mit `snet-web` verknüpft ist, übernimmt die Filterung.
* **Delete NIC when VM is deleted:** je nach Wunsch (Standardverhalten kann übernommen werden, keine Public IP vorhanden)

### 5.4 Management, Monitoring, Advanced, Tags

* **Boot diagnostics:** Disables

### 5.5 Review + create

* Konfiguration prüfen — insbesondere dass Resource Group und Virtual Network mit denen der Edge-VM übereinstimmen — und **Create** wählen.
* Auch hier fordert Azure beim Klick auf **Create** zunächst den Download des generierten privaten Schlüssels. Die heruntergeladene `.pem`-Datei für die Web-VM ebenfalls sichern.
---

## 6. Kontrolle nach der Bereitstellung

Nach Abschluss beider Deployments sollte geprüft werden, dass ausschließlich die Ressourcen aus Kapitel 01 verwendet und nicht versehentlich neue Netzwerkobjekte erzeugt wurden.

### 6.1 Prüfung im Azure Portal

| Prüfpunkt | Erwartetes Ergebnis |
| --- | --- |
| Edge-VM → Networking-Blade | NIC in `snet-dmz` (aus Kapitel 01), Public IP verknüpft, keine NIC-NSG |
| Web-VM → Networking-Blade | NIC in `snet-web` (aus Kapitel 01), **keine** Public IP, keine NIC-NSG |
| Subnetz `snet-dmz` | unverändert, weiterhin verknüpft mit `nsg-<project>-dmz` aus Kapitel 01 |
| Subnetz `snet-web` | unverändert, weiterhin verknüpft mit `nsg-<project>-web` aus Kapitel 01 |
| Virtual Network Übersicht | zeigt weiterhin genau **ein** VNet `vnet-<project>` mit zwei Subnetzen — kein zweites/abweichendes VNet wurde angelegt |
| Resource Group Übersicht | enthält nun zusätzlich zu den Ressourcen aus Kapitel 01 die neuen Objekte aus Kapitel 02 (Public IP, 2× NIC, 2× VM, 2× OS-Disk) — keine zweite Resource Group |

### 6.2 Verifikation via Azure CLI

Das folgende Skript prüft die Konfiguration automatisiert und meldet je Prüfpunkt `OK` oder `FEHLER`. Variablen im Header einmalig anpassen.

```bash
#!/usr/bin/env bash
set -euo pipefail

RG="rg-<project>-<environment>-<region>"
VNET="vnet-<project>"
VM_EDGE="vm-<project>-edge-01"
VM_WEB="vm-<project>-web-01"
PIP_EDGE="pip-<project>-edge-01"
NSG_DMZ="nsg-<project>-dmz"
NSG_WEB="nsg-<project>-web"

FAILED=0
pass() { echo "OK      - $1"; }
fail() { echo "FEHLER  - $1"; FAILED=1; }

# 1. snet-dmz -> korrekte NSG
NSG_ACTUAL=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n snet-dmz --query "networkSecurityGroup.id" -o tsv)
[[ "$NSG_ACTUAL" == *"$NSG_DMZ" ]] && pass "snet-dmz verknüpft mit $NSG_DMZ" || fail "snet-dmz NSG ist '$NSG_ACTUAL', erwartet '$NSG_DMZ'"

# 2. snet-web -> korrekte NSG
NSG_ACTUAL=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n snet-web --query "networkSecurityGroup.id" -o tsv)
[[ "$NSG_ACTUAL" == *"$NSG_WEB" ]] && pass "snet-web verknüpft mit $NSG_WEB" || fail "snet-web NSG ist '$NSG_ACTUAL', erwartet '$NSG_WEB'"

# 3. Edge-VM NIC: Subnetz, Public IP (Name nach Konvention), keine NIC-NSG
EDGE_NIC_ID=$(az vm show -g "$RG" -n "$VM_EDGE" --query "networkProfile.networkInterfaces[0].id" -o tsv)
EDGE_SUBNET=$(az network nic show --ids "$EDGE_NIC_ID" --query "ipConfigurations[0].subnet.id" -o tsv)
EDGE_PIP=$(az network nic show --ids "$EDGE_NIC_ID" --query "ipConfigurations[0].publicIPAddress.id" -o tsv)
EDGE_NICNSG=$(az network nic show --ids "$EDGE_NIC_ID" --query "networkSecurityGroup.id" -o tsv)

[[ "$EDGE_SUBNET" == *"/snet-dmz" ]] && pass "Edge-VM NIC im Subnetz snet-dmz" || fail "Edge-VM NIC Subnetz ist '$EDGE_SUBNET'"
[[ "$EDGE_PIP" == *"$PIP_EDGE" ]] && pass "Public IP entspricht Konvention $PIP_EDGE" || fail "Public IP weicht von Konvention ab: '$EDGE_PIP', erwartet Name '$PIP_EDGE'"
[[ -z "$EDGE_NICNSG" || "$EDGE_NICNSG" == "None" ]] && pass "Edge-VM NIC hat KEINE eigene NSG" || fail "Edge-VM NIC hat NIC-NSG: '$EDGE_NICNSG'"

# 4. Web-VM NIC: Subnetz, KEINE Public IP, keine NIC-NSG
WEB_NIC_ID=$(az vm show -g "$RG" -n "$VM_WEB" --query "networkProfile.networkInterfaces[0].id" -o tsv)
WEB_SUBNET=$(az network nic show --ids "$WEB_NIC_ID" --query "ipConfigurations[0].subnet.id" -o tsv)
WEB_PIP=$(az network nic show --ids "$WEB_NIC_ID" --query "ipConfigurations[0].publicIPAddress.id" -o tsv)
WEB_NICNSG=$(az network nic show --ids "$WEB_NIC_ID" --query "networkSecurityGroup.id" -o tsv)

[[ "$WEB_SUBNET" == *"/snet-web" ]] && pass "Web-VM NIC im Subnetz snet-web" || fail "Web-VM NIC Subnetz ist '$WEB_SUBNET'"
[[ -z "$WEB_PIP" || "$WEB_PIP" == "None" ]] && pass "Web-VM NIC hat KEINE Public IP" || fail "Web-VM NIC hat Public IP: '$WEB_PIP'"
[[ -z "$WEB_NICNSG" || "$WEB_NICNSG" == "None" ]] && pass "Web-VM NIC hat KEINE eigene NSG" || fail "Web-VM NIC hat NIC-NSG: '$WEB_NICNSG'"

echo
[[ "$FAILED" -eq 0 ]] && echo "=== ALLE PRÜFUNGEN BESTANDEN ===" || echo "=== ES GAB FEHLER, SIEHE OBEN ==="
```

Beispielausgabe bei korrekter Konfiguration:

```
OK      - snet-dmz verknüpft mit nsg-<project>-dmz
OK      - snet-web verknüpft mit nsg-<project>-web
OK      - Edge-VM NIC im Subnetz snet-dmz
OK      - Public IP entspricht Konvention <pip-name>
OK      - Edge-VM NIC hat KEINE eigene NSG
OK      - Web-VM NIC im Subnetz snet-web
OK      - Web-VM NIC hat KEINE Public IP
OK      - Web-VM NIC hat KEINE eigene NSG

=== ALLE PRÜFUNGEN BESTANDEN ===
```

**Erwartete Ergebnisse zusammengefasst:**

| Prüfpunkt | Erwartung |
| --- | --- |
| Edge-VM NIC | Subnetz `snet-dmz`, Public IP gesetzt, keine NIC-NSG |
| Web-VM NIC | Subnetz `snet-web`, **keine** Public IP, keine NIC-NSG |

> **Hinweis:** Da beide NICs ohne eigene NSG erstellt wurden, gelten ausschließlich die Subnetz-NSGs aus Kapitel 01. Damit bleibt die Zielkonfiguration konsistent zu `01_vnet_and_nsg.md`.
