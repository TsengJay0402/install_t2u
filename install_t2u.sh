#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/aircrack-ng/rtl8812au.git"
SRC_DIR="${HOME}/rtl8812au"
MODULE_NAME="rtl8812au"
KMOD_NAME="88XXau"

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

cleanup_on_error() {
  err "安裝過程失敗，請檢查上面的錯誤訊息。"
  err "若要查看 DKMS 狀態，可執行：dkms status"
}
trap cleanup_on_error ERR

check_network() {
  log "檢查外網連線（IP 層）..."
  if ! ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    err "無法連到 8.8.8.8，請先確認有線網路/預設路由是否正常。"
    exit 1
  fi

  log "檢查 DNS / GitHub 連線..."
  if ! ping -c 2 -W 3 github.com >/dev/null 2>&1; then
    err "無法解析或連到 github.com，請先確認 DNS 設定。"
    exit 1
  fi

  log "外網檢查通過"
}

log "開始安裝 RTL8811AU/RTL8812AU 驅動"
log "Kernel: $(uname -r)"

check_network

log "更新套件索引並安裝必要工具..."
sudo apt update
sudo apt install -y dkms git build-essential rsync

BUILD_DIR="/lib/modules/$(uname -r)/build"
log "檢查 kernel build tree: ${BUILD_DIR}"
if [[ ! -L "${BUILD_DIR}" && ! -d "${BUILD_DIR}" ]]; then
  err "找不到 kernel build 目錄：${BUILD_DIR}"
  exit 1
fi

if [[ ! -f "${BUILD_DIR}/Makefile" ]]; then
  err "kernel build tree 缺少 Makefile：${BUILD_DIR}/Makefile"
  exit 1
fi
log "kernel build tree 檢查通過"

if [[ -d "${SRC_DIR}/.git" ]]; then
  log "已存在原始碼目錄，更新 repo..."
  git -C "${SRC_DIR}" pull --ff-only
else
  log "下載驅動原始碼..."
  git clone "${REPO_URL}" "${SRC_DIR}"
fi

cd "${SRC_DIR}"

if [[ ! -f dkms.conf ]]; then
  err "找不到 dkms.conf，repo 內容不完整：${SRC_DIR}"
  exit 1
fi

VER="$(awk -F= '/PACKAGE_VERSION/ {gsub(/"| /,"",$2); print $2}' dkms.conf)"
if [[ -z "${VER}" ]]; then
  err "無法從 dkms.conf 取得版本號"
  exit 1
fi
log "DKMS 版本：${VER}"

DKMS_SRC_DIR="/usr/src/${MODULE_NAME}-${VER}"
log "同步原始碼到 ${DKMS_SRC_DIR}"
sudo mkdir -p "${DKMS_SRC_DIR}"
sudo rsync -a --delete ./ "${DKMS_SRC_DIR}/"

if dkms status | grep -q "^${MODULE_NAME}/${VER},"; then
  warn "偵測到 DKMS 已有 ${MODULE_NAME}/${VER}，先移除舊註冊再重裝"
  sudo dkms remove -m "${MODULE_NAME}" -v "${VER}" --all || true
fi

log "DKMS add..."
sudo dkms add -m "${MODULE_NAME}" -v "${VER}"

log "DKMS build..."
sudo dkms build -m "${MODULE_NAME}" -v "${VER}"

log "DKMS install..."
sudo dkms install -m "${MODULE_NAME}" -v "${VER}"

log "執行 depmod..."
sudo depmod -a

log "載入核心模組 ${KMOD_NAME} ..."
sudo modprobe "${KMOD_NAME}"

log "設定開機自動載入 ${KMOD_NAME} ..."
echo "${KMOD_NAME}" | sudo tee /etc/modules-load.d/88xxau.conf >/dev/null

log "安裝完成，以下是驗收資訊："
echo
echo "===== dkms status ====="
dkms status | grep -i "${MODULE_NAME}" || true
echo
echo "===== lsmod ====="
lsmod | grep -i "${KMOD_NAME}" || true
echo
echo "===== nmcli dev ====="
nmcli dev || true
echo
echo "===== nmcli dev wifi list (前20行) ====="
nmcli dev wifi list | head -n 20 || true
echo
echo "===== 無線介面 ====="
ip link | egrep -i "wlan|wlx|wlp" || true
echo

log "若已看到 wifi 介面（例如 wlx...），即可使用 nmcli 連線："
echo 'sudo nmcli dev wifi connect "SSID名稱" password "WiFi密碼"'