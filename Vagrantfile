#-*- mode: ruby -*-
require 'yaml'
require 'fileutils'

# Charger le fichier local sans dependance externe. Les variables deja exportees
# dans le terminal restent prioritaires.
env_file = File.expand_path('.env', __dir__)
if File.file?(env_file)
  File.foreach(env_file) do |line|
    line = line.strip
    next if line.empty? || line.start_with?('#')

    key, value = line.split('=', 2)
    next unless key&.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) && value

    value = value.sub(/\s+#.*\z/, '').strip
    if value.length >= 2 && ['"', "'"].include?(value[0]) && value[-1] == value[0]
      value = value[1...-1]
    end
    ENV[key] ||= value
  end
end

# Lecture des variables d'environnement ou valeurs par defaut
GROUPE = (ENV['GROUPE'] || 1).to_i
NB_APP = (ENV['NB_APP'] || 2).to_i

RESEAU = "192.168.#{55 + GROUPE}"
BOITE = "bento/ubuntu-24.04"
VERSION = "202404.26.0"

NOEUDS = []
NOEUDS << { nom: "bdd1", ip: "#{RESEAU}.31", mem: 768, role: "bdd" }
NOEUDS << { nom: "bdd2", ip: "#{RESEAU}.32", mem: 768, role: "replique" }

(1..NB_APP).each do |i|
  NOEUDS << { nom: "app#{i}", ip: "#{RESEAU}.#{20 + i}", mem: 512, role: "app" }
end

NOEUDS << { nom: "lb1", ip: "#{RESEAU}.11", mem: 512, role: "lb" }
NOEUDS << { nom: "lb2", ip: "#{RESEAU}.12", mem: 512, role: "lb" }  # Extension E1
NOEUDS << { nom: "obs", ip: "#{RESEAU}.41", mem: 768, role: "obs" } # Extension E2

# Export de la source de vérité pour HAProxy / scripts
FileUtils.mkdir_p("config")
File.write("config/noeuds.yml", NOEUDS.to_yaml)

Vagrant.configure("2") do |config|
  config.vm.box = BOITE
  config.vm.box_version = VERSION

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

      # Script de provisioning shell selon le rôle
      m.vm.provision "shell", path: "scripts/#{n[:role]}.sh"
    end
  end
end
