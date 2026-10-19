import unittest
from unittest.mock import patch

import psycopg2

from app import main


class FauxCurseur:
    def __init__(self, ligne=(1,)):
        self.ligne = ligne

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None

    def execute(self, *_):
        return None

    def fetchone(self):
        return self.ligne


class FausseConnexion:
    def __init__(self, ligne=(1,)):
        self.ligne = ligne

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None

    def cursor(self):
        return FauxCurseur(self.ligne)


class TestApplication(unittest.TestCase):
    def setUp(self):
        self.client = main.app.test_client()

    def test_info(self):
        reponse = self.client.get("/info")
        self.assertEqual(reponse.status_code, 200)
        self.assertIn("serveur", reponse.get_json())

    @patch("app.main.connexion_db", return_value=FausseConnexion())
    def test_sante_base_disponible(self, _connexion):
        reponse = self.client.get("/sante")
        self.assertEqual(reponse.status_code, 200)
        self.assertEqual(reponse.get_json(), {"statut": "OK"})

    @patch(
        "app.main.connexion_db",
        side_effect=psycopg2.OperationalError("base indisponible"),
    )
    def test_sante_base_indisponible(self, _connexion):
        reponse = self.client.get("/sante")
        self.assertEqual(reponse.status_code, 503)
        self.assertEqual(reponse.get_json(), {"statut": "INDISPONIBLE"})

    def test_resultat_sans_matricule(self):
        reponse = self.client.get("/resultat")
        self.assertEqual(reponse.status_code, 400)

    @patch("app.main.connexion_db", return_value=FausseConnexion(None))
    def test_resultat_inconnu(self, _connexion):
        reponse = self.client.get("/resultat?matricule=INCONNU")
        self.assertEqual(reponse.status_code, 404)

    @patch(
        "app.main.connexion_db",
        return_value=FausseConnexion(("BF00001", "Nom Test", "D", 12.5, True)),
    )
    def test_resultat_trouve(self, _connexion):
        reponse = self.client.get("/resultat?matricule=BF00001")
        self.assertEqual(reponse.status_code, 200)
        self.assertEqual(
            reponse.get_json(),
            {
                "matricule": "BF00001",
                "nom": "Nom Test",
                "serie": "D",
                "moyenne": 12.5,
                "admis": True,
            },
        )


if __name__ == "__main__":
    unittest.main()
