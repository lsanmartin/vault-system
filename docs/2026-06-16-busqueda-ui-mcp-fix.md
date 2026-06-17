# Búsqueda UI, Persistencia MCP y DuckDB

## Análisis y Estrategia
- **Problema 1 (Buscador)**: El usuario reportó que el buscador de texto "solo estaba buscando en carpetas y no en notas".
- **Problema 2 (Persistencia MCP)**: El usuario indicó que al recompilar el proyecto, las configuraciones del MCP desaparecían.
- **Estrategia**: Analizar exhaustivamente el ciclo de vida de `queryNotes` y DuckDB para comprobar el contenido indexado. Para MCP, examinar el comportamiento del `App Sandbox` de macOS durante los ciclos de build en Xcode.

## Decisiones Técnicas
- **Fix UI Buscador**:
  - **Caminos tomados**: Se identificó que DuckDB y `scanVault` sí estaban indexando y devolviendo correctamente los matches. El bug estaba en `EditorViewModel.updateGridForCurrentPath()`, donde la lógica anterior concatenaba la lista de resultados de la búsqueda con las notas mostradas previamente en el directorio actual, ensuciando la vista e impidiendo distinguir los resultados reales. La corrección implementada asegura que `self.allFolders` y `self.allNotes` se manejen limpiamente.
  - **Alternativas descartadas**: Modificar el motor de búsqueda en Rust para emitir flags booleanas, ya que el motor funcionaba correctamente.
- **Diagnóstico MCP Tokens**:
  - **Explicación técnica**: El archivo `~/.vault_system/mcp_tokens.json` se guarda utilizando la variable de entorno `HOME` en Rust. Dado que la aplicación tiene la configuración `App Sandbox: YES`, la variable `HOME` apunta al directorio aislado de la app (`~/Library/Containers/com.apple.vault...`). Durante recompilaciones limpias o cambios estructurales en DerivedData, Xcode reinicia este contenedor, borrando los tokens y el `system_workspace`.
  - **Próximo paso**: Se informa al usuario la causa y se propone migrar la persistencia de configuraciones globales a `UserDefaults` (que sobrevive mejor a las recompilaciones) o a una subcarpeta fija dentro del vault (ej: `.vault_system`).

## Próximos Pasos
- Validar con el usuario si prefiere usar `UserDefaults` para la persistencia del MCP en vez de guardar archivos estáticos en el Sandbox.
- Verificar el funcionamiento en caliente de los Highlights inyectados mediante `mark.js`.
