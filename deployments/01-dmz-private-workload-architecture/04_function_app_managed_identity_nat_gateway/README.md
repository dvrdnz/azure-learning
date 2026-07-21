# 04_function_app_managed_identity_nat_gateway

Dieses Verzeichnis enthält die Deployments-Assets zur Umsetzung aus
`docs/01-dmz-private-workload-architecture/04_function_app_managed_identity_nat_gateway.md`.

Erstellte Dateien:

- `nat-toggle-role.json` – Custom Role Definition (Placeholders ersetzen)
- `scripts/function/requirements.psd1` – PowerShell-Module für die Function
- `scripts/function/ToggleWebInternet/function.json` – Function Binding
- `scripts/function/ToggleWebInternet/run.ps1` – Function-Handler (PowerShell)
- `create-resources.sh` – Hilfs-Skript mit CLI-Befehlen zum Erstellen (Placeholders)

Kurzanleitung

1. Platzhalter in den Dateien ersetzen: `<project>`, `<environment>`, `<region>`, `<subscription>`, `<admin-ip>`.
2. Optional: Public IP und NAT Gateway erstellen:

```bash
bash create-resources.sh create-pip
bash create-resources.sh create-nat
```

3. Storage Account und Function App erstellen:

```bash
bash create-resources.sh create-storage
bash create-resources.sh create-function
```

4. Custom Role anlegen und die Managed Identity der Function zuweisen:

```bash
bash create-resources.sh create-role
bash create-resources.sh assign-role
```

5. Function zippen und deployen:

```bash
cd scripts/function
zip -r deploy.zip .
cd -
bash create-resources.sh deploy-function
```

6. Function Key ermitteln und Toggle verwenden (siehe Doku):

```bash
az functionapp function keys list \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --function-name ToggleWebInternet \
  --query default \
  --output tsv
```

Hinweis: Die Skripte sind als Vorlage gedacht. Vor dem Ausführen immer Platzhalter ersetzen und Befehle prüfen.
