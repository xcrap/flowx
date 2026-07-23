.PHONY: dev build test check clean generate

generate:
	xcodegen generate

# Debug build for development (bundle: com.flowx.app.dev)
dev: generate
	xcodebuild -project FlowX.xcodeproj -scheme FlowX -configuration Debug -derivedDataPath build/dev -quiet
	mkdir -p dist
	rm -rf dist/FlowX-Dev.app
	cp -R build/dev/Build/Products/Debug/FlowX.app dist/FlowX-Dev.app
	open dist/FlowX-Dev.app

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
