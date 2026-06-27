# 2026-06-27 - Menú Contextual en Background de Listado de Notas

## Análisis y Estrategia
Se incorporó la funcionalidad de crear notas y carpetas directamente desde el fondo (background) de la segunda columna ([MainContentColumn](file:///Users/lsanmartin/dev/vault-system/apple/Shared/Views/Editor/MainEditorView.swift#L352)), facilitando la creación rápida de archivos mediante un clic secundario en el área vacía del listado.

## Decisiones Técnicas
- **Intercepción de Gestos en SwiftUI**: Se aplicó el modificador `.contextMenu` directamente sobre el fondo (`.background(...)`) del `ScrollView` en ambos modos de visualización (lista y cuadrícula). Esto intercepta clics secundarios en el área vacía de la segunda columna sin interferir con los gestos táctiles de selección (`.onTapGesture`) ni los menús contextuales específicos de cada tarjeta o fila ([NoteCard](file:///Users/lsanmartin/dev/vault-system/apple/Shared/Views/Editor/MainEditorView.swift#L3) y [FileRowView](file:///Users/lsanmartin/dev/vault-system/apple/Shared/Views/Editor/MainEditorView.swift#L897)).
- **Integración con EditorViewModel**: Se re-utilizaron de forma directa las acciones `createNewNote` y `createNewFolder` del [EditorViewModel](file:///Users/lsanmartin/dev/vault-system/apple/Shared/Views/Editor/EditorViewModel.swift) que administran la creación física en DuckDB y en disco, además del renombrado inmediato y foco automático.

## Próximos Pasos
- Validar consistencia al crear notas en workspaces vacíos o sin selección activa.
