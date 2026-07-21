# 05_deploy_function_app_update

Assets für das Kapitel `docs/01-dmz-private-workload-architecture/05_deploy_function_app_update.md`.

Inhalt:

- `scripts/function/host.json` – Function Host-Konfiguration (Timeout, Queue-Settings, managedDependency)
- `scripts/function/profile.ps1` – Cold-start Helper
- `scripts/function/requirements.psd1` – PowerShell-Module (`Az.*`)
- `scripts/function/ToggleWebInternet/function.json` und `run.ps1` – HTTP-Starter
- `scripts/function/ToggleWebInternetWorker/function.json` und `run.ps1` – Queue-Worker
- `scripts/function/GetToggleWebInternetStatus/function.json` und `run.ps1` – Status-Endpunkt
- `scripts/function/Modules/StatusStore/StatusStore.psm1` – Status-Blob-Logik
- `scripts/function/Modules/RetryHelper/RetryHelper.psm1` – Retry-Helper
- `create-resources.sh` – Hilfs-Skript (Placeholders; App Settings & Rolle erweitern)

Kurzanleitung

1. Platzhalter ersetzen: `<project>`, `<environment>`, `<region>`, `<subscription>`.
2. Sicherstellen, dass Kapitel 04 in einem sauberen `Off`-Zustand ist (siehe Doku).
3. `scripts/function` zippen und deployen (siehe Doku Abschnitt 9).
4. App Settings setzen (siehe Doku Abschnitt 8).

Beispiel: Zip und Deploy

```bash
cd deployments/05_deploy_function_app_update/scripts/function
rm -f deploy.zip
zip -r deploy.zip GetToggleWebInternetStatus Modules ToggleWebInternet ToggleWebInternetWorker host.json profile.ps1 requirements.psd1
cd -
az functionapp deployment source config-zip \
  --resource-group rg-<project>-<environment>-<region> \
  --name func-<project>-<environment> \
  --src deployments/05_deploy_function_app_update/scripts/function/deploy.zip
```

Hinweis: Vor dem Deployen immer Platzhalter ersetzen und `unzip -l deploy.zip` prüfen.
