# DMZ & Private Workload Architecture

Diese Anleitung beschreibt den Aufbau einer einfachen Azure-Architektur mit einer öffentlich erreichbaren DMZ und einem privaten Workload-Subnetz. Der Lernpfad ist bewusst schrittweise aufgebaut und führt von der Netzwerkplanung über die Bereitstellung von virtuellen Maschinen bis hin zu Sicherheits- und Wartungsaspekten.

Ziel ist es, typische Azure-Konzepte nachvollziehbar zu erklären und in einer kleinen, aber realistischen Infrastruktur anzuwenden. Der Schwerpunkt liegt auf Netzwerksegmentierung, Zugriffsschutz, sicherer Konfiguration und nachvollziehbarer Dokumentation.

## Architektur

```text
Internet
    │
    ▼
[Public IP]
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
- Absicherung von SSH- und Web-Zugriffen
- Verwendung von Firewall- und Hardening-Maßnahmen auf Betriebssystemebene
- Temporärer Internetzugang für private Workloads über NAT Gateway und Function App
- Dokumentation einer reproduzierbaren Infrastruktur


## Kapitelübersicht

| Kapitel | Inhalt | Fokus |
| --- | --- | --- |
| [01_vnet_and_nsg.md](01_vnet_and_nsg.md) | Virtual Network, Subnetze und NSGs | Netzwerkgrundlagen und Zugriffskontrolle |
| [02_compute_deployment.md](02_compute_deployment.md) | Deployment von Edge-VM und Web-VM | Bereitstellung von Rechenressourcen |
| [03_os_hardening.md](03_os_hardening.md) | SSH-Hardening, fail2ban und UFW | Betriebssystem-Sicherheit |
| [04_function_app_managed_identity_nat_gateway.md](04_function_app_managed_identity_nat_gateway.md) | Temporärer Internetzugang über Function App, Managed Identity und NAT Gateway | Wartungszugang und Least-Privilege-Konzept |



## Architekturprinzipien

- Private Workloads erhalten keine öffentliche IP-Adresse.
- Externer Datenverkehr wird ausschließlich über die DMZ verarbeitet.
- Zugriffskontrolle erfolgt primär über NSGs und zusätzliche Host-Firewalls.
- Komponenten werden nach dem Prinzip der minimalen Rechte konfiguriert.
- Infrastruktur und Konfiguration werden vollständig dokumentiert und nachvollziehbar gehalten.

## Voraussetzungen

- Microsoft Azure Subscription
- Azure CLI (optional)
- Azure Portal
- Grundkenntnisse in Linux und Netzwerktechnik

## Erwartetes Ergebnis

Am Ende des Lernpfads entsteht eine kleine, aber gut strukturierte Azure-Testumgebung, die die wichtigsten Sicherheits- und Architekturprinzipien einer DMZ- und Private-Workload-Lösung demonstriert

## Hinweise

Dieses Projekt dient ausschließlich Lern- und Demonstrationszwecken. Es erhebt keinen Anspruch auf eine produktionsreife Enterprise-Architektur, orientiert sich jedoch an bewährten Architektur- und Sicherheitsprinzipien für Microsoft Azure.
