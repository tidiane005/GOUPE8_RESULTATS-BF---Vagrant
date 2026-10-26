# RÉSULTATS-BF

**Plateforme de consultation de résultats d'examens : résiliente, scalable, entièrement décrite en code.**

Projet de groupe (groupe 8) du module *Virtualisation et Cloud Computing*, M1 Informatique, IBAM, Université Joseph Ki-Zerbo.

Un candidat saisit son matricule et obtient son résultat. Derrière cette page se trouve une infrastructure de sept machines virtuelles au maximum, construite et configurée par une seule commande (`vagrant up`), qui survit à la panne d'un serveur applicatif, d'un répartiteur ou de la base de données, et qui s'agrandit en changeant une seule valeur.

## Sommaire

1. [Présentation](#1-présentation)
2. [Architecture](#2-architecture)
3. [Prérequis](#3-prérequis)
4. [Installation et démarrage](#4-installation-et-démarrage)
5. [Utiliser et exploiter la plateforme](#5-utiliser-et-exploiter-la-plateforme)
6. [Organisation du dépôt](#6-organisation-du-dépôt)
7. [Exigences et extensions](#7-exigences-et-extensions)
8. [Tests et résultats](#8-tests-et-résultats)
9. [Dépannage](#9-dépannage)
10. [Équipe](#10-équipe)

---

## 1. Présentation

| | |
|---|---|
| **Besoin** | Consulter un résultat à partir d'un matricule (50 000 candidats), même au moment du pic de consultation |
| **Exigences prioritaires** | **Résilience** : la panne d'une machine n'interrompt pas le service. **Scalabilité** : ajouter de la capacité = ajouter des machines, sans réécrire la configuration |
| **Technologies** | Vagrant + VirtualBox, HAProxy, Keepalived (VRRP), Python (Flask + Gunicorn), PostgreSQL 16, Prometheus, Grafana |
| **Principe directeur** | Une **source unique de vérité** : le `Vagrantfile` décrit les machines et engendre `config/noeuds.yml`, dont se servent HAProxy, Prometheus et les scripts. Aucune adresse n'est écrite en dur. |
| **Reconstruction** | `vagrant destroy -f` puis `vagrant up` : plateforme fonctionnelle sans geste manuel (mesuré : environ 18 minutes) |

---

## 2. Architecture

```text
                    Poste hôte (navigateur, curl, ab)
                                  |
                       localhost:8080 -> lb1:80          (seul port exposé à l'hôte)
                                  |
 +--------------------- réseau privé 192.168.63.0/24 ----------------------+
 |                                                                         |
 |                      IP virtuelle VRRP : 192.168.63.5                   |
 |                                   |                                     |
 |            +----------------------+----------------------+              |
 |            |                                             |              |
 |     lb1 (MASTER)  .11                             lb2 (BACKUP)  .12     |
 |     HAProxy + Keepalived                          HAProxy + Keepalived  |
 |            |            sonde GET /sante (1 s)           |              |
 |            +----------------------+----------------------+              |
 |                                   | HTTP :3000 (round-robin)            |
 |             +---------------------+---------------------+               |
 |             |                     |                     |               |
 |        app1 .21              app2 .22             app3 ... appN         |
 |        Flask + Gunicorn      (sans état)          (NB_APP = N)          |
 |             |                     |                                     |
 |             +---------------------+                                     |
 |                                   | SQL :5432                           |
 |                         bdd1 (primaire) .31 ---> bdd2 (réplique) .32    |
 |                         PostgreSQL 16    réplication en flux asynchrone |
 |                                                                         |
 |     obs .41 : Prometheus (:9090) + Grafana (:3000)  <-- métriques de    |
 |     toutes les machines (node_exporter :9100) et de HAProxy (:8405)     |
 +-------------------------------------------------------------------------+
```

Le sous-réseau est `192.168.X.0/24` avec **X = 55 + GROUPE**. Pour le groupe 8, X = 63.

### Les machines

| Machine | Adresse | RAM | Rôle | Statut | Démarrée par `vagrant up` |
|---|---|---|---|---|---|
| `bdd1` | `.31` | 768 Mo | PostgreSQL primaire (lecture/écriture) | Obligatoire | oui |
| `bdd2` | `.32` | 768 Mo | Réplique en flux, promouvable | Obligatoire | oui |
| `app1` … `appN` | `.21` … `.2N` | 512 Mo | Serveurs applicatifs sans état (N = `NB_APP`, par défaut 2) | Obligatoire | oui |
| `lb1` | `.11` | 512 Mo | Répartiteur actif (HAProxy + Keepalived MASTER) | Obligatoire | oui |
| `lb2` | `.12` | 512 Mo | Répartiteur passif (Keepalived BACKUP) | Extension E1 (`E1=1`) | non, `vagrant up lb2` |
| `obs` | `.41` | 768 Mo | Prometheus + Grafana | Extension E2 (`E2=1`) | non, `vagrant up obs` |

Le socle (5 machines) occupe environ **3 Go** de mémoire. Avec `lb2` et `obs` : environ 4,3 Go. Ces deux extensions ne démarrent pas avec `vagrant up` pour ménager un poste de 8 Go.

### Le voyage d'une requête

1. Le client appelle `http://localhost:8080/resultat?matricule=MAT000001` (ou l'IP virtuelle `192.168.63.5`).
2. **Keepalived** attribue l'IP virtuelle au répartiteur en bonne santé : `lb1` en temps normal, `lb2` s'il tombe.
3. **HAProxy** répartit en *round-robin* entre les serveurs applicatifs dont la sonde `GET /sante` répond 200. Un serveur défaillant est retiré ; une requête échouée est rejouée sur un autre serveur (`option redispatch 1`).
4. L'application **Flask/Gunicorn** (sans état) lit la table `resultats` dans PostgreSQL et renvoie du JSON.
5. Si `bdd1` tombe, `/sante` renvoie 503 (aucun serveur n'est plus servi) jusqu'à la **bascule** : `bdd2` est promue primaire et les serveurs applicatifs sont repointés.

### Choix techniques en bref

| Domaine | Choix | Raison |
|---|---|---|
| Répartition | HAProxy, `balance roundrobin`, sonde `/sante` toutes les 1 s (`fall 3`, `rise 2`) | Standard, sonde applicative réelle |
| Haute disponibilité du répartiteur | Keepalived (VRRP), priorité 101 (lb1) / 100 (lb2), annonce toutes les 1 s | IP unique pour les clients |
| Application | Flask + Gunicorn (2 processus × 2 threads), service systemd `app`, aucun état local | Ajout/retrait d'un serveur sans conséquence |
| Base | PostgreSQL 16, réplication en flux asynchrone, accès limité au réseau privé (`scram-sha-256`) | Mécanisme natif, réplique lisible |
| Supervision | node_exporter (toutes les VM) + exporter intégré de HAProxy, Prometheus, Grafana | Voir le débit monter et un serveur disparaître |
| Reproductibilité | Scripts idempotents, boîte épinglée `bento/ubuntu-24.04` version `202508.03.0`, `.gitattributes` (fins de ligne LF) | Rejeu sans effet de bord |

---

## 3. Prérequis

| Outil | Rôle | Remarque |
|---|---|---|
| **VirtualBox** 7.x | Virtualisation | Les réseaux hôte-seul doivent rester dans `192.168.56.0/21` (ne pas modifier `networks.conf`) |
| **Vagrant** 2.4 ou plus | Orchestration | Redémarrer le poste après l'installation |
| **Git for Windows** | Fournit **Git Bash**, indispensable pour les tests | |
| Mémoire | 8 Go sur le poste | 3 Go pour le socle |

Vérification (dans PowerShell) :

```powershell
VBoxManage --version
vagrant --version
git --version
```

---

## 4. Installation et démarrage

### 4.1 Récupérer le dépôt

```bash
git clone https://github.com/tidiane005/GOUPE8_RESULTATS-BF---Vagrant.git
cd GOUPE8_RESULTATS-BF---Vagrant
```

### 4.2 Créer le fichier de configuration `.env`

Les mots de passe ne sont **jamais** dans le dépôt. Un modèle est fourni :

```bash
cp .env.exemple .env      # PowerShell : Copy-Item .env.exemple .env
```

Ouvrir `.env` et renseigner les variables :

| Variable | Rôle | Valeur d'exemple |
|---|---|---|
| `GROUPE` | Numéro de groupe (1 à 8) : détermine le réseau `192.168.(55+GROUPE).0/24` | `8` |
| `NB_APP` | Nombre de serveurs applicatifs (≥ 2) | `2` |
| `DB_USER` | Utilisateur PostgreSQL (application et réplication) | `resultats` |
| `DB_NAME` | Nom de la base | `resultats_bf` |
| `DB_PASS` | Mot de passe PostgreSQL | **à choisir** |
| `VRRP_PASS` | Mot de passe VRRP entre répartiteurs (8 premiers caractères utilisés) | **à choisir** |
| `GRAFANA_ADMIN_PASSWORD` | Mot de passe du compte `admin` de Grafana | **à choisir** |
| `E1` | `1` = déclare `lb2` (répartiteur redondant) | `1` |
| `E2` | `1` = déclare `obs` (supervision) | `1` |

> Les valeurs de `.env.exemple` sont de simples exemples de laboratoire. `.env` est ignoré par Git : ne jamais le commiter.
> Priorité des valeurs : variable d'environnement du terminal > `.env` > valeur par défaut. Un `export NB_APP=4` temporaire remplace donc le `.env`.

### 4.3 Démarrer

```bash
vagrant validate        # attendu : Vagrantfile validated successfully
vagrant up              # bdd1, bdd2, app1, app2, lb1 (premier lancement : 15 à 20 minutes)
vagrant up obs lb2      # extensions (nécessitent E2=1 et E1=1 dans .env)
vagrant status
```

Le premier démarrage télécharge la boîte Ubuntu et installe les paquets : prévoir une bonne connexion et de la patience. Aucun geste manuel n'est requis ensuite.

### 4.4 Vérifier que tout fonctionne

```bash
curl http://localhost:8080/info                              # {"serveur":"app1"} puis app2...
curl http://localhost:8080/sante                             # {"statut":"OK"}
curl "http://localhost:8080/resultat?matricule=MAT000001"    # résultat du candidat
```

| Interface | Adresse | Accès |
|---|---|---|
| Application (via l'hôte) | `http://localhost:8080` | public |
| Application (IP virtuelle) | `http://192.168.63.5` | réseau privé |
| Grafana | `http://192.168.63.41:3000` | `admin` + `GRAFANA_ADMIN_PASSWORD` |
| Prometheus | `http://192.168.63.41:9090/targets` | toutes les cibles doivent être **UP** |
| Statistiques HAProxy | `http://192.168.63.11:8404/stats` | état des serveurs |

---

## 5. Utiliser et exploiter la plateforme

### 5.1 L'application

| Point d'entrée | Réponse |
|---|---|
| `GET /resultat?matricule=…` | `200` JSON `{matricule, nom, serie, moyenne, admis}` · `400` matricule absent · `404` matricule inconnu · `503` base indisponible |
| `GET /sante` | `200 {"statut":"OK"}` si la base répond, `503 {"statut":"INDISPONIBLE"}` sinon (sonde de HAProxy) |
| `GET /info` | `200 {"serveur":"<nom d'hôte>"}` : sert à observer la répartition |

Les matricules vont de `MAT000001` à `MAT050000`.

### 5.2 Ajouter ou retirer un serveur applicatif (R3)

**Passer à 4 serveurs** : une seule valeur à changer. Dans Git Bash :

```bash
export NB_APP=4
vagrant up                      # crée app3 et app4
vagrant provision lb1           # HAProxy relit config/noeuds.yml (et lb2 s'il tourne)
vagrant provision obs           # Prometheus relit config/noeuds.yml
```

La configuration de HAProxy et de Prometheus est **engendrée** depuis `config/noeuds.yml` : elle suit toute seule.

**Revenir à 2 serveurs** (Vagrant ne connaît `app3` et `app4` que si `NB_APP=4`) :

```bash
export NB_APP=4
vagrant destroy -f app3 app4
export NB_APP=2
vagrant provision lb1           # puis lb2 et obs s'ils tournent
vagrant provision obs
```

### 5.3 Déployer une nouvelle version sans coupure (E4)

Après avoir modifié `app/main.py`, depuis PowerShell :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-app.ps1
```

Le script vérifie que tous les serveurs sont sains, puis met à jour **un serveur à la fois** (`vagrant provision appN`) et attend que `/sante` réponde 200 avant de passer au suivant : il en reste toujours au moins un en service.

### 5.4 Basculer la base sur la réplique (R6)

Quand `bdd1` est tombée, depuis la racine du dépôt :

```bash
bash scripts/bascule.sh            # Git Bash, sur l'hôte
```

Le script (1) promeut `bdd2` en primaire (`pg_promote`), (2) repointe `DB_HOST` vers `bdd2` sur chaque serveur applicatif démarré (`/etc/resultats-bf/app.env`) et redémarre le service. Il est rejouable sans effet de bord et se chronomètre lui-même (environ 45 s sur le poste de développement, presque tout en appels `vagrant ssh`).

Remettre l'ancien primaire en réplique (ses données sont **remplacées** par celles du nouveau primaire) :

```powershell
.\reintegrer.ps1                   # bdd1 redevient réplique de bdd2
```

Détails, version PowerShell (`bascule.ps1 -Panne bdd1`) et limites : [`docs/bascule.md`](docs/bascule.md).

> Ne pas rejouer `vagrant provision` sur `bdd1`/`bdd2` après une bascule : les scripts supposent `bdd1` primaire. Pour revenir à l'état initial : `vagrant destroy -f` puis `vagrant up`.

### 5.5 Superviser

Grafana, tableau **RESULTATS-BF - Infrastructure** (chargé automatiquement) : état UP/DOWN des machines, serveurs applicatifs vus par HAProxy, débit en requêtes/s, réponses par code HTTP, sessions en cours, temps de réponse moyen, serveurs actifs par backend, CPU, mémoire et réseau par machine. Pendant une panne, le serveur arrêté disparaît du panneau « Serveurs applicatifs vus par HAProxy ».

### 5.6 Arrêter, reprendre, tout effacer

| Je veux… | Commande |
|---|---|
| Éteindre sans rien perdre | `vagrant halt` |
| Redémarrer | `vagrant up` |
| Mettre en pause | `vagrant suspend` / `vagrant resume` |
| Tout supprimer et repartir de zéro | `vagrant destroy -f` puis `vagrant up` |

---

## 6. Organisation du dépôt

```text
Vagrantfile                 source de vérité : machines, réseau, secrets via .env
.env.exemple                modèle de configuration (versionné) ; .env n'est jamais versionné
config/
  noeuds.yml                ENGENDRÉ par le Vagrantfile (non versionné)
  grafana/                  source de données et tableau de bord provisionnés
app/                        service Flask (main.py), dépendances, tests unitaires
scripts/                    provisionnement : bdd.sh, replique.sh, app.sh, lb.sh, obs.sh,
                            node_exporter.sh, lb-metrics.sh, gen_prometheus_config.py ;
                            exploitation : bascule.sh, promouvoir.sh, rejoindre.sh,
                            deploy-app.ps1
tests/                      scénarios V1 à V6 et utilitaires  ->  tests/README.md
resultats/                  rapports horodatés des scénarios
docs/                       procédure de bascule (bascule.md)
bascule.ps1, reintegrer.ps1, r2.ps1, r5.ps1   outils PowerShell de l'ingénieur données
README-OBSERVABILITE.md     détails de la supervision
```

---

## 7. Exigences et extensions

| Réf. | Exigence | Où / comment |
|---|---|---|
| R1 | Reconstruction intégrale | `vagrant destroy -f && vagrant up` ; mesuré par V5 |
| R2 | Idempotence | scripts rejouables ; vérifiée par `tests/r2_idempotence.sh` et `r2.ps1` |
| R3 | Nombre de serveurs paramétrable | `NB_APP` ; HAProxy et Prometheus engendrés depuis `config/noeuds.yml` |
| R4 | Sonde de santé | HAProxy interroge `/sante` ; scénario V2 |
| R5 | Réplication en flux | `bdd2` réplique de `bdd1` ; `r5.ps1`, V4, V5 |
| R6 | Procédure de bascule | `scripts/bascule.sh`, `docs/bascule.md` ; scénario V4 |
| R7 | Aucun secret dans le dépôt | `.env` ignoré, `.env.exemple` versionné |
| R8 | Cloisonnement réseau | seul `lb` redirige un port (80 → 8080 / 8081) |
| E1 | Répartiteur redondant | `lb2` + Keepalived ; scénario V6 |
| E2 | Observabilité | `obs` : Prometheus + Grafana |
| E4 | Déploiement sans coupure | `scripts/deploy-app.ps1` |

---

## 8. Tests et résultats

Les six scénarios de validation (V1 à V6) sont des scripts bash dans [`tests/`](tests/README.md), à lancer dans **Git Bash** :

```bash
./tests/v1_repartition.sh
./tests/v2_panne_app.sh
SKIP_SCALE=1 ./tests/v3_montee_en_charge.sh
./tests/v6_panne_repartiteur.sh
./tests/v4_panne_base.sh        # laisse bdd1 arrêtée
./tests/v5_reconstruction.sh    # détruit et reconstruit tout : en dernier
```

Chaque script affiche des contrôles `[ OK ]` / `[ECHEC]`, un `RÉSULTAT GLOBAL`, et écrit un rapport dans `resultats/`. Guide complet, description de chaque script et résultats de référence : [`tests/README.md`](tests/README.md).

Tests unitaires de l'application (7 tests, base de données simulée), depuis la racine du dépôt, dans un environnement Python où `pip install -r app/requirements.txt` a été exécuté :

```bash
python -m unittest app.test_main
```

---

## 9. Dépannage

| Symptôme | Cause probable et solution |
|---|---|
| `variables manquantes dans .env` | Compléter `DB_USER`, `DB_NAME`, `DB_PASS` |
| `machine not found` | `GROUPE` / `NB_APP` d'un terminal ne correspondent pas à ceux du `vagrant up` ; refaire les `export` |
| `obs` ou `lb2` inconnue de `vagrant status` | `E2=1` / `E1=1` absent du `.env` |
| `GRAFANA_ADMIN_PASSWORD manquant` | Renseigner le mot de passe puis `vagrant provision obs` |
| `/sante` renvoie 503 | Base arrêtée ou `.env` incorrect : `vagrant status`, puis `vagrant ssh bdd1 -c "sudo systemctl status postgresql"` |
| `bash\r: No such file or directory` | Fins de ligne CRLF : `sed -i 's/\r$//' scripts/*.sh tests/*.sh` |
| Avertissement « guest additions » | Sans gravité |
| Premier `vagrant up` très long | Normal (téléchargements) ; ne pas interrompre |
| Tout est cassé | `vagrant destroy -f` puis `vagrant up` |

---

## 10. Équipe

| Rôle | Membre (identifiant Git) | Périmètre |
|---|---|---|
| Architecte réseau et répartition | KABORE Olivier Wendpanga | Plan d'adressage, Vagrantfile, HAProxy, Keepalived, extension E1 |
| Ingénieur applicatif | SANON Cheick Hadou | Service HTTP sans état, gestion des erreurs, déploiement sans coupure (E4) |
| Ingénieur données | BADINI Cheick Ahmed Tidiane | PostgreSQL, jeu de données, réplication, procédure de bascule |
| Ingénieur essais et observabilité | ROUAMBA Wendpagnagdé Franck Idsene | Scénarios V1 à V6, campagne de mesures, supervision (E2) |

*M1 Informatique · IBAM · Université Joseph Ki-Zerbo · année 2025-2026.*
