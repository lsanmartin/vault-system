use std::io::{self, BufRead, BufReader, Write};
use std::net::TcpStream;
use std::env;

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut client_token: Option<String> = None;
    
    for i in 0..args.len() {
        if args[i] == "--client-token" && i + 1 < args.len() {
            client_token = Some(args[i+1].clone());
        }
    }

    if client_token.is_none() {
        eprintln!("Error: Se requiere --client-token <TOKEN_UUID>");
        std::process::exit(1);
    }

    let client_token_val = client_token.unwrap();

    let stdin = io::stdin();
    let mut handle = stdin.lock();
    let mut buffer = String::new();

    loop {
        buffer.clear();
        match handle.read_line(&mut buffer) {
            Ok(0) => break, // EOF
            Ok(_) => {
                if buffer.trim().is_empty() { continue; }
                
                let req_val: Option<serde_json::Value> = serde_json::from_str(&buffer).ok();
                
                // Inyectar tokens (IPC Interno y Client Token de MCP)
                if let Some(mut req) = req_val {
                    let ipc_token = std::fs::read_to_string("/tmp/vault_ipc.token").unwrap_or("".to_string());
                    if let Some(obj) = req.as_object_mut() {
                        obj.insert("ipc_token".to_string(), serde_json::json!(ipc_token.trim()));
                        obj.insert("mcp_client_token".to_string(), serde_json::json!(client_token_val.trim()));
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
