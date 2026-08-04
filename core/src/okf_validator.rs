/// Validador OKF determinista.
/// Valida archivos _memory.md, _specs.md, _lore.md de la tríada Open Knowledge Format.

use std::collections::{HashMap, HashSet};
use std::path::Path;

#[derive(serde::Serialize)]
struct ValidationReport {
    file: String,
    is_valid: bool,
    errors: Vec<String>,
    warnings: Vec<String>,
    has_frontmatter: bool,
    sections_found: Vec<String>,
}

/// Valida un archivo OKF (_memory.md, _specs.md, _lore.md).
/// Retorna JSON con errores, warnings y secciones encontradas.
pub fn validate_okf_file(file_path: &str) -> String {
    let path = Path::new(file_path);
    let file_name = path.file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("desconocido");

    let mut report = ValidationReport {
        file: file_path.to_string(),
        is_valid: true,
        errors: Vec::new(),
        warnings: Vec::new(),
        has_frontmatter: false,
        sections_found: Vec::new(),
    };

    // Solo validar archivos de la tríada OKF
    if !matches!(file_name, "_memory.md" | "_specs.md" | "_lore.md") {
        report.warnings.push("No es un archivo de la tríada OKF (_memory.md, _specs.md, _lore.md).".into());
    }

    // Leer archivo
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) => {
            report.is_valid = false;
            report.errors.push(format!("No se pudo leer el archivo: {}", e));
            return serde_json::to_string_pretty(&report).unwrap_or_default();
        }
    };

    // Validar frontmatter YAML (delimitadores ---)
    validate_frontmatter(&content, &mut report);

    // Validar según tipo de archivo
    match file_name {
        "_memory.md" => validate_memory(&content, &mut report),
        "_specs.md" => validate_specs(&content, &mut report),
        "_lore.md" => validate_lore(&content, &mut report),
        _ => {}
    }

    // Detectar secciones del documento
    detect_sections(&content, &mut report);

    report.is_valid = report.errors.is_empty();
    serde_json::to_string_pretty(&report).unwrap_or_default()
}

/// Valida el frontmatter YAML delimitado por ---
fn validate_frontmatter(content: &str, report: &mut ValidationReport) {
    let lines: Vec<&str> = content.lines().collect();
    let mut frontmatter_open = false;
    let mut frontmatter_close = false;
    let mut yaml_lines: Vec<&str> = Vec::new();
    let mut has_content_before_fm = false;

    for line in &lines {
        let trimmed = line.trim();
        if trimmed == "---" {
            if !frontmatter_open {
                frontmatter_open = true;
                if has_content_before_fm {
                    report.warnings.push("Frontmatter (---) no está al inicio del archivo.".into());
                }
            } else {
                frontmatter_close = true;
                break;
            }
        } else if frontmatter_open {
            yaml_lines.push(line);
        } else if !trimmed.is_empty() {
            has_content_before_fm = true;
        }
    }

    if frontmatter_open && !frontmatter_close {
        report.warnings.push("Frontmatter abierto con --- pero no cerrado.".into());
    }

    if frontmatter_open && frontmatter_close {
        report.has_frontmatter = true;

        // Validar líneas YAML: deben ser key: value o listas con -
        for (i, line) in yaml_lines.iter().enumerate() {
            let trimmed = line.trim();
            if trimmed.is_empty() { continue; }

            if trimmed.starts_with('-') {
                // Elemento de lista, válido
                continue;
            }

            if !trimmed.contains(':') {
                report.warnings.push(format!(
                    "Línea {} del frontmatter no parece YAML válido: '{}' (falta ':')",
                    i + 1, trimmed
                ));
            } else {
                let parts: Vec<&str> = trimmed.splitn(2, ':').collect();
                let key = parts[0].trim();
                let value = parts.get(1).map(|v| v.trim()).unwrap_or("");

                if key.is_empty() {
                    report.warnings.push(format!(
                        "Línea {} del frontmatter tiene clave vacía: '{}'",
                        i + 1, trimmed
                    ));
                }
                if value.is_empty() {
                    report.warnings.push(format!(
                        "Línea {} del frontmatter tiene valor vacío: '{}'",
                        i + 1, key
                    ));
                }
            }
        }
    }
}

/// Valida _memory.md: debe tener sección ## Contexto, ## Hitos, ## Historial (o similares)
fn validate_memory(content: &str, report: &mut ValidationReport) {
    let lower = content.to_lowercase();
    let has_contexto = lower.contains("## contexto");
    let has_hitos = lower.contains("## hito");
    let has_historial = lower.contains("## historial");

    if !has_contexto {
        report.warnings.push("_memory.md no tiene sección '## Contexto'. Se recomienda incluir una descripción del proyecto.".into());
    }
    if !has_hitos {
        report.warnings.push("_memory.md no tiene sección '## Hitos'. Se recomienda registrar hitos con [HITO] por sesión.".into());
    }
    if !has_historial {
        report.warnings.push("_memory.md no tiene sección '## Historial'. Se recomienda llevar historial de sesiones.".into());
    }
}

/// Valida _specs.md: arquitectura, reglas, dependencias
fn validate_specs(content: &str, report: &mut ValidationReport) {
    let lower = content.to_lowercase();
    let has_arquitectura = lower.contains("## arquitectura");
    let has_reglas = lower.contains("## reglas");
    let has_deps = lower.contains("## dependencias");

    if !has_arquitectura {
        report.warnings.push("_specs.md no tiene sección '## Arquitectura'.".into());
    }
    if !has_reglas {
        report.warnings.push("_specs.md no tiene sección '## Reglas'.".into());
    }
    if !has_deps {
        report.warnings.push("_specs.md no tiene sección '## Dependencias'.".into());
    }
}

/// Valida _lore.md: propósito, glosario, usuarios
fn validate_lore(content: &str, report: &mut ValidationReport) {
    let lower = content.to_lowercase();
    if !lower.contains("## prop") && !lower.contains("## propósito") && !lower.contains("## proposito") {
        report.warnings.push("_lore.md no tiene sección '## Propósito'. Se recomienda describir el propósito del proyecto.".into());
    }
    if !lower.contains("## glosario") {
        report.warnings.push("_lore.md no tiene sección '## Glosario'. Se recomienda definir términos clave.".into());
    }
    if !lower.contains("## usuario") {
        report.warnings.push("_lore.md no tiene sección '## Usuarios'. Se recomienda listar usuarios y roles.".into());
    }
}

/// Detecta secciones markdown (## heading)
fn detect_sections(content: &str, report: &mut ValidationReport) {
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("## ") {
            let section = trimmed[3..].trim().to_string();
            report.sections_found.push(section);
        }
    }
}

/// Detecta ciclos en las dependencias entre proyectos.
/// Escanea un directorio en busca de _specs.md y construye un grafo de dependencias.
pub fn validate_dependency_cycles(root_dir: &str) -> String {
    let mut graph: HashMap<String, Vec<String>> = HashMap::new();
    let mut errors: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();
    let mut projects_found = 0;

    // Recorrer directorio buscando _specs.md
    if let Ok(entries) = std::fs::read_dir(root_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                let specs_path = path.join("_specs.md");
                if specs_path.exists() {
                    projects_found += 1;
                    let project_name = path.file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("desconocido")
                        .to_string();

                    if let Ok(content) = std::fs::read_to_string(&specs_path) {
                        let deps = extract_dependencies(&content);
                        graph.insert(project_name, deps);
                    }
                }
            }
        }
    }

    if graph.is_empty() {
        return serde_json::json!({
            "has_cycles": false,
            "projects_scanned": projects_found,
            "cycles_found": [],
            "errors": ["No se encontraron _specs.md con sección de dependencias."],
            "warnings": warnings,
        }).to_string();
    }

    // Detectar ciclos con DFS
    let cycles = find_cycles(&graph);

    if !cycles.is_empty() {
        errors.push(format!("Se detectaron {} ciclo(s) de dependencia:", cycles.len()));
        for cycle in &cycles {
            errors.push(format!("  Ciclo: {}", cycle.join(" → ")));
        }
    }

    serde_json::json!({
        "has_cycles": !cycles.is_empty(),
        "projects_scanned": projects_found,
        "cycles_found": cycles,
        "dependencies": graph,
        "errors": errors,
        "warnings": warnings,
    }).to_string()
}

/// Extrae dependencias de la sección ## Dependencias de un _specs.md
fn extract_dependencies(content: &str) -> Vec<String> {
    let mut deps = Vec::new();
    let mut in_deps_section = false;

    for line in content.lines() {
        let trimmed = line.trim();
        let lower = trimmed.to_lowercase();

        if lower.starts_with("## dependencias") {
            in_deps_section = true;
            continue;
        }
        if in_deps_section && lower.starts_with("## ") {
            break; // Fin de la sección
        }
        if in_deps_section && !trimmed.is_empty() {
            // Líneas de dependencia: "- nombre_proyecto" o "* nombre" o "nombre: desc"
            let dep_name = trimmed
                .trim_start_matches(['-', '*', '+'])
                .trim()
                .split([':', ' '])
                .next()
                .unwrap_or("")
                .trim()
                .to_lowercase();

            if !dep_name.is_empty() && dep_name.len() > 1 {
                deps.push(dep_name);
            }
        }
    }

    deps
}

/// Algoritmo DFS para detectar ciclos en grafo dirigido
fn find_cycles(graph: &HashMap<String, Vec<String>>) -> Vec<Vec<String>> {
    let mut cycles = Vec::new();
    let mut visited = HashSet::new();
    let mut stack = Vec::new();

    for node in graph.keys() {
        if !visited.contains(node.as_str()) {
            dfs_visit(node, graph, &mut visited, &mut stack, &mut cycles);
        }
    }

    cycles
}

fn dfs_visit(
    node: &str,
    graph: &HashMap<String, Vec<String>>,
    visited: &mut HashSet<String>,
    stack: &mut Vec<String>,
    cycles: &mut Vec<Vec<String>>,
) {
    visited.insert(node.to_string());
    stack.push(node.to_string());

    if let Some(neighbors) = graph.get(node) {
        for neighbor in neighbors {
            let neighbor_lower = neighbor.to_lowercase();
            let neighbor_key = graph.keys().find(|k| k.to_lowercase() == neighbor_lower);

            if let Some(actual_neighbor) = neighbor_key {
                if let Some(pos) = stack.iter().position(|n| n.to_lowercase() == neighbor_lower) {
                    // Ciclo encontrado
                    let mut cycle: Vec<String> = stack[pos..].to_vec();
                    cycle.push(cycle[0].clone()); // cerrar el ciclo
                    cycles.push(cycle);
                } else if !visited.contains(actual_neighbor.as_str()) {
                    dfs_visit(actual_neighbor, graph, visited, stack, cycles);
                }
            }
        }
    }

    stack.pop();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_memory_with_frontmatter() {
        let content = "---\nname: test-project\ndescription: un proyecto de prueba\n---\n\n## Contexto\nTest context\n\n## Hitos\n- Hito 1\n\n## Historial\n- Sesión 1\n";
        let result = validate_okf_file_content(content, "_memory.md");
        assert!(result.is_valid, "Errores: {:?}", result.errors);
        assert!(result.has_frontmatter);
        assert_eq!(result.sections_found.len(), 3);
    }

    #[test]
    fn test_validate_bad_frontmatter() {
        let content = "---\nname bad line\n---\n## Contexto\n";
        let result = validate_okf_file_content(content, "_memory.md");
        assert!(!result.warnings.is_empty());
    }

    #[test]
    fn test_missing_sections() {
        let content = "# Solo título\nsin secciones";
        let result = validate_okf_file_content(content, "_memory.md");
        assert!(!result.warnings.is_empty());
    }

    #[test]
    fn test_cycle_detection() {
        let mut graph = HashMap::new();
        graph.insert("a".into(), vec!["b".into()]);
        graph.insert("b".into(), vec!["c".into()]);
        graph.insert("c".into(), vec!["a".into()]);
        let cycles = find_cycles(&graph);
        assert!(!cycles.is_empty());
    }

    fn validate_okf_file_content(content: &str, file_name: &str) -> ValidationReport {
        let mut report = ValidationReport {
            file: file_name.to_string(),
            is_valid: true,
            errors: Vec::new(),
            warnings: Vec::new(),
            has_frontmatter: false,
            sections_found: Vec::new(),
        };

        if !matches!(file_name, "_memory.md" | "_specs.md" | "_lore.md") {
            report.warnings.push("No es un archivo de la tríada OKF.".into());
        }

        validate_frontmatter(content, &mut report);

        match file_name {
            "_memory.md" => validate_memory(content, &mut report),
            "_specs.md" => validate_specs(content, &mut report),
            "_lore.md" => validate_lore(content, &mut report),
            _ => {}
        }

        detect_sections(content, &mut report);
        report.is_valid = report.errors.is_empty();
        report
    }
}
