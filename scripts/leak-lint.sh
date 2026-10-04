#!/usr/bin/env bash
# Every IPv4 address written down in this repository has to come from a range
# reserved for documentation, or from one of the private prefixes named below.
# Nothing else may be here.
#
# "Private" was the whole rule until 2026-10-04, and it was too wide: a tunnel
# address a VPN handed out is a 10.x address, so a route table copied off this
# machine passed the lint with two live addresses in it. Private space is where
# real internal addresses live. The prefixes allowed here are the ones the
# fixtures invent, enumerated, so a new 10.x address fails until somebody says
# in this file what it is.
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

# Documentation space (RFC 5737), the addresses that mean nothing on their own,
# multicast, and the invented private prefixes: 10.0.0.x and 10.9.9.x for a
# gateway, 10.11.12.x and 10.11.13.x for an AWS VPN client's replies, and
# 172.16.0.x, 192.168.0.x and 192.168.1.x for a home network. 10.0.0.0/8,
# 172.16.0.0/12 and 192.168.0.0/16 themselves are the examples the docs give of
# a CIDR a VPN hands out, and they are what somebody would actually type.
readonly ALLOWED='^(0\.0\.0\.0$|127\.|169\.254\.|255\.255\.255\.255$|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|22[4-9]\.|23[0-9]\.|10\.0\.0\.|10\.9\.9\.|10\.11\.1[23]\.|172\.16\.0\.|192\.168\.[01]\.)'
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
  echo "A private address is not safe by being private: a real one looks the same." >&2
  exit 1
fi
echo "every address written down here is a documentation or an invented one"
