#!/usr/bin/env bash
# ============================================================
# 02-k8s-gpu-setup.sh
# 쿠버네티스(containerd)가 GPU를 쓰도록 설정 + NVIDIA GPU Operator 설치
# 전제: 01 스크립트 완료, 재부팅 후 nvidia-smi 정상, kubectl/helm 사용 가능
# 실행: bash 02-k8s-gpu-setup.sh
# ============================================================
set -euo pipefail

echo "[1/4] containerd에 nvidia 런타임 등록"
if systemctl is-active --quiet k3s; then
  # k3s는 nvidia-container-runtime을 자동 감지 → 재시작만
  sudo systemctl restart k3s
else
  # kubeadm 등 일반 containerd
  sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
  sudo systemctl restart containerd
fi

# Pod에서 runtimeClassName: nvidia 로 지정할 RuntimeClass (이미 있으면 그대로 유지)
cat <<'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF

echo "[2/4] Helm 확인"
if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "[3/4] NVIDIA GPU Operator 설치 (드라이버/툴킷은 호스트 것 사용)"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm upgrade --install gpu-operator nvidia/gpu-operator \
  -n gpu-operator --create-namespace \
  --set driver.enabled=false \
  --set toolkit.enabled=false \
  --wait --timeout 10m

echo "[4/4] 노드 GPU 인식 확인"
kubectl -n gpu-operator get pods
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

cat <<'EOF'

GPU 열이 1 이상이면 성공. 간단 테스트:
  kubectl run gpu-test --rm -it --restart=Never \
    --image=nvidia/cuda:12.8.0-base-ubuntu24.04 \
    --overrides='{"spec":{"runtimeClassName":"nvidia","containers":[{"name":"gpu-test","image":"nvidia/cuda:12.8.0-base-ubuntu24.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}'
EOF
