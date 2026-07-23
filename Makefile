.PHONY: dev build test check clean generate

generate:
	xcodegen generate

# Debug build for development (bundle: com.flowx.app.dev)
dev: generate
	xcodebuild -project FlowX.xcodeproj -scheme FlowX -configuration Debug -derivedDataPath build/dev -quiet
	@set -eu; \
	flowx_dev_pids() { \
		/usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); $$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.flowx.app.dev").js.map(function(app) { return Number(app.processIdentifier); }).join(" ")'; \
	}; \
	pids="$$(flowx_dev_pids)"; \
	if [ -n "$$pids" ]; then \
		/usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); $$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.flowx.app.dev").js.forEach(function(app) { app.terminate; });'; \
		attempt=0; \
		while [ "$$attempt" -lt 50 ] && [ -n "$$(flowx_dev_pids)" ]; do \
			/bin/sleep 0.1; \
			attempt=$$((attempt + 1)); \
		done; \
	fi; \
	pids="$$(flowx_dev_pids)"; \
	if [ -n "$$pids" ]; then \
		echo "FlowX-Dev did not quit in time; force-terminating exact process IDs: $$pids" >&2; \
		/usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); $$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.flowx.app.dev").js.forEach(function(app) { app.forceTerminate; });'; \
		attempt=0; \
		while [ "$$attempt" -lt 20 ] && [ -n "$$(flowx_dev_pids)" ]; do \
			/bin/sleep 0.1; \
			attempt=$$((attempt + 1)); \
		done; \
	fi; \
	pids="$$(flowx_dev_pids)"; \
	if [ -n "$$pids" ]; then \
		echo "FlowX-Dev process IDs still running after bounded shutdown: $$pids" >&2; \
		exit 1; \
	fi; \
	/bin/mkdir -p dist; \
	/bin/rm -rf dist/FlowX-Dev.app; \
	/bin/cp -R build/dev/Build/Products/Debug/FlowX-Dev.app dist/FlowX-Dev.app; \
	/usr/bin/open -n dist/FlowX-Dev.app; \
	attempt=0; \
	pids="$$(flowx_dev_pids)"; \
	while [ "$$attempt" -lt 50 ] && [ -z "$$pids" ]; do \
		/bin/sleep 0.1; \
		attempt=$$((attempt + 1)); \
		pids="$$(flowx_dev_pids)"; \
	done; \
	set -- $$pids; \
	if [ "$$#" -ne 1 ]; then \
		echo "Expected exactly one FlowX-Dev process after launch; found $$#: $$pids" >&2; \
		exit 1; \
	fi

# Release build
build: generate
	xcodebuild archive -project FlowX.xcodeproj -scheme FlowX -configuration Release -archivePath build/FlowX.xcarchive -quiet
	mkdir -p dist
	rm -rf dist/FlowX.app
	cp -R build/FlowX.xcarchive/Products/Applications/FlowX.app dist/FlowX.app

test:
	cd Packages/FXCore && swift test --scratch-path ../../build/tests/FXCore --quiet
	cd Packages/FXAgent && swift test --scratch-path ../../build/tests/FXAgent --quiet
	cd Packages/FXTerminal && swift test --scratch-path ../../build/tests/FXTerminal --quiet
	cd Packages/FXDesign && swift test --scratch-path ../../build/tests/FXDesign --quiet
	@echo "All tests passed."

check: test generate
	xcodebuild -project FlowX.xcodeproj -scheme FlowX -configuration Debug -derivedDataPath build/check CODE_SIGNING_ALLOWED=NO build -quiet
	@echo "Tests and app integration build passed."

clean:
	rm -rf build dist
	xcodebuild -project FlowX.xcodeproj -scheme FlowX clean -quiet 2>/dev/null || true
	@echo "Clean."
