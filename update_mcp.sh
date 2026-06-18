#!/bin/bash
cat << 'RUST' > /tmp/mcp.rs
static MCP_TOKENS: std::sync::LazyLock<std::sync::Mutex<Vec<McpTokenRecord>>> = std::sync::LazyLock::new(|| std::sync::Mutex::new(Vec::new()));

#[uniffi::export]
pub fn load_mcp_tokens_from_json(json_str: String) -> bool {
    if let Ok(tokens) = serde_json::from_str::<Vec<McpTokenRecord>>(&json_str) {
        if let Ok(mut guard) = MCP_TOKENS.lock() {
            *guard = tokens;
            return true;
        }
    }
    false
}

#[uniffi::export]
pub fn export_mcp_tokens_to_json() -> String {
    if let Ok(guard) = MCP_TOKENS.lock() {
        if let Ok(json) = serde_json::to_string_pretty(&*guard) {
            return json;
        }
    }
    "[]".to_string()
}
RUST
