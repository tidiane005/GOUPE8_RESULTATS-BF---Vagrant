# R6 - Procedure de bascule de la base de donnees (ingenieur donnees)
# La replique devient le primaire ; chaque etape est chronometree.
#
# Usage (depuis le dossier du projet) :
#   .\bascule.ps1                    promeut la replique (bdd2)
#   .\bascule.ps1 -Panne bdd1        eteint d'abord bdd1 (simulation de panne), puis promeut bdd2
#   .\bascule.ps1 -Cible bdd1        promeut bdd1 (pour revenir en arriere)
param(
    [string]$Panne = "",
    [string]$Cible = ""
)

$chrono = [System.Diagnostics.Stopwatch]::StartNew()
function Etape($t) { Write-Host ("[{0,6:N1} s] {1}" -f $chrono.Elapsed.TotalSeconds, $t) }
function Echec($t) { Write-Host "ECHEC : $t" -ForegroundColor Red; exit 1 }

if (-not (Test-Path "config\noeuds.yml")) { Echec "config\noeuds.yml introuvable (lancez le script depuis le dossier du projet)" }
$noeuds = @(); $cur = $null
foreach ($l in Get-Content "config\noeuds.yml") {
    if ($l -match '^- nom:\s*(\S+)') { $cur = @{ nom = $Matches[1] }; $noeuds += $cur }
    elseif ($cur -and $l -match '^\s+(\w+):\s*(\S+)') { $cur[$Matches[1]] = $Matches[2] }
}
if (-not $Cible) {
    $r = $noeuds | Where-Object { $_.role -eq 'replique' } | Select-Object -First 1
    if (-not $r) { Echec "aucune replique dans noeuds.yml" }
    $Cible = $r.nom
}
$ipCible = ($noeuds | Where-Object { $_.nom -eq $Cible }).ip
if (-not $ipCible) { Echec "$Cible absent de noeuds.yml" }
$apps = @($noeuds | Where-Object { $_.role -eq 'app' })

Etape "Debut : $Cible ($ipCible) va devenir le primaire"

# -- 0. Simulation de panne (facultatif) -----------------------------------------
if ($Panne) {
    vagrant halt $Panne --force | Out-Null
    Etape "PANNE : $Panne eteinte"
}
$tPanne = $chrono.Elapsed.TotalSeconds

# -- 1. Promotion -----------------------------------------------------------------
Etape "Promotion de $Cible (pg_promote)"
$sortie = vagrant ssh $Cible -c "sudo bash /vagrant/scripts/promouvoir.sh" 2>$null
$ligne = ($sortie | Where-Object { $_ -match '^(PROMU|DEJA_PRIMAIRE)' } | Select-Object -Last 1)
if (-not $ligne) { Echec "la promotion n'a pas abouti (sortie : $sortie)" }
Etape "Resultat : $ligne   (PROMU = secondes passees dans pg_promote)"
$tPromu = $chrono.Elapsed.TotalSeconds

# -- 2. Verification : $Cible accepte les ecritures ---------------------------------
$ecr = vagrant ssh $Cible -c "sudo bash /vagrant/scripts/r5-test.sh ecrire" 2>$null | Select-Object -Last 1
vagrant ssh $Cible -c "sudo bash /vagrant/scripts/r5-test.sh supprimer" 2>$null | Out-Null
if ($ecr -notmatch 'INSERT') { Echec "ecriture refusee sur $Cible (sortie : $ecr)" }
Etape "Ecriture sur $Cible acceptee ($ecr), ligne de test supprimee"
$nb = vagrant ssh $Cible -c "sudo -u postgres psql -d resultats_bf -tAc 'SELECT count(*) FROM resultats;'" 2>$null | Select-Object -Last 1
Etape "Lignes presentes sur $Cible : $nb  (50000 attendu)"

# -- 3. Repointage des serveurs applicatifs (seulement ceux qui tournent) ---------
# Fichier de configuration et service de l'ingenieur applicatif :
# /etc/resultats-bf/app.env (DB_HOST) et app.service
$repointes = 0
foreach ($a in $apps) {
    $n = $a.nom
    $marche = vagrant status $n --machine-readable 2>$null | Select-String ',state,running'
    if (-not $marche) { Etape "$n non demarree : ignoree"; continue }
    Etape "Repointage de $n vers $ipCible"
    vagrant ssh $n -c "if [ -f /etc/resultats-bf/app.env ]; then sudo sed -i 's/^DB_HOST=.*/DB_HOST=$ipCible/' /etc/resultats-bf/app.env && sudo systemctl restart app.service && echo repointe; else echo absent; fi" 2>$null | Out-Null
    $repointes++
}

# -- 4. Attente du retablissement du service via le repartiteur -----------------
$tService = 0
if ($repointes -gt 0) {
    Etape "Attente du retablissement (http://localhost:8080/sante)"
    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
        $code = curl.exe -s -o NUL -w '%{http_code}' --max-time 3 http://localhost:8080/sante
        if ($code -eq '200') { $ok = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ok) { Echec "le service n'est pas revenu en 60 s apres le repointage" }
    $tService = $chrono.Elapsed.TotalSeconds
    Etape "/sante repond 200 via le repartiteur"
    $rep = curl.exe -s --max-time 5 "http://localhost:8080/resultat?matricule=MAT000001"
    Etape "Verification /resultat : $rep"
}
$tFin = $chrono.Elapsed.TotalSeconds

Write-Host ""
Write-Host "== BASCULE TERMINEE"
if ($Panne) { Write-Host ("Panne -> $Cible primaire et ecritures verifiees : {0:N1} s" -f ($tFin - $tPanne)) }
if ($tService -gt 0) { Write-Host ("Panne -> service retabli via le repartiteur : {0:N1} s" -f ($tService - $tPanne)) }
Write-Host ("Duree totale de la procedure : {0:N1} s" -f $tFin)
$dureePromo = ($ligne -replace '^PROMU ','')
Write-Host "(dont les appels 'vagrant ssh', lents sous Windows ; pg_promote seul : $dureePromo)"
Write-Host ""
Write-Host "Pour remettre l'ancien primaire en replique : .\reintegrer.ps1"
