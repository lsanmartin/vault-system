use std::io::{self, BufRead, BufReader, Write};
use std::net::TcpStream;
use std::env;

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut allowed_workspace: Option<String> = None;
    let mut is_read_only = false;
    let mut allow_metadata = false;
    let mut allow_system = false;
    
    for i in 0..args.len() {
        if args[i] == "--workspace" && i + 1 < args.len() {
            allowed_workspace = Some(args[i+1].clone());
        }
        if args[i] == "--read-only" {
            is_read_only = true;
        }
        if args[i] == "--allow-metadata" {
            allow_metadata = true;
        }
        if args[i] == "--allow-system" {
            allow_system = true;
        }
    }

    let stdin = io::stdin();
    let mut handle = stdin.lock();
    let mut buffer = String::new();

    loop {
        buffer.clear();
        match handle.read_line(&mut buffer) {
            Ok(0) => break, // EOF
            Ok(_) => {
                if buffer.trim().is_empty() { continue; }
                
                // --- CAPA DE SEGURIDAD DEL DAEMON ---
                let mut should_block = false;
                let mut block_reason = String::new();
                let mut req_val: Option<serde_json::Value> = serde_json::from_str(&buffer).ok();
                
                if let Some(ref mut req) = req_val {
                    if let Some(method) = req.get("method").and_then(|m| m.as_str()) {
                        if method == "tools/call" {
                            if let Some(params) = req.get_mut("params").and_then(|p| p.as_object_mut()) {
                                let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("").to_string();
                                
                                // Bloqueo de Escritura
                                if is_read_only && (name == "vault_write" || name == "vault_create_folder") {
                                    should_block = true;
                                    block_reason = "El Workspace está configurado como READ-ONLY. No se pueden modificar archivos.".to_string();
                                }
                                
                                if let Some(args) = params.get_mut("arguments").and_then(|a| a.as_object_mut()) {
                                    // Validación de Rutas (Workspace y Metadatos)
                                    if let Some(path_val) = args.get("path").and_then(|p| p.as_str()) {
                                        // 1. Workspace
                                        if let Some(ref workspace_path) = allowed_workspace {
                                            if !path_val.starts_with(workspace_path) {
                                                should_block = true;
                                                block_reason = format!("Acceso Denegado: La IA está restringida al Workspace '{}'.", workspace_path);
                                            }
                                        }
                                        // 2. Capa Meta-Sistémica (Reglas y lore global)
                                        if !allow_system && (path_val.contains("/00-Sistema") || path_val.ends_with("GEMINI.md") || path_val.ends_with("agentes.md")) {
                                            should_block = true;
                                            block_reason = "Acceso Denegado: No tienes permisos para acceder a la Capa Meta-Sistémica (00-Sistema, GEMINI.md).".to_string();
                                        }
                                        // 3. Capa Meta-Cognitiva (Metadatos de proyecto y estado)
                                        if !allow_metadata && path_val.contains("/_") {
                                            should_block = true;
                                            block_reason = "Acceso Denegado: No tienes permisos para acceder a la Capa Meta-Cognitiva (archivos/carpetas con '_').".to_string();
                                        }
                                    }
                                    
                                    // Inyección de parámetros para vault_search
                                    if name == "vault_search" {
                                        if !allow_metadata {
                                            args.insert("exclude_metadata".to_string(), serde_json::json!(true));
                                        }
                                        if !allow_system {
                                            args.insert("exclude_system".to_string(), serde_json::json!(true));
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Si la validación falla, rebotar inmediatamente
                if should_block {
                    if let Some(req) = req_val {
                        let id = req.get("id").unwrap_or(&serde_json::json!(null)).clone();
                        let err_resp = serde_json::json!({
                            "jsonrpc": "2.0",
                            "id": id,
                            "error": {
                                "code": -32000,
                                "message": block_reason
                            }
                        });
                        println!("{}", err_resp);
                        let _ = io::stdout().flush();
                        continue;
                    }
                }
                
                // Si hubo inyección de args (ej. vault_search), regenerar buffer
                if let Some(mut req) = req_val {
                    // Leer Token IPC generado por la App
                    let ipc_token = std::fs::read_to_string("/tmp/vault_ipc.token").unwrap_or("".to_string());
                    if let Some(obj) = req.as_object_mut() {
                        obj.insert("ipc_token".to_string(), serde_json::json!(ipc_token.trim()));
                    }
                    buffer = serde_json::to_string(&req).unwrap() + "\n";
                }
                
                // Conectar al puerto IPC de la Vault App
                match TcpStream::connect("127.0.0.1:49152") {
                    Ok(mut stream) => {
                        let _ = stream.write_all(buffer.as_bytes());
                        let mut reader = BufReader::new(stream);
                        let mut response = String::new();
                        if let Ok(_) = reader.read_line(&mut response) {
                            if !response.trim().is_empty() {
                                print!("{}", response);
                                let _ = io::stdout().flush();
                            }
                        }
                    }
                    Err(_) => {
                        let req_parse = serde_json::from_str::<serde_json::Value>(&buffer).ok();
                        let id = req_parse.as_ref().and_then(|r| r.get("id")).unwrap_or(&serde_json::json!(null));
                        let err_resp = serde_json::json!({
                            "jsonrpc": "2.0",
                            "id": id,
                            "error": {
                                "code": -32000,
                                "message": "Vault App no está ejecutándose o el IPC Server no ha iniciado."
                            }
                        });
                        println!("{}", err_resp);
                        let _ = io::stdout().flush();
                    }
                }
            }
            Err(_) => break,
        }
    }
}
