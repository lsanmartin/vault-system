# --- Destinos (Targets) ---
TARGET_X86 = x86_64-apple-darwin
TARGET_ARM = aarch64-apple-darwin

# --- Rutas de Homebrew ---
BREW_PATH_X86 = /usr/local/opt/duckdb
BREW_PATH_ARM = /opt/homebrew/opt/duckdb

export LIBCLANG_PATH = /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib

XCFRAMEWORK_DIR = target/apple_core.xcframework

# --- App Config ---
APP_NAME = VaultSystem
XCODE_PROJECT = apple/VaultSystem.xcodeproj
XCODE_SCHEME = VaultSystem
ARCHIVE_PATH = apple/build/$(APP_NAME).xcarchive
APP_BUNDLE = $(ARCHIVE_PATH)/Products/Applications/$(APP_NAME).app

.PHONY: all clean build-x86_64 build-aarch64 build-universal xcode-build deploy release

all: build-universal

build-x86_64:
	@echo "--- Compilando Core de Rust para Intel ($(TARGET_X86)) ---"
	MACOSX_DEPLOYMENT_TARGET=15.0 DUCKDB_LIB_DIR="$(BREW_PATH_X86)/lib" DUCKDB_INCLUDE_DIR="$(BREW_PATH_X86)/include" \
	cargo build --target $(TARGET_X86) --release

build-aarch64:
	@echo "--- Compilando Core de Rust para Apple Silicon ($(TARGET_ARM)) ---"
	LIBCLANG_PATH="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib" \
	MACOSX_DEPLOYMENT_TARGET=15.0 DUCKDB_LIB_DIR="$(BREW_PATH_ARM)/lib" DUCKDB_INCLUDE_DIR="$(BREW_PATH_ARM)/include" \
	cargo build --target $(TARGET_ARM) --release

build-universal: build-aarch64
	@echo "--- Generando Enlaces FFI ---"
	@TARGET=$(TARGET_ARM); \
	BREW_PATH=$(BREW_PATH_ARM); \
	DUCKDB_LIB_DIR="$$BREW_PATH/lib" DUCKDB_INCLUDE_DIR="$$BREW_PATH/include" RUSTFLAGS="-L $$BREW_PATH/lib -l duckdb" \
	cargo run --target $$TARGET --bin uniffi-bindgen --features=uniffi/cli -- generate --library target/$$TARGET/release/libvault_core.dylib --language swift --out-dir core/bindings/

	@echo "--- Empaquetando XCFramework para Xcode (Sólo Apple Silicon) ---"
	rm -rf $(XCFRAMEWORK_DIR)
	xcodebuild -create-xcframework \
		-library target/$(TARGET_ARM)/release/libvault_core.dylib -headers core/bindings/ \
		-output $(XCFRAMEWORK_DIR)

	@echo "--- Fijando @rpath install name en XCFramework (safety net) ---"
	@DYLIB_IN_FW=$$(find $(XCFRAMEWORK_DIR) -name 'libvault_core.dylib' | head -1); \
	if [ -n "$$DYLIB_IN_FW" ]; then \
		install_name_tool -id @rpath/libvault_core.dylib "$$DYLIB_IN_FW"; \
		echo "✅ install name → @rpath/libvault_core.dylib"; \
	fi

clean:
	cargo clean
	rm -rf target/
	rm -rf $(ARCHIVE_PATH)

xcode-build:
	@echo "--- Regenerando .xcodeproj desde project.yml ---"
	@if command -v xcodegen &>/dev/null; then \
		xcodegen generate --spec apple/project.yml --project apple/; \
		echo "✅ .xcodeproj regenerado"; \
	else \
		echo "⚠️  xcodegen no encontrado, usando .xcodeproj existente"; \
	fi
	@echo "--- Archivando $(APP_NAME) (Release) ---"
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme $(XCODE_SCHEME) \
		-configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		-arch arm64 \
		archive \
		ONLY_ACTIVE_ARCH=YES \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGNING_REQUIRED=NO
	@echo "--- Archive generado en $(ARCHIVE_PATH) ---"

deploy: xcode-build
	@echo "--- Desplegando a /Applications ---"
	@mkdir -p ~/.vault_system
	@if [ -d "/Applications/$(APP_NAME).app" ]; then \
		echo "Eliminando versión anterior..."; \
		rm -rf "/Applications/$(APP_NAME).app"; \
	fi
	cp -R "$(APP_BUNDLE)" /Applications/
	@echo "✅ $(APP_NAME) v0.1.0 instalado en /Applications/"
	@echo "   Ejecutar con: open /Applications/$(APP_NAME).app"

release: build-universal xcode-build deploy
	@echo "=== Release Pipeline Completo ==="
	@echo "  ✅ Rust Core compilado"
	@echo "  ✅ XCFramework empaquetado"
	@echo "  ✅ App archivada y desplegada"
	@echo "  → /Applications/$(APP_NAME).app"

