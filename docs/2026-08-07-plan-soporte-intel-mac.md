# Plan: Soporte Mac Intel (x86_64) — vault-system

**Fecha**: 2026-08-07
**Estado**: Planificado (retomar en sesión futura)
**Objetivo**: Compilar y ejecutar vault-system en Mac Intel sin MLX local.

---

## 1. Diagnóstico Actual

El proyecto tiene soporte parcial para x86_64:

| Aspecto | Estado | Detalle |
|---|---|---|
| Rust target `x86_64-apple-darwin` | Definido pero no integrado | `make build-x86_64` existe pero no se invoca en ningún pipeline |
| `build-universal` | Solo ARM | Depende solo de `build-aarch64`, XCFramework single-arch |
| `xcode-build` | Hardcodea `-arch arm64` | Línea 87 del Makefile |
| `VALID_ARCHS` | Correcto | `x86_64 arm64` en `project.yml` |
| `ARCHS` | Correcto | `$(ARCHS_STANDARD)` en `project.yml` |
| DuckDB paths | Correcto | `/usr/local/opt/duckdb` (Intel) vs `/opt/homebrew/opt/duckdb` (ARM) |
| `LIBRARY_SEARCH_PATHS` por arquitectura | Correcto | Condicionales `[arch=x86_64]` y `[arch=arm64]` en project.yml |
| `LD_RUNPATH_SEARCH_PATHS` | Hardcodeado ARM | Línea 51: `aarch64-apple-darwin` fijo |
| MLX Swift | Solo ARM | `mlx-swift-lm` requiere Apple Silicon (Neural Engine + GPU unificada) |

---

## 2. Cambios Requeridos

### 2.1 Makefile — Nuevo target `build-intel`

```makefile
# Nuevo target: build completo para Intel (sin MLX)
.PHONY: build-intel
build-intel: build-x86_64
	@echo "--- Generando Enlaces FFI (x86_64) ---"
	@TARGET=$(TARGET_X86); \
	BREW_PATH=$(BREW_PATH_X86); \
	DUCKDB_LIB_DIR="$$BREW_PATH/lib" DUCKDB_INCLUDE_DIR="$$BREW_PATH/include" RUSTFLAGS="-L $$BREW_PATH/lib -l duckdb" \
	cargo run --target $$TARGET --bin uniffi-bindgen --features=uniffi/cli -- generate \
		--library target/$$TARGET/release/libvault_core.dylib \
		--language swift --out-dir core/bindings/

	@echo "--- Empaquetando XCFramework (x86_64) ---"
	rm -rf $(XCFRAMEWORK_DIR)
	xcodebuild -create-xcframework \
		-library target/$(TARGET_X86)/release/libvault_core.dylib \
		-headers core/bindings/ \
		-output $(XCFRAMEWORK_DIR)

	@DYLIB_IN_FW=$$(find $(XCFRAMEWORK_DIR) -name 'libvault_core.dylib' | head -1); \
	if [ -n "$$DYLIB_IN_FW" ]; then \
		install_name_tool -id @rpath/libvault_core.dylib "$$DYLIB_IN_FW"; \
		echo "✅ install name → @rpath/libvault_core.dylib"; \
	fi

	@echo "--- Core x86_64 listo ---"
	@echo "   Luego: make xcode-build-intel"
```

### 2.2 Makefile — Nuevo target `xcode-build-intel`

```makefile
.PHONY: xcode-build-intel
xcode-build-intel:
	@echo "--- Regenerando .xcodeproj desde project.yml ---"
	@if command -v xcodegen &>/dev/null; then \
		xcodegen generate --spec apple/project.yml --project apple/; \
	fi
	@echo "--- Archivando $(APP_NAME) para Intel (Release) ---"
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme $(XCODE_SCHEME) \
		-configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		-arch x86_64 \
		-skipPackagePluginValidation \
		-skipMacroValidation \
		archive \
		ONLY_ACTIVE_ARCH=YES \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGNING_REQUIRED=NO
```

### 2.3 Makefile — Pipeline completo Intel

```makefile
.PHONY: release-intel
release-intel: preflight build-intel xcode-build-intel deploy
	@echo "=== Release Intel Pipeline Completo ==="
	@echo "  ✅ Rust Core compilado (x86_64)"
	@echo "  ✅ XCFramework empaquetado (x86_64)"
	@echo "  ✅ App archivada y desplegada"
	@echo "  → /Applications/$(APP_NAME).app"
```

### 2.4 `apple/project.yml` — Runpath dinámico por arquitectura

Cambiar:
```yaml
LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks $(PROJECT_DIR)/../target/aarch64-apple-darwin/release/deps"
```

Por:
```yaml
LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks"
LD_RUNPATH_SEARCH_PATHS[arch=x86_64]: "$(inherited) $(PROJECT_DIR)/../target/x86_64-apple-darwin/release/deps"
LD_RUNPATH_SEARCH_PATHS[arch=arm64]: "$(inherited) $(PROJECT_DIR)/../target/aarch64-apple-darwin/release/deps"
```

### 2.5 `apple/project.yml` — MLX condicional por arquitectura

MLX Swift packages solo se resuelven en ARM. En Intel hay que excluirlos:

```yaml
dependencies:
  - framework: ../target/apple_core.xcframework
    embed: true
  - package: mlx-swift-lm          # ← solo ARM
    product: MLXLLM
    platformFilter: arm64           # ← nuevo
  - package: mlx-swift-lm
    product: MLXLMCommon
    platformFilter: arm64
  - package: mlx-swift-lm
    product: MLXHuggingFace
    platformFilter: arm64
  - package: swift-huggingface
    product: HuggingFace
    platformFilter: arm64
  - package: swift-transformers
    product: Tokenizers
    platformFilter: arm64
```

**Nota**: Verificar si `platformFilter` es compatible con la versión de xcodegen usada. Alternativa: crear un segundo target `VaultSystem-Intel` sin dependencias MLX.

### 2.6 Swift — Guards condicionales para LocalBrain

En todos los archivos Swift que referencian `LocalBrain`, `MLXLLM`, `MLXLMCommon`:

```swift
#if arch(arm64)
import MLXLLM
import MLXLMCommon
#endif

// En la clase/struct que lo usa:
#if arch(arm64)
    @Published var localBrain: LocalBrain?
    var isLocalBrainAvailable: Bool { true }
#else
    var isLocalBrainAvailable: Bool { false }
#endif
```

**Archivos a revisar** (buscar referencias a MLX):
- `LocalBrain.swift`
- `ChatViewModel.swift` o similar (donde se instancia el cerebro local)
- `SettingsView.swift` o similar (toggle de cerebro local)
- Cualquier vista que muestre el estado del cerebro local

### 2.7 UI — Ocultar toggle en Intel

Donde se renderiza el toggle de "Cerebro Local":

```swift
if isLocalBrainAvailable {
    Toggle("Cerebro Local (Gemma 4)", isOn: $localBrainEnabled)
}
```

---

## 3. Dependencias Sistema (Mac Intel)

Ejecutar **antes** del build:

```bash
# 1. Homebrew en /usr/local/ (nativo Intel, NO Rosetta)
brew install duckdb

# 2. Rust target x86_64
rustup target add x86_64-apple-darwin

# 3. xcodegen (si no está)
brew install xcodegen

# 4. Verificar arquitectura
uname -m          # debe decir x86_64
xcrun --show-sdk-path  # debe mostrar una ruta válida
```

---

## 4. Pasos de Ejecución (orden)

1. Instalar dependencias (sección 3)
2. `make build-intel` — compila Rust core para x86_64 + genera XCFramework
3. `make xcode-build-intel` — archiva la app SwiftUI para x86_64
4. `make deploy` — copia a `/Applications/`
5. `open /Applications/VaultSystem.app` — ejecutar

O en un solo paso:
```bash
make release-intel
```

---

## 5. Limitaciones Conocidas

| Funcionalidad | Intel | ARM |
|---|---|---|
| MCP Server (herramientas locales) | ✅ | ✅ |
| Agentes externos (DeepSeek, Claude, OpenAI) | ✅ | ✅ |
| DuckDB + FileWatcher | ✅ | ✅ |
| Git local sin remote | ✅ | ✅ |
| Chat con @menciones | ✅ | ✅ |
| RBAC granular (tokens MCP) | ✅ | ✅ |
| Validación OKF + hooks | ✅ | ✅ |
| Comandos `/plan`, `/goal`, `/design` | ✅ | ✅ |
| **Gemma 4 local (MLX)** | ❌ No disponible | ✅ |
| **Embeddings locales (MLX)** | ❌ No disponible | ✅ |
| Liquid Glass (Tahoe) | ✅ | ✅ |
| WebView Markdown | ✅ | ✅ |

---

## 6. Verificación Post-Build

- [ ] App abre sin crash en Mac Intel
- [ ] Chat con agente externo (DeepSeek) funciona
- [ ] Navegación de notas (DuckDB) funciona
- [ ] Toggle "Cerebro Local" no aparece o está deshabilitado
- [ ] MCP server responde a herramientas de lectura/escritura
- [ ] Sin leaks de memoria ni consumo anómalo de CPU
- [ ] Build no arrastra símbolos MLX ni frameworks ARM

---

## 7. Alternativas No Exploradas

- **Universal Binary (fat binary)**: compilar para ambas arquitecturas con `lipo`. Más complejo pero permite un solo `.app` que corre nativo en ambas. Requiere build machine ARM con cross-compilation a x86_64 (o CI con runners de ambas arquitecturas).
- **Rosetta 2**: ejecutar el binario ARM en Intel vía Rosetta. No probado. MLX probablemente fallaría igual.

---

## 8. Referencias

- `Makefile` — targets `build-x86_64`, `build-aarch64`, `build-universal`, `xcode-build`
- `apple/project.yml` — config Xcode, dependencias MLX, LIBRARY_SEARCH_PATHS
- `_specs.md` — arquitectura general
- `KANBAN.md` — backlog y fases
- `docs/2026-07-29-integracion-gemma-local-swift-mlx.md` — integración MLX
