#!/bin/bash

set -e

SCRIPT_PATH=$(dirname "$(realpath "$0")")
source ${KUBEVIRTCI_PATH}/cluster/kind/common.sh

echo "Configuring KubeVirt for Grace GPU passthrough..."

# Wait for KubeVirt to be available
_kubectl wait -n kubevirt kv kubevirt --for condition=Available --timeout 5m

# Discover GPU PCI IDs from the host (3D controllers only)
gpu_pci_ids=$(lspci -d 10de: -nn | grep -i '3D controller' | grep -oP '\[10de:\K[0-9a-f]+(?=\])' | sort -u)

if [ -z "$gpu_pci_ids" ]; then
  echo "WARNING: No NVIDIA 3D controller GPUs found, skipping permittedHostDevices"
  exit 0
fi

# Discover resource names from node allocatable
gpu_resources=$(_kubectl get nodes -o json | jq -r '.items[].status.allocatable | to_entries[] | select(.key | startswith("nvidia.com/")) | .key' | sort -u)

if [ -z "$gpu_resources" ]; then
  echo "WARNING: No nvidia.com/* resources found on nodes, skipping permittedHostDevices"
  exit 0
fi

# Build the permittedHostDevices patch
pci_host_devices="["
first=true
for resource in $gpu_resources; do
  for pci_id in $gpu_pci_ids; do
    if [ "$first" = true ]; then
      first=false
    else
      pci_host_devices+=","
    fi
    pci_host_devices+="{\"pciVendorSelector\":\"10de:${pci_id}\",\"resourceName\":\"${resource}\"}"
  done
done
pci_host_devices+="]"

echo "Patching KubeVirt CR with permittedHostDevices:"
echo "  PCI IDs: $(echo $gpu_pci_ids | tr '\n' ' ')"
echo "  Resources: $(echo $gpu_resources | tr '\n' ' ')"

_kubectl patch kubevirt kubevirt -n kubevirt \
  --type merge -p "{\"spec\":{\"configuration\":{\"permittedHostDevices\":{\"pciHostDevices\":${pci_host_devices}}}}}"

echo "KubeVirt configured for Grace GPU passthrough"

# Discover the deployed virt-launcher image for the AIE webhook config
launcher_image=$(_kubectl get deployment virt-controller -n kubevirt -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="VIRT_LAUNCHER_IMAGE")].value}' 2>/dev/null || true)
if [ -z "$launcher_image" ]; then
  launcher_image="registry:5000/kubevirt/virt-launcher:devel"
  echo "WARNING: Could not discover launcher image, using default: $launcher_image"
fi
echo "Launcher image for AIE webhook: $launcher_image"

# Build device name list for webhook rules
device_names=""
first=true
for resource in $gpu_resources; do
  if [ "$first" = true ]; then
    first=false
  else
    device_names+=","
  fi
  device_names+="\"${resource}\""
done

# Update the AIE webhook ConfigMap with the discovered launcher image and GPU devices
_kubectl apply -f - <<CMEOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubevirt-aie-launcher-config
  namespace: kubevirt
data:
  config.yaml: |
    rules:
    - name: "grace-gpu-passthrough"
      image: "${launcher_image}"
      selector:
        deviceNames:
$(for resource in $gpu_resources; do echo "        - \"${resource}\""; done)
CMEOF

# Deploy the AIE webhook (requires kubevirt namespace to exist)
source ${SCRIPT_PATH}/grace-node/node.sh
node::deploy_aie_webhook

# Restart the webhook to pick up the new config
_kubectl rollout restart deployment/kubevirt-aie-webhook -n kubevirt 2>/dev/null || true
_kubectl -n kubevirt rollout status deployment/kubevirt-aie-webhook --timeout=60s || true
