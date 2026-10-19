# RESULTATS-BF avec Vagrant

RESULTATS-BF permet a un candidat de consulter son resultat a partir de son
numero de matricule. L'infrastructure est decrite dans le `Vagrantfile` et les
machines sont provisionnees par les scripts du repertoire `scripts/`.

## Configuration locale

Copier le fichier d'exemple, puis remplacer le mot de passe par celui convenu
avec l'ingenieur donnees. Le fichier `.env` est ignore par Git.

```powershell
Copy-Item .env.example .env
notepad .env
```

Variables utilisees par l'application :

| Variable | Description |
| --- | --- |
| `DB_HOST` | Adresse de PostgreSQL ; si vide, l'adresse de `bdd1` est lue dans `config/noeuds.yml` |
| `DB_PORT` | Port PostgreSQL, `5432` par defaut |
| `DB_USER` | Utilisateur applicatif en lecture |
| `DB_PASSWORD` | Secret local, obligatoire pour que `/sante` soit valide |
| `DB_NAME` | Base contenant la table `resultats` |

## Demarrage

```powershell
vagrant validate
vagrant up
```

Le repartiteur principal est expose sur `http://localhost:8080`. Exemples :

```powershell
curl.exe http://localhost:8080/info
curl.exe http://localhost:8080/sante
curl.exe "http://localhost:8080/resultat?matricule=BF00001"
```

Reponses attendues : `/info` renvoie le nom du serveur, `/sante` renvoie 200
uniquement si PostgreSQL repond, et `/resultat` renvoie 400, 404, 200 ou 503
selon la requete et l'etat de la base.

## Verification de l'application

Les tests n'ont pas besoin d'une base reelle : la connexion PostgreSQL est
simulee afin de verifier les codes HTTP et le JSON.

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s app -p "test_*.py"
```

Dans une VM applicative :

```bash
sudo systemctl status app.service --no-pager
curl -i http://127.0.0.1:3000/info
curl -i http://127.0.0.1:3000/sante
```

## Deploiement sans coupure (extension E4)

Toutes les VM applicatives et la base doivent etre saines avant l'operation.
Le script reprovisionne les serveurs un par un et attend le retour de `/sante`
avant de continuer :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-app.ps1
```

Pendant la demonstration, lancer une charge continue sur le repartiteur et
conserver le resultat brut. Aucune requete ne doit echouer pendant la mise a
jour. La campagne de mesure et son commentaire appartiennent au livrable des
essais.

## Dependances entre roles

L'ingenieur donnees doit fournir PostgreSQL, la table `resultats`, les 50 000
lignes, l'utilisateur applicatif et la replication. L'architecte reseau fournit
HAProxy et sa sonde `/sante`. L'application reste volontairement sans etat et
peut donc etre retiree puis remise dans la rotation sans migration locale.
