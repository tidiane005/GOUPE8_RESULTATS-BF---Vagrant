# RÉSULTATS-BF — Ingénieur essais et observabilité

Ce document décrit **tout ce qui relève du rôle « Ingénieur essais et observabilité »** et comment l'installer dans le dépôt du groupe :

| Tâche du cahier des charges | Fichier(s) livré(s) |
|---|---|
| Prometheus + Grafana sur `obs` (192.168.X.41) | `scripts/obs.sh` |
| Prometheus collecte VM + HAProxy (extension E2) | `scripts/gen_prometheus_config.py`, `scripts/lb-metrics.sh` |
| Grafana connecté à Prometheus + tableau de bord | `config/grafana/datasource.yml`, `dashboards.yml`, `resultats-bf.json` |
| `node_exporter` sur les VM (CPU, mémoire, réseau) | `scripts/node_exporter.sh` |
| Scripts de validation V1 à V6 | `tests/v1_…` à `tests/v6_…`, `tests/lib.sh`, `tests/run_all.sh` |
| (bonus barème R2) preuve d'idempotence | `tests/r2_idempotence.sh` |

> **Ce qui a été vérifié.** Les scripts ont été relus (`bash -n`), le générateur Prometheus et les calculs de mesure (répartition, erreurs, période dégradée, parsing d'`ab`) ont été testés sur un faux répartiteur. **En revanche, rien n'a pu être exécuté dans de vraies VM VirtualBox** : le premier `vagrant up obs` de votre groupe est le vrai test. La section [Dépannage](#9-dépannage) liste les points les plus susceptibles de demander un ajustement.

---

## 1. Principes de conception

1. **Source unique de vérité** : Prometheus ne contient aucune adresse écrite à la main. `obs.sh` lit `config/noeuds.yml` (écrit par le Vagrantfile) et engendre `prometheus.yml`. Ajouter des serveurs applicatifs (`NB_APP=4`) puis rejouer `vagrant provision obs` suffit — même logique que pour la configuration du répartiteur (R3).
2. **Idempotence (R2)** : chaque fichier de configuration est comparé (`cmp`) avant remplacement ; un service n'est redémarré que si son fichier change ; `lb-metrics.sh` retire puis réécrit son bloc, et ne recharge HAProxy que si le résultat diffère.
3. **Pas de secret dans le dépôt (R7)** : le mot de passe Grafana vient de `.env` (non versionné), via le Vagrantfile (`env:`), et n'est écrit que dans la VM `obs`.
4. **Cloisonnement réseau (R8)** : aucun `forwarded_port` supplémentaire. Grafana (`:3000`), Prometheus (`:9090`), node_exporter (`:9100`) et les métriques HAProxy (`:8405`) ne sont joignables que sur le réseau privé `192.168.X.0/24` ; l'hôte y accède directement.
5. **Budget mémoire** : `obs` (768 Mo) est déclarée `autostart: false`. Le socle de 3 Go n'est pas modifié ; on la démarre à la demande avec `vagrant up obs`.
6. **Mesurer, pas affirmer** : chaque scénario enregistre dans `resultats/` la commande exacte, le résultat brut, les chronomètres et un verdict, prêts à coller dans le dossier d'architecture (L2).

## 2. Arborescence ajoutée

```
.
├── scripts/
│   ├── obs.sh                      # Prometheus + Grafana sur obs
│   ├── gen_prometheus_config.py    # noeuds.yml -> prometheus.yml
│   ├── node_exporter.sh            # sur chaque VM
│   └── lb-metrics.sh               # expose /metrics d'HAProxy (port 8405)
├── config/grafana/
│   ├── datasource.yml              # source de données Prometheus
│   ├── dashboards.yml              # chargement automatique du tableau de bord
│   └── resultats-bf.json           # tableau de bord (10 panneaux)
├── tests/
│   ├── lib.sh                      # fonctions communes (ne pas exécuter)
│   ├── v1_repartition.sh … v6_panne_repartiteur.sh
│   ├── run_all.sh
│   └── r2_idempotence.sh
├── resultats/                      # rapports engendrés (à versionner : ce sont vos preuves)
├── .env.exemple
├── .gitattributes.ajouts  .gitignore.ajouts
└── Vagrantfile.modifications.rb    # guide de copier-coller (pas à exécuter)
```

## 3. Hypothèses sur le reste du projet — **à vérifier**

Les autres rôles sont terminés ; voici ce que ces scripts supposent d'eux. Si l'un des points diffère, la colonne de droite dit quoi ajuster.

| Hypothèse | Si ce n'est pas le cas |
|---|---|
| `config/noeuds.yml` est celui de l'annexe A (`Hash#to_yaml` : clés `:nom`, `:ip`, `:role`) | `gen_prometheus_config.py` accepte aussi des clés sans `:` ; il faut seulement `nom`, `ip`, `role` |
| Le rôle des serveurs applicatifs s'appelle `app`, celui des répartiteurs commence par `lb` | adapter `startswith("lb")` dans le générateur et les `grep`/`awk` de `tests/lib.sh` |
| La configuration HAProxy est `/etc/haproxy/haproxy.cfg` et HAProxy ≥ 2.4 (Ubuntu 24.04 : 2.8) | `HAPROXY_CFG=… ` ou intégrer le bloc dans votre gabarit (voir §5.3) |
| L'application a un `/info` qui renvoie un texte contenant `appN` (nom d'hôte) | variable `HOST_REGEX` |
| Un matricule existe dans la table | variable `MATRICULE` (V3, V4, V5) |
| L'ingénieur données a écrit une procédure de bascule exécutable | variable `BASCULE_CMD` (V4) |
| Le script du répartiteur ne crée pas déjà un frontend sur le port 8405 | choisir un autre port (`HAPROXY_METRICS_PORT` dans `lb-metrics.sh` **et** `obs.sh`) |
| `config/noeuds.yml` contient désormais une ligne `obs` : le script du répartiteur doit **ne prendre que `role == "app"`** | filtrer dans le script du répartiteur |

## 4. Installation pas à pas

**Étape 1 — Copier les fichiers** dans le dépôt (racine = dossier du `Vagrantfile`), puis les rendre exécutables :

```bash
chmod +x scripts/*.sh scripts/*.py tests/*.sh
```

**Étape 2 — Fins de ligne et secrets.** Ajouter le contenu de `.gitattributes.ajouts` à `.gitattributes` et celui de `.gitignore.ajouts` à `.gitignore` (piège n°5 du sujet : un script en CRLF échoue dans la VM).

**Étape 3 — Créer `.env`** (jamais commité) :

```bash
cp .env.exemple .env
# éditer .env : choisir GRAFANA_ADMIN_PASSWORD
```

Versionner `.env.exemple` (sans vrai mot de passe), pas `.env`.

**Étape 4 — Modifier le Vagrantfile** en reportant les trois blocs de `Vagrantfile.modifications.rb` : (1) chargement de `.env` s'il n'existe pas déjà, (2) une ligne `obs` dans `NOEUDS`, (3) dans la boucle : `autostart: false` pour `obs`, `env:` pour le mot de passe, et les provisionneurs `lb-metrics.sh` (répartiteurs) et `node_exporter.sh` (toutes les VM sauf `obs`). L'ordre des provisionneurs compte : `lb-metrics.sh` doit venir **après** le script du répartiteur.

**Étape 5 — Déployer.** Exporter une fois pour toutes les variables de session (sinon le Vagrantfile réécrit `noeuds.yml` avec d'autres valeurs) :

```bash
export GROUPE=4            # votre numéro de groupe
export NB_APP=2
vagrant up                 # socle ; node_exporter et métriques HAProxy sont installés au passage
vagrant up obs             # supervision (démarrer lb2 avant si E1)
```

Pour les machines déjà créées avant l'ajout : `vagrant provision` (idempotent).

**Étape 6 — Vérifier** (remplacer `X` par `55 + GROUPE`) :

```bash
curl -s http://192.168.X.11:8405/metrics | grep -c '^haproxy_'     # > 0 : métriques HAProxy exposées
curl -s http://192.168.X.21:9100/metrics | grep -c '^node_'        # > 0 : node_exporter
```

Dans le navigateur de l'hôte :

* Prometheus : `http://192.168.X.41:9090` → *Status → Targets* : toutes les cibles `UP` (jobs `node`, `haproxy`, `prometheus`).
* Grafana : `http://192.168.X.41:3000` → utilisateur `admin`, mot de passe du `.env` → dossier **RESULTATS-BF** → *RESULTATS-BF - Infrastructure*.

## 5. Détail des configurations

### 5.1 `scripts/obs.sh`

Dans l'ordre : (1) dépôt apt Grafana + **un seul** `apt-get update` / `install` pour `grafana prometheus prometheus-node-exporter python3-yaml apache2-utils` (connexion lente) ; (2) `node_exporter` sur `obs` ; (3) génération et validation (`promtool check config`) de `prometheus.yml`, rétention limitée à 2 jours pour tenir dans 768 Mo, écoute sur `0.0.0.0:9090` ; (4) Grafana : mot de passe via un fichier d'environnement systemd `0600`, provisionnement de la source de données et du tableau de bord, attente de l'API puis vérification du mot de passe. `apache2-utils` fournit `ab` dans la VM, utile si votre poste n'en a pas (§6).

### 5.2 Prometheus (`gen_prometheus_config.py`)

Intervalle de collecte **5 s** (pour voir une panne en quelques secondes sur le tableau de bord). Trois jobs : `prometheus` (lui-même), `node` (port 9100 de **toutes** les entrées de `noeuds.yml`, avec les étiquettes `nom` et `role`), `haproxy` (port 8405 des machines dont le rôle commence par `lb`). Un serveur ajouté via `NB_APP` apparaît donc seul après `vagrant provision obs`.

### 5.3 Métriques HAProxy (`lb-metrics.sh`)

HAProxy 2.8 embarque l'exporter Prometheus. Le script ajoute, entre deux marqueurs, un `frontend metrics_prometheus` sur le port 8405 (`use-service prometheus-exporter`), valide la configuration avec `haproxy -c`, recharge, et **revient en arrière** si elle est invalide. Le port n'est pas redirigé vers l'hôte (R8).

*Alternative plus propre* : si l'architecte réseau préfère, coller directement ce bloc dans son gabarit de `haproxy.cfg` et ne pas utiliser `lb-metrics.sh` :

```
frontend metrics_prometheus
    bind *:8405
    mode http
    http-request use-service prometheus-exporter if { path /metrics }
    no log
```

### 5.4 `node_exporter.sh`

Installe le paquet Ubuntu `prometheus-node-exporter` et le fait écouter sur `:9100` (et non `127.0.0.1` — piège n°1 du sujet). Collecte CPU, mémoire, réseau, disque.

### 5.5 Grafana — tableau de bord

Rafraîchi toutes les 5 s, fenêtre 15 min, rechargé automatiquement si `resultats-bf.json` change.

| Panneau | Sert à démontrer |
|---|---|
| Machines (node_exporter) UP / DOWN | une machine **disparaît** pendant la panne (V2, V4, V6) |
| Serveurs applicatifs vus par HAProxy | la sonde `/sante` écarte le serveur défaillant (R4) |
| Requêtes/s reçues par le répartiteur | le **débit monte** pendant la charge (V3) |
| Réponses HTTP par code | les 5xx = période dégradée (V2, V4) |
| Sessions, temps de réponse moyen, serveurs actifs | comportement sous charge |
| CPU, mémoire, réseau par machine | explication des résultats V3 (saturation du CPU partagé) |

Les noms de métriques HAProxy sont ceux de l'exporter intégré (`haproxy_frontend_http_requests_total`, `haproxy_server_status`, …). S'il manque une courbe, copier le nom exact depuis `curl http://192.168.X.11:8405/metrics`.

## 6. Scénarios de validation V1 à V6

**Prérequis sur le poste hôte** : `bash`, `curl`, `awk`, `vagrant`, `date` GNU (Linux, WSL ou Git Bash — pas le Terminal macOS standard). `ab` : `sudo apt install apache2-utils` ; à défaut, les scripts lancent `ab` **depuis la VM `obs`** (démarrée au préalable), ou `USE_OBS=1` pour le forcer.

Toujours lancer depuis la racine du dépôt, avec `GROUPE` et `NB_APP` exportés comme à l'étape 5. Chaque script écrit `resultats/<scénario>_<horodatage>.txt` et se termine par un verdict (code retour 0 = succès).

| Script | Ce qu'il fait | Mesure produite | Critère |
|---|---|---|---|
| `v1_repartition.sh` | 20 `curl` successifs sur `/info` | requêtes par serveur, écart max–min | tous les serveurs vus, écart < 20 % |
| `v2_panne_app.sh` | sonde à 10 req/s ; `vagrant halt --force app1` en pleine charge ; remise en service | requêtes en erreur, période dégradée, hôtes servis avant/après | aucune erreur > 5 s après l'arrêt, `app1` écarté |
| `v3_montee_en_charge.sh [N…]` | pour chaque N (défaut `2 4`) : `vagrant up`, re-provisionne le répartiteur (et `obs`), échauffement, 3 × `ab -n 2000 -c 50` sur `/resultat?matricule=…` | req/s, temps moyen, p50/p95/p99, échecs, non-2xx, médiane par N, fenêtre horaire pour Grafana | 0 erreur ; le débit médian est comparé (indicatif) |
| `v4_panne_base.sh` | `vagrant halt --force bdd1` ; contrôle des 503 (app directe, via le répartiteur, `/resultat`) ; exécute `BASCULE_CMD` ; chronomètre | délais panne→503, durée de la bascule, panne→`/resultat` de nouveau 200 | 503 propre et corps non vide, bascule OK, `bdd2` promue |
| `v5_reconstruction.sh` | `vagrant destroy -f` puis `vagrant up` ; vérifie santé, répartition, réplication | durée destroy / up / total | plateforme fonctionnelle sans intervention |
| `v6_panne_repartiteur.sh` | sonde sur l'IP virtuelle `.5` ; `vagrant halt --force lb1` | plus longue interruption (reprise VRRP) | service joignable à la même adresse, < 5 s |

```bash
./tests/v1_repartition.sh
./tests/v2_panne_app.sh
./tests/v3_montee_en_charge.sh            # N=2 puis N=4 (ordre croissant)
./tests/v6_panne_repartiteur.sh           # nécessite E1 (lb2 démarrée)
./tests/v4_panne_base.sh                  # laisse bdd1 arrêtée
./tests/v5_reconstruction.sh              # DÉTRUIT tout puis reconstruit : à lancer après V4
./tests/run_all.sh                        # V1, V2, V3 (N courant), V6 — non destructif
./tests/run_all.sh --complet              # tout, dans le bon ordre (V4 puis V5)
./tests/r2_idempotence.sh                 # rejoue vagrant provision 2 fois et compare les empreintes
```

### Variables utiles

| Variable | Défaut | Rôle |
|---|---|---|
| `BASE_URL` | auto : `http://192.168.X.5`, sinon `.11`, sinon `localhost:8080` | adresse testée |
| `MATRICULE` | `1` | matricule existant (**à adapter**, sinon V3 signale une route en erreur) |
| `HOST_REGEX` | `app[0-9]+` | motif du nom d'hôte renvoyé par `/info` |
| `BASCULE_CMD` | `vagrant ssh bdd2 -c 'sudo /vagrant/scripts/bascule.sh'` | **à adapter** à la procédure de l'ingénieur données |
| `HALT_FORCE` | `1` | `1` = arrêt brutal (vraie panne) ; `0` = arrêt propre |
| `CIBLE`, `PRE_DURATION`, `POST_DURATION` | `app1`, 5, 30 | réglages de V2 |
| `RUNS`, `REQUETES`, `CONCURRENCE`, `ROUTE`, `SKIP_SCALE`, `USE_OBS` | 3, 2000, 50, … | réglages de V3 |
| `YES=1` | — | ne pas demander confirmation (V4, V5) |

### Comment lire les chronomètres

* **t0** est l'instant où la commande `vagrant halt` est lancée, pas celui où la VM cesse de répondre : la durée mesurée inclut donc le temps d'arrêt de la VM. Le dire dans le dossier.
* La sonde de V2/V6 émet environ 10 requêtes/s : la précision des durées est d'environ 0,1 à 0,2 s.
* Pour V2, le répartiteur à tourniquet envoie environ 1 requête sur N au serveur tombé tant qu'il n'est pas écarté : « période dégradée » = de la première à la dernière erreur ; « plus longue série d'erreurs consécutives » est plus courte puisque les erreurs sont entrecoupées de succès.

## 7. Campagne de mesures recommandée (semaine 4)

1. `vagrant up` + `vagrant up obs`, ouvrir Grafana sur un second écran.
2. Redémarrer une plateforme propre, puis `V1` → `V2` → `V3` → `V6` (E1) → `V4`, enfin `V5`.
3. Pendant V2, V3 et V6, **capturer le tableau de bord** : c'est la démonstration de l'extension E2 (« le débit monte pendant la charge, un serveur disparaît pendant la panne »). V3 affiche la fenêtre horaire à capturer.
4. Répéter au moins une fois chaque mesure et garder les deux rapports : le barème pénalise de 4 points des mesures « non reproductibles ou manifestement inventées ». Ne jamais retoucher un rapport à la main.
5. Dans le dossier (L2), un tableau par scénario : commande, résultat brut (extrait du rapport), commentaire.

### Honnêteté des mesures (V3)

Les VM, le répartiteur et `ab` (s'il tourne sur l'hôte) se partagent le même processeur. Passer de 2 à 4 serveurs ne doublera pas le débit et peut même le réduire : c'est un **résultat à expliquer** (panneau CPU du tableau de bord) et non un échec. Si vous constatez ce plafonnement, indiquez-le tel quel.

## 8. Rotation des rôles et Git

Le sujet exige qu'**au moins un commit significatif de chaque membre porte hors de son domaine**. Suggestion : faire relire et exécuter `tests/` à l'ingénieur applicatif, et faire écrire à l'ingénieur essais le bloc `lb-metrics` directement dans le gabarit du répartiteur. Ne jamais commiter `.env`.

## 9. Dépannage

| Symptôme | Cause probable et correction |
|---|---|
| `obs.sh` : « GRAFANA_ADMIN_PASSWORD absent » | `.env` manquant, ou bloc `env:` absent du Vagrantfile, ou la machine a été lancée dans un shell sans le `.env` lu |
| Cible `haproxy` DOWN dans Prometheus | `lb-metrics.sh` non exécuté (ordre des provisionneurs), ou HAProxy sans exporter (`haproxy -vv \| grep -i prometheus`) |
| Cible `node` DOWN pour une VM | `node_exporter.sh` non rejoué sur cette VM : `vagrant provision <vm>` |
| Nouveau serveur absent de Prometheus | rejouer `vagrant provision obs` (V3 le fait automatiquement si `obs` tourne) |
| Panneau HAProxy vide | nom de métrique différent : vérifier dans `/metrics` |
| `apt.grafana.com` inaccessible | pare-feu / connexion de la salle ; alternative : télécharger le `.deb` de Grafana une fois et l'installer avec `dpkg -i` dans `obs.sh` |
| `vagrant halt app1` affiche « machine not found » | `NB_APP`/`GROUPE` non exportés : le Vagrantfile ne connaît pas la machine |
| V3 : `Non-2xx responses` | mauvais `MATRICULE` ou `ROUTE` |
| V3 : `ab` introuvable | installer `apache2-utils` ou démarrer `obs` (fallback automatique) |
| V6 : « IP virtuelle injoignable » | E1 non active : `vagrant up lb2` |
| V4 : la bascule échoue | `BASCULE_CMD` ne correspond pas au script de l'ingénieur données |
| Écarts R2 | un script de rôle utilise `>>` (accumulation) ; piège n°2 du sujet |

## 10. Correspondance avec le barème

| Critère | Apporté par cette partie |
|---|---|
| Reconstruction (R1) | `obs` se reconstruit sans geste manuel ; V5 chronomètre la reconstruction |
| Scalabilité (R3) | cibles Prometheus engendrées depuis `noeuds.yml`, aucune adresse en dur |
| Résilience (R4–R6) | V2, V4 et V6 prouvent et mesurent le comportement |
| Qualité technique (R2, R7, R8) | idempotence testée (`r2_idempotence.sh`), mot de passe via `.env`, pas de port exposé |
| Extensions | E2 complète (Prometheus, node_exporter, Grafana) |
| Dossier et mesures | rapports horodatés prêts à citer |
