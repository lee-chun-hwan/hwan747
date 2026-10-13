#!/usr/bin/env bash
# ============================================================
# 02-k8s-gpu-setup.sh  (Ubuntu 26.04 LTS 용)
# 쿠버네티스가 GPU를 쓰도록 설정 + NVIDIA GPU Operator 설치
#  - 쿠버네티스가 없으면 k3s(단일 노드)를 자동 설치
#  - 기존 kubeadm(containerd) 클러스터도 지원
# 전제: 01 스크립트 완료 → 재부팅 → nvidia-smi 정상
# 실행: bash 02-k8s-gpu-setup.sh   (일반 사용자로 실행, 필요 시 sudo 물어봄)
# ============================================================
set -euo pipefail

# ---- 0. 사전 점검 ----
echo "[0/5] 사전 점검"
if ! nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi 실패 — 01 스크립트 실행 후 재부팅했는지 확인하세요."; exit 1
fi
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
command -v nvidia-ctk >/dev/null || { echo "nvidia-container-toolkit 미설치 — 01 스크립트 확인"; exit 1; }

# ---- 1. 쿠버네티스 준비 ----
echo "[1/5] 쿠버네티스 확인"
if systemctl is-active --quiet k3s; then
  MODE=k3s
elif systemctl is-active --quiet kubelet; then
  MODE=kubeadm
else
  echo "  쿠버네티스가 없어 k3s(단일 노드)를 설치합니다."
  curl -sfL https://get.k3s.io | sudo sh -s - --write-kubeconfig-mode 644
  MODE=k3s
fi
echo "  모드: $MODE"

if [[ $MODE == k3s ]]; then
  mkdir -p ~/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo chown "$(id -u):$(id -g)" ~/.kube/config
  export KUBECONFIG=~/.kube/config
fi
kubectl get nodes

# ---- 2. containerd 에 nvidia 런타임 등록 ----
echo "[2/5] containerd 에 nvidia 런타임 등록"
if [[ $MODE == k3s ]]; then
  # k3s 는 설치된 nvidia-container-runtime 을 시작 시 자동 감지
  sudo systemctl restart k3s
  sleep 15
else
  # kubeadm: 26.04 의 containerd 2.x 도 nvidia-ctk 가 처리
  sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default
  sudo systemctl restart containerd
fi

# Pod 에서 runtimeClassName: nvidia 로 쓸 RuntimeClass (있으면 그대로 유지)
cat <<'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF

# ---- 3. Helm ----
echo "[3/5] Helm 확인"
if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ---- 4. NVIDIA GPU Operator ----
echo "[4/5] NVIDIA GPU Operator 설치 (드라이버/툴킷은 호스트 것 사용)"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update
helm upgrade --install gpu-operator nvidia/gpu-operator \
  -n gpu-operator --create-namespace \
  --set driver.enabled=false \
  --set toolkit.enabled=false \
  --wait --timeout 15m

# ---- 5. 확인 ----
echo "[5/5] 노드 GPU 인식 확인 (1~2분 걸릴 수 있음)"
for i in $(seq 1 24); do
  GPU=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
  [[ -n "$GPU" && "$GPU" != "0" ]] && break
  sleep 5
done
kubectl -n gpu-operator get pods
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

cat <<'EOF'

GPU 열이 1 이상이면 성공. Pod 안에서 GPU 테스트:
  kubectl run gpu-test --rm -it --restart=Never \
    --image=nvidia/cuda:12.8.0-base-ubuntu24.04 \
    --overrides='{"spec":{"runtimeClassName":"nvidia","containers":[{"name":"gpu-test","image":"nvidia/cuda:12.8.0-base-ubuntu24.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}'

다음 단계:  kubectl apply -f 03-ollama-gpu.yaml
EOF
