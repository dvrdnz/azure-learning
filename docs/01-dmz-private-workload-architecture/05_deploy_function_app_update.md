# 05 – Function-App-Update: Ephemere NAT-Ressourcen, Locking und asynchrone Verarbeitung

> **Voraussetzung:**
>
> * [01 – Virtual Network und Network Security Groups (NSG)](https://github.com/dvrdnz/azure-learning/blob/main/docs/01-dmz-private-workload-architecture/01_vnet_and_nsg.md)
> * [02 – Compute-Deployment: Edge-VM und Web-VM](https://github.com/dvrdnz/azure-learning/blob/main/docs/01-dmz-private-workload-architecture/02_compute_deployment.md)
> * [03 – OS-Hardening: SSH, fail2ban, UFW](https://github.com/dvrdnz/azure-learning/blob/main/docs/01-dmz-private-workload-architecture/03_os_hardening.md)
>
> * [04 – Temporärer Internetzugang für die Web-VM: Function App, Managed Identity und NAT Gateway](https://github.com/dvrdnz/azure-learning/blob/main/docs/01-dmz-private-workload-architecture/04_function_app_managed_identity_nat_gateway.md) — vollständig umgesetzt und verifiziert (Abschnitt 10.3: `natGateway.id` ist leer)
>
> **Status:** Kapitel 04 legt Managed Identity, RBAC-Grundmodell und die Trennung von Authentifizierung und Autorisierung an einem bewusst vereinfachten Ressourcenmodell dar — mit einem dauerhaft bestehenden NAT Gateway und ohne Schutz gegen parallele Aufrufe oder Teilfehler. Dieses Kapitel schließt genau diese Lücken.
>
> **Beispielkonfiguration**
>
> * Subscription: `<subscription>`
> * Region: `<azure-region>`
> * Resource Group: `rg-<project>-<environment>-<region>`

## 1. Lernziele


* das Ressourcenmodell aus Kapitel 04 von dauerhaft bestehenden auf ephemere NAT-Ressourcen umstellen und die dafür nötige RBAC-Erweiterung nachvollziehen
* das Zielbild mit **ephemeren NAT-Ressourcen** und **öffentlicher IP nur während des Wartungsfensters** verstehen
* das Zusammenspiel von **Function App**, **Managed Identity** und **RBAC** im Update-Kontext prüfen
* das Prinzip eines **Blob-Lease-Locks** gegen parallele Toggle-Aufrufe nachvollziehen
* die **asynchrone Verarbeitung** über Queue-Trigger und Status-Blob einordnen
* den Umgang mit **Rollback**, **CleanupPending** und idempotenter Wiederholung strukturieren
* den Übergang von Kapitel 04 auf dieses Kapitel als **gezielte Erweiterung** des Ressourcenmodells verifizieren
* eine synchrone HTTP-Function in einen asynchronen Ablauf aus Annahme-, Worker- und Status-Function auftrennen, um das 230-Sekunden-Timeout des Azure Load Balancers zu vermeiden
* eine Blob-Lease als Lock gegen parallele Toggle-Aufrufe einsetzen und automatisch erneuern
* Rollback- bzw. Cleanup-Logik für Teilfehler beim Erzeugen und Löschen von NAT Gateway und Public IP entwerfen
* den bestehenden Wartungsablauf aus Kapitel 04 auf den neuen, statusbasierten Ablauf migrieren, ohne verwaiste Ressourcen zu riskieren


## 2. Voraussetzungen aus Kapitel 04 prüfen
| Ressource               | Erwarteter Zustand                                                                                   | Prüfung                                                                                                                                                                                          |
| ----------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| RBAC-Rolle              | `NAT Gateway Toggle Operator` existiert mit den 6 Actions aus Kapitel 04                             | `az role definition list --name "NAT Gateway Toggle Operator" --output json`                                                                                                                     |
| Managed Identity        | System-assigned, Rolle zugewiesen                                                                    | `az role assignment list --scope /subscriptions/<subscription>/resourceGroups/rg-<project>-<environment>-<region> --query "[?roleDefinitionName=='NAT Gateway Toggle Operator']" --output table` |
| Function App            | `func-<project>-<environment>` läuft, `ToggleWebInternet` aufrufbar                                  | `az functionapp function list --resource-group rg-<project>-<environment>-<region> --name func-<project>-<environment> --query "[].name" --output table`                                         |
| NAT Gateway / Public IP | dauerhaft vorhanden (`nat-<project>`, `pip-<project>-nat`), aktuell **nicht** an `snet-web` gebunden | `az network vnet subnet show --resource-group rg-<project>-<environment>-<region> --vnet-name vnet-<project> --name snet-web --query "natGateway.id" --output tsv` — Ergebnis muss leer sein     |

Ist die letzte Zeile nicht leer, läuft aktuell eine Wartung oder der letzte Toggle-Off ist fehlgeschlagen — vor Beginn dieses Kapitels erst über `04_function_app_managed_identity_nat_gateway.md`, Abschnitt 10.6 auf einen sauberen `Off`-Zustand bringen.

---

## 3. Zielbild
Kapitel 04 implementiert den Toggle über ein dauerhaft bestehendes NAT Gateway: Es wird einmalig angelegt und danach ausschließlich am Subnetz an- bzw. abgekoppelt. Das ist als Einstieg richtig, weil es Managed Identity und RBAC ohne zusätzliche Komplexität einführt — es hat aber zwei Konsequenzen:

* Ein dauerhaft bestehendes NAT Gateway samt Public IP verursacht Kosten unabhängig vom Toggle-Zustand — auch dann, wenn die Web-VM die meiste Zeit isoliert bleiben soll.
* Es gibt kein Schutzmechanismus gegen parallele Toggle-Aufrufe und keinen automatisierten Umgang mit Teilfehlern — beides wird in einem realen Betrieb irgendwann auftreten.

Dieses Kapitel ändert deshalb das Ressourcenmodell: NAT Gateway und Public IP werden bei jedem Toggle neu erzeugt und nach der Wartung vollständig gelöscht, statt nur entkoppelt. Das ist die zentrale Änderung gegenüber Kapitel 04.

Zusätzlich dazu führt der Code in diesem Kapitel einen Blob-Lease-Lock gegen parallele Toggle-Aufrufe sowie Rollback- und Cleanup-Logik bei Teilfehlern ein. Diese beiden Mechanismen sind von der Frage ephemer vs. dauerhaft unabhängig: Sie adressieren das allgemeine Problem nebenläufiger, mehrschrittiger Infrastrukturänderungen. Sie werden hier eingeführt, weil das Erzeugen und Löschen zusätzlicher Ressourcen die Zahl der Schritte im Ablauf erhöht und damit auch die Zahl der Stellen, an denen ein Teilfehler auftreten kann.

Das Zielbild aus Kapitel 04 (`Admin-Rechner → Function App → snet-web → Internet`) bleibt im Kern bestehen, wird aber um die asynchrone Verarbeitung erweitert, die Abschnitt 4.3 begründet:

```text
Admin-Rechner
     |
     | POST /api/ToggleWebInternet?code=<function-key>
     | Body: {"State":"On"} oder {"State":"Off"}
     v
[ToggleWebInternet] --- validiert nur, schreibt Auftrag in Queue
     |                   antwortet sofort mit 202 Accepted + operationId
     v
[toggle-requests Queue] --- Blob-Lease-Lock verhindert parallele Läufe
     |
     v
[ToggleWebInternetWorker] --- Managed Identity (RBAC: NAT Gateway Toggle Operator, erweitert)
     |
     | On:  Public IP + NAT Gateway erzeugen, an snet-web binden
     | Off: von snet-web lösen, NAT Gateway + Public IP löschen
     | bei Teilfehler: Rollback (On) bzw. CleanupPending-Status (Off)
     v
[snet-web] --- NAT Gateway (nur während Wartung vorhanden)
     |
     v
Internet (ausgehend, nur Web-VM, nur TCP/UDP — kein ICMP)

Admin-Rechner
     |
     | GET /api/GetToggleWebInternetStatus?operationId=...&code=<function-key-status>
     v
[GetToggleWebInternetStatus] --- liest Status-Blob, gibt Queued|Running|Succeeded|Failed|CleanupPending zurück
```

Dieses Update ist notwendig, weil:

* Kapitel 04 ist als Lernschritt vollständig und funktionsfähig; Managed Identity, RBAC-Rollenmodell und die Trennung von Authentifizierung und Autorisierung sind dort bereits vollständig abgedeckt und werden hier nicht wiederholt.
* Die Änderungen in diesem Kapitel sind eine Erweiterung des Ressourcenmodells und der Betriebslogik, keine Korrektur an Kapitel 04 — beide Implementierungen sind für sich technisch korrekt.
* Ohne dieses Update bleibt die Umgebung dauerhaft kostenpflichtig (NAT Gateway + Public IP laufen permanent) und ungeschützt gegen parallele Aufrufe.

## 4. Unterschied zu Kapitel 04 im Überblick

### 4.1 Ressourcenmodell

Dies ist die zentrale Änderung in diesem Kapitel.

| Aspekt                                       | Kapitel 04 (vorher)                                                 | Nach diesem Kapitel                                                |
| -------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Lebensdauer NAT Gateway / Public IP          | dauerhaft vorhanden, unabhängig vom Toggle-Zustand                  | existieren nur während des Wartungsfensters                        |
| Geschaltet wird                              | ausschließlich die Subnetz-Zuordnung                                | Erzeugen/Löschen der Ressourcen zusätzlich zur Zuordnung           |
| Laufende Kosten außerhalb der Wartung        | NAT Gateway und Public IP bestehen weiter und verursachen Kosten    | keine, da beide Ressourcen gelöscht sind                           |
| Dauer der eigentlichen Netzwerkänderung      | kurz — NAT Gateway existiert bereits, nur Attach nötig              | länger — NAT Gateway und Public IP müssen erst angelegt werden     |
| RBAC-Actions der Managed Identity            | 6 (Lesen und Zuordnen)                                              | 12 (zusätzlich Erzeugen und Löschen von NAT Gateway und Public IP) |
| Angriffsfläche bei kompromittierter Identity | kleiner — keine Lösch- oder Erzeugungsrechte auf Netzwerkressourcen | größer — kann Netzwerkressourcen anlegen und löschen               |

### 4.2 Betriebslogik (Locking, Rollback)

Diese Mechanismen sind eine Ergänzung des Codes, die nicht zwingend aus dem Ressourcenmodell in 3.1 folgt, aber gemeinsam mit ihm eingeführt wird, weil das Erzeugen/Löschen zusätzlicher Ressourcen den Ablauf ohnehin um mehr Schritte erweitert und damit mehr potentielle Bruchstellen schafft. 

| Aspekt                                   | Kapitel 04 (vorher)                                                         | Nach diesem Kapitel                                                                                                                  |
| ---------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Verhalten bei parallelen Toggle-Aufrufen | kein Locking; Ergebnis bei gleichzeitigen Aufrufen ist nicht definiert      | Blob-Lease-Lock im Worker; ein blockierter Auftrag wird über den automatischen Queue-Retry seriell nachgeholt statt sofort abgelehnt |
| Verhalten bei Teilfehlern                | kein automatisiertes Cleanup; Ressourcenzustand muss manuell geprüft werden | automatischer Rollback (On) bzw. `CleanupPending`-Status (Off)                                                                       |
| Code-Abhängigkeiten                      | `Az.Accounts`, `Az.Network`                                                 | zusätzlich `Az.Storage` für Lock und Status-Blob                                                                                     |

### 4.3 HTTP-Verhalten (synchron vs. asynchron)

Diese Änderung folgt aus Abschnitt 3: Ein HTTP-getriggerter Endpunkt hat unabhängig vom Hosting-Plan ein hartes 230-Sekunden-Zeitlimit für die Antwort (Azure-Load-Balancer-Idle-Timeout). Kapitel 04 blieb weit darunter, weil nur ein Attach stattfand. Das Erzeugen von NAT Gateway und Public IP plus Wartezeit kann sich dieser Grenze nähern — deshalb wird die Ausführung von der Annahme entkoppelt.

| Aspekt                       | Kapitel 04 (vorher)                         | Nach diesem Kapitel                                                              |
| ---------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------- |
| Anzahl Functions             | 1 (`ToggleWebInternet`)                     | 3 (`ToggleWebInternet`, `ToggleWebInternetWorker`, `GetToggleWebInternetStatus`) |
| Antwort auf Toggle-Aufruf    | synchron, Endergebnis direkt in der Antwort | `202 Accepted` mit `operationId`, Endergebnis über separaten Status-Endpunkt     |
| Risiko `504 Gateway Timeout` | praktisch nicht vorhanden                   | ohne diese Entkopplung real vorhanden — genau das wird hier vermieden            |

Die Function App, der Storage Account und die Managed Identity bleiben dieselben Ressourcen wie in Kapitel 04 — dieses Update deployt darin nur zusätzliche Functions statt einer neuen App. Der Function Key existiert danach pro aufrufbarer HTTP-Function, also zweimal statt einmal (Abschnitt 12.1).

## 5. Von Kapitel 04 auf dieses Kapitel aktualisieren

Diese Reihenfolge ist bindend. Sie stellt sicher, dass zu keinem Zeitpunkt Ressourcen verwaist zurückbleiben oder die Netzwerkisolation ungeprüft aufgehoben ist.

### 5.1 Sicherstellen, dass aktuell nichts zugeordnet ist

**Auf Azure Cloud Shell aufschalten**

Verifizieren — das Ergebnis muss leer sein, bevor der nächste Schritt ausgeführt wird:

```bash
az network vnet subnet show \
  --resource-group rg-<project>-<environment>-<region> \
  --vnet-name vnet-<project> \
  --name snet-web \
  --query "natGateway.id" \
  --output tsv
```

Sollte keine Ausgabe liefern, ansonsten:

```bash
curl -X POST \
  "https://<function-hostname>/api/ToggleWebInternet?code=<function-key>" \
  -H "Content-Type: application/json" \
  -d '{"State": "Off"}'
```

### 5.2 Alte, dauerhafte NAT-Ressourcen löschen

Nur ausführen, wenn Abschnitt 5.1 einen leeren Wert ergeben hat. Ab hier legt ausschließlich die Function selbst NAT Gateway und Public IP an und wieder ab.

**Portal (Klick-für-Klick):**

1. Resource Group `rg-<project>-<environment>-<region>` öffnen
2. `nat-<project>` (NAT gateway) öffnen → **Delete** → Namen zur Bestätigung eintippen → **Delete**
3. `pip-<project>-nat` (Public IP address) öffnen → **Delete** → Namen zur Bestätigung eintippen → **Delete**


**Oder per CLI:**

```bash
az network nat gateway delete \
  --resource-group rg-<project>-<environment>-<region> \
  --name nat-<project>

az network public-ip delete \
  --resource-group rg-<project>-<environment>-<region> \
  --name pip-<project>-nat
```


## 6. RBAC Custom Role erweitern

Die bestehende Rolle aus `04_function_app_managed_identity_nat_gateway.md` wird **erweitert, nicht ersetzt** — dieselbe Rollen-Id bleibt bestehen, nur der Satz an Actions wächst.

Aktuelle Definition abrufen:

```bash
az role definition list --name "NAT Gateway Toggle Operator" --output json > nat-toggle-role.json
nano nat-toggle-role.json
```

```json
{
  "Name": "NAT Gateway Toggle Operator",
  "IsCustom": true,
  "Description": "Erzeugt, bindet, löst und entfernt das NAT Gateway für den Wartungszugang der Web-VM.",
  "Actions": [
    "Microsoft.Network/virtualNetworks/read",
    "Microsoft.Network/virtualNetworks/write",
    "Microsoft.Network/virtualNetworks/subnets/read",
    "Microsoft.Network/virtualNetworks/subnets/write",
    "Microsoft.Network/natGateways/read",
    "Microsoft.Network/natGateways/write",
    "Microsoft.Network/natGateways/delete",
    "Microsoft.Network/publicIPAddresses/read",
    "Microsoft.Network/publicIPAddresses/write",
    "Microsoft.Network/publicIPAddresses/delete",
    "Microsoft.Network/publicIPAddresses/join/action",
    "Microsoft.Network/networkSecurityGroups/join/action"
  ],
  "NotActions": [],
  "AssignableScopes": [
    "/subscriptions/<subscription>/resourceGroups/rg-<project>-<environment>-<region>"
  ]
}
```
> **Hinweis:** `networkSecurityGroups/join/action` stammt aus `04_function_app_managed_identity_nat_gateway.md` und schützt vor `LinkedAuthorizationFailed` bei Schreibvorgängen auf dem VNet. Der Grund dafür ändert sich durch dieses Update nicht — die Action bleibt deshalb erhalten, auch wenn sie in den neuen Funktionen nicht direkt im Vordergrund steht.


Update ausführen:

```bash
az role definition update --role-definition nat-toggle-role.json
```

RBAC-Änderungen brauchen etwas Zeit, bis sie propagiert sind — vor dem ersten Testlauf ein bis zwei Minuten warten und dann prüfen:

```bash
az role assignment list \
  --scope /subscriptions/<subscription>/resourceGroups/rg-<project>-<environment>-<region> \
  --query "[?roleDefinitionName=='NAT Gateway Toggle Operator']" \
  --output table
```

Jede zusätzliche Action über diese Liste hinaus vergrößert die Angriffsfläche, falls die Function App kompromittiert wird, und sollte vermieden werden.

## 7. Function-Code aktualisieren

Für **jeden** HTTP-getriggerten Azure-Functions-Endpunkt gilt, unabhängig vom Hosting-Plan: **230 Sekunden** Idle-Timeout am Azure Load Balancer für die HTTP-Antwort. `functionTimeout` in `host.json` kann das nicht verschieben. Die Kombination aus NAT-Gateway-/Public-IP-Erstellung, Attach und bis zu 180 Sekunden Wartezeit in `Wait-SubnetNatState` kann sich dieser Grenze gefährlich nähern. Deshalb wird aus der einen HTTP-Function `ToggleWebInternet` eine Aufteilung in drei Functions:

* **`ToggleWebInternet`** (HTTP-Trigger, bleibt der öffentliche Endpunkt): nimmt nur noch an, validiert und schreibt einen Auftrag in eine Queue. Antwortet sofort mit `202 Accepted` und einer `operationId` — ohne dass die Netzwerkänderung schon stattgefunden hat.
* **`ToggleWebInternetWorker`** (Queue-Trigger): führt die eigentliche Netzwerkänderung aus. Queue-Trigger unterliegen nicht dem 230-Sekunden-HTTP-Limit, nur dem regulären `functionTimeout` (bis zu 10 Minuten).
* **`GetToggleWebInternetStatus`** (HTTP-Trigger): liest den Fortschritt aus einem Status-Blob und gibt `Queued | Running | Succeeded | Failed | CleanupPending` zurück.

> **Keine RBAC-Änderung nötig:** Queue senden/empfangen und der Status-Blob laufen über dieselbe Storage-Account-Connection-String (`$env:AzureWebJobsStorage`), die auch der Lock schon nutzt — das ist Shared-Key-Zugriff auf die Storage-Datenebene, keine ARM-Operation. Die Rolle aus Abschnitt 6 bleibt unverändert.

Die Dateistruktur aus `04_function_app_managed_identity_nat_gateway.md` wird dadurch erweitert:

```text
scripts/
└── function/
    ├── profile.ps1
    ├── host.json
    ├── requirements.psd1
    ├── ToggleWebInternet/
    │   ├── function.json
    │   └── run.ps1
    ├── ToggleWebInternetWorker/
    │   ├── function.json
    │   └── run.ps1
    ├── GetToggleWebInternetStatus/
    │   ├── function.json
    │   └── run.ps1
    └── Modules/
        ├── StatusStore/
        │   └── StatusStore.psm1
        └── RetryHelper/
            └── RetryHelper.psm1
```

**Auf Azure Cloud Shell:**

```bash
mkdir -p scripts/function/ToggleWebInternet \
         scripts/function/ToggleWebInternetWorker \
         scripts/function/GetToggleWebInternetStatus \
         scripts/function/Modules/StatusStore \
         scripts/function/Modules/RetryHelper
```


### 7.1 `scripts/function/host.json`

Neu gegenüber `04_function_app_managed_identity_nat_gateway.md` (hatte keine `host.json`):
Erhöht das Funktions-Timeout auf das für den Consumption Plan zulässige Maximum, konfiguriert die Queue-Retry-Logik und aktiviert explizit die Modul-Installation:

```bash
nano scripts/function/host.json
```

```json
{
  "version": "2.0",
  "managedDependency": {
    "enabled": true
  },
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle",
    "version": "[4.*, 5.0.0)"
  },
  "functionTimeout": "00:10:00",
  "extensions": {
    "queues": {
      "maxDequeueCount": 5,
      "visibilityTimeout": "00:00:30"
    }
  }
}
```


> 1. **`extensionBundle`** ist für nicht-kompilierte Runtimes wie PowerShell zwingend, damit der Host überhaupt einen Queue-Trigger-Listener registriert. Fehlt der Eintrag, existiert die Function `ToggleWebInternetWorker` zwar (`az functionapp function list` zeigt sie an), aber es findet nie ein Trigger-Aufruf statt — Nachrichten bleiben dauerhaft auf `Queued` stehen, ohne dass irgendwo ein Fehler sichtbar wird.
> 2. **`managedDependency.enabled: true`** ist erforderlich, damit Azure die Module aus `requirements.psd1` zuverlässig installiert. Ohne diesen Schalter kann es passieren, dass z. B. `Az.Storage` nie installiert wird und `New-AzStorageContext`/`New-AzStorageContainer` mit „term not recognized" fehlschlagen, obwohl `requirements.psd1` korrekt im Deploy-Paket liegt.

### 7.2 `scripts/function/requirements.psd1`

```bash
nano scripts/function/requirements.psd1
```

```powershell
@{
    'Az.Accounts' = '3.0.4'
    'Az.Network'  = '7.5.0'
    'Az.Storage'  = '6.2.0'
}
```

`Az.Storage` wird sowohl für den Lock als auch für den Status-Blob-Container gebraucht.


#### `scripts/function/profile.ps1`

`profile.ps1` läuft bei Cold Starts der Function App. Der Managed-Identity-Login ist hier bewusst nur best-effort: Der Worker authentifiziert sich vor der eigentlichen Azure-Operation selbst noch einmal mit Retry innerhalb seines normalen Fehlerpfads.

```bash
nano scripts/function/profile.ps1
```

```powershell
# Azure Functions profile.ps1
#
# This profile.ps1 will get executed every "cold start" of your Function App.
# "cold start" occurs when:
#
# * A Function App starts up for the very first time
# * A Function App starts up after being de-allocated due to inactivity
#
# You can define helper functions, run commands, or specify environment variables
# NOTE: any variables defined that are not environment variables will get reset after the first execution

# Authenticate with Azure PowerShell using MSI.
# Keep this best-effort only: the worker performs its own managed-identity
# login with retry inside its normal error path.
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    try {
        Connect-AzAccount -Identity | Out-Null
    }
    catch {
        Write-Host "WARNUNG: Connect-AzAccount im profile.ps1 fehlgeschlagen: $($_.Exception.Message)"
    }
}

# Uncomment the next line to enable legacy AzureRm alias in Azure PowerShell.
# Enable-AzureRmAlias

# You can also define functions or aliases that can be referenced in any of your PowerShell functions.
```

### 7.3 `scripts/function/ToggleWebInternet/function.json` (HTTP-Starter)

Neu ist das Queue-Output-Binding — es gibt in PowerShell-Functions keine Cmdlets für die Queue-Datenebene, ein direktes SDK-Handling über `Get-AzStorageQueue` bringt bekannte Versions- und Async-Fallstricke mit sich. Das Binding umgeht das:

```bash
nano scripts/function/ToggleWebInternet/function.json
```

```json
{
  "bindings": [
    {
      "authLevel": "function",
      "type": "httpTrigger",
      "direction": "in",
      "name": "Request",
      "methods": ["post"]
    },
    {
      "type": "queue",
      "direction": "out",
      "name": "QueueMessage",
      "queueName": "toggle-requests",
      "connection": "AzureWebJobsStorage"
    },
    {
      "type": "http",
      "direction": "out",
      "name": "Response"
    }
  ]
}
```

### 7.4 `scripts/function/ToggleWebInternet/run.ps1` (HTTP-Starter)

Macht im Kern drei Dinge: `State` validieren, Status-Datensatz mit neuer `operationId` anlegen, Auftrag in die Queue schreiben.

```bash
nano scripts/function/ToggleWebInternet/run.ps1
```

```powershell
using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

$State = $Request.Query.State
if (-not $State) { $State = $Request.Body.State }
$State = ("$State").Trim().ToLowerInvariant()

if ($State -notin @('on', 'off')) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = "Parameter 'State' muss 'On' oder 'Off' sein."
    })
    return
}

$OperationId = [guid]::NewGuid().ToString()
$RequestedAt = (Get-Date).ToUniversalTime().ToString('o')

try {
    Set-OperationStatus -OperationId $OperationId -State $State -Status 'Queued' -RequestedAt $RequestedAt

    $queueMessage = @{
        operationId = $OperationId
        state       = $State
        requestedAt = $RequestedAt
    } | ConvertTo-Json -Compress

    Push-OutputBinding -Name QueueMessage -Value $queueMessage

    $responseBody = @{
        operationId = $OperationId
        status      = 'Queued'
        statusCheck = "GET /api/GetToggleWebInternetStatus?operationId=$OperationId&code=<function-key-status>"
    } | ConvertTo-Json -Compress

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Accepted
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = $responseBody
    })
}
catch {
    Write-Host "FEHLER [$OperationId]: $($_.Exception.ToString())"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{
            error       = 'Der Vorgang konnte nicht gestartet werden.'
            operationId = $OperationId
        } | ConvertTo-Json -Compress)
    })
}
```

> Die Antwort enthält bewusst nicht mehr „Internetzugang aktiviert." — das wäre an dieser Stelle schlicht falsch, weil die Änderung noch gar nicht stattgefunden hat.
>
> **Fehlerantwort bewusst generisch:** Der `catch`-Block gibt nicht mehr `$_.Exception.Message` direkt an den Aufrufer zurück, sondern nur eine generische Meldung plus `operationId`. Die tatsächliche Fehlermeldung landet stattdessen im Log-Stream (`Write-Host`) — so lässt sich der Fehler bei Bedarf nachvollziehen, ohne interne Details (Ressourcennamen, Stacktraces) über einen öffentlich erreichbaren HTTP-Endpunkt preiszugeben.
 

### 7.5 `scripts/function/ToggleWebInternetWorker/function.json` (Queue-Worker)

```bash
nano scripts/function/ToggleWebInternetWorker/function.json
```


```json
{
  "bindings": [
    {
      "type": "queueTrigger",
      "direction": "in",
      "name": "QueueItem",
      "dataType": "string",
      "queueName": "toggle-requests",
      "connection": "AzureWebJobsStorage"
    }
  ]
}
```

> **`dataType: "string"` explizit setzen.** Ohne diese Angabe hat die Runtime `$QueueItem` in der Praxis als `System.Byte[]` statt als dekodierten String bereitgestellt. Ein `[string]$QueueItem`-Cast auf ein Byte-Array liefert dabei nicht den decodierten Text, sondern den .NET-Typnamen als String (`"System.Byte[]"`) — `ConvertFrom-Json` scheitert dann mit einer kryptischen Meldung wie *„Unexpected character encountered while parsing value: S."*, weil es faktisch versucht, den Text `System.Byte[]` als JSON zu parsen. `run.ps1` behandelt beide Fälle zusätzlich defensiv (siehe unten), `dataType` behebt die Ursache direkt am Binding. Eine frühere Fassung hatte hier zusätzlich zwei Write-Host-Zeilen zur Diagnose (Typ und Rohinhalt der Nachricht) stehen; die sind nach stabil bestätigtem Betrieb entfernt worden, damit keine Nutzdaten dauerhaft im Klartext-Log landen.

### 7.6 `scripts/function/ToggleWebInternetWorker/run.ps1` (Queue-Worker)

Der Worker führt die eigentliche Netzwerkänderung aus. Queue-Nachrichten werden robust gelesen, der Managed-Identity-Login läuft mit Retry im Fehlerpfad, der Status wechselt erst nach erfolgreichem Lock auf `Running`, und nur echte Lease-Konflikte werden als `LOCK_BEREITS_BELEGT` behandelt.

```bash
nano scripts/function/ToggleWebInternetWorker/run.ps1
```

```powershell
param($QueueItem, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

function Get-RequiredEnv {
    param([string]$Name)
    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "App Setting '$Name' ist nicht gesetzt."
    }
    return $value
}

$ResourceGroupName   = Get-RequiredEnv 'TOGGLEWEBINTERNET_RESOURCE_GROUP'
$VnetName            = Get-RequiredEnv 'TOGGLEWEBINTERNET_VNET_NAME'
$SubnetName          = Get-RequiredEnv 'TOGGLEWEBINTERNET_SUBNET_NAME'
$NatGatewayName      = Get-RequiredEnv 'TOGGLEWEBINTERNET_NAT_GATEWAY_NAME'
$PublicIpName        = Get-RequiredEnv 'TOGGLEWEBINTERNET_PUBLIC_IP_NAME'
$Location            = Get-RequiredEnv 'TOGGLEWEBINTERNET_LOCATION'
$LockContainerName   = 'locks'
$LockBlobName        = 'togglewebinternet.lock'
$MaxDequeueCount     = 5   # muss mit host.json > extensions.queues.maxDequeueCount übereinstimmen
$LeaseDurationSeconds = 60
$RenewIntervalSeconds = 25 # deutlich unter LeaseDurationSeconds, um Netzwerk-Jitter abzufangen

$script:LastRenewedAt = $null

function Initialize-LockBlob {
    $ctx = Get-StorageContext

    # Hinweis: Az.Storage-Cmdlets liefern bei "nicht gefunden" i. d. R. $null
    # statt einer Exception (anders als Az.Network) - SilentlyContinue ist hier
    # bewusst korrekt. Invoke-WithRetry fängt trotzdem echte transiente Fehler
    # (Throttling, Timeout) ab, die sonst als Exception durchschlagen würden.
    $container = Invoke-WithRetry -OperationName 'Get-AzStorageContainer' -ScriptBlock {
        Get-AzStorageContainer -Name $LockContainerName -Context $ctx -ErrorAction SilentlyContinue
    }
    if (-not $container) {
        $container = Invoke-WithRetry -OperationName 'New-AzStorageContainer' -ScriptBlock {
            New-AzStorageContainer -Name $LockContainerName -Context $ctx -Permission Off
        }
    }

    $blob = Invoke-WithRetry -OperationName 'Get-AzStorageBlob' -ScriptBlock {
        Get-AzStorageBlob -Container $LockContainerName -Blob $LockBlobName -Context $ctx -ErrorAction SilentlyContinue
    }
    if (-not $blob) {
        $temp = Join-Path $env:TEMP 'togglewebinternet.lock'
        Set-Content -Path $temp -Value 'lock' -NoNewline -Encoding UTF8
        try {
            Invoke-WithRetry -OperationName 'Set-AzStorageBlobContent' -ScriptBlock {
                Set-AzStorageBlobContent -Container $LockContainerName -Blob $LockBlobName -File $temp -Context $ctx | Out-Null
            }
        }
        finally {
            Remove-Item -Path $temp -ErrorAction SilentlyContinue
        }
    }
}

function Enter-Lock {
    Initialize-LockBlob
    $ctx = Get-StorageContext
    $blob = Get-AzStorageBlob -Container $LockContainerName -Blob $LockBlobName -Context $ctx

    $leaseClient = New-Object Azure.Storage.Blobs.Specialized.BlobLeaseClient -ArgumentList $blob.BlobBaseClient

    try {
        $leaseClient.Acquire((New-TimeSpan -Seconds $LeaseDurationSeconds)) | Out-Null
    }
    catch {
        $ex = $_.Exception
        $statusCode = $null
        if ($ex.PSObject.Properties.Match('Status').Count -gt 0) { $statusCode = $ex.Status }
        $errorCode = $null
        if ($ex.PSObject.Properties.Match('ErrorCode').Count -gt 0) { $errorCode = $ex.ErrorCode }

        if ($statusCode -eq 409 -or $errorCode -eq 'LeaseAlreadyPresent') {
            throw 'LOCK_BEREITS_BELEGT'
        }
        throw
    }

    $script:LastRenewedAt = Get-Date
    return $leaseClient
}

function Confirm-LockRenewal {
    param($LeaseClient)

    if (-not $LeaseClient) { return }
    if (((Get-Date) - $script:LastRenewedAt).TotalSeconds -lt $RenewIntervalSeconds) { return }

    try {
        $LeaseClient.Renew() | Out-Null
        $script:LastRenewedAt = Get-Date
    }
    catch {
        throw 'LOCK_RENEW_FEHLGESCHLAGEN'
    }
}

function Exit-Lock {
    param($LeaseClient)

    if (-not $LeaseClient) { return }

    try {
        $LeaseClient.Release() | Out-Null
    }
    catch {
    }
}

function Get-SubnetObject {
    $vnet = Invoke-WithRetry -OperationName 'Get-AzVirtualNetwork' -ScriptBlock {
        Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName
    }
    $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName
    if (-not $subnet) { throw "Subnet '$SubnetName' wurde nicht gefunden." }
    return $subnet
}

function Initialize-PublicIp {
    param($LeaseClient)

    $pip = Get-AzResourceOrNull -OperationName 'Get-AzPublicIpAddress' -ScriptBlock {
        Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PublicIpName -ErrorAction Stop
    }
    if (-not $pip) {
        Confirm-LockRenewal -LeaseClient $LeaseClient
        $pip = Invoke-WithRetry -OperationName 'New-AzPublicIpAddress' -ScriptBlock {
            New-AzPublicIpAddress `
                -ResourceGroupName $ResourceGroupName `
                -Name $PublicIpName `
                -Location $Location `
                -Sku Standard `
                -AllocationMethod Static `
                -Tier Regional
        }
    }
    return $pip
}

function Initialize-NatGateway {
    param($LeaseClient)

    $nat = Get-AzResourceOrNull -OperationName 'Get-AzNatGateway' -ScriptBlock {
        Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $NatGatewayName -ErrorAction Stop
    }
    if (-not $nat) {
        $pip = Initialize-PublicIp -LeaseClient $LeaseClient
        Confirm-LockRenewal -LeaseClient $LeaseClient
        $nat = Invoke-WithRetry -OperationName 'New-AzNatGateway' -ScriptBlock {
            New-AzNatGateway `
                -ResourceGroupName $ResourceGroupName `
                -Name $NatGatewayName `
                -Location $Location `
                -Sku Standard `
                -PublicIpAddress $pip
        }
    }
    return $nat
}

function Add-NatToSubnet {
    param($Nat)

    $vnet = Invoke-WithRetry -OperationName 'Get-AzVirtualNetwork' -ScriptBlock {
        Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName
    }
    $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName
    if (-not $subnet) { throw "Subnet '$SubnetName' wurde nicht gefunden." }

    if ($subnet.NatGateway -and $subnet.NatGateway.Id -eq $Nat.Id) {
        return
    }

    $subnet.NatGateway = $Nat
    Invoke-WithRetry -OperationName 'Set-AzVirtualNetwork' -ScriptBlock {
        Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
    }
}

function Remove-NatFromSubnet {
    $vnet = Invoke-WithRetry -OperationName 'Get-AzVirtualNetwork' -ScriptBlock {
        Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName
    }
    $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName
    if (-not $subnet) { throw "Subnet '$SubnetName' wurde nicht gefunden." }

    if (-not $subnet.NatGateway) {
        return
    }

    $subnet.NatGateway = $null
    Invoke-WithRetry -OperationName 'Set-AzVirtualNetwork' -ScriptBlock {
        Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
    }
}

function Wait-SubnetNatState {
    param(
        [string]$ExpectedNatId,
        $LeaseClient,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        Start-Sleep -Seconds 5
        Confirm-LockRenewal -LeaseClient $LeaseClient
        $subnet = Get-SubnetObject
        $current = if ($subnet.NatGateway) { $subnet.NatGateway.Id } else { $null }

        if ($ExpectedNatId) {
            if ($current -eq $ExpectedNatId) { return }
        }
        else {
            if (-not $current) { return }
        }
    } while ((Get-Date) -lt $deadline)

    throw "Timeout beim Warten auf den gewünschten Subnetz-Zustand."
}

function Remove-NatGatewayIfExists {
    param($LeaseClient)

    $nat = Get-AzResourceOrNull -OperationName 'Get-AzNatGateway' -ScriptBlock {
        Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $NatGatewayName -ErrorAction Stop
    }
    if ($nat) {
        Confirm-LockRenewal -LeaseClient $LeaseClient
        Invoke-WithRetry -OperationName 'Remove-AzNatGateway' -ScriptBlock {
            Remove-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $NatGatewayName -Force
        }
    }
}

function Remove-PublicIpIfExists {
    param($LeaseClient)

    $pip = Get-AzResourceOrNull -OperationName 'Get-AzPublicIpAddress' -ScriptBlock {
        Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PublicIpName -ErrorAction Stop
    }
    if ($pip) {
        Confirm-LockRenewal -LeaseClient $LeaseClient
        Invoke-WithRetry -OperationName 'Remove-AzPublicIpAddress' -ScriptBlock {
            Remove-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PublicIpName -Force
        }
    }
}
# Queue-Input robust behandeln:
# - byte[] => UTF-8 String
# - string => JSON parsen
# - Objekt/Hashtable => direkt verwenden
if ($QueueItem -is [byte[]]) {
    $QueueItem = [System.Text.Encoding]::UTF8.GetString($QueueItem)
}

if ($QueueItem -is [string]) {
    $QueueItem = $QueueItem.Trim([char]0xFEFF).Trim()
    try {
        $job = $QueueItem | ConvertFrom-Json
    }
    catch {
        # Falls die Nachricht base64-kodiert ankam (CloudQueue.AddMessage kodiert je nach
        # EncodeMessage-Default des CloudQueueClient) und der Host sie nicht automatisch
        # dekodiert hat: einmalig Base64 versuchen, bevor der Parse-Fehler durchgereicht wird.
        $decodedBytes = [System.Convert]::FromBase64String($QueueItem)
        $decodedText  = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
        $job = $decodedText | ConvertFrom-Json
    }
}
else {
    $job = $QueueItem
}

$OperationId  = $job.operationId
$State        = $job.state
$RequestedAt  = $job.requestedAt
$DequeueCount = [int]$TriggerMetadata.DequeueCount

$leaseClient = $null

try {
    Invoke-WithRetry -OperationName 'Connect-AzAccount(Identity)' -ScriptBlock {
        Connect-AzAccount -Identity | Out-Null
    }

    try {
        $leaseClient = Enter-Lock
    }
    catch {
        if ($_.Exception.Message -eq 'LOCK_BEREITS_BELEGT' -and $DequeueCount -ge $MaxDequeueCount) {
            Set-OperationStatus -OperationId $OperationId -State $State -Status 'Failed' `
                -Message 'Lock war dauerhaft belegt; Auftrag nach mehreren Versuchen verworfen.' -RequestedAt $RequestedAt
        }
        throw
    }

    Set-OperationStatus -OperationId $OperationId -State $State -Status 'Running' -RequestedAt $RequestedAt

    if ($State -eq 'on') {
        $nat = Initialize-NatGateway -LeaseClient $leaseClient

        try {
            Add-NatToSubnet -Nat $nat
            Confirm-LockRenewal -LeaseClient $leaseClient
            Wait-SubnetNatState -ExpectedNatId $nat.Id -LeaseClient $leaseClient
            Set-OperationStatus -OperationId $OperationId -State $State -Status 'Succeeded' `
                -Message 'Internetzugang aktiviert.' -RequestedAt $RequestedAt
        }
        catch {
            try { Remove-NatFromSubnet } catch { }
            try { Remove-NatGatewayIfExists -LeaseClient $leaseClient } catch { }
            try { Remove-PublicIpIfExists -LeaseClient $leaseClient } catch { }
            throw
        }
    }
    else {
        Remove-NatFromSubnet
        Confirm-LockRenewal -LeaseClient $leaseClient
        Wait-SubnetNatState -ExpectedNatId $null -LeaseClient $leaseClient

        $cleanupErrors = @()
        try { Remove-NatGatewayIfExists -LeaseClient $leaseClient } catch { $cleanupErrors += $_.Exception.Message }
        try { Remove-PublicIpIfExists -LeaseClient $leaseClient } catch { $cleanupErrors += $_.Exception.Message }

        if ($cleanupErrors.Count -gt 0) {
            Set-OperationStatus -OperationId $OperationId -State $State -Status 'CleanupPending' `
                -Message ($cleanupErrors -join ' | ') -RequestedAt $RequestedAt
        }
        else {
            Set-OperationStatus -OperationId $OperationId -State $State -Status 'Succeeded' `
                -Message 'Internetzugang deaktiviert.' -RequestedAt $RequestedAt
        }
    }
}
catch {
    if ($_.Exception.Message -eq 'LOCK_RENEW_FEHLGESCHLAGEN') {
        Set-OperationStatus -OperationId $OperationId -State $State -Status 'Failed' `
            -Message 'Lock-Erneuerung fehlgeschlagen; Vorgang abgebrochen, um Ressourcen nicht ohne gültigen Lock zu verändern.' -RequestedAt $RequestedAt
    }
    elseif ($_.Exception.Message -ne 'LOCK_BEREITS_BELEGT') {
        Set-OperationStatus -OperationId $OperationId -State $State -Status 'Failed' `
            -Message $_.Exception.Message -RequestedAt $RequestedAt
    }
    throw
}
finally {
    Exit-Lock -LeaseClient $leaseClient
}
```

> **Es gibt kein natives Az.Storage-Cmdlet für Blob-Leases.** `Start-AzStorageBlobLease` und `Stop-AzStorageBlobLease` existieren nicht — offener Feature-Request [Azure/azure-powershell#27068](https://github.com/Azure/azure-powershell/issues/27068), kein vorhandenes Cmdlet. Der von einem Az-PowerShell-Maintainer bestätigte Weg: direkter Zugriff auf den zugrunde liegenden .NET-SDK-Client über `$blob.BlobBaseClient`, darauf einen `Azure.Storage.Blobs.Specialized.BlobLeaseClient` konstruieren. Nutzt weiterhin die Storage-Account-Connection-String (Shared Key über `$env:AzureWebJobsStorage`) — die RBAC-Rolle „Storage Blob Data Contributor" aus der offiziellen Doku ist nur für Microsoft-Entra-ID-Auth nötig und betrifft uns hier nicht.
>
> **Warum eine kurze, erneuerte Lease statt einer unbefristeten:** Eine Azure-Blob-Lease ist auf 15–60 Sekunden befristet oder unbefristet (`-1`) — eine dritte Option gibt es nicht. Eine unbefristete Lease läuft nicht von selbst ab; sie endet erst durch `Exit-Lock` im `finally`-Block — wird der Prozess hart abgebrochen, bevor `finally` erreicht wird, bleibt sie für immer hängen und braucht ein manuelles `az storage blob lease break`. Eine kurze 60-Sekunden-Lease mit `Renew` alle 25 Sekunden (`Confirm-LockRenewal`, aufgerufen nach jedem größeren Schritt und in der Poll-Schleife von `Wait-SubnetNatState`) schützt genauso zuverlässig über die volle Dauer des Vorgangs, heilt sich bei einem harten Absturz aber innerhalb von höchstens 60 Sekunden von selbst. Schlägt eine Erneuerung fehl (`LOCK_RENEW_FEHLGESCHLAGEN`), bricht der Worker sofort ab.
>
> **Warum der Lock im Worker liegt, nicht im HTTP-Starter:** Azure kann mehrere Queue-Nachrichten parallel an verschiedene Worker-Instanzen ausliefern. Würde der HTTP-Starter die Lease erwerben und die LeaseId nur an den Worker weiterreichen, entstünde eine unsaubere Trennung zwischen Erwerb und Freigabe über zwei Funktionsaufrufe hinweg — Queues liefern nur *at-least-once*, eine Nachricht kann erneut zugestellt werden. Sauberer: Der Worker erwirbt und gibt die Lease vollständig selbst frei, in einem einzigen Aufruf.

### 7.7 `scripts/function/GetToggleWebInternetStatus/function.json` und `run.ps1`

```bash
nano scripts/function/GetToggleWebInternetStatus/function.json
```

```json
{
  "bindings": [
    {
      "authLevel": "function",
      "type": "httpTrigger",
      "direction": "in",
      "name": "Request",
      "methods": ["get"]
    },
    {
      "type": "http",
      "direction": "out",
      "name": "Response"
    }
  ]
}
```

### 7.8 `scripts/function/GetToggleWebInternetStatus/run.ps1`

```bash
nano scripts/function/GetToggleWebInternetStatus/run.ps1
```

```powershell
using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

$OperationId = $Request.Query.operationId
if (-not $OperationId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = "Parameter 'operationId' fehlt."
    })
    return
}

$parsedGuid = [guid]::Empty
if (-not [guid]::TryParse($OperationId, [ref]$parsedGuid)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = "Parameter 'operationId' muss eine gültige GUID sein."
    })
    return
}
$OperationId = $parsedGuid.ToString()

try {
    $content = Get-OperationStatus -OperationId $OperationId

    if (-not $content) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = "Keine Statusinformation zu dieser operationId gefunden."
        })
        return
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = $content
    })
}
catch {
    Write-Host "FEHLER [$OperationId]: $($_.Exception.ToString())"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{
            error       = 'Der Status konnte nicht abgerufen werden.'
            operationId = $OperationId
        } | ConvertTo-Json -Compress)
    })
}
```

Mögliche Werte für `status`: `Queued`, `Running`, `Succeeded`, `Failed`, `CleanupPending`.

### 7.9 Gemeinsame Module: `Modules/StatusStore/StatusStore.psm1` und `Modules/RetryHelper/RetryHelper.psm1`

Diese beiden Module werden von allen drei Functions automatisch geladen.

**`Modules/StatusStore/StatusStore.psm1`** bündelt die Storage-Logik:

```bash
nano scripts/function/Modules/StatusStore/StatusStore.psm1
```

```powershell
# StatusStore.psm1

$script:StatusContainerName = 'status'

function Get-StorageContext {
    <#
    .SYNOPSIS
        Liefert den Az-Storage-Context auf Basis von AzureWebJobsStorage.
    #>
    if (-not $env:AzureWebJobsStorage) {
        throw 'AzureWebJobsStorage ist nicht verfügbar.'
    }
    return New-AzStorageContext -ConnectionString $env:AzureWebJobsStorage
}

function Set-OperationStatus {
    <#
    .SYNOPSIS
        Schreibt den Status eines Vorgangs als JSON-Blob in den 'status'-Container.
    #>
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Status,
        [string]$Message = '',
        [Parameter(Mandatory)][string]$RequestedAt
    )

    $ctx = Get-StorageContext

    # -ErrorAction SilentlyContinue beim Create statt Get-dann-New:
    # vermeidet die Race Condition, wenn zwei Aufrufe gleichzeitig prüfen,
    # ob der Container existiert, und beide ihn anlegen wollen.
    # Invoke-WithRetry (aus dem RetryHelper-Modul) fängt trotzdem echte
    # transiente Fehler wie Throttling ab, statt den Job sofort abbrechen zu lassen.
    Invoke-WithRetry -OperationName 'New-AzStorageContainer(status)' -ScriptBlock {
        New-AzStorageContainer -Name $script:StatusContainerName -Context $ctx -Permission Off -ErrorAction SilentlyContinue | Out-Null
    }

    # Reihenfolge-Schutz: Starter (Queued) und Worker (Running/Succeeded/Failed) schreiben
    # unabhängig voneinander auf denselben Blob, ohne dass ein Aufrufer vom anderen weiß.
    # Ohne diese Prüfung kann ein verzögerter 'Queued'-Write des Starters einen bereits
    # geschriebenen 'Running'-Status des Workers wieder überschreiben. Ein Status, der laut
    # dieser Rangfolge bereits weiter fortgeschritten ist, wird daher nicht zurückgesetzt.
    # Das ist ein Read-Check-Write - das praktische Zeitfenster der Race schrumpft von 
    # "gesamte Laufzeit beider Aufrufe" auf die Lücke zwischen diesem Read und dem Write 
    # weiter unten, verschwindet aber nicht theoretisch vollständig.
    $statusRank = @{ 'Queued' = 1; 'Running' = 2; 'Succeeded' = 3; 'Failed' = 3 }
    $existingRaw = Get-OperationStatus -OperationId $OperationId
    if ($existingRaw) {
        $existing = $existingRaw | ConvertFrom-Json
        if ($statusRank.ContainsKey($existing.status) -and $statusRank.ContainsKey($Status) `
                -and $statusRank[$existing.status] -gt $statusRank[$Status]) {
            Write-Host "INFO [$OperationId]: Status-Write '$Status' übersprungen - vorhandener Status '$($existing.status)' ist bereits weiter fortgeschritten."
            return
        }
    }

    $body = @{
        operationId = $OperationId
        state       = $State
        status      = $Status
        message     = $Message
        requestedAt = $RequestedAt
        updatedAt   = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Compress

    $temp = Join-Path $env:TEMP "$OperationId.json"
    try {
        Set-Content -Path $temp -Value $body -NoNewline -Encoding UTF8
        Invoke-WithRetry -OperationName 'Set-AzStorageBlobContent(status)' -ScriptBlock {
            Set-AzStorageBlobContent -Container $script:StatusContainerName -Blob "$OperationId.json" -File $temp -Context $ctx -Force | Out-Null
        }
    }
    finally {
        Remove-Item -Path $temp -ErrorAction SilentlyContinue
    }
}

function Get-OperationStatus {
    <#
    .SYNOPSIS
        Liest den Status eines Vorgangs aus dem 'status'-Container.
    .OUTPUTS
        Der rohe JSON-String, oder $null, falls kein Status-Blob existiert.
    #>
    param(
        [Parameter(Mandatory)][string]$OperationId
    )

    $ctx = Get-StorageContext
    $blob = Invoke-WithRetry -OperationName 'Get-AzStorageBlob(status)' -ScriptBlock {
        Get-AzStorageBlob -Container $script:StatusContainerName -Blob "$OperationId.json" -Context $ctx -ErrorAction SilentlyContinue
    }

    if (-not $blob) {
        return $null
    }

    $temp = Join-Path $env:TEMP "$OperationId-read.json"
    try {
        Invoke-WithRetry -OperationName 'Get-AzStorageBlobContent(status)' -ScriptBlock {
            Get-AzStorageBlobContent -Container $script:StatusContainerName -Blob "$OperationId.json" -Context $ctx -Destination $temp -Force | Out-Null
        }
        return Get-Content -Path $temp -Raw
    }
    finally {
        Remove-Item -Path $temp -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-StorageContext, Set-OperationStatus, Get-OperationStatus
```

> **Temp-Datei-Aufräumen per `finally`:** `Remove-Item -ErrorAction SilentlyContinue` im `finally`-Block räumen auf, auch wenn `Set-AzStorageBlobContent`/`Get-AzStorageBlobContent` fehlschlägt.

**`Modules/RetryHelper/RetryHelper.psm1`** kapselt Retry-mit-Exponential-Backoff für einzelne Azure-API-Aufrufe sowie die Unterscheidung zwischen einem transienten Fehler und einem echten „Ressource existiert nicht":

```bash
nano scripts/function/Modules/RetryHelper/RetryHelper.psm1
```

```powershell
# RetryHelper.psm1
#
# Kapselt Retry-mit-Exponential-Backoff für einzelne Azure-API-Aufrufe.
# Grund: ohne das bricht bei kurzem Azure-Throttling (HTTP 429) oder
# Netzwerk-Jitter sofort der gesamte Queue-Job ab, statt nur den einen
# Call zu wiederholen. Der Job landet dann zwar über die Queue-Visibility
# erneut in Bearbeitung, aber komplett von vorn - das ist teurer und
# langsamer als ein gezielter Retry auf API-Ebene.

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Führt einen ScriptBlock mit Exponential-Backoff-Retry aus.
    .DESCRIPTION
        Wiederholt den ScriptBlock bei transienten Fehlern (Throttling,
        Timeouts, temporäre Netzwerkfehler). Nicht-transiente Fehler
        (z. B. Berechtigungsfehler, ungültige Parameter) werden sofort
        weitergereicht, da ein Retry dort nichts bringt.
    .PARAMETER ScriptBlock
        Der auszuführende Code, z. B. { Get-AzNatGateway ... }.
    .PARAMETER MaxAttempts
        Maximale Anzahl Versuche (Default: 4).
    .PARAMETER InitialDelaySeconds
        Wartezeit vor dem ersten Retry in Sekunden (Default: 2). Verdoppelt
        sich bei jedem weiteren Versuch (2s, 4s, 8s, ...).
    .PARAMETER OperationName
        Name für Log-Ausgaben, z. B. 'Get-AzNatGateway'.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 4,
        [int]$InitialDelaySeconds = 2,
        [string]$OperationName = 'Azure-Aufruf'
    )

    $attempt = 0
    $delay = $InitialDelaySeconds

    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            $isTransient = Test-TransientAzureError -ErrorRecord $_

            if (-not $isTransient -or $attempt -ge $MaxAttempts) {
                Write-Host "$OperationName fehlgeschlagen (Versuch $attempt/$MaxAttempts, transient=$isTransient): $($_.Exception.Message)"
                throw
            }

            Write-Host "$OperationName transient fehlgeschlagen (Versuch $attempt/$MaxAttempts), erneuter Versuch in $delay s: $($_.Exception.Message)"
            Start-Sleep -Seconds $delay
            $delay = $delay * 2
        }
    }
}

function Test-TransientAzureError {
    <#
    .SYNOPSIS
        Beurteilt, ob ein Fehler wahrscheinlich transient ist (Retry lohnt sich)
        oder dauerhaft (z. B. Berechtigung, ungültiger Parameter - Retry hilft nicht).
    #>
    param(
        [Parameter(Mandatory)]$ErrorRecord
    )

    $message = $ErrorRecord.Exception.Message
    $statusCode = $null

    if ($ErrorRecord.Exception.PSObject.Properties.Match('Response').Count -gt 0 -and $ErrorRecord.Exception.Response) {
        $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode
    }

    # Bekannte transiente HTTP-Statuscodes: 429 (Throttling), 408 (Timeout),
    # 5xx (serverseitige Fehler).
    if ($statusCode -and ($statusCode -eq 429 -or $statusCode -eq 408 -or $statusCode -ge 500)) {
        return $true
    }

    # Fallback über Textmuster, falls kein strukturierter StatusCode verfügbar ist
    # (bei Az-Cmdlets nicht immer garantiert).
    $transientPatterns = @(
        'too many requests',
        'throttl',
        'timeout',
        'timed out',
        'temporarily unavailable',
        'service unavailable',
        'connection was closed',
        'connection reset'
    )

    foreach ($pattern in $transientPatterns) {
        if ($message -imatch [regex]::Escape($pattern)) {
            return $true
        }
    }

    return $false
}

function Test-AzResourceNotFoundError {
    <#
    .SYNOPSIS
        Erkennt, ob ein Fehler bedeutet "Ressource existiert nicht" (kein
        echter Fehler, sondern ein erwarteter Zustand) - im Gegensatz zu
        einem echten Problem wie Throttling oder Berechtigungsfehler.
    #>
    param(
        [Parameter(Mandatory)]$ErrorRecord
    )

    $statusCode = $null
    if ($ErrorRecord.Exception.PSObject.Properties.Match('Response').Count -gt 0 -and $ErrorRecord.Exception.Response) {
        $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode
    }
    if ($statusCode -eq 404) { return $true }

    $errorCode = $null
    if ($ErrorRecord.Exception.PSObject.Properties.Match('Body').Count -gt 0 -and $ErrorRecord.Exception.Body) {
        $errorCode = $ErrorRecord.Exception.Body.Code
    }
    if ($errorCode -in @('ResourceNotFound', 'NotFound', 'PublicIPAddressNotFound', 'NatGatewayNotFound')) { return $true }

    return ($ErrorRecord.Exception.Message -imatch 'was not found|could not be found|does not exist|ResourceNotFound')
}

function Get-AzResourceOrNull {
    <#
    .SYNOPSIS
        Führt einen Az-Lookup mit Retry aus. Gibt $null zurück, wenn die
        Ressource nicht existiert (erwarteter Fall). Alle anderen Fehler
        (Throttling, Auth, Netzwerk) werden per Retry behandelt bzw. am
        Ende weitergereicht - sie werden NICHT als "nicht gefunden" verschluckt.
    .PARAMETER ScriptBlock
        Muss -ErrorAction Stop im enthaltenen Cmdlet-Aufruf verwenden (oder
        global gesetzt sein), damit "nicht gefunden" als Exception ankommt.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$OperationName = 'Azure-Lookup'
    )

    try {
        return Invoke-WithRetry -OperationName $OperationName -ScriptBlock $ScriptBlock
    }
    catch {
        if (Test-AzResourceNotFoundError -ErrorRecord $_) {
            return $null
        }
        throw
    }
}

Export-ModuleMember -Function Invoke-WithRetry, Test-TransientAzureError, Get-AzResourceOrNull, Test-AzResourceNotFoundError
```

> **Warum nicht-transiente Fehler sofort weitergereicht werden:** `Invoke-WithRetry` wiederholt ausschließlich Fehler, die `Test-TransientAzureError` als transient erkennt (HTTP 429/408/5xx oder bekannte Netzwerk-/Timeout-Textmuster). Ein Berechtigungsfehler (z. B. fehlende RBAC-Action aus Abschnitt 6) oder ein ungültiger Parameter würde durch Wiederholen nicht behoben — ein Retry darauf würde den Fehler nur verzögert und mit unnötigen Wartezeiten erneut auftreten lassen, statt ihn schnell sichtbar zu machen.

## 8. Function App Umgebungsvariablen (App Settings) setzen

```bash
az functionapp config appsettings set \
  --name func-<project>-<environment> \
  --resource-group rg-<project>-<environment>-<region> \
  --settings \
    TOGGLEWEBINTERNET_RESOURCE_GROUP=rg-<project>-<environment>-<region> \
    TOGGLEWEBINTERNET_VNET_NAME=vnet-<project> \
    TOGGLEWEBINTERNET_SUBNET_NAME=snet-web \
    TOGGLEWEBINTERNET_NAT_GATEWAY_NAME=nat-<project> \
    TOGGLEWEBINTERNET_PUBLIC_IP_NAME=pip-<project>-nat \
    TOGGLEWEBINTERNET_LOCATION=<azure-region>
```

## 9. Function App deployen

Aus dem Function-Root bauen. Wichtig ist, dass die Function-Verzeichnisse und Root-Dateien direkt im ZIP liegen; es darf keinen zusätzlichen Wrapper-Ordner geben.

```bash
cd scripts/function
rm -f deploy.zip
zip -r deploy.zip \
  GetToggleWebInternetStatus \
  Modules \
  ToggleWebInternet \
  ToggleWebInternetWorker \
  host.json \
  profile.ps1 \
  requirements.psd1
```

Prüfen, bevor deployed wird:

```bash
unzip -l deploy.zip
unzip -p deploy.zip ToggleWebInternet/function.json
```

Die Prüfung muss zeigen, dass `ToggleWebInternet/function.json` ein Queue-Output-Binding mit `name: "QueueMessage"`, `queueName: "toggle-requests"` und `connection: "AzureWebJobsStorage"` enthält.

Dann deployen:

```bash
az functionapp deployment source config-zip \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --src deploy.zip
```

## 10. Locking-Pflichtverhalten

* Lock erfolgreich erworben → Worker-Lauf darf die Netzwerkänderung durchführen
* Lock bereits belegt → Worker wirft `LOCK_BEREITS_BELEGT`; Azure Queues stellt die Nachricht automatisch erneut zu (bis `maxDequeueCount`, kein eigener Retry-Code nötig)
* Auf dem letzten erlaubten Versuch wird der Status explizit auf `Failed` gesetzt, statt die Nachricht stillschweigend in die Poison-Queue wandern zu lassen
* Lock wird immer im `finally`-Block des Workers per `Exit-Lock` freigegeben, auch bei Fehlern oder Timeout

Damit werden konkurrierende Toggles und inkonsistente Zwischenzustände verhindert, ohne dass ein Deadlock entstehen kann.

---

## 11. Erweiterte Betriebslogik für Teilfehler

### 11.1 Grundsatz

Der Toggle darf nie nur den Zustand „angeschaltet" oder „abgeschaltet" melden. Er muss zusätzlich aussagen, ob die **Ressourcenlage** korrekt ist. In der asynchronen Fassung gilt das für den `status`-Wert, den `GetToggleWebInternetStatus` zurückgibt — ein `202 Accepted` vom HTTP-Starter bedeutet ausschließlich „Auftrag angenommen", niemals „abgeschlossen".

### 11.2 Fehler beim Einschalten

Wenn beim Einschalten Public IP und NAT Gateway angelegt wurden, aber die Subnetz-Zuordnung scheitert:

1. das Subnetz wird wieder entkoppelt, falls eine Teilzuordnung existiert
2. das NAT Gateway wird gelöscht
3. die Public IP wird gelöscht
4. erst dann setzt der Worker den Status auf `Failed`

Dadurch bleibt kein kostenpflichtiger Zustand zurück.

### 11.3 Fehler beim Ausschalten

Wenn beim Ausschalten die Entkopplung vom Subnetz erfolgreich war, aber das Löschen von NAT Gateway oder Public IP fehlschlägt:

1. die Entkopplung bleibt bestehen
2. der Worker setzt den Status nicht auf `Succeeded`, sondern auf `CleanupPending`
3. ein erneuter `Off`-Aufruf über `ToggleWebInternet` kann die Bereinigung abschließen
4. die Web-VM bleibt in jedem Fall isoliert, auch wenn Cleanup noch offen ist

### 11.4 Idempotente Wiederholung

Jeder dieser Zustände ist ohne Schaden erneut bearbeitbar:

* `On` erneut ausführen, wenn bereits `On` gesetzt ist
* `Off` erneut ausführen, wenn bereits `Off` gesetzt ist
* Cleanup erneut ausführen, wenn Delete-Schritte zuvor fehlgeschlagen sind

Für den Worker kommt eine weitere Ebene hinzu: Azure Queues stellen eine Nachricht bei einem unbehandelten Fehler automatisch erneut zu (`host.json` → `maxDequeueCount`). Jeder dieser automatischen Wiederholungsversuche muss denselben Auftrag (`operationId`, `state`) unverändert und ohne Doppelwirkung verarbeiten können — das ist bereits dadurch sichergestellt, dass `Initialize-*`/`Add-*`/`Remove-*` immer zuerst den Ist-Zustand prüfen, bevor sie handeln. Dabei ist wichtig, dass „Ist-Zustand prüfen" zuverlässig zwischen „Ressource existiert nicht" und „Abfrage ist gerade transient fehlgeschlagen" unterscheidet — sonst könnte ein automatischer Wiederholungsversuch nach einem kurzen Throttling fälschlich eine zweite, redundante Ressource anlegen. Genau das leistet `Get-AzResourceOrNull` aus `Modules/RetryHelper`.

## 12. Verifikation

Die Verifikationsschritte aus `04_function_app_managed_identity_nat_gateway.md`, Abschnitt 10.1 bis 10.4 gelten inhaltlich weiter, laufen jetzt aber asynchron: Ein Toggle-Aufruf liefert nur noch `202 Accepted` mit einer `operationId`, nicht mehr das Endergebnis. Der Fortschritt wird über `GetToggleWebInternetStatus` abgefragt.

### 12.1 Function Keys abrufen

Es gibt jetzt zwei aufrufbare HTTP-Functions mit je eigenem Key:

```bash
az functionapp function keys list \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --function-name ToggleWebInternet \
  --query default \
  --output tsv

az functionapp function keys list \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --function-name GetToggleWebInternetStatus \
  --query default \
  --output tsv
```

> **Bekannter Bug in manchen `az`-CLI-Versionen: leere Ausgabe trotz vorhandenem Key.** Der Befehl kann in der Praxis kommentarlos leer zurückkommen, obwohl der Key tatsächlich existiert. Ursache (mit `--debug` nachvollziehbar): Die REST-API liefert für diesen Endpunkt ein flaches `{"default": "<key>"}`-Objekt zurück, aber die Deserialisierungslogik dieses CLI-Befehls erwartet ein ARM-typisches Objekt mit `id`/`name`/`type`/`properties` — die Werte landen dadurch intern auf `null`, und `--query default` findet dann nichts. Zwei zuverlässige Alternativen, falls das auftritt:
>
> **a) Direkt über die REST-API (`az rest`), unverändert dieselbe offizielle Azure-API, nur ohne den fehlerhaften Wrapper:**
>
> ```bash
> az rest --method post \
>   --uri "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/rg-<project>-<environment>-<region>/providers/Microsoft.Web/sites/func-<project>-<environment>/functions/ToggleWebInternet/listkeys?api-version=2022-03-01"
> ```
>
> (Für `GetToggleWebInternetStatus` am Ende der URL entsprechend austauschen.)
>
> **b) Im Azure Portal:** Function App → *Functions* → betreffende Function (z. B. `ToggleWebInternet`) → *Function Keys* → *Show value*. Nicht zu verwechseln mit *App keys* im linken Menü der Function App — das sind Host-Keys, nicht die Keys der einzelnen Function.

### 12.2 Toggle On anstoßen und Status pollen

```bash
curl -X POST \
  "https://<function-hostname>/api/ToggleWebInternet?code=<function-key-toggle>" \
  -H "Content-Type: application/json" \
  -d '{"State":"On"}'
```

Erwartete Antwort: `202 Accepted` mit `operationId`. Status pollen, bis `Succeeded`:

```bash
curl -s "https://<function-hostname>/api/GetToggleWebInternetStatus?operationId=<operationId>&code=<function-key-status>"
```

**Äquivalent in PowerShell**  — `Invoke-RestMethod` parst den JSON-Body automatisch zu einem Objekt:

```powershell
$toggleResponse = Invoke-RestMethod -Method Post `
  -Uri "https://<function-hostname>/api/ToggleWebInternet?code=<function-key-toggle>" `
  -ContentType "application/json" `
  -Body '{"State":"On"}'

$toggleResponse

$operationId = $toggleResponse.operationId

Invoke-RestMethod -Method Get -Uri "https://<function-hostname>/api/GetToggleWebInternetStatus?operationId=$operationId&code=<function-key-status>"
```

Den letzten Befehl wiederholen, bis `status: Succeeded` erscheint.


### 12.3 NAT Gateway-Zuordnung prüfen

Erst nachdem der Status `Succeeded` meldet:

```bash
az network vnet subnet show \
  --resource-group rg-<project>-<environment>-<region> \
  --vnet-name vnet-<project> \
  --name snet-web \
  --query "natGateway.id" \
  --output tsv
```

> **Timing beim tatsächlichen Verbindungstest beachten:** `status: Succeeded` bestätigt, dass die ARM-Operation (Subnetz-Zuordnung) abgeschlossen ist — das Routing über das NAT Gateway kann in der Praxis noch einige Sekunden länger brauchen, bis es tatsächlich wirksam ist. Ein `sudo apt update` oder `curl https://api.ipify.org` auf der Web-VM unmittelbar nach `Succeeded` kann daher fälschlich wie ein Fehler aussehen. Vor einer echten Fehlersuche (NSG-Regeln, Routing-Tabellen) einfach 10–20 Sekunden warten und erneut testen.


### 12.4 Toggle Off anstoßen und auf vollständige Bereinigung prüfen

> **Wichtig:** Erst Wartungsarbeiten vollständig abschließen, dann Toggle Off anstoßen. Toggle Off löscht die Public IP; aktive Verbindungen, die dieser IP zugeordnet sind, werden dabei hart beendet statt sauber auszulaufen.

```bash
curl -X POST \
  "https://<function-hostname>/api/ToggleWebInternet?code=<function-key-toggle>" \
  -H "Content-Type: application/json" \
  -d '{"State":"Off"}'
```

**Äquivalent in PowerShell:**

```powershell
$toggleResponse = Invoke-RestMethod -Method Post `
  -Uri "https://<function-hostname>/api/ToggleWebInternet?code=<function-key-toggle>" `
  -ContentType "application/json" `
  -Body '{"State":"Off"}'

$operationId = $toggleResponse.operationId

Invoke-RestMethod -Method Get -Uri "https://<function-hostname>/api/GetToggleWebInternetStatus?operationId=$operationId&code=<function-key-status>"
```

Status pollen, bis `Succeeded` (nicht `CleanupPending`, siehe Abschnitt 7.3). Zuordnung prüfen (muss leer sein):

```bash
az network vnet subnet show \
  --resource-group rg-<project>-<environment>-<region> \
  --vnet-name vnet-<project> \
  --name snet-web \
  --query "natGateway.id" \
  --output tsv
```

Ressourcen-Existenz prüfen (beide müssen mit `ResourceNotFound` fehlschlagen):

```bash
az network nat gateway show \
  --resource-group rg-<project>-<environment>-<region> \
  --name nat-<project>

az network public-ip show \
  --resource-group rg-<project>-<environment>-<region> \
  --name pip-<project>-nat
```

## 13. Typische Fehlerbilder

| Fehlerbild                                                                                                              | Mögliche Ursache                                                                                                                                                         | Lösung                                                                                                                                                                                     |
| ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Status bleibt dauerhaft auf `Queued`, `az functionapp function list` zeigt den Worker trotzdem an                       | `host.json` fehlt `extensionBundle` — Queue-Trigger-Listener wird für PowerShell-Runtimes ohne Bundle nie registriert                                                    | `extensionBundle`-Eintrag in `host.json` ergänzen (Abschnitt 7.1), neu deployen                                                                                                            |
| `FEHLER: The term 'New-AzStorageContext' is not recognized...` trotz korrekter `requirements.psd1`                      | `managedDependency.enabled: true` fehlt in `host.json` — Modulinstallation läuft nicht zuverlässig                                                                       | Eintrag ergänzen (Abschnitt 7.1), Function App neu starten, 1–2 Minuten für Kaltstart einplanen                                                                                            |
| `Conversion from JSON failed... Unexpected character encountered while parsing value: S.` im Worker-Log                 | `$QueueItem` kommt als `System.Byte[]` statt als String an; `[string]`-Cast allein löst es nicht (liefert den Typnamen `"System.Byte[]"` als Text)                       | `dataType: "string"` im Queue-Trigger-Binding setzen **und** robuste Typprüfung in `run.ps1` verwenden (Abschnitt 7.5)                                                                     |
| Status bleibt dauerhaft auf `Queued`, obwohl Trigger-Fehler behoben wurden                                              | Bereits vor dem Fix in die Queue gelangte Nachrichten sind oft schon in der Poison-Queue (`toggle-requests-poison`) gelandet und werden nicht automatisch nachbearbeitet | Alte, fehlgeschlagene Nachrichten ignorieren; nur mit einem frischen `ToggleWebInternet`-Aufruf und neuer `operationId` erneut testen                                                      |
| `sudo apt update` / `curl https://api.ipify.org` schlägt direkt nach `status: Succeeded` fehl                           | Routing über das NAT Gateway ist zum Zeitpunkt des Tests noch nicht vollständig propagiert                                                                               | 10–20 Sekunden warten, erneut testen, bevor NSG/Routing-Konfiguration in Frage gestellt wird (Abschnitt 12.3)                                                                               |
| Status bleibt dauerhaft auf `Queued`                                                                                    | `ToggleWebInternetWorker` läuft nicht an — Queue-Trigger-Binding falsch konfiguriert oder nicht deployt                                                                  | `function.json` des Workers und Verzeichnisstruktur aus Abschnitt 6 gegenprüfen                                                                                                            |
| Status bleibt lange auf `Running`, dann `Failed: Lock war dauerhaft belegt; Auftrag nach mehreren Versuchen verworfen.` | Ein anderer Worker-Lauf hielt die Lease über alle `maxDequeueCount`-Versuche hinweg (host.json, Abschnitt 7.1)                                                           | Log-Stream des blockierenden Laufs prüfen; Vorgang erneut über `ToggleWebInternet` anstoßen                                                                                                |
| Status `Failed: Lock-Erneuerung fehlgeschlagen...`                                                                      | Ein anderer Prozess hat die Lease übernommen oder gebrochen, während der Worker noch lief                                                                                | Log-Stream prüfen; Vorgang über `ToggleWebInternet` erneut anstoßen                                                                                                                        |
| Lock scheint kurzzeitig weiter belegt, obwohl der vorherige Lauf abgestürzt ist                                         | Die kurze Lease (60s) ist noch nicht abgelaufen                                                                                                                          | Bis zu 60 Sekunden warten — heilt sich von selbst. Nur falls danach weiterhin blockiert: `az storage blob lease break --container-name locks --blob-name togglewebinternet.lock` ausführen |
| `FEHLER: Timeout beim Warten auf den gewünschten Subnetz-Zustand.` (im Status als `Failed`)                             | Zuordnung/Entkopplung ist innerhalb der Wartezeit nicht angekommen                                                                                                       | RBAC-Rolle aus Abschnitt 6 prüfen; ggf. Timeout in `Wait-SubnetNatState` (Abschnitt 7.6) erhöhen                                                                                           |
| Status `CleanupPending` nach Toggle Off                                                                                 | Löschen von NAT Gateway oder Public IP ist fehlgeschlagen                                                                                                                | `Off` erneut aufrufen — die Function ist idempotent (§7.4); Ressourcenstatus vorher mit §12.4 prüfen                                                                                        |
| `GetToggleWebInternetStatus` liefert `404 Not Found`                                                                    | `operationId` falsch übertragen, oder der Auftrag wurde nie erfolgreich über `ToggleWebInternet` angenommen                                                              | `operationId` aus der `202`-Antwort exakt übernehmen                                                                                                                                       |
| `FEHLER: AzureWebJobsStorage ist nicht verfügbar.`                                                                      | App-Setting fehlt oder wurde entfernt                                                                                                                                    | In den Function-App-Einstellungen prüfen, dass `AzureWebJobsStorage` gesetzt ist                                                                                                           |
| Nach dem Update: `natGateway.id` zeigt weiterhin auf eine alte NAT-Gateway-Ressource                                    | Abschnitt 4.3 wurde übersprungen oder zu früh ausgeführt                                                                                                                 | Erst `Off` und leere Zuordnung verifizieren (§4.1), dann Ressourcen manuell löschen                                                                                                        |
| `App Setting 'TOGGLEWEBINTERNET_...' ist nicht gesetzt.` (im Status als `Failed`, direkt beim ersten Worker-Aufruf)     | Die sechs `TOGGLEWEBINTERNET_*`-App-Settings (Abschnitt 9) wurden nach dem Deployment nicht oder unvollständig gesetzt                                                | `az functionapp config appsettings list` gegenprüfen; alle sechs Werte aus Abschnitt 9 setzen, 1–2 Minuten Kaltstart abwarten                                                            |
| `az functionapp function keys list` liefert eine leere Zeile, obwohl der Key laut Portal existiert                     | Bekannter CLI-Parsing-Bug: Die API liefert ein flaches `{"default": "..."}`-Objekt, der Befehl erwartet intern ein ARM-Objekt mit `id`/`name`/`properties` (Abschnitt 12.1) | `az rest` gegen den `listkeys`-Endpunkt direkt aufrufen, oder den Key im Portal unter *Functions → \<Name\> → Function Keys* ablesen; optional `az upgrade`                               |

Die Fehlerbilder aus `04_function_app_managed_identity_nat_gateway.md`, Abschnitt 11 (fehlender Function Key, falscher `State`-Wert, `404` bei falscher Zip-Struktur) gelten unverändert weiter.

## 14. Wartungsablauf 

Ersetzt die Checkliste aus `04_function_app_managed_identity_nat_gateway.md`, Abschnitt 12, vollständig.

```
[ ] 1. Toggle On anstoßen:  POST .../ToggleWebInternet?code=<function-key-toggle>  Body: {"State":"On"}
[ ] 2. operationId aus der 202-Antwort notieren
[ ] 3. Status pollen, bis Succeeded (§12.2) – mit `GetToggleWebInternetStatus?operationId=<operationId>&code=<function-key-status>`
[ ] 4. Zuordnung prüfen (§12.3)
[ ] 5. Internetzugang auf der Web-VM testen (curl https://api.ipify.org)
[ ] 6. Wartungsarbeiten durchführen (apt update, apt upgrade, …) — vollständig abwarten
[ ] 7. Toggle Off anstoßen:  POST .../ToggleWebInternet?code=<function-key-toggle>  Body: {"State":"Off"}
[ ] 8. Status pollen, bis Succeeded (nicht CleanupPending, §12.4) – mit `GetToggleWebInternetStatus?operationId=<operationId>&code=<function-key-status>`
[ ] 9. Zuordnung prüfen: NAT Gateway nicht mehr an snet-web gebunden
[ ] 10. NAT Gateway existiert nicht mehr (§12.4)
[ ] 11. Public IP existiert nicht mehr (§12.4)
[ ] 12. curl https://api.ipify.org auf der Web-VM → muss mit Timeout oder Verbindungsfehler abbrechen
```

> **Wichtig:** Schritt 6 muss vollständig abgeschlossen sein, bevor Schritt 7 angestoßen wird — Toggle Off löscht die Public IP, aktive Verbindungen dazu werden hart beendet. Wird Schritt 7 übersprungen, bleibt die Web-VM weiterhin mit dem Internet verbunden. Werden Schritt 10 oder 11 übersprungen bzw. schlägt das Cleanup fehl (`CleanupPending` in Schritt 8), bleiben kostenpflichtige Ressourcen bestehen, auch wenn die Netzwerkisolation selbst bereits wiederhergestellt ist. Der tatsächliche Kostenstopp tritt erst ein, wenn NAT Gateway **und** Public IP wirklich gelöscht sind — beides erst nach `status: Succeeded` in Schritt 8 verlässlich geprüft.

## 15. Ergebnis

Nach Abschluss dieses Kapitels gilt zusätzlich zu `04_function_app_managed_identity_nat_gateway.md`:

* NAT Gateway und Public IP existieren nur noch während des Wartungsfensters und verursachen außerhalb davon keine Kosten.
* Kein HTTP-Aufruf wartet mehr synchron auf eine Ressourcenoperation: `ToggleWebInternet` nimmt nur an, `ToggleWebInternetWorker` führt aus, `GetToggleWebInternetStatus` meldet den Fortschritt — der Toggle bleibt damit unabhängig vom 230-Sekunden-Limit für HTTP-Trigger.
* Parallele Toggle-Läufe sind durch eine kurze, automatisch erneuerte Blob-Lease im Worker ausgeschlossen; ein blockierter Lauf wird über den automatischen Queue-Retry serialisiert, und ein abgestürzter Lauf heilt sich innerhalb von Sekunden selbst, statt dauerhaft hängen zu bleiben.
* Teilfehler werden nicht als Erfolg gemeldet — weder synchron noch über den Status-Endpunkt. Fehler beim Einschalten lösen einen automatischen Rollback aus, Fehler beim Ausschalten führen zu einem expliziten `CleanupPending`-Status.
* Jeder Zustand (On, Off, Cleanup) ist idempotent wiederholbar, auch über die automatischen Zustellversuche der Queue hinweg.
* Ressourcennamen (Resource Group, VNet, Subnet, NAT Gateway, Public IP, Region) sind über App Settings parametrisiert statt im Code verdrahtet (Abschnitt 9) — dieselbe Function App kann so unverändert in mehreren Umgebungen laufen.
* Status- und Storage-Logik liegt einmalig in `Modules/StatusStore`, Retry-Logik einmalig in `Modules/RetryHelper` (Abschnitt 7.9)
* Transiente Azure-API-Fehler (Throttling, Timeouts) werden per Exponential Backoff wiederholt, statt den ganzen Worker-Lauf abzubrechen oder eine Ressource fälschlich als „existiert nicht" zu behandeln.
* Alle Funktionsnamen im Worker sind PSScriptAnalyzer-konform (`PSUseApprovedVerbs`)
* Kapitel 04 bleibt als Grundlage bestehen, auf der Managed Identity, RBAC-Modell und die Trennung von Authentifizierung und Autorisierung eingeführt wurden; die Umgebung selbst läuft nach diesem Kapitel verbindlich auf dem hier beschriebenen Code.
