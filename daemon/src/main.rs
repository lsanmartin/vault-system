use std::io::{self, BufRead, BufReader, Write};
use std::net::TcpStream;

fn main() {
    let stdin = io::stdin();
    let mut handle = stdin.lock();
    let mut buffer = String::new();

    loop {
        buffer.clear();
        match handle.read_line(&mut buffer) {
            Ok(0) => break, // EOF
            Ok(_) => {
                if buffer.trim().is_empty() { continue; }
                
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
                        // Si no pudimos conectar, enviar un error JSON-RPC estándar a la IA
                        if let Ok(req) = serde_json::from_str::<serde_json::Value>(&buffer) {
                            if let Some(id) = req.get("id") {
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
                }
            }
            Err(_) => break,
        }
    }
}
