#!/system/bin/sh
# Run by init right after apexd has activated all APEXes (and before zygote): bind the SHA-NI-free libcrypto
# over every APEX copy matching patched/MANIFEST.
M=/postinstall/fidebook/patched/MANIFEST
[ -f $M ] || { log -t fidebook "apex_patch: $M missing"; exit 0; }
while read -r kind rel want file rest; do
  [ "$kind" = apex ] || continue
  P=/postinstall/fidebook/$file
  [ -f $P ] || { log -t fidebook "apex_patch: $P missing"; continue; }
  for d in /apex/*; do
    case $d in *@*) continue;; esac
    f=$d/$rel
    [ -f $f ] || continue
    have=$(sha256sum $f | cut -d' ' -f1)
    if [ "$have" = "$want" ]; then
      mount -o bind $P $f && log -t fidebook "apex_patch: patched $f" || log -t fidebook "apex_patch: bind FAILED $f"
    else
      log -t fidebook "apex_patch: $f left alone (sha256 $have, patch is for $want)"
    fi
  done
done < $M
