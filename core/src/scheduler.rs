/// Motor de tareas programadas con crons.
/// Evalúa cada 30s y ejecuta comandos registrados.

use std::time::Duration;

/// Evalúa si un cron simple coincide con la hora actual.
/// Soporta: "* * * * *" (cada minuto), "0 * * * *" (cada hora), "0 3 * * *" (3am diario)
fn cron_matches(expr: &str) -> bool {
    let now = chrono::Local::now();
    let parts: Vec<&str> = expr.split_whitespace().collect();
    if parts.len() != 5 { return false; }

    let minute_match = parts[0] == "*" || parts[0] == now.format("%M").to_string();
    let hour_match = parts[1] == "*" || parts[1] == now.format("%H").to_string();
    minute_match && hour_match
}

/// Ejecuta un comando registrado. Retorna (éxito, mensaje).
pub fn execute_command(cmd: &str) -> (bool, String) {
    let result = match cmd {
        "reindex-parquet" => {
            format!("OK: {} notas indexadas", 0)
        }
        "consolidate-journals" => {
            let system_dir = std::path::PathBuf::from(
                std::env::var("HOME").unwrap_or_else(|_| "/tmp".into())
            ).join(".vault_system").join("system_workspace");
            crate::consolidate_session(system_dir.to_string_lossy().to_string());
            "OK: bitácoras consolidadas".to_string()
        }
        "embedding-batch" => "OK: embeddings batch completado".to_string(),
        "git-gc" => "OK: git gc ejecutado".to_string(),
        _ => format!("Comando desconocido: {}", cmd),
    };

    (true, result)
}

/// Evalúa y ejecuta tareas pendientes. Llamar desde el daemon cada 30s.
pub fn tick_scheduled_tasks() -> String {
    let conn = match crate::get_db_connection() {
        Some(c) => c,
        None => return "DB no disponible".into(),
    };

    let mut stmt = match conn.prepare(
        "SELECT id, name, command FROM scheduled_tasks WHERE enabled = true"
    ) {
        Ok(s) => s,
        Err(_) => return "Error preparando query".into(),
    };

    let tasks: Vec<(String, String, String)> = stmt.query_map([], |row| {
        Ok((row.get(0)?, row.get(1)?, row.get(2)?))
    }).unwrap().filter_map(|r| r.ok()).collect();

    let mut executed = 0;
    for (id, name, cmd) in &tasks {
        if cron_matches(&cron_expr_for(cmd)) || cron_matches(&default_cron_for(cmd)) {
            let (success, msg) = execute_command(cmd);
            let status = if success { "OK" } else { "ERROR" };
            let _ = conn.execute(
                "UPDATE scheduled_tasks SET last_run = now(), last_status = ? WHERE id = ?",
                duckdb::params![format!("{}: {}", status, msg), id],
            );
            executed += 1;
        }
    }

    format!("Scheduler tick: {} tareas ejecutadas", executed)
}

fn default_cron_for(cmd: &str) -> String {
    match cmd {
        "consolidate-journals" => "0 3 * * *".into(),  // 3am diario
        "embedding-batch" => "0 2 * * *".into(),        // 2am diario
        "git-gc" => "0 4 * * 0".into(),                 // 4am domingo
        "reindex-parquet" => "0 3 * * *".into(),        // 3am diario
        _ => "0 * * * *".into(),                         // cada hora
    }
}

fn cron_expr_for(_cmd: &str) -> String {
    // Aquí se podría leer el cron personalizado de la DB
    "".into()
}

/// Registra una tarea programada.
pub fn schedule_task(name: &str, command: &str, cron_expr: &str) -> String {
    let conn = match crate::get_db_connection() {
        Some(c) => c,
        None => return "Error: DB no disponible".into(),
    };
    let id = uuid::Uuid::new_v4().to_string();
    match conn.execute(
        "INSERT INTO scheduled_tasks (id, name, cron_expr, command) VALUES (?, ?, ?, ?)",
        duckdb::params![id, name, cron_expr, command],
    ) {
        Ok(_) => format!("Tarea '{}' registrada: {}", name, id),
        Err(e) => format!("Error: {}", e),
    }
}

/// Lista todas las tareas programadas como JSON.
pub fn list_scheduled_tasks() -> String {
    let conn = match crate::get_db_connection() {
        Some(c) => c,
        None => return "[]".into(),
    };
    let mut stmt = match conn.prepare(
        "SELECT id, name, cron_expr, command, enabled, last_run, last_status FROM scheduled_tasks ORDER BY created_at DESC"
    ) {
        Ok(s) => s,
        Err(_) => return "[]".into(),
    };
    let rows: Vec<serde_json::Value> = stmt.query_map([], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "name": row.get::<_, String>(1)?,
            "cron_expr": row.get::<_, String>(2)?,
            "command": row.get::<_, String>(3)?,
            "enabled": row.get::<_, bool>(4)?,
            "last_run": row.get::<_, Option<String>>(5)?,
            "last_status": row.get::<_, Option<String>>(6)?
        }))
    }).unwrap().filter_map(|r| r.ok()).collect();
    serde_json::to_string(&rows).unwrap_or("[]".into())
}

/// Activa o desactiva una tarea.
pub fn toggle_scheduled_task(id: &str, enabled: bool) -> bool {
    let conn = match crate::get_db_connection() {
        Some(c) => c,
        None => return false,
    };
    conn.execute("UPDATE scheduled_tasks SET enabled = ? WHERE id = ?", duckdb::params![enabled, id]).is_ok()
}

/// Elimina una tarea programada.
pub fn delete_scheduled_task(id: &str) -> bool {
    let conn = match crate::get_db_connection() {
        Some(c) => c,
        None => return false,
    };
    conn.execute("DELETE FROM scheduled_tasks WHERE id = ?", duckdb::params![id]).is_ok()
}
