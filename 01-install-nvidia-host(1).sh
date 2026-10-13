#!/usr/bin/env bash
# ============================================================
# 01-install-nvidia-host.sh  (Ubuntu 26.04 LTS "resolute" 용)
# NVIDIA 드라이버 + Container Toolkit 설치
# 대상: RTX 5060 (Blackwell) — "open" 커널 모듈 드라이버 필요
# 실행: sudo bash 01-install-nvidia-host.sh   (완료 후 재부팅)
# ============================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "sudo로 실행하세요"; exit 1; fi

# ---- 0. OS 확인 ----
. /etc/os-release
echo "OS: $PRETTY_NAME"
if [[ "${VERSION_ID}" != "26.04" ]]; then
  echo "경고: Ubuntu 26.04용 스크립트입니다 (현재 ${VERSION_ID}). 계속하려면 Enter, 중단은 Ctrl+C"
  read -r
fi

# ---- 1. 시스템 Python 복구 (apt 후처리 에러 방지) ----
# 26.04 시스템 Python = 3.14. /usr/bin/python3 가 다른 버전(deadsnakes 등)을
# 가리키면 apt update 가 'apt_pkg' 에러로 실패함.
echo "[1/6] 시스템 Python 점검"
SYS_PY=$(ls /usr/lib/python3/dist-packages/apt_pkg.cpython-3*.so 2>/dev/null \
         | head -1 | sed -E 's/.*cpython-3([0-9]+)-.*/3.\1/')
SYS_PY=${SYS_PY:-3.14}
if ! /usr/bin/python3 -c 'import apt_pkg' 2>/dev/null; then
  echo "  /usr/bin/python3 이 깨져 있음 → python${SYS_PY} 로 복구"
  update-alternatives --remove-all python3 2>/dev/null || true
  if [[ -x /usr/bin/python${SYS_PY} ]]; then
    ln -sf "python${SYS_PY}" /usr/bin/python3
  else
    apt-get install -y --reinstall "python${SYS_PY}" "python${SYS_PY}-minimal" \
      python3-minimal python3 python3-apt
  fi
fi
/usr/bin/python3 -c 'import apt_pkg' && echo "  python3 → $(python3 --version) OK"

# ---- 2. 기본 패키지 ----
echo "[2/6] 기본 패키지"
apt-get update
apt-get install -y build-essential dkms "linux-headers-$(uname -r)" \
  ubuntu-drivers-common mokutil curl gnupg ca-certificates

# ---- 3. nouveau 비활성화 ----
echo "[3/6] nouveau 비활성화"
cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
update-initramfs -u

# ---- 4. NVIDIA 드라이버 ----
echo "[4/6] NVIDIA 드라이버 설치"
ubuntu-drivers devices || true
# 권장 드라이버 자동 설치 (RTX 50xx → *-open 드라이버가 선택됨)
ubuntu-drivers install
# 특정 버전을 고정하려면 위 줄 대신: apt-get install -y nvidia-driver-<버전>-open
#   (사용 가능한 버전은 'ubuntu-drivers devices' 출력에서 확인)

# ---- 5. NVIDIA Container Toolkit ----
echo "[5/6] NVIDIA Container Toolkit"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y nvidia-container-toolkit

# ---- 6. Secure Boot 안내 ----
echo "[6/6] Secure Boot 상태"
if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  cat <<'EOF'
  Secure Boot 가 켜져 있습니다.
  드라이버 설치 중 MOK 비밀번호를 설정했다면, 재부팅 시 파란 화면(MOK Manager)에서
  "Enroll MOK" → "Continue" → 비밀번호 입력 → Reboot 를 진행해야 드라이버가 로드됩니다.
EOF
fi

echo
echo "완료. 지금 재부팅하세요:  sudo reboot"
echo "재부팅 후 확인:  nvidia-smi   (GPU 이름과 드라이버/CUDA 버전이 보이면 성공)"
