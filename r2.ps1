# R2 - Idempotence : vagrant provision rejoue deux fois ne change rien
# Principe : releve de l'etat (empreinte des fichiers de configuration, nombre
# de lignes, mode replique) avant, apres un premier rejeu, apres un second rejeu.
# Les trois releves doivent etre identiques.
# Usage : powershell -ExecutionPolicy Bypass -File .\r2.ps1   (comptez ~10 min)

function Releve {
    $r = @()
    foreach ($m in "bdd1", "bdd2") {
        $r += "[$m]"
        $r += (vagrant ssh $m -c "sudo bash /vagrant/scripts/etat-bdd.sh" 2>$null | Where-Object { $_ -match ':' })
    }
    return $r
}

function Rejeu($n) {
    Write-Host "Rejeu $n : vagrant provision bdd1 bdd2 ..."
    vagrant provision bdd1 bdd2 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "ECHEC : le rejeu $n a echoue" -ForegroundColor Red; exit 1 }
}

Write-Host "== R2 : idempotence des scripts de base de donnees"
$a = Releve
Rejeu 1
$b = Releve
Rejeu 2
$c = Releve

Write-Host ""
Write-Host "== Etat avant"; $a
Write-Host ""
Write-Host "== Etat apres le rejeu 2"; $c
Write-Host ""
if ((($a -join "`n") -eq ($b -join "`n")) -and (($b -join "`n") -eq ($c -join "`n"))) {
    Write-Host "RESULTAT : identique avant, apres 1 rejeu et apres 2 rejeux (R2 valide)" -ForegroundColor Green
} else {
    Write-Host "RESULTAT : DIFFERENCES detectees" -ForegroundColor Red
    Write-Host "--- apres rejeu 1"; $b
}
