# Procédure de bascule de la base de données (R6)

Responsable : ingénieur données. Fichiers concernés : `bascule.ps1`,
`reintegrer.ps1`, `scripts/promouvoir.sh`, `scripts/rejoindre.sh`.

## Situation de départ

- `bdd1` : primaire PostgreSQL 16 (lecture et écriture), `192.168.63.31`.
- `bdd2` : réplique en flux asynchrone de `bdd1`, en lecture seule, `192.168.63.32`.
- Les serveurs applicatifs lisent `DB_HOST` dans `/opt/app/.env`.

## Procédure automatique (depuis le dossier du projet, sous PowerShell)

1. Promouvoir `bdd2` en primaire. `-Panne bdd1` éteint d'abord `bdd1` pour simuler une panne :

   ```powershell
   .\bascule.ps1 -Panne bdd1
   ```

   Le script : (1) promeut `bdd2` avec `pg_promote()` ; (2) écrit puis supprime une ligne
   de test pour prouver que `bdd2` accepte les écritures ; (3) compte les lignes ;
   (4) repointe `DB_HOST` vers `bdd2` sur chaque serveur applicatif **démarré** et
   redémarre le service. Chaque étape est chronométrée.

2. Quand `bdd1` est réparée, la remettre en réplique de `bdd2` :

   ```powershell
   .\reintegrer.ps1
   ```

   Le script redémarre `bdd1` (sans reprovisionnement), la recopie entièrement depuis
   `bdd2` (`pg_basebackup -R`), vérifie le flux de réplication et compare le nombre de lignes.

3. Retour au rôle d'origine (facultatif) : `.\bascule.ps1 -Cible bdd1` puis
   `.\reintegrer.ps1 -Machine bdd2 -Source bdd1`.

## Procédure manuelle équivalente

```bash
# sur bdd2 : promotion
sudo -u postgres psql -tAc "SELECT pg_promote(wait => true, wait_seconds => 30);"
sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();"     # f = primaire
# sur chaque app : repointage
sudo sed -i 's/^DB_HOST=.*/DB_HOST=192.168.63.32/' /opt/app/.env
sudo systemctl restart resultats-app
```

## Mesures (deux essais, PC de développement, VirtualBox)

| Étape | Essai 1 | Essai 2 (machines reconstruites) |
|---|---|---|
| `pg_promote()` seul (promotion PostgreSQL) | 0,67 s | 1,27 s |
| Procédure complète `bascule.ps1 -Panne bdd1` | 98,6 s | 111,3 s |
| dont panne simulée (arrêt de `bdd1`) | 14,6 s | 16,7 s |
| dont promotion + écriture vérifiée | 69,4 s | 77,9 s |
| Réintégration `reintegrer.ps1` (copie complète, 50 000 lignes) | 95,9 s | 224,7 s |
| dont redémarrage de `bdd1` par VirtualBox | 14,7 s | 124,0 s |

La base est prête à écrire environ une seconde après l'ordre de promotion. Le reste du
temps vient des appels `vagrant ssh` (environ 10 à 15 s chacun sous Windows) et du
démarrage de la machine virtuelle, pas de PostgreSQL. Ces durées dépendent de la charge
du PC (la réintégration varie du simple au double entre les deux essais) : ce sont des
ordres de grandeur, pas des garanties. Mesures faites sans serveur applicatif démarré.

## Limites connues

- **Perte possible de données** : la réplication est asynchrone. Si `bdd1` tombe, les
  dernières écritures non encore reçues par `bdd2` sont perdues. Lors de l'essai, aucune
  écriture n'était en cours, donc aucune perte n'a été constatée.
- **Bascule manuelle** : rien ne la déclenche automatiquement. C'est une procédure, pas un
  basculement automatique.
- **Deux primaires** : ne jamais rallumer l'ancien primaire sans le réintégrer d'abord
  (`reintegrer.ps1` remplace ses données par celles du nouveau primaire).
- **Pas de `vagrant provision` après une bascule** sur `bdd1`/`bdd2` : les scripts de
  provisionnement supposent `bdd1` primaire. Pour revenir à l'état initial :
  `vagrant destroy -f` puis `vagrant up`.
- **Réglages identiques** : `bdd1` et `bdd2` doivent avoir les mêmes `max_wal_senders`,
  `wal_level` et `wal_keep_size` (une réplique refuse de démarrer si une valeur est plus
  petite que celle du primaire). Les deux scripts de provisionnement les écrivent à
  l'identique.
- Le répartiteur n'intervient pas : il ne parle qu'aux serveurs applicatifs, c'est
  `bascule.ps1` qui repointe ces derniers.
