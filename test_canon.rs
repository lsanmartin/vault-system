use std::fs;
fn main() {
    let p = "/Users/lsanmartin/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian/06-Desarrollo/dpo-vaa/docs/Nueva Nota 1784757680.md";
    let canon = fs::canonicalize(p);
    println!("{:?}", canon);
}
