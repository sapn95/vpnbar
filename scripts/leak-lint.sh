#!/usr/bin/env bash
# Every IPv4 address written down in this repository has to come from a range
# reserved for documentation or for private networks. Nothing else may be here.
#
# An allowlist rather than a list of forbidden strings, for the reason
# sapn95/container-commander's ADR 0011 gives: a denylist is itself a list of
# the things you are hiding, it has to be updated by the person who is about to
# leak something new, and it fails open on everything nobody thought of. This
# one contains no secrets by construction and fails closed.
#
# Names are not checkable the same way — a VPN profile named after an employer
# looks like any other word — so that rule is written in the README and checked
# by reading. This catches the class a machine can catch.
set -euo pipefail

readonly ALLOWED='^(0\.0\.0\.0$|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|255\.255\.255\.255$|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|22[4-9]\.|23[0-9]\.)'
readonly PATTERN='[0-9]{1,3}(\.[0-9]{1,3}){3}'

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Tracked files plus the untracked ones git would not ignore, so a new file is
# checked before it is added. The list goes through a file, not a variable: a
# command substitution drops the NUL separators. If git itself fails, so does
# the lint: a check that passes because it could not run is worse than none.
list="$(mktemp)"
staged="$(mktemp)"
hits="$(mktemp)"
matches="$(mktemp)"
trap 'rm -f "${list}" "${staged}" "${hits}" "${matches}"' EXIT
git ls-files -z --cached --others --exclude-standard > "${list}" || exit 1

# One grep per file, rather than one xargs run over all of them. xargs reports a
# child that failed as 123, which is the code it also uses when a batch simply
# found nothing, so a file grep could not read would be indistinguishable from a
# file with no address in it. Per file, exit 1 is "nothing here" and anything
# else stops the lint.
#
# `-a` because a file with a NUL byte anywhere in it is one grep otherwise
# reports as "binary file matches" and exits 0 on, without saying what it found:
# the address would be in the tree and not in the output.
while IFS= read -r -d '' file; do
  if [ -f "${file}" ]; then
    subject="${file}"
  elif [ -e "${file}" ]; then
    # A directory in this list is a submodule, and what is inside it is another
    # repository's to check.
    continue
  else
    # Staged, and then taken out of the working tree. What a commit would carry
    # is in the index, so that is what gets searched.
    git show ":${file}" > "${staged}" || {
      printf 'no working copy and no staged copy of %s to search\n' "${file}" >&2
      exit 1
    }
    subject="${staged}"
  fi

  if grep -aonE "${PATTERN}" -- "${subject}" > "${hits}"; then
    # grep says `line:address`, and the name goes in front of it. Both are
    # NUL-terminated, that being the one byte a file name cannot contain: a name
    # with a colon, a tab or a newline in it would otherwise be read as part of
    # the match, and a name ending in an allowed address would have the
    # disallowed one appended to it and pass.
    while IFS= read -r hit; do
      printf '%s\0%s\0' "${file}" "${hit}" >> "${matches}"
    done < "${hits}"
  else
    rc=$?
    if [ "${rc}" -ne 1 ]; then
      printf '%s could not be searched, grep exited %s\n' "${file}" "${rc}" >&2
      exit 1
    fi
  fi
done < "${list}"

found=0
while IFS= read -r -d '' file && IFS= read -r -d '' hit; do
  line="${hit%%:*}"
  address="${hit#*:}"
  [ -n "${address}" ] || continue
  if ! printf '%s' "${address}" | grep -qE "${ALLOWED}"; then
    printf '%s:%s: %s is neither a documentation nor a private address\n' "${file}" "${line}" "${address}" >&2
    found=1
  fi
done < "${matches}"

if [ "${found}" -ne 0 ]; then
  echo >&2
  echo "Use 192.0.2.x, 198.51.100.x or 203.0.113.x instead — they exist for this." >&2
  exit 1
fi
echo "every address written down here is a documentation or private one"
