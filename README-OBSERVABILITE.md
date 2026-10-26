# Guide des tests — scénarios V1 à V6

Ce dossier contient les scripts qui **prouvent** que la plateforme tient : six scénarios de validation (V1 à V6), une vérification d'idempotence (R2) et les bibliothèques qui les supportent. Chaque exécution écrit un rapport horodaté dans `resultats/` : commande exacte, sortie brute, chronomètres et verdict. Les chiffres du dossier d'architecture proviennent de ces rapports, sans retouche.

---

## Sommaire

1. [Vue d'ensemble des scripts](#1-vue-densemble-des-scripts)
2. [Prérequis](#2-prérequis)
3. [Principes communs](#3-principes-communs)
4. [Ordre d'exécution recommandé](#4-ordre-dexécution-recommandé)
5. [Description détaillée des scripts](#5-description-détaillée-des-scripts)
   - [V1 — Répartition](#v1--répartition-v1_repartitionsh)
   - [V2 — Panne d'un serveur applicatif](#v2--panne-dun-serveur-applicatif-v2_panne_appsh)
   - [V3 — Montée en charge](#v3--montée-en-charge-v3_montee_en_chargesh)
   - [V4 — Panne de la base primaire](#v4--panne-de-la-base-primaire-v4_panne_basesh)
   - [V5 — Reconstruction](#v5--reconstruction-v5_reconstructionsh)
   - [V6 — Panne du répartiteur](#v6--panne-du-répartiteur-v6_panne_repartiteursh)
   - [R2 — Idempotence](#r2--idempotence-r2_idempotencesh)
   - [run_all.sh — Enchaînement](#run_allsh--enchaînement)
   - [lib.sh et lib_mesure.sh — Bibliothèques](#libsh-et-lib_mesuresh--bibliothèques)
   - [Scripts d'appui hors de `tests/`](#scripts-dappui-hors-de-tests)
6. [Variables d'environnement](#6-variables-denvironnement)
7. [Lire un rapport](#7-lire-un-rapport)
8. [Résultats de référence du groupe 8](#8-résultats-de-référence-du-groupe-8)
9. [Dépannage](#9-dépannage)

---

## 1. Vue d'ensemble des scripts

| Script | Rôle | Destructif ? | Prérequis particulier |
|---|---|---|---|
| `v1_repartition.sh` | 20 appels à `/info` : tous les serveurs répondent, écart < 20 % | Non | Plateforme démarrée |
| `v2_panne_app.sh` | Arrête `app1` en pleine charge, mesure les erreurs | Arrête puis relance `app1` | Au moins 2 serveurs applicatifs |
| `v3_montee_en_charge.sh` | `ab -n 2000 -c 50` pour N = 2 puis N = 4 | Crée des VM (`vagrant up`) et reprovisionne les répartiteurs | `ab` sur l'hôte, ou VM `obs` démarrée |
| `v4_panne_base.sh` | Arrête `bdd1`, vérifie les 503, exécute et chronomètre la bascule | **Laisse `bdd1` arrêtée** et bdd2 promue | Confirmation demandée (`YES=1` pour l'éviter) |
| `v5_reconstruction.sh` | `vagrant destroy -f` puis `vagrant up`, vérifie la plateforme | **Détruit toutes les VM** | Confirmation demandée |
| `v6_panne_repartiteur.sh` | Arrête `lb1`, mesure la reprise par l'IP virtuelle | Arrête puis relance `lb1` | Extension E1 : `lb2` démarrée |
| `r2_idempotence.sh` | Rejoue `vagrant provision` deux fois et compare les empreintes | Reprovisionne toutes les VM démarrées | Plateforme démarrée |
| `run_all.sh` | Enchaîne les scénarios et affiche un récapitulatif | Selon l'option | — |
| `lib.sh` | Fonctions communes (rapport, HTTP, sonde, Vagrant, `ab`) | — | À *sourcer*, pas à exécuter |
| `lib_mesure.sh` | Mesure de l'arrêt effectif d'une VM (V2 et V6) | — | À *sourcer* après `lib.sh` |

---

## 2. Prérequis

- **Poste hôte** : `bash`, `curl`, `awk`, `sed`, `grep`, `sort`, `uniq`, `vagrant` et un `date` GNU (supportant `%N`). Utilisez **Git Bash**, WSL ou Linux ; le Terminal macOS standard ne convient pas (le script le détecte et s'arrête).
- **ApacheBench** (`ab`) pour V3 : `sudo apt install apache2-utils` ; à défaut, le script lance `ab` depuis la VM `obs` (à démarrer avec `vagrant up obs`, avec `E2=1`).
- **Racine du dépôt** : les scripts se placent d'eux-mêmes à la racine (`lib.sh` fait un `cd`), mais `vagrant` doit connaître le même `GROUPE`, `NB_APP`, `E1` et `E2` que ceux de la création des machines : mettez-les dans `.env`.
- **Droits** : `chmod +x tests/*.sh` si nécessaire.

---

## 3. Principes communs

**Un rapport par exécution.** Le fichier `resultats/<scénario>_AAAAMMJJ_HHMMSS.txt` reprend tout ce qui s'affiche. V2, V4 et V6 enregistrent en plus la **sonde brute** (`…_sonde_brute_….log`, une ligne `horodatage code hôte` par requête).

**Contrôles et verdict.** Chaque vérification affiche `[ OK ]` ou `[ECHEC]`. Le script termine par `RÉSULTAT GLOBAL : SUCCÈS` ou `ÉCHEC` et renvoie un code de retour :

| Code | Signification |
|---|---|
| `0` | Tous les contrôles réussis |
| `1` | Au moins un contrôle en échec (ou action annulée) |
| `2` | Prérequis absent (ex. V6 sans `lb2`, `ab` introuvable) : le scénario est *ignoré* |

**Détection automatique.** Les scripts déduisent `GROUPE` et `NB_APP` de `config/noeuds.yml`, choisissent l'adresse testée dans l'ordre `http://<IP virtuelle .5>`, `http://<lb1>`, `http://localhost:8080`, et cherchent un matricule valide (`MAT000001`…) si la route `/resultat` ne répond pas 200.

**Mesure A et mesure B (V2 et V6).** `vagrant halt --force` met plusieurs secondes à couper réellement la VM (≈ 7 s observées). Les scripts relèvent deux origines :
- **Mesure A** : t0 = lancement de la commande d'arrêt (inclut le délai propre à Vagrant/VirtualBox) ;
- **Mesure B** : t0 = **arrêt effectif**, observé par une sonde directe sur la machine (trois échecs consécutifs). C'est la mesure de référence des contrôles.

**Honnêteté des mesures.** Les VM, le répartiteur et `ab` partagent le processeur d'un même poste : un débit qui n'augmente pas avec N est un **résultat à commenter**, pas un échec. Ne retouchez jamais un rapport à la main.

---

## 4. Ordre d'exécution recommandé

```bash
./tests/v1_repartition.sh          # 1. répartition
./tests/v2_panne_app.sh            # 2. panne d'une application (relance app1 à la fin)
./tests/v3_montee_en_charge.sh     # 3. N=2 puis N=4 (crée app3 et app4)
./tests/v6_panne_repartiteur.sh    # 4. nécessite E1 (E1=1 dans .env, vagrant up lb2)
./tests/v4_panne_base.sh           # 5. laisse bdd1 arrêtée
./tests/v5_reconstruction.sh       # 6. DÉTRUIT puis reconstruit : à lancer après V4
./tests/r2_idempotence.sh          # 7. sur une plateforme saine
```

`run_all.sh` automatise tout ou partie de cet ordre (voir plus bas). **V4 doit précéder V5** : V4 laisse la base dans un état bascule que seule V5 remet à l'état initial.

---

## 5. Description détaillée des scripts

### V1 — Répartition (`v1_repartition.sh`)

**Objectif.** Vérifier que les N serveurs applicatifs apparaissent tour à tour, avec un écart de charge inférieur à 20 %.

**Commande.** `./tests/v1_repartition.sh`

**Ce que fait le script.**
1. Détecte l'adresse testée.
2. Envoie `REQUESTS` (20) requêtes `curl` successives sur `/info`.
3. Compte les réponses par serveur (`app1`, `app2`, …) et calcule `écart = (max − min) / total`.

**Contrôles.** (1) les N serveurs ont répondu ; (2) écart < 20 % ; (3) aucune requête en erreur.

**Variables.** `REQUESTS` (20), `BASE_URL`.

**Durée.** Quelques secondes. Sans effet de bord.

### V2 — Panne d'un serveur applicatif (`v2_panne_app.sh`)

**Objectif.** Montrer que le service reste disponible quand un serveur applicatif tombe en pleine charge, sans erreur au-delà de 5 secondes.

**Commande.** `./tests/v2_panne_app.sh`

**Ce que fait le script.**
1. Lance une sonde continue (une requête toutes les 0,1 s sur `/info`).
2. Après `PRE_DURATION` (5 s), exécute `vagrant halt --force app1` et détecte l'arrêt effectif par une sonde directe.
3. Continue la charge pendant `POST_DURATION` (30 s) après l'arrêt effectif.
4. Analyse la sonde (mesures A et B), puis relance `app1` (`vagrant up app1`) et attend sa réintégration.

**Contrôles.** (1) au moins 2 serveurs déclarés ; (2) la cible est démarrée ; (3) aucune erreur au-delà de 5 s après l'arrêt effectif ; (4) le service répond toujours ; (5) la cible n'est plus sollicitée 5 s après son arrêt ; (6) la cible est de nouveau dans la répartition.

**Mesures produites.** Nombre de requêtes envoyées et en erreur, première et dernière erreur, période dégradée, plus longue série d'erreurs, hôtes servis avant et après.

**Variables.** `CIBLE` (`app1`), `PRE_DURATION` (5), `POST_DURATION` (30), `HALT_FORCE` (1 = arrêt brutal), `CIBLE_URL`.

**Effet de bord.** `app1` est arrêtée puis relancée. **Durée** : 1 à 3 minutes.

### V3 — Montée en charge (`v3_montee_en_charge.sh`)

**Objectif.** Mesurer le débit pour N = 2 puis N = 4 serveurs applicatifs.

**Commande.** `./tests/v3_montee_en_charge.sh [N …]` (par défaut `2 4`, dans cet ordre croissant)

**Ce que fait le script.** Pour chaque N :
1. **Met la plateforme à N** : `vagrant up` (crée les serveurs manquants), `vagrant provision` sur chaque répartiteur (régénère HAProxy), `vagrant provision obs` si `obs` tourne ; attend jusqu'à 120 s que N serveurs répondent.
2. Vérifie que la route `/resultat?matricule=…` répond 200.
3. Fait un **échauffement** de 200 requêtes (non compté).
4. Lance `RUNS` (3) mesures `ab -n 2000 -c 50`, avec 5 s de pause entre elles.
5. Relève req/s, temps moyen, p50, p95, p99, requêtes en échec et réponses non-2xx.
6. Affiche la fenêtre horaire à capturer dans Grafana.

À la fin : tableau de synthèse, **médiane du débit par N** et variation entre le premier et le dernier N.

**Contrôles.** (1) plateforme prête avec N ; (2) route répondant 200 ; (3) aucune requête en échec ni non-2xx. La variation de débit est une **information**, pas un contrôle.

**Variables.** `RUNS` (3), `REQUETES` (2000), `CONCURRENCE` (50), `MATRICULE`, `ROUTE`, `USE_OBS=1` (lancer `ab` depuis la VM `obs`), `SKIP_SCALE=1` (mesurer la configuration en cours sans toucher aux VM ; le script vérifie alors que le N annoncé correspond au nombre de serveurs qui répondent).

**Effet de bord.** Crée `app3`, `app4` (+1 Go de RAM) et reprovisionne les répartiteurs. **Durée** : 10 minutes et plus.

> Un `NB_APP=4` exporté dans le terminal ne **crée pas** les machines : seul `vagrant up` le fait. Sans `SKIP_SCALE`, V3 s'en charge.

### V4 — Panne de la base primaire (`v4_panne_base.sh`)

**Objectif.** Vérifier que la panne de bdd1 donne un 503 propre (jamais de page blanche ni d'erreur de connexion brute), puis chronométrer la bascule sur bdd2.

**Commande.** `./tests/v4_panne_base.sh`

**Ce que fait le script.**
1. Vérifie que la commande de bascule existe (par défaut `bash scripts/bascule.sh`) **avant** d'arrêter la base, puis demande confirmation.
2. Contrôle l'état initial : `/sante` et `/resultat` en 200, bdd2 en réplique.
3. Démarre une sonde `/sante` via le répartiteur, puis exécute `vagrant halt --force bdd1` (t0).
4. Attend le premier 503, puis relève les réponses brutes : directement sur app1, via le répartiteur, et sur `/resultat`.
5. Exécute la bascule et la chronomètre.
6. Attend le retour de `/sante` et `/resultat` en 200 et vérifie que bdd2 est promue.
7. Analyse la sonde (période dégradée).

**Contrôles.** (1)(2) `/sante` et `/resultat` en 200 avant la panne ; (3) 503 via le répartiteur ; (4) app1 renvoie 503 ; (5) corps non vide ; (6) aucune erreur de connexion brute ; (7) bascule sans erreur ; (8)(9) `/sante` et `/resultat` de nouveau en 200 ; (10) bdd2 n'est plus en recovery.

**Chronomètres.** Panne → premier 503 ; durée de la procédure de bascule ; panne → `/sante` en 200 ; panne → `/resultat` en 200 (temps total de remise en service).

**Variables.** `BASCULE_CMD` (défaut `bash scripts/bascule.sh`), `YES=1`.

**Effet de bord.** **`bdd1` reste arrêtée.** Pour revenir à l'état initial : V5. **Durée** : 3 à 5 minutes.

### V5 — Reconstruction (`v5_reconstruction.sh`)

**Objectif.** Prouver que `vagrant destroy -f` puis `vagrant up` redonne une plateforme fonctionnelle sans aucune intervention.

**Commande.** `./tests/v5_reconstruction.sh` (ou `YES=1 ./tests/v5_reconstruction.sh`)

**Ce que fait le script.**
1. Demande confirmation, puis exécute `vagrant destroy -f`, puis `vagrant up`, en chronométrant chaque étape.
2. Attend que `/sante` réponde 200.
3. Vérifie la répartition, la route `/resultat`, que bdd2 est une réplique et que bdd1 voit une réplique en flux.

**Contrôles.** (1) `vagrant up` sans erreur ; (2) `/sante` en 200 ; (3) les N serveurs dans la répartition ; (4) `/resultat` en 200 ; (5) bdd2 est une réplique ; (6) bdd1 voit une réplique en flux.

**Chronomètres.** Durée de `destroy`, de `up` et durée totale jusqu'à une plateforme vérifiée.

**Effet de bord.** **Détruit toutes les VM du projet.** **Durée** : 15 à 20 minutes selon la connexion.

### V6 — Panne du répartiteur (`v6_panne_repartiteur.sh`)

**Objectif.** Montrer que le service reste joignable à la même adresse (IP virtuelle `.5`) quand `lb1` tombe, avec une reprise en moins de 5 secondes (extension E1).

**Commande.** `./tests/v6_panne_repartiteur.sh`

**Ce que fait le script.**
1. Vérifie que l'IP virtuelle répond ; sinon sort avec le code `2` en indiquant de démarrer `lb2` (`E1=1`, `vagrant up lb2`).
2. Lance une sonde sur l'IP virtuelle, puis arrête `lb1` (`vagrant halt --force`) et détecte l'arrêt effectif.
3. Continue la sonde pendant `POST_DURATION` (20 s).
4. Calcule la **plus longue interruption** (temps de reprise VRRP) et vérifie que `lb2` porte l'IP virtuelle.
5. Relance `lb1` et vérifie que le service reste joignable.

**Contrôles.** (1) `lb2` démarré ; (2) `lb1` démarré ; (3) le service répond à la même adresse après l'arrêt ; (4) reprise sans erreur au-delà de 5 s ; (5) `lb2` porte l'IP virtuelle ; (6) service joignable après le retour de `lb1`.

**Variables.** `LB_ACTIF` (`lb1`), `LB_PASSIF` (`lb2`), `POST_DURATION` (20), `HALT_FORCE`, `ACTIF_URL`.

**Effet de bord.** `lb1` arrêté puis relancé. **Durée** : 1 à 3 minutes.

### R2 — Idempotence (`r2_idempotence.sh`)

**Objectif.** Vérifier que `vagrant provision` rejoué deux fois ne modifie aucun fichier de configuration.

**Commande.** `./tests/r2_idempotence.sh`

**Ce que fait le script.** Relève les empreintes `sha256` des fichiers de configuration clés (`/etc/hosts`, `haproxy.cfg`, `keepalived.conf`, `postgresql.conf`, `pg_hba.conf`, configuration Prometheus et Grafana…) sur chaque VM démarrée, rejoue deux fois `vagrant provision`, relève de nouveau, puis compare.

**Contrôles.** (1) premier rejeu sans erreur ; (2) deuxième rejeu sans erreur ; (3) aucun fichier modifié. La section « différences avant / après » du rapport doit être vide.

**Alternative PowerShell.** `.\r2.ps1` (bases de données seulement, via `scripts/etat-bdd.sh`). **Durée** : environ 10 minutes.

> Ne lancez pas ce test après une bascule de la base : `vagrant provision` remettrait `DB_HOST` sur bdd1.

### `run_all.sh` — Enchaînement

| Commande | Contenu |
|---|---|
| `./tests/run_all.sh` | V1, V2, V3 (N courant, `SKIP_SCALE=1`), V6 — non destructif |
| `./tests/run_all.sh --complet` | V1, V2, V3 (N = 2 puis 4), V6, V4, V5 — **destructif** |

Le script affiche un **récapitulatif** : `SUCCÈS`, `ÉCHEC` ou `IGNORÉ (prérequis absent)` par scénario. `YES=1` évite les demandes de confirmation de V4 et V5.

### `lib.sh` et `lib_mesure.sh` — Bibliothèques

À *sourcer* (`source tests/lib.sh`), jamais à exécuter. `lib.sh` vérifie les outils, se place à la racine, déduit `GROUPE`, `NB_APP`, les adresses (`VIP`, `LB1_IP`, `OBS_IP`) et fournit :

| Famille | Fonctions |
|---|---|
| Rapport | `start_report`, `run`, `check`, `end_summary`, `confirm` |
| Temps | `now`, `dur`, `add`, `elapsed_since` |
| HTTP | `detect_base_url`, `http_code`, `wait_http`, `hote_de`, `wait_host` |
| Route `/resultat` | `detect_resultat`, `matricule_depuis_base` |
| Sonde continue | `probe_start`, `probe_stop`, `analyse_probe`, `probe_errors_after`, `probe_success_after`, `probe_host_after` |
| Vagrant | `vm_state`, `vm_running`, `vm_halt`, `vssh`, `noeuds_liste` |
| ApacheBench | `run_ab`, `ab_base_url` |
| Configuration | `dotenv_get`, `e2_actif`, `verifier_bascule_cmd` |

`lib_mesure.sh` fournit `halt_mesure <vm> <url_directe>` : arrête la VM et relève `T0` (lancement) et `T_DOWN` (arrêt effectif : début de trois sondes directes consécutives en échec). Garde-fous : la sonde directe doit répondre 200 **avant** l'arrêt, et un échec isolé ne compte pas.

### Scripts d'appui hors de `tests/`

| Script | Rôle |
|---|---|
| `scripts/r5-test.sh ecrire\|lire\|supprimer` | Démontre la réplication (R5) avec la ligne `MAT999999` : écrire sur bdd1, lire sur bdd2 |
| `scripts/etat-bdd.sh` | Relève l'état de PostgreSQL (empreintes, lignes marquées, mode réplique, nombre de lignes) |
| `scripts/bascule.sh` | Procédure de bascule exécutée par V4 |
| `r2.ps1`, `r5.ps1` | Variantes PowerShell des vérifications R2 et R5 |
| `bascule.ps1`, `reintegrer.ps1` | Bascule (avec simulation de panne) et réintégration de l'ancien primaire |

---

## 6. Variables d'environnement

| Variable | Défaut | Rôle |
|---|---|---|
| `GROUPE`, `NB_APP` | déduits de `noeuds.yml` | Numéro de groupe et nombre de serveurs applicatifs |
| `BASE_URL` | auto (`http://<VIP>`, sinon `lb1`, sinon `localhost:8080`) | Adresse testée |
| `MATRICULE` | `1`, puis détection (`MAT000001`…) | Matricule existant pour `/resultat` |
| `ROUTE` | `/resultat?matricule=$MATRICULE` | Route `/resultat` imposée |
| `HOST_REGEX` | `app[0-9]+` | Motif du nom d'hôte renvoyé par `/info` |
| `APP_PORT` | `3000` | Port direct des serveurs applicatifs |
| `RESULTS_DIR` | `resultats/` | Dossier des rapports |
| `HALT_FORCE` | `1` | `1` = arrêt brutal (vraie panne), `0` = arrêt propre |
| `YES` | `0` | `1` = ne pas demander confirmation (V4, V5) |
| `BASCULE_CMD` | `bash scripts/bascule.sh` | Commande de bascule de V4 |
| `RUNS`, `REQUETES`, `CONCURRENCE`, `SKIP_SCALE`, `USE_OBS` | 3, 2000, 50, 0, 0 | Réglages de V3 |
| `CIBLE`, `PRE_DURATION`, `POST_DURATION` | `app1`, 5, 30 | Réglages de V2 |
| `LB_ACTIF`, `LB_PASSIF`, `POST_DURATION` | `lb1`, `lb2`, 20 | Réglages de V6 |
| `REQUESTS` | 20 | Nombre de requêtes de V1 |

Exemple : `MATRICULE=MAT000123 RUNS=5 ./tests/v3_montee_en_charge.sh 2 3 4`

---

## 7. Lire un rapport

Un rapport se lit de haut en bas :

1. **En-tête** : scénario, date, poste, groupe/réseau, N.
2. **Corps** : chaque commande est précédée de `$ …`, suivie de sa sortie brute et de `(code retour : …)`.
3. **Contrôles** : lignes `[ OK ]` / `[ECHEC]`.
4. **Chronomètres et synthèse** : tableaux et valeurs à reporter dans le dossier.
5. **Pied** : `RÉSULTAT GLOBAL` et chemin du rapport.

À reporter dans le dossier pour chaque scénario : la commande exacte, le rapport (nom de fichier), un tableau de mesures et un commentaire honnête, y compris quand le résultat est inattendu.

---

## 8. Résultats de référence du groupe 8

Extraits des rapports versionnés dans `resultats/` (poste Windows, Git Bash, N = 2 sauf V3) :

| Scénario | Résultat mesuré |
|---|---|
| V1 | app1 = 10, app2 = 10 ; écart 0,0 % |
| V2 | 0 erreur sur 105 requêtes ; arrêt effectif constaté 6,77 s après la commande |
| V3 | Médiane N = 2 : 38,62 req/s ; N = 4 : 33,57 req/s (− 13,1 %) ; 0 échec |
| V4 | Première erreur à + 7,19 s ; bascule 44,17 s ; dernière erreur à + 65,03 s ; `/resultat` de nouveau 200 à + 76,23 s |
| V5 | `destroy` 20,86 s ; `up` 992,36 s ; total 1 061,70 s |
| V6 | Plus longue interruption 2,41 s ; IP virtuelle portée par lb2 |

---

## 9. Dépannage

| Symptôme | Cause et solution |
|---|---|
| `Le 'date' de ce système ne gère pas %N` | Hôte macOS : utilisez Linux, WSL ou Git Bash |
| `Outil manquant : …` | Installez l'outil cité (`curl`, `awk`…) |
| `vagrant halt app1` : machine introuvable | `NB_APP`/`E1`/`E2` du terminal ne correspondent pas à la création : mettez-les dans `.env` |
| V3 : « seulement X serveur(s) visible(s) sur N attendus » | `app3`/`app4` non créées ou répartiteur non reprovisionné ; laissez V3 faire (sans `SKIP_SCALE`) |
| V3 : `Non-2xx responses` ou `Failed requests` | Mauvais matricule : `MATRICULE=…` ; vérifiez `curl -i http://<VIP>/sante` |
| V3 : `ab` introuvable | `sudo apt install apache2-utils` ou `vagrant up obs` |
| V4 : `BASCULE_CMD n'est pas défini` | `scripts/bascule.sh` manquant : `export BASCULE_CMD="…"` |
| V4 : app1 renvoie `000` au lieu de 503 | Délai de `curl` trop court face au `connect_timeout` de l'application (3 s) : relancez avec un délai plus long |
| V6 : « IP virtuelle injoignable » (code 2) | E1 inactive : `E1=1` dans `.env` puis `vagrant up lb2` |
| `la sonde directe … ne répond pas 200 avant l'arrêt` | La VM visée est déjà arrêtée ou injoignable : `vagrant status`, `curl -si <url>` |
| Fins de ligne `\r` dans un script | `git add --renormalize .` ; le `.gitattributes` impose LF |
| Après V4, plus rien ne fonctionne comme avant | Normal : bdd1 est arrêtée ; lancez V5 pour revenir à l'état initial |
