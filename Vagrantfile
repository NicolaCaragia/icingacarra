# -*- mode: ruby -*-
# VM pronta all'uso: Debian 12 + Icinga (PostgreSQL) installato da runsetup.sh
#   vagrant up                    # VirtualBox (predefinito) o Hyper-V
#   vagrant up --provider=hyperv  # Windows con Hyper-V (da PowerShell admin)
# UI: http://localhost:8080/icingaweb2  (utente icingaadmin / password: vedi sotto)
#   vagrant ssh -c 'sudo cat /root/icinga-credentials.txt'
Vagrant.configure("2") do |config|
  config.vm.box = "debian/bookworm64"
  config.vm.hostname = "icinga.local"

  config.vm.network "forwarded_port", guest: 80,   host: 8080, auto_correct: true
  config.vm.network "forwarded_port", guest: 5665, host: 5665, auto_correct: true

  config.vm.provider "virtualbox" do |vb|
    vb.name   = "icinga-pgsql"
    vb.memory = 3072
    vb.cpus   = 2
  end
  config.vm.provider "hyperv" do |h|
    h.vmname = "icinga-pgsql"
    h.memory = 3072
    h.cpus   = 2
  end

  # Niente cartelle sincronizzate (compatibile con Hyper-V): si copia lo script.
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.provision "file", source: "runsetup.sh", destination: "/tmp/runsetup.sh"
  config.vm.provision "shell", privileged: true, inline: <<-SHELL
    ICINGA_FQDN=icinga.local bash /tmp/runsetup.sh --yes
  SHELL
end
