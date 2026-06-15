# --- Destinos (Targets) ---
TARGET_X86 = x86_64-apple-darwin
TARGET_ARM = aarch64-apple-darwin

# --- Rutas de Homebrew ---
BREW_PATH_X86 = /usr/local/opt/duckdb
BREW_PATH_ARM = /opt/homebrew/opt/duckdb

export LIBCLANG_PATH = /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib

XCFRAMEWORK_DIR = target/apple_core.xcframework

.PHONY: all clean build-x86_64 build-aarch64 build-universal

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

clean:
	cargo clean
	rm -rf target/
