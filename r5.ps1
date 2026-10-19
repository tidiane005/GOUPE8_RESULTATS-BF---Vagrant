# R5 - La replique bdd2 recoit les ecritures de bdd1 (replication en flux)
# Demonstration : insertion sur bdd1, puis lecture sur bdd2 ; verification que
# bdd2 refuse les ecritures ; nettoyage.
# Usage : powershell -ExecutionPolicy Bypass -File .\r5.ps1

function Sur($machine, $action) {
    $r = vagrant ssh $machine -c "sudo bash /vagrant/scripts/r5-test.sh $action" 2>&1
    return ($r | Where-Object { $_ -and ($_ -notmatch 'Connection to') }) -join " "
}

Write-Host "== R5 : replication bdd1 -> bdd2"
$etat = (vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();'" 2>$null | Select-Object -Last 1).ToString().Trim()
Write-Host "bdd2 en mode replique (recovery) : $etat   (t = oui)"
$flux = vagrant ssh bdd1 -c "sudo -u postgres psql -tAc 'SELECT client_addr, state, sync_state FROM pg_stat_replication;'" 2>$null
Write-Host "Flux de replication vu depuis bdd1 : $flux"

Sur "bdd1" "supprimer" | Out-Null
Write-Host ""
Write-Host "1. Avant : lecture sur bdd2         : [$(Sur 'bdd2' 'lire')]   (vide attendu)"
Write-Host "2. Ecriture sur bdd1                : $(Sur 'bdd1' 'ecrire')"
$t0 = Get-Date
$vu = ""
for ($i = 0; $i -lt 30 -and -not $vu; $i++) {
    $vu = Sur 'bdd2' 'lire'
    if (-not $vu) { Start-Sleep -Milliseconds 500 }
}
$delai = ((Get-Date) - $t0).TotalSeconds
if ($vu) { Write-Host ("3. Lecture sur bdd2                 : [{0}]   (visible, mesure incluant les appels ssh : {1:N1} s)" -f $vu, $delai) }
else     { Write-Host "3. ECHEC : la ligne n'est pas arrivee sur bdd2 en 15 s" -ForegroundColor Red }

$refus = Sur 'bdd2' 'ecrire'
Write-Host "4. Ecriture sur bdd2 (doit etre refusee) : $refus"

Sur "bdd1" "supprimer" | Out-Null
Write-Host "5. Nettoyage de la ligne de test sur bdd1 : fait"
