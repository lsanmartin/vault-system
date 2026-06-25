use std::process::Command;

fn main() {
    // Instrucciones uniffi estándar
    uniffi::generate_scaffolding("src/vault_core.udl").ok();

    // Forzar @rpath como install name del dylib resultante.
    // Sin esto, el install name queda como ruta absoluta al directorio target/
    // y el app crash al launch si no encuentra exactamente esa ruta.
    //
    // Con @rpath/libvault_core.dylib, el sistema resuelve la ruta en runtime
    // usando los RPATH entries del binario consumidor (configurados en Xcode).
    println!("cargo:rustc-link-arg-cdylib=-Wl,-install_name,@rpath/libvault_core.dylib");

    // Asegurar que dyld pueda resolver dependencias transitivas del dylib
    // cuando se ejecuta desde dentro del .app bundle
    println!("cargo:rustc-link-arg-cdylib=-Wl,-rpath,@loader_path/../Frameworks");
}
