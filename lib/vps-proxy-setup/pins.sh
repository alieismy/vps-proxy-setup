# shellcheck shell=bash
# Fixed versions and digests (detailed design 6). Data only; deploy and check
# read them from here, and the tests compare against them (VT-99).
# shellcheck disable=SC2034

readonly VPS_PIN_XUI_VERSION='3.11.0'
readonly VPS_PIN_XUI_TAG='v3.11.0'
readonly VPS_PIN_XUI_COMMIT='c621ba9014a6aa21fd7c9ecf45655e44e24ebf13'
readonly VPS_PIN_XUI_INSTALL_SHA256='9684bae4f769b2127fcceceb4f200045657381311867529e6ba76c6b58e2825d'
readonly VPS_PIN_XUI_TARBALL_SIZE='82728788'
readonly VPS_PIN_XUI_TARBALL_SHA256='0ddfa4702f595442e2962acd81addc768fdacaa4ff2672c971a0463dae744916'

# Installed files checked by xui.files. The two binaries are the members
# x-ui/x-ui and x-ui/bin/xray-linux-amd64 of the fixed release archive
# (verification plan VO-1); x-ui.sh and x-ui.service.debian in that archive
# are identical to the files on the tag path. An empty digest never passes.
readonly VPS_PIN_XUI_FILES=(
  "$VPS_XUI_BIN"
  "$VPS_XUI_XRAY"
  "$VPS_XUI_SCRIPT"
  "$VPS_XUI_UNIT_FILE"
)
readonly VPS_PIN_XUI_SHA256=(
  'fb7b3776334fce69299f90168c8c31377b69f89c7787088e6dbf561d07b3d345'
  'a27e3f95ab6ce270956d0cecd32eda4686a811afc71c64a6a734a3dede14883e'
  '26c229d5fb3b184e81581b4b223b801582ca7cf5908aaedeb8d1c7c70ad4cc25'
  '95cb6e39499601148404cadf3b4d75b0489301ff7e7ab565cd9db21d23be957c'
)

readonly VPS_PIN_CLOUDFLARED_VERSION='2026.10.5'
readonly VPS_PIN_CLOUDFLARED_SIZE='40263303'
readonly VPS_PIN_CLOUDFLARED_SHA256='e1bc0cf084fd9e590554fe769a86b1db46701c3f847a43d902f7b974a4e16298'

# vps-hardening versions this tool was tested with (requirements A-1, D9; DO-7).
readonly VPS_PIN_HARDENING_TESTED=('0.1.1')
