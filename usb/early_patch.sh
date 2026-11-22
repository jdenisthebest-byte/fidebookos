# Sourced from fidebook.cfg, before any partition is mounted. Binds SHA-NI/VNNI-free libz + libcrypto before stage0 dmctl.
_cfg="${G:-/fidebook/fidebook}/fidebook.cfg"
if [ -f "$_cfg" ] && grep -q '^MODE=live' "$_cfg" 2>/dev/null; then
  sed -i 's/^MODE=live/MODE=ask/' "$_cfg" 2>/dev/null || true
  sync 2>/dev/null || true
fi
unset _cfg
fidebook_early_patch() {
  [ -f "$G/patched/MANIFEST" ] || return 0
  while read -r ep_kind ep_target ep_want ep_file ep_rest; do
    [ "$ep_kind" = early ] || continue
    [ -f "$G/$ep_file" ] && [ -f "$ep_target" ] || continue
    if [ "$(sha256sum "$ep_target" | cut -d' ' -f1)" = "$ep_want" ]; then
      mount --bind "$G/$ep_file" "$ep_target" && log "early: patched $ep_target"
    fi
  done < "$G/patched/MANIFEST"
}
chroot() {
  if [ -z "$FIDEBOOK_EARLY_DONE" ] && [ "$1" = /new ]; then
    FIDEBOOK_EARLY_DONE=1
    fidebook_early_patch
  fi
  command chroot "$@"
}
