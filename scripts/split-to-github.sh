#!/usr/bin/env bash
# Publish sdks/ruby to its public GitHub repository.
#
# The monorepo (GitLab, private) is the source of truth. This pushes ONLY the
# sdks/ruby subtree, with its history, to github.com/sendclipper/sendclipper-ruby.
# Never push the monorepo itself there.
#
#   sdks/ruby/scripts/split-to-github.sh            # push main
#   sdks/ruby/scripts/split-to-github.sh v0.1.0     # push main and tag v0.1.0 (publishes to RubyGems)
#
# REMOTE defaults to the `github-sendclipper` SSH alias (~/.ssh/config), which
# authenticates as the sendclipper GitHub account.
set -euo pipefail

REMOTE="${REMOTE:-git@github-sendclipper:sendclipper/sendclipper-ruby.git}"
TAG="${1:-}"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [ -n "$(git status --porcelain -- sdks/ruby)" ]; then
  echo "sdks/ruby has uncommitted changes; commit them first." >&2
  exit 1
fi

if [ -n "$TAG" ]; then
  version="$(sed -n 's/^  VERSION = "\(.*\)"/\1/p' sdks/ruby/lib/sendclipper/version.rb)"
  if [ "v$version" != "$TAG" ]; then
    echo "tag $TAG does not match SendClipper::VERSION $version" >&2
    exit 1
  fi
fi

SPLIT="$(git subtree split --prefix=sdks/ruby HEAD 2>/dev/null)"
echo "split commit: $SPLIT"
git push "$REMOTE" "$SPLIT:refs/heads/main"

if [ -n "$TAG" ]; then
  git push "$REMOTE" "$SPLIT:refs/tags/$TAG"
fi
