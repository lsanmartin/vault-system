fn make_accent_insensitive_regex(word: &str) -> String {
    let mut regex = String::new();
    for c in word.chars() {
        if c >= '\u{0300}' && c <= '\u{036F}' {
            continue;
        }
        match c.to_lowercase().next().unwrap() {
            'a' | 'á' | 'ä' => regex.push_str("[aáäAÁÄ]\\p{M}*"),
            'e' | 'é' | 'ë' => regex.push_str("[eéëEÉË]\\p{M}*"),
            'i' | 'í' | 'ï' => regex.push_str("[iíïIÍÏ]\\p{M}*"),
            'o' | 'ó' | 'ö' => regex.push_str("[oóöOÓÖ]\\p{M}*"),
            'u' | 'ú' | 'ü' => regex.push_str("[uúüUÚÜ]\\p{M}*"),
            'n' | 'ñ' => regex.push_str("[nñNÑ]\\p{M}*"),
            other => {
                if ".*+?^${}()|[]\\".contains(other) {
                    regex.push('\\');
                }
                regex.push(other);
                regex.push_str("\\p{M}*");
            }
        }
    }
    regex
}

fn main() {
    let word1 = "diseñadores";
    let word2 = "cronologia";
    println!("Regex 1: (?i){}", make_accent_insensitive_regex(word1));
    println!("Regex 2: (?i){}", make_accent_insensitive_regex(word2));
}
