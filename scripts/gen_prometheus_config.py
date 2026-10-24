#!/usr/bin/env python3
"""Engendre prometheus.yml à partir de config/noeuds.yml (source unique de vérité).

Usage : gen_prometheus_config.py <noeuds.yml> [port_metriques_haproxy]
Aucune adresse n'est écrite en dur : ajouter un serveur applicatif (NB_APP)
puis rejouer `vagrant provision obs` suffit à le faire apparaître dans Prometheus.
La sortie est déterministe (même entrée = même fichier) : le provisionnement
reste idempotent.
"""
import sys
import yaml


def nettoyer(noeud):
    # Ruby sérialise les clés symboles sous la forme ":nom" : on retire le ':'.
    return {str(k).lstrip(":"): v for k, v in noeud.items()}


def main():
    chemin = sys.argv[1]
    port_haproxy = int(sys.argv[2]) if len(sys.argv) > 2 else 8405
    with open(chemin, encoding="utf-8") as f:
        noeuds = [nettoyer(n) for n in yaml.safe_load(f)]

    cibles_node = [
        {"targets": [f"{n['ip']}:9100"], "labels": {"nom": n["nom"], "role": n["role"]}}
        for n in noeuds
    ]
    cibles_haproxy = [
        {"targets": [f"{n['ip']}:{port_haproxy}"], "labels": {"nom": n["nom"]}}
        for n in noeuds
        if str(n["role"]).startswith("lb")
    ]

    config = {
        "global": {"scrape_interval": "5s", "evaluation_interval": "5s"},
        "scrape_configs": [
            {"job_name": "prometheus", "static_configs": [{"targets": ["localhost:9090"]}]},
            {"job_name": "node", "static_configs": cibles_node},
            {"job_name": "haproxy", "static_configs": cibles_haproxy},
        ],
    }
    print("# FICHIER ENGENDRE par scripts/gen_prometheus_config.py -- ne pas modifier a la main")
    print("# Source : config/noeuds.yml")
    print(yaml.safe_dump(config, default_flow_style=False, sort_keys=False, allow_unicode=True), end="")


if __name__ == "__main__":
    main()
