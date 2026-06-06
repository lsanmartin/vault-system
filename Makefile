# --- Destinos (Targets) ---
TARGET_X86 = x86_64-apple-darwin
TARGET_ARM = aarch64-apple-darwin

# --- Rutas de Homebrew ---
BREW_PATH_X86 = /usr/local/opt/duckdb
BREW_PATH_ARM = /opt/homebrew/opt/duckdb

XCFRAMEWORK_DIR = target/apple_core.xcframework

.PHONY: all clean build-x86_64 build-aarch64 build-universal

all: build-universal

build-x86_64:
	@echo "--- Compilando Core de Rust para Intel ($(TARGET_X86)) ---"
	MACOSX_DEPLOYMENT_TARGET=15.0 DUCKDB_LIB_DIR="$(BREW_PATH_X86)/lib" DUCKDB_INCLUDE_DIR="$(BREW_PATH_X86)/include" \
	cargo build --target $(TARGET_X86) --release

build-aarch64:
	@echo "--- Compilando Core de Rust para Apple Silicon ($(TARGET_ARM)) ---"
	MACOSX_DEPLOYMENT_TARGET=15.0 DUCKDB_LIB_DIR="$(BREW_PATH_ARM)/lib" DUCKDB_INCLUDE_DIR="$(BREW_PATH_ARM)/include" \
	cargo build --target $(TARGET_ARM) --release

build-universal: build-x86_64 build-aarch64
	@echo "--- Generando Enlaces FFI ---"
	@HOST_ARCH=$$(uname -m); \
	if [ "$$HOST_ARCH" = "x86_64" ]; then \
		TARGET=$(TARGET_X86); \
		BREW_PATH=$(BREW_PATH_X86); \
	else \
		TARGET=$(TARGET_ARM); \
		BREW_PATH=$(BREW_PATH_ARM); \
	fi; \
	DUCKDB_LIB_DIR="$$BREW_PATH/lib" DUCKDB_INCLUDE_DIR="$$BREW_PATH/include" \
	cargo run --bin uniffi-bindgen --features=uniffi/cli -- generate --library target/$$TARGET/release/libvault_core.dylib --language swift --out-dir core/bindings/

	@echo "--- Creando binario universal (lipo) ---"
	mkdir -p target/universal/release
	lipo -create -output target/universal/release/libvault_core.a \
		target/$(TARGET_X86)/release/libvault_core.a \
		target/$(TARGET_ARM)/release/libvault_core.a

	@echo "--- Empaquetando XCFramework para Xcode ---"
	rm -rf $(XCFRAMEWORK_DIR)
	xcodebuild -create-xcframework \
		-library target/universal/release/libvault_core.a -headers core/bindings/ \
		-output $(XCFRAMEWORK_DIR)

clean:
	cargo clean
	rm -rf target/
