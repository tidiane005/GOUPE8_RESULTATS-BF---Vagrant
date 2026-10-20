# R6 - Remet l'ancien primaire en replique du nouveau (apres bascule.ps1)
# Usage :
#   .\reintegrer.ps1                          bdd1 devient replique de bdd2
#   .\reintegrer.ps1 -Machine bdd2 -Source bdd1   (apres une bascule inverse)
param(
    [string]$Machine = "bdd1",
    [string]$Source  = "bdd2"
)

$chrono = [System.Diagnostics.Stopwatch]::StartNew()
function Etape($t) { Write-Host ("[{0,6:N1} s] {1}" -f $chrono.Elapsed.TotalSeconds, $t) }
function Echec($t) { Write-Host "ECHEC : $t" -ForegroundColor Red; exit 1 }

Etape "Demarrage de $Machine (sans reprovisionnement)"
vagrant up $Machine --no-provision | Out-Null
if ($LASTEXITCODE -ne 0) { Echec "vagrant up $Machine" }

Etape "Rattachement de $Machine a $Source (copie complete, quelques secondes)"
$sortie = vagrant ssh $Machine -c "sudo bash /vagrant/scripts/rejoindre.sh $Source" 2>$null
if (-not ($sortie | Select-String 'REPLIQUE_OK')) { Echec "rattachement (sortie : $sortie)" }
Etape "$Machine est en mode replique"

$flux = vagrant ssh $Source -c "sudo -u postgres psql -tAc 'SELECT client_addr, state, sync_state FROM pg_stat_replication;'" 2>$null
Etape "Flux de replication vu depuis ${Source} : $flux"
$n1 = vagrant ssh $Source  -c "sudo -u postgres psql -d resultats_bf -tAc 'SELECT count(*) FROM resultats;'" 2>$null | Select-Object -Last 1
$n2 = vagrant ssh $Machine -c "sudo -u postgres psql -d resultats_bf -tAc 'SELECT count(*) FROM resultats;'" 2>$null | Select-Object -Last 1
Etape "Lignes : $Source = $n1 ; $Machine = $n2"
if ($n1 -ne $n2) { Echec "les deux noeuds n'ont pas le meme nombre de lignes" }
Write-Host ""
Write-Host "== REINTEGRATION TERMINEE : $Machine est replique de $Source"
