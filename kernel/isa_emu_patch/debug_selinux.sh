#!/bin/sh
# Boot param fidebook_permissive keeps SELinux permissive (ignores setenforce 1). Idempotent.
set -e
F=/build/src/security/selinux/selinuxfs.c
if grep -q gbos_permissive $F; then
  sed -i 's/gbos_permissive/fidebook_permissive/g' $F
fi
grep -q fidebook_permissive $F && exit 0
sed -i '/^static ssize_t sel_write_enforce(struct file \*file, const char __user \*buf,$/i \
static bool fidebook_permissive;\
static int __init fidebook_permissive_setup(char *s) { fidebook_permissive = true; return 1; }\
__setup("fidebook_permissive", fidebook_permissive_setup);\
' $F
sed -i 's/^\tnew_value = !!scan_value;$/\tnew_value = !!scan_value;\n\tif (fidebook_permissive \&\& new_value) {\n\t\tpr_warn_once("SELinux: fidebook_permissive: ignoring setenforce 1\\n");\n\t\tnew_value = 0;\n\t}/' $F
grep -n -A4 'new_value = !!scan_value' $F; grep -n fidebook_permissive_setup $F
