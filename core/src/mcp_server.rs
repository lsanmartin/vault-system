use serde::{Deserialize, Serialize};
use serde_json::json;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

#[derive(Deserialize, Serialize, Clone)]
pub struct McpTokenRecord {
    pub token_id: String,
    pub client_name: String,
    pub workspaces: Vec<String>,
    pub can_write_projects: bool,
    pub allow_project_metadata: bool,
    pub allow_workspace_context: bool,
    pub allow_telemetry: bool,
    #[serde(default)]
    pub allow_telemetry_system: bool,
    #[serde(default)]
    pub allow_telemetry_project: bool,
    #[serde(default)]
    pub allow_telemetry_human: bool,
    #[serde(default)]
    pub allow_telemetry_agent: bool,
}

#[derive(Deserialize)]
struct RpcRequest {
    #[allow(dead_code)]
    jsonrpc: String,
    method: String,
    params: Option<serde_json::Value>,
    id: Option<serde_json::Value>,
}

#[derive(Serialize)]
struct RpcResponse {
    jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<serde_json::Value>,
}

fn config_dir() -> PathBuf {
    if let Ok(home) = std::env::var("HOME") {
        PathBuf::from(home).join(".config")
    } else {
        PathBuf::from(".")
    }
}

fn validate_token(token_id: Option<String>, workspace_root: &Path) -> anyhow::Result<McpTokenRecord> {
    let token_id = token_id.ok_or_else(|| anyhow::anyhow!("Se requiere autenticación MCP (--token=...)"))?;
    
    // vault-system config path
    let path = config_dir().join("vault-system").join("mcp_tokens.json");
    
    // fallback to vault-app for migration if needed
    let content = std::fs::read_to_string(&path)
        .or_else(|_| std::fs::read_to_string(config_dir().join("vault-app").join("mcp_tokens.json")))
        .map_err(|_| anyhow::anyhow!("No se encontraron tokens MCP configurados"))?;
        
    let tokens: Vec<McpTokenRecord> = serde_json::from_str(&content)
        .map_err(|_| anyhow::anyhow!("Archivo de tokens MCP corrupto"))?;
        
    let token = tokens.into_iter().find(|t| t.token_id == token_id)
        .ok_or_else(|| anyhow::anyhow!("Token MCP inválido o revocado"))?;
        
    let workspace_str = workspace_root.to_string_lossy().to_string();
    if !token.workspaces.is_empty() {
        let has_access = token.workspaces.iter().any(|allowed| {
            workspace_str == *allowed || workspace_str.starts_with(&format!("{}/", allowed))
        });
        if !has_access {
            return Err(anyhow::anyhow!("El token MCP no tiene acceso a este workspace"));
        }
    }
    Ok(token)
}

fn handle_method(method: &str, _params: Option<serde_json::Value>, workspace_root: &Path, token: &McpTokenRecord) -> anyhow::Result<serde_json::Value> {
    match method {
        "initialize" => {
            let mut instructions = String::new();
            
            let global_agent_path = config_dir().join("vault-system").join("mcp_global_agent.md");
            if global_agent_path.exists() {
                if let Ok(content) = std::fs::read_to_string(&global_agent_path) {
                    instructions.push_str(&content);
                    instructions.push_str("\n\n---\n\n");
                }
            } else {
                instructions.push_str("Estás operando el servidor MCP de Vault-System.\n\n---\n\n");
            }
            
            if token.allow_workspace_context {
                let agent_md_path = workspace_root.join("agent.md");
                if agent_md_path.exists() {
                    if let Ok(content) = std::fs::read_to_string(&agent_md_path) {
                        instructions.push_str("=== INSTRUCCIONES DEL WORKSPACE ===\n");
                        instructions.push_str(&content);
                    }
                }
            }

            Ok(serde_json::json!({
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": { "listChanged": false }
                },
                "serverInfo": {
                    "name": "vault-system-mcp",
                    "version": "0.1.0"
                },
                "instructions": instructions
            }))
        }
        "notifications/initialized" => {
            Ok(serde_json::Value::Null)
        }
        "tools/list" => {
            // Delegar a mcp_handle_request (lib.rs) que tiene la lista completa de herramientas
            let internal_req = json!({
                "jsonrpc": "2.0",
                "method": "tools/list",
                "params": {},
                "id": 1,
                "mcp_client_token": token.token_id
            });
            let response_str = crate::mcp_handle_request(internal_req.to_string());
            match serde_json::from_str::<serde_json::Value>(&response_str) {
                Ok(resp) => {
                    if let Some(result) = resp.get("result") {
                        Ok(result.clone())
                    } else if let Some(err) = resp.get("error") {
                        Err(anyhow::anyhow!("{}", err.get("message").and_then(|m| m.as_str()).unwrap_or("Error MCP")))
                    } else {
                        Ok(json!({"tools": []}))
                    }
                }
                Err(_) => Ok(json!({"tools": []}))
            }
        }
        "tools/call" => {
            let params = _params.unwrap_or(json!({}));
            let internal_req = json!({
                "jsonrpc": "2.0",
                "method": "tools/call",
                "params": params,
                "id": 1,
                "mcp_client_token": token.token_id
            });
            let response_str = crate::mcp_handle_request(internal_req.to_string());
            match serde_json::from_str::<serde_json::Value>(&response_str) {
                Ok(resp) => {
                    if let Some(result) = resp.get("result") {
                        Ok(result.clone())
                    } else if let Some(err) = resp.get("error") {
                        Err(anyhow::anyhow!("{}", err.get("message").and_then(|m| m.as_str()).unwrap_or("Error MCP")))
                    } else {
                        Err(anyhow::anyhow!("Respuesta MCP vacía"))
                    }
                }
                Err(e) => Err(anyhow::anyhow!("Error parseando respuesta MCP: {}", e))
            }
        }
        _ => Err(anyhow::anyhow!("Método no soportado: {}", method)),
    }
}

pub fn run_mcp_server(workspace_root: PathBuf, max_payload_bytes: usize, token_id: Option<String>) -> anyhow::Result<()> {
    let token = validate_token(token_id, &workspace_root)?;
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    let mut reader = stdin.lock();

    eprintln!("Vault-System MCP Server started. Workspace: {:?} | Client: {}", workspace_root, token.client_name);

    loop {
        let mut line = String::new();
        let bytes_read = reader.read_line(&mut line)?;
        if bytes_read == 0 {
            break;
        }

        if line.len() > max_payload_bytes {
            eprintln!("Error: Payload exceeds maximum size");
            continue;
        }

        if line.trim().is_empty() {
            continue;
        }

        match serde_json::from_str::<RpcRequest>(&line) {
            Ok(req) => {
                let req_params = req.params.clone();
                let method = req.method.clone();
                let req_id = req.id.clone();
                
                let wr = workspace_root.clone();
                let tk = token.clone();
                let (tx, rx) = std::sync::mpsc::channel::<anyhow::Result<serde_json::Value>>();
                
                std::thread::Builder::new()
                    .name("mcp-worker".into())
                    .spawn(move || {
                        let _ = tx.send(handle_method(&method, req_params, &wr, &tk));
                    })
                    .ok();

                let result = rx.recv_timeout(std::time::Duration::from_secs(120));

                if req_id.is_none() {
                    continue;
                }

                let response = match result {
                    Ok(Ok(val)) => RpcResponse {
                        jsonrpc: "2.0".to_string(),
                        result: Some(val),
                        error: None,
                        id: req_id,
                    },
                    Ok(Err(e)) => RpcResponse {
                        jsonrpc: "2.0".to_string(),
                        result: None,
                        error: Some(serde_json::json!({
                            "code": -32603,
                            "message": e.to_string()
                        })),
                        id: req_id,
                    },
                    Err(_) => RpcResponse {
                        jsonrpc: "2.0".to_string(),
                        result: None,
                        error: Some(serde_json::json!({
                            "code": -32001,
                            "message": "Timeout o error de hilo"
                        })),
                        id: req_id,
                    }
                };

                let response_str = serde_json::to_string(&response)?;
                writeln!(stdout, "{}", response_str)?;
                stdout.flush()?;
            }
            Err(e) => {
                eprintln!("Error parseando JSON-RPC: {}", e);
            }
        }
    }

    Ok(())
}
