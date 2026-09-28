#!/bin/bash
# Build the dev pair from a synthetic source tree: the sudo grant command, its
# library, boot cleanup and revocation hook ship from settings, and no path
# ships from both packages, which pacman would refuse to install together.
set -euo pipefail

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fixture=$scratch/src/omarchy

mapfile -t files < "$BUILD_ROOT/tests/fixtures/settings-source-files"
files+=(
  bin/omarchy-update
  default/libalpm/hooks/00-omarchy-update-guard.hook
  default/libalpm/hooks/10-omarchy-hyprland-reload-pause.hook
  default/libalpm/hooks/90-omarchy-hyprland-reload-resume.hook
  install/omarchy-base.packages
  themes/fixture/colors.toml
  migrations/1788163635.sh
  shell/shell.qml
  version
)
for path in "${files[@]}"; do
  mkdir -p "$(dirname "$fixture/$path")"
  printf 'fixture for %s\n' "$path" > "$fixture/$path"
done
# The aarch64 recipe parses the HOOKS line.
cp "$BUILD_ROOT/tests/fixtures/settings-boot/omarchy_hooks-v4.0.4.conf" "$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

hook=usr/share/libalpm/hooks/05-omarchy-passwordless-revoke.hook
boot_cleanup=etc/tmpfiles.d/omarchy-nopasswd-sudo.conf

# The scriptlets are what clear the hook's marker, and
# passwordless-package-lifecycle.py only tests the file, not that it ships.
registered=$(CARCH=x86_64 && source "$BUILD_ROOT/pkgbuilds/omarchy-settings-dev/PKGBUILD" && echo "${install:-}")
[[ $registered == omarchy-settings-dev.install ]] ||
  fail "omarchy-settings-dev does not register omarchy-settings-dev.install"

# The runtime refuses the settings releases from before the helpers moved,
# the last of which was -2, and accepts this one.
floor=$(CARCH=x86_64 && source "$BUILD_ROOT/pkgbuilds/omarchy-dev/PKGBUILD" && printf '%s\n' "${conflicts[@]}" | sed -n 's/^omarchy-settings-dev<//p')
settings=$(CARCH=x86_64 && source "$BUILD_ROOT/pkgbuilds/omarchy-settings-dev/PKGBUILD" && echo "$pkgver-$pkgrel")
[[ -n $floor ]] && (($(vercmp 4.0.0.r6694.g821ae58-2 "$floor") < 0 && $(vercmp "$settings" "$floor") >= 0)) ||
  fail "omarchy-dev does not refuse settings-dev releases without the grant helpers (conflict: '${floor}', settings: $settings)"

for target_arch in x86_64 aarch64; do
  for recipe in omarchy-dev omarchy-settings-dev; do
    (
      export CARCH=$target_arch OMARCHY_SRC=$fixture
      export srcdir=$scratch/src pkgdir=$scratch/$recipe-$target_arch
      backup=()
      # shellcheck disable=SC1090 # Exercise each recipe's actual package function.
      source "$BUILD_ROOT/pkgbuilds/$recipe/PKGBUILD"
      package
    ) >/dev/null
  done
  runtime=$scratch/omarchy-dev-$target_arch
  settings=$scratch/omarchy-settings-dev-$target_arch

  for helper in omarchy-sudo-passwordless omarchy-security-functions; do
    cmp -s "$fixture/bin/$helper" "$settings/usr/bin/$helper" && [[ -x $settings/usr/bin/$helper ]] ||
      fail "$target_arch: omarchy-settings-dev does not ship /usr/bin/$helper"
    [[ $(readlink "$settings/usr/share/omarchy/bin/$helper") == "/usr/bin/$helper" ]] ||
      fail "$target_arch: omarchy-settings-dev does not link /usr/share/omarchy/bin/$helper"
  done
  cmp -s "$fixture/default/libalpm/hooks/05-omarchy-passwordless-revoke.hook" "$settings/$hook" &&
    [[ $(stat -c %a "$settings/$hook") == 644 ]] ||
    fail "$target_arch: omarchy-settings-dev does not ship /$hook"
  cmp -s "$fixture/$boot_cleanup" "$settings/$boot_cleanup" ||
    fail "$target_arch: omarchy-settings-dev does not ship /$boot_cleanup"
  [[ -x $runtime/usr/bin/omarchy-update && -f $runtime/usr/share/libalpm/hooks/00-omarchy-update-guard.hook ]] ||
    fail "$target_arch: omarchy-dev lost its own commands or hooks"

  overlap=$(comm -12 <(cd "$runtime" && find . ! -type d | sort) <(cd "$settings" && find . ! -type d | sort))
  [[ -z $overlap ]] || fail "$target_arch: shipped by both omarchy-dev and omarchy-settings-dev:"$'\n'"$overlap"
  echo "PASS: $target_arch: omarchy-settings-dev owns the sudo grant lifecycle and shares no file with omarchy-dev"
done
