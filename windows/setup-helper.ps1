# PinShift — Helper di verifica ambiente Windows
# Esegui in PowerShell: .\windows\setup-helper.ps1

$ErrorActionPreference = "SilentlyContinue"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   PinShift — Verifica Setup Windows -> iOS   " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# 1. Controlla Apple Mobile Device Support (driver USB iPhone)
$appleSvc = Get-Service -Name "Apple Mobile Device Service"
if ($appleSvc) {
    Write-Host "[OK] Apple Mobile Device Service trovato (Stato: $($appleSvc.Status))" -ForegroundColor Green
    if ($appleSvc.Status -ne "Running") {
        Write-Host "     -> Suggerimento: avvia il servizio o reinstalla iTunes Desktop (non Microsoft Store)." -ForegroundColor Yellow
    }
} else {
    Write-Host "[!] Apple Mobile Device Service NON trovato." -ForegroundColor Yellow
    Write-Host "    Installa iTunes (versione Desktop da apple.com) oppure Apple Devices per i driver USB iPhone." -ForegroundColor Gray
}

# 2. Controlla Git / GitHub CLI per caricare facilmente il progetto su GitHub
$gitCmd = Get-Command git
if ($gitCmd) {
    Write-Host "[OK] Git installato: $((git --version) -join ' ')" -ForegroundColor Green
} else {
    Write-Host "[i] Git non trovato: puoi caricare il progetto su GitHub usando GitHub Desktop oppure l'upload web." -ForegroundColor Yellow
}

# 3. Controlla se esiste gia un pairing file nella cartella Download
$downloads = Join-Path $env:USERPROFILE "Downloads"
$pairFiles = Get-ChildItem -Path $downloads -Include *.mobiledevicepairing, *.plist -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "*Info.plist*" }

if ($pairFiles) {
    Write-Host ""
    Write-Host "[OK] Possibili pairing file trovati in Download:" -ForegroundColor Green
    foreach ($f in $pairFiles) {
        Write-Host "     - $($f.FullName) ($($f.Length) byte)" -ForegroundColor White
    }
} else {
    Write-Host ""
    Write-Host "[i] Nessun pairing file trovato in Download." -ForegroundColor Gray
    Write-Host "    Generalo collegando l'iPhone via USB e usando idevice_pair." -ForegroundColor Gray
}

Write-Host ""
Write-Host "Link utili per il setup:" -ForegroundColor Cyan
Write-Host "  1) GitHub (crea account gratis):  https://github.com/signup"
Write-Host "  2) Sideloadly (installa IPA):     https://sideloadly.io/"
Write-Host "  3) idevice_pair (pairing file):   https://github.com/jkcoxson/idevice_pair/releases"
Write-Host "  4) LocalDevVPN (App Store iOS):   cerca 'LocalDevVPN' sull'App Store del tuo iPhone"
Write-Host ""
Write-Host "Premi INVIO per aprire le pagine di Sideloadly e idevice_pair nel browser (oppure CTRL+C per uscire)..." -ForegroundColor Yellow
Read-Host | Out-Null

Start-Process "https://sideloadly.io/"
Start-Process "https://github.com/jkcoxson/idevice_pair/releases"
