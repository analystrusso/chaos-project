#!/bin/bash
curl -sfL https://get.k3s.io | sh -

# Wait for k3s to be ready
until k3s kubectl get nodes 2>/dev/null | grep -q "Ready"; do
	sleep 5
done

# Write the join token to a known location for Ansible to retrieve
cat /var/lib/rancher/k3s/server/node-token > /tmp/k3s-node-token
chmod 644 /tmp/k3s-node-token

