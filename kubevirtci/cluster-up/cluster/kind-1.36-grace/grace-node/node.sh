#!/bin/bash

function node::remount_sysfs() {
  local -r nodes_array=($1)
  for node in "${nodes_array[@]}"; do
    ${CRI_BIN} exec $node mount -o remount,rw /sys
  done
}

function node::setup_vfio() {
  local -r nodes_array=($1)
  for node in "${nodes_array[@]}"; do
    ${CRI_BIN} exec $node chmod 666 /dev/iommu 2>/dev/null || true
    ${CRI_BIN} exec $node chmod 666 /dev/vfio/vfio 2>/dev/null || true
    ${CRI_BIN} exec $node bash -c 'for f in /dev/vfio/*; do chmod 666 "$f" 2>/dev/null; done' || true
    ${CRI_BIN} exec $node bash -c 'for f in /dev/vfio/devices/*; do chmod 666 "$f" 2>/dev/null; done' || true
  done
}

function node::deploy_gpu_device_plugin() {
  _kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kubevirt-gpu-device-plugin
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: kubevirt-gpu-device-plugin
  template:
    metadata:
      labels:
        name: kubevirt-gpu-device-plugin
    spec:
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: kubevirt-gpu-device-plugin
        image: ghcr.io/nvidia/kubevirt-gpu-device-plugin:94985728
        securityContext:
          privileged: true
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
        - name: pci-devices
          mountPath: /sys/bus/pci/devices
          readOnly: true
        - name: dev-vfio
          mountPath: /dev/vfio
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
      - name: pci-devices
        hostPath:
          path: /sys/bus/pci/devices
      - name: dev-vfio
        hostPath:
          path: /dev/vfio
EOF

  echo "Waiting for kubevirt-gpu-device-plugin to be ready..."
  _kubectl -n kube-system rollout status daemonset/kubevirt-gpu-device-plugin --timeout=120s || true

  echo "GPU extended resources:"
  _kubectl get nodes -o json | jq '.items[].status.allocatable | to_entries[] | select(.key | startswith("nvidia.com/"))' || true
}

function node::deploy_iommufd_device_plugin() {
  local dp_bin="/usr/local/bin/iommufd-device-plugin"
  local dp_src="/tmp/iommufd-device-plugin"
  local nodes_array=($(_kubectl get nodes -o custom-columns=:.metadata.name --no-headers))

  if [ ! -f "${dp_src}" ]; then
    echo "Building iommufd-device-plugin from source..."
    local build_dir=$(mktemp -d)
    git clone --depth 1 https://github.com/kubevirt/iommufd-device-plugin.git "${build_dir}/iommufd-device-plugin"
    (cd "${build_dir}/iommufd-device-plugin" && CGO_ENABLED=0 go build -o "${dp_src}" ./cmd/main.go)
    rm -rf "${build_dir}"
  fi

  for node in "${nodes_array[@]}"; do
    echo "Deploying iommufd-device-plugin on ${node}..."
    ${CRI_BIN} cp "${dp_src}" "${node}:${dp_bin}"
    ${CRI_BIN} exec "${node}" chmod +x "${dp_bin}"
    ${CRI_BIN} exec "${node}" mkdir -p /var/run/kubevirt/fd-sockets
    ${CRI_BIN} exec -d "${node}" bash -c "${dp_bin} -log-level=info -socket-dir=/var/run/kubevirt/fd-sockets > /tmp/iommufd-dp.log 2>&1"
  done

  echo "Waiting for iommufd-device-plugin to register..."
  sleep 10

  echo "IOMMUFD resources:"
  _kubectl get nodes -o json | jq '.items[].status.allocatable | to_entries[] | select(.key | contains("iommufd"))' || true
}

function node::deploy_cert_manager() {
  echo "Installing cert-manager..."
  _kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml

  echo "Waiting for cert-manager to be ready..."
  _kubectl -n cert-manager rollout status deployment/cert-manager --timeout=120s || true
  _kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=120s || true
  _kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=120s || true
}

function node::deploy_aie_webhook() {
  echo "Deploying AIE webhook..."
  _kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubevirt-aie-webhook
  namespace: kubevirt
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubevirt-aie-webhook
rules:
- apiGroups: ["kubevirt.io"]
  resources: ["virtualmachineinstances"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubevirt-aie-webhook
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubevirt-aie-webhook
subjects:
- kind: ServiceAccount
  name: kubevirt-aie-webhook
  namespace: kubevirt
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: kubevirt-aie-webhook-selfsigned
  namespace: kubevirt
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: kubevirt-aie-webhook-tls
  namespace: kubevirt
spec:
  secretName: kubevirt-aie-webhook-tls
  dnsNames:
  - kubevirt-aie-webhook.kubevirt.svc
  - kubevirt-aie-webhook.kubevirt.svc.cluster.local
  issuerRef:
    name: kubevirt-aie-webhook-selfsigned
    kind: Issuer
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubevirt-aie-launcher-config
  namespace: kubevirt
data:
  config.yaml: |
    rules: []
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubevirt-aie-webhook
  namespace: kubevirt
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kubevirt-aie-webhook
  template:
    metadata:
      labels:
        app: kubevirt-aie-webhook
    spec:
      serviceAccountName: kubevirt-aie-webhook
      containers:
      - name: webhook
        image: quay.io/kubevirt/kubevirt-aie-webhook:v1.1.0
        ports:
        - containerPort: 9443
          name: webhook
        - containerPort: 8080
          name: metrics
        - containerPort: 8081
          name: health
        env:
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        volumeMounts:
        - name: tls
          mountPath: /tmp/k8s-webhook-server/serving-certs
          readOnly: true
        - name: config
          mountPath: /etc/kubevirt-aie
          readOnly: true
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
        securityContext:
          runAsNonRoot: true
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
      volumes:
      - name: tls
        secret:
          secretName: kubevirt-aie-webhook-tls
      - name: config
        configMap:
          name: kubevirt-aie-launcher-config
---
apiVersion: v1
kind: Service
metadata:
  name: kubevirt-aie-webhook
  namespace: kubevirt
spec:
  ports:
  - port: 443
    targetPort: 9443
  selector:
    app: kubevirt-aie-webhook
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: kubevirt-aie-webhook
  annotations:
    cert-manager.io/inject-ca-from: kubevirt/kubevirt-aie-webhook-tls
webhooks:
- name: aie.kubevirt.io
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Fail
  clientConfig:
    service:
      name: kubevirt-aie-webhook
      namespace: kubevirt
      path: /mutate-pods
      port: 443
  rules:
  - operations: ["CREATE"]
    apiGroups: [""]
    apiVersions: ["v1"]
    resources: ["pods"]
  objectSelector:
    matchLabels:
      kubevirt.io: virt-launcher
EOF

  echo "Waiting for AIE webhook to be ready..."
  _kubectl -n kubevirt rollout status deployment/kubevirt-aie-webhook --timeout=120s || true
}
