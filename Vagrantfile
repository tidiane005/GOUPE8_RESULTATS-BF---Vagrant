# -*- mode: ruby -*-
require 'yaml'
require 'fileutils'

# --- Lecture de .env (R7 : aucun secret dans le dépôt) ---
def charger_env(chemin)
  return {} unless File.exist?(chemin)
  File.readlines(chemin, chomp: true).each_with_object({}) do |ligne, h|
    ligne = ligne.sub(/\s+#.*$/, '').strip   # commentaires en fin de ligne
    next if ligne.empty? || ligne.start_with?('#')
    cle, val = ligne.split('=', 2)
    next if val.nil?
    h[cle.strip] = val.strip.gsub(/\A["']|["']\z/, '')
  end
end

DOTENV = charger_env(File.join(__dir__, '.env'))
# Priorité : variable d'environnement du shell > .env > valeur par défaut
cfg = ->(cle, defaut = nil) { ENV[cle] || DOTENV[cle] || defaut }

GROUPE = cfg.('GROUPE', 8).to_i
NB_APP = cfg.('NB_APP', 2).to_i
E1     = cfg.('E1', '0') == '1'   # extension E1 : second répartiteur lb2
E2     = cfg.('E2', '0') == '1'   # extension E2 : supervision obs

RESEAU  = "192.168.#{55 + GROUPE}"
BOITE   = "bento/ubuntu-24.04"
VERSION = "202508.03.0"

# Secrets transmis aux scripts via env: (jamais écrits en dur)
SECRETS_BD = %w[DB_USER DB_NAME DB_PASS]
if ARGV.first =~ /\A(up|provision|reload)\z/
  manquants = SECRETS_BD.reject { |k| cfg.(k) }
  abort "ERREUR : variables manquantes dans .env : #{manquants.join(', ')}" unless manquants.empty?
end

ENV_BD  = SECRETS_BD.to_h { |k| [k, cfg.(k).to_s] }
ENV_LB  = cfg.('VRRP_PASS') ? { "VRRP_PASS" => cfg.('VRRP_PASS') } : {}

# --- Définition des noeuds ---
NOEUDS = []
NOEUDS << { nom: "bdd1", ip: "#{RESEAU}.31", mem: 768, role: "bdd" }
NOEUDS << { nom: "bdd2", ip: "#{RESEAU}.32", mem: 768, role: "replique" }

(1..NB_APP).each do |i|
  NOEUDS << { nom: "app#{i}", ip: "#{RESEAU}.#{20 + i}", mem: 512, role: "app" }
end

NOEUDS << { nom: "lb1", ip: "#{RESEAU}.11", mem: 512, role: "lb" }
NOEUDS << { nom: "lb2", ip: "#{RESEAU}.12", mem: 512, role: "lb" }  if E1
NOEUDS << { nom: "obs", ip: "#{RESEAU}.41", mem: 768, role: "obs" } if E2

# Source de vérité pour HAProxy / scripts (clés en chaînes, pas en symboles)
FileUtils.mkdir_p("config")
File.write("config/noeuds.yml", NOEUDS.map { |n| n.transform_keys(&:to_s) }.to_yaml)

Vagrant.configure("2") do |config|
  config.vm.box = BOITE
  config.vm.box_version = VERSION
  config.vm.box_architecture = "amd64"

  NOEUDS.each do |n|
    config.vm.define n[:nom] do |m|
      m.vm.hostname = n[:nom]
      m.vm.network "private_network", ip: n[:ip]

      # Redirection du port HTTP uniquement sur les répartiteurs (Exigence R8)
      if n[:role] == "lb"
        m.vm.network "forwarded_port", guest: 80, host: (n[:nom] == "lb1" ? 8080 : 8081)
      end

      m.vm.provider "virtualbox" do |vb|
        vb.memory = n[:mem]
        vb.cpus = 1
      end

      env = case n[:role]
            when "bdd", "replique", "app" then ENV_BD
            when "lb"                     then ENV_LB
            else {}
            end

      m.vm.provision "shell", path: "scripts/#{n[:role]}.sh", env: env
    end
  end
end