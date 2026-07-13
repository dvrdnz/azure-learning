# 04 – Temporärer Internetzugang für die Web-VM: Function App, Managed Identity und NAT Gateway

> **Voraussetzung:**
>
> * [01 – Virtual Network und Network Security Groups (NSG)](https://github.com/dvrdnz/azure-learning/blob/main/docs/01-dmz-private-workload-architecture/01_vnet_and_nsg.md)
> * [02 – Compute-Deployment: Edge-VM und Web-VM](https://github.com/dvrdnz/azure-learning/blob/main/docs/01-dmz-private-workload-architecture/02_compute_deployment.md)
> * [03 – OS-Hardening: SSH, fail2ban, UFW](https://github.com/dvrdnz/azure-learning/blob/main/docs/01-dmz-private-workload-architecture/03_os_hardening.md)
>
> **Beispielkonfiguration**
>
> * Subscription: `<subscription>`
> * Region: `<azure-region>`
> * Resource Group: `rg-<project>-<environment>-<region>`

## 1. Lernziele

* das Prinzip eines **temporären Ausnahmezustands** in einer ansonsten strikt isolierten Netzarchitektur verstehen
* ein **NAT Gateway** als ausgehenden Internetpfad einsetzen, ohne der Web-VM eine Public IP zuzuweisen
* die Steuerung einer Infrastrukturänderung über **Function App** und **Managed Identity** nachvollziehen
* den Unterschied zwischen **Authentifizierung** und **Autorisierung** sauber trennen
* eine **Custom Role** nach dem Prinzip der **Least Privilege** definieren und zuweisen
* verifizieren, dass ein temporär aktivierter Zustand nach der Wartung zuverlässig wieder zurückgesetzt wird

## 2. Voraussetzungen aus den Kapiteln 01 bis 03 prüfen

| Ressource       | Erwarteter Name       | Prüfung                                |
| --------------- | --------------------- | -------------------------------------- |
| Virtual Network | `vnet-<project>`      | vorhanden                              |
| Subnetz Web     | `snet-web`            | vorhanden, kein NAT Gateway zugeordnet |
| NSG Web         | `nsg-<project>-web`   | vorhanden, mit `snet-web` verknüpft    |
| Web-VM          | `vm-<project>-web-01` | vorhanden, läuft, keine Public IP      |

---

## 3. Zielbild
 
Die Web-VM besitzt **im Normalbetrieb keinen ausgehenden Internetzugang**. Weder eine Public IP noch ein NAT Gateway sind dauerhaft an das Subnetz `snet-web` gebunden. Das ist beabsichtigt: Die VM soll ausschließlich über die Edge-VM erreichbar bleiben und im Regelbetrieb nicht direkt nach außen kommunizieren.

Für Wartungsaufgaben wie `apt update` oder Paketinstallationen wird jedoch gelegentlich ausgehender Internetzugang benötigt. Eine dauerhafte Freigabe würde die gewünschte Netzwerkisolation aufheben.

Die Lösung ist ein **NAT Gateway**, das per HTTP-Aufruf temporär an `snet-web` zugeordnet oder wieder davon gelöst wird. Die Steuerung erfolgt über eine **Azure Function App**, die mit **Managed Identity** und einer **minimalen Custom Role** arbeitet.

 
```text
Admin-Rechner
     |
     | POST /api/ToggleWebInternet?code=<function-key>
     | Body: {"State":"On"} oder {"State":"Off"}
     v
[Function App] --- Managed Identity (RBAC: NAT Gateway Toggle Operator)
     |
     | Set-AzVirtualNetwork: NAT Gateway an snet-web zuordnen / lösen
     v
[snet-web] --- NAT Gateway (nur während Wartung aktiv)
     |
     v
Internet (ausgehend, nur für die Web-VM)
```
 
> **Hinweis zur Umsetzung:** Azure stellt keine separate API bereit, um ein NAT Gateway direkt „anzuhängen“. Die Zuordnung ist eine Eigenschaft des Subnetzes (`subnet.NatGateway`) und wird technisch über das VNet-Objekt aktualisiert (`Get-AzVirtualNetwork` → Eigenschaft ändern → `Set-AzVirtualNetwork`). Das hat unmittelbare RBAC-Konsequenzen, siehe Abschnitt 5.

**Wichtig:** Das NAT Gateway selbst existiert **dauerhaft**. Es wird bei „Wartung beendet“ nicht gelöscht, sondern lediglich vom Subnetz gelöst. Geschaltet wird ausschließlich die **Zuordnung zum Subnetz** (`State=On` / `State=Off`). Der Zustand „On“ ist also ausdrücklich nur temporär gemeint.


## 4. Neue Ressourcen anlegen

### 4.1 Ressourcenübersicht

| Ressource                       | Name                           | Zweck                                                |
| ------------------------------- | ------------------------------ | ---------------------------------------------------- |
| Public IP Resource (für NAT GW) | `pip-<project>-nat`            | Öffentliche IP-Adresse für das NAT Gateway           |
| NAT Gateway                     | `nat-<project>`                | Ausgehender Internetzugang für `snet-web` (temporär) |
| Storage Account                 | `st<project><environment>`     | Pflichtressource der Function App                    |
| Function App                    | `func-<project>-<environment>` | HTTP-Trigger für den NAT-Gateway-Toggle              |

### 4.2 Public IP für das NAT Gateway

Im Azure Portal: **Create a resource → Public IP address**

* **SKU:** Standard
* **Tier:** Regional
* **IP Version:** IPv4
* **Assignment:** Static
* **Availability zone:** Zone-redundant
* **Routing preference:** Microsoft Network
* **DDoS Protection:** **Disabled**
* **Name:** `pip-<project>-nat`
* **Resource Group:** vorhandene `rg-<project>-<environment>-<region>` auswählen
* **Region:** `<azure-region>`

Oder per CLI:

```bash
az network public-ip create \
  --resource-group rg-<project>-<environment>-<region> \
  --name pip-<project>-nat \
  --sku Standard \
  --tier Regional \
  --allocation-method Static \
  --zone 1 2 3 \
  --ddos-protection-mode Disabled \
  --location <azure-region>
```

### 4.3 NAT Gateway

Im Azure Portal: **Create a resource → NAT gateway**

**Tab „Basics“:**

* **Name:** `nat-<project>`
* **Resource Group:** vorhandene `rg-<project>-<environment>-<region>`
* **Region:** `<azure-region>`
* **SKU:** Standard

**Tab „Outbound IP“:**

* **Public IP addresses:** `pip-<project>-nat` (oben angelegt) — über „Add public IP addresses or prefixes“ auswählen

**Tab „Networking":**

* **Virtual network:** `None` lassen
* **Subnets:** `None` lassen

> **Hinweis:** Die Subnetz-Zuordnung erfolgt **nicht** im Tab „Outbound IP“; dort werden nur die IP-Adressen des Gateways selbst definiert. Die tatsächliche Zuordnung geschieht separat und hier bewusst nicht manuell im Portal, sondern über die Function App (Abschnitt 7/8).

Oder per CLI:

```bash
az network nat gateway create \
  --resource-group rg-<project>-<environment>-<region> \
  --name nat-<project> \
  --public-ip-addresses pip-<project>-nat \
  --location <azure-region>
```

> **Hinweis:** Der CLI-Befehl kennt ohnehin kein Subnetz-Argument. Eine Zuordnung würde separat über `az network vnet subnet update --nat-gateway` erfolgen, was hier bewusst nicht ausgeführt wird.

> **Hinweis:** Das NAT Gateway ist nach der Erstellung vorhanden, aber noch nicht für `snet-web` aktiv. Die Web-VM hat weiterhin keinen Internetzugang.

## 5. RBAC Custom Role anlegen

Die Function App benötigt die Berechtigung, das NAT Gateway am Web-Subnetz zuzuordnen oder zu lösen.

Azure prüft bei dieser Änderung nicht nur das Subnetz selbst, sondern auch die verknüpften Netzwerkobjekte. Ein Schreibvorgang auf dem VNet kann daher mit `LinkedAuthorizationFailed` fehlschlagen, wenn für referenzierte Ressourcen die erforderlichen Rechte fehlen. Deshalb enthält die Custom Role neben den Subnetz-Rechten auch die notwendigen Rechte für die verknüpften Netzwerkressourcen.


### 5.1 Subscription ID ermitteln

Azure Cloud Shell öffnen — eine ephemere Bash-Sitzung genügt.

Die Subscription ID wird für `AssignableScopes` in der Rollendefinition benötigt. Der Scope enthält die volle Resource-ID, in dem die Rolle zuweisbar sein soll.

```bash
az account show --query id -o tsv
```

Den ausgegebenen Wert als `<subscription>` in Abschnitt 5.2 verwenden.

### 5.2 Rollendefinition erstellen


Datei `nat-toggle-role.json` anlegen, zum Beispiel in der Cloud Shell:
 
```json
{
  "Name": "NAT Gateway Toggle Operator",
  "IsCustom": true,
  "Description": "Aktiviert und deaktiviert die NAT-Gateway-Zuordnung auf einem Subnetz im Wartungsmodus.",
  "Actions": [
    "Microsoft.Network/virtualNetworks/read",
    "Microsoft.Network/virtualNetworks/write",
    "Microsoft.Network/virtualNetworks/subnets/read",
    "Microsoft.Network/virtualNetworks/subnets/write",
    "Microsoft.Network/natGateways/read",
    "Microsoft.Network/networkSecurityGroups/join/action"
  ],
  "NotActions": [],
  "AssignableScopes": [
    "/subscriptions/<subscription>/resourceGroups/rg-<project>-<environment>-<region>"
  ]
}
```

### 5.3 Rolle anlegen

```bash
az role definition create --role-definition nat-toggle-role.json
```

Erwartetes Ergebnis: JSON-Ausgabe der neu erstellten Rolle mit `"roleName": "NAT Gateway Toggle Operator"` und sechs Einträgen unter `"actions"`.


## 6. Function App anlegen

### 6.1 Storage Account

Ein Storage Account ist Pflichtbestandteil jeder Function App.

**Portal (Klick-für-Klick):**

1. Azure Portal → Suchleiste → **Storage accounts** → **+ Create**
2. Tab **Basics**:
   * **Resource group:** vorhandene `rg-<project>-<environment>-<region>` auswählen
   * **Storage account name:** `st<project><environment>`
   * **Region:** `<azure-region>`
   * **Primary service:** Azure Blob Storage or Azure Files (Standard bleibt ausgewählt)
   * **Performance:** Standard
   * **Redundancy:** Locally-redundant storage (LRS)
4. Restliche Tabs (Advanced, Networking, Data protection, Encryption, Tags): Standardwerte übernehmen
5. **Review + create** → **Create**

> **Hinweis:** Storage-Account-Namen dürfen nur Kleinbuchstaben und Ziffern enthalten und maximal 24 Zeichen lang sein.

**Oder per CLI:**

```bash
az storage account create \
  --name st<project><environment> \
  --resource-group rg-<project>-<environment>-<region> \
  --location <azure-region> \
  --sku Standard_LRS
```

### 6.2 Function App erstellen

**Portal (Klick-für-Klick):**

1. Azure Portal → Suchleiste → **Function App** → **+ Create**
2. Wahl des Hosting-Optionen-Dialogs: **Consumption** auswählen
3. Tab **Basics**:
   * **Resource group:** vorhandene `rg-<project>-<environment>-<region>`
   * **Function App name:** `func-<project>-<environment>`
   * **Runtime stack:** PowerShell Core
   * **Version:** 7.4
   * **Region:** `<azure-region>`
4. Tab **Storage**:
   * **Storage account:** vorhandenen `st<project><environment>` auswählen, nicht neu anlegen
5. Tab **Hosting**:
   * **Plan type:** Consumption (Serverless)
6. Tab **Monitoring**: 
   * **Enable Application Insights** No (Kann später im Hinblickl auf Abschnitt 8.4 aktiviert werden)
7. Tab **Networking, Tags**: Standardwerte übernehmen
8. **Review + create** → **Create**

> **Managed Identity:** Wird beim Erstellen im Portal nicht separat abgefragt. Sie wird anschließend aktiviert, siehe Abschnitt 6.3.

**Oder per CLI** — aktiviert die Function-Identity direkt mit:

```bash
az functionapp create \
  --resource-group rg-<project>-<environment>-<region> \
  --consumption-plan-location <azure-region> \
  --runtime powershell \
  --runtime-version 7.4 \
  --functions-version 4 \
  --name func-<project>-<environment> \
  --storage-account st<project><environment> \
  --assign-identity [system]
```

---

### 6.3 Managed Identity aktivieren und Principal ID ermitteln

**Portal (Klick-für-Klick)** — nötig, falls die Function App über das Portal erstellt wurde:

1. Function App öffnen → linkes Menü → **Identity** (unter **Settings**)
2. Tab **System assigned** → Status auf **On** setzen → **Save** → Bestätigungsdialog mit **Yes**
3. Nach dem Speichern erscheint die **Object (principal) ID** auf derselben Seite — diesen Wert kopieren

**Oder per CLI** — falls die Identity bereits bei der Erstellung mit `--assign-identity [system]` aktiviert wurde:

```bash
az functionapp identity show \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --query principalId \
  --output tsv
```

Den ausgegebenen bzw. kopierten Wert als `<principal-id>` in Abschnitt 6.4 verwenden.

### 6.4 Custom Role der Managed Identity zuweisen

**Cloud Shell**:

```bash
az role assignment create \
  --assignee <principal-id> \
  --role "NAT Gateway Toggle Operator" \
  --scope /subscriptions/<subscription>/resourceGroups/rg-<project>-<environment>-<region>
```

### 6.5 Tatsächlichen Hostnamen ermitteln

> **Wichtiger Hinweis:** Ist bei der Erstellung „Secure unique default hostname“ aktiv, vergibt Azure nicht die einfache URL `func-<project>-<environment>.azurewebsites.net`, sondern hängt zum Schutz vor Subdomain-Takeover einen zufälligen Suffix an. Alle späteren Aufrufe benötigen den **tatsächlichen Hostnamen**:
 
```bash
az functionapp show \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --query defaultHostName \
  --output tsv
```

Ergebnis hat die Form `func-<project>-<environment>-<zufallssuffix>.<region>-01.azurewebsites.net`. **Den ermittelten Wert als `<function-hostname>` notieren.** Dieser tatsächliche Hostname muss in allen folgenden Aufrufen anstelle des Platzhalters verwendet werden.

## 7. Code deployen

Die Function App erwartet folgende Dateistruktur im Repository:

```
scripts/
└── function/
    ├── requirements.psd1
    └── ToggleWebInternet/
        ├── function.json
        └── run.ps1
```

**Cloud Shell**:

```bash
mkdir -p scripts/function/ToggleWebInternet
cd scripts/function
```

### 7.1 `scripts/function/requirements.psd1`

Es werden nur die tatsächlich benötigten Module eingebunden. Das verkürzt den Kaltstart gegenüber dem vollständigen `Az`-Modul.

```bash
nano requirements.psd1
```

Folgenden Inhalt einfügen:


```powershell
@{
    'Az.Accounts' = '3.*'
    'Az.Network'  = '7.*'
}
```

### 7.2 `scripts/function/ToggleWebInternet/function.json`

```bash
nano ToggleWebInternet/function.json
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
      "type": "http",
      "direction": "out",
      "name": "Response"
    }
  ]
}
```

> **Authentifizierung vs. Autorisierung:** `"authLevel": "function"` stellt sicher, dass der HTTP-Aufruf einen gültigen Function Key mitbringen muss — das ist die **Authentifizierung**. Die **Autorisierung** gegenüber den Azure-Ressourcen läuft davon unabhängig über die Managed Identity und deren RBAC-Rolle aus Abschnitt 5. Ein gültiger Function Key erlaubt also nur den Aufruf, nicht automatisch die Netzwerkänderung.

### 7.3 `scripts/function/ToggleWebInternet/run.ps1`

```bash
nano ToggleWebInternet/run.ps1
```

```powershell
using namespace System.Net
 
param($Request, $TriggerMetadata)
 
$ErrorActionPreference = 'Stop'
 
try {
    Connect-AzAccount -Identity | Out-Null
 
    $ResourceGroupName = 'rg-<project>-<environment>-<region>'
    $VnetName          = 'vnet-<project>'
    $SubnetName        = 'snet-web'
    $NatGatewayName    = 'nat-<project>'
 
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
 
    $vnet   = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName
    $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName
 
    if (-not $subnet) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = "Subnet '$SubnetName' wurde nicht gefunden."
        })
        return
    }
 
    switch ($State) {
        'on' {
            $nat = Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $NatGatewayName
            if ($subnet.NatGateway -and $subnet.NatGateway.Id -eq $nat.Id) {
                $msg = 'Internetzugang war bereits aktiviert.'
            } else {
                $subnet.NatGateway = $nat
                $result = Set-AzVirtualNetwork -VirtualNetwork $vnet
                $msg = "Internetzugang aktiviert. ProvisioningState: $($result.ProvisioningState)"
            }
        }
        'off' {
            if (-not $subnet.NatGateway) {
                $msg = 'Internetzugang war bereits deaktiviert.'
            } else {
                $subnet.NatGateway = $null
                $result = Set-AzVirtualNetwork -VirtualNetwork $vnet
                $msg = "Internetzugang deaktiviert. ProvisioningState: $($result.ProvisioningState)"
            }
        }
    }
 
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = $msg
    })
 
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = "FEHLER: $($_.Exception.Message)"
    })
}
```

> `$ErrorActionPreference = 'Stop'` erzwingt, dass jeder Cmdlet-Fehler als Exception behandelt wird, statt still im Error-Stream zu verschwinden. Der `catch`-Block gibt die vollständige Fehlermeldung direkt im HTTP-Body zurück, einschließlich einer eventuell fehlenden RBAC-Action. `ProvisioningState` im Erfolgsfall bestätigt, dass die ARM-Operation nicht nur angenommen, sondern abgeschlossen wurde.

### 7.4 Function App deployen

Aus dem Repository-Root:

```bash
cd scripts/function
zip -r deploy.zip .
```

Prüfen, bevor deployed wird — der Zip-Inhalt sollte `requirements.psd1` und `ToggleWebInternet/` direkt im Root des Archivs haben, nicht in einem Unterordner:

```bash
unzip -l deploy.zip
```

Dann deployen:


```bash
az functionapp deployment source config-zip \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --src deploy.zip
```

Durch die Nutzung der Azure Cloud Shell ist die CLI bereits per Entra-Token authentifiziert; Basic Auth ist dabei kein Hindernis.


### 7.5 Function Key abrufen

```bash
az functionapp function list \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --query "[].name" \
  --output table
```
Erwartung:

```text
func-<rg>-<env>/ToggleWebInternet
```

```bash
az functionapp function keys list \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --function-name ToggleWebInternet \
  --query default \
  --output tsv
```

> In bestimmten Azure-CLI-Versionen kann dieser Befehl `null` zurückgeben, obwohl der Key serverseitig existiert. Zwei alternative Wege:
>
> **Portal:** Function App → **Functions** → `ToggleWebInternet` → **Function Keys**
>
> **Option 1 — direkt per REST-API aus der Azure Cloud Shell:**

> ```bash
> az rest --method post \
>   --url "https://management.azure.com/subscriptions/<subscription>/resourceGroups/rg-<project>-<environment>-<region>/providers/Microsoft.Web/sites/func-<project>-<environment>/functions/ToggleWebInternet/listkeys?api-version=2023-01-01"
> ```
>
> **Option 2 — im Portal:**
>
> 1. Function App `func-<project>-<environment>` öffnen
> 2. Linkes Menü → **Functions** → `ToggleWebInternet`
> 3. Im Function-Blade → **Function Keys**
> 4. Dort sollte `default` mit dem Wert angezeigt werden — falls nicht vorhanden, direkt dort **+ New function key** anlegen

---

## 8. Access Restrictions und Key Rotation für die Function App

Der NAT-Gateway-Toggle ist ein privilegierter Eingriff in die Netzwerkisolation. Auch wenn er zeitlich begrenzt ist, sollte er mit derselben Sorgfalt behandelt werden wie jede andere Änderung an der Netzwerkgrenze.

### 8.1 Zugriff auf die Toggle-Function begrenzen

Standardmäßig ist der HTTP-Endpunkt der Function App von jeder beliebigen IP-Adresse aus erreichbar. Der Function Key schützt vor unautorisierten Aufrufen, aber nicht davor, dass der Endpunkt selbst von überall angesprochen werden kann, etwa für Brute-Force-Versuche auf den Key. Access Restrictions schränken zusätzlich ein, von welchen IP-Adressen aus die Function App überhaupt erreichbar ist.

### 8.2 Access Restriction im Portal setzen
 
1. Function App öffnen → linkes Menü → **Settings** aufklappen
2. **Networking** auswählen
3. Unter „Inbound traffic configuration" → **Public network access** anklicken (Link neben „Enabled with no access restrictions")
4. Auf der Access-Restrictions-Seite: **Public network access** auf **„Enabled from select virtual networks and IP addresses"** umstellen
5. **Unmatched rule action:** auf **Deny** setzen — das übernimmt die Funktion einer separaten „Deny all"-Regel, ohne dass eine solche extra angelegt werden muss
6. **+ Add** klicken, Regel anlegen:
7. Oben links **Save** klicken

Ergebnis in der Regelliste: eine Zeile `admin-ip` mit Priority 100, Allow, `<admin-ip>/32`; „Unmatched rule action“ zeigt Deny.

Nach dieser Einschränkung funktioniert der Toggle-Aufruf **nur noch von der eingetragenen Admin-IP aus**. Aufrufe aus der Azure Cloud Shell oder von einer Azure-VM aus, etwa der Edge-VM, schlagen danach mit `403 Forbidden` fehl.

### 8.3 Oder per CLI
 
```bash
az functionapp config access-restriction add \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --rule-name admin-ip \
  --action Allow \
  --ip-address <admin-ip>/32 \
  --priority 100
```

**IP-Adresse später aktualisieren:** Es gibt kein separates `update`-Kommando für eine bestehende Regel. Derselbe `add`-Befehl mit demselben `--rule-name`, aber neuer `--ip-address`, überschreibt die bestehende Regel, statt eine zweite anzulegen.

### 8.4 Verifizieren
 
```bash
az functionapp config access-restriction show \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --output table
```

Ein Toggle-Aufruf vom Admin-Rechner funktioniert danach weiterhin wie beschrieben. Ein Aufruf von jeder anderen IP-Adresse — inklusive Cloud Shell und jeder Azure-VM ohne eingetragene IP — wird bereits von Azure selbst mit `403 Forbidden` abgelehnt, bevor die Function überhaupt ausgeführt wird. 

### 8.5 Function Key rotieren
 
Anders als Storage-Account-Keys (`key1`/`key2`) haben Function Keys **keinen eingebauten Zwei-Schlüssel-Mechanismus mit Übergangsfrist**. Wird ein Key erneuert, ist der alte Wert sofort ungültig.

**Rotation mit kurzer Downtime**:
 
```bash
az functionapp function keys set \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --function-name ToggleWebInternet \
  --key-name default
```

Ohne `--key-value` generiert Azure automatisch einen neuen Zufallswert. Der alte Wert funktioniert ab sofort nicht mehr, bis der neue Wert überall aktualisiert ist, wo er verwendet wird.
 
**Rotation ohne Downtime** — Function Apps erlauben mehrere benannte Keys gleichzeitig, das lässt sich für einen Übergang nutzen:
 
1. Neuen Key unter anderem Namen anlegen, der alte bleibt weiter gültig:

```bash
   az functionapp function keys set \
     --resource-group rg-<project>-<environment>-<region> \
     --name func-<project>-<environment> \
     --function-name ToggleWebInternet \
     --key-name default-v2
```

2. Lokale Aufrufe/Skripte auf `code=<neuer-key>` umstellen, testen

3. Erst danach den alten Key löschen:
```bash
   az functionapp function keys delete \
     --resource-group rg-<project>-<environment>-<region> \
     --name func-<project>-<environment> \
     --function-name ToggleWebInternet \
     --key-name default
```

4. Optional den neuen Wert anschließend unter dem kanonischen Namen `default` setzen und `default-v2` wieder löschen, damit die Namenskonvention in dieser Doku konsistent bleibt.

> Die Key-Rotation ist unabhängig von den Access Restrictions aus Abschnitt 8: Die IP-Beschränkung regelt, **von wo** ein Aufruf kommen darf; der Function Key regelt, **mit welchem Geheimnis** der Aufruf autorisiert wird. Beide Mechanismen greifen unabhängig voneinander.

## 9. Weitere Sicherheitsaspekte

Der NAT-Gateway-Toggle ist ein privilegierter Eingriff in die Netzwerkisolation. Auch wenn er zeitlich begrenzt ist, sollte er mit derselben Sorgfalt behandelt werden wie jede andere Änderung an der Netzwerkgrenze.

### 9.1 Zugriff auf die Toggle-Function begrenzen

* Der Function Key darf nicht im Klartext in Skripten oder Repositories landen.
* Zusätzlich abgesichert über die Access Restrictions aus Abschnitt 8.

### 9.2 RBAC-Rolle minimal halten
 
* Die Managed Identity darf ausschließlich die für den Subnetz-Update notwendigen Rechte besitzen.

* Jede zusätzliche Action vergrößert die Angriffsfläche, falls die Function App kompromittiert wird.
  
### 9.3 Zustand nicht dauerhaft auf „On“ belassen
 
* Ein vergessener „Off“-Schritt hebt die Netzwerkisolation aus Kapitel 01 dauerhaft auf.

## 10. Verifikation

Für alle Funktionsaufrufe ist ausschließlich der in Abschnitt 6.5 ermittelte tatsächliche Hostname zu verwenden. Der Platzhalter `<function-hostname>` steht in den folgenden Schritten für diesen Wert und ist vor der Ausführung durch den tatsächlich ausgelesenen Hostnamen zu ersetzen.

### 10.1 Function Key abrufen

```bash
az functionapp function keys list \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --function-name ToggleWebInternet \
  --query default \
  --output tsv
```

Den Wert als `<function-key>` in den folgenden Aufrufen verwenden.

### 10.2 Toggle On

```bash
curl -X POST \
  "https://<function-hostname>/api/ToggleWebInternet?code=<function-key>" \
  -H "Content-Type: application/json" \
  -d '{"State": "On"}'
```

Erwartete Antwort: `Internetzugang aktiviert.`

### 10.3 NAT Gateway-Zuordnung prüfen

```bash
az network vnet subnet show \
  --resource-group rg-<project>-<environment>-<region> \
  --vnet-name vnet-<project> \
  --name snet-web \
  --query "natGateway.id" \
  --output tsv
```

Erwartetes Ergebnis: vollständige Resource-ID des `nat-<project>`.

### 10.4 Ausgehenden Internetzugang auf der Web-VM testen

Über die Edge-VM als Jump-Host auf die Web-VM verbinden (siehe Kapitel 03, §3.2) und dort:

```bash
curl -s https://api.ipify.org
```

Erwartetes Ergebnis: die öffentliche IP von `pip-<project>-nat`.

### 10.5 System aktualisieren

```bash
sudo apt update
sudo apt upgrade
```

### 10.6 Toggle Off

```bash
curl -X POST \
  "https://<function-hostname>/api/ToggleWebInternet?code=<function-key>" \
  -H "Content-Type: application/json" \
  -d '{"State": "Off"}'
```

Erwartete Antwort: `Internetzugang deaktiviert.`

Anschließend Abschnitt 10.3 wiederholen — die Query muss nun einen leeren Wert zurückgeben.

## 11. Typische Fehlerbilder

| Fehlerbild                                                                                                     | Mögliche Ursache                                                             | Lösung                                                                           |
| -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `403 Forbidden` beim Toggle-Aufruf                                                                             | Falscher oder fehlender Function Key                                         | Key aus Abschnitt 10.1 erneut abrufen und korrekt als `code=`-Parameter mitgeben |
| `400 Bad Request`                                                                                              | `State`-Wert ist weder `On` noch `Off`                                       | Body- oder Query-Parameter auf Tippfehler prüfen                                 |
| Toggle antwortet `200 OK`, aber `natGateway.id` bleibt leer                                                    | Managed Identity hat keine ausreichenden RBAC-Rechte (`subnets/write` fehlt) | Rollenzuweisung aus Abschnitt 5.1 bzw. 6.4 prüfen                                |
| `curl https://api.ipify.org` auf der Web-VM liefert weiterhin einen Timeout, obwohl Toggle „On“ gemeldet wurde | NSG-Regel blockiert ausgehenden Verkehr trotz NAT Gateway                    | Outbound-Regeln der NSG aus Kapitel 01 und 03 prüfen                             |
| Function App deployt, aber `ToggleWebInternet` ist nicht aufrufbar (`404`)                                     | `function.json` oder `run.ps1` liegt nicht im erwarteten Pfad im Deploy-Zip  | Verzeichnisstruktur aus Abschnitt 7 gegenprüfen und erneut deployen              |

## 12. Wartungsablauf (Checkliste)

Dieser Ablauf ist bei jeder Wartung zu wiederholen. Der Zustand `State=On` ist ausschließlich für die Dauer der Wartung vorgesehen.

```
[ ] 1. Toggle On:   POST .../ToggleWebInternet?code=<function-key>  Body: {"State":"On"}
[ ] 2. Zuordnung prüfen (§10.3)
[ ] 3. Wartungsarbeiten durchführen (apt update, apt upgrade, …)
[ ] 4. Toggle Off:   POST .../ToggleWebInternet?code=<function-key>  Body: {"State":"Off"}
[ ] 5. Zuordnung prüfen: NAT Gateway nicht mehr an snet-web gebunden
[ ] 6. `curl https://api.ipify.org` auf der Web-VM ausführen → muss mit Timeout oder Verbindungsfehler abbrechen
```

> **Wichtig:** Wird Schritt 10.6 vergessen, bleibt die Web-VM dauerhaft mit dem Internet verbunden. Das hebt die Netzwerkisolation aus Kapitel 01 auf und widerspricht dem Sicherheitsprinzip dieses Setups.

## 13. Ergebnis

Nach Abschluss dieses Kapitels gilt:

* Die Web-VM bleibt im Normalbetrieb vollständig isoliert — ohne Public IP und ohne dauerhaften Internetzugang.
* Ausgehender Internetzugang ist ausschließlich temporär aktivierbar und wird über einen HTTP-Toggle mit minimaler RBAC-Berechtigung gesteuert.
* Die Function App fungiert als schlanker, auditierbarer Kontrollpunkt zwischen Admin-Rechner und Netzwerkkonfiguration.
