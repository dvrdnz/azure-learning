# 01 – Virtual Network und Network Security Groups (NSG)

> **Beispielkonfiguration**
>
> * Subscription: `<subscription>`
> * Region: `<azure-region>`
> * Resource Group: `rg-<project>-<environment>-<region>`

## 1. Zielbild und Netzwerktopologie

Diese Anleitung beschreibt den Aufbau eines einfachen Azure-Netzwerks mit zwei Subnetzen:

* **DMZ-Subnetz** für öffentlich erreichbare oder vorgelagerte Komponenten
* **Web-Subnetz** für interne Web- oder Applikationskomponenten

Die Absicherung erfolgt über **Network Security Groups (NSGs)** auf Subnetzebene.

| Ressource       | Namenskonvention / Beispiel           |
| --------------- | ------------------------------------- |
| Subscription    | `<subscription>`                      |
| Resource Group  | `rg-<project>-<environment>-<region>` |
| Virtual Network | `vnet-<project>`                      |
| Adressraum      | `10.100.0.0/16`                       |
| Subnetz DMZ     | `snet-dmz` – `10.100.1.0/24`          |
| Subnetz Web     | `snet-web` – `10.100.2.0/24`          |
| NSG DMZ         | `nsg-<project>-dmz`                   |
| NSG Web         | `nsg-<project>-web`                   |

---

## 2. Erstellung im Azure Portal

Die Netzwerkinfrastruktur wird über den Azure-Portal-Assistenten **Create virtual network** erstellt.

### 2.1 Basics

* **Subscription** auswählen.
* **Resource Group** auswählen oder neu erstellen: `rg-<project>-<environment>-<region>`.
* **Virtual Network** anlegen: `vnet-<project>`.
* **Region** auswählen.

### 2.2 Security

* **Azure Bastion:** Disabled
* **Azure Firewall:** Disabled
* **Azure DDoS Network Protection:** Disabled

### 2.3 IP Addresses

* Adressraum: `10.100.0.0/16`

### 2.4 Subnetz `snet-dmz`

* Address Prefix: `10.100.1.0/24`
* **Private Subnet:** Enabled
* Network Security Group: **New** → `nsg-<project>-dmz`

**Hinweis:** Durch „Private Subnet“ werden in diesem Subnetz standardmäßig keine öffentlichen IP-Adressen auf Netzwerkschnittstellen vergeben. Der Zugriff erfolgt über private Netzwerke oder vorgeschaltete Komponenten.

### 2.5 Subnetz `snet-web`

* Address Prefix: `10.100.2.0/24`
* **Private Subnet:** Enabled
* Network Security Group: **New** → `nsg-<project>-web`

### 2.6 Tags

Optional können projektspezifische Tags ergänzt werden.

Nach der Bereitstellung werden die NSGs automatisch mit den jeweiligen Subnetzen verknüpft.

---

## 3. Öffentliche Administrator-IP ermitteln

Für die SSH-Freigabe wird die öffentliche IPv4-Adresse des Verwaltungszugangs benötigt. 

### Vorgehen

1. Vor dem Anlegen der SSH-Regel die öffentliche IPv4-Adresse ermitteln, zum Beispiel über:

   * `https://ifconfig.me`
   * `https://api.ipify.org`

2. Die Adresse im CIDR-Format notieren:

   ```text
   <admin-ip>/32
   ```

3. Diese Adresse ausschließlich für administrative Zugriffe verwenden.

> **Hinweis:** Die Regel sollte nur für Verwaltungszugriffe genutzt werden und nach Möglichkeit durch Azure Bastion oder einen VPN-Zugang ersetzt werden.

---

## 4. Zielkonfiguration der NSG-Regeln

Die folgenden Regeln bilden die gewünschte Zielkonfiguration.

Azure legt zusätzlich automatisch Standardregeln an. Diese müssen nicht manuell erstellt werden.

### 4.1 NSG DMZ (`nsg-<project>-dmz`)

| Name            | Priorität | Richtung | Quelle          | Ziel | Port | Protokoll | Aktion |
| --------------- | --------: | -------- | --------------- | ---- | ---: | --------- | ------ |
| Allow-HTTP      |       100 | Inbound  | Internet        | Any  |   80 | TCP       | Allow  |
| Allow-HTTPS     |       110 | Inbound  | Internet        | Any  |  443 | TCP       | Allow  |
| Allow-SSH-Admin |       120 | Inbound  | `<admin-ip>/32` | Any  |   22 | TCP       | Allow  |

### 4.2 NSG Web (`nsg-<project>-web`)

| Name                 | Priorität | Richtung | Quelle          | Ziel | Port | Protokoll | Aktion |
| -------------------- | --------: | -------- | --------------- | ---- | ---: | --------- | ------ |
| Allow-HTTP-from-DMZ  |       100 | Inbound  | `10.100.1.0/24` | Any  |   80 | TCP       | Allow  |
| Allow-HTTPS-from-DMZ |       110 | Inbound  | `10.100.1.0/24` | Any  |  443 | TCP       | Allow  |

> **Hinweis:** Die Zielspalte verwendet `Any`, da die NSG auf Subnetzebene zugeordnet wird. Soll der Zugriff auf einzelne Netzwerkschnittstellen weiter eingeschränkt werden, kann dies zusätzlich über NSGs auf NIC-Ebene erfolgen.

---

## 5. Azure-Standardregeln

Beim Erstellen einer NSG legt Azure automatisch Standardregeln an. Diese Regeln bleiben zusätzlich zu den eigenen Regeln aktiv.

### Inbound

| Regel                         | Priorität |
| ----------------------------- | --------: |
| AllowVnetInBound              |     65000 |
| AllowAzureLoadBalancerInBound |     65001 |
| DenyAllInbound                |     65500 |

### Outbound

| Regel                 | Priorität |
| --------------------- | --------: |
| AllowVnetOutBound     |     65000 |
| AllowInternetOutBound |     65001 |
| DenyAllOutBound       |     65500 |

NSGs sind **stateful**. Antwortpakete auf bereits erlaubte Verbindungen werden automatisch zugelassen.

### Hinweis zu Outbound-Regeln

In dieser Zielkonfiguration werden keine eigenen Outbound-Regeln angelegt, da die Azure-Standardregeln bereits das übliche Verhalten abdecken.

---

## 6. Regeln im Azure Portal anlegen

Für jede NSG:

1. **Network Security Group** öffnen
2. **Inbound security rules** auswählen
3. **Add** wählen
4. Regel gemäß der Tabelle aus Abschnitt 4 anlegen

Empfohlene Reihenfolge:

1. `nsg-<project>-dmz`
2. `nsg-<project>-web`

Erstellen Sie zunächst alle Inbound-Regeln für die DMZ und anschließend die Inbound-Regeln für das Web-Subnetz.

---

## 7. Alternative: Azure CLI

### 7.1 NSG DMZ

```bash
az network nsg rule create \
  -g rg-<project>-<environment>-<region> \
  --nsg-name nsg-<project>-dmz \
  -n Allow-HTTP \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes Internet \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 80

az network nsg rule create \
  -g rg-<project>-<environment>-<region> \
  --nsg-name nsg-<project>-dmz \
  -n Allow-HTTPS \
  --priority 110 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes Internet \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 443

az network nsg rule create \
  -g rg-<project>-<environment>-<region> \
  --nsg-name nsg-<project>-dmz \
  -n Allow-SSH-Admin \
  --priority 120 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes <admin-ip>/32 \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 22
```

### 7.2 NSG Web

```bash
az network nsg rule create \
  -g rg-<project>-<environment>-<region> \
  --nsg-name nsg-<project>-web \
  -n Allow-HTTP-from-DMZ \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes 10.100.1.0/24 \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 80

az network nsg rule create \
  -g rg-<project>-<environment>-<region> \
  --nsg-name nsg-<project>-web \
  -n Allow-HTTPS-from-DMZ \
  --priority 110 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes 10.100.1.0/24 \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 443
```

> **Hinweis:** Eigene Outbound-Regeln werden in dieser Basisvariante nicht angelegt, da Azure die Standardregeln bereits bereitstellt.

---


