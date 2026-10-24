# 🎓 RESULTATS-BF

### Consultez un résultat d'examen en une seconde, sur une infrastructure qui ne tombe jamais.

> Tapez un matricule. Obtenez un résultat. Pendant ce temps, **9 serveurs virtuels** travaillent en coulisses, se surveillent entre eux, et se remplacent automatiquement en cas de panne, le tout lancé avec **une seule commande**.

![Vagrant](https://img.shields.io/badge/Vagrant-automatisé-1868F2?logo=vagrant&logoColor=white)
![HAProxy](https://img.shields.io/badge/HAProxy-répartition%20de%20charge-0F9D58)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-336791?logo=postgresql&logoColor=white)
![Flask](https://img.shields.io/badge/Flask-Gunicorn-000000?logo=flask&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-Grafana-E6522C?logo=prometheus&logoColor=white)

---

## 📑 Sommaire

1. [Le projet en 30 secondes](#-le-projet-en-30-secondes)
2. [Ce que vous allez construire](#-ce-que-vous-allez-construire)
3. [Comprendre sans être informaticien](#-comprendre-sans-être-informaticien)
4. [Étape 0 : Installer les prérequis](#-étape-0--installer-les-prérequis)
5. [Étape 1 : Configurer le projet](#-étape-1--configurer-le-projet)
6. [Étape 2 : Démarrer l'infrastructure](#-étape-2--démarrer-linfrastructure)
7. [Étape 3 : Tester dans le navigateur](#-étape-3--tester-dans-le-navigateur)
8. [Étape 4 : Valider avec les tests automatisés](#-étape-4--valider-avec-les-tests-automatisés)
9. [Étape 5 : Mettre à jour sans coupure](#-étape-5--mettre-à-jour-sans-coupure)
10. [Mettre en pause, arrêter, tout effacer](#-mettre-en-pause-arrêter-tout-effacer)
11. [L'équipe derrière le projet](#-léquipe-derrière-le-projet)
12. [Dépannage rapide](#-dépannage-rapide)

---

## ⚡ Le projet en 30 secondes

| | |
|---|---|
| **Le besoin** | Un candidat saisit son matricule (ex : `MAT000001`) et voit son résultat |
| **Le défi** | Des milliers de candidats connectés en même temps, sans jamais de panne |
| **La solution** | Une architecture **n-tiers haute disponibilité**, isolée et 100 % automatisée |
| **Votre effort** | Installer 3 outils, copier un fichier, taper `vagrant up` |
| **Durée du premier démarrage** | ⏳ 10 à 15 minutes |

---

## 🏗️ Ce que vous allez construire

Une mini-infrastructure professionnelle, **entièrement sur votre ordinateur**.

### 📐 Schéma d'architecture

```text
                    [ Client / Navigateur Web ]
                                 |
                                 v
                   http://localhost:8080 (port hôte)
                                 |
+-----------------------------------------------------------------+
|                    RÉSEAU PRIVÉ VIRTUEL                         |
|                  (sous-réseau 192.168.63.0/24)                  |
|                                                                 |
|  +-----------------------------------------------------------+  |
|  |                  IP VIRTUELLE (VRRP)                      |  |
|  |                     192.168.63.5                          |  |
|  +-----------------------------+-----------------------------+  |
|                                |                                |
|            +-------------------+-------------------+            |
|            |                                       |            |
|            v                                       v            |
|    +----------------+                      +----------------+   |
|    |  lb1 (MASTER)  |                      |  lb2 (BACKUP)  |   |
|    | 192.168.63.11  |                      | 192.168.63.12  |   |
|    |    HAProxy     |                      |    HAProxy     |   |
|    +-------+--------+                      +--------+-------+   |
|            |                                        |           |
|            +-------------------+--------------------+           |
|                                | (Round-Robin)                  |
|        +-----------------------+-----------------------+        |
|        |                       |                       |        |
|        v                       v                       v        |
|  +------------+          +------------+          +------------+ |
|  |    app1    |          |    app2    |          |    app3    | |
|  | .63.21:3000|          | .63.22:3000|          | .63.23:3000| |
|  | Flask/Guni.|          | Flask/Guni.|          | Flask/Guni.| |
|  +-----+------+          +-----+------+          +-----+------+ |
|        |                       |                       |        |
|        +-----------------------+-----------------------+        |
|                                |                                |
|                   +------------+------------+                   |
|                   |                         |                   |
|                   v (lecture / écriture)    v (réplication)     |
|          +------------------+     +------------------+          |
|          |  bdd1 (primaire) |---->|  bdd2 (réplique) |          |
|          |  192.168.63.31   |     |  192.168.63.32   |          |
|          |  PostgreSQL 16   |     |  PostgreSQL 16   |          |
|          +------------------+     +------------------+          |
|                                                                 |
|  +-----------------------------------------------------------+  |
|  |                      SUPERVISION                          |  |
|  |                      obs (.63.41)                         |  |
|  |            Prometheus (9090) + Grafana (3000)             |  |
|  +-----------------------------------------------------------+  |
+-----------------------------------------------------------------+
```

### 🌐 La carte des machines

| Machine | Adresse IP | Rôle | Détails |
|---|---|---|---|
| 🌍 **VIP** | `192.168.63.5` | IP virtuelle partagée | Bascule automatique via Keepalived |
| ⚖️ **`lb1`** | `192.168.63.11` | Répartiteur principal | HAProxy + Keepalived (Master) |
| 🛟 **`lb2`** | `192.168.63.12` | Répartiteur de secours | HAProxy + Keepalived (Backup), *Extension E1* |
| 🧠 **`app1`** | `192.168.63.21` | Serveur applicatif 1 | Python Flask + Gunicorn (port 3000) |
| 🧠 **`app2`** | `192.168.63.22` | Serveur applicatif 2 | Python Flask + Gunicorn (port 3000) |
| 🧠 **`app3`** | `192.168.63.23` | Serveur applicatif 3 | Python Flask + Gunicorn (port 3000) |
| 🗄️ **`bdd1`** | `192.168.63.31` | Base de données principale | PostgreSQL 16 (primaire) |
| 🗄️ **`bdd2`** | `192.168.63.32` | Base de données secondaire | PostgreSQL 16 (réplique en flux) |
| 📊 **`obs`** | `192.168.63.41` | Supervision et métriques | Prometheus + Grafana, *Extension E2* |

### 🔄 Le voyage d'une requête

1. **🚪 Entrée du trafic.** Le candidat ouvre `http://localhost:8080/resultat?matricule=MAT000001`. Le port `8080` de votre ordinateur redirige vers le port `80` du répartiteur `lb1`.
2. **⚖️ Répartition.** HAProxy distribue les demandes entre `app1`, `app2` et `app3` en *Round-Robin* (chacun son tour).
3. **🩺 Contrôle de santé.** HAProxy interroge en continu l'endpoint `/sante`. Un nœud défaillant est **retiré de la rotation instantanément**.
4. **🗄️ Traitement.** L'application Flask (sans état) interroge `bdd1`. Si `bdd1` tombe, un script de bascule **promeut `bdd2` en nouveau primaire** et met à jour les applicatifs, sans perte de données.

> 💪 **Ce qui rend ce projet solide :** deux répartiteurs, trois serveurs applicatifs, deux bases synchronisées. Il n'existe aucun point de défaillance unique.

---

## 💡 Comprendre sans être informaticien

Imaginez une **grande administration** installée dans votre ordinateur :

| Composant | Dans la vraie vie | Son travail |
|---|---|---|
| ⚖️ **Répartiteurs** (`lb1`, `lb2`) | Les guichets d'accueil | Reçoivent les candidats et les orientent équitablement pour éviter les files d'attente |
| 🧠 **Serveurs applicatifs** (`app1`, `app2`, `app3`) | Les agents administratifs | Cherchent le résultat et préparent la réponse |
| 🗄️ **Bases de données** (`bdd1`, `bdd2`) | Le service d'archives | `bdd1` garde les **50 000 candidats** ; `bdd2` en est la copie conforme en temps réel |
| 📊 **Observabilité** (`obs`) | La salle de contrôle | Surveille que tout fonctionne, en direct |

Et la magie de **Vagrant** : toute cette administration se construit **toute seule**, sans installer chaque serveur à la main.

---

## 🛠️ Étape 0 : Installer les prérequis

> 🧰 Trois outils à installer, **une seule fois**. Comptez environ 15 minutes.

### 1️⃣ VirtualBox, le moteur de virtualisation

Il fait tourner les serveurs Linux virtuels sur votre PC Windows.

1. Rendez-vous sur [virtualbox.org/wiki/Downloads](https://www.virtualbox.org/wiki/Downloads) et cliquez sur **Windows hosts**.
2. Double-cliquez sur l'installateur (`VirtualBox-7.x.x-Win.exe`).
3. Cliquez sur **Next** à chaque écran, sans changer les options.
4. Si Windows avertit à propos des interfaces réseau, cliquez sur **Yes**.
5. Cliquez sur **Install**, puis **Finish**.

### 2️⃣ Vagrant, le chef d'orchestre

Il lit le fichier `Vagrantfile` et crée tous les serveurs à votre place.

1. Allez sur [developer.hashicorp.com/vagrant/install](https://developer.hashicorp.com/vagrant/install), onglet **Windows**, version **AMD64 / 64-bit**.
2. Double-cliquez sur le fichier `.msi`, acceptez la licence, puis **Next** jusqu'à **Finish**.
3. ♻️ **Redémarrez votre ordinateur** quand l'installateur le demande.

### 3️⃣ Git pour Windows, le terminal indispensable

Il fournit **Git Bash**, nécessaire pour lancer les scripts de validation.

1. Allez sur [git-scm.com/download/win](https://git-scm.com/download/win). Le téléchargement démarre tout seul.
2. Lancez l'installateur, gardez toutes les options par défaut, puis **Install** et **Finish**.

### ✅ Le moment de vérité

Après redémarrage, ouvrez **Windows PowerShell** (touche Windows, tapez `PowerShell`) et lancez :

```powershell
VBoxManage --version
vagrant --version
git --version
```

| Résultat | Signification |
|---|---|
| 🟢 Trois numéros de version (ex : `7.0.12`, `2.4.1`, `2.43.0`) | **Bravo, votre PC est prêt à 100 % !** |
| 🔴 Texte rouge « commande non reconnue » | Redémarrez le PC pour activer les variables d'environnement |

---

## 🚀 Étape 1 : Configurer le projet

### 1.1 Ouvrir le dossier du projet

Dans PowerShell, placez-vous dans le dossier :

```powershell
cd "C:\chemin\vers\votre\dossier\GOUPE8_RESULTATS-BF---Vagrant"
```

### 1.2 Créer votre fichier de secrets `.env`

L'application a besoin d'un fichier de mots de passe pour protéger la base de données. Un modèle, `.env.exemple`, est déjà fourni.

```powershell
# 1. Copier le modèle
Copy-Item .env.exemple .env

# 2. Ouvrir le fichier pour vérifier ou modifier les valeurs
notepad .env
```

| Variable | Rôle |
|---|---|
| `DB_HOST` | Adresse du serveur de base de données (si vide, lit `config/noeuds.yml`) |
| `DB_PORT` | Port de communication (défaut : `5432`) |
| `DB_USER` | Utilisateur autorisé à lire les résultats (`resultats`) |
| `DB_PASS` | Mot de passe de la base de données |
| `DB_NAME` | Nom de la base contenant la table `resultats` |
| `VRRP_PASS` | Mot de passe de la haute disponibilité entre répartiteurs |
| `GRAFANA_ADMIN_PASSWORD` | Mot de passe d'accès à Grafana |

Enregistrez et fermez le Bloc-notes.

> 🔒 **Bon à savoir :** le fichier `.env` reste **uniquement sur votre ordinateur**. Il n'est jamais envoyé sur Git.

---

## ⚙️ Étape 2 : Démarrer l'infrastructure

Deux commandes suffisent pour créer **9 serveurs**.

**2.1 Vérifier la configuration**

```powershell
vagrant validate
```

✅ Attendu : `Vagrantfile validated successfully!`

**2.2 Tout créer et démarrer**

```powershell
vagrant up
```

> ⏳ **Patience :** au premier lancement, comptez **10 à 15 minutes**. Vagrant télécharge le système d'exploitation et installe tout automatiquement. C'est le bon moment pour un café ☕.

---

## 🔍 Étape 3 : Tester dans le navigateur

Le répartiteur est accessible sur **`http://localhost:8080`**. Trois tests, trois preuves que tout fonctionne.

### 🧪 Test 1 : Voir la charge se répartir

Ouvrez **http://localhost:8080/info**, puis appuyez plusieurs fois sur **F5**.

> 🎯 Le nom du serveur change (`app1`, `app2`...) : la charge est bien répartie.

### 🩺 Test 2 : Vérifier la santé

Ouvrez **http://localhost:8080/sante**

> 🎯 Réponse `200 OK` avec `{"statut": "OK"}` : la base PostgreSQL répond correctement.

### 🎓 Test 3 : Consulter un résultat

Ouvrez **http://localhost:8080/resultat?matricule=MAT000001**

> 🎯 L'application cherche `MAT000001` parmi les 50 000 candidats.

### 📬 Comprendre les réponses

| Code | Signification |
|---|---|
| ✅ **200 OK** | Matricule trouvé, résultat renvoyé en JSON |
| ⚠️ **400 Bad Request** | Format du matricule invalide |
| 🔎 **404 Not Found** | Matricule bien écrit, mais candidat inexistant |
| 🚨 **503 Service Unavailable** | Panne de la base de données ou du service |

---

## 🧪 Étape 4 : Valider avec les tests automatisés

### 4.1 Tests unitaires (sans base de données réelle)

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s app -p "test_*.py"
```

### 4.2 Inspecter un serveur de l'intérieur

```powershell
vagrant ssh app1
```

Puis, dans le serveur :

```bash
sudo systemctl status app.service --no-pager
curl -i http://127.0.0.1:3000/sante
exit
```

### 4.3 La suite de tests globale

Depuis **Git Bash** ou **WSL**, à la racine du projet :

```bash
./tests/run_all.sh
```

Elle valide l'ensemble du système, du `tests/v1_repartition.sh` au `tests/v6_panne_repartiteur.sh`.

---

## 🔄 Étape 5 : Mettre à jour sans coupure

Le **déploiement sans interruption** (*Zero Downtime Deployment*) met à jour le code **serveur par serveur**, pendant que les utilisateurs continuent à consulter leurs résultats sans rien remarquer.

1. Vérifiez que l'application et la base fonctionnent parfaitement.
2. Lancez le script :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-app.ps1
```

> 🛡️ Le script met à jour chaque serveur applicatif l'un après l'autre et **attend que `/sante` réponde positivement** avant de passer au suivant.

---

## 🛑 Mettre en pause, arrêter, tout effacer

| Je veux... | Commande |
|---|---|
| ⏸️ Mettre en pause (état conservé, aucun processeur utilisé) | `vagrant suspend` |
| 🔌 Arrêter proprement | `vagrant halt` |
| ▶️ Redémarrer | `vagrant reload` |
| 💣 Tout supprimer et repartir de zéro | `vagrant destroy -f` |

---

## 🤝 L'équipe derrière le projet

RESULTATS-BF repose sur **4 rôles complémentaires** :

| Rôle | Mission |
|---|---|
| 🌐 **Architecte Réseau & HA** | Fournit HAProxy, l'IP virtuelle Keepalived et la sonde de santé `/sante` |
| 💻 **Ingénieur Applicatif** | Développe le microservice Flask/Gunicorn *stateless* : un serveur peut entrer ou sortir de la rotation à tout moment |
| 🗄️ **Ingénieur Données** | Déploie PostgreSQL 16, génère les 50 000 candidats, assure la réplication `bdd1` → `bdd2` et la bascule automatique |
| 📊 **Ingénieur Essais & Observabilité** | Configure Prometheus/Grafana et écrit les scripts de validation (`v1` à `v6`) |

---

## 🩹 Dépannage rapide

| Symptôme | Solution |
|---|---|
| `commande non reconnue` dans PowerShell | Redémarrez le PC, puis relancez les vérifications de version |
| `vagrant validate` échoue | Vérifiez que vous êtes bien dans le dossier du projet (`cd ...`) |
| Le premier `vagrant up` semble bloqué | Normal : attendez 10 à 15 minutes (téléchargements) |
| `/sante` renvoie `503` | Vérifiez le fichier `.env` et l'état de `bdd1` (`vagrant status`) |
| Tout est cassé | `vagrant destroy -f` puis `vagrant up` : retour à zéro propre |

---

<p align="center">
  <b>🎓 RESULTATS-BF</b> · Projet de groupe · M1 Informatique, IBAM · Université Joseph Ki-Zerbo<br>
  <i>Une infrastructure qui ne dort jamais, pour que chaque candidat trouve son résultat.</i>
</p>
