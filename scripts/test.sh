#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build.noindex/module-cache
xcrun swiftc -module-cache-path build.noindex/module-cache Sources/Metrics.swift Sources/PanelLayout.swift Tests/main.swift -o build.noindex/metrics-tests
build.noindex/metrics-tests
xcrun clang -O2 Tests/bridge_test.c Sources/MonitorBridge.c -o build.noindex/bridge-tests
build.noindex/bridge-tests
python3 Tests/test_usage.py
xcrun clang -O2 -c Sources/MonitorBridge.c -o build.noindex/MonitorBridge-test.o
xcrun swiftc -module-cache-path build.noindex/module-cache -import-objc-header Sources/MonitorBridge.h Sources/Metrics.swift Sources/Sampler.swift Sources/AccountUsage.swift Tests/AccountUsageTests.swift build.noindex/MonitorBridge-test.o -o build.noindex/account-tests
build.noindex/account-tests
