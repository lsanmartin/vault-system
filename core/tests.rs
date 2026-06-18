#[cfg(test)]
mod tests {
    use duckdb::Connection;
    // copiamos la logica de make_accent_insensitive_regex
    fn make_accent_insensitive_regex(word: &str) -> String {
        let mut regex = String::new();
        for c in word.chars() {
            if c >= '\u{0300}' && c <= '\u{036F}' { continue; }
            match c.to_lowercase().next().unwrap() {
                'a' | 'á' | 'ä' => regex.push_str("[aáäAÁÄ]\\p{M}*"),
                'e' | 'é' | 'ë' => regex.push_str("[eéëEÉË]\\p{M}*"),
                'i' | 'í' | 'ï' => regex.push_str("[iíïIÍÏ]\\p{M}*"),
                'o' | 'ó' | 'ö' => regex.push_str("[oóöOÓÖ]\\p{M}*"),
                'u' | 'ú' | 'ü' => regex.push_str("[uúüUÚÜ]\\p{M}*"),
                'n' | 'ñ' => regex.push_str("[nñNÑ]\\p{M}*"),
                other => {
                    if ".*+?^${}()|[]\\".contains(other) { regex.push('\\'); }
                    regex.push(other);
                    regex.push_str("\\p{M}*");
                }
            }
        }
        regex
    }

    #[test]
    fn test_duckdb_query() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/lsanmartin".to_string());
        let db_path = format!("{}/.vault_system.duckdb", home);
        let conn = Connection::open(&db_path).unwrap();

        let term = "diseñadores cronologia";
        let mut sql = "SELECT title FROM notes WHERE 1=1".to_string();

        for word in term.split_whitespace() {
            let safe_word = word.replace("'", "''");
            let regex_pattern = format!("(?i){}", make_accent_insensitive_regex(&safe_word));
            sql.push_str(&format!(" AND (regexp_matches(title, '{}') OR regexp_matches(content, '{}') OR regexp_matches(path, '{}'))", regex_pattern, regex_pattern, regex_pattern));
        }

        println!("SQL: {}", sql);
        let mut stmt = conn.prepare(&sql).unwrap();
        let rows = stmt.query_map([], |row| row.get::<_, String>(0)).unwrap();
        for title in rows {
            println!("MATCHED TITLE: {}", title.unwrap());
        }
    }
}
