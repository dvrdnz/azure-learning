# DMZ & Private Workload Architecture

Dieses Projekt dokumentiert den Aufbau einer Azure-Infrastruktur mit einer öffentlich erreichbaren DMZ und einem privaten Workload-Subnetz.

Ziel ist es, eine typische mehrschichtige Infrastruktur (Multi-Tier Architecture) mit Microsoft Azure aufzubauen, zu dokumentieren und deren Komponenten nachvollziehbar zu erklären. Der Schwerpunkt liegt auf Netzwerksegmentierung, Zugriffsschutz und einem kosteneffizienten Betrieb innerhalb eines Azure-Abonnements.

## Architektur

```text
Internet
    │
    ▼
Public IP
    │
    ▼
┌──────────────────────────────────────┐
│ Virtual Network                      │
│                                      │
│  DMZ Subnet                          │
│  ┌───────────────────────────────┐   │
│  │ Edge VM                       │   │
│  │ • Public IP                   │   │
│  │ • Nginx Reverse Proxy         │   │
│  │ • HTTPS Termination           │   │
│  └───────────────┬───────────────┘   │
│                  │                   │
│                  ▼                   │
│  Private Workload Subnet            │
│  ┌───────────────────────────────┐   │
│  │ Web VM                        │   │
│  │ • Private IP                  │   │
│  │ • Web Application             │   │
│  │ • No Public Access            │   │
│  └───────────────────────────────┘   │
└──────────────────────────────────────┘
```

## Lernziele

- Aufbau eines Azure Virtual Networks
- Segmentierung mittels Subnetzen
- Einsatz von Network Security Groups (NSGs)
- Bereitstellung virtueller Maschinen
- Reverse Proxy mit Nginx
- Trennung zwischen öffentlich erreichbaren und privaten Ressourcen
- Absicherung des Netzwerkverkehrs
- Dokumentation einer reproduzierbaren Infrastruktur

## Dokumentation

| Dokument | Inhalt |
|----------|--------|
| 01-vnet-nsg.md | Virtual Network, Subnetze und Network Security Groups |


## Architekturprinzipien

- Private Workloads erhalten keine öffentliche IP-Adresse.
- Der gesamte externe Datenverkehr wird ausschließlich über die DMZ verarbeitet.
- Zugriffe zwischen den Subnetzen werden ausschließlich über Network Security Groups gesteuert.
- Komponenten werden nach dem Prinzip der minimalen Rechte (Least Privilege) konfiguriert.
- Infrastruktur und Konfiguration werden vollständig dokumentiert.

## Voraussetzungen

- Microsoft Azure Subscription
- Azure CLI (optional)
- Azure Portal
- Grundkenntnisse in Linux und Netzwerktechnik

## Hinweise

Dieses Projekt dient ausschließlich Lern- und Demonstrationszwecken. Es erhebt keinen Anspruch auf eine produktionsreife Enterprise-Architektur, orientiert sich jedoch an bewährten Architektur- und Sicherheitsprinzipien für Microsoft Azure.
