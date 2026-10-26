# Tests de validation : scénarios V1 à V6

Ce dossier contient les scripts qui **prouvent** que la plateforme RÉSULTATS-BF tient ses promesses : répartition de charge, résilience, scalabilité, reconstruction. Chaque script affiche ses contrôles, produit des **mesures** (pas des affirmations) et écrit un rapport horodaté dans [`../resultats/`](../resultats/).

## Sommaire

1. [Vue d'ensemble](#1-vue-densemble)
2. [Préparer l'environnement](#2-préparer-lenvironnement)
3. [Lancer les scénarios](#3-lancer-les-scénarios)
4. [Description de chaque script](#4-description-de-chaque-script)
5. [Variables de configuration](#5-variables-de-configuration)
6. [Lire un rapport](#6-lire-un-rapport)
7. [Résultats de référence](#7-résultats-de-référence)
8. [Méthode et bonnes pratiques](#8-méthode-et-bonnes-pratiques)
9. [Dépannage](#9-dépannage)

---

## 1. Vue d'ensemble

| Script | Scénario | Ce qu'il démontre | Destructif ? | Durée |
|---|---|---|---|---|
| `v1_repartition.sh` | V1 | Les serveurs applicatifs se partagent la charge | non | 1 min |
| `v2_panne_app.sh` | V2 | La panne d'un serveur applicatif n'interrompt pas le service | arrête puis relance `app1` | 3 min |
| `v3_montee_en_charge.sh` | V3 | Débit et temps de réponse avec N = 2 puis N = 4 serveurs | crée `app3`/`app4` (sauf `SKIP_SCALE=1`) | 5 min (N courant) à 30 min |
| `v6_panne_repartiteur.sh` | V6 | Le service survit à la panne de `lb1` (IP virtuelle sur `lb2`) | arrête puis relance `lb1` | 4 min |
| `v4_panne_base.sh` | V4 | Panne de `bdd1` : 503 propre, puis bascule sur `bdd2` | **laisse `bdd1` arrêtée** | 5 min |
| `v5_reconstruction.sh` | V5 | `destroy` + `up` : plateforme fonctionnelle sans geste manuel | **détruit toutes les VM** | 20 à 35 min |
| `run_all.sh` | tous | Enchaîne les scénarios et affiche un récapitulatif | selon l'option | variable |
| `r2_idempotence.sh` | R2 | Rejouer `vagrant provision` deux fois ne modifie rien | non | 10 min |

**Ordre recommandé : V1, V2, V3, V6, V4, V5.** V4 laisse `bdd1` arrêtée ; V5, en dernier, remet tout à neuf.

---

## 2. Préparer l'environnement

Les scripts sont des scripts **bash** : les lancer dans **Git Bash** (ou Linux/WSL), jamais dans PowerShell, depuis la racine du dépôt.

```bash
cd /c/Users/<utilisateur>/GOUPE8_RESULTATS-BF---Vagrant
export GROUPE=8                       # votre numéro de groupe
export NB_APP=2                       # nombre de serveurs applicatifs
chmod +x scripts/*.sh tests/*.sh
vagrant up                            # socle : bdd1, bdd2, app1, app2, lb1
vagrant up obs lb2                    # extensions (E2=1 et E1=1 dans .env) : requis pour V3 sans ab local et V6
vagrant status
```

À refaire dans chaque nouveau terminal : les `export` sont perdus à la fermeture. `GROUPE` et `NB_APP` doivent être **ceux utilisés pour `vagrant up`**.

Prérequis sur le poste : `bash`, `curl`, `awk`, `sed`, `vagrant` et un `date` GNU (Git Bash convient). L'outil `ab` (ApacheBench) est utilisé sur le poste s'il existe, **sinon dans la machine `obs`** : celle-ci doit alors tourner.

Avant de commencer, repérez le matricule valide (détecté automatiquement par les scripts, forme `MAT000001`) :

```bash
curl "http://192.168.63.5/resultat?matricule=MAT000001"
```

---

## 3. Lancer les scénarios

```bash
./tests/v1_repartition.sh
./tests/v2_panne_app.sh
./tests/v3_montee_en_charge.sh      # pour confirmer la création des nouvelles apps à travers "vagrant status", il faut d'abord faire "export NB_APP=n"( remplacer "n" par le nombre total de app)
./tests/v6_panne_repartiteur.sh
./tests/v4_panne_base.sh                         # répondre o à la confirmation
./tests/v5_reconstruction.sh                     # répondre o : DÉTRUIT tout, ~20 à 35 min
```

- **V3 complet, 2 puis 4 serveurs** : `./tests/v3_montee_en_charge.sh` (sans `SKIP_SCALE`) crée `app3` et `app4`. Pour revenir à 2 serveurs ensuite :
  ```bash
  export NB_APP=4 && vagrant destroy -f app3 app4
  export NB_APP=2 && vagrant provision lb1 && vagrant provision obs     # + lb2 s'il tourne
  ```
- **Enchaîner** : `./tests/run_all.sh` lance V1, V2, V3 (`SKIP_SCALE=1`) et V6 sans rien détruire ; `./tests/run_all.sh --complet` lance aussi V4 et V5 (avec V3 en 2 puis 4). `YES=1` supprime les demandes de confirmation.
- **Verdicts de tous les rapports** : `grep -H "RÉSULTAT GLOBAL" resultats/*.txt`

Les scripts s'arrêtent avec le code `0` (succès), `1` (échec) ou `2` (prérequis absent, par exemple `lb2` non démarrée).

---

## 4. Description de chaque script

### 4.1 `lib.sh` : bibliothèque commune

*À sourcer, pas à exécuter.* Fournit à tous les scénarios :

| Fonction | Rôle |
|---|---|
| `start_report`, `run`, `check`, `end_summary` | Création du rapport horodaté, affichage de chaque commande exacte avec son résultat brut, contrôles `[ OK ]`/`[ECHEC]`, verdict final et code de sortie |
| `detect_base_url` | Trouve l'adresse à tester : IP virtuelle `.5`, sinon `lb1`, sinon `localhost:8080` |
| `detect_resultat` | Trouve un matricule valide (celui fourni, puis la base, puis un balayage) et la route `/resultat` correspondante ; réessaie jusqu'à la fin de l'initialisation |
| `noeuds_liste`, `dotenv_get` | Lecture de `config/noeuds.yml` (fins de ligne CRLF tolérées) et de `.env` |
| `probe_start`, `probe_stop`, `analyse_probe` | **Sonde de charge** en arrière-plan (une requête toutes les 0,1 s) et calcul du nombre et de la durée des erreurs |
| `wait_http`, `wait_host`, `http_code`, `hote_de` | Attentes et lectures HTTP (code retour, nom du serveur qui répond) |
| `vm_state`, `vm_running`, `vm_halt`, `vssh` | Pilotage des machines (`vagrant halt --force` par défaut, pour simuler une vraie panne) |
| `run_ab`, `ab_base_url` | Lancement d'`ab` sur le poste ou, à défaut, dans la machine `obs` |
| `confirm` | Demande de confirmation avant une opération destructive |

### 4.2 `lib_mesure.sh` : mesure de l'arrêt effectif

*À sourcer après `lib.sh` (utilisé par V2 et V6).* Fonction `halt_mesure <vm> <url_directe>` : lance l'arrêt de la machine et relève **deux instants** : le lancement de la commande (T0) et l'**arrêt effectif** (T_DOWN), détecté en interrogeant la machine directement, sans passer par le répartiteur. Garde-fous : la sonde directe doit répondre 200 **avant** l'arrêt (sinon rien n'est arrêté), et il faut **3 échecs consécutifs** pour déclarer l'arrêt (un échec isolé est ignoré).

*Pourquoi :* `vagrant halt --force` met plusieurs secondes (6 à 10 s) à couper réellement la VM ; compter la reprise à partir du lancement de la commande y ajouterait un délai qui n'est pas une propriété de la plateforme.

### 4.3 `v1_repartition.sh` : répartition de charge (V1)

- **Fait** : 20 appels successifs à `/info` via l'IP virtuelle (`REQUESTS`).
- **Contrôles** : les N serveurs applicatifs ont répondu ; écart entre le plus et le moins sollicité < 20 % ; aucune requête en erreur.
- **Sortie** : liste des 20 réponses, répartition en nombre et en pourcentage.

### 4.4 `v2_panne_app.sh` : panne d'un serveur applicatif (V2)

- **Fait** : lance la sonde (0,1 s) 5 s, arrête `app1` (`CIBLE`) **pendant la charge** avec `halt_mesure`, observe 30 s, puis relance `app1`.
- **Contrôles** (6) : au moins 2 serveurs déclarés ; `app1` démarré avant ; **aucune erreur plus de 5 s après l'arrêt effectif** ; le service répond toujours ; `app1` n'est plus sollicité 5 s après son arrêt effectif ; `app1` réintégré à la répartition.
- **Sortie** : deux mesures, **A** (depuis le lancement de la commande, à titre d'information) et **B** (depuis l'arrêt effectif, référence des contrôles), avec nombre de requêtes perdues et durée de la période dégradée. Journal brut de la sonde dans `resultats/V2_sonde_brute_*.log`.

### 4.5 `v3_montee_en_charge.sh` : montée en charge (V3)

- **Fait** : pour chaque N de la liste (défaut `2 4`, ordre croissant), met la plateforme à N serveurs (`NB_APP`, `vagrant up`, régénération de HAProxy et de Prometheus), vérifie la répartition, fait un échauffement (200 requêtes, non compté) puis `RUNS` = 3 mesures `ab -n 2000 -c 50` sur `/resultat?matricule=…`.
- **Contrôles** : plateforme prête avec N ; route `/resultat` valide ; aucune requête en échec ni non-2xx. Avec `SKIP_SCALE=1` : le nombre de serveurs qui répondent doit égaler N, sinon le script refuse de mesurer.
- **Sortie** : tableau de synthèse (requêtes/s, temps moyen, p50, p95, p99, échecs, non-2xx), débit médian par N, variation en pourcentage, et **fenêtre horaire à retrouver dans Grafana** pour chaque N.
- **Note** : la variation du débit est une **observation à commenter** (`[ INFO ]`), pas un critère de réussite : les VM partagent le processeur d'un seul poste.

### 4.6 `v4_panne_base.sh` : panne de la base primaire (V4)

- **Fait** : lance une sonde sur `/sante` ; arrête `bdd1` ; vérifie la réponse 503 ; exécute la **procédure de bascule** (`bash scripts/bascule.sh`, ou `BASCULE_CMD`) ; attend le retour du service ; chronomètre chaque phase. Demande une confirmation.
- **Contrôles** (10) : `/sante` et `/resultat` à 200 avant la panne ; `/sante` renvoie 503 via le répartiteur ; chaque serveur applicatif renvoie 503 avec un corps non vide (pas de page blanche) ; pas d'erreur de connexion brute ; bascule sans erreur ; `/sante` puis `/resultat` redeviennent 200 ; `bdd2` n'est plus en *recovery*.
- **Sortie** : chronomètres (premier 503, durée de la bascule, retour de `/sante`, retour de `/resultat`), réponses brutes pendant la panne, analyse de la sonde. Journal : `resultats/V4_sonde_brute_*.log`.
- **Attention** : laisse `bdd1` arrêtée. Pour revenir à l'état initial : V5.

### 4.7 `v5_reconstruction.sh` : reconstruction complète (V5)

- **Fait** (**destructif**, confirmation demandée) : `vagrant destroy -f`, puis `vagrant up` (socle : `bdd1`, `bdd2`, `app*`, `lb1`), puis vérifie la plateforme. `obs` et `lb2`, démarrées à la demande, ne sont **pas** recréées : les relancer ensuite avec `vagrant up obs lb2`.
- **Contrôles** (6) : `vagrant up` sans erreur ; `/sante` répond 200 sans intervention ; les N serveurs sont dans la répartition ; la route `/resultat` répond 200 ; `bdd2` est une réplique ; `bdd1` voit une réplique en flux.
- **Sortie** : durée de `destroy`, durée de `up`, **durée totale jusqu'à une plateforme vérifiée prête** (socle de 5 machines).

### 4.8 `v6_panne_repartiteur.sh` : panne du répartiteur (V6)

- **Fait** : vérifie que `lb1` et `lb2` tournent, lance la sonde sur l'IP virtuelle, arrête `lb1` (`LB_ACTIF`) avec `halt_mesure`, observe 20 s, relance `lb1`.
- **Contrôles** (6) : `lb2` et `lb1` démarrés ; le service répond toujours à la même adresse ; **reprise en moins de 5 s après l'arrêt effectif** ; `lb2` porte l'IP virtuelle ; service joignable après le retour de `lb1`.
- **Sortie** : mesures A et B, plus longue interruption (temps de reprise VRRP), adresse virtuelle sur `lb2`. Prérequis : `E1=1` et `vagrant up lb2` (sinon code de sortie `2`).

### 4.9 `run_all.sh` : orchestrateur

Sans option : V1, V2, V3 (`SKIP_SCALE=1`) et V6 (non destructif). `--complet` : V1, V2, V3 (N=2 puis 4), V6, V4, V5. Affiche un récapitulatif `SUCCÈS` / `ÉCHEC` / `IGNORÉ`.

### 4.10 `r2_idempotence.sh` : idempotence (R2)

Relève l'empreinte (`sha256`) des fichiers de configuration clés de chaque machine démarrée (`/etc/haproxy/haproxy.cfg`, `/etc/keepalived/keepalived.conf`, PostgreSQL, Prometheus…), rejoue `vagrant provision` **deux fois**, et vérifie qu'aucun fichier n'a changé. Les outils `r2.ps1` et `r5.ps1` (racine du dépôt, PowerShell) en sont les équivalents pour la base de données (idempotence R2, réplication R5).

---

## 5. Variables de configuration

| Variable | Défaut | Utilisée par | Effet |
|---|---|---|---|
| `GROUPE`, `NB_APP` | `.env` / déduites de `noeuds.yml` | tous | Doivent correspondre à `vagrant up` |
| `YES` | `0` | V4, V5, `run_all` | `1` : pas de confirmation |
| `MATRICULE` | détecté | V3, V4, V5 | Matricule à interroger |
| `ROUTE` | détectée | V3, V4, V5 | Chemin `/resultat` imposé |
| `BASE_URL` | IP virtuelle `.5` | tous | Adresse testée |
| `REQUESTS` | `20` | V1 | Nombre d'appels |
| `CIBLE` | `app1` | V2 | Serveur applicatif à arrêter |
| `PRE_DURATION`, `POST_DURATION` | 5 s, 30 s (V2) / 20 s (V6) | V2, V6 | Durée de charge avant et après la panne |
| `HALT_FORCE` | `1` | V2, V6 | `1` : arrêt brutal (panne réelle) |
| `LB_ACTIF`, `LB_PASSIF` | `lb1`, `lb2` | V6 | Répartiteurs |
| `RUNS`, `REQUETES`, `CONCURRENCE` | `3`, `2000`, `50` | V3 | Protocole de mesure `ab` |
| `SKIP_SCALE` | `0` | V3 | `1` : mesurer l'état courant sans toucher aux VM |
| `USE_OBS` | `0` | V3 | `1` : lancer `ab` depuis la VM `obs` |
| `BASCULE_CMD` | `bash scripts/bascule.sh` | V4 | Commande de bascule |
| `RESULTS_DIR` | `resultats/` | tous | Dossier des rapports |

---

## 6. Lire un rapport

Chaque rapport `resultats/Vn_<scénario>_<date>_<heure>.txt` contient, dans l'ordre : l'en-tête (date, poste, groupe, N), **chaque commande exacte avec son résultat brut**, les contrôles, les mesures et le verdict. Les scénarios V2, V4 et V6 écrivent aussi la sonde brute (`*_sonde_brute_*.log` : horodatage, code HTTP, serveur).

```text
[ OK ]    Aucune erreur au-delà de 5 s après l'arrêt effectif (mesure B, constaté : 0)
[ECHEC]   ...
RÉSULTAT GLOBAL : SUCCÈS (6 contrôle(s) réussi(s))
```

---

## 7. Résultats de référence

Mesurés sur un poste Windows (VirtualBox 7.2, une vCPU par VM, toutes les machines sur le même processeur), N = 2. Rapports dans `resultats/`.

| Scénario | Résultat | Verdict |
|---|---|---|
| **V1** | 20 appels : `app1` 10 (50 %), `app2` 10 (50 %), écart 0 %, 0 erreur | SUCCÈS 3/3 |
| **V2** | 0 requête perdue sur 105 ; arrêt effectif de `app1` 6,8 s après la commande ; aucune erreur après | SUCCÈS 6/6 |
| **V3** | N=2 : 38,6 req/s (médiane) ; N=4 : 33,6 req/s (−13 %) ; 0 échec sur 12 000 requêtes | SUCCÈS 5/5 |
| **V4** | Interruption côté client : 58 s ; procédure de bascule : 44 s ; retour de `/resultat` : 76 s | SUCCÈS 10/10 |
| **V5** | `destroy` 21 s + `up` 992 s ; plateforme prête en 1062 s (17 min 42 s) | SUCCÈS 6/6 |
| **V6** | 1 requête perdue sur 75 ; interruption maximale 2,4 s ; `lb2` porte l'IP virtuelle | SUCCÈS 6/6 |

Ces valeurs dépendent de la charge du poste : les rejouer donne le même ordre de grandeur, pas les mêmes chiffres.

---

## 8. Méthode et bonnes pratiques

- **Mesurer plutôt qu'affirmer** : ne jamais modifier un rapport à la main ; refaire un scénario si un doute existe, et conserver les deux rapports.
- **Un débit qui n'augmente pas avec N** (V3) est un résultat honnête, pas un échec : toutes les VM partagent un seul processeur et la base est commune.
- **Arrêt effectif** : V2 et V6 comptent la reprise à partir du moment où la machine est réellement arrêtée, pas du lancement de `vagrant halt`.
- **Horloges** : l'horloge d'une VM peut retarder de quelques minutes sur celle du poste ; décaler en conséquence la fenêtre de temps dans Grafana.
- **Avant V5** : sauvegarder `resultats/` ailleurs et commiter le travail en cours ; ne jamais lancer V5 par inadvertance.

---

## 9. Dépannage

| Message | Cause probable | Solution |
|---|---|---|
| `machine not found` | `GROUPE` / `NB_APP` non exportés ou différents | Refaire les `export` |
| V3 : `ab est absent de l'hôte et la VM obs ne tourne pas` | `ab` absent du poste | `vagrant up obs` |
| V3 : `NB_APP=4 dans ce terminal, mais 2 serveur(s) répondent` | Variable d'un autre test | `export NB_APP=2`, ou retirer `SKIP_SCALE=1` |
| V6 : code de sortie `2`, IP virtuelle injoignable | `lb2` non démarrée | `vagrant up lb2` |
| `ATTENTION : aucune route /resultat ne répond 200` | Base ou application indisponible | `vagrant status` puis `curl -si "http://192.168.63.5/resultat?matricule=MAT000001"` |
| V4 : `scripts/bascule.sh n'existe pas` | Dépôt incomplet | `git pull` |
| `bash\r: No such file` | Fins de ligne CRLF | `sed -i 's/\r$//' tests/*.sh scripts/*.sh` |
| `curl` ne répond pas dans PowerShell | Alias PowerShell de `curl` | Utiliser Git Bash |
