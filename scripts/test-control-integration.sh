#!/bin/zsh
# Exercise the actual Agent Bridge catalogue and settings on a disposable H Chat profile, without starting the desktop app.
set -euo pipefail
cd "${0:A:h:h}"
build_dir="${HELLOCHAT_BUILD_DIR:-$PWD/.build.noindex}"
mkdir -p "$build_dir"
fixture=$(mktemp -d "$build_dir/control-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
touch "$fixture/control-fixture-owner"
swift build --build-tests --scratch-path "$build_dir" --jobs 3
HCHAT_CONTROL_FIXTURE_HOME="${fixture:A}" CFFIXED_USER_HOME="${fixture:A}" swift test --skip-build --scratch-path "$build_dir" --filter AgentControlIntegrationTests
