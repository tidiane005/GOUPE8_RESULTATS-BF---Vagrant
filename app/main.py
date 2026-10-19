import os
import socket

import psycopg2
from flask import Flask, jsonify, request

app = Flask(__name__)


def variable_obligatoire(nom):
    valeur = os.environ.get(nom, "").strip()
    if not valeur:
        raise ValueError(f"Variable obligatoire absente : {nom}")
    return valeur


def connexion_db():
    return psycopg2.connect(
        host=variable_obligatoire("DB_HOST"),
        port=os.environ.get("DB_PORT", "5432"),
        user=variable_obligatoire("DB_USER"),
        password=variable_obligatoire("DB_PASSWORD"),
        dbname=variable_obligatoire("DB_NAME"),
        connect_timeout=3,
        application_name="resultats-bf",
    )


@app.route("/info", methods=["GET"])
def info():
    return jsonify({
        "serveur": socket.gethostname()
    }), 200


@app.route("/sante", methods=["GET"])
def sante():
    try:
        with connexion_db() as conn:
            with conn.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()
        return jsonify({"statut": "OK"}), 200
    except (psycopg2.Error, KeyError, ValueError):
        return jsonify({"statut": "INDISPONIBLE"}), 503


@app.route("/resultat", methods=["GET"])
def resultat():
    matricule = request.args.get("matricule", "").strip()

    if not matricule:
        return jsonify({
            "erreur": "Le matricule est obligatoire"
        }), 400

    try:
        with connexion_db() as conn:
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT matricule, nom, serie, moyenne, admis
                    FROM resultats
                    WHERE matricule = %s
                    """,
                    (matricule,),
                )
                ligne = cursor.fetchone()

        if ligne is None:
            return jsonify({
                "erreur": "Matricule introuvable"
            }), 404

        return jsonify({
            "matricule": ligne[0],
            "nom": ligne[1],
            "serie": ligne[2],
            "moyenne": float(ligne[3]) if ligne[3] is not None else None,
            "admis": ligne[4]
        }), 200

    except psycopg2.Error:
        return jsonify({
            "erreur": "Base de donnees indisponible"
        }), 503
    except (KeyError, ValueError):
        return jsonify({
            "erreur": "Configuration de la base invalide"
        }), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=3000)
