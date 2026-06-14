# Wrapper uruchamiany przez Harmonogram zadan Windows (zadanie "PowerDWH ETL").
# Uruchamia orkiestrator w trybie przyrostowym i loguje wyjscie do logs\etl_RRRRMMDD.log.
$ErrorActionPreference = 'Stop'

# --- sciezki maszyny (dostosuj przy przenosinach) ---
$ScriptsDir = 'C:\Users\jozio\Dokumenty\Power_DWH\Python_scripts'
$Python     = 'C:\Users\jozio\AppData\Local\Programs\Python\Python311\python.exe'
# ----------------------------------------------------

$LogDir = Join-Path $ScriptsDir 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$Log = Join-Path $LogDir ("etl_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

"==== START $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====" | Out-File -FilePath $Log -Append -Encoding utf8
Set-Location $ScriptsDir
& $Python 'load_range.py' '--incremental' *>> $Log
$code = $LASTEXITCODE
"==== KONIEC $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  exit=$code ====" | Out-File -FilePath $Log -Append -Encoding utf8
exit $code
