# Données : PostgreSQL, jeu de données, réplication (partie de l'ingénieur données)

Cette section alimente le dossier d'architecture (L2) ; la procédure de bascule est détaillée
dans `docs/bascule.md`. Tous les chiffres viennent d'essais réels sur un PC Windows avec
VirtualBox ; ils sont donnés comme ordres de grandeur.

## 1. Rôle et choix

- **PostgreSQL 16** (paquet Ubuntu 24.04) sur deux machines : `bdd1` (primaire, `.31`) et
  `bdd2` (réplique, `.32`) sur le réseau `192.168.63.0/24` du groupe 8.
- **Réplication en flux asynchrone** (streaming replication). Raison : c'est le mécanisme
  natif, sans logiciel supplémentaire, et la lecture sur la réplique reste possible.
  Contrepartie assumée : les dernières écritures peuvent être perdues si le primaire tombe.
- **Une seule source de vérité pour les adresses** : les scripts lisent `config/noeuds.yml`,
  engendré par le Vagrantfile. Aucune adresse n'est écrite en dur dans mes scripts.

## 2. Jeu de données

Table `resultats(matricule, nom, serie, moyenne, admis)` avec 50 000 candidats
(`MAT000001` à `MAT050000`), engendrés en SQL avec `generate_series`. Une graine fixe
(`setseed`) rend la génération reproductible à chaque reconstruction ; seul le nombre de
lignes est vérifié par les tests, pas chaque valeur. Le peuplement est conditionné
(`ON CONFLICT DO NOTHING`) : le rejouer n'ajoute rien.

## 3. Sécurité et secrets (R7, R8)

- Aucun secret dans le dépôt : `DB_USER`, `DB_NAME` et `DB_PASS` viennent du fichier `.env`
  local (ignoré par Git) ; `.env.exemple` documente les variables. Le Vagrantfile les passe
  aux seules machines qui en ont besoin ; mes scripts relisent aussi `/vagrant/.env`.
- Accès à PostgreSQL limité au réseau privé du groupe (`pg_hba.conf`, authentification
  `scram-sha-256`). Aucun port de base n'est publié sur l'hôte.

## 4. Idempotence (R2)

Les scripts de base (`bdd.sh`, `replique.sh`) peuvent être rejoués sans effet. Moyens :
fichier de configuration à nous (`conf.d/90-resultats-bf.conf`) réécrit à chaque passage,
lignes de `pg_hba.conf` repérées par un marqueur et recréées, création des rôles et de la
base conditionnelle, et la réplique ne refait pas sa copie si `standby.signal` existe.

**Preuve** (`r2.ps1`) : empreinte de `pg_hba.conf` et de la configuration, nombre de lignes
marquées, mode réplique et nombre de lignes de la table sont relevés avant, après un rejeu
et après deux rejeux. Résultat : identiques à chaque fois (R2 validé), y compris après
retour aux rôles d'origine.

## 5. Réplication (R5)

**Preuve** (`r5.ps1`), sur machines reconstruites : `bdd2` est en mode réplique,
`pg_stat_replication` montre `192.168.63.32 | streaming | async` ; une ligne écrite sur
`bdd1` apparaît sur `bdd2` (la mesure de 9 à 18 s inclut les appels `vagrant ssh`, elle
ne reflète pas le retard de réplication) ; une écriture sur `bdd2` est refusée
(`cannot execute INSERT in a read-only transaction`).

## 6. Bascule (R6)

Procédure automatisée (`bascule.ps1`, `reintegrer.ps1`), décrite et mesurée dans
`docs/bascule.md`. Résumé : la promotion PostgreSQL prend environ une seconde ; la
procédure complète 100 à 110 s, dont l'essentiel est le temps des appels `vagrant ssh`.
Validée dans les deux sens (bdd2 promue puis bdd1 réintégrée, et l'inverse).

## 7. Difficultés rencontrées

- **Boîte Vagrant** : la version imposée par le sujet n'existe plus pour VirtualBox ;
  corrigée par l'architecte (version plus récente, architecture précisée).
- **Fins de ligne Windows** : le fichier `noeuds.yml` écrit par Ruby contient des retours
  chariot (CRLF) qui faussaient la lecture des adresses dans mes scripts. Corrigé.
- **Retour en réplique impossible au premier essai** : `bdd1` refusait de redémarrer en
  réplique de `bdd2` (`max_wal_senders = 5` plus petit que la valeur 10 du primaire).
  Cause : réglages différents entre les deux machines. Corrigé en leur donnant les mêmes
  valeurs ; le test R5 d'origine, à sens unique, ne pouvait pas le révéler.
- **Après une bascule, `vagrant provision` échoue** sur la réplique (écriture refusée) :
  limite connue, documentée ; on revient à l'état initial par une bascule inverse ou par
  `vagrant destroy -f` puis `vagrant up`.

## 8. Limites et ce que nous ferions autrement

- Réplication asynchrone : risque de perte des dernières transactions. Une réplication
  synchrone supprimerait ce risque au prix d'écritures plus lentes et d'une dépendance à
  la réplique.
- Bascule déclenchée à la main. Un outil comme Patroni ou repmgr la rendrait automatique,
  avec élection du primaire pour éviter deux primaires simultanés.
- Réintégration par copie complète (`pg_basebackup`) : simple mais lente si la base grossit ;
  `pg_rewind` permettrait de ne recopier que la différence.
- Un seul compte (`DB_USER`) sert à l'application et à la réplication. Deux comptes aux
  droits distincts seraient plus sûrs.
- Le mot de passe de réplication est enregistré dans la configuration de la réplique
  (`primary_conninfo`), hors du dépôt mais lisible par l'administrateur de la machine.
- Les serveurs applicatifs doivent être repointés vers le nouveau primaire (fait par
  `bascule.ps1` pour ceux qui tournent) ; une adresse virtuelle pour la base éviterait cette
  étape. Essais de bascule faits sans serveur applicatif démarré.
