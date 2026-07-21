# Deployments

Dieses Verzeichnis enthält die Implementierungs-Artefakte und automatisierten Skripte für die in `docs/` beschriebenen Lernpfade. 

Die Deployments sind in nummerierte Lernpfade organisiert und jedem Kapitel (z.B. `04_function_app_managed_identity_nat_gateway`) zugeordnet. Sie erhalten damit ein reproduzierbares Setup mit vorgefertigten Skripten, Konfigurationen und Ressourcen-Definitionen.

## Struktur

```
deployments/
├── 01-dmz-private-workload-architecture/
│   ├── 04_function_app_managed_identity_nat_gateway/
│   │   ├── create-resources.sh           # Deployment-Skript
│   │   ├── nat-toggle-role.json          # Custom Role Definition
│   │   ├── README.md                     # Kurzbeschreibung
│   │   └── scripts/function/             # Azure Function Quellcode
│   │
│   └── 05_deploy_function_app_update/
│       ├── create-resources.sh           # Deployment-Skript
│       ├── README.md                     # Kurzbeschreibung
│       └── scripts/function/             # Verbesserte Azure Function
```

## Verwendung

Jedes Deployment-Verzeichnis enthält eine eigene `README.md` mit spezifischen Anweisungen. Diese Datei verweist auf das entsprechende Kapitel in `docs/` und erklärt:

- **Voraussetzungen** – erforderliche Tools, Rollen, Zugriffe
- **Platzhalter** – zu ersetzende Variablen (z.B. `<project>`, `<region>`)
- **Deployment-Schritte** – Reihenfolge der Skript-Ausführungen
- **Verifikation** – Überprüfung der erfolgreichen Bereitstellung

### Beispiel

Für das Deployment von 04 (Function App mit NAT Gateway):

```bash
cd deployments/01-dmz-private-workload-architecture/04_function_app_managed_identity_nat_gateway/
# Anweisungen in README.md folgen
bash create-resources.sh create-pip
```

## Verknüpfung zur Dokumentation

Jedes Deployment korrespondiert mit einem Kapitel in der Dokumentation:

| Deployment | Dokumentation |
| --- | --- |
| `04_function_app_managed_identity_nat_gateway/` | `docs/01-dmz-private-workload-architecture/04_function_app_managed_identity_nat_gateway.md` |
| `05_deploy_function_app_update/` | `docs/01-dmz-private-workload-architecture/05_deploy_function_app_update.md` |

Die Dokumentation erklärt die Konzepte, Architektur und Sicherheitsaspekte. Die Deployments stellen fertige Skripte und Konfigurationen bereit.
