#!/bin/bash
# k3s on workers needs the master IP and join token
# These will be supplied by Ansible after the master is ready
# Nothing to do at launch time on workers

apt-get update -y
apt-get install -y curl
